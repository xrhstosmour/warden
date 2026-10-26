#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../library/backups.sh"
}

@test "the backend type is read from the named remote alone" {
    cat >"$BATS_TEST_TMPDIR/rclone.conf" <<'EOF'
[drive]
type = drive
scope = drive

[filen]
type = filen
api_key = x
EOF
    [ "$(rclone_remote_type "$BATS_TEST_TMPDIR/rclone.conf" drive)" = "drive" ]
    [ "$(rclone_remote_type "$BATS_TEST_TMPDIR/rclone.conf" filen)" = "filen" ]
    [ -z "$(rclone_remote_type "$BATS_TEST_TMPDIR/rclone.conf" missing)" ]
}
