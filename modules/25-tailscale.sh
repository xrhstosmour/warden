#!/bin/bash
# Joins the server to your tailnet, when warden.conf asks for it. Runs
# before the firewall, so with SSH_ACCESS=tailscale the tailnet is up
# before SSH is restricted to it.

uses_tailscale || return 0

# Tailscale's own repository, Debian ships no package.
# shellcheck disable=SC1091 # Present on every Debian system.
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
keyring=/usr/share/keyrings/tailscale-archive-keyring.gpg
# The fingerprint of Tailscale's package signing key.
place_signing_key "https://pkgs.tailscale.com/stable/debian/$codename.noarmor.gpg" "$keyring" \
    2596A99EAAB33821893C0A79458CA832957F5868
if place_content /etc/apt/sources.list.d/tailscale.list 0644 <<EOF; then
# Managed by warden, local changes are overwritten on the next run.
deb [signed-by=$keyring] https://pkgs.tailscale.com/stable/debian $codename main
EOF
    apt-get update -q
fi

install_packages tailscale
ensure_service tailscaled

ssh_over_tailnet=false
uses_tailscale_ssh && ssh_over_tailnet=true

if ! tailscale status >/dev/null 2>&1; then
    # The server keeps its own resolver, MagicDNS is for people, and the
    # containers resolve through the host.
    # The tag is applied at enrollment, the tailnet policy gives an untagged
    # machine the access of a personal device.
    up_options=(--hostname="$(hostname)" --accept-dns=false --ssh="$ssh_over_tailnet" --advertise-tags="$TAILSCALE_TAG")
    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        # Read from a file rather than the command line, where every
        # process on the machine can see it.
        key_file=$(mktemp)
        printf '%s' "$TAILSCALE_AUTH_KEY" >"$key_file"
        tailscale up --auth-key="file:$key_file" "${up_options[@]}" ||
            {
                rm -f "$key_file"
                fail "Tailscale did not sign in, check that the auth key is valid and unused."
            }
        rm -f "$key_file"
    else
        # Without a key, Tailscale prints a login URL and waits until it
        # is approved in a browser.
        log_info "Open the login URL below in your browser to add this server to your tailnet."
        tailscale up --timeout=10m "${up_options[@]}" ||
            fail "Tailscale did not sign in, the login URL was not approved in time."
    fi
    log_info "Joined the tailnet."
fi

# A server that joined earlier without the tag stays untagged, so it is
# refused rather than retagged behind the owner's back.
tailscale status --json | has_tailscale_tag "$TAILSCALE_TAG" ||
    fail "This server is on the tailnet without $TAILSCALE_TAG. Tag it in the Tailscale admin console and run again."

tailscale set --ssh="$ssh_over_tailnet" --accept-dns=false

address=$(tailscale ip -4 | head -1)
[[ -n "$address" ]] || fail "Tailscale is up but has no address."
log_success "On the tailnet as $address."
# Read by `provision.sh`, which logs in here once public SSH is closed.
echo "WARDEN_TAILSCALE_ADDRESS=$address"
