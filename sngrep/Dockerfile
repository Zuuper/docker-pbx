FROM debian:bookworm

# Optional but saves pain later
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates gnupg; \
  rm -rf /var/lib/apt/lists/*

# Install sngrep at build time (works on amd64 and arm64 in bookworm)
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends sngrep; \
  rm -rf /var/lib/apt/lists/*

# Default to launching sngrep; override CMD if you want a shell
CMD ["sngrep", "-h"]
