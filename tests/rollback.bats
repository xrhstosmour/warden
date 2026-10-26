#!/usr/bin/env bats

setup() {
    script="$BATS_TEST_DIRNAME/../files/warden-ssh-rollback-stop.sh"
    stub="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$stub"
    # A systemctl that reports the timer as TIMER_ACTIVE and records a stop.
    cat >"$stub/systemctl" <<'STUB'
#!/bin/bash
case "$1" in
is-active) [[ "${TIMER_ACTIVE:-no}" == "yes" ]] ;;
stop) echo "$*" >>"$BATS_TEST_TMPDIR/stopped" ;;
esac
STUB
    # An nft that prints the input chain as it is in FIREWALL_RULES.
    cat >"$stub/nft" <<'STUB'
#!/bin/bash
[[ "${NFT_FAILS:-no}" == "yes" ]] && exit 1
printf '%s\n' "table inet warden {" "    chain input {" "        policy drop;" "$FIREWALL_RULES" "    }" "}"
STUB
    chmod +x "$stub/systemctl" "$stub/nft"
    export PATH="$stub:$PATH"
    export BATS_TEST_TMPDIR
}

@test "a pending timer is stopped" {
    TIMER_ACTIVE=yes FIREWALL_RULES='        iifname "tailscale0" tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/stopped")" = "stop warden-ssh-rollback.timer" ]
}

@test "a timer that already fired is reported, the public rule is back" {
    FIREWALL_RULES='        tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 3 ]
    [ ! -e "$BATS_TEST_TMPDIR/stopped" ]
}

@test "no timer and a tailnet only rule is nothing to stop" {
    FIREWALL_RULES='        iifname "tailscale0" tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/stopped" ]
}

@test "a firewall that cannot be read is not taken for a safe one" {
    NFT_FAILS=yes run "$script" 2222
    [ "$status" -eq 4 ]
    [ ! -e "$BATS_TEST_TMPDIR/stopped" ]
}

@test "the port must be a number" {
    run "$script" '2222; reboot'
    [ "$status" -eq 2 ]
}
