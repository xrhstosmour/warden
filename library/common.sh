#!/bin/bash
# Shared helpers every module sources. Nothing here changes the system on
# its own, a module decides what to change and these keep it idempotent.

BOLD_CYAN='\e[1;36m'
BOLD_GREEN='\e[1;32m'
BOLD_YELLOW='\e[1;33m'
BOLD_RED='\e[1;31m'
NO_COLOR='\e[0m'

log_info() { echo -e "${BOLD_CYAN}$*${NO_COLOR}" >&2; }
log_success() { echo -e "${BOLD_GREEN}$*${NO_COLOR}" >&2; }
log_warning() { echo -e "${BOLD_YELLOW}$*${NO_COLOR}" >&2; }
log_error() { echo -e "${BOLD_RED}$*${NO_COLOR}" >&2; }

# Print an error and stop the whole run.
fail() {
    log_error "$*"
    exit 1
}

# Install a file only when its content or mode differs from what is there.
# Returns 0 when it changed something, 1 when the target was already right,
# so a caller restarts a service only after a real change:
#   if place "$source" /etc/thing.conf 0644; then systemctl restart thing; fi
place() {
    local source="$1"
    local target="$2"
    local mode="${3:-0644}"

    if [[ -f "$target" ]] && cmp -s "$source" "$target" &&
        [[ "$(stat -c '%a' "$target")" == "${mode#0}" ]]; then
        return 1
    fi

    install -D -m "$mode" -o root -g root "$source" "$target"
    log_info "Updated $target."
    return 0
}

# Same as `place`, for content produced on the fly, read from standard input.
place_content() {
    local target="$1"
    local mode="${2:-0644}"
    local temporary
    temporary=$(mktemp)
    cat >"$temporary"

    local status=0
    place "$temporary" "$target" "$mode" || status=$?
    rm -f "$temporary"
    return "$status"
}

# Same as `place_content`, for a file in a directory its owner controls. The
# owner could swap the directory for a link between root's check and root's
# write, so the write is made as the owner and reaches nothing more than the
# owner could. Returns 0 when it changed something, 1 when it was already right.
place_as_owner() {
    local user="$1"
    local target="$2"
    local mode="${3:-0644}"
    local temporary
    temporary=$(mktemp)
    cat >"$temporary"
    # Read by the owner, and never holds more than a public key or a setting.
    chmod 0644 "$temporary"

    local status=1
    if ! { runuser -u "$user" -- cmp -s "$temporary" "$target" &&
        [[ "$(runuser -u "$user" -- stat -c '%a' "$target")" == "${mode#0}" ]]; }; then
        runuser -u "$user" -- install -m "$mode" "$temporary" "$target"
        log_info "Updated $target."
        status=0
    fi
    rm -f "$temporary"
    return "$status"
}

# The primary key fingerprint of an OpenPGP key file, nothing when the file
# holds more than one key, apt trusts every key in a file it is pointed at.
key_fingerprint() {
    gpg --show-keys --with-colons "$1" 2>/dev/null |
        awk -F: '$1 == "pub" { keys++ } $1 == "fpr" && !fingerprint { fingerprint = $10 } END { if (keys == 1) print fingerprint }'
}

# Place a repository's signing key, refusing one whose fingerprint is not
# the vendor's published one, so a swapped key is never trusted. Checked on
# every run, not only the first.
# place_signing_key "url" "target" "fingerprint"
place_signing_key() {
    local url="$1"
    local target="$2"
    local fingerprint="$3"

    if [[ -f "$target" && "$(key_fingerprint "$target")" == "$fingerprint" ]]; then
        return 0
    fi
    local temporary
    temporary=$(mktemp)
    curl -fsSL "$url" -o "$temporary" || {
        rm -f "$temporary"
        fail "Could not download the signing key from $url."
    }
    if [[ "$(key_fingerprint "$temporary")" != "$fingerprint" ]]; then
        rm -f "$temporary"
        fail "The signing key from $url is not the expected $fingerprint."
    fi
    mkdir -p "$(dirname "$target")"
    install -m 0644 "$temporary" "$target"
    rm -f "$temporary"
}

# Install packages that are missing, quietly and without prompts.
install_packages() {
    local missing=()
    local package
    for package in "$@"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$package")
        fi
    done

    if ((${#missing[@]} > 0)); then
        log_info "Installing ${missing[*]}."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${missing[@]}"
    fi
}

# Remove packages that are present, with their configuration.
purge_packages() {
    local present=()
    local package
    for package in "$@"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            present+=("$package")
        fi
    done

    if ((${#present[@]} > 0)); then
        log_info "Removing ${present[*]}."
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${present[@]}"
    fi
}

# Enable a unit and make sure it runs, restarting it when asked to.
# ensure_service "unit" ["restart"]
ensure_service() {
    local unit="$1"
    local action="${2:-}"

    systemctl enable -q "$unit"
    if [[ "$action" == "restart" ]]; then
        systemctl restart "$unit"
    elif ! systemctl is-active -q "$unit"; then
        systemctl start "$unit"
    fi
}
