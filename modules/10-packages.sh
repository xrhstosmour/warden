#!/bin/bash
# Bring the system up to date, install what the other modules need, and
# remove what a server facing the internet has no use for.

apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q

install_packages \
    apparmor apparmor-profiles apparmor-profiles-extra apparmor-utils \
    apt-listchanges auditd ca-certificates chrony curl dbus-user-session \
    debsums fail2ban gnupg needrestart nftables python3-systemd rsync \
    slirp4netns sudo uidmap unattended-upgrades

# Survey uploads, plain text remote shells, and firewall front ends that
# would fight `nftables.conf` over the same rules.
purge_packages popularity-contest telnet inetutils-telnet rsh-client rsh-redone-client ufw firewalld

DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q --purge
