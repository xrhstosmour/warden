#!/bin/bash
# Installs `warden-audit`, a read-only check that this server still matches
# what warden sets up, run it any time as `sudo warden-audit`. Switched off
# with `AUDIT_TOOL=no`.

if [[ "$AUDIT_TOOL" != "yes" ]]; then
    rm -f /usr/local/sbin/warden-audit
    log_info "warden-audit is off, AUDIT_TOOL=yes in warden.conf installs it."
    return 0
fi

place "$WARDEN_DIRECTORY/files/warden-audit.sh" /usr/local/sbin/warden-audit 0755 || true
