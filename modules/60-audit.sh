#!/bin/bash
# Audit trail for security relevant changes, and Mandatory Access Control
# confining the services Debian ships profiles for.

changed=false
if place "$WARDEN_DIRECTORY/files/audit.rules" /etc/audit/rules.d/50-warden.rules 0640; then
    changed=true
fi

# Who can log in is decided by these two files, watched per user.
keys_rules=""
for user in "$ADMIN_USER" "$DEPLOY_USER"; do
    home=$(getent passwd "$user" | cut -d: -f6)
    keys_rules+="-w $home/.ssh/ -p wa -k remote-access"$'\n'
done
if printf '# Managed by warden, local changes are overwritten on the next run.\n%s' "$keys_rules" |
    place_content /etc/audit/rules.d/51-warden-keys.rules 0640; then
    changed=true
fi

if [[ "$changed" == true ]]; then
    augenrules --load >/dev/null || log_warning "auditd did not load the rules, they apply after a reboot."
fi
# The kernel's audit system is out of reach inside a container and on
# container based VPS plans, which is no reason to stop the rest.
ensure_service auditd || log_warning "auditd cannot run on this machine, it is likely a container. Skipped."

if aa-enabled -q 2>/dev/null; then
    ensure_service apparmor
else
    log_warning "AppArmor is not enabled in this kernel, check the provider's kernel or boot parameters."
fi
