#!/bin/bash
# Managed by warden, local changes are overwritten on the next run.
# Encrypted backups with restic: warden-backup [init|has-snapshots|backup|check|verify]
#   init    start the repository at the target when it is not there yet
#   has-snapshots  succeed when at least one backup exists
#   backup  back up, then drop snapshots past the retention (default)
#   check   verify the repository structure
#   verify  restore one file from the latest snapshot and compare it
# A failure sends an alert when alerts are on, then exits non-zero.

set -uo pipefail

configuration_directory="${WARDEN_CONFIGURATION_DIRECTORY:-/etc/warden}"
state_directory="${WARDEN_STATE_DIRECTORY:-/var/lib/warden}"
alert="${WARDEN_ALERT:-/usr/local/sbin/warden-alert}"
secrets="$state_directory/backup"

# shellcheck disable=SC1091 # Written by warden, root's file.
source "$configuration_directory/backup.conf" || exit 1

fail_with_alert() {
    echo "$1" >&2
    [[ -x "$alert" ]] && "$alert" 5 "Backup failed" "$(hostname): $1" "rotating_light"
    exit 1
}

export RESTIC_REPOSITORY="$BACKUP_REPOSITORY"
export RESTIC_PASSWORD_FILE="$secrets/password"
options=()
case "$BACKUP_REPOSITORY" in
sftp:*)
    target="${BACKUP_REPOSITORY#sftp:}"
    # The host key is pinned, an unknown or changed host is refused.
    options=(-o "sftp.command=ssh ${target%%:*} -p $BACKUP_SSH_PORT -i $secrets/key -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=$secrets/known_hosts -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=4 -s sftp")
    ;;
rclone:*)
    export RCLONE_CONFIG="$secrets/rclone.conf"
    ;;
esac

case "${1:-backup}" in
init)
    restic "${options[@]}" cat config >/dev/null 2>&1 || restic "${options[@]}" init >/dev/null ||
        fail_with_alert "restic could not reach or start the repository, check the target, the key, the host key and that the folder exists."
    ;;
has-snapshots)
    [[ -n "$(restic "${options[@]}" snapshots --json --latest 1 2>/dev/null | tr -d '[] \n')" ]]
    ;;
backup)
    read -ra paths <<<"$BACKUP_PATHS"
    restic "${options[@]}" backup /etc "${paths[@]}" --one-file-system --exclude-caches \
        --exclude '/home/*/.cache' \
        --exclude '/home/*/.local/share/docker/overlay2' \
        --exclude '/home/*/.local/share/docker/image' \
        --exclude '/home/*/.local/share/docker/containers' \
        --exclude '/home/*/.local/share/docker/buildkit' ||
        fail_with_alert "restic backup did not finish."
    restic "${options[@]}" forget --prune --keep-daily "$BACKUP_KEEP_DAILY" \
        --keep-weekly "$BACKUP_KEEP_WEEKLY" --keep-monthly "$BACKUP_KEEP_MONTHLY" ||
        fail_with_alert "restic could not apply the retention."
    ;;
check)
    restic "${options[@]}" check || fail_with_alert "restic check found a problem in the repository."
    ;;
verify)
    restore=$(mktemp -d)
    trap 'rm -rf "$restore"' EXIT
    verify_file="${WARDEN_VERIFY_FILE:-/etc/hostname}"
    restic "${options[@]}" restore latest --target "$restore" --include "$verify_file" ||
        fail_with_alert "restic could not restore from the latest snapshot."
    cmp -s "$restore$verify_file" "$verify_file" ||
        fail_with_alert "the restored $verify_file differs from the original."
    echo "Restore test passed."
    ;;
*)
    echo "Usage: warden-backup [init|has-snapshots|backup|check|verify]" >&2
    exit 2
    ;;
esac
