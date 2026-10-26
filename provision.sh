#!/bin/bash
# Harden a server from your own machine, in one command:
#
#   ./provision.sh <user@host> [ssh options...]
#
# The first time, that is the provider's initial login, root@203.0.113.10
# or debian@203.0.113.10. Afterwards it is the admin on the new port,
# ./provision.sh admin@203.0.113.10 -p 2222 -i ~/.ssh/app_admin. With SSH kept
# to the tailnet that is Tailscale SSH on port 22 of the server's tailnet
# address, ./provision.sh admin@100.64.0.1 -p 22.
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
    # Logging in as the admin means the server already has keys. New ones
    # under another name would replace the ones in use, locking out the old.
    if [[ -z "$ADMIN_PUBLIC_KEY" && "$user" == "$ADMIN_USER" && ! -f "$admin_identity" ]]; then
        fail "No key named ${name}_admin in $key_directory, and the server already has the admin's key. Set SERVER_HOSTNAME to the name the keys were made under, or paste both public keys into warden.conf."
    fi
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
    printf '\nADMIN_PUBLIC_KEY=%q\nDEPLOY_PUBLIC_KEY=%q\n' "$ADMIN_PUBLIC_KEY" "$DEPLOY_PUBLIC_KEY"
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
        fail "warden did not report a tailnet address. Public SSH reopens on port $SSH_PORT $(rollback_minutes) minutes after SSH moved."
fi

# Where and how the logins are made. The tailnet policy grants port 22 only,
# which Tailscale SSH serves, signed in by the tailnet and never as root.
# Otherwise only the key made for an account, when there is one, so a pass
# proves that key works rather than whichever the agent offered first. Sets
# `options`, macOS ships bash 3, which has no `mapfile`.
login_port="$SSH_PORT"
uses_tailscale_ssh_login && login_port=22
identity_options() {
    options=(-p "$login_port")
    if uses_tailscale_ssh_login; then
        # The tailnet already authenticated the server, the host key is new.
        options+=(-o StrictHostKeyChecking=accept-new)
    elif [[ -f "$1" ]]; then
        options+=(-i "$1" -o IdentitiesOnly=yes)
    fi
}

# One login proof. On the tailnet the policy asks for a browser approval
# first, so ssh runs without BatchMode to show the URL it prints. Both
# accounts share `login_approval_seconds`, which `rollback_minutes` counts.
login_approval_seconds=900
login_deadline=$(($(date +%s) + login_approval_seconds))
check_login() {
    local account="$1" identity="$2"
    identity_options "$identity"
    if uses_tailscale_ssh_login; then
        log_info "$account: if Tailscale prints a URL, open it in your browser to approve the login."
        local status=0 remaining=$((login_deadline - $(date +%s)))
        ((remaining >= 1)) || remaining=1
        within "$remaining" ssh -o ConnectTimeout=10 "${options[@]}" "$account@$login_host" true || status=$?
        if ((status == 124)); then
            log_error "$account was not approved in time, $((login_approval_seconds / 60)) minutes are shared by both accounts."
        fi
        return "$status"
    fi
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${options[@]}" "$account@$login_host" true
}

log_info "Checking that both accounts can log in to $login_host on port $login_port."
failures=0
for account in "$ADMIN_USER" "$DEPLOY_USER"; do
    identity="$deploy_identity"
    [[ "$account" == "$ADMIN_USER" ]] && identity="$admin_identity"
    if check_login "$account" "$identity"; then
        log_success "$account logs in."
    else
        log_error "$account could not log in. Check before closing any open session."
        failures=$((failures + 1))
    fi
done

if ((failures > 0)); then
    [[ "$SSH_ACCESS" == "tailscale" ]] && log_warning "Public SSH reopens on port $SSH_PORT $(rollback_minutes) minutes after SSH moved, to fix it from there."
    exit 1
fi

if [[ "$SSH_ACCESS" == "tailscale" ]]; then
    log_info "The tailnet login works, keeping SSH on it. sudo asks for the admin password."
    identity_options "$admin_identity"
    # A timer that already fired left a public rule for SSH_PORT behind, then
    # stopping it would claim a tailnet only server that is not one.
    ssh -t "${options[@]}" "$ADMIN_USER@$login_host" "sudo /usr/local/sbin/warden-ssh-rollback-stop $SSH_PORT" ||
        fail "Could not stop the rollback timer. If it already fired, public SSH on port $SSH_PORT is open again. Run provision.sh again."
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
        echo "    Port $login_port"
        echo "    User $account"
        if [[ -f "$identity" ]] && ! uses_tailscale_ssh_login; then
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
