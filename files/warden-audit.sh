#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Reads this server's state and reports whether it still matches what warden
# sets up. Changes nothing, run it as root: sudo warden-audit

# Each check is a command string for `sh -c`, expanded there.
# shellcheck disable=SC2016

set -uo pipefail

[[ $EUID -eq 0 ]] || {
    echo "Run as root, sudo warden-audit." >&2
    exit 1
}

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
sysctl_value() { sysctl -n "$1" 2>/dev/null; }

check "SSH is not on port 22" test "$(sshd_value port)" != 22
check "SSH refuses root" test "$(sshd_value permitrootlogin)" = no
check "SSH refuses passwords" test "$(sshd_value passwordauthentication)" = no
check "the firewall drops inbound by default" sh -c 'nft list chain inet warden input | grep -q "policy drop"'
check "no other firewall front end is installed" sh -c '! dpkg -s ufw firewalld 2>/dev/null | grep -q "Status: install ok installed"'
check "fail2ban watches SSH" fail2ban-client status sshd
check "unattended upgrades are on" systemctl is-enabled unattended-upgrades
check "auditd runs" systemctl is-active auditd
check "AppArmor is enabled" aa-enabled -q
check "the system Docker daemon is masked" sh -c 'test "$(systemctl is-enabled docker.service 2>/dev/null)" = masked'
check "nobody is in the docker group" sh -c '! getent group docker | cut -d: -f4 | grep -q .'
check "kernel pointers are hidden" test "$(sysctl_value kernel.kptr_restrict)" = 2
check "ptrace is limited to parents" test "$(sysctl_value kernel.yama.ptrace_scope)" -ge 2
check "SYN cookies are on" test "$(sysctl_value net.ipv4.tcp_syncookies)" = 1
check "user namespaces stay on for rootless Docker" test "$(sysctl_value user.max_user_namespaces)" -gt 0
check "core dumps are off" sh -c 'grep -q "Storage=none" /etc/systemd/coredump.conf.d/warden.conf'
check "sudo still parses" visudo -cq

if ((failures > 0)); then
    echo "$failures check(s) failed." >&2
    exit 1
fi
echo "All checks passed."
