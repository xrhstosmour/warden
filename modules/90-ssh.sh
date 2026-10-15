#!/bin/bash
# Key-only SSH on its own port. Runs last, so a run that fails halfway
# never leaves the server reachable on a port the firewall does not allow.
# The session running this survives the restart, the firewall keeps
# established connections open.

# Socket activation would keep listening on port 22 and ignore `Port`.
if systemctl is-enabled -q ssh.socket 2>/dev/null; then
    systemctl disable -q --now ssh.socket
    log_info "Moved SSH from socket activation to ssh.service."
fi

changed=false
if render_sshd | place_content /etc/ssh/sshd_config.d/00-warden.conf 0644; then
    changed=true
fi

# Diffie-Hellman groups under 3072 bits fall short of the key exchange
# strength everything else here assumes.
moduli=$(mktemp)
awk '$5 >= 3071' /etc/ssh/moduli >"$moduli"
if [[ -s "$moduli" ]] && place "$moduli" /etc/ssh/moduli 0644; then
    changed=true
fi
rm -f "$moduli"

# Host keys other than ed25519 and RSA are never offered, so they go.
for key in /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_dsa_key; do
    if [[ -f "$key" ]]; then
        rm -f "$key" "$key.pub"
        changed=true
    fi
done

sshd -t || fail "sshd rejects the new configuration, it was not restarted. Fix it before logging out."

if [[ "$changed" == true ]]; then
    systemctl restart ssh
    log_warning "SSH now listens on port $SSH_PORT. Keep this session open and log in from a second terminal before closing it."
fi
ensure_service ssh

# SSH listens on its own port now, close any other one the firewall step
# kept open for the move. A no-op when there was none.
candidate=$(mktemp)
render_nftables >"$candidate"
nft -c -f "$candidate" || fail "The generated firewall does not parse, the old SSH port is still open."
if place "$candidate" /etc/nftables.conf 0755; then
    nft -f /etc/nftables.conf
    log_info "Closed the previous SSH port."
    if [[ "$SSH_ACCESS" == "tailscale" ]]; then
        # SSH answers on the tailnet only from here on. Should nobody be
        # able to log in over it, public SSH on the new port comes back by
        # itself until the next run, rather than the server being lost.
        systemctl stop warden-ssh-rollback.timer 2>/dev/null || true
        systemd-run --quiet --unit=warden-ssh-rollback --on-active=15min \
            /usr/sbin/nft insert rule inet warden input tcp dport "$SSH_PORT" accept
        log_warning "SSH answers on the tailnet only. Public SSH reopens in 15 minutes unless a tailnet login runs: sudo systemctl stop warden-ssh-rollback.timer"
    fi
fi
rm -f "$candidate"
