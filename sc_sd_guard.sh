#!/bin/bash

set -euo pipefail

LOCK_FILE="/tmp/sc_sd_guard.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "Another SD Guard instance is running. Exiting." >> /var/log/smartcam/sd_guard.log
    exit 0
}

START_TIME=$(date +%s)

# Load SmartCam environment (for Telegram alerts)
if [ -f /etc/smartcam/.env ]; then
    source /etc/smartcam/.env
fi

# SmartCam SD Protection Guard

RECORD_DIR="/var/lib/smartcam/recordings"
# Safety: determine today's folder (format: YYYY-MM-DD)
TODAY_FOLDER="$(date +%Y-%m-%d)"

LOG_FILE="/var/log/smartcam/sd_guard.log"

LOCK_DISABLE="/etc/smartcam/sd_guard.disable"

# Allow thresholds from environment
MIN_FREE_MB=${MIN_FREE_MB:-2048}
EMERGENCY_THRESHOLD_MB=${EMERGENCY_THRESHOLD_MB:-1024}

# Safety: prevent accidental deletion if mount missing
if ! mountpoint -q /var/lib/smartcam; then
    echo "CRITICAL: Recording mount missing! Cleanup aborted." >> "$LOG_FILE"
    if alert_cooldown; then
        send_alert "CRITICAL: Recording mount missing. SD Guard aborted."
    fi
    exit 1
fi

# Manual disable lock
if [ -f "$LOCK_DISABLE" ]; then
    echo "SD Guard disabled via lock file." >> "$LOG_FILE"
    exit 0
fi

# Samba backup configuration
SAMBA_PATH="/mnt/smartcam_backup"
# Samba credentials must be defined in /etc/smartcam/.env:

ALERT_LOCK="/tmp/sd_guard_alert.lock"

send_alert() {
    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        return
    fi
    MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="SD Guard: ${MESSAGE}" > /dev/null
}

alert_cooldown() {
    if [ -f "${ALERT_LOCK}" ]; then
        LAST_ALERT=$(stat -c %Y "${ALERT_LOCK}")
        NOW=$(date +%s)
        DIFF=$((NOW - LAST_ALERT))
        if [ "${DIFF}" -lt 300 ]; then
            return 1
        fi
    fi
    touch "${ALERT_LOCK}"
    return 0
}

if [ "${SD_WEAR_REDUCTION:-0}" != "1" ]; then
    echo "===== SD Guard Run $(date) =====" >> "$LOG_FILE"
fi

# Get available free space in MB
FREE_MB=$(df -m /var/lib/smartcam | awk 'NR==2 {print $4}')

echo "Free space: ${FREE_MB}MB" >> "$LOG_FILE"

if [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; then
    echo "Low disk space detected. Starting folder cleanup..." >> "$LOG_FILE"

    if alert_cooldown; then
        send_alert "Low disk space detected (${FREE_MB}MB free). Starting cleanup."
    fi

    INITIAL_FREE_MB=$FREE_MB

    while [ "$FREE_MB" -lt "$MIN_FREE_MB" ]; do

        # Find oldest date folder inside recordings
        OLDEST_FOLDER=$(find "$RECORD_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort | head -n 1)

        # Safety Check 0: Prevent root or empty deletion
        if [ -z "$OLDEST_FOLDER" ] || [ "$OLDEST_FOLDER" = "/" ]; then
            echo "Safety lock: Invalid folder detected. Aborting." >> "$LOG_FILE"
            break
        fi

        # Safety Check 1: Do not delete if this is today's folder
        if echo "$OLDEST_FOLDER" | grep -q "$TODAY_FOLDER"; then
            echo "Safety lock: Oldest folder is today's folder. Skipping deletion." >> "$LOG_FILE"
            break
        fi

        # Safety Check 2: Ensure at least one historical folder remains
        TOTAL_FOLDERS=$(find "$RECORD_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
        if [ "$TOTAL_FOLDERS" -le 1 ]; then
            echo "Safety lock: Only one folder remains. Aborting cleanup." >> "$LOG_FILE"

            if alert_cooldown; then
                send_alert "EMERGENCY: Disk low but only one recording folder remains. Manual intervention required."
            fi
            break
        fi

        if [ -z "$OLDEST_FOLDER" ]; then
            echo "No date folders left to delete." >> "$LOG_FILE"

            if [ "$FREE_MB" -lt "$EMERGENCY_THRESHOLD_MB" ]; then
                if alert_cooldown; then
                    send_alert "EMERGENCY: Disk critically low (${FREE_MB}MB free) and no folders left to delete!"
                fi
            fi
            break
        fi

        # ----- Samba Backup with Auto-Mount + Checksum Verification -----
        if ! mountpoint -q "$SAMBA_PATH"; then
            echo "Samba not mounted. Attempting credential-based mount..." >> "$LOG_FILE"

            if [ -z "$SAMBA_SERVER" ] || [ -z "$SAMBA_USER" ] || [ -z "$SAMBA_PASS" ]; then
                echo "Samba credentials missing in .env" >> "$LOG_FILE"
            else
                mkdir -p "$SAMBA_PATH"

                mount -t cifs "$SAMBA_SERVER" "$SAMBA_PATH" \
                    -o username="$SAMBA_USER",password="$SAMBA_PASS",rw,vers=3.0,file_mode=0777,dir_mode=0777 \
                    >> "$LOG_FILE" 2>&1

                sleep 2
            fi
        fi

        if mountpoint -q "$SAMBA_PATH"; then

            DEST="$SAMBA_PATH/$(basename "$OLDEST_FOLDER")"
            echo "Backing up $OLDEST_FOLDER to $DEST" >> "$LOG_FILE"

            ionice -c2 -n7 nice -n 19 true

            timeout 600 ionice -c2 -n7 nice -n 19 rsync -a --checksum "$OLDEST_FOLDER/" "$DEST/" >> "$LOG_FILE" 2>&1

            if [ $? -eq 0 ]; then

                # Verify integrity using dry-run checksum compare
                VERIFY=$(rsync -a --checksum --dry-run "$OLDEST_FOLDER/" "$DEST/" 2>/dev/null)

                if [ -z "$VERIFY" ]; then
                    echo "Checksum verification successful. Deleting source folder." >> "$LOG_FILE"
                    rm -rf "$OLDEST_FOLDER"
                else
                    echo "Checksum verification failed. Skipping deletion." >> "$LOG_FILE"
                    if alert_cooldown; then
                        send_alert "Backup checksum verification failed. Folder not deleted."
                    fi
                    break
                fi

            else
                echo "Backup failed. Skipping deletion." >> "$LOG_FILE"
                if alert_cooldown; then
                    send_alert "Backup to Samba failed. Folder not deleted."
                fi
                break
            fi

        else
            echo "Samba mount unavailable. Deleting without backup." >> "$LOG_FILE"
            rm -rf "$OLDEST_FOLDER"
        fi

        # Recalculate free space
        FREE_MB=$(df -m /var/lib/smartcam | awk 'NR==2 {print $4}')
        echo "Free space after delete: ${FREE_MB}MB" >> "$LOG_FILE"

    done

    echo "Folder cleanup completed." >> "$LOG_FILE"

    FINAL_FREE_MB=$(df -m /var/lib/smartcam | awk 'NR==2 {print $4}')
    FREED_MB=$((FINAL_FREE_MB - INITIAL_FREE_MB))
    echo "Recovered ${FREED_MB}MB space." >> "$LOG_FILE"

    if [ "$FREED_MB" -gt 0 ]; then
        if alert_cooldown; then
            send_alert "Cleanup completed. Recovered ${FREED_MB}MB. Free space now ${FINAL_FREE_MB}MB."
        fi
    fi
else
    echo "Disk healthy." >> "$LOG_FILE"
fi

# Heartbeat update
echo "$(date +%s)" > /var/lib/smartcam/sd_guard.heartbeat

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ "${SD_WEAR_REDUCTION:-0}" != "1" ]; then
    echo "Execution time: ${DURATION}s" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi