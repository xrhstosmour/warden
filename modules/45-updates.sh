#!/bin/bash
# Security updates every day, restarted services after library updates,
# and a reboot in a quiet window when the kernel needs one. The containers
# come back on their own, Docker starts with the deploy user's session.

place_content /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF' || true
// Managed by warden, local changes are overwritten on the next run.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

place_content /etc/apt/apt.conf.d/52warden-unattended-upgrades 0644 <<EOF || true
// Managed by warden, local changes are overwritten on the next run.
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=\${distro_codename},label=Debian";
    "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=\${distro_codename}-updates";
    "origin=Docker,label=Docker CE";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
Unattended-Upgrade::SyslogEnable "true";
EOF

# Restart services using an updated library without asking.
place_content /etc/needrestart/conf.d/warden.conf 0644 <<'EOF' || true
# Managed by warden, local changes are overwritten on the next run.
$nrconf{restart} = 'a';
EOF

ensure_service unattended-upgrades
