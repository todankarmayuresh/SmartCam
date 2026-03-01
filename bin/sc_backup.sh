#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/smartcam/backup.log"
BACKUP_DIR="/var/lib/smartcam/backups"
MOUNT_POINT="/mnt/smartcam-backup"

mkdir -p /var/log/smartcam
mkdir -p "$BACKUP_DIR"

echo "===== Backup Run $(date) =====" >> "$LOG_FILE"

# Load ENV safely
if [ -f /etc/smartcam/.env ]; then
    source /etc/smartcam/.env
else
    echo "$(date): ENV file missing!" >> "$LOG_FILE"
    exit 1
fi

DATE=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_NAME="smartcam_backup_${DATE}.tar.gz"
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"

# Create archive
if ! tar -czf "$BACKUP_PATH" \
    /etc/smartcam \
    /etc/mediamtx \
    /opt/smartcam \
    /etc/nginx/sites-available/smartcam \
    >> "$LOG_FILE" 2>&1; then

    echo "Backup creation failed" >> "$LOG_FILE"
    curl -s --max-time 5 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="SmartCam CRITICAL: Backup creation failed" > /dev/null
    exit 1
fi

# Generate checksum
SHA256=$(sha256sum "$BACKUP_PATH" | awk '{print $1}')
echo "Checksum: $SHA256" >> "$LOG_FILE"

# Optional SMB copy
if [ -n "${SMB_SHARE:-}" ]; then

    mkdir -p "$MOUNT_POINT"

    if ! mountpoint -q "$MOUNT_POINT"; then
        if ! mount -t cifs "$SMB_SHARE" "$MOUNT_POINT" \
            -o username="$SMB_USER",password="$SMB_PASS",vers=3.0 >> "$LOG_FILE" 2>&1; then
            echo "SMB mount failed" >> "$LOG_FILE"
            curl -s --max-time 5 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d chat_id="${CHAT_ID}" \
                -d text="SmartCam WARNING: SMB mount failed during backup" > /dev/null
            exit 1
        fi
    fi

    cp "$BACKUP_PATH" "$MOUNT_POINT/" >> "$LOG_FILE" 2>&1

    # Verify integrity
    REMOTE_SHA=$(sha256sum "$MOUNT_POINT/$BACKUP_NAME" | awk '{print $1}')
    if [ "$SHA256" != "$REMOTE_SHA" ]; then
        echo "Checksum mismatch after SMB copy" >> "$LOG_FILE"
        curl -s --max-time 5 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
            -d chat_id="${CHAT_ID}" \
            -d text="SmartCam WARNING: Backup checksum mismatch on SMB" > /dev/null
    else
        echo "SMB copy verified successfully" >> "$LOG_FILE"
    fi
fi

# Retention (keep last 7 backups locally)
ls -1t "$BACKUP_DIR"/smartcam_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f

echo "Backup completed successfully" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"