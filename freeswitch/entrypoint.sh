#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint][error] %s\n' "$*" >&2; exit 1; }

# Binaries and paths
FS_BIN="${FS_BIN:-/usr/bin/freeswitch}"

FS_ETC="${FS_ETC:-/etc/freeswitch}"
FS_VAR="${FS_VAR:-/var/lib/freeswitch}"
FS_LOG="${FS_LOG:-/var/log/freeswitch}"
FS_RUN="/var/run/freeswitch"

FS_USER="${FS_USER:-www-data}"
FS_GROUP="${FS_GROUP:-www-data}"

# Where to seed from. We’ll pick the first that actually exists.
# 1) explicit FS_CONF_SOURCE
# 2) packaged samples
# 3) legacy path you might have used in your Dockerfile
CANDIDATES=()
[[ -n "${FS_CONF_SOURCE:-}" ]] && CANDIDATES+=("${FS_CONF_SOURCE}")
CANDIDATES+=("/usr/share/freeswitch/conf" "/opt/freeswitch/defaults")

command -v "$FS_BIN" >/dev/null || die "freeswitch not found at ${FS_BIN}"

mkdir -p "$FS_ETC" "$FS_VAR" "$FS_LOG" "$FS_RUN"

# Seed config once if empty
if [[ -z "$(ls -A "$FS_ETC" 2>/dev/null)" ]]; then
  for src in "${CANDIDATES[@]}"; do
    if [[ -d "$src" ]]; then
      log "Seeding config: ${src} -> ${FS_ETC}"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a "${src}/" "${FS_ETC}/"
      else
        cp -a "${src}/." "${FS_ETC}/"
      fi
      break
    fi
  done

  if [[ -z "$(ls -A "$FS_ETC" 2>/dev/null)" ]]; then
    die "No FreeSWITCH config found to seed and ${FS_ETC} is empty. Mount a conf or bake one into the image."
  fi
fi

# Ownership and permissions FreeSWITCH expects
if id -u "$FS_USER" >/dev/null 2>&1 && getent group "$FS_GROUP" >/dev/null 2>&1; then
  chown -R "$FS_USER:$FS_GROUP" "$FS_ETC" "$FS_VAR" "$FS_LOG" "$FS_RUN" || true
fi
chmod 2775 "$FS_VAR" "$FS_RUN" || true
find "$FS_VAR" -type d -exec chmod 2775 {} + 2>/dev/null || true
find "$FS_VAR" -type f -exec chmod 664 {} + 2>/dev/null || true

ulimit -n 200000 || true

# Graceful shutdown
_term() {
  log "Shutdown signal received; asking FreeSWITCH to exit."
  if command -v fs_cli >/dev/null 2>&1; then fs_cli -x 'shutdown' || true; fi
  sleep 2
  pkill -TERM -x freeswitch || true
}
trap _term TERM INT

# Optional noisy diagnostics
if [[ "${FS_DEBUG:-0}" == "1" ]]; then
  log "DEBUG on. Paths and ownership:"
  ls -ld "$FS_ETC" "$FS_VAR" "$FS_LOG" "$FS_RUN" || true
  find "$FS_ETC" -maxdepth 1 -type f -name '*.xml' -print | head -n 20 || true
fi

# Start FreeSWITCH
log "Starting FreeSWITCH"
if [[ "${FS_FOREGROUND:-0}" == "1" ]]; then
  # Foreground, no daemon, for debugging
  exec su -s /bin/bash -c "\"$FS_BIN\" -u \"$FS_USER\" -g \"$FS_GROUP\" -nf -nonat" "$FS_USER"
else
  # Normal: wait for ready, then background
  exec "$FS_BIN" -u "$FS_USER" -g "$FS_GROUP" -ncwait -nonat
fi
