#!/bin/bash
set -e

echo "===== SmartCam Enterprise Installer ====="

echo ""
echo "Set SmartCam Admin Password (used for all services)"
echo "Minimum 12 chars, must include upper, lower, number, special."

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
# 1. Install Dependencies
# -------------------------------------------------
echo "[1/5] Installing required packages..."
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
echo "[2/5] Creating smartcam user..."
if ! id "smartcam" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin smartcam
fi

usermod -aG video smartcam

# -------------------------------------------------
# 3. Install MediaMTX
# -------------------------------------------------
echo "[3/5] Installing MediaMTX..."

MEDIAMTX_VERSION="v1.16.2"
TMP_DIR="/tmp/mediamtx_install"

mkdir -p $TMP_DIR
cd $TMP_DIR

wget -q https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION#v}_linux_arm64.tar.gz

tar -xzf mediamtx_${MEDIAMTX_VERSION#v}_linux_arm64.tar.gz

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

    # If no active config exists yet, create it from vendor default
    if [ ! -f /etc/mediamtx/mediamtx.yml ]; then
        cp mediamtx.yml /etc/mediamtx/mediamtx.yml
    fi
fi

mkdir -p /var/lib/smartcam/recordings
chown -R smartcam:smartcam /var/lib/smartcam

# -------------------------------------------------
# 4. Create MediaMTX Config
# -------------------------------------------------
echo "[4/5] Creating MediaMTX configuration..."

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
echo "[5/5] Creating MediaMTX service..."

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
echo ""
echo "[6/6] Installing FileBrowser..."

FILEBROWSER_VERSION="v2.30.0"
cd /tmp

wget -q https://github.com/filebrowser/filebrowser/releases/download/${FILEBROWSER_VERSION}/linux-arm64-filebrowser.tar.gz
tar -xzf linux-arm64-filebrowser.tar.gz
install -m 755 filebrowser /usr/local/bin/filebrowser

mkdir -p /var/lib/smartcam
chown -R smartcam:smartcam /var/lib/smartcam

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
  --port 8082
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable filebrowser
systemctl restart filebrowser

echo ""
echo "===== FileBrowser Installation Complete ====="
systemctl status filebrowser --no-pager

# -------------------------------------------------
# 7. Install & Configure NGINX (SSL + Auth)
# -------------------------------------------------
echo ""
echo "[7/7] Installing and configuring NGINX..."

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

# Create NGINX site config
cat <<EOF > /etc/nginx/sites-available/smartcam
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/smartcam.crt;
    ssl_certificate_key /etc/nginx/ssl/smartcam.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    root /var/www/smartcam;
    index index.html;

    # Login page (static only)
    location = / {
        auth_basic "SmartCam Secure Area";
        auth_basic_user_file /etc/nginx/.htpasswd;
        root /var/www/smartcam;
        index index.html;
        try_files /index.html =404;
    }

    # Static assets (if any)
    location /static/ {
        root /var/www/smartcam;
    }

    location /dashboard/ {
        auth_basic "SmartCam Secure Area";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass http://127.0.0.1:8090/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # File browser
    location /files/ {
        auth_basic "SmartCam Secure Area";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass http://127.0.0.1:8082/files/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # WebRTC live stream
    location /live/ {
        auth_basic "SmartCam Secure Area";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass http://127.0.0.1:8889/live/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location = /logout {
        return 401;
    }
}
EOF

ln -sf /etc/nginx/sites-available/smartcam /etc/nginx/sites-enabled/smartcam
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx
systemctl enable nginx

echo ""
echo "===== NGINX Installation Complete ====="
systemctl status nginx --no-pager

# -------------------------------------------------
# 8. Enable Hardware Watchdog (Daemon + systemd)
# -------------------------------------------------
echo ""
echo "[8/8] Enabling Hardware Watchdog..."

# Install watchdog package (idempotent safe)
apt install -y watchdog

# Backup existing watchdog.conf
if [ -f /etc/watchdog.conf ]; then
    cp /etc/watchdog.conf /etc/watchdog.conf.bak.$(date +%Y%m%d_%H%M%S)
fi

# Write minimal production configuration
cat <<EOF > /etc/watchdog.conf
watchdog-device = /dev/watchdog
interval = 10
realtime = yes
priority = 1
EOF

# Ensure correct permissions
chmod 644 /etc/watchdog.conf

# Backup systemd config
if [ -f /etc/systemd/system.conf ]; then
    cp /etc/systemd/system.conf /etc/systemd/system.conf.bak.$(date +%Y%m%d_%H%M%S)
fi

# Enable RuntimeWatchdogSec (safe replace or append)
if grep -q "^RuntimeWatchdogSec=" /etc/systemd/system.conf; then
    sed -i 's/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=15/' /etc/systemd/system.conf
else
    echo "RuntimeWatchdogSec=15" >> /etc/systemd/system.conf
fi

# Enable and restart watchdog service
systemctl enable watchdog
systemctl restart watchdog

echo ""
echo "===== Hardware Watchdog Enabled (Daemon + systemd) ====="
systemctl status watchdog --no-pager

echo ""
echo "Installer Complete."
echo "Reboot recommended to fully activate RuntimeWatchdogSec."

# -------------------------------------------------
# 8. Enable systemd Hardware Watchdog Integration
# -------------------------------------------------
echo ""
echo "[8/8] Enabling systemd Hardware Watchdog..."

# Ensure watchdog package is installed
apt install -y watchdog

# Backup systemd config before modification
if [ -f /etc/systemd/system.conf ]; then
    cp /etc/systemd/system.conf /etc/systemd/system.conf.bak.$(date +%Y%m%d_%H%M%S)
fi

# Enable RuntimeWatchdogSec if not already enabled
if ! grep -q "^RuntimeWatchdogSec=" /etc/systemd/system.conf; then
    echo "RuntimeWatchdogSec=15" >> /etc/systemd/system.conf
else
    sed -i 's/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=15/' /etc/systemd/system.conf
fi

# Ensure watchdog service is enabled
systemctl enable watchdog
systemctl restart watchdog

echo ""
echo "===== Hardware Watchdog Integration Enabled ====="
systemctl status watchdog --no-pager

echo ""
echo "Installer Complete. A reboot is recommended to fully activate RuntimeWatchdogSec."