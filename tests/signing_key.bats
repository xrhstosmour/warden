#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../library/common.sh"
    KEY="file://$BATS_TEST_DIRNAME/fixtures/docker.asc"
    TARGET="$BATS_TEST_TMPDIR/keyrings/docker.asc"
}

@test "a key with the published fingerprint is placed" {
    run place_signing_key "$KEY" "$TARGET" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$TARGET" 2>/dev/null || stat -f %Lp "$TARGET")" = "644" ]
}

@test "a key with another fingerprint is refused and not placed" {
    run place_signing_key "$KEY" "$TARGET" 2596A99EAAB33821893C0A79458CA832957F5868
    [ "$status" -eq 1 ]
    [[ "$output" == *"not the expected"* ]]
    [ ! -e "$TARGET" ]
}

@test "a file with the published key and a second key is refused" {
    home="$BATS_TEST_TMPDIR/gnupg"
    mkdir -m 0700 "$home"
    gpg --homedir "$home" --batch --passphrase '' --quick-gen-key extra@example.invalid ed25519 sign never 2>/dev/null
    cp "$BATS_TEST_DIRNAME/fixtures/docker.asc" "$BATS_TEST_TMPDIR/two-keys.asc"
    gpg --homedir "$home" --armor --export extra@example.invalid >>"$BATS_TEST_TMPDIR/two-keys.asc"
    run place_signing_key "file://$BATS_TEST_TMPDIR/two-keys.asc" "$TARGET" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
    [ "$status" -eq 1 ]
    [ ! -e "$TARGET" ]
}

@test "a swapped key already in place is replaced" {
    mkdir -p "$(dirname "$TARGET")"
    echo "not a key" >"$TARGET"
    run place_signing_key "$KEY" "$TARGET" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
    [ "$status" -eq 0 ]
    [ "$(key_fingerprint "$TARGET")" = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" ]
}
