#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../library/common.sh"
    # Without root the owner options of `install` cannot be honoured, so a
    # copy of it without them stands in.
    STUB="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB"
    cat >"$STUB/install" <<EOF
#!/bin/bash
arguments=()
while (( \$# )); do
    case "\$1" in
    -o | -g) shift 2 ;;
    *) arguments+=("\$1"); shift ;;
    esac
done
PATH="\${PATH#$STUB:}" exec install "\${arguments[@]}"
EOF
    chmod +x "$STUB/install"
    PATH="$STUB:$PATH"
    SOURCE="$BATS_TEST_TMPDIR/source"
    TARGET="$BATS_TEST_TMPDIR/target"
    echo "content" >"$SOURCE"
}

@test "place reports a change only when the content or the mode differs" {
    stat -c %a / >/dev/null 2>&1 || skip "needs GNU stat"
    run place "$SOURCE" "$TARGET" 0644
    [ "$status" -eq 0 ]
    run place "$SOURCE" "$TARGET" 0644
    [ "$status" -eq 1 ]
    run place "$SOURCE" "$TARGET" 0600
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$TARGET")" = "600" ]
    run place "$SOURCE" "$TARGET" 0600
    [ "$status" -eq 1 ]
    echo "other" >"$SOURCE"
    run place "$SOURCE" "$TARGET" 0600
    [ "$status" -eq 0 ]
    [ "$(cat "$TARGET")" = "other" ]
}

@test "place_content passes the change status of place through" {
    stat -c %a / >/dev/null 2>&1 || skip "needs GNU stat"
    run bash -c 'source "$1"; PATH="$2:$PATH"; echo one | place_content "$3" 0644' _ \
        "$BATS_TEST_DIRNAME/../library/common.sh" "$STUB" "$TARGET"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; PATH="$2:$PATH"; echo one | place_content "$3" 0644' _ \
        "$BATS_TEST_DIRNAME/../library/common.sh" "$STUB" "$TARGET"
    [ "$status" -eq 1 ]
    run bash -c 'source "$1"; PATH="$2:$PATH"; echo two | place_content "$3" 0644' _ \
        "$BATS_TEST_DIRNAME/../library/common.sh" "$STUB" "$TARGET"
    [ "$status" -eq 0 ]
    [ "$(cat "$TARGET")" = "two" ]
}

@test "a file in a directory its owner controls is written as that owner" {
    stat -c %a / >/dev/null 2>&1 || skip "needs GNU stat"
    # Without root `runuser` cannot switch user, a stand-in records who it
    # was asked to run as and runs the command as the test user.
    cat >"$STUB/runuser" <<EOF
#!/bin/bash
echo "\$2" >>"$BATS_TEST_TMPDIR/runuser-users"
shift 3
exec "\$@"
EOF
    chmod +x "$STUB/runuser"
    run bash -c 'source "$1"; PATH="$2:$PATH"; echo key | place_as_owner deploy "$3" 0600' _ \
        "$BATS_TEST_DIRNAME/../library/common.sh" "$STUB" "$TARGET"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; PATH="$2:$PATH"; echo key | place_as_owner deploy "$3" 0600' _ \
        "$BATS_TEST_DIRNAME/../library/common.sh" "$STUB" "$TARGET"
    [ "$status" -eq 1 ]
    run bash -c 'source "$1"; PATH="$2:$PATH"; echo other | place_as_owner deploy "$3" 0600' _ \
        "$BATS_TEST_DIRNAME/../library/common.sh" "$STUB" "$TARGET"
    [ "$status" -eq 0 ]
    [ "$(cat "$TARGET")" = "other" ]
    [ "$(stat -c %a "$TARGET")" = "600" ]
    # Every read and write went through the owner, none as root.
    [ "$(sort -u "$BATS_TEST_TMPDIR/runuser-users")" = "deploy" ]
}

@test "a command that finishes in time keeps its own status" {
    run within 5 true
    [ "$status" -eq 0 ]
    run within 5 sh -c 'exit 3'
    [ "$status" -eq 3 ]
}

@test "a command that runs too long is stopped with status 124" {
    run within 1 sleep 30
    [ "$status" -eq 124 ]
}
