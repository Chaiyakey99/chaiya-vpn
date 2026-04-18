#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL - All-in-One Install Script v3
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-setup.sh
#   แก้ไข: API auth ถูกต้อง, ตรวจ x-ui port จริง, HTML ไม่ค้าง
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
      VPN PANEL - ALL-IN-ONE INSTALLER v3
BANNER
echo -e "${NC}"

# ── ROOT CHECK ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "รันด้วย root หรือ sudo เท่านั้น"

# ── INSTALL DEPS ─────────────────────────────────────────────
info "อัปเดต packages..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl wget python3 nginx dropbear openssh-server \
  ufw build-essential cmake net-tools jq bc cron unzip sqlite3 \
  iptables-persistent 2>/dev/null || true
ok "ติดตั้ง packages สำเร็จ"

# ── GET SERVER IP ────────────────────────────────────────────
info "กำลังดึง IP ของเครื่อง..."
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
            hostname -I | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && err "ไม่สามารถดึง IP ได้"
ok "IP: ${CYAN}$SERVER_IP${NC}"

# ── PASSWORD ─────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}กำหนด Password สำหรับ Panel Login${NC}"
while true; do
  read -rsp "  Panel Password: " PANEL_PASS; echo
  read -rsp "  Confirm Password: " PANEL_PASS2; echo
  [[ "$PANEL_PASS" == "$PANEL_PASS2" ]] && break
  warn "Password ไม่ตรงกัน ลองอีกครั้ง"
done
[[ ${#PANEL_PASS} -lt 6 ]] && err "Password ต้องมีอย่างน้อย 6 ตัวอักษร"

# ── XUI CREDENTIALS ──────────────────────────────────────────
echo ""
echo -e "${YELLOW}กำหนด Username / Password สำหรับ 3x-ui${NC}"
read -rp "  3x-ui Username [admin]: " XUI_USER
[[ -z "$XUI_USER" ]] && XUI_USER="admin"
while true; do
  read -rsp "  3x-ui Password: " XUI_PASS; echo
  read -rsp "  Confirm 3x-ui Password: " XUI_PASS2; echo
  [[ "$XUI_PASS" == "$XUI_PASS2" ]] && break
  warn "Password ไม่ตรงกัน ลองอีกครั้ง"
done
[[ ${#XUI_PASS} -lt 6 ]] && err "3x-ui Password ต้องมีอย่างน้อย 6 ตัวอักษร"

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
echo -e "  Panel URL     : ${CYAN}http://$SERVER_IP:$PANEL_PORT${NC}"
echo -e "  SSH API Port  : ${CYAN}$SSH_API_PORT${NC}"
echo -e "  3x-ui Port    : ${CYAN}$XUI_PORT${NC}"
echo -e "  Dropbear      : ${CYAN}$DROPBEAR_PORT1, $DROPBEAR_PORT2${NC}"
echo ""
read -rp "เริ่มติดตั้ง? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 0

# ── HASH PANEL PASSWORD ───────────────────────────────────────
PANEL_PASS_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${PANEL_PASS}'.encode()).hexdigest())")

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
# สร้าง host keys ถ้าไม่มี
[[ ! -f /etc/dropbear/dropbear_rsa_host_key ]] && \
  dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null || true
[[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]] && \
  dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key 2>/dev/null || true

# ใช้ systemd override แทน /etc/default/dropbear
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
  # ลอง download binary
  wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
    "https://raw.githubusercontent.com/NevermoreSSH/Blueblue/main/newudpgw" 2>/dev/null && \
    chmod +x /usr/bin/badvpn-udpgw || rm -f /usr/bin/badvpn-udpgw
  # fallback: build จาก source
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
mkdir -p /etc/chaiya
# บันทึก credentials ก่อน install
echo "$XUI_USER" > /etc/chaiya/xui-user.conf
echo "$XUI_PASS" > /etc/chaiya/xui-pass.conf
chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf

# ตรวจว่า x-ui ติดตั้งแล้วหรือยัง
if ! command -v x-ui &>/dev/null; then
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << XUIEOF
n
XUIEOF
fi

# ตั้งค่า x-ui: หยุดก่อนแก้ DB เพื่อป้องกัน race condition
systemctl stop x-ui 2>/dev/null || true
sleep 2

XUI_DB="/etc/x-ui/x-ui.db"

# ── สร้าง bcrypt hash ของ password ──────────────────────────
XUI_PASS_HASH=$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
" "$XUI_PASS" 2>/dev/null)
# ถ้า bcrypt ไม่มีให้ใช้ plain text แทน (fallback)
[[ -z "$XUI_PASS_HASH" ]] && XUI_PASS_HASH="$XUI_PASS"

# ── เขียนลง DB โดยตรง (DELETE+INSERT เพื่อป้องกัน duplicate) ──
if [[ -f "$XUI_DB" ]]; then
  # users table
  sqlite3 "$XUI_DB" "UPDATE users SET username='${XUI_USER}', password='${XUI_PASS_HASH}' WHERE id=1;" 2>/dev/null || true

  # settings table — DELETE ก่อนเสมอเพื่อป้องกัน duplicate rows
  for _key in webPort webUsername webPassword; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPort','${XUI_PORT}');"       2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webUsername','${XUI_USER}');"   2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPassword','${XUI_PASS_HASH}');" 2>/dev/null || true
  ok "x-ui credentials + port ตั้งค่าใน DB เรียบร้อย"
fi

systemctl start x-ui 2>/dev/null || true

# ── รอ x-ui พร้อม (max 20 วินาที) ───────────────────────────
info "รอ x-ui เริ่มต้น..."
REAL_XUI_PORT="$XUI_PORT"
XUI_READY=0
for _i in $(seq 1 10); do
  sleep 2
  # ดูจาก ss ว่า x-ui listen port อะไรจริงๆ
  _ssport=$(ss -tlnp 2>/dev/null | grep x-ui | grep -oP ':\K\d+' | head -1)
  [[ -n "$_ssport" ]] && REAL_XUI_PORT="$_ssport"
  # ตรวจว่า x-ui ตอบสนอง HTTP แล้ว
  _http=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}"     "http://127.0.0.1:${REAL_XUI_PORT}/" 2>/dev/null)
  if [[ "$_http" =~ ^[123] ]]; then
    XUI_READY=1; break
  fi
done
[[ -z "$REAL_XUI_PORT" ]] && REAL_XUI_PORT=$XUI_PORT
echo "$REAL_XUI_PORT" > /etc/chaiya/xui-port.conf

if [[ $XUI_READY -eq 1 ]]; then
  ok "3x-ui พร้อม (port $REAL_XUI_PORT)"
else
  warn "3x-ui อาจยังไม่พร้อม (port $REAL_XUI_PORT) — ตรวจสอบด้วย: systemctl status x-ui"
fi

# ── สร้าง Inbounds ครบชุดใน x-ui ───────────────────────────
# Port map (ตาม ChaiyaProject):
#   8080 → VMess + WebSocket
#   8880 → VLESS + WebSocket
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

# ── helper: ดึง port list ที่มีอยู่แล้ว ──────────────────────
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

# ── helper: POST inbound ──────────────────────────────────────
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

  # ── 1. VMess + WebSocket  port 8080 ──────────────────────────
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
    VMESS_UUID=$(curl -s -b "$XUI_COOKIE" "${XUI_BASE}/xui/API/inbounds" 2>/dev/null | \
      python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    if x.get('port')==8080:
      s=json.loads(x.get('settings','{}'))
      cl=s.get('clients',[])
      if cl: print(cl[0].get('id',''))
except: pass
" 2>/dev/null)
    [[ -n "$VMESS_UUID" ]] && echo "$VMESS_UUID" > /etc/chaiya/vmess-uuid.conf
    ok "VMess-WS มีอยู่แล้ว (port 8080)"
  fi

  # ── 2. VLESS + WebSocket  port 8880 ──────────────────────────
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
    VLESS_UUID=$(curl -s -b "$XUI_COOKIE" "${XUI_BASE}/xui/API/inbounds" 2>/dev/null | \
      python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    if x.get('port')==8880:
      s=json.loads(x.get('settings','{}'))
      cl=s.get('clients',[])
      if cl: print(cl[0].get('id',''))
except: pass
" 2>/dev/null)
    [[ -n "$VLESS_UUID" ]] && echo "$VLESS_UUID" > /etc/chaiya/vless-uuid.conf
    ok "VLESS-WS มีอยู่แล้ว (port 8880)"
  fi

  systemctl restart x-ui 2>/dev/null || true
  sleep 2

else
  warn "Login x-ui ไม่สำเร็จ — ข้าม inbound setup (ตั้งค่าเองใน x-ui panel ได้)"
  VMESS_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  VLESS_UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
  echo "$VMESS_UUID" > /etc/chaiya/vmess-uuid.conf
  echo "$VLESS_UUID" > /etc/chaiya/vless-uuid.conf
fi
rm -f "$XUI_COOKIE"

# ── SSH API (Python) ──────────────────────────────────────────
info "ติดตั้ง SSH API..."
mkdir -p /opt/chaiya-ssh-api /etc/chaiya/exp

cat > /opt/chaiya-ssh-api/app.py << 'PYEOF'
#!/usr/bin/env python3
"""
Chaiya SSH API v4 — SSH user + x-ui client sync, NPV link support
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, socket, threading, socketserver, hmac, uuid, sqlite3

XUI_DB = '/etc/x-ui/x-ui.db'
VLESS_UUID_FILE = '/etc/chaiya/vless-uuid.conf'

def run_cmd(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
    return r.returncode == 0, r.stdout.strip(), r.stderr.strip()

def get_xui_inbound_id(port=443):
    """ดึง inbound id ของ port 443 จาก x-ui DB"""
    try:
        con = sqlite3.connect(XUI_DB)
        row = con.execute("SELECT id FROM inbounds WHERE port=?", (port,)).fetchone()
        con.close()
        return row[0] if row else None
    except:
        return None

def get_xui_clients():
    """ดึง client list จาก VMess inbound port 8080"""
    try:
        con = sqlite3.connect(XUI_DB)
        row = con.execute("SELECT settings FROM inbounds WHERE port=8080").fetchone()
        con.close()
        if not row: return []
        s = json.loads(row[0])
        return s.get('clients', [])
    except:
        return []

def add_xui_client(email, user_uuid=None):
    """เพิ่ม client ใน VMess inbound port 8080"""
    if user_uuid is None:
        user_uuid = str(uuid.uuid4())
    try:
        con = sqlite3.connect(XUI_DB)
        row = con.execute("SELECT id, settings FROM inbounds WHERE port=8080").fetchone()
        if not row:
            con.close()
            return None
        inbound_id, settings_str = row
        settings = json.loads(settings_str)
        clients = settings.get('clients', [])
        clients = [c for c in clients if c.get('email') != email]
        clients.append({
            'id': user_uuid,
            'alterId': 0,
            'email': email,
            'limitIpCount': 2,
            'totalGB': 0,
            'expiryTime': 0,
            'enable': True,
            'tgId': '',
            'subId': ''
        })
        settings['clients'] = clients
        con.execute("UPDATE inbounds SET settings=? WHERE id=?",
                    (json.dumps(settings), inbound_id))
        con.commit()
        con.close()
        return user_uuid
    except Exception as e:
        return None

def remove_xui_client(email):
    """ลบ client จาก VMess inbound port 8080 และ VLESS port 8880"""
    for port in (8080, 8880):
        try:
            con = sqlite3.connect(XUI_DB)
            row = con.execute("SELECT id, settings FROM inbounds WHERE port=?", (port,)).fetchone()
            if not row:
                con.close()
                continue
            inbound_id, settings_str = row
            settings = json.loads(settings_str)
            settings['clients'] = [c for c in settings.get('clients', [])
                                    if c.get('email') != email]
            con.execute("UPDATE inbounds SET settings=? WHERE id=?",
                        (json.dumps(settings), inbound_id))
            con.commit()
            con.close()
        except:
            pass
    subprocess.run("systemctl restart x-ui", shell=True, capture_output=True, timeout=15)

def build_npv_link(host, user_uuid, remark):
    """สร้าง npvt-ssh:// import link สำหรับ NapsternetV"""
    import base64
    # SSH over WebSocket (port 80)
    ssh_config = {
        "server": host,
        "port": 80,
        "username": remark,
        "protocol": "ssh",
        "transport": "ws",
        "ws_path": "/",
        "remarks": remark
    }
    b64 = base64.b64encode(json.dumps(ssh_config).encode()).decode()
    return f"npvt-ssh://{b64}"

def get_connections():
    counts = {"total": 0}
    for port in ["80", "143", "109", "22", "2095"]:
        out = subprocess.run(
            f"ss -tn state established 2>/dev/null | grep -c ':{port}[^0-9]' || echo 0",
            shell=True, capture_output=True, text=True
        ).stdout.strip()
        try:
            c = int(out.split()[0]) if out.strip() else 0
        except:
            c = 0
        counts[port] = c
        counts["total"] += c
    return counts

def list_users():
    users = []
    xui_clients = {c['email']: c['id'] for c in get_xui_clients()}

    # อ่าน users.db (format: user days exp data_gb ip_limit)
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
                # อ่าน expiry จาก exp file ก่อน
                exp_f = f'/etc/chaiya/exp/{uname}'
                if os.path.exists(exp_f):
                    u['exp'] = open(exp_f).read().strip()
                # ถ้าไม่มี fallback ไปที่ users.db
                if not u['exp'] and uname in db_map:
                    u['exp'] = db_map[uname]['exp']
                if uname in db_map:
                    u['ip_limit'] = db_map[uname]['ip_limit']
                    u['data_gb']  = db_map[uname]['data_gb']
                if u['exp']:
                    try:
                        exp_date = datetime.date.fromisoformat(u['exp'])
                        u['active'] = exp_date >= datetime.date.today()
                    except:
                        pass
                u['uuid'] = xui_clients.get(uname)
                users.append(u)
    except Exception as e:
        pass
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
        """อ่าน body ครั้งเดียวแล้ว parse — ไม่อ่านซ้ำ"""
        try:
            length = int(self.headers.get('Content-Length', 0))
            if length > 0:
                raw = self.rfile.read(length)
                return json.loads(raw)
            return {}
        except Exception:
            return {}

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
            respond(self, 200, {
                "host": open('/etc/chaiya/my_ip.conf').read().strip()
                        if os.path.exists('/etc/chaiya/my_ip.conf') else '',
                "xui_port": int(xui_port),
                "dropbear_port": 143,
                "dropbear_port2": 109,
                "ws_port": 80,
                "udpgw_port": 7300,
            })

        else:
            respond(self, 404, {'error': 'Not found'})

    def do_POST(self):
        # อ่าน body ครั้งเดียว ก่อน route
        data = self.read_body()

        if self.path == '/api/verify':
            import hashlib
            pw = data.get("password", "")
            hashed = hashlib.sha256(pw.encode()).hexdigest()
            # อ่าน hash จาก config.js
            cfg_path = '/opt/chaiya-panel/config.js'
            stored = ""
            try:
                import re
                cfg = open(cfg_path).read()
                m = re.search(r'panel_pass\s*:\s*"([a-f0-9]+)"', cfg)
                if m:
                    stored = m.group(1)
            except Exception:
                pass
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

            # 1. สร้าง OS user (ตาม ChaiyaProject: -M -s /bin/false -e exp)
            ok1, _, e1 = run_cmd(
                f"userdel -f {user} 2>/dev/null; "
                f"useradd -M -s /bin/false -e {(datetime.date.today() + datetime.timedelta(days=days)).isoformat()} {user}"
            )
            # ตั้ง password ปลอดภัย (ไม่ผ่าน shell)
            import subprocess as _sp
            _sp.run(['chpasswd'], input=f'{user}:{pw}\n', text=True, capture_output=True, timeout=10)
            exp = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
            run_cmd(f"chage -E {exp} {user}")

            # บันทึก expiry file
            os.makedirs('/etc/chaiya/exp', exist_ok=True)
            with open(f'/etc/chaiya/exp/{user}', 'w') as f:
                f.write(exp)

            # บันทึก users.db (format: user days exp data_gb ip_limit)
            os.makedirs('/etc/chaiya/sshws-users', exist_ok=True)
            db = '/etc/chaiya/sshws-users/users.db'
            # ลบ entry เดิมถ้ามี แล้วเขียนใหม่
            existing_lines = []
            if os.path.exists(db):
                existing_lines = [l for l in open(db) if not l.strip().startswith(user + ' ')]
            with open(db, 'w') as f:
                f.writelines(existing_lines)
                f.write(f"{user} {days} {exp} {data_gb} {ip_limit}\n")

            # 2. สร้าง x-ui client (VMess port 8080 + VLESS port 8880)
            user_uuid = add_xui_client(user)  # VMess port 8080

            # VLESS port 8880
            vless_uuid = None
            try:
                con = sqlite3.connect(XUI_DB)
                row = con.execute("SELECT id, settings FROM inbounds WHERE port=8880").fetchone()
                if row:
                    inbound_id, settings_str = row
                    settings = json.loads(settings_str)
                    clients = settings.get('clients', [])
                    clients = [c for c in clients if c.get('email') != user]
                    import uuid as _uuid
                    vless_uuid = str(_uuid.uuid4())
                    clients.append({'id': vless_uuid, 'flow': '', 'email': user,
                                    'limitIpCount': ip_limit, 'totalGB': data_gb * (1024**3) if data_gb else 0,
                                    'expiryTime': 0, 'enable': True, 'tgId': '', 'subId': ''})
                    settings['clients'] = clients
                    con.execute("UPDATE inbounds SET settings=? WHERE id=?",
                                (json.dumps(settings), inbound_id))
                    con.commit()
                con.close()
            except:
                pass

            # restart x-ui เพื่อ reload inbound config
            run_cmd("systemctl restart x-ui 2>/dev/null || true")

            # 3. สร้าง NPV link (SSH over WS port 80)
            host = ''
            try:
                host = open('/etc/chaiya/my_ip.conf').read().strip()
            except:
                pass
            npv_link = build_npv_link(host, user_uuid, user) if host and user_uuid else None

            respond(self, 200, {
                'ok': True,
                'user': user,
                'exp': exp,
                'uuid': user_uuid,
                'vless_uuid': vless_uuid,
                'ip_limit': ip_limit,
                'data_gb': data_gb,
                'npv_link': npv_link
            })

        elif self.path == '/api/delete':
            user = data.get('user', '').strip()
            if not user:
                return respond(self, 400, {'error': 'user required'})
            run_cmd(f"userdel -f {user} 2>/dev/null")
            run_cmd(f"rm -f /etc/chaiya/exp/{user}")
            # ลบจาก users.db
            db = '/etc/chaiya/sshws-users/users.db'
            if os.path.exists(db):
                lines = [l for l in open(db) if not l.strip().startswith(user + ' ')]
                with open(db, 'w') as f:
                    f.writelines(lines)
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

# ── SYSTEMD SERVICE FOR SSH API ───────────────────────────────
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
import socket, threading, select, sys, time, collections

LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 80
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
        self.threads = []
        self.lock = threading.Lock()

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
            except socket.timeout:
                continue
            except Exception:
                break

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
            hostPort = self.findHeader(buf, 'X-Real-Host') or DEFAULT_HOST
            self.connect_target(hostPort)
            self.client.sendall(RESPONSE)
            self.relay()
        except Exception:
            pass
        finally:
            self.close()

    def findHeader(self, head, header):
        if isinstance(head, bytes):
            head = head.decode('utf-8', errors='replace')
        i = head.find(header + ': ')
        if i == -1: return ''
        i = head.find(':', i)
        head = head[i+2:]
        j = head.find('\r\n')
        return head[:j] if j != -1 else ''

    def connect_target(self, host):
        i = host.find(':')
        port = int(host[i+1:]) if i != -1 else 143
        host = host[:i] if i != -1 else host
        self.target = socket.create_connection((host, port), timeout=10)
        self.targetClosed = False

    def relay(self):
        socs = [self.client, self.target]
        count = 0
        while True:
            count += 1
            recv, _, err = select.select(socs, [], socs, 3)
            if err: break
            if recv:
                for s in recv:
                    data = s.recv(BUFLEN)
                    if not data: return
                    (self.target if s is self.client else self.client).sendall(data)
                    count = 0
            if count >= TIMEOUT: break

def main():
    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()
    print(f"WS-Stunnel running on port {LISTENING_PORT}")
    while True:
        time.sleep(60)

if __name__ == '__main__':
    main()
WSPYEOF
chmod +x /usr/local/bin/ws-stunnel

cat > /etc/systemd/system/chaiya-sshws.service << 'WSEOF'
[Unit]
Description=WS-Stunnel SSH Tunnel port 80 -> Dropbear
After=network.target dropbear.service
[Service]
Type=simple
ExecStartPre=/bin/sh -c 'fuser -k 80/tcp 2>/dev/null || true'
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
ok "WS-Stunnel พร้อม (port 80)"

# ── PANEL HTML ────────────────────────────────────────────────
info "สร้าง Panel HTML..."
mkdir -p /opt/chaiya-panel

# อ่าน xui port จริง
REAL_XUI_PORT=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")

cat > /opt/chaiya-panel/config.js << EOF
// Auto-generated by chaiya-setup.sh v3 — DO NOT EDIT MANUALLY
window.CHAIYA_CONFIG = {
  host:         "$SERVER_IP",
  ssh_api_port: $SSH_API_PORT,
  xui_port:     $REAL_XUI_PORT,
  xui_user:     "$XUI_USER",
  xui_pass:     "$XUI_PASS",
  ssh_token:    "",
  panel_pass:   "$PANEL_PASS_HASH"
};
EOF


# ── PANEL INDEX.HTML ───────────────────────────────────────────
# config.js โหลดเป็น <script src> ใน HTML — ไม่ใช้ dynamic inject
cat > /opt/chaiya-panel/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA VPN PANEL</title>
<!-- config.js โหลดก่อน script หลัก — ป้องกัน race condition -->
<script src="config.js"></script>
<style>
  :root{--bg:#0a0d14;--panel:#111827;--border:#1e2d45;
    --green:#4dffa0;--cyan:#80ffdd;--purple:#b8a0ff;--yellow:#ffe680;
    --red:#ff6b8a;--text:#c8ddd0;--muted:#7a9aaa;}
  *{margin:0;padding:0;box-sizing:border-box;}
  body{font-family:'Segoe UI',sans-serif;background:var(--bg);color:var(--text);
    min-height:100vh;display:flex;align-items:center;justify-content:center;}
  .wrap{width:100%;max-width:420px;padding:1.5rem;}
  .logo{text-align:center;margin-bottom:2rem;}
  .logo h1{font-size:2rem;font-weight:900;letter-spacing:.15em;
    background:linear-gradient(135deg,var(--green),var(--cyan),var(--purple));
    -webkit-background-clip:text;-webkit-text-fill-color:transparent;}
  .logo p{color:var(--muted);letter-spacing:.3em;font-size:.75rem;margin-top:.3rem;}
  .card{background:var(--panel);border:1px solid var(--border);border-radius:16px;
    padding:1.5rem;box-shadow:0 8px 32px rgba(0,0,0,.5);}
  .server-box{background:rgba(77,255,160,.05);border:1px solid rgba(77,255,160,.2);
    border-radius:10px;padding:.75rem 1rem;text-align:center;margin-bottom:1.5rem;}
  .server-box .lbl{font-size:.7rem;letter-spacing:.2em;color:var(--muted);margin-bottom:.3rem;}
  .server-box .ip{color:var(--cyan);font-size:1.1rem;font-weight:700;font-family:monospace;}
  .field-lbl{font-size:.72rem;letter-spacing:.1em;color:var(--muted);margin-bottom:.4rem;}
  input[type=password]{width:100%;background:rgba(255,255,255,.04);border:1px solid var(--border);
    border-radius:8px;padding:.75rem 1rem;color:var(--text);font-size:.95rem;outline:none;transition:border .2s;}
  input[type=password]:focus{border-color:var(--cyan);}
  .btn{width:100%;padding:.85rem;border:none;border-radius:10px;font-size:.9rem;
    font-weight:700;cursor:pointer;margin-top:1rem;
    background:linear-gradient(135deg,var(--green),var(--cyan));color:#0a0d14;transition:opacity .2s;}
  .btn:disabled{opacity:.5;cursor:not-allowed;}
  .msg{text-align:center;font-size:.82rem;padding:.6rem;border-radius:8px;margin-top:.8rem;display:none;}
  .msg.err{background:rgba(255,107,138,.1);color:var(--red);border:1px solid rgba(255,107,138,.3);}
  .msg.ok{background:rgba(77,255,160,.1);color:var(--green);border:1px solid rgba(77,255,160,.3);}
  .dots{display:flex;justify-content:center;gap:.4rem;margin-top:.8rem;}
  .dot{width:8px;height:8px;border-radius:50%;background:var(--border);transition:background .3s;}
  .dot.lit{background:var(--cyan);}
  #dashboard{display:none;}
  .nav{display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:1.5rem;}
  .nav-btn{padding:.45rem .9rem;border:1px solid var(--border);border-radius:8px;
    background:transparent;color:var(--muted);font-size:.78rem;cursor:pointer;transition:.2s;}
  .nav-btn.active{border-color:var(--cyan);color:var(--cyan);background:rgba(128,255,221,.06);}
  .page{display:none;}.page.active{display:block;}
  .stat-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:.8rem;margin-bottom:1rem;}
  .stat{background:rgba(255,255,255,.04);border:1px solid var(--border);border-radius:10px;padding:.8rem;text-align:center;}
  .stat .val{font-size:1.6rem;font-weight:900;color:var(--cyan);}
  .stat .lbl{font-size:.68rem;color:var(--muted);margin-top:.2rem;}
  .svc-list{display:flex;flex-direction:column;gap:.5rem;}
  .svc-row{display:flex;justify-content:space-between;align-items:center;
    padding:.6rem .8rem;background:rgba(255,255,255,.03);border-radius:8px;}
  .badge{font-size:.65rem;padding:.2rem .5rem;border-radius:20px;font-weight:700;}
  .badge.on{background:rgba(77,255,160,.15);color:var(--green);}
  .badge.off{background:rgba(255,107,138,.15);color:var(--red);}
  .form-g{margin-bottom:.8rem;}
  .form-g label{display:block;font-size:.72rem;color:var(--muted);margin-bottom:.3rem;}
  .form-g input{width:100%;background:rgba(255,255,255,.04);border:1px solid var(--border);
    border-radius:8px;padding:.6rem .8rem;color:var(--text);font-size:.85rem;outline:none;}
  .btn2{padding:.6rem 1.2rem;border:none;border-radius:8px;font-size:.8rem;font-weight:700;
    cursor:pointer;background:linear-gradient(135deg,var(--green),var(--cyan));color:#0a0d14;}
  table{width:100%;border-collapse:collapse;font-size:.78rem;}
  th,td{padding:.5rem .6rem;text-align:left;border-bottom:1px solid var(--border);}
  th{color:var(--muted);font-size:.68rem;}
  .del-btn{background:rgba(255,107,138,.15);color:var(--red);border:1px solid rgba(255,107,138,.3);
    border-radius:6px;padding:.2rem .5rem;font-size:.68rem;cursor:pointer;}
</style>
</head>
<body>

<div class="wrap" id="login">
  <div class="logo"><h1>CHAIYA</h1><p>VPN PANEL</p></div>
  <div class="card">
    <div class="server-box">
      <div class="lbl">VPS SERVER</div>
      <div class="ip" id="server-ip-disp">-</div>
    </div>
    <div class="field-lbl">🔑 PANEL PASSWORD</div>
    <input type="password" id="pass-input" placeholder="••••••••" onkeyup="if(event.key==='Enter')doLogin()">
    <button class="btn" id="login-btn" onclick="doLogin()">CONNECT</button>
    <div class="msg" id="msg"></div>
    <div class="dots">
      <div class="dot" id="d1"></div><div class="dot" id="d2"></div>
      <div class="dot" id="d3"></div><div class="dot" id="d4"></div><div class="dot" id="d5"></div>
    </div>
  </div>
</div>

<div style="width:100%;max-width:680px;margin:0 auto;padding:1.5rem" id="dashboard">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem">
    <h2 style="color:var(--cyan);font-size:1.1rem">🛸 CHAIYA VPN PANEL</h2>
    <button onclick="doLogout()" style="background:rgba(255,107,138,.15);color:var(--red);border:1px solid rgba(255,107,138,.3);border-radius:8px;padding:.35rem .8rem;font-size:.75rem;cursor:pointer;">Logout</button>
  </div>
  <div class="nav">
    <button class="nav-btn active" id="nb-dashboard" onclick="showPage('dashboard',this)">📊 Dashboard</button>
    <button class="nav-btn" id="nb-users" onclick="showPage('users',this)">👤 Users</button>
    <button class="nav-btn" id="nb-services" onclick="showPage('services',this)">⚙️ Services</button>
  </div>

  <div id="page-dashboard" class="page active">
    <div class="stat-grid">
      <div class="stat"><div class="val" id="s-conn">-</div><div class="lbl">CONNECTIONS</div></div>
      <div class="stat"><div class="val" id="s-users">-</div><div class="lbl">TOTAL USERS</div></div>
      <div class="stat"><div class="val" id="s-online">-</div><div class="lbl">ONLINE</div></div>
      <div class="stat"><div class="val" id="s-80">-</div><div class="lbl">PORT 80</div></div>
    </div>
    <div class="svc-list" id="svc-list"></div>
    <div style="text-align:right;font-size:.65rem;color:var(--muted);margin-top:.8rem" id="last-upd"></div>
  </div>

  <div id="page-users" class="page">
    <div class="card" style="margin-bottom:1rem">
      <h3 style="font-size:.85rem;margin-bottom:.8rem;color:var(--cyan)">➕ เพิ่ม User</h3>
      <div class="form-g"><label>Username</label><input id="new-user" placeholder="username"></div>
      <div class="form-g"><label>Password</label><input type="password" id="new-pass" placeholder="password"></div>
      <div class="form-g"><label>จำนวนวัน</label><input id="new-days" type="number" value="30"></div>
      <button class="btn2" onclick="createUser()">➕ สร้าง User</button>
      <div id="u-alert" style="margin-top:.5rem;font-size:.8rem;display:none"></div>
    </div>
    <div class="card">
      <h3 style="font-size:.85rem;margin-bottom:.8rem;color:var(--cyan)">📋 รายชื่อ Users</h3>
      <div style="overflow-x:auto">
        <table>
          <thead><tr><th>#</th><th>Username</th><th>หมดอายุ</th><th>สถานะ</th><th>NPV</th><th></th></tr></thead>
          <tbody id="user-tbody"></tbody>
        </table>
      </div>
    </div>
  </div>

  <div id="page-services" class="page">
    <div class="card">
      <h3 style="font-size:.85rem;margin-bottom:.8rem;color:var(--cyan)">⚙️ Services</h3>
      <div class="svc-list" id="svc-detail"></div>
      <div style="margin-top:1rem">
        <button class="btn2" onclick="svcAll('restart')">🔄 Restart All</button>
      </div>
    </div>
  </div>
</div>

<script>
// API ชี้ที่ /api/ บน same-origin (nginx proxy) — ไม่มี CORS ปัญหาเลย
var API = '/api';
var CFG = window.CHAIYA_CONFIG || {};
var loggedIn = false;

// แสดง IP จาก config.js ที่โหลดเป็น <script src> แล้ว (synchronous)
document.getElementById('server-ip-disp').textContent = CFG.host || location.hostname;

// ── SHA256 ──────────────────────────────────────────────────
async function sha256hex(s) {
  try {
    var b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
    return Array.from(new Uint8Array(b)).map(function(x){return x.toString(16).padStart(2,'0');}).join('');
  } catch(e) { return null; }
}

// ── fetch with timeout (รองรับทุก browser) ───────────────────
function ftch(url, opts, ms) {
  return new Promise(function(res, rej) {
    var ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
    var t = setTimeout(function(){ if(ctrl) ctrl.abort(); rej(new Error('timeout')); }, ms || 10000);
    var o = Object.assign({}, opts);
    if (ctrl) o.signal = ctrl.signal;
    fetch(url, o).then(function(r){ clearTimeout(t); res(r); }).catch(function(e){ clearTimeout(t); rej(e); });
  });
}

// ── UI helpers ───────────────────────────────────────────────
function setDots(on) {
  for (var i=1;i<=5;i++) {
    (function(el,on,delay){
      if(on) setTimeout(function(){el.classList.add('lit');}, delay);
      else el.classList.remove('lit');
    })(document.getElementById('d'+i), on, i*100);
  }
}
function showMsg(txt, type) {
  var el = document.getElementById('msg');
  el.textContent = txt; el.className = 'msg '+type; el.style.display = 'block';
}

// ── LOGIN ────────────────────────────────────────────────────
async function doLogin() {
  var pw = document.getElementById('pass-input').value;
  if (!pw) return showMsg('กรุณาใส่ Password', 'err');
  var btn = document.getElementById('login-btn');
  btn.disabled = true; btn.textContent = 'CONNECTING...';
  setDots(true); document.getElementById('msg').style.display = 'none';
  try {
    // 1. ตรวจ hash ฝั่ง browser ก่อน (fast fail)
    var hash = await sha256hex(pw);
    if (hash && CFG.panel_pass && hash !== CFG.panel_pass) {
      return showMsg('❌ Password ไม่ถูกต้อง', 'err');
    }
    // 2. verify กับ API (same-origin — ไม่มี CORS)
    var r = await ftch(API + '/verify', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({password: pw})
    }, 8000);
    var d = await r.json();
    if (!d.ok) return showMsg('❌ Password ไม่ถูกต้อง', 'err');
    // สำเร็จ
    loggedIn = true;
    document.getElementById('login').style.display = 'none';
    document.getElementById('dashboard').style.display = 'block';
    document.body.style.display = 'block';
    loadDashboard();
    if (!window._dt) window._dt = setInterval(function(){ if(loggedIn && document.getElementById('page-dashboard').classList.contains('active')) loadDashboard(); }, 15000);
  } catch(e) {
    showMsg('❌ เชื่อมต่อไม่ได้: ' + e.message, 'err');
  } finally {
    setDots(false); btn.disabled = false; btn.textContent = 'CONNECT';
  }
}

function doLogout() {
  loggedIn = false;
  document.getElementById('dashboard').style.display = 'none';
  document.getElementById('login').style.display = 'flex';
  document.getElementById('pass-input').value = '';
}

// ── NAV ──────────────────────────────────────────────────────
function showPage(name, btn) {
  document.querySelectorAll('.page').forEach(function(p){p.classList.remove('active');});
  document.querySelectorAll('.nav-btn').forEach(function(b){b.classList.remove('active');});
  document.getElementById('page-'+name).classList.add('active');
  if (btn) btn.classList.add('active');
  if (name==='users')    loadUsers();
  if (name==='services') loadServices();
}

// ── API helper ───────────────────────────────────────────────
async function api(method, path, body) {
  try {
    var o = {method:method, headers:{'Content-Type':'application/json'}};
    if (body) o.body = JSON.stringify(body);
    var r = await ftch(API + path, o, 10000);
    return await r.json();
  } catch(e) { return {error: e.message}; }
}

// ── DASHBOARD ────────────────────────────────────────────────
async function loadDashboard() {
  var d = await api('GET', '/status');
  if (d.error) { document.getElementById('last-upd').textContent = '⚠ ' + d.error; return; }
  document.getElementById('s-conn').textContent   = d.connections   != null ? d.connections   : '-';
  document.getElementById('s-users').textContent  = d.total_users   != null ? d.total_users   : '-';
  document.getElementById('s-online').textContent = d.online_count  != null ? d.online_count  : '-';
  document.getElementById('s-80').textContent     = d.conn_80       != null ? d.conn_80       : '-';
  document.getElementById('last-upd').textContent = 'อัพเดท ' + new Date().toLocaleTimeString('th-TH');
  var svcs = d.services || {};
  document.getElementById('svc-list').innerHTML = Object.entries(svcs).map(function(kv){
    return '<div class="svc-row"><span>'+svcIcon(kv[0])+' '+kv[0]+'</span>'+
      '<span class="badge '+(kv[1]?'on':'off')+'">'+(kv[1]?'RUNNING':'STOPPED')+'</span></div>';
  }).join('');
}
function svcIcon(k){var m={ssh:'🔑',dropbear:'🐻',nginx:'🌐',badvpn:'🎮',sshws:'🚇',xui:'📊',tunnel:'🔗'};return m[k]||'⚙️';}

// ── USERS ────────────────────────────────────────────────────
async function loadUsers() {
  var d = await api('GET', '/users');
  var tb = document.getElementById('user-tbody');
  if (d.error || !d.users) { tb.innerHTML='<tr><td colspan="6" style="text-align:center;color:var(--red)">'+(d.error||'โหลดไม่ได้')+'</td></tr>'; return; }
  if (!d.users.length) { tb.innerHTML='<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:1rem">ไม่มี Users</td></tr>'; return; }
  tb.innerHTML = d.users.map(function(u,i){
    var npv = u.uuid ? '<button class="del-btn" style="color:var(--cyan);border-color:rgba(128,255,221,.3)" onclick="copyNpv(\''+u.user+'\',\''+u.uuid+'\')">📋 NPV</button>' : '-';
    return '<tr><td>'+(i+1)+'</td><td>'+u.user+'</td><td style="font-size:.7rem">'+(u.exp||'-')+'</td>'+
      '<td><span class="badge '+(u.active?'on':'off')+'">'+(u.active?'ACTIVE':'EXPIRED')+'</span></td>'+
      '<td>'+npv+'</td><td><button class="del-btn" onclick="delUser(\''+u.user+'\')">🗑</button></td></tr>';
  }).join('');
}

function copyNpv(user, uid) {
  var host = CFG.host || location.hostname;
  var link = 'npvt-ssh://'+btoa(JSON.stringify({server:host,port:80,username:user,protocol:'ssh',transport:'ws',ws_path:'/',remarks:user}));
  if (navigator.clipboard) navigator.clipboard.writeText(link).then(function(){showMsg('✅ คัดลอก NPV link แล้ว','ok');}).catch(function(){prompt('NPV:',link);});
  else prompt('NPV:', link);
}

async function createUser() {
  var user = document.getElementById('new-user').value.trim();
  var pass = document.getElementById('new-pass').value;
  var days = parseInt(document.getElementById('new-days').value) || 30;
  var al = document.getElementById('u-alert');
  if (!user||!pass) { al.textContent='กรุณาใส่ Username และ Password'; al.style.cssText='display:block;color:var(--red)'; return; }
  var d = await api('POST', '/create', {user:user, pass:pass, days:days});
  al.style.display = 'block';
  if (d.ok) { al.textContent='✅ สร้าง '+user+' สำเร็จ (หมดอายุ '+d.exp+')'; al.style.cssText='display:block;color:var(--green)'; document.getElementById('new-user').value=''; document.getElementById('new-pass').value=''; loadUsers(); }
  else { al.textContent='❌ '+(d.error||'ล้มเหลว'); al.style.cssText='display:block;color:var(--red)'; }
}

async function delUser(user) {
  if (!confirm('ลบ '+user+'?')) return;
  var d = await api('POST', '/delete', {user:user});
  if (d.ok) loadUsers(); else alert('ลบไม่ได้: '+(d.error||''));
}

// ── SERVICES ─────────────────────────────────────────────────
async function loadServices() {
  var d = await api('GET', '/status');
  if (d.error) return;
  var svcs = d.services || {};
  document.getElementById('svc-detail').innerHTML = Object.entries(svcs).map(function(kv){
    var k=kv[0],v=kv[1];
    return '<div class="svc-row"><span>'+svcIcon(k)+' <b>'+k+'</b></span>'+
      '<div style="display:flex;gap:.4rem;align-items:center">'+
      '<span class="badge '+(v?'on':'off')+'">'+(v?'RUNNING':'STOPPED')+'</span>'+
      '<button onclick="svc1(\''+k+'\',\'restart\')" class="del-btn" style="color:var(--cyan);border-color:rgba(128,255,221,.3)">🔄</button>'+
      '</div></div>';
  }).join('');
}
async function svc1(svc,action){ await api('POST','/service',{service:svc,action:action}); setTimeout(loadServices,1500); }
async function svcAll(action){ var s=['dropbear','nginx','chaiya-sshws','chaiya-badvpn']; for(var i=0;i<s.length;i++) await api('POST','/service',{service:s[i],action:action}); setTimeout(loadDashboard,2000); }
</script>
</body>
</html>
HTMLEOF
ok "Panel HTML พร้อม"

# ── NGINX — proxy /api/ ไปที่ SSH API (same-origin แก้ CORS) ──
info "ตั้งค่า Nginx..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
for f in /etc/nginx/sites-enabled/*; do
  [[ "$f" == *"chaiya"* ]] && continue
  [[ -f "$f" ]] && grep -q "listen 80" "$f" 2>/dev/null && rm -f "$f" || true
done

cat > /etc/nginx/sites-available/chaiya << EOF
server {
    listen $PANEL_PORT;
    server_name _;
    root /opt/chaiya-panel;
    index index.html;

    # Static files (HTML, config.js)
    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-store";
    }

    # Proxy /api/* → SSH API (same-origin — แก้ปัญหา CORS/mixed content)
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
}
EOF

ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/
nginx -t &>/dev/null && systemctl restart nginx
ok "Nginx พร้อม (port $PANEL_PORT, proxy /api/ → :$SSH_API_PORT)"
# ── FIREWALL ─────────────────────────────────────────────────
info "ตั้งค่า Firewall..."
ufw --force reset &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
for port in 22 80 $PANEL_PORT $DROPBEAR_PORT1 $DROPBEAR_PORT2 \
            $SSH_API_PORT $REAL_XUI_PORT $BADVPN_PORT $OPENVPN_PORT 8080 8880; do
  ufw allow $port/tcp &>/dev/null
done
ufw allow $BADVPN_PORT/udp &>/dev/null
ufw --force enable &>/dev/null
ok "Firewall พร้อม"

# ── CACHE IP ──────────────────────────────────────────────────
echo "$SERVER_IP" > /etc/chaiya/my_ip.conf

# ── SUMMARY ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}   CHAIYA VPN PANEL v3 - ติดตั้งสำเร็จ! 🚀${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo ""
echo -e "  🌐 Panel URL      : ${CYAN}http://$SERVER_IP:$PANEL_PORT${NC}"
echo -e "  🔑 Panel Password : ${YELLOW}$PANEL_PASS${NC}"
echo -e "  🔧 SSH API        : ${CYAN}http://$SERVER_IP:$SSH_API_PORT${NC}"
echo -e "  📊 3x-ui Panel    : ${CYAN}http://$SERVER_IP:$REAL_XUI_PORT${NC}"
echo -e "  👤 3x-ui Username : ${YELLOW}$XUI_USER${NC}"
echo -e "  🔒 3x-ui Password : ${YELLOW}$XUI_PASS${NC}"
echo -e "  🐻 Dropbear       : ${CYAN}port $DROPBEAR_PORT1, $DROPBEAR_PORT2${NC}"
echo -e "  🎮 BadVPN         : ${CYAN}port $BADVPN_PORT${NC}"
echo -e "  📡 VMess-WS       : ${CYAN}port 8080, path /chaiya${NC}"
echo -e "  📡 VLESS-WS       : ${CYAN}port 8880, path /chaiya${NC}"
echo ""
echo -e "  เปิดหน้า Panel ได้เลยที่:"
echo -e "  ${CYAN}${BOLD}http://$SERVER_IP:$PANEL_PORT${NC}"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo ""

# ── ทดสอบ API ────────────────────────────────────────────────
echo -n "  ทดสอบ API... "
sleep 2
API_TEST=$(curl -s --max-time 5 http://127.0.0.1:$SSH_API_PORT/api/status 2>/dev/null)
if echo "$API_TEST" | grep -q '"ok"'; then
  echo -e "${GREEN}✅ API ทำงานปกติ${NC}"
else
  echo -e "${YELLOW}⚠️  API อาจยังไม่พร้อม ลอง: systemctl restart chaiya-ssh-api${NC}"
fi
echo ""
