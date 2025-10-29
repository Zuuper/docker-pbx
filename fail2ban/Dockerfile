# Minimal Debian base; small enough to not offend, big enough to work
FROM debian:bookworm-slim

# Noninteractive to keep apt from asking life questions
ENV DEBIAN_FRONTEND=noninteractive

# Install fail2ban and rsyslog (your script did both)
# iptables is usually already there, but let's be explicit
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  fail2ban rsyslog iptables ca-certificates tzdata \
  && rm -rf /var/lib/apt/lists/*

# Copy your custom filters and jail.local from the build context.
# Expect these files to be present in the ./fail2ban folder next to this Dockerfile.
#   fail2ban/
#     freeswitch.conf
#     freeswitch-acl.conf
#     sip-auth-failure.conf
#     sip-auth-challenge.conf
#     auth-challenge-ip.conf
#     freeswitch-ip.conf
#     fusionpbx.conf
#     fusionpbx-mac.conf
#     fusionpbx-404.conf
#     nginx-404.conf
#     nginx-dos.conf
#     jail.local
#
# If you don't have some of them, either add them or delete the COPY lines below.
COPY freeswitch.conf            /etc/fail2ban/filter.d/freeswitch.conf
COPY freeswitch-acl.conf        /etc/fail2ban/filter.d/freeswitch-acl.conf
COPY sip-auth-failure.conf      /etc/fail2ban/filter.d/sip-auth-failure.conf
COPY sip-auth-challenge.conf    /etc/fail2ban/filter.d/sip-auth-challenge.conf
COPY auth-challenge-ip.conf     /etc/fail2ban/filter.d/auth-challenge-ip.conf
COPY freeswitch-ip.conf         /etc/fail2ban/filter.d/freeswitch-ip.conf
COPY fusionpbx.conf             /etc/fail2ban/filter.d/fusionpbx.conf
COPY fusionpbx-mac.conf         /etc/fail2ban/filter.d/fusionpbx-mac.conf
COPY fusionpbx-404.conf         /etc/fail2ban/filter.d/fusionpbx-404.conf
COPY nginx-404.conf             /etc/fail2ban/filter.d/nginx-404.conf
COPY nginx-dos.conf             /etc/fail2ban/filter.d/nginx-dos.conf
COPY jail.local                 /etc/fail2ban/jail.local

# Create runtime dirs
RUN mkdir -p /var/run/fail2ban /var/log/fail2ban

# Optional: make logs and state persistable
VOLUME ["/var/log", "/var/lib/fail2ban"]

# Healthcheck so you know when it’s actually alive and not just vibing
HEALTHCHECK --interval=30s --timeout=5s --retries=10 CMD fail2ban-client ping || exit 1

# Copy the entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Root is required if you expect it to touch iptables
USER root

# Run it
ENTRYPOINT ["/entrypoint.sh"]
