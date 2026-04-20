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

# ── NGINX INSTALL + CONFIG (port 81) ─────────────────────────
info "ติดตั้ง Nginx ใหม่..."
systemctl stop nginx 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
apt-get purge -y nginx nginx-common nginx-full nginx-core nginx-extras 2>/dev/null || true
rm -rf /etc/nginx /var/log/nginx /var/lib/nginx
apt-get install -y nginx
ok "ติดตั้ง Nginx ใหม่สำเร็จ"

info "ตั้งค่า Nginx port 81..."
rm -f /etc/nginx/sites-enabled/*

# เปิด port 81 ถ้ายังไม่เปิด
ufw allow 81/tcp &>/dev/null || true

if [[ $USE_SSL -eq 1 ]]; then
cat > /etc/nginx/sites-available/chaiya << EOF
server {
    listen 81 ssl http2;
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
nginx -t && systemctl restart nginx && ok "Nginx พร้อม (port 81)" || warn "Nginx มีปัญหา — ตรวจ: nginx -t"
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
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPkNIQUlZQSBWUE4g4oCUIERhc2hib2FyZDwvdGl0bGU+CjxsaW5rIGhyZWY9Imh0dHBzOi8vZm9udHMuZ29vZ2xlYXBpcy5jb20vY3NzMj9mYW1pbHk9T3JiaXRyb246d2dodEA0MDA7NzAwOzkwMCZmYW1pbHk9S2FuaXQ6d2dodEAzMDA7NDAwOzYwMCZmYW1pbHk9U2hhcmUrVGVjaCtNb25vJmRpc3BsYXk9c3dhcCIgcmVsPSJzdHlsZXNoZWV0Ij4KPHN0eWxlPgo6cm9vdCB7CiAgLS1uZW9uOiAgICNjMDg0ZmM7CiAgLS1uZW9uMjogICNhODU1Zjc7CiAgLS1uZW9uMzogICM3YzNhZWQ7CiAgLS1nbG93OiAgIHJnYmEoMTkyLDEzMiwyNTIsMC4zNSk7CiAgLS1nbG93MjogIHJnYmEoMTY4LDg1LDI0NywwLjE4KTsKICAtLWJnOiAgICAgIzBkMDYxNzsKICAtLWJnMjogICAgIzEyMDgyMDsKICAtLWJnMzogICAgIzBhMDQxMjsKICAtLWNhcmQ6ICAgcmdiYSgyNTUsMjU1LDI1NSwwLjAzOCk7CiAgLS1jYXJkMjogIHJnYmEoMTkyLDEzMiwyNTIsMC4wNyk7CiAgLS1ib3JkZXI6IHJnYmEoMTkyLDEzMiwyNTIsMC4xOCk7CiAgLS10ZXh0OiAgICNmMGU2ZmY7CiAgLS1zdWI6ICAgIHJnYmEoMjIwLDE4MCwyNTUsMC41KTsKICAtLWdyZWVuOiAgIzM0ZDM5OTsKICAtLXJlZDogICAgI2Y4NzE3MTsKICAtLXllbGxvdzogI2ZiYmYyNDsKICAtLWN5YW46ICAgIzY3ZThmOTsKfQoKKiwqOjpiZWZvcmUsKjo6YWZ0ZXIgeyBib3gtc2l6aW5nOmJvcmRlci1ib3g7IG1hcmdpbjowOyBwYWRkaW5nOjA7IH0KCmh0bWwgeyBzY3JvbGwtYmVoYXZpb3I6IHNtb290aDsgfQoKYm9keSB7CiAgbWluLWhlaWdodDogMTAwdmg7CiAgYmFja2dyb3VuZDogdmFyKC0tYmcpOwogIGZvbnQtZmFtaWx5OiAnS2FuaXQnLCBzYW5zLXNlcmlmOwogIGNvbG9yOiB2YXIoLS10ZXh0KTsKICBvdmVyZmxvdy14OiBoaWRkZW47Cn0KCi8qIOKUgOKUgCBBTUJJRU5UIEJHIOKUgOKUgCAqLwouYmxvYiB7IHBvc2l0aW9uOmZpeGVkOyBib3JkZXItcmFkaXVzOjUwJTsgZmlsdGVyOmJsdXIoMTAwcHgpOyBwb2ludGVyLWV2ZW50czpub25lOyB6LWluZGV4OjA7IGFuaW1hdGlvbjpibG9iRmxvYXQgMTBzIGVhc2UtaW4tb3V0IGluZmluaXRlOyB9Ci5ibG9iMSB7IHdpZHRoOjUwMHB4O2hlaWdodDo1MDBweDtiYWNrZ3JvdW5kOnJnYmEoMTI0LDU4LDIzNywuMTIpO3RvcDotMTAwcHg7bGVmdDotMTUwcHg7YW5pbWF0aW9uLWRlbGF5OjBzOyB9Ci5ibG9iMiB7IHdpZHRoOjM1MHB4O2hlaWdodDozNTBweDtiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA4KTtib3R0b206LTgwcHg7cmlnaHQ6LTEwMHB4O2FuaW1hdGlvbi1kZWxheTo0czsgfQouYmxvYjMgeyB3aWR0aDoyNTBweDtoZWlnaHQ6MjUwcHg7YmFja2dyb3VuZDpyZ2JhKDE2OCw4NSwyNDcsLjA3KTt0b3A6NDAlO2xlZnQ6NTUlO2FuaW1hdGlvbi1kZWxheTo3czsgfQpAa2V5ZnJhbWVzIGJsb2JGbG9hdCB7CiAgMCUsMTAwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgNTAleyB0cmFuc2Zvcm06dHJhbnNsYXRlKDE4cHgsLTE4cHgpIHNjYWxlKDEuMDYpOyB9Cn0KCi5ncmlkLWJnIHsKICBwb3NpdGlvbjpmaXhlZDsgaW5zZXQ6MDsgei1pbmRleDowOyBwb2ludGVyLWV2ZW50czpub25lOwogIGJhY2tncm91bmQtaW1hZ2U6CiAgICBsaW5lYXItZ3JhZGllbnQocmdiYSgxOTIsMTMyLDI1MiwuMDMpIDFweCwgdHJhbnNwYXJlbnQgMXB4KSwKICAgIGxpbmVhci1ncmFkaWVudCg5MGRlZywgcmdiYSgxOTIsMTMyLDI1MiwuMDMpIDFweCwgdHJhbnNwYXJlbnQgMXB4KTsKICBiYWNrZ3JvdW5kLXNpemU6NTZweCA1NnB4Owp9CgovKiDilIDilIAgVE9QQkFSIOKUgOKUgCAqLwoudG9wYmFyIHsKICBwb3NpdGlvbjogc3RpY2t5OyB0b3A6MDsgei1pbmRleDoyMDA7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOwogIHBhZGRpbmc6IC43NXJlbSAxLjJyZW07CiAgYmFja2dyb3VuZDogcmdiYSgxMyw2LDIzLDAuODgpOwogIGJhY2tkcm9wLWZpbHRlcjogYmx1cigyMHB4KTsKICBib3JkZXItYm90dG9tOiAxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKfQoudG9wYmFyLWxlZnQgeyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi43NXJlbTsgfQoubG9nby1tYXJrIHsKICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogIGZvbnQtc2l6ZTogLjYycmVtOwogIGZvbnQtd2VpZ2h0OiA5MDA7CiAgbGV0dGVyLXNwYWNpbmc6IC4zZW07CiAgY29sb3I6IHZhcigtLW5lb24pOwogIHRleHQtc2hhZG93OiAwIDAgMTJweCB2YXIoLS1nbG93KTsKICB3aGl0ZS1zcGFjZTogbm93cmFwOwp9Ci5sb2dvLWRpdmlkZXIgeyB3aWR0aDoxcHg7IGhlaWdodDoyMHB4OyBiYWNrZ3JvdW5kOnZhcigtLWJvcmRlcik7IH0KLnVzZXItY2hpcCB7CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAuNHJlbTsKICBiYWNrZ3JvdW5kOiB2YXIoLS1jYXJkMik7CiAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKICBib3JkZXItcmFkaXVzOiAyMHB4OwogIHBhZGRpbmc6IC4yMnJlbSAuNzVyZW07CiAgZm9udC1zaXplOiAuNzJyZW07CiAgY29sb3I6IHZhcigtLXN1Yik7CiAgZm9udC1mYW1pbHk6ICdTaGFyZSBUZWNoIE1vbm8nLCBtb25vc3BhY2U7Cn0KLnVzZXItY2hpcCAuZG90IHsKICB3aWR0aDogNnB4OyBoZWlnaHQ6IDZweDsKICBiYWNrZ3JvdW5kOiB2YXIoLS1ncmVlbik7CiAgYm9yZGVyLXJhZGl1czogNTAlOwogIGJveC1zaGFkb3c6IDAgMCA2cHggdmFyKC0tZ3JlZW4pOwogIGFuaW1hdGlvbjogcHVsc2UgMnMgaW5maW5pdGU7Cn0KQGtleWZyYW1lcyBwdWxzZSB7IDAlLDEwMCV7b3BhY2l0eToxfSA1MCV7b3BhY2l0eTouM30gfQoKLnRvcGJhci1yaWdodCB7IGRpc3BsYXk6ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyBnYXA6LjZyZW07IH0KI2Nsb2NrLWRpc3BsYXkgewogIGZvbnQtZmFtaWx5OiAnU2hhcmUgVGVjaCBNb25vJywgbW9ub3NwYWNlOwogIGZvbnQtc2l6ZTogLjY4cmVtOwogIGNvbG9yOiByZ2JhKDE5MiwxMzIsMjUyLC41KTsKICBsZXR0ZXItc3BhY2luZzogLjA1ZW07Cn0KLmJ0bi1sb2dvdXQgewogIGJhY2tncm91bmQ6IHJnYmEoMjQ4LDExMywxMTMsLjA4KTsKICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDI0OCwxMTMsMTEzLC4yNSk7CiAgY29sb3I6IHZhcigtLXJlZCk7CiAgYm9yZGVyLXJhZGl1czogMTBweDsKICBwYWRkaW5nOiAuM3JlbSAuOHJlbTsKICBmb250LXNpemU6IC43MnJlbTsKICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogIGN1cnNvcjogcG9pbnRlcjsKICB0cmFuc2l0aW9uOiBhbGwgLjJzOwogIGxldHRlci1zcGFjaW5nOiAuMDZlbTsKfQouYnRuLWxvZ291dDpob3ZlciB7IGJhY2tncm91bmQ6IHJnYmEoMjQ4LDExMywxMTMsLjE4KTsgYm9yZGVyLWNvbG9yOiB2YXIoLS1yZWQpOyB9CgovKiDilIDilIAgTkFWIFRBQlMg4pSA4pSAICovCi5uYXYtdGFicyB7CiAgZGlzcGxheTogZmxleDsKICBiYWNrZ3JvdW5kOiByZ2JhKDEwLDQsMTgsLjYpOwogIGJvcmRlci1ib3R0b206IDFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogIG92ZXJmbG93LXg6IGF1dG87CiAgcG9zaXRpb246IHN0aWNreTsgdG9wOiA1MnB4OyB6LWluZGV4OjEwMDsKICAtd2Via2l0LW92ZXJmbG93LXNjcm9sbGluZzogdG91Y2g7Cn0KLm5hdi10YWJzOjotd2Via2l0LXNjcm9sbGJhciB7IGRpc3BsYXk6bm9uZTsgfQoudGFiLWJ0biB7CiAgZmxleDogMTsgbWluLXdpZHRoOiA3MnB4OwogIHBhZGRpbmc6IC43MnJlbSAuNXJlbTsKICBib3JkZXI6IG5vbmU7IGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogIGZvbnQtZmFtaWx5OiAnS2FuaXQnLCBzYW5zLXNlcmlmOwogIGZvbnQtc2l6ZTogLjc2cmVtOyBmb250LXdlaWdodDogNjAwOwogIGNvbG9yOiByZ2JhKDIyMCwxODAsMjU1LC4zNSk7CiAgY3Vyc29yOiBwb2ludGVyOwogIGJvcmRlci1ib3R0b206IDJweCBzb2xpZCB0cmFuc3BhcmVudDsKICB0cmFuc2l0aW9uOiBhbGwgLjJzOwogIHdoaXRlLXNwYWNlOiBub3dyYXA7CiAgcG9zaXRpb246IHJlbGF0aXZlOwp9Ci50YWItYnRuOmhvdmVyIHsgY29sb3I6IHJnYmEoMjIwLDE4MCwyNTUsLjY1KTsgYmFja2dyb3VuZDogcmdiYSgxOTIsMTMyLDI1MiwuMDQpOyB9Ci50YWItYnRuLmFjdGl2ZSB7CiAgY29sb3I6IHZhcigtLW5lb24pOwogIGJvcmRlci1ib3R0b20tY29sb3I6IHZhcigtLW5lb24pOwogIGJhY2tncm91bmQ6IHJnYmEoMTkyLDEzMiwyNTIsLjA3KTsKICB0ZXh0LXNoYWRvdzogMCAwIDEwcHggdmFyKC0tZ2xvdyk7Cn0KLnRhYi1wYW5lbCB7IGRpc3BsYXk6bm9uZTsgfQoudGFiLXBhbmVsLmFjdGl2ZSB7IGRpc3BsYXk6YmxvY2s7IH0KCi8qIOKUgOKUgCBNQUlOIENPTlRFTlQg4pSA4pSAICovCi5tYWluIHsKICBtYXgtd2lkdGg6IDU0MHB4OwogIG1hcmdpbjogMCBhdXRvOwogIHBhZGRpbmc6IDEuNHJlbSAxcmVtIDVyZW07CiAgcG9zaXRpb246IHJlbGF0aXZlOyB6LWluZGV4OjE7CiAgZGlzcGxheTogZmxleDsgZmxleC1kaXJlY3Rpb246IGNvbHVtbjsgZ2FwOiAxLjJyZW07Cn0KCi8qIOKUgOKUgCBTRUNUSU9OIExBQkVMIOKUgOKUgCAqLwouc2VjLWxhYmVsIHsKICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogIGZvbnQtc2l6ZTogLjU4cmVtOwogIGxldHRlci1zcGFjaW5nOiAuMjVlbTsKICB0ZXh0LXRyYW5zZm9ybTogdXBwZXJjYXNlOwogIGNvbG9yOiByZ2JhKDE5MiwxMzIsMjUyLC40NSk7CiAgcGFkZGluZzogLjE1cmVtIDAgLjZyZW07CiAgZGlzcGxheTogZmxleDsgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAuNXJlbTsKfQouc2VjLWxhYmVsOjphZnRlciB7IGNvbnRlbnQ6Jyc7IGZsZXg6MTsgaGVpZ2h0OjFweDsgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdmFyKC0tYm9yZGVyKSx0cmFuc3BhcmVudCk7IH0KCi8qIOKUgOKUgCBTVEFUIENBUkRTIOKUgOKUgCAqLwouc3RhdHMtZ3JpZCB7IGRpc3BsYXk6Z3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7IGdhcDouNzVyZW07IH0KLnN0YXQtY2FyZCB7CiAgYmFja2dyb3VuZDogdmFyKC0tY2FyZCk7CiAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKICBib3JkZXItcmFkaXVzOiAxOHB4OwogIHBhZGRpbmc6IDFyZW0gMS4xcmVtOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKICBvdmVyZmxvdzogaGlkZGVuOwogIHRyYW5zaXRpb246IGJvcmRlci1jb2xvciAuMnMsIHRyYW5zZm9ybSAuMnM7Cn0KLnN0YXQtY2FyZDo6YmVmb3JlIHsKICBjb250ZW50OicnOyBwb3NpdGlvbjphYnNvbHV0ZTsgaW5zZXQ6MDsgYm9yZGVyLXJhZGl1czogMThweDsKICBiYWNrZ3JvdW5kOiByYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSBhdCB0b3AgbGVmdCwgdmFyKC0tZ2xvdzIpIDAlLCB0cmFuc3BhcmVudCA2NSUpOwogIG9wYWNpdHk6IDA7IHRyYW5zaXRpb246IG9wYWNpdHkgLjJzOwp9Ci5zdGF0LWNhcmQ6aG92ZXI6OmJlZm9yZSB7IG9wYWNpdHk6MTsgfQouc3RhdC1jYXJkOmhvdmVyIHsgYm9yZGVyLWNvbG9yOiByZ2JhKDE5MiwxMzIsMjUyLC4zOCk7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMXB4KTsgfQouc3RhdC1jYXJkLndpZGUgeyBncmlkLWNvbHVtbjogc3BhbiAyOyB9Ci5zdGF0LWljb24geyBmb250LXNpemU6IDEuMXJlbTsgbWFyZ2luLWJvdHRvbTogLjM1cmVtOyB9Ci5zdGF0LWxibCB7CiAgZm9udC1mYW1pbHk6ICdTaGFyZSBUZWNoIE1vbm8nLCBtb25vc3BhY2U7CiAgZm9udC1zaXplOiAuNnJlbTsgbGV0dGVyLXNwYWNpbmc6IC4xZW07CiAgdGV4dC10cmFuc2Zvcm06IHVwcGVyY2FzZTsKICBjb2xvcjogdmFyKC0tc3ViKTsgbWFyZ2luLWJvdHRvbTogLjNyZW07Cn0KLnN0YXQtdmFsIHsKICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogIGZvbnQtc2l6ZTogMS44cmVtOyBmb250LXdlaWdodDogOTAwOwogIGxpbmUtaGVpZ2h0OiAxOwogIGNvbG9yOiB2YXIoLS10ZXh0KTsKICB0ZXh0LXNoYWRvdzogMCAwIDE2cHggdmFyKC0tZ2xvdyk7Cn0KLnN0YXQtdW5pdCB7IGZvbnQtc2l6ZTogLjg1cmVtOyBjb2xvcjogdmFyKC0tc3ViKTsgbWFyZ2luLWxlZnQ6IC4xNXJlbTsgfQouc3RhdC1zdWIgeyBmb250LXNpemU6IC42OHJlbTsgY29sb3I6IHZhcigtLXN1Yik7IG1hcmdpbi10b3A6IC4zcmVtOyB9CgovKiBSaW5nIGdhdWdlICovCi5yaW5nLXdyYXAgeyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi44cmVtOyB9Ci5yaW5nLXN2ZyB7IGZsZXgtc2hyaW5rOjA7IH0KLnJpbmctdHJhY2sgeyBmaWxsOm5vbmU7IHN0cm9rZTpyZ2JhKDE5MiwxMzIsMjUyLC4xKTsgc3Ryb2tlLXdpZHRoOjY7IH0KLnJpbmctZmlsbCAgeyBmaWxsOm5vbmU7IHN0cm9rZS13aWR0aDo2OyBzdHJva2UtbGluZWNhcDpyb3VuZDsgdHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAxLjJzIGN1YmljLWJlemllciguNCwwLC4yLDEpOyB9Ci5yaW5nLWluZm8geyBmbGV4OjE7IH0KLmJhci1nYXVnZSB7IGhlaWdodDo2cHg7IGJhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMSk7IGJvcmRlci1yYWRpdXM6NHB4OyBtYXJnaW4tdG9wOi41NXJlbTsgb3ZlcmZsb3c6aGlkZGVuOyB9Ci5iYXItZmlsbCAgeyBoZWlnaHQ6MTAwJTsgYm9yZGVyLXJhZGl1czo0cHg7IHRyYW5zaXRpb246d2lkdGggMS4ycyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKTsgfQoKLyog4pSA4pSAIFNFUlZJQ0UgTU9OSVRPUiDilIDilIAgKi8KLnN2Yy1ncmlkIHsgZGlzcGxheTpmbGV4OyBmbGV4LWRpcmVjdGlvbjpjb2x1bW47IGdhcDouMzhyZW07IH0KLnN2Yy1yb3cgewogIGRpc3BsYXk6ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyBnYXA6LjZyZW07CiAgYm9yZGVyLXJhZGl1czoxMnB4OwogIHBhZGRpbmc6LjUycmVtIC44NXJlbTsKICBib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjEpOwogIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsLjAyKTsKICB0cmFuc2l0aW9uOiBhbGwgLjE1czsKfQouc3ZjLXJvdy51cCAgIHsgYm9yZGVyLWNvbG9yOnJnYmEoNTIsMjExLDE1MywuMjUpOyBiYWNrZ3JvdW5kOnJnYmEoNTIsMjExLDE1MywuMDQpOyB9Ci5zdmMtcm93LmRvd24geyBib3JkZXItY29sb3I6cmdiYSgyNDgsMTEzLDExMywuMjUpOyBiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsLjA0KTsgfQouc3ZjLWRvdCB7IHdpZHRoOjhweDtoZWlnaHQ6OHB4O2JvcmRlci1yYWRpdXM6NTAlO2ZsZXgtc2hyaW5rOjA7IH0KLnN2Yy1kb3QudXAgICB7IGJhY2tncm91bmQ6dmFyKC0tZ3JlZW4pOyBib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tZ3JlZW4pOyBhbmltYXRpb246cHVsc2UgMnMgaW5maW5pdGU7IH0KLnN2Yy1kb3QuZG93biB7IGJhY2tncm91bmQ6dmFyKC0tcmVkKTsgfQouc3ZjLWRvdC5jaGVja2luZyB7IGJhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuNCk7IH0KLnN2Yy1pY29uIHsgZm9udC1zaXplOi44NXJlbTsgZmxleC1zaHJpbms6MDsgfQouc3ZjLW5hbWUgeyBmb250LWZhbWlseTonU2hhcmUgVGVjaCBNb25vJyxtb25vc3BhY2U7IGZvbnQtc2l6ZTouNzNyZW07IGNvbG9yOnZhcigtLXRleHQpOyBmbGV4OjE7IGZvbnQtd2VpZ2h0OjYwMDsgfQouc3ZjLXBvcnRzIHsgZm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlOyBmb250LXNpemU6LjZyZW07IGNvbG9yOnZhcigtLXN1Yik7IH0KLnN2Yy1iYWRnZSB7CiAgZm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlOyBmb250LXNpemU6LjZyZW07CiAgcGFkZGluZzouMTJyZW0gLjVyZW07IGJvcmRlci1yYWRpdXM6MjBweDsgZmxleC1zaHJpbms6MDsgZm9udC13ZWlnaHQ6NzAwOwp9Ci5zdmMtYmFkZ2UudXAgICB7IGJhY2tncm91bmQ6cmdiYSg1MiwyMTEsMTUzLC4xNSk7IGNvbG9yOnZhcigtLWdyZWVuKTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDUyLDIxMSwxNTMsLjMpOyB9Ci5zdmMtYmFkZ2UuZG93biB7IGJhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMTIpOyBjb2xvcjp2YXIoLS1yZWQpOyAgIGJvcmRlcjoxcHggc29saWQgcmdiYSgyNDgsMTEzLDExMywuMjUpOyB9Ci5zdmMtYmFkZ2UuY2hlY2tpbmcgeyBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA4KTsgY29sb3I6dmFyKC0tc3ViKTsgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyB9CgovKiDilIDilIAgUkVGUkVTSCBCVE4g4pSA4pSAICovCi5yZWZyZXNoLWJ0biB7CiAgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyBiYWNrZ3JvdW5kOnZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOjEwcHg7CiAgcGFkZGluZzouM3JlbSAuNzVyZW07IGZvbnQtc2l6ZTouNzJyZW07IGNvbG9yOnZhcigtLXN1Yik7CiAgY3Vyc29yOnBvaW50ZXI7IGZvbnQtZmFtaWx5OidLYW5pdCcsc2Fucy1zZXJpZjsKICB0cmFuc2l0aW9uOmFsbCAuMnM7IGRpc3BsYXk6aW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi4zcmVtOwp9Ci5yZWZyZXNoLWJ0bjpob3ZlciB7IGJhY2tncm91bmQ6dmFyKC0tY2FyZDIpOyBjb2xvcjp2YXIoLS1uZW9uKTsgYm9yZGVyLWNvbG9yOnJnYmEoMTkyLDEzMiwyNTIsLjQpOyB9Ci5yZWZyZXNoLWJ0bi5zcGluIHN2ZyB7IGFuaW1hdGlvbjpzcGluUiAuNnMgbGluZWFyIGluZmluaXRlOyB9CkBrZXlmcmFtZXMgc3BpblIgeyB0b3sgdHJhbnNmb3JtOnJvdGF0ZSgzNjBkZWcpOyB9IH0KCi8qIOKUgOKUgCBDUkVBVEUgVVNFUiBQQU5FTCDilIDilIAgKi8KLmNhcnJpZXItZ3JvdXAgewogIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOwogIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgYm9yZGVyLXJhZGl1czogMjBweDsKICBvdmVyZmxvdzogaGlkZGVuOwp9Ci5jYXJyaWVyLWJ0biB7CiAgd2lkdGg6MTAwJTsgYm9yZGVyOm5vbmU7IGJhY2tncm91bmQ6dHJhbnNwYXJlbnQ7CiAgcGFkZGluZzoxLjA1cmVtIDEuMnJlbTsKICBjdXJzb3I6cG9pbnRlcjsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IGdhcDoxcmVtOwogIHRleHQtYWxpZ246bGVmdDsKICB0cmFuc2l0aW9uOmJhY2tncm91bmQgLjE1czsKICBib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwp9Ci5jYXJyaWVyLWJ0bjpsYXN0LWNoaWxkIHsgYm9yZGVyLWJvdHRvbTpub25lOyB9Ci5jYXJyaWVyLWJ0bjpob3ZlciB7IGJhY2tncm91bmQ6IHZhcigtLWNhcmQyKTsgfQouYnRuLWxvZ28gewogIHdpZHRoOjUycHg7aGVpZ2h0OjUycHg7Ym9yZGVyLXJhZGl1czoxNHB4OwogIGRpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjsKICBmbGV4LXNocmluazowOyBmb250LXNpemU6MS41cmVtOwogIGJvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKICBiYWNrZ3JvdW5kOiByZ2JhKDE5MiwxMzIsMjUyLC4wOCk7Cn0KLmJ0bi1sb2dvLmFpcyAgeyBiYWNrZ3JvdW5kOnJnYmEoNTIsMjExLDE1MywuMSk7IGJvcmRlci1jb2xvcjpyZ2JhKDUyLDIxMSwxNTMsLjMpOyB9Ci5idG4tbG9nby50cnVlIHsgYmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLC4xKTsgYm9yZGVyLWNvbG9yOnJnYmEoMjQ4LDExMywxMTMsLjI1KTsgfQouYnRuLWxvZ28uc3NoICB7IGJhY2tncm91bmQ6cmdiYSgxMDMsMjMyLDI0OSwuMSk7IGJvcmRlci1jb2xvcjpyZ2JhKDEwMywyMzIsMjQ5LC4yNSk7IH0KLmJ0bi1pbmZvIHsgZmxleDoxOyBtaW4td2lkdGg6MDsgfQouYnRuLW5hbWUgewogIGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyBmb250LXNpemU6MXJlbTsgZm9udC13ZWlnaHQ6NzAwOwogIGxldHRlci1zcGFjaW5nOi4wNGVtOyBkaXNwbGF5OmJsb2NrOyBtYXJnaW4tYm90dG9tOi4xNHJlbTsKfQouYnRuLW5hbWUuYWlzICB7IGNvbG9yOnZhcigtLWdyZWVuKTsgfQouYnRuLW5hbWUudHJ1ZSB7IGNvbG9yOnZhcigtLXJlZCk7IH0KLmJ0bi1uYW1lLnNzaCAgeyBjb2xvcjp2YXIoLS1jeWFuKTsgfQouYnRuLWRlc2MgeyBmb250LXNpemU6LjcycmVtOyBjb2xvcjp2YXIoLS1zdWIpOyB3aGl0ZS1zcGFjZTpub3dyYXA7IG92ZXJmbG93OmhpZGRlbjsgdGV4dC1vdmVyZmxvdzplbGxpcHNpczsgZGlzcGxheTpibG9jazsgfQouYnRuLWFycm93IHsgY29sb3I6dmFyKC0tc3ViKTsgZm9udC1zaXplOjEuMXJlbTsgZmxleC1zaHJpbms6MDsgdHJhbnNpdGlvbjp0cmFuc2Zvcm0gLjE4czsgfQouY2Fycmllci1idG46aG92ZXIgLmJ0bi1hcnJvdyB7IHRyYW5zZm9ybTp0cmFuc2xhdGVYKDNweCk7IGNvbG9yOnZhcigtLW5lb24pOyB9CgovKiDilIDilIAgTU9EQUwg4pSA4pSAICovCi5tb2RhbC1vdmVybGF5IHsKICBkaXNwbGF5Om5vbmU7IHBvc2l0aW9uOmZpeGVkOyBpbnNldDowOyB6LWluZGV4OjEwMDA7CiAgYmFja2dyb3VuZDpyZ2JhKDAsMCwwLC41NSk7IGJhY2tkcm9wLWZpbHRlcjpibHVyKDhweCk7CiAgYWxpZ24taXRlbXM6ZmxleC1lbmQ7IGp1c3RpZnktY29udGVudDpjZW50ZXI7Cn0KLm1vZGFsLW92ZXJsYXkub3BlbiB7IGRpc3BsYXk6ZmxleDsgfQoubW9kYWwgewogIHdpZHRoOjEwMCU7IG1heC13aWR0aDo1NDBweDsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCAjMTMwYTI0LCAjMGQwNjE3KTsKICBib3JkZXItcmFkaXVzOjI4cHggMjhweCAwIDA7CiAgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyBib3JkZXItYm90dG9tOm5vbmU7CiAgb3ZlcmZsb3c6aGlkZGVuOyBtYXgtaGVpZ2h0Ojk0dmg7CiAgZGlzcGxheTpmbGV4OyBmbGV4LWRpcmVjdGlvbjpjb2x1bW47CiAgYW5pbWF0aW9uOnNsaWRlVXAgLjI4cyBjdWJpYy1iZXppZXIoLjM0LDEuMSwuNjQsMSk7CiAgYm94LXNoYWRvdzogMCAtMjBweCA2MHB4IHJnYmEoMTI0LDU4LDIzNywuMik7Cn0KQGtleWZyYW1lcyBzbGlkZVVwIHsKICBmcm9teyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgxMDAlKTsgb3BhY2l0eTouNDsgfQogIHRvICB7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApOyAgICBvcGFjaXR5OjE7IH0KfQoubW9kYWw6OmJlZm9yZSB7CiAgY29udGVudDonJzsgZGlzcGxheTpibG9jazsKICB3aWR0aDo0MHB4OyBoZWlnaHQ6NHB4OyBib3JkZXItcmFkaXVzOjJweDsKICBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjMpOwogIG1hcmdpbjoxMHB4IGF1dG8gMDsgZmxleC1zaHJpbms6MDsKfQoubW9kYWwtaGVhZGVyIHsKICBwYWRkaW5nOi44NXJlbSAxLjRyZW0gLjk1cmVtOwogIGRpc3BsYXk6ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjsKICBib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyBmbGV4LXNocmluazowOwp9Ci5tb2RhbC10aXRsZSB7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IGZvbnQtc2l6ZToxcmVtOyBmb250LXdlaWdodDo3MDA7CiAgbGV0dGVyLXNwYWNpbmc6LjA4ZW07IGRpc3BsYXk6ZmxleDsgYWxpZ24taXRlbXM6Y2VudGVyOyBnYXA6LjZyZW07Cn0KLm1vZGFsLXRpdGxlLmFpcyAgeyBjb2xvcjp2YXIoLS1ncmVlbik7IHRleHQtc2hhZG93OjAgMCAxMnB4IHJnYmEoNTIsMjExLDE1MywuNCk7IH0KLm1vZGFsLXRpdGxlLnRydWUgeyBjb2xvcjp2YXIoLS1yZWQpOyAgIHRleHQtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjQ4LDExMywxMTMsLjMpOyB9Ci5tb2RhbC10aXRsZS5zc2ggIHsgY29sb3I6dmFyKC0tY3lhbik7ICB0ZXh0LXNoYWRvdzowIDAgMTJweCByZ2JhKDEwMywyMzIsMjQ5LC4zKTsgfQoubW9kYWwtY2xvc2UgewogIHdpZHRoOjMwcHg7aGVpZ2h0OjMwcHg7Ym9yZGVyLXJhZGl1czo1MCU7Ym9yZGVyOm5vbmU7CiAgYmFja2dyb3VuZDpyZ2JhKDE5MiwxMzIsMjUyLC4xKTsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IGp1c3RpZnktY29udGVudDpjZW50ZXI7CiAgY3Vyc29yOnBvaW50ZXI7IGZvbnQtc2l6ZTouODVyZW07IGNvbG9yOnZhcigtLXN1Yik7IHRyYW5zaXRpb246YWxsIC4yczsKfQoubW9kYWwtY2xvc2U6aG92ZXIgeyBiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsLjIpOyBjb2xvcjp2YXIoLS1yZWQpOyB9Ci5tb2RhbC1ib2R5IHsgcGFkZGluZzoxLjFyZW0gMS40cmVtIDEuOHJlbTsgb3ZlcmZsb3cteTphdXRvOyBmbGV4OjE7IH0KCi8qIOKUgOKUgCBTTkkgQkFER0Ug4pSA4pSAICovCi5zbmktYmFkZ2UgewogIGRpc3BsYXk6aW5saW5lLWZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi40cmVtOwogIGZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZTsgZm9udC1zaXplOi42NnJlbTsKICBwYWRkaW5nOi4yNXJlbSAuNzVyZW07IGJvcmRlci1yYWRpdXM6MjBweDsgbWFyZ2luLWJvdHRvbTouOTVyZW07Cn0KLnNuaS1iYWRnZS5haXMgIHsgYmFja2dyb3VuZDpyZ2JhKDUyLDIxMSwxNTMsLjEpOyBib3JkZXI6MXB4IHNvbGlkIHJnYmEoNTIsMjExLDE1MywuMyk7IGNvbG9yOnZhcigtLWdyZWVuKTsgfQouc25pLWJhZGdlLnRydWUgeyBiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsLjA4KTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDI0OCwxMTMsMTEzLC4yNSk7IGNvbG9yOnZhcigtLXJlZCk7IH0KLnNuaS1iYWRnZS5zc2ggIHsgYmFja2dyb3VuZDpyZ2JhKDEwMywyMzIsMjQ5LC4wOCk7IGJvcmRlcjoxcHggc29saWQgcmdiYSgxMDMsMjMyLDI0OSwuMjUpOyBjb2xvcjp2YXIoLS1jeWFuKTsgfQoKLyog4pSA4pSAIEZPUk0g4pSA4pSAICovCi5mZ3JpZCB7IGRpc3BsYXk6Z3JpZDsgZ3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7IGdhcDouNnJlbSAuOHJlbTsgfQouZmdyaWQgLnNwYW4yIHsgZ3JpZC1jb2x1bW46c3BhbiAyOyB9Ci5maWVsZCB7IGRpc3BsYXk6ZmxleDsgZmxleC1kaXJlY3Rpb246Y29sdW1uOyBnYXA6LjI4cmVtOyB9CmxhYmVsIHsKICBmb250LXNpemU6LjY0cmVtOyBsZXR0ZXItc3BhY2luZzouMTJlbTsgdGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlOwogIGNvbG9yOnZhcigtLXN1Yik7IGZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZTsKfQppbnB1dCwgc2VsZWN0IHsKICBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA2KTsKICBib3JkZXI6MS41cHggc29saWQgcmdiYSgxOTIsMTMyLDI1MiwuMTgpOwogIGJvcmRlci1yYWRpdXM6MTJweDsgcGFkZGluZzouNjVyZW0gLjlyZW07CiAgY29sb3I6dmFyKC0tdGV4dCk7IGZvbnQtZmFtaWx5OidLYW5pdCcsc2Fucy1zZXJpZjsKICBmb250LXNpemU6LjlyZW07IG91dGxpbmU6bm9uZTsKICB0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnMsIGJveC1zaGFkb3cgLjJzLCBiYWNrZ3JvdW5kIC4yczsKICB3aWR0aDoxMDAlOwp9CmlucHV0OjpwbGFjZWhvbGRlciB7IGNvbG9yOnJnYmEoMjIwLDE4MCwyNTUsLjI1KTsgfQppbnB1dDpmb2N1cywgc2VsZWN0OmZvY3VzIHsKICBib3JkZXItY29sb3I6cmdiYSgxOTIsMTMyLDI1MiwuNTUpOwogIGJhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMSk7CiAgYm94LXNoYWRvdzowIDAgMCAzcHggcmdiYSgxOTIsMTMyLDI1MiwuMSk7Cn0KaW5wdXQuYWlzLWY6Zm9jdXMgIHsgYm9yZGVyLWNvbG9yOnJnYmEoNTIsMjExLDE1MywuNSk7IGJveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoNTIsMjExLDE1MywuMDgpOyB9CmlucHV0LnRydWUtZjpmb2N1cyB7IGJvcmRlci1jb2xvcjpyZ2JhKDI0OCwxMTMsMTEzLC40KTsgYm94LXNoYWRvdzowIDAgMCAzcHggcmdiYSgyNDgsMTEzLDExMywuMDcpOyB9CmlucHV0LnNzaC1mOmZvY3VzICB7IGJvcmRlci1jb2xvcjpyZ2JhKDEwMywyMzIsMjQ5LC40KTsgYm94LXNoYWRvdzowIDAgMCAzcHggcmdiYSgxMDMsMjMyLDI0OSwuMDgpOyB9CnNlbGVjdCBvcHRpb24geyBiYWNrZ3JvdW5kOiMxMzBhMjQ7IH0KCi5zdWJtaXQtYnRuIHsKICB3aWR0aDoxMDAlOyBwYWRkaW5nOi44OHJlbTsgYm9yZGVyOm5vbmU7IGJvcmRlci1yYWRpdXM6MTRweDsKICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOi44OHJlbTsgZm9udC13ZWlnaHQ6NzAwOwogIGxldHRlci1zcGFjaW5nOi4xZW07IGN1cnNvcjpwb2ludGVyOyBtYXJnaW4tdG9wOi45cmVtOwogIHRyYW5zaXRpb246YWxsIC4yNXM7IHBvc2l0aW9uOnJlbGF0aXZlOyBvdmVyZmxvdzpoaWRkZW47Cn0KLnN1Ym1pdC1idG46ZGlzYWJsZWQgeyBvcGFjaXR5Oi40NTsgY3Vyc29yOm5vdC1hbGxvd2VkOyB9Ci5zdWJtaXQtYnRuLmFpcy1idG4gIHsKICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzA2NWY0NiwjMDU5NjY5LCMzNGQzOTkpOwogIGNvbG9yOiNmZmY7IGJveC1zaGFkb3c6MCA0cHggMjBweCByZ2JhKDUyLDIxMSwxNTMsLjMpOwp9Ci5zdWJtaXQtYnRuLmFpcy1idG46aG92ZXI6bm90KDpkaXNhYmxlZCkgIHsgYm94LXNoYWRvdzowIDZweCAyOHB4IHJnYmEoNTIsMjExLDE1MywuNDUpOyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTsgfQouc3VibWl0LWJ0bi50cnVlLWJ0biB7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCM3ZjFkMWQsI2RjMjYyNiwjZjg3MTcxKTsKICBjb2xvcjojZmZmOyBib3gtc2hhZG93OjAgNHB4IDIwcHggcmdiYSgyNDgsMTEzLDExMywuMjgpOwp9Ci5zdWJtaXQtYnRuLnRydWUtYnRuOmhvdmVyOm5vdCg6ZGlzYWJsZWQpIHsgYm94LXNoYWRvdzowIDZweCAyOHB4IHJnYmEoMjQ4LDExMywxMTMsLjQpOyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTsgfQouc3VibWl0LWJ0bi5zc2gtYnRuICB7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNjRlNjMsIzA4OTFiMiwjNjdlOGY5KTsKICBjb2xvcjojMDcxMTFhOyBib3gtc2hhZG93OjAgNHB4IDIwcHggcmdiYSgxMDMsMjMyLDI0OSwuMjgpOwp9Ci5zdWJtaXQtYnRuLnNzaC1idG46aG92ZXI6bm90KDpkaXNhYmxlZCkgIHsgYm94LXNoYWRvdzowIDZweCAyOHB4IHJnYmEoMTAzLDIzMiwyNDksLjQpOyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTsgfQoKLnNwaW5uZXIgewogIGRpc3BsYXk6aW5saW5lLWJsb2NrO3dpZHRoOjE0cHg7aGVpZ2h0OjE0cHg7CiAgYm9yZGVyOjJweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4zKTsgYm9yZGVyLXRvcC1jb2xvcjojZmZmOwogIGJvcmRlci1yYWRpdXM6NTAlOyBhbmltYXRpb246c3BpbiAuN3MgbGluZWFyIGluZmluaXRlOwogIHZlcnRpY2FsLWFsaWduOm1pZGRsZTsgbWFyZ2luLXJpZ2h0Oi40cmVtOwp9CkBrZXlmcmFtZXMgc3BpbiB7IHRveyB0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyk7IH0gfQoKLmFsZXJ0LW1zZyB7CiAgZGlzcGxheTpub25lOyBtYXJnaW4tdG9wOi43cmVtOyBwYWRkaW5nOi42NXJlbSAuOXJlbTsKICBib3JkZXItcmFkaXVzOjEwcHg7IGZvbnQtc2l6ZTouOHJlbTsgbGluZS1oZWlnaHQ6MS41Owp9Ci5hbGVydC1tc2cub2sgIHsgYmFja2dyb3VuZDpyZ2JhKDUyLDIxMSwxNTMsLjEpOyAgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDUyLDIxMSwxNTMsLjMpOyBjb2xvcjp2YXIoLS1ncmVlbik7IH0KLmFsZXJ0LW1zZy5lcnIgeyBiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsLjA4KTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDI0OCwxMTMsMTEzLC4yNSk7IGNvbG9yOnZhcigtLXJlZCk7IH0KCi8qIOKUgOKUgCBSRVNVTFQgQ0FSRCDilIDilIAgKi8KLnJlc3VsdC1jYXJkIHsKICBkaXNwbGF5Om5vbmU7IG1hcmdpbi10b3A6MS4xcmVtOwogIGJvcmRlci1yYWRpdXM6MTZweDsgb3ZlcmZsb3c6aGlkZGVuOwogIGJvcmRlcjoxLjVweCBzb2xpZCByZ2JhKDE5MiwxMzIsMjUyLC4yNSk7CiAgYm94LXNoYWRvdzowIDRweCAyMHB4IHJnYmEoMTI0LDU4LDIzNywuMTUpOwp9Ci5yZXN1bHQtY2FyZC5zaG93IHsgZGlzcGxheTpibG9jazsgfQoucmVzdWx0LWhlYWRlciB7CiAgcGFkZGluZzouNjVyZW0gMXJlbTsKICBmb250LWZhbWlseTonU2hhcmUgVGVjaCBNb25vJyxtb25vc3BhY2U7IGZvbnQtc2l6ZTouN3JlbTsgbGV0dGVyLXNwYWNpbmc6LjFlbTsKICBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi41cmVtOwogIGJhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMDgpOwogIGJvcmRlci1ib3R0b206MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjE4KTsKfQoucmVzdWx0LWhlYWRlciAuZG90IHsgd2lkdGg6N3B4O2hlaWdodDo3cHg7Ym9yZGVyLXJhZGl1czo1MCU7ZmxleC1zaHJpbms6MDsgfQoucmVzdWx0LWJvZHkgeyBwYWRkaW5nOi44NXJlbSAxcmVtOyBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA0KTsgfQouaW5mby1yb3dzIHsgbWFyZ2luLWJvdHRvbTouOHJlbTsgfQouaW5mby1yb3cgewogIGRpc3BsYXk6ZmxleDsganVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47IGFsaWduLWl0ZW1zOmNlbnRlcjsKICBwYWRkaW5nOi4zcmVtIDA7IGJvcmRlci1ib3R0b206MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjEpOwogIGZvbnQtc2l6ZTouOHJlbTsKfQouaW5mby1yb3c6bGFzdC1jaGlsZCB7IGJvcmRlci1ib3R0b206bm9uZTsgfQouaW5mby1rZXkgeyBjb2xvcjp2YXIoLS1zdWIpOyBmb250LXNpemU6LjY4cmVtOyBmb250LWZhbWlseTonU2hhcmUgVGVjaCBNb25vJyxtb25vc3BhY2U7IGxldHRlci1zcGFjaW5nOi4wNmVtOyB9Ci5pbmZvLXZhbCB7IGNvbG9yOnZhcigtLXRleHQpOyB0ZXh0LWFsaWduOnJpZ2h0OyB3b3JkLWJyZWFrOmJyZWFrLWFsbDsgbWF4LXdpZHRoOjYyJTsgfQouaW5mby12YWwucGFzcyB7IGZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZTsgY29sb3I6dmFyKC0tZ3JlZW4pOyBmb250LXdlaWdodDo2MDA7IH0KCi5saW5rLWJveCB7CiAgYmFja2dyb3VuZDpyZ2JhKDE5MiwxMzIsMjUyLC4wNyk7IGJvcmRlci1yYWRpdXM6MTBweDsKICBwYWRkaW5nOi43cmVtIC45cmVtOyBmb250LWZhbWlseTonU2hhcmUgVGVjaCBNb25vJyxtb25vc3BhY2U7CiAgZm9udC1zaXplOi42cmVtOyB3b3JkLWJyZWFrOmJyZWFrLWFsbDsgbGluZS1oZWlnaHQ6MS43NTsKICBtYXJnaW4tYm90dG9tOi43NXJlbTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDE5MiwxMzIsMjUyLC4xOCk7CiAgY29sb3I6dmFyKC0tc3ViKTsKfQoucXItd3JhcCB7IGRpc3BsYXk6ZmxleDsganVzdGlmeS1jb250ZW50OmNlbnRlcjsgbWFyZ2luOi42cmVtIDAgLjhyZW07IH0KLnFyLWlubmVyIHsKICBiYWNrZ3JvdW5kOiNmZmY7IHBhZGRpbmc6MTBweDsgYm9yZGVyLXJhZGl1czoxMHB4OwogIGRpc3BsYXk6aW5saW5lLWJsb2NrOyBib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjI1KTsKfQouY29weS1yb3cgeyBkaXNwbGF5OmZsZXg7IGdhcDouNXJlbTsgZmxleC13cmFwOndyYXA7IH0KLmNvcHktYnRuIHsKICBmbGV4OjE7IG1pbi13aWR0aDoxMDBweDsgcGFkZGluZzouNXJlbSAuN3JlbTsgYm9yZGVyLXJhZGl1czoxMHB4OwogIGJvcmRlcjoxLjVweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA2KTsKICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOi43OHJlbTsgZm9udC13ZWlnaHQ6NzAwOwogIGxldHRlci1zcGFjaW5nOi4wNmVtOyBjdXJzb3I6cG9pbnRlcjsgdHJhbnNpdGlvbjphbGwgLjE4czsgY29sb3I6dmFyKC0tbmVvbik7Cn0KLmNvcHktYnRuOmhvdmVyIHsgYmFja2dyb3VuZDp2YXIoLS1jYXJkMik7IGJvcmRlci1jb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC40NSk7IH0KLmNvcHktYnRuLmNvcGllZCB7IG9wYWNpdHk6LjY7IHBvaW50ZXItZXZlbnRzOm5vbmU7IH0KCi8qIOKUgOKUgCBVU0VSIExJU1Qg4pSA4pSAICovCi5tZ210LXBhbmVsIHsKICBiYWNrZ3JvdW5kOnZhcigtLWNhcmQpOyBib3JkZXItcmFkaXVzOjIwcHg7CiAgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOyBvdmVyZmxvdzpoaWRkZW47Cn0KLm1nbXQtaGVhZGVyIHsKICBwYWRkaW5nOi45cmVtIDEuMnJlbTsgYm9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKICBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsganVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47IGdhcDouOHJlbTsKfQoubWdtdC10aXRsZSB7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IGZvbnQtc2l6ZTouOXJlbTsgZm9udC13ZWlnaHQ6NzAwOwogIGxldHRlci1zcGFjaW5nOi4wNmVtOyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi41cmVtOwogIGNvbG9yOnZhcigtLW5lb24pOwp9Ci5zZWFyY2gtYmFyIHsKICBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi41cmVtOwogIHBhZGRpbmc6Ljc1cmVtIDEuMnJlbTsgYm9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKfQouc2VhcmNoLWJhciBpbnB1dCB7CiAgZmxleDoxOyBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA2KTsKICBib3JkZXI6MS41cHggc29saWQgdmFyKC0tYm9yZGVyKTsgYm9yZGVyLXJhZGl1czoxMHB4OwogIHBhZGRpbmc6LjVyZW0gLjg1cmVtOyBmb250LWZhbWlseTonS2FuaXQnLHNhbnMtc2VyaWY7CiAgZm9udC1zaXplOi44OHJlbTsgb3V0bGluZTpub25lOyBjb2xvcjp2YXIoLS10ZXh0KTsKfQouc2VhcmNoLWJhciBpbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC40KTsgYmFja2dyb3VuZDpyZ2JhKDE5MiwxMzIsMjUyLC4xKTsgfQoudXNlci1saXN0IHsgbWF4LWhlaWdodDo0MDBweDsgb3ZlcmZsb3cteTphdXRvOyB9Ci51c2VyLWxpc3Q6Oi13ZWJraXQtc2Nyb2xsYmFyIHsgd2lkdGg6NHB4OyB9Ci51c2VyLWxpc3Q6Oi13ZWJraXQtc2Nyb2xsYmFyLXRodW1iIHsgYmFja2dyb3VuZDpyZ2JhKDE5MiwxMzIsMjUyLC4yKTsgYm9yZGVyLXJhZGl1czoycHg7IH0KLnVzZXItcm93IHsKICBwYWRkaW5nOi43NXJlbSAxLjJyZW07IGJvcmRlci1ib3R0b206MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjA3KTsKICBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOi44cmVtOwogIHRyYW5zaXRpb246YmFja2dyb3VuZCAuMTVzOyBjdXJzb3I6cG9pbnRlcjsKfQoudXNlci1yb3c6bGFzdC1jaGlsZCB7IGJvcmRlci1ib3R0b206bm9uZTsgfQoudXNlci1yb3c6aG92ZXIgeyBiYWNrZ3JvdW5kOnZhcigtLWNhcmQyKTsgfQoudXNlci1hdmF0YXIgewogIHdpZHRoOjM2cHg7IGhlaWdodDozNnB4OyBib3JkZXItcmFkaXVzOjEwcHg7CiAgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IGp1c3RpZnktY29udGVudDpjZW50ZXI7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IGZvbnQtd2VpZ2h0OjcwMDsgZm9udC1zaXplOi45cmVtOwogIGZsZXgtc2hyaW5rOjA7Cn0KLnVhLWFpcyAgeyBiYWNrZ3JvdW5kOnJnYmEoNTIsMjExLDE1MywuMTUpOyBjb2xvcjp2YXIoLS1ncmVlbik7IGJvcmRlcjoxcHggc29saWQgcmdiYSg1MiwyMTEsMTUzLC4zKTsgfQoudWEtdHJ1ZSB7IGJhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMTIpOyBjb2xvcjp2YXIoLS1yZWQpOyAgIGJvcmRlcjoxcHggc29saWQgcmdiYSgyNDgsMTEzLDExMywuMjUpOyB9Ci51YS1zc2ggIHsgYmFja2dyb3VuZDpyZ2JhKDEwMywyMzIsMjQ5LC4xKTsgIGNvbG9yOnZhcigtLWN5YW4pOyAgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDEwMywyMzIsMjQ5LC4yNSk7IH0KLnVzZXItaW5mbyB7IGZsZXg6MTsgbWluLXdpZHRoOjA7IH0KLnVzZXItbmFtZSB7IGZvbnQtd2VpZ2h0OjYwMDsgZm9udC1zaXplOi44OHJlbTsgY29sb3I6dmFyKC0tdGV4dCk7IG1hcmdpbi1ib3R0b206LjFyZW07IH0KLnVzZXItbWV0YSB7IGZvbnQtc2l6ZTouN3JlbTsgY29sb3I6dmFyKC0tc3ViKTsgZm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlOyB9Ci5zdGF0dXMtYmFkZ2UgewogIGZvbnQtc2l6ZTouNjRyZW07IHBhZGRpbmc6LjJyZW0gLjU1cmVtOyBib3JkZXItcmFkaXVzOjIwcHg7CiAgZm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlOyBmbGV4LXNocmluazowOwp9Ci5zdGF0dXMtb2sgICB7IGJhY2tncm91bmQ6cmdiYSg1MiwyMTEsMTUzLC4xMik7IGJvcmRlcjoxcHggc29saWQgcmdiYSg1MiwyMTEsMTUzLC4zKTsgY29sb3I6dmFyKC0tZ3JlZW4pOyB9Ci5zdGF0dXMtZXhwICB7IGJhY2tncm91bmQ6cmdiYSgyNTEsMTkxLDM2LC4xKTsgIGJvcmRlcjoxcHggc29saWQgcmdiYSgyNTEsMTkxLDM2LC4yNSk7IGNvbG9yOnZhcigtLXllbGxvdyk7IH0KLnN0YXR1cy1kZWFkIHsgYmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLC4xKTsgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDI0OCwxMTMsMTEzLC4yNSk7IGNvbG9yOnZhcigtLXJlZCk7IH0KLmVtcHR5LXN0YXRlIHsgdGV4dC1hbGlnbjpjZW50ZXI7IHBhZGRpbmc6MnJlbSAxcmVtOyBjb2xvcjp2YXIoLS1zdWIpOyBmb250LXNpemU6Ljg1cmVtOyB9Ci5lbXB0eS1zdGF0ZSAuZWkgeyBmb250LXNpemU6MnJlbTsgbWFyZ2luLWJvdHRvbTouNXJlbTsgfQoubG9hZGluZy1yb3cgewogIHRleHQtYWxpZ246Y2VudGVyOyBwYWRkaW5nOjEuNXJlbTsgY29sb3I6dmFyKC0tc3ViKTsKICBmb250LXNpemU6LjgycmVtOyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsKICBqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyOyBnYXA6LjVyZW07Cn0KCi8qIOKUgOKUgCBPTkxJTkUgVVNFUlMg4pSA4pSAICovCi5vbmxpbmUtZG90IHsKICB3aWR0aDoxMHB4O2hlaWdodDoxMHB4O2JvcmRlci1yYWRpdXM6NTAlOwogIGJhY2tncm91bmQ6dmFyKC0tZ3JlZW4pOwogIGJveC1zaGFkb3c6MCAwIDhweCB2YXIoLS1ncmVlbik7CiAgYW5pbWF0aW9uOnB1bHNlIDJzIGluZmluaXRlOwogIGZsZXgtc2hyaW5rOjA7Cn0KCi8qIOKUgOKUgCBUT0FTVCDilIDilIAgKi8KLnRvYXN0IHsKICBwb3NpdGlvbjpmaXhlZDsgYm90dG9tOjMwcHg7IGxlZnQ6NTAlOwogIHRyYW5zZm9ybTp0cmFuc2xhdGVYKC01MCUpIHNjYWxlKC45NSk7CiAgYmFja2dyb3VuZDpyZ2JhKDEzLDYsMjMsLjk1KTsgYmFja2Ryb3AtZmlsdGVyOmJsdXIoMjBweCk7CiAgYm9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpOwogIGNvbG9yOnZhcigtLXRleHQpOyBwYWRkaW5nOi42NXJlbSAxLjZyZW07CiAgYm9yZGVyLXJhZGl1czoyNnB4OyBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsKICBmb250LXdlaWdodDo3MDA7IGZvbnQtc2l6ZTouODhyZW07CiAgb3BhY2l0eTowOyBwb2ludGVyLWV2ZW50czpub25lOyB6LWluZGV4Ojk5OTk7CiAgdHJhbnNpdGlvbjpvcGFjaXR5IC4yNXMsIHRyYW5zZm9ybSAuMjVzOwogIHdoaXRlLXNwYWNlOm5vd3JhcDsKICBib3gtc2hhZG93OjAgOHB4IDMycHggcmdiYSgxMjQsNTgsMjM3LC4zKTsKfQoudG9hc3Quc2hvdyB7IG9wYWNpdHk6MTsgdHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSkgc2NhbGUoMSk7IH0KCkBtZWRpYShtYXgtd2lkdGg6NjAwcHgpewogIC5mZ3JpZCB7IGdyaWQtdGVtcGxhdGUtY29sdW1uczoxZnI7IH0KICAuZmdyaWQgLnNwYW4yIHsgZ3JpZC1jb2x1bW46c3BhbiAxOyB9Cn0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KCjwhLS0gQW1iaWVudCAtLT4KPGRpdiBjbGFzcz0iZ3JpZC1iZyI+PC9kaXY+CjxkaXYgY2xhc3M9ImJsb2IgYmxvYjEiPjwvZGl2Pgo8ZGl2IGNsYXNzPSJibG9iIGJsb2IyIj48L2Rpdj4KPGRpdiBjbGFzcz0iYmxvYiBibG9iMyI+PC9kaXY+Cgo8IS0tIFRPUCBCQVIgLS0+CjxoZWFkZXIgY2xhc3M9InRvcGJhciI+CiAgPGRpdiBjbGFzcz0idG9wYmFyLWxlZnQiPgogICAgPHNwYW4gY2xhc3M9ImxvZ28tbWFyayI+4pymIENIQUlZQTwvc3Bhbj4KICAgIDxkaXYgY2xhc3M9ImxvZ28tZGl2aWRlciI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJ1c2VyLWNoaXAiPgogICAgICA8c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+CiAgICAgIDxzcGFuIGlkPSJ0b3BiYXItdXNlciI+4oCUPC9zcGFuPgogICAgPC9kaXY+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0idG9wYmFyLXJpZ2h0Ij4KICAgIDxzcGFuIGlkPSJjbG9jay1kaXNwbGF5Ij48L3NwYW4+CiAgICA8c3BhbiBpZD0icnQtYmFkZ2UiIHN0eWxlPSJmb250LWZhbWlseTonU2hhcmUgVGVjaCBNb25vJyxtb25vc3BhY2U7Zm9udC1zaXplOi42cmVtO2JhY2tncm91bmQ6I2RjZmNlNztib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE2NjUzNDtwYWRkaW5nOi4xOHJlbSAuNTVyZW07Ym9yZGVyLXJhZGl1czoyMHB4O2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDouM3JlbSI+PHNwYW4gc3R5bGU9IndpZHRoOjZweDtoZWlnaHQ6NnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTthbmltYXRpb246cHVsc2UgMnMgaW5maW5pdGU7ZmxleC1zaHJpbms6MCI+PC9zcGFuPkxJVkU8L3NwYW4+CiAgICA8YnV0dG9uIGNsYXNzPSJidG4tbG9nb3V0IiBvbmNsaWNrPSJkb0xvZ291dCgpIj7ij7sg4Lit4Lit4LiBPC9idXR0b24+CiAgPC9kaXY+CjwvaGVhZGVyPgoKPCEtLSBOQVYgVEFCUyAtLT4KPG5hdiBjbGFzcz0ibmF2LXRhYnMiPgogIDxidXR0b24gY2xhc3M9InRhYi1idG4gYWN0aXZlIiBpZD0idGFiLWJ0bi1kYXNoIiAgICBvbmNsaWNrPSJzd2l0Y2hUYWIoJ2Rhc2gnLHRoaXMpIj7wn5OKIERhc2hib2FyZDwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9InRhYi1idG4iICAgICAgICBpZD0idGFiLWJ0bi1jcmVhdGUiICBvbmNsaWNrPSJzd2l0Y2hUYWIoJ2NyZWF0ZScsdGhpcykiPuKaoSDguKrguKPguYnguLLguIfguJzguLnguYnguYPguIrguYk8L2J1dHRvbj4KICA8YnV0dG9uIGNsYXNzPSJ0YWItYnRuIiAgICAgICAgaWQ9InRhYi1idG4tbWFuYWdlIiAgb25jbGljaz0ic3dpdGNoVGFiKCdtYW5hZ2UnLHRoaXMpIj7wn5SnIOC4iOC4seC4lOC4geC4suC4ozwvYnV0dG9uPgogIDxidXR0b24gY2xhc3M9InRhYi1idG4iICAgICAgICBpZD0idGFiLWJ0bi1vbmxpbmUiICBvbmNsaWNrPSJzd2l0Y2hUYWIoJ29ubGluZScsdGhpcykiPvCfn6Ig4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9idXR0b24+CjwvbmF2PgoKPCEtLSDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAgVEFCOiBEQVNIQk9BUkQg4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQIC0tPgo8ZGl2IGNsYXNzPSJ0YWItcGFuZWwgYWN0aXZlIiBpZD0idGFiLWRhc2giPgo8ZGl2IGNsYXNzPSJtYWluIj4KICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuIj4KICAgIDxzcGFuIGNsYXNzPSJzZWMtbGFiZWwiPuKsoSBTeXN0ZW0gTW9uaXRvcjwvc3Bhbj4KICAgIDxidXR0b24gY2xhc3M9InJlZnJlc2gtYnRuIiBpZD0icmVmcmVzaC1idG4iIG9uY2xpY2s9ImxvYWRTdGF0cygpIj4KICAgICAgPHN2ZyB3aWR0aD0iMTMiIGhlaWdodD0iMTMiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi41Ij4KICAgICAgICA8cGF0aCBkPSJNMjMgNHY2aC02Ii8+PHBhdGggZD0iTTEgMjB2LTZoNiIvPgogICAgICAgIDxwYXRoIGQ9Ik0zLjUxIDlhOSA5IDAgMCAxIDE0Ljg1LTMuMzZMMjMgMTBNMSAxNGw0LjY0IDQuMzZBOSA5IDAgMCAwIDIwLjQ5IDE1Ii8+CiAgICAgIDwvc3ZnPgogICAgICDguKPguLXguYDguJ/guKPguIoKICAgIDwvYnV0dG9uPgogIDwvZGl2PgoKICA8ZGl2IGNsYXNzPSJzdGF0cy1ncmlkIj4KICAgIDwhLS0gQ1BVIC0tPgogICAgPGRpdiBjbGFzcz0ic3RhdC1jYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic3RhdC1sYmwiPuKaoSBDUFUgVXNhZ2U8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0icmluZy13cmFwIj4KICAgICAgICA8c3ZnIGNsYXNzPSJyaW5nLXN2ZyIgd2lkdGg9IjYyIiBoZWlnaHQ9IjYyIiB2aWV3Qm94PSIwIDAgNjIgNjIiPgogICAgICAgICAgPGNpcmNsZSBjbGFzcz0icmluZy10cmFjayIgY3g9IjMxIiBjeT0iMzEiIHI9IjI1Ii8+CiAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJyaW5nLWZpbGwiIGlkPSJjcHUtcmluZyIgY3g9IjMxIiBjeT0iMzEiIHI9IjI1IgogICAgICAgICAgICBzdHJva2U9IiNhODU1ZjciIHN0cm9rZS1kYXNoYXJyYXk9IjE1Ny4xIiBzdHJva2UtZGFzaG9mZnNldD0iMTU3LjEiCiAgICAgICAgICAgIHRyYW5zZm9ybT0icm90YXRlKC05MCAzMSAzMSkiLz4KICAgICAgICA8L3N2Zz4KICAgICAgICA8ZGl2IGNsYXNzPSJyaW5nLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3RhdC12YWwiIGlkPSJjcHUtdmFsIj4tLTxzcGFuIGNsYXNzPSJzdGF0LXVuaXQiPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGF0LXN1YiIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJhci1nYXVnZSI+PGRpdiBjbGFzcz0iYmFyLWZpbGwiIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzdjM2FlZCwjYzA4NGZjKSI+PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDwhLS0gUkFNIC0tPgogICAgPGRpdiBjbGFzcz0ic3RhdC1jYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic3RhdC1sYmwiPvCfp6AgUkFNIFVzYWdlPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InJpbmctd3JhcCI+CiAgICAgICAgPHN2ZyBjbGFzcz0icmluZy1zdmciIHdpZHRoPSI2MiIgaGVpZ2h0PSI2MiIgdmlld0JveD0iMCAwIDYyIDYyIj4KICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InJpbmctdHJhY2siIGN4PSIzMSIgY3k9IjMxIiByPSIyNSIvPgogICAgICAgICAgPGNpcmNsZSBjbGFzcz0icmluZy1maWxsIiBpZD0icmFtLXJpbmciIGN4PSIzMSIgY3k9IjMxIiByPSIyNSIKICAgICAgICAgICAgc3Ryb2tlPSIjNjdlOGY5IiBzdHJva2UtZGFzaGFycmF5PSIxNTcuMSIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjE1Ny4xIgogICAgICAgICAgICB0cmFuc2Zvcm09InJvdGF0ZSgtOTAgMzEgMzEpIi8+CiAgICAgICAgPC9zdmc+CiAgICAgICAgPGRpdiBjbGFzcz0icmluZy1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0YXQtdmFsIiBpZD0icmFtLXZhbCI+LS08c3BhbiBjbGFzcz0ic3RhdC11bml0Ij4lPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3RhdC1zdWIiIGlkPSJyYW0tZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJiYXItZ2F1Z2UiPjxkaXYgY2xhc3M9ImJhci1maWxsIiBpZD0icmFtLWJhciIgc3R5bGU9IndpZHRoOjAlO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMwODkxYjIsIzY3ZThmOSkiPjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgICA8IS0tIERpc2sgLS0+CiAgICA8ZGl2IGNsYXNzPSJzdGF0LWNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LWxibCI+8J+SviBEaXNrIFVzYWdlPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN0YXQtdmFsIiBpZD0iZGlzay12YWwiPi0tPHNwYW4gY2xhc3M9InN0YXQtdW5pdCI+JTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3RhdC1zdWIiIGlkPSJkaXNrLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJiYXItZ2F1Z2UiPjxkaXYgY2xhc3M9ImJhci1maWxsIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZDk3NzA2LCNmYmJmMjQpIj48L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogICAgPCEtLSBVcHRpbWUgLS0+CiAgICA8ZGl2IGNsYXNzPSJzdGF0LWNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LWxibCI+4o+xIFVwdGltZTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LXZhbCIgaWQ9InVwdGltZS12YWwiIHN0eWxlPSJmb250LXNpemU6MS40cmVtIj4tLTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LXN1YiIgaWQ9InVwdGltZS1zdWIiPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOi40cmVtIiBpZD0ibG9hZC1jaGlwcyI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDwhLS0gTmV0d29yayB3aWRlIC0tPgogICAgPGRpdiBjbGFzcz0ic3RhdC1jYXJkIHdpZGUiPgogICAgICA8ZGl2IGNsYXNzPSJzdGF0LWxibCI+8J+MkCBOZXR3b3JrIEkvTzwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOi41cmVtIj4KICAgICAgICA8ZGl2PgogICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOi42NXJlbTtjb2xvcjp2YXIoLS1zdWIpO2ZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZSI+4oaRIFVwbG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3RhdC12YWwiIGlkPSJuZXQtdXAiIHN0eWxlPSJmb250LXNpemU6MS4zcmVtIj4tLTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3RhdC1zdWIiIGlkPSJuZXQtdXAtdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6LjY1cmVtO2NvbG9yOnZhcigtLXN1Yik7Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIj7ihpMgRG93bmxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0YXQtdmFsIiBpZD0ibmV0LWRvd24iIHN0eWxlPSJmb250LXNpemU6MS4zcmVtIj4tLTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3RhdC1zdWIiIGlkPSJuZXQtZG93bi10b3RhbCI+dG90YWw6IC0tPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gU2VydmljZSBNb25pdG9yIC0tPgogIDxkaXY+CiAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206LjZyZW0iPgogICAgICA8c3BhbiBjbGFzcz0ic2VjLWxhYmVsIiBzdHlsZT0icGFkZGluZzowIj7irKEgU2VydmljZXM8L3NwYW4+CiAgICAgIDxidXR0b24gY2xhc3M9InJlZnJlc2gtYnRuIiBvbmNsaWNrPSJsb2FkU2VydmljZVN0YXR1cygpIj4KICAgICAgICA8c3ZnIHdpZHRoPSIxMiIgaGVpZ2h0PSIxMiIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiBzdHJva2U9ImN1cnJlbnRDb2xvciIgc3Ryb2tlLXdpZHRoPSIyLjUiPgogICAgICAgICAgPHBhdGggZD0iTTIzIDR2NmgtNiIvPjxwYXRoIGQ9Ik0xIDIwdi02aDYiLz4KICAgICAgICAgIDxwYXRoIGQ9Ik0zLjUxIDlhOSA5IDAgMCAxIDE0Ljg1LTMuMzZMMjMgMTBNMSAxNGw0LjY0IDQuMzZBOSA5IDAgMCAwIDIwLjQ5IDE1Ii8+CiAgICAgICAgPC9zdmc+CiAgICAgICAg4LiV4Lij4Lin4LiI4Liq4Lit4LiaCiAgICAgIDwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzdmMtZ3JpZCIgaWQ9InN2Yy1ncmlkIj4KICAgICAgPGRpdiBjbGFzcz0ibG9hZGluZy1yb3ciPjxzcGFuPuC4geC4s+C4peC4seC4h+C4leC4o+C4p+C4iOC4quC4reC4miBzZXJ2aWNlcy4uLjwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6LjY1cmVtO2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsLjMpO2ZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZSIgaWQ9Imxhc3QtdXBkYXRlIj7guK3guLHguJvguYDguJTguJXguKXguYjguLLguKrguLjguJQ6IC0tPC9kaXY+CjwvZGl2Pgo8L2Rpdj4KCjwhLS0g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQIFRBQjogQ1JFQVRFIFVTRVIg4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQIC0tPgo8ZGl2IGNsYXNzPSJ0YWItcGFuZWwiIGlkPSJ0YWItY3JlYXRlIj4KPGRpdiBjbGFzcz0ibWFpbiI+CiAgPHNwYW4gY2xhc3M9InNlYy1sYWJlbCI+4qyhIOC5gOC4peC4t+C4reC4gSBQcm90b2NvbDwvc3Bhbj4KICA8ZGl2IGNsYXNzPSJjYXJyaWVyLWdyb3VwIj4KICAgIDxidXR0b24gY2xhc3M9ImNhcnJpZXItYnRuIiBvbmNsaWNrPSJvcGVuTW9kYWwoJ2FpcycpIj4KICAgICAgPGRpdiBjbGFzcz0iYnRuLWxvZ28gYWlzIj7wn5uwPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1pbmZvIj4KICAgICAgICA8c3BhbiBjbGFzcz0iYnRuLW5hbWUgYWlzIj5BSVMgLyBWTEVTUy1XUzwvc3Bhbj4KICAgICAgICA8c3BhbiBjbGFzcz0iYnRuLWRlc2MiPlBvcnQgODA4MCDCtyBTTkk6IGNqLWViYi5zcGVlZHRlc3QubmV0PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9ImJ0bi1hcnJvdyI+4oC6PC9zcGFuPgogICAgPC9idXR0b24+CiAgICA8YnV0dG9uIGNsYXNzPSJjYXJyaWVyLWJ0biIgb25jbGljaz0ib3Blbk1vZGFsKCd0cnVlJykiPgogICAgICA8ZGl2IGNsYXNzPSJidG4tbG9nbyB0cnVlIj7wn5OhPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1pbmZvIj4KICAgICAgICA8c3BhbiBjbGFzcz0iYnRuLW5hbWUgdHJ1ZSI+VFJVRSAvIFZMRVNTLVdTPC9zcGFuPgogICAgICAgIDxzcGFuIGNsYXNzPSJidG4tZGVzYyI+UG9ydCA4ODgwIMK3IFNOSTogdHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlczwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJidG4tYXJyb3ciPuKAujwvc3Bhbj4KICAgIDwvYnV0dG9uPgogICAgPGJ1dHRvbiBjbGFzcz0iY2Fycmllci1idG4iIG9uY2xpY2s9Im9wZW5Nb2RhbCgnc3NoJykiPgogICAgICA8ZGl2IGNsYXNzPSJidG4tbG9nbyBzc2giPvCflJA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYnRuLWluZm8iPgogICAgICAgIDxzcGFuIGNsYXNzPSJidG4tbmFtZSBzc2giPlNTSC1XUzwvc3Bhbj4KICAgICAgICA8c3BhbiBjbGFzcz0iYnRuLWRlc2MiPlBvcnQgODAgwrcgRHJvcGJlYXI6MTQzIMK3IEhUVFAtV1MgVHVubmVsPC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9ImJ0bi1hcnJvdyI+4oC6PC9zcGFuPgogICAgPC9idXR0b24+CiAgPC9kaXY+CjwvZGl2Pgo8L2Rpdj4KCjwhLS0g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQIFRBQjogTUFOQUdFIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAtLT4KPGRpdiBjbGFzcz0idGFiLXBhbmVsIiBpZD0idGFiLW1hbmFnZSI+CjxkaXYgY2xhc3M9Im1haW4iPgogIDxkaXYgY2xhc3M9Im1nbXQtcGFuZWwiPgogICAgPGRpdiBjbGFzcz0ibWdtdC1oZWFkZXIiPgogICAgICA8ZGl2IGNsYXNzPSJtZ210LXRpdGxlIj7wn5GkIFZMRVNTIFVzZXJzPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9InJlZnJlc2gtYnRuIiBvbmNsaWNrPSJsb2FkVXNlckxpc3QoKSI+CiAgICAgICAgPHN2ZyB3aWR0aD0iMTIiIGhlaWdodD0iMTIiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi41Ij4KICAgICAgICAgIDxwYXRoIGQ9Ik0yMyA0djZoLTYiLz48cGF0aCBkPSJNMSAyMHYtNmg2Ii8+CiAgICAgICAgICA8cGF0aCBkPSJNMy41MSA5YTkgOSAwIDAgMSAxNC44NS0zLjM2TDIzIDEwTTEgMTRsNC42NCA0LjM2QTkgOSAwIDAgMCAyMC40OSAxNSIvPgogICAgICAgIDwvc3ZnPgogICAgICAgIOC4o+C4teC5gOC4n+C4o+C4igogICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ic2VhcmNoLWJhciI+CiAgICAgIDxpbnB1dCB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i8J+UjSDguITguYnguJnguKvguLLguJzguLnguYnguYPguIrguYkuLi4iIG9uaW5wdXQ9ImZpbHRlclVzZXJzKHRoaXMudmFsdWUpIj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0idXNlci1saXN0IiBpZD0idXNlci1saXN0Ij4KICAgICAgPGRpdiBjbGFzcz0ibG9hZGluZy1yb3ciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2Pgo8L2Rpdj4KCjwhLS0g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQIFRBQjogT05MSU5FIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAtLT4KPGRpdiBjbGFzcz0idGFiLXBhbmVsIiBpZD0idGFiLW9ubGluZSI+CjxkaXYgY2xhc3M9Im1haW4iPgogIDxkaXYgY2xhc3M9Im1nbXQtcGFuZWwiPgogICAgPGRpdiBjbGFzcz0ibWdtdC1oZWFkZXIiPgogICAgICA8ZGl2IGNsYXNzPSJtZ210LXRpdGxlIj7wn5+iIE9ubGluZSBVc2VyczwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJyZWZyZXNoLWJ0biIgaWQ9Im9ubGluZS1yZWZyZXNoIiBvbmNsaWNrPSJsb2FkT25saW5lVXNlcnMoKSI+CiAgICAgICAgPHN2ZyB3aWR0aD0iMTIiIGhlaWdodD0iMTIiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJjdXJyZW50Q29sb3IiIHN0cm9rZS13aWR0aD0iMi41Ij4KICAgICAgICAgIDxwYXRoIGQ9Ik0yMyA0djZoLTYiLz48cGF0aCBkPSJNMSAyMHYtNmg2Ii8+CiAgICAgICAgICA8cGF0aCBkPSJNMy41MSA5YTkgOSAwIDAgMSAxNC44NS0zLjM2TDIzIDEwTTEgMTRsNC42NCA0LjM2QTkgOSAwIDAgMCAyMC40OSAxNSIvPgogICAgICAgIDwvc3ZnPgogICAgICAgIOC4o+C4teC5gOC4n+C4o+C4igogICAgICA8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0idXNlci1saXN0IiBpZD0ib25saW5lLWxpc3QiPgogICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nLXJvdyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+CjwvZGl2PgoKPCEtLSDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAgTU9EQUw6IEFJUyDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAgLS0+CjxkaXYgY2xhc3M9Im1vZGFsLW92ZXJsYXkiIGlkPSJtb2RhbC1haXMiPgo8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgPGRpdiBjbGFzcz0ibW9kYWwtaGVhZGVyIj4KICAgIDxkaXYgY2xhc3M9Im1vZGFsLXRpdGxlIGFpcyI+8J+bsCDguKrguKPguYnguLLguIfguJzguLnguYnguYPguIrguYkgQUlTIC8gVkxFU1MtV1M8L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9Im1vZGFsLWNsb3NlIiBvbmNsaWNrPSJjbG9zZU1vZGFsKCdhaXMnKSI+4pyVPC9idXR0b24+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0ibW9kYWwtYm9keSI+CiAgICA8ZGl2IGNsYXNzPSJzbmktYmFkZ2UgYWlzIj7wn4yQIGNqLWViYi5zcGVlZHRlc3QubmV0IMK3IFBvcnQgODA4MDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCBzcGFuMiI+PGxhYmVsPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iSAoRW1haWwpPC9sYWJlbD48aW5wdXQgdHlwZT0idGV4dCIgaWQ9ImFpcy1lbWFpbCIgcGxhY2Vob2xkZXI9InVzZXJAYWlzIiBjbGFzcz0iYWlzLWYiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+PGxhYmVsPuC4reC4suC4ouC4uCAo4Lin4Lix4LiZKTwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9ImFpcy1kYXlzIiB2YWx1ZT0iMzAiIG1pbj0iMSIgY2xhc3M9ImFpcy1mIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQiPjxsYWJlbD7guIjguLPguIHguLHguJQgSVA8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJhaXMtaXBsaW1pdCIgdmFsdWU9IjIiIG1pbj0iMSIgY2xhc3M9ImFpcy1mIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQgc3BhbjIiPjxsYWJlbD7guILguYnguK3guKHguLnguKUgKEdCLCAwPeC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2xhYmVsPjxpbnB1dCB0eXBlPSJudW1iZXIiIGlkPSJhaXMtZ2IiIHZhbHVlPSIwIiBtaW49IjAiIGNsYXNzPSJhaXMtZiI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9InN1Ym1pdC1idG4gYWlzLWJ0biIgaWQ9ImFpcy1zdWJtaXQiIG9uY2xpY2s9ImNyZWF0ZUFJUygpIj7imqEg4Liq4Lij4LmJ4Liy4LiH4Lia4Lix4LiN4LiK4Li1IEFJUzwvYnV0dG9uPgogICAgPGRpdiBjbGFzcz0iYWxlcnQtbXNnIiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgIDxkaXYgY2xhc3M9InJlc3VsdC1jYXJkIiBpZD0iYWlzLXJlc3VsdCI+CiAgICAgIDxkaXYgY2xhc3M9InJlc3VsdC1oZWFkZXIiIHN0eWxlPSJjb2xvcjp2YXIoLS1ncmVlbikiPjxzcGFuIGNsYXNzPSJkb3QiIHN0eWxlPSJiYWNrZ3JvdW5kOnZhcigtLWdyZWVuKSI+PC9zcGFuPuKchSDguKrguKPguYnguLLguIfguKrguLPguYDguKPguYfguIg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0icmVzdWx0LWJvZHkiPgogICAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93cyIgaWQ9ImFpcy1pbmZvLXJvd3MiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmstYm94IiBpZD0iYWlzLXZsZXNzLWxpbmsiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InFyLXdyYXAiPjxkaXYgY2xhc3M9InFyLWlubmVyIiBpZD0iYWlzLXFyIj48L2Rpdj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJjb3B5LXJvdyI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgaWQ9ImFpcy1jb3B5LXZsZXNzIiBvbmNsaWNrPSJjb3B5RWwoJ2Fpcy12bGVzcy1saW5rJywnYWlzLWNvcHktdmxlc3MnKSI+8J+TiyBDb3B5IFZMRVNTPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2Pgo8L2Rpdj4KCjwhLS0g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQIE1PREFMOiBUUlVFIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAtLT4KPGRpdiBjbGFzcz0ibW9kYWwtb3ZlcmxheSIgaWQ9Im1vZGFsLXRydWUiPgo8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgPGRpdiBjbGFzcz0ibW9kYWwtaGVhZGVyIj4KICAgIDxkaXYgY2xhc3M9Im1vZGFsLXRpdGxlIHRydWUiPvCfk6Eg4Liq4Lij4LmJ4Liy4LiH4Lic4Li54LmJ4LmD4LiK4LmJIFRSVUUgLyBWTEVTUy1XUzwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0ibW9kYWwtY2xvc2UiIG9uY2xpY2s9ImNsb3NlTW9kYWwoJ3RydWUnKSI+4pyVPC9idXR0b24+CiAgPC9kaXY+CiAgPGRpdiBjbGFzcz0ibW9kYWwtYm9keSI+CiAgICA8ZGl2IGNsYXNzPSJzbmktYmFkZ2UgdHJ1ZSI+8J+MkCB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzIMK3IFBvcnQgODg4MDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCBzcGFuMiI+PGxhYmVsPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iSAoRW1haWwpPC9sYWJlbD48aW5wdXQgdHlwZT0idGV4dCIgaWQ9InRydWUtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQHRydWUiIGNsYXNzPSJ0cnVlLWYiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+PGxhYmVsPuC4reC4suC4ouC4uCAo4Lin4Lix4LiZKTwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9InRydWUtZGF5cyIgdmFsdWU9IjMwIiBtaW49IjEiIGNsYXNzPSJ0cnVlLWYiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+PGxhYmVsPuC4iOC4s+C4geC4seC4lCBJUDwvbGFiZWw+PGlucHV0IHR5cGU9Im51bWJlciIgaWQ9InRydWUtaXBsaW1pdCIgdmFsdWU9IjIiIG1pbj0iMSIgY2xhc3M9InRydWUtZiI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIHNwYW4yIj48bGFiZWw+4LiC4LmJ4Lit4Lih4Li54LilIChHQiwgMD3guYTguKHguYjguIjguLPguIHguLHguJQpPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0idHJ1ZS1nYiIgdmFsdWU9IjAiIG1pbj0iMCIgY2xhc3M9InRydWUtZiI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9InN1Ym1pdC1idG4gdHJ1ZS1idG4iIGlkPSJ0cnVlLXN1Ym1pdCIgb25jbGljaz0iY3JlYXRlVFJVRSgpIj7imqEg4Liq4Lij4LmJ4Liy4LiH4Lia4Lix4LiN4LiK4Li1IFRSVUU8L2J1dHRvbj4KICAgIDxkaXYgY2xhc3M9ImFsZXJ0LW1zZyIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0icmVzdWx0LWNhcmQiIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgIDxkaXYgY2xhc3M9InJlc3VsdC1oZWFkZXIiIHN0eWxlPSJjb2xvcjp2YXIoLS1yZWQpIj48c3BhbiBjbGFzcz0iZG90IiBzdHlsZT0iYmFja2dyb3VuZDp2YXIoLS1yZWQpIj48L3NwYW4+4pyFIOC4quC4o+C5ieC4suC4h+C4quC4s+C5gOC4o+C5h+C4iDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJyZXN1bHQtYm9keSI+CiAgICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3dzIiBpZD0idHJ1ZS1pbmZvLXJvd3MiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmstYm94IiBpZD0idHJ1ZS12bGVzcy1saW5rIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJxci13cmFwIj48ZGl2IGNsYXNzPSJxci1pbm5lciIgaWQ9InRydWUtcXIiPjwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImNvcHktcm93Ij4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBpZD0idHJ1ZS1jb3B5LXZsZXNzIiBvbmNsaWNrPSJjb3B5RWwoJ3RydWUtdmxlc3MtbGluaycsJ3RydWUtY29weS12bGVzcycpIj7wn5OLIENvcHkgVkxFU1M8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+CjwvZGl2PgoKPCEtLSDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAgTU9EQUw6IFNTSCDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAgLS0+CjxkaXYgY2xhc3M9Im1vZGFsLW92ZXJsYXkiIGlkPSJtb2RhbC1zc2giPgo8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgPGRpdiBjbGFzcz0ibW9kYWwtaGVhZGVyIj4KICAgIDxkaXYgY2xhc3M9Im1vZGFsLXRpdGxlIHNzaCI+8J+UkCDguKrguKPguYnguLLguIfguJzguLnguYnguYPguIrguYkgU1NILVdTPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJtb2RhbC1jbG9zZSIgb25jbGljaz0iY2xvc2VNb2RhbCgnc3NoJykiPuKclTwvYnV0dG9uPgogIDwvZGl2PgogIDxkaXYgY2xhc3M9Im1vZGFsLWJvZHkiPgogICAgPGRpdiBjbGFzcz0ic25pLWJhZGdlIHNzaCI+8J+MkCBQb3J0IDgwIMK3IERyb3BiZWFyOjE0MyDCtyBIVFRQLVdTIFR1bm5lbDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZCBzcGFuMiI+PGxhYmVsPlVzZXJuYW1lPC9sYWJlbD48aW5wdXQgdHlwZT0idGV4dCIgaWQ9InNzaC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiIGNsYXNzPSJzc2gtZiI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIHNwYW4yIj48bGFiZWw+UGFzc3dvcmQ8L2xhYmVsPjxpbnB1dCB0eXBlPSJwYXNzd29yZCIgaWQ9InNzaC1wYXNzIiBwbGFjZWhvbGRlcj0icGFzc3dvcmQiIGNsYXNzPSJzc2gtZiI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkIj48bGFiZWw+4Lit4Liy4Lii4Li4ICjguKfguLHguJkpPC9sYWJlbD48aW5wdXQgdHlwZT0ibnVtYmVyIiBpZD0ic3NoLWRheXMiIHZhbHVlPSIzMCIgbWluPSIxIiBjbGFzcz0ic3NoLWYiPjwvZGl2PgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJzdWJtaXQtYnRuIHNzaC1idG4iIGlkPSJzc2gtc3VibWl0IiBvbmNsaWNrPSJjcmVhdGVTU0goKSI+4pqhIOC4quC4o+C5ieC4suC4h+C4muC4seC4jeC4iuC4tSBTU0g8L2J1dHRvbj4KICAgIDxkaXYgY2xhc3M9ImFsZXJ0LW1zZyIgaWQ9InNzaC1hbGVydCI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJyZXN1bHQtY2FyZCIgaWQ9InNzaC1yZXN1bHQiPgogICAgICA8ZGl2IGNsYXNzPSJyZXN1bHQtaGVhZGVyIiBzdHlsZT0iY29sb3I6dmFyKC0tY3lhbikiPjxzcGFuIGNsYXNzPSJkb3QiIHN0eWxlPSJiYWNrZ3JvdW5kOnZhcigtLWN5YW4pIj48L3NwYW4+4pyFIOC4quC4o+C5ieC4suC4h+C4quC4s+C5gOC4o+C5h+C4iDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJyZXN1bHQtYm9keSI+CiAgICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3dzIiBpZD0ic3NoLWluZm8tcm93cyI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2Pgo8L2Rpdj4KCjxkaXYgY2xhc3M9InRvYXN0IiBpZD0idG9hc3QiPjwvZGl2PgoKPHNjcmlwdCBzcmM9Imh0dHBzOi8vY2RuanMuY2xvdWRmbGFyZS5jb20vYWpheC9saWJzL3FyY29kZWpzLzEuMC4wL3FyY29kZS5taW4uanMiPjwvc2NyaXB0Pgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIiBvbmVycm9yPSJ3aW5kb3cuQ0hBSVlBX0NPTkZJRz17fSI+PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8qIOKUgOKUgCBDT05GSUcg4pSA4pSAICovCmNvbnN0IENGRyAgICAgPSAodHlwZW9mIHdpbmRvdy5DSEFJWUFfQ09ORklHICE9PSAndW5kZWZpbmVkJykgPyB3aW5kb3cuQ0hBSVlBX0NPTkZJRyA6IHt9Owpjb25zdCBIT1NUICAgID0gQ0ZHLmhvc3QgICAgfHwgbG9jYXRpb24uaG9zdG5hbWU7CmNvbnN0IFhVSV9BUEkgPSAnL3h1aS1hcGknOwpjb25zdCBTU0hfQVBJID0gJy9hcGknOwoKLyog4pSA4pSAIFNFU1NJT04gR1VBUkQg4pSA4pSAICovCihmdW5jdGlvbigpewogIGNvbnN0IHMgPSBzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKCdjaGFpeWFfYXV0aCcpOwogIGlmICghcykgeyB3aW5kb3cubG9jYXRpb24ucmVwbGFjZSgnU3lzdGVtbG9naW4uaHRtbCcpOyByZXR1cm47IH0KICB0cnkgewogICAgY29uc3QgZCA9IEpTT04ucGFyc2Uocyk7CiAgICBpZiAoIWQudXNlciB8fCAhZC5wYXNzIHx8IERhdGUubm93KCkgPj0gZC5leHApIHsKICAgICAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbSgnY2hhaXlhX2F1dGgnKTsKICAgICAgd2luZG93LmxvY2F0aW9uLnJlcGxhY2UoJ1N5c3RlbWxvZ2luLmh0bWwnKTsKICAgIH0gZWxzZSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0b3BiYXItdXNlcicpLnRleHRDb250ZW50ID0gZC51c2VyLnRvVXBwZXJDYXNlKCk7CiAgICB9CiAgfSBjYXRjaChlKSB7CiAgICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKCdjaGFpeWFfYXV0aCcpOwogICAgd2luZG93LmxvY2F0aW9uLnJlcGxhY2UoJ1N5c3RlbWxvZ2luLmh0bWwnKTsKICB9Cn0pKCk7CgpsZXQgX3h1aU9rID0gZmFsc2U7CmxldCBfYWxsVXNlcnMgPSBbXSwgX2ZpbHRlcmVkVXNlcnMgPSBbXTsKCi8qIOKUgOKUgCBDTE9DSyDilIDilIAgKi8KZnVuY3Rpb24gdXBkYXRlQ2xvY2soKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Nsb2NrLWRpc3BsYXknKS50ZXh0Q29udGVudCA9CiAgICBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKfQp1cGRhdGVDbG9jaygpOyBzZXRJbnRlcnZhbCh1cGRhdGVDbG9jaywgMTAwMCk7CgovKiDilIDilIAgVEFCIFNXSVRDSCDilIDilIAgKi8KZnVuY3Rpb24gc3dpdGNoVGFiKHRhYiwgYnRuKSB7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnRhYi1wYW5lbCcpLmZvckVhY2gocCA9PiBwLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcudGFiLWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLScgKyB0YWIpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChidG4pIGJ0bi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBpZiAodGFiID09PSAnZGFzaCcpICAgeyBsb2FkU3RhdHMoKTsgbG9hZFNlcnZpY2VTdGF0dXMoKTsgfQogIGlmICh0YWIgPT09ICdtYW5hZ2UnKSBsb2FkVXNlckxpc3QoKTsKICBpZiAodGFiID09PSAnb25saW5lJykgbG9hZE9ubGluZVVzZXJzKCk7Cn0KCi8qIOKUgOKUgCBNT0RBTCDilIDilIAgKi8KZnVuY3Rpb24gb3Blbk1vZGFsKGlkKSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC0nK2lkKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7IGRvY3VtZW50LmJvZHkuc3R5bGUub3ZlcmZsb3c9J2hpZGRlbic7IH0KZnVuY3Rpb24gY2xvc2VNb2RhbChpZCl7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC0nK2lkKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7IGRvY3VtZW50LmJvZHkuc3R5bGUub3ZlcmZsb3c9Jyc7IH0KZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm1vZGFsLW92ZXJsYXknKS5mb3JFYWNoKGVsID0+IHsKICBlbC5hZGRFdmVudExpc3RlbmVyKCdjbGljaycsIGUgPT4geyBpZihlLnRhcmdldD09PWVsKXsgZWwuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOyBkb2N1bWVudC5ib2R5LnN0eWxlLm92ZXJmbG93PScnOyB9IH0pOwp9KTsKCi8qIOKUgOKUgCBVVElMUyDilIDilIAgKi8KZnVuY3Rpb24gdmFsKGlkKXsgcmV0dXJuIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS52YWx1ZS50cmltKCk7IH0KZnVuY3Rpb24gc2V0QWxlcnQocHJlLCBtc2csIHR5cGUpewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQocHJlKyctYWxlcnQnKTsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQtbXNnICcgKyB0eXBlOyBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5zdHlsZS5kaXNwbGF5ID0gbXNnID8gJ2Jsb2NrJyA6ICdub25lJzsKfQpmdW5jdGlvbiB0b2FzdChtc2csIG9rPXRydWUpewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RvYXN0Jyk7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuYm9yZGVyQ29sb3IgPSBvayA/ICdyZ2JhKDUyLDIxMSwxNTMsLjQpJyA6ICdyZ2JhKDI0OCwxMTMsMTEzLC40KSc7CiAgZWwuY2xhc3NMaXN0LmFkZCgnc2hvdycpOyBzZXRUaW1lb3V0KCgpID0+IGVsLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKSwgMjQwMCk7Cn0KZnVuY3Rpb24gZ2VuVVVJRCgpewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csIGMgPT4gewogICAgY29uc3QgciA9IE1hdGgucmFuZG9tKCkqMTZ8MDsKICAgIHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3wweDgpKS50b1N0cmluZygxNik7CiAgfSk7Cn0KZnVuY3Rpb24gZm10Qnl0ZXMoYil7CiAgaWYoYj09PTApIHJldHVybiAnMCBCJzsKICBjb25zdCBrPTEwMjQscz1bJ0InLCdLQicsJ01CJywnR0InLCdUQiddOwogIGNvbnN0IGk9TWF0aC5mbG9vcihNYXRoLmxvZyhiKS9NYXRoLmxvZyhrKSk7CiAgcmV0dXJuIChiL01hdGgucG93KGssaSkpLnRvRml4ZWQoMSkrJyAnK3NbaV07Cn0KZnVuY3Rpb24gY2hpcChsYWJlbCl7IHJldHVybiBgPHNwYW4gc3R5bGU9ImRpc3BsYXk6aW5saW5lLWJsb2NrO2JhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMSk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6LjEycmVtIC40NXJlbTtmb250LWZhbWlseTonU2hhcmUgVGVjaCBNb25vJyxtb25vc3BhY2U7Zm9udC1zaXplOi42NXJlbTtjb2xvcjp2YXIoLS1zdWIpO21hcmdpbi1yaWdodDouMnJlbSI+JHtsYWJlbH08L3NwYW4+YDsgfQpmdW5jdGlvbiBjb3B5RWwoZWxJZCwgYnRuSWQpewogIGNvbnN0IHRleHQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChlbElkKS50ZXh0Q29udGVudC50cmltKCk7CiAgY29uc3QgZG9uZSA9ICgpID0+IHsKICAgIHRvYXN0KCfwn5OLIOC4hOC4seC4lOC4peC4reC4geC5geC4peC5ieC4pyEnKTsKICAgIGlmKGJ0bklkKXsKICAgICAgY29uc3QgYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGJ0bklkKTsKICAgICAgaWYoYil7IGNvbnN0IG89Yi50ZXh0Q29udGVudDsgYi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBiLmNsYXNzTGlzdC5hZGQoJ2NvcGllZCcpOyBzZXRUaW1lb3V0KCgpPT57Yi50ZXh0Q29udGVudD1vO2IuY2xhc3NMaXN0LnJlbW92ZSgnY29waWVkJyk7fSwyMDAwKTsgfQogICAgfQogIH07CiAgaWYobmF2aWdhdG9yLmNsaXBib2FyZCkgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodGV4dCkudGhlbihkb25lKS5jYXRjaCgoKT0+ZmJDb3B5KHRleHQsZG9uZSkpOwogIGVsc2UgZmJDb3B5KHRleHQsZG9uZSk7CiAgZnVuY3Rpb24gZmJDb3B5KHQsY2IpeyBjb25zdCB0YT1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCd0ZXh0YXJlYScpOyB0YS52YWx1ZT10OyB0YS5zdHlsZS5jc3NUZXh0PSdwb3NpdGlvbjpmaXhlZDt0b3A6MDtsZWZ0OjA7b3BhY2l0eTowOyc7IGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQodGEpOyB0YS5mb2N1cygpOyB0YS5zZWxlY3QoKTsgdHJ5e2RvY3VtZW50LmV4ZWNDb21tYW5kKCdjb3B5Jyk7Y2IoKTt9Y2F0Y2goZSl7dG9hc3QoJ+KdjCDguITguLHguJTguKXguK3guIHguYTguKHguYjguKrguLPguYDguKPguYfguIgnLGZhbHNlKTt9IGRvY3VtZW50LmJvZHkucmVtb3ZlQ2hpbGQodGEpOyB9Cn0KCi8qIOKUgOKUgCBYVUkgTE9HSU4g4pSA4pSAICovCmFzeW5jIGZ1bmN0aW9uIHh1aUxvZ2luKCl7CiAgbGV0IHVzZXI9Q0ZHLnh1aV91c2VyfHwnYWRtaW4nLCBwYXNzPUNGRy54dWlfcGFzc3x8Jyc7CiAgdHJ5ewogICAgY29uc3Qgcz1KU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oJ2NoYWl5YV9hdXRoJyl8fCd7fScpOwogICAgaWYocy51c2VyKSB1c2VyPXMudXNlcjsgaWYocy5wYXNzKSBwYXNzPXMucGFzczsKICB9Y2F0Y2goZSl7fQogIF94dWlPaz1mYWxzZTsKICBjb25zdCBmb3JtPW5ldyBVUkxTZWFyY2hQYXJhbXMoe3VzZXJuYW1lOnVzZXIscGFzc3dvcmQ6cGFzc30pOwogIGNvbnN0IHI9YXdhaXQgZmV0Y2goWFVJX0FQSSsnL2xvZ2luJyx7bWV0aG9kOidQT1NUJyxjcmVkZW50aWFsczonaW5jbHVkZScsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL3gtd3d3LWZvcm0tdXJsZW5jb2RlZCd9LGJvZHk6Zm9ybS50b1N0cmluZygpfSk7CiAgY29uc3QgZD1hd2FpdCByLmpzb24oKTsgX3h1aU9rPSEhZC5zdWNjZXNzOyByZXR1cm4gZC5zdWNjZXNzOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aUdldChwYXRoKXsgaWYoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsgY29uc3Qgcj1hd2FpdCBmZXRjaChYVUlfQVBJK3BhdGgse2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOyByZXR1cm4gci5qc29uKCk7IH0KYXN5bmMgZnVuY3Rpb24geHVpUG9zdChwYXRoLHBheWxvYWQpewogIGlmKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgY29uc3Qgcj1hd2FpdCBmZXRjaChYVUlfQVBJK3BhdGgse21ldGhvZDonUE9TVCcsY3JlZGVudGlhbHM6J2luY2x1ZGUnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeShwYXlsb2FkKX0pOwogIHJldHVybiByLmpzb24oKTsKfQoKLyog4pSA4pSAIFJJTkcgLyBCQVIg4pSA4pSAICovCmZ1bmN0aW9uIHNldFJpbmcoaWQscGN0LGNvbG9yKXsKICBjb25zdCBlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7IGlmKCFlbClyZXR1cm47CiAgY29uc3QgY2lyYz0xNTcuMTsKICBpZihjb2xvcikgZWwuc3R5bGUuc3Ryb2tlPWNvbG9yOwogIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQ9Y2lyYy0oY2lyYypNYXRoLm1pbihwY3QsMTAwKS8xMDApOwp9CmZ1bmN0aW9uIHNldEJhcihpZCxwY3QpeyBjb25zdCBlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7IGlmKGVsKSBlbC5zdHlsZS53aWR0aD1NYXRoLm1pbihwY3QsMTAwKSsnJSc7IH0KZnVuY3Rpb24gYmFyQ29sb3IocGN0KXsgcmV0dXJuIHBjdD44NT8nbGluZWFyLWdyYWRpZW50KDkwZGVnLCNkYzI2MjYsI2VmNDQ0NCknOnBjdD42NT8nbGluZWFyLWdyYWRpZW50KDkwZGVnLCNkOTc3MDYsI2Y1OWUwYiknOicnOyB9CgovKiDilIDilIAgTE9BRCBTVEFUUyDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gbG9hZFN0YXRzKCl7CiAgY29uc3QgYnRuPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyZWZyZXNoLWJ0bicpOwogIGlmKGJ0bikgYnRuLmNsYXNzTGlzdC5hZGQoJ3NwaW4nKTsKICB0cnl7CiAgICBjb25zdCBvaz1hd2FpdCB4dWlMb2dpbigpOwogICAgaWYoIW9rKXsgaWYoYnRuKWJ0bi5jbGFzc0xpc3QucmVtb3ZlKCdzcGluJyk7IHJldHVybjsgfQogICAgY29uc3Qgc3Y9YXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL3NlcnZlci9zdGF0dXMnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZihzdiYmc3Yuc3VjY2VzcyYmc3Yub2JqKXsKICAgICAgY29uc3Qgbz1zdi5vYmo7CiAgICAgIGNvbnN0IGNwdVBjdD1NYXRoLnJvdW5kKG8uY3B1fHwwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS12YWwnKS5pbm5lckhUTUw9YCR7Y3B1UGN0fTxzcGFuIGNsYXNzPSJzdGF0LXVuaXQiPiU8L3NwYW4+YDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1jb3JlcycpLnRleHRDb250ZW50PShvLmNwdUNvcmVzfHxvLmxvZ2ljYWxQcm98fCctLScpKycgY29yZXMnOwogICAgICBzZXRSaW5nKCdjcHUtcmluZycsY3B1UGN0LCcjYzA4NGZjJyk7IHNldEJhcignY3B1LWJhcicsY3B1UGN0KTsKICAgICAgY29uc3QgY2I9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1iYXInKTsgaWYoY2Ipe2NvbnN0IGM9YmFyQ29sb3IoY3B1UGN0KTtpZihjKWNiLnN0eWxlLmJhY2tncm91bmQ9Yzt9CiAgICAgIGNvbnN0IHJhbVQ9KChvLm1lbSYmby5tZW0udG90YWwpfHwwKS8xMDczNzQxODI0OwogICAgICBjb25zdCByYW1VPSgoby5tZW0mJm8ubWVtLmN1cnJlbnQpfHwwKS8xMDczNzQxODI0OwogICAgICBjb25zdCByYW1QY3Q9cmFtVD4wP01hdGgucm91bmQocmFtVS9yYW1UKjEwMCk6MDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS12YWwnKS5pbm5lckhUTUw9YCR7cmFtUGN0fTxzcGFuIGNsYXNzPSJzdGF0LXVuaXQiPiU8L3NwYW4+YDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1kZXRhaWwnKS50ZXh0Q29udGVudD1yYW1VLnRvRml4ZWQoMSkrJyAvICcrcmFtVC50b0ZpeGVkKDEpKycgR0InOwogICAgICBzZXRSaW5nKCdyYW0tcmluZycscmFtUGN0LCcjNjdlOGY5Jyk7IHNldEJhcigncmFtLWJhcicscmFtUGN0KTsKICAgICAgY29uc3QgcmI9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1iYXInKTsgaWYocmIpe2NvbnN0IGM9YmFyQ29sb3IocmFtUGN0KTtpZihjKXJiLnN0eWxlLmJhY2tncm91bmQ9Yzt9CiAgICAgIGNvbnN0IGRpc2tUPSgoby5kaXNrJiZvLmRpc2sudG90YWwpfHwwKS8xMDczNzQxODI0OwogICAgICBjb25zdCBkaXNrVT0oKG8uZGlzayYmby5kaXNrLmN1cnJlbnQpfHwwKS8xMDczNzQxODI0OwogICAgICBjb25zdCBkaXNrUGN0PWRpc2tUPjA/TWF0aC5yb3VuZChkaXNrVS9kaXNrVCoxMDApOjA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLXZhbCcpLmlubmVySFRNTD1gJHtkaXNrUGN0fTxzcGFuIGNsYXNzPSJzdGF0LXVuaXQiPiU8L3NwYW4+YDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stZGV0YWlsJykudGV4dENvbnRlbnQ9ZGlza1UudG9GaXhlZCgwKSsnIC8gJytkaXNrVC50b0ZpeGVkKDApKycgR0InOwogICAgICBzZXRCYXIoJ2Rpc2stYmFyJyxkaXNrUGN0KTsKICAgICAgY29uc3QgdXA9by51cHRpbWV8fDA7CiAgICAgIGNvbnN0IGQ9TWF0aC5mbG9vcih1cC84NjQwMCksaD1NYXRoLmZsb29yKCh1cCU4NjQwMCkvMzYwMCksbT1NYXRoLmZsb29yKCh1cCUzNjAwKS82MCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtdmFsJykudGV4dENvbnRlbnQ9ZD4wP2Ake2R9ZCAke2h9aGA6YCR7aH1oICR7bX1tYDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS1zdWInKS50ZXh0Q29udGVudD1gJHtkfSDguKfguLHguJkgJHtofSDguIrguLHguYjguKfguYLguKHguIcgJHttfSDguJnguLLguJfguLVgOwogICAgICBjb25zdCBsb2Fkcz1vLmxvYWRzfHxbXTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvYWQtY2hpcHMnKS5pbm5lckhUTUw9bG9hZHMubWFwKChsLGkpPT5bJzFtJywnNW0nLCcxNW0nXVtpXT9jaGlwKGAke1snMW0nLCc1bScsJzE1bSddW2ldfTogJHtsLnRvRml4ZWQoMil9YCk6JycpLmpvaW4oJycpOwogICAgICBjb25zdCBucz1vLm5ldElPfHxudWxsOwogICAgICBpZihucyl7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cCcpLnRleHRDb250ZW50PWZtdEJ5dGVzKG5zLnVwfHwwKSsnL3MnOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG93bicpLnRleHRDb250ZW50PWZtdEJ5dGVzKG5zLmRvd258fDApKycvcyc7CiAgICAgIH0KICAgICAgY29uc3QgbnQ9by5uZXRUcmFmZmljfHxudWxsOwogICAgICBpZihudCl7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cC10b3RhbCcpLnRleHRDb250ZW50PSd0b3RhbDogJytmbXRCeXRlcyhudC5zZW50fHwwKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRvd24tdG90YWwnKS50ZXh0Q29udGVudD0ndG90YWw6ICcrZm10Qnl0ZXMobnQucmVjdnx8MCk7CiAgICAgIH0KICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsYXN0LXVwZGF0ZScpLnRleHRDb250ZW50PSfguK3guLHguJvguYDguJTguJXguKXguYjguLLguKrguLjguJQ6ICcrbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgfWNhdGNoKGUpeyBjb25zb2xlLndhcm4oJ3N0YXRzIGVycm9yJyxlKTsgfQogIGZpbmFsbHl7IGlmKGJ0bilidG4uY2xhc3NMaXN0LnJlbW92ZSgnc3BpbicpOyB9Cn0KCi8qIOKUgOKUgCBTRVJWSUNFIFNUQVRVUyDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gbG9hZFNlcnZpY2VTdGF0dXMoKXsKICBjb25zdCBncmlkPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtZ3JpZCcpOwogIGNvbnN0IFNFUlZJQ0VTPVsKICAgIHtuYW1lOid4LXVpIFBhbmVsJywgICAgIGljb246J/CflqUnLCAgcG9ydHM6JzoyMDUzJywga2V5Oid4dWknfSwKICAgIHtuYW1lOidQeXRob24gU1NIIEFQSScsIGljb246J/CfkI0nLCAgcG9ydHM6Jzo2Nzg5Jywga2V5Oidzc2gnfSwKICAgIHtuYW1lOidEcm9wYmVhciBTU0gnLCAgIGljb246J/CfkLsnLCAgcG9ydHM6JzoxNDMgOjEwOScsIGtleTonZHJvcGJlYXInfSwKICAgIHtuYW1lOiduZ2lueCAvIFdTJywgICAgIGljb246J/CfjJAnLCAgcG9ydHM6Jzo4MCA6NDQzJywga2V5OiduZ2lueCd9LAogICAge25hbWU6J1NTSC1XUy1TU0wnLCAgICAgaWNvbjon8J+UkicsICBwb3J0czonOjQ0MycsICBrZXk6J3NzaHdzJ30sCiAgICB7bmFtZTonYmFkdnBuIFVEUC1HVycsICBpY29uOifwn46uJywgIHBvcnRzOic6NzMwMCcsIGtleTonYmFkdnBuJ30sCiAgXTsKICBncmlkLmlubmVySFRNTD1TRVJWSUNFUy5tYXAocz0+YAogICAgPGRpdiBjbGFzcz0ic3ZjLXJvdyIgaWQ9InN2Yy0ke3Mua2V5fSI+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1kb3QgY2hlY2tpbmciPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtaWNvbiI+JHtzLmljb259PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1uYW1lIj4ke3MubmFtZX08L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3ZjLXBvcnRzIj4ke3MucG9ydHN9PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1iYWRnZSBjaGVja2luZyIgaWQ9InN2Yy1jaGlwLSR7cy5rZXl9Ij7guJXguKPguKfguIjguKrguK3guJouLi48L2Rpdj4KICAgIDwvZGl2PmApLmpvaW4oJycpOwogIHRyeXsKICAgIGNvbnN0IHI9YXdhaXQgZmV0Y2goU1NIX0FQSSsnL3N0YXR1cycpOwogICAgY29uc3QgZD1hd2FpdCByLmpzb24oKTsKICAgIGNvbnN0IHN2Y01hcD1kLnNlcnZpY2VzfHx7fTsKICAgIFNFUlZJQ0VTLmZvckVhY2gocz0+ewogICAgICBjb25zdCB1cD1zdmNNYXBbcy5rZXldPT09dHJ1ZXx8c3ZjTWFwW3Mua2V5XT09PSdhY3RpdmUnOwogICAgICBjb25zdCByb3c9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy0nK3Mua2V5KTsKICAgICAgY29uc3QgY2hpcD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWNoaXAtJytzLmtleSk7CiAgICAgIGNvbnN0IGRvdD1yb3c/cm93LnF1ZXJ5U2VsZWN0b3IoJy5zdmMtZG90Jyk6bnVsbDsKICAgICAgaWYocm93KSByb3cuY2xhc3NOYW1lPSdzdmMtcm93ICcrKHVwPyd1cCc6J2Rvd24nKTsKICAgICAgaWYoZG90KSBkb3QuY2xhc3NOYW1lPSdzdmMtZG90ICcrKHVwPyd1cCc6J2Rvd24nKTsKICAgICAgaWYoY2hpcCl7IGNoaXAuY2xhc3NOYW1lPSdzdmMtYmFkZ2UgJysodXA/J3VwJzonZG93bicpOyBjaGlwLnRleHRDb250ZW50PXVwPydSVU5OSU5HJzonRE9XTic7IH0KICAgIH0pOwogIH1jYXRjaChlKXsKICAgIFNFUlZJQ0VTLmZvckVhY2gocz0+ewogICAgICBjb25zdCBjaGlwPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtY2hpcC0nK3Mua2V5KTsKICAgICAgaWYoY2hpcCl7IGNoaXAuY2xhc3NOYW1lPSdzdmMtYmFkZ2UgZG93bic7IGNoaXAudGV4dENvbnRlbnQ9J0VSUk9SJzsgfQogICAgfSk7CiAgfQp9CgovKiDilIDilIAgQ1JFQVRFIEFJUyDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gY3JlYXRlQUlTKCl7CiAgY29uc3QgZW1haWw9dmFsKCdhaXMtZW1haWwnKSwgZGF5cz1wYXJzZUludCh2YWwoJ2Fpcy1kYXlzJykpfHwzMDsKICBjb25zdCBpcExpbWl0PXBhcnNlSW50KHZhbCgnYWlzLWlwbGltaXQnKSl8fDIsIGdiPXBhcnNlSW50KHZhbCgnYWlzLWdiJykpfHwwOwogIGlmKCFlbWFpbCkgcmV0dXJuIHNldEFsZXJ0KCdhaXMnLCfguIHguKPguLjguJPguLLguYPguKrguYjguIrguLfguYjguK3guJzguLnguYnguYPguIrguYknLCdlcnInKTsKICBjb25zdCBidG49ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fpcy1zdWJtaXQnKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9InNwaW5uZXIiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIHNldEFsZXJ0KCdhaXMnLCcnLCcnKTsKICB0cnl7CiAgICBjb25zdCBvaz1hd2FpdCB4dWlMb2dpbigpOyBpZighb2spIHRocm93IG5ldyBFcnJvcignTG9naW4geC11aSDguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIGNvbnN0IGxpc3Q9YXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliPShsaXN0Lm9ianx8W10pLmZpbmQoeD0+eC5wb3J0PT09ODA4MCk7CiAgICBpZighaWIpIHRocm93IG5ldyBFcnJvcign4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCA4MDgwIOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZJyk7CiAgICBjb25zdCB1aWQ9Z2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXM9ZGF5cz4wPyhEYXRlLm5vdygpK2RheXMqODY0MDAwMDApOjA7CiAgICBjb25zdCB0b3RhbEJ5dGVzPWdiPjA/Z2IqMTA3Mzc0MTgyNDowOwogICAgY29uc3QgcmVzPWF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50Jyx7CiAgICAgIGlkOmliLmlkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOnVpZCxmbG93OicnLGVtYWlsLGxpbWl0SXA6aXBMaW1pdCx0b3RhbEdCOnRvdGFsQnl0ZXMsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C4quC4o+C5ieC4suC4h+C4muC4seC4jeC4iuC4teC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgY29uc3Qgc25pPSdjai1lYmIuc3BlZWR0ZXN0Lm5ldCc7CiAgICBjb25zdCB2bGVzc0xpbms9YHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06ODA4MD90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChlbWFpbCsnLUFJUycpfWA7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLWluZm8tcm93cycpLmlubmVySFRNTD1gCiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPkVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+JHtlbWFpbH08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPlVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIiBzdHlsZT0iZm9udC1zaXplOi42cmVtO2ZvbnQtZmFtaWx5OidTaGFyZSBUZWNoIE1vbm8nLG1vbm9zcGFjZSI+JHt1aWR9PC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5Qb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+ODA4MDwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+JHtkYXlzfSDguKfguLHguJk8L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPklQIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+JHtpcExpbWl0fSBJUHM8L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPuC4guC5ieC4reC4oeC4ueC4pTwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiPiR7Z2I+MD9nYisnIEdCJzon4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJ308L3NwYW4+PC9kaXY+YDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtdmxlc3MtbGluaycpLnRleHRDb250ZW50PXZsZXNzTGluazsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtcXInKS5pbm5lckhUTUw9Jyc7CiAgICBuZXcgUVJDb2RlKGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtcXInKSx7dGV4dDp2bGVzc0xpbmssd2lkdGg6MTc1LGhlaWdodDoxNzV9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtcmVzdWx0JykuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgc2V0QWxlcnQoJ2FpcycsJ+KchSDguKrguKPguYnguLLguIfguJrguLHguI3guIrguLUgQUlTIOC4quC4s+C5gOC4o+C5h+C4iCEnLCdvaycpOwogICAgdG9hc3QoJ+KchSDguKrguKPguYnguLLguIfguJrguLHguI3guIrguLUgQUlTIOC4quC4s+C5gOC4o+C5h+C4iCEnKTsKICB9Y2F0Y2goZSl7IHNldEFsZXJ0KCdhaXMnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseXsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfimqEg4Liq4Lij4LmJ4Liy4LiH4Lia4Lix4LiN4LiK4Li1IEFJUyc7IH0KfQoKLyog4pSA4pSAIENSRUFURSBUUlVFIOKUgOKUgCAqLwphc3luYyBmdW5jdGlvbiBjcmVhdGVUUlVFKCl7CiAgY29uc3QgZW1haWw9dmFsKCd0cnVlLWVtYWlsJyksIGRheXM9cGFyc2VJbnQodmFsKCd0cnVlLWRheXMnKSl8fDMwOwogIGNvbnN0IGlwTGltaXQ9cGFyc2VJbnQodmFsKCd0cnVlLWlwbGltaXQnKSl8fDIsIGdiPXBhcnNlSW50KHZhbCgndHJ1ZS1nYicpKXx8MDsKICBpZighZW1haWwpIHJldHVybiBzZXRBbGVydCgndHJ1ZScsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iOC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iScsJ2VycicpOwogIGNvbnN0IGJ0bj1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndHJ1ZS1zdWJtaXQnKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9InNwaW5uZXIiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIHNldEFsZXJ0KCd0cnVlJywnJywnJyk7CiAgdHJ5ewogICAgY29uc3Qgb2s9YXdhaXQgeHVpTG9naW4oKTsgaWYoIW9rKSB0aHJvdyBuZXcgRXJyb3IoJ0xvZ2luIHgtdWkg4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBjb25zdCBsaXN0PWF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0Jyk7CiAgICBjb25zdCBpYj0obGlzdC5vYmp8fFtdKS5maW5kKHg9PngucG9ydD09PTg4ODApOwogICAgaWYoIWliKSB0aHJvdyBuZXcgRXJyb3IoJ+C5hOC4oeC5iOC4nuC4miBpbmJvdW5kIHBvcnQgODg4MCDigJQg4Lij4Lix4LiZIHNldHVwIOC4geC5iOC4reC4mScpOwogICAgY29uc3QgdWlkPWdlblVVSUQoKTsKICAgIGNvbnN0IGV4cE1zPWRheXM+MD8oRGF0ZS5ub3coKStkYXlzKjg2NDAwMDAwKTowOwogICAgY29uc3QgdG90YWxCeXRlcz1nYj4wP2diKjEwNzM3NDE4MjQ6MDsKICAgIGNvbnN0IHJlcz1hd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL2FkZENsaWVudCcsewogICAgICBpZDppYi5pZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDp1aWQsZmxvdzonJyxlbWFpbCxsaW1pdElwOmlwTGltaXQsdG90YWxHQjp0b3RhbEJ5dGVzLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguKrguKPguYnguLLguIfguJrguLHguI3guIrguLXguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIGNvbnN0IHNuaT0ndHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlcyc7CiAgICBjb25zdCB2bGVzc0xpbms9YHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06ODg4MD90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChlbWFpbCsnLVRSVUUnKX1gOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtaW5mby1yb3dzJykuaW5uZXJIVE1MPWAKICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+RW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke2VtYWlsfTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+VVVJRDwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiIHN0eWxlPSJmb250LXNpemU6LjZyZW07Zm9udC1mYW1pbHk6J1NoYXJlIFRlY2ggTW9ubycsbW9ub3NwYWNlIj4ke3VpZH08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPlBvcnQ8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj44ODgwPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij7guK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke2RheXN9IOC4p+C4seC4mTwvc3Bhbj48L2Rpdj5gOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtdmxlc3MtbGluaycpLnRleHRDb250ZW50PXZsZXNzTGluazsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0cnVlLXFyJykuaW5uZXJIVE1MPScnOwogICAgbmV3IFFSQ29kZShkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndHJ1ZS1xcicpLHt0ZXh0OnZsZXNzTGluayx3aWR0aDoxNzUsaGVpZ2h0OjE3NX0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtcmVzdWx0JykuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgc2V0QWxlcnQoJ3RydWUnLCfinIUg4Liq4Lij4LmJ4Liy4LiH4Lia4Lix4LiN4LiK4Li1IFRSVUUg4Liq4Liz4LmA4Lij4LmH4LiIIScsJ29rJyk7CiAgICB0b2FzdCgn4pyFIOC4quC4o+C5ieC4suC4h+C4muC4seC4jeC4iuC4tSBUUlVFIOC4quC4s+C5gOC4o+C5h+C4iCEnKTsKICB9Y2F0Y2goZSl7IHNldEFsZXJ0KCd0cnVlJywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHl7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4pqhIOC4quC4o+C5ieC4suC4h+C4muC4seC4jeC4iuC4tSBUUlVFJzsgfQp9CgovKiDilIDilIAgQ1JFQVRFIFNTSCDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCl7CiAgY29uc3QgdXNlcj12YWwoJ3NzaC11c2VyJyksIHBhc3M9dmFsKCdzc2gtcGFzcycpOwogIGNvbnN0IGRheXM9cGFyc2VJbnQodmFsKCdzc2gtZGF5cycpKXx8MzA7CiAgaWYoIXVzZXIpIHJldHVybiBzZXRBbGVydCgnc3NoJywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYoIXBhc3MpIHJldHVybiBzZXRBbGVydCgnc3NoJywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3JkJywnZXJyJyk7CiAgY29uc3QgYnRuPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtc3VibWl0Jyk7CiAgYnRuLmRpc2FibGVkPXRydWU7IGJ0bi5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJzcGlubmVyIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBzZXRBbGVydCgnc3NoJywnJywnJyk7CiAgdHJ5ewogICAgY29uc3Qgcj1hd2FpdCBmZXRjaChTU0hfQVBJKycvY3JlYXRlX3NzaCcse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyLHBhc3N3b3JkOnBhc3MsZGF5c30pfSk7CiAgICBjb25zdCBkPWF3YWl0IHIuanNvbigpOwogICAgaWYoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yfHwn4Liq4Lij4LmJ4Liy4LiH4Lia4Lix4LiN4LiK4Li14LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWluZm8tcm93cycpLmlubmVySFRNTD1gCiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPlVzZXJuYW1lPC9zcGFuPjxzcGFuIGNsYXNzPSJpbmZvLXZhbCI+JHt1c2VyfTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+UGFzc3dvcmQ8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIHBhc3MiPiR7cGFzc308L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImluZm8tcm93Ij48c3BhbiBjbGFzcz0iaW5mby1rZXkiPkhvc3Q8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke0hPU1R9PC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij5Qb3J0IFNTSDwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiPjE0MyAvIDEwOTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5mby1yb3ciPjxzcGFuIGNsYXNzPSJpbmZvLWtleSI+UG9ydCBXUzwvc3Bhbj48c3BhbiBjbGFzcz0iaW5mby12YWwiPjgwPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbmZvLXJvdyI+PHNwYW4gY2xhc3M9ImluZm8ta2V5Ij7guKfguLHguJnguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImluZm8tdmFsIj4ke2QuZXhwfTwvc3Bhbj48L2Rpdj5gOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZXN1bHQnKS5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7CiAgICBzZXRBbGVydCgnc3NoJywn4pyFIOC4quC4o+C5ieC4suC4h+C4muC4seC4jeC4iuC4tSBTU0gg4Liq4Liz4LmA4Lij4LmH4LiIIScsJ29rJyk7CiAgICB0b2FzdCgn4pyFIOC4quC4o+C5ieC4suC4h+C4muC4seC4jeC4iuC4tSBTU0gg4Liq4Liz4LmA4Lij4LmH4LiIIScpOwogIH1jYXRjaChlKXsgc2V0QWxlcnQoJ3NzaCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5eyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KaoSDguKrguKPguYnguLLguIfguJrguLHguI3guIrguLUgU1NIJzsgfQp9CgovKiDilIDilIAgVVNFUiBMSVNUIOKUgOKUgCAqLwphc3luYyBmdW5jdGlvbiBsb2FkVXNlckxpc3QoKXsKICBjb25zdCBsaXN0PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKTsKICBsaXN0LmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZy1yb3ciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5ewogICAgY29uc3Qgb2s9YXdhaXQgeHVpTG9naW4oKTsgaWYoIW9rKSB0aHJvdyBuZXcgRXJyb3IoJ0xvZ2luIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgY29uc3QgZD1hd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYoIWQuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKCfguYLguKvguKXguJTguILguYnguK3guKHguLnguKXguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIF9hbGxVc2Vycz1bXTsKICAgIChkLm9ianx8W10pLmZvckVhY2goaWI9PnsKICAgICAgY29uc3Qgc2V0dGluZ3M9dHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZyc/SlNPTi5wYXJzZShpYi5zZXR0aW5ncyk6aWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjPT57CiAgICAgICAgX2FsbFVzZXJzLnB1c2goe2luYm91bmRJZDppYi5pZCxpbmJvdW5kUG9ydDppYi5wb3J0LHByb3RvY29sOmliLnByb3RvY29sLGVtYWlsOmMuZW1haWx8fGMuaWQsdXVpZDpjLmlkLGV4cGlyeVRpbWU6Yy5leHBpcnlUaW1lfHwwLGVuYWJsZTpjLmVuYWJsZSE9PWZhbHNlfSk7CiAgICAgIH0pOwogICAgfSk7CiAgICBfZmlsdGVyZWRVc2Vycz1bLi4uX2FsbFVzZXJzXTsKICAgIHJlbmRlclVzZXJMaXN0KF9maWx0ZXJlZFVzZXJzKTsKICB9Y2F0Y2goZSl7IGxpc3QuaW5uZXJIVE1MPWA8ZGl2IGNsYXNzPSJlbXB0eS1zdGF0ZSI+PGRpdiBjbGFzcz0iZWkiPuKaoO+4jzwvZGl2PjxkaXY+JHtlLm1lc3NhZ2V9PC9kaXY+PC9kaXY+YDsgfQp9CgpmdW5jdGlvbiByZW5kZXJVc2VyTGlzdCh1c2Vycyl7CiAgY29uc3QgbGlzdD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0Jyk7CiAgaWYoIXVzZXJzLmxlbmd0aCl7IGxpc3QuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJlbXB0eS1zdGF0ZSI+PGRpdiBjbGFzcz0iZWkiPvCfk608L2Rpdj48ZGl2PuC5hOC4oeC5iOC4oeC4teC4nOC4ueC5ieC5g+C4iuC5iTwvZGl2PjwvZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdz1EYXRlLm5vdygpOwogIGxpc3QuaW5uZXJIVE1MPXVzZXJzLm1hcCh1PT57CiAgICBjb25zdCBpc0Fpcz11LmluYm91bmRQb3J0PT09ODA4MDsKICAgIGNvbnN0IGlzU1NIPXUucHJvdG9jb2w9PT0nbm9uZSd8fHUuaW5ib3VuZFBvcnQ9PT0yMjsKICAgIGxldCBzdGF0dXNIdG1sPScnLCBleHBTdHI9Jyc7CiAgICBpZih1LmV4cGlyeVRpbWU9PT0wKXsgZXhwU3RyPSfguYTguKHguYjguIjguLPguIHguLHguJQnOyBzdGF0dXNIdG1sPSc8c3BhbiBjbGFzcz0ic3RhdHVzLWJhZGdlIHN0YXR1cy1vayI+4pyTIEFjdGl2ZTwvc3Bhbj4nOyB9CiAgICBlbHNlewogICAgICBjb25zdCBkaWZmPXUuZXhwaXJ5VGltZS1ub3csIGRheXM9TWF0aC5jZWlsKGRpZmYvODY0MDAwMDApOwogICAgICBpZihkaWZmPDApeyBleHBTdHI9J+C4q+C4oeC4lOC4reC4suC4ouC4uOC5geC4peC5ieC4pyc7IHN0YXR1c0h0bWw9JzxzcGFuIGNsYXNzPSJzdGF0dXMtYmFkZ2Ugc3RhdHVzLWRlYWQiPuKclyBFeHBpcmVkPC9zcGFuPic7IH0KICAgICAgZWxzZSBpZihkYXlzPD0zKXsgZXhwU3RyPWDguYDguKvguKXguLfguK0gJHtkYXlzfSDguKfguLHguJlgOyBzdGF0dXNIdG1sPWA8c3BhbiBjbGFzcz0ic3RhdHVzLWJhZGdlIHN0YXR1cy1leHAiPuKaoCAke2RheXN9ZDwvc3Bhbj5gOyB9CiAgICAgIGVsc2V7IGV4cFN0cj1gJHtkYXlzfSDguKfguLHguJlgOyBzdGF0dXNIdG1sPSc8c3BhbiBjbGFzcz0ic3RhdHVzLWJhZGdlIHN0YXR1cy1vayI+4pyTIEFjdGl2ZTwvc3Bhbj4nOyB9CiAgICB9CiAgICBjb25zdCBjbHM9aXNTU0g/J3VhLXNzaCc6aXNBaXM/J3VhLWFpcyc6J3VhLXRydWUnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1c2VyLXJvdyI+CiAgICAgIDxkaXYgY2xhc3M9InVzZXItYXZhdGFyICR7Y2xzfSI+JHsodS5lbWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ1c2VyLWluZm8iPgogICAgICAgIDxkaXYgY2xhc3M9InVzZXItbmFtZSI+JHt1LmVtYWlsfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InVzZXItbWV0YSI+UG9ydCAke3UuaW5ib3VuZFBvcnR9IMK3ICR7ZXhwU3RyfTwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgJHtzdGF0dXNIdG1sfQogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQoKZnVuY3Rpb24gZmlsdGVyVXNlcnMocSl7CiAgY29uc3Qgcz1xLnRvTG93ZXJDYXNlKCk7CiAgX2ZpbHRlcmVkVXNlcnM9X2FsbFVzZXJzLmZpbHRlcih1PT4odS5lbWFpbHx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocykpOwogIHJlbmRlclVzZXJMaXN0KF9maWx0ZXJlZFVzZXJzKTsKfQoKLyog4pSA4pSAIE9OTElORSBVU0VSUyDilIDilIAgKi8KYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZVVzZXJzKCl7CiAgY29uc3QgYnRuPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtcmVmcmVzaCcpOwogIGlmKGJ0bikgYnRuLmNsYXNzTGlzdC5hZGQoJ3NwaW4nKTsKICBjb25zdCBsaXN0PWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpOwogIGxpc3QuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nLXJvdyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnl7CiAgICBjb25zdCBvaz1hd2FpdCB4dWlMb2dpbigpOyBpZighb2spIHRocm93IG5ldyBFcnJvcignTG9naW4g4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBjb25zdCBvZD1hd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvb25saW5lcycpLmNhdGNoKCgpPT5udWxsKTsKICAgIGNvbnN0IG9ubGluZUVtYWlscz0ob2QmJm9kLm9iaik/b2Qub2JqOltdOwogICAgaWYoIV9hbGxVc2Vycy5sZW5ndGgpIGF3YWl0IGxvYWRVc2VyTGlzdCgpLmNhdGNoKCgpPT57fSk7CiAgICBjb25zdCB1c2VyTWFwPXt9OwogICAgX2FsbFVzZXJzLmZvckVhY2godT0+eyB1c2VyTWFwW3UuZW1haWxdPXU7IH0pOwogICAgaWYoIW9ubGluZUVtYWlscy5sZW5ndGgpewogICAgICBsaXN0LmlubmVySFRNTD0nPGRpdiBjbGFzcz0iZW1wdHktc3RhdGUiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PGRpdj7guYTguKHguYjguKHguLXguJzguLnguYnguYPguIrguYnguK3guK3guJnguYTguKXguJnguYw8L2Rpdj48L2Rpdj4nOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBub3c9RGF0ZS5ub3coKTsKICAgIGxpc3QuaW5uZXJIVE1MPW9ubGluZUVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdT11c2VyTWFwW2VtYWlsXXx8bnVsbDsKICAgICAgY29uc3QgaXNBaXM9dSYmdS5pbmJvdW5kUG9ydD09PTgwODA7CiAgICAgIGxldCBleHBMYWJlbD0n4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJywgZXhwQ29sb3I9J3ZhcigtLWdyZWVuKSc7CiAgICAgIGlmKHUmJnUuZXhwaXJ5VGltZT4wKXsKICAgICAgICBjb25zdCBkaWZmPXUuZXhwaXJ5VGltZS1ub3csIGQ9TWF0aC5jZWlsKGRpZmYvODY0MDAwMDApOwogICAgICAgIGV4cExhYmVsPWRpZmY8MD8n4Lir4Lih4LiU4Lit4Liy4Lii4Li44LmB4Lil4LmJ4LinJzpgJHtkfSDguKfguLHguJlgOwogICAgICAgIGV4cENvbG9yPWRpZmY8MD8ndmFyKC0tcmVkKSc6ZDw9Mz8ndmFyKC0teWVsbG93KSc6J3ZhcigtLWdyZWVuKSc7CiAgICAgIH0KICAgICAgY29uc3QgY2xzPWlzQWlzPyd1YS1haXMnOid1YS10cnVlJzsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1c2VyLXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0idXNlci1hdmF0YXIgJHtjbHN9Ij4keyhlbWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InVzZXItaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1c2VyLW5hbWUiPiR7ZW1haWx9IDxzcGFuIHN0eWxlPSJmb250LXNpemU6LjZyZW07YmFja2dyb3VuZDpyZ2JhKDEwMywyMzIsMjQ5LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTAzLDIzMiwyNDksLjI1KTtjb2xvcjp2YXIoLS1jeWFuKTtwYWRkaW5nOi4xcmVtIC40cmVtO2JvcmRlci1yYWRpdXM6MjBweDtmb250LWZhbWlseTonU2hhcmUgVGVjaCBNb25vJyxtb25vc3BhY2UiPiR7dT8nUG9ydCAnK3UuaW5ib3VuZFBvcnQ6J1ZMRVNTJ308L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1c2VyLW1ldGEiIHN0eWxlPSJjb2xvcjoke2V4cENvbG9yfSI+8J+ThSAke2V4cExhYmVsfTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Im9ubGluZS1kb3QiPjwvZGl2PgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfWNhdGNoKGUpewogICAgbGlzdC5pbm5lckhUTUw9YDxkaXYgY2xhc3M9ImVtcHR5LXN0YXRlIj48ZGl2IGNsYXNzPSJlaSI+4pqg77iPPC9kaXY+PGRpdj4ke2UubWVzc2FnZX08L2Rpdj48L2Rpdj5gOwogIH1maW5hbGx5ewogICAgaWYoYnRuKSBidG4uY2xhc3NMaXN0LnJlbW92ZSgnc3BpbicpOwogIH0KfQoKLyog4pSA4pSAIExPR09VVCDilIDilIAgKi8KZnVuY3Rpb24gZG9Mb2dvdXQoKXsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKCdjaGFpeWFfYXV0aCcpOwogIHdpbmRvdy5sb2NhdGlvbi5yZXBsYWNlKCdTeXN0ZW1sb2dpbi5odG1sJyk7Cn0KCgovKiDilIDilIAgUkVBTFRJTUUgUE9MTElORyDilIDilIAgKi8KbGV0IF9ydEFjdGl2ZSA9IGZhbHNlOwpsZXQgX3J0VGltZXIgPSBudWxsOwpsZXQgX3J0RmFpbHMgPSAwOwoKZnVuY3Rpb24gc3RhcnRSZWFsdGltZSgpIHsKICBpZiAoX3J0QWN0aXZlKSByZXR1cm47CiAgX3J0QWN0aXZlID0gdHJ1ZTsKICBfcnRGYWlscyA9IDA7CiAgcnRUaWNrKCk7Cn0KCmFzeW5jIGZ1bmN0aW9uIHJ0VGljaygpIHsKICBpZiAoIV9ydEFjdGl2ZSkgcmV0dXJuOwogIHRyeSB7CiAgICAvLyBwb2xsIFNTSCBBUEkg4Liq4LiW4Liy4LiZ4LiwIHNlcnZpY2UKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChTU0hfQVBJICsgJy9zdGF0dXMnLCB7IHNpZ25hbDogQWJvcnRTaWduYWwudGltZW91dCgzMDAwKSB9KTsKICAgIGlmIChyLm9rKSB7CiAgICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgICAgdXBkYXRlU2VydmljZURvdHMoZC5zZXJ2aWNlcyB8fCB7fSk7CiAgICAgIF9ydEZhaWxzID0gMDsKICAgICAgc2V0QmFkZ2UodHJ1ZSk7CiAgICB9CiAgfSBjYXRjaChlKSB7CiAgICBfcnRGYWlscysrOwogICAgaWYgKF9ydEZhaWxzID4gMykgc2V0QmFkZ2UoZmFsc2UpOwogIH0KICBfcnRUaW1lciA9IHNldFRpbWVvdXQocnRUaWNrLCA1MDAwKTsKfQoKZnVuY3Rpb24gc2V0QmFkZ2UobGl2ZSkgewogIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncnQtYmFkZ2UnKTsKICBpZiAoIWIpIHJldHVybjsKICBpZiAobGl2ZSkgewogICAgYi5zdHlsZS5iYWNrZ3JvdW5kID0gJyNkY2ZjZTcnOyBiLnN0eWxlLmJvcmRlckNvbG9yID0gJyM4NmVmYWMnOyBiLnN0eWxlLmNvbG9yID0gJyMxNjY1MzQnOwogICAgYi5pbm5lckhUTUwgPSAnPHNwYW4gc3R5bGU9IndpZHRoOjZweDtoZWlnaHQ6NnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTthbmltYXRpb246cHVsc2UgMnMgaW5maW5pdGU7ZmxleC1zaHJpbms6MCI+PC9zcGFuPkxJVkUnOwogIH0gZWxzZSB7CiAgICBiLnN0eWxlLmJhY2tncm91bmQgPSAnI2ZlZjJmMic7IGIuc3R5bGUuYm9yZGVyQ29sb3IgPSAnI2ZjYTVhNSc7IGIuc3R5bGUuY29sb3IgPSAnIzk5MWIxYic7CiAgICBiLmlubmVySFRNTCA9ICc8c3BhbiBzdHlsZT0id2lkdGg6NnB4O2hlaWdodDo2cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2ZsZXgtc2hyaW5rOjAiPjwvc3Bhbj5PRkZMSU5FJzsKICB9Cn0KCmZ1bmN0aW9uIHVwZGF0ZVNlcnZpY2VEb3RzKHN2Y01hcCkgewogIGNvbnN0IEtFWVMgPSBbJ3h1aScsJ3NzaCcsJ2Ryb3BiZWFyJywnbmdpbngnLCdzc2h3cycsJ2JhZHZwbiddOwogIEtFWVMuZm9yRWFjaChrZXkgPT4gewogICAgY29uc3QgdXAgPSBzdmNNYXBba2V5XSA9PT0gdHJ1ZSB8fCBzdmNNYXBba2V5XSA9PT0gJ2FjdGl2ZSc7CiAgICBjb25zdCByb3cgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy0nICsga2V5KTsKICAgIGNvbnN0IGNoaXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWNoaXAtJyArIGtleSk7CiAgICBjb25zdCBkb3QgID0gcm93ID8gcm93LnF1ZXJ5U2VsZWN0b3IoJy5zdmMtZG90JykgOiBudWxsOwogICAgaWYgKHJvdykgIHJvdy5jbGFzc05hbWUgID0gJ3N2Yy1yb3cgJyAgKyAodXAgPyAndXAnIDogJ2Rvd24nKTsKICAgIGlmIChkb3QpICBkb3QuY2xhc3NOYW1lICA9ICdzdmMtZG90ICcgICsgKHVwID8gJ3VwJyA6ICdkb3duJyk7CiAgICBpZiAoY2hpcCkgeyBjaGlwLmNsYXNzTmFtZSA9ICdzdmMtY2hpcCAnICsgKHVwID8gJ3VwJyA6ICdkb3duJyk7IGNoaXAudGV4dENvbnRlbnQgPSB1cCA/ICdSVU5OSU5HJyA6ICdET1dOJzsgfQogIH0pOwp9CgoKLyog4pSA4pSAIElOSVQg4pSA4pSAICovCndpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdsb2FkJywgKCkgPT4gewogIF94dWlPaz1mYWxzZTsKICBsb2FkU3RhdHMoKTsKICBsb2FkU2VydmljZVN0YXR1cygpOwogIHNldEludGVydmFsKCgpPT57CiAgICBpZihkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLWRhc2gnKS5jbGFzc0xpc3QuY29udGFpbnMoJ2FjdGl2ZScpKXsKICAgICAgbG9hZFN0YXRzKCk7IGxvYWRTZXJ2aWNlU3RhdHVzKCk7CiAgICB9CiAgfSwgNTAwMCk7CiAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigndmlzaWJpbGl0eWNoYW5nZScsKCk9PnsKICAgIGlmKGRvY3VtZW50LnZpc2liaWxpdHlTdGF0ZT09PSd2aXNpYmxlJyl7IF94dWlPaz1mYWxzZTsgbG9hZFN0YXRzKCk7IGxvYWRTZXJ2aWNlU3RhdHVzKCk7IH0KICB9KTsKfSk7Cjwvc2NyaXB0Pgo8L2JvZHk+CjwvaHRtbD4K' | base64 -d > /opt/chaiya-panel/dashboard.html
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
