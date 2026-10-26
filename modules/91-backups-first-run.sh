#!/bin/bash
# The first backup and a restore test, which prove the target, the host key
# and the password work before anyone depends on the backups. Runs after SSH
# has moved, so an unreachable target never blocks the hardening. A failure is
# reported loudly and does not stop the run. Every step is bounded, 9 minutes
# in all, because with `SSH_ACCESS=tailscale` the rollback that reopens public
# SSH fires `rollback_minutes` after SSH moved, and a slow upload must not
# outlast it.
# A backup cut short carries on in the daily timer.

uses_backups || return 0

first_backup() {
    local first=false
    timeout 1m /usr/local/sbin/warden-backup init || return 1
    if ! timeout 1m /usr/local/sbin/warden-backup has-snapshots; then
        first=true
        log_info "Running the first backup."
        timeout 5m /usr/local/sbin/warden-backup backup || return 1
    fi
    # Every run, so a restore test that failed once is tried again.
    timeout 2m /usr/local/sbin/warden-backup verify || return 1
    [[ "$first" == false ]] || log_warning "Backups work. Keep a copy of the restic password off this server, without it the backups cannot be read."
}

first_backup || log_error "The first backup or its restore test failed or ran out of time, the backups are NOT working yet. Fix the target, then run warden again."
