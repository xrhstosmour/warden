#!/bin/bash
# Ban addresses that keep failing to log in. Key-only SSH already makes
# guessing useless, this keeps the noise and the load down.

# Debian's own jail would also watch the old port.
rm -f /etc/fail2ban/jail.d/defaults-debian.conf

if render_fail2ban | place_content /etc/fail2ban/jail.d/warden.local 0644; then
    fail2ban-client -t >/dev/null || fail "fail2ban rejects /etc/fail2ban/jail.d/warden.local."
    ensure_service fail2ban restart
else
    ensure_service fail2ban
fi
