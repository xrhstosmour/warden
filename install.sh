#!/bin/bash
# Harden a fresh Debian 13 server for hosting containers. Run as root on
# the server:
#
#   sudo ./install.sh [path/to/warden.conf]
#
# Every module is idempotent, running this again applies only what drifted.
# `provision.sh` does the copying and running from your own machine.

set -euo pipefail

WARDEN_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export WARDEN_DIRECTORY

# shellcheck source=library/common.sh
source "$WARDEN_DIRECTORY/library/common.sh"
# shellcheck source=library/configuration.sh
source "$WARDEN_DIRECTORY/library/configuration.sh"
# shellcheck source=library/render.sh
source "$WARDEN_DIRECTORY/library/render.sh"

[[ $EUID -eq 0 ]] || fail "Run as root, sudo ./install.sh."

# shellcheck disable=SC1091 # Present on every Debian system.
source /etc/os-release
if [[ "${ID:-}" != "debian" ]]; then
    fail "This is ${PRETTY_NAME:-an unknown system}, warden supports Debian only."
fi
if [[ "${VERSION_CODENAME:-}" != "trixie" ]]; then
    log_warning "Written for Debian 13 trixie, this is ${PRETTY_NAME:-unknown}. Continuing."
fi

load_configuration "${1:-$WARDEN_DIRECTORY/warden.conf}"
validate_configuration || fail "Fix warden.conf and run again."

# Each module runs in a subshell, so a variable set in one never leaks
# into the next, and a failure stops the whole run.
for module in "$WARDEN_DIRECTORY"/modules/*.sh; do
    name=$(basename "$module" .sh)
    log_info "== ${name#*-}"
    # shellcheck disable=SC1090 # Modules are found at run time.
    (source "$module")
done

describe_features >&2
log_success "Done. Log in as $ADMIN_USER on port $SSH_PORT from a new terminal before closing this one."
if [[ -f /var/run/reboot-required ]]; then
    log_warning "A reboot is needed to finish, run sudo reboot once the new login works."
fi
