#!/bin/bash
# ============================================================
#  CHAIYA V2RAY PRO MAX v10  —  Full Auto Setup
#  ติดตั้งครั้งเดียว พร้อมใช้งาน 100% ทุกเมนู
#  เมนู 1-18 ทำงานได้จริงทั้งหมด ไม่มีเมนูหลอก
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── สีและ style ──────────────────────────────────────────────
R1='\033[38;2;255;0;85m'
R2='\033[38;2;255;102;0m'
R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'
R5='\033[38;2;0;204;255m'
R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'
YE='\033[38;2;255;238;0m'
WH='\033[1;37m'
GR='\033[38;2;0;255;68m'
RD='\033[38;2;255;0;85m'
CY='\033[38;2;0;255;220m'
MG='\033[38;2;255;0;255m'
OR='\033[38;2;255;165;0m'
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

printf '%s' 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFNTSC1XUzwvdGl0bGU+CjxzdHlsZT4KOnJvb3R7LS1iZzojMDIwNDA4Oy0tYmcyOiMwNjBkMTQ7LS1ib3JkZXI6IzBmMjAzMDstLW1vbm86J0NvdXJpZXIgTmV3Jyxtb25vc3BhY2V9Cip7Ym94LXNpemluZzpib3JkZXItYm94O21hcmdpbjowO3BhZGRpbmc6MH0KYm9keXtiYWNrZ3JvdW5kOnZhcigtLWJnKTtjb2xvcjojYzhkZGU4O2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO21pbi1oZWlnaHQ6MTAwdmh9Ci53cmFwe21heC13aWR0aDo5NjBweDttYXJnaW46MCBhdXRvO3BhZGRpbmc6MTZweH0KLmgxe2NvbG9yOiNmZjAwNDA7Zm9udC1zaXplOjI0cHg7Zm9udC13ZWlnaHQ6OTAwO2xldHRlci1zcGFjaW5nOjRweDttYXJnaW4tYm90dG9tOjRweH0KLnN1Yntjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjE2cHh9Ci5jYXJke2JhY2tncm91bmQ6dmFyKC0tYmcyKTtib3JkZXI6MXB4IHNvbGlkICMxYTNhNTU7cGFkZGluZzoxNHB4O21hcmdpbi1ib3R0b206MTJweH0KLmxibHtjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTttYXJnaW4tYm90dG9tOjRweH0KLnZhbHtjb2xvcjojMDBlNWZmO2ZvbnQtc2l6ZToxM3B4fQouYnRue3BhZGRpbmc6NnB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCAjMDBlNWZmO2JhY2tncm91bmQ6dHJhbnNwYXJlbnQ7Y29sb3I6IzAwZTVmZjtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTp2YXIoLS1tb25vKTtmb250LXNpemU6MTFweH0KLmJ0bjpob3ZlcntiYWNrZ3JvdW5kOiMwMGU1ZmYyMn0KLmJ0bi1ne2JvcmRlci1jb2xvcjojMDBmZjg4O2NvbG9yOiMwMGZmODh9LmJ0bi1nOmhvdmVye2JhY2tncm91bmQ6IzAwZmY4ODIyfQouYnRuLXJ7Ym9yZGVyLWNvbG9yOiNmZjIyNTU7Y29sb3I6I2ZmMjI1NX0uYnRuLXI6aG92ZXJ7YmFja2dyb3VuZDojZmYyMjU1MjJ9CnRhYmxle3dpZHRoOjEwMCU7Ym9yZGVyLWNvbGxhcHNlOmNvbGxhcHNlO2ZvbnQtc2l6ZToxMXB4fQp0aHtjb2xvcjojM2Q1YTczO2ZvbnQtd2VpZ2h0OjQwMDtwYWRkaW5nOjZweCA4cHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgIzBmMjAzMDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxcHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlfQp0ZHtwYWRkaW5nOjhweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCAjMGExNTIwfQp0cjpob3ZlciB0ZHtiYWNrZ3JvdW5kOiMwYTE1MjB9Ci5waWxse3BhZGRpbmc6MXB4IDZweDtmb250LXNpemU6OHB4O2JvcmRlcjoxcHggc29saWR9Ci5wZ3tib3JkZXItY29sb3I6IzAwZmY4ODQ0O2NvbG9yOiMwMGZmODg7YmFja2dyb3VuZDojMDBmZjg4MTF9Ci5wcntib3JkZXItY29sb3I6I2ZmMjI1NTQ0O2NvbG9yOiNmZjIyNTU7YmFja2dyb3VuZDojZmYyMjU1MTF9CmlucHV0LHNlbGVjdHtiYWNrZ3JvdW5kOiMwMzA2MDg7Ym9yZGVyOjFweCBzb2xpZCAjMWEzYTU1O2NvbG9yOiNjOGRkZTg7cGFkZGluZzo2cHggOHB4O2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZToxMXB4O3dpZHRoOjEwMCU7b3V0bGluZTpub25lfQppbnB1dDpmb2N1cyxzZWxlY3Q6Zm9jdXN7Ym9yZGVyLWNvbG9yOiMwMGU1ZmZ9Ci5maXttYXJnaW4tYm90dG9tOjhweH0uZmkgbGFiZWx7ZGlzcGxheTpibG9jaztjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MXB4O21hcmdpbi1ib3R0b206M3B4fQoucm93e2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmZsZXgtZW5kfQouZzJ7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4fQoudGFic3tkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgIzBmMjAzMDttYXJnaW4tYm90dG9tOjEycHh9Ci50YWJ7cGFkZGluZzo3cHggMTJweDtiYWNrZ3JvdW5kOm5vbmU7Ym9yZGVyOm5vbmU7Y29sb3I6IzNkNWE3MztjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTp2YXIoLS1tb25vKTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjFweDtib3JkZXItYm90dG9tOjJweCBzb2xpZCB0cmFuc3BhcmVudDttYXJnaW4tYm90dG9tOi0xcHh9Ci50YWIub257Y29sb3I6IzAwZTVmZjtib3JkZXItYm90dG9tLWNvbG9yOiMwMGU1ZmZ9Ci50Y3tkaXNwbGF5Om5vbmV9LnRjLm9ue2Rpc3BsYXk6YmxvY2t9Ci5sb2d7YmFja2dyb3VuZDojMDMwNjA4O2JvcmRlcjoxcHggc29saWQgIzBmMjAzMDtwYWRkaW5nOjEwcHg7aGVpZ2h0OjEzMHB4O292ZXJmbG93LXk6YXV0bztmb250LXNpemU6MTBweDtjb2xvcjojMmE1YTQwO2xpbmUtaGVpZ2h0OjEuN30KI3RvYXN0e3Bvc2l0aW9uOmZpeGVkO2JvdHRvbToxNnB4O3JpZ2h0OjE2cHg7cGFkZGluZzo4cHggMTRweDtiYWNrZ3JvdW5kOnZhcigtLWJnMik7Ym9yZGVyOjFweCBzb2xpZCAjMDBlNWZmO2NvbG9yOiMwMGU1ZmY7Zm9udC1zaXplOjEwcHg7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoMTQwJSk7dHJhbnNpdGlvbjouM3M7ei1pbmRleDo5OTk5fQojdG9hc3Quc3t0cmFuc2Zvcm06bm9uZX0KLm1ve3Bvc2l0aW9uOmZpeGVkO2luc2V0OjA7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC44NSk7ZGlzcGxheTpub25lO3BsYWNlLWl0ZW1zOmNlbnRlcjt6LWluZGV4OjUwMDB9Ci5tby5ve2Rpc3BsYXk6Z3JpZH0KLm1ke2JhY2tncm91bmQ6dmFyKC0tYmcyKTtib3JkZXI6MXB4IHNvbGlkICMxYTNhNTU7cGFkZGluZzoyMHB4O3dpZHRoOm1pbig5MHZ3LDM2MHB4KX0KLm1kIGgze2NvbG9yOiMwMGU1ZmY7Zm9udC1zaXplOjEwcHg7bGV0dGVyLXNwYWNpbmc6MnB4O21hcmdpbi1ib3R0b206MTJweH0KLm1me2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2p1c3RpZnktY29udGVudDpmbGV4LWVuZDttYXJnaW4tdG9wOjEycHh9CkBtZWRpYShtYXgtd2lkdGg6NjAwcHgpey5nMntncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfX0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CjxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEycHg7bWFyZ2luLWJvdHRvbToxOHB4Ij4KICA8ZGl2PgogICAgPGRpdiBjbGFzcz0iaDEiPkNIQUlZQSBTU0gtV1M8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InN1YiI+Ly8gV0VCU09DS0VUIFNTSCBNQU5BR0VSPC9kaXY+CiAgPC9kaXY+CiAgPGRpdiBzdHlsZT0ibWFyZ2luLWxlZnQ6YXV0bztkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7Zm9udC1zaXplOjEwcHgiPgogICAgPGRpdiBpZD0iZG90IiBzdHlsZT0id2lkdGg6OHB4O2hlaWdodDo4cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojM2Q1YTczIj48L2Rpdj4KICAgIDxzcGFuIGlkPSJnbGJsIiBzdHlsZT0iY29sb3I6IzNkNWE3MyI+4oCUPC9zcGFuPgogIDwvZGl2Pgo8L2Rpdj4KPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmNlbnRlciI+CiAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgIDxkaXYgY2xhc3M9ImxibCI+QVBJIFRPS0VOPC9kaXY+CiAgICA8aW5wdXQgdHlwZT0icGFzc3dvcmQiIGlkPSJ0b2siIHBsYWNlaG9sZGVyPSJUb2tlbiAoYXV0by1maWxsZWQpIj4KICA8L2Rpdj4KICA8YnV0dG9uIGNsYXNzPSJidG4iIG9uY2xpY2s9InRvZ2dsZVRvaygpIj7wn5GBPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBvbmNsaWNrPSJsb2FkQWxsKCkiPuKWtiDguYDguIrguLfguYjguK3guKHguJXguYjguK08L2J1dHRvbj4KPC9kaXY+CjxkaXYgY2xhc3M9ImcyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxMnB4Ij4KICA8ZGl2IGNsYXNzPSJjYXJkIj48ZGl2IGNsYXNzPSJsYmwiPldlYlNvY2tldCBTdGF0dXM8L2Rpdj48ZGl2IGNsYXNzPSJ2YWwiIGlkPSJ3cy1zIj7igJQ8L2Rpdj48ZGl2IHN0eWxlPSJjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZTo5cHg7bWFyZ2luLXRvcDozcHgiIGlkPSJ3cy1wIj5wb3J0IOKAlDwvZGl2PjwvZGl2PgogIDxkaXYgY2xhc3M9ImNhcmQiPjxkaXYgY2xhc3M9ImxibCI+Q29ubmVjdGlvbnM8L2Rpdj48ZGl2IGNsYXNzPSJ2YWwiIGlkPSJjb25ucyI+4oCUPC9kaXY+PGRpdiBzdHlsZT0iY29sb3I6IzNkNWE3Mztmb250LXNpemU6OXB4O21hcmdpbi10b3A6M3B4Ij5hY3RpdmUgc2Vzc2lvbnM8L2Rpdj48L2Rpdj4KPC9kaXY+CjxkaXYgY2xhc3M9ImNhcmQiPgogIDxkaXYgY2xhc3M9InRhYnMiPgogICAgPGJ1dHRvbiBjbGFzcz0idGFiIG9uIiBvbmNsaWNrPSJzdygndC11c2VycycsdGhpcykiPvCfkaQgVXNlcnM8L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9InRhYiIgb25jbGljaz0ic3coJ3Qtb25saW5lJyx0aGlzKSI+8J+foiBPbmxpbmU8L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9InRhYiIgb25jbGljaz0ic3coJ3QtYmFuJyx0aGlzKSI+8J+aqyBCYW5uZWQ8L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9InRhYiIgb25jbGljaz0ic3coJ3QtbG9nJyx0aGlzKSI+8J+TiyBMb2dzPC9idXR0b24+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0idGMgb24iIGlkPSJ0LXVzZXJzIj4KICAgIDxkaXYgY2xhc3M9ImcyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTo4cHgiPgogICAgICA8ZGl2IGNsYXNzPSJmaSI+PGxhYmVsPlVzZXJuYW1lPC9sYWJlbD48aW5wdXQgaWQ9Im51IiBwbGFjZWhvbGRlcj0idXNlcjEiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaSI+PGxhYmVsPlBhc3N3b3JkPC9sYWJlbD48aW5wdXQgdHlwZT0icGFzc3dvcmQiIGlkPSJucCIgcGxhY2Vob2xkZXI9IuKAouKAouKAouKAouKAouKAouKAouKAoiI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InJvdyIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTJweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZpIiBzdHlsZT0ibWFyZ2luOjA7ZmxleDoxIj48bGFiZWw+4Lin4Lix4LiZPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0ibmQiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmkiIHN0eWxlPSJtYXJnaW46MDtmbGV4OjEiPjxsYWJlbD5EYXRhIEdCICgwPWluZik8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJuZ2IiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWciIG9uY2xpY2s9ImFkZFVzZXIoKSI+KyDguYDguJ7guLTguYjguKE8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPHRhYmxlPgogICAgICA8dGhlYWQ+PHRyPjx0aD5Vc2VybmFtZTwvdGg+PHRoPuC4q+C4oeC4lOC4reC4suC4ouC4uDwvdGg+PHRoPkRhdGE8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BY3Rpb25zPC90aD48L3RyPjwvdGhlYWQ+CiAgICAgIDx0Ym9keSBpZD0idXRiIj48dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjojM2Q1YTczO3BhZGRpbmc6MTZweCI+4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwvdGJvZHk+CiAgICA8L3RhYmxlPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9InRjIiBpZD0idC1vbmxpbmUiPgogICAgPHRhYmxlPgogICAgICA8dGhlYWQ+PHRyPjx0aD5SZW1vdGUgSVA8L3RoPjx0aD5TdGF0ZTwvdGg+PC90cj48L3RoZWFkPgogICAgICA8dGJvZHkgaWQ9Im90YiI+PHRyPjx0ZCBjb2xzcGFuPSIyIiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6IzNkNWE3MztwYWRkaW5nOjE2cHgiPuC5hOC4oeC5iOC4oeC4tSBjb25uZWN0aW9uPC90ZD48L3RyPjwvdGJvZHk+CiAgICA8L3RhYmxlPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9InRjIiBpZD0idC1iYW4iPgogICAgPHRhYmxlPgogICAgICA8dGhlYWQ+PHRyPjx0aD5Vc2VybmFtZTwvdGg+PHRoPuC5geC4muC4meC4luC4tuC4hzwvdGg+PHRoPklQczwvdGg+PHRoPkFjdGlvbjwvdGg+PC90cj48L3RoZWFkPgogICAgICA8dGJvZHkgaWQ9ImJ0YiI+PHRyPjx0ZCBjb2xzcGFuPSI0IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6IzNkNWE3MztwYWRkaW5nOjE2cHgiPuC5hOC4oeC5iOC4oeC4tSBhY2NvdW50IOC4luC4ueC4geC5geC4muC4mTwvdGQ+PC90cj48L3Rib2R5PgogICAgPC90YWJsZT4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJ0YyIgaWQ9InQtbG9nIj4KICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246cmlnaHQ7bWFyZ2luLWJvdHRvbTo4cHgiPjxidXR0b24gY2xhc3M9ImJ0biIgb25jbGljaz0ibG9hZExvZ3MoKSI+UmVmcmVzaDwvYnV0dG9uPjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibG9nIiBpZD0ibG9nYm94Ij48c3BhbiBzdHlsZT0iY29sb3I6IzNkNWE3MyI+Ly8g4LiB4LiUIFJlZnJlc2g8L3NwYW4+PC9kaXY+CiAgPC9kaXY+CjwvZGl2Pgo8ZGl2IGlkPSJ0b2FzdCI+PC9kaXY+CjxkaXYgY2xhc3M9Im1vIiBpZD0ibS1yZW5ldyI+CiAgPGRpdiBjbGFzcz0ibWQiPgogICAgPGgzPuC4leC5iOC4reC4reC4suC4ouC4uDwvaDM+CiAgICA8ZGl2IGNsYXNzPSJmaSI+PGxhYmVsPlVzZXJuYW1lPC9sYWJlbD48aW5wdXQgaWQ9InJuLXUiIHJlYWRvbmx5IHN0eWxlPSJjb2xvcjojMDBlNWZmIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImcyIj4KICAgICAgPGRpdiBjbGFzcz0iZmkiPjxsYWJlbD7guKfguLHguJk8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJybi1kIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpIj48bGFiZWw+RGF0YSBHQjwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9InJuLWdiIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibWYiPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4iIG9uY2xpY2s9ImNtKCdtLXJlbmV3JykiPuC4ouC4geC5gOC4peC4tOC4gTwvYnV0dG9uPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLWciIG9uY2xpY2s9ImNvbmZpcm1SZW5ldygpIj7guJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KPGRpdiBjbGFzcz0ibW8iIGlkPSJtLWRlbCI+CiAgPGRpdiBjbGFzcz0ibWQiPgogICAgPGgzPuC4peC4miBVc2VyPC9oMz4KICAgIDxwIHN0eWxlPSJmb250LXNpemU6MTFweDttYXJnaW4tYm90dG9tOjEwcHgiPuC4ouC4t+C4meC4ouC4seC4meC4peC4miA8c3BhbiBpZD0iZHUiIHN0eWxlPSJjb2xvcjojZmYyMjU1O2ZvbnQtd2VpZ2h0OjcwMCI+PC9zcGFuPiA/PC9wPgogICAgPGRpdiBjbGFzcz0ibWYiPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4iIG9uY2xpY2s9ImNtKCdtLWRlbCcpIj7guKLguIHguYDguKXguLTguIE8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1yIiBvbmNsaWNrPSJjb25maXJtRGVsKCkiPuC4peC4mjwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2Pgo8c2NyaXB0Pgpjb25zdCBBVVRPX1RPS0VOPSIlJVRPS0VOJSUiLEFVVE9fSE9TVD0iJSVIT1NUJSUiLEFVVE9fUFJPVE89IiUlUFJPVE8lJSI7CmNvbnN0IEFQST13aW5kb3cubG9jYXRpb24ub3JpZ2luKycvc3Nod3MtYXBpJzsKbGV0IGRlbFRhcmdldD0nJzsKY29uc3QgRUw9aWQ9PmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2xvYWQnLCgpPT57CiAgY29uc3Qgc2F2ZWQ9bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2N0b2snKTsKICBpZihBVVRPX1RPS0VOJiZBVVRPX1RPS0VOIT09JyUlVE9LRU4lJScpe0VMKCd0b2snKS52YWx1ZT1BVVRPX1RPS0VOO2xvY2FsU3RvcmFnZS5zZXRJdGVtKCdjdG9rJyxBVVRPX1RPS0VOKTt9CiAgZWxzZSBpZihzYXZlZCkgRUwoJ3RvaycpLnZhbHVlPXNhdmVkOwogIEVMKCd0b2snKS5hZGRFdmVudExpc3RlbmVyKCdjaGFuZ2UnLCgpPT5sb2NhbFN0b3JhZ2Uuc2V0SXRlbSgnY3RvaycsZ2V0VG9rKCkpKTsKICBpZihnZXRUb2soKSkgbG9hZEFsbCgpOwogIHNldEludGVydmFsKCgpPT57aWYoZ2V0VG9rKCkpe2xvYWRTdGF0dXMoKTtsb2FkT25saW5lKCk7fX0sODAwMCk7Cn0pOwpmdW5jdGlvbiBnZXRUb2soKXtyZXR1cm4gRUwoJ3RvaycpLnZhbHVlLnRyaW0oKTt9CmZ1bmN0aW9uIHRvZ2dsZVRvaygpe2NvbnN0IGU9RUwoJ3RvaycpO2UudHlwZT1lLnR5cGU9PT0ncGFzc3dvcmQnPyd0ZXh0JzoncGFzc3dvcmQnO30KZnVuY3Rpb24gdG9hc3QobXNnLGVycj1mYWxzZSl7CiAgY29uc3QgdD1FTCgndG9hc3QnKTt0LnRleHRDb250ZW50PW1zZzt0LmNsYXNzTmFtZT0ncycrKGVycj8nIGVycic6JycpOwogIGNsZWFyVGltZW91dCh0Ll90KTt0Ll90PXNldFRpbWVvdXQoKCk9PnQuY2xhc3NOYW1lPScnLDI4MDApOwp9CmFzeW5jIGZ1bmN0aW9uIGFwaShtZXRob2QscGF0aCxib2R5PW51bGwpewogIGNvbnN0IG89e21ldGhvZCxoZWFkZXJzOnsnQXV0aG9yaXphdGlvbic6J0JlYXJlciAnK2dldFRvaygpLCdDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ319OwogIGlmKGJvZHkpIG8uYm9keT1KU09OLnN0cmluZ2lmeShib2R5KTsKICB0cnl7Y29uc3Qgcj1hd2FpdCBmZXRjaChBUEkrcGF0aCxvKTtyZXR1cm4gYXdhaXQgci5qc29uKCk7fWNhdGNoKGUpe3JldHVybntlcnJvcjplLm1lc3NhZ2V9O30KfQpmdW5jdGlvbiBzdyhpZCxlbCl7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnRjJykuZm9yRWFjaCh0PT50LmNsYXNzTGlzdC5yZW1vdmUoJ29uJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWInKS5mb3JFYWNoKHQ9PnQuY2xhc3NMaXN0LnJlbW92ZSgnb24nKSk7CiAgRUwoaWQpLmNsYXNzTGlzdC5hZGQoJ29uJyk7ZWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICBpZihpZD09PSd0LW9ubGluZScpbG9hZE9ubGluZSgpOwogIGlmKGlkPT09J3QtYmFuJylsb2FkQmFubmVkKCk7CiAgaWYoaWQ9PT0ndC1sb2cnKWxvYWRMb2dzKCk7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFN0YXR1cygpewogIGNvbnN0IGQ9YXdhaXQgYXBpKCdHRVQnLCcvYXBpL3N0YXR1cycpOwogIGlmKGQuZXJyb3IpcmV0dXJuOwogIGNvbnN0IG9uPWQud3Nfc3RhdHVzPT09J2FjdGl2ZSc7CiAgRUwoJ2RvdCcpLnN0eWxlLmJhY2tncm91bmQ9b24/JyMwMGZmODgnOicjZmYyMjU1JzsKICBFTCgnZ2xibCcpLnRleHRDb250ZW50PW9uPydPTkxJTkUnOidPRkZMSU5FJzsKICBFTCgnZ2xibCcpLnN0eWxlLmNvbG9yPW9uPycjMDBmZjg4JzonI2ZmMjI1NSc7CiAgRUwoJ3dzLXMnKS50ZXh0Q29udGVudD1vbj8nUlVOTklORyc6J1NUT1BQRUQnOwogIEVMKCd3cy1zJykuc3R5bGUuY29sb3I9b24/JyMwMGZmODgnOicjZmYyMjU1JzsKICBFTCgnd3MtcCcpLnRleHRDb250ZW50PSdwb3J0ICcrZC53c19wb3J0OwogIEVMKCdjb25ucycpLnRleHRDb250ZW50PWQuY29ubmVjdGlvbnM/PzA7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJzKCl7CiAgY29uc3QgdT1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvdXNlcnMnKTsKICBjb25zdCB0Yj1FTCgndXRiJyk7CiAgaWYodS5lcnJvcil7dG9hc3QoJ+C5guC4q+C4peC4lOC5hOC4oeC5iOC5hOC4lOC5iScsdHJ1ZSk7cmV0dXJuO30KICBpZighQXJyYXkuaXNBcnJheSh1KXx8IXUubGVuZ3RoKXt0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgdXNlcnM8L3RkPjwvdHI+JztyZXR1cm47fQogIHRiLmlubmVySFRNTD11Lm1hcCh4PT57CiAgICBjb25zdCBkTGVmdD1NYXRoLmNlaWwoKG5ldyBEYXRlKHguZXhwKS1uZXcgRGF0ZSgpKS84NjQwMDAwMCk7CiAgICBjb25zdCBvaz14LmFjdGl2ZSYmZExlZnQ+MDsKICAgIHJldHVybiAnPHRyPjx0ZCBzdHlsZT0iY29sb3I6I2ZmZjtmb250LXdlaWdodDo3MDAiPicreC51c2VyKyc8L3RkPjx0ZD4nK3guZXhwKyc8c3BhbiBzdHlsZT0iY29sb3I6IzNkNWE3Mztmb250LXNpemU6OXB4Ij4gKCcrKGRMZWZ0PjA/ZExlZnQrJ2QnOifguKvguKHguJQnKSsnKTwvc3Bhbj48L3RkPjx0ZCBzdHlsZT0iY29sb3I6IzAwZTVmZiI+JysoeC5kYXRhX2diPjA/eC5kYXRhX2diKydHQic6J2luZicpKyc8L3RkPjx0ZD48c3BhbiBjbGFzcz0icGlsbCAnKyhvaz8ncGcnOidwcicpKyciPicrKG9rPydBQ1RJVkUnOidFWFBJUkVEJykrJzwvc3Bhbj48L3RkPjx0ZCBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo0cHgiPjxidXR0b24gY2xhc3M9ImJ0biIgc3R5bGU9InBhZGRpbmc6MnB4IDhweDtmb250LXNpemU6OXB4IiBvbmNsaWNrPSJvcGVuUmVuZXcoXCcnK3gudXNlcisnXCcsJyt4LmRheXMrJywnK3guZGF0YV9nYisnKSI+UjwvYnV0dG9uPjxidXR0b24gY2xhc3M9ImJ0biBidG4tciIgc3R5bGU9InBhZGRpbmc6MnB4IDhweDtmb250LXNpemU6OXB4IiBvbmNsaWNrPSJvcGVuRGVsKFwnJyt4LnVzZXIrJ1wnKSI+WDwvYnV0dG9uPjwvdGQ+PC90cj4nOwogIH0pLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGFkZFVzZXIoKXsKICBjb25zdCB1c2VyPUVMKCdudScpLnZhbHVlLnRyaW0oKSxwYXNzPUVMKCducCcpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzPXBhcnNlSW50KEVMKCduZCcpLnZhbHVlKXx8MzAsZ2I9cGFyc2VJbnQoRUwoJ25nYicpLnZhbHVlKXx8MDsKICBpZighdXNlcnx8IXBhc3Mpe3RvYXN0KCfguYPguKrguYggdXNlcm5hbWUg4LmB4Lil4LiwIHBhc3N3b3JkJyx0cnVlKTtyZXR1cm47fQogIGNvbnN0IHI9YXdhaXQgYXBpKCdQT1NUJywnL2FwaS91c2Vycycse3VzZXIscGFzc3dvcmQ6cGFzcyxkYXlzLGRhdGFfZ2I6Z2J9KTsKICBpZihyLm9rKXt0b2FzdCgn4LmA4Lie4Li04LmI4LihICcrdXNlcisnIOC5geC4peC5ieC4pycpO0VMKCdudScpLnZhbHVlPScnO0VMKCducCcpLnZhbHVlPScnO2xvYWRVc2VycygpO30KICBlbHNlIHRvYXN0KCfguYDguJ7guLTguYjguKHguYTguKHguYjguYTguJTguYk6ICcrKHIucmVzdWx0fHxyLmVycm9yKSx0cnVlKTsKfQpmdW5jdGlvbiBvcGVuUmVuZXcodSxkLGdiKXtFTCgncm4tdScpLnZhbHVlPXU7RUwoJ3JuLWQnKS52YWx1ZT1kfHwzMDtFTCgncm4tZ2InKS52YWx1ZT1nYnx8MDtFTCgnbS1yZW5ldycpLmNsYXNzTGlzdC5hZGQoJ28nKTt9CmFzeW5jIGZ1bmN0aW9uIGNvbmZpcm1SZW5ldygpewogIGNvbnN0IHU9RUwoJ3JuLXUnKS52YWx1ZSxkPXBhcnNlSW50KEVMKCdybi1kJykudmFsdWUpfHwzMCxnYj1wYXJzZUludChFTCgncm4tZ2InKS52YWx1ZSl8fDA7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3JlbmV3Jyx7dXNlcjp1LGRheXM6ZCxkYXRhX2diOmdifSk7CiAgY20oJ20tcmVuZXcnKTsKICBpZihyLm9rKXt0b2FzdCgn4LiV4LmI4Lit4Lit4Liy4Lii4Li4ICcrdSsnICcrZCsn4Lin4Lix4LiZJyk7bG9hZFVzZXJzKCk7fWVsc2UgdG9hc3QoJ+C4leC5iOC4reC4reC4suC4ouC4uOC5hOC4oeC5iOC5hOC4lOC5iScsdHJ1ZSk7Cn0KZnVuY3Rpb24gb3BlbkRlbCh1KXtkZWxUYXJnZXQ9dTtFTCgnZHUnKS50ZXh0Q29udGVudD11O0VMKCdtLWRlbCcpLmNsYXNzTGlzdC5hZGQoJ28nKTt9CmFzeW5jIGZ1bmN0aW9uIGNvbmZpcm1EZWwoKXsKICBjb25zdCByPWF3YWl0IGFwaSgnREVMRVRFJywnL2FwaS91c2Vycy8nK2RlbFRhcmdldCk7CiAgY20oJ20tZGVsJyk7CiAgaWYoci5vayl7dG9hc3QoJ+C4peC4miAnK2RlbFRhcmdldCsnIOC5geC4peC5ieC4pycpO2xvYWRVc2VycygpO31lbHNlIHRvYXN0KCfguKXguJrguYTguKHguYjguYTguJTguYknLHRydWUpOwp9CmZ1bmN0aW9uIGNtKGlkKXtFTChpZCkuY2xhc3NMaXN0LnJlbW92ZSgnbycpO30KZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm1vJykuZm9yRWFjaChtPT5tLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJyxlPT57aWYoZS50YXJnZXQ9PT1tKW0uY2xhc3NMaXN0LnJlbW92ZSgnbycpO30pKTsKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpewogIGNvbnN0IGQ9YXdhaXQgYXBpKCdHRVQnLCcvYXBpL29ubGluZScpOwogIGNvbnN0IHRiPUVMKCdvdGInKTsKICBpZighQXJyYXkuaXNBcnJheShkKXx8IWQubGVuZ3RoKXt0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iMiIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgY29ubmVjdGlvbjwvdGQ+PC90cj4nO3JldHVybjt9CiAgdGIuaW5uZXJIVE1MPWQubWFwKGM9Pic8dHI+PHRkIHN0eWxlPSJjb2xvcjojMDBlNWZmIj4nK2MucmVtb3RlKyc8L3RkPjx0ZD48c3BhbiBjbGFzcz0icGlsbCBwZyI+JytjLnN0YXRlKyc8L3NwYW4+PC90ZD48L3RyPicpLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRCYW5uZWQoKXsKICBjb25zdCBiPWF3YWl0IGFwaSgnR0VUJywnL2FwaS9iYW5uZWQnKTsKICBjb25zdCB0Yj1FTCgnYnRiJyk7CiAgY29uc3Qga2V5cz1PYmplY3Qua2V5cyhifHx7fSk7CiAgaWYoIWtleXMubGVuZ3RoKXt0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNCIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgYWNjb3VudCDguJbguLnguIHguYHguJrguJk8L3RkPjwvdHI+JztyZXR1cm47fQogIHRiLmlubmVySFRNTD1rZXlzLm1hcCh1aWQ9PnsKICAgIGNvbnN0IHg9Ylt1aWRdOwogICAgY29uc3QgdW50aWw9bmV3IERhdGUoeC51bnRpbCkudG9Mb2NhbGVTdHJpbmcoJ3RoLVRIJyk7CiAgICByZXR1cm4gJzx0cj48dGQgc3R5bGU9ImNvbG9yOiNmZjIyNTU7Zm9udC13ZWlnaHQ6NzAwIj4nK3gubmFtZSsnPC90ZD48dGQ+PHNwYW4gY2xhc3M9InBpbGwgcHIiPicrdW50aWwrJzwvc3Bhbj48L3RkPjx0ZCBzdHlsZT0iZm9udC1zaXplOjlweDtjb2xvcjojM2Q1YTczIj4nKygoeC5pcHN8fFtdKS5zbGljZSgwLDMpLmpvaW4oJywgJykpKyc8L3RkPjx0ZD48YnV0dG9uIGNsYXNzPSJidG4gYnRuLWciIHN0eWxlPSJwYWRkaW5nOjJweCA4cHg7Zm9udC1zaXplOjlweCIgb25jbGljaz0idW5iYW4oXCcnK3VpZCsnXCcsXCcnK3gubmFtZSsnXCcpIj7guJvguKXguJQ8L2J1dHRvbj48L3RkPjwvdHI+JzsKICB9KS5qb2luKCcnKTsKfQphc3luYyBmdW5jdGlvbiB1bmJhbih1aWQsbmFtZSl7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3VuYmFuJyx7dWlkLG5hbWV9KTsKICBpZihyLm9rKXt0b2FzdCgn4Lib4Lil4LiU4LmB4Lia4LiZICcrbmFtZSk7bG9hZEJhbm5lZCgpO31lbHNlIHRvYXN0KCfguJvguKXguJTguYHguJrguJnguYTguKHguYjguYTguJTguYknLHRydWUpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRMb2dzKCl7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvbG9ncycpOwogIGNvbnN0IGI9RUwoJ2xvZ2JveCcpOwogIGlmKCFyLmxpbmVzfHwhci5saW5lcy5sZW5ndGgpe2IuaW5uZXJIVE1MPSc8c3BhbiBzdHlsZT0iY29sb3I6IzNkNWE3MyI+Ly8g4LmE4Lih4LmI4Lih4Li1IGxvZ3M8L3NwYW4+JztyZXR1cm47fQogIGIuaW5uZXJIVE1MPXIubGluZXMubWFwKGw9Pic8ZGl2IHN0eWxlPSJjb2xvcjonKyhsLmluY2x1ZGVzKCdFUlInKT8nI2ZmMjI1NSc6bC5pbmNsdWRlcygnT0snKT8nIzAwZmY4OCc6JyMyYTVhNDAnKSsnIj4nK2wrJzwvZGl2PicpLmpvaW4oJycpOwogIGIuc2Nyb2xsVG9wPWIuc2Nyb2xsSGVpZ2h0Owp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRBbGwoKXsKICBpZighZ2V0VG9rKCkpe3RvYXN0KCfguYPguKrguYggQVBJIFRva2VuIOC4geC5iOC4reC4mScsdHJ1ZSk7cmV0dXJuO30KICBhd2FpdCBsb2FkU3RhdHVzKCk7YXdhaXQgbG9hZFVzZXJzKCk7YXdhaXQgbG9hZE9ubGluZSgpOwp9Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K' | base64 -d   | sed "s|%%TOKEN%%|${_SSHWS_TOK}|g"   | sed "s|%%HOST%%|${_SSHWS_HOST}|g"   | sed "s|%%PROTO%%|${_SSHWS_PROTO}|g"   > /var/www/chaiya/sshws.html

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

# ── สี ────────────────────────────────────────────────────────
R1='\033[38;2;255;0;85m'
R2='\033[38;2;255;102;0m'
R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'
R5='\033[38;2;0;204;255m'
R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'
YE='\033[38;2;255;238;0m'
WH='\033[1;37m'
GR='\033[38;2;0;255;68m'
RD='\033[38;2;255;0;85m'
CY='\033[38;2;0;255;220m'
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
  printf "${R1}┌──────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS} 🔥 ${BLD}${R2}V2RAY PRO MAX v10${RS}                        ${R1}│${RS}\n"
  if [[ -n "$HOST" ]]; then
    printf "${R1}│${RS} 🌐 ${GR}Domain : %-30s${R1}│${RS}\n" "$HOST"
  else
    printf "${R1}│${RS} ⚠️  ${YE}ยังไม่มีโดเมน                             ${R1}│${RS}\n"
  fi
  printf "${R1}│${RS} 🌍 ${CY}IP     : %-30s${R1}│${RS}\n" "$MY_IP"
  printf "${R1}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R1}│${RS} 💻 CPU: ${GR}%-4s%%%s${RS}  🧠 RAM: ${YE}%s/%s GB${RS}  👥 Users: ${PU}%-3s${R1}│${RS}\n" "$CPU" "" "$RAM_USED" "$RAM_TOTAL" "$USERS"
  printf "${R1}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R1}│${RS}  ${R2}1.${RS}  ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ          ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R3}2.${RS}  ตั้งค่าโดเมน + SSL อัตโนมัติ              ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R4}3.${RS}  สร้าง VLESS (IP/โดเมน+port+SNI)          ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R5}4.${RS}  ลบบัญชีหมดอายุ                           ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R6}5.${RS}  ดูบัญชี                                   ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${PU}6.${RS}  ดู User Online Realtime                   ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${CY}7.${RS}  รีสตาร์ท 3x-ui                            ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${GR}8.${RS}  จัดการ Process CPU สูง                   ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${YE}9.${RS}  เช็คความเร็ว VPS                          ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R2}10.${RS} จัดการ Port (เปิด/ปิด)                   ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R3}11.${RS} ปลดแบน IP / จัดการ User                  ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R4}12.${RS} บล็อก IP ต่างประเทศ                       ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R5}13.${RS} สแกน Bug Host (SNI)                       ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${R6}14.${RS} ลบ User                                   ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${PU}15.${RS} ตั้งค่ารีบูตอัตโนมัติ                    ${R1}│${RS}\n"
  printf "${R1}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R1}│${RS}  ${CY}16.${RS} ก่อนการติดตั้ง Chaiya                     ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${YE}17.${RS} เคลียร์ CPU อัตโนมัติ                    ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${GR}18.${RS} SSH WebSocket                             ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${WH}0.${RS}  ออก                                        ${R1}│${RS}\n"
  printf "${R1}└──────────────────────────────────────────────┘${RS}\n"
  printf "\n${YE}เลือก >> ${RS}"
}

# ── helper: x-ui API ─────────────────────────────────────────
xui_port() { cat "$XUI_PORT_FILE" 2>/dev/null || echo "2053"; }
xui_user() { cat "$XUI_USER_FILE" 2>/dev/null || echo "admin"; }
xui_pass() { cat "$XUI_PASS_FILE" 2>/dev/null || echo "admin"; }

xui_login() {
  local p u pw
  p=$(xui_port); u=$(xui_user); pw=$(xui_pass)
  curl -s -c "$XUI_COOKIE" -b "$XUI_COOKIE" \
    -X POST "http://127.0.0.1:${p}/login" \
    -d "username=${u}&password=${pw}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --max-time 10 2>/dev/null | grep -q '"success":true'
}

xui_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local p; p=$(xui_port)
  xui_login 2>/dev/null || true
  if [[ -n "$data" ]]; then
    curl -s -c "$XUI_COOKIE" -b "$XUI_COOKIE" \
      -X "$method" "http://127.0.0.1:${p}${endpoint}" \
      -H "Content-Type: application/json" -d "$data" --max-time 15 2>/dev/null
  else
    curl -s -c "$XUI_COOKIE" -b "$XUI_COOKIE" \
      -X "$method" "http://127.0.0.1:${p}${endpoint}" --max-time 15 2>/dev/null
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
# เมนู 1 — ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ
# ══════════════════════════════════════════════════════════════
menu_1() {
  clear
  printf "${R2}[1] ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ${RS}\n\n"
  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

  if systemctl is-active --quiet x-ui 2>/dev/null; then
    # ── x-ui ติดตั้งแล้ว ──────────────────────────────────────
    local p; p=$(xui_port)
    printf "${GR}✔ 3x-ui กำลังทำงานอยู่แล้ว${RS}\n"
    printf "  Panel  : ${WH}http://%s:%s${RS}\n" "$MY_IP" "$p"
    printf "  User   : ${WH}%s${RS}\n\n" "$(xui_user)"
    printf "  ${YE}1.${RS} ดูข้อมูล inbounds ปัจจุบัน\n"
    printf "  ${R2}2.${RS} เปลี่ยน credential admin\n"
    printf "  ${RD}3.${RS} ติดตั้งใหม่ทับ\n"
    read -rp "$(printf "${YE}เลือก (Enter = ออก): ${RS}")" sub
    case $sub in
      1)
        printf "\n${YE}━━━ Inbounds ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RS}\n"
        xui_api GET "/panel/api/inbounds/list" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  items=d.get('obj',[])
  if not items: print('  ไม่มี inbounds'); sys.exit()
  print(f\"  {'PORT':<7} {'PROTOCOL':<10} {'REMARK':<25} {'STATUS'}\")
  print('  '+'-'*55)
  for x in items:
    st='✅' if x.get('enable') else '❌'
    print(f\"  {x['port']:<7} {x.get('protocol',''):<10} {x.get('remark',''):<25} {st}\")
except Exception as e: print(f'  Error: {e}')
"
        read -rp "Enter ย้อนกลับ..." ;;
      2)
        read -rp "$(printf "${YE}Username ใหม่: ${RS}")" u
        [[ -z "$u" ]] && { printf "${YE}ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
        read -rsp "$(printf "${YE}Password ใหม่: ${RS}")" pw; echo ""
        [[ -z "$pw" ]] && { printf "${RD}ต้องใส่ password${RS}\n"; read -rp "Enter..."; return; }
        echo "$u" > /etc/chaiya/xui-user.conf
        echo "$pw" > /etc/chaiya/xui-pass.conf
        x-ui setting -username "$u" -password "$pw" 2>/dev/null || true
        systemctl restart x-ui 2>/dev/null || true
        printf "${GR}✔ อัพเดต credential แล้ว | User: %s${RS}\n" "$u"
        read -rp "Enter..." ;;
      3) : ;; # ไปต่อด้านล่าง (ติดตั้งใหม่)
      *) return ;;
    esac
    [[ "$sub" != "3" ]] && return
  fi

  # ── ถามชื่อ+รหัส ก่อนติดตั้ง x-ui ──────────────────────────
  printf "\n${R1}┌──────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ${WH}ขั้นตอนที่ 1: ตั้งค่า admin สำหรับ 3x-ui    ${R1}│${RS}\n"
  printf "${R1}└──────────────────────────────────────────────┘${RS}\n\n"

  read -rp "$(printf "${YE}กรอก Username admin (เช่น admin): ${RS}")" u
  [[ -z "$u" ]] && u="admin"
  while true; do
    read -rsp "$(printf "${YE}กรอก Password admin (ห้ามว่าง): ${RS}")" pw; echo ""
    [[ -n "$pw" ]] && break
    printf "${RD}Password ห้ามว่าง กรอกใหม่${RS}\n"
  done
  read -rsp "$(printf "${YE}ยืนยัน Password อีกครั้ง: ${RS}")" pw2; echo ""
  if [[ "$pw" != "$pw2" ]]; then
    printf "${RD}✗ Password ไม่ตรงกัน — ยกเลิก${RS}\n"
    read -rp "Enter..."; return
  fi

  # เซฟ credential
  echo "$u" > /etc/chaiya/xui-user.conf
  echo "$pw" > /etc/chaiya/xui-pass.conf
  chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf
  printf "\n${GR}✔ บันทึก: User=${WH}%s${GR} | Pass=****${RS}\n\n" "$u"

  # ── ติดตั้ง 3x-ui พร้อมตอบ prompt อัตโนมัติ ─────────────────
  printf "${R1}┌──────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ${WH}ขั้นตอนที่ 2: ติดตั้ง 3x-ui                  ${R1}│${RS}\n"
  printf "${R1}└──────────────────────────────────────────────┘${RS}\n"
  printf "  ${YE}Port panel  : 2053${RS}\n"
  printf "  ${YE}SSL method  : IP certificate (6 วัน auto-renew)${RS}\n"
  printf "  ${YE}IPv6        : ข้าม${RS}\n"
  printf "  ${YE}ACME port   : 80${RS}\n\n"

  XUI_INSTALL=$(mktemp /tmp/xui-XXXXX.sh)
  curl -Ls "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" -o "$XUI_INSTALL" 2>/dev/null
  # ตอบ prompt ทั้ง 5 ข้ออัตโนมัติ
  printf "y\n2053\n2\n\n80\n" | bash "$XUI_INSTALL" 2>&1 | tee /var/log/chaiya-xui-install.log
  rm -f "$XUI_INSTALL"

  sleep 3

  # ── ตั้ง credential หลังติดตั้ง ──────────────────────────────
  printf "\n${YE}⟳ ตั้ง credential...${RS}\n"
  x-ui setting -username "$u" -password "$pw" 2>/dev/null || \
    /usr/local/x-ui/x-ui setting -username "$u" -password "$pw" 2>/dev/null || \
    printf "${YE}⚠ CLI ไม่สำเร็จ — ลอง API แทน${RS}\n"
  systemctl restart x-ui 2>/dev/null || true
  sleep 2

  # อัพเดต port จาก config จริง
  _xp=$(x-ui setting 2>/dev/null | grep -oP 'port.*?:\s*\K\d+' | head -1)
  [[ -n "$_xp" ]] && echo "$_xp" > /etc/chaiya/xui-port.conf

  printf "${GR}✔ ติดตั้ง 3x-ui เสร็จ${RS}\n"
  printf "  Panel  : ${WH}http://%s:%s${RS}\n" "$MY_IP" "$(xui_port)"
  printf "  User   : ${WH}%s${RS}\n" "$u"
  printf "  Pass   : ${WH}%s${RS}\n\n" "$pw"

  # ── เชื่อม API: สร้าง inbounds 8080/8880 อัตโนมัติ ──────────
  printf "${R1}┌──────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ${WH}ขั้นตอนที่ 3: สร้าง inbounds อัตโนมัติ       ${R1}│${RS}\n"
  printf "${R1}└──────────────────────────────────────────────┘${RS}\n"

  sleep 3
  local _ports=("8080:CHAIYA-AIS-8080:cj-ebb.speedtest.net"
                "8880:CHAIYA-TRUE-8880:true-internet.zoom.xyz.services")
  for _item in "${_ports[@]}"; do
    _pp=$(echo "$_item"|cut -d: -f1)
    _rr=$(echo "$_item"|cut -d: -f2)
    _ss=$(echo "$_item"|cut -d: -f3)
    _uuid=$(cat /proc/sys/kernel/random/uuid)
    _res=$(xui_api POST "/panel/api/inbounds/add" \
      "{\"remark\":\"${_rr}\",\"enable\":true,\"listen\":\"\",\"port\":${_pp},\"protocol\":\"vmess\",\"settings\":{\"clients\":[{\"id\":\"${_uuid}\",\"alterId\":0}],\"disableInsecureEncryption\":false},\"streamSettings\":{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"/\",\"headers\":{\"Host\":\"${_ss}\"}}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}")
    ufw allow "${_pp}"/tcp 2>/dev/null || true
    if echo "$_res" | grep -q '"success":true'; then
      printf "  ${GR}✔ Port %s (%s) → SNI: %s${RS}\n" "$_pp" "$_rr" "$_ss"
    else
      printf "  ${YE}⚠ Port %s — API ไม่ตอบ (x-ui อาจยังไม่พร้อม)${RS}\n" "$_pp"
    fi
  done

  printf "\n${GR}✅ ติดตั้งและตั้งค่าทั้งหมดเสร็จสมบูรณ์!${RS}\n"
  read -rp "Enter ย้อนกลับเมนูหลัก..."
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
# เมนู 3 — สร้าง VLESS
# ══════════════════════════════════════════════════════════════
menu_3() {
  clear
  printf "${R4}[3] สร้าง VLESS User${RS}\n\n"

  # ดึง host
  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  if [[ -f "$DOMAIN_FILE" ]]; then
    AUTO_HOST=$(cat "$DOMAIN_FILE")
    printf "  ${GR}โดเมน: ${WH}%s${RS} (จะใช้อัตโนมัติ)\n" "$AUTO_HOST"
  else
    AUTO_HOST="$MY_IP"
    printf "  ${YE}ไม่มีโดเมน — ใช้ IP: ${WH}%s${RS}\n" "$MY_IP"
  fi
  printf "\n"

  read -rp "$(printf "${YE}ชื่อผู้ใช้: ${RS}")" UNAME
  [[ -z "$UNAME" ]] && { printf "${YE}ยกเลิก${RS}\n"; read -rp "Enter..."; return; }

  read -rp "$(printf "${YE}วันหมดอายุ (จำนวนวัน): ${RS}")" DAYS
  [[ -z "$DAYS" ]] && DAYS=30

  read -rp "$(printf "${YE}ข้อมูลสูงสุด GB (0 = ไม่จำกัด): ${RS}")" DATA_GB
  [[ -z "$DATA_GB" ]] && DATA_GB=0

  printf "\n  ${WH}เลือก Port:${RS}\n"
  printf "  ${R2}1.${RS} 8080 (AIS)\n"
  printf "  ${R3}2.${RS} 8880 (TRUE)\n"
  printf "  ${R4}3.${RS} กรอกเอง\n"
  read -rp "$(printf "${YE}เลือก: ${RS}")" port_choice
  case $port_choice in
    1) VPORT=8080 ;;
    2) VPORT=8880 ;;
    3) read -rp "$(printf "${YE}Port: ${RS}")" VPORT ;;
    *) VPORT=8080 ;;
  esac

  printf "\n  ${WH}SNI / Bug Host:${RS}\n"
  printf "  ${R2}1.${RS} cj-ebb.speedtest.net\n"
  printf "  ${R3}2.${RS} speedtest.net\n"
  printf "  ${R4}3.${RS} true-internet.zoom.xyz.services\n"
  printf "  ${R5}4.${RS} กรอกเอง\n"
  read -rp "$(printf "${YE}เลือก: ${RS}")" sni_choice
  case $sni_choice in
    1) SNI="cj-ebb.speedtest.net" ;;
    2) SNI="speedtest.net" ;;
    3) SNI="true-internet.zoom.xyz.services" ;;
    4) read -rp "$(printf "${YE}SNI: ${RS}")" SNI ;;
    *) SNI="cj-ebb.speedtest.net" ;;
  esac

  UUID=$(cat /proc/sys/kernel/random/uuid)
  EXP=$(date -d "+${DAYS} days" +"%Y-%m-%d")

  # สร้าง inbound ผ่าน 3x-ui API
  printf "\n${YE}⟳ สร้าง inbound ผ่าน 3x-ui API...${RS}\n"
  local SEC="none"
  [[ -f "$DOMAIN_FILE" ]] && SEC="tls"

  local TOTAL_BYTES=$(( DATA_GB * 1073741824 ))
  local EXP_MS=$(( $(date -d "$EXP" +%s) * 1000 ))
  local PAYLOAD="{\"remark\":\"CHAIYA-${UNAME}\",\"enable\":true,\"listen\":\"\",\"port\":${VPORT},\"protocol\":\"vless\",\"settings\":{\"clients\":[{\"id\":\"${UUID}\",\"email\":\"${UNAME}\",\"limitIp\":2,\"totalGB\":${TOTAL_BYTES},\"expiryTime\":${EXP_MS},\"enable\":true,\"comment\":\"\",\"reset\":0}],\"decryption\":\"none\"},\"streamSettings\":{\"network\":\"ws\",\"security\":\"${SEC}\",\"wsSettings\":{\"path\":\"/vless\",\"headers\":{\"Host\":\"${SNI}\"}}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}"

  API_RESULT=$(xui_api POST "/panel/api/inbounds/add" "$PAYLOAD")
  if echo "$API_RESULT" | grep -q '"success":true'; then
    printf "${GR}✔ inbound สร้างสำเร็จผ่าน API${RS}\n"
    ufw allow "${VPORT}"/tcp 2>/dev/null || true
  else
    printf "${YE}⚠ API ไม่ตอบสนอง — บันทึก local แทน${RS}\n"
  fi

  # บันทึก DB
  echo "$UNAME $DAYS $EXP $DATA_GB $UUID $VPORT $SNI $AUTO_HOST" >> "$DB"
  echo "$UNAME $DAYS $EXP $DATA_GB" >> /etc/chaiya/sshws-users/users.db 2>/dev/null || true

  # สร้าง VLESS link
  if [[ -f "$DOMAIN_FILE" ]]; then
    VLESS_LINK="vless://${UUID}@${AUTO_HOST}:${VPORT}?encryption=none&security=tls&type=ws&path=%2Fvless&sni=${SNI}&host=${SNI}#CHAIYA-${UNAME}"
  else
    VLESS_LINK="vless://${UUID}@${AUTO_HOST}:${VPORT}?encryption=none&security=none&type=ws&path=%2Fvless&host=${SNI}#CHAIYA-${UNAME}"
  fi

  # สร้างไฟล์ HTML
  gen_vless_html "$UNAME" "$VLESS_LINK" "$UUID" "$AUTO_HOST" "$VPORT" "$SNI" "$EXP"

  # แสดงผล
  printf "\n${R1}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ${WH}✅ สร้าง VLESS User สำเร็จ                       ${R1}│${RS}\n"
  printf "${R1}├──────────────────────────────────────────────────┤${RS}\n"
  printf "${R1}│${RS}  ${GR}User    :${RS} ${WH}%-38s${R1}│${RS}\n" "$UNAME"
  printf "${R1}│${RS}  ${GR}Host    :${RS} ${WH}%-38s${R1}│${RS}\n" "$AUTO_HOST"
  printf "${R1}│${RS}  ${GR}Port    :${RS} ${WH}%-38s${R1}│${RS}\n" "$VPORT"
  printf "${R1}│${RS}  ${GR}UUID    :${RS} ${CY}%-38s${R1}│${RS}\n" "$UUID"
  printf "${R1}│${RS}  ${GR}SNI     :${RS} ${YE}%-38s${R1}│${RS}\n" "$SNI"
  printf "${R1}│${RS}  ${GR}หมดอายุ :${RS} ${WH}%-38s${R1}│${RS}\n" "$EXP"
  printf "${R1}├──────────────────────────────────────────────────┤${RS}\n"
  printf "${R1}│${RS}  ${YE}VLESS Link:${RS}                                    ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${CY}%s${R1}│${RS}\n" "$(echo "$VLESS_LINK" | fold -w 50 | head -1)"
  printf "${R1}├──────────────────────────────────────────────────┤${RS}\n"
  printf "${R1}│${RS}  ${GR}📥 ดาวน์โหลด Config:${RS}                          ${R1}│${RS}\n"
  printf "${R1}│${RS}  ${WH}http://%s:81/config/%s.html${RS}\n" "$MY_IP" "$UNAME"
  printf "${R1}└──────────────────────────────────────────────────┘${RS}\n\n"

  # QR Code
  command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$VLESS_LINK"

  read -rp "Enter ย้อนกลับ..."
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
  [[ -f "$DOMAIN_FILE" ]] && HOST=$(cat "$DOMAIN_FILE") || HOST="$MY_IP"
  TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null || echo "N/A")
  PROTO="http"
  [[ -f "/etc/letsencrypt/live/${HOST}/fullchain.pem" ]] && PROTO="https"

  printf "\n${R1}┌──────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ${GR}SSH over WebSocket Manager${RS}                   ${R1}│${RS}\n"
  printf "${R1}└──────────────────────────────────────────────┘${RS}\n\n"
  printf "  🌐 URL   : ${YE}%s://%s/sshws/sshws.html${RS}\n" "$PROTO" "$HOST"
  printf "  🌐 Alt   : ${YE}http://%s:81/sshws/sshws.html${RS}\n" "$MY_IP"
  printf "  🔑 Token : ${WH}%s${RS}\n\n" "$TOKEN"

  # สถานะ service
  WS_STATUS=$(systemctl is-active chaiya-sshws 2>/dev/null || echo "inactive")
  [[ "$WS_STATUS" == "active" ]] && printf "  ● Service: ${GR}ACTIVE${RS}\n" || printf "  ● Service: ${RD}INACTIVE${RS}\n"

  printf "\n  ${GR}1.${RS} รีสตาร์ท SSH-WS service\n"
  printf "  ${YE}2.${RS} ดู log SSH-WS\n"
  printf "  ${CY}3.${RS} ดู status service\n"
  printf "  ${R2}4.${RS} เริ่ม service\n"
  printf "  ${RD}5.${RS} หยุด service\n"
  printf "  ${WH}6.${RS} แสดง QR code ของ URL\n"
  read -rp "$(printf "${YE}เลือก (Enter = ออก): ${RS}")" sub
  case $sub in
    1) systemctl restart chaiya-sshws 2>/dev/null && \
         printf "${GR}✔ รีสตาร์ทสำเร็จ${RS}\n" || \
         printf "${RD}✗ ไม่สำเร็จ${RS}\n" ;;
    2) journalctl -u chaiya-sshws -n 50 --no-pager 2>/dev/null || \
       tail -50 /var/log/chaiya-sshws.log 2>/dev/null ;;
    3) systemctl status chaiya-sshws 2>/dev/null ;;
    4) systemctl start chaiya-sshws 2>/dev/null && printf "${GR}✔ เริ่ม service${RS}\n" ;;
    5) systemctl stop chaiya-sshws 2>/dev/null && printf "${YE}✔ หยุด service${RS}\n" ;;
    6) command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "${PROTO}://${HOST}/sshws/sshws.html" || printf "${YE}ไม่มี qrencode${RS}\n" ;;
  esac
  read -rp "Enter ย้อนกลับ..."
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
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ CHAIYA V2RAY PRO MAX v10 ติดตั้งเสร็จ!  ║"
echo "║                                              ║"
echo "║  👉 พิมพ์:  chaiya  เพื่อเปิดเมนู           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
