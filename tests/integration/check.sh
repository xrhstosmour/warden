#!/bin/bash
# Checks run inside the integration container after warden, each one a
# property a hardened server must have.

# Each check is a command string for `sh -c`, expanded there.
# shellcheck disable=SC2016

set -uo pipefail

failures=0
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "ok   $description"
    else
        echo "FAIL $description"
        failures=$((failures + 1))
    fi
}

sshd_value() { sshd -T 2>/dev/null | awk -v key="$1" '$1 == key { print $2; exit }'; }

check "SSH listens on 2222" test "$(sshd_value port)" = 2222
check "SSH refuses root" test "$(sshd_value permitrootlogin)" = no
check "SSH refuses passwords" test "$(sshd_value passwordauthentication)" = no
check "the firewall drops inbound by default" sh -c 'nft list chain inet warden input | grep -q "policy drop"'
check "the firewall no longer opens port 22" sh -c '! nft list chain inet warden input | grep -qE "dport (22 |\{ ([0-9]+, )*22[ ,])"'
check "fail2ban watches SSH" fail2ban-client status sshd
check "chrony runs" systemctl is-active chrony
check "unattended upgrades are on" systemctl is-enabled unattended-upgrades
check "the deploy user has no sudo" sh -c '! id -nG deploy | grep -qw sudo'
check "the deploy password is locked" sh -c 'passwd -S deploy | grep -q " L "'
check "the system Docker daemon is masked" sh -c 'test "$(systemctl is-enabled docker.service)" = masked'
check "Docker runs rootless for deploy" sh -c 'sudo -u deploy -H XDG_RUNTIME_DIR=/run/user/$(id -u deploy) docker info --format "{{.SecurityOptions}}" | grep -q rootless'
check "a rootless container runs" sh -c 'sudo -u deploy -H XDG_RUNTIME_DIR=/run/user/$(id -u deploy) docker run --rm hello-world'
check "core dumps are off" sh -c 'grep -q "Storage=none" /etc/systemd/coredump.conf.d/warden.conf'
check "sudo still parses" visudo -cq
check "/etc is in git and committed" sh -c 'test -d /etc/.git && ! etckeeper unclean'

if ((failures > 0)); then
    echo "$failures checks failed." >&2
    exit 1
fi
echo "All checks passed."
