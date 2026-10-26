#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Run by `provision.sh` through sudo once a tailnet login works, with the SSH
# port. Stops the timer that would reopen public SSH. Exits 3 when the timer
# already fired, which left a public rule for that port in the firewall, and 4
# when the firewall cannot be read, then nothing is known about the port.

port="${1:-}"
[[ "$port" =~ ^[0-9]{1,5}$ ]] || {
    echo "Usage: warden-ssh-rollback-stop <ssh-port>" >&2
    exit 2
}

if systemctl is-active -q warden-ssh-rollback.timer; then
    systemctl stop warden-ssh-rollback.timer
else
    rules=$(nft list chain inet warden input) || {
        echo "The warden firewall chain cannot be read." >&2
        exit 4
    }
    grep -q "^[[:space:]]*tcp dport $port accept" <<<"$rules" && exit 3
fi
exit 0
