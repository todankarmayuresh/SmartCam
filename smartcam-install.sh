#!/bin/bash


set -e

# ------------------------------
# Enterprise Logging
# ------------------------------
LOG_DIR="/var/log/smartcam"
LOG_FILE="$LOG_DIR/install.log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------
# Validation Mode
# ------------------------------
if [[ "$1" == "--validate" ]]; then
    echo "Running SmartCam installer validation mode..."
    command -v curl >/dev/null || echo "curl missing"
    command -v nginx >/dev/null || echo "nginx missing"
    command -v python3 >/dev/null || echo "python3 missing"
    command -v ffmpeg >/dev/null || echo "ffmpeg missing"
    echo "Architecture: $(uname -m)"
    echo "Validation complete."
    exit 0
fi

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this installer as root (sudo)."
  exit 1
fi



echo "===== SmartCam Enterprise Installer ====="

# -------------------------------------------------
# PRE-STEP: Pull SmartCam Release from GitHub
# -------------------------------------------------
echo ""
echo "Pulling SmartCam release v1.0.0 from GitHub..."

RELEASE_URL="https://github.com/todankarmayuresh/SmartCam/archive/refs/tags/v1.0.0.tar.gz"
CURRENT_DIR="$(pwd)"
TMP_ARCHIVE="${CURRENT_DIR}/SmartCam-v1.0.0.tar.gz"
INSTALL_DIR="/opt/smartcam"

#
# Download release to current installer directory (Enterprise Hardened)
curl -fL --retry 3 --retry-delay 5 --connect-timeout 10 -o "$TMP_ARCHIVE" "$RELEASE_URL"

if [ ! -f "$TMP_ARCHIVE" ]; then
    echo "Failed to download SmartCam release."
    exit 1
fi

# Atomic extraction and install
TMP_INSTALL="${INSTALL_DIR}.new"
rm -rf "$TMP_INSTALL"
mkdir -p "$TMP_INSTALL"

tar -xzf "$TMP_ARCHIVE" -C "$TMP_INSTALL" --strip-components=1

# Atomic swap
if [ -d "$INSTALL_DIR" ]; then
    mv "$INSTALL_DIR" "${INSTALL_DIR}.old.$(date +%Y%m%d_%H%M%S)" || true
fi

mv "$TMP_INSTALL" "$INSTALL_DIR"

# Fix ownership if smartcam user exists
if id "smartcam" &>/dev/null; then
    chown -R smartcam:smartcam "$INSTALL_DIR" || true
fi

echo "SmartCam release extracted to $INSTALL_DIR"
echo ""

# -------------------------------------------------
# Configure .env (Interactive Setup)
# -------------------------------------------------
cp /opt/smartcam/env.example /opt/smartcam/.env
ENV_FILE="/opt/smartcam/.env"

# Safe update or append function
update_or_add_var() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

if [ -f "$ENV_FILE" ]; then
    echo "Configuring SmartCam environment settings..."

    # ---- Telegram Setup ----
    read -p "Enable Telegram alerts? (Y/n): " TG_ENABLE
    if [[ -z "$TG_ENABLE" || "$TG_ENABLE" =~ ^[Yy]$ ]]; then
        read -p "Enter Telegram BOT_TOKEN: " TG_TOKEN
        read -p "Enter Telegram CHAT_ID: " TG_CHAT

        update_or_add_var "BOT_TOKEN" "${TG_TOKEN}"
        update_or_add_var "CHAT_ID" "${TG_CHAT}"
        update_or_add_var "TELEGRAM_ENABLED" "true"
    else
        update_or_add_var "TELEGRAM_ENABLED" "false"
    fi

    # ---- SMB Setup ----
    read -p "Enable SMB backup? (y/N): " SMB_ENABLE
    if [[ "$SMB_ENABLE" =~ ^[Yy]$ ]]; then
        read -p "SMB Server IP (e.g. 192.168.1.50): " SMB_SERVER
        read -p "SMB Share Name: " SMB_SHARE
        read -p "SMB Username: " SMB_USER

        # Temporarily disable logging for password handling
        exec 3>&1
        exec >/dev/tty 2>&1

        read -s -p "SMB Password: " SMB_PASS
        echo ""

        # Restore logging
        exec >&3 2>&3

        update_or_add_var "SMB_ENABLED" "true"
        update_or_add_var "SMB_SERVER" "${SMB_SERVER}"
        update_or_add_var "SMB_SHARE" "${SMB_SHARE}"
        update_or_add_var "SMB_USERNAME" "${SMB_USER}"
        update_or_add_var "SMB_PASSWORD" "${SMB_PASS}"
    else
        update_or_add_var "SMB_ENABLED" "false"
    fi

    echo "Environment configuration updated."
else
    echo "WARNING: .env file not found in /opt/smartcam"
fi

# -------------------------------------------------
# 0. Optional System Update & Upgrade
# -------------------------------------------------
echo ""
echo "Would you like to update and upgrade the system before installation?"
echo "This will run: apt update && apt upgrade -y && apt autoremove -y"
read -p "Run system update now? (Y/n): " UPDATE_CHOICE

if [[ -z "$UPDATE_CHOICE" || "$UPDATE_CHOICE" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Updating system packages..."
    apt update
    apt upgrade -y
    apt autoremove -y
    echo "System update complete."
else
    echo "Skipping system update."
fi

echo ""

echo ""
echo "Set SmartCam Admin Password (used for all services)"
echo "Minimum 12 chars, must include upper, lower, number, special."

# Password prompt loop
while true; do
    read -s -p "Enter Password: " ADMIN_PASS
    echo
    read -s -p "Confirm Password: " ADMIN_PASS_CONFIRM
    echo

    if [ "$ADMIN_PASS" != "$ADMIN_PASS_CONFIRM" ]; then
        echo "Passwords do not match. Try again."
        continue
    fi

    if [[ ${#ADMIN_PASS} -lt 12 ]] || \
       [[ ! "$ADMIN_PASS" =~ [A-Z] ]] || \
       [[ ! "$ADMIN_PASS" =~ [a-z] ]] || \
       [[ ! "$ADMIN_PASS" =~ [0-9] ]] || \
       [[ ! "$ADMIN_PASS" =~ [^a-zA-Z0-9] ]]; then
        echo "Password does not meet complexity requirements."
        continue
    fi

    break
done

# -------------------------------------------------
# FileBrowser Authentication Mode
# -------------------------------------------------
echo ""
echo "FileBrowser Authentication Mode:"
echo "1) Single Auth (NGINX only, recommended)"
echo "2) Dual Auth (NGINX + FileBrowser login)"
read -p "Choose option [1-2] (default 1): " FB_AUTH_MODE

if [[ "$FB_AUTH_MODE" == "2" ]]; then
    FILEBROWSER_DUAL_AUTH="yes"
    echo "Dual authentication enabled for FileBrowser."
else
    FILEBROWSER_DUAL_AUTH="no"
    echo "Single authentication mode selected (NGINX only)."
fi
echo ""

# -------------------------------------------------
# 1. Install Dependencies
# -------------------------------------------------
echo "[1/8] Installing required packages..."
apt update -y
apt install -y \
    curl \
    wget \
    tar \
    gzip \
    jq \
    ffmpeg \
    libcamera-apps \
    v4l-utils \
    ca-certificates \
    iproute2 \
    sudo \
    rsync

# -------------------------------------------------
# 2. Create smartcam system user (if not exists)
# -------------------------------------------------
echo "[2/8] Creating smartcam user..."
if ! id "smartcam" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin smartcam
fi

usermod -aG video smartcam

# -------------------------------------------------
# 3. MediaMTX Setup
# -------------------------------------------------
echo "[3/8] MediaMTX Setup..."

#
# If MediaMTX already installed AND systemd unit present, skip full setup
if command -v mediamtx >/dev/null 2>&1 && systemctl list-unit-files | grep -q mediamtx.service; then
    echo "MediaMTX already installed. Skipping MediaMTX installation and configuration."
else

MEDIAMTX_VERSION="v1.16.3"
ARCH=$(uname -m)

# Detect correct architecture
if [[ "$ARCH" == "aarch64" ]]; then
    MTX_ARCH="linux_arm64"
elif [[ "$ARCH" == "armv7l" ]]; then
    MTX_ARCH="linux_armv7"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

TMP_DIR="/tmp/mediamtx_install"
rm -rf $TMP_DIR
mkdir -p $TMP_DIR
cd $TMP_DIR

MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_${MTX_ARCH}.tar.gz"

echo "Downloading MediaMTX from:"
echo "$MTX_URL"

curl -L -o mediamtx.tar.gz "$MTX_URL"

if [ ! -f mediamtx.tar.gz ]; then
    echo "MediaMTX download failed."
    exit 1
fi

tar -xzf mediamtx.tar.gz

if [ ! -f mediamtx ]; then
    echo "MediaMTX binary not found after extraction."
    exit 1
fi

install -m 755 mediamtx /usr/local/bin/mediamtx


# Ensure configuration directory exists
mkdir -p /etc/mediamtx

# Preserve existing active configuration if present
if [ -f /etc/mediamtx/mediamtx.yml ]; then
    cp /etc/mediamtx/mediamtx.yml /etc/mediamtx/mediamtx.yml.bak.$(date +%Y%m%d_%H%M%S)
fi

# Copy vendor default config from extracted package
if [ -f mediamtx.yml ]; then
    cp mediamtx.yml /etc/mediamtx/mediamtx.default.yml

    if [ ! -f /etc/mediamtx/mediamtx.yml ]; then
        cp mediamtx.yml /etc/mediamtx/mediamtx.yml
    fi
fi

mkdir -p /var/lib/smartcam/recordings
chown -R smartcam:smartcam /var/lib/smartcam

# -------------------------------------------------
# 4. Create MediaMTX Config
# -------------------------------------------------
echo "[4/8] Creating MediaMTX configuration..."

cat <<EOF > /etc/mediamtx/mediamtx.yml
logLevel: warn

api: yes
apiAddress: :9997

metrics: yes
metricsAddress: :9998

paths:
  live:
    source: rpiCamera

    rpiCameraWidth: 1920
    rpiCameraHeight: 1080
    rpiCameraFPS: 25

    rpiCameraCodec: hardwareH264
    rpiCameraBitrate: 6500000

    record: yes
    recordPath: /var/lib/smartcam/recordings/%path/%Y-%m-%d/%H-%M-%S
    recordSegmentDuration: 10m
    recordDeleteAfter: 7d
EOF

chown smartcam:smartcam /etc/mediamtx/mediamtx.yml

# -------------------------------------------------
# 5. Create systemd Service
# -------------------------------------------------
echo "[5/8] Creating MediaMTX service..."

cat <<EOF > /etc/systemd/system/mediamtx.service
[Unit]
Description=MediaMTX SmartCam Service
After=network.target

[Service]
User=smartcam
Group=smartcam
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mediamtx
systemctl restart mediamtx

echo ""
echo "===== MediaMTX Installation Complete ====="
systemctl status mediamtx --no-pager

# -------------------------------------------------
# 6. Install & Configure FileBrowser (Secure)
# -------------------------------------------------
fi

echo ""
echo "[6/8] FileBrowser Setup..."

# If FileBrowser already installed, skip full setup
if command -v filebrowser >/dev/null 2>&1; then
    echo "FileBrowser already installed. Skipping FileBrowser installation and configuration."
else

FILEBROWSER_VERSION="v2.30.0"
ARCH=$(uname -m)

if [[ "$ARCH" == "aarch64" ]]; then
    FB_ARCH="linux-arm64"
elif [[ "$ARCH" == "armv7l" ]]; then
    FB_ARCH="linux-armv7"
else
    echo "Unsupported architecture for FileBrowser: $ARCH"
    exit 1
fi

cd /tmp
rm -f filebrowser.tar.gz

FB_URL="https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/${FB_ARCH}-filebrowser.tar.gz"

echo "Downloading FileBrowser from:"
echo "$FB_URL"

curl -L -o filebrowser.tar.gz "$FB_URL"

if [ ! -f filebrowser.tar.gz ]; then
    echo "FileBrowser download failed."
    exit 1
fi

tar -xzf filebrowser.tar.gz

if [ ! -f filebrowser ]; then
    echo "FileBrowser binary not found after extraction."
    exit 1
fi

    install -m 755 filebrowser /usr/local/bin/filebrowser

    mkdir -p /var/lib/smartcam
    chown -R smartcam:smartcam /var/lib/smartcam

    if [[ "$FILEBROWSER_DUAL_AUTH" == "yes" ]]; then

        # Initialize DB and create admin user
        sudo -u smartcam /usr/local/bin/filebrowser \
            -d /var/lib/smartcam/filebrowser.db \
            config init

        sudo -u smartcam /usr/local/bin/filebrowser \
            -d /var/lib/smartcam/filebrowser.db \
            users add admin "$ADMIN_PASS" --perm.admin

        cat <<EOF > /etc/systemd/system/filebrowser.service
[Unit]
Description=SmartCam FileBrowser Service
After=network.target

[Service]
User=smartcam
Group=smartcam
WorkingDirectory=/var/lib/smartcam
ExecStart=/usr/local/bin/filebrowser \
  -r /var/lib/smartcam/recordings \
  -d /var/lib/smartcam/filebrowser.db \
  -a 127.0.0.1 \
  --port 8082 \
  --baseurl /files
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    else

        # No internal auth (NGINX handles security)
        cat <<EOF > /etc/systemd/system/filebrowser.service
[Unit]
Description=SmartCam FileBrowser Service
After=network.target

[Service]
User=smartcam
Group=smartcam
WorkingDirectory=/var/lib/smartcam
ExecStart=/usr/local/bin/filebrowser \
  -r /var/lib/smartcam/recordings \
  -d /var/lib/smartcam/filebrowser.db \
  -a 127.0.0.1 \
  --port 8082 \
  --baseurl /files \
  --noauth
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    fi

systemctl daemon-reload
systemctl enable filebrowser
systemctl restart filebrowser

echo ""
echo "===== FileBrowser Installation Complete ====="
systemctl status filebrowser --no-pager

fi

# -------------------------------------------------
# 7. Install & Configure NGINX (SSL + Auth)
# -------------------------------------------------
echo ""
echo "[7/8] Installing and configuring NGINX..."

apt install -y nginx apache2-utils openssl

mkdir -p /etc/nginx/ssl

# Generate self-signed SSL certificate (if not exists)
if [ ! -f /etc/nginx/ssl/smartcam.crt ]; then
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/smartcam.key \
        -out /etc/nginx/ssl/smartcam.crt \
        -subj "/C=IN/ST=MH/L=Mumbai/O=AstraMakers/OU=SmartCam/CN=$(hostname)"
fi

chmod 600 /etc/nginx/ssl/smartcam.key

# Create htpasswd file using ADMIN_PASS
htpasswd -bc /etc/nginx/.htpasswd admin "$ADMIN_PASS"

#
# Create SmartCam Web Root safely
mkdir -p /var/www/smartcam || { echo "Failed to create web root directory"; exit 1; }

# Move SmartCam index.html from release directory
if [ -f /opt/smartcam/index.html ]; then
    cp /opt/smartcam/index.html /var/www/smartcam/index.html
    chmod 644 /var/www/smartcam/index.html
    chown www-data:www-data /var/www/smartcam/index.html
else
    echo "ERROR: /opt/smartcam/index.html not found."
    exit 1
fi


#
# NGINX port 443 pre-check (Enterprise Aware)
if ss -tulnp | grep -q ":443"; then

    # If SmartCam nginx config already exists, allow reconfiguration
    if [ -f /etc/nginx/sites-available/smartcam ]; then
        echo "Port 443 already in use by nginx (SmartCam). Continuing configuration..."
    else
        echo "Port 443 already in use by another service. Aborting nginx configuration."
        ss -tulnp | grep ":443"
        exit 1
    fi

fi

# Move NGINX site config from release directory
if [ -f /opt/smartcam/smartcam ]; then
    cp /opt/smartcam/smartcam /etc/nginx/sites-available/smartcam
else
    echo "ERROR: /opt/smartcam/smartcam nginx config not found."
    exit 1
fi

ln -sf /etc/nginx/sites-available/smartcam /etc/nginx/sites-enabled/smartcam
rm -f /etc/nginx/sites-enabled/default

if nginx -t; then
    systemctl restart nginx
    systemctl enable nginx
    echo ""
    echo "===== NGINX Installation Complete ====="
    systemctl status nginx --no-pager
else
    # NGINX ROLLBACK ON TEST FAILURE
    if [ -f /etc/nginx/sites-available/smartcam.bak.* ]; then
        LATEST_BACKUP=$(ls -t /etc/nginx/sites-available/smartcam.bak.* 2>/dev/null | head -1)
        if [ -n "$LATEST_BACKUP" ]; then
            cp "$LATEST_BACKUP" /etc/nginx/sites-available/smartcam
            echo "Restored previous nginx configuration."
        fi
    fi
    exit 1
fi

# -------------------------------------------------
# 8. Enable Hardware Watchdog (systemd native)
# -------------------------------------------------
echo ""
echo "[8/8] Enabling Hardware Watchdog (systemd native)..."

# Enable BCM watchdog in Raspberry Pi firmware
if [ -f /boot/firmware/config.txt ]; then
    if ! grep -q "dtparam=watchdog=on" /boot/firmware/config.txt; then
        echo "dtparam=watchdog=on" >> /boot/firmware/config.txt
    fi
fi

# Backup systemd config
if [ -f /etc/systemd/system.conf ]; then
    cp /etc/systemd/system.conf /etc/systemd/system.conf.bak.$(date +%Y%m%d_%H%M%S)
fi

# Enable systemd hardware watchdog
if grep -q "^RuntimeWatchdogSec=" /etc/systemd/system.conf; then
    sed -i 's/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=15/' /etc/systemd/system.conf
else
    echo "RuntimeWatchdogSec=15" >> /etc/systemd/system.conf
fi

# Disable watchdog daemon if installed
if systemctl list-unit-files | grep -q watchdog.service; then
    systemctl disable watchdog >/dev/null 2>&1 || true
    systemctl stop watchdog >/dev/null 2>&1 || true
fi

#
# -------------------------------------------------
# 9. Install SmartCam Core Services (Dashboard + Guards + Backup)
# -------------------------------------------------
echo ""
echo "[9/9] Installing SmartCam Core Services..."

mkdir -p /opt/smartcam
mkdir -p /var/log/smartcam
mkdir -p /var/lib/smartcam
mkdir -p /var/lib/smartcam/backups
mkdir -p /var/lib/smartcam/locks
chown -R smartcam:smartcam /opt/smartcam
chown -R smartcam:smartcam /var/log/smartcam
chown -R smartcam:smartcam /var/lib/smartcam
chown -R smartcam:smartcam /var/lib/smartcam/backups
chown -R smartcam:smartcam /var/lib/smartcam/locks
chmod +x /opt/smartcam/sc_guard.sh
chmod +x /opt/smartcam/sc_backup.sh
chmod +x /opt/smartcam/sc_sd_guard.sh
chmod +x /opt/smartcam/sc_boot_notify.sh

# VERIFY CORE SCRIPTS EXIST BEFORE SERVICES
for f in sc_dashboard.py sc_guard.sh sc_sd_guard.sh sc_backup.sh sc_boot_notify.sh; do
    if [ ! -f "/opt/smartcam/$f" ]; then
        echo "ERROR: Missing required file /opt/smartcam/$f"
        exit 1
    fi
done

# ---- Dashboard Service ----
cat <<EOF > /etc/systemd/system/sc-dashboard.service
[Unit]
Description=SmartCam Dashboard Service
After=network.target mediamtx.service

[Service]
User=smartcam
Group=smartcam
WorkingDirectory=/opt/smartcam
ExecStart=/usr/bin/python3 /opt/smartcam/sc_dashboard.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- Guard Service ----
cat <<EOF > /etc/systemd/system/sc-guard.service
[Unit]
Description=SmartCam Health Guard
After=network.target mediamtx.service

[Service]
Type=oneshot
User=smartcam
Group=smartcam
ExecStart=/opt/smartcam/sc_guard.sh
EOF

cat <<EOF > /etc/systemd/system/sc-guard.timer
[Unit]
Description=Run SmartCam Guard every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=sc-guard.service

[Install]
WantedBy=timers.target
EOF

# ---- SD Guard Service ----
cat <<EOF > /etc/systemd/system/sc-sdguard.service
[Unit]
Description=SmartCam SD Disk Protection
After=network.target

[Service]
Type=oneshot
User=smartcam
Group=smartcam
ExecStart=/opt/smartcam/sc_sd_guard.sh
EOF

cat <<EOF > /etc/systemd/system/sc-sdguard.timer
[Unit]
Description=Run SD Guard every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Unit=sc-sdguard.service

[Install]
WantedBy=timers.target
EOF

# ---- Backup Service ----
cat <<EOF > /etc/systemd/system/sc-backup.service
[Unit]
Description=SmartCam Configuration Backup

[Service]
Type=oneshot
User=smartcam
Group=smartcam
ExecStart=/opt/smartcam/sc_backup.sh
EOF

cat <<EOF > /etc/systemd/system/sc-backup.timer
[Unit]
Description=Daily SmartCam Backup (02:30)

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
Unit=sc-backup.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

systemctl enable sc-dashboard
systemctl enable sc-guard.timer
systemctl enable sc-sdguard.timer
systemctl enable sc-backup.timer

systemctl restart sc-dashboard || true
systemctl start sc-guard.timer
systemctl start sc-sdguard.timer
systemctl start sc-backup.timer

echo ""
echo "SmartCam Core Services Installed:"
echo "  • sc-dashboard.service"
echo "  • sc-guard.timer (2 min)"
echo "  • sc-sdguard.timer (5 min)"
echo "  • sc-backup.timer (daily 02:30)"
echo ""


# -------------------------------------------------
# Firewall (UFW) Configuration
# -------------------------------------------------
echo ""
echo "Configuring firewall (UFW)..."

if ! command -v ufw >/dev/null 2>&1; then
    apt install -y ufw
fi

# Reset rules safely (idempotent)
ufw --force reset >/dev/null 2>&1 || true

ufw default deny incoming
ufw default allow outgoing

ufw allow 22    # SSH
ufw allow 80    # HTTP
ufw allow 443   # HTTPS

ufw --force enable
ufw status verbose

# -------------------------------------------------
# Fail2Ban Installation & Configuration
# -------------------------------------------------
echo ""
echo "Installing and configuring Fail2Ban..."

if ! command -v fail2ban-client >/dev/null 2>&1; then
    apt install -y fail2ban
fi

mkdir -p /etc/fail2ban

cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s

[nginx-http-auth]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
EOF

systemctl enable fail2ban
systemctl restart fail2ban
systemctl status fail2ban --no-pager

echo ""
echo "========================================="
echo "SmartCam Enterprise Install Summary"
echo "========================================="
echo "MediaMTX      : $(systemctl is-active mediamtx 2>/dev/null)"
echo "FileBrowser   : $(systemctl is-active filebrowser 2>/dev/null)"
echo "NGINX         : $(systemctl is-active nginx 2>/dev/null)"
echo "Dashboard     : $(systemctl is-active sc-dashboard 2>/dev/null)"
echo "Guard Timer   : $(systemctl is-active sc-guard.timer 2>/dev/null)"
echo "SD Guard      : $(systemctl is-active sc-sdguard.timer 2>/dev/null)"
echo "Backup Timer  : $(systemctl is-active sc-backup.timer 2>/dev/null)"
echo "========================================="

echo ""
echo "===== Hardware Watchdog Enabled (systemd native) ====="
echo "RuntimeWatchdogSec set to 15 seconds."
echo ""
echo "Installer Complete."
echo "Hardware watchdog requires reboot to activate."
read -p "Reboot now? (Y/n): " REBOOT_CHOICE
if [[ -z "$REBOOT_CHOICE" || "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
    reboot
fi