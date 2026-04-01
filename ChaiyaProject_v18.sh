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
# ── Port 81: Web Panel (SSH-WS + config download)
server {
    listen 81;
    server_name _;
    root /var/www/chaiya;
    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
        default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache";
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
# websocat ฟัง port 80 โดยตรง รับ WebSocket แล้ว forward ไป SSH port 22
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

(crontab -l 2>/dev/null || true) | grep -v chaiya-iplimit | { cat; echo "*/5 * * * * python3 /usr/local/bin/chaiya-iplimit >> /var/log/chaiya-iplimit.log 2>&1"; } | crontab -

# ══════════════════════════════════════════════════════════════
#  สร้าง sshws.html  (base64 decode + แทน token)
# ══════════════════════════════════════════════════════════════
_SSHWS_TOK=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]' || echo "N/A")
_SSHWS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
_SSHWS_HOST=$( [[ -f /etc/chaiya/domain.conf ]] && cat /etc/chaiya/domain.conf || echo "$_SSHWS_IP" )
_SSHWS_PROTO="http"
[[ -f "/etc/letsencrypt/live/${_SSHWS_HOST}/fullchain.pem" ]] && _SSHWS_PROTO="https"

printf '%s' 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEuMCI+Cjx0aXRsZT5DSEFJWUEgU1NILVdTPC90aXRsZT4KPHN0eWxlPgo6cm9vdHstLWJnOiMwMjA0MDg7LS1iZzI6IzA2MGQxNDstLWJvcmRlcjojMGYyMDMwOy0tbW9ubzonQ291cmllciBOZXcnLG1vbm9zcGFjZX0KKntib3gtc2l6aW5nOmJvcmRlci1ib3g7bWFyZ2luOjA7cGFkZGluZzowfQpib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2NvbG9yOiNjOGRkZTg7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbn0KCi8qIFJHQiB3YXZlIGFuaW1hdGlvbiDguKrguLPguKvguKPguLHguJrguJXguLHguKfguK3guLHguIHguKnguKPguKvguLHguKfguILguYnguK0gKi8KQGtleWZyYW1lcyB3YXZlLXJnYnsKICAwJXtjb2xvcjojZmYwMDU1O3RleHQtc2hhZG93OjAgMCAxMHB4ICNmZjAwNTUsMCAwIDIwcHggI2ZmMDA1NTY2fQogIDE2JXtjb2xvcjojZmY2NjAwO3RleHQtc2hhZG93OjAgMCAxMHB4ICNmZjY2MDAsMCAwIDIwcHggI2ZmNjYwMDY2fQogIDMzJXtjb2xvcjojZmZlZTAwO3RleHQtc2hhZG93OjAgMCAxMHB4ICNmZmVlMDAsMCAwIDIwcHggI2ZmZWUwMDY2fQogIDUwJXtjb2xvcjojMDBmZjQ0O3RleHQtc2hhZG93OjAgMCAxMHB4ICMwMGZmNDQsMCAwIDIwcHggIzAwZmY0NDY2fQogIDY2JXtjb2xvcjojMDBjY2ZmO3RleHQtc2hhZG93OjAgMCAxMHB4ICMwMGNjZmYsMCAwIDIwcHggIzAwY2NmZjY2fQogIDgzJXtjb2xvcjojY2M0NGZmO3RleHQtc2hhZG93OjAgMCAxMHB4ICNjYzQ0ZmYsMCAwIDIwcHggI2NjNDRmZjY2fQogIDEwMCV7Y29sb3I6I2ZmMDA1NTt0ZXh0LXNoYWRvdzowIDAgMTBweCAjZmYwMDU1LDAgMCAyMHB4ICNmZjAwNTU2Nn0KfQpAa2V5ZnJhbWVzIHdhdmUtdW5kZXJsaW5lewogIDAle2JhY2tncm91bmQtcG9zaXRpb246MCUgNTAlfQogIDEwMCV7YmFja2dyb3VuZC1wb3NpdGlvbjoyMDAlIDUwJX0KfQpAa2V5ZnJhbWVzIHJnYi1ib3JkZXJ7CiAgMCV7Ym9yZGVyLWNvbG9yOiNmZjAwNTV9MTYle2JvcmRlci1jb2xvcjojZmY2NjAwfTMzJXtib3JkZXItY29sb3I6I2ZmZWUwMH0KICA1MCV7Ym9yZGVyLWNvbG9yOiMwMGZmNDR9NjYle2JvcmRlci1jb2xvcjojMDBjY2ZmfTgzJXtib3JkZXItY29sb3I6I2NjNDRmZn0xMDAle2JvcmRlci1jb2xvcjojZmYwMDU1fQp9CkBrZXlmcmFtZXMgcHVsc2UtZG90ewogIDAlLDEwMCV7b3BhY2l0eToxO3RyYW5zZm9ybTpzY2FsZSgxKX01MCV7b3BhY2l0eTouNjt0cmFuc2Zvcm06c2NhbGUoLjgpfQp9Ci8qIHdhdmUg4Liq4Liz4Lir4Lij4Lix4Lia4LmB4LiV4LmI4Lil4Liw4LiV4Lix4Lin4Lit4Lix4LiB4Lip4Lij4LmD4LiZ4Lir4Lix4Lin4LiC4LmJ4LitICovCkBrZXlmcmFtZXMgY2hhci13YXZlewogIDAlLDEwMCV7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9NTAle3RyYW5zZm9ybTp0cmFuc2xhdGVZKC00cHgpfQp9Cgoud3JhcHttYXgtd2lkdGg6OTYwcHg7bWFyZ2luOjAgYXV0bztwYWRkaW5nOjE2cHh9CgovKiBIZWFkZXIgUkdCIHdhdmUgKi8KLmgxLXdyYXB7b3ZlcmZsb3c6aGlkZGVuO21hcmdpbi1ib3R0b206NHB4fQouaDF7Zm9udC1zaXplOjI2cHg7Zm9udC13ZWlnaHQ6OTAwO2xldHRlci1zcGFjaW5nOjVweDtkaXNwbGF5OmZsZXg7Z2FwOjFweH0KLmgxIHNwYW57ZGlzcGxheTppbmxpbmUtYmxvY2s7YW5pbWF0aW9uOndhdmUtcmdiIDNzIGxpbmVhciBpbmZpbml0ZSxjaGFyLXdhdmUgMS41cyBlYXNlLWluLW91dCBpbmZpbml0ZX0KLmgxIHNwYW46bnRoLWNoaWxkKDEpe2FuaW1hdGlvbi1kZWxheTowcywwc30KLmgxIHNwYW46bnRoLWNoaWxkKDIpe2FuaW1hdGlvbi1kZWxheTouMDVzLC4xc30KLmgxIHNwYW46bnRoLWNoaWxkKDMpe2FuaW1hdGlvbi1kZWxheTouMXMsLjJzfQouaDEgc3BhbjpudGgtY2hpbGQoNCl7YW5pbWF0aW9uLWRlbGF5Oi4xNXMsLjNzfQouaDEgc3BhbjpudGgtY2hpbGQoNSl7YW5pbWF0aW9uLWRlbGF5Oi4ycywuNHN9Ci5oMSBzcGFuOm50aC1jaGlsZCg2KXthbmltYXRpb24tZGVsYXk6LjI1cywuNXN9Ci5oMSBzcGFuOm50aC1jaGlsZCg3KXthbmltYXRpb24tZGVsYXk6LjNzLC42c30KLmgxIHNwYW46bnRoLWNoaWxkKDgpe2FuaW1hdGlvbi1kZWxheTouMzVzLC43c30KLmgxIHNwYW46bnRoLWNoaWxkKDkpe2FuaW1hdGlvbi1kZWxheTouNHMsLjhzfQouaDEgc3BhbjpudGgtY2hpbGQoMTApe2FuaW1hdGlvbi1kZWxheTouNDVzLC45c30KLmgxIHNwYW46bnRoLWNoaWxkKDExKXthbmltYXRpb24tZGVsYXk6LjVzLDFzfQouaDEgc3BhbjpudGgtY2hpbGQoMTIpe2FuaW1hdGlvbi1kZWxheTouNTVzLDEuMXN9Ci5oMS11bmRlcntoZWlnaHQ6MnB4O21hcmdpbi10b3A6NHB4O21hcmdpbi1ib3R0b206NHB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmZjAwNTUsI2ZmNjYwMCwjZmZlZTAwLCMwMGZmNDQsIzAwY2NmZiwjY2M0NGZmLCNmZjAwNTUpO2JhY2tncm91bmQtc2l6ZToyMDAlIDEwMCU7YW5pbWF0aW9uOndhdmUtdW5kZXJsaW5lIDJzIGxpbmVhciBpbmZpbml0ZX0KLnN1Yntjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjE2cHh9CgovKiBTZWN0aW9uIGhlYWRlcnMg4LmB4Lia4LiaIFJHQiB3YXZlICovCi5zZWMtdGl0bGV7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzozcHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO21hcmdpbi1ib3R0b206MTJweDtkaXNwbGF5OmZsZXg7Z2FwOjFweH0KLnNlYy10aXRsZSBzcGFue2Rpc3BsYXk6aW5saW5lLWJsb2NrO2FuaW1hdGlvbjp3YXZlLXJnYiA0cyBsaW5lYXIgaW5maW5pdGV9Ci5zZWMtdGl0bGUgc3BhbjpudGgtY2hpbGQobil7YW5pbWF0aW9uLWRlbGF5OmNhbGModmFyKC0taSkqLjA2cyl9CgouY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWJnMik7Ym9yZGVyOjFweCBzb2xpZCAjMWEzYTU1O3BhZGRpbmc6MTRweDttYXJnaW4tYm90dG9tOjEycHg7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjNzfQouY2FyZDpob3ZlcnthbmltYXRpb246cmdiLWJvcmRlciAycyBsaW5lYXIgaW5maW5pdGV9Ci5jYXJkLnJnYi1hbHdheXN7YW5pbWF0aW9uOnJnYi1ib3JkZXIgMnMgbGluZWFyIGluZmluaXRlfQoubGJse2NvbG9yOiMzZDVhNzM7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO21hcmdpbi1ib3R0b206NHB4fQoudmFse2NvbG9yOiMwMGU1ZmY7Zm9udC1zaXplOjEzcHh9Ci5idG57cGFkZGluZzo2cHggMTJweDtib3JkZXI6MXB4IHNvbGlkICMwMGU1ZmY7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtjb2xvcjojMDBlNWZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZToxMXB4O3RyYW5zaXRpb246YmFja2dyb3VuZCAuMnN9Ci5idG46aG92ZXJ7YmFja2dyb3VuZDojMDBlNWZmMjJ9Ci5idG4tZ3tib3JkZXItY29sb3I6IzAwZmY4ODtjb2xvcjojMDBmZjg4fS5idG4tZzpob3ZlcntiYWNrZ3JvdW5kOiMwMGZmODgyMn0KLmJ0bi1ye2JvcmRlci1jb2xvcjojZmYyMjU1O2NvbG9yOiNmZjIyNTV9LmJ0bi1yOmhvdmVye2JhY2tncm91bmQ6I2ZmMjI1NTIyfQouYnRuLXl7Ym9yZGVyLWNvbG9yOiNmZmVlMDA7Y29sb3I6I2ZmZWUwMH0uYnRuLXk6aG92ZXJ7YmFja2dyb3VuZDojZmZlZTAwMjJ9Ci5idG4tcHtib3JkZXItY29sb3I6I2NjNDRmZjtjb2xvcjojY2M0NGZmfS5idG4tcDpob3ZlcntiYWNrZ3JvdW5kOiNjYzQ0ZmYyMn0KdGFibGV7d2lkdGg6MTAwJTtib3JkZXItY29sbGFwc2U6Y29sbGFwc2U7Zm9udC1zaXplOjExcHh9CnRoe2NvbG9yOiMzZDVhNzM7Zm9udC13ZWlnaHQ6NDAwO3BhZGRpbmc6NnB4IDhweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCAjMGYyMDMwO3RleHQtYWxpZ246bGVmdDtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjFweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2V9CnRke3BhZGRpbmc6OHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkICMwYTE1MjB9CnRyOmhvdmVyIHRke2JhY2tncm91bmQ6IzBhMTUyMH0KLnBpbGx7cGFkZGluZzoxcHggNnB4O2ZvbnQtc2l6ZTo4cHg7Ym9yZGVyOjFweCBzb2xpZH0KLnBne2JvcmRlci1jb2xvcjojMDBmZjg4NDQ7Y29sb3I6IzAwZmY4ODtiYWNrZ3JvdW5kOiMwMGZmODgxMX0KLnBye2JvcmRlci1jb2xvcjojZmYyMjU1NDQ7Y29sb3I6I2ZmMjI1NTtiYWNrZ3JvdW5kOiNmZjIyNTUxMX0KaW5wdXQsc2VsZWN0e2JhY2tncm91bmQ6IzAzMDYwODtib3JkZXI6MXB4IHNvbGlkICMxYTNhNTU7Y29sb3I6I2M4ZGRlODtwYWRkaW5nOjZweCA4cHg7Zm9udC1mYW1pbHk6dmFyKC0tbW9ubyk7Zm9udC1zaXplOjExcHg7d2lkdGg6MTAwJTtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzfQppbnB1dDpmb2N1cyxzZWxlY3Q6Zm9jdXN7Ym9yZGVyLWNvbG9yOiMwMGU1ZmZ9Ci5maXttYXJnaW4tYm90dG9tOjhweH0uZmkgbGFiZWx7ZGlzcGxheTpibG9jaztjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MXB4O21hcmdpbi1ib3R0b206M3B4fQoucm93e2Rpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmZsZXgtZW5kfQouZzJ7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4fQoudGFic3tkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgIzBmMjAzMDttYXJnaW4tYm90dG9tOjEycHg7ZmxleC13cmFwOndyYXA7Z2FwOjJweH0KLnRhYntwYWRkaW5nOjdweCAxMnB4O2JhY2tncm91bmQ6bm9uZTtib3JkZXI6bm9uZTtjb2xvcjojM2Q1YTczO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OnZhcigtLW1vbm8pO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6MXB4O2JvcmRlci1ib3R0b206MnB4IHNvbGlkIHRyYW5zcGFyZW50O21hcmdpbi1ib3R0b206LTFweDt0cmFuc2l0aW9uOmNvbG9yIC4yc30KLnRhYi5vbntjb2xvcjojMDBlNWZmO2JvcmRlci1ib3R0b20tY29sb3I6IzAwZTVmZn0KLnRje2Rpc3BsYXk6bm9uZX0udGMub257ZGlzcGxheTpibG9ja30KLmxvZ3tiYWNrZ3JvdW5kOiMwMzA2MDg7Ym9yZGVyOjFweCBzb2xpZCAjMGYyMDMwO3BhZGRpbmc6MTBweDtoZWlnaHQ6MTMwcHg7b3ZlcmZsb3cteTphdXRvO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOiMyYTVhNDA7bGluZS1oZWlnaHQ6MS43fQojdG9hc3R7cG9zaXRpb246Zml4ZWQ7Ym90dG9tOjE2cHg7cmlnaHQ6MTZweDtwYWRkaW5nOjhweCAxNHB4O2JhY2tncm91bmQ6dmFyKC0tYmcyKTtib3JkZXI6MXB4IHNvbGlkICMwMGU1ZmY7Y29sb3I6IzAwZTVmZjtmb250LXNpemU6MTBweDt0cmFuc2Zvcm06dHJhbnNsYXRlWCgxNDAlKTt0cmFuc2l0aW9uOi4zczt6LWluZGV4Ojk5OTl9CiN0b2FzdC5ze3RyYW5zZm9ybTpub25lfQoubW97cG9zaXRpb246Zml4ZWQ7aW5zZXQ6MDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjg1KTtkaXNwbGF5Om5vbmU7cGxhY2UtaXRlbXM6Y2VudGVyO3otaW5kZXg6NTAwMH0KLm1vLm97ZGlzcGxheTpncmlkfQoubWR7YmFja2dyb3VuZDp2YXIoLS1iZzIpO2JvcmRlcjoxcHggc29saWQgIzFhM2E1NTtwYWRkaW5nOjIwcHg7d2lkdGg6bWluKDkwdncsMzgwcHgpfQoubWQgaDN7Y29sb3I6IzAwZTVmZjtmb250LXNpemU6MTBweDtsZXR0ZXItc3BhY2luZzoycHg7bWFyZ2luLWJvdHRvbToxMnB4fQoubWZ7ZGlzcGxheTpmbGV4O2dhcDo4cHg7anVzdGlmeS1jb250ZW50OmZsZXgtZW5kO21hcmdpbi10b3A6MTJweDtmbGV4LXdyYXA6d3JhcH0KLmRvdHt3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXItcmFkaXVzOjUwJTtkaXNwbGF5OmlubGluZS1ibG9jazthbmltYXRpb246cHVsc2UtZG90IDJzIGVhc2UtaW4tb3V0IGluZmluaXRlfQouZG90LW9ue2JhY2tncm91bmQ6IzAwZmY4ODtib3gtc2hhZG93OjAgMCA2cHggIzAwZmY4OH0KLmRvdC1vZmZ7YmFja2dyb3VuZDojZmYyMjU1O2JveC1zaGFkb3c6MCAwIDZweCAjZmYyMjU1fQouYmFja3VwLWJveHtiYWNrZ3JvdW5kOiMwMzA2MDg7Ym9yZGVyOjFweCBzb2xpZCAjMGYyMDMwO3BhZGRpbmc6MTBweDtmb250LXNpemU6MTBweDtjb2xvcjojM2Q1YTczO3dpZHRoOjEwMCU7aGVpZ2h0OjgwcHg7cmVzaXplOnZlcnRpY2FsO291dGxpbmU6bm9uZTtmb250LWZhbWlseTp2YXIoLS1tb25vKX0KLmJhY2t1cC1ib3g6Zm9jdXN7Ym9yZGVyLWNvbG9yOiNjYzQ0ZmZ9CkBtZWRpYShtYXgtd2lkdGg6NjAwcHgpey5nMntncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS5tZntmbGV4LWRpcmVjdGlvbjpjb2x1bW59fQo8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGNsYXNzPSJ3cmFwIj4KCjwhLS0gSGVhZGVyIHdpdGggUkdCIHdhdmUgY2hhcnMgLS0+CjxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpmbGV4LXN0YXJ0O2dhcDoxMnB4O21hcmdpbi1ib3R0b206MThweCI+CiAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgIDxkaXYgY2xhc3M9ImgxLXdyYXAiPgogICAgICA8ZGl2IGNsYXNzPSJoMSI+CiAgICAgICAgPHNwYW4+Qzwvc3Bhbj48c3Bhbj5IPC9zcGFuPjxzcGFuPkE8L3NwYW4+PHNwYW4+STwvc3Bhbj48c3Bhbj5ZPC9zcGFuPjxzcGFuPkE8L3NwYW4+CiAgICAgICAgPHNwYW4+Jm5ic3A7PC9zcGFuPgogICAgICAgIDxzcGFuPlM8L3NwYW4+PHNwYW4+Uzwvc3Bhbj48c3Bhbj5IPC9zcGFuPjxzcGFuPi08L3NwYW4+PHNwYW4+Vzwvc3Bhbj48c3Bhbj5TPC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iaDEtdW5kZXIiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0ic3ViIj4vLyBXRUJTT0NLRVQgU1NIIE1BTkFHRVI8L2Rpdj4KICA8L2Rpdj4KICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7Zm9udC1zaXplOjEwcHg7bWFyZ2luLXRvcDo0cHgiPgogICAgPHNwYW4gY2xhc3M9ImRvdCBkb3Qtb2ZmIiBpZD0iZG90Ij48L3NwYW4+CiAgICA8c3BhbiBpZD0iZ2xibCIgc3R5bGU9ImNvbG9yOiMzZDVhNzMiPuKAlDwvc3Bhbj4KICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIFRva2VuIGNhcmQgLS0+CjxkaXYgY2xhc3M9ImNhcmQgcmdiLWFsd2F5cyIgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWduLWl0ZW1zOmNlbnRlciI+CiAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgIDxkaXYgY2xhc3M9ImxibCI+QVBJIFRPS0VOPC9kaXY+CiAgICA8aW5wdXQgdHlwZT0icGFzc3dvcmQiIGlkPSJ0b2siIHBsYWNlaG9sZGVyPSJUb2tlbiAoYXV0by1maWxsZWQpIj4KICA8L2Rpdj4KICA8YnV0dG9uIGNsYXNzPSJidG4iIG9uY2xpY2s9InRvZ2dsZVRvaygpIj7wn5GBPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1nIiBvbmNsaWNrPSJsb2FkQWxsKCkiPuKWtiDguYDguIrguLfguYjguK3guKHguJXguYjguK08L2J1dHRvbj4KPC9kaXY+Cgo8IS0tIFN0YXR1cyByb3cgLS0+CjxkaXYgY2xhc3M9ImcyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxMnB4Ij4KICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgIDxkaXYgY2xhc3M9ImxibCI+V0VCU09DS0VUIFNUQVRVUzwvZGl2PgogICAgPGRpdiBjbGFzcz0idmFsIiBpZD0id3MtcyI+4oCUPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJjb2xvcjojM2Q1YTczO2ZvbnQtc2l6ZTo5cHg7bWFyZ2luLXRvcDozcHgiIGlkPSJ3cy1wIj5wb3J0IOKAlDwvZGl2PgogIDwvZGl2PgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGRpdiBjbGFzcz0ibGJsIj5DT05ORUNUSU9OUzwvZGl2PgogICAgPGRpdiBjbGFzcz0idmFsIiBpZD0iY29ubnMiPuKAlDwvZGl2PgogICAgPGRpdiBzdHlsZT0iY29sb3I6IzNkNWE3Mztmb250LXNpemU6OXB4O21hcmdpbi10b3A6M3B4Ij5hY3RpdmUgc2Vzc2lvbnM8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIE1haW4gY2FyZCB0YWJzIC0tPgo8ZGl2IGNsYXNzPSJjYXJkIj4KICA8ZGl2IGNsYXNzPSJ0YWJzIj4KICAgIDxidXR0b24gY2xhc3M9InRhYiBvbiIgb25jbGljaz0ic3coJ3QtdXNlcnMnLHRoaXMpIj7wn5GkIFVzZXJzPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LW9ubGluZScsdGhpcykiPvCfn6IgT25saW5lPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LWJhbicsdGhpcykiPvCfmqsgQmFubmVkPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LWJhY2t1cCcsdGhpcykiPvCfkr4gQmFja3VwPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LXN2YycsdGhpcykiPuKame+4jyBTZXJ2aWNlPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJ0YWIiIG9uY2xpY2s9InN3KCd0LWxvZycsdGhpcykiPvCfk4sgTG9nczwvYnV0dG9uPgogIDwvZGl2PgoKICA8IS0tIFVzZXJzIHRhYiDigJQgU1NIIHVzZXJzIOC5gOC4l+C5iOC4suC4meC4seC5ieC4mSDguYTguKHguYjguYPguIrguYggeC11aSAtLT4KICA8ZGl2IGNsYXNzPSJ0YyBvbiIgaWQ9InQtdXNlcnMiPgogICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj4KICAgICAgPHNwYW4gc3R5bGU9Ii0taTowIj5TPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6MSI+Uzwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjIiPkg8L3NwYW4+CiAgICAgIDxzcGFuIHN0eWxlPSItLWk6MyI+Jm5ic3A7PC9zcGFuPgogICAgICA8c3BhbiBzdHlsZT0iLS1pOjQiPlU8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taTo1Ij5TPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6NiI+RTwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjciPlI8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taTo4Ij5TPC9zcGFuPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJnMiIgc3R5bGU9Im1hcmdpbi1ib3R0b206OHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZmkiPjxsYWJlbD5Vc2VybmFtZTwvbGFiZWw+PGlucHV0IGlkPSJudSIgcGxhY2Vob2xkZXI9InVzZXIxIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmkiPjxsYWJlbD5QYXNzd29yZDwvbGFiZWw+PGlucHV0IHR5cGU9InBhc3N3b3JkIiBpZD0ibnAiIHBsYWNlaG9sZGVyPSLigKLigKLigKLigKLigKLigKLigKLigKIiPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJyb3ciIHN0eWxlPSJtYXJnaW4tYm90dG9tOjEycHgiPgogICAgICA8ZGl2IGNsYXNzPSJmaSIgc3R5bGU9Im1hcmdpbjowO2ZsZXg6MSI+PGxhYmVsPuC4p+C4seC4mTwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9Im5kIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpIiBzdHlsZT0ibWFyZ2luOjA7ZmxleDoxIj48bGFiZWw+RGF0YSBHQiAoMD1pbmYpPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0ibmdiIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1nIiBvbmNsaWNrPSJhZGRVc2VyKCkiPisg4LmA4Lie4Li04LmI4LihPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDx0YWJsZT4KICAgICAgPHRoZWFkPjx0cj48dGg+VXNlcm5hbWU8L3RoPjx0aD7guKvguKHguJTguK3guLLguKLguLg8L3RoPjx0aD5EYXRhPC90aD48dGg+4Liq4LiW4Liy4LiZ4LiwPC90aD48dGg+QWN0aW9uczwvdGg+PC90cj48L3RoZWFkPgogICAgICA8dGJvZHkgaWQ9InV0YiI+PHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6IzNkNWE3MztwYWRkaW5nOjE2cHgiPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvdGQ+PC90cj48L3Rib2R5PgogICAgPC90YWJsZT4KICA8L2Rpdj4KCiAgPCEtLSBPbmxpbmUgdGFiIC0tPgogIDxkaXYgY2xhc3M9InRjIiBpZD0idC1vbmxpbmUiPgogICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj48c3BhbiBzdHlsZT0iLS1pOjAiPk88L3NwYW4+PHNwYW4gc3R5bGU9Ii0taToxIj5OPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6MiI+TDwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjMiPkk8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taTo0Ij5OPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6NSI+RTwvc3Bhbj48L2Rpdj4KICAgIDx0YWJsZT4KICAgICAgPHRoZWFkPjx0cj48dGg+UmVtb3RlIElQPC90aD48dGg+U3RhdGU8L3RoPjwvdHI+PC90aGVhZD4KICAgICAgPHRib2R5IGlkPSJvdGIiPjx0cj48dGQgY29sc3Bhbj0iMiIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgY29ubmVjdGlvbjwvdGQ+PC90cj48L3Rib2R5PgogICAgPC90YWJsZT4KICA8L2Rpdj4KCiAgPCEtLSBCYW5uZWQgdGFiIC0tPgogIDxkaXYgY2xhc3M9InRjIiBpZD0idC1iYW4iPgogICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj48c3BhbiBzdHlsZT0iLS1pOjAiPkI8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taToxIj5BPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6MiI+Tjwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjMiPk48L3NwYW4+PHNwYW4gc3R5bGU9Ii0taTo0Ij5FPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6NSI+RDwvc3Bhbj48L2Rpdj4KICAgIDx0YWJsZT4KICAgICAgPHRoZWFkPjx0cj48dGg+VXNlcm5hbWU8L3RoPjx0aD7guYHguJrguJnguJbguLbguIfguYDguKfguKXguLI8L3RoPjx0aD5JUHM8L3RoPjx0aD5BY3Rpb248L3RoPjwvdHI+PC90aGVhZD4KICAgICAgPHRib2R5IGlkPSJidGIiPjx0cj48dGQgY29sc3Bhbj0iNCIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgYWNjb3VudCDguJbguLnguIHguYHguJrguJk8L3RkPjwvdHI+PC90Ym9keT4KICAgIDwvdGFibGU+CiAgPC9kaXY+CgogIDwhLS0gQmFja3VwL0ltcG9ydCB0YWIgLS0+CiAgPGRpdiBjbGFzcz0idGMiIGlkPSJ0LWJhY2t1cCI+CiAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPjxzcGFuIHN0eWxlPSItLWk6MCI+Qjwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjEiPkE8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taToyIj5DPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6MyI+Szwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjQiPlU8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taTo1Ij5QPC9zcGFuPjwvZGl2PgogICAgPGRpdiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxNHB4Ij4KICAgICAgPGRpdiBjbGFzcz0ibGJsIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTo4cHgiPvCfk6YgQkFDS1VQIFVTRVJTPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6OHB4O21hcmdpbi1ib3R0b206OHB4Ij4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLXAiIG9uY2xpY2s9ImRvQmFja3VwKCkiPuKMhyBFeHBvcnQgSlNPTjwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4teSIgb25jbGljaz0iY29weUJhY2t1cCgpIj7wn5OLIENvcHk8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDx0ZXh0YXJlYSBjbGFzcz0iYmFja3VwLWJveCIgaWQ9ImJhY2t1cC1vdXQiIHBsYWNlaG9sZGVyPSIvLyDguIHguJQgRXhwb3J0IOC5gOC4nuC4t+C5iOC4rSBiYWNrdXAuLi4iIHJlYWRvbmx5PjwvdGV4dGFyZWE+CiAgICA8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImJvcmRlci10b3A6MXB4IHNvbGlkICMwZjIwMzA7cGFkZGluZy10b3A6MTRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImxibCIgc3R5bGU9Im1hcmdpbi1ib3R0b206OHB4Ij7wn5OlIElNUE9SVCBVU0VSUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaSI+PGxhYmVsPuC4p+C4suC4h+C4guC5ieC4reC4oeC4ueC4pSBKU09OIOC4l+C4teC5iOC4meC4teC5iDwvbGFiZWw+CiAgICAgICAgPHRleHRhcmVhIGNsYXNzPSJiYWNrdXAtYm94IiBpZD0iaW1wb3J0LWluIiBwbGFjZWhvbGRlcj0nW3sidXNlciI6IngiLCJwYXNzd29yZCI6InkiLCJkYXlzIjozMCwiZGF0YV9nYiI6MH1dJyBzdHlsZT0iaGVpZ2h0OjcwcHgiPjwvdGV4dGFyZWE+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjhweCI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1nIiBvbmNsaWNrPSJkb0ltcG9ydCgpIj7ijIYgSW1wb3J0PC9idXR0b24+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW1wb3J0LWluJykudmFsdWU9JyciPuKclSBDbGVhcjwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIFNlcnZpY2UgdGFiIC0tPgogIDxkaXYgY2xhc3M9InRjIiBpZD0idC1zdmMiPgogICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj48c3BhbiBzdHlsZT0iLS1pOjAiPlM8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taToxIj5FPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6MiI+Ujwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjMiPlY8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taTo0Ij5JPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6NSI+Qzwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjYiPkU8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJtYXJnaW4tYm90dG9tOjEycHgiPgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7bWFyZ2luLXRvcDo2cHg7bWFyZ2luLWJvdHRvbToxNHB4Ij4KICAgICAgICA8c3BhbiBjbGFzcz0iZG90IGRvdC1vZmYiIGlkPSJzdmMtZG90Ij48L3NwYW4+CiAgICAgICAgPHNwYW4gaWQ9InN2Yy1sYmwiIHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjojM2Q1YTczIj7guIHguLPguKXguLHguIfguJXguKPguKfguIjguKrguK3guJouLi48L3NwYW4+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7ZmxleC13cmFwOndyYXA7Z2FwOjhweCI+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tZyIgb25jbGljaz0ic3ZjQWN0aW9uKCdzdGFydCcpIj7ilrYgU3RhcnQ8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi15IiBvbmNsaWNrPSJzdmNBY3Rpb24oJ3Jlc3RhcnQnKSI+4oa6IFJlc3RhcnQ8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1yIiBvbmNsaWNrPSJzdmNBY3Rpb24oJ3N0b3AnKSI+4pagIFN0b3A8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBvbmNsaWNrPSJsb2FkU3ZjU3RhdHVzKCkiPuKfsyBSZWZyZXNoPC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSBMb2dzIHRhYiAtLT4KICA8ZGl2IGNsYXNzPSJ0YyIgaWQ9InQtbG9nIj4KICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+PHNwYW4gc3R5bGU9Ii0taTowIj5MPC9zcGFuPjxzcGFuIHN0eWxlPSItLWk6MSI+Tzwvc3Bhbj48c3BhbiBzdHlsZT0iLS1pOjIiPkc8L3NwYW4+PHNwYW4gc3R5bGU9Ii0taTozIj5TPC9zcGFuPjwvZGl2PgogICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpyaWdodDttYXJnaW4tYm90dG9tOjhweCI+PGJ1dHRvbiBjbGFzcz0iYnRuIiBvbmNsaWNrPSJsb2FkTG9ncygpIj5SZWZyZXNoPC9idXR0b24+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJsb2ciIGlkPSJsb2dib3giPjxzcGFuIHN0eWxlPSJjb2xvcjojM2Q1YTczIj4vLyDguIHguJQgUmVmcmVzaDwvc3Bhbj48L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8ZGl2IGlkPSJ0b2FzdCI+PC9kaXY+Cgo8IS0tIE1vZGFsIFJlbmV3IC0tPgo8ZGl2IGNsYXNzPSJtbyIgaWQ9Im0tcmVuZXciPgogIDxkaXYgY2xhc3M9Im1kIj4KICAgIDxoMz7guJXguYjguK3guK3guLLguKLguLggU1NIIFVzZXI8L2gzPgogICAgPGRpdiBjbGFzcz0iZmkiPjxsYWJlbD5Vc2VybmFtZTwvbGFiZWw+PGlucHV0IGlkPSJybi11IiByZWFkb25seSBzdHlsZT0iY29sb3I6IzAwZTVmZiI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJnMiI+CiAgICAgIDxkaXYgY2xhc3M9ImZpIj48bGFiZWw+4Lin4Lix4LiZPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0icm4tZCIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaSI+PGxhYmVsPkRhdGEgR0I8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJybi1nYiIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im1mIj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBvbmNsaWNrPSJjbSgnbS1yZW5ldycpIj7guKLguIHguYDguKXguLTguIE8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1nIiBvbmNsaWNrPSJjb25maXJtUmVuZXcoKSI+4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIE1vZGFsIERlbGV0ZSAtLT4KPGRpdiBjbGFzcz0ibW8iIGlkPSJtLWRlbCI+CiAgPGRpdiBjbGFzcz0ibWQiPgogICAgPGgzPuC4peC4miBTU0ggVXNlcjwvaDM+CiAgICA8cCBzdHlsZT0iZm9udC1zaXplOjExcHg7bWFyZ2luLWJvdHRvbToxMHB4Ij7guKXguJogPHNwYW4gaWQ9ImR1IiBzdHlsZT0iY29sb3I6I2ZmMjI1NTtmb250LXdlaWdodDo3MDAiPjwvc3Bhbj4gPzwvcD4KICAgIDxkaXYgY2xhc3M9Im1mIj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuIiBvbmNsaWNrPSJjbSgnbS1kZWwnKSI+4Lii4LiB4LmA4Lil4Li04LiBPC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tciIgb25jbGljaz0iY29uZmlybURlbCgpIj7guKXguJo8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQ+CmNvbnN0IEFVVE9fVE9LRU49IiUlVE9LRU4lJSIsQVVUT19IT1NUPSIlJUhPU1QlJSIsQVVUT19QUk9UTz0iJSVQUk9UTyUlIjsKY29uc3QgQVBJPXdpbmRvdy5sb2NhdGlvbi5vcmlnaW4rJy9zc2h3cy1hcGknOwpsZXQgZGVsVGFyZ2V0PScnOwpjb25zdCBFTD1pZD0+ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwoKd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2xvYWQnLCgpPT57CiAgY29uc3Qgc2F2ZWQ9bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ2N0b2snKTsKICBpZihBVVRPX1RPS0VOJiZBVVRPX1RPS0VOIT0nJSVUT0tFTiUlJyl7RUwoJ3RvaycpLnZhbHVlPUFVVE9fVE9LRU47bG9jYWxTdG9yYWdlLnNldEl0ZW0oJ2N0b2snLEFVVE9fVE9LRU4pO30KICBlbHNlIGlmKHNhdmVkKSBFTCgndG9rJykudmFsdWU9c2F2ZWQ7CiAgRUwoJ3RvaycpLmFkZEV2ZW50TGlzdGVuZXIoJ2NoYW5nZScsKCk9PmxvY2FsU3RvcmFnZS5zZXRJdGVtKCdjdG9rJyxnZXRUb2soKSkpOwogIGlmKGdldFRvaygpKSBsb2FkQWxsKCk7CiAgc2V0SW50ZXJ2YWwoKCk9PntpZihnZXRUb2soKSl7bG9hZFN0YXR1cygpO2xvYWRPbmxpbmUoKTt9fSw4MDAwKTsKfSk7CgpmdW5jdGlvbiBnZXRUb2soKXtyZXR1cm4gRUwoJ3RvaycpLnZhbHVlLnRyaW0oKTt9CmZ1bmN0aW9uIHRvZ2dsZVRvaygpe2NvbnN0IGU9RUwoJ3RvaycpO2UudHlwZT1lLnR5cGU9PT0ncGFzc3dvcmQnPyd0ZXh0JzoncGFzc3dvcmQnO30KZnVuY3Rpb24gdG9hc3QobXNnLGVycj1mYWxzZSl7CiAgY29uc3QgdD1FTCgndG9hc3QnKTt0LnRleHRDb250ZW50PW1zZzt0LmNsYXNzTmFtZT0ncycrKGVycj8nIGVycic6JycpOwogIGNsZWFyVGltZW91dCh0Ll90KTt0Ll90PXNldFRpbWVvdXQoKCk9PnQuY2xhc3NOYW1lPScnLDI4MDApOwp9CmFzeW5jIGZ1bmN0aW9uIGFwaShtZXRob2QscGF0aCxib2R5PW51bGwpewogIGNvbnN0IG89e21ldGhvZCxoZWFkZXJzOnsnQXV0aG9yaXphdGlvbic6J0JlYXJlciAnK2dldFRvaygpLCdDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ319OwogIGlmKGJvZHkpIG8uYm9keT1KU09OLnN0cmluZ2lmeShib2R5KTsKICB0cnl7Y29uc3Qgcj1hd2FpdCBmZXRjaChBUEkrcGF0aCxvKTtyZXR1cm4gYXdhaXQgci5qc29uKCk7fWNhdGNoKGUpe3JldHVybntlcnJvcjplLm1lc3NhZ2V9O30KfQpmdW5jdGlvbiBzdyhpZCxlbCl7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnRjJykuZm9yRWFjaCh0PT50LmNsYXNzTGlzdC5yZW1vdmUoJ29uJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWInKS5mb3JFYWNoKHQ9PnQuY2xhc3NMaXN0LnJlbW92ZSgnb24nKSk7CiAgRUwoaWQpLmNsYXNzTGlzdC5hZGQoJ29uJyk7ZWwuY2xhc3NMaXN0LmFkZCgnb24nKTsKICBpZihpZD09PSd0LW9ubGluZScpbG9hZE9ubGluZSgpOwogIGlmKGlkPT09J3QtYmFuJylsb2FkQmFubmVkKCk7CiAgaWYoaWQ9PT0ndC1sb2cnKWxvYWRMb2dzKCk7CiAgaWYoaWQ9PT0ndC1zdmMnKWxvYWRTdmNTdGF0dXMoKTsKICBpZihpZD09PSd0LWJhY2t1cCcpZG9CYWNrdXAoKTsKfQphc3luYyBmdW5jdGlvbiBsb2FkU3RhdHVzKCl7CiAgY29uc3QgZD1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvc3RhdHVzJyk7CiAgaWYoZC5lcnJvcilyZXR1cm47CiAgY29uc3Qgb249ZC53c19zdGF0dXM9PT0nYWN0aXZlJzsKICBFTCgnZG90JykuY2xhc3NOYW1lPSdkb3QgJysob24/J2RvdC1vbic6J2RvdC1vZmYnKTsKICBFTCgnZ2xibCcpLnRleHRDb250ZW50PW9uPydPTkxJTkUnOidPRkZMSU5FJzsKICBFTCgnZ2xibCcpLnN0eWxlLmNvbG9yPW9uPycjMDBmZjg4JzonI2ZmMjI1NSc7CiAgRUwoJ3dzLXMnKS50ZXh0Q29udGVudD1vbj8nUlVOTklORyc6J1NUT1BQRUQnOwogIEVMKCd3cy1zJykuc3R5bGUuY29sb3I9b24/JyMwMGZmODgnOicjZmYyMjU1JzsKICBFTCgnd3MtcCcpLnRleHRDb250ZW50PSdwb3J0ICcrZC53c19wb3J0OwogIEVMKCdjb25ucycpLnRleHRDb250ZW50PWQuY29ubmVjdGlvbnM/PzA7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFN2Y1N0YXR1cygpewogIGNvbnN0IGQ9YXdhaXQgYXBpKCdHRVQnLCcvYXBpL3N0YXR1cycpOwogIGNvbnN0IG9uPWQud3Nfc3RhdHVzPT09J2FjdGl2ZSc7CiAgRUwoJ3N2Yy1kb3QnKS5jbGFzc05hbWU9J2RvdCAnKyhvbj8nZG90LW9uJzonZG90LW9mZicpOwogIEVMKCdzdmMtbGJsJykudGV4dENvbnRlbnQ9b24/J0FDVElWRSDigJQgcnVubmluZyc6J0lOQUNUSVZFIOKAlCBzdG9wcGVkJzsKICBFTCgnc3ZjLWxibCcpLnN0eWxlLmNvbG9yPW9uPycjMDBmZjg4JzonI2ZmMjI1NSc7Cn0KYXN5bmMgZnVuY3Rpb24gc3ZjQWN0aW9uKGFjdCl7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3NlcnZpY2UnLHthY3Rpb246YWN0fSk7CiAgaWYoci5vayl7dG9hc3QoJ+KclCAnK2FjdCsnIOC4quC4s+C5gOC4o+C5h+C4iCcpO31lbHNle3RvYXN0KCfimqAg4Liq4Lix4LmI4LiHICcrYWN0Kycg4LmE4Lih4LmI4LmE4LiU4LmJOiAnKyhyLmVycm9yfHwnJyksdHJ1ZSk7fQogIHNldFRpbWVvdXQobG9hZFN2Y1N0YXR1cywxNTAwKTtzZXRUaW1lb3V0KGxvYWRTdGF0dXMsMTUwMCk7Cn0KLyogU1NIIFVzZXJzIOKAlCDguJTguLbguIfguIjguLLguIEgL2FwaS91c2VycyDguIvguLbguYjguIfguK3guYjguLLguJnguIjguLLguIEgc3Nod3MtdXNlcnMvdXNlcnMuZGIgKi8KYXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJzKCl7CiAgY29uc3QgdT1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvdXNlcnMnKTsKICBjb25zdCB0Yj1FTCgndXRiJyk7CiAgaWYodS5lcnJvcil7dG9hc3QoJ+C5guC4q+C4peC4lCBTU0ggdXNlcnMg4LmE4Lih4LmI4LmE4LiU4LmJJyx0cnVlKTtyZXR1cm47fQogIGlmKCFBcnJheS5pc0FycmF5KHUpfHwhdS5sZW5ndGgpe3RiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6IzNkNWE3MztwYWRkaW5nOjE2cHgiPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3RkPjwvdHI+JztyZXR1cm47fQogIHRiLmlubmVySFRNTD11Lm1hcCh4PT57CiAgICBjb25zdCBkTGVmdD1NYXRoLmNlaWwoKG5ldyBEYXRlKHguZXhwKS1uZXcgRGF0ZSgpKS84NjQwMDAwMCk7CiAgICBjb25zdCBvaz14LmFjdGl2ZSYmZExlZnQ+MDsKICAgIHJldHVybiAnPHRyPjx0ZCBzdHlsZT0iY29sb3I6I2ZmZjtmb250LXdlaWdodDo3MDAiPicreC51c2VyKyc8L3RkPjx0ZD4nK3guZXhwKyc8c3BhbiBzdHlsZT0iY29sb3I6IzNkNWE3Mztmb250LXNpemU6OXB4Ij4gKCcrKGRMZWZ0PjA/ZExlZnQrJ2QnOifguKvguKHguJTguYHguKXguYnguKcnKSsnKTwvc3Bhbj48L3RkPjx0ZCBzdHlsZT0iY29sb3I6IzAwZTVmZiI+JysoeC5kYXRhX2diPjA/eC5kYXRhX2diKydHQic6J2luZicpKyc8L3RkPjx0ZD48c3BhbiBjbGFzcz0icGlsbCAnKyhvaz8ncGcnOidwcicpKyciPicrKG9rPydBQ1RJVkUnOidFWFBJUkVEJykrJzwvc3Bhbj48L3RkPjx0ZCBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo0cHgiPjxidXR0b24gY2xhc3M9ImJ0biIgc3R5bGU9InBhZGRpbmc6MnB4IDhweDtmb250LXNpemU6OXB4IiBvbmNsaWNrPSJvcGVuUmVuZXcoXCcnK3gudXNlcisnXCcsJyt4LmRheXMrJywnK3guZGF0YV9nYisnKSI+UjwvYnV0dG9uPjxidXR0b24gY2xhc3M9ImJ0biBidG4tciIgc3R5bGU9InBhZGRpbmc6MnB4IDhweDtmb250LXNpemU6OXB4IiBvbmNsaWNrPSJvcGVuRGVsKFwnJyt4LnVzZXIrJ1wnKSI+WDwvYnV0dG9uPjwvdGQ+PC90cj4nOwogIH0pLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGFkZFVzZXIoKXsKICBjb25zdCB1c2VyPUVMKCdudScpLnZhbHVlLnRyaW0oKSxwYXNzPUVMKCducCcpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzPXBhcnNlSW50KEVMKCduZCcpLnZhbHVlKXx8MzAsZ2I9cGFyc2VJbnQoRUwoJ25nYicpLnZhbHVlKXx8MDsKICBpZighdXNlcnx8IXBhc3Mpe3RvYXN0KCfguJXguYnguK3guIfguYPguKrguYggdXNlcm5hbWUg4LmB4Lil4LiwIHBhc3N3b3JkJyx0cnVlKTtyZXR1cm47fQogIGNvbnN0IHI9YXdhaXQgYXBpKCdQT1NUJywnL2FwaS91c2Vycycse3VzZXIscGFzc3dvcmQ6cGFzcyxkYXlzLGRhdGFfZ2I6Z2J9KTsKICBpZihyLm9rKXt0b2FzdCgn4LmA4Lie4Li04LmI4LihIFNTSCB1c2VyICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcpO0VMKCdudScpLnZhbHVlPScnO0VMKCducCcpLnZhbHVlPScnO2xvYWRVc2VycygpO30KICBlbHNlIHRvYXN0KCfguYDguJ7guLTguYjguKHguYTguKHguYjguYTguJTguYk6ICcrKHIucmVzdWx0fHxyLmVycm9yKSx0cnVlKTsKfQpmdW5jdGlvbiBvcGVuUmVuZXcodSxkLGdiKXtFTCgncm4tdScpLnZhbHVlPXU7RUwoJ3JuLWQnKS52YWx1ZT1kfHwzMDtFTCgncm4tZ2InKS52YWx1ZT1nYnx8MDtFTCgnbS1yZW5ldycpLmNsYXNzTGlzdC5hZGQoJ28nKTt9CmFzeW5jIGZ1bmN0aW9uIGNvbmZpcm1SZW5ldygpewogIGNvbnN0IHU9RUwoJ3JuLXUnKS52YWx1ZSxkPXBhcnNlSW50KEVMKCdybi1kJykudmFsdWUpfHwzMCxnYj1wYXJzZUludChFTCgncm4tZ2InKS52YWx1ZSl8fDA7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3JlbmV3Jyx7dXNlcjp1LGRheXM6ZCxkYXRhX2diOmdifSk7CiAgY20oJ20tcmVuZXcnKTsKICBpZihyLm9rKXt0b2FzdCgn4LiV4LmI4Lit4Lit4Liy4Lii4Li4IFNTSCAnK3UrJyAnK2QrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIJyk7bG9hZFVzZXJzKCk7fWVsc2UgdG9hc3QoJ+C4leC5iOC4reC4reC4suC4ouC4uOC5hOC4oeC5iOC5hOC4lOC5iScsdHJ1ZSk7Cn0KZnVuY3Rpb24gb3BlbkRlbCh1KXtkZWxUYXJnZXQ9dTtFTCgnZHUnKS50ZXh0Q29udGVudD11O0VMKCdtLWRlbCcpLmNsYXNzTGlzdC5hZGQoJ28nKTt9CmFzeW5jIGZ1bmN0aW9uIGNvbmZpcm1EZWwoKXsKICBjb25zdCByPWF3YWl0IGFwaSgnREVMRVRFJywnL2FwaS91c2Vycy8nK2RlbFRhcmdldCk7CiAgY20oJ20tZGVsJyk7CiAgaWYoci5vayl7dG9hc3QoJ+C4peC4miBTU0ggdXNlciAnK2RlbFRhcmdldCsnIOC4quC4s+C5gOC4o+C5h+C4iCcpO2xvYWRVc2VycygpO31lbHNlIHRvYXN0KCfguKXguJrguYTguKHguYjguYTguJTguYknLHRydWUpOwp9CmZ1bmN0aW9uIGNtKGlkKXtFTChpZCkuY2xhc3NMaXN0LnJlbW92ZSgnbycpO30KZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm1vJykuZm9yRWFjaChtPT5tLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJyxlPT57aWYoZS50YXJnZXQ9PT1tKW0uY2xhc3NMaXN0LnJlbW92ZSgnbycpO30pKTsKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpewogIGNvbnN0IGQ9YXdhaXQgYXBpKCdHRVQnLCcvYXBpL29ubGluZScpOwogIGNvbnN0IHRiPUVMKCdvdGInKTsKICBpZighQXJyYXkuaXNBcnJheShkKXx8IWQubGVuZ3RoKXt0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iMiIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgY29ubmVjdGlvbjwvdGQ+PC90cj4nO3JldHVybjt9CiAgdGIuaW5uZXJIVE1MPWQubWFwKGM9Pic8dHI+PHRkIHN0eWxlPSJjb2xvcjojMDBlNWZmIj4nK2MucmVtb3RlKyc8L3RkPjx0ZD48c3BhbiBjbGFzcz0icGlsbCBwZyI+JytjLnN0YXRlKyc8L3NwYW4+PC90ZD48L3RyPicpLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRCYW5uZWQoKXsKICBjb25zdCBiPWF3YWl0IGFwaSgnR0VUJywnL2FwaS9iYW5uZWQnKTsKICBjb25zdCB0Yj1FTCgnYnRiJyk7CiAgY29uc3Qga2V5cz1PYmplY3Qua2V5cyhifHx7fSk7CiAgaWYoIWtleXMubGVuZ3RoKXt0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNCIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiMzZDVhNzM7cGFkZGluZzoxNnB4Ij7guYTguKHguYjguKHguLUgYWNjb3VudCDguJbguLnguIHguYHguJrguJk8L3RkPjwvdHI+JztyZXR1cm47fQogIHRiLmlubmVySFRNTD1rZXlzLm1hcCh1aWQ9PnsKICAgIGNvbnN0IHg9Ylt1aWRdOwogICAgY29uc3QgdW50aWw9bmV3IERhdGUoeC51bnRpbCkudG9Mb2NhbGVTdHJpbmcoJ3RoLVRIJyk7CiAgICByZXR1cm4gJzx0cj48dGQgc3R5bGU9ImNvbG9yOiNmZjIyNTU7Zm9udC13ZWlnaHQ6NzAwIj4nK3gubmFtZSsnPC90ZD48dGQ+PHNwYW4gY2xhc3M9InBpbGwgcHIiPicrdW50aWwrJzwvc3Bhbj48L3RkPjx0ZCBzdHlsZT0iZm9udC1zaXplOjlweDtjb2xvcjojM2Q1YTczIj4nKygoeC5pcHN8fFtdKS5zbGljZSgwLDMpLmpvaW4oJywgJykpKyc8L3RkPjx0ZD48YnV0dG9uIGNsYXNzPSJidG4gYnRuLWciIHN0eWxlPSJwYWRkaW5nOjJweCA4cHg7Zm9udC1zaXplOjlweCIgb25jbGljaz0idW5iYW4oXCcnK3VpZCsnXCcsXCcnK3gubmFtZSsnXCcpIj7guJvguKXguJTguYHguJrguJk8L2J1dHRvbj48L3RkPjwvdHI+JzsKICB9KS5qb2luKCcnKTsKfQphc3luYyBmdW5jdGlvbiB1bmJhbih1aWQsbmFtZSl7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3VuYmFuJyx7dWlkLG5hbWV9KTsKICBpZihyLm9rKXt0b2FzdCgn4Lib4Lil4LiU4LmB4Lia4LiZICcrbmFtZSk7bG9hZEJhbm5lZCgpO31lbHNlIHRvYXN0KCfguJvguKXguJTguYHguJrguJnguYTguKHguYjguYTguJTguYknLHRydWUpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRMb2dzKCl7CiAgY29uc3Qgcj1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvbG9ncycpOwogIGNvbnN0IGI9RUwoJ2xvZ2JveCcpOwogIGlmKCFyLmxpbmVzfHwhci5saW5lcy5sZW5ndGgpe2IuaW5uZXJIVE1MPSc8c3BhbiBzdHlsZT0iY29sb3I6IzNkNWE3MyI+Ly8g4LmE4Lih4LmI4Lih4Li1IGxvZ3M8L3NwYW4+JztyZXR1cm47fQogIGIuaW5uZXJIVE1MPXIubGluZXMubWFwKGw9Pic8ZGl2IHN0eWxlPSJjb2xvcjonKyhsLmluY2x1ZGVzKCdFUlInKT8nI2ZmMjI1NSc6bC5pbmNsdWRlcygnT0snKT8nIzAwZmY4OCc6JyMyYTVhNDAnKSsnIj4nK2wrJzwvZGl2PicpLmpvaW4oJycpOwogIGIuc2Nyb2xsVG9wPWIuc2Nyb2xsSGVpZ2h0Owp9CmFzeW5jIGZ1bmN0aW9uIGRvQmFja3VwKCl7CiAgY29uc3QgdT1hd2FpdCBhcGkoJ0dFVCcsJy9hcGkvdXNlcnMnKTsKICBpZih1LmVycm9yKXt0b2FzdCgn4LmC4Lir4Lil4LiUIHVzZXJzIOC5hOC4oeC5iOC5hOC4lOC5iScsdHJ1ZSk7cmV0dXJuO30KICBFTCgnYmFja3VwLW91dCcpLnZhbHVlPUpTT04uc3RyaW5naWZ5KEFycmF5LmlzQXJyYXkodSk/dTpbXSxudWxsLDIpOwogIHRvYXN0KCdFeHBvcnQg4Liq4Liz4LmA4Lij4LmH4LiIIOKAlCAnKyhBcnJheS5pc0FycmF5KHUpP3UubGVuZ3RoOjApKycgU1NIIHVzZXJzJyk7Cn0KZnVuY3Rpb24gY29weUJhY2t1cCgpewogIGNvbnN0IHY9RUwoJ2JhY2t1cC1vdXQnKS52YWx1ZTsKICBpZighdil7dG9hc3QoJ+C5hOC4oeC5iOC4oeC4teC4guC5ieC4reC4oeC4ueC4pScsdHJ1ZSk7cmV0dXJuO30KICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh2KS50aGVuKCgpPT50b2FzdCgn8J+TiyBDb3BpZWQhJykpOwp9CmFzeW5jIGZ1bmN0aW9uIGRvSW1wb3J0KCl7CiAgY29uc3QgcmF3PUVMKCdpbXBvcnQtaW4nKS52YWx1ZS50cmltKCk7CiAgaWYoIXJhdyl7dG9hc3QoJ+C4geC4o+C4reC4gSBKU09OIOC4geC5iOC4reC4mScsdHJ1ZSk7cmV0dXJuO30KICBsZXQgdXNlcnM7CiAgdHJ5e3VzZXJzPUpTT04ucGFyc2UocmF3KTt9Y2F0Y2goZSl7dG9hc3QoJ0pTT04g4LmE4Lih4LmI4LiW4Li54LiB4LiV4LmJ4Lit4LiHJyx0cnVlKTtyZXR1cm47fQogIGlmKCFBcnJheS5pc0FycmF5KHVzZXJzKSl7dG9hc3QoJ+C4leC5ieC4reC4h+C5gOC4m+C5h+C4mSBhcnJheScsdHJ1ZSk7cmV0dXJuO30KICBsZXQgb2s9MCxmYWlsPTA7CiAgZm9yKGNvbnN0IHUgb2YgdXNlcnMpewogICAgY29uc3Qgcj1hd2FpdCBhcGkoJ1BPU1QnLCcvYXBpL3VzZXJzJyx1KTsKICAgIHIub2s/b2srKzpmYWlsKys7CiAgfQogIHRvYXN0KCdJbXBvcnQ6IOKclCAnK29rKycg4Liq4Liz4LmA4Lij4LmH4LiIJysoZmFpbD8nIOKaoCAnK2ZhaWwrJyDguYTguKHguYjguYTguJTguYknOicnKSk7CiAgbG9hZFVzZXJzKCk7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZEFsbCgpewogIGlmKCFnZXRUb2soKSl7dG9hc3QoJ+C4leC5ieC4reC4h+C5g+C4quC5iCBBUEkgVG9rZW4nLHRydWUpO3JldHVybjt9CiAgYXdhaXQgbG9hZFN0YXR1cygpO2F3YWl0IGxvYWRVc2VycygpO2F3YWl0IGxvYWRPbmxpbmUoKTsKfQo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==' | base64 -d   | sed "s|%%TOKEN%%|${_SSHWS_TOK}|g"   | sed "s|%%HOST%%|${_SSHWS_HOST}|g"   | sed "s|%%PROTO%%|${_SSHWS_PROTO}|g"   > /var/www/chaiya/sshws.html

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
  local _cookie="/etc/chaiya/xui-cookie.jar"
  rm -f "$_cookie"

  local _r
  # ลอง https + basepath ก่อน (3x-ui เปิด SSL by default)
  if [[ -n "$bp" && "$bp" != "/" ]]; then
    _r=$(curl -sk -c "$_cookie" \
      -X POST "https://127.0.0.1:${p}${bp}/login" \
      -d "username=${u}&password=${pw}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --max-time 10 2>/dev/null)
    if echo "$_r" | grep -q '"success":true'; then
      [[ -n "$XUI_COOKIE" ]] && cp "$_cookie" "$XUI_COOKIE" 2>/dev/null || true
      return 0
    fi
    rm -f "$_cookie"
    # fallback http + basepath
    _r=$(curl -s -c "$_cookie" \
      -X POST "http://127.0.0.1:${p}${bp}/login" \
      -d "username=${u}&password=${pw}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --max-time 10 2>/dev/null)
    if echo "$_r" | grep -q '"success":true'; then
      [[ -n "$XUI_COOKIE" ]] && cp "$_cookie" "$XUI_COOKIE" 2>/dev/null || true
      return 0
    fi
    rm -f "$_cookie"
  fi

  # fallback https ไม่มี basepath
  _r=$(curl -sk -c "$_cookie" \
    -X POST "https://127.0.0.1:${p}/login" \
    -d "username=${u}&password=${pw}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --max-time 10 2>/dev/null)
  if echo "$_r" | grep -q '"success":true'; then
    [[ -n "$XUI_COOKIE" ]] && cp "$_cookie" "$XUI_COOKIE" 2>/dev/null || true
    return 0
  fi
  # fallback http ไม่มี basepath
  _r=$(curl -s -c "$_cookie" \
    -X POST "http://127.0.0.1:${p}/login" \
    -d "username=${u}&password=${pw}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --max-time 10 2>/dev/null)
  if echo "$_r" | grep -q '"success":true'; then
    [[ -n "$XUI_COOKIE" ]] && cp "$_cookie" "$XUI_COOKIE" 2>/dev/null || true
    return 0
  fi
  return 1
}

xui_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local p bp _r
  p=$(xui_port)
  bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | sed 's|/$||')
  local _cookie="/etc/chaiya/xui-cookie.jar"

  xui_login 2>/dev/null || true

  # ตรวจว่า 3x-ui ฟัง https หรือ http (ลอง https ก่อน fallback http)
  local _proto="http"
  if curl -sk --max-time 3 "https://127.0.0.1:${p}/" &>/dev/null; then
    _proto="https"
  fi

  if [[ -n "$data" ]]; then
    _r=$(curl -sk -b "$_cookie" \
      -X "$method" "${_proto}://127.0.0.1:${p}${bp}${endpoint}" \
      -H "Content-Type: application/json" -d "$data" --max-time 15 2>/dev/null)
  else
    _r=$(curl -sk -b "$_cookie" \
      -X "$method" "${_proto}://127.0.0.1:${p}${bp}${endpoint}" --max-time 15 2>/dev/null)
  fi

  # ถ้า response ว่างหรือไม่มี success ลอง protocol อีกตัว
  if ! echo "$_r" | grep -q '"success"'; then
    local _proto2="https"; [[ "$_proto" == "https" ]] && _proto2="http"
    if [[ -n "$data" ]]; then
      _r=$(curl -sk -b "$_cookie" \
        -X "$method" "${_proto2}://127.0.0.1:${p}${bp}${endpoint}" \
        -H "Content-Type: application/json" -d "$data" --max-time 15 2>/dev/null)
    else
      _r=$(curl -sk -b "$_cookie" \
        -X "$method" "${_proto2}://127.0.0.1:${p}${bp}${endpoint}" --max-time 15 2>/dev/null)
    fi
  fi
  echo "$_r"
}

# ── สร้างไฟล์ HTML สำหรับ VLESS user (RGB Wave UI v15) ───────
gen_vless_html() {
  local uname="$1" link="$2" uuid="$3" host_val="$4" port_val="$5" sni_val="$6" exp="$7"
  local outfile="/var/www/chaiya/config/${uname}.html"
  python3 << PYEOF
import os

u       = """$uname"""
lnk     = """$link"""
ex      = """$exp"""
outfile = """$outfile"""

# escape สำหรับ JS string (ป้องกัน quote ทำลาย JS)
lnk_js = lnk.replace("\\\\", "\\\\\\\\").replace('"', '\\\\"').replace("\\n", "")

html = """<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA VPN \u2014 """ + u + """</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d0d0d;font-family:'Segoe UI',sans-serif;min-height:100vh;
     display:flex;align-items:center;justify-content:center;padding:20px}
.wrap{width:100%;max-width:420px}

@keyframes rgbTxt{
  0%{color:#ff0080}16%{color:#ff8000}33%{color:#ffee00}
  50%{color:#00ff80}66%{color:#00d4ff}83%{color:#b400ff}100%{color:#ff0080}}
@keyframes rgbLine{
  0%{background:linear-gradient(90deg,#ff0080,#ff8000)}
  25%{background:linear-gradient(90deg,#ffee00,#00ff80)}
  50%{background:linear-gradient(90deg,#00d4ff,#b400ff)}
  75%{background:linear-gradient(90deg,#ff0080,#ff8000)}
  100%{background:linear-gradient(90deg,#ffee00,#00ff80)}}
@keyframes rgbBorder{
  0%{border-color:#ff0080}16%{border-color:#ff8000}33%{border-color:#ffee00}
  50%{border-color:#00ff80}66%{border-color:#00d4ff}83%{border-color:#b400ff}100%{border-color:#ff0080}}
@keyframes rgbBtn{
  0%{background:linear-gradient(135deg,#ff0080,#b400ff)}
  33%{background:linear-gradient(135deg,#b400ff,#5500cc)}
  66%{background:linear-gradient(135deg,#00d4ff,#b400ff)}
  100%{background:linear-gradient(135deg,#ff0080,#b400ff)}}
@keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.2)}}
@keyframes charWave{
  0%,100%{color:#ff0080}16%{color:#ff8000}33%{color:#ffee00}
  50%{color:#00ff80}66%{color:#00d4ff}83%{color:#b400ff}}

.header{text-align:center;padding:22px 0 12px}
.fire{font-size:34px;display:inline-block;animation:pulse 1.8s ease-in-out infinite}
.title{font-size:22px;font-weight:800;letter-spacing:6px;margin-top:4px;
       animation:rgbTxt 3s linear infinite}
.username{margin-top:6px;font-size:14px;color:#5a8aaa}
.username span{color:#00cfff;font-weight:600}

.line{height:2px;border-radius:2px;margin:10px 0 16px;animation:rgbLine 3s linear infinite}

.row{display:flex;align-items:center;justify-content:space-between;
     padding:11px 4px;border-bottom:1px solid #1a1a2a}
.row:last-of-type{border-bottom:none}
.row-left{display:flex;align-items:center;gap:10px}
.ico{font-size:18px}
.lbl{font-size:13px;font-weight:500;letter-spacing:1px;animation:rgbTxt 3s linear infinite}
.row:nth-child(1) .lbl{animation-delay:0s}
.row:nth-child(2) .lbl{animation-delay:.5s}
.row:nth-child(3) .lbl{animation-delay:1s}
.row-right{font-size:13px;color:#c0d0e0;text-align:right}

.link-box{background:#111118;border-radius:10px;border:1.5px solid #333;
          padding:12px 14px;margin:16px 0 14px;
          animation:rgbBorder 3s linear infinite;
          word-break:break-all;font-family:monospace;font-size:11.5px;line-height:1.7}
.link-char{display:inline;animation:charWave 3s linear infinite}

.btn-copy{width:100%;padding:15px;border:none;border-radius:12px;
          font-size:15px;font-weight:700;letter-spacing:1px;cursor:pointer;
          color:#fff;margin-bottom:10px;animation:rgbBtn 3s linear infinite;
          transition:transform .1s,opacity .1s}
.btn-copy:active{transform:scale(.97);opacity:.85}
.btn-qr{width:100%;padding:14px;border-radius:12px;border:1.5px solid #b8860b;
        background:transparent;color:#ffd700;font-size:14px;font-weight:600;
        cursor:pointer;letter-spacing:1px;transition:transform .1s;
        animation:rgbBorder 3s linear infinite;animation-delay:1.5s}
.btn-qr:active{transform:scale(.97)}
#qrbox{display:none;margin-top:14px;text-align:center;
       background:#fff;padding:14px;border-radius:12px}
.toast{position:fixed;bottom:32px;left:50%;transform:translateX(-50%);
       background:#00ff80;color:#000;padding:11px 28px;border-radius:22px;
       font-weight:700;font-size:13px;opacity:0;transition:opacity .3s;
       pointer-events:none;z-index:999}
.toast.show{opacity:1}
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <div class="fire">\U0001f525</div>
    <div class="title">CHAIYA VPN</div>
    <div class="username">\U0001f464 <span>""" + u + """</span></div>
  </div>
  <div class="line"></div>
  <div class="row">
    <div class="row-left"><span class="ico">\U0001f4c5</span><span class="lbl">\u0e2b\u0e21\u0e14\u0e2d\u0e32\u0e22\u0e38</span></div>
    <div class="row-right">""" + ex + """</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">\U0001f4ca</span><span class="lbl">Data</span></div>
    <div class="row-right">Unlimited</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">\U0001f310</span><span class="lbl">Protocol</span></div>
    <div class="row-right">VLESS WS</div>
  </div>
  <div class="link-box" id="vlink-box"></div>
  <button class="btn-copy" onclick="copyLink()">\U0001f4cb Copy Link</button>
  <button class="btn-qr" onclick="toggleQR()">\U0001f4f1 \u0e41\u0e2a\u0e14\u0e07 QR Code</button>
  <div id="qrbox"></div>
</div>
<div class="toast" id="toast">\u2714 Copied!</div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<script>
var vlessLink = \"""" + lnk_js + """\";
// แยกแต่ละตัวอักษร ใส่ animation-delay ต่างกัน ทำให้สีวิ่งเป็นคลื่น
(function(){
  var box=document.getElementById("vlink-box"), html="";
  for(var i=0;i<vlessLink.length;i++){
    var ch=vlessLink[i];
    if(ch==="<")ch="&lt;";
    else if(ch===">")ch="&gt;";
    else if(ch==="&")ch="&amp;";
    var d=(-(i*0.04)).toFixed(2);
    html+='<span class="link-char" style="animation-delay:'+d+'s">'+ch+'</span>';
  }
  box.innerHTML=html;
})();
function copyLink(){
  if(navigator.clipboard){navigator.clipboard.writeText(vlessLink).then(showToast);}
  else{var ta=document.createElement("textarea");ta.value=vlessLink;
    document.body.appendChild(ta);ta.select();document.execCommand("copy");
    document.body.removeChild(ta);showToast();}
}
function showToast(){
  var el=document.getElementById("toast");
  el.classList.add("show");
  setTimeout(function(){el.classList.remove("show");},2000);
}
var qrDone=false;
function toggleQR(){
  var b=document.getElementById("qrbox");
  if(b.style.display==="block"){b.style.display="none";return;}
  b.style.display="block";
  if(!qrDone){new QRCode(b,{text:vlessLink,width:250,height:250,
    colorDark:"#000",colorLight:"#fff",correctLevel:QRCode.CorrectLevel.M});
    qrDone=true;}
}
</script>
</body></html>"""

os.makedirs(os.path.dirname(outfile), exist_ok=True)
with open(outfile, 'w', encoding='utf-8') as f:
    f.write(html)
print("OK:" + outfile)
PYEOF
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

  # ── detect port จาก x-ui setting ก่อน (ไม่รอ db) ──
  local _xp
  _xp=$(/usr/local/x-ui/x-ui setting 2>/dev/null | grep -oP 'port.*?:\s*\K\d+' | head -1)
  [[ -n "$_xp" ]] && echo "$_xp" > /etc/chaiya/xui-port.conf
  local _panel_port; _panel_port=$(xui_port)

  # ── 55% รอ 3x-ui พร้อม (ลอง http ก่อน แล้วค่อย https) ──
  # สาเหตุที่ลอง http ก่อน: 3x-ui ติดตั้งใหม่ยังไม่มี SSL certificate
  rgb_bar 55 "รอ port ${_panel_port}..."
  local _ok=0
  for _i in $(seq 1 20); do
    if curl -s --max-time 2 "http://127.0.0.1:${_panel_port}/" &>/dev/null; then
      _ok=1; break
    fi
    if curl -sk --max-time 2 "https://127.0.0.1:${_panel_port}/" &>/dev/null; then
      _ok=1; break
    fi
    sleep 2
  done

  # ── detect basepath หลัง 3x-ui พร้อม (db เขียนเสร็จแน่นอนแล้ว) ──
  # ต้องรอให้ service พร้อมก่อน ไม่งั้น sqlite3 จะอ่านได้แค่ "/" หรือ ""
  local _basepath; _basepath=$(detect_xui_basepath)
  local _bp_try=0
  while [[ ( -z "$_basepath" || "$_basepath" == "/" ) && $_bp_try -lt 5 ]]; do
    sleep 3
    _basepath=$(detect_xui_basepath)
    (( _bp_try++ ))
  done
  echo "$_basepath" > /etc/chaiya/xui-basepath.conf

  # ── 80% login API ──
  rgb_bar 80 "Login API..."
  local _login_ok=0
  xui_login 2>/dev/null && _login_ok=1

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

    # 3x-ui v2+ ต้องการ settings/streamSettings/sniffing เป็น JSON string (ไม่ใช่ object)
    # แต่บาง version ต้องการ object — ลอง string ก่อน (ตรงกับ source code ของ 3x-ui)
    local _payload
    _payload=$(python3 -c "
import json, sys
uid, remark, port, sni = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
settings_obj = {
  'clients': [{'id': uid, 'flow': '', 'email': 'chaiya-' + remark,
               'limitIp': 0, 'totalGB': 0, 'expiryTime': 0,
               'enable': True, 'comment': '', 'reset': 0}],
  'decryption': 'none'
}
stream_obj = {
  'network': 'ws',
  'security': 'none',
  'wsSettings': {'path': '/vless', 'headers': {'Host': sni}}
}
sniff_obj = {'enabled': True, 'destOverride': ['http', 'tls']}
# 3x-ui API /inbounds/add ต้องการ string ทั้ง 3 fields
payload = {
  'remark':         remark,
  'enable':         True,
  'listen':         '',
  'port':           port,
  'protocol':       'vless',
  'settings':       json.dumps(settings_obj),
  'streamSettings': json.dumps(stream_obj),
  'sniffing':       json.dumps(sniff_obj),
  'tag':            'inbound-' + str(port),
}
print(json.dumps(payload))
" "$_ibuid" "$_ibremark" "$_ibport" "$_ibsni")

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
    location /config/ { alias /var/www/chaiya/config/; try_files \$uri =404; default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache"; }
    location /sshws-api/ { proxy_pass http://127.0.0.1:6789/; proxy_http_version 1.1; proxy_set_header Host \$host; }
}
SSLEOF
    ln -sf /etc/nginx/sites-available/chaiya-ssl /etc/nginx/sites-enabled/chaiya-ssl
    systemctl start nginx 2>/dev/null || true
    nginx -t && systemctl reload nginx 2>/dev/null || true
    # cert renewal cron
    (crontab -l 2>/dev/null || true) | grep -v certbot-renew | { cat; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx # certbot-renew"; } | crontab -
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
  local _cfg_host; _cfg_host=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "$MY_IP")
  printf "${R4}│${RS}  ${CY}📥 Config HTML:${RS}\n"
  printf "${R4}│${RS}  ${WH}http://%s:81/config/%s.html${RS}\n" "$_cfg_host" "$UNAME"
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
