#!/usr/bin/env bats

# The audit runs as root against a live server, so only its listener filter is
# loaded here, with `ss` and `sshd` stubbed.
setup() {
    sshd_value() { echo 2222; }
    eval "$(sed -n '/^wide_listeners() {/,/^}/p' "$BATS_TEST_DIRNAME/../files/warden-audit.sh")"
}

@test "a listener on every address is reported" {
    ss() { printf 'LISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*\nLISTEN 0 4096 [::]:9000 [::]:*\n'; }
    run wide_listeners
    [[ "$output" == *"0.0.0.0:8080"* ]]
    [[ "$output" == *"[::]:9000"* ]]
}

@test "loopback listeners and the SSH port are not reported" {
    ss() { printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:8080 0.0.0.0:*\nLISTEN 0 4096 [::1]:8080 [::]:*\nLISTEN 0 4096 100.64.0.1:22 0.0.0.0:*\n'; }
    run wide_listeners
    [ -z "$output" ]
}
