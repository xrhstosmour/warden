# A stand-in for a fresh Debian 13 VPS: systemd as PID 1, an SSH server,
# and the provider's default sudo user. Privileged, warden manages the
# firewall, kernel parameters and nested rootless containers.
FROM debian:trixie

ENV container=docker
RUN apt-get update -q \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
        systemd systemd-sysv dbus openssh-server sudo ca-certificates curl kmod iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl enable ssh

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
