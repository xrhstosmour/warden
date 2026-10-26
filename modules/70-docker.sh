#!/bin/bash
# Rootless Docker for the deploy user. The daemon and every container run
# as that user, so breaking out of a container lands in an account with no
# sudo, not in root. The system wide daemon is installed only for its
# binaries and stays masked.

deploy_uid=$(id -u "$DEPLOY_USER")
deploy_home=$(getent passwd "$DEPLOY_USER" | cut -d: -f6)
runtime="/run/user/$deploy_uid"

# Run a command as the deploy user, inside its own systemd session.
as_deploy() {
    sudo -u "$DEPLOY_USER" -H \
        XDG_RUNTIME_DIR="$runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
        "$@"
}

# Docker's own repository, Debian's package lags behind and has no compose
# plugin.
architecture=$(dpkg --print-architecture)
# shellcheck disable=SC1091 # Present on every Debian system.
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
# The fingerprint Docker publishes in its installation guide.
place_signing_key https://download.docker.com/linux/debian/gpg /etc/apt/keyrings/docker.asc \
    9DC858229FC7DD38854AE2D88D81803C0EBFCD88
if place_content /etc/apt/sources.list.d/docker.sources 0644 <<EOF; then
# Managed by warden, local changes are overwritten on the next run.
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -q
fi

install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin docker-ce-rootless-extras

# Nothing but the deploy user's daemon may run containers on this machine.
for unit in docker.service docker.socket containerd.service; do
    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" != "masked" ]]; then
        systemctl disable -q --now "$unit" 2>/dev/null || true
        systemctl mask -q "$unit"
        log_info "Masked the system wide $unit."
    fi
done
rm -f /var/run/docker.sock

# Let the deploy user's containers set memory, CPU and process limits.
if place_content /etc/systemd/system/user@.service.d/delegate.conf 0644 <<'EOF'; then
# Managed by warden, local changes are overwritten on the next run.
[Service]
Delegate=cpu cpuset io memory pids
EOF
    systemctl daemon-reload
fi

# The deploy user's systemd starts at boot without anyone logging in, and
# with it Docker and the containers.
loginctl enable-linger "$DEPLOY_USER"
for _ in $(seq 1 30); do
    [[ -S "$runtime/bus" ]] && break
    sleep 1
done
[[ -S "$runtime/bus" ]] || fail "The deploy user's systemd session did not start."

# The real client address has to reach the proxy, for rate limits, bans,
# and logs. RootlessKit 3 keeps it when Docker's own proxy is off, older
# releases only with the slower slirp4netns port driver.
rootlesskit_major=$(rootlesskit --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
rootlesskit_major="${rootlesskit_major:-0}"

daemon_options='"log-driver": "local",
    "log-opts": { "max-size": "20m", "max-file": "5" },
    "no-new-privileges": true'
# New container networks take their ranges from here, so they never overlap
# a VPN or provider network. Existing networks keep the range they have.
if uses_docker_pool; then
    daemon_options+=",
    \"default-address-pools\": [{ \"base\": \"$DOCKER_ADDRESS_POOL\", \"size\": 24 }]"
fi
if ((rootlesskit_major >= 3)); then
    daemon_options+=',
    "userland-proxy": false'
fi

configuration_changed=false
# The deploy user owns these paths and could swap one for a link at any time.
# Everything in them is made as that user, so a swapped link can only reach
# what the user could already reach.
as_owner() { runuser -u "$DEPLOY_USER" -- "$@"; }
as_owner install -d -m 0700 "$deploy_home/.config" "$deploy_home/.config/docker"
if printf '{\n    %s\n}\n' "$daemon_options" | place_as_owner "$DEPLOY_USER" "$deploy_home/.config/docker/daemon.json" 0600; then
    configuration_changed=true
fi

override="$deploy_home/.config/systemd/user/docker.service.d/override.conf"
if ((rootlesskit_major < 3)); then
    as_owner install -d -m 0700 \
        "$deploy_home/.config/systemd" "$deploy_home/.config/systemd/user" \
        "$deploy_home/.config/systemd/user/docker.service.d"
    if place_as_owner "$DEPLOY_USER" "$override" 0644 <<'EOF'; then
# Managed by warden, local changes are overwritten on the next run.
[Service]
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns"
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns"
EOF
        configuration_changed=true
    fi
fi

# Docker 29 will not create its bridge network unless this module is loaded,
# the daemon stops with "bridge-nf-call-iptables: no such file". It is the
# host's module, rootless Docker cannot load it, so it is loaded now and at
# every boot.
if printf 'br_netfilter\n' | place_content /etc/modules-load.d/warden-docker.conf 0644; then
    modprobe br_netfilter || log_warning "br_netfilter did not load, rootless Docker may not start."
fi

if [[ ! -f "$deploy_home/.config/systemd/user/docker.service" ]]; then
    # The setup tool refuses to run until the netfilter module is loaded,
    # and skipping that check would switch container networking off.
    modprobe nf_tables 2>/dev/null || true
    log_info "Installing rootless Docker for $DEPLOY_USER."
    as_deploy dockerd-rootless-setuptool.sh install
    configuration_changed=true
fi

as_deploy systemctl --user daemon-reload
as_deploy systemctl --user enable -q docker
if [[ "$configuration_changed" == true ]]; then
    as_deploy systemctl --user restart docker
fi

# Plain `docker` and `docker compose` reach the rootless daemon, also over
# a non-interactive SSH session, which reads no shell profile.
as_deploy docker context use rootless >/dev/null

as_deploy docker info --format '{{.SecurityOptions}}' | grep -q rootless ||
    fail "Docker for $DEPLOY_USER is not running rootless."
log_success "Rootless Docker runs for $DEPLOY_USER."
