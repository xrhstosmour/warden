#!/bin/bash
# Configuration files built from `warden.conf`. Each function only prints,
# so the tests can check the output without a server.

# Comma separated, for an nftables anonymous set.
join_by_comma() {
    local IFS=","
    echo "$*"
}

# One nftables set of Cloudflare ranges, read from the cache the sync script
# keeps. An empty set is valid, it simply matches nobody.
render_cloudflare_set() {
    local name="$1" type="$2" file="$3"
    local ranges=""
    # shellcheck disable=SC2046 # One range per line, split on purpose.
    [[ -s "$file" ]] && ranges=$(join_by_comma $(cat "$file"))
    echo "    set $name {"
    echo "        type $type; flags interval;"
    [[ -n "$ranges" ]] && echo "        elements = { $ranges }"
    echo "    }"
}

render_nftables() {
    local tcp_ports udp_ports
    # shellcheck disable=SC2086 # Space separated lists on purpose.
    tcp_ports=$(join_by_comma $PUBLIC_TCP_PORTS)
    # shellcheck disable=SC2086
    udp_ports=$(join_by_comma $PUBLIC_UDP_PORTS)

    # While SSH is still moving, the port it listens on now stays open too,
    # so a run that stops halfway does not lock everyone out.
    local ssh_ports="$SSH_PORT"
    if [[ -n "${TRANSITION_SSH_PORT:-}" && "$TRANSITION_SSH_PORT" != "$SSH_PORT" ]]; then
        ssh_ports="{ $SSH_PORT, $TRANSITION_SSH_PORT }"
    fi

    local ssh_rules="        tcp dport $ssh_ports accept"
    if [[ "$SSH_ACCESS" == "tailscale" ]]; then
        # Reachable from the tailnet only. The port SSH listens on now stays
        # open to everyone until `90-ssh.sh` has moved it, even when it is
        # the same port, so the session doing the move is never cut off.
        ssh_rules="        iifname \"tailscale0\" tcp dport $SSH_PORT accept"
        if [[ -n "${TRANSITION_SSH_PORT:-}" ]]; then
            ssh_rules+=$'\n'"        tcp dport $TRANSITION_SSH_PORT accept"
        fi
    elif [[ -n "$SSH_SOURCES" ]]; then
        local ipv4=() ipv6=() source
        for source in $SSH_SOURCES; do
            if [[ "$source" == *:* ]]; then ipv6+=("$source"); else ipv4+=("$source"); fi
        done
        ssh_rules=""
        ((${#ipv4[@]} > 0)) && ssh_rules+="        ip saddr { $(join_by_comma "${ipv4[@]}") } tcp dport $ssh_ports accept"$'\n'
        ((${#ipv6[@]} > 0)) && ssh_rules+="        ip6 saddr { $(join_by_comma "${ipv6[@]}") } tcp dport $ssh_ports accept"$'\n'
        ssh_rules="${ssh_rules%$'\n'}"
    fi

    # With CLOUDFLARE_ONLY every public port answers Cloudflare's ranges alone.
    local cloudflare_sets=""
    if [[ "${CLOUDFLARE_ONLY:-no}" == "yes" ]]; then
        local cache="${CLOUDFLARE_DIRECTORY:-/var/lib/warden/cloudflare}"
        cloudflare_sets=$(render_cloudflare_set cloudflare4 ipv4_addr "$cache/ipv4")$'\n'
        cloudflare_sets+=$(render_cloudflare_set cloudflare6 ipv6_addr "$cache/ipv6")$'\n'
    fi

    cat <<EOF
#!/usr/sbin/nft -f
# Managed by warden, local changes are overwritten on the next run.
#
# Containers run under rootless Docker, which publishes ports from a user
# process on the host, so these rules govern them like any other service.
# Nothing is routed through this machine, so forwarding is closed.

# Declared, dropped, and declared again, so a reload replaces only this
# table and leaves the one fail2ban keeps its bans in alone.
table inet warden
delete table inet warden
table inet warden {
$cloudflare_sets    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept

        # Path MTU discovery and diagnostics break without these.
        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded, parameter-problem } limit rate 20/second accept
        ip6 nexthdr icmpv6 icmpv6 type { echo-request, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept

$ssh_rules
EOF
    if [[ "${CLOUDFLARE_ONLY:-no}" == "yes" ]]; then
        if [[ -n "$tcp_ports" ]]; then
            echo "        ip saddr @cloudflare4 tcp dport { $tcp_ports } accept"
            echo "        ip6 saddr @cloudflare6 tcp dport { $tcp_ports } accept"
        fi
        if [[ -n "$udp_ports" ]]; then
            echo "        ip saddr @cloudflare4 udp dport { $udp_ports } accept"
            echo "        ip6 saddr @cloudflare6 udp dport { $udp_ports } accept"
        fi
    else
        [[ -n "$tcp_ports" ]] && echo "        tcp dport { $tcp_ports } accept"
        [[ -n "$udp_ports" ]] && echo "        udp dport { $udp_ports } accept"
    fi
    if uses_tailscale; then
        echo ""
        echo "        # Tailscale's own port, for direct connections rather than relays."
        echo "        udp dport 41641 accept"
    fi
    cat <<'EOF'
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
}

render_sshd() {
    local users="$ADMIN_USER $DEPLOY_USER"
    cat <<EOF
# Managed by warden, local changes are overwritten on the next run.
#
# Named 00- so it is read before any provider drop-in: for most keywords
# sshd keeps the first value it sees.
Port $SSH_PORT
AllowUsers $users

HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin no
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitUserEnvironment no

MaxAuthTries 3
MaxSessions 2
MaxStartups 10:30:60
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no

# Post-quantum hybrid key exchange first, then curve25519 for older clients.
KexAlgorithms mlkem768x25519-sha256,sntrup761x25519-sha512,sntrup761x25519-sha512@openssh.com,curve25519-sha256,curve25519-sha256@libssh.org
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,sk-ssh-ed25519@openssh.com

# A source that keeps failing waits longer before sshd answers it again.
PerSourcePenalties yes

# Key fingerprints in the log, so a login can be traced to a key.
LogLevel VERBOSE

# The admin may tunnel to services bound to this machine's loopback, such
# as a database console, without publishing them.
Match User $ADMIN_USER
    AllowTcpForwarding local
EOF
}

render_fail2ban() {
    cat <<EOF
# Managed by warden, local changes are overwritten on the next run.

[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports
backend = systemd
findtime = 10m
maxretry = 5
bantime = 1h
# Each repeat ban doubles, up to a week.
bantime.increment = true
bantime.maxtime = 1w
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $SSH_PORT
mode = aggressive

# Anyone banned three times in a day is shut out of every port for a week.
[recidive]
enabled = true
backend = auto
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
findtime = 1d
maxretry = 3
bantime = 1w
EOF
}
