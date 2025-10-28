#!/usr/bin/env bash
set -Eeuo pipefail

# ----- tiny logger -----
log() { printf '[iptables-init] %s\n' "$*"; }
warn() { printf '[iptables-init][warn] %s\n' "$*" >&2; }
die() { printf '[iptables-init][error] %s\n' "$*" >&2; exit 1; }

# ----- detect codename -----
OS_CODENAME="${os_codename:-}"
if [[ -z "${OS_CODENAME}" ]]; then
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_CODENAME="${VERSION_CODENAME:-bookworm}"
  else
    OS_CODENAME="bookworm"
  fi
fi
log "Detected Debian codename: ${OS_CODENAME}"

# Idempotency marker to avoid duplicate rules on restarts
MARKER="/var/run/iptables.applied"

# ----- install prerequisites -----
export DEBIAN_FRONTEND=noninteractive

# Switch to legacy iptables on affected releases
case "${OS_CODENAME}" in
  buster|bullseye|bookworm)
    if command -v update-alternatives >/dev/null 2>&1; then
      update-alternatives --set iptables /usr/sbin/iptables-legacy || true
      update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true
      log "Using iptables-legacy"
    fi
    ;;
  *)
    warn "Unknown codename ${OS_CODENAME}; leaving iptables alternatives alone"
    ;;
esac

# If already applied, bail early (useful if the container restarts)
if [[ -f "${MARKER}" ]]; then
  log "Rules already applied; skipping and staying alive."
  exec tail -f /dev/null
fi

log "Removing/disabling UFW if present"
ufw reset || true
ufw disable || true
apt-get remove -y ufw || true

# Best-effort removal of UFW chains; ignore if they don’t exist
for CH in \
  ufw-after-forward ufw-after-input ufw-after-logging-forward \
  ufw-after-logging-input ufw-after-logging-output ufw-after-output \
  ufw-before-forward ufw-before-input ufw-before-logging-forward \
  ufw-before-logging-input ufw-before-logging-output ufw-before-output \
  ufw-reject-forward ufw-reject-input ufw-reject-output \
  ufw-track-forward ufw-track-input ufw-track-output
do
  iptables --delete-chain "$CH" 2>/dev/null || true
done

log "Flushing base policies"
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F

log "Applying SIP/RTP and service rules"
# loopback and established
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# drop known scanners on SIP ports 5060–5091
for proto in udp tcp; do
  iptables -A INPUT -j DROP -p "$proto" --dport 5060:5091 -m string --string "friendly-scanner" --algo bm --icase
  iptables -A INPUT -j DROP -p "$proto" --dport 5060:5091 -m string --string "sipcli/" --algo bm --icase
  iptables -A INPUT -j DROP -p "$proto" --dport 5060:5091 -m string --string "VaxSIPUserAgent/" --algo bm --icase
  iptables -A INPUT -j DROP -p "$proto" --dport 5060:5091 -m string --string "pplsip" --algo bm --icase
  iptables -A INPUT -j DROP -p "$proto" --dport 5060:5091 -m string --string "system " --algo bm --icase
  iptables -A INPUT -j DROP -p "$proto" --dport 5060:5091 -m string --string "exec." --algo bm --icase
  iptables -A INPUT -j DROP -p "$proto" --dport 5060:5091 -m string --string "multipart/mixed;boundary" --algo bm --icase
done

# allow service ports
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 7443 -j ACCEPT
iptables -A INPUT -p tcp --dport 5060:5091 -j ACCEPT
iptables -A INPUT -p udp --dport 5060:5091 -j ACCEPT
iptables -A INPUT -p udp --dport 16384:32768 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT -p udp --dport 1194 -j ACCEPT

# DSCP marking for RTP and SIP
iptables -t mangle -A OUTPUT -p udp -m udp --sport 16384:32768 -j DSCP --set-dscp 46
iptables -t mangle -A OUTPUT -p udp -m udp --sport 5060:5091 -j DSCP --set-dscp 26
iptables -t mangle -A OUTPUT -p tcp -m tcp --sport 5060:5091 -j DSCP --set-dscp 26

# default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

log "Saving rules to /etc/iptables/rules.v4"
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 || warn "iptables-save failed; continuing"

# Mark as applied
touch "${MARKER}"
log "Firewall rules applied."

# Keep the container alive (sidecar style)
exec tail -f /dev/null
