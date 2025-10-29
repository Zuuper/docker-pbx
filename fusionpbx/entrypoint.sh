#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf '[fusionpbx-setup] %s\n' "$*"; }
warn() { printf '[fusionpbx-setup][warn] %s\n' "$*" >&2; }
die()  { printf '[fusionpbx-setup][error] %s\n' "$*" >&2; exit 1; }

# Ensure config is present
CONFIG_PATH="${CONFIG_PATH:-/docker/config.sh}"
if [[ ! -r "$CONFIG_PATH" ]]; then
  die "Missing config.sh at $CONFIG_PATH. Mount or COPY it to /docker/config.sh"
fi

# shellcheck disable=SC1090
. "$CONFIG_PATH"

# Defaults if config forgot them
: "${system_branch:=master}"
: "${application_transcribe:=false}"
: "${application_speech:=false}"
: "${application_device_logs:=false}"
: "${application_dialplan_tools:=false}"
: "${application_edit:=false}"
: "${application_sip_trunks:=false}"

FUSIONPBX_DIR="${FUSIONPBX_DIR:-/var/www/fusionpbx}"

# Compute branch args
GIT_BRANCH_ARGS=()
if [[ "$system_branch" != "master" && -n "$system_branch" ]]; then
  log "Using version branch: $system_branch"
  GIT_BRANCH_ARGS=(-b "$system_branch")
else
  log "Using master branch"
fi

# Create cache dir and permissions
mkdir -p /var/cache/fusionpbx
chown -R www-data:www-data /var/cache/fusionpbx

# Helper: mark a repo path as safe for git (prevents 'dubious ownership' block)
git_safe_dir() {
  local d="$1"
  # Git doesn't support globs here; add exact paths.
  # Using --system so both root and www-data are covered.
  git config --system --add safe.directory "$d" || true
}

# Clone/update FusionPBX
# --- helpers ---
is_mount() { command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$1"; }
is_empty_dir() { [ -d "$1" ] && [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

# Ensure target dir exists
mkdir -p "$FUSIONPBX_DIR"

# Decide action based on what's there
if [[ -d "$FUSIONPBX_DIR/.git" ]]; then
  log "Existing FusionPBX repo detected; pulling latest"
  git_safe_dir "$FUSIONPBX_DIR"
  git -C "$FUSIONPBX_DIR" fetch --all --prune || true
  # Pick branch target
  TARGET_BRANCH="${system_branch:-master}"
  if [[ "$TARGET_BRANCH" == "master" ]]; then
    git -C "$FUSIONPBX_DIR" reset --hard origin/master || true
  else
    log "Using version branch: $TARGET_BRANCH"
    git -C "$FUSIONPBX_DIR" reset --hard "origin/$TARGET_BRANCH" || true
  fi
  chown -R www-data:www-data "$FUSIONPBX_DIR"

elif is_empty_dir "$FUSIONPBX_DIR"; then
  # Empty dir: safe to clone into
  if [[ "$system_branch" != "master" && -n "$system_branch" ]]; then
    log "Using version branch: $system_branch"
    GIT_BRANCH_ARGS=(-b "$system_branch")
  else
    log "Using master branch"
    GIT_BRANCH_ARGS=()
  fi
  log "Cloning FusionPBX into $FUSIONPBX_DIR"
  git clone --depth=1 "${GIT_BRANCH_ARGS[@]}" https://github.com/fusionpbx/fusionpbx.git "$FUSIONPBX_DIR"
  chown -R www-data:www-data "$FUSIONPBX_DIR"

else
  # Non-empty and not a git repo: do NOT try to wipe if it's a mount
  if is_mount "$FUSIONPBX_DIR"; then
    die "Target $FUSIONPBX_DIR is a mounted, non-empty, non-git directory. Refusing to overwrite. Clear it yourself or point FUSIONPBX_DIR elsewhere."
  else
    log "Non-mounted directory with junk; replacing contents"
    rm -rf "$FUSIONPBX_DIR"
    if [[ "$system_branch" != "master" && -n "$system_branch" ]]; then
      log "Using version branch: $system_branch"
      GIT_BRANCH_ARGS=(-b "$system_branch")
    else
      log "Using master branch"
      GIT_BRANCH_ARGS=()
    fi
    git clone --depth=1 "${GIT_BRANCH_ARGS[@]}" https://github.com/fusionpbx/fusionpbx.git "$FUSIONPBX_DIR"
    chown -R www-data:www-data "$FUSIONPBX_DIR"
  fi
fi


# Optional applications
apps_dir="$FUSIONPBX_DIR/app"
mkdir -p "$apps_dir"

clone_app() {
  local flag="$1" repo="$2" target="$3"
  local path="$apps_dir/$target"

  if [[ "${flag}" == "true" ]]; then
    if [[ ! -d "$path/.git" ]]; then
      log "Adding optional app: $target"
      git clone "$repo" "$path"
      chown -R www-data:www-data "$path"
      git_safe_dir "$path"
    else
      log "Optional app $target already present; pulling latest"
      git_safe_dir "$path"
      git -C "$path" fetch --all --prune || true
      git -C "$path" reset --hard origin/HEAD || true
      chown -R www-data:www-data "$path"
    fi
  else
    log "Optional app $target disabled"
  fi
}

clone_app "$application_transcribe"     https://github.com/fusionpbx/fusionpbx-app-transcribe.git     transcribe
clone_app "$application_speech"         https://github.com/fusionpbx/fusionpbx-app-speech.git         speech
clone_app "$application_device_logs"    https://github.com/fusionpbx/fusionpbx-app-device_logs.git    device_logs
clone_app "$application_dialplan_tools" https://github.com/fusionpbx/fusionpbx-app-dialplan_tools.git dialplan_tools
clone_app "$application_edit"           https://github.com/fusionpbx/fusionpbx-app-edit.git           edit
clone_app "$application_sip_trunks"     https://github.com/fusionpbx/fusionpbx-app-sip_trunks.git     sip_trunks

# Final ownership sweep
chown -R www-data:www-data "$FUSIONPBX_DIR"

log "FusionPBX setup complete."

# Ensure FusionPBX app log exists for Fail2ban
FUSIONPBX_LOG_DIR="${FUSIONPBX_LOG_DIR:-$FUSIONPBX_DIR/resources/log}"
FUSIONPBX_LOG_FILE="${FUSIONPBX_LOG_FILE:-$FUSIONPBX_LOG_DIR/fusionpbx.log}"

mkdir -p "$FUSIONPBX_LOG_DIR"
# create if missing so fail2ban's glob isn't empty
[ -f "$FUSIONPBX_LOG_FILE" ] || touch "$FUSIONPBX_LOG_FILE"

# sane perms so web app can write and fail2ban can read
chown -R www-data:www-data "$FUSIONPBX_LOG_DIR"
chmod 775 "$FUSIONPBX_LOG_DIR"
chmod 664 "$FUSIONPBX_LOG_FILE"

log "Ensured FusionPBX log at $FUSIONPBX_LOG_FILE"

exec docker-php-entrypoint php-fpm -F
