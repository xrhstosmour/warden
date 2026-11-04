#!/usr/bin/env bats

# A second run must keep the keys, a regenerated pair would lock the
# operator out of a server that already trusts the first.
@test "an existing key pair is kept" {
    run "$BATS_TEST_DIRNAME/../keys.sh" server "$BATS_TEST_TMPDIR" </dev/null
    [ "$status" -eq 0 ]
    before=$(cat "$BATS_TEST_TMPDIR/server_admin" "$BATS_TEST_TMPDIR/server_deploy")
    run "$BATS_TEST_DIRNAME/../keys.sh" server "$BATS_TEST_TMPDIR" </dev/null
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/server_admin" "$BATS_TEST_TMPDIR/server_deploy")" = "$before" ]
}

@test "a server name with a slash is refused" {
    run "$BATS_TEST_DIRNAME/../keys.sh" ../server "$BATS_TEST_TMPDIR"
    [ "$status" -eq 1 ]
}
