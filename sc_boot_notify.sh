#!/bin/bash

set -euo pipefail

# =================================================
# SmartCam Guard v3 - Enterprise Hardened Edition
# =================================================

START_TIME=$(date +%s)

# -------------------------------------------------
# Lock Protection (Prevent Parallel Runs)
# -------------------------------------------------
LOCK_FILE="/tmp/sc_guard.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || exit 0

# -------------------------------------------------
# Paths & Logging
# -------------------------------------------------
LOG_DIR="/var/log/smartcam"
LOG_FILE="$LOG_DIR/guard.log"
STATE_DIR="/var/lib/smartcam"
HEARTBEAT_FILE="$STATE_DIR/guard_heartbeat"
RESTART_FLAG="$STATE_DIR/guard_restart.flag"

mkdir -p "$LOG_DIR" "$STATE_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# -------------------------------------------------
# Load Environment
# -------------------------------------------------
if [ -f /etc/smartcam/.env ]; then
    source /etc/smartcam/.env
else
    log "ENV file missing!"
    exit 1
fi

# -------------------------------------------------
# Execution Timeout Wrapper
# -------------------------------------------------
safe_run() {
    timeout 10 bash -c "$1" 2>/dev/null || echo ""
}

# -------------------------------------------------
# Heartbeat Update
# -------------------------------------------------
echo "$(date +%s)" > "$HEARTBEAT_FILE"
chmod 600 "$HEARTBEAT_FILE"

# -------------------------------------------------
# SD Wear Reduction Mode
# -------------------------------------------------
WEAR_MODE="${SD_WEAR_REDUCTION:-yes}"
if [ "$WEAR_MODE" = "yes" ]; then
    exec >> "$LOG_FILE" 2>&1
fi

# -------------------------------------------------
# Service Checks
# -------------------------------------------------
check_service() {
    local SERVICE="$1"
    STATUS=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "unknown")

    if [ "$STATUS" != "active" ]; then
        log "Service $SERVICE not active. Restarting..."
        systemctl restart "$SERVICE" 2>/dev/null || true
        sleep 3
        STATUS2=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "failed")
        if [ "$STATUS2" != "active" ]; then
            log "CRITICAL: $SERVICE failed to restart."
        else
            log "$SERVICE successfully restarted."
        fi
    fi
}

check_service mediamtx
check_service filebrowser
check_service smartcam-dashboard

# -------------------------------------------------
# RAM Monitoring
# -------------------------------------------------
RAM_FREE=$(safe_run "free -m | awk '/Mem:/ {print \$7}'")

if [[ "$RAM_FREE" =~ ^[0-9]+$ ]]; then
    if [ "$RAM_FREE" -lt 100 ]; then
        log "WARNING: Low RAM detected (${RAM_FREE}MB free)."
    fi
fi

# -------------------------------------------------
# Disk Space Monitoring
# -------------------------------------------------
DISK_PCT=$(safe_run "df -h /var/lib/smartcam | awk 'NR==2 {print \$5}'")
DISK_VAL="${DISK_PCT%\%}"

if [[ "$DISK_VAL" =~ ^[0-9]+$ ]]; then
    if [ "$DISK_VAL" -gt 90 ]; then
        log "CRITICAL: Disk usage above 90%."
    elif [ "$DISK_VAL" -gt 80 ]; then
        log "WARNING: Disk usage above 80%."
    fi
fi

# -------------------------------------------------
# Stream Health Check
# -------------------------------------------------
STREAM_STATUS=$(safe_run "curl -s http://localhost:9997/v3/paths/list | grep -A5 '\"name\":\"live\"' | grep '\"ready\":true'")

if [ -z "$STREAM_STATUS" ]; then
    log "Stream appears offline. Restarting MediaMTX..."
    systemctl restart mediamtx || true
fi

# -------------------------------------------------
# Guard Self-Health Monitoring
# -------------------------------------------------
if [ -f "$HEARTBEAT_FILE" ]; then
    LAST_BEAT=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    DIFF=$((NOW - LAST_BEAT))

    if [[ "$DIFF" =~ ^[0-9]+$ ]] && [ "$DIFF" -gt 600 ]; then
        log "Guard heartbeat stale (${DIFF}s). Attempting self-restart."
        touch "$RESTART_FLAG"
        systemctl restart smartcam-guard 2>/dev/null || true
        exit 0
    fi
fi

# -------------------------------------------------
# Predictive Failure Warnings
# -------------------------------------------------
TEMP=$(safe_run "vcgencmd measure_temp | cut -d= -f2 | cut -d\\' -f1")

if [[ "$TEMP" =~ ^[0-9]+ ]]; then
    TEMP_INT="${TEMP%.*}"
    if [ "$TEMP_INT" -gt 80 ]; then
        log "CRITICAL: CPU temperature high (${TEMP}C)."
    elif [ "$TEMP_INT" -gt 70 ]; then
        log "WARNING: CPU temperature elevated (${TEMP}C)."
    fi
fi

# -------------------------------------------------
# Execution Duration Logging
# -------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "Guard execution completed in ${DURATION}s"

exit 0