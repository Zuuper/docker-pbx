# Minimal, predictable base
FROM php:8.2-fpm-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# System deps your script used at runtime -> install at build time
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  git dbus haveged ssl-cert qrencode \
  ghostscript libtiff5-dev libtiff-tools at \
  vim ca-certificates postgresql-client\
  && rm -rf /var/lib/apt/lists/*

# Where we'll stash the config used by entrypoint
# You can override by mounting your own config at runtime:
#   docker run -v $(pwd)/config.sh:/docker/config.sh:ro ...
COPY config.sh /docker/config.sh

# Entry script that performs the clone/optional app pulls
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
  && mkdir -p /var/cache/fusionpbx \
  && chown -R www-data:www-data /var/cache/fusionpbx

# Keep app code here; you can also mount it as a volume if you want to persist edits
WORKDIR /var/www

# Let users mount these if desired
VOLUME ["/docker"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
