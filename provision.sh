#!/bin/bash
# Harden a server from your own machine, in one command:
#
#   ./provision.sh <user@host> [ssh options...]
#
# The first time, that is the provider's initial login, root@203.0.113.10
# or debian@203.0.113.10. Afterwards it is the admin on the new port,
# ./provision.sh admin@203.0.113.10 -p 2222 -i ~/.ssh/app_admin.
#
# With the public keys left empty in warden.conf, it first makes an
# ed25519 key pair per account on this machine, where they stay. Then it
# copies warden and warden.conf to the server, runs install.sh there with
# a terminal for the admin password prompt, and proves both accounts can
# log in on the new port, over the tailnet when SSH is kept to it, before
# it reports success.

# Remote commands are built here on purpose, from fixed names and validated
# configuration values.
# shellcheck disable=SC2029

set -euo pipefail

WARDEN_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

target="${1:-}"
[[ "$target" == *@* ]] || {
    echo "Usage: ./provision.sh <user@host> [ssh options...]" >&2
    exit 1
}
shift
ssh_options=("$@")

configuration="${WARDEN_CONFIGURATION:-$WARDEN_DIRECTORY/warden.conf}"
[[ -f "$configuration" ]] || {
    echo "No $configuration, copy warden.conf.example and fill it in." >&2
    exit 1
}

# shellcheck source=library/common.sh
source "$WARDEN_DIRECTORY/library/common.sh"
# shellcheck source=library/configuration.sh
source "$WARDEN_DIRECTORY/library/configuration.sh"
load_configuration "$configuration"

host="${target#*@}"
user="${target%@*}"
sudo_prefix="sudo"
[[ "$user" == "root" ]] && sudo_prefix=""

# The keys, and the SSH configuration naming them, live on this machine.
name="${SERVER_HOSTNAME:-${host//[^A-Za-z0-9-]/-}}"
key_directory="${WARDEN_KEYS:-$HOME/.ssh}"
admin_identity="$key_directory/${name}_admin"
deploy_identity="$key_directory/${name}_deploy"

if [[ -z "$ADMIN_PUBLIC_KEY" || -z "$DEPLOY_PUBLIC_KEY" ]]; then
    log_info "Making the key pairs in $key_directory."
    "$WARDEN_DIRECTORY/keys.sh" "$name" "$key_directory" >/dev/null
    [[ -n "$ADMIN_PUBLIC_KEY" ]] || ADMIN_PUBLIC_KEY=$(cat "$admin_identity.pub")
    [[ -n "$DEPLOY_PUBLIC_KEY" ]] || DEPLOY_PUBLIC_KEY=$(cat "$deploy_identity.pub")
fi
validate_configuration || fail "Fix $configuration and run again."

if [[ "$SSH_ACCESS" == "tailscale" ]]; then
    if command -v tailscale >/dev/null; then
        tailscale status >/dev/null 2>&1 ||
            fail "This machine is not on the tailnet, and SSH to the server will be kept to it. Connect first."
    else
        log_warning "No tailscale command here, make sure this machine is on the tailnet the server joins."
    fi
fi

# Uploaded as the login user first, so a `sudo` password prompt never
# competes with the upload for standard input. Then one `sudo`, with a
# terminal, moves it into root's own directory, where nobody else can read
# the configuration or swap the scripts out, and runs it.
upload=".warden-upload"
remote_directory="/root/warden"

log_info "Copying warden to $host."
ssh "${ssh_options[@]}" "$target" "rm -rf $upload && umask 077 && mkdir $upload"
# No macOS resource fork files in the archive.
COPYFILE_DISABLE=1 tar -C "$WARDEN_DIRECTORY" -czf - install.sh library modules files |
    ssh "${ssh_options[@]}" "$target" "umask 077 && tar -xzf - -C $upload"

# The backup password and keys are made on this machine. They travel with the
# upload, readable by root alone, and the configuration below points at them.
backup_overrides=""
copy_backup_secret() {
    local variable="$1"
    local name="$2"
    local source="${!variable}"
    [[ -n "$source" ]] || return 0
    source="${source/#\~/$HOME}"
    [[ -f "$source" ]] || fail "$source is missing, $variable names it in warden.conf."
    ssh "${ssh_options[@]}" "$target" "umask 077 && mkdir -p $upload/secrets && cat > $upload/secrets/$name" <"$source"
    backup_overrides+="$variable=\"$remote_directory/secrets/$name\""$'\n'
}
if uses_backups; then
    copy_backup_secret BACKUP_PASSWORD_FILE password
    copy_backup_secret BACKUP_SSH_KEY_FILE key
    copy_backup_secret BACKUP_RCLONE_CONFIG_FILE rclone.conf
fi

# The keys made above follow the file's own lines, and so win over them.
{
    cat "$configuration"
    printf '\nADMIN_PUBLIC_KEY="%s"\nDEPLOY_PUBLIC_KEY="%s"\n' "$ADMIN_PUBLIC_KEY" "$DEPLOY_PUBLIC_KEY"
    printf '%s' "$backup_overrides"
} | ssh "${ssh_options[@]}" "$target" "umask 077 && cat > $upload/warden.conf"

log_info "Running warden on $host."
output=$(mktemp)
trap 'rm -f "$output"' EXIT
ssh -t "${ssh_options[@]}" "$target" \
    "upload=\$HOME/$upload; $sudo_prefix sh -c \"rm -rf $remote_directory && mv \$upload $remote_directory && chown -R root:root $remote_directory && bash $remote_directory/install.sh $remote_directory/warden.conf\"" |
    tee "$output"

login_host="$host"
if [[ "$SSH_ACCESS" == "tailscale" ]]; then
    login_host=$(grep -o 'WARDEN_TAILSCALE_ADDRESS=[0-9.]*' "$output" | tail -1 | cut -d= -f2 || true)
    [[ -n "$login_host" ]] ||
        fail "warden did not report a tailnet address. Public SSH reopens on port $SSH_PORT in 15 minutes."
fi

# Only the key made for an account, when there is one, so a pass proves
# that key works rather than whichever the agent offered first. Sets
# `options`, macOS ships bash 3, which has no `mapfile`.
identity_options() {
    options=(-p "$SSH_PORT")
    if [[ -f "$1" ]]; then
        options+=(-i "$1" -o IdentitiesOnly=yes)
    fi
}

log_info "Checking that both accounts can log in to $login_host on port $SSH_PORT."
failures=0
for account in "$ADMIN_USER" "$DEPLOY_USER"; do
    identity="$deploy_identity"
    [[ "$account" == "$ADMIN_USER" ]] && identity="$admin_identity"
    identity_options "$identity"
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "${options[@]}" "$account@$login_host" true; then
        log_success "$account logs in."
    else
        log_error "$account could not log in. Check before closing any open session."
        failures=$((failures + 1))
    fi
done

if ((failures > 0)); then
    [[ "$SSH_ACCESS" == "tailscale" ]] && log_warning "Public SSH reopens on port $SSH_PORT in 15 minutes, to fix it from there."
    exit 1
fi

if [[ "$SSH_ACCESS" == "tailscale" ]]; then
    log_info "The tailnet login works, keeping SSH on it. sudo asks for the admin password."
    identity_options "$admin_identity"
    ssh -t "${options[@]}" "$ADMIN_USER@$login_host" \
        "sudo systemctl stop warden-ssh-rollback.timer" ||
        fail "The rollback is still pending, run: sudo systemctl stop warden-ssh-rollback.timer"
fi

# A Host entry per account, in a file of its own next to the keys.
ssh_configuration="$key_directory/$name.config"
{
    echo "# Written by warden's provision.sh for $host."
    for account in "$ADMIN_USER" "$DEPLOY_USER"; do
        identity="$deploy_identity"
        role="deploy"
        if [[ "$account" == "$ADMIN_USER" ]]; then
            identity="$admin_identity"
            role="admin"
        fi
        echo
        echo "Host $name-$role"
        echo "    HostName $login_host"
        echo "    Port $SSH_PORT"
        echo "    User $account"
        if [[ -f "$identity" ]]; then
            echo "    IdentityFile $identity"
            echo "    IdentitiesOnly yes"
        fi
        echo "    AddKeysToAgent yes"
        echo "    IgnoreUnknown UseKeychain"
        echo "    UseKeychain yes"
    done
} >"$ssh_configuration"
chmod 0600 "$ssh_configuration"

cat <<EOF

Done. The SSH configuration is in $ssh_configuration. Put this line at
the top of ~/.ssh/config once, then ssh $name-admin or ssh $name-deploy:

Include $ssh_configuration
EOF
