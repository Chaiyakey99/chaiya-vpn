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
mkdir -p /etc/dropbear
[[ ! -f /etc/dropbear/dropbear_rsa_host_key ]] && \
  dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null || true
[[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]] && \
  dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key 2>/dev/null || true

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
  [[ $_attempt -lt 3 ]] && sleep 3
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
  VMESS_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  VLESS_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  echo "$VMESS_UUID" > /etc/chaiya/vmess-uuid.conf
  echo "$VLESS_UUID" > /etc/chaiya/vless-uuid.conf
  chmod 600 /etc/chaiya/vmess-uuid.conf /etc/chaiya/vless-uuid.conf

  if ! echo "$EXISTING_PORTS" | grep -qw "8080"; then
    PAYLOAD=$(python3 -c "
import json
p = {
  'up':0,'down':0,'total':0,'remark':'CHAIYA-VMess-WS',
  'enable':True,'expiryTime':0,'listen':'','port':8080,'protocol':'vmess',
  'settings': json.dumps({
    'clients':[{'id':'${VMESS_UUID}','alterId':0,'email':'chaiya-default',
      'limitIpCount':2,'totalGB':0,'expiryTime':0,'enable':True,'tgId':'','subId':''}]
  }),
  'streamSettings': json.dumps({
    'network':'ws','security':'none',
    'wsSettings':{'path':'/chaiya','headers':{}}
  }),
  'sniffing': json.dumps({'enabled':True,'destOverride':['http','tls','quic','fakedns']}),
  'tag':'inbound-8080'
}
print(json.dumps(p))
")
    _add_inbound "$PAYLOAD"
    ok "VMess-WS inbound พร้อม (port 8080, path /chaiya)"
  else
    ok "VMess-WS มีอยู่แล้ว (port 8080)"
  fi

  if ! echo "$EXISTING_PORTS" | grep -qw "8880"; then
    PAYLOAD=$(python3 -c "
import json
p = {
  'up':0,'down':0,'total':0,'remark':'CHAIYA-VLESS-WS',
  'enable':True,'expiryTime':0,'listen':'','port':8880,'protocol':'vless',
  'settings': json.dumps({
    'clients':[{'id':'${VLESS_UUID}','flow':'','email':'chaiya-default',
      'limitIpCount':2,'totalGB':0,'expiryTime':0,'enable':True,'tgId':'','subId':''}],
    'decryption':'none','fallbacks':[]
  }),
  'streamSettings': json.dumps({
    'network':'ws','security':'none',
    'wsSettings':{'path':'/chaiya','headers':{}}
  }),
  'sniffing': json.dumps({'enabled':True,'destOverride':['http','tls','quic','fakedns']}),
  'tag':'inbound-8880'
}
print(json.dumps(p))
")
    _add_inbound "$PAYLOAD"
    ok "VLESS-WS inbound พร้อม (port 8880, path /chaiya)"
  else
    ok "VLESS-WS มีอยู่แล้ว (port 8880)"
  fi

  systemctl restart x-ui 2>/dev/null || true
  sleep 2
else
  warn "Login x-ui ไม่สำเร็จ — ข้าม inbound setup"
  VMESS_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  VLESS_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  echo "$VMESS_UUID" > /etc/chaiya/vmess-uuid.conf
  echo "$VLESS_UUID" > /etc/chaiya/vless-uuid.conf
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
<title>CHAIYA VPN PANEL — Login</title>
<script src="config.js"></script>
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@600;700&family=Kanit:wght@300;400;600&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<style>
:root{
  --bg:#070d14;--card:#0d1622;
  --border:rgba(255,255,255,.08);--border2:rgba(255,255,255,.13);
  --text:#e8f4ff;--text2:rgba(255,255,255,.45);--text3:rgba(255,255,255,.25);
  --green:#72d124;--blue:#7ee8fa;--purple:#a78bfa;--red:#f87171;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%}
body{
  background:var(--bg);color:var(--text);font-family:'Kanit',sans-serif;
  min-height:100vh;display:flex;flex-direction:column;
  align-items:center;justify-content:center;overflow:hidden;position:relative;
}
body::before{
  content:'';position:fixed;inset:0;pointer-events:none;
  background:
    radial-gradient(ellipse 70% 50% at 15% 40%,rgba(0,160,255,.055) 0%,transparent 65%),
    radial-gradient(ellipse 60% 50% at 85% 60%,rgba(160,0,255,.05) 0%,transparent 65%),
    radial-gradient(ellipse 80% 40% at 50% 100%,rgba(0,255,140,.04) 0%,transparent 60%);
  animation:ambientPulse 9s ease-in-out infinite alternate;
}
@keyframes ambientPulse{0%{opacity:.7}50%{opacity:1}100%{opacity:.6}}
body::after{
  content:'';position:fixed;inset:0;pointer-events:none;
  background-image:radial-gradient(rgba(126,232,250,.06) 1px,transparent 1px);
  background-size:32px 32px;
}
#snow-canvas{position:fixed;inset:0;pointer-events:none;z-index:1}
.login-wrap{position:relative;z-index:10;width:100%;max-width:380px;padding:1.2rem;}
.card-glow{
  position:absolute;inset:-1px;border-radius:27px;
  background:linear-gradient(135deg,rgba(126,232,250,.18),rgba(167,139,250,.12),rgba(114,209,36,.14),rgba(126,232,250,.18));
  background-size:300% 300%;
  animation:borderGlow 6s linear infinite;z-index:0;
}
@keyframes borderGlow{to{background-position:300% 300%}}
.login-card{
  position:relative;z-index:1;background:var(--card);border-radius:26px;
  padding:2.2rem 2rem 2rem;border:1px solid var(--border2);
  box-shadow:0 24px 60px rgba(0,0,0,.5),inset 0 1px 0 rgba(255,255,255,.06);
  animation:floatCard 6s ease-in-out infinite;
}
@keyframes floatCard{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}
.logo-area{text-align:center;margin-bottom:1.8rem}
.logo-badge{
  display:inline-flex;align-items:center;gap:.55rem;
  font-family:'Share Tech Mono',monospace;font-size:.58rem;
  letter-spacing:.38em;color:rgba(126,232,250,.5);margin-bottom:.8rem;
}
.logo-icon{
  width:64px;height:64px;border-radius:18px;
  background:linear-gradient(135deg,#0f1f0a,#1a3512);
  border:1px solid rgba(114,209,36,.25);
  display:flex;align-items:center;justify-content:center;
  margin:0 auto .9rem;
  box-shadow:0 0 0 6px rgba(114,209,36,.06),0 8px 24px rgba(0,0,0,.3);
  font-size:1.8rem;position:relative;overflow:hidden;
}
.logo-title{
  font-family:'Rajdhani',sans-serif;font-size:1.9rem;font-weight:700;
  letter-spacing:.1em;color:var(--text);line-height:1;
}
.logo-title .rgb{
  background:linear-gradient(90deg,#7ee8fa,#a78bfa,#80ff72,#7ee8fa);
  background-size:250% auto;
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;
  background-clip:text;animation:rgbFlow 4s linear infinite;
}
@keyframes rgbFlow{to{background-position:250% center}}
.logo-sub{font-family:'Share Tech Mono',monospace;font-size:.65rem;color:var(--text3);letter-spacing:.1em;margin-top:.35rem;}
.server-strip{
  display:flex;align-items:center;justify-content:center;gap:.5rem;
  background:rgba(255,255,255,.03);border:1px solid var(--border);border-radius:10px;
  padding:.5rem .8rem;margin-bottom:1.4rem;
  font-family:'Share Tech Mono',monospace;font-size:.65rem;color:var(--text3);
}
.server-dot{
  width:6px;height:6px;border-radius:50%;background:#22c55e;
  box-shadow:0 0 5px rgba(34,197,94,.6);animation:pingDot 2s infinite;flex-shrink:0;
}
@keyframes pingDot{0%,100%{opacity:1}50%{opacity:.35}}
.form-group{margin-bottom:1rem;position:relative}
.form-label{
  display:flex;align-items:center;gap:.35rem;
  font-family:'Share Tech Mono',monospace;font-size:.62rem;
  letter-spacing:.12em;text-transform:uppercase;color:var(--text2);margin-bottom:.45rem;
}
.input-wrap{position:relative}
.input-icon{position:absolute;left:.9rem;top:50%;transform:translateY(-50%);font-size:.95rem;pointer-events:none;}
.form-input{
  width:100%;background:rgba(255,255,255,.04);border:1.5px solid rgba(255,255,255,.1);
  border-radius:12px;padding:.72rem .9rem .72rem 2.6rem;color:var(--text);
  font-family:'Kanit',sans-serif;font-size:.92rem;outline:none;
  transition:border-color .2s,box-shadow .2s,background .2s;
}
.form-input::placeholder{color:var(--text3)}
.form-input:focus{
  background:rgba(255,255,255,.07);border-color:rgba(126,232,250,.4);
  box-shadow:0 0 0 3px rgba(126,232,250,.08),inset 0 1px 0 rgba(255,255,255,.04);
}
.eye-btn{
  position:absolute;right:.9rem;top:50%;transform:translateY(-50%);
  background:none;border:none;cursor:pointer;color:var(--text3);font-size:1rem;
  padding:.2rem;transition:color .2s;
}
.eye-btn:hover{color:var(--text2)}
.login-btn{
  width:100%;margin-top:.4rem;padding:.88rem;border:none;border-radius:13px;
  font-family:'Rajdhani',sans-serif;font-size:1.06rem;font-weight:700;
  letter-spacing:.14em;cursor:pointer;position:relative;overflow:hidden;
  background:linear-gradient(135deg,#1a3a10,#2d6016,#3d8018);color:#d4f8a0;
  box-shadow:0 4px 20px rgba(72,160,20,.25),inset 0 1px 0 rgba(255,255,255,.1);
  transition:all .22s;
}
.login-btn:hover{box-shadow:0 6px 28px rgba(72,160,20,.38);transform:translateY(-1px);}
.login-btn:active{transform:translateY(0)}
.login-btn:disabled{opacity:.5;cursor:not-allowed;transform:none}
.btn-inner{position:relative;z-index:1;display:flex;align-items:center;justify-content:center;gap:.5rem}
.spin-ring{
  display:inline-block;width:16px;height:16px;
  border:2px solid rgba(255,255,255,.25);border-top-color:rgba(255,255,255,.8);
  border-radius:50%;animation:spin .7s linear infinite;
}
@keyframes spin{to{transform:rotate(360deg)}}
.login-alert{
  display:none;margin-top:.85rem;padding:.65rem .9rem;border-radius:10px;
  font-size:.8rem;line-height:1.5;text-align:center;
}
.login-alert.err{background:rgba(248,113,113,.1);border:1px solid rgba(248,113,113,.25);color:#fca5a5;}
.login-alert.ok{background:rgba(114,209,36,.1);border:1px solid rgba(114,209,36,.25);color:#a3e635;}
.login-footer{
  text-align:center;margin-top:1.5rem;font-family:'Share Tech Mono',monospace;
  font-size:.6rem;color:var(--text3);letter-spacing:.06em;line-height:1.8;
}
.login-footer .dot{margin:0 .3rem;color:rgba(126,232,250,.2)}
@keyframes shake{
  0%,100%{transform:translateX(0)}20%{transform:translateX(-6px)}
  40%{transform:translateX(6px)}60%{transform:translateX(-4px)}80%{transform:translateX(4px)}
}
.shake{animation:shake .4s ease-in-out!important}
</style>
</head>
<body>
<canvas id="snow-canvas"></canvas>
<div class="login-wrap">
  <div class="card-glow"></div>
  <div class="login-card" id="login-card">
    <div class="logo-area">
      <div class="logo-badge">CHAIYA VPN PANEL v4</div>
      <div class="logo-icon">🛡️</div>
      <div class="logo-title">ADMIN <span class="rgb">PANEL</span></div>
      <div class="logo-sub">SSH + V2Ray Management System</div>
    </div>
    <div class="server-strip">
      <span class="server-dot"></span>
      <span id="srv-host">กำลังเชื่อมต่อ...</span>
    </div>
    <div class="form-group">
      <div class="form-label">🔑 Panel Password</div>
      <div class="input-wrap">
        <span class="input-icon">🔑</span>
        <input type="password" id="inp-pass" class="form-input"
          placeholder="••••••••" autocomplete="current-password"
          onkeydown="if(event.key==='Enter')doLogin()"
          style="padding-right:2.8rem">
        <button class="eye-btn" id="eye-btn" onclick="toggleEye()" type="button">👁</button>
      </div>
    </div>
    <button class="login-btn" id="login-btn" onclick="doLogin()">
      <span class="btn-inner" id="btn-inner">⚡ เข้าสู่ระบบ</span>
    </button>
    <div class="login-alert" id="login-alert"></div>
    <div class="login-footer">
      <span id="login-time">--</span>
      <span class="dot">·</span>CHAIYA VPN SYSTEM<span class="dot">·</span>v4.0
    </div>
  </div>
</div>
<script>
const CFG = (typeof window.CHAIYA_CONFIG !== 'undefined') ? window.CHAIYA_CONFIG : {};
const HOST = CFG.domain || CFG.host || location.hostname;
const SESSION_KEY = 'chaiya_auth';
const DASHBOARD = 'sshws.html';

window.addEventListener('load', () => {
  const saved = sessionStorage.getItem(SESSION_KEY);
  if (saved) {
    try {
      const s = JSON.parse(saved);
      if (s.token && Date.now() < s.exp) { window.location.replace(DASHBOARD); return; }
    } catch(e) {}
    sessionStorage.removeItem(SESSION_KEY);
  }
  document.getElementById('srv-host').textContent = 'https://' + HOST;
  updateClock();
  setInterval(updateClock, 1000);
  document.getElementById('inp-pass').focus();
  startSnow();
});

function updateClock() {
  document.getElementById('login-time').textContent =
    new Date().toLocaleTimeString('th-TH', {hour:'2-digit',minute:'2-digit',second:'2-digit'});
}

let eyeOpen = false;
function toggleEye() {
  eyeOpen = !eyeOpen;
  document.getElementById('inp-pass').type = eyeOpen ? 'text' : 'password';
  document.getElementById('eye-btn').textContent = eyeOpen ? '🙈' : '👁';
}

async function doLogin() {
  const pass = document.getElementById('inp-pass').value;
  if (!pass) return showAlert('กรุณาใส่ Password', 'err');
  setLoading(true); hideAlert();
  try {
    const res = await Promise.race([
      fetch('/api/verify', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({password: pass})
      }),
      new Promise((_,rej) => setTimeout(() => rej(new Error('Connection timeout')), 8000))
    ]);
    const data = await res.json();
    if (data.ok) {
      sessionStorage.setItem(SESSION_KEY, JSON.stringify({
        token: btoa(pass), exp: Date.now() + 8 * 3600 * 1000
      }));
      showAlert('✅ เข้าสู่ระบบสำเร็จ กำลัง redirect...', 'ok');
      setTimeout(() => window.location.replace(DASHBOARD), 900);
    } else {
      throw new Error('Password ไม่ถูกต้อง');
    }
  } catch(e) {
    showAlert('❌ ' + e.message, 'err');
    const card = document.getElementById('login-card');
    card.classList.remove('shake'); void card.offsetWidth; card.classList.add('shake');
    setTimeout(() => card.classList.remove('shake'), 450);
    document.getElementById('inp-pass').style.borderColor = 'rgba(248,113,113,.5)';
    setTimeout(() => { document.getElementById('inp-pass').style.borderColor = ''; }, 1500);
  } finally { setLoading(false); }
}

function setLoading(on) {
  const btn = document.getElementById('login-btn');
  const inner = document.getElementById('btn-inner');
  btn.disabled = on;
  inner.innerHTML = on ? '<span class="spin-ring"></span> กำลังตรวจสอบ...' : '⚡ เข้าสู่ระบบ';
}
function showAlert(msg, type) {
  const el = document.getElementById('login-alert');
  el.textContent = msg; el.className = 'login-alert ' + type; el.style.display = 'block';
}
function hideAlert() { document.getElementById('login-alert').style.display = 'none'; }

function startSnow() {
  const canvas = document.getElementById('snow-canvas');
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  function resize() { canvas.width = window.innerWidth; canvas.height = window.innerHeight; }
  resize(); window.addEventListener('resize', resize);
  const COLORS = ['rgba(180,230,255,','rgba(200,255,220,','rgba(220,200,255,','rgba(255,210,240,'];
  const COUNT = 38; const flakes = [];
  function rnd(a,b){return Math.random()*(b-a)+a}
  function mkFlake(){return{x:rnd(0,canvas.width),y:rnd(-20,canvas.height),size:rnd(4,10),
    speed:rnd(.2,.55),drift:rnd(-.25,.25),rot:rnd(0,Math.PI),rotSpeed:rnd(-.018,.018),
    color:COLORS[Math.floor(Math.random()*COLORS.length)],opacity:rnd(.2,.55)}}
  for(let i=0;i<COUNT;i++)flakes.push(mkFlake());
  function drawFlake(f){
    ctx.save();ctx.translate(f.x,f.y);ctx.rotate(f.rot);
    ctx.strokeStyle=f.color+f.opacity+')';ctx.lineWidth=1.1;ctx.lineCap='round';
    const s=f.size;
    for(let i=0;i<4;i++){
      ctx.save();ctx.rotate(i*Math.PI/4);
      ctx.beginPath();ctx.moveTo(0,-s);ctx.lineTo(0,s);ctx.stroke();
      const b=s*.42;
      ctx.beginPath();ctx.moveTo(-b,-s*.48);ctx.lineTo(0,-s*.48+b*.5);ctx.lineTo(b,-s*.48);ctx.stroke();
      ctx.restore();
    }
    ctx.beginPath();ctx.arc(0,0,1.5,0,Math.PI*2);
    ctx.fillStyle=f.color+Math.min(f.opacity+.25,1)+')';ctx.fill();ctx.restore();
  }
  function tick(){
    ctx.clearRect(0,0,canvas.width,canvas.height);
    flakes.forEach(f=>{
      f.y+=f.speed;f.x+=f.drift;f.rot+=f.rotSpeed;
      if(f.y>canvas.height+20)Object.assign(f,mkFlake(),{y:-10,x:rnd(0,canvas.width)});
      drawFlake(f);
    });
    requestAnimationFrame(tick);
  }
  tick();
}
</script>
</body>
</html>
LOGINEOF
ok "Login page พร้อม"

# ── DASHBOARD (sshws.html) ─────────────────────────────────────
# Copy dashboard HTML + patch config
info "สร้าง Dashboard..."
cp /opt/chaiya-panel/index.html /opt/chaiya-panel/index.html.bak 2>/dev/null || true

# สร้าง dashboard จาก template ที่ฝังใน script
cat > /opt/chaiya-panel/sshws.html.tmp << 'DASHEOF'
PLACEHOLDER_DASHBOARD
DASHEOF

# ถ้ามี original dashboard ให้ copy มา ไม่มีให้ใช้ basic version
DASH_SRC=""
for f in /tmp/chaiya-dashboard.html /root/chaiya-user-creator-v8.html; do
  [[ -f "$f" ]] && DASH_SRC="$f" && break
done

if [[ -n "$DASH_SRC" ]]; then
  cp "$DASH_SRC" /opt/chaiya-panel/sshws.html
  # แทรก config.js ถ้ายังไม่มี
  grep -q 'config.js' /opt/chaiya-panel/sshws.html || \
    sed -i 's|<head>|<head>\n<script src="config.js"></script>|' /opt/chaiya-panel/sshws.html
  # แก้ XUI_API ให้ผ่าน nginx proxy
  sed -i "s|const XUI_API.*=.*['\"].*['\"]|const XUI_API = '/xui-api'|g" /opt/chaiya-panel/sshws.html
  sed -i "s|const SSH_API.*=.*['\"].*['\"]|const SSH_API = '/api'|g" /opt/chaiya-panel/sshws.html
  ok "Dashboard จาก original file"
else
  # สร้าง basic dashboard
  cat > /opt/chaiya-panel/sshws.html << 'BASICDASH'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA VPN PANEL — Dashboard</title>
<script src="config.js"></script>
<style>
:root{--bg:#070d14;--card:#0d1622;--border:rgba(255,255,255,.1);--text:#e8f4ff;
  --green:#72d124;--cyan:#7ee8fa;--red:#f87171;--muted:rgba(255,255,255,.4)}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:sans-serif;min-height:100vh;padding:1.5rem}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:1.5rem;
  padding:.8rem 1.2rem;background:var(--card);border-radius:12px;border:1px solid var(--border)}
h1{font-size:1.1rem;color:var(--cyan)}
.logout-btn{background:rgba(248,113,113,.15);color:var(--red);border:1px solid rgba(248,113,113,.3);
  border-radius:8px;padding:.35rem .8rem;font-size:.75rem;cursor:pointer}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:1rem;margin-bottom:1.5rem}
.stat{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:1rem;text-align:center}
.stat .val{font-size:2rem;font-weight:900;color:var(--cyan)}
.stat .lbl{font-size:.72rem;color:var(--muted);margin-top:.3rem}
.card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:1.2rem;margin-bottom:1rem}
.card h2{font-size:.9rem;color:var(--cyan);margin-bottom:1rem}
.form-row{display:flex;gap:.8rem;flex-wrap:wrap;margin-bottom:.8rem}
.form-row input{flex:1;min-width:120px;background:rgba(255,255,255,.05);border:1px solid var(--border);
  border-radius:8px;padding:.55rem .8rem;color:var(--text);font-size:.85rem;outline:none}
.btn{padding:.55rem 1.1rem;border:none;border-radius:8px;font-size:.82rem;font-weight:700;
  cursor:pointer;background:linear-gradient(135deg,var(--green),var(--cyan));color:#0a1a0a}
table{width:100%;border-collapse:collapse;font-size:.8rem}
th,td{padding:.5rem .6rem;text-align:left;border-bottom:1px solid var(--border)}
th{color:var(--muted);font-size:.68rem}
.del{background:rgba(248,113,113,.15);color:var(--red);border:1px solid rgba(248,113,113,.3);
  border-radius:6px;padding:.2rem .5rem;font-size:.68rem;cursor:pointer}
.badge-ok{color:var(--green)}.badge-off{color:var(--red)}
.alert{padding:.6rem .8rem;border-radius:8px;font-size:.8rem;margin-top:.6rem;display:none}
.alert.ok{background:rgba(114,209,36,.1);border:1px solid rgba(114,209,36,.3);color:#a3e635}
.alert.err{background:rgba(248,113,113,.1);border:1px solid rgba(248,113,113,.3);color:#fca5a5}
</style>
</head>
<body>
<div class="header">
  <h1>🛸 CHAIYA VPN PANEL</h1>
  <button class="logout-btn" onclick="doLogout()">Logout</button>
</div>
<div class="grid">
  <div class="stat"><div class="val" id="s-conn">-</div><div class="lbl">CONNECTIONS</div></div>
  <div class="stat"><div class="val" id="s-users">-</div><div class="lbl">TOTAL USERS</div></div>
  <div class="stat"><div class="val" id="s-online">-</div><div class="lbl">ONLINE</div></div>
  <div class="stat"><div class="val" id="s-svcs">-</div><div class="lbl">SERVICES OK</div></div>
</div>
<div class="card">
  <h2>➕ เพิ่ม SSH User</h2>
  <div class="form-row">
    <input id="new-user" placeholder="username (a-z0-9)">
    <input type="password" id="new-pass" placeholder="password">
    <input type="number" id="new-days" value="30" style="max-width:80px">
  </div>
  <button class="btn" onclick="createUser()">➕ สร้าง User</button>
  <div class="alert" id="u-alert"></div>
</div>
<div class="card">
  <h2>👤 รายชื่อ Users <button class="btn" style="float:right;font-size:.7rem" onclick="loadUsers()">🔄 Refresh</button></h2>
  <div id="user-table"><div style="color:var(--muted);text-align:center;padding:1rem">กำลังโหลด...</div></div>
</div>
<div class="card">
  <h2>⚙️ Services</h2>
  <div id="svc-list"><div style="color:var(--muted)">กำลังตรวจสอบ...</div></div>
</div>
<script>
(function(){
  const k='chaiya_auth';
  const s=sessionStorage.getItem(k);
  if(!s){window.location.replace('index.html');return;}
  try{const p=JSON.parse(s);if(!p.token||Date.now()>=p.exp){sessionStorage.removeItem(k);window.location.replace('index.html');}}
  catch(e){sessionStorage.removeItem(k);window.location.replace('index.html');}
})();

const CFG=(typeof window.CHAIYA_CONFIG!=='undefined')?window.CHAIYA_CONFIG:{};

async function api(method,path,body){
  const r=await fetch('/api'+path,{
    method,headers:{'Content-Type':'application/json'},
    body:body?JSON.stringify(body):undefined
  });
  return r.json();
}

async function loadDash(){
  const d=await api('GET','/status').catch(()=>({ok:false}));
  if(d.ok){
    document.getElementById('s-conn').textContent=d.connections||0;
    document.getElementById('s-users').textContent=d.total_users||0;
    document.getElementById('s-online').textContent=d.online||0;
    const svcs=d.services||{};
    const ok=Object.values(svcs).filter(Boolean).length;
    document.getElementById('s-svcs').textContent=ok+'/'+Object.keys(svcs).length;
    const sl=document.getElementById('svc-list');
    sl.innerHTML=Object.entries(svcs).map(([k,v])=>
      `<div style="display:flex;justify-content:space-between;padding:.4rem 0;border-bottom:1px solid var(--border)">
        <span>${k}</span><span class="${v?'badge-ok':'badge-off'}">${v?'✅ RUNNING':'❌ STOPPED'}</span>
      </div>`).join('');
  }
}

async function loadUsers(){
  const d=await api('GET','/users').catch(()=>({users:[]}));
  const users=d.users||[];
  const t=document.getElementById('user-table');
  if(!users.length){t.innerHTML='<div style="color:var(--muted);text-align:center;padding:1rem">ไม่มี users</div>';return;}
  t.innerHTML='<table><tr><th>Username</th><th>Exp</th><th>Status</th><th></th></tr>'+
    users.map(u=>`<tr>
      <td>${u.user}</td>
      <td>${u.exp||'-'}</td>
      <td><span class="${u.active?'badge-ok':'badge-off'}">${u.active?'✅ Active':'❌ Expired'}</span></td>
      <td><button class="del" onclick="delUser('${u.user}')">🗑 ลบ</button></td>
    </tr>`).join('')+'</table>';
}

async function createUser(){
  const user=document.getElementById('new-user').value.trim();
  const pass=document.getElementById('new-pass').value;
  const days=parseInt(document.getElementById('new-days').value)||30;
  const al=document.getElementById('u-alert');
  if(!user||!pass){al.textContent='กรุณาใส่ Username และ Password';al.className='alert err';al.style.display='block';return;}
  const d=await api('POST','/create',{user,pass,days});
  al.style.display='block';
  if(d.ok){
    al.textContent='✅ สร้าง '+user+' สำเร็จ (หมดอายุ '+d.exp+')';
    al.className='alert ok';
    document.getElementById('new-user').value='';
    document.getElementById('new-pass').value='';
    loadUsers();
  }else{al.textContent='❌ '+(d.error||'ล้มเหลว');al.className='alert err';}
}

async function delUser(user){
  if(!confirm('ลบ '+user+'?'))return;
  const d=await api('POST','/delete',{user});
  if(d.ok)loadUsers();else alert('ลบไม่ได้: '+(d.error||''));
}

function doLogout(){
  sessionStorage.removeItem('chaiya_auth');
  window.location.replace('index.html');
}

loadDash();loadUsers();
setInterval(loadDash,30000);
</script>
</body>
</html>
BASICDASH
  ok "Dashboard (basic) พร้อม"
fi

rm -f /opt/chaiya-panel/sshws.html.tmp
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
info "ขอ SSL Certificate สำหรับ $DOMAIN ..."
certbot certonly --nginx --non-interactive --agree-tos \
  --register-unsafely-without-email \
  -d "$DOMAIN" 2>&1 | tail -5 || \
certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos \
  --register-unsafely-without-email \
  -d "$DOMAIN" 2>&1 | tail -5

SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [[ -f "$SSL_CERT" ]]; then
  ok "SSL Certificate พร้อม"
  USE_SSL=1
else
  warn "SSL Certificate ไม่สำเร็จ — ใช้ HTTP แทนชั่วคราว (ต้องแก้ DNS ก่อน)"
  USE_SSL=0
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
    listen 443 ssl;
    http2 on;
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
echo -e "  │  3x-ui Panel  : ${C}http://$SERVER_IP:$XUI_PORT${N}"
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
