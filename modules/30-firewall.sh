#!/bin/bash
# Deny every inbound connection except SSH and the public ports. Checked
# with `nft -c` before it is installed, so a bad rule never replaces a
# working firewall.

# The port SSH listens on right now, kept open until `90-ssh.sh` moves it.
# shellcheck disable=SC2034 # Read by `render_nftables`.
TRANSITION_SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')

candidate=$(mktemp)
render_nftables >"$candidate"
nft -c -f "$candidate" || fail "The generated firewall does not parse, nothing was changed."

if place "$candidate" /etc/nftables.conf 0755; then
    nft -f /etc/nftables.conf
    log_info "Firewall reloaded."
fi
rm -f "$candidate"
ensure_service nftables
