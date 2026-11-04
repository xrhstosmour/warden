#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Run by `provision.sh` through sudo once a tailnet login works, with the SSH
# port. Stops the timer that would reopen public SSH. When the timer already
# fired, the public rule it inserted is only in the running firewall and is
# deleted by its handle. Loading the installed file again would also reset
# the Cloudflare sets to the ranges cached at install time. Exits 3 when the
# rule is still there after that, and 4 when the firewall cannot be read or
# changed, then nothing is known about the port.

port="${1:-}"
[[ "$port" =~ ^[0-9]{1,5}$ ]] || {
    echo "Usage: warden-ssh-rollback-stop <ssh-port>" >&2
    exit 2
}

if systemctl is-active -q warden-ssh-rollback.timer; then
    systemctl stop warden-ssh-rollback.timer
else
    rules=$(nft -a list chain inet warden input) || {
        echo "The warden firewall chain cannot be read." >&2
        exit 4
    }
    rule="^[[:space:]]*tcp dport $port accept"
    if grep -q "$rule" <<<"$rules"; then
        while read -r handle; do
            nft delete rule inet warden input handle "$handle" || {
                echo "The public rule could not be deleted." >&2
                exit 4
            }
        done < <(sed -n "s/$rule # handle \([0-9][0-9]*\)\$/\1/p" <<<"$rules")
        rules=$(nft -a list chain inet warden input) || exit 4
        grep -q "$rule" <<<"$rules" && exit 3
    fi
fi
exit 0
