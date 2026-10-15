#!/bin/bash
# Host name, time zone, and a clock that cannot be pushed around. Plain NTP
# is unauthenticated, so anyone on the path can shift the clock and with it
# certificate validity and token expiry. Network Time Security signs it.

if [[ -n "$SERVER_HOSTNAME" && "$(hostname)" != "$SERVER_HOSTNAME" ]]; then
    hostnamectl set-hostname "$SERVER_HOSTNAME"
    log_info "Host name set to $SERVER_HOSTNAME."
fi

if [[ "$(timedatectl show -p Timezone --value)" != "$TIMEZONE" ]]; then
    timedatectl set-timezone "$TIMEZONE"
    log_info "Time zone set to $TIMEZONE."
fi

if place "$WARDEN_DIRECTORY/files/chrony.conf" /etc/chrony/chrony.conf 0644; then
    ensure_service chrony restart
else
    ensure_service chrony
fi
