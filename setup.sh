#!/usr/bin/env bash
# Host-run FusionPBX bootstrap for your Docker stack.
# Executes inside the containers via docker exec. Quiet, idempotent, Windows-safe.
set -Eeuo pipefail

# ------------- Config you can tweak -------------
# Container names (must match your compose)
PG_CTN="${PG_CTN:-pbx_postgres}"
FPBX_CTN="${FPBX_CTN:-pbx_fusion}"
FS_CTN="${FS_CTN:-pbx_freeswitch}"

# Local config (on host)
CONFIG_SH="${CONFIG_SH:-./config.sh}"
FPBX_CONF_SRC="${FPBX_CONF_SRC:-./fusionpbx/config.conf}"  # optional template

# psql auth/maintenance DB
PSQL_USER="${POSTGRES_USER:-fusionpbx}"
PSQL_DB_MAINT="${POSTGRES_DB:-fusion_pbx_db}"

# Defaults if your config forgot them (overridden by CONFIG_SH if set)
: "${database_host:=pbx_postgres}"
: "${database_port:=5432}"
: "${database_name:=fusion_pbx_db}"
: "${database_username:=fusionpbx}"
: "${database_password:=12345678}"
: "${system_username:=admin}"
: "${system_password:=random}"
: "${domain_name:=hostname}"

# ------------- Sanity checks -------------
command -v docker >/dev/null || { echo "docker not found"; exit 1; }
[[ -f "$CONFIG_SH" ]] || { echo "Missing $CONFIG_SH. Put your variables there."; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG_SH"

# ------------- Bring up containers (idempotent) -------------
echo "[host] ensuring containers are running..."
docker compose up -d "$PG_CTN" "$FPBX_CTN" "$FS_CTN" >/dev/null 2>&1 || true

# ------------- docker exec helpers (MSYS path-mangle off) -------------
dex_fpbx(){ MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" docker exec -i "$FPBX_CTN" "$@"; }
dex_pg(){   MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" docker exec -i "$PG_CTN" "$@"; }
dex_fs(){   MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" docker exec -i "$FS_CTN" "$@"; }

# ------------- Wait for Postgres (maintenance DB) -------------
echo "[host] waiting for Postgres..."
for _ in $(seq 1 60); do
  if docker exec "$PG_CTN" pg_isready -U "$PSQL_USER" -d "$PSQL_DB_MAINT" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# ------------- Generate passwords if requested -------------
if [[ ".${database_password}" = ".random" ]]; then
  database_password="$(dd if=/dev/urandom bs=1 count=24 2>/dev/null | base64 | sed 's/[=+\/]//g')"
  echo "[host] generated database_password"
fi
if [[ ".${system_password}" = ".random" ]]; then
  ui_password="$(dd if=/dev/urandom bs=1 count=24 2>/dev/null | base64 | sed 's/[=+\/]//g')"
  echo "[host] generated UI password"
else
  ui_password="$system_password"
fi

# ------------- Ensure application database exists -------------
echo "[db] ensuring application database exists: ${database_name}"
DB_EXISTS="$(dex_pg psql -tA -U "$PSQL_USER" -d "$PSQL_DB_MAINT" -h "$database_host" \
  -c "SELECT 1 FROM pg_database WHERE datname='${database_name}'")"
if [[ "$DB_EXISTS" != "1" ]]; then
  echo "[db] creating database ${database_name} owned by ${PSQL_USER}"
  dex_pg psql -v ON_ERROR_STOP=1 -U "$PSQL_USER" -d "$PSQL_DB_MAINT" -h "$database_host" \
    -c "CREATE DATABASE ${database_name} OWNER ${PSQL_USER};"
fi
dex_pg psql -tA -U "$PSQL_USER" -d "$PSQL_DB_MAINT" -h "$database_host" \
  -c "SELECT 1 FROM pg_database WHERE datname='${database_name}'" | grep -q '^1$' \
  || { echo "[db][error] ${database_name} was not created"; exit 1; }

# ------------- Update DB role passwords (if roles exist) -------------
echo "[db] altering roles fusionpbx / freeswitch"
dex_pg psql -v ON_ERROR_STOP=1 -U "$PSQL_USER" -d "$PSQL_DB_MAINT" -h "$database_host" <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='fusionpbx') THEN
    EXECUTE 'ALTER USER fusionpbx WITH PASSWORD ' || quote_literal('${database_password}');
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='freeswitch') THEN
    EXECUTE 'ALTER USER freeswitch WITH PASSWORD ' || quote_literal('${database_password}');
  END IF;
END
\$\$;
SQL

# ------------- Seed /etc/fusionpbx/config.conf inside FusionPBX -------------
echo "[fpbx] ensuring /etc/fusionpbx/config.conf"
dex_fpbx bash -c "mkdir -p /etc/fusionpbx"
if [[ -f "$FPBX_CONF_SRC" ]]; then
  docker cp "$FPBX_CONF_SRC" "$FPBX_CTN:/etc/fusionpbx/config.conf"
else
  dex_fpbx bash -lc "cat >/etc/fusionpbx/config.conf <<'EOF'
[database]
type=pgsql
host={database_host}
name={database_name}
username={database_username}
password={database_password}
port={database_port}
EOF"
fi
# replace placeholders inside the container
dex_fpbx bash -lc "sed -i \
  -e 's:{database_host}:$database_host:g' \
  -e 's:{database_name}:$database_name:g' \
  -e 's:{database_username}:$database_username:g' \
  -e 's:{database_password}:$database_password:g' \
  -e 's:{database_port}:$database_port:g' /etc/fusionpbx/config.conf"

# ------------- Locate upgrade.php -------------
UPGRADE_PATH="$(dex_fpbx bash -lc 'for p in \
  /var/www/fusionpbx/core/upgrade/upgrade.php \
  /var/www/core/upgrade/upgrade.php; do
  [ -f "$p" ] && echo "$p" && break
done')"
[ -n "$UPGRADE_PATH" ] || { echo "[fpbx][error] FusionPBX not found under /var/www"; exit 1; }

# ------------- Quiet runner for upgrade steps -------------
run_upgrade_quiet() {
  local step="$1"
  echo "[fpbx] running $step (quiet)"
  dex_fpbx bash -lc "
    set -e
    LOGDIR=/var/log/fusionpbx
    mkdir -p \"\$LOGDIR\"
    LOGFILE=\"\$LOGDIR/upgrade_${step}.log\"
    php -d display_errors=0 \"$UPGRADE_PATH\" --$step >\"\$LOGFILE\" 2>&1
  " || {
    echo "[fpbx][error] upgrade step '$step' failed. Last 100 lines:"
    dex_fpbx bash -lc "tail -n 100 /var/log/fusionpbx/upgrade_${step}.log || true"
    exit 1
  }
}

# ------------- Run schema first -------------
run_upgrade_quiet schema

# ------------- Silence SQL/log debug settings (after schema) -------------
dex_pg psql -v ON_ERROR_STOP=1 -U "$PSQL_USER" -d "$database_name" -h "$database_host" -c "
UPDATE v_default_settings
   SET default_setting_enabled='false'
 WHERE (default_setting_category IN ('database','log','logging','message','internal')
        OR default_setting_subcategory ILIKE '%sql%'
        OR default_setting_name ILIKE '%sql%')
   AND default_setting_enabled='true';
"
dex_pg psql -v ON_ERROR_STOP=1 -U "$PSQL_USER" -d "$database_name" -h "$database_host" -c "
UPDATE v_domain_settings
   SET domain_setting_enabled='false'
 WHERE (domain_setting_category IN ('database','log','logging','message','internal')
        OR domain_setting_subcategory ILIKE '%sql%'
        OR domain_setting_name ILIKE '%sql%')
   AND domain_setting_enabled='true';
"

# ------------- Determine domain name within container netns -------------
resolved_domain_name="$(dex_fpbx bash -lc '
  d="'"$domain_name"'"
  if [ ".$d" = ".hostname" ]; then hostname -f || hostname; elif [ ".$d" = ".ip_address" ]; then hostname -I | awk "{print \$1}"; else echo "$d"; fi
')"
echo "[fpbx] domain_name => $resolved_domain_name"

# ------------- Create domain + admin user, add to superadmin -------------
domain_uuid="$(dex_fpbx php /var/www/fusionpbx/resources/uuid.php)"
user_uuid="$(dex_fpbx php /var/www/fusionpbx/resources/uuid.php)"
user_salt="$(dex_fpbx php /var/www/fusionpbx/resources/uuid.php)"
password_hash="$(dex_fpbx php -r "echo md5('${user_salt}${ui_password}');" | tr -d '\r')"

echo "[db] inserting domain if missing"
dex_pg psql -v ON_ERROR_STOP=1 -U "$PSQL_USER" -d "$database_name" -h "$database_host" <<SQL
INSERT INTO v_domains (domain_uuid, domain_name, domain_enabled)
VALUES ('$domain_uuid', '$resolved_domain_name', 'true')
ON CONFLICT (domain_name) DO NOTHING;
SQL

echo "[db] creating admin user if missing"
dex_pg psql -v ON_ERROR_STOP=1 -U "$PSQL_USER" -d "$database_name" -h "$database_host" <<SQL
INSERT INTO v_users (user_uuid, domain_uuid, username, password, salt, user_enabled)
SELECT '$user_uuid', '$domain_uuid', '${system_username}', '${password_hash}', '${user_salt}', 'true'
WHERE NOT EXISTS (
  SELECT 1 FROM v_users WHERE username='${system_username}'
    AND (domain_uuid='${domain_uuid}' OR domain_uuid IS NULL)
);
SQL

echo "[db] adding user to superadmin"
group_uuid="$(dex_pg psql -tA -U "$PSQL_USER" -d "$database_name" -h "$database_host" \
  -c "SELECT group_uuid FROM v_groups WHERE group_name='superadmin' LIMIT 1;")"
[ -n "$group_uuid" ] || { echo "[error] superadmin group missing. Did schema load?"; exit 1; }
user_group_uuid="$(dex_fpbx php /var/www/fusionpbx/resources/uuid.php)"
dex_pg psql -v ON_ERROR_STOP=1 -U "$PSQL_USER" -d "$database_name" -h "$database_host" <<SQL
INSERT INTO v_user_groups (user_group_uuid, domain_uuid, group_name, group_uuid, user_uuid)
SELECT '$user_group_uuid', '$domain_uuid', 'superadmin', '$group_uuid', '$user_uuid'
WHERE NOT EXISTS (
  SELECT 1 FROM v_user_groups WHERE user_uuid='$user_uuid' AND group_uuid='$group_uuid'
);
SQL

# ------------- Apply defaults/permissions/services (quiet) -------------
run_upgrade_quiet defaults
run_upgrade_quiet permissions
run_upgrade_quiet services

# ------------- Optional: xml_cdr wiring inside FreeSWITCH -------------
echo "[fs] configuring xml_cdr credentials (best-effort)"
xml_user="$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | sed 's/[=+\/]//g')"
xml_pass="$(dd if=/dev/urandom bs=1 count=20 2>/dev/null | base64 | sed 's/[=+\/]//g')"
dex_fs bash -lc '
  set -e
  CONF=/etc/freeswitch/autoload_configs/xml_cdr.conf.xml
  [ -f "$CONF" ] || exit 0
  sed -i \
    -e s:"{v_http_protocol}:http:" \
    -e s:"{domain_name}:'"$database_host"':" \
    -e s:"{v_project_path}::" \
    -e s:"{v_user}:'"$xml_user"':" \
    -e s:"{v_pass}:'"$xml_pass"':" \
    "$CONF"
  true
' || echo "[fs] skipped xml_cdr edits (file missing)."

echo "[fs] reloading FreeSWITCH"
if dex_fs command -v fs_cli >/dev/null 2>&1; then
  dex_fs fs_cli -x 'reloadxml' || true
else
  docker compose restart "$FS_CTN" >/dev/null 2>&1 || true
fi

# ------------- Runtime dir for FusionPBX -------------
echo "[fpbx] making /var/run/fusionpbx"
dex_fpbx bash -lc "mkdir -p /var/run/fusionpbx && chown -R www-data:www-data /var/run/fusionpbx || true"

# ------------- Summary -------------
cat <<EOF

==== FusionPBX Installation Notes ====
 Login URL:        https://${resolved_domain_name}
 Username:         ${system_username}
 Password:         ${ui_password}

 Database host:    ${database_host}:${database_port}
 Database name:    ${database_name}
 Database user:    ${database_username}
 Database pass:    ${database_password}
======================================

EOF
