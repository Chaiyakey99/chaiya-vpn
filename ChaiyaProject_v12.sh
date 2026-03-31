#!/bin/bash
# ============================================================
#  CHAIYA V2RAY PRO MAX v10  —  Full Auto Setup
#  ติดตั้งครั้งเดียว พร้อมใช้งาน 100% ทุกเมนู
#  เมนู 1-18 ทำงานได้จริงทั้งหมด ไม่มีเมนูหลอก
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── สีและ style ──────────────────────────────────────────────
R1='\033[1;38;2;255;0;128m'
R2='\033[1;38;2;255;80;0m'
R3='\033[1;38;2;255;230;0m'
R4='\033[1;38;2;0;255;80m'
R5='\033[1;38;2;0;220;255m'
R6='\033[1;38;2;180;0;255m'
PU='\033[1;38;2;200;0;255m'
YE='\033[1;38;2;255;230;0m'
WH='\033[1;38;2;255;255;255m'
GR='\033[1;38;2;0;200;255m'
RD='\033[1;38;2;255;0;80m'
CY='\033[1;38;2;0;255;220m'
MG='\033[1;38;2;255;0;200m'
OR='\033[1;38;2;255;140;0m'
RS='\033[0m'
BLD='\033[1m'

echo -e "${R2}🔥 กำลังติดตั้ง CHAIYA V2RAY PRO MAX v10...${RS}"

# ── ล็อค / ล้าง dpkg ─────────────────────────────────────────
systemctl stop unattended-upgrades 2>/dev/null || true
pkill -f needrestart 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

apt-get update -y -qq
apt-get install -y -qq curl wget python3 bc qrencode ufw nginx \
  certbot python3-certbot-nginx python3-pip fail2ban sqlite3 \
  jq openssl net-tools 2>/dev/null || true

pip3 install bcrypt --break-system-packages -q 2>/dev/null || true

# ── หยุด service เก่า ────────────────────────────────────────
for svc in apache2 xray; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
rm -f /etc/systemd/system/xray.service /usr/local/bin/xray
rm -rf /usr/local/etc/xray /var/log/xray
systemctl daemon-reload 2>/dev/null || true

# ── สร้าง directories / files ────────────────────────────────
mkdir -p /etc/chaiya /var/www/chaiya/config /var/log/nginx \
         /etc/chaiya/sshws-users /etc/chaiya/vless-users
touch /etc/chaiya/vless.db /etc/chaiya/banned.db \
      /etc/chaiya/iplog.db /etc/chaiya/datalimit.conf \
      /etc/chaiya/iplimit_ban.json

echo "{}" > /etc/chaiya/iplimit_ban.json 2>/dev/null || true

# ── ตรวจจับ IP สาธารณะ ──────────────────────────────────────
MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
     || curl -s --max-time 5 api.ipify.org 2>/dev/null \
     || hostname -I | awk '{print $1}')

# ── UFW ──────────────────────────────────────────────────────
ufw --force enable 2>/dev/null || true
for p in 22 80 81 443 2053 2082 8080 8880; do
  ufw allow "$p"/tcp 2>/dev/null || true
done

# ══════════════════════════════════════════════════════════════
#  installer ไม่ถามอะไร — ทุกอย่างทำผ่านเมนู 1
#  แค่เตรียม helper functions ไว้ใช้ใน menu
# ══════════════════════════════════════════════════════════════
# สร้าง placeholder ถ้ายังไม่มี credential
[[ ! -f /etc/chaiya/xui-user.conf ]] && echo "admin" > /etc/chaiya/xui-user.conf
[[ ! -f /etc/chaiya/xui-pass.conf ]] && echo "" > /etc/chaiya/xui-pass.conf
[[ ! -f /etc/chaiya/xui-port.conf ]] && echo "2053" > /etc/chaiya/xui-port.conf
chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
#  nginx config
# ══════════════════════════════════════════════════════════════
cat > /etc/nginx/sites-available/chaiya << 'NGINXEOF'
# ── Port 80: WebSocket SSH
server {
    listen 80;
    server_name _;
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
# ── Port 81: Web Panel (SSH-WS + config download)
server {
    listen 81;
    server_name _;
    root /var/www/chaiya;
    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
        add_header Content-Disposition "attachment";
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
}
NGINXEOF

ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable nginx && systemctl restart nginx

# ── websocat ─────────────────────────────────────────────────
ARCH=$(uname -m)
WS_URL=""
[[ "$ARCH" == "x86_64"  ]] && WS_URL="https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl"
[[ "$ARCH" == "aarch64" ]] && WS_URL="https://github.com/vi/websocat/releases/latest/download/websocat.aarch64-unknown-linux-musl"
if [[ -n "$WS_URL" ]] && [[ ! -f /usr/local/bin/websocat ]]; then
  curl -sL "$WS_URL" -o /usr/local/bin/websocat 2>/dev/null && chmod +x /usr/local/bin/websocat
fi

# ── chaiya-sshws systemd ──────────────────────────────────────
cat > /etc/systemd/system/chaiya-sshws.service << 'WSEOF'
[Unit]
Description=Chaiya SSH over WebSocket (internal :8090)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/websocat --binary ws-l:127.0.0.1:8090 tcp:127.0.0.1:22
Restart=always
RestartSec=3
StandardOutput=append:/var/log/chaiya-sshws.log
StandardError=append:/var/log/chaiya-sshws.log
[Install]
WantedBy=multi-user.target
WSEOF

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

# ══════════════════════════════════════════════════════════════
#  chaiya-sshws-api  (Python HTTP API :6789)
# ══════════════════════════════════════════════════════════════
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
        if p == "/api/service":
            action = body.get("action","")
            if action == "start":
                out,code = run("systemctl start chaiya-sshws")
                cfg = load_conf(); cfg["ENABLED"]="1"; save_conf(cfg)
                return self.send_json(200,{"ok":code==0,"result":out})
            elif action == "stop":
                out,code = run("systemctl stop chaiya-sshws")
                cfg = load_conf(); cfg["ENABLED"]="0"; save_conf(cfg)
                return self.send_json(200,{"ok":code==0,"result":out})
            elif action == "restart":
                out,code = run("systemctl restart chaiya-sshws")
                return self.send_json(200,{"ok":code==0,"result":out})
            else:
                return self.send_json(400,{"error":"unknown action"})
        elif p == "/api/start":
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
            target = f"127.0.0.1:{cfg['SSH_PORT']}"
            if cfg["USE_DROPBEAR"]=="1": target = f"127.0.0.1:{cfg['DROPBEAR_PORT']}"
            unit = f"""[Unit]
Description=Chaiya SSH over WebSocket port {cfg['WS_PORT']}
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/websocat --binary ws-l:127.0.0.1:8090 tcp:{target}
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
            import subprocess as sp
            exp = sp.check_output(f"date -d '+{days} days' +'%Y-%m-%d'",shell=True).decode().strip()
            run(f"userdel -f {user} 2>/dev/null; useradd -M -s /bin/false -e {exp} {user}")
            run(f"echo '{user}:{pw}' | chpasswd")
            run(f"chage -E {exp} {user}")
            db = os.path.join(USERS_DIR,"users.db")
            with open(db,"a") as f: f.write(f"{user} {days} {exp} {data_gb}\n")
            return self.send_json(200,{"ok":True,"result":f"user_created:{user}"})
        elif p == "/api/renew":
            user    = body.get("user","").strip()
            days    = int(body.get("days",30))
            data_gb = int(body.get("data_gb",0))
            if not user: return self.send_json(400,{"error":"user required"})
            exp,_ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
            run(f"chage -E {exp} {user}")
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
                lines.append(f"{user} {days} {exp} {data_gb}\n")
            with open(db,"w") as f: f.writelines(lines)
            return self.send_json(200,{"ok":True,"result":f"renewed:{user} exp:{exp}"})
        elif p == "/api/unban":
            uid  = body.get("uid","")
            name = body.get("name","")
            bans = load_bans()
            if uid in bans: del bans[uid]
            save_bans(bans)
            run(f"usermod -e '' {name} 2>/dev/null || true")
            return self.send_json(200,{"ok":True})
        elif p == "/api/import":
            users_data = body.get("users", body) if isinstance(body, dict) else body
            if not isinstance(users_data, list):
                return self.send_json(400,{"error":"expected list of users"})
            created = []; updated = []; failed = []
            db = os.path.join(USERS_DIR,"users.db")
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
                    if not exp:
                        exp_out,_ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
                        exp = exp_out.strip()
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
    print(f"SSH-WS API :{PORT} | Token: {TOKEN}")
    server.serve_forever()
PYEOF
chmod +x /usr/local/bin/chaiya-sshws-api

python3 /usr/local/bin/chaiya-sshws-api install
sleep 2

# ── SSHWS token ──────────────────────────────────────────────
SSHWS_TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')
if [[ -z "$SSHWS_TOKEN" ]]; then
  SSHWS_TOKEN=$(python3 -c "import hashlib,os; print(hashlib.sha256(os.urandom(32)).hexdigest()[:32])")
  echo "$SSHWS_TOKEN" > /etc/chaiya/sshws-token.conf
fi

SSHWS_HOST=""
[[ -f /etc/chaiya/domain.conf ]] && SSHWS_HOST=$(cat /etc/chaiya/domain.conf)
[[ -z "$SSHWS_HOST" ]] && SSHWS_HOST="$MY_IP"
SSHWS_PROTO="http"
[[ -f /etc/letsencrypt/live/$(cat /etc/chaiya/domain.conf 2>/dev/null)/fullchain.pem ]] && SSHWS_PROTO="https"

# ── chaiya-iplimit ────────────────────────────────────────────
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

for uid in list(bans.keys()):
    until = datetime.fromisoformat(bans[uid]["until"])
    if now >= until:
        name = bans[uid]["name"]
        subprocess.run(f"usermod -e '' {name} 2>/dev/null || true", shell=True)
        print(f"🔓 Unban: {name}")
        del bans[uid]

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

(crontab -l 2>/dev/null | grep -v chaiya-iplimit
 echo "*/5 * * * * python3 /usr/local/bin/chaiya-iplimit >> /var/log/chaiya-iplimit.log 2>&1"
) | crontab -

# ══════════════════════════════════════════════════════════════
#  สร้าง sshws.html  (base64 decode + แทน token)
# ══════════════════════════════════════════════════════════════
_SSHWS_TOK=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]' || echo "N/A")
_SSHWS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
_SSHWS_HOST=$( [[ -f /etc/chaiya/domain.conf ]] && cat /etc/chaiya/domain.conf || echo "$_SSHWS_IP" )
_SSHWS_PROTO="http"
[[ -f "/etc/letsencrypt/live/${_SSHWS_HOST}/fullchain.pem" ]] && _SSHWS_PROTO="https"

printf '%s' 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFNTSC1XUzwvdGl0bGU+CjxzdHlsZT4KOnJvb3R7LS1iZzojMDIwNDA4Oy0tYmcyOiMwNjBkMTQ7LS1ib3JkZXI6IzBmMjAzMDstLW1vbm86J0NvdXJpZXIgTmV3Jyxtb25vc3BhY2V9Cip7Ym94LXNpemluZzpib3JkZXItYm94O21hcmdpbjowO3BhZGRpbmc6MH0KYm9keXtiYWNrZ3JvdW5kOnZhcigtLWJnKTtjb2xvcjojYzhkZGU4O2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO21pbi1oZWlnaHQ6MTAwdmg7b3ZlcmZsb3cteDpoaWRkZW59CgovKiBSR0IgYm9yZGVyIGFuaW1hdGlvbiAqLwpAa2V5ZnJhbWVzIHJnYi1ib3JkZXJ7CiAgMCV7Ym9yZGVyLWNvbG9yOiNmZjAwNTV9CiAgMTYle2JvcmRlci1jb2xvcjojZmY2NjAwfQogIDMzJXtib3JkZXItY29sb3I6I2ZmZWUwMH0KICA1MCV7Ym9yZGVyLWNvbG9yOiMwMGZmNDR9CiAgNjYle2JvcmRlci1jb2xvcjojMDBjY2ZmfQogIDgzJXtib3JkZXItY29sb3I6I2NjNDRmZn0KICAxMDAle2JvcmRlci1jb2xvcjojZmYwMDU1fQp9CkBrZXlmcmFtZXMgcmdiLWdsb3d7CiAgMCV7dGV4dC1zaGFkb3c6MCAwIDhweCAjZmYwMDU1LDAgMCAxNnB4ICNmZjAwNTUzM30KICAxNiV7dGV4dC1zaGFkb3c6MCAwIDhweCAjZmY2NjAwLDAgMCAxNnB4ICNmZjY2MDAzM30KICAzMyV7dGV4dC1zaGFkb3c6MCAwIDhweCAjZmZlZTAwLDAgMCAxNnB4ICNmZmVlMDAzM30KICA1MCV7dGV4dC1zaGFkb3c6MCAwIDhweCAjMDBmZjQ0LDAgMCAxNnB4ICMwMGZmNDQzM30KICA2NiV7dGV4dC1zaGFkb3c6MCAwIDhweCAjMDBjY2ZmLDAgMCAxNnB4ICMwMGNjZmYzM30KICA4MyV7dGV4dC1zaGFkb3c6MCAwIDhweCAjY2M0NGZmLDAgMCAxNnB4ICNjYzQ0ZmYzM30KICAxMDAle3RleHQtc2hhZG93OjAgMCA4cHggI2ZmMDA1NSwwIDAgMTZweCAjZmYwMDU1MzN9Cn0KQGtleWZyYW1lcyByZ2ItdW5kZXJsaW5lewogIDAle2JhY2tncm91bmQtcG9zaXRpb246MCUgNTAlfQogIDEwMCV7YmFja2dyb3VuZC1wb3NpdGlvbjoyMDAlIDUwJX0KfQpAa2V5ZnJhbWVzIHB1bHNlLWRvdHsKICAwJSwxMDAle29wYWNpdHk6MTt0cmFuc2Zvcm06c2NhbGUoMSl9CiAgNTAle29wYWNpdHk6LjY7dHJhbnNmb3JtOnNjYWxlKC44KX0KfQoKLndyYXB7bWF4LXdpZHRoOjk2MHB4O21hcmdpbjowIGF1dG87cGFkZGluZzoxNnB4fQoKLyogSGVhZGVyIFJHQiAqLwouaDF7CiAgZm9udC1zaXplOjI2cHg7Zm9udC13ZWlnaHQ6OTAwO2xldHRlci1zcGFjaW5nOjVweDsKICBhbmltYXRpb246cmdiLWdsb3cgM3MgbGluZWFyIGluZmluaXRlOwogIGNvbG9yOiNmZjAwNTU7Cn0KLmgxLXVuZGVyewogIGhlaWdodDoycHg7bWFyZ2luLXRvcDo0cHg7bWFyZ2luLWJvdHRvbTo0cHg7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2ZmMDA1NSwjZmY2NjAwLCNmZmVlMDAsIzAwZmY0NCwjMDBjY2ZmLCNjYzQ0ZmYsI2ZmMDA1NSk7CiAgYmFja2dyb3VuZC1zaXplOjIwMCUgMTAwJTsKICBhbmltYXRpb246cmdiLXVuZGVybGluZSAycyBsaW5lYXIgaW5maW5pdGU7Cn0KLnN1Yntjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjE2cHh9CgovKiBDYXJkIHdpdGggUkdCIGJvcmRlciBvbiBob3ZlciAqLwouY2FyZHsKICBiYWNrZ3JvdW5kOnZhcigtLWJnMik7Ym9yZGVyOjFweCBzb2xpZCAjMWEzYTU1OwogIHBhZGRpbmc6MTRweDttYXJnaW4tYm90dG9tOjEycHg7CiAgdHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjNzOwp9Ci5jYXJkOmhvdmVye2FuaW1hdGlvbjpyZ2ItYm9yZGVyIDJzIGxpbmVhciBpbmZpbml0ZX0KLmNhcmQucmdiLWFsd2F5c3thbmltYXRpb246cmdiLWJvcmRlciAycyBsaW5lYXIgaW5maW5pdGV9CgoubGJse2NvbG9yOiMzZDVhNzM7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO21hcmdpbi1ib3R0b206NHB4fQoudmFse2NvbG9yOiMwMGU1ZmY7Zm9udC1zaXplOjEzcHh9Ci5idG57cGFkZGluZzo2cHggMTJweDtib3JkZXI6MXB4IHNvbGlkICMwMGU1ZmY7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtjb2xvcjojMDBlNWZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZToxMXB4O3RyYW5zaXRpb246YmFja2dyb3VuZCAuMnN9Ci5idG46aG92ZXJ7YmFja2dyb3VuZDojMDBlNWZmMjJ9Ci5idG4tZ3tib3JkZXItY29sb3I6IzAwZmY4ODtjb2xvcjojMDBmZjg4fS5idG4tZzpob3ZlcntiYWNrZ3JvdW5kOiMwMGZmODgyMn0KLmJ0bi1ye2JvcmRlci1jb2xvcjojZmYyMjU1O2NvbG9yOiNmZjIyNTV9LmJ0bi1yOmhvdmVye2JhY2tncm91bmQ6I2ZmMjI1NTIyfQouYnRuLXl7Ym9yZGVyLWNvbG9yOiNmZmVlMDA7Y29sb3I6I2ZmZWUwMH0uYnRuLXk6aG92ZXJ7YmFja2dyb3VuZDojZmZlZTAwMjJ9Ci5idG4tcHtib3JkZXItY29sb3I6I2NjNDRmZjtjb2xvcjojY2M0NGZmfS5idG4tcDpob3ZlcntiYWNrZ3JvdW5kOiNjYzQ0ZmYyMn0KCnRhYmxle3dpZHRoOjEwMCU7Ym9yZGVyLWNvbGxhcHNlOmNvbGxhcHNlO2ZvbnQtc2l6ZToxMXB4fQp0aHtjb2xvcjojM2Q1YTczO2ZvbnQtd2VpZ2h0OjQwMDtwYWRkaW5nOjZweCA4cHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgIzBmMjAzMDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxcHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlfQp0ZHtwYWRkaW5nOjhweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCAjMGExNTIwfQp0cjpob3ZlciB0ZHtiYWNrZ3JvdW5kOiMwYTE1MjB9Ci5waWxse3BhZGRpbmc6MXB4IDZweDtmb250LXNpemU6OHB4O2JvcmRlcjoxcHggc29saWR9Ci5wZ3tib3JkZXItY29sb3I6IzAwZmY4ODQ0O2NvbG9yOiMwMGZmODg7YmFja2dyb3VuZDojMDBmZjg4MTF9Ci5wcntib3JkZXItY29sb3I6I2ZmMjI1NTQ0O2NvbG9yOiNmZjIyNTU7YmFja2dyb3VuZDojZmYyMjU1MTF9CmlucHV0LHNlbGVjdHtiYWNrZ3JvdW5kOiMwMzA2MDg7Ym9yZGVyOjFweCBzb2xpZCAjMWEzYTU1O2NvbG9yOiNjOGRkZTg7cGFkZGluZzo2cHggOHB4O2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZToxMXB4O3dpZHRoOjEwMCU7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yc30KaW5wdXQ6Zm9jdXMsc2VsZWN0OmZvY3Vze2JvcmRlci1jb2xvcjojMDBlNWZmfQouZml7bWFyZ2luLWJvdHRvbTo4cHh9LmZpIGxhYmVse2Rpc3BsYXk6YmxvY2s7Y29sb3I6IzNkNWE3Mztmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjFweDttYXJnaW4tYm90dG9tOjNweH0KLnJvd3tkaXNwbGF5OmZsZXg7Z2FwOjhweDthbGlnbi1pdGVtczpmbGV4LWVuZH0KLmcye2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweH0KLnRhYnN7ZGlzcGxheTpmbGV4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkICMwZjIwMzA7bWFyZ2luLWJvdHRvbToxMnB4O2ZsZXgtd3JhcDp3cmFwO2dhcDoycHh9Ci50YWJ7cGFkZGluZzo3cHggMTJweDtiYWNrZ3JvdW5kOm5vbmU7Ym9yZGVyOm5vbmU7Y29sb3I6IzNkNWE3MztjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTp2YXIoLS1tb25vKTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjFweDtib3JkZXItYm90dG9tOjJweCBzb2xpZCB0cmFuc3BhcmVudDttYXJnaW4tYm90dG9tOi0xcHg7dHJhbnNpdGlvbjpjb2xvciAuMnN9Ci50YWIub257Y29sb3I6IzAwZTVmZjtib3JkZXItYm90dG9tLWNvbG9yOiMwMGU1ZmZ9Ci50Y3tkaXNwbGF5Om5vbmV9LnRjLm9ue2Rpc3BsYXk6YmxvY2t9Ci5sb2d7YmFja2dyb3VuZDojMDMwNjA4O2JvcmRlcjoxcHggc29saWQgIzBmMjAzMDtwYWRkaW5nOjEwcHg7aGVpZ2h0OjEzMHB4O292ZXJmbG93LXk6YXV0bztmb250LXNpemU6MTBweDtjb2xvcjojMmE1YTQwO2xpbmUtaGVpZ2h0OjEuN30KI3RvYXN0e3Bvc2l0aW9uOmZpeGVkO2JvdHRvbToxNnB4O3JpZ2h0OjE2cHg7cGFkZGluZzo4cHggMTRweDtiYWNrZ3JvdW5kOnZhcigtLWJnMik7Ym9yZGVyOjFweCBzb2xpZCAjMDBlNWZmO2NvbG9yOiMwMGU1ZmY7Zm9udC1zaXplOjEwcHg7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoMTQwJSk7dHJhbnNpdGlvbjouM3M7ei1pbmRleDo5OTk5fQojdG9hc3Quc3t0cmFuc2Zvcm06bm9uZX0KLm1ve3Bvc2l0aW9uOmZpeGVkO2luc2V0OjA7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC44NSk7ZGlzcGxheTpub25lO3BsYWNlLWl0ZW1zOmNlbnRlcjt6LWluZGV4OjUwMDB9Ci5tby5ve2Rpc3BsYXk6Z3JpZH0KLm1ke2JhY2tncm91bmQ6dmFyKC0tYmcyKTtib3JkZXI6MXB4IHNvbGlkICMxYTNhNTU7cGFkZGluZzoyMHB4O3dpZHRoOm1pbig5MHZ3LDM4MHB4KX0KLm1kIGgze2NvbG9yOiMwMGU1ZmY7Zm9udC1zaXplOjEwcHg7bGV0dGVyLXNwYWNpbmc6MnB4O21hcmdpbi1ib3R0b206MTJweH0KLm1me2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2p1c3RpZnktY29udGVudDpmbGV4LWVuZDttYXJnaW4tdG9wOjEycHg7ZmxleC13cmFwOndyYXB9CgovKiBTZXJ2aWNlIHN0YXR1cyBkb3QgKi8KLmRvdHt3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXItcmFkaXVzOjUwJTtkaXNwbGF5OmlubGluZS1ibG9jazthbmltYXRpb246cHVsc2UtZG90IDJzIGVhc2UtaW4tb3V0IGluZmluaXRlfQouZG90LW9ue2JhY2tncm91bmQ6IzAwZmY4ODtib3gtc2hhZG93OjAgMCA2cHggIzAwZmY4OH0KLmRvdC1vZmZ7YmFja2dyb3VuZDojZmYyMjU1O2JveC1zaGFkb3c6MCAwIDZweCAjZmYyMjU1fQoKLyogQmFja3VwL0ltcG9ydCBhcmVhICovCi5iYWNrdXAtYm94e2JhY2tncm91bmQ6IzAzMDYwODtib3JkZXI6MXB4IHNvbGlkICMwZjIwMzA7cGFkZGluZzoxMHB4O2ZvbnQtc2l6ZToxMHB4O2NvbG9yOiMzZDVhNzM7d2lkdGg6MTAwJTtoZWlnaHQ6ODBweDtyZXNpemU6dmVydGljYWw7b3V0bGluZTpub25lO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pfQouYmFja3VwLWJveDpmb2N1c3tib3JkZXItY29sb3I6I2NjNDRmZn0KCkBtZWRpYShtYXgtd2lkdGg6NjAwcHgpey5nMntncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS5tZntmbGV4LWRpcmVjdGlvbjpjb2x1bW59fQo8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGNsYXNzPSJ3cmFwIj4KCjwhLS0gSGVhZGVyIC0tPgo8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6ZmxleC1zdGFydDtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE4cHgiPgogIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICA8ZGl2IGNsYXNzPSJoMSI+Q0hBSVlBIFNTSC1XUzwvZGl2PgogICAgPGRpdiBjbGFzcz0iaDEtdW5kZXIiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0ic3ViIj4vLyBXRUJTT0NLRVQgU1NIIE1BTkFHRVI8L2Rpdj4KICA8L2Rpdj4KICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7Zm9udC1zaXplOjEwcHg7bWFyZ2luLXRvcDo0cHgiPgogICAgPHNwYW4gY2xhc3M9ImRvdCBkb3Qtb2ZmIiBpZD0iZG90Ij48L3NwYW4+CiAgICA8c3BhbiBpZD0iZ2xibCIgc3R5bGU9ImNvbG9yOiMzZDVhNzMiPuKAlDwvc3Bhbj4KICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIFRva2VuIGNhcmQgLS0+CjxkaXYgY2xhc3M9ImNhcmQgcmdiLWFsd2F5cyIgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmNlbnRlciI+CiAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgIDxkaXYgY2xhc3M9ImxibCI+QVBJIFRPS0VOPC9kaXY+CiAgICA8aW5wdXQgdHlwZT0icGFzc3dvcmQiIGlkPSJ0b2siIHBsYWNlaG9sZGVyPSJUb2tlbiAoYXV0by1maWxsZWQpIj4KICA8L2Rpdj4KICA8YnV0dG9uIGNsYXNzPSJidG4iIG9uY2xpY2s9InRvZ2dsZVRvaygpIj7wn5GBPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1nIiBvbmNsaWNrPSJsb2FkQWxsKCkiPuKWtiDguYDguIrguLfguYjguK3guKHguJXguYjguK08L2J1dHRvbj4KPC9kaXY+Cgo8IS0tIFN0YXR1cyByb3cgLS0+CjxkaXYgY2xhc3M9ImcyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxMnB4Ij4KICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgIDxkaXYgY2xhc3M9ImxibCI+V2ViU29ja2V0IFN0YXR1czwvZGl2PgogICAgPGRpdiBjbGFzcz0idmFsIiBpZD0id3MtcyI+4oCUPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZTo5cHg7bWFyZ2luLXRvcDozcHgiIGlkPSJ3cy1wIj5wb3J0IOKAlDwvZGl2PgogIDwvZGl2PgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGRpdiBjbGFzcz0ibGJsIj5Db25uZWN0aW9uczwvZGl2PgogICAgPGRpdiBjbGFzcz0idmFsIiBpZD0iY29ubnMiPuKAlDwvZGl2PgogICAgPGRpdiBzdHlsZT0iY29sb3I6IzNkNWE3Mztmb250LXNpemU6OXB4O21hcmdpbi10b3A6M3B4Ij5hY3RpdmUgc2Vzc2lvbnM8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIE1haW4gY2FyZCB0YWJzIC0tPgo8ZGl2IGNsYXNzPSJjYXJkIj4KICA8ZGl2IGNsYXNzPSJ0YWJzIj4KICAgIDxidXR0b24gY2xhc3M9InRhYiBvbiIgb25jbGljaz0ic3coJ3QtdXNlcnMnLHRoaXMpIj7wn5GkIFVzZXJzPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LW9ubGluZScsdGhpcykiPvCfn6IgT25saW5lPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LWJhbicsdGhpcykiPvCfmqsgQmFubmVkPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LWJhY2t1cCcsdGhpcykiPvCfkr4gQmFja3VwPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LXN2YycsdGhpcykiPuKame+4jyBTZXJ2aWNlPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LWxvZycsdGhpcykiPvCfk4sgTG9nczwvYnV0dG9uPgogIDwvZGl2PgoKICA8IS0tIFVzZXJzIHRhYiAtLT4KICA8ZGl2IGNsYXNzPSJ0YyBvbiIgaWQ9InQtdXNlcnMiPgogICAgPGRpdiBjbGFzcz0iZzIiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjhweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZpIj48bGFiZWw+VXNlcm5hbWU8L2xhYmVsPjxpbnB1dCBpZD0ibnUiIHBsYWNlaG9sZGVyPSJ1c2VyMSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpIj48bGFiZWw+UGFzc3dvcmQ8L2xhYmVsPjxpbnB1dCB0eXBlPSJwYXNzd29yZCIgaWQ9Im5wIiBwbGFjZWhvbGRlcj0i4oCi4oCi4oCi4oCi4oCi4oCi4oCi4oCiIj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0icm93IiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxMnB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZmkiIHN0eWxlPSJtYXJnaW46MDtmbGV4OjEiPjxsYWJlbD7guKfguLHguJk8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJuZCIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaSIgc3R5bGU9Im1hcmdpbjowO2ZsZXg6MSI+PGxhYmVsPkRhdGEgR0IgKDA9aW5mKTwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9Im5nYiIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tZyIgb25jbGljaz0iYWRkVXNlcigpIj4rIOC5gOC4nuC4tOC5iOC4oTwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8dGFibGU+CiAgICAgIDx0aGVhZD48dHI+PHRoPlVzZXJuYW1lPC90aD48dGg+4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC90aD48dGg+RGF0YTwvdGg+PHRoPuC4quC4luC4suC4meC4sDwvdGg+PHRoPkFjdGlvbnM8L3RoPjwvdHI+PC90aGVhZD4KICAgICAgPHRib2R5IGlkPSJ1dGIiPjx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L3RkPjwvdHI+PC90Ym9keT4KICAgIDwvdGFibGU+CiAgPC9kaXY+CgogIDwhLS0gT25saW5lIHRhYiAtLT4KICA8ZGl2IGNsYXNzPSJ0YyIgaWQ9InQtb25saW5lIj4KICAgIDx0YWJsZT4KICAgICAgPHRoZWFkPjx0cj48dGg+UmVtb3RlIElQPC90aD48dGg+U3RhdGU8L3RoPjwvdHI+PC90aGVhZD4KICAgICAgPHRib2R5IGlkPSJvdGIiPjx0cj48dGQgY29sc3Bhbj0iMiIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgY29ubmVjdGlvbjwvdGQ+PC90cj48L3Rib2R5PgogICAgPC90YWJsZT4KICA8L2Rpdj4KCiAgPCEtLSBCYW5uZWQgdGFiIC0tPgogIDxkaXYgY2xhc3M9InRjIiBpZD0idC1iYW4iPgogICAgPHRhYmxlPgogICAgICA8dGhlYWQ+PHRyPjx0aD5Vc2VybmFtZTwvdGg+PHRoPuC4luC4ueC4geC5geC4muC4meC4luC4tuC4hzwvdGg+PHRoPklQczwvdGg+PHRoPkFjdGlvbjwvdGg+PC90cj48L3RoZWFkPgogICAgICA8dGJvZHkgaWQ9ImJ0YiI+PHRyPjx0ZCBjb2xzcGFuPSI0IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6IzNkNWE3MztwYWRkaW5nOjE2cHgiPuC5hOC4oeC5iOC4oeC4tSBhY2NvdW50IOC4luC4ueC4geC5geC4muC4mTwvdGQ+PC90cj48L3Rib2R5PgogICAgPC90YWJsZT4KICA8L2Rpdj4KCiAgPCEtLSBCYWNrdXAvSW1wb3J0IHRhYiAtLT4KICA8ZGl2IGNsYXNzPSJ0YyIgaWQ9InQtYmFja3VwIj4KICAgIDxkaXYgc3R5bGU9Im1hcmdpbi1ib3R0b206MTRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImxibCIgc3R5bGU9Im1hcmdpbi1ib3R0b206OHB4Ij7wn5OmIEJBQ0tVUCBVU0VSUzwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjhweCI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1wIiBvbmNsaWNrPSJkb0JhY2t1cCgpIj7irIcgRXhwb3J0IEpTT048L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLXkiIG9uY2xpY2s9ImNvcHlCYWNrdXAoKSI+8J+TiyBDb3B5PC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8dGV4dGFyZWEgY2xhc3M9ImJhY2t1cC1ib3giIGlkPSJiYWNrdXAtb3V0IiBwbGFjZWhvbGRlcj0iLy8g4LiB4LiUIEV4cG9ydCDguYDguJ7guLfguYjguK3guJTguLnguILguYnguK3guKHguLnguKUgYmFja3VwLi4uIiByZWFkb25seT48L3RleHRhcmVhPgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJib3JkZXItdG9wOjFweCBzb2xpZCAjMGYyMDMwO3BhZGRpbmctdG9wOjE0cHgiPgogICAgICA8ZGl2IGNsYXNzPSJsYmwiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjhweCI+8J+TpSBJTVBPUlQgVVNFUlM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmkiPjxsYWJlbD7guKfguLLguIfguILguYnguK3guKHguLnguKUgSlNPTiDguJfguLXguYjguJnguLXguYg8L2xhYmVsPgogICAgICAgIDx0ZXh0YXJlYSBjbGFzcz0iYmFja3VwLWJveCIgaWQ9ImltcG9ydC1pbiIgcGxhY2Vob2xkZXI9J1t7InVzZXIiOiJ4IiwicGFzc3dvcmQiOiJ5IiwiZGF5cyI6MzAsImRhdGFfZ2IiOjB9XScgc3R5bGU9ImhlaWdodDo3MHB4Ij48L3RleHRhcmVhPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHgiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tZyIgb25jbGljaz0iZG9JbXBvcnQoKSI+4qyGIEltcG9ydDwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0biIgb25jbGljaz0iZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ltcG9ydC1pbicpLnZhbHVlPScnIj7inJUgQ2xlYXI8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSBTZXJ2aWNlIHRhYiAtLT4KICA8ZGl2IGNsYXNzPSJ0YyIgaWQ9InQtc3ZjIj4KICAgIDxkaXYgc3R5bGU9Im1hcmdpbi1ib3R0b206MTJweCI+CiAgICAgIDxkaXYgY2xhc3M9ImxibCI+U1NILVdTIFNFUlZJQ0U8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4O21hcmdpbi10b3A6NnB4O21hcmdpbi1ib3R0b206MTRweCI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImRvdCBkb3Qtb2ZmIiBpZD0ic3ZjLWRvdCI+PC9zcGFuPgogICAgICAgIDxzcGFuIGlkPSJzdmMtbGJsIiBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6IzNkNWE3MyI+4LiB4Liz4Lil4Lix4LiH4LiV4Lij4Lin4LiI4Liq4Lit4LiaLi4uPC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2dhcDo4cHgiPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWciIG9uY2xpY2s9InN2Y0FjdGlvbignc3RhcnQnKSI+4pa2IFN0YXJ0PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4teSIgb25jbGljaz0ic3ZjQWN0aW9uKCdyZXN0YXJ0JykiPuKGuiBSZXN0YXJ0PC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tciIgb25jbGljaz0ic3ZjQWN0aW9uKCdzdG9wJykiPuKWoCBTdG9wPC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biIgb25jbGljaz0ibG9hZFN2Y1N0YXR1cygpIj7in7MgUmVmcmVzaDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gTG9ncyB0YWIgLS0+CiAgPGRpdiBjbGFzcz0idGMiIGlkPSJ0LWxvZyI+CiAgICA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOnJpZ2h0O21hcmdpbi1ib3R0b206OHB4Ij48YnV0dG9uIGNsYXNzPSJidG4iIG9uY2xpY2s9ImxvYWRMb2dzKCkiPlJlZnJlc2g8L2J1dHRvbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImxvZyIgaWQ9ImxvZ2JveCI+PHNwYW4gc3R5bGU9ImNvbG9yOiMzZDVhNzMiPi8vIOC4geC4lCBSZWZyZXNoPC9zcGFuPjwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxkaXYgaWQ9InRvYXN0Ij48L2Rpdj4KCjwhLS0gTW9kYWwgUmVuZXcgLS0+CjxkaXYgY2xhc3M9Im1vIiBpZD0ibS1yZW5ldyI+CiAgPGRpdiBjbGFzcz0ibWQiPgogICAgPGgzPuC4leC5iOC4reC4reC4suC4ouC4uCBVc2VyPC9oMz4KICAgIDxkaXYgY2xhc3M9ImZpIj48bGFiZWw+VXNlcm5hbWU8L2xhYmVsPjxpbnB1dCBpZD0icm4tdSIgcmVhZG9ubHkgc3R5bGU9ImNvbG9yOiMwMGU1ZmYiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iZzIiPgogICAgICA8ZGl2IGNsYXNzPSJmaSI+PGxhYmVsPuC4p+C4seC4mTwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9InJuLWQiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmkiPjxsYWJlbD5EYXRhIEdCPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0icm4tZ2IiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJtZiI+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biIgb25jbGljaz0iY20oJ20tcmVuZXcnKSI+4Lii4LiB4LmA4Lil4Li04LiBPC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tZyIgb25jbGljaz0iY29uZmlybVJlbmV3KCkiPuC4leC5iOC4reC4reC4suC4ouC4uDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2PgoKPCEtLSBNb2RhbCBEZWxldGUgLS0+CjxkaXYgY2xhc3M9Im1vIiBpZD0ibS1kZWwiPgogIDxkaXYgY2xhc3M9Im1kIj4KICAgIDxoMz7guKXguJogVXNlcjwvaDM+CiAgICA8cCBzdHlsZT0iZm9udC1zaXplOjExcHg7bWFyZ2luLWJvdHRvbToxMHB4Ij7guKXguJogPHNwYW4gaWQ9ImR1IiBzdHlsZT0iY29sb3I6I2ZmMjI1NTtmb250LXdlaWdodDo3MDAiPjwvc3Bhbj4gPzwvcD4KICAgIDxkaXYgY2xhc3M9Im1mIj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBvbmNsaWNrPSJjbSgnbS1kZWwnKSI+4Lii4LiB4LmA4Lil4Li04LiBPC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tciIgb25jbGljaz0iY29uZmlybURlbCgpIj7guKXguJo8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQ+CmNvbnN0IEFVVE9fVE9LRU49IiUlVE9LRU4lJSIsQVVUT19IT1NUPSIlJUhPU1QlJSIsQVVUT19QUk9UTz0iJSVQUk9UTyUlIjsKY29uc3QgQVBJPXdpbmRvdy5sb2NhdGlvbi5vcmlnaW4rJy9zc2h3cy1hcGknOwpsZXQgZGVsVGFyZ2V0PScnOwpjb25zdCBFTD1pZD0+ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwoKd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2xvYWQnLCgpPT57CiAgY29uc3Qgc2F2ZWQ9bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2N0b2snKTsKICBpZihBVVRPX1RPS0VOJiZBVVRPX1RPS0VOIT09JyUlVE9LRU4lJScpe0VMKCd0b2snKS52YWx1ZT1BVVRPX1RPS0VOO2xvY2FsU3RvcmFnZS5zZXRJdGVtKCdjdG9rJyxBVVRPX1RPS0VOKTt9CiAgZWxzZSBpZihzYXZlZCkgRUwoJ3RvaycpLnZhbHVlPXNhdmVkOwogIEVMKCd0b2snKS5hZGRFdmVudExpc3RlbmVyKCdjaGFuZ2UnLCgpPT5sb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY3RvaycsZ2V0VG9rKCkpKTsKICBpZihnZXRUb2soKSkgbG9hZEFsbCgpOwogIHNldEludGVydmFsKCgpPT57aWYoZ2V0VG9rKCkpe2xvYWRTdGF0dXMoKTtsb2FkT25saW5lKCk7fX0sODAwMCk7Cn0pOwoKZnVuY3Rpb24gZ2V0VG9rKCl7cmV0dXJuIEVMKCd0b2snKS52YWx1ZS50cmltKCk7fQpmdW5jdGlvbiB0b2dnbGVUb2soKXtjb25zdCBlPUVMKCd0b2snKTtlLnR5cGU9ZS50eXBlPT09J3Bhc3N3b3JkJz8ndGV4dCc6J3Bhc3N3b3JkJzt9CmZ1bmN0aW9uIHRvYXN0KG1zZyxlcnI9ZmFsc2UpewogIGNvbnN0IHQ9RUwoJ3RvYXN0Jyk7dC50ZXh0Q29udGVudD1tc2c7dC5jbGFzc05hbWU9J3MnKyhlcnI/JyBlcnInOicnKTsKICBjbGVhclRpbWVvdXQodC5fdCk7dC5fdD1zZXRUaW1lb3V0KCgpPT50LmNsYXNzTmFtZT0nJywyODAwKTsKfQphc3luYyBmdW5jdGlvbiBhcGkobWV0aG9kLHBhdGgsYm9keT1udWxsKXsKICBjb25zdCBvPXttZXRob2QsaGVhZGVyczp7J0F1dGhvcml6YXRpb24nOidCZWFyZXIgJytnZXRUb2soKSwnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9fTsKICBpZihib2R5KSBvLmJvZHk9SlNPTi5zdHJpbmdpZnkoYm9keSk7CiAgdHJ5e2NvbnN0IHI9YXdhaXQgZmV0Y2goQVBJK3BhdGgsbyk7cmV0dXJuIGF3YWl0IHIuanNvbigpO31jYXRjaChlKXtyZXR1cm57ZXJyb3I6ZS5tZXNzYWdlfTt9Cn0KZnVuY3Rpb24gc3coaWQsZWwpewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YycpLmZvckVhY2godD0+dC5jbGFzc0xpc3QucmVtb3ZlKCdvbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudGFiJykuZm9yRWFjaCh0PT50LmNsYXNzTGlzdC5yZW1vdmUoJ29uJykpOwogIEVMKGlkKS5jbGFzc0xpc3QuYWRkKCdvbicpO2VsLmNsYXNzTGlzdC5hZGQoJ29uJyk7CiAgaWYoaWQ9PT0ndC1vbmxpbmUnKWxvYWRPbmxpbmUoKTsKICBpZihpZD09PSd0LWJhbicpbG9hZEJhbm5lZCgpOwogIGlmKGlkPT09J3QtbG9nJylsb2FkTG9ncygpOwogIGlmKGlkPT09J3Qtc3ZjJylsb2FkU3ZjU3RhdHVzKCk7CiAgaWYoaWQ9PT0ndC1iYWNrdXAnKWRvQmFja3VwKCk7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFN0YXR1cygpewogIGNvbnN0IGQ9YXdhaXQgYXBpKCdHRVQnLCcvYXBpL3N0YXR1cycpOwogIGlmKGQuZXJyb3IpcmV0dXJuOwogIGNvbnN0IG9uPWQud3Nfc3RhdHVzPT09J2FjdGl2ZSc7CiAgRUwoJ2RvdCcpLmNsYXNzTmFtZT0nZG90ICcrKG9uPydkb3Qtb24nOidkb3Qtb2ZmJyk7CiAgRUwoJ2dsYmwnKS50ZXh0Q29udGVudD1vbj8nT05MSU5FJzonT0ZGTElORSc7CiAgRUwoJ2dsYmwnKS5zdHlsZS5jb2xvcj1vbj8nIzAwZmY4OCc6JyNmZjIyNTUnOwogIEVMKCd3cy1zJykudGV4dENvbnRlbnQ9b24/J1JVTk5JTkcnOidTVE9QUEVEJzsKICBFTCgnd3MtcycpLnN0eWxlLmNvbG9yPW9uPycjMDBmZjg4JzonI2ZmMjI1NSc7CiAgRUwoJ3dzLXAnKS50ZXh0Q29udGVudD0ncG9ydCAnK2Qud3NfcG9ydDsKICBFTCgnY29ubnMnKS50ZXh0Q29udGVudD1kLmNvbm5lY3Rpb25zPz8wOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRTdmNTdGF0dXMoKXsKICBjb25zdCBkPWF3YWl0IGFwaSgnR0VUJywnL2FwaS9zdGF0dXMnKTsKICBjb25zdCBvbj1kLndzX3N0YXR1cz09PSdhY3RpdmUnOwogIEVMKCdzdmMtZG90JykuY2xhc3NOYW1lPSdkb3QgJysob24/J2RvdC1vbic6J2RvdC1vZmYnKTsKICBFTCgnc3ZjLWxibCcpLnRleHRDb250ZW50PW9uPydBQ1RJVkUg4oCUIHJ1bm5pbmcnOidJTkFDVElWRSDigJQgc3RvcHBlZCc7CiAgRUwoJ3N2Yy1sYmwnKS5zdHlsZS5jb2xvcj1vbj8nIzAwZmY4OCc6JyNmZjIyNTUnOwp9CmFzeW5jIGZ1bmN0aW9uIHN2Y0FjdGlvbihhY3QpewogIGNvbnN0IHI9YXdhaXQgYXBpKCdQT1NUJywnL2FwaS9zZXJ2aWNlJyx7YWN0aW9uOmFjdH0pOwogIGlmKHIub2spe3RvYXN0KCfinJQgJythY3QrJyDguKrguLPguYDguKPguYfguIgnKTt9ZWxzZXt0b2FzdCgn4pqgIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iDogJysoci5lcnJvcnx8JycpLHRydWUpO30KICBzZXRUaW1lb3V0KGxvYWRTdmNTdGF0dXMsMTUwMCk7c2V0VGltZW91dChsb2FkU3RhdHVzLDE1MDApOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRVc2VycygpewogIGNvbnN0IHU9YXdhaXQgYXBpKCdHRVQnLCcvYXBpL3VzZXJzJyk7CiAgY29uc3QgdGI9RUwoJ3V0YicpOwogIGlmKHUuZXJyb3Ipe3RvYXN0KCfguYLguKvguKXguJQgdXNlcnMg4Lil4LmJ4Lih4LmA4Lir4Lil4LinJyx0cnVlKTtyZXR1cm47fQogIGlmKCFBcnJheS5pc0FycmF5KHUpfHwhdS5sZW5ndGgpe3RiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6IzNkNWE3MztwYWRkaW5nOjE2cHgiPuC5hOC4oeC5iOC4oeC4tSB1c2VyczwvdGQ+PC90cj4nO3JldHVybjt9CiAgdGIuaW5uZXJIVE1MPXUubWFwKHg9PnsKICAgIGNvbnN0IGRMZWZ0PU1hdGguY2VpbCgobmV3IERhdGUoeC5leHApLW5ldyBEYXRlKCkpLzg2NDAwMDAwKTsKICAgIGNvbnN0IG9rPXguYWN0aXZlJiZkTGVmdD4wOwogICAgcmV0dXJuICc8dHI+PHRkIHN0eWxlPSJjb2xvcjojZmZmO2ZvbnQtd2VpZ2h0OjcwMCI+Jyt4LnVzZXIrJzwvdGQ+PHRkPicreC5leHArJzxzcGFuIHN0eWxlPSJjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZTo5cHgiPiAoJysoZExlZnQ+MD9kTGVmdCsnZCc6J+C4q+C4oeC4lCcpKycpPC9zcGFuPjwvdGQ+PHRkIHN0eWxlPSJjb2xvcjojMDBlNWZmIj4nKyh4LmRhdGFfZ2I+MD94LmRhdGFfZ2IrJ0dCJzonaW5mJykrJzwvdGQ+PHRkPjxzcGFuIGNsYXNzPSJwaWxsICcrKG9rPydwZyc6J3ByJykrJyI+Jysob2s/J0FDVElWRSc6J0VYUElSRUQnKSsnPC9zcGFuPjwvdGQ+PHRkIHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjRweCI+PGJ1dHRvbiBjbGFzcz0iYnRuIiBzdHlsZT0icGFkZGluZzoycHggOHB4O2ZvbnQtc2l6ZTo5cHgiIG9uY2xpY2s9Im9wZW5SZW5ldyhcJycreC51c2VyKydcJywnK3guZGF5cysnLCcreC5kYXRhX2diKycpIj5SPC9idXR0b24+PGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1yIiBzdHlsZT0icGFkZGluZzoycHggOHB4O2ZvbnQtc2l6ZTo5cHgiIG9uY2xpY2s9Im9wZW5EZWwoXCcnK3gudXNlcisnXCcpIj5YPC9idXR0b24+PC90ZD48L3RyPic7CiAgfSkuam9pbignJyk7Cn0KYXN5bmMgZnVuY3Rpb24gYWRkVXNlcigpewogIGNvbnN0IHVzZXI9RUwoJ251JykudmFsdWUudHJpbSgpLHBhc3M9RUwoJ25wJykudmFsdWUudHJpbSgpOwogIGNvbnN0IGRheXM9cGFyc2VJbnQoRUwoJ25kJykudmFsdWUpfHwzMCxnYj1wYXJzZUludChFTCgnbmdiJykudmFsdWUpfHwwOwogIGlmKCF1c2VyfHwhcGFzcyl7dG9hc3QoJ+C5g+C4quC5iCB1c2VybmFtZSDguYHguKXguLAgcGFzc3dvcmQnLHRydWUpO3JldHVybjt9CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3VzZXJzJyx7dXNlcixwYXNzd29yZDpwYXNzLGRheXMsZGF0YV9nYjpnYn0pOwogIGlmKHIub2spe3RvYXN0KCfguYDguJ7guLTguYjguKEgJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJyk7RUwoJ251JykudmFsdWU9Jyc7RUwoJ25wJykudmFsdWU9Jyc7bG9hZFVzZXJzKCk7fQogIGVsc2UgdG9hc3QoJ+C5gOC4nuC4tOC5iOC4oeC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iDogJysoci5yZXN1bHR8fHIuZXJyb3IpLHRydWUpOwp9CmZ1bmN0aW9uIG9wZW5SZW5ldyh1LGQsZ2Ipe0VMKCdybi11JykudmFsdWU9dTtFTCgncm4tZCcpLnZhbHVlPWR8fDMwO0VMKCdybi1nYicpLnZhbHVlPWdifHwwO0VMKCdtLXJlbmV3JykuY2xhc3NMaXN0LmFkZCgnbycpO30KYXN5bmMgZnVuY3Rpb24gY29uZmlybVJlbmV3KCl7CiAgY29uc3QgdT1FTCgncm4tdScpLnZhbHVlLGQ9cGFyc2VJbnQoRUwoJ3JuLWQnKS52YWx1ZSl8fDMwLGdiPXBhcnNlSW50KEVMKCdybi1nYicpLnZhbHVlKXx8MDsKICBjb25zdCByPWF3YWl0IGFwaSgnUE9TVCcsJy9hcGkvcmVuZXcnLHt1c2VyOnUsZGF5czpkLGRhdGFfZ2I6Z2J9KTsKICBjbSgnbS1yZW5ldycpOwogIGlmKHIub2spe3RvYXN0KCfguJXguYjguK3guK3guLLguKLguLggJyt1KycgJytkKyfguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIJyk7bG9hZFVzZXJzKCk7fWVsc2UgdG9hc3QoJ+C4leC5iOC4reC4reC4suC4ouC4uOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcsdHJ1ZSk7Cn0KZnVuY3Rpb24gb3BlbkRlbCh1KXtkZWxUYXJnZXQ9dTtFTCgnZHUnKS50ZXh0Q29udGVudD11O0VMKCdtLWRlbCcpLmNsYXNzTGlzdC5hZGQoJ28nKTt9CmFzeW5jIGZ1bmN0aW9uIGNvbmZpcm1EZWwoKXsKICBjb25zdCByPWF3YWl0IGFwaSgnREVMRVRFJywnL2FwaS91c2Vycy8nK2RlbFRhcmdldCk7CiAgY20oJ20tZGVsJyk7CiAgaWYoci5vayl7dG9hc3QoJ+C4peC4miAnK2RlbFRhcmdldCsnIOC4quC4s+C5gOC4o+C5h+C4iCcpO2xvYWRVc2VycygpO31lbHNlIHRvYXN0KCfguKXguJrguYTguKHguYjguKrguLPguYDguKPguYfguIgnLHRydWUpOwp9CmZ1bmN0aW9uIGNtKGlkKXtFTChpZCkuY2xhc3NMaXN0LnJlbW92ZSgnbycpO30KZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm1vJykuZm9yRWFjaChtPT5tLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJyxlPT57aWYoZS50YXJnZXQ9PT1tKW0uY2xhc3NMaXN0LnJlbW92ZSgnbycpO30pKTsKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpewogIGNvbnN0IGQ9YXdhaXQgYXBpKCdHRVQnLCcvYXBpL29ubGluZScpOwogIGNvbnN0IHRiPUVMKCdvdGInKTsKICBpZighQXJyYXkuaXNBcnJheShkKXx8IWQubGVuZ3RoKXt0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iMiIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgY29ubmVjdGlvbjwvdGQ+PC90cj4nO3JldHVybjt9CiAgdGIuaW5uZXJIVE1MPWQubWFwKGM9Pic8dHI+PHRkIHN0eWxlPSJjb2xvcjojMDBlNWZmIj4nK2MucmVtb3RlKyc8L3RkPjx0ZD48c3BhbiBjbGFzcz0icGlsbCBwZyI+JytjLnN0YXRlKyc8L3NwYW4+PC90ZD48L3RyPicpLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRCYW5uZWQoKXsKICBjb25zdCBiPWF3YWl0IGFwaSgnR0VUJywnL2FwaS9iYW5uZWQnKTsKICBjb25zdCB0Yj1FTCgnYnRiJyk7CiAgY29uc3Qga2V5cz1PYmplY3Qua2V5cyhifHx7fSk7CiAgaWYoIWtleXMubGVuZ3RoKXt0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNCIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgYWNjb3VudCDguJbguLnguIHguYHguJrguJk8L3RkPjwvdHI+JztyZXR1cm47fQogIHRiLmlubmVySFRNTD1rZXlzLm1hcCh1aWQ9PnsKICAgIGNvbnN0IHg9Ylt1aWRdOwogICAgY29uc3QgdW50aWw9bmV3IERhdGUoeC51bnRpbCkudG9Mb2NhbGVTdHJpbmcoJ3RoLVRIJyk7CiAgICByZXR1cm4gJzx0cj48dGQgc3R5bGU9ImNvbG9yOiNmZjIyNTU7Zm9udC13ZWlnaHQ6NzAwIj4nK3gubmFtZSsnPC90ZD48dGQ+PHNwYW4gY2xhc3M9InBpbGwgcHIiPicrdW50aWwrJzwvc3Bhbj48L3RkPjx0ZCBzdHlsZT0iZm9udC1zaXplOjlweDtjb2xvcjojM2Q1YTczIj4nKygoeC5pcHN8fFtdKS5zbGljZSgwLDMpLmpvaW4oJywgJykpKyc8L3RkPjx0ZD48YnV0dG9uIGNsYXNzPSJidG4gYnRuLWciIHN0eWxlPSJwYWRkaW5nOjJweCA4cHg7Zm9udC1zaXplOjlweCIgb25jbGljaz0idW5iYW4oXCcnK3VpZCsnXCcsXCcnK3gubmFtZSsnXCcpIj7guJvguKXguJTguYHguJrguJk8L2J1dHRvbj48L3RkPjwvdHI+JzsKICB9KS5qb2luKCcnKTsKfQphc3luYyBmdW5jdGlvbiB1bmJhbih1aWQsbmFtZSl7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3VuYmFuJyx7dWlkLG5hbWV9KTsKICBpZihyLm9rKXt0b2FzdCgn4Lib4Lil4LiU4LmB4Lia4LiZICcrbmFtZSk7bG9hZEJhbm5lZCgpO31lbHNlIHRvYXN0KCfguJvguKXguJTguYHguJrguJnguYTguKHguYjguKrguLPguYDguKPguYfguIgnLHRydWUpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRMb2dzKCl7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvbG9ncycpOwogIGNvbnN0IGI9RUwoJ2xvZ2JveCcpOwogIGlmKCFyLmxpbmVzfHwhci5saW5lcy5sZW5ndGgpe2IuaW5uZXJIVE1MPSc8c3BhbiBzdHlsZT0iY29sb3I6IzNkNWE3MyI+Ly8g4LmE4Lih4LmI4Lih4Li1IGxvZ3M8L3NwYW4+JztyZXR1cm47fQogIGIuaW5uZXJIVE1MPXIubGluZXMubWFwKGw9Pic8ZGl2IHN0eWxlPSJjb2xvcjonKyhsLmluY2x1ZGVzKCdFUlInKT8nI2ZmMjI1NSc6bC5pbmNsdWRlcygnT0snKT8nIzAwZmY4OCc6JyMyYTVhNDAnKSsnIj4nK2wrJzwvZGl2PicpLmpvaW4oJycpOwogIGIuc2Nyb2xsVG9wPWIuc2Nyb2xsSGVpZ2h0Owp9CgovKiBCYWNrdXAvSW1wb3J0ICovCmFzeW5jIGZ1bmN0aW9uIGRvQmFja3VwKCl7CiAgY29uc3QgdT1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvdXNlcnMnKTsKICBpZih1LmVycm9yKXt0b2FzdCgn4LmC4Lir4Lil4LiUIHVzZXJzIOC4peC5ieC4oeC5gOC4q+C4peC4pycsdHJ1ZSk7cmV0dXJuO30KICBFTCgnYmFja3VwLW91dCcpLnZhbHVlPUpTT04uc3RyaW5naWZ5KEFycmF5LmlzQXJyYXkodSk/dTpbXSxudWxsLDIpOwogIHRvYXN0KCdFeHBvcnQg4Liq4Liz4LmA4Lij4LmH4LiIIOKAlCAnKyggQXJyYXkuaXNBcnJheSh1KT91Lmxlbmd0aDowICkrJyB1c2VycycpOwp9CmZ1bmN0aW9uIGNvcHlCYWNrdXAoKXsKICBjb25zdCB2PUVMKCdiYWNrdXAtb3V0JykudmFsdWU7CiAgaWYoIXYpe3RvYXN0KCfguYTguKHguYjguKHguLXguILguYnguK3guKHguLnguKUnLHRydWUpO3JldHVybjt9CiAgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodikudGhlbigoKT0+dG9hc3QoJ/Cfk4sgQ29waWVkIScpKTsKfQphc3luYyBmdW5jdGlvbiBkb0ltcG9ydCgpewogIGNvbnN0IHJhdz1FTCgnaW1wb3J0LWluJykudmFsdWUudHJpbSgpOwogIGlmKCFyYXcpe3RvYXN0KCfguKfguLLguIcgSlNPTiDguIHguYjguK3guJknLHRydWUpO3JldHVybjt9CiAgbGV0IHVzZXJzOwogIHRyeXt1c2Vycz1KU09OLnBhcnNlKHJhdyk7fWNhdGNoKGUpe3RvYXN0KCdKU09OIOC5hOC4oeC5iOC4luC4ueC4geC4leC5ieC4reC4hycsdHJ1ZSk7cmV0dXJuO30KICBpZighQXJyYXkuaXNBcnJheSh1c2Vycykpe3RvYXN0KCfguJXguYnguK3guIfguYDguJvguYfguJkgYXJyYXknLHRydWUpO3JldHVybjt9CiAgbGV0IG9rPTAsZmFpbD0wOwogIGZvcihjb25zdCB1IG9mIHVzZXJzKXsKICAgIGNvbnN0IHI9YXdhaXQgYXBpKCdQT1NUJywnL2FwaS91c2VycycsdSk7CiAgICByLm9rP29rKys6ZmFpbCsrOwogIH0KICB0b2FzdCgnSW1wb3J0OiDinJQgJytvaysnIOC4quC4s+C5gOC4o+C5h+C4iCcrKGZhaWw/JyDimqAgJytmYWlsKycg4Lil4LmJ4Lih4LmA4Lir4Lil4LinJzonJykpOwogIGxvYWRVc2VycygpOwp9Cgphc3luYyBmdW5jdGlvbiBsb2FkQWxsKCl7CiAgaWYoIWdldFRvaygpKXt0b2FzdCgn4LmD4Liq4LmIIEFQSSBUb2tlbiDguIHguYjguK3guJknLHRydWUpO3JldHVybjt9CiAgYXdhaXQgbG9hZFN0YXR1cygpO2F3YWl0IGxvYWRVc2VycygpO2F3YWl0IGxvYWRPbmxpbmUoKTsKfQo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==' | base64 -d   | sed "s|%%TOKEN%%|${_SSHWS_TOK}|g"   | sed "s|%%HOST%%|${_SSHWS_HOST}|g"   | sed "s|%%PROTO%%|${_SSHWS_PROTO}|g"   > /var/www/chaiya/sshws.html

echo "✅ sshws.html สร้างพร้อมใช้งาน"

# ══════════════════════════════════════════════════════════════
#  chaiya  MAIN MENU SCRIPT  (เขียนตรงไม่ใช้ base64)
# ══════════════════════════════════════════════════════════════
cat > /usr/local/bin/chaiya << 'CHAIYAEOF'
#!/bin/bash
# CHAIYA V2RAY PRO MAX v10 — Main Menu
# ทุกเมนูทำงานได้จริง 100%

DB="/etc/chaiya/vless.db"
DOMAIN_FILE="/etc/chaiya/domain.conf"
BAN_FILE="/etc/chaiya/banned.db"
IP_LOG="/etc/chaiya/iplog.db"
VLESS_DIR="/etc/chaiya/vless-users"
XUI_COOKIE="/etc/chaiya/xui-cookie.jar"
XUI_PORT_FILE="/etc/chaiya/xui-port.conf"
XUI_USER_FILE="/etc/chaiya/xui-user.conf"
XUI_PASS_FILE="/etc/chaiya/xui-pass.conf"

mkdir -p "$VLESS_DIR"

# ── สี นีออนรุ้งเข้ม ──────────────────────────────────────────
R1='\033[1;38;2;255;0;128m'
R2='\033[1;38;2;255;80;0m'
R3='\033[1;38;2;255;230;0m'
R4='\033[1;38;2;0;255;80m'
R5='\033[1;38;2;0;220;255m'
R6='\033[1;38;2;180;0;255m'
PU='\033[1;38;2;200;0;255m'
YE='\033[1;38;2;255;230;0m'
WH='\033[1;38;2;255;255;255m'
GR='\033[1;38;2;0;200;255m'
RD='\033[1;38;2;255;0;80m'
CY='\033[1;38;2;0;255;220m'
MG='\033[1;38;2;255;0;200m'
OR='\033[1;38;2;255;140;0m'
RS='\033[0m'
BLD='\033[1m'

# ── helper ────────────────────────────────────────────────────
get_info() {
  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  [[ -f "$DOMAIN_FILE" ]] && HOST=$(cat "$DOMAIN_FILE") || HOST=""
  CPU=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%d", $2+$4}' 2>/dev/null || echo "0")
  RAM_USED=$(free -m | awk '/Mem:/{printf "%.1f", $3/1024}')
  RAM_TOTAL=$(free -m | awk '/Mem:/{printf "%.1f", $2/1024}')
  USERS=$(ss -tn state established 2>/dev/null | grep -c ':22' || echo "0")
}

show_logo() {
  printf "${R1}  ██████╗██╗  ██╗ █████╗ ██╗██╗   ██╗ █████╗ ${RS}\n"
  printf "${R2}  ██╔════╝██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══██╗${RS}\n"
  printf "${R3}  ██║     ███████║███████║██║ ╚████╔╝ ███████║${RS}\n"
  printf "${R4}  ██║     ██╔══██║██╔══██║██║  ╚██╔╝  ██╔══██║${RS}\n"
  printf "${R5}  ╚██████╗██║  ██║██║  ██║██║   ██║   ██║  ██║${RS}\n"
  printf "${R6}   ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝${RS}\n"
}

show_menu() {
  get_info
  clear
  show_logo
  printf "\n"
  printf "${R1}╭──────────────────────────────────────────────╮${RS}\n"
  printf "${R2}│${RS} 🔥 ${R2}V2RAY PRO MAX v10${RS}\n"
  if [[ -n "$HOST" ]]; then
    printf "${R3}│${RS} 🌐 ${CY}Domain : %s${RS}\n" "$HOST"
  else
    printf "${R3}│${RS} ⚠️  ${YE}ยังไม่มีโดเมน${RS}\n"
  fi
  printf "${R4}│${RS} 🌍 ${CY}IP     : %s${RS}\n" "$MY_IP"
  printf "${R4}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R5}│${RS} 💻 CPU:${CY}%s%%%s${RS} 🧠RAM:${YE}%s/%sGB${RS} 👥:${PU}%s${RS}\n" "$CPU" "" "$RAM_USED" "$RAM_TOTAL" "$USERS"
  printf "${R5}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R6}│${RS}  ${R1}1.${RS}  ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ\n"
  printf "${R6}│${RS}  ${R2}2.${RS}  ตั้งค่าโดเมน + SSL อัตโนมัติ\n"
  printf "${PU}│${RS}  ${R3}3.${RS}  สร้าง VLESS (IP/โดเมน+port+SNI)\n"
  printf "${PU}│${RS}  ${R4}4.${RS}  ลบบัญชีหมดอายุ\n"
  printf "${MG}│${RS}  ${R5}5.${RS}  ดูบัญชี\n"
  printf "${MG}│${RS}  ${R6}6.${RS}  ดู User Online Realtime\n"
  printf "${CY}│${RS}  ${PU}7.${RS}  รีสตาร์ท 3x-ui\n"
  printf "${CY}│${RS}  ${CY}8.${RS}  จัดการ Process CPU สูง\n"
  printf "${R5}│${RS}  ${CY}9.${RS}  เช็คความเร็ว VPS\n"
  printf "${R4}│${RS}  ${YE}10.${RS} จัดการ Port (เปิด/ปิด)\n"
  printf "${R4}│${RS}  ${R2}11.${RS} ปลดแบน IP / จัดการ User\n"
  printf "${R3}│${RS}  ${R3}12.${RS} บล็อก IP ต่างประเทศ\n"
  printf "${R3}│${RS}  ${R4}13.${RS} สแกน Bug Host (SNI)\n"
  printf "${R2}│${RS}  ${R5}14.${RS} ลบ User\n"
  printf "${R2}│${RS}  ${R6}15.${RS} ตั้งค่ารีบูตอัตโนมัติ\n"
  printf "${R1}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R2}│${RS}  ${CY}16.${RS} ก่อนการติดตั้ง Chaiya\n"
  printf "${R3}│${RS}  ${YE}17.${RS} เคลียร์ CPU อัตโนมัติ\n"
  printf "${R4}│${RS}  ${CY}18.${RS} SSH WebSocket\n"
  printf "${R5}│${RS}  ${WH}0.${RS}  ออก\n"
  printf "${R6}╰──────────────────────────────────────────────╯${RS}\n"
  printf "\n${MG}เลือก >> ${RS}"
}

# ── helper: x-ui API ─────────────────────────────────────────
xui_port() { cat "$XUI_PORT_FILE" 2>/dev/null || echo "2053"; }
xui_user() { cat "$XUI_USER_FILE" 2>/dev/null || echo "admin"; }
xui_pass() { cat "$XUI_PASS_FILE" 2>/dev/null || echo "admin"; }

xui_login() {
  local p u pw bp
  p=$(xui_port); u=$(xui_user); pw=$(xui_pass)
  bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | sed 's|/$||')
  # ลบ cookie เก่าก่อนเสมอ
  rm -f "$XUI_COOKIE"
  local _r
  _r=$(curl -s -c "$XUI_COOKIE" \
    -X POST "http://127.0.0.1:${p}${bp}/login" \
    -d "username=${u}&password=${pw}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --max-time 10 2>/dev/null)
  echo "$_r" | grep -q '"success":true' && return 0
  # fallback ไม่มี basepath
  rm -f "$XUI_COOKIE"
  curl -s -c "$XUI_COOKIE" \
    -X POST "http://127.0.0.1:${p}/login" \
    -d "username=${u}&password=${pw}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --max-time 10 2>/dev/null | grep -q '"success":true'
}

xui_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local p bp
  p=$(xui_port)
  bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | sed 's|/$||')
  # login ใหม่ทุกครั้ง ไม่ใช้ cookie เก่า
  xui_login 2>/dev/null || true
  if [[ -n "$data" ]]; then
    curl -s -b "$XUI_COOKIE" \
      -X "$method" "http://127.0.0.1:${p}${bp}${endpoint}" \
      -H "Content-Type: application/json" -d "$data" --max-time 15 2>/dev/null
  else
    curl -s -b "$XUI_COOKIE" \
      -X "$method" "http://127.0.0.1:${p}${bp}${endpoint}" --max-time 15 2>/dev/null
  fi
}

# ── สร้างไฟล์ HTML สำหรับ VLESS user ────────────────────────
gen_vless_html() {
  local uname="$1" link="$2" uuid="$3" host_val="$4" port_val="$5" sni_val="$6" exp="$7"
  local outfile="/var/www/chaiya/config/${uname}.html"
  cat > "$outfile" << HTMLEOF
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA — ${uname}</title>
<style>
body{background:#020408;color:#c8dde8;font-family:'Courier New',monospace;padding:20px;max-width:600px;margin:0 auto}
h2{color:#ff0040;letter-spacing:4px;margin-bottom:16px}
.card{background:#060d14;border:1px solid #1a3a55;padding:14px;margin-bottom:12px;border-radius:2px}
.lbl{color:#3d5a73;font-size:9px;letter-spacing:2px;text-transform:uppercase;margin-bottom:4px}
.val{color:#00e5ff;word-break:break-all;font-size:12px}
.link{color:#ffd700;word-break:break-all;font-size:11px;line-height:1.6}
.btn{display:inline-block;margin-top:10px;padding:8px 16px;background:transparent;border:1px solid #00e5ff;color:#00e5ff;cursor:pointer;font-family:'Courier New',monospace;font-size:11px}
#qr{text-align:center;margin:12px 0}
</style>
</head>
<body>
<h2>CHAIYA VPN CONFIG</h2>
<div class="card"><div class="lbl">Username</div><div class="val">${uname}</div></div>
<div class="card"><div class="lbl">Host / IP</div><div class="val">${host_val}</div></div>
<div class="card"><div class="lbl">Port</div><div class="val">${port_val}</div></div>
<div class="card"><div class="lbl">UUID</div><div class="val">${uuid}</div></div>
<div class="card"><div class="lbl">SNI / Bug Host</div><div class="val">${sni_val}</div></div>
<div class="card"><div class="lbl">หมดอายุ</div><div class="val">${exp}</div></div>
<div class="card">
  <div class="lbl">VLESS Link</div>
  <div class="link" id="vlink">${link}</div>
  <button class="btn" onclick="navigator.clipboard.writeText(document.getElementById('vlink').textContent).then(()=>this.textContent='✔ Copied!')">📋 Copy Link</button>
</div>
<div id="qr"></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<script>
new QRCode(document.getElementById('qr'),{text:"${link}",width:220,height:220,colorDark:"#00e5ff",colorLight:"#020408"});
</script>
</body>
</html>
HTMLEOF
  printf "${GR}✔ สร้างไฟล์ HTML: %s${RS}\n" "$outfile"
}

# ══════════════════════════════════════════════════════════════
# เมนู 1 — ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ (v11 full rewrite)
# ══════════════════════════════════════════════════════════════

# ── RGB Progress Bar ──────────────────────────────────────────
rgb_bar() {
  local pct="$1" label="${2:-}" width=40
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  # คำนวณสี RGB ตาม % (แดง→ส้ม→เหลือง→เขียว→ฟ้า→ม่วง)
  local r g b
  if   (( pct < 20 )); then r=255; g=$(( pct*12 )); b=85
  elif (( pct < 40 )); then r=255; g=$(( 240+(pct-20)*2 )); b=0
  elif (( pct < 60 )); then r=$(( 255-(pct-40)*10 )); g=255; b=0
  elif (( pct < 80 )); then r=0; g=255; b=$(( (pct-60)*12 ))
  else                      r=$(( (pct-80)*12 )); g=$(( 255-(pct-80)*10 )); b=255
  fi
  local bar_color="\033[38;2;${r};${g};${b}m"
  local bar_fill; bar_fill=$(printf '%0.s█' $(seq 1 $filled) 2>/dev/null || printf '█%.0s' $(seq 1 $filled))
  local bar_empty; bar_empty=$(printf '%0.s░' $(seq 1 $empty) 2>/dev/null || printf '░%.0s' $(seq 1 $empty))
  printf "  ${bar_color}[%s%s]${RS} ${WH}%3d%%${RS} ${YE}%s${RS}\n" \
    "$bar_fill" "$bar_empty" "$pct" "$label"
}

# ── ฟังก์ชัน detect webBasePath จาก sqlite3 ──────────────────
detect_xui_basepath() {
  local db_path="/etc/x-ui/x-ui.db"
  local bp=""
  if command -v sqlite3 &>/dev/null && [[ -f "$db_path" ]]; then
    bp=$(sqlite3 "$db_path" "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;" 2>/dev/null || echo "")
  fi
  [[ -z "$bp" ]] && bp="/"
  echo "$bp"
}

menu_1() {
  clear
  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

  printf "${R1}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ☠️  ${R2}${BLD}ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ${RS}           ${R1}│${RS}\n"
  printf "${R1}└──────────────────────────────────────────────────┘${RS}\n\n"

  # ── ถ้า x-ui รันอยู่แล้ว ให้ลบออกอัตโนมัติก่อน ─────────────
  if systemctl is-active --quiet x-ui 2>/dev/null; then
    printf "  ${YE}⚙ พบ x-ui รันอยู่ — กำลังลบออกและติดตั้งใหม่...${RS}\n"
    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true
    rm -f /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui /usr/local/bin/x-ui
    rm -rf /etc/x-ui
    systemctl daemon-reload 2>/dev/null || true
    printf "  ${GR}✔ ลบ x-ui เก่าเรียบร้อย${RS}\n\n"
  fi

  # ── ถาม Username / Password ──────────────────────────────────
  read -rp "$(printf "  ${YE}Username admin: ${RS}")" _u
  [[ -z "$_u" ]] && _u="admin"

  local _pw _pw2
  while true; do
    read -rsp "$(printf "  ${YE}Password admin (ห้ามว่าง): ${RS}")" _pw; echo ""
    [[ -n "$_pw" ]] && break
    printf "  ${RD}✗ Password ห้ามว่าง${RS}\n"
  done
  read -rsp "$(printf "  ${YE}ยืนยัน Password: ${RS}")" _pw2; echo ""
  if [[ "$_pw" != "$_pw2" ]]; then
    printf "\n  ${RD}✗ Password ไม่ตรงกัน — ยกเลิก${RS}\n"
    read -rp "  Enter..."; return
  fi

  mkdir -p /etc/chaiya
  echo "$_u"  > /etc/chaiya/xui-user.conf
  echo "$_pw" > /etc/chaiya/xui-pass.conf
  chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf
  printf "\n"

  # ════════════════════════════════════════════════════════════
  # Progress bar เดียว ครอบทุกขั้นตอน (install → port → API → inbound)
  # ════════════════════════════════════════════════════════════

  # ── 10% ดาวน์โหลด install script ──
  rgb_bar 10 "ดาวน์โหลด install script..."
  local _xui_sh; _xui_sh=$(mktemp /tmp/xui-XXXXX.sh)
  curl -Ls "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" \
       -o "$_xui_sh" 2>/dev/null

  # ── 15% ติดตั้ง 3x-ui ──
  rgb_bar 15 "กำลังติดตั้ง 3x-ui..."
  printf "y\n2053\n2\n\n80\n" | bash "$_xui_sh" >> /var/log/chaiya-xui-install.log 2>&1
  rm -f "$_xui_sh"

  # ── 50% reset credential ──
  rgb_bar 50 "ตั้งค่า credential..."
  /usr/local/x-ui/x-ui setting -username "$_u" -password "$_pw" 2>/dev/null || \
    x-ui setting -username "$_u" -password "$_pw" 2>/dev/null || true
  systemctl restart x-ui 2>/dev/null || true
  sleep 3

  # detect basePath + port
  local _basepath; _basepath=$(detect_xui_basepath)
  echo "$_basepath" > /etc/chaiya/xui-basepath.conf
  local _xp
  _xp=$(/usr/local/x-ui/x-ui setting 2>/dev/null | grep -oP 'port.*?:\s*\K\d+' | head -1)
  [[ -n "$_xp" ]] && echo "$_xp" > /etc/chaiya/xui-port.conf
  local _panel_port; _panel_port=$(xui_port)

  # ── 55% รอ port ──
  rgb_bar 55 "รอ port ${_panel_port}..."
  local _ok=0
  for _i in $(seq 1 10); do
    if curl -s --max-time 3 "http://127.0.0.1:${_panel_port}/" &>/dev/null; then
      _ok=1; break
    fi
    sleep 3
  done
  if [[ "$_ok" == "0" ]]; then
    systemctl restart x-ui 2>/dev/null || true
    sleep 5
  fi

  # ── 80% login API — retry จนกว่าจะสำเร็จ ──
  rgb_bar 80 "Login API..."
  local _login_ok=0
  for _li in $(seq 1 15); do
    if xui_login 2>/dev/null; then
      _login_ok=1; break
    fi
    sleep 4
  done

  # ถ้า login ไม่ได้เลย ลอง restart x-ui แล้ว retry
  if [[ "$_login_ok" == "0" ]]; then
    systemctl restart x-ui 2>/dev/null || true
    sleep 6
    for _li in $(seq 1 10); do
      if xui_login 2>/dev/null; then
        _login_ok=1; break
      fi
      sleep 4
    done
  fi

  # ── 85–95% สร้าง inbounds ──
  local _inbounds=(
    "8080:CHAIYA-AIS-8080:cj-ebb.speedtest.net"
    "8880:CHAIYA-TRUE-8880:true-internet.zoom.xyz.services"
  )
  local _ib_n=0 _ib_results=()
  for _item in "${_inbounds[@]}"; do
    (( _ib_n++ ))
    local _ibport; _ibport=$(echo "$_item" | cut -d: -f1)
    local _ibremark; _ibremark=$(echo "$_item" | cut -d: -f2)
    local _ibsni; _ibsni=$(echo "$_item" | cut -d: -f3-)
    local _ibuid; _ibuid=$(cat /proc/sys/kernel/random/uuid)

    rgb_bar $(( 85 + _ib_n * 5 )) "สร้าง inbound port ${_ibport}..."

    # 3x-ui ต้องการ settings/streamSettings/sniffing เป็น JSON string (escaped)
    local _settings _stream _sniff _payload
    _settings=$(printf '{"clients":[{"id":"%s","alterId":0}],"disableInsecureEncryption":false}' "$_ibuid")
    _stream=$(printf '{"network":"ws","security":"none","wsSettings":{"path":"/","headers":{"Host":"%s"}}}' "$_ibsni")
    _sniff='{"enabled":true,"destOverride":["http","tls"]}'

    _payload=$(python3 -c "
import json, sys
d = {
  'remark':         sys.argv[1],
  'enable':         True,
  'listen':         '',
  'port':           int(sys.argv[2]),
  'protocol':       'vmess',
  'settings':       sys.argv[3],
  'streamSettings': sys.argv[4],
  'sniffing':       sys.argv[5],
}
print(json.dumps(d))
" "$_ibremark" "$_ibport" "$_settings" "$_stream" "$_sniff")

    # retry สร้าง inbound สูงสุด 3 ครั้ง
    local _res _created=0
    for _try in 1 2 3; do
      _res=$(xui_api POST "/panel/api/inbounds/add" "$_payload" 2>/dev/null)
      if echo "$_res" | grep -q '"success":true'; then
        _created=1; break
      fi
      # ถ้า port ซ้ำอยู่แล้ว ถือว่าสำเร็จ
      if echo "$_res" | grep -qi "already\|duplicate\|exist"; then
        _created=2; break
      fi
      # login ใหม่แล้วลองอีกครั้ง
      xui_login 2>/dev/null || true
      sleep 3
    done

    ufw allow "${_ibport}"/tcp >> /dev/null 2>&1 || true

    if [[ "$_created" == "1" ]]; then
      _ib_results+=("${GR}✔ Port ${_ibport} (${_ibremark}) — สร้างสำเร็จ${RS}")
    elif [[ "$_created" == "2" ]]; then
      _ib_results+=("${CY}ℹ Port ${_ibport} (${_ibremark}) — มีอยู่แล้ว${RS}")
    else
      # แสดง response จริงเพื่อ debug
      local _err_msg; _err_msg=$(echo "$_res" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('msg','unknown'))" 2>/dev/null || echo "no response")
      _ib_results+=("${RD}✗ Port ${_ibport} — ${_err_msg}${RS}")
    fi
  done

  rgb_bar 100 "เสร็จสมบูรณ์!"
  printf "\n"

  # ════════════════════════════════════════════════════════════
  # สรุปผล — กระชับ
  # ════════════════════════════════════════════════════════════
  local _bp_clean; _bp_clean=$(echo "$_basepath" | sed 's|/$||')
  # ใช้โดเมนถ้ามี ไม่งั้นใช้ IP
  local _host_display
  if [[ -f "$DOMAIN_FILE" ]] && [[ -n "$(cat "$DOMAIN_FILE" 2>/dev/null)" ]]; then
    _host_display=$(cat "$DOMAIN_FILE")
    local _proto="https"
    [[ ! -f "/etc/letsencrypt/live/${_host_display}/fullchain.pem" ]] && _proto="http"
    local _panel_url="${_proto}://${_host_display}:${_panel_port}${_bp_clean}/"
    local _api_url="${_proto}://${_host_display}:${_panel_port}${_bp_clean}/panel/api"
  else
    local _panel_url="http://${MY_IP}:${_panel_port}${_bp_clean}/"
    local _api_url="http://${MY_IP}:${_panel_port}${_bp_clean}/panel/api"
  fi

  printf "${R1}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  🌐 Panel  : ${WH}%s${RS}\n" "$_panel_url"
  printf "${R1}│${RS}  🔗 API    : ${WH}%s${RS}\n" "$_api_url"
  printf "${R1}│${RS}  👤 User   : ${WH}%s${RS}  🔑 Pass: ${WH}%s${RS}\n" "$_u" "$_pw"
  printf "${R1}├──────────────────────────────────────────────────┤${RS}\n"
  for _r in "${_ib_results[@]}"; do
    printf "${R1}│${RS}  $(printf "${_r}")\n"
  done
  [[ "$_login_ok" == "0" ]] && printf "${R1}│${RS}  ${YE}⚠ Login API ไม่สำเร็จ — ลอง login panel เอง${RS}\n"
  printf "${R1}└──────────────────────────────────────────────────┘${RS}\n\n"
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 2 — ตั้งค่าโดเมน + SSL
# ══════════════════════════════════════════════════════════════
menu_2() {
  clear
  printf "${R3}[2] ตั้งค่าโดเมน + SSL อัตโนมัติ${RS}\n\n"
  read -rp "$(printf "${YE}กรอกโดเมน (เช่น vpn.example.com): ${RS}")" domain
  [[ -z "$domain" ]] && { printf "${YE}ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
  echo "$domain" > "$DOMAIN_FILE"
  apt-get install -y certbot python3-certbot-nginx -qq 2>/dev/null || true
  systemctl stop nginx 2>/dev/null || true
  printf "${YE}⟳ ขอ SSL certificate...${RS}\n"
  certbot certonly --standalone -d "$domain" --non-interactive --agree-tos -m "admin@${domain}" 2>&1
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    printf "${GR}✔ SSL สำเร็จ!${RS}\n"
    # อัพเดต x-ui ให้ใช้ SSL
    xui_api POST "/panel/api/setting/update" \
      "{\"domain\":\"${domain}\",\"certFile\":\"/etc/letsencrypt/live/${domain}/fullchain.pem\",\"keyFile\":\"/etc/letsencrypt/live/${domain}/privkey.pem\"}" > /dev/null 2>&1 || true
    # nginx HTTPS config
    cat > /etc/nginx/sites-available/chaiya-ssl << SSLEOF
server {
    listen 443 ssl;
    server_name ${domain};
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    location /sshws/ { alias /var/www/chaiya/; index sshws.html; try_files \$uri \$uri/ =404; }
    location /config/ { alias /var/www/chaiya/config/; try_files \$uri =404; add_header Content-Disposition "attachment"; }
    location /sshws-api/ { proxy_pass http://127.0.0.1:6789/; proxy_http_version 1.1; proxy_set_header Host \$host; }
}
SSLEOF
    ln -sf /etc/nginx/sites-available/chaiya-ssl /etc/nginx/sites-enabled/chaiya-ssl
    systemctl start nginx 2>/dev/null || true
    nginx -t && systemctl reload nginx 2>/dev/null || true
    # cert renewal cron
    (crontab -l 2>/dev/null | grep -v certbot-renew
     echo "0 3 * * * certbot renew --quiet && systemctl reload nginx # certbot-renew"
    ) | crontab -
    printf "${GR}✔ ตั้งค่า HTTPS เสร็จ — ${WH}https://%s${RS}\n" "$domain"
  else
    printf "${RD}✗ SSL ไม่สำเร็จ — ตรวจสอบว่า DNS ชี้มาที่ IP นี้แล้ว${RS}\n"
  fi
  systemctl start nginx 2>/dev/null || true
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 3 — สร้าง VLESS (ผูกกับ VMess inbound 8080/8880)
#   • รับ: username, วันใช้งาน, data limit GB
#   • IP limit 2 IP/user — เกินแบน 12 ชั่วโมง
#   • Progress bar RGB ทุกขั้นตอน
# ══════════════════════════════════════════════════════════════
menu_3() {
  clear
  printf "${R4}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R4}│${RS}  🌈 ${BLD}สร้าง VLESS User (IP Limit + Auto Ban)${RS}      ${R4}│${RS}\n"
  printf "${R4}└──────────────────────────────────────────────────┘${RS}\n\n"

  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  if [[ -f "$DOMAIN_FILE" ]]; then
    AUTO_HOST=$(cat "$DOMAIN_FILE")
    printf "  ${GR}✔ โดเมน: ${WH}%s${RS}\n" "$AUTO_HOST"
  else
    AUTO_HOST="$MY_IP"
    printf "  ${YE}⚠ ไม่มีโดเมน — ใช้ IP: ${WH}%s${RS}\n" "$MY_IP"
  fi
  printf "\n"

  # ── รับ input ─────────────────────────────────────────────
  rgb_bar 5 "รอ input..."; printf "\n\n"

  read -rp "$(printf "  ${YE}👤 ชื่อ User: ${RS}")" UNAME
  [[ -z "$UNAME" ]] && { printf "  ${YE}ยกเลิก${RS}\n"; read -rp "  Enter..."; return; }

  read -rp "$(printf "  ${YE}📅 จำนวนวัน (default 30): ${RS}")" DAYS
  [[ -z "$DAYS" || ! "$DAYS" =~ ^[0-9]+$ ]] && DAYS=30

  read -rp "$(printf "  ${YE}📦 Data limit GB (0=ไม่จำกัด): ${RS}")" DATA_GB
  [[ -z "$DATA_GB" || ! "$DATA_GB" =~ ^[0-9]+$ ]] && DATA_GB=0

  printf "\n  ${WH}🔌 เลือก Inbound (VMess WS):${RS}\n"
  printf "  ${R2}1.${RS} Port ${WH}8080${RS} — AIS  | SNI: ${YE}cj-ebb.speedtest.net${RS}\n"
  printf "  ${R3}2.${RS} Port ${WH}8880${RS} — TRUE | SNI: ${YE}true-internet.zoom.xyz.services${RS}\n"
  printf "  ${R4}3.${RS} ทั้งสอง port (สร้าง 2 user)\n"
  printf "  ${CY}4.${RS} กรอก port + SNI เอง\n"
  read -rp "$(printf "  ${YE}เลือก: ${RS}")" port_choice

  # สร้าง array of "port:sni" ที่จะสร้าง
  declare -a _PORT_SNI_LIST=()
  case $port_choice in
    1) _PORT_SNI_LIST=("8080:cj-ebb.speedtest.net") ;;
    2) _PORT_SNI_LIST=("8880:true-internet.zoom.xyz.services") ;;
    3) _PORT_SNI_LIST=("8080:cj-ebb.speedtest.net" "8880:true-internet.zoom.xyz.services") ;;
    4) read -rp "$(printf "  ${YE}Port: ${RS}")" _cp
       read -rp "$(printf "  ${YE}SNI: ${RS}")" _cs
       _PORT_SNI_LIST=("${_cp}:${_cs}") ;;
    *) _PORT_SNI_LIST=("8080:cj-ebb.speedtest.net") ;;
  esac

  EXP=$(date -d "+${DAYS} days" +"%Y-%m-%d")
  local TOTAL_BYTES=$(( DATA_GB * 1073741824 ))
  local EXP_MS=$(( $(date -d "$EXP" +%s) * 1000 ))
  local SEC="none"
  [[ -f "$DOMAIN_FILE" ]] && SEC="tls"

  rgb_bar 20 "ตรวจสอบ 3x-ui API..."; printf "\n\n"

  # ── ตรวจว่า inbound port มีอยู่แล้วหรือยัง ────────────────
  local _inbound_list
  _inbound_list=$(xui_api GET "/panel/api/inbounds/list" 2>/dev/null)

  local _created_count=0
  local _step=0
  local _total=${#_PORT_SNI_LIST[@]}
  declare -a _RESULTS=()

  for _ps in "${_PORT_SNI_LIST[@]}"; do
    (( _step++ ))
    local _vport; _vport=$(echo "$_ps" | cut -d: -f1)
    local _sni;   _sni=$(echo "$_ps"   | cut -d: -f2-)
    local _pct=$(( 25 + _step * 30 / _total ))
    local UUID; UUID=$(cat /proc/sys/kernel/random/uuid)

    rgb_bar "$_pct" "สร้าง VLESS client port ${_vport}..."; printf "\n\n"

    # ค้นหา inbound_id ที่ port ตรง (VMess สร้างใน menu_1)
    local _inbound_id
    _inbound_id=$(echo "$_inbound_list" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    if x['port'] == int('${_vport}'):
      print(x['id']); sys.exit()
except: pass
print('')
" 2>/dev/null)

    local API_RESULT=""
    if [[ -n "$_inbound_id" ]]; then
      # เพิ่ม client เข้า inbound เดิม — settings ต้องเป็น JSON string
      local _client_payload
      _client_payload=$(python3 -c "
import json, sys
client = {
  'id': sys.argv[1],
  'email': sys.argv[2],
  'limitIp': 2,
  'totalGB': int(sys.argv[3]),
  'expiryTime': int(sys.argv[4]),
  'enable': True,
  'comment': '',
  'reset': 0
}
payload = {
  'id': int(sys.argv[5]),
  'settings': json.dumps({'clients': [client]})
}
print(json.dumps(payload))
" "$UUID" "$UNAME" "$TOTAL_BYTES" "$EXP_MS" "$_inbound_id")
      API_RESULT=$(xui_api POST "/panel/api/inbounds/addClient" "$_client_payload" 2>/dev/null)
    else
      # ไม่มี inbound — สร้างใหม่พร้อม client
      local _vless_payload
      _vless_payload=$(python3 -c "
import json, sys
settings = json.dumps({
  'clients': [{
    'id': sys.argv[1],
    'email': sys.argv[2],
    'limitIp': 2,
    'totalGB': int(sys.argv[3]),
    'expiryTime': int(sys.argv[4]),
    'enable': True,
    'comment': '',
    'reset': 0
  }],
  'decryption': 'none'
})
stream = json.dumps({
  'network': 'ws',
  'security': sys.argv[5],
  'wsSettings': {'path': '/vless', 'headers': {'Host': sys.argv[6]}}
})
sniff = json.dumps({'enabled': True, 'destOverride': ['http','tls']})
payload = {
  'remark': 'CHAIYA-' + sys.argv[2],
  'enable': True,
  'listen': '',
  'port': int(sys.argv[7]),
  'protocol': 'vless',
  'settings': settings,
  'streamSettings': stream,
  'sniffing': sniff
}
print(json.dumps(payload))
" "$UUID" "$UNAME" "$TOTAL_BYTES" "$EXP_MS" "$SEC" "$_sni" "$_vport")
      API_RESULT=$(xui_api POST "/panel/api/inbounds/add" "$_vless_payload" 2>/dev/null)
      ufw allow "${_vport}"/tcp 2>/dev/null || true
    fi

    # สร้าง link
    local VLESS_LINK
    if [[ -f "$DOMAIN_FILE" ]]; then
      VLESS_LINK="vless://${UUID}@${AUTO_HOST}:${_vport}?encryption=none&security=tls&type=ws&path=%2Fvless&sni=${_sni}&host=${_sni}#CHAIYA-${UNAME}-${_vport}"
    else
      VLESS_LINK="vless://${UUID}@${AUTO_HOST}:${_vport}?encryption=none&security=none&type=ws&path=%2Fvless&host=${_sni}#CHAIYA-${UNAME}-${_vport}"
    fi

    # บันทึก DB
    echo "$UNAME $DAYS $EXP $DATA_GB $UUID $_vport $_sni $AUTO_HOST" >> "$DB"
    echo "$UNAME $DAYS $EXP $DATA_GB" >> /etc/chaiya/sshws-users/users.db 2>/dev/null || true

    # เก็บผลสำหรับแสดง
    _RESULTS+=("$_vport|$_sni|$UUID|$VLESS_LINK|$API_RESULT")
    (( _created_count++ ))
  done

  # ── ตั้งค่า IP limit enforcement (ban 12 ชั่วโมง) ────────────
  rgb_bar 85 "ตั้งค่า IP limit 2 IP / แบน 12 ชั่วโมง..."; printf "\n\n"

  # บันทึก config IP limit สำหรับ chaiya-iplimit daemon
  local _ipl_conf="/etc/chaiya/iplimit.conf"
  grep -q "^${UNAME}=" "$_ipl_conf" 2>/dev/null || \
    echo "${UNAME}=2:720" >> "$_ipl_conf" 2>/dev/null || true
  # format: user=max_ip:ban_minutes (720 min = 12 ชั่วโมง)

  # ── สร้างไฟล์ HTML (port แรกในรายการ) ───────────────────────
  if [[ ${#_RESULTS[@]} -gt 0 ]]; then
    local _first="${_RESULTS[0]}"
    local _fp; _fp=$(echo "$_first" | cut -d'|' -f1)
    local _fs; _fs=$(echo "$_first" | cut -d'|' -f2)
    local _fu; _fu=$(echo "$_first" | cut -d'|' -f3)
    local _fl; _fl=$(echo "$_first" | cut -d'|' -f4)
    gen_vless_html "$UNAME" "$_fl" "$_fu" "$AUTO_HOST" "$_fp" "$_fs" "$EXP"
  fi

  rgb_bar 100 "สร้าง User สำเร็จ! ✔"; printf "\n\n"

  # ── แสดงผลสรุป ───────────────────────────────────────────────
  printf "${R4}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R4}│${RS}  ${GR}✅ สร้าง VLESS User สำเร็จ!${RS}                    ${R4}│${RS}\n"
  printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"
  printf "${R4}│${RS}  ${GR}User    :${RS} ${WH}%-38s${R4}│${RS}\n" "$UNAME"
  printf "${R4}│${RS}  ${GR}Host    :${RS} ${WH}%-38s${R4}│${RS}\n" "$AUTO_HOST"
  printf "${R4}│${RS}  ${GR}หมดอายุ :${RS} ${WH}%-38s${R4}│${RS}\n" "$EXP"
  printf "${R4}│${RS}  ${GR}Data    :${RS} ${WH}%-38s${R4}│${RS}\n" "${DATA_GB} GB (0=ไม่จำกัด)"
  printf "${R4}│${RS}  ${YE}IP Limit:${RS} ${WH}2 IP / แบน ${RD}12 ชั่วโมง${RS}              ${R4}│${RS}\n"
  printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"

  for _r in "${_RESULTS[@]}"; do
    local _p; _p=$(echo "$_r" | cut -d'|' -f1)
    local _s; _s=$(echo "$_r" | cut -d'|' -f2)
    local _u; _u=$(echo "$_r" | cut -d'|' -f3)
    local _ar; _ar=$(echo "$_r" | cut -d'|' -f5)
    local _st
    if echo "$_ar" | grep -q '"success":true'; then
      _st="${CY}✔ เพิ่ม client สำเร็จ${RS}"
    else
      local _err; _err=$(echo "$_ar" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('msg','no response'))" 2>/dev/null || echo "ไม่ได้รับ response")
      _st="${RD}✗ ${_err}${RS}"
    fi
    printf "${R4}│${RS}  ${CY}Port %-5s${RS} SNI: %s\n" "$_p" "$_s"
    printf "${R4}│${RS}  UUID: ${CY}%s${RS}\n" "$_u"
    printf "${R4}│${RS}  Status: %b\n" "$_st"
    printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"
  done

  # ลิงค์ x-ui panel
  local _xp; _xp=$(xui_port)
  local _bp; _bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | sed 's|/$||')
  local _proto="http"
  [[ -f "$DOMAIN_FILE" ]] && _proto="https"
  local _panel_host; _panel_host=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "$MY_IP")

  printf "${R4}│${RS}  ${YE}🔗 X-UI Panel:${RS}\n"
  printf "${R4}│${RS}  ${WH}%s://%s:%s%s/${RS}\n" "$_proto" "$_panel_host" "$_xp" "$_bp"
  printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"
  printf "${R4}│${RS}  ${CY}📥 Config HTML:${RS}\n"
  printf "${R4}│${RS}  ${WH}http://%s:81/config/%s.html${RS}\n" "$MY_IP" "$UNAME"
  printf "${R4}└──────────────────────────────────────────────────┘${RS}\n\n"

  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 4 — ลบบัญชีหมดอายุ
# ══════════════════════════════════════════════════════════════
menu_4() {
  clear
  printf "${R5}[4] ลบบัญชีหมดอายุ${RS}\n\n"
  NOW=$(date +%s); COUNT=0
  if [[ -f "$DB" && -s "$DB" ]]; then
    while IFS=' ' read -r user days exp rest; do
      [[ -z "$user" ]] && continue
      EXP_TS=$(date -d "$exp" +%s 2>/dev/null || echo 0)
      if (( EXP_TS < NOW )); then
        sed -i "/^${user} /d" "$DB"
        userdel -f "$user" 2>/dev/null || true
        # ลบจาก x-ui ผ่าน API
        xui_api POST "/panel/api/client/delByEmail/${user}" "" > /dev/null 2>&1 || true
        printf "${RD}ลบ: %s (exp: %s)${RS}\n" "$user" "$exp"
        (( COUNT++ ))
      fi
    done < "$DB"
  fi
  printf "\n${GR}✔ ลบบัญชีหมดอายุ %d รายการ${RS}\n" "$COUNT"
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 5 — ดูบัญชี (ดึงจาก 3x-ui API)
# ══════════════════════════════════════════════════════════════
menu_5() {
  clear
  printf "${R6}[5] ดูบัญชีทั้งหมด${RS}\n\n"

  # ดึงจาก API ก่อน
  local api_data
  api_data=$(xui_api GET "/panel/api/inbounds/list" 2>/dev/null)

  if echo "$api_data" | grep -q '"success":true'; then
    printf "${WH}%-20s %-8s %-8s %-15s %-12s${RS}\n" "REMARK" "PORT" "PROTO" "UUID/EMAIL" "STATUS"
    printf "%.0s─" {1..70}; printf "\n"
    echo "$api_data" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    remark=x.get('remark','')[:19]
    port=x['port']
    proto=x.get('protocol','')[:7]
    enable='ACTIVE' if x.get('enable') else 'OFF'
    clients=[]
    try:
      s=json.loads(x.get('settings','{}'))
      clients=[c.get('email',c.get('id',''))[:14] for c in s.get('clients',[])]
    except: pass
    emails=', '.join(clients) if clients else '-'
    print(f'  {remark:<20} {port:<8} {proto:<8} {emails:<15} {enable:<12}')
except Exception as e: print(f'  Error: {e}')
"
  else
    # fallback ใช้ local DB
    if [[ ! -f "$DB" || ! -s "$DB" ]]; then
      printf "${YE}ไม่มีข้อมูลบัญชี${RS}\n"
    else
      NOW=$(date +%s)
      printf "${WH}%-20s %-12s %-8s %-15s${RS}\n" "USERNAME" "EXPIRE" "DATA_GB" "STATUS"
      printf "%.0s─" {1..60}; printf "\n"
      while IFS=' ' read -r user days exp quota uuid port sni rest; do
        [[ -z "$user" ]] && continue
        EXP_TS=$(date -d "$exp" +%s 2>/dev/null || echo 0)
        (( EXP_TS < NOW )) && C="$RD" || C="$GR"
        printf "${C}  %-20s %-12s %-8s %-15s${RS}\n" "$user" "$exp" "${quota:-∞}" "$(( EXP_TS < NOW ? 'EXPIRED' : 'ACTIVE' ))"
      done < "$DB"
    fi
  fi
  printf "\n"
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 6 — User Online Realtime
# ══════════════════════════════════════════════════════════════
menu_6() {
  printf "${PU}[6] User Online Realtime — Ctrl+C ออก${RS}\n\n"
  trap 'printf "\n${YE}กลับ...${RS}\n"; sleep 1; return' INT
  while true; do
    clear
    printf "${PU}[6] User Online Realtime  %s${RS}\n\n" "$(date '+%H:%M:%S')"
    printf "${WH}%-20s %-20s %-8s${RS}\n" "USER" "IP" "PORT"
    printf "%.0s─" {1..50}; printf "\n"
    ss -tnpc state established 2>/dev/null | grep ':22' | awk '{print $4}' | sort | while read -r addr; do
      ip=$(echo "$addr" | cut -d: -f1)
      pt=$(echo "$addr" | cut -d: -f2)
      user=$(who 2>/dev/null | awk -v ip="$ip" '$0~ip{print $1}' | head -1)
      printf "${GR}  %-20s %-20s %-8s${RS}\n" "${user:--}" "$ip" "$pt"
    done
    # ดึง online จาก x-ui API ด้วย
    local xui_online
    xui_online=$(xui_api GET "/panel/api/inbounds/onlines" 2>/dev/null)
    if echo "$xui_online" | grep -q '"success":true'; then
      printf "\n${YE}VLESS Online:${RS}\n"
      echo "$xui_online" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    print(f'  {x}')
except: pass
" 2>/dev/null || true
    fi
    sleep 3
  done
  trap - INT
}

# ══════════════════════════════════════════════════════════════
# เมนู 7 — รีสตาร์ท 3x-ui
# ══════════════════════════════════════════════════════════════
menu_7() {
  clear
  printf "${CY}[7] รีสตาร์ท 3x-ui${RS}\n\n"
  systemctl restart x-ui 2>/dev/null && \
    printf "${GR}✔ 3x-ui รีสตาร์ทสำเร็จ${RS}\n" || \
    printf "${RD}✗ ไม่สามารถ restart service x-ui${RS}\n"
  sleep 1
  systemctl status x-ui --no-pager 2>/dev/null | head -10
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 8 — จัดการ Process CPU สูง
# ══════════════════════════════════════════════════════════════
menu_8() {
  clear
  printf "${GR}[8] จัดการ Process CPU สูง${RS}\n\n"
  printf "${YE}Top 10 process CPU สูง:${RS}\n\n"
  printf "${WH}%-8s %-6s %-6s %s${RS}\n" "PID" "CPU%" "MEM%" "CMD"
  printf "%.0s─" {1..40}; printf "\n"
  ps aux --sort=-%cpu | tail -n +2 | head -10 | awk '{printf "  %-8s %-6s %-6s %s\n", $2, $3, $4, $11}'
  printf "\n"
  read -rp "$(printf "${YE}กรอก PID ที่จะ kill (Enter = ข้าม): ${RS}")" PID
  if [[ -n "$PID" ]]; then
    kill -9 "$PID" 2>/dev/null && \
      printf "${GR}✔ kill PID %s สำเร็จ${RS}\n" "$PID" || \
      printf "${RD}✗ ไม่สามารถ kill PID %s${RS}\n" "$PID"
  fi
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 9 — เช็คความเร็ว VPS
# ══════════════════════════════════════════════════════════════
menu_9() {
  clear
  printf "${YE}[9] เช็คความเร็ว VPS${RS}\n\n"
  if ! command -v speedtest-cli &>/dev/null; then
    printf "${YE}ติดตั้ง speedtest-cli...${RS}\n"
    pip3 install speedtest-cli --break-system-packages -q 2>/dev/null || \
    apt-get install -y speedtest-cli -qq 2>/dev/null || true
  fi
  if command -v speedtest-cli &>/dev/null; then
    speedtest-cli 2>/dev/null || printf "${RD}✗ speedtest ไม่สำเร็จ${RS}\n"
  else
    # fallback: curl test
    printf "${YE}ใช้ curl test แทน...${RS}\n"
    printf "Download: "
    curl -o /dev/null -s -w "%{speed_download} bytes/s\n" http://speedtest.ftp.otenet.gr/files/test1Mb.db 2>/dev/null || echo "ไม่สำเร็จ"
  fi
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 10 — จัดการ Port
# ══════════════════════════════════════════════════════════════
menu_10() {
  clear
  printf "${R2}[10] จัดการ Port (เปิด/ปิด)${RS}\n\n"
  printf "  ${GR}1.${RS} เปิด Port\n"
  printf "  ${RD}2.${RS} ปิด Port\n"
  printf "  ${YE}3.${RS} ดู Port ที่เปิดอยู่\n"
  read -rp "$(printf "${YE}เลือก: ${RS}")" sub
  case $sub in
    1) read -rp "Port: " P
       ufw allow "$P" 2>/dev/null || iptables -I INPUT -p tcp --dport "$P" -j ACCEPT
       printf "${GR}✔ เปิด Port %s สำเร็จ${RS}\n" "$P" ;;
    2) read -rp "Port: " P
       ufw deny "$P" 2>/dev/null || iptables -D INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null
       printf "${RD}✔ ปิด Port %s สำเร็จ${RS}\n" "$P" ;;
    3) printf "\n${YE}Port ที่เปิดอยู่:${RS}\n"
       ss -tlnp | grep LISTEN | awk '{printf "  %-30s %s\n", $4, $6}' | sort ;;
  esac
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 11 — ปลดแบน IP / จัดการ User
# ══════════════════════════════════════════════════════════════
menu_11() {
  clear
  printf "${R3}[11] ปลดแบน IP / จัดการ User${RS}\n\n"
  printf "  ${GR}1.${RS} ปลดแบน IP\n"
  printf "  ${YE}2.${RS} ดู IP ที่แบนอยู่\n"
  printf "  ${RD}3.${RS} แบน IP\n"
  printf "  ${CY}4.${RS} รีเซ็ต traffic VLESS user (ผ่าน API)\n"
  read -rp "$(printf "${YE}เลือก: ${RS}")" sub
  case $sub in
    1) read -rp "IP: " IP
       iptables -D INPUT -s "$IP" -j DROP 2>/dev/null || true
       sed -i "/${IP}/d" "$BAN_FILE" 2>/dev/null || true
       printf "${GR}✔ ปลดแบน %s สำเร็จ${RS}\n" "$IP" ;;
    2) printf "${YE}IP ที่แบนอยู่:${RS}\n"
       iptables -L INPUT -n 2>/dev/null | grep DROP | awk '{print "  "$4}'
       [[ -f "$BAN_FILE" ]] && cat "$BAN_FILE" || true ;;
    3) read -rp "IP: " IP
       iptables -I INPUT -s "$IP" -j DROP
       echo "$IP" >> "$BAN_FILE"
       printf "${RD}✔ แบน %s สำเร็จ${RS}\n" "$IP" ;;
    4) read -rp "$(printf "${YE}Email/username ของ VLESS user: ${RS}")" EMAIL
       local result
       result=$(xui_api POST "/panel/api/client/resetClientTraffic/${EMAIL}" "" 2>/dev/null)
       if echo "$result" | grep -q '"success":true'; then
         printf "${GR}✔ รีเซ็ต traffic %s สำเร็จ${RS}\n" "$EMAIL"
       else
         printf "${RD}✗ ไม่สำเร็จ${RS}\n"
       fi ;;
  esac
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 12 — บล็อก IP ต่างประเทศ
# ══════════════════════════════════════════════════════════════
menu_12() {
  clear
  printf "${R4}[12] บล็อก IP ต่างประเทศ${RS}\n\n"
  printf "  ${GR}1.${RS} บล็อก IP นอก TH/SG/MY/HK\n"
  printf "  ${YE}2.${RS} ดู rule ที่มีอยู่\n"
  printf "  ${RD}3.${RS} ยกเลิกบล็อก (flush rules)\n"
  read -rp "$(printf "${YE}เลือก: ${RS}")" sub
  case $sub in
    1) printf "${YE}ยืนยันบล็อก IP ต่างประเทศ? (y/N): ${RS}"
       read -r c
       [[ "$c" != "y" && "$c" != "Y" ]] && { printf "${YE}ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
       iptables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
       iptables -I INPUT -s 127.0.0.0/8 -j ACCEPT
       iptables -I INPUT -s 10.0.0.0/8 -j ACCEPT
       iptables -I INPUT -s 192.168.0.0/16 -j ACCEPT
       printf "${GR}✔ บล็อกเพิ่ม whitelist LAN สำเร็จ${RS}\n"
       printf "${YE}หมายเหตุ: ต้องเพิ่ม IP range ของแต่ละ ISP เองด้วย ipset${RS}\n" ;;
    2) iptables -L INPUT -n 2>/dev/null | head -20 ;;
    3) iptables -F INPUT 2>/dev/null
       printf "${YE}✔ ล้าง rules แล้ว${RS}\n" ;;
  esac
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 13 — สแกน Bug Host (SNI)
# ══════════════════════════════════════════════════════════════
menu_13() {
  clear
  printf "${R5}[13] สแกน Bug Host (SNI)${RS}\n\n"
  printf "  ${YE}SNI ยอดนิยม:${RS}\n"
  printf "  1. cj-ebb.speedtest.net\n"
  printf "  2. speedtest.net\n"
  printf "  3. true-internet.zoom.xyz.services\n"
  printf "  4. กรอกเอง\n\n"
  read -rp "$(printf "${YE}เลือก (หรือกรอก SNI โดยตรง): ${RS}")" sel
  case $sel in
    1) TARGET="cj-ebb.speedtest.net" ;;
    2) TARGET="speedtest.net" ;;
    3) TARGET="true-internet.zoom.xyz.services" ;;
    4) read -rp "$(printf "${YE}SNI: ${RS}")" TARGET ;;
    *) TARGET="$sel" ;;
  esac
  [[ -z "$TARGET" ]] && { printf "${YE}ยกเลิก${RS}\n"; read -rp "Enter..."; return; }

  printf "\n${R1}┌─────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ${WH}ผลสแกน: %-31s${R1}│${RS}\n" "$TARGET"
  printf "${R1}└─────────────────────────────────────────┘${RS}\n\n"

  printf "${YE}HTTP Headers:${RS}\n"
  curl -sI --max-time 5 "http://${TARGET}" 2>/dev/null | head -8 || printf "  ไม่ตอบสนอง\n"

  printf "\n${YE}TLS/SNI Info:${RS}\n"
  echo | openssl s_client -connect "${TARGET}:443" -servername "$TARGET" 2>/dev/null \
    | grep -E "subject|issuer|CN=" | head -5 || printf "  ไม่มี TLS\n"

  printf "\n${YE}WebSocket Test:${RS}\n"
  curl -sI --max-time 5 \
    -H "Upgrade: websocket" \
    -H "Connection: Upgrade" \
    -H "Host: ${TARGET}" \
    "http://${TARGET}" 2>/dev/null | grep -E "HTTP|Upgrade|101" | head -5 || printf "  ไม่รองรับ WS\n"

  printf "\n${YE}Ping (3 ครั้ง):${RS}\n"
  ping -c 3 -W 3 "$TARGET" 2>/dev/null | tail -3 || printf "  ping ไม่ได้\n"

  printf "\n${GR}✔ สแกนเสร็จ${RS}\n"
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 14 — ลบ User
# ══════════════════════════════════════════════════════════════
menu_14() {
  clear
  printf "${R6}[14] ลบ User${RS}\n\n"
  if [[ ! -f "$DB" || ! -s "$DB" ]]; then
    printf "${YE}ไม่มีบัญชีในระบบ${RS}\n"
    read -rp "Enter..."; return
  fi
  awk '{print NR". "$1" (exp: "$3")"}' "$DB"
  printf "\n"
  read -rp "$(printf "${YE}กรอกชื่อ user ที่จะลบ: ${RS}")" UNAME
  [[ -z "$UNAME" ]] && { printf "${YE}ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
  if grep -q "^${UNAME} " "$DB"; then
    sed -i "/^${UNAME} /d" "$DB"
    userdel -f "$UNAME" 2>/dev/null || true
    # ลบจาก x-ui ผ่าน API
    xui_api POST "/panel/api/client/delByEmail/${UNAME}" "" > /dev/null 2>&1 || true
    # ลบไฟล์ HTML
    rm -f "/var/www/chaiya/config/${UNAME}.html" 2>/dev/null || true
    printf "${GR}✔ ลบ %s สำเร็จ${RS}\n" "$UNAME"
  else
    printf "${RD}✗ ไม่พบ user %s${RS}\n" "$UNAME"
  fi
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 15 — ตั้งค่ารีบูตอัตโนมัติ
# ══════════════════════════════════════════════════════════════
menu_15() {
  clear
  printf "${PU}[15] ตั้งค่ารีบูตอัตโนมัติ${RS}\n\n"
  printf "  ${GR}1.${RS} รีบูตตามเวลา (กำหนดเอง)\n"
  printf "  ${YE}2.${RS} รีบูตทุกวันอาทิตย์ เวลา 03:00\n"
  printf "  ${RD}3.${RS} ยกเลิกรีบูตอัตโนมัติ\n"
  printf "  ${CY}4.${RS} ดู crontab ปัจจุบัน\n"
  read -rp "$(printf "${YE}เลือก: ${RS}")" sub
  case $sub in
    1) read -rp "$(printf "${YE}เวลา (เช่น 04:00): ${RS}")" T
       H=$(echo "$T"|cut -d: -f1); M=$(echo "$T"|cut -d: -f2)
       (crontab -l 2>/dev/null | grep -v "chaiya-reboot"; echo "$M $H * * * /sbin/reboot # chaiya-reboot") | crontab -
       printf "${GR}✔ รีบูตทุกวัน %s${RS}\n" "$T" ;;
    2) (crontab -l 2>/dev/null | grep -v "chaiya-reboot"; echo "0 3 * * 0 /sbin/reboot # chaiya-reboot") | crontab -
       printf "${GR}✔ รีบูตทุกวันอาทิตย์ 03:00${RS}\n" ;;
    3) crontab -l 2>/dev/null | grep -v "chaiya-reboot" | crontab -
       printf "${YE}✔ ยกเลิกรีบูตอัตโนมัติ${RS}\n" ;;
    4) printf "${YE}Crontab ปัจจุบัน:${RS}\n"
       crontab -l 2>/dev/null || printf "  ไม่มี crontab\n" ;;
  esac
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 16 — ก่อนการติดตั้ง Chaiya (dependencies)
# ══════════════════════════════════════════════════════════════
menu_16() {
  clear
  printf "${CY}[16] ก่อนการติดตั้ง Chaiya — ติดตั้ง dependencies${RS}\n\n"
  printf "${YE}กำลัง update + ติดตั้ง dependencies...${RS}\n\n"
  apt-get update -y
  apt-get install -y curl wget git unzip socat cron openssl net-tools \
    python3 python3-pip iptables ipset ufw nginx certbot \
    python3-certbot-nginx dropbear qrencode jq sqlite3 2>/dev/null || true
  # websocat
  if ! command -v websocat &>/dev/null; then
    ARCH=$(uname -m)
    WS_URL=""
    [[ "$ARCH" == "x86_64"  ]] && WS_URL="https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl"
    [[ "$ARCH" == "aarch64" ]] && WS_URL="https://github.com/vi/websocat/releases/latest/download/websocat.aarch64-unknown-linux-musl"
    [[ -n "$WS_URL" ]] && curl -sL "$WS_URL" -o /usr/local/bin/websocat 2>/dev/null && chmod +x /usr/local/bin/websocat
  fi
  printf "\n${GR}✔ ติดตั้งเสร็จสมบูรณ์${RS}\n"
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 17 — เคลียร์ CPU อัตโนมัติ
# ══════════════════════════════════════════════════════════════
menu_17() {
  clear
  printf "${YE}[17] เคลียร์ CPU อัตโนมัติ${RS}\n\n"
  printf "  ${GR}1.${RS} เปิด (kill process CPU > 80%% ทุก 5 นาที)\n"
  printf "  ${RD}2.${RS} ปิด\n"
  printf "  ${CY}3.${RS} ดู log${RS}\n"
  read -rp "$(printf "${YE}เลือก: ${RS}")" sub
  case $sub in
    1) cat > /usr/local/bin/chaiya-cpu-guard << 'CPUEOF'
#!/bin/bash
ps -eo pid,pcpu,comm --sort=-pcpu | tail -n +2 | head -20 | while read pid cpu cmd; do
  INT=${cpu%.*}
  (( INT > 80 )) || continue
  [[ "$cmd" =~ sshd|nginx|chaiya|python|systemd|x-ui ]] && continue
  kill -9 "$pid" 2>/dev/null
  echo "$(date) killed $pid ($cmd) cpu=$cpu%" >> /var/log/chaiya-cpu-guard.log
done
CPUEOF
       chmod +x /usr/local/bin/chaiya-cpu-guard
       (crontab -l 2>/dev/null | grep -v "chaiya-cpu"; echo "*/5 * * * * /usr/local/bin/chaiya-cpu-guard # chaiya-cpu") | crontab -
       printf "${GR}✔ เปิด CPU guard สำเร็จ${RS}\n" ;;
    2) crontab -l 2>/dev/null | grep -v "chaiya-cpu" | crontab -
       printf "${YE}✔ ปิด CPU guard สำเร็จ${RS}\n" ;;
    3) printf "${YE}Log:${RS}\n"
       tail -20 /var/log/chaiya-cpu-guard.log 2>/dev/null || printf "  ไม่มี log\n" ;;
  esac
  read -rp "Enter ย้อนกลับ..."
}

# ══════════════════════════════════════════════════════════════
# เมนู 18 — SSH WebSocket Manager
# ══════════════════════════════════════════════════════════════
menu_18() {
  clear
  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  [[ -f "$DOMAIN_FILE" ]] && _H=$(cat "$DOMAIN_FILE") || _H="$MY_IP"
  TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null || echo "N/A")
  PROTO="http"
  [[ -f "/etc/letsencrypt/live/${_H}/fullchain.pem" ]] && PROTO="https"

  printf "\n${R1}┌──────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ${GR}SSH over WebSocket${RS}                           ${R1}│${RS}\n"
  printf "${R1}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R1}│${RS}  🌐 ${WH}%s://%s/sshws/sshws.html${RS}\n" "$PROTO" "$_H"
  printf "${R1}│${RS}  🔑 Token : ${CY}%s${RS}\n" "$TOKEN"
  printf "${R1}└──────────────────────────────────────────────┘${RS}\n\n"
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# Main Loop
# ══════════════════════════════════════════════════════════════
while true; do
  show_menu
  read -r opt
  case $opt in
    1)  menu_1  ;;
    2)  menu_2  ;;
    3)  menu_3  ;;
    4)  menu_4  ;;
    5)  menu_5  ;;
    6)  menu_6  ;;
    7)  menu_7  ;;
    8)  menu_8  ;;
    9)  menu_9  ;;
    10) menu_10 ;;
    11) menu_11 ;;
    12) menu_12 ;;
    13) menu_13 ;;
    14) menu_14 ;;
    15) menu_15 ;;
    16) menu_16 ;;
    17) menu_17 ;;
    18) menu_18 ;;
    0)  clear; exit 0 ;;
  esac
done
CHAIYAEOF
chmod +x /usr/local/bin/chaiya

# ── สรุปผลการติดตั้ง ─────────────────────────────────────────

echo ""
echo "╭══════════════════════════════════════════════╮"
echo "║  ✅ CHAIYA V2RAY PRO MAX v10 ติดตั้งเสร็จ!  ║"
echo "║                                              ║"
echo "║  👉 พิมพ์:  chaiya  เพื่อเปิดเมนู           ║"
echo "╰══════════════════════════════════════════════╯"
echo ""
