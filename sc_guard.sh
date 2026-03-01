#!/bin/bash

# SmartCam Enterprise Guard (Production Clean)

# Load environment variables
ENV_FILE="/etc/smartcam/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "$(date): WARNING - .env file missing" >> /var/log/smartcam/guard.log
fi

# ---- Performance Optimization: Cache System Stats ----
MEM_INFO=$(free -m)
RAM_AVAILABLE=$(echo "$MEM_INFO" | awk '/Mem:/ {print $7}')
TEMP_RAW=$(vcgencmd measure_temp 2>/dev/null)
TEMP=${TEMP_RAW#*=}
TEMP=${TEMP%'C'}
TEMP_INT=${TEMP%.*}
DISK=$(df /var/lib/smartcam | awk 'NR==2 {print $5}' | sed 's/%//')

RECORD_PATH="/var/lib/smartcam/recordings/live"
: ${MAX_RECORDING_AGE:=15}
: ${MAX_TEMP:=75}
: ${MAX_DISK_PERCENT:=85}
: ${MAX_RAM_WARN:=150}
: ${MAX_RAM_CRITICAL:=80}
: ${ALERT_COOLDOWN_SECONDS:=300}
: ${STREAM_NAME:=live}
MAX_RAM_CRITICAL=80
RAM_COUNTER_FILE="/tmp/smartcam_ram_counter"
MAX_RAM_CYCLES=3
STREAM_COUNTER_FILE="/tmp/smartcam_stream_counter"
MAX_STREAM_CYCLES=3
EMERGENCY_RAM=60
NETWORK_COUNTER_FILE="/tmp/smartcam_network_counter"
MAX_NETWORK_CYCLES=3
GATEWAY_IP=$(ip route | awk '/default/ {print $3}')
REBOOT_COUNTER_FILE="/tmp/smartcam_reboot_counter"
MAX_REBOOTS=3
REBOOT_WINDOW=1800   # 30 minutes (seconds)
SAFE_MODE_FLAG="/var/lib/smartcam/safe_mode"
CONFIG_BACKUP_DIR="/var/lib/smartcam/config_backup"
MAX_FAILURES_SAFE_MODE=3
DISK_CORRUPTION_FLAG="/tmp/smartcam_disk_error"


LOG_FILE="/var/log/smartcam/guard.log"
LOCK_FILE="/tmp/smartcam_alert.lock"

# -------------------------
# Boot snapshot notification setup
# -------------------------
BOOT_MARKER="/tmp/smartcam_boot_notified"

send_boot_snapshot() {
    CPU_LOAD=$(uptime | awk -F'load average:' '{print $2}')
    RAM_FREE=$(echo "$MEM_INFO" | awk '/Mem:/ {print $7}')
    DISK_USAGE=$(df /var/lib/smartcam | awk 'NR==2 {print $5}')
    TEMP_VAL=$TEMP

    send_alert "SmartCam Boot Snapshot:
CPU Load:${CPU_LOAD}
RAM Free:${RAM_FREE}MB
Disk Usage:${DISK_USAGE}
Temperature:${TEMP_VAL}C
Services:
MediaMTX: $(systemctl is-active mediamtx)
FileBrowser: $(systemctl is-active filebrowser)
Watchdog: $(systemctl is-active watchdog)"
}

# ===== Mount Safety Check =====
#if ! mountpoint -q /var/lib/smartcam; then
#    echo "$(date): CRITICAL - Recording mount missing!" >> "${LOG_FILE}"
#    send_alert "CRITICAL: Recording drive not mounted!"
#    exit 1
#fi

send_alert() {
    MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="SmartCam Alert: ${MESSAGE}" > /dev/null
}

alert_cooldown() {
    if [ -f "${LOCK_FILE}" ]; then
        LAST_ALERT=$(stat -c %Y "${LOCK_FILE}")
        NOW=$(date +%s)
        DIFF=$((NOW - LAST_ALERT))
        if [ "${DIFF}" -lt "${ALERT_COOLDOWN_SECONDS}" ]; then
            return 1
        fi
    fi
    touch "${LOCK_FILE}"
    return 0
}

safe_reboot() {

    NOW=$(date +%s)

    if [ -f "$REBOOT_COUNTER_FILE" ]; then
        read LAST_TIME COUNT < "$REBOOT_COUNTER_FILE"
    else
        LAST_TIME=0
        COUNT=0
    fi

    TIME_DIFF=$((NOW - LAST_TIME))

    if [ "$TIME_DIFF" -gt "$REBOOT_WINDOW" ]; then
        COUNT=0
    fi

    COUNT=$((COUNT + 1))

    echo "$NOW $COUNT" > "$REBOOT_COUNTER_FILE"

    if [ "$COUNT" -gt "$MAX_REBOOTS" ]; then
        echo "$(date): Reboot limit reached. Skipping reboot." >> "$LOG_FILE"
        if alert_cooldown; then
            send_alert "CRITICAL: Reboot limit reached. Manual intervention required."
        fi
        return
    fi

    echo "$(date): Performing safe reboot (Attempt $COUNT)" >> "$LOG_FILE"
    reboot
}

enter_safe_mode() {
    echo "$(date): Entering SAFE MODE." >> "$LOG_FILE"
    touch "$SAFE_MODE_FLAG"
    if alert_cooldown; then
        send_alert "SAFE MODE activated. Manual intervention required."
    fi
}

backup_config() {
    mkdir -p "$CONFIG_BACKUP_DIR"
    cp /etc/smartcam/.env "$CONFIG_BACKUP_DIR/.env.bak" 2>/dev/null
    cp /etc/mediamtx/mediamtx.yml "$CONFIG_BACKUP_DIR/mediamtx.yml.bak" 2>/dev/null
}

check_disk_corruption() {
    dmesg -T | tail -n 200 | grep -Ei "ext4|I/O error" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        touch "$DISK_CORRUPTION_FLAG"
        echo "$(date): Disk corruption detected via dmesg." >> "$LOG_FILE"
        if alert_cooldown; then
            send_alert "CRITICAL: Disk corruption signs detected!"
        fi
    fi
}


echo "===== Guard Run $(date) =====" >> "${LOG_FILE}"

# -------------------------
# Boot snapshot notification (once per boot)
# -------------------------
UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)

if [ "$UPTIME_SECONDS" -lt 300 ] && [ ! -f "$BOOT_MARKER" ]; then
    echo "$(date): Sending boot snapshot." >> "${LOG_FILE}"
    send_boot_snapshot
    touch "$BOOT_MARKER"
fi

# -------------------------
# Recording check
# -------------------------
LATEST_FILE=$(find "${RECORD_PATH}" -type f -name "*.mp4" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -n "${LATEST_FILE}" ]; then
    NOW=$(date +%s)
    FILE_TIME=$(stat -c %Y "${LATEST_FILE}")
    AGE_MIN=$(( (NOW - FILE_TIME) / 60 ))

    if [ "${AGE_MIN}" -gt "${MAX_RECORDING_AGE}" ]; then
        echo "$(date): Recording stalled (${AGE_MIN} min)" >> "${LOG_FILE}"

        if alert_cooldown; then
            send_alert "Recording stalled (${AGE_MIN} minutes). Restarting MediaMTX."
        fi

        systemctl restart mediamtx
        sleep 60

        LATEST_FILE=$(find "${RECORD_PATH}" -type f -name "*.mp4" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

        if [ -z "${LATEST_FILE}" ]; then
            echo "$(date): No new recording after restart." >> "${LOG_FILE}"
            if alert_cooldown; then
                send_alert "CRITICAL: Recording still stalled. Rebooting system."
            fi
            safe_reboot
        fi
    fi
fi

# -------------------------
# MediaMTX check
# -------------------------
if ! systemctl is-active --quiet mediamtx; then
    echo "$(date): MediaMTX DOWN - Restarting" >> "${LOG_FILE}"
    systemctl restart mediamtx
    sleep 5

    if systemctl is-active --quiet mediamtx; then
        send_alert "MediaMTX was down and has been restarted."
    else
        send_alert "CRITICAL: MediaMTX failed to restart!"
    fi
fi

# -------------------------
# Stream health via MediaMTX API (multi-cycle protection)
# -------------------------
API_STATUS=$(curl -s --max-time 2 http://localhost:9997/v3/paths/list)
STREAM_READY=$(echo "$API_STATUS" | grep -A5 "\"name\":\"$STREAM_NAME\"" | grep '"ready":true')

if [ -z "$STREAM_READY" ]; then

    # read counter
    if [ -f "$STREAM_COUNTER_FILE" ]; then
        STREAM_COUNT=$(cat "$STREAM_COUNTER_FILE")
    else
        STREAM_COUNT=0
    fi

    STREAM_COUNT=$((STREAM_COUNT + 1))
    echo "$STREAM_COUNT" > "$STREAM_COUNTER_FILE"

    echo "$(date): Stream not ready - Cycle ${STREAM_COUNT}" >> "${LOG_FILE}"

    if [ "$STREAM_COUNT" -ge "$MAX_STREAM_CYCLES" ]; then
        if alert_cooldown; then
            send_alert "CRITICAL: Stream '$STREAM_NAME' down for ${STREAM_COUNT} cycles. Restarting MediaMTX."
        fi
        systemctl restart mediamtx
        echo "0" > "$STREAM_COUNTER_FILE"
    fi

else
    # Stream is healthy → reset counter
    echo "0" > "$STREAM_COUNTER_FILE"
fi

# -------------------------
# FileBrowser check
# -------------------------
if ! systemctl is-active --quiet filebrowser; then
    echo "$(date): FileBrowser DOWN - Restarting" >> "${LOG_FILE}"
    systemctl restart filebrowser
    sleep 5

    if systemctl is-active --quiet filebrowser; then
        send_alert "FileBrowser was down and has been restarted."
    else
        send_alert "CRITICAL: FileBrowser failed to restart!"
    fi
fi

# -------------------------
# Watchdog check
# -------------------------
if ! systemctl is-active --quiet watchdog; then
    echo "$(date): Watchdog DOWN - Restarting" >> "${LOG_FILE}"
    systemctl restart watchdog
    sleep 5

    if systemctl is-active --quiet watchdog; then
        send_alert "Watchdog was down and has been restarted."
    else
        send_alert "CRITICAL: Watchdog failed to restart!"
    fi
fi

# -------------------------
# Temperature check
# -------------------------
if [ "${TEMP_INT}" -gt "${MAX_TEMP}" ]; then
    echo "$(date): High temperature ${TEMP}C" >> "${LOG_FILE}"
    if alert_cooldown; then
        send_alert "High temperature detected: ${TEMP} C"
    fi
fi

# -------------------------
# Disk check
# -------------------------
if [ "${DISK}" -gt "${MAX_DISK_PERCENT}" ]; then
    echo "$(date): Disk critical ${DISK}%" >> "${LOG_FILE}"
    if alert_cooldown; then
        send_alert "Disk usage critical: ${DISK}%"
    fi
fi

# -------------------------
# RAM check (multi-cycle protection)
# -------------------------
if [ "$RAM_AVAILABLE" -lt "$MAX_RAM_WARN" ]; then

    # read current counter
    if [ -f "$RAM_COUNTER_FILE" ]; then
        RAM_COUNT=$(cat "$RAM_COUNTER_FILE")
    else
        RAM_COUNT=0
    fi

    RAM_COUNT=$((RAM_COUNT + 1))
    echo "$RAM_COUNT" > "$RAM_COUNTER_FILE"

    echo "$(date): Low RAM detected (${RAM_AVAILABLE}MB free) - Cycle ${RAM_COUNT}" >> "${LOG_FILE}"

    if [ "$RAM_COUNT" -ge "$MAX_RAM_CYCLES" ]; then
        if alert_cooldown; then
            send_alert "CRITICAL: RAM low for ${RAM_COUNT} cycles (${RAM_AVAILABLE}MB). Restarting MediaMTX."
        fi
        systemctl restart mediamtx
        echo "0" > "$RAM_COUNTER_FILE"
    fi

else
    # RAM normal → reset counter
    echo "0" > "$RAM_COUNTER_FILE"
fi

# -------------------------
# Emergency protection
# -------------------------
if [ "$RAM_AVAILABLE" -lt "$MAX_RAM_CRITICAL" ]; then

    if [ -f "$STREAM_COUNTER_FILE" ]; then
        STREAM_COUNT=$(cat "$STREAM_COUNTER_FILE")
    else
        STREAM_COUNT=0
    fi

    if [ "$STREAM_COUNT" -ge "$MAX_STREAM_CYCLES" ]; then
        echo "$(date): EMERGENCY condition met. Rebooting system." >> "${LOG_FILE}"

        if alert_cooldown; then
            send_alert "EMERGENCY: RAM critically low (${RAM_AVAILABLE}MB) and stream unstable. Rebooting system."
        fi

        safe_reboot
    fi
fi

# -------------------------
# Network connectivity check (multi-cycle)
# -------------------------
if ! ping -c1 -W2 "$GATEWAY_IP" >/dev/null 2>&1 && \
   ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then

    if [ -f "$NETWORK_COUNTER_FILE" ]; then
        NET_COUNT=$(cat "$NETWORK_COUNTER_FILE")
    else
        NET_COUNT=0
    fi

    NET_COUNT=$((NET_COUNT + 1))
    echo "$NET_COUNT" > "$NETWORK_COUNTER_FILE"

    echo "$(date): Network failure detected - Cycle ${NET_COUNT}" >> "${LOG_FILE}"

    if [ "$NET_COUNT" -ge "$MAX_NETWORK_CYCLES" ]; then
        if alert_cooldown; then
            send_alert "CRITICAL: Network unreachable for ${NET_COUNT} cycles. Rebooting system."
        fi
        safe_reboot
    fi

else
    echo "0" > "$NETWORK_COUNTER_FILE"
fi

# -------------------------
# Disk corruption detection
# -------------------------
check_disk_corruption

# -------------------------
# Automatic config backup (once per day)
# -------------------------
BACKUP_MARKER="/tmp/smartcam_backup_done"
TODAY=$(date +%Y-%m-%d)

if [ ! -f "$BACKUP_MARKER" ] || [ "$(cat $BACKUP_MARKER)" != "$TODAY" ]; then
    backup_config
    echo "$TODAY" > "$BACKUP_MARKER"
fi

# -------------------------
# Daily heartbeat
# -------------------------
HOUR=$(date +%H)
MINUTE=$(date +%M)

if [ "$HOUR" = "09" ] && [ "$MINUTE" -lt "5" ]; then

    # Collect system stats for summary
    DISK_USAGE=$DISK
    TEMP_VAL=$TEMP

    if alert_cooldown; then
        send_alert "Daily Health Summary:
RAM Free: ${RAM_AVAILABLE}MB
Disk Usage: ${DISK_USAGE}%
Temperature: ${TEMP_VAL}C
Stream Counter: $(cat $STREAM_COUNTER_FILE 2>/dev/null)
RAM Counter: $(cat $RAM_COUNTER_FILE 2>/dev/null)
Network Counter: $(cat $NETWORK_COUNTER_FILE 2>/dev/null)
Status: System running normally."
    fi
fi

echo "$(date): Guard cycle complete." >> "${LOG_FILE}"
echo "" >> "${LOG_FILE}"
