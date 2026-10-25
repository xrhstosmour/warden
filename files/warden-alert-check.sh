#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Run by a timer. Alerts when the disk crosses the threshold or a unit fails,
# once per change, and again when it is back to normal. A change whose alert
# did not go out is sent again on the next run.

set -uo pipefail

configuration_directory="${WARDEN_CONFIGURATION_DIRECTORY:-/etc/warden}"
state_directory="${WARDEN_STATE_DIRECTORY:-/var/lib/warden}"
alert="${WARDEN_ALERT:-/usr/local/sbin/warden-alert}"

ALERT_DISK_PERCENT=85
# shellcheck disable=SC1091 # Written by warden, root's file.
source "$configuration_directory/alerts.conf" 2>/dev/null
[[ "$ALERT_DISK_PERCENT" =~ ^[0-9]{2}$ ]] || exit 0

host=$(hostname)
install -d -m 0700 "$state_directory"

usage=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if ((usage >= ALERT_DISK_PERCENT)); then
    if [[ ! -f "$state_directory/disk-full" ]] && "$alert" 5 "Disk almost full" "$host: / is $usage% full." "floppy_disk"; then
        touch "$state_directory/disk-full"
    fi
elif [[ -f "$state_directory/disk-full" ]] && "$alert" 3 "Disk space back" "$host: / is $usage% full." "white_check_mark"; then
    rm -f "$state_directory/disk-full"
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
