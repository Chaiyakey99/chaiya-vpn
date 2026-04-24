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

# ── ALWAYS ASK: DOMAIN / USER / PASS ────────────────────────
UPDATE_MODE=0

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
        (8080, 'pop-AIS',  'cj-ebb.speedtest.net',           'vless',  'inbound-8080'),
        (8880, 'pop-TRUE', 'true-internet.zoom.xyz.services', 'vless',  'inbound-8880'),
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
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj4KPHRpdGxlPkNIQUlZQSBWUE4g4oCUIExvZ2luPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1PcmJpdHJvbjp3Z2h0QDcwMDs5MDAmZmFtaWx5PUthbml0OndnaHRAMzAwOzQwMDs2MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c3R5bGU+Cjpyb290IHsKICAtLW5lb246ICNjMDg0ZmM7CiAgLS1uZW9uMjogI2E4NTVmNzsKICAtLW5lb24zOiAjN2MzYWVkOwogIC0tZ2xvdzogcmdiYSgxOTIsMTMyLDI1MiwwLjM1KTsKICAtLWdsb3cyOiByZ2JhKDE2OCw4NSwyNDcsMC4xOCk7CiAgLS1iZzogIzBkMDYxNzsKICAtLWJnMjogIzEyMDgyMDsKICAtLWNhcmQ6IHJnYmEoMjU1LDI1NSwyNTUsMC4wMzUpOwogIC0tYm9yZGVyOiByZ2JhKDE5MiwxMzIsMjUyLDAuMjIpOwogIC0tdGV4dDogI2YwZTZmZjsKICAtLXN1YjogcmdiYSgyMjAsMTgwLDI1NSwwLjUpOwp9CgoqLCo6OmJlZm9yZSwqOjphZnRlciB7IGJveC1zaXppbmc6Ym9yZGVyLWJveDsgbWFyZ2luOjA7IHBhZGRpbmc6MDsgfQoKYm9keSB7CiAgbWluLWhlaWdodDogMTAwdmg7CiAgYmFja2dyb3VuZDogdmFyKC0tYmcpOwogIGZvbnQtZmFtaWx5OiAnS2FuaXQnLCBzYW5zLXNlcmlmOwogIGRpc3BsYXk6IGZsZXg7CiAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICBvdmVyZmxvdzogaGlkZGVuOwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKfQoKLyog4pSA4pSAIEJBQ0tHUk9VTkQgQkxPQlMg4pSA4pSAICovCi5ibG9iIHsKICBwb3NpdGlvbjogZml4ZWQ7CiAgYm9yZGVyLXJhZGl1czogNTAlOwogIGZpbHRlcjogYmx1cig4MHB4KTsKICBwb2ludGVyLWV2ZW50czogbm9uZTsKICB6LWluZGV4OiAwOwogIGFuaW1hdGlvbjogYmxvYkZsb2F0IDhzIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9Ci5ibG9iMSB7IHdpZHRoOjQyMHB4O2hlaWdodDo0MjBweDtiYWNrZ3JvdW5kOnJnYmEoMTI0LDU4LDIzNywuMTgpO3RvcDotODBweDtsZWZ0Oi0xMDBweDthbmltYXRpb24tZGVsYXk6MHM7IH0KLmJsb2IyIHsgd2lkdGg6MzIwcHg7aGVpZ2h0OjMyMHB4O2JhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMTIpO2JvdHRvbTotNjBweDtyaWdodDotODBweDthbmltYXRpb24tZGVsYXk6M3M7IH0KLmJsb2IzIHsgd2lkdGg6MjAwcHg7aGVpZ2h0OjIwMHB4O2JhY2tncm91bmQ6cmdiYSgxNjgsODUsMjQ3LC4xKTt0b3A6NTAlO2xlZnQ6NjAlO2FuaW1hdGlvbi1kZWxheTo1czsgfQpAa2V5ZnJhbWVzIGJsb2JGbG9hdCB7CiAgMCUsMTAwJSB7IHRyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTsgfQogIDUwJSB7IHRyYW5zZm9ybTp0cmFuc2xhdGUoMjBweCwtMjBweCkgc2NhbGUoMS4wOCk7IH0KfQoKLyog4pSA4pSAIFNUQVJTIOKUgOKUgCAqLwouc3RhcnMgeyBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MDtwb2ludGVyLWV2ZW50czpub25lOyB9Ci5zdGFyIHsKICBwb3NpdGlvbjphYnNvbHV0ZTsKICBiYWNrZ3JvdW5kOiNjMDg0ZmM7CiAgYm9yZGVyLXJhZGl1czo1MCU7CiAgYW5pbWF0aW9uOiB0d2lua2xlIHZhcigtLWQsMnMpIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9CkBrZXlmcmFtZXMgdHdpbmtsZSB7CiAgMCUsMTAwJXtvcGFjaXR5Oi4wODt0cmFuc2Zvcm06c2NhbGUoMSk7fQogIDUwJXtvcGFjaXR5Oi42O3RyYW5zZm9ybTpzY2FsZSgxLjQpO30KfQoKLyog4pSA4pSAIEdSSUQgTElORVMg4pSA4pSAICovCi5ncmlkLWJnIHsKICBwb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MDtwb2ludGVyLWV2ZW50czpub25lOwogIGJhY2tncm91bmQtaW1hZ2U6CiAgICBsaW5lYXItZ3JhZGllbnQocmdiYSgxOTIsMTMyLDI1MiwuMDQpIDFweCwgdHJhbnNwYXJlbnQgMXB4KSwKICAgIGxpbmVhci1ncmFkaWVudCg5MGRlZywgcmdiYSgxOTIsMTMyLDI1MiwuMDQpIDFweCwgdHJhbnNwYXJlbnQgMXB4KTsKICBiYWNrZ3JvdW5kLXNpemU6IDQ4cHggNDhweDsKfQoKLyog4pSA4pSAIE1BSU4gV1JBUCDilIDilIAgKi8KLndyYXAgewogIHBvc2l0aW9uOnJlbGF0aXZlO3otaW5kZXg6MTA7CiAgd2lkdGg6OTAlO21heC13aWR0aDo0MDBweDsKICBkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDowOwp9CgovKiDilIDilIAgQ0hBUkFDVEVSUyDilIDilIAgKi8KLmNoYXJzIHsKICBkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OmNlbnRlcjtnYXA6MThweDsKICBtYXJnaW4tYm90dG9tOiAtOHB4OwogIHBvc2l0aW9uOiByZWxhdGl2ZTsKICB6LWluZGV4OiAxMTsKfQoKLyogR2hvc3QgKi8KLmdob3N0IHsKICB3aWR0aDo2NHB4O2hlaWdodDo3MHB4OwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGFuaW1hdGlvbjogZ2hvc3RCb2IgMi4ycyBlYXNlLWluLW91dCBpbmZpbml0ZTsKfQouZ2hvc3QtYm9keSB7CiAgd2lkdGg6NjRweDtoZWlnaHQ6NTBweDsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCNlOGQ1ZmYsI2MwODRmYyk7CiAgYm9yZGVyLXJhZGl1czozMnB4IDMycHggMCAwOwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGJveC1zaGFkb3c6IDAgMCAxOHB4IHJnYmEoMTkyLDEzMiwyNTIsLjUpLCBpbnNldCAwIC02cHggMTJweCByZ2JhKDAsMCwwLC4xNSk7Cn0KLmdob3N0LWJvdHRvbSB7CiAgZGlzcGxheTpmbGV4OwogIHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDt3aWR0aDoxMDAlOwp9Ci5naG9zdC13YXZlIHsKICBmbGV4OjE7aGVpZ2h0OjE0cHg7CiAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2MGRlZywjZThkNWZmLCNjMDg0ZmMpOwp9Ci5naG9zdC13YXZlOm50aC1jaGlsZCgxKXsgYm9yZGVyLXJhZGl1czowIDUwJSA1MCUgMDsgfQouZ2hvc3Qtd2F2ZTpudGgtY2hpbGQoMil7IGJvcmRlci1yYWRpdXM6NTAlIDAgMCA1MCU7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDRweCk7IH0KLmdob3N0LXdhdmU6bnRoLWNoaWxkKDMpeyBib3JkZXItcmFkaXVzOjAgNTAlIDUwJSAwOyB9Ci5naG9zdC1leWVzIHsgcG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7bGVmdDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSk7ZGlzcGxheTpmbGV4O2dhcDoxMnB4OyB9Ci5naG9zdC1leWUgeyB3aWR0aDoxMHB4O2hlaWdodDoxMHB4O2JhY2tncm91bmQ6IzNiMDc2NDtib3JkZXItcmFkaXVzOjUwJTtwb3NpdGlvbjpyZWxhdGl2ZTsgfQouZ2hvc3QtZXllOjphZnRlciB7IGNvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7dG9wOjJweDtsZWZ0OjJweDt3aWR0aDo0cHg7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjQpO2JvcmRlci1yYWRpdXM6NTAlOyB9Ci5naG9zdC1ibHVzaCB7IHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbToxMnB4O2Rpc3BsYXk6ZmxleDtnYXA6MjJweDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTt3aWR0aDo1MHB4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuOyB9Ci5naG9zdC1ibHVzaCBzcGFuIHsgd2lkdGg6MTBweDtoZWlnaHQ6NnB4O2JhY2tncm91bmQ6cmdiYSgyMzYsNzIsMTUzLC4zNSk7Ym9yZGVyLXJhZGl1czo1MCU7ZGlzcGxheTpibG9jazsgfQouZ2hvc3Qtc3RhciB7CiAgcG9zaXRpb246YWJzb2x1dGU7dG9wOi04cHg7cmlnaHQ6LTRweDsKICBmb250LXNpemU6MTRweDsKICBhbmltYXRpb246IHN0YXJTcGluIDNzIGxpbmVhciBpbmZpbml0ZTsKICBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA0cHggI2MwODRmYyk7Cn0KQGtleWZyYW1lcyBnaG9zdEJvYiB7CiAgMCUsMTAwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCkgcm90YXRlKC0zZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEwcHgpIHJvdGF0ZSgzZGVnKTsgfQp9CkBrZXlmcmFtZXMgc3RhclNwaW4geyB0b3sgdHJhbnNmb3JtOnJvdGF0ZSgzNjBkZWcpOyB9IH0KCi8qIENhdCAqLwouY2F0IHsKICB3aWR0aDo1NnB4O2hlaWdodDo2OHB4OwogIHBvc2l0aW9uOnJlbGF0aXZlOwogIGFuaW1hdGlvbjogY2F0Qm9iIDEuOHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgYW5pbWF0aW9uLWRlbGF5Oi40czsKfQouY2F0LWJvZHkgewogIHdpZHRoOjU2cHg7aGVpZ2h0OjQ4cHg7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCNmNWQwZmUsI2E4NTVmNyk7CiAgYm9yZGVyLXJhZGl1czoyOHB4IDI4cHggMjJweCAyMnB4OwogIHBvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowOwogIGJveC1zaGFkb3c6MCAwIDE2cHggcmdiYSgxNjgsODUsMjQ3LC40NSk7Cn0KLmNhdC1lYXIgewogIHBvc2l0aW9uOmFic29sdXRlO3RvcDotMTRweDsKICB3aWR0aDowO2hlaWdodDowOwp9Ci5jYXQtZWFyLmxlZnQgeyBsZWZ0OjhweDsgYm9yZGVyLWxlZnQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItYm90dG9tOjIwcHggc29saWQgI2Y1ZDBmZTsgfQouY2F0LWVhci5yaWdodCB7IHJpZ2h0OjhweDsgYm9yZGVyLWxlZnQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6MTBweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItYm90dG9tOjIwcHggc29saWQgI2Y1ZDBmZTsgfQouY2F0LWVhcjo6YWZ0ZXIgeyBjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlOyB9Ci5jYXQtaW5uZXItZWFyIHsKICBwb3NpdGlvbjphYnNvbHV0ZTt0b3A6LThweDsKICB3aWR0aDowO2hlaWdodDowOwp9Ci5jYXQtaW5uZXItZWFyLmxlZnQgeyBsZWZ0OjE0cHg7IGJvcmRlci1sZWZ0OjVweCBzb2xpZCB0cmFuc3BhcmVudDtib3JkZXItcmlnaHQ6NXB4IHNvbGlkIHRyYW5zcGFyZW50O2JvcmRlci1ib3R0b206MTFweCBzb2xpZCAjZTg3OWY5OyB9Ci5jYXQtaW5uZXItZWFyLnJpZ2h0IHsgcmlnaHQ6MTRweDsgYm9yZGVyLWxlZnQ6NXB4IHNvbGlkIHRyYW5zcGFyZW50O2JvcmRlci1yaWdodDo1cHggc29saWQgdHJhbnNwYXJlbnQ7Ym9yZGVyLWJvdHRvbToxMXB4IHNvbGlkICNlODc5Zjk7IH0KLmNhdC1mYWNlIHsgcG9zaXRpb246YWJzb2x1dGU7dG9wOjEwcHg7bGVmdDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSk7d2lkdGg6NDRweDsgfQouY2F0LWV5ZXMgeyBkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWFyb3VuZDttYXJnaW4tYm90dG9tOjRweDsgfQouY2F0LWV5ZSB7IHdpZHRoOjlweDtoZWlnaHQ6OXB4O2JhY2tncm91bmQ6IzJlMTA2NTtib3JkZXItcmFkaXVzOjUwJTtwb3NpdGlvbjpyZWxhdGl2ZTsgfQouY2F0LWV5ZTo6YWZ0ZXIgeyBjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO3RvcDoycHg7bGVmdDoycHg7d2lkdGg6M3B4O2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC41KTtib3JkZXItcmFkaXVzOjUwJTsgfQouY2F0LW5vc2UgeyB3aWR0aDo2cHg7aGVpZ2h0OjVweDtiYWNrZ3JvdW5kOiNmNDcyYjY7Ym9yZGVyLXJhZGl1czo1MCU7bWFyZ2luOjAgYXV0byAycHg7IH0KLmNhdC1tb3V0aCB7IGRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoycHg7IGZvbnQtc2l6ZTo4cHg7IGNvbG9yOiM3YzNhZWQ7IH0KLmNhdC1ibHVzaCB7IGRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjAgMnB4O21hcmdpbi10b3A6MnB4OyB9Ci5jYXQtYmx1c2ggc3BhbiB7IHdpZHRoOjEwcHg7aGVpZ2h0OjZweDtiYWNrZ3JvdW5kOnJnYmEoMjQ5LDE2OCwyMTIsLjUpO2JvcmRlci1yYWRpdXM6NTAlO2Rpc3BsYXk6YmxvY2s7IH0KLmNhdC10YWlsIHsKICBwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206NHB4O3JpZ2h0Oi0xNHB4OwogIHdpZHRoOjIwcHg7aGVpZ2h0OjM2cHg7CiAgYm9yZGVyOjRweCBzb2xpZCAjYTg1NWY3OwogIGJvcmRlci1sZWZ0Om5vbmU7CiAgYm9yZGVyLXJhZGl1czowIDIwcHggMjBweCAwOwogIGFuaW1hdGlvbjp0YWlsV2FnIDFzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIHRyYW5zZm9ybS1vcmlnaW46dG9wIGxlZnQ7CiAgYm94LXNoYWRvdzowIDAgOHB4IHJnYmEoMTY4LDg1LDI0NywuNCk7Cn0KQGtleWZyYW1lcyBjYXRCb2IgewogIDAlLDEwMCV7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApIHJvdGF0ZSgyZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLThweCkgcm90YXRlKC0yZGVnKTsgfQp9CkBrZXlmcmFtZXMgdGFpbFdhZyB7CiAgMCUsMTAwJXsgdHJhbnNmb3JtOnJvdGF0ZSgtMTBkZWcpOyB9CiAgNTAleyB0cmFuc2Zvcm06cm90YXRlKDE1ZGVnKTsgfQp9CgovKiBTdGFyICovCi5zdGFyLWNoYXIgewogIHdpZHRoOjUycHg7aGVpZ2h0OjY4cHg7CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1c3RpZnktY29udGVudDpjZW50ZXI7CiAgcG9zaXRpb246cmVsYXRpdmU7CiAgYW5pbWF0aW9uOiBzdGFyQ2hhckJvYiAyLjZzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIGFuaW1hdGlvbi1kZWxheTouOHM7Cn0KLnN0YXItYm9keSB7CiAgZm9udC1zaXplOjQ2cHg7CiAgbGluZS1oZWlnaHQ6MTsKICBmaWx0ZXI6ZHJvcC1zaGFkb3coMCAwIDEycHggI2MwODRmYykgZHJvcC1zaGFkb3coMCAwIDI0cHggcmdiYSgxOTIsMTMyLDI1MiwuNCkpOwogIGFuaW1hdGlvbjogc3RhclB1bHNlIDEuNXMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgdXNlci1zZWxlY3Q6bm9uZTsKfQouc3Rhci1mYWNlIHsKICBwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MTBweDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTsKICBkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MnB4Owp9Ci5zdGFyLWV5ZXMgeyBkaXNwbGF5OmZsZXg7Z2FwOjhweDsgfQouc3Rhci1leWUyIHsgd2lkdGg6NnB4O2hlaWdodDo2cHg7YmFja2dyb3VuZDojMmUxMDY1O2JvcmRlci1yYWRpdXM6NTAlOyB9Ci5zdGFyLXNtaWxlIHsgZm9udC1zaXplOjlweDtjb2xvcjojN2MzYWVkOyB9CkBrZXlmcmFtZXMgc3RhckNoYXJCb2IgewogIDAlLDEwMCV7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApIHJvdGF0ZSg1ZGVnKTsgfQogIDUwJXsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTEycHgpIHJvdGF0ZSgtNWRlZyk7IH0KfQpAa2V5ZnJhbWVzIHN0YXJQdWxzZSB7CiAgMCUsMTAwJXsgZmlsdGVyOmRyb3Atc2hhZG93KDAgMCAxMnB4ICNjMDg0ZmMpIGRyb3Atc2hhZG93KDAgMCAyNHB4IHJnYmEoMTkyLDEzMiwyNTIsLjQpKTsgfQogIDUwJXsgZmlsdGVyOmRyb3Atc2hhZG93KDAgMCAyMHB4ICNlODc5ZjkpIGRyb3Atc2hhZG93KDAgMCAzNnB4IHJnYmEoMjMyLDEyMSwyNDksLjUpKTsgfQp9CgovKiDilIDilIAgQ0FSRCDilIDilIAgKi8KLmNhcmQgewogIGJhY2tncm91bmQ6IHZhcigtLWNhcmQpOwogIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgYm9yZGVyLXJhZGl1czogMjhweDsKICBwYWRkaW5nOiAyLjJyZW0gMnJlbSAycmVtOwogIGJhY2tkcm9wLWZpbHRlcjogYmx1cigyNHB4KTsKICBib3gtc2hhZG93OgogICAgMCAwIDAgMXB4IHJnYmEoMTkyLDEzMiwyNTIsLjA4KSwKICAgIDAgOHB4IDQwcHggcmdiYSgxMjQsNTgsMjM3LC4xOCksCiAgICBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsLjA2KTsKICBwb3NpdGlvbjpyZWxhdGl2ZTsKICBvdmVyZmxvdzpoaWRkZW47Cn0KLmNhcmQ6OmJlZm9yZSB7CiAgY29udGVudDonJzsKICBwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4OwogIGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsLjUpLHRyYW5zcGFyZW50KTsKfQouY2FyZDo6YWZ0ZXIgewogIGNvbnRlbnQ6Jyc7CiAgcG9zaXRpb246YWJzb2x1dGU7dG9wOi00MCU7bGVmdDotMjAlOwogIHdpZHRoOjE0MCU7aGVpZ2h0OjE0MCU7CiAgYmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSBhdCA1MCUgMCUscmdiYSgxOTIsMTMyLDI1MiwuMDYpIDAlLHRyYW5zcGFyZW50IDYwJSk7CiAgcG9pbnRlci1ldmVudHM6bm9uZTsKfQoKLmxvZ28tdGFnIHsKICB0ZXh0LWFsaWduOmNlbnRlcjsKICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsKICBmb250LXNpemU6LjVyZW07CiAgbGV0dGVyLXNwYWNpbmc6LjRlbTsKICBjb2xvcjp2YXIoLS1uZW9uKTsKICBvcGFjaXR5Oi42OwogIG1hcmdpbi1ib3R0b206LjRyZW07CiAgdGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlOwp9Ci50aXRsZSB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7CiAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7CiAgZm9udC1zaXplOjEuNnJlbTsKICBmb250LXdlaWdodDo5MDA7CiAgbGV0dGVyLXNwYWNpbmc6LjA2ZW07CiAgY29sb3I6dmFyKC0tdGV4dCk7CiAgbWFyZ2luLWJvdHRvbTouMnJlbTsKICB0ZXh0LXNoYWRvdzowIDAgMjBweCByZ2JhKDE5MiwxMzIsMjUyLC40KTsKfQoudGl0bGUgc3BhbiB7IGNvbG9yOnZhcigtLW5lb24pOyB9Ci5zdWJ0aXRsZSB7CiAgdGV4dC1hbGlnbjpjZW50ZXI7CiAgZm9udC1zaXplOi43MnJlbTsKICBjb2xvcjp2YXIoLS1zdWIpOwogIG1hcmdpbi1ib3R0b206MS42cmVtOwogIGxldHRlci1zcGFjaW5nOi4wNGVtOwp9CgovKiBTZXJ2ZXIgYmFkZ2UgKi8KLnNlcnZlci1iYWRnZSB7CiAgZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDouNXJlbTsKICBiYWNrZ3JvdW5kOnJnYmEoMTkyLDEzMiwyNTIsLjA3KTsKICBib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTkyLDEzMiwyNTIsLjE4KTsKICBib3JkZXItcmFkaXVzOjIwcHg7CiAgcGFkZGluZzouM3JlbSAuOXJlbTsKICBtYXJnaW4tYm90dG9tOjEuNHJlbTsKICBmb250LWZhbWlseTptb25vc3BhY2U7CiAgZm9udC1zaXplOi42OHJlbTsKICBjb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC43NSk7Cn0KLnB1bHNlLWRvdCB7CiAgd2lkdGg6NXB4O2hlaWdodDo1cHg7YmFja2dyb3VuZDp2YXIoLS1uZW9uKTtib3JkZXItcmFkaXVzOjUwJTsKICBib3gtc2hhZG93OjAgMCA0cHggdmFyKC0tbmVvbik7CiAgYW5pbWF0aW9uOnB1bHNlIDNzIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9CkBrZXlmcmFtZXMgcHVsc2UgeyAwJSwxMDAle29wYWNpdHk6MTtib3gtc2hhZG93OjAgMCAzcHggdmFyKC0tbmVvbil9NTAle29wYWNpdHk6LjQ7Ym94LXNoYWRvdzowIDAgNnB4IHZhcigtLW5lb24pfSB9CgovKiBGaWVsZHMgKi8KLmZpZWxkIHsgbWFyZ2luLWJvdHRvbToxLjFyZW07IH0KbGFiZWwgewogIGRpc3BsYXk6YmxvY2s7CiAgZm9udC1zaXplOi42MnJlbTsKICBsZXR0ZXItc3BhY2luZzouMTRlbTsKICB0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7CiAgY29sb3I6dmFyKC0tc3ViKTsKICBtYXJnaW4tYm90dG9tOi40MnJlbTsKICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsKfQouaW5wdXQtd3JhcCB7IHBvc2l0aW9uOnJlbGF0aXZlOyB9CmlucHV0IHsKICB3aWR0aDoxMDAlOwogIGJhY2tncm91bmQ6cmdiYSgxOTIsMTMyLDI1MiwuMDYpOwogIGJvcmRlcjoxLjVweCBzb2xpZCByZ2JhKDE5MiwxMzIsMjUyLC4yKTsKICBib3JkZXItcmFkaXVzOjE0cHg7CiAgcGFkZGluZzouN3JlbSAxcmVtOwogIGNvbG9yOnZhcigtLXRleHQpOwogIGZvbnQtZmFtaWx5OidLYW5pdCcsc2Fucy1zZXJpZjsKICBmb250LXNpemU6LjkycmVtOwogIG91dGxpbmU6bm9uZTsKICB0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnMsIGJveC1zaGFkb3cgLjJzLCBiYWNrZ3JvdW5kIC4yczsKfQppbnB1dDo6cGxhY2Vob2xkZXIgeyBjb2xvcjpyZ2JhKDIyMCwxODAsMjU1LC4yNSk7IH0KaW5wdXQ6Zm9jdXMgewogIGJvcmRlci1jb2xvcjpyZ2JhKDE5MiwxMzIsMjUyLC41NSk7CiAgYmFja2dyb3VuZDpyZ2JhKDE5MiwxMzIsMjUyLC4xKTsKICBib3gtc2hhZG93OjAgMCAwIDNweCByZ2JhKDE5MiwxMzIsMjUyLC4xKSwgMCAwIDE2cHggcmdiYSgxOTIsMTMyLDI1MiwuMTIpOwp9Ci5leWUtYnRuIHsKICBwb3NpdGlvbjphYnNvbHV0ZTtyaWdodDouNzVyZW07dG9wOjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtNTAlKTsKICBiYWNrZ3JvdW5kOm5vbmU7Ym9yZGVyOm5vbmU7Y29sb3I6cmdiYSgyMjAsMTgwLDI1NSwuNCk7CiAgY3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjFyZW07cGFkZGluZzouMnJlbTsKICB0cmFuc2l0aW9uOmNvbG9yIC4yczsKfQouZXllLWJ0bjpob3ZlciB7IGNvbG9yOnZhcigtLW5lb24pOyB9CgovKiBCdXR0b24gKi8KLmxvZ2luLWJ0biB7CiAgd2lkdGg6MTAwJTtwYWRkaW5nOi44OHJlbTtib3JkZXI6bm9uZTtib3JkZXItcmFkaXVzOjE0cHg7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCM3YzNhZWQsI2E4NTVmNywjYzA4NGZjKTsKICBjb2xvcjojZmZmOwogIGZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOwogIGZvbnQtc2l6ZTouODhyZW07CiAgZm9udC13ZWlnaHQ6NzAwOwogIGxldHRlci1zcGFjaW5nOi4xMmVtOwogIGN1cnNvcjpwb2ludGVyOwogIG1hcmdpbi10b3A6LjVyZW07CiAgdHJhbnNpdGlvbjphbGwgLjI1czsKICBwb3NpdGlvbjpyZWxhdGl2ZTsKICBvdmVyZmxvdzpoaWRkZW47CiAgYm94LXNoYWRvdzowIDRweCAyMHB4IHJnYmEoMTI0LDU4LDIzNywuNCksMCAwIDAgMXB4IHJnYmEoMTkyLDEzMiwyNTIsLjIpOwp9Ci5sb2dpbi1idG46OmJlZm9yZSB7CiAgY29udGVudDonJzsKICBwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowOwogIGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZyxyZ2JhKDI1NSwyNTUsMjU1LC4xMiksdHJhbnNwYXJlbnQpOwogIG9wYWNpdHk6MDt0cmFuc2l0aW9uOm9wYWNpdHkgLjJzOwp9Ci5sb2dpbi1idG46aG92ZXI6bm90KDpkaXNhYmxlZCkgewogIGJveC1zaGFkb3c6MCA2cHggMjhweCByZ2JhKDEyNCw1OCwyMzcsLjU1KSwgMCAwIDMycHggcmdiYSgxOTIsMTMyLDI1MiwuMjUpOwogIHRyYW5zZm9ybTp0cmFuc2xhdGVZKC0xcHgpOwp9Ci5sb2dpbi1idG46aG92ZXI6bm90KDpkaXNhYmxlZCk6OmJlZm9yZSB7IG9wYWNpdHk6MTsgfQoubG9naW4tYnRuOmFjdGl2ZTpub3QoOmRpc2FibGVkKSB7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKDApOyB9Ci5sb2dpbi1idG46ZGlzYWJsZWQgeyBvcGFjaXR5Oi41O2N1cnNvcjpub3QtYWxsb3dlZDsgfQoKLyogU3Bpbm5lciAqLwouc3Bpbm5lciB7CiAgZGlzcGxheTppbmxpbmUtYmxvY2s7d2lkdGg6MTRweDtoZWlnaHQ6MTRweDsKICBib3JkZXI6MnB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjMpOwogIGJvcmRlci10b3AtY29sb3I6I2ZmZjsKICBib3JkZXItcmFkaXVzOjUwJTsKICBhbmltYXRpb246c3BpbiAuN3MgbGluZWFyIGluZmluaXRlOwogIHZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6LjRyZW07Cn0KQGtleWZyYW1lcyBzcGluIHsgdG97dHJhbnNmb3JtOnJvdGF0ZSgzNjBkZWcpfSB9CgovKiBBbGVydCAqLwouYWxlcnQgewogIGRpc3BsYXk6bm9uZTttYXJnaW4tdG9wOi44cmVtOwogIHBhZGRpbmc6LjY1cmVtIC45cmVtO2JvcmRlci1yYWRpdXM6MTBweDsKICBmb250LXNpemU6LjhyZW07bGluZS1oZWlnaHQ6MS41Owp9Ci5hbGVydC5vayB7IGJhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiM0YWRlODA7IH0KLmFsZXJ0LmVyciB7IGJhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsLjA4KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4yNSk7Y29sb3I6I2Y4NzE3MTsgfQoKLyogRm9vdGVyICovCi5mb290ZXIgewogIHRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MS40cmVtOwogIGZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXNpemU6LjZyZW07CiAgY29sb3I6cmdiYSgxOTIsMTMyLDI1MiwuMjUpO2xldHRlci1zcGFjaW5nOi4wNmVtOwp9CgovKiBOZW9uIGxpbmVzIGRlY28gKi8KLm5lb24tbGluZSB7CiAgcG9zaXRpb246YWJzb2x1dGU7CiAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdHJhbnNwYXJlbnQsdmFyKC0tbmVvbiksdHJhbnNwYXJlbnQpOwogIGhlaWdodDoxcHg7b3BhY2l0eTouMTU7CiAgYW5pbWF0aW9uOmxpbmVNb3ZlIDRzIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9Ci5uZW9uLWxpbmU6bnRoLWNoaWxkKDEpeyB0b3A6MzAlO3dpZHRoOjEwMCU7bGVmdDowO2FuaW1hdGlvbi1kZWxheTowczsgfQoubmVvbi1saW5lOm50aC1jaGlsZCgyKXsgdG9wOjcwJTt3aWR0aDo2MCU7bGVmdDoyMCU7YW5pbWF0aW9uLWRlbGF5OjJzOyB9CkBrZXlmcmFtZXMgbGluZU1vdmUgewogIDAlLDEwMCV7b3BhY2l0eTouMDg7fQogIDUwJXtvcGFjaXR5Oi4yNTt9Cn0KCi8qIOKUgOKUgCBGTE9BVElORyBTUEFSS0xFUyDilIDilIAgKi8KLnNwYXJrbGVzIHsgcG9zaXRpb246Zml4ZWQ7aW5zZXQ6MDtwb2ludGVyLWV2ZW50czpub25lO3otaW5kZXg6MTsgfQouc3AgewogIHBvc2l0aW9uOmFic29sdXRlOwogIHdpZHRoOjRweDtoZWlnaHQ6NHB4OwogIGJhY2tncm91bmQ6dmFyKC0tbmVvbik7CiAgYm9yZGVyLXJhZGl1czo1MCU7CiAgYm94LXNoYWRvdzowIDAgNnB4IHZhcigtLW5lb24pOwogIGFuaW1hdGlvbjpzcEZsb2F0IHZhcigtLXNkLDZzKSBlYXNlLWluLW91dCBpbmZpbml0ZTsKICBvcGFjaXR5OjA7Cn0KQGtleWZyYW1lcyBzcEZsb2F0IHsKICAwJXsgb3BhY2l0eTowO3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApIHNjYWxlKDApOyB9CiAgMjAleyBvcGFjaXR5Oi43O3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0yMHB4KSBzY2FsZSgxKTsgfQogIDgwJXsgb3BhY2l0eTouNDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtODBweCkgc2NhbGUoLjYpOyB9CiAgMTAwJXsgb3BhY2l0eTowO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0xMjBweCkgc2NhbGUoMCk7IH0KfQo8L3N0eWxlPgo8L2hlYWQ+Cjxib2R5PgoKPCEtLSBCYWNrZ3JvdW5kIC0tPgo8ZGl2IGNsYXNzPSJncmlkLWJnIj48L2Rpdj4KPGRpdiBjbGFzcz0iYmxvYiBibG9iMSI+PC9kaXY+CjxkaXYgY2xhc3M9ImJsb2IgYmxvYjIiPjwvZGl2Pgo8ZGl2IGNsYXNzPSJibG9iIGJsb2IzIj48L2Rpdj4KPGRpdiBjbGFzcz0ic3RhcnMiIGlkPSJzdGFycyI+PC9kaXY+CjxkaXYgY2xhc3M9InNwYXJrbGVzIiBpZD0ic3BhcmtsZXMiPjwvZGl2PgoKPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gQ2hhcmFjdGVycyAtLT4KICA8ZGl2IGNsYXNzPSJjaGFycyI+CgogICAgPCEtLSBHaG9zdCAtLT4KICAgIDxkaXYgY2xhc3M9Imdob3N0Ij4KICAgICAgPGRpdiBjbGFzcz0iZ2hvc3Qtc3RhciI+4pymPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Imdob3N0LWJvZHkiPgogICAgICAgIDxkaXYgY2xhc3M9Imdob3N0LWV5ZXMiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtZXllIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Imdob3N0LWV5ZSI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3QtYmx1c2giPgogICAgICAgICAgPHNwYW4+PC9zcGFuPjxzcGFuPjwvc3Bhbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC1ib3R0b20iPgogICAgICAgICAgPGRpdiBjbGFzcz0iZ2hvc3Qtd2F2ZSI+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJnaG9zdC13YXZlIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Imdob3N0LXdhdmUiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU3RhciBjaGFyIC0tPgogICAgPGRpdiBjbGFzcz0ic3Rhci1jaGFyIj4KICAgICAgPGRpdiBjbGFzcz0ic3Rhci1ib2R5Ij7irZA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3Rhci1mYWNlIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdGFyLWV5ZXMiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3Rhci1leWUyIj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0YXItZXllMiI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3Rhci1zbWlsZSI+4pehPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBDYXQgLS0+CiAgICA8ZGl2IGNsYXNzPSJjYXQiPgogICAgICA8ZGl2IGNsYXNzPSJjYXQtZWFyIGxlZnQiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXQtZWFyIHJpZ2h0Ij48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2F0LWlubmVyLWVhciBsZWZ0Ij48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2F0LWlubmVyLWVhciByaWdodCI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhdC1ib2R5Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJjYXQtZmFjZSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJjYXQtZXllcyI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImNhdC1leWUiPjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJjYXQtZXllIj48L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iY2F0LW5vc2UiPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0iY2F0LW1vdXRoIj48c3Bhbj7PiTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImNhdC1ibHVzaCI+CiAgICAgICAgICAgIDxzcGFuPjwvc3Bhbj48c3Bhbj48L3NwYW4+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhdC10YWlsIj48L2Rpdj4KICAgIDwvZGl2PgoKICA8L2Rpdj4KCiAgPCEtLSBDYXJkIC0tPgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGRpdiBjbGFzcz0ibmVvbi1saW5lIj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5lb24tbGluZSI+PC9kaXY+CgogICAgPGRpdiBjbGFzcz0ibG9nby10YWciPuKcpiBDSEFJWUEgVjJSQVkgUFJPIE1BWCDinKY8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InRpdGxlIj5BRE1JTiA8c3Bhbj5QQU5FTDwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9InN1YnRpdGxlIj54LXVpIE1hbmFnZW1lbnQgRGFzaGJvYXJkPC9kaXY+CgogICAgPGRpdiBjbGFzcz0ic2VydmVyLWJhZGdlIj4KICAgICAgPHNwYW4gY2xhc3M9InB1bHNlLWRvdCI+PC9zcGFuPgogICAgICA8c3BhbiBpZD0ic2VydmVyLWhvc3QiPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvc3Bhbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpZWxkIj4KICAgICAgPGxhYmVsPvCfkaQgVXNlcm5hbWU8L2xhYmVsPgogICAgICA8aW5wdXQgdHlwZT0idGV4dCIgaWQ9ImlucC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiIGF1dG9jb21wbGV0ZT0idXNlcm5hbWUiPgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICA8bGFiZWw+8J+UkSBQYXNzd29yZDwvbGFiZWw+CiAgICAgIDxkaXYgY2xhc3M9ImlucHV0LXdyYXAiPgogICAgICAgIDxpbnB1dCB0eXBlPSJwYXNzd29yZCIgaWQ9ImlucC1wYXNzIiBwbGFjZWhvbGRlcj0i4oCi4oCi4oCi4oCi4oCi4oCi4oCi4oCiIiBhdXRvY29tcGxldGU9ImN1cnJlbnQtcGFzc3dvcmQiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImV5ZS1idG4iIGlkPSJleWUtYnRuIiBvbmNsaWNrPSJ0b2dnbGVFeWUoKSIgdHlwZT0iYnV0dG9uIj7wn5GBPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGJ1dHRvbiBjbGFzcz0ibG9naW4tYnRuIiBpZD0ibG9naW4tYnRuIiBvbmNsaWNrPSJkb0xvZ2luKCkiPgogICAgICDinKYgJm5ic3A74LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4LiaCiAgICA8L2J1dHRvbj4KCiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImFsZXJ0Ij48L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmb290ZXIiIGlkPSJmb290ZXItdGltZSI+PC9kaXY+CiAgPC9kaXY+Cgo8L2Rpdj4KCjxzY3JpcHQgc3JjPSJjb25maWcuanMiIG9uZXJyb3I9IndpbmRvdy5DSEFJWUFfQ09ORklHPXt9Ij48L3NjcmlwdD4KPHNjcmlwdD4KY29uc3QgQ0ZHID0gKHR5cGVvZiB3aW5kb3cuQ0hBSVlBX0NPTkZJRyAhPT0gJ3VuZGVmaW5lZCcpID8gd2luZG93LkNIQUlZQV9DT05GSUcgOiB7fTsKY29uc3QgWFVJX0FQSSA9ICcveHVpLWFwaSc7CmNvbnN0IFNFU1NJT05fS0VZID0gJ2NoYWl5YV9hdXRoJzsKY29uc3QgREFTSEJPQVJEID0gQ0ZHLmRhc2hib2FyZF91cmwgfHwgJ3NzaHdzLmh0bWwnOwoKLy8gU2VydmVyIGhvc3QKZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NlcnZlci1ob3N0JykudGV4dENvbnRlbnQgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKaWYgKENGRy54dWlfdXNlcikgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2lucC11c2VyJykudmFsdWUgPSBDRkcueHVpX3VzZXI7CgovLyBDbG9jawpmdW5jdGlvbiB1cGRhdGVDbG9jaygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9vdGVyLXRpbWUnKS50ZXh0Q29udGVudCA9CiAgICBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKSArICcg4pymIENIQUlZQSBWUE4gU1lTVEVNIOKcpiB2NS4wJzsKfQp1cGRhdGVDbG9jaygpOyBzZXRJbnRlcnZhbCh1cGRhdGVDbG9jaywgMTAwMCk7CgovLyBFbnRlciBrZXkKZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigna2V5ZG93bicsIGUgPT4geyBpZiAoZS5rZXkgPT09ICdFbnRlcicpIGRvTG9naW4oKTsgfSk7CgpsZXQgZXllT3BlbiA9IGZhbHNlOwpmdW5jdGlvbiB0b2dnbGVFeWUoKSB7CiAgZXllT3BlbiA9ICFleWVPcGVuOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbnAtcGFzcycpLnR5cGUgPSBleWVPcGVuID8gJ3RleHQnIDogJ3Bhc3N3b3JkJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZXllLWJ0bicpLnRleHRDb250ZW50ID0gZXllT3BlbiA/ICfwn5mIJyA6ICfwn5GBJzsKfQoKZnVuY3Rpb24gc2hvd0FsZXJ0KG1zZywgdHlwZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FsZXJ0Jyk7CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcgKyB0eXBlOwogIGVsLnRleHRDb250ZW50ID0gbXNnOwogIGVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwp9Cgphc3luYyBmdW5jdGlvbiBkb0xvZ2luKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaW5wLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdpbnAtcGFzcycpLnZhbHVlOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywgJ2VycicpOwogIGlmICghcGFzcykgcmV0dXJuIHNob3dBbGVydCgn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3JkJywgJ2VycicpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2dpbi1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOwogIGJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW5uZXIiPjwvc3Bhbj4g4LiB4Liz4Lil4Lix4LiH4LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4LiaLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWxlcnQnKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIHRyeSB7CiAgICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiB1c2VyLCBwYXNzd29yZDogcGFzcyB9KTsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IFByb21pc2UucmFjZShbCiAgICAgIGZldGNoKFhVSV9BUEkgKyAnL2xvZ2luJywgewogICAgICAgIG1ldGhvZDogJ1BPU1QnLCBjcmVkZW50aWFsczogJ2luY2x1ZGUnLAogICAgICAgIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQnIH0sCiAgICAgICAgYm9keTogZm9ybS50b1N0cmluZygpCiAgICAgIH0pLAogICAgICBuZXcgUHJvbWlzZSgoXyxyZWopID0+IHNldFRpbWVvdXQoKCkgPT4gcmVqKG5ldyBFcnJvcignVGltZW91dCcpKSwgODAwMCkpCiAgICBdKTsKICAgIGNvbnN0IGRhdGEgPSBhd2FpdCByZXMuanNvbigpOwogICAgaWYgKGRhdGEuc3VjY2VzcykgewogICAgICBzZXNzaW9uU3RvcmFnZS5zZXRJdGVtKFNFU1NJT05fS0VZLCBKU09OLnN0cmluZ2lmeSh7IHVzZXIsIHBhc3MsIGV4cDogRGF0ZS5ub3coKSArIDgqMzYwMCoxMDAwIH0pKTsKICAgICAgc2hvd0FsZXJ0KCfinIUg4LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4Lia4Liq4Liz4LmA4Lij4LmH4LiIIOC4geC4s+C4peC4seC4hyByZWRpcmVjdC4uLicsICdvaycpOwogICAgICBzZXRUaW1lb3V0KCgpID0+IHsgd2luZG93LmxvY2F0aW9uLnJlcGxhY2UoREFTSEJPQVJEKTsgfSwgODAwKTsKICAgIH0gZWxzZSB7CiAgICAgIHNob3dBbGVydCgn4p2MIFVzZXJuYW1lIOC4q+C4o+C4t+C4rSBQYXNzd29yZCDguYTguKHguYjguJbguLnguIHguJXguYnguK3guIcnLCAnZXJyJyk7CiAgICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogICAgICBidG4uaW5uZXJIVE1MID0gJ+KcpiAmbmJzcDvguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJonOwogICAgfQogIH0gY2F0Y2goZSkgewogICAgc2hvd0FsZXJ0KCfinYwgJyArIGUubWVzc2FnZSwgJ2VycicpOwogICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICBidG4uaW5uZXJIVE1MID0gJ+KcpiAmbmJzcDvguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJonOwogIH0KfQoKLy8g4pSA4pSAIFNUQVJTIOKUgOKUgApjb25zdCBzdGFyc0VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0YXJzJyk7CmZvciAobGV0IGkgPSAwOyBpIDwgNjA7IGkrKykgewogIGNvbnN0IHMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICBzLmNsYXNzTmFtZSA9ICdzdGFyJzsKICBjb25zdCBzaXplID0gTWF0aC5yYW5kb20oKSAqIDIuNSArIC41OwogIHMuc3R5bGUuY3NzVGV4dCA9IGAKICAgIHdpZHRoOiR7c2l6ZX1weDtoZWlnaHQ6JHtzaXplfXB4OwogICAgbGVmdDoke01hdGgucmFuZG9tKCkqMTAwfSU7dG9wOiR7TWF0aC5yYW5kb20oKSoxMDB9JTsKICAgIC0tZDokeyhNYXRoLnJhbmRvbSgpKjMrMS41KS50b0ZpeGVkKDEpfXM7CiAgICBhbmltYXRpb24tZGVsYXk6JHsoTWF0aC5yYW5kb20oKSo0KS50b0ZpeGVkKDEpfXM7CiAgICBvcGFjaXR5OiR7KE1hdGgucmFuZG9tKCkqLjQrLjA1KS50b0ZpeGVkKDIpfTsKICBgOwogIHN0YXJzRWwuYXBwZW5kQ2hpbGQocyk7Cn0KCi8vIOKUgOKUgCBTUEFSS0xFUyDilIDilIAKY29uc3Qgc3BFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGFya2xlcycpOwpmb3IgKGxldCBpID0gMDsgaSA8IDIwOyBpKyspIHsKICBjb25zdCBzcCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogIHNwLmNsYXNzTmFtZSA9ICdzcCc7CiAgc3Auc3R5bGUuY3NzVGV4dCA9IGAKICAgIGxlZnQ6JHtNYXRoLnJhbmRvbSgpKjEwMH0lOwogICAgdG9wOiR7KE1hdGgucmFuZG9tKCkqNDArNDApfSU7CiAgICAtLXNkOiR7KE1hdGgucmFuZG9tKCkqNSs0KS50b0ZpeGVkKDEpfXM7CiAgICBhbmltYXRpb24tZGVsYXk6JHsoTWF0aC5yYW5kb20oKSo2KS50b0ZpeGVkKDEpfXM7CiAgICB3aWR0aDoke01hdGgucmFuZG9tKCkqNCsyfXB4O2hlaWdodDoke01hdGgucmFuZG9tKCkqNCsyfXB4OwogIGA7CiAgc3BFbC5hcHBlbmRDaGlsZChzcCk7Cn0KCi8vIOKUgOKUgCBDaGFyYWN0ZXIgd2lnZ2xlIG9uIGhvdmVyIOKUgOKUgApkb2N1bWVudC5xdWVyeVNlbGVjdG9yKCcuY2FyZCcpLmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlZW50ZXInLCAoKSA9PiB7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmdob3N0LC5jYXQsLnN0YXItY2hhcicpLmZvckVhY2goZWwgPT4gewogICAgZWwuc3R5bGUuYW5pbWF0aW9uUGxheVN0YXRlID0gJ3J1bm5pbmcnOwogIH0pOwp9KTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMxYTBhMmUgMCUsIzBmMGExZSA1NSUsIzBhMGEwZiAxMDAlKTtwYWRkaW5nOjI4cHggMjBweCAyMnB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tncm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo1cHg7aGVpZ2h0OjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCAzcHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQogIC5kb3QucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgQGtleWZyYW1lcyBwbHN7MCUsMTAwJXtvcGFjaXR5Oi45O2JveC1zaGFkb3c6MCAwIDJweCB2YXIoLS1uZyl9NTAle29wYWNpdHk6LjY7Ym94LXNoYWRvdzowIDAgNHB4IHZhcigtLW5nKX19CiAgLnh1aS1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC54dWktaW5mb3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS43O30KICAueHVpLWluZm8gYntjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLWxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O21hcmdpbi10b3A6MTBweDt9CiAgLnN2Y3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMDUpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMXB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjt9CiAgLnN2Yy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4wNSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMik7fQogIC5zdmMtbHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O30KICAuZGd7d2lkdGg6NnB4O2hlaWdodDo2cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94LXNoYWRvdzowIDAgM3B4IHZhcigtLW5nKTtmbGV4LXNocmluazowO30KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4OjEwMDtkaXNwbGF5Om5vbmU7YWxpZ24taXRlbXM6ZmxleC1lbmQ7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLm1vdmVyLm9wZW57ZGlzcGxheTpmbGV4O30KICAubW9kYWx7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjIwcHggMjBweCAwIDA7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDgwcHg7cGFkZGluZzoyMHB4O21heC1oZWlnaHQ6ODV2aDtvdmVyZmxvdy15OmF1dG87YW5pbWF0aW9uOnN1IC4zcyBlYXNlO2JveC1zaGFkb3c6MCAtNHB4IDMwcHggcmdiYSgwLDAsMCwwLjEyKTt9CiAgQGtleWZyYW1lcyBzdXtmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVZKDEwMCUpfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAubWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206MTZweDt9CiAgLm10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS10eHQpO30KICAubWNsb3Nle3dpZHRoOjMycHg7aGVpZ2h0OjMycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAuZGdyaWR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLWJvdHRvbToxNHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRye2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo3cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHI6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5ka3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5kdntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmR2LmdyZWVue2NvbG9yOnZhcigtLW5nKTt9CiAgLmR2LnJlZHtjb2xvcjojZWY0NDQ0O30KICAuZHYubW9ub3tjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDt9CiAgLmFncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O30KICAubS1zdWJ7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTRweDtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHg7fQogIC5tLXN1Yi5vcGVue2Rpc3BsYXk6YmxvY2s7YW5pbWF0aW9uOmZpIC4ycyBlYXNlO30KICAubXN1Yi1sYmx7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuYWJ0bntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHggMTBweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5hYnRuOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAuYWJ0biAuYWl7Zm9udC1zaXplOjIycHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5hYnRuIC5hbntmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLmFidG4gLmFke2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5yZXMtYm94e3Bvc2l0aW9uOnJlbGF0aXZlO2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tdG9wOjE0cHg7ZGlzcGxheTpub25lO30KICAucmVzLWJveC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5yZXMtY2xvc2V7cG9zaXRpb246YWJzb2x1dGU7dG9wOi0xMXB4O3JpZ2h0Oi0xMXB4O3dpZHRoOjIycHg7aGVpZ2h0OjIycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2JvcmRlcjoycHggc29saWQgI2ZmZjtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bGluZS1oZWlnaHQ6MTtib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDIzOSw2OCw2OCwwLjQpO3otaW5kZXg6Mjt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gSEVBREVSIC0tPgogIDxkaXYgY2xhc3M9ImhkciI+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiPuKGqSDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KICAgIDxkaXYgY2xhc3M9Imhkci1zdWIiPkNIQUlZQSBWMlJBWSBQUk8gTUFYPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJoZHItdGl0bGUiPlVTRVIgPHNwYW4+Q1JFQVRPUjwvc3Bhbj48L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imhkci1kZXNjIiBpZD0iaGRyLWRvbWFpbiI+djUgwrcgU0VDVVJFIFBBTkVMPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gTkFWIC0tPgogIDxkaXYgY2xhc3M9Im5hdiI+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSBhY3RpdmUiIG9uY2xpY2s9InN3KCdkYXNoYm9hcmQnLHRoaXMpIj7wn5OKIOC5geC4lOC4iuC4muC4reC4o+C5jOC4lDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdjcmVhdGUnLHRoaXMpIj7inpUg4Liq4Lij4LmJ4Liy4LiH4Lii4Li54LiqPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ21hbmFnZScsdGhpcykiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54LiqPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ29ubGluZScsdGhpcykiPvCfn6Ig4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2JhbicsdGhpcykiPvCfmqsg4Lib4Lil4LiU4LmB4Lia4LiZPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIgaWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFuIGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7imqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9udC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGltZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJvdyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3guKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAgICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklDRSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2ltZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgtQUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlzLm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWlnaHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdTIMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBXUyDCtyB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KCiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCIgc3R5bGU9Im1hcmdpbi10b3A6MjBweCI+8J+UkSDguKPguLDguJrguJogU1NIIFdFQlNPQ0tFVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3NzaCcpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtc3NoIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6I2ZmZjtmb250LWZhbWlseTptb25vc3BhY2UiPlNTSCZndDs8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgc3NoIj5TU0gg4oCTIFdTIFR1bm5lbDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+U1NIIMK3IFBvcnQgODAgwrcgRHJvcGJlYXIgMTQzLzEwOTxicj5OcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IEFJUyDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLWFpcyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgYWlzLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWxvZ28gc2VsLWFpcy1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouOHJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgU05JOiBjai1lYmIuc3BlZWR0ZXN0Lm5ldDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckBhaXMiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLWFpcyIgaWQ9ImFpcy1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCdhaXMnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0iYWlzLXJlc3VsdCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtcmVzdWx0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSciPuKclTwvYnV0dG9uPgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OnIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiIgaWQ9InItYWlzLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici1haXMtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItYWlzLWV4cCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtbGluayIgaWQ9InItYWlzLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItYWlzLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0iYWlzLXFyIiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLXRvcDoxMnB4OyI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogVFJVRSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXRydWUiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0taGRyIHRydWUtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlLXNtIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tdGl0bGUgdHJ1ZSI+VFJVRSDigJMgVkRPPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDg4ODAgwrcgU05JOiB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckB0cnVlIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+ThSDguKfguLHguJnguYPguIrguYnguIfguLLguJkgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4gY2J0bi10cnVlIiBpZD0idHJ1ZS1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCd0cnVlJykiPuKaoSDguKrguKPguYnguLLguIcgVFJVRSBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJ0cnVlLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0idHJ1ZS1yZXN1bHQiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0icmVzLWNsb3NlIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndHJ1ZS1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici10cnVlLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici10cnVlLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLXRydWUtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici10cnVlLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItdHJ1ZS1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9InRydWUtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBTU0gg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1zc2giIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNzaC1kYXJrLWZvcm0iPgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7inpUg4LmA4Lie4Li04LmI4LihIFNTSCBVU0VSPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1wYXNzIiBwbGFjZWhvbGRlcj0icGFzc3dvcmQiIHR5cGU9InBhc3N3b3JkIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lil4Li04Lih4Li04LiV4LmE4Lit4Lie4Li1PC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+4pyI77iPIOC5gOC4peC4t+C4reC4gSBQT1JUPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIGFjdGl2ZS1wODAiIGlkPSJwYi04MCIgb25jbGljaz0icGlja1BvcnQoJzgwJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn4yQPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgODA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XUyDCtyBIVFRQPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIiBpZD0icGItNDQzIiBvbmNsaWNrPSJwaWNrUG9ydCgnNDQzJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn5SSPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgNDQzPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLXN1YiI+V1NTIMK3IFNTTDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn4yQIOC5gOC4peC4t+C4reC4gSBJU1AgLyBPUEVSQVRPUjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBpY2stZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCBhLWR0YWMiIGlkPSJwcm8tZHRhYyIgb25jbGljaz0icGlja1BybygnZHRhYycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCfn6A8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRUQUMgR0FNSU5HPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5kbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0icHJvLXRydWUiIG9uY2xpY2s9InBpY2tQcm8oJ3RydWUnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj7wn5S1PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5UUlVFIFRXSVRURVI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmhlbHAueC5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCI+8J+TsSDguYDguKXguLfguK3guIEgQVBQPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtbnB2IiBpZD0iYXBwLW5wdiIgb25jbGljaz0icGlja0FwcCgnbnB2JykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+PGRpdiBzdHlsZT0id2lkdGg6MzhweDtoZWlnaHQ6MzhweDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMGQyYTNhO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjttYXJnaW46MCBhdXRvIC4xcmVtO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi44NXJlbTtjb2xvcjojMDBjY2ZmO2xldHRlci1zcGFjaW5nOi0xcHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMCwyMDQsMjU1LC4zKSI+blY8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPk5wdiBUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPm5wdnQtc3NoOi8vPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0iYXBwLWRhcmsiIG9uY2xpY2s9InBpY2tBcHAoJ2RhcmsnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMxMTE7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6c2Fucy1zZXJpZjtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi42MnJlbTtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOi41cHg7Ym9yZGVyOjEuNXB4IHNvbGlkICM0NDQiPkRBUks8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRhcmtUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRhcmt0dW5uZWw6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuLXNzaCIgaWQ9InNzaC1idG4iIG9uY2xpY2s9ImNyZWF0ZVNTSCgpIj7inpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXI8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InNzaC1hbGVydCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibGluay1yZXN1bHQiIGlkPSJzc2gtbGluay1yZXN1bHQiPjwvZGl2PgogICAgICA8L2Rpdj4KCiAgICAgIDwhLS0gVXNlciB0YWJsZSAtLT4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbjowIj7wn5OLIOC4o+C4suC4ouC4iuC4t+C5iOC4rSBVU0VSUzwvZGl2PgogICAgICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0ic3NoLXNlYXJjaCIgcGxhY2Vob2xkZXI9IuC4hOC5ieC4meC4q+C4si4uLiIgb25pbnB1dD0iZmlsdGVyU1NIVXNlcnModGhpcy52YWx1ZSkiCiAgICAgICAgICAgIHN0eWxlPSJ3aWR0aDoxMjBweDttYXJnaW46MDtmb250LXNpemU6MTFweDtwYWRkaW5nOjZweCAxMHB4Ij4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1dGJsLXdyYXAiPgogICAgICAgICAgPHRhYmxlIGNsYXNzPSJ1dGJsIj4KICAgICAgICAgICAgPHRoZWFkPjx0cj48dGg+IzwvdGg+PHRoPlVTRVJOQU1FPC90aD48dGg+4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC90aD48dGg+4Liq4LiW4Liy4LiZ4LiwPC90aD48dGg+QUNUSU9OPC90aD48L3RyPjwvdGhlYWQ+CiAgICAgICAgICAgIDx0Ym9keSBpZD0ic3NoLXVzZXItdGJvZHkiPjx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MjBweDtjb2xvcjp2YXIoLS1tdXRlZCkiPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvdGQ+PC90cj48L3Rib2R5PgogICAgICAgICAgPC90YWJsZT4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgPC9kaXY+PCEtLSAvdGFiLWNyZWF0ZSAtLT4KCjwhLS0g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW1hbmFnZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4quC5gOC4i+C4reC4o+C5jCBWTEVTUzwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkVXNlcnMoKSI+4oa7IOC5guC4q+C4peC4lDwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0idXNlci1zZWFyY2giIHBsYWNlaG9sZGVyPSLwn5SNICDguITguYnguJnguKvguLIgdXNlcm5hbWUuLi4iIG9uaW5wdXQ9ImZpbHRlclVzZXJzKHRoaXMudmFsdWUpIj4KICAgICAgPGRpdiBpZD0idXNlci1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguJvguLjguYjguKHguYLguKvguKXguJTguYDguJ7guLfguYjguK3guJTguLbguIfguILguYnguK3guKHguLnguKU8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1vbmxpbmUiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+8J+foiDguKLguLnguKrguYDguIvguK3guKPguYzguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZE9ubGluZSgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvY3IiPgogICAgICAgIDxkaXYgY2xhc3M9Im9waWxsIiBpZD0ib25saW5lLXBpbGwiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj48c3BhbiBpZD0ib25saW5lLWNvdW50Ij4wPC9zcGFuPiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0idXQiIGlkPSJvbmxpbmUtdGltZSI+LS08L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4LiU4Lij4Li14LmA4Lif4Lij4LiK4LmA4Lie4Li34LmI4Lit4LiU4Li54Lic4Li54LmJ4LmD4LiK4LmJ4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQkFOIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItYmFuIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiPvCfmqsg4LiI4Lix4LiU4LiB4Liy4LijIFNTSCBVc2VyczwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBVU0VSTkFNRTwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJiYW4tdXNlciIgcGxhY2Vob2xkZXI9IuC5g+C4quC5iCB1c2VybmFtZSDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguKXguJoiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNTgwM2QsIzIyYzU1ZSkiIG9uY2xpY2s9ImRlbGV0ZVNTSCgpIj7wn5eR77iPIOC4peC4miBTU0ggVXNlcjwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImJhbi1hbGVydCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+TiyBTU0ggVXNlcnMg4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgaWQ9InNzaC11c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+Cgo8L2Rpdj48IS0tIC93cmFwIC0tPgoKPCEtLSBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJtb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbSgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIiBpZD0ibXQiPuKame+4jyB1c2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY20oKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6EgUG9ydDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkcCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9ImRlIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TpiBEYXRhIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TiiBUcmFmZmljIOC5g+C4iuC5iTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdHIiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OxIElQIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRpIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBtb25vIiBpZD0iZHV1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTBweCI+4LmA4Lil4Li34Lit4LiB4LiB4Liy4Lij4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3JlbmV3JykiPjxkaXYgY2xhc3M9ImFpIj7wn5SEPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignZXh0ZW5kJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OFPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignYWRkZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+8J+TpjwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guYDguJ7guLTguYjguKEgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4LihPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3NldGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPuKalu+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguLHguYnguIcgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guIHguLPguKvguJnguJTguYPguKvguKHguYg8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVzZXQnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIM8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4gZGFuZ2VyIiBvbmNsaWNrPSJtQWN0aW9uKCdkZWxldGUnKSI+PGRpdiBjbGFzcz0iYWkiPvCfl5HvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lil4Lia4Lii4Li54LiqPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4peC4muC4luC4suC4p+C4ozwvZGl2PjwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC5iOC4reC4reC4suC4ouC4uCAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZW5ldyI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCDigJQg4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVuZXctYnRuIiBvbmNsaWNrPSJkb1JlbmV3VXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWV4dGVuZCI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OFIOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSDigJQg4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1leHRlbmQtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWV4dGVuZC1idG4iIG9uY2xpY2s9ImRvRXh0ZW5kVXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4LihIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItYWRkZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OmIOC5gOC4nuC4tOC5iOC4oSBEYXRhIOKAlCDguYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4Lih4LiI4Liy4LiB4LiX4Li14LmI4Lih4Li14Lit4Lii4Li54LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJkgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tYWRkZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMTAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWFkZGRhdGEtYnRuIiBvbmNsaWNrPSJkb0FkZERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oSBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4Lix4LmJ4LiHIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItc2V0ZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7impbvuI8g4LiV4Lix4LmJ4LiHIERhdGEg4oCUIOC4geC4s+C4q+C4meC4lCBMaW1pdCDguYPguKvguKHguYggKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj5EYXRhIExpbWl0IChHQikg4oCUIDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1zZXRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1zZXRkYXRhLWJ0biIgb25jbGljaz0iZG9TZXREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguLHguYnguIcgRGF0YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlc2V0Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIMg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4oCUIOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5ieC4l+C4seC5ieC4h+C4q+C4oeC4lDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guIHguLLguKPguKPguLXguYDguIvguJUgVHJhZmZpYyDguIjguLDguYDguITguKXguLXguKLguKPguYzguKLguK3guJQgVXBsb2FkL0Rvd25sb2FkIOC4l+C4seC5ieC4h+C4q+C4oeC4lOC4guC4reC4h+C4ouC4ueC4quC4meC4teC5iTwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZXNldC1idG4iIG9uY2xpY2s9ImRvUmVzZXRUcmFmZmljKCkiPuKchSDguKLguLfguJnguKLguLHguJnguKPguLXguYDguIvguJUgVHJhZmZpYzwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4peC4muC4ouC4ueC4qiAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1kZWxldGUiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPvCfl5HvuI8g4Lil4Lia4Lii4Li54LiqIOKAlCDguKXguJrguJbguLLguKfguKMg4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LiB4Li54LmJ4LiE4Li34LiZ4LmE4LiU4LmJPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4ouC4ueC4qiA8YiBpZD0ibS1kZWwtbmFtZSIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPjwvYj4g4LiI4Liw4LiW4Li54LiB4Lil4Lia4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4Lia4LiW4Liy4Lin4LijPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWRlbGV0ZS1idG4iIG9uY2xpY2s9ImRvRGVsZXRlVXNlcigpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNkYzI2MjYsI2VmNDQ0NCkiPvCfl5HvuI8g4Lii4Li34LiZ4Lii4Lix4LiZ4Lil4Lia4Lii4Li54LiqPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9Im1vZGFsLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIiBvbmVycm9yPSJ3aW5kb3cuQ0hBSVlBX0NPTkZJRz17fSI+PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8vIOKVkOKVkOKVkOKVkCBDT05GSUcg4pWQ4pWQ4pWQ4pWQCmNvbnN0IENGRyA9ICh0eXBlb2Ygd2luZG93LkNIQUlZQV9DT05GSUcgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdy5DSEFJWUFfQ09ORklHIDoge307CmNvbnN0IEhPU1QgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKY29uc3QgWFVJICA9ICcveHVpLWFwaSc7CmNvbnN0IEFQSSAgPSAnL2FwaSc7CmNvbnN0IFNFU1NJT05fS0VZID0gJ2NoYWl5YV9hdXRoJzsKCi8vIFNlc3Npb24gY2hlY2sKY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwppZiAoIV9zLnVzZXIgfHwgIV9zLnBhc3MgfHwgRGF0ZS5ub3coKSA+PSAoX3MuZXhwfHwwKSkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8gSGVhZGVyIGRvbWFpbgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLWRvbWFpbicpLnRleHRDb250ZW50ID0gSE9TVCArICcgwrcgdjUnOwoKLy8g4pWQ4pWQ4pWQ4pWQIFVUSUxTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBmbXRCeXRlcyhiKSB7CiAgaWYgKCFiIHx8IGIgPT09IDApIHJldHVybiAnMCBCJzsKICBjb25zdCBrID0gMTAyNCwgdSA9IFsnQicsJ0tCJywnTUInLCdHQicsJ1RCJ107CiAgY29uc3QgaSA9IE1hdGguZmxvb3IoTWF0aC5sb2coYikvTWF0aC5sb2coaykpOwogIHJldHVybiAoYi9NYXRoLnBvdyhrLGkpKS50b0ZpeGVkKDEpKycgJyt1W2ldOwp9CmZ1bmN0aW9uIGZtdERhdGUobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgY29uc3QgZCA9IG5ldyBEYXRlKG1zKTsKICByZXR1cm4gZC50b0xvY2FsZURhdGVTdHJpbmcoJ3RoLVRIJyx7eWVhcjonbnVtZXJpYycsbW9udGg6J3Nob3J0JyxkYXk6J251bWVyaWMnfSk7Cn0KZnVuY3Rpb24gZGF5c0xlZnQobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gbnVsbDsKICByZXR1cm4gTWF0aC5jZWlsKChtcyAtIERhdGUubm93KCkpIC8gODY0MDAwMDApOwp9CmZ1bmN0aW9uIHNldFJpbmcoaWQsIHBjdCkgewogIGNvbnN0IGNpcmMgPSAxMzguMjsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoZWwpIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBjaXJjIC0gKGNpcmMgKiBNYXRoLm1pbihwY3QsMTAwKSAvIDEwMCk7Cn0KZnVuY3Rpb24gc2V0QmFyKGlkLCBwY3QsIHdhcm49ZmFsc2UpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuc3R5bGUud2lkdGggPSBNYXRoLm1pbihwY3QsMTAwKSArICclJzsKICBpZiAod2FybiAmJiBwY3QgPiA4NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KSc7CiAgZWxzZSBpZiAod2FybiAmJiBwY3QgPiA2NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2Y5NzMxNiwjZmI5MjNjKSc7Cn0KZnVuY3Rpb24gc2hvd0FsZXJ0KGlkLCBtc2csIHR5cGUpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcrdHlwZTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBpZiAodHlwZSA9PT0gJ29rJykgc2V0VGltZW91dCgoKT0+e2VsLnN0eWxlLmRpc3BsYXk9J25vbmUnO30sIDMwMDApOwp9CgovLyDilZDilZDilZDilZAgTkFWIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBzdyhuYW1lLCBlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZWMnKS5mb3JFYWNoKHM9PnMuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobj0+bi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nK25hbWUpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChuYW1lPT09J2NyZWF0ZScpIGNsb3NlRm9ybSgpOwogIGlmIChuYW1lPT09J2Rhc2hib2FyZCcpIGxvYWREYXNoKCk7CiAgaWYgKG5hbWU9PT0nbWFuYWdlJykgbG9hZFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0nb25saW5lJykgbG9hZE9ubGluZSgpOwogIGlmIChuYW1lPT09J2JhbicpIGxvYWRTU0hVc2VycygpOwp9CgovLyDilIDilIAgRm9ybSBuYXYg4pSA4pSACmxldCBfY3VyRm9ybSA9IG51bGw7CmZ1bmN0aW9uIG9wZW5Gb3JtKGlkKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBbJ2FpcycsJ3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gZj09PWlkID8gJ2Jsb2NrJyA6ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IGlkOwogIGlmIChpZD09PSdzc2gnKSBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB3aW5kb3cuc2Nyb2xsVG8oMCwwKTsKfQpmdW5jdGlvbiBjbG9zZUZvcm0oKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IG51bGw7Cn0KCmxldCBfd3NQb3J0ID0gJzgwJzsKZnVuY3Rpb24gdG9nUG9ydChidG4sIHBvcnQpIHsKICBfd3NQb3J0ID0gcG9ydDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M4MC1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzgwJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzNDQzLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9PT0nNDQzJyk7Cn0KZnVuY3Rpb24gdG9nR3JvdXAoYnRuLCBjbHMpIHsKICBidG4uY2xvc2VzdCgnZGl2JykucXVlcnlTZWxlY3RvckFsbChjbHMpLmZvckVhY2goYj0+Yi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYnRuLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9CgovLyDilZDilZDilZDilZAgWFVJIExPR0lOIChjb29raWUpIOKVkOKVkOKVkOKVkApsZXQgX3h1aU9rID0gZmFsc2U7CmFzeW5jIGZ1bmN0aW9uIHh1aUxvZ2luKCkgewogIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IF9zLnVzZXIsIHBhc3N3b3JkOiBfcy5wYXNzIH0pOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrJy9sb2dpbicsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQnfSwKICAgIGJvZHk6IGZvcm0udG9TdHJpbmcoKQogIH0pOwogIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICBfeHVpT2sgPSAhIWQuc3VjY2VzczsKICByZXR1cm4gX3h1aU9rOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aUdldChwYXRoKSB7CiAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7CiAgcmV0dXJuIHIuanNvbigpOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aVBvc3QocGF0aCwgYm9keSkgewogIGlmICghX3h1aU9rKSBhd2FpdCB4dWlMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwgewogICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLAogICAgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KGJvZHkpCiAgfSk7CiAgcmV0dXJuIHIuanNvbigpOwp9CgovLyDilZDilZDilZDilZAgREFTSEJPQVJEIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkRGFzaCgpIHsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXJlZnJlc2gnKTsKICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IC4uLic7CiAgX3h1aU9rID0gZmFsc2U7IC8vIGZvcmNlIHJlLWxvZ2luIOC5gOC4quC4oeC4rQoKICB0cnkgewogICAgLy8gU1NIIEFQSSBzdGF0dXMKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKHN0KSB7CiAgICAgIHJlbmRlclNlcnZpY2VzKHN0LnNlcnZpY2VzIHx8IHt9KTsKICAgIH0KCiAgICAvLyBYVUkgc2VydmVyIHN0YXR1cwogICAgY29uc3Qgb2sgPSBhd2FpdCB4dWlMb2dpbigpOwogICAgaWYgKCFvaykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj5Mb2dpbiDguYTguKHguYjguYTguJTguYknOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwgb2ZmJzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qgc3YgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvc2VydmVyL3N0YXR1cycpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChzdiAmJiBzdi5zdWNjZXNzICYmIHN2Lm9iaikgewogICAgICBjb25zdCBvID0gc3Yub2JqOwogICAgICAvLyBDUFUKICAgICAgY29uc3QgY3B1ID0gTWF0aC5yb3VuZChvLmNwdSB8fCAwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1wY3QnKS50ZXh0Q29udGVudCA9IGNwdSArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1jb3JlcycpLnRleHRDb250ZW50ID0gKG8uY3B1Q29yZXMgfHwgby5sb2dpY2FsUHJvIHx8ICctLScpICsgJyBjb3Jlcyc7CiAgICAgIHNldFJpbmcoJ2NwdS1yaW5nJywgY3B1KTsgc2V0QmFyKCdjcHUtYmFyJywgY3B1LCB0cnVlKTsKCiAgICAgIC8vIFJBTQogICAgICBjb25zdCByYW1UID0gKChvLm1lbT8udG90YWx8fDApLzEwNzM3NDE4MjQpLCByYW1VID0gKChvLm1lbT8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IHJhbVAgPSByYW1UID4gMCA/IE1hdGgucm91bmQocmFtVS9yYW1UKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLXBjdCcpLnRleHRDb250ZW50ID0gcmFtUCArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1kZXRhaWwnKS50ZXh0Q29udGVudCA9IHJhbVUudG9GaXhlZCgxKSsnIC8gJytyYW1ULnRvRml4ZWQoMSkrJyBHQic7CiAgICAgIHNldFJpbmcoJ3JhbS1yaW5nJywgcmFtUCk7IHNldEJhcigncmFtLWJhcicsIHJhbVAsIHRydWUpOwoKICAgICAgLy8gRGlzawogICAgICBjb25zdCBkc2tUID0gKChvLmRpc2s/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgZHNrVSA9ICgoby5kaXNrPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgZHNrUCA9IGRza1QgPiAwID8gTWF0aC5yb3VuZChkc2tVL2Rza1QqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLXBjdCcpLmlubmVySFRNTCA9IGRza1AgKyAnPHNwYW4+JTwvc3Bhbj4nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1kZXRhaWwnKS50ZXh0Q29udGVudCA9IGRza1UudG9GaXhlZCgwKSsnIC8gJytkc2tULnRvRml4ZWQoMCkrJyBHQic7CiAgICAgIHNldEJhcignZGlzay1iYXInLCBkc2tQLCB0cnVlKTsKCiAgICAgIC8vIFVwdGltZQogICAgICBjb25zdCB1cCA9IG8udXB0aW1lIHx8IDA7CiAgICAgIGNvbnN0IHVkID0gTWF0aC5mbG9vcih1cC84NjQwMCksIHVoID0gTWF0aC5mbG9vcigodXAlODY0MDApLzM2MDApLCB1bSA9IE1hdGguZmxvb3IoKHVwJTM2MDApLzYwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS12YWwnKS50ZXh0Q29udGVudCA9IHVkID4gMCA/IHVkKydkICcrdWgrJ2gnIDogdWgrJ2ggJyt1bSsnbSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtc3ViJykudGV4dENvbnRlbnQgPSB1ZCsn4Lin4Lix4LiZICcrdWgrJ+C4iuC4oS4gJyt1bSsn4LiZ4Liy4LiX4Li1JzsKICAgICAgY29uc3QgbG9hZHMgPSBvLmxvYWRzIHx8IFtdOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9hZC1jaGlwcycpLmlubmVySFRNTCA9IGxvYWRzLm1hcCgobCxpKT0+CiAgICAgICAgYDxzcGFuIGNsYXNzPSJiZGciPiR7WycxbScsJzVtJywnMTVtJ11baV19OiAke2wudG9GaXhlZCgyKX08L3NwYW4+YCkuam9pbignJyk7CgogICAgICAvLyBOZXR3b3JrCiAgICAgIGlmIChvLm5ldElPKSB7CiAgICAgICAgY29uc3QgdXBfYiA9IG8ubmV0SU8udXB8fDAsIGRuX2IgPSBvLm5ldElPLmRvd258fDA7CiAgICAgICAgY29uc3QgdXBGbXQgPSBmbXRCeXRlcyh1cF9iKSwgZG5GbXQgPSBmbXRCeXRlcyhkbl9iKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwJykuaW5uZXJIVE1MID0gdXBGbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbicpLmlubmVySFRNTCA9IGRuRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICB9CiAgICAgIGlmIChvLm5ldFRyYWZmaWMpIHsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnNlbnR8fDApOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4tdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMucmVjdnx8MCk7CiAgICAgIH0KCiAgICAgIC8vIFhVSSB2ZXJzaW9uCiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktdmVyJykudGV4dENvbnRlbnQgPSBvLnhyYXlWZXJzaW9uIHx8ICctLSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0gJ29waWxsJzsKICAgIH0KCiAgICAvLyBJbmJvdW5kcyBjb3VudAogICAgY29uc3QgaWJsID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoaWJsICYmIGlibC5zdWNjZXNzKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktaW5ib3VuZHMnKS50ZXh0Q29udGVudCA9IChpYmwub2JqfHxbXSkubGVuZ3RoOwogICAgfQoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsYXN0LXVwZGF0ZScpLnRleHRDb250ZW50ID0gJ+C4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogJyArIG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogIH0gY2F0Y2goZSkgewogICAgY29uc29sZS5lcnJvcihlKTsKICB9IGZpbmFsbHkgewogICAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyDguKPguLXguYDguJ/guKPguIonOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNFUlZJQ0VTIOKVkOKVkOKVkOKVkApjb25zdCBTVkNfREVGID0gWwogIHsga2V5Oid4dWknLCAgICAgIGljb246J/Cfk6EnLCBuYW1lOid4LXVpIFBhbmVsJywgICAgICBwb3J0Oic6MjA1MycgfSwKICB7IGtleTonc3NoJywgICAgICBpY29uOifwn5CNJywgbmFtZTonU1NIIEFQSScsICAgICAgICAgIHBvcnQ6Jzo2Nzg5JyB9LAogIHsga2V5Oidkcm9wYmVhcicsIGljb246J/CfkLsnLCBuYW1lOidEcm9wYmVhciBTU0gnLCAgICAgcG9ydDonOjE0MyA6MTA5JyB9LAogIHsga2V5OiduZ2lueCcsICAgIGljb246J/CfjJAnLCBuYW1lOiduZ2lueCAvIFBhbmVsJywgICAgcG9ydDonOjgwIDo0NDMnIH0sCiAgeyBrZXk6J3NzaHdzJywgICAgaWNvbjon8J+UkicsIG5hbWU6J1dTLVN0dW5uZWwnLCAgICAgICBwb3J0Oic6ODDihpI6MTQzJyB9LAogIHsga2V5OidiYWR2cG4nLCAgIGljb246J/Cfjq4nLCBuYW1lOidCYWRWUE4gVURQR1cnLCAgICAgcG9ydDonOjczMDAnIH0sCl07CmZ1bmN0aW9uIHJlbmRlclNlcnZpY2VzKG1hcCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtbGlzdCcpLmlubmVySFRNTCA9IFNWQ19ERUYubWFwKHMgPT4gewogICAgY29uc3QgdXAgPSBtYXBbcy5rZXldID09PSB0cnVlIHx8IG1hcFtzLmtleV0gPT09ICdhY3RpdmUnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJzdmMgJHt1cD8nJzonZG93bid9Ij4KICAgICAgPGRpdiBjbGFzcz0ic3ZjLWwiPjxzcGFuIGNsYXNzPSJkZyAke3VwPycnOidyZWQnfSI+PC9zcGFuPjxzcGFuPiR7cy5pY29ufTwvc3Bhbj4KICAgICAgICA8ZGl2PjxkaXYgY2xhc3M9InN2Yy1uIj4ke3MubmFtZX08L2Rpdj48ZGl2IGNsYXNzPSJzdmMtcCI+JHtzLnBvcnR9PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0icmJkZyAke3VwPycnOidkb3duJ30iPiR7dXA/J1JVTk5JTkcnOidET1dOJ308L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRTZXJ2aWNlcygpIHsKICB0cnkgewogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIHJlbmRlclNlcnZpY2VzKHN0LnNlcnZpY2VzIHx8IHt9KTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+4LmA4LiK4Li34LmI4Lit4Lih4LiV4LmI4LitIEFQSSDguYTguKHguYjguYTguJTguYk8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBQSUNLRVIgU1RBVEUg4pWQ4pWQ4pWQ4pWQCmNvbnN0IFBST1MgPSB7CiAgZHRhYzogewogICAgbmFtZTogJ0RUQUMgR0FNSU5HJywKICAgIHByb3h5OiAnMTA0LjE4LjYzLjEyNDo4MCcsCiAgICBwYXlsb2FkOiAnQ09OTkVDVCAvICBIVFRQLzEuMSBbY3JsZl1Ib3N0OiBkbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tIFtjcmxmXVtjcmxmXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0Oltob3N0XVtjcmxmXVVwZ3JhZGU6VXNlci1BZ2VudDogW3VhXVtjcmxmXVtjcmxmXScsCiAgICBkYXJrUHJveHk6ICd0cnVldmlwYW5saW5lLmdvZHZwbi5zaG9wJywgZGFya1Byb3h5UG9ydDogODAKICB9LAogIHRydWU6IHsKICAgIG5hbWU6ICdUUlVFIFRXSVRURVInLAogICAgcHJveHk6ICcxMDQuMTguMzkuMjQ6ODAnLAogICAgcGF5bG9hZDogJ1BPU1QgLyBIVFRQLzEuMVtjcmxmXUhvc3Q6aGVscC54LmNvbVtjcmxmXVVzZXItQWdlbnQ6IFt1YV1bY3JsZl1bY3JsZl1bc3BsaXRdW2NyXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OiBbaG9zdF1bY3JsZl1VcGdyYWRlOiB3ZWJzb2NrZXRbY3JsZl1Db25uZWN0aW9uOlVwZ3JhZGVbY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfQp9Owpjb25zdCBOUFZfSE9TVCA9ICd3d3cucHJvamVjdC5nb2R2cG4uc2hvcCcsIE5QVl9QT1JUID0gODA7CmxldCBfc3NoUHJvID0gJ2R0YWMnLCBfc3NoQXBwID0gJ25wdicsIF9zc2hQb3J0ID0gJzgwJzsKCmZ1bmN0aW9uIHBpY2tQb3J0KHApIHsKICBfc3NoUG9ydCA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BiLTgwJykuY2xhc3NOYW1lICA9ICdwb3J0LWJ0bicgKyAocD09PSc4MCcgID8gJyBhY3RpdmUtcDgwJyAgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BiLTQ0MycpLmNsYXNzTmFtZSA9ICdwb3J0LWJ0bicgKyAocD09PSc0NDMnID8gJyBhY3RpdmUtcDQ0MycgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja1BybyhwKSB7CiAgX3NzaFBybyA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byby1kdGFjJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChwPT09J2R0YWMnID8gJyBhLWR0YWMnIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tdHJ1ZScpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSd0cnVlJyA/ICcgYS10cnVlJyA6ICcnKTsKfQpmdW5jdGlvbiBwaWNrQXBwKGEpIHsKICBfc3NoQXBwID0gYTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwLW5wdicpLmNsYXNzTmFtZSAgPSAncGljay1vcHQnICsgKGE9PT0nbnB2JyAgPyAnIGEtbnB2JyAgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcC1kYXJrJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChhPT09J2RhcmsnID8gJyBhLWRhcmsnIDogJycpOwp9CmZ1bmN0aW9uIGJ1aWxkTnB2TGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBqID0gewogICAgc3NoQ29uZmlnVHlwZTonU1NILVByb3h5LVBheWxvYWQnLCByZW1hcmtzOnByby5uYW1lKyctJytuYW1lLAogICAgc3NoSG9zdDpOUFZfSE9TVCwgc3NoUG9ydDpOUFZfUE9SVCwKICAgIHNzaFVzZXJuYW1lOm5hbWUsIHNzaFBhc3N3b3JkOnBhc3MsCiAgICBzbmk6JycsIHRsc1ZlcnNpb246J0RFRkFVTFQnLAogICAgaHR0cFByb3h5OnByby5wcm94eSwgYXV0aGVudGljYXRlUHJveHk6ZmFsc2UsCiAgICBwcm94eVVzZXJuYW1lOicnLCBwcm94eVBhc3N3b3JkOicnLAogICAgcGF5bG9hZDpwcm8ucGF5bG9hZCwKICAgIGRuc01vZGU6J1VEUCcsIGRuc1NlcnZlcjonJywgbmFtZXNlcnZlcjonJywgcHVibGljS2V5OicnLAogICAgdWRwZ3dQb3J0OjczMDAsIHVkcGd3VHJhbnNwYXJlbnRETlM6dHJ1ZQogIH07CiAgcmV0dXJuICducHZ0LXNzaDovLycgKyBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChKU09OLnN0cmluZ2lmeShqKSkpKTsKfQpmdW5jdGlvbiBidWlsZERhcmtMaW5rKG5hbWUsIHBhc3MsIHBybykgewogIGNvbnN0IHBwID0gKHByby5wcm94eXx8JycpLnNwbGl0KCc6Jyk7CiAgY29uc3QgZGggPSBwcFswXSB8fCBwcm8uZGFya1Byb3h5OwogIGNvbnN0IGogPSB7CiAgICBjb25maWdUeXBlOidTU0gtUFJPWFknLCByZW1hcmtzOnByby5uYW1lKyctJytuYW1lLAogICAgc3NoSG9zdDpIT1NULCBzc2hQb3J0OjE0MywKICAgIHNzaFVzZXI6bmFtZSwgc3NoUGFzczpwYXNzLAogICAgcGF5bG9hZDonR0VUIC8gSFRUUC8xLjFcclxuSG9zdDogJytIT1NUKydcclxuVXBncmFkZTogd2Vic29ja2V0XHJcbkNvbm5lY3Rpb246IFVwZ3JhZGVcclxuXHJcbicsCiAgICBwcm94eUhvc3Q6ZGgsIHByb3h5UG9ydDo4MCwKICAgIHVkcGd3QWRkcjonMTI3LjAuMC4xJywgdWRwZ3dQb3J0OjczMDAsIHRsc0VuYWJsZWQ6ZmFsc2UKICB9OwogIHJldHVybiAnZGFya3R1bm5lbC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBDUkVBVEUgU1NIIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBjcmVhdGVTU0goKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlcicpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBwYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1wYXNzJykudmFsdWUudHJpbSgpOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWRheXMnKS52YWx1ZSl8fDMwOwogIGNvbnN0IGlwbCAgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWlwJykgPyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWlwJykudmFsdWUgOiAyKXx8MjsKICBpZiAoIXVzZXIpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBVc2VybmFtZScsJ2VycicpOwogIGlmICghcGFzcykgcmV0dXJuIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3JkJywnZXJyJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOwogIGJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iIHN0eWxlPSJib3JkZXItY29sb3I6cmdiYSgzNCwxOTcsOTQsLjMpO2JvcmRlci10b3AtY29sb3I6IzIyYzU1ZSI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGNvbnN0IHJlc0VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1saW5rLXJlc3VsdCcpOwogIGlmIChyZXNFbCkgcmVzRWwuY2xhc3NOYW1lPSdsaW5rLXJlc3VsdCc7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9jcmVhdGVfc3NoJywgewogICAgICBtZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7dXNlciwgcGFzc3dvcmQ6cGFzcywgZGF5cywgaXBfbGltaXQ6aXBsfSkKICAgIH0pOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAgaWYgKCFkLm9rKSB0aHJvdyBuZXcgRXJyb3IoZC5lcnJvciB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgcHJvICA9IFBST1NbX3NzaFByb10gfHwgUFJPUy5kdGFjOwogICAgY29uc3QgbGluayA9IF9zc2hBcHA9PT0nbnB2JyA/IGJ1aWxkTnB2TGluayh1c2VyLHBhc3MscHJvKSA6IGJ1aWxkRGFya0xpbmsodXNlcixwYXNzLHBybyk7CiAgICBjb25zdCBpc05wdiA9IF9zc2hBcHA9PT0nbnB2JzsKICAgIGNvbnN0IGxwQ2xzID0gaXNOcHYgPyAnJyA6ICcgZGFyay1scCc7CiAgICBjb25zdCBjQ2xzICA9IGlzTnB2ID8gJ25wdicgOiAnZGFyayc7CiAgICBjb25zdCBhcHBMYWJlbCA9IGlzTnB2ID8gJ05wdnQnIDogJ0RhcmtUdW5uZWwnOwoKICAgIGlmIChyZXNFbCkgewogICAgICByZXNFbC5jbGFzc05hbWUgPSAnbGluay1yZXN1bHQgc2hvdyc7CiAgICAgIGNvbnN0IHNhZmVMaW5rID0gbGluay5yZXBsYWNlKC9cXC9nLCdcXFxcJykucmVwbGFjZSgvJy9nLCJcXCciKTsKICAgICAgcmVzRWwuaW5uZXJIVE1MID0KICAgICAgICAiPGRpdiBjbGFzcz0nbGluay1yZXN1bHQtaGRyJz4iICsKICAgICAgICAgICI8c3BhbiBjbGFzcz0naW1wLWJhZGdlICIrY0NscysiJz4iK2FwcExhYmVsKyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6dmFyKC0tbXV0ZWQpJz4iK3Byby5uYW1lKyIgXHhiNyBQb3J0ICIrX3NzaFBvcnQrIjwvc3Bhbj4iICsKICAgICAgICAgICI8c3BhbiBzdHlsZT0nZm9udC1zaXplOi42NXJlbTtjb2xvcjojMjJjNTVlO21hcmdpbi1sZWZ0OmF1dG8nPlx1MjcwNSAiK3VzZXIrIjwvc3Bhbj4iICsKICAgICAgICAiPC9kaXY+IiArCiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcHJldmlldyIrbHBDbHMrIic+IitsaW5rKyI8L2Rpdj4iICsKICAgICAgICAiPGJ1dHRvbiBjbGFzcz0nY29weS1saW5rLWJ0biAiK2NDbHMrIicgaWQ9J2NvcHktc3NoLWJ0bicgb25jbGljaz1cImNvcHlTU0hMaW5rKClcIj4iKwogICAgICAgICAgIlx1ZDgzZFx1ZGNjYiBDb3B5ICIrYXBwTGFiZWwrIiBMaW5rIisKICAgICAgICAiPC9idXR0b24+IjsKICAgICAgd2luZG93Ll9sYXN0U1NITGluayA9IGxpbms7CiAgICAgIHdpbmRvdy5fbGFzdFNTSEFwcCAgPSBjQ2xzOwogICAgICB3aW5kb3cuX2xhc3RTU0hMYWJlbCA9IGFwcExhYmVsOwogICAgfQoKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4pyFIOC4quC4o+C5ieC4suC4hyAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIggwrcg4Lir4Lih4LiU4Lit4Liy4Lii4Li4ICcrZC5leHAsJ29rJyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZT0nJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlPScnOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KelSDguKrguKPguYnguLLguIcgVXNlcic7IH0KfQpmdW5jdGlvbiBjb3B5U1NITGluaygpIHsKICBjb25zdCBsaW5rID0gd2luZG93Ll9sYXN0U1NITGlua3x8Jyc7CiAgY29uc3QgY0NscyA9IHdpbmRvdy5fbGFzdFNTSEFwcHx8J25wdic7CiAgY29uc3QgbGFiZWwgPSB3aW5kb3cuX2xhc3RTU0hMYWJlbHx8J0xpbmsnOwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KGxpbmspLnRoZW4oZnVuY3Rpb24oKXsKICAgIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29weS1zc2gtYnRuJyk7CiAgICBpZihiKXsgYi50ZXh0Q29udGVudD0nXHUyNzA1IOC4hOC4seC4lOC4peC4reC4geC5geC4peC5ieC4pyEnOyBzZXRUaW1lb3V0KGZ1bmN0aW9uKCl7Yi50ZXh0Q29udGVudD0nXHVkODNkXHVkY2NiIENvcHkgJytsYWJlbCsnIExpbmsnO30sMjAwMCk7IH0KICB9KS5jYXRjaChmdW5jdGlvbigpeyBwcm9tcHQoJ0NvcHkgbGluazonLGxpbmspOyB9KTsKfQoKLy8gU1NIIHVzZXIgdGFibGUKbGV0IF9zc2hUYWJsZVVzZXJzID0gW107CmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hUYWJsZUluRm9ybSgpIHsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBfc3NoVGFibGVVc2VycyA9IGQudXNlcnMgfHwgW107CiAgICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogICAgaWYodGIpIHRiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6I2VmNDQ0NDtwYWRkaW5nOjE2cHgiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBTU0ggQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvdGQ+PC90cj4nOwogIH0KfQpmdW5jdGlvbiByZW5kZXJTU0hUYWJsZSh1c2VycykgewogIGNvbnN0IHRiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLXRib2R5Jyk7CiAgaWYgKCF0YikgcmV0dXJuOwogIGlmICghdXNlcnMubGVuZ3RoKSB7CiAgICB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjIwcHgiPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3RkPjwvdHI+JzsKICAgIHJldHVybjsKICB9CiAgY29uc3Qgbm93ID0gbmV3IERhdGUoKS50b0lTT1N0cmluZygpLnNsaWNlKDAsMTApOwogIHRiLmlubmVySFRNTCA9IHVzZXJzLm1hcChmdW5jdGlvbih1LGkpewogICAgY29uc3QgZXhwaXJlZCA9IHUuZXhwICYmIHUuZXhwIDwgbm93OwogICAgY29uc3QgYWN0aXZlICA9IHUuYWN0aXZlICE9PSBmYWxzZSAmJiAhZXhwaXJlZDsKICAgIGNvbnN0IGRMZWZ0ICAgPSB1LmV4cCA/IE1hdGguY2VpbCgobmV3IERhdGUodS5leHApLURhdGUubm93KCkpLzg2NDAwMDAwKSA6IG51bGw7CiAgICBjb25zdCBiYWRnZSAgID0gYWN0aXZlCiAgICAgID8gJzxzcGFuIGNsYXNzPSJiZGcgYmRnLWciPkFDVElWRTwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJiZGcgYmRnLXIiPkVYUElSRUQ8L3NwYW4+JzsKICAgIGNvbnN0IGRUYWcgPSBkTGVmdCE9PW51bGwKICAgICAgPyAnPHNwYW4gY2xhc3M9ImRheXMtYmFkZ2UiPicrKGRMZWZ0PjA/ZExlZnQrJ2QnOifguKvguKHguJQnKSsnPC9zcGFuPicKICAgICAgOiAnPHNwYW4gY2xhc3M9ImRheXMtYmFkZ2UiPlx1MjIxZTwvc3Bhbj4nOwogICAgcmV0dXJuICc8dHI+PHRkIHN0eWxlPSJjb2xvcjp2YXIoLS1tdXRlZCkiPicrKGkrMSkrJzwvdGQ+JyArCiAgICAgICc8dGQ+PGI+Jyt1LnVzZXIrJzwvYj48L3RkPicgKwogICAgICAnPHRkIHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjonKyhleHBpcmVkPycjZWY0NDQ0JzondmFyKC0tbXV0ZWQpJykrJyI+JysKICAgICAgICAodS5leHB8fCfguYTguKHguYjguIjguLPguIHguLHguJQnKSsnPC90ZD4nICsKICAgICAgJzx0ZD4nK2JhZGdlKyc8L3RkPicgKwogICAgICAnPHRkPjxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6NHB4O2FsaWduLWl0ZW1zOmNlbnRlciI+JysKICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iYnRuLXRibCIgdGl0bGU9IuC4leC5iOC4reC4reC4suC4ouC4uCIgb25jbGljaz0ib3BlblNTSFJlbmV3TW9kYWwoXCcnK3UudXNlcisnXCcpIj7wn5SEPC9idXR0b24+JysKICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iYnRuLXRibCIgdGl0bGU9IuC4peC4miIgb25jbGljaz0iZGVsU1NIVXNlcihcJycrdS51c2VyKydcJykiIHN0eWxlPSJib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsLjMpIj7wn5eR77iPPC9idXR0b24+JysKICAgICAgICBkVGFnKwogICAgICAnPC9kaXY+PC90ZD48L3RyPic7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsdGVyU1NIVXNlcnMocSkgewogIHJlbmRlclNTSFRhYmxlKF9zc2hUYWJsZVVzZXJzLmZpbHRlcihmdW5jdGlvbih1KXtyZXR1cm4gKHUudXNlcnx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50b0xvd2VyQ2FzZSgpKTt9KSk7Cn0KLy8gU1NIIFJlbmV3IE1vZGFsCmxldCBfcmVuZXdTU0hVc2VyID0gJyc7CmZ1bmN0aW9uIG9wZW5TU0hSZW5ld01vZGFsKHVzZXIpIHsKICBfcmVuZXdTU0hVc2VyID0gdXNlcjsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LXVzZXJuYW1lJykudGV4dENvbnRlbnQgPSB1c2VyOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctZGF5cycpLnZhbHVlID0gJzMwJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LW1vZGFsJykuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwp9CmZ1bmN0aW9uIGNsb3NlU1NIUmVuZXdNb2RhbCgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LW1vZGFsJykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogIF9yZW5ld1NTSFVzZXIgPSAnJzsKfQphc3luYyBmdW5jdGlvbiBkb1NTSFJlbmV3KCkgewogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKCFkYXlzfHxkYXlzPD0wKSByZXR1cm47CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOyBidG4udGV4dENvbnRlbnQgPSAn4LiB4Liz4Lil4Lix4LiH4LiV4LmI4Lit4Lit4Liy4Lii4Li4Li4uJzsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2V4dGVuZF9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyOl9yZW5ld1NTSFVzZXIsZGF5c30pCiAgICB9KS50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKTt9KTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKHIuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzA1IOC4leC5iOC4reC4reC4suC4ouC4uCAnK19yZW5ld1NTSFVzZXIrJyArJytkYXlzKycg4Lin4Lix4LiZIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBjbG9zZVNTSFJlbmV3TW9kYWwoKTsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgewogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3NGMgJytlLm1lc3NhZ2UsJ2VycicpOwogIH0gZmluYWxseSB7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLgnOwogIH0KfQphc3luYyBmdW5jdGlvbiByZW5ld1NTSFVzZXIodXNlcikgeyBvcGVuU1NIUmVuZXdNb2RhbCh1c2VyKTsgfQphc3luYyBmdW5jdGlvbiBkZWxTU0hVc2VyKHVzZXIpIHsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciIOC4luC4suC4p+C4oz8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcsewogICAgICBtZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJ9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBhbGVydCgnXHUyNzRjICcrZS5tZXNzYWdlKTsgfQp9Ci8vIOKVkOKVkOKVkOKVkCBDUkVBVEUgVkxFU1Mg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGdlblVVSUQoKSB7CiAgcmV0dXJuICd4eHh4eHh4eC14eHh4LTR4eHgteXh4eC14eHh4eHh4eHh4eHgnLnJlcGxhY2UoL1t4eV0vZyxjPT57CiAgICBjb25zdCByPU1hdGgucmFuZG9tKCkqMTZ8MDsgcmV0dXJuIChjPT09J3gnP3I6KHImMHgzfDB4OCkpLnRvU3RyaW5nKDE2KTsKICB9KTsKfQphc3luYyBmdW5jdGlvbiBjcmVhdGVWTEVTUyhjYXJyaWVyKSB7CiAgY29uc3QgZW1haWxFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1lbWFpbCcpOwogIGNvbnN0IGRheXNFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZGF5cycpOwogIGNvbnN0IGlwRWwgICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctaXAnKTsKICBjb25zdCBnYkVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWdiJyk7CiAgY29uc3QgZW1haWwgICA9IGVtYWlsRWwudmFsdWUudHJpbSgpOwogIGNvbnN0IGRheXMgICAgPSBwYXJzZUludChkYXlzRWwudmFsdWUpfHwzMDsKICBjb25zdCBpcExpbWl0ID0gcGFyc2VJbnQoaXBFbC52YWx1ZSl8fDI7CiAgY29uc3QgZ2IgICAgICA9IHBhcnNlSW50KGdiRWwudmFsdWUpfHwwOwogIGlmICghZW1haWwpIHJldHVybiBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIEVtYWlsL1VzZXJuYW1lJywnZXJyJyk7CgogIGNvbnN0IHBvcnQgPSBjYXJyaWVyPT09J2FpcycgPyA4MDgwIDogODg4MDsKICBjb25zdCBzbmkgID0gY2Fycmllcj09PSdhaXMnID8gJ2NqLWViYi5zcGVlZHRlc3QubmV0JyA6ICd0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzJzsKCiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWJ0bicpOwogIGJ0bi5kaXNhYmxlZD10cnVlOyBidG4uaW5uZXJIVE1MPSc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKCiAgdHJ5IHsKICAgIGlmICghX3h1aU9rKSBhd2FpdCB4dWlMb2dpbigpOwogICAgLy8g4Lir4LiyIGluYm91bmQgaWQKICAgIGNvbnN0IGxpc3QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgY29uc3QgaWIgPSAobGlzdC5vYmp8fFtdKS5maW5kKHg9PngucG9ydD09PXBvcnQpOwogICAgaWYgKCFpYikgdGhyb3cgbmV3IEVycm9yKGDguYTguKHguYjguJ7guJogaW5ib3VuZCBwb3J0ICR7cG9ydH0g4oCUIOC4o+C4seC4mSBzZXR1cCDguIHguYjguK3guJlgKTsKCiAgICBjb25zdCB1aWQgPSBnZW5VVUlEKCk7CiAgICBjb25zdCBleHBNcyA9IGRheXMgPiAwID8gKERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwKSA6IDA7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CgogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9hZGRDbGllbnQnLCB7CiAgICAgIGlkOiBpYi5pZCwKICAgICAgc2V0dGluZ3M6IEpTT04uc3RyaW5naWZ5KHsgY2xpZW50czpbewogICAgICAgIGlkOnVpZCwgZmxvdzonJywgZW1haWwsIGxpbWl0SXA6aXBMaW1pdCwKICAgICAgICB0b3RhbEdCOnRvdGFsQnl0ZXMsIGV4cGlyeVRpbWU6ZXhwTXMsIGVuYWJsZTp0cnVlLCB0Z0lkOicnLCBzdWJJZDonJywgY29tbWVudDonJywgcmVzZXQ6MAogICAgICB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBsaW5rID0gYHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06JHtwb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChlbWFpbCsnLScrKGNhcnJpZXI9PT0nYWlzJz8nQUlTJzonVFJVRScpKX1gOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWVtYWlsJykudGV4dENvbnRlbnQgPSBlbWFpbDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLXV1aWQnKS50ZXh0Q29udGVudCA9IHVpZDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWV4cCcpLnRleHRDb250ZW50ID0gZXhwTXMgPiAwID8gZm10RGF0ZShleHBNcykgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWxpbmsnKS50ZXh0Q29udGVudCA9IGxpbms7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0JykuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgLy8gR2VuZXJhdGUgUVIgY29kZQogICAgY29uc3QgcXJEaXYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcXInKTsKICAgIGlmIChxckRpdikgewogICAgICBxckRpdi5pbm5lckhUTUwgPSAnJzsKICAgICAgdHJ5IHsKICAgICAgICBuZXcgUVJDb2RlKHFyRGl2LCB7IHRleHQ6IGxpbmssIHdpZHRoOiAxODAsIGhlaWdodDogMTgwLCBjb3JyZWN0TGV2ZWw6IFFSQ29kZS5Db3JyZWN0TGV2ZWwuTSB9KTsKICAgICAgfSBjYXRjaChxckVycikgeyBxckRpdi5pbm5lckhUTUwgPSAnJzsgfQogICAgfQogICAgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgVkxFU1MgQWNjb3VudCDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZW1haWxFbC52YWx1ZT0nJzsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfimqEg4Liq4Lij4LmJ4Liy4LiHICcrKGNhcnJpZXI9PT0nYWlzJz8nQUlTJzonVFJVRScpKycgQWNjb3VudCc7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSBVU0VSUyDilZDilZDilZDilZAKbGV0IF9hbGxVc2VycyA9IFtdLCBfY3VyVXNlciA9IG51bGw7CmFzeW5jIGZ1bmN0aW9uIGxvYWRVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlPayA9IGZhbHNlOwogICAgYXdhaXQgeHVpTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihkLm1zZyB8fCAn4LmC4Lir4Lil4LiUIGluYm91bmRzIOC5hOC4oeC5iOC5hOC4lOC5iScpOwogICAgX2FsbFVzZXJzID0gW107CiAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICBfYWxsVXNlcnMucHVzaCh7CiAgICAgICAgICBpYklkOiBpYi5pZCwgcG9ydDogaWIucG9ydCwgcHJvdG86IGliLnByb3RvY29sLAogICAgICAgICAgZW1haWw6IGMuZW1haWx8fGMuaWQsIHV1aWQ6IGMuaWQsCiAgICAgICAgICBleHA6IGMuZXhwaXJ5VGltZXx8MCwgdG90YWw6IGMudG90YWxHQnx8MCwKICAgICAgICAgIHVwOiBpYi51cHx8MCwgZG93bjogaWIuZG93bnx8MCwgbGltaXRJcDogYy5saW1pdElwfHwwCiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSk7CiAgICByZW5kZXJVc2VycyhfYWxsVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclVzZXJzKHVzZXJzKSB7CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lie4Lia4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMPC9wPjwvZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1ID0+IHsKICAgIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogICAgbGV0IGJhZGdlLCBjbHM7CiAgICBpZiAoIXUuZXhwIHx8IHUuZXhwPT09MCkgeyBiYWRnZT0n4pyTIOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7IGNscz0nb2snOyB9CiAgICBlbHNlIGlmIChkbCA8IDApICAgICAgICAgeyBiYWRnZT0n4Lir4Lih4LiU4Lit4Liy4Lii4Li4JzsgY2xzPSdleHAnOyB9CiAgICBlbHNlIGlmIChkbCA8PSAzKSAgICAgICAgeyBiYWRnZT0n4pqgICcrZGwrJ2QnOyBjbHM9J3Nvb24nOyB9CiAgICBlbHNlICAgICAgICAgICAgICAgICAgICAgeyBiYWRnZT0n4pyTICcrZGwrJ2QnOyBjbHM9J29rJzsgfQogICAgY29uc3QgYXZDbHMgPSBkbCA8IDAgPyAnYXYteCcgOiAnYXYtZyc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIiBvbmNsaWNrPSJvcGVuVXNlcigke0pTT04uc3RyaW5naWZ5KHUpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyl9KSI+CiAgICAgIDxkaXYgY2xhc3M9InVhdiAke2F2Q2xzfSI+JHsodS5lbWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3UuZW1haWx9PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idW0iPlBvcnQgJHt1LnBvcnR9IMK3ICR7Zm10Qnl0ZXModS51cCt1LmRvd24pfSDguYPguIrguYk8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJhYmRnICR7Y2xzfSI+JHtiYWRnZX08L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclVzZXJzKHEpIHsKICByZW5kZXJVc2VycyhfYWxsVXNlcnMuZmlsdGVyKHU9Pih1LmVtYWlsfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBNT0RBTCBVU0VSIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBvcGVuVXNlcih1KSB7CiAgaWYgKHR5cGVvZiB1ID09PSAnc3RyaW5nJykgdSA9IEpTT04ucGFyc2UodSk7CiAgX2N1clVzZXIgPSB1OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdCcpLnRleHRDb250ZW50ID0gJ+Kame+4jyAnK3UuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1JykudGV4dENvbnRlbnQgPSB1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcCcpLnRleHRDb250ZW50ID0gdS5wb3J0OwogIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogIGNvbnN0IGV4cFR4dCA9ICF1LmV4cHx8dS5leHA9PT0wID8gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcgOiBmbXREYXRlKHUuZXhwKTsKICBjb25zdCBkZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZScpOwogIGRlLnRleHRDb250ZW50ID0gZXhwVHh0OwogIGRlLmNsYXNzTmFtZSA9ICdkdicgKyAoZGwgIT09IG51bGwgJiYgZGwgPCAwID8gJyByZWQnIDogJyBncmVlbicpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZCcpLnRleHRDb250ZW50ID0gdS50b3RhbCA+IDAgPyBmbXRCeXRlcyh1LnRvdGFsKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdHInKS50ZXh0Q29udGVudCA9IGZtdEJ5dGVzKHUudXArdS5kb3duKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGknKS50ZXh0Q29udGVudCA9IHUubGltaXRJcCB8fCAn4oieJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHV1JykudGV4dENvbnRlbnQgPSB1LnV1aWQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwp9CmZ1bmN0aW9uIGNtKCl7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogIF9tU3Vicy5mb3JFYWNoKGsgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5hYnRuJykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwp9CgovLyDilIDilIAgTU9EQUwgNi1BQ1RJT04gU1lTVEVNIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjb25zdCBfbVN1YnMgPSBbJ3JlbmV3JywnZXh0ZW5kJywnYWRkZGF0YScsJ3NldGRhdGEnLCdyZXNldCcsJ2RlbGV0ZSddOwpmdW5jdGlvbiBtQWN0aW9uKGtleSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrZXkpOwogIGNvbnN0IGlzT3BlbiA9IGVsLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpOwogIF9tU3Vicy5mb3JFYWNoKGsgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5hYnRuJykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGlmICghaXNPcGVuKSB7CiAgICBlbC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICBpZiAoa2V5PT09J2RlbGV0ZScgJiYgX2N1clVzZXIpIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWRlbC1uYW1lJykudGV4dENvbnRlbnQgPSBfY3VyVXNlci5lbWFpbDsKICAgIHNldFRpbWVvdXQoKCk9PmVsLnNjcm9sbEludG9WaWV3KHtiZWhhdmlvcjonc21vb3RoJyxibG9jazonbmVhcmVzdCd9KSwxMDApOwogIH0KfQpmdW5jdGlvbiBfbUJ0bkxvYWQoaWQsIGxvYWRpbmcsIG9yaWdUZXh0KSB7CiAgY29uc3QgYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWIpIHJldHVybjsKICBiLmRpc2FibGVkID0gbG9hZGluZzsKICBpZiAobG9hZGluZykgeyBiLmRhdGFzZXQub3JpZyA9IGIudGV4dENvbnRlbnQ7IGIuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+IOC4geC4s+C4peC4seC4h+C4lOC4s+C5gOC4meC4tOC4meC4geC4suC4oy4uLic7IH0KICBlbHNlIGlmIChiLmRhdGFzZXQub3JpZykgYi50ZXh0Q29udGVudCA9IGIuZGF0YXNldC5vcmlnOwp9Cgphc3luYyBmdW5jdGlvbiBkb1JlbmV3VXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXJlbmV3LWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tcmVuZXctYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGV4cE1zID0gRGF0ZS5ub3coKSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4LmI4Lit4Lit4Liy4Lii4Li44Liq4Liz4LmA4Lij4LmH4LiIICcrZGF5cysnIOC4p+C4seC4mSAo4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJKScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0V4dGVuZFVzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1leHRlbmQtZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoZGF5cyA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iOC4s+C4meC4p+C4meC4p+C4seC4mScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGJhc2UgPSAoX2N1clVzZXIuZXhwICYmIF9jdXJVc2VyLmV4cCA+IERhdGUubm93KCkpID8gX2N1clVzZXIuZXhwIDogRGF0ZS5ub3coKTsKICAgIGNvbnN0IGV4cE1zID0gYmFzZSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihICcrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIggKOC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lCknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvQWRkRGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgYWRkR2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWFkZGRhdGEtZ2InKS52YWx1ZSl8fDA7CiAgaWYgKGFkZEdiIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBuZXdUb3RhbCA9IChfY3VyVXNlci50b3RhbHx8MCkgKyBhZGRHYioxMDczNzQxODI0OwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOm5ld1RvdGFsLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguYDguJ7guLTguYjguKEgRGF0YSArJythZGRHYisnIEdCIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWFkZGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvU2V0RGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZ2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXNldGRhdGEtZ2InKS52YWx1ZSk7CiAgaWYgKGlzTmFOKGdiKXx8Z2I8MCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYioxMDczNzQxODI0IDogMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjp0b3RhbEJ5dGVzLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguJXguLHguYnguIcgRGF0YSBMaW1pdCAnKyhnYj4wP2diKycgR0InOifguYTguKHguYjguIjguLPguIHguLHguJQnKSsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvUmVzZXRUcmFmZmljKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9yZXNldENsaWVudFRyYWZmaWMvJytfY3VyVXNlci5lbWFpbCk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTUwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZXNldC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9EZWxldGVVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvJytfY3VyVXNlci5pYklkKycvZGVsQ2xpZW50LycrX2N1clVzZXIudXVpZCk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKXguJrguKLguLnguKogJytfY3VyVXNlci5lbWFpbCsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxMjAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCBmYWxzZSk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlPayA9IGZhbHNlOwogICAgYXdhaXQgeHVpTG9naW4oKTsKICAgIC8vIOC5guC4q+C4peC4lCBpbmJvdW5kcyDguJbguYnguLLguKLguLHguIfguYTguKHguYjguKHguLUKICAgIGlmICghX2FsbFVzZXJzLmxlbmd0aCkgewogICAgICBjb25zdCBkID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAgIGlmIChkICYmIGQuc3VjY2VzcykgewogICAgICAgIF9hbGxVc2VycyA9IFtdOwogICAgICAgIChkLm9ianx8W10pLmZvckVhY2goaWIgPT4gewogICAgICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgICAgICAoc2V0dGluZ3MuY2xpZW50c3x8W10pLmZvckVhY2goYyA9PiB7CiAgICAgICAgICAgIF9hbGxVc2Vycy5wdXNoKHsgaWJJZDppYi5pZCwgcG9ydDppYi5wb3J0LCBwcm90bzppYi5wcm90b2NvbCwKICAgICAgICAgICAgICBlbWFpbDpjLmVtYWlsfHxjLmlkLCB1dWlkOmMuaWQsIGV4cDpjLmV4cGlyeVRpbWV8fDAsCiAgICAgICAgICAgICAgdG90YWw6Yy50b3RhbEdCfHwwLCB1cDppYi51cHx8MCwgZG93bjppYi5kb3dufHwwLCBsaW1pdElwOmMubGltaXRJcHx8MCB9KTsKICAgICAgICAgIH0pOwogICAgICAgIH0pOwogICAgICB9CiAgICB9CiAgICBjb25zdCBvZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9vbmxpbmVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgLy8g4Lij4Lit4LiH4Lij4Lix4LiaIGZvcm1hdDoge29iajogWy4uLl19IOC4q+C4o+C4t+C4rSB7b2JqOiBudWxsfSDguKvguKPguLfguK0ge29iajoge319CiAgICBsZXQgZW1haWxzID0gW107CiAgICBpZiAob2QgJiYgb2Qub2JqKSB7CiAgICAgIGlmIChBcnJheS5pc0FycmF5KG9kLm9iaikpIGVtYWlscyA9IG9kLm9iajsKICAgICAgZWxzZSBpZiAodHlwZW9mIG9kLm9iaiA9PT0gJ29iamVjdCcpIGVtYWlscyA9IE9iamVjdC52YWx1ZXMob2Qub2JqKS5mbGF0KCkuZmlsdGVyKGU9PnR5cGVvZiBlPT09J3N0cmluZycpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1jb3VudCcpLnRleHRDb250ZW50ID0gZW1haWxzLmxlbmd0aDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtdGltZScpLnRleHRDb250ZW50ID0gbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgICBpZiAoIWVtYWlscy5sZW5ndGgpIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfmLQ8L2Rpdj48cD7guYTguKHguYjguKHguLXguKLguLnguKrguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L3A+PC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3QgdU1hcCA9IHt9OwogICAgX2FsbFVzZXJzLmZvckVhY2godT0+eyB1TWFwW3UuZW1haWxdPXU7IH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1saXN0JykuaW5uZXJIVE1MID0gZW1haWxzLm1hcChlbWFpbD0+ewogICAgICBjb25zdCB1ID0gdU1hcFtlbWFpbF07CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iPgogICAgICAgIDxkaXYgY2xhc3M9InVhdiBhdi1nIj7wn5+iPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke2VtYWlsfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idW0iPiR7dSA/ICdQb3J0ICcrdS5wb3J0IDogJ1ZMRVNTJ30gwrcg4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4Lit4Lii4Li54LmIPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgb2siPk9OTElORTwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU1NIIFVTRVJTIChiYW4gdGFiKSDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZFNTSFVzZXJzKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvdXNlcnMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIGNvbnN0IHVzZXJzID0gZC51c2VycyB8fCBbXTsKICAgIGlmICghdXNlcnMubGVuZ3RoKSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfk608L2Rpdj48cD7guYTguKHguYjguKHguLUgU1NIIHVzZXJzPC9wPjwvZGl2Pic7IHJldHVybjsgfQogICAgY29uc3Qgbm93ID0gbmV3IERhdGUoKS50b0lTT1N0cmluZygpLnNsaWNlKDAsMTApOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUwgPSB1c2Vycy5tYXAodT0+ewogICAgICBjb25zdCBleHAgPSB1LmV4cCB8fCAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICAgICAgY29uc3QgYWN0aXZlID0gdS5hY3RpdmUgIT09IGZhbHNlOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YXYgJHthY3RpdmU/J2F2LWcnOidhdi14J30iPiR7dS51c2VyWzBdLnRvVXBwZXJDYXNlKCl9PC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3UudXNlcn08L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVtIj7guKvguKHguJTguK3guLLguKLguLg6ICR7ZXhwfTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnICR7YWN0aXZlPydvayc6J2V4cCd9Ij4ke2FjdGl2ZT8nQWN0aXZlJzonRXhwaXJlZCd9PC9zcGFuPgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQphc3luYyBmdW5jdGlvbiBkZWxldGVTU0goKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVlLnRyaW0oKTsKICBpZiAoIXVzZXIpIHJldHVybiBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBVc2VybmFtZScsJ2VycicpOwogIGlmICghY29uZmlybSgn4Lil4LiaIFNTSCB1c2VyICInK3VzZXIrJyIgPycpKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy9kZWxldGVfc3NoJyx7bWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJ9KX0pLnRoZW4ocj0+ci5qc29uKCkpOwogICAgaWYgKCFkLm9rKSB0aHJvdyBuZXcgRXJyb3IoZC5lcnJvcnx8J+C4peC4muC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinIUg4Lil4LiaICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZT0nJzsKICAgIGxvYWRTU0hVc2VycygpOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIENPUFkg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGNvcHlMaW5rKGlkLCBidG4pIHsKICBjb25zdCB0eHQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkudGV4dENvbnRlbnQ7CiAgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQodHh0KS50aGVuKCgpPT57CiAgICBjb25zdCBvcmlnID0gYnRuLnRleHRDb250ZW50OwogICAgYnRuLnRleHRDb250ZW50PSfinIUgQ29waWVkISc7IGJ0bi5zdHlsZS5iYWNrZ3JvdW5kPSdyZ2JhKDM0LDE5Nyw5NCwuMTUpJzsKICAgIHNldFRpbWVvdXQoKCk9PnsgYnRuLnRleHRDb250ZW50PW9yaWc7IGJ0bi5zdHlsZS5iYWNrZ3JvdW5kPScnOyB9LCAyMDAwKTsKICB9KS5jYXRjaCgoKT0+eyBwcm9tcHQoJ0NvcHkgbGluazonLCB0eHQpOyB9KTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIExPR09VVCDilZDilZDilZDilZAKZnVuY3Rpb24gZG9Mb2dvdXQoKSB7CiAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShTRVNTSU9OX0tFWSk7CiAgbG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOwp9CgovLyDilZDilZDilZDilZAgSU5JVCDilZDilZDilZDilZAKbG9hZERhc2goKTsKbG9hZFNlcnZpY2VzKCk7CnNldEludGVydmFsKGxvYWREYXNoLCAzMDAwMCk7Cjwvc2NyaXB0PgoKPCEtLSBTU0ggUkVORVcgTU9EQUwgLS0+CjxkaXYgY2xhc3M9Im1vdmVyIiBpZD0ic3NoLXJlbmV3LW1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNsb3NlU1NIUmVuZXdNb2RhbCgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCBTU0ggVXNlcjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJtY2xvc2UiIG9uY2xpY2s9ImNsb3NlU1NIUmVuZXdNb2RhbCgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIFVzZXJuYW1lPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9InNzaC1yZW5ldy11c2VybmFtZSI+LS08L3NwYW4+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImZnIiBzdHlsZT0ibWFyZ2luLXRvcDoxNHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZ4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+CiAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gtcmVuZXctZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSIgcGxhY2Vob2xkZXI9IjMwIj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9InNzaC1yZW5ldy1idG4iIG9uY2xpY2s9ImRvU1NIUmVuZXcoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4reC4reC4suC4ouC4uDwvYnV0dG9uPgogIDwvZGl2Pgo8L2Rpdj4KCjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/sshws.html
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
                # get onlines (3x-ui ต้องใช้ POST method, empty body)
                import json as _json2
                req = urllib.request.Request(
                    f'http://127.0.0.1:{xui_port}/panel/api/inbounds/onlines',
                    data=b'', method='POST'
                )
                resp = opener.open(req, timeout=5)
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
            # Stream script update log back to client via chunked response
            # รองรับ interactive input ผ่าน PTY + session id
            import subprocess, threading, pty, select, fcntl, termios, struct
            SCRIPT_URL = data.get('url', 'https://raw.githubusercontent.com/Chaiyakey99/chaiya-vpn/main/chaiya-setup-v5-combined.sh').strip()
            if not SCRIPT_URL.startswith('https://'):
                return respond(self, 400, {'ok': False, 'error': 'URL ไม่ถูกต้อง'})
            # สร้าง session id สำหรับ interactive input
            import uuid as _uuid
            sid = _uuid.uuid4().hex
            if not hasattr(Handler, '_update_sessions'):
                Handler._update_sessions = {}
            sess = {'fd': None, 'proc': None, 'done': False}
            Handler._update_sessions[sid] = sess
            def stream_update():
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain; charset=utf-8')
                self.send_header('Transfer-Encoding', 'chunked')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.send_header('Cache-Control', 'no-cache')
                self.send_header('X-Accel-Buffering', 'no')
                self.end_headers()
                def write_chunk(text):
                    try:
                        b = text.encode('utf-8', errors='replace')
                        self.wfile.write(('%x\r\n' % len(b)).encode())
                        self.wfile.write(b)
                        self.wfile.write(b'\r\n')
                        self.wfile.flush()
                    except: pass
                try:
                    # ส่ง session id ให้ frontend ผ่าน marker บรรทัดแรก
                    write_chunk('__SID__:' + sid + '\n')
                    write_chunk('[INFO] ดาวน์โหลด script จาก ' + SCRIPT_URL + '\n')
                    import tempfile, os, hashlib
                    tmp = tempfile.mktemp(suffix='.sh')
                    rc = subprocess.call(['curl', '-fsSL', '-o', tmp, SCRIPT_URL])
                    if rc != 0 or not os.path.exists(tmp):
                        write_chunk('[ERR] ดาวน์โหลดไม่สำเร็จ\n')
                        write_chunk('__DONE_FAIL__\n')
                        self.wfile.write(b'0\r\n\r\n')
                        return
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
                    # รันผ่าน PTY เพื่อให้ interactive (read -p) ทำงานได้
                    master_fd, slave_fd = pty.openpty()
                    # ตั้ง terminal size
                    try:
                        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
                    except: pass
                    proc = subprocess.Popen(
                        ['bash', tmp],
                        stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
                        close_fds=True, preexec_fn=os.setsid
                    )
                    os.close(slave_fd)
                    sess['fd'] = master_fd
                    sess['proc'] = proc
                    buf = b''
                    while True:
                        try:
                            r, _, _ = select.select([master_fd], [], [], 0.3)
                        except (OSError, ValueError):
                            break
                        if master_fd in r:
                            try:
                                chunk = os.read(master_fd, 4096)
                            except OSError:
                                break
                            if not chunk:
                                break
                            buf += chunk
                            # ส่งทุกข้อมูล (แม้จะไม่มี newline — สำคัญสำหรับ prompt)
                            try:
                                text = buf.decode('utf-8', errors='replace')
                                buf = b''
                                write_chunk(text)
                            except: pass
                        if proc.poll() is not None:
                            # อ่านข้อมูลที่เหลือ
                            try:
                                while True:
                                    chunk = os.read(master_fd, 4096)
                                    if not chunk: break
                                    try: write_chunk(chunk.decode('utf-8', errors='replace'))
                                    except: pass
                            except OSError: pass
                            break
                    try: os.close(master_fd)
                    except: pass
                    try: os.remove(tmp)
                    except: pass
                    sess['done'] = True
                    if proc.returncode == 0:
                        write_chunk('\n[OK] อัพเดตเสร็จสิ้น ✅\n')
                        write_chunk('__DONE_OK__\n')
                    else:
                        write_chunk('\n[ERR] อัพเดตล้มเหลว (exit ' + str(proc.returncode) + ')\n')
                        write_chunk('__DONE_FAIL__\n')
                except Exception as ex:
                    write_chunk('[ERR] ' + str(ex) + '\n')
                    write_chunk('__DONE_FAIL__\n')
                finally:
                    sess['done'] = True
                    try: Handler._update_sessions.pop(sid, None)
                    except: pass
                try:
                    self.wfile.write(b'0\r\n\r\n')
                    self.wfile.flush()
                except: pass
            t = threading.Thread(target=stream_update)
            t.daemon = True
            t.start()
            t.join()
            return

        elif self.path == '/api/update_input':
            # ส่ง input ไปยัง interactive process ที่กำลังรัน
            import os as _os
            sid = data.get('sid', '').strip()
            text = data.get('input', '')
            if not sid or not hasattr(Handler, '_update_sessions'):
                return respond(self, 400, {'ok': False, 'error': 'no session'})
            sess = Handler._update_sessions.get(sid)
            if not sess or sess.get('done') or not sess.get('fd'):
                return respond(self, 400, {'ok': False, 'error': 'session not active'})
            try:
                # เพิ่ม newline ถ้าไม่มี
                if not text.endswith('\n'):
                    text = text + '\n'
                _os.write(sess['fd'], text.encode('utf-8'))
                respond(self, 200, {'ok': True})
            except Exception as e:
                respond(self, 500, {'ok': False, 'error': str(e)})

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
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVU
Ri04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwg
aW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8
bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0
cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNw
bGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAj
MjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgz
NCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0t
bmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNm
MGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7
CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCww
LjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30K
ICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNl
cmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9
CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBw
eDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpsaW5lYXIt
Z3JhZGllbnQoMTYwZGVnLCMxYTBhMmUgMCUsIzBmMGExZSA1NSUsIzBhMGEwZiAxMDAlKTtwYWRk
aW5nOjI4cHggMjBweCAyMnB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292
ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0
ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdy
YWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVu
dCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6
ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJn
aW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9z
cGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3Bh
Y2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7
bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1
KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2
cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFw
eCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6
NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNv
cjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tn
cm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9y
ZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5
O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9
CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17Zmxl
eDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9y
OnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFj
ZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjph
bGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9t
LWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGlu
ZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZl
e2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3Jt
OnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQog
IC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3Jk
ZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bv
c2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7
fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250
ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQt
ZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5n
OjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9y
ZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4
IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2Zv
bnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0
bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dy
aWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21h
cmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFw
eCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9z
aXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9
CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDts
ZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30K
ICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtm
b250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBz
cGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQog
IC5zc3Vie2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiM0YTU1Njg7bWFyZ2luLXRvcDo0cHg7fQogIC5k
bnV0e3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjUycHg7aGVpZ2h0OjUycHg7bWFyZ2luOjRweCBh
dXRvIDRweDt9CiAgLmRudXQgc3Zne3RyYW5zZm9ybTpyb3RhdGUoLTkwZGVnKTt9CiAgLmRiZ3tm
aWxsOm5vbmU7c3Ryb2tlOnJnYmEoMCwwLDAsMC4wNik7c3Ryb2tlLXdpZHRoOjQ7fQogIC5kdntm
aWxsOm5vbmU7c3Ryb2tlLXdpZHRoOjQ7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7dHJhbnNpdGlvbjpz
dHJva2UtZGFzaG9mZnNldCAxcyBlYXNlO30KICAuZGN7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6
MDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7
Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEycHg7Zm9udC13ZWln
aHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5wYntoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdi
YSgwLDAsMCwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpo
aWRkZW47fQogIC5wZntoZWlnaHQ6MTAwJTtib3JkZXItcmFkaXVzOjJweDt0cmFuc2l0aW9uOndp
ZHRoIDFzIGVhc2U7fQogIC5wZi5wdXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2
YXIoLS1hYyksIzE2YTM0YSk7fQogIC5wZi5wZ3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5
MGRlZyx2YXIoLS1uZyksIzE2YTM0YSk7fQogIC5wZi5wb3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFk
aWVudCg5MGRlZywjZmI5MjNjLCNmOTczMTYpO30KICAucGYucHJ7YmFja2dyb3VuZDpsaW5lYXIt
Z3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KTt9CiAgLnViZGd7ZGlzcGxheTpmbGV4O2dh
cDo1cHg7ZmxleC13cmFwOndyYXA7bWFyZ2luLXRvcDo4cHg7fQogIC5iZGd7YmFja2dyb3VuZDoj
ZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjZweDtw
YWRkaW5nOjNweCA4cHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFt
aWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAubmV0LXJvd3tkaXNwbGF5OmZsZXg7anVzdGlm
eS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEycHg7bWFyZ2luLXRvcDoxMHB4O30KICAubml7
ZmxleDoxO30KICAubmR7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tYWMpO21hcmdpbi1ib3R0
b206M3B4O30KICAubnN7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXpl
OjIwcHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5ucyBzcGFue2ZvbnQt
c2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5udHtmb250
LXNpemU6MTJweDtjb2xvcjojNGE1NTY4O21hcmdpbi10b3A6MnB4O30KICAuZGl2aWRlcnt3aWR0
aDoxcHg7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpO21hcmdpbjo0cHggMDt9CiAgLm9waWxse2Jh
Y2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3
LDk0LDAuMyk7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6NXB4IDE0cHg7Zm9udC1zaXplOjEy
cHg7Y29sb3I6dmFyKC0tbmcpO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVy
O2dhcDo1cHg7d2hpdGUtc3BhY2U6bm93cmFwO30KICAub3BpbGwub2Zme2JhY2tncm91bmQ6cmdi
YSgyMzksNjgsNjgsMC4xKTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4zKTtjb2xvcjoj
ZWY0NDQ0O30KICAuZG90e3dpZHRoOjdweDtoZWlnaHQ6N3B4O2JvcmRlci1yYWRpdXM6NTAlO2Jh
Y2tncm91bmQ6dmFyKC0tbmcpO2JveC1zaGFkb3c6MCAwIDhweCB2YXIoLS1uZyksMCAwIDE2cHgg
dmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgMXMgaW5maW5pdGU7fQogIC5kb3QucmVke2JhY2tncm91
bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA4cHggI2VmNDQ0NCwwIDAgMTZweCAjZWY0NDQ0O2Fu
aW1hdGlvbjpwbHMtcmVkIDFzIGluZmluaXRlO30KICBAa2V5ZnJhbWVzIHBsc3swJSw0NSV7b3Bh
Y2l0eToxO3RyYW5zZm9ybTpzY2FsZSgxLjMpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMzQs
MTk3LDk0LDAuMzUpLDAgMCAxMnB4IHZhcigtLW5nKSwwIDAgMjRweCB2YXIoLS1uZyl9NTUlLDEw
MCV7b3BhY2l0eTowLjI7dHJhbnNmb3JtOnNjYWxlKDAuODUpO2JveC1zaGFkb3c6bm9uZX19CiAg
Lnh1aS1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4t
dG9wOjEwcHg7fQogIC54dWktaW5mb3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7
bGluZS1oZWlnaHQ6MS43O30KICAueHVpLWluZm8gYntjb2xvcjp2YXIoLS10eHQpO30KICAuc3Zj
LWxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O21hcmdpbi10
b3A6MTBweDt9CiAgLnN2Y3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMDUpO2JvcmRlcjox
cHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzox
MXB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6
c3BhY2UtYmV0d2Vlbjt9CiAgLnN2Yy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4w
NSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMik7fQogIC5zdmMtbHtkaXNwbGF5OmZs
ZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O30KICAuZGd7d2lkdGg6MTBweDtoZWlnaHQ6
MTBweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAg
MCA4cHggdmFyKC0tbmcpO2ZsZXgtc2hyaW5rOjA7YW5pbWF0aW9uOnBscyAwLjlzIGVhc2UtaW4t
b3V0IGluZmluaXRlO30KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAg
MCA4cHggI2VmNDQ0NCwwIDAgMTZweCAjZWY0NDQ0O2FuaW1hdGlvbjpwbHMtcmVkIDFzIGluZmlu
aXRlO30KICAuZGcub3Jhbmdle2JhY2tncm91bmQ6I2Y5NzMxNjtib3gtc2hhZG93OjAgMCA4cHgg
I2Y5NzMxNiwwIDAgMTZweCAjZjk3MzE2O2FuaW1hdGlvbjpwbHMtb3JhbmdlIDFzIGluZmluaXRl
O30KICBAa2V5ZnJhbWVzIHBscy1vcmFuZ2V7MCUsNDUle29wYWNpdHk6MTt0cmFuc2Zvcm06c2Nh
bGUoMS4zKTtib3gtc2hhZG93OjAgMCAwIDNweCByZ2JhKDI0OSwxMTUsMjIsMC4zNSksMCAwIDEy
cHggI2Y5NzMxNiwwIDAgMjRweCAjZjk3MzE2fTU1JSwxMDAle29wYWNpdHk6MC4yO3RyYW5zZm9y
bTpzY2FsZSgwLjg1KTtib3gtc2hhZG93Om5vbmV9fQogIC5yYmRnLndhcm57YmFja2dyb3VuZDpy
Z2JhKDI0OSwxMTUsMjIsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ5LDExNSwyMiwwLjMp
O2NvbG9yOiNmOTczMTY7fQogIEBrZXlmcmFtZXMgcGxzLXJlZHswJSw0NSV7b3BhY2l0eToxO3Ry
YW5zZm9ybTpzY2FsZSgxLjMpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMjM5LDY4LDY4LDAu
MzUpLDAgMCAxMnB4ICNlZjQ0NDQsMCAwIDI0cHggI2VmNDQ0NH01NSUsMTAwJXtvcGFjaXR5OjAu
Mjt0cmFuc2Zvcm06c2NhbGUoMC44NSk7Ym94LXNoYWRvdzpub25lfX0KICAuc3ZjLW57Zm9udC1z
aXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtcHtmb250
LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtjb2xvcjojNGE1NTY4
O30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xp
ZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7
Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9u
b3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEo
MjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2Vm
NDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigt
LW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7
bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9u
b3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRl
ZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2Fw
OjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZh
cigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6
MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNw
bGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRk
aW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjti
b3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZh
cigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFs
bCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNv
bG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7
fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7
bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1i
b3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFw
eCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4
O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNh
bnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZp
OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0t
YWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3Bh
ZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVy
O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6
dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246
YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXIt
Y29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRk
aW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0Ojcw
MDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgx
MzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1Nh
cmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1
cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7
Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5z
bGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxv
d2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFm
Yztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRp
bmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6
J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFu
c2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIo
LS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1i
b3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7
YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1i
b3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAg
MXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZh
cigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWln
aHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVy
O2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7
Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hy
aW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFy
KC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNr
Z3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNv
bGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4
LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwu
Mik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0
KTt9CiAgLnVte2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiM0YTU1Njg7bWFyZ2luLXRvcDoycHg7fQog
IC5hYmRne2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7
Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5hYmRnLm9re2JhY2tncm91bmQ6
cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4zKTtj
b2xvcjp2YXIoLS1uZyk7fQogIC5hYmRnLmV4cHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAu
MSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMyk7Y29sb3I6I2VmNDQ0NDt9CiAg
LmFiZGcuc29vbntiYWNrZ3JvdW5kOnJnYmEoMjUxLDE0Niw2MCwwLjEpO2JvcmRlcjoxcHggc29s
aWQgcmdiYSgyNTEsMTQ2LDYwLC4zKTtjb2xvcjojZjk3MzE2O30KICAubW92ZXJ7cG9zaXRpb246
Zml4ZWQ7aW5zZXQ6MDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjUpO2JhY2tkcm9wLWZpbHRlcjpi
bHVyKDZweCk7ei1pbmRleDoxMDA7ZGlzcGxheTpub25lO2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1
c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5tb3Zlci5vcGVue2Rpc3BsYXk6ZmxleDt9CiAgLm1v
ZGFse2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVy
LXJhZGl1czoyMHB4IDIwcHggMCAwO3dpZHRoOjEwMCU7bWF4LXdpZHRoOjQ4MHB4O3BhZGRpbmc6
MjBweDttYXgtaGVpZ2h0Ojg1dmg7b3ZlcmZsb3cteTphdXRvO2FuaW1hdGlvbjpzdSAuM3MgZWFz
ZTtib3gtc2hhZG93OjAgLTRweCAzMHB4IHJnYmEoMCwwLDAsMC4xMik7fQogIEBrZXlmcmFtZXMg
c3V7ZnJvbXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgxMDAlKX10b3t0cmFuc2Zvcm06dHJhbnNsYXRl
WSgwKX19CiAgLm1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNv
bnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjE2cHg7fQogIC5tdGl0bGV7Zm9udC1m
YW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Y29sb3I6dmFyKC0tdHh0
KTt9CiAgLm1jbG9zZXt3aWR0aDozMnB4O2hlaWdodDozMnB4O2JvcmRlci1yYWRpdXM6NTAlO2Jh
Y2tncm91bmQ6I2YxZjVmOTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Y29sb3I6dmFy
KC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxNnB4O2Rpc3BsYXk6ZmxleDthbGln
bi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLmRncmlke2JhY2tncm91
bmQ6I2Y4ZmFmYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi1ib3R0b206
MTRweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcntkaXNwbGF5OmZsZXg7
anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6
N3B4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRyOmxhc3Qt
Y2hpbGR7Ym9yZGVyLWJvdHRvbTpub25lO30KICAuZGt7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFy
KC0tbXV0ZWQpO30KICAuZHZ7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tdHh0KTtmb250LXdl
aWdodDo2MDA7fQogIC5kdi5ncmVlbntjb2xvcjp2YXIoLS1uZyk7fQogIC5kdi5yZWR7Y29sb3I6
I2VmNDQ0NDt9CiAgLmR2Lm1vbm97Y29sb3I6dmFyKC0tYWMpO2ZvbnQtc2l6ZTo5cHg7Zm9udC1m
YW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7fQogIC5hZ3Jp
ZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDt9CiAg
Lm0tc3Vie2Rpc3BsYXk6bm9uZTttYXJnaW4tdG9wOjE0cHg7YmFja2dyb3VuZDojZjhmYWZjO2Jv
cmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzox
NHB4O30KICAubS1zdWIub3BlbntkaXNwbGF5OmJsb2NrO2FuaW1hdGlvbjpmaSAuMnMgZWFzZTt9
CiAgLm1zdWItbGJse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10
eHQpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLmFidG57YmFja2dyb3VuZDojZjhmYWZjO2JvcmRl
cjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4
IDEwcHg7dGV4dC1hbGlnbjpjZW50ZXI7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjJz
O30KICAuYWJ0bjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZh
cigtLWFjKTt9CiAgLmFidG4gLmFpe2ZvbnQtc2l6ZToyMnB4O21hcmdpbi1ib3R0b206NnB4O30K
ICAuYWJ0biAuYW57Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4
dCk7fQogIC5hYnRuIC5hZHtmb250LXNpemU6MTJweDtjb2xvcjojMzc0MTUxO2ZvbnQtd2VpZ2h0
OjUwMDttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdi
YSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWdu
OmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJn
aW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNw
eDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdp
bi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtm
b250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5y
ZXMtY2xvc2V7cG9zaXRpb246YWJzb2x1dGU7dG9wOi0xMXB4O3JpZ2h0Oi0xMXB4O3dpZHRoOjIy
cHg7aGVpZ2h0OjIycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2JvcmRl
cjoycHggc29saWQgI2ZmZjtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4
O2ZvbnQtd2VpZ2h0OjcwMDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnkt
Y29udGVudDpjZW50ZXI7bGluZS1oZWlnaHQ6MTtib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDIz
OSw2OCw2OCwwLjQpO3otaW5kZXg6Mjt9CiAgLnJlcy1ib3h7cG9zaXRpb246cmVsYXRpdmU7YmFj
a2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztib3JkZXItcmFkaXVzOjEw
cHg7cGFkZGluZzoxNHB4O21hcmdpbi10b3A6MTRweDtkaXNwbGF5Om5vbmU7fQogIC5yZXMtYm94
LnNob3d7ZGlzcGxheTpibG9jazt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29u
dGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQg
I2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90
dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQog
IC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFr
LWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3Jv
dW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6
OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9u
Jyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFy
KC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5n
OjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7
YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtj
dXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxl
cnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRp
dXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tn
cm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAg
LmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2Nv
bG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9j
azt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1
NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpz
cCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6
NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxv
YWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtm
b250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwog
IC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFk
ZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZs
Ymx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJr
LWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29s
aWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7
fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUs
LjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFy
ay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAu
ZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFt
aWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9t
OjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0
IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1u
czoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dy
b3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1
NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246
Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5w
Yi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAu
cGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVt
O2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7
Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuNjUpO30KICAucG9ydC1idG4u
YWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1
LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1i
dG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZl
LXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4
KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4u
YWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2Vy
ICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAx
ZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJn
YmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwu
MDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVy
O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250
LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFt
aWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7
bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjEwcHg7Y29sb3I6
cmdiYSgyNTUsMjU1LDI1NSwuNik7fQogIC5waWNrLW9wdC5hLWR0YWN7Ym9yZGVyLWNvbG9yOiNm
ZjY2MDA7YmFja2dyb3VuZDpyZ2JhKDI1NSwxMDIsMCwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCBy
Z2JhKDI1NSwxMDIsMCwuMTUpO30KICAucGljay1vcHQuYS1kdGFjIC5wbntjb2xvcjojZmY4ODMz
O30KICAucGljay1vcHQuYS10cnVle2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdi
YSgwLDIwMCwyNTUsLjEpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9
CiAgLnBpY2stb3B0LmEtdHJ1ZSAucG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtbnB2
e2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdiYSgwLDIwMCwyNTUsLjA4KTtib3gt
c2hhZG93OjAgMCAxMHB4IHJnYmEoMCwyMDAsMjU1LC4xMik7fQogIC5waWNrLW9wdC5hLW5wdiAu
cG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtZGFya3tib3JkZXItY29sb3I6I2NjNjZm
ZjtiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdi
YSgxNTMsNTEsMjU1LC4xKTt9CiAgLnBpY2stb3B0LmEtZGFyayAucG57Y29sb3I6I2NjNjZmZjt9
CiAgLyogQ3JlYXRlIGJ0biAoc3NoIGRhcmspICovCiAgLmNidG4tc3Noe2JhY2tncm91bmQ6dHJh
bnNwYXJlbnQ7Ym9yZGVyOjJweCBzb2xpZCAjMjJjNTVlO2NvbG9yOiMyMmM1NWU7Zm9udC1zaXpl
OjEzcHg7d2lkdGg6YXV0bztwYWRkaW5nOjEwcHggMjhweDtib3JkZXItcmFkaXVzOjEwcHg7Y3Vy
c29yOnBvaW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNl
cmlmO3RyYW5zaXRpb246YWxsIC4ycztkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNl
bnRlcjtnYXA6NnB4O30KICAuY2J0bi1zc2g6aG92ZXJ7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5
NCwuMSk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDM0LDE5Nyw5NCwuMik7fQogIC8qIExpbmsg
cmVzdWx0ICovCiAgLmxpbmstcmVzdWx0e2Rpc3BsYXk6bm9uZTttYXJnaW4tdG9wOjEycHg7Ym9y
ZGVyLXJhZGl1czoxMHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLmxpbmstcmVzdWx0LnNob3d7ZGlz
cGxheTpibG9jazt9CiAgLmxpbmstcmVzdWx0LWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6
Y2VudGVyO2dhcDo4cHg7cGFkZGluZzo4cHggMTJweDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjMp
O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjA2KTt9CiAgLmltcC1i
YWRnZXtmb250LXNpemU6LjYycmVtO2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzoxLjVw
eDtwYWRkaW5nOi4xOHJlbSAuNTVyZW07Ym9yZGVyLXJhZGl1czo5OXB4O30KICAuaW1wLWJhZGdl
Lm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4xNSk7Y29sb3I6IzAwY2NmZjtib3JkZXI6
MXB4IHNvbGlkIHJnYmEoMCwxODAsMjU1LC4zKTt9CiAgLmltcC1iYWRnZS5kYXJre2JhY2tncm91
bmQ6cmdiYSgxNTMsNTEsMjU1LC4xNSk7Y29sb3I6I2NjNjZmZjtib3JkZXI6MXB4IHNvbGlkIHJn
YmEoMTUzLDUxLDI1NSwuMyk7fQogIC5saW5rLXByZXZpZXd7YmFja2dyb3VuZDojMDYwYTEyO2Jv
cmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2Zv
bnQtc2l6ZTouNTZyZW07Y29sb3I6IzAwYWFkZDt3b3JkLWJyZWFrOmJyZWFrLWFsbDtsaW5lLWhl
aWdodDoxLjY7bWFyZ2luOjhweCAxMnB4O2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE1MCwyNTUs
LjE1KTttYXgtaGVpZ2h0OjU0cHg7b3ZlcmZsb3c6aGlkZGVuO3Bvc2l0aW9uOnJlbGF0aXZlO30K
ICAubGluay1wcmV2aWV3LmRhcmstbHB7Ym9yZGVyLWNvbG9yOnJnYmEoMTUzLDUxLDI1NSwuMjIp
O2NvbG9yOiNhYTU1ZmY7fQogIC5saW5rLXByZXZpZXc6OmFmdGVye2NvbnRlbnQ6Jyc7cG9zaXRp
b246YWJzb2x1dGU7Ym90dG9tOjA7bGVmdDowO3JpZ2h0OjA7aGVpZ2h0OjE0cHg7YmFja2dyb3Vu
ZDpsaW5lYXItZ3JhZGllbnQodHJhbnNwYXJlbnQsIzA2MGExMik7fQogIC5jb3B5LWxpbmstYnRu
e3dpZHRoOmNhbGMoMTAwJSAtIDI0cHgpO21hcmdpbjowIDEycHggMTBweDtwYWRkaW5nOi41NXJl
bTtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6LjgycmVtO2ZvbnQtd2VpZ2h0OjcwMDtjdXJz
b3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtib3JkZXI6MXB4IHNv
bGlkO30KICAuY29weS1saW5rLWJ0bi5ucHZ7YmFja2dyb3VuZDpyZ2JhKDAsMTgwLDI1NSwuMDcp
O2JvcmRlci1jb2xvcjpyZ2JhKDAsMTgwLDI1NSwuMjgpO2NvbG9yOiMwMGNjZmY7fQogIC5jb3B5
LWxpbmstYnRuLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjA3KTtib3JkZXItY29s
b3I6cmdiYSgxNTMsNTEsMjU1LC4yOCk7Y29sb3I6I2NjNjZmZjt9CiAgLyogVXNlciB0YWJsZSAq
LwogIC51dGJsLXdyYXB7b3ZlcmZsb3cteDphdXRvO21hcmdpbi10b3A6MTBweDt9CiAgLnV0Ymx7
d2lkdGg6MTAwJTtib3JkZXItY29sbGFwc2U6Y29sbGFwc2U7Zm9udC1zaXplOjEycHg7fQogIC51
dGJsIHRoe3BhZGRpbmc6OHB4IDEwcHg7dGV4dC1hbGlnbjpsZWZ0O2ZvbnQtZmFtaWx5OidPcmJp
dHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6MS41cHg7Y29sb3I6
dmFyKC0tbXV0ZWQpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC51
dGJsIHRke3BhZGRpbmc6OXB4IDEwcHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9y
ZGVyKTt9CiAgLnV0YmwgdHI6bGFzdC1jaGlsZCB0ZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5i
ZGd7cGFkZGluZzoycHggOHB4O2JvcmRlci1yYWRpdXM6MjBweDtmb250LXNpemU6MTBweDtmb250
LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXdlaWdodDo3MDA7fQogIC5iZGctZ3ti
YWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3
LDk0LC4zKTtjb2xvcjojMjJjNTVlO30KICAuYmRnLXJ7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2
OCwuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMyk7Y29sb3I6I2VmNDQ0NDt9
CiAgLmJ0bi10Ymx7d2lkdGg6MzBweDtoZWlnaHQ6MzBweDtib3JkZXItcmFkaXVzOjhweDtib3Jk
ZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2N1cnNvcjpwb2lu
dGVyO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVu
dDpjZW50ZXI7Zm9udC1zaXplOjE0cHg7fQogIC5idG4tdGJsOmhvdmVye2JvcmRlci1jb2xvcjp2
YXIoLS1hYyk7fQogIC8qIFJlbmV3IGRheXMgYmFkZ2UgKi8KICAuZGF5cy1iYWRnZXtmb250LWZh
bWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtwYWRkaW5nOjJweCA4cHg7
Ym9yZGVyLXJhZGl1czoyMHB4O2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjA4KTtib3JkZXI6
MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4yKTtjb2xvcjp2YXIoLS1hYyk7fQoKICAvKiDilIDi
lIAgU0VMRUNUT1IgQ0FSRFMg4pSA4pSAICovICAvKiDilIDilIAgU0VMRUNUT1IgQ0FSRFMg4pSA
4pSAICovCiAgLnNlYy1sYWJlbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250
LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzo2
cHggMnB4IDEwcHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO30KICAuc2VsLWNhcmR7YmFja2dy
b3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjE2
cHg7cGFkZGluZzoxNnB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjE0cHg7
Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjJzO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93
KTttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5zZWwtY2FyZDpob3Zlcntib3JkZXItY29sb3I6dmFy
KC0tYWMpO2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgycHgp
O30KICAuc2VsLWxvZ297d2lkdGg6NjRweDtoZWlnaHQ6NjRweDtib3JkZXItcmFkaXVzOjE0cHg7
ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2Zs
ZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlze2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlk
ICNjNWU4OWE7fQogIC5zZWwtdHJ1ZXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3Noe2Jh
Y2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1haXMtc20sLnNlbC10cnVlLXNtLC5zZWwtc3NoLXNt
e3dpZHRoOjQ0cHg7aGVpZ2h0OjQ0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2Rpc3BsYXk6ZmxleDth
bGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmbGV4LXNocmluazowO30K
ICAuc2VsLWFpcy1zbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCAjYzVlODlhO30K
ICAuc2VsLXRydWUtc217YmFja2dyb3VuZDojYzgwNDBkO30KICAuc2VsLXNzaC1zbXtiYWNrZ3Jv
dW5kOiMxNTY1YzA7fQogIC5zZWwtaW5mb3tmbGV4OjE7bWluLXdpZHRoOjA7fQogIC5zZWwtbmFt
ZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6LjgycmVtO2ZvbnQt
d2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNlbC1uYW1lLmFpc3tjb2xvcjojM2Q3
YTBlO30KICAuc2VsLW5hbWUudHJ1ZXtjb2xvcjojYzgwNDBkO30KICAuc2VsLW5hbWUuc3Noe2Nv
bG9yOiMxNTY1YzA7fQogIC5zZWwtc3Vie2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiMzNzQxNTE7Zm9u
dC13ZWlnaHQ6NTAwO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40
cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBI
RUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2Vu
dGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2lu
dGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpo
b3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0
ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRw
eDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtm
b250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2Vp
Z2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdh
MGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3No
e2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTJweDtjb2xvcjojNGE1NTY4
O30KICAuY2J0bi1haXN7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMzZDdhMGUs
IzVhYWExOCk7fQogIC5jYnRuLXRydWV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVn
LCNhNjAwMGMsI2Q4MTAyMCk7fQogIC8qIEJhbiBjb3VudGRvd24gKi8KICBAa2V5ZnJhbWVzIHB1
bHNlLW9yYW5nZSB7CiAgICAwJSwxMDAle2JveC1zaGFkb3c6MCAwIDRweCByZ2JhKDI0OSwxMTUs
MjIsLjMpfQogICAgNTAle2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgyNDksMTE1LDIyLC42KX0K
ICB9CiAgI2Jhbm5lZC1saXN0IC51aXRlbSB7IGN1cnNvcjpkZWZhdWx0OyB9CiAgI2Jhbm5lZC1s
aXN0IC51aXRlbTpob3ZlciB7IGJvcmRlci1jb2xvcjpyZ2JhKDI0OSwxMTUsMjIsMC40KTtiYWNr
Z3JvdW5kOnJnYmEoMjQ5LDExNSwyMiwwLjA0KTsgfQo8L3N0eWxlPgo8c2NyaXB0IHNyYz0iaHR0
cHM6Ly9jZG5qcy5jbG91ZGZsYXJlLmNvbS9hamF4L2xpYnMvcXJjb2RlanMvMS4wLjAvcXJjb2Rl
Lm1pbi5qcyI+PC9zY3JpcHQ+CjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9IndyYXAiPgoKICA8
IS0tIEhFQURFUiAtLT4KICA8ZGl2IGNsYXNzPSJoZHIiPgogICAgPGJ1dHRvbiBjbGFzcz0ibG9n
b3V0IiBvbmNsaWNrPSJkb0xvZ291dCgpIj7ihqkg4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia
4LiaPC9idXR0b24+CiAgICA8ZGl2IGNsYXNzPSJoZHItc3ViIj5DSEFJWUEgVjJSQVkgUFJPIE1B
WDwvZGl2PgogICAgPGRpdiBjbGFzcz0iaGRyLXRpdGxlIj5VU0VSIDxzcGFuPkNSRUFUT1I8L3Nw
YW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJoZHItZGVzYyIgaWQ9Imhkci1kb21haW4iPnY1IMK3
IFNFQ1VSRSBQQU5FTDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIE5BViAtLT4KICA8ZGl2IGNsYXNz
PSJuYXYiPgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gYWN0aXZlIiBvbmNsaWNrPSJzdygnZGFz
aGJvYXJkJyx0aGlzKSI+8J+TiiDguYHguJTguIrguJrguK3guKPguYzguJQ8L2Rpdj4KICAgIDxk
aXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnY3JlYXRlJyx0aGlzKSI+4p6VIOC4quC4
o+C5ieC4suC4h+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xp
Y2s9InN3KCdtYW5hZ2UnLHRoaXMpIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4qjwv
ZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdvbmxpbmUnLHRoaXMp
Ij7wn5+iIOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0
ZW0iIG9uY2xpY2s9InN3KCdiYW4nLHRoaXMpIj7wn5qrIOC4m+C4peC4lOC5geC4muC4mTwvZGl2
PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCd1cGRhdGUnLHRoaXMpIj7i
rIbvuI8g4Lit4Lix4Lie4LmA4LiU4LiVPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ
4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIg
aWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFu
IGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRv
biBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7
IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJz
Z3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7i
mqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8
c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAg
ICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAg
ICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIy
IiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIi
IHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8
ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAg
ICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZh
cigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNs
YXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUi
PjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAg
IDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFz
cz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0i
MCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIy
NiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIg
Y3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ry
b2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAg
ICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2
PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2Zv
bnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0g
R0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJy
YW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcs
IzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNs
YXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+
CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+
PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0t
IEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0i
ZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAg
ICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwv
ZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9u
dC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGlt
ZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMi
PjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgog
ICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAg
PGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAg
PGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5z
IiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xh
c3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4K
ICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJu
aSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKG
kyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0t
PHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQt
ZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAg
IDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0
bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJv
dyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNs
YXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+
CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3g
uKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAg
ICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4
geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAg
IDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFy
Z2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklD
RSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9Imxv
YWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAg
ICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNz
PSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9k
aXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4
seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEt
LSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMi
IGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3
KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9
InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRp
diBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRp
diBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2lt
ZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgt
QUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlz
Lm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWln
aHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9u
dC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtq
dXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8
L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRp
diBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2
PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdT
IMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNw
YW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBj
bGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYg
Y2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtm
b250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2
IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5U
UlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3
IFBvcnQgODg4MCDCtyBXUyDCtyB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+
CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFu
PgogICAgICA8L2Rpdj4KCiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCIgc3R5bGU9Im1hcmdp
bi10b3A6MjBweCI+8J+UkSDguKPguLDguJrguJogU1NIIFdFQlNPQ0tFVDwvZGl2PgogICAgICA8
ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3NzaCcpIj4KICAgICAgICA8
ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtc3NoIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJl
bTtmb250LXdlaWdodDo3MDA7Y29sb3I6I2ZmZjtmb250LWZhbWlseTptb25vc3BhY2UiPlNTSCZn
dDs8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAg
PGRpdiBjbGFzcz0ic2VsLW5hbWUgc3NoIj5TU0gg4oCTIFdTIFR1bm5lbDwvZGl2PgogICAgICAg
ICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+U1NIIMK3IFBvcnQgODAgwrcgRHJvcGJlYXIgMTQzLzEw
OTxicj5OcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAg
PHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2
PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IEFJUyDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3Jt
LWFpcyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIg
b25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBj
bGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgYWlzLWhkciI+CiAgICAg
ICAgICA8ZGl2IGNsYXNzPSJmb3JtLWxvZ28gc2VsLWFpcy1zbSI+PHNwYW4gc3R5bGU9ImZvbnQt
c2l6ZTouOHJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2
PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSBhaXMi
PkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xh
c3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgU05JOiBjai1lYmIuc3BlZWR0ZXN0
Lm5ldDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBj
bGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLg
uLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWVtYWlsIiBwbGFjZWhvbGRlcj0i
dXNlckBhaXMiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJs
Ij7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4
geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWRheXMiIHR5cGU9Im51bWJl
ciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2
IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFp
cy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2
IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI
4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZ2IiIHR5cGU9
Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0i
Y2J0biBjYnRuLWFpcyIgaWQ9ImFpcy1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCdhaXMnKSI+
4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xh
c3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMt
Ym94IiBpZD0iYWlzLXJlc3VsdCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PGJ1dHRvbiBjbGFzcz0i
cmVzLWNsb3NlIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLXJlc3VsdCcp
LnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9
InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFz
cz0icmVzLXYiIGlkPSJyLWFpcy1lbWFpbCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2
IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfhpQgVVVJRDwvc3Bhbj48c3Bh
biBjbGFzcz0icmVzLXYgbW9ubyIgaWQ9InItYWlzLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAg
ICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4
oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLWFp
cy1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlk
PSJyLWFpcy1saW5rIj4tLTwvZGl2PgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY29weS1idG4i
IG9uY2xpY2s9ImNvcHlMaW5rKCdyLWFpcy1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExp
bms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9ImFpcy1xciIgc3R5bGU9InRleHQtYWxpZ246
Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rp
dj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFRSVUUg4pSA4pSAIC0tPgogICAg
PGRpdiBpZD0iZm9ybS10cnVlIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFz
cz0iZm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2
PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciB0
cnVlLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtdHJ1ZS1zbSI+PHNw
YW4gc3R5bGU9ImZvbnQtc2l6ZTouNzVyZW07Zm9udC13ZWlnaHQ6OTAwO2NvbG9yOiNmZmYiPnRy
dWU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJm
b3JtLXRpdGxlIHRydWUiPlRSVUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNz
PSJmb3JtLXN1YiI+VkxFU1MgwrcgUG9ydCA4ODgwIMK3IFNOSTogdHJ1ZS1pbnRlcm5ldC56b29t
Lnh5ei5zZXJ2aWNlczwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAg
ICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfg
uYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1lbWFpbCIgcGxh
Y2Vob2xkZXI9InVzZXJAdHJ1ZSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYg
Y2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih
4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWRheXMi
IHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xh
c3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNz
PSJmaSIgaWQ9InRydWUtaXAiIHR5cGU9Im51bWJlciIgdmFsdWU9IjIiIG1pbj0iMSI+PC9kaXY+
CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkr4gRGF0YSBHQiAo
MCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0i
dHJ1ZS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8
YnV0dG9uIGNsYXNzPSJjYnRuIGNidG4tdHJ1ZSIgaWQ9InRydWUtYnRuIiBvbmNsaWNrPSJjcmVh
dGVWTEVTUygndHJ1ZScpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIFRSVUUgQWNjb3VudDwvYnV0dG9u
PgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0idHJ1ZS1hbGVydCI+PC9kaXY+CiAgICAg
ICAgPGRpdiBjbGFzcz0icmVzLWJveCIgaWQ9InRydWUtcmVzdWx0IiBzdHlsZT0iZGlzcGxheTpu
b25lIj48YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCd0cnVlLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4K
ICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBF
bWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXRydWUtZW1haWwiPi0tPC9zcGFu
PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1r
Ij7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLXRydWUtdXVp
ZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBj
bGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNz
PSJyZXMtdiBncmVlbiIgaWQ9InItdHJ1ZS1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAg
PGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLXRydWUtbGluayI+LS08L2Rpdj4KICAgICAgICAg
IDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci10cnVlLWxpbmsn
LHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0i
dHJ1ZS1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2
PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSA
IEZPUk06IFNTSCDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXNzaCIgc3R5bGU9ImRpc3Bs
YXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3Jt
KCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3NoLWRhcmstZm9y
bSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPuKelSDguYDguJ7guLTguYjguKEgU1NI
IFVTRVI8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiK
4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNz
aC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9
ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2Rpdj48aW5w
dXQgY2xhc3M9ImZpIiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgdHlwZT0i
cGFzc3dvcmQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJs
Ij7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3No
LWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxk
aXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKXguLTguKHguLTguJXguYTguK3guJ7g
uLU8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVl
PSIyIiBtaW49IjEiPjwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9
Im1hcmdpbi10b3A6NHB4Ij7inIjvuI8g4LmA4Lil4Li34Lit4LiBIFBPUlQ8L2Rpdj4KICAgICAg
ICA8ZGl2IGNsYXNzPSJwb3J0LWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4g
YWN0aXZlLXA4MCIgaWQ9InBiLTgwIiBvbmNsaWNrPSJwaWNrUG9ydCgnODAnKSI+CiAgICAgICAg
ICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCfjJA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFz
cz0icGItbmFtZSI+UG9ydCA4MDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1zdWIi
PldTIMK3IEhUVFA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0i
cG9ydC1idG4iIGlkPSJwYi00NDMiIG9uY2xpY2s9InBpY2tQb3J0KCc0NDMnKSI+CiAgICAgICAg
ICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCflJI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFz
cz0icGItbmFtZSI+UG9ydCA0NDM8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3Vi
Ij5XU1MgwrcgU1NMPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KCiAgICAg
ICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPvCfjJAg4LmA4Lil4Li34Lit4LiBIElTUCAvIE9QRVJB
VE9SPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYg
Y2xhc3M9InBpY2stb3B0IGEtZHRhYyIgaWQ9InByby1kdGFjIiBvbmNsaWNrPSJwaWNrUHJvKCdk
dGFjJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+8J+foDwvZGl2PgogICAgICAgICAg
ICA8ZGl2IGNsYXNzPSJwbiI+RFRBQyBHQU1JTkc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFz
cz0icHMiPmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2Pgog
ICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJwcm8tdHJ1ZSIgb25jbGljaz0icGlj
a1BybygndHJ1ZScpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCflLU8L2Rpdj4KICAg
ICAgICAgICAgPGRpdiBjbGFzcz0icG4iPlRSVUUgVFdJVFRFUjwvZGl2PgogICAgICAgICAgICA8
ZGl2IGNsYXNzPSJwcyI+aGVscC54LmNvbTwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAg
PC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn5OxIOC5gOC4peC4t+C4reC4
gSBBUFA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLWdyaWQiPgogICAgICAgICAgPGRp
diBjbGFzcz0icGljay1vcHQgYS1ucHYiIGlkPSJhcHAtbnB2IiBvbmNsaWNrPSJwaWNrQXBwKCdu
cHYnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4
O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMwZDJhM2E7ZGlzcGxh
eTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjow
IGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNp
emU6Ljg1cmVtO2NvbG9yOiMwMGNjZmY7bGV0dGVyLXNwYWNpbmc6LTFweDtib3JkZXI6MS41cHgg
c29saWQgcmdiYSgwLDIwNCwyNTUsLjMpIj5uVjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2
IGNsYXNzPSJwbiI+TnB2IFR1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+
bnB2dC1zc2g6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0i
cGljay1vcHQiIGlkPSJhcHAtZGFyayIgb25jbGljaz0icGlja0FwcCgnZGFyaycpIj4KICAgICAg
ICAgICAgPGRpdiBjbGFzcz0icGkiPjxkaXYgc3R5bGU9IndpZHRoOjM4cHg7aGVpZ2h0OjM4cHg7
Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6IzExMTtkaXNwbGF5OmZsZXg7YWxpZ24taXRl
bXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bWFyZ2luOjAgYXV0byAuMXJlbTtmb250
LWZhbWlseTpzYW5zLXNlcmlmO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6LjYycmVtO2NvbG9y
OiNmZmY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3JkZXI6MS41cHggc29saWQgIzQ0NCI+REFSSzwv
ZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RGFya1R1bm5lbDwvZGl2Pgog
ICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+ZGFya3R1bm5lbDovLzwvZGl2PgogICAgICAgICAg
PC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4tc3NoIiBp
ZD0ic3NoLWJ0biIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKelSDguKrguKPguYnguLLguIcgVXNl
cjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0IiBzdHls
ZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsaW5rLXJlc3Vs
dCIgaWQ9InNzaC1saW5rLXJlc3VsdCI+PC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBV
c2VyIHRhYmxlIC0tPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDox
MHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9
ImRhcmstbGJsIiBzdHlsZT0ibWFyZ2luOjAiPvCfk4sg4Lij4Liy4Lii4LiK4Li34LmI4LitIFVT
RVJTPC9kaXY+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJzc2gtc2VhcmNoIiBw
bGFjZWhvbGRlcj0i4LiE4LmJ4LiZ4Lir4LiyLi4uIiBvbmlucHV0PSJmaWx0ZXJTU0hVc2Vycyh0
aGlzLnZhbHVlKSIKICAgICAgICAgICAgc3R5bGU9IndpZHRoOjEyMHB4O21hcmdpbjowO2ZvbnQt
c2l6ZToxMXB4O3BhZGRpbmc6NnB4IDEwcHgiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYg
Y2xhc3M9InV0Ymwtd3JhcCI+CiAgICAgICAgICA8dGFibGUgY2xhc3M9InV0YmwiPgogICAgICAg
ICAgICA8dGhlYWQ+PHRyPjx0aD4jPC90aD48dGg+VVNFUk5BTUU8L3RoPjx0aD7guKvguKHguJTg
uK3guLLguKLguLg8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BQ1RJT048L3RoPjwv
dHI+PC90aGVhZD4KICAgICAgICAgICAgPHRib2R5IGlkPSJzc2gtdXNlci10Ym9keSI+PHRyPjx0
ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9y
OnZhcigtLW11dGVkKSI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwv
dGJvZHk+CiAgICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAg
IDwvZGl2PgoKICA8L2Rpdj48IS0tIC90YWItY3JlYXRlIC0tPgoKPCEtLSDilZDilZDilZDilZAg
TUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdl
Ij4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAg
ICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI
4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAg
ICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir
4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlk
PSJ1c2VyLXNlYXJjaCIgcGxhY2Vob2xkZXI9IvCflI0gIOC4hOC5ieC4meC4q+C4siB1c2VybmFt
ZS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgICA8ZGl2IGlkPSJ1
c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4m+C4uOC5iOC4oeC5guC4q+C4
peC4lOC5gOC4nuC4t+C5iOC4reC4lOC4tuC4h+C4guC5ieC4reC4oeC4ueC4pTwvZGl2PjwvZGl2
PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDi
lZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNs
YXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFz
cz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4
reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAg
ICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkT25saW5lKCkiPuKGuyDguKPg
uLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9j
ciI+CiAgICAgICAgPGRpdiBjbGFzcz0ib3BpbGwiIGlkPSJvbmxpbmUtcGlsbCI+PHNwYW4gY2xh
c3M9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJvbmxpbmUtY291bnQiPjA8L3NwYW4+IOC4reC4reC4
meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJ1dCIgaWQ9Im9ubGluZS10
aW1lIj4tLTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS12bGVzcy1z
ZWN0aW9uIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgICA8ZGl2IHN0eWxlPSJmb250LWZh
bWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjNw
eDtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzo4cHggMCA2cHg7dGV4dC10cmFuc2Zvcm06dXBw
ZXJjYXNlOyI+8J+ToSBWTEVTUyBPbmxpbmU8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJvbmxpbmUt
dmxlc3MtbGlzdCI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtc3No
LXNlY3Rpb24iIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICAgIDxkaXYgc3R5bGU9ImZvbnQt
ZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6
M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjhweCAwIDZweDt0ZXh0LXRyYW5zZm9ybTp1
cHBlcmNhc2U7Ij7wn5SRIFNTSCBPbmxpbmU8L2Rpdj4KICAgICAgICA8ZGl2IGlkPSJvbmxpbmUt
c3NoLWxpc3QiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0ib25saW5lLWVtcHR5
IiBzdHlsZT0iZGlzcGxheTpub25lIiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9k
aXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit
4LiZ4LiZ4Li14LmJPC9wPjwvZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtbG9hZGluZyI+PGRp
diBjbGFzcz0ibG9hZGluZyI+4LiB4LiU4Lij4Li14LmA4Lif4Lij4LiK4LmA4Lie4Li34LmI4Lit
4LiU4Li54Lic4Li54LmJ4LmD4LiK4LmJ4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+PC9kaXY+
CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQkFOIC8gVU5CQU4g4pWQ
4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1iYW4iPgogICAgPGRpdiBj
bGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+aqyDguJvguKXguJTguKXg
uYfguK3guIQgSVAgQmFuPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMXB4O2Nv
bG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHg7bGluZS1oZWlnaHQ6MS42OyI+CiAg
ICAgICAg4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmM4LiX4Li14LmI4LmD4LiK4LmJIElQIOC5gOC4
geC4tOC4mSBMaW1pdCDguIjguLDguJbguLnguIHguKXguYfguK3guITguIrguLHguYjguKfguITg
uKPguLLguKcgMSDguIrguLHguYjguKfguYLguKHguIc8YnI+CiAgICAgICAg4LiB4Lij4Lit4LiB
IFVzZXJuYW1lIOC5gOC4nuC4t+C5iOC4reC4m+C4peC4lOC4peC5h+C4reC4hOC4l+C4seC4meC4
l+C4tQogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwi
PvCfkaQgVVNFUk5BTUUg4LiX4Li14LmI4LiW4Li54LiB4LmB4Lia4LiZPC9kaXY+CiAgICAgICAg
PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImJhbi11c2VyIiBwbGFjZWhvbGRlcj0i4LiB4Lij4Lit4LiB
IHVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4m+C4peC4lOC4peC5h+C4
reC4hCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJiYWNrZ3JvdW5k
OmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2I0NTMwOSwjZDk3NzA2KSIgb25jbGljaz0idW5iYW5V
c2VyKCkiPvCflJMg4Lib4Lil4LiU4Lil4LmH4Lit4LiEIElQIEJhbjwvYnV0dG9uPgogICAgICA8
ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImJhbi1hbGVydCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxk
aXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgY2xhc3M9
InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0
b206MCI+4o+x77iPIOC4o+C4suC4ouC4geC4suC4o+C4l+C4teC5iOC4luC4ueC4geC5geC4muC4
meC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNr
PSJsb2FkQmFubmVkVXNlcnMoKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAg
ICA8L2Rpdj4KICAgICAgPGRpdiBpZD0iYmFubmVkLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmci
PuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAg
PC9kaXY+Cgo8L2Rpdj48IS0tIC93cmFwIC0tPgoKPCEtLSDilZDilZDilZDilZAgVVBEQVRFIOKV
kOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItdXBkYXRlIj4KICAgIDxk
aXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2
IGNsYXNzPSJzZWMtdGl0bGUiPuKshu+4jyDguK3guLHguJ7guYDguJTguJUgU2NyaXB0PC9kaXY+
CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIo
LS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4Ij4KICAgICAgICDguIHguJTguJvguLjguYjguKHg
uJTguYnguLLguJnguKXguYjguLLguIfguYDguJ7guLfguYjguK3guJTguLbguIcgc2NyaXB0IOC5
g+C4q+C4oeC5iOC4iOC4suC4gSBHaXRIdWIg4LmB4Lil4LmJ4Lin4Lij4Lix4LiZ4Lit4Lix4LiV
4LmC4LiZ4Lih4Lix4LiV4Li04Lia4LiZIHNlcnZlcjxicj4KICAgICAgICBQcm9ncmVzcyDguYHg
uKXguLAgTG9nIOC4iOC4sOC5geC4quC4lOC4h+C5geC4muC4miByZWFsLXRpbWUg4LiU4LmJ4Liy
4LiZ4Lil4LmI4Liy4LiHCiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+CiAgICAg
ICAgPGRpdiBjbGFzcz0iZmxibCI+8J+UlyBTY3JpcHQgVVJMPC9kaXY+CiAgICAgICAgPGlucHV0
IGNsYXNzPSJmaSIgaWQ9InVwZGF0ZS11cmwiIHZhbHVlPSJodHRwczovL3Jhdy5naXRodWJ1c2Vy
Y29udGVudC5jb20vQ2hhaXlha2V5OTkvY2hhaXlhLXZwbi9tYWluL2NoYWl5YS1zZXR1cC12NS1j
b21iaW5lZC5zaCI+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7
YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTJweCI+CiAgICAgICAg
PGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9InVwZGF0ZS1idG4iIG9uY2xpY2s9InN0YXJ0VXBkYXRl
KCkiIHN0eWxlPSJmbGV4OjEiPuKshu+4jyDguYDguKPguLTguYjguKEgVXBkYXRlPC9idXR0b24+
CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImNsZWFyVXBkYXRlTG9nKCki
PvCfl5Eg4Lil4LmJ4Liy4LiHIExvZzwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBp
ZD0idXBkYXRlLXN0YXR1cyIgc3R5bGU9ImRpc3BsYXk6bm9uZTttYXJnaW4tYm90dG9tOjEwcHgi
PjwvZGl2PgogICAgICA8IS0tIFByb2dyZXNzIGJhciAtLT4KICAgICAgPGRpdiBpZD0idXBkYXRl
LXByb2dyZXNzLXdyYXAiIHN0eWxlPSJkaXNwbGF5Om5vbmU7bWFyZ2luLWJvdHRvbToxMHB4Ij4K
ICAgICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFy
Z2luLWJvdHRvbTo0cHgiIGlkPSJ1cGRhdGUtcHJvZ3Jlc3MtbGFiZWwiPuC4geC4s+C4peC4seC4
h+C4l+C4s+C4h+C4suC4mS4uLjwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDo2cHg7
YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC4wNyk7Ym9yZGVyLXJhZGl1czozcHg7b3ZlcmZsb3c6aGlk
ZGVuIj4KICAgICAgICAgIDxkaXYgaWQ9InVwZGF0ZS1wcm9ncmVzcy1iYXIiIHN0eWxlPSJoZWln
aHQ6MTAwJTt3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1h
YyksIzRhZGU4MCk7Ym9yZGVyLXJhZGl1czozcHg7dHJhbnNpdGlvbjp3aWR0aCAuNXMgZWFzZSI+
PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8IS0tIExvZyBib3ggLS0+
CiAgICAgIDxkaXYgaWQ9InVwZGF0ZS1sb2ciIHN0eWxlPSJiYWNrZ3JvdW5kOiMwZDExMTc7Ym9y
ZGVyLXJhZGl1czoxMnB4O3BhZGRpbmc6MTRweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1z
aXplOjExcHg7Y29sb3I6IzU4ZDY4ZDtsaW5lLWhlaWdodDoxLjc7bWF4LWhlaWdodDozNjBweDtv
dmVyZmxvdy15OmF1dG87ZGlzcGxheTpub25lO2JvcmRlcjoxcHggc29saWQgcmdiYSg4OCwyMTQs
MTQxLC4xNSk7d2hpdGUtc3BhY2U6cHJlLXdyYXA7d29yZC1icmVhazpicmVhay1hbGwiPjwvZGl2
PgoKICAgICAgPCEtLSBJbnRlcmFjdGl2ZSBpbnB1dCAtLT4KICAgICAgPGRpdiBpZD0idXBkYXRl
LWlucHV0LXdyYXAiIHN0eWxlPSJkaXNwbGF5Om5vbmU7bWFyZ2luLXRvcDoxMHB4O2JhY2tncm91
bmQ6IzBkMTExNztib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjUxLDE5MSwzNiwuNCk7Ym9yZGVyLXJh
ZGl1czoxMnB4O3BhZGRpbmc6MTJweCI+CiAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEx
cHg7Y29sb3I6I2ZiYmYyNDttYXJnaW4tYm90dG9tOjhweDtmb250LWZhbWlseTptb25vc3BhY2Ui
PuKMqO+4jyA8c3BhbiBpZD0idXBkYXRlLWlucHV0LWxhYmVsIj5TY3JpcHQg4LiB4Liz4Lil4Lix
4LiH4Lij4LitIGlucHV0Li4uPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImRpc3Bs
YXk6ZmxleDtnYXA6NnB4Ij4KICAgICAgICAgIDxpbnB1dCBpZD0idXBkYXRlLWlucHV0LWJveCIg
dHlwZT0idGV4dCIgcGxhY2Vob2xkZXI9IuC4nuC4tOC4oeC4nuC5jOC5geC4peC5ieC4p+C4geC4
lCBFbnRlciDguKvguKPguLfguK0gU2VuZCIgc3R5bGU9ImZsZXg6MTtiYWNrZ3JvdW5kOiMwYTBl
MTQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDg4LDIxNCwxNDEsLjMpO2NvbG9yOiNlOGY0ZmY7Ym9y
ZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9u
dC1zaXplOjEycHg7b3V0bGluZTpub25lIiBvbmtleWRvd249ImlmKGV2ZW50LmtleT09PSdFbnRl
cicpc2VuZFVwZGF0ZUlucHV0KCkiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgc3R5
bGU9IndpZHRoOmF1dG87cGFkZGluZzo4cHggMThweDtmb250LXNpemU6MTJweCIgb25jbGljaz0i
c2VuZFVwZGF0ZUlucHV0KCkiPlNlbmQ8L2J1dHRvbj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9
ImJ0bi1yIiBzdHlsZT0icGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTJweCIgb25jbGljaz0i
c2VuZFVwZGF0ZUlucHV0KCcnKSIgdGl0bGU9IuC4quC5iOC4h+C4hOC5iOC4suC4p+C5iOC4suC4
hyAoRW50ZXIg4LmA4Lib4Lil4LmI4LiyKSI+4oa1PC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAg
ICAgIDwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+Cgo8IS0tIE1PREFMIC0tPgo8ZGl2IGNsYXNz
PSJtb3ZlciIgaWQ9Im1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNtKCki
PgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2
IGNsYXNzPSJtdGl0bGUiIGlkPSJtdCI+4pqZ77iPIHVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBj
bGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbSgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAg
PGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRr
Ij7wn5GkIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR1Ij4tLTwvc3Bhbj48L2Rp
dj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ToSBQb3J0PC9zcGFu
PjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFz
cz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+
PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0iZGUiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2
IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OmIERhdGEgTGltaXQ8L3NwYW4+PHNwYW4g
Y2xhc3M9ImR2IiBpZD0iZGQiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+
PHNwYW4gY2xhc3M9ImRrIj7wn5OKIFRyYWZmaWMg4LmD4LiK4LmJPC9zcGFuPjxzcGFuIGNsYXNz
PSJkdiIgaWQ9ImR0ciI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3Bh
biBjbGFzcz0iZGsiPvCfk7EgSVAgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGki
Pi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7w
n4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IG1vbm8iIGlkPSJkdXUiPi0tPC9zcGFuPjwv
ZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIo
LS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMHB4Ij7guYDguKXguLfguK3guIHguIHguLLguKPguJTg
uLPguYDguJnguLTguJnguIHguLLguKM8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImFncmlkIj4KICAg
ICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVuZXcnKSI+PGRpdiBjbGFz
cz0iYWkiPvCflIQ8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9k
aXY+PGRpdiBjbGFzcz0iYWQiPuC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4
teC5iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9u
KCdleHRlbmQnKSI+PGRpdiBjbGFzcz0iYWkiPvCfk4U8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LmA
4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4leC5iOC4reC4iOC4
suC4geC4p+C4seC4meC4q+C4oeC4lDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRu
IiBvbmNsaWNrPSJtQWN0aW9uKCdhZGRkYXRhJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OmPC9kaXY+
PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oSBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQi
PuC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKE8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBj
bGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignc2V0ZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+
4pqW77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC4seC5ieC4hyBEYXRhPC9kaXY+PGRpdiBj
bGFzcz0iYWQiPuC4geC4s+C4q+C4meC4lOC5g+C4q+C4oeC5iDwvZGl2PjwvZGl2PgogICAgICA8
ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdyZXNldCcpIj48ZGl2IGNsYXNzPSJh
aSI+8J+UgzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKPguLXguYDguIvguJUgVHJhZmZpYzwvZGl2
PjxkaXYgY2xhc3M9ImFkIj7guYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYk8
L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biBkYW5nZXIiIG9uY2xpY2s9Im1BY3Rp
b24oJ2RlbGV0ZScpIj48ZGl2IGNsYXNzPSJhaSI+8J+Xke+4jzwvZGl2PjxkaXYgY2xhc3M9ImFu
Ij7guKXguJrguKLguLnguKo8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lil4Lia4LiW4Liy4Lin4Lij
PC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4LmI4Lit4Lit
4Liy4Lii4Li4IC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlbmV3Ij4KICAg
ICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IOKAlCDg
uKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj4KICAgICAgPGRp
diBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4mTwv
ZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXJlbmV3LWRheXMiIHR5cGU9Im51bWJlciIgdmFs
dWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1y
ZW5ldy1idG4iIG9uY2xpY2s9ImRvUmVuZXdVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJng
uJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBB
TkVMOiDguYDguJ7guLTguYjguKHguKfguLHguJkgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIg
aWQ9Im1zdWItZXh0ZW5kIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk4Ug4LmA4Lie
4Li04LmI4Lih4Lin4Lix4LiZIOKAlCDguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHg
uJQ8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4
meC4p+C4meC4p+C4seC4meC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5
iOC4oTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLWV4dGVuZC1kYXlzIiB0eXBlPSJudW1i
ZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIg
aWQ9Im0tZXh0ZW5kLWJ0biIgb25jbGljaz0iZG9FeHRlbmRVc2VyKCkiPuKchSDguKLguLfguJng
uKLguLHguJnguYDguJ7guLTguYjguKHguKfguLHguJk8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAg
IDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKEgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9
Im0tc3ViIiBpZD0ibXN1Yi1hZGRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCf
k6Yg4LmA4Lie4Li04LmI4LihIERhdGEg4oCUIOC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjg
uKHguIjguLLguIHguJfguLXguYjguKHguLXguK3guKLguLnguYg8L2Rpdj4KICAgICAgPGRpdiBj
bGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4mSBHQiDguJfguLXguYjg
uJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZp
IiBpZD0ibS1hZGRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIxMCIgbWluPSIxIj48L2Rp
dj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tYWRkZGF0YS1idG4iIG9uY2xpY2s9
ImRvQWRkRGF0YSgpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4LihIERhdGE8
L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguJXguLHguYnguIcgRGF0
YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1zZXRkYXRhIj4KICAgICAgPGRp
diBjbGFzcz0ibXN1Yi1sYmwiPuKalu+4jyDguJXguLHguYnguIcgRGF0YSDigJQg4LiB4Liz4Lir
4LiZ4LiUIExpbWl0IOC5g+C4q+C4oeC5iCAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8
L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPkRhdGEgTGltaXQg
KEdCKSDigJQgMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lDwvZGl2PjxpbnB1dCBjbGFzcz0i
ZmkiIGlkPSJtLXNldGRhdGEtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9k
aXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXNldGRhdGEtYnRuIiBvbmNsaWNr
PSJkb1NldERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC4seC5ieC4hyBEYXRhPC9i
dXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lij4Li14LmA4LiL4LiVIFRy
YWZmaWMgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItcmVzZXQiPgogICAgICA8
ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+UgyDguKPguLXguYDguIvguJUgVHJhZmZpYyDigJQg4LmA
4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJ4LiX4Lix4LmJ4LiH4Lir4Lih4LiU
PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVk
KTttYXJnaW4tYm90dG9tOjEycHgiPuC4geC4suC4o+C4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4
iOC4sOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lCBVcGxvYWQvRG93bmxvYWQg4LiX4Lix
4LmJ4LiH4Lir4Lih4LiU4LiC4Lit4LiH4Lii4Li54Liq4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxi
dXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXJlc2V0LWJ0biIgb25jbGljaz0iZG9SZXNldFRyYWZm
aWMoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9idXR0
b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lil4Lia4Lii4Li54LiqIC0tPgog
ICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWRlbGV0ZSI+CiAgICAgIDxkaXYgY2xhc3M9
Im1zdWItbGJsIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+8J+Xke+4jyDguKXguJrguKLguLnguKog
4oCUIOC4peC4muC4luC4suC4p+C4oyDguYTguKHguYjguKrguLLguKHguLLguKPguJbguIHguLng
uYnguITguLfguJnguYTguJTguYk8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEy
cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTJweCI+4Lii4Li54LiqIDxiIGlk
PSJtLWRlbC1uYW1lIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+PC9iPiDguIjguLDguJbguLnguIHg
uKXguJrguK3guK3guIHguIjguLLguIHguKPguLDguJrguJrguJbguLLguKfguKM8L2Rpdj4KICAg
ICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZGVsZXRlLWJ0biIgb25jbGljaz0iZG9EZWxl
dGVVc2VyKCkiIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2RjMjYy
NiwjZWY0NDQ0KSI+8J+Xke+4jyDguKLguLfguJnguKLguLHguJnguKXguJrguKLguLnguKo8L2J1
dHRvbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ibW9kYWwtYWxlcnQi
IHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPjwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQg
c3JjPSJjb25maWcuanMiIG9uZXJyb3I9IndpbmRvdy5DSEFJWUFfQ09ORklHPXt9Ij48L3Njcmlw
dD4KPHNjcmlwdD4KLy8g4pWQ4pWQ4pWQ4pWQIENPTkZJRyDilZDilZDilZDilZAKY29uc3QgQ0ZH
ID0gKHR5cGVvZiB3aW5kb3cuQ0hBSVlBX0NPTkZJRyAhPT0gJ3VuZGVmaW5lZCcpID8gd2luZG93
LkNIQUlZQV9DT05GSUcgOiB7fTsKY29uc3QgSE9TVCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhv
c3RuYW1lOwpjb25zdCBYVUkgID0gJy94dWktYXBpJzsKY29uc3QgQVBJICA9ICcvYXBpJzsKY29u
c3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwoKLy8gU2Vzc2lvbiBjaGVjawpjb25zdCBf
cyA9ICgoKSA9PiB7IHRyeSB7IHJldHVybiBKU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0
ZW0oU0VTU0lPTl9LRVkpfHwne30nKTsgfSBjYXRjaChlKXtyZXR1cm57fTt9IH0pKCk7CmlmICgh
X3MudXNlciB8fCAhX3MucGFzcyB8fCBEYXRlLm5vdygpID49IChfcy5leHB8fDApKSB7CiAgc2Vz
c2lvblN0b3JhZ2UucmVtb3ZlSXRlbShTRVNTSU9OX0tFWSk7CiAgbG9jYXRpb24ucmVwbGFjZSgn
aW5kZXguaHRtbCcpOwp9CgovLyBIZWFkZXIgZG9tYWluCmRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdoZHItZG9tYWluJykudGV4dENvbnRlbnQgPSBIT1NUICsgJyDCtyB2NSc7CgovLyDilZDilZDi
lZDilZAgVVRJTFMg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGZtdEJ5dGVzKGIpIHsKICBpZiAoIWIg
fHwgYiA9PT0gMCkgcmV0dXJuICcwIEInOwogIGNvbnN0IGsgPSAxMDI0LCB1ID0gWydCJywnS0In
LCdNQicsJ0dCJywnVEInXTsKICBjb25zdCBpID0gTWF0aC5mbG9vcihNYXRoLmxvZyhiKS9NYXRo
LmxvZyhrKSk7CiAgcmV0dXJuIChiL01hdGgucG93KGssaSkpLnRvRml4ZWQoMSkrJyAnK3VbaV07
Cn0KZnVuY3Rpb24gZm10RGF0ZShtcykgewogIGlmICghbXMgfHwgbXMgPT09IDApIHJldHVybiAn
4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBjb25zdCBkID0gbmV3IERhdGUobXMpOwogIHJl
dHVybiBkLnRvTG9jYWxlRGF0ZVN0cmluZygndGgtVEgnLHt5ZWFyOidudW1lcmljJyxtb250aDon
c2hvcnQnLGRheTonbnVtZXJpYyd9KTsKfQpmdW5jdGlvbiBkYXlzTGVmdChtcykgewogIGlmICgh
bXMgfHwgbXMgPT09IDApIHJldHVybiBudWxsOwogIHJldHVybiBNYXRoLmNlaWwoKG1zIC0gRGF0
ZS5ub3coKSkgLyA4NjQwMDAwMCk7Cn0KZnVuY3Rpb24gc2V0UmluZyhpZCwgcGN0KSB7CiAgY29u
c3QgY2lyYyA9IDEzOC4yOwogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQp
OwogIGlmIChlbCkgZWwuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IGNpcmMgLSAoY2lyYyAqIE1h
dGgubWluKHBjdCwxMDApIC8gMTAwKTsKfQpmdW5jdGlvbiBzZXRCYXIoaWQsIHBjdCwgd2Fybj1m
YWxzZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICgh
ZWwpIHJldHVybjsKICBlbC5zdHlsZS53aWR0aCA9IE1hdGgubWluKHBjdCwxMDApICsgJyUnOwog
IGlmICh3YXJuICYmIHBjdCA+IDg1KSBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFk
aWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpJzsKICBlbHNlIGlmICh3YXJuICYmIHBjdCA+IDY1
KSBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZjk3MzE2LCNm
YjkyM2MpJzsKfQpmdW5jdGlvbiBzaG93QWxlcnQoaWQsIG1zZywgdHlwZSkgewogIGNvbnN0IGVs
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghZWwpIHJldHVybjsKICBlbC5j
bGFzc05hbWUgPSAnYWxlcnQgJyt0eXBlOwogIGVsLnRleHRDb250ZW50ID0gbXNnOwogIGVsLnN0
eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIGlmICh0eXBlID09PSAnb2snKSBzZXRUaW1lb3V0KCgp
PT57ZWwuc3R5bGUuZGlzcGxheT0nbm9uZSc7fSwgMzAwMCk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBO
QVYg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIHN3KG5hbWUsIGVsKSB7CiAgZG9jdW1lbnQucXVlcnlT
ZWxlY3RvckFsbCgnLnNlYycpLmZvckVhY2gocz0+cy5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUn
KSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm5hdi1pdGVtJykuZm9yRWFjaChuPT5u
LmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
dGFiLScrbmFtZSkuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgZWwuY2xhc3NMaXN0LmFkZCgn
YWN0aXZlJyk7CiAgaWYgKG5hbWU9PT0nY3JlYXRlJykgY2xvc2VGb3JtKCk7CiAgaWYgKG5hbWU9
PT0nZGFzaGJvYXJkJykgbG9hZERhc2goKTsKICBpZiAobmFtZT09PSdtYW5hZ2UnKSBsb2FkVXNl
cnMoKTsKICBpZiAobmFtZT09PSdvbmxpbmUnKSBsb2FkT25saW5lKCk7CiAgaWYgKG5hbWU9PT0n
YmFuJykgbG9hZEJhbm5lZFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0ndXBkYXRlJykgeyAvKiBubyBh
dXRvLWxvYWQgKi8gfQp9CgovLyDilIDilIAgRm9ybSBuYXYg4pSA4pSACmxldCBfY3VyRm9ybSA9
IG51bGw7CmZ1bmN0aW9uIG9wZW5Gb3JtKGlkKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBbJ2FpcycsJ3RydWUnLCdz
c2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytm
KS5zdHlsZS5kaXNwbGF5ID0gZj09PWlkID8gJ2Jsb2NrJyA6ICdub25lJzsKICB9KTsKICBfY3Vy
Rm9ybSA9IGlkOwogIGlmIChpZD09PSdzc2gnKSBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB3aW5k
b3cuc2Nyb2xsVG8oMCwwKTsKfQpmdW5jdGlvbiBjbG9zZUZvcm0oKSB7CiAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgWydh
aXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9
IG51bGw7Cn0KCmxldCBfd3NQb3J0ID0gJzgwJzsKZnVuY3Rpb24gdG9nUG9ydChidG4sIHBvcnQp
IHsKICBfd3NQb3J0ID0gcG9ydDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M4MC1idG4n
KS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzgwJyk7CiAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3dzNDQzLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9
PT0nNDQzJyk7Cn0KZnVuY3Rpb24gdG9nR3JvdXAoYnRuLCBjbHMpIHsKICBidG4uY2xvc2VzdCgn
ZGl2JykucXVlcnlTZWxlY3RvckFsbChjbHMpLmZvckVhY2goYj0+Yi5jbGFzc0xpc3QucmVtb3Zl
KCdhY3RpdmUnKSk7CiAgYnRuLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9CgovLyDilZDilZDi
lZDilZAgWFVJIExPR0lOIChjb29raWUpIOKVkOKVkOKVkOKVkApsZXQgX3h1aU9rID0gZmFsc2U7
CmFzeW5jIGZ1bmN0aW9uIHh1aUxvZ2luKCkgewogIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNo
UGFyYW1zKHsgdXNlcm5hbWU6IF9zLnVzZXIsIHBhc3N3b3JkOiBfcy5wYXNzIH0pOwogIGNvbnN0
IHIgPSBhd2FpdCBmZXRjaChYVUkrJy9sb2dpbicsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRl
bnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlv
bi94LXd3dy1mb3JtLXVybGVuY29kZWQnfSwKICAgIGJvZHk6IGZvcm0udG9TdHJpbmcoKQogIH0p
OwogIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICBfeHVpT2sgPSAhIWQuc3VjY2VzczsKICBy
ZXR1cm4gX3h1aU9rOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aUdldChwYXRoKSB7CiAgaWYgKCFfeHVp
T2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7
Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7CiAgLy8gQXV0byByZS1sb2dpbiDguJbguYnguLIgc2Vz
c2lvbiDguKvguKHguJQgKDQwMS80MDMvcmVkaXJlY3QgdG8gbG9naW4pCiAgaWYgKHIuc3RhdHVz
ID09PSA0MDEgfHwgci5zdGF0dXMgPT09IDQwMyB8fCByLnVybC5pbmNsdWRlcygnL2xvZ2luJykp
IHsKICAgIF94dWlPayA9IGZhbHNlOwogICAgYXdhaXQgeHVpTG9naW4oKTsKICAgIGNvbnN0IHIy
ID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHtjcmVkZW50aWFsczonaW5jbHVkZSd9KTsKICAgIHJl
dHVybiByMi5qc29uKCk7CiAgfQogIHJldHVybiByLmpzb24oKTsKfQphc3luYyBmdW5jdGlvbiB4
dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICBj
b25zdCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRl
bnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlv
bi9qc29uJ30sCiAgICBib2R5OiBKU09OLnN0cmluZ2lmeShib2R5KQogIH0pOwogIC8vIEF1dG8g
cmUtbG9naW4g4LiW4LmJ4LiyIHNlc3Npb24g4Lir4Lih4LiUCiAgaWYgKHIuc3RhdHVzID09PSA0
MDEgfHwgci5zdGF0dXMgPT09IDQwMyB8fCByLnVybC5pbmNsdWRlcygnL2xvZ2luJykpIHsKICAg
IF94dWlPayA9IGZhbHNlOwogICAgYXdhaXQgeHVpTG9naW4oKTsKICAgIGNvbnN0IHIyID0gYXdh
aXQgZmV0Y2goWFVJK3BhdGgsIHsKICAgICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2lu
Y2x1ZGUnLAogICAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9
LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeShib2R5KQogICAgfSk7CiAgICByZXR1cm4gcjIu
anNvbigpOwogIH0KICByZXR1cm4gci5qc29uKCk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBEQVNIQk9B
UkQg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWREYXNoKCkgewogIGNvbnN0IGJ0biA9
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcmVmcmVzaCcpOwogIGlmIChidG4pIGJ0bi50
ZXh0Q29udGVudCA9ICfihrsgLi4uJzsKICBfeHVpT2sgPSBmYWxzZTsgLy8gZm9yY2UgcmUtbG9n
aW4g4LmA4Liq4Lih4LitCgogIHRyeSB7CiAgICAvLyBTU0ggQVBJIHN0YXR1cwogICAgY29uc3Qg
c3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgo
KT0+bnVsbCk7CiAgICByZW5kZXJTZXJ2aWNlcyhzdCA/IChzdC5zZXJ2aWNlcyB8fCB7fSkgOiBu
dWxsKTsKCiAgICAvLyBYVUkgc2VydmVyIHN0YXR1cwogICAgY29uc3Qgb2sgPSBhd2FpdCB4dWlM
b2dpbigpOwogICAgaWYgKCFvaykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVp
LXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj5Mb2dpbiDg
uYTguKHguYjguYTguJTguYknOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBp
bGwnKS5jbGFzc05hbWUgPSAnb3BpbGwgb2ZmJzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29u
c3Qgc3YgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvc2VydmVyL3N0YXR1cycpLmNhdGNoKCgp
PT5udWxsKTsKICAgIGlmIChzdiAmJiBzdi5zdWNjZXNzICYmIHN2Lm9iaikgewogICAgICBjb25z
dCBvID0gc3Yub2JqOwogICAgICAvLyBDUFUKICAgICAgY29uc3QgY3B1ID0gTWF0aC5yb3VuZChv
LmNwdSB8fCAwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1wY3QnKS50ZXh0
Q29udGVudCA9IGNwdSArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1j
b3JlcycpLnRleHRDb250ZW50ID0gKG8uY3B1Q29yZXMgfHwgby5sb2dpY2FsUHJvIHx8ICctLScp
ICsgJyBjb3Jlcyc7CiAgICAgIHNldFJpbmcoJ2NwdS1yaW5nJywgY3B1KTsgc2V0QmFyKCdjcHUt
YmFyJywgY3B1LCB0cnVlKTsKCiAgICAgIC8vIFJBTQogICAgICBjb25zdCByYW1UID0gKChvLm1l
bT8udG90YWx8fDApLzEwNzM3NDE4MjQpLCByYW1VID0gKChvLm1lbT8uY3VycmVudHx8MCkvMTA3
Mzc0MTgyNCk7CiAgICAgIGNvbnN0IHJhbVAgPSByYW1UID4gMCA/IE1hdGgucm91bmQocmFtVS9y
YW1UKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLXBjdCcpLnRl
eHRDb250ZW50ID0gcmFtUCArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Jh
bS1kZXRhaWwnKS50ZXh0Q29udGVudCA9IHJhbVUudG9GaXhlZCgxKSsnIC8gJytyYW1ULnRvRml4
ZWQoMSkrJyBHQic7CiAgICAgIHNldFJpbmcoJ3JhbS1yaW5nJywgcmFtUCk7IHNldEJhcigncmFt
LWJhcicsIHJhbVAsIHRydWUpOwoKICAgICAgLy8gRGlzawogICAgICBjb25zdCBkc2tUID0gKChv
LmRpc2s/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgZHNrVSA9ICgoby5kaXNrPy5jdXJyZW50fHww
KS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgZHNrUCA9IGRza1QgPiAwID8gTWF0aC5yb3VuZChk
c2tVL2Rza1QqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLXBj
dCcpLmlubmVySFRNTCA9IGRza1AgKyAnPHNwYW4+JTwvc3Bhbj4nOwogICAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnZGlzay1kZXRhaWwnKS50ZXh0Q29udGVudCA9IGRza1UudG9GaXhlZCgw
KSsnIC8gJytkc2tULnRvRml4ZWQoMCkrJyBHQic7CiAgICAgIHNldEJhcignZGlzay1iYXInLCBk
c2tQLCB0cnVlKTsKCiAgICAgIC8vIFVwdGltZQogICAgICBjb25zdCB1cCA9IG8udXB0aW1lIHx8
IDA7CiAgICAgIGNvbnN0IHVkID0gTWF0aC5mbG9vcih1cC84NjQwMCksIHVoID0gTWF0aC5mbG9v
cigodXAlODY0MDApLzM2MDApLCB1bSA9IE1hdGguZmxvb3IoKHVwJTM2MDApLzYwKTsKICAgICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS12YWwnKS50ZXh0Q29udGVudCA9IHVkID4g
MCA/IHVkKydkICcrdWgrJ2gnIDogdWgrJ2ggJyt1bSsnbSc7CiAgICAgIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCd1cHRpbWUtc3ViJykudGV4dENvbnRlbnQgPSB1ZCsn4Lin4Lix4LiZICcrdWgr
J+C4iuC4oS4gJyt1bSsn4LiZ4Liy4LiX4Li1JzsKICAgICAgY29uc3QgbG9hZHMgPSBvLmxvYWRz
IHx8IFtdOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9hZC1jaGlwcycpLmlubmVy
SFRNTCA9IGxvYWRzLm1hcCgobCxpKT0+CiAgICAgICAgYDxzcGFuIGNsYXNzPSJiZGciPiR7Wycx
bScsJzVtJywnMTVtJ11baV19OiAke2wudG9GaXhlZCgyKX08L3NwYW4+YCkuam9pbignJyk7Cgog
ICAgICAvLyBOZXR3b3JrCiAgICAgIGlmIChvLm5ldElPKSB7CiAgICAgICAgY29uc3QgdXBfYiA9
IG8ubmV0SU8udXB8fDAsIGRuX2IgPSBvLm5ldElPLmRvd258fDA7CiAgICAgICAgY29uc3QgdXBG
bXQgPSBmbXRCeXRlcyh1cF9iKSwgZG5GbXQgPSBmbXRCeXRlcyhkbl9iKTsKICAgICAgICBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwJykuaW5uZXJIVE1MID0gdXBGbXQucmVwbGFjZSgn
ICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J25ldC1kbicpLmlubmVySFRNTCA9IGRuRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bh
bj4nOwogICAgICB9CiAgICAgIGlmIChvLm5ldFRyYWZmaWMpIHsKICAgICAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnbmV0LXVwLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10
Qnl0ZXMoby5uZXRUcmFmZmljLnNlbnR8fDApOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCduZXQtZG4tdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5l
dFRyYWZmaWMucmVjdnx8MCk7CiAgICAgIH0KCiAgICAgIC8vIFhVSSB2ZXJzaW9uCiAgICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktdmVyJykudGV4dENvbnRlbnQgPSBvLnhyYXlWZXJz
aW9uIHx8ICctLSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlu
bmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM
JzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0g
J29waWxsJzsKICAgIH0KCiAgICAvLyBJbmJvdW5kcyBjb3VudAogICAgY29uc3QgaWJsID0gYXdh
aXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAg
ICBpZiAoaWJsICYmIGlibC5zdWNjZXNzKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCd4dWktaW5ib3VuZHMnKS50ZXh0Q29udGVudCA9IChpYmwub2JqfHxbXSkubGVuZ3RoOwogICAg
fQoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsYXN0LXVwZGF0ZScpLnRleHRDb250ZW50
ID0gJ+C4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogJyArIG5ldyBEYXRlKCku
dG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogIH0gY2F0Y2goZSkgewogICAgY29uc29sZS5l
cnJvcihlKTsKICB9IGZpbmFsbHkgewogICAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KG
uyDguKPguLXguYDguJ/guKPguIonOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNFUlZJQ0VTIOKV
kOKVkOKVkOKVkApjb25zdCBTVkNfREVGID0gWwogIHsga2V5Oid4dWknLCAgICAgIGljb246J/Cf
k6EnLCBuYW1lOid4LXVpIFBhbmVsJywgICAgICBwb3J0Oic6MjA1MycgfSwKICB7IGtleTonc3No
JywgICAgICBpY29uOifwn5CNJywgbmFtZTonU1NIIEFQSScsICAgICAgICAgIHBvcnQ6Jzo2Nzg5
JyB9LAogIHsga2V5Oidkcm9wYmVhcicsIGljb246J/CfkLsnLCBuYW1lOidEcm9wYmVhciBTU0gn
LCAgICAgcG9ydDonOjE0MyA6MTA5JyB9LAogIHsga2V5OiduZ2lueCcsICAgIGljb246J/CfjJAn
LCBuYW1lOiduZ2lueCAvIFBhbmVsJywgICAgcG9ydDonOjgwIDo0NDMnIH0sCiAgeyBrZXk6J3Nz
aHdzJywgICAgaWNvbjon8J+UkicsIG5hbWU6J1dTLVN0dW5uZWwnLCAgICAgICBwb3J0Oic6ODDi
hpI6MTQzJyB9LAogIHsga2V5OidiYWR2cG4nLCAgIGljb246J/Cfjq4nLCBuYW1lOidCYWRWUE4g
VURQR1cnLCAgICAgcG9ydDonOjczMDAnIH0sCl07CmZ1bmN0aW9uIHJlbmRlclNlcnZpY2VzKG1h
cCkgewogIGNvbnN0IHRzID0gbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyx7
aG91cjonMi1kaWdpdCcsbWludXRlOicyLWRpZ2l0JyxzZWNvbmQ6JzItZGlnaXQnfSk7CiAgY29u
c3QgaXNVbmtub3duID0gIW1hcDsKICBpZiAoIW1hcCkgbWFwID0ge307CiAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gU1ZDX0RFRi5tYXAocyA9PiB7CiAg
ICBjb25zdCB1cCA9IG1hcFtzLmtleV0gPT09IHRydWUgfHwgbWFwW3Mua2V5XSA9PT0gJ2FjdGl2
ZSc7CiAgICBjb25zdCB1bmtub3duID0gaXNVbmtub3duOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNz
PSJzdmMgJHt1bmtub3duPycnOicnfSR7KCF1bmtub3duJiYhdXApPydkb3duJzonJ30iPgogICAg
ICA8ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnICR7dW5rbm93bj8nb3JhbmdlJzp1
cD8nJzoncmVkJ30iPjwvc3Bhbj48c3Bhbj4ke3MuaWNvbn08L3NwYW4+CiAgICAgICAgPGRpdj48
ZGl2IGNsYXNzPSJzdmMtbiI+JHtzLm5hbWV9PC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPiR7cy5w
b3J0fTwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9InJiZGcgJHt1
bmtub3duPyd3YXJuJzp1cD8nJzonZG93bid9Ij4ke3Vua25vd24/Jy4uLic6dXA/J1JVTk5JTkcn
OidET1dOJ308L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpICsgYDxkaXYgc3R5bGU9
InRleHQtYWxpZ246cmlnaHQ7Zm9udC1zaXplOjlweDtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGlu
Zy10b3A6NnB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5n
OjFweCI+TElWRSDCtyAke3RzfTwvZGl2PmA7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFNlcnZpY2Vz
KCkgewogIHRyeSB7CiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cz90PScr
RGF0ZS5ub3coKSwge2NhY2hlOiduby1zdG9yZSd9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIHJl
bmRlclNlcnZpY2VzKHN0LnNlcnZpY2VzIHx8IHt9KTsKICB9IGNhdGNoKGUpIHsKICAgIHJlbmRl
clNlcnZpY2VzKG51bGwpOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBQSUNLRVIgU1RBVEUg
4pWQ4pWQ4pWQ4pWQCmNvbnN0IFBST1MgPSB7CiAgZHRhYzogewogICAgbmFtZTogJ0RUQUMgR0FN
SU5HJywKICAgIHByb3h5OiAnMTA0LjE4LjYzLjEyNDo4MCcsCiAgICBwYXlsb2FkOiAnQ09OTkVD
VCAvICBIVFRQLzEuMSBbY3JsZl1Ib3N0OiBkbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tIFtjcmxm
XVtjcmxmXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0Oltob3N0XVtjcmxmXVVwZ3JhZGU6VXNl
ci1BZ2VudDogW3VhXVtjcmxmXVtjcmxmXScsCiAgICBkYXJrUHJveHk6ICd0cnVldmlwYW5saW5l
LmdvZHZwbi5zaG9wJywgZGFya1Byb3h5UG9ydDogODAKICB9LAogIHRydWU6IHsKICAgIG5hbWU6
ICdUUlVFIFRXSVRURVInLAogICAgcHJveHk6ICcxMDQuMTguMzkuMjQ6ODAnLAogICAgcGF5bG9h
ZDogJ1BPU1QgLyBIVFRQLzEuMVtjcmxmXUhvc3Q6aGVscC54LmNvbVtjcmxmXVVzZXItQWdlbnQ6
IFt1YV1bY3JsZl1bY3JsZl1bc3BsaXRdW2NyXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OiBb
aG9zdF1bY3JsZl1VcGdyYWRlOiB3ZWJzb2NrZXRbY3JsZl1Db25uZWN0aW9uOlVwZ3JhZGVbY3Js
Zl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRh
cmtQcm94eVBvcnQ6IDgwCiAgfQp9Owpjb25zdCBOUFZfSE9TVCA9ICd3d3cucHJvamVjdC5nb2R2
cG4uc2hvcCcsIE5QVl9QT1JUID0gODA7CmxldCBfc3NoUHJvID0gJ2R0YWMnLCBfc3NoQXBwID0g
J25wdicsIF9zc2hQb3J0ID0gJzgwJzsKCmZ1bmN0aW9uIHBpY2tQb3J0KHApIHsKICBfc3NoUG9y
dCA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BiLTgwJykuY2xhc3NOYW1lICA9ICdw
b3J0LWJ0bicgKyAocD09PSc4MCcgID8gJyBhY3RpdmUtcDgwJyAgOiAnJyk7CiAgZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ3BiLTQ0MycpLmNsYXNzTmFtZSA9ICdwb3J0LWJ0bicgKyAocD09PSc0
NDMnID8gJyBhY3RpdmUtcDQ0MycgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja1BybyhwKSB7CiAgX3Nz
aFBybyA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byby1kdGFjJykuY2xhc3NOYW1l
ID0gJ3BpY2stb3B0JyArIChwPT09J2R0YWMnID8gJyBhLWR0YWMnIDogJycpOwogIGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdwcm8tdHJ1ZScpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09
PSd0cnVlJyA/ICcgYS10cnVlJyA6ICcnKTsKfQpmdW5jdGlvbiBwaWNrQXBwKGEpIHsKICBfc3No
QXBwID0gYTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwLW5wdicpLmNsYXNzTmFtZSAg
PSAncGljay1vcHQnICsgKGE9PT0nbnB2JyAgPyAnIGEtbnB2JyAgOiAnJyk7CiAgZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2FwcC1kYXJrJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChhPT09
J2RhcmsnID8gJyBhLWRhcmsnIDogJycpOwp9CmZ1bmN0aW9uIGJ1aWxkTnB2TGluayhuYW1lLCBw
YXNzLCBwcm8pIHsKICBjb25zdCBqID0gewogICAgc3NoQ29uZmlnVHlwZTonU1NILVByb3h5LVBh
eWxvYWQnLCByZW1hcmtzOnByby5uYW1lKyctJytuYW1lLAogICAgc3NoSG9zdDpOUFZfSE9TVCwg
c3NoUG9ydDpOUFZfUE9SVCwKICAgIHNzaFVzZXJuYW1lOm5hbWUsIHNzaFBhc3N3b3JkOnBhc3Ms
CiAgICBzbmk6JycsIHRsc1ZlcnNpb246J0RFRkFVTFQnLAogICAgaHR0cFByb3h5OnByby5wcm94
eSwgYXV0aGVudGljYXRlUHJveHk6ZmFsc2UsCiAgICBwcm94eVVzZXJuYW1lOicnLCBwcm94eVBh
c3N3b3JkOicnLAogICAgcGF5bG9hZDpwcm8ucGF5bG9hZCwKICAgIGRuc01vZGU6J1VEUCcsIGRu
c1NlcnZlcjonJywgbmFtZXNlcnZlcjonJywgcHVibGljS2V5OicnLAogICAgdWRwZ3dQb3J0Ojcz
MDAsIHVkcGd3VHJhbnNwYXJlbnRETlM6dHJ1ZQogIH07CiAgcmV0dXJuICducHZ0LXNzaDovLycg
KyBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChKU09OLnN0cmluZ2lmeShqKSkpKTsK
fQpmdW5jdGlvbiBidWlsZERhcmtMaW5rKG5hbWUsIHBhc3MsIHBybykgewogIGNvbnN0IHBwID0g
KHByby5wcm94eXx8JycpLnNwbGl0KCc6Jyk7CiAgY29uc3QgZGggPSBwcFswXSB8fCBwcm8uZGFy
a1Byb3h5OwogIGNvbnN0IGogPSB7CiAgICBjb25maWdUeXBlOidTU0gtUFJPWFknLCByZW1hcmtz
OnByby5uYW1lKyctJytuYW1lLAogICAgc3NoSG9zdDpIT1NULCBzc2hQb3J0OjE0MywKICAgIHNz
aFVzZXI6bmFtZSwgc3NoUGFzczpwYXNzLAogICAgcGF5bG9hZDonR0VUIC8gSFRUUC8xLjFcclxu
SG9zdDogJytIT1NUKydcclxuVXBncmFkZTogd2Vic29ja2V0XHJcbkNvbm5lY3Rpb246IFVwZ3Jh
ZGVcclxuXHJcbicsCiAgICBwcm94eUhvc3Q6ZGgsIHByb3h5UG9ydDo4MCwKICAgIHVkcGd3QWRk
cjonMTI3LjAuMC4xJywgdWRwZ3dQb3J0OjczMDAsIHRsc0VuYWJsZWQ6ZmFsc2UKICB9OwogIHJl
dHVybiAnZGFya3R1bm5lbC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25l
bnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBDUkVBVEUgU1NIIOKV
kOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBjcmVhdGVTU0goKSB7CiAgY29uc3QgdXNlciA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlcicpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBw
YXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1wYXNzJykudmFsdWUudHJpbSgpOwog
IGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWRheXMn
KS52YWx1ZSl8fDMwOwogIGNvbnN0IGlwbCAgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc3NoLWlwJykgPyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWlwJykudmFsdWUg
OiAyKXx8MjsKICBpZiAoIXVzZXIpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4
o+C4uOC4k+C4suC5g+C4quC5iCBVc2VybmFtZScsJ2VycicpOwogIGlmICghcGFzcykgcmV0dXJu
IHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3Jk
JywnZXJyJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1idG4n
KTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOwogIGJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9
InNwaW4iIHN0eWxlPSJib3JkZXItY29sb3I6cmdiYSgzNCwxOTcsOTQsLjMpO2JvcmRlci10b3At
Y29sb3I6IzIyYzU1ZSI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7
CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25v
bmUnOwogIGNvbnN0IHJlc0VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1saW5rLXJl
c3VsdCcpOwogIGlmIChyZXNFbCkgcmVzRWwuY2xhc3NOYW1lPSdsaW5rLXJlc3VsdCc7CiAgdHJ5
IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9jcmVhdGVfc3NoJywgewogICAgICBt
ZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9
LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7dXNlciwgcGFzc3dvcmQ6cGFzcywgZGF5cywg
aXBfbGltaXQ6aXBsfSkKICAgIH0pOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAg
aWYgKCFkLm9rKSB0aHJvdyBuZXcgRXJyb3IoZC5lcnJvciB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE
4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgcHJvICA9IFBST1NbX3NzaFBy
b10gfHwgUFJPUy5kdGFjOwogICAgY29uc3QgbGluayA9IF9zc2hBcHA9PT0nbnB2JyA/IGJ1aWxk
TnB2TGluayh1c2VyLHBhc3MscHJvKSA6IGJ1aWxkRGFya0xpbmsodXNlcixwYXNzLHBybyk7CiAg
ICBjb25zdCBpc05wdiA9IF9zc2hBcHA9PT0nbnB2JzsKICAgIGNvbnN0IGxwQ2xzID0gaXNOcHYg
PyAnJyA6ICcgZGFyay1scCc7CiAgICBjb25zdCBjQ2xzICA9IGlzTnB2ID8gJ25wdicgOiAnZGFy
ayc7CiAgICBjb25zdCBhcHBMYWJlbCA9IGlzTnB2ID8gJ05wdnQnIDogJ0RhcmtUdW5uZWwnOwoK
ICAgIGlmIChyZXNFbCkgewogICAgICByZXNFbC5jbGFzc05hbWUgPSAnbGluay1yZXN1bHQgc2hv
dyc7CiAgICAgIGNvbnN0IHNhZmVMaW5rID0gbGluay5yZXBsYWNlKC9cXC9nLCdcXFxcJykucmVw
bGFjZSgvJy9nLCJcXCciKTsKICAgICAgcmVzRWwuaW5uZXJIVE1MID0KICAgICAgICAiPGRpdiBj
bGFzcz0nbGluay1yZXN1bHQtaGRyJz4iICsKICAgICAgICAgICI8c3BhbiBjbGFzcz0naW1wLWJh
ZGdlICIrY0NscysiJz4iK2FwcExhYmVsKyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5
bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6dmFyKC0tbXV0ZWQpJz4iK3Byby5uYW1lKyIgXHhi
NyBQb3J0ICIrX3NzaFBvcnQrIjwvc3Bhbj4iICsKICAgICAgICAgICI8c3BhbiBzdHlsZT0nZm9u
dC1zaXplOi42NXJlbTtjb2xvcjojMjJjNTVlO21hcmdpbi1sZWZ0OmF1dG8nPlx1MjcwNSAiK3Vz
ZXIrIjwvc3Bhbj4iICsKICAgICAgICAiPC9kaXY+IiArCiAgICAgICAgIjxkaXYgY2xhc3M9J2xp
bmstcHJldmlldyIrbHBDbHMrIic+IitsaW5rKyI8L2Rpdj4iICsKICAgICAgICAiPGJ1dHRvbiBj
bGFzcz0nY29weS1saW5rLWJ0biAiK2NDbHMrIicgaWQ9J2NvcHktc3NoLWJ0bicgb25jbGljaz1c
ImNvcHlTU0hMaW5rKClcIj4iKwogICAgICAgICAgIlx1ZDgzZFx1ZGNjYiBDb3B5ICIrYXBwTGFi
ZWwrIiBMaW5rIisKICAgICAgICAiPC9idXR0b24+IjsKICAgICAgd2luZG93Ll9sYXN0U1NITGlu
ayA9IGxpbms7CiAgICAgIHdpbmRvdy5fbGFzdFNTSEFwcCAgPSBjQ2xzOwogICAgICB3aW5kb3cu
X2xhc3RTU0hMYWJlbCA9IGFwcExhYmVsOwogICAgfQoKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0
Jywn4pyFIOC4quC4o+C5ieC4suC4hyAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIggwrcg4Lir
4Lih4LiU4Lit4Liy4Lii4Li4ICcrZC5leHAsJ29rJyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnc3NoLXVzZXInKS52YWx1ZT0nJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdz
c2gtcGFzcycpLnZhbHVlPScnOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChl
KSB7IHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsgfQog
IGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KelSDguKrguKPg
uYnguLLguIcgVXNlcic7IH0KfQpmdW5jdGlvbiBjb3B5U1NITGluaygpIHsKICBjb25zdCBsaW5r
ID0gd2luZG93Ll9sYXN0U1NITGlua3x8Jyc7CiAgY29uc3QgY0NscyA9IHdpbmRvdy5fbGFzdFNT
SEFwcHx8J25wdic7CiAgY29uc3QgbGFiZWwgPSB3aW5kb3cuX2xhc3RTU0hMYWJlbHx8J0xpbmsn
OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KGxpbmspLnRoZW4oZnVuY3Rpb24oKXsK
ICAgIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29weS1zc2gtYnRuJyk7CiAg
ICBpZihiKXsgYi50ZXh0Q29udGVudD0nXHUyNzA1IOC4hOC4seC4lOC4peC4reC4geC5geC4peC5
ieC4pyEnOyBzZXRUaW1lb3V0KGZ1bmN0aW9uKCl7Yi50ZXh0Q29udGVudD0nXHVkODNkXHVkY2Ni
IENvcHkgJytsYWJlbCsnIExpbmsnO30sMjAwMCk7IH0KICB9KS5jYXRjaChmdW5jdGlvbigpeyBw
cm9tcHQoJ0NvcHkgbGluazonLGxpbmspOyB9KTsKfQoKLy8gU1NIIHVzZXIgdGFibGUKbGV0IF9z
c2hUYWJsZVVzZXJzID0gW107CmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hUYWJsZUluRm9ybSgpIHsK
ICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5y
Lmpzb24oKSk7CiAgICBfc3NoVGFibGVVc2VycyA9IGQudXNlcnMgfHwgW107CiAgICByZW5kZXJT
U0hUYWJsZShfc3NoVGFibGVVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zdCB0YiA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogICAgaWYodGIpIHRiLmlu
bmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29s
b3I6I2VmNDQ0NDtwYWRkaW5nOjE2cHgiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBTU0gg
QVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvdGQ+PC90cj4nOwogIH0KfQpmdW5jdGlvbiByZW5kZXJT
U0hUYWJsZSh1c2VycykgewogIGNvbnN0IHRiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Nz
aC11c2VyLXRib2R5Jyk7CiAgaWYgKCF0YikgcmV0dXJuOwogIGlmICghdXNlcnMubGVuZ3RoKSB7
CiAgICB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246
Y2VudGVyO2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjIwcHgiPuC5hOC4oeC5iOC4oeC4tSBT
U0ggdXNlcnM8L3RkPjwvdHI+JzsKICAgIHJldHVybjsKICB9CiAgY29uc3Qgbm93ID0gbmV3IERh
dGUoKS50b0lTT1N0cmluZygpLnNsaWNlKDAsMTApOwogIHRiLmlubmVySFRNTCA9IHVzZXJzLm1h
cChmdW5jdGlvbih1LGkpewogICAgY29uc3QgZXhwaXJlZCA9IHUuZXhwICYmIHUuZXhwIDwgbm93
OwogICAgY29uc3QgYWN0aXZlICA9IHUuYWN0aXZlICE9PSBmYWxzZSAmJiAhZXhwaXJlZDsKICAg
IGNvbnN0IGRMZWZ0ICAgPSB1LmV4cCA/IE1hdGguY2VpbCgobmV3IERhdGUodS5leHApLURhdGUu
bm93KCkpLzg2NDAwMDAwKSA6IG51bGw7CiAgICBjb25zdCBiYWRnZSAgID0gYWN0aXZlCiAgICAg
ID8gJzxzcGFuIGNsYXNzPSJiZGcgYmRnLWciPkFDVElWRTwvc3Bhbj4nCiAgICAgIDogJzxzcGFu
IGNsYXNzPSJiZGcgYmRnLXIiPkVYUElSRUQ8L3NwYW4+JzsKICAgIGNvbnN0IGRUYWcgPSBkTGVm
dCE9PW51bGwKICAgICAgPyAnPHNwYW4gY2xhc3M9ImRheXMtYmFkZ2UiPicrKGRMZWZ0PjA/ZExl
ZnQrJ2QnOifguKvguKHguJQnKSsnPC9zcGFuPicKICAgICAgOiAnPHNwYW4gY2xhc3M9ImRheXMt
YmFkZ2UiPlx1MjIxZTwvc3Bhbj4nOwogICAgcmV0dXJuICc8dHI+PHRkIHN0eWxlPSJjb2xvcjp2
YXIoLS1tdXRlZCkiPicrKGkrMSkrJzwvdGQ+JyArCiAgICAgICc8dGQ+PGI+Jyt1LnVzZXIrJzwv
Yj48L3RkPicgKwogICAgICAnPHRkIHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjonKyhleHBp
cmVkPycjZWY0NDQ0JzondmFyKC0tbXV0ZWQpJykrJyI+JysKICAgICAgICAodS5leHB8fCfguYTg
uKHguYjguIjguLPguIHguLHguJQnKSsnPC90ZD4nICsKICAgICAgJzx0ZD4nK2JhZGdlKyc8L3Rk
PicgKwogICAgICAnPHRkPjxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6NHB4O2FsaWduLWl0
ZW1zOmNlbnRlciI+JysKICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iYnRuLXRibCIgdGl0bGU9IuC4
leC5iOC4reC4reC4suC4ouC4uCIgb25jbGljaz0icmVuZXdTU0hVc2VyKFwnJyt1LnVzZXIrJ1wn
KSI+8J+UhDwvYnV0dG9uPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxl
PSLguKXguJoiIG9uY2xpY2s9ImRlbFNTSFVzZXIoXCcnK3UudXNlcisnXCcpIiBzdHlsZT0iYm9y
ZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LC4zKSI+8J+Xke+4jzwvYnV0dG9uPicrCiAgICAgICAg
ZFRhZysKICAgICAgJzwvZGl2PjwvdGQ+PC90cj4nOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9u
IGZpbHRlclNTSFVzZXJzKHEpIHsKICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycy5maWx0
ZXIoZnVuY3Rpb24odSl7cmV0dXJuICh1LnVzZXJ8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVz
KHEudG9Mb3dlckNhc2UoKSk7fSkpOwp9CmFzeW5jIGZ1bmN0aW9uIHJlbmV3U1NIVXNlcih1c2Vy
KSB7CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KHByb21wdCgn4LiV4LmI4Lit4Lit4Liy4Lii4Li4
ICcrdXNlcisnIOC4geC4teC5iOC4p+C4seC4mT8nLCczMCcpKTsKICBpZiAoIWRheXN8fGRheXM8
PTApIHJldHVybjsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2V4dGVu
ZF9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBw
bGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyLGRheXN9KQog
ICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2sp
IHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7
CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguJXguYjguK3guK3guLLguKLguLgg
Jyt1c2VyKycgKycrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIgnLCdvaycpOwog
ICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IGFsZXJ0KCdcdTI3NGMgJytl
Lm1lc3NhZ2UpOyB9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsU1NIVXNlcih1c2VyKSB7CiAgaWYgKCFj
b25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiDguJbguLLguKfguKM/JykpIHJldHVy
bjsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHsK
ICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24v
anNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSkKICAgIH0pLnRoZW4oZnVu
Y3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJy
b3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0
KCdzc2gtYWxlcnQnLCdcdTI3MDUg4Lil4LiaICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcs
J29rJyk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgYWxlcnQoJ1x1
Mjc0YyAnK2UubWVzc2FnZSk7IH0KfQovLyDilZDilZDilZDilZAgQ1JFQVRFIFZMRVNTIOKVkOKV
kOKVkOKVkApmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4
LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csYz0+ewogICAgY29uc3Qgcj1NYXRo
LnJhbmRvbSgpKjE2fDA7IHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3wweDgpKS50b1N0cmluZygx
Nik7CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gY3JlYXRlVkxFU1MoY2FycmllcikgewogIGNvbnN0
IGVtYWlsRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZW1haWwnKTsKICBj
b25zdCBkYXlzRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWRheXMnKTsK
ICBjb25zdCBpcEVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWlwJyk7
CiAgY29uc3QgZ2JFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1nYicp
OwogIGNvbnN0IGVtYWlsICAgPSBlbWFpbEVsLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzICAg
ID0gcGFyc2VJbnQoZGF5c0VsLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50
KGlwRWwudmFsdWUpfHwyOwogIGNvbnN0IGdiICAgICAgPSBwYXJzZUludChnYkVsLnZhbHVlKXx8
MDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+C4geC4
o+C4uOC4k+C4suC5g+C4quC5iCBFbWFpbC9Vc2VybmFtZScsJ2VycicpOwoKICBjb25zdCBwb3J0
ID0gY2Fycmllcj09PSdhaXMnID8gODA4MCA6IDg4ODA7CiAgY29uc3Qgc25pICA9IGNhcnJpZXI9
PT0nYWlzJyA/ICdjai1lYmIuc3BlZWR0ZXN0Lm5ldCcgOiAndHJ1ZS1pbnRlcm5ldC56b29tLnh5
ei5zZXJ2aWNlcyc7CgogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJp
ZXIrJy1idG4nKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xh
c3M9InNwaW4iPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25v
bmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5zdHlsZS5k
aXNwbGF5PSdub25lJzsKCiAgdHJ5IHsKICAgIGlmICghX3h1aU9rKSBhd2FpdCB4dWlMb2dpbigp
OwogICAgLy8g4Lir4LiyIGluYm91bmQgaWQKICAgIGNvbnN0IGxpc3QgPSBhd2FpdCB4dWlHZXQo
Jy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgY29uc3QgaWIgPSAobGlzdC5vYmp8fFtd
KS5maW5kKHg9PngucG9ydD09PXBvcnQpOwogICAgaWYgKCFpYikgdGhyb3cgbmV3IEVycm9yKGDg
uYTguKHguYjguJ7guJogaW5ib3VuZCBwb3J0ICR7cG9ydH0g4oCUIOC4o+C4seC4mSBzZXR1cCDg
uIHguYjguK3guJlgKTsKCiAgICBjb25zdCB1aWQgPSBnZW5VVUlEKCk7CiAgICBjb25zdCBleHBN
cyA9IGRheXMgPiAwID8gKERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwKSA6IDA7CiAgICBjb25z
dCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CgogICAgY29uc3QgcmVz
ID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9hZGRDbGllbnQnLCB7CiAgICAg
IGlkOiBpYi5pZCwKICAgICAgc2V0dGluZ3M6IEpTT04uc3RyaW5naWZ5KHsgY2xpZW50czpbewog
ICAgICAgIGlkOnVpZCwgZmxvdzonJywgZW1haWwsIGxpbWl0SXA6aXBMaW1pdCwKICAgICAgICB0
b3RhbEdCOnRvdGFsQnl0ZXMsIGV4cGlyeVRpbWU6ZXhwTXMsIGVuYWJsZTp0cnVlLCB0Z0lkOicn
LCBzdWJJZDonJywgY29tbWVudDonJywgcmVzZXQ6MAogICAgICB9XX0pCiAgICB9KTsKICAgIGlm
ICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnIHx8ICfguKrguKPguYnguLLg
uIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBsaW5rID0gYHZsZXNz
Oi8vJHt1aWR9QCR7SE9TVH06JHtwb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2
bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudCgoY2Fycmllcj09PSdhaXMnPydB
SVMt4LiB4Lix4LiZ4Lij4Lix4LmI4LinJzonVFJVRS1WRE8nKSsnLScrZW1haWwpfWA7CgogICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZW1haWwnKS50ZXh0Q29udGVu
dCA9IGVtYWlsOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctdXVp
ZCcpLnRleHRDb250ZW50ID0gdWlkOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytj
YXJyaWVyKyctZXhwJykudGV4dENvbnRlbnQgPSBleHBNcyA+IDAgPyBmbXREYXRlKGV4cE1zKSA6
ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3ItJytjYXJyaWVyKyctbGluaycpLnRleHRDb250ZW50ID0gbGluazsKICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdibG9jayc7CiAg
ICBjb25zdCBxckRpdiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1xcicpOwog
ICAgaWYgKHFyRGl2KSB7IHFyRGl2LmlubmVySFRNTCA9ICcnOyB0cnkgeyBuZXcgUVJDb2RlKHFy
RGl2LCB7IHRleHQ6IGxpbmssIHdpZHRoOiAxODAsIGhlaWdodDogMTgwLCBjb3JyZWN0TGV2ZWw6
IFFSQ29kZS5Db3JyZWN0TGV2ZWwuTSB9KTsgfSBjYXRjaChxckVycikge30gfQogICAgc2hvd0Fs
ZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgVkxFU1MgQWNjb3VudCDg
uKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZW1haWxFbC52YWx1ZT0nJzsKICB9IGNhdGNo
KGUpIHsgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7
IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfimqEg4Liq
4Lij4LmJ4Liy4LiHICcrKGNhcnJpZXI9PT0nYWlzJz8nQUlTJzonVFJVRScpKycgQWNjb3VudCc7
IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSBVU0VSUyDilZDilZDilZDilZAKbGV0IF9hbGxV
c2VycyA9IFtdLCBfY3VyVXNlciA9IG51bGw7CmFzeW5jIGZ1bmN0aW9uIGxvYWRVc2VycygpIHsK
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYg
Y2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAg
dHJ5IHsKICAgIC8vIOC4lOC4tuC4h+C4iOC4suC4gSBTU0ggQVBJIOC4l+C4teC5iOC4reC5iOC4
suC4mSBjbGllbnRfdHJhZmZpY3MgREIg4LmC4LiU4Lii4LiV4Lij4LiHIOKAlCDguYHguKLguIEg
dHJhZmZpYyDguKPguLLguKLguITguJnguJbguLnguIHguJXguYnguK3guIcKICAgIGNvbnN0IGQg
PSBhd2FpdCBmZXRjaChBUEkrJy92bGVzc191c2Vycz90PScrRGF0ZS5ub3coKSwge2NhY2hlOidu
by1zdG9yZSd9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVy
cm9yKCfguYLguKvguKXguJTguYTguKHguYjguYTguJTguYknKTsKICAgIF9hbGxVc2VycyA9IChk
LnVzZXJzfHxbXSkubWFwKHUgPT4gKHsKICAgICAgaWJJZDogdS5pbmJvdW5kSWQsIHBvcnQ6IHUu
cG9ydCwgcHJvdG86IHUucHJvdG9jb2wsCiAgICAgIGVtYWlsOiB1LnVzZXIsIHV1aWQ6IHUudXVp
ZCwKICAgICAgZXhwOiB1LmV4cGlyeVRpbWV8fDAsIHRvdGFsOiB1LnRvdGFsR0J8fDAsCiAgICAg
IHVwOiB1LnVwfHwwLCBkb3duOiB1LmRvd258fDAsIGxpbWl0SXA6IHUubGltaXRJcHx8MAogICAg
fSkpOwogICAgcmVuZGVyVXNlcnMoX2FsbFVzZXJzKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0i
bG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0K
fQpmdW5jdGlvbiByZW5kZXJVc2Vycyh1c2VycykgewogIGlmICghdXNlcnMubGVuZ3RoKSB7IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9
Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4nuC4muC4ouC4ueC4
quC5gOC4i+C4reC4o+C5jDwvcD48L2Rpdj4nOyByZXR1cm47IH0KICBjb25zdCBub3cgPSBEYXRl
Lm5vdygpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwg
PSB1c2Vycy5tYXAodSA9PiB7CiAgICBjb25zdCBkbCA9IGRheXNMZWZ0KHUuZXhwKTsKICAgIGxl
dCBiYWRnZSwgY2xzOwogICAgaWYgKCF1LmV4cCB8fCB1LmV4cD09PTApIHsgYmFkZ2U9J+KckyDg
uYTguKHguYjguIjguLPguIHguLHguJQnOyBjbHM9J29rJzsgfQogICAgZWxzZSBpZiAoZGwgPCAw
KSAgICAgICAgIHsgYmFkZ2U9J+C4q+C4oeC4lOC4reC4suC4ouC4uCc7IGNscz0nZXhwJzsgfQog
ICAgZWxzZSBpZiAoZGwgPD0gMykgICAgICAgIHsgYmFkZ2U9J+KaoCAnK2RsKydkJzsgY2xzPSdz
b29uJzsgfQogICAgZWxzZSAgICAgICAgICAgICAgICAgICAgIHsgYmFkZ2U9J+KckyAnK2RsKydk
JzsgY2xzPSdvayc7IH0KICAgIGNvbnN0IGF2Q2xzID0gZGwgPCAwID8gJ2F2LXgnIDogJ2F2LWcn
OwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSIgb25jbGljaz0ib3BlblVzZXIoJHtKU09O
LnN0cmluZ2lmeSh1KS5yZXBsYWNlKC8iL2csJyZxdW90OycpfSkiPgogICAgICA8ZGl2IGNsYXNz
PSJ1YXYgJHthdkNsc30iPiR7KHUuZW1haWx8fCc/JylbMF0udG9VcHBlckNhc2UoKX08L2Rpdj4K
ICAgICAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LmVt
YWlsfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InVtIj5Qb3J0ICR7dS5wb3J0fSDCtyAke2Zt
dEJ5dGVzKHUudXArdS5kb3duKX0g4LmD4LiK4LmJPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8
c3BhbiBjbGFzcz0iYWJkZyAke2Nsc30iPiR7YmFkZ2V9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9
KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJVc2VycyhxKSB7CiAgcmVuZGVyVXNlcnMoX2Fs
bFVzZXJzLmZpbHRlcih1PT4odS5lbWFpbHx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50
b0xvd2VyQ2FzZSgpKSkpOwp9CgovLyDilZDilZDilZDilZAgTU9EQUwgVVNFUiDilZDilZDilZDi
lZAKZnVuY3Rpb24gb3BlblVzZXIodSkgewogIGlmICh0eXBlb2YgdSA9PT0gJ3N0cmluZycpIHUg
PSBKU09OLnBhcnNlKHUpOwogIF9jdXJVc2VyID0gdTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnbXQnKS50ZXh0Q29udGVudCA9ICfimpnvuI8gJyt1LmVtYWlsOwogIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdkdScpLnRleHRDb250ZW50ID0gdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnZHAnKS50ZXh0Q29udGVudCA9IHUucG9ydDsKICBjb25zdCBkbCA9IGRheXNMZWZ0
KHUuZXhwKTsKICBjb25zdCBleHBUeHQgPSAhdS5leHB8fHUuZXhwPT09MCA/ICfguYTguKHguYjg
uIjguLPguIHguLHguJQnIDogZm10RGF0ZSh1LmV4cCk7CiAgY29uc3QgZGUgPSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnZGUnKTsKICBkZS50ZXh0Q29udGVudCA9IGV4cFR4dDsKICBkZS5jbGFz
c05hbWUgPSAnZHYnICsgKGRsICE9PSBudWxsICYmIGRsIDwgMCA/ICcgcmVkJyA6ICcgZ3JlZW4n
KTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGQnKS50ZXh0Q29udGVudCA9IHUudG90YWwg
PiAwID8gZm10Qnl0ZXModS50b3RhbCkgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHRyJykudGV4dENvbnRlbnQgPSBmbXRCeXRlcyh1LnVw
K3UuZG93bik7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RpJykudGV4dENvbnRlbnQgPSB1
LmxpbWl0SXAgfHwgJ+KInic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1dScpLnRleHRD
b250ZW50ID0gdS51dWlkOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC1hbGVydCcp
LnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcp
LmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbSgpewogIGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfbVN1YnMuZm9y
RWFjaChrID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJl
bW92ZSgnb3BlbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVh
Y2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKfQoKLy8g4pSA4pSAIE1PREFM
IDYtQUNUSU9OIFNZU1RFTSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY29u
c3QgX21TdWJzID0gWydyZW5ldycsJ2V4dGVuZCcsJ2FkZGRhdGEnLCdzZXRkYXRhJywncmVzZXQn
LCdkZWxldGUnXTsKZnVuY3Rpb24gbUFjdGlvbihrZXkpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdtc3ViLScra2V5KTsKICBjb25zdCBpc09wZW4gPSBlbC5jbGFzc0xp
c3QuY29udGFpbnMoJ29wZW4nKTsKICBfbVN1YnMuZm9yRWFjaChrID0+IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpKTsKICBkb2N1bWVu
dC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1v
dmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5z
dHlsZS5kaXNwbGF5PSdub25lJzsKICBpZiAoIWlzT3BlbikgewogICAgZWwuY2xhc3NMaXN0LmFk
ZCgnb3BlbicpOwogICAgaWYgKGtleT09PSdkZWxldGUnICYmIF9jdXJVc2VyKSBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnbS1kZWwtbmFtZScpLnRleHRDb250ZW50ID0gX2N1clVzZXIuZW1haWw7
CiAgICBzZXRUaW1lb3V0KCgpPT5lbC5zY3JvbGxJbnRvVmlldyh7YmVoYXZpb3I6J3Ntb290aCcs
YmxvY2s6J25lYXJlc3QnfSksMTAwKTsKICB9Cn0KZnVuY3Rpb24gX21CdG5Mb2FkKGlkLCBsb2Fk
aW5nLCBvcmlnVGV4dCkgewogIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7
CiAgaWYgKCFiKSByZXR1cm47CiAgYi5kaXNhYmxlZCA9IGxvYWRpbmc7CiAgaWYgKGxvYWRpbmcp
IHsgYi5kYXRhc2V0Lm9yaWcgPSBiLnRleHRDb250ZW50OyBiLmlubmVySFRNTCA9ICc8c3BhbiBj
bGFzcz0ic3BpbiI+PC9zcGFuPiDguIHguLPguKXguLHguIfguJTguLPguYDguJnguLTguJnguIHg
uLLguKMuLi4nOyB9CiAgZWxzZSBpZiAoYi5kYXRhc2V0Lm9yaWcpIGIudGV4dENvbnRlbnQgPSBi
LmRhdGFzZXQub3JpZzsKfQoKYXN5bmMgZnVuY3Rpb24gZG9SZW5ld1VzZXIoKSB7CiAgaWYgKCFf
Y3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnbS1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVy
biBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI
4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bics
IHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBleHBNcyA9IERhdGUubm93KCkgKyBkYXlzKjg2NDAw
MDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91
cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAg
ICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxm
bG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3Rh
bEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxz
dWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nl
c3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiI
Jyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC5iOC4reC4reC4suC4ouC4
uOC4quC4s+C5gOC4o+C5h+C4iCAnK2RheXMrJyDguKfguLHguJkgKOC4o+C4teC5gOC4i+C4leC4
iOC4suC4geC4p+C4seC4meC4meC4teC5iSknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBj
bSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9k
YWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9h
ZCgnbS1yZW5ldy1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9FeHRlbmRVc2Vy
KCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZXh0ZW5kLWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRh
eXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLg
uIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQo
J20tZXh0ZW5kLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBiYXNlID0gKF9jdXJVc2Vy
LmV4cCAmJiBfY3VyVXNlci5leHAgPiBEYXRlLm5vdygpKSA/IF9jdXJVc2VyLmV4cCA6IERhdGUu
bm93KCk7CiAgICBjb25zdCBleHBNcyA9IGJhc2UgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3Qg
cmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytf
Y3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpT
T04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9j
dXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRv
dGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50
OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBF
cnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxl
cnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSAnK2RheXMrJyDguKfguLHguJkg
4Liq4Liz4LmA4Lij4LmH4LiIICjguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQp
Jywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDAp
OwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdl
LCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIGZhbHNlKTsg
fQp9Cgphc3luYyBmdW5jdGlvbiBkb0FkZERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJu
OwogIGNvbnN0IGFkZEdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1h
ZGRkYXRhLWdiJykudmFsdWUpfHwwOwogIGlmIChhZGRHYiA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0
KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiDguJfguLXguYjg
uJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKEnLCdlcnInKTsKICBfbUJ0bkxvYWQo
J20tYWRkZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgbmV3VG90YWwgPSAoX2N1
clVzZXIudG90YWx8fDApICsgYWRkR2IqMTA3Mzc0MTgyNDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0
IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVp
ZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lm
eSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFp
bCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpuZXdUb3RhbCxleHBpcnlUaW1lOl9j
dXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVz
ZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJl
cy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9k
YWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihIERhdGEgKycrYWRkR2IrJyBHQiDguKrguLPg
uYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMo
KTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwg
JytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0
bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1NldERhdGEoKSB7CiAgaWYgKCFfY3Vy
VXNlcikgcmV0dXJuOwogIGNvbnN0IGdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnbS1zZXRkYXRhLWdiJykudmFsdWUpOwogIGlmIChpc05hTihnYil8fGdiPDApIHJldHVy
biBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdC
ICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1z
ZXRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAw
ID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFu
ZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6
X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tp
ZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3Vy
VXNlci5saW1pdElwLHRvdGFsR0I6dG90YWxCeXRlcyxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8
MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAg
IH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTg
uKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfi
nIUg4LiV4Lix4LmJ4LiHIERhdGEgTGltaXQgJysoZ2I+MD9nYisnIEdCJzon4LmE4Lih4LmI4LiI
4Liz4LiB4Lix4LiUJykrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91
dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dB
bGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7
IF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBk
b1Jlc2V0VHJhZmZpYygpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdt
LXJlc2V0LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9n
aW4oKTsKICAgIC8vIOC5g+C4iuC5iSBmZXRjaCDguYLguJTguKLguJXguKPguIfguYDguJ7guLfg
uYjguK3guIjguLHguJTguIHguLLguKMgcmVzcG9uc2Ug4LiX4Li14LmI4Lit4Liy4LiI4LmE4Lih
4LmI4LmD4LiK4LmIIEpTT04KICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrJy9wYW5lbC9h
cGkvaW5ib3VuZHMvJytfY3VyVXNlci5pYklkKycvcmVzZXRDbGllbnRUcmFmZmljLycrX2N1clVz
ZXIuZW1haWwsIHsKICAgICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnCiAg
ICB9KTsKICAgIGxldCByZXMgPSB7fTsKICAgIHRyeSB7IHJlcyA9IGF3YWl0IHIuanNvbigpOyB9
IGNhdGNoKGplKSB7IHJlcyA9IHtzdWNjZXNzOiByLm9rfTsgfQogICAgaWYgKCFyZXMuc3VjY2Vz
cyAmJiAhci5vaykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguKPguLXguYDguIvguJUgVHJh
ZmZpYyDguYTguKHguYjguKrguLPguYDguKPguYfguIggKEhUVFAgJytyLnN0YXR1cysnKScpOwog
ICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDg
uKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2Fk
VXNlcnMoKTsgfSwgMTUwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQn
LCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZXNl
dC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9EZWxldGVVc2VyKCkgewogIGlm
ICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIHRydWUpOwog
IHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIC8vIOC5g+C4iuC5
iSBmZXRjaCDguYLguJTguKLguJXguKPguIfguYDguJ7guLfguYjguK3guIjguLHguJTguIHguLLg
uKMgcmVzcG9uc2Ug4LiX4Li14LmI4Lit4Liy4LiI4LmE4Lih4LmI4LmD4LiK4LmIIEpTT04KICAg
IGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrJy9wYW5lbC9hcGkvaW5ib3VuZHMvJytfY3VyVXNl
ci5pYklkKycvZGVsQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBtZXRob2Q6J1BPU1Qn
LCBjcmVkZW50aWFsczonaW5jbHVkZScKICAgIH0pOwogICAgbGV0IHJlcyA9IHt9OwogICAgdHJ5
IHsgcmVzID0gYXdhaXQgci5qc29uKCk7IH0gY2F0Y2goamUpIHsgcmVzID0ge3N1Y2Nlc3M6IHIu
b2t9OyB9CiAgICBpZiAoIXJlcy5zdWNjZXNzICYmICFyLm9rKSB0aHJvdyBuZXcgRXJyb3IocmVz
Lm1zZ3x8J+C4peC4muC4ouC4ueC4quC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCAoSFRUUCAn
K3Iuc3RhdHVzKycpJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4peC4muC4
ouC4ueC4qiAnK19jdXJVc2VyLmVtYWlsKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAg
IHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDEyMDApOwogIH0gY2F0Y2go
ZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQog
IGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIGZhbHNlKTsgfQp9CgovLyDilZDi
lZDilZDilZAgT05MSU5FIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkT25saW5lKCkg
ewogIGNvbnN0IGxvYWRFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxvYWRp
bmcnKTsKICBjb25zdCB2bGVzc0VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS12
bGVzcy1zZWN0aW9uJyk7CiAgY29uc3Qgc3NoRWwgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdvbmxpbmUtc3NoLXNlY3Rpb24nKTsKICBjb25zdCBlbXB0eUVsID0gZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ29ubGluZS1lbXB0eScpOwogIGNvbnN0IGNvdW50RWwgPSBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnb25saW5lLWNvdW50Jyk7CiAgY29uc3QgdGltZUVsICA9IGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdvbmxpbmUtdGltZScpOwoKICBsb2FkRWwuaW5uZXJIVE1MICA9ICc8ZGl2
IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJTguILguYnguK3guKHg
uLnguKXguK3guK3guJnguYTguKXguJnguYwuLi48L2Rpdj4nOwogIGxvYWRFbC5zdHlsZS5kaXNw
bGF5ICA9ICdibG9jayc7CiAgdmxlc3NFbC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIHNzaEVs
LnN0eWxlLmRpc3BsYXkgICA9ICdub25lJzsKICBlbXB0eUVsLnN0eWxlLmRpc3BsYXkgPSAnbm9u
ZSc7CgogIHRyeSB7CiAgICAvLyDilIDilIAgMS4gTG9naW4geC11aSDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKICAgIGlmICghX3h1aU9r
KSBhd2FpdCB4dWlMb2dpbigpOwoKICAgIC8vIOKUgOKUgCAyLiDguYLguKvguKXguJQgVkxFU1Mg
b25saW5lIGVtYWlscyDguIjguLLguIEgeC11aSAo4Liq4LiUKSDilIDilIDilIDilIDilIDilIDi
lIDilIDilIAKICAgIGxldCBvbmxpbmVFbWFpbHMgPSBbXTsKICAgIHRyeSB7CiAgICAgIC8vIOC4
lOC4tuC4hyBWTEVTUyBvbmxpbmUg4LiI4Liy4LiBIFNTSCBBUEkgKOC4l+C4teC5iCBsb2dpbiB4
LXVpIOC5g+C4q+C5ieC5gOC4reC4hykKICAgICAgY29uc3Qgb2QgPSBhd2FpdCBmZXRjaChBUEkr
Jy92bGVzc19vbmxpbmU/dD0nK0RhdGUubm93KCksIHtjYWNoZTonbm8tc3RvcmUnfSkudGhlbihy
PT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgICBpZiAob2QgJiYgb2Qub2sgJiYgQXJy
YXkuaXNBcnJheShvZC5vbmxpbmUpKSB7CiAgICAgICAgb25saW5lRW1haWxzID0gb2Qub25saW5l
OwogICAgICB9CiAgICB9IGNhdGNoKGUyKSB7fQoKICAgIC8vIOKUgOKUgCAzLiDguYLguKvguKXg
uJQgY2xpZW50U3RhdHMg4LiC4Lit4LiH4LmB4LiV4LmI4Lil4LiwIHVzZXIgKHRyYWZmaWMg4LiI
4Lij4Li04LiHKSDilIDilIAKICAgIC8vIOC5g+C4iuC5iSBfYWxsVXNlcnMg4LiW4LmJ4Liy4Lih
4Li14LmB4Lil4LmJ4LinIOC5hOC4oeC5iOC4h+C4seC5ieC4meC5guC4q+C4peC4lOC5g+C4q+C4
oeC5iAogICAgaWYgKCFfYWxsVXNlcnMubGVuZ3RoKSBhd2FpdCBsb2FkVXNlcnNRdWlldCgpOwog
ICAgY29uc3QgdU1hcCA9IHt9OwogICAgX2FsbFVzZXJzLmZvckVhY2godSA9PiB7IHVNYXBbdS5l
bWFpbF0gPSB1OyB9KTsKCiAgICAvLyDilIDilIAgNC4g4LmC4Lir4Lil4LiUIFNTSCBvbmxpbmUg
4LiI4Liy4LiBIFNTSCBBUEkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSACiAgICBsZXQgc3NoT25saW5lID0gW107CiAgICBsZXQgc3No
Q29ubkNvdW50ID0gMDsKICAgIHRyeSB7CiAgICAgIGNvbnN0IG9uUmVzcCA9IGF3YWl0IGZldGNo
KEFQSSsnL29ubGluZV9zc2gnLCB7Y2FjaGU6J25vLXN0b3JlJ30pLnRoZW4ocj0+ci5qc29uKCkp
LmNhdGNoKCgpPT5udWxsKTsKICAgICAgaWYgKG9uUmVzcCAmJiBvblJlc3Aub2spIHsKICAgICAg
ICBzc2hPbmxpbmUgPSAob25SZXNwLm9ubGluZSB8fCBbXSkuZmlsdGVyKHUgPT4gIXUuY29ubl9v
bmx5KTsKICAgICAgICAvLyBjb25uX29ubHkgPSDguYTguKHguYjguKPguLnguYnguIrguLfguYjg
uK0gdXNlciDguYHguJXguYjguKPguLnguYnguKfguYjguLLguKHguLUgY29ubmVjdGlvbgogICAg
ICAgIGNvbnN0IGNvbm5Pbmx5ID0gKG9uUmVzcC5vbmxpbmUgfHwgW10pLmZpbmQodSA9PiB1LmNv
bm5fb25seSk7CiAgICAgICAgaWYgKGNvbm5Pbmx5KSB7CiAgICAgICAgICBjb25zdCBtID0gU3Ry
aW5nKGNvbm5Pbmx5LnVzZXIpLm1hdGNoKC8oXGQrKS8pOwogICAgICAgICAgc3NoQ29ubkNvdW50
ID0gbSA/IHBhcnNlSW50KG1bMV0pIDogMTsKICAgICAgICB9CiAgICAgIH0KICAgICAgLy8gZmFs
bGJhY2s6IOC5g+C4iuC5iSBjb25uZWN0aW9uIGNvdW50IOC4iOC4suC4gSAvYXBpL3N0YXR1cwog
ICAgICBpZiAoIXNzaE9ubGluZS5sZW5ndGggJiYgc3NoQ29ubkNvdW50ID09PSAwKSB7CiAgICAg
ICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnLCB7Y2FjaGU6J25vLXN0b3Jl
J30pLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgICAgICBpZiAoc3QpIHNz
aENvbm5Db3VudCA9IChzdC5jb25uXzE0M3x8MCkgKyAoc3QuY29ubl8xMDl8fDApICsgKHN0LmNv
bm5fODB8fDApOwogICAgICB9CiAgICB9IGNhdGNoKGUzKSB7fQoKICAgIGNvbnN0IHRvdGFsT25s
aW5lID0gb25saW5lRW1haWxzLmxlbmd0aCArIHNzaE9ubGluZS5sZW5ndGggKyAoc3NoQ29ubkNv
dW50ID4gMCAmJiBzc2hPbmxpbmUubGVuZ3RoID09PSAwID8gMSA6IDApOwogICAgY291bnRFbC50
ZXh0Q29udGVudCA9IG9ubGluZUVtYWlscy5sZW5ndGggKyBzc2hPbmxpbmUubGVuZ3RoOwogICAg
aWYgKHRpbWVFbCkgdGltZUVsLnRleHRDb250ZW50ID0gJ+C4reC4seC4nuC5gOC4lOC4lTogJytu
ZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKICAgIGxvYWRFbC5zdHlsZS5k
aXNwbGF5ID0gJ25vbmUnOwoKICAgIGlmIChvbmxpbmVFbWFpbHMubGVuZ3RoID09PSAwICYmIHNz
aE9ubGluZS5sZW5ndGggPT09IDAgJiYgc3NoQ29ubkNvdW50ID09PSAwKSB7CiAgICAgIGVtcHR5
RWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgICAgIHJldHVybjsKICAgIH0KCiAgICAvLyDi
lIDilIAgNS4g4LmB4Liq4LiU4LiHIFZMRVNTIG9ubGluZSDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIAKICAgIGlmIChvbmxpbmVFbWFpbHMubGVuZ3RoID4gMCkgewogICAgICB2
bGVzc0VsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnb25saW5lLXZsZXNzLWxpc3QnKS5pbm5lckhUTUwgPSBvbmxpbmVFbWFpbHMubWFwKGVt
YWlsID0+IHsKICAgICAgICBjb25zdCB1ID0gdU1hcFtlbWFpbF0gfHwge307CiAgICAgICAgY29u
c3QgdXNlZEJ5dGVzICA9ICh1LnVwfHwwKSArICh1LmRvd258fDApOwogICAgICAgIGNvbnN0IHRv
dGFsQnl0ZXMgPSB1LnRvdGFsIHx8IDA7CiAgICAgICAgY29uc3QgcGN0ICAgICAgICA9IHRvdGFs
Qnl0ZXMgPiAwID8gTWF0aC5taW4oMTAwLCBNYXRoLnJvdW5kKHVzZWRCeXRlcy90b3RhbEJ5dGVz
KjEwMCkpIDogMDsKICAgICAgICBjb25zdCB1c2VkR0IgICAgID0gKHVzZWRCeXRlcy8xMDczNzQx
ODI0KS50b0ZpeGVkKDIpOwogICAgICAgIGNvbnN0IHRvdGFsR0IgICAgPSB0b3RhbEJ5dGVzID4g
MCA/ICh0b3RhbEJ5dGVzLzEwNzM3NDE4MjQpLnRvRml4ZWQoMSkgOiAn4oieJzsKICAgICAgICBj
b25zdCBiYXJDb2xvciAgID0gcGN0ID4gODUgPyAnI2VmNDQ0NCcgOiBwY3QgPiA2NSA/ICcjZjk3
MzE2JyA6ICd2YXIoLS1hYyknOwogICAgICAgIGNvbnN0IHBvcnQgICAgICAgPSB1LnBvcnQgfHwg
Jz8nOwogICAgICAgIGNvbnN0IGNhcnJpZXIgICAgPSBwb3J0ID09IDgwODAgPyAnQUlTJyA6IHBv
cnQgPT0gODg4MCA/ICdUUlVFJyA6ICdWTCc7CiAgICAgICAgLy8g4Lin4Lix4LiZ4Lir4Lih4LiU
4Lit4Liy4Lii4Li4CiAgICAgICAgY29uc3QgZGwgPSB1LmV4cCAmJiB1LmV4cCA+IDAgPyBNYXRo
LmNlaWwoKHUuZXhwIC0gRGF0ZS5ub3coKSkvODY0MDAwMDApIDogbnVsbDsKICAgICAgICBjb25z
dCBleHBUeHQgPSBkbCA9PT0gbnVsbCA/ICfguYTguKHguYjguIjguLPguIHguLHguJQnIDogZGwg
PCAwID8gJ+C4q+C4oeC4lOC4reC4suC4ouC4uOC5geC4peC5ieC4pycgOiBkbCsnZCc7CiAgICAg
ICAgY29uc3QgZXhwQ2xzID0gZGwgIT09IG51bGwgJiYgZGwgPCAwID8gJyNlZjQ0NDQnIDogZGwg
IT09IG51bGwgJiYgZGwgPD0gMyA/ICcjZjk3MzE2JyA6ICd2YXIoLS1hYyknOwogICAgICAgIHJl
dHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIHN0eWxlPSJmbGV4LWRpcmVjdGlvbjpjb2x1bW47YWxp
Z24taXRlbXM6c3RyZXRjaDtnYXA6OHB4O2N1cnNvcjpkZWZhdWx0Ij4KICAgICAgICAgIDxkaXYg
c3R5bGU9ImRpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHgiPgogICAgICAg
ICAgICA8ZGl2IGNsYXNzPSJ1YXYgYXYtZyIgc3R5bGU9ImZsZXgtc2hyaW5rOjA7cG9zaXRpb246
cmVsYXRpdmUiPgogICAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJmb250LXNpemU6OXB4O2ZvbnQt
ZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMCI+JHtjYXJyaWVyfTwv
c3Bhbj4KICAgICAgICAgICAgICA8c3BhbiBjbGFzcz0iZG90IiBzdHlsZT0icG9zaXRpb246YWJz
b2x1dGU7dG9wOi0ycHg7cmlnaHQ6LTJweDt3aWR0aDo2cHg7aGVpZ2h0OjZweCI+PC9zcGFuPgog
ICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iZmxleDoxO21pbi13aWR0
aDowIj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHtlbWFpbH08L2Rpdj4KICAgICAg
ICAgICAgICA8ZGl2IGNsYXNzPSJ1bSIgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6OHB4O2FsaWdu
LWl0ZW1zOmNlbnRlciI+CiAgICAgICAgICAgICAgICA8c3Bhbj5Qb3J0ICR7cG9ydH08L3NwYW4+
CiAgICAgICAgICAgICAgICA8c3BhbiBzdHlsZT0iY29sb3I6JHtleHBDbHN9O2ZvbnQtZmFtaWx5
OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHgiPiR7ZXhwVHh0fTwvc3Bhbj4KICAg
ICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxzcGFuIGNs
YXNzPSJhYmRnIG9rIiBzdHlsZT0iZm9udC1zaXplOjlweDt3aGl0ZS1zcGFjZTpub3dyYXAiPuKX
jyBPTkxJTkU8L3NwYW4+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgc3R5bGU9InBh
ZGRpbmctbGVmdDo0NnB4Ij4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2p1
c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11
dGVkKTttYXJnaW4tYm90dG9tOjRweCI+CiAgICAgICAgICAgICAgPHNwYW4+JHt1c2VkR0J9IEdC
IOC5g+C4iuC5ieC5hOC4mzwvc3Bhbj4KICAgICAgICAgICAgICA8c3BhbiBzdHlsZT0iY29sb3I6
JHtiYXJDb2xvcn07Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2UiPiR7dG90YWxHQiA9
PT0gJ+KInicgPyAn4oieJyA6IHRvdGFsR0IrJyBHQid9IMK3ICR7cGN0fSU8L3NwYW4+CiAgICAg
ICAgICAgIDwvZGl2PgogICAgICAgICAgICA8ZGl2IHN0eWxlPSJoZWlnaHQ6NnB4O2JhY2tncm91
bmQ6cmdiYSgwLDAsMCwwLjA2KTtib3JkZXItcmFkaXVzOjNweDtvdmVyZmxvdzpoaWRkZW4iPgog
ICAgICAgICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDoxMDAlO3dpZHRoOiR7cGN0fSU7YmFja2dy
b3VuZDoke2JhckNvbG9yfTtib3JkZXItcmFkaXVzOjNweDt0cmFuc2l0aW9uOndpZHRoIDAuOHMg
ZWFzZSI+PC9kaXY+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAg
PC9kaXY+YDsKICAgICAgfSkuam9pbignJyk7CiAgICB9CgogICAgLy8g4pSA4pSAIDYuIOC5geC4
quC4lOC4hyBTU0ggb25saW5lIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKU
gAogICAgaWYgKHNzaE9ubGluZS5sZW5ndGggPiAwKSB7CiAgICAgIHNzaEVsLnN0eWxlLmRpc3Bs
YXkgPSAnYmxvY2snOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXNzaC1s
aXN0JykuaW5uZXJIVE1MID0gc3NoT25saW5lLm1hcCh1ID0+IHsKICAgICAgICBjb25zdCBkbCA9
IHUuZXhwID8gTWF0aC5jZWlsKChuZXcgRGF0ZSh1LmV4cCkgLSBuZXcgRGF0ZSgpKS84NjQwMDAw
MCkgOiBudWxsOwogICAgICAgIGNvbnN0IGV4cFR4dCA9IGRsID09PSBudWxsID8gJ+C5hOC4oeC5
iOC4iOC4s+C4geC4seC4lCcgOiBkbCA8IDAgPyAn4Lir4Lih4LiU4Lit4Liy4Lii4Li4JyA6IGRs
KydkJzsKICAgICAgICBjb25zdCBleHBDbHMgPSBkbCAhPT0gbnVsbCAmJiBkbCA8IDAgPyAnI2Vm
NDQ0NCcgOiBkbCAhPT0gbnVsbCAmJiBkbCA8PSAzID8gJyNmOTczMTYnIDogJyMzYjgyZjYnOwog
ICAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIHN0eWxlPSJjdXJzb3I6ZGVmYXVsdCI+
CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1YXYiIHN0eWxlPSJiYWNrZ3JvdW5kOnJnYmEoNTksMTMw
LDI0NiwwLjE1KTtjb2xvcjojM2I4MmY2O2JvcmRlcjoxcHggc29saWQgcmdiYSg1OSwxMzAsMjQ2
LC4yNSk7ZmxleC1zaHJpbms6MDtwb3NpdGlvbjpyZWxhdGl2ZSI+CiAgICAgICAgICAgIDxzcGFu
IHN0eWxlPSJmb250LXNpemU6OXB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2Zv
bnQtd2VpZ2h0OjcwMCI+U1NIPC9zcGFuPgogICAgICAgICAgICA8c3BhbiBjbGFzcz0iZG90IiBz
dHlsZT0icG9zaXRpb246YWJzb2x1dGU7dG9wOi0ycHg7cmlnaHQ6LTJweDt3aWR0aDo2cHg7aGVp
Z2h0OjZweDtiYWNrZ3JvdW5kOiMzYjgyZjY7Ym94LXNoYWRvdzowIDAgNnB4ICMzYjgyZjY7YW5p
bWF0aW9uOnBscyAxLjVzIGluZmluaXRlIj48L3NwYW4+CiAgICAgICAgICA8L2Rpdj4KICAgICAg
ICAgIDxkaXYgc3R5bGU9ImZsZXg6MTttaW4td2lkdGg6MCI+CiAgICAgICAgICAgIDxkaXYgY2xh
c3M9InVuIj4ke3UudXNlcn08L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0idW0iIHN0eWxl
PSJkaXNwbGF5OmZsZXg7Z2FwOjhweDthbGlnbi1pdGVtczpjZW50ZXIiPgogICAgICAgICAgICAg
IDxzcGFuPkRyb3BiZWFyIDoxNDMvOjEwOTwvc3Bhbj4KICAgICAgICAgICAgICA8c3BhbiBzdHls
ZT0iY29sb3I6JHtleHBDbHN9O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQt
c2l6ZTo5cHgiPiR7ZXhwVHh0fTwvc3Bhbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8
L2Rpdj4KICAgICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIG9rIiBzdHlsZT0iZm9udC1zaXplOjlw
eDt3aGl0ZS1zcGFjZTpub3dyYXAiPuKXjyBPTkxJTkU8L3NwYW4+CiAgICAgICAgPC9kaXY+YDsK
ICAgICAgfSkuam9pbignJyk7CiAgICB9IGVsc2UgaWYgKHNzaENvbm5Db3VudCA+IDApIHsKICAg
ICAgLy8g4Lih4Li1IGNvbm5lY3Rpb24g4LmB4LiV4LmI4LmE4Lih4LmI4Lij4Li54LmJ4LiK4Li3
4LmI4LitIHVzZXIg4oaSIOC5geC4quC4lOC4h+C5gOC4m+C5h+C4mSBjb25uZWN0aW9uIGNvdW50
CiAgICAgIHNzaEVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogICAgICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnb25saW5lLXNzaC1saXN0JykuaW5uZXJIVE1MID0KICAgICAgICBgPGRpdiBj
bGFzcz0idWl0ZW0iIHN0eWxlPSJjdXJzb3I6ZGVmYXVsdCI+CiAgICAgICAgICA8ZGl2IGNsYXNz
PSJ1YXYiIHN0eWxlPSJiYWNrZ3JvdW5kOnJnYmEoNTksMTMwLDI0NiwwLjE1KTtjb2xvcjojM2I4
MmY2O2JvcmRlcjoxcHggc29saWQgcmdiYSg1OSwxMzAsMjQ2LC4yNSk7ZmxleC1zaHJpbms6MDtw
b3NpdGlvbjpyZWxhdGl2ZSI+CiAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJmb250LXNpemU6OXB4
O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMCI+U1NIPC9z
cGFuPgogICAgICAgICAgICA8c3BhbiBjbGFzcz0iZG90IiBzdHlsZT0icG9zaXRpb246YWJzb2x1
dGU7dG9wOi0ycHg7cmlnaHQ6LTJweDt3aWR0aDo2cHg7aGVpZ2h0OjZweDtiYWNrZ3JvdW5kOiMz
YjgyZjY7Ym94LXNoYWRvdzowIDAgNnB4ICMzYjgyZjY7YW5pbWF0aW9uOnBscyAxLjVzIGluZmlu
aXRlIj48L3NwYW4+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6
MSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3NzaENvbm5Db3VudH0gYWN0aXZlIGNv
bm5lY3Rpb24ke3NzaENvbm5Db3VudD4xPydzJzonJ308L2Rpdj4KICAgICAgICAgICAgPGRpdiBj
bGFzcz0idW0iPkRyb3BiZWFyIMK3IHBvcnQgMTQzLzEwOS84MDwvZGl2PgogICAgICAgICAgPC9k
aXY+CiAgICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayIgc3R5bGU9ImZvbnQtc2l6ZTo5cHg7
d2hpdGUtc3BhY2U6bm93cmFwIj7il48gT05MSU5FPC9zcGFuPgogICAgICAgIDwvZGl2PmA7CiAg
ICB9CgogIH0gY2F0Y2goZSkgewogICAgbG9hZEVsLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJs
b2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+4p2MICcrZS5tZXNzYWdlKyc8L2Rpdj4nOwog
ICAgbG9hZEVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIH0KfQoKLy8g4LmC4Lir4Lil4LiU
IHVzZXJzIOC5geC4muC4muC5gOC4h+C4teC4ouC4muC5hiDguYTguKHguYggcmVuZGVyIFVJCmFz
eW5jIGZ1bmN0aW9uIGxvYWRVc2Vyc1F1aWV0KCkgewogIHRyeSB7CiAgICBpZiAoIV94dWlPaykg
YXdhaXQgeHVpTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkv
aW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHJldHVybjsKICAgIF9hbGxVc2Vy
cyA9IFtdOwogICAgLy8g4LiU4Li24LiHIGNsaWVudFN0YXRzIOC5geC4ouC4geC4leC5iOC4suC4
h+C4q+C4suC4gQogICAgY29uc3Qgc3RhdHNNYXAgPSB7fTsKICAgIHRyeSB7CiAgICAgIGNvbnN0
IHN0YXRzQWxsID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2NsaWVudFRyYWZm
aWNzL2FsbCcpLmNhdGNoKCgpPT5udWxsKTsKICAgICAgaWYgKHN0YXRzQWxsICYmIHN0YXRzQWxs
LnN1Y2Nlc3MgJiYgc3RhdHNBbGwub2JqKSB7CiAgICAgICAgc3RhdHNBbGwub2JqLmZvckVhY2go
cyA9PiB7IHN0YXRzTWFwW3MuZW1haWxdID0gczsgfSk7CiAgICAgIH0KICAgIH0gY2F0Y2goZTIp
IHt9CiAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgY29uc3Qgc2V0dGluZ3Mg
PSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3Mp
IDogaWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+
IHsKICAgICAgICBjb25zdCBlbWFpbCA9IGMuZW1haWx8fGMuaWQ7CiAgICAgICAgY29uc3Qgc3Qg
PSBzdGF0c01hcFtlbWFpbF07CiAgICAgICAgX2FsbFVzZXJzLnB1c2goewogICAgICAgICAgaWJJ
ZDogaWIuaWQsIHBvcnQ6IGliLnBvcnQsIHByb3RvOiBpYi5wcm90b2NvbCwKICAgICAgICAgIGVt
YWlsOiBlbWFpbCwgdXVpZDogYy5pZCwKICAgICAgICAgIGV4cDogYy5leHBpcnlUaW1lfHwwLCB0
b3RhbDogYy50b3RhbEdCfHwwLAogICAgICAgICAgdXA6IHN0ID8gKHN0LnVwfHwwKSA6IDAsIGRv
d246IHN0ID8gKHN0LmRvd258fDApIDogMCwgbGltaXRJcDogYy5saW1pdElwfHwwCiAgICAgICAg
fSk7CiAgICAgIH0pOwogICAgfSk7CiAgfSBjYXRjaChlKSB7fQp9CgovLyDilZDilZDilZDilZAg
QkFOIC8gVU5CQU4gU1lTVEVNIOKVkOKVkOKVkOKVkAovLyDguJXguLHguKfguYHguJvguKPguYDg
uIHguYfguJrguKPguLLguKLguIHguLLguKMgYmFubmVkIHVzZXJzICsgY291bnRkb3duIHRpbWVy
cwpsZXQgX2Jhbm5lZFRpbWVycyA9IHt9OwpsZXQgX2Jhbm5lZFVzZXJzID0gW107CgovLyDguYLg
uKvguKXguJTguKPguLLguKLguIHguLLguKPguJfguLXguYjguJbguLnguIHguYHguJrguJkKYXN5
bmMgZnVuY3Rpb24gbG9hZEJhbm5lZFVzZXJzKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdiYW5uZWQtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil
4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0
IGZldGNoKEFQSSsnL2Jhbm5lZCcpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsK
ICAgIC8vIOC4luC5ieC4siBBUEkg4Lii4Lix4LiH4LmE4Lih4LmI4Lij4Lit4LiH4Lij4Lix4Lia
IGVuZHBvaW50IC9iYW5uZWQg4LmD4Lir4LmJ4LmD4LiK4LmJ4LiC4LmJ4Lit4Lih4Li54Lil4LiI
4Liy4LiBIHgtdWkgY2xpZW50U3RhdHMKICAgIGxldCBiYW5uZWQgPSBbXTsKICAgIGlmIChkICYm
IGQuYmFubmVkKSB7CiAgICAgIGJhbm5lZCA9IGQuYmFubmVkOwogICAgfSBlbHNlIHsKICAgICAg
Ly8gZmFsbGJhY2s6IOC4lOC4tuC4h+C4iOC4suC4gSB4LXVpIOC4leC4o+C4p+C4iCBjbGllbnRz
IOC4l+C4teC5iOC4luC4ueC4gSBkaXNhYmxlIOC5gOC4nuC4o+C4suC4sCBJUCBsaW1pdAogICAg
ICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgICAgY29uc3QgaWJMaXN0ID0gYXdh
aXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAg
ICAgIGlmIChpYkxpc3QgJiYgaWJMaXN0Lm9iaikgewogICAgICAgIGNvbnN0IG5vdyA9IERhdGUu
bm93KCk7CiAgICAgICAgKGliTGlzdC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAg
IGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBh
cnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAgICAgKHNldHRpbmdzLmNsaWVu
dHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBpZiAoYy5lbmFibGUgPT09IGZhbHNl
KSB7CiAgICAgICAgICAgICAgLy8g4LiW4LmJ4LiyIHVzZXIg4LiW4Li54LiBIGRpc2FibGUg4LiW
4Li34Lit4Lin4LmI4Liy4LmC4LiU4LiZ4LmB4Lia4LiZCiAgICAgICAgICAgICAgYmFubmVkLnB1
c2goewogICAgICAgICAgICAgICAgdXNlcjogYy5lbWFpbCB8fCBjLmlkLAogICAgICAgICAgICAg
ICAgdHlwZTogJ3ZsZXNzJywKICAgICAgICAgICAgICAgIHBvcnQ6IGliLnBvcnQsCiAgICAgICAg
ICAgICAgICBiYW5UaW1lOiBub3csCiAgICAgICAgICAgICAgICB1bmJhblRpbWU6IG5vdyArIDM2
MDAwMDAgLy8gMSDguIrguLHguYjguKfguYLguKHguIcgKOC4quC4oeC4oeC4uOC4leC4tCkKICAg
ICAgICAgICAgICB9KTsKICAgICAgICAgICAgfQogICAgICAgICAgfSk7CiAgICAgICAgfSk7CiAg
ICAgIH0KICAgIH0KICAgIF9iYW5uZWRVc2VycyA9IGJhbm5lZDsKCiAgICAvLyBDbGVhciBvbGQg
dGltZXJzCiAgICBPYmplY3QudmFsdWVzKF9iYW5uZWRUaW1lcnMpLmZvckVhY2godD0+Y2xlYXJJ
bnRlcnZhbCh0KSk7CiAgICBfYmFubmVkVGltZXJzID0ge307CgogICAgaWYgKCFiYW5uZWQubGVu
Z3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW5uZWQtbGlzdCcpLmlubmVy
SFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7inIU8L2Rpdj48cD7guYTguKHg
uYjguKHguLXguKLguLnguKrguYDguIvguK3guKPguYzguJbguLnguIHguYHguJrguJnguK3guKLg
uLnguYg8L3A+PC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQogICAgcmVuZGVyQmFubmVkTGlz
dChiYW5uZWQpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jh
bm5lZC1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6
I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CgpmdW5jdGlvbiByZW5kZXJCYW5u
ZWRMaXN0KGJhbm5lZCkgewogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Jhbm5lZC1saXN0JykuaW5uZXJIVE1MID0gYmFubmVkLm1hcCgoYixpKSA9
PiB7CiAgICBjb25zdCByZW1haW5pbmcgPSBiLnVuYmFuVGltZSA/IE1hdGgubWF4KDAsIGIudW5i
YW5UaW1lIC0gbm93KSA6IDM2MDAwMDA7CiAgICBjb25zdCBtaW5zID0gTWF0aC5mbG9vcihyZW1h
aW5pbmcvNjAwMDApOwogICAgY29uc3Qgc2VjcyA9IE1hdGguZmxvb3IoKHJlbWFpbmluZyU2MDAw
MCkvMTAwMCk7CiAgICBjb25zdCB0eXBlTGFiZWwgPSBiLnR5cGU9PT0nc3NoJyA/ICdTU0gnIDog
J1ZMRVNTJzsKICAgIGNvbnN0IHR5cGVCZyA9IGIudHlwZT09PSdzc2gnID8gJ3JnYmEoNTksMTMw
LDI0NiwwLjE1KScgOiAncmdiYSgyMzksNjgsNjgsMC4xMiknOwogICAgY29uc3QgdHlwZUNvbG9y
ID0gYi50eXBlPT09J3NzaCcgPyAnIzNiODJmNicgOiAnI2VmNDQ0NCc7CiAgICByZXR1cm4gYDxk
aXYgY2xhc3M9InVpdGVtIiBpZD0iYmFubmVkLWl0ZW0tJHtpfSIgc3R5bGU9ImZsZXgtZGlyZWN0
aW9uOmNvbHVtbjthbGlnbi1pdGVtczpzdHJldGNoO2dhcDo4cHgiPgogICAgICA8ZGl2IHN0eWxl
PSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4Ij4KICAgICAgICA8ZGl2
IGNsYXNzPSJ1YXYiIHN0eWxlPSJiYWNrZ3JvdW5kOiR7dHlwZUJnfTtjb2xvcjoke3R5cGVDb2xv
cn07Ym9yZGVyOjFweCBzb2xpZCAke3R5cGVDb2xvcn0zMztmbGV4LXNocmluazowIj4KICAgICAg
ICAgIDxzcGFuIHN0eWxlPSJmb250LXNpemU6OXB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9u
b3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMCI+JHt0eXBlTGFiZWx9PC9zcGFuPgogICAgICAgIDwvZGl2
PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+
JHtiLnVzZXJ9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+UG9ydCAke2IucG9ydHx8
Jz8nfSDCtyDguYDguIHguLTguJkgSVAgTGltaXQ8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAg
ICA8YnV0dG9uIG9uY2xpY2s9InVuYmFuVXNlckRpcmVjdCgnJHtiLnVzZXJ9JywnJHtiLnR5cGV8
fCd2bGVzcyd9Jywke2IuaWJJZHx8MH0sJyR7Yi51dWlkfHwnJ30nKSIgCiAgICAgICAgICBzdHls
ZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNiNDUzMDksI2Q5NzcwNik7Ym9y
ZGVyOm5vbmU7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo2cHggMTJweDtmb250LXNpemU6MTFw
eDtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNl
cmlmO2ZvbnQtd2VpZ2h0OjcwMDt3aGl0ZS1zcGFjZTpub3dyYXAiPgogICAgICAgICAg8J+UkyDg
uJvguKXguJQKICAgICAgICA8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9
InBhZGRpbmctbGVmdDo0NnB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhw
eCI+CiAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQp
Ij7guKvguKHguJTguYHguJrguJnguYPguJk6PC9kaXY+CiAgICAgICAgPGRpdiBpZD0iY291bnRk
b3duLSR7aX0iIHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNp
emU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6I2Y5NzMxNjtiYWNrZ3JvdW5kOnJnYmEoMjQ5
LDExNSwyMiwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNDksMTE1LDIyLDAuMyk7Ym9yZGVy
LXJhZGl1czo2cHg7cGFkZGluZzoycHggOHB4Ij4KICAgICAgICAgICR7U3RyaW5nKG1pbnMpLnBh
ZFN0YXJ0KDIsJzAnKX06JHtTdHJpbmcoc2VjcykucGFkU3RhcnQoMiwnMCcpfQogICAgICAgIDwv
ZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MTtoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdi
YSgwLDAsMCwwLjA2KTtib3JkZXItcmFkaXVzOjJweDtvdmVyZmxvdzpoaWRkZW4iPgogICAgICAg
ICAgPGRpdiBpZD0iY291bnRkb3duLWJhci0ke2l9IiBzdHlsZT0iaGVpZ2h0OjEwMCU7YmFja2dy
b3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2Y5NzMxNiwjZmI5MjNjKTtib3JkZXItcmFkaXVz
OjJweDt0cmFuc2l0aW9uOndpZHRoIDFzIGxpbmVhcjt3aWR0aDoke01hdGgubWluKDEwMCwocmVt
YWluaW5nLzM2MDAwMDApKjEwMCl9JSI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2
PgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKCiAgLy8gU3RhcnQgY291bnRkb3ducwogIGJh
bm5lZC5mb3JFYWNoKChiLGkpID0+IHsKICAgIF9iYW5uZWRUaW1lcnNbaV0gPSBzZXRJbnRlcnZh
bCgoKSA9PiB7CiAgICAgIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvdW50
ZG93bi0nK2kpOwogICAgICBjb25zdCBiYXJFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdj
b3VudGRvd24tYmFyLScraSk7CiAgICAgIGlmICghZWwpIHsgY2xlYXJJbnRlcnZhbChfYmFubmVk
VGltZXJzW2ldKTsgcmV0dXJuOyB9CiAgICAgIGNvbnN0IHJlbSA9IE1hdGgubWF4KDAsIGIudW5i
YW5UaW1lIC0gRGF0ZS5ub3coKSk7CiAgICAgIGNvbnN0IG0gPSBNYXRoLmZsb29yKHJlbS82MDAw
MCk7CiAgICAgIGNvbnN0IHMgPSBNYXRoLmZsb29yKChyZW0lNjAwMDApLzEwMDApOwogICAgICBl
bC50ZXh0Q29udGVudCA9IFN0cmluZyhtKS5wYWRTdGFydCgyLCcwJykrJzonK1N0cmluZyhzKS5w
YWRTdGFydCgyLCcwJyk7CiAgICAgIGlmIChiYXJFbCkgYmFyRWwuc3R5bGUud2lkdGggPSBNYXRo
Lm1pbigxMDAsKHJlbS8zNjAwMDAwKSoxMDApKyclJzsKICAgICAgaWYgKHJlbSA8PSAwKSB7CiAg
ICAgICAgY2xlYXJJbnRlcnZhbChfYmFubmVkVGltZXJzW2ldKTsKICAgICAgICBlbC50ZXh0Q29u
dGVudCA9ICcwMDowMCc7CiAgICAgICAgZWwuc3R5bGUuY29sb3IgPSAndmFyKC0tYWMpJzsKICAg
ICAgICBlbC5zdHlsZS5ib3JkZXJDb2xvciA9ICdyZ2JhKDM0LDE5Nyw5NCwwLjMpJzsKICAgICAg
ICBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ3JnYmEoMzQsMTk3LDk0LDAuMSknOwogICAgICAgIC8v
IEF1dG8gcmVsb2FkIGFmdGVyIGJhbiB0aW1lCiAgICAgICAgc2V0VGltZW91dChsb2FkQmFubmVk
VXNlcnMsIDIwMDApOwogICAgICB9CiAgICB9LCAxMDAwKTsKICB9KTsKfQoKLy8g4Lib4Lil4LiU
4Lil4LmH4Lit4LiE4LmC4LiU4Lii4Lie4Li04Lih4Lie4LmM4LiK4Li34LmI4Lit4LmD4LiZ4LiK
4LmI4Lit4LiHIGlucHV0CmFzeW5jIGZ1bmN0aW9uIHVuYmFuVXNlcigpIHsKICBjb25zdCB1c2Vy
ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgpOwogIGlm
ICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD
4Liq4LmIIFVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4m+C4peC4lOC4
peC5h+C4reC4hCcsJ2VycicpOwogIAogIGNvbnN0IGJ0biA9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0
b3IoJ1tvbmNsaWNrPSJ1bmJhblVzZXIoKSJdJyk7CiAgaWYgKGJ0bikgeyBidG4uZGlzYWJsZWQ9
dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj4g4LiB4Liz4Lil
4Lix4LiH4Lib4Lil4LiULi4uJzsgfQogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tYWxl
cnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKCiAgdHJ5IHsKICAgIC8vIOC4nuC4ouC4suC4ouC4
suC4oSBlbmFibGUgY2xpZW50IOC5g+C4mSB4LXVpCiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVp
TG9naW4oKTsKICAgIAogICAgbGV0IGZvdW5kID0gZmFsc2U7CiAgICBjb25zdCBpYkxpc3QgPSBh
d2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpLmNhdGNoKCgpPT5udWxsKTsK
ICAgIGlmIChpYkxpc3QgJiYgaWJMaXN0Lm9iaikgewogICAgICBmb3IgKGNvbnN0IGliIG9mIGli
TGlzdC5vYmopIHsKICAgICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09
PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAg
ICBjb25zdCBjbGllbnQgPSAoc2V0dGluZ3MuY2xpZW50c3x8W10pLmZpbmQoYyA9PiAoYy5lbWFp
bHx8Yy5pZCkgPT09IHVzZXIpOwogICAgICAgIGlmIChjbGllbnQpIHsKICAgICAgICAgIC8vIEVu
YWJsZSBjbGllbnQKICAgICAgICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9h
cGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrY2xpZW50LmlkLCB7CiAgICAgICAgICAgIGlkOiBp
Yi5pZCwKICAgICAgICAgICAgc2V0dGluZ3M6IEpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7CiAg
ICAgICAgICAgICAgaWQ6Y2xpZW50LmlkLCBmbG93OmNsaWVudC5mbG93fHwnJywgZW1haWw6Y2xp
ZW50LmVtYWlsfHxjbGllbnQuaWQsCiAgICAgICAgICAgICAgbGltaXRJcDpjbGllbnQubGltaXRJ
cHx8MCwgdG90YWxHQjpjbGllbnQudG90YWxHQnx8MCwKICAgICAgICAgICAgICBleHBpcnlUaW1l
OmNsaWVudC5leHBpcnlUaW1lfHwwLCBlbmFibGU6dHJ1ZSwKICAgICAgICAgICAgICB0Z0lkOicn
LCBzdWJJZDonJywgY29tbWVudDonJywgcmVzZXQ6MAogICAgICAgICAgICB9XX0pCiAgICAgICAg
ICB9KTsKICAgICAgICAgIGlmIChyZXMuc3VjY2VzcykgeyBmb3VuZCA9IHRydWU7IGJyZWFrOyB9
CiAgICAgICAgfQogICAgICB9CiAgICB9CiAgICAKICAgIC8vIOC4peC4muC4reC4reC4geC4iOC4
suC4gSBpcHRhYmxlcyAo4LiW4LmJ4LiyIFNTSCBiYW4pCiAgICBhd2FpdCBmZXRjaChBUEkrJy91
bmJhbicsIHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBw
bGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSkKICAgIH0p
LmNhdGNoKCgpPT57fSk7CgogICAgaWYgKGZvdW5kKSB7CiAgICAgIHNob3dBbGVydCgnYmFuLWFs
ZXJ0Jywn4pyFIOC4m+C4peC4lOC4peC5h+C4reC4hCAnK3VzZXIrJyDguKrguLPguYDguKPguYfg
uIgg4oCUIOC4quC4suC4oeC4suC4o+C4luC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4reC5hOC4
lOC5ieC4l+C4seC4meC4l+C4tScsJ29rJyk7CiAgICB9IGVsc2UgewogICAgICAvLyDguYTguKHg
uYjguJ7guJrguYPguJkgeC11aSDguYHguJXguYjguK3guLLguIjguYDguJvguYfguJkgU1NIIOKA
lCDguJbguLfguK3guKfguYjguLLguJvguKXguJTguYTguJTguYkKICAgICAgc2hvd0FsZXJ0KCdi
YW4tYWxlcnQnLCfinIUg4Liq4LmI4LiH4LiE4Liz4Liq4Lix4LmI4LiH4Lib4Lil4LiU4Lil4LmH
4Lit4LiEICcrdXNlcisnIOC5geC4peC5ieC4pycsJ29rJyk7CiAgICB9CiAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZT0nJzsKICAgIGxvYWRCYW5uZWRVc2Vycygp
OwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwn
ZXJyJyk7IH0KICBmaW5hbGx5IHsKICAgIGlmIChidG4pIHsgYnRuLmRpc2FibGVkPWZhbHNlOyBi
dG4uaW5uZXJIVE1MPSfwn5STIOC4m+C4peC4lOC4peC5h+C4reC4hCBJUCBCYW4nOyB9CiAgfQp9
CgovLyDguJvguKXguJTguKXguYfguK3guITguYLguJTguKLguIHguJTguJvguLjguYjguKHguIjg
uLLguIHguKPguLLguKLguIHguLLguKMKYXN5bmMgZnVuY3Rpb24gdW5iYW5Vc2VyRGlyZWN0KHVz
ZXIsIHR5cGUsIGliSWQsIHV1aWQpIHsKICB0cnkgewogICAgaWYgKHR5cGUgPT09ICd2bGVzcycg
JiYgdXVpZCkgewogICAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgICAgLy8g
4LiV4LmJ4Lit4LiH4LiU4Li24LiHIGNsaWVudCBkYXRhIOC5gOC4leC5h+C4oeC4geC5iOC4reC4
mQogICAgICBjb25zdCBpYkxpc3QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMv
bGlzdCcpLmNhdGNoKCgpPT5udWxsKTsKICAgICAgbGV0IGZvdW5kID0gZmFsc2U7CiAgICAgIGlm
IChpYkxpc3QgJiYgaWJMaXN0Lm9iaikgewogICAgICAgIGZvciAoY29uc3QgaWIgb2YgaWJMaXN0
Lm9iaikgewogICAgICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0n
c3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgICAg
ICBjb25zdCBjbGllbnQgPSAoc2V0dGluZ3MuY2xpZW50c3x8W10pLmZpbmQoYyA9PiAoYy5lbWFp
bHx8Yy5pZCkgPT09IHVzZXIpOwogICAgICAgICAgaWYgKGNsaWVudCkgewogICAgICAgICAgICBj
b25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVu
dC8nK2NsaWVudC5pZCwgewogICAgICAgICAgICAgIGlkOiBpYi5pZCwKICAgICAgICAgICAgICBz
ZXR0aW5nczogSlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3sKICAgICAgICAgICAgICAgIGlkOmNs
aWVudC5pZCwgZmxvdzpjbGllbnQuZmxvd3x8JycsIGVtYWlsOmNsaWVudC5lbWFpbHx8Y2xpZW50
LmlkLAogICAgICAgICAgICAgICAgbGltaXRJcDpjbGllbnQubGltaXRJcHx8MCwgdG90YWxHQjpj
bGllbnQudG90YWxHQnx8MCwKICAgICAgICAgICAgICAgIGV4cGlyeVRpbWU6Y2xpZW50LmV4cGly
eVRpbWV8fDAsIGVuYWJsZTp0cnVlLAogICAgICAgICAgICAgICAgdGdJZDonJywgc3ViSWQ6Jycs
IGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgICAgICAgICB9XX0pCiAgICAgICAgICAgIH0pOwog
ICAgICAgICAgICBpZiAocmVzLnN1Y2Nlc3MpIHsgZm91bmQgPSB0cnVlOyBicmVhazsgfQogICAg
ICAgICAgfQogICAgICAgIH0KICAgICAgfQogICAgfQogICAgYXdhaXQgZmV0Y2goQVBJKycvdW5i
YW4nLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxp
Y2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pCiAgICB9KS5j
YXRjaCgoKT0+e30pOwogICAgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinIUg4Lib4Lil4LiU4Lil
4LmH4Lit4LiEICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZT0nJzsKICAgIHNldFRpbWVvdXQobG9h
ZEJhbm5lZFVzZXJzLCA4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ2Jhbi1hbGVydCcs
J+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KfQoKLy8gTGVnYWN5OiDguKLguLHguIfguITguIcg
ZGVsZXRlU1NIIOC5hOC4p+C5ieC5g+C4iuC5ieC4iOC4suC4geC4l+C4teC5iOC4reC4t+C5iOC4
mQphc3luYyBmdW5jdGlvbiBkZWxldGVTU0goKSB7CiAgcmV0dXJuIHVuYmFuVXNlcigpOwp9Cgov
LyDguYLguKvguKXguJQgU1NIIFVzZXJzIOC4quC4s+C4q+C4o+C4seC4miByZWZlcmVuY2UKYXN5
bmMgZnVuY3Rpb24gbG9hZFNTSFVzZXJzKCkgewogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQg
ZmV0Y2goQVBJKycvdXNlcnMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIHJldHVybiBkLnVzZXJz
IHx8IFtdOwogIH0gY2F0Y2goZSkgeyByZXR1cm4gW107IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIENP
UFkg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGNvcHlMaW5rKGlkLCBidG4pIHsKICBjb25zdCB0eHQg
PSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkudGV4dENvbnRlbnQ7CiAgbmF2aWdhdG9yLmNs
aXBib2FyZC53cml0ZVRleHQodHh0KS50aGVuKCgpPT57CiAgICBjb25zdCBvcmlnID0gYnRuLnRl
eHRDb250ZW50OwogICAgYnRuLnRleHRDb250ZW50PSfinIUgQ29waWVkISc7IGJ0bi5zdHlsZS5i
YWNrZ3JvdW5kPSdyZ2JhKDM0LDE5Nyw5NCwuMTUpJzsKICAgIHNldFRpbWVvdXQoKCk9PnsgYnRu
LnRleHRDb250ZW50PW9yaWc7IGJ0bi5zdHlsZS5iYWNrZ3JvdW5kPScnOyB9LCAyMDAwKTsKICB9
KS5jYXRjaCgoKT0+eyBwcm9tcHQoJ0NvcHkgbGluazonLCB0eHQpOyB9KTsKfQoKLy8g4pWQ4pWQ
4pWQ4pWQIExPR09VVCDilZDilZDilZDilZAKZnVuY3Rpb24gZG9Mb2dvdXQoKSB7CiAgc2Vzc2lv
blN0b3JhZ2UucmVtb3ZlSXRlbShTRVNTSU9OX0tFWSk7CiAgbG9jYXRpb24ucmVwbGFjZSgnaW5k
ZXguaHRtbCcpOwp9CgovLyDilZDilZDilZDilZAgVVBEQVRFIOKVkOKVkOKVkOKVkApsZXQgX3Vw
ZGF0ZUFjdGl2ZSA9IGZhbHNlOwpsZXQgX3VwZGF0ZVNpZCA9IG51bGw7CmxldCBfcHJvbXB0VGlt
ZXIgPSBudWxsOwpmdW5jdGlvbiBjbGVhclVwZGF0ZUxvZygpIHsKICBjb25zdCBsb2cgPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLWxvZycpOwogIGlmIChsb2cpIHsgbG9nLnRleHRD
b250ZW50ID0gJyc7IGxvZy5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOyB9CiAgY29uc3Qgc3QgPSBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLXN0YXR1cycpOwogIGlmIChzdCkgc3Quc3R5
bGUuZGlzcGxheSA9ICdub25lJzsKICBjb25zdCBwdyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCd1cGRhdGUtcHJvZ3Jlc3Mtd3JhcCcpOwogIGlmIChwdykgcHcuc3R5bGUuZGlzcGxheSA9ICdu
b25lJzsKICBoaWRlVXBkYXRlSW5wdXQoKTsKfQpmdW5jdGlvbiBzaG93VXBkYXRlSW5wdXQobGFi
ZWwpIHsKICBjb25zdCB3cmFwID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1pbnB1
dC13cmFwJyk7CiAgY29uc3QgbGJsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGRhdGUt
aW5wdXQtbGFiZWwnKTsKICBjb25zdCBib3ggID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Vw
ZGF0ZS1pbnB1dC1ib3gnKTsKICBpZiAoIXdyYXApIHJldHVybjsKICBpZiAobGFiZWwpIGxibC50
ZXh0Q29udGVudCA9IGxhYmVsOwogIHdyYXAuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgYm94
LnZhbHVlID0gJyc7CiAgc2V0VGltZW91dCgoKT0+Ym94LmZvY3VzKCksIDUwKTsKfQpmdW5jdGlv
biBoaWRlVXBkYXRlSW5wdXQoKSB7CiAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRC
eUlkKCd1cGRhdGUtaW5wdXQtd3JhcCcpOwogIGlmICh3cmFwKSB3cmFwLnN0eWxlLmRpc3BsYXkg
PSAnbm9uZSc7CiAgaWYgKF9wcm9tcHRUaW1lcikgeyBjbGVhclRpbWVvdXQoX3Byb21wdFRpbWVy
KTsgX3Byb21wdFRpbWVyID0gbnVsbDsgfQp9CmFzeW5jIGZ1bmN0aW9uIHNlbmRVcGRhdGVJbnB1
dChmb3JjZWQpIHsKICBpZiAoIV91cGRhdGVTaWQpIHJldHVybjsKICBjb25zdCBib3ggPSBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLWlucHV0LWJveCcpOwogIGNvbnN0IHZhbCA9IChm
b3JjZWQgIT09IHVuZGVmaW5lZCkgPyBmb3JjZWQgOiAoYm94ID8gYm94LnZhbHVlIDogJycpOwog
IHRyeSB7CiAgICBhd2FpdCBmZXRjaChBUEkgKyAnL3VwZGF0ZV9pbnB1dCcsIHsKICAgICAgbWV0
aG9kOiAnUE9TVCcsCiAgICAgIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlv
bi9qc29uJyB9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IHNpZDogX3VwZGF0ZVNpZCwg
aW5wdXQ6IHZhbCB9KQogICAgfSk7CiAgICBpZiAoYm94KSBib3gudmFsdWUgPSAnJzsKICAgIGhp
ZGVVcGRhdGVJbnB1dCgpOwogIH0gY2F0Y2goZSkgewogICAgYWxlcnQoJ+C4quC5iOC4hyBpbnB1
dCDguYTguKHguYjguKrguLPguYDguKPguYfguIg6ICcgKyBlLm1lc3NhZ2UpOwogIH0KfQovLyDg
uYDguIrguYfguITguKfguYjguLIgdGV4dCDguJTguLnguYDguKvguKHguLfguK3guJkgcHJvbXB0
IOC4l+C4teC5iOC4o+C4rSBpbnB1dCDguIjguLLguIEgdXNlciDguKvguKPguLfguK3guYTguKHg
uYgKZnVuY3Rpb24gbG9va3NMaWtlUHJvbXB0KGJ1ZikgewogIGlmICghYnVmKSByZXR1cm4gbnVs
bDsKICAvLyDguYDguK3guLLguYDguInguJ7guLLguLDguJrguKPguKPguJfguLHguJTguKrguLjg
uJTguJfguYnguLLguKLguJfguLXguYjguKLguLHguIfguYTguKHguYjguKHguLUgbmV3bGluZQog
IGNvbnN0IGlkeCA9IGJ1Zi5sYXN0SW5kZXhPZignXG4nKTsKICBjb25zdCB0YWlsID0gKGlkeCA+
PSAwID8gYnVmLnNsaWNlKGlkeCsxKSA6IGJ1ZikucmVwbGFjZSgvXHgxYlxbWzAtOTtdKlthLXpB
LVpdL2csJycpLnRyaW0oKTsKICBpZiAoIXRhaWwpIHJldHVybiBudWxsOwogIC8vIFBhdHRlcm46
IOC4peC4h+C4l+C5ieC4suC4ouC4lOC5ieC4p+C4oiA6ID8gXSA+IOC4q+C4o+C4t+C4reC4oeC4
teC4hOC4s+C4p+C5iOC4siAi4LiB4Lij4Li44LiT4LiyIiAi4LmC4Lib4Lij4LiUIiAiRW50ZXIi
ICJbWS9uXSIKICBpZiAoL1s6Pz5cXV1ccyokLy50ZXN0KHRhaWwpKSByZXR1cm4gdGFpbDsKICBp
ZiAoL1xbeVwvblxdfFxbWVwvblxdfFxbeVwvTlxdL2kudGVzdCh0YWlsKSkgcmV0dXJuIHRhaWw7
CiAgaWYgKC8o4LiB4Lij4Li44LiT4LiyfOC5guC4m+C4o+C4lHzguYPguKrguYh84Lie4Li04Lih
4Lie4LmMfOC4m+C5ieC4reC4mXzguKPguLDguJrguLgpLipbOj9dP1xzKiQvLnRlc3QodGFpbCkp
IHJldHVybiB0YWlsOwogIGlmICgvKGVudGVyfGlucHV0fHBhc3N3b3JkfHVzZXJuYW1lfGRvbWFp
bnxlbWFpbCkvaS50ZXN0KHRhaWwpICYmIHRhaWwubGVuZ3RoIDwgMTIwKSByZXR1cm4gdGFpbDsK
ICByZXR1cm4gbnVsbDsKfQphc3luYyBmdW5jdGlvbiBzdGFydFVwZGF0ZSgpIHsKICBpZiAoX3Vw
ZGF0ZUFjdGl2ZSkgcmV0dXJuOwogIGNvbnN0IHVybCA9IChkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgndXBkYXRlLXVybCcpLnZhbHVlIHx8ICcnKS50cmltKCk7CiAgaWYgKCF1cmwuc3RhcnRzV2l0
aCgnaHR0cHM6Ly8nKSkgcmV0dXJuIGFsZXJ0KCdVUkwg4LmE4Lih4LmI4LiW4Li54LiB4LiV4LmJ
4Lit4LiHJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1i
dG4nKTsKICBjb25zdCBsb2cgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLWxvZycp
OwogIGNvbnN0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1zdGF0dXMnKTsK
ICBjb25zdCBwdyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGRhdGUtcHJvZ3Jlc3Mtd3Jh
cCcpOwogIGNvbnN0IHBiYXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLXByb2dy
ZXNzLWJhcicpOwogIGNvbnN0IHBsYmwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRl
LXByb2dyZXNzLWxhYmVsJyk7CiAgX3VwZGF0ZUFjdGl2ZSA9IHRydWU7CiAgX3VwZGF0ZVNpZCA9
IG51bGw7CiAgaGlkZVVwZGF0ZUlucHV0KCk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4u
aW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+IOC4geC4s+C4peC4seC4hyBV
cGRhdGUuLi4nOwogIGxvZy50ZXh0Q29udGVudCA9ICcnOwogIGxvZy5zdHlsZS5kaXNwbGF5ID0g
J2Jsb2NrJzsKICBwdy5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBwYmFyLnN0eWxlLndpZHRo
ID0gJzUlJzsKICBwbGJsLnRleHRDb250ZW50ID0gJ+C4geC4s+C4peC4seC4h+C5gOC4iuC4t+C5
iOC4reC4oeC4leC5iOC4rS4uLic7CiAgc3Quc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBsZXQg
bGluZUNvdW50ID0gMDsKICB0cnkgewogICAgY29uc3QgcmVzcCA9IGF3YWl0IGZldGNoKEFQSSAr
ICcvdXBkYXRlJywgewogICAgICBtZXRob2Q6ICdQT1NUJywKICAgICAgaGVhZGVyczogeyAnQ29u
dGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nIH0sCiAgICAgIGJvZHk6IEpTT04uc3RyaW5n
aWZ5KHsgdXJsIH0pCiAgICB9KTsKICAgIGlmICghcmVzcC5vayB8fCAhcmVzcC5ib2R5KSB0aHJv
dyBuZXcgRXJyb3IoJ1NlcnZlciDguYTguKHguYjguJXguK3guJrguKrguJnguK3guIcnKTsKICAg
IGNvbnN0IHJlYWRlciA9IHJlc3AuYm9keS5nZXRSZWFkZXIoKTsKICAgIGNvbnN0IGRlY29kZXIg
PSBuZXcgVGV4dERlY29kZXIoJ3V0Zi04Jyk7CiAgICBsZXQgZG9uZSA9IGZhbHNlLCBidWYgPSAn
JzsKICAgIGxldCBwcm9nID0gNTsKICAgIC8vIOC5gOC4geC5h+C4miAidGFpbCIg4LiX4Li14LmI
4Lii4Lix4LiH4LmE4Lih4LmI4Lih4Li1IG5ld2xpbmUg4oCUIOC5g+C4iuC5iSBkZXRlY3QgcHJv
bXB0CiAgICBsZXQgdGFpbFNpbmNlTmV3bGluZSA9ICcnOwogICAgLy8gaGVscGVyOiBhcHBlbmQg
cmF3IHRleHQg4LmE4Lib4Lii4Lix4LiHIGxvZyAo4Lie4Lij4LmJ4Lit4LihIGNvbG9yKQogICAg
Y29uc3QgYXBwZW5kTG9nID0gKHR4dCkgPT4gewogICAgICBpZiAodHh0LmluY2x1ZGVzKCdbT0td
JykgfHwgdHh0LmluY2x1ZGVzKCfinIUnKSB8fCB0eHQuaW5jbHVkZXMoJ+C4quC4s+C5gOC4o+C5
h+C4iCcpKSB7CiAgICAgICAgbG9nLmlubmVySFRNTCArPSAnPHNwYW4gc3R5bGU9ImNvbG9yOiM0
YWRlODAiPicgKyBlc2NIdG1sKHR4dCkgKyAnPC9zcGFuPic7CiAgICAgIH0gZWxzZSBpZiAodHh0
LmluY2x1ZGVzKCdbRVJSXScpIHx8IHR4dC5pbmNsdWRlcygnRVJSJykgfHwgdHh0LmluY2x1ZGVz
KCfguKXguYnguKHguYDguKvguKXguKcnKSkgewogICAgICAgIGxvZy5pbm5lckhUTUwgKz0gJzxz
cGFuIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nICsgZXNjSHRtbCh0eHQpICsgJzwvc3Bhbj4nOwog
ICAgICB9IGVsc2UgaWYgKHR4dC5pbmNsdWRlcygnW0lORk9dJykgfHwgdHh0LmluY2x1ZGVzKCdb
V0FSTl0nKSkgewogICAgICAgIGxvZy5pbm5lckhUTUwgKz0gJzxzcGFuIHN0eWxlPSJjb2xvcjoj
ZmJiZjI0Ij4nICsgZXNjSHRtbCh0eHQpICsgJzwvc3Bhbj4nOwogICAgICB9IGVsc2UgewogICAg
ICAgIGxvZy5pbm5lckhUTUwgKz0gZXNjSHRtbCh0eHQpOwogICAgICB9CiAgICAgIGxvZy5zY3Jv
bGxUb3AgPSBsb2cuc2Nyb2xsSGVpZ2h0OwogICAgfTsKICAgIC8vIOC4q+C4peC4seC4hyBzdHJl
YW0g4LmA4LiH4Li14Lii4LiaIDUwMG1zIOC5geC4peC4sOC4oeC4tSB0YWlsIOC4hOC5ieC4suC4
h+C4reC4ouC4ueC5iCDihpIg4LiW4Li34Lit4Lin4LmI4Liy4LmA4Lib4LmH4LiZIHByb21wdAog
ICAgY29uc3Qgc2NoZWR1bGVQcm9tcHRDaGVjayA9ICgpID0+IHsKICAgICAgaWYgKF9wcm9tcHRU
aW1lcikgY2xlYXJUaW1lb3V0KF9wcm9tcHRUaW1lcik7CiAgICAgIF9wcm9tcHRUaW1lciA9IHNl
dFRpbWVvdXQoKCkgPT4gewogICAgICAgIGNvbnN0IHAgPSBsb29rc0xpa2VQcm9tcHQodGFpbFNp
bmNlTmV3bGluZSk7CiAgICAgICAgaWYgKHAgJiYgX3VwZGF0ZUFjdGl2ZSAmJiBfdXBkYXRlU2lk
KSBzaG93VXBkYXRlSW5wdXQocCk7CiAgICAgIH0sIDUwMCk7CiAgICB9OwogICAgd2hpbGUgKCFk
b25lKSB7CiAgICAgIGNvbnN0IHsgdmFsdWUsIGRvbmU6IGQgfSA9IGF3YWl0IHJlYWRlci5yZWFk
KCk7CiAgICAgIGRvbmUgPSBkOwogICAgICBpZiAodmFsdWUpIHsKICAgICAgICBjb25zdCBjaHVu
ayA9IGRlY29kZXIuZGVjb2RlKHZhbHVlLCB7IHN0cmVhbTogdHJ1ZSB9KTsKICAgICAgICBidWYg
Kz0gY2h1bms7CiAgICAgICAgLy8g4Lit4Lix4Lie4LmA4LiU4LiVIHRhaWwgdHJhY2tpbmcKICAg
ICAgICBmb3IgKGNvbnN0IGNoIG9mIGNodW5rKSB7CiAgICAgICAgICBpZiAoY2ggPT09ICdcbicp
IHRhaWxTaW5jZU5ld2xpbmUgPSAnJzsKICAgICAgICAgIGVsc2UgdGFpbFNpbmNlTmV3bGluZSAr
PSBjaDsKICAgICAgICB9CiAgICAgICAgLy8g4LmB4Lii4LiBIHNlc3Npb24gaWQg4Lia4Lij4Lij
4LiX4Lix4LiU4LmB4Lij4LiBICjguJbguYnguLLguKHguLUpCiAgICAgICAgaWYgKCFfdXBkYXRl
U2lkKSB7CiAgICAgICAgICBjb25zdCBzaWRNYXRjaCA9IGJ1Zi5tYXRjaCgvXl9fU0lEX186KFth
LWYwLTldKylcbi8pOwogICAgICAgICAgaWYgKHNpZE1hdGNoKSB7CiAgICAgICAgICAgIF91cGRh
dGVTaWQgPSBzaWRNYXRjaFsxXTsKICAgICAgICAgICAgYnVmID0gYnVmLnNsaWNlKHNpZE1hdGNo
WzBdLmxlbmd0aCk7CiAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGNvbnN0IGxpbmVzID0g
YnVmLnNwbGl0KCdcbicpOwogICAgICAgIGJ1ZiA9IGxpbmVzLnBvcCgpOwogICAgICAgIGxldCBz
dG9wTG9vcCA9IGZhbHNlOwogICAgICAgIGZvciAoY29uc3QgbGluZSBvZiBsaW5lcykgewogICAg
ICAgICAgbGluZUNvdW50Kys7CiAgICAgICAgICBjb25zdCB0eHQgPSBsaW5lICsgJ1xuJzsKICAg
ICAgICAgIC8vIOC4i+C5iOC4reC4mSBpbnB1dCBib3gg4LmA4Lih4Li34LmI4Lit4Lih4Li14Lia
4Lij4Lij4LiX4Lix4LiU4LmD4Lir4Lih4LmIICh1c2VyIOC4leC4reC4muC5geC4peC5ieC4pyDg
uKvguKPguLfguK3guKHguLUgb3V0cHV0IOC4leC5iOC4rSkKICAgICAgICAgIGhpZGVVcGRhdGVJ
bnB1dCgpOwogICAgICAgICAgYXBwZW5kTG9nKHR4dCk7CiAgICAgICAgICBwcm9nID0gTWF0aC5t
aW4oOTUsIHByb2cgKyAwLjMpOwogICAgICAgICAgcGJhci5zdHlsZS53aWR0aCA9IHByb2cgKyAn
JSc7CiAgICAgICAgICBpZiAodHh0LmluY2x1ZGVzKCdfX0RPTkVfT0tfXycpKSB7CiAgICAgICAg
ICAgIHBiYXIuc3R5bGUud2lkdGggPSAnMTAwJSc7IHBiYXIuc3R5bGUuYmFja2dyb3VuZCA9ICds
aW5lYXItZ3JhZGllbnQoOTBkZWcsIzIyYzU1ZSwjNGFkZTgwKSc7CiAgICAgICAgICAgIHBsYmwu
dGV4dENvbnRlbnQgPSAn4pyFIOC4reC4seC4nuC5gOC4lOC4leC4quC4s+C5gOC4o+C5h+C4iCEn
OyBwbGJsLnN0eWxlLmNvbG9yID0gJyMyMmM1NWUnOwogICAgICAgICAgICBzdC5pbm5lckhUTUwg
PSAnPGRpdiBjbGFzcz0iYWxlcnQgb2siIHN0eWxlPSJkaXNwbGF5OmJsb2NrIj7inIUg4Lit4Lix
4Lie4LmA4LiU4LiV4LmA4Liq4Lij4LmH4LiI4Liq4Li04LmJ4LiZIOKAlCDguIHguKPguLjguJPg
uLIgUmVmcmVzaCDguKvguJnguYnguLI8L2Rpdj4nOwogICAgICAgICAgICBzdG9wTG9vcCA9IHRy
dWU7IGJyZWFrOwogICAgICAgICAgfQogICAgICAgICAgaWYgKHR4dC5pbmNsdWRlcygnX19ET05F
X0xBVEVTVF9fJykpIHsKICAgICAgICAgICAgcGJhci5zdHlsZS53aWR0aCA9ICcxMDAlJzsgcGJh
ci5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjM2I4MmY2LCM2MGE1
ZmEpJzsKICAgICAgICAgICAgcGxibC50ZXh0Q29udGVudCA9ICfinIUg4LmA4Lin4Lit4Lij4LmM
4LiK4Lix4LmI4LiZ4Lil4LmI4Liy4Liq4Li44LiU4LmB4Lil4LmJ4LinJzsgcGxibC5zdHlsZS5j
b2xvciA9ICcjM2I4MmY2JzsKICAgICAgICAgICAgc3QuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9
ImFsZXJ0IG9rIiBzdHlsZT0iZGlzcGxheTpibG9jaztiYWNrZ3JvdW5kOiNlZmY2ZmY7Ym9yZGVy
LWNvbG9yOiM5M2M1ZmQ7Y29sb3I6IzFkNGVkOCI+4pyFIFNjcmlwdCDguYDguJvguYfguJnguYDg
uKfguK3guKPguYzguIrguLHguYjguJnguKXguYjguLLguKrguLjguJTguYHguKXguYnguKcg4LmE
4Lih4LmI4LiI4Liz4LmA4Lib4LmH4LiZ4LiV4LmJ4Lit4LiH4Lit4Lix4Lie4LmA4LiU4LiVPC9k
aXY+JzsKICAgICAgICAgICAgc3RvcExvb3AgPSB0cnVlOyBicmVhazsKICAgICAgICAgIH0KICAg
ICAgICAgIGlmICh0eHQuaW5jbHVkZXMoJ19fRE9ORV9GQUlMX18nKSkgewogICAgICAgICAgICBw
YmFyLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNlZjQ0NDQsI2Rj
MjYyNiknOwogICAgICAgICAgICBwbGJsLnRleHRDb250ZW50ID0gJ+KdjCDguK3guLHguJ7guYDg
uJTguJXguKXguYnguKHguYDguKvguKXguKcnOyBwbGJsLnN0eWxlLmNvbG9yID0gJyNlZjQ0NDQn
OwogICAgICAgICAgICBzdC5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0iYWxlcnQgZXJyIiBzdHls
ZT0iZGlzcGxheTpibG9jayI+4p2MIOC4reC4seC4nuC5gOC4lOC4leC4peC5ieC4oeC5gOC4q+C4
peC4pyDguJTguLkgTG9nIOC4lOC5ieC4suC4meC4muC4mTwvZGl2Pic7CiAgICAgICAgICAgIHN0
b3BMb29wID0gdHJ1ZTsgYnJlYWs7CiAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGlmIChz
dG9wTG9vcCkgYnJlYWs7CiAgICAgICAgLy8g4LmB4Liq4LiU4LiHIHRhaWwg4LiX4Li14LmI4Lii
4Lix4LiH4LmE4Lih4LmI4Lih4Li1IG5ld2xpbmUg4Lil4LiH4LmD4LiZIGxvZyAocHJvbXB0IHRl
eHQpICsg4LiV4Lix4LmJ4LiHIHByb21wdCBjaGVjawogICAgICAgIGlmIChidWYpIHsKICAgICAg
ICAgIC8vIOC5geC4quC4lOC4hyBwYXJ0aWFsIGxpbmU6IGFwcGVuZCDguJXguYjguK3guJfguYng
uLLguKLguYHguJXguYjguIjguLDguJbguLnguIEgb3ZlcndyaXRlIOC5gOC4oeC4t+C5iOC4reC4
oeC4tSBuZXdsaW5lIOC4iOC4o+C4tOC4hwogICAgICAgICAgLy8g4LmD4LiK4LmJIGFwcHJvYWNo
OiBhcHBlbmQg4LmA4LiJ4Lie4Liy4Liw4Liq4LmI4Lin4LiZ4LiX4Li14LmI4Lii4Lix4LiH4LmE
4Lih4LmI4LmE4LiU4LmJ4LmB4Liq4LiU4LiHCiAgICAgICAgICBjb25zdCBzaG93biA9IGxvZy5k
YXRhc2V0LnBhcnRpYWwgfHwgJyc7CiAgICAgICAgICBpZiAoYnVmICE9PSBzaG93bikgewogICAg
ICAgICAgICAvLyDguKXguJogcGFydGlhbCDguYDguIHguYjguLIg4LmB4Lil4LmJ4Lin4LmD4Liq
4LmI4LmD4Lir4Lih4LmICiAgICAgICAgICAgIGlmIChzaG93biAmJiBsb2cuaW5uZXJIVE1MLmVu
ZHNXaXRoKCc8c3BhbiBjbGFzcz0idXBkLXBhcnRpYWwiPicgKyBlc2NIdG1sKHNob3duKSArICc8
L3NwYW4+JykpIHsKICAgICAgICAgICAgICBsb2cuaW5uZXJIVE1MID0gbG9nLmlubmVySFRNTC5z
bGljZSgwLCBsb2cuaW5uZXJIVE1MLmxlbmd0aCAtICgnPHNwYW4gY2xhc3M9InVwZC1wYXJ0aWFs
Ij4nICsgZXNjSHRtbChzaG93bikgKyAnPC9zcGFuPicpLmxlbmd0aCk7CiAgICAgICAgICAgIH0K
ICAgICAgICAgICAgbG9nLmlubmVySFRNTCArPSAnPHNwYW4gY2xhc3M9InVwZC1wYXJ0aWFsIiBz
dHlsZT0iY29sb3I6I2ZiYmYyNCI+JyArIGVzY0h0bWwoYnVmKSArICc8L3NwYW4+JzsKICAgICAg
ICAgICAgbG9nLmRhdGFzZXQucGFydGlhbCA9IGJ1ZjsKICAgICAgICAgICAgbG9nLnNjcm9sbFRv
cCA9IGxvZy5zY3JvbGxIZWlnaHQ7CiAgICAgICAgICB9CiAgICAgICAgICBzY2hlZHVsZVByb21w
dENoZWNrKCk7CiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgIGxvZy5kYXRhc2V0LnBhcnRpYWwg
PSAnJzsKICAgICAgICB9CiAgICAgIH0KICAgIH0KICB9IGNhdGNoKGUpIHsKICAgIGxvZy5pbm5l
ckhUTUwgKz0gJzxzcGFuIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij5bRVJSXSAnICsgZXNjSHRtbChl
Lm1lc3NhZ2UpICsgJ1xuPC9zcGFuPic7CiAgICBwbGJsLnRleHRDb250ZW50ID0gJ+KdjCDguYDg
uIHguLTguJTguILguYnguK3guJzguLTguJTguJ7guKXguLLguJQnOyBwbGJsLnN0eWxlLmNvbG9y
ID0gJyNlZjQ0NDQnOwogICAgc3QuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImFsZXJ0IGVyciIg
c3R5bGU9ImRpc3BsYXk6YmxvY2siPuKdjCAnICsgZXNjSHRtbChlLm1lc3NhZ2UpICsgJzwvZGl2
Pic7CiAgfSBmaW5hbGx5IHsKICAgIF91cGRhdGVBY3RpdmUgPSBmYWxzZTsKICAgIF91cGRhdGVT
aWQgPSBudWxsOwogICAgaGlkZVVwZGF0ZUlucHV0KCk7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxz
ZTsKICAgIGJ0bi5pbm5lckhUTUwgPSAn4qyG77iPIOC5gOC4o+C4tOC5iOC4oSBVcGRhdGUnOwog
IH0KfQpmdW5jdGlvbiBzdHJpcEFuc2kocykgewogIHJldHVybiBzLnJlcGxhY2UoL1x4MWJcW1sw
LTk7XSpbbUdLSEZdL2csICcnKS5yZXBsYWNlKC9cW1xkKzs/XGQqbS9nLCAnJyk7Cn0KZnVuY3Rp
b24gZXNjSHRtbChzKSB7CiAgcmV0dXJuIHN0cmlwQW5zaShzKS5yZXBsYWNlKC8mL2csJyZhbXA7
JykucmVwbGFjZSgvPC9nLCcmbHQ7JykucmVwbGFjZSgvPi9nLCcmZ3Q7Jyk7Cn0KCi8vIOKVkOKV
kOKVkOKVkCBJTklUIOKVkOKVkOKVkOKVkApsb2FkRGFzaCgpOwpsb2FkU2VydmljZXMoKTsKCi8v
IFJlYWx0aW1lIHBvbGxpbmcg4oCUIHNlcnZpY2VzIOC4l+C4uOC4gSA4IOC4p+C4tCAoQVBJIOC5
gOC4muC4siksIGRhc2hib2FyZCDguJfguLjguIEgMTUg4Lin4Li0CnNldEludGVydmFsKGFzeW5j
IGZ1bmN0aW9uKCkgewogIHRyeSB7CiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0
YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChzdCkgcmVu
ZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogIH0gY2F0Y2goZSkge30KfSwgODAwMCk7
CgpzZXRJbnRlcnZhbChsb2FkRGFzaCwgMTUwMDApOwo8L3NjcmlwdD4KPC9ib2R5Pgo8L2h0bWw+
Cg==
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
echo -e "  🖥  3x-ui Panel : ${CYAN}${BOLD}https://${DOMAIN}:2053/${NC}"
echo -e "  🐻 Dropbear    : ${CYAN}port 143, 109${NC}"
echo -e "  🌐 WS-Tunnel   : ${CYAN}port 80 → Dropbear:143${NC}"
echo -e "  🎮 BadVPN UDPGW: ${CYAN}port 7300${NC}"
echo -e "  📡 VMess-WS    : ${CYAN}port 8080, path /vmess${NC}"
echo -e "  📡 VLESS-WS    : ${CYAN}port 8880, path /vless${NC}"
echo ""
echo -e "  💡 พิมพ์ ${CYAN}menu${NC} เพื่อดูรายละเอียด"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
