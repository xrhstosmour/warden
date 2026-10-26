#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Sends one push through ntfy: warden-alert <priority 1-5> <title> <message> [tags]
# The topic is a password, it is read from a root only file and handed to curl
# on standard input, never on a command line other users could list. A failed
# send is logged and exits non-zero, so a caller that keeps state can retry.

set -uo pipefail

configuration_directory="${WARDEN_CONFIGURATION_DIRECTORY:-/etc/warden}"
state_directory="${WARDEN_STATE_DIRECTORY:-/var/lib/warden}"

priority="${1:-3}"
title="${2:-warden}"
message="${3:-}"
tags="${4:-}"

[[ "$priority" =~ ^[1-5]$ ]] || priority=3

NTFY_SERVER=""
# shellcheck disable=SC1091 # Written by warden, root's file.
source "$configuration_directory/alerts.conf" 2>/dev/null
read -r topic <"$state_directory/ntfy-topic" 2>/dev/null

if [[ ! "$NTFY_SERVER" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || [[ ! "$topic" =~ ^[A-Za-z0-9_-]{16,64}$ ]]; then
    logger -t warden-alert "No usable ntfy server or topic, nothing sent."
    exit 0
fi

# Quotes, backslashes and line breaks would break the curl configuration.
clean() { printf '%s' "$1" | tr -d '"\\\r\n' | cut -c1-"$2"; }

if ! printf 'url = "%s/%s"\nheader = "Title: %s"\nheader = "Priority: %s"\nheader = "Tags: %s"\ndata-raw = "%s"\n' \
    "$NTFY_SERVER" "$topic" "$(clean "$title" 80)" "$priority" "$(clean "$tags" 40)" "$(clean "$message" 500)" |
    curl --silent --show-error --fail --proto '=https' --tlsv1.2 --max-time 10 --config - >/dev/null; then
    logger -t warden-alert "Sending to ntfy failed."
    exit 1
fi
