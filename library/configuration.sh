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
TAILSCALE_TAG="${TAILSCALE_TAG:-}"
PUBLIC_TCP_PORTS="${PUBLIC_TCP_PORTS:-80 443}"
PUBLIC_UDP_PORTS="${PUBLIC_UDP_PORTS:-443}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"
TIMEZONE="${TIMEZONE:-UTC}"
REBOOT_TIME="${REBOOT_TIME:-04:00}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
ETCKEEPER="${ETCKEEPER:-yes}"
LOGIN_STATUS="${LOGIN_STATUS:-yes}"
AUDIT_TOOL="${AUDIT_TOOL:-yes}"
DOCKER_ADDRESS_POOL="${DOCKER_ADDRESS_POOL-172.30.0.0/16}"
ALERTS="${ALERTS:-no}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
ALERT_DISK_PERCENT="${ALERT_DISK_PERCENT:-85}"
ALERT_SSH_LOGIN="${ALERT_SSH_LOGIN:-yes}"
CLOUDFLARE_ONLY="${CLOUDFLARE_ONLY:-no}"
BACKUP_REPOSITORY="${BACKUP_REPOSITORY:-}"
BACKUP_PASSWORD_FILE="${BACKUP_PASSWORD_FILE:-}"
BACKUP_SSH_KEY_FILE="${BACKUP_SSH_KEY_FILE:-}"
BACKUP_RCLONE_CONFIG_FILE="${BACKUP_RCLONE_CONFIG_FILE:-}"
BACKUP_HOST_KEY="${BACKUP_HOST_KEY:-}"
BACKUP_SSH_PORT="${BACKUP_SSH_PORT:-22}"
BACKUP_PATHS="${BACKUP_PATHS:-/home}"
BACKUP_TIME="${BACKUP_TIME:-03:30}"
BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"

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

# Whether the only way to log in is Tailscale SSH on port 22, the one SSH
# port the tailnet policy grants.
uses_tailscale_ssh_login() {
    [[ "$SSH_ACCESS" == "tailscale" && "$TAILSCALE_SSH" == "yes" ]]
}

# Minutes after SSH moved until public SSH comes back when nobody proves a
# tailnet login. Tailscale SSH asks for a browser approval first, which takes
# long. The 40 counts up to 9 for the first backup, 15 for the approvals of
# both accounts (`login_approval_seconds` in `provision.sh`), 10 for the final
# login with its `sudo` password, and the rest for the upload and `etckeeper`.
rollback_minutes() {
    echo 40
}

# Whether new Docker networks take their ranges from a warden pool.
uses_docker_pool() {
    [[ -n "$DOCKER_ADDRESS_POOL" ]]
}

# Whether alerts are sent to a phone.
uses_alerts() {
    [[ "$ALERTS" == "ntfy" ]]
}

# Whether public ports answer Cloudflare's ranges alone.
uses_cloudflare() {
    [[ "$CLOUDFLARE_ONLY" == "yes" ]]
}

# Whether encrypted backups run.
uses_backups() {
    [[ -n "$BACKUP_REPOSITORY" ]]
}

# A public key line as `ssh-keygen` writes it, with an optional comment. The
# comment is limited to characters the shell leaves alone, because the server
# sources the line as bash before it validates anything. `provision.sh` runs
# this check on the operator's machine first, and quotes the line with `%q`.
is_public_key() {
    [[ "$1" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-rsa)\ [A-Za-z0-9+/]+={0,3}(\ [A-Za-z0-9@._+=:/\ -]*)?$ ]]
}

is_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && [[ "$1" != "root" ]]
}

# A network in the private blocks, wide enough to be cut into /24 networks,
# written with the host bits zero the way Docker wants it.
is_private_pool() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    local first=$((10#${BASH_REMATCH[1]})) second=$((10#${BASH_REMATCH[2]}))
    local third=$((10#${BASH_REMATCH[3]})) fourth=$((10#${BASH_REMATCH[4]})) prefix=$((10#${BASH_REMATCH[5]}))

    ((first <= 255 && second <= 255 && third <= 255 && fourth <= 255)) || return 1
    ((prefix >= 8 && prefix <= 24)) || return 1
    ((first == 10 || (first == 172 && second >= 16 && second <= 31) || (first == 192 && second == 168))) || return 1

    local address=$(((first << 24) | (second << 16) | (third << 8) | fourth))
    local mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    (((address & ~mask & 0xFFFFFFFF) == 0))
}

# A `known_hosts` line, the host (or [host]:port) and its public key.
is_host_key() {
    [[ "$1" =~ ^(\[[A-Za-z0-9.-]+\]:[0-9]{1,5}|[A-Za-z0-9.-]+)\ (ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)\ [A-Za-z0-9+/]+={0,3}$ ]]
}

is_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && (("$1" >= 1 && "$1" <= 65535))
}

# Whether the JSON of `tailscale status --json`, on standard input, lists the
# given tag on this machine.
has_tailscale_tag() {
    python3 -c 'import json, sys; sys.exit(0 if sys.argv[1] in (json.load(sys.stdin)["Self"].get("Tags") or []) else 1)' "$1"
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
    # No default, an untagged machine of the owner counts as a personal device
    # in the tailnet policy and reaches everything.
    if uses_tailscale && [[ ! "$TAILSCALE_TAG" =~ ^tag:(server|web|shared|internal)$ ]]; then
        problems+=("TAILSCALE_TAG must be tag:server, tag:web, tag:shared or tag:internal, a server without a tag gets the access of a personal device.")
    fi
    # The policy grants the tailnet port 22 only, plain sshd listens elsewhere.
    if [[ "$SSH_ACCESS" == "tailscale" && "$TAILSCALE_SSH" != "yes" ]]; then
        problems+=("SSH_ACCESS=tailscale needs TAILSCALE_SSH=yes, the tailnet policy only grants port 22, which Tailscale SSH serves.")
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
    [[ "$CLOUDFLARE_ONLY" =~ ^(yes|no)$ ]] || problems+=("CLOUDFLARE_ONLY must be yes or no.")
    [[ "$ALERTS" =~ ^(no|ntfy)$ ]] || problems+=("ALERTS must be no or ntfy.")
    [[ "$NTFY_SERVER" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || problems+=("NTFY_SERVER must be an https address, such as https://ntfy.sh.")
    [[ "$ALERT_DISK_PERCENT" =~ ^([5-9][0-9])$ ]] || problems+=("ALERT_DISK_PERCENT must be from 50 to 99.")
    [[ "$ALERT_SSH_LOGIN" =~ ^(yes|no)$ ]] || problems+=("ALERT_SSH_LOGIN must be yes or no.")
    if [[ -n "$BACKUP_REPOSITORY" ]]; then
        local backup_kind=""
        [[ "$BACKUP_REPOSITORY" =~ ^sftp:[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+:/[A-Za-z0-9._/-]*$ ]] && backup_kind=sftp
        [[ "$BACKUP_REPOSITORY" =~ ^rclone:[A-Za-z0-9_-]+:[A-Za-z0-9._/-]*$ ]] && backup_kind=rclone
        [[ -n "$backup_kind" ]] || problems+=("BACKUP_REPOSITORY must look like sftp:user@host:/path or rclone:remote:path.")
        [[ -n "$BACKUP_PASSWORD_FILE" ]] || problems+=("BACKUP_PASSWORD_FILE is needed with BACKUP_REPOSITORY, the file holding the restic password.")
        if [[ "$backup_kind" == "sftp" ]]; then
            [[ -n "$BACKUP_SSH_KEY_FILE" ]] || problems+=("BACKUP_SSH_KEY_FILE is needed for an sftp repository, a private key made for backups only.")
            if ! is_host_key "$BACKUP_HOST_KEY"; then
                problems+=("BACKUP_HOST_KEY must be the target's known_hosts line, from ssh-keyscan, so the host is never trusted blindly.")
            else
                # ssh looks the key up under the host, and under [host]:port for any port but 22.
                local backup_host="${BACKUP_REPOSITORY#*@}"
                backup_host="${backup_host%%:*}"
                local expected_host="$backup_host"
                [[ "$BACKUP_SSH_PORT" == "22" ]] || expected_host="[$backup_host]:$BACKUP_SSH_PORT"
                [[ "${BACKUP_HOST_KEY%% *}" == "$expected_host" ]] ||
                    problems+=("BACKUP_HOST_KEY must start with $expected_host, the host and port the backups connect to.")
            fi
        fi
        if [[ "$backup_kind" == "rclone" && -z "$BACKUP_RCLONE_CONFIG_FILE" ]]; then
            problems+=("BACKUP_RCLONE_CONFIG_FILE is needed for an rclone repository, the rclone.conf made on your machine.")
        fi
    fi
    is_port "$BACKUP_SSH_PORT" || problems+=("BACKUP_SSH_PORT must be a port number.")
    [[ "$BACKUP_PATHS" =~ ^/[A-Za-z0-9._/-]*( /[A-Za-z0-9._/-]*)*$ ]] || problems+=("BACKUP_PATHS must be absolute paths separated by spaces.")
    [[ "$BACKUP_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || problems+=("BACKUP_TIME must be HH:MM.")
    local keep
    for keep in "$BACKUP_KEEP_DAILY" "$BACKUP_KEEP_WEEKLY" "$BACKUP_KEEP_MONTHLY"; do
        [[ "$keep" =~ ^[0-9]{1,4}$ ]] || problems+=("BACKUP_KEEP_DAILY, BACKUP_KEEP_WEEKLY and BACKUP_KEEP_MONTHLY must be numbers.")
    done
    if [[ -n "$DOCKER_ADDRESS_POOL" ]] && ! is_private_pool "$DOCKER_ADDRESS_POOL"; then
        problems+=("DOCKER_ADDRESS_POOL must be a private IPv4 range from /8 to /24, such as 172.30.0.0/16, or empty for Docker's own.")
    fi

    if ((${#problems[@]} > 0)); then
        printf '%s\n' "${problems[@]}" >&2
        return 1
    fi
}

# One row of the feature list: name, on or off, and the setting that changes it.
print_feature() {
    printf '  %-20s %-4s %s\n' "$1" "$2" "$3"
}

# One line per optional feature, on or off, and the setting that changes it,
# so nothing is switched on or off without being told.
describe_features() {
    echo "Optional features, change them in warden.conf and run again:"
    print_feature "etckeeper" "$([[ "$ETCKEEPER" == yes ]] && echo on || echo off)" "ETCKEEPER, /etc in git"
    print_feature "login status" "$([[ "$LOGIN_STATUS" == yes ]] && echo on || echo off)" "LOGIN_STATUS, a status line on SSH login"
    print_feature "warden-audit" "$([[ "$AUDIT_TOOL" == yes ]] && echo on || echo off)" "AUDIT_TOOL, sudo warden-audit"
    print_feature "Tailscale" "$(uses_tailscale && echo on || echo off)" "SSH_ACCESS, TAILSCALE_SSH, TAILSCALE_AUTH_KEY, TAILSCALE_TAG"
    print_feature "Docker address pool" "$(uses_docker_pool && echo on || echo off)" "DOCKER_ADDRESS_POOL=${DOCKER_ADDRESS_POOL:-the Docker default}"
    print_feature "alerts" "$(uses_alerts && echo on || echo off)" "ALERTS=ntfy, phone alerts for disk, units and SSH logins"
    print_feature "backups" "$(uses_backups && echo on || echo off)" "BACKUP_REPOSITORY, encrypted restic backups"
    print_feature "Cloudflare only" "$(uses_cloudflare && echo on || echo off)" "CLOUDFLARE_ONLY, public ports for Cloudflare alone"
}
