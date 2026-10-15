#!/bin/bash
# Make the two key pairs warden expects, on your own machine, never on the
# server. One for the admin, one for deployments, so either can be revoked
# alone.
#
#   ./keys.sh <server-name> [directory]
#
# Writes <directory>/<server-name>_admin and <server-name>_deploy, with
# their .pub files, and prints the lines to put in warden.conf.

set -euo pipefail

name="${1:-}"
directory="${2:-$HOME/.ssh}"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Usage: ./keys.sh <server-name> [directory]" >&2
    exit 1
}

mkdir -p "$directory"
chmod 0700 "$directory"

for role in admin deploy; do
    key="$directory/${name}_$role"
    if [[ -e "$key" ]]; then
        echo "$key exists, kept it." >&2
        continue
    fi
    # 100 rounds of key derivation make a stolen, encrypted key file slow to
    # brute force. Leave the passphrase empty only for a key a deployment
    # pipeline has to use unattended.
    echo "Passphrase for the $role key:" >&2
    ssh-keygen -q -t ed25519 -a 100 -C "${name}_$role" -f "$key"
done

echo
echo "ADMIN_PUBLIC_KEY=\"$(cat "$directory/${name}_admin.pub")\""
echo "DEPLOY_PUBLIC_KEY=\"$(cat "$directory/${name}_deploy.pub")\""
