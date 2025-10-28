FROM debian:bookworm

ARG DEBIAN_FRONTEND=noninteractive

# Pin what "stable" means to you
ARG FS_VERSION=1.10.12     
ARG SOFIA_VERSION=1.13.17     
ARG SPANDSP_REF=v3.0     
ARG INSTALL_SOUNDS=1          

ENV TZ=UTC \
  FS_VERSION=${FS_VERSION} \
  INSTALL_SOUNDS=${INSTALL_SOUNDS} \
  FS_USER=www-data \
  FS_GROUP=www-data \
  FS_ETC=/etc/freeswitch \
  FS_VAR=/var/lib/freeswitch \
  FS_LOG=/var/log/freeswitch \
  FS_SHARE=/usr/share/freeswitch \
  FS_DEFAULTS_DIR=/opt/freeswitch/defaults \
  FS_CONF_SOURCE=/opt/freeswitch/defaults

# Use bash so pipefail behaves and logs are readable
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 0) Build deps (include libtool + libtool-bin) and verify
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
  ca-certificates curl wget git bash tzdata procps iproute2 \
  autoconf automake libtool libtool-bin pkg-config m4 gettext \
  build-essential cmake unzip rsync \
  libncurses5-dev libpcre3-dev libedit-dev \
  libssl-dev libcurl4-openssl-dev zlib1g-dev \
  libsqlite3-dev libpq-dev uuid-dev \
  libspeexdsp-dev libopus-dev libsndfile1-dev \
  libjpeg-dev libpng-dev libtiff5-dev \
  libvpx-dev libyuv-dev \
  libavformat-dev libavcodec-dev libswscale-dev \
  liblua5.2-dev libmemcached-dev libshout3-dev \
  libmpg123-dev libmp3lame-dev libxml2-dev libxslt1-dev \
  libuv1-dev libatomic1 \
  libldns-dev portaudio19-dev libyaml-dev \
  yasm nasm sox ccache; \
  command -v libtool && libtool --version; \
  command -v libtoolize && libtoolize --version; \
  command -v autoconf && autoconf --version; \
  command -v automake && automake --version

WORKDIR /usr/src

# 1) libks (install to /usr, skip Debian packaging logic)
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
  libuv1-dev libatomic1 uuid-dev libssl-dev zlib1g-dev; \
  OPENSSL_MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"; \
  git clone --depth 1 --branch v2.0.7 https://github.com/signalwire/libks.git /usr/src/libks; \
  # Disable the DEB generator block that trips on shallow clones/no lsb_release
  sed -i 's/^[[:space:]]*if[[:space:]]*(\s*DEBIAN_FOUND\s*)/if(FALSE AND DEBIAN_FOUND)/' /usr/src/libks/CMakeLists.txt; \
  cmake -S /usr/src/libks -B /usr/src/libks/build \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=OFF \
  -DOPENSSL_ROOT_DIR=/usr \
  -DOPENSSL_INCLUDE_DIR=/usr/include \
  -DOPENSSL_CRYPTO_LIBRARY=/usr/lib/${OPENSSL_MULTIARCH}/libcrypto.so \
  -DOPENSSL_SSL_LIBRARY=/usr/lib/${OPENSSL_MULTIARCH}/libssl.so; \
  cmake --build /usr/src/libks/build -j"$(getconf _NPROCESSORS_ONLN || echo 2)"; \
  cmake --install /usr/src/libks/build

# 2) sofia-sip (install to /usr)
RUN set -eux; \
  wget -qO sofia.zip "https://github.com/freeswitch/sofia-sip/archive/refs/tags/v${SOFIA_VERSION}.zip"; \
  unzip -q -o sofia.zip -d /usr/src; \
  cd "/usr/src/sofia-sip-${SOFIA_VERSION}"; \
  sh autogen.sh; \
  ./configure --prefix=/usr --enable-debug; \
  make -j"$(getconf _NPROCESSORS_ONLN || echo 2)"; \
  make install

# 3) spandsp 3.x (install to /usr; FS requires v3)
RUN set -eux; \
  git clone https://github.com/freeswitch/spandsp.git spandsp; \
  cd spandsp; \
  git checkout -q "${SPANDSP_REF}" || true; \
  sh autogen.sh; \
  ./configure --prefix=/usr --enable-debug; \
  make -j"$(getconf _NPROCESSORS_ONLN || echo 2)"; \
  make install; \
  ldconfig; \
  pkg-config --modversion spandsp

# 4) FreeSWITCH source (choose repo/branch like the source_release script)
RUN set -eux; \
  ver="${FS_VERSION#v}"; \
  repo="https://github.com/signalwire/freeswitch.git"; \
  branch="${FS_VERSION}"; \
  # If FS_VERSION is numeric (e.g. 1.10.12), pick repo/tag format accordingly
  if [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then \
  num="$(printf '%s' "$ver" | tr -d '.')"; \
  if [ "$num" -gt 1100 ]; then \
  # For > 1.1.0 use FusionPBX fork; tags have NO leading 'v'
  repo="https://github.com/fusionpbx/freeswitch"; \
  branch="$ver"; \
  else \
  # For <= 1.1.0 use SignalWire; tags are 'vX.Y.Z'
  repo="https://github.com/signalwire/freeswitch.git"; \
  branch="v$ver"; \
  fi; \
  fi; \
  echo "Cloning $repo @ $branch"; \
  git clone --depth 1 -b "$branch" "$repo" freeswitch || git clone -b "$branch" "$repo" freeswitch
WORKDIR /usr/src/freeswitch
RUN ./bootstrap.sh -j


# 5) Enable/disable specific modules (kill mod_signalwire everywhere)
RUN set -eux; \
  tweak_file(){ f="$1"; pat="$2"; action="$3"; \
  [ -f "$f" ] || return 0; \
  if [ "$action" = enable ]; then \
  # uncomment even if '#   <mod>   ...'
  sed -i -E "s|^[[:space:]]*#[[:space:]]*(${pat})([[:space:]].*)?$|\\1|" "$f"; \
  else \
  # comment regardless of leading/trailing noise
  sed -i -E "s|^[[:space:]]*#?[[:space:]]*(${pat})([[:space:]].*)?$|#\\1|" "$f"; \
  fi; \
  }; \
  for f in modules.conf modules.conf.in build/modules.conf build/modules.conf.most; do \
  tweak_file "$f" "applications/mod_callcenter" enable; \
  tweak_file "$f" "applications/mod_cidlookup"  enable; \
  tweak_file "$f" "applications/mod_memcache"   enable; \
  tweak_file "$f" "applications/mod_curl"       enable; \
  tweak_file "$f" "applications/mod_spandsp"    disable; \
  tweak_file "$f" "formats/mod_shout"           enable; \
  tweak_file "$f" "formats/mod_pgsql"           enable; \
  # disable mod_signalwire (no alternation; call twice)
  tweak_file "$f" "applications/mod_signalwire" disable; \
  tweak_file "$f" "event_handlers/mod_signalwire" disable; \
  tweak_file "$f" "applications/mod_enum" disable; \
  done; \
  # neuter XML autoloads so runtime won't try to load it
  find conf -type f -name modules.conf.xml -print0 | xargs -0 sed -i -E \
  's|^[[:space:]]*<load[[:space:]]+module="mod_signalwire"[[:space:]]*/>|<!--load module="mod_signalwire"/-->|g'; \
  # assert not enabled in build files (only check build lists, not the whole tree)
  if grep -RniE '^[[:space:]]*[^#[:space:]].*\bmod_signalwire\b' \
  modules.conf modules.conf.in build/modules.conf build/modules.conf.most; then \
  echo "ERROR: mod_signalwire still enabled in build files"; exit 1; \
  fi



# 6) Configure to FHS paths
RUN rm -f config.cache && ./configure \
  --enable-portable-binary \
  --disable-dependency-tracking \
  --enable-debug \
  --prefix=/usr \
  --localstatedir=/var \
  --sysconfdir=/etc \
  --with-openssl \
  --enable-core-pgsql-support

# 7) Build and install
RUN make -j"$(getconf _NPROCESSORS_ONLN || echo 2)" && make install

# 8) Sounds (optional; controlled by INSTALL_SOUNDS)
RUN if [ "${INSTALL_SOUNDS}" = "1" ]; then \
  make sounds-install moh-install || true; \
  make hd-sounds-install hd-moh-install || true; \
  make cd-sounds-install cd-moh-install || true; \
  mkdir -p /usr/share/freeswitch/sounds/music/default; \
  bash -lc 'shopt -s nullglob; mv /usr/share/freeswitch/sounds/music/*000 /usr/share/freeswitch/sounds/music/default 2>/dev/null || true'; \
  fi

# 9) Permissions
RUN set -eux; \
  for d in "$FS_ETC" "$FS_VAR" "$FS_SHARE" "$FS_LOG" /var/run/freeswitch /var/cache/fusionpbx; do \
  mkdir -p "$d"; chown -R "$FS_USER:$FS_GROUP" "$d" || true; \
  done; \
  chmod -R g+rX "$FS_ETC" || true; \
  chmod 2775 "$FS_VAR" /var/run/freeswitch || true; \
  find "$FS_VAR" -type d -exec chmod 2775 {} + 2>/dev/null || true; \
  find "$FS_VAR" -type f -exec chmod 664 {} + 2>/dev/null || true; \
  chmod 2755 "$FS_LOG" || true; \
  find "$FS_LOG" -type d -exec chmod 2755 {} + 2>/dev/null || true; \
  find "$FS_LOG" -type f -exec chmod 664 {} + 2>/dev/null || true

# 10) Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 5060/tcp 5060/udp 5080/tcp 5080/udp 8021/tcp
HEALTHCHECK --interval=30s --timeout=10s --retries=5 \
  CMD bash -c 'timeout 2 bash -c "</dev/tcp/127.0.0.1/8021" 2>/dev/null || pgrep -x freeswitch >/dev/null || exit 1'

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
