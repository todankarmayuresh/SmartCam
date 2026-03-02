#!/bin/bash
set -euo pipefail

# =================================================
# SmartCam Backup v3 – Enterprise Intelligent Edition
# =================================================

START_TIME=$(date +%s)

# -------------------------------------------------
# Lock Protection
# -------------------------------------------------
LOCK_FILE="/tmp/sc_backup.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || exit 0

# -------------------------------------------------
# Paths & Logging
# -------------------------------------------------
LOG_DIR="/var/log/smartcam"
LOG_FILE="$LOG_DIR/backup.log"
STATE_DIR="/var/lib/smartcam"
BACKUP_ROOT="$STATE_DIR/backups"
SNAPSHOT_DIR="$BACKUP_ROOT/snapshots"
MOUNT_POINT="/mnt/smartcam-backup"
HEALTH_JSON="$STATE_DIR/backup_state.json"
FAIL_COUNTER_FILE="$STATE_DIR/backup_fail_count"
FAIL_ALERT_THRESHOLD="${BACKUP_FAIL_ALERT_THRESHOLD:-3}"

mkdir -p "$LOG_DIR" "$BACKUP_ROOT" "$SNAPSHOT_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

log "===== Backup Run Started ====="

# -------------------------------------------------
# Load ENV
# -------------------------------------------------
if [ -f /etc/smartcam/.env ]; then
    source /etc/smartcam/.env
else
    log "ENV file missing!"
    exit 1
fi

RETENTION_DAYS="${BACKUP_RETENTION:-7}"
REMOTE_RETENTION_DAYS="${REMOTE_BACKUP_RETENTION:-14}"
MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-1024}"

# -------------------------------------------------
# Disk Safety Check
# -------------------------------------------------
FREE_MB=$(df -m "$STATE_DIR" | awk 'NR==2 {print $4}')
if [[ "$FREE_MB" =~ ^[0-9]+$ ]] && [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    log "CRITICAL: Not enough free space (${FREE_MB}MB free)"
    CURRENT_FAIL=$(( $(cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$CURRENT_FAIL" > "$FAIL_COUNTER_FILE"

    if [ "$CURRENT_FAIL" -ge "$FAIL_ALERT_THRESHOLD" ]; then
        log "ALERT: Backup failed ${CURRENT_FAIL} consecutive times"

        if [ -n "${BOT_TOKEN:-}" ] && [ -n "${CHAT_ID:-}" ]; then
            timeout 5 curl -s -X POST \
                "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d chat_id="${CHAT_ID}" \
                -d text="SmartCam CRITICAL: Backup failed ${CURRENT_FAIL} consecutive times." \
                >/dev/null 2>&1 || true
        fi
    fi

    exit 1
fi

DATE=$(date +%Y-%m-%d_%H-%M-%S)
SNAPSHOT_PATH="$SNAPSHOT_DIR/$DATE"
LATEST_LINK="$SNAPSHOT_DIR/latest"

# -------------------------------------------------
# Incremental Snapshot (rsync hardlink mode)
# -------------------------------------------------
PREVIOUS=""
if [ -L "$LATEST_LINK" ]; then
    PREVIOUS="--link-dest=$(readlink -f "$LATEST_LINK")"
fi

mkdir -p "$SNAPSHOT_PATH"

if ! timeout 600 rsync -a --delete $PREVIOUS \
    /etc/smartcam \
    /etc/mediamtx \
    /opt/smartcam \
    /etc/nginx/sites-available/smartcam \
    "$SNAPSHOT_PATH" >> "$LOG_FILE" 2>&1; then

    log "CRITICAL: Snapshot rsync failed"
    CURRENT_FAIL=$(( $(cat "$FAIL_COUNTER_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$CURRENT_FAIL" > "$FAIL_COUNTER_FILE"

    if [ "$CURRENT_FAIL" -ge "$FAIL_ALERT_THRESHOLD" ]; then
        log "ALERT: Backup failed ${CURRENT_FAIL} consecutive times"

        if [ -n "${BOT_TOKEN:-}" ] && [ -n "${CHAT_ID:-}" ]; then
            timeout 5 curl -s -X POST \
                "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d chat_id="${CHAT_ID}" \
                -d text="SmartCam CRITICAL: Backup failed ${CURRENT_FAIL} consecutive times." \
                >/dev/null 2>&1 || true
        fi
    fi

    exit 1
fi

ln -sfn "$SNAPSHOT_PATH" "$LATEST_LINK"

# -------------------------------------------------
# Backup Size Tracking
# -------------------------------------------------
SIZE_MB=$(du -sm "$SNAPSHOT_PATH" | awk '{print $1}')
log "Snapshot size: ${SIZE_MB}MB"

# -------------------------------------------------
# Optional SMB Sync + Remote Retention
# -------------------------------------------------
if [ -n "${SMB_SHARE:-}" ]; then
    mkdir -p "$MOUNT_POINT"

    if ! mountpoint -q "$MOUNT_POINT"; then
        timeout 15 mount -t cifs "$SMB_SHARE" "$MOUNT_POINT" \
            -o username="$SMB_USER",password="$SMB_PASS",vers=3.0 >> "$LOG_FILE" 2>&1 || true
    fi

    if mountpoint -q "$MOUNT_POINT"; then
        timeout 600 rsync -a --delete "$SNAPSHOT_PATH" "$MOUNT_POINT/" >> "$LOG_FILE" 2>&1 || true

        # Remote retention cleanup
        find "$MOUNT_POINT" -maxdepth 1 -type d -mtime +$REMOTE_RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null || true
    else
        log "WARNING: SMB not mounted"
    fi
fi

# -------------------------------------------------
# Local Retention Cleanup
# -------------------------------------------------
find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} \; 2>/dev/null || true

# -------------------------------------------------
# Backup Health JSON (Dashboard Integration)
# -------------------------------------------------
cat <<EOF > "$HEALTH_JSON"
{
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
  "size_mb": $SIZE_MB,
  "free_mb": $FREE_MB,
  "retention_days": $RETENTION_DAYS,
  "remote_retention_days": $REMOTE_RETENTION_DAYS
}
EOF

# -------------------------------------------------
# Reset Failure Counter on Success
# -------------------------------------------------
echo 0 > "$FAIL_COUNTER_FILE"

# -------------------------------------------------
# Duration Logging
# -------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "Backup completed successfully in ${DURATION}s"
log ""

exit 0