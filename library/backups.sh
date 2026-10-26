#!/bin/bash
# Helpers for the backups module, kept apart from it so `tests/backups.bats` can
# source them.

# The backend type of one remote in an rclone configuration file.
# rclone_remote_type "file" "remote"
rclone_remote_type() {
    awk -v section="[$2]" '
        $0 == section { found = 1; next }
        /^\[/ { found = 0 }
        found && $1 == "type" { print $3; exit }
    ' "$1"
}
