#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Run by `provision.sh` through sudo once a tailnet login works, with the SSH
# port. Stops and disables the timer that would reopen public SSH. Whether or
# not the timer fired, the public rule it inserts is only in the running
# firewall, and is deleted by its handle. Loading the installed file again
# would also reset the Cloudflare sets to the ranges cached at install time.
# Exits 3 when the rule is still there after that, and 4 when the firewall
# cannot be read or changed, then nothing is known about the port.

port="${1:-}"
[[ "$port" =~ ^[0-9]{1,5}$ ]] || {
    echo "Usage: warden-ssh-rollback-stop <ssh-port>" >&2
    exit 2
}

if systemctl is-active -q warden-ssh-rollback.timer; then
    systemctl stop warden-ssh-rollback.timer
fi
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
# Remembered, so a later run neither opens SSH to everyone for the move nor
# arms the rollback again. Enabled until now, so a reboot before this point
# still fires it, done with, it must not come back at the next boot.
state_directory="${WARDEN_STATE_DIRECTORY:-/var/lib/warden}"
install -d -m 0755 "$state_directory"
printf '%s\n' "$port" >"$state_directory/ssh-proven"
systemctl disable -q warden-ssh-rollback.timer
exit 0
