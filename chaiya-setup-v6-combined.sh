#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL v5 + PATCH (Combined)
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-setup-v5-combined.sh
#   แก้ทุกปัญหาจาก v4:
#   - nginx ไม่ชนกัน (port แยกชัดเจน ไม่มี SSL block ถ้าไม่มี cert)
#   - dashboard auto-login ทุกครั้งที่โหลด ไม่ง้อ sessionStorage
#   - บันทึก xui credentials ลง config.js ให้ถูกต้อง
# ============================================================

# ── SELF-SAVE GUARD ──────────────────────────────────────────
# ป้องกัน heredoc truncation เมื่อรันผ่าน bash <(curl ...) / curl | bash / wget -O- | bash
# อ่าน script จาก fd ทั้งหมดลงไฟล์จริงก่อน แล้ว exec ใหม่
if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$0" == "bash" ]] || [[ "$0" == "-bash" ]] || [[ ! -f "$0" ]]; then
  _SELF=$(mktemp /tmp/chaiya-setup-XXXXX.sh)
  echo "[INFO] บันทึก script ลงไฟล์: $_SELF"
  if [[ -r "$0" ]] && cat "$0" > "$_SELF" 2>/dev/null && [[ $(wc -c < "$_SELF") -gt 10000 ]]; then
    chmod +x "$_SELF"
    exec bash "$_SELF" "$@"
  fi
  # fallback: ถ้าอ่านจาก fd ไม่ได้ ให้อ่านจาก stdin
  if [[ ! -t 0 ]] && cat > "$_SELF" 2>/dev/null && [[ $(wc -c < "$_SELF") -gt 10000 ]]; then
    chmod +x "$_SELF"
    exec bash "$_SELF" "$@"
  fi
  echo "[ERR] ไม่สามารถบันทึก script ลงไฟล์ได้ — กรุณาดาวน์โหลดไฟล์แล้วรันตรงๆ"
  rm -f "$_SELF"
  exit 1
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
  # ── เปิด IP Limit tracking + Traffic stats (จำเป็นสำหรับหน้าออนไลน์) ──
  for _key in enableIpLimit enableTrafficStatistics timeLocation trafficDiffReset; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('enableIpLimit','true');"              2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('enableTrafficStatistics','true');"    2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('timeLocation','Asia/Bangkok');"       2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('trafficDiffReset','false');"          2>/dev/null || true
  ok "3x-ui credentials + IP/Traffic tracking ตั้งค่าแล้ว"
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

# ── FIX #5: ใส่ settings อีกครั้งหลัง x-ui start เพื่อป้องกัน x-ui overwrite ──
# x-ui อาจ init DB ใหม่ตอน start ทับค่าเดิม → insert ซ้ำหลัง start ให้แน่ใจ
XUI_DB="/etc/x-ui/x-ui.db"
if [[ -f "$XUI_DB" ]]; then
  systemctl stop x-ui 2>/dev/null; sleep 2
  for _key in enableIpLimit enableTrafficStatistics timeLocation trafficDiffReset; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('enableIpLimit','true');"           2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('enableTrafficStatistics','true');" 2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('timeLocation','Asia/Bangkok');"    2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('trafficDiffReset','false');"       2>/dev/null || true
  # ตรวจสอบว่า settings ถูกบันทึก
  _ip_setting=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='enableIpLimit';" 2>/dev/null)
  [[ "$_ip_setting" == "true" ]] && ok "x-ui IP Limit + Traffic tracking ยืนยันแล้ว" || warn "ตรวจสอบ x-ui settings อีกครั้งหลังติดตั้ง"
  systemctl start x-ui; sleep 3
fi

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
        (8080, 'AIS-กันรั่ว',  'cj-ebb.speedtest.net',           'vless',  'inbound-8080'),
        (8880, 'TRUE-VDO', 'true-internet.zoom.xyz.services', 'vless',  'inbound-8880'),
    ]

    for port, remark, host, proto, tag in inbounds:
        if port in existing:
            print(f'[OK] {remark} มีอยู่แล้ว')
            continue
        uid = str(uuid.uuid4())
        if proto == 'vmess':
            settings = json.dumps({'clients': [{'id': uid, 'alterId': 0, 'email': f'default@{tag}', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}]})
        else:
            settings = json.dumps({'clients': [{'id': uid, 'flow': '', 'email': f'default@{tag}', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}], 'decryption': 'none'})
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
# อ่าน webBasePath จาก x-ui DB (ถ้ามี)
_XUI_BASEPATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null | head -1 | sed 's|/*$||')
[[ -z "$_XUI_BASEPATH" ]] && _XUI_BASEPATH=""
# สร้าง nginx prefix สำหรับ proxy
_XUI_NGINX_PATH="/xui-api"
[[ -n "$_XUI_BASEPATH" ]] && _XUI_NGINX_PATH="/${_XUI_BASEPATH}"
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
  dashboard_url:"sshws.html",
  basepath:     "${_XUI_NGINX_PATH}"
};
EOF

# ── LOGIN PAGE (index.html) ───────────────────────────────────
info "สร้าง Login Page..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPkNIQUlZQSBWUE4g4oCUIExvZ2luPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1PcmJpdHJvbjp3Z2h0QDcwMDs5MDAmZmFtaWx5PUthbml0OndnaHRAMzAwOzQwMDs2MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c3R5bGU+Cjpyb290IHsKICAtLW5lb246ICNjMDg0ZmM7CiAgLS1uZW9uMjogI2E4NTVmNzsKICAtLW5lb24zOiAjN2MzYWVkOwogIC0tZ2xvdzogcmdiYSgxOTIsMTMyLDI1MiwwLjM1KTsKICAtLWdsb3cyOiByZ2JhKDE2OCw4NSwyNDcsMC4xOCk7CiAgLS1iZzogIzBkMDYxNzsKICAtLWJnMjogIzEyMDgyMDsKICAtLWNhcmQ6IHJnYmEoMjU1LDI1NSwyNTUsMC4wMzUpOwogIC0tYm9yZGVyOiByZ2JhKDE5MiwxMzIsMjUyLDAuMjIpOwogIC0tdGV4dDogI2YwZTZmZjsKICAtLXN1YjogcmdiYSgyMjAsMTgwLDI1NSwwLjUpOwp9CgoqLCo6OmJlZm9yZSwqOjphZnRlciB7IGJveC1zaXppbmc6Ym9yZGVyLWJveDsgbWFyZ2luOjA7IHBhZGRpbmc6MDsgfQoKYm9keSB7CiAgbWluLWhlaWdodDogMTAwdmg7CiAgYmFja2dyb3VuZDogdmFyKC0tYmcpOwogIGZvbnQtZmFtaWx5OiAnS2FuaXQnLCBzYW5zLXNlcmlmOwogIGRpc3BsYXk6IGZsZXg7CiAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBvdmVyZmxvdzogaGlkZGVuOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKfQoKLyog4pSA4pSAIEJBQ0tHUk9VTkQgQkxPQlMg4pSA4pSAICovCi5ibG9iIHsKICBwb3NpdGlvbjogZml4ZWQ7CiAgYm9yZGVyLXJhZGl1czogNTAlOwogIGZpbHRlcjogYmx1cig4MHB4KTsKICBwb2ludGVyLWV2ZW50czogbm9uZTsKICB6LWluZGV4OiAwOwogIGFuaW1hdGlvbjogYmxvYkZsb2F0IDhzIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9Ci5ibG9iMSB7IHdpZHRoOjQyMHB4O2hlaWdodDo0MjBweDtiYWNrZ3JvdW5kOnJnYmEoMTI0LDU4LDIzNywuMTgpO3RvcDotODBweDtsZWZ0Oi0xMDBweDthbmltYXRpb24tZGVsYXk6MHM7IH0KLmJsb2IyIHsgd2lkdGg6MzIwcHg7aGVpZ2h0OjMyMHB4O2JhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMTIpO2JvdHRvbTotNjBweDtyaWdodDotODBweDthbmltYXRpb24tZGVsYXk6M3M7IH0KLmJsb2IzIHsgd2lkdGg6MjAwcHg7aGVpZ2h0OjIwMHB4O2JhY2tncm91bmQ6cmdiYSgxNjgsODUsMjQ3LC4xKTt0b3A6NTAlO2xlZnQ6NjAlO2FuaW1hdGlvbi1kZWxheTo1czsgfQpAa2V5ZnJhbWVzIGJsb2JGbG9hdCB7CiAgMCUsMTAwJSB7IHRyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTsgfQogIDUwJSB7IHRyYW5zZm9ybTp0cmFuc2xhdGUoMjBweCwtMjBweCkgc2NhbGUoMS4wOCk7IH0KfQoKLyog4pSA4pSAIFNUQVJTIOKUgOKUgCAqLwouc3RhcnMgeyBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MDtwb2ludGVyLWV2ZW50czpub25lOyB9Ci5zdGFyIHsKICBwb3NpdGlvbjphYnNvbHV0ZTsKICBiYWNrZ3JvdW5kOiNjMDg0ZmM7CiAgYm9yZGVyLXJhZGl1czo1MCU7CiAgYW5pbWF0aW9uOiB0d2lua2xlIHZhcigtLWQsMnMpIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9CkBrZXlmcmFtZXMgdHdpbmtsZSB7CiAgMCUsMTAwJXtvcGFjaXR5Oi4wODt0cmFuc2Zvcm06c2NhbGUoMSk7fQogIDUwJXtvcGFjaXR5Oi42O3RyYW5zZm9ybTpzY2FsZSgxLjQpO30KfQoKLyog4pSA4pSAIEdSSUQgTElORVMg4pSA4pSAICovCi5ncmlkLWJnIHsKICBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MDtwb2ludGVyLWV2ZW50czpub25lOwogIGJhY2tncm91bmQtaW1hZ2U6CiAgICBsaW5lYXItZ3JhZGllbnQocmdiYSgxOTIsMTMyLDI1MiwuMDQpIDFweCwgdHJhbnNwYXJlbnQgMXB4KSwKICAgIGxpbmVhci1ncmFkaWVudCg5MGRlZywgcmdiYSgxOTIsMTMyLDI1MiwuMDQpIDFweCwgdHJhbnNwYXJlbnQgMXB4KTsKICBiYWNrZ3JvdW5kLXNpemU6IDQ4cHggNDhweDsKfQoKLyog4pSA4pSAIE1BSU4gV1JBUCDilIDilIAgKi8KLndyYXAgewogIHBvc2l0aW9uOnJlbGF0aXZlO3otaW5kZXg6MTA7CiAgd2lkdGg6OTAlO21heC13aWR0aDo0MDBweDsKICBkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDowOwp9CgovKiDilIDilIAgQ0hBUkFDVEVSUyDilIDilIAgKi8KLmNoYXJzIHsKICBkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OmNlbnRlcjtnYXA6MThweDsKICBtYXJnaW4tYm90dG9tOiAtOHB4OwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKICB6LWluZGV4OiAxMTsKfQoKLyogR2hvc3QgKi8KLmdob3N0IHsKICB3aWR0aDo2NHB4O2hlaWdodDo3MHB4OwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGFuaW1hdGlvbjogZ2hvc3RCb2IgMi4ycyBlYXNlLWluLW91dCBpbmZpbml0ZTsKfQouZ2hvc3QtYm9keSB7CiAgd2lkdGg6NjRweDtoZWlnaHQ6NTBweDsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCNlOGQ1ZmYsI2MwODRmYyk7CiAgYm9yZGVyLXJhZGl1czozMnB4IDMycHggMCAwOwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGJveC1zaGFkb3c6IDAgMCAxOHB4IHJnYmEoMTkyLDEzMiwyNTIsLjUpLCBpbnNldCAwIC02cHggMTJweCByZ2JhKDAsMCwwLC4xNSk7Cn0KLmdob3N0LWJvdHRvbSB7CiAgZGlzcGxheTpmbGV4OwogIHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDt3aWR0aDoxMDAlOwp9Ci5naG9zdC13YXZlIHsKICBmbGV4OjE7aGVpZ2h0OjE0cHg7CiAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2MGRlZywjZThkNWZmLCNjMDg0ZmMpOwp9Ci5naG9zdC13YXZlOm50aC1jaGlsZCgxKXsgYm9yZGVyLXJhZGl1czowIDUwJSA1MCUgMDsgfQouZ2hvc3Qtd2F2ZTpudGgtY2hpbGQoMil7IGJvcmRlci1yYWRpdXM6NTAlIDAgMCA1MCU7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDRweCk7IH0KLmdob3N0LXdhdmU6bnRoLWNoaWxkKDMpeyBib3JkZXItcmFkaXVzOjAgNTAlIDUwJSAwOyB9Ci5naG9zdC1leWVzIHsgcG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7bGVmdDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSk7ZGlzcGxheTpmbGV4O2dhcDoxMnB4OyB9Ci5naG9zdC1leWUgeyB3aWR0aDoxMHB4O2hlaWdodDoxMHB4O2JhY2tncm91bmQ6IzNiMDc2NDtib3JkZXItcmFkaXVzOjUwJTtwb3NpdGlvbjpyZWxhdGl2ZTsgfQouZ2hvc3QtZXllOjphZnRlciB7IGNvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7dG9wOjJweDtsZWZ0OjJweDt3aWR0aDo0cHg7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjQpO2JvcmRlci1yYWRpdXM6NTAlOyB9Ci5naG9zdC1ibHVzaCB7IHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbToxMnB4O2Rpc3BsYXk6ZmxleDtnYXA6MjJweDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTt3aWR0aDo1MHB4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuOyB9Ci5naG9zdC1ibHVzaCBzcGFuIHsgd2lkdGg6MTBweDtoZWlnaHQ6NnB4O2JhY2tncm91bmQ6cmdiYSgyMzYsNzIsMTUzLC4zNSk7Ym9yZGVyLXJhZGl1czo1MCU7ZGlzcGxheTpibG9jazsgfQouZ2hvc3Qtc3RhciB7CiAgcG9zaXRpb246YWJzb2x1dGU7dG9wOi04cHg7cmlnaHQ6LTRweDsKICBmb250LXNpemU6MTRweDsKICBhbmltYXRpb246IHN0YXJTcGluIDNzIGxpbmVhciBpbmZpbml0ZTsKICBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA0cHggI2MwODRmYyk7Cn0KQGtleWZyYW1lcyBnaG9zdEJvYiB7CiAgMCUsMTAwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCkgcm90YXRlKC0zZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEwcHgpIHJvdGF0ZSgzZGVnKTsgfQp9CkBrZXlmcmFtZXMgc3RhclNwaW4geyB0b3sgdHJhbnNmb3JtOnJvdGF0ZSgzNjBkZWcpOyB9IH0KCi8qIENhdCAqLwouY2F0IHsKICB3aWR0aDo1NnB4O2hlaWdodDo2OHB4OwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGFuaW1hdGlvbjogY2F0Qm9iIDEuOHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgYW5pbWF0aW9uLWRlbGF5Oi40czsKfQouY2F0LWJvZHkgewogIHdpZHRoOjU2cHg7aGVpZ2h0OjQ4cHg7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCNmNWQwZmUsI2E4NTVmNyk7CiAgYm9yZGVyLXJhZGl1czoyOHB4IDI4cHggMjJweCAyMnB4OwogIHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowOwogIGJveC1zaGFkb3c6MCAwIDE2cHggcmdiYSgxNjgsODUsMjQ3LC40NSk7Cn0KLmNhdC1lYXIgewogIHBvc2l0aW9uOmFic29sdXRlO3RvcDotMTRweDsKICB3aWR0aDowO2hlaWdodDowOwp9Ci5jYXQtZWFyLmxlZnQgeyBsZWZ0OjhweDsgYm9yZGVyLWxlZnQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItYm90dG9tOjIwcHggc29saWQgI2Y1ZDBmZTsgfQouY2F0LWVhci5yaWdodCB7IHJpZ2h0OjhweDsgYm9yZGVyLWxlZnQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItYm90dG9tOjIwcHggc29saWQgI2Y1ZDBmZTsgfQouY2F0LWVhcjo6YWZ0ZXIgeyBjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlOyB9Ci5jYXQtaW5uZXItZWFyIHsKICBwb3NpdGlvbjphYnNvbHV0ZTt0b3A6LThweDsKICB3aWR0aDowO2hlaWdodDowOwp9Ci5jYXQtaW5uZXItZWFyLmxlZnQgeyBsZWZ0OjE0cHg7IGJvcmRlci1sZWZ0OjVweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6NXB4IHNvbGlkIHRyYW5zcGFyZW50O2JvcmRlci1ib3R0b206MTFweCBzb2xpZCAjZTg3OWY5OyB9Ci5jYXQtaW5uZXItZWFyLnJpZ2h0IHsgcmlnaHQ6MTRweDsgYm9yZGVyLWxlZnQ6NXB4IHNvbGlkIHRyYW5zcGFyZW50O2JvcmRlci1yaWdodDo1cHggc29saWQgdHJhbnNwYXJlbnQ7Ym9yZGVyLWJvdHRvbToxMXB4IHNvbGlkICNlODc5Zjk7IH0KLmNhdC1mYWNlIHsgcG9zaXRpb246YWJzb2x1dGU7dG9wOjEwcHg7bGVmdDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSk7d2lkdGg6NDRweDsgfQouY2F0LWV5ZXMgeyBkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWFyb3VuZDttYXJnaW4tYm90dG9tOjRweDsgfQouY2F0LWV5ZSB7IHdpZHRoOjlweDtoZWlnaHQ6OXB4O2JhY2tncm91bmQ6IzJlMTA2NTtib3JkZXItcmFkaXVzOjUwJTtwb3NpdGlvbjpyZWxhdGl2ZTsgfQouY2F0LWV5ZTo6YWZ0ZXIgeyBjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO3RvcDoycHg7bGVmdDoycHg7d2lkdGg6M3B4O2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC41KTtib3JkZXItcmFkaXVzOjUwJTsgfQouY2F0LW5vc2UgeyB3aWR0aDo2cHg7aGVpZ2h0OjVweDtiYWNrZ3JvdW5kOiNmNDcyYjY7Ym9yZGVyLXJhZGl1czo1MCU7bWFyZ2luOjAgYXV0byAycHg7IH0KLmNhdC1tb3V0aCB7IGRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoycHg7IGZvbnQtc2l6ZTo4cHg7IGNvbG9yOiM3YzNhZWQ7IH0KLmNhdC1ibHVzaCB7IGRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjAgMnB4O21hcmdpbi10b3A6MnB4OyB9Ci5jYXQtYmx1c2ggc3BhbiB7IHdpZHRoOjEwcHg7aGVpZ2h0OjZweDtiYWNrZ3JvdW5kOnJnYmEoMjQ5LDE2OCwyMTIsLjUpO2JvcmRlci1yYWRpdXM6NTAlO2Rpc3BsYXk6YmxvY2s7IH0KLmNhdC10YWlsIHsKICBwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206NHB4O3JpZ2h0Oi0xNHB4OwogIHdpZHRoOjIwcHg7aGVpZ2h0OjM2cHg7CiAgYm9yZGVyOjRweCBzb2xpZCAjYTg1NWY3OwogIGJvcmRlci1sZWZ0Om5vbmU7CiAgYm9yZGVyLXJhZGl1czowIDIwcHggMjBweCAwOwogIGFuaW1hdGlvbjp0YWlsV2FnIDFzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIHRyYW5zZm9ybS1vcmlnaW46dG9wIGxlZnQ7CiAgYm94LXNoYWRvdzowIDAgOHB4IHJnYmEoMTY4LDg1LDI0NywuNCk7Cn0KQGtleWZyYW1lcyBjYXRCb2IgewogIDAlLDEwMCV7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApIHJvdGF0ZSgyZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLThweCkgcm90YXRlKC0yZGVnKTsgfQp9CkBrZXlmcmFtZXMgdGFpbFdhZyB7CiAgMCUsMTAwJXsgdHJhbnNmb3JtOnJvdGF0ZSgtMTBkZWcpOyB9CiAgNTAleyB0cmFuc2Zvcm06cm90YXRlKDE1ZGVnKTsgfQp9CgovKiBTdGFyICovCi5zdGFyLWNoYXIgewogIHdpZHRoOjUycHg7aGVpZ2h0OjY4cHg7CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1c3RpZnktY29udGVudDpjZW50ZXI7CiAgcG9zaXRpb246cmVsYXRpdmU7CiAgYW5pbWF0aW9uOiBzdGFyQ2hhckJvYiAyLjZzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIGFuaW1hdGlvbi1kZWxheTouOHM7Cn0KLnN0YXItYm9keSB7CiAgZm9udC1zaXplOjQ2cHg7CiAgbGluZS1oZWlnaHQ6MTsKICBmaWx0ZXI6ZHJvcC1zaGFkb3coMCAwIDEycHggI2MwODRmYykgZHJvcC1zaGFkb3coMCAwIDI0cHggcmdiYSgxOTIsMTMyLDI1MiwuNCkpOwogIGFuaW1hdGlvbjogc3RhclB1bHNlIDEuNXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgdXNlci1zZWxlY3Q6bm9uZTsKfQouc3Rhci1mYWNlIHsKICBwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MTBweDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTsKICBkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MnB4Owp9Ci5zdGFyLWV5ZXMgeyBkaXNwbGF5OmZsZXg7Z2FwOjhweDsgfQouc3Rhci1leWUyIHsgd2lkdGg6NnB4O2hlaWdodDo2cHg7YmFja2dyb3VuZDojMmUxMDY1O2JvcmRlci1yYWRpdXM6NTAlOyB9Ci5zdGFyLXNtaWxlIHsgZm9udC1zaXplOjlweDtjb2xvcjojN2MzYWVkOyB9CkBrZXlmcmFtZXMgc3RhckNoYXJCb2IgewogIDAlLDEwMCV7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApIHJvdGF0ZSg1ZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEycHgpIHJvdGF0ZSgtNWRlZyk7IH0KfQpAa2V5ZnJhbWVzIHN0YXJQdWxzZSB7CiAgMCUsMTAwJXsgZmlsdGVyOmRyb3Atc2hhZG93KDAgMCAxMnB4ICNjMDg0ZmMpIGRyb3Atc2hhZG93KDAgMCAyNHB4IHJnYmEoMTkyLDEzMiwyNTIsLjQpKTsgfQogIDUwJXsgZmlsdGVyOmRyb3Atc2hhZG93KDAgMCAyMHB4ICNlODc5ZjkpIGRyb3Atc2hhZG93KDAgMCAzNnB4IHJnYmEoMjMyLDEyMSwyNDksLjUpKTsgfQp9CgovKiDilIDilIAgQ0FSRCDilIDilIAgKi8KLmNhcmQgewogIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOwogIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgYm9yZGVyLXJhZGl1czogMjhweDsKICBwYWRkaW5nOiAyLjJyZW0gMnJlbSAycmVtOwogIGJhY2tkcm9wLWZpbHRlcjogYmx1cigyNHB4KTsKICBib3gtc2hhZG93OgogICAgMCAwIDAgMXB4IHJnYmEoMTkyLDEzMiwyNTIsLjA4KSwKICAgIDAgOHB4IDQwcHggcmdiYSgxMjQsNTgsMjM3LC4xOCksCiAgICBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsLjA2KTsKICBwb3NpdGlvbjpyZWxhdGl2ZTsKICBvdmVyZmxvdzpoaWRkZW47Cn0KLmNhcmQ6OmJlZm9yZSB7CiAgY29udGVudDonJzsKICBwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4OwogIGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsLjUpLHRyYW5zcGFyZW50KTsKfQouY2FyZDo6YWZ0ZXIgewogIGNvbnRlbnQ6Jyc7CiAgcG9zaXRpb246YWJzb2x1dGU7dG9wOi00MCU7bGVmdDotMjAlOwogIHdpZHRoOjE0MCU7aGVpZ2h0OjE0MCU7CiAgYmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSBhdCA1MCUgMCUscmdiYSgxOTIsMTMyLDI1MiwuMDYpIDAlLHRyYW5zcGFyZW50IDYwJSk7CiAgcG9pbnRlci1ldmVudHM6bm9uZTsKfQoKLmxvZ28tdGFnIHsKICB0ZXh0LWFsaWduOmNlbnRlcjsKICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsKICBmb250LXNpemU6LjVyZW07CiAgbGV0dGVyLXNwYWNpbmc6LjRlbTsKICBjb2xvcjp2YXIoLS1uZW9uKTsKICBvcGFjaXR5Oi42OwogIG1hcmdpbi1ib3R0b206LjRyZW07CiAgdGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlOwp9Ci50aXRsZSB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7CiAgZm9udC1zaXplOjEuNnJlbTsKICBmb250LXdlaWdodDo5MDA7CiAgbGV0dGVyLXNwYWNpbmc6LjA2ZW07CiAgY29sb3I6dmFyKC0tdGV4dCk7CiAgbWFyZ2luLWJvdHRvbTouMnJlbTsKICB0ZXh0LXNoYWRvdzowIDAgMjBweCByZ2JhKDE5MiwxMzIsMjUyLC40KTsKfQoudGl0bGUgc3BhbiB7IGNvbG9yOnZhcigtLW5lb24pOyB9Ci5zdWJ0aXRsZSB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7CiAgZm9udC1zaXplOi43MnJlbTsKICBjb2xvcjp2YXIoLS1zdWIpOwogIG1hcmdpbi1ib3R0b206MS42cmVtOwogIGxldHRlci1zcGFjaW5nOi4wNGVtOwp9CgovKiBTZXJ2ZXIgYmFkZ2UgKi8KLnNlcnZlci1iYWRnZSB7CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDouNXJlbTsKICBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA3KTsKICBib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjE4KTsKICBib3JkZXItcmFkaXVzOjIwcHg7CiAgcGFkZGluZzouM3JlbSAuOXJlbTsKICBtYXJnaW4tYm90dG9tOjEuNHJlbTsKICBmb250LWZhbWlseTptb25vc3BhY2U7CiAgZm9udC1zaXplOi42OHJlbTsKICBjb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC43NSk7Cn0KLnB1bHNlLWRvdCB7CiAgd2lkdGg6N3B4O2hlaWdodDo3cHg7YmFja2dyb3VuZDp2YXIoLS1uZW9uKTtib3JkZXItcmFkaXVzOjUwJTsKICBib3gtc2hhZG93OjAgMCA4cHggdmFyKC0tbmVvbik7CiAgYW5pbWF0aW9uOnB1bHNlIDJzIGluZmluaXRlOwp9CkBrZXlmcmFtZXMgcHVsc2UgeyAwJSwxMDAle29wYWNpdHk6MX01MCV7b3BhY2l0eTouMzV9IH0KCi8qIEZpZWxkcyAqLwouZmllbGQgeyBtYXJnaW4tYm90dG9tOjEuMXJlbTsgfQpsYWJlbCB7CiAgZGlzcGxheTpibG9jazsKICBmb250LXNpemU6LjYycmVtOwogIGxldHRlci1zcGFjaW5nOi4xNGVtOwogIHRleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTsKICBjb2xvcjp2YXIoLS1zdWIpOwogIG1hcmdpbi1ib3R0b206LjQycmVtOwogIGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOwp9Ci5pbnB1dC13cmFwIHsgcG9zaXRpb246cmVsYXRpdmU7IH0KaW5wdXQgewogIHdpZHRoOjEwMCU7CiAgYmFja2dyb3VuZDpyZ2JhKDE5MiwxMzIsMjUyLC4wNik7CiAgYm9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjIpOwogIGJvcmRlci1yYWRpdXM6MTRweDsKICBwYWRkaW5nOi43cmVtIDFyZW07CiAgY29sb3I6dmFyKC0tdGV4dCk7CiAgZm9udC1mYW1pbHk6J0thbml0JyxzYW5zLXNlcmlmOwogIGZvbnQtc2l6ZTouOTJyZW07CiAgb3V0bGluZTpub25lOwogIHRyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4ycywgYm94LXNoYWRvdyAuMnMsIGJhY2tncm91bmQgLjJzOwp9CmlucHV0OjpwbGFjZWhvbGRlciB7IGNvbG9yOnJnYmEoMjIwLDE4MCwyNTUsLjI1KTsgfQppbnB1dDpmb2N1cyB7CiAgYm9yZGVyLWNvbG9yOnJnYmEoMTkyLDEzMiwyNTIsLjU1KTsKICBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjEpOwogIGJveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMTkyLDEzMiwyNTIsLjEpLCAwIDAgMTZweCByZ2JhKDE5MiwxMzIsMjUyLC4xMik7Cn0KLmV5ZS1idG4gewogIHBvc2l0aW9uOmFic29sdXRlO3JpZ2h0Oi43NXJlbTt0b3A6NTAlO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpOwogIGJhY2tncm91bmQ6bm9uZTtib3JkZXI6bm9uZTtjb2xvcjpyZ2JhKDIyMCwxODAsMjU1LC40KTsKICBjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MXJlbTtwYWRkaW5nOi4ycmVtOwogIHRyYW5zaXRpb246Y29sb3IgLjJzOwp9Ci5leWUtYnRuOmhvdmVyIHsgY29sb3I6dmFyKC0tbmVvbik7IH0KCi8qIEJ1dHRvbiAqLwoubG9naW4tYnRuIHsKICB3aWR0aDoxMDAlO3BhZGRpbmc6Ljg4cmVtO2JvcmRlcjpub25lO2JvcmRlci1yYWRpdXM6MTRweDsKICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzdjM2FlZCwjYTg1NWY3LCNjMDg0ZmMpOwogIGNvbG9yOiNmZmY7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7CiAgZm9udC1zaXplOi44OHJlbTsKICBmb250LXdlaWdodDo3MDA7CiAgbGV0dGVyLXNwYWNpbmc6LjEyZW07CiAgY3Vyc29yOnBvaW50ZXI7CiAgbWFyZ2luLXRvcDouNXJlbTsKICB0cmFuc2l0aW9uOmFsbCAuMjVzOwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIG92ZXJmbG93OmhpZGRlbjsKICBib3gtc2hhZG93OjAgNHB4IDIwcHggcmdiYSgxMjQsNTgsMjM3LC40KSwwIDAgMCAxcHggcmdiYSgxOTIsMTMyLDI1MiwuMik7Cn0KLmxvZ2luLWJ0bjo6YmVmb3JlIHsKICBjb250ZW50OicnOwogIHBvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLHJnYmEoMjU1LDI1NSwyNTUsLjEyKSx0cmFuc3BhcmVudCk7CiAgb3BhY2l0eTowO3RyYW5zaXRpb246b3BhY2l0eSAuMnM7Cn0KLmxvZ2luLWJ0bjpob3Zlcjpub3QoOmRpc2FibGVkKSB7CiAgYm94LXNoYWRvdzowIDZweCAyOHB4IHJnYmEoMTI0LDU4LDIzNywuNTUpLCAwIDAgMzJweCByZ2JhKDE5MiwxMzIsMjUyLC4yNSk7CiAgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7Cn0KLmxvZ2luLWJ0bjpob3Zlcjpub3QoOmRpc2FibGVkKTo6YmVmb3JlIHsgb3BhY2l0eToxOyB9Ci5sb2dpbi1idG46YWN0aXZlOm5vdCg6ZGlzYWJsZWQpIHsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCk7IH0KLmxvZ2luLWJ0bjpkaXNhYmxlZCB7IG9wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkOyB9CgovKiBTcGlubmVyICovCi5zcGlubmVyIHsKICBkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxNHB4O2hlaWdodDoxNHB4OwogIGJvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7CiAgYm9yZGVyLXRvcC1jb2xvcjojZmZmOwogIGJvcmRlci1yYWRpdXM6NTAlOwogIGFuaW1hdGlvbjpzcGluIC43cyBsaW5lYXIgaW5maW5pdGU7CiAgdmVydGljYWwtYWxpZ246bWlkZGxlO21hcmdpbi1yaWdodDouNHJlbTsKfQpAa2V5ZnJhbWVzIHNwaW4geyB0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9IH0KCi8qIEFsZXJ0ICovCi5hbGVydCB7CiAgZGlzcGxheTpub25lO21hcmdpbi10b3A6LjhyZW07CiAgcGFkZGluZzouNjVyZW0gLjlyZW07Ym9yZGVyLXJhZGl1czoxMHB4OwogIGZvbnQtc2l6ZTouOHJlbTtsaW5lLWhlaWdodDoxLjU7Cn0KLmFsZXJ0Lm9rIHsgYmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMyk7Y29sb3I6IzRhZGU4MDsgfQouYWxlcnQuZXJyIHsgYmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjI1KTtjb2xvcjojZjg3MTcxOyB9CgovKiBGb290ZXIgKi8KLmZvb3RlciB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLXRvcDoxLjRyZW07CiAgZm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtc2l6ZTouNnJlbTsKICBjb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC4yNSk7bGV0dGVyLXNwYWNpbmc6LjA2ZW07Cn0KCi8qIE5lb24gbGluZXMgZGVjbyAqLwoubmVvbi1saW5lIHsKICBwb3NpdGlvbjphYnNvbHV0ZTsKICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCx2YXIoLS1uZW9uKSx0cmFuc3BhcmVudCk7CiAgaGVpZ2h0OjFweDtvcGFjaXR5Oi4xNTsKICBhbmltYXRpb246bGluZU1vdmUgNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7Cn0KLm5lb24tbGluZTpudGgtY2hpbGQoMSl7IHRvcDozMCU7d2lkdGg6MTAwJTtsZWZ0OjA7YW5pbWF0aW9uLWRlbGF5OjBzOyB9Ci5uZW9uLWxpbmU6bnRoLWNoaWxkKDIpeyB0b3A6NzAlO3dpZHRoOjYwJTtsZWZ0OjIwJTthbmltYXRpb24tZGVsYXk6MnM7IH0KQGtleWZyYW1lcyBsaW5lTW92ZSB7CiAgMCUsMTAwJXtvcGFjaXR5Oi4wODt9CiAgNTAle29wYWNpdHk6LjI1O30KfQoKLyog4pSA4pSAIEZMT0FUSU5HIFNQQVJLTEVTIOKUgOKUgCAqLwouc3BhcmtsZXMgeyBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDoxOyB9Ci5zcCB7CiAgcG9zaXRpb246YWJzb2x1dGU7CiAgd2lkdGg6NHB4O2hlaWdodDo0cHg7CiAgYmFja2dyb3VuZDp2YXIoLS1uZW9uKTsKICBib3JkZXItcmFkaXVzOjUwJTsKICBib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tbmVvbik7CiAgYW5pbWF0aW9uOnNwRmxvYXQgdmFyKC0tc2QsNnMpIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIG9wYWNpdHk6MDsKfQpAa2V5ZnJhbWVzIHNwRmxvYXQgewogIDAleyBvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCkgc2NhbGUoMCk7IH0KICAyMCV7IG9wYWNpdHk6Ljc7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTIwcHgpIHNjYWxlKDEpOyB9CiAgODAleyBvcGFjaXR5Oi40O3RyYW5zZm9ybTp0cmFuc2xhdGVZKC04MHB4KSBzY2FsZSguNik7IH0KICAxMDAleyBvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEyMHB4KSBzY2FsZSgwKTsgfQp9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+Cgo8IS0tIEJhY2tncm91bmQgLS0+CjxkaXYgY2xhc3M9ImdyaWQtYmciPjwvZGl2Pgo8ZGl2IGNsYXNzPSJibG9iIGJsb2IxIj48L2Rpdj4KPGRpdiBjbGFzcz0iYmxvYiBibG9iMiI+PC9kaXY+CjxkaXYgY2xhc3M9ImJsb2IgYmxvYjMiPjwvZGl2Pgo8ZGl2IGNsYXNzPSJzdGFycyIgaWQ9InN0YXJzIj48L2Rpdj4KPGRpdiBjbGFzcz0ic3BhcmtsZXMiIGlkPSJzcGFya2xlcyI+PC9kaXY+Cgo8ZGl2IGNsYXNzPSJ3cmFwIj4KCiAgPCEtLSBDaGFyYWN0ZXJzIC0tPgogIDxkaXYgY2xhc3M9ImNoYXJzIj4KCiAgICA8IS0tIEdob3N0IC0tPgogICAgPGRpdiBjbGFzcz0iZ2hvc3QiPgogICAgICA8ZGl2IGNsYXNzPSJnaG9zdC1zdGFyIj7inKY8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtYm9keSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtZXllcyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC1leWUiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtZXllIj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC1ibHVzaCI+CiAgICAgICAgICA8c3Bhbj48L3NwYW4+PHNwYW4+PC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Imdob3N0LWJvdHRvbSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC13YXZlIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Imdob3N0LXdhdmUiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3Qtd2F2ZSI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTdGFyIGNoYXIgLS0+CiAgICA8ZGl2IGNsYXNzPSJzdGFyLWNoYXIiPgogICAgICA8ZGl2IGNsYXNzPSJzdGFyLWJvZHkiPuKtkDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdGFyLWZhY2UiPgogICAgICAgIDxkaXYgY2xhc3M9InN0YXItZXllcyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdGFyLWV5ZTIiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3Rhci1leWUyIj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGFyLXNtaWxlIj7il6E8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIENhdCAtLT4KICAgIDxkaXYgY2xhc3M9ImNhdCI+CiAgICAgIDxkaXYgY2xhc3M9ImNhdC1lYXIgbGVmdCI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhdC1lYXIgcmlnaHQiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXQtaW5uZXItZWFyIGxlZnQiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXQtaW5uZXItZWFyIHJpZ2h0Ij48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2F0LWJvZHkiPgogICAgICAgIDxkaXYgY2xhc3M9ImNhdC1mYWNlIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImNhdC1leWVzIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iY2F0LWV5ZSI+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImNhdC1leWUiPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJjYXQtbm9zZSI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJjYXQtbW91dGgiPjxzcGFuPs+JPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iY2F0LWJsdXNoIj4KICAgICAgICAgICAgPHNwYW4+PC9zcGFuPjxzcGFuPjwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2F0LXRhaWwiPjwvZGl2PgogICAgPC9kaXY+CgogIDwvZGl2PgoKICA8IS0tIENhcmQgLS0+CiAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICA8ZGl2IGNsYXNzPSJuZW9uLWxpbmUiPjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmVvbi1saW5lIj48L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJsb2dvLXRhZyI+4pymIENIQUlZQSBWMlJBWSBQUk8gTUFYIOKcpjwvZGl2PgogICAgPGRpdiBjbGFzcz0idGl0bGUiPkFETUlOIDxzcGFuPlBBTkVMPC9zcGFuPjwvZGl2PgogICAgPGRpdiBjbGFzcz0ic3VidGl0bGUiPngtdWkgTWFuYWdlbWVudCBEYXNoYm9hcmQ8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJzZXJ2ZXItYmFkZ2UiPgogICAgICA8c3BhbiBjbGFzcz0icHVsc2UtZG90Ij48L3NwYW4+CiAgICAgIDxzcGFuIGlkPSJzZXJ2ZXItaG9zdCI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9zcGFuPgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICA8bGFiZWw+8J+RpCBVc2VybmFtZTwvbGFiZWw+CiAgICAgIDxpbnB1dCB0eXBlPSJ0ZXh0IiBpZD0iaW5wLXVzZXIiIHBsYWNlaG9sZGVyPSJ1c2VybmFtZSIgYXV0b2NvbXBsZXRlPSJ1c2VybmFtZSI+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICAgIDxsYWJlbD7wn5SRIFBhc3N3b3JkPC9sYWJlbD4KICAgICAgPGRpdiBjbGFzcz0iaW5wdXQtd3JhcCI+CiAgICAgICAgPGlucHV0IHR5cGU9InBhc3N3b3JkIiBpZD0iaW5wLXBhc3MiIHBsYWNlaG9sZGVyPSLigKLigKLigKLigKLigKLigKLigKLigKIiIGF1dG9jb21wbGV0ZT0iY3VycmVudC1wYXNzd29yZCI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iZXllLWJ0biIgaWQ9ImV5ZS1idG4iIG9uY2xpY2s9InRvZ2dsZUV5ZSgpIiB0eXBlPSJidXR0b24iPvCfkYE8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8YnV0dG9uIGNsYXNzPSJsb2dpbi1idG4iIGlkPSJsb2dpbi1idG4iIG9uY2xpY2s9ImRvTG9naW4oKSI+CiAgICAgIOKcpiAmbmJzcDvguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJoKICAgIDwvYnV0dG9uPgoKICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWxlcnQiPjwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZvb3RlciIgaWQ9ImZvb3Rlci10aW1lIj48L2Rpdj4KICA8L2Rpdj4KCjwvZGl2PgoKPHNjcmlwdCBzcmM9ImNvbmZpZy5qcyIgb25lcnJvcj0id2luZG93LkNIQUlZQV9DT05GSUc9e30iPjwvc2NyaXB0Pgo8c2NyaXB0Pgpjb25zdCBDRkcgPSAodHlwZW9mIHdpbmRvdy5DSEFJWUFfQ09ORklHICE9PSAndW5kZWZpbmVkJykgPyB3aW5kb3cuQ0hBSVlBX0NPTkZJRyA6IHt9Owpjb25zdCBYVUlfQVBJID0gJy94dWktYXBpJzsKY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwpjb25zdCBEQVNIQk9BUkQgPSBDRkcuZGFzaGJvYXJkX3VybCB8fCAnc3Nod3MuaHRtbCc7CgovLyBTZXJ2ZXIgaG9zdApkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc2VydmVyLWhvc3QnKS50ZXh0Q29udGVudCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhvc3RuYW1lOwppZiAoQ0ZHLnh1aV91c2VyKSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5wLXVzZXInKS52YWx1ZSA9IENGRy54dWlfdXNlcjsKCi8vIENsb2NrCmZ1bmN0aW9uIHVwZGF0ZUNsb2NrKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb290ZXItdGltZScpLnRleHRDb250ZW50ID0KICAgIG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpICsgJyDinKYgQ0hBSVlBIFZQTiBTWVNURU0g4pymIHY1LjAnOwp9CnVwZGF0ZUNsb2NrKCk7IHNldEludGVydmFsKHVwZGF0ZUNsb2NrLCAxMDAwKTsKCi8vIEVudGVyIGtleQpkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7IGlmIChlLmtleSA9PT0gJ0VudGVyJykgZG9Mb2dpbigpOyB9KTsKCmxldCBleWVPcGVuID0gZmFsc2U7CmZ1bmN0aW9uIHRvZ2dsZUV5ZSgpIHsKICBleWVPcGVuID0gIWV5ZU9wZW47CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lucC1wYXNzJykudHlwZSA9IGV5ZU9wZW4gPyAndGV4dCcgOiAncGFzc3dvcmQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdleWUtYnRuJykudGV4dENvbnRlbnQgPSBleWVPcGVuID8gJ/CfmYgnIDogJ/CfkYEnOwp9CgpmdW5jdGlvbiBzaG93QWxlcnQobXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWxlcnQnKTsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyArIHR5cGU7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvTG9naW4oKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbnAtdXNlcicpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBwYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lucC1wYXNzJykudmFsdWU7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCAnZXJyJyk7CiAgaWYgKCFwYXNzKSByZXR1cm4gc2hvd0FsZXJ0KCfguIHguKPguLjguJPguLLguYPguKrguYggUGFzc3dvcmQnLCAnZXJyJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luLWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3Bpbm5lciI+PC9zcGFuPiDguIHguLPguKXguLHguIfguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJouLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhbGVydCcpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgdHJ5IHsKICAgIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IHVzZXIsIHBhc3N3b3JkOiBwYXNzIH0pOwogICAgY29uc3QgcmVzID0gYXdhaXQgUHJvbWlzZS5yYWNlKFsKICAgICAgZmV0Y2goWFVJX0FQSSArICcvbG9naW4nLCB7CiAgICAgICAgbWV0aG9kOiAnUE9TVCcsIGNyZWRlbnRpYWxzOiAnaW5jbHVkZScsCiAgICAgICAgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL3gtd3d3LWZvcm0tdXJsZW5jb2RlZCcgfSwKICAgICAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICAgICAgfSksCiAgICAgIG5ldyBQcm9taXNlKChfLHJlaikgPT4gc2V0VGltZW91dCgoKSA9PiByZWoobmV3IEVycm9yKCdUaW1lb3V0JykpLCA4MDAwKSkKICAgIF0pOwogICAgY29uc3QgZGF0YSA9IGF3YWl0IHJlcy5qc29uKCk7CiAgICBpZiAoZGF0YS5zdWNjZXNzKSB7CiAgICAgIHNlc3Npb25TdG9yYWdlLnNldEl0ZW0oU0VTU0lPTl9LRVksIEpTT04uc3RyaW5naWZ5KHsgdXNlciwgcGFzcywgZXhwOiBEYXRlLm5vdygpICsgOCozNjAwKjEwMDAgfSkpOwogICAgICBzaG93QWxlcnQoJ+KchSDguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJrguKrguLPguYDguKPguYfguIgg4LiB4Liz4Lil4Lix4LiHIHJlZGlyZWN0Li4uJywgJ29rJyk7CiAgICAgIHNldFRpbWVvdXQoKCkgPT4geyB3aW5kb3cubG9jYXRpb24ucmVwbGFjZShEQVNIQk9BUkQpOyB9LCA4MDApOwogICAgfSBlbHNlIHsKICAgICAgc2hvd0FsZXJ0KCfinYwgVXNlcm5hbWUg4Lir4Lij4Li34LitIFBhc3N3b3JkIOC5hOC4oeC5iOC4luC4ueC4geC4leC5ieC4reC4hycsICdlcnInKTsKICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIGJ0bi5pbm5lckhUTUwgPSAn4pymICZuYnNwO+C5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mic7CiAgICB9CiAgfSBjYXRjaChlKSB7CiAgICBzaG93QWxlcnQoJ+KdjCAnICsgZS5tZXNzYWdlLCAnZXJyJyk7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgIGJ0bi5pbm5lckhUTUwgPSAn4pymICZuYnNwO+C5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mic7CiAgfQp9CgovLyDilIDilIAgU1RBUlMg4pSA4pSACmNvbnN0IHN0YXJzRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3RhcnMnKTsKZm9yIChsZXQgaSA9IDA7IGkgPCA2MDsgaSsrKSB7CiAgY29uc3QgcyA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogIHMuY2xhc3NOYW1lID0gJ3N0YXInOwogIGNvbnN0IHNpemUgPSBNYXRoLnJhbmRvbSgpICogMi41ICsgLjU7CiAgcy5zdHlsZS5jc3NUZXh0ID0gYAogICAgd2lkdGg6JHtzaXplfXB4O2hlaWdodDoke3NpemV9cHg7CiAgICBsZWZ0OiR7TWF0aC5yYW5kb20oKSoxMDB9JTt0b3A6JHtNYXRoLnJhbmRvbSgpKjEwMH0lOwogICAgLS1kOiR7KE1hdGgucmFuZG9tKCkqMysxLjUpLnRvRml4ZWQoMSl9czsKICAgIGFuaW1hdGlvbi1kZWxheTokeyhNYXRoLnJhbmRvbSgpKjQpLnRvRml4ZWQoMSl9czsKICAgIG9wYWNpdHk6JHsoTWF0aC5yYW5kb20oKSouNCsuMDUpLnRvRml4ZWQoMil9OwogIGA7CiAgc3RhcnNFbC5hcHBlbmRDaGlsZChzKTsKfQoKLy8g4pSA4pSAIFNQQVJLTEVTIOKUgOKUgApjb25zdCBzcEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwYXJrbGVzJyk7CmZvciAobGV0IGkgPSAwOyBpIDwgMjA7IGkrKykgewogIGNvbnN0IHNwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgc3AuY2xhc3NOYW1lID0gJ3NwJzsKICBzcC5zdHlsZS5jc3NUZXh0ID0gYAogICAgbGVmdDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICB0b3A6JHsoTWF0aC5yYW5kb20oKSo0MCs0MCl9JTsKICAgIC0tc2Q6JHsoTWF0aC5yYW5kb20oKSo1KzQpLnRvRml4ZWQoMSl9czsKICAgIGFuaW1hdGlvbi1kZWxheTokeyhNYXRoLnJhbmRvbSgpKjYpLnRvRml4ZWQoMSl9czsKICAgIHdpZHRoOiR7TWF0aC5yYW5kb20oKSo0KzJ9cHg7aGVpZ2h0OiR7TWF0aC5yYW5kb20oKSo0KzJ9cHg7CiAgYDsKICBzcEVsLmFwcGVuZENoaWxkKHNwKTsKfQoKLy8g4pSA4pSAIENoYXJhY3RlciB3aWdnbGUgb24gaG92ZXIg4pSA4pSACmRvY3VtZW50LnF1ZXJ5U2VsZWN0b3IoJy5jYXJkJykuYWRkRXZlbnRMaXN0ZW5lcignbW91c2VlbnRlcicsICgpID0+IHsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuZ2hvc3QsLmNhdCwuc3Rhci1jaGFyJykuZm9yRWFjaChlbCA9PiB7CiAgICBlbC5zdHlsZS5hbmltYXRpb25QbGF5U3RhdGUgPSAncnVubmluZyc7CiAgfSk7Cn0pOwo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+Cg==' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMxYTBhMmUgMCUsIzBmMGExZSA1NSUsIzBhMGEwZiAxMDAlKTtwYWRkaW5nOjI4cHggMjBweCAyMnB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tncm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo1cHg7aGVpZ2h0OjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgMi40cyBlYXNlLWluLW91dCBpbmZpbml0ZTt9CiAgLmRvdC5yZWR7YmFja2dyb3VuZDojZWY0NDQ0O2JveC1zaGFkb3c6MCAwIDZweCAjZWY0NDQ0O30KICBAa2V5ZnJhbWVzIHBsc3swJSwxMDAle29wYWNpdHk6MTt0cmFuc2Zvcm06c2NhbGUoMSl9NTAle29wYWNpdHk6LjM1O3RyYW5zZm9ybTpzY2FsZSgwLjcpfX0KICAueHVpLXJvd3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLnh1aS1pbmZve2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtsaW5lLWhlaWdodDoxLjc7fQogIC54dWktaW5mbyBie2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtbGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4O30KICAuc3Zje2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4wNSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjExcHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO30KICAuc3ZjLmRvd257YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjA1KTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4yKTt9CiAgLnN2Yy1se2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7fQogIC5kZ3t3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tbmcpO2ZsZXgtc2hyaW5rOjA7fQogIC5kZy5yZWR7YmFja2dyb3VuZDojZWY0NDQ0O2JveC1zaGFkb3c6MCAwIDZweCAjZWY0NDQ0O30KICAuc3ZjLW57Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtcHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5yYmRne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMyk7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1uZyk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAucmJkZy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4zKTtjb2xvcjojZWY0NDQ0O30KICAubHV7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MTRweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoxcHg7fQogIC5mdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjExcHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4O30KICAuaW5mby1ib3h7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxMnB4O2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wdGdse2Rpc3BsYXk6ZmxleDtnYXA6OHB4O21hcmdpbi1ib3R0b206MTRweDt9CiAgLnBidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmZne21hcmdpbi1ib3R0b206MTJweDt9CiAgLmZsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO29wYWNpdHk6Ljg7bWFyZ2luLWJvdHRvbTo1cHg7fQogIC5maXt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo5cHg7cGFkZGluZzoxMHB4IDE0cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tdHh0KTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzO30KICAuZmk6Zm9jdXN7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtib3gtc2hhZG93OjAgMCAwIDNweCB2YXIoLS1hYy1kaW0pO30KICAudGdse2Rpc3BsYXk6ZmxleDtnYXA6OHB4O30KICAudGJ0bntmbGV4OjE7cGFkZGluZzo5cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXI7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JhY2tncm91bmQ6I2Y4ZmFmYztjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO30KICAudGJ0bi5hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuY2J0bnt3aWR0aDoxMDAlO3BhZGRpbmc6MTRweDtib3JkZXItcmFkaXVzOjEwcHg7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2JvcmRlcjpub25lO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMTZhMzRhLCMyMmM1NWUsIzRhZGU4MCk7Y29sb3I6I2ZmZjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtsZXR0ZXItc3BhY2luZzouNXB4O2JveC1zaGFkb3c6MCA0cHggMTVweCByZ2JhKDM0LDE5Nyw5NCwuMyk7dHJhbnNpdGlvbjphbGwgLjJzO30KICAuY2J0bjpob3Zlcntib3gtc2hhZG93OjAgNnB4IDIwcHggcmdiYSgzNCwxOTcsOTQsLjQ1KTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTt9CiAgLmNidG46ZGlzYWJsZWR7b3BhY2l0eTouNTtjdXJzb3I6bm90LWFsbG93ZWQ7dHJhbnNmb3JtOm5vbmU7fQogIC5zYm94e3dpZHRoOjEwMCU7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMHB4IDE0cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tdHh0KTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtvdXRsaW5lOm5vbmU7bWFyZ2luLWJvdHRvbToxMnB4O3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLnNib3g6Zm9jdXN7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLnVpdGVte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTJweCAxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbTo4cHg7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjJzO2JveC1zaGFkb3c6MCAxcHggNHB4IHJnYmEoMCwwLDAsMC4wNCk7fQogIC51aXRlbTpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWMpO2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTt9CiAgLnVhdnt3aWR0aDozNnB4O2hlaWdodDozNnB4O2JvcmRlci1yYWRpdXM6OXB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo3MDA7bWFyZ2luLXJpZ2h0OjEycHg7ZmxleC1zaHJpbms6MDt9CiAgLmF2LWd7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjE1KTtjb2xvcjp2YXIoLS1uZyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMik7fQogIC5hdi1ye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywwLjE1KTtjb2xvcjojZjg3MTcxO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNDgsMTEzLDExMywuMik7fQogIC5hdi14e2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xMik7Y29sb3I6I2VmNDQ0NDtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4yKTt9CiAgLnVue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAudW17Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuYWJkZ3tib3JkZXItcmFkaXVzOjZweDtwYWRkaW5nOjNweCAxMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAuYWJkZy5va3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMyk7Y29sb3I6dmFyKC0tbmcpO30KICAuYWJkZy5leHB7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjMpO2NvbG9yOiNlZjQ0NDQ7fQogIC5hYmRnLnNvb257YmFja2dyb3VuZDpyZ2JhKDI1MSwxNDYsNjAsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjUxLDE0Niw2MCwuMyk7Y29sb3I6I2Y5NzMxNjt9CiAgLm1vdmVye3Bvc2l0aW9uOmZpeGVkO2luc2V0OjA7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC41KTtiYWNrZHJvcC1maWx0ZXI6Ymx1cig2cHgpO3otaW5kZXg6MTAwO2Rpc3BsYXk6bm9uZTthbGlnbi1pdGVtczpmbGV4LWVuZDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAubW92ZXIub3BlbntkaXNwbGF5OmZsZXg7fQogIC5tb2RhbHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MjBweCAyMHB4IDAgMDt3aWR0aDoxMDAlO21heC13aWR0aDo0ODBweDtwYWRkaW5nOjIwcHg7bWF4LWhlaWdodDo4NXZoO292ZXJmbG93LXk6YXV0bzthbmltYXRpb246c3UgLjNzIGVhc2U7Ym94LXNoYWRvdzowIC00cHggMzBweCByZ2JhKDAsMCwwLDAuMTIpO30KICBAa2V5ZnJhbWVzIHN1e2Zyb217dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMTAwJSl9dG97dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5taGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxNnB4O30KICAubXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLXR4dCk7fQogIC5tY2xvc2V7d2lkdGg6MzJweDtoZWlnaHQ6MzJweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2NvbG9yOnZhcigtLW11dGVkKTtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5kZ3JpZHtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tYm90dG9tOjE0cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHJ7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtwYWRkaW5nOjdweCAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcjpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmRre2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmR2e2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC13ZWlnaHQ6NjAwO30KICAuZHYuZ3JlZW57Y29sb3I6dmFyKC0tbmcpO30KICAuZHYucmVke2NvbG9yOiNlZjQ0NDQ7fQogIC5kdi5tb25ve2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6OXB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO3dvcmQtYnJlYWs6YnJlYWstYWxsO30KICAuYWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7fQogIC5tLXN1YntkaXNwbGF5Om5vbmU7bWFyZ2luLXRvcDoxNHB4O2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMnB4O3BhZGRpbmc6MTRweDt9CiAgLm0tc3ViLm9wZW57ZGlzcGxheTpibG9jazthbmltYXRpb246ZmkgLjJzIGVhc2U7fQogIC5tc3ViLWxibHtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5hYnRue2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweCAxMHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmFidG46aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC5hYnRuIC5haXtmb250LXNpemU6MjJweDttYXJnaW4tYm90dG9tOjZweDt9CiAgLmFidG4gLmFue2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuYWJ0biAuYWR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuYWJ0bi5kYW5nZXI6aG92ZXJ7YmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLC4xKTtib3JkZXItY29sb3I6I2Y4NzE3MTt9CiAgLm9le3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6NDBweCAyMHB4O30KICAub2UgLmVpe2ZvbnQtc2l6ZTo0OHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLm9lIHB7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxM3B4O30KICAub2Nye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxNnB4O30KICAudXR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAvKiByZXN1bHQgYm94ICovCiAgLnJlcy1ib3h7YmFja2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi10b3A6MTRweDtkaXNwbGF5Om5vbmU7fQogIC5yZXMtYm94LnNob3d7ZGlzcGxheTpibG9jazt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gSEVBREVSIC0tPgogIDxkaXYgY2xhc3M9ImhkciI+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiPuKGqSDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KICAgIDxkaXYgY2xhc3M9Imhkci1zdWIiPkNIQUlZQSBWMlJBWSBQUk8gTUFYPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJoZHItdGl0bGUiPlVTRVIgPHNwYW4+Q1JFQVRPUjwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imhkci1kZXNjIiBpZD0iaGRyLWRvbWFpbiI+djUgwrcgU0VDVVJFIFBBTkVMPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gTkFWIC0tPgogIDxkaXYgY2xhc3M9Im5hdiI+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSBhY3RpdmUiIG9uY2xpY2s9InN3KCdkYXNoYm9hcmQnLHRoaXMpIj7wn5OKIOC5geC4lOC4iuC4muC4reC4o+C5jOC4lDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdjcmVhdGUnLHRoaXMpIj7inpUg4Liq4Lij4LmJ4Liy4LiH4Lii4Li54LiqPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ21hbmFnZScsdGhpcykiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54LiqPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ29ubGluZScsdGhpcykiPvCfn6Ig4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2JhbicsdGhpcykiPvCfmqsg4Lib4Lil4LiU4LmB4Lia4LiZPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIgaWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFuIGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7imqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9udC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGltZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJvdyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3guKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAgICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklDRSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2ltZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgtQUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlzLm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWlnaHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdTIMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBXUyDCtyB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KCiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCIgc3R5bGU9Im1hcmdpbi10b3A6MjBweCI+8J+UkSDguKPguLDguJrguJogU1NIIFdFQlNPQ0tFVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3NzaCcpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtc3NoIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6I2ZmZjtmb250LWZhbWlseTptb25vc3BhY2UiPlNTSCZndDs8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgc3NoIj5TU0gg4oCTIFdTIFR1bm5lbDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+U1NIIMK3IFBvcnQgODAgwrcgRHJvcGJlYXIgMTQzLzEwOTxicj5OcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IEFJUyDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLWFpcyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgYWlzLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWxvZ28gc2VsLWFpcy1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouOHJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgU05JOiBjai1lYmIuc3BlZWR0ZXN0Lm5ldDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckBhaXMiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLWFpcyIgaWQ9ImFpcy1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCdhaXMnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0iYWlzLXJlc3VsdCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1haXMtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLWFpcy11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici1haXMtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici1haXMtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci1haXMtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5rPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJhaXMtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBUUlVFIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tdHJ1ZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgdHJ1ZS1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBTTkk6IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQHRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLXRydWUiIGlkPSJ0cnVlLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ3RydWUnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBUUlVFIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici10cnVlLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici10cnVlLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLXRydWUtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici10cnVlLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItdHJ1ZS1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9InRydWUtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBTU0gg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1zc2giIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNzaC1kYXJrLWZvcm0iPgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7inpUg4LmA4Lie4Li04LmI4LihIFNTSCBVU0VSPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1wYXNzIiBwbGFjZWhvbGRlcj0icGFzc3dvcmQiIHR5cGU9InBhc3N3b3JkIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lil4Li04Lih4Li04LiV4LmE4Lit4Lie4Li1PC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+4pyI77iPIOC5gOC4peC4t+C4reC4gSBQT1JUPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIGFjdGl2ZS1wODAiIGlkPSJwYi04MCIgb25jbGljaz0icGlja1BvcnQoJzgwJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn4yQPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgODA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XUyDCtyBIVFRQPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIiBpZD0icGItNDQzIiBvbmNsaWNrPSJwaWNrUG9ydCgnNDQzJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn5SSPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgNDQzPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLXN1YiI+V1NTIMK3IFNTTDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn4yQIOC5gOC4peC4t+C4reC4gSBJU1AgLyBPUEVSQVRPUjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBpY2stZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCBhLWR0YWMiIGlkPSJwcm8tZHRhYyIgb25jbGljaz0icGlja1BybygnZHRhYycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCfn6A8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRUQUMgR0FNSU5HPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5kbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0icHJvLXRydWUiIG9uY2xpY2s9InBpY2tQcm8oJ3RydWUnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj7wn5S1PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5UUlVFIFRXSVRURVI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmhlbHAueC5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCI+8J+TsSDguYDguKXguLfguK3guIEgQVBQPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtbnB2IiBpZD0iYXBwLW5wdiIgb25jbGljaz0icGlja0FwcCgnbnB2JykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+PGRpdiBzdHlsZT0id2lkdGg6MzhweDtoZWlnaHQ6MzhweDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMGQyYTNhO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjttYXJnaW46MCBhdXRvIC4xcmVtO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi44NXJlbTtjb2xvcjojMDBjY2ZmO2xldHRlci1zcGFjaW5nOi0xcHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMCwyMDQsMjU1LC4zKSI+blY8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPk5wdiBUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPm5wdnQtc3NoOi8vPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0iYXBwLWRhcmsiIG9uY2xpY2s9InBpY2tBcHAoJ2RhcmsnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMxMTE7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6c2Fucy1zZXJpZjtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi42MnJlbTtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOi41cHg7Ym9yZGVyOjEuNXB4IHNvbGlkICM0NDQiPkRBUks8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRhcmtUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRhcmt0dW5uZWw6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuLXNzaCIgaWQ9InNzaC1idG4iIG9uY2xpY2s9ImNyZWF0ZVNTSCgpIj7inpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXI8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InNzaC1hbGVydCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibGluay1yZXN1bHQiIGlkPSJzc2gtbGluay1yZXN1bHQiPjwvZGl2PgogICAgICA8L2Rpdj4KCiAgICAgIDwhLS0gVXNlciB0YWJsZSAtLT4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbjowIj7wn5OLIOC4o+C4suC4ouC4iuC4t+C5iOC4rSBVU0VSUzwvZGl2PgogICAgICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0ic3NoLXNlYXJjaCIgcGxhY2Vob2xkZXI9IuC4hOC5ieC4meC4q+C4si4uLiIgb25pbnB1dD0iZmlsdGVyU1NIVXNlcnModGhpcy52YWx1ZSkiCiAgICAgICAgICAgIHN0eWxlPSJ3aWR0aDoxMjBweDttYXJnaW46MDtmb250LXNpemU6MTFweDtwYWRkaW5nOjZweCAxMHB4Ij4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1dGJsLXdyYXAiPgogICAgICAgICAgPHRhYmxlIGNsYXNzPSJ1dGJsIj4KICAgICAgICAgICAgPHRoZWFkPjx0cj48dGg+IzwvdGg+PHRoPlVTRVJOQU1FPC90aD48dGg+4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC90aD48dGg+4Liq4LiW4Liy4LiZ4LiwPC90aD48dGg+QUNUSU9OPC90aD48L3RyPjwvdGhlYWQ+CiAgICAgICAgICAgIDx0Ym9keSBpZD0ic3NoLXVzZXItdGJvZHkiPjx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MjBweDtjb2xvcjp2YXIoLS1tdXRlZCkiPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvdGQ+PC90cj48L3Rib2R5PgogICAgICAgICAgPC90YWJsZT4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgPC9kaXY+PCEtLSAvdGFiLWNyZWF0ZSAtLT4KCjwhLS0g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW1hbmFnZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4quC5gOC4i+C4reC4o+C5jCBWTEVTUzwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkVXNlcnMoKSI+4oa7IOC5guC4q+C4peC4lDwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0idXNlci1zZWFyY2giIHBsYWNlaG9sZGVyPSLwn5SNICDguITguYnguJnguKvguLIgdXNlcm5hbWUuLi4iIG9uaW5wdXQ9ImZpbHRlclVzZXJzKHRoaXMudmFsdWUpIj4KICAgICAgPGRpdiBpZD0idXNlci1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguJvguLjguYjguKHguYLguKvguKXguJTguYDguJ7guLfguYjguK3guJTguLbguIfguILguYnguK3guKHguLnguKU8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1vbmxpbmUiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+8J+foiDguKLguLnguKrguYDguIvguK3guKPguYzguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZE9ubGluZSgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvY3IiPgogICAgICAgIDxkaXYgY2xhc3M9Im9waWxsIiBpZD0ib25saW5lLXBpbGwiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj48c3BhbiBpZD0ib25saW5lLWNvdW50Ij4wPC9zcGFuPiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0idXQiIGlkPSJvbmxpbmUtdGltZSI+LS08L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4LiU4Lij4Li14LmA4Lif4Lij4LiK4LmA4Lie4Li34LmI4Lit4LiU4Li54Lic4Li54LmJ4LmD4LiK4LmJ4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQkFOIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItYmFuIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiPvCfmqsg4LiI4Lix4LiU4LiB4Liy4LijIFNTSCBVc2VyczwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBVU0VSTkFNRTwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJiYW4tdXNlciIgcGxhY2Vob2xkZXI9IuC5g+C4quC5iCB1c2VybmFtZSDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguKXguJoiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNTgwM2QsIzIyYzU1ZSkiIG9uY2xpY2s9ImRlbGV0ZVNTSCgpIj7wn5eR77iPIOC4peC4miBTU0ggVXNlcjwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImJhbi1hbGVydCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+TiyBTU0ggVXNlcnMg4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgaWQ9InNzaC11c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+Cgo8L2Rpdj48IS0tIC93cmFwIC0tPgoKPCEtLSBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJtb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbSgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIiBpZD0ibXQiPuKame+4jyB1c2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY20oKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6EgUG9ydDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkcCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9ImRlIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TpiBEYXRhIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TiiBUcmFmZmljIOC5g+C4iuC5iTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdHIiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OxIElQIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRpIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBtb25vIiBpZD0iZHV1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTBweCI+4LmA4Lil4Li34Lit4LiB4LiB4Liy4Lij4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3JlbmV3JykiPjxkaXYgY2xhc3M9ImFpIj7wn5SEPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignZXh0ZW5kJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OFPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignYWRkZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+8J+TpjwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guYDguJ7guLTguYjguKEgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4LihPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3NldGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPuKalu+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguLHguYnguIcgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guIHguLPguKvguJnguJTguYPguKvguKHguYg8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVzZXQnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIM8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4gZGFuZ2VyIiBvbmNsaWNrPSJtQWN0aW9uKCdkZWxldGUnKSI+PGRpdiBjbGFzcz0iYWkiPvCfl5HvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lil4Lia4Lii4Li54LiqPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4peC4muC4luC4suC4p+C4ozwvZGl2PjwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC5iOC4reC4reC4suC4ouC4uCAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZW5ldyI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCDigJQg4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVuZXctYnRuIiBvbmNsaWNrPSJkb1JlbmV3VXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWV4dGVuZCI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OFIOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSDigJQg4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1leHRlbmQtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWV4dGVuZC1idG4iIG9uY2xpY2s9ImRvRXh0ZW5kVXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4LihIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItYWRkZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OmIOC5gOC4nuC4tOC5iOC4oSBEYXRhIOKAlCDguYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4Lih4LiI4Liy4LiB4LiX4Li14LmI4Lih4Li14Lit4Lii4Li54LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJkgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tYWRkZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMTAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWFkZGRhdGEtYnRuIiBvbmNsaWNrPSJkb0FkZERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oSBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4Lix4LmJ4LiHIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItc2V0ZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7impbvuI8g4LiV4Lix4LmJ4LiHIERhdGEg4oCUIOC4geC4s+C4q+C4meC4lCBMaW1pdCDguYPguKvguKHguYggKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj5EYXRhIExpbWl0IChHQikg4oCUIDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1zZXRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1zZXRkYXRhLWJ0biIgb25jbGljaz0iZG9TZXREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguLHguYnguIcgRGF0YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlc2V0Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIMg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4oCUIOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5ieC4l+C4seC5ieC4h+C4q+C4oeC4lDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guIHguLLguKPguKPguLXguYDguIvguJUgVHJhZmZpYyDguIjguLDguYDguITguKXguLXguKLguKPguYzguKLguK3guJQgVXBsb2FkL0Rvd25sb2FkIOC4l+C4seC5ieC4h+C4q+C4oeC4lOC4guC4reC4h+C4ouC4ueC4quC4meC4teC5iTwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZXNldC1idG4iIG9uY2xpY2s9ImRvUmVzZXRUcmFmZmljKCkiPuKchSDguKLguLfguJnguKLguLHguJnguKPguLXguYDguIvguJUgVHJhZmZpYzwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4peC4muC4ouC4ueC4qiAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1kZWxldGUiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPvCfl5HvuI8g4Lil4Lia4Lii4Li54LiqIOKAlCDguKXguJrguJbguLLguKfguKMg4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LiB4Li54LmJ4LiE4Li34LiZ4LmE4LiU4LmJPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4ouC4ueC4qiA8YiBpZD0ibS1kZWwtbmFtZSIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPjwvYj4g4LiI4Liw4LiW4Li54LiB4Lil4Lia4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4Lia4LiW4Liy4Lin4LijPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWRlbGV0ZS1idG4iIG9uY2xpY2s9ImRvRGVsZXRlVXNlcigpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNkYzI2MjYsI2VmNDQ0NCkiPvCfl5HvuI8g4Lii4Li34LiZ4Lii4Lix4LiZ4Lil4Lia4Lii4Li54LiqPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9Im1vZGFsLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIiBvbmVycm9yPSJ3aW5kb3cuQ0hBSVlBX0NPTkZJRz17fSI+PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8vIOKVkOKVkOKVkOKVkCBDT05GSUcg4pWQ4pWQ4pWQ4pWQCmNvbnN0IENGRyA9ICh0eXBlb2Ygd2luZG93LkNIQUlZQV9DT05GSUcgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdy5DSEFJWUFfQ09ORklHIDoge307CmNvbnN0IEhPU1QgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKY29uc3QgWFVJICA9IChDRkcuYmFzZXBhdGggfHwgJy94dWktYXBpJykucmVwbGFjZSgvXC8kLywgJycpOwpjb25zdCBBUEkgID0gJy9hcGknOwpjb25zdCBTRVNTSU9OX0tFWSA9ICdjaGFpeWFfYXV0aCc7CgovLyBTZXNzaW9uIGNoZWNrCmNvbnN0IF9zID0gKCgpID0+IHsgdHJ5IHsgcmV0dXJuIEpTT04ucGFyc2Uoc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSl8fCd7fScpOyB9IGNhdGNoKGUpe3JldHVybnt9O30gfSkoKTsKaWYgKCFfcy51c2VyIHx8ICFfcy5wYXNzIHx8IERhdGUubm93KCkgPj0gKF9zLmV4cHx8MCkpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8vIEhlYWRlciBkb21haW4KZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1kb21haW4nKS50ZXh0Q29udGVudCA9IEhPU1QgKyAnIMK3IHY1JzsKCi8vIOKVkOKVkOKVkOKVkCBVVElMUyDilZDilZDilZDilZAKZnVuY3Rpb24gZm10Qnl0ZXMoYikgewogIGlmICghYiB8fCBiID09PSAwKSByZXR1cm4gJzAgQic7CiAgY29uc3QgayA9IDEwMjQsIHUgPSBbJ0InLCdLQicsJ01CJywnR0InLCdUQiddOwogIGNvbnN0IGkgPSBNYXRoLmZsb29yKE1hdGgubG9nKGIpL01hdGgubG9nKGspKTsKICByZXR1cm4gKGIvTWF0aC5wb3coayxpKSkudG9GaXhlZCgxKSsnICcrdVtpXTsKfQpmdW5jdGlvbiBmbXREYXRlKG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGNvbnN0IGQgPSBuZXcgRGF0ZShtcyk7CiAgcmV0dXJuIGQudG9Mb2NhbGVEYXRlU3RyaW5nKCd0aC1USCcse3llYXI6J251bWVyaWMnLG1vbnRoOidzaG9ydCcsZGF5OidudW1lcmljJ30pOwp9CmZ1bmN0aW9uIGRheXNMZWZ0KG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuIG51bGw7CiAgcmV0dXJuIE1hdGguY2VpbCgobXMgLSBEYXRlLm5vdygpKSAvIDg2NDAwMDAwKTsKfQpmdW5jdGlvbiBzZXRSaW5nKGlkLCBwY3QpIHsKICBjb25zdCBjaXJjID0gMTM4LjI7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKGVsKSBlbC5zdHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gY2lyYyAtIChjaXJjICogTWF0aC5taW4ocGN0LDEwMCkgLyAxMDApOwp9CmZ1bmN0aW9uIHNldEJhcihpZCwgcGN0LCB3YXJuPWZhbHNlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLnN0eWxlLndpZHRoID0gTWF0aC5taW4ocGN0LDEwMCkgKyAnJSc7CiAgaWYgKHdhcm4gJiYgcGN0ID4gODUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNlZjQ0NDQsI2RjMjYyNiknOwogIGVsc2UgaWYgKHdhcm4gJiYgcGN0ID4gNjUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNmOTczMTYsI2ZiOTIzYyknOwp9CmZ1bmN0aW9uIHNob3dBbGVydChpZCwgbXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLmNsYXNzTmFtZSA9ICdhbGVydCAnK3R5cGU7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgaWYgKHR5cGUgPT09ICdvaycpIHNldFRpbWVvdXQoKCk9PntlbC5zdHlsZS5kaXNwbGF5PSdub25lJzt9LCAzMDAwKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE5BViDilZDilZDilZDilZAKZnVuY3Rpb24gc3cobmFtZSwgZWwpIHsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuc2VjJykuZm9yRWFjaChzPT5zLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcubmF2LWl0ZW0nKS5mb3JFYWNoKG49Pm4uY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWItJytuYW1lKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBlbC5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBpZiAobmFtZT09PSdjcmVhdGUnKSBjbG9zZUZvcm0oKTsKICBpZiAobmFtZT09PSdkYXNoYm9hcmQnKSBsb2FkRGFzaCgpOwogIGlmIChuYW1lPT09J21hbmFnZScpIGxvYWRVc2VycygpOwogIGlmIChuYW1lPT09J29ubGluZScpIGxvYWRPbmxpbmUoKTsKICBpZiAobmFtZT09PSdiYW4nKSBsb2FkU1NIVXNlcnMoKTsKfQoKLy8g4pSA4pSAIEZvcm0gbmF2IOKUgOKUgApsZXQgX2N1ckZvcm0gPSBudWxsOwpmdW5jdGlvbiBvcGVuRm9ybShpZCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9IGY9PT1pZCA/ICdibG9jaycgOiAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBpZDsKICBpZiAoaWQ9PT0nc3NoJykgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgd2luZG93LnNjcm9sbFRvKDAsMCk7Cn0KZnVuY3Rpb24gY2xvc2VGb3JtKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIFsnYWlzJywndHJ1ZScsJ3NzaCddLmZvckVhY2goZiA9PiB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9ybS0nK2YpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBudWxsOwp9CgpsZXQgX3dzUG9ydCA9ICc4MCc7CmZ1bmN0aW9uIHRvZ1BvcnQoYnRuLCBwb3J0KSB7CiAgX3dzUG9ydCA9IHBvcnQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzODAtYnRuJykuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgcG9ydD09PSc4MCcpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd3czQ0My1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzQ0MycpOwp9CmZ1bmN0aW9uIHRvZ0dyb3VwKGJ0biwgY2xzKSB7CiAgYnRuLmNsb3Nlc3QoJ2RpdicpLnF1ZXJ5U2VsZWN0b3JBbGwoY2xzKS5mb3JFYWNoKGI9PmIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGJ0bi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIFhVSSBMT0dJTiAoY29va2llKSDilZDilZDilZDilZAKbGV0IF94dWlPayA9IGZhbHNlOwphc3luYyBmdW5jdGlvbiB4dWlMb2dpbigpIHsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyLCBwYXNzd29yZDogX3MucGFzcyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aU9rID0gISFkLnN1Y2Nlc3M7CiAgcmV0dXJuIF94dWlPazsKfQphc3luYyBmdW5jdGlvbiB4dWlHZXQocGF0aCkgewogIGlmICghX3h1aU9rKSBhd2FpdCB4dWlMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIHJldHVybiByLmpzb24oKTsKfQphc3luYyBmdW5jdGlvbiB4dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICBib2R5OiBKU09OLnN0cmluZ2lmeShib2R5KQogIH0pOwogIHJldHVybiByLmpzb24oKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZERhc2goKSB7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1yZWZyZXNoJyk7CiAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyAuLi4nOwogIF94dWlPayA9IGZhbHNlOyAvLyBmb3JjZSByZS1sb2dpbiDguYDguKrguKHguK0KCiAgdHJ5IHsKICAgIC8vIFNTSCBBUEkgc3RhdHVzCiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChzdCkgewogICAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgICB9CgogICAgLy8gWFVJIHNlcnZlciBzdGF0dXMKICAgIGNvbnN0IG9rID0gYXdhaXQgeHVpTG9naW4oKTsKICAgIGlmICghb2spIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+TG9naW4g4LmE4Lih4LmI4LmE4LiU4LmJJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0gJ29waWxsIG9mZic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHN2ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL3NlcnZlci9zdGF0dXMnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3YgJiYgc3Yuc3VjY2VzcyAmJiBzdi5vYmopIHsKICAgICAgY29uc3QgbyA9IHN2Lm9iajsKICAgICAgLy8gQ1BVCiAgICAgIGNvbnN0IGNwdSA9IE1hdGgucm91bmQoby5jcHUgfHwgMCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtcGN0JykudGV4dENvbnRlbnQgPSBjcHUgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtY29yZXMnKS50ZXh0Q29udGVudCA9IChvLmNwdUNvcmVzIHx8IG8ubG9naWNhbFBybyB8fCAnLS0nKSArICcgY29yZXMnOwogICAgICBzZXRSaW5nKCdjcHUtcmluZycsIGNwdSk7IHNldEJhcignY3B1LWJhcicsIGNwdSwgdHJ1ZSk7CgogICAgICAvLyBSQU0KICAgICAgY29uc3QgcmFtVCA9ICgoby5tZW0/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgcmFtVSA9ICgoby5tZW0/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCByYW1QID0gcmFtVCA+IDAgPyBNYXRoLnJvdW5kKHJhbVUvcmFtVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1wY3QnKS50ZXh0Q29udGVudCA9IHJhbVAgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tZGV0YWlsJykudGV4dENvbnRlbnQgPSByYW1VLnRvRml4ZWQoMSkrJyAvICcrcmFtVC50b0ZpeGVkKDEpKycgR0InOwogICAgICBzZXRSaW5nKCdyYW0tcmluZycsIHJhbVApOyBzZXRCYXIoJ3JhbS1iYXInLCByYW1QLCB0cnVlKTsKCiAgICAgIC8vIERpc2sKICAgICAgY29uc3QgZHNrVCA9ICgoby5kaXNrPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIGRza1UgPSAoKG8uZGlzaz8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IGRza1AgPSBkc2tUID4gMCA/IE1hdGgucm91bmQoZHNrVS9kc2tUKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1wY3QnKS5pbm5lckhUTUwgPSBkc2tQICsgJzxzcGFuPiU8L3NwYW4+JzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stZGV0YWlsJykudGV4dENvbnRlbnQgPSBkc2tVLnRvRml4ZWQoMCkrJyAvICcrZHNrVC50b0ZpeGVkKDApKycgR0InOwogICAgICBzZXRCYXIoJ2Rpc2stYmFyJywgZHNrUCwgdHJ1ZSk7CgogICAgICAvLyBVcHRpbWUKICAgICAgY29uc3QgdXAgPSBvLnVwdGltZSB8fCAwOwogICAgICBjb25zdCB1ZCA9IE1hdGguZmxvb3IodXAvODY0MDApLCB1aCA9IE1hdGguZmxvb3IoKHVwJTg2NDAwKS8zNjAwKSwgdW0gPSBNYXRoLmZsb29yKCh1cCUzNjAwKS82MCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtdmFsJykudGV4dENvbnRlbnQgPSB1ZCA+IDAgPyB1ZCsnZCAnK3VoKydoJyA6IHVoKydoICcrdW0rJ20nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXN1YicpLnRleHRDb250ZW50ID0gdWQrJ+C4p+C4seC4mSAnK3VoKyfguIrguKEuICcrdW0rJ+C4meC4suC4l+C4tSc7CiAgICAgIGNvbnN0IGxvYWRzID0gby5sb2FkcyB8fCBbXTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvYWQtY2hpcHMnKS5pbm5lckhUTUwgPSBsb2Fkcy5tYXAoKGwsaSk9PgogICAgICAgIGA8c3BhbiBjbGFzcz0iYmRnIj4ke1snMW0nLCc1bScsJzE1bSddW2ldfTogJHtsLnRvRml4ZWQoMil9PC9zcGFuPmApLmpvaW4oJycpOwoKICAgICAgLy8gTmV0d29yawogICAgICBpZiAoby5uZXRJTykgewogICAgICAgIGNvbnN0IHVwX2IgPSBvLm5ldElPLnVwfHwwLCBkbl9iID0gby5uZXRJTy5kb3dufHwwOwogICAgICAgIGNvbnN0IHVwRm10ID0gZm10Qnl0ZXModXBfYiksIGRuRm10ID0gZm10Qnl0ZXMoZG5fYik7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cCcpLmlubmVySFRNTCA9IHVwRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4nKS5pbm5lckhUTUwgPSBkbkZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgfQogICAgICBpZiAoby5uZXRUcmFmZmljKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cC10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5zZW50fHwwKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnJlY3Z8fDApOwogICAgICB9CgogICAgICAvLyBYVUkgdmVyc2lvbgogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXZlcicpLnRleHRDb250ZW50ID0gby54cmF5VmVyc2lvbiB8fCAnLS0nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPuC4reC4reC4meC5hOC4peC4meC5jCc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCc7CiAgICB9CgogICAgLy8gSW5ib3VuZHMgY291bnQKICAgIGNvbnN0IGlibCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKGlibCAmJiBpYmwuc3VjY2VzcykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLWluYm91bmRzJykudGV4dENvbnRlbnQgPSAoaWJsLm9ianx8W10pLmxlbmd0aDsKICAgIH0KCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGFzdC11cGRhdGUnKS50ZXh0Q29udGVudCA9ICfguK3guLHguJ7guYDguJTguJfguKXguYjguLLguKrguLjguJQ6ICcgKyBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnNvbGUuZXJyb3IoZSk7CiAgfSBmaW5hbGx5IHsKICAgIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsg4Lij4Li14LmA4Lif4Lij4LiKJzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTRVJWSUNFUyDilZDilZDilZDilZAKY29uc3QgU1ZDX0RFRiA9IFsKICB7IGtleToneHVpJywgICAgICBpY29uOifwn5OhJywgbmFtZToneC11aSBQYW5lbCcsICAgICAgcG9ydDonOjIwNTMnIH0sCiAgeyBrZXk6J3NzaCcsICAgICAgaWNvbjon8J+QjScsIG5hbWU6J1NTSCBBUEknLCAgICAgICAgICBwb3J0Oic6Njc4OScgfSwKICB7IGtleTonZHJvcGJlYXInLCBpY29uOifwn5C7JywgbmFtZTonRHJvcGJlYXIgU1NIJywgICAgIHBvcnQ6JzoxNDMgOjEwOScgfSwKICB7IGtleTonbmdpbngnLCAgICBpY29uOifwn4yQJywgbmFtZTonbmdpbnggLyBQYW5lbCcsICAgIHBvcnQ6Jzo4MCA6NDQzJyB9LAogIHsga2V5Oidzc2h3cycsICAgIGljb246J/CflJInLCBuYW1lOidXUy1TdHVubmVsJywgICAgICAgcG9ydDonOjgw4oaSOjE0MycgfSwKICB7IGtleTonYmFkdnBuJywgICBpY29uOifwn46uJywgbmFtZTonQmFkVlBOIFVEUEdXJywgICAgIHBvcnQ6Jzo3MzAwJyB9LApdOwpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcyhtYXApIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSBTVkNfREVGLm1hcChzID0+IHsKICAgIGNvbnN0IHVwID0gbWFwW3Mua2V5XSA9PT0gdHJ1ZSB8fCBtYXBbcy5rZXldID09PSAnYWN0aXZlJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0ic3ZjICR7dXA/Jyc6J2Rvd24nfSI+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1sIj48c3BhbiBjbGFzcz0iZGcgJHt1cD8nJzoncmVkJ30iPjwvc3Bhbj48c3Bhbj4ke3MuaWNvbn08L3NwYW4+CiAgICAgICAgPGRpdj48ZGl2IGNsYXNzPSJzdmMtbiI+JHtzLm5hbWV9PC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPiR7cy5wb3J0fTwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9InJiZGcgJHt1cD8nJzonZG93bid9Ij4ke3VwPydSVU5OSU5HJzonRE9XTid9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQphc3luYyBmdW5jdGlvbiBsb2FkU2VydmljZXMoKSB7CiAgdHJ5IHsKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggUElDS0VSIFNUQVRFIOKVkOKVkOKVkOKVkApjb25zdCBQUk9TID0gewogIGR0YWM6IHsKICAgIG5hbWU6ICdEVEFDIEdBTUlORycsCiAgICBwcm94eTogJzEwNC4xOC42My4xMjQ6ODAnLAogICAgcGF5bG9hZDogJ0NPTk5FQ1QgLyAgSFRUUC8xLjEgW2NybGZdSG9zdDogZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbSBbY3JsZl1bY3JsZl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDpbaG9zdF1bY3JsZl1VcGdyYWRlOlVzZXItQWdlbnQ6IFt1YV1bY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfSwKICB0cnVlOiB7CiAgICBuYW1lOiAnVFJVRSBUV0lUVEVSJywKICAgIHByb3h5OiAnMTA0LjE4LjM5LjI0OjgwJywKICAgIHBheWxvYWQ6ICdQT1NUIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OmhlbHAueC5jb21bY3JsZl1Vc2VyLUFnZW50OiBbdWFdW2NybGZdW2NybGZdW3NwbGl0XVtjcl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDogW2hvc3RdW2NybGZdVXBncmFkZTogd2Vic29ja2V0W2NybGZdQ29ubmVjdGlvbjpVcGdyYWRlW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0KfTsKY29uc3QgTlBWX0hPU1QgPSAnd3d3LnByb2plY3QuZ29kdnBuLnNob3AnLCBOUFZfUE9SVCA9IDgwOwpsZXQgX3NzaFBybyA9ICdkdGFjJywgX3NzaEFwcCA9ICducHYnLCBfc3NoUG9ydCA9ICc4MCc7CgpmdW5jdGlvbiBwaWNrUG9ydChwKSB7CiAgX3NzaFBvcnQgPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi04MCcpLmNsYXNzTmFtZSAgPSAncG9ydC1idG4nICsgKHA9PT0nODAnICA/ICcgYWN0aXZlLXA4MCcgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi00NDMnKS5jbGFzc05hbWUgPSAncG9ydC1idG4nICsgKHA9PT0nNDQzJyA/ICcgYWN0aXZlLXA0NDMnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tQcm8ocCkgewogIF9zc2hQcm8gPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tZHRhYycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSdkdGFjJyA/ICcgYS1kdGFjJyA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLXRydWUnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0ndHJ1ZScgPyAnIGEtdHJ1ZScgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja0FwcChhKSB7CiAgX3NzaEFwcCA9IGE7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcC1ucHYnKS5jbGFzc05hbWUgID0gJ3BpY2stb3B0JyArIChhPT09J25wdicgID8gJyBhLW5wdicgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtZGFyaycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAoYT09PSdkYXJrJyA/ICcgYS1kYXJrJyA6ICcnKTsKfQpmdW5jdGlvbiBidWlsZE5wdkxpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgaiA9IHsKICAgIHNzaENvbmZpZ1R5cGU6J1NTSC1Qcm94eS1QYXlsb2FkJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6TlBWX0hPU1QsIHNzaFBvcnQ6TlBWX1BPUlQsCiAgICBzc2hVc2VybmFtZTpuYW1lLCBzc2hQYXNzd29yZDpwYXNzLAogICAgc25pOicnLCB0bHNWZXJzaW9uOidERUZBVUxUJywKICAgIGh0dHBQcm94eTpwcm8ucHJveHksIGF1dGhlbnRpY2F0ZVByb3h5OmZhbHNlLAogICAgcHJveHlVc2VybmFtZTonJywgcHJveHlQYXNzd29yZDonJywKICAgIHBheWxvYWQ6cHJvLnBheWxvYWQsCiAgICBkbnNNb2RlOidVRFAnLCBkbnNTZXJ2ZXI6JycsIG5hbWVzZXJ2ZXI6JycsIHB1YmxpY0tleTonJywKICAgIHVkcGd3UG9ydDo3MzAwLCB1ZHBnd1RyYW5zcGFyZW50RE5TOnRydWUKICB9OwogIHJldHVybiAnbnB2dC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KZnVuY3Rpb24gYnVpbGREYXJrTGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBwcCA9IChwcm8ucHJveHl8fCcnKS5zcGxpdCgnOicpOwogIGNvbnN0IGRoID0gcHBbMF0gfHwgcHJvLmRhcmtQcm94eTsKICBjb25zdCBqID0gewogICAgY29uZmlnVHlwZTonU1NILVBST1hZJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6SE9TVCwgc3NoUG9ydDoxNDMsCiAgICBzc2hVc2VyOm5hbWUsIHNzaFBhc3M6cGFzcywKICAgIHBheWxvYWQ6J0dFVCAvIEhUVFAvMS4xXHJcbkhvc3Q6ICcrSE9TVCsnXHJcblVwZ3JhZGU6IHdlYnNvY2tldFxyXG5Db25uZWN0aW9uOiBVcGdyYWRlXHJcblxyXG4nLAogICAgcHJveHlIb3N0OmRoLCBwcm94eVBvcnQ6ODAsCiAgICB1ZHBnd0FkZHI6JzEyNy4wLjAuMScsIHVkcGd3UG9ydDo3MzAwLCB0bHNFbmFibGVkOmZhbHNlCiAgfTsKICByZXR1cm4gJ2Rhcmt0dW5uZWwtc3NoOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CgovLyDilZDilZDilZDilZAgQ1JFQVRFIFNTSCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1kYXlzJykudmFsdWUpfHwzMDsKICBjb25zdCBpcGwgID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpID8gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpLnZhbHVlIDogMil8fDI7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIXBhc3MpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBQYXNzd29yZCcsJ2VycicpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMzQsMTk3LDk0LC4zKTtib3JkZXItdG9wLWNvbG9yOiMyMmM1NWUiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBjb25zdCByZXNFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtbGluay1yZXN1bHQnKTsKICBpZiAocmVzRWwpIHJlc0VsLmNsYXNzTmFtZT0nbGluay1yZXN1bHQnOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvY3JlYXRlX3NzaCcsIHsKICAgICAgbWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoe3VzZXIsIHBhc3N3b3JkOnBhc3MsIGRheXMsIGlwX2xpbWl0OmlwbH0pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0IHBybyAgPSBQUk9TW19zc2hQcm9dIHx8IFBST1MuZHRhYzsKICAgIGNvbnN0IGxpbmsgPSBfc3NoQXBwPT09J25wdicgPyBidWlsZE5wdkxpbmsodXNlcixwYXNzLHBybykgOiBidWlsZERhcmtMaW5rKHVzZXIscGFzcyxwcm8pOwogICAgY29uc3QgaXNOcHYgPSBfc3NoQXBwPT09J25wdic7CiAgICBjb25zdCBscENscyA9IGlzTnB2ID8gJycgOiAnIGRhcmstbHAnOwogICAgY29uc3QgY0NscyAgPSBpc05wdiA/ICducHYnIDogJ2RhcmsnOwogICAgY29uc3QgYXBwTGFiZWwgPSBpc05wdiA/ICdOcHZ0JyA6ICdEYXJrVHVubmVsJzsKCiAgICBpZiAocmVzRWwpIHsKICAgICAgcmVzRWwuY2xhc3NOYW1lID0gJ2xpbmstcmVzdWx0IHNob3cnOwogICAgICBjb25zdCBzYWZlTGluayA9IGxpbmsucmVwbGFjZSgvXFwvZywnXFxcXCcpLnJlcGxhY2UoLycvZywiXFwnIik7CiAgICAgIHJlc0VsLmlubmVySFRNTCA9CiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcmVzdWx0LWhkcic+IiArCiAgICAgICAgICAiPHNwYW4gY2xhc3M9J2ltcC1iYWRnZSAiK2NDbHMrIic+IithcHBMYWJlbCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOnZhcigtLW11dGVkKSc+Iitwcm8ubmFtZSsiIFx4YjcgUG9ydCAiK19zc2hQb3J0KyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6IzIyYzU1ZTttYXJnaW4tbGVmdDphdXRvJz5cdTI3MDUgIit1c2VyKyI8L3NwYW4+IiArCiAgICAgICAgIjwvZGl2PiIgKwogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXByZXZpZXciK2xwQ2xzKyInPiIrbGluaysiPC9kaXY+IiArCiAgICAgICAgIjxidXR0b24gY2xhc3M9J2NvcHktbGluay1idG4gIitjQ2xzKyInIGlkPSdjb3B5LXNzaC1idG4nIG9uY2xpY2s9XCJjb3B5U1NITGluaygpXCI+IisKICAgICAgICAgICJcdWQ4M2RcdWRjY2IgQ29weSAiK2FwcExhYmVsKyIgTGluayIrCiAgICAgICAgIjwvYnV0dG9uPiI7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExpbmsgPSBsaW5rOwogICAgICB3aW5kb3cuX2xhc3RTU0hBcHAgID0gY0NsczsKICAgICAgd2luZG93Ll9sYXN0U1NITGFiZWwgPSBhcHBMYWJlbDsKICAgIH0KCiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIIMK3IOC4q+C4oeC4lOC4reC4suC4ouC4uCAnK2QuZXhwLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWU9Jyc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZT0nJzsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfinpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXInOyB9Cn0KZnVuY3Rpb24gY29weVNTSExpbmsoKSB7CiAgY29uc3QgbGluayA9IHdpbmRvdy5fbGFzdFNTSExpbmt8fCcnOwogIGNvbnN0IGNDbHMgPSB3aW5kb3cuX2xhc3RTU0hBcHB8fCducHYnOwogIGNvbnN0IGxhYmVsID0gd2luZG93Ll9sYXN0U1NITGFiZWx8fCdMaW5rJzsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dChsaW5rKS50aGVuKGZ1bmN0aW9uKCl7CiAgICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvcHktc3NoLWJ0bicpOwogICAgaWYoYil7IGIudGV4dENvbnRlbnQ9J1x1MjcwNSDguITguLHguJTguKXguK3guIHguYHguKXguYnguKchJzsgc2V0VGltZW91dChmdW5jdGlvbigpe2IudGV4dENvbnRlbnQ9J1x1ZDgzZFx1ZGNjYiBDb3B5ICcrbGFiZWwrJyBMaW5rJzt9LDIwMDApOyB9CiAgfSkuY2F0Y2goZnVuY3Rpb24oKXsgcHJvbXB0KCdDb3B5IGxpbms6JyxsaW5rKTsgfSk7Cn0KCi8vIFNTSCB1c2VyIHRhYmxlCmxldCBfc3NoVGFibGVVc2VycyA9IFtdOwphc3luYyBmdW5jdGlvbiBsb2FkU1NIVGFibGVJbkZvcm0oKSB7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgX3NzaFRhYmxlVXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICAgIGlmKHRiKSB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiNlZjQ0NDQ7cGFkZGluZzoxNnB4Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gU1NIIEFQSSDguYTguKHguYjguYTguJTguYk8L3RkPjwvdHI+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyU1NIVGFibGUodXNlcnMpIHsKICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogIGlmICghdGIpIHJldHVybjsKICBpZiAoIXVzZXJzLmxlbmd0aCkgewogICAgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzoyMHB4Ij7guYTguKHguYjguKHguLUgU1NIIHVzZXJzPC90ZD48L3RyPic7CiAgICByZXR1cm47CiAgfQogIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICB0Yi5pbm5lckhUTUwgPSB1c2Vycy5tYXAoZnVuY3Rpb24odSxpKXsKICAgIGNvbnN0IGV4cGlyZWQgPSB1LmV4cCAmJiB1LmV4cCA8IG5vdzsKICAgIGNvbnN0IGFjdGl2ZSAgPSB1LmFjdGl2ZSAhPT0gZmFsc2UgJiYgIWV4cGlyZWQ7CiAgICBjb25zdCBkTGVmdCAgID0gdS5leHAgPyBNYXRoLmNlaWwoKG5ldyBEYXRlKHUuZXhwKS1EYXRlLm5vdygpKS84NjQwMDAwMCkgOiBudWxsOwogICAgY29uc3QgYmFkZ2UgICA9IGFjdGl2ZQogICAgICA/ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1nIj5BQ1RJVkU8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1yIj5FWFBJUkVEPC9zcGFuPic7CiAgICBjb25zdCBkVGFnID0gZExlZnQhPT1udWxsCiAgICAgID8gJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj4nKyhkTGVmdD4wP2RMZWZ0KydkJzon4Lir4Lih4LiUJykrJzwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj5cdTIyMWU8L3NwYW4+JzsKICAgIHJldHVybiAnPHRyPjx0ZCBzdHlsZT0iY29sb3I6dmFyKC0tbXV0ZWQpIj4nKyhpKzEpKyc8L3RkPicgKwogICAgICAnPHRkPjxiPicrdS51c2VyKyc8L2I+PC90ZD4nICsKICAgICAgJzx0ZCBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6JysoZXhwaXJlZD8nI2VmNDQ0NCc6J3ZhcigtLW11dGVkKScpKyciPicrCiAgICAgICAgKHUuZXhwfHwn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJzwvdGQ+JyArCiAgICAgICc8dGQ+JytiYWRnZSsnPC90ZD4nICsKICAgICAgJzx0ZD48ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjRweDthbGlnbi1pdGVtczpjZW50ZXIiPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguJXguYjguK3guK3guLLguKLguLgiIG9uY2xpY2s9Im9wZW5TU0hSZW5ld01vZGFsKFwnJyt1LnVzZXIrJ1wnKSI+8J+UhDwvYnV0dG9uPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguKXguJoiIG9uY2xpY2s9ImRlbFNTSFVzZXIoXCcnK3UudXNlcisnXCcpIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LC4zKSI+8J+Xke+4jzwvYnV0dG9uPicrCiAgICAgICAgZFRhZysKICAgICAgJzwvZGl2PjwvdGQ+PC90cj4nOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclNTSFVzZXJzKHEpIHsKICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycy5maWx0ZXIoZnVuY3Rpb24odSl7cmV0dXJuICh1LnVzZXJ8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSk7fSkpOwp9Ci8vIFNTSCBSZW5ldyBNb2RhbApsZXQgX3JlbmV3U1NIVXNlciA9ICcnOwpmdW5jdGlvbiBvcGVuU1NIUmVuZXdNb2RhbCh1c2VyKSB7CiAgX3JlbmV3U1NIVXNlciA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy11c2VybmFtZScpLnRleHRDb250ZW50ID0gdXNlcjsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSA9ICczMCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbG9zZVNTSFJlbmV3TW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfcmVuZXdTU0hVc2VyID0gJyc7Cn0KYXN5bmMgZnVuY3Rpb24gZG9TU0hSZW5ldygpIHsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmICghZGF5c3x8ZGF5czw9MCkgcmV0dXJuOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsgYnRuLnRleHRDb250ZW50ID0gJ+C4geC4s+C4peC4seC4h+C4leC5iOC4reC4reC4suC4ouC4uC4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9leHRlbmRfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcjpfcmVuZXdTU0hVc2VyLGRheXN9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguJXguYjguK3guK3guLLguKLguLggJytfcmVuZXdTU0hVc2VyKycgKycrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgY2xvc2VTU0hSZW5ld01vZGFsKCk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsKICB9IGZpbmFsbHkgewogICAgYnRuLmRpc2FibGVkID0gZmFsc2U7IGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gcmVuZXdTU0hVc2VyKHVzZXIpIHsgb3BlblNTSFJlbmV3TW9kYWwodXNlcik7IH0KYXN5bmMgZnVuY3Rpb24gZGVsU1NIVXNlcih1c2VyKSB7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiDguJbguLLguKfguKM/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4Lil4LiaICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgYWxlcnQoJ1x1Mjc0YyAnK2UubWVzc2FnZSk7IH0KfQovLyDilZDilZDilZDilZAgQ1JFQVRFIFZMRVNTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csYz0+ewogICAgY29uc3Qgcj1NYXRoLnJhbmRvbSgpKjE2fDA7IHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3wweDgpKS50b1N0cmluZygxNik7CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gY3JlYXRlVkxFU1MoY2FycmllcikgewogIGNvbnN0IGVtYWlsRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZW1haWwnKTsKICBjb25zdCBkYXlzRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWRheXMnKTsKICBjb25zdCBpcEVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWlwJyk7CiAgY29uc3QgZ2JFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1nYicpOwogIGNvbnN0IGVtYWlsICAgPSBlbWFpbEVsLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzICAgID0gcGFyc2VJbnQoZGF5c0VsLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50KGlwRWwudmFsdWUpfHwyOwogIGNvbnN0IGdiICAgICAgPSBwYXJzZUludChnYkVsLnZhbHVlKXx8MDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBFbWFpbC9Vc2VybmFtZScsJ2VycicpOwoKICBjb25zdCBwb3J0ID0gY2Fycmllcj09PSdhaXMnID8gODA4MCA6IDg4ODA7CiAgY29uc3Qgc25pICA9IGNhcnJpZXI9PT0nYWlzJyA/ICdjai1lYmIuc3BlZWR0ZXN0Lm5ldCcgOiAndHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlcyc7CgogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1idG4nKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CgogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIC8vIOC4q+C4siBpbmJvdW5kIGlkCiAgICBjb25zdCBsaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliID0gKGxpc3Qub2JqfHxbXSkuZmluZCh4PT54LnBvcnQ9PT1wb3J0KTsKICAgIGlmICghaWIpIHRocm93IG5ldyBFcnJvcihg4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCAke3BvcnR9IOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZYCk7CgogICAgY29uc3QgdWlkID0gZ2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXMgPSBkYXlzID4gMCA/IChEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMCkgOiAwOwogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDp1aWQsIGZsb3c6JycsIGVtYWlsLCBsaW1pdElwOmlwTGltaXQsCiAgICAgICAgdG90YWxHQjp0b3RhbEJ5dGVzLCBleHBpcnlUaW1lOmV4cE1zLCBlbmFibGU6dHJ1ZSwgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgbGluayA9IGB2bGVzczovLyR7dWlkfUAke0hPU1R9OiR7cG9ydH0/dHlwZT13cyZzZWN1cml0eT1ub25lJnBhdGg9JTJGdmxlc3MmaG9zdD0ke3NuaX0jJHtlbmNvZGVVUklDb21wb25lbnQoZW1haWwrJy0nKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSl9YDsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1lbWFpbCcpLnRleHRDb250ZW50ID0gZW1haWw7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy11dWlkJykudGV4dENvbnRlbnQgPSB1aWQ7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1leHAnKS50ZXh0Q29udGVudCA9IGV4cE1zID4gMCA/IGZtdERhdGUoZXhwTXMpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1saW5rJykudGV4dENvbnRlbnQgPSBsaW5rOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgIC8vIEdlbmVyYXRlIFFSIGNvZGUKICAgIGNvbnN0IHFyRGl2ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXFyJyk7CiAgICBpZiAocXJEaXYpIHsKICAgICAgcXJEaXYuaW5uZXJIVE1MID0gJyc7CiAgICAgIHRyeSB7CiAgICAgICAgbmV3IFFSQ29kZShxckRpdiwgeyB0ZXh0OiBsaW5rLCB3aWR0aDogMTgwLCBoZWlnaHQ6IDE4MCwgY29ycmVjdExldmVsOiBRUkNvZGUuQ29ycmVjdExldmVsLk0gfSk7CiAgICAgIH0gY2F0Y2gocXJFcnIpIHsgcXJEaXYuaW5uZXJIVE1MID0gJyc7IH0KICAgIH0KICAgIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHIFZMRVNTIEFjY291bnQg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGVtYWlsRWwudmFsdWU9Jyc7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4pqhIOC4quC4o+C5ieC4suC4hyAnKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSsnIEFjY291bnQnOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBNQU5BR0UgVVNFUlMg4pWQ4pWQ4pWQ4pWQCmxldCBfYWxsVXNlcnMgPSBbXSwgX2N1clVzZXIgPSBudWxsOwphc3luYyBmdW5jdGlvbiBsb2FkVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcign4LmC4Lir4Lil4LiU4LmE4Lih4LmI4LmE4LiU4LmJJyk7CiAgICBfYWxsVXNlcnMgPSBbXTsKICAgIChkLm9ianx8W10pLmZvckVhY2goaWIgPT4gewogICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgIF9hbGxVc2Vycy5wdXNoKHsKICAgICAgICAgIGliSWQ6IGliLmlkLCBwb3J0OiBpYi5wb3J0LCBwcm90bzogaWIucHJvdG9jb2wsCiAgICAgICAgICBlbWFpbDogYy5lbWFpbHx8Yy5pZCwgdXVpZDogYy5pZCwKICAgICAgICAgIGV4cDogYy5leHBpcnlUaW1lfHwwLCB0b3RhbDogYy50b3RhbEdCfHwwLAogICAgICAgICAgdXA6IGliLnVwfHwwLCBkb3duOiBpYi5kb3dufHwwLCBsaW1pdElwOiBjLmxpbWl0SXB8fDAKICAgICAgICB9KTsKICAgICAgfSk7CiAgICB9KTsKICAgIHJlbmRlclVzZXJzKF9hbGxVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyVXNlcnModXNlcnMpIHsKICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfk608L2Rpdj48cD7guYTguKHguYjguJ7guJrguKLguLnguKrguYDguIvguK3guKPguYw8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHUgPT4gewogICAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgICBsZXQgYmFkZ2UsIGNsczsKICAgIGlmICghdS5leHAgfHwgdS5leHA9PT0wKSB7IGJhZGdlPSfinJMg4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsgY2xzPSdvayc7IH0KICAgIGVsc2UgaWYgKGRsIDwgMCkgICAgICAgICB7IGJhZGdlPSfguKvguKHguJTguK3guLLguKLguLgnOyBjbHM9J2V4cCc7IH0KICAgIGVsc2UgaWYgKGRsIDw9IDMpICAgICAgICB7IGJhZGdlPSfimqAgJytkbCsnZCc7IGNscz0nc29vbic7IH0KICAgIGVsc2UgICAgICAgICAgICAgICAgICAgICB7IGJhZGdlPSfinJMgJytkbCsnZCc7IGNscz0nb2snOyB9CiAgICBjb25zdCBhdkNscyA9IGRsIDwgMCA/ICdhdi14JyA6ICdhdi1nJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIG9uY2xpY2s9Im9wZW5Vc2VyKCR7SlNPTi5zdHJpbmdpZnkodSkucmVwbGFjZSgvIi9nLCcmcXVvdDsnKX0pIj4KICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YXZDbHN9Ij4keyh1LmVtYWlsfHwnPycpWzBdLnRvVXBwZXJDYXNlKCl9PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS5lbWFpbH08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+UG9ydCAke3UucG9ydH0gwrcgJHtmbXRCeXRlcyh1LnVwK3UuZG93bil9IOC5g+C4iuC5iTwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHtjbHN9Ij4ke2JhZGdlfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsdGVyVXNlcnMocSkgewogIHJlbmRlclVzZXJzKF9hbGxVc2Vycy5maWx0ZXIodT0+KHUuZW1haWx8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSkpKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1PREFMIFVTRVIg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIG9wZW5Vc2VyKHUpIHsKICBpZiAodHlwZW9mIHUgPT09ICdzdHJpbmcnKSB1ID0gSlNPTi5wYXJzZSh1KTsKICBfY3VyVXNlciA9IHU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ210JykudGV4dENvbnRlbnQgPSAn4pqZ77iPICcrdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHUnKS50ZXh0Q29udGVudCA9IHUuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RwJykudGV4dENvbnRlbnQgPSB1LnBvcnQ7CiAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgY29uc3QgZXhwVHh0ID0gIXUuZXhwfHx1LmV4cD09PTAgPyAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJyA6IGZtdERhdGUodS5leHApOwogIGNvbnN0IGRlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RlJyk7CiAgZGUudGV4dENvbnRlbnQgPSBleHBUeHQ7CiAgZGUuY2xhc3NOYW1lID0gJ2R2JyArIChkbCAhPT0gbnVsbCAmJiBkbCA8IDAgPyAnIHJlZCcgOiAnIGdyZWVuJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RkJykudGV4dENvbnRlbnQgPSB1LnRvdGFsID4gMCA/IGZtdEJ5dGVzKHUudG90YWwpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R0cicpLnRleHRDb250ZW50ID0gZm10Qnl0ZXModS51cCt1LmRvd24pOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaScpLnRleHRDb250ZW50ID0gdS5saW1pdElwIHx8ICfiiJ4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdXUnKS50ZXh0Q29udGVudCA9IHUudXVpZDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY20oKXsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7Cn0KCi8vIOKUgOKUgCBNT0RBTCA2LUFDVElPTiBTWVNURU0g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNvbnN0IF9tU3VicyA9IFsncmVuZXcnLCdleHRlbmQnLCdhZGRkYXRhJywnc2V0ZGF0YScsJ3Jlc2V0JywnZGVsZXRlJ107CmZ1bmN0aW9uIG1BY3Rpb24oa2V5KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2tleSk7CiAgY29uc3QgaXNPcGVuID0gZWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgaWYgKCFpc09wZW4pIHsKICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgIGlmIChrZXk9PT0nZGVsZXRlJyAmJiBfY3VyVXNlcikgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZGVsLW5hbWUnKS50ZXh0Q29udGVudCA9IF9jdXJVc2VyLmVtYWlsOwogICAgc2V0VGltZW91dCgoKT0+ZWwuc2Nyb2xsSW50b1ZpZXcoe2JlaGF2aW9yOidzbW9vdGgnLGJsb2NrOiduZWFyZXN0J30pLDEwMCk7CiAgfQp9CmZ1bmN0aW9uIF9tQnRuTG9hZChpZCwgbG9hZGluZywgb3JpZ1RleHQpIHsKICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghYikgcmV0dXJuOwogIGIuZGlzYWJsZWQgPSBsb2FkaW5nOwogIGlmIChsb2FkaW5nKSB7IGIuZGF0YXNldC5vcmlnID0gYi50ZXh0Q29udGVudDsgYi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj4g4LiB4Liz4Lil4Lix4LiH4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijLi4uJzsgfQogIGVsc2UgaWYgKGIuZGF0YXNldC5vcmlnKSBiLnRleHRDb250ZW50ID0gYi5kYXRhc2V0Lm9yaWc7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvUmVuZXdVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tcmVuZXctZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoZGF5cyA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iOC4s+C4meC4p+C4meC4p+C4seC4mScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1yZW5ldy1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgZXhwTXMgPSBEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpfY3VyVXNlci50b3RhbCxleHBpcnlUaW1lOmV4cE1zLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguJXguYjguK3guK3guLLguKLguLjguKrguLPguYDguKPguYfguIggJytkYXlzKycg4Lin4Lix4LiZICjguKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYkpJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVuZXctYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRXh0ZW5kVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWV4dGVuZC1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLWV4dGVuZC1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgYmFzZSA9IChfY3VyVXNlci5leHAgJiYgX2N1clVzZXIuZXhwID4gRGF0ZS5ub3coKSkgPyBfY3VyVXNlci5leHAgOiBEYXRlLm5vdygpOwogICAgY29uc3QgZXhwTXMgPSBiYXNlICsgZGF5cyo4NjQwMDAwMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpfY3VyVXNlci50b3RhbCxleHBpcnlUaW1lOmV4cE1zLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguYDguJ7guLTguYjguKEgJytkYXlzKycg4Lin4Lix4LiZIOC4quC4s+C5gOC4o+C5h+C4iCAo4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUKScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWV4dGVuZC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9BZGREYXRhKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBhZGRHYiA9IHBhcnNlRmxvYXQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tYWRkZGF0YS1nYicpLnZhbHVlKXx8MDsKICBpZiAoYWRkR2IgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIEgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLWFkZGRhdGEtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IG5ld1RvdGFsID0gKF9jdXJVc2VyLnRvdGFsfHwwKSArIGFkZEdiKjEwNzM3NDE4MjQ7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6bmV3VG90YWwsZXhwaXJ5VGltZTpfY3VyVXNlci5leHB8fDAsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSBEYXRhICsnK2FkZEdiKycgR0Ig4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tYWRkZGF0YS1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9TZXREYXRhKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBnYiA9IHBhcnNlRmxvYXQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tc2V0ZGF0YS1nYicpLnZhbHVlKTsKICBpZiAoaXNOYU4oZ2IpfHxnYjwwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tc2V0ZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOnRvdGFsQnl0ZXMsZXhwaXJ5VGltZTpfY3VyVXNlci5leHB8fDAsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC4seC5ieC4hyBEYXRhIExpbWl0ICcrKGdiPjA/Z2IrJyBHQic6J+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcpKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tc2V0ZGF0YS1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9SZXNldFRyYWZmaWMoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIF9tQnRuTG9hZCgnbS1yZXNldC1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL3Jlc2V0Q2xpZW50VHJhZmZpYy8nK19jdXJVc2VyLmVtYWlsKTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxNTAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXJlc2V0LWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0RlbGV0ZVVzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIF9tQnRuTG9hZCgnbS1kZWxldGUtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9kZWxDbGllbnQvJytfY3VyVXNlci51dWlkKTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4peC4muC4ouC4ueC4qiAnK19jdXJVc2VyLmVtYWlsKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDEyMDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIGZhbHNlKTsgfQp9CgovLyDilZDilZDilZDilZAgT05MSU5FIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkT25saW5lKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICBjb25zdCBvZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9vbmxpbmVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgY29uc3QgZW1haWxzID0gKG9kICYmIG9kLm9iaikgPyBvZC5vYmogOiBbXTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YXYgYXYtZyI+8J+fojwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHtlbWFpbH08L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVtIj4ke3UgPyAnUG9ydCAnK3UucG9ydCA6ICdWTEVTUyd9IMK3IOC4reC4reC4meC5hOC4peC4meC5jOC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIG9rIj5PTkxJTkU8L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBVU0VSUyAoYmFuIHRhYikg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCB1c2VycyA9IGQudXNlcnMgfHwgW107CiAgICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvcD48L2Rpdj4nOyByZXR1cm47IH0KICAgIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHU9PnsKICAgICAgY29uc3QgZXhwID0gdS5leHAgfHwgJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICAgIGNvbnN0IGFjdGl2ZSA9IHUuYWN0aXZlICE9PSBmYWxzZTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YWN0aXZlPydhdi1nJzonYXYteCd9Ij4ke3UudXNlclswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LnVzZXJ9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+4Lir4Lih4LiU4Lit4Liy4Lii4Li4OiAke2V4cH08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2FjdGl2ZT8nb2snOidleHAnfSI+JHthY3RpdmU/J0FjdGl2ZSc6J0V4cGlyZWQnfTwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsZXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZS50cmltKCk7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciID8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSl9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3J8fCfguKXguJrguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVXNlcnMoKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBDT1BZIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBjb3B5TGluayhpZCwgYnRuKSB7CiAgY29uc3QgdHh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHR4dCkudGhlbigoKT0+ewogICAgY29uc3Qgb3JpZyA9IGJ0bi50ZXh0Q29udGVudDsKICAgIGJ0bi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0ncmdiYSgzNCwxOTcsOTQsLjE1KSc7CiAgICBzZXRUaW1lb3V0KCgpPT57IGJ0bi50ZXh0Q29udGVudD1vcmlnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0nJzsgfSwgMjAwMCk7CiAgfSkuY2F0Y2goKCk9PnsgcHJvbXB0KCdDb3B5IGxpbms6JywgdHh0KTsgfSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBMT0dPVVQg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGRvTG9nb3V0KCkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIElOSVQg4pWQ4pWQ4pWQ4pWQCmxvYWREYXNoKCk7CmxvYWRTZXJ2aWNlcygpOwpzZXRJbnRlcnZhbChsb2FkRGFzaCwgMzAwMDApOwo8L3NjcmlwdD4KCjwhLS0gU1NIIFJFTkVXIE1PREFMIC0tPgo8ZGl2IGNsYXNzPSJtb3ZlciIgaWQ9InNzaC1yZW5ldy1tb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbG9zZVNTSFJlbmV3TW9kYWwoKSI+CiAgPGRpdiBjbGFzcz0ibW9kYWwiPgogICAgPGRpdiBjbGFzcz0ibWhkciI+CiAgICAgIDxkaXYgY2xhc3M9Im10aXRsZSI+8J+UhCDguJXguYjguK3guK3guLLguKLguLggU1NIIFVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbG9zZVNTSFJlbmV3TW9kYWwoKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBVc2VybmFtZTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYgZ3JlZW4iIGlkPSJzc2gtcmVuZXctdXNlcm5hbWUiPi0tPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJmZyIgc3R5bGU9Im1hcmdpbi10b3A6MTRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4meC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLXJlbmV3LWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiIHBsYWNlaG9sZGVyPSIzMCI+CiAgICA8L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJzc2gtcmVuZXctYnRuIiBvbmNsaWNrPSJkb1NTSFJlbmV3KCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICA8L2Rpdj4KPC9kaXY+Cgo8L2JvZHk+CjwvaHRtbD4K' | base64 -d > /opt/chaiya-panel/sshws.html
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

# ── APPLY PATCH v5 ────────────────────────────────────────────
info "Apply patch v5 — อัพเดต app.py และ sshws.html..."
info "Patching Chaiya VPN Panel v5..."

# ── STEP 1: เพิ่ม API endpoints ใหม่ใน app.py ─────────────────
info "อัพเดต SSH API..."

cat > /opt/chaiya-ssh-api/app.py << 'PYEOF'
#!/usr/bin/env python3
"""Chaiya SSH API v5 - Patched: /api/banned, /api/unban, /api/online_ssh"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, threading, sqlite3, time, re

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

def get_online_ssh_users():
    """ดึงรายชื่อ SSH users ที่ online จริงจาก ss -tnp + /proc/PID/status"""
    online = []
    try:
        users_map = {}
        ssh_users = list_ssh_users()
        for u in ssh_users:
            users_map[u['user']] = u

        if not users_map:
            return []

        # วิธี 1: ใช้ who/w command (บน tty login)
        _, who_out, _ = run_cmd("who 2>/dev/null || true")
        seen_who = set()
        if who_out:
            for line in who_out.strip().split('\n'):
                parts = line.split()
                if parts and parts[0] in users_map and parts[0] not in seen_who:
                    seen_who.add(parts[0])
                    online.append(users_map[parts[0]].copy())

        # วิธี 2: ss -tnp หา PID ที่ connect บน port dropbear แล้วหา username จาก /proc/PID/status
        _, ss_out, _ = run_cmd(
            "ss -tnp state established 2>/dev/null | grep -E ':(143|109)' || true"
        )
        pid_set = set()
        if ss_out:
            import re as _re
            for pid_m in _re.findall(r'pid=(\d+)', ss_out):
                pid_set.add(pid_m)

        seen_proc = set()
        for pid in pid_set:
            try:
                status_path = f'/proc/{pid}/status'
                if not os.path.exists(status_path):
                    continue
                with open(status_path) as sf:
                    status_txt = sf.read()
                # ดึง Uid จาก /proc/PID/status
                uid_line = [l for l in status_txt.split('\n') if l.startswith('Uid:')]
                if not uid_line:
                    continue
                uid = int(uid_line[0].split()[1])
                if uid < 1000 or uid > 60000:
                    continue
                # หา username จาก uid
                import pwd as _pwd
                try:
                    uname = _pwd.getpwuid(uid).pw_name
                except:
                    continue
                if uname in users_map and uname not in seen_proc and uname not in seen_who:
                    seen_proc.add(uname)
                    online.append(users_map[uname].copy())
            except:
                continue

        # วิธี 3: fallback - นับ connection count ถ้าไม่ได้ชื่อ
        if not online:
            _, conn_out, _ = run_cmd(
                "ss -tn state established 2>/dev/null | awk '{print $4}' | grep -cE ':(143|109|80)$' || echo 0"
            )
            try:
                cnt = int(conn_out.strip().split()[0])
                if cnt > 0:
                    # ส่งกลับเป็น connection count แบบ generic
                    online.append({'user': f'{cnt} connection(s)', 'active': True, 'exp': None, 'conn_only': True})
            except:
                pass

        return online
    except:
        return []

def get_banned_users():
    """ดึงรายการ IP ที่ถูก block ใน iptables (x-ui จะ ban ด้วย iptables)"""
    banned = []
    now_ts = int(time.time() * 1000)
    
    try:
        # ตรวจ iptables สำหรับ blocked IPs จาก x-ui
        _, ipt_out, _ = run_cmd("iptables -L -n 2>/dev/null | grep -E 'DROP|REJECT' | awk '{print $4}' | grep -v '^0' || true")
        banned_ips = [ip.strip() for ip in ipt_out.split('\n') if ip.strip() and ip.strip() != '0.0.0.0/0']
        
        # อ่าน x-ui DB หาชื่อ user ที่ disable
        if os.path.exists(XUI_DB):
            con = sqlite3.connect(XUI_DB)
            rows = con.execute("SELECT id, remark, port, settings FROM inbounds WHERE enable=1").fetchall()
            con.close()
            for row in rows:
                ib_id, remark, port, settings_str = row
                try:
                    settings = json.loads(settings_str)
                    for c in settings.get('clients', []):
                        if not c.get('enable', True):
                            ban_time = now_ts
                            unban_time = now_ts + 3600000  # 1 ชั่วโมง
                            banned.append({
                                'user': c.get('email') or c.get('id', '?'),
                                'type': 'vless',
                                'port': port,
                                'ibId': ib_id,
                                'uuid': c.get('id', ''),
                                'banTime': ban_time,
                                'unbanTime': unban_time
                            })
                except: pass
    except: pass
    
    return banned

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

        elif self.path == '/api/online_ssh':
            # ดึงรายชื่อ SSH users ที่กำลัง connect อยู่จริงๆ
            online = get_online_ssh_users()
            respond(self, 200, {'ok': True, 'online': online, 'count': len(online)})

        elif self.path == '/api/vless_online':
            # login x-ui แล้วดึง onlines โดยตรง
            import urllib.request, urllib.parse, http.cookiejar
            try:
                xui_user = open('/etc/chaiya/xui-user.conf').read().strip() if os.path.exists('/etc/chaiya/xui-user.conf') else 'admin'
                xui_pass = open('/etc/chaiya/xui-pass.conf').read().strip() if os.path.exists('/etc/chaiya/xui-pass.conf') else 'admin'
                xui_port = open('/etc/chaiya/xui-port.conf').read().strip() if os.path.exists('/etc/chaiya/xui-port.conf') else '2053'
                jar = http.cookiejar.CookieJar()
                opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
                # login
                login_data = urllib.parse.urlencode({'username': xui_user, 'password': xui_pass}).encode()
                opener.open(f'http://127.0.0.1:{xui_port}/login', login_data, timeout=5)
                # get onlines
                resp = opener.open(f'http://127.0.0.1:{xui_port}/panel/api/inbounds/onlines', timeout=5)
                import json as _json2
                data = _json2.loads(resp.read().decode())
                emails = data.get('obj') or []
                respond(self, 200, {'ok': True, 'online': emails, 'count': len(emails)})
            except Exception as ex:
                respond(self, 200, {'ok': False, 'online': [], 'count': 0, 'error': str(ex)})

        elif self.path == '/api/banned':
            # ดึงรายการที่ถูก ban (IP เกิน limit)
            banned = get_banned_users()
            respond(self, 200, {'ok': True, 'banned': banned, 'count': len(banned)})

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

        elif self.path == '/api/unban':
            # ปลดล็อค IP ban — ลบ iptables rule + เปิดใช้งาน client ใน x-ui DB
            user = data.get('user', '').strip()
            if not user:
                return respond(self, 400, {'error': 'user required'})
            
            actions = []
            
            # 1. ลบ iptables DROP rules สำหรับ user นี้ (ถ้ามี)
            run_cmd(f"iptables -D INPUT -m string --string '{user}' --algo bm -j DROP 2>/dev/null || true")
            
            # 2. เปิดใช้งาน client ใน x-ui DB ถ้ามี
            if os.path.exists(XUI_DB):
                try:
                    con = sqlite3.connect(XUI_DB)
                    rows = con.execute("SELECT id, settings FROM inbounds WHERE enable=1").fetchall()
                    for ib_id, settings_str in rows:
                        try:
                            settings = json.loads(settings_str)
                            changed = False
                            for c in settings.get('clients', []):
                                if (c.get('email') == user or c.get('id') == user) and not c.get('enable', True):
                                    c['enable'] = True
                                    changed = True
                            if changed:
                                con.execute("UPDATE inbounds SET settings=? WHERE id=?",
                                           (json.dumps(settings), ib_id))
                                actions.append(f'enabled vless client {user}')
                        except: pass
                    con.commit()
                    con.close()
                except: pass
            
            # 3. Restart x-ui เพื่อ apply changes
            if actions:
                run_cmd("systemctl reload x-ui 2>/dev/null || systemctl restart x-ui 2>/dev/null || true")
            
            respond(self, 200, {'ok': True, 'user': user, 'actions': actions})

        elif self.path == '/api/update':
            # Stream script update log back to client via SSE-like chunked response
            import subprocess, threading
            SCRIPT_URL = data.get('url', 'https://raw.githubusercontent.com/Chaiyakey99/chaiya-vpn/main/chaiya-setup-v5-combined.sh').strip()
            if not SCRIPT_URL.startswith('https://'):
                return respond(self, 400, {'ok': False, 'error': 'URL ไม่ถูกต้อง'})
            def stream_update():
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.send_header('Transfer-Encoding', 'chunked')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.end_headers()
                def write_chunk(text):
                    try:
                        b = text.encode('utf-8')
                        self.wfile.write(('%x\r\n' % len(b)).encode())
                        self.wfile.write(b)
                        self.wfile.write(b'\r\n')
                        self.wfile.flush()
                    except: pass
                try:
                    write_chunk('[INFO] ดาวน์โหลด script จาก ' + SCRIPT_URL + '\n')
                    import tempfile, os, hashlib
                    tmp = tempfile.mktemp(suffix='.sh')
                    rc = subprocess.call(['curl', '-fsSL', '-o', tmp, SCRIPT_URL])
                    if rc != 0 or not os.path.exists(tmp):
                        write_chunk('[ERR] ดาวน์โหลดไม่สำเร็จ\n')
                        write_chunk('__DONE_FAIL__\n')
                        self.wfile.write(b'0\r\n\r\n')
                        return
                    # เช็ค MD5 เทียบกับ script ปัจจุบัน
                    def md5file(path):
                        try:
                            h = hashlib.md5()
                            with open(path, 'rb') as f:
                                for chunk in iter(lambda: f.read(65536), b''):
                                    h.update(chunk)
                            return h.hexdigest()
                        except: return ''
                    new_md5 = md5file(tmp)
                    cur_path = os.path.abspath(__file__)
                    cur_md5  = md5file(cur_path)
                    write_chunk('[INFO] MD5 ใหม่  : ' + new_md5 + '\n')
                    write_chunk('[INFO] MD5 ปัจจุบัน: ' + cur_md5  + '\n')
                    if new_md5 and cur_md5 and new_md5 == cur_md5:
                        os.remove(tmp)
                        write_chunk('[OK] Script เป็นเวอร์ชั่นล่าสุดแล้ว ไม่ต้องอัพเดต ✅\n')
                        write_chunk('__DONE_LATEST__\n')
                        self.wfile.write(b'0\r\n\r\n')
                        return
                    write_chunk('[OK] พบเวอร์ชั่นใหม่ — เริ่ม update...\n')
                    proc = subprocess.Popen(
                        ['bash', tmp],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        universal_newlines=True, bufsize=1
                    )
                    for line in proc.stdout:
                        write_chunk(line)
                    proc.wait()
                    os.remove(tmp)
                    if proc.returncode == 0:
                        write_chunk('\n[OK] อัพเดตเสร็จสิ้น ✅\n')
                        write_chunk('__DONE_OK__\n')
                    else:
                        write_chunk('\n[ERR] อัพเดตล้มเหลว (exit ' + str(proc.returncode) + ')\n')
                        write_chunk('__DONE_FAIL__\n')
                except Exception as ex:
                    write_chunk('[ERR] ' + str(ex) + '\n')
                    write_chunk('__DONE_FAIL__\n')
                try:
                    self.wfile.write(b'0\r\n\r\n')
                    self.wfile.flush()
                except: pass
            t = threading.Thread(target=stream_update)
            t.daemon = True
            t.start()
            t.join()
            return

        elif self.path == '/api/delete_vless':
            import sqlite3 as _sq3, json as _json
            user = data.get('user', '').strip()
            inbound_id = data.get('inboundId')
            if not user:
                return respond(self, 400, {'error': 'user required'})
            if not os.path.exists(XUI_DB):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(XUI_DB)
                rows = con.execute(
                    "SELECT id, settings FROM inbounds WHERE enable=1" if not inbound_id
                    else "SELECT id, settings FROM inbounds WHERE id=?", *([[inbound_id]] if inbound_id else [])
                ).fetchall()
                deleted = 0
                for ib_id, settings_str in rows:
                    try:
                        s = _json.loads(settings_str)
                        clients = s.get('clients', [])
                        new_clients = [c for c in clients if c.get('email') != user and c.get('id') != user]
                        if len(new_clients) < len(clients):
                            s['clients'] = new_clients
                            con.execute("UPDATE inbounds SET settings=? WHERE id=?", (_json.dumps(s), ib_id))
                            deleted += len(clients) - len(new_clients)
                    except: pass
                con.commit()
                con.close()
                if deleted > 0:
                    run_cmd("systemctl restart x-ui 2>/dev/null || true")
                respond(self, 200, {'ok': deleted > 0, 'deleted': deleted, 'user': user})
            except Exception as e:
                respond(self, 500, {'error': str(e)})

        elif self.path == '/api/reset_traffic':
            import sqlite3 as _sq3, json as _json
            user = data.get('user', '').strip()
            inbound_id = data.get('inboundId')
            if not user:
                return respond(self, 400, {'error': 'user required'})
            if not os.path.exists(XUI_DB):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(XUI_DB)
                rows = con.execute(
                    "SELECT id, settings FROM inbounds WHERE enable=1" if not inbound_id
                    else "SELECT id, settings FROM inbounds WHERE id=?", *([[inbound_id]] if inbound_id else [])
                ).fetchall()
                reset = 0
                for ib_id, settings_str in rows:
                    try:
                        s = _json.loads(settings_str)
                        changed = False
                        for c in s.get('clients', []):
                            if c.get('email') == user or c.get('id') == user:
                                c['up'] = 0
                                c['down'] = 0
                                changed = True
                        if changed:
                            con.execute("UPDATE inbounds SET settings=?,up=0,down=0 WHERE id=?", (_json.dumps(s), ib_id))
                            reset += 1
                    except: pass
                # รีเซต client_traffics ด้วยถ้ามี table นี้
                try:
                    con2 = _sq3.connect(XUI_DB)
                    con2.execute("UPDATE client_traffics SET up=0, down=0 WHERE email=?", (user,))
                    con2.commit()
                    con2.close()
                except: pass
                con.commit()
                con.close()
                if reset > 0:
                    run_cmd("systemctl restart x-ui 2>/dev/null || true")
                respond(self, 200, {'ok': True, 'reset': reset, 'user': user})
            except Exception as e:
                respond(self, 500, {'error': str(e)})

        elif self.path == '/api/extend_vless':
            import sqlite3 as _sq3, json as _json, datetime as _dt
            user = data.get('user', '').strip()
            days = int(data.get('days', 30))
            inbound_id = data.get('inboundId')
            if not user:
                return respond(self, 400, {'error': 'user required'})
            if not os.path.exists(XUI_DB):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(XUI_DB)
                rows = con.execute(
                    "SELECT id, settings FROM inbounds WHERE enable=1" if not inbound_id
                    else "SELECT id, settings FROM inbounds WHERE id=?", *([[inbound_id]] if inbound_id else [])
                ).fetchall()
                updated = 0
                new_exp_ms = 0
                for ib_id, settings_str in rows:
                    try:
                        s = _json.loads(settings_str)
                        changed = False
                        for c in s.get('clients', []):
                            if c.get('email') == user or c.get('id') == user:
                                old_ms = int(c.get('expiryTime', 0) or 0)
                                now_ms = int(_dt.datetime.now().timestamp() * 1000)
                                base_ms = max(old_ms, now_ms)
                                new_exp_ms = base_ms + days * 86400000
                                c['expiryTime'] = new_exp_ms
                                changed = True
                        if changed:
                            con.execute("UPDATE inbounds SET settings=? WHERE id=?", (_json.dumps(s), ib_id))
                            updated += 1
                    except: pass
                con.commit()
                con.close()
                if updated > 0:
                    run_cmd("systemctl restart x-ui 2>/dev/null || true")
                respond(self, 200, {'ok': updated > 0, 'user': user, 'days': days, 'expiryTime': new_exp_ms})
            except Exception as e:
                respond(self, 500, {'error': str(e)})

        elif self.path == '/api/set_traffic':
            import sqlite3 as _sq3, json as _json
            user = data.get('user', '').strip()
            gb = float(data.get('gb', 0))
            inbound_id = data.get('inboundId')
            if not user:
                return respond(self, 400, {'error': 'user required'})
            if not os.path.exists(XUI_DB):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(XUI_DB)
                rows = con.execute(
                    "SELECT id, settings FROM inbounds WHERE enable=1" if not inbound_id
                    else "SELECT id, settings FROM inbounds WHERE id=?", *([[inbound_id]] if inbound_id else [])
                ).fetchall()
                updated = 0
                for ib_id, settings_str in rows:
                    try:
                        s = _json.loads(settings_str)
                        changed = False
                        for c in s.get('clients', []):
                            if c.get('email') == user or c.get('id') == user:
                                c['totalGB'] = int(gb * 1073741824)
                                changed = True
                        if changed:
                            con.execute("UPDATE inbounds SET settings=? WHERE id=?", (_json.dumps(s), ib_id))
                            updated += 1
                    except: pass
                con.commit()
                con.close()
                if updated > 0:
                    run_cmd("systemctl restart x-ui 2>/dev/null || true")
                respond(self, 200, {'ok': updated > 0, 'user': user, 'gb': gb})
            except Exception as e:
                respond(self, 500, {'error': str(e)})

        elif self.path == '/api/add_traffic':
            import sqlite3 as _sq3, json as _json
            user = data.get('user', '').strip()
            gb = float(data.get('gb', 0))
            inbound_id = data.get('inboundId')
            if not user:
                return respond(self, 400, {'error': 'user required'})
            if not os.path.exists(XUI_DB):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(XUI_DB)
                rows = con.execute(
                    "SELECT id, settings FROM inbounds WHERE enable=1" if not inbound_id
                    else "SELECT id, settings FROM inbounds WHERE id=?", *([[inbound_id]] if inbound_id else [])
                ).fetchall()
                updated = 0
                for ib_id, settings_str in rows:
                    try:
                        s = _json.loads(settings_str)
                        changed = False
                        for c in s.get('clients', []):
                            if c.get('email') == user or c.get('id') == user:
                                old_bytes = int(c.get('totalGB', 0) or 0)
                                c['totalGB'] = old_bytes + int(gb * 1073741824)
                                changed = True
                        if changed:
                            con.execute("UPDATE inbounds SET settings=? WHERE id=?", (_json.dumps(s), ib_id))
                            updated += 1
                    except: pass
                con.commit()
                con.close()
                if updated > 0:
                    run_cmd("systemctl restart x-ui 2>/dev/null || true")
                respond(self, 200, {'ok': updated > 0, 'user': user, 'gb': gb})
            except Exception as e:
                respond(self, 500, {'error': str(e)})

        elif self.path == '/api/vless_users':
            import sqlite3 as _sq3, json as _json
            if not os.path.exists(XUI_DB):
                return respond(self, 200, {'ok': True, 'users': []})
            try:
                con = _sq3.connect(XUI_DB)
                rows = con.execute(
                    "SELECT id, remark, port, protocol, settings, up, down, total, expiry_time, enable FROM inbounds"
                ).fetchall()
                # ดึง traffic แยกรายคนจาก client_traffics — ลอง 2 ชื่อ table
                ct_map = {}
                for tbl in ('client_traffics', 'xray_client_traffics'):
                    try:
                        ct_rows = con.execute(f"SELECT email, up, down, inbound_id FROM {tbl}").fetchall()
                        for ct_email, ct_up, ct_down, ct_ib in ct_rows:
                            key = (ct_ib, ct_email)
                            ct_map[key] = {'up': ct_up or 0, 'down': ct_down or 0}
                        break
                    except: pass
                # fallback: ลอง query ไม่มี inbound_id
                if not ct_map:
                    for tbl in ('client_traffics', 'xray_client_traffics'):
                        try:
                            ct_rows = con.execute(f"SELECT email, up, down FROM {tbl}").fetchall()
                            for ct_email, ct_up, ct_down in ct_rows:
                                ct_map[(None, ct_email)] = {'up': ct_up or 0, 'down': ct_down or 0}
                            break
                        except: pass
                con.close()
                all_users = []
                for ib_id, remark, port, proto, settings_str, ib_up, ib_down, ib_total, ib_exp, ib_enable in rows:
                    try:
                        s = _json.loads(settings_str)
                        clients = s.get('clients', [])
                        for c in clients:
                            email = c.get('email') or c.get('id', '')
                            # ลอง key (ib_id, email) ก่อน ถ้าไม่มีลอง (None, email)
                            ct = ct_map.get((ib_id, email)) or ct_map.get((None, email), {})
                            all_users.append({
                                'inboundId': ib_id,
                                'inbound': remark,
                                'port': port,
                                'protocol': proto,
                                'user': email,
                                'uuid': c.get('id', ''),
                                'up': ct.get('up', 0),
                                'down': ct.get('down', 0),
                                'totalGB': c.get('totalGB', 0),
                                'expiryTime': c.get('expiryTime', 0),
                                'limitIp': c.get('limitIp', 0),
                                'enable': c.get('enable', True),
                            })
                    except: pass
                respond(self, 200, {'ok': True, 'users': all_users})
            except Exception as e:
                respond(self, 500, {'error': str(e)})

        else:
            respond(self, 404, {'error': 'not found'})

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 6789), Handler)
    print('[chaiya-ssh-api] Listening on 127.0.0.1:6789 (patched v5)')
    server.serve_forever()
PYEOF

chmod +x /opt/chaiya-ssh-api/app.py
ok "SSH API อัพเดตแล้ว"

# ── STEP 2: อัพเดต sshws.html ─────────────────────────────────
info "อัพเดต Dashboard HTML..."

# Backup เก่า
cp /opt/chaiya-panel/sshws.html /opt/chaiya-panel/sshws.html.bak 2>/dev/null || true

# เขียนไฟล์ HTML ใหม่ (base64 encoded)
cat << 'HTML_BASE64_EOF' | base64 -d > /opt/chaiya-panel/sshws.html
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMxYTBhMmUgMCUsIzBmMGExZSA1NSUsIzBhMGEwZiAxMDAlKTtwYWRkaW5nOjI4cHggMjBweCAyMnB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tncm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo1cHg7aGVpZ2h0OjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgMi40cyBlYXNlLWluLW91dCBpbmZpbml0ZTt9CiAgLmRvdC5yZWR7YmFja2dyb3VuZDojZWY0NDQ0O2JveC1zaGFkb3c6MCAwIDZweCAjZWY0NDQ0O30KICBAa2V5ZnJhbWVzIHBsc3swJSwxMDAle29wYWNpdHk6MTt0cmFuc2Zvcm06c2NhbGUoMSl9NTAle29wYWNpdHk6LjM1O3RyYW5zZm9ybTpzY2FsZSgwLjcpfX0KICAueHVpLXJvd3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLnh1aS1pbmZve2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtsaW5lLWhlaWdodDoxLjc7fQogIC54dWktaW5mbyBie2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtbGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4O30KICAuc3Zje2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4wNSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjExcHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO30KICAuc3ZjLmRvd257YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjA1KTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4yKTt9CiAgLnN2Yy1se2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7fQogIC5kZ3t3aWR0aDo4cHg7aGVpZ2h0OjhweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCA2cHggdmFyKC0tbmcpO2ZsZXgtc2hyaW5rOjA7fQogIC5kZy5yZWR7YmFja2dyb3VuZDojZWY0NDQ0O2JveC1zaGFkb3c6MCAwIDZweCAjZWY0NDQ0O30KICAuc3ZjLW57Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtcHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5yYmRne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMyk7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1uZyk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAucmJkZy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4zKTtjb2xvcjojZWY0NDQ0O30KICAubHV7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MTRweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoxcHg7fQogIC5mdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjExcHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4O30KICAuaW5mby1ib3h7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxMnB4O2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wdGdse2Rpc3BsYXk6ZmxleDtnYXA6OHB4O21hcmdpbi1ib3R0b206MTRweDt9CiAgLnBidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmZne21hcmdpbi1ib3R0b206MTJweDt9CiAgLmZsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO29wYWNpdHk6Ljg7bWFyZ2luLWJvdHRvbTo1cHg7fQogIC5maXt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo5cHg7cGFkZGluZzoxMHB4IDE0cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tdHh0KTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzO30KICAuZmk6Zm9jdXN7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtib3gtc2hhZG93OjAgMCAwIDNweCB2YXIoLS1hYy1kaW0pO30KICAudGdse2Rpc3BsYXk6ZmxleDtnYXA6OHB4O30KICAudGJ0bntmbGV4OjE7cGFkZGluZzo5cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXI7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JhY2tncm91bmQ6I2Y4ZmFmYztjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO30KICAudGJ0bi5hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuY2J0bnt3aWR0aDoxMDAlO3BhZGRpbmc6MTRweDtib3JkZXItcmFkaXVzOjEwcHg7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2JvcmRlcjpub25lO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMTZhMzRhLCMyMmM1NWUsIzRhZGU4MCk7Y29sb3I6I2ZmZjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtsZXR0ZXItc3BhY2luZzouNXB4O2JveC1zaGFkb3c6MCA0cHggMTVweCByZ2JhKDM0LDE5Nyw5NCwuMyk7dHJhbnNpdGlvbjphbGwgLjJzO30KICAuY2J0bjpob3Zlcntib3gtc2hhZG93OjAgNnB4IDIwcHggcmdiYSgzNCwxOTcsOTQsLjQ1KTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTt9CiAgLmNidG46ZGlzYWJsZWR7b3BhY2l0eTouNTtjdXJzb3I6bm90LWFsbG93ZWQ7dHJhbnNmb3JtOm5vbmU7fQogIC5zYm94e3dpZHRoOjEwMCU7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMHB4IDE0cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tdHh0KTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtvdXRsaW5lOm5vbmU7bWFyZ2luLWJvdHRvbToxMnB4O3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLnNib3g6Zm9jdXN7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLnVpdGVte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTJweCAxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbTo4cHg7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjJzO2JveC1zaGFkb3c6MCAxcHggNHB4IHJnYmEoMCwwLDAsMC4wNCk7fQogIC51aXRlbTpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWMpO2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTt9CiAgLnVhdnt3aWR0aDozNnB4O2hlaWdodDozNnB4O2JvcmRlci1yYWRpdXM6OXB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo3MDA7bWFyZ2luLXJpZ2h0OjEycHg7ZmxleC1zaHJpbms6MDt9CiAgLmF2LWd7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjE1KTtjb2xvcjp2YXIoLS1uZyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMik7fQogIC5hdi1ye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywwLjE1KTtjb2xvcjojZjg3MTcxO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNDgsMTEzLDExMywuMik7fQogIC5hdi14e2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xMik7Y29sb3I6I2VmNDQ0NDtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4yKTt9CiAgLnVue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAudW17Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuYWJkZ3tib3JkZXItcmFkaXVzOjZweDtwYWRkaW5nOjNweCAxMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAuYWJkZy5va3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMyk7Y29sb3I6dmFyKC0tbmcpO30KICAuYWJkZy5leHB7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjMpO2NvbG9yOiNlZjQ0NDQ7fQogIC5hYmRnLnNvb257YmFja2dyb3VuZDpyZ2JhKDI1MSwxNDYsNjAsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjUxLDE0Niw2MCwuMyk7Y29sb3I6I2Y5NzMxNjt9CiAgLm1vdmVye3Bvc2l0aW9uOmZpeGVkO2luc2V0OjA7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC41KTtiYWNrZHJvcC1maWx0ZXI6Ymx1cig2cHgpO3otaW5kZXg6MTAwO2Rpc3BsYXk6bm9uZTthbGlnbi1pdGVtczpmbGV4LWVuZDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAubW92ZXIub3BlbntkaXNwbGF5OmZsZXg7fQogIC5tb2RhbHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MjBweCAyMHB4IDAgMDt3aWR0aDoxMDAlO21heC13aWR0aDo0ODBweDtwYWRkaW5nOjIwcHg7bWF4LWhlaWdodDo4NXZoO292ZXJmbG93LXk6YXV0bzthbmltYXRpb246c3UgLjNzIGVhc2U7Ym94LXNoYWRvdzowIC00cHggMzBweCByZ2JhKDAsMCwwLDAuMTIpO30KICBAa2V5ZnJhbWVzIHN1e2Zyb217dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMTAwJSl9dG97dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5taGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxNnB4O30KICAubXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLXR4dCk7fQogIC5tY2xvc2V7d2lkdGg6MzJweDtoZWlnaHQ6MzJweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2NvbG9yOnZhcigtLW11dGVkKTtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5kZ3JpZHtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tYm90dG9tOjE0cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHJ7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtwYWRkaW5nOjdweCAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcjpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmRre2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmR2e2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC13ZWlnaHQ6NjAwO30KICAuZHYuZ3JlZW57Y29sb3I6dmFyKC0tbmcpO30KICAuZHYucmVke2NvbG9yOiNlZjQ0NDQ7fQogIC5kdi5tb25ve2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6OXB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO3dvcmQtYnJlYWs6YnJlYWstYWxsO30KICAuYWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7fQogIC5tLXN1YntkaXNwbGF5Om5vbmU7bWFyZ2luLXRvcDoxNHB4O2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMnB4O3BhZGRpbmc6MTRweDt9CiAgLm0tc3ViLm9wZW57ZGlzcGxheTpibG9jazthbmltYXRpb246ZmkgLjJzIGVhc2U7fQogIC5tc3ViLWxibHtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5hYnRue2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweCAxMHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmFidG46aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC5hYnRuIC5haXtmb250LXNpemU6MjJweDttYXJnaW4tYm90dG9tOjZweDt9CiAgLmFidG4gLmFue2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuYWJ0biAuYWR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuYWJ0bi5kYW5nZXI6aG92ZXJ7YmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLC4xKTtib3JkZXItY29sb3I6I2Y4NzE3MTt9CiAgLm9le3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6NDBweCAyMHB4O30KICAub2UgLmVpe2ZvbnQtc2l6ZTo0OHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLm9lIHB7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxM3B4O30KICAub2Nye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxNnB4O30KICAudXR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAvKiByZXN1bHQgYm94ICovCiAgLnJlcy1ib3h7YmFja2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi10b3A6MTRweDtkaXNwbGF5Om5vbmU7fQogIC5yZXMtYm94LnNob3d7ZGlzcGxheTpibG9jazt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gSEVBREVSIC0tPgogIDxkaXYgY2xhc3M9ImhkciI+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiPuKGqSDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KICAgIDxkaXYgY2xhc3M9Imhkci1zdWIiPkNIQUlZQSBWMlJBWSBQUk8gTUFYPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJoZHItdGl0bGUiPlVTRVIgPHNwYW4+Q1JFQVRPUjwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imhkci1kZXNjIiBpZD0iaGRyLWRvbWFpbiI+djUgwrcgU0VDVVJFIFBBTkVMPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gTkFWIC0tPgogIDxkaXYgY2xhc3M9Im5hdiI+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSBhY3RpdmUiIG9uY2xpY2s9InN3KCdkYXNoYm9hcmQnLHRoaXMpIj7wn5OKIOC5geC4lOC4iuC4muC4reC4o+C5jOC4lDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdjcmVhdGUnLHRoaXMpIj7inpUg4Liq4Lij4LmJ4Liy4LiH4Lii4Li54LiqPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ21hbmFnZScsdGhpcykiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54LiqPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ29ubGluZScsdGhpcykiPvCfn6Ig4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2JhbicsdGhpcykiPvCfmqsg4Lib4Lil4LiU4LmB4Lia4LiZPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIgaWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFuIGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7imqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9udC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGltZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJvdyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3guKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAgICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklDRSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2ltZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgtQUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlzLm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWlnaHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdTIMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBXUyDCtyB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KCiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCIgc3R5bGU9Im1hcmdpbi10b3A6MjBweCI+8J+UkSDguKPguLDguJrguJogU1NIIFdFQlNPQ0tFVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3NzaCcpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtc3NoIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6I2ZmZjtmb250LWZhbWlseTptb25vc3BhY2UiPlNTSCZndDs8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgc3NoIj5TU0gg4oCTIFdTIFR1bm5lbDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+U1NIIMK3IFBvcnQgODAgwrcgRHJvcGJlYXIgMTQzLzEwOTxicj5OcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IEFJUyDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLWFpcyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgYWlzLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWxvZ28gc2VsLWFpcy1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouOHJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgU05JOiBjai1lYmIuc3BlZWR0ZXN0Lm5ldDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckBhaXMiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLWFpcyIgaWQ9ImFpcy1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCdhaXMnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0iYWlzLXJlc3VsdCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1haXMtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLWFpcy11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici1haXMtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici1haXMtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci1haXMtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5rPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJhaXMtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBUUlVFIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tdHJ1ZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgdHJ1ZS1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBTTkk6IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQHRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLXRydWUiIGlkPSJ0cnVlLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ3RydWUnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBUUlVFIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici10cnVlLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici10cnVlLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLXRydWUtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici10cnVlLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItdHJ1ZS1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9InRydWUtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBTU0gg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1zc2giIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNzaC1kYXJrLWZvcm0iPgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7inpUg4LmA4Lie4Li04LmI4LihIFNTSCBVU0VSPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1wYXNzIiBwbGFjZWhvbGRlcj0icGFzc3dvcmQiIHR5cGU9InBhc3N3b3JkIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lil4Li04Lih4Li04LiV4LmE4Lit4Lie4Li1PC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+4pyI77iPIOC5gOC4peC4t+C4reC4gSBQT1JUPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIGFjdGl2ZS1wODAiIGlkPSJwYi04MCIgb25jbGljaz0icGlja1BvcnQoJzgwJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn4yQPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgODA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XUyDCtyBIVFRQPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIiBpZD0icGItNDQzIiBvbmNsaWNrPSJwaWNrUG9ydCgnNDQzJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn5SSPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgNDQzPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLXN1YiI+V1NTIMK3IFNTTDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn4yQIOC5gOC4peC4t+C4reC4gSBJU1AgLyBPUEVSQVRPUjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBpY2stZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCBhLWR0YWMiIGlkPSJwcm8tZHRhYyIgb25jbGljaz0icGlja1BybygnZHRhYycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCfn6A8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRUQUMgR0FNSU5HPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5kbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0icHJvLXRydWUiIG9uY2xpY2s9InBpY2tQcm8oJ3RydWUnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj7wn5S1PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5UUlVFIFRXSVRURVI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmhlbHAueC5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCI+8J+TsSDguYDguKXguLfguK3guIEgQVBQPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtbnB2IiBpZD0iYXBwLW5wdiIgb25jbGljaz0icGlja0FwcCgnbnB2JykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+PGRpdiBzdHlsZT0id2lkdGg6MzhweDtoZWlnaHQ6MzhweDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMGQyYTNhO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjttYXJnaW46MCBhdXRvIC4xcmVtO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi44NXJlbTtjb2xvcjojMDBjY2ZmO2xldHRlci1zcGFjaW5nOi0xcHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMCwyMDQsMjU1LC4zKSI+blY8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPk5wdiBUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPm5wdnQtc3NoOi8vPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0iYXBwLWRhcmsiIG9uY2xpY2s9InBpY2tBcHAoJ2RhcmsnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMxMTE7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6c2Fucy1zZXJpZjtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi42MnJlbTtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOi41cHg7Ym9yZGVyOjEuNXB4IHNvbGlkICM0NDQiPkRBUks8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRhcmtUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRhcmt0dW5uZWw6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuLXNzaCIgaWQ9InNzaC1idG4iIG9uY2xpY2s9ImNyZWF0ZVNTSCgpIj7inpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXI8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InNzaC1hbGVydCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibGluay1yZXN1bHQiIGlkPSJzc2gtbGluay1yZXN1bHQiPjwvZGl2PgogICAgICA8L2Rpdj4KCiAgICAgIDwhLS0gVXNlciB0YWJsZSAtLT4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbjowIj7wn5OLIOC4o+C4suC4ouC4iuC4t+C5iOC4rSBVU0VSUzwvZGl2PgogICAgICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0ic3NoLXNlYXJjaCIgcGxhY2Vob2xkZXI9IuC4hOC5ieC4meC4q+C4si4uLiIgb25pbnB1dD0iZmlsdGVyU1NIVXNlcnModGhpcy52YWx1ZSkiCiAgICAgICAgICAgIHN0eWxlPSJ3aWR0aDoxMjBweDttYXJnaW46MDtmb250LXNpemU6MTFweDtwYWRkaW5nOjZweCAxMHB4Ij4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1dGJsLXdyYXAiPgogICAgICAgICAgPHRhYmxlIGNsYXNzPSJ1dGJsIj4KICAgICAgICAgICAgPHRoZWFkPjx0cj48dGg+IzwvdGg+PHRoPlVTRVJOQU1FPC90aD48dGg+4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC90aD48dGg+4Liq4LiW4Liy4LiZ4LiwPC90aD48dGg+QUNUSU9OPC90aD48L3RyPjwvdGhlYWQ+CiAgICAgICAgICAgIDx0Ym9keSBpZD0ic3NoLXVzZXItdGJvZHkiPjx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MjBweDtjb2xvcjp2YXIoLS1tdXRlZCkiPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvdGQ+PC90cj48L3Rib2R5PgogICAgICAgICAgPC90YWJsZT4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgPC9kaXY+PCEtLSAvdGFiLWNyZWF0ZSAtLT4KCjwhLS0g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW1hbmFnZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4quC5gOC4i+C4reC4o+C5jCBWTEVTUzwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkVXNlcnMoKSI+4oa7IOC5guC4q+C4peC4lDwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0idXNlci1zZWFyY2giIHBsYWNlaG9sZGVyPSLwn5SNICDguITguYnguJnguKvguLIgdXNlcm5hbWUuLi4iIG9uaW5wdXQ9ImZpbHRlclVzZXJzKHRoaXMudmFsdWUpIj4KICAgICAgPGRpdiBpZD0idXNlci1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguJvguLjguYjguKHguYLguKvguKXguJTguYDguJ7guLfguYjguK3guJTguLbguIfguILguYnguK3guKHguLnguKU8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1vbmxpbmUiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+8J+foiDguKLguLnguKrguYDguIvguK3guKPguYzguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZE9ubGluZSgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvY3IiPgogICAgICAgIDxkaXYgY2xhc3M9Im9waWxsIiBpZD0ib25saW5lLXBpbGwiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj48c3BhbiBpZD0ib25saW5lLWNvdW50Ij4wPC9zcGFuPiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0idXQiIGlkPSJvbmxpbmUtdGltZSI+LS08L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4LiU4Lij4Li14LmA4Lif4Lij4LiK4LmA4Lie4Li34LmI4Lit4LiU4Li54Lic4Li54LmJ4LmD4LiK4LmJ4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQkFOIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItYmFuIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiPvCfmqsg4LiI4Lix4LiU4LiB4Liy4LijIFNTSCBVc2VyczwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBVU0VSTkFNRTwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJiYW4tdXNlciIgcGxhY2Vob2xkZXI9IuC5g+C4quC5iCB1c2VybmFtZSDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguKXguJoiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNTgwM2QsIzIyYzU1ZSkiIG9uY2xpY2s9ImRlbGV0ZVNTSCgpIj7wn5eR77iPIOC4peC4miBTU0ggVXNlcjwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImJhbi1hbGVydCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+TiyBTU0ggVXNlcnMg4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgaWQ9InNzaC11c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+Cgo8L2Rpdj48IS0tIC93cmFwIC0tPgoKPCEtLSBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJtb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbSgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIiBpZD0ibXQiPuKame+4jyB1c2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY20oKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6EgUG9ydDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkcCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9ImRlIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TpiBEYXRhIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TiiBUcmFmZmljIOC5g+C4iuC5iTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdHIiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OxIElQIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRpIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBtb25vIiBpZD0iZHV1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTBweCI+4LmA4Lil4Li34Lit4LiB4LiB4Liy4Lij4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3JlbmV3JykiPjxkaXYgY2xhc3M9ImFpIj7wn5SEPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignZXh0ZW5kJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OFPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignYWRkZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+8J+TpjwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guYDguJ7guLTguYjguKEgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4LihPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3NldGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPuKalu+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguLHguYnguIcgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guIHguLPguKvguJnguJTguYPguKvguKHguYg8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVzZXQnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIM8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4gZGFuZ2VyIiBvbmNsaWNrPSJtQWN0aW9uKCdkZWxldGUnKSI+PGRpdiBjbGFzcz0iYWkiPvCfl5HvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lil4Lia4Lii4Li54LiqPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4peC4muC4luC4suC4p+C4ozwvZGl2PjwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC5iOC4reC4reC4suC4ouC4uCAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZW5ldyI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCDigJQg4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVuZXctYnRuIiBvbmNsaWNrPSJkb1JlbmV3VXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWV4dGVuZCI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OFIOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSDigJQg4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1leHRlbmQtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWV4dGVuZC1idG4iIG9uY2xpY2s9ImRvRXh0ZW5kVXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4LihIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItYWRkZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OmIOC5gOC4nuC4tOC5iOC4oSBEYXRhIOKAlCDguYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4Lih4LiI4Liy4LiB4LiX4Li14LmI4Lih4Li14Lit4Lii4Li54LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJkgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tYWRkZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMTAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWFkZGRhdGEtYnRuIiBvbmNsaWNrPSJkb0FkZERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oSBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4Lix4LmJ4LiHIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItc2V0ZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7impbvuI8g4LiV4Lix4LmJ4LiHIERhdGEg4oCUIOC4geC4s+C4q+C4meC4lCBMaW1pdCDguYPguKvguKHguYggKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj5EYXRhIExpbWl0IChHQikg4oCUIDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1zZXRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1zZXRkYXRhLWJ0biIgb25jbGljaz0iZG9TZXREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguLHguYnguIcgRGF0YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlc2V0Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIMg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4oCUIOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5ieC4l+C4seC5ieC4h+C4q+C4oeC4lDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guIHguLLguKPguKPguLXguYDguIvguJUgVHJhZmZpYyDguIjguLDguYDguITguKXguLXguKLguKPguYzguKLguK3guJQgVXBsb2FkL0Rvd25sb2FkIOC4l+C4seC5ieC4h+C4q+C4oeC4lOC4guC4reC4h+C4ouC4ueC4quC4meC4teC5iTwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZXNldC1idG4iIG9uY2xpY2s9ImRvUmVzZXRUcmFmZmljKCkiPuKchSDguKLguLfguJnguKLguLHguJnguKPguLXguYDguIvguJUgVHJhZmZpYzwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4peC4muC4ouC4ueC4qiAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1kZWxldGUiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPvCfl5HvuI8g4Lil4Lia4Lii4Li54LiqIOKAlCDguKXguJrguJbguLLguKfguKMg4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LiB4Li54LmJ4LiE4Li34LiZ4LmE4LiU4LmJPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4ouC4ueC4qiA8YiBpZD0ibS1kZWwtbmFtZSIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPjwvYj4g4LiI4Liw4LiW4Li54LiB4Lil4Lia4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4Lia4LiW4Liy4Lin4LijPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWRlbGV0ZS1idG4iIG9uY2xpY2s9ImRvRGVsZXRlVXNlcigpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNkYzI2MjYsI2VmNDQ0NCkiPvCfl5HvuI8g4Lii4Li34LiZ4Lii4Lix4LiZ4Lil4Lia4Lii4Li54LiqPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9Im1vZGFsLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIiBvbmVycm9yPSJ3aW5kb3cuQ0hBSVlBX0NPTkZJRz17fSI+PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8vIOKVkOKVkOKVkOKVkCBDT05GSUcg4pWQ4pWQ4pWQ4pWQCmNvbnN0IENGRyA9ICh0eXBlb2Ygd2luZG93LkNIQUlZQV9DT05GSUcgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdy5DSEFJWUFfQ09ORklHIDoge307CmNvbnN0IEhPU1QgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKY29uc3QgWFVJICA9IChDRkcuYmFzZXBhdGggfHwgJy94dWktYXBpJykucmVwbGFjZSgvXC8kLywgJycpOwpjb25zdCBBUEkgID0gJy9hcGknOwpjb25zdCBTRVNTSU9OX0tFWSA9ICdjaGFpeWFfYXV0aCc7CgovLyBTZXNzaW9uIGNoZWNrCmNvbnN0IF9zID0gKCgpID0+IHsgdHJ5IHsgcmV0dXJuIEpTT04ucGFyc2Uoc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSl8fCd7fScpOyB9IGNhdGNoKGUpe3JldHVybnt9O30gfSkoKTsKaWYgKCFfcy51c2VyIHx8ICFfcy5wYXNzIHx8IERhdGUubm93KCkgPj0gKF9zLmV4cHx8MCkpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8vIEhlYWRlciBkb21haW4KZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1kb21haW4nKS50ZXh0Q29udGVudCA9IEhPU1QgKyAnIMK3IHY1JzsKCi8vIOKVkOKVkOKVkOKVkCBVVElMUyDilZDilZDilZDilZAKZnVuY3Rpb24gZm10Qnl0ZXMoYikgewogIGlmICghYiB8fCBiID09PSAwKSByZXR1cm4gJzAgQic7CiAgY29uc3QgayA9IDEwMjQsIHUgPSBbJ0InLCdLQicsJ01CJywnR0InLCdUQiddOwogIGNvbnN0IGkgPSBNYXRoLmZsb29yKE1hdGgubG9nKGIpL01hdGgubG9nKGspKTsKICByZXR1cm4gKGIvTWF0aC5wb3coayxpKSkudG9GaXhlZCgxKSsnICcrdVtpXTsKfQpmdW5jdGlvbiBmbXREYXRlKG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGNvbnN0IGQgPSBuZXcgRGF0ZShtcyk7CiAgcmV0dXJuIGQudG9Mb2NhbGVEYXRlU3RyaW5nKCd0aC1USCcse3llYXI6J251bWVyaWMnLG1vbnRoOidzaG9ydCcsZGF5OidudW1lcmljJ30pOwp9CmZ1bmN0aW9uIGRheXNMZWZ0KG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuIG51bGw7CiAgcmV0dXJuIE1hdGguY2VpbCgobXMgLSBEYXRlLm5vdygpKSAvIDg2NDAwMDAwKTsKfQpmdW5jdGlvbiBzZXRSaW5nKGlkLCBwY3QpIHsKICBjb25zdCBjaXJjID0gMTM4LjI7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKGVsKSBlbC5zdHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gY2lyYyAtIChjaXJjICogTWF0aC5taW4ocGN0LDEwMCkgLyAxMDApOwp9CmZ1bmN0aW9uIHNldEJhcihpZCwgcGN0LCB3YXJuPWZhbHNlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLnN0eWxlLndpZHRoID0gTWF0aC5taW4ocGN0LDEwMCkgKyAnJSc7CiAgaWYgKHdhcm4gJiYgcGN0ID4gODUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNlZjQ0NDQsI2RjMjYyNiknOwogIGVsc2UgaWYgKHdhcm4gJiYgcGN0ID4gNjUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNmOTczMTYsI2ZiOTIzYyknOwp9CmZ1bmN0aW9uIHNob3dBbGVydChpZCwgbXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLmNsYXNzTmFtZSA9ICdhbGVydCAnK3R5cGU7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgaWYgKHR5cGUgPT09ICdvaycpIHNldFRpbWVvdXQoKCk9PntlbC5zdHlsZS5kaXNwbGF5PSdub25lJzt9LCAzMDAwKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE5BViDilZDilZDilZDilZAKZnVuY3Rpb24gc3cobmFtZSwgZWwpIHsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuc2VjJykuZm9yRWFjaChzPT5zLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcubmF2LWl0ZW0nKS5mb3JFYWNoKG49Pm4uY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWItJytuYW1lKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBlbC5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBpZiAobmFtZT09PSdjcmVhdGUnKSBjbG9zZUZvcm0oKTsKICBpZiAobmFtZT09PSdkYXNoYm9hcmQnKSBsb2FkRGFzaCgpOwogIGlmIChuYW1lPT09J21hbmFnZScpIGxvYWRVc2VycygpOwogIGlmIChuYW1lPT09J29ubGluZScpIGxvYWRPbmxpbmUoKTsKICBpZiAobmFtZT09PSdiYW4nKSBsb2FkU1NIVXNlcnMoKTsKfQoKLy8g4pSA4pSAIEZvcm0gbmF2IOKUgOKUgApsZXQgX2N1ckZvcm0gPSBudWxsOwpmdW5jdGlvbiBvcGVuRm9ybShpZCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9IGY9PT1pZCA/ICdibG9jaycgOiAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBpZDsKICBpZiAoaWQ9PT0nc3NoJykgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgd2luZG93LnNjcm9sbFRvKDAsMCk7Cn0KZnVuY3Rpb24gY2xvc2VGb3JtKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIFsnYWlzJywndHJ1ZScsJ3NzaCddLmZvckVhY2goZiA9PiB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9ybS0nK2YpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBudWxsOwp9CgpsZXQgX3dzUG9ydCA9ICc4MCc7CmZ1bmN0aW9uIHRvZ1BvcnQoYnRuLCBwb3J0KSB7CiAgX3dzUG9ydCA9IHBvcnQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzODAtYnRuJykuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgcG9ydD09PSc4MCcpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd3czQ0My1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzQ0MycpOwp9CmZ1bmN0aW9uIHRvZ0dyb3VwKGJ0biwgY2xzKSB7CiAgYnRuLmNsb3Nlc3QoJ2RpdicpLnF1ZXJ5U2VsZWN0b3JBbGwoY2xzKS5mb3JFYWNoKGI9PmIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGJ0bi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIFhVSSBMT0dJTiAoY29va2llKSDilZDilZDilZDilZAKbGV0IF94dWlPayA9IGZhbHNlOwphc3luYyBmdW5jdGlvbiB4dWlMb2dpbigpIHsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyLCBwYXNzd29yZDogX3MucGFzcyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aU9rID0gISFkLnN1Y2Nlc3M7CiAgcmV0dXJuIF94dWlPazsKfQphc3luYyBmdW5jdGlvbiB4dWlHZXQocGF0aCkgewogIGlmICghX3h1aU9rKSBhd2FpdCB4dWlMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIHJldHVybiByLmpzb24oKTsKfQphc3luYyBmdW5jdGlvbiB4dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICBib2R5OiBKU09OLnN0cmluZ2lmeShib2R5KQogIH0pOwogIHJldHVybiByLmpzb24oKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZERhc2goKSB7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1yZWZyZXNoJyk7CiAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyAuLi4nOwogIF94dWlPayA9IGZhbHNlOyAvLyBmb3JjZSByZS1sb2dpbiDguYDguKrguKHguK0KCiAgdHJ5IHsKICAgIC8vIFNTSCBBUEkgc3RhdHVzCiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChzdCkgewogICAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgICB9CgogICAgLy8gWFVJIHNlcnZlciBzdGF0dXMKICAgIGNvbnN0IG9rID0gYXdhaXQgeHVpTG9naW4oKTsKICAgIGlmICghb2spIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+TG9naW4g4LmE4Lih4LmI4LmE4LiU4LmJJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0gJ29waWxsIG9mZic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHN2ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL3NlcnZlci9zdGF0dXMnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3YgJiYgc3Yuc3VjY2VzcyAmJiBzdi5vYmopIHsKICAgICAgY29uc3QgbyA9IHN2Lm9iajsKICAgICAgLy8gQ1BVCiAgICAgIGNvbnN0IGNwdSA9IE1hdGgucm91bmQoby5jcHUgfHwgMCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtcGN0JykudGV4dENvbnRlbnQgPSBjcHUgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtY29yZXMnKS50ZXh0Q29udGVudCA9IChvLmNwdUNvcmVzIHx8IG8ubG9naWNhbFBybyB8fCAnLS0nKSArICcgY29yZXMnOwogICAgICBzZXRSaW5nKCdjcHUtcmluZycsIGNwdSk7IHNldEJhcignY3B1LWJhcicsIGNwdSwgdHJ1ZSk7CgogICAgICAvLyBSQU0KICAgICAgY29uc3QgcmFtVCA9ICgoby5tZW0/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgcmFtVSA9ICgoby5tZW0/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCByYW1QID0gcmFtVCA+IDAgPyBNYXRoLnJvdW5kKHJhbVUvcmFtVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1wY3QnKS50ZXh0Q29udGVudCA9IHJhbVAgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tZGV0YWlsJykudGV4dENvbnRlbnQgPSByYW1VLnRvRml4ZWQoMSkrJyAvICcrcmFtVC50b0ZpeGVkKDEpKycgR0InOwogICAgICBzZXRSaW5nKCdyYW0tcmluZycsIHJhbVApOyBzZXRCYXIoJ3JhbS1iYXInLCByYW1QLCB0cnVlKTsKCiAgICAgIC8vIERpc2sKICAgICAgY29uc3QgZHNrVCA9ICgoby5kaXNrPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIGRza1UgPSAoKG8uZGlzaz8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IGRza1AgPSBkc2tUID4gMCA/IE1hdGgucm91bmQoZHNrVS9kc2tUKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1wY3QnKS5pbm5lckhUTUwgPSBkc2tQICsgJzxzcGFuPiU8L3NwYW4+JzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stZGV0YWlsJykudGV4dENvbnRlbnQgPSBkc2tVLnRvRml4ZWQoMCkrJyAvICcrZHNrVC50b0ZpeGVkKDApKycgR0InOwogICAgICBzZXRCYXIoJ2Rpc2stYmFyJywgZHNrUCwgdHJ1ZSk7CgogICAgICAvLyBVcHRpbWUKICAgICAgY29uc3QgdXAgPSBvLnVwdGltZSB8fCAwOwogICAgICBjb25zdCB1ZCA9IE1hdGguZmxvb3IodXAvODY0MDApLCB1aCA9IE1hdGguZmxvb3IoKHVwJTg2NDAwKS8zNjAwKSwgdW0gPSBNYXRoLmZsb29yKCh1cCUzNjAwKS82MCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtdmFsJykudGV4dENvbnRlbnQgPSB1ZCA+IDAgPyB1ZCsnZCAnK3VoKydoJyA6IHVoKydoICcrdW0rJ20nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXN1YicpLnRleHRDb250ZW50ID0gdWQrJ+C4p+C4seC4mSAnK3VoKyfguIrguKEuICcrdW0rJ+C4meC4suC4l+C4tSc7CiAgICAgIGNvbnN0IGxvYWRzID0gby5sb2FkcyB8fCBbXTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvYWQtY2hpcHMnKS5pbm5lckhUTUwgPSBsb2Fkcy5tYXAoKGwsaSk9PgogICAgICAgIGA8c3BhbiBjbGFzcz0iYmRnIj4ke1snMW0nLCc1bScsJzE1bSddW2ldfTogJHtsLnRvRml4ZWQoMil9PC9zcGFuPmApLmpvaW4oJycpOwoKICAgICAgLy8gTmV0d29yawogICAgICBpZiAoby5uZXRJTykgewogICAgICAgIGNvbnN0IHVwX2IgPSBvLm5ldElPLnVwfHwwLCBkbl9iID0gby5uZXRJTy5kb3dufHwwOwogICAgICAgIGNvbnN0IHVwRm10ID0gZm10Qnl0ZXModXBfYiksIGRuRm10ID0gZm10Qnl0ZXMoZG5fYik7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cCcpLmlubmVySFRNTCA9IHVwRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4nKS5pbm5lckhUTUwgPSBkbkZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgfQogICAgICBpZiAoby5uZXRUcmFmZmljKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cC10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5zZW50fHwwKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnJlY3Z8fDApOwogICAgICB9CgogICAgICAvLyBYVUkgdmVyc2lvbgogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXZlcicpLnRleHRDb250ZW50ID0gby54cmF5VmVyc2lvbiB8fCAnLS0nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPuC4reC4reC4meC5hOC4peC4meC5jCc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCc7CiAgICB9CgogICAgLy8gSW5ib3VuZHMgY291bnQKICAgIGNvbnN0IGlibCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKGlibCAmJiBpYmwuc3VjY2VzcykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLWluYm91bmRzJykudGV4dENvbnRlbnQgPSAoaWJsLm9ianx8W10pLmxlbmd0aDsKICAgIH0KCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGFzdC11cGRhdGUnKS50ZXh0Q29udGVudCA9ICfguK3guLHguJ7guYDguJTguJfguKXguYjguLLguKrguLjguJQ6ICcgKyBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnNvbGUuZXJyb3IoZSk7CiAgfSBmaW5hbGx5IHsKICAgIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsg4Lij4Li14LmA4Lif4Lij4LiKJzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTRVJWSUNFUyDilZDilZDilZDilZAKY29uc3QgU1ZDX0RFRiA9IFsKICB7IGtleToneHVpJywgICAgICBpY29uOifwn5OhJywgbmFtZToneC11aSBQYW5lbCcsICAgICAgcG9ydDonOjIwNTMnIH0sCiAgeyBrZXk6J3NzaCcsICAgICAgaWNvbjon8J+QjScsIG5hbWU6J1NTSCBBUEknLCAgICAgICAgICBwb3J0Oic6Njc4OScgfSwKICB7IGtleTonZHJvcGJlYXInLCBpY29uOifwn5C7JywgbmFtZTonRHJvcGJlYXIgU1NIJywgICAgIHBvcnQ6JzoxNDMgOjEwOScgfSwKICB7IGtleTonbmdpbngnLCAgICBpY29uOifwn4yQJywgbmFtZTonbmdpbnggLyBQYW5lbCcsICAgIHBvcnQ6Jzo4MCA6NDQzJyB9LAogIHsga2V5Oidzc2h3cycsICAgIGljb246J/CflJInLCBuYW1lOidXUy1TdHVubmVsJywgICAgICAgcG9ydDonOjgw4oaSOjE0MycgfSwKICB7IGtleTonYmFkdnBuJywgICBpY29uOifwn46uJywgbmFtZTonQmFkVlBOIFVEUEdXJywgICAgIHBvcnQ6Jzo3MzAwJyB9LApdOwpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcyhtYXApIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSBTVkNfREVGLm1hcChzID0+IHsKICAgIGNvbnN0IHVwID0gbWFwW3Mua2V5XSA9PT0gdHJ1ZSB8fCBtYXBbcy5rZXldID09PSAnYWN0aXZlJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0ic3ZjICR7dXA/Jyc6J2Rvd24nfSI+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1sIj48c3BhbiBjbGFzcz0iZGcgJHt1cD8nJzoncmVkJ30iPjwvc3Bhbj48c3Bhbj4ke3MuaWNvbn08L3NwYW4+CiAgICAgICAgPGRpdj48ZGl2IGNsYXNzPSJzdmMtbiI+JHtzLm5hbWV9PC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPiR7cy5wb3J0fTwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9InJiZGcgJHt1cD8nJzonZG93bid9Ij4ke3VwPydSVU5OSU5HJzonRE9XTid9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQphc3luYyBmdW5jdGlvbiBsb2FkU2VydmljZXMoKSB7CiAgdHJ5IHsKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggUElDS0VSIFNUQVRFIOKVkOKVkOKVkOKVkApjb25zdCBQUk9TID0gewogIGR0YWM6IHsKICAgIG5hbWU6ICdEVEFDIEdBTUlORycsCiAgICBwcm94eTogJzEwNC4xOC42My4xMjQ6ODAnLAogICAgcGF5bG9hZDogJ0NPTk5FQ1QgLyAgSFRUUC8xLjEgW2NybGZdSG9zdDogZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbSBbY3JsZl1bY3JsZl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDpbaG9zdF1bY3JsZl1VcGdyYWRlOlVzZXItQWdlbnQ6IFt1YV1bY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfSwKICB0cnVlOiB7CiAgICBuYW1lOiAnVFJVRSBUV0lUVEVSJywKICAgIHByb3h5OiAnMTA0LjE4LjM5LjI0OjgwJywKICAgIHBheWxvYWQ6ICdQT1NUIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OmhlbHAueC5jb21bY3JsZl1Vc2VyLUFnZW50OiBbdWFdW2NybGZdW2NybGZdW3NwbGl0XVtjcl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDogW2hvc3RdW2NybGZdVXBncmFkZTogd2Vic29ja2V0W2NybGZdQ29ubmVjdGlvbjpVcGdyYWRlW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0KfTsKY29uc3QgTlBWX0hPU1QgPSAnd3d3LnByb2plY3QuZ29kdnBuLnNob3AnLCBOUFZfUE9SVCA9IDgwOwpsZXQgX3NzaFBybyA9ICdkdGFjJywgX3NzaEFwcCA9ICducHYnLCBfc3NoUG9ydCA9ICc4MCc7CgpmdW5jdGlvbiBwaWNrUG9ydChwKSB7CiAgX3NzaFBvcnQgPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi04MCcpLmNsYXNzTmFtZSAgPSAncG9ydC1idG4nICsgKHA9PT0nODAnICA/ICcgYWN0aXZlLXA4MCcgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi00NDMnKS5jbGFzc05hbWUgPSAncG9ydC1idG4nICsgKHA9PT0nNDQzJyA/ICcgYWN0aXZlLXA0NDMnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tQcm8ocCkgewogIF9zc2hQcm8gPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tZHRhYycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSdkdGFjJyA/ICcgYS1kdGFjJyA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLXRydWUnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0ndHJ1ZScgPyAnIGEtdHJ1ZScgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja0FwcChhKSB7CiAgX3NzaEFwcCA9IGE7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcC1ucHYnKS5jbGFzc05hbWUgID0gJ3BpY2stb3B0JyArIChhPT09J25wdicgID8gJyBhLW5wdicgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtZGFyaycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAoYT09PSdkYXJrJyA/ICcgYS1kYXJrJyA6ICcnKTsKfQpmdW5jdGlvbiBidWlsZE5wdkxpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgaiA9IHsKICAgIHNzaENvbmZpZ1R5cGU6J1NTSC1Qcm94eS1QYXlsb2FkJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6TlBWX0hPU1QsIHNzaFBvcnQ6TlBWX1BPUlQsCiAgICBzc2hVc2VybmFtZTpuYW1lLCBzc2hQYXNzd29yZDpwYXNzLAogICAgc25pOicnLCB0bHNWZXJzaW9uOidERUZBVUxUJywKICAgIGh0dHBQcm94eTpwcm8ucHJveHksIGF1dGhlbnRpY2F0ZVByb3h5OmZhbHNlLAogICAgcHJveHlVc2VybmFtZTonJywgcHJveHlQYXNzd29yZDonJywKICAgIHBheWxvYWQ6cHJvLnBheWxvYWQsCiAgICBkbnNNb2RlOidVRFAnLCBkbnNTZXJ2ZXI6JycsIG5hbWVzZXJ2ZXI6JycsIHB1YmxpY0tleTonJywKICAgIHVkcGd3UG9ydDo3MzAwLCB1ZHBnd1RyYW5zcGFyZW50RE5TOnRydWUKICB9OwogIHJldHVybiAnbnB2dC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KZnVuY3Rpb24gYnVpbGREYXJrTGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBwcCA9IChwcm8ucHJveHl8fCcnKS5zcGxpdCgnOicpOwogIGNvbnN0IGRoID0gcHBbMF0gfHwgcHJvLmRhcmtQcm94eTsKICBjb25zdCBqID0gewogICAgY29uZmlnVHlwZTonU1NILVBST1hZJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6SE9TVCwgc3NoUG9ydDoxNDMsCiAgICBzc2hVc2VyOm5hbWUsIHNzaFBhc3M6cGFzcywKICAgIHBheWxvYWQ6J0dFVCAvIEhUVFAvMS4xXHJcbkhvc3Q6ICcrSE9TVCsnXHJcblVwZ3JhZGU6IHdlYnNvY2tldFxyXG5Db25uZWN0aW9uOiBVcGdyYWRlXHJcblxyXG4nLAogICAgcHJveHlIb3N0OmRoLCBwcm94eVBvcnQ6ODAsCiAgICB1ZHBnd0FkZHI6JzEyNy4wLjAuMScsIHVkcGd3UG9ydDo3MzAwLCB0bHNFbmFibGVkOmZhbHNlCiAgfTsKICByZXR1cm4gJ2Rhcmt0dW5uZWwtc3NoOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CgovLyDilZDilZDilZDilZAgQ1JFQVRFIFNTSCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1kYXlzJykudmFsdWUpfHwzMDsKICBjb25zdCBpcGwgID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpID8gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpLnZhbHVlIDogMil8fDI7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIXBhc3MpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBQYXNzd29yZCcsJ2VycicpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMzQsMTk3LDk0LC4zKTtib3JkZXItdG9wLWNvbG9yOiMyMmM1NWUiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBjb25zdCByZXNFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtbGluay1yZXN1bHQnKTsKICBpZiAocmVzRWwpIHJlc0VsLmNsYXNzTmFtZT0nbGluay1yZXN1bHQnOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvY3JlYXRlX3NzaCcsIHsKICAgICAgbWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoe3VzZXIsIHBhc3N3b3JkOnBhc3MsIGRheXMsIGlwX2xpbWl0OmlwbH0pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0IHBybyAgPSBQUk9TW19zc2hQcm9dIHx8IFBST1MuZHRhYzsKICAgIGNvbnN0IGxpbmsgPSBfc3NoQXBwPT09J25wdicgPyBidWlsZE5wdkxpbmsodXNlcixwYXNzLHBybykgOiBidWlsZERhcmtMaW5rKHVzZXIscGFzcyxwcm8pOwogICAgY29uc3QgaXNOcHYgPSBfc3NoQXBwPT09J25wdic7CiAgICBjb25zdCBscENscyA9IGlzTnB2ID8gJycgOiAnIGRhcmstbHAnOwogICAgY29uc3QgY0NscyAgPSBpc05wdiA/ICducHYnIDogJ2RhcmsnOwogICAgY29uc3QgYXBwTGFiZWwgPSBpc05wdiA/ICdOcHZ0JyA6ICdEYXJrVHVubmVsJzsKCiAgICBpZiAocmVzRWwpIHsKICAgICAgcmVzRWwuY2xhc3NOYW1lID0gJ2xpbmstcmVzdWx0IHNob3cnOwogICAgICBjb25zdCBzYWZlTGluayA9IGxpbmsucmVwbGFjZSgvXFwvZywnXFxcXCcpLnJlcGxhY2UoLycvZywiXFwnIik7CiAgICAgIHJlc0VsLmlubmVySFRNTCA9CiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcmVzdWx0LWhkcic+IiArCiAgICAgICAgICAiPHNwYW4gY2xhc3M9J2ltcC1iYWRnZSAiK2NDbHMrIic+IithcHBMYWJlbCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOnZhcigtLW11dGVkKSc+Iitwcm8ubmFtZSsiIFx4YjcgUG9ydCAiK19zc2hQb3J0KyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6IzIyYzU1ZTttYXJnaW4tbGVmdDphdXRvJz5cdTI3MDUgIit1c2VyKyI8L3NwYW4+IiArCiAgICAgICAgIjwvZGl2PiIgKwogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXByZXZpZXciK2xwQ2xzKyInPiIrbGluaysiPC9kaXY+IiArCiAgICAgICAgIjxidXR0b24gY2xhc3M9J2NvcHktbGluay1idG4gIitjQ2xzKyInIGlkPSdjb3B5LXNzaC1idG4nIG9uY2xpY2s9XCJjb3B5U1NITGluaygpXCI+IisKICAgICAgICAgICJcdWQ4M2RcdWRjY2IgQ29weSAiK2FwcExhYmVsKyIgTGluayIrCiAgICAgICAgIjwvYnV0dG9uPiI7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExpbmsgPSBsaW5rOwogICAgICB3aW5kb3cuX2xhc3RTU0hBcHAgID0gY0NsczsKICAgICAgd2luZG93Ll9sYXN0U1NITGFiZWwgPSBhcHBMYWJlbDsKICAgIH0KCiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIIMK3IOC4q+C4oeC4lOC4reC4suC4ouC4uCAnK2QuZXhwLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWU9Jyc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZT0nJzsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfinpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXInOyB9Cn0KZnVuY3Rpb24gY29weVNTSExpbmsoKSB7CiAgY29uc3QgbGluayA9IHdpbmRvdy5fbGFzdFNTSExpbmt8fCcnOwogIGNvbnN0IGNDbHMgPSB3aW5kb3cuX2xhc3RTU0hBcHB8fCducHYnOwogIGNvbnN0IGxhYmVsID0gd2luZG93Ll9sYXN0U1NITGFiZWx8fCdMaW5rJzsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dChsaW5rKS50aGVuKGZ1bmN0aW9uKCl7CiAgICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvcHktc3NoLWJ0bicpOwogICAgaWYoYil7IGIudGV4dENvbnRlbnQ9J1x1MjcwNSDguITguLHguJTguKXguK3guIHguYHguKXguYnguKchJzsgc2V0VGltZW91dChmdW5jdGlvbigpe2IudGV4dENvbnRlbnQ9J1x1ZDgzZFx1ZGNjYiBDb3B5ICcrbGFiZWwrJyBMaW5rJzt9LDIwMDApOyB9CiAgfSkuY2F0Y2goZnVuY3Rpb24oKXsgcHJvbXB0KCdDb3B5IGxpbms6JyxsaW5rKTsgfSk7Cn0KCi8vIFNTSCB1c2VyIHRhYmxlCmxldCBfc3NoVGFibGVVc2VycyA9IFtdOwphc3luYyBmdW5jdGlvbiBsb2FkU1NIVGFibGVJbkZvcm0oKSB7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgX3NzaFRhYmxlVXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICAgIGlmKHRiKSB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiNlZjQ0NDQ7cGFkZGluZzoxNnB4Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gU1NIIEFQSSDguYTguKHguYjguYTguJTguYk8L3RkPjwvdHI+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyU1NIVGFibGUodXNlcnMpIHsKICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogIGlmICghdGIpIHJldHVybjsKICBpZiAoIXVzZXJzLmxlbmd0aCkgewogICAgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzoyMHB4Ij7guYTguKHguYjguKHguLUgU1NIIHVzZXJzPC90ZD48L3RyPic7CiAgICByZXR1cm47CiAgfQogIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICB0Yi5pbm5lckhUTUwgPSB1c2Vycy5tYXAoZnVuY3Rpb24odSxpKXsKICAgIGNvbnN0IGV4cGlyZWQgPSB1LmV4cCAmJiB1LmV4cCA8IG5vdzsKICAgIGNvbnN0IGFjdGl2ZSAgPSB1LmFjdGl2ZSAhPT0gZmFsc2UgJiYgIWV4cGlyZWQ7CiAgICBjb25zdCBkTGVmdCAgID0gdS5leHAgPyBNYXRoLmNlaWwoKG5ldyBEYXRlKHUuZXhwKS1EYXRlLm5vdygpKS84NjQwMDAwMCkgOiBudWxsOwogICAgY29uc3QgYmFkZ2UgICA9IGFjdGl2ZQogICAgICA/ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1nIj5BQ1RJVkU8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1yIj5FWFBJUkVEPC9zcGFuPic7CiAgICBjb25zdCBkVGFnID0gZExlZnQhPT1udWxsCiAgICAgID8gJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj4nKyhkTGVmdD4wP2RMZWZ0KydkJzon4Lir4Lih4LiUJykrJzwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj5cdTIyMWU8L3NwYW4+JzsKICAgIHJldHVybiAnPHRyPjx0ZCBzdHlsZT0iY29sb3I6dmFyKC0tbXV0ZWQpIj4nKyhpKzEpKyc8L3RkPicgKwogICAgICAnPHRkPjxiPicrdS51c2VyKyc8L2I+PC90ZD4nICsKICAgICAgJzx0ZCBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6JysoZXhwaXJlZD8nI2VmNDQ0NCc6J3ZhcigtLW11dGVkKScpKyciPicrCiAgICAgICAgKHUuZXhwfHwn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJzwvdGQ+JyArCiAgICAgICc8dGQ+JytiYWRnZSsnPC90ZD4nICsKICAgICAgJzx0ZD48ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjRweDthbGlnbi1pdGVtczpjZW50ZXIiPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguJXguYjguK3guK3guLLguKLguLgiIG9uY2xpY2s9Im9wZW5TU0hSZW5ld01vZGFsKFwnJyt1LnVzZXIrJ1wnKSI+8J+UhDwvYnV0dG9uPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguKXguJoiIG9uY2xpY2s9ImRlbFNTSFVzZXIoXCcnK3UudXNlcisnXCcpIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LC4zKSI+8J+Xke+4jzwvYnV0dG9uPicrCiAgICAgICAgZFRhZysKICAgICAgJzwvZGl2PjwvdGQ+PC90cj4nOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclNTSFVzZXJzKHEpIHsKICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycy5maWx0ZXIoZnVuY3Rpb24odSl7cmV0dXJuICh1LnVzZXJ8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSk7fSkpOwp9Ci8vIFNTSCBSZW5ldyBNb2RhbApsZXQgX3JlbmV3U1NIVXNlciA9ICcnOwpmdW5jdGlvbiBvcGVuU1NIUmVuZXdNb2RhbCh1c2VyKSB7CiAgX3JlbmV3U1NIVXNlciA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy11c2VybmFtZScpLnRleHRDb250ZW50ID0gdXNlcjsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSA9ICczMCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbG9zZVNTSFJlbmV3TW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfcmVuZXdTU0hVc2VyID0gJyc7Cn0KYXN5bmMgZnVuY3Rpb24gZG9TU0hSZW5ldygpIHsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmICghZGF5c3x8ZGF5czw9MCkgcmV0dXJuOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsgYnRuLnRleHRDb250ZW50ID0gJ+C4geC4s+C4peC4seC4h+C4leC5iOC4reC4reC4suC4ouC4uC4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9leHRlbmRfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcjpfcmVuZXdTU0hVc2VyLGRheXN9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguJXguYjguK3guK3guLLguKLguLggJytfcmVuZXdTU0hVc2VyKycgKycrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgY2xvc2VTU0hSZW5ld01vZGFsKCk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsKICB9IGZpbmFsbHkgewogICAgYnRuLmRpc2FibGVkID0gZmFsc2U7IGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gcmVuZXdTU0hVc2VyKHVzZXIpIHsgb3BlblNTSFJlbmV3TW9kYWwodXNlcik7IH0KYXN5bmMgZnVuY3Rpb24gZGVsU1NIVXNlcih1c2VyKSB7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiDguJbguLLguKfguKM/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4Lil4LiaICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgYWxlcnQoJ1x1Mjc0YyAnK2UubWVzc2FnZSk7IH0KfQovLyDilZDilZDilZDilZAgQ1JFQVRFIFZMRVNTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csYz0+ewogICAgY29uc3Qgcj1NYXRoLnJhbmRvbSgpKjE2fDA7IHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3wweDgpKS50b1N0cmluZygxNik7CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gY3JlYXRlVkxFU1MoY2FycmllcikgewogIGNvbnN0IGVtYWlsRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZW1haWwnKTsKICBjb25zdCBkYXlzRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWRheXMnKTsKICBjb25zdCBpcEVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWlwJyk7CiAgY29uc3QgZ2JFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1nYicpOwogIGNvbnN0IGVtYWlsICAgPSBlbWFpbEVsLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzICAgID0gcGFyc2VJbnQoZGF5c0VsLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50KGlwRWwudmFsdWUpfHwyOwogIGNvbnN0IGdiICAgICAgPSBwYXJzZUludChnYkVsLnZhbHVlKXx8MDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBFbWFpbC9Vc2VybmFtZScsJ2VycicpOwoKICBjb25zdCBwb3J0ID0gY2Fycmllcj09PSdhaXMnID8gODA4MCA6IDg4ODA7CiAgY29uc3Qgc25pICA9IGNhcnJpZXI9PT0nYWlzJyA/ICdjai1lYmIuc3BlZWR0ZXN0Lm5ldCcgOiAndHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlcyc7CgogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1idG4nKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CgogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIC8vIOC4q+C4siBpbmJvdW5kIGlkCiAgICBjb25zdCBsaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliID0gKGxpc3Qub2JqfHxbXSkuZmluZCh4PT54LnBvcnQ9PT1wb3J0KTsKICAgIGlmICghaWIpIHRocm93IG5ldyBFcnJvcihg4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCAke3BvcnR9IOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZYCk7CgogICAgY29uc3QgdWlkID0gZ2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXMgPSBkYXlzID4gMCA/IChEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMCkgOiAwOwogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDp1aWQsIGZsb3c6JycsIGVtYWlsLCBsaW1pdElwOmlwTGltaXQsCiAgICAgICAgdG90YWxHQjp0b3RhbEJ5dGVzLCBleHBpcnlUaW1lOmV4cE1zLCBlbmFibGU6dHJ1ZSwgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgbGluayA9IGB2bGVzczovLyR7dWlkfUAke0hPU1R9OiR7cG9ydH0/dHlwZT13cyZzZWN1cml0eT1ub25lJnBhdGg9JTJGdmxlc3MmaG9zdD0ke3NuaX0jJHtlbmNvZGVVUklDb21wb25lbnQoZW1haWwrJy0nKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSl9YDsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1lbWFpbCcpLnRleHRDb250ZW50ID0gZW1haWw7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy11dWlkJykudGV4dENvbnRlbnQgPSB1aWQ7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1leHAnKS50ZXh0Q29udGVudCA9IGV4cE1zID4gMCA/IGZtdERhdGUoZXhwTXMpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1saW5rJykudGV4dENvbnRlbnQgPSBsaW5rOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgIC8vIEdlbmVyYXRlIFFSIGNvZGUKICAgIGNvbnN0IHFyRGl2ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXFyJyk7CiAgICBpZiAocXJEaXYpIHsKICAgICAgcXJEaXYuaW5uZXJIVE1MID0gJyc7CiAgICAgIHRyeSB7CiAgICAgICAgbmV3IFFSQ29kZShxckRpdiwgeyB0ZXh0OiBsaW5rLCB3aWR0aDogMTgwLCBoZWlnaHQ6IDE4MCwgY29ycmVjdExldmVsOiBRUkNvZGUuQ29ycmVjdExldmVsLk0gfSk7CiAgICAgIH0gY2F0Y2gocXJFcnIpIHsgcXJEaXYuaW5uZXJIVE1MID0gJyc7IH0KICAgIH0KICAgIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHIFZMRVNTIEFjY291bnQg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGVtYWlsRWwudmFsdWU9Jyc7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4pqhIOC4quC4o+C5ieC4suC4hyAnKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSsnIEFjY291bnQnOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBNQU5BR0UgVVNFUlMg4pWQ4pWQ4pWQ4pWQCmxldCBfYWxsVXNlcnMgPSBbXSwgX2N1clVzZXIgPSBudWxsOwphc3luYyBmdW5jdGlvbiBsb2FkVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcign4LmC4Lir4Lil4LiU4LmE4Lih4LmI4LmE4LiU4LmJJyk7CiAgICBfYWxsVXNlcnMgPSBbXTsKICAgIChkLm9ianx8W10pLmZvckVhY2goaWIgPT4gewogICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgIF9hbGxVc2Vycy5wdXNoKHsKICAgICAgICAgIGliSWQ6IGliLmlkLCBwb3J0OiBpYi5wb3J0LCBwcm90bzogaWIucHJvdG9jb2wsCiAgICAgICAgICBlbWFpbDogYy5lbWFpbHx8Yy5pZCwgdXVpZDogYy5pZCwKICAgICAgICAgIGV4cDogYy5leHBpcnlUaW1lfHwwLCB0b3RhbDogYy50b3RhbEdCfHwwLAogICAgICAgICAgdXA6IGliLnVwfHwwLCBkb3duOiBpYi5kb3dufHwwLCBsaW1pdElwOiBjLmxpbWl0SXB8fDAKICAgICAgICB9KTsKICAgICAgfSk7CiAgICB9KTsKICAgIHJlbmRlclVzZXJzKF9hbGxVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyVXNlcnModXNlcnMpIHsKICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfk608L2Rpdj48cD7guYTguKHguYjguJ7guJrguKLguLnguKrguYDguIvguK3guKPguYw8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHUgPT4gewogICAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgICBsZXQgYmFkZ2UsIGNsczsKICAgIGlmICghdS5leHAgfHwgdS5leHA9PT0wKSB7IGJhZGdlPSfinJMg4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsgY2xzPSdvayc7IH0KICAgIGVsc2UgaWYgKGRsIDwgMCkgICAgICAgICB7IGJhZGdlPSfguKvguKHguJTguK3guLLguKLguLgnOyBjbHM9J2V4cCc7IH0KICAgIGVsc2UgaWYgKGRsIDw9IDMpICAgICAgICB7IGJhZGdlPSfimqAgJytkbCsnZCc7IGNscz0nc29vbic7IH0KICAgIGVsc2UgICAgICAgICAgICAgICAgICAgICB7IGJhZGdlPSfinJMgJytkbCsnZCc7IGNscz0nb2snOyB9CiAgICBjb25zdCBhdkNscyA9IGRsIDwgMCA/ICdhdi14JyA6ICdhdi1nJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIG9uY2xpY2s9Im9wZW5Vc2VyKCR7SlNPTi5zdHJpbmdpZnkodSkucmVwbGFjZSgvIi9nLCcmcXVvdDsnKX0pIj4KICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YXZDbHN9Ij4keyh1LmVtYWlsfHwnPycpWzBdLnRvVXBwZXJDYXNlKCl9PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS5lbWFpbH08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+UG9ydCAke3UucG9ydH0gwrcgJHtmbXRCeXRlcyh1LnVwK3UuZG93bil9IOC5g+C4iuC5iTwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHtjbHN9Ij4ke2JhZGdlfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsdGVyVXNlcnMocSkgewogIHJlbmRlclVzZXJzKF9hbGxVc2Vycy5maWx0ZXIodT0+KHUuZW1haWx8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSkpKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1PREFMIFVTRVIg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIG9wZW5Vc2VyKHUpIHsKICBpZiAodHlwZW9mIHUgPT09ICdzdHJpbmcnKSB1ID0gSlNPTi5wYXJzZSh1KTsKICBfY3VyVXNlciA9IHU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ210JykudGV4dENvbnRlbnQgPSAn4pqZ77iPICcrdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHUnKS50ZXh0Q29udGVudCA9IHUuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RwJykudGV4dENvbnRlbnQgPSB1LnBvcnQ7CiAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgY29uc3QgZXhwVHh0ID0gIXUuZXhwfHx1LmV4cD09PTAgPyAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJyA6IGZtdERhdGUodS5leHApOwogIGNvbnN0IGRlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RlJyk7CiAgZGUudGV4dENvbnRlbnQgPSBleHBUeHQ7CiAgZGUuY2xhc3NOYW1lID0gJ2R2JyArIChkbCAhPT0gbnVsbCAmJiBkbCA8IDAgPyAnIHJlZCcgOiAnIGdyZWVuJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RkJykudGV4dENvbnRlbnQgPSB1LnRvdGFsID4gMCA/IGZtdEJ5dGVzKHUudG90YWwpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R0cicpLnRleHRDb250ZW50ID0gZm10Qnl0ZXModS51cCt1LmRvd24pOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaScpLnRleHRDb250ZW50ID0gdS5saW1pdElwIHx8ICfiiJ4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdXUnKS50ZXh0Q29udGVudCA9IHUudXVpZDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY20oKXsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7Cn0KCi8vIOKUgOKUgCBNT0RBTCA2LUFDVElPTiBTWVNURU0g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNvbnN0IF9tU3VicyA9IFsncmVuZXcnLCdleHRlbmQnLCdhZGRkYXRhJywnc2V0ZGF0YScsJ3Jlc2V0JywnZGVsZXRlJ107CmZ1bmN0aW9uIG1BY3Rpb24oa2V5KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2tleSk7CiAgY29uc3QgaXNPcGVuID0gZWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgaWYgKCFpc09wZW4pIHsKICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgIGlmIChrZXk9PT0nZGVsZXRlJyAmJiBfY3VyVXNlcikgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZGVsLW5hbWUnKS50ZXh0Q29udGVudCA9IF9jdXJVc2VyLmVtYWlsOwogICAgc2V0VGltZW91dCgoKT0+ZWwuc2Nyb2xsSW50b1ZpZXcoe2JlaGF2aW9yOidzbW9vdGgnLGJsb2NrOiduZWFyZXN0J30pLDEwMCk7CiAgfQp9CmZ1bmN0aW9uIF9tQnRuTG9hZChpZCwgbG9hZGluZywgb3JpZ1RleHQpIHsKICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghYikgcmV0dXJuOwogIGIuZGlzYWJsZWQgPSBsb2FkaW5nOwogIGlmIChsb2FkaW5nKSB7IGIuZGF0YXNldC5vcmlnID0gYi50ZXh0Q29udGVudDsgYi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj4g4LiB4Liz4Lil4Lix4LiH4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijLi4uJzsgfQogIGVsc2UgaWYgKGIuZGF0YXNldC5vcmlnKSBiLnRleHRDb250ZW50ID0gYi5kYXRhc2V0Lm9yaWc7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvUmVuZXdVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tcmVuZXctZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoZGF5cyA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iOC4s+C4meC4p+C4meC4p+C4seC4mScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1yZW5ldy1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgZXhwTXMgPSBEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpfY3VyVXNlci50b3RhbCxleHBpcnlUaW1lOmV4cE1zLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguJXguYjguK3guK3guLLguKLguLjguKrguLPguYDguKPguYfguIggJytkYXlzKycg4Lin4Lix4LiZICjguKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYkpJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVuZXctYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRXh0ZW5kVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWV4dGVuZC1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLWV4dGVuZC1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgYmFzZSA9IChfY3VyVXNlci5leHAgJiYgX2N1clVzZXIuZXhwID4gRGF0ZS5ub3coKSkgPyBfY3VyVXNlci5leHAgOiBEYXRlLm5vdygpOwogICAgY29uc3QgZXhwTXMgPSBiYXNlICsgZGF5cyo4NjQwMDAwMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpfY3VyVXNlci50b3RhbCxleHBpcnlUaW1lOmV4cE1zLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguYDguJ7guLTguYjguKEgJytkYXlzKycg4Lin4Lix4LiZIOC4quC4s+C5gOC4o+C5h+C4iCAo4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUKScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWV4dGVuZC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9BZGREYXRhKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBhZGRHYiA9IHBhcnNlRmxvYXQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tYWRkZGF0YS1nYicpLnZhbHVlKXx8MDsKICBpZiAoYWRkR2IgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIEgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLWFkZGRhdGEtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IG5ld1RvdGFsID0gKF9jdXJVc2VyLnRvdGFsfHwwKSArIGFkZEdiKjEwNzM3NDE4MjQ7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6bmV3VG90YWwsZXhwaXJ5VGltZTpfY3VyVXNlci5leHB8fDAsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSBEYXRhICsnK2FkZEdiKycgR0Ig4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tYWRkZGF0YS1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9TZXREYXRhKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBnYiA9IHBhcnNlRmxvYXQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tc2V0ZGF0YS1nYicpLnZhbHVlKTsKICBpZiAoaXNOYU4oZ2IpfHxnYjwwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tc2V0ZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOnRvdGFsQnl0ZXMsZXhwaXJ5VGltZTpfY3VyVXNlci5leHB8fDAsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC4seC5ieC4hyBEYXRhIExpbWl0ICcrKGdiPjA/Z2IrJyBHQic6J+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcpKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tc2V0ZGF0YS1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9SZXNldFRyYWZmaWMoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIF9tQnRuTG9hZCgnbS1yZXNldC1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL3Jlc2V0Q2xpZW50VHJhZmZpYy8nK19jdXJVc2VyLmVtYWlsKTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxNTAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXJlc2V0LWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0RlbGV0ZVVzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIF9tQnRuTG9hZCgnbS1kZWxldGUtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9kZWxDbGllbnQvJytfY3VyVXNlci51dWlkKTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4peC4muC4ouC4ueC4qiAnK19jdXJVc2VyLmVtYWlsKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDEyMDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIGZhbHNlKTsgfQp9CgovLyDilZDilZDilZDilZAgT05MSU5FIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkT25saW5lKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICBjb25zdCBvZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9vbmxpbmVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgY29uc3QgZW1haWxzID0gKG9kICYmIG9kLm9iaikgPyBvZC5vYmogOiBbXTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YXYgYXYtZyI+8J+fojwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHtlbWFpbH08L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVtIj4ke3UgPyAnUG9ydCAnK3UucG9ydCA6ICdWTEVTUyd9IMK3IOC4reC4reC4meC5hOC4peC4meC5jOC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIG9rIj5PTkxJTkU8L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBVU0VSUyAoYmFuIHRhYikg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCB1c2VycyA9IGQudXNlcnMgfHwgW107CiAgICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvcD48L2Rpdj4nOyByZXR1cm47IH0KICAgIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHU9PnsKICAgICAgY29uc3QgZXhwID0gdS5leHAgfHwgJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICAgIGNvbnN0IGFjdGl2ZSA9IHUuYWN0aXZlICE9PSBmYWxzZTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YWN0aXZlPydhdi1nJzonYXYteCd9Ij4ke3UudXNlclswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LnVzZXJ9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+4Lir4Lih4LiU4Lit4Liy4Lii4Li4OiAke2V4cH08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2FjdGl2ZT8nb2snOidleHAnfSI+JHthY3RpdmU/J0FjdGl2ZSc6J0V4cGlyZWQnfTwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsZXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZS50cmltKCk7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciID8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSl9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3J8fCfguKXguJrguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVXNlcnMoKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBDT1BZIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBjb3B5TGluayhpZCwgYnRuKSB7CiAgY29uc3QgdHh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHR4dCkudGhlbigoKT0+ewogICAgY29uc3Qgb3JpZyA9IGJ0bi50ZXh0Q29udGVudDsKICAgIGJ0bi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0ncmdiYSgzNCwxOTcsOTQsLjE1KSc7CiAgICBzZXRUaW1lb3V0KCgpPT57IGJ0bi50ZXh0Q29udGVudD1vcmlnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0nJzsgfSwgMjAwMCk7CiAgfSkuY2F0Y2goKCk9PnsgcHJvbXB0KCdDb3B5IGxpbms6JywgdHh0KTsgfSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBMT0dPVVQg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGRvTG9nb3V0KCkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIElOSVQg4pWQ4pWQ4pWQ4pWQCmxvYWREYXNoKCk7CmxvYWRTZXJ2aWNlcygpOwpzZXRJbnRlcnZhbChsb2FkRGFzaCwgMzAwMDApOwo8L3NjcmlwdD4KCjwhLS0gU1NIIFJFTkVXIE1PREFMIC0tPgo8ZGl2IGNsYXNzPSJtb3ZlciIgaWQ9InNzaC1yZW5ldy1tb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbG9zZVNTSFJlbmV3TW9kYWwoKSI+CiAgPGRpdiBjbGFzcz0ibW9kYWwiPgogICAgPGRpdiBjbGFzcz0ibWhkciI+CiAgICAgIDxkaXYgY2xhc3M9Im10aXRsZSI+8J+UhCDguJXguYjguK3guK3guLLguKLguLggU1NIIFVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbG9zZVNTSFJlbmV3TW9kYWwoKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBVc2VybmFtZTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYgZ3JlZW4iIGlkPSJzc2gtcmVuZXctdXNlcm5hbWUiPi0tPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJmZyIgc3R5bGU9Im1hcmdpbi10b3A6MTRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4meC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLXJlbmV3LWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiIHBsYWNlaG9sZGVyPSIzMCI+CiAgICA8L2Rpdj4KICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJzc2gtcmVuZXctYnRuIiBvbmNsaWNrPSJkb1NTSFJlbmV3KCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICA8L2Rpdj4KPC9kaXY+Cgo8L2JvZHk+CjwvaHRtbD4K
HTML_BASE64_EOF

ok "Dashboard HTML อัพเดตแล้ว"

# ── STEP 3: Restart services ───────────────────────────────────
info "Restart services..."
systemctl restart chaiya-ssh-api
sleep 2
systemctl is-active --quiet chaiya-ssh-api && ok "chaiya-ssh-api ✅" || echo "⚠️ chaiya-ssh-api อาจมีปัญหา"


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
