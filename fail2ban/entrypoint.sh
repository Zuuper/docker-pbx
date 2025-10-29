#!/bin/sh
set -eu

# runtime dirs
mkdir -p /var/run/fail2ban /var/log/fail2ban /etc/fail2ban/jail.d

# Optional: disable rsyslog entirely (recommended in containers)
if [ "${DISABLE_RSYSLOG:-0}" != "1" ]; then
  # stop rsyslog from poking /proc/kmsg inside containers
  printf 'module(load="imklog" active="off")\n' > /etc/rsyslog.d/01-disable-imklog.conf
  rsyslogd || echo "rsyslogd failed to start; continuing anyway"
fi

# Auto-disable sshd jail unless you explicitly want it
# Reason: no sshd in this container and no /var/log/auth.log
if [ "${DISABLE_SSHD:-1}" = "1" ]; then
  printf '[sshd]\nenabled = false\n' > /etc/fail2ban/jail.d/disable-sshd.local
fi

# Optional sed override for custom FS log paths
if [ "${F2B_JAIL_SED:-}" != "" ]; then
  sed -i -e "${F2B_JAIL_SED}" /etc/fail2ban/jail.local
fi

# foreground
exec /usr/bin/fail2ban-server -xf start
