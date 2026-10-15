#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../library/common.sh"
    source "$BATS_TEST_DIRNAME/../library/configuration.sh"
    ADMIN_USER=admin
    ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl admin@laptop"
    DEPLOY_USER=deploy
    DEPLOY_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB7sX2oL3d6X0j6bJ8x4yJ0Jq1cZpXl8i2wY5mN3kQ0r deploy@laptop"
    SSH_PORT=2222
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
    ADMIN_PUBLIC_KEY=$'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl a\nssh-ed25519 AAAAC3Nza b'
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
