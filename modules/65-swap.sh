#!/bin/bash
# A swap file, so a memory spike during a build or a backup slows the
# server down instead of having the kernel kill the database.

if [[ "$SWAP_SIZE" == "0" ]]; then
    exit 0
fi

if [[ -n "$(swapon --noheadings --show=NAME)" ]]; then
    exit 0
fi

if [[ ! -f /swapfile ]]; then
    log_info "Creating a $SWAP_SIZE swap file."
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
fi
swapon /swapfile

if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >>/etc/fstab
fi
