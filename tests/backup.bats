#!/usr/bin/env bats

setup() {
    script="$BATS_TEST_DIRNAME/../files/warden-backup.sh"
    work=$(mktemp -d)
    export WORK="$work"
    export WARDEN_CONFIGURATION_DIRECTORY="$work/etc"
    export WARDEN_STATE_DIRECTORY="$work/state"
    export WARDEN_ALERT="$work/alert"
    mkdir -p "$WARDEN_CONFIGURATION_DIRECTORY" "$WARDEN_STATE_DIRECTORY/backup" "$work/bin"
    cat >"$WARDEN_CONFIGURATION_DIRECTORY/backup.conf" <<'EOF'
BACKUP_REPOSITORY=sftp:backup@laptop:/srv/warden
BACKUP_SSH_PORT=22
BACKUP_PATHS="/home /srv"
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=6
EOF

    # A restic that records its call, and restores the file asked for.
    cat >"$work/bin/restic" <<'EOF'
#!/bin/bash
echo "$@" >>"$WORK/restic-arguments"
echo "$RESTIC_PASSWORD_FILE $RESTIC_REPOSITORY" >>"$WORK/restic-environment"
if [[ " $* " == *" restore "* ]]; then
    for ((i = 1; i <= $#; i++)); do
        [[ "${!i}" == --target ]] && j=$((i + 1)) && target="${!j}"
        [[ "${!i}" == --include ]] && j=$((i + 1)) && include="${!j}"
    done
    mkdir -p "$target$(dirname "$include")"
    cp "${RESTORE_SOURCE:-$include}" "$target$include"
fi
exit "${RESTIC_STATUS:-0}"
EOF
    cat >"$work/alert" <<'EOF'
#!/bin/bash
echo "$@" >>"$WORK/alert-calls"
EOF
    # A flock that records its call, the real one is not on every machine.
    cat >"$work/bin/flock" <<'EOF'
#!/bin/bash
echo "$@" >>"$WORK/flock-calls"
EOF
    chmod +x "$work/bin/restic" "$work/alert" "$work/bin/flock"
    export PATH="$work/bin:$PATH"
    echo "app-1" >"$work/hostname"
    export WARDEN_VERIFY_FILE="$work/hostname"
}

teardown() {
    rm -rf "$work"
}

@test "a backup pins the host key and refuses unknown hosts" {
    run "$script" backup
    [ "$status" -eq 0 ]
    grep -q 'StrictHostKeyChecking=yes' "$work/restic-arguments"
    grep -q "UserKnownHostsFile=$work/state/backup/known_hosts" "$work/restic-arguments"
    grep -q 'backup@laptop' "$work/restic-arguments"
}

@test "a backup never waits forever on a dead connection" {
    run "$script" backup
    grep -q 'ServerAliveInterval=30' "$work/restic-arguments"
    grep -q 'ServerAliveCountMax=4' "$work/restic-arguments"
}

@test "the daily backup forgets old snapshots and leaves the prune to the weekly check" {
    run "$script" backup
    grep -q ' forget ' "$work/restic-arguments"
    [ -z "$(grep -e '--prune' -e ' prune$' "$work/restic-arguments")" ]
    run "$script" check
    [ "$status" -eq 0 ]
    grep -q ' prune$' "$work/restic-arguments"
    grep -q ' check$' "$work/restic-arguments"
    # A damaged repository is found before anything rewrites it.
    [ "$(grep -n ' check$' "$work/restic-arguments" | tail -1 | cut -d: -f1)" -lt "$(grep -n ' prune$' "$work/restic-arguments" | tail -1 | cut -d: -f1)" ]
}

@test "every command that reads or changes snapshots takes the same lock" {
    for command in backup check verify has-snapshots; do
        run "$script" "$command"
    done
    [ "$(wc -l <"$work/flock-calls")" -eq 4 ]
    [ -f "$work/state/backup.lock" ]
}

@test "starting the repository takes no lock" {
    run "$script" init
    [ ! -e "$work/flock-calls" ]
}

@test "the password travels as a file path, never in the arguments" {
    echo "correct-horse-battery-staple" >"$work/state/backup/password"
    run "$script" backup
    grep -q "^$work/state/backup/password sftp:backup@laptop:/srv/warden" "$work/restic-environment"
    ! grep -q 'correct-horse-battery-staple' "$work/restic-arguments" "$work/restic-environment"
}

@test "/etc is always backed up with the chosen paths, and Docker images are left out" {
    run "$script" backup
    grep -q 'backup /etc /home /srv' "$work/restic-arguments"
    grep -q "exclude /home/\*/.local/share/docker/overlay2" "$work/restic-arguments"
}

@test "a failed backup alerts and fails" {
    RESTIC_STATUS=1 run "$script" backup
    [ "$status" -eq 1 ]
    grep -q 'Backup failed' "$work/alert-calls"
}

@test "the restore test passes for an intact file and fails for a changed one" {
    run "$script" verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restore test passed"* ]]

    echo "something else" >"$work/other"
    RESTORE_SOURCE="$work/other" run "$script" verify
    [ "$status" -eq 1 ]
    grep -q 'differs from the original' "$work/alert-calls"
}

@test "an unknown command is refused" {
    run "$script" wipe
    [ "$status" -eq 2 ]
}
