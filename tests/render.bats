#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../library/configuration.sh"
    source "$BATS_TEST_DIRNAME/../library/render.sh"
    ADMIN_USER=admin
    DEPLOY_USER=deploy
    SSH_PORT=2222
    SSH_SOURCES=""
    PUBLIC_TCP_PORTS="80 443"
    PUBLIC_UDP_PORTS="443"
    SSH_ACCESS=public
    TAILSCALE_AUTH_KEY=""
    TAILSCALE_SSH=no
    unset TRANSITION_SSH_PORT
}

@test "the firewall drops by default and opens SSH and the public ports" {
    run render_nftables
    [[ "$output" == *"policy drop;"* ]]
    [[ "$output" == *"tcp dport 2222 accept"* ]]
    [[ "$output" == *"tcp dport { 80,443 } accept"* ]]
    [[ "$output" == *"udp dport { 443 } accept"* ]]
}

@test "the firewall never opens port 22 once SSH has moved" {
    run render_nftables
    [[ "$output" != *"dport 22 "* ]]
    [[ "$output" != *", 22 }"* ]]
}

@test "the firewall keeps the current SSH port open during the move" {
    TRANSITION_SSH_PORT=22
    run render_nftables
    [[ "$output" == *"tcp dport { 2222, 22 } accept"* ]]
}

@test "SSH sources limit SSH by address family" {
    SSH_SOURCES="100.64.0.0/10 fd7a:115c:a1e0::/48"
    run render_nftables
    [[ "$output" == *"ip saddr { 100.64.0.0/10 } tcp dport 2222 accept"* ]]
    [[ "$output" == *"ip6 saddr { fd7a:115c:a1e0::/48 } tcp dport 2222 accept"* ]]
    [[ "$output" != *$'\n        tcp dport 2222 accept'* ]]
}

@test "the firewall replaces only its own table" {
    run render_nftables
    [[ "$output" != *"flush ruleset"* ]]
    [[ "$output" == *"delete table inet warden"* ]]
}

@test "SSH allows only the two accounts, by key, on the chosen port" {
    run render_sshd
    [[ "$output" == *"Port 2222"* ]]
    [[ "$output" == *"AllowUsers admin deploy"* ]]
    [[ "$output" == *"PermitRootLogin no"* ]]
    [[ "$output" == *"PasswordAuthentication no"* ]]
    [[ "$output" == *"AuthenticationMethods publickey"* ]]
}

@test "only the admin may forward ports" {
    run render_sshd
    [[ "$output" == *$'AllowTcpForwarding no'* ]]
    [[ "$output" == *$'Match User admin\n    AllowTcpForwarding local'* ]]
}

@test "fail2ban watches the port SSH actually listens on" {
    run render_fail2ban
    [[ "$output" == *$'[sshd]\nenabled = true\nport = 2222'* ]]
}

@test "tailnet only SSH answers on the tailnet interface alone" {
    SSH_ACCESS=tailscale
    run render_nftables
    [[ "$output" == *'iifname "tailscale0" tcp dport 2222 accept'* ]]
    [[ "$output" != *$'\n        tcp dport 2222 accept'* ]]
    [[ "$output" == *"udp dport 41641 accept"* ]]
}

@test "tailnet only SSH keeps the current port public until the move, even the same one" {
    SSH_ACCESS=tailscale
    TRANSITION_SSH_PORT=2222
    run render_nftables
    [[ "$output" == *$'\n        tcp dport 2222 accept'* ]]
}

@test "the Tailscale port stays closed without Tailscale" {
    run render_nftables
    [[ "$output" != *"41641"* ]]
}

