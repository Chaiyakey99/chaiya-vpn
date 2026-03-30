#!/bin/bash
# ============================================================
#  CHAIYA V2RAY PRO MAX v9  —  Full Auto Setup
#  ติดตั้งครั้งเดียว พร้อมใช้งาน 100% ไม่ต้องแก้มือ
# ============================================================
echo "🔥 กำลังติดตั้ง CHAIYA V2RAY PRO MAX v9..."
export DEBIAN_FRONTEND=noninteractive

# ── ล็อค / ล้าง dpkg ──────────────────────────────────────
systemctl stop unattended-upgrades 2>/dev/null
pkill -f needrestart 2>/dev/null
rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock 2>/dev/null
dpkg --configure -a 2>/dev/null

apt-get update -y -qq
apt-get install -y -qq curl wget python3 bc qrencode ufw nginx \
  certbot python3-certbot-nginx python3-pip fail2ban sqlite3 2>/dev/null || true

pip3 install bcrypt --break-system-packages -q 2>/dev/null

# ── หยุด service เก่า ──────────────────────────────────────
for svc in apache2 xray; do
  systemctl stop $svc 2>/dev/null; systemctl disable $svc 2>/dev/null
done
rm -f /etc/systemd/system/xray.service /usr/local/bin/xray
rm -rf /usr/local/etc/xray /var/log/xray
systemctl daemon-reload 2>/dev/null

# ── สร้าง directories / files ──────────────────────────────
mkdir -p /etc/chaiya /var/www/chaiya/config /var/log/nginx \
         /etc/chaiya/sshws-users
touch /etc/chaiya/vless.db /etc/chaiya/banned.db \
      /etc/chaiya/iplog.db /etc/chaiya/datalimit.conf \
      /etc/chaiya/iplimit_ban.json

echo "{}" > /etc/chaiya/iplimit_ban.json 2>/dev/null || true

# ── ตรวจจับ IP สาธารณะ ─────────────────────────────────────
MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
     || curl -s --max-time 5 api.ipify.org 2>/dev/null \
     || hostname -I | awk '{print $1}')

# ── UFW ────────────────────────────────────────────────────
ufw --force enable
for p in 22 80 443 8080 8880 2053 2082; do
  ufw allow $p/tcp 2>/dev/null
done

# ══════════════════════════════════════════════════════════
#  nginx config  (รองรับทั้ง HTTP และ HTTPS หลัง certbot)
# ══════════════════════════════════════════════════════════
cat > /etc/nginx/sites-available/chaiya << 'NGINXEOF'
server {
    listen 81;
    server_name _;
    root /var/www/chaiya;

    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
    }
    location /sshws/ {
        alias /var/www/chaiya/;
        index sshws.html;
        try_files $uri $uri/ =404;
    }
    location /sshws-api/ {
        proxy_pass http://127.0.0.1:6789/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    location /ssh-ws {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_set_header Host $host;
    }
    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable nginx && systemctl restart nginx

# ── websocat ───────────────────────────────────────────────
echo "✅ ติดตั้ง websocat..."
ARCH=$(uname -m)
WS_URL=""
[[ "$ARCH" == "x86_64"  ]] && WS_URL="https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl"
[[ "$ARCH" == "aarch64" ]] && WS_URL="https://github.com/vi/websocat/releases/latest/download/websocat.aarch64-unknown-linux-musl"
if [[ -n "$WS_URL" ]] && [[ ! -f /usr/local/bin/websocat ]]; then
  curl -sL "$WS_URL" -o /usr/local/bin/websocat 2>/dev/null && chmod +x /usr/local/bin/websocat
fi

# ── ws-ssh systemd (พอร์ต 80 — websocat ─► SSH 22) ────────
cat > /etc/systemd/system/chaiya-sshws.service << 'WSEOF'
[Unit]
Description=Chaiya SSH over WebSocket port 80
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/websocat --binary ws-l:0.0.0.0:80 tcp:127.0.0.1:22
Restart=always
RestartSec=3
StandardOutput=append:/var/log/chaiya-sshws.log
StandardError=append:/var/log/chaiya-sshws.log

[Install]
WantedBy=multi-user.target
WSEOF

# ── chaiya-sshws config ────────────────────────────────────
mkdir -p /etc/chaiya
cat > /etc/chaiya/sshws.conf << 'CONFEOF'
SSH_PORT=22
WS_PORT=80
DROPBEAR_PORT=2222
USE_DROPBEAR=0
ENABLED=1
CONFEOF

systemctl daemon-reload
systemctl enable chaiya-sshws
systemctl restart chaiya-sshws

# ══════════════════════════════════════════════════════════
#  chaiya-sshws-api  (Python HTTP API :6789)
# ══════════════════════════════════════════════════════════
echo "✅ ติดตั้ง chaiya-sshws-api..."
cat > /usr/local/bin/chaiya-sshws-api << 'PYEOF'
#!/usr/bin/env python3
"""Chaiya SSH-WS HTTP API — port 6789"""
import http.server, json, subprocess, os, sys, urllib.parse, hmac, hashlib, time

PORT  = 6789
HOST  = "127.0.0.1"
TOKEN_FILE  = "/etc/chaiya/sshws-token.conf"
BAN_FILE    = "/etc/chaiya/iplimit_ban.json"
USERS_DIR   = "/etc/chaiya/sshws-users"
CONF_FILE   = "/etc/chaiya/sshws.conf"

os.makedirs(USERS_DIR, exist_ok=True)

# ── Auto-generate token ────────────────────────────────────
def get_token():
    if os.path.exists(TOKEN_FILE):
        t = open(TOKEN_FILE).read().strip()
        if t: return t
    tok = hashlib.sha256(os.urandom(32)).hexdigest()[:32]
    with open(TOKEN_FILE, "w") as f: f.write(tok)
    return tok

TOKEN = get_token()

def run(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip(), r.returncode
    except Exception as e:
        return str(e), 1

def load_conf():
    d = {"SSH_PORT":"22","WS_PORT":"80","DROPBEAR_PORT":"2222","USE_DROPBEAR":"0","ENABLED":"1"}
    if os.path.exists(CONF_FILE):
        for line in open(CONF_FILE):
            if "=" in line:
                k,v=line.strip().split("=",1); d[k]=v
    return d

def save_conf(d):
    with open(CONF_FILE,"w") as f:
        for k,v in d.items(): f.write(f"{k}={v}\n")

def load_bans():
    try: return json.load(open(BAN_FILE))
    except: return {}

def save_bans(b):
    json.dump(b, open(BAN_FILE,"w"), indent=2, ensure_ascii=False)

def list_users():
    db = os.path.join(USERS_DIR, "users.db")
    result = []
    if not os.path.exists(db): return result
    for line in open(db):
        parts = line.strip().split()
        if len(parts) >= 3:
            user, days, exp = parts[0], parts[1], parts[2]
            data_gb = parts[3] if len(parts) > 3 else "0"
            import subprocess as sp
            active = sp.run(f"id {user}", shell=True, capture_output=True).returncode == 0
            result.append({"user":user,"days":int(days),"exp":exp,"active":active,"data_gb":int(data_gb)})
    return result

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",len(body))
        self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Headers","Authorization,Content-Type")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin","*")
        self.send_header("Access-Control-Allow-Methods","GET,POST,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers","Authorization,Content-Type")
        self.end_headers()

    def auth(self):
        t = self.headers.get("Authorization","").replace("Bearer ","").strip()
        return hmac.compare_digest(t, TOKEN)

    def read_body(self):
        n = int(self.headers.get("Content-Length",0))
        return json.loads(self.rfile.read(n)) if n else {}

    def do_GET(self):
        if not self.auth(): return self.send_json(401,{"error":"unauthorized"})
        p = urllib.parse.urlparse(self.path).path.rstrip("/")

        if p == "/api/status":
            cfg = load_conf()
            ws_on,_ = run("systemctl is-active chaiya-sshws")
            conns,_ = run(f"ss -tnp 2>/dev/null | grep -c ':{cfg['WS_PORT']}' 2>/dev/null || echo 0")
            return self.send_json(200,{
                "enabled": int(cfg.get("ENABLED","1")),
                "ws_status": "active" if ws_on=="active" else "inactive",
                "ws_port": int(cfg.get("WS_PORT",80)),
                "ssh_port": int(cfg.get("SSH_PORT",22)),
                "dropbear_port": int(cfg.get("DROPBEAR_PORT",2222)),
                "use_dropbear": int(cfg.get("USE_DROPBEAR",0)),
                "connections": int(conns) if conns.isdigit() else 0
            })

        elif p == "/api/users":
            return self.send_json(200, list_users())

        elif p == "/api/online":
            cfg = load_conf()
            out,_ = run(f"ss -tnp 2>/dev/null | grep ESTAB | grep ':{cfg['WS_PORT']} '")
            conns = []
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 5:
                    conns.append({"remote": parts[4], "state": parts[0]})
            return self.send_json(200, conns)

        elif p == "/api/banned":
            return self.send_json(200, load_bans())

        elif p == "/api/logs":
            out,_ = run("tail -n 60 /var/log/chaiya-sshws.log 2>/dev/null || echo ''")
            return self.send_json(200,{"lines": out.splitlines()})

        elif p == "/api/token":
            return self.send_json(200,{"token": TOKEN})

        else:
            return self.send_json(404,{"error":"not_found"})

    def do_POST(self):
        if not self.auth(): return self.send_json(401,{"error":"unauthorized"})
        p = urllib.parse.urlparse(self.path).path.rstrip("/")
        body = self.read_body()

        if p == "/api/start":
            out,code = run("systemctl start chaiya-sshws")
            cfg = load_conf(); cfg["ENABLED"]="1"; save_conf(cfg)
            return self.send_json(200,{"ok":code==0,"result":out})

        elif p == "/api/stop":
            out,code = run("systemctl stop chaiya-sshws")
            cfg = load_conf(); cfg["ENABLED"]="0"; save_conf(cfg)
            return self.send_json(200,{"ok":code==0,"result":out})

        elif p == "/api/config":
            cfg = load_conf()
            cfg["WS_PORT"]       = str(body.get("ws_port",80))
            cfg["SSH_PORT"]      = str(body.get("ssh_port",22))
            cfg["USE_DROPBEAR"]  = str(body.get("use_dropbear",0))
            cfg["DROPBEAR_PORT"] = str(body.get("dropbear_port",2222))
            save_conf(cfg)
            # Rewrite systemd unit
            target = f"127.0.0.1:{cfg['SSH_PORT']}"
            if cfg["USE_DROPBEAR"]=="1": target = f"127.0.0.1:{cfg['DROPBEAR_PORT']}"
            unit = f"""[Unit]
Description=Chaiya SSH over WebSocket port {cfg['WS_PORT']}
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/websocat --binary ws-l:0.0.0.0:{cfg['WS_PORT']} tcp:{target}
Restart=always
RestartSec=3
StandardOutput=append:/var/log/chaiya-sshws.log
StandardError=append:/var/log/chaiya-sshws.log

[Install]
WantedBy=multi-user.target
"""
            with open("/etc/systemd/system/chaiya-sshws.service","w") as f: f.write(unit)
            run("systemctl daemon-reload")
            if cfg.get("ENABLED","1")=="1":
                run("systemctl restart chaiya-sshws")
            return self.send_json(200,{"ok":True,"result":"config_saved"})

        elif p == "/api/users":
            user = body.get("user","").strip()
            pw   = body.get("password","").strip()
            days = int(body.get("days",30))
            data_gb = int(body.get("data_gb",0))
            if not user or not pw:
                return self.send_json(400,{"error":"user and password required"})
            exp = subprocess.check_output(f"date -d '+{days} days' +'%Y-%m-%d'",shell=True).decode().strip()
            # Create system user
            run(f"userdel -f {user} 2>/dev/null; useradd -M -s /bin/false -e {exp} {user}")
            run(f"echo '{user}:{pw}' | chpasswd")
            run(f"chage -E {exp} {user}")
            # Save to db
            db = os.path.join(USERS_DIR,"users.db")
            with open(db,"a") as f: f.write(f"{user} {days} {exp} {data_gb}\n")
            return self.send_json(200,{"ok":True,"result":f"user_created:{user}"})

        elif p == "/api/renew":
            # ต่ออายุ + เปลี่ยน data
            user    = body.get("user","").strip()
            days    = int(body.get("days",30))
            data_gb = int(body.get("data_gb",0))
            if not user: return self.send_json(400,{"error":"user required"})
            exp,_ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
            run(f"chage -E {exp} {user}")
            # Update db
            db = os.path.join(USERS_DIR,"users.db")
            lines = []
            if os.path.exists(db):
                for line in open(db):
                    p2 = line.strip().split()
                    if p2 and p2[0]==user:
                        lines.append(f"{user} {days} {exp} {data_gb}\n")
                    else:
                        lines.append(line)
            else:
                exp2,_ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
                lines.append(f"{user} {days} {exp2} {data_gb}\n")
            with open(db,"w") as f: f.writelines(lines)
            return self.send_json(200,{"ok":True,"result":f"renewed:{user} exp:{exp}"})

        elif p == "/api/unban":
            uid  = body.get("uid","")
            name = body.get("name","")
            bans = load_bans()
            if uid in bans: del bans[uid]
            save_bans(bans)
            # Re-enable system user
            run(f"usermod -e '' {name} 2>/dev/null || true")
            return self.send_json(200,{"ok":True})

        elif p == "/api/import":
            # Import users from JSON backup
            # body = {"users": [...]} หรือ [...] โดยตรง
            users_data = body.get("users", body) if isinstance(body, dict) else body
            if not isinstance(users_data, list):
                return self.send_json(400,{"error":"expected list of users"})
            created = []; updated = []; failed = []
            db = os.path.join(USERS_DIR,"users.db")
            # โหลด db เดิม
            existing = {}
            if os.path.exists(db):
                for line in open(db):
                    parts = line.strip().split()
                    if parts: existing[parts[0]] = line
            new_lines = dict(existing)
            import subprocess as sp
            for u in users_data:
                user    = str(u.get("user","")).strip()
                pw      = str(u.get("password","")).strip()
                days    = int(u.get("days", 30))
                data_gb = int(u.get("data_gb", 0))
                exp     = str(u.get("exp","")).strip()
                if not user: failed.append("(empty)"); continue
                try:
                    # คำนวณ exp ถ้าไม่มี
                    if not exp:
                        exp_out,_ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
                        exp = exp_out.strip()
                    # สร้าง / อัพเดต system user
                    user_exists = sp.run(f"id {user}", shell=True, capture_output=True).returncode == 0
                    if not user_exists:
                        run(f"useradd -M -s /bin/false -e {exp} {user}")
                        created.append(user)
                    else:
                        updated.append(user)
                    if pw:
                        run(f"echo '{user}:{pw}' | chpasswd")
                    run(f"chage -E {exp} {user}")
                    new_lines[user] = f"{user} {days} {exp} {data_gb}\n"
                except Exception as e:
                    failed.append(f"{user}:{e}")
            # เขียน db ใหม่ (ไม่สร้างไฟล์ซ้ำ)
            with open(db,"w") as f:
                f.writelines(new_lines.values())
            return self.send_json(200,{
                "ok":True,
                "created": created,
                "updated": updated,
                "failed":  failed,
                "total":   len(created)+len(updated)
            })

        else:
            return self.send_json(404,{"error":"not_found"})

    def do_DELETE(self):
        if not self.auth(): return self.send_json(401,{"error":"unauthorized"})
        p = urllib.parse.urlparse(self.path).path.rstrip("/").split("/")
        if len(p)==4 and p[2]=="users":
            user = p[3]
            run(f"userdel -f {user} 2>/dev/null")
            db = os.path.join(USERS_DIR,"users.db")
            if os.path.exists(db):
                lines = [l for l in open(db) if not l.startswith(user+" ")]
                with open(db,"w") as f: f.writelines(lines)
            return self.send_json(200,{"ok":True,"result":f"user_deleted:{user}"})
        return self.send_json(404,{"error":"not_found"})

if __name__ == "__main__":
    import subprocess
    if len(sys.argv) > 1 and sys.argv[1] == "install":
        unit = """[Unit]
Description=Chaiya SSH-WS API
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/chaiya-sshws-api
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
"""
        with open("/etc/systemd/system/chaiya-sshws-api.service","w") as f: f.write(unit)
        os.system("systemctl daemon-reload && systemctl enable chaiya-sshws-api && systemctl restart chaiya-sshws-api")
        print(f"✅ API installed | Token: {TOKEN}")
        sys.exit(0)
    server = http.server.HTTPServer((HOST, PORT), Handler)
    print(f"SSH-WS API :{ PORT} | Token: {TOKEN}")
    server.serve_forever()
PYEOF
chmod +x /usr/local/bin/chaiya-sshws-api

# ── auto-install API service ────────────────────────────────
python3 /usr/local/bin/chaiya-sshws-api install

# ── chaiya-iplimit (auto-ban >2 IP, 12h) ───────────────────
echo "✅ ติดตั้ง chaiya-iplimit..."
cat > /usr/local/bin/chaiya-iplimit << 'LIMITEOF'
#!/usr/bin/env python3
"""Auto-ban SSH users using >2 IPs simultaneously (12h ban)"""
import json, subprocess, os, re
from datetime import datetime, timedelta

CONF    = "/etc/chaiya/sshws.conf"
BAN     = "/etc/chaiya/iplimit_ban.json"
LOG     = "/var/log/auth.log"
LIMIT   = 2
BAN_HRS = 12

def load_bans():
    try: return json.load(open(BAN))
    except: return {}

def save_bans(b): json.dump(b, open(BAN,"w"), indent=2, ensure_ascii=False)

def get_users():
    db = "/etc/chaiya/sshws-users/users.db"
    if not os.path.exists(db): return []
    return [l.strip().split()[0] for l in open(db) if l.strip()]

now  = datetime.now()
bans = load_bans()

# ── Unban expired ──────────────────────────────────────────
for uid in list(bans.keys()):
    until = datetime.fromisoformat(bans[uid]["until"])
    if now >= until:
        name = bans[uid]["name"]
        subprocess.run(f"usermod -e '' {name} 2>/dev/null || true", shell=True)
        print(f"🔓 Unban: {name}")
        del bans[uid]

# ── Check IPs ─────────────────────────────────────────────
users = get_users()
for user in users:
    if any(b["name"]==user for b in bans.values()): continue
    try:
        out = subprocess.check_output(
            f"grep 'Accepted.*{user}' {LOG} 2>/dev/null | tail -200",
            shell=True, text=True)
        ips = set()
        for line in out.splitlines():
            m = re.search(r'from (\S+) port', line)
            if m: ips.add(m.group(1))
        if len(ips) > LIMIT:
            until = now + timedelta(hours=BAN_HRS)
            subprocess.run(f"usermod -e 1 {user} 2>/dev/null || true", shell=True)
            uid = f"{user}_{int(now.timestamp())}"
            bans[uid] = {"name":user,"until":until.isoformat(),"ips":list(ips)}
            print(f"🔨 Ban: {user} ({len(ips)} IPs) until {until.strftime('%Y-%m-%d %H:%M')}")
    except: pass

save_bans(bans)
print(f"✔ iplimit check done | banned: {len(bans)}")
LIMITEOF
chmod +x /usr/local/bin/chaiya-iplimit

# ── cron: iplimit ทุก 5 นาที ──────────────────────────────
(crontab -l 2>/dev/null | grep -v chaiya-iplimit
 echo "*/5 * * * * python3 /usr/local/bin/chaiya-iplimit >> /var/log/chaiya-iplimit.log 2>&1"
) | crontab -

# ══════════════════════════════════════════════════════════
#  สร้าง sshws.html  (ดึงโดเมน/IP อัตโนมัติ)
# ══════════════════════════════════════════════════════════
echo "✅ สร้าง sshws.html..."

# ดึง token อัตโนมัติ
SSHWS_TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null || echo "")
# ดึงโดเมนอัตโนมัติ
SSHWS_HOST=""
[[ -f /etc/chaiya/domain.conf ]] && SSHWS_HOST=$(cat /etc/chaiya/domain.conf)
[[ -z "$SSHWS_HOST" ]] && SSHWS_HOST="$MY_IP"
# Protocol
SSHWS_PROTO="http"
[[ -f /etc/letsencrypt/live/$(cat /etc/chaiya/domain.conf 2>/dev/null)/fullchain.pem ]] && SSHWS_PROTO="https"

python3 - << PYGENEOF
import json, os

token = "$SSHWS_TOKEN"
host  = "$SSHWS_HOST"
proto = "$SSHWS_PROTO"

html = r"""<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CHAIYA SSH-WS</title>
<link href="https://fonts.googleapis.com/css2?family=Orbitron:wght@400;700;900&family=Saira+Condensed:wght@300;400;600;700&display=swap" rel="stylesheet">
<style>
:root{--bg:#020408;--bg2:#060d14;--bg3:#0a1520;--border:#0f2030;--border2:#1a3a55;--mono:'Orbitron',monospace;--sans:'Saira Condensed',sans-serif}
*{box-sizing:border-box;margin:0;padding:0}
@keyframes rgb-fire{0%{color:#ff0040;text-shadow:0 0 10px #ff0040,0 0 30px #ff0040}14%{color:#ff6600;text-shadow:0 0 10px #ff6600,0 0 30px #ff6600}28%{color:#ffff00;text-shadow:0 0 10px #ffff00,0 0 30px #ffff00}42%{color:#00ff88;text-shadow:0 0 10px #00ff88,0 0 30px #00ff88}57%{color:#00e5ff;text-shadow:0 0 10px #00e5ff,0 0 30px #00e5ff}71%{color:#8800ff;text-shadow:0 0 10px #8800ff,0 0 30px #8800ff}85%{color:#ff00cc;text-shadow:0 0 10px #ff00cc,0 0 30px #ff00cc}100%{color:#ff0040;text-shadow:0 0 10px #ff0040,0 0 30px #ff0040}}
@keyframes rgb-border{0%{border-color:#ff0040;box-shadow:0 0 15px #ff004044}25%{border-color:#00ff88;box-shadow:0 0 15px #00ff8844}50%{border-color:#00e5ff;box-shadow:0 0 15px #00e5ff44}75%{border-color:#8800ff;box-shadow:0 0 15px #8800ff44}100%{border-color:#ff0040;box-shadow:0 0 15px #ff004044}}
@keyframes rgb-bg{0%{background:linear-gradient(135deg,#ff004011,transparent)}25%{background:linear-gradient(135deg,#00ff8811,transparent)}50%{background:linear-gradient(135deg,#00e5ff11,transparent)}75%{background:linear-gradient(135deg,#8800ff11,transparent)}100%{background:linear-gradient(135deg,#ff004011,transparent)}}
@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.4;transform:scale(1.4)}}
@keyframes scan{0%{transform:translateY(-100%)}100%{transform:translateY(100vh)}}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
body{background:var(--bg);color:#c8dde8;font-family:var(--sans);font-size:14px;min-height:100vh;overflow-x:hidden;background-image:repeating-linear-gradient(0deg,transparent,transparent 39px,rgba(0,229,255,.025) 39px,rgba(0,229,255,.025) 40px),repeating-linear-gradient(90deg,transparent,transparent 39px,rgba(0,229,255,.025) 39px,rgba(0,229,255,.025) 40px)}
body::before{content:'';position:fixed;inset:0;pointer-events:none;z-index:999;background:repeating-linear-gradient(0deg,transparent,transparent 3px,rgba(0,0,0,.05) 3px,rgba(0,0,0,.05) 4px)}
body::after{content:'';position:fixed;left:0;top:-100%;width:100%;height:3px;background:linear-gradient(90deg,transparent,rgba(0,229,255,.5),transparent);animation:scan 4s linear infinite;pointer-events:none;z-index:998}
.wrap{max-width:980px;margin:0 auto;padding:16px 14px 60px;position:relative;z-index:1}
.rgb{animation:rgb-fire 2s linear infinite}
.rgb2{animation:rgb-fire 2s linear infinite;animation-delay:.5s}
.rgb-bd{animation:rgb-border 2s linear infinite}
.rgb-bg{animation:rgb-bg 3s linear infinite}
/* TOKEN */
.tok-bar{display:flex;align-items:center;gap:8px;background:var(--bg2);padding:9px 12px;border:1px solid;margin-bottom:18px;animation:rgb-border 2s linear infinite}
.tok-bar label{font-family:var(--mono);font-size:8px;color:#3d5a73;letter-spacing:2px;white-space:nowrap}
.tok-bar input{flex:1;background:transparent;border:none;outline:none;font-family:var(--mono);font-size:11px;color:#00e5ff}
/* HEADER */
header{display:flex;align-items:center;gap:14px;padding-bottom:16px;margin-bottom:18px;border-bottom:1px solid #0f2030}
.logo{width:54px;height:54px;flex-shrink:0;display:grid;place-items:center;font-family:var(--mono);font-size:10px;text-align:center;line-height:1.3;border:2px solid;animation:rgb-border 2s linear infinite;position:relative}
.logo::before{content:'';position:absolute;inset:4px;border:1px solid rgba(0,229,255,.15)}
.h1{font-family:var(--mono);font-size:clamp(18px,5vw,28px);font-weight:900;letter-spacing:5px;text-transform:uppercase;animation:rgb-fire 2s linear infinite;line-height:1}
.hsub{font-family:var(--mono);font-size:9px;letter-spacing:2px;color:#3d5a73;margin-top:3px}
.hstat{margin-left:auto;display:flex;align-items:center;gap:7px;font-family:var(--mono);font-size:10px}
.dot{width:8px;height:8px;border-radius:50%}
.dot.on{background:#00ff88;box-shadow:0 0 10px #00ff88;animation:pulse 1.5s infinite}
.dot.off{background:#ff2255}
/* STATS */
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}
.stat{background:var(--bg2);border:1px solid var(--border);padding:12px 14px;animation:rgb-bg 3s linear infinite;overflow:hidden;position:relative}
.slbl{font-family:var(--mono);font-size:8px;color:#3d5a73;letter-spacing:2px;text-transform:uppercase;margin-bottom:5px}
.sval{font-family:var(--mono);font-size:22px;font-weight:900;line-height:1;animation:rgb-fire 2s linear infinite}
.ssub{font-family:var(--mono);font-size:9px;color:#3d5a73;margin-top:3px}
/* GRID */
.g2{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
/* CARD */
.card{background:var(--bg2);border:1px solid var(--border);overflow:hidden;margin-bottom:12px}
.ch{padding:9px 14px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:8px}
.ch h2{font-family:var(--mono);font-size:9px;font-weight:500;letter-spacing:2px;text-transform:uppercase;animation:rgb-fire 2s linear infinite}
.ch .bge{margin-left:auto;font-family:var(--mono);font-size:8px;padding:2px 7px;border:1px solid;letter-spacing:1px}
.bge.on{border-color:#00ff88;color:#00ff88}.bge.off{border-color:#ff2255;color:#ff2255}
.cb{padding:14px}
/* TOGGLE */
.twrap{display:flex;flex-direction:column;align-items:center;gap:12px;padding:18px 14px}
.tbtn{width:70px;height:70px;border-radius:50%;border:2px solid;background:var(--bg3);cursor:pointer;display:grid;place-items:center;font-size:20px;transition:all .3s;animation:rgb-border 2s linear infinite}
.tbtn:hover{transform:scale(1.05)}.tbtn.on{box-shadow:0 0 25px rgba(0,255,136,.25)}.tbtn.off{box-shadow:0 0 15px rgba(255,34,85,.2)}
.tlbl{font-family:var(--mono);font-size:9px;letter-spacing:2px;animation:rgb-fire 2s linear infinite}
.brow{display:flex;gap:8px}
/* FIELD */
.fi{margin-bottom:10px}
.fi label{display:block;font-family:var(--mono);font-size:8px;color:#3d5a73;letter-spacing:1px;text-transform:uppercase;margin-bottom:4px}
.fi input,.fi select{width:100%;padding:7px 9px;background:var(--bg3);border:1px solid var(--border);color:#c8dde8;font-family:var(--mono);font-size:11px;outline:none;transition:border-color .2s;appearance:none}
.fi input:focus,.fi select:focus{border-color:#00e5ff}
.fg2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
/* BUTTONS */
.btn{padding:7px 13px;border:none;cursor:pointer;font-family:var(--sans);font-size:12px;font-weight:600;letter-spacing:1px;text-transform:uppercase;transition:all .2s;display:inline-flex;align-items:center;gap:5px}
.btn-r{background:var(--bg3);border:1px solid;animation:rgb-border 2s linear infinite;color:#fff}
.btn-r:hover{filter:brightness(1.2)}
.btn-g{background:#00aa55;color:#fff}.btn-g:hover{filter:brightness(1.15)}
.btn-d{background:#ff2255;color:#fff}.btn-d:hover{filter:brightness(1.15)}
.btn-y{background:#cc8800;color:#fff}.btn-y:hover{filter:brightness(1.15)}
.sm{padding:4px 10px;font-size:10px}.xs{padding:2px 7px;font-size:9px}
.btn:disabled{opacity:.4;cursor:not-allowed}
/* SEC TITLE */
.stit{font-family:var(--mono);font-size:8px;letter-spacing:3px;text-transform:uppercase;display:flex;align-items:center;gap:10px;margin-bottom:10px;animation:rgb-fire 2s linear infinite}
.stit::after{content:'';flex:1;height:1px;background:var(--border);animation:none}
/* TABS */
.tabs{display:flex;border-bottom:1px solid var(--border)}
.tab{padding:8px 13px;font-family:var(--mono);font-size:9px;letter-spacing:1px;text-transform:uppercase;cursor:pointer;border:none;background:transparent;color:#3d5a73;transition:all .2s;border-bottom:2px solid transparent;margin-bottom:-1px}
.tab.active{color:#fff;border-bottom-color:#00e5ff;animation:rgb-fire 2s linear infinite}
.tc{display:none;padding:14px}.tc.active{display:block;animation:fadeUp .2s ease}
/* TABLE */
.tw{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-family:var(--mono);font-size:11px}
thead tr{border-bottom:1px solid var(--border2)}
th{padding:6px 8px;text-align:left;color:#3d5a73;font-weight:400;font-size:8px;letter-spacing:1px;text-transform:uppercase}
tbody tr{border-bottom:1px solid var(--border);transition:background .15s}
tbody tr:hover{background:rgba(0,229,255,.04)}
td{padding:8px 8px}
/* PILL */
.p{display:inline-block;padding:1px 6px;font-family:var(--mono);font-size:8px}
.pg{background:rgba(0,255,136,.1);color:#00ff88;border:1px solid rgba(0,255,136,.2)}
.pr{background:rgba(255,34,85,.1);color:#ff2255;border:1px solid rgba(255,34,85,.2)}
.py{background:rgba(255,215,0,.1);color:#ffd700;border:1px solid rgba(255,215,0,.2)}
.pd{background:rgba(61,90,115,.2);color:#3d5a73;border:1px solid var(--border)}
/* LOG */
.logbox{background:#030608;border:1px solid var(--border);padding:10px 12px;height:140px;overflow-y:auto;font-family:var(--mono);font-size:10px;color:#2a5a40;line-height:1.7}
.le{color:#ff2255}.lok{color:#00ff88}.lw{color:#ffd700}
/* CONFIG HINT */
.chint{background:#030608;border:1px solid var(--border);padding:10px 12px;font-family:var(--mono);font-size:10px;line-height:2;color:#00e5ff}
/* TOAST */
#toast{position:fixed;bottom:20px;right:16px;padding:8px 16px;font-family:var(--mono);font-size:10px;border:1px solid;background:var(--bg2);transform:translateX(140%);transition:transform .3s;z-index:10000;max-width:300px;animation:rgb-border 2s linear infinite}
#toast.show{transform:translateX(0)}
/* MODAL */
.mo{position:fixed;inset:0;background:rgba(0,0,0,.85);display:none;place-items:center;z-index:5000}
.mo.open{display:grid}
.md{background:var(--bg2);border:1px solid;animation:rgb-border 2s linear infinite;padding:20px;width:min(90vw,380px)}
.md h3{font-family:var(--mono);font-size:10px;letter-spacing:2px;margin-bottom:14px;animation:rgb-fire 2s linear infinite}
.mbtns{display:flex;gap:8px;margin-top:14px;justify-content:flex-end}
hr.dv{border:none;border-top:1px solid var(--border);margin:10px 0}
.empty{text-align:center;padding:20px;color:#3d5a73;font-family:var(--mono);font-size:10px}
.spin{display:inline-block;animation:spin .6s linear infinite}
@media(max-width:600px){.g2,.stats,.fg2{grid-template-columns:1fr}.h1{font-size:18px;letter-spacing:3px}}
</style>
</head>
<body>
<div class="wrap">

<!-- TOKEN BAR (auto-filled) -->
<div class="tok-bar rgb-bd">
  <label>API TOKEN</label>
  <input type="password" id="api-token" placeholder="Token จะถูกกรอกอัตโนมัติ" autocomplete="off">
  <button class="btn btn-r xs" onclick="toggleTok()">👁</button>
  <button class="btn btn-r xs" onclick="loadAll()">▶ เชื่อมต่อ</button>
</div>

<!-- HEADER -->
<header>
  <div class="logo rgb-bd"><span class="rgb">SSH<br>WS</span></div>
  <div>
    <div class="h1">CHAIYA <span class="rgb2">SSH‑WS</span></div>
    <div class="hsub" id="hd-sub">// ws-port: — | connections: —</div>
  </div>
  <div class="hstat">
    <div class="dot" id="g-dot"></div>
    <span id="g-label" style="color:#3d5a73">—</span>
  </div>
</header>

<!-- STATS -->
<div class="stats">
  <div class="stat rgb-bg">
    <div class="slbl">WebSocket</div>
    <div class="sval rgb" id="ws-status">—</div>
    <div class="ssub" id="ws-port-sub">port —</div>
  </div>
  <div class="stat rgb-bg">
    <div class="slbl">Connections</div>
    <div class="sval rgb" id="conn-count">—</div>
    <div class="ssub">active sessions</div>
  </div>
  <div class="stat rgb-bg">
    <div class="slbl">SSH Users</div>
    <div class="sval rgb" id="user-count">—</div>
    <div class="ssub" id="backend-sub">openssh :22</div>
  </div>
</div>

<!-- CONTROL + CONFIG -->
<div class="g2">
  <div class="card">
    <div class="ch"><span>⚡</span><h2>CONTROL</h2><span class="bge" id="svc-badge">—</span></div>
    <div class="twrap">
      <button class="tbtn rgb-bd" id="toggle-btn" onclick="toggleService()">
        <span id="toggle-icon">⊙</span>
      </button>
      <span class="tlbl" id="toggle-lbl">LOADING...</span>
      <div class="brow">
        <button class="btn btn-r sm" onclick="loadAll()">↺ Refresh</button>
        <button class="btn btn-r sm" onclick="switchTab('tab-logs',document.querySelectorAll('.tab')[3])">📋 Logs</button>
      </div>
    </div>
  </div>
  <div class="card">
    <div class="ch"><span>⚙</span><h2>CONFIGURATION</h2></div>
    <div class="cb">
      <div class="fg2">
        <div class="fi"><label>WS Port</label><input type="number" id="cfg-ws" value="80" min="1" max="65535"></div>
        <div class="fi"><label>SSH Port</label><input type="number" id="cfg-ssh" value="22" min="1" max="65535"></div>
      </div>
      <div class="fi">
        <label>Backend Mode</label>
        <select id="cfg-backend" onchange="onBEChange()">
          <option value="0">OpenSSH (port 22)</option>
          <option value="1">Dropbear (root login)</option>
        </select>
      </div>
      <div class="fi" id="db-port-f" style="display:none">
        <label>Dropbear Port</label>
        <input type="number" id="cfg-db-port" value="2222" min="1" max="65535">
      </div>
      <button class="btn btn-r sm" onclick="saveCfg()">💾 บันทึก Config</button>
    </div>
  </div>
</div>

<!-- USERS PANEL -->
<div class="stit">จัดการ SSH Users</div>
<div class="card">
  <div class="tabs">
    <button class="tab active" onclick="switchTab('tab-users',this)">👤 Users</button>
    <button class="tab" onclick="switchTab('tab-online',this)">🟢 Online</button>
    <button class="tab" onclick="switchTab('tab-banned',this)">🚫 Banned</button>
    <button class="tab" onclick="switchTab('tab-logs',this)">📋 Logs</button>
    <button class="tab" onclick="switchTab('tab-backup',this)">💾 Backup/Import</button>
  </div>

  <!-- TAB USERS -->
  <div class="tc active" id="tab-users">
    <div class="fg2" style="margin-bottom:8px">
      <div class="fi" style="margin:0"><label>Username</label><input type="text" id="nu" placeholder="chaiya_user1"></div>
      <div class="fi" style="margin:0"><label>Password</label><input type="password" id="np" placeholder="••••••••"></div>
    </div>
    <div style="display:flex;gap:8px;align-items:flex-end;margin-bottom:12px">
      <div class="fi" style="margin:0;flex:1"><label>วัน</label><input type="number" id="nd" value="30" min="1" max="3650"></div>
      <div class="fi" style="margin:0;flex:1"><label>Data GB (0=∞)</label><input type="number" id="ngb" value="0" min="0"></div>
      <button class="btn btn-r sm" onclick="addUser()">＋ เพิ่ม</button>
    </div>
    <hr class="dv">
    <div class="tw">
      <table>
        <thead><tr><th>Username</th><th>หมดอายุ</th><th>Data GB</th><th>สถานะ</th><th>Actions</th></tr></thead>
        <tbody id="utb"><tr><td colspan="5" class="empty"><span class="spin">⟳</span> โหลด...</td></tr></tbody>
      </table>
    </div>
  </div>

  <!-- TAB ONLINE -->
  <div class="tc" id="tab-online">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
      <span style="font-family:var(--mono);font-size:9px;color:#3d5a73">AUTO REFRESH 8s</span>
      <button class="btn btn-r xs" onclick="loadOnline()">↺</button>
    </div>
    <div class="tw">
      <table>
        <thead><tr><th>Remote IP</th><th>State</th></tr></thead>
        <tbody id="otb"><tr><td colspan="2" class="empty">ไม่มี connection</td></tr></tbody>
      </table>
    </div>
  </div>

  <!-- TAB BANNED -->
  <div class="tc" id="tab-banned">
    <p style="font-family:var(--mono);font-size:9px;color:#3d5a73;margin-bottom:10px">⚠ ใช้เกิน 2 IP → แบนอัตโนมัติ 12 ชั่วโมง</p>
    <div class="tw">
      <table>
        <thead><tr><th>Username</th><th>แบนถึง</th><th>IPs</th><th>Action</th></tr></thead>
        <tbody id="btb"><tr><td colspan="4" class="empty">ไม่มี account ถูกแบน ✔</td></tr></tbody>
      </table>
    </div>
  </div>

  <!-- TAB LOGS -->
  <div class="tc" id="tab-logs">
    <div style="display:flex;justify-content:flex-end;margin-bottom:8px">
      <button class="btn btn-r xs" onclick="loadLogs()">↺ Refresh</button>
    </div>
    <div class="logbox" id="logbox"><span style="color:#3d5a73">// กด Refresh</span></div>
  </div>

  <!-- TAB BACKUP/IMPORT -->
  <div class="tc" id="tab-backup">
    <div style="font-family:var(--mono);font-size:8px;letter-spacing:2px;margin-bottom:12px;animation:rgb-fire 2s linear infinite">
      // BACKUP &amp; IMPORT — ส่งออก/นำเข้าข้อมูล users ทั้งหมด
    </div>

    <!-- BACKUP SECTION -->
    <div style="margin-bottom:16px">
      <div style="font-family:var(--mono);font-size:8px;color:#3d5a73;letter-spacing:2px;margin-bottom:7px;text-transform:uppercase">▸ Backup Users</div>
      <div style="display:flex;gap:7px;margin-bottom:8px">
        <button class="btn btn-r sm" onclick="doBackup()" style="flex:1">
          📥 Backup ดึงข้อมูล
        </button>
        <button class="btn btn-r sm" onclick="copyBackup()" id="btn-copy-bk" disabled>
          📋 Copy JSON
        </button>
      </div>
      <textarea id="bk-output" readonly
        placeholder="// กด Backup เพื่อดึงข้อมูล users ทั้งหมด..."
        style="width:100%;height:130px;background:#030608;border:1px solid;
               animation:rgb-border 2s linear infinite;
               color:#00e5ff;font-family:var(--mono);font-size:10px;
               padding:9px;resize:vertical;outline:none;line-height:1.6">
      </textarea>
    </div>

    <hr class="dv">

    <!-- IMPORT SECTION -->
    <div>
      <div style="font-family:var(--mono);font-size:8px;color:#3d5a73;letter-spacing:2px;margin-bottom:7px;text-transform:uppercase">▸ Import Users</div>
      <div style="font-family:var(--mono);font-size:9px;color:#ffd700;margin-bottom:8px;line-height:1.7">
        ⚠ วาง JSON (array) ลงช่องด้านล่าง แล้วกด Import<br>
        <span style="color:#3d5a73">// ระบบจะสร้าง/อัพเดต users อัตโนมัติ ไม่สร้างซ้ำ</span>
      </div>
      <textarea id="imp-input"
        placeholder='[{"user":"alice","password":"pass123","days":30,"data_gb":0},...]'
        style="width:100%;height:130px;background:#030608;border:1px solid;
               animation:rgb-border 2s linear infinite;
               color:#c8dde8;font-family:var(--mono);font-size:10px;
               padding:9px;resize:vertical;outline:none;line-height:1.6">
      </textarea>
      <div style="display:flex;gap:7px;margin-top:8px">
        <button class="btn btn-g sm" onclick="doImport()" style="flex:2">
          📤 Import เพิ่ม/อัพเดต Users
        </button>
        <button class="btn btn-d sm" onclick="$('imp-input').value=''" style="flex:1">
          🗑 Clear
        </button>
      </div>
      <div id="imp-result" style="font-family:var(--mono);font-size:10px;
           margin-top:8px;padding:8px;background:#030608;border:1px solid var(--border);
           display:none;line-height:1.8"></div>
    </div>
  </div>
</div>

<!-- CONFIG STRING -->
<div class="stit" style="margin-top:6px">Config String</div>
<div class="card">
  <div class="cb">
    <div class="chint" id="cfg-hint">// โหลด...</div>
    <p style="font-family:var(--mono);font-size:9px;color:#3d5a73;margin-top:6px">// HTTP Injector / NapsternetV / SocksHttp</p>
  </div>
</div>

</div>

<div id="toast"></div>

<!-- MODAL: ต่ออายุ/เพิ่มData -->
<div class="mo" id="m-renew">
  <div class="md">
    <h3>🔄 ต่ออายุ + แก้ไข Data</h3>
    <div class="fi"><label>Username</label><input type="text" id="rn-user" readonly style="color:#00e5ff"></div>
    <div class="fg2">
      <div class="fi"><label>เพิ่มวัน</label><input type="number" id="rn-days" value="30" min="1" max="3650"></div>
      <div class="fi"><label>Data GB (0=∞)</label><input type="number" id="rn-gb" value="0" min="0"></div>
    </div>
    <div class="mbtns">
      <button class="btn btn-r sm" onclick="closeM('m-renew')">ยกเลิก</button>
      <button class="btn btn-g sm" onclick="confirmRenew()">✔ ต่ออายุ</button>
    </div>
  </div>
</div>

<!-- MODAL: ลบ -->
<div class="mo" id="m-del">
  <div class="md">
    <h3>⚠ ลบ User</h3>
    <p style="font-family:var(--mono);font-size:11px;margin-bottom:10px">
      ยืนยันลบ <span id="del-user" class="rgb" style="font-weight:900"></span> ?
    </p>
    <div class="mbtns">
      <button class="btn btn-r sm" onclick="closeM('m-del')">ยกเลิก</button>
      <button class="btn btn-d sm" onclick="confirmDel()">✕ ลบ</button>
    </div>
  </div>
</div>

<script>
/* ── AUTO CONFIG (injected at install time) ── */
const AUTO_TOKEN = "%%TOKEN%%";
const AUTO_HOST  = "%%HOST%%";
const AUTO_PROTO = "%%PROTO%%";

const API = window.location.origin + '/sshws-api';
let svcOn=false, autoRef=null, delTarget='';
const $=id=>document.getElementById(id);

/* INIT token */
window.addEventListener('load',()=>{
  const saved=localStorage.getItem('chaiya_tok');
  if(AUTO_TOKEN && AUTO_TOKEN!=='%%TOKEN%%') {
    $('api-token').value=AUTO_TOKEN;
    localStorage.setItem('chaiya_tok',AUTO_TOKEN);
  } else if(saved) {
    $('api-token').value=saved;
  }
  $('api-token').addEventListener('change',()=>{localStorage.setItem('chaiya_tok',tok());});
  $('api-token').addEventListener('keydown',e=>{if(e.key==='Enter')loadAll();});
  if(tok()) loadAll();
  startAuto();
});

function tok(){ return $('api-token').value.trim(); }
function toggleTok(){ const e=$('api-token'); e.type=e.type==='password'?'text':'password'; }

function toast(msg,err=false){
  const t=$('toast'); t.textContent=msg;
  t.className='show'+(err?' err':'');
  clearTimeout(t._t); t._t=setTimeout(()=>t.className='',2800);
}

async function api(method,path,body=null){
  const o={method,headers:{'Authorization':'Bearer '+tok(),'Content-Type':'application/json'}};
  if(body) o.body=JSON.stringify(body);
  try{ const r=await fetch(API+path,o); return await r.json(); }
  catch(e){ return {error:e.message}; }
}

/* TABS */
function switchTab(id,el){
  document.querySelectorAll('.tc').forEach(t=>t.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));
  $(id).classList.add('active'); el.classList.add('active');
  if(id==='tab-online') loadOnline();
  if(id==='tab-banned') loadBanned();
  if(id==='tab-logs')   loadLogs();
  if(id==='tab-backup') resetBackup();
}

/* STATUS */
async function loadStatus(){
  const d=await api('GET','/api/status');
  if(d.error){toast('API Error: '+d.error,true);return;}
  const on=d.ws_status==='active'; svcOn=on;
  $('g-dot').className='dot '+(on?'on':'off');
  $('g-label').textContent=on?'ONLINE':'OFFLINE';
  $('g-label').style.color=on?'#00ff88':'#ff2255';
  $('hd-sub').textContent=`// ws-port: ${d.ws_port??'—'}  |  connections: ${d.connections??0}`;
  $('ws-status').textContent=on?'RUNNING':'STOPPED';
  $('ws-port-sub').textContent=`port ${d.ws_port??'—'}`;
  $('conn-count').textContent=d.connections??0;
  $('backend-sub').textContent=d.use_dropbear?`dropbear :${d.dropbear_port}`:`openssh :${d.ssh_port}`;
  const btn=$('toggle-btn'); btn.className='tbtn rgb-bd '+(on?'on':'off');
  $('toggle-icon').textContent=on?'⏻':'⊙';
  $('toggle-lbl').textContent=on?'SERVICE RUNNING':'SERVICE STOPPED';
  const bg=$('svc-badge'); bg.textContent=on?'ACTIVE':'INACTIVE';
  bg.className='bge '+(on?'on':'off');
  $('cfg-ws').value=d.ws_port||80;
  $('cfg-ssh').value=d.ssh_port||22;
  $('cfg-backend').value=d.use_dropbear||0;
  $('cfg-db-port').value=d.dropbear_port||2222;
  onBEChange();
  const h=AUTO_HOST!=='%%HOST%%'?AUTO_HOST:window.location.hostname;
  const pr=AUTO_PROTO!=='%%PROTO%%'?AUTO_PROTO:window.location.protocol.replace(':','');
  $('cfg-hint').innerHTML=`<span style="color:#3d5a73">Host&nbsp;&nbsp;&nbsp;:</span> ${h}<br><span style="color:#3d5a73">WS Port:</span> <b style="color:#fff">${d.ws_port??'—'}</b><br><span style="color:#3d5a73">Payload:</span> GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]<br><span style="color:#3d5a73">Backend:</span> ${d.use_dropbear?'Dropbear SSH':'OpenSSH'} over WebSocket`;
}

/* USERS */
async function loadUsers(){
  const users=await api('GET','/api/users');
  const tb=$('utb');
  if(users.error){toast('โหลด users ไม่ได้',true);return;}
  $('user-count').textContent=Array.isArray(users)?users.length:'?';
  if(!Array.isArray(users)||users.length===0){
    tb.innerHTML='<tr><td colspan="5" class="empty">ไม่มี SSH users</td></tr>'; return;
  }
  tb.innerHTML=users.map(u=>{
    const exp=new Date(u.exp); const now=new Date();
    const dLeft=Math.ceil((exp-now)/86400000);
    const pill=u.active&&dLeft>0?'<span class="p pg">ACTIVE</span>':'<span class="p pr">EXPIRED</span>';
    const expTxt=u.exp+`<span style="color:#3d5a73;font-size:9px"> (${dLeft>0?dLeft+'d':'หมด'})</span>`;
    const dataStr=u.data_gb>0?u.data_gb+'GB':'∞';
    return `<tr>
      <td style="color:#fff;font-weight:700">${u.user}</td>
      <td>${expTxt}</td>
      <td style="color:#00e5ff">${dataStr}</td>
      <td>${pill}</td>
      <td style="display:flex;gap:3px;flex-wrap:wrap">
        <button class="btn btn-y xs" onclick="openRenew('${u.user}',${u.days},${u.data_gb})">🔄</button>
        <button class="btn btn-d xs" onclick="openDel('${u.user}')">✕</button>
      </td>
    </tr>`;
  }).join('');
}

async function addUser(){
  const user=$('nu').value.trim(), pass=$('np').value.trim();
  const days=parseInt($('nd').value)||30, gb=parseInt($('ngb').value)||0;
  if(!user||!pass){toast('ใส่ username และ password',true);return;}
  const r=await api('POST','/api/users',{user,password:pass,days,data_gb:gb});
  if(r.ok){toast(`✔ เพิ่ม "${user}" แล้ว`);$('nu').value='';$('np').value='';loadUsers();}
  else toast('เพิ่มไม่ได้: '+(r.result||r.error),true);
}

/* RENEW MODAL */
function openRenew(user,days,gb){
  $('rn-user').value=user; $('rn-days').value=days||30; $('rn-gb').value=gb||0;
  $('m-renew').classList.add('open');
}
async function confirmRenew(){
  const user=$('rn-user').value, days=parseInt($('rn-days').value)||30, gb=parseInt($('rn-gb').value)||0;
  const r=await api('POST','/api/renew',{user,days,data_gb:gb});
  closeM('m-renew');
  if(r.ok){toast(`✔ ต่ออายุ "${user}" ${days}วัน | Data: ${gb||'∞'}GB`);loadUsers();}
  else toast('ต่ออายุไม่ได้: '+(r.result||r.error),true);
}

/* DELETE MODAL */
function openDel(user){delTarget=user; $('del-user').textContent=user; $('m-del').classList.add('open');}
async function confirmDel(){
  const r=await api('DELETE',`/api/users/${delTarget}`);
  closeM('m-del');
  if(r.ok){toast(`✔ ลบ "${delTarget}" แล้ว`);loadUsers();}
  else toast('ลบไม่ได้: '+(r.result||r.error),true);
}

function closeM(id){$(id).classList.remove('open');}

/* ONLINE */
async function loadOnline(){
  const data=await api('GET','/api/online');
  const tb=$('otb');
  if(!Array.isArray(data)||data.length===0){
    tb.innerHTML='<tr><td colspan="2" class="empty">ไม่มี connection</td></tr>';
    $('conn-count').textContent=0; return;
  }
  $('conn-count').textContent=data.length;
  tb.innerHTML=data.map(c=>`<tr><td style="color:#00e5ff">${c.remote}</td><td><span class="p pg">${c.state}</span></td></tr>`).join('');
}

/* BANNED */
async function loadBanned(){
  const bans=await api('GET','/api/banned');
  const tb=$('btb');
  const keys=Object.keys(bans||{});
  if(keys.length===0){tb.innerHTML='<tr><td colspan="4" class="empty">ไม่มี account ถูกแบน ✔</td></tr>';return;}
  tb.innerHTML=keys.map(uid=>{
    const b=bans[uid];
    const until=new Date(b.until).toLocaleString('th-TH');
    const ips=(b.ips||[]).slice(0,3).join(', ')+(b.ips&&b.ips.length>3?'...':'');
    return `<tr>
      <td style="color:#ff2255;font-weight:700">${b.name}</td>
      <td><span class="p pr">${until}</span></td>
      <td style="font-size:9px;color:#3d5a73">${ips||'—'}</td>
      <td><button class="btn btn-g xs" onclick="unban('${uid}','${b.name}')">🔓 ปลด</button></td>
    </tr>`;
  }).join('');
}

async function unban(uid,name){
  const r=await api('POST','/api/unban',{uid,name});
  if(r.ok){toast(`🔓 ปลดแบน ${name} แล้ว`);loadBanned();}
  else toast('ปลดแบนไม่ได้: '+(r.error||''),true);
}

/* LOGS */
async function loadLogs(){
  const r=await api('GET','/api/logs');
  const box=$('logbox');
  if(!r.lines||r.lines.length===0){box.innerHTML='<span style="color:#3d5a73">// ไม่มี logs</span>';return;}
  box.innerHTML=r.lines.map(l=>{
    const cls=l.includes('error')||l.includes('ERR')?'le':l.includes('OK')||l.includes('start')?'lok':'';
    return `<div class="${cls}">${l}</div>`;
  }).join('');
  box.scrollTop=box.scrollHeight;
}

/* TOGGLE SERVICE */
async function toggleService(){
  const btn=$('toggle-btn'); btn.disabled=true;
  const act=svcOn?'stop':'start';
  toast(`⟳ ${act} service...`);
  const r=await api('POST',`/api/${act}`);
  btn.disabled=false;
  if(r.ok!==false){toast(act==='start'?'✔ เริ่ม service':'✔ หยุด service');setTimeout(loadAll,1000);}
  else toast('ไม่สำเร็จ: '+(r.result||r.error),true);
}

/* CONFIG */
function onBEChange(){$('db-port-f').style.display=$('cfg-backend').value==='1'?'':'none';}
async function saveCfg(){
  const ws=parseInt($('cfg-ws').value), ssh=parseInt($('cfg-ssh').value);
  const drop=parseInt($('cfg-backend').value), dbp=parseInt($('cfg-db-port').value)||2222;
  if(!ws||!ssh){toast('ใส่ port ให้ถูกต้อง',true);return;}
  const r=await api('POST','/api/config',{ws_port:ws,ssh_port:ssh,use_dropbear:drop,dropbear_port:dbp});
  if(r.ok!==false){toast('✔ บันทึก config แล้ว');setTimeout(loadAll,800);}
  else toast('บันทึกไม่ได้: '+(r.result||r.error),true);
}

async function loadAll(){
  if(!tok()){toast('ใส่ API Token ก่อน',true);return;}
  await loadStatus(); await loadUsers(); await loadOnline();
}

function startAuto(){
  if(autoRef) clearInterval(autoRef);
  autoRef=setInterval(()=>{if(tok()){loadStatus();loadOnline();}},8000);
}

document.querySelectorAll('.mo').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('open');}));

/* ─── BACKUP / IMPORT ────────────────────────────────── */
function resetBackup(){
  $('bk-output').value='';
  $('btn-copy-bk').disabled=true;
}

async function doBackup(){
  toast('⟳ กำลังดึงข้อมูล...');
  const users = await api('GET','/api/users');
  if(users.error){ toast('Backup ไม่ได้: '+users.error, true); return; }
  if(!Array.isArray(users)){ toast('ไม่มีข้อมูล users', true); return; }
  // สร้าง JSON พร้อม export (ไม่มี password เพราะ API ไม่ส่งกลับ)
  const exported = users.map(u=>({
    user:    u.user,
    password: '',        // ผู้ดูแลระบบกรอกเองถ้าต้องการ import ต่าง server
    days:    u.days   || 30,
    data_gb: u.data_gb|| 0,
    exp:     u.exp    || ''
  }));
  const json = JSON.stringify(exported, null, 2);
  $('bk-output').value = json;
  $('btn-copy-bk').disabled = false;
  toast(`✔ Backup ${exported.length} users สำเร็จ`);
}

function copyBackup(){
  const val = $('bk-output').value;
  if(!val){ toast('ไม่มีข้อมูลที่จะ copy', true); return; }
  navigator.clipboard.writeText(val)
    .then(()=>toast('✔ Copy JSON แล้ว'))
    .catch(()=>{
      // fallback
      $('bk-output').select();
      document.execCommand('copy');
      toast('✔ Copy JSON แล้ว (fallback)');
    });
}

async function doImport(){
  const raw = $('imp-input').value.trim();
  if(!raw){ toast('วาง JSON ก่อน', true); return; }
  let data;
  try{ data = JSON.parse(raw); }
  catch(e){ toast('JSON ไม่ถูกต้อง: '+e.message, true); return; }
  // รองรับทั้ง array โดยตรง และ {users:[...]}
  const payload = Array.isArray(data) ? {users:data} : data;
  toast('⟳ กำลัง Import...');
  const r = await api('POST', '/api/import', payload);
  const res = $('imp-result');
  res.style.display='block';
  if(r.ok){
    res.style.color='#00ff88';
    res.innerHTML =
      `✔ Import สำเร็จ <b>${r.total}</b> users<br>`+
      (r.created.length ? `<span style="color:#00e5ff">➕ สร้างใหม่: ${r.created.join(', ')}</span><br>` : '')+
      (r.updated.length ? `<span style="color:#ffd700">♻ อัพเดต: ${r.updated.join(', ')}</span><br>` : '')+
      (r.failed.length  ? `<span style="color:#ff2255">✕ ล้มเหลว: ${r.failed.join(', ')}</span>` : '');
    toast(`✔ Import ${r.total} users`);
    loadUsers();
  } else {
    res.style.color='#ff2255';
    res.textContent='✕ Import ไม่สำเร็จ: '+(r.error||JSON.stringify(r));
    toast('Import ไม่สำเร็จ', true);
  }
}
</script>
</body>
</html>"""

# แทนที่ token/host/proto อัตโนมัติ
html = html.replace("%%TOKEN%%", token)
html = html.replace("%%HOST%%", host)
html = html.replace("%%PROTO%%", proto)

with open("/var/www/chaiya/sshws.html","w") as f:
    f.write(html)
print("OK")
PYGENEOF

echo "✅ sshws.html สร้างพร้อมใช้งาน"

# ══════════════════════════════════════════════════════════
#  chaiya  (main menu — ไม่เปลี่ยน flow เดิม)
# ══════════════════════════════════════════════════════════
echo "✅ ติดตั้ง chaiya menu..."
# (ส่วนนี้คง base64 เดิมไว้ ไม่ตัดออก)
printf "%s" "IyEvYmluL2Jhc2gKREI9Ii9ldGMvY2hhaXlhL3ZsZXNzLmRiIgpET01BSU5fRklMRT0iL2V0Yy9jaGFpeWEvZG9tYWluLmNvbmYiCkJBTl9GSUxFPSIvZXRjL2NoYWl5YS9iYW5uZWQuZGIiCklQX0xPRz0iL2V0Yy9jaGFpeWEvaXBsb2cuZGIiClIxPSdcMDMzWzM4OzI7MjU1OzA7ODVtJwpSMj0nXDAzM1szODsyOzI1NTsxMDI7MG0nClIzPSdcMDMzWzM4OzI7MjU1OzIzODswbScKUjQ9J1wwMzNbMzg7MjswOzI1NTs2OG0nClI1PSdcMDMzWzM4OzI7MDsyMDQ7MjU1bScKUjY9J1wwMzNbMzg7MjsyMDQ7Njg7MjU1bScKUFU9J1wwMzNbMzg7MjsyMDQ7Njg7MjU1bScKWUU9J1wwMzNbMzg7MjsyNTU7MjM4OzBtJwpXSD0nXDAzM1sxOzM3bScKR1I9J1wwMzNbMzg7MjswOzI1NTs2OG0nClJEPSdcMDMzWzM4OzI7MjU1OzA7ODVtJwpSUz0nXDAzM1swbScKd2hpbGUgdHJ1ZTsgZG8KICBjbGVhcgogIHByaW50ZiAiJHtSMX0gIENIQUlZQSBWMlJBWSBQUk8gTUFYJHtSU31cbiIKICBwcmludGYgIiR7UjJ9ICAxLiBcdTc0ZThcdTlmMWQgM3gtdWkke1JTfVxuIgogIHByaW50ZiAiJHtSM30gIDIuIFNTTCR7UlN9XG4iCiAgcHJpbnRmICIke1I0fSAgMy4gVkxFU1Mke1JTfVxuIgogIHByaW50ZiAiJHtSNX0gIDE4LiBTU0ggV2ViU29ja2V0JHtSU31cbiIKICBwcmludGYgIiAgMC4gT3V0JHtSU31cbiIKICByZWFkIC1ycCAnPiAnIG9wdAogIGNhc2UgJG9wdCBpbgogIDE4KSBjbGVhcgogICAgTVlfSVA9JChob3N0bmFtZSAtSSB8IGF3ayAne3ByaW50ICQxfScpCiAgICBbWyAtZiAvZXRjL2NoYWl5YS9kb21haW4uY29uZiBdXSAmJiBIT1NUPSQoY2F0IC9ldGMvY2hhaXlhL2RvbWFpbi5jb25mKSB8fCBIT1NUPSIkTVlfSVAiCiAgICBUT0tFTj0kKGNhdCAvZXRjL2NoYWl5YS9zc2h3cy10b2tlbi5jb25mIDI+L2Rldi9udWxsIHx8IGVjaG8gInlldCIpCiAgICBwcmludGYgIlxuXHUyNTU0XHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTU3XG4iCiAgICBwcmludGYgIlx1MjU1MVx1MjAyNlx1MjU1MSBTU0ggb3ZlciBXZWJTb2NrZXQgTWFuYWdlciBcdTI1NTFcbiIKICAgIHByaW50ZiAiXHUyNTVhXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTUwXHUyNTVkXG5cbiIKICAgIFBST1RPPSJodHRwIjsgW1sgLWYgL2V0Yy9sZXRzZW5jcnlwdC9saXZlLyRIT1NUL2Z1bGxjaGFpbi5wZW0gXV0gJiYgUFJPVE89Imh0dHBzIgogICAgcHJpbnRmICIgIFx1MWU2Zlx1MWU0MyBVUkwgOiAkUFJPVE86Ly8kSE9TVC9zc2h3cy9zc2h3cy5odG1sXG4iCiAgICBwcmludGYgIiAgVG9rZW4gOiAkVE9LRU5cbiIKICAgIHJlYWQgLXJwICJFbnRlci4uLiI7OwogIDApIGV4aXQgMDs7CiAgZXNhYwpkb25lCg==" | base64 -d > /usr/local/bin/chaiya
chmod +x /usr/local/bin/chaiya

# ══════════════════════════════════════════════════════════
#  สรุปผลการติดตั้ง
# ══════════════════════════════════════════════════════════
TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null || echo "N/A")
HOST_DISP=""
[[ -f /etc/chaiya/domain.conf ]] && HOST_DISP=$(cat /etc/chaiya/domain.conf)
[[ -z "$HOST_DISP" ]] && HOST_DISP="$MY_IP"
PROTO_DISP="http"
[[ -f /etc/letsencrypt/live/$HOST_DISP/fullchain.pem ]] && PROTO_DISP="https"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ CHAIYA V2RAY PRO MAX v9 ติดตั้งเสร็จ!   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  🌐 SSH-WS Manager :"
echo "     $PROTO_DISP://$HOST_DISP/sshws/sshws.html"
echo ""
echo "  🔑 API Token (auto-filled ในหน้าเว็บ) :"
echo "     $TOKEN"
echo ""
echo "  ⚡ WebSocket SSH พอร์ต 80 : พร้อมใช้งาน"
echo "  🔧 nginx พอร์ต 81         : พร้อมใช้งาน"
echo "  🛡  IP Limit auto-ban      : ทุก 5 นาที"
echo ""
echo "  👉 พิมพ์: chaiya  เพื่อเปิดเมนู"
echo ""
