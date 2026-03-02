from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import re
import json
import urllib.request
import os
import time
import threading
from datetime import datetime

# -------------------------------------------------
# Environment Loader
# -------------------------------------------------
ENV_FILE = "/etc/smartcam/.env"
if os.path.exists(ENV_FILE):
    with open(ENV_FILE) as f:
        for line in f:
            if line.strip() and not line.startswith("#") and "=" in line:
                key, val = line.strip().split("=", 1)
                os.environ[key] = val

SNAPSHOT_FILE = os.environ.get("SNAPSHOT_FILE", "/var/lib/smartcam/system_state.json")
STREAM_NAME = os.environ.get("STREAM_NAME", "live")
MIN_BITRATE = float(os.environ.get("MIN_BITRATE_MBPS", "1"))

HEARTBEAT_FILE = "/var/lib/smartcam/guard_heartbeat"
BOOT_ALERT_FLAG = "/var/lib/smartcam/boot_alert.flag"
BOOT_EVENT_FILE = "/var/lib/smartcam/boot_event.json"
BACKUP_HEALTH_FILE = "/var/lib/smartcam/backup_health.json"
BACKUP_WARN_AGE_MIN = int(os.environ.get("BACKUP_WARN_AGE_MIN", "1440"))  # default 24h
HEARTBEAT_STALE_LIMIT = int(os.environ.get("HEARTBEAT_STALE_LIMIT", "600"))

# -------------------------------------------------
# Global Cached State
# -------------------------------------------------
cached_data = {}
last_snapshot_write = 0
snapshot_interval = 30  # seconds


# -------------------------------------------------
# Safe Command Execution
# -------------------------------------------------
def run(cmd, timeout=2):
    try:
        return subprocess.check_output(cmd, shell=True, timeout=timeout).decode().strip()
    except:
        return ""


def safe_int(val):
    try:
        return int(float(val))
    except:
        return 0

def system_cmd(cmd):
    try:
        subprocess.Popen(cmd, shell=True)
        return True
    except:
        return False


# -------------------------------------------------
# Metric Collector (Background Thread)
# -------------------------------------------------
def collect_metrics():
    global cached_data, last_snapshot_write

    previous_bytes = 0
    previous_time = time.time()

    while True:
        cpu_out = run("top -bn1 | grep 'Cpu(s)'")
        cpu_match = re.search(r"(\d+\.\d+)\s*us", cpu_out)
        cpu = float(cpu_match.group(1)) if cpu_match else 0

        temp_out = run("vcgencmd measure_temp 2>/dev/null")
        temp_match = re.search(r"=([\d\.]+)", temp_out)
        temp = float(temp_match.group(1)) if temp_match else 0

        disk_percent = safe_int(run("df -h /var/lib/smartcam | awk 'NR==2 {print $5}' | sed 's/%//'"))
        disk_free_mb = safe_int(run("df -m /var/lib/smartcam | awk 'NR==2 {print $4}'"))
        ram = safe_int(run("awk '/MemAvailable/ {print $2/1024}' /proc/meminfo"))
        uptime = run("uptime -p").replace("up ", "", 1)
        load_avg = run("awk '{print $1}' /proc/loadavg")

        services = {
            "mediamtx": run("systemctl is-active mediamtx"),
            "filebrowser": run("systemctl is-active filebrowser"),
            "watchdog": run("systemctl is-active watchdog")
        }

        ready = False
        readers = 0
        bytes_received = 0

        try:
            with urllib.request.urlopen("http://localhost:9997/v3/paths/list", timeout=2) as r:
                data = json.loads(r.read().decode())
                for item in data.get("items", []):
                    if item["name"] == STREAM_NAME:
                        ready = item.get("ready", False)
                        readers = len(item.get("readers", []))
                        bytes_received = item.get("bytesReceived", 0)
        except:
            pass

        now = time.time()
        delta_time = now - previous_time
        delta_bytes = bytes_received - previous_bytes
        previous_bytes = bytes_received
        previous_time = now
        bitrate = round((delta_bytes * 8) / (delta_time * 1000000), 2) if delta_time > 0 else 0

        freeze = ready and bitrate < MIN_BITRATE

        stream_score = 30 if ready and bitrate >= MIN_BITRATE else 15 if ready else 0
        disk_score = 20 if disk_free_mb > 4096 else 12 if disk_free_mb > 2048 else 5 if disk_free_mb > 1024 else 0
        temp_score = max(0, 15 - int(max(0, temp - 40) * 0.5))
        service_score = sum(5 for s in services.values() if s == "active")
        ram_score = 10 if ram > 300 else 5 if ram > 150 else 0

        health_score = stream_score + disk_score + temp_score + service_score + ram_score

        # -------------------------------------------------
        # Predictive Failure Warnings
        # -------------------------------------------------
        warnings = []

        if disk_percent > 80:
            warnings.append("Disk usage trending high")

        if ram < 150:
            warnings.append("Low available RAM")

        if temp > 70:
            warnings.append("High temperature risk")

        if not ready:
            warnings.append("Stream offline")

        # -------------------------------------------------
        # Guard Heartbeat Check
        # -------------------------------------------------
        guard_status = "Unknown"
        guard_age = -1

        if os.path.exists(HEARTBEAT_FILE):
            try:
                with open(HEARTBEAT_FILE) as hb:
                    content = hb.read().strip()
                    if "|" in content:
                        epoch = int(content.split("|")[1].strip())
                        guard_age = int(time.time() - epoch)

                        if guard_age <= HEARTBEAT_STALE_LIMIT:
                            guard_status = "Healthy"
                        else:
                            guard_status = "Stale"
                    else:
                        guard_status = "Invalid"
            except:
                guard_status = "Error"
        else:
            guard_status = "Missing"

        # -------------------------------------------------
        # Boot Intelligence Integration
        # -------------------------------------------------
        boot_event = {}
        boot_escalation = False

        if os.path.exists(BOOT_EVENT_FILE):
            try:
                with open(BOOT_EVENT_FILE) as bf:
                    boot_event = json.load(bf)
            except:
                boot_event = {}

        if os.path.exists(BOOT_ALERT_FLAG):
            boot_escalation = True

        # -------------------------------------------------
        # Backup Intelligence
        # -------------------------------------------------
        backup_status = "Unknown"
        backup_age_min = -1
        backup_failures = 0

        if os.path.exists(BACKUP_HEALTH_FILE):
            try:
                with open(BACKUP_HEALTH_FILE) as bf:
                    backup_data = json.load(bf)

                last_success = backup_data.get("last_success_epoch")
                backup_failures = int(backup_data.get("consecutive_failures", 0))

                if last_success:
                    backup_age_min = int((time.time() - int(last_success)) / 60)

                    if backup_age_min <= BACKUP_WARN_AGE_MIN:
                        backup_status = "Healthy"
                    else:
                        backup_status = "Stale"
                else:
                    backup_status = "Never"

                if backup_failures > 0:
                    backup_status = "Degraded"

            except:
                backup_status = "Error"
        else:
            backup_status = "Missing"

        cached_data = {
            "cpu": round(cpu, 1),
            "temp": round(temp, 1),
            "disk_percent": disk_percent,
            "disk_free_mb": disk_free_mb,
            "ram": ram,
            "uptime": uptime,
            "load_avg": load_avg,
            "ready": ready,
            "readers": readers,
            "bitrate": bitrate,
            "freeze": freeze,
            "services": services,
            "guard_status": guard_status,
            "guard_age": guard_age,
            "warnings": warnings,
            "health_score": health_score,
            "health_label": "Excellent" if health_score >= 90 else "Stable" if health_score >= 70 else "Warning" if health_score >= 50 else "Critical",
            "boot_event": boot_event,
            "boot_escalation": boot_escalation,
            "backup_status": backup_status,
            "backup_age_min": backup_age_min,
            "backup_failures": backup_failures,
        }

        if now - last_snapshot_write > snapshot_interval:
            try:
                os.makedirs("/var/lib/smartcam", exist_ok=True)
                with open(SNAPSHOT_FILE, "w") as f:
                    json.dump(cached_data, f, indent=4)
                last_snapshot_write = now
            except:
                pass

        time.sleep(5)


# -------------------------------------------------
# HTTP Handler
# -------------------------------------------------
class Handler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        return

    def do_GET(self):

        if self.path == "/status":
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(json.dumps(cached_data).encode())
            return

        if self.path == "/restart-guard":
            system_cmd("systemctl restart smartcam-guard.service || systemctl restart sc_guard.service || pkill -f sc_guard.sh")
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return

        if self.path == "/reboot-system":
            system_cmd("reboot")
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"Rebooting...")
            return

        html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>SmartCam Enterprise Monitor</title>
<style>
body { background:#0f172a; color:#e2e8f0; font-family:Arial; padding:30px; }
.card { background:#1e293b; padding:20px; border-radius:12px; margin-bottom:20px; }
.value { font-size:24px; font-weight:bold; }
.green { color:#00ff88; }
.yellow { color:#ffaa00; }
.red { color:#ff4444; }
</style>
</head>
<body>

<h1>SmartCam Enterprise Monitor</h1>

<div id="alertBanner" class="card" style="display:none; background:#7f1d1d;"></div>
<div id="bootBanner" class="card" style="display:none; background:#5b1a1a;"></div>

<div class="card">
<h2>Health Score</h2>
<div id="health" class="value"></div>
</div>

<div class="card">
<h2>System</h2>
<div id="system"></div>
</div>

<div class="card">
<h2>Backup</h2>
<div id="backup"></div>
</div>

<div class="card">
<h2>Guard</h2>
<div id="guard"></div>
</div>

<div class="card">
<h2>Controls</h2>
<button onclick="location.href='/restart-guard'">Restart Guard</button>
<button onclick="if(confirm('Reboot system?')) location.href='/reboot-system'">Reboot System</button>
</div>

<script>
function update(){
 fetch('/status')
  .then(r=>r.json())
  .then(d=>{
    document.getElementById("health").innerHTML = d.health_score + "% - " + d.health_label;
    document.getElementById("system").innerHTML =
      "CPU: " + d.cpu + "%<br>" +
      "RAM: " + d.ram + " MB<br>" +
      "Temp: " + d.temp + " C<br>" +
      "Disk: " + d.disk_percent + "%<br>" +
      "Load: " + d.load_avg + "<br>" +
      "Uptime: " + d.uptime;

    let guardColor = "green";
    if (d.guard_status === "Stale" || d.guard_status === "Missing") guardColor = "red";
    if (d.guard_status === "Unknown" || d.guard_status === "Invalid") guardColor = "yellow";

    document.getElementById("guard").innerHTML =
      "Status: <span class='" + guardColor + "'>" + d.guard_status + "</span><br>" +
      "Last Seen: " + (d.guard_age >= 0 ? d.guard_age + "s ago" : "N/A");

    let backupColor = "green";
    if (d.backup_status === "Stale" || d.backup_status === "Missing" || d.backup_status === "Never") backupColor = "red";
    if (d.backup_status === "Degraded" || d.backup_status === "Error") backupColor = "yellow";

    document.getElementById("backup").innerHTML =
      "Status: <span class='" + backupColor + "'>" + d.backup_status + "</span><br>" +
      "Last Success: " + (d.backup_age_min >= 0 ? d.backup_age_min + " min ago" : "N/A") + "<br>" +
      "Failures: " + d.backup_failures;

    if (d.backup_age_min > 0 && d.backup_age_min > """ + str(BACKUP_WARN_AGE_MIN) + """) {
        document.getElementById("alertBanner").style.display = "block";
        document.getElementById("alertBanner").innerHTML =
          "<strong>Warning:</strong> Backup is older than expected threshold.";
    }

    // Alert banner when guard stale
    if (d.guard_status === "Stale" || d.guard_status === "Missing") {
        document.getElementById("alertBanner").style.display = "block";
        document.getElementById("alertBanner").innerHTML =
          "<strong>ALERT:</strong> Guard service unhealthy!";
    } else {
        document.getElementById("alertBanner").style.display = "none";
    }

    // Boot escalation banner
    if (d.boot_escalation === true) {
        document.getElementById("bootBanner").style.display = "block";

        let msg = "<strong>BOOT ALERT:</strong><br>";

        if (d.boot_event) {
            msg += "Type: " + (d.boot_event.boot_type || "Unknown") + "<br>";
            msg += "Reason: " + (d.boot_event.boot_reason || "Unknown") + "<br>";
            msg += "Boot Count: " + (d.boot_event.boot_count || "N/A") + "<br>";
            msg += "Loop: " + (d.boot_event.boot_loop || "N/A");
        }

        document.getElementById("bootBanner").innerHTML = msg;
    } else {
        document.getElementById("bootBanner").style.display = "none";
    }

    // Predictive warnings
    if (d.warnings && d.warnings.length > 0) {
        document.getElementById("alertBanner").style.display = "block";
        document.getElementById("alertBanner").innerHTML =
          "<strong>Warning:</strong><br>" + d.warnings.join("<br>");
    }
  });
}
setInterval(update,5000);
update();
</script>

</body>
</html>
"""
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(html.encode())


# -------------------------------------------------
# Start Background Collector + Server
# -------------------------------------------------
if __name__ == "__main__":
    threading.Thread(target=collect_metrics, daemon=True).start()
    server = HTTPServer(("0.0.0.0", 8090), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass