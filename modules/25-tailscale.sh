#!/bin/bash
# Joins the server to your tailnet, when warden.conf asks for it. Runs
# before the firewall, so with SSH_ACCESS=tailscale the tailnet is up
# before SSH is restricted to it.

uses_tailscale || return 0

# Tailscale's own repository, Debian ships no package.
# shellcheck disable=SC1091 # Present on every Debian system.
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
if [[ ! -f "$keyring" ]]; then
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/$codename.noarmor.gpg" -o "$keyring"
    chmod 0644 "$keyring"
fi
if place_content /etc/apt/sources.list.d/tailscale.list 0644 <<EOF; then
# Managed by warden, local changes are overwritten on the next run.
deb [signed-by=$keyring] https://pkgs.tailscale.com/stable/debian $codename main
EOF
    apt-get update -q
fi

install_packages tailscale
ensure_service tailscaled

ssh_over_tailnet=false
[[ "$TAILSCALE_SSH" == "yes" ]] && ssh_over_tailnet=true

if ! tailscale status >/dev/null 2>&1; then
    [[ -n "$TAILSCALE_AUTH_KEY" ]] ||
        fail "This server is not on a tailnet yet, set TAILSCALE_AUTH_KEY in warden.conf."
    # Read from a file rather than the command line, where every process
    # on the machine can see it.
    key_file=$(mktemp)
    printf '%s' "$TAILSCALE_AUTH_KEY" >"$key_file"
    # The server keeps its own resolver, MagicDNS is for people, and the
    # containers resolve through the host.
    tailscale up --auth-key="file:$key_file" --hostname="$(hostname)" \
        --accept-dns=false --ssh="$ssh_over_tailnet" ||
        {
            rm -f "$key_file"
            fail "Tailscale did not sign in, check that the auth key is valid and unused."
        }
    rm -f "$key_file"
    log_info "Joined the tailnet."
fi

tailscale set --ssh="$ssh_over_tailnet" --accept-dns=false

address=$(tailscale ip -4 | head -1)
[[ -n "$address" ]] || fail "Tailscale is up but has no address."
log_success "On the tailnet as $address."
# Read by `provision.sh`, which logs in here once public SSH is closed.
echo "WARDEN_TAILSCALE_ADDRESS=$address"
