#!/bin/bash

set -euo pipefail

# -------------------------------------------------
# Lock Protection (Standardized)
# -------------------------------------------------
APP_DIR="/opt/smartcam"
LOCK_DIR="${APP_DIR}/locks"
STATE_DIR="/var/lib/smartcam"
LOG_DIR="/var/log/smartcam"

mkdir -p "$LOCK_DIR" "$STATE_DIR" "$LOG_DIR"

LOCK_FILE="${LOCK_DIR}/sc_sd_guard.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "Another SD Guard instance is running. Exiting." >> "${LOG_DIR}/sd_guard.log"
    exit 0
}

START_TIME=$(date +%s)

# Load SmartCam environment (for Telegram alerts)
if [ -f /opt/smartcam/.env ]; then
    source /opt/smartcam/.env
fi

# SmartCam SD Protection Guard

RECORD_DIR="/var/lib/smartcam/recordings"
# Safety: determine today's folder (format: YYYY-MM-DD)
TODAY_FOLDER="$(date +%Y-%m-%d)"

LOG_FILE="${LOG_DIR}/sd_guard.log"

LOCK_DISABLE="/opt/smartcam/sd_guard.disable"

# Allow thresholds from environment
MIN_FREE_MB=${MIN_FREE_MB:-2048}
EMERGENCY_THRESHOLD_MB=${EMERGENCY_THRESHOLD_MB:-1024}

MIN_FREE_PERCENT=${MIN_FREE_PERCENT:-10}        # minimum 10% free
PREDICT_THRESHOLD_PERCENT=${PREDICT_THRESHOLD_PERCENT:-15}  # early warning at 15%

HEALTH_JSON="${STATE_DIR}/sd_guard_health.json"

# -------------------------------------------------
# Alert Functions (Must Be Defined Before Use)
# -------------------------------------------------
ALERT_LOCK="${LOCK_DIR}/sd_guard_alert.lock"

send_alert() {
    if [ "${TELEGRAM_ENABLED:-false}" != "true" ]; then
        return
    fi
    if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
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


# -------------------------------------------------
# Optional Mount Enforcement (Enterprise Safe)
# Only enforce mount check if explicitly enabled
# -------------------------------------------------
REQUIRE_RECORD_MOUNT=${REQUIRE_RECORD_MOUNT:-false}

if [ "$REQUIRE_RECORD_MOUNT" = "true" ]; then
    if ! mountpoint -q /var/lib/smartcam; then
        echo "CRITICAL: Recording mount missing! Cleanup aborted." >> "$LOG_FILE"
        if alert_cooldown; then
            send_alert "CRITICAL: Recording mount missing. SD Guard aborted."
        fi
        exit 1
    fi
fi

# Manual disable lock
if [ -f "$LOCK_DISABLE" ]; then
    echo "SD Guard disabled via lock file." >> "$LOG_FILE"
    exit 0
fi

# Samba backup configuration
SAMBA_PATH="/mnt/smartcam_backup"
# Samba credentials must be defined in /etc/smartcam/.env:


if [ "${SD_WEAR_REDUCTION:-0}" != "1" ]; then
    echo "===== SD Guard Run $(date) =====" >> "$LOG_FILE"
fi

# Get available free space in MB and percentage
DISK_LINE=$(df -m /var/lib/smartcam | awk 'NR==2')
FREE_MB=$(echo "$DISK_LINE" | awk '{print $4}')
USED_PERCENT=$(df /var/lib/smartcam | awk 'NR==2 {gsub("%","",$5); print $5}')
FREE_PERCENT=$((100 - USED_PERCENT))

echo "Free space: ${FREE_MB}MB" >> "$LOG_FILE"

# Predictive early warning
if [ "$FREE_PERCENT" -lt "$PREDICT_THRESHOLD_PERCENT" ]; then
    if alert_cooldown; then
        send_alert "Disk trending low (${FREE_PERCENT}% free). Pre-threshold warning."
    fi
fi


if [ "$FREE_MB" -lt "$MIN_FREE_MB" ] || [ "$FREE_PERCENT" -lt "$MIN_FREE_PERCENT" ]; then
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

            if [ -z "${SMB_SHARE:-}" ] || [ -z "${SMB_USER:-}" ] || [ -z "${SMB_PASS:-}" ]; then
                echo "Samba credentials missing in .env" >> "$LOG_FILE"
            else
                mkdir -p "$SAMBA_PATH"

                mount -t cifs "$SMB_SHARE" "$SAMBA_PATH" \
                    -o username="$SMB_USER",password="$SMB_PASS",rw,vers=3.0,file_mode=0777,dir_mode=0777 \
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

# -------------------------------------------------
# SD Guard Health JSON (Dashboard Integration)
# -------------------------------------------------
cat <<EOF > "$HEALTH_JSON"
{
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
  "free_mb": $FREE_MB,
  "free_percent": $FREE_PERCENT,
  "min_free_mb": $MIN_FREE_MB,
  "min_free_percent": $MIN_FREE_PERCENT
}
EOF

# Heartbeat update
echo "$(date +%s)" > "${STATE_DIR}/sd_guard.heartbeat"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ "${SD_WEAR_REDUCTION:-0}" != "1" ]; then
    echo "Execution time: ${DURATION}s" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi