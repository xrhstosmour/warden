#!/bin/bash
# Answer a few questions and get a `warden.conf`, on your own machine:
#
#   ./setup.sh
#
# It copies `warden.conf.example` and appends your answers below it, the
# last assignment wins when the file is sourced, so every comment of the
# example stays. Secrets are asked for without echo. The tunnel token is kept
# in a file only you can read and `warden.conf` only names it, the one-off
# Tailscale auth key goes into `warden.conf` itself, which is written for you
# alone too. Nothing is sent anywhere,
# `provision.sh` does that later. It never overwrites a `warden.conf`. Input
# that ends early stops it before anything is written, so answers can be piped
# in for a test.

set -euo pipefail

WARDEN_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=library/common.sh
source "$WARDEN_DIRECTORY/library/common.sh"
# shellcheck source=library/configuration.sh
source "$WARDEN_DIRECTORY/library/configuration.sh"

target="${WARDEN_CONFIGURATION:-$WARDEN_DIRECTORY/warden.conf}"
secrets_directory="${WARDEN_SECRETS:-$HOME/.warden}"

[[ ! -e "$target" ]] || fail "$target exists, move it away first. setup.sh never overwrites a configuration."

# ask "question" "default", the answer lands in `answer`.
ask() {
    read -r -p "$1 [$2] " answer
    answer="${answer:-$2}"
}

# choose "question" "default" "option|option...", asks again until the answer is one of them.
choose() {
    while true; do
        ask "$1 ($3)" "$2"
        [[ "|$3|" == *"|$answer|"* ]] && return 0
        echo "Pick one of: ${3//|/, }." >&2
    done
}

# A secret is read without echo and never lands in the shell's history.
ask_secret() {
    read -r -s -p "$1: " answer
    echo
}

answers=""
add() {
    answers+="$(printf '%s=%q' "$1" "$2")"$'\n'
}

echo "warden setup, press Enter to take the answer in brackets."
echo

ask "Account you log in with to administer the server" admin
is_username "$answer" || fail "That is not a lowercase user name other than root."
add ADMIN_USER "$answer"

echo
echo "SSH: tailscale keeps SSH off the public address, through your tailnet. public opens it to the internet on SSH_PORT."
choose "How should SSH be reached?" tailscale "tailscale|public"
ssh_access="$answer"
add SSH_ACCESS "$ssh_access"

if [[ "$ssh_access" == "tailscale" ]]; then
    add TAILSCALE_SSH yes
    echo
    echo "Tags: server (SSH only), web (SSH and web from your devices), shared (reaches other shared machines), internal (reaches nothing)."
    choose "Which tailnet tag does this server get?" server "server|web|shared|internal"
    add TAILSCALE_TAG "tag:$answer"
    echo
    echo "A one-off auth key from https://login.tailscale.com/admin/settings/keys lets the server join without a browser. Empty means approving a login URL instead."
    ask_secret "Tailscale auth key, or Enter to skip"
    if [[ -n "$answer" ]]; then
        [[ "$answer" =~ ^tskey-[A-Za-z0-9-]+$ ]] || fail "That is not a Tailscale auth key."
        # Kept in warden.conf, which only you can read, and the key is one-off.
        add TAILSCALE_AUTH_KEY "$answer"
    fi
fi

echo
echo "Web: tunnel brings traffic in through Cloudflare with no public port. ports opens 80 and 443. none opens nothing."
choose "How does web traffic reach the server?" tunnel "tunnel|ports|none"
case "$answer" in
tunnel)
    # One token file per place, another server's token must not be replaced
    # under it, its next provision.sh would join this server to the wrong tunnel.
    token_file="$secrets_directory/cloudflare-tunnel-token"
    [[ ! -e "$token_file" ]] ||
        fail "$token_file exists, probably another server's token. Move it, or set WARDEN_SECRETS to another directory for this server."
    echo
    echo "Create the tunnel in the Zero Trust dashboard under Networks, Tunnels, choose Cloudflared, and copy the token from the install command."
    ask_secret "Tunnel token"
    is_tunnel_token "$answer" || fail "That does not look like a tunnel token."
    (umask 077 && mkdir -p "$secrets_directory")
    (umask 077 && printf '%s\n' "$answer" >"$token_file")
    log_info "Token saved to $token_file, readable by you alone."
    add CLOUDFLARE_TUNNEL_TOKEN_FILE "$token_file"
    add PUBLIC_TCP_PORTS ""
    add PUBLIC_UDP_PORTS ""
    ;;
ports)
    choose "Let only Cloudflare's address ranges reach them?" no "yes|no"
    add CLOUDFLARE_ONLY "$answer"
    ;;
none)
    add PUBLIC_TCP_PORTS ""
    add PUBLIC_UDP_PORTS ""
    ;;
esac

echo
echo "Alerts to your phone through ntfy (disk, failed units, SSH logins) are off. Backups are off. Turn them on in warden.conf, see the comments there."

(umask 077 && {
    cat "$WARDEN_DIRECTORY/warden.conf.example"
    printf '\n# Answers from setup.sh, these win over the lines above.\n%s' "$answers"
} >"$target")

log_success "Wrote $target."
echo "Check it, then run: ./provision.sh <user@host>"
