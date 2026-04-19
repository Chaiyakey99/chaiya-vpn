#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL - All-in-One Install Script v4
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-setup.sh
#   v4: รองรับโดเมน + HTTPS (ไม่โชว์พอร์ต) + รหัสผ่านไม่จำกัด
#       + คำสั่ง menu + HTML ใหม่ (login + dashboard)
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
  ██████╗██╗  ██╗ █████╗ ██╗██╗   ██╗ █████╗
 ██╔════╝██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══██╗
 ██║     ███████║███████║██║ ╚████╔╝ ███████║
 ██║     ██╔══██║██╔══██║██║  ╚██╔╝  ██╔══██║
 ╚██████╗██║  ██║██║  ██║██║   ██║   ██║  ██║
  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝
      VPN PANEL - ALL-IN-ONE INSTALLER v4
BANNER
echo -e "${NC}"

# ── ROOT CHECK ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "รันด้วย root หรือ sudo เท่านั้น"

# ── INSTALL DEPS ─────────────────────────────────────────────
info "อัปเดต packages..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl wget python3 python3-pip nginx certbot python3-certbot-nginx \
  dropbear openssh-server ufw build-essential cmake net-tools jq bc cron unzip sqlite3 \
  iptables-persistent 2>/dev/null || true
ok "ติดตั้ง packages สำเร็จ"

# ── GET SERVER IP ────────────────────────────────────────────
info "กำลังดึง IP ของเครื่อง..."
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
            hostname -I | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && err "ไม่สามารถดึง IP ได้"
ok "IP: ${CYAN}$SERVER_IP${NC}"

# ── DOMAIN SETUP ─────────────────────────────────────────────
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
echo -e "${YELLOW}   ตั้งค่าโดเมน (ใช้ https://yourdomain.com)${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
echo -e "  ต้อง DNS ชี้ A record มาที่ IP: ${CYAN}$SERVER_IP${NC} ก่อน"
echo ""
read -rp "  โดเมนของคุณ (เช่น panel.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && err "กรุณาใส่โดเมน"
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|https\?://||' | sed 's|/.*||')
ok "โดเมน: ${CYAN}$DOMAIN${NC}"

# ── PASSWORD ─────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}กำหนด Password สำหรับ Panel Login (ไม่จำกัดความยาว)${NC}"
while true; do
  read -rsp "  Panel Password: " PANEL_PASS; echo
  [[ -z "$PANEL_PASS" ]] && { warn "Password ห้ามว่าง"; continue; }
  read -rsp "  Confirm Password: " PANEL_PASS2; echo
  [[ "$PANEL_PASS" == "$PANEL_PASS2" ]] && break
  warn "Password ไม่ตรงกัน ลองอีกครั้ง"
done
ok "Panel Password ตั้งค่าแล้ว"

# ── XUI CREDENTIALS ──────────────────────────────────────────
echo ""
echo -e "${YELLOW}กำหนด Username / Password สำหรับ 3x-ui (ไม่จำกัดความยาว)${NC}"
read -rp "  3x-ui Username [admin]: " XUI_USER
[[ -z "$XUI_USER" ]] && XUI_USER="admin"
while true; do
  read -rsp "  3x-ui Password: " XUI_PASS; echo
  [[ -z "$XUI_PASS" ]] && { warn "Password ห้ามว่าง"; continue; }
  read -rsp "  Confirm 3x-ui Password: " XUI_PASS2; echo
  [[ "$XUI_PASS" == "$XUI_PASS2" ]] && break
  warn "Password ไม่ตรงกัน ลองอีกครั้ง"
done
ok "3x-ui Password ตั้งค่าแล้ว"

# ── PORT CONFIG ────────────────────────────────────────────
SSH_API_PORT=2095
XUI_PORT=2053
PANEL_PORT=8888
DROPBEAR_PORT1=143
DROPBEAR_PORT2=109
BADVPN_PORT=7300
OPENVPN_PORT=1194

echo ""
info "การตั้งค่า:"
echo -e "  IP Server     : ${CYAN}$SERVER_IP${NC}"
echo -e "  โดเมน         : ${CYAN}$DOMAIN${NC}"
echo -e "  Panel URL     : ${CYAN}https://$DOMAIN${NC}"
echo -e "  SSH API Port  : ${CYAN}$SSH_API_PORT${NC} (ภายใน)"
echo -e "  3x-ui Port    : ${CYAN}$XUI_PORT${NC}"
echo -e "  Dropbear      : ${CYAN}$DROPBEAR_PORT1, $DROPBEAR_PORT2${NC}"
echo ""
read -rp "เริ่มติดตั้ง? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 0

# ── HASH PANEL PASSWORD ───────────────────────────────────────
PANEL_PASS_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${PANEL_PASS}'.encode()).hexdigest())")
mkdir -p /etc/chaiya
echo "$PANEL_PASS_HASH" > /etc/chaiya/panel-pass.hash
chmod 600 /etc/chaiya/panel-pass.hash

# ── OPENSSH ──────────────────────────────────────────────────
info "ตั้งค่า OpenSSH..."
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
ok "OpenSSH พร้อม"

# ── DROPBEAR ─────────────────────────────────────────────────
info "ตั้งค่า Dropbear..."
systemctl stop dropbear 2>/dev/null || true
mkdir -p /etc/dropbear
[[ ! -f /etc/dropbear/dropbear_rsa_host_key ]] && \
  dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null || true
[[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]] && \
  dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key 2>/dev/null || true
[[ ! -f /etc/dropbear/dropbear_dss_host_key ]] && \
  dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key 2>/dev/null || true

mkdir -p /etc/systemd/system/dropbear.service.d
cat > /etc/systemd/system/dropbear.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -F -p $DROPBEAR_PORT1 -p $DROPBEAR_PORT2 -W 65536
EOF

grep -q '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
grep -q '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

systemctl daemon-reload 2>/dev/null || true
systemctl enable dropbear 2>/dev/null || true
systemctl restart dropbear 2>/dev/null || true
sleep 2
systemctl is-active --quiet dropbear && ok "Dropbear พร้อม (port $DROPBEAR_PORT1, $DROPBEAR_PORT2)" || \
  warn "Dropbear อาจไม่ทำงาน — ตรวจสอบด้วย: systemctl status dropbear"

# ── BADVPN ───────────────────────────────────────────────────
info "ติดตั้ง BadVPN..."
if ! command -v badvpn-udpgw &>/dev/null; then
  wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
    "https://raw.githubusercontent.com/NevermoreSSH/Blueblue/main/newudpgw" 2>/dev/null && \
    chmod +x /usr/bin/badvpn-udpgw || rm -f /usr/bin/badvpn-udpgw
  if [[ ! -f /usr/bin/badvpn-udpgw ]]; then
    apt-get install -y -qq cmake build-essential 2>/dev/null || true
    cd /tmp && wget -q https://github.com/ambrop72/badvpn/archive/refs/heads/master.zip -O badvpn.zip 2>/dev/null && \
      unzip -q badvpn.zip && cd badvpn-master && \
      cmake . -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_INSTALL_PREFIX=/usr/local &>/dev/null && \
      make -j$(nproc) &>/dev/null && make install &>/dev/null && \
      ln -sf /usr/local/bin/badvpn-udpgw /usr/bin/badvpn-udpgw
    cd / && rm -rf /tmp/badvpn*
  fi
fi

cat > /etc/systemd/system/chaiya-badvpn.service << EOF
[Unit]
Description=Chaiya BadVPN UDP Gateway
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:$BADVPN_PORT --max-clients 500
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable chaiya-badvpn 2>/dev/null || true
pkill -f badvpn 2>/dev/null || true
sleep 1
systemctl start chaiya-badvpn 2>/dev/null || true
ok "BadVPN พร้อม (port $BADVPN_PORT)"

# ── 3X-UI INSTALL ────────────────────────────────────────────
info "ติดตั้ง 3x-ui..."
echo "$XUI_USER" > /etc/chaiya/xui-user.conf
echo "$XUI_PASS" > /etc/chaiya/xui-pass.conf
chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf

if ! command -v x-ui &>/dev/null; then
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << XUIEOF
n
XUIEOF
fi

systemctl stop x-ui 2>/dev/null || true
sleep 2

XUI_DB="/etc/x-ui/x-ui.db"

XUI_PASS_HASH=$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
" "$XUI_PASS" 2>/dev/null)
[[ -z "$XUI_PASS_HASH" ]] && XUI_PASS_HASH="$XUI_PASS"

if [[ -f "$XUI_DB" ]]; then
  sqlite3 "$XUI_DB" "UPDATE users SET username='${XUI_USER}', password='${XUI_PASS_HASH}' WHERE id=1;" 2>/dev/null || true
  for _key in webPort webUsername webPassword; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPort','${XUI_PORT}');"       2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webUsername','${XUI_USER}');"   2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPassword','${XUI_PASS_HASH}');" 2>/dev/null || true
  ok "x-ui credentials + port ตั้งค่าใน DB เรียบร้อย"
fi

systemctl start x-ui 2>/dev/null || true
sleep 5
info "รอ x-ui เริ่มต้น..."
REAL_XUI_PORT="$XUI_PORT"
XUI_READY=0
for _i in $(seq 1 10); do
  sleep 2
  _ssport=$(ss -tlnp 2>/dev/null | grep x-ui | grep -oP ':\K\d+' | head -1)
  [[ -n "$_ssport" ]] && REAL_XUI_PORT="$_ssport"
  _http=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${REAL_XUI_PORT}/" 2>/dev/null)
  if [[ "$_http" =~ ^[123] ]]; then
    XUI_READY=1; break
  fi
done
[[ -z "$REAL_XUI_PORT" ]] && REAL_XUI_PORT=$XUI_PORT
echo "$REAL_XUI_PORT" > /etc/chaiya/xui-port.conf

[[ $XUI_READY -eq 1 ]] && ok "3x-ui พร้อม (port $REAL_XUI_PORT)" || \
  warn "3x-ui อาจยังไม่พร้อม — ตรวจสอบด้วย: systemctl status x-ui"

# ── สร้าง Inbounds ใน x-ui ───────────────────────────────────
info "สร้าง Inbounds ใน x-ui (VMess-WS:8080, VLESS-WS:8880)..."
XUI_BASE="http://127.0.0.1:${REAL_XUI_PORT}"
XUI_COOKIE=$(mktemp)

LOGIN_OK="false"
[[ $XUI_READY -eq 0 ]] && sleep 5
for _attempt in 1 2 3; do
  LOGIN_RESP=$(curl -s --max-time 10 -c "$XUI_COOKIE" -X POST "${XUI_BASE}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${XUI_USER}" \
    --data-urlencode "password=${XUI_PASS}" 2>/dev/null)
  LOGIN_OK=$(echo "$LOGIN_RESP" | python3 -c \
"import sys,json
try:
  d=json.load(sys.stdin)
  print(str(d.get('success',False)).lower())
except:
  print('false')
" 2>/dev/null)
  [[ "$LOGIN_OK" == "true" ]] && break
  [[ $_attempt -lt 3 ]] && sleep 5
done

_get_existing_ports() {
  curl -s -b "$XUI_COOKIE" "${XUI_BASE}/xui/API/inbounds" 2>/dev/null | \
    python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  print(' '.join(str(x.get('port','')) for x in d.get('obj',[])))
except: print('')
" 2>/dev/null
}

_add_inbound() {
  curl -s -b "$XUI_COOKIE" -X POST "${XUI_BASE}/xui/API/inbounds/add" \
    -H "Content-Type: application/json" -d "$1" >/dev/null 2>&1
}

if [[ "$LOGIN_OK" == "true" ]]; then
  EXISTING_PORTS=$(_get_existing_ports)

  python3 << PYEOF
import sqlite3, uuid, json, os

DB = '/etc/x-ui/x-ui.db'
con = sqlite3.connect(DB)
existing = [r[0] for r in con.execute("SELECT port FROM inbounds").fetchall()]

inbounds = [
  (8080, 'AIS-กันรั่ว',  'cj-ebb.speedtest.net',          'inbound-8080'),
  (8880, 'TRUE-VDO',     'true-internet.zoom.xyz.services', 'inbound-8880'),
]

for port, remark, host, tag in inbounds:
  if port in existing:
    print(f"[OK] {remark} มีอยู่แล้ว (port {port})")
    continue
  uid = str(uuid.uuid4())
  settings = json.dumps({"clients":[{"id":uid,"flow":"","email":"chaiya-default","limitIp":2,"totalGB":0,"expiryTime":0,"enable":True,"tgId":"","subId":""}],"decryption":"none","fallbacks":[]})
  stream   = json.dumps({"network":"ws","security":"none","wsSettings":{"path":"/vless","headers":{"Host":host}}})
  sniffing = json.dumps({"enabled":True,"destOverride":["http","tls","quic","fakedns"]})
  con.execute("INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,?,1,0,'',?,'vless',?,?,?,?)",
    (remark, port, settings, stream, tag, sniffing))
  key = 'ais' if port==8080 else 'true'
  open(f'/etc/chaiya/{key}-uuid.conf','w').write(uid)
  print(f"[OK] VLESS {remark} inbound พร้อม (port {port})")

con.commit()
con.close()
PYEOF

  systemctl restart x-ui 2>/dev/null || true
  sleep 2
else
  warn "Login x-ui ไม่สำเร็จ — ข้าม inbound setup"
fi
rm -f "$XUI_COOKIE"

# ── SSH API (Python) ──────────────────────────────────────────
info "ติดตั้ง SSH API..."
mkdir -p /opt/chaiya-ssh-api /etc/chaiya/exp /etc/chaiya/sshws-users

cat > /opt/chaiya-ssh-api/app.py << 'PYEOF'
#!/usr/bin/env python3
"""Chaiya SSH API v5 — domain support, no port in links"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, socket, threading, socketserver, hmac, uuid, sqlite3, base64

XUI_DB = '/etc/x-ui/x-ui.db'

def run_cmd(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
    return r.returncode == 0, r.stdout.strip(), r.stderr.strip()

def get_host():
    domain_f = '/etc/chaiya/domain.conf'
    ip_f = '/etc/chaiya/my_ip.conf'
    if os.path.exists(domain_f):
        return open(domain_f).read().strip()
    if os.path.exists(ip_f):
        return open(ip_f).read().strip()
    return ''

def get_xui_clients():
    try:
        con = sqlite3.connect(XUI_DB)
        row = con.execute("SELECT settings FROM inbounds WHERE port=8080").fetchone()
        con.close()
        if not row: return []
        return json.loads(row[0]).get('clients', [])
    except: return []

def add_xui_client(email, user_uuid=None):
    if user_uuid is None:
        user_uuid = str(uuid.uuid4())
    try:
        con = sqlite3.connect(XUI_DB)
        row = con.execute("SELECT id, settings FROM inbounds WHERE port=8080").fetchone()
        if not row: con.close(); return None
        inbound_id, settings_str = row
        settings = json.loads(settings_str)
        clients = [c for c in settings.get('clients', []) if c.get('email') != email]
        clients.append({'id': user_uuid, 'alterId': 0, 'email': email,
                        'limitIpCount': 2, 'totalGB': 0, 'expiryTime': 0,
                        'enable': True, 'tgId': '', 'subId': ''})
        settings['clients'] = clients
        con.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(settings), inbound_id))
        con.commit(); con.close()
        return user_uuid
    except: return None

def remove_xui_client(email):
    for port in (8080, 8880):
        try:
            con = sqlite3.connect(XUI_DB)
            row = con.execute("SELECT id, settings FROM inbounds WHERE port=?", (port,)).fetchone()
            if not row: con.close(); continue
            inbound_id, settings_str = row
            settings = json.loads(settings_str)
            settings['clients'] = [c for c in settings.get('clients', []) if c.get('email') != email]
            con.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(settings), inbound_id))
            con.commit(); con.close()
        except: pass
    subprocess.run("systemctl restart x-ui", shell=True, capture_output=True, timeout=15)

def build_npv_link(host, user_uuid, remark):
    # ใช้ domain + HTTPS port 443 (ไม่โชว์พอร์ต)
    ssh_config = {
        "server": host, "port": 443,
        "username": remark, "protocol": "ssh",
        "transport": "ws", "ws_path": "/",
        "tls": True, "remarks": remark
    }
    b64 = base64.b64encode(json.dumps(ssh_config).encode()).decode()
    return f"npvt-ssh://{b64}"

def get_connections():
    counts = {"total": 0}
    for port in ["80", "443", "143", "109", "22", "2095"]:
        out = subprocess.run(
            f"ss -tn state established 2>/dev/null | grep -c ':{port}[^0-9]' || echo 0",
            shell=True, capture_output=True, text=True).stdout.strip()
        try: c = int(out.split()[0]) if out.strip() else 0
        except: c = 0
        counts[port] = c
        counts["total"] += c
    return counts

def list_users():
    users = []
    xui_clients = {c['email']: c['id'] for c in get_xui_clients()}
    db_map = {}
    db_path = '/etc/chaiya/sshws-users/users.db'
    if os.path.exists(db_path):
        for line in open(db_path):
            parts = line.strip().split()
            if len(parts) >= 3:
                db_map[parts[0]] = {
                    'days':     int(parts[1]) if len(parts) > 1 else 30,
                    'exp':      parts[2]      if len(parts) > 2 else '',
                    'data_gb':  int(parts[3]) if len(parts) > 3 else 0,
                    'ip_limit': int(parts[4]) if len(parts) > 4 else 2,
                }
    try:
        with open('/etc/passwd') as f:
            for line in f:
                p = line.strip().split(':')
                if len(p) < 7: continue
                uid = int(p[2])
                if uid < 1000 or uid > 60000: continue
                if p[6] not in ['/bin/false', '/usr/sbin/nologin', '/bin/bash', '/bin/sh']: continue
                uname = p[0]
                u = {'user': uname, 'active': True, 'exp': None, 'uuid': None, 'ip_limit': 2, 'data_gb': 0}
                exp_f = f'/etc/chaiya/exp/{uname}'
                if os.path.exists(exp_f):
                    u['exp'] = open(exp_f).read().strip()
                if not u['exp'] and uname in db_map:
                    u['exp'] = db_map[uname]['exp']
                if uname in db_map:
                    u['ip_limit'] = db_map[uname]['ip_limit']
                    u['data_gb']  = db_map[uname]['data_gb']
                if u['exp']:
                    try:
                        exp_date = datetime.date.fromisoformat(u['exp'])
                        u['active'] = exp_date >= datetime.date.today()
                    except: pass
                u['uuid'] = xui_clients.get(uname)
                users.append(u)
    except: pass
    return users

def respond(handler, code, data):
    body = json.dumps(data).encode()
    handler.send_response(code)
    handler.send_header('Content-Type', 'application/json')
    handler.send_header('Content-Length', len(body))
    handler.send_header('Access-Control-Allow-Origin', '*')
    handler.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
    handler.send_header('Access-Control-Allow-Headers', 'Content-Type,Authorization')
    handler.end_headers()
    handler.wfile.write(body)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type,Authorization')
        self.end_headers()

    def read_body(self):
        try:
            length = int(self.headers.get('Content-Length', 0))
            if length > 0:
                raw = self.rfile.read(length)
                return json.loads(raw)
            return {}
        except: return {}

    def do_GET(self):
        if self.path == '/api/status':
            xui_port_f = '/etc/chaiya/xui-port.conf'
            xui_port = open(xui_port_f).read().strip() if os.path.exists(xui_port_f) else '2053'
            _, svc_dropbear, _ = run_cmd("systemctl is-active dropbear")
            _, svc_nginx,    _ = run_cmd("systemctl is-active nginx")
            _, svc_xui,      _ = run_cmd("systemctl is-active x-ui")
            _, udp, _          = run_cmd("pgrep -x badvpn-udpgw")
            _, ws,  _          = run_cmd("pgrep -f ws-stunnel")
            conns = get_connections()
            users = list_users()
            respond(self, 200, {
                "ok": True,
                "connections": conns.get("total", 0),
                "conn_443": conns.get("443", 0),
                "conn_80":  conns.get("80", 0),
                "conn_143": conns.get("143", 0),
                "conn_109": conns.get("109", 0),
                "conn_22":  conns.get("22", 0),
                "online":   conns.get("total", 0),
                "online_count": conns.get("total", 0),
                "total_users": len(users),
                "services": {
                    "ssh":      True,
                    "dropbear": svc_dropbear.strip() == "active",
                    "nginx":    svc_nginx.strip()    == "active",
                    "badvpn":   bool(udp.strip()),
                    "sshws":    bool(ws.strip()),
                    "xui":      svc_xui.strip()      == "active",
                    "tunnel":   bool(ws.strip()),
                }
            })

        elif self.path == '/api/users':
            respond(self, 200, {"users": list_users()})

        elif self.path == '/api/info':
            xui_port_f = '/etc/chaiya/xui-port.conf'
            xui_port = open(xui_port_f).read().strip() if os.path.exists(xui_port_f) else '2053'
            domain_f = '/etc/chaiya/domain.conf'
            domain = open(domain_f).read().strip() if os.path.exists(domain_f) else ''
            respond(self, 200, {
                "host": get_host(),
                "domain": domain,
                "xui_port": int(xui_port),
                "dropbear_port": 143,
                "dropbear_port2": 109,
                "ws_port": 443,
                "udpgw_port": 7300,
            })


        elif self.path == '/api/ban':
            user = data.get('user', '').strip()
            hours = float(data.get('hours', 2))
            if not user:
                return respond(self, 400, {'error': 'user required'})
            import time
            ban_dir = '/etc/chaiya/bans'
            os.makedirs(ban_dir, exist_ok=True)
            ban_until = time.time() + hours * 3600
            with open(f'{ban_dir}/{user}', 'w') as bf:
                bf.write(str(ban_until))
            # iptables block SSH login for this user via chage expire immediately
            run_cmd(f"chage -E 0 {user} 2>/dev/null || true")
            # iptables drop established connections from this user via pkill
            run_cmd(f"pkill -u {user} 2>/dev/null || true")
            respond(self, 200, {'ok': True, 'user': user, 'ban_until': ban_until, 'hours': hours})

        elif self.path == '/api/unban':
            user = data.get('user', '').strip()
            if not user:
                return respond(self, 400, {'error': 'user required'})
            import time
            ban_dir = '/etc/chaiya/bans'
            ban_file = f'{ban_dir}/{user}'
            if os.path.exists(ban_file):
                os.remove(ban_file)
            # restore account expiry from exp file
            exp_f = f'/etc/chaiya/exp/{user}'
            if os.path.exists(exp_f):
                exp_date = open(exp_f).read().strip()
                run_cmd(f"chage -E {exp_date} {user} 2>/dev/null || true")
            else:
                run_cmd(f"chage -E -1 {user} 2>/dev/null || true")
            # re-enable x-ui client
            import sqlite3 as _sq, json as _js
            for port in (8080, 8880):
                try:
                    con = _sq.connect('/etc/x-ui/x-ui.db')
                    row = con.execute("SELECT id, settings FROM inbounds WHERE port=?", (port,)).fetchone()
                    if row:
                        inb_id, s = row
                        settings = _js.loads(s)
                        for c in settings.get('clients', []):
                            if c.get('email') == user:
                                c['enable'] = True
                        con.execute("UPDATE inbounds SET settings=? WHERE id=?", (_js.dumps(settings), inb_id))
                        con.commit()
                    con.close()
                except: pass
            run_cmd("systemctl restart x-ui 2>/dev/null || true")
            respond(self, 200, {'ok': True, 'user': user})

        elif self.path == '/api/unban_vless':
            # ปลดแบน x-ui VLESS client เท่านั้น (ไม่ต้องมี system user)
            user = data.get('user', '').strip()
            inbound_id = data.get('inbound_id')
            uuid = data.get('uuid', '').strip()
            if not user or inbound_id is None:
                return respond(self, 400, {'error': 'user and inbound_id required'})
            import sqlite3 as _sq, json as _js
            try:
                con = _sq.connect('/etc/x-ui/x-ui.db')
                row = con.execute("SELECT id, settings FROM inbounds WHERE id=?", (inbound_id,)).fetchone()
                if row:
                    inb_id, s = row
                    settings = _js.loads(s)
                    for c in settings.get('clients', []):
                        if c.get('email') == user or c.get('id') == uuid:
                            c['enable'] = True
                    con.execute("UPDATE inbounds SET settings=? WHERE id=?", (_js.dumps(settings), inb_id))
                    con.commit()
                con.close()
                run_cmd("systemctl restart x-ui 2>/dev/null || true")
                respond(self, 200, {'ok': True, 'user': user})
            except Exception as e:
                respond(self, 500, {'error': str(e)})


        elif self.path == '/api/banned':
            import time
            ban_dir = '/etc/chaiya/bans'
            banned = []
            if os.path.exists(ban_dir):
                now_ts = time.time()
                for fname in os.listdir(ban_dir):
                    fpath = os.path.join(ban_dir, fname)
                    try:
                        ban_until = float(open(fpath).read().strip())
                        if ban_until > now_ts:
                            banned.append({'user': fname, 'ban_until': ban_until})
                        else:
                            # หมดเวลาแบนแล้ว — ลบไฟล์และ restore account
                            os.remove(fpath)
                            exp_f = f'/etc/chaiya/exp/{fname}'
                            if os.path.exists(exp_f):
                                exp_date = open(exp_f).read().strip()
                                run_cmd(f"chage -E {exp_date} {fname} 2>/dev/null || true")
                            else:
                                run_cmd(f"chage -E -1 {fname} 2>/dev/null || true")
                    except: pass
            respond(self, 200, {'banned': banned, 'count': len(banned)})

        elif self.path == '/api/online':
            # SSH online users — ตรวจจาก ss connections
            import subprocess as _sp
            result = _sp.run(
                "ss -tnp state established 2>/dev/null | grep -E ':(143|109)\b' | grep -oP 'users:\(\("[^"]+"' | grep -oP '"[^"]+"' | sort -u | tr -d '"'",
                shell=True, capture_output=True, text=True, timeout=5
            )
            online_procs = [l.strip() for l in result.stdout.strip().split('\n') if l.strip()]
            # แปลง process name เป็น username
            online_users = []
            db_path = '/etc/chaiya/sshws-users/users.db'
            if os.path.exists(db_path):
                all_users = [line.strip().split()[0] for line in open(db_path) if line.strip()]
                for user in all_users:
                    chk = _sp.run(f"ps -u {user} 2>/dev/null | grep -c .", shell=True, capture_output=True, text=True)
                    try:
                        if int(chk.stdout.strip()) > 0:
                            online_users.append(user)
                    except: pass
            respond(self, 200, {'users': online_users, 'online': online_users, 'count': len(online_users)})

        else:
            respond(self, 404, {'error': 'Not found'})

    def do_POST(self):
        data = self.read_body()

        if self.path == '/api/verify':
            import hashlib
            pw = data.get("password", "")
            hashed = hashlib.sha256(pw.encode()).hexdigest()
            hash_f = '/etc/chaiya/panel-pass.hash'
            stored = ""
            try:
                stored = open(hash_f).read().strip()
            except: pass
            respond(self, 200, {"ok": bool(stored) and hashed == stored})

        elif self.path == '/api/create':
            import re as _re
            user     = data.get('user', '').strip()
            pw       = data.get('pass', '').strip()
            days     = int(data.get('exp_days', data.get('days', 30)))
            data_gb  = int(data.get('data_gb', 0))
            ip_limit = int(data.get('ip_limit', 2))
            if not user or not pw:
                return respond(self, 400, {'error': 'user/pass required'})
            if not _re.match(r'^[a-z0-9_-]{1,32}$', user):
                return respond(self, 400, {'error': 'username: a-z0-9_- เท่านั้น max 32 ตัว'})

            ok1, _, e1 = run_cmd(
                f"userdel -f {user} 2>/dev/null; "
                f"useradd -M -s /bin/false -e {(datetime.date.today() + datetime.timedelta(days=days)).isoformat()} {user}"
            )
            import subprocess as _sp
            _sp.run(['chpasswd'], input=f'{user}:{pw}\n', text=True, capture_output=True, timeout=10)
            exp = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
            run_cmd(f"chage -E {exp} {user}")

            os.makedirs('/etc/chaiya/exp', exist_ok=True)
            with open(f'/etc/chaiya/exp/{user}', 'w') as f:
                f.write(exp)

            os.makedirs('/etc/chaiya/sshws-users', exist_ok=True)
            db = '/etc/chaiya/sshws-users/users.db'
            existing_lines = []
            if os.path.exists(db):
                existing_lines = [l for l in open(db) if not l.strip().startswith(user + ' ')]
            with open(db, 'w') as f:
                f.writelines(existing_lines)
                f.write(f"{user} {days} {exp} {data_gb} {ip_limit}\n")

            user_uuid = add_xui_client(user)

            vless_uuid = None
            try:
                con = sqlite3.connect(XUI_DB)
                row = con.execute("SELECT id, settings FROM inbounds WHERE port=8880").fetchone()
                if row:
                    inbound_id, settings_str = row
                    settings = json.loads(settings_str)
                    clients = [c for c in settings.get('clients', []) if c.get('email') != user]
                    vless_uuid = str(uuid.uuid4())
                    clients.append({'id': vless_uuid, 'flow': '', 'email': user,
                                    'limitIpCount': ip_limit,
                                    'totalGB': data_gb * (1024**3) if data_gb else 0,
                                    'expiryTime': 0, 'enable': True, 'tgId': '', 'subId': ''})
                    settings['clients'] = clients
                    con.execute("UPDATE inbounds SET settings=? WHERE id=?",
                                (json.dumps(settings), inbound_id))
                    con.commit()
                con.close()
            except: pass

            run_cmd("systemctl restart x-ui 2>/dev/null || true")

            host = get_host()
            npv_link = build_npv_link(host, user_uuid, user) if host and user_uuid else None

            respond(self, 200, {
                'ok': True, 'user': user, 'exp': exp,
                'uuid': user_uuid, 'vless_uuid': vless_uuid,
                'ip_limit': ip_limit, 'data_gb': data_gb,
                'npv_link': npv_link
            })

        elif self.path == '/api/delete':
            user = data.get('user', '').strip()
            if not user:
                return respond(self, 400, {'error': 'user required'})
            run_cmd(f"userdel -f {user} 2>/dev/null")
            run_cmd(f"rm -f /etc/chaiya/exp/{user}")
            db = '/etc/chaiya/sshws-users/users.db'
            if os.path.exists(db):
                lines = [l for l in open(db) if not l.strip().startswith(user + ' ')]
                with open(db, 'w') as f: f.writelines(lines)
            remove_xui_client(user)
            respond(self, 200, {'ok': True})

        elif self.path == '/api/service':
            action = data.get('action', '')
            svc    = data.get('service', '')
            if action in ('start', 'stop', 'restart') and svc:
                run_cmd(f"systemctl {action} {svc}")
                respond(self, 200, {'ok': True})
            else:
                respond(self, 400, {'error': 'invalid action or service'})

        else:
            respond(self, 404, {'error': 'Not found'})

class ThreadedHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 2095
    server = ThreadedHTTPServer(('0.0.0.0', port), Handler)
    print(f"Chaiya SSH API running on port {port}")
    server.serve_forever()
PYEOF

chmod +x /opt/chaiya-ssh-api/app.py

cat > /etc/systemd/system/chaiya-ssh-api.service << EOF
[Unit]
Description=Chaiya SSH API
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/chaiya-ssh-api/app.py $SSH_API_PORT
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chaiya-ssh-api
systemctl restart chaiya-ssh-api
sleep 2
ok "SSH API พร้อม (port $SSH_API_PORT)"

# ── WS-STUNNEL (HTTP CONNECT → Dropbear) ─────────────────────
info "ติดตั้ง WS-Stunnel..."
cat > /usr/local/bin/ws-stunnel << 'WSPYEOF'
#!/usr/bin/python3
import socket, threading, select, sys, time

LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 8080
BUFLEN = 4096 * 4
TIMEOUT = 60
DEFAULT_HOST = '127.0.0.1:143'
RESPONSE = b'HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n'

class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.daemon = True
        self.host = host
        self.port = port

    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, int(self.port)))
        self.soc.listen(128)
        while True:
            try:
                c, addr = self.soc.accept()
                t = ConnectionHandler(c, self, addr)
                t.daemon = True
                t.start()
            except socket.timeout: continue
            except Exception: break

class ConnectionHandler(threading.Thread):
    def __init__(self, client, server, addr):
        threading.Thread.__init__(self)
        self.client = client
        self.server = server
        self.addr = addr
        self.clientClosed = False
        self.targetClosed = True

    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except: pass
        finally: self.clientClosed = True
        try:
            if not self.targetClosed:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except: pass
        finally: self.targetClosed = True

    def run(self):
        try:
            buf = self.client.recv(BUFLEN)
            if not buf: self.close(); return
            hostport = DEFAULT_HOST
            for line in buf.split(b'\r\n'):
                if line.upper().startswith(b'HOST:'):
                    hostport = line.split(b':', 1)[1].strip().decode()
                    break
            host, port = (hostport.split(':', 1) + ['143'])[:2]
            try: port = int(port)
            except: port = 143
            self.target = socket.socket(socket.AF_INET)
            self.target.connect((host, port))
            self.targetClosed = False
            self.client.sendall(RESPONSE)
            count = 0
            while True:
                recv, _, err = select.select([self.client, self.target], [], [self.client, self.target], 1)
                if err: break
                if recv:
                    for s in recv:
                        data = s.recv(BUFLEN)
                        if not data: return
                        (self.target if s is self.client else self.client).sendall(data)
                        count = 0
                if count >= TIMEOUT: break
        except: pass
        finally: self.close()

def main():
    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()
    print(f"WS-Stunnel running on port {LISTENING_PORT}")
    while True: time.sleep(60)

if __name__ == '__main__':
    main()
WSPYEOF
chmod +x /usr/local/bin/ws-stunnel

cat > /etc/systemd/system/chaiya-sshws.service << 'WSEOF'
[Unit]
Description=WS-Stunnel SSH Tunnel port 8080 -> Dropbear
After=network.target dropbear.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-stunnel
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
WSEOF

systemctl daemon-reload
systemctl enable chaiya-sshws
systemctl restart chaiya-sshws
sleep 2
ok "WS-Stunnel พร้อม"

# ── PANEL FILES ────────────────────────────────────────────────
info "สร้าง Panel HTML (Login + Dashboard)..."
mkdir -p /opt/chaiya-panel

REAL_XUI_PORT=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")

# บันทึก domain และ IP
echo "$DOMAIN"    > /etc/chaiya/domain.conf
echo "$SERVER_IP" > /etc/chaiya/my_ip.conf

# ── config.js ────────────────────────────────────────────────
cat > /opt/chaiya-panel/config.js << EOF
// Auto-generated by chaiya-setup.sh v4
window.CHAIYA_CONFIG = {
  host:           "${DOMAIN}",
  domain:         "${DOMAIN}",
  ssh_api_port:   ${SSH_API_PORT},
  xui_port:       ${REAL_XUI_PORT},
  xui_user:       "${XUI_USER}",
  xui_pass:       "${XUI_PASS}",
  ssh_token:      "",
  panel_pass:     "${PANEL_PASS_HASH}",
  panel_url:      "https://${DOMAIN}",
  dashboard_url:  "sshws.html"
};
EOF

# ── LOGIN PAGE (chaiya-login.html → index.html) ───────────────
# Embed login HTML directly - ใช้ design จาก chaiya-login.html
cat > /opt/chaiya-panel/index.html << 'LOGINEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA V2RAY PRO MAX — Login</title>
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@600;700&family=Kanit:wght@300;400;600&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<style>
/* ══════════════════════════════════════
   ROOT
══════════════════════════════════════ */
:root{
  --bg:     #070d14;
  --card:   #0d1622;
  --border: rgba(255,255,255,.08);
  --border2:rgba(255,255,255,.13);
  --text:   #e8f4ff;
  --text2:  rgba(255,255,255,.45);
  --text3:  rgba(255,255,255,.25);
  --green:  #72d124;
  --blue:   #7ee8fa;
  --purple: #a78bfa;
  --red:    #f87171;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{
  background:radial-gradient(ellipse 120% 120% at 50% 0%, #0a1628 0%, #060d1a 45%, #030810 100%);
  color:var(--text);
  font-family:'Kanit',sans-serif;
  font-weight:400;
  min-height:100vh;
  display:flex;flex-direction:column;
  align-items:center;justify-content:center;
  overflow:hidden;position:relative;
}

/* ══════════════════════════════════════
   BACKGROUND LAYERS
══════════════════════════════════════ */
/* ambient RGB glow */
body::before{
  content:'';position:fixed;inset:0;pointer-events:none;
  background:
    radial-gradient(ellipse 70% 55% at 20% 30%, rgba(40,100,200,.09) 0%,transparent 65%),
    radial-gradient(ellipse 60% 50% at 80% 70%, rgba(20,60,160,.07)  0%,transparent 65%),
    radial-gradient(ellipse 90% 50% at 50% 100%,rgba(80,140,255,.05) 0%,transparent 60%);
  animation:ambientPulse 9s ease-in-out infinite alternate;
}
@keyframes ambientPulse{
  0%  {opacity:.7}50%{opacity:1}100%{opacity:.6}
}

/* grid dots — ลบออก ใช้หิมะแทน */
body::after{ content:''; }

/* snow canvas */
#snow-canvas{position:fixed;inset:0;pointer-events:none;z-index:1}

/* ══════════════════════════════════════
   LOGIN CARD
══════════════════════════════════════ */
.login-wrap{
  position:relative;z-index:10;
  width:100%;max-width:380px;
  padding:1.2rem;
}

/* glow ring รอบ card */
.card-glow{
  position:absolute;inset:-1px;border-radius:27px;
  background:linear-gradient(135deg,rgba(126,232,250,.18),rgba(167,139,250,.12),rgba(114,209,36,.14),rgba(126,232,250,.18));
  background-size:300% 300%;
  animation:borderGlow 6s linear infinite;
  z-index:0;
}
@keyframes borderGlow{to{background-position:300% 300%}}

.login-card{
  position:relative;z-index:1;
  background:var(--card);
  border-radius:26px;
  padding:2.2rem 2rem 2rem;
  border:1px solid var(--border2);
  box-shadow:0 24px 60px rgba(0,0,0,.5),inset 0 1px 0 rgba(255,255,255,.06);
}

/* ══════════════════════════════════════
   LOGO AREA
══════════════════════════════════════ */
.logo-area{text-align:center;margin-bottom:1.8rem}
.logo-badge{
  display:inline-flex;align-items:center;gap:.55rem;
  font-family:'Share Tech Mono',monospace;font-size:.58rem;
  letter-spacing:.38em;color:rgba(126,232,250,.5);
  margin-bottom:.8rem;
}
.logo-badge::before,.logo-badge::after{
  content:'';display:inline-block;height:1px;width:28px;
  background:linear-gradient(90deg,transparent,rgba(126,232,250,.35));
}
.logo-badge::after{background:linear-gradient(90deg,rgba(126,232,250,.35),transparent)}

.logo-icon{
  width:64px;height:64px;border-radius:18px;
  background:linear-gradient(135deg,#0f1f0a,#1a3512);
  border:1px solid rgba(114,209,36,.25);
  display:flex;align-items:center;justify-content:center;
  margin:0 auto .9rem;
  box-shadow:0 0 0 6px rgba(114,209,36,.06),0 8px 24px rgba(0,0,0,.3);
  font-size:1.8rem;
  position:relative;overflow:hidden;
}
.logo-icon::after{
  content:'';position:absolute;inset:0;
  background:linear-gradient(135deg,rgba(126,232,250,.08),transparent 60%);
}

.logo-title{
  font-family:'Rajdhani',sans-serif;font-size:1.9rem;font-weight:700;
  letter-spacing:.1em;color:var(--text);line-height:1;
}
.logo-title .rgb{
  background:linear-gradient(90deg,#7ee8fa,#a78bfa,#80ff72,#7ee8fa);
  background-size:250% auto;
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;
  background-clip:text;
  animation:rgbFlow 4s linear infinite;
}
@keyframes rgbFlow{to{background-position:250% center}}

.logo-sub{
  font-family:'Share Tech Mono',monospace;
  font-size:.65rem;color:var(--text3);letter-spacing:.1em;
  margin-top:.35rem;
}

/* ══════════════════════════════════════
   FORM
══════════════════════════════════════ */
.form-group{margin-bottom:1rem;position:relative}
.form-label{
  display:flex;align-items:center;gap:.35rem;
  font-family:'Share Tech Mono',monospace;
  font-size:.62rem;letter-spacing:.12em;text-transform:uppercase;
  color:var(--text2);margin-bottom:.45rem;
}
.input-wrap{position:relative}
.input-icon{
  position:absolute;left:.9rem;top:50%;transform:translateY(-50%);
  font-size:.95rem;pointer-events:none;
}
.form-input{
  width:100%;
  background:rgba(255,255,255,.04);
  border:1.5px solid rgba(255,255,255,.1);
  border-radius:12px;
  padding:.72rem .9rem .72rem 2.6rem;
  color:var(--text);
  font-family:'Kanit',sans-serif;font-size:.92rem;
  outline:none;
  transition:border-color .2s,box-shadow .2s,background .2s;
}
.form-input::placeholder{color:var(--text3)}
.form-input:focus{
  background:rgba(255,255,255,.07);
  border-color:rgba(126,232,250,.4);
  box-shadow:0 0 0 3px rgba(126,232,250,.08),inset 0 1px 0 rgba(255,255,255,.04);
}

/* eye toggle */
.eye-btn{
  position:absolute;right:.9rem;top:50%;transform:translateY(-50%);
  background:none;border:none;cursor:pointer;
  color:var(--text3);font-size:1rem;padding:.2rem;
  transition:color .2s;
}
.eye-btn:hover{color:var(--text2)}

/* ══════════════════════════════════════
   LOGIN BUTTON
══════════════════════════════════════ */
.login-btn{
  width:100%;margin-top:.4rem;
  padding:.88rem;border:none;border-radius:13px;
  font-family:'Rajdhani',sans-serif;font-size:1.06rem;font-weight:700;
  letter-spacing:.14em;cursor:pointer;
  position:relative;overflow:hidden;
  background:linear-gradient(135deg,#1a3a10,#2d6016,#3d8018);
  color:#d4f8a0;
  box-shadow:0 4px 20px rgba(72,160,20,.25),inset 0 1px 0 rgba(255,255,255,.1);
  transition:all .22s;
}
.login-btn::before{
  content:'';position:absolute;inset:0;
  background:linear-gradient(90deg,rgba(126,232,250,.15),rgba(167,139,250,.1),rgba(114,209,36,.12),rgba(126,232,250,.15));
  background-size:300% auto;
  animation:btnRgb 4s linear infinite;opacity:0;
  transition:opacity .3s;
}
@keyframes btnRgb{to{background-position:300% center}}
.login-btn:hover::before{opacity:1}
.login-btn:hover{
  box-shadow:0 6px 28px rgba(72,160,20,.38),inset 0 1px 0 rgba(255,255,255,.12);
  transform:translateY(-1px);
}
.login-btn:active{transform:translateY(0)}
.login-btn:disabled{opacity:.5;cursor:not-allowed;transform:none}
.login-btn .btn-inner{position:relative;z-index:1;display:flex;align-items:center;justify-content:center;gap:.5rem}

/* spinner */
.spin-ring{
  display:inline-block;width:16px;height:16px;
  border:2px solid rgba(255,255,255,.25);
  border-top-color:rgba(255,255,255,.8);
  border-radius:50%;
  animation:spin .7s linear infinite;
}
@keyframes spin{to{transform:rotate(360deg)}}

/* ══════════════════════════════════════
   ALERT
══════════════════════════════════════ */
.login-alert{
  display:none;margin-top:.85rem;
  padding:.65rem .9rem;border-radius:10px;
  font-size:.8rem;line-height:1.5;text-align:center;
}
.login-alert.err{
  background:rgba(248,113,113,.1);
  border:1px solid rgba(248,113,113,.25);
  color:#fca5a5;
}
.login-alert.ok{
  background:rgba(114,209,36,.1);
  border:1px solid rgba(114,209,36,.25);
  color:#a3e635;
}

/* ══════════════════════════════════════
   FOOTER INFO
══════════════════════════════════════ */
.login-footer{
  text-align:center;margin-top:1.5rem;
  font-family:'Share Tech Mono',monospace;
  font-size:.6rem;color:var(--text3);letter-spacing:.06em;
  line-height:1.8;
}
.login-footer .dot{margin:0 .3rem;color:rgba(126,232,250,.2)}

/* ══════════════════════════════════════
   SERVER INFO STRIP
══════════════════════════════════════ */
.server-strip{
  display:flex;align-items:center;justify-content:center;gap:.5rem;
  background:rgba(255,255,255,.03);
  border:1px solid var(--border);border-radius:10px;
  padding:.5rem .8rem;margin-bottom:1.4rem;
  font-family:'Share Tech Mono',monospace;font-size:.65rem;
  color:var(--text3);
}
.server-dot{
  width:6px;height:6px;border-radius:50%;background:#22c55e;
  box-shadow:0 0 5px rgba(34,197,94,.6);
  animation:pingDot 2s infinite;flex-shrink:0;
}
@keyframes pingDot{0%,100%{opacity:1}50%{opacity:.35}}

/* ══════════════════════════════════════
   SNOWFLAKE EFFECT ที่ card
══════════════════════════════════════ */
@keyframes floatCard{
  0%,100%{transform:translateY(0)}
  50%    {transform:translateY(-4px)}
}
.login-card{animation:floatCard 6s ease-in-out infinite}

/* shake on error */
@keyframes shake{
  0%,100%{transform:translateX(0)}
  20%    {transform:translateX(-6px)}
  40%    {transform:translateX(6px)}
  60%    {transform:translateX(-4px)}
  80%    {transform:translateX(4px)}
}
.shake{animation:shake .4s ease-in-out!important}
</style>
</head>
<body>

<canvas id="snow-canvas"></canvas>

<div class="login-wrap">
  <!-- glow border -->
  <div class="card-glow"></div>

  <div class="login-card" id="login-card">

    <!-- Logo -->
    <div class="logo-area">
      <div class="logo-badge">CHAIYA V2RAY PRO MAX</div>
      <div class="logo-icon">🛡️</div>
      <div class="logo-title">ADMIN <span class="rgb">PANEL</span></div>
      <div class="logo-sub">x-ui Management Dashboard</div>
    </div>

    <!-- Server strip -->
    <div class="server-strip">
      <span class="server-dot"></span>
      <span id="srv-host">กำลังเชื่อมต่อ...</span>
    </div>

    <!-- Username -->
    <div class="form-group">
      <div class="form-label">👤 Username</div>
      <div class="input-wrap">
        <span class="input-icon">👤</span>
        <input
          type="text" id="inp-user"
          class="form-input" placeholder="admin"
          autocomplete="username"
          onkeydown="if(event.key==='Enter')doLogin()"
        >
      </div>
    </div>

    <!-- Password -->
    <div class="form-group">
      <div class="form-label">🔑 Password</div>
      <div class="input-wrap">
        <span class="input-icon">🔑</span>
        <input
          type="password" id="inp-pass"
          class="form-input" placeholder="••••••••"
          autocomplete="current-password"
          onkeydown="if(event.key==='Enter')doLogin()"
          style="padding-right:2.8rem"
        >
        <button class="eye-btn" id="eye-btn" onclick="toggleEye()" type="button">👁</button>
      </div>
    </div>

    <!-- Login Button -->
    <button class="login-btn" id="login-btn" onclick="doLogin()">
      <span class="btn-inner" id="btn-inner">
        ⚡ เข้าสู่ระบบ
      </span>
    </button>

    <!-- Alert -->
    <div class="login-alert" id="login-alert"></div>

    <!-- Footer -->
    <div class="login-footer">
      <span id="login-time">--</span>
      <span class="dot">·</span>
      CHAIYA VPN SYSTEM
      <span class="dot">·</span>
      v8.0
    </div>

  </div><!-- /login-card -->
</div>

<script>
/* ══════════════════════════════════════
   CONFIG — อ่านจาก CHAIYA_CONFIG เหมือน dashboard
══════════════════════════════════════ */
const CFG     = (typeof window.CHAIYA_CONFIG !== 'undefined') ? window.CHAIYA_CONFIG : {};
const HOST    = CFG.host      || location.hostname;
const XUI_API = '/xui-api';
// ชื่อ key ที่จะเก็บใน sessionStorage
const SESSION_KEY = 'chaiya_auth';
// หน้า dashboard ที่จะ redirect ไป
const DASHBOARD = CFG.dashboard_url || 'sshws.html';

/* ══════════════════════════════════════
   INIT
══════════════════════════════════════ */
window.addEventListener('load', () => {
  // ถ้า login ค้างไว้แล้ว ข้ามไป dashboard เลย
  const saved = sessionStorage.getItem(SESSION_KEY);
  if (saved) {
    try {
      const s = JSON.parse(saved);
      if (s.user && s.pass && Date.now() < s.exp) {
        window.location.replace(DASHBOARD);
        return;
      }
    } catch(e) {}
    sessionStorage.removeItem(SESSION_KEY);
  }

  document.getElementById('srv-host').textContent = HOST;
  updateClock();
  setInterval(updateClock, 1000);

  // focus username
  document.getElementById('inp-user').focus();
  if (CFG.xui_user) document.getElementById('inp-user').value = CFG.xui_user;

  startSnow('snow-canvas', 55, true);
});

function updateClock() {
  document.getElementById('login-time').textContent =
    new Date().toLocaleTimeString('th-TH', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

/* ══════════════════════════════════════
   EYE TOGGLE
══════════════════════════════════════ */
let eyeOpen = false;
function toggleEye() {
  eyeOpen = !eyeOpen;
  document.getElementById('inp-pass').type = eyeOpen ? 'text' : 'password';
  document.getElementById('eye-btn').textContent = eyeOpen ? '🙈' : '👁';
}

/* ══════════════════════════════════════
   LOGIN LOGIC
══════════════════════════════════════ */
async function doLogin() {
  const user = document.getElementById('inp-user').value.trim();
  const pass = document.getElementById('inp-pass').value;

  if (!user) return showAlert('กรุณาใส่ Username', 'err');
  if (!pass) return showAlert('กรุณาใส่ Password', 'err');

  setLoading(true);
  hideAlert();

  try {
    // POST ไป x-ui login endpoint
    const form = new URLSearchParams({ username: user, password: pass });
    const res  = await Promise.race([
      fetch(XUI_API + '/login', {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form.toString()
      }),
      new Promise((_, rej) => setTimeout(() => rej(new Error('Connection timeout')), 8000))
    ]);

    const data = await res.json();

    if (data.success) {
      // บันทึก session 8 ชั่วโมง
      sessionStorage.setItem(SESSION_KEY, JSON.stringify({
        user, pass,
        exp: Date.now() + 8 * 3600 * 1000
      }));
      showAlert('✅ เข้าสู่ระบบสำเร็จ กำลัง redirect...', 'ok');

      // flash สีเขียวแล้ว redirect
      setTimeout(() => {
        window.location.replace(DASHBOARD);
      }, 900);
    } else {
      throw new Error(data.msg || 'Username หรือ Password ไม่ถูกต้อง');
    }
  } catch (e) {
    showAlert('❌ ' + e.message, 'err');
    // shake card
    const card = document.getElementById('login-card');
    card.classList.remove('shake');
    void card.offsetWidth; // reflow
    card.classList.add('shake');
    setTimeout(() => card.classList.remove('shake'), 450);
    // เขย่า input
    ['inp-user','inp-pass'].forEach(id => {
      document.getElementById(id).style.borderColor = 'rgba(248,113,113,.5)';
      setTimeout(() => {
        document.getElementById(id).style.borderColor = '';
      }, 1500);
    });
  } finally {
    setLoading(false);
  }
}

function setLoading(on) {
  const btn = document.getElementById('login-btn');
  const inner = document.getElementById('btn-inner');
  btn.disabled = on;
  inner.innerHTML = on
    ? '<span class="spin-ring"></span> กำลังตรวจสอบ...'
    : '⚡ เข้าสู่ระบบ';
}

function showAlert(msg, type) {
  const el = document.getElementById('login-alert');
  el.textContent = msg;
  el.className = 'login-alert ' + type;
  el.style.display = 'block';
}
function hideAlert() {
  document.getElementById('login-alert').style.display = 'none';
}

function startSnow(canvasId, count, isFull) {
  const canvas = document.getElementById(canvasId || 'snow-canvas');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');

  function resize() {
    if (isFull) {
      canvas.width  = window.innerWidth;
      canvas.height = window.innerHeight;
    } else {
      canvas.width  = canvas.offsetWidth  || canvas.parentElement.offsetWidth  || 400;
      canvas.height = canvas.offsetHeight || canvas.parentElement.offsetHeight || 200;
    }
  }
  resize();
  window.addEventListener('resize', resize);

  const N = count || 48;
  const flakes = [];

  // ขนาดหลายระดับ: เกล็ดใหญ่น้อยใหญ่สลับกัน
  function mkFlake(scatter) {
    const tier = Math.random();
    const size = tier < 0.15 ? (Math.random() * 9 + 10)   // ใหญ่มาก
               : tier < 0.45 ? (Math.random() * 5 + 5.5)  // กลาง
               : (Math.random() * 3 + 2);                  // เล็ก
    return {
      x:        Math.random() * (canvas.width  || 400),
      y:        scatter ? Math.random() * (canvas.height || 300) : -size * 2,
      size,
      speed:    (0.18 + Math.random() * 0.35) * (1 + (18 - Math.min(size, 18)) * 0.015),
      drift:    (Math.random() - 0.5) * 0.28,
      rot:      Math.random() * Math.PI * 2,
      rotSpeed: (Math.random() - 0.5) * 0.012,
      alpha:    0.18 + Math.random() * 0.55,
      glowR:    180 + Math.floor(Math.random() * 55),  // โทนขาว-ฟ้าน้ำแข็ง
      glowG:    210 + Math.floor(Math.random() * 40),
      glowB:    255,
      sway:     0,
      swaySpeed: (Math.random() - 0.5) * 0.018,
      swayAmp:  Math.random() * 0.45 + 0.1,
    };
  }

  for (let i = 0; i < N; i++) flakes.push(mkFlake(true));

  // วาดเกล็ดหิมะ 6 แฉก (dendrite) พร้อม sub-branch
  function drawFlake(f) {
    ctx.save();
    ctx.translate(f.x, f.y);
    ctx.rotate(f.rot);
    const s = f.size;
    const col = `${f.glowR},${f.glowG},${f.glowB}`;

    // glow รอบเกล็ด (เฉพาะเกล็ดใหญ่)
    if (s > 6) {
      const grd = ctx.createRadialGradient(0, 0, s * 0.1, 0, 0, s * 1.5);
      grd.addColorStop(0, `rgba(${col},${f.alpha * 0.4})`);
      grd.addColorStop(1, `rgba(${col},0)`);
      ctx.beginPath();
      ctx.arc(0, 0, s * 1.5, 0, Math.PI * 2);
      ctx.fillStyle = grd;
      ctx.fill();
    }

    ctx.strokeStyle = `rgba(${col},${f.alpha})`;
    ctx.lineCap = 'round';

    // 6 แขน
    for (let arm = 0; arm < 6; arm++) {
      ctx.save();
      ctx.rotate((arm * Math.PI) / 3);

      // เส้นหลัก
      ctx.lineWidth = Math.max(0.6, s * 0.11);
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.lineTo(0, -s);
      ctx.stroke();

      // กิ่งระดับ 1 (2 คู่)
      const bw = s * 0.13;
      [[s * 0.35, s * 0.28], [s * 0.62, s * 0.22]].forEach(([pos, len]) => {
        ctx.lineWidth = Math.max(0.4, bw);
        [1, -1].forEach(dir => {
          ctx.beginPath();
          ctx.moveTo(0, -pos);
          ctx.lineTo(dir * len * 0.7, -pos - len * 0.5);
          ctx.stroke();
        });
      });

      // กิ่งระดับ 2 (เฉพาะเกล็ดใหญ่)
      if (s > 7) {
        ctx.lineWidth = Math.max(0.3, bw * 0.55);
        const pos3 = s * 0.5, len3 = s * 0.14;
        [1, -1].forEach(dir => {
          ctx.beginPath();
          ctx.moveTo(0, -pos3);
          ctx.lineTo(dir * len3, -pos3 - len3 * 0.6);
          ctx.stroke();
        });
      }

      // จุดปลายแขน
      if (s > 4) {
        ctx.beginPath();
        ctx.arc(0, -s, Math.max(0.6, s * 0.1), 0, Math.PI * 2);
        ctx.fillStyle = `rgba(${col},${Math.min(f.alpha + 0.3, 1)})`;
        ctx.fill();
      }

      ctx.restore();
    }

    // แกนกลาง
    ctx.beginPath();
    ctx.arc(0, 0, Math.max(0.8, s * 0.14), 0, Math.PI * 2);
    ctx.fillStyle = `rgba(${col},${Math.min(f.alpha + 0.35, 1)})`;
    ctx.fill();

    // วงแหวนกลาง (เฉพาะเกล็ดใหญ่)
    if (s > 8) {
      ctx.beginPath();
      ctx.arc(0, 0, s * 0.28, 0, Math.PI * 2);
      ctx.lineWidth = 0.5;
      ctx.strokeStyle = `rgba(${col},${f.alpha * 0.6})`;
      ctx.stroke();
    }

    ctx.restore();
  }

  let frame;
  function tick() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    flakes.forEach(f => {
      f.sway += f.swaySpeed;
      f.y   += f.speed;
      f.x   += f.drift + Math.sin(f.sway) * f.swayAmp;
      f.rot += f.rotSpeed;
      if (f.y > (canvas.height || 300) + 20 || f.x < -30 || f.x > (canvas.width || 400) + 30) {
        Object.assign(f, mkFlake(false));
        f.x = Math.random() * (canvas.width || 400);
      }
      drawFlake(f);
    });
    frame = requestAnimationFrame(tick);
  }
  tick();
  return () => cancelAnimationFrame(frame);
}

// Login page เรียก startSnow แบบ full-screen

</script>
</body>
</html>
LOGINEOF
ok "Login page พร้อม"

# ── DASHBOARD (sshws.html) — v8 embedded ──────────────────────
info "สร้าง Dashboard v8..."

# ลบไฟล์เก่าออกก่อน
rm -f /opt/chaiya-panel/sshws.html /opt/chaiya-panel/index.html.bak 2>/dev/null || true

# เขียน dashboard v8 ลงตรงๆ (แก้ session/API ให้ตรงระบบใหม่แล้ว)
cat > /opt/chaiya-panel/sshws.html << 'DASHV8EOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA V2RAY PRO MAX — Dashboard</title>
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@600;700&family=Kanit:wght@300;400;600&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
/* ══════════════════════════════════════
   ROOT & RESET
══════════════════════════════════════ */
:root {
  --bg:        #f0f4f8;
  --surface:   #ffffff;
  --border:    #e2e8f0;
  --shadow:    0 2px 12px rgba(0,0,0,.08);
  --shadow-lg: 0 4px 24px rgba(0,0,0,.12);

  --ais:       #5a9e1c;
  --ais2:      #3d7a0e;
  --ais-light: #f0f9e8;
  --ais-bdr:   #c5e89a;

  --true:      #e01020;
  --true2:     #b8000e;
  --true-light:#fff0f0;
  --true-bdr:  #f8a0a8;

  --ssh:       #1a6fa8;
  --ssh2:      #0d5487;
  --ssh-light: #e8f4fc;
  --ssh-bdr:   #90caf0;

  --text:      #1a2332;
  --text2:     #4a6072;
  --text3:     #8099ac;
  --green:     #22c55e;
  --orange:    #f97316;
  --red:       #ef4444;
  --purple:    #8b5cf6;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{
  background:var(--bg);
  color:var(--text);
  font-family:'Kanit',sans-serif;
  font-weight:400;
  min-height:100vh;
  overflow-x:hidden;
}

/* ══════════════════════════════════════
   HEADER
══════════════════════════════════════ */
/* ══════════════════════════════════════
   HEADER — dark + RGB glow + snowflakes
══════════════════════════════════════ */
.site-header{
  text-align:center;
  padding:2.2rem 1.5rem 1.8rem;
  background:radial-gradient(ellipse 140% 130% at 50% -10%, #0d1f3c 0%, #060e1e 55%, #020810 100%);
  border-bottom:1px solid rgba(255,255,255,.06);
  position:relative;overflow:hidden;
}
/* RGB glow คลื่นรอบหัว */
.site-header::before{
  content:'';position:absolute;inset:0;
  background:
    radial-gradient(ellipse 60% 50% at 20% 40%,rgba(80,150,255,.10) 0%,transparent 70%),
    radial-gradient(ellipse 60% 50% at 80% 60%,rgba(40,100,220,.08) 0%,transparent 70%),
    radial-gradient(ellipse 90% 60% at 50% 120%,rgba(120,180,255,.07) 0%,transparent 65%);
  pointer-events:none;animation:hdrGlow 8s ease-in-out infinite alternate;
}
@keyframes hdrGlow{
  0%  {opacity:.7}
  50% {opacity:1}
  100%{opacity:.6}
}
/* canvas หิมะ */
#snow-canvas{position:absolute;inset:0;pointer-events:none;z-index:0}

.site-logo{
  font-family:'Share Tech Mono',monospace;
  font-size:.6rem;letter-spacing:.38em;
  color:rgba(160,220,255,.5);
  margin-bottom:.5rem;
  display:flex;align-items:center;justify-content:center;gap:.75rem;
  position:relative;z-index:2;
}
.site-logo::before,.site-logo::after{
  content:'';display:inline-block;height:1px;width:44px;
  background:linear-gradient(90deg,transparent,rgba(100,180,255,.35));
}
.site-logo::after{background:linear-gradient(90deg,rgba(100,180,255,.35),transparent)}

.site-title{
  font-family:'Rajdhani',sans-serif;font-size:2.45rem;font-weight:700;
  letter-spacing:.09em;color:#e8f4ff;
  position:relative;z-index:2;line-height:1.1;
  text-shadow:0 0 30px rgba(80,160,255,.2);
}
.site-title .rgb-word{
  background:linear-gradient(90deg,#7ee8fa,#80ff72,#7ee8fa);
  background-size:200% auto;
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;
  animation:rgbShift 4s linear infinite;
}
@keyframes rgbShift{to{background-position:200% center}}

.site-sub{
  font-size:.7rem;color:rgba(255,255,255,.3);margin-top:.4rem;
  font-family:'Share Tech Mono',monospace;letter-spacing:.07em;
  position:relative;z-index:2;
}
.site-sub .dot{margin:0 .4rem;color:rgba(130,200,255,.35)}

/* ══════════════════════════════════════
   TAB NAV — dark sticky
══════════════════════════════════════ */
.tab-nav{
  display:flex;
  background:#0e1825;
  border-bottom:1px solid rgba(255,255,255,.07);
  overflow-x:auto;-webkit-overflow-scrolling:touch;
  position:sticky;top:0;z-index:200;
}
.tab-nav::-webkit-scrollbar{display:none}
.tab-btn{
  flex:1;min-width:80px;padding:.8rem .5rem;
  border:none;background:transparent;
  font-family:'Kanit',sans-serif;font-size:.78rem;font-weight:600;
  color:rgba(255,255,255,.35);cursor:pointer;
  border-bottom:2px solid transparent;
  transition:all .22s;white-space:nowrap;
}
.tab-btn:hover{color:rgba(255,255,255,.65);background:rgba(255,255,255,.03)}
.tab-btn.active{
  color:#7ee8fa;border-bottom-color:#7ee8fa;
  background:rgba(126,232,250,.05);
  text-shadow:0 0 12px rgba(126,232,250,.4);
}

/* ══════════════════════════════════════
   RGB SECTION LABELS
══════════════════════════════════════ */
.section-label{
  display:flex;align-items:center;gap:.55rem;
  font-family:'Rajdhani',sans-serif;
  font-size:.9rem;font-weight:700;letter-spacing:.16em;text-transform:uppercase;
  padding:.2rem 0 .8rem;
  position:relative;
}
.section-label .lbl-text{
  background:linear-gradient(90deg,#7ee8fa,#a78bfa,#80ff72,#7ee8fa);
  background-size:300% auto;
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;
  animation:rgbShift 5s linear infinite;
}
.section-label::after{
  content:'';flex:1;height:1px;
  background:linear-gradient(90deg,rgba(126,232,250,.2),transparent);
  margin-left:.4rem;
}

/* ══════════════════════════════════════
   TAB NAV
══════════════════════════════════════ */
.tab-nav{
  display:flex;
  background:var(--surface);
  border-bottom:1px solid var(--border);
  overflow-x:auto;
  -webkit-overflow-scrolling:touch;
}
.tab-nav::-webkit-scrollbar{display:none}
.tab-btn{
  flex:1;min-width:80px;
  padding:.75rem .5rem;
  border:none;background:transparent;
  font-family:'Kanit',sans-serif;font-size:.8rem;font-weight:600;
  color:var(--text3);cursor:pointer;
  border-bottom:2px solid transparent;
  transition:all .2s;white-space:nowrap;
}
.tab-btn.active{color:var(--ais);border-bottom-color:var(--ais)}

/* ══════════════════════════════════════
   TAB PANELS
══════════════════════════════════════ */
.tab-panel{display:none}
.tab-panel.active{display:block}

/* ══════════════════════════════════════
   MAIN LAYOUT
══════════════════════════════════════ */
.main{max-width:520px;margin:0 auto;padding:1.4rem 1rem 4rem;display:flex;flex-direction:column;gap:1.2rem}

/* ══════════════════════════════════════
   SYSTEM STATS — WIDGETS
══════════════════════════════════════ */
.stats-grid{
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:.8rem;
}
.stat-card{
  background:var(--surface);
  border-radius:16px;
  padding:1rem 1.1rem;
  border:1px solid var(--border);
  box-shadow:var(--shadow);
  position:relative;overflow:hidden;
}
.stat-card.wide{grid-column:span 2}
.stat-label{
  font-family:'Share Tech Mono',monospace;
  font-size:.65rem;letter-spacing:.1em;text-transform:uppercase;
  color:var(--text3);margin-bottom:.4rem;
  display:flex;align-items:center;gap:.4rem;
}
.stat-value{
  font-family:'Rajdhani',sans-serif;
  font-size:1.9rem;font-weight:700;line-height:1;
  color:var(--text);
}
.stat-unit{font-size:1rem;color:var(--text2);margin-left:.15rem}
.stat-sub{font-size:.72rem;color:var(--text3);margin-top:.3rem}

/* Ring gauge */
.ring-wrap{display:flex;align-items:center;gap:.9rem}
.ring-svg{flex-shrink:0}
.ring-track{fill:none;stroke:var(--border);stroke-width:6}
.ring-fill{fill:none;stroke-width:6;stroke-linecap:round;
  transition:stroke-dashoffset 1s cubic-bezier(.4,0,.2,1)}
.ring-info{flex:1}

/* Bar gauge */
.bar-gauge{
  height:8px;background:var(--border);border-radius:4px;
  margin-top:.6rem;overflow:hidden;
}
.bar-fill{
  height:100%;border-radius:4px;
  transition:width 1s cubic-bezier(.4,0,.2,1);
}

/* Online badge */
.online-badge{
  display:inline-flex;align-items:center;gap:.35rem;
  background:#f0fdf4;border:1px solid #86efac;
  color:#166534;padding:.25rem .7rem;border-radius:20px;
  font-size:.72rem;font-family:'Share Tech Mono',monospace;
}
.online-dot{width:7px;height:7px;border-radius:50%;background:var(--green);
  animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}

.refresh-btn{
  border:1px solid var(--border);background:var(--surface);
  border-radius:8px;padding:.3rem .7rem;
  font-size:.75rem;color:var(--text2);cursor:pointer;
  font-family:'Kanit',sans-serif;
  transition:all .2s;
}
.refresh-btn:hover{background:var(--bg);color:var(--text)}
.refresh-btn.spin svg{animation:spinR .6s linear infinite}
@keyframes spinR{to{transform:rotate(360deg)}}

/* uptime chip */
.chip{
  display:inline-block;
  background:#f8fafc;border:1px solid var(--border);
  border-radius:6px;padding:.15rem .5rem;
  font-family:'Share Tech Mono',monospace;font-size:.72rem;color:var(--text2);
}

/* ══════════════════════════════════════
   SECTION LABEL
══════════════════════════════════════ */
.section-label{
  display:flex;align-items:center;gap:.5rem;
  font-family:'Rajdhani',sans-serif;
  font-size:.9rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
  color:var(--text2);padding:.2rem 0 .7rem;
}

/* ══════════════════════════════════════
   CARD GROUP (buttons)
══════════════════════════════════════ */
.card-group{
  background:var(--surface);border-radius:18px;
  box-shadow:var(--shadow);overflow:hidden;
  border:1px solid var(--border);
}
.card-group .carrier-btn+.carrier-btn{border-top:1px solid var(--border)}

/* ══════════════════════════════════════
   CARRIER BUTTONS
══════════════════════════════════════ */
.carrier-btn{
  width:100%;border:none;background:var(--surface);
  padding:1rem 1.2rem;cursor:pointer;
  display:flex;align-items:center;gap:1rem;text-align:left;
  transition:background .15s;
}
.carrier-btn:hover{background:#f8fbff}
.carrier-btn:active{background:#f0f6ff}

.btn-logo{
  width:54px;height:54px;border-radius:13px;
  display:flex;align-items:center;justify-content:center;
  flex-shrink:0;overflow:hidden;
  border:1px solid var(--border);background:#f4f4f4;
}
.logo-ais{background:#fff;border-color:var(--ais-bdr)}
.logo-true{background:#c8040d;border-color:#e0000a}
.logo-ssh{background:#1565c0;border-color:#1976d2}

.btn-info{flex:1;min-width:0}
.btn-name{font-family:'Rajdhani',sans-serif;font-size:1.12rem;font-weight:700;letter-spacing:.04em;display:block;margin-bottom:.15rem}
.btn-ais  .btn-name{color:var(--ais)}
.btn-true .btn-name{color:var(--true)}
.btn-ssh  .btn-name{color:var(--ssh)}
.btn-desc{font-size:.74rem;font-weight:300;color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block}
.btn-true .btn-desc{color:var(--true)}
.btn-arrow{color:var(--text3);font-size:1.1rem;flex-shrink:0;transition:transform .18s}
.carrier-btn:hover .btn-arrow{transform:translateX(3px);color:var(--text2)}

/* ══════════════════════════════════════
   USER MANAGEMENT — search / list
══════════════════════════════════════ */
.mgmt-panel{
  background:var(--surface);border-radius:18px;
  border:1px solid var(--border);box-shadow:var(--shadow);
  overflow:hidden;
}
.mgmt-header{
  padding:.9rem 1.2rem;
  border-bottom:1px solid var(--border);
  display:flex;align-items:center;justify-content:space-between;
  gap:.8rem;
}
.mgmt-title{
  font-family:'Rajdhani',sans-serif;font-size:1rem;font-weight:700;
  letter-spacing:.06em;color:var(--text);display:flex;align-items:center;gap:.5rem;
}
.search-bar{
  display:flex;align-items:center;gap:.5rem;
  padding:.8rem 1.2rem;border-bottom:1px solid var(--border);
}
.search-bar input{
  flex:1;background:#f8fafc;border:1.5px solid var(--border);
  border-radius:10px;padding:.5rem .85rem;
  font-family:'Kanit',sans-serif;font-size:.88rem;
  outline:none;color:var(--text);transition:border-color .2s;
}
.search-bar input:focus{border-color:var(--ssh);background:#fff}

/* User row */
.user-list{max-height:400px;overflow-y:auto}
.user-list::-webkit-scrollbar{width:4px}
.user-list::-webkit-scrollbar-thumb{background:rgba(0,0,0,.1);border-radius:2px}

.user-row{
  padding:.75rem 1.2rem;
  border-bottom:1px solid var(--border);
  display:flex;align-items:center;gap:.8rem;
  transition:background .15s;cursor:pointer;
}
.user-row:last-child{border-bottom:none}
.user-row:hover{background:#f8fafc}
.user-avatar{
  width:36px;height:36px;border-radius:10px;
  display:flex;align-items:center;justify-content:center;
  font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;
  flex-shrink:0;
}
.ua-ais{background:var(--ais-light);color:var(--ais2);border:1px solid var(--ais-bdr)}
.ua-true{background:var(--true-light);color:var(--true2);border:1px solid var(--true-bdr)}

.user-info{flex:1;min-width:0}
.user-name{font-weight:600;font-size:.88rem;color:var(--text);margin-bottom:.1rem}
.user-meta{font-size:.72rem;color:var(--text3);font-family:'Share Tech Mono',monospace}

.status-badge{
  font-size:.68rem;padding:.2rem .55rem;border-radius:20px;
  font-family:'Share Tech Mono',monospace;flex-shrink:0;
}
.status-ok{background:#f0fdf4;border:1px solid #86efac;color:#166534}
.status-exp{background:#fff7ed;border:1px solid #fed7aa;color:#92400e}
.status-dead{background:#fef2f2;border:1px solid #fca5a5;color:#991b1b}
.status-online{background:#eff6ff;border:1px solid #93c5fd;color:#1e40af}

/* empty state */
.empty-state{
  text-align:center;padding:2rem 1rem;
  color:var(--text3);font-size:.85rem;
}
.empty-state .ei{font-size:2rem;margin-bottom:.5rem}

/* loading row */
.loading-row{
  text-align:center;padding:1.5rem;
  color:var(--text3);font-size:.82rem;
  display:flex;align-items:center;justify-content:center;gap:.5rem;
}

/* ══════════════════════════════════════
   MODAL OVERLAY
══════════════════════════════════════ */
.modal-overlay{
  display:none;position:fixed;inset:0;z-index:1000;
  background:rgba(0,0,0,.4);backdrop-filter:blur(4px);
  align-items:flex-end;justify-content:center;padding:0;
}
.modal-overlay.open{display:flex}

.modal{
  width:100%;max-width:520px;
  background:var(--surface);
  border-radius:24px 24px 0 0;
  overflow:hidden;position:relative;
  animation:slideUp .28s cubic-bezier(.34,1.1,.64,1);
  max-height:92vh;display:flex;flex-direction:column;
}
@keyframes slideUp{from{transform:translateY(100%);opacity:.5}to{transform:translateY(0);opacity:1}}

.modal::before{content:'';display:block;width:40px;height:4px;border-radius:2px;background:rgba(0,0,0,.15);margin:10px auto 0;flex-shrink:0}

.modal-header{
  padding:.85rem 1.4rem .95rem;
  display:flex;align-items:center;justify-content:space-between;
  border-bottom:1px solid var(--border);flex-shrink:0;
}
.modal-title{
  font-family:'Rajdhani',sans-serif;font-size:1.05rem;font-weight:700;letter-spacing:.08em;
  display:flex;align-items:center;gap:.6rem;
}
.modal-ais  .modal-title{color:var(--ais2)}
.modal-true .modal-title{color:var(--true2)}
.modal-ssh  .modal-title{color:var(--ssh2)}
.modal-mgmt .modal-title{color:var(--ssh2)}

.modal-close{
  width:30px;height:30px;border-radius:50%;border:none;
  background:#f0f4f8;display:flex;align-items:center;justify-content:center;
  cursor:pointer;font-size:.85rem;color:var(--text2);transition:all .2s;
}
.modal-close:hover{background:#e2e8f0;color:var(--text)}

.modal-body{padding:1rem 1.4rem 1.6rem;overflow-y:auto;flex:1}
.modal-body::-webkit-scrollbar{width:4px}
.modal-body::-webkit-scrollbar-thumb{background:rgba(0,0,0,.1);border-radius:2px}

/* ══════════════════════════════════════
   FORM FIELDS
══════════════════════════════════════ */
.sni-badge{
  display:inline-block;font-family:'Share Tech Mono',monospace;
  font-size:.68rem;padding:.22rem .65rem;border-radius:20px;margin-bottom:.9rem;
}
.sni-badge.ais{background:var(--ais-light);border:1px solid var(--ais-bdr);color:var(--ais2)}
.sni-badge.true{background:var(--true-light);border:1px solid var(--true-bdr);color:var(--true2)}
.sni-badge.ssh{background:var(--ssh-light);border:1px solid var(--ssh-bdr);color:var(--ssh2)}

.fgrid{display:grid;grid-template-columns:1fr 1fr;gap:.6rem .8rem}
.fgrid .span2{grid-column:span 2}
.field{display:flex;flex-direction:column;gap:.3rem}

label{font-size:.67rem;font-family:'Share Tech Mono',monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--text3)}
input,select{
  background:#f8fafc;border:1.5px solid var(--border);border-radius:10px;
  padding:.58rem .88rem;color:var(--text);
  font-family:'Kanit',sans-serif;font-size:.88rem;outline:none;
  transition:border-color .2s,box-shadow .2s;width:100%;
}
input:focus,select:focus{background:#fff}
input.ais-focus:focus{border-color:var(--ais);box-shadow:0 0 0 3px rgba(90,158,28,.1)}
input.true-focus:focus{border-color:var(--true);box-shadow:0 0 0 3px rgba(224,16,32,.09)}
input.ssh-focus:focus{border-color:var(--ssh);box-shadow:0 0 0 3px rgba(26,111,168,.1)}
input.mgmt-focus:focus{border-color:var(--purple);box-shadow:0 0 0 3px rgba(139,92,246,.1)}
select option{background:#fff}

.divider{height:1px;background:var(--border);margin:.8rem 0}

.submit-btn{
  width:100%;padding:.83rem;border:none;border-radius:12px;
  font-family:'Rajdhani',sans-serif;font-size:1.02rem;font-weight:700;letter-spacing:.1em;
  cursor:pointer;margin-top:.8rem;transition:all .2s;overflow:hidden;
}
.submit-btn:disabled{opacity:.5;cursor:not-allowed}
.submit-btn.ais-btn{background:linear-gradient(135deg,#4d8a15,var(--ais));color:#fff;box-shadow:0 4px 14px rgba(90,158,28,.3)}
.submit-btn.ais-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(90,158,28,.4);transform:translateY(-1px)}
.submit-btn.true-btn{background:linear-gradient(135deg,#c0030f,var(--true));color:#fff;box-shadow:0 4px 14px rgba(224,16,32,.26)}
.submit-btn.true-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(224,16,32,.36);transform:translateY(-1px)}
.submit-btn.ssh-btn{background:linear-gradient(135deg,#135d94,var(--ssh));color:#fff;box-shadow:0 4px 14px rgba(26,111,168,.26)}
.submit-btn.ssh-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(26,111,168,.36);transform:translateY(-1px)}
.submit-btn.mgmt-btn{background:linear-gradient(135deg,#6d28d9,var(--purple));color:#fff;box-shadow:0 4px 14px rgba(139,92,246,.26)}
.submit-btn.mgmt-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(139,92,246,.36);transform:translateY(-1px)}
.submit-btn.danger-btn{background:linear-gradient(135deg,#b91c1c,var(--red));color:#fff;box-shadow:0 4px 14px rgba(239,68,68,.22)}

.spinner{display:inline-block;width:14px;height:14px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite;vertical-align:middle;margin-right:.4rem}
@keyframes spin{to{transform:rotate(360deg)}}

.alert{display:none;margin-top:.7rem;padding:.68rem .9rem;border-radius:10px;font-size:.8rem;line-height:1.6}
.alert.ok{background:#f0fdf4;border:1px solid #86efac;color:#166534}
.alert.err{background:#fef2f2;border:1px solid #fca5a5;color:#991b1b}
.alert.info{background:#eff6ff;border:1px solid #93c5fd;color:#1e40af}

/* ══════════════════════════════════════
   RESULT CARD
══════════════════════════════════════ */
.result-card{display:none;margin-top:1rem;border-radius:14px;overflow:hidden;border:1.5px solid var(--border);box-shadow:0 2px 10px rgba(0,0,0,.06)}
.result-card.show{display:block}
#ais-result.show{border-color:var(--ais-bdr)}
#true-result.show{border-color:var(--true-bdr)}
#ssh-result.show{border-color:var(--ssh-bdr)}

.result-header{padding:.65rem 1rem;font-family:'Share Tech Mono',monospace;font-size:.72rem;letter-spacing:.1em;display:flex;align-items:center;gap:.5rem;border-bottom:1px solid var(--border)}
.result-header .dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.result-header.ais-r{background:var(--ais-light);color:var(--ais2)}
.result-header.ais-r .dot{background:var(--ais);box-shadow:0 0 5px var(--ais)}
.result-header.true-r{background:var(--true-light);color:var(--true2)}
.result-header.true-r .dot{background:var(--true)}
.result-header.ssh-r{background:var(--ssh-light);color:var(--ssh2)}
.result-header.ssh-r .dot{background:var(--ssh)}

.result-body{padding:.85rem 1rem;background:#fafcfe}
.info-rows{margin-bottom:.8rem}
.info-row{display:flex;justify-content:space-between;align-items:center;padding:.32rem 0;border-bottom:1px solid var(--border);font-size:.8rem}
.info-row:last-child{border-bottom:none}
.info-key{color:var(--text3);font-size:.7rem;font-family:'Share Tech Mono',monospace;letter-spacing:.08em}
.info-val{color:var(--text);text-align:right;word-break:break-all;max-width:62%}
.info-val.pass{font-family:'Share Tech Mono',monospace;color:var(--green);font-weight:600}
.info-val.uuid{font-family:'Share Tech Mono',monospace;font-size:.62rem;color:var(--ssh)}

.link-box{background:#f0f4f8;border-radius:8px;padding:.6rem .8rem;font-family:'Share Tech Mono',monospace;font-size:.62rem;word-break:break-all;line-height:1.7;margin-bottom:.7rem;border:1px solid var(--border);color:var(--text2)}
.link-box.vless-link{border-left:3px solid var(--ais);color:var(--ais2)}
.link-box.npv-link{border-left:3px solid var(--ssh);color:var(--ssh2)}
.link-box.dark-link{border-left:3px solid #9333ea;color:#7e22ce}

.qr-wrap{display:flex;justify-content:center;margin:.6rem 0 .8rem}
.qr-inner{background:#fff;padding:10px;border-radius:10px;display:inline-block;border:1px solid var(--border)}

.copy-row{display:flex;gap:.5rem;flex-wrap:wrap}
.copy-btn{flex:1;min-width:120px;padding:.5rem .7rem;border-radius:9px;border:1.5px solid var(--border);background:#fff;font-family:'Rajdhani',sans-serif;font-size:.85rem;font-weight:700;letter-spacing:.06em;cursor:pointer;transition:all .2s;color:var(--text2)}
.copy-btn.vless{border-color:var(--ais-bdr);color:var(--ais2)}
.copy-btn.vless:hover{background:var(--ais-light)}
.copy-btn.npv{border-color:var(--ssh-bdr);color:var(--ssh2)}
.copy-btn.npv:hover{background:var(--ssh-light)}
.copy-btn.ssh-copy{border-color:var(--ssh-bdr);color:var(--ssh2)}
.copy-btn.ssh-copy:hover{background:var(--ssh-light)}
.copy-btn.copied{opacity:.6;pointer-events:none}

/* ══════════════════════════════════════
   PORT / APP TABS
══════════════════════════════════════ */
.port-tabs{display:flex;gap:.4rem;margin-bottom:.6rem}
.port-tab{flex:1;padding:.48rem;border-radius:9px;font-size:.8rem;cursor:pointer;border:1.5px solid var(--border);background:#f8fafc;color:var(--text2);font-family:'Rajdhani',sans-serif;font-weight:600;transition:all .2s}
.port-tab.active-ssh{border-color:var(--ssh);background:var(--ssh-light);color:var(--ssh2)}
.pro-tab{display:flex;align-items:center;justify-content:center;gap:.4rem;padding:.5rem .6rem}
#ssh-pro-dtac.active-ssh{border-color:var(--ssh);background:var(--ssh-light);color:var(--ssh2)}
#ssh-pro-true.active-ssh{border-color:var(--true);background:var(--true-light);color:var(--true2)}

/* ══════════════════════════════════════
   MGMT MODAL — action rows
══════════════════════════════════════ */
.action-grid{display:grid;grid-template-columns:1fr 1fr;gap:.6rem;margin-top:.8rem}
.action-card{
  background:#f8fafc;border:1.5px solid var(--border);border-radius:12px;
  padding:.85rem .9rem;cursor:pointer;transition:all .2s;text-align:center;
}
.action-card:hover{border-color:var(--ssh);background:var(--ssh-light)}
.action-card.selected{border-color:var(--purple);background:#f5f3ff}
.action-icon{font-size:1.4rem;margin-bottom:.3rem}
.action-name{font-family:'Rajdhani',sans-serif;font-size:.9rem;font-weight:700;color:var(--text)}
.action-desc{font-size:.7rem;color:var(--text3);margin-top:.15rem}

/* user detail panel */
.udetail{
  background:var(--bg);border-radius:12px;padding:.85rem 1rem;
  border:1px solid var(--border);margin-bottom:.9rem;
}
.udetail-row{display:flex;justify-content:space-between;padding:.28rem 0;border-bottom:1px solid var(--border);font-size:.8rem}
.udetail-row:last-child{border-bottom:none}
.dk{color:var(--text3);font-family:'Share Tech Mono',monospace;font-size:.68rem}
.dv{color:var(--text);font-weight:600}
.dv.exp{color:var(--orange)}
.dv.dead{color:var(--red)}
.dv.ok{color:var(--green)}
.dv.online{color:var(--ssh)}

/* ══════════════════════════════════════
   TOAST
══════════════════════════════════════ */
.toast{
  position:fixed;bottom:28px;left:50%;transform:translateX(-50%);
  background:var(--text);color:#fff;
  padding:.6rem 1.5rem;border-radius:24px;
  font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;
  opacity:0;pointer-events:none;z-index:9999;transition:opacity .25s;white-space:nowrap;
  box-shadow:0 4px 20px rgba(0,0,0,.25);
}
.toast.show{opacity:1}

/* ══════════════════════════════════════
   RESPONSIVE
══════════════════════════════════════ */
@media(max-width:600px){
  .fgrid{grid-template-columns:1fr}.fgrid .span2{grid-column:span 1}
  .action-grid{grid-template-columns:1fr 1fr}
  .modal{border-radius:20px 20px 0 0}
}

/* ══════════════════════════════════════
   SERVICE MONITOR
══════════════════════════════════════ */
.svc-grid{display:flex;flex-direction:column;gap:.42rem}
.svc-row{
  display:flex;align-items:center;gap:.65rem;
  border-radius:11px;padding:.52rem .85rem;
  border:1px solid var(--border);background:#f9fbfc;
  transition:all .15s;
}
.svc-row.up  {border-color:#86efac;background:#f0fdf4}
.svc-row.down{border-color:#fca5a5;background:#fef2f2}
.svc-row.warn{border-color:#fed7aa;background:#fffbf5}
.svc-dot{
  width:8px;height:8px;border-radius:50%;flex-shrink:0;
}
.svc-dot.up  {background:#22c55e;box-shadow:0 0 6px rgba(34,197,94,.55);animation:pulse 2s infinite}
.svc-dot.down{background:var(--red)}
.svc-dot.warn{background:var(--orange);animation:pulse 2s infinite}
.svc-icon{font-size:.9rem;flex-shrink:0}
.svc-name{font-family:"Share Tech Mono",monospace;font-size:.75rem;color:var(--text);flex:1;font-weight:600}
.svc-ports{font-family:"Share Tech Mono",monospace;font-size:.63rem;color:var(--text3)}
.svc-chip{
  font-family:"Share Tech Mono",monospace;font-size:.63rem;
  padding:.13rem .5rem;border-radius:20px;flex-shrink:0;font-weight:700;
}
.svc-chip.up  {background:#dcfce7;color:#166534;border:1px solid #86efac}
.svc-chip.down{background:#fee2e2;color:#991b1b;border:1px solid #fca5a5}
.svc-chip.warn{background:#fff7ed;color:#92400e;border:1px solid #fed7aa}
.svc-chip.checking{background:#f1f5f9;color:var(--text3);border:1px solid var(--border)}

/* ══════════════════════════════════════
   HEADER UPGRADE
══════════════════════════════════════ */
.site-header{
  text-align:center;
  padding:2rem 1.5rem 1.6rem;
  background:radial-gradient(ellipse 140% 130% at 50% -10%, #0d1f3c 0%, #060e1e 55%, #020810 100%);
  border-bottom:1px solid rgba(255,255,255,.05);
  position:relative;overflow:hidden;
}
.site-header::before{
  content:"";position:absolute;top:-60px;left:50%;transform:translateX(-50%);
  width:380px;height:200px;
  background:radial-gradient(ellipse,rgba(80,160,20,.18) 0%,transparent 70%);
  pointer-events:none;
}
.site-logo{
  font-family:"Share Tech Mono",monospace;
  font-size:.6rem;letter-spacing:.35em;
  color:rgba(100,200,50,.65);
  margin-bottom:.45rem;
  display:flex;align-items:center;justify-content:center;gap:.7rem;
  position:relative;z-index:1;
}
.site-logo::before,.site-logo::after{
  content:"";display:inline-block;height:1px;width:42px;
  background:linear-gradient(90deg,transparent,rgba(100,200,50,.45));
}
.site-logo::after{background:linear-gradient(90deg,rgba(100,200,50,.45),transparent)}
.site-title{
  font-family:"Rajdhani",sans-serif;font-size:2.4rem;font-weight:700;letter-spacing:.08em;
  color:#eef6ff;position:relative;z-index:1;line-height:1.1;
}
.site-title span{color:#72d124;text-shadow:0 0 22px rgba(100,200,30,.4)}
.site-sub{
  font-size:.72rem;color:rgba(255,255,255,.35);margin-top:.4rem;
  font-family:"Share Tech Mono",monospace;letter-spacing:.07em;
  position:relative;z-index:1;
}
.site-sub .dot{margin:0 .4rem;color:rgba(110,200,50,.45)}

/* ══════════════════════════════════════
   TAB NAV UPGRADE
══════════════════════════════════════ */
.tab-nav{
  display:flex;
  background:#192333;
  border-bottom:1px solid rgba(255,255,255,.07);
  overflow-x:auto;-webkit-overflow-scrolling:touch;
  position:sticky;top:0;z-index:200;
}
.tab-nav::-webkit-scrollbar{display:none}
.tab-btn{
  flex:1;min-width:80px;
  padding:.78rem .5rem;
  border:none;background:transparent;
  font-family:"Kanit",sans-serif;font-size:.78rem;font-weight:600;
  color:rgba(255,255,255,.38);cursor:pointer;
  border-bottom:2px solid transparent;
  transition:all .2s;white-space:nowrap;
}
.tab-btn:hover{color:rgba(255,255,255,.65);background:rgba(255,255,255,.03)}
.tab-btn.active{color:#72d124;border-bottom-color:#72d124;background:rgba(114,209,36,.06)}

/* ══════════════════════════════════════
   STAT CARDS UPGRADE
══════════════════════════════════════ */
.stat-card{
  background:var(--surface);
  border-radius:18px;
  padding:1.1rem 1.15rem;
  border:1px solid var(--border);
  box-shadow:0 2px 14px rgba(0,0,0,.07);
  position:relative;overflow:hidden;transition:box-shadow .2s,transform .2s;
}
.stat-card:hover{box-shadow:0 6px 24px rgba(0,0,0,.11);transform:translateY(-1px)}
.stat-card::after{
  content:"";position:absolute;top:0;right:0;
  width:70px;height:70px;border-radius:0 18px 0 100%;
  background:linear-gradient(135deg,transparent,rgba(0,0,0,.025));
  pointer-events:none;
}

/* refresh btn upgrade */
.refresh-btn{
  border:1px solid var(--border);background:var(--surface);
  border-radius:9px;padding:.32rem .75rem;
  font-size:.74rem;color:var(--text2);cursor:pointer;
  font-family:"Kanit",sans-serif;
  transition:all .2s;display:inline-flex;align-items:center;gap:.3rem;
}
.refresh-btn:hover{background:#f0f4fa;color:var(--text);border-color:#b0bfd0}
.refresh-btn.spin svg{animation:spinR .6s linear infinite}

/* carrier button upgrade */
.carrier-btn{
  width:100%;border:none;background:var(--surface);
  padding:1.05rem 1.2rem;cursor:pointer;
  display:flex;align-items:center;gap:1rem;text-align:left;
  transition:background .15s,transform .1s;
}
.carrier-btn:hover{background:#f6f9ff;transform:none}
.carrier-btn:active{transform:scale(.99)}

/* section label upgrade */
.section-label{
  display:flex;align-items:center;gap:.5rem;
  font-family:"Rajdhani",sans-serif;
  font-size:.88rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
  color:var(--text2);padding:.2rem 0 .75rem;
}

/* modal upgrade */
.modal{
  width:100%;max-width:520px;
  background:var(--surface);
  border-radius:26px 26px 0 0;
  overflow:hidden;position:relative;
  animation:slideUp .26s cubic-bezier(.34,1.1,.64,1);
  max-height:94vh;display:flex;flex-direction:column;
}
.modal::before{
  content:"";display:block;width:42px;height:4px;border-radius:2px;
  background:rgba(0,0,0,.12);margin:11px auto 0;flex-shrink:0;
}
.modal-body{padding:1.1rem 1.4rem 1.8rem;overflow-y:auto;flex:1}

/* submit button upgrade */
.submit-btn{
  width:100%;padding:.88rem;border:none;border-radius:13px;
  font-family:"Rajdhani",sans-serif;font-size:1.05rem;font-weight:700;letter-spacing:.1em;
  cursor:pointer;margin-top:.9rem;transition:all .2s;
  position:relative;overflow:hidden;
}
.submit-btn::after{
  content:"";position:absolute;inset:0;
  background:linear-gradient(180deg,rgba(255,255,255,.12),transparent);
  pointer-events:none;
}
.submit-btn.ais-btn{background:linear-gradient(135deg,#3d7a0e,#5aaa18);color:#fff;box-shadow:0 4px 16px rgba(77,154,14,.32)}
.submit-btn.ais-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(77,154,14,.45);transform:translateY(-1px)}
.submit-btn.true-btn{background:linear-gradient(135deg,#a6000c,#d81020);color:#fff;box-shadow:0 4px 16px rgba(216,14,28,.28)}
.submit-btn.true-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(216,14,28,.4);transform:translateY(-1px)}
.submit-btn.ssh-btn{background:linear-gradient(135deg,#0c4f84,#1668a8);color:#fff;box-shadow:0 4px 16px rgba(21,104,166,.28)}
.submit-btn.ssh-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(21,104,166,.4);transform:translateY(-1px)}
.submit-btn.mgmt-btn{background:linear-gradient(135deg,#5b21b6,#7c3aed);color:#fff;box-shadow:0 4px 16px rgba(124,58,237,.26)}
.submit-btn.danger-btn{background:linear-gradient(135deg,#991b1b,#dc2626);color:#fff;box-shadow:0 4px 16px rgba(220,38,38,.22)}

/* card group upgrade */
.card-group{
  background:var(--surface);border-radius:20px;
  box-shadow:0 2px 14px rgba(0,0,0,.07);overflow:hidden;
  border:1px solid var(--border);
}

/* online badge upgrade */
.online-badge{
  display:inline-flex;align-items:center;gap:.38rem;
  background:#f0fdf4;border:1px solid #86efac;
  color:#15803d;padding:.26rem .75rem;border-radius:20px;
  font-size:.7rem;font-family:"Share Tech Mono",monospace;font-weight:600;
}

/* toast upgrade */
.toast{
  position:fixed;bottom:30px;left:50%;transform:translateX(-50%) scale(.95);
  background:#1a2332;color:#fff;
  padding:.65rem 1.6rem;border-radius:26px;
  font-family:"Rajdhani",sans-serif;font-weight:700;font-size:.9rem;
  opacity:0;pointer-events:none;z-index:9999;
  transition:opacity .25s,transform .25s;white-space:nowrap;
  box-shadow:0 8px 24px rgba(0,0,0,.22);
}
.toast.show{opacity:1;transform:translateX(-50%) scale(1)}

/* mgmt panel upgrade */
.mgmt-panel{
  background:var(--surface);border-radius:20px;
  border:1px solid var(--border);box-shadow:0 2px 14px rgba(0,0,0,.07);
  overflow:hidden;
}

/* SNI badge upgrade */
.sni-badge{
  display:inline-flex;align-items:center;gap:.4rem;
  font-family:"Share Tech Mono",monospace;
  font-size:.68rem;padding:.25rem .75rem;border-radius:20px;margin-bottom:.95rem;
}
.sni-badge.ais{background:#edf7e3;border:1px solid #b5e08a;color:#316808}
.sni-badge.true{background:#fff0f0;border:1px solid #f5909a;color:#a6000c}
.sni-badge.ssh{background:#e6f3fc;border:1px solid #82c0ee;color:#0c4f84}

/* input upgrade */
input,select{
  background:#f6f9fc;border:1.5px solid #d8e2ee;border-radius:11px;
  padding:.6rem .9rem;color:var(--text);
  font-family:"Kanit",sans-serif;font-size:.88rem;outline:none;
  transition:border-color .2s,box-shadow .2s,background .2s;width:100%;
}
input:focus,select:focus{background:#fff}
input.ais-focus:focus{border-color:#4d9a0e;box-shadow:0 0 0 3px rgba(77,154,14,.1)}
input.true-focus:focus{border-color:#d80e1c;box-shadow:0 0 0 3px rgba(216,14,28,.09)}
input.ssh-focus:focus{border-color:#1568a6;box-shadow:0 0 0 3px rgba(21,104,166,.1)}
input.mgmt-focus:focus{border-color:#7c3aed;box-shadow:0 0 0 3px rgba(124,58,237,.1)}

/* link-box upgrade */
.link-box{
  background:#f0f5fb;border-radius:10px;padding:.7rem .9rem;
  font-family:"Share Tech Mono",monospace;font-size:.62rem;
  word-break:break-all;line-height:1.75;margin-bottom:.75rem;
  border:1px solid #dde3ec;color:var(--text2);
}
.link-box.vless-link{border-left:3px solid #4d9a0e;color:#316808}
.link-box.npv-link{border-left:3px solid #1568a6;color:#0c4f84}
.link-box.dark-link{border-left:3px solid #7c3aed;color:#5b21b6}

/* copy buttons upgrade */
.copy-btn{
  flex:1;min-width:110px;padding:.52rem .7rem;
  border-radius:10px;border:1.5px solid var(--border);
  background:#fff;font-family:"Rajdhani",sans-serif;font-size:.85rem;
  font-weight:700;letter-spacing:.06em;cursor:pointer;
  transition:all .18s;color:var(--text2);
}
.copy-btn.vless{border-color:#b5e08a;color:#316808}
.copy-btn.vless:hover{background:#edf7e3;border-color:#4d9a0e}
.copy-btn.npv{border-color:#82c0ee;color:#0c4f84}
.copy-btn.npv:hover{background:#e6f3fc;border-color:#1568a6}
.copy-btn.ssh-copy{border-color:#82c0ee;color:#0c4f84}
.copy-btn.ssh-copy:hover{background:#e6f3fc;border-color:#1568a6}

/* port tabs upgrade */
.port-tab{
  flex:1;padding:.5rem;border-radius:10px;font-size:.8rem;cursor:pointer;
  border:1.5px solid #d8e2ee;background:#f6f9fc;color:var(--text2);
  font-family:"Rajdhani",sans-serif;font-weight:600;transition:all .18s;
}
.port-tab.active-ssh{border-color:#1568a6;background:#e6f3fc;color:#0c4f84}

/* action card upgrade */
.action-card{
  background:#f6f9fc;border:1.5px solid #d8e2ee;border-radius:14px;
  padding:.9rem .9rem;cursor:pointer;transition:all .18s;text-align:center;
}
.action-card:hover{border-color:#1568a6;background:#e6f3fc;transform:translateY(-1px)}
.action-card.selected{border-color:#7c3aed;background:#f5f3ff;box-shadow:0 0 0 3px rgba(124,58,237,.08)}

/* result card upgrade */
.result-card{
  display:none;margin-top:1.1rem;border-radius:16px;overflow:hidden;
  border:1.5px solid var(--border);box-shadow:0 4px 16px rgba(0,0,0,.07);
}
.result-card.show{display:block}

/* bg upgrade */
:root { --bg: #ebeff6; }
.main{max-width:520px;margin:0 auto;padding:1.5rem 1rem 4rem;display:flex;flex-direction:column;gap:1.3rem}


/* ══════════════════════════════════════
   ONLINE USER ROWS — data bar style
══════════════════════════════════════ */
.online-user-row{
  padding:.85rem 1.2rem;border-bottom:1px solid var(--border);
  display:flex;align-items:flex-start;gap:.9rem;
  transition:background .15s;
}
.online-user-row:last-child{border-bottom:none}
.online-user-row:hover{background:#f6faff}
.online-avatar{
  width:40px;height:40px;border-radius:12px;
  display:flex;align-items:center;justify-content:center;
  font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.95rem;
  flex-shrink:0;border:1px solid;
}
.online-info{flex:1;min-width:0}
.online-name{
  display:flex;align-items:center;gap:.5rem;
  font-weight:600;font-size:.88rem;color:var(--text);margin-bottom:.35rem;
  flex-wrap:wrap;
}
.online-port-chip{
  font-family:'Share Tech Mono',monospace;font-size:.6rem;
  background:#eff6ff;border:1px solid #93c5fd;color:#1e40af;
  padding:.1rem .45rem;border-radius:20px;flex-shrink:0;
}
.online-data-row{display:flex;align-items:center;gap:.55rem;margin-bottom:.28rem}
.online-data-bar-wrap{
  flex:1;height:7px;background:#e8eef5;border-radius:4px;overflow:hidden;
}
.online-data-bar{
  height:100%;border-radius:4px;
  transition:width .8s cubic-bezier(.4,0,.2,1);
}
.online-data-label{
  font-family:'Share Tech Mono',monospace;font-size:.62rem;
  color:var(--text3);white-space:nowrap;flex-shrink:0;
}
.online-exp{font-size:.68rem;font-family:'Share Tech Mono',monospace;}
.online-exp.exp-ok  {color:#16a34a}
.online-exp.exp-warn{color:#ea6c10}
.online-exp.exp-dead{color:#dc2626}
.online-live-dot{
  width:10px;height:10px;border-radius:50%;flex-shrink:0;margin-top:4px;
  background:#22c55e;
  box-shadow:0 0 0 3px rgba(34,197,94,.2);
  animation:livePulse 1.8s ease-in-out infinite;
}
@keyframes livePulse{
  0%,100%{box-shadow:0 0 0 3px rgba(34,197,94,.2)}
  50%{box-shadow:0 0 0 6px rgba(34,197,94,.05)}
}

/* ══════════════════════════════════════
   RGB STAT CARD ACCENTS
══════════════════════════════════════ */
.stat-card{
  background:var(--surface);border-radius:18px;
  padding:1.1rem 1.15rem;border:1px solid var(--border);
  box-shadow:0 2px 14px rgba(0,0,0,.07);
  position:relative;overflow:hidden;
  transition:box-shadow .2s,transform .2s;
}
.stat-card:hover{
  box-shadow:0 6px 28px rgba(0,0,0,.11);
  transform:translateY(-1px);
}
/* เส้น RGB บนสุด card */
.stat-card::before{
  content:'';position:absolute;top:0;left:0;right:0;height:2px;
  background:linear-gradient(90deg,#7ee8fa,#a78bfa,#80ff72,#f9a8d4,#7ee8fa);
  background-size:300% auto;
  animation:rgbShift 6s linear infinite;
  opacity:0;transition:opacity .3s;
}
.stat-card:hover::before{opacity:1}

/* RGB glow ใน section label */
.section-label .lbl-text{font-size:.9rem;font-weight:700;letter-spacing:.16em}

/* ══════════════════════════════════════
   SNOWFLAKE CSS ANIMATION (fallback)
══════════════════════════════════════ */
@keyframes snowFall{
  0%  {transform:translateY(-20px) rotate(0deg);opacity:0}
  10% {opacity:.8}
  90% {opacity:.6}
  100%{transform:translateY(160px) rotate(360deg);opacity:0}
}

</style>
</head>
<body>

<!-- ─── HEADER ─── -->
<div class="site-header">
  <canvas id="snow-canvas"></canvas>
  <div class="site-logo">CHAIYA V2RAY PRO MAX</div>
  <div class="site-title">USER <span class="rgb-word">CREATOR</span></div>
  <div class="site-sub">สร้างบัญชี VLESS <span class="dot">·</span> SSH-WS ผ่านหน้าเว็บ <span class="dot">·</span> v8</div>
  <button onclick="doLogout()" style="position:absolute;top:1rem;right:1rem;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.12);color:rgba(255,255,255,.45);border-radius:8px;padding:.3rem .75rem;font-family:'Share Tech Mono',monospace;font-size:.62rem;cursor:pointer;z-index:10;transition:all .2s" onmouseover="this.style.color='rgba(248,113,113,.8)'" onmouseout="this.style.color='rgba(255,255,255,.45)'">⎋ ออกจากระบบ</button>
</div>

<!-- ─── TAB NAV ─── -->
<nav class="tab-nav">
  <button class="tab-btn active" onclick="switchTab('dash')">📊 แดชบอร์ด</button>
  <button class="tab-btn" onclick="switchTab('create')">➕ สร้างยูส</button>
  <button class="tab-btn" onclick="switchTab('manage')">🔧 จัดการยูส</button>
  <button class="tab-btn" onclick="switchTab('online')">🟢 ออนไลน์</button>
  <button class="tab-btn" onclick="switchTab('ban')">🚫 ปลดแบน</button>
</nav>

<!-- ══════════════════════════════════════
     TAB: DASHBOARD
══════════════════════════════════════ -->
<div class="tab-panel active" id="tab-dash">
<div class="main">

  <!-- Refresh row -->
  <div style="display:flex;align-items:center;justify-content:space-between">
    <span style="font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;color:var(--text2);letter-spacing:.1em">SYSTEM MONITOR</span>
    <button class="refresh-btn" id="refresh-btn" onclick="loadStats()">
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:4px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
      รีเฟรช
    </button>
  </div>

  <!-- Stats Grid -->
  <div class="stats-grid">

    <!-- CPU -->
    <div class="stat-card">
      <div class="stat-label">⚡ CPU Usage</div>
      <div class="ring-wrap">
        <svg class="ring-svg" width="64" height="64" viewBox="0 0 64 64">
          <circle class="ring-track" cx="32" cy="32" r="26"/>
          <circle class="ring-fill" id="cpu-ring" cx="32" cy="32" r="26"
            stroke="#5a9e1c"
            stroke-dasharray="163.4"
            stroke-dashoffset="163.4"
            transform="rotate(-90 32 32)"/>
        </svg>
        <div class="ring-info">
          <div class="stat-value" id="cpu-val">--<span class="stat-unit">%</span></div>
          <div class="stat-sub" id="cpu-cores">-- cores</div>
        </div>
      </div>
      <div class="bar-gauge"><div class="bar-fill" id="cpu-bar" style="width:0%;background:linear-gradient(90deg,#5a9e1c,#8dc63f)"></div></div>
    </div>

    <!-- RAM -->
    <div class="stat-card">
      <div class="stat-label">🧠 RAM Usage</div>
      <div class="ring-wrap">
        <svg class="ring-svg" width="64" height="64" viewBox="0 0 64 64">
          <circle class="ring-track" cx="32" cy="32" r="26"/>
          <circle class="ring-fill" id="ram-ring" cx="32" cy="32" r="26"
            stroke="#1a6fa8"
            stroke-dasharray="163.4"
            stroke-dashoffset="163.4"
            transform="rotate(-90 32 32)"/>
        </svg>
        <div class="ring-info">
          <div class="stat-value" id="ram-val">--<span class="stat-unit">%</span></div>
          <div class="stat-sub" id="ram-detail">-- / -- GB</div>
        </div>
      </div>
      <div class="bar-gauge"><div class="bar-fill" id="ram-bar" style="width:0%;background:linear-gradient(90deg,#1a6fa8,#40b0ff)"></div></div>
    </div>

    <!-- Disk -->
    <div class="stat-card">
      <div class="stat-label">💾 Disk Usage</div>
      <div class="stat-value" id="disk-val">--<span class="stat-unit">%</span></div>
      <div class="stat-sub" id="disk-detail">-- / -- GB</div>
      <div class="bar-gauge"><div class="bar-fill" id="disk-bar" style="width:0%;background:linear-gradient(90deg,#f97316,#fb923c)"></div></div>
    </div>

    <!-- Uptime -->
    <div class="stat-card">
      <div class="stat-label">⏱ Uptime</div>
      <div class="stat-value" style="font-size:1.3rem" id="uptime-val">--</div>
      <div class="stat-sub" id="uptime-sub">กำลังโหลด...</div>
      <div style="margin-top:.5rem" id="load-avg-chips"></div>
    </div>

    <!-- Network -->
    <div class="stat-card wide">
      <div class="stat-label" style="margin-bottom:.6rem">🌐 Network I/O</div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:.6rem">
        <div>
          <div style="font-size:.7rem;color:var(--text3);font-family:'Share Tech Mono',monospace">↑ Upload</div>
          <div class="stat-value" style="font-size:1.3rem" id="net-up">--</div>
          <div class="stat-sub" id="net-up-total">total: --</div>
        </div>
        <div>
          <div style="font-size:.7rem;color:var(--text3);font-family:'Share Tech Mono',monospace">↓ Download</div>
          <div class="stat-value" style="font-size:1.3rem" id="net-down">--</div>
          <div class="stat-sub" id="net-down-total">total: --</div>
        </div>
      </div>
    </div>

    <!-- x-ui status -->
    <div class="stat-card wide">
      <div class="stat-label" style="margin-bottom:.7rem">📡 x-ui Panel Status</div>
      <div style="display:flex;align-items:center;gap:.8rem;flex-wrap:wrap">
        <div id="xui-status-badge">
          <span class="chip">ตรวจสอบ...</span>
        </div>
        <div style="flex:1">
          <div style="font-size:.78rem;color:var(--text2)" id="xui-ver">เวอร์ชัน: --</div>
          <div style="font-size:.72rem;color:var(--text3);font-family:'Share Tech Mono',monospace" id="xui-traffic">Traffic inbounds: --</div>
        </div>
      </div>
    </div>


    <!-- Service Monitor -->
    <div class="stat-card wide" id="svc-card">
      <div class="stat-label" style="margin-bottom:.8rem;display:flex;align-items:center;justify-content:space-between;flex-wrap:nowrap">
        <span>🛠 SERVICE MONITOR</span>
        <button class="refresh-btn" id="svc-refresh-btn" onclick="loadServiceStatus()" style="padding:.2rem .65rem;font-size:.7rem">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
          เช็คสถานะ
        </button>
      </div>
      <div id="svc-list">
        <div class="loading-row" style="padding:.5rem 0"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--ssh)"></span>กำลังตรวจสอบ...</div>
      </div>
    </div>


    <!-- Service Monitor -->
    <div class="stat-card wide">
      <div class="stat-label" style="display:flex;align-items:center;justify-content:space-between;margin-bottom:.85rem">
        <span>🛠 SERVICE MONITOR</span>
        <button class="refresh-btn" id="svc-refresh-btn" onclick="loadServiceStatus()">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
          เช็คสถานะ
        </button>
      </div>
      <div id="svc-list">
        <div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--ssh)"></span>กำลังตรวจสอบ...</div>
      </div>
    </div>

  </div><!-- /stats-grid -->

  <div style="font-size:.72rem;color:var(--text3);text-align:center;font-family:'Share Tech Mono',monospace" id="last-update">อัพเดทล่าสุด: --</div>
</div>
</div>

<!-- ══════════════════════════════════════
     TAB: CREATE
══════════════════════════════════════ -->
<div class="tab-panel" id="tab-create">
<div class="main">
  <!-- VLESS Section -->
  <div>
    <div class="section-label"><span>📡</span><span class="lbl-text">ระบบ 3X-UI VLESS</span></div>
    <div class="card-group">
      <button class="carrier-btn btn-ais" onclick="openModal('ais')">
        <div class="btn-logo logo-ais">
          <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/4/4e/AIS_Logo.svg/200px-AIS_Logo.svg.png" alt="AIS" style="width:42px;height:42px;object-fit:contain" onerror="this.style.display='none';this.nextElementSibling.style.display='block'">
          <span style="display:none;color:#5a9e1c;font-family:'Rajdhani',sans-serif;font-weight:900;font-size:1.1rem">AIS</span>
        </div>
        <div class="btn-info">
          <span class="btn-name">AIS — กันรั่ว</span>
          <span class="btn-desc">VLESS · Port 8080 · WS · cj-ebb.speedtest.net</span>
        </div>
        <span class="btn-arrow">›</span>
      </button>
      <button class="carrier-btn btn-true" onclick="openModal('true')">
        <div class="btn-logo logo-true">
          <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/True_Corporation_Logo.svg/200px-True_Corporation_Logo.svg.png" alt="TRUE" style="width:44px;height:44px;object-fit:contain;filter:brightness(0) invert(1)" onerror="this.style.display='none';this.nextElementSibling.style.display='block'">
          <span style="display:none;color:#fff;font-family:Arial,sans-serif;font-weight:900;font-size:1rem">true</span>
        </div>
        <div class="btn-info">
          <span class="btn-name">TRUE — VDO</span>
          <span class="btn-desc">VLESS · Port 8880 · WS · true-internet.zoom.xyz.services</span>
        </div>
        <span class="btn-arrow">›</span>
      </button>
    </div>
  </div>
  <!-- SSH Section -->
  <div>
    <div class="section-label"><span>🔑</span><span class="lbl-text">ระบบ SSH WEBSOCKET</span></div>
    <div class="card-group">
      <button class="carrier-btn btn-ssh" onclick="openModal('ssh')">
        <div class="btn-logo logo-ssh">
          <svg width="30" height="30" viewBox="0 0 34 34" fill="none">
            <rect x="2" y="4" width="30" height="22" rx="4" fill="none" stroke="#90caf0" stroke-width="2"/>
            <rect x="2" y="4" width="30" height="6" rx="4" fill="rgba(255,255,255,.2)"/>
            <text x="6" y="20" font-family="monospace" font-weight="700" font-size="10" fill="#fff">SSH&gt;_</text>
            <line x1="10" y1="26" x2="10" y2="30" stroke="#90caf0" stroke-width="2"/>
            <line x1="24" y1="26" x2="24" y2="30" stroke="#90caf0" stroke-width="2"/>
            <line x1="6" y1="30" x2="28" y2="30" stroke="#90caf0" stroke-width="2"/>
          </svg>
        </div>
        <div class="btn-info">
          <span class="btn-name">SSH — WS Tunnel</span>
          <span class="btn-desc">SSH · Port 80 · Dropbear 143/109 · NpvTunnel / DarkTunnel</span>
        </div>
        <span class="btn-arrow">›</span>
      </button>
    </div>
  </div>
</div>
</div>

<!-- ══════════════════════════════════════
     TAB: MANAGE
══════════════════════════════════════ -->
<div class="tab-panel" id="tab-manage">
<div class="main">
  <!-- Type selector buttons -->
  <div style="display:flex;gap:.7rem;margin-bottom:1rem">
    <button id="mgmt-btn-vless" onclick="switchMgmtType('vless')"
      style="flex:1;padding:.75rem;border-radius:12px;border:2px solid var(--green);background:var(--green);color:#001a00;font-family:'Orbitron',sans-serif;font-size:.78rem;font-weight:700;letter-spacing:.08em;cursor:pointer;transition:all .2s">
      📡 VLESS
    </button>
    <button id="mgmt-btn-ssh" onclick="switchMgmtType('ssh')"
      style="flex:1;padding:.75rem;border-radius:12px;border:2px solid var(--ssh);background:transparent;color:var(--ssh);font-family:'Orbitron',sans-serif;font-size:.78rem;font-weight:700;letter-spacing:.08em;cursor:pointer;transition:all .2s">
      🔐 SSH-WS
    </button>
  </div>

  <!-- VLESS Panel -->
  <div id="mgmt-panel-vless" class="mgmt-panel">
    <div class="mgmt-header">
      <div class="mgmt-title">🔧 จัดการยูสเซอร์ VLESS</div>
      <button class="refresh-btn" onclick="loadUserList()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        โหลด
      </button>
    </div>
    <div class="search-bar">
      <input type="text" id="search-input" placeholder="🔍 ค้นหา username..." oninput="filterUsers(this.value)">
    </div>
    <div class="user-list" id="user-list">
      <div class="empty-state">
        <div class="ei">📋</div>
        <div>กดปุ่ม "โหลด" เพื่อดึงข้อมูลยูสเซอร์</div>
      </div>
    </div>
  </div>

  <!-- SSH-WS Panel -->
  <div id="mgmt-panel-ssh" class="mgmt-panel" style="display:none">
    <div class="mgmt-header">
      <div class="mgmt-title">🔐 จัดการยูสเซอร์ SSH-WS</div>
      <button class="refresh-btn" onclick="loadSSHUserList()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        โหลด
      </button>
    </div>
    <div class="search-bar">
      <input type="text" id="ssh-search-input" placeholder="🔍 ค้นหา username..." oninput="filterSSHUsers(this.value)">
    </div>
    <div class="user-list" id="ssh-user-list">
      <div class="empty-state">
        <div class="ei">📋</div>
        <div>กดปุ่ม "โหลด" เพื่อดึงข้อมูล SSH Users</div>
      </div>
    </div>
  </div>
</div>
</div>

<!-- ══════════════════════════════════════
     TAB: ONLINE (v2 — VLESS + SSH รวมกัน)
══════════════════════════════════════ -->
<div class="tab-panel" id="tab-online">
<div class="main">
  <div class="mgmt-panel">
    <div class="mgmt-header">
      <div class="mgmt-title">🟢 ยูสเซอร์ออนไลน์ตอนนี้</div>
      <button class="refresh-btn" id="online-refresh" onclick="loadOnlineUsers()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        รีเฟรช
      </button>
    </div>
    <div style="padding:.65rem 1.2rem;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:.5rem">
      <div style="display:flex;align-items:center;gap:.55rem">
        <span id="online-count-badge" class="online-badge"><span class="online-dot"></span><span id="online-count">0</span> ออนไลน์</span>
        <span style="font-family:'Share Tech Mono',monospace;font-size:.6rem;background:#eff6ff;border:1px solid #93c5fd;color:#1e40af;padding:.15rem .5rem;border-radius:20px" id="online-vless-badge">VLESS 0</span>
        <span style="font-family:'Share Tech Mono',monospace;font-size:.6rem;background:#f0fdf4;border:1px solid #86efac;color:#166534;padding:.15rem .5rem;border-radius:20px" id="online-ssh-badge">SSH 0</span>
      </div>
      <span style="font-size:.72rem;color:var(--text3);font-family:'Share Tech Mono',monospace" id="online-time">--</span>
    </div>
    <div class="user-list" id="online-list">
      <div class="empty-state">
        <div class="ei">😴</div>
        <div>ไม่มียูสออนไลน์ตอนนี้</div>
      </div>
    </div>
  </div>
</div>
</div>

<!-- ══════════════════════════════════════
     TAB: BAN
══════════════════════════════════════ -->
<div class="tab-panel" id="tab-ban">
<div class="main">
  <div class="mgmt-panel">
    <div class="mgmt-header">
      <div class="mgmt-title">🚫 ระบบปลดแบน</div>
      <button class="refresh-btn" id="ban-refresh" onclick="loadBanList()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        รีเฟรช
      </button>
    </div>

    <!-- คำอธิบาย -->
    <div style="padding:.75rem 1.2rem;border-bottom:1px solid var(--border);background:#fffbeb;display:flex;align-items:flex-start;gap:.6rem">
      <span style="font-size:1rem;flex-shrink:0">⚠️</span>
      <div style="font-size:.75rem;color:#92400e;line-height:1.55">
        แบนอัตโนมัติ <strong>2 ชั่วโมง</strong> — ลูกค้าที่ถูกแบนจะไม่สามารถเชื่อมต่อได้ กดปลดแบนเพื่อให้ใช้งานได้ทันที
      </div>
    </div>

    <!-- แบนด้วยตนเอง -->
    <div style="padding:.9rem 1.2rem;border-bottom:1px solid var(--border)">
      <div style="font-family:'Rajdhani',sans-serif;font-size:.8rem;font-weight:700;letter-spacing:.1em;color:var(--text2);margin-bottom:.55rem">🔨 แบนด้วยตนเอง (SSH-WS)</div>
      <div style="display:flex;gap:.5rem">
        <input type="text" id="ban-manual-user" placeholder="username ที่ต้องการแบน" style="flex:1;font-size:.82rem">
        <select id="ban-manual-hours" style="width:100px;font-size:.82rem">
          <option value="1">1 ชั่วโมง</option>
          <option value="2" selected>2 ชั่วโมง</option>
          <option value="6">6 ชั่วโมง</option>
          <option value="24">24 ชั่วโมง</option>
        </select>
        <button onclick="doBanUser()" style="padding:.52rem .9rem;border-radius:10px;border:none;background:linear-gradient(135deg,#991b1b,#dc2626);color:#fff;font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.82rem;cursor:pointer;white-space:nowrap;box-shadow:0 3px 10px rgba(220,38,38,.25)">แบน</button>
      </div>
      <div id="ban-manual-alert" style="display:none;margin-top:.5rem;font-size:.78rem;padding:.4rem .75rem;border-radius:8px"></div>
    </div>

    <!-- รายชื่อที่ถูกแบน -->
    <div style="padding:.7rem 1.2rem .5rem;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.55rem">
      <span style="font-family:'Rajdhani',sans-serif;font-size:.82rem;font-weight:700;color:var(--text2);letter-spacing:.08em">รายชื่อที่ถูกแบน</span>
      <span style="font-family:'Share Tech Mono',monospace;font-size:.6rem;background:#fef2f2;border:1px solid #fca5a5;color:#991b1b;padding:.12rem .5rem;border-radius:20px" id="ban-count-badge">0 คน</span>
    </div>
    <div class="user-list" id="ban-list">
      <div class="empty-state">
        <div class="ei">✅</div>
        <div>ไม่มีใครถูกแบนตอนนี้</div>
      </div>
    </div>
  </div>

  <!-- VLESS Ban section -->
  <div class="mgmt-panel" style="margin-top:.2rem">
    <div class="mgmt-header">
      <div class="mgmt-title">📡 ปลดแบน VLESS (x-ui)</div>
      <button class="refresh-btn" onclick="loadVlessBanList()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        โหลด
      </button>
    </div>
    <div class="user-list" id="vless-ban-list">
      <div class="empty-state">
        <div class="ei">📡</div>
        <div>กดโหลดเพื่อดูรายชื่อ VLESS</div>
      </div>
    </div>
  </div>
</div>
</div>

<!-- ══════════════════════════════════════
     MODAL: AIS CREATE
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-ais">
  <div class="modal modal-ais">
    <div class="modal-header">
      <span class="modal-title">
        <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/4/4e/AIS_Logo.svg/200px-AIS_Logo.svg.png" style="height:20px;width:auto;object-fit:contain" onerror="this.style.display='none'">
        AIS — กันรั่ว
      </span>
      <button class="modal-close" onclick="closeModal('ais')">✕</button>
    </div>
    <div class="modal-body">
      <div class="sni-badge ais">📡 Port 8080 · SNI: cj-ebb.speedtest.net · VLESS-WS</div>
      <div class="fgrid">
        <div class="field span2"><label>👤 Username</label><input type="text" id="ais-user" placeholder="chaiya01" class="ais-focus" oninput="syncField('ais-user','ais-email')"></div>
        <div class="field"><label>📅 วันใช้งาน</label><input type="number" id="ais-days" value="30" min="1" class="ais-focus"></div>
        <div class="field"><label>📦 Data (GB, 0=∞)</label><input type="number" id="ais-data" value="0" min="0" class="ais-focus"></div>
        <div class="field"><label>📱 IP Limit</label><input type="number" id="ais-iplimit" value="2" min="1" class="ais-focus"></div>
        <div class="field span2"><label>🌐 Email (Client ID)</label><input type="text" id="ais-email" placeholder="chaiya01" class="ais-focus"></div>
        <div class="field span2"><label>🔒 SNI (Host Header)</label><input type="text" id="ais-sni" value="cj-ebb.speedtest.net" class="ais-focus"></div>
      </div>
      <button class="submit-btn ais-btn" id="ais-submit" onclick="createVless('ais')">⚡ สร้าง AIS Account</button>
      <div class="alert" id="ais-alert"></div>
      <div class="result-card" id="ais-result">
        <div class="result-header ais-r"><span class="dot"></span>✅ สร้างสำเร็จ — AIS VLESS</div>
        <div class="result-body">
          <div class="info-rows" id="ais-info"></div>
          <div class="qr-wrap"><div class="qr-inner" id="ais-qr"></div></div>
          <div class="link-box vless-link" id="ais-vless-link"></div>
          <div class="copy-row">
            <button class="copy-btn vless" onclick="copyText('ais-vless-link','ais-copy-vless')" id="ais-copy-vless">⎘ VLESS Link</button>
            <button class="copy-btn npv" onclick="copyNpvDirect('ais')" id="ais-copy-npv">📥 NPV Import</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════
     MODAL: TRUE CREATE
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-true">
  <div class="modal modal-true">
    <div class="modal-header">
      <span class="modal-title">
        <span style="background:#c8040d;border-radius:5px;padding:1px 6px;font-size:.82rem;color:#fff;font-family:Arial,sans-serif;font-weight:900">true</span>
        TRUE — VDO
      </span>
      <button class="modal-close" onclick="closeModal('true')">✕</button>
    </div>
    <div class="modal-body">
      <div class="sni-badge true">📡 Port 8880 · SNI: true-internet.zoom.xyz.services · VLESS-WS</div>
      <div class="fgrid">
        <div class="field span2"><label>👤 Username</label><input type="text" id="true-user" placeholder="chaiya01" class="true-focus" oninput="syncField('true-user','true-email')"></div>
        <div class="field"><label>📅 วันใช้งาน</label><input type="number" id="true-days" value="30" min="1" class="true-focus"></div>
        <div class="field"><label>📦 Data (GB, 0=∞)</label><input type="number" id="true-data" value="0" min="0" class="true-focus"></div>
        <div class="field"><label>📱 IP Limit</label><input type="number" id="true-iplimit" value="2" min="1" class="true-focus"></div>
        <div class="field span2"><label>🌐 Email (Client ID)</label><input type="text" id="true-email" placeholder="chaiya01" class="true-focus"></div>
        <div class="field span2"><label>🔒 SNI (Host Header)</label><input type="text" id="true-sni" value="true-internet.zoom.xyz.services" class="true-focus"></div>
      </div>
      <button class="submit-btn true-btn" id="true-submit" onclick="createVless('true')">⚡ สร้าง TRUE Account</button>
      <div class="alert" id="true-alert"></div>
      <div class="result-card" id="true-result">
        <div class="result-header true-r"><span class="dot"></span>✅ สร้างสำเร็จ — TRUE VLESS</div>
        <div class="result-body">
          <div class="info-rows" id="true-info"></div>
          <div class="qr-wrap"><div class="qr-inner" id="true-qr"></div></div>
          <div class="link-box vless-link" id="true-vless-link"></div>
          <div class="copy-row">
            <button class="copy-btn vless" onclick="copyText('true-vless-link','true-copy-vless')" id="true-copy-vless">⎘ VLESS Link</button>
            <button class="copy-btn npv" onclick="copyNpvDirect('true')" id="true-copy-npv">📥 NPV Import</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════
     MODAL: SSH CREATE
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-ssh">
  <div class="modal modal-ssh">
    <div class="modal-header">
      <span class="modal-title">🔐 SSH WebSocket</span>
      <button class="modal-close" onclick="closeModal('ssh')">✕</button>
    </div>
    <div class="modal-body">
      <div class="sni-badge ssh">🔑 Dropbear 143/109 · WS Port 80 · NpvTunnel / DarkTunnel</div>
      <div class="field" style="margin-bottom:.8rem">
        <label>🔌 WS Port</label>
        <div class="port-tabs">
          <button class="port-tab active-ssh" id="ssh-tab-80" onclick="sshSelPort(80)">Port 80 — HTTP-WS</button>
          <button class="port-tab" id="ssh-tab-443" onclick="sshSelPort(443)">Port 443 — WSS 🔒</button>
        </div>
      </div>
      <div class="fgrid">
        <div class="field span2"><label>👤 Username</label><input type="text" id="ssh-user" placeholder="chaiya01" class="ssh-focus"></div>
        <div class="field"><label>🔑 Password</label><input type="text" id="ssh-pass" placeholder="pass1234" class="ssh-focus"></div>
        <div class="field"><label>📅 วันใช้งาน</label><input type="number" id="ssh-days" value="30" min="1" class="ssh-focus"></div>
        <div class="field"><label>📱 IP Limit</label><input type="number" id="ssh-iplimit" value="2" min="1" class="ssh-focus"></div>
        <div class="field span2" style="display:none" id="ssh-sni-field"><label>🌐 SNI / Host</label><input type="text" id="ssh-sni" placeholder="your-domain.com" class="ssh-focus"></div>
      </div>
      <div class="divider"></div>
      <div style="margin-bottom:.6rem">
        <label style="margin-bottom:.4rem;display:block">📱 แอพ Import Link</label>
        <div class="port-tabs">
          <button class="port-tab active-ssh" id="ssh-app-npv" onclick="sshSelApp('npv')">NpvTunnel</button>
          <button class="port-tab" id="ssh-app-dark" onclick="sshSelApp('dark')">DarkTunnel</button>
        </div>
      </div>
      <div style="margin-bottom:.8rem">
        <label style="margin-bottom:.4rem;display:block">🌐 Operator / Payload</label>
        <div class="port-tabs">
          <button class="port-tab active-ssh pro-tab" id="ssh-pro-dtac" onclick="sshSelPro('dtac')">DTAC GAMING</button>
          <button class="port-tab pro-tab" id="ssh-pro-true" onclick="sshSelPro('true')">TRUE TWITTER</button>
        </div>
      </div>
      <button class="submit-btn ssh-btn" id="ssh-submit" onclick="createSSH()">⚡ สร้าง SSH Account</button>
      <div class="alert" id="ssh-alert"></div>
      <div class="result-card" id="ssh-result">
        <div class="result-header ssh-r"><span class="dot"></span>✅ สร้างสำเร็จ — SSH WS</div>
        <div class="result-body">
          <div class="info-rows" id="ssh-info"></div>
          <div class="link-box npv-link" id="ssh-import-link" style="word-break:break-all"></div>
          <div class="copy-row">
            <button class="copy-btn ssh-copy" onclick="copyEl('ssh-import-link','ssh-copy-import')" id="ssh-copy-import">⎘ Copy Import Link</button>
            <button class="copy-btn ssh-copy" onclick="copySSHInfo()" id="ssh-copy-info">📋 ข้อมูล SSH</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════
     MODAL: USER MANAGEMENT
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-mgmt">
  <div class="modal modal-mgmt">
    <div class="modal-header">
      <span class="modal-title" id="mgmt-modal-title">⚙️ จัดการยูส</span>
      <button class="modal-close" onclick="closeModal('mgmt')">✕</button>
    </div>
    <div class="modal-body">
      <!-- User Detail -->
      <div class="udetail" id="mgmt-user-detail"></div>

      <!-- Action Selector -->
      <label style="margin-bottom:.5rem;display:block">เลือกการดำเนินการ</label>
      <div class="action-grid">
        <div class="action-card" id="act-renew" onclick="selectAction('renew')">
          <div class="action-icon">🔄</div>
          <div class="action-name">ต่ออายุ</div>
          <div class="action-desc">รีเซตจากวันนี้</div>
        </div>
        <div class="action-card" id="act-adddays" onclick="selectAction('adddays')">
          <div class="action-icon">📅</div>
          <div class="action-name">เพิ่มวัน</div>
          <div class="action-desc">ต่อจากวันหมด</div>
        </div>
        <div class="action-card" id="act-adddata" onclick="selectAction('adddata')">
          <div class="action-icon">📦</div>
          <div class="action-name">เพิ่ม Data</div>
          <div class="action-desc">เติม GB เพิ่ม</div>
        </div>
        <div class="action-card" id="act-setdata" onclick="selectAction('setdata')">
          <div class="action-icon">⚖️</div>
          <div class="action-name">ตั้ง Data</div>
          <div class="action-desc">กำหนดใหม่</div>
        </div>
        <div class="action-card" id="act-resettraffic" onclick="selectAction('resettraffic')">
          <div class="action-icon">🔃</div>
          <div class="action-name">รีเซต Traffic</div>
          <div class="action-desc">เคลียร์ยอดใช้</div>
        </div>
        <div class="action-card" id="act-delete" onclick="selectAction('delete')">
          <div class="action-icon">🗑️</div>
          <div class="action-name">ลบยูส</div>
          <div class="action-desc">ลบถาวร</div>
        </div>
      </div>

      <!-- Action Detail Form -->
      <div id="action-form" style="margin-top:1rem;display:none">
        <div class="divider"></div>
        <!-- Renew -->
        <div id="form-renew" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>📅 วันใช้งานใหม่ (นับจากวันนี้)</label><input type="number" id="mgmt-renew-days" value="30" min="1" class="mgmt-focus"></div>
            <div class="field span2"><label>📦 Data Limit (GB, 0=∞)</label><input type="number" id="mgmt-renew-data" value="0" min="0" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('renew')">🔄 ต่ออายุยูสเซอร์</button>
        </div>
        <!-- Add Days -->
        <div id="form-adddays" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>📅 เพิ่มกี่วัน (ต่อจากวันหมดอายุเดิม)</label><input type="number" id="mgmt-adddays-val" value="30" min="1" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('adddays')">📅 เพิ่มวัน</button>
        </div>
        <!-- Add Data -->
        <div id="form-adddata" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>📦 เพิ่ม Data กี่ GB</label><input type="number" id="mgmt-adddata-val" value="10" min="1" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('adddata')">📦 เพิ่ม Data</button>
        </div>
        <!-- Set Data -->
        <div id="form-setdata" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>⚖️ ตั้ง Data ใหม่ (GB, 0=ไม่จำกัด)</label><input type="number" id="mgmt-setdata-val" value="30" min="0" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('setdata')">⚖️ ตั้ง Data</button>
        </div>
        <!-- Reset Traffic -->
        <div id="form-resettraffic" style="display:none">
          <div style="background:#fff7ed;border:1px solid #fed7aa;border-radius:10px;padding:.75rem .9rem;font-size:.82rem;color:#92400e;margin-bottom:.8rem">
            ⚠️ การรีเซต Traffic จะเคลียร์ยอดใช้งาน Up/Down ของยูสนี้ให้กลับเป็น 0
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('resettraffic')">🔃 รีเซต Traffic</button>
        </div>
        <!-- Delete -->
        <div id="form-delete" style="display:none">
          <div style="background:#fef2f2;border:1px solid #fca5a5;border-radius:10px;padding:.75rem .9rem;font-size:.82rem;color:#991b1b;margin-bottom:.8rem">
            ⚠️ ยืนยันการลบยูสเซอร์นี้ถาวร ไม่สามารถกู้คืนได้
          </div>
          <button class="submit-btn danger-btn" onclick="doAction('delete')">🗑️ ยืนยันลบยูสเซอร์</button>
        </div>
      </div>

      <div class="alert" id="mgmt-alert"></div>
    </div>
  </div>
</div>

<!-- Toast -->
<div class="toast" id="toast"></div>

<!-- ══════════════════════════════════════
     MODAL: SSH USER MANAGEMENT
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-ssh-mgmt">
  <div class="modal modal-mgmt">
    <div class="modal-header">
      <span class="modal-title" id="ssh-mgmt-title">⚙️ SSH User</span>
      <button class="modal-close" onclick="closeModal('ssh-mgmt')">✕</button>
    </div>
    <div class="modal-body">
      <div class="udetail" id="ssh-mgmt-detail"></div>
      <div class="divider" style="margin:1rem 0"></div>
      <div class="fgrid">
        <div class="field span2">
          <label>📅 เพิ่มกี่วัน (ต่อจากวันหมดอายุเดิม)</label>
          <input type="number" id="ssh-mgmt-adddays" value="30" min="1" class="mgmt-focus">
        </div>
      </div>
      <button class="submit-btn ssh-btn" id="ssh-mgmt-submit" onclick="doSSHAddDays()">📅 เพิ่มวันใช้งาน</button>
      <div class="alert" id="ssh-mgmt-alert"></div>
    </div>
  </div>
</div>

<script>
/* ══════════════════════════════════════
   CONFIG
══════════════════════════════════════ */

/* ══════════════════════════════════════
   SESSION GUARD — เช็ค login ก่อน
══════════════════════════════════════ */
(function(){
  const SESSION_KEY = 'chaiya_auth';
  const LOGIN_PAGE  = 'chaiya-login.html';
  const saved = sessionStorage.getItem(SESSION_KEY);
  if (!saved) { window.location.replace(LOGIN_PAGE); return; }
  try {
    const s = JSON.parse(saved);
    if (!s.user || !s.pass || Date.now() >= s.exp) {
      sessionStorage.removeItem(SESSION_KEY);
      window.location.replace(LOGIN_PAGE);
    }
  } catch(e) {
    sessionStorage.removeItem(SESSION_KEY);
    window.location.replace(LOGIN_PAGE);
  }
})();

const CFG    = (typeof window.CHAIYA_CONFIG !== 'undefined') ? window.CHAIYA_CONFIG : {};
const HOST   = CFG.host       || location.hostname;
const XUI_API = '/xui-api';
const SSH_API = '/sshws-api';
const TOK    = CFG.ssh_token  || '';

const PROS = {
  dtac:{ name:'DTAC GAMING', proxy:'104.18.63.124:80',
    payload:'CONNECT /  HTTP/1.1 [crlf]Host: dl.dir.freefiremobile.com [crlf][crlf]PATCH / HTTP/1.1[crlf]Host:[host][crlf]Upgrade:User-Agent: [ua][crlf][crlf]',
    darkProxy:'104.18.63.124', darkProxyPort:80 },
  true:{ name:'TRUE TWITTER', proxy:'104.18.39.24:80',
    payload:'POST / HTTP/1.1[crlf]Host: help.x.com[crlf]User-Agent: [ua][crlf][crlf][split][cr]PATCH / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
    darkProxy:'104.18.39.24', darkProxyPort:80 }
};

let _sshPort=80, _sshApp='npv', _sshPro='dtac';
let _aisSaved=null, _trueSaved=null, _sshSaved=null;
let _xuiCookieSet=false;
let _allUsers=[], _filteredUsers=[];
let _mgmtUser=null, _mgmtInbound=null, _mgmtAction=null;

/* ══════════════════════════════════════
   TAB SWITCH
══════════════════════════════════════ */
function switchTab(tab) {
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-'+tab).classList.add('active');
  event.currentTarget.classList.add('active');
  if(tab==='dash') loadStats();
  if(tab==='online') loadOnlineUsers();
  if(tab==='ban'){ loadBanList(); loadVlessBanList(); }
}

/* ══════════════════════════════════════
   MODAL
══════════════════════════════════════ */
function openModal(id){document.getElementById('modal-'+id).classList.add('open');document.body.style.overflow='hidden'}
function closeModal(id){document.getElementById('modal-'+id).classList.remove('open');document.body.style.overflow=''}
document.querySelectorAll('.modal-overlay').forEach(el=>{
  el.addEventListener('click',e=>{if(e.target===el){el.classList.remove('open');document.body.style.overflow=''}});
});

/* ══════════════════════════════════════
   UTILITY
══════════════════════════════════════ */
function syncField(s,d){document.getElementById(d).value=document.getElementById(s).value}
function val(id){return document.getElementById(id).value.trim()}
function setAlert(pre,msg,type){
  const el=document.getElementById(pre+'-alert');
  el.className='alert '+type; el.textContent=msg; el.style.display=msg?'':'none';
}
function setLoading(id,on){
  const btn=document.getElementById(id+'-submit');
  if(!btn)return;
  btn.disabled=on;
  btn.innerHTML=on?'<span class="spinner"></span> กำลังดำเนินการ...'
    :(id==='ais'?'⚡ สร้าง AIS Account':id==='true'?'⚡ สร้าง TRUE Account':'⚡ สร้าง SSH Account');
}
function toast(msg,ok=true){
  const el=document.getElementById('toast');
  el.textContent=msg; el.style.background=ok?'#1a2332':'#ef4444';
  el.classList.add('show'); setTimeout(()=>el.classList.remove('show'),2400);
}
function genUUID(){
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{
    const r=Math.random()*16|0;return(c==='x'?r:(r&0x3|0x8)).toString(16);
  });
}
function fmtBytes(bytes){
  if(bytes===0)return'0 B';
  const k=1024,s=['B','KB','MB','GB','TB'];
  const i=Math.floor(Math.log(bytes)/Math.log(k));
  return(bytes/Math.pow(k,i)).toFixed(1)+' '+s[i];
}
function copyText(elId,btnId){copyToClipboard(document.getElementById(elId).textContent.trim(),btnId)}
function copyEl(elId,btnId){copyToClipboard(document.getElementById(elId).textContent.trim(),btnId)}
function copyToClipboard(text,btnId){
  const done=()=>{
    toast('📋 คัดลอกแล้ว!');
    if(btnId){const b=document.getElementById(btnId);if(b){const o=b.textContent;b.textContent='✓ Copied!';b.classList.add('copied');setTimeout(()=>{b.textContent=o;b.classList.remove('copied')},2000)}}
  };
  if(navigator.clipboard)navigator.clipboard.writeText(text).then(done).catch(()=>fbCopy(text,done));
  else fbCopy(text,done);
  function fbCopy(t,cb){const ta=document.createElement('textarea');ta.value=t;ta.style.cssText='position:fixed;top:0;left:0;opacity:0;';document.body.appendChild(ta);ta.focus();ta.select();try{document.execCommand('copy');cb()}catch(e){toast('❌ คัดลอกไม่ได้',false)}document.body.removeChild(ta)}
}

/* ══════════════════════════════════════
   x-ui API
══════════════════════════════════════ */
async function xuiLogin(){
  const SESSION_KEY = 'chaiya_auth';
  let user = CFG.xui_user||'admin', pass = CFG.xui_pass||'';
  try {
    const s = JSON.parse(sessionStorage.getItem(SESSION_KEY)||'{}');
    if(s.user) user = s.user;
    if(s.pass) pass = s.pass;
  } catch(e){}
  const form=new URLSearchParams({username:user,password:pass});
  const r=await fetch(XUI_API+'/login',{method:'POST',credentials:'include',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:form.toString()});
  const d=await r.json(); _xuiCookieSet=!!d.success; return d.success;
}
async function xuiPost(path,payload){
  if(!_xuiCookieSet)await xuiLogin();
  const r=await fetch(XUI_API+path,{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
  return r.json();
}
async function xuiGet(path){
  if(!_xuiCookieSet)await xuiLogin();
  const r=await fetch(XUI_API+path,{credentials:'include'}); return r.json();
}
async function getInboundId(port){
  const d=await xuiGet('/panel/api/inbounds/list');
  if(!d.success)return null;
  const ib=(d.obj||[]).find(x=>x.port===port);
  return ib?ib.id:null;
}

/* ══════════════════════════════════════
   SYSTEM STATS
══════════════════════════════════════ */
function setRing(id,pct,color){
  const el=document.getElementById(id);
  if(!el)return;
  const circ=163.4;
  el.style.stroke=color||el.style.stroke;
  el.style.strokeDashoffset=circ-(circ*Math.min(pct,100)/100);
}
function setBar(id,pct){
  const el=document.getElementById(id);
  if(el)el.style.width=Math.min(pct,100)+'%';
}
function barColor(pct){return pct>85?'linear-gradient(90deg,#dc2626,#ef4444)':pct>65?'linear-gradient(90deg,#d97706,#f97316)':''}

async function loadStats(){
  const btn=document.getElementById('refresh-btn');
  if(btn)btn.classList.add('spin');
  try{
    /* ── 1. x-ui server status ── */
    const ok=await xuiLogin();
    if(!ok){setBadge(false,'Login ไม่สำเร็จ');return;}

    const sv=await xuiGet('/panel/api/server/status').catch(()=>null);
    if(sv&&sv.success&&sv.obj){
      const o=sv.obj;
      /* CPU */
      const cpuPct=Math.round((o.cpu||0));
      document.getElementById('cpu-val').innerHTML=`${cpuPct}<span class="stat-unit">%</span>`;
      document.getElementById('cpu-cores').textContent=(o.cpuCores||o.logicalPro||'--')+' cores';
      setRing('cpu-ring',cpuPct,'#5a9e1c');
      setBar('cpu-bar',cpuPct);
      const cb=document.getElementById('cpu-bar');
      if(cb){const c=barColor(cpuPct);if(c)cb.style.background=c;}

      /* RAM */
      const ramTotalG=((o.mem&&o.mem.total)||0)/1073741824;
      const ramUsedG=((o.mem&&o.mem.current)||0)/1073741824;
      const ramPct=ramTotalG>0?Math.round(ramUsedG/ramTotalG*100):0;
      document.getElementById('ram-val').innerHTML=`${ramPct}<span class="stat-unit">%</span>`;
      document.getElementById('ram-detail').textContent=ramUsedG.toFixed(1)+' / '+ramTotalG.toFixed(1)+' GB';
      setRing('ram-ring',ramPct,'#1a6fa8');
      setBar('ram-bar',ramPct);
      const rb=document.getElementById('ram-bar');
      if(rb){const c=barColor(ramPct);if(c)rb.style.background=c;}

      /* Disk */
      const diskTotalG=((o.disk&&o.disk.total)||0)/1073741824;
      const diskUsedG=((o.disk&&o.disk.current)||0)/1073741824;
      const diskPct=diskTotalG>0?Math.round(diskUsedG/diskTotalG*100):0;
      document.getElementById('disk-val').innerHTML=`${diskPct}<span class="stat-unit">%</span>`;
      document.getElementById('disk-detail').textContent=diskUsedG.toFixed(0)+' / '+diskTotalG.toFixed(0)+' GB';
      setBar('disk-bar',diskPct);
      const db=document.getElementById('disk-bar');
      if(db){const c=barColor(diskPct);if(c)db.style.background=c;}

      /* Uptime */
      const up=o.uptime||0;
      const d=Math.floor(up/86400),h=Math.floor((up%86400)/3600),m=Math.floor((up%3600)/60);
      document.getElementById('uptime-val').textContent=d>0?`${d}d ${h}h`:`${h}h ${m}m`;
      document.getElementById('uptime-sub').textContent=`${d} วัน ${h} ชม. ${m} นาที`;
      /* Load avg */
      const loads=o.loads||[];
      const chips=loads.map((l,i)=>['1m','5m','15m'][i]?`<span class="chip">${['1m','5m','15m'][i]}: ${l.toFixed(2)}</span>`:'').join(' ');
      document.getElementById('load-avg-chips').innerHTML=chips;

      /* Network */
      const ns=o.netIO||o.netTraffic||null;
      if(ns){
        document.getElementById('net-up').textContent=fmtBytes((ns.up||0))+'/s';
        document.getElementById('net-down').textContent=fmtBytes((ns.down||0))+'/s';
      }
      const nt=o.netTraffic||null;
      if(nt){
        document.getElementById('net-up-total').textContent='total: '+fmtBytes(nt.sent||0);
        document.getElementById('net-down-total').textContent='total: '+fmtBytes(nt.recv||0);
      }

      /* x-ui version */
      setBadge(true,'ออนไลน์');
      document.getElementById('xui-ver').textContent='เวอร์ชัน: '+(o.xrayVersion||'--');
    }

    /* ── 2. Inbound count ── */
    const ibl=await xuiGet('/panel/api/inbounds/list').catch(()=>null);
    if(ibl&&ibl.success){
      const cnt=(ibl.obj||[]).length;
      document.getElementById('xui-traffic').textContent=`Inbounds: ${cnt} รายการ`;
    }

    document.getElementById('last-update').textContent='อัพเดทล่าสุด: '+new Date().toLocaleTimeString('th-TH');
  }catch(e){
    setBadge(false,'Error: '+e.message);
  }finally{
    if(btn)btn.classList.remove('spin');
  }
}

function setBadge(ok,text){
  const el=document.getElementById('xui-status-badge');
  if(!el)return;
  el.innerHTML=ok
    ?`<span class="online-badge"><span class="online-dot"></span>${text}</span>`
    :`<span class="status-badge status-dead">⚠ ${text}</span>`;
}

/* ══════════════════════════════════════
   USER LIST
══════════════════════════════════════ */
async function loadUserList(){
  const list=document.getElementById('user-list');
  list.innerHTML='<div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--ssh)"></span>กำลังโหลด...</div>';
  try{
    if(!_xuiCookieSet)await xuiLogin();
    const d=await xuiGet('/panel/api/inbounds/list');
    if(!d.success)throw new Error('โหลดไม่สำเร็จ');
    _allUsers=[];
    (d.obj||[]).forEach(ib=>{
      const settings=typeof ib.settings==='string'?JSON.parse(ib.settings):ib.settings;
      (settings.clients||[]).forEach(c=>{
        _allUsers.push({
          inboundId:ib.id, inboundPort:ib.port, protocol:ib.protocol,
          email:c.email||c.id, uuid:c.id, expiryTime:c.expiryTime||0,
          totalGB:c.totalGB||0, limitIp:c.limitIp||0,
          enable:c.enable!==false,
          upBytes:(ib.up||0),
          downBytes:(ib.down||0),
          upMB:((ib.up||0)/1048576).toFixed(0),
          downMB:((ib.down||0)/1048576).toFixed(0),
          _raw:c, _inbound:ib
        });
      });
    });
    _filteredUsers=[..._allUsers];
    renderUserList(_filteredUsers);
  }catch(e){
    list.innerHTML=`<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }
}

function renderUserList(users){
  const list=document.getElementById('user-list');
  if(!users.length){list.innerHTML='<div class="empty-state"><div class="ei">🔍</div><div>ไม่พบยูสเซอร์</div></div>';return;}
  const now=Date.now();
  list.innerHTML=users.map(u=>{
    const isAis=u.inboundPort===8080;
    const avatarClass=isAis?'ua-ais':'ua-true';
    const initial=(u.email||'?')[0].toUpperCase();
    let statusHtml='', expStr='';
    if(u.expiryTime===0){expStr='ไม่จำกัด';statusHtml='<span class="status-badge status-ok">✓ Active</span>'}
    else{
      const diff=u.expiryTime-now;
      const days=Math.ceil(diff/86400000);
      if(diff<0){expStr='หมดอายุแล้ว';statusHtml='<span class="status-badge status-dead">✗ Expired</span>'}
      else if(days<=3){expStr=`เหลือ ${days} วัน`;statusHtml=`<span class="status-badge status-exp">⚠ ${days}d</span>`}
      else{expStr=`${days} วัน`;statusHtml='<span class="status-badge status-ok">✓ Active</span>'}
    }
    return `<div class="user-row" onclick="openMgmtModal(${JSON.stringify(u.email)})">
      <div class="user-avatar ${avatarClass}">${initial}</div>
      <div class="user-info">
        <div class="user-name">${u.email}</div>
        <div class="user-meta">Port ${u.inboundPort} · ${expStr}</div>
      </div>
      ${statusHtml}
    </div>`;
  }).join('');
}

function filterUsers(q){
  const s=q.toLowerCase();
  _filteredUsers=_allUsers.filter(u=>(u.email||'').toLowerCase().includes(s));
  renderUserList(_filteredUsers);
}

/* ══════════════════════════════════════
   ONLINE USERS v2 — VLESS + SSH รวมกัน
══════════════════════════════════════ */
async function loadOnlineUsers(){
  const btn=document.getElementById('online-refresh');
  if(btn)btn.classList.add('spin');
  const list=document.getElementById('online-list');
  list.innerHTML='<div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--green)"></span>กำลังโหลด...</div>';

  try{
    // โหลด VLESS online จาก x-ui
    let vlessOnlineEmails = [];
    let vlessUserMap = {};
    try{
      if(!_xuiCookieSet) await xuiLogin();
      // ดึง online list จาก x-ui
      const od = await xuiGet('/panel/api/inbounds/onlines').catch(()=>null);
      if(od && (od.success || Array.isArray(od.obj))){
        vlessOnlineEmails = od.obj || [];
      }
      // ดึง user detail ทั้งหมด
      if(!_allUsers.length) await loadUserList().catch(()=>{});
      _allUsers.forEach(u=>{ vlessUserMap[u.email]=u; });
    }catch(e){ console.warn('VLESS online error:', e.message); }

    // โหลด SSH online จาก SSH API — ใช้ /api/users แล้วเช็ค active connection
    let sshOnlineUsers = [];
    try{
      // SSH API ไม่มี "online" endpoint ที่แน่นอน
      // จะใช้ /api/status ดู connection count แล้วเอา users ที่ active + ไม่หมดอายุ
      // และใช้ /api/users ดึงรายชื่อ
      const statusR = await fetch(SSH_API+'/api/status', {
        headers:{'X-Token':TOK,'Authorization':'Bearer '+TOK}
      });
      const statusD = await statusR.json();

      // ดึง user list
      const usersR = await fetch(SSH_API+'/api/users', {
        headers:{'X-Token':TOK,'Authorization':'Bearer '+TOK}
      });
      const usersD = await usersR.json();
      const allSSH = usersD.users || [];

      // กรองเฉพาะที่ active (ยังไม่หมดอายุ) — SSH ไม่มี real online tracking แบบ x-ui
      // แสดง active users ที่มี connection จริง (ตรวจจาก connection count)
      const today = new Date().toISOString().split('T')[0];
      const connCount = statusD.conn_143 + statusD.conn_109 || 0;

      // ดึงรายชื่อ SSH ที่ active จริงจาก /api/online ถ้ามี
      let sshOnlineList = [];
      try{
        const onR = await fetch(SSH_API+'/api/online', {
          headers:{'X-Token':TOK,'Authorization':'Bearer '+TOK}
        });
        if(onR.ok){
          const onD = await onR.json();
          sshOnlineList = onD.users || onD.online || [];
        }
      }catch(e){}

      if(sshOnlineList.length > 0){
        // ถ้า API /api/online มีข้อมูล ใช้ตัวนั้น
        sshOnlineUsers = allSSH.filter(u => sshOnlineList.includes(u.user));
      } else {
        // fallback: ไม่แสดง SSH users ถ้าไม่มี real online data
        // (ไม่มั่วแสดงทั้งหมด — ตาม requirement)
        sshOnlineUsers = [];
      }
    }catch(e){ console.warn('SSH online error:', e.message); }

    const totalOnline = vlessOnlineEmails.length + sshOnlineUsers.length;
    document.getElementById('online-count').textContent = totalOnline;
    document.getElementById('online-vless-badge').textContent = 'VLESS ' + vlessOnlineEmails.length;
    document.getElementById('online-ssh-badge').textContent = 'SSH ' + sshOnlineUsers.length;
    document.getElementById('online-time').textContent = 'อัพเดท: '+new Date().toLocaleTimeString('th-TH');

    if(totalOnline === 0){
      list.innerHTML='<div class="empty-state"><div class="ei">😴</div><div>ไม่มียูสออนไลน์ตอนนี้</div></div>';
      return;
    }

    const now = Date.now();
    let rows = '';

    // ─── VLESS rows ───────────────────────────────
    vlessOnlineEmails.forEach(email=>{
      const u = vlessUserMap[email] || null;
      const isAis = u && u.inboundPort===8080;
      const portLabel = u ? `Port ${u.inboundPort}` : 'VLESS';
      const typeLabel = isAis ? 'AIS' : 'TRUE';
      const avatarBg = isAis ? '#edf7e3' : '#fff0f0';
      const avatarBd = isAis ? '#b5e08a' : '#f5909a';
      const avatarColor = isAis ? '#316808' : '#a6000c';

      // data bar — totalGB ใน x-ui เก็บเป็น bytes แล้ว
      let dataPct=0, dataLabel='ไม่จำกัด', dataColor='#22c55e', isFullBar=false;
      if(u && u.totalGB > 0){
        // totalGB จาก x-ui คือ bytes จริงๆ (เพราะส่งไปเป็น GB*1024^3)
        const totalBytes = u.totalGB;
        const usedBytes = (u.upBytes||0) + (u.downBytes||0);
        dataPct = Math.min(Math.round(usedBytes/totalBytes*100), 100);
        const usedGB = (usedBytes/1073741824).toFixed(2);
        const totalGB = (totalBytes/1073741824).toFixed(0);
        dataLabel = `${usedGB} / ${totalGB} GB`;
        dataColor = dataPct>85?'#ef4444':dataPct>60?'#f97316':'#22c55e';
      }

      // วันหมดอายุ
      let expLabel='ไม่จำกัด', expClass='exp-ok';
      if(u && u.expiryTime > 0){
        const diff = u.expiryTime - now;
        const daysLeft = Math.ceil(diff/86400000);
        if(diff < 0){ expLabel='หมดอายุแล้ว'; expClass='exp-dead'; }
        else{
          expLabel = `${daysLeft}d — ${new Date(u.expiryTime).toLocaleDateString('th-TH')}`;
          expClass = daysLeft<=3?'exp-warn':'exp-ok';
        }
      }

      rows += `<div class="online-user-row">
        <div class="online-avatar" style="background:${avatarBg};border-color:${avatarBd};color:${avatarColor}">${(email||'?')[0].toUpperCase()}</div>
        <div class="online-info">
          <div class="online-name">
            <span>${email}</span>
            <span class="online-port-chip">${portLabel}</span>
            <span style="font-family:'Share Tech Mono',monospace;font-size:.6rem;background:${isAis?'#f0f9e8':'#fff0f0'};border:1px solid ${isAis?'#b5e08a':'#f5909a'};color:${isAis?'#316808':'#a6000c'};padding:.1rem .4rem;border-radius:20px">${typeLabel}</span>
          </div>
          <div class="online-data-row">
            <div class="online-data-bar-wrap">
              <div class="online-data-bar" style="width:${u&&u.totalGB>0?dataPct:0}%;background:${dataColor}"></div>
            </div>
            <span class="online-data-label">${dataLabel}</span>
          </div>
          <div class="online-exp ${expClass}">📅 ${expLabel}</div>
        </div>
        <span class="online-live-dot"></span>
      </div>`;
    });

    // ─── SSH rows ───────────────────────────────
    sshOnlineUsers.forEach(u=>{
      const expLabel2 = u.exp || 'ไม่จำกัด';
      const expClass2 = !u.exp ? 'exp-ok' : (u.exp < new Date().toISOString().split('T')[0] ? 'exp-dead' : 'exp-ok');
      rows += `<div class="online-user-row">
        <div class="online-avatar" style="background:#e8f0fe;border-color:#7c9ff5;color:#1a4faf">${(u.user||'?')[0].toUpperCase()}</div>
        <div class="online-info">
          <div class="online-name">
            <span>${u.user}</span>
            <span class="online-port-chip">SSH-WS</span>
            <span style="font-family:'Share Tech Mono',monospace;font-size:.6rem;background:#e8f0fe;border:1px solid #7c9ff5;color:#1a4faf;padding:.1rem .4rem;border-radius:20px">SSH</span>
          </div>
          <div class="online-data-row">
            <div class="online-data-bar-wrap">
              <div class="online-data-bar" style="width:100%;background:#22c55e;opacity:.35"></div>
            </div>
            <span class="online-data-label">ไม่จำกัด</span>
          </div>
          <div class="online-exp ${expClass2}">📅 ${expLabel2}</div>
        </div>
        <span class="online-live-dot"></span>
      </div>`;
    });

    list.innerHTML = rows;

  }catch(e){
    list.innerHTML=`<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }finally{
    if(btn)btn.classList.remove('spin');
  }
}

/* ══════════════════════════════════════
   BAN SYSTEM
══════════════════════════════════════ */
async function loadBanList(){
  const btn=document.getElementById('ban-refresh');
  if(btn)btn.classList.add('spin');
  const list=document.getElementById('ban-list');
  list.innerHTML='<div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:#dc2626"></span>กำลังโหลด...</div>';
  try{
    // ดึงรายชื่อที่ถูกแบน (เช็คจากไฟล์ /etc/chaiya/bans/ ผ่าน SSH API)
    // เนื่องจากไม่มี /api/banned ให้ดึง SSH users แล้วเช็ค status
    const r = await fetch(SSH_API+'/api/users', {
      headers:{'X-Token':TOK,'Authorization':'Bearer '+TOK}
    });
    const d = await r.json();
    const allUsers = d.users || [];

    // กรองเฉพาะที่ถูกแบน (active=false หรือ exp เป็น 0000 หรือมีไฟล์แบน)
    // ใช้ endpoint /api/banned ถ้ามี
    let banned = [];
    try{
      const br = await fetch(SSH_API+'/api/banned', {
        headers:{'X-Token':TOK,'Authorization':'Bearer '+TOK}
      });
      if(br.ok){
        const bd = await br.json();
        banned = bd.banned || [];
      }
    }catch(e){
      // fallback: ถ้าไม่มี endpoint แสดงว่าไม่มีระบบแบน
      banned = [];
    }

    document.getElementById('ban-count-badge').textContent = banned.length + ' คน';

    if(!banned.length){
      list.innerHTML='<div class="empty-state"><div class="ei">✅</div><div>ไม่มีใครถูกแบนตอนนี้</div></div>';
      return;
    }
    const now = Date.now();
    list.innerHTML = banned.map(b=>{
      const banUntil = b.ban_until ? new Date(b.ban_until*1000) : null;
      const remaining = banUntil ? Math.max(0, Math.ceil((banUntil-now)/60000)) : 0;
      const timeStr = banUntil ? `หมดแบน: ${banUntil.toLocaleTimeString('th-TH')} (อีก ${remaining} นาที)` : 'ถาวร';
      return `<div class="online-user-row" style="align-items:center">
        <div class="online-avatar" style="background:#fef2f2;border-color:#fca5a5;color:#991b1b">${(b.user||'?')[0].toUpperCase()}</div>
        <div class="online-info" style="flex:1">
          <div class="online-name"><span style="font-weight:600">${b.user}</span><span style="font-family:'Share Tech Mono',monospace;font-size:.6rem;background:#fef2f2;border:1px solid #fca5a5;color:#991b1b;padding:.1rem .4rem;border-radius:20px">🚫 BANNED</span></div>
          <div style="font-size:.68rem;color:#dc2626;font-family:'Share Tech Mono',monospace;margin-top:.2rem">⏱ ${timeStr}</div>
        </div>
        <button onclick="doUnban('${b.user}')" style="padding:.4rem .85rem;border-radius:9px;border:1.5px solid #16a34a;background:#f0fdf4;color:#15803d;font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.82rem;cursor:pointer;white-space:nowrap;transition:all .18s" onmouseover="this.style.background='#dcfce7'" onmouseout="this.style.background='#f0fdf4'">✅ ปลดแบน</button>
      </div>`;
    }).join('');
  }catch(e){
    list.innerHTML=`<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }finally{
    if(btn)btn.classList.remove('spin');
  }
}

async function doBanUser(){
  const user = document.getElementById('ban-manual-user').value.trim();
  const hours = parseFloat(document.getElementById('ban-manual-hours').value) || 2;
  const alertEl = document.getElementById('ban-manual-alert');

  if(!user){ alertEl.style.display='block'; alertEl.style.background='#fef2f2'; alertEl.style.border='1px solid #fca5a5'; alertEl.style.color='#991b1b'; alertEl.textContent='❌ กรุณาใส่ username'; return; }

  alertEl.style.display='block'; alertEl.style.background='#f0f9ff'; alertEl.style.border='1px solid #7dd3fc'; alertEl.style.color='#0369a1'; alertEl.textContent='⏳ กำลังแบน...';
  try{
    const r = await fetch(SSH_API+'/api/ban', {
      method:'POST',
      headers:{'Content-Type':'application/json','X-Token':TOK,'Authorization':'Bearer '+TOK},
      body:JSON.stringify({user, hours})
    });
    const d = await r.json();
    if(!d.ok && !d.success) throw new Error(d.error||'ไม่สำเร็จ');
    alertEl.style.background='#f0fdf4'; alertEl.style.border='1px solid #86efac'; alertEl.style.color='#15803d';
    alertEl.textContent=`✅ แบน "${user}" ${hours} ชั่วโมง สำเร็จ`;
    document.getElementById('ban-manual-user').value='';
    setTimeout(()=>loadBanList(), 800);
  }catch(e){
    alertEl.style.background='#fef2f2'; alertEl.style.border='1px solid #fca5a5'; alertEl.style.color='#991b1b';
    alertEl.textContent='❌ '+e.message;
  }
}

async function doUnban(user){
  try{
    const r = await fetch(SSH_API+'/api/unban', {
      method:'POST',
      headers:{'Content-Type':'application/json','X-Token':TOK,'Authorization':'Bearer '+TOK},
      body:JSON.stringify({user})
    });
    const d = await r.json();
    if(!d.ok && !d.success) throw new Error(d.error||'ไม่สำเร็จ');
    toast('✅ ปลดแบน '+user+' สำเร็จ');
    loadBanList();
  }catch(e){ toast('❌ '+e.message, false); }
}

async function loadVlessBanList(){
  const list = document.getElementById('vless-ban-list');
  list.innerHTML='<div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--ais)"></span>กำลังโหลด...</div>';
  try{
    if(!_xuiCookieSet) await xuiLogin();
    const d = await xuiGet('/panel/api/inbounds/list');
    if(!d.success) throw new Error('โหลด inbound ไม่สำเร็จ');
    let disabledClients = [];
    (d.obj||[]).forEach(ib=>{
      const settings = typeof ib.settings==='string'?JSON.parse(ib.settings):ib.settings;
      (settings.clients||[]).forEach(c=>{
        if(c.enable===false){
          disabledClients.push({
            email: c.email||c.id,
            uuid: c.id,
            inboundId: ib.id,
            inboundPort: ib.port,
            protocol: ib.protocol
          });
        }
      });
    });
    if(!disabledClients.length){
      list.innerHTML='<div class="empty-state"><div class="ei">✅</div><div>ไม่มี VLESS ที่ถูกปิดการใช้งาน</div></div>';
      return;
    }
    list.innerHTML = disabledClients.map(c=>{
      const isAis=c.inboundPort===8080;
      return `<div class="online-user-row" style="align-items:center">
        <div class="online-avatar" style="background:${isAis?'#edf7e3':'#fff0f0'};border-color:${isAis?'#b5e08a':'#f5909a'};color:${isAis?'#316808':'#a6000c'}">${(c.email||'?')[0].toUpperCase()}</div>
        <div class="online-info" style="flex:1">
          <div class="online-name"><span style="font-weight:600">${c.email}</span><span class="online-port-chip">Port ${c.inboundPort}</span><span style="font-family:'Share Tech Mono',monospace;font-size:.6rem;background:#fef2f2;border:1px solid #fca5a5;color:#991b1b;padding:.1rem .4rem;border-radius:20px">🔴 Disabled</span></div>
          <div style="font-size:.68rem;color:var(--text3);font-family:'Share Tech Mono',monospace;margin-top:.2rem">UUID: ${c.uuid.substring(0,18)}...</div>
        </div>
        <button onclick="doUnbanVless('${c.email}',${c.inboundId},'${c.uuid}')" style="padding:.4rem .85rem;border-radius:9px;border:1.5px solid #16a34a;background:#f0fdf4;color:#15803d;font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.82rem;cursor:pointer;white-space:nowrap;transition:all .18s" onmouseover="this.style.background='#dcfce7'" onmouseout="this.style.background='#f0fdf4'">✅ Enable</button>
      </div>`;
    }).join('');
  }catch(e){
    list.innerHTML=`<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }
}

async function doUnbanVless(email, inboundId, uuid){
  try{
    const r = await fetch(SSH_API+'/api/unban_vless', {
      method:'POST',
      headers:{'Content-Type':'application/json','X-Token':TOK,'Authorization':'Bearer '+TOK},
      body:JSON.stringify({user:email, inbound_id:inboundId, uuid})
    });
    const d = await r.json();
    if(!d.ok && !d.success) throw new Error(d.error||'ไม่สำเร็จ');
    toast('✅ Enable '+email+' สำเร็จ');
    loadVlessBanList();
  }catch(e){ toast('❌ '+e.message, false); }
}

/* ══════════════════════════════════════
   SWITCH TAB (override เพิ่ม ban)
══════════════════════════════════════ */

/* ══════════════════════════════════════
   MANAGE TAB TYPE SWITCH
══════════════════════════════════════ */
let _mgmtType = 'vless';
function switchMgmtType(type) {
  _mgmtType = type;
  const isVless = type === 'vless';
  document.getElementById('mgmt-panel-vless').style.display = isVless ? '' : 'none';
  document.getElementById('mgmt-panel-ssh').style.display   = isVless ? 'none' : '';
  const btnV = document.getElementById('mgmt-btn-vless');
  const btnS = document.getElementById('mgmt-btn-ssh');
  if(isVless){
    btnV.style.background = 'var(--green)'; btnV.style.color = '#001a00'; btnV.style.borderColor = 'var(--green)';
    btnS.style.background = 'transparent'; btnS.style.color = 'var(--ssh)'; btnS.style.borderColor = 'var(--ssh)';
    if(!_allUsers.length) loadUserList();
  } else {
    btnS.style.background = 'var(--ssh)'; btnS.style.color = '#fff'; btnS.style.borderColor = 'var(--ssh)';
    btnV.style.background = 'transparent'; btnV.style.color = 'var(--green)'; btnV.style.borderColor = 'var(--green)';
    if(!_allSSHUsers.length) loadSSHUserList();
  }
}

/* ══════════════════════════════════════
   SSH USER LIST
══════════════════════════════════════ */
let _allSSHUsers = [], _filteredSSHUsers = [], _sshMgmtUser = null;

async function loadSSHUserList() {
  const list = document.getElementById('ssh-user-list');
  list.innerHTML = '<div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--ssh)"></span>กำลังโหลด...</div>';
  try {
    const r = await fetch(SSH_API + '/api/users', {
      headers: { 'X-Token': TOK, 'Authorization': 'Bearer ' + TOK }
    });
    const d = await r.json();
    if (d.error || !d.users) throw new Error(d.error || 'โหลดไม่สำเร็จ');
    _allSSHUsers = d.users || [];
    _filteredSSHUsers = [..._allSSHUsers];
    renderSSHUserList(_filteredSSHUsers);
  } catch(e) {
    list.innerHTML = `<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }
}

function renderSSHUserList(users) {
  const list = document.getElementById('ssh-user-list');
  if (!users.length) {
    list.innerHTML = '<div class="empty-state"><div class="ei">🔍</div><div>ไม่พบยูสเซอร์ SSH</div></div>';
    return;
  }
  const today = new Date().toISOString().split('T')[0];
  list.innerHTML = users.map(u => {
    const expired = u.exp && u.exp < today;
    let statusHtml, expStr;
    if (!u.exp) { expStr = 'ไม่จำกัด'; statusHtml = '<span class="status-badge status-ok">✓ Active</span>'; }
    else if (expired) { expStr = 'หมดอายุ'; statusHtml = '<span class="status-badge status-dead">✗ Expired</span>'; }
    else {
      const days = Math.ceil((new Date(u.exp) - new Date()) / 86400000);
      expStr = days + ' วัน';
      statusHtml = days <= 3
        ? `<span class="status-badge status-exp">⚠ ${days}d</span>`
        : '<span class="status-badge status-ok">✓ Active</span>';
    }
    return `<div class="user-row" onclick="openSSHMgmtModal(${JSON.stringify(u.user)})">
      <div class="user-avatar ua-ssh" style="background:#e8f0fe;border-color:#7c9ff5;color:#1a4faf">${(u.user||'?')[0].toUpperCase()}</div>
      <div class="user-info">
        <div class="user-name">${u.user}</div>
        <div class="user-meta">SSH-WS · ${expStr}</div>
      </div>
      ${statusHtml}
    </div>`;
  }).join('');
}

function filterSSHUsers(q) {
  const s = q.toLowerCase();
  _filteredSSHUsers = _allSSHUsers.filter(u => (u.user||'').toLowerCase().includes(s));
  renderSSHUserList(_filteredSSHUsers);
}

function openSSHMgmtModal(username) {
  const u = _allSSHUsers.find(x => x.user === username);
  if (!u) return;
  _sshMgmtUser = u;
  document.getElementById('ssh-mgmt-title').textContent = '⚙️ ' + username;
  const expStr = u.exp || 'ไม่จำกัด';
  document.getElementById('ssh-mgmt-detail').innerHTML = `
    <div class="udetail-row"><span class="dk">👤 Username</span><span class="dv">${u.user}</span></div>
    <div class="udetail-row"><span class="dk">📅 หมดอายุ</span><span class="dv">${expStr}</span></div>
    <div class="udetail-row"><span class="dk">📱 IP Limit</span><span class="dv">${u.ip_limit || u.iplimit || '2'}</span></div>
  `;
  document.getElementById('ssh-mgmt-adddays').value = 30;
  setAlert('ssh-mgmt', '', '');
  openModal('ssh-mgmt');
}

async function doSSHAddDays() {
  if (!_sshMgmtUser) return;
  const days = parseInt(document.getElementById('ssh-mgmt-adddays').value) || 30;
  const btn = document.getElementById('ssh-mgmt-submit');
  btn.disabled = true;
  setAlert('ssh-mgmt', '⏳ กำลังดำเนินการ...', 'info');
  try {
    const r = await fetch(SSH_API + '/api/renew', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Token': TOK, 'Authorization': 'Bearer ' + TOK },
      body: JSON.stringify({ user: _sshMgmtUser.user, days })
    });
    const d = await r.json();
    if (!d.ok && !d.success) throw new Error(d.error || d.msg || 'ดำเนินการไม่สำเร็จ');
    setAlert('ssh-mgmt', `✅ เพิ่ม ${days} วันสำเร็จ!`, 'ok');
    toast(`✅ ${_sshMgmtUser.user} +${days} วัน`);
    setTimeout(() => { closeModal('ssh-mgmt'); loadSSHUserList(); }, 1500);
  } catch(e) {
    setAlert('ssh-mgmt', '❌ ' + e.message, 'err');
  } finally {
    btn.disabled = false;
  }
}

/* ══════════════════════════════════════
   VLESS CREATION
══════════════════════════════════════ */
const VLESS_CFG={
  ais:{port:8080,sniField:'ais-sni',defaultSNI:'cj-ebb.speedtest.net'},
  true:{port:8880,sniField:'true-sni',defaultSNI:'true-internet.zoom.xyz.services'}
};

async function createVless(carrier){
  const c=VLESS_CFG[carrier];
  const user=val(carrier+'-user');
  const days=parseInt(val(carrier+'-days'))||30;
  const dataGB=parseInt(val(carrier+'-data'))||0;
  const ipLimit=parseInt(val(carrier+'-iplimit'))||2;
  const email=val(carrier+'-email')||user;
  const sni=val(carrier+'-sni')||c.defaultSNI;
  if(!user)return setAlert(carrier,'❌ กรุณาใส่ Username','err');

  setLoading(carrier,true); setAlert(carrier,'','');
  try{
    const loginOk=await xuiLogin();
    if(!loginOk)throw new Error('Login x-ui ไม่สำเร็จ');
    const uuid=genUUID();
    const expMs=Date.now()+days*86400000;
    const totalBytes=dataGB>0?dataGB*1073741824:0;
    const inboundId=await getInboundId(c.port);
    let result;
    if(inboundId!==null){
      result=await xuiPost('/panel/api/inbounds/addClient',{id:inboundId,settings:JSON.stringify({clients:[{id:uuid,flow:'',email:email,limitIp:ipLimit,totalGB:totalBytes,expiryTime:expMs,enable:true,tgId:'',subId:'',comment:'',reset:0}]})});
    }else{
      result=await xuiPost('/panel/api/inbounds/add',{remark:`CHAIYA-${carrier.toUpperCase()}-${c.port}`,enable:true,listen:'',port:c.port,protocol:'vless',settings:JSON.stringify({clients:[{id:uuid,flow:'',email:email,limitIp:ipLimit,totalGB:totalBytes,expiryTime:expMs,enable:true,tgId:'',subId:'',comment:'',reset:0}],decryption:'none'}),streamSettings:JSON.stringify({network:'ws',security:'none',wsSettings:{path:'/vless',headers:{Host:sni}}}),sniffing:JSON.stringify({enabled:true,destOverride:['http','tls']}),tag:`inbound-${c.port}`});
    }
    if(!result.success)throw new Error(result.msg||'สร้างไม่สำเร็จ');
    const vlessLink=buildVlessLink(uuid,HOST,c.port,sni,email);
    const saved={user,email,uuid,days,expMs,dataGB,ipLimit,sni,port:c.port,vlessLink};
    if(carrier==='ais')_aisSaved=saved; else _trueSaved=saved;
    showVlessResult(carrier,saved);
    setAlert(carrier,`✅ สร้าง ${carrier.toUpperCase()} user "${user}" สำเร็จ!`,'ok');
  }catch(e){setAlert(carrier,'❌ '+e.message,'err');
  }finally{setLoading(carrier,false)}
}

function showVlessResult(carrier,d){
  const expDate=new Date(d.expMs).toLocaleDateString('th-TH');
  const dataStr=d.dataGB>0?d.dataGB+' GB':'ไม่จำกัด';
  document.getElementById(carrier+'-info').innerHTML=`
    <div class="info-row"><span class="info-key">👤 Username</span><span class="info-val">${d.user}</span></div>
    <div class="info-row"><span class="info-key">📅 หมดอายุ</span><span class="info-val">${expDate}</span></div>
    <div class="info-row"><span class="info-key">📦 Data</span><span class="info-val">${dataStr}</span></div>
    <div class="info-row"><span class="info-key">📱 IP Limit</span><span class="info-val">${d.ipLimit} IP</span></div>
    <div class="info-row"><span class="info-key">🔌 Port</span><span class="info-val">${d.port}</span></div>
    <div class="info-row"><span class="info-key">🌐 SNI</span><span class="info-val">${d.sni}</span></div>
    <div class="info-row"><span class="info-key">🆔 UUID</span><span class="info-val uuid">${d.uuid}</span></div>`;
  document.getElementById(carrier+'-vless-link').textContent=d.vlessLink;
  renderQR(carrier+'-qr',d.vlessLink);
  document.getElementById(carrier+'-result').classList.add('show');
  setTimeout(()=>document.getElementById(carrier+'-result').scrollIntoView({behavior:'smooth',block:'nearest'}),100);
}
function copyNpvDirect(carrier){
  const saved=carrier==='ais'?_aisSaved:_trueSaved;
  if(!saved)return toast('❌ สร้าง account ก่อน',false);
  copyToClipboard(buildNpvLink(saved.user,saved.pass,PROS.dtac,80),carrier+'-copy-npv');
}

/* ══════════════════════════════════════
   SSH SELECTORS
══════════════════════════════════════ */
function sshSelPort(port){
  _sshPort=port;
  ['80','443'].forEach(p=>{document.getElementById('ssh-tab-'+p).className='port-tab'+(String(port)===p?' active-ssh':'')});
  document.getElementById('ssh-sni-field').style.display=port===443?'':'none';
}
function sshSelApp(app){
  _sshApp=app;
  ['npv','dark'].forEach(a=>{document.getElementById('ssh-app-'+a).className='port-tab'+(app===a?' active-ssh':'')});
  const lb=document.getElementById('ssh-import-link');
  if(lb)lb.className='link-box '+(app==='npv'?'npv-link':'dark-link');
}
function sshSelPro(pro){
  _sshPro=pro;
  ['dtac','true'].forEach(p=>{document.getElementById('ssh-pro-'+p).className='port-tab pro-tab'+(pro===p?' active-ssh':'')});
}

/* ══════════════════════════════════════
   SSH CREATION
══════════════════════════════════════ */
async function createSSH(){
  const user=val('ssh-user'), pass=val('ssh-pass');
  const days=parseInt(val('ssh-days'))||30;
  const ipLimit=parseInt(val('ssh-iplimit'))||2;
  if(!user)return setAlert('ssh','❌ กรุณาใส่ Username','err');
  if(!pass)return setAlert('ssh','❌ กรุณาใส่ Password','err');
  setLoading('ssh',true); setAlert('ssh','','');
  try{
    const r=await fetch(SSH_API+'/api/create',{method:'POST',headers:{'Content-Type':'application/json','X-Token':TOK,'Authorization':'Bearer '+TOK},body:JSON.stringify({user,pass,exp_days:days,ip_limit:ipLimit,port:String(_sshPort)})});
    const d=await r.json();
    if(!d.ok&&!d.success)throw new Error(d.error||d.msg||'สร้างไม่สำเร็จ');
    const pro=PROS[_sshPro];
    const link=_sshApp==='npv'?buildNpvLink(user,pass,pro,_sshPort):buildDarkLink(user,pass,pro,_sshPort);
    const expDate=new Date(Date.now()+days*86400000).toLocaleDateString('th-TH');
    _sshSaved={user,pass,days,ipLimit,port:_sshPort,expDate,link};
    showSSHResult(_sshSaved);
    setAlert('ssh',`✅ สร้าง SSH user "${user}" สำเร็จ!`,'ok');
  }catch(e){setAlert('ssh','❌ '+e.message,'err');
  }finally{setLoading('ssh',false)}
}
function showSSHResult(d){
  const isNpv=_sshApp==='npv';
  document.getElementById('ssh-info').innerHTML=`
    <div class="info-row"><span class="info-key">👤 Username</span><span class="info-val">${d.user}</span></div>
    <div class="info-row"><span class="info-key">🔑 Password</span><span class="info-val pass">${d.pass}</span></div>
    <div class="info-row"><span class="info-key">🌐 Host</span><span class="info-val">${HOST}</span></div>
    <div class="info-row"><span class="info-key">🔌 WS Port</span><span class="info-val">${d.port}</span></div>
    <div class="info-row"><span class="info-key">🐻 Dropbear</span><span class="info-val">143, 109</span></div>
    <div class="info-row"><span class="info-key">📅 หมดอายุ</span><span class="info-val">${d.expDate}</span></div>
    <div class="info-row"><span class="info-key">📱 IP Limit</span><span class="info-val">${d.ipLimit} IP</span></div>
    <div class="info-row"><span class="info-key">📲 App</span><span class="info-val">${isNpv?'NpvTunnel':'DarkTunnel'}</span></div>`;
  const lb=document.getElementById('ssh-import-link');
  lb.textContent=d.link; lb.className='link-box '+(isNpv?'npv-link':'dark-link');
  document.getElementById('ssh-result').classList.add('show');
  setTimeout(()=>document.getElementById('ssh-result').scrollIntoView({behavior:'smooth',block:'nearest'}),100);
}
function copySSHInfo(){
  if(!_sshSaved)return toast('❌ สร้าง account ก่อน',false);
  const d=_sshSaved;
  const text=`Host/IP   : ${HOST}\nPort (WS) : ${d.port}\nDropbear  : 143, 109\nUsername  : ${d.user}\nPassword  : ${d.pass}\nExpire    : ${d.expDate}\nIP Limit  : ${d.ipLimit}\nUDP GW    : 127.0.0.1:7300\nPath (80) : /\nPath (443): /ssh/`;
  copyToClipboard(text,'ssh-copy-info');
}

/* ══════════════════════════════════════
   LINK BUILDERS
══════════════════════════════════════ */
function buildVlessLink(uuid,host,port,sni,email){
  return `vless://${uuid}@${host}:${port}?path=${encodeURIComponent('/vless')}&security=none&encryption=none&host=${encodeURIComponent(sni)}&type=ws#CHAIYA-${email}-${port}`;
}
function buildNpvLink(name,pass,pro,port){
  const j={sshConfigType:'SSH-Proxy-Payload',remarks:pro.name+'-'+name,sshHost:HOST,sshPort:port,sshUsername:name,sshPassword:pass,sni:'',tlsVersion:'DEFAULT',httpProxy:pro.proxy,authenticateProxy:false,proxyUsername:'',proxyPassword:'',payload:pro.payload,dnsTTMode:'UDP',dnsServer:'',nameserver:'',publicKey:'',udpgwPort:7300,udpgwTransparentDNS:true};
  return 'npvt-ssh://'+btoa(unescape(encodeURIComponent(JSON.stringify(j))));
}
function buildDarkLink(name,pass,pro,port){
  const j={type:'SSH',name:pro.name+'-'+name,sshTunnelConfig:{sshConfig:{host:HOST,port:port,username:name,password:pass},injectConfig:{mode:'PROXY',proxyHost:pro.darkProxy||'',proxyPort:pro.darkProxyPort||80,payload:pro.payload||''}}};
  return 'darktunnel://'+btoa(unescape(encodeURIComponent(JSON.stringify(j))));
}

/* QR */
function renderQR(elId,text){
  const el=document.getElementById(elId); el.innerHTML='';
  try{new QRCode(el,{text,width:176,height:176,colorDark:'#000',colorLight:'#fff',correctLevel:QRCode.CorrectLevel.M})}
  catch(e){el.textContent='QR Error'}
}

/* ══════════════════════════════════════
   AUTO LOAD on start
══════════════════════════════════════ */

/* ══════════════════════════════════════
   SERVICE MONITOR
══════════════════════════════════════ */
const SERVICES=[
  {name:'x-ui Panel',     icon:'📡', ports:[54321], type:'xui'},
  {name:'Python SSH API', icon:'🐍', ports:[6789],  path:SSH_API+'/api/status', type:'http'},
  {name:'Dropbear SSH',   icon:'🐻', ports:[143,109], type:'port'},
  {name:'nginx / WS',     icon:'🌐', ports:[80],    path:'/', type:'http'},
  {name:'badvpn UDP-GW',  icon:'🎮', ports:[7300],  type:'port'},
];

async function loadServiceStatus(){
  const btn=document.getElementById('svc-refresh-btn');
  if(btn)btn.classList.add('spin');
  const listEl=document.getElementById('svc-list');
  // แสดง placeholder ขณะโหลด
  listEl.innerHTML='<div class="svc-grid">'+SERVICES.map(s=>`
    <div class="svc-row">
      <span class="svc-dot" style="background:#d1d5db"></span>
      <span class="svc-icon">${s.icon}</span>
      <span class="svc-name">${s.name}</span>
      <span class="svc-ports">${s.ports.map(p=>':'+p).join(' ')}</span>
      <span class="svc-chip checking">...</span>
    </div>`).join('')+'</div>';

  const results=await Promise.all(SERVICES.map(s=>checkService(s)));
  listEl.innerHTML='<div class="svc-grid">'+results.map(r=>`
    <div class="svc-row ${r.state}">
      <span class="svc-dot ${r.state}"></span>
      <span class="svc-icon">${r.icon}</span>
      <span class="svc-name">${r.name}</span>
      <span class="svc-ports">${r.portStr}</span>
      <span class="svc-chip ${r.state}">${r.state==='up'?'RUNNING':r.state==='warn'?'WARN':'DOWN'}</span>
    </div>`).join('')+'</div>';

  if(btn)btn.classList.remove('spin');
}

async function checkService(s){
  const base={name:s.name,icon:s.icon,portStr:s.ports.map(p=>':'+p).join(' '),state:'down'};
  try{
    if(s.type==='xui'){
      const ok=_xuiCookieSet||(await xuiLogin());
      return {...base,state:ok?'up':'down'};
    }
    if(s.type==='http'&&s.path){
      const r=await Promise.race([
        fetch(s.path,{credentials:'include'}),
        new Promise((_,rej)=>setTimeout(()=>rej(),3500))
      ]);
      return {...base,state:r.ok||r.status<500?'up':'warn'};
    }
    // port: ใช้ no-cors fetch — ถ้าไม่ timeout แสดงว่า port เปิดอยู่
    if(s.type==='port'){
      const checks=await Promise.all(s.ports.map(async p=>{
        try{
          await Promise.race([
            fetch(`http://${HOST}:${p}/`,{method:'HEAD',mode:'no-cors'}),
            new Promise((_,rej)=>setTimeout(()=>rej(),2800))
          ]);
          return true;
        }catch{return false;}
      }));
      const up=checks.filter(Boolean).length;
      return {...base,state:up===s.ports.length?'up':up>0?'warn':'down'};
    }
  }catch(e){}
  return base;
}


/* ══════════════════════════════════════
   SNOWFLAKE CANVAS — เกล็ด 6 แฉก dendrite
══════════════════════════════════════ */
startSnow('snow-canvas', 32, false);

function doLogout(){
  sessionStorage.removeItem('chaiya_auth');
  window.location.replace('chaiya-login.html');
}

window.addEventListener('load',()=>{
  loadStats();
  loadServiceStatus();
  // auto-refresh stats every 30s
  setInterval(()=>{
    if(document.getElementById('tab-dash').classList.contains('active')){loadStats();loadServiceStatus();}
  },30000);
});
</script>
</body>
</html>

DASHV8EOF

# patch config.js และ paths ให้ตรงกับ nginx proxy
python3 << 'PYEOF'
with open('/opt/chaiya-panel/sshws.html','r') as f: c=f.read()
c=c.replace("const SSH_API = '/sshws-api';","const SSH_API = '/api';")
c=c.replace("window.location.replace('chaiya-login.html');","window.location.replace('index.html');")
c=c.replace("!s.user || !s.pass || Date.now()","!(s.token || (s.user && s.pass)) || Date.now()")
c=c.replace("ports:[54321]","ports:[2053]")
c=c.replace("path:SSH_API+'/api/status'","path:SSH_API+'/status'")
with open('/opt/chaiya-panel/sshws.html','w') as f: f.write(c)
print("patch OK")
PYEOF

chmod -R 755 /opt/chaiya-panel



# ── NGINX — HTTPS + reverse proxy ─────────────────────────────
info "ตั้งค่า Nginx สำหรับ HTTPS + domain..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
for f in /etc/nginx/sites-enabled/*; do
  [[ "$f" == *"chaiya"* ]] && continue
  [[ -f "$f" ]] && rm -f "$f" || true
done

# HTTP → HTTPS redirect
cat > /etc/nginx/sites-available/chaiya-http << EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf /etc/nginx/sites-available/chaiya-http /etc/nginx/sites-enabled/
nginx -t &>/dev/null && systemctl restart nginx

# ── ขอ SSL Certificate ─────────────────────────────────────────
apt-get install -y -qq python3-certbot-nginx 2>/dev/null || true
info "ขอ SSL Certificate สำหรับ $DOMAIN ..."
SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
USE_SSL=0

for _ssl_try in 1 2 3; do
  certbot certonly --nginx --non-interactive --agree-tos \
    --register-unsafely-without-email \
    -d "$DOMAIN" 2>&1 | tail -5
  if [[ -f "$SSL_CERT" ]]; then USE_SSL=1; break; fi
  certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos \
    --register-unsafely-without-email \
    -d "$DOMAIN" 2>&1 | tail -5
  if [[ -f "$SSL_CERT" ]]; then USE_SSL=1; break; fi
  [[ $_ssl_try -lt 3 ]] && { warn "SSL retry $_ssl_try/3..."; sleep 5; }
done

if [[ $USE_SSL -eq 1 ]]; then
  ok "SSL Certificate พร้อม"
else
  warn "SSL Certificate ไม่สำเร็จ — ใช้ HTTP แทนชั่วคราว (ต้องแก้ DNS ก่อน)"
fi

# ── NGINX HTTPS CONFIG ─────────────────────────────────────────
if [[ $USE_SSL -eq 1 ]]; then
cat > /etc/nginx/sites-available/chaiya << EOF
# HTTP → HTTPS redirect
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

# HTTPS — Panel หลัก
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root /opt/chaiya-panel;
    index index.html;

    # Static files
    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-store";
    }

    # SSH API proxy
    location /api/ {
        proxy_pass http://127.0.0.1:${SSH_API_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 30s;
        proxy_connect_timeout 5s;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }

    # 3x-ui proxy (ไม่โชว์พอร์ต)
    location /xui-api/ {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
    }
}
EOF
else
# HTTP fallback
cat > /etc/nginx/sites-available/chaiya << EOF
server {
    listen 80;
    server_name $DOMAIN _;
    root /opt/chaiya-panel;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-store";
    }
    location /api/ {
        proxy_pass http://127.0.0.1:${SSH_API_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 30s;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }
    location /xui-api/ {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Cookie \$http_cookie;
        proxy_read_timeout 60s;
    }
}
EOF
fi

rm -f /etc/nginx/sites-enabled/chaiya-http 2>/dev/null || true
ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/

# เพิ่ม port 2535 proxy → x-ui
grep -q "listen 2535" /etc/nginx/sites-available/chaiya 2>/dev/null || cat >> /etc/nginx/sites-available/chaiya << NGINXEOF

server {
    listen 2535 ssl http2;
    server_name $DOMAIN;
    ssl_certificate     $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    location / {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Cookie \$http_cookie;
        proxy_read_timeout 60s;
    }
}
NGINXEOF
ufw allow 2535/tcp &>/dev/null || true

nginx -t &>/dev/null && systemctl restart nginx && ok "Nginx พร้อม" || warn "Nginx มีปัญหา — ตรวจ: nginx -t"

# ── CERTBOT AUTO-RENEW ─────────────────────────────────────────
[[ $USE_SSL -eq 1 ]] && (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | sort -u | crontab -

# ── FIREWALL ──────────────────────────────────────────────────
info "ตั้งค่า Firewall..."
ufw --force reset &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
for port in 22 80 443 $DROPBEAR_PORT1 $DROPBEAR_PORT2 \
            $SSH_API_PORT $REAL_XUI_PORT $BADVPN_PORT $OPENVPN_PORT 8080 8880; do
  ufw allow $port/tcp &>/dev/null
done
ufw allow $BADVPN_PORT/udp &>/dev/null
ufw --force enable &>/dev/null
ok "Firewall พร้อม"

# ── CACHE INFO ────────────────────────────────────────────────
echo "$SERVER_IP" > /etc/chaiya/my_ip.conf
echo "$DOMAIN"    > /etc/chaiya/domain.conf
echo "$REAL_XUI_PORT" > /etc/chaiya/xui-port.conf

# ── MENU COMMAND ─────────────────────────────────────────────
info "ติดตั้ง menu command..."
cat > /usr/local/bin/menu << 'MENUEOF'
#!/bin/bash
G='\033[1;32m' C='\033[1;36m' Y='\033[1;33m' R='\033[0;31m' B='\033[1m' N='\033[0m'

DOMAIN=$(cat /etc/chaiya/domain.conf 2>/dev/null || echo "")
SERVER_IP=$(cat /etc/chaiya/my_ip.conf 2>/dev/null || curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
XUI_PORT=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")
XUI_USER=$(cat /etc/chaiya/xui-user.conf 2>/dev/null || echo "chaiya")
XUI_PASS=$(cat /etc/chaiya/xui-pass.conf 2>/dev/null || echo "chaiya")
SSH_API_PORT=2095
PANEL_PORT=443
DROPBEAR_PORT1=143
DROPBEAR_PORT2=109
BADVPN_PORT=7300

if [[ -n "$DOMAIN" ]]; then
  PANEL_URL="https://$DOMAIN"
  HOST_DISPLAY="$DOMAIN"
else
  PANEL_URL="http://$SERVER_IP"
  HOST_DISPLAY="$SERVER_IP"
fi

clear
echo ""
echo -e "${G}${B}╔══════════════════════════════════════════════╗${N}"
echo -e "${G}${B}║         CHAIYA VPN PANEL v4  🛸              ║${N}"
echo -e "${G}${B}╚══════════════════════════════════════════════╝${N}"
echo ""
echo -e "${B}  ┌─ 🌐 Server Info ────────────────────────────┐${N}"
echo -e "  │  IP  Server   : ${C}$SERVER_IP${N}"
echo -e "  │  Domain       : ${C}$HOST_DISPLAY${N}"
echo -e "  └──────────────────────────────────────────────┘"
echo ""
echo -e "${B}  ┌─ 🔗 Access URLs ─────────────────────────────┐${N}"
echo -e "  │  Panel URL    : ${C}${B}$PANEL_URL${N}"
echo -e "  │  3x-ui Panel  : ${C}https://$HOST_DISPLAY:2535${N}"
echo -e "  │  (via domain) : ${C}${PANEL_URL}/xui-api/${N}"
echo -e "  └──────────────────────────────────────────────┘"
echo ""
echo -e "${B}  ┌─ 🔑 Credentials ─────────────────────────────┐${N}"
echo -e "  │  3x-ui User   : ${Y}$XUI_USER${N}"
echo -e "  │  3x-ui Pass   : ${Y}$XUI_PASS${N}"
echo -e "  └──────────────────────────────────────────────┘"
echo ""
echo -e "${B}  ┌─ 🔌 Ports ───────────────────────────────────┐${N}"
echo -e "  │  HTTPS Panel  : ${C}443${N} (ผ่านโดเมน — ไม่โชว์พอร์ต)"
echo -e "  │  Dropbear SSH : ${C}$DROPBEAR_PORT1${N} , ${C}$DROPBEAR_PORT2${N}"
echo -e "  │  BadVPN UDPGW : ${C}$BADVPN_PORT${N}"
echo -e "  │  VMess-WS     : ${C}8080${N}  path: /chaiya"
echo -e "  │  VLESS-WS     : ${C}8880${N}  path: /chaiya"
echo -e "  │  SSH API      : ${C}$SSH_API_PORT${N} (ภายใน)"
echo -e "  └──────────────────────────────────────────────┘"
echo ""
echo -e "${B}  ┌─ 📌 สถานะ Services ─────────────────────────┐${N}"

_svc() {
  local name=$1 svc=$2
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "  │  ${G}✅ $name${N}"
  else
    echo -e "  │  ${R}❌ $name  (รัน: systemctl start $svc)${N}"
  fi
}

_svc "Nginx (HTTPS)"      "nginx"
_svc "3x-ui Panel"        "x-ui"
_svc "Dropbear SSH"       "dropbear"
_svc "SSH API"            "chaiya-ssh-api"
_svc "WS-Stunnel"         "chaiya-sshws"
_svc "BadVPN UDPGW"       "chaiya-badvpn"

# SSL status
SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
if [[ -f "$SSL_CERT" ]]; then
  EXP_DATE=$(openssl x509 -noout -enddate -in "$SSL_CERT" 2>/dev/null | sed 's/notAfter=//')
  echo -e "  │  ${G}🔒 SSL Certificate${N}: ${C}$EXP_DATE${N}"
else
  echo -e "  │  ${Y}⚠️  SSL Certificate${N}: ยังไม่มี (รัน: certbot --nginx -d $DOMAIN)"
fi

echo -e "  └──────────────────────────────────────────────┘"
echo ""
echo -e "  เปิด Panel ได้เลย: ${C}${B}$PANEL_URL${N}"
echo ""
echo -e "  ─────────────────────────────────────────────"
echo -e "  [P] เปลี่ยนรหัสผ่าน Panel Login"
echo -e "  ─────────────────────────────────────────────"
echo -ne "  กด P แล้ว Enter เพื่อเปลี่ยนรหัส (หรือ Enter เพื่อข้าม): "
read -r _choice
if [[ "$_choice" == "p" || "$_choice" == "P" ]]; then
  read -rsp "  รหัสผ่านใหม่: " _np; echo
  read -rsp "  ยืนยันรหัสผ่าน: " _np2; echo
  if [[ -z "$_np" ]]; then
    echo -e "  ${R}❌ รหัสผ่านห้ามว่าง${N}"
  elif [[ "$_np" != "$_np2" ]]; then
    echo -e "  ${R}❌ รหัสผ่านไม่ตรงกัน${N}"
  else
    echo -n "$_np" | python3 -c "import hashlib,sys; open('/etc/chaiya/panel-pass.hash','w').write(hashlib.sha256(sys.stdin.read().encode()).hexdigest())"
    echo -e "  ${G}✅ เปลี่ยนรหัสผ่านสำเร็จ${N}"
  fi
fi
echo ""
echo -e "${G}${B}════════════════════════════════════════════════${N}"
MENUEOF
chmod +x /usr/local/bin/menu
grep -q "alias menu=" /root/.bashrc 2>/dev/null || echo 'alias menu="/usr/local/bin/menu"' >> /root/.bashrc
source /root/.bashrc 2>/dev/null || true
ok "menu command พร้อม — พิมพ์ 'menu' เพื่อดูรายละเอียด"

# ── ทดสอบ API ─────────────────────────────────────────────────
echo ""
echo -n "  ทดสอบ SSH API... "
sleep 2
API_TEST=$(curl -s --max-time 5 http://127.0.0.1:$SSH_API_PORT/api/status 2>/dev/null)
if echo "$API_TEST" | grep -q '"ok"'; then
  echo -e "${GREEN}✅ API ทำงานปกติ${NC}"
else
  echo -e "${YELLOW}⚠️  API อาจยังไม่พร้อม — ลอง: systemctl restart chaiya-ssh-api${NC}"
fi

# ── SUMMARY ───────────────────────────────────────────────────
if [[ $USE_SSL -eq 1 ]]; then
  PANEL_URL_FINAL="https://$DOMAIN"
  SSL_STATUS="${GREEN}✅ HTTPS พร้อม${NC}"
else
  PANEL_URL_FINAL="http://$DOMAIN (ยังไม่มี SSL — แก้ DNS แล้วรัน: certbot --nginx -d $DOMAIN)"
  SSL_STATUS="${YELLOW}⚠️  HTTP เท่านั้น${NC}"
fi

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   CHAIYA VPN PANEL v4 - ติดตั้งสำเร็จ! 🚀  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  🌐 Panel URL      : ${CYAN}${BOLD}$PANEL_URL_FINAL${NC}"
echo -e "  🔒 SSL            : $SSL_STATUS"
echo -e "  🔑 Panel Password : ${YELLOW}$PANEL_PASS${NC}"
echo -e "  📊 3x-ui Panel    : ${CYAN}http://$SERVER_IP:$REAL_XUI_PORT${NC}"
echo -e "  👤 3x-ui Username : ${YELLOW}$XUI_USER${NC}"
echo -e "  🔒 3x-ui Password : ${YELLOW}$XUI_PASS${NC}"
echo -e "  🐻 Dropbear       : ${CYAN}port $DROPBEAR_PORT1, $DROPBEAR_PORT2${NC}"
echo -e "  🎮 BadVPN UDPGW   : ${CYAN}port $BADVPN_PORT${NC}"
echo -e "  📡 VMess-WS       : ${CYAN}port 8080, path /chaiya${NC}"
echo -e "  📡 VLESS-WS       : ${CYAN}port 8880, path /chaiya${NC}"
echo ""
echo -e "  💡 พิมพ์ ${CYAN}${BOLD}menu${NC} เพื่อดูรายละเอียดทั้งหมด"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
echo ""
