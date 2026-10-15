#!/bin/bash
# Logs that survive a reboot but do not pile up. Access logs hold client
# addresses, which are personal data, so they are kept a month and no
# longer. No core dumps, a dump of the application is a dump of whatever
# customer data it held in memory.

if place_content /etc/systemd/journald.conf.d/warden.conf 0644 <<'EOF'; then
# Managed by warden, local changes are overwritten on the next run.
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=1G
MaxRetentionSec=1month
ForwardToSyslog=no
EOF
    systemctl restart systemd-journald
fi

place_content /etc/systemd/coredump.conf.d/warden.conf 0644 <<'EOF' || true
# Managed by warden, local changes are overwritten on the next run.
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

place_content /etc/security/limits.d/warden.conf 0644 <<'EOF' || true
# Managed by warden, local changes are overwritten on the next run.
* hard core 0
EOF

# New files readable by their owner and group only.
if grep -qE '^UMASK[[:space:]]+022' /etc/login.defs; then
    temporary=$(mktemp)
    awk '/^UMASK[[:space:]]/ { print "UMASK\t\t027"; next } { print }' /etc/login.defs >"$temporary"
    place "$temporary" /etc/login.defs 0644 || true
    rm -f "$temporary"
fi

# `logrotate` keeps the sudo log beside the others.
place_content /etc/logrotate.d/warden-sudo 0644 <<'EOF' || true
/var/log/sudo.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
EOF
