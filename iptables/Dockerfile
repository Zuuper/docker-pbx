# syntax=docker/dockerfile:1
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive \
  os_codename=bookworm

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  iptables iptables-persistent \
  debconf-utils ca-certificates iproute2 procps net-tools && \
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections && \
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections && \
  update-alternatives --set iptables /usr/sbin/iptables-legacy || true && \
  update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY entrypoint.sh /app/script.sh
RUN chmod +x /app/script.sh

# Run your firewall script, then stay up
ENTRYPOINT ["/bin/sh","-c","/app/script.sh && tail -f /dev/null"]
