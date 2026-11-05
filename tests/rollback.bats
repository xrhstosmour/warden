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
disable) echo "$*" >>"$BATS_TEST_TMPDIR/disabled" ;;
esac
STUB
    # An nft that prints the input chain as it is in FIREWALL_RULES.
    cat >"$stub/nft" <<'STUB'
#!/bin/bash
[[ "${NFT_FAILS:-no}" == "yes" ]] && exit 1
if [[ "$1" == "delete" ]]; then
    echo "$*" >>"$BATS_TEST_TMPDIR/deleted"
    [[ "${DELETE_KEEPS_RULE:-no}" == "yes" ]] || touch "$BATS_TEST_TMPDIR/clean"
    exit 0
fi
[[ -e "$BATS_TEST_TMPDIR/clean" ]] && FIREWALL_RULES='        iifname "tailscale0" tcp dport 2222 accept'
printf '%s\n' "table inet warden {" "    chain input {" "        policy drop;"
sed 's/$/ # handle 7/' <<<"$FIREWALL_RULES"
printf '%s\n' "    }" "}"
STUB
    chmod +x "$stub/systemctl" "$stub/nft"
    export PATH="$stub:$PATH"
    export BATS_TEST_TMPDIR
    export WARDEN_STATE_DIRECTORY="$BATS_TEST_TMPDIR/state"
}

@test "a pending timer is stopped" {
    TIMER_ACTIVE=yes FIREWALL_RULES='        iifname "tailscale0" tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/stopped")" = "stop warden-ssh-rollback.timer" ]
    [ "$(cat "$BATS_TEST_TMPDIR/disabled")" = "disable -q warden-ssh-rollback.timer" ]
    [ "$(cat "$BATS_TEST_TMPDIR/state/ssh-proven")" = 2222 ]
}

@test "the reopen marker of a fired rollback is removed" {
    mkdir -p "$BATS_TEST_TMPDIR/state"
    touch "$BATS_TEST_TMPDIR/state/ssh-reopened"
    FIREWALL_RULES='        tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/state/ssh-reopened" ]
}

@test "a pending timer is stopped and a public rule found with it is deleted" {
    TIMER_ACTIVE=yes FIREWALL_RULES='        tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/stopped")" = "stop warden-ssh-rollback.timer" ]
    [ "$(cat "$BATS_TEST_TMPDIR/deleted")" = "delete rule inet warden input handle 7" ]
}

@test "a timer that already fired has its public rule deleted by handle" {
    FIREWALL_RULES='        tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/deleted")" = "delete rule inet warden input handle 7" ]
}

@test "a public rule that survives the delete is reported" {
    DELETE_KEEPS_RULE=yes FIREWALL_RULES='        tcp dport 2222 accept' run "$script" 2222
    [ "$status" -eq 3 ]
    [ ! -e "$BATS_TEST_TMPDIR/state/ssh-proven" ]
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
