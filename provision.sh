#!/bin/bash
# Harden a server from your own machine, in one command:
#
#   ./provision.sh <user@host> [ssh options...]
#
# The first time, that is the provider's initial login, root@203.0.113.10
# or debian@203.0.113.10. Afterwards it is the admin on the new port,
# ./provision.sh admin@203.0.113.10 -p 2222 -i ~/.ssh/app_admin.
#
# Copies warden and warden.conf to the server, runs install.sh there with
# a terminal for the admin password prompt, then proves both accounts can
# log in on the new port before it reports success.

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
validate_configuration || fail "Fix $configuration and run again."

host="${target#*@}"
user="${target%@*}"
sudo_prefix="sudo"
[[ "$user" == "root" ]] && sudo_prefix=""

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
ssh "${ssh_options[@]}" "$target" "umask 077 && cat > $upload/warden.conf" <"$configuration"

log_info "Running warden on $host."
ssh -t "${ssh_options[@]}" "$target" \
    "upload=\$HOME/$upload; $sudo_prefix sh -c \"rm -rf $remote_directory && mv \$upload $remote_directory && chown -R root:root $remote_directory && bash $remote_directory/install.sh $remote_directory/warden.conf\""

log_info "Checking that both accounts can log in on port $SSH_PORT."
failures=0
for account in "$ADMIN_USER" "$DEPLOY_USER"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=10 -p "$SSH_PORT" "$account@$host" true; then
        log_success "$account logs in."
    else
        log_error "$account could not log in with your loaded keys. Check before closing any open session."
        failures=$((failures + 1))
    fi
done

if ((failures > 0)); then
    exit 1
fi

cat <<EOF

Done. Add this to ~/.ssh/config to shorten the commands, with each
IdentityFile pointing at the matching private key:

Host $host-admin
    HostName $host
    Port $SSH_PORT
    User $ADMIN_USER

Host $host-deploy
    HostName $host
    Port $SSH_PORT
    User $DEPLOY_USER
EOF
