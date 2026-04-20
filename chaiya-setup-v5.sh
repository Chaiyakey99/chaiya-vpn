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
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVgg4oCUIExvZ2luPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1SYWpkaGFuaTp3Z2h0QDYwMDs3MDAmZmFtaWx5PUthbml0OndnaHRAMzAwOzQwMDs2MDAmZmFtaWx5PVNoYXJlK1RlY2grTW9ubyZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KKiwqOjpiZWZvcmUsKjo6YWZ0ZXJ7Ym94LXNpemluZzpib3JkZXItYm94O21hcmdpbjowO3BhZGRpbmc6MH0KYm9keXsKICBtaW4taGVpZ2h0OjEwMHZoO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjsKICBiYWNrZ3JvdW5kOnJhZGlhbC1ncmFkaWVudChlbGxpcHNlIDE0MCUgMTMwJSBhdCA1MCUgLTEwJSwjMGQxZjNjIDAlLCMwNjBlMWUgNTUlLCMwMjA4MTAgMTAwJSk7CiAgZm9udC1mYW1pbHk6J0thbml0JyxzYW5zLXNlcmlmO292ZXJmbG93OmhpZGRlbjtwb3NpdGlvbjpyZWxhdGl2ZTsKfQpjYW52YXN7cG9zaXRpb246Zml4ZWQ7aW5zZXQ6MDtwb2ludGVyLWV2ZW50czpub25lO3otaW5kZXg6MH0KLmNhcmR7CiAgcG9zaXRpb246cmVsYXRpdmU7ei1pbmRleDoxMDsKICB3aWR0aDo5MCU7bWF4LXdpZHRoOjM4MHB4OwogIGJhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDQpOwogIGJvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7CiAgYm9yZGVyLXJhZGl1czoyNHB4O3BhZGRpbmc6Mi40cmVtIDJyZW0gMnJlbTsKICBiYWNrZHJvcC1maWx0ZXI6Ymx1cigxOHB4KTsKICBib3gtc2hhZG93OjAgMjBweCA2MHB4IHJnYmEoMCwwLDAsLjUpOwp9Ci5sb2dvewogIGZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZTsKICBmb250LXNpemU6LjU1cmVtO2xldHRlci1zcGFjaW5nOi4zNWVtOwogIGNvbG9yOnJnYmEoMTAwLDIwMCw1MCwuNik7CiAgdGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLWJvdHRvbTouNXJlbTsKICBkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Z2FwOi42cmVtOwp9Ci5sb2dvOjpiZWZvcmUsLmxvZ286OmFmdGVye2NvbnRlbnQ6Jyc7ZmxleDoxO2hlaWdodDoxcHg7YmFja2dyb3VuZDpyZ2JhKDEwMCwyMDAsNTAsLjMpfQoudGl0bGV7CiAgZm9udC1mYW1pbHk6J1JhamRoYW5pJyxzYW5zLXNlcmlmO2ZvbnQtc2l6ZToyLjFyZW07Zm9udC13ZWlnaHQ6NzAwOwogIHRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiNlZWY2ZmY7bGV0dGVyLXNwYWNpbmc6LjA4ZW07bWFyZ2luLWJvdHRvbTouMjVyZW07Cn0KLnRpdGxlIHNwYW57Y29sb3I6IzcyZDEyNDt0ZXh0LXNoYWRvdzowIDAgMjBweCByZ2JhKDEwMCwyMDAsMzAsLjQpfQouc3VidGl0bGV7CiAgZm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouNjVyZW07CiAgY29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMyk7dGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLWJvdHRvbToycmVtO2xldHRlci1zcGFjaW5nOi4wNmVtOwp9Ci5zZXJ2ZXItYmFkZ2V7CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6LjVyZW07anVzdGlmeS1jb250ZW50OmNlbnRlcjsKICBiYWNrZ3JvdW5kOnJnYmEoMTE0LDIwOSwzNiwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgxMTQsMjA5LDM2LC4yKTsKICBib3JkZXItcmFkaXVzOjIwcHg7cGFkZGluZzouMzVyZW0gLjlyZW07bWFyZ2luLWJvdHRvbToxLjVyZW07CiAgZm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouNjhyZW07Y29sb3I6cmdiYSgxMTQsMjA5LDM2LC44KTsKfQouc2VydmVyLWJhZGdlIC5kb3R7d2lkdGg6N3B4O2hlaWdodDo3cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojNzJkMTI0O2FuaW1hdGlvbjpwdWxzZSAycyBpbmZpbml0ZX0KQGtleWZyYW1lcyBwdWxzZXswJSwxMDAle29wYWNpdHk6MX01MCV7b3BhY2l0eTouM319Ci5maWVsZHttYXJnaW4tYm90dG9tOjEuMXJlbX0KbGFiZWx7ZGlzcGxheTpibG9jaztmb250LXNpemU6LjY1cmVtO2ZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzouMWVtO2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsLjQpO21hcmdpbi1ib3R0b206LjQ1cmVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZX0KLmlucHV0LXdyYXB7cG9zaXRpb246cmVsYXRpdmV9CmlucHV0ewogIHdpZHRoOjEwMCU7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNik7CiAgYm9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEyKTtib3JkZXItcmFkaXVzOjEycHg7CiAgcGFkZGluZzouN3JlbSAxcmVtO2NvbG9yOiNlOGY0ZmY7CiAgZm9udC1mYW1pbHk6J0thbml0JyxzYW5zLXNlcmlmO2ZvbnQtc2l6ZTouOXJlbTtvdXRsaW5lOm5vbmU7CiAgdHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzLGJhY2tncm91bmQgLjJzOwp9CmlucHV0OjpwbGFjZWhvbGRlcntjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4yKX0KaW5wdXQ6Zm9jdXN7Ym9yZGVyLWNvbG9yOnJnYmEoMTE0LDIwOSwzNiwuNSk7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wOSl9Ci5leWUtYnRuewogIHBvc2l0aW9uOmFic29sdXRlO3JpZ2h0Oi43NXJlbTt0b3A6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpOwogIGJhY2tncm91bmQ6bm9uZTtib3JkZXI6bm9uZTtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MXJlbTsKfQoubG9naW4tYnRuewogIHdpZHRoOjEwMCU7cGFkZGluZzouODVyZW07Ym9yZGVyOm5vbmU7Ym9yZGVyLXJhZGl1czoxM3B4OwogIGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjM2Q3YTBlLCM1YWFhMTgpO2NvbG9yOiNmZmY7CiAgZm9udC1mYW1pbHk6J1JhamRoYW5pJyxzYW5zLXNlcmlmO2ZvbnQtc2l6ZToxLjA1cmVtO2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMWVtOwogIGN1cnNvcjpwb2ludGVyO21hcmdpbi10b3A6LjVyZW07dHJhbnNpdGlvbjphbGwgLjJzOwogIGJveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDkwLDE3MCwyNCwuMyk7Cn0KLmxvZ2luLWJ0bjpob3Zlcjpub3QoOmRpc2FibGVkKXtib3gtc2hhZG93OjAgNnB4IDI0cHggcmdiYSg5MCwxNzAsMjQsLjQ1KTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KX0KLmxvZ2luLWJ0bjpkaXNhYmxlZHtvcGFjaXR5Oi41O2N1cnNvcjpub3QtYWxsb3dlZH0KLnNwaW5uZXJ7ZGlzcGxheTppbmxpbmUtYmxvY2s7d2lkdGg6MTRweDtoZWlnaHQ6MTRweDtib3JkZXI6MnB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjMpO2JvcmRlci10b3AtY29sb3I6I2ZmZjtib3JkZXItcmFkaXVzOjUwJTthbmltYXRpb246c3BpbiAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6LjRyZW19CkBrZXlmcmFtZXMgc3Bpbnt0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9fQouYWxlcnR7bWFyZ2luLXRvcDouOHJlbTtwYWRkaW5nOi42NXJlbSAuOXJlbTtib3JkZXItcmFkaXVzOjEwcHg7Zm9udC1zaXplOi44cmVtO2Rpc3BsYXk6bm9uZTtsaW5lLWhlaWdodDoxLjV9Ci5hbGVydC5va3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4zKTtjb2xvcjojNGFkZTgwfQouYWxlcnQuZXJye2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjMpO2NvbG9yOiNmODcxNzF9Ci5mb290ZXJ7dGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLXRvcDoxLjVyZW07Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouNnJlbTtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4xNSk7bGV0dGVyLXNwYWNpbmc6LjA2ZW19Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+CjxjYW52YXMgaWQ9InNub3ctY2FudmFzIj48L2NhbnZhcz4KPGRpdiBjbGFzcz0iY2FyZCI+CiAgPGRpdiBjbGFzcz0ibG9nbyI+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L2Rpdj4KICA8ZGl2IGNsYXNzPSJ0aXRsZSI+QURNSU4gPHNwYW4+UEFORUw8L3NwYW4+PC9kaXY+CiAgPGRpdiBjbGFzcz0ic3VidGl0bGUiPngtdWkgTWFuYWdlbWVudCBEYXNoYm9hcmQ8L2Rpdj4KICA8ZGl2IGNsYXNzPSJzZXJ2ZXItYmFkZ2UiPgogICAgPHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPgogICAgPHNwYW4gaWQ9InNlcnZlci1ob3N0Ij7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L3NwYW4+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgPGxhYmVsPvCfkaQgVVNFUk5BTUU8L2xhYmVsPgogICAgPGlucHV0IHR5cGU9InRleHQiIGlkPSJpbnAtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIiBhdXRvY29tcGxldGU9InVzZXJuYW1lIj4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICA8bGFiZWw+8J+UkSBQQVNTV09SRDwvbGFiZWw+CiAgICA8ZGl2IGNsYXNzPSJpbnB1dC13cmFwIj4KICAgICAgPGlucHV0IHR5cGU9InBhc3N3b3JkIiBpZD0iaW5wLXBhc3MiIHBsYWNlaG9sZGVyPSLigKLigKLigKLigKLigKLigKLigKLigKIiIGF1dG9jb21wbGV0ZT0iY3VycmVudC1wYXNzd29yZCI+CiAgICAgIDxidXR0b24gY2xhc3M9ImV5ZS1idG4iIGlkPSJleWUtYnRuIiBvbmNsaWNrPSJ0b2dnbGVFeWUoKSIgdHlwZT0iYnV0dG9uIj7wn5GBPC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2Rpdj4KICA8YnV0dG9uIGNsYXNzPSJsb2dpbi1idG4iIGlkPSJsb2dpbi1idG4iIG9uY2xpY2s9ImRvTG9naW4oKSI+4pqhIOC5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mjwvYnV0dG9uPgogIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWxlcnQiPjwvZGl2PgogIDxkaXYgY2xhc3M9ImZvb3RlciIgaWQ9ImZvb3Rlci10aW1lIj48L2Rpdj4KPC9kaXY+CjxzY3JpcHQgc3JjPSJjb25maWcuanMiPjwvc2NyaXB0Pgo8c2NyaXB0Pgpjb25zdCBDRkcgPSAodHlwZW9mIHdpbmRvdy5DSEFJWUFfQ09ORklHICE9PSAndW5kZWZpbmVkJykgPyB3aW5kb3cuQ0hBSVlBX0NPTkZJRyA6IHt9Owpjb25zdCBYVUlfQVBJID0gJy94dWktYXBpJzsKY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwpjb25zdCBEQVNIQk9BUkQgPSBDRkcuZGFzaGJvYXJkX3VybCB8fCAnc3Nod3MuaHRtbCc7CgovLyDguYHguKrguJTguIcgc2VydmVyIGhvc3QKZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlcnZlci1ob3N0JykudGV4dENvbnRlbnQgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKCi8vIGF1dG8tZmlsbCB1c2VybmFtZSDguIjguLLguIEgY29uZmlnCmlmIChDRkcueHVpX3VzZXIpIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbnAtdXNlcicpLnZhbHVlID0gQ0ZHLnh1aV91c2VyOwoKLy8gY2xvY2sKZnVuY3Rpb24gdXBkYXRlQ2xvY2soKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvb3Rlci10aW1lJykudGV4dENvbnRlbnQgPQogICAgbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJykgKyAnIMK3IENIQUlZQSBWUE4gU1lTVEVNIMK3IHY1LjAnOwp9CnVwZGF0ZUNsb2NrKCk7CnNldEludGVydmFsKHVwZGF0ZUNsb2NrLCAxMDAwKTsKCi8vIGVudGVyIGtleQpkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7IGlmIChlLmtleSA9PT0gJ0VudGVyJykgZG9Mb2dpbigpOyB9KTsKCmxldCBleWVPcGVuID0gZmFsc2U7CmZ1bmN0aW9uIHRvZ2dsZUV5ZSgpIHsKICBleWVPcGVuID0gIWV5ZU9wZW47CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lucC1wYXNzJykudHlwZSA9IGV5ZU9wZW4gPyAndGV4dCcgOiAncGFzc3dvcmQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdleWUtYnRuJykudGV4dENvbnRlbnQgPSBleWVPcGVuID8gJ/CfmYgnIDogJ/CfkYEnOwp9CgpmdW5jdGlvbiBzaG93QWxlcnQobXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWxlcnQnKTsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyArIHR5cGU7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvTG9naW4oKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbnAtdXNlcicpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBwYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lucC1wYXNzJykudmFsdWU7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCAnZXJyJyk7CiAgaWYgKCFwYXNzKSByZXR1cm4gc2hvd0FsZXJ0KCfguIHguKPguLjguJPguLLguYPguKrguYggUGFzc3dvcmQnLCAnZXJyJyk7CgogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2dpbi1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOwogIGJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW5uZXIiPjwvc3Bhbj4g4LiB4Liz4Lil4Lix4LiH4LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4LiaLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWxlcnQnKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwoKICB0cnkgewogICAgY29uc3QgZm9ybSA9IG5ldyBVUkxTZWFyY2hQYXJhbXMoeyB1c2VybmFtZTogdXNlciwgcGFzc3dvcmQ6IHBhc3MgfSk7CiAgICBjb25zdCByZXMgPSBhd2FpdCBQcm9taXNlLnJhY2UoWwogICAgICBmZXRjaChYVUlfQVBJICsgJy9sb2dpbicsIHsKICAgICAgICBtZXRob2Q6ICdQT1NUJywKICAgICAgICBjcmVkZW50aWFsczogJ2luY2x1ZGUnLAogICAgICAgIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQnIH0sCiAgICAgICAgYm9keTogZm9ybS50b1N0cmluZygpCiAgICAgIH0pLAogICAgICBuZXcgUHJvbWlzZSgoXywgcmVqKSA9PiBzZXRUaW1lb3V0KCgpID0+IHJlaihuZXcgRXJyb3IoJ1RpbWVvdXQnKSksIDgwMDApKQogICAgXSk7CiAgICBjb25zdCBkYXRhID0gYXdhaXQgcmVzLmpzb24oKTsKICAgIGlmIChkYXRhLnN1Y2Nlc3MpIHsKICAgICAgLy8g4LmA4LiB4LmH4LiaIGNyZWRlbnRpYWxzIOC5g+C4mSBzZXNzaW9uU3RvcmFnZSDguYDguJ7guLfguYjguK3guYPguKvguYkgZGFzaGJvYXJkIOC5g+C4iuC5iSBsb2dpbiDguIvguYnguLPguYTguJTguYkKICAgICAgc2Vzc2lvblN0b3JhZ2Uuc2V0SXRlbShTRVNTSU9OX0tFWSwgSlNPTi5zdHJpbmdpZnkoewogICAgICAgIHVzZXIsIHBhc3MsCiAgICAgICAgZXhwOiBEYXRlLm5vdygpICsgOCAqIDM2MDAgKiAxMDAwCiAgICAgIH0pKTsKICAgICAgc2hvd0FsZXJ0KCfinIUg4LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4Lia4Liq4Liz4LmA4Lij4LmH4LiIIOC4geC4s+C4peC4seC4hyByZWRpcmVjdC4uLicsICdvaycpOwogICAgICBzZXRUaW1lb3V0KCgpID0+IHsgd2luZG93LmxvY2F0aW9uLnJlcGxhY2UoREFTSEJPQVJEKTsgfSwgODAwKTsKICAgIH0gZWxzZSB7CiAgICAgIHNob3dBbGVydCgn4p2MIFVzZXJuYW1lIOC4q+C4o+C4t+C4rSBQYXNzd29yZCDguYTguKHguYjguJbguLnguIHguJXguYnguK3guIcnLCAnZXJyJyk7CiAgICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogICAgICBidG4uaW5uZXJIVE1MID0gJ+KaoSDguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJonOwogICAgfQogIH0gY2F0Y2ggKGUpIHsKICAgIHNob3dBbGVydCgn4p2MICcgKyBlLm1lc3NhZ2UsICdlcnInKTsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogICAgYnRuLmlubmVySFRNTCA9ICfimqEg4LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4LiaJzsKICB9Cn0KCi8vIFNub3cKZnVuY3Rpb24gc3RhcnRTbm93KGNhbnZhc0lkLCBjb3VudCkgewogIGNvbnN0IGNhbnZhcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhbnZhc0lkKTsKICBpZiAoIWNhbnZhcykgcmV0dXJuOwogIGNvbnN0IGN0eCA9IGNhbnZhcy5nZXRDb250ZXh0KCcyZCcpOwogIGxldCBmbGFrZXMgPSBbXTsKICBmdW5jdGlvbiByZXNpemUoKSB7CiAgICBjYW52YXMud2lkdGggPSB3aW5kb3cuaW5uZXJXaWR0aDsKICAgIGNhbnZhcy5oZWlnaHQgPSB3aW5kb3cuaW5uZXJIZWlnaHQ7CiAgfQogIHJlc2l6ZSgpOwogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCByZXNpemUpOwogIGZ1bmN0aW9uIG1rRmxha2UoKSB7CiAgICByZXR1cm4gewogICAgICB4OiBNYXRoLnJhbmRvbSgpICogY2FudmFzLndpZHRoLAogICAgICB5OiBNYXRoLnJhbmRvbSgpICogY2FudmFzLmhlaWdodCAtIGNhbnZhcy5oZWlnaHQsCiAgICAgIHI6IE1hdGgucmFuZG9tKCkgKiAyICsgMSwKICAgICAgc3BlZWQ6IE1hdGgucmFuZG9tKCkgKiAwLjggKyAwLjMsCiAgICAgIGRyaWZ0OiAoTWF0aC5yYW5kb20oKSAtIDAuNSkgKiAwLjQsCiAgICAgIG9wYWNpdHk6IE1hdGgucmFuZG9tKCkgKiAwLjQgKyAwLjEKICAgIH07CiAgfQogIGZvciAobGV0IGkgPSAwOyBpIDwgY291bnQ7IGkrKykgZmxha2VzLnB1c2gobWtGbGFrZSgpKTsKICBmdW5jdGlvbiB0aWNrKCkgewogICAgY3R4LmNsZWFyUmVjdCgwLCAwLCBjYW52YXMud2lkdGgsIGNhbnZhcy5oZWlnaHQpOwogICAgZmxha2VzLmZvckVhY2goKGYsIGkpID0+IHsKICAgICAgY3R4LmJlZ2luUGF0aCgpOwogICAgICBjdHguYXJjKGYueCwgZi55LCBmLnIsIDAsIE1hdGguUEkgKiAyKTsKICAgICAgY3R4LmZpbGxTdHlsZSA9IGByZ2JhKDI1NSwyNTUsMjU1LCR7Zi5vcGFjaXR5fSlgOwogICAgICBjdHguZmlsbCgpOwogICAgICBmLnkgKz0gZi5zcGVlZDsKICAgICAgZi54ICs9IGYuZHJpZnQ7CiAgICAgIGlmIChmLnkgPiBjYW52YXMuaGVpZ2h0ICsgMTApIGZsYWtlc1tpXSA9IG1rRmxha2UoKTsKICAgIH0pOwogICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKHRpY2spOwogIH0KICB0aWNrKCk7Cn0Kc3RhcnRTbm93KCdzbm93LWNhbnZhcycsIDQwKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCxpbml0aWFsLXNjYWxlPTEiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVgg4oCUIERhc2hib2FyZDwvdGl0bGU+CjxsaW5rIGhyZWY9Imh0dHBzOi8vZm9udHMuZ29vZ2xlYXBpcy5jb20vY3NzMj9mYW1pbHk9UmFqZGhhbmk6d2dodEA2MDA7NzAwJmZhbWlseT1LYW5pdDp3Z2h0QDMwMDs0MDA7NjAwJmZhbWlseT1TaGFyZStUZWNoK01vbm8mZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c2NyaXB0IHNyYz0iaHR0cHM6Ly9jZG5qcy5jbG91ZGZsYXJlLmNvbS9hamF4L2xpYnMvcXJjb2RlanMvMS4wLjAvcXJjb2RlLm1pbi5qcyI+PC9zY3JpcHQ+CjxzdHlsZT4KOnJvb3R7CiAgLS1iZzojZWJlZmY2Oy0tc3VyZmFjZTojZmZmOy0tYm9yZGVyOiNlMmU4ZjA7CiAgLS1zaGFkb3c6MCAycHggMTJweCByZ2JhKDAsMCwwLC4wOCk7CiAgLS1haXM6IzVhOWUxYzstLWFpczI6IzNkN2EwZTstLWFpcy1saWdodDojZjBmOWU4Oy0tYWlzLWJkcjojYzVlODlhOwogIC0tdHJ1ZTojZTAxMDIwOy0tdHJ1ZTI6I2I4MDAwZTstLXRydWUtbGlnaHQ6I2ZmZjBmMDstLXRydWUtYmRyOiNmOGEwYTg7CiAgLS1zc2g6IzFhNmZhODstLXNzaDI6IzBkNTQ4NzstLXNzaC1saWdodDojZThmNGZjOy0tc3NoLWJkcjojOTBjYWYwOwogIC0tdGV4dDojMWEyMzMyOy0tdGV4dDI6IzRhNjA3MjstLXRleHQzOiM4MDk5YWM7CiAgLS1ncmVlbjojMjJjNTVlOy0tb3JhbmdlOiNmOTczMTY7LS1yZWQ6I2VmNDQ0NDstLXB1cnBsZTojOGI1Y2Y2Owp9CiosKjo6YmVmb3JlLCo6OmFmdGVye2JveC1zaXppbmc6Ym9yZGVyLWJveDttYXJnaW46MDtwYWRkaW5nOjB9CmJvZHl7YmFja2dyb3VuZDp2YXIoLS1iZyk7Y29sb3I6dmFyKC0tdGV4dCk7Zm9udC1mYW1pbHk6J0thbml0JyxzYW5zLXNlcmlmO21pbi1oZWlnaHQ6MTAwdmg7b3ZlcmZsb3cteDpoaWRkZW59CgovKiBIRUFERVIgKi8KLnNpdGUtaGVhZGVyewogIHRleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MnJlbSAxLjVyZW0gMS42cmVtOwogIGJhY2tncm91bmQ6cmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgMTQwJSAxMzAlIGF0IDUwJSAtMTAlLCMwZDFmM2MgMCUsIzA2MGUxZSA1NSUsIzAyMDgxMCAxMDAlKTsKICBib3JkZXItYm90dG9tOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4wNSk7CiAgcG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuOwp9Ci5zaXRlLWhlYWRlcjo6YmVmb3JlewogIGNvbnRlbnQ6IiI7cG9zaXRpb246YWJzb2x1dGU7dG9wOi02MHB4O2xlZnQ6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVYKC01MCUpOwogIHdpZHRoOjM4MHB4O2hlaWdodDoyMDBweDsKICBiYWNrZ3JvdW5kOnJhZGlhbC1ncmFkaWVudChlbGxpcHNlLHJnYmEoODAsMTYwLDIwLC4xOCkgMCUsdHJhbnNwYXJlbnQgNzAlKTsKICBwb2ludGVyLWV2ZW50czpub25lOwp9CiNzbm93LWNhbnZhc3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDowfQouc2l0ZS1sb2dvewogIGZvbnQtZmFtaWx5OiJTaGFyZSBUZWNoIE1vbm8iLG1vbm9zcGFjZTtmb250LXNpemU6LjZyZW07bGV0dGVyLXNwYWNpbmc6LjM1ZW07CiAgY29sb3I6cmdiYSgxMDAsMjAwLDUwLC42NSk7bWFyZ2luLWJvdHRvbTouNDVyZW07CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDouN3JlbTtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7Cn0KLnNpdGUtbG9nbzo6YmVmb3JlLC5zaXRlLWxvZ286OmFmdGVye2NvbnRlbnQ6IiI7ZGlzcGxheTppbmxpbmUtYmxvY2s7aGVpZ2h0OjFweDt3aWR0aDo0MnB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTAwLDIwMCw1MCwuNDUpKX0KLnNpdGUtbG9nbzo6YWZ0ZXJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcscmdiYSgxMDAsMjAwLDUwLC40NSksdHJhbnNwYXJlbnQpfQouc2l0ZS10aXRsZXtmb250LWZhbWlseToiUmFqZGhhbmkiLHNhbnMtc2VyaWY7Zm9udC1zaXplOjIuNHJlbTtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjA4ZW07Y29sb3I6I2VlZjZmZjtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7bGluZS1oZWlnaHQ6MS4xfQouc2l0ZS10aXRsZSBzcGFue2NvbG9yOiM3MmQxMjQ7dGV4dC1zaGFkb3c6MCAwIDIycHggcmdiYSgxMDAsMjAwLDMwLC40KX0KLnNpdGUtc3Vie2ZvbnQtc2l6ZTouNzJyZW07Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO21hcmdpbi10b3A6LjRyZW07Zm9udC1mYW1pbHk6IlNoYXJlIFRlY2ggTW9ubyIsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOi4wN2VtO3Bvc2l0aW9uOnJlbGF0aXZlO3otaW5kZXg6MX0KLnNpdGUtc3ViIC5kb3R7bWFyZ2luOjAgLjRyZW07Y29sb3I6cmdiYSgxMTAsMjAwLDUwLC40NSl9Ci5sb2dvdXQtYnRue3Bvc2l0aW9uOmFic29sdXRlO3RvcDoxcmVtO3JpZ2h0OjFyZW07YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4xMik7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuNDUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6LjNyZW0gLjc1cmVtO2ZvbnQtZmFtaWx5OiJTaGFyZSBUZWNoIE1vbm8iLG1vbm9zcGFjZTtmb250LXNpemU6LjYycmVtO2N1cnNvcjpwb2ludGVyO3otaW5kZXg6MTA7dHJhbnNpdGlvbjphbGwgLjJzfQoubG9nb3V0LWJ0bjpob3Zlcntjb2xvcjpyZ2JhKDI0OCwxMTMsMTEzLC44KX0KCi8qIFRBQlMgKi8KLnRhYi1uYXZ7ZGlzcGxheTpmbGV4O2JhY2tncm91bmQ6IzE5MjMzMztib3JkZXItYm90dG9tOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4wNyk7b3ZlcmZsb3cteDphdXRvOy13ZWJraXQtb3ZlcmZsb3ctc2Nyb2xsaW5nOnRvdWNoO3Bvc2l0aW9uOnN0aWNreTt0b3A6MDt6LWluZGV4OjIwMH0KLnRhYi1uYXY6Oi13ZWJraXQtc2Nyb2xsYmFye2Rpc3BsYXk6bm9uZX0KLnRhYi1idG57ZmxleDoxO21pbi13aWR0aDo4MHB4O3BhZGRpbmc6Ljc4cmVtIC41cmVtO2JvcmRlcjpub25lO2JhY2tncm91bmQ6dHJhbnNwYXJlbnQ7Zm9udC1mYW1pbHk6Ikthbml0IixzYW5zLXNlcmlmO2ZvbnQtc2l6ZTouNzhyZW07Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsLjM4KTtjdXJzb3I6cG9pbnRlcjtib3JkZXItYm90dG9tOjJweCBzb2xpZCB0cmFuc3BhcmVudDt0cmFuc2l0aW9uOmFsbCAuMnM7d2hpdGUtc3BhY2U6bm93cmFwfQoudGFiLWJ0bjpob3Zlcntjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC42NSk7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wMyl9Ci50YWItYnRuLmFjdGl2ZXtjb2xvcjojNzJkMTI0O2JvcmRlci1ib3R0b20tY29sb3I6IzcyZDEyNDtiYWNrZ3JvdW5kOnJnYmEoMTE0LDIwOSwzNiwuMDYpfQoudGFiLXBhbmVse2Rpc3BsYXk6bm9uZX0udGFiLXBhbmVsLmFjdGl2ZXtkaXNwbGF5OmJsb2NrfQoubWFpbnttYXgtd2lkdGg6NTIwcHg7bWFyZ2luOjAgYXV0bztwYWRkaW5nOjEuNXJlbSAxcmVtIDRyZW07ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6MS4zcmVtfQoKLyogU1RBVCBDQVJEUyAqLwouc3RhdHMtZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOi44cmVtfQouc3RhdC1jYXJke2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZSk7Ym9yZGVyLXJhZGl1czoxOHB4O3BhZGRpbmc6MS4xcmVtIDEuMTVyZW07Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47dHJhbnNpdGlvbjpib3gtc2hhZG93IC4ycyx0cmFuc2Zvcm0gLjJzfQouc3RhdC1jYXJkOmhvdmVye2JveC1zaGFkb3c6MCA2cHggMjhweCByZ2JhKDAsMCwwLC4xMSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCl9Ci5zdGF0LWNhcmQud2lkZXtncmlkLWNvbHVtbjpzcGFuIDJ9Ci5zdGF0LWxhYmVse2ZvbnQtZmFtaWx5OiJTaGFyZSBUZWNoIE1vbm8iLG1vbm9zcGFjZTtmb250LXNpemU6LjY1cmVtO2xldHRlci1zcGFjaW5nOi4xZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2NvbG9yOnZhcigtLXRleHQzKTttYXJnaW4tYm90dG9tOi40cmVtO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOi40cmVtfQouc3RhdC12YWx1ZXtmb250LWZhbWlseToiUmFqZGhhbmkiLHNhbnMtc2VyaWY7Zm9udC1zaXplOjEuOXJlbTtmb250LXdlaWdodDo3MDA7bGluZS1oZWlnaHQ6MTtjb2xvcjp2YXIoLS10ZXh0KX0KLnN0YXQtdW5pdHtmb250LXNpemU6MXJlbTtjb2xvcjp2YXIoLS10ZXh0Mik7bWFyZ2luLWxlZnQ6LjE1cmVtfQouc3RhdC1zdWJ7Zm9udC1zaXplOi43MnJlbTtjb2xvcjp2YXIoLS10ZXh0Myk7bWFyZ2luLXRvcDouM3JlbX0KLnJpbmctd3JhcHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDouOXJlbX0KLnJpbmctc3Zne2ZsZXgtc2hyaW5rOjB9Ci5yaW5nLXRyYWNre2ZpbGw6bm9uZTtzdHJva2U6dmFyKC0tYm9yZGVyKTtzdHJva2Utd2lkdGg6Nn0KLnJpbmctZmlsbHtmaWxsOm5vbmU7c3Ryb2tlLXdpZHRoOjY7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAxcyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKX0KLnJpbmctaW5mb3tmbGV4OjF9Ci5iYXItZ2F1Z2V7aGVpZ2h0OjhweDtiYWNrZ3JvdW5kOnZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo0cHg7bWFyZ2luLXRvcDouNnJlbTtvdmVyZmxvdzpoaWRkZW59Ci5iYXItZmlsbHtoZWlnaHQ6MTAwJTtib3JkZXItcmFkaXVzOjRweDt0cmFuc2l0aW9uOndpZHRoIDFzIGN1YmljLWJlemllciguNCwwLC4yLDEpfQouY2hpcHtkaXNwbGF5OmlubGluZS1ibG9jaztiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6LjE1cmVtIC41cmVtO2ZvbnQtZmFtaWx5OiJTaGFyZSBUZWNoIE1vbm8iLG1vbm9zcGFjZTtmb250LXNpemU6LjcycmVtO2NvbG9yOnZhcigtLXRleHQyKX0KLnJlZnJlc2gtYnRue2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6LjMycmVtIC43NXJlbTtmb250LXNpemU6Ljc0cmVtO2NvbG9yOnZhcigtLXRleHQyKTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseToiS2FuaXQiLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDouM3JlbX0KLnJlZnJlc2gtYnRuOmhvdmVye2JhY2tncm91bmQ6I2YwZjRmYTtjb2xvcjp2YXIoLS10ZXh0KX0KLnJlZnJlc2gtYnRuLnNwaW4gc3Zne2FuaW1hdGlvbjpzcGluUiAuNnMgbGluZWFyIGluZmluaXRlfQpAa2V5ZnJhbWVzIHNwaW5Se3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19Ci5vbmxpbmUtYmFkZ2V7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOi4zOHJlbTtiYWNrZ3JvdW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xpZCAjODZlZmFjO2NvbG9yOiMxNTgwM2Q7cGFkZGluZzouMjZyZW0gLjc1cmVtO2JvcmRlci1yYWRpdXM6MjBweDtmb250LXNpemU6LjdyZW07Zm9udC1mYW1pbHk6IlNoYXJlIFRlY2ggTW9ubyIsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjYwMH0KLm9ubGluZS1kb3R7d2lkdGg6N3B4O2hlaWdodDo3cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1ncmVlbik7YW5pbWF0aW9uOnB1bHNlIDJzIGluZmluaXRlfQpAa2V5ZnJhbWVzIHB1bHNlezAlLDEwMCV7b3BhY2l0eToxfTUwJXtvcGFjaXR5Oi40fX0KCi8qIFNFQ1RJT04gTEFCRUwgKi8KLnNlY3Rpb24tbGFiZWx7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6LjVyZW07Zm9udC1mYW1pbHk6IlJhamRoYW5pIixzYW5zLXNlcmlmO2ZvbnQtc2l6ZTouODhyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4xNGVtO3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTtjb2xvcjp2YXIoLS10ZXh0Mik7cGFkZGluZzouMnJlbSAwIC43NXJlbX0KCi8qIENBUlJJRVIgQlVUVE9OUyAqLwouY2FyZC1ncm91cHtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpO2JvcmRlci1yYWRpdXM6MjBweDtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7b3ZlcmZsb3c6aGlkZGVuO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKX0KLmNhcmQtZ3JvdXAgLmNhcnJpZXItYnRuKy5jYXJyaWVyLWJ0bntib3JkZXItdG9wOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpfQouY2Fycmllci1idG57d2lkdGg6MTAwJTtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpO3BhZGRpbmc6MS4wNXJlbSAxLjJyZW07Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MXJlbTt0ZXh0LWFsaWduOmxlZnQ7dHJhbnNpdGlvbjpiYWNrZ3JvdW5kIC4xNXN9Ci5jYXJyaWVyLWJ0bjpob3ZlcntiYWNrZ3JvdW5kOiNmNmY5ZmZ9Ci5idG4tbG9nb3t3aWR0aDo1NHB4O2hlaWdodDo1NHB4O2JvcmRlci1yYWRpdXM6MTNweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDtvdmVyZmxvdzpoaWRkZW47Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2ZvbnQtc2l6ZToxLjZyZW19Ci5sb2dvLWFpc3tiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyLWNvbG9yOnZhcigtLWFpcy1iZHIpfQoubG9nby10cnVle2JhY2tncm91bmQ6I2M4MDQwZDtib3JkZXItY29sb3I6I2UwMDAwYX0KLmxvZ28tc3Noe2JhY2tncm91bmQ6IzE1NjVjMDtib3JkZXItY29sb3I6IzE5NzZkMn0KLmJ0bi1pbmZve2ZsZXg6MTttaW4td2lkdGg6MH0KLmJ0bi1uYW1le2ZvbnQtZmFtaWx5OiJSYWpkaGFuaSIsc2Fucy1zZXJpZjtmb250LXNpemU6MS4xMnJlbTtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjA0ZW07ZGlzcGxheTpibG9jazttYXJnaW4tYm90dG9tOi4xNXJlbX0KLmJ0bi1haXMgLmJ0bi1uYW1le2NvbG9yOnZhcigtLWFpcyl9LmJ0bi10cnVlIC5idG4tbmFtZXtjb2xvcjp2YXIoLS10cnVlKX0uYnRuLXNzaCAuYnRuLW5hbWV7Y29sb3I6dmFyKC0tc3NoKX0KLmJ0bi1kZXNje2ZvbnQtc2l6ZTouNzRyZW07Zm9udC13ZWlnaHQ6MzAwO2NvbG9yOnZhcigtLXRleHQyKTt3aGl0ZS1zcGFjZTpub3dyYXA7b3ZlcmZsb3c6aGlkZGVuO3RleHQtb3ZlcmZsb3c6ZWxsaXBzaXM7ZGlzcGxheTpibG9ja30KLmJ0bi1hcnJvd3tjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1zaXplOjEuMXJlbTtmbGV4LXNocmluazowO3RyYW5zaXRpb246dHJhbnNmb3JtIC4xOHN9Ci5jYXJyaWVyLWJ0bjpob3ZlciAuYnRuLWFycm93e3RyYW5zZm9ybTp0cmFuc2xhdGVYKDNweCl9CgovKiBTRVJWSUNFIE1PTklUT1IgKi8KLnN2Yy1ncmlke2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOi40MnJlbX0KLnN2Yy1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6LjY1cmVtO2JvcmRlci1yYWRpdXM6MTFweDtwYWRkaW5nOi41MnJlbSAuODVyZW07Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JhY2tncm91bmQ6I2Y5ZmJmYzt0cmFuc2l0aW9uOmFsbCAuMTVzfQouc3ZjLXJvdy51cHtib3JkZXItY29sb3I6Izg2ZWZhYztiYWNrZ3JvdW5kOiNmMGZkZjR9Ci5zdmMtcm93LmRvd257Ym9yZGVyLWNvbG9yOiNmY2E1YTU7YmFja2dyb3VuZDojZmVmMmYyfQouc3ZjLWRvdHt3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXItcmFkaXVzOjUwJTtmbGV4LXNocmluazowfQouc3ZjLWRvdC51cHtiYWNrZ3JvdW5kOiMyMmM1NWU7Ym94LXNoYWRvdzowIDAgNnB4IHJnYmEoMzQsMTk3LDk0LC41NSk7YW5pbWF0aW9uOnB1bHNlIDJzIGluZmluaXRlfQouc3ZjLWRvdC5kb3due2JhY2tncm91bmQ6dmFyKC0tcmVkKX0KLnN2Yy1pY29ue2ZvbnQtc2l6ZTouOXJlbTtmbGV4LXNocmluazowfQouc3ZjLW5hbWV7Zm9udC1mYW1pbHk6IlNoYXJlIFRlY2ggTW9ubyIsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouNzVyZW07Y29sb3I6dmFyKC0tdGV4dCk7ZmxleDoxO2ZvbnQtd2VpZ2h0OjYwMH0KLnN2Yy1wb3J0c3tmb250LWZhbWlseToiU2hhcmUgVGVjaCBNb25vIixtb25vc3BhY2U7Zm9udC1zaXplOi42M3JlbTtjb2xvcjp2YXIoLS10ZXh0Myl9Ci5zdmMtY2hpcHtmb250LWZhbWlseToiU2hhcmUgVGVjaCBNb25vIixtb25vc3BhY2U7Zm9udC1zaXplOi42M3JlbTtwYWRkaW5nOi4xM3JlbSAuNXJlbTtib3JkZXItcmFkaXVzOjIwcHg7ZmxleC1zaHJpbms6MDtmb250LXdlaWdodDo3MDB9Ci5zdmMtY2hpcC51cHtiYWNrZ3JvdW5kOiNkY2ZjZTc7Y29sb3I6IzE2NjUzNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWN9Ci5zdmMtY2hpcC5kb3due2JhY2tncm91bmQ6I2ZlZTJlMjtjb2xvcjojOTkxYjFiO2JvcmRlcjoxcHggc29saWQgI2ZjYTVhNX0KLnN2Yy1jaGlwLmNoZWNraW5ne2JhY2tncm91bmQ6I2YxZjVmOTtjb2xvcjp2YXIoLS10ZXh0Myk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpfQoKLyogTU9EQUwgKi8KLm1vZGFsLW92ZXJsYXl7ZGlzcGxheTpub25lO3Bvc2l0aW9uOmZpeGVkO2luc2V0OjA7ei1pbmRleDoxMDAwO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNCk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNHB4KTthbGlnbi1pdGVtczpmbGV4LWVuZDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyfQoubW9kYWwtb3ZlcmxheS5vcGVue2Rpc3BsYXk6ZmxleH0KLm1vZGFse3dpZHRoOjEwMCU7bWF4LXdpZHRoOjUyMHB4O2JhY2tncm91bmQ6dmFyKC0tc3VyZmFjZSk7Ym9yZGVyLXJhZGl1czoyNnB4IDI2cHggMCAwO292ZXJmbG93OmhpZGRlbjtwb3NpdGlvbjpyZWxhdGl2ZTthbmltYXRpb246c2xpZGVVcCAuMjZzIGN1YmljLWJlemllciguMzQsMS4xLC42NCwxKTttYXgtaGVpZ2h0Ojk0dmg7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbn0KQGtleWZyYW1lcyBzbGlkZVVwe2Zyb217dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMTAwJSk7b3BhY2l0eTouNX10b3t0cmFuc2Zvcm06dHJhbnNsYXRlWSgwKTtvcGFjaXR5OjF9fQoubW9kYWw6OmJlZm9yZXtjb250ZW50OiIiO2Rpc3BsYXk6YmxvY2s7d2lkdGg6NDJweDtoZWlnaHQ6NHB4O2JvcmRlci1yYWRpdXM6MnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMTIpO21hcmdpbjoxMXB4IGF1dG8gMDtmbGV4LXNocmluazowfQoubW9kYWwtaGVhZGVye3BhZGRpbmc6Ljg1cmVtIDEuNHJlbSAuOTVyZW07ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2ZsZXgtc2hyaW5rOjB9Ci5tb2RhbC10aXRsZXtmb250LWZhbWlseToiUmFqZGhhbmkiLHNhbnMtc2VyaWY7Zm9udC1zaXplOjEuMDVyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4wOGVtO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOi42cmVtfQoubW9kYWwtYWlzIC5tb2RhbC10aXRsZXtjb2xvcjp2YXIoLS1haXMyKX0ubW9kYWwtdHJ1ZSAubW9kYWwtdGl0bGV7Y29sb3I6dmFyKC0tdHJ1ZTIpfS5tb2RhbC1zc2ggLm1vZGFsLXRpdGxle2NvbG9yOnZhcigtLXNzaDIpfQoubW9kYWwtY2xvc2V7d2lkdGg6MzBweDtoZWlnaHQ6MzBweDtib3JkZXItcmFkaXVzOjUwJTtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOiNmMGY0Zjg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZTouODVyZW07Y29sb3I6dmFyKC0tdGV4dDIpO3RyYW5zaXRpb246YWxsIC4yc30KLm1vZGFsLWNsb3NlOmhvdmVye2JhY2tncm91bmQ6I2UyZThmMH0KLm1vZGFsLWJvZHl7cGFkZGluZzoxLjFyZW0gMS40cmVtIDEuOHJlbTtvdmVyZmxvdy15OmF1dG87ZmxleDoxfQoKLyogRk9STSAqLwouc25pLWJhZGdle2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDouNHJlbTtmb250LWZhbWlseToiU2hhcmUgVGVjaCBNb25vIixtb25vc3BhY2U7Zm9udC1zaXplOi42OHJlbTtwYWRkaW5nOi4yNXJlbSAuNzVyZW07Ym9yZGVyLXJhZGl1czoyMHB4O21hcmdpbi1ib3R0b206Ljk1cmVtfQouc25pLWJhZGdlLmFpc3tiYWNrZ3JvdW5kOiNlZGY3ZTM7Ym9yZGVyOjFweCBzb2xpZCAjYjVlMDhhO2NvbG9yOiMzMTY4MDh9Ci5zbmktYmFkZ2UudHJ1ZXtiYWNrZ3JvdW5kOiNmZmYwZjA7Ym9yZGVyOjFweCBzb2xpZCAjZjU5MDlhO2NvbG9yOiNhNjAwMGN9Ci5zbmktYmFkZ2Uuc3Noe2JhY2tncm91bmQ6I2U2ZjNmYztib3JkZXI6MXB4IHNvbGlkICM4MmMwZWU7Y29sb3I6IzBjNGY4NH0KLmZncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6LjZyZW0gLjhyZW19Ci5mZ3JpZCAuc3BhbjJ7Z3JpZC1jb2x1bW46c3BhbiAyfQouZmllbGR7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6LjNyZW19CmxhYmVse2ZvbnQtc2l6ZTouNjdyZW07Zm9udC1mYW1pbHk6IlNoYXJlIFRlY2ggTW9ubyIsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOi4xZW07dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO2NvbG9yOnZhcigtLXRleHQzKX0KaW5wdXQsc2VsZWN0e2JhY2tncm91bmQ6I2Y2ZjlmYztib3JkZXI6MS41cHggc29saWQgI2Q4ZTJlZTtib3JkZXItcmFkaXVzOjExcHg7cGFkZGluZzouNnJlbSAuOXJlbTtjb2xvcjp2YXIoLS10ZXh0KTtmb250LWZhbWlseToiS2FuaXQiLHNhbnMtc2VyaWY7Zm9udC1zaXplOi44OHJlbTtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzLGJveC1zaGFkb3cgLjJzO3dpZHRoOjEwMCV9CmlucHV0OmZvY3VzLHNlbGVjdDpmb2N1c3tiYWNrZ3JvdW5kOiNmZmZ9CmlucHV0LmFpcy1mb2N1czpmb2N1c3tib3JkZXItY29sb3I6IzRkOWEwZTtib3gtc2hhZG93OjAgMCAwIDNweCByZ2JhKDc3LDE1NCwxNCwuMSl9CmlucHV0LnRydWUtZm9jdXM6Zm9jdXN7Ym9yZGVyLWNvbG9yOiNkODBlMWM7Ym94LXNoYWRvdzowIDAgMCAzcHggcmdiYSgyMTYsMTQsMjgsLjA5KX0KaW5wdXQuc3NoLWZvY3VzOmZvY3Vze2JvcmRlci1jb2xvcjojMTU2OGE2O2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMjEsMTA0LDE2NiwuMSl9Ci5kaXZpZGVye2hlaWdodDoxcHg7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpO21hcmdpbjouOHJlbSAwfQouc3VibWl0LWJ0bnt3aWR0aDoxMDAlO3BhZGRpbmc6Ljg4cmVtO2JvcmRlcjpub25lO2JvcmRlci1yYWRpdXM6MTNweDtmb250LWZhbWlseToiUmFqZGhhbmkiLHNhbnMtc2VyaWY7Zm9udC1zaXplOjEuMDVyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOi4xZW07Y3Vyc29yOnBvaW50ZXI7bWFyZ2luLXRvcDouOXJlbTt0cmFuc2l0aW9uOmFsbCAuMnN9Ci5zdWJtaXQtYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkfQouc3VibWl0LWJ0bi5haXMtYnRue2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjM2Q3YTBlLCM1YWFhMTgpO2NvbG9yOiNmZmY7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoNzcsMTU0LDE0LC4zMil9Ci5zdWJtaXQtYnRuLmFpcy1idG46aG92ZXI6bm90KDpkaXNhYmxlZCl7Ym94LXNoYWRvdzowIDZweCAyNHB4IHJnYmEoNzcsMTU0LDE0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCl9Ci5zdWJtaXQtYnRuLnRydWUtYnRue2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjYTYwMDBjLCNkODEwMjApO2NvbG9yOiNmZmY7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoMjE2LDE0LDI4LC4yOCl9Ci5zdWJtaXQtYnRuLnRydWUtYnRuOmhvdmVyOm5vdCg6ZGlzYWJsZWQpe2JveC1zaGFkb3c6MCA2cHggMjRweCByZ2JhKDIxNiwxNCwyOCwuNCk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCl9Ci5zdWJtaXQtYnRuLnNzaC1idG57YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMwYzRmODQsIzE2NjhhOCk7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgyMSwxMDQsMTY2LC4yOCl9Ci5zdWJtaXQtYnRuLnNzaC1idG46aG92ZXI6bm90KDpkaXNhYmxlZCl7Ym94LXNoYWRvdzowIDZweCAyNHB4IHJnYmEoMjEsMTA0LDE2NiwuNCk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCl9Ci5zdWJtaXQtYnRuLmRhbmdlci1idG57YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCM5OTFiMWIsI2RjMjYyNik7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgyMjAsMzgsMzgsLjIyKX0KLnNwaW5uZXJ7ZGlzcGxheTppbmxpbmUtYmxvY2s7d2lkdGg6MTRweDtoZWlnaHQ6MTRweDtib3JkZXI6MnB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjMpO2JvcmRlci10b3AtY29sb3I6I2ZmZjtib3JkZXItcmFkaXVzOjUwJTthbmltYXRpb246c3BpbiAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6LjRyZW19CkBrZXlmcmFtZXMgc3Bpbnt0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9fQouYWxlcnR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6LjdyZW07cGFkZGluZzouNjhyZW0gLjlyZW07Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZTouOHJlbTtsaW5lLWhlaWdodDoxLjZ9Ci5hbGVydC5va3tiYWNrZ3JvdW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xpZCAjODZlZmFjO2NvbG9yOiMxNjY1MzR9Ci5hbGVydC5lcnJ7YmFja2dyb3VuZDojZmVmMmYyO2JvcmRlcjoxcHggc29saWQgI2ZjYTVhNTtjb2xvcjojOTkxYjFifQouYWxlcnQuaW5mb3tiYWNrZ3JvdW5kOiNlZmY2ZmY7Ym9yZGVyOjFweCBzb2xpZCAjOTNjNWZkO2NvbG9yOiMxZTQwYWZ9CgovKiBSRVNVTFQgQ0FSRCAqLwoucmVzdWx0LWNhcmR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MS4xcmVtO2JvcmRlci1yYWRpdXM6MTZweDtvdmVyZmxvdzpoaWRkZW47Ym9yZGVyOjEuNXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoMCwwLDAsLjA3KX0KLnJlc3VsdC1jYXJkLnNob3d7ZGlzcGxheTpibG9ja30KI2Fpcy1yZXN1bHQuc2hvd3tib3JkZXItY29sb3I6dmFyKC0tYWlzLWJkcil9CiN0cnVlLXJlc3VsdC5zaG93e2JvcmRlci1jb2xvcjp2YXIoLS10cnVlLWJkcil9CiNzc2gtcmVzdWx0LnNob3d7Ym9yZGVyLWNvbG9yOnZhcigtLXNzaC1iZHIpfQoucmVzdWx0LWhlYWRlcntwYWRkaW5nOi42NXJlbSAxcmVtO2ZvbnQtZmFtaWx5OiJTaGFyZSBUZWNoIE1vbm8iLG1vbm9zcGFjZTtmb250LXNpemU6LjcycmVtO2xldHRlci1zcGFjaW5nOi4xZW07ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6LjVyZW07Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKX0KLnJlc3VsdC1oZWFkZXIgLmRvdHt3aWR0aDo3cHg7aGVpZ2h0OjdweDtib3JkZXItcmFkaXVzOjUwJTtmbGV4LXNocmluazowfQoucmVzdWx0LWhlYWRlci5haXMtcntiYWNrZ3JvdW5kOnZhcigtLWFpcy1saWdodCk7Y29sb3I6dmFyKC0tYWlzMil9LnJlc3VsdC1oZWFkZXIuYWlzLXIgLmRvdHtiYWNrZ3JvdW5kOnZhcigtLWFpcyl9Ci5yZXN1bHQtaGVhZGVyLnRydWUtcntiYWNrZ3JvdW5kOnZhcigtLXRydWUtbGlnaHQpO2NvbG9yOnZhcigtLXRydWUyKX0ucmVzdWx0LWhlYWRlci50cnVlLXIgLmRvdHtiYWNrZ3JvdW5kOnZhcigtLXRydWUpfQoucmVzdWx0LWhlYWRlci5zc2gtcntiYWNrZ3JvdW5kOnZhcigtLXNzaC1saWdodCk7Y29sb3I6dmFyKC0tc3NoMil9LnJlc3VsdC1oZWFkZXIuc3NoLXIgLmRvdHtiYWNrZ3JvdW5kOnZhcigtLXNzaCl9Ci5yZXN1bHQtYm9keXtwYWRkaW5nOi44NXJlbSAxcmVtO2JhY2tncm91bmQ6I2ZhZmNmZX0KLmluZm8tcm93c3ttYXJnaW4tYm90dG9tOi44cmVtfQouaW5mby1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtwYWRkaW5nOi4zMnJlbSAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Zm9udC1zaXplOi44cmVtfQouaW5mby1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmV9Ci5pbmZvLWtleXtjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1zaXplOi43cmVtO2ZvbnQtZmFtaWx5OiJTaGFyZSBUZWNoIE1vbm8iLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzouMDhlbX0KLmluZm8tdmFse2NvbG9yOnZhcigtLXRleHQpO3RleHQtYWxpZ246cmlnaHQ7d29yZC1icmVhazpicmVhay1hbGw7bWF4LXdpZHRoOjYyJX0KLmluZm8tdmFsLnBhc3N7Zm9udC1mYW1pbHk6IlNoYXJlIFRlY2ggTW9ubyIsbW9ub3NwYWNlO2NvbG9yOnZhcigtLWdyZWVuKTtmb250LXdlaWdodDo2MDB9Ci5saW5rLWJveHtiYWNrZ3JvdW5kOiNmMGY1ZmI7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6LjdyZW0gLjlyZW07Zm9udC1mYW1pbHk6IlNoYXJlIFRlY2ggTW9ubyIsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouNjJyZW07d29yZC1icmVhazpicmVhay1hbGw7bGluZS1oZWlnaHQ6MS43NTttYXJnaW4tYm90dG9tOi43NXJlbTtib3JkZXI6MXB4IHNvbGlkICNkZGUzZWM7Y29sb3I6dmFyKC0tdGV4dDIpfQoubGluay1ib3gudmxlc3MtbGlua3tib3JkZXItbGVmdDozcHggc29saWQgIzRkOWEwZTtjb2xvcjojMzE2ODA4fQoubGluay1ib3gubnB2LWxpbmt7Ym9yZGVyLWxlZnQ6M3B4IHNvbGlkICMxNTY4YTY7Y29sb3I6IzBjNGY4NH0KLnFyLXdyYXB7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpjZW50ZXI7bWFyZ2luOi42cmVtIDAgLjhyZW19Ci5xci1pbm5lcntiYWNrZ3JvdW5kOiNmZmY7cGFkZGluZzoxMHB4O2JvcmRlci1yYWRpdXM6MTBweDtkaXNwbGF5OmlubGluZS1ibG9jaztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcil9Ci5jb3B5LXJvd3tkaXNwbGF5OmZsZXg7Z2FwOi41cmVtO2ZsZXgtd3JhcDp3cmFwfQouY29weS1idG57ZmxleDoxO21pbi13aWR0aDoxMTBweDtwYWRkaW5nOi41MnJlbSAuN3JlbTtib3JkZXItcmFkaXVzOjEwcHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZmZmO2ZvbnQtZmFtaWx5OiJSYWpkaGFuaSIsc2Fucy1zZXJpZjtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzouMDZlbTtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMThzO2NvbG9yOnZhcigtLXRleHQyKX0KLmNvcHktYnRuLnZsZXNze2JvcmRlci1jb2xvcjojYjVlMDhhO2NvbG9yOiMzMTY4MDh9LmNvcHktYnRuLnZsZXNzOmhvdmVye2JhY2tncm91bmQ6I2VkZjdlM30KLmNvcHktYnRuLm5wdntib3JkZXItY29sb3I6IzgyYzBlZTtjb2xvcjojMGM0Zjg0fS5jb3B5LWJ0bi5ucHY6aG92ZXJ7YmFja2dyb3VuZDojZTZmM2ZjfQouY29weS1idG4uY29waWVke29wYWNpdHk6LjY7cG9pbnRlci1ldmVudHM6bm9uZX0KCi8qIFVTRVIgTElTVCAqLwoubWdtdC1wYW5lbHtiYWNrZ3JvdW5kOnZhcigtLXN1cmZhY2UpO2JvcmRlci1yYWRpdXM6MjBweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO292ZXJmbG93OmhpZGRlbn0KLm1nbXQtaGVhZGVye3BhZGRpbmc6LjlyZW0gMS4ycmVtO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6LjhyZW19Ci5tZ210LXRpdGxle2ZvbnQtZmFtaWx5OiJSYWpkaGFuaSIsc2Fucy1zZXJpZjtmb250LXNpemU6MXJlbTtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6LjA2ZW07Y29sb3I6dmFyKC0tdGV4dCk7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6LjVyZW19Ci5zZWFyY2gtYmFye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOi41cmVtO3BhZGRpbmc6LjhyZW0gMS4ycmVtO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcil9Ci5zZWFyY2gtYmFyIGlucHV0e2ZsZXg6MTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjEuNXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6LjVyZW0gLjg1cmVtO2ZvbnQtZmFtaWx5OiJLYW5pdCIsc2Fucy1zZXJpZjtmb250LXNpemU6Ljg4cmVtO291dGxpbmU6bm9uZTtjb2xvcjp2YXIoLS10ZXh0KX0KLnNlYXJjaC1iYXIgaW5wdXQ6Zm9jdXN7Ym9yZGVyLWNvbG9yOnZhcigtLXNzaCk7YmFja2dyb3VuZDojZmZmfQoudXNlci1saXN0e21heC1oZWlnaHQ6NDAwcHg7b3ZlcmZsb3cteTphdXRvfQoudXNlci1saXN0Ojotd2Via2l0LXNjcm9sbGJhcnt3aWR0aDo0cHh9Ci51c2VyLWxpc3Q6Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1ie2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMSk7Ym9yZGVyLXJhZGl1czoycHh9Ci51c2VyLXJvd3twYWRkaW5nOi43NXJlbSAxLjJyZW07Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDouOHJlbTt0cmFuc2l0aW9uOmJhY2tncm91bmQgLjE1cztjdXJzb3I6cG9pbnRlcn0KLnVzZXItcm93Omxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRvbTpub25lfQoudXNlci1yb3c6aG92ZXJ7YmFja2dyb3VuZDojZjhmYWZjfQoudXNlci1hdmF0YXJ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtZmFtaWx5OiJSYWpkaGFuaSIsc2Fucy1zZXJpZjtmb250LXdlaWdodDo3MDA7Zm9udC1zaXplOi45cmVtO2ZsZXgtc2hyaW5rOjB9Ci51YS1haXN7YmFja2dyb3VuZDp2YXIoLS1haXMtbGlnaHQpO2NvbG9yOnZhcigtLWFpczIpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYWlzLWJkcil9Ci51YS10cnVle2JhY2tncm91bmQ6dmFyKC0tdHJ1ZS1saWdodCk7Y29sb3I6dmFyKC0tdHJ1ZTIpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tdHJ1ZS1iZHIpfQoudXNlci1pbmZve2ZsZXg6MTttaW4td2lkdGg6MH0KLnVzZXItbmFtZXtmb250LXdlaWdodDo2MDA7Zm9udC1zaXplOi44OHJlbTtjb2xvcjp2YXIoLS10ZXh0KTttYXJnaW4tYm90dG9tOi4xcmVtfQoudXNlci1tZXRhe2ZvbnQtc2l6ZTouNzJyZW07Y29sb3I6dmFyKC0tdGV4dDMpO2ZvbnQtZmFtaWx5OiJTaGFyZSBUZWNoIE1vbm8iLG1vbm9zcGFjZX0KLnN0YXR1cy1iYWRnZXtmb250LXNpemU6LjY4cmVtO3BhZGRpbmc6LjJyZW0gLjU1cmVtO2JvcmRlci1yYWRpdXM6MjBweDtmb250LWZhbWlseToiU2hhcmUgVGVjaCBNb25vIixtb25vc3BhY2U7ZmxleC1zaHJpbms6MH0KLnN0YXR1cy1va3tiYWNrZ3JvdW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xpZCAjODZlZmFjO2NvbG9yOiMxNjY1MzR9Ci5zdGF0dXMtZXhwe2JhY2tncm91bmQ6I2ZmZjdlZDtib3JkZXI6MXB4IHNvbGlkICNmZWQ3YWE7Y29sb3I6IzkyNDAwZX0KLnN0YXR1cy1kZWFke2JhY2tncm91bmQ6I2ZlZjJmMjtib3JkZXI6MXB4IHNvbGlkICNmY2E1YTU7Y29sb3I6Izk5MWIxYn0KLmVtcHR5LXN0YXRle3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MnJlbSAxcmVtO2NvbG9yOnZhcigtLXRleHQzKTtmb250LXNpemU6Ljg1cmVtfQouZW1wdHktc3RhdGUgLmVpe2ZvbnQtc2l6ZToycmVtO21hcmdpbi1ib3R0b206LjVyZW19Ci5sb2FkaW5nLXJvd3t0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjEuNXJlbTtjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1zaXplOi44MnJlbTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Z2FwOi41cmVtfQoKLyogVE9BU1QgKi8KLnRvYXN0e3Bvc2l0aW9uOmZpeGVkO2JvdHRvbTozMHB4O2xlZnQ6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVYKC01MCUpIHNjYWxlKC45NSk7YmFja2dyb3VuZDojMWEyMzMyO2NvbG9yOiNmZmY7cGFkZGluZzouNjVyZW0gMS42cmVtO2JvcmRlci1yYWRpdXM6MjZweDtmb250LWZhbWlseToiUmFqZGhhbmkiLHNhbnMtc2VyaWY7Zm9udC13ZWlnaHQ6NzAwO2ZvbnQtc2l6ZTouOXJlbTtvcGFjaXR5OjA7cG9pbnRlci1ldmVudHM6bm9uZTt6LWluZGV4Ojk5OTk7dHJhbnNpdGlvbjpvcGFjaXR5IC4yNXMsdHJhbnNmb3JtIC4yNXM7d2hpdGUtc3BhY2U6bm93cmFwO2JveC1zaGFkb3c6MCA4cHggMjRweCByZ2JhKDAsMCwwLC4yMil9Ci50b2FzdC5zaG93e29wYWNpdHk6MTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKSBzY2FsZSgxKX0KCkBtZWRpYShtYXgtd2lkdGg6NjAwcHgpey5mZ3JpZHtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyfS5mZ3JpZCAuc3BhbjJ7Z3JpZC1jb2x1bW46c3BhbiAxfX0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KCjxkaXYgY2xhc3M9InNpdGUtaGVhZGVyIj4KICA8Y2FudmFzIGlkPSJzbm93LWNhbnZhcyI+PC9jYW52YXM+CiAgPGRpdiBjbGFzcz0ic2l0ZS1sb2dvIj5DSEFJWUEgVjJSQVkgUFJPIE1BWDwvZGl2PgogIDxkaXYgY2xhc3M9InNpdGUtdGl0bGUiPlVTRVIgPHNwYW4+Q1JFQVRPUjwvc3Bhbj48L2Rpdj4KICA8ZGl2IGNsYXNzPSJzaXRlLXN1YiI+4Liq4Lij4LmJ4Liy4LiH4Lia4Lix4LiN4LiK4Li1IFZMRVNTIDxzcGFuIGNsYXNzPSJkb3QiPsK3PC9zcGFuPiBTU0gtV1Mg4Lic4LmI4Liy4LiZ4Lir4LiZ4LmJ4Liy4LmA4Lin4LmH4LiaIDxzcGFuIGNsYXNzPSJkb3QiPsK3PC9zcGFuPiB2NTwvZGl2PgogIDxidXR0b24gY2xhc3M9ImxvZ291dC1idG4iIG9uY2xpY2s9ImRvTG9nb3V0KCkiPuKOiyDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KPC9kaXY+Cgo8bmF2IGNsYXNzPSJ0YWItbmF2Ij4KICA8YnV0dG9uIGNsYXNzPSJ0YWItYnRuIGFjdGl2ZSIgaWQ9InRhYi1idG4tZGFzaCIgICAgb25jbGljaz0ic3dpdGNoVGFiKCdkYXNoJyx0aGlzKSI+8J+TiiDguYHguJTguIrguJrguK3guKPguYzguJQ8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPSJ0YWItYnRuIiAgICAgICAgaWQ9InRhYi1idG4tY3JlYXRlIiAgb25jbGljaz0ic3dpdGNoVGFiKCdjcmVhdGUnLHRoaXMpIj7inpUg4Liq4Lij4LmJ4Liy4LiH4Lii4Li54LiqPC9idXR0b24+CiAgPGJ1dHRvbiBjbGFzcz0idGFiLWJ0biIgICAgICAgIGlkPSJ0YWItYnRuLW1hbmFnZSIgIG9uY2xpY2s9InN3aXRjaFRhYignbWFuYWdlJyx0aGlzKSI+8J+UpyDguIjguLHguJTguIHguLLguKPguKLguLnguKo8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPSJ0YWItYnRuIiAgICAgICAgaWQ9InRhYi1idG4tb25saW5lIiAgb25jbGljaz0ic3dpdGNoVGFiKCdvbmxpbmUnLHRoaXMpIj7wn5+iIOC4reC4reC4meC5hOC4peC4meC5jDwvYnV0dG9uPgo8L25hdj4KCjwhLS0g4pSA4pSAIFRBQjogREFTSEJPQVJEIOKUgOKUgCAtLT4KPGRpdiBjbGFzcz0idGFiLXBhbmVsIGFjdGl2ZSIgaWQ9InRhYi1kYXNoIj4KPGRpdiBjbGFzcz0ibWFpbiI+CiAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbiI+CiAgICA8c3BhbiBzdHlsZT0iZm9udC1mYW1pbHk6J1JhamRoYW5pJyxzYW5zLXNlcmlmO2ZvbnQtd2VpZ2h0OjcwMDtmb250LXNpemU6LjlyZW07Y29sb3I6dmFyKC0tdGV4dDIpO2xldHRlci1zcGFjaW5nOi4xZW0iPlNZU1RFTSBNT05JVE9SPC9zcGFuPgogICAgPGJ1dHRvbiBjbGFzcz0icmVmcmVzaC1idG4iIGlkPSJyZWZyZXNoLWJ0biIgb25jbGljaz0ibG9hZFN0YXRzKCkiPgogICAgICA8c3ZnIHdpZHRoPSIxMyIgaGVpZ2h0PSIxMyIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjUiPjxwYXRoIGQ9Ik0yMyA0djZoLTYiLz48cGF0aCBkPSJNMSAyMHYtNmg2Ii8+PHBhdGggZD0iTTMuNTEgOWE5IDkgMCAwIDEgMTQuODUtMy4zNkwyMyAxME0xIDE0bDQuNjQgNC4zNkE5IDkgMCAwIDAgMjAuNDkgMTUiLz48L3N2Zz4KICAgICAg4Lij4Li14LmA4Lif4Lij4LiKCiAgICA8L2J1dHRvbj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0ic3RhdHMtZ3JpZCI+CiAgICA8ZGl2IGNsYXNzPSJzdGF0LWNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LWxhYmVsIj7imqEgQ1BVIFVzYWdlPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InJpbmctd3JhcCI+CiAgICAgICAgPHN2ZyBjbGFzcz0icmluZy1zdmciIHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIgdmlld0JveD0iMCAwIDY0IDY0Ij4KICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InJpbmctdHJhY2siIGN4PSIzMiIgY3k9IjMyIiByPSIyNiIvPgogICAgICAgICAgPGNpcmNsZSBjbGFzcz0icmluZy1maWxsIiBpZD0iY3B1LXJpbmciIGN4PSIzMiIgY3k9IjMyIiByPSIyNiIgc3Ryb2tlPSIjNWE5ZTFjIiBzdHJva2UtZGFzaGFycmF5PSIxNjMuNCIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjE2My40IiB0cmFuc2Zvcm09InJvdGF0ZSgtOTAgMzIgMzIpIi8+CiAgICAgICAgPC9zdmc+CiAgICAgICAgPGRpdiBjbGFzcz0icmluZy1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0YXQtdmFsdWUiIGlkPSJjcHUtdmFsIj4tLTxzcGFuIGNsYXNzPSJzdGF0LXVuaXQiPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0LXN1YiIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJhci1nYXVnZSI+PGRpdiBjbGFzcz0iYmFyLWZpbGwiIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzVhOWUxYywjOGRjNjNmKSI+PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InN0YXQtY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InN0YXQtbGFiZWwiPvCfp6AgUkFNIFVzYWdlPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InJpbmctd3JhcCI+CiAgICAgICAgPHN2ZyBjbGFzcz0icmluZy1zdmciIHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIgdmlld0JveD0iMCAwIDY0IDY0Ij4KICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InJpbmctdHJhY2siIGN4PSIzMiIgY3k9IjMyIiByPSIyNiIvPgogICAgICAgICAgPGNpcmNsZSBjbGFzcz0icmluZy1maWxsIiBpZD0icmFtLXJpbmciIGN4PSIzMiIgY3k9IjMyIiByPSIyNiIgc3Ryb2tlPSIjMWE2ZmE4IiBzdHJva2UtZGFzaGFycmF5PSIxNjMuNCIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjE2My40IiB0cmFuc2Zvcm09InJvdGF0ZSgtOTAgMzIgMzIpIi8+CiAgICAgICAgPC9zdmc+CiAgICAgICAgPGRpdiBjbGFzcz0icmluZy1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0YXQtdmFsdWUiIGlkPSJyYW0tdmFsIj4tLTxzcGFuIGNsYXNzPSJzdGF0LXVuaXQiPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0LXN1YiIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJhci1nYXVnZSI+PGRpdiBjbGFzcz0iYmFyLWZpbGwiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzFhNmZhOCwjNDBiMGZmKSI+PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InN0YXQtY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InN0YXQtbGFiZWwiPvCfkr4gRGlzayBVc2FnZTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LXZhbHVlIiBpZD0iZGlzay12YWwiPi0tPHNwYW4gY2xhc3M9InN0YXQtdW5pdCI+JTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3RhdC1zdWIiIGlkPSJkaXNrLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJiYXItZ2F1Z2UiPjxkaXYgY2xhc3M9ImJhci1maWxsIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZjk3MzE2LCNmYjkyM2MpIj48L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ic3RhdC1jYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic3RhdC1sYWJlbCI+4o+xIFVwdGltZTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LXZhbHVlIiBpZD0idXB0aW1lLXZhbCIgc3R5bGU9ImZvbnQtc2l6ZToxLjRyZW0iPi0tPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN0YXQtc3ViIiBpZD0idXB0aW1lLXN1YiI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9Im1hcmdpbi10b3A6LjRyZW0iIGlkPSJsb2FkLWF2Zy1jaGlwcyI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InN0YXQtY2FyZCB3aWRlIj4KICAgICAgPGRpdiBjbGFzcz0ic3RhdC1sYWJlbCI+8J+MkCBOZXR3b3JrIEkvTzwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOi41cmVtIj4KICAgICAgICA8ZGl2PgogICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOi42OHJlbTtjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIj7ihpEgVXBsb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0LXZhbHVlIiBpZD0ibmV0LXVwIiBzdHlsZT0iZm9udC1zaXplOjEuNHJlbSI+LS08L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0YXQtc3ViIiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2PgogICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOi42OHJlbTtjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIj7ihpMgRG93bmxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0YXQtdmFsdWUiIGlkPSJuZXQtZG93biIgc3R5bGU9ImZvbnQtc2l6ZToxLjRyZW0iPi0tPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0LXN1YiIgaWQ9Im5ldC1kb3duLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InN0YXQtY2FyZCB3aWRlIj4KICAgICAgPGRpdiBjbGFzcz0ic3RhdC1sYWJlbCI+8J+bsCBYLVVJIFBhbmVsIFN0YXR1czwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDouOHJlbTtmbGV4LXdyYXA6d3JhcCI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXN0YXR1cy1iYWRnZSI+PHNwYW4gY2xhc3M9InN0YXR1cy1iYWRnZSBzdGF0dXMtZGVhZCI+4LiB4Liz4Lil4Lix4LiH4LiV4Lij4Lin4LiI4Liq4Lit4LiaLi4uPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXY+CiAgICAgICAgICA8ZGl2IGlkPSJ4dWktdmVyIiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtjb2xvcjp2YXIoLS10ZXh0Mik7Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIj7guYDguKfguK3guKPguYzguIrguLHguJk6IC0tPC9kaXY+CiAgICAgICAgICA8ZGl2IGlkPSJ4dWktdHJhZmZpYyIgc3R5bGU9ImZvbnQtc2l6ZTouN3JlbTtjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIj5UcmFmZmljIGluYm91bmRzOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8ZGl2PgogICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOi42cmVtIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjdGlvbi1sYWJlbCIgc3R5bGU9InBhZGRpbmc6MCI+8J+boCBTZXJ2aWNlIE1vbml0b3I8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0icmVmcmVzaC1idG4iIG9uY2xpY2s9ImxvYWRTZXJ2aWNlU3RhdHVzKCkiPgogICAgICAgIDxzdmcgd2lkdGg9IjEyIiBoZWlnaHQ9IjEyIiB2aWV3Qm94PSIwIDAgMjQgMjQiIGZpbGw9Im5vbmUiIHN0cm9rZT0iY3VycmVudENvbG9yIiBzdHJva2Utd2lkdGg9IjIuNSI+PHBhdGggZD0iTTIzIDR2NmgtNiIvPjxwYXRoIGQ9Ik0xIDIwdi02aDYiLz48cGF0aCBkPSJNMy41MSA5YTkgOSAwIDAgMSAxNC44NS0zLjM2TDIzIDEwTTEgMTRsNC42NCA0LjM2QTkgOSAwIDAgMCAyMC40OSAxNSIvPjwvc3ZnPgogICAgICAgIOC5gOC4iuC5h+C4hOC4quC4luC4suC4meC4sAogICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ic3ZjLWdyaWQiIGlkPSJzdmMtZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImxvYWRpbmctcm93Ij48c3BhbiBzdHlsZT0iZm9udC1zaXplOi44cmVtO2NvbG9yOnZhcigtLXRleHQzKSI+4LiB4Liz4Lil4Lix4LiH4LiV4Lij4Lin4LiI4Liq4Lit4LiaLi4uPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZTouN3JlbTtjb2xvcjp2YXIoLS10ZXh0Myk7Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KPC9kaXY+CjwvZGl2PgoKPCEtLSDilIDilIAgVEFCOiBDUkVBVEUgVVNFUiDilIDilIAgLS0+CjxkaXYgY2xhc3M9InRhYi1wYW5lbCIgaWQ9InRhYi1jcmVhdGUiPgo8ZGl2IGNsYXNzPSJtYWluIj4KICA8ZGl2IGNsYXNzPSJzZWN0aW9uLWxhYmVsIj7wn5OhIOC5gOC4peC4t+C4reC4gSBQcm90b2NvbDwvZGl2PgogIDxkaXYgY2xhc3M9ImNhcmQtZ3JvdXAiPgogICAgPGJ1dHRvbiBjbGFzcz0iY2Fycmllci1idG4gYnRuLWFpcyIgb25jbGljaz0ib3Blbk1vZGFsKCdhaXMnKSI+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1sb2dvIGxvZ28tYWlzIj7wn5+iPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1pbmZvIj4KICAgICAgICA8c3BhbiBjbGFzcz0iYnRuLW5hbWUiPkFJUyAvIFZMRVNTLVdTPC9zcGFuPgogICAgICAgIDxzcGFuIGNsYXNzPSJidG4tZGVzYyI+UG9ydCA4MDgwIMK3IFNOSTogY2otZWJiLnNwZWVkdGVzdC5uZXQ8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0iYnRuLWFycm93Ij7igLo8L3NwYW4+CiAgICA8L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9ImNhcnJpZXItYnRuIGJ0bi10cnVlIiBvbmNsaWNrPSJvcGVuTW9kYWwoJ3RydWUnKSI+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1sb2dvIGxvZ28tdHJ1ZSI+8J+UtDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJidG4taW5mbyI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImJ0bi1uYW1lIj5UUlVFIC8gVkxFU1MtV1M8L3NwYW4+CiAgICAgICAgPHNwYW4gY2xhc3M9ImJ0bi1kZXNjIj5Qb3J0IDg4ODAgwrcgU05JOiB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9ImJ0bi1hcnJvdyI+4oC6PC9zcGFuPgogICAgPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJjYXJyaWVyLWJ0biBidG4tc3NoIiBvbmNsaWNrPSJvcGVuTW9kYWwoJ3NzaCcpIj4KICAgICAgPGRpdiBjbGFzcz0iYnRuLWxvZ28gbG9nby1zc2giPvCflLU8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYnRuLWluZm8iPgogICAgICAgIDxzcGFuIGNsYXNzPSJidG4tbmFtZSI+U1NILVdTPC9zcGFuPgogICAgICAgIDxzcGFuIGNsYXNzPSJidG4tZGVzYyI+UG9ydCA4MCDCtyBEcm9wYmVhcjoxNDMgwrcgSFRUUC1XUyBUdW5uZWw8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0iYnRuLWFycm93Ij7igLo8L3NwYW4+CiAgICA8L2J1dHRvbj4KICA8L2Rpdj4KPC9kaXY+CjwvZGl2PgoKPCEtLSDilIDilIAgVEFCOiBNQU5BR0Ug4pSA4pSAIC0tPgo8ZGl2IGNsYXNzPSJ0YWItcGFuZWwiIGlkPSJ0YWItbWFuYWdlIj4KPGRpdiBjbGFzcz0ibWFpbiI+CiAgPGRpdiBjbGFzcz0ibWdtdC1wYW5lbCI+CiAgICA8ZGl2IGNsYXNzPSJtZ210LWhlYWRlciI+CiAgICAgIDxkaXYgY2xhc3M9Im1nbXQtdGl0bGUiPvCfkaUg4Lij4Liy4Lii4LiK4Li34LmI4LitIFZMRVNTIFVzZXJzPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9InJlZnJlc2gtYnRuIiBvbmNsaWNrPSJsb2FkVXNlckxpc3QoKSI+CiAgICAgICAgPHN2ZyB3aWR0aD0iMTIiIGhlaWdodD0iMTIiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi41Ij48cGF0aCBkPSJNMjMgNHY2aC02Ii8+PHBhdGggZD0iTTEgMjB2LTZoNiIvPjxwYXRoIGQ9Ik0zLjUxIDlhOSA5IDAgMCAxIDE0Ljg1LTMuMzZMMjMgMTBNMSAxNGw0LjY0IDQuMzZBOSA5IDAgMCAwIDIwLjQ5IDE1Ii8+PC9zdmc+CiAgICAgICAg4Lij4Li14LmA4Lif4Lij4LiKCiAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZWFyY2gtYmFyIj4KICAgICAgPGlucHV0IHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLwn5SNIOC4hOC5ieC4meC4q+C4suC4iuC4t+C5iOC4rS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJ1c2VyLWxpc3QiIGlkPSJ1c2VyLWxpc3QiPgogICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nLXJvdyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+CjwvZGl2PgoKPCEtLSDilIDilIAgVEFCOiBPTkxJTkUg4pSA4pSAIC0tPgo8ZGl2IGNsYXNzPSJ0YWItcGFuZWwiIGlkPSJ0YWItb25saW5lIj4KPGRpdiBjbGFzcz0ibWFpbiI+CiAgPGRpdiBjbGFzcz0ibWdtdC1wYW5lbCI+CiAgICA8ZGl2IGNsYXNzPSJtZ210LWhlYWRlciI+CiAgICAgIDxkaXYgY2xhc3M9Im1nbXQtdGl0bGUiPvCfn6IgT25saW5lIFVzZXJzPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9InJlZnJlc2gtYnRuIiBpZD0ib25saW5lLXJlZnJlc2giIG9uY2xpY2s9ImxvYWRPbmxpbmVVc2VycygpIj4KICAgICAgICA8c3ZnIHdpZHRoPSIxMiIgaGVpZ2h0PSIxMiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjUiPjxwYXRoIGQ9Ik0yMyA0djZoLTYiLz48cGF0aCBkPSJNMSAyMHYtNmg2Ii8+PHBhdGggZD0iTTMuNTEgOWE5IDkgMCAwIDEgMTQuODUtMy4zNkwyMyAxME0xIDE0bDQuNjQgNC4zNkE5IDkgMCAwIDAgMjAuNDkgMTUiLz48L3N2Zz4KICAgICAgICDguKPguLXguYDguJ/guKPguIoKICAgICAgPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InVzZXItbGlzdCIgaWQ9Im9ubGluZS1saXN0Ij4KICAgICAgPGRpdiBjbGFzcz0ibG9hZGluZy1yb3ciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2Pgo8L2Rpdj4KCjwhLS0g4pSA4pSAIE1PREFMUyDilIDilIAgLS0+CjwhLS0gQUlTIE1vZGFsIC0tPgo8ZGl2IGNsYXNzPSJtb2RhbC1vdmVybGF5IG1vZGFsLWFpcyIgaWQ9Im1vZGFsLWFpcyI+CjxkaXYgY2xhc3M9Im1vZGFsIj4KICA8ZGl2IGNsYXNzPSJtb2RhbC1oZWFkZXIiPgogICAgPGRpdiBjbGFzcz0ibW9kYWwtdGl0bGUiPvCfn6Ig4Liq4Lij4LmJ4Liy4LiHIEFJUyAvIFZMRVNTLVdTPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJtb2RhbC1jbG9zZSIgb25jbGljaz0iY2xvc2VNb2RhbCgnYWlzJykiPuKclTwvYnV0dG9uPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9Im1vZGFsLWJvZHkiPgogICAgPGRpdiBjbGFzcz0ic25pLWJhZGdlIGFpcyI+8J+MkCBjai1lYmIuc3BlZWR0ZXN0Lm5ldCDCtyBQb3J0IDgwODA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImZncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQgc3BhbjIiPjxsYWJlbD7guIrguLfguYjguK0gVXNlciAoRW1haWwpPC9sYWJlbD48aW5wdXQgdHlwZT0idGV4dCIgaWQ9ImFpcy1lbWFpbCIgcGxhY2Vob2xkZXI9InVzZXJAYWlzIiBjbGFzcz0iYWlzLWZvY3VzIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQiPjxsYWJlbD7guKfguLHguJnguYPguIrguYnguIfguLLguJk8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJhaXMtZGF5cyIgdmFsdWU9IjMwIiBtaW49IjEiIGNsYXNzPSJhaXMtZm9jdXMiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+PGxhYmVsPuC4iOC4s+C4geC4seC4lCBJUDwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9ImFpcy1pcGxpbWl0IiB2YWx1ZT0iMiIgbWluPSIxIiBjbGFzcz0iYWlzLWZvY3VzIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQgc3BhbjIiPjxsYWJlbD7guIjguLPguIHguLHguJTguILguYnguK3guKHguLnguKUgKEdCLCAwPeC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJhaXMtZ2IiIHZhbHVlPSIwIiBtaW49IjAiIGNsYXNzPSJhaXMtZm9jdXMiPjwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJzdWJtaXQtYnRuIGFpcy1idG4iIGlkPSJhaXMtc3VibWl0IiBvbmNsaWNrPSJjcmVhdGVBSVMoKSI+4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJhaXMtYWxlcnQiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0icmVzdWx0LWNhcmQiIGlkPSJhaXMtcmVzdWx0Ij4KICAgICAgPGRpdiBjbGFzcz0icmVzdWx0LWhlYWRlciBhaXMtciI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPuKchSDguKrguKPguYnguLLguIfguKrguLPguYDguKPguYfguIg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0icmVzdWx0LWJvZHkiPgogICAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93cyIgaWQ9ImFpcy1pbmZvLXJvd3MiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmstYm94IHZsZXNzLWxpbmsiIGlkPSJhaXMtdmxlc3MtbGluayI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icXItd3JhcCI+PGRpdiBjbGFzcz0icXItaW5uZXIiIGlkPSJhaXMtcXIiPjwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNvcHktcm93Ij4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIHZsZXNzIiBpZD0iYWlzLWNvcHktdmxlc3MiIG9uY2xpY2s9ImNvcHlFbCgnYWlzLXZsZXNzLWxpbmsnLCdhaXMtY29weS12bGVzcycpIj7wn5OLIENvcHkgVkxFU1M8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+CjwvZGl2PgoKPCEtLSBUUlVFIE1vZGFsIC0tPgo8ZGl2IGNsYXNzPSJtb2RhbC1vdmVybGF5IG1vZGFsLXRydWUiIGlkPSJtb2RhbC10cnVlIj4KPGRpdiBjbGFzcz0ibW9kYWwiPgogIDxkaXYgY2xhc3M9Im1vZGFsLWhlYWRlciI+CiAgICA8ZGl2IGNsYXNzPSJtb2RhbC10aXRsZSI+8J+UtCDguKrguKPguYnguLLguIcgVFJVRSAvIFZMRVNTLVdTPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJtb2RhbC1jbG9zZSIgb25jbGljaz0iY2xvc2VNb2RhbCgndHJ1ZScpIj7inJU8L2J1dHRvbj4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJtb2RhbC1ib2R5Ij4KICAgIDxkaXYgY2xhc3M9InNuaS1iYWRnZSB0cnVlIj7wn4yQIHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXMgwrcgUG9ydCA4ODgwPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJmZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIHNwYW4yIj48bGFiZWw+4LiK4Li34LmI4LitIFVzZXIgKEVtYWlsKTwvbGFiZWw+PGlucHV0IHR5cGU9InRleHQiIGlkPSJ0cnVlLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckB0cnVlIiBjbGFzcz0idHJ1ZS1mb2N1cyI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIj48bGFiZWw+4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0idHJ1ZS1kYXlzIiB2YWx1ZT0iMzAiIG1pbj0iMSIgY2xhc3M9InRydWUtZm9jdXMiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+PGxhYmVsPuC4iOC4s+C4geC4seC4lCBJUDwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9InRydWUtaXBsaW1pdCIgdmFsdWU9IjIiIG1pbj0iMSIgY2xhc3M9InRydWUtZm9jdXMiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCBzcGFuMiI+PGxhYmVsPuC4iOC4s+C4geC4seC4lOC4guC5ieC4reC4oeC4ueC4pSAoR0IsIDA94LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9InRydWUtZ2IiIHZhbHVlPSIwIiBtaW49IjAiIGNsYXNzPSJ0cnVlLWZvY3VzIj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0ic3VibWl0LWJ0biB0cnVlLWJ0biIgaWQ9InRydWUtc3VibWl0IiBvbmNsaWNrPSJjcmVhdGVUUlVFKCkiPuKaoSDguKrguKPguYnguLLguIcgVFJVRSBBY2NvdW50PC9idXR0b24+CiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0icmVzdWx0LWNhcmQiIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgIDxkaXYgY2xhc3M9InJlc3VsdC1oZWFkZXIgdHJ1ZS1yIj48c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+4pyFIOC4quC4o+C5ieC4suC4h+C4quC4s+C5gOC4o+C5h+C4iDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJyZXN1bHQtYm9keSI+CiAgICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3dzIiBpZD0idHJ1ZS1pbmZvLXJvd3MiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmstYm94IHZsZXNzLWxpbmsiIGlkPSJ0cnVlLXZsZXNzLWxpbmsiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InFyLXdyYXAiPjxkaXYgY2xhc3M9InFyLWlubmVyIiBpZD0idHJ1ZS1xciI+PC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iY29weS1yb3ciPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY29weS1idG4gdmxlc3MiIGlkPSJ0cnVlLWNvcHktdmxlc3MiIG9uY2xpY2s9ImNvcHlFbCgndHJ1ZS12bGVzcy1saW5rJywndHJ1ZS1jb3B5LXZsZXNzJykiPvCfk4sgQ29weSBWTEVTUzwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KPC9kaXY+Cgo8IS0tIFNTSCBNb2RhbCAtLT4KPGRpdiBjbGFzcz0ibW9kYWwtb3ZlcmxheSBtb2RhbC1zc2giIGlkPSJtb2RhbC1zc2giPgo8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgPGRpdiBjbGFzcz0ibW9kYWwtaGVhZGVyIj4KICAgIDxkaXYgY2xhc3M9Im1vZGFsLXRpdGxlIj7wn5S1IOC4quC4o+C5ieC4suC4hyBTU0gtV1MgQWNjb3VudDwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0ibW9kYWwtY2xvc2UiIG9uY2xpY2s9ImNsb3NlTW9kYWwoJ3NzaCcpIj7inJU8L2J1dHRvbj4KICA8L2Rpdj4KICA8ZGl2IGNsYXNzPSJtb2RhbC1ib2R5Ij4KICAgIDxkaXYgY2xhc3M9InNuaS1iYWRnZSBzc2giPvCfjJAgUG9ydCA4MCDCtyBEcm9wYmVhcjoxNDMgwrcgSFRUUC1XUyBUdW5uZWw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImZncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQgc3BhbjIiPjxsYWJlbD5Vc2VybmFtZTwvbGFiZWw+PGlucHV0IHR5cGU9InRleHQiIGlkPSJzc2gtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIiBjbGFzcz0ic3NoLWZvY3VzIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQgc3BhbjIiPjxsYWJlbD5QYXNzd29yZDwvbGFiZWw+PGlucHV0IHR5cGU9InBhc3N3b3JkIiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgY2xhc3M9InNzaC1mb2N1cyI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIj48bGFiZWw+4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0ic3NoLWRheXMiIHZhbHVlPSIzMCIgbWluPSIxIiBjbGFzcz0ic3NoLWZvY3VzIj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0ic3VibWl0LWJ0biBzc2gtYnRuIiBpZD0ic3NoLXN1Ym1pdCIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKaoSDguKrguKPguYnguLLguIcgU1NIIEFjY291bnQ8L2J1dHRvbj4KICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0Ij48L2Rpdj4KICAgIDxkaXYgY2xhc3M9InJlc3VsdC1jYXJkIiBpZD0ic3NoLXJlc3VsdCI+CiAgICAgIDxkaXYgY2xhc3M9InJlc3VsdC1oZWFkZXIgc3NoLXIiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj7inIUg4Liq4Lij4LmJ4Liy4LiH4Liq4Liz4LmA4Lij4LmH4LiIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InJlc3VsdC1ib2R5Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvd3MiIGlkPSJzc2gtaW5mby1yb3dzIj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+CjwvZGl2PgoKPGRpdiBjbGFzcz0idG9hc3QiIGlkPSJ0b2FzdCI+PC9kaXY+Cgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIj48L3NjcmlwdD4KPHNjcmlwdD4KLyog4pSA4pSAIENPTkZJRyDilIDilIAgKi8KY29uc3QgQ0ZHICAgICA9ICh0eXBlb2Ygd2luZG93LkNIQUlZQV9DT05GSUcgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdy5DSEFJWUFfQ09ORklHIDoge307CmNvbnN0IEhPU1QgICAgPSBDRkcuaG9zdCAgICB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKY29uc3QgWFVJX0FQSSA9ICcveHVpLWFwaSc7CmNvbnN0IFNTSF9BUEkgPSAnL2FwaSc7CgovKiDilIDilIAgU0VTU0lPTiBHVUFSRCDilIDilIAgKi8KKGZ1bmN0aW9uKCl7CiAgY29uc3QgcyA9IHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oJ2NoYWl5YV9hdXRoJyk7CiAgaWYgKCFzKSB7IHdpbmRvdy5sb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7IHJldHVybjsgfQogIHRyeSB7CiAgICBjb25zdCBkID0gSlNPTi5wYXJzZShzKTsKICAgIGlmICghZC51c2VyIHx8ICFkLnBhc3MgfHwgRGF0ZS5ub3coKSA+PSBkLmV4cCkgewogICAgICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKCdjaGFpeWFfYXV0aCcpOwogICAgICB3aW5kb3cubG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOwogICAgfQogIH0gY2F0Y2goZSkgewogICAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbSgnY2hhaXlhX2F1dGgnKTsKICAgIHdpbmRvdy5sb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7CiAgfQp9KSgpOwoKbGV0IF94dWlDb29raWVTZXQgPSBmYWxzZTsKbGV0IF9hbGxVc2VycyA9IFtdLCBfZmlsdGVyZWRVc2VycyA9IFtdOwoKLyog4pSA4pSAIFRBQiBTV0lUQ0gg4pSA4pSAICovCmZ1bmN0aW9uIHN3aXRjaFRhYih0YWIsIGJ0bikgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy50YWItcGFuZWwnKS5mb3JFYWNoKHAgPT4gcC5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnRhYi1idG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nICsgdGFiKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBpZiAoYnRuKSBidG4uY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgaWYgKHRhYiA9PT0gJ2Rhc2gnKSB7IGxvYWRTdGF0cygpOyBsb2FkU2VydmljZVN0YXR1cygpOyB9CiAgaWYgKHRhYiA9PT0gJ21hbmFnZScpIGxvYWRVc2VyTGlzdCgpOwogIGlmICh0YWIgPT09ICdvbmxpbmUnKSBsb2FkT25saW5lVXNlcnMoKTsKfQoKLyog4pSA4pSAIE1PREFMIOKUgOKUgCAqLwpmdW5jdGlvbiBvcGVuTW9kYWwoaWQpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLScgKyBpZCkuY2xhc3NMaXN0LmFkZCgnb3BlbicpOyBkb2N1bWVudC5ib2R5LnN0eWxlLm92ZXJmbG93ID0gJ2hpZGRlbic7IH0KZnVuY3Rpb24gY2xvc2VNb2RhbChpZCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtJyArIGlkKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7IGRvY3VtZW50LmJvZHkuc3R5bGUub3ZlcmZsb3cgPSAnJzsgfQpkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcubW9kYWwtb3ZlcmxheScpLmZvckVhY2goZWwgPT4gewogIGVsLmFkZEV2ZW50TGlzdGVuZXIoJ2NsaWNrJywgZSA9PiB7IGlmIChlLnRhcmdldCA9PT0gZWwpIHsgZWwuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOyBkb2N1bWVudC5ib2R5LnN0eWxlLm92ZXJmbG93ID0gJyc7IH0gfSk7Cn0pOwoKLyog4pSA4pSAIFVUSUxTIOKUgOKUgCAqLwpmdW5jdGlvbiB2YWwoaWQpIHsgcmV0dXJuIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS52YWx1ZS50cmltKCk7IH0KZnVuY3Rpb24gc2V0QWxlcnQocHJlLCBtc2csIHR5cGUpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKHByZSArICctYWxlcnQnKTsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyArIHR5cGU7IGVsLnRleHRDb250ZW50ID0gbXNnOyBlbC5zdHlsZS5kaXNwbGF5ID0gbXNnID8gJ2Jsb2NrJyA6ICdub25lJzsKfQpmdW5jdGlvbiB0b2FzdChtc2csIG9rID0gdHJ1ZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RvYXN0Jyk7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7IGVsLnN0eWxlLmJhY2tncm91bmQgPSBvayA/ICcjMWEyMzMyJyA6ICcjZWY0NDQ0JzsKICBlbC5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7IHNldFRpbWVvdXQoKCkgPT4gZWwuY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpLCAyNDAwKTsKfQpmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csIGMgPT4gewogICAgY29uc3QgciA9IE1hdGgucmFuZG9tKCkgKiAxNiB8IDA7CiAgICByZXR1cm4gKGMgPT09ICd4JyA/IHIgOiAociAmIDB4MyB8IDB4OCkpLnRvU3RyaW5nKDE2KTsKICB9KTsKfQpmdW5jdGlvbiBmbXRCeXRlcyhieXRlcykgewogIGlmIChieXRlcyA9PT0gMCkgcmV0dXJuICcwIEInOwogIGNvbnN0IGsgPSAxMDI0LCBzID0gWydCJywgJ0tCJywgJ01CJywgJ0dCJywgJ1RCJ107CiAgY29uc3QgaSA9IE1hdGguZmxvb3IoTWF0aC5sb2coYnl0ZXMpIC8gTWF0aC5sb2coaykpOwogIHJldHVybiAoYnl0ZXMgLyBNYXRoLnBvdyhrLCBpKSkudG9GaXhlZCgxKSArICcgJyArIHNbaV07Cn0KZnVuY3Rpb24gY29weUVsKGVsSWQsIGJ0bklkKSB7CiAgY29uc3QgdGV4dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGVsSWQpLnRleHRDb250ZW50LnRyaW0oKTsKICBjb25zdCBkb25lID0gKCkgPT4gewogICAgdG9hc3QoJ/Cfk4sg4LiE4Lix4LiU4Lil4Lit4LiB4LmB4Lil4LmJ4LinIScpOwogICAgaWYgKGJ0bklkKSB7CiAgICAgIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChidG5JZCk7CiAgICAgIGlmIChiKSB7IGNvbnN0IG8gPSBiLnRleHRDb250ZW50OyBiLnRleHRDb250ZW50ID0gJ+KckyBDb3BpZWQhJzsgYi5jbGFzc0xpc3QuYWRkKCdjb3BpZWQnKTsgc2V0VGltZW91dCgoKSA9PiB7IGIudGV4dENvbnRlbnQgPSBvOyBiLmNsYXNzTGlzdC5yZW1vdmUoJ2NvcGllZCcpOyB9LCAyMDAwKTsgfQogICAgfQogIH07CiAgaWYgKG5hdmlnYXRvci5jbGlwYm9hcmQpIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHRleHQpLnRoZW4oZG9uZSkuY2F0Y2goKCkgPT4gZmJDb3B5KHRleHQsIGRvbmUpKTsKICBlbHNlIGZiQ29weSh0ZXh0LCBkb25lKTsKICBmdW5jdGlvbiBmYkNvcHkodCwgY2IpIHsgY29uc3QgdGEgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCd0ZXh0YXJlYScpOyB0YS52YWx1ZSA9IHQ7IHRhLnN0eWxlLmNzc1RleHQgPSAncG9zaXRpb246Zml4ZWQ7dG9wOjA7bGVmdDowO29wYWNpdHk6MDsnOyBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKHRhKTsgdGEuZm9jdXMoKTsgdGEuc2VsZWN0KCk7IHRyeSB7IGRvY3VtZW50LmV4ZWNDb21tYW5kKCdjb3B5Jyk7IGNiKCk7IH0gY2F0Y2goZSkgeyB0b2FzdCgn4p2MIOC4hOC4seC4lOC4peC4reC4geC5hOC4oeC5iOC5hOC4lOC5iScsIGZhbHNlKTsgfSBkb2N1bWVudC5ib2R5LnJlbW92ZUNoaWxkKHRhKTsgfQp9CgovKiDilIDilIAgWFVJIExPR0lOIOKUgOKUgCAobG9naW4g4LmD4Lir4Lih4LmI4LiX4Li44LiB4LiE4Lij4Lix4LmJ4LiHIOC5hOC4oeC5iOC4h+C5ieC4rSBjb29raWUg4LmA4LiB4LmI4LiyKSAqLwphc3luYyBmdW5jdGlvbiB4dWlMb2dpbigpIHsKICAvLyDguK3guYjguLLguJkgY3JlZGVudGlhbHMg4LiI4Liy4LiBIHNlc3Npb25TdG9yYWdlIOC4geC5iOC4reC4mSDguYHguKXguYnguKcgZmFsbGJhY2sg4LmE4LibIGNvbmZpZy5qcwogIGxldCB1c2VyID0gQ0ZHLnh1aV91c2VyIHx8ICdhZG1pbicsIHBhc3MgPSBDRkcueHVpX3Bhc3MgfHwgJyc7CiAgdHJ5IHsKICAgIGNvbnN0IHMgPSBKU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oJ2NoYWl5YV9hdXRoJykgfHwgJ3t9Jyk7CiAgICBpZiAocy51c2VyKSB1c2VyID0gcy51c2VyOwogICAgaWYgKHMucGFzcykgcGFzcyA9IHMucGFzczsKICB9IGNhdGNoKGUpIHt9CiAgLy8gZm9yY2UgcmUtbG9naW4g4LiX4Li44LiB4LiE4Lij4Lix4LmJ4LiHCiAgX3h1aUNvb2tpZVNldCA9IGZhbHNlOwogIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IHVzZXIsIHBhc3N3b3JkOiBwYXNzIH0pOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUlfQVBJICsgJy9sb2dpbicsIHsKICAgIG1ldGhvZDogJ1BPU1QnLCBjcmVkZW50aWFsczogJ2luY2x1ZGUnLAogICAgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL3gtd3d3LWZvcm0tdXJsZW5jb2RlZCcgfSwKICAgIGJvZHk6IGZvcm0udG9TdHJpbmcoKQogIH0pOwogIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICBfeHVpQ29va2llU2V0ID0gISFkLnN1Y2Nlc3M7CiAgcmV0dXJuIGQuc3VjY2VzczsKfQphc3luYyBmdW5jdGlvbiB4dWlHZXQocGF0aCkgewogIGlmICghX3h1aUNvb2tpZVNldCkgYXdhaXQgeHVpTG9naW4oKTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJX0FQSSArIHBhdGgsIHsgY3JlZGVudGlhbHM6ICdpbmNsdWRlJyB9KTsKICByZXR1cm4gci5qc29uKCk7Cn0KYXN5bmMgZnVuY3Rpb24geHVpUG9zdChwYXRoLCBwYXlsb2FkKSB7CiAgaWYgKCFfeHVpQ29va2llU2V0KSBhd2FpdCB4dWlMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUlfQVBJICsgcGF0aCwgewogICAgbWV0aG9kOiAnUE9TVCcsIGNyZWRlbnRpYWxzOiAnaW5jbHVkZScsCiAgICBoZWFkZXJzOiB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSwKICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHBheWxvYWQpCiAgfSk7CiAgcmV0dXJuIHIuanNvbigpOwp9CgovKiDilIDilIAgU1RBVCBSSU5HUyDilIDilIAgKi8KZnVuY3Rpb24gc2V0UmluZyhpZCwgcGN0LCBjb2xvcikgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghZWwpIHJldHVybjsKICBjb25zdCBjaXJjID0gMTYzLjQ7CiAgZWwuc3R5bGUuc3Ryb2tlID0gY29sb3IgfHwgZWwuc3R5bGUuc3Ryb2tlOwogIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBjaXJjIC0gKGNpcmMgKiBNYXRoLm1pbihwY3QsIDEwMCkgLyAxMDApOwp9CmZ1bmN0aW9uIHNldEJhcihpZCwgcGN0KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKGVsKSBlbC5zdHlsZS53aWR0aCA9IE1hdGgubWluKHBjdCwgMTAwKSArICclJzsKfQpmdW5jdGlvbiBiYXJDb2xvcihwY3QpIHsgcmV0dXJuIHBjdCA+IDg1ID8gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZGMyNjI2LCNlZjQ0NDQpJyA6IHBjdCA+IDY1ID8gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZDk3NzA2LCNmOTczMTYpJyA6ICcnOyB9CmZ1bmN0aW9uIHNldEJhZGdlKG9rLCB0ZXh0KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXN0YXR1cy1iYWRnZScpOwogIGlmICghZWwpIHJldHVybjsKICBlbC5pbm5lckhUTUwgPSBvawogICAgPyBgPHNwYW4gY2xhc3M9Im9ubGluZS1iYWRnZSI+PHNwYW4gY2xhc3M9Im9ubGluZS1kb3QiPjwvc3Bhbj4ke3RleHR9PC9zcGFuPmAKICAgIDogYDxzcGFuIGNsYXNzPSJzdGF0dXMtYmFkZ2Ugc3RhdHVzLWRlYWQiPuKaoCAke3RleHR9PC9zcGFuPmA7Cn0KCi8qIOKUgOKUgCBMT0FEIFNUQVRTICh4dWkgQVBJKSDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gbG9hZFN0YXRzKCkgewogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyZWZyZXNoLWJ0bicpOwogIGlmIChidG4pIGJ0bi5jbGFzc0xpc3QuYWRkKCdzcGluJyk7CiAgdHJ5IHsKICAgIGNvbnN0IG9rID0gYXdhaXQgeHVpTG9naW4oKTsKICAgIGlmICghb2spIHsgc2V0QmFkZ2UoZmFsc2UsICdMb2dpbiDguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsgcmV0dXJuOyB9CgogICAgY29uc3Qgc3YgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvc2VydmVyL3N0YXR1cycpLmNhdGNoKCgpID0+IG51bGwpOwogICAgaWYgKHN2ICYmIHN2LnN1Y2Nlc3MgJiYgc3Yub2JqKSB7CiAgICAgIGNvbnN0IG8gPSBzdi5vYmo7CiAgICAgIC8vIENQVQogICAgICBjb25zdCBjcHVQY3QgPSBNYXRoLnJvdW5kKG8uY3B1IHx8IDApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LXZhbCcpLmlubmVySFRNTCA9IGAke2NwdVBjdH08c3BhbiBjbGFzcz0ic3RhdC11bml0Ij4lPC9zcGFuPmA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtY29yZXMnKS50ZXh0Q29udGVudCA9IChvLmNwdUNvcmVzIHx8IG8ubG9naWNhbFBybyB8fCAnLS0nKSArICcgY29yZXMnOwogICAgICBzZXRSaW5nKCdjcHUtcmluZycsIGNwdVBjdCwgJyM1YTllMWMnKTsgc2V0QmFyKCdjcHUtYmFyJywgY3B1UGN0KTsKICAgICAgY29uc3QgY2IgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LWJhcicpOwogICAgICBpZiAoY2IpIHsgY29uc3QgYyA9IGJhckNvbG9yKGNwdVBjdCk7IGlmIChjKSBjYi5zdHlsZS5iYWNrZ3JvdW5kID0gYzsgfQogICAgICAvLyBSQU0KICAgICAgY29uc3QgcmFtVCA9ICgoby5tZW0gJiYgby5tZW0udG90YWwpIHx8IDApIC8gMTA3Mzc0MTgyNDsKICAgICAgY29uc3QgcmFtVSA9ICgoby5tZW0gJiYgby5tZW0uY3VycmVudCkgfHwgMCkgLyAxMDczNzQxODI0OwogICAgICBjb25zdCByYW1QY3QgPSByYW1UID4gMCA/IE1hdGgucm91bmQocmFtVSAvIHJhbVQgKiAxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS12YWwnKS5pbm5lckhUTUwgPSBgJHtyYW1QY3R9PHNwYW4gY2xhc3M9InN0YXQtdW5pdCI+JTwvc3Bhbj5gOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLWRldGFpbCcpLnRleHRDb250ZW50ID0gcmFtVS50b0ZpeGVkKDEpICsgJyAvICcgKyByYW1ULnRvRml4ZWQoMSkgKyAnIEdCJzsKICAgICAgc2V0UmluZygncmFtLXJpbmcnLCByYW1QY3QsICcjMWE2ZmE4Jyk7IHNldEJhcigncmFtLWJhcicsIHJhbVBjdCk7CiAgICAgIGNvbnN0IHJiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1iYXInKTsKICAgICAgaWYgKHJiKSB7IGNvbnN0IGMgPSBiYXJDb2xvcihyYW1QY3QpOyBpZiAoYykgcmIuc3R5bGUuYmFja2dyb3VuZCA9IGM7IH0KICAgICAgLy8gRGlzawogICAgICBjb25zdCBkaXNrVCA9ICgoby5kaXNrICYmIG8uZGlzay50b3RhbCkgfHwgMCkgLyAxMDczNzQxODI0OwogICAgICBjb25zdCBkaXNrVSA9ICgoby5kaXNrICYmIG8uZGlzay5jdXJyZW50KSB8fCAwKSAvIDEwNzM3NDE4MjQ7CiAgICAgIGNvbnN0IGRpc2tQY3QgPSBkaXNrVCA+IDAgPyBNYXRoLnJvdW5kKGRpc2tVIC8gZGlza1QgKiAxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stdmFsJykuaW5uZXJIVE1MID0gYCR7ZGlza1BjdH08c3BhbiBjbGFzcz0ic3RhdC11bml0Ij4lPC9zcGFuPmA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLWRldGFpbCcpLnRleHRDb250ZW50ID0gZGlza1UudG9GaXhlZCgwKSArICcgLyAnICsgZGlza1QudG9GaXhlZCgwKSArICcgR0InOwogICAgICBzZXRCYXIoJ2Rpc2stYmFyJywgZGlza1BjdCk7CiAgICAgIC8vIFVwdGltZQogICAgICBjb25zdCB1cCA9IG8udXB0aW1lIHx8IDA7CiAgICAgIGNvbnN0IGQgPSBNYXRoLmZsb29yKHVwIC8gODY0MDApLCBoID0gTWF0aC5mbG9vcigodXAgJSA4NjQwMCkgLyAzNjAwKSwgbSA9IE1hdGguZmxvb3IoKHVwICUgMzYwMCkgLyA2MCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtdmFsJykudGV4dENvbnRlbnQgPSBkID4gMCA/IGAke2R9ZCAke2h9aGAgOiBgJHtofWggJHttfW1gOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXN1YicpLnRleHRDb250ZW50ID0gYCR7ZH0g4Lin4Lix4LiZICR7aH0g4LiK4LihLiAke219IOC4meC4suC4l+C4tWA7CiAgICAgIGNvbnN0IGxvYWRzID0gby5sb2FkcyB8fCBbXTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvYWQtYXZnLWNoaXBzJykuaW5uZXJIVE1MID0gbG9hZHMubWFwKChsLCBpKSA9PiBbJzFtJywnNW0nLCcxNW0nXVtpXSA/IGA8c3BhbiBjbGFzcz0iY2hpcCI+JHtbJzFtJywnNW0nLCcxNW0nXVtpXX06ICR7bC50b0ZpeGVkKDIpfTwvc3Bhbj4gYCA6ICcnKS5qb2luKCcnKTsKICAgICAgLy8gTmV0d29yawogICAgICBjb25zdCBucyA9IG8ubmV0SU8gfHwgbnVsbDsKICAgICAgaWYgKG5zKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cCcpLnRleHRDb250ZW50ID0gZm10Qnl0ZXMobnMudXAgfHwgMCkgKyAnL3MnOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG93bicpLnRleHRDb250ZW50ID0gZm10Qnl0ZXMobnMuZG93biB8fCAwKSArICcvcyc7CiAgICAgIH0KICAgICAgY29uc3QgbnQgPSBvLm5ldFRyYWZmaWMgfHwgbnVsbDsKICAgICAgaWYgKG50KSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cC10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnICsgZm10Qnl0ZXMobnQuc2VudCB8fCAwKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRvd24tdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJyArIGZtdEJ5dGVzKG50LnJlY3YgfHwgMCk7CiAgICAgIH0KICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS12ZXInKS50ZXh0Q29udGVudCA9ICfguYDguKfguK3guKPguYzguIrguLHguJk6ICcgKyAoby54cmF5VmVyc2lvbiB8fCAnLS0nKTsKICAgICAgc2V0QmFkZ2UodHJ1ZSwgJ+C4reC4reC4meC5hOC4peC4meC5jCcpOwogICAgfQoKICAgIGNvbnN0IGlibCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCkgPT4gbnVsbCk7CiAgICBpZiAoaWJsICYmIGlibC5zdWNjZXNzKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktdHJhZmZpYycpLnRleHRDb250ZW50ID0gYFRyYWZmaWMgaW5ib3VuZHM6ICR7KGlibC5vYmogfHwgW10pLmxlbmd0aH0g4Lij4Liy4Lii4LiB4Liy4LijYDsKICAgIH0KCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGFzdC11cGRhdGUnKS50ZXh0Q29udGVudCA9ICfguK3guLHguJ7guYDguJTguJfguKXguYjguLLguKrguLjguJQ6ICcgKyBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKICB9IGNhdGNoKGUpIHsKICAgIHNldEJhZGdlKGZhbHNlLCAnRXJyb3I6ICcgKyBlLm1lc3NhZ2UpOwogIH0gZmluYWxseSB7CiAgICBpZiAoYnRuKSBidG4uY2xhc3NMaXN0LnJlbW92ZSgnc3BpbicpOwogIH0KfQoKLyog4pSA4pSAIFNFUlZJQ0UgU1RBVFVTICjguJzguYjguLLguJkgU1NIIEFQSSkg4pSA4pSAICovCmFzeW5jIGZ1bmN0aW9uIGxvYWRTZXJ2aWNlU3RhdHVzKCkgewogIGNvbnN0IGdyaWQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWdyaWQnKTsKICBjb25zdCBTRVJWSUNFUyA9IFsKICAgIHsgbmFtZTogJ3gtdWkgUGFuZWwnLCAgICAgIGljb246ICfwn5uwJywgcG9ydHM6ICc6MjA1MycsIGtleTogJ3h1aScgfSwKICAgIHsgbmFtZTogJ1B5dGhvbiBTU0ggQVBJJywgIGljb246ICfwn5CNJywgcG9ydHM6ICc6Njc4OScsIGtleTogJ3NzaCcgfSwKICAgIHsgbmFtZTogJ0Ryb3BiZWFyIFNTSCcsICAgIGljb246ICfwn5C7JywgcG9ydHM6ICc6MTQzIDoxMDknLCBrZXk6ICdkcm9wYmVhcicgfSwKICAgIHsgbmFtZTogJ25naW54IC8gV1MnLCAgICAgIGljb246ICfwn4yQJywgcG9ydHM6ICc6ODAgOjQ0MycsICBrZXk6ICduZ2lueCcgfSwKICAgIHsgbmFtZTogJ1NTSC1XUy1TU0wnLCAgICAgIGljb246ICfwn5SSJywgcG9ydHM6ICc6NDQzJywgICAgICBrZXk6ICdzc2h3cycgfSwKICAgIHsgbmFtZTogJ2JhZHZwbiBVRFAtR1cnLCAgIGljb246ICfwn46uJywgcG9ydHM6ICc6NzMwMCcsICAgICBrZXk6ICdiYWR2cG4nIH0sCiAgXTsKICBncmlkLmlubmVySFRNTCA9IFNFUlZJQ0VTLm1hcChzID0+IGAKICAgIDxkaXYgY2xhc3M9InN2Yy1yb3ciIGlkPSJzdmMtJHtzLmtleX0iPgogICAgICA8ZGl2IGNsYXNzPSJzdmMtZG90IGNoZWNraW5nIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3ZjLWljb24iPiR7cy5pY29ufTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbmFtZSI+JHtzLm5hbWV9PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1wb3J0cyI+JHtzLnBvcnRzfTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtY2hpcCBjaGVja2luZyIgaWQ9InN2Yy1jaGlwLSR7cy5rZXl9Ij7guJXguKPguKfguIjguKrguK3guJouLi48L2Rpdj4KICAgIDwvZGl2PmApLmpvaW4oJycpOwoKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKFNTSF9BUEkgKyAnL3N0YXR1cycpOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAgY29uc3Qgc3ZjTWFwID0gZC5zZXJ2aWNlcyB8fCB7fTsKCiAgICBTRVJWSUNFUy5mb3JFYWNoKHMgPT4gewogICAgICBjb25zdCB1cCA9IHN2Y01hcFtzLmtleV0gPT09IHRydWUgfHwgc3ZjTWFwW3Mua2V5XSA9PT0gJ2FjdGl2ZSc7CiAgICAgIGNvbnN0IHJvdyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtJyArIHMua2V5KTsKICAgICAgY29uc3QgY2hpcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtY2hpcC0nICsgcy5rZXkpOwogICAgICBjb25zdCBkb3QgPSByb3cgPyByb3cucXVlcnlTZWxlY3RvcignLnN2Yy1kb3QnKSA6IG51bGw7CiAgICAgIGlmIChyb3cpIHJvdy5jbGFzc05hbWUgPSAnc3ZjLXJvdyAnICsgKHVwID8gJ3VwJyA6ICdkb3duJyk7CiAgICAgIGlmIChkb3QpIGRvdC5jbGFzc05hbWUgPSAnc3ZjLWRvdCAnICsgKHVwID8gJ3VwJyA6ICdkb3duJyk7CiAgICAgIGlmIChjaGlwKSB7IGNoaXAuY2xhc3NOYW1lID0gJ3N2Yy1jaGlwICcgKyAodXAgPyAndXAnIDogJ2Rvd24nKTsgY2hpcC50ZXh0Q29udGVudCA9IHVwID8gJ1JVTk5JTkcnIDogJ0RPV04nOyB9CiAgICB9KTsKICB9IGNhdGNoKGUpIHsKICAgIFNFUlZJQ0VTLmZvckVhY2gocyA9PiB7CiAgICAgIGNvbnN0IGNoaXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWNoaXAtJyArIHMua2V5KTsKICAgICAgaWYgKGNoaXApIHsgY2hpcC5jbGFzc05hbWUgPSAnc3ZjLWNoaXAgZG93bic7IGNoaXAudGV4dENvbnRlbnQgPSAnRVJST1InOyB9CiAgICB9KTsKICB9Cn0KCi8qIOKUgOKUgCBDUkVBVEUgQUlTIChWTEVTUyBwb3J0IDgwODApIOKUgOKUgCAqLwphc3luYyBmdW5jdGlvbiBjcmVhdGVBSVMoKSB7CiAgY29uc3QgZW1haWwgICA9IHZhbCgnYWlzLWVtYWlsJyk7CiAgY29uc3QgZGF5cyAgICA9IHBhcnNlSW50KHZhbCgnYWlzLWRheXMnKSkgfHwgMzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50KHZhbCgnYWlzLWlwbGltaXQnKSkgfHwgMjsKICBjb25zdCBnYiAgICAgID0gcGFyc2VJbnQodmFsKCdhaXMtZ2InKSkgfHwgMDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2V0QWxlcnQoJ2FpcycsICfguIHguKPguLjguJPguLLguYPguKrguYjguIrguLfguYjguK0gVXNlcicsICdlcnInKTsKCiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fpcy1zdWJtaXQnKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOyBidG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGlubmVyIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBzZXRBbGVydCgnYWlzJywgJycsICcnKTsKCiAgdHJ5IHsKICAgIGNvbnN0IG9rID0gYXdhaXQgeHVpTG9naW4oKTsKICAgIGlmICghb2spIHRocm93IG5ldyBFcnJvcignTG9naW4geC11aSDguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICAvLyDguKvguLIgaW5ib3VuZCBpZCBwb3J0IDgwODAKICAgIGNvbnN0IGxpc3QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgY29uc3QgaWIgPSAobGlzdC5vYmogfHwgW10pLmZpbmQoeCA9PiB4LnBvcnQgPT09IDgwODApOwogICAgaWYgKCFpYikgdGhyb3cgbmV3IEVycm9yKCfguYTguKHguYjguJ7guJogaW5ib3VuZCBwb3J0IDgwODAg4oCUIOC4o+C4seC4mSBzZXR1cCDguIHguYjguK3guJknKTsKCiAgICBjb25zdCB1aWQgPSBnZW5VVUlEKCk7CiAgICBjb25zdCBleHBNcyA9IGRheXMgPiAwID8gKERhdGUubm93KCkgKyBkYXlzICogODY0MDAwMDApIDogMDsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYiAqIDEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgY2xpZW50czogW3sKICAgICAgICAgIGlkOiB1aWQsIGZsb3c6ICcnLCBlbWFpbCwgbGltaXRJcDogaXBMaW1pdCwKICAgICAgICAgIHRvdGFsR0I6IHRvdGFsQnl0ZXMsIGV4cGlyeVRpbWU6IGV4cE1zLAogICAgICAgICAgZW5hYmxlOiB0cnVlLCB0Z0lkOiAnJywgc3ViSWQ6ICcnLCBjb21tZW50OiAnJywgcmVzZXQ6IDAKICAgICAgICB9XQogICAgICB9KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgLy8g4Liq4Lij4LmJ4Liy4LiHIFZMRVNTIGxpbmsKICAgIGNvbnN0IHNuaSA9ICdjai1lYmIuc3BlZWR0ZXN0Lm5ldCc7CiAgICBjb25zdCB2bGVzc0xpbmsgPSBgdmxlc3M6Ly8ke3VpZH1AJHtIT1NUfTo4MDgwP3R5cGU9d3Mmc2VjdXJpdHk9bm9uZSZwYXRoPSUyRnZsZXNzJmhvc3Q9JHtzbml9IyR7ZW5jb2RlVVJJQ29tcG9uZW50KGVtYWlsICsgJy1BSVMnKX1gOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtaW5mby1yb3dzJykuaW5uZXJIVE1MID0gYAogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5FbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiPiR7ZW1haWx9PC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5VVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCIgc3R5bGU9ImZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZTtmb250LXNpemU6LjYycmVtIj4ke3VpZH08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPlBvcnQ8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj44MDgwPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij7guKfguLHguJnguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke2RheXN9IOC4p+C4seC4mTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+SVAgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke2lwTGltaXR9IElQczwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+4LiC4LmJ4Lit4Lih4Li54LilPC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+JHtnYiA+IDAgPyBnYiArICcgR0InIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCd9PC9zcGFuPjwvZGl2PmA7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLXZsZXNzLWxpbmsnKS50ZXh0Q29udGVudCA9IHZsZXNzTGluazsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtcXInKS5pbm5lckhUTUwgPSAnJzsKICAgIG5ldyBRUkNvZGUoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fpcy1xcicpLCB7IHRleHQ6IHZsZXNzTGluaywgd2lkdGg6IDE4MCwgaGVpZ2h0OiAxODAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLXJlc3VsdCcpLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgIHNldEFsZXJ0KCdhaXMnLCAn4pyFIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudCDguKrguLPguYDguKPguYfguIghJywgJ29rJyk7CiAgICB0b2FzdCgn4pyFIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudCDguKrguLPguYDguKPguYfguIghJyk7CiAgfSBjYXRjaChlKSB7CiAgICBzZXRBbGVydCgnYWlzJywgJ+KdjCAnICsgZS5tZXNzYWdlLCAnZXJyJyk7CiAgfSBmaW5hbGx5IHsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOyBidG4uaW5uZXJIVE1MID0gJ+KaoSDguKrguKPguYnguLLguIcgQUlTIEFjY291bnQnOwogIH0KfQoKLyog4pSA4pSAIENSRUFURSBUUlVFIChWTEVTUyBwb3J0IDg4ODApIOKUgOKUgCAqLwphc3luYyBmdW5jdGlvbiBjcmVhdGVUUlVFKCkgewogIGNvbnN0IGVtYWlsICAgPSB2YWwoJ3RydWUtZW1haWwnKTsKICBjb25zdCBkYXlzICAgID0gcGFyc2VJbnQodmFsKCd0cnVlLWRheXMnKSkgfHwgMzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50KHZhbCgndHJ1ZS1pcGxpbWl0JykpIHx8IDI7CiAgY29uc3QgZ2IgICAgICA9IHBhcnNlSW50KHZhbCgndHJ1ZS1nYicpKSB8fCAwOwogIGlmICghZW1haWwpIHJldHVybiBzZXRBbGVydCgndHJ1ZScsICfguIHguKPguLjguJPguLLguYPguKrguYjguIrguLfguYjguK0gVXNlcicsICdlcnInKTsKCiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtc3VibWl0Jyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsgYnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3Bpbm5lciI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgc2V0QWxlcnQoJ3RydWUnLCAnJywgJycpOwoKICB0cnkgewogICAgY29uc3Qgb2sgPSBhd2FpdCB4dWlMb2dpbigpOwogICAgaWYgKCFvaykgdGhyb3cgbmV3IEVycm9yKCdMb2dpbiB4LXVpIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0IGxpc3QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgY29uc3QgaWIgPSAobGlzdC5vYmogfHwgW10pLmZpbmQoeCA9PiB4LnBvcnQgPT09IDg4ODApOwogICAgaWYgKCFpYikgdGhyb3cgbmV3IEVycm9yKCfguYTguKHguYjguJ7guJogaW5ib3VuZCBwb3J0IDg4ODAg4oCUIOC4o+C4seC4mSBzZXR1cCDguIHguYjguK3guJknKTsKCiAgICBjb25zdCB1aWQgPSBnZW5VVUlEKCk7CiAgICBjb25zdCBleHBNcyA9IGRheXMgPiAwID8gKERhdGUubm93KCkgKyBkYXlzICogODY0MDAwMDApIDogMDsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYiAqIDEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7CiAgICAgICAgY2xpZW50czogW3sKICAgICAgICAgIGlkOiB1aWQsIGZsb3c6ICcnLCBlbWFpbCwgbGltaXRJcDogaXBMaW1pdCwKICAgICAgICAgIHRvdGFsR0I6IHRvdGFsQnl0ZXMsIGV4cGlyeVRpbWU6IGV4cE1zLAogICAgICAgICAgZW5hYmxlOiB0cnVlLCB0Z0lkOiAnJywgc3ViSWQ6ICcnLCBjb21tZW50OiAnJywgcmVzZXQ6IDAKICAgICAgICB9XQogICAgICB9KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3Qgc25pID0gJ3RydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXMnOwogICAgY29uc3Qgdmxlc3NMaW5rID0gYHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06ODg4MD90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChlbWFpbCArICctVFJVRScpfWA7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtaW5mby1yb3dzJykuaW5uZXJIVE1MID0gYAogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5FbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiPiR7ZW1haWx9PC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5VVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCIgc3R5bGU9ImZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZTtmb250LXNpemU6LjYycmVtIj4ke3VpZH08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPlBvcnQ8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj44ODgwPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij7guKfguLHguJnguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke2RheXN9IOC4p+C4seC4mTwvc3Bhbj48L2Rpdj5gOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtdmxlc3MtbGluaycpLnRleHRDb250ZW50ID0gdmxlc3NMaW5rOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtcXInKS5pbm5lckhUTUwgPSAnJzsKICAgIG5ldyBRUkNvZGUoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtcXInKSwgeyB0ZXh0OiB2bGVzc0xpbmssIHdpZHRoOiAxODAsIGhlaWdodDogMTgwIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtcmVzdWx0JykuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgc2V0QWxlcnQoJ3RydWUnLCAn4pyFIOC4quC4o+C5ieC4suC4hyBUUlVFIEFjY291bnQg4Liq4Liz4LmA4Lij4LmH4LiIIScsICdvaycpOwogICAgdG9hc3QoJ+KchSDguKrguKPguYnguLLguIcgVFJVRSBBY2NvdW50IOC4quC4s+C5gOC4o+C5h+C4iCEnKTsKICB9IGNhdGNoKGUpIHsKICAgIHNldEFsZXJ0KCd0cnVlJywgJ+KdjCAnICsgZS5tZXNzYWdlLCAnZXJyJyk7CiAgfSBmaW5hbGx5IHsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOyBidG4uaW5uZXJIVE1MID0gJ+KaoSDguKrguKPguYnguLLguIcgVFJVRSBBY2NvdW50JzsKICB9Cn0KCi8qIOKUgOKUgCBDUkVBVEUgU1NIIOKUgOKUgCAqLwphc3luYyBmdW5jdGlvbiBjcmVhdGVTU0goKSB7CiAgY29uc3QgdXNlciA9IHZhbCgnc3NoLXVzZXInKTsKICBjb25zdCBwYXNzID0gdmFsKCdzc2gtcGFzcycpOwogIGNvbnN0IGRheXMgPSBwYXJzZUludCh2YWwoJ3NzaC1kYXlzJykpIHx8IDMwOwogIGlmICghdXNlcikgcmV0dXJuIHNldEFsZXJ0KCdzc2gnLCAn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywgJ2VycicpOwogIGlmICghcGFzcykgcmV0dXJuIHNldEFsZXJ0KCdzc2gnLCAn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3JkJywgJ2VycicpOwoKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXN1Ym1pdCcpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7IGJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW5uZXIiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIHNldEFsZXJ0KCdzc2gnLCAnJywgJycpOwoKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKFNTSF9BUEkgKyAnL2NyZWF0ZV9zc2gnLCB7CiAgICAgIG1ldGhvZDogJ1BPU1QnLAogICAgICBoZWFkZXJzOiB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoeyB1c2VyLCBwYXNzd29yZDogcGFzcywgZGF5cyB9KQogICAgfSk7CiAgICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWluZm8tcm93cycpLmlubmVySFRNTCA9IGAKICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+VXNlcm5hbWU8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke3VzZXJ9PC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5QYXNzd29yZDwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwgcGFzcyI+JHtwYXNzfTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+SG9zdDwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiPiR7SE9TVH08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPlBvcnQgU1NIPC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+MTQzIC8gMTA5PC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5Qb3J0IFdTPC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+ODA8L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPuC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiPiR7ZC5leHB9PC9zcGFuPjwvZGl2PmA7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlc3VsdCcpLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgIHNldEFsZXJ0KCdzc2gnLCAn4pyFIOC4quC4o+C5ieC4suC4hyBTU0ggQWNjb3VudCDguKrguLPguYDguKPguYfguIghJywgJ29rJyk7CiAgICB0b2FzdCgn4pyFIOC4quC4o+C5ieC4suC4hyBTU0ggQWNjb3VudCDguKrguLPguYDguKPguYfguIghJyk7CiAgfSBjYXRjaChlKSB7CiAgICBzZXRBbGVydCgnc3NoJywgJ+KdjCAnICsgZS5tZXNzYWdlLCAnZXJyJyk7CiAgfSBmaW5hbGx5IHsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOyBidG4uaW5uZXJIVE1MID0gJ+KaoSDguKrguKPguYnguLLguIcgU1NIIEFjY291bnQnOwogIH0KfQoKLyog4pSA4pSAIFVTRVIgTElTVCDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJMaXN0KCkgewogIGNvbnN0IGxpc3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0Jyk7CiAgbGlzdC5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZy1yb3ciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IG9rID0gYXdhaXQgeHVpTG9naW4oKTsKICAgIGlmICghb2spIHRocm93IG5ldyBFcnJvcignTG9naW4g4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBjb25zdCBkID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGlmICghZC5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IoJ+C5guC4q+C4peC4lOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgX2FsbFVzZXJzID0gW107CiAgICAoZC5vYmogfHwgW10pLmZvckVhY2goaWIgPT4gewogICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncyA9PT0gJ3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAoc2V0dGluZ3MuY2xpZW50cyB8fCBbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICBfYWxsVXNlcnMucHVzaCh7IGluYm91bmRJZDogaWIuaWQsIGluYm91bmRQb3J0OiBpYi5wb3J0LCBwcm90b2NvbDogaWIucHJvdG9jb2wsIGVtYWlsOiBjLmVtYWlsIHx8IGMuaWQsIHV1aWQ6IGMuaWQsIGV4cGlyeVRpbWU6IGMuZXhwaXJ5VGltZSB8fCAwLCBlbmFibGU6IGMuZW5hYmxlICE9PSBmYWxzZSB9KTsKICAgICAgfSk7CiAgICB9KTsKICAgIF9maWx0ZXJlZFVzZXJzID0gWy4uLl9hbGxVc2Vyc107CiAgICByZW5kZXJVc2VyTGlzdChfZmlsdGVyZWRVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBsaXN0LmlubmVySFRNTCA9IGA8ZGl2IGNsYXNzPSJlbXB0eS1zdGF0ZSI+PGRpdiBjbGFzcz0iZWkiPuKaoO+4jzwvZGl2PjxkaXY+JHtlLm1lc3NhZ2V9PC9kaXY+PC9kaXY+YDsKICB9Cn0KCmZ1bmN0aW9uIHJlbmRlclVzZXJMaXN0KHVzZXJzKSB7CiAgY29uc3QgbGlzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKTsKICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBsaXN0LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJlbXB0eS1zdGF0ZSI+PGRpdiBjbGFzcz0iZWkiPvCflI08L2Rpdj48ZGl2PuC5hOC4oeC5iOC4nuC4muC4ouC4ueC4quC5gOC4i+C4reC4o+C5jDwvZGl2PjwvZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgbGlzdC5pbm5lckhUTUwgPSB1c2Vycy5tYXAodSA9PiB7CiAgICBjb25zdCBpc0FpcyA9IHUuaW5ib3VuZFBvcnQgPT09IDgwODA7CiAgICBsZXQgc3RhdHVzSHRtbCA9ICcnLCBleHBTdHIgPSAnJzsKICAgIGlmICh1LmV4cGlyeVRpbWUgPT09IDApIHsgZXhwU3RyID0gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7IHN0YXR1c0h0bWwgPSAnPHNwYW4gY2xhc3M9InN0YXR1cy1iYWRnZSBzdGF0dXMtb2siPuKckyBBY3RpdmU8L3NwYW4+JzsgfQogICAgZWxzZSB7CiAgICAgIGNvbnN0IGRpZmYgPSB1LmV4cGlyeVRpbWUgLSBub3c7CiAgICAgIGNvbnN0IGRheXMgPSBNYXRoLmNlaWwoZGlmZiAvIDg2NDAwMDAwKTsKICAgICAgaWYgKGRpZmYgPCAwKSB7IGV4cFN0ciA9ICfguKvguKHguJTguK3guLLguKLguLjguYHguKXguYnguKcnOyBzdGF0dXNIdG1sID0gJzxzcGFuIGNsYXNzPSJzdGF0dXMtYmFkZ2Ugc3RhdHVzLWRlYWQiPuKclyBFeHBpcmVkPC9zcGFuPic7IH0KICAgICAgZWxzZSBpZiAoZGF5cyA8PSAzKSB7IGV4cFN0ciA9IGDguYDguKvguKXguLfguK0gJHtkYXlzfSDguKfguLHguJlgOyBzdGF0dXNIdG1sID0gYDxzcGFuIGNsYXNzPSJzdGF0dXMtYmFkZ2Ugc3RhdHVzLWV4cCI+4pqgICR7ZGF5c31kPC9zcGFuPmA7IH0KICAgICAgZWxzZSB7IGV4cFN0ciA9IGAke2RheXN9IOC4p+C4seC4mWA7IHN0YXR1c0h0bWwgPSAnPHNwYW4gY2xhc3M9InN0YXR1cy1iYWRnZSBzdGF0dXMtb2siPuKckyBBY3RpdmU8L3NwYW4+JzsgfQogICAgfQogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1c2VyLXJvdyI+CiAgICAgIDxkaXYgY2xhc3M9InVzZXItYXZhdGFyICR7aXNBaXMgPyAndWEtYWlzJyA6ICd1YS10cnVlJ30iPiR7KHUuZW1haWwgfHwgJz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ1c2VyLWluZm8iPgogICAgICAgIDxkaXYgY2xhc3M9InVzZXItbmFtZSI+JHt1LmVtYWlsfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InVzZXItbWV0YSI+UG9ydCAke3UuaW5ib3VuZFBvcnR9IMK3ICR7ZXhwU3RyfTwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgJHtzdGF0dXNIdG1sfQogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQoKZnVuY3Rpb24gZmlsdGVyVXNlcnMocSkgewogIGNvbnN0IHMgPSBxLnRvTG93ZXJDYXNlKCk7CiAgX2ZpbHRlcmVkVXNlcnMgPSBfYWxsVXNlcnMuZmlsdGVyKHUgPT4gKHUuZW1haWwgfHwgJycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocykpOwogIHJlbmRlclVzZXJMaXN0KF9maWx0ZXJlZFVzZXJzKTsKfQoKLyog4pSA4pSAIE9OTElORSBVU0VSUyDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZVVzZXJzKCkgewogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtcmVmcmVzaCcpOwogIGlmIChidG4pIGJ0bi5jbGFzc0xpc3QuYWRkKCdzcGluJyk7CiAgY29uc3QgbGlzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpOwogIGxpc3QuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmctcm93Ij7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBjb25zdCBvayA9IGF3YWl0IHh1aUxvZ2luKCk7CiAgICBpZiAoIW9rKSB0aHJvdyBuZXcgRXJyb3IoJ0xvZ2luIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgY29uc3Qgb2QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvb25saW5lcycpLmNhdGNoKCgpID0+IG51bGwpOwogICAgY29uc3Qgb25saW5lRW1haWxzID0gKG9kICYmIG9kLm9iaikgPyBvZC5vYmogOiBbXTsKCiAgICBpZiAoIV9hbGxVc2Vycy5sZW5ndGgpIGF3YWl0IGxvYWRVc2VyTGlzdCgpLmNhdGNoKCgpID0+IHt9KTsKICAgIGNvbnN0IHVzZXJNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHUgPT4geyB1c2VyTWFwW3UuZW1haWxdID0gdTsgfSk7CgogICAgaWYgKCFvbmxpbmVFbWFpbHMubGVuZ3RoKSB7CiAgICAgIGxpc3QuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImVtcHR5LXN0YXRlIj48ZGl2IGNsYXNzPSJlaSI+8J+YtDwvZGl2PjxkaXY+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9kaXY+PC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQoKICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgICBsaXN0LmlubmVySFRNTCA9IG9ubGluZUVtYWlscy5tYXAoZW1haWwgPT4gewogICAgICBjb25zdCB1ID0gdXNlck1hcFtlbWFpbF0gfHwgbnVsbDsKICAgICAgY29uc3QgaXNBaXMgPSB1ICYmIHUuaW5ib3VuZFBvcnQgPT09IDgwODA7CiAgICAgIGxldCBleHBMYWJlbCA9ICfguYTguKHguYjguIjguLPguIHguLHguJQnLCBleHBDb2xvciA9ICcjMTZhMzRhJzsKICAgICAgaWYgKHUgJiYgdS5leHBpcnlUaW1lID4gMCkgewogICAgICAgIGNvbnN0IGRpZmYgPSB1LmV4cGlyeVRpbWUgLSBub3c7CiAgICAgICAgY29uc3QgZCA9IE1hdGguY2VpbChkaWZmIC8gODY0MDAwMDApOwogICAgICAgIGV4cExhYmVsID0gZGlmZiA8IDAgPyAn4Lir4Lih4LiU4Lit4Liy4Lii4Li44LmB4Lil4LmJ4LinJyA6IGAke2R9IOC4p+C4seC4mWA7CiAgICAgICAgZXhwQ29sb3IgPSBkaWZmIDwgMCA/ICcjZGMyNjI2JyA6IGQgPD0gMyA/ICcjZWE2YzEwJyA6ICcjMTZhMzRhJzsKICAgICAgfQogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVzZXItcm93Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJ1c2VyLWF2YXRhciAke2lzQWlzID8gJ3VhLWFpcycgOiAndWEtdHJ1ZSd9Ij4keyhlbWFpbCB8fCAnPycpWzBdLnRvVXBwZXJDYXNlKCl9PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idXNlci1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVzZXItbmFtZSI+JHtlbWFpbH0gPHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouNnJlbTtiYWNrZ3JvdW5kOiNlZmY2ZmY7Ym9yZGVyOjFweCBzb2xpZCAjOTNjNWZkO2NvbG9yOiMxZTQwYWY7cGFkZGluZzouMXJlbSAuNHJlbTtib3JkZXItcmFkaXVzOjIwcHg7Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIj4ke3UgPyAnUG9ydCAnICsgdS5pbmJvdW5kUG9ydCA6ICdWTEVTUyd9PC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idXNlci1tZXRhIiBzdHlsZT0iY29sb3I6JHtleHBDb2xvcn0iPvCfk4UgJHtleHBMYWJlbH08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBzdHlsZT0id2lkdGg6MTBweDtoZWlnaHQ6MTBweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiMyMmM1NWU7Ym94LXNoYWRvdzowIDAgNnB4IHJnYmEoMzQsMTk3LDk0LC41NSk7YW5pbWF0aW9uOnB1bHNlIDJzIGluZmluaXRlO2ZsZXgtc2hyaW5rOjAiPjwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgbGlzdC5pbm5lckhUTUwgPSBgPGRpdiBjbGFzcz0iZW1wdHktc3RhdGUiPjxkaXYgY2xhc3M9ImVpIj7imqDvuI88L2Rpdj48ZGl2PiR7ZS5tZXNzYWdlfTwvZGl2PjwvZGl2PmA7CiAgfSBmaW5hbGx5IHsKICAgIGlmIChidG4pIGJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdzcGluJyk7CiAgfQp9CgovKiDilIDilIAgTE9HT1VUIOKUgOKUgCAqLwpmdW5jdGlvbiBkb0xvZ291dCgpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKCdjaGFpeWFfYXV0aCcpOwogIHdpbmRvdy5sb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8qIOKUgOKUgCBTTk9XIOKUgOKUgCAqLwpmdW5jdGlvbiBzdGFydFNub3coY2FudmFzSWQsIGNvdW50KSB7CiAgY29uc3QgY2FudmFzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FudmFzSWQpOwogIGlmICghY2FudmFzKSByZXR1cm47CiAgY29uc3QgY3R4ID0gY2FudmFzLmdldENvbnRleHQoJzJkJyk7CiAgbGV0IGZsYWtlcyA9IFtdOwogIGZ1bmN0aW9uIHJlc2l6ZSgpIHsgY2FudmFzLndpZHRoID0gd2luZG93LmlubmVyV2lkdGg7IGNhbnZhcy5oZWlnaHQgPSAxODA7IH0KICByZXNpemUoKTsKICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJywgcmVzaXplKTsKICBmb3IgKGxldCBpID0gMDsgaSA8IGNvdW50OyBpKyspIGZsYWtlcy5wdXNoKG1rRmxha2UoKSk7CiAgZnVuY3Rpb24gbWtGbGFrZSgpIHsgcmV0dXJuIHsgeDogTWF0aC5yYW5kb20oKSAqIGNhbnZhcy53aWR0aCwgeTogTWF0aC5yYW5kb20oKSAqIGNhbnZhcy5oZWlnaHQsIHI6IE1hdGgucmFuZG9tKCkgKiAxLjggKyAuNiwgc3BlZWQ6IE1hdGgucmFuZG9tKCkgKiAuNiArIC4yLCBkcmlmdDogKE1hdGgucmFuZG9tKCkgLSAuNSkgKiAuMywgb3BhY2l0eTogTWF0aC5yYW5kb20oKSAqIC4zNSArIC4wOCB9OyB9CiAgZnVuY3Rpb24gdGljaygpIHsKICAgIGN0eC5jbGVhclJlY3QoMCwgMCwgY2FudmFzLndpZHRoLCBjYW52YXMuaGVpZ2h0KTsKICAgIGZsYWtlcy5mb3JFYWNoKChmLCBpKSA9PiB7CiAgICAgIGN0eC5iZWdpblBhdGgoKTsgY3R4LmFyYyhmLngsIGYueSwgZi5yLCAwLCBNYXRoLlBJICogMik7CiAgICAgIGN0eC5maWxsU3R5bGUgPSBgcmdiYSgyNTUsMjU1LDI1NSwke2Yub3BhY2l0eX0pYDsgY3R4LmZpbGwoKTsKICAgICAgZi55ICs9IGYuc3BlZWQ7IGYueCArPSBmLmRyaWZ0OwogICAgICBpZiAoZi55ID4gY2FudmFzLmhlaWdodCArIDUpIGZsYWtlc1tpXSA9IG1rRmxha2UoKTsKICAgIH0pOwogICAgcmVxdWVzdEFuaW1hdGlvbkZyYW1lKHRpY2spOwogIH0KICB0aWNrKCk7Cn0KCi8qIOKUgOKUgCBJTklUIOKUgOKUgCAqLwpzdGFydFNub3coJ3Nub3ctY2FudmFzJywgMzApOwoKLy8g4LmC4Lir4Lil4LiU4LiC4LmJ4Lit4Lih4Li54Lil4LiX4Lix4LiZ4LiX4Li14LiX4Li14LmI4Lir4LiZ4LmJ4Liy4Lie4Lij4LmJ4Lit4LihIOKAlCBsb2dpbiDguYPguKvguKHguYjguJfguLjguIHguITguKPguLHguYnguIcg4LmE4Lih4LmI4LiH4LmJ4LitIGNvb2tpZSDguYDguIHguYjguLIKd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ2xvYWQnLCAoKSA9PiB7CiAgX3h1aUNvb2tpZVNldCA9IGZhbHNlOwogIGxvYWRTdGF0cygpOwogIGxvYWRTZXJ2aWNlU3RhdHVzKCk7CiAgc2V0SW50ZXJ2YWwoKCkgPT4gewogICAgaWYgKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWItZGFzaCcpLmNsYXNzTGlzdC5jb250YWlucygnYWN0aXZlJykpIHsKICAgICAgbG9hZFN0YXRzKCk7CiAgICAgIGxvYWRTZXJ2aWNlU3RhdHVzKCk7CiAgICB9CiAgfSwgMzAwMDApOwogIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ3Zpc2liaWxpdHljaGFuZ2UnLCAoKSA9PiB7CiAgICBpZiAoZG9jdW1lbnQudmlzaWJpbGl0eVN0YXRlID09PSAndmlzaWJsZScpIHsKICAgICAgX3h1aUNvb2tpZVNldCA9IGZhbHNlOwogICAgICBsb2FkU3RhdHMoKTsKICAgICAgbG9hZFNlcnZpY2VTdGF0dXMoKTsKICAgIH0KICB9KTsKfSk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K' | base64 -d > /opt/chaiya-panel/sshws.html
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
