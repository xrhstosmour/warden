#!/usr/bin/env bats

setup() {
    work=$(mktemp -d)
    export WARDEN_CONFIGURATION="$work/warden.conf"
    export WARDEN_SECRETS="$work/secrets"
    token="eyJhIjoiMDEyMzQ1Njc4OSIsInQiOiJhYmMifQ=="
}

teardown() {
    rm -rf "$work"
}

@test "a tunnel answer saves the token privately and empties the public ports" {
    run bash -c "printf '%s\n' admin tailscale web '' tunnel '$token' | $BATS_TEST_DIRNAME/../setup.sh"
    [ "$status" -eq 0 ]
    [ "$(stat -c '%a' "$WARDEN_SECRETS/cloudflare-tunnel-token" 2>/dev/null || stat -f '%Lp' "$WARDEN_SECRETS/cloudflare-tunnel-token")" = 600 ]
    grep -q "^CLOUDFLARE_TUNNEL_TOKEN_FILE=$WARDEN_SECRETS/cloudflare-tunnel-token$" "$WARDEN_CONFIGURATION"
    grep -q "^PUBLIC_TCP_PORTS=''$" "$WARDEN_CONFIGURATION"
    # The token itself never lands in the configuration.
    ! grep -q "$token" "$WARDEN_CONFIGURATION"
}

@test "a bad token is refused and nothing is written" {
    run bash -c "printf '%s\n' admin tailscale web '' tunnel 'not a token' | $BATS_TEST_DIRNAME/../setup.sh"
    [ "$status" -ne 0 ]
    [ ! -e "$WARDEN_CONFIGURATION" ]
}

@test "an existing configuration is never overwritten" {
    echo keep >"$WARDEN_CONFIGURATION"
    run "$BATS_TEST_DIRNAME/../setup.sh" </dev/null
    [ "$status" -ne 0 ]
    [ "$(cat "$WARDEN_CONFIGURATION")" = keep ]
}

@test "input that ends early writes nothing" {
    run bash -c "printf '%s\n' admin | $BATS_TEST_DIRNAME/../setup.sh"
    [ "$status" -ne 0 ]
    [ ! -e "$WARDEN_CONFIGURATION" ]
}

@test "another server's token file is never replaced" {
    mkdir -p "$WARDEN_SECRETS"
    echo other >"$WARDEN_SECRETS/cloudflare-tunnel-token"
    run bash -c "printf '%s\n' admin tailscale web '' tunnel '$token' | $BATS_TEST_DIRNAME/../setup.sh"
    [ "$status" -ne 0 ]
    [ "$(cat "$WARDEN_SECRETS/cloudflare-tunnel-token")" = other ]
    [ ! -e "$WARDEN_CONFIGURATION" ]
}
