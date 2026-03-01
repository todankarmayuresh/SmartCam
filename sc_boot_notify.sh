#!/bin/bash

LOG_FILE="/var/log/smartcam/boot.log"
mkdir -p /var/log/smartcam

# Load ENV safely
if [ -f /etc/smartcam/.env ]; then
    source /etc/smartcam/.env
else
    echo "$(date): ENV file missing!" >> "$LOG_FILE"
    exit 1
fi

DATE=$(date)

IP=$(hostname -I | awk '{print $1}')
UPTIME=$(uptime -p | sed 's/up //')
DISK=$(df -h /var/lib/smartcam | awk 'NR==2 {print $5}')
RAM_FREE=$(free -m | awk '/Mem:/ {print $7}')
TEMP_RAW=$(vcgencmd measure_temp 2>/dev/null)
TEMP=$(echo "$TEMP_RAW" | cut -d= -f2 | cut -d\' -f1)

# Service Status
MEDIAMTX=$(systemctl is-active mediamtx)
FILEBROWSER=$(systemctl is-active filebrowser)
DASHBOARD=$(systemctl is-active smartcam-dashboard)
WATCHDOG=$(systemctl is-active watchdog 2>/dev/null || echo "unknown")

# Stream Check (live only)
STREAM_READY="OFFLINE"
if curl -s --max-time 3 http://localhost:9997/v3/paths/list \
   | grep -A5 '"name":"live"' | grep -q '"ready":true'; then
    STREAM_READY="LIVE"
fi

# Health Score
HEALTH=100
[ "$MEDIAMTX" != "active" ] && HEALTH=$((HEALTH-20))
[ "$FILEBROWSER" != "active" ] && HEALTH=$((HEALTH-10))
[ "$DASHBOARD" != "active" ] && HEALTH=$((HEALTH-10))
[ "$STREAM_READY" != "LIVE" ] && HEALTH=$((HEALTH-20))
[ "${DISK%\%}" -gt 85 ] && HEALTH=$((HEALTH-10))
[ "$RAM_FREE" -lt 100 ] && HEALTH=$((HEALTH-10))
[ "${TEMP%.*}" -gt 75 ] && HEALTH=$((HEALTH-10))

if [ "$HEALTH" -ge 90 ]; then
    STATUS="Excellent"
elif [ "$HEALTH" -ge 70 ]; then
    STATUS="Stable"
elif [ "$HEALTH" -ge 50 ]; then
    STATUS="Warning"
else
    STATUS="Critical"
fi

MESSAGE="🚀 SmartCam Boot Notification

📅 $DATE
🌐 IP: $IP
⏱ Uptime: $UPTIME

📊 System
• Disk: $DISK
• RAM Free: ${RAM_FREE}MB
• Temp: ${TEMP}C

🎥 Stream: $STREAM_READY

🛠 Services
• MediaMTX: $MEDIAMTX
• FileBrowser: $FILEBROWSER
• Dashboard: $DASHBOARD
• Watchdog: $WATCHDOG

❤️ Health Score: $HEALTH% ($STATUS)
"

echo "===== Boot Snapshot $DATE =====" >> "$LOG_FILE"
echo "$MESSAGE" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

curl -s --max-time 5 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d text="$MESSAGE" > /dev/null