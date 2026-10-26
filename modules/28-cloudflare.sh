#!/bin/bash
# Let only Cloudflare reach the public ports, for a site behind its proxy. Runs
# before the firewall, which reads the ranges this fetches. If they cannot be
# fetched the run stops, a firewall that matches nobody would shut the site
# and one that matches everybody would defeat the point. Off unless
# `CLOUDFLARE_ONLY=yes`.

if ! uses_cloudflare; then
    systemctl disable -q --now warden-cloudflare-sync.timer 2>/dev/null || true
    rm -f /etc/systemd/system/warden-cloudflare-sync.service /etc/systemd/system/warden-cloudflare-sync.timer \
        /usr/local/sbin/warden-cloudflare-sync
    rm -rf /var/lib/warden/cloudflare
    log_info "Cloudflare only is off, CLOUDFLARE_ONLY=yes in warden.conf limits the public ports to Cloudflare."
    return 0
fi

install -d -m 0700 /var/lib/warden
place "$WARDEN_DIRECTORY/files/warden-cloudflare-sync.sh" /usr/local/sbin/warden-cloudflare-sync 0755 || true
if ! /usr/local/sbin/warden-cloudflare-sync; then
    # Ranges from an earlier run still hold, an outage on Cloudflare's side
    # must not stop every other module. Without any, there is nothing to allow.
    [[ -s /var/lib/warden/cloudflare/ipv4 && -s /var/lib/warden/cloudflare/ipv6 ]] ||
        fail "Cloudflare's ranges could not be fetched, the public ports were left as they are."
    log_warning "Cloudflare's ranges could not be refreshed, keeping the ones from the last run."
fi

changed=false
place_content /etc/systemd/system/warden-cloudflare-sync.service 0644 <<'EOF' && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Refresh the Cloudflare address ranges in the firewall
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warden-cloudflare-sync
EOF
place_content /etc/systemd/system/warden-cloudflare-sync.timer 0644 <<'EOF' && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Refresh the Cloudflare address ranges every day

[Timer]
OnBootSec=5min
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
[[ "$changed" == true ]] && systemctl daemon-reload
ensure_service warden-cloudflare-sync.timer
