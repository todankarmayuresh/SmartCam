#!/bin/bash

# ----------------------------------------------------------
# Execution Timeout Wrapper (prevents hang)
# ----------------------------------------------------------
: ${GUARD_TIMEOUT:=120}   # seconds

if [ -z "$GUARD_TIMEOUT_WRAPPED" ]; then
    export GUARD_TIMEOUT_WRAPPED=1
    exec timeout --kill-after=10 ${GUARD_TIMEOUT}s "$0" "$@"
fi

# ----------------------------------------------------------
# Execution Timing
# ----------------------------------------------------------
START_TIME=$(date +%s)

# ----------------------------------------------------------
# Core Paths & Directories (Standardized)
# ----------------------------------------------------------
APP_DIR="/opt/smartcam"
LOCK_DIR="${APP_DIR}/locks"
STATE_DIR="/var/lib/smartcam"
LOG_DIR="/var/log/smartcam"

mkdir -p "$LOCK_DIR" "$STATE_DIR" "$LOG_DIR"

LOG_FILE="${LOG_DIR}/guard.log"
HEARTBEAT_FILE="${STATE_DIR}/guard_heartbeat"

# ==========================================================
# SmartCam Enterprise Guard v2 (Production Consolidated)
# High Reliability • Rate Limited • SD Safe • Multi-layer Protection
# ==========================================================

set -o pipefail

# ----------------------------------------------------------
# Environment Loader
# ----------------------------------------------------------
ENV_FILE="/opt/smartcam/.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# ----------------------------------------------------------
# Defaults (overridable via .env)
# ----------------------------------------------------------
: ${RECORD_PATH:=/var/lib/smartcam/recordings/live}
: ${LOG_FILE:=/var/log/smartcam/guard.log}
: ${MAX_RECORDING_AGE:=15}
: ${MAX_TEMP:=75}
: ${MAX_DISK_PERCENT:=85}
: ${MAX_RAM_WARN:=150}
: ${MAX_RAM_CRITICAL:=80}
: ${ALERT_COOLDOWN_SECONDS:=300}
: ${STREAM_NAME:=live}
: ${MAX_RAM_CYCLES:=3}
: ${MAX_STREAM_CYCLES:=3}
: ${MAX_NETWORK_CYCLES:=3}
: ${MAX_REBOOTS:=3}
: ${REBOOT_WINDOW:=1800}

# ----------------------------------------------------------
# New Defaults
# ----------------------------------------------------------
: ${HEARTBEAT_STALE_LIMIT:=600}     # seconds (10 min)
: ${SD_WEAR_REDUCTION:=no}         # yes/no

# ----------------------------------------------------------
# Heartbeat Stale Detection (self-monitor)
# ----------------------------------------------------------
if [ -f "$HEARTBEAT_FILE" ]; then
    LAST_BEAT_EPOCH=$(awk -F'|' '{print $2}' "$HEARTBEAT_FILE" | tr -d ' ')
    NOW_EPOCH=$(date +%s)

    if [ -n "$LAST_BEAT_EPOCH" ]; then
        AGE=$((NOW_EPOCH - LAST_BEAT_EPOCH))
        if [ "$AGE" -gt "$HEARTBEAT_STALE_LIMIT" ]; then
            log "Heartbeat stale (${AGE}s). Restarting MediaMTX."
            systemctl restart mediamtx
        fi
    fi
fi

LOCK_FILE="${LOCK_DIR}/alert.lock"
RAM_COUNTER_FILE="${LOCK_DIR}/ram.counter"
STREAM_COUNTER_FILE="${LOCK_DIR}/stream.counter"
NETWORK_COUNTER_FILE="${LOCK_DIR}/network.counter"
REBOOT_COUNTER_FILE="${LOCK_DIR}/reboot.counter"
CONFIG_BACKUP_DIR="/var/lib/smartcam/config_backup"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    if [ "$SD_WEAR_REDUCTION" = "yes" ]; then
        # Only log critical entries
        case "$1" in
            *critical*|*CRITICAL*|*Emergency*|*reboot*|*Reboot*|*stalled*)
                echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
                ;;
        esac
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
    fi
}

# ----------------------------------------------------------
# Telegram Alert (Rate Limited)
# ----------------------------------------------------------
send_alert() {
    [ -z "$BOT_TOKEN" ] && return
    [ -z "$CHAT_ID" ] && return

    if [ -f "$LOCK_FILE" ]; then
        LAST_ALERT=$(stat -c %Y "$LOCK_FILE" 2>/dev/null)
        NOW=$(date +%s)
        DIFF=$((NOW - LAST_ALERT))
        [ "$DIFF" -lt "$ALERT_COOLDOWN_SECONDS" ] && return
    fi

    touch "$LOCK_FILE"

    curl -s --max-time 5 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d text="SmartCam Alert: $1" >/dev/null 2>&1
}

# ----------------------------------------------------------
# Safe Reboot Controller
# ----------------------------------------------------------
safe_reboot() {
    NOW=$(date +%s)

    if [ -f "$REBOOT_COUNTER_FILE" ]; then
        read LAST_TIME COUNT < "$REBOOT_COUNTER_FILE"
    else
        LAST_TIME=0
        COUNT=0
    fi

    [ $((NOW - LAST_TIME)) -gt "$REBOOT_WINDOW" ] && COUNT=0

    COUNT=$((COUNT + 1))
    echo "$NOW $COUNT" > "$REBOOT_COUNTER_FILE"

    if [ "$COUNT" -gt "$MAX_REBOOTS" ]; then
        log "Reboot limit reached"
        send_alert "Reboot limit reached. Manual intervention required."
        return
    fi

    log "Safe reboot triggered (Attempt $COUNT)"
    reboot
}

# ----------------------------------------------------------
# Fast System Snapshot
# ----------------------------------------------------------
MEM_AVAILABLE=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
TEMP_RAW=$(vcgencmd measure_temp 2>/dev/null)
TEMP=${TEMP_RAW#*=}
TEMP=${TEMP%'C'}
TEMP_INT=${TEMP%.*}
DISK_PERCENT=$(df /var/lib/smartcam | awk 'NR==2 {gsub("%","",$5); print $5}')
GATEWAY_IP=$(ip route | awk '/default/ {print $3}')

log "Guard start | RAM:${MEM_AVAILABLE}MB Disk:${DISK_PERCENT}% Temp:${TEMP_INT}"

# ----------------------------------------------------------
# Recording Health
# ----------------------------------------------------------
LATEST_FILE=$(find "$RECORD_PATH" -type f -name "*.mp4" -printf "%T@ %p\n" 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

if [ -n "$LATEST_FILE" ]; then
    FILE_TIME=$(stat -c %Y "$LATEST_FILE")
    AGE_MIN=$(( ($(date +%s) - FILE_TIME) / 60 ))

    if [ "$AGE_MIN" -gt "$MAX_RECORDING_AGE" ]; then
        log "Recording stalled (${AGE_MIN}m)"
        send_alert "Recording stalled (${AGE_MIN}m). Restarting MediaMTX."
        systemctl restart mediamtx
        sleep 20
    fi
fi

# ----------------------------------------------------------
# Service Checks
# ----------------------------------------------------------
for SERVICE in mediamtx filebrowser; do
    if ! systemctl is-active --quiet "$SERVICE"; then
        log "$SERVICE down"
        systemctl restart "$SERVICE"
        sleep 5
    fi
done

# ----------------------------------------------------------
# Stream Health (Multi-cycle)
# ----------------------------------------------------------
API_STATUS=$(curl -s --max-time 2 http://localhost:9997/v3/paths/list)
echo "$API_STATUS" | grep -q "\"name\":\"$STREAM_NAME\"" && \
echo "$API_STATUS" | grep -q '"ready":true'
STREAM_OK=$?

if [ "$STREAM_OK" -ne 0 ]; then
    COUNT=$(cat "$STREAM_COUNTER_FILE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$STREAM_COUNTER_FILE"
    log "Stream not ready (cycle $COUNT)"

    if [ "$COUNT" -ge "$MAX_STREAM_CYCLES" ]; then
        send_alert "Stream unstable for $COUNT cycles. Restarting MediaMTX."
        systemctl restart mediamtx
        echo 0 > "$STREAM_COUNTER_FILE"
    fi
else
    echo 0 > "$STREAM_COUNTER_FILE"
fi

# ----------------------------------------------------------
# RAM Multi-cycle Protection
# ----------------------------------------------------------
if [ "$MEM_AVAILABLE" -lt "$MAX_RAM_WARN" ]; then
    COUNT=$(cat "$RAM_COUNTER_FILE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$RAM_COUNTER_FILE"
    log "Low RAM ${MEM_AVAILABLE}MB (cycle $COUNT)"

    if [ "$COUNT" -ge "$MAX_RAM_CYCLES" ]; then
        send_alert "Low RAM persistent (${MEM_AVAILABLE}MB). Restarting MediaMTX."
        systemctl restart mediamtx
        echo 0 > "$RAM_COUNTER_FILE"
    fi
else
    echo 0 > "$RAM_COUNTER_FILE"
fi

if [ "$MEM_AVAILABLE" -lt "$MAX_RAM_CRITICAL" ]; then
    send_alert "CRITICAL RAM (${MEM_AVAILABLE}MB). Emergency reboot."
    safe_reboot
fi

# ----------------------------------------------------------
# Disk & Temperature
# ----------------------------------------------------------
if [ "$DISK_PERCENT" -gt "$MAX_DISK_PERCENT" ]; then
    log "Disk critical ${DISK_PERCENT}%"
    send_alert "Disk usage critical: ${DISK_PERCENT}%"
fi

if [ "$TEMP_INT" -gt "$MAX_TEMP" ]; then
    log "High temperature ${TEMP_INT}C"
    send_alert "High temperature detected: ${TEMP_INT}C"
fi

# ----------------------------------------------------------
# Network Multi-cycle Protection
# ----------------------------------------------------------
if ! ping -c1 -W2 "$GATEWAY_IP" >/dev/null 2>&1 && \
   ! ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then

    COUNT=$(cat "$NETWORK_COUNTER_FILE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$NETWORK_COUNTER_FILE"
    log "Network failure (cycle $COUNT)"

    if [ "$COUNT" -ge "$MAX_NETWORK_CYCLES" ]; then
        send_alert "Network unreachable for $COUNT cycles. Rebooting."
        safe_reboot
    fi
else
    echo 0 > "$NETWORK_COUNTER_FILE"
fi

# ----------------------------------------------------------
# Daily Config Backup
# ----------------------------------------------------------
TODAY=$(date +%Y-%m-%d)
BACKUP_MARKER="${LOCK_DIR}/daily_backup.marker"

if [ "$(cat $BACKUP_MARKER 2>/dev/null)" != "$TODAY" ]; then
    mkdir -p "$CONFIG_BACKUP_DIR"
    cp /etc/smartcam/.env "$CONFIG_BACKUP_DIR/.env.$TODAY.bak" 2>/dev/null
    cp /etc/mediamtx/mediamtx.yml "$CONFIG_BACKUP_DIR/mediamtx.$TODAY.bak" 2>/dev/null
    echo "$TODAY" > "$BACKUP_MARKER"
    log "Daily config backup completed"
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Update heartbeat file (epoch + human readable)
if [ "$SD_WEAR_REDUCTION" = "yes" ]; then
    # Only update heartbeat every 3 cycles (~cron 1min = every 3 min)
    HB_COUNTER_FILE="${LOCK_DIR}/hb.counter"
    COUNT=$(cat "$HB_COUNTER_FILE" 2>/dev/null || echo 0)
    COUNT=$((COUNT + 1))

    if [ "$COUNT" -ge 3 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | ${END_TIME}" > "$HEARTBEAT_FILE"
        echo 0 > "$HB_COUNTER_FILE"
    else
        echo "$COUNT" > "$HB_COUNTER_FILE"
    fi
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ${END_TIME}" > "$HEARTBEAT_FILE"
fi

log "Guard cycle complete | Duration: ${DURATION}s"

exit 0