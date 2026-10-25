#!/bin/bash
# Push alerts to your phone through ntfy: a full disk, a failed unit, and
# optionally every SSH login. Off unless `ALERTS=ntfy`. The topic is the only
# secret, it lives under /var/lib/warden, outside /etc, so etckeeper never
# commits it. A dead server sends nothing, this does not replace a monitor
# outside it.

if ! uses_alerts; then
    systemctl disable -q --now warden-alert-check.timer 2>/dev/null || true
    rm -f /etc/systemd/system/warden-alert-check.service /etc/systemd/system/warden-alert-check.timer \
        /usr/local/sbin/warden-alert /usr/local/sbin/warden-alert-check /etc/warden/alerts.conf
    log_info "Alerts are off, ALERTS=ntfy in warden.conf sends them to your phone."
    return 0
fi

install -d -m 0755 /etc/warden
install -d -m 0700 /var/lib/warden

place "$WARDEN_DIRECTORY/files/warden-alert.sh" /usr/local/sbin/warden-alert 0755 || true
place "$WARDEN_DIRECTORY/files/warden-alert-check.sh" /usr/local/sbin/warden-alert-check 0755 || true

place_content /etc/warden/alerts.conf 0644 <<EOF || true
# Managed by warden, local changes are overwritten on the next run.
NTFY_SERVER=$NTFY_SERVER
ALERT_DISK_PERCENT=$ALERT_DISK_PERCENT
EOF

# 36 random bytes, 48 characters, the password to the topic.
generated=false
if [[ ! -s /var/lib/warden/ntfy-topic ]]; then
    (umask 077 && head -c 36 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' >/var/lib/warden/ntfy-topic)
    generated=true
fi
chmod 0600 /var/lib/warden/ntfy-topic

changed=false
place_content /etc/systemd/system/warden-alert-check.service 0644 <<'EOF' && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Alert on a full disk or a failed unit

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warden-alert-check
EOF
place_content /etc/systemd/system/warden-alert-check.timer 0644 <<'EOF' && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Check the disk and the units every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
[[ "$changed" == true ]] && systemctl daemon-reload
ensure_service warden-alert-check.timer

if [[ "$generated" == true ]]; then
    /usr/local/sbin/warden-alert 3 "warden alerts" "Alerts are on for $(hostname)." "tada" || true
    log_warning "Alerts are on. Subscribe to the topic in the ntfy app, read it with: sudo cat /var/lib/warden/ntfy-topic. Treat it like a password."
fi
