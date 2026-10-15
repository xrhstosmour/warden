#!/bin/bash
# Shared memory and the temporary directory are writable by everyone, so
# nothing placed there may run as a program or act as a device. Debian 13
# already mounts `/tmp` as tmpfs without devices or set-user-ID.

if ! grep -qE '^[^#]*[[:space:]]/dev/shm[[:space:]]' /etc/fstab; then
    echo "tmpfs /dev/shm tmpfs defaults,nosuid,nodev,noexec 0 0" >>/etc/fstab
    log_info "Added /dev/shm to /etc/fstab."
fi
mount -o remount,nosuid,nodev,noexec /dev/shm || log_warning "Could not remount /dev/shm, it applies after a reboot."
