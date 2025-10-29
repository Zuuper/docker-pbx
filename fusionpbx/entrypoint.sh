#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf '[fusionpbx] %s\n' "$*"; }
warn() { printf '[fusionpbx][warn] %s\n' "$*" >&2; }
die()  { printf '[fusionpbx][error] %s\n' "$*" >&2; exit 1; }

# ---- Config (env first, optional /docker/config.sh second) ----
[ -r "${CONFIG_PATH:-/docker/config.sh}" ] && . "${CONFIG_PATH:-/docker/config.sh}" || true

: "${FUSIONPBX_DIR:=/var/www/fusionpbx}"
: "${SYSTEM_BRANCH:=master}"

: "${DATABASE_HOST:=pbx_postgres}"
: "${DATABASE_PORT:=5432}"
: "${DATABASE_NAME:=fusionpbx}"
: "${DATABASE_USERNAME:=fusionpbx}"
: "${DATABASE_PASSWORD:=12345678}"

# cookie secure only once you have TLS in front
: "${FUSIONPBX_COOKIE_SECURE:=false}"

# ---- Clone/update FusionPBX repo ----
mkdir -p "$FUSIONPBX_DIR"
if [[ -d "$FUSIONPBX_DIR/.git" ]]; then
  log "Updating FusionPBX repo..."
  git -C "$FUSIONPBX_DIR" fetch --all --prune || true
  if [[ "$SYSTEM_BRANCH" = "master" ]]; then
    git -C "$FUSIONPBX_DIR" reset --hard origin/master || true
  else
    git -C "$FUSIONPBX_DIR" reset --hard "origin/$SYSTEM_BRANCH" || true
  fi
else
  log "Cloning FusionPBX ($SYSTEM_BRANCH) into $FUSIONPBX_DIR"
  if [[ "$SYSTEM_BRANCH" = "master" ]]; then
    git clone --depth=1 https://github.com/fusionpbx/fusionpbx.git "$FUSIONPBX_DIR"
  else
    git clone --depth=1 -b "$SYSTEM_BRANCH" https://github.com/fusionpbx/fusionpbx.git "$FUSIONPBX_DIR"
  fi
fi
chown -R www-data:www-data "$FUSIONPBX_DIR"

# ---- Write configs (no schema here) ----
mkdir -p /etc/fusionpbx

if [[ -f /etc/fusionpbx/config.conf ]]; then
  log "Found existing /etc/fusionpbx/config.conf; leaving as-is"
else
  if [[ -r /docker/config.conf ]]; then
    log "Using mounted /docker/config.conf"
    cp /docker/config.conf /etc/fusionpbx/config.conf
  else
    log "Generating /etc/fusionpbx/config.conf from env"
    cat >/etc/fusionpbx/config.conf <<CONF
#database system settings
database.0.type = pgsql
database.0.host = ${DATABASE_HOST:-pbx_postgres}
database.0.port = ${DATABASE_PORT:-5432}
database.0.sslmode = prefer
database.0.name = ${DATABASE_NAME:-fusionpbx}
database.0.username = ${DATABASE_USERNAME:-fusionpbx}
database.0.password = ${DATABASE_PASSWORD:-changeme}
CONF
  fi

  # Always fill placeholders if present
  sed -i \
    -e "s:{database_host}:${DATABASE_HOST:-pbx_postgres}:g" \
    -e "s:{database_port}:${DATABASE_PORT:-5432}:g" \
    -e "s:{database_name}:${DATABASE_NAME:-fusionpbx}:g" \
    -e "s:{database_username}:${DATABASE_USERNAME:-fusionpbx}:g" \
    -e "s:{database_password}:${DATABASE_PASSWORD:-changeme}:g" \
    /etc/fusionpbx/config.conf || true

  # Also write config.php for branches that need it
  cat >/etc/fusionpbx/config.php <<PHP
<?php
\$database_type = "pgsql";
\$database_host = "${DATABASE_HOST:-pbx_postgres}";
\$database_port = "${DATABASE_PORT:-5432}";
\$database_name = "${DATABASE_NAME:-fusionpbx}";
\$database_username = "${DATABASE_USERNAME:-fusionpbx}";
\$database_password = "${DATABASE_PASSWORD:-changeme}";
\$db_type = \$database_type; \$db_host = \$database_host; \$db_port = \$database_port; \$db_name = \$database_name; \$db_username = \$database_username; \$db_password = \$database_password;
PHP

  tr -d '\r' </etc/fusionpbx/config.conf > /etc/fusionpbx/config.conf.tmp && mv /etc/fusionpbx/config.conf.tmp /etc/fusionpbx/config.conf
  tr -d '\r' </etc/fusionpbx/config.php  > /etc/fusionpbx/config.php.tmp  && mv /etc/fusionpbx/config.php.tmp  /etc/fusionpbx/config.php
  chown www-data:www-data /etc/fusionpbx/config.* || true
  chmod 640 /etc/fusionpbx/config.* || true
fi


# ---- App log dir (handy for fail2ban later) ----
LOGDIR="${FUSIONPBX_LOG_DIR:-$FUSIONPBX_DIR/resources/log}"
mkdir -p "$LOGDIR"
touch "$LOGDIR/fusionpbx.log" || true
chown -R www-data:www-data "$LOGDIR"
chmod 775 "$LOGDIR" || true

# No schema/defaults/permissions/services here.
exec docker-php-entrypoint php-fpm -F
