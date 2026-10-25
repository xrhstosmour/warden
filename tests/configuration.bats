#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../library/common.sh"
    source "$BATS_TEST_DIRNAME/../library/configuration.sh"
    ADMIN_USER=admin
    ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOSWAHsCf+sZ6GEGPlRvVDuNAa/vjrxWpqgaFxT/Dsxt admin@laptop"
    DEPLOY_USER=deploy
    DEPLOY_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICMxjodA14l51z5VGfmg5g/Okt4x3V08Kz/XOy5hTcli deploy@laptop"
    SSH_PORT=2222
    SSH_SOURCES=""
    SSH_ACCESS=public
    TAILSCALE_AUTH_KEY=""
    TAILSCALE_SSH=no
    ETCKEEPER=yes
    LOGIN_STATUS=yes
    AUDIT_TOOL=yes
    DOCKER_ADDRESS_POOL=172.30.0.0/16
}

@test "a complete configuration passes" {
    run validate_configuration
    [ "$status" -eq 0 ]
}

@test "the default SSH port is refused" {
    SSH_PORT=22
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"SSH_PORT"* ]]
}

@test "root is refused as either user" {
    ADMIN_USER=root
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"ADMIN_USER"* ]]
}

@test "the deploy user cannot be the admin" {
    DEPLOY_USER=admin
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"must differ"* ]]
}

@test "a placeholder or a private key is not a public key" {
    ADMIN_PUBLIC_KEY="ssh-ed25519 AAAA...replace admin@laptop"
    DEPLOY_PUBLIC_KEY="-----BEGIN OPENSSH PRIVATE KEY-----"
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"ADMIN_PUBLIC_KEY"* ]]
    [[ "$output" == *"DEPLOY_PUBLIC_KEY"* ]]
}

@test "a key carrying a second line is refused" {
    ADMIN_PUBLIC_KEY=$'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOSWAHsCf+sZ6GEGPlRvVDuNAa/vjrxWpqgaFxT/Dsxt a\nssh-ed25519 AAAAC3Nza b'
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"ADMIN_PUBLIC_KEY"* ]]
}

@test "SSH cannot share a public port" {
    SSH_PORT=8443
    PUBLIC_TCP_PORTS="80 443 8443"
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"public port"* ]]
}

@test "an SSH source that is not an address is refused" {
    SSH_SOURCES="100.64.0.0/10 example.com"
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"example.com"* ]]
}

@test "every problem is reported in one run" {
    SSH_PORT=22
    TIMEZONE="Europe/Athens; rm"
    REBOOT_TIME=25:00
    run validate_configuration
    [ "$status" -eq 1 ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "SSH access is public or tailscale" {
    SSH_ACCESS=vpn
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"SSH_ACCESS"* ]]
}

@test "a Tailscale auth key looks like one" {
    TAILSCALE_AUTH_KEY="not-a-key"
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"TAILSCALE_AUTH_KEY"* ]]
    TAILSCALE_AUTH_KEY="tskey-auth-k1a2b3-c4d5e6"
    run validate_configuration
    [ "$status" -eq 0 ]
}

@test "SSH sources and tailnet only SSH exclude each other" {
    SSH_ACCESS=tailscale
    SSH_SOURCES="203.0.113.0/24"
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"exclude each other"* ]]
}

@test "etckeeper accepts only yes or no" {
    ETCKEEPER=maybe
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"ETCKEEPER"* ]]
}

@test "the login status accepts only yes or no" {
    LOGIN_STATUS=maybe
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"LOGIN_STATUS"* ]]
}

@test "the audit tool accepts only yes or no" {
    AUDIT_TOOL=maybe
    run validate_configuration
    [ "$status" -eq 1 ]
    [[ "$output" == *"AUDIT_TOOL"* ]]
}

@test "the Docker address pool must be a private range or empty" {
    DOCKER_ADDRESS_POOL=""
    run validate_configuration
    [ "$status" -eq 0 ]
    for pool in 8.8.8.0/24 172.30.0.0/28 172.30.0.0 not-a-range 10.999.0.0/16 10.0/16 172.16.5.0/16 10.1.2.3/8 192.168.0.0/8 172.32.0.0/16; do
        DOCKER_ADDRESS_POOL="$pool"
        run validate_configuration
        [ "$status" -eq 1 ]
        [[ "$output" == *"DOCKER_ADDRESS_POOL"* ]]
    done
}

@test "Tailscale is used only when asked for" {
    run uses_tailscale
    [ "$status" -eq 1 ]
    TAILSCALE_SSH=yes
    run uses_tailscale
    [ "$status" -eq 0 ]
}

