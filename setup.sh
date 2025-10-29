#!/usr/bin/env bash
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

# --------- Docker wrappers (Windows-safe) ----------
docker_cmd() {
  if [ "${OS:-}" = "Windows_NT" ]; then
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" docker "$@"
  else
    docker "$@"
  fi
}
docker_exec() { docker_cmd exec "$@"; }

# --------- locations ----------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE="docker compose"
COMPOSE_FILE="docker-compose.yaml"

# --------- sanity ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
need docker
$COMPOSE version >/dev/null 2>&1 || { echo "docker compose not available"; exit 1; }
[ -f "$COMPOSE_FILE" ] || { echo "$COMPOSE_FILE not found in $SCRIPT_DIR"; exit 1; }
[ -f ".env" ] || { echo ".env not found in $SCRIPT_DIR"; exit 1; }

# --------- load env (strip CRLF on Windows) ----------
set -a
sed -e 's/\r$//' .env > .env.unix
. ./.env.unix
rm -f .env.unix
set +a

# --------- defaults from your .env ----------
POSTGRES_DB="${POSTGRES_DB:-fusion_pbx_db}"
POSTGRES_USER="${POSTGRES_USER:-fusionpbx}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-12345678}"
POSTGRES_HOST="${POSTGRES_HOST:-pbx_postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

# Map to your original names/behavior
DOMAIN_NAME="${DOMAIN_NAME:-hostname}"   # hostname | ip_address | fqdn
SYSTEM_USERNAME="${ADMIN_USER:-admin}"
SYSTEM_PASSWORD="${ADMIN_PASS:-random}"

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}
[ "$SYSTEM_PASSWORD" = "random" ] && SYSTEM_PASSWORD="$(gen_secret)"

# Compose service/container names
SVC_DB="pbx_postgres"
SVC_WEB="pbx_fusionpbx"
NAME_WEB="pbx_fusion"
SVC_FS="pbx_freeswitch"
SVC_NGX="pbx_nginx"

echo "[setup] Starting Postgres…"
$COMPOSE -f "$COMPOSE_FILE" up -d "$SVC_DB"

echo "[setup] Waiting for Postgres health…"
for _ in {1..60}; do
  health="$(docker_cmd inspect --format='{{.State.Health.Status}}' "$SVC_DB" 2>/dev/null || echo "unknown")"
  [ "$health" = "healthy" ] && break
  sleep 2
done
[ "$health" = "healthy" ] || { echo "Postgres failed health"; docker_cmd logs --tail 100 "$SVC_DB" || true; exit 1; }
echo "[setup] Postgres healthy."

echo "[setup] Starting FusionPBX web…"
$COMPOSE -f "$COMPOSE_FILE" up -d "$SVC_WEB"
docker_cmd inspect "$NAME_WEB" >/dev/null 2>&1 || { echo "Container $NAME_WEB not found"; exit 1; }

# Detect FusionPBX install path (kept simple)
FUSIONPBX_DIR="/var/www/fusionpbx"
if ! docker_exec "$NAME_WEB" bash -lc "test -f '$FUSIONPBX_DIR/index.php'"; then
  for p in /var/www/html/fusionpbx /var/www/html /var/www; do
    if docker_exec "$NAME_WEB" bash -lc "test -f '$p/index.php'"; then FUSIONPBX_DIR="$p"; break; fi
  done
fi
docker_exec "$NAME_WEB" bash -lc "test -f '$FUSIONPBX_DIR/index.php'" || {
  echo "[setup] Could not find FusionPBX index.php in container"; exit 1; }
echo "[setup] FusionPBX detected at $FUSIONPBX_DIR"

echo "[setup] Bootstrapping FusionPBX (schema, defaults, user)…"
# IMPORTANT: -i so heredoc reaches bash -s in the container
docker_cmd exec -i \
  -e database_host="${POSTGRES_HOST}" \
  -e database_port="${POSTGRES_PORT}" \
  -e database_name="${POSTGRES_DB}" \
  -e database_username="${POSTGRES_USER}" \
  -e database_password="${POSTGRES_PASSWORD}" \
  -e domain_name="${DOMAIN_NAME}" \
  -e system_username="${SYSTEM_USERNAME}" \
  -e system_password="${SYSTEM_PASSWORD}" \
  -e FUSIONPBX_DIR="${FUSIONPBX_DIR}" \
  "$NAME_WEB" bash -s <<'IN_CONTAINER'
set -euo pipefail
log(){ printf "\n[finish-like] %s\n" "$*"; }

# Bring env in like the original finish.sh
database_host="${database_host:-pbx_postgres}"
database_port="${database_port:-5432}"
database_name="${database_name:-fusion_pbx_db}"
database_username="${database_username:-fusionpbx}"
database_password="${database_password:-random}"
domain_name="${domain_name:-hostname}"
system_username="${system_username:-admin}"
system_password="${system_password:-random}"
FUSIONPBX_DIR="${FUSIONPBX_DIR:-/var/www/fusionpbx}"

[ "$database_password" = "random" ] && database_password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
export PGPASSWORD="$database_password"

# --- PHP CLI detection / install if missing ---------------------------------
PHP=""
if command -v php >/dev/null 2>&1; then
  PHP="$(command -v php)"
elif [ -x /usr/local/bin/php ]; then
  PHP="/usr/local/bin/php"
elif [ -x /usr/bin/php ]; then
  PHP="/usr/bin/php"
fi

if [ -z "$PHP" ]; then
  log "php CLI not found; attempting to install…"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    (apt-get install -y php-cli || apt-get install -y php8.2-cli php8.2-common php8.2-opcache php8.2-readline || apt-get install -y php8.1-cli) || {
      echo "Failed to install php-cli via apt-get"; exit 1; }
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache php82-cli php82-session php82-opcache || apk add --no-cache php81-cli || {
      echo "Failed to install php-cli via apk"; exit 1; }
    command -v php >/dev/null 2>&1 || ln -sf "$(command -v php82 || true)" /usr/bin/php || true
    command -v php >/dev/null 2>&1 || ln -sf "$(command -v php81 || true)" /usr/bin/php || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y php-cli || dnf install -y php82-cli || {
      echo "Failed to install php-cli via dnf"; exit 1; }
  else
    echo "No package manager found to install php-cli. Please add php-cli to the image."
    exit 1
  fi

  if command -v php >/dev/null 2>&1; then
    PHP="$(command -v php)"
  elif [ -x /usr/local/bin/php ]; then
    PHP="/usr/local/bin/php"
  elif [ -x /usr/bin/php ]; then
    PHP="/usr/bin/php"
  else
    echo "php CLI still not found after install attempts"; exit 1
  fi
fi

PSQL=psql

# 1) add the config files (conf + php) like your original
log "Writing /etc/fusionpbx/config.conf & config.php"
mkdir -p /etc/fusionpbx
cat >/etc/fusionpbx/config.conf <<EOF
#database system settings
database.0.type = pgsql
database.0.host = ${database_host}
database.0.port = ${database_port}
database.0.sslmode = prefer
database.0.name = ${database_name}
database.0.username = ${database_username}
database.0.password = ${database_password}
EOF

cat >/etc/fusionpbx/config.php <<EOF
<?php
\$database_type = "pgsql";
\$database_host = "${database_host}";
\$database_port = "${database_port}";
\$database_name = "${database_name}";
\$database_username = "${database_username}";
\$database_password = "${database_password}";
\$db_type=\$database_type;\$db_host=\$database_host;\$db_port=\$database_port;\$db_name=\$database_name;\$db_username=\$database_username;\$db_password=\$database_password;
EOF
chmod 0640 /etc/fusionpbx/config.*

# 2) add the database schema (LOUD)
log "Applying database schema"
set +e
SCHEMA_OUT="$({ $PHP -d display_errors=1 "$FUSIONPBX_DIR/core/upgrade/upgrade.php" --schema; } 2>&1)"
RC=$?
set -e
printf "%s\n" "$SCHEMA_OUT"
[ $RC -eq 0 ] || { echo "Schema failed rc=$RC"; exit $RC; }

# 3) get the server hostname/ip (same logic as original)
if [ ".$domain_name" = ".hostname" ]; then domain_name="$(hostname -f 2>/dev/null || hostname)"; fi
if [ ".$domain_name" = ".ip_address" ]; then domain_name="$(hostname -I 2>/dev/null | awk '{print $1}')"; fi
[ -n "$domain_name" ] || domain_name="127.0.0.1"
log "Domain will be: $domain_name"

# 4) get the domain_uuid and insert (idempotent)
domain_uuid="$($PHP "$FUSIONPBX_DIR/resources/uuid.php")"
$PSQL --host="$database_host" --port="$database_port" --username="$database_username" \
  -d "$database_name" -c "
  INSERT INTO v_domains (domain_uuid, domain_name, domain_enabled)
  SELECT '$domain_uuid', '$domain_name', 'true'
  WHERE NOT EXISTS (
    SELECT 1 FROM v_domains WHERE domain_name = '$domain_name'
  );"

# 5) run app defaults
log "Running --defaults"
$PHP -d display_errors=1 "$FUSIONPBX_DIR/core/upgrade/upgrade.php" --defaults

# 6) add the user (salt + md5 like original)
user_uuid="$($PHP "$FUSIONPBX_DIR/resources/uuid.php")"
user_salt="$($PHP "$FUSIONPBX_DIR/resources/uuid.php")"
[ "$system_password" = "random" ] && user_password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)" || user_password="$system_password"
password_hash="$($PHP -r "echo md5('$user_salt$user_password');")"
log "Creating/ensuring user ${system_username}"
$PSQL --host="$database_host" --port="$database_port" --username="$database_username" -d "$database_name" -c "
  INSERT INTO v_users (user_uuid, domain_uuid, username, password, salt, user_enabled)
  SELECT '$user_uuid', '$domain_uuid', '$system_username', '$password_hash', '$user_salt', 'true'
  WHERE NOT EXISTS (
    SELECT 1 FROM v_users
    WHERE username = '$system_username' AND domain_uuid = '$domain_uuid'
  );"

# 7) add to superadmin
group_uuid="$($PSQL --host="$database_host" --port="$database_port" --username="$database_username" -d "$database_name" -qtAX -c "select group_uuid from v_groups where group_name = 'superadmin' limit 1;")"
[ -n "$group_uuid" ] || { echo "superadmin group missing"; exit 1; }
user_group_uuid="$($PHP "$FUSIONPBX_DIR/resources/uuid.php")"
$PSQL --host="$database_host" --port="$database_port" --username="$database_username" -d "$database_name" -c "
  INSERT INTO v_user_groups (user_group_uuid, domain_uuid, group_name, group_uuid, user_uuid)
  SELECT '$user_group_uuid', '$domain_uuid', 'superadmin', '$group_uuid', '$user_uuid'
  WHERE NOT EXISTS (
    SELECT 1 FROM v_user_groups
    WHERE user_uuid = '$user_uuid' AND group_uuid = '$group_uuid'
  );"

# 8) update permissions and services
log "Running --permissions"
$PHP -d display_errors=1 "$FUSIONPBX_DIR/core/upgrade/upgrade.php" --permissions || true
log "Running --services"
$PHP -d display_errors=1 "$FUSIONPBX_DIR/core/upgrade/upgrade.php" --services   || true

# 9) runtime dir
mkdir -p /var/run/fusionpbx && chown -R www-data:www-data /var/run/fusionpbx || true

# 10) summary (like your echoes)
echo ""
echo "Installation Notes."
echo "   Use a web browser to login."
echo "      domain name: https://$domain_name"
echo "      username: $system_username"
echo "      password: $user_password"
echo ""
echo "   If you need to login to a different domain then use username@domain."
echo "      username: $system_username@$domain_name"
echo ""

unset PGPASSWORD
IN_CONTAINER

# Start FreeSWITCH and nginx (separate containers)
echo "[setup] Starting FreeSWITCH…"
$COMPOSE -f "$COMPOSE_FILE" up -d "$SVC_FS" || true

echo "[setup] Starting nginx…"
$COMPOSE -f "$COMPOSE_FILE" up -d "$SVC_NGX" || true

# Final hint
if [ "${DOMAIN_NAME}" = "hostname" ]; then
  HOST_URL="$(hostname -f 2>/dev/null || hostname)"
elif [ "${DOMAIN_NAME}" = "ip_address" ]; then
  HOST_URL="$(hostname -I 2>/dev/null | awk '{print $1}')"
else
  HOST_URL="${DOMAIN_NAME}"
fi

echo
echo "FusionPBX is up. Open: https://${HOST_URL}  (443) or http://localhost:8080"
echo "Admin: ${SYSTEM_USERNAME}   Password: ${SYSTEM_PASSWORD}"
echo
