# shellcheck shell=bash
# Managed by warden, local changes are overwritten on the next run.
# Sourced by login shells, prints a short status for interactive SSH logins.

warden_status() {
    local failed listening

    # A busy or stuck systemd must not hold the prompt back.
    failed=$(timeout 2 systemctl --failed --no-legend 2>/dev/null | wc -l)
    listening=$(ss -tlnH 2>/dev/null | awk '{ sub(/.*:/, "", $4); print $4 }' | sort -nu | tr '\n' ' ')

    echo
    echo "  $(hostname) | up $(uptime -p | sed 's/^up //') | load $(cut -d ' ' -f 1-3 /proc/loadavg)"
    echo "  disk $(df -h --output=pcent / | tail -1 | tr -d ' ') used | memory $(free -h | awk '/^Mem:/ { print $3 " of " $2 }')"
    echo "  failed units: $failed"
    echo "  listening on: $listening"
    [ -f /var/run/reboot-required ] && echo "  a reboot is needed to finish updates"
    echo
}

# Nothing is left behind in the user's shell, and no package list is built on
# every login, unattended upgrades already apply the updates.
if [ -n "${SSH_CONNECTION:-}" ] && [ -t 1 ]; then
    warden_status
fi
unset -f warden_status
