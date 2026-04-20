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
apt-get install -y -qq curl wget python3 python3-pip certbot \
  dropbear openssh-server ufw \
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
After=network.target dropbear.service nginx.service
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
# ws-stunnel จะ start หลัง nginx — ไม่ start ตอนนี้
sleep 2
ok "WS-Stunnel พร้อม (port $WS_TUNNEL_PORT → Dropbear:$DROPBEAR_PORT1)"

# ── 3x-ui INSTALL ────────────────────────────────────────────
info "ติดตั้ง 3x-ui..."
if ! command -v x-ui &>/dev/null; then
  _xui_sh=$(mktemp /tmp/xui-XXXXX.sh)
  curl -Ls "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" -o "$_xui_sh" 2>/dev/null
  printf "y\n${XUI_PORT}\n2\n\n\n" | bash "$_xui_sh" >> /var/log/chaiya-xui-install.log 2>&1
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
        (8080, 'CHAIYA-AIS-8080',  'cj-ebb.speedtest.net',           'vless',  'inbound-8080'),
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
        stream   = json.dumps({'network': 'ws', 'security': 'none', 'wsSettings': {'path': '/vless', 'headers': {'Host': host}}})
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
                    'sshws':    ws.strip() == 'active',
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

# ── NGINX INSTALL + CONFIG (port 81) ─────────────────────────
info "ติดตั้ง Nginx ใหม่..."
systemctl stop nginx 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
apt-get purge -y nginx nginx-common nginx-full nginx-core nginx-extras 2>/dev/null || true
rm -rf /etc/nginx /var/log/nginx /var/lib/nginx
apt-get install -y nginx
ok "ติดตั้ง Nginx ใหม่สำเร็จ"

info "ตั้งค่า Nginx port 443..."
rm -f /etc/nginx/sites-enabled/*

# เปิด port 81 ถ้ายังไม่เปิด
ufw allow 443/tcp &>/dev/null || true

if [[ $USE_SSL -eq 1 ]]; then
cat > /etc/nginx/sites-available/chaiya << EOF
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

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya
nginx -t && systemctl restart nginx && ok "Nginx พร้อม (port 443)" || warn "Nginx มีปัญหา — ตรวจ: nginx -t"
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
_PANEL_URL="https://${DOMAIN}"
[[ $USE_SSL -eq 0 ]] && _PANEL_URL="http://${DOMAIN}:81"
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
  panel_url:    "${_PANEL_URL}",
  dashboard_url:"sshws.html"
};
EOF

# ── LOGIN PAGE (index.html) ───────────────────────────────────
info "สร้าง Login Page..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPkNIQUlZQSBWUE4g4oCUIExvZ2luPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1PcmJpdHJvbjp3Z2h0QDcwMDs5MDAmZmFtaWx5PUthbml0OndnaHRAMzAwOzQwMDs2MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c3R5bGU+Cjpyb290IHsKICAtLW5lb246ICNjMDg0ZmM7CiAgLS1uZW9uMjogI2E4NTVmNzsKICAtLW5lb24zOiAjN2MzYWVkOwogIC0tZ2xvdzogcmdiYSgxOTIsMTMyLDI1MiwwLjM1KTsKICAtLWdsb3cyOiByZ2JhKDE2OCw4NSwyNDcsMC4xOCk7CiAgLS1iZzogIzBkMDYxNzsKICAtLWJnMjogIzEyMDgyMDsKICAtLWNhcmQ6IHJnYmEoMjU1LDI1NSwyNTUsMC4wMzUpOwogIC0tYm9yZGVyOiByZ2JhKDE5MiwxMzIsMjUyLDAuMjIpOwogIC0tdGV4dDogI2YwZTZmZjsKICAtLXN1YjogcmdiYSgyMjAsMTgwLDI1NSwwLjUpOwp9CgoqLCo6OmJlZm9yZSwqOjphZnRlciB7IGJveC1zaXppbmc6Ym9yZGVyLWJveDsgbWFyZ2luOjA7IHBhZGRpbmc6MDsgfQoKYm9keSB7CiAgbWluLWhlaWdodDogMTAwdmg7CiAgYmFja2dyb3VuZDogdmFyKC0tYmcpOwogIGZvbnQtZmFtaWx5OiAnS2FuaXQnLCBzYW5zLXNlcmlmOwogIGRpc3BsYXk6IGZsZXg7CiAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBvdmVyZmxvdzogaGlkZGVuOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKfQoKLyog4pSA4pSAIEJBQ0tHUk9VTkQgQkxPQlMg4pSA4pSAICovCi5ibG9iIHsKICBwb3NpdGlvbjogZml4ZWQ7CiAgYm9yZGVyLXJhZGl1czogNTAlOwogIGZpbHRlcjogYmx1cig4MHB4KTsKICBwb2ludGVyLWV2ZW50czogbm9uZTsKICB6LWluZGV4OiAwOwogIGFuaW1hdGlvbjogYmxvYkZsb2F0IDhzIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9Ci5ibG9iMSB7IHdpZHRoOjQyMHB4O2hlaWdodDo0MjBweDtiYWNrZ3JvdW5kOnJnYmEoMTI0LDU4LDIzNywuMTgpO3RvcDotODBweDtsZWZ0Oi0xMDBweDthbmltYXRpb24tZGVsYXk6MHM7IH0KLmJsb2IyIHsgd2lkdGg6MzIwcHg7aGVpZ2h0OjMyMHB4O2JhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMTIpO2JvdHRvbTotNjBweDtyaWdodDotODBweDthbmltYXRpb24tZGVsYXk6M3M7IH0KLmJsb2IzIHsgd2lkdGg6MjAwcHg7aGVpZ2h0OjIwMHB4O2JhY2tncm91bmQ6cmdiYSgxNjgsODUsMjQ3LC4xKTt0b3A6NTAlO2xlZnQ6NjAlO2FuaW1hdGlvbi1kZWxheTo1czsgfQpAa2V5ZnJhbWVzIGJsb2JGbG9hdCB7CiAgMCUsMTAwJSB7IHRyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTsgfQogIDUwJSB7IHRyYW5zZm9ybTp0cmFuc2xhdGUoMjBweCwtMjBweCkgc2NhbGUoMS4wOCk7IH0KfQoKLyog4pSA4pSAIFNUQVJTIOKUgOKUgCAqLwouc3RhcnMgeyBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MDtwb2ludGVyLWV2ZW50czpub25lOyB9Ci5zdGFyIHsKICBwb3NpdGlvbjphYnNvbHV0ZTsKICBiYWNrZ3JvdW5kOiNjMDg0ZmM7CiAgYm9yZGVyLXJhZGl1czo1MCU7CiAgYW5pbWF0aW9uOiB0d2lua2xlIHZhcigtLWQsMnMpIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9CkBrZXlmcmFtZXMgdHdpbmtsZSB7CiAgMCUsMTAwJXtvcGFjaXR5Oi4wODt0cmFuc2Zvcm06c2NhbGUoMSk7fQogIDUwJXtvcGFjaXR5Oi42O3RyYW5zZm9ybTpzY2FsZSgxLjQpO30KfQoKLyog4pSA4pSAIEdSSUQgTElORVMg4pSA4pSAICovCi5ncmlkLWJnIHsKICBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MDtwb2ludGVyLWV2ZW50czpub25lOwogIGJhY2tncm91bmQtaW1hZ2U6CiAgICBsaW5lYXItZ3JhZGllbnQocmdiYSgxOTIsMTMyLDI1MiwuMDQpIDFweCwgdHJhbnNwYXJlbnQgMXB4KSwKICAgIGxpbmVhci1ncmFkaWVudCg5MGRlZywgcmdiYSgxOTIsMTMyLDI1MiwuMDQpIDFweCwgdHJhbnNwYXJlbnQgMXB4KTsKICBiYWNrZ3JvdW5kLXNpemU6IDQ4cHggNDhweDsKfQoKLyog4pSA4pSAIE1BSU4gV1JBUCDilIDilIAgKi8KLndyYXAgewogIHBvc2l0aW9uOnJlbGF0aXZlO3otaW5kZXg6MTA7CiAgd2lkdGg6OTAlO21heC13aWR0aDo0MDBweDsKICBkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDowOwp9CgovKiDilIDilIAgQ0hBUkFDVEVSUyDilIDilIAgKi8KLmNoYXJzIHsKICBkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OmNlbnRlcjtnYXA6MThweDsKICBtYXJnaW4tYm90dG9tOiAtOHB4OwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKICB6LWluZGV4OiAxMTsKfQoKLyogR2hvc3QgKi8KLmdob3N0IHsKICB3aWR0aDo2NHB4O2hlaWdodDo3MHB4OwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGFuaW1hdGlvbjogZ2hvc3RCb2IgMi4ycyBlYXNlLWluLW91dCBpbmZpbml0ZTsKfQouZ2hvc3QtYm9keSB7CiAgd2lkdGg6NjRweDtoZWlnaHQ6NTBweDsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCNlOGQ1ZmYsI2MwODRmYyk7CiAgYm9yZGVyLXJhZGl1czozMnB4IDMycHggMCAwOwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGJveC1zaGFkb3c6IDAgMCAxOHB4IHJnYmEoMTkyLDEzMiwyNTIsLjUpLCBpbnNldCAwIC02cHggMTJweCByZ2JhKDAsMCwwLC4xNSk7Cn0KLmdob3N0LWJvdHRvbSB7CiAgZGlzcGxheTpmbGV4OwogIHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDt3aWR0aDoxMDAlOwp9Ci5naG9zdC13YXZlIHsKICBmbGV4OjE7aGVpZ2h0OjE0cHg7CiAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2MGRlZywjZThkNWZmLCNjMDg0ZmMpOwp9Ci5naG9zdC13YXZlOm50aC1jaGlsZCgxKXsgYm9yZGVyLXJhZGl1czowIDUwJSA1MCUgMDsgfQouZ2hvc3Qtd2F2ZTpudGgtY2hpbGQoMil7IGJvcmRlci1yYWRpdXM6NTAlIDAgMCA1MCU7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDRweCk7IH0KLmdob3N0LXdhdmU6bnRoLWNoaWxkKDMpeyBib3JkZXItcmFkaXVzOjAgNTAlIDUwJSAwOyB9Ci5naG9zdC1leWVzIHsgcG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7bGVmdDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSk7ZGlzcGxheTpmbGV4O2dhcDoxMnB4OyB9Ci5naG9zdC1leWUgeyB3aWR0aDoxMHB4O2hlaWdodDoxMHB4O2JhY2tncm91bmQ6IzNiMDc2NDtib3JkZXItcmFkaXVzOjUwJTtwb3NpdGlvbjpyZWxhdGl2ZTsgfQouZ2hvc3QtZXllOjphZnRlciB7IGNvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7dG9wOjJweDtsZWZ0OjJweDt3aWR0aDo0cHg7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjQpO2JvcmRlci1yYWRpdXM6NTAlOyB9Ci5naG9zdC1ibHVzaCB7IHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbToxMnB4O2Rpc3BsYXk6ZmxleDtnYXA6MjJweDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTt3aWR0aDo1MHB4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuOyB9Ci5naG9zdC1ibHVzaCBzcGFuIHsgd2lkdGg6MTBweDtoZWlnaHQ6NnB4O2JhY2tncm91bmQ6cmdiYSgyMzYsNzIsMTUzLC4zNSk7Ym9yZGVyLXJhZGl1czo1MCU7ZGlzcGxheTpibG9jazsgfQouZ2hvc3Qtc3RhciB7CiAgcG9zaXRpb246YWJzb2x1dGU7dG9wOi04cHg7cmlnaHQ6LTRweDsKICBmb250LXNpemU6MTRweDsKICBhbmltYXRpb246IHN0YXJTcGluIDNzIGxpbmVhciBpbmZpbml0ZTsKICBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA0cHggI2MwODRmYyk7Cn0KQGtleWZyYW1lcyBnaG9zdEJvYiB7CiAgMCUsMTAwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCkgcm90YXRlKC0zZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEwcHgpIHJvdGF0ZSgzZGVnKTsgfQp9CkBrZXlmcmFtZXMgc3RhclNwaW4geyB0b3sgdHJhbnNmb3JtOnJvdGF0ZSgzNjBkZWcpOyB9IH0KCi8qIENhdCAqLwouY2F0IHsKICB3aWR0aDo1NnB4O2hlaWdodDo2OHB4OwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGFuaW1hdGlvbjogY2F0Qm9iIDEuOHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgYW5pbWF0aW9uLWRlbGF5Oi40czsKfQouY2F0LWJvZHkgewogIHdpZHRoOjU2cHg7aGVpZ2h0OjQ4cHg7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCNmNWQwZmUsI2E4NTVmNyk7CiAgYm9yZGVyLXJhZGl1czoyOHB4IDI4cHggMjJweCAyMnB4OwogIHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowOwogIGJveC1zaGFkb3c6MCAwIDE2cHggcmdiYSgxNjgsODUsMjQ3LC40NSk7Cn0KLmNhdC1lYXIgewogIHBvc2l0aW9uOmFic29sdXRlO3RvcDotMTRweDsKICB3aWR0aDowO2hlaWdodDowOwp9Ci5jYXQtZWFyLmxlZnQgeyBsZWZ0OjhweDsgYm9yZGVyLWxlZnQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItYm90dG9tOjIwcHggc29saWQgI2Y1ZDBmZTsgfQouY2F0LWVhci5yaWdodCB7IHJpZ2h0OjhweDsgYm9yZGVyLWxlZnQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItYm90dG9tOjIwcHggc29saWQgI2Y1ZDBmZTsgfQouY2F0LWVhcjo6YWZ0ZXIgeyBjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlOyB9Ci5jYXQtaW5uZXItZWFyIHsKICBwb3NpdGlvbjphYnNvbHV0ZTt0b3A6LThweDsKICB3aWR0aDowO2hlaWdodDowOwp9Ci5jYXQtaW5uZXItZWFyLmxlZnQgeyBsZWZ0OjE0cHg7IGJvcmRlci1sZWZ0OjVweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6NXB4IHNvbGlkIHRyYW5zcGFyZW50O2JvcmRlci1ib3R0b206MTFweCBzb2xpZCAjZTg3OWY5OyB9Ci5jYXQtaW5uZXItZWFyLnJpZ2h0IHsgcmlnaHQ6MTRweDsgYm9yZGVyLWxlZnQ6NXB4IHNvbGlkIHRyYW5zcGFyZW50O2JvcmRlci1yaWdodDo1cHggc29saWQgdHJhbnNwYXJlbnQ7Ym9yZGVyLWJvdHRvbToxMXB4IHNvbGlkICNlODc5Zjk7IH0KLmNhdC1mYWNlIHsgcG9zaXRpb246YWJzb2x1dGU7dG9wOjEwcHg7bGVmdDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSk7d2lkdGg6NDRweDsgfQouY2F0LWV5ZXMgeyBkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWFyb3VuZDttYXJnaW4tYm90dG9tOjRweDsgfQouY2F0LWV5ZSB7IHdpZHRoOjlweDtoZWlnaHQ6OXB4O2JhY2tncm91bmQ6IzJlMTA2NTtib3JkZXItcmFkaXVzOjUwJTtwb3NpdGlvbjpyZWxhdGl2ZTsgfQouY2F0LWV5ZTo6YWZ0ZXIgeyBjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO3RvcDoycHg7bGVmdDoycHg7d2lkdGg6M3B4O2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC41KTtib3JkZXItcmFkaXVzOjUwJTsgfQouY2F0LW5vc2UgeyB3aWR0aDo2cHg7aGVpZ2h0OjVweDtiYWNrZ3JvdW5kOiNmNDcyYjY7Ym9yZGVyLXJhZGl1czo1MCU7bWFyZ2luOjAgYXV0byAycHg7IH0KLmNhdC1tb3V0aCB7IGRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoycHg7IGZvbnQtc2l6ZTo4cHg7IGNvbG9yOiM3YzNhZWQ7IH0KLmNhdC1ibHVzaCB7IGRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjAgMnB4O21hcmdpbi10b3A6MnB4OyB9Ci5jYXQtYmx1c2ggc3BhbiB7IHdpZHRoOjEwcHg7aGVpZ2h0OjZweDtiYWNrZ3JvdW5kOnJnYmEoMjQ5LDE2OCwyMTIsLjUpO2JvcmRlci1yYWRpdXM6NTAlO2Rpc3BsYXk6YmxvY2s7IH0KLmNhdC10YWlsIHsKICBwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206NHB4O3JpZ2h0Oi0xNHB4OwogIHdpZHRoOjIwcHg7aGVpZ2h0OjM2cHg7CiAgYm9yZGVyOjRweCBzb2xpZCAjYTg1NWY3OwogIGJvcmRlci1sZWZ0Om5vbmU7CiAgYm9yZGVyLXJhZGl1czowIDIwcHggMjBweCAwOwogIGFuaW1hdGlvbjp0YWlsV2FnIDFzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIHRyYW5zZm9ybS1vcmlnaW46dG9wIGxlZnQ7CiAgYm94LXNoYWRvdzowIDAgOHB4IHJnYmEoMTY4LDg1LDI0NywuNCk7Cn0KQGtleWZyYW1lcyBjYXRCb2IgewogIDAlLDEwMCV7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApIHJvdGF0ZSgyZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLThweCkgcm90YXRlKC0yZGVnKTsgfQp9CkBrZXlmcmFtZXMgdGFpbFdhZyB7CiAgMCUsMTAwJXsgdHJhbnNmb3JtOnJvdGF0ZSgtMTBkZWcpOyB9CiAgNTAleyB0cmFuc2Zvcm06cm90YXRlKDE1ZGVnKTsgfQp9CgovKiBTdGFyICovCi5zdGFyLWNoYXIgewogIHdpZHRoOjUycHg7aGVpZ2h0OjY4cHg7CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1c3RpZnktY29udGVudDpjZW50ZXI7CiAgcG9zaXRpb246cmVsYXRpdmU7CiAgYW5pbWF0aW9uOiBzdGFyQ2hhckJvYiAyLjZzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIGFuaW1hdGlvbi1kZWxheTouOHM7Cn0KLnN0YXItYm9keSB7CiAgZm9udC1zaXplOjQ2cHg7CiAgbGluZS1oZWlnaHQ6MTsKICBmaWx0ZXI6ZHJvcC1zaGFkb3coMCAwIDEycHggI2MwODRmYykgZHJvcC1zaGFkb3coMCAwIDI0cHggcmdiYSgxOTIsMTMyLDI1MiwuNCkpOwogIGFuaW1hdGlvbjogc3RhclB1bHNlIDEuNXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgdXNlci1zZWxlY3Q6bm9uZTsKfQouc3Rhci1mYWNlIHsKICBwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MTBweDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTsKICBkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MnB4Owp9Ci5zdGFyLWV5ZXMgeyBkaXNwbGF5OmZsZXg7Z2FwOjhweDsgfQouc3Rhci1leWUyIHsgd2lkdGg6NnB4O2hlaWdodDo2cHg7YmFja2dyb3VuZDojMmUxMDY1O2JvcmRlci1yYWRpdXM6NTAlOyB9Ci5zdGFyLXNtaWxlIHsgZm9udC1zaXplOjlweDtjb2xvcjojN2MzYWVkOyB9CkBrZXlmcmFtZXMgc3RhckNoYXJCb2IgewogIDAlLDEwMCV7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApIHJvdGF0ZSg1ZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEycHgpIHJvdGF0ZSgtNWRlZyk7IH0KfQpAa2V5ZnJhbWVzIHN0YXJQdWxzZSB7CiAgMCUsMTAwJXsgZmlsdGVyOmRyb3Atc2hhZG93KDAgMCAxMnB4ICNjMDg0ZmMpIGRyb3Atc2hhZG93KDAgMCAyNHB4IHJnYmEoMTkyLDEzMiwyNTIsLjQpKTsgfQogIDUwJXsgZmlsdGVyOmRyb3Atc2hhZG93KDAgMCAyMHB4ICNlODc5ZjkpIGRyb3Atc2hhZG93KDAgMCAzNnB4IHJnYmEoMjMyLDEyMSwyNDksLjUpKTsgfQp9CgovKiDilIDilIAgQ0FSRCDilIDilIAgKi8KLmNhcmQgewogIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOwogIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgYm9yZGVyLXJhZGl1czogMjhweDsKICBwYWRkaW5nOiAyLjJyZW0gMnJlbSAycmVtOwogIGJhY2tkcm9wLWZpbHRlcjogYmx1cigyNHB4KTsKICBib3gtc2hhZG93OgogICAgMCAwIDAgMXB4IHJnYmEoMTkyLDEzMiwyNTIsLjA4KSwKICAgIDAgOHB4IDQwcHggcmdiYSgxMjQsNTgsMjM3LC4xOCksCiAgICBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsLjA2KTsKICBwb3NpdGlvbjpyZWxhdGl2ZTsKICBvdmVyZmxvdzpoaWRkZW47Cn0KLmNhcmQ6OmJlZm9yZSB7CiAgY29udGVudDonJzsKICBwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4OwogIGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsLjUpLHRyYW5zcGFyZW50KTsKfQouY2FyZDo6YWZ0ZXIgewogIGNvbnRlbnQ6Jyc7CiAgcG9zaXRpb246YWJzb2x1dGU7dG9wOi00MCU7bGVmdDotMjAlOwogIHdpZHRoOjE0MCU7aGVpZ2h0OjE0MCU7CiAgYmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSBhdCA1MCUgMCUscmdiYSgxOTIsMTMyLDI1MiwuMDYpIDAlLHRyYW5zcGFyZW50IDYwJSk7CiAgcG9pbnRlci1ldmVudHM6bm9uZTsKfQoKLmxvZ28tdGFnIHsKICB0ZXh0LWFsaWduOmNlbnRlcjsKICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsKICBmb250LXNpemU6LjVyZW07CiAgbGV0dGVyLXNwYWNpbmc6LjRlbTsKICBjb2xvcjp2YXIoLS1uZW9uKTsKICBvcGFjaXR5Oi42OwogIG1hcmdpbi1ib3R0b206LjRyZW07CiAgdGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlOwp9Ci50aXRsZSB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7CiAgZm9udC1zaXplOjEuNnJlbTsKICBmb250LXdlaWdodDo5MDA7CiAgbGV0dGVyLXNwYWNpbmc6LjA2ZW07CiAgY29sb3I6dmFyKC0tdGV4dCk7CiAgbWFyZ2luLWJvdHRvbTouMnJlbTsKICB0ZXh0LXNoYWRvdzowIDAgMjBweCByZ2JhKDE5MiwxMzIsMjUyLC40KTsKfQoudGl0bGUgc3BhbiB7IGNvbG9yOnZhcigtLW5lb24pOyB9Ci5zdWJ0aXRsZSB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7CiAgZm9udC1zaXplOi43MnJlbTsKICBjb2xvcjp2YXIoLS1zdWIpOwogIG1hcmdpbi1ib3R0b206MS42cmVtOwogIGxldHRlci1zcGFjaW5nOi4wNGVtOwp9CgovKiBTZXJ2ZXIgYmFkZ2UgKi8KLnNlcnZlci1iYWRnZSB7CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDouNXJlbTsKICBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA3KTsKICBib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjE4KTsKICBib3JkZXItcmFkaXVzOjIwcHg7CiAgcGFkZGluZzouM3JlbSAuOXJlbTsKICBtYXJnaW4tYm90dG9tOjEuNHJlbTsKICBmb250LWZhbWlseTptb25vc3BhY2U7CiAgZm9udC1zaXplOi42OHJlbTsKICBjb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC43NSk7Cn0KLnB1bHNlLWRvdCB7CiAgd2lkdGg6N3B4O2hlaWdodDo3cHg7YmFja2dyb3VuZDp2YXIoLS1uZW9uKTtib3JkZXItcmFkaXVzOjUwJTsKICBib3gtc2hhZG93OjAgMCA4cHggdmFyKC0tbmVvbik7CiAgYW5pbWF0aW9uOnB1bHNlIDJzIGluZmluaXRlOwp9CkBrZXlmcmFtZXMgcHVsc2UgeyAwJSwxMDAle29wYWNpdHk6MX01MCV7b3BhY2l0eTouMzV9IH0KCi8qIEZpZWxkcyAqLwouZmllbGQgeyBtYXJnaW4tYm90dG9tOjEuMXJlbTsgfQpsYWJlbCB7CiAgZGlzcGxheTpibG9jazsKICBmb250LXNpemU6LjYycmVtOwogIGxldHRlci1zcGFjaW5nOi4xNGVtOwogIHRleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTsKICBjb2xvcjp2YXIoLS1zdWIpOwogIG1hcmdpbi1ib3R0b206LjQycmVtOwogIGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOwp9Ci5pbnB1dC13cmFwIHsgcG9zaXRpb246cmVsYXRpdmU7IH0KaW5wdXQgewogIHdpZHRoOjEwMCU7CiAgYmFja2dyb3VuZDpyZ2JhKDE5MiwxMzIsMjUyLC4wNik7CiAgYm9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjIpOwogIGJvcmRlci1yYWRpdXM6MTRweDsKICBwYWRkaW5nOi43cmVtIDFyZW07CiAgY29sb3I6dmFyKC0tdGV4dCk7CiAgZm9udC1mYW1pbHk6J0thbml0JyxzYW5zLXNlcmlmOwogIGZvbnQtc2l6ZTouOTJyZW07CiAgb3V0bGluZTpub25lOwogIHRyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4ycywgYm94LXNoYWRvdyAuMnMsIGJhY2tncm91bmQgLjJzOwp9CmlucHV0OjpwbGFjZWhvbGRlciB7IGNvbG9yOnJnYmEoMjIwLDE4MCwyNTUsLjI1KTsgfQppbnB1dDpmb2N1cyB7CiAgYm9yZGVyLWNvbG9yOnJnYmEoMTkyLDEzMiwyNTIsLjU1KTsKICBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjEpOwogIGJveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMTkyLDEzMiwyNTIsLjEpLCAwIDAgMTZweCByZ2JhKDE5MiwxMzIsMjUyLC4xMik7Cn0KLmV5ZS1idG4gewogIHBvc2l0aW9uOmFic29sdXRlO3JpZ2h0Oi43NXJlbTt0b3A6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpOwogIGJhY2tncm91bmQ6bm9uZTtib3JkZXI6bm9uZTtjb2xvcjpyZ2JhKDIyMCwxODAsMjU1LC40KTsKICBjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MXJlbTtwYWRkaW5nOi4ycmVtOwogIHRyYW5zaXRpb246Y29sb3IgLjJzOwp9Ci5leWUtYnRuOmhvdmVyIHsgY29sb3I6dmFyKC0tbmVvbik7IH0KCi8qIEJ1dHRvbiAqLwoubG9naW4tYnRuIHsKICB3aWR0aDoxMDAlO3BhZGRpbmc6Ljg4cmVtO2JvcmRlcjpub25lO2JvcmRlci1yYWRpdXM6MTRweDsKICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzdjM2FlZCwjYTg1NWY3LCNjMDg0ZmMpOwogIGNvbG9yOiNmZmY7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7CiAgZm9udC1zaXplOi44OHJlbTsKICBmb250LXdlaWdodDo3MDA7CiAgbGV0dGVyLXNwYWNpbmc6LjEyZW07CiAgY3Vyc29yOnBvaW50ZXI7CiAgbWFyZ2luLXRvcDouNXJlbTsKICB0cmFuc2l0aW9uOmFsbCAuMjVzOwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIG92ZXJmbG93OmhpZGRlbjsKICBib3gtc2hhZG93OjAgNHB4IDIwcHggcmdiYSgxMjQsNTgsMjM3LC40KSwwIDAgMCAxcHggcmdiYSgxOTIsMTMyLDI1MiwuMik7Cn0KLmxvZ2luLWJ0bjo6YmVmb3JlIHsKICBjb250ZW50OicnOwogIHBvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLHJnYmEoMjU1LDI1NSwyNTUsLjEyKSx0cmFuc3BhcmVudCk7CiAgb3BhY2l0eTowO3RyYW5zaXRpb246b3BhY2l0eSAuMnM7Cn0KLmxvZ2luLWJ0bjpob3Zlcjpub3QoOmRpc2FibGVkKSB7CiAgYm94LXNoYWRvdzowIDZweCAyOHB4IHJnYmEoMTI0LDU4LDIzNywuNTUpLCAwIDAgMzJweCByZ2JhKDE5MiwxMzIsMjUyLC4yNSk7CiAgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7Cn0KLmxvZ2luLWJ0bjpob3Zlcjpub3QoOmRpc2FibGVkKTo6YmVmb3JlIHsgb3BhY2l0eToxOyB9Ci5sb2dpbi1idG46YWN0aXZlOm5vdCg6ZGlzYWJsZWQpIHsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCk7IH0KLmxvZ2luLWJ0bjpkaXNhYmxlZCB7IG9wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkOyB9CgovKiBTcGlubmVyICovCi5zcGlubmVyIHsKICBkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxNHB4O2hlaWdodDoxNHB4OwogIGJvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7CiAgYm9yZGVyLXRvcC1jb2xvcjojZmZmOwogIGJvcmRlci1yYWRpdXM6NTAlOwogIGFuaW1hdGlvbjpzcGluIC43cyBsaW5lYXIgaW5maW5pdGU7CiAgdmVydGljYWwtYWxpZ246bWlkZGxlO21hcmdpbi1yaWdodDouNHJlbTsKfQpAa2V5ZnJhbWVzIHNwaW4geyB0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9IH0KCi8qIEFsZXJ0ICovCi5hbGVydCB7CiAgZGlzcGxheTpub25lO21hcmdpbi10b3A6LjhyZW07CiAgcGFkZGluZzouNjVyZW0gLjlyZW07Ym9yZGVyLXJhZGl1czoxMHB4OwogIGZvbnQtc2l6ZTouOHJlbTtsaW5lLWhlaWdodDoxLjU7Cn0KLmFsZXJ0Lm9rIHsgYmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMyk7Y29sb3I6IzRhZGU4MDsgfQouYWxlcnQuZXJyIHsgYmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjI1KTtjb2xvcjojZjg3MTcxOyB9CgovKiBGb290ZXIgKi8KLmZvb3RlciB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLXRvcDoxLjRyZW07CiAgZm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtc2l6ZTouNnJlbTsKICBjb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC4yNSk7bGV0dGVyLXNwYWNpbmc6LjA2ZW07Cn0KCi8qIE5lb24gbGluZXMgZGVjbyAqLwoubmVvbi1saW5lIHsKICBwb3NpdGlvbjphYnNvbHV0ZTsKICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCx2YXIoLS1uZW9uKSx0cmFuc3BhcmVudCk7CiAgaGVpZ2h0OjFweDtvcGFjaXR5Oi4xNTsKICBhbmltYXRpb246bGluZU1vdmUgNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7Cn0KLm5lb24tbGluZTpudGgtY2hpbGQoMSl7IHRvcDozMCU7d2lkdGg6MTAwJTtsZWZ0OjA7YW5pbWF0aW9uLWRlbGF5OjBzOyB9Ci5uZW9uLWxpbmU6bnRoLWNoaWxkKDIpeyB0b3A6NzAlO3dpZHRoOjYwJTtsZWZ0OjIwJTthbmltYXRpb24tZGVsYXk6MnM7IH0KQGtleWZyYW1lcyBsaW5lTW92ZSB7CiAgMCUsMTAwJXtvcGFjaXR5Oi4wODt9CiAgNTAle29wYWNpdHk6LjI1O30KfQoKLyog4pSA4pSAIEZMT0FUSU5HIFNQQVJLTEVTIOKUgOKUgCAqLwouc3BhcmtsZXMgeyBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDoxOyB9Ci5zcCB7CiAgcG9zaXRpb246YWJzb2x1dGU7CiAgd2lkdGg6NHB4O2hlaWdodDo0cHg7CiAgYmFja2dyb3VuZDp2YXIoLS1uZW9uKTsKICBib3JkZXItcmFkaXVzOjUwJTsKICBib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tbmVvbik7CiAgYW5pbWF0aW9uOnNwRmxvYXQgdmFyKC0tc2QsNnMpIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIG9wYWNpdHk6MDsKfQpAa2V5ZnJhbWVzIHNwRmxvYXQgewogIDAleyBvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCkgc2NhbGUoMCk7IH0KICAyMCV7IG9wYWNpdHk6Ljc7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTIwcHgpIHNjYWxlKDEpOyB9CiAgODAleyBvcGFjaXR5Oi40O3RyYW5zZm9ybTp0cmFuc2xhdGVZKC04MHB4KSBzY2FsZSguNik7IH0KICAxMDAleyBvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEyMHB4KSBzY2FsZSgwKTsgfQp9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+Cgo8IS0tIEJhY2tncm91bmQgLS0+CjxkaXYgY2xhc3M9ImdyaWQtYmciPjwvZGl2Pgo8ZGl2IGNsYXNzPSJibG9iIGJsb2IxIj48L2Rpdj4KPGRpdiBjbGFzcz0iYmxvYiBibG9iMiI+PC9kaXY+CjxkaXYgY2xhc3M9ImJsb2IgYmxvYjMiPjwvZGl2Pgo8ZGl2IGNsYXNzPSJzdGFycyIgaWQ9InN0YXJzIj48L2Rpdj4KPGRpdiBjbGFzcz0ic3BhcmtsZXMiIGlkPSJzcGFya2xlcyI+PC9kaXY+Cgo8ZGl2IGNsYXNzPSJ3cmFwIj4KCiAgPCEtLSBDaGFyYWN0ZXJzIC0tPgogIDxkaXYgY2xhc3M9ImNoYXJzIj4KCiAgICA8IS0tIEdob3N0IC0tPgogICAgPGRpdiBjbGFzcz0iZ2hvc3QiPgogICAgICA8ZGl2IGNsYXNzPSJnaG9zdC1zdGFyIj7inKY8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtYm9keSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtZXllcyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC1leWUiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtZXllIj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC1ibHVzaCI+CiAgICAgICAgICA8c3Bhbj48L3NwYW4+PHNwYW4+PC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Imdob3N0LWJvdHRvbSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC13YXZlIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Imdob3N0LXdhdmUiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3Qtd2F2ZSI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTdGFyIGNoYXIgLS0+CiAgICA8ZGl2IGNsYXNzPSJzdGFyLWNoYXIiPgogICAgICA8ZGl2IGNsYXNzPSJzdGFyLWJvZHkiPuKtkDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdGFyLWZhY2UiPgogICAgICAgIDxkaXYgY2xhc3M9InN0YXItZXllcyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGFyLWV5ZTIiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3Rhci1leWUyIj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGFyLXNtaWxlIj7il6E8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIENhdCAtLT4KICAgIDxkaXYgY2xhc3M9ImNhdCI+CiAgICAgIDxkaXYgY2xhc3M9ImNhdC1lYXIgbGVmdCI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhdC1lYXIgcmlnaHQiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXQtaW5uZXItZWFyIGxlZnQiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXQtaW5uZXItZWFyIHJpZ2h0Ij48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2F0LWJvZHkiPgogICAgICAgIDxkaXYgY2xhc3M9ImNhdC1mYWNlIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImNhdC1leWVzIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2F0LWV5ZSI+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImNhdC1leWUiPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJjYXQtbm9zZSI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJjYXQtbW91dGgiPjxzcGFuPs+JPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iY2F0LWJsdXNoIj4KICAgICAgICAgICAgPHNwYW4+PC9zcGFuPjxzcGFuPjwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2F0LXRhaWwiPjwvZGl2PgogICAgPC9kaXY+CgogIDwvZGl2PgoKICA8IS0tIENhcmQgLS0+CiAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICA8ZGl2IGNsYXNzPSJuZW9uLWxpbmUiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmVvbi1saW5lIj48L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJsb2dvLXRhZyI+4pymIENIQUlZQSBWMlJBWSBQUk8gTUFYIOKcpjwvZGl2PgogICAgPGRpdiBjbGFzcz0idGl0bGUiPkFETUlOIDxzcGFuPlBBTkVMPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0ic3VidGl0bGUiPngtdWkgTWFuYWdlbWVudCBEYXNoYm9hcmQ8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJzZXJ2ZXItYmFkZ2UiPgogICAgICA8c3BhbiBjbGFzcz0icHVsc2UtZG90Ij48L3NwYW4+CiAgICAgIDxzcGFuIGlkPSJzZXJ2ZXItaG9zdCI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9zcGFuPgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICA8bGFiZWw+8J+RpCBVc2VybmFtZTwvbGFiZWw+CiAgICAgIDxpbnB1dCB0eXBlPSJ0ZXh0IiBpZD0iaW5wLXVzZXIiIHBsYWNlaG9sZGVyPSJ1c2VybmFtZSIgYXV0b2NvbXBsZXRlPSJ1c2VybmFtZSI+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICAgIDxsYWJlbD7wn5SRIFBhc3N3b3JkPC9sYWJlbD4KICAgICAgPGRpdiBjbGFzcz0iaW5wdXQtd3JhcCI+CiAgICAgICAgPGlucHV0IHR5cGU9InBhc3N3b3JkIiBpZD0iaW5wLXBhc3MiIHBsYWNlaG9sZGVyPSLigKLigKLigKLigKLigKLigKLigKLigKIiIGF1dG9jb21wbGV0ZT0iY3VycmVudC1wYXNzd29yZCI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iZXllLWJ0biIgaWQ9ImV5ZS1idG4iIG9uY2xpY2s9InRvZ2dsZUV5ZSgpIiB0eXBlPSJidXR0b24iPvCfkYE8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8YnV0dG9uIGNsYXNzPSJsb2dpbi1idG4iIGlkPSJsb2dpbi1idG4iIG9uY2xpY2s9ImRvTG9naW4oKSI+CiAgICAgIOKcpiAmbmJzcDvguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJoKICAgIDwvYnV0dG9uPgoKICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWxlcnQiPjwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZvb3RlciIgaWQ9ImZvb3Rlci10aW1lIj48L2Rpdj4KICA8L2Rpdj4KCjwvZGl2PgoKPHNjcmlwdCBzcmM9ImNvbmZpZy5qcyIgb25lcnJvcj0id2luZG93LkNIQUlZQV9DT05GSUc9e30iPjwvc2NyaXB0Pgo8c2NyaXB0Pgpjb25zdCBDRkcgPSAodHlwZW9mIHdpbmRvdy5DSEFJWUFfQ09ORklHICE9PSAndW5kZWZpbmVkJykgPyB3aW5kb3cuQ0hBSVlBX0NPTkZJRyA6IHt9Owpjb25zdCBYVUlfQVBJID0gJy94dWktYXBpJzsKY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwpjb25zdCBEQVNIQk9BUkQgPSBDRkcuZGFzaGJvYXJkX3VybCB8fCAnc3Nod3MuaHRtbCc7CgovLyBTZXJ2ZXIgaG9zdApkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VydmVyLWhvc3QnKS50ZXh0Q29udGVudCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhvc3RuYW1lOwppZiAoQ0ZHLnh1aV91c2VyKSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5wLXVzZXInKS52YWx1ZSA9IENGRy54dWlfdXNlcjsKCi8vIENsb2NrCmZ1bmN0aW9uIHVwZGF0ZUNsb2NrKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb290ZXItdGltZScpLnRleHRDb250ZW50ID0KICAgIG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpICsgJyDinKYgQ0hBSVlBIFZQTiBTWVNURU0g4pymIHY1LjAnOwp9CnVwZGF0ZUNsb2NrKCk7IHNldEludGVydmFsKHVwZGF0ZUNsb2NrLCAxMDAwKTsKCi8vIEVudGVyIGtleQpkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7IGlmIChlLmtleSA9PT0gJ0VudGVyJykgZG9Mb2dpbigpOyB9KTsKCmxldCBleWVPcGVuID0gZmFsc2U7CmZ1bmN0aW9uIHRvZ2dsZUV5ZSgpIHsKICBleWVPcGVuID0gIWV5ZU9wZW47CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lucC1wYXNzJykudHlwZSA9IGV5ZU9wZW4gPyAndGV4dCcgOiAncGFzc3dvcmQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdleWUtYnRuJykudGV4dENvbnRlbnQgPSBleWVPcGVuID8gJ/CfmYgnIDogJ/CfkYEnOwp9CgpmdW5jdGlvbiBzaG93QWxlcnQobXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWxlcnQnKTsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyArIHR5cGU7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvTG9naW4oKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbnAtdXNlcicpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBwYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lucC1wYXNzJykudmFsdWU7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCAnZXJyJyk7CiAgaWYgKCFwYXNzKSByZXR1cm4gc2hvd0FsZXJ0KCfguIHguKPguLjguJPguLLguYPguKrguYggUGFzc3dvcmQnLCAnZXJyJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luLWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3Bpbm5lciI+PC9zcGFuPiDguIHguLPguKXguLHguIfguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJouLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhbGVydCcpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgdHJ5IHsKICAgIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IHVzZXIsIHBhc3N3b3JkOiBwYXNzIH0pOwogICAgY29uc3QgcmVzID0gYXdhaXQgUHJvbWlzZS5yYWNlKFsKICAgICAgZmV0Y2goWFVJX0FQSSArICcvbG9naW4nLCB7CiAgICAgICAgbWV0aG9kOiAnUE9TVCcsIGNyZWRlbnRpYWxzOiAnaW5jbHVkZScsCiAgICAgICAgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL3gtd3d3LWZvcm0tdXJsZW5jb2RlZCcgfSwKICAgICAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICAgICAgfSksCiAgICAgIG5ldyBQcm9taXNlKChfLHJlaikgPT4gc2V0VGltZW91dCgoKSA9PiByZWoobmV3IEVycm9yKCdUaW1lb3V0JykpLCA4MDAwKSkKICAgIF0pOwogICAgY29uc3QgZGF0YSA9IGF3YWl0IHJlcy5qc29uKCk7CiAgICBpZiAoZGF0YS5zdWNjZXNzKSB7CiAgICAgIHNlc3Npb25TdG9yYWdlLnNldEl0ZW0oU0VTU0lPTl9LRVksIEpTT04uc3RyaW5naWZ5KHsgdXNlciwgcGFzcywgZXhwOiBEYXRlLm5vdygpICsgOCozNjAwKjEwMDAgfSkpOwogICAgICBzaG93QWxlcnQoJ+KchSDguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJrguKrguLPguYDguKPguYfguIgg4LiB4Liz4Lil4Lix4LiHIHJlZGlyZWN0Li4uJywgJ29rJyk7CiAgICAgIHNldFRpbWVvdXQoKCkgPT4geyB3aW5kb3cubG9jYXRpb24ucmVwbGFjZShEQVNIQk9BUkQpOyB9LCA4MDApOwogICAgfSBlbHNlIHsKICAgICAgc2hvd0FsZXJ0KCfinYwgVXNlcm5hbWUg4Lir4Lij4Li34LitIFBhc3N3b3JkIOC5hOC4oeC5iOC4luC4ueC4geC4leC5ieC4reC4hycsICdlcnInKTsKICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIGJ0bi5pbm5lckhUTUwgPSAn4pymICZuYnNwO+C5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mic7CiAgICB9CiAgfSBjYXRjaChlKSB7CiAgICBzaG93QWxlcnQoJ+KdjCAnICsgZS5tZXNzYWdlLCAnZXJyJyk7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgIGJ0bi5pbm5lckhUTUwgPSAn4pymICZuYnNwO+C5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mic7CiAgfQp9CgovLyDilIDilIAgU1RBUlMg4pSA4pSACmNvbnN0IHN0YXJzRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3RhcnMnKTsKZm9yIChsZXQgaSA9IDA7IGkgPCA2MDsgaSsrKSB7CiAgY29uc3QgcyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogIHMuY2xhc3NOYW1lID0gJ3N0YXInOwogIGNvbnN0IHNpemUgPSBNYXRoLnJhbmRvbSgpICogMi41ICsgLjU7CiAgcy5zdHlsZS5jc3NUZXh0ID0gYAogICAgd2lkdGg6JHtzaXplfXB4O2hlaWdodDoke3NpemV9cHg7CiAgICBsZWZ0OiR7TWF0aC5yYW5kb20oKSoxMDB9JTt0b3A6JHtNYXRoLnJhbmRvbSgpKjEwMH0lOwogICAgLS1kOiR7KE1hdGgucmFuZG9tKCkqMysxLjUpLnRvRml4ZWQoMSl9czsKICAgIGFuaW1hdGlvbi1kZWxheTokeyhNYXRoLnJhbmRvbSgpKjQpLnRvRml4ZWQoMSl9czsKICAgIG9wYWNpdHk6JHsoTWF0aC5yYW5kb20oKSouNCsuMDUpLnRvRml4ZWQoMil9OwogIGA7CiAgc3RhcnNFbC5hcHBlbmRDaGlsZChzKTsKfQoKLy8g4pSA4pSAIFNQQVJLTEVTIOKUgOKUgApjb25zdCBzcEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwYXJrbGVzJyk7CmZvciAobGV0IGkgPSAwOyBpIDwgMjA7IGkrKykgewogIGNvbnN0IHNwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgc3AuY2xhc3NOYW1lID0gJ3NwJzsKICBzcC5zdHlsZS5jc3NUZXh0ID0gYAogICAgbGVmdDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICB0b3A6JHsoTWF0aC5yYW5kb20oKSo0MCs0MCl9JTsKICAgIC0tc2Q6JHsoTWF0aC5yYW5kb20oKSo1KzQpLnRvRml4ZWQoMSl9czsKICAgIGFuaW1hdGlvbi1kZWxheTokeyhNYXRoLnJhbmRvbSgpKjYpLnRvRml4ZWQoMSl9czsKICAgIHdpZHRoOiR7TWF0aC5yYW5kb20oKSo0KzJ9cHg7aGVpZ2h0OiR7TWF0aC5yYW5kb20oKSo0KzJ9cHg7CiAgYDsKICBzcEVsLmFwcGVuZENoaWxkKHNwKTsKfQoKLy8g4pSA4pSAIENoYXJhY3RlciB3aWdnbGUgb24gaG92ZXIg4pSA4pSACmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJy5jYXJkJykuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuZ2hvc3QsLmNhdCwuc3Rhci1jaGFyJykuZm9yRWFjaChlbCA9PiB7CiAgICBlbC5zdHlsZS5hbmltYXRpb25QbGF5U3RhdGUgPSAncnVubmluZyc7CiAgfSk7Cn0pOwo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMxYTBhMmUgMCUsIzBmMGExZSA1NSUsIzBhMGEwZiAxMDAlKTtwYWRkaW5nOjI4cHggMjBweCAyMnB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tncm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo3cHg7aGVpZ2h0OjdweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgMS41cyBpbmZpbml0ZTt9CiAgLmRvdC5yZWR7YmFja2dyb3VuZDojZWY0NDQ0O2JveC1zaGFkb3c6MCAwIDZweCAjZWY0NDQ0O30KICBAa2V5ZnJhbWVzIHBsc3swJSwxMDAle2JveC1zaGFkb3c6MCAwIDRweCB2YXIoLS1uZyl9NTAle2JveC1zaGFkb3c6MCAwIDEwcHggdmFyKC0tbmcpLDAgMCAyMHB4IHJnYmEoMzQsMTk3LDk0LC4zKX19CiAgLnh1aS1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC54dWktaW5mb3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS43O30KICAueHVpLWluZm8gYntjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLWxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O21hcmdpbi10b3A6MTBweDt9CiAgLnN2Y3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMDUpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMXB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjt9CiAgLnN2Yy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4wNSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMik7fQogIC5zdmMtbHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O30KICAuZGd7d2lkdGg6OHB4O2hlaWdodDo4cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94LXNoYWRvdzowIDAgNnB4IHZhcigtLW5nKTtmbGV4LXNocmluazowO30KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA2cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4OjEwMDtkaXNwbGF5Om5vbmU7YWxpZ24taXRlbXM6ZmxleC1lbmQ7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLm1vdmVyLm9wZW57ZGlzcGxheTpmbGV4O30KICAubW9kYWx7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjIwcHggMjBweCAwIDA7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDgwcHg7cGFkZGluZzoyMHB4O21heC1oZWlnaHQ6ODV2aDtvdmVyZmxvdy15OmF1dG87YW5pbWF0aW9uOnN1IC4zcyBlYXNlO2JveC1zaGFkb3c6MCAtNHB4IDMwcHggcmdiYSgwLDAsMCwwLjEyKTt9CiAgQGtleWZyYW1lcyBzdXtmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVZKDEwMCUpfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAubWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206MTZweDt9CiAgLm10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS10eHQpO30KICAubWNsb3Nle3dpZHRoOjMycHg7aGVpZ2h0OjMycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAuZGdyaWR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLWJvdHRvbToxNHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRye2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo3cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHI6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5ka3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5kdntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmR2LmdyZWVue2NvbG9yOnZhcigtLW5nKTt9CiAgLmR2LnJlZHtjb2xvcjojZWY0NDQ0O30KICAuZHYubW9ub3tjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDt9CiAgLmFncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O30KICAuYWJ0bntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHggMTBweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5hYnRuOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAuYWJ0biAuYWl7Zm9udC1zaXplOjIycHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5hYnRuIC5hbntmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLmFidG4gLmFke2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5yZXMtYm94e2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tdG9wOjE0cHg7ZGlzcGxheTpub25lO30KICAucmVzLWJveC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5yZXMtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjVweCAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkICNkY2ZjZTc7Zm9udC1zaXplOjEzcHg7fQogIC5yZXMtcm93Omxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRvbTpub25lO30KICAucmVzLWt7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMXB4O30KICAucmVzLXZ7Y29sb3I6dmFyKC0tdHh0KTtmb250LXdlaWdodDo2MDA7d29yZC1icmVhazpicmVhay1hbGw7dGV4dC1hbGlnbjpyaWdodDttYXgtd2lkdGg6NjUlO30KICAucmVzLWxpbmt7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO3dvcmQtYnJlYWs6YnJlYWstYWxsO21hcmdpbi10b3A6OHB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmNvcHktYnRue3dpZHRoOjEwMCU7bWFyZ2luLXRvcDo4cHg7cGFkZGluZzo4cHg7Ym9yZGVyLXJhZGl1czo4cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1hYy1ib3JkZXIpO2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7fQogIC8qIGFsZXJ0ICovCiAgLmFsZXJ0e2Rpc3BsYXk6bm9uZTtwYWRkaW5nOjEwcHggMTRweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5hbGVydC5va3tiYWNrZ3JvdW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xpZCAjODZlZmFjO2NvbG9yOiMxNTgwM2Q7fQogIC5hbGVydC5lcnJ7YmFja2dyb3VuZDojZmVmMmYyO2JvcmRlcjoxcHggc29saWQgI2ZjYTVhNTtjb2xvcjojZGMyNjI2O30KICAvKiBzcGlubmVyICovCiAgLnNwaW57ZGlzcGxheTppbmxpbmUtYmxvY2s7d2lkdGg6MTJweDtoZWlnaHQ6MTJweDtib3JkZXI6MnB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjMpO2JvcmRlci10b3AtY29sb3I6I2ZmZjtib3JkZXItcmFkaXVzOjUwJTthbmltYXRpb246c3AgLjdzIGxpbmVhciBpbmZpbml0ZTt2ZXJ0aWNhbC1hbGlnbjptaWRkbGU7bWFyZ2luLXJpZ2h0OjRweDt9CiAgQGtleWZyYW1lcyBzcHt0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9fQogIC5sb2FkaW5ne3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MzBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEzcHg7fQo8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5Pgo8ZGl2IGNsYXNzPSJ3cmFwIj4KCiAgPCEtLSBIRUFERVIgLS0+CiAgPGRpdiBjbGFzcz0iaGRyIj4KICAgIDxidXR0b24gY2xhc3M9ImxvZ291dCIgb25jbGljaz0iZG9Mb2dvdXQoKSI+4oapIOC4reC4reC4geC4iOC4suC4geC4o+C4sOC4muC4mjwvYnV0dG9uPgogICAgPGRpdiBjbGFzcz0iaGRyLXN1YiI+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imhkci10aXRsZSI+VVNFUiA8c3Bhbj5DUkVBVE9SPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0iaGRyLWRlc2MiIGlkPSJoZHItZG9tYWluIj52NSDCtyBTRUNVUkUgUEFORUw8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSBOQVYgLS0+CiAgPGRpdiBjbGFzcz0ibmF2Ij4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIGFjdGl2ZSIgb25jbGljaz0ic3coJ2Rhc2hib2FyZCcsdGhpcykiPvCfk4og4LmB4LiU4LiK4Lia4Lit4Lij4LmM4LiUPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2NyZWF0ZScsdGhpcykiPuKelSDguKrguKPguYnguLLguIfguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnbWFuYWdlJyx0aGlzKSI+8J+UpyDguIjguLHguJTguIHguLLguKPguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnb25saW5lJyx0aGlzKSI+8J+foiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnYmFuJyx0aGlzKSI+8J+aqyDguJvguKXguJTguYHguJrguJk8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgREFTSEJPQVJEIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMgYWN0aXZlIiBpZD0idGFiLWRhc2hib2FyZCI+CiAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgPHNwYW4gY2xhc3M9InNlYy10aXRsZSI+4pqhIFNZU1RFTSBNT05JVE9SPC9zcGFuPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgaWQ9ImJ0bi1yZWZyZXNoIiBvbmNsaWNrPSJsb2FkRGFzaCgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InNncmlkIj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPuKaoSBDUFUgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9ImNwdS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzRhZGU4MCIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0iY3B1LXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0iY3B1LWNvcmVzIj4tLSBjb3JlczwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwZyIgaWQ9ImNwdS1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+noCBSQU0gVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9InJhbS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzNiODJmNiIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0icmFtLXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0icmFtLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwdSIgaWQ9InJhbS1iYXIiIHN0eWxlPSJ3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjM2I4MmY2LCM2MGE1ZmEpIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7wn5K+IERJU0sgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdmFsIiBpZD0iZGlzay1wY3QiPi0tPHNwYW4+JTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0iZGlzay1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcG8iIGlkPSJkaXNrLWJhciIgc3R5bGU9IndpZHRoOjAlIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7ij7EgVVBUSU1FPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9InVwdGltZS12YWwiIHN0eWxlPSJmb250LXNpemU6MjBweCI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0idXB0aW1lLXN1YiI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YmRnIiBpZD0ibG9hZC1jaGlwcyI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+MkCBORVRXT1JLIEkvTzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJuZXQtcm93Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaRIFVwbG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtdXAiPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtdXAtdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRpdmlkZXIiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Im5pIiBzdHlsZT0idGV4dC1hbGlnbjpyaWdodCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaTIERvd25sb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJucyIgaWQ9Im5ldC1kbiI+LS08c3Bhbj4gLS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJudCIgaWQ9Im5ldC1kbi10b3RhbCI+dG90YWw6IC0tPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+ToSBYLVVJIFBBTkVMIFNUQVRVUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ4dWktcm93Ij4KICAgICAgICA8ZGl2IGlkPSJ4dWktcGlsbCIgY2xhc3M9Im9waWxsIG9mZiI+PHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj7guIHguLPguKXguLHguIfguYDguIrguYfguIQuLi48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ4dWktaW5mbyI+CiAgICAgICAgICA8ZGl2PuC5gOC4p+C4reC4o+C5jOC4iuC4seC4mSBYcmF5OiA8YiBpZD0ieHVpLXZlciI+LS08L2I+PC9kaXY+CiAgICAgICAgICA8ZGl2PkluYm91bmRzOiA8YiBpZD0ieHVpLWluYm91bmRzIj4tLTwvYj4g4Lij4Liy4Lii4LiB4Liy4LijPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPgogICAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+UpyBTRVJWSUNFIE1PTklUT1I8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZFNlcnZpY2VzKCkiPuKGuyDguYDguIrguYfguIQ8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1saXN0IiBpZD0ic3ZjLWxpc3QiPgogICAgICAgIDxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibHUiIGlkPSJsYXN0LXVwZGF0ZSI+4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAtLTwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBDUkVBVEUgU1NIIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiPvCflJIg4Liq4Lij4LmJ4Liy4LiHIFNTSCBXZWJTb2NrZXQgQWNjb3VudDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLWJveCI+8J+UkSBEcm9wYmVhciA6MTQzLzoxMDkgwrcgV1MgUG9ydCA6ODAgwrcg4Liq4Liz4Lir4Lij4Lix4LiaIE5wdlR1bm5lbCAvIERhcmtUdW5uZWw8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgVVNFUk5BTUU8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLXVzZXIiIHBsYWNlaG9sZGVyPSJ1c2VybmFtZSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5SRIFBBU1NXT1JEPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1wYXNzIiBwbGFjZWhvbGRlcj0icGFzc3dvcmQiIHR5cGU9InBhc3N3b3JkIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9InNzaC1idG4iIG9uY2xpY2s9ImNyZWF0ZVNTSCgpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIFNTSCBBY2NvdW50PC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0Ij48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0icmVzLWJveCIgaWQ9InNzaC1yZXN1bHQiPgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+RpCBVc2VybmFtZTwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXNzaC11c2VyIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCflJEgUGFzc3dvcmQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1zc2gtcGFzcyI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4yQIEhvc3Q8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1zc2gtaG9zdCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OhIFNTSCBQb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiI+MTQzIC8gMTA5PC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+UlyBXUyBQb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiI+ODA8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLXNzaC1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+MkCDguKrguKPguYnguLLguIcgVkxFU1MgQWNjb3VudCAoQUlTIMK3IFBvcnQgODA4MCk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1ib3giPlNOSTogY2otZWJiLnNwZWVkdGVzdC5uZXQgwrcgUGF0aDogL3ZsZXNzPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1lbWFpbCIgcGxhY2Vob2xkZXI9InVzZXJAYWlzIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkr4gRGF0YSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0iYWlzLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ2FpcycpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIEFJUyBBY2NvdW50PC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0icmVzLWJveCIgaWQ9ImFpcy1yZXN1bHQiPgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLWFpcy1lbWFpbCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLWFpcy11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItYWlzLWV4cCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLWFpcy1saW5rIj4tLTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci1haXMtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5rPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIj7wn4yQIOC4quC4o+C5ieC4suC4hyBWTEVTUyBBY2NvdW50IChUUlVFIMK3IFBvcnQgODg4MCk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1ib3giPlNOSTogdHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlcyDCtyBQYXRoOiAvdmxlc3M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1lbWFpbCIgcGxhY2Vob2xkZXI9InVzZXJAdHJ1ZSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkr4gRGF0YSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9InRydWUtYnRuIiBvbmNsaWNrPSJjcmVhdGVWTEVTUygndHJ1ZScpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIFRSVUUgQWNjb3VudDwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0idHJ1ZS1yZXN1bHQiPgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXRydWUtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici10cnVlLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici10cnVlLWV4cCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLXRydWUtbGluayI+LS08L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItdHJ1ZS1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgTUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJ1c2VyLXNlYXJjaCIgcGxhY2Vob2xkZXI9IvCflI0gIOC4hOC5ieC4meC4q+C4siB1c2VybmFtZS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgICA8ZGl2IGlkPSJ1c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4m+C4uOC5iOC4oeC5guC4q+C4peC4lOC5gOC4nuC4t+C5iOC4reC4lOC4tuC4h+C4guC5ieC4reC4oeC4ueC4pTwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkT25saW5lKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9jciI+CiAgICAgICAgPGRpdiBjbGFzcz0ib3BpbGwiIGlkPSJvbmxpbmUtcGlsbCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJvbmxpbmUtY291bnQiPjA8L3NwYW4+IOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJ1dCIgaWQ9Im9ubGluZS10aW1lIj4tLTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguKPguLXguYDguJ/guKPguIrguYDguJ7guLfguYjguK3guJTguLnguJzguLnguYnguYPguIrguYnguK3guK3guJnguYTguKXguJnguYw8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBCQU4g4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1iYW4iPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+aqyDguIjguLHguJTguIHguLLguKMgU1NIIFVzZXJzPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIFVTRVJOQU1FPC9kaXY+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImJhbi11c2VyIiBwbGFjZWhvbGRlcj0i4LmD4Liq4LmIIHVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4peC4miI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE1ODAzZCwjMjJjNTVlKSIgb25jbGljaz0iZGVsZXRlU1NIKCkiPvCfl5HvuI8g4Lil4LiaIFNTSCBVc2VyPC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYmFuLWFsZXJ0Ij48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIj7wn5OLIFNTSCBVc2VycyDguJfguLHguYnguIfguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBpZD0ic3NoLXVzZXItbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCjwvZGl2PjwhLS0gL3dyYXAgLS0+Cgo8IS0tIE1PREFMIC0tPgo8ZGl2IGNsYXNzPSJtb3ZlciIgaWQ9Im1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNtKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiIGlkPSJtdCI+4pqZ77iPIHVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbSgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ToSBQb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0iZGUiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OmIERhdGEgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGQiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OKIFRyYWZmaWMg4LmD4LiK4LmJPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR0ciI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk7EgSVAgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGkiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IG1vbm8iIGlkPSJkdXUiPi0tPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMHB4Ij7guYDguKXguLfguK3guIHguIHguLLguKPguJTguLPguYDguJnguLTguJnguIHguLLguKM8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImFncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0icmVuZXdVc2VyKCkiPjxkaXYgY2xhc3M9ImFpIj7wn5SEPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0icmVzZXRUcmFmZmljKCkiPjxkaXYgY2xhc3M9ImFpIj7wn5SDPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIGRhbmdlciIgb25jbGljaz0iZGVsZXRlVXNlcigpIj48ZGl2IGNsYXNzPSJhaSI+8J+Xke+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKXguJrguKLguLnguKo8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lil4Lia4LiW4Liy4Lin4LijPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ibW9kYWwtYWxlcnQiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPjwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQgc3JjPSJjb25maWcuanMiIG9uZXJyb3I9IndpbmRvdy5DSEFJWUFfQ09ORklHPXt9Ij48L3NjcmlwdD4KPHNjcmlwdD4KLy8g4pWQ4pWQ4pWQ4pWQIENPTkZJRyDilZDilZDilZDilZAKY29uc3QgQ0ZHID0gKHR5cGVvZiB3aW5kb3cuQ0hBSVlBX0NPTkZJRyAhPT0gJ3VuZGVmaW5lZCcpID8gd2luZG93LkNIQUlZQV9DT05GSUcgOiB7fTsKY29uc3QgSE9TVCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhvc3RuYW1lOwpjb25zdCBYVUkgID0gJy94dWktYXBpJzsKY29uc3QgQVBJICA9ICcvYXBpJzsKY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwoKLy8gU2Vzc2lvbiBjaGVjawpjb25zdCBfcyA9ICgoKSA9PiB7IHRyeSB7IHJldHVybiBKU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oU0VTU0lPTl9LRVkpfHwne30nKTsgfSBjYXRjaChlKXtyZXR1cm57fTt9IH0pKCk7CmlmICghX3MudXNlciB8fCAhX3MucGFzcyB8fCBEYXRlLm5vdygpID49IChfcy5leHB8fDApKSB7CiAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShTRVNTSU9OX0tFWSk7CiAgbG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOwp9CgovLyBIZWFkZXIgZG9tYWluCmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoZHItZG9tYWluJykudGV4dENvbnRlbnQgPSBIT1NUICsgJyDCtyB2NSc7CgovLyDilZDilZDilZDilZAgVVRJTFMg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGZtdEJ5dGVzKGIpIHsKICBpZiAoIWIgfHwgYiA9PT0gMCkgcmV0dXJuICcwIEInOwogIGNvbnN0IGsgPSAxMDI0LCB1ID0gWydCJywnS0InLCdNQicsJ0dCJywnVEInXTsKICBjb25zdCBpID0gTWF0aC5mbG9vcihNYXRoLmxvZyhiKS9NYXRoLmxvZyhrKSk7CiAgcmV0dXJuIChiL01hdGgucG93KGssaSkpLnRvRml4ZWQoMSkrJyAnK3VbaV07Cn0KZnVuY3Rpb24gZm10RGF0ZShtcykgewogIGlmICghbXMgfHwgbXMgPT09IDApIHJldHVybiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBjb25zdCBkID0gbmV3IERhdGUobXMpOwogIHJldHVybiBkLnRvTG9jYWxlRGF0ZVN0cmluZygndGgtVEgnLHt5ZWFyOidudW1lcmljJyxtb250aDonc2hvcnQnLGRheTonbnVtZXJpYyd9KTsKfQpmdW5jdGlvbiBkYXlzTGVmdChtcykgewogIGlmICghbXMgfHwgbXMgPT09IDApIHJldHVybiBudWxsOwogIHJldHVybiBNYXRoLmNlaWwoKG1zIC0gRGF0ZS5ub3coKSkgLyA4NjQwMDAwMCk7Cn0KZnVuY3Rpb24gc2V0UmluZyhpZCwgcGN0KSB7CiAgY29uc3QgY2lyYyA9IDEzOC4yOwogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmIChlbCkgZWwuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IGNpcmMgLSAoY2lyYyAqIE1hdGgubWluKHBjdCwxMDApIC8gMTAwKTsKfQpmdW5jdGlvbiBzZXRCYXIoaWQsIHBjdCwgd2Fybj1mYWxzZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghZWwpIHJldHVybjsKICBlbC5zdHlsZS53aWR0aCA9IE1hdGgubWluKHBjdCwxMDApICsgJyUnOwogIGlmICh3YXJuICYmIHBjdCA+IDg1KSBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpJzsKICBlbHNlIGlmICh3YXJuICYmIHBjdCA+IDY1KSBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZjk3MzE2LCNmYjkyM2MpJzsKfQpmdW5jdGlvbiBzaG93QWxlcnQoaWQsIG1zZywgdHlwZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghZWwpIHJldHVybjsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyt0eXBlOwogIGVsLnRleHRDb250ZW50ID0gbXNnOwogIGVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIGlmICh0eXBlID09PSAnb2snKSBzZXRUaW1lb3V0KCgpPT57ZWwuc3R5bGUuZGlzcGxheT0nbm9uZSc7fSwgMzAwMCk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBOQVYg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIHN3KG5hbWUsIGVsKSB7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnNlYycpLmZvckVhY2gocz0+cy5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm5hdi1pdGVtJykuZm9yRWFjaChuPT5uLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLScrbmFtZSkuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgZWwuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgaWYgKG5hbWU9PT0nZGFzaGJvYXJkJykgbG9hZERhc2goKTsKICBpZiAobmFtZT09PSdtYW5hZ2UnKSBsb2FkVXNlcnMoKTsKICBpZiAobmFtZT09PSdvbmxpbmUnKSBsb2FkT25saW5lKCk7CiAgaWYgKG5hbWU9PT0nYmFuJykgbG9hZFNTSFVzZXJzKCk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBYVUkgTE9HSU4gKGNvb2tpZSkg4pWQ4pWQ4pWQ4pWQCmxldCBfeHVpT2sgPSBmYWxzZTsKYXN5bmMgZnVuY3Rpb24geHVpTG9naW4oKSB7CiAgY29uc3QgZm9ybSA9IG5ldyBVUkxTZWFyY2hQYXJhbXMoeyB1c2VybmFtZTogX3MudXNlciwgcGFzc3dvcmQ6IF9zLnBhc3MgfSk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSSsnL2xvZ2luJywgewogICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLAogICAgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL3gtd3d3LWZvcm0tdXJsZW5jb2RlZCd9LAogICAgYm9keTogZm9ybS50b1N0cmluZygpCiAgfSk7CiAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogIF94dWlPayA9ICEhZC5zdWNjZXNzOwogIHJldHVybiBfeHVpT2s7Cn0KYXN5bmMgZnVuY3Rpb24geHVpR2V0KHBhdGgpIHsKICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHtjcmVkZW50aWFsczonaW5jbHVkZSd9KTsKICByZXR1cm4gci5qc29uKCk7Cn0KYXN5bmMgZnVuY3Rpb24geHVpUG9zdChwYXRoLCBib2R5KSB7CiAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgYm9keTogSlNPTi5zdHJpbmdpZnkoYm9keSkKICB9KTsKICByZXR1cm4gci5qc29uKCk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBEQVNIQk9BUkQg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWREYXNoKCkgewogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcmVmcmVzaCcpOwogIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsgLi4uJzsKICBfeHVpT2sgPSBmYWxzZTsgLy8gZm9yY2UgcmUtbG9naW4g4LmA4Liq4Lih4LitCgogIHRyeSB7CiAgICAvLyBTU0ggQVBJIHN0YXR1cwogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3QpIHsKICAgICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogICAgfQoKICAgIC8vIFhVSSBzZXJ2ZXIgc3RhdHVzCiAgICBjb25zdCBvayA9IGF3YWl0IHh1aUxvZ2luKCk7CiAgICBpZiAoIW9rKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90IHJlZCI+PC9zcGFuPkxvZ2luIOC5hOC4oeC5iOC5hOC4lOC5iSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCBvZmYnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdiA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9zZXJ2ZXIvc3RhdHVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKHN2ICYmIHN2LnN1Y2Nlc3MgJiYgc3Yub2JqKSB7CiAgICAgIGNvbnN0IG8gPSBzdi5vYmo7CiAgICAgIC8vIENQVQogICAgICBjb25zdCBjcHUgPSBNYXRoLnJvdW5kKG8uY3B1IHx8IDApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LXBjdCcpLnRleHRDb250ZW50ID0gY3B1ICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LWNvcmVzJykudGV4dENvbnRlbnQgPSAoby5jcHVDb3JlcyB8fCBvLmxvZ2ljYWxQcm8gfHwgJy0tJykgKyAnIGNvcmVzJzsKICAgICAgc2V0UmluZygnY3B1LXJpbmcnLCBjcHUpOyBzZXRCYXIoJ2NwdS1iYXInLCBjcHUsIHRydWUpOwoKICAgICAgLy8gUkFNCiAgICAgIGNvbnN0IHJhbVQgPSAoKG8ubWVtPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIHJhbVUgPSAoKG8ubWVtPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgcmFtUCA9IHJhbVQgPiAwID8gTWF0aC5yb3VuZChyYW1VL3JhbVQqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tcGN0JykudGV4dENvbnRlbnQgPSByYW1QICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLWRldGFpbCcpLnRleHRDb250ZW50ID0gcmFtVS50b0ZpeGVkKDEpKycgLyAnK3JhbVQudG9GaXhlZCgxKSsnIEdCJzsKICAgICAgc2V0UmluZygncmFtLXJpbmcnLCByYW1QKTsgc2V0QmFyKCdyYW0tYmFyJywgcmFtUCwgdHJ1ZSk7CgogICAgICAvLyBEaXNrCiAgICAgIGNvbnN0IGRza1QgPSAoKG8uZGlzaz8udG90YWx8fDApLzEwNzM3NDE4MjQpLCBkc2tVID0gKChvLmRpc2s/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCBkc2tQID0gZHNrVCA+IDAgPyBNYXRoLnJvdW5kKGRza1UvZHNrVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stcGN0JykuaW5uZXJIVE1MID0gZHNrUCArICc8c3Bhbj4lPC9zcGFuPic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLWRldGFpbCcpLnRleHRDb250ZW50ID0gZHNrVS50b0ZpeGVkKDApKycgLyAnK2Rza1QudG9GaXhlZCgwKSsnIEdCJzsKICAgICAgc2V0QmFyKCdkaXNrLWJhcicsIGRza1AsIHRydWUpOwoKICAgICAgLy8gVXB0aW1lCiAgICAgIGNvbnN0IHVwID0gby51cHRpbWUgfHwgMDsKICAgICAgY29uc3QgdWQgPSBNYXRoLmZsb29yKHVwLzg2NDAwKSwgdWggPSBNYXRoLmZsb29yKCh1cCU4NjQwMCkvMzYwMCksIHVtID0gTWF0aC5mbG9vcigodXAlMzYwMCkvNjApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXZhbCcpLnRleHRDb250ZW50ID0gdWQgPiAwID8gdWQrJ2QgJyt1aCsnaCcgOiB1aCsnaCAnK3VtKydtJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS1zdWInKS50ZXh0Q29udGVudCA9IHVkKyfguKfguLHguJkgJyt1aCsn4LiK4LihLiAnK3VtKyfguJnguLLguJfguLUnOwogICAgICBjb25zdCBsb2FkcyA9IG8ubG9hZHMgfHwgW107CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2FkLWNoaXBzJykuaW5uZXJIVE1MID0gbG9hZHMubWFwKChsLGkpPT4KICAgICAgICBgPHNwYW4gY2xhc3M9ImJkZyI+JHtbJzFtJywnNW0nLCcxNW0nXVtpXX06ICR7bC50b0ZpeGVkKDIpfTwvc3Bhbj5gKS5qb2luKCcnKTsKCiAgICAgIC8vIE5ldHdvcmsKICAgICAgaWYgKG8ubmV0SU8pIHsKICAgICAgICBjb25zdCB1cF9iID0gby5uZXRJTy51cHx8MCwgZG5fYiA9IG8ubmV0SU8uZG93bnx8MDsKICAgICAgICBjb25zdCB1cEZtdCA9IGZtdEJ5dGVzKHVwX2IpLCBkbkZtdCA9IGZtdEJ5dGVzKGRuX2IpOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAnKS5pbm5lckhUTUwgPSB1cEZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuJykuaW5uZXJIVE1MID0gZG5GbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgIH0KICAgICAgaWYgKG8ubmV0VHJhZmZpYykgewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAtdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMuc2VudHx8MCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbi10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5yZWN2fHwwKTsKICAgICAgfQoKICAgICAgLy8gWFVJIHZlcnNpb24KICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS12ZXInKS50ZXh0Q29udGVudCA9IG8ueHJheVZlcnNpb24gfHwgJy0tJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj7guK3guK3guJnguYTguKXguJnguYwnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwnOwogICAgfQoKICAgIC8vIEluYm91bmRzIGNvdW50CiAgICBjb25zdCBpYmwgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChpYmwgJiYgaWJsLnN1Y2Nlc3MpIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1pbmJvdW5kcycpLnRleHRDb250ZW50ID0gKGlibC5vYmp8fFtdKS5sZW5ndGg7CiAgICB9CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xhc3QtdXBkYXRlJykudGV4dENvbnRlbnQgPSAn4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAnICsgbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zb2xlLmVycm9yKGUpOwogIH0gZmluYWxseSB7CiAgICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IOC4o+C4teC5gOC4n+C4o+C4iic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU0VSVklDRVMg4pWQ4pWQ4pWQ4pWQCmNvbnN0IFNWQ19ERUYgPSBbCiAgeyBrZXk6J3h1aScsICAgICAgaWNvbjon8J+ToScsIG5hbWU6J3gtdWkgUGFuZWwnLCAgICAgIHBvcnQ6JzoyMDUzJyB9LAogIHsga2V5Oidzc2gnLCAgICAgIGljb246J/CfkI0nLCBuYW1lOidTU0ggQVBJJywgICAgICAgICAgcG9ydDonOjY3ODknIH0sCiAgeyBrZXk6J2Ryb3BiZWFyJywgaWNvbjon8J+QuycsIG5hbWU6J0Ryb3BiZWFyIFNTSCcsICAgICBwb3J0Oic6MTQzIDoxMDknIH0sCiAgeyBrZXk6J25naW54JywgICAgaWNvbjon8J+MkCcsIG5hbWU6J25naW54IC8gUGFuZWwnLCAgICBwb3J0Oic6ODAgOjQ0MycgfSwKICB7IGtleTonc3Nod3MnLCAgICBpY29uOifwn5SSJywgbmFtZTonV1MtU3R1bm5lbCcsICAgICAgIHBvcnQ6Jzo4MOKGkjoxNDMnIH0sCiAgeyBrZXk6J2JhZHZwbicsICAgaWNvbjon8J+OricsIG5hbWU6J0JhZFZQTiBVRFBHVycsICAgICBwb3J0Oic6NzMwMCcgfSwKXTsKZnVuY3Rpb24gcmVuZGVyU2VydmljZXMobWFwKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gU1ZDX0RFRi5tYXAocyA9PiB7CiAgICBjb25zdCB1cCA9IG1hcFtzLmtleV0gPT09IHRydWUgfHwgbWFwW3Mua2V5XSA9PT0gJ2FjdGl2ZSc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InN2YyAke3VwPycnOidkb3duJ30iPgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnICR7dXA/Jyc6J3JlZCd9Ij48L3NwYW4+PHNwYW4+JHtzLmljb259PC9zcGFuPgogICAgICAgIDxkaXY+PGRpdiBjbGFzcz0ic3ZjLW4iPiR7cy5uYW1lfTwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj4ke3MucG9ydH08L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJyYmRnICR7dXA/Jyc6J2Rvd24nfSI+JHt1cD8nUlVOTklORyc6J0RPV04nfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFNlcnZpY2VzKCkgewogIHRyeSB7CiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvZGl2Pic7CiAgfQp9CgovLyDilZDilZDilZDilZAgQ1JFQVRFIFNTSCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1kYXlzJykudmFsdWUpfHwzMDsKICBpZiAoIXVzZXIpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBVc2VybmFtZScsJ2VycicpOwogIGlmICghcGFzcykgcmV0dXJuIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3JkJywnZXJyJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOyBidG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZXN1bHQnKS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9jcmVhdGVfc3NoJywgewogICAgICBtZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7dXNlciwgcGFzc3dvcmQ6cGFzcywgZGF5c30pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Itc3NoLXVzZXInKS50ZXh0Q29udGVudCA9IHVzZXI7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci1zc2gtcGFzcycpLnRleHRDb250ZW50ID0gcGFzczsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLXNzaC1ob3N0JykudGV4dENvbnRlbnQgPSBIT1NUOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Itc3NoLWV4cCcpLnRleHRDb250ZW50ID0gZC5leHA7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlc3VsdCcpLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4pyFIOC4quC4o+C5ieC4suC4hyBTU0ggQWNjb3VudCDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWU9Jyc7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlPScnOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfimqEg4Liq4Lij4LmJ4Liy4LiHIFNTSCBBY2NvdW50JzsgfQp9CgovLyDilZDilZDilZDilZAgQ1JFQVRFIFZMRVNTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csYz0+ewogICAgY29uc3Qgcj1NYXRoLnJhbmRvbSgpKjE2fDA7IHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3wweDgpKS50b1N0cmluZygxNik7CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gY3JlYXRlVkxFU1MoY2FycmllcikgewogIGNvbnN0IGVtYWlsRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZW1haWwnKTsKICBjb25zdCBkYXlzRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWRheXMnKTsKICBjb25zdCBpcEVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWlwJyk7CiAgY29uc3QgZ2JFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1nYicpOwogIGNvbnN0IGVtYWlsICAgPSBlbWFpbEVsLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzICAgID0gcGFyc2VJbnQoZGF5c0VsLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50KGlwRWwudmFsdWUpfHwyOwogIGNvbnN0IGdiICAgICAgPSBwYXJzZUludChnYkVsLnZhbHVlKXx8MDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBFbWFpbC9Vc2VybmFtZScsJ2VycicpOwoKICBjb25zdCBwb3J0ID0gY2Fycmllcj09PSdhaXMnID8gODA4MCA6IDg4ODA7CiAgY29uc3Qgc25pICA9IGNhcnJpZXI9PT0nYWlzJyA/ICdjai1lYmIuc3BlZWR0ZXN0Lm5ldCcgOiAndHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlcyc7CgogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1idG4nKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CgogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIC8vIOC4q+C4siBpbmJvdW5kIGlkCiAgICBjb25zdCBsaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliID0gKGxpc3Qub2JqfHxbXSkuZmluZCh4PT54LnBvcnQ9PT1wb3J0KTsKICAgIGlmICghaWIpIHRocm93IG5ldyBFcnJvcihg4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCAke3BvcnR9IOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZYCk7CgogICAgY29uc3QgdWlkID0gZ2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXMgPSBkYXlzID4gMCA/IChEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMCkgOiAwOwogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDp1aWQsIGZsb3c6JycsIGVtYWlsLCBsaW1pdElwOmlwTGltaXQsCiAgICAgICAgdG90YWxHQjp0b3RhbEJ5dGVzLCBleHBpcnlUaW1lOmV4cE1zLCBlbmFibGU6dHJ1ZSwgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgbGluayA9IGB2bGVzczovLyR7dWlkfUAke0hPU1R9OiR7cG9ydH0/dHlwZT13cyZzZWN1cml0eT1ub25lJnBhdGg9JTJGdmxlc3MmaG9zdD0ke3NuaX0jJHtlbmNvZGVVUklDb21wb25lbnQoZW1haWwrJy0nKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSl9YDsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1lbWFpbCcpLnRleHRDb250ZW50ID0gZW1haWw7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy11dWlkJykudGV4dENvbnRlbnQgPSB1aWQ7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1leHAnKS50ZXh0Q29udGVudCA9IGV4cE1zID4gMCA/IGZtdERhdGUoZXhwTXMpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1saW5rJykudGV4dENvbnRlbnQgPSBsaW5rOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHIFZMRVNTIEFjY291bnQg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGVtYWlsRWwudmFsdWU9Jyc7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4pqhIOC4quC4o+C5ieC4suC4hyAnKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSsnIEFjY291bnQnOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBNQU5BR0UgVVNFUlMg4pWQ4pWQ4pWQ4pWQCmxldCBfYWxsVXNlcnMgPSBbXSwgX2N1clVzZXIgPSBudWxsOwphc3luYyBmdW5jdGlvbiBsb2FkVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcign4LmC4Lir4Lil4LiU4LmE4Lih4LmI4LmE4LiU4LmJJyk7CiAgICBfYWxsVXNlcnMgPSBbXTsKICAgIChkLm9ianx8W10pLmZvckVhY2goaWIgPT4gewogICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgIF9hbGxVc2Vycy5wdXNoKHsKICAgICAgICAgIGliSWQ6IGliLmlkLCBwb3J0OiBpYi5wb3J0LCBwcm90bzogaWIucHJvdG9jb2wsCiAgICAgICAgICBlbWFpbDogYy5lbWFpbHx8Yy5pZCwgdXVpZDogYy5pZCwKICAgICAgICAgIGV4cDogYy5leHBpcnlUaW1lfHwwLCB0b3RhbDogYy50b3RhbEdCfHwwLAogICAgICAgICAgdXA6IGliLnVwfHwwLCBkb3duOiBpYi5kb3dufHwwLCBsaW1pdElwOiBjLmxpbWl0SXB8fDAKICAgICAgICB9KTsKICAgICAgfSk7CiAgICB9KTsKICAgIHJlbmRlclVzZXJzKF9hbGxVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyVXNlcnModXNlcnMpIHsKICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfk608L2Rpdj48cD7guYTguKHguYjguJ7guJrguKLguLnguKrguYDguIvguK3guKPguYw8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHUgPT4gewogICAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgICBsZXQgYmFkZ2UsIGNsczsKICAgIGlmICghdS5leHAgfHwgdS5leHA9PT0wKSB7IGJhZGdlPSfinJMg4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsgY2xzPSdvayc7IH0KICAgIGVsc2UgaWYgKGRsIDwgMCkgICAgICAgICB7IGJhZGdlPSfguKvguKHguJTguK3guLLguKLguLgnOyBjbHM9J2V4cCc7IH0KICAgIGVsc2UgaWYgKGRsIDw9IDMpICAgICAgICB7IGJhZGdlPSfimqAgJytkbCsnZCc7IGNscz0nc29vbic7IH0KICAgIGVsc2UgICAgICAgICAgICAgICAgICAgICB7IGJhZGdlPSfinJMgJytkbCsnZCc7IGNscz0nb2snOyB9CiAgICBjb25zdCBhdkNscyA9IGRsIDwgMCA/ICdhdi14JyA6ICdhdi1nJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIG9uY2xpY2s9Im9wZW5Vc2VyKCR7SlNPTi5zdHJpbmdpZnkodSkucmVwbGFjZSgvIi9nLCcmcXVvdDsnKX0pIj4KICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YXZDbHN9Ij4keyh1LmVtYWlsfHwnPycpWzBdLnRvVXBwZXJDYXNlKCl9PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS5lbWFpbH08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+UG9ydCAke3UucG9ydH0gwrcgJHtmbXRCeXRlcyh1LnVwK3UuZG93bil9IOC5g+C4iuC5iTwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHtjbHN9Ij4ke2JhZGdlfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsdGVyVXNlcnMocSkgewogIHJlbmRlclVzZXJzKF9hbGxVc2Vycy5maWx0ZXIodT0+KHUuZW1haWx8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSkpKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1PREFMIFVTRVIg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIG9wZW5Vc2VyKHUpIHsKICBpZiAodHlwZW9mIHUgPT09ICdzdHJpbmcnKSB1ID0gSlNPTi5wYXJzZSh1KTsKICBfY3VyVXNlciA9IHU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ210JykudGV4dENvbnRlbnQgPSAn4pqZ77iPICcrdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHUnKS50ZXh0Q29udGVudCA9IHUuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RwJykudGV4dENvbnRlbnQgPSB1LnBvcnQ7CiAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgY29uc3QgZXhwVHh0ID0gIXUuZXhwfHx1LmV4cD09PTAgPyAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJyA6IGZtdERhdGUodS5leHApOwogIGNvbnN0IGRlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RlJyk7CiAgZGUudGV4dENvbnRlbnQgPSBleHBUeHQ7CiAgZGUuY2xhc3NOYW1lID0gJ2R2JyArIChkbCAhPT0gbnVsbCAmJiBkbCA8IDAgPyAnIHJlZCcgOiAnIGdyZWVuJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RkJykudGV4dENvbnRlbnQgPSB1LnRvdGFsID4gMCA/IGZtdEJ5dGVzKHUudG90YWwpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R0cicpLnRleHRDb250ZW50ID0gZm10Qnl0ZXModS51cCt1LmRvd24pOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaScpLnRleHRDb250ZW50ID0gdS5saW1pdElwIHx8ICfiiJ4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdXUnKS50ZXh0Q29udGVudCA9IHUudXVpZDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY20oKXsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOyB9Cgphc3luYyBmdW5jdGlvbiByZW5ld1VzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChwcm9tcHQoJ+C4leC5iOC4reC4reC4suC4ouC4uOC4geC4teC5iOC4p+C4seC4mT8nLCczMCcpKTsKICBpZiAoIWRheXMgfHwgZGF5cyA8PSAwKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IGV4cE1zID0gRGF0ZS5ub3coKSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6IF9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDpfY3VyVXNlci51dWlkLCBmbG93OicnLCBlbWFpbDpfY3VyVXNlci5lbWFpbCwKICAgICAgICBsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsIHRvdGFsR0I6X2N1clVzZXIudG90YWwsCiAgICAgICAgZXhwaXJ5VGltZTpleHBNcywgZW5hYmxlOnRydWUsIHRnSWQ6JycsIHN1YklkOicnLCBjb21tZW50OicnLCByZXNldDowCiAgICAgIH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4LmI4Lit4Lit4Liy4Lii4Li44Liq4Liz4LmA4Lij4LmH4LiIICcrZGF5cysnIOC4p+C4seC4mScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxNTAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gcmVzZXRUcmFmZmljKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBpZiAoIWNvbmZpcm0oJ+C4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4guC4reC4hyAnK19jdXJVc2VyLmVtYWlsKycgPycpKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9yZXNldENsaWVudFRyYWZmaWMvJytfY3VyVXNlci5lbWFpbCk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTUwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRlbGV0ZVVzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGlmICghY29uZmlybSgn4Lil4Lia4Lii4Li54LiqICcrX2N1clVzZXIuZW1haWwrJyDguJbguLLguKfguKM/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL2RlbENsaWVudC8nK19jdXJVc2VyLnV1aWQpOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4Lil4Lia4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDEwMDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQp9CgovLyDilZDilZDilZDilZAgT05MSU5FIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkT25saW5lKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICBjb25zdCBvZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9vbmxpbmVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgY29uc3QgZW1haWxzID0gKG9kICYmIG9kLm9iaikgPyBvZC5vYmogOiBbXTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YXYgYXYtZyI+8J+fojwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHtlbWFpbH08L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVtIj4ke3UgPyAnUG9ydCAnK3UucG9ydCA6ICdWTEVTUyd9IMK3IOC4reC4reC4meC5hOC4peC4meC5jOC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIG9rIj5PTkxJTkU8L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBVU0VSUyAoYmFuIHRhYikg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCB1c2VycyA9IGQudXNlcnMgfHwgW107CiAgICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvcD48L2Rpdj4nOyByZXR1cm47IH0KICAgIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHU9PnsKICAgICAgY29uc3QgZXhwID0gdS5leHAgfHwgJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICAgIGNvbnN0IGFjdGl2ZSA9IHUuYWN0aXZlICE9PSBmYWxzZTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YWN0aXZlPydhdi1nJzonYXYteCd9Ij4ke3UudXNlclswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LnVzZXJ9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+4Lir4Lih4LiU4Lit4Liy4Lii4Li4OiAke2V4cH08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2FjdGl2ZT8nb2snOidleHAnfSI+JHthY3RpdmU/J0FjdGl2ZSc6J0V4cGlyZWQnfTwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsZXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZS50cmltKCk7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciID8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSl9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3J8fCfguKXguJrguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVXNlcnMoKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBDT1BZIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBjb3B5TGluayhpZCwgYnRuKSB7CiAgY29uc3QgdHh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHR4dCkudGhlbigoKT0+ewogICAgY29uc3Qgb3JpZyA9IGJ0bi50ZXh0Q29udGVudDsKICAgIGJ0bi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0ncmdiYSgzNCwxOTcsOTQsLjE1KSc7CiAgICBzZXRUaW1lb3V0KCgpPT57IGJ0bi50ZXh0Q29udGVudD1vcmlnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0nJzsgfSwgMjAwMCk7CiAgfSkuY2F0Y2goKCk9PnsgcHJvbXB0KCdDb3B5IGxpbms6JywgdHh0KTsgfSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBMT0dPVVQg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGRvTG9nb3V0KCkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIElOSVQg4pWQ4pWQ4pWQ4pWQCmxvYWREYXNoKCk7CmxvYWRTZXJ2aWNlcygpOwpzZXRJbnRlcnZhbChsb2FkRGFzaCwgMzAwMDApOwo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==' | base64 -d > /opt/chaiya-panel/sshws.html
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
echo -e "  🖥  3x-ui Panel : ${CYAN}${BOLD}https://${DOMAIN}/xui-api/panel/${NC}"
echo -e "  🐻 Dropbear    : ${CYAN}port 143, 109${NC}"
echo -e "  🌐 WS-Tunnel   : ${CYAN}port 80 → Dropbear:143${NC}"
echo -e "  🎮 BadVPN UDPGW: ${CYAN}port 7300${NC}"
echo -e "  📡 VMess-WS    : ${CYAN}port 8080, path /vmess${NC}"
echo -e "  📡 VLESS-WS    : ${CYAN}port 8880, path /vless${NC}"
echo ""
echo -e "  💡 พิมพ์ ${CYAN}menu${NC} เพื่อดูรายละเอียด"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
