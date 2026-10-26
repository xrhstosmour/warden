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
check "the SSH login hook is in the PAM stack exactly once" sh -c 'test "$(grep -c warden-alert-login /etc/pam.d/sshd)" = 1'
check "unattended upgrades keep the edited PAM file" grep -q force-confold /etc/apt/apt.conf.d/52warden-confold
check "Cloudflare ranges are in the firewall sets" sh -c 'nft list set inet warden cloudflare4 | grep -q 173.245.48.0/20 && nft list set inet warden cloudflare6 | grep -q 2400:cb00::/32'
check "the Cloudflare sync timer is on" systemctl is-enabled warden-cloudflare-sync.timer
check "the public ports answer the Cloudflare set" sh -c 'nft list ruleset | grep -q "ip saddr @cloudflare4 tcp dport"'
check "the backup timer is on" systemctl is-enabled warden-backup.timer
check "the first backup made a snapshot" /usr/local/sbin/warden-backup has-snapshots
check "a backup restores" env WARDEN_VERIFY_FILE=/etc/passwd /usr/local/sbin/warden-backup verify
check "the backup secrets are readable by root alone" sh -c 'test "$(stat -c %a /var/lib/warden/backup/password)" = 600 && test "$(stat -c %a /var/lib/warden/backup/rclone.conf)" = 600'
check "the uploaded backup secrets are deleted" sh -c '! test -e /root/warden/secrets/password && ! test -e /root/warden/secrets/rclone.conf'
check "br_netfilter loads at boot for rootless Docker" grep -qx br_netfilter /etc/modules-load.d/warden-docker.conf
check "the alert topic is readable by root alone" sh -c 'test "$(stat -c %a /var/lib/warden/ntfy-topic)" = 600'
check "the login status is installed" test -f /etc/profile.d/warden-status.sh
check "warden-audit is installed" test -x /usr/local/sbin/warden-audit
check "/etc is in git and committed" sh -c 'test -d /etc/.git && ! etckeeper unclean'

if ((failures > 0)); then
    echo "$failures checks failed." >&2
    exit 1
fi
echo "All checks passed."
