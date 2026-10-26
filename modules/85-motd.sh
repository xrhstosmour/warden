#!/bin/bash
# A short status on every interactive SSH login, so a full disk, a failed
# unit or a pending reboot shows up the moment you log in. Switched off with
# `LOGIN_STATUS=no`.

if [[ "$LOGIN_STATUS" != "yes" ]]; then
    rm -f /etc/profile.d/warden-status.sh
    log_info "The login status is off, LOGIN_STATUS=yes in warden.conf shows it on every SSH login."
    return 0
fi

place "$WARDEN_DIRECTORY/files/status.sh" /etc/profile.d/warden-status.sh 0644 || true
