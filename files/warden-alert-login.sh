#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Run by PAM when an SSH session opens. It always exits 0, so a failure here
# can never block a login. The client address is left out on purpose, it is
# personal data and the push goes through a third party. It runs as root with
# an environment the logging in user can influence, so nothing here is read
# from the environment: the paths are fixed and the alert runs with a clean one.

[[ "${PAM_TYPE:-}" == "open_session" ]] || exit 0

user="${PAM_USER:-unknown}"
stamp_directory=/run/warden-alert

# One push per user and address per minute, a burst of connections from the
# same place is one event. The address only names the stamp file.
install -d -m 0700 "$stamp_directory" 2>/dev/null
# Stamps older than the minute that matters would only pile up until reboot.
find "$stamp_directory" -type f -mmin +60 -delete 2>/dev/null
origin=$(printf '%s' "${PAM_RHOST:-}" | sha256sum | cut -c1-16)
stamp="$stamp_directory/login-${user//[^A-Za-z0-9_-]/_}-$origin"
if [[ -f "$stamp" && -n "$(find "$stamp" -mmin -1 2>/dev/null)" ]]; then
    exit 0
fi
touch "$stamp" 2>/dev/null

env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/local/sbin/warden-alert 3 "SSH login" "$user logged in to $(hostname)." "key" </dev/null >/dev/null 2>&1 &
exit 0
