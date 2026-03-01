from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import re
import json
import urllib.request
import os
import time

from datetime import datetime

# Load environment configuration (optional)
ENV_FILE = "/etc/smartcam/.env"
if os.path.exists(ENV_FILE):
    with open(ENV_FILE) as f:
        for line in f:
            if line.strip() and not line.startswith("#") and "=" in line:
                key, val = line.strip().split("=", 1)
                os.environ[key] = val

SNAPSHOT_FILE = os.environ.get("SNAPSHOT_FILE", "/var/lib/smartcam/system_state.json")
STREAM_NAME = os.environ.get("STREAM_NAME", "live")

previous_bytes = 0
previous_time = time.time()

def run(cmd):
    return subprocess.getoutput(cmd)

def get_cpu():
    cpu_raw = run("top -bn1 | grep 'Cpu(s)'")
    match = re.search(r"(\d+\.\d+)\s*us", cpu_raw)
    return float(match.group(1)) if match else 0

def get_temp():
    temp_raw = run("vcgencmd measure_temp")
    match = re.search(r"=([\d\.]+)", temp_raw)
    return float(match.group(1)) if match else 0

def get_disk():
    line = run("df -h /var/lib/smartcam | tail -1")
    parts = line.split()
    return int(parts[4].replace("%", "")) if len(parts) > 4 else 0

def get_ram():
    mem_raw = run("free -m | awk '/Mem:/ {print $7}'")
    return int(mem_raw) if mem_raw.isdigit() else 0

def get_uptime():
    return run("uptime -p").replace("up ", "", 1)

def get_services():
    return {
        "mediamtx": run("systemctl is-active mediamtx").strip(),
        "filebrowser": run("systemctl is-active filebrowser").strip(),
        "watchdog": run("systemctl is-active watchdog").strip()
    }

def get_stream_info():
    ready = False
    readers = 0
    bytes_received = 0
    viewer_ips = []
    try:
        with urllib.request.urlopen("http://localhost:9997/v3/paths/list", timeout=2) as r:
            data = json.loads(r.read().decode())
            for item in data.get("items", []):
                if item["name"] == STREAM_NAME:
                    ready = item.get("ready", False)
                    readers = len(item.get("readers", []))
                    bytes_received = item.get("bytesReceived", 0)

        with urllib.request.urlopen("http://localhost:9997/v3/sessions/list", timeout=2) as r:
            sess = json.loads(r.read().decode())
            for s in sess.get("items", []):
                if s.get("path") == STREAM_NAME:
                    viewer_ips.append(s.get("remoteAddr", "unknown"))
    except:
        pass
    return ready, readers, bytes_received, viewer_ips

def calculate_bitrate(current_bytes):
    global previous_bytes, previous_time
    now = time.time()
    delta_time = now - previous_time
    delta_bytes = current_bytes - previous_bytes
    previous_bytes = current_bytes
    previous_time = now
    if delta_time <= 0:
        return 0
    return round((delta_bytes * 8) / (delta_time * 1000000), 2)

def get_protocol_activity():
    activity = {}
    try:
        with urllib.request.urlopen("http://localhost:9998/metrics", timeout=2) as r:
            metrics = r.read().decode()
            for proto in ["rtsp_sessions", "webrtc_sessions", "hls_muxers"]:
                match = re.search(rf"{proto} (\d+)", metrics)
                activity[proto] = int(match.group(1)) if match else 0
    except:
        activity = {"rtsp_sessions":0,"webrtc_sessions":0,"hls_muxers":0}
    return activity

def get_last_recording():
    base = "/var/lib/smartcam/recordings/live"
    latest = None
    for root, dirs, files in os.walk(base):
        for f in files:
            path = os.path.join(root, f)
            if not latest or os.path.getmtime(path) > os.path.getmtime(latest):
                latest = path
    if latest:
        return datetime.fromtimestamp(os.path.getmtime(latest)).strftime("%Y-%m-%d %H:%M:%S")
    return "N/A"

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):
        cpu = get_cpu()
        temp = get_temp()
        disk = get_disk()
        ram = get_ram()
        uptime = get_uptime()
        services = get_services()
        ready, readers, bytes_received, viewer_ips = get_stream_info()
        bitrate = calculate_bitrate(bytes_received)
        protocols = get_protocol_activity()
        last_record = get_last_recording()

        min_bitrate = float(os.environ.get("MIN_BITRATE_MBPS", "1"))
        freeze = ready and bitrate < min_bitrate

        # ---- Predictive Weighted Health Engine ----

        if not ready:
            stream_score = 0
        elif bitrate < min_bitrate:
            stream_score = 15
        else:
            stream_score = 30

        try:
            last_dt = datetime.strptime(last_record, "%Y-%m-%d %H:%M:%S")
            minutes_old = (datetime.now() - last_dt).total_seconds() / 60
            if minutes_old < 10:
                recording_score = 20
            elif minutes_old < 20:
                recording_score = 10
            else:
                recording_score = 0
        except:
            recording_score = 0

        # ---- Disk Score (20%) - Based on Free Space ----
        try:
            free_raw = run("df -m /var/lib/smartcam | awk 'NR==2 {print $4}'")
            free_mb = int(free_raw) if free_raw.isdigit() else 0

            if free_mb > 4096:
                disk_score = 20
            elif free_mb > 2048:
                disk_score = 12
            elif free_mb > 1024:
                disk_score = 5
            else:
                disk_score = 0
        except:
            free_mb = 0
            disk_score = 0
        temp_score = max(0, 15 - int(max(0, temp - 40) * 0.5))

        services_score = 0
        for s in services.values():
            if s == "active":
                services_score += 5

        health_score = stream_score + recording_score + disk_score + temp_score + services_score

        if health_score >= 90:
            health_label = "Excellent"
            health_color = "#00ff88"
        elif health_score >= 70:
            health_label = "Stable"
            health_color = "#ffaa00"
        elif health_score >= 50:
            health_label = "Warning"
            health_color = "#ff8800"
        else:
            health_label = "Critical"
            health_color = "#ff4444"

        # ---- Central Health Snapshot ----
        try:
            snapshot = {
                "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                "cpu": round(cpu, 1),
                "ram_free_mb": ram,
                "temp": round(temp, 1),
                "disk_percent": disk,
                "disk_free_mb": free_mb,
                "uptime": uptime,
                "stream_ready": ready,
                "readers": readers,
                "bitrate_mbps": bitrate,
                "services": services,
                "health_score": health_score,
                "health_label": health_label
            }

            os.makedirs("/var/lib/smartcam", exist_ok=True)
            with open(SNAPSHOT_FILE, "w") as f:
                json.dump(snapshot, f, indent=4)
        except Exception:
            pass

        if self.path == "/status":
            response = {
                "cpu": round(cpu, 1),
                "temp": round(temp, 1),
                "disk": disk,
                "ram": ram,
                "ready": ready,
                "bitrate": bitrate,
                "guard": f"{health_score}% ({health_label})"
            }
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(response).encode())
            return

        ram_color = "#00ff88" if ram > 200 else "#ffaa00" if ram > 100 else "#ff4444"

        html = f"""
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>SmartCam Enterprise Monitor</title>
<style>
body {{ background:#0f172a; color:#e2e8f0; font-family:Arial; padding:30px; }}
.grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(260px,1fr)); gap:25px; margin-top:20px; }}
.card {{ background:#1e293b; padding:20px; border-radius:12px; }}
.value {{ font-size:26px; font-weight:bold; }}
.alert {{ background:#7f1d1d; padding:10px; border-radius:8px; margin-top:10px; display:{'block' if freeze else 'none'}; }}
</style>
<script>
setInterval(() => location.reload(), 5000);
</script>
</head>
<body>

<h1>SmartCam Enterprise Monitor</h1>

<div class="alert">⚠ Stream appears frozen (bitrate too low)</div>

<div class="grid">

<div class="card" style="border-left:6px solid {health_color};">
<h2>Health Score</h2>
<div class="value" style="color:{health_color};">
{health_score}% - {health_label}
</div>
</div>

<div class="card">
<h2>Stream</h2>
<div class="value" style="color:{'#00ff88' if ready else '#ff4444'};">
{'LIVE' if ready else 'OFFLINE'}
</div>
<div>Bitrate: {bitrate} Mbps</div>
<div>Readers: {readers}</div>
<div>Viewer IPs: {', '.join(viewer_ips) if viewer_ips else 'None'}</div>
<div>Last Recording: {last_record}</div>
</div>

<div class="card">
<h2>Protocols</h2>
<div>RTSP: {protocols['rtsp_sessions']}</div>
<div>WebRTC: {protocols['webrtc_sessions']}</div>
<div>HLS: {protocols['hls_muxers']}</div>
</div>

<div class="card">
<h2>System</h2>

<div>
<span style="color:#ffffff;">CPU:</span>
<span style="color:{'#ff4444' if cpu>80 else '#ffaa00' if cpu>60 else '#00ff88'}; font-weight:bold;">
{cpu:.1f}%
</span>
</div>

<div>
<span style="color:#ffffff;">RAM:</span>
<span style="color:{ram_color}; font-weight:bold;">
{ram} MB
</span>
</div>

<div>
<span style="color:#ffffff;">Temp:</span>
<span style="color:{'#ff4444' if temp>75 else '#ffaa00' if temp>65 else '#00ff88'}; font-weight:bold;">
{temp:.1f} C
</span>
</div>

<div>
<span style="color:#ffffff;">Disk:</span>
<span style="color:{'#ff4444' if disk>85 else '#ffaa00' if disk>70 else '#00ff88'}; font-weight:bold;">
{disk}%
</span>
</div>

<div>
<span style="color:#ffffff;">Uptime:</span>
<span style="font-weight:bold;">
{uptime}
</span>
</div>

</div>

<div class="card">
<h2>Services</h2>

<div>
<span style="color:#ffffff;">MediaMTX:</span>
<span style="color:{'#00ff88' if services['mediamtx']=='active' else '#ff4444'}; font-weight:bold;">
{services['mediamtx']}
</span>
</div>

<div>
<span style="color:#ffffff;">FileBrowser:</span>
<span style="color:{'#00ff88' if services['filebrowser']=='active' else '#ff4444'}; font-weight:bold;">
{services['filebrowser']}
</span>
</div>

<div>
<span style="color:#ffffff;">Watchdog:</span>
<span style="color:{'#00ff88' if services['watchdog']=='active' else '#ff4444'}; font-weight:bold;">
{services['watchdog']}
</span>
</div>

</div>

</div>
</body>
</html>
        """

        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write(html.encode())

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8090), Handler)
    server.serve_forever()