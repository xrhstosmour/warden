#!/bin/bash
# Reads and checks `warden.conf`. Every module trusts the values after
# `validate_configuration`, so anything a module writes into a system file
# is checked here first.

# Defaults, a configuration file overrides any of them.
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PUBLIC_KEY="${ADMIN_PUBLIC_KEY:-}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_PUBLIC_KEY="${DEPLOY_PUBLIC_KEY:-}"
SSH_PORT="${SSH_PORT:-}"
SSH_SOURCES="${SSH_SOURCES:-}"
SSH_ACCESS="${SSH_ACCESS:-public}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_SSH="${TAILSCALE_SSH:-no}"
PUBLIC_TCP_PORTS="${PUBLIC_TCP_PORTS:-80 443}"
PUBLIC_UDP_PORTS="${PUBLIC_UDP_PORTS:-443}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
TIMEZONE="${TIMEZONE:-UTC}"
REBOOT_TIME="${REBOOT_TIME:-04:00}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
ETCKEEPER="${ETCKEEPER:-yes}"
LOGIN_STATUS="${LOGIN_STATUS:-yes}"
AUDIT_TOOL="${AUDIT_TOOL:-yes}"

# Source a configuration file. It is plain `KEY=value` lines, sourced as
# bash, so it must be root's own file and nobody else's to write.
load_configuration() {
    local file="$1"
    [[ -f "$file" ]] || fail "No configuration at $file, copy warden.conf.example and fill it in."

    # shellcheck disable=SC1090 # The path is chosen at run time.
    source "$file"
}

# Whether this server joins a tailnet at all.
uses_tailscale() {
    [[ "$SSH_ACCESS" == "tailscale" || "$TAILSCALE_SSH" == "yes" || -n "$TAILSCALE_AUTH_KEY" ]]
}

# A public key line as `ssh-keygen` writes it, with an optional comment.
is_public_key() {
    [[ "$1" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)\ [A-Za-z0-9+/]+={0,3}(\ [^[:cntrl:]]*)?$ ]]
}

is_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && [[ "$1" != "root" ]]
}

is_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (("$1" >= 1 && "$1" <= 65535))
}

# Print every problem, then return non-zero if there was any, so one run
# shows the whole list instead of one mistake at a time.
validate_configuration() {
    local problems=()

    is_username "$ADMIN_USER" || problems+=("ADMIN_USER must be a lowercase user name other than root.")
    is_username "$DEPLOY_USER" || problems+=("DEPLOY_USER must be a lowercase user name other than root.")
    [[ "$ADMIN_USER" != "$DEPLOY_USER" ]] || problems+=("ADMIN_USER and DEPLOY_USER must differ, the deploy user has no sudo.")
    is_public_key "$ADMIN_PUBLIC_KEY" || problems+=("ADMIN_PUBLIC_KEY must be one public key line, such as ssh-ed25519 AAAA... name.")
    is_public_key "$DEPLOY_PUBLIC_KEY" || problems+=("DEPLOY_PUBLIC_KEY must be one public key line, such as ssh-ed25519 AAAA... name.")

    # Port 22 draws nearly all of the automated guessing, a different port
    # keeps the logs readable. It is not a defence on its own.
    if ! is_port "$SSH_PORT" || ((SSH_PORT < 1024)); then
        problems+=("SSH_PORT must be a port from 1024 to 65535.")
    fi

    local port
    for port in $PUBLIC_TCP_PORTS $PUBLIC_UDP_PORTS; do
        is_port "$port" || problems+=("Public port '$port' is not a port number.")
    done
    for port in $PUBLIC_TCP_PORTS; do
        [[ "$port" != "$SSH_PORT" ]] || problems+=("SSH_PORT must not also be listed as a public port.")
    done

    [[ "$SSH_ACCESS" =~ ^(public|tailscale)$ ]] || problems+=("SSH_ACCESS must be public or tailscale.")
    [[ "$TAILSCALE_SSH" =~ ^(yes|no)$ ]] || problems+=("TAILSCALE_SSH must be yes or no.")
    if [[ -n "$TAILSCALE_AUTH_KEY" && ! "$TAILSCALE_AUTH_KEY" =~ ^tskey-[A-Za-z0-9-]+$ ]]; then
        problems+=("TAILSCALE_AUTH_KEY must be a Tailscale auth key, tskey-auth-...")
    fi
    if [[ "$SSH_ACCESS" == "tailscale" && -n "$SSH_SOURCES" ]]; then
        problems+=("SSH_SOURCES and SSH_ACCESS=tailscale exclude each other, the tailnet decides who reaches SSH.")
    fi

    local source
    for source in $SSH_SOURCES; do
        [[ "$source" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]] || problems+=("SSH_SOURCES entry '$source' is not an address or CIDR range.")
    done

    if [[ -n "$SERVER_HOSTNAME" && ! "$SERVER_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        problems+=("SERVER_HOSTNAME must be a single label, such as app-1.")
    fi
    [[ "$TIMEZONE" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || problems+=("TIMEZONE must look like UTC or Europe/Athens.")
    [[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || problems+=("REBOOT_TIME must be HH:MM.")
    [[ "$SWAP_SIZE" =~ ^([0-9]+[MG]|0)$ ]] || problems+=("SWAP_SIZE must be like 2G, 512M, or 0 for none.")
    [[ "$ETCKEEPER" =~ ^(yes|no)$ ]] || problems+=("ETCKEEPER must be yes or no.")
    [[ "$LOGIN_STATUS" =~ ^(yes|no)$ ]] || problems+=("LOGIN_STATUS must be yes or no.")
    [[ "$AUDIT_TOOL" =~ ^(yes|no)$ ]] || problems+=("AUDIT_TOOL must be yes or no.")

    if ((${#problems[@]} > 0)); then
        printf '%s\n' "${problems[@]}" >&2
        return 1
    fi
}
