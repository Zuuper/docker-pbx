# Minimal, predictable base
FROM php:8.2-fpm-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# System deps + headers to compile pgsql extensions
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  git dbus haveged ssl-cert qrencode \
  ghostscript libtiff5-dev libtiff-tools at \
  vim ca-certificates postgresql-client libpq-dev \
  && docker-php-ext-install -j"$(nproc)" pdo_pgsql pgsql \
  && rm -rf /var/lib/apt/lists/*

# Where entrypoint reads optional templates from
# You can mount your own: -v ./config.conf:/docker/config.conf:ro
COPY config.sh /docker/config.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
  && mkdir -p /var/cache/fusionpbx \
  && chown -R www-data:www-data /var/cache/fusionpbx

WORKDIR /var/www
VOLUME ["/docker"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
