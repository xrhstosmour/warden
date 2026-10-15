#!/bin/bash
# Kernel parameters, unused kernel modules, and BBR congestion control.

place "$WARDEN_DIRECTORY/files/modprobe.conf" /etc/modprobe.d/warden.conf 0644 || true

# BBR is a module, loaded before the parameters that select it.
if printf 'tcp_bbr\n' | place_content /etc/modules-load.d/warden.conf 0644; then
    modprobe tcp_bbr || log_warning "tcp_bbr did not load, congestion control stays on the default."
fi

if place "$WARDEN_DIRECTORY/files/sysctl.conf" /etc/sysctl.d/90-warden.conf 0644; then
    # Some keys do not exist inside a container or on an older kernel, a
    # missing one is reported and the rest still apply.
    sysctl -q -p /etc/sysctl.d/90-warden.conf || log_warning "Some kernel parameters were not applied, see above."
fi
