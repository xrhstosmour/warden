#!/usr/bin/env bats

setup() {
    script="$BATS_TEST_DIRNAME/../files/warden-cloudflare-sync.sh"
    work=$(mktemp -d)
    export WORK="$work"
    export WARDEN_STATE_DIRECTORY="$work/state"
    mkdir -p "$work/bin" "$work/served"
    printf '%s\n' 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 >"$work/served/ips-v4"
    printf '%s\n' 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32 >"$work/served/ips-v6"

    # A curl that serves files, an nft that accepts a check and has no live
    # table, so only the cache is touched.
    cat >"$work/bin/curl" <<'EOS'
#!/bin/bash
url="${@: -1}"
cat "$WORK/served/${url##*/}"
EOS
    cat >"$work/bin/nft" <<'EOS'
#!/bin/bash
[[ "$1" == "list" ]] && exit 1
[[ "$1" == "-c" ]] && exit "${NFT_CHECK_STATUS:-0}"
exit 0
EOS
    chmod +x "$work/bin/curl" "$work/bin/nft"
    export PATH="$work/bin:$PATH"
}

teardown() {
    rm -rf "$work"
}

@test "valid ranges are cached" {
    run "$script"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$work/state/cloudflare/ipv4")" -eq 5 ]
    [ "$(wc -l <"$work/state/cloudflare/ipv6")" -eq 5 ]
}

@test "a list with a line that is not a range is refused and the cache stays" {
    run "$script"
    echo "not-a-range" >>"$work/served/ips-v4"
    run "$script"
    [ "$status" -eq 1 ]
    ! grep -q 'not-a-range' "$work/state/cloudflare/ipv4"
}

@test "a list that is too short is refused" {
    printf '173.245.48.0/20\n' >"$work/served/ips-v4"
    run "$script"
    [ "$status" -eq 1 ]
    [ ! -e "$work/state/cloudflare/ipv4" ]
}

@test "a failed download keeps what is cached" {
    run "$script"
    printf '#!/bin/bash\nexit 22\n' >"$work/bin/curl"
    run "$script"
    [ "$status" -eq 1 ]
    [ "$(wc -l <"$work/state/cloudflare/ipv4")" -eq 5 ]
}

@test "a range that would open the ports to everyone is refused" {
    for range in 0.0.0.0/0 10.0.0.0/7; do
        printf '%s\n' "$range" >>"$work/served/ips-v4"
        run "$script"
        [ "$status" -eq 1 ]
        [ ! -e "$work/state/cloudflare/ipv4" ]
        printf '%s\n' 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 >"$work/served/ips-v4"
    done
    printf '%s\n' 2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 ::/0 >"$work/served/ips-v6"
    run "$script"
    [ "$status" -eq 1 ]
    [ ! -e "$work/state/cloudflare/ipv6" ]
}

@test "ranges the firewall rejects never reach the cache" {
    NFT_CHECK_STATUS=1 run "$script"
    [ "$status" -eq 1 ]
    [ ! -e "$work/state/cloudflare/ipv4" ]

    run "$script"
    [ "$status" -eq 0 ]
    NFT_CHECK_STATUS=1 run "$script"
    [ "$status" -eq 1 ]
    [ "$(wc -l <"$work/state/cloudflare/ipv4")" -eq 5 ]
}
