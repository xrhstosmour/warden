#!/bin/bash
# Bring the system up to date, install what the other modules need, and
# remove what a server facing the internet has no use for.

# An index under a day old is not fetched again on every run. The stamp is
# warden's own, written after a successful update, and the lists check covers
# an image whose package lists were cleaned after it.
stamp="${WARDEN_STATE_DIRECTORY:-/var/lib/warden}/apt-updated"
if [[ -z "$(find "$stamp" -mmin -1440 -print -quit 2>/dev/null)" ]] || ! compgen -G '/var/lib/apt/lists/*_Packages*' >/dev/null; then
    apt-get update -q
    mkdir -p "$(dirname "$stamp")"
    touch "$stamp"
fi
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q

install_packages \
    apparmor apparmor-profiles apparmor-profiles-extra apparmor-utils \
    apt-listchanges auditd ca-certificates chrony curl dbus-user-session \
    debsums fail2ban gnupg libpam-tmpdir needrestart nftables python3-systemd rsync \
    slirp4netns sudo uidmap unattended-upgrades

# Survey uploads, plain text remote shells, and firewall front ends that
# would fight `nftables.conf` over the same rules.
purge_packages popularity-contest telnet inetutils-telnet rsh-client rsh-redone-client ufw firewalld

DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q --purge
