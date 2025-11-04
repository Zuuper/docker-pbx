#!/usr/bin/env bash
set -euo pipefail

# ===================== env knobs (defaults) =====================
DOMAIN="${DOMAIN:-pbx.local}"

LOCAL_IP_V4="${LOCAL_IP_V4:-}"
EXTERNAL_SIP_IP="${EXTERNAL_SIP_IP:-auto-nat}"
EXTERNAL_RTP_IP="${EXTERNAL_RTP_IP:-auto-nat}"

INTERNAL_SIP_PORT="${INTERNAL_SIP_PORT:-5060}"
EXTERNAL_SIP_PORT="${EXTERNAL_SIP_PORT:-5080}"
RTP_START="${RTP_START:-30000}"
RTP_END="${RTP_END:-30100}"

INBOUND_ACL="${INBOUND_ACL:-domains}"

# Event Socket
ESL_PASSWORD="${ESL_PASSWORD:-ClueCon}"
ESL_LISTEN_IP="${ESL_LISTEN_IP:-127.0.0.1}"
ESL_LISTEN_PORT="${ESL_LISTEN_PORT:-8021}"
ESL_APPLY_ACL="${ESL_APPLY_ACL:-esl}"
EXTRA_ESL_ALLOW_CIDRS="${EXTRA_ESL_ALLOW_CIDRS:-}"

GLOBAL_CODECS="${GLOBAL_CODECS:-opus,PCMU,PCMA,G722}"
OUTBOUND_CODECS="${OUTBOUND_CODECS:-opus,PCMU,PCMA,G722}"

# FusionPBX Lua scripts BASE (final path = ${SCRIPTS_DIR}/resources/scripts)
SCRIPTS_DIR="${SCRIPTS_DIR:-/var/www/fusionpbx/app/switch}"

ENABLE_EXTERNAL="${ENABLE_EXTERNAL:-1}"
ENABLE_INTERNAL="${ENABLE_INTERNAL:-1}"

# ===================== paths =====================
FS_ETC="${FS_ETC:-/etc/freeswitch}"
VARS_XML="$FS_ETC/vars.xml"
INTERNAL_XML="$FS_ETC/sip_profiles/internal.xml"
EXTERNAL_XML="$FS_ETC/sip_profiles/external.xml"
ESL_XML="$FS_ETC/autoload_configs/event_socket.conf.xml"
SOFIA_XML="$FS_ETC/autoload_configs/sofia.conf.xml"
MODULES_XML="$FS_ETC/autoload_configs/modules.conf.xml"
ACL_XML="$FS_ETC/autoload_configs/acl.conf.xml"
LUA_XML="$FS_ETC/autoload_configs/lua.conf.xml"

# ===================== helpers =====================
fail(){ echo "ERROR: $*" >&2; exit 1; }
sed_escape(){ printf '%s' "$1" | sed 's/[\/&]/\\&/g'; }

detect_local_ip() {
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}'
  elif command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

detect_bridge_cidr() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show dev eth0 2>/dev/null | awk '/inet /{print $2; exit}'
  fi
}

[[ -f "$VARS_XML" ]] || fail "$VARS_XML not found. Mount /etc/freeswitch correctly and seed configs."

if [[ -z "${LOCAL_IP_V4}" ]]; then
  LOCAL_IP_V4="$(detect_local_ip || true)"
fi
: "${LOCAL_IP_V4:=127.0.0.1}"

BRIDGE_CIDR="$(detect_bridge_cidr || true)"
: "${BRIDGE_CIDR:=}"

have_xmlstarlet=0
command -v xmlstarlet >/dev/null 2>&1 && have_xmlstarlet=1

FINAL_SCRIPTS="${SCRIPTS_DIR}/resources/scripts"
DOC_ROOT="/var/www/fusionpbx"

# ===================== patch vars.xml =====================
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
    -u "/document/section/X-PRE-PROCESS[@data^='document_root=']/@data" -v "document_root=${DOC_ROOT}" \
    "$VARS_XML"

  if grep -q 'scripts_dir=' "$VARS_XML"; then
    xmlstarlet ed -L \
      -u "/document/section/X-PRE-PROCESS[contains(@data,'scripts_dir=')]/@data" \
      -v "scripts_dir=${FINAL_SCRIPTS}" \
      "$VARS_XML"
  else
   sed -i "0,/<\/section>/s|</section>|<X-PRE-PROCESS data=\"scripts_dir=${FINAL_SCRIPTS}\" />\n</section>|" "$VARS_XML"
  fi
else
  sd_dom=$(sed_escape "$DOMAIN")
  sd_lip=$(sed_escape "$LOCAL_IP_V4")
  sd_esip=$(sed_escape "$EXTERNAL_SIP_IP")
  sd_erip=$(sed_escape "$EXTERNAL_RTP_IP")
  sd_scripts=$(sed_escape "$FINAL_SCRIPTS")
  sed -i \
    -e "s#data=\"internal_sip_port=[^\"]*\"#data=\"internal_sip_port=${INTERNAL_SIP_PORT}\"#g" \
    -e "s#data=\"external_sip_port=[^\"]*\"#data=\"external_sip_port=${EXTERNAL_SIP_PORT}\"#g" \
    -e "s#data=\"domain=[^\"]*\"#data=\"domain=${sd_dom}\"#g" \
    -e "s#data=\"local_ip_v4=[^\"]*\"#data=\"local_ip_v4=${sd_lip}\"#g" \
    -e "s#data=\"external_sip_ip=[^\"]*\"#data=\"external_sip_ip=${sd_esip}\"#g" \
    -e "s#data=\"external_rtp_ip=[^\"]*\"#data=\"external_rtp_ip=${sd_erip}\"#g" \
    -e "s#data=\"rtp_start_port=[^\"]*\"#data=\"rtp_start_port=${RTP_START}\"#g" \
    -e "s#data=\"rtp_end_port=[^\"]*\"#data=\"rtp_end_port=${RTP_END}\"#g" \
    -e "s#data=\"event_socket_password=[^\"]*\"#data=\"event_socket_password=${ESL_PASSWORD}\"#g" \
    -e "s#data=\"global_codec_prefs=[^\"]*\"#data=\"global_codec_prefs=${GLOBAL_CODECS}\"#g" \
    -e "s#data=\"outbound_codec_prefs=[^\"]*\"#data=\"outbound_codec_prefs=${OUTBOUND_CODECS}\"#g" \
    "$VARS_XML"
  if grep -q 'document_root=' "$VARS_XML"; then
    sed -i "s#document_root=[^\"]*#document_root=${DOC_ROOT}#g" "$VARS_XML"
  else
    sed -i "0,/<\/section>/s|</section>|<X-PRE-PROCESS data=\"document_root=/var/www/fusionpbx\" />\n</section>|" "$VARS_XML"
  fi
  if grep -q 'scripts_dir=' "$VARS_XML"; then
    sed -i "s#scripts_dir=[^\"]*#scripts_dir=${sd_scripts}#g" "$VARS_XML"
  else
    sed -i "0,/<\/section>/s|</section>|<X-PRE-PROCESS data=\"scripts_dir=${FINAL_SCRIPTS}\" />\n</section>|" "$VARS_XML"
  fi
fi

# ===================== ensure sofia includes sip_profiles =====================
if [[ -f "$SOFIA_XML" ]] && ! grep -q 'sip_profiles/\*\.xml' "$SOFIA_XML"; then
  sed -i '/<\/configuration>/i \  <X-PRE-PROCESS cmd="include" data="sip_profiles/*.xml"/>' "$SOFIA_XML"
fi

# ===================== internal profile (enable + patch) =====================
if [[ "$ENABLE_INTERNAL" == "1" ]]; then
  if [[ -f "${INTERNAL_XML}.noload" && ! -f "$INTERNAL_XML" ]]; then
    mv "${INTERNAL_XML}.noload" "$INTERNAL_XML"
    echo "[config] Enabled internal profile (removed .noload)"
  fi
fi

if [[ -f "$INTERNAL_XML" ]]; then
  sed -i \
    -e 's#name="sip-ip" value="[^"]*"#name="sip-ip" value="0.0.0.0"#g' \
    -e 's#name="rtp-ip" value="[^"]*"#name="rtp-ip" value="0.0.0.0"#g' \
    -e "s#name=\"sip-port\" value=\"[^\"]*\"#name=\"sip-port\" value=\"${INTERNAL_SIP_PORT}\"#g" \
    -e 's#name="ext-sip-ip" value="[^"]*"#name="ext-sip-ip" value="$${external_sip_ip}"#g' \
    -e 's#name="ext-rtp-ip" value="[^"]*"#name="ext-rtp-ip" value="$${external_rtp_ip}"#g' \
    -e "s#name=\"apply-inbound-acl\" value=\"[^\"]*\"#name=\"apply-inbound-acl\" value=\"${INBOUND_ACL}\"#g" \
    "$INTERNAL_XML" || true
  if ! grep -q '<domain name=' "$INTERNAL_XML"; then
    sed -i 's#<profile name="internal">#<profile name="internal">\n  <domains>\n    <domain name="$${domain}"/>\n  </domains>#' "$INTERNAL_XML"
  fi
fi

# ===================== external profile (enable + patch) =====================
if [[ "$ENABLE_EXTERNAL" == "1" ]]; then
  if [[ -f "${EXTERNAL_XML}.noload" && ! -f "$EXTERNAL_XML" ]]; then
    mv "${EXTERNAL_XML}.noload" "$EXTERNAL_XML"
    echo "[config] Enabled external profile (removed .noload)"
  fi
fi

if [[ -f "$EXTERNAL_XML" ]]; then
  sed -i \
    -e "s#name=\"sip-port\" value=\"[^\"]*\"#name=\"sip-port\" value=\"${EXTERNAL_SIP_PORT}\"#g" \
    -e 's#name="sip-ip" value="[^"]*"#name="sip-ip" value="0.0.0.0"#g' \
    -e 's#name="rtp-ip" value="[^"]*"#name="rtp-ip" value="0.0.0.0"#g' \
    -e 's#name="ext-sip-ip" value="[^"]*"#name="ext-sip-ip" value="$${external_sip_ip}"#g' \
    -e 's#name="ext-rtp-ip" value="[^"]*"#name="ext-rtp-ip" value="$${external_rtp_ip}"#g' \
    "$EXTERNAL_XML" || true
fi

# ===================== event socket: modules + config + ACL =====================
# Ensure mod_event_socket autoloads
if [[ -f "$MODULES_XML" ]] && ! grep -q 'mod_event_socket' "$MODULES_XML"; then
  sed -i '/<\/modules>/i \  <load module="mod_event_socket"/>' "$MODULES_XML"
fi

# Ensure mod_lua autoloads
if [[ -f "$MODULES_XML" ]] && ! grep -q 'mod_lua' "$MODULES_XML"; then
  sed -i '/<\/modules>/i \  <load module="mod_lua"/>' "$MODULES_XML"
fi

# Configure event_socket.conf.xml
if [[ -f "$ESL_XML" ]]; then
  sed -i \
    -e "s#name=\"enabled\" value=\"[^\"]*\"#name=\"enabled\" value=\"true\"#g" \
    -e "s#name=\"listen-ip\" value=\"[^\"]*\"#name=\"listen-ip\" value=\"${ESL_LISTEN_IP}\"#g" \
    -e "s#name=\"listen-port\" value=\"[^\"]*\"#name=\"listen-port\" value=\"${ESL_LISTEN_PORT}\"#g" \
    -e "s#name=\"password\" value=\"[^\"]*\"#name=\"password\" value=\"${ESL_PASSWORD}\"#g" \
    "$ESL_XML" || true

  if grep -q 'apply-inbound-acl' "$ESL_XML"; then
    sed -i "s#name=\"apply-inbound-acl\" value=\"[^\"]*\"#name=\"apply-inbound-acl\" value=\"${ESL_APPLY_ACL}\"#g" "$ESL_XML"
  else
    sed -i "/<\/settings>/i \    <param name=\"apply-inbound-acl\" value=\"${ESL_APPLY_ACL}\"/>" "$ESL_XML"
  fi
fi

# Harden/extend ACL 'lan' for ESL
if [[ -f "$ACL_XML" ]]; then
  if ! grep -q '<list name="esl"' "$ACL_XML"; then
    sed -i "/<\/configuration>/i \
  <list name=\"esl\" default=\"deny\">\n\
    <node type=\"allow\" cidr=\"127.0.0.1/32\"/>\n\
    <node type=\"allow\" cidr=\"::1/128\"/>\n\
  </list>" "$ACL_XML"
  fi
  add_allow_cidr() {
    local cidr="$1"; [[ -z "$cidr" ]] && return 0
    if ! grep -q "cidr=\"$cidr\"" "$ACL_XML"; then
      sed -i "/<list name=\"esl\"/,/<\/list>/ s#</list>#  <node type=\"allow\" cidr=\"$cidr\"/>\n  </list>#g" "$ACL_XML"
    fi
  }
  if command -v ip >/dev/null 2>&1; then
    while read -r cidr iface _; do
      [[ "$iface" = "lo" ]] && continue
      add_allow_cidr "$cidr"
    done < <(ip -o -f inet addr show | awk '{print $4, $2, $NF}')
  fi
  [[ -n "${BRIDGE_CIDR:-}" ]] && add_allow_cidr "$BRIDGE_CIDR"
  IFS=',' read -r -a _extra_cidrs <<< "${EXTRA_ESL_ALLOW_CIDRS:-}"
  for c in "${_extra_cidrs[@]}"; do
    c_trim="$(echo "$c" | xargs || true)"; [[ -n "$c_trim" ]] && add_allow_cidr "$c_trim"
  done
fi

# ===================== lua.conf.xml script-directory =====================
if [[ -f "$LUA_XML" ]]; then
  if grep -q 'script-directory' "$LUA_XML"; then
    sed -i 's#name="script-directory" value="[^"]*"#name="script-directory" value="/usr/share/freeswitch/scripts"#' "$LUA_XML"
  else
    sed -i '/<\/settings>/i \    <param name="script-directory" value="/usr/share/freeswitch/scripts"/>' "$LUA_XML"
  fi
fi

# ===================== smart shim at /usr/share/freeswitch/scripts/app.lua =====================
if [[ -f "${FINAL_SCRIPTS}/app.lua" ]]; then
  mkdir -p /usr/share/freeswitch/scripts
  cat > /usr/share/freeswitch/scripts/app.lua <<EOF
local base = "${FINAL_SCRIPTS}"

-- Seed globals FusionPBX expects (guards against nil concatenation)
scripts_dir   = base
document_root = "/var/www/fusionpbx"

-- Optional: log what we're about to use (first start/debug)
if freeswitch and freeswitch.consoleLog then
  freeswitch.consoleLog("INFO", "[lua-shim] scripts_dir="..tostring(scripts_dir).."\n")
  freeswitch.consoleLog("INFO", "[lua-shim] document_root="..tostring(document_root).."\n")
end

-- Make 'require' find FusionPBX modules
package.path = table.concat({
  base .. "/?.lua",
  base .. "/?/init.lua",
  package.path or ""
}, ";")

-- Hand off to FusionPBX entrypoint
dofile(base .. "/app.lua")
EOF
  chown -R "${FS_USER:-www-data}:${FS_GROUP:-www-data}" /usr/share/freeswitch/scripts 2>/dev/null || true
else
  echo "WARNING: ${FINAL_SCRIPTS}/app.lua not found; skipping shim creation" >&2
fi

# ===================== reload & start profiles (best-effort) =====================
if command -v fs_cli >/dev/null 2>&1; then
  fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x reloadacl || true
  fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x reloadxml || true
  # force mod_lua to reread lua.conf and pick up shim
  fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x "unload mod_lua" || true
  fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x "load mod_lua"   || true
  fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x "reload mod_event_socket" || true
  fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x "reload mod_sofia" || fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x "load mod_sofia" || true
  fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x "sofia profile internal start" || true
  if [[ "$ENABLE_EXTERNAL" == "1" ]]; then
    fs_cli -H "${ESL_LISTEN_IP}" -P "${ESL_LISTEN_PORT}" -p "${ESL_PASSWORD}" -x "sofia profile external start" || true
  fi
fi

echo "Config applied:"
echo "  DOMAIN=${DOMAIN}"
echo "  LOCAL_IP_V4=${LOCAL_IP_V4}  BRIDGE_CIDR=${BRIDGE_CIDR:-N/A}"
echo "  EXTERNAL_SIP_IP=${EXTERNAL_SIP_IP}  EXTERNAL_RTP_IP=${EXTERNAL_RTP_IP}"
echo "  INTERNAL_SIP_PORT=${INTERNAL_SIP_PORT}  EXTERNAL_SIP_PORT=${EXTERNAL_SIP_PORT}"
echo "  RTP=${RTP_START}-${RTP_END}  INBOUND_ACL=${INBOUND_ACL}"
echo "  SCRIPTS_DIR=${SCRIPTS_DIR} (final: ${FINAL_SCRIPTS})"
echo "  ESL_LISTEN_IP=${ESL_LISTEN_IP}  ESL_LISTEN_PORT=${ESL_LISTEN_PORT}"
echo "  ESL_APPLY_ACL=${ESL_APPLY_ACL}  EXTRA_ESL_ALLOW_CIDRS=${EXTRA_ESL_ALLOW_CIDRS:-<none>}"

exec "$@"
