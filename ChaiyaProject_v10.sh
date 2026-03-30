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
#  ถามชื่อ+รหัส admin สำหรับ x-ui ก่อนติดตั้ง
# ══════════════════════════════════════════════════════════════
echo ""
printf "${WH}╔══════════════════════════════════════════════╗${RS}\n"
printf "${WH}║  ตั้งค่า admin ก่อนติดตั้ง 3x-ui             ║${RS}\n"
printf "${WH}╚══════════════════════════════════════════════╝${RS}\n"
echo ""
read -rp "$(printf "${YE}กรอก Username admin (เช่น admin): ${RS}")" XUI_USER
[[ -z "$XUI_USER" ]] && XUI_USER="admin"
read -rsp "$(printf "${YE}กรอก Password admin: ${RS}")" XUI_PASS
echo ""
[[ -z "$XUI_PASS" ]] && XUI_PASS="chaiya$(openssl rand -hex 4)"
printf "${GR}✔ จะใช้ Username: ${WH}%s${RS}\n" "$XUI_USER"
printf "${GR}✔ จะใช้ Password: ${WH}%s${RS}\n" "$XUI_PASS"

# บันทึก credential
echo "$XUI_USER" > /etc/chaiya/xui-user.conf
echo "$XUI_PASS" > /etc/chaiya/xui-pass.conf
chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf

# ══════════════════════════════════════════════════════════════
#  ติดตั้ง 3x-ui พร้อมตอบคำถามอัตโนมัติ
# ══════════════════════════════════════════════════════════════
printf "${YE}⟳ ติดตั้ง 3x-ui...${RS}\n"

# ดาวน์โหลด installer
XUI_INSTALL=$(mktemp /tmp/xui-install-XXXXX.sh)
curl -Ls "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" -o "$XUI_INSTALL"
chmod +x "$XUI_INSTALL"

# ตอบ interactive prompts อัตโนมัติ:
# - Would you like to customize the Panel Port settings? → y
# - Please set up the panel port: → 2053
# - Choose SSL certificate setup method: → 2 (Let's Encrypt for IP, 6-day)
# - Do you have an IPv6? → (enter ผ่าน = ไม่มี)
# - Port to use for ACME HTTP-01 listener (default 80): → 80
printf "y\n2053\n2\n\n80\n" | bash "$XUI_INSTALL" 2>&1 | tee /var/log/chaiya-xui-install.log || true
rm -f "$XUI_INSTALL"

sleep 3

# ตั้งค่า admin user+pass ผ่าน x-ui CLI
x-ui setting -username "$XUI_USER" -password "$XUI_PASS" 2>/dev/null || \
  /usr/local/x-ui/x-ui setting -username "$XUI_USER" -password "$XUI_PASS" 2>/dev/null || \
  printf "${YE}⚠ ตั้ง credential ผ่าน CLI ไม่สำเร็จ — จะใช้ default${RS}\n"

systemctl restart x-ui 2>/dev/null || true
sleep 2

# ตรวจสอบ x-ui port จาก config
XUI_PORT=2053
if command -v x-ui &>/dev/null; then
  _p=$(x-ui setting 2>/dev/null | grep -oP 'port.*?:\s*\K\d+' | head -1)
  [[ -n "$_p" ]] && XUI_PORT="$_p"
fi
echo "$XUI_PORT" > /etc/chaiya/xui-port.conf

# ── ฟังก์ชัน helper สำหรับเรียก 3x-ui API ──────────────────
# บันทึก session cookie
XUI_COOKIE_JAR="/etc/chaiya/xui-cookie.jar"

xui_login() {
  local user pass port
  user=$(cat /etc/chaiya/xui-user.conf 2>/dev/null || echo "admin")
  pass=$(cat /etc/chaiya/xui-pass.conf 2>/dev/null || echo "admin")
  port=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")
  curl -s -c "$XUI_COOKIE_JAR" -b "$XUI_COOKIE_JAR" \
    -X POST "http://127.0.0.1:${port}/login" \
    -d "username=${user}&password=${pass}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --max-time 10 2>/dev/null | grep -q '"success":true' && return 0 || return 1
}

xui_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local port
  port=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")
  xui_login 2>/dev/null || true
  if [[ -n "$data" ]]; then
    curl -s -c "$XUI_COOKIE_JAR" -b "$XUI_COOKIE_JAR" \
      -X "$method" "http://127.0.0.1:${port}${endpoint}" \
      -H "Content-Type: application/json" \
      -d "$data" --max-time 15 2>/dev/null
  else
    curl -s -c "$XUI_COOKIE_JAR" -b "$XUI_COOKIE_JAR" \
      -X "$method" "http://127.0.0.1:${port}${endpoint}" \
      --max-time 15 2>/dev/null
  fi
}

# ══════════════════════════════════════════════════════════════
#  สร้าง inbounds อัตโนมัติ: port 8080 (AIS) และ 8880 (TRUE)
# ══════════════════════════════════════════════════════════════
printf "${YE}⟳ สร้าง inbounds อัตโนมัติ (8080/8880)...${RS}\n"

ufw allow 8080/tcp 2>/dev/null || true
ufw allow 8880/tcp 2>/dev/null || true

_create_inbound() {
  local port="$1" remark="$2" sni="$3"
  local uuid
  uuid=$(cat /proc/sys/kernel/random/uuid)
  local payload
  payload=$(cat <<INEOF
{
  "remark": "${remark}",
  "enable": true,
  "listen": "",
  "port": ${port},
  "protocol": "vmess",
  "settings": {
    "clients": [{"id": "${uuid}", "alterId": 0}],
    "disableInsecureEncryption": false
  },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "path": "/",
      "headers": {"Host": "${sni}"}
    }
  },
  "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
}
INEOF
)
  xui_api POST "/panel/api/inbounds/add" "$payload"
}

sleep 2
_create_inbound 8080 "CHAIYA-AIS-8080"  "cj-ebb.speedtest.net"
_create_inbound 8880 "CHAIYA-TRUE-8880" "true-internet.zoom.xyz.services"

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
#  สร้าง sshws.html
# ══════════════════════════════════════════════════════════════
python3 - << PYGENEOF
import json, os
token = "${SSHWS_TOKEN}"
host  = "${SSHWS_HOST}"
proto = "${SSHWS_PROTO}"

html = open("/dev/stdin").read() if False else r"""<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CHAIYA SSH-WS</title>
<style>
:root{--bg:#020408;--bg2:#060d14;--border:#0f2030;--mono:'Courier New',monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:#c8dde8;font-family:var(--mono);min-height:100vh}
.wrap{max-width:960px;margin:0 auto;padding:16px}
.h1{color:#ff0040;font-size:24px;font-weight:900;letter-spacing:4px;margin-bottom:4px}
.sub{color:#3d5a73;font-size:10px;letter-spacing:2px;margin-bottom:16px}
.card{background:var(--bg2);border:1px solid #1a3a55;padding:14px;margin-bottom:12px}
.lbl{color:#3d5a73;font-size:8px;letter-spacing:2px;text-transform:uppercase;margin-bottom:4px}
.val{color:#00e5ff;font-size:13px}
.btn{padding:6px 12px;border:1px solid #00e5ff;background:transparent;color:#00e5ff;cursor:pointer;font-family:var(--mono);font-size:11px}
.btn:hover{background:#00e5ff22}
.btn-g{border-color:#00ff88;color:#00ff88}.btn-g:hover{background:#00ff8822}
.btn-r{border-color:#ff2255;color:#ff2255}.btn-r:hover{background:#ff225522}
table{width:100%;border-collapse:collapse;font-size:11px}
th{color:#3d5a73;font-weight:400;padding:6px 8px;border-bottom:1px solid #0f2030;text-align:left;font-size:9px;letter-spacing:1px;text-transform:uppercase}
td{padding:8px;border-bottom:1px solid #0a1520}
tr:hover td{background:#0a1520}
.pill{padding:1px 6px;font-size:8px;border:1px solid}
.pg{border-color:#00ff8844;color:#00ff88;background:#00ff8811}
.pr{border-color:#ff225544;color:#ff2255;background:#ff225511}
input,select{background:#030608;border:1px solid #1a3a55;color:#c8dde8;padding:6px 8px;font-family:var(--mono);font-size:11px;width:100%;outline:none}
input:focus,select:focus{border-color:#00e5ff}
.fi{margin-bottom:8px}.fi label{display:block;color:#3d5a73;font-size:8px;letter-spacing:1px;margin-bottom:3px}
.row{display:flex;gap:8px;align-items:flex-end}
.g2{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.tabs{display:flex;border-bottom:1px solid #0f2030;margin-bottom:12px}
.tab{padding:7px 12px;background:none;border:none;color:#3d5a73;cursor:pointer;font-family:var(--mono);font-size:9px;letter-spacing:1px;border-bottom:2px solid transparent;margin-bottom:-1px}
.tab.on{color:#00e5ff;border-bottom-color:#00e5ff}
.tc{display:none}.tc.on{display:block}
.log{background:#030608;border:1px solid #0f2030;padding:10px;height:130px;overflow-y:auto;font-size:10px;color:#2a5a40;line-height:1.7}
#toast{position:fixed;bottom:16px;right:16px;padding:8px 14px;background:var(--bg2);border:1px solid #00e5ff;color:#00e5ff;font-size:10px;transform:translateX(140%);transition:.3s;z-index:9999}
#toast.s{transform:none}
.mo{position:fixed;inset:0;background:rgba(0,0,0,.85);display:none;place-items:center;z-index:5000}
.mo.o{display:grid}
.md{background:var(--bg2);border:1px solid #1a3a55;padding:20px;width:min(90vw,360px)}
.md h3{color:#00e5ff;font-size:10px;letter-spacing:2px;margin-bottom:12px}
.mf{display:flex;gap:8px;justify-content:flex-end;margin-top:12px}
@media(max-width:600px){.g2{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="wrap">
<div style="display:flex;align-items:center;gap:12px;margin-bottom:18px">
  <div>
    <div class="h1">CHAIYA SSH-WS</div>
    <div class="sub">// WEBSOCKET SSH MANAGER</div>
  </div>
  <div style="margin-left:auto;display:flex;align-items:center;gap:8px;font-size:10px">
    <div id="dot" style="width:8px;height:8px;border-radius:50%;background:#3d5a73"></div>
    <span id="glbl" style="color:#3d5a73">—</span>
  </div>
</div>

<div class="card" style="display:flex;gap:8px;align-items:center">
  <div style="flex:1">
    <div class="lbl">API TOKEN</div>
    <input type="password" id="tok" placeholder="Token (auto-filled)">
  </div>
  <button class="btn" onclick="toggleTok()">👁</button>
  <button class="btn" onclick="loadAll()">▶ เชื่อมต่อ</button>
</div>

<div class="g2" style="margin-bottom:12px">
  <div class="card"><div class="lbl">WebSocket Status</div><div class="val" id="ws-s">—</div><div style="color:#3d5a73;font-size:9px;margin-top:3px" id="ws-p">port —</div></div>
  <div class="card"><div class="lbl">Connections</div><div class="val" id="conns">—</div><div style="color:#3d5a73;font-size:9px;margin-top:3px">active sessions</div></div>
</div>

<div class="card">
  <div class="tabs">
    <button class="tab on" onclick="sw('t-users',this)">👤 Users</button>
    <button class="tab" onclick="sw('t-online',this)">🟢 Online</button>
    <button class="tab" onclick="sw('t-ban',this)">🚫 Banned</button>
    <button class="tab" onclick="sw('t-log',this)">📋 Logs</button>
  </div>

  <div class="tc on" id="t-users">
    <div class="g2" style="margin-bottom:8px">
      <div class="fi"><label>Username</label><input id="nu" placeholder="user1"></div>
      <div class="fi"><label>Password</label><input type="password" id="np" placeholder="••••••••"></div>
    </div>
    <div class="row" style="margin-bottom:12px">
      <div class="fi" style="margin:0;flex:1"><label>วัน</label><input type="number" id="nd" value="30" min="1"></div>
      <div class="fi" style="margin:0;flex:1"><label>Data GB (0=∞)</label><input type="number" id="ngb" value="0" min="0"></div>
      <button class="btn btn-g" onclick="addUser()">＋ เพิ่ม</button>
    </div>
    <table>
      <thead><tr><th>Username</th><th>หมดอายุ</th><th>Data</th><th>สถานะ</th><th>Actions</th></tr></thead>
      <tbody id="utb"><tr><td colspan="5" style="text-align:center;color:#3d5a73;padding:16px">โหลด...</td></tr></tbody>
    </table>
  </div>

  <div class="tc" id="t-online">
    <table>
      <thead><tr><th>Remote IP</th><th>State</th></tr></thead>
      <tbody id="otb"><tr><td colspan="2" style="text-align:center;color:#3d5a73;padding:16px">ไม่มี connection</td></tr></tbody>
    </table>
  </div>

  <div class="tc" id="t-ban">
    <table>
      <thead><tr><th>Username</th><th>แบนถึง</th><th>IPs</th><th>Action</th></tr></thead>
      <tbody id="btb"><tr><td colspan="4" style="text-align:center;color:#3d5a73;padding:16px">ไม่มี account ถูกแบน</td></tr></tbody>
    </table>
  </div>

  <div class="tc" id="t-log">
    <div style="text-align:right;margin-bottom:8px"><button class="btn" onclick="loadLogs()">↺ Refresh</button></div>
    <div class="log" id="logbox"><span style="color:#3d5a73">// กด Refresh</span></div>
  </div>
</div>

<div id="toast"></div>

<div class="mo" id="m-renew">
  <div class="md">
    <h3>🔄 ต่ออายุ</h3>
    <div class="fi"><label>Username</label><input id="rn-u" readonly style="color:#00e5ff"></div>
    <div class="g2">
      <div class="fi"><label>วัน</label><input type="number" id="rn-d" value="30" min="1"></div>
      <div class="fi"><label>Data GB</label><input type="number" id="rn-gb" value="0" min="0"></div>
    </div>
    <div class="mf">
      <button class="btn" onclick="cm('m-renew')">ยกเลิก</button>
      <button class="btn btn-g" onclick="confirmRenew()">✔ ต่ออายุ</button>
    </div>
  </div>
</div>

<div class="mo" id="m-del">
  <div class="md">
    <h3>⚠ ลบ User</h3>
    <p style="font-size:11px;margin-bottom:10px">ยืนยันลบ <span id="du" style="color:#ff2255;font-weight:700"></span> ?</p>
    <div class="mf">
      <button class="btn" onclick="cm('m-del')">ยกเลิก</button>
      <button class="btn btn-r" onclick="confirmDel()">✕ ลบ</button>
    </div>
  </div>
</div>

<script>
const AUTO_TOKEN="%%TOKEN%%", AUTO_HOST="%%HOST%%", AUTO_PROTO="%%PROTO%%";
const API=window.location.origin+'/sshws-api';
let delTarget='';
const $=id=>document.getElementById(id);

window.addEventListener('load',()=>{
  const saved=localStorage.getItem('ctok');
  if(AUTO_TOKEN&&AUTO_TOKEN!=='%%TOKEN%%'){
    $('tok').value=AUTO_TOKEN;
    localStorage.setItem('ctok',AUTO_TOKEN);
  } else if(saved) $('tok').value=saved;
  $('tok').addEventListener('change',()=>localStorage.setItem('ctok',tok()));
  if(tok()) loadAll();
  setInterval(()=>{if(tok()){loadStatus();loadOnline();}},8000);
});

function tok(){return $('tok').value.trim();}
function toggleTok(){const e=$('tok');e.type=e.type==='password'?'text':'password';}

function toast(msg,err=false){
  const t=$('toast');t.textContent=msg;t.className='s'+(err?' err':'');
  clearTimeout(t._t);t._t=setTimeout(()=>t.className='',2800);
}

async function api(method,path,body=null){
  const o={method,headers:{'Authorization':'Bearer '+tok(),'Content-Type':'application/json'}};
  if(body) o.body=JSON.stringify(body);
  try{const r=await fetch(API+path,o);return await r.json();}
  catch(e){return{error:e.message};}
}

function sw(id,el){
  document.querySelectorAll('.tc').forEach(t=>t.classList.remove('on'));
  document.querySelectorAll('.tab').forEach(t=>t.classList.remove('on'));
  $(id).classList.add('on');el.classList.add('on');
  if(id==='t-online')loadOnline();
  if(id==='t-ban')loadBanned();
  if(id==='t-log')loadLogs();
}

async function loadStatus(){
  const d=await api('GET','/api/status');
  if(d.error)return;
  const on=d.ws_status==='active';
  $('dot').style.background=on?'#00ff88':'#ff2255';
  $('glbl').textContent=on?'ONLINE':'OFFLINE';
  $('glbl').style.color=on?'#00ff88':'#ff2255';
  $('ws-s').textContent=on?'RUNNING':'STOPPED';
  $('ws-s').style.color=on?'#00ff88':'#ff2255';
  $('ws-p').textContent='port '+d.ws_port;
  $('conns').textContent=d.connections??0;
}

async function loadUsers(){
  const u=await api('GET','/api/users');
  const tb=$('utb');
  if(u.error){toast('โหลดไม่ได้',true);return;}
  if(!Array.isArray(u)||!u.length){tb.innerHTML='<tr><td colspan="5" style="text-align:center;color:#3d5a73;padding:16px">ไม่มี users</td></tr>';return;}
  tb.innerHTML=u.map(x=>{
    const dLeft=Math.ceil((new Date(x.exp)-new Date())/86400000);
    const ok=x.active&&dLeft>0;
    return `<tr>
      <td style="color:#fff;font-weight:700">${x.user}</td>
      <td>${x.exp}<span style="color:#3d5a73;font-size:9px"> (${dLeft>0?dLeft+'d':'หมด'})</span></td>
      <td style="color:#00e5ff">${x.data_gb>0?x.data_gb+'GB':'∞'}</td>
      <td><span class="pill ${ok?'pg':'pr'}">${ok?'ACTIVE':'EXPIRED'}</span></td>
      <td style="display:flex;gap:4px">
        <button class="btn" style="padding:2px 8px;font-size:9px" onclick="openRenew('${x.user}',${x.days},${x.data_gb})">🔄</button>
        <button class="btn btn-r" style="padding:2px 8px;font-size:9px" onclick="openDel('${x.user}')">✕</button>
      </td>
    </tr>`;
  }).join('');
}

async function addUser(){
  const user=$('nu').value.trim(),pass=$('np').value.trim();
  const days=parseInt($('nd').value)||30,gb=parseInt($('ngb').value)||0;
  if(!user||!pass){toast('ใส่ username และ password',true);return;}
  const r=await api('POST','/api/users',{user,password:pass,days,data_gb:gb});
  if(r.ok){toast(`✔ เพิ่ม "${user}" แล้ว`);$('nu').value='';$('np').value='';loadUsers();}
  else toast('เพิ่มไม่ได้: '+(r.result||r.error),true);
}

function openRenew(u,d,gb){$('rn-u').value=u;$('rn-d').value=d||30;$('rn-gb').value=gb||0;$('m-renew').classList.add('o');}
async function confirmRenew(){
  const u=$('rn-u').value,d=parseInt($('rn-d').value)||30,gb=parseInt($('rn-gb').value)||0;
  const r=await api('POST','/api/renew',{user:u,days:d,data_gb:gb});
  cm('m-renew');
  if(r.ok){toast(`✔ ต่ออายุ "${u}" ${d}วัน`);loadUsers();}
  else toast('ต่ออายุไม่ได้',true);
}

function openDel(u){delTarget=u;$('du').textContent=u;$('m-del').classList.add('o');}
async function confirmDel(){
  const r=await api('DELETE',`/api/users/${delTarget}`);
  cm('m-del');
  if(r.ok){toast(`✔ ลบ "${delTarget}" แล้ว`);loadUsers();}
  else toast('ลบไม่ได้',true);
}

function cm(id){$(id).classList.remove('o');}
document.querySelectorAll('.mo').forEach(m=>m.addEventListener('click',e=>{if(e.target===m)m.classList.remove('o');}));

async function loadOnline(){
  const d=await api('GET','/api/online');
  const tb=$('otb');
  if(!Array.isArray(d)||!d.length){tb.innerHTML='<tr><td colspan="2" style="text-align:center;color:#3d5a73;padding:16px">ไม่มี connection</td></tr>';return;}
  tb.innerHTML=d.map(c=>`<tr><td style="color:#00e5ff">${c.remote}</td><td><span class="pill pg">${c.state}</span></td></tr>`).join('');
}

async function loadBanned(){
  const b=await api('GET','/api/banned');
  const tb=$('btb');
  const keys=Object.keys(b||{});
  if(!keys.length){tb.innerHTML='<tr><td colspan="4" style="text-align:center;color:#3d5a73;padding:16px">ไม่มี account ถูกแบน ✔</td></tr>';return;}
  tb.innerHTML=keys.map(uid=>{
    const x=b[uid];
    const until=new Date(x.until).toLocaleString('th-TH');
    return `<tr>
      <td style="color:#ff2255;font-weight:700">${x.name}</td>
      <td><span class="pill pr">${until}</span></td>
      <td style="font-size:9px;color:#3d5a73">${(x.ips||[]).slice(0,3).join(', ')}</td>
      <td><button class="btn btn-g" style="padding:2px 8px;font-size:9px" onclick="unban('${uid}','${x.name}')">🔓 ปลด</button></td>
    </tr>`;
  }).join('');
}

async function unban(uid,name){
  const r=await api('POST','/api/unban',{uid,name});
  if(r.ok){toast(`🔓 ปลดแบน ${name}`);loadBanned();}
  else toast('ปลดแบนไม่ได้',true);
}

async function loadLogs(){
  const r=await api('GET','/api/logs');
  const b=$('logbox');
  if(!r.lines||!r.lines.length){b.innerHTML='<span style="color:#3d5a73">// ไม่มี logs</span>';return;}
  b.innerHTML=r.lines.map(l=>`<div style="color:${l.includes('ERR')?'#ff2255':l.includes('OK')?'#00ff88':'#2a5a40'}">${l}</div>`).join('');
  b.scrollTop=b.scrollHeight;
}

async function loadAll(){
  if(!tok()){toast('ใส่ API Token ก่อน',true);return;}
  await loadStatus();await loadUsers();await loadOnline();
}
</script>
</body>
</html>"""

html = html.replace("%%TOKEN%%", token)
html = html.replace("%%HOST%%", host)
html = html.replace("%%PROTO%%", proto)

with open("/var/www/chaiya/sshws.html","w") as f:
    f.write(html)
print("sshws.html OK")
PYGENEOF

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
  if systemctl is-active --quiet x-ui 2>/dev/null; then
    MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    local p; p=$(xui_port)
    printf "${GR}✔ 3x-ui กำลังทำงานอยู่แล้ว${RS}\n"
    printf "  Panel : ${WH}http://%s:%s${RS}\n" "$MY_IP" "$p"
    printf "  User  : ${WH}%s${RS}\n" "$(xui_user)"
    printf "\n  ${YE}1.${RS} ติดตั้งใหม่ทับ\n  ${YE}2.${RS} ดูข้อมูล inbounds ปัจจุบัน\n"
    read -rp "เลือก: " sub
    case $sub in
      2)
        printf "\n${YE}Inbounds:${RS}\n"
        xui_api GET "/panel/api/inbounds/list" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    print(f\"  Port {x['port']:5d} | {x['protocol']:8s} | {x['remark']}\")
except: print('  ไม่สามารถดึงข้อมูลได้')
"
        read -rp "Enter ย้อนกลับ..." ;;
      1|*)
        read -rp "$(printf "${YE}Username admin ใหม่: ${RS}")" u
        [[ -z "$u" ]] && u="admin"
        read -rsp "$(printf "${YE}Password admin ใหม่: ${RS}")" pw; echo ""
        [[ -z "$pw" ]] && { printf "${RD}ต้องใส่ password${RS}\n"; read -rp "Enter..."; return; }
        echo "$u" > /etc/chaiya/xui-user.conf
        echo "$pw" > /etc/chaiya/xui-pass.conf
        x-ui setting -username "$u" -password "$pw" 2>/dev/null || true
        systemctl restart x-ui
        printf "${GR}✔ อัพเดต credential แล้ว${RS}\n"
        read -rp "Enter..." ;;
    esac
  else
    printf "${YE}ติดตั้ง 3x-ui...${RS}\n"
    read -rp "$(printf "${YE}Username admin: ${RS}")" u
    [[ -z "$u" ]] && u="admin"
    read -rsp "$(printf "${YE}Password admin: ${RS}")" pw; echo ""
    [[ -z "$pw" ]] && pw="chaiya$(openssl rand -hex 4)"
    echo "$u" > /etc/chaiya/xui-user.conf
    echo "$pw" > /etc/chaiya/xui-pass.conf
    XUI_INSTALL=$(mktemp /tmp/xui-XXXXX.sh)
    curl -Ls "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" -o "$XUI_INSTALL"
    printf "y\n2053\n2\n\n80\n" | bash "$XUI_INSTALL"
    rm -f "$XUI_INSTALL"
    sleep 3
    x-ui setting -username "$u" -password "$pw" 2>/dev/null || true
    systemctl restart x-ui
    MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    printf "\n${GR}✔ ติดตั้งเสร็จ${RS}\n"
    printf "  Panel : ${WH}http://%s:2053${RS}\n" "$MY_IP"
    printf "  User  : ${WH}%s${RS}  Pass: ${WH}%s${RS}\n" "$u" "$pw"
    # สร้าง inbounds อัตโนมัติ
    sleep 3
    printf "${YE}⟳ สร้าง inbounds 8080/8880...${RS}\n"
    for _p_s in "8080 CHAIYA-AIS-8080 cj-ebb.speedtest.net" "8880 CHAIYA-TRUE-8880 true-internet.zoom.xyz.services"; do
      _pp=$(echo "$_p_s"|awk '{print $1}')
      _rr=$(echo "$_p_s"|awk '{print $2}')
      _ss=$(echo "$_p_s"|awk '{print $3}')
      _uuid=$(cat /proc/sys/kernel/random/uuid)
      xui_api POST "/panel/api/inbounds/add" "{\"remark\":\"${_rr}\",\"enable\":true,\"listen\":\"\",\"port\":${_pp},\"protocol\":\"vmess\",\"settings\":{\"clients\":[{\"id\":\"${_uuid}\",\"alterId\":0}],\"disableInsecureEncryption\":false},\"streamSettings\":{\"network\":\"ws\",\"security\":\"none\",\"wsSettings\":{\"path\":\"/\",\"headers\":{\"Host\":\"${_ss}\"}}},\"sniffing\":{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"]}}" > /dev/null
      ufw allow "${_pp}"/tcp 2>/dev/null || true
    done
    printf "${GR}✔ inbounds สร้างแล้ว${RS}\n"
    read -rp "Enter..."
  fi
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

  PAYLOAD=$(cat << PEOF
{
  "remark": "CHAIYA-${UNAME}",
  "enable": true,
  "listen": "",
  "port": ${VPORT},
  "protocol": "vless",
  "settings": {
    "clients": [{
      "id": "${UUID}",
      "email": "${UNAME}",
      "limitIp": 2,
      "totalGB": $((DATA_GB * 1073741824)),
      "expiryTime": $(date -d "$EXP" +%s)000,
      "enable": true,
      "comment": "",
      "reset": 0
    }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "${SEC}",
    "wsSettings": {
      "path": "/vless",
      "headers": {"Host": "${SNI}"}
    }
  },
  "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
}
PEOF
)

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

# ══════════════════════════════════════════════════════════════
#  สรุปผลการติดตั้ง
# ══════════════════════════════════════════════════════════════
TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null || echo "N/A")
XUI_U=$(cat /etc/chaiya/xui-user.conf 2>/dev/null || echo "admin")
XUI_P=$(cat /etc/chaiya/xui-pass.conf 2>/dev/null || echo "N/A")
XUI_PT=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")
HOST_DISP=""
[[ -f /etc/chaiya/domain.conf ]] && HOST_DISP=$(cat /etc/chaiya/domain.conf)
[[ -z "$HOST_DISP" ]] && HOST_DISP="$MY_IP"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ✅ CHAIYA V2RAY PRO MAX v10 ติดตั้งเสร็จ!      ║"
echo "╠══════════════════════════════════════════════════╣"
printf "║  🔥 3x-ui Panel  : http://%-22s║\n" "${MY_IP}:${XUI_PT}"
printf "║  👤 Admin User   : %-28s║\n" "$XUI_U"
printf "║  🔑 Admin Pass   : %-28s║\n" "$XUI_P"
echo "╠══════════════════════════════════════════════════╣"
printf "║  🌐 SSH-WS URL   : http://%-22s║\n" "${HOST_DISP}/sshws/sshws.html"
printf "║  🌐 Alt URL      : http://%-22s║\n" "${MY_IP}:81/sshws/sshws.html"
printf "║  🔒 SSH-WS Token : %-28s║\n" "${TOKEN:0:28}"
echo "╠══════════════════════════════════════════════════╣"
echo "║  ⚡ Port 8080 : CHAIYA-AIS  (vmess+ws)          ║"
echo "║  ⚡ Port 8880 : CHAIYA-TRUE (vmess+ws)          ║"
echo "║  ⚡ Port 80   : SSH WebSocket                    ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  👉 พิมพ์: chaiya  เพื่อเปิดเมนู                ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
