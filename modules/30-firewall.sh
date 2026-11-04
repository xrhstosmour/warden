#!/bin/bash
# Deny every inbound connection except SSH and the public ports. Checked
# with `nft -c` before it is installed, so a bad rule never replaces a
# working firewall.

# The port SSH listens on right now, kept open until `90-ssh.sh` moves it.
# shellcheck disable=SC2034 # Read by `render_nftables`.
TRANSITION_SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')
# A tailnet login already worked on this port, so nobody needs the public one.
if [[ "$SSH_ACCESS" != "tailscale" ]]; then
    # Nothing of the tailnet rollback may outlive the mode, a boot service
    # left over would open a port nothing else lists.
    rm -f "$(ssh_proof_file)" "$(ssh_reopen_file)"
    if [[ -e /etc/systemd/system/warden-ssh-reopen.service ]]; then
        systemctl disable -q warden-ssh-reopen.service
    fi
fi
tailnet_ssh_proven && TRANSITION_SSH_PORT=""

candidate=$(mktemp)
render_nftables >"$candidate"
nft -c -f "$candidate" || fail "The generated firewall does not parse, nothing was changed."

if place "$candidate" /etc/nftables.conf 0755; then
    nft -f /etc/nftables.conf
    log_info "Firewall reloaded."
fi
rm -f "$candidate"
ensure_service nftables
