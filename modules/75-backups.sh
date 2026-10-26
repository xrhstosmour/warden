#!/bin/bash
# Encrypted, deduplicated backups with restic to a target you own: an SFTP
# host, or any storage rclone reaches. Off unless `BACKUP_REPOSITORY` is set.
# The password and keys are made on your machine and copied here by
# `provision.sh`, nothing secret is made on the server. They live under
# /var/lib/warden, outside /etc, so etckeeper never commits them. The first
# backup runs later, in 91-backups-first-run.sh.

if ! uses_backups; then
    systemctl disable -q --now warden-backup.timer warden-backup-check.timer 2>/dev/null || true
    rm -f /etc/systemd/system/warden-backup.service /etc/systemd/system/warden-backup.timer \
        /etc/systemd/system/warden-backup-check.service /etc/systemd/system/warden-backup-check.timer \
        /usr/local/sbin/warden-backup /etc/warden/backup.conf
    rm -rf /var/lib/warden/backup
    log_info "Backups are off, BACKUP_REPOSITORY in warden.conf turns them on."
    return 0
fi

secrets=/var/lib/warden/backup
install -d -m 0755 /etc/warden
install -d -m 0700 /var/lib/warden "$secrets"

install_packages restic
if [[ "$BACKUP_REPOSITORY" == rclone:* ]]; then
    install_packages rclone
    # Filen's backend arrived in rclone 1.73, Debian's package may be older.
    rclone_version=$(rclone version 2>/dev/null | awk 'NR == 1 { sub(/^v/, "", $2); print $2 }')
    if [[ "$(printf '%s\n1.73.0\n' "${rclone_version:-0}" | sort -V | head -1)" != "1.73.0" ]]; then
        log_warning "rclone ${rclone_version:-unknown} is older than 1.73, a newer backend such as Filen may be missing from it."
    fi
fi

# Copies a secret the operator supplied into place, root only. A file already
# there is replaced only when the uploaded one changed since the last time,
# rclone rewrites its own configuration when it refreshes a token, and putting
# the old copy back would undo that. Once placed, the upload is deleted, so
# nothing secret stays behind in warden's directory.
place_secret() {
    local source="$1"
    local target="$2"
    local fingerprint_file="$target.uploaded"

    if [[ ! -f "$source" ]]; then
        [[ -f "$target" ]] || fail "$source is missing, it should hold the file named in warden.conf."
        return 0
    fi

    local fingerprint
    fingerprint=$(sha256sum "$source" | cut -d ' ' -f 1)
    if [[ ! -f "$target" || "$(cat "$fingerprint_file" 2>/dev/null)" != "$fingerprint" ]]; then
        install -m 0600 -o root -g root "$source" "$target"
        (umask 077 && printf '%s\n' "$fingerprint" >"$fingerprint_file")
        log_info "Updated $target."
    fi
    if [[ "$source" == "$WARDEN_DIRECTORY/secrets/"* ]]; then
        rm -f "$source"
    fi
}

place_secret "$BACKUP_PASSWORD_FILE" "$secrets/password"
if [[ "$BACKUP_REPOSITORY" == sftp:* ]]; then
    place_secret "$BACKUP_SSH_KEY_FILE" "$secrets/key"
    printf '%s\n' "$BACKUP_HOST_KEY" | place_content "$secrets/known_hosts" 0600 || true
else
    place_secret "$BACKUP_RCLONE_CONFIG_FILE" "$secrets/rclone.conf"
fi

place "$WARDEN_DIRECTORY/files/warden-backup.sh" /usr/local/sbin/warden-backup 0755 || true
place_content /etc/warden/backup.conf 0644 <<EOF || true
# Managed by warden, local changes are overwritten on the next run.
BACKUP_REPOSITORY=$BACKUP_REPOSITORY
BACKUP_SSH_PORT=$BACKUP_SSH_PORT
BACKUP_PATHS="$BACKUP_PATHS"
BACKUP_KEEP_DAILY=$BACKUP_KEEP_DAILY
BACKUP_KEEP_WEEKLY=$BACKUP_KEEP_WEEKLY
BACKUP_KEEP_MONTHLY=$BACKUP_KEEP_MONTHLY
EOF

changed=false
place_content /etc/systemd/system/warden-backup.service 0644 <<'EOF' && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Back up to the restic repository
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warden-backup backup
# A target that stops answering must not hang the unit for good, a failed unit
# is what the alerts watch for. The time also counts the wait for the lock, so
# it covers a whole weekly check (12h) and a backup after it (6h).
TimeoutStartSec=18h
Nice=10
IOSchedulingClass=idle
EOF
place_content /etc/systemd/system/warden-backup.timer 0644 <<EOF && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Back up every day at $BACKUP_TIME

[Timer]
OnCalendar=*-*-* $BACKUP_TIME:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
place_content /etc/systemd/system/warden-backup-check.service 0644 <<'EOF' && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Check the restic repository
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warden-backup check
TimeoutStartSec=12h
Nice=10
IOSchedulingClass=idle
EOF
place_content /etc/systemd/system/warden-backup-check.timer 0644 <<'EOF' && changed=true
# Managed by warden, local changes are overwritten on the next run.
[Unit]
Description=Check the restic repository every week

[Timer]
OnCalendar=Sun *-*-* 05:00:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
[[ "$changed" == true ]] && systemctl daemon-reload
ensure_service warden-backup.timer
ensure_service warden-backup-check.timer
