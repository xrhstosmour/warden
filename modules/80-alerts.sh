#!/bin/bash
# Push alerts to your phone through ntfy: a full disk, a failed unit, and
# optionally every SSH login. Off unless `ALERTS=ntfy`. The topic is the only
# secret, it lives under /var/lib/warden, outside /etc, so etckeeper never
# commits it. A dead server sends nothing, this does not replace a monitor
# outside it.

if ! uses_alerts; then
    rm -f /usr/local/sbin/warden-alert /etc/warden/alerts.conf
    log_info "Alerts are off, ALERTS=ntfy in warden.conf sends them to your phone."
    return 0
fi

install -d -m 0755 /etc/warden
install -d -m 0700 /var/lib/warden

place "$WARDEN_DIRECTORY/files/warden-alert.sh" /usr/local/sbin/warden-alert 0755 || true

place_content /etc/warden/alerts.conf 0644 <<EOF || true
# Managed by warden, local changes are overwritten on the next run.
NTFY_SERVER=$NTFY_SERVER
EOF

# 36 random bytes, 48 characters, the password to the topic.
generated=false
if [[ ! -s /var/lib/warden/ntfy-topic ]]; then
    (umask 077 && head -c 36 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' >/var/lib/warden/ntfy-topic)
    generated=true
fi
chmod 0600 /var/lib/warden/ntfy-topic

if [[ "$generated" == true ]]; then
    /usr/local/sbin/warden-alert 3 "warden alerts" "Alerts are on for $(hostname)." "tada" || true
    log_warning "Alerts are on. Subscribe to the topic in the ntfy app, read it with: sudo cat /var/lib/warden/ntfy-topic. Treat it like a password."
fi
