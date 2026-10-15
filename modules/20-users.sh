#!/bin/bash
# Two accounts, split by what they may do. The admin user logs in with a
# key and needs its password for `sudo`. The deploy user logs in with a
# different key, runs the containers, and cannot become root, so a leaked
# deploy key reaches the application and not the machine.

# Write one authorized key for a user, replacing whatever was there, so a
# key removed from the configuration stops working on the next run.
authorize_key() {
    local user="$1"
    local key="$2"
    local home
    home=$(getent passwd "$user" | cut -d: -f6)

    install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
    if printf '%s\n' "$key" | place_content "$home/.ssh/authorized_keys" 0600; then
        chown "$user:$user" "$home/.ssh/authorized_keys"
    fi
}

if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER"
    log_info "Created $ADMIN_USER."
fi
usermod -aG sudo "$ADMIN_USER"
authorize_key "$ADMIN_USER" "$ADMIN_PUBLIC_KEY"

# `sudo` asks for the admin's own password, so a stolen key alone does not
# give root. Set one now when there is a terminal to type it into.
if [[ "$(passwd -S "$ADMIN_USER" | cut -d' ' -f2)" != "P" ]]; then
    if [[ -t 0 ]]; then
        log_warning "Choose a password for $ADMIN_USER, sudo will ask for it."
        passwd "$ADMIN_USER"
    else
        fail "$ADMIN_USER has no password and there is no terminal to set one. Run again with a terminal, or set it with passwd first."
    fi
fi

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$DEPLOY_USER"
    log_info "Created $DEPLOY_USER."
fi
# Locked, the account has no password to guess, only its key.
passwd -l "$DEPLOY_USER" >/dev/null
if id -nG "$DEPLOY_USER" | tr ' ' '\n' | grep -qxE 'sudo|docker|adm'; then
    gpasswd -d "$DEPLOY_USER" sudo >/dev/null 2>&1 || true
    gpasswd -d "$DEPLOY_USER" docker >/dev/null 2>&1 || true
    gpasswd -d "$DEPLOY_USER" adm >/dev/null 2>&1 || true
    log_info "Removed $DEPLOY_USER from privileged groups."
fi
authorize_key "$DEPLOY_USER" "$DEPLOY_PUBLIC_KEY"

# Rootless containers map their users onto this subordinate range.
for file in /etc/subuid /etc/subgid; do
    if ! grep -q "^$DEPLOY_USER:" "$file"; then
        # After the highest range already handed out, so none overlap.
        start=$(awk -F: 'BEGIN { end = 100000 } { if ($2 + $3 > end) end = $2 + $3 } END { print end }' "$file")
        echo "$DEPLOY_USER:$start:65536" >>"$file"
        log_info "Added a subordinate range for $DEPLOY_USER to $file."
    fi
done

# Home directories readable by their owner only.
chmod 0750 "$(getent passwd "$ADMIN_USER" | cut -d: -f6)" "$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"

# Provider images often leave a default account with passwordless sudo.
for file in /etc/sudoers.d/*; do
    [[ -f "$file" ]] || continue
    if grep -qs 'NOPASSWD' "$file" && [[ "$(basename "$file")" != "warden" ]]; then
        log_warning "$file grants passwordless sudo, review it and remove it once $ADMIN_USER works."
    fi
done

place_content /etc/sudoers.d/warden 0440 <<'EOF' || true
# Managed by warden, local changes are overwritten on the next run.
Defaults use_pty
Defaults passwd_tries=3
Defaults timestamp_timeout=5
Defaults logfile="/var/log/sudo.log"
EOF
if ! visudo -cq; then
    rm -f /etc/sudoers.d/warden
    fail "sudoers stopped parsing with /etc/sudoers.d/warden, removed it again."
fi
