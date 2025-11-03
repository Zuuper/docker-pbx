#!/usr/bin/env bash
set -euo pipefail

# -------- settings you control via env or .env ----------
DOMAIN="${DOMAIN:-pbx.local}"

# If you know these, set them in compose/.env. If not, we’ll guess.
LOCAL_IP_V4="${LOCAL_IP_V4:-}"
EXTERNAL_SIP_IP="${EXTERNAL_SIP_IP:-auto-nat}"
EXTERNAL_RTP_IP="${EXTERNAL_RTP_IP:-auto-nat}"

# Ports
INTERNAL_SIP_PORT="${INTERNAL_SIP_PORT:-5060}"
EXTERNAL_SIP_PORT="${EXTERNAL_SIP_PORT:-5080}"
RTP_START="${RTP_START:-30000}"
RTP_END="${RTP_END:-30100}"

# ACL for internal profile (domains|localnet.auto)
INBOUND_ACL="${INBOUND_ACL:-domains}"

# ESL / FS CLI password
ESL_PASSWORD="${ESL_PASSWORD:-verysecret}"

# Optional codec lists
GLOBAL_CODECS="${GLOBAL_CODECS:-opus,PCMU,PCMA,G722}"
OUTBOUND_CODECS="${OUTBOUND_CODECS:-opus,PCMU,PCMA,G722}"

# Paths inside the container (you mounted ./freeswitch/defaults -> /etc/freeswitch)
FS_ETC="${FS_ETC:-/etc/freeswitch}"
VARS_XML="$FS_ETC/vars.xml"
INTERNAL_XML="$FS_ETC/sip_profiles/internal.xml"
EXTERNAL_XML="$FS_ETC/sip_profiles/external.xml"
ESL_XML="$FS_ETC/autoload_configs/event_socket.conf.xml"
SOFIA_XML="$FS_ETC/autoload_configs/sofia.conf.xml"

echo ${VARS_XML}

# -------------------------------------------------------

# Helper: find a local IP if not provided
detect_local_ip() {
  # Try to get the IP used to reach the Internet. Works in Docker too.
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}'
  elif command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

if [[ -z "$LOCAL_IP_V4" ]]; then
  LOCAL_IP_V4="$(detect_local_ip || true)"
fi
: "${LOCAL_IP_V4:=127.0.0.1}"  # last resort, but we’ll bind on auto anyway

# Ensure xmlstarlet exists (nice) or we’ll fall back to sed (fine)
have_xmlstarlet=0
if command -v xmlstarlet >/dev/null 2>&1; then
  have_xmlstarlet=1
fi

edit_xml() {
  local file="$1" xpath="$2" value="$3"
  if [[ $have_xmlstarlet -eq 1 ]]; then
    xmlstarlet ed -L -u "$xpath" -v "$value" "$file" 2>/dev/null \
      || xmlstarlet ed -L -s "$(dirname "$xpath")" -t attr -n data -v "$value" "$file"
  else
    # crude but effective: update the data="key=..." lines
    local key="${value%%=*}"
    key="${key#*=}" # not used here, sed path below
    # replace matching data="name=..." regardless of current value
    local name="${value%%=*}"
    name="${name%=*}" # meh; sed fallback only for vars.xml lines we control below
    :
  fi
}

# ---------- Patch vars.xml ----------
if [[ ! -f "$VARS_XML" ]]; then
  echo "ERROR: $VARS_XML not found. Mount your config directory correctly." >&2
  exit 1
fi

if [[ $have_xmlstarlet -eq 1 ]]; then
  xmlstarlet ed -L \
    -u "/document/section/X-PRE-PROCESS[@data^='internal_sip_port=']/@data" -v "internal_sip_port=$INTERNAL_SIP_PORT" \
    -u "/document/section/X-PRE-PROCESS[@data^='external_sip_port=']/@data" -v "external_sip_port=$EXTERNAL_SIP_PORT" \
    -u "/document/section/X-PRE-PROCESS[@data^='domain=']/@data" -v "domain=$DOMAIN" \
    -u "/document/section/X-PRE-PROCESS[@data^='local_ip_v4=']/@data" -v "local_ip_v4=$LOCAL_IP_V4" \
    -u "/document/section/X-PRE-PROCESS[@data^='external_sip_ip=']/@data" -v "external_sip_ip=$EXTERNAL_SIP_IP" \
    -u "/document/section/X-PRE-PROCESS[@data^='external_rtp_ip=']/@data" -v "external_rtp_ip=$EXTERNAL_RTP_IP" \
    -u "/document/section/X-PRE-PROCESS[@data^='rtp_start_port=']/@data" -v "rtp_start_port=$RTP_START" \
    -u "/document/section/X-PRE-PROCESS[@data^='rtp_end_port=']/@data" -v "rtp_end_port=$RTP_END" \
    -u "/document/section/X-PRE-PROCESS[@data^='event_socket_password=']/@data" -v "event_socket_password=$ESL_PASSWORD" \
    -u "/document/section/X-PRE-PROCESS[@data^='global_codec_prefs=']/@data" -v "global_codec_prefs=$GLOBAL_CODECS" \
    -u "/document/section/X-PRE-PROCESS[@data^='outbound_codec_prefs=']/@data" -v "outbound_codec_prefs=$OUTBOUND_CODECS" \
    "$VARS_XML"
else
  # sed fallback for the exact keys we expect
  sed -i \
    -e "s#data=\"internal_sip_port=[^\"]*\"#data=\"internal_sip_port=$INTERNAL_SIP_PORT\"#g" \
    -e "s#data=\"external_sip_port=[^\"]*\"#data=\"external_sip_port=$EXTERNAL_SIP_PORT\"#g" \
    -e "s#data=\"domain=[^\"]*\"#data=\"domain=$DOMAIN\"#g" \
    -e "s#data=\"local_ip_v4=[^\"]*\"#data=\"local_ip_v4=$LOCAL_IP_V4\"#g" \
    -e "s#data=\"external_sip_ip=[^\"]*\"#data=\"external_sip_ip=$EXTERNAL_SIP_IP\"#g" \
    -e "s#data=\"external_rtp_ip=[^\"]*\"#data=\"external_rtp_ip=$EXTERNAL_RTP_IP\"#g" \
    -e "s#data=\"rtp_start_port=[^\"]*\"#data=\"rtp_start_port=$RTP_START\"#g" \
    -e "s#data=\"rtp_end_port=[^\"]*\"#data=\"rtp_end_port=$RTP_END\"#g" \
    -e "s#data=\"event_socket_password=[^\"]*\"#data=\"event_socket_password=$ESL_PASSWORD\"#g" \
    -e "s#data=\"global_codec_prefs=[^\"]*\"#data=\"global_codec_prefs=$GLOBAL_CODECS\"#g" \
    -e "s#data=\"outbound_codec_prefs=[^\"]*\"#data=\"outbound_codec_prefs=$OUTBOUND_CODECS\"#g" \
    "$VARS_XML"
fi

# ---------- Patch internal.xml ----------
if [[ -f "$INTERNAL_XML" ]]; then
  # Bind to whatever the container actually has; advertise real externals
  sed -i \
    -e "s#name=\"sip-ip\" value=\"[^\"]*\"#name=\"sip-ip\" value=\"0.0.0.0\"#g" \
    -e "s#name=\"rtp-ip\" value=\"[^\"]*\"#name=\"rtp-ip\" value=\"0.0.0.0\"#g" \
    -e "s#name=\"sip-port\" value=\"[^\"]*\"#name=\"sip-port\" value=\"$INTERNAL_SIP_PORT\"#g" \
    -e "s#name=\"ext-sip-ip\" value=\"[^\"]*\"#name=\"ext-sip-ip\" value=\"\$\${external_sip_ip}\"#g" \
    -e "s#name=\"ext-rtp-ip\" value=\"[^\"]*\"#name=\"ext-rtp-ip\" value=\"\$\${external_rtp_ip}\"#g" \
    -e "s#name=\"apply-inbound-acl\" value=\"[^\"]*\"#name=\"apply-inbound-acl\" value=\"$INBOUND_ACL\"#g" \
    "$INTERNAL_XML" || true

  # Ensure the domain element exists and matches
  if ! grep -q "<domain name=" "$INTERNAL_XML"; then
    sed -i "s#<settings>#</settings>#; t; s#<profile name=\"internal\">#<profile name=\"internal\">\n  <domains>\n    <domain name=\"\$\${domain}\"/>\n  </domains>#" "$INTERNAL_XML"
  fi
fi

# ---------- Patch external.xml (if you expose it) ----------
if [[ -f "$EXTERNAL_XML" ]]; then
  sed -i \
    -e "s#name=\"sip-port\" value=\"[^\"]*\"#name=\"sip-port\" value=\"$EXTERNAL_SIP_PORT\"#g" \
    -e "s#name=\"sip-ip\" value=\"[^\"]*\"#name=\"sip-ip\" value=\"0.0.0.0\"#g" \
    -e "s#name=\"rtp-ip\" value=\"[^\"]*\"#name=\"rtp-ip\" value=\"0.0.0.0\"#g" \
    -e "s#name=\"ext-sip-ip\" value=\"[^\"]*\"#name=\"ext-sip-ip\" value=\"\$\${external_sip_ip}\"#g" \
    -e "s#name=\"ext-rtp-ip\" value=\"[^\"]*\"#name=\"ext-rtp-ip\" value=\"\$\${external_rtp_ip}\"#g" \
    "$EXTERNAL_XML" || true
fi

# ---------- ESL password ----------
if [[ -f "$ESL_XML" ]]; then
  sed -i \
    -e "s#name=\"password\" value=\"[^\"]*\"#name=\"password\" value=\"$ESL_PASSWORD\"#g" \
    "$ESL_XML" || true
fi

# ---------- wake up sofia if this is a reloadable container ----------
if command -v fs_cli >/dev/null 2>&1; then
  fs_cli -x 'reloadxml' || true
fi

echo "Config applied:"
echo "  DOMAIN=$DOMAIN"
echo "  LOCAL_IP_V4=$LOCAL_IP_V4"
echo "  EXTERNAL_SIP_IP=$EXTERNAL_SIP_IP"
echo "  EXTERNAL_RTP_IP=$EXTERNAL_RTP_IP"
echo "  INTERNAL_SIP_PORT=$INTERNAL_SIP_PORT  EXTERNAL_SIP_PORT=$EXTERNAL_SIP_PORT"
echo "  RTP=$RTP_START-$RTP_END"
echo "  INBOUND_ACL=$INBOUND_ACL"

# Exec whatever was passed (should be freeswitch)
exec "$@"
