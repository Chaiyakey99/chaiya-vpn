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
echo '' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOwogICAgLS1hYy1nbG93OiByZ2JhKDM0LDE5Nyw5NCwwLjI1KTsKICAgIC0tYWMtZGltOiByZ2JhKDM0LDE5Nyw5NCwwLjA4KTsKICAgIC0tYWMtYm9yZGVyOiByZ2JhKDM0LDE5Nyw5NCwwLjI1KTsKICAgIC0tbmc6ICMyMmM1NWU7CiAgICAtLW5nLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMik7CiAgICAtLWJnOiAjZjBmMmY1OwogICAgLS1jYXJkOiAjZmZmZmZmOwogICAgLS10eHQ6ICMxZTI5M2I7CiAgICAtLW11dGVkOiAjNjQ3NDhiOwogICAgLS1ib3JkZXI6ICNlMmU4ZjA7CiAgICAtLXNoYWRvdzogMCAycHggMTJweCByZ2JhKDAsMCwwLDAuMDcpOwogIH0KICAqIHsgbWFyZ2luOjA7IHBhZGRpbmc6MDsgYm94LXNpemluZzpib3JkZXItYm94OyB9CiAgYm9keSB7IGJhY2tncm91bmQ6dmFyKC0tYmcpOyBmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjsgY29sb3I6dmFyKC0tdHh0KTsgbWluLWhlaWdodDoxMDB2aDsgb3ZlcmZsb3cteDpoaWRkZW47IH0KICAud3JhcCB7IG1heC13aWR0aDo0ODBweDsgbWFyZ2luOjAgYXV0bzsgcGFkZGluZy1ib3R0b206NTBweDsgcG9zaXRpb246cmVsYXRpdmU7IHotaW5kZXg6MTsgfQoKICAvKiBIRUFERVIg4oCUIGRhcmssIHB1cnBsZSBvbmx5IG9uIENSRUFUT1IgKi8KICAuaGRyIHsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxNjBkZWcsIzFhMGEyZSAwJSwjMGYwYTFlIDU1JSwjMGEwYTBmIDEwMCUpOwogICAgcGFkZGluZzoyOHB4IDIwcHggMjJweDsgdGV4dC1hbGlnbjpjZW50ZXI7IHBvc2l0aW9uOnJlbGF0aXZlOyBvdmVyZmxvdzpoaWRkZW47CiAgfQogIC5oZHI6OmFmdGVyIHsgY29udGVudDonJzsgcG9zaXRpb246YWJzb2x1dGU7IGJvdHRvbTowOyBsZWZ0OjA7IHJpZ2h0OjA7IGhlaWdodDoxcHg7CiAgICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCxyZ2JhKDE5MiwxMzIsMjUyLDAuNiksdHJhbnNwYXJlbnQpOyB9CiAgLmhkci1zdWIgeyBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOjlweDsgbGV0dGVyLXNwYWNpbmc6NHB4OyBjb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLDAuNyk7IG1hcmdpbi1ib3R0b206NnB4OyB9CiAgLmhkci10aXRsZSB7IGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyBmb250LXNpemU6MjZweDsgZm9udC13ZWlnaHQ6OTAwOyBjb2xvcjojZmZmOyBsZXR0ZXItc3BhY2luZzoycHg7IH0KICAuaGRyLXRpdGxlIHNwYW4geyBjb2xvcjojYzA4NGZjOyB9CiAgLmhkci1kZXNjIHsgbWFyZ2luLXRvcDo2cHg7IGZvbnQtc2l6ZToxMXB4OyBjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNDUpOyBsZXR0ZXItc3BhY2luZzoycHg7IH0KICAubG9nb3V0IHsgcG9zaXRpb246YWJzb2x1dGU7IHRvcDoxNnB4OyByaWdodDoxNHB4OyBiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7CiAgICBib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4xNSk7IGJvcmRlci1yYWRpdXM6OHB4OyBwYWRkaW5nOjVweCAxMnB4OwogICAgZm9udC1zaXplOjExcHg7IGNvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC42KTsgY3Vyc29yOnBvaW50ZXI7IGZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyB9CgogIC8qIE5BViDigJQgd2hpdGUgYmFyLCBncmVlbiBhY3RpdmUgKi8KICAubmF2IHsgYmFja2dyb3VuZDojZmZmOyBkaXNwbGF5OmZsZXg7IGJvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgICBvdmVyZmxvdy14OmF1dG87IHNjcm9sbGJhci13aWR0aDpub25lOyBwb3NpdGlvbjpzdGlja3k7IHRvcDowOyB6LWluZGV4OjEwOwogICAgYm94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTsgfQogIC5uYXY6Oi13ZWJraXQtc2Nyb2xsYmFyIHsgZGlzcGxheTpub25lOyB9CiAgLm5hdi1pdGVtIHsgZmxleDoxOyBwYWRkaW5nOjEzcHggNnB4OyBmb250LXNpemU6MTFweDsgZm9udC13ZWlnaHQ6NjAwOyBjb2xvcjp2YXIoLS1tdXRlZCk7CiAgICB0ZXh0LWFsaWduOmNlbnRlcjsgY3Vyc29yOnBvaW50ZXI7IHdoaXRlLXNwYWNlOm5vd3JhcDsgYm9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICB0cmFuc2l0aW9uOmFsbCAuMnM7IH0KICAubmF2LWl0ZW0uYWN0aXZlIHsgY29sb3I6dmFyKC0tYWMpOyBib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTsgYmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pOyB9CgogIC8qIFNFQ1RJT05TICovCiAgLnNlYyB7IHBhZGRpbmc6MTRweDsgZGlzcGxheTpub25lOyBhbmltYXRpb246ZmkgLjNzIGVhc2U7IH0KICAuc2VjLmFjdGl2ZSB7IGRpc3BsYXk6YmxvY2s7IH0KICBAa2V5ZnJhbWVzIGZpIHsgZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX0gdG97b3BhY2l0eToxO3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfSB9CgogIC8qIENBUkRTICovCiAgLmNhcmQgewogICAgYmFja2dyb3VuZDp2YXIoLS1jYXJkKTsKICAgIGJvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTsgYm9yZGVyLXJhZGl1czoxNHB4OyBwYWRkaW5nOjE2cHg7CiAgICBtYXJnaW4tYm90dG9tOjEwcHg7IHBvc2l0aW9uOnJlbGF0aXZlOyBvdmVyZmxvdzpoaWRkZW47CiAgICBib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7CiAgfQoKICAuc2VjLWhkciB7IGRpc3BsYXk6ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjsgbWFyZ2luLWJvdHRvbToxMnB4OyB9CiAgLnNlYy10aXRsZSB7IGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyBmb250LXNpemU6MTBweDsgbGV0dGVyLXNwYWNpbmc6M3B4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IH0KICAuYnRuLXIgeyBiYWNrZ3JvdW5kOiNmOGZhZmM7IGJvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTsgYm9yZGVyLXJhZGl1czo4cHg7CiAgICBwYWRkaW5nOjZweCAxNHB4OyBmb250LXNpemU6MTFweDsgY29sb3I6dmFyKC0tbXV0ZWQpOyBjdXJzb3I6cG9pbnRlcjsKICAgIGZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyB0cmFuc2l0aW9uOmFsbCAuMnM7IH0KICAuYnRuLXI6aG92ZXIgeyBib3JkZXItY29sb3I6dmFyKC0tYWMpOyBjb2xvcjp2YXIoLS1hYyk7IH0KCiAgLyogU1RBVCBHUklEICovCiAgLnNncmlkIHsgZGlzcGxheTpncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjsgZ2FwOjEwcHg7IG1hcmdpbi1ib3R0b206MTBweDsgfQogIC5zYyB7IGJhY2tncm91bmQ6dmFyKC0tY2FyZCk7CiAgICBib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7IGJvcmRlci1yYWRpdXM6MTRweDsgcGFkZGluZzoxNHB4OwogICAgcG9zaXRpb246cmVsYXRpdmU7IG92ZXJmbG93OmhpZGRlbjsgYm94LXNoYWRvdzp2YXIoLS1zaGFkb3cpOyB9CiAgLnNsYmwgeyBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOjhweDsgbGV0dGVyLXNwYWNpbmc6MnB4OwogICAgY29sb3I6dmFyKC0tbXV0ZWQpOyBtYXJnaW4tYm90dG9tOjhweDsgfQogIC5zdmFsIHsgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IGZvbnQtc2l6ZToyNHB4OyBmb250LXdlaWdodDo3MDA7IGNvbG9yOnZhcigtLXR4dCk7IGxpbmUtaGVpZ2h0OjE7IH0KICAuc3ZhbCBzcGFuIHsgZm9udC1zaXplOjEycHg7IGNvbG9yOnZhcigtLW11dGVkKTsgZm9udC13ZWlnaHQ6NDAwOyB9CiAgLnNzdWIgeyBmb250LXNpemU6MTBweDsgY29sb3I6dmFyKC0tbXV0ZWQpOyBtYXJnaW4tdG9wOjRweDsgfQoKICAvKiBEb251dCAqLwogIC5kbnV0IHsgcG9zaXRpb246cmVsYXRpdmU7IHdpZHRoOjUycHg7IGhlaWdodDo1MnB4OyBtYXJnaW46NHB4IGF1dG8gNHB4OyB9CiAgLmRudXQgc3ZnIHsgdHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpOyB9CiAgLmRiZyB7IGZpbGw6bm9uZTsgc3Ryb2tlOnJnYmEoMCwwLDAsMC4wNik7IHN0cm9rZS13aWR0aDo0OyB9CiAgLmR2ICB7IGZpbGw6bm9uZTsgc3Ryb2tlLXdpZHRoOjQ7IHN0cm9rZS1saW5lY2FwOnJvdW5kOyB9CiAgLmRjICB7IHBvc2l0aW9uOmFic29sdXRlOyBpbnNldDowOyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsganVzdGlmeS1jb250ZW50OmNlbnRlcjsKICAgIGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyBmb250LXNpemU6MTJweDsgZm9udC13ZWlnaHQ6NzAwOyBjb2xvcjp2YXIoLS10eHQpOyB9CgogIC8qIFByb2cgYmFycyAqLwogIC5wYiB7IGhlaWdodDo0cHg7IGJhY2tncm91bmQ6cmdiYSgwLDAsMCwwLjA2KTsgYm9yZGVyLXJhZGl1czoycHg7IG1hcmdpbi10b3A6OHB4OyBvdmVyZmxvdzpoaWRkZW47IH0KICAucGYgeyBoZWlnaHQ6MTAwJTsgYm9yZGVyLXJhZGl1czoycHg7IH0KICAucGYucHUgeyBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1hYyksIzE2YTM0YSk7IH0KICAucGYucGcgeyBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1uZyksIzE2YTM0YSk7IH0KICAucGYucG8geyBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZmI5MjNjLCNmOTczMTYpOyB9CgogIC51YmRnIHsgZGlzcGxheTpmbGV4OyBnYXA6NXB4OyBmbGV4LXdyYXA6d3JhcDsgbWFyZ2luLXRvcDo4cHg7IH0KICAuYmRnIHsgYmFja2dyb3VuZDojZjFmNWY5OyBib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgICBib3JkZXItcmFkaXVzOjZweDsgcGFkZGluZzozcHggOHB4OyBmb250LXNpemU6MTBweDsgY29sb3I6dmFyKC0tbXV0ZWQpOwogICAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IH0KCiAgLyogTmV0d29yayAqLwogIC5uZXQtcm93IHsgZGlzcGxheTpmbGV4OyBqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjsgZ2FwOjEycHg7IG1hcmdpbi10b3A6MTBweDsgfQogIC5uaSB7IGZsZXg6MTsgfQogIC5uZCB7IGZvbnQtc2l6ZToxMXB4OyBjb2xvcjp2YXIoLS1hYyk7IG1hcmdpbi1ib3R0b206M3B4OyB9CiAgLm5zIHsgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IGZvbnQtc2l6ZToyMHB4OyBmb250LXdlaWdodDo3MDA7IGNvbG9yOnZhcigtLXR4dCk7IH0KICAubnMgc3BhbiB7IGZvbnQtc2l6ZToxMXB4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IGZvbnQtd2VpZ2h0OjQwMDsgfQogIC5udCB7IGZvbnQtc2l6ZToxMHB4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IG1hcmdpbi10b3A6MnB4OyB9CiAgLmRpdmlkZXIgeyB3aWR0aDoxcHg7IGJhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTsgbWFyZ2luOjRweCAwOyB9CgogIC8qIE9ubGluZSBwaWxsICovCiAgLm9waWxsIHsgYmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpOyBib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMyk7CiAgICBib3JkZXItcmFkaXVzOjIwcHg7IHBhZGRpbmc6NXB4IDE0cHg7IGZvbnQtc2l6ZToxMnB4OyBjb2xvcjp2YXIoLS1uZyk7CiAgICBkaXNwbGF5OmlubGluZS1mbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IGdhcDo1cHg7IHdoaXRlLXNwYWNlOm5vd3JhcDsgfQogIC5kb3QgeyB3aWR0aDo3cHg7IGhlaWdodDo3cHg7IGJvcmRlci1yYWRpdXM6NTAlOyBiYWNrZ3JvdW5kOnZhcigtLW5nKTsgYm94LXNoYWRvdzowIDAgNnB4IHZhcigtLW5nKTsKICAgIGFuaW1hdGlvbjpwbHMgMS41cyBpbmZpbml0ZTsgfQogIEBrZXlmcmFtZXMgcGxzIHsgMCUsMTAwJXtib3gtc2hhZG93OjAgMCA0cHggdmFyKC0tbmcpfSA1MCV7Ym94LXNoYWRvdzowIDAgMTBweCB2YXIoLS1uZyksMCAwIDIwcHggcmdiYSgzNCwxOTcsOTQsLjMpfSB9CiAgLnh1aS1yb3cgeyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOjEycHg7IG1hcmdpbi10b3A6MTBweDsgfQogIC54dWktaW5mbyB7IGZvbnQtc2l6ZToxMnB4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IGxpbmUtaGVpZ2h0OjEuNzsgfQogIC54dWktaW5mbyBiIHsgY29sb3I6dmFyKC0tdHh0KTsgfQoKICAvKiBTZXJ2aWNlcyAqLwogIC5zdmMtbGlzdCB7IGRpc3BsYXk6ZmxleDsgZmxleC1kaXJlY3Rpb246Y29sdW1uOyBnYXA6OHB4OyBtYXJnaW4tdG9wOjEwcHg7IH0KICAuc3ZjIHsgYmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjA1KTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjIpOwogICAgYm9yZGVyLXJhZGl1czoxMHB4OyBwYWRkaW5nOjExcHggMTRweDsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IGp1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuOyB9CiAgLnN2Yy1sIHsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IGdhcDoxMHB4OyB9CiAgLmRnIHsgd2lkdGg6OHB4OyBoZWlnaHQ6OHB4OyBib3JkZXItcmFkaXVzOjUwJTsgYmFja2dyb3VuZDp2YXIoLS1uZyk7IGJveC1zaGFkb3c6MCAwIDZweCB2YXIoLS1uZyk7IGZsZXgtc2hyaW5rOjA7IH0KICAuc3ZjLW4geyBmb250LXNpemU6MTNweDsgZm9udC13ZWlnaHQ6NjAwOyBjb2xvcjp2YXIoLS10eHQpOyB9CiAgLnN2Yy1wIHsgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IGZvbnQtc2l6ZToxMHB4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IH0KICAucmJkZyB7IGJhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpOwogICAgYm9yZGVyLXJhZGl1czo2cHg7IHBhZGRpbmc6M3B4IDEwcHg7IGZvbnQtc2l6ZToxMHB4OyBjb2xvcjp2YXIoLS1uZyk7CiAgICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgbGV0dGVyLXNwYWNpbmc6MXB4OyB9CiAgLmx1IHsgdGV4dC1hbGlnbjpjZW50ZXI7IGZvbnQtc2l6ZToxMHB4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IG1hcmdpbi10b3A6MTRweDsKICAgIGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyBsZXR0ZXItc3BhY2luZzoxcHg7IH0KCiAgLyogRk9STSAqLwogIC5mdGl0bGUgeyBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOjExcHg7IGxldHRlci1zcGFjaW5nOjJweDsKICAgIGNvbG9yOnZhcigtLW11dGVkKTsgbWFyZ2luLWJvdHRvbToxNHB4OyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOjhweDsgfQogIC5pbmZvLWJveCB7IGJhY2tncm91bmQ6I2Y4ZmFmYzsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgYm9yZGVyLXJhZGl1czo4cHg7IHBhZGRpbmc6OHB4IDEycHg7IGZvbnQtc2l6ZToxMXB4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IG1hcmdpbi1ib3R0b206MTRweDsgfQogIC5wdGdsIHsgZGlzcGxheTpmbGV4OyBnYXA6OHB4OyBtYXJnaW4tYm90dG9tOjE0cHg7IH0KICAucGJ0biB7IGZsZXg6MTsgcGFkZGluZzo5cHg7IGJvcmRlci1yYWRpdXM6OHB4OyBmb250LXNpemU6MTJweDsgY3Vyc29yOnBvaW50ZXI7CiAgICBib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7IGJhY2tncm91bmQ6I2Y4ZmFmYzsgY29sb3I6dmFyKC0tbXV0ZWQpOwogICAgZm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7IHRyYW5zaXRpb246YWxsIC4yczsgfQogIC5wYnRuLmFjdGl2ZSB7IGJhY2tncm91bmQ6dmFyKC0tYWMtZGltKTsgYm9yZGVyLWNvbG9yOnZhcigtLWFjKTsgY29sb3I6dmFyKC0tYWMpOyB9CiAgLmZnIHsgbWFyZ2luLWJvdHRvbToxMnB4OyB9CiAgLmZsYmwgeyBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOjhweDsgbGV0dGVyLXNwYWNpbmc6MnB4OwogICAgY29sb3I6dmFyKC0tbXV0ZWQpOyBvcGFjaXR5Oi44OyBtYXJnaW4tYm90dG9tOjVweDsgfQogIC5maSB7IHdpZHRoOjEwMCU7IGJhY2tncm91bmQ6I2Y4ZmFmYzsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgYm9yZGVyLXJhZGl1czo5cHg7IHBhZGRpbmc6MTBweCAxNHB4OyBmb250LXNpemU6MTNweDsgY29sb3I6dmFyKC0tdHh0KTsKICAgIGZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyBvdXRsaW5lOm5vbmU7IHRyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczsgfQogIC5maTpmb2N1cyB7IGJvcmRlci1jb2xvcjp2YXIoLS1hYyk7IGJveC1zaGFkb3c6MCAwIDAgM3B4IHZhcigtLWFjLWRpbSk7IH0KICAudGdsIHsgZGlzcGxheTpmbGV4OyBnYXA6OHB4OyB9CiAgLnRidG4geyBmbGV4OjE7IHBhZGRpbmc6OXB4OyBib3JkZXItcmFkaXVzOjhweDsgZm9udC1zaXplOjEycHg7IGN1cnNvcjpwb2ludGVyOwogICAgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyBiYWNrZ3JvdW5kOiNmOGZhZmM7CiAgICBjb2xvcjp2YXIoLS1tdXRlZCk7IGZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyB0cmFuc2l0aW9uOmFsbCAuMnM7IH0KICAudGJ0bi5hY3RpdmUgeyBiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7IGJvcmRlci1jb2xvcjp2YXIoLS1hYyk7IGNvbG9yOnZhcigtLWFjKTsgfQogIC5jYnRuIHsgd2lkdGg6MTAwJTsgcGFkZGluZzoxNHB4OyBib3JkZXItcmFkaXVzOjEwcHg7IGZvbnQtc2l6ZToxNHB4OyBmb250LXdlaWdodDo3MDA7CiAgICBjdXJzb3I6cG9pbnRlcjsgYm9yZGVyOm5vbmU7IGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMTZhMzRhLCMyMmM1NWUsIzRhZGU4MCk7CiAgICBjb2xvcjojZmZmOyBmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjsgbGV0dGVyLXNwYWNpbmc6LjVweDsKICAgIGJveC1zaGFkb3c6MCA0cHggMTVweCByZ2JhKDM0LDE5Nyw5NCwuMyk7CiAgICB0cmFuc2l0aW9uOmFsbCAuMnM7IH0KICAuY2J0bjpob3ZlciB7IGJveC1zaGFkb3c6MCA2cHggMjBweCByZ2JhKDM0LDE5Nyw5NCwuNDUpOyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTsgfQoKICAvKiBNQU5BR0UgKi8KICAuc2JveCB7IHdpZHRoOjEwMCU7IGJhY2tncm91bmQ6I2Y4ZmFmYzsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgYm9yZGVyLXJhZGl1czoxMHB4OyBwYWRkaW5nOjEwcHggMTRweDsgZm9udC1zaXplOjEzcHg7IGNvbG9yOnZhcigtLXR4dCk7CiAgICBmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjsgb3V0bGluZTpub25lOyBtYXJnaW4tYm90dG9tOjEycHg7IHRyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczsgfQogIC5zYm94OmZvY3VzIHsgYm9yZGVyLWNvbG9yOnZhcigtLWFjKTsgfQogIC51aXRlbSB7IGJhY2tncm91bmQ6I2ZmZjsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgYm9yZGVyLXJhZGl1czoxMHB4OyBwYWRkaW5nOjEycHggMTRweDsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjsgbWFyZ2luLWJvdHRvbTo4cHg7IGN1cnNvcjpwb2ludGVyOyB0cmFuc2l0aW9uOmFsbCAuMnM7CiAgICBib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpOyB9CiAgLnVpdGVtOmhvdmVyIHsgYm9yZGVyLWNvbG9yOnZhcigtLWFjKTsgYmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pOyB9CiAgLnVhdiB7IHdpZHRoOjM2cHg7IGhlaWdodDozNnB4OyBib3JkZXItcmFkaXVzOjlweDsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyOyBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOjE0cHg7IGZvbnQtd2VpZ2h0OjcwMDsKICAgIG1hcmdpbi1yaWdodDoxMnB4OyBmbGV4LXNocmluazowOyB9CiAgLmF2LWcgeyBiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMTUpOyBjb2xvcjp2YXIoLS1uZyk7IGJvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpOyB9CiAgLmF2LXAgeyBiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMTUpOyBjb2xvcjp2YXIoLS1uZyk7IGJvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpOyB9CiAgLmF2LXIgeyBiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7IGNvbG9yOiNmODcxNzE7IGJvcmRlcjoxcHggc29saWQgcmdiYSgyNDgsMTEzLDExMywuMik7IH0KICAudW4geyBmb250LXNpemU6MTNweDsgZm9udC13ZWlnaHQ6NjAwOyBjb2xvcjp2YXIoLS10eHQpOyB9CiAgLnVtIHsgZm9udC1zaXplOjExcHg7IGNvbG9yOnZhcigtLW11dGVkKTsgbWFyZ2luLXRvcDoycHg7IH0KICAuYWJkZyB7IGJhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMyk7CiAgICBib3JkZXItcmFkaXVzOjZweDsgcGFkZGluZzozcHggMTBweDsgZm9udC1zaXplOjEwcHg7IGNvbG9yOnZhcigtLW5nKTsgfQoKICAvKiBNT0RBTCAqLwogIC5tb3ZlciB7IHBvc2l0aW9uOmZpeGVkOyBpbnNldDowOyBiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjUpOyBiYWNrZHJvcC1maWx0ZXI6Ymx1cig2cHgpOwogICAgei1pbmRleDoxMDA7IGRpc3BsYXk6bm9uZTsgYWxpZ24taXRlbXM6ZmxleC1lbmQ7IGp1c3RpZnktY29udGVudDpjZW50ZXI7IH0KICAubW92ZXIub3BlbiB7IGRpc3BsYXk6ZmxleDsgfQogIC5tb2RhbCB7IGJhY2tncm91bmQ6I2ZmZjsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgYm9yZGVyLXJhZGl1czoyMHB4IDIwcHggMCAwOyB3aWR0aDoxMDAlOyBtYXgtd2lkdGg6NDgwcHg7IHBhZGRpbmc6MjBweDsKICAgIG1heC1oZWlnaHQ6ODV2aDsgb3ZlcmZsb3cteTphdXRvOyBhbmltYXRpb246c3UgLjNzIGVhc2U7CiAgICBib3gtc2hhZG93OjAgLTRweCAzMHB4IHJnYmEoMCwwLDAsMC4xMik7IH0KICBAa2V5ZnJhbWVzIHN1IHsgZnJvbXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgxMDAlKX0gdG97dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9IH0KICAubWhkciB7IGRpc3BsYXk6ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjsgbWFyZ2luLWJvdHRvbToxNnB4OyB9CiAgLm10aXRsZSB7IGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyBmb250LXNpemU6MTRweDsgY29sb3I6dmFyKC0tdHh0KTsgfQogIC5tY2xvc2UgeyB3aWR0aDozMnB4OyBoZWlnaHQ6MzJweDsgYm9yZGVyLXJhZGl1czo1MCU7IGJhY2tncm91bmQ6I2YxZjVmOTsKICAgIGJvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTsgY29sb3I6dmFyKC0tbXV0ZWQpOyBjdXJzb3I6cG9pbnRlcjsKICAgIGZvbnQtc2l6ZToxNnB4OyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsganVzdGlmeS1jb250ZW50OmNlbnRlcjsgfQogIC5kZ3JpZCB7IGJhY2tncm91bmQ6I2Y4ZmFmYzsgYm9yZGVyLXJhZGl1czoxMHB4OyBwYWRkaW5nOjE0cHg7IG1hcmdpbi1ib3R0b206MTRweDsKICAgIGJvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTsgfQogIC5kciB7IGRpc3BsYXk6ZmxleDsganVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47IGFsaWduLWl0ZW1zOmNlbnRlcjsKICAgIHBhZGRpbmc6N3B4IDA7IGJvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7IH0KICAuZHI6bGFzdC1jaGlsZCB7IGJvcmRlci1ib3R0b206bm9uZTsgfQogIC5kayB7IGZvbnQtc2l6ZToxMnB4OyBjb2xvcjp2YXIoLS1tdXRlZCk7IH0KICAuZHYgeyBmb250LXNpemU6MTJweDsgY29sb3I6dmFyKC0tdHh0KTsgZm9udC13ZWlnaHQ6NjAwOyB9CiAgLmR2LmdyZWVuIHsgY29sb3I6dmFyKC0tbmcpOyB9CiAgLmR2Lm1vbm8geyBjb2xvcjp2YXIoLS1hYyk7IGZvbnQtc2l6ZTo5cHg7IGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyB3b3JkLWJyZWFrOmJyZWFrLWFsbDsgfQogIC5hZ3JpZCB7IGRpc3BsYXk6Z3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7IGdhcDo4cHg7IH0KICAuYWJ0biB7IGJhY2tncm91bmQ6I2Y4ZmFmYzsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogICAgYm9yZGVyLXJhZGl1czoxMHB4OyBwYWRkaW5nOjE0cHggMTBweDsgdGV4dC1hbGlnbjpjZW50ZXI7IGN1cnNvcjpwb2ludGVyOyB0cmFuc2l0aW9uOmFsbCAuMnM7IH0KICAuYWJ0bjpob3ZlciB7IGJhY2tncm91bmQ6dmFyKC0tYWMtZGltKTsgYm9yZGVyLWNvbG9yOnZhcigtLWFjKTsgfQogIC5hYnRuIC5haSB7IGZvbnQtc2l6ZToyMnB4OyBtYXJnaW4tYm90dG9tOjZweDsgfQogIC5hYnRuIC5hbiB7IGZvbnQtc2l6ZToxMnB4OyBmb250LXdlaWdodDo2MDA7IGNvbG9yOnZhcigtLXR4dCk7IH0KICAuYWJ0biAuYWQgeyBmb250LXNpemU6MTBweDsgY29sb3I6dmFyKC0tbXV0ZWQpOyBtYXJnaW4tdG9wOjJweDsgfQogIC5hYnRuLmRhbmdlcjpob3ZlciB7IGJhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7IGJvcmRlci1jb2xvcjojZjg3MTcxOyB9CgogIC8qIE9OTElORSAqLwogIC5vZSB7IHRleHQtYWxpZ246Y2VudGVyOyBwYWRkaW5nOjQwcHggMjBweDsgfQogIC5vZSAuZWkgeyBmb250LXNpemU6NDhweDsgbWFyZ2luLWJvdHRvbToxMnB4OyB9CiAgLm9lIHAgeyBjb2xvcjp2YXIoLS1tdXRlZCk7IGZvbnQtc2l6ZToxM3B4OyB9CiAgLm9jciB7IGRpc3BsYXk6ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyBnYXA6MTBweDsgbWFyZ2luLWJvdHRvbToxNnB4OyB9CiAgLnV0IHsgZm9udC1zaXplOjEwcHg7IGNvbG9yOnZhcigtLW11dGVkKTsgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IH0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gSEVBREVSIC0tPgogIDxkaXYgY2xhc3M9ImhkciI+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiPuKGqSDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KICAgIDxkaXYgY2xhc3M9Imhkci1zdWIiPkNIQUlZQSBWMlJBWSBQUk8gTUFYPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJoZHItdGl0bGUiPlVTRVIgPHNwYW4+Q1JFQVRPUjwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imhkci1kZXNjIj7guKrguKPguYnguLLguIfguJrguLHguI3guIrguLUgVkxFU1MgwrcgU1NILVdTIOC4nOC5iOC4suC4meC4q+C4meC5ieC4suC5gOC4p+C5h+C4miDCtyB2ODwvZGl2PgogIDwvZGl2PgoKICA8IS0tIE5BViAtLT4KICA8ZGl2IGNsYXNzPSJuYXYiPgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gYWN0aXZlIiBvbmNsaWNrPSJzdygnZGFzaGJvYXJkJyx0aGlzKSI+8J+TiiDguYHguJTguIrguJrguK3guKPguYzguJQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnY3JlYXRlJyx0aGlzKSI+4p6VIOC4quC4o+C5ieC4suC4h+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdtYW5hZ2UnLHRoaXMpIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdvbmxpbmUnLHRoaXMpIj7wn5+iIOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdiYW4nLHRoaXMpIj7wn5qrIOC4m+C4peC4lOC5geC4muC4mTwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBEQVNIQk9BUkQg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyBhY3RpdmUiIGlkPSJ0YWItZGFzaGJvYXJkIj4KICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICA8c3BhbiBjbGFzcz0ic2VjLXRpdGxlIj7imqEgU1lTVEVNIE1PTklUT1I8L3NwYW4+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJ0aGlzLnRleHRDb250ZW50PSfihrsgLi4uJztzZXRUaW1lb3V0KCgpPT50aGlzLnRleHRDb250ZW50PSfihrsg4Lij4Li14LmA4Lif4Lij4LiKJyw5MDApIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDwhLS0gQ1BVIC0tPgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4pqhIENQVSBVU0FHRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRudXQiPgogICAgICAgICAgPHN2ZyB3aWR0aD0iNTIiIGhlaWdodD0iNTIiIHZpZXdCb3g9IjAgMCA1MiA1MiI+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImRiZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIi8+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImR2IiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzRhZGU4MCIKICAgICAgICAgICAgICBzdHlsZT0iZmlsdGVyOmRyb3Atc2hhZG93KDAgMCAzcHggIzRhZGU4MCkiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzYuOCIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyI+MSU8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCkiPjIgY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIHN0eWxlPSJ3aWR0aDoxJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8IS0tIFJBTSAtLT4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIgc3Ryb2tlPSIjM2I4MmY2IgogICAgICAgICAgICAgIHN0eWxlPSJmaWx0ZXI6ZHJvcC1zaGFkb3coMCAwIDNweCAjM2I4MmY2KSIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjExOC44Ii8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIj4xNCU8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCkiPjAuNSAvIDMuOCBHQjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwdSIgc3R5bGU9IndpZHRoOjE0JTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjM2I4MmY2LCM2MGE1ZmEpIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDwhLS0gRElTSyAtLT4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfkr4gRElTSyBVU0FHRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiPjIyPHNwYW4+JTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIj44IC8gMzYgR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcG8iIHN0eWxlPSJ3aWR0aDoyMiUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPCEtLSBVUFRJTUUgLS0+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7ij7EgVVBUSU1FPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgc3R5bGU9ImZvbnQtc2l6ZToyMHB4Ij4xZCAxMWg8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIj4xIOC4p+C4seC4mSAxMSDguIrguKEuIDQwIOC4meC4suC4l+C4tTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InViZGciPgogICAgICAgICAgPHNwYW4gY2xhc3M9ImJkZyI+MW06IDAuMDA8L3NwYW4+CiAgICAgICAgICA8c3BhbiBjbGFzcz0iYmRnIj41bTogMC4wMDwvc3Bhbj4KICAgICAgICAgIDxzcGFuIGNsYXNzPSJiZGciPjE1bTogMC4wMDwvc3Bhbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIE5ldHdvcmsgLS0+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7wn4yQIE5FVFdPUksgSS9PPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im5ldC1yb3ciPgogICAgICAgIDxkaXYgY2xhc3M9Im5pIj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5kIj7ihpEgVXBsb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJucyI+MzkuNDxzcGFuPiBLQi9zPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiPnRvdGFsOiAxLjcgR0I8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiPjI2LjM8c3Bhbj4gS0Ivczwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50Ij50b3RhbDogMi4xIEdCPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBYLVVJIC0tPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+ToSBYLVVJIFBBTkVMIFNUQVRVUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ4dWktcm93Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJvcGlsbCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPuC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Inh1aS1pbmZvIj4KICAgICAgICAgIDxkaXY+4LmA4Lin4Lit4Lij4LmM4LiK4Lix4LiZOiA8Yj4tLTwvYj48L2Rpdj4KICAgICAgICAgIDxkaXY+SW5ib3VuZHM6IDxiPjIg4Lij4Liy4Lii4LiB4Liy4LijPC9iPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU2VydmljZXMgLS0+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7wn5SnIFNFUlZJQ0UgTU9OSVRPUjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIj7ihrsg4LmA4LiK4LmH4LiE4Liq4LiW4Liy4LiZ4LiwPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZjIj48ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnIj48L3NwYW4+PHNwYW4+8J+ToTwvc3Bhbj48ZGl2PjxkaXYgY2xhc3M9InN2Yy1uIj54LXVpIFBhbmVsPC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPjoyMDUzPC9kaXY+PC9kaXY+PC9kaXY+PHNwYW4gY2xhc3M9InJiZGciPlJVTk5JTkc8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZjIj48ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnIj48L3NwYW4+PHNwYW4+8J+QjTwvc3Bhbj48ZGl2PjxkaXYgY2xhc3M9InN2Yy1uIj5QeXRob24gU1NIIEFQSTwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj46MjA5NTwvZGl2PjwvZGl2PjwvZGl2PjxzcGFuIGNsYXNzPSJyYmRnIj5SVU5OSU5HPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YyI+PGRpdiBjbGFzcz0ic3ZjLWwiPjxzcGFuIGNsYXNzPSJkZyI+PC9zcGFuPjxzcGFuPvCfkLs8L3NwYW4+PGRpdj48ZGl2IGNsYXNzPSJzdmMtbiI+RHJvcGJlYXIgU1NIPC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPjoxNDMgOjEwOTwvZGl2PjwvZGl2PjwvZGl2PjxzcGFuIGNsYXNzPSJyYmRnIj5SVU5OSU5HPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YyI+PGRpdiBjbGFzcz0ic3ZjLWwiPjxzcGFuIGNsYXNzPSJkZyI+PC9zcGFuPjxzcGFuPvCfjJA8L3NwYW4+PGRpdj48ZGl2IGNsYXNzPSJzdmMtbiI+bmdpbnggLyBXUzwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj46ODAgOjQ0MzwvZGl2PjwvZGl2PjwvZGl2PjxzcGFuIGNsYXNzPSJyYmRnIj5SVU5OSU5HPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YyI+PGRpdiBjbGFzcz0ic3ZjLWwiPjxzcGFuIGNsYXNzPSJkZyI+PC9zcGFuPjxzcGFuPvCflJI8L3NwYW4+PGRpdj48ZGl2IGNsYXNzPSJzdmMtbiI+U1NILVdTLVNTTDwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj46NDQzPC9kaXY+PC9kaXY+PC9kaXY+PHNwYW4gY2xhc3M9InJiZGciPlJVTk5JTkc8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZjIj48ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnIj48L3NwYW4+PHNwYW4+8J+Orjwvc3Bhbj48ZGl2PjxkaXYgY2xhc3M9InN2Yy1uIj5iYWR2cG4gVURQLUdXPC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPjo3MzAwPC9kaXY+PC9kaXY+PC9kaXY+PHNwYW4gY2xhc3M9InJiZGciPlJVTk5JTkc8L3NwYW4+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJsdSI+4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAwNTo1MDowNzwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBDUkVBVEUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1jcmVhdGUiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+UkiBTU0ggV2ViU29ja2V0PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tYm94Ij7wn5SRIERyb3BiZWFyIDE0My8xMDkgwrcgV1MgUG9ydCA4MCDCtyBOcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZsYmwiPvCfk6EgV1MgUE9SVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJwdGdsIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxNHB4Ij4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJwYnRuIGFjdGl2ZSIgb25jbGljaz0idG9nKHRoaXMsJy5wYnRuJykiPlBvcnQgODAg4oCTIEhUVFAtV1M8L2J1dHRvbj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJwYnRuIiBvbmNsaWNrPSJ0b2codGhpcywnLnBidG4nKSI+UG9ydCA0NDMg4oCTIFdTUyDwn5SSPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBVU0VSTkFNRTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIHZhbHVlPSJjaGFpeWEwMSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5SRIFBBU1NXT1JEPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgdmFsdWU9InBhc3MxMjM0Ij48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIHR5cGU9Im51bWJlciIgdmFsdWU9IjIiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+CiAgICAgICAgPGRpdiBjbGFzcz0iZmxibCI+8J+TsSDguYHguK3guJ4gSU1QT1JUIExJTks8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0Z2wiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0idGJ0biBhY3RpdmUiIG9uY2xpY2s9InRvZyh0aGlzLCcudGJ0bicpIj5OcHZUdW5uZWw8L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InRidG4iIG9uY2xpY2s9InRvZyh0aGlzLCcudGJ0bicpIj5EYXJrVHVubmVsPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTZweCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZmxibCI+8J+MkCBPUEVSQVRPUiAvIFBBWUxPQUQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ0Z2wiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0idGJ0biBhY3RpdmUiIG9uY2xpY2s9InRvZyh0aGlzLCcudGJ0bjInKSIgY2xhc3M9InRidG4yIj5EVEFDIEdBTUlORzwvYnV0dG9uPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0idGJ0biIgb25jbGljaz0idG9nKHRoaXMsJy50YnRuMicpIiBjbGFzcz0idGJ0bjIiPlRSVUUgVFdJVFRFUjwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biI+4pqhIOC4quC4o+C5ieC4suC4hyBTU0ggQWNjb3VudDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW1hbmFnZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4quC5gOC4i+C4reC4o+C5jCBWTEVTUzwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIHBsYWNlaG9sZGVyPSLwn5SNICDguITguYnguJnguKvguLIgdXNlcm5hbWUuLi4iPgogICAgICA8ZGl2IGNsYXNzPSJ1aXRlbSIgb25jbGljaz0ib20oJ2NoYWl5YS1kZWZhdWx0JywnODA4MCcsJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcsJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcsJzInLCcwIC8gMCBNQicsJ2M4MzM2Li4uJykiPgogICAgICAgIDxkaXYgY2xhc3M9InVhdiBhdi1nIj5DPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0iZmxleDoxIj48ZGl2IGNsYXNzPSJ1biI+Y2hhaXlhLWRlZmF1bHQ8L2Rpdj48ZGl2IGNsYXNzPSJ1bSI+UG9ydCA4MDgwIMK3IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lDwvZGl2PjwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIj7inJMgQWN0aXZlPC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0idWl0ZW0iIG9uY2xpY2s9Im9tKCdwb3AnLCc4MDgwJywnMzAg4Lin4Lix4LiZJywnMTkvNS8yNTY5JywnMicsJzAgLyAwIE1CJywnYzgzMzYwZmYtMzIyNS00MjczLWEzMDMtNDJjYzk5M2NjODFjJykiPgogICAgICAgIDxkaXYgY2xhc3M9InVhdiBhdi1wIj5QPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0iZmxleDoxIj48ZGl2IGNsYXNzPSJ1biI+cG9wPC9kaXY+PGRpdiBjbGFzcz0idW0iPlBvcnQgODA4MCDCtyAzMCDguKfguLHguJk8L2Rpdj48L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyI+4pyTIEFjdGl2ZTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InVpdGVtIiBvbmNsaWNrPSJvbSgnY2hhaXlhLWRlZmF1bHQnLCc4ODgwJywn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJywn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJywnMicsJzAgLyAwIE1CJywnYTFiMmMzZDQuLi4nKSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2IGF2LXIiPkM8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InVuIj5jaGFpeWEtZGVmYXVsdDwvZGl2PjxkaXYgY2xhc3M9InVtIj5Qb3J0IDg4ODAgwrcg4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUPC9kaXY+PC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9ImFiZGciPuKckyBBY3RpdmU8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvY3IiPgogICAgICAgIDxkaXYgY2xhc3M9Im9waWxsIj48c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+MCDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0idXQiPuC4reC4seC4nuC5gOC4lOC4lTogMDI6MzQ6NTI8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvZSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZWkiPvCfmLQ8L2Rpdj4KICAgICAgICA8cD7guYTguKHguYjguKHguLXguKLguLnguKrguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L3A+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIEJBTiDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLWJhbiI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIj7wn5qrIOC4m+C4peC4lOC5geC4muC4meC4ouC4ueC4quC5gOC4i+C4reC4o+C5jDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBVU0VSTkFNRTwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIHBsYWNlaG9sZGVyPSLguYPguKrguYggdXNlcm5hbWUg4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4Lib4Lil4LiU4LmB4Lia4LiZIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgc3R5bGU9ImJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMTU4MDNkLCMyMmM1NWUpIj7wn5STIOC4m+C4peC4lOC5geC4muC4mTwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+Cgo8L2Rpdj48IS0tIC93cmFwIC0tPgoKPCEtLSBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJtb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbSgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIiBpZD0ibXQiPuKame+4jyBwb3A8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbSgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIFVzZXJuYW1lPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR1Ij5wb3A8L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6EgUG9ydDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkcCI+ODA4MDwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0iZGUiPjE5LzUvMjU2OTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TpiBEYXRhPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRkIj4yMTQ3NDgzNjQ4MCBHQjwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TsSBJUCBMaW1pdDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkaSI+Mjwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TiiBUcmFmZmljPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR0ciI+MCAvIDAgTUI8L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfhpQgVVVJRDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYgbW9ubyIgaWQ9ImR1dSI+YzgzMzYwZmYuLi48L3NwYW4+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEwcHgiPuC5gOC4peC4t+C4reC4geC4geC4suC4o+C4lOC4s+C5gOC4meC4tOC4meC4geC4suC4ozwvZGl2PgogICAgPGRpdiBjbGFzcz0iYWdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIj48ZGl2IGNsYXNzPSJhaSI+8J+UhDwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguYjguK3guK3guLLguKLguLg8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iPjxkaXYgY2xhc3M9ImFpIj7wn5OFPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biI+PGRpdiBjbGFzcz0iYWkiPvCfk6Y8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LmA4Lie4Li04LmI4LihIERhdGE8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiV4Li04LihIEdCIOC5gOC4nuC4tOC5iOC4oTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIj48ZGl2IGNsYXNzPSJhaSI+4pqW77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC4seC5ieC4hyBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4geC4s+C4q+C4meC4lOC5g+C4q+C4oeC5iDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIj48ZGl2IGNsYXNzPSJhaSI+8J+UgzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKPguLXguYDguIvguJUgVHJhZmZpYzwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biBkYW5nZXIiPjxkaXYgY2xhc3M9ImFpIj7wn5eR77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4peC4muC4ouC4ueC4qjwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKXguJrguJbguLLguKfguKM8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQ+CmZ1bmN0aW9uIHN3KG5hbWUsZWwpewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZWMnKS5mb3JFYWNoKHM9PnMuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobj0+bi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nK25hbWUpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9CmZ1bmN0aW9uIHRvZyhidG4sY2xzKXsKICBidG4uY2xvc2VzdCgnZGl2JykucXVlcnlTZWxlY3RvckFsbChjbHMpLmZvckVhY2goYj0+Yi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYnRuLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9CmZ1bmN0aW9uIG9tKHUscCxkLGUsaXAsdHIsdXVpZCl7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ210JykudGV4dENvbnRlbnQ9J+Kame+4jyAnK3U7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1JykudGV4dENvbnRlbnQ9dTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHAnKS50ZXh0Q29udGVudD1wOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZScpLnRleHRDb250ZW50PWU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RkJykudGV4dENvbnRlbnQ9ZD09PSfguYTguKHguYjguIjguLPguIHguLHguJQnPycyMTQ3NDgzNjQ4MCBHQic6ZDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGknKS50ZXh0Q29udGVudD1pcDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHRyJykudGV4dENvbnRlbnQ9dHI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1dScpLnRleHRDb250ZW50PXV1aWQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwp9CmZ1bmN0aW9uIGNtKCl7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsgfQo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==' | base64 -d > /opt/chaiya-panel/sshws.html
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
