#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL v5
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-setup-v5.sh
#   แก้ทุกปัญหาจาก v4:
#   - nginx ไม่ชนกัน (port แยกชัดเจน ไม่มี SSL block ถ้าไม่มี cert)
#   - dashboard auto-login ทุกครั้งที่โหลด ไม่ง้อ sessionStorage
#   - บันทึก xui credentials ลง config.js ให้ถูกต้อง
# ============================================================

# ── SELF-DOWNLOAD GUARD ──────────────────────────────────────
# ป้องกัน heredoc truncation เมื่อรันผ่าน bash <(curl ...)
# ถ้ารันจาก process substitution (fd แทนที่จะเป็นไฟล์จริง) ให้ดาวน์โหลดก่อน
if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$0" == "bash" ]]; then
  _SELF=$(mktemp /tmp/chaiya-setup-XXXXX.sh)
  # หา URL จาก cmdline หรือใช้ GitHub ตรง
  _URL="https://raw.githubusercontent.com/Chaiyakey99/chaiya-vpn/main/chaiya-setup-v5.sh"
  echo "[INFO] ดาวน์โหลด script ลงไฟล์ชั่วคราวก่อนรัน..."
  if curl -fsSL --max-time 60 "$_URL" -o "$_SELF" 2>/dev/null && [[ -s "$_SELF" ]]; then
    chmod +x "$_SELF"
    exec bash "$_SELF" "$@"
  else
    echo "[WARN] ดาวน์โหลดไม่สำเร็จ — รันต่อจาก stream (อาจมีปัญหา heredoc)"
    rm -f "$_SELF"
  fi
fi

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

cat << 'BANNER'
  ██████╗██╗  ██╗ █████╗ ██╗██╗   ██╗ █████╗
 ██╔════╝██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══██╗
 ██║     ███████║███████║██║ ╚████╔╝ ███████║
 ██║     ██╔══██║██╔══██║██║  ╚██╔╝  ██╔══██║
 ╚██████╗██║  ██║██║  ██║██║   ██║   ██║  ██║
  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝
       VPN PANEL v5 - ALL-IN-ONE INSTALLER
BANNER

[[ $EUID -ne 0 ]] && err "รันด้วย root หรือ sudo เท่านั้น"

# ── PORT MAP ────────────────────────────────────────────────
# 22    OpenSSH (admin)
# 80    ws-stunnel HTTP-CONNECT → Dropbear:143
# 109   Dropbear SSH port 2
# 143   Dropbear SSH port 1
# 443   nginx HTTPS panel (ถ้ามี SSL cert)
# 2053  3x-ui panel (internal)
# 7300  badvpn-udpgw (127.0.0.1 เท่านั้น)
# 8080  xui VMess-WS inbound
# 8880  xui VLESS-WS inbound
# 6789  chaiya-sshws-api (127.0.0.1 เท่านั้น)

SSH_API_PORT=6789
XUI_PORT=2053
DROPBEAR_PORT1=143
DROPBEAR_PORT2=109
BADVPN_PORT=7300
WS_TUNNEL_PORT=80

# ── INSTALL DEPS ─────────────────────────────────────────────
info "อัปเดต packages..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl wget python3 python3-pip nginx certbot \
  python3-certbot-nginx dropbear openssh-server ufw \
  net-tools jq bc cron unzip sqlite3 iptables-persistent 2>/dev/null || true
ok "ติดตั้ง packages สำเร็จ"

# ── GET SERVER IP ────────────────────────────────────────────
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
            hostname -I | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && err "ไม่สามารถดึง IP ได้"
ok "IP: ${CYAN}$SERVER_IP${NC}"

# ── DOMAIN SETUP ─────────────────────────────────────────────
echo ""
echo -e "${YELLOW}════════════════════════════════════════${NC}"
echo -e "${YELLOW}  ตั้งค่าโดเมน${NC}"
echo -e "${YELLOW}════════════════════════════════════════${NC}"
echo -e "  DNS ต้องชี้ A record มาที่ IP: ${CYAN}$SERVER_IP${NC} ก่อน"
echo ""
read -rp "  โดเมน (เช่น panel.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && err "กรุณาใส่โดเมน"
DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's|https\?://||' | sed 's|/.*||')
ok "โดเมน: ${CYAN}$DOMAIN${NC}"

# ── 3x-ui CREDENTIALS ────────────────────────────────────────
echo ""
read -rp "  3x-ui Username [admin]: " XUI_USER
[[ -z "$XUI_USER" ]] && XUI_USER="admin"
while true; do
  read -rsp "  3x-ui Password: " XUI_PASS; echo
  [[ -z "$XUI_PASS" ]] && { warn "Password ห้ามว่าง"; continue; }
  read -rsp "  Confirm Password: " XUI_PASS2; echo
  [[ "$XUI_PASS" == "$XUI_PASS2" ]] && break
  warn "Password ไม่ตรงกัน"
done
ok "3x-ui credentials ตั้งค่าแล้ว"

echo ""
read -rp "เริ่มติดตั้ง? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 0

# ── CLEANUP (ล้างข้อมูลเก่าทุกครั้งก่อนติดตั้งใหม่) ──────────
info "ล้างข้อมูลเก่า..."

# หยุด services ทั้งหมดที่เกี่ยวข้อง
for _svc in chaiya-sshws chaiya-ssh-api chaiya-badvpn nginx x-ui dropbear; do
  systemctl stop "$_svc"    2>/dev/null || true
  systemctl disable "$_svc" 2>/dev/null || true
done

# kill โดยตรงกรณี systemctl ไม่จับ
pkill -f ws-stunnel      2>/dev/null || true
pkill -f badvpn-udpgw    2>/dev/null || true
pkill -f chaiya-ssh-api  2>/dev/null || true
pkill -f 'app.py'        2>/dev/null || true
pkill -9 -x nginx        2>/dev/null || true
sleep 2

# ล้าง nginx config เก่า
rm -f /etc/nginx/sites-enabled/*
rm -f /etc/nginx/sites-available/chaiya
rm -f /etc/nginx/sites-available/chaiya-tmp
# คืน default เผื่อ nginx ต้องการ (จะถูก override ทีหลัง)
[[ -f /etc/nginx/sites-available/default ]] && \
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true

# ล้าง systemd unit เก่า
rm -f /etc/systemd/system/chaiya-sshws.service
rm -f /etc/systemd/system/chaiya-ssh-api.service
rm -f /etc/systemd/system/chaiya-badvpn.service
rm -f /etc/systemd/system/dropbear.service.d/override.conf
systemctl daemon-reload

# ล้าง chaiya config/data
rm -rf /etc/chaiya
rm -rf /opt/chaiya-panel
rm -rf /opt/chaiya-ssh-api
rm -f  /usr/local/bin/ws-stunnel
rm -f  /usr/local/bin/menu

# ล้าง x-ui inbounds เก่า (เก็บ binary ไว้ — ไม่ uninstall)
if [[ -f /etc/x-ui/x-ui.db ]]; then
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds;" 2>/dev/null || true
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings;" 2>/dev/null || true
fi

# ล้าง port binding ที่อาจค้างอยู่
for _port in 80 81 443 6789 7300; do
  _pid=$(lsof -ti tcp:$_port 2>/dev/null || fuser $_port/tcp 2>/dev/null | awk '{print $1}')
  [[ -n "$_pid" ]] && kill -9 $_pid 2>/dev/null || true
done
sleep 1

ok "ล้างข้อมูลเก่าเสร็จแล้ว"

# ── MKDIR ────────────────────────────────────────────────────
mkdir -p /etc/chaiya /etc/chaiya/exp /var/www/chaiya /opt/chaiya-panel

# ── บันทึก credentials ──────────────────────────────────────
echo "$XUI_USER"  > /etc/chaiya/xui-user.conf
echo "$XUI_PASS"  > /etc/chaiya/xui-pass.conf
echo "$SERVER_IP" > /etc/chaiya/my_ip.conf
echo "$DOMAIN"    > /etc/chaiya/domain.conf
chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf

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
[[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]     && dropbearkey -t rsa     -f /etc/dropbear/dropbear_rsa_host_key     2>/dev/null || true
[[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]   && dropbearkey -t ecdsa   -f /etc/dropbear/dropbear_ecdsa_host_key   2>/dev/null || true
[[ ! -f /etc/dropbear/dropbear_ed25519_host_key ]] && dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true

grep -q '/bin/false' /etc/shells     2>/dev/null || echo '/bin/false'         >> /etc/shells
grep -q '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

mkdir -p /etc/systemd/system/dropbear.service.d
cat > /etc/systemd/system/dropbear.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -F -p $DROPBEAR_PORT1 -p $DROPBEAR_PORT2 -W 65536
EOF

systemctl daemon-reload
systemctl enable dropbear
systemctl restart dropbear
sleep 2
systemctl is-active --quiet dropbear && ok "Dropbear พร้อม (port $DROPBEAR_PORT1, $DROPBEAR_PORT2)" || \
  warn "Dropbear อาจไม่ทำงาน"

# ── BADVPN ───────────────────────────────────────────────────
info "ติดตั้ง BadVPN..."
if [[ ! -f /usr/bin/badvpn-udpgw ]] || [[ ! -x /usr/bin/badvpn-udpgw ]]; then
  wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
    "https://raw.githubusercontent.com/NevermoreSSH/Blueblue/main/newudpgw" 2>/dev/null && \
    chmod +x /usr/bin/badvpn-udpgw || rm -f /usr/bin/badvpn-udpgw
  # fallback
  if [[ ! -f /usr/bin/badvpn-udpgw ]]; then
    wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
      "https://raw.githubusercontent.com/bagaswastu/badvpn/master/udpgw/badvpn-udpgw" 2>/dev/null && \
      chmod +x /usr/bin/badvpn-udpgw || true
  fi
fi

cat > /etc/systemd/system/chaiya-badvpn.service << 'EOF'
[Unit]
Description=Chaiya BadVPN UDP Gateway
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500
Restart=always
RestartSec=5
StandardOutput=null
StandardError=null
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chaiya-badvpn
pkill -f badvpn 2>/dev/null || true
sleep 1
systemctl start chaiya-badvpn
ok "BadVPN พร้อม (port $BADVPN_PORT)"

# ── WS-STUNNEL (port 80 → Dropbear:143) ─────────────────────
info "ติดตั้ง WS-Stunnel..."
cat > /usr/local/bin/ws-stunnel << 'WSPYEOF'
#!/usr/bin/python3
import socket, threading, select, sys, time

LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 80
BUFLEN = 4096 * 4
TIMEOUT = 60
DEFAULT_HOST = '127.0.0.1:143'
RESPONSE = b'HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n'

class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.running = False
        self.host = host
        self.port = port
        self.threads = []
        self.threadsLock = threading.Lock()
    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, int(self.port)))
        self.soc.listen(128)
        self.running = True
        try:
            while self.running:
                try:
                    c, addr = self.soc.accept()
                    c.setblocking(1)
                except socket.timeout:
                    continue
                conn = ConnectionHandler(c, self, addr)
                conn.start()
                self.addConn(conn)
        finally:
            self.running = False
            self.soc.close()
    def addConn(self, conn):
        try:
            self.threadsLock.acquire()
            if self.running:
                self.threads.append(conn)
        finally:
            self.threadsLock.release()
    def removeConn(self, conn):
        try:
            self.threadsLock.acquire()
            self.threads.remove(conn)
        finally:
            self.threadsLock.release()
    def close(self):
        try:
            self.running = False
            self.threadsLock.acquire()
            threads = list(self.threads)
            for c in threads:
                c.close()
        finally:
            self.threadsLock.release()

class ConnectionHandler(threading.Thread):
    def __init__(self, socClient, server, addr):
        threading.Thread.__init__(self)
        self.client = socClient
        self.client_buffer = b''
        self.server = server
        self.addr = addr
        self.daemon = True
    def run(self):
        try:
            self.client.settimeout(TIMEOUT)
            self.client_buffer = self.client.recv(BUFLEN)
            hostPort = DEFAULT_HOST
            try:
                _h = self.client_buffer.split(b'\r\n')[0].decode()
                for line in self.client_buffer.decode(errors='ignore').split('\r\n'):
                    if line.lower().startswith('x-real-host:') or line.lower().startswith('host:'):
                        hostPort = line.split(':',1)[1].strip()
                        break
            except: pass
            host = hostPort.split(':')[0]
            port = int(hostPort.split(':')[1]) if ':' in hostPort else 143
            self.client.send(RESPONSE)
            self._tunnel(host, port)
        except: pass
        finally:
            self.server.removeConn(self)
    def _tunnel(self, host, port):
        try:
            soc = socket.socket(socket.AF_INET)
            soc.settimeout(TIMEOUT)
            soc.connect((host, port))
            while True:
                r, _, _ = select.select([self.client, soc], [], [], TIMEOUT)
                if not r: break
                for s in r:
                    data = s.recv(BUFLEN)
                    if not data: return
                    (soc if s is self.client else self.client).sendall(data)
        except: pass
        finally:
            try: soc.close()
            except: pass

def main():
    print(f'[ws-stunnel] Listening on port {LISTENING_PORT} → {DEFAULT_HOST}')
    srv = Server(LISTENING_ADDR, LISTENING_PORT)
    srv.start()
    try:
        while True: time.sleep(60)
    except KeyboardInterrupt:
        srv.close()

if __name__ == '__main__':
    main()
WSPYEOF
chmod +x /usr/local/bin/ws-stunnel

cat > /etc/systemd/system/chaiya-sshws.service << 'EOF'
[Unit]
Description=Chaiya WS-Stunnel port 80 -> Dropbear:143
After=network.target dropbear.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-stunnel
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chaiya-sshws
systemctl restart chaiya-sshws
sleep 2
ok "WS-Stunnel พร้อม (port $WS_TUNNEL_PORT → Dropbear:$DROPBEAR_PORT1)"

# ── 3x-ui INSTALL ────────────────────────────────────────────
info "ติดตั้ง 3x-ui..."
if ! command -v x-ui &>/dev/null; then
  _xui_sh=$(mktemp /tmp/xui-XXXXX.sh)
  curl -Ls "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" -o "$_xui_sh" 2>/dev/null
  printf "y\n${XUI_PORT}\n2\n\n80\n" | bash "$_xui_sh" >> /var/log/chaiya-xui-install.log 2>&1
  rm -f "$_xui_sh"
fi

systemctl stop x-ui 2>/dev/null || true
sleep 2

# ตั้งค่า credentials ใน x-ui
XUI_DB="/etc/x-ui/x-ui.db"
if [[ -f "$XUI_DB" ]]; then
  XUI_PASS_HASH=$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt()).decode())
" "$XUI_PASS" 2>/dev/null || echo "$XUI_PASS")

  sqlite3 "$XUI_DB" "UPDATE users SET username='${XUI_USER}', password='${XUI_PASS_HASH}' WHERE id=1;" 2>/dev/null || true
  for _key in webPort webUsername webPassword; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPort','${XUI_PORT}');"       2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webUsername','${XUI_USER}');"   2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPassword','${XUI_PASS_HASH}');" 2>/dev/null || true
  ok "3x-ui credentials ตั้งค่าแล้ว"
fi

systemctl start x-ui
sleep 5

# รอ x-ui พร้อม
REAL_XUI_PORT="$XUI_PORT"
for _i in $(seq 1 15); do
  _p=$(ss -tlnp 2>/dev/null | grep x-ui | grep -oP ':\K\d+' | head -1)
  [[ -n "$_p" ]] && REAL_XUI_PORT="$_p"
  curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${REAL_XUI_PORT}/" 2>/dev/null | grep -q "^[123]" && break
  sleep 2
done
echo "$REAL_XUI_PORT" > /etc/chaiya/xui-port.conf
ok "3x-ui พร้อม (port $REAL_XUI_PORT)"

# ── สร้าง inbounds ใน x-ui ───────────────────────────────────
info "สร้าง VMess/VLESS inbounds..."
XUI_COOKIE=$(mktemp)

# login
for _try in 1 2 3; do
  _resp=$(curl -s --max-time 10 -c "$XUI_COOKIE" -X POST \
    "http://127.0.0.1:${REAL_XUI_PORT}/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${XUI_USER}" \
    --data-urlencode "password=${XUI_PASS}" 2>/dev/null)
  echo "$_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('success') else 1)" 2>/dev/null && break
  sleep 3
done

python3 << PYEOF
import sqlite3, uuid, json

DB = '/etc/x-ui/x-ui.db'
try:
    con = sqlite3.connect(DB)
    existing = [r[0] for r in con.execute("SELECT port FROM inbounds").fetchall()]

    inbounds = [
        (8080, 'CHAIYA-AIS-8080',  'cj-ebb.speedtest.net',           'vmess',  'inbound-8080'),
        (8880, 'CHAIYA-TRUE-8880', 'true-internet.zoom.xyz.services', 'vless',  'inbound-8880'),
    ]

    for port, remark, host, proto, tag in inbounds:
        if port in existing:
            print(f'[OK] {remark} มีอยู่แล้ว')
            continue
        uid = str(uuid.uuid4())
        if proto == 'vmess':
            settings = json.dumps({'clients': [{'id': uid, 'alterId': 0, 'email': 'chaiya-default', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}]})
        else:
            settings = json.dumps({'clients': [{'id': uid, 'flow': '', 'email': 'chaiya-default', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}], 'decryption': 'none'})
        stream   = json.dumps({'network': 'ws', 'security': 'none', 'wsSettings': {'path': '/vless' if proto=='vless' else '/vmess', 'headers': {'Host': host}}})
        sniffing = json.dumps({'enabled': True, 'destOverride': ['http', 'tls']})
        con.execute(
            "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,?,1,0,'',?,?,?,?,?,?)",
            (remark, port, proto, settings, stream, tag, sniffing)
        )
        print(f'[OK] {proto.upper()} {remark} (port {port})')
    con.commit()
    con.close()
except Exception as e:
    print(f'[WARN] {e}')
PYEOF

rm -f "$XUI_COOKIE"
systemctl restart x-ui 2>/dev/null || true
sleep 2
ok "Inbounds พร้อม"

# ── SSH API (Python) ──────────────────────────────────────────
info "ติดตั้ง SSH API..."
mkdir -p /opt/chaiya-ssh-api

cat > /opt/chaiya-ssh-api/app.py << 'PYEOF'
#!/usr/bin/env python3
"""Chaiya SSH API v5"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, threading, sqlite3

XUI_DB = '/etc/x-ui/x-ui.db'

def run_cmd(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
    return r.returncode == 0, r.stdout.strip(), r.stderr.strip()

def get_host():
    for f in ('/etc/chaiya/domain.conf', '/etc/chaiya/my_ip.conf'):
        if os.path.exists(f):
            v = open(f).read().strip()
            if v: return v
    return ''

def get_connections():
    counts = {}
    total = 0
    for port in ['80', '443', '143', '109', '22']:
        try:
            r = subprocess.run(
                f"ss -tn state established 2>/dev/null | awk '{{print $4}}' | grep -c ':{port}$' || echo 0",
                shell=True, capture_output=True, text=True)
            c = int(r.stdout.strip().split()[0]) if r.stdout.strip() else 0
        except: c = 0
        counts[port] = c
        total += c
    counts['total'] = total
    return counts

def list_ssh_users():
    users = []
    try:
        with open('/etc/passwd') as f:
            for line in f:
                p = line.strip().split(':')
                if len(p) < 7: continue
                uid = int(p[2])
                if uid < 1000 or uid > 60000: continue
                if p[6] not in ['/bin/false', '/usr/sbin/nologin', '/bin/bash', '/bin/sh']: continue
                uname = p[0]
                u = {'user': uname, 'active': True, 'exp': None}
                exp_f = f'/etc/chaiya/exp/{uname}'
                if os.path.exists(exp_f):
                    u['exp'] = open(exp_f).read().strip()
                if u['exp']:
                    try:
                        exp_date = datetime.date.fromisoformat(u['exp'])
                        u['active'] = exp_date >= datetime.date.today()
                    except: pass
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
                return json.loads(self.rfile.read(length))
            return {}
        except: return {}

    def do_GET(self):
        if self.path == '/api/status':
            _, svc_drop, _ = run_cmd("systemctl is-active dropbear")
            _, svc_nginx, _ = run_cmd("systemctl is-active nginx")
            _, svc_xui,  _ = run_cmd("systemctl is-active x-ui")
            _, udp, _       = run_cmd("pgrep -x badvpn-udpgw")
            _, ws,  _       = run_cmd("systemctl is-active chaiya-sshws")
            conns = get_connections()
            users = list_ssh_users()
            respond(self, 200, {
                'ok': True,
                'connections': conns.get('total', 0),
                'conn_443': conns.get('443', 0),
                'conn_80':  conns.get('80', 0),
                'conn_143': conns.get('143', 0),
                'conn_109': conns.get('109', 0),
                'conn_22':  conns.get('22', 0),
                'online': conns.get('total', 0),
                'online_count': conns.get('total', 0),
                'total_users': len(users),
                'services': {
                    'ssh':      True,
                    'dropbear': svc_drop.strip() == 'active',
                    'nginx':    svc_nginx.strip() == 'active',
                    'badvpn':   bool(udp.strip()),
                    'sshws':    ws.strip() == 'active',
                    'xui':      svc_xui.strip() == 'active',
                    'tunnel':   ws.strip() == 'active',
                }
            })

        elif self.path == '/api/users':
            respond(self, 200, {'users': list_ssh_users()})

        elif self.path == '/api/info':
            xui_port = open('/etc/chaiya/xui-port.conf').read().strip() if os.path.exists('/etc/chaiya/xui-port.conf') else '2053'
            respond(self, 200, {
                'host': get_host(),
                'xui_port': int(xui_port),
                'dropbear_port': 143,
                'dropbear_port2': 109,
                'udpgw_port': 7300,
            })
        else:
            respond(self, 404, {'error': 'not found'})

    def do_POST(self):
        data = self.read_body()

        if self.path == '/api/create_ssh':
            user = data.get('user', '').strip()
            days = int(data.get('days', 30))
            passwd = data.get('password', '').strip()
            if not user or not passwd:
                return respond(self, 400, {'error': 'user and password required'})
            # สร้าง user
            ok1, _, _ = run_cmd(f"id {user} 2>/dev/null")
            if not ok1:
                run_cmd(f"useradd -M -s /bin/false {user}")
            run_cmd(f"echo '{user}:{passwd}' | chpasswd")
            exp_date = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
            run_cmd(f"chage -E {exp_date} {user}")
            with open(f'/etc/chaiya/exp/{user}', 'w') as f:
                f.write(exp_date)
            respond(self, 200, {'ok': True, 'user': user, 'exp': exp_date, 'days': days})

        elif self.path == '/api/delete_ssh':
            user = data.get('user', '').strip()
            if not user:
                return respond(self, 400, {'error': 'user required'})
            run_cmd(f"userdel -f {user} 2>/dev/null || true")
            try: os.remove(f'/etc/chaiya/exp/{user}')
            except: pass
            respond(self, 200, {'ok': True, 'user': user})

        elif self.path == '/api/extend_ssh':
            user = data.get('user', '').strip()
            days = int(data.get('days', 30))
            if not user:
                return respond(self, 400, {'error': 'user required'})
            exp_f = f'/etc/chaiya/exp/{user}'
            if os.path.exists(exp_f):
                try:
                    old = datetime.date.fromisoformat(open(exp_f).read().strip())
                    new_exp = max(old, datetime.date.today()) + datetime.timedelta(days=days)
                except:
                    new_exp = datetime.date.today() + datetime.timedelta(days=days)
            else:
                new_exp = datetime.date.today() + datetime.timedelta(days=days)
            run_cmd(f"chage -E {new_exp.isoformat()} {user}")
            with open(exp_f, 'w') as f:
                f.write(new_exp.isoformat())
            respond(self, 200, {'ok': True, 'user': user, 'exp': new_exp.isoformat()})

        else:
            respond(self, 404, {'error': 'not found'})

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 6789), Handler)
    print('[chaiya-ssh-api] Listening on 127.0.0.1:6789')
    server.serve_forever()
PYEOF

chmod +x /opt/chaiya-ssh-api/app.py

cat > /etc/systemd/system/chaiya-ssh-api.service << 'EOF'
[Unit]
Description=Chaiya SSH API
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/chaiya-ssh-api/app.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chaiya-ssh-api
systemctl restart chaiya-ssh-api
sleep 2
curl -s --max-time 3 http://127.0.0.1:6789/api/status | grep -q '"ok"' && \
  ok "SSH API พร้อม (port 6789)" || warn "SSH API อาจยังไม่พร้อม"

# ── SSL CERTIFICATE ───────────────────────────────────────────
info "ขอ SSL Certificate สำหรับ ${DOMAIN}..."
SSL_CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
USE_SSL=0

# certbot standalone ต้องการ port 80 ว่าง — หยุด ws-stunnel + nginx ชั่วคราว
systemctl stop chaiya-sshws 2>/dev/null || true
systemctl stop nginx       2>/dev/null || true
sleep 2

for _try in 1 2 3; do
  certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email -d "$DOMAIN" 2>&1 | tail -3
  [[ -f "$SSL_CERT" ]] && { USE_SSL=1; break; }
  sleep 5
done

[[ $USE_SSL -eq 1 ]] && ok "SSL Certificate พร้อม" || warn "ไม่มี SSL — ใช้ HTTP แทน"

# ── NGINX CONFIG ─────────────────────────────────────────────
info "ตั้งค่า Nginx..."
rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true

if [[ $USE_SSL -eq 1 ]]; then
cat > /etc/nginx/sites-available/chaiya << EOF
# HTTP → HTTPS redirect
server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

# HTTPS Panel หลัก
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root /opt/chaiya-panel;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-store";
    }

    # SSH API proxy
    location /api/ {
        proxy_pass http://127.0.0.1:6789/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 30s;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }

    # 3x-ui proxy
    location /xui-api/ {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }
}
EOF
else
# ไม่มี SSL — ใช้ HTTP port 81 แทน (port 80 ถูก ws-stunnel ใช้อยู่)
cat > /etc/nginx/sites-available/chaiya << EOF
server {
    listen 81;
    server_name ${DOMAIN} _;
    root /opt/chaiya-panel;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
        add_header Cache-Control "no-store";
    }
    location /api/ {
        proxy_pass http://127.0.0.1:6789/api/;
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

ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya
nginx -t && systemctl restart nginx && ok "Nginx พร้อม" || warn "Nginx มีปัญหา — ตรวจ: nginx -t"
# start ws-stunnel คืนหลัง nginx config เสร็จ
systemctl start chaiya-sshws 2>/dev/null || true

# ── FIREWALL ─────────────────────────────────────────────────
info "ตั้งค่า Firewall..."
ufw --force reset &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
for port in 22 80 81 109 143 443 8080 8880 "${REAL_XUI_PORT}"; do
  ufw allow "$port"/tcp &>/dev/null
done
ufw deny 6789/tcp &>/dev/null
ufw deny 7300/tcp &>/dev/null
ufw allow 7300/udp &>/dev/null
ufw --force enable &>/dev/null
ok "Firewall พร้อม"

# ── CONFIG.JS ────────────────────────────────────────────────
cat > /opt/chaiya-panel/config.js << EOF
// Auto-generated by chaiya-setup-v5.sh
window.CHAIYA_CONFIG = {
  host:         "${DOMAIN}",
  domain:       "${DOMAIN}",
  ssh_api_port: 6789,
  xui_port:     ${REAL_XUI_PORT},
  xui_user:     "${XUI_USER}",
  xui_pass:     "${XUI_PASS}",
  ssh_token:    "",
  panel_url:    "https://${DOMAIN}",
  dashboard_url:"sshws.html"
};
EOF

# ── LOGIN PAGE (index.html) ───────────────────────────────────
info "สร้าง Login Page..."
cat > /opt/chaiya-panel/index.html << 'LOGINEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA V2RAY PRO MAX — Login</title>
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@600;700&family=Kanit:wght@300;400;600&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{
  min-height:100vh;display:flex;align-items:center;justify-content:center;
  background:radial-gradient(ellipse 140% 130% at 50% -10%,#0d1f3c 0%,#060e1e 55%,#020810 100%);
  font-family:'Kanit',sans-serif;overflow:hidden;position:relative;
}
canvas{position:fixed;inset:0;pointer-events:none;z-index:0}
.card{
  position:relative;z-index:10;
  width:90%;max-width:380px;
  background:rgba(255,255,255,.04);
  border:1px solid rgba(255,255,255,.1);
  border-radius:24px;padding:2.4rem 2rem 2rem;
  backdrop-filter:blur(18px);
  box-shadow:0 20px 60px rgba(0,0,0,.5);
}
.logo{
  font-family:'Share Tech Mono',monospace;
  font-size:.55rem;letter-spacing:.35em;
  color:rgba(100,200,50,.6);
  text-align:center;margin-bottom:.5rem;
  display:flex;align-items:center;justify-content:center;gap:.6rem;
}
.logo::before,.logo::after{content:'';flex:1;height:1px;background:rgba(100,200,50,.3)}
.title{
  font-family:'Rajdhani',sans-serif;font-size:2.1rem;font-weight:700;
  text-align:center;color:#eef6ff;letter-spacing:.08em;margin-bottom:.25rem;
}
.title span{color:#72d124;text-shadow:0 0 20px rgba(100,200,30,.4)}
.subtitle{
  font-family:'Share Tech Mono',monospace;font-size:.65rem;
  color:rgba(255,255,255,.3);text-align:center;margin-bottom:2rem;letter-spacing:.06em;
}
.server-badge{
  display:flex;align-items:center;gap:.5rem;justify-content:center;
  background:rgba(114,209,36,.08);border:1px solid rgba(114,209,36,.2);
  border-radius:20px;padding:.35rem .9rem;margin-bottom:1.5rem;
  font-family:'Share Tech Mono',monospace;font-size:.68rem;color:rgba(114,209,36,.8);
}
.server-badge .dot{width:7px;height:7px;border-radius:50%;background:#72d124;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
.field{margin-bottom:1.1rem}
label{display:block;font-size:.65rem;font-family:'Share Tech Mono',monospace;letter-spacing:.1em;color:rgba(255,255,255,.4);margin-bottom:.45rem;text-transform:uppercase}
.input-wrap{position:relative}
input{
  width:100%;background:rgba(255,255,255,.06);
  border:1.5px solid rgba(255,255,255,.12);border-radius:12px;
  padding:.7rem 1rem;color:#e8f4ff;
  font-family:'Kanit',sans-serif;font-size:.9rem;outline:none;
  transition:border-color .2s,background .2s;
}
input::placeholder{color:rgba(255,255,255,.2)}
input:focus{border-color:rgba(114,209,36,.5);background:rgba(255,255,255,.09)}
.eye-btn{
  position:absolute;right:.75rem;top:50%;transform:translateY(-50%);
  background:none;border:none;color:rgba(255,255,255,.3);cursor:pointer;font-size:1rem;
}
.login-btn{
  width:100%;padding:.85rem;border:none;border-radius:13px;
  background:linear-gradient(135deg,#3d7a0e,#5aaa18);color:#fff;
  font-family:'Rajdhani',sans-serif;font-size:1.05rem;font-weight:700;letter-spacing:.1em;
  cursor:pointer;margin-top:.5rem;transition:all .2s;
  box-shadow:0 4px 16px rgba(90,170,24,.3);
}
.login-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(90,170,24,.45);transform:translateY(-1px)}
.login-btn:disabled{opacity:.5;cursor:not-allowed}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite;vertical-align:middle;margin-right:.4rem}
@keyframes spin{to{transform:rotate(360deg)}}
.alert{margin-top:.8rem;padding:.65rem .9rem;border-radius:10px;font-size:.8rem;display:none;line-height:1.5}
.alert.ok{background:rgba(34,197,94,.1);border:1px solid rgba(34,197,94,.3);color:#4ade80}
.alert.err{background:rgba(239,68,68,.1);border:1px solid rgba(239,68,68,.3);color:#f87171}
.footer{text-align:center;margin-top:1.5rem;font-family:'Share Tech Mono',monospace;font-size:.6rem;color:rgba(255,255,255,.15);letter-spacing:.06em}
</style>
</head>
<body>
<canvas id="snow-canvas"></canvas>
<div class="card">
  <div class="logo">CHAIYA V2RAY PRO MAX</div>
  <div class="title">ADMIN <span>PANEL</span></div>
  <div class="subtitle">x-ui Management Dashboard</div>
  <div class="server-badge">
    <span class="dot"></span>
    <span id="server-host">กำลังโหลด...</span>
  </div>
  <div class="field">
    <label>👤 USERNAME</label>
    <input type="text" id="inp-user" placeholder="username" autocomplete="username">
  </div>
  <div class="field">
    <label>🔑 PASSWORD</label>
    <div class="input-wrap">
      <input type="password" id="inp-pass" placeholder="••••••••" autocomplete="current-password">
      <button class="eye-btn" id="eye-btn" onclick="toggleEye()" type="button">👁</button>
    </div>
  </div>
  <button class="login-btn" id="login-btn" onclick="doLogin()">⚡ เข้าสู่ระบบ</button>
  <div class="alert" id="alert"></div>
  <div class="footer" id="footer-time"></div>
</div>
<script src="config.js"></script>
<script>
const CFG = (typeof window.CHAIYA_CONFIG !== 'undefined') ? window.CHAIYA_CONFIG : {};
const XUI_API = '/xui-api';
const SESSION_KEY = 'chaiya_auth';
const DASHBOARD = CFG.dashboard_url || 'sshws.html';

// แสดง server host
document.getElementById('server-host').textContent = CFG.host || location.hostname;

// auto-fill username จาก config
if (CFG.xui_user) document.getElementById('inp-user').value = CFG.xui_user;

// clock
function updateClock() {
  document.getElementById('footer-time').textContent =
    new Date().toLocaleTimeString('th-TH') + ' · CHAIYA VPN SYSTEM · v5.0';
}
updateClock();
setInterval(updateClock, 1000);

// enter key
document.addEventListener('keydown', e => { if (e.key === 'Enter') doLogin(); });

let eyeOpen = false;
function toggleEye() {
  eyeOpen = !eyeOpen;
  document.getElementById('inp-pass').type = eyeOpen ? 'text' : 'password';
  document.getElementById('eye-btn').textContent = eyeOpen ? '🙈' : '👁';
}

function showAlert(msg, type) {
  const el = document.getElementById('alert');
  el.className = 'alert ' + type;
  el.textContent = msg;
  el.style.display = 'block';
}

async function doLogin() {
  const user = document.getElementById('inp-user').value.trim();
  const pass = document.getElementById('inp-pass').value;
  if (!user) return showAlert('กรุณาใส่ Username', 'err');
  if (!pass) return showAlert('กรุณาใส่ Password', 'err');

  const btn = document.getElementById('login-btn');
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> กำลังเข้าสู่ระบบ...';
  document.getElementById('alert').style.display = 'none';

  try {
    const form = new URLSearchParams({ username: user, password: pass });
    const res = await Promise.race([
      fetch(XUI_API + '/login', {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: form.toString()
      }),
      new Promise((_, rej) => setTimeout(() => rej(new Error('Timeout')), 8000))
    ]);
    const data = await res.json();
    if (data.success) {
      // เก็บ credentials ใน sessionStorage เพื่อให้ dashboard ใช้ login ซ้ำได้
      sessionStorage.setItem(SESSION_KEY, JSON.stringify({
        user, pass,
        exp: Date.now() + 8 * 3600 * 1000
      }));
      showAlert('✅ เข้าสู่ระบบสำเร็จ กำลัง redirect...', 'ok');
      setTimeout(() => { window.location.replace(DASHBOARD); }, 800);
    } else {
      showAlert('❌ Username หรือ Password ไม่ถูกต้อง', 'err');
      btn.disabled = false;
      btn.innerHTML = '⚡ เข้าสู่ระบบ';
    }
  } catch (e) {
    showAlert('❌ ' + e.message, 'err');
    btn.disabled = false;
    btn.innerHTML = '⚡ เข้าสู่ระบบ';
  }
}

// Snow
function startSnow(canvasId, count) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  let flakes = [];
  function resize() {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
  }
  resize();
  window.addEventListener('resize', resize);
  function mkFlake() {
    return {
      x: Math.random() * canvas.width,
      y: Math.random() * canvas.height - canvas.height,
      r: Math.random() * 2 + 1,
      speed: Math.random() * 0.8 + 0.3,
      drift: (Math.random() - 0.5) * 0.4,
      opacity: Math.random() * 0.4 + 0.1
    };
  }
  for (let i = 0; i < count; i++) flakes.push(mkFlake());
  function tick() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    flakes.forEach((f, i) => {
      ctx.beginPath();
      ctx.arc(f.x, f.y, f.r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(255,255,255,${f.opacity})`;
      ctx.fill();
      f.y += f.speed;
      f.x += f.drift;
      if (f.y > canvas.height + 10) flakes[i] = mkFlake();
    });
    requestAnimationFrame(tick);
  }
  tick();
}
startSnow('snow-canvas', 40);
</script>
</body>
</html>
LOGINEOF
ok "Login Page พร้อม"

# ── DASHBOARD (sshws.html) ────────────────────────────────────
info "สร้าง Dashboard..."
cat > /opt/chaiya-panel/sshws.html << 'DASHEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA V2RAY PRO MAX — Dashboard</title>
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@600;700&family=Kanit:wght@300;400;600&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
:root{
  --bg:#ebeff6;--surface:#fff;--border:#e2e8f0;
  --shadow:0 2px 12px rgba(0,0,0,.08);
  --ais:#5a9e1c;--ais2:#3d7a0e;--ais-light:#f0f9e8;--ais-bdr:#c5e89a;
  --true:#e01020;--true2:#b8000e;--true-light:#fff0f0;--true-bdr:#f8a0a8;
  --ssh:#1a6fa8;--ssh2:#0d5487;--ssh-light:#e8f4fc;--ssh-bdr:#90caf0;
  --text:#1a2332;--text2:#4a6072;--text3:#8099ac;
  --green:#22c55e;--orange:#f97316;--red:#ef4444;--purple:#8b5cf6;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Kanit',sans-serif;min-height:100vh;overflow-x:hidden}

/* HEADER */
.site-header{
  text-align:center;padding:2rem 1.5rem 1.6rem;
  background:radial-gradient(ellipse 140% 130% at 50% -10%,#0d1f3c 0%,#060e1e 55%,#020810 100%);
  border-bottom:1px solid rgba(255,255,255,.05);
  position:relative;overflow:hidden;
}
.site-header::before{
  content:"";position:absolute;top:-60px;left:50%;transform:translateX(-50%);
  width:380px;height:200px;
  background:radial-gradient(ellipse,rgba(80,160,20,.18) 0%,transparent 70%);
  pointer-events:none;
}
#snow-canvas{position:absolute;inset:0;pointer-events:none;z-index:0}
.site-logo{
  font-family:"Share Tech Mono",monospace;font-size:.6rem;letter-spacing:.35em;
  color:rgba(100,200,50,.65);margin-bottom:.45rem;
  display:flex;align-items:center;justify-content:center;gap:.7rem;position:relative;z-index:1;
}
.site-logo::before,.site-logo::after{content:"";display:inline-block;height:1px;width:42px;background:linear-gradient(90deg,transparent,rgba(100,200,50,.45))}
.site-logo::after{background:linear-gradient(90deg,rgba(100,200,50,.45),transparent)}
.site-title{font-family:"Rajdhani",sans-serif;font-size:2.4rem;font-weight:700;letter-spacing:.08em;color:#eef6ff;position:relative;z-index:1;line-height:1.1}
.site-title span{color:#72d124;text-shadow:0 0 22px rgba(100,200,30,.4)}
.site-sub{font-size:.72rem;color:rgba(255,255,255,.35);margin-top:.4rem;font-family:"Share Tech Mono",monospace;letter-spacing:.07em;position:relative;z-index:1}
.site-sub .dot{margin:0 .4rem;color:rgba(110,200,50,.45)}
.logout-btn{position:absolute;top:1rem;right:1rem;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.12);color:rgba(255,255,255,.45);border-radius:8px;padding:.3rem .75rem;font-family:"Share Tech Mono",monospace;font-size:.62rem;cursor:pointer;z-index:10;transition:all .2s}
.logout-btn:hover{color:rgba(248,113,113,.8)}

/* TABS */
.tab-nav{display:flex;background:#192333;border-bottom:1px solid rgba(255,255,255,.07);overflow-x:auto;-webkit-overflow-scrolling:touch;position:sticky;top:0;z-index:200}
.tab-nav::-webkit-scrollbar{display:none}
.tab-btn{flex:1;min-width:80px;padding:.78rem .5rem;border:none;background:transparent;font-family:"Kanit",sans-serif;font-size:.78rem;font-weight:600;color:rgba(255,255,255,.38);cursor:pointer;border-bottom:2px solid transparent;transition:all .2s;white-space:nowrap}
.tab-btn:hover{color:rgba(255,255,255,.65);background:rgba(255,255,255,.03)}
.tab-btn.active{color:#72d124;border-bottom-color:#72d124;background:rgba(114,209,36,.06)}
.tab-panel{display:none}.tab-panel.active{display:block}
.main{max-width:520px;margin:0 auto;padding:1.5rem 1rem 4rem;display:flex;flex-direction:column;gap:1.3rem}

/* STAT CARDS */
.stats-grid{display:grid;grid-template-columns:1fr 1fr;gap:.8rem}
.stat-card{background:var(--surface);border-radius:18px;padding:1.1rem 1.15rem;border:1px solid var(--border);box-shadow:var(--shadow);position:relative;overflow:hidden;transition:box-shadow .2s,transform .2s}
.stat-card:hover{box-shadow:0 6px 28px rgba(0,0,0,.11);transform:translateY(-1px)}
.stat-card.wide{grid-column:span 2}
.stat-label{font-family:"Share Tech Mono",monospace;font-size:.65rem;letter-spacing:.1em;text-transform:uppercase;color:var(--text3);margin-bottom:.4rem;display:flex;align-items:center;gap:.4rem}
.stat-value{font-family:"Rajdhani",sans-serif;font-size:1.9rem;font-weight:700;line-height:1;color:var(--text)}
.stat-unit{font-size:1rem;color:var(--text2);margin-left:.15rem}
.stat-sub{font-size:.72rem;color:var(--text3);margin-top:.3rem}
.ring-wrap{display:flex;align-items:center;gap:.9rem}
.ring-svg{flex-shrink:0}
.ring-track{fill:none;stroke:var(--border);stroke-width:6}
.ring-fill{fill:none;stroke-width:6;stroke-linecap:round;transition:stroke-dashoffset 1s cubic-bezier(.4,0,.2,1)}
.ring-info{flex:1}
.bar-gauge{height:8px;background:var(--border);border-radius:4px;margin-top:.6rem;overflow:hidden}
.bar-fill{height:100%;border-radius:4px;transition:width 1s cubic-bezier(.4,0,.2,1)}
.chip{display:inline-block;background:#f8fafc;border:1px solid var(--border);border-radius:6px;padding:.15rem .5rem;font-family:"Share Tech Mono",monospace;font-size:.72rem;color:var(--text2)}
.refresh-btn{border:1px solid var(--border);background:var(--surface);border-radius:9px;padding:.32rem .75rem;font-size:.74rem;color:var(--text2);cursor:pointer;font-family:"Kanit",sans-serif;transition:all .2s;display:inline-flex;align-items:center;gap:.3rem}
.refresh-btn:hover{background:#f0f4fa;color:var(--text)}
.refresh-btn.spin svg{animation:spinR .6s linear infinite}
@keyframes spinR{to{transform:rotate(360deg)}}
.online-badge{display:inline-flex;align-items:center;gap:.38rem;background:#f0fdf4;border:1px solid #86efac;color:#15803d;padding:.26rem .75rem;border-radius:20px;font-size:.7rem;font-family:"Share Tech Mono",monospace;font-weight:600}
.online-dot{width:7px;height:7px;border-radius:50%;background:var(--green);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}

/* SECTION LABEL */
.section-label{display:flex;align-items:center;gap:.5rem;font-family:"Rajdhani",sans-serif;font-size:.88rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:var(--text2);padding:.2rem 0 .75rem}

/* CARRIER BUTTONS */
.card-group{background:var(--surface);border-radius:20px;box-shadow:var(--shadow);overflow:hidden;border:1px solid var(--border)}
.card-group .carrier-btn+.carrier-btn{border-top:1px solid var(--border)}
.carrier-btn{width:100%;border:none;background:var(--surface);padding:1.05rem 1.2rem;cursor:pointer;display:flex;align-items:center;gap:1rem;text-align:left;transition:background .15s}
.carrier-btn:hover{background:#f6f9ff}
.btn-logo{width:54px;height:54px;border-radius:13px;display:flex;align-items:center;justify-content:center;flex-shrink:0;overflow:hidden;border:1px solid var(--border);font-size:1.6rem}
.logo-ais{background:#fff;border-color:var(--ais-bdr)}
.logo-true{background:#c8040d;border-color:#e0000a}
.logo-ssh{background:#1565c0;border-color:#1976d2}
.btn-info{flex:1;min-width:0}
.btn-name{font-family:"Rajdhani",sans-serif;font-size:1.12rem;font-weight:700;letter-spacing:.04em;display:block;margin-bottom:.15rem}
.btn-ais .btn-name{color:var(--ais)}.btn-true .btn-name{color:var(--true)}.btn-ssh .btn-name{color:var(--ssh)}
.btn-desc{font-size:.74rem;font-weight:300;color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block}
.btn-arrow{color:var(--text3);font-size:1.1rem;flex-shrink:0;transition:transform .18s}
.carrier-btn:hover .btn-arrow{transform:translateX(3px)}

/* SERVICE MONITOR */
.svc-grid{display:flex;flex-direction:column;gap:.42rem}
.svc-row{display:flex;align-items:center;gap:.65rem;border-radius:11px;padding:.52rem .85rem;border:1px solid var(--border);background:#f9fbfc;transition:all .15s}
.svc-row.up{border-color:#86efac;background:#f0fdf4}
.svc-row.down{border-color:#fca5a5;background:#fef2f2}
.svc-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.svc-dot.up{background:#22c55e;box-shadow:0 0 6px rgba(34,197,94,.55);animation:pulse 2s infinite}
.svc-dot.down{background:var(--red)}
.svc-icon{font-size:.9rem;flex-shrink:0}
.svc-name{font-family:"Share Tech Mono",monospace;font-size:.75rem;color:var(--text);flex:1;font-weight:600}
.svc-ports{font-family:"Share Tech Mono",monospace;font-size:.63rem;color:var(--text3)}
.svc-chip{font-family:"Share Tech Mono",monospace;font-size:.63rem;padding:.13rem .5rem;border-radius:20px;flex-shrink:0;font-weight:700}
.svc-chip.up{background:#dcfce7;color:#166534;border:1px solid #86efac}
.svc-chip.down{background:#fee2e2;color:#991b1b;border:1px solid #fca5a5}
.svc-chip.checking{background:#f1f5f9;color:var(--text3);border:1px solid var(--border)}

/* MODAL */
.modal-overlay{display:none;position:fixed;inset:0;z-index:1000;background:rgba(0,0,0,.4);backdrop-filter:blur(4px);align-items:flex-end;justify-content:center}
.modal-overlay.open{display:flex}
.modal{width:100%;max-width:520px;background:var(--surface);border-radius:26px 26px 0 0;overflow:hidden;position:relative;animation:slideUp .26s cubic-bezier(.34,1.1,.64,1);max-height:94vh;display:flex;flex-direction:column}
@keyframes slideUp{from{transform:translateY(100%);opacity:.5}to{transform:translateY(0);opacity:1}}
.modal::before{content:"";display:block;width:42px;height:4px;border-radius:2px;background:rgba(0,0,0,.12);margin:11px auto 0;flex-shrink:0}
.modal-header{padding:.85rem 1.4rem .95rem;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--border);flex-shrink:0}
.modal-title{font-family:"Rajdhani",sans-serif;font-size:1.05rem;font-weight:700;letter-spacing:.08em;display:flex;align-items:center;gap:.6rem}
.modal-ais .modal-title{color:var(--ais2)}.modal-true .modal-title{color:var(--true2)}.modal-ssh .modal-title{color:var(--ssh2)}
.modal-close{width:30px;height:30px;border-radius:50%;border:none;background:#f0f4f8;display:flex;align-items:center;justify-content:center;cursor:pointer;font-size:.85rem;color:var(--text2);transition:all .2s}
.modal-close:hover{background:#e2e8f0}
.modal-body{padding:1.1rem 1.4rem 1.8rem;overflow-y:auto;flex:1}

/* FORM */
.sni-badge{display:inline-flex;align-items:center;gap:.4rem;font-family:"Share Tech Mono",monospace;font-size:.68rem;padding:.25rem .75rem;border-radius:20px;margin-bottom:.95rem}
.sni-badge.ais{background:#edf7e3;border:1px solid #b5e08a;color:#316808}
.sni-badge.true{background:#fff0f0;border:1px solid #f5909a;color:#a6000c}
.sni-badge.ssh{background:#e6f3fc;border:1px solid #82c0ee;color:#0c4f84}
.fgrid{display:grid;grid-template-columns:1fr 1fr;gap:.6rem .8rem}
.fgrid .span2{grid-column:span 2}
.field{display:flex;flex-direction:column;gap:.3rem}
label{font-size:.67rem;font-family:"Share Tech Mono",monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--text3)}
input,select{background:#f6f9fc;border:1.5px solid #d8e2ee;border-radius:11px;padding:.6rem .9rem;color:var(--text);font-family:"Kanit",sans-serif;font-size:.88rem;outline:none;transition:border-color .2s,box-shadow .2s;width:100%}
input:focus,select:focus{background:#fff}
input.ais-focus:focus{border-color:#4d9a0e;box-shadow:0 0 0 3px rgba(77,154,14,.1)}
input.true-focus:focus{border-color:#d80e1c;box-shadow:0 0 0 3px rgba(216,14,28,.09)}
input.ssh-focus:focus{border-color:#1568a6;box-shadow:0 0 0 3px rgba(21,104,166,.1)}
.divider{height:1px;background:var(--border);margin:.8rem 0}
.submit-btn{width:100%;padding:.88rem;border:none;border-radius:13px;font-family:"Rajdhani",sans-serif;font-size:1.05rem;font-weight:700;letter-spacing:.1em;cursor:pointer;margin-top:.9rem;transition:all .2s}
.submit-btn:disabled{opacity:.5;cursor:not-allowed}
.submit-btn.ais-btn{background:linear-gradient(135deg,#3d7a0e,#5aaa18);color:#fff;box-shadow:0 4px 16px rgba(77,154,14,.32)}
.submit-btn.ais-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(77,154,14,.45);transform:translateY(-1px)}
.submit-btn.true-btn{background:linear-gradient(135deg,#a6000c,#d81020);color:#fff;box-shadow:0 4px 16px rgba(216,14,28,.28)}
.submit-btn.true-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(216,14,28,.4);transform:translateY(-1px)}
.submit-btn.ssh-btn{background:linear-gradient(135deg,#0c4f84,#1668a8);color:#fff;box-shadow:0 4px 16px rgba(21,104,166,.28)}
.submit-btn.ssh-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(21,104,166,.4);transform:translateY(-1px)}
.submit-btn.danger-btn{background:linear-gradient(135deg,#991b1b,#dc2626);color:#fff;box-shadow:0 4px 16px rgba(220,38,38,.22)}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite;vertical-align:middle;margin-right:.4rem}
@keyframes spin{to{transform:rotate(360deg)}}
.alert{display:none;margin-top:.7rem;padding:.68rem .9rem;border-radius:10px;font-size:.8rem;line-height:1.6}
.alert.ok{background:#f0fdf4;border:1px solid #86efac;color:#166534}
.alert.err{background:#fef2f2;border:1px solid #fca5a5;color:#991b1b}
.alert.info{background:#eff6ff;border:1px solid #93c5fd;color:#1e40af}

/* RESULT CARD */
.result-card{display:none;margin-top:1.1rem;border-radius:16px;overflow:hidden;border:1.5px solid var(--border);box-shadow:0 4px 16px rgba(0,0,0,.07)}
.result-card.show{display:block}
#ais-result.show{border-color:var(--ais-bdr)}
#true-result.show{border-color:var(--true-bdr)}
#ssh-result.show{border-color:var(--ssh-bdr)}
.result-header{padding:.65rem 1rem;font-family:"Share Tech Mono",monospace;font-size:.72rem;letter-spacing:.1em;display:flex;align-items:center;gap:.5rem;border-bottom:1px solid var(--border)}
.result-header .dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.result-header.ais-r{background:var(--ais-light);color:var(--ais2)}.result-header.ais-r .dot{background:var(--ais)}
.result-header.true-r{background:var(--true-light);color:var(--true2)}.result-header.true-r .dot{background:var(--true)}
.result-header.ssh-r{background:var(--ssh-light);color:var(--ssh2)}.result-header.ssh-r .dot{background:var(--ssh)}
.result-body{padding:.85rem 1rem;background:#fafcfe}
.info-rows{margin-bottom:.8rem}
.info-row{display:flex;justify-content:space-between;align-items:center;padding:.32rem 0;border-bottom:1px solid var(--border);font-size:.8rem}
.info-row:last-child{border-bottom:none}
.info-key{color:var(--text3);font-size:.7rem;font-family:"Share Tech Mono",monospace;letter-spacing:.08em}
.info-val{color:var(--text);text-align:right;word-break:break-all;max-width:62%}
.info-val.pass{font-family:"Share Tech Mono",monospace;color:var(--green);font-weight:600}
.link-box{background:#f0f5fb;border-radius:10px;padding:.7rem .9rem;font-family:"Share Tech Mono",monospace;font-size:.62rem;word-break:break-all;line-height:1.75;margin-bottom:.75rem;border:1px solid #dde3ec;color:var(--text2)}
.link-box.vless-link{border-left:3px solid #4d9a0e;color:#316808}
.link-box.npv-link{border-left:3px solid #1568a6;color:#0c4f84}
.qr-wrap{display:flex;justify-content:center;margin:.6rem 0 .8rem}
.qr-inner{background:#fff;padding:10px;border-radius:10px;display:inline-block;border:1px solid var(--border)}
.copy-row{display:flex;gap:.5rem;flex-wrap:wrap}
.copy-btn{flex:1;min-width:110px;padding:.52rem .7rem;border-radius:10px;border:1.5px solid var(--border);background:#fff;font-family:"Rajdhani",sans-serif;font-size:.85rem;font-weight:700;letter-spacing:.06em;cursor:pointer;transition:all .18s;color:var(--text2)}
.copy-btn.vless{border-color:#b5e08a;color:#316808}.copy-btn.vless:hover{background:#edf7e3}
.copy-btn.npv{border-color:#82c0ee;color:#0c4f84}.copy-btn.npv:hover{background:#e6f3fc}
.copy-btn.copied{opacity:.6;pointer-events:none}

/* USER LIST */
.mgmt-panel{background:var(--surface);border-radius:20px;border:1px solid var(--border);box-shadow:var(--shadow);overflow:hidden}
.mgmt-header{padding:.9rem 1.2rem;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;gap:.8rem}
.mgmt-title{font-family:"Rajdhani",sans-serif;font-size:1rem;font-weight:700;letter-spacing:.06em;color:var(--text);display:flex;align-items:center;gap:.5rem}
.search-bar{display:flex;align-items:center;gap:.5rem;padding:.8rem 1.2rem;border-bottom:1px solid var(--border)}
.search-bar input{flex:1;background:#f8fafc;border:1.5px solid var(--border);border-radius:10px;padding:.5rem .85rem;font-family:"Kanit",sans-serif;font-size:.88rem;outline:none;color:var(--text)}
.search-bar input:focus{border-color:var(--ssh);background:#fff}
.user-list{max-height:400px;overflow-y:auto}
.user-list::-webkit-scrollbar{width:4px}
.user-list::-webkit-scrollbar-thumb{background:rgba(0,0,0,.1);border-radius:2px}
.user-row{padding:.75rem 1.2rem;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.8rem;transition:background .15s;cursor:pointer}
.user-row:last-child{border-bottom:none}
.user-row:hover{background:#f8fafc}
.user-avatar{width:36px;height:36px;border-radius:10px;display:flex;align-items:center;justify-content:center;font-family:"Rajdhani",sans-serif;font-weight:700;font-size:.9rem;flex-shrink:0}
.ua-ais{background:var(--ais-light);color:var(--ais2);border:1px solid var(--ais-bdr)}
.ua-true{background:var(--true-light);color:var(--true2);border:1px solid var(--true-bdr)}
.user-info{flex:1;min-width:0}
.user-name{font-weight:600;font-size:.88rem;color:var(--text);margin-bottom:.1rem}
.user-meta{font-size:.72rem;color:var(--text3);font-family:"Share Tech Mono",monospace}
.status-badge{font-size:.68rem;padding:.2rem .55rem;border-radius:20px;font-family:"Share Tech Mono",monospace;flex-shrink:0}
.status-ok{background:#f0fdf4;border:1px solid #86efac;color:#166534}
.status-exp{background:#fff7ed;border:1px solid #fed7aa;color:#92400e}
.status-dead{background:#fef2f2;border:1px solid #fca5a5;color:#991b1b}
.empty-state{text-align:center;padding:2rem 1rem;color:var(--text3);font-size:.85rem}
.empty-state .ei{font-size:2rem;margin-bottom:.5rem}
.loading-row{text-align:center;padding:1.5rem;color:var(--text3);font-size:.82rem;display:flex;align-items:center;justify-content:center;gap:.5rem}

/* TOAST */
.toast{position:fixed;bottom:30px;left:50%;transform:translateX(-50%) scale(.95);background:#1a2332;color:#fff;padding:.65rem 1.6rem;border-radius:26px;font-family:"Rajdhani",sans-serif;font-weight:700;font-size:.9rem;opacity:0;pointer-events:none;z-index:9999;transition:opacity .25s,transform .25s;white-space:nowrap;box-shadow:0 8px 24px rgba(0,0,0,.22)}
.toast.show{opacity:1;transform:translateX(-50%) scale(1)}

@media(max-width:600px){.fgrid{grid-template-columns:1fr}.fgrid .span2{grid-column:span 1}}
</style>
</head>
<body>

<div class="site-header">
  <canvas id="snow-canvas"></canvas>
  <div class="site-logo">CHAIYA V2RAY PRO MAX</div>
  <div class="site-title">USER <span>CREATOR</span></div>
  <div class="site-sub">สร้างบัญชี VLESS <span class="dot">·</span> SSH-WS ผ่านหน้าเว็บ <span class="dot">·</span> v5</div>
  <button class="logout-btn" onclick="doLogout()">⎋ ออกจากระบบ</button>
</div>

<nav class="tab-nav">
  <button class="tab-btn active" id="tab-btn-dash"    onclick="switchTab('dash',this)">📊 แดชบอร์ด</button>
  <button class="tab-btn"        id="tab-btn-create"  onclick="switchTab('create',this)">➕ สร้างยูส</button>
  <button class="tab-btn"        id="tab-btn-manage"  onclick="switchTab('manage',this)">🔧 จัดการยูส</button>
  <button class="tab-btn"        id="tab-btn-online"  onclick="switchTab('online',this)">🟢 ออนไลน์</button>
</nav>

<!-- ── TAB: DASHBOARD ── -->
<div class="tab-panel active" id="tab-dash">
<div class="main">
  <div style="display:flex;align-items:center;justify-content:space-between">
    <span style="font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;color:var(--text2);letter-spacing:.1em">SYSTEM MONITOR</span>
    <button class="refresh-btn" id="refresh-btn" onclick="loadStats()">
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
      รีเฟรช
    </button>
  </div>

  <div class="stats-grid">
    <div class="stat-card">
      <div class="stat-label">⚡ CPU Usage</div>
      <div class="ring-wrap">
        <svg class="ring-svg" width="64" height="64" viewBox="0 0 64 64">
          <circle class="ring-track" cx="32" cy="32" r="26"/>
          <circle class="ring-fill" id="cpu-ring" cx="32" cy="32" r="26" stroke="#5a9e1c" stroke-dasharray="163.4" stroke-dashoffset="163.4" transform="rotate(-90 32 32)"/>
        </svg>
        <div class="ring-info">
          <div class="stat-value" id="cpu-val">--<span class="stat-unit">%</span></div>
          <div class="stat-sub" id="cpu-cores">-- cores</div>
        </div>
      </div>
      <div class="bar-gauge"><div class="bar-fill" id="cpu-bar" style="width:0%;background:linear-gradient(90deg,#5a9e1c,#8dc63f)"></div></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">🧠 RAM Usage</div>
      <div class="ring-wrap">
        <svg class="ring-svg" width="64" height="64" viewBox="0 0 64 64">
          <circle class="ring-track" cx="32" cy="32" r="26"/>
          <circle class="ring-fill" id="ram-ring" cx="32" cy="32" r="26" stroke="#1a6fa8" stroke-dasharray="163.4" stroke-dashoffset="163.4" transform="rotate(-90 32 32)"/>
        </svg>
        <div class="ring-info">
          <div class="stat-value" id="ram-val">--<span class="stat-unit">%</span></div>
          <div class="stat-sub" id="ram-detail">-- / -- GB</div>
        </div>
      </div>
      <div class="bar-gauge"><div class="bar-fill" id="ram-bar" style="width:0%;background:linear-gradient(90deg,#1a6fa8,#40b0ff)"></div></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">💾 Disk Usage</div>
      <div class="stat-value" id="disk-val">--<span class="stat-unit">%</span></div>
      <div class="stat-sub" id="disk-detail">-- / -- GB</div>
      <div class="bar-gauge"><div class="bar-fill" id="disk-bar" style="width:0%;background:linear-gradient(90deg,#f97316,#fb923c)"></div></div>
    </div>
    <div class="stat-card">
      <div class="stat-label">⏱ Uptime</div>
      <div class="stat-value" id="uptime-val" style="font-size:1.4rem">--</div>
      <div class="stat-sub" id="uptime-sub">กำลังโหลด...</div>
      <div style="margin-top:.4rem" id="load-avg-chips"></div>
    </div>
    <div class="stat-card wide">
      <div class="stat-label">🌐 Network I/O</div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:.5rem">
        <div>
          <div style="font-size:.68rem;color:var(--text3);font-family:'Share Tech Mono',monospace">↑ Upload</div>
          <div class="stat-value" id="net-up" style="font-size:1.4rem">--</div>
          <div class="stat-sub" id="net-up-total">total: --</div>
        </div>
        <div>
          <div style="font-size:.68rem;color:var(--text3);font-family:'Share Tech Mono',monospace">↓ Download</div>
          <div class="stat-value" id="net-down" style="font-size:1.4rem">--</div>
          <div class="stat-sub" id="net-down-total">total: --</div>
        </div>
      </div>
    </div>
    <div class="stat-card wide">
      <div class="stat-label">🛰 X-UI Panel Status</div>
      <div style="display:flex;align-items:center;gap:.8rem;flex-wrap:wrap">
        <div id="xui-status-badge"><span class="status-badge status-dead">กำลังตรวจสอบ...</span></div>
        <div>
          <div id="xui-ver" style="font-size:.75rem;color:var(--text2);font-family:'Share Tech Mono',monospace">เวอร์ชัน: --</div>
          <div id="xui-traffic" style="font-size:.7rem;color:var(--text3);font-family:'Share Tech Mono',monospace">Traffic inbounds: --</div>
        </div>
      </div>
    </div>
  </div>

  <div>
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:.6rem">
      <div class="section-label" style="padding:0">🛠 Service Monitor</div>
      <button class="refresh-btn" onclick="loadServiceStatus()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        เช็คสถานะ
      </button>
    </div>
    <div class="svc-grid" id="svc-grid">
      <div class="loading-row"><span style="font-size:.8rem;color:var(--text3)">กำลังตรวจสอบ...</span></div>
    </div>
  </div>

  <div style="text-align:center;font-size:.7rem;color:var(--text3);font-family:'Share Tech Mono',monospace" id="last-update">อัพเดทล่าสุด: --</div>
</div>
</div>

<!-- ── TAB: CREATE USER ── -->
<div class="tab-panel" id="tab-create">
<div class="main">
  <div class="section-label">📡 เลือก Protocol</div>
  <div class="card-group">
    <button class="carrier-btn btn-ais" onclick="openModal('ais')">
      <div class="btn-logo logo-ais">🟢</div>
      <div class="btn-info">
        <span class="btn-name">AIS / VLESS-WS</span>
        <span class="btn-desc">Port 8080 · SNI: cj-ebb.speedtest.net</span>
      </div>
      <span class="btn-arrow">›</span>
    </button>
    <button class="carrier-btn btn-true" onclick="openModal('true')">
      <div class="btn-logo logo-true">🔴</div>
      <div class="btn-info">
        <span class="btn-name">TRUE / VLESS-WS</span>
        <span class="btn-desc">Port 8880 · SNI: true-internet.zoom.xyz.services</span>
      </div>
      <span class="btn-arrow">›</span>
    </button>
    <button class="carrier-btn btn-ssh" onclick="openModal('ssh')">
      <div class="btn-logo logo-ssh">🔵</div>
      <div class="btn-info">
        <span class="btn-name">SSH-WS</span>
        <span class="btn-desc">Port 80 · Dropbear:143 · HTTP-WS Tunnel</span>
      </div>
      <span class="btn-arrow">›</span>
    </button>
  </div>
</div>
</div>

<!-- ── TAB: MANAGE ── -->
<div class="tab-panel" id="tab-manage">
<div class="main">
  <div class="mgmt-panel">
    <div class="mgmt-header">
      <div class="mgmt-title">👥 รายชื่อ VLESS Users</div>
      <button class="refresh-btn" onclick="loadUserList()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        รีเฟรช
      </button>
    </div>
    <div class="search-bar">
      <input type="text" placeholder="🔍 ค้นหาชื่อ..." oninput="filterUsers(this.value)">
    </div>
    <div class="user-list" id="user-list">
      <div class="loading-row">กำลังโหลด...</div>
    </div>
  </div>
</div>
</div>

<!-- ── TAB: ONLINE ── -->
<div class="tab-panel" id="tab-online">
<div class="main">
  <div class="mgmt-panel">
    <div class="mgmt-header">
      <div class="mgmt-title">🟢 Online Users</div>
      <button class="refresh-btn" id="online-refresh" onclick="loadOnlineUsers()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        รีเฟรช
      </button>
    </div>
    <div class="user-list" id="online-list">
      <div class="loading-row">กำลังโหลด...</div>
    </div>
  </div>
</div>
</div>

<!-- ── MODALS ── -->
<!-- AIS Modal -->
<div class="modal-overlay modal-ais" id="modal-ais">
<div class="modal">
  <div class="modal-header">
    <div class="modal-title">🟢 สร้าง AIS / VLESS-WS</div>
    <button class="modal-close" onclick="closeModal('ais')">✕</button>
  </div>
  <div class="modal-body">
    <div class="sni-badge ais">🌐 cj-ebb.speedtest.net · Port 8080</div>
    <div class="fgrid">
      <div class="field span2"><label>ชื่อ User (Email)</label><input type="text" id="ais-email" placeholder="user@ais" class="ais-focus"></div>
      <div class="field"><label>วันใช้งาน</label><input type="number" id="ais-days" value="30" min="1" class="ais-focus"></div>
      <div class="field"><label>จำกัด IP</label><input type="number" id="ais-iplimit" value="2" min="1" class="ais-focus"></div>
      <div class="field span2"><label>จำกัดข้อมูล (GB, 0=ไม่จำกัด)</label><input type="number" id="ais-gb" value="0" min="0" class="ais-focus"></div>
    </div>
    <button class="submit-btn ais-btn" id="ais-submit" onclick="createAIS()">⚡ สร้าง AIS Account</button>
    <div class="alert" id="ais-alert"></div>
    <div class="result-card" id="ais-result">
      <div class="result-header ais-r"><span class="dot"></span>✅ สร้างสำเร็จ</div>
      <div class="result-body">
        <div class="info-rows" id="ais-info-rows"></div>
        <div class="link-box vless-link" id="ais-vless-link"></div>
        <div class="qr-wrap"><div class="qr-inner" id="ais-qr"></div></div>
        <div class="copy-row">
          <button class="copy-btn vless" id="ais-copy-vless" onclick="copyEl('ais-vless-link','ais-copy-vless')">📋 Copy VLESS</button>
        </div>
      </div>
    </div>
  </div>
</div>
</div>

<!-- TRUE Modal -->
<div class="modal-overlay modal-true" id="modal-true">
<div class="modal">
  <div class="modal-header">
    <div class="modal-title">🔴 สร้าง TRUE / VLESS-WS</div>
    <button class="modal-close" onclick="closeModal('true')">✕</button>
  </div>
  <div class="modal-body">
    <div class="sni-badge true">🌐 true-internet.zoom.xyz.services · Port 8880</div>
    <div class="fgrid">
      <div class="field span2"><label>ชื่อ User (Email)</label><input type="text" id="true-email" placeholder="user@true" class="true-focus"></div>
      <div class="field"><label>วันใช้งาน</label><input type="number" id="true-days" value="30" min="1" class="true-focus"></div>
      <div class="field"><label>จำกัด IP</label><input type="number" id="true-iplimit" value="2" min="1" class="true-focus"></div>
      <div class="field span2"><label>จำกัดข้อมูล (GB, 0=ไม่จำกัด)</label><input type="number" id="true-gb" value="0" min="0" class="true-focus"></div>
    </div>
    <button class="submit-btn true-btn" id="true-submit" onclick="createTRUE()">⚡ สร้าง TRUE Account</button>
    <div class="alert" id="true-alert"></div>
    <div class="result-card" id="true-result">
      <div class="result-header true-r"><span class="dot"></span>✅ สร้างสำเร็จ</div>
      <div class="result-body">
        <div class="info-rows" id="true-info-rows"></div>
        <div class="link-box vless-link" id="true-vless-link"></div>
        <div class="qr-wrap"><div class="qr-inner" id="true-qr"></div></div>
        <div class="copy-row">
          <button class="copy-btn vless" id="true-copy-vless" onclick="copyEl('true-vless-link','true-copy-vless')">📋 Copy VLESS</button>
        </div>
      </div>
    </div>
  </div>
</div>
</div>

<!-- SSH Modal -->
<div class="modal-overlay modal-ssh" id="modal-ssh">
<div class="modal">
  <div class="modal-header">
    <div class="modal-title">🔵 สร้าง SSH-WS Account</div>
    <button class="modal-close" onclick="closeModal('ssh')">✕</button>
  </div>
  <div class="modal-body">
    <div class="sni-badge ssh">🌐 Port 80 · Dropbear:143 · HTTP-WS Tunnel</div>
    <div class="fgrid">
      <div class="field span2"><label>Username</label><input type="text" id="ssh-user" placeholder="username" class="ssh-focus"></div>
      <div class="field span2"><label>Password</label><input type="password" id="ssh-pass" placeholder="password" class="ssh-focus"></div>
      <div class="field"><label>วันใช้งาน</label><input type="number" id="ssh-days" value="30" min="1" class="ssh-focus"></div>
    </div>
    <button class="submit-btn ssh-btn" id="ssh-submit" onclick="createSSH()">⚡ สร้าง SSH Account</button>
    <div class="alert" id="ssh-alert"></div>
    <div class="result-card" id="ssh-result">
      <div class="result-header ssh-r"><span class="dot"></span>✅ สร้างสำเร็จ</div>
      <div class="result-body">
        <div class="info-rows" id="ssh-info-rows"></div>
      </div>
    </div>
  </div>
</div>
</div>

<div class="toast" id="toast"></div>

<script src="config.js"></script>
<script>
/* ── CONFIG ── */
const CFG     = (typeof window.CHAIYA_CONFIG !== 'undefined') ? window.CHAIYA_CONFIG : {};
const HOST    = CFG.host    || location.hostname;
const XUI_API = '/xui-api';
const SSH_API = '/api';

/* ── SESSION GUARD ── */
(function(){
  const s = sessionStorage.getItem('chaiya_auth');
  if (!s) { window.location.replace('index.html'); return; }
  try {
    const d = JSON.parse(s);
    if (!d.user || !d.pass || Date.now() >= d.exp) {
      sessionStorage.removeItem('chaiya_auth');
      window.location.replace('index.html');
    }
  } catch(e) {
    sessionStorage.removeItem('chaiya_auth');
    window.location.replace('index.html');
  }
})();

let _xuiCookieSet = false;
let _allUsers = [], _filteredUsers = [];

/* ── TAB SWITCH ── */
function switchTab(tab, btn) {
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-' + tab).classList.add('active');
  if (btn) btn.classList.add('active');
  if (tab === 'dash') { loadStats(); loadServiceStatus(); }
  if (tab === 'manage') loadUserList();
  if (tab === 'online') loadOnlineUsers();
}

/* ── MODAL ── */
function openModal(id) { document.getElementById('modal-' + id).classList.add('open'); document.body.style.overflow = 'hidden'; }
function closeModal(id) { document.getElementById('modal-' + id).classList.remove('open'); document.body.style.overflow = ''; }
document.querySelectorAll('.modal-overlay').forEach(el => {
  el.addEventListener('click', e => { if (e.target === el) { el.classList.remove('open'); document.body.style.overflow = ''; } });
});

/* ── UTILS ── */
function val(id) { return document.getElementById(id).value.trim(); }
function setAlert(pre, msg, type) {
  const el = document.getElementById(pre + '-alert');
  el.className = 'alert ' + type; el.textContent = msg; el.style.display = msg ? 'block' : 'none';
}
function toast(msg, ok = true) {
  const el = document.getElementById('toast');
  el.textContent = msg; el.style.background = ok ? '#1a2332' : '#ef4444';
  el.classList.add('show'); setTimeout(() => el.classList.remove('show'), 2400);
}
function genUUID() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}
function fmtBytes(bytes) {
  if (bytes === 0) return '0 B';
  const k = 1024, s = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return (bytes / Math.pow(k, i)).toFixed(1) + ' ' + s[i];
}
function copyEl(elId, btnId) {
  const text = document.getElementById(elId).textContent.trim();
  const done = () => {
    toast('📋 คัดลอกแล้ว!');
    if (btnId) {
      const b = document.getElementById(btnId);
      if (b) { const o = b.textContent; b.textContent = '✓ Copied!'; b.classList.add('copied'); setTimeout(() => { b.textContent = o; b.classList.remove('copied'); }, 2000); }
    }
  };
  if (navigator.clipboard) navigator.clipboard.writeText(text).then(done).catch(() => fbCopy(text, done));
  else fbCopy(text, done);
  function fbCopy(t, cb) { const ta = document.createElement('textarea'); ta.value = t; ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0;'; document.body.appendChild(ta); ta.focus(); ta.select(); try { document.execCommand('copy'); cb(); } catch(e) { toast('❌ คัดลอกไม่ได้', false); } document.body.removeChild(ta); }
}

/* ── XUI LOGIN ── (login ใหม่ทุกครั้ง ไม่ง้อ cookie เก่า) */
async function xuiLogin() {
  // อ่าน credentials จาก sessionStorage ก่อน แล้ว fallback ไป config.js
  let user = CFG.xui_user || 'admin', pass = CFG.xui_pass || '';
  try {
    const s = JSON.parse(sessionStorage.getItem('chaiya_auth') || '{}');
    if (s.user) user = s.user;
    if (s.pass) pass = s.pass;
  } catch(e) {}
  // force re-login ทุกครั้ง
  _xuiCookieSet = false;
  const form = new URLSearchParams({ username: user, password: pass });
  const r = await fetch(XUI_API + '/login', {
    method: 'POST', credentials: 'include',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString()
  });
  const d = await r.json();
  _xuiCookieSet = !!d.success;
  return d.success;
}
async function xuiGet(path) {
  if (!_xuiCookieSet) await xuiLogin();
  const r = await fetch(XUI_API + path, { credentials: 'include' });
  return r.json();
}
async function xuiPost(path, payload) {
  if (!_xuiCookieSet) await xuiLogin();
  const r = await fetch(XUI_API + path, {
    method: 'POST', credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  });
  return r.json();
}

/* ── STAT RINGS ── */
function setRing(id, pct, color) {
  const el = document.getElementById(id);
  if (!el) return;
  const circ = 163.4;
  el.style.stroke = color || el.style.stroke;
  el.style.strokeDashoffset = circ - (circ * Math.min(pct, 100) / 100);
}
function setBar(id, pct) {
  const el = document.getElementById(id);
  if (el) el.style.width = Math.min(pct, 100) + '%';
}
function barColor(pct) { return pct > 85 ? 'linear-gradient(90deg,#dc2626,#ef4444)' : pct > 65 ? 'linear-gradient(90deg,#d97706,#f97316)' : ''; }
function setBadge(ok, text) {
  const el = document.getElementById('xui-status-badge');
  if (!el) return;
  el.innerHTML = ok
    ? `<span class="online-badge"><span class="online-dot"></span>${text}</span>`
    : `<span class="status-badge status-dead">⚠ ${text}</span>`;
}

/* ── LOAD STATS (xui API) ── */
async function loadStats() {
  const btn = document.getElementById('refresh-btn');
  if (btn) btn.classList.add('spin');
  try {
    const ok = await xuiLogin();
    if (!ok) { setBadge(false, 'Login ไม่สำเร็จ'); return; }

    const sv = await xuiGet('/panel/api/server/status').catch(() => null);
    if (sv && sv.success && sv.obj) {
      const o = sv.obj;
      // CPU
      const cpuPct = Math.round(o.cpu || 0);
      document.getElementById('cpu-val').innerHTML = `${cpuPct}<span class="stat-unit">%</span>`;
      document.getElementById('cpu-cores').textContent = (o.cpuCores || o.logicalPro || '--') + ' cores';
      setRing('cpu-ring', cpuPct, '#5a9e1c'); setBar('cpu-bar', cpuPct);
      const cb = document.getElementById('cpu-bar');
      if (cb) { const c = barColor(cpuPct); if (c) cb.style.background = c; }
      // RAM
      const ramT = ((o.mem && o.mem.total) || 0) / 1073741824;
      const ramU = ((o.mem && o.mem.current) || 0) / 1073741824;
      const ramPct = ramT > 0 ? Math.round(ramU / ramT * 100) : 0;
      document.getElementById('ram-val').innerHTML = `${ramPct}<span class="stat-unit">%</span>`;
      document.getElementById('ram-detail').textContent = ramU.toFixed(1) + ' / ' + ramT.toFixed(1) + ' GB';
      setRing('ram-ring', ramPct, '#1a6fa8'); setBar('ram-bar', ramPct);
      const rb = document.getElementById('ram-bar');
      if (rb) { const c = barColor(ramPct); if (c) rb.style.background = c; }
      // Disk
      const diskT = ((o.disk && o.disk.total) || 0) / 1073741824;
      const diskU = ((o.disk && o.disk.current) || 0) / 1073741824;
      const diskPct = diskT > 0 ? Math.round(diskU / diskT * 100) : 0;
      document.getElementById('disk-val').innerHTML = `${diskPct}<span class="stat-unit">%</span>`;
      document.getElementById('disk-detail').textContent = diskU.toFixed(0) + ' / ' + diskT.toFixed(0) + ' GB';
      setBar('disk-bar', diskPct);
      // Uptime
      const up = o.uptime || 0;
      const d = Math.floor(up / 86400), h = Math.floor((up % 86400) / 3600), m = Math.floor((up % 3600) / 60);
      document.getElementById('uptime-val').textContent = d > 0 ? `${d}d ${h}h` : `${h}h ${m}m`;
      document.getElementById('uptime-sub').textContent = `${d} วัน ${h} ชม. ${m} นาที`;
      const loads = o.loads || [];
      document.getElementById('load-avg-chips').innerHTML = loads.map((l, i) => ['1m','5m','15m'][i] ? `<span class="chip">${['1m','5m','15m'][i]}: ${l.toFixed(2)}</span> ` : '').join('');
      // Network
      const ns = o.netIO || null;
      if (ns) {
        document.getElementById('net-up').textContent = fmtBytes(ns.up || 0) + '/s';
        document.getElementById('net-down').textContent = fmtBytes(ns.down || 0) + '/s';
      }
      const nt = o.netTraffic || null;
      if (nt) {
        document.getElementById('net-up-total').textContent = 'total: ' + fmtBytes(nt.sent || 0);
        document.getElementById('net-down-total').textContent = 'total: ' + fmtBytes(nt.recv || 0);
      }
      document.getElementById('xui-ver').textContent = 'เวอร์ชัน: ' + (o.xrayVersion || '--');
      setBadge(true, 'ออนไลน์');
    }

    const ibl = await xuiGet('/panel/api/inbounds/list').catch(() => null);
    if (ibl && ibl.success) {
      document.getElementById('xui-traffic').textContent = `Traffic inbounds: ${(ibl.obj || []).length} รายการ`;
    }

    document.getElementById('last-update').textContent = 'อัพเดทล่าสุด: ' + new Date().toLocaleTimeString('th-TH');
  } catch(e) {
    setBadge(false, 'Error: ' + e.message);
  } finally {
    if (btn) btn.classList.remove('spin');
  }
}

/* ── SERVICE STATUS (ผ่าน SSH API) ── */
async function loadServiceStatus() {
  const grid = document.getElementById('svc-grid');
  const SERVICES = [
    { name: 'x-ui Panel',      icon: '🛰', ports: ':2053', key: 'xui' },
    { name: 'Python SSH API',  icon: '🐍', ports: ':6789', key: 'ssh' },
    { name: 'Dropbear SSH',    icon: '🐻', ports: ':143 :109', key: 'dropbear' },
    { name: 'nginx / WS',      icon: '🌐', ports: ':80 :443',  key: 'nginx' },
    { name: 'SSH-WS-SSL',      icon: '🔒', ports: ':443',      key: 'sshws' },
    { name: 'badvpn UDP-GW',   icon: '🎮', ports: ':7300',     key: 'badvpn' },
  ];
  grid.innerHTML = SERVICES.map(s => `
    <div class="svc-row" id="svc-${s.key}">
      <div class="svc-dot checking"></div>
      <div class="svc-icon">${s.icon}</div>
      <div class="svc-name">${s.name}</div>
      <div class="svc-ports">${s.ports}</div>
      <div class="svc-chip checking" id="svc-chip-${s.key}">ตรวจสอบ...</div>
    </div>`).join('');

  try {
    const r = await fetch(SSH_API + '/status');
    const d = await r.json();
    const svcMap = d.services || {};

    SERVICES.forEach(s => {
      const up = svcMap[s.key] === true || svcMap[s.key] === 'active';
      const row = document.getElementById('svc-' + s.key);
      const chip = document.getElementById('svc-chip-' + s.key);
      const dot = row ? row.querySelector('.svc-dot') : null;
      if (row) row.className = 'svc-row ' + (up ? 'up' : 'down');
      if (dot) dot.className = 'svc-dot ' + (up ? 'up' : 'down');
      if (chip) { chip.className = 'svc-chip ' + (up ? 'up' : 'down'); chip.textContent = up ? 'RUNNING' : 'DOWN'; }
    });
  } catch(e) {
    SERVICES.forEach(s => {
      const chip = document.getElementById('svc-chip-' + s.key);
      if (chip) { chip.className = 'svc-chip down'; chip.textContent = 'ERROR'; }
    });
  }
}

/* ── CREATE AIS (VLESS port 8080) ── */
async function createAIS() {
  const email   = val('ais-email');
  const days    = parseInt(val('ais-days')) || 30;
  const ipLimit = parseInt(val('ais-iplimit')) || 2;
  const gb      = parseInt(val('ais-gb')) || 0;
  if (!email) return setAlert('ais', 'กรุณาใส่ชื่อ User', 'err');

  const btn = document.getElementById('ais-submit');
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>กำลังสร้าง...';
  setAlert('ais', '', '');

  try {
    const ok = await xuiLogin();
    if (!ok) throw new Error('Login x-ui ไม่สำเร็จ');

    // หา inbound id port 8080
    const list = await xuiGet('/panel/api/inbounds/list');
    const ib = (list.obj || []).find(x => x.port === 8080);
    if (!ib) throw new Error('ไม่พบ inbound port 8080 — รัน setup ก่อน');

    const uid = genUUID();
    const expMs = days > 0 ? (Date.now() + days * 86400000) : 0;
    const totalBytes = gb > 0 ? gb * 1073741824 : 0;

    const res = await xuiPost('/panel/api/inbounds/addClient', {
      id: ib.id,
      settings: JSON.stringify({
        clients: [{
          id: uid, flow: '', email, limitIp: ipLimit,
          totalGB: totalBytes, expiryTime: expMs,
          enable: true, tgId: '', subId: '', comment: '', reset: 0
        }]
      })
    });
    if (!res.success) throw new Error(res.msg || 'สร้างไม่สำเร็จ');

    // สร้าง VLESS link
    const sni = 'cj-ebb.speedtest.net';
    const vlessLink = `vless://${uid}@${HOST}:8080?type=ws&security=none&path=%2Fvless&host=${sni}#${encodeURIComponent(email + '-AIS')}`;

    document.getElementById('ais-info-rows').innerHTML = `
      <div class="info-row"><span class="info-key">Email</span><span class="info-val">${email}</span></div>
      <div class="info-row"><span class="info-key">UUID</span><span class="info-val" style="font-family:'Share Tech Mono',monospace;font-size:.62rem">${uid}</span></div>
      <div class="info-row"><span class="info-key">Port</span><span class="info-val">8080</span></div>
      <div class="info-row"><span class="info-key">วันหมดอายุ</span><span class="info-val">${days} วัน</span></div>
      <div class="info-row"><span class="info-key">IP Limit</span><span class="info-val">${ipLimit} IPs</span></div>
      <div class="info-row"><span class="info-key">ข้อมูล</span><span class="info-val">${gb > 0 ? gb + ' GB' : 'ไม่จำกัด'}</span></div>`;
    document.getElementById('ais-vless-link').textContent = vlessLink;
    document.getElementById('ais-qr').innerHTML = '';
    new QRCode(document.getElementById('ais-qr'), { text: vlessLink, width: 180, height: 180 });
    document.getElementById('ais-result').classList.add('show');
    setAlert('ais', '✅ สร้าง AIS Account สำเร็จ!', 'ok');
    toast('✅ สร้าง AIS Account สำเร็จ!');
  } catch(e) {
    setAlert('ais', '❌ ' + e.message, 'err');
  } finally {
    btn.disabled = false; btn.innerHTML = '⚡ สร้าง AIS Account';
  }
}

/* ── CREATE TRUE (VLESS port 8880) ── */
async function createTRUE() {
  const email   = val('true-email');
  const days    = parseInt(val('true-days')) || 30;
  const ipLimit = parseInt(val('true-iplimit')) || 2;
  const gb      = parseInt(val('true-gb')) || 0;
  if (!email) return setAlert('true', 'กรุณาใส่ชื่อ User', 'err');

  const btn = document.getElementById('true-submit');
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>กำลังสร้าง...';
  setAlert('true', '', '');

  try {
    const ok = await xuiLogin();
    if (!ok) throw new Error('Login x-ui ไม่สำเร็จ');

    const list = await xuiGet('/panel/api/inbounds/list');
    const ib = (list.obj || []).find(x => x.port === 8880);
    if (!ib) throw new Error('ไม่พบ inbound port 8880 — รัน setup ก่อน');

    const uid = genUUID();
    const expMs = days > 0 ? (Date.now() + days * 86400000) : 0;
    const totalBytes = gb > 0 ? gb * 1073741824 : 0;

    const res = await xuiPost('/panel/api/inbounds/addClient', {
      id: ib.id,
      settings: JSON.stringify({
        clients: [{
          id: uid, flow: '', email, limitIp: ipLimit,
          totalGB: totalBytes, expiryTime: expMs,
          enable: true, tgId: '', subId: '', comment: '', reset: 0
        }]
      })
    });
    if (!res.success) throw new Error(res.msg || 'สร้างไม่สำเร็จ');

    const sni = 'true-internet.zoom.xyz.services';
    const vlessLink = `vless://${uid}@${HOST}:8880?type=ws&security=none&path=%2Fvless&host=${sni}#${encodeURIComponent(email + '-TRUE')}`;

    document.getElementById('true-info-rows').innerHTML = `
      <div class="info-row"><span class="info-key">Email</span><span class="info-val">${email}</span></div>
      <div class="info-row"><span class="info-key">UUID</span><span class="info-val" style="font-family:'Share Tech Mono',monospace;font-size:.62rem">${uid}</span></div>
      <div class="info-row"><span class="info-key">Port</span><span class="info-val">8880</span></div>
      <div class="info-row"><span class="info-key">วันหมดอายุ</span><span class="info-val">${days} วัน</span></div>`;
    document.getElementById('true-vless-link').textContent = vlessLink;
    document.getElementById('true-qr').innerHTML = '';
    new QRCode(document.getElementById('true-qr'), { text: vlessLink, width: 180, height: 180 });
    document.getElementById('true-result').classList.add('show');
    setAlert('true', '✅ สร้าง TRUE Account สำเร็จ!', 'ok');
    toast('✅ สร้าง TRUE Account สำเร็จ!');
  } catch(e) {
    setAlert('true', '❌ ' + e.message, 'err');
  } finally {
    btn.disabled = false; btn.innerHTML = '⚡ สร้าง TRUE Account';
  }
}

/* ── CREATE SSH ── */
async function createSSH() {
  const user = val('ssh-user');
  const pass = val('ssh-pass');
  const days = parseInt(val('ssh-days')) || 30;
  if (!user) return setAlert('ssh', 'กรุณาใส่ Username', 'err');
  if (!pass) return setAlert('ssh', 'กรุณาใส่ Password', 'err');

  const btn = document.getElementById('ssh-submit');
  btn.disabled = true; btn.innerHTML = '<span class="spinner"></span>กำลังสร้าง...';
  setAlert('ssh', '', '');

  try {
    const r = await fetch(SSH_API + '/create_ssh', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ user, password: pass, days })
    });
    const d = await r.json();
    if (!d.ok) throw new Error(d.error || 'สร้างไม่สำเร็จ');

    document.getElementById('ssh-info-rows').innerHTML = `
      <div class="info-row"><span class="info-key">Username</span><span class="info-val">${user}</span></div>
      <div class="info-row"><span class="info-key">Password</span><span class="info-val pass">${pass}</span></div>
      <div class="info-row"><span class="info-key">Host</span><span class="info-val">${HOST}</span></div>
      <div class="info-row"><span class="info-key">Port SSH</span><span class="info-val">143 / 109</span></div>
      <div class="info-row"><span class="info-key">Port WS</span><span class="info-val">80</span></div>
      <div class="info-row"><span class="info-key">หมดอายุ</span><span class="info-val">${d.exp}</span></div>`;
    document.getElementById('ssh-result').classList.add('show');
    setAlert('ssh', '✅ สร้าง SSH Account สำเร็จ!', 'ok');
    toast('✅ สร้าง SSH Account สำเร็จ!');
  } catch(e) {
    setAlert('ssh', '❌ ' + e.message, 'err');
  } finally {
    btn.disabled = false; btn.innerHTML = '⚡ สร้าง SSH Account';
  }
}

/* ── USER LIST ── */
async function loadUserList() {
  const list = document.getElementById('user-list');
  list.innerHTML = '<div class="loading-row">กำลังโหลด...</div>';
  try {
    const ok = await xuiLogin();
    if (!ok) throw new Error('Login ไม่สำเร็จ');
    const d = await xuiGet('/panel/api/inbounds/list');
    if (!d.success) throw new Error('โหลดไม่สำเร็จ');
    _allUsers = [];
    (d.obj || []).forEach(ib => {
      const settings = typeof ib.settings === 'string' ? JSON.parse(ib.settings) : ib.settings;
      (settings.clients || []).forEach(c => {
        _allUsers.push({ inboundId: ib.id, inboundPort: ib.port, protocol: ib.protocol, email: c.email || c.id, uuid: c.id, expiryTime: c.expiryTime || 0, enable: c.enable !== false });
      });
    });
    _filteredUsers = [..._allUsers];
    renderUserList(_filteredUsers);
  } catch(e) {
    list.innerHTML = `<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }
}

function renderUserList(users) {
  const list = document.getElementById('user-list');
  if (!users.length) { list.innerHTML = '<div class="empty-state"><div class="ei">🔍</div><div>ไม่พบยูสเซอร์</div></div>'; return; }
  const now = Date.now();
  list.innerHTML = users.map(u => {
    const isAis = u.inboundPort === 8080;
    let statusHtml = '', expStr = '';
    if (u.expiryTime === 0) { expStr = 'ไม่จำกัด'; statusHtml = '<span class="status-badge status-ok">✓ Active</span>'; }
    else {
      const diff = u.expiryTime - now;
      const days = Math.ceil(diff / 86400000);
      if (diff < 0) { expStr = 'หมดอายุแล้ว'; statusHtml = '<span class="status-badge status-dead">✗ Expired</span>'; }
      else if (days <= 3) { expStr = `เหลือ ${days} วัน`; statusHtml = `<span class="status-badge status-exp">⚠ ${days}d</span>`; }
      else { expStr = `${days} วัน`; statusHtml = '<span class="status-badge status-ok">✓ Active</span>'; }
    }
    return `<div class="user-row">
      <div class="user-avatar ${isAis ? 'ua-ais' : 'ua-true'}">${(u.email || '?')[0].toUpperCase()}</div>
      <div class="user-info">
        <div class="user-name">${u.email}</div>
        <div class="user-meta">Port ${u.inboundPort} · ${expStr}</div>
      </div>
      ${statusHtml}
    </div>`;
  }).join('');
}

function filterUsers(q) {
  const s = q.toLowerCase();
  _filteredUsers = _allUsers.filter(u => (u.email || '').toLowerCase().includes(s));
  renderUserList(_filteredUsers);
}

/* ── ONLINE USERS ── */
async function loadOnlineUsers() {
  const btn = document.getElementById('online-refresh');
  if (btn) btn.classList.add('spin');
  const list = document.getElementById('online-list');
  list.innerHTML = '<div class="loading-row">กำลังโหลด...</div>';
  try {
    const ok = await xuiLogin();
    if (!ok) throw new Error('Login ไม่สำเร็จ');
    const od = await xuiGet('/panel/api/inbounds/onlines').catch(() => null);
    const onlineEmails = (od && od.obj) ? od.obj : [];

    if (!_allUsers.length) await loadUserList().catch(() => {});
    const userMap = {};
    _allUsers.forEach(u => { userMap[u.email] = u; });

    if (!onlineEmails.length) {
      list.innerHTML = '<div class="empty-state"><div class="ei">😴</div><div>ไม่มียูสออนไลน์ตอนนี้</div></div>';
      return;
    }

    const now = Date.now();
    list.innerHTML = onlineEmails.map(email => {
      const u = userMap[email] || null;
      const isAis = u && u.inboundPort === 8080;
      let expLabel = 'ไม่จำกัด', expColor = '#16a34a';
      if (u && u.expiryTime > 0) {
        const diff = u.expiryTime - now;
        const d = Math.ceil(diff / 86400000);
        expLabel = diff < 0 ? 'หมดอายุแล้ว' : `${d} วัน`;
        expColor = diff < 0 ? '#dc2626' : d <= 3 ? '#ea6c10' : '#16a34a';
      }
      return `<div class="user-row">
        <div class="user-avatar ${isAis ? 'ua-ais' : 'ua-true'}">${(email || '?')[0].toUpperCase()}</div>
        <div class="user-info">
          <div class="user-name">${email} <span style="font-size:.6rem;background:#eff6ff;border:1px solid #93c5fd;color:#1e40af;padding:.1rem .4rem;border-radius:20px;font-family:'Share Tech Mono',monospace">${u ? 'Port ' + u.inboundPort : 'VLESS'}</span></div>
          <div class="user-meta" style="color:${expColor}">📅 ${expLabel}</div>
        </div>
        <span style="width:10px;height:10px;border-radius:50%;background:#22c55e;box-shadow:0 0 6px rgba(34,197,94,.55);animation:pulse 2s infinite;flex-shrink:0"></span>
      </div>`;
    }).join('');
  } catch(e) {
    list.innerHTML = `<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  } finally {
    if (btn) btn.classList.remove('spin');
  }
}

/* ── LOGOUT ── */
function doLogout() {
  sessionStorage.removeItem('chaiya_auth');
  window.location.replace('index.html');
}

/* ── SNOW ── */
function startSnow(canvasId, count) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  let flakes = [];
  function resize() { canvas.width = window.innerWidth; canvas.height = 180; }
  resize();
  window.addEventListener('resize', resize);
  for (let i = 0; i < count; i++) flakes.push(mkFlake());
  function mkFlake() { return { x: Math.random() * canvas.width, y: Math.random() * canvas.height, r: Math.random() * 1.8 + .6, speed: Math.random() * .6 + .2, drift: (Math.random() - .5) * .3, opacity: Math.random() * .35 + .08 }; }
  function tick() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    flakes.forEach((f, i) => {
      ctx.beginPath(); ctx.arc(f.x, f.y, f.r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(255,255,255,${f.opacity})`; ctx.fill();
      f.y += f.speed; f.x += f.drift;
      if (f.y > canvas.height + 5) flakes[i] = mkFlake();
    });
    requestAnimationFrame(tick);
  }
  tick();
}

/* ── INIT ── */
startSnow('snow-canvas', 30);

// โหลดข้อมูลทันทีที่หน้าพร้อม — login ใหม่ทุกครั้ง ไม่ง้อ cookie เก่า
window.addEventListener('load', () => {
  _xuiCookieSet = false;
  loadStats();
  loadServiceStatus();
  setInterval(() => {
    if (document.getElementById('tab-dash').classList.contains('active')) {
      loadStats();
      loadServiceStatus();
    }
  }, 30000);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      _xuiCookieSet = false;
      loadStats();
      loadServiceStatus();
    }
  });
});
</script>
</body>
</html>
DASHEOF
ok "Dashboard พร้อม"

# ── CERTBOT AUTO-RENEW ────────────────────────────────────────
[[ $USE_SSL -eq 1 ]] && \
  (crontab -l 2>/dev/null; echo "0 3 * * * systemctl stop chaiya-sshws && certbot renew --quiet --standalone && systemctl reload nginx; systemctl start chaiya-sshws") | sort -u | crontab -

# ── MENU COMMAND ─────────────────────────────────────────────
cat > /usr/local/bin/menu << 'MENUEOF'
#!/bin/bash
G='\033[1;32m' C='\033[1;36m' Y='\033[1;33m' R='\033[0;31m' N='\033[0m'
DOMAIN=$(cat /etc/chaiya/domain.conf 2>/dev/null || echo "")
SERVER_IP=$(cat /etc/chaiya/my_ip.conf 2>/dev/null || hostname -I | awk '{print $1}')
XUI_PORT=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")
XUI_USER=$(cat /etc/chaiya/xui-user.conf 2>/dev/null || echo "admin")
clear
echo ""
echo -e "${G}╔══════════════════════════════════════════════╗${N}"
echo -e "${G}║         CHAIYA VPN PANEL v5  🛸              ║${N}"
echo -e "${G}╚══════════════════════════════════════════════╝${N}"
echo ""
echo -e "  IP Server   : ${C}$SERVER_IP${N}"
echo -e "  Domain      : ${C}$DOMAIN${N}"
echo -e "  Panel URL   : ${C}https://$DOMAIN${N}"
echo -e "  3x-ui Port  : ${C}$XUI_PORT${N}"
echo -e "  3x-ui User  : ${Y}$XUI_USER${N}"
echo ""
echo -e "  Dropbear SSH: ${C}143, 109${N}"
echo -e "  WS-Tunnel   : ${C}80 → Dropbear:143${N}"
echo -e "  BadVPN UDPGW: ${C}7300${N}"
echo -e "  VMess-WS    : ${C}8080 /vmess${N}"
echo -e "  VLESS-WS    : ${C}8880 /vless${N}"
echo ""
echo -e "  ┌─ Services ───────────────────────────────────┐"
for svc in nginx x-ui dropbear chaiya-sshws chaiya-ssh-api chaiya-badvpn; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo -e "  │  ${G}✅ $svc${N}"
  else
    echo -e "  │  ${R}❌ $svc${N}"
  fi
done
echo -e "  └──────────────────────────────────────────────┘"
echo ""
MENUEOF
chmod +x /usr/local/bin/menu
grep -q 'alias menu=' /root/.bashrc 2>/dev/null || echo 'alias menu="/usr/local/bin/menu"' >> /root/.bashrc

# ── PERMISSIONS ──────────────────────────────────────────────
chmod -R 755 /opt/chaiya-panel

# ── FINAL CHECK ──────────────────────────────────────────────
echo ""
info "ตรวจสอบ services..."
sleep 3

for svc in nginx x-ui dropbear chaiya-sshws chaiya-ssh-api chaiya-badvpn; do
  systemctl is-active --quiet "$svc" && ok "$svc ✅" || warn "$svc ⚠️"
done

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   CHAIYA VPN PANEL v5 - ติดตั้งสำเร็จ! 🚀  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
if [[ $USE_SSL -eq 1 ]]; then
  echo -e "  🌐 Panel URL   : ${CYAN}${BOLD}https://${DOMAIN}${NC}"
  echo -e "  🔒 SSL         : ${GREEN}✅ HTTPS พร้อม${NC}"
else
  echo -e "  🌐 Panel URL   : ${YELLOW}http://${DOMAIN}:81 (ยังไม่มี SSL)${NC}"
  echo -e "  🔒 SSL         : ${YELLOW}⚠️  ยังไม่มี — รัน: certbot certonly --standalone -d ${DOMAIN}${NC}"
fi
echo -e "  👤 3x-ui User  : ${YELLOW}${XUI_USER}${NC}"
echo -e "  🔒 3x-ui Pass  : ${YELLOW}${XUI_PASS}${NC}"
echo -e "  🐻 Dropbear    : ${CYAN}port 143, 109${NC}"
echo -e "  🌐 WS-Tunnel   : ${CYAN}port 80 → Dropbear:143${NC}"
echo -e "  🎮 BadVPN UDPGW: ${CYAN}port 7300${NC}"
echo -e "  📡 VMess-WS    : ${CYAN}port 8080, path /vmess${NC}"
echo -e "  📡 VLESS-WS    : ${CYAN}port 8880, path /vless${NC}"
echo ""
echo -e "  💡 พิมพ์ ${CYAN}menu${NC} เพื่อดูรายละเอียด"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
