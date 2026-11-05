#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Run by a timer. Alerts when the disk, its inodes or the memory cross the
# threshold, the load stays high, the clock loses sync, a unit fails or a
# container is unhealthy, once per change, and again when it is back to
# normal. A change whose alert did not go out is sent again on the next run.

set -uo pipefail

configuration_directory="${WARDEN_CONFIGURATION_DIRECTORY:-/etc/warden}"
state_directory="${WARDEN_STATE_DIRECTORY:-/var/lib/warden}"
alert="${WARDEN_ALERT:-/usr/local/sbin/warden-alert}"
proc_directory="${WARDEN_PROC_DIRECTORY:-/proc}"

ALERT_DISK_PERCENT=85
default_memory_percent=90
ALERT_MEMORY_PERCENT=$default_memory_percent
DEPLOY_USER=""
# shellcheck disable=SC1091 # Written by warden, root's file.
source "$configuration_directory/alerts.conf" 2>/dev/null
# The range `validate_configuration` allows, 50 to 99.
[[ "$ALERT_DISK_PERCENT" =~ ^[5-9][0-9]$ ]] || exit 0
# A bad memory value only costs the memory alert its threshold, exiting here
# would silence every other alert on the machine without a sign.
[[ "$ALERT_MEMORY_PERCENT" =~ ^[5-9][0-9]$ ]] || ALERT_MEMORY_PERCENT=$default_memory_percent

host=$(hostname)
install -d -m 0700 "$state_directory"

# Alert once when a condition starts and once when it ends. The state is
# kept only once the alert went out, so a failed send is tried again.
# alert_on_change <state> <bad: yes|no> <priority> <tags> <title> <ended title> <message>
alert_on_change() {
    local state="$state_directory/$1" bad="$2" priority="$3" tags="$4" title="$5" ended="$6" message="$7"
    if [[ "$bad" == yes ]]; then
        if [[ ! -f "$state" ]] && "$alert" "$priority" "$title" "$message" "$tags"; then
            touch "$state"
        fi
    elif [[ -f "$state" ]] && "$alert" 3 "$ended" "$message" "white_check_mark"; then
        rm -f "$state"
    fi
}

# Succeeds when the first number is at or above the second, decimals too.
at_least() { awk -v value="$1" -v limit="$2" 'BEGIN { exit !(value >= limit) }'; }

usage=$(df --output=pcent / | tail -1 | tr -dc '0-9')
bad=no
((usage >= ALERT_DISK_PERCENT)) && bad=yes
alert_on_change disk-full "$bad" 5 floppy_disk "Disk almost full" "Disk space back" "$host: / is $usage% full."

# A disk of many small files runs out of inodes with space to spare.
inodes=$(df --output=ipcent / | tail -1 | tr -dc '0-9')
bad=no
[[ -n "$inodes" ]] && ((inodes >= ALERT_DISK_PERCENT)) && bad=yes
alert_on_change inodes-full "$bad" 5 floppy_disk "Inodes almost full" "Inodes back" "$host: / uses $inodes% of its inodes."

# What is left after the cache is given back, not what is free.
if [[ -r "$proc_directory/meminfo" ]]; then
    used=$(awk '/^MemTotal:/ { total = $2 } /^MemAvailable:/ { available = $2 } END { if (total > 0) printf "%d", (total - available) * 100 / total }' "$proc_directory/meminfo")
    if [[ -n "$used" ]]; then
        bad=no
        ((used >= ALERT_MEMORY_PERCENT)) && bad=yes
        alert_on_change memory-full "$bad" 4 warning "Memory almost full" "Memory back" "$host: memory is $used% used."
    fi
fi

# The 15 minute average per core, so a short burst never alerts. Above 2 the
# machine has had twice the work it can do for a quarter of an hour.
if [[ -r "$proc_directory/loadavg" ]]; then
    read -r _ _ load _ <"$proc_directory/loadavg"
    cores=$(nproc 2>/dev/null || echo 1)
    bad=no
    at_least "$load" "$((cores * 2))" && bad=yes
    alert_on_change load-high "$bad" 4 warning "Load high" "Load back" "$host: load is $load over $cores cores for 15 minutes."
fi

# Certificates, logs and backups all depend on the clock. Unknown counts as fine.
if command -v timedatectl >/dev/null 2>&1; then
    synchronised=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null)
    bad=no
    [[ "$synchronised" == no ]] && bad=yes
    alert_on_change clock-unsynchronised "$bad" 4 warning "Clock out of sync" "Clock synced" "$host: the clock is not synchronised."
fi

# The deploy user runs Docker, so its containers are asked as that user. Its
# daemon is a unit of the user's own systemd, which the failed unit alert
# below does not see, so a daemon that does not answer is reported here, not
# read as healthy or as broken containers. The deploy user owns the socket and
# could leave it unanswered, the timeout keeps that from stalling every check
# after this one.
if [[ -n "$DEPLOY_USER" ]] && id "$DEPLOY_USER" >/dev/null 2>&1; then
    deploy_uid=$(id -u "$DEPLOY_USER")
    deploy_home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
    if listing=$(timeout 30 runuser -u "$DEPLOY_USER" -- env HOME="$deploy_home" \
        DOCKER_HOST="unix:///run/user/$deploy_uid/docker.sock" \
        docker ps --all --format '{{.Names}}|{{.Status}}' 2>/dev/null); then
        alert_on_change docker-unreachable no 4 warning "Docker not answering" "Docker answering" "$host: Docker of $DEPLOY_USER answers again."
        # A container that exited with 0 finished its job on purpose. Only
        # names Docker itself allows are kept, the deploy user controls the
        # socket and so the text that reaches the phone.
        broken=$(printf '%s\n' "$listing" |
            awk -F'|' '$1 ~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/ && $2 ~ /\(unhealthy\)|^Restarting|^Dead|^Exited \([1-9]/ { print $1 }' | sort | tr '\n' ' ')
        # Kept as a list, so a second container breaking is a new alert.
        previous=""
        [[ -f "$state_directory/broken-containers" ]] && previous=$(cat "$state_directory/broken-containers")
        if [[ "$broken" != "$previous" ]]; then
            if [[ -n "$broken" ]]; then
                "$alert" 4 "Container unhealthy" "$host: $broken" "warning"
            else
                "$alert" 3 "Containers healthy" "$host: no unhealthy containers." "white_check_mark"
            fi && printf '%s' "$broken" >"$state_directory/broken-containers"
        fi
    else
        alert_on_change docker-unreachable yes 4 warning "Docker not answering" "Docker answering" "$host: Docker of $DEPLOY_USER does not answer."
    fi
fi

failed=$(systemctl --failed --no-legend --plain | awk '{ print $1 }' | sort | tr '\n' ' ')
previous=""
[[ -f "$state_directory/failed-units" ]] && previous=$(cat "$state_directory/failed-units")
if [[ "$failed" != "$previous" ]]; then
    # The change is remembered only once the alert went out, so a failed
    # send is tried again on the next check.
    if [[ -n "$failed" ]]; then
        "$alert" 4 "Unit failed" "$host: $failed" "warning"
    else
        "$alert" 3 "Units healthy" "$host: no failed units." "white_check_mark"
    fi && printf '%s' "$failed" >"$state_directory/failed-units"
fi
