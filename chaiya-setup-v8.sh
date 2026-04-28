#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL v8 + PATCH (Combined)
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-setup-v8.sh
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
       VPN PANEL v8 - ALL-IN-ONE INSTALLER
BANNER

[[ $EUID -ne 0 ]] && err "รันด้วย root หรือ sudo เท่านั้น"

# ── PORT MAP ────────────────────────────────────────────────
# 22    OpenSSH (admin)
# 80    ws-stunnel HTTP-CONNECT → Dropbear:143
# 109   Dropbear SSH port 2
# 143   Dropbear SSH port 1
# 443   nginx HTTPS panel (ถ้ามี SSL cert)
# 2503  nginx SSL proxy → 3x-ui panel (user เข้า URL นี้)
# 54321 3x-ui internal (ไม่ expose ออกนอก)
# 7300  badvpn-udpgw (127.0.0.1 เท่านั้น)
# 8080  xui VMess-WS inbound
# 8880  xui VLESS-WS inbound
# 6789  chaiya-sshws-api (127.0.0.1 เท่านั้น)

SSH_API_PORT=6789
XUI_PORT=54321       # x-ui internal port (default x-ui)
XUI_NGINX_PORT=2503  # port ที่ nginx proxy ออกให้ user เปิด browser
DROPBEAR_PORT1=143
DROPBEAR_PORT2=109
BADVPN_PORT=7300
WS_TUNNEL_PORT=80

# ── INSTALL DEPS ─────────────────────────────────────────────
info "อัปเดต packages..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl wget python3 python3-pip \
  dropbear openssh-server ufw \
  net-tools jq bc cron unzip sqlite3 iptables-persistent snapd 2>/dev/null || true

# ติดตั้ง certbot (ลอง apt ก่อน fallback snap)
if ! command -v certbot &>/dev/null; then
  apt-get install -y certbot python3-certbot 2>/dev/null || \
  apt-get install -y certbot 2>/dev/null || true
fi
if ! command -v certbot &>/dev/null; then
  snap install --classic certbot 2>/dev/null && \
    ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
fi
# ติดตั้ง bcrypt สำหรับ hash password x-ui
pip3 install bcrypt --break-system-packages -q 2>/dev/null || \
  pip3 install bcrypt -q 2>/dev/null || true
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
rm -f /etc/nginx/conf.d/chaiya.conf
rm -f /etc/nginx/conf.d/default.conf

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
for _port in 80 443 6789 7300; do
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

# ติดตั้ง dropbear (force ไม่ใช้ || true)
apt-get install -y dropbear 2>/dev/null || apt-get install -y dropbear-bin 2>/dev/null || true

# หา binary (อาจอยู่ที่ /usr/sbin หรือ /usr/bin)
_DB_BIN=""
for _p in /usr/sbin/dropbear /usr/bin/dropbear; do
  [[ -x "$_p" ]] && _DB_BIN="$_p" && break
done

if [[ -z "$_DB_BIN" ]]; then
  warn "ไม่พบ dropbear binary — ข้ามขั้นตอนนี้"
else
  systemctl stop dropbear 2>/dev/null || true
  mkdir -p /etc/dropbear
  [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]     && dropbearkey -t rsa     -f /etc/dropbear/dropbear_rsa_host_key     2>/dev/null || true
  [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]   && dropbearkey -t ecdsa   -f /etc/dropbear/dropbear_ecdsa_host_key   2>/dev/null || true
  [[ ! -f /etc/dropbear/dropbear_ed25519_host_key ]] && dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true

  grep -q '/bin/false'       /etc/shells 2>/dev/null || echo '/bin/false'       >> /etc/shells
  grep -q '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

  # สร้าง systemd unit หลักเสมอ (override ทับของเก่าถ้ามี / บาง distro ไม่มีมาให้)
  cat > /etc/systemd/system/dropbear.service << DBSVC
[Unit]
Description=Dropbear SSH Server
After=network.target

[Service]
Type=simple
ExecStart=$_DB_BIN -F -p ${DROPBEAR_PORT1} -p ${DROPBEAR_PORT2}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
DBSVC

  # ลบ override.conf เก่าที่อาจค้างอยู่ (เพราะ unit หลักครบแล้ว)
  rm -f /etc/systemd/system/dropbear.service.d/override.conf

  systemctl daemon-reload
  systemctl enable dropbear
  systemctl stop dropbear 2>/dev/null || true
  sleep 1
  systemctl start dropbear
  # รอ Dropbear พร้อมสูงสุด 15 วินาที
  _db_ok=0
  for _i in $(seq 1 5); do
    sleep 3
    if systemctl is-active --quiet dropbear; then
      _db_ok=1; break
    fi
    warn "Dropbear ยังไม่พร้อม ลองใหม่ครั้งที่ $_i..."
    systemctl restart dropbear 2>/dev/null || true
  done
  if [[ $_db_ok -eq 1 ]]; then
    ok "Dropbear พร้อม (port $DROPBEAR_PORT1, $DROPBEAR_PORT2)"
  else
    warn "Dropbear ไม่สามารถเริ่มได้ — ตรวจสอบ: journalctl -u dropbear -n 30"
    journalctl -u dropbear -n 10 --no-pager 2>/dev/null || true
  fi
fi

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
  printf "y\n${XUI_PORT}\n\n\n\n" | bash "$_xui_sh" >> /var/log/chaiya-xui-install.log 2>&1
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
  # ล้าง basePath ให้ใช้ root "/" เสมอ ไม่งั้น proxy /xui-api/ จะ 404
  sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='webBasePath';" 2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webBasePath','');" 2>/dev/null || true
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
        (8080, 'AIS – กันรั่ว',  'cj-ebb.speedtest.net',           'vless',  'inbound-8080', '/vless'),
        (8880, 'TRUE – VDO', 'true-internet.zoom.xyz.services', 'vless',  'inbound-8880', '/vless'),
    ]

    for port, remark, host, proto, tag, ws_path in inbounds:
        if port in existing:
            print(f'[OK] {remark} มีอยู่แล้ว')
            continue
        uid = str(uuid.uuid4())
        if proto == 'vmess':
            settings = json.dumps({'clients': [{'id': uid, 'alterId': 0, 'email': f'default@{tag}', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}]})
        else:
            settings = json.dumps({'clients': [{'id': uid, 'flow': '', 'email': f'default@{tag}', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}], 'decryption': 'none'})
        stream   = json.dumps({'network': 'ws', 'security': 'none', 'wsSettings': {'path': ws_path, 'headers': {'Host': host}}})
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
"""Chaiya SSH API v8"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, threading, sqlite3

XUI_DB = '/etc/x-ui/x-ui.db'

def find_xui_db():
    """ค้นหา x-ui.db จากหลาย path ที่เป็นไปได้"""
    candidates = [
        '/etc/x-ui/x-ui.db',
        '/root/.local/share/3x-ui/db/x-ui.db',
        '/usr/local/x-ui/x-ui.db',
        '/opt/x-ui/x-ui.db',
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    # ลอง find ถ้าไม่เจอ
    try:
        import subprocess as _sp
        r = _sp.run('find / -name "x-ui.db" -not -path "*/proc/*" 2>/dev/null | head -1',
                    shell=True, capture_output=True, text=True, timeout=5)
        p = r.stdout.strip()
        if p and os.path.exists(p):
            return p
    except: pass
    return '/etc/x-ui/x-ui.db'

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

    def do_HEAD(self):
        self.do_GET()

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
            xui_port = open('/etc/chaiya/xui-port.conf').read().strip() if os.path.exists('/etc/chaiya/xui-port.conf') else '2503'
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
            # ใช้ stdin แทนการ embed password ใน shell — ป้องกัน injection
            subprocess.run('chpasswd', input=f'{user}:{passwd}\n', capture_output=True, text=True)
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

# หยุด WS-Stunnel ชั่วคราวเพื่อ free port 80 ให้ certbot standalone
# (Let's Encrypt ต้องการ port 80 จริงๆ — http-01-port อื่นไม่ work)
info "หยุด WS-Stunnel ชั่วคราว (ปลดล็อก port 80)..."
systemctl stop chaiya-sshws 2>/dev/null || true
pkill -f ws-stunnel 2>/dev/null || true
# รอให้ port 80 ว่างจริงๆ
for _w in 1 2 3 4 5; do
  lsof -ti tcp:80 &>/dev/null || break
  sleep 1
done

if command -v certbot &>/dev/null; then
  for _try in 1 2 3; do
    info "certbot attempt ${_try}/3..."
    certbot certonly --standalone --non-interactive --agree-tos \
      --register-unsafely-without-email \
      -d "$DOMAIN" 2>&1 | tail -5
    [[ -f "$SSL_CERT" ]] && { USE_SSL=1; break; }
    sleep 5
  done
fi

# เปิด WS-Stunnel กลับไม่ว่า SSL จะสำเร็จหรือไม่
info "เปิด WS-Stunnel กลับ..."
systemctl start chaiya-sshws 2>/dev/null || true

[[ $USE_SSL -eq 1 ]] && ok "SSL Certificate พร้อม" || warn "ไม่มี SSL — ใช้ HTTP แทน"

# ── NGINX INSTALL + CONFIG ────────────────────────────────────
info "ติดตั้ง Nginx ใหม่..."
systemctl stop nginx 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
apt-get purge -y nginx nginx-common nginx-full nginx-core nginx-extras 2>/dev/null || true
rm -rf /etc/nginx /var/log/nginx /var/lib/nginx

# ใช้ official nginx repo เพื่อให้ได้ nginx 1.24+ (รองรับทุก directive)
if ! grep -q "nginx.org" /etc/apt/sources.list.d/nginx.list 2>/dev/null; then
  apt-get install -y -qq gnupg2
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null || true
  _codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu ${_codename} nginx" \
    > /etc/apt/sources.list.d/nginx.list 2>/dev/null || true
  apt-get update -qq 2>/dev/null || true
fi
apt-get install -y nginx
ok "ติดตั้ง Nginx ใหม่สำเร็จ ($(nginx -v 2>&1 | grep -oP '[\d.]+'))"
# ลบ default.conf ที่ nginx install สร้างขึ้นมาใหม่
rm -f /etc/nginx/conf.d/default.conf

info "ตั้งค่า Nginx..."
# nginx.org package ใช้ conf.d/ ไม่ใช่ sites-enabled/
rm -f /etc/nginx/conf.d/default.conf
rm -f /etc/nginx/conf.d/chaiya.conf
mkdir -p /etc/nginx/conf.d

# เปิด port 443/2503
ufw allow 443/tcp  &>/dev/null || true
ufw allow 2503/tcp &>/dev/null || true

if [[ $USE_SSL -eq 1 ]]; then
cat > /etc/nginx/conf.d/chaiya.conf << EOF
# ── Dashboard (port 443 HTTPS) ──────────────────────────────────
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 60s;
        proxy_cookie_path / /;
        add_header Access-Control-Allow-Origin "\$http_origin" always;
        add_header Access-Control-Allow-Credentials "true" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type,Authorization,Cookie" always;
    }
}

# ── 3x-ui Panel proxy (port 2503 HTTPS) ───────────────────────
server {
    listen 2503 ssl http2;
    listen [::]:2503 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;
    location / {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 120s;
        proxy_cookie_path / /;
    }
}
EOF
else
cat > /etc/nginx/conf.d/chaiya.conf << EOF
# ── Dashboard (port 443 HTTP) ───────────────────────────────────
server {
    listen 443;
    listen [::]:443;
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
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto "http";
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 60s;
        proxy_cookie_path / /;
        add_header Access-Control-Allow-Origin "\$http_origin" always;
        add_header Access-Control-Allow-Credentials "true" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type,Authorization,Cookie" always;
    }
}

# ── 3x-ui Panel proxy (port 2503 HTTP) ────────────────────────
server {
    listen 2503;
    listen [::]:2503;
    server_name ${DOMAIN} _;
    location / {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 120s;
        proxy_cookie_path / /;
    }
}
EOF
fi

nginx -t && systemctl restart nginx && ok "Nginx พร้อม (Dashboard:443 / 3x-ui proxy:2503)" || warn "Nginx มีปัญหา — ตรวจ: nginx -t"
# start ws-stunnel คืนหลัง nginx config เสร็จ
systemctl start chaiya-sshws 2>/dev/null || true

# ── FIREWALL ─────────────────────────────────────────────────
info "ตั้งค่า Firewall..."
ufw --force reset &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
for port in 22 80 109 143 443 2503 8080 8880; do
  ufw allow "$port"/tcp &>/dev/null
done
# 6789 (SSH API), 54321 (x-ui internal), 7300/tcp — ปิดจากภายนอก
ufw deny 6789/tcp  &>/dev/null
ufw deny 7300/tcp  &>/dev/null
ufw deny 54321/tcp &>/dev/null
ufw deny 8888/tcp  &>/dev/null
# 7300/udp เปิดสำหรับ badvpn-udpgw (bind 127.0.0.1 แต่ต้องให้ client tunnel ผ่าน SSH มาได้)
ufw allow 7300/udp &>/dev/null
ufw --force enable &>/dev/null
ok "Firewall พร้อม"

# ── CONFIG.JS ────────────────────────────────────────────────
_PANEL_URL="https://${DOMAIN}"
[[ $USE_SSL -eq 0 ]] && _PANEL_URL="http://${DOMAIN}:443"
cat > /opt/chaiya-panel/config.js << EOF
// Auto-generated by chaiya-setup-v8.sh
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
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFBST0pFQ1Qg4oCTIExvZ2luPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1PcmJpdHJvbjp3Z2h0QDQwMDs3MDA7OTAwJmZhbWlseT1TYXJhYnVuOndnaHRAMzAwOzQwMDs2MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c3R5bGU+CiAgOnJvb3QgewogICAgLS1wdXJwbGU6ICM3YzNhZWQ7CiAgICAtLXB1cnBsZS1saWdodDogI2E4NTVmNzsKICAgIC0tYmx1ZTogIzI1NjNlYjsKICAgIC0tYmx1ZS1saWdodDogIzYwYTVmYTsKICAgIC0tY3lhbjogIzA2YjZkNDsKICAgIC0tZGFyazogIzAzMDUwZjsKICAgIC0tZGFyazI6ICMwODBkMWY7CiAgICAtLWNhcmQtYmc6IHJnYmEoMTAsMTUsNDAsMC44NSk7CiAgICAtLWJvcmRlcjogcmdiYSgxMjQsNTgsMjM3LDAuNCk7CiAgICAtLWdsb3ctcHVycGxlOiByZ2JhKDEyNCw1OCwyMzcsMC42KTsKICAgIC0tZ2xvdy1ibHVlOiByZ2JhKDM3LDk5LDIzNSwwLjUpOwogICAgLS10ZXh0OiAjZTJlOGYwOwogICAgLS1tdXRlZDogcmdiYSgxODAsMTkwLDIyMCwwLjUpOwogIH0KCiAgKiB7IG1hcmdpbjowOyBwYWRkaW5nOjA7IGJveC1zaXppbmc6Ym9yZGVyLWJveDsgfQoKICBib2R5IHsKICAgIG1pbi1oZWlnaHQ6IDEwMHZoOwogICAgYmFja2dyb3VuZDogdmFyKC0tZGFyayk7CiAgICBmb250LWZhbWlseTogJ1NhcmFidW4nLCBzYW5zLXNlcmlmOwogICAgY29sb3I6IHZhcigtLXRleHQpOwogICAgZGlzcGxheTogZmxleDsKICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgfQoKICAvKiDilIDilIAgQmFja2dyb3VuZCDilIDilIAgKi8KICAuYmcgewogICAgcG9zaXRpb246IGZpeGVkOwogICAgaW5zZXQ6IDA7CiAgICBiYWNrZ3JvdW5kOgogICAgICByYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUsIHJnYmEoMTI0LDU4LDIzNywwLjI1KSAwJSwgdHJhbnNwYXJlbnQgNjAlKSwKICAgICAgcmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLCByZ2JhKDM3LDk5LDIzNSwwLjIpIDAlLCB0cmFuc3BhcmVudCA2MCUpLAogICAgICByYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA0MCUgNDAlIGF0IDUwJSA1MCUsIHJnYmEoNiwxODIsMjEyLDAuMDgpIDAlLCB0cmFuc3BhcmVudCA3MCUpLAogICAgICBsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCAjMDMwNTBmIDAlLCAjMDgwZDFmIDUwJSwgIzA1MDgxMCAxMDAlKTsKICAgIHotaW5kZXg6IDA7CiAgfQoKICAvKiBncmlkIGxpbmVzICovCiAgLmJnOjpiZWZvcmUgewogICAgY29udGVudDogJyc7CiAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICBpbnNldDogMDsKICAgIGJhY2tncm91bmQtaW1hZ2U6CiAgICAgIGxpbmVhci1ncmFkaWVudChyZ2JhKDEyNCw1OCwyMzcsMC4wNikgMXB4LCB0cmFuc3BhcmVudCAxcHgpLAogICAgICBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHJnYmEoMTI0LDU4LDIzNywwLjA2KSAxcHgsIHRyYW5zcGFyZW50IDFweCk7CiAgICBiYWNrZ3JvdW5kLXNpemU6IDUwcHggNTBweDsKICAgIGFuaW1hdGlvbjogZ3JpZE1vdmUgMjBzIGxpbmVhciBpbmZpbml0ZTsKICB9CgogIEBrZXlmcmFtZXMgZ3JpZE1vdmUgewogICAgMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNTBweCk7IH0KICB9CgogIC8qIHBhcnRpY2xlcyAqLwogIC5wYXJ0aWNsZSB7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIGFuaW1hdGlvbjogZmxvYXQgbGluZWFyIGluZmluaXRlOwogICAgb3BhY2l0eTogMDsKICB9CgogIEBrZXlmcmFtZXMgZmxvYXQgewogICAgMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMTAwdmgpIHNjYWxlKDApOyBvcGFjaXR5OiAwOyB9CiAgICAxMCUgeyBvcGFjaXR5OiAxOyB9CiAgICA5MCUgeyBvcGFjaXR5OiAwLjY7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTEwMHB4KSBzY2FsZSgxKTsgb3BhY2l0eTogMDsgfQogIH0KCiAgLyog4pSA4pSAIExvZ28gYXJlYSDilIDilIAgKi8KICAubG9nby13cmFwIHsKICAgIHRleHQtYWxpZ246IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDI0cHg7CiAgICBhbmltYXRpb246IGZhZGVEb3duIDAuOHMgZWFzZSBib3RoOwogIH0KCiAgLyogU2lnbmFsIFB1bHNlIGxvZ28gYW5pbWF0aW9ucyAqLwogIEBrZXlmcmFtZXMgb3JiaXQtZGFzaCB7CiAgICBmcm9tIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IH0KICAgIHRvICAgeyBzdHJva2UtZGFzaG9mZnNldDogLTI1MTsgfQogIH0KICBAa2V5ZnJhbWVzIHB1bHNlLWRyYXcgewogICAgMCUgICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7IG9wYWNpdHk6IDA7IH0KICAgIDE1JSAgeyBvcGFjaXR5OiAxOyB9CiAgICAxMDAlIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBibGluay1kb3QgewogICAgMCUsIDEwMCUgeyBvcGFjaXR5OiAwLjI1OyB9CiAgICA1MCUgICAgICAgeyBvcGFjaXR5OiAxOyB9CiAgfQogIEBrZXlmcmFtZXMgbG9nby1nbG93IHsKICAgIDAlLCAxMDAlIHsgZmlsdGVyOiBkcm9wLXNoYWRvdygwIDAgNnB4ICM2MGE1ZmEpIGRyb3Atc2hhZG93KDAgMCAxNHB4ICMyNTYzZWIpOyB9CiAgICA1MCUgICAgICAgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCAxNHB4ICM2MGE1ZmEpIGRyb3Atc2hhZG93KDAgMCAyOHB4ICMyNTYzZWIpIGRyb3Atc2hhZG93KDAgMCA0MnB4ICMwNmI2ZDQpOyB9CiAgfQoKICAubG9nby1zdmctd3JhcCB7CiAgICBkaXNwbGF5OiBmbGV4OwogICAganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICBtYXJnaW4tYm90dG9tOiAxMHB4OwogICAgYW5pbWF0aW9uOiBsb2dvLWdsb3cgM3MgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgfQoKICAub3JiaXQtcmluZy1hbmltIHsKICAgIHRyYW5zZm9ybS1vcmlnaW46IDUwcHggNTBweDsKICAgIGFuaW1hdGlvbjogb3JiaXQtZGFzaCA4cyBsaW5lYXIgaW5maW5pdGU7CiAgfQoKICAud2F2ZS1hbmltIHsKICAgIHN0cm9rZS1kYXNoYXJyYXk6IDIyMDsKICAgIHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7CiAgICBhbmltYXRpb246IHB1bHNlLWRyYXcgMS42cyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKSAwLjVzIGZvcndhcmRzOwogIH0KCiAgLmRvdC1hbmltLTEgeyBhbmltYXRpb246IGJsaW5rLWRvdCAyLjJzIGVhc2UtaW4tb3V0IDEuOHMgaW5maW5pdGU7IH0KICAuZG90LWFuaW0tMiB7IGFuaW1hdGlvbjogYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMi4ycyBpbmZpbml0ZTsgfQoKICAvKiDilIDilIAgQ2FyZCDilIDilIAgKi8KICAuY2FyZCB7CiAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICB6LWluZGV4OiAxMDsKICAgIHdpZHRoOiAxMDAlOwogICAgbWF4LXdpZHRoOiA0MDBweDsKICAgIHBhZGRpbmc6IDMycHggMjhweDsKICAgIGJhY2tncm91bmQ6IHZhcigtLWNhcmQtYmcpOwogICAgYmFja2Ryb3AtZmlsdGVyOiBibHVyKDIwcHgpOwogICAgYm9yZGVyLXJhZGl1czogMjBweDsKICAgIGJvcmRlcjogMXB4IHNvbGlkIHZhcigtLWJvcmRlcik7CiAgICBib3gtc2hhZG93OgogICAgICAwIDAgMCAxcHggcmdiYSgxMjQsNTgsMjM3LDAuMSksCiAgICAgIDAgMjBweCA2MHB4IHJnYmEoMCwwLDAsMC42KSwKICAgICAgaW5zZXQgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDUpOwogICAgYW5pbWF0aW9uOiBmYWRlVXAgMC44cyBlYXNlIGJvdGggMC4yczsKICAgIG1hcmdpbjogMjBweDsKICB9CgogIC8qIGNvcm5lciBkZWNvcmF0aW9ucyAqLwogIC5jYXJkOjpiZWZvcmUsIC5jYXJkOjphZnRlciB7CiAgICBjb250ZW50OiAnJzsKICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgIHdpZHRoOiAyMHB4OwogICAgaGVpZ2h0OiAyMHB4OwogICAgYm9yZGVyLWNvbG9yOiB2YXIoLS1wdXJwbGUtbGlnaHQpOwogICAgYm9yZGVyLXN0eWxlOiBzb2xpZDsKICB9CiAgLmNhcmQ6OmJlZm9yZSB7IHRvcDogLTFweDsgbGVmdDogLTFweDsgYm9yZGVyLXdpZHRoOiAycHggMCAwIDJweDsgYm9yZGVyLXJhZGl1czogNHB4IDAgMCAwOyB9CiAgLmNhcmQ6OmFmdGVyIHsgYm90dG9tOiAtMXB4OyByaWdodDogLTFweDsgYm9yZGVyLXdpZHRoOiAwIDJweCAycHggMDsgYm9yZGVyLXJhZGl1czogMCAwIDRweCAwOyB9CgogIEBrZXlmcmFtZXMgZmFkZVVwIHsKICAgIGZyb20geyBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMzBweCk7IH0KICAgIHRvIHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgfQoKICBAa2V5ZnJhbWVzIGZhZGVEb3duIHsKICAgIGZyb20geyBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTIwcHgpOyB9CiAgICB0byB7IG9wYWNpdHk6IDE7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsgfQogIH0KCiAgLyog4pSA4pSAIFNlY3Rpb24gdGl0bGUg4pSA4pSAICovCiAgLnNlY3Rpb24tdGl0bGUgewogICAgZm9udC1zaXplOiAxMXB4OwogICAgbGV0dGVyLXNwYWNpbmc6IDNweDsKICAgIGNvbG9yOiB2YXIoLS1wdXJwbGUtbGlnaHQpOwogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsKICAgIG1hcmdpbi1ib3R0b206IDE2cHg7CiAgICBkaXNwbGF5OiBmbGV4OwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgIGdhcDogOHB4OwogIH0KCiAgLnNlY3Rpb24tdGl0bGU6OmJlZm9yZSB7CiAgICBjb250ZW50OiAnJzsKICAgIHdpZHRoOiA0cHg7CiAgICBoZWlnaHQ6IDE0cHg7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCB2YXIoLS1wdXJwbGUpLCB2YXIoLS1ibHVlKSk7CiAgICBib3JkZXItcmFkaXVzOiAycHg7CiAgICBkaXNwbGF5OiBpbmxpbmUtYmxvY2s7CiAgfQoKICAvKiDilIDilIAgSW5wdXQgZ3JvdXAg4pSA4pSAICovCiAgLmZpZWxkIHsKICAgIG1hcmdpbi1ib3R0b206IDE0cHg7CiAgfQoKICAuZmllbGQtbGFiZWwgewogICAgZm9udC1zaXplOiAxMXB4OwogICAgY29sb3I6IHZhcigtLW11dGVkKTsKICAgIG1hcmdpbi1ib3R0b206IDZweDsKICAgIGxldHRlci1zcGFjaW5nOiAxcHg7CiAgICBkaXNwbGF5OiBmbGV4OwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgIGdhcDogNnB4OwogIH0KCiAgLmlucHV0LXdyYXAgewogICAgcG9zaXRpb246IHJlbGF0aXZlOwogIH0KCiAgLmlucHV0LWljb24gewogICAgcG9zaXRpb246IGFic29sdXRlOwogICAgbGVmdDogMTRweDsKICAgIHRvcDogNTAlOwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC01MCUpOwogICAgY29sb3I6IHZhcigtLXB1cnBsZS1saWdodCk7CiAgICBmb250LXNpemU6IDE2cHg7CiAgICBvcGFjaXR5OiAwLjc7CiAgICB6LWluZGV4OiAxOwogIH0KCiAgLmZpIHsKICAgIHdpZHRoOiAxMDAlOwogICAgYmFja2dyb3VuZDogcmdiYSgxNSwyMCw1MCwwLjgpOwogICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMjQsNTgsMjM3LDAuMyk7CiAgICBib3JkZXItcmFkaXVzOiAxMHB4OwogICAgcGFkZGluZzogMTJweCAxNHB4IDEycHggNDJweDsKICAgIGNvbG9yOiB2YXIoLS10ZXh0KTsKICAgIGZvbnQtZmFtaWx5OiAnU2FyYWJ1bicsIHNhbnMtc2VyaWY7CiAgICBmb250LXNpemU6IDE0cHg7CiAgICBvdXRsaW5lOiBub25lOwogICAgdHJhbnNpdGlvbjogYWxsIDAuM3M7CiAgfQoKICAuZmk6Zm9jdXMgewogICAgYm9yZGVyLWNvbG9yOiB2YXIoLS1wdXJwbGUtbGlnaHQpOwogICAgYmFja2dyb3VuZDogcmdiYSgyMCwyNSw2MCwwLjkpOwogICAgYm94LXNoYWRvdzogMCAwIDAgM3B4IHJnYmEoMTI0LDU4LDIzNywwLjE1KSwgMCAwIDIwcHggcmdiYSgxMjQsNTgsMjM3LDAuMSk7CiAgfQoKICAuZmk6OnBsYWNlaG9sZGVyIHsgY29sb3I6IHJnYmEoMTgwLDE5MCwyMjAsMC4zKTsgfQoKICAuZXllLXRvZ2dsZSB7CiAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICByaWdodDogMTRweDsKICAgIHRvcDogNTAlOwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC01MCUpOwogICAgYmFja2dyb3VuZDogbm9uZTsKICAgIGJvcmRlcjogbm9uZTsKICAgIGNvbG9yOiB2YXIoLS1tdXRlZCk7CiAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICBmb250LXNpemU6IDE2cHg7CiAgICBwYWRkaW5nOiAwOwogICAgdHJhbnNpdGlvbjogY29sb3IgMC4yczsKICB9CgogIC5leWUtdG9nZ2xlOmhvdmVyIHsgY29sb3I6IHZhcigtLXB1cnBsZS1saWdodCk7IH0KCiAgLyog4pSA4pSAIEJ1dHRvbiDilIDilIAgKi8KICAuYnRuLW1haW4gewogICAgd2lkdGg6IDEwMCU7CiAgICBwYWRkaW5nOiAxNHB4OwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDEzNWRlZywgdmFyKC0tcHVycGxlKSwgdmFyKC0tYmx1ZSkpOwogICAgYm9yZGVyOiBub25lOwogICAgYm9yZGVyLXJhZGl1czogMTBweDsKICAgIGNvbG9yOiAjZmZmOwogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsKICAgIGZvbnQtc2l6ZTogMTNweDsKICAgIGZvbnQtd2VpZ2h0OiA3MDA7CiAgICBsZXR0ZXItc3BhY2luZzogMnB4OwogICAgY3Vyc29yOiBwb2ludGVyOwogICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgIHRyYW5zaXRpb246IGFsbCAwLjNzOwogICAgYm94LXNoYWRvdzogMCA0cHggMjBweCByZ2JhKDEyNCw1OCwyMzcsMC40KTsKICAgIG1hcmdpbi10b3A6IDRweDsKICB9CgogIC5idG4tbWFpbjo6YmVmb3JlIHsKICAgIGNvbnRlbnQ6ICcnOwogICAgcG9zaXRpb246IGFic29sdXRlOwogICAgaW5zZXQ6IDA7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpLCB0cmFuc3BhcmVudCk7CiAgICBvcGFjaXR5OiAwOwogICAgdHJhbnNpdGlvbjogb3BhY2l0eSAwLjNzOwogIH0KCiAgLmJ0bi1tYWluOmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsKICAgIGJveC1zaGFkb3c6IDAgOHB4IDMwcHggcmdiYSgxMjQsNTgsMjM3LDAuNiksIDAgMCA2MHB4IHJnYmEoMzcsOTksMjM1LDAuMyk7CiAgfQoKICAuYnRuLW1haW46aG92ZXI6OmJlZm9yZSB7IG9wYWNpdHk6IDE7IH0KICAuYnRuLW1haW46YWN0aXZlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CgogIC5idG4tbWFpbiAuYnRuLXNoaW5lIHsKICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgIHRvcDogMDsgbGVmdDogLTEwMCU7CiAgICB3aWR0aDogNjAlOwogICAgaGVpZ2h0OiAxMDAlOwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCB0cmFuc3BhcmVudCwgcmdiYSgyNTUsMjU1LDI1NSwwLjIpLCB0cmFuc3BhcmVudCk7CiAgICB0cmFuc2Zvcm06IHNrZXdYKC0yMGRlZyk7CiAgICBhbmltYXRpb246IHNoaW5lIDNzIGVhc2UtaW4tb3V0IGluZmluaXRlIDFzOwogIH0KCiAgQGtleWZyYW1lcyBzaGluZSB7CiAgICAwJSB7IGxlZnQ6IC0xMDAlOyB9CiAgICAzMCUsIDEwMCUgeyBsZWZ0OiAxNTAlOyB9CiAgfQoKICAvKiDilIDilIAgRGl2aWRlciDilIDilIAgKi8KICAuZGl2aWRlciB7CiAgICBkaXNwbGF5OiBmbGV4OwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgIGdhcDogMTJweDsKICAgIG1hcmdpbjogMjBweCAwOwogICAgY29sb3I6IHZhcigtLW11dGVkKTsKICAgIGZvbnQtc2l6ZTogMTFweDsKICAgIGxldHRlci1zcGFjaW5nOiAycHg7CiAgfQoKICAuZGl2aWRlcjo6YmVmb3JlLCAuZGl2aWRlcjo6YWZ0ZXIgewogICAgY29udGVudDogJyc7CiAgICBmbGV4OiAxOwogICAgaGVpZ2h0OiAxcHg7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHRyYW5zcGFyZW50LCByZ2JhKDEyNCw1OCwyMzcsMC4zKSwgdHJhbnNwYXJlbnQpOwogIH0KCiAgLyog4pSA4pSAIFJlc2V0IHNlY3Rpb24g4pSA4pSAICovCiAgLnJlc2V0LXNlY3Rpb24gewogICAgYmFja2dyb3VuZDogcmdiYSgxMjQsNTgsMjM3LDAuMDUpOwogICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMjQsNTgsMjM3LDAuMik7CiAgICBib3JkZXItcmFkaXVzOiAxMnB4OwogICAgcGFkZGluZzogMTZweDsKICAgIG1hcmdpbi10b3A6IDRweDsKICB9CgogIC5idG4tcmVzZXQgewogICAgd2lkdGg6IDEwMCU7CiAgICBwYWRkaW5nOiAxMnB4OwogICAgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQ7CiAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDk2LDE2NSwyNTAsMC40KTsKICAgIGJvcmRlci1yYWRpdXM6IDEwcHg7CiAgICBjb2xvcjogdmFyKC0tYmx1ZS1saWdodCk7CiAgICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogICAgZm9udC1zaXplOiAxMnB4OwogICAgZm9udC13ZWlnaHQ6IDcwMDsKICAgIGxldHRlci1zcGFjaW5nOiAycHg7CiAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4zczsKICAgIG1hcmdpbi10b3A6IDRweDsKICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgIG92ZXJmbG93OiBoaWRkZW47CiAgfQoKICAuYnRuLXJlc2V0OmhvdmVyIHsKICAgIGJhY2tncm91bmQ6IHJnYmEoMzcsOTksMjM1LDAuMTUpOwogICAgYm9yZGVyLWNvbG9yOiB2YXIoLS1ibHVlLWxpZ2h0KTsKICAgIGJveC1zaGFkb3c6IDAgMCAyMHB4IHJnYmEoMzcsOTksMjM1LDAuMyk7CiAgfQoKICAvKiDilIDilIAgRm9vdGVyIOKUgOKUgCAqLwogIC5mb290ZXIgewogICAgdGV4dC1hbGlnbjogY2VudGVyOwogICAgbWFyZ2luLXRvcDogMjBweDsKICAgIGZvbnQtZmFtaWx5OiAnT3JiaXRyb24nLCBtb25vc3BhY2U7CiAgICBmb250LXNpemU6IDhweDsKICAgIGxldHRlci1zcGFjaW5nOiAzcHg7CiAgICBjb2xvcjogdmFyKC0tbXV0ZWQpOwogICAgZGlzcGxheTogZmxleDsKICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIGdhcDogOHB4OwogIH0KCiAgLmZvb3Rlci1kb3QgewogICAgd2lkdGg6IDNweDsKICAgIGhlaWdodDogM3B4OwogICAgYm9yZGVyLXJhZGl1czogNTAlOwogICAgYmFja2dyb3VuZDogdmFyKC0tcHVycGxlLWxpZ2h0KTsKICAgIG9wYWNpdHk6IDAuNTsKICB9CgogIC8qIOKUgOKUgCBSZXNldCBidXR0b24gKHJlcGxhY2VzIHJlc2V0LXNlY3Rpb24pIOKUgOKUgCAqLwogIC5idG4tb3Blbi1yZXNldCB7CiAgICB3aWR0aDogMTAwJTsKICAgIHBhZGRpbmc6IDEzcHg7CiAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoOTYsMTY1LDI1MCwwLjM1KTsKICAgIGJvcmRlci1yYWRpdXM6IDEwcHg7CiAgICBjb2xvcjogdmFyKC0tYmx1ZS1saWdodCk7CiAgICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogICAgZm9udC1zaXplOiAxMXB4OwogICAgZm9udC13ZWlnaHQ6IDcwMDsKICAgIGxldHRlci1zcGFjaW5nOiAycHg7CiAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4zczsKICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgIG92ZXJmbG93OiBoaWRkZW47CiAgfQogIC5idG4tb3Blbi1yZXNldDpob3ZlciB7CiAgICBiYWNrZ3JvdW5kOiByZ2JhKDM3LDk5LDIzNSwwLjEyKTsKICAgIGJvcmRlci1jb2xvcjogdmFyKC0tYmx1ZS1saWdodCk7CiAgICBib3gtc2hhZG93OiAwIDAgMjBweCByZ2JhKDM3LDk5LDIzNSwwLjI1KTsKICB9CgogIC8qIOKUgOKUgCBNb2RhbCBvdmVybGF5IOKUgOKUgCAqLwogIC5tb2RhbC1vdmVybGF5IHsKICAgIGRpc3BsYXk6IG5vbmU7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBpbnNldDogMDsKICAgIGJhY2tncm91bmQ6IHJnYmEoMiw0LDE1LDAuNzUpOwogICAgYmFja2Ryb3AtZmlsdGVyOiBibHVyKDZweCk7CiAgICB6LWluZGV4OiAxMDA7CiAgICBhbGlnbi1pdGVtczogY2VudGVyOwogICAganVzdGlmeS1jb250ZW50OiBjZW50ZXI7CiAgICBwYWRkaW5nOiAyMHB4OwogIH0KICAubW9kYWwtb3ZlcmxheS5vcGVuIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBhbmltYXRpb246IGZhZGVJbiAwLjI1cyBlYXNlIGJvdGg7CiAgfQogIEBrZXlmcmFtZXMgZmFkZUluIHsKICAgIGZyb20geyBvcGFjaXR5OiAwOyB9CiAgICB0byAgIHsgb3BhY2l0eTogMTsgfQogIH0KCiAgLm1vZGFsIHsKICAgIHdpZHRoOiAxMDAlOwogICAgbWF4LXdpZHRoOiAzODBweDsKICAgIGJhY2tncm91bmQ6IHJnYmEoOCwxMiwzNSwwLjk3KTsKICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoOTYsMTY1LDI1MCwwLjMpOwogICAgYm9yZGVyLXJhZGl1czogMjBweDsKICAgIHBhZGRpbmc6IDI4cHggMjRweCAyNHB4OwogICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgYm94LXNoYWRvdzogMCAwIDAgMXB4IHJnYmEoMzcsOTksMjM1LDAuMSksIDAgMjRweCA2NHB4IHJnYmEoMCwwLDAsMC43KTsKICAgIGFuaW1hdGlvbjogc2xpZGVVcCAwLjNzIGN1YmljLWJlemllciguNCwwLC4yLDEpIGJvdGg7CiAgfQogIEBrZXlmcmFtZXMgc2xpZGVVcCB7CiAgICBmcm9tIHsgb3BhY2l0eTogMDsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDI0cHgpOyB9CiAgICB0byAgIHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgfQogIC5tb2RhbDo6YmVmb3JlIHsgY29udGVudDonJzsgcG9zaXRpb246YWJzb2x1dGU7IHRvcDotMXB4OyBsZWZ0Oi0xcHg7IHdpZHRoOjIwcHg7IGhlaWdodDoyMHB4OyBib3JkZXItdG9wOjEuNXB4IHNvbGlkIHJnYmEoOTYsMTY1LDI1MCwwLjUpOyBib3JkZXItbGVmdDoxLjVweCBzb2xpZCByZ2JhKDk2LDE2NSwyNTAsMC41KTsgYm9yZGVyLXJhZGl1czo0cHggMCAwIDA7IH0KICAubW9kYWw6OmFmdGVyICB7IGNvbnRlbnQ6Jyc7IHBvc2l0aW9uOmFic29sdXRlOyBib3R0b206LTFweDsgcmlnaHQ6LTFweDsgd2lkdGg6MjBweDsgaGVpZ2h0OjIwcHg7IGJvcmRlci1ib3R0b206MS41cHggc29saWQgcmdiYSg2LDE4MiwyMTIsMC41KTsgYm9yZGVyLXJpZ2h0OjEuNXB4IHNvbGlkIHJnYmEoNiwxODIsMjEyLDAuNSk7IGJvcmRlci1yYWRpdXM6MCAwIDRweCAwOyB9CgogIC5tb2RhbC1oZWFkZXIgewogICAgZGlzcGxheTogZmxleDsKICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IHNwYWNlLWJldHdlZW47CiAgICBtYXJnaW4tYm90dG9tOiAyMHB4OwogIH0KICAubW9kYWwtdGl0bGUgewogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsKICAgIGZvbnQtc2l6ZTogMTFweDsKICAgIGZvbnQtd2VpZ2h0OiA3MDA7CiAgICBsZXR0ZXItc3BhY2luZzogM3B4OwogICAgY29sb3I6IHZhcigtLWJsdWUtbGlnaHQpOwogICAgZGlzcGxheTogZmxleDsKICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICBnYXA6IDhweDsKICB9CiAgLm1vZGFsLXRpdGxlOjpiZWZvcmUgewogICAgY29udGVudDogJyc7CiAgICB3aWR0aDogNHB4OyBoZWlnaHQ6IDE0cHg7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCB2YXIoLS1ibHVlKSwgdmFyKC0tY3lhbikpOwogICAgYm9yZGVyLXJhZGl1czogMnB4OwogIH0KICAubW9kYWwtY2xvc2UgewogICAgYmFja2dyb3VuZDogbm9uZTsKICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoOTYsMTY1LDI1MCwwLjIpOwogICAgYm9yZGVyLXJhZGl1czogOHB4OwogICAgY29sb3I6IHZhcigtLW11dGVkKTsKICAgIGZvbnQtc2l6ZTogMTZweDsKICAgIHdpZHRoOiAzMnB4OyBoZWlnaHQ6IDMycHg7CiAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIHRyYW5zaXRpb246IGFsbCAwLjJzOwogICAgbGluZS1oZWlnaHQ6IDE7CiAgfQogIC5tb2RhbC1jbG9zZTpob3ZlciB7IGJvcmRlci1jb2xvcjogcmdiYSg5NiwxNjUsMjUwLDAuNSk7IGNvbG9yOiB2YXIoLS1ibHVlLWxpZ2h0KTsgfQoKICAvKiBtb2RhbCBpbnB1dDogdXNlIGJsdWUgYWNjZW50IGluc3RlYWQgb2YgcHVycGxlICovCiAgLm1vZGFsIC5maSB7IGJvcmRlci1jb2xvcjogcmdiYSgzNyw5OSwyMzUsMC4zKTsgfQogIC5tb2RhbCAuZmk6Zm9jdXMgeyBib3JkZXItY29sb3I6IHZhcigtLWJsdWUtbGlnaHQpOyBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSgzNyw5OSwyMzUsMC4xNSk7IH0KICAubW9kYWwgLmlucHV0LWljb24geyBjb2xvcjogdmFyKC0tYmx1ZS1saWdodCk7IH0KCiAgLmJ0bi1jcmVhdGUgewogICAgd2lkdGg6IDEwMCU7CiAgICBwYWRkaW5nOiAxNHB4OwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDEzNWRlZywgdmFyKC0tYmx1ZSksICMwZWE1ZTkpOwogICAgYm9yZGVyOiBub25lOwogICAgYm9yZGVyLXJhZGl1czogMTBweDsKICAgIGNvbG9yOiAjZmZmOwogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsKICAgIGZvbnQtc2l6ZTogMTJweDsKICAgIGZvbnQtd2VpZ2h0OiA3MDA7CiAgICBsZXR0ZXItc3BhY2luZzogMnB4OwogICAgY3Vyc29yOiBwb2ludGVyOwogICAgbWFyZ2luLXRvcDogNHB4OwogICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgb3ZlcmZsb3c6IGhpZGRlbjsKICAgIHRyYW5zaXRpb246IGFsbCAwLjNzOwogICAgYm94LXNoYWRvdzogMCA0cHggMjBweCByZ2JhKDM3LDk5LDIzNSwwLjQpOwogIH0KICAuYnRuLWNyZWF0ZTpob3ZlciB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsgYm94LXNoYWRvdzogMCA4cHggMjhweCByZ2JhKDM3LDk5LDIzNSwwLjU1KTsgfQogIC5idG4tY3JlYXRlOmFjdGl2ZSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsgfQogIC5idG4tY3JlYXRlIC5idG4tc2hpbmUgewogICAgcG9zaXRpb246YWJzb2x1dGU7IHRvcDowOyBsZWZ0Oi0xMDAlOyB3aWR0aDo2MCU7IGhlaWdodDoxMDAlOwogICAgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdHJhbnNwYXJlbnQscmdiYSgyNTUsMjU1LDI1NSwwLjE4KSx0cmFuc3BhcmVudCk7CiAgICB0cmFuc2Zvcm06c2tld1goLTIwZGVnKTsKICAgIGFuaW1hdGlvbjpzaGluZSAzcyBlYXNlLWluLW91dCBpbmZpbml0ZSAxLjJzOwogIH0KCiAgLmFsZXJ0IHsKICAgIHBhZGRpbmc6IDEwcHggMTRweDsKICAgIGJvcmRlci1yYWRpdXM6IDhweDsKICAgIGZvbnQtc2l6ZTogMTJweDsKICAgIG1hcmdpbi1ib3R0b206IDEycHg7CiAgICBkaXNwbGF5OiBub25lOwogICAgYm9yZGVyOiAxcHggc29saWQ7CiAgfQoKICAuYWxlcnQuZXJyIHsgYmFja2dyb3VuZDogcmdiYSgyMzksNjgsNjgsMC4xKTsgYm9yZGVyLWNvbG9yOiByZ2JhKDIzOSw2OCw2OCwwLjMpOyBjb2xvcjogI2ZjYTVhNTsgfQogIC5hbGVydC5vayB7IGJhY2tncm91bmQ6IHJnYmEoMzQsMTk3LDk0LDAuMSk7IGJvcmRlci1jb2xvcjogcmdiYSgzNCwxOTcsOTQsMC4zKTsgY29sb3I6ICM4NmVmYWM7IH0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KCjxkaXYgY2xhc3M9ImJnIj48L2Rpdj4KCjwhLS0gUGFydGljbGVzIC0tPgo8c2NyaXB0Pgpmb3IgKGxldCBpID0gMDsgaSA8IDIwOyBpKyspIHsKICBjb25zdCBwID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgcC5jbGFzc05hbWUgPSAncGFydGljbGUnOwogIGNvbnN0IHNpemUgPSBNYXRoLnJhbmRvbSgpICogNCArIDE7CiAgY29uc3QgY29sb3JzID0gWycjN2MzYWVkJywnI2E4NTVmNycsJyMyNTYzZWInLCcjNjBhNWZhJywnIzA2YjZkNCddOwogIHAuc3R5bGUuY3NzVGV4dCA9IGAKICAgIHdpZHRoOiR7c2l6ZX1weDsgaGVpZ2h0OiR7c2l6ZX1weDsKICAgIGxlZnQ6JHtNYXRoLnJhbmRvbSgpKjEwMH0lOwogICAgYmFja2dyb3VuZDoke2NvbG9yc1tNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkqY29sb3JzLmxlbmd0aCldfTsKICAgIGFuaW1hdGlvbi1kdXJhdGlvbjoke01hdGgucmFuZG9tKCkqMTUrMTB9czsKICAgIGFuaW1hdGlvbi1kZWxheToke01hdGgucmFuZG9tKCkqMTB9czsKICAgIGJveC1zaGFkb3c6IDAgMCAke3NpemUqM31weCBjdXJyZW50Q29sb3I7CiAgYDsKICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKHApOwp9Cjwvc2NyaXB0PgoKPGRpdiBzdHlsZT0icG9zaXRpb246cmVsYXRpdmU7ei1pbmRleDoxMDt3aWR0aDoxMDAlO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6MjBweCAwIj4KCiAgPCEtLSBMb2dvIC0tPgogIDxkaXYgY2xhc3M9ImxvZ28td3JhcCI+CiAgICA8IS0tIFNpZ25hbCBQdWxzZSBTVkcgTG9nbyAtLT4KICAgIDxkaXYgY2xhc3M9ImxvZ28tc3ZnLXdyYXAiPgogICAgICA8c3ZnIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdpZHRoPSI5MCIgaGVpZ2h0PSI5MCI+CiAgICAgICAgPGRlZnM+CiAgICAgICAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxnVyIgeDE9IjAlIiB5MT0iMCUiIHgyPSIxMDAlIiB5Mj0iMCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMyNTYzZWIiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSI1MCUiICBzdG9wLWNvbG9yPSIjNjBhNWZhIi8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzA2YjZkNCIvPgogICAgICAgICAgPC9saW5lYXJHcmFkaWVudD4KICAgICAgICAgIDxyYWRpYWxHcmFkaWVudCBpZD0ibGdCZyIgY3g9IjUwJSIgY3k9IjUwJSIgcj0iNTAlIj4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9yPSIjMGYxZTRhIiBzdG9wLW9wYWNpdHk9IjAuOTUiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjMDYwYzFlIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgICAgICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAgICAgICA8ZmlsdGVyIGlkPSJsZ0dsb3ciPgogICAgICAgICAgICA8ZmVHYXVzc2lhbkJsdXIgc3RkRGV2aWF0aW9uPSIyLjUiIHJlc3VsdD0iYiIvPgogICAgICAgICAgICA8ZmVNZXJnZT48ZmVNZXJnZU5vZGUgaW49ImIiLz48ZmVNZXJnZU5vZGUgaW49IlNvdXJjZUdyYXBoaWMiLz48L2ZlTWVyZ2U+CiAgICAgICAgICA8L2ZpbHRlcj4KICAgICAgICAgIDxjbGlwUGF0aCBpZD0ibGdDbGlwIj48Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIvPjwvY2xpcFBhdGg+CiAgICAgICAgPC9kZWZzPgoKICAgICAgICA8IS0tIE91dGVyIGZhaW50IHJpbmcgLS0+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSgzNyw5OSwyMzUsMC4xMikiIHN0cm9rZS13aWR0aD0iMSIvPgoKICAgICAgICA8IS0tIE9yYml0aW5nIGRhc2hlZCByaW5nIC0tPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQyIgogICAgICAgICAgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC4yKSIgc3Ryb2tlLXdpZHRoPSIxIgogICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iNSA0IgogICAgICAgICAgY2xhc3M9Im9yYml0LXJpbmctYW5pbSIvPgoKICAgICAgICA8IS0tIE1pZCByaW5nIC0tPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM4IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMjIpIiBzdHJva2Utd2lkdGg9IjEiLz4KCiAgICAgICAgPCEtLSBDaXJjbGUgYm9keSAtLT4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIgZmlsbD0idXJsKCNsZ0JnKSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0IiBmaWxsPSJub25lIiBzdHJva2U9InVybCgjbGdXKSIgc3Ryb2tlLXdpZHRoPSIxLjgiIG9wYWNpdHk9IjAuOSIvPgoKICAgICAgICA8IS0tIENvbXBhc3MgdGlja3MgLS0+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iMTQiIHgyPSI1MCIgeTI9IjIwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI1MCIgeTE9IjgwIiB4Mj0iNTAiIHkyPSI4NiIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iMTQiIHkxPSI1MCIgeDI9IjIwIiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjgwIiB5MT0iNTAiIHgyPSI4NiIgeTI9IjUwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgoKICAgICAgICA8IS0tIERpYWdvbmFsIHRpY2tzIC0tPgogICAgICAgIDxsaW5lIHgxPSI3NCIgeTE9IjI0IiB4Mj0iNzgiIHkyPSIyMCIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjQpIiBzdHJva2Utd2lkdGg9IjEiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSIyNiIgeTE9IjI0IiB4Mj0iMjIiIHkyPSIyMCIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjQpIiBzdHJva2Utd2lkdGg9IjEiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI3NCIgeTE9Ijc2IiB4Mj0iNzgiIHkyPSI4MCIgc3Ryb2tlPSJyZ2JhKDYsMTgyLDIxMiwwLjQpIiAgc3Ryb2tlLXdpZHRoPSIxIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iMjYiIHkxPSI3NiIgeDI9IjIyIiB5Mj0iODAiIHN0cm9rZT0icmdiYSg2LDE4MiwyMTIsMC40KSIgIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CgogICAgICAgIDwhLS0gV2F2ZWZvcm0gKGNsaXBwZWQpIC0tPgogICAgICAgIDxnIGNsaXAtcGF0aD0idXJsKCNsZ0NsaXApIj4KICAgICAgICAgIDxwb2x5bGluZQogICAgICAgICAgICBwb2ludHM9IjE2LDUwIDI0LDUwIDI5LDMyIDM0LDY4IDM5LDMyIDQ0LDUwIDg0LDUwIgogICAgICAgICAgICBmaWxsPSJub25lIiBzdHJva2U9InVybCgjbGdXKSIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIKICAgICAgICAgICAgZmlsdGVyPSJ1cmwoI2xnR2xvdykiCiAgICAgICAgICAgIGNsYXNzPSJ3YXZlLWFuaW0iLz4KICAgICAgICA8L2c+CgogICAgICAgIDwhLS0gUGVhayBkb3RzIC0tPgogICAgICAgIDxjaXJjbGUgY3g9IjI5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzYwYTVmYSIgZmlsdGVyPSJ1cmwoI2xnR2xvdykiIGNsYXNzPSJkb3QtYW5pbS0xIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjMDZiNmQ0IiBmaWx0ZXI9InVybCgjbGdHbG93KSIgY2xhc3M9ImRvdC1hbmltLTIiLz4KICAgICAgICA8Y2lyY2xlIGN4PSIzNCIgY3k9IjY4IiByPSIyLjUiIGZpbGw9IiM2MGE1ZmEiIGZpbHRlcj0idXJsKCNsZ0dsb3cpIiBjbGFzcz0iZG90LWFuaW0tMSIvPgogICAgICA8L3N2Zz4KICAgIDwvZGl2PgoKICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyMHB4O2ZvbnQtd2VpZ2h0OjkwMDtsZXR0ZXItc3BhY2luZzo0cHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2UwZjJmZSwjNjBhNWZhLCMwNmI2ZDQpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7Ij5DSEFJWUE8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6OXB4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjYpO21hcmdpbi10b3A6MnB4OyI+UFJPSkVDVDwvZGl2PgogICAgPGRpdiBzdHlsZT0id2lkdGg6MTYwcHg7aGVpZ2h0OjFweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCwjNjBhNWZhLCMwNmI2ZDQsdHJhbnNwYXJlbnQpO21hcmdpbjo4cHggYXV0bztvcGFjaXR5OjAuNTsiPjwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6cmdiYSg2LDE4MiwyMTIsMC41NSk7bWFyZ2luLXRvcDoycHg7Ij5WMlJBWSAmYW1wOyBTU0g8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6aW5saW5lLWJsb2NrO21hcmdpbi10b3A6OHB4O3BhZGRpbmc6M3B4IDE0cHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDk2LDE2NSwyNTAsMC4zNSk7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOiM2MGE1ZmE7YmFja2dyb3VuZDpyZ2JhKDM3LDk5LDIzNSwwLjEpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyI+QUxMLUlOLU9ORSBQUk88L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSBDYXJkIC0tPgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGRpdiBpZD0iYWxlcnQtYm94IiBjbGFzcz0iYWxlcnQiPjwvZGl2PgoKICAgIDwhLS0gTG9naW4gc2VjdGlvbiAtLT4KICAgIDxkaXYgY2xhc3M9InNlY3Rpb24tdGl0bGUiPuC5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mjwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpZWxkIj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQtbGFiZWwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5ieC4h+C4suC4mTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbnB1dC13cmFwIj4KICAgICAgICA8c3BhbiBjbGFzcz0iaW5wdXQtaWNvbiI+8J+RpDwvc3Bhbj4KICAgICAgICA8aW5wdXQgY2xhc3M9ImZpIiBpZD0idXNlcm5hbWUiIHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLguIHguKPguK3guIHguIrguLfguYjguK3guJzguLnguYnguYPguIrguYnguIfguLLguJkiIGF1dG9jb21wbGV0ZT0ib2ZmIj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkLWxhYmVsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5wdXQtd3JhcCI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImlucHV0LWljb24iPvCflJI8L3NwYW4+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9InBhc3N3b3JkIiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IuC4geC4o+C4reC4geC4o+C4q+C4seC4quC4nOC5iOC4suC4mSI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iZXllLXRvZ2dsZSIgb25jbGljaz0idG9nZ2xlUHcoJ3Bhc3N3b3JkJyx0aGlzKSIgdGFiaW5kZXg9Ii0xIj7wn5GBPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuLW1haW4iIG9uY2xpY2s9ImRvTG9naW4oKSI+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1zaGluZSI+PC9kaXY+CiAgICAgIPCflJAgJm5ic3A74LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4LiaCiAgICA8L2J1dHRvbj4KCiAgICA8IS0tIFJlc2V0IGJ1dHRvbiAtLT4KICAgIDxidXR0b24gY2xhc3M9ImJ0bi1vcGVuLXJlc2V0IiBvbmNsaWNrPSJvcGVuTW9kYWwoKSI+CiAgICAgIPCflJEgJm5ic3A74LiV4Lix4LmJ4LiH4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJIC8g4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZ4LmD4Lir4Lih4LmICiAgICA8L2J1dHRvbj4KCiAgICA8IS0tIEZvb3RlciAtLT4KICAgIDxkaXYgY2xhc3M9ImZvb3RlciI+CiAgICAgIENIQUlZQS1QUk9KRUNUIFYyUkFZJmFtcDtTU0ggQUxMLUlOLU9ORSBQUk8KICAgICAgPGRpdiBjbGFzcz0iZm9vdGVyLWRvdCI+PC9kaXY+CiAgICAgIFNFQ1VSRQogICAgICA8ZGl2IGNsYXNzPSJmb290ZXItZG90Ij48L2Rpdj4KICAgICAgU1RBQkxFCiAgICAgIDxkaXYgY2xhc3M9ImZvb3Rlci1kb3QiPjwvZGl2PgogICAgICBGQVNUCiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIFJlc2V0IE1vZGFsIC0tPgo8ZGl2IGNsYXNzPSJtb2RhbC1vdmVybGF5IiBpZD0icmVzZXRNb2RhbCIgb25jbGljaz0iY2xvc2VNb2RhbE91dHNpZGUoZXZlbnQpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtb2RhbC1oZWFkZXIiPgogICAgICA8ZGl2IGNsYXNzPSJtb2RhbC10aXRsZSI+4LiV4Lix4LmJ4LiH4LiE4LmI4Liy4Lic4Li54LmJ4LmD4LiK4LmJ4LmD4Lir4Lih4LmIPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1vZGFsLWNsb3NlIiBvbmNsaWNrPSJjbG9zZU1vZGFsKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0ibW9kYWwtYWxlcnQiIGNsYXNzPSJhbGVydCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTRweCI+PC9kaXY+CgogICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZC1sYWJlbCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJ4LmD4Lir4Lih4LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImlucHV0LXdyYXAiPgogICAgICAgIDxzcGFuIGNsYXNzPSJpbnB1dC1pY29uIj7wn5GkPC9zcGFuPgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJuZXctdXNlciIgdHlwZT0idGV4dCIgcGxhY2Vob2xkZXI9IuC4geC4o+C4reC4geC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5ieC5g+C4q+C4oeC5iCIgYXV0b2NvbXBsZXRlPSJvZmYiPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpZWxkIj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQtbGFiZWwiPuC4o+C4q+C4seC4quC4nOC5iOC4suC4meC5g+C4q+C4oeC5iDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbnB1dC13cmFwIj4KICAgICAgICA8c3BhbiBjbGFzcz0iaW5wdXQtaWNvbiI+8J+UkTwvc3Bhbj4KICAgICAgICA8aW5wdXQgY2xhc3M9ImZpIiBpZD0ibmV3LXBhc3MiIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0i4LiB4Lij4Lit4LiB4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZ4LmD4Lir4Lih4LmIIj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJleWUtdG9nZ2xlIiBvbmNsaWNrPSJ0b2dnbGVQdygnbmV3LXBhc3MnLHRoaXMpIiB0YWJpbmRleD0iLTEiPvCfkYE8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTZweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkLWxhYmVsIj7guKLguLfguJnguKLguLHguJnguKPguKvguLHguKrguJzguYjguLLguJnguYPguKvguKHguYg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5wdXQtd3JhcCI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImlucHV0LWljb24iPvCflJE8L3NwYW4+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImNvbmZpcm0tcGFzcyIgdHlwZT0icGFzc3dvcmQiIHBsYWNlaG9sZGVyPSLguKLguLfguJnguKLguLHguJnguKPguKvguLHguKrguJzguYjguLLguJnguYPguKvguKHguYgiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImV5ZS10b2dnbGUiIG9uY2xpY2s9InRvZ2dsZVB3KCdjb25maXJtLXBhc3MnLHRoaXMpIiB0YWJpbmRleD0iLTEiPvCfkYE8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8YnV0dG9uIGNsYXNzPSJidG4tY3JlYXRlIiBvbmNsaWNrPSJkb1Jlc2V0KCkiPgogICAgICA8ZGl2IGNsYXNzPSJidG4tc2hpbmUiPjwvZGl2PgogICAgICDinIUgJm5ic3A74Liq4Lij4LmJ4Liy4LiH4Lic4Li54LmJ4LmD4LiK4LmJ4LmD4Lir4Lih4LmICiAgICA8L2J1dHRvbj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0PgpmdW5jdGlvbiB0b2dnbGVQdyhpZCwgYnRuKSB7CiAgY29uc3QgaW5wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlucC50eXBlID0gaW5wLnR5cGUgPT09ICdwYXNzd29yZCcgPyAndGV4dCcgOiAncGFzc3dvcmQnOwogIGJ0bi50ZXh0Q29udGVudCA9IGlucC50eXBlID09PSAncGFzc3dvcmQnID8gJ/CfkYEnIDogJ/CfmYgnOwp9CgpmdW5jdGlvbiBzaG93QWxlcnQobXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWxlcnQtYm94Jyk7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcgKyB0eXBlOwogIGVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIHNldFRpbWVvdXQoKCkgPT4geyBlbC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOyB9LCAzMDAwKTsKfQoKZnVuY3Rpb24gc2hvd01vZGFsQWxlcnQobXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyArIHR5cGU7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgc2V0VGltZW91dCgoKSA9PiB7IGVsLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7IH0sIDMwMDApOwp9CgpmdW5jdGlvbiBvcGVuTW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Jlc2V0TW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgZG9jdW1lbnQuYm9keS5zdHlsZS5vdmVyZmxvdyA9ICdoaWRkZW4nOwogIHNldFRpbWVvdXQoKCkgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldy11c2VyJykuZm9jdXMoKSwgMzAwKTsKfQoKZnVuY3Rpb24gY2xvc2VNb2RhbCgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmVzZXRNb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBkb2N1bWVudC5ib2R5LnN0eWxlLm92ZXJmbG93ID0gJyc7Cn0KCmZ1bmN0aW9uIGNsb3NlTW9kYWxPdXRzaWRlKGUpIHsKICBpZiAoZS50YXJnZXQgPT09IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyZXNldE1vZGFsJykpIGNsb3NlTW9kYWwoKTsKfQoKZnVuY3Rpb24gZG9Mb2dpbigpIHsKICBjb25zdCB1ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXJuYW1lJykudmFsdWUudHJpbSgpOwogIGNvbnN0IHAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzc3dvcmQnKS52YWx1ZTsKICBpZiAoIXUgfHwgIXApIHJldHVybiBzaG93QWxlcnQoJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5ieC5geC4peC4sOC4o+C4q+C4seC4quC4nOC5iOC4suC4mScsICdlcnInKTsKICBzaG93QWxlcnQoJ+C4geC4s+C4peC4seC4h+C5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mi4uLicsICdvaycpOwp9CgpmdW5jdGlvbiBkb1Jlc2V0KCkgewogIGNvbnN0IHUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV3LXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXctcGFzcycpLnZhbHVlOwogIGNvbnN0IGMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29uZmlybS1wYXNzJykudmFsdWU7CiAgaWYgKCF1IHx8ICFwIHx8ICFjKSByZXR1cm4gc2hvd01vZGFsQWxlcnQoJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4guC5ieC4reC4oeC4ueC4peC5g+C4q+C5ieC4hOC4o+C4micsICdlcnInKTsKICBpZiAocCAhPT0gYykgcmV0dXJuIHNob3dNb2RhbEFsZXJ0KCfguKPguKvguLHguKrguJzguYjguLLguJnguYTguKHguYjguJXguKPguIfguIHguLHguJknLCAnZXJyJyk7CiAgLy8gVE9ETzogc3VibWl0IHRvIGJhY2tlbmQKICBzaG93TW9kYWxBbGVydCgn4Liq4Lij4LmJ4Liy4LiH4Lic4Li54LmJ4LmD4LiK4LmJ4LmD4Lir4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIIOKckycsICdvaycpOwogIHNldFRpbWVvdXQoKCkgPT4gY2xvc2VNb2RhbCgpLCAxODAwKTsKfQo8L3NjcmlwdD4KCjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/index.html
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
XUI_PORT=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "54321")
XUI_USER=$(cat /etc/chaiya/xui-user.conf 2>/dev/null || echo "admin")
clear
echo ""
echo -e "${G}╔══════════════════════════════════════════════╗${N}"
echo -e "${G}║         CHAIYA VPN PANEL v8  🛸              ║${N}"
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
info "Apply patch v8 — อัพเดต app.py และ sshws.html..."
info "Patching Chaiya VPN Panel v8..."

# ── STEP 1: เพิ่ม API endpoints ใหม่ใน app.py ─────────────────
info "อัพเดต SSH API..."

cat > /opt/chaiya-ssh-api/app.py << 'PYEOF'
#!/usr/bin/env python3
"""Chaiya SSH API v8 - /api/banned, /api/unban, /api/online_ssh"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, threading, sqlite3, time, re

XUI_DB = '/etc/x-ui/x-ui.db'

def find_xui_db():
    """ค้นหา x-ui.db จากหลาย path ที่เป็นไปได้"""
    candidates = [
        '/etc/x-ui/x-ui.db',
        '/root/.local/share/3x-ui/db/x-ui.db',
        '/usr/local/x-ui/x-ui.db',
        '/opt/x-ui/x-ui.db',
    ]
    for p in candidates:
        if os.path.exists(p):
            return p
    try:
        r = subprocess.run('find / -name "x-ui.db" -not -path "*/proc/*" 2>/dev/null | head -1',
                           shell=True, capture_output=True, text=True, timeout=5)
        p = r.stdout.strip()
        if p and os.path.exists(p):
            return p
    except: pass
    return '/etc/x-ui/x-ui.db'

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
    """ดึง SSH users ที่ online จริง — ใช้หลายวิธีเพื่อรองรับ Dropbear"""
    online = []
    try:
        users_map = {}
        for u in list_ssh_users():
            users_map[u['user']] = u

        if not users_map:
            return []

        seen = set()

        # วิธี 1: who — บน tty/pts login
        _, who_out, _ = run_cmd("who 2>/dev/null || true")
        if who_out:
            for line in who_out.strip().split('\n'):
                parts = line.split()
                if parts and parts[0] in users_map and parts[0] not in seen:
                    seen.add(parts[0])
                    online.append(users_map[parts[0]].copy())

        # วิธี 2: w -h — แสดง logged-in users รวม pts
        _, w_out, _ = run_cmd("w -h 2>/dev/null || true")
        if w_out:
            for line in w_out.strip().split('\n'):
                parts = line.split()
                if parts and parts[0] in users_map and parts[0] not in seen:
                    seen.add(parts[0])
                    online.append(users_map[parts[0]].copy())

        # วิธี 3: ss -tnp บน port dropbear หา uid จาก /proc/PID/loginuid
        _, ss_out, _ = run_cmd(
            "ss -tnp state established 2>/dev/null | grep -E ':(143|109)' || true"
        )
        if ss_out:
            import re as _re
            for pid_m in _re.findall(r'pid=(\d+)', ss_out):
                try:
                    # ลอง loginuid ก่อน (น่าเชื่อถือกว่า uid สำหรับ dropbear)
                    loginuid_path = f'/proc/{pid_m}/loginuid'
                    uid = -1
                    if os.path.exists(loginuid_path):
                        val = open(loginuid_path).read().strip()
                        if val and val != '4294967295':
                            uid = int(val)
                    if uid < 1000 or uid > 60000:
                        # fallback: /proc/PID/status Uid
                        status_path = f'/proc/{pid_m}/status'
                        if os.path.exists(status_path):
                            for ln in open(status_path):
                                if ln.startswith('Uid:'):
                                    uid = int(ln.split()[1])
                                    break
                    if uid < 1000 or uid > 60000:
                        continue
                    import pwd as _pwd
                    try:
                        uname = _pwd.getpwuid(uid).pw_name
                    except:
                        continue
                    if uname in users_map and uname not in seen:
                        seen.add(uname)
                        online.append(users_map[uname].copy())
                except:
                    continue

        # วิธี 4: /proc/*/loginuid scan — หา uid ของ processes ทั้งหมดที่ match user
        if not online:
            try:
                import glob, pwd as _pwd2
                for loginuid_file in glob.glob('/proc/*/loginuid'):
                    try:
                        val = open(loginuid_file).read().strip()
                        if not val or val == '4294967295':
                            continue
                        uid = int(val)
                        if uid < 1000 or uid > 60000:
                            continue
                        try:
                            uname = _pwd2.getpwuid(uid).pw_name
                        except:
                            continue
                        if uname in users_map and uname not in seen:
                            seen.add(uname)
                            online.append(users_map[uname].copy())
                    except:
                        continue
            except: pass

        # วิธี 5: fallback นับ connection count
        if not online:
            _, conn_out, _ = run_cmd(
                "ss -tn state established 2>/dev/null | awk '{print $4}' | grep -cE ':(143|109)$' || echo 0"
            )
            try:
                cnt = int(conn_out.strip().split()[0])
                if cnt > 0:
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
        if os.path.exists(find_xui_db()):
            con = sqlite3.connect(find_xui_db(), timeout=10); con.execute('PRAGMA journal_mode=WAL')
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

    def do_HEAD(self):
        self.do_GET()

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
            # ดึง VLESS online โดยเช็ค active connections บน xray ports
            import sqlite3 as _sq3
            emails = []
            try:
                _db = find_xui_db()
                if os.path.exists(_db):
                    con = _sq3.connect(_db, timeout=10)
                    con.execute('PRAGMA journal_mode=WAL')

                    # หา ports ทั้งหมดจาก inbounds ที่ enable
                    ib_ports = []
                    try:
                        rows = con.execute("SELECT port FROM inbounds WHERE enable=1").fetchall()
                        ib_ports = [str(r[0]) for r in rows]
                    except: pass

                    # เช็ค connections บน xray ports เหล่านั้น
                    has_conn = False
                    if ib_ports:
                        port_pattern = '|'.join(':'+p+'$' for p in ib_ports)
                        _, ss_out, _ = run_cmd(
                            f"ss -tn state established 2>/dev/null | awk '{{print $4}}' | grep -cE '({port_pattern})' || echo 0"
                        )
                        try:
                            has_conn = int(ss_out.strip().split()[0]) > 0
                        except: pass

                    # ถ้ามี connection — ดึง email จาก client_traffics ที่มี last_online ล่าสุด
                    if has_conn:
                        for tbl in ('client_traffics', 'xray_client_traffics'):
                            try:
                                # ใช้ last_online ถ้ามี ไม่งั้นใช้ up+down > 0
                                cols = [r[1] for r in con.execute(f"PRAGMA table_info({tbl})").fetchall()]
                                if 'last_online' in cols:
                                    cutoff = int(__import__('time').time() * 1000) - 300000  # 5 นาที
                                    rows = con.execute(
                                        f"SELECT email FROM {tbl} WHERE last_online > ?", (cutoff,)
                                    ).fetchall()
                                else:
                                    rows = con.execute(
                                        f"SELECT email FROM {tbl} WHERE (up > 0 OR down > 0)"
                                    ).fetchall()
                                for row in rows:
                                    if row[0] and row[0] not in emails:
                                        emails.append(row[0])
                                break
                            except: pass
                    con.close()
            except Exception as ex:
                pass
            respond(self, 200, {'ok': True, 'online': emails, 'count': len(emails)})
        elif self.path == '/api/banned':
            # ดึงรายการที่ถูก ban (IP เกิน limit)
            banned = get_banned_users()
            respond(self, 200, {'ok': True, 'banned': banned, 'count': len(banned)})

        elif self.path == '/api/info':
            xui_port = open('/etc/chaiya/xui-port.conf').read().strip() if os.path.exists('/etc/chaiya/xui-port.conf') else '2503'
            respond(self, 200, {
                'host': get_host(),
                'xui_port': int(xui_port),
                'dropbear_port': 143,
                'dropbear_port2': 109,
                'udpgw_port': 7300,
            })
        elif self.path == '/api/vless_users':
            import sqlite3 as _sq3, json as _json
            _xui_db = find_xui_db()
            if not os.path.exists(_xui_db):
                return respond(self, 200, {'ok': True, 'users': [], 'db_path': _xui_db, 'note': 'db not found'})
            try:
                con = _sq3.connect(_xui_db, timeout=10); con.execute('PRAGMA journal_mode=WAL')
                rows = con.execute(
                    "SELECT id, remark, port, protocol, settings, up, down, total, expiry_time, enable FROM inbounds"
                ).fetchall()
                # ดึง traffic จาก client_traffics — match ด้วย email อย่างเดียว (inbound_id ไม่ตรงกับ inbounds.id)
                ct_map = {}
                for tbl in ('client_traffics', 'xray_client_traffics'):
                    try:
                        ct_rows = con.execute(f"SELECT email, up, down FROM {tbl}").fetchall()
                        for ct_email, ct_up, ct_down in ct_rows:
                            ct_map[ct_email] = {'up': ct_up or 0, 'down': ct_down or 0}
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
                            ct = ct_map.get(email, {})
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
            # ใช้ stdin แทนการ embed password ใน shell — ป้องกัน injection
            subprocess.run('chpasswd', input=f'{user}:{passwd}\n', capture_output=True, text=True)
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
            if os.path.exists(find_xui_db()):
                try:
                    con = sqlite3.connect(find_xui_db(), timeout=10); con.execute('PRAGMA journal_mode=WAL')
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
            SCRIPT_URL = data.get('url', 'https://raw.githubusercontent.com/Chaiyakey99/chaiya-vpn/main/chaiya-setup-v8.sh').strip()
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
            if not os.path.exists(find_xui_db()):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(find_xui_db())
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
            if not os.path.exists(find_xui_db()):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(find_xui_db())
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
                    con2 = _sq3.connect(find_xui_db())
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
            if not os.path.exists(find_xui_db()):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(find_xui_db())
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
            if not os.path.exists(find_xui_db()):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(find_xui_db())
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
            if not os.path.exists(find_xui_db()):
                return respond(self, 404, {'error': 'xui db not found'})
            try:
                con = _sq3.connect(find_xui_db())
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
    print('[chaiya-ssh-api] Listening on 127.0.0.1:6789 (v8)')
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
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMxYTBhMmUgMCUsIzBmMGExZSA1NSUsIzBhMGEwZiAxMDAlKTtwYWRkaW5nOjI4cHggMjBweCAyMnB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tncm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiM0YTU1Njg7bWFyZ2luLXRvcDo0cHg7fQogIC5kbnV0e3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjUycHg7aGVpZ2h0OjUycHg7bWFyZ2luOjRweCBhdXRvIDRweDt9CiAgLmRudXQgc3Zne3RyYW5zZm9ybTpyb3RhdGUoLTkwZGVnKTt9CiAgLmRiZ3tmaWxsOm5vbmU7c3Ryb2tlOnJnYmEoMCwwLDAsMC4wNik7c3Ryb2tlLXdpZHRoOjQ7fQogIC5kdntmaWxsOm5vbmU7c3Ryb2tlLXdpZHRoOjQ7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAxcyBlYXNlO30KICAuZGN7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5wYntoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW47fQogIC5wZntoZWlnaHQ6MTAwJTtib3JkZXItcmFkaXVzOjJweDt0cmFuc2l0aW9uOndpZHRoIDFzIGVhc2U7fQogIC5wZi5wdXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1hYyksIzE2YTM0YSk7fQogIC5wZi5wZ3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1uZyksIzE2YTM0YSk7fQogIC5wZi5wb3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZmI5MjNjLCNmOTczMTYpO30KICAucGYucHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KTt9CiAgLnViZGd7ZGlzcGxheTpmbGV4O2dhcDo1cHg7ZmxleC13cmFwOndyYXA7bWFyZ2luLXRvcDo4cHg7fQogIC5iZGd7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjZweDtwYWRkaW5nOjNweCA4cHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAubmV0LXJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEycHg7bWFyZ2luLXRvcDoxMHB4O30KICAubml7ZmxleDoxO30KICAubmR7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tYWMpO21hcmdpbi1ib3R0b206M3B4O30KICAubnN7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjIwcHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5ucyBzcGFue2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5udHtmb250LXNpemU6MTJweDtjb2xvcjojNGE1NTY4O21hcmdpbi10b3A6MnB4O30KICAuZGl2aWRlcnt3aWR0aDoxcHg7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpO21hcmdpbjo0cHggMDt9CiAgLm9waWxse2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMyk7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6NXB4IDE0cHg7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbmcpO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo1cHg7d2hpdGUtc3BhY2U6bm93cmFwO30KICAub3BpbGwub2Zme2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4zKTtjb2xvcjojZWY0NDQ0O30KICAuZG90e3dpZHRoOjVweDtoZWlnaHQ6NXB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6dmFyKC0tbmcpO2JveC1zaGFkb3c6MCAwIDVweCB2YXIoLS1uZyksMCAwIDEwcHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgMnMgaW5maW5pdGU7fQogIC5kb3QucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA1cHggI2VmNDQ0NCwwIDAgMTBweCAjZWY0NDQ0O2FuaW1hdGlvbjpwbHMtcmVkIDJzIGluZmluaXRlO30KICBAa2V5ZnJhbWVzIHBsc3swJSwxMDAle29wYWNpdHk6MC45O3RyYW5zZm9ybTpzY2FsZSgxKTtib3gtc2hhZG93OjAgMCAzcHggdmFyKC0tbmcpfTUwJXtvcGFjaXR5OjAuNjt0cmFuc2Zvcm06c2NhbGUoMS4xNSk7Ym94LXNoYWRvdzowIDAgNnB4IHZhcigtLW5nKX01NSUsMTAwJXtvcGFjaXR5OjAuMjt0cmFuc2Zvcm06c2NhbGUoMC44NSk7Ym94LXNoYWRvdzpub25lfX0KICAueHVpLXJvd3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLnh1aS1pbmZve2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtsaW5lLWhlaWdodDoxLjc7fQogIC54dWktaW5mbyBie2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtbGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4O30KICAuc3Zje2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4wNSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjExcHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO30KICAuc3ZjLmRvd257YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjA1KTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4yKTt9CiAgLnN2Yy1se2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7fQogIC5kZ3t3aWR0aDo2cHg7aGVpZ2h0OjZweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCA0cHggdmFyKC0tbmcpO2ZsZXgtc2hyaW5rOjA7YW5pbWF0aW9uOnBscyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTt9CiAgLmRnLnJlZHtiYWNrZ3JvdW5kOiNlZjQ0NDQ7Ym94LXNoYWRvdzowIDAgNHB4ICNlZjQ0NDQ7YW5pbWF0aW9uOnBscy1yZWQgM3MgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQogIC5kZy5vcmFuZ2V7YmFja2dyb3VuZDojZjk3MzE2O2JveC1zaGFkb3c6MCAwIDhweCAjZjk3MzE2LDAgMCAxNnB4ICNmOTczMTY7YW5pbWF0aW9uOnBscy1vcmFuZ2UgMXMgaW5maW5pdGU7fQogIEBrZXlmcmFtZXMgcGxzLW9yYW5nZXswJSw0NSV7b3BhY2l0eToxO3RyYW5zZm9ybTpzY2FsZSgxLjMpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMjQ5LDExNSwyMiwwLjM1KSwwIDAgMTJweCAjZjk3MzE2LDAgMCAyNHB4ICNmOTczMTZ9NTUlLDEwMCV7b3BhY2l0eTowLjI7dHJhbnNmb3JtOnNjYWxlKDAuODUpO2JveC1zaGFkb3c6bm9uZX19CiAgLnJiZGcud2FybntiYWNrZ3JvdW5kOnJnYmEoMjQ5LDExNSwyMiwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNDksMTE1LDIyLDAuMyk7Y29sb3I6I2Y5NzMxNjt9CiAgQGtleWZyYW1lcyBwbHMtcmVkezAlLDEwMCV7b3BhY2l0eTowLjk7dHJhbnNmb3JtOnNjYWxlKDEpO2JveC1zaGFkb3c6MCAwIDNweCAjZWY0NDQ0fTUwJXtvcGFjaXR5OjAuNTt0cmFuc2Zvcm06c2NhbGUoMS4xKTtib3gtc2hhZG93OjAgMCA1cHggI2VmNDQ0NH01NSUsMTAwJXtvcGFjaXR5OjAuMjt0cmFuc2Zvcm06c2NhbGUoMC44NSk7Ym94LXNoYWRvdzpub25lfX0KICAuc3ZjLW57Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtcHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtjb2xvcjojNGE1NTY4O30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiM0YTU1Njg7bWFyZ2luLXRvcDoycHg7fQogIC5hYmRne2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5hYmRnLm9re2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4zKTtjb2xvcjp2YXIoLS1uZyk7fQogIC5hYmRnLmV4cHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmFiZGcuc29vbntiYWNrZ3JvdW5kOnJnYmEoMjUxLDE0Niw2MCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTEsMTQ2LDYwLC4zKTtjb2xvcjojZjk3MzE2O30KICAubW92ZXJ7cG9zaXRpb246Zml4ZWQ7aW5zZXQ6MDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjUpO2JhY2tkcm9wLWZpbHRlcjpibHVyKDZweCk7ei1pbmRleDoxMDA7ZGlzcGxheTpub25lO2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5tb3Zlci5vcGVue2Rpc3BsYXk6ZmxleDt9CiAgLm1vZGFse2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoyMHB4IDIwcHggMCAwO3dpZHRoOjEwMCU7bWF4LXdpZHRoOjQ4MHB4O3BhZGRpbmc6MjBweDttYXgtaGVpZ2h0Ojg1dmg7b3ZlcmZsb3cteTphdXRvO2FuaW1hdGlvbjpzdSAuM3MgZWFzZTtib3gtc2hhZG93OjAgLTRweCAzMHB4IHJnYmEoMCwwLDAsMC4xMik7fQogIEBrZXlmcmFtZXMgc3V7ZnJvbXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgxMDAlKX10b3t0cmFuc2Zvcm06dHJhbnNsYXRlWSgwKX19CiAgLm1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjE2cHg7fQogIC5tdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm1jbG9zZXt3aWR0aDozMnB4O2hlaWdodDozMnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6I2YxZjVmOTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxNnB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLmRncmlke2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi1ib3R0b206MTRweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcntkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6N3B4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRyOmxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRvbTpub25lO30KICAuZGt7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuZHZ7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tdHh0KTtmb250LXdlaWdodDo2MDA7fQogIC5kdi5ncmVlbntjb2xvcjp2YXIoLS1uZyk7fQogIC5kdi5yZWR7Y29sb3I6I2VmNDQ0NDt9CiAgLmR2Lm1vbm97Y29sb3I6dmFyKC0tYWMpO2ZvbnQtc2l6ZTo5cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7fQogIC5hZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDt9CiAgLm0tc3Vie2Rpc3BsYXk6bm9uZTttYXJnaW4tdG9wOjE0cHg7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNHB4O30KICAubS1zdWIub3BlbntkaXNwbGF5OmJsb2NrO2FuaW1hdGlvbjpmaSAuMnMgZWFzZTt9CiAgLm1zdWItbGJse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLmFidG57YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4IDEwcHg7dGV4dC1hbGlnbjpjZW50ZXI7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjJzO30KICAuYWJ0bjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLmFidG4gLmFpe2ZvbnQtc2l6ZToyMnB4O21hcmdpbi1ib3R0b206NnB4O30KICAuYWJ0biAuYW57Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5hYnRuIC5hZHtmb250LXNpemU6MTJweDtjb2xvcjojMzc0MTUxO2ZvbnQtd2VpZ2h0OjUwMDttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5yZXMtY2xvc2V7cG9zaXRpb246YWJzb2x1dGU7dG9wOi0xMXB4O3JpZ2h0Oi0xMXB4O3dpZHRoOjIycHg7aGVpZ2h0OjIycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2JvcmRlcjoycHggc29saWQgI2ZmZjtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bGluZS1oZWlnaHQ6MTtib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDIzOSw2OCw2OCwwLjQpO3otaW5kZXg6Mjt9CiAgLnJlcy1ib3h7cG9zaXRpb246cmVsYXRpdmU7YmFja2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi10b3A6MTRweDtkaXNwbGF5Om5vbmU7fQogIC5yZXMtYm94LnNob3d7ZGlzcGxheTpibG9jazt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuNjUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuNik7fQogIC5waWNrLW9wdC5hLWR0YWN7Ym9yZGVyLWNvbG9yOiNmZjY2MDA7YmFja2dyb3VuZDpyZ2JhKDI1NSwxMDIsMCwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDI1NSwxMDIsMCwuMTUpO30KICAucGljay1vcHQuYS1kdGFjIC5wbntjb2xvcjojZmY4ODMzO30KICAucGljay1vcHQuYS10cnVle2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdiYSgwLDIwMCwyNTUsLjEpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtdHJ1ZSAucG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtbnB2e2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdiYSgwLDIwMCwyNTUsLjA4KTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMCwyMDAsMjU1LC4xMik7fQogIC5waWNrLW9wdC5hLW5wdiAucG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtZGFya3tib3JkZXItY29sb3I6I2NjNjZmZjtiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgxNTMsNTEsMjU1LC4xKTt9CiAgLnBpY2stb3B0LmEtZGFyayAucG57Y29sb3I6I2NjNjZmZjt9CiAgLyogQ3JlYXRlIGJ0biAoc3NoIGRhcmspICovCiAgLmNidG4tc3Noe2JhY2tncm91bmQ6dHJhbnNwYXJlbnQ7Ym9yZGVyOjJweCBzb2xpZCAjMjJjNTVlO2NvbG9yOiMyMmM1NWU7Zm9udC1zaXplOjEzcHg7d2lkdGg6YXV0bztwYWRkaW5nOjEwcHggMjhweDtib3JkZXItcmFkaXVzOjEwcHg7Y3Vyc29yOnBvaW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4ycztkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAuY2J0bi1zc2g6aG92ZXJ7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMSk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDM0LDE5Nyw5NCwuMik7fQogIC8qIExpbmsgcmVzdWx0ICovCiAgLmxpbmstcmVzdWx0e2Rpc3BsYXk6bm9uZTttYXJnaW4tdG9wOjEycHg7Ym9yZGVyLXJhZGl1czoxMHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLmxpbmstcmVzdWx0LnNob3d7ZGlzcGxheTpibG9jazt9CiAgLmxpbmstcmVzdWx0LWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7cGFkZGluZzo4cHggMTJweDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjMpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjA2KTt9CiAgLmltcC1iYWRnZXtmb250LXNpemU6LjYycmVtO2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzoxLjVweDtwYWRkaW5nOi4xOHJlbSAuNTVyZW07Ym9yZGVyLXJhZGl1czo5OXB4O30KICAuaW1wLWJhZGdlLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4xNSk7Y29sb3I6IzAwY2NmZjtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMCwxODAsMjU1LC4zKTt9CiAgLmltcC1iYWRnZS5kYXJre2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4xNSk7Y29sb3I6I2NjNjZmZjtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTUzLDUxLDI1NSwuMyk7fQogIC5saW5rLXByZXZpZXd7YmFja2dyb3VuZDojMDYwYTEyO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtc2l6ZTouNTZyZW07Y29sb3I6IzAwYWFkZDt3b3JkLWJyZWFrOmJyZWFrLWFsbDtsaW5lLWhlaWdodDoxLjY7bWFyZ2luOjhweCAxMnB4O2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE1MCwyNTUsLjE1KTttYXgtaGVpZ2h0OjU0cHg7b3ZlcmZsb3c6aGlkZGVuO3Bvc2l0aW9uOnJlbGF0aXZlO30KICAubGluay1wcmV2aWV3LmRhcmstbHB7Ym9yZGVyLWNvbG9yOnJnYmEoMTUzLDUxLDI1NSwuMjIpO2NvbG9yOiNhYTU1ZmY7fQogIC5saW5rLXByZXZpZXc6OmFmdGVye2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7Ym90dG9tOjA7bGVmdDowO3JpZ2h0OjA7aGVpZ2h0OjE0cHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQodHJhbnNwYXJlbnQsIzA2MGExMik7fQogIC5jb3B5LWxpbmstYnRue3dpZHRoOmNhbGMoMTAwJSAtIDI0cHgpO21hcmdpbjowIDEycHggMTBweDtwYWRkaW5nOi41NXJlbTtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6LjgycmVtO2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtib3JkZXI6MXB4IHNvbGlkO30KICAuY29weS1saW5rLWJ0bi5ucHZ7YmFja2dyb3VuZDpyZ2JhKDAsMTgwLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDAsMTgwLDI1NSwuMjgpO2NvbG9yOiMwMGNjZmY7fQogIC5jb3B5LWxpbmstYnRuLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjA3KTtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yOCk7Y29sb3I6I2NjNjZmZjt9CiAgLyogVXNlciB0YWJsZSAqLwogIC51dGJsLXdyYXB7b3ZlcmZsb3cteDphdXRvO21hcmdpbi10b3A6MTBweDt9CiAgLnV0Ymx7d2lkdGg6MTAwJTtib3JkZXItY29sbGFwc2U6Y29sbGFwc2U7Zm9udC1zaXplOjEycHg7fQogIC51dGJsIHRoe3BhZGRpbmc6OHB4IDEwcHg7dGV4dC1hbGlnbjpsZWZ0O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6MS41cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC51dGJsIHRke3BhZGRpbmc6OXB4IDEwcHg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdHI6bGFzdC1jaGlsZCB0ZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5iZGd7cGFkZGluZzoycHggOHB4O2JvcmRlci1yYWRpdXM6MjBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXdlaWdodDo3MDA7fQogIC5iZGctZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4zKTtjb2xvcjojMjJjNTVlO30KICAuYmRnLXJ7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmJ0bi10Ymx7d2lkdGg6MzBweDtoZWlnaHQ6MzBweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2N1cnNvcjpwb2ludGVyO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1zaXplOjE0cHg7fQogIC5idG4tdGJsOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC8qIFJlbmV3IGRheXMgYmFkZ2UgKi8KICAuZGF5cy1iYWRnZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtwYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjA4KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4yKTtjb2xvcjp2YXIoLS1hYyk7fQoKICAvKiDilIDilIAgU0VMRUNUT1IgQ0FSRFMg4pSA4pSAICovICAvKiDilIDilIAgU0VMRUNUT1IgQ0FSRFMg4pSA4pSAICovCiAgLnNlYy1sYWJlbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzo2cHggMnB4IDEwcHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlO30KICAuc2VsLWNhcmR7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxNnB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjE0cHg7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjJzO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5zZWwtY2FyZDpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWMpO2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgycHgpO30KICAuc2VsLWxvZ297d2lkdGg6NjRweDtoZWlnaHQ6NjRweDtib3JkZXItcmFkaXVzOjE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlze2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3Noe2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1haXMtc20sLnNlbC10cnVlLXNtLC5zZWwtc3NoLXNte3dpZHRoOjQ0cHg7aGVpZ2h0OjQ0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmbGV4LXNocmluazowO30KICAuc2VsLWFpcy1zbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCAjYzVlODlhO30KICAuc2VsLXRydWUtc217YmFja2dyb3VuZDojYzgwNDBkO30KICAuc2VsLXNzaC1zbXtiYWNrZ3JvdW5kOiMxNTY1YzA7fQogIC5zZWwtaW5mb3tmbGV4OjE7bWluLXdpZHRoOjA7fQogIC5zZWwtbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6LjgycmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNlbC1uYW1lLmFpc3tjb2xvcjojM2Q3YTBlO30KICAuc2VsLW5hbWUudHJ1ZXtjb2xvcjojYzgwNDBkO30KICAuc2VsLW5hbWUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5zZWwtc3Vie2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiMzNzQxNTE7Zm9udC13ZWlnaHQ6NTAwO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTJweDtjb2xvcjojNGE1NTY4O30KICAuY2J0bi1haXN7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMzZDdhMGUsIzVhYWExOCk7fQogIC5jYnRuLXRydWV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNhNjAwMGMsI2Q4MTAyMCk7fQogIC8qIEJhbiBjb3VudGRvd24gKi8KICBAa2V5ZnJhbWVzIHB1bHNlLW9yYW5nZSB7CiAgICAwJSwxMDAle2JveC1zaGFkb3c6MCAwIDRweCByZ2JhKDI0OSwxMTUsMjIsLjMpfQogICAgNTAle2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgyNDksMTE1LDIyLC42KX0KICB9CiAgI2Jhbm5lZC1saXN0IC51aXRlbSB7IGN1cnNvcjpkZWZhdWx0OyB9CiAgI2Jhbm5lZC1saXN0IC51aXRlbTpob3ZlciB7IGJvcmRlci1jb2xvcjpyZ2JhKDI0OSwxMTUsMjIsMC40KTtiYWNrZ3JvdW5kOnJnYmEoMjQ5LDExNSwyMiwwLjA0KTsgfQo8L3N0eWxlPgo8c2NyaXB0IHNyYz0iaHR0cHM6Ly9jZG5qcy5jbG91ZGZsYXJlLmNvbS9hamF4L2xpYnMvcXJjb2RlanMvMS4wLjAvcXJjb2RlLm1pbi5qcyI+PC9zY3JpcHQ+CjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9IndyYXAiPgoKICA8IS0tIEhFQURFUiAtLT4KICA8ZGl2IGNsYXNzPSJoZHIiPgogICAgPGJ1dHRvbiBjbGFzcz0ibG9nb3V0IiBvbmNsaWNrPSJkb0xvZ291dCgpIj7ihqkg4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4LiaPC9idXR0b24+CiAgICA8ZGl2IGNsYXNzPSJoZHItc3ViIj5DSEFJWUEgVjJSQVkgUFJPIE1BWDwvZGl2PgogICAgPGRpdiBjbGFzcz0iaGRyLXRpdGxlIj5VU0VSIDxzcGFuPkNSRUFUT1I8L3NwYW4+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJoZHItZGVzYyIgaWQ9Imhkci1kb21haW4iPnY1IMK3IFNFQ1VSRSBQQU5FTDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIE5BViAtLT4KICA8ZGl2IGNsYXNzPSJuYXYiPgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gYWN0aXZlIiBvbmNsaWNrPSJzdygnZGFzaGJvYXJkJyx0aGlzKSI+8J+TiiDguYHguJTguIrguJrguK3guKPguYzguJQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnY3JlYXRlJyx0aGlzKSI+4p6VIOC4quC4o+C5ieC4suC4h+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdtYW5hZ2UnLHRoaXMpIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdvbmxpbmUnLHRoaXMpIj7wn5+iIOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdiYW4nLHRoaXMpIj7wn5qrIOC4m+C4peC4lOC5geC4muC4mTwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCd1cGRhdGUnLHRoaXMpIj7irIbvuI8g4Lit4Lix4Lie4LmA4LiU4LiVPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIgaWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFuIGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7imqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9udC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGltZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJvdyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3guKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAgICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklDRSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2ltZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgtQUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlzLm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWlnaHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdTIMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBXUyDCtyB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KCiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCIgc3R5bGU9Im1hcmdpbi10b3A6MjBweCI+8J+UkSDguKPguLDguJrguJogU1NIIFdFQlNPQ0tFVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3NzaCcpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtc3NoIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6I2ZmZjtmb250LWZhbWlseTptb25vc3BhY2UiPlNTSCZndDs8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgc3NoIj5TU0gg4oCTIFdTIFR1bm5lbDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+U1NIIMK3IFBvcnQgODAgwrcgRHJvcGJlYXIgMTQzLzEwOTxicj5OcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IEFJUyDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLWFpcyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgYWlzLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWxvZ28gc2VsLWFpcy1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouOHJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgU05JOiBjai1lYmIuc3BlZWR0ZXN0Lm5ldDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckBhaXMiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLWFpcyIgaWQ9ImFpcy1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCdhaXMnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0iYWlzLXJlc3VsdCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+PGJ1dHRvbiBjbGFzcz0icmVzLWNsb3NlIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLWFpcy1lbWFpbCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfhpQgVVVJRDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgbW9ubyIgaWQ9InItYWlzLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLWFpcy1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLWFpcy1saW5rIj4tLTwvZGl2PgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY29weS1idG4iIG9uY2xpY2s9ImNvcHlMaW5rKCdyLWFpcy1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9ImFpcy1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFRSVUUg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS10cnVlIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0iZm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciB0cnVlLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtdHJ1ZS1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouNzVyZW07Zm9udC13ZWlnaHQ6OTAwO2NvbG9yOiNmZmYiPnRydWU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXRpdGxlIHRydWUiPlRSVUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXN1YiI+VkxFU1MgwrcgUG9ydCA4ODgwIMK3IFNOSTogdHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlczwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1lbWFpbCIgcGxhY2Vob2xkZXI9InVzZXJAdHJ1ZSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtaXAiIHR5cGU9Im51bWJlciIgdmFsdWU9IjIiIG1pbj0iMSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkr4gRGF0YSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIGNidG4tdHJ1ZSIgaWQ9InRydWUtYnRuIiBvbmNsaWNrPSJjcmVhdGVWTEVTUygndHJ1ZScpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIFRSVUUgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0idHJ1ZS1hbGVydCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLWJveCIgaWQ9InRydWUtcmVzdWx0IiBzdHlsZT0iZGlzcGxheTpub25lIj48YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0cnVlLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXRydWUtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLXRydWUtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItdHJ1ZS1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLXRydWUtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci10cnVlLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0idHJ1ZS1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFNTSCDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXNzaCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3NoLWRhcmstZm9ybSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPuKelSDguYDguJ7guLTguYjguKEgU1NIIFVTRVI8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgdHlwZT0icGFzc3dvcmQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKXguLTguKHguLTguJXguYTguK3guJ7guLU8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij7inIjvuI8g4LmA4Lil4Li34Lit4LiBIFBPUlQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwb3J0LWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4gYWN0aXZlLXA4MCIgaWQ9InBiLTgwIiBvbmNsaWNrPSJwaWNrUG9ydCgnODAnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCfjJA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA4MDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1zdWIiPldTIMK3IEhUVFA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4iIGlkPSJwYi00NDMiIG9uY2xpY2s9InBpY2tQb3J0KCc0NDMnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCflJI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA0NDM8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XU1MgwrcgU1NMPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPvCfjJAg4LmA4Lil4Li34Lit4LiBIElTUCAvIE9QRVJBVE9SPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtZHRhYyIgaWQ9InByby1kdGFjIiBvbmNsaWNrPSJwaWNrUHJvKCdkdGFjJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+8J+foDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RFRBQyBHQU1JTkc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJwcm8tdHJ1ZSIgb25jbGljaz0icGlja1BybygndHJ1ZScpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCflLU8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPlRSVUUgVFdJVFRFUjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+aGVscC54LmNvbTwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn5OxIOC5gOC4peC4t+C4reC4gSBBUFA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQgYS1ucHYiIGlkPSJhcHAtbnB2IiBvbmNsaWNrPSJwaWNrQXBwKCducHYnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMwZDJhM2E7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6Ljg1cmVtO2NvbG9yOiMwMGNjZmY7bGV0dGVyLXNwYWNpbmc6LTFweDtib3JkZXI6MS41cHggc29saWQgcmdiYSgwLDIwNCwyNTUsLjMpIj5uVjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+TnB2IFR1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+bnB2dC1zc2g6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJhcHAtZGFyayIgb25jbGljaz0icGlja0FwcCgnZGFyaycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPjxkaXYgc3R5bGU9IndpZHRoOjM4cHg7aGVpZ2h0OjM4cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6IzExMTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bWFyZ2luOjAgYXV0byAuMXJlbTtmb250LWZhbWlseTpzYW5zLXNlcmlmO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6LjYycmVtO2NvbG9yOiNmZmY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3JkZXI6MS41cHggc29saWQgIzQ0NCI+REFSSzwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RGFya1R1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+ZGFya3R1bm5lbDovLzwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4tc3NoIiBpZD0ic3NoLWJ0biIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKelSDguKrguKPguYnguLLguIcgVXNlcjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsaW5rLXJlc3VsdCIgaWQ9InNzaC1saW5rLXJlc3VsdCI+PC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBVc2VyIHRhYmxlIC0tPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIiBzdHlsZT0ibWFyZ2luOjAiPvCfk4sg4Lij4Liy4Lii4LiK4Li34LmI4LitIFVTRVJTPC9kaXY+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJzc2gtc2VhcmNoIiBwbGFjZWhvbGRlcj0i4LiE4LmJ4LiZ4Lir4LiyLi4uIiBvbmlucHV0PSJmaWx0ZXJTU0hVc2Vycyh0aGlzLnZhbHVlKSIKICAgICAgICAgICAgc3R5bGU9IndpZHRoOjEyMHB4O21hcmdpbjowO2ZvbnQtc2l6ZToxMXB4O3BhZGRpbmc6NnB4IDEwcHgiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InV0Ymwtd3JhcCI+CiAgICAgICAgICA8dGFibGUgY2xhc3M9InV0YmwiPgogICAgICAgICAgICA8dGhlYWQ+PHRyPjx0aD4jPC90aD48dGg+VVNFUk5BTUU8L3RoPjx0aD7guKvguKHguJTguK3guLLguKLguLg8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BQ1RJT048L3RoPjwvdHI+PC90aGVhZD4KICAgICAgICAgICAgPHRib2R5IGlkPSJzc2gtdXNlci10Ym9keSI+PHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9yOnZhcigtLW11dGVkKSI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwvdGJvZHk+CiAgICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICA8L2Rpdj48IS0tIC90YWItY3JlYXRlIC0tPgoKPCEtLSDilZDilZDilZDilZAgTUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICAKICAgICAgPGRpdiBpZD0idXNlci1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguJvguLjguYjguKHguYLguKvguKXguJTguYDguJ7guLfguYjguK3guJTguLbguIfguILguYnguK3guKHguLnguKU8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1vbmxpbmUiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+8J+foiDguKLguLnguKrguYDguIvguK3guKPguYzguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZE9ubGluZSgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvY3IiPgogICAgICAgIDxkaXYgY2xhc3M9Im9waWxsIiBpZD0ib25saW5lLXBpbGwiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj48c3BhbiBpZD0ib25saW5lLWNvdW50Ij4wPC9zcGFuPiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0idXQiIGlkPSJvbmxpbmUtdGltZSI+LS08L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtdmxlc3Mtc2VjdGlvbiIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO3BhZGRpbmc6OHB4IDAgNnB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTsiPvCfk6EgVkxFU1MgT25saW5lPC9kaXY+CiAgICAgICAgPGRpdiBpZD0ib25saW5lLXZsZXNzLWxpc3QiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0ib25saW5lLXNzaC1zZWN0aW9uIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzo4cHggMCA2cHg7dGV4dC10cmFuc2Zvcm06dXBwZXJjYXNlOyI+8J+UkSBTU0ggT25saW5lPC9kaXY+CiAgICAgICAgPGRpdiBpZD0ib25saW5lLXNzaC1saXN0Ij48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS1lbXB0eSIgc3R5bGU9ImRpc3BsYXk6bm9uZSIgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+YtDwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4teC4ouC4ueC4quC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvcD48L2Rpdj4KICAgICAgPGRpdiBpZD0ib25saW5lLWxvYWRpbmciPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4o+C4teC5gOC4n+C4o+C4iuC5gOC4nuC4t+C5iOC4reC4lOC4ueC4nOC4ueC5ieC5g+C4iuC5ieC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIEJBTiAvIFVOQkFOIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItYmFuIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiPvCfmqsg4Lib4Lil4LiU4Lil4LmH4Lit4LiEIElQIEJhbjwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4O2xpbmUtaGVpZ2h0OjEuNjsiPgogICAgICAgIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4l+C4teC5iOC5g+C4iuC5iSBJUCDguYDguIHguLTguJkgTGltaXQg4LiI4Liw4LiW4Li54LiB4Lil4LmH4Lit4LiE4LiK4Lix4LmI4Lin4LiE4Lij4Liy4LinIDEg4LiK4Lix4LmI4Lin4LmC4Lih4LiHPGJyPgogICAgICAgIOC4geC4o+C4reC4gSBVc2VybmFtZSDguYDguJ7guLfguYjguK3guJvguKXguJTguKXguYfguK3guITguJfguLHguJnguJfguLUKICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIFVTRVJOQU1FIOC4l+C4teC5iOC4luC4ueC4geC5geC4muC4mTwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJiYW4tdXNlciIgcGxhY2Vob2xkZXI9IuC4geC4o+C4reC4gSB1c2VybmFtZSDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguJvguKXguJTguKXguYfguK3guIQiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNiNDUzMDksI2Q5NzcwNikiIG9uY2xpY2s9InVuYmFuVXNlcigpIj7wn5STIOC4m+C4peC4lOC4peC5h+C4reC4hCBJUCBCYW48L2J1dHRvbj4KICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJiYW4tYWxlcnQiPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDo0cHgiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPuKPse+4jyDguKPguLLguKLguIHguLLguKPguJfguLXguYjguJbguLnguIHguYHguJrguJnguK3guKLguLnguYg8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZEJhbm5lZFVzZXJzKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9ImJhbm5lZC1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKPC9kaXY+PCEtLSAvd3JhcCAtLT4KCjwhLS0g4pWQ4pWQ4pWQ4pWQIFVQREFURSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLXVwZGF0ZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7irIbvuI8g4Lit4Lix4Lie4LmA4LiU4LiVIFNjcmlwdDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTRweCI+CiAgICAgICAg4LiB4LiU4Lib4Li44LmI4Lih4LiU4LmJ4Liy4LiZ4Lil4LmI4Liy4LiH4LmA4Lie4Li34LmI4Lit4LiU4Li24LiHIHNjcmlwdCDguYPguKvguKHguYjguIjguLLguIEgR2l0SHViIOC5geC4peC5ieC4p+C4o+C4seC4meC4reC4seC4leC5guC4meC4oeC4seC4leC4tOC4muC4mSBzZXJ2ZXI8YnI+CiAgICAgICAgUHJvZ3Jlc3Mg4LmB4Lil4LiwIExvZyDguIjguLDguYHguKrguJTguIfguYHguJrguJogcmVhbC10aW1lIOC4lOC5ieC4suC4meC4peC5iOC4suC4hwogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPgogICAgICAgIDxkaXYgY2xhc3M9ImZsYmwiPvCflJcgU2NyaXB0IFVSTDwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ1cGRhdGUtdXJsIiB2YWx1ZT0iaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL0NoYWl5YWtleTk5L2NoYWl5YS12cG4vbWFpbi9jaGFpeWEtc2V0dXAtdjUtY29tYmluZWQuc2giPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjEycHgiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJ1cGRhdGUtYnRuIiBvbmNsaWNrPSJzdGFydFVwZGF0ZSgpIiBzdHlsZT0iZmxleDoxIj7irIbvuI8g4LmA4Lij4Li04LmI4LihIFVwZGF0ZTwvYnV0dG9uPgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJjbGVhclVwZGF0ZUxvZygpIj7wn5eRIOC4peC5ieC4suC4hyBMb2c8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9InVwZGF0ZS1zdGF0dXMiIHN0eWxlPSJkaXNwbGF5Om5vbmU7bWFyZ2luLWJvdHRvbToxMHB4Ij48L2Rpdj4KICAgICAgPCEtLSBQcm9ncmVzcyBiYXIgLS0+CiAgICAgIDxkaXYgaWQ9InVwZGF0ZS1wcm9ncmVzcy13cmFwIiBzdHlsZT0iZGlzcGxheTpub25lO21hcmdpbi1ib3R0b206MTBweCI+CiAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206NHB4IiBpZD0idXBkYXRlLXByb2dyZXNzLWxhYmVsIj7guIHguLPguKXguLHguIfguJfguLPguIfguLLguJkuLi48L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJoZWlnaHQ6NnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMDcpO2JvcmRlci1yYWRpdXM6M3B4O292ZXJmbG93OmhpZGRlbiI+CiAgICAgICAgICA8ZGl2IGlkPSJ1cGRhdGUtcHJvZ3Jlc3MtYmFyIiBzdHlsZT0iaGVpZ2h0OjEwMCU7d2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdmFyKC0tYWMpLCM0YWRlODApO2JvcmRlci1yYWRpdXM6M3B4O3RyYW5zaXRpb246d2lkdGggLjVzIGVhc2UiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPCEtLSBMb2cgYm94IC0tPgogICAgICA8ZGl2IGlkPSJ1cGRhdGUtbG9nIiBzdHlsZT0iYmFja2dyb3VuZDojMGQxMTE3O2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHg7Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2NvbG9yOiM1OGQ2OGQ7bGluZS1oZWlnaHQ6MS43O21heC1oZWlnaHQ6MzYwcHg7b3ZlcmZsb3cteTphdXRvO2Rpc3BsYXk6bm9uZTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoODgsMjE0LDE0MSwuMTUpO3doaXRlLXNwYWNlOnByZS13cmFwO3dvcmQtYnJlYWs6YnJlYWstYWxsIj48L2Rpdj4KCiAgICAgIDwhLS0gSW50ZXJhY3RpdmUgaW5wdXQgLS0+CiAgICAgIDxkaXYgaWQ9InVwZGF0ZS1pbnB1dC13cmFwIiBzdHlsZT0iZGlzcGxheTpub25lO21hcmdpbi10b3A6MTBweDtiYWNrZ3JvdW5kOiMwZDExMTc7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxOTEsMzYsLjQpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHgiPgogICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMXB4O2NvbG9yOiNmYmJmMjQ7bWFyZ2luLWJvdHRvbTo4cHg7Zm9udC1mYW1pbHk6bW9ub3NwYWNlIj7ijKjvuI8gPHNwYW4gaWQ9InVwZGF0ZS1pbnB1dC1sYWJlbCI+U2NyaXB0IOC4geC4s+C4peC4seC4h+C4o+C4rSBpbnB1dC4uLjwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjZweCI+CiAgICAgICAgICA8aW5wdXQgaWQ9InVwZGF0ZS1pbnB1dC1ib3giIHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLguJ7guLTguKHguJ7guYzguYHguKXguYnguKfguIHguJQgRW50ZXIg4Lir4Lij4Li34LitIFNlbmQiIHN0eWxlPSJmbGV4OjE7YmFja2dyb3VuZDojMGEwZTE0O2JvcmRlcjoxcHggc29saWQgcmdiYSg4OCwyMTQsMTQxLC4zKTtjb2xvcjojZThmNGZmO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEycHg7Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtc2l6ZToxMnB4O291dGxpbmU6bm9uZSIgb25rZXlkb3duPSJpZihldmVudC5rZXk9PT0nRW50ZXInKXNlbmRVcGRhdGVJbnB1dCgpIj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJ3aWR0aDphdXRvO3BhZGRpbmc6OHB4IDE4cHg7Zm9udC1zaXplOjEycHgiIG9uY2xpY2s9InNlbmRVcGRhdGVJbnB1dCgpIj5TZW5kPC9idXR0b24+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgc3R5bGU9InBhZGRpbmc6OHB4IDEycHg7Zm9udC1zaXplOjEycHgiIG9uY2xpY2s9InNlbmRVcGRhdGVJbnB1dCgnJykiIHRpdGxlPSLguKrguYjguIfguITguYjguLLguKfguYjguLLguIcgKEVudGVyIOC5gOC4m+C4peC5iOC4sikiPuKGtTwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKPCEtLSBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJtb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbSgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIiBpZD0ibXQiPuKame+4jyB1c2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY20oKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6EgUG9ydDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkcCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9ImRlIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TpiBEYXRhIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TiiBUcmFmZmljIOC5g+C4iuC5iTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdHIiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OxIElQIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRpIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBtb25vIiBpZD0iZHV1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTBweCI+4LmA4Lil4Li34Lit4LiB4LiB4Liy4Lij4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3JlbmV3JykiPjxkaXYgY2xhc3M9ImFpIj7wn5SEPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignZXh0ZW5kJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OFPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignYWRkZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+8J+TpjwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guYDguJ7guLTguYjguKEgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4LihPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3NldGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPuKalu+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguLHguYnguIcgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guIHguLPguKvguJnguJTguYPguKvguKHguYg8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVzZXQnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIM8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4gZGFuZ2VyIiBvbmNsaWNrPSJtQWN0aW9uKCdkZWxldGUnKSI+PGRpdiBjbGFzcz0iYWkiPvCfl5HvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lil4Lia4Lii4Li54LiqPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4peC4muC4luC4suC4p+C4ozwvZGl2PjwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC5iOC4reC4reC4suC4ouC4uCAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZW5ldyI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCDigJQg4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVuZXctYnRuIiBvbmNsaWNrPSJkb1JlbmV3VXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWV4dGVuZCI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OFIOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSDigJQg4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1leHRlbmQtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWV4dGVuZC1idG4iIG9uY2xpY2s9ImRvRXh0ZW5kVXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4LihIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItYWRkZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OmIOC5gOC4nuC4tOC5iOC4oSBEYXRhIOKAlCDguYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4Lih4LiI4Liy4LiB4LiX4Li14LmI4Lih4Li14Lit4Lii4Li54LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJkgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tYWRkZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMTAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWFkZGRhdGEtYnRuIiBvbmNsaWNrPSJkb0FkZERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oSBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4Lix4LmJ4LiHIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItc2V0ZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7impbvuI8g4LiV4Lix4LmJ4LiHIERhdGEg4oCUIOC4geC4s+C4q+C4meC4lCBMaW1pdCDguYPguKvguKHguYggKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj5EYXRhIExpbWl0IChHQikg4oCUIDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1zZXRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1zZXRkYXRhLWJ0biIgb25jbGljaz0iZG9TZXREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguLHguYnguIcgRGF0YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlc2V0Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIMg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4oCUIOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5ieC4l+C4seC5ieC4h+C4q+C4oeC4lDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guIHguLLguKPguKPguLXguYDguIvguJUgVHJhZmZpYyDguIjguLDguYDguITguKXguLXguKLguKPguYzguKLguK3guJQgVXBsb2FkL0Rvd25sb2FkIOC4l+C4seC5ieC4h+C4q+C4oeC4lOC4guC4reC4h+C4ouC4ueC4quC4meC4teC5iTwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZXNldC1idG4iIG9uY2xpY2s9ImRvUmVzZXRUcmFmZmljKCkiPuKchSDguKLguLfguJnguKLguLHguJnguKPguLXguYDguIvguJUgVHJhZmZpYzwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4peC4muC4ouC4ueC4qiAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1kZWxldGUiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPvCfl5HvuI8g4Lil4Lia4Lii4Li54LiqIOKAlCDguKXguJrguJbguLLguKfguKMg4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LiB4Li54LmJ4LiE4Li34LiZ4LmE4LiU4LmJPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4ouC4ueC4qiA8YiBpZD0ibS1kZWwtbmFtZSIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPjwvYj4g4LiI4Liw4LiW4Li54LiB4Lil4Lia4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4Lia4LiW4Liy4Lin4LijPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWRlbGV0ZS1idG4iIG9uY2xpY2s9ImRvRGVsZXRlVXNlcigpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNkYzI2MjYsI2VmNDQ0NCkiPvCfl5HvuI8g4Lii4Li34LiZ4Lii4Lix4LiZ4Lil4Lia4Lii4Li54LiqPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9Im1vZGFsLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIiBvbmVycm9yPSJ3aW5kb3cuQ0hBSVlBX0NPTkZJRz17fSI+PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8vIOKVkOKVkOKVkOKVkCBDT05GSUcg4pWQ4pWQ4pWQ4pWQCmNvbnN0IENGRyA9ICh0eXBlb2Ygd2luZG93LkNIQUlZQV9DT05GSUcgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdy5DSEFJWUFfQ09ORklHIDoge307CmNvbnN0IEhPU1QgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKY29uc3QgWFVJICA9ICcveHVpLWFwaSc7CmNvbnN0IEFQSSAgPSAnL2FwaSc7CmNvbnN0IFNFU1NJT05fS0VZID0gJ2NoYWl5YV9hdXRoJzsKCi8vIFNlc3Npb24gY2hlY2sKY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwppZiAoIV9zLnVzZXIgfHwgIV9zLnBhc3MgfHwgRGF0ZS5ub3coKSA+PSAoX3MuZXhwfHwwKSkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8gSGVhZGVyIGRvbWFpbgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLWRvbWFpbicpLnRleHRDb250ZW50ID0gSE9TVCArICcgwrcgdjUnOwoKLy8g4pWQ4pWQ4pWQ4pWQIFVUSUxTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBmbXRCeXRlcyhiKSB7CiAgaWYgKCFiIHx8IGIgPT09IDApIHJldHVybiAnMCBCJzsKICBjb25zdCBrID0gMTAyNCwgdSA9IFsnQicsJ0tCJywnTUInLCdHQicsJ1RCJ107CiAgY29uc3QgaSA9IE1hdGguZmxvb3IoTWF0aC5sb2coYikvTWF0aC5sb2coaykpOwogIHJldHVybiAoYi9NYXRoLnBvdyhrLGkpKS50b0ZpeGVkKDEpKycgJyt1W2ldOwp9CmZ1bmN0aW9uIGZtdERhdGUobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgY29uc3QgZCA9IG5ldyBEYXRlKG1zKTsKICByZXR1cm4gZC50b0xvY2FsZURhdGVTdHJpbmcoJ3RoLVRIJyx7eWVhcjonbnVtZXJpYycsbW9udGg6J3Nob3J0JyxkYXk6J251bWVyaWMnfSk7Cn0KZnVuY3Rpb24gZGF5c0xlZnQobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gbnVsbDsKICByZXR1cm4gTWF0aC5jZWlsKChtcyAtIERhdGUubm93KCkpIC8gODY0MDAwMDApOwp9CmZ1bmN0aW9uIHNldFJpbmcoaWQsIHBjdCkgewogIGNvbnN0IGNpcmMgPSAxMzguMjsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoZWwpIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBjaXJjIC0gKGNpcmMgKiBNYXRoLm1pbihwY3QsMTAwKSAvIDEwMCk7Cn0KZnVuY3Rpb24gc2V0QmFyKGlkLCBwY3QsIHdhcm49ZmFsc2UpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuc3R5bGUud2lkdGggPSBNYXRoLm1pbihwY3QsMTAwKSArICclJzsKICBpZiAod2FybiAmJiBwY3QgPiA4NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KSc7CiAgZWxzZSBpZiAod2FybiAmJiBwY3QgPiA2NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2Y5NzMxNiwjZmI5MjNjKSc7Cn0KZnVuY3Rpb24gc2hvd0FsZXJ0KGlkLCBtc2csIHR5cGUpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcrdHlwZTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBpZiAodHlwZSA9PT0gJ29rJykgc2V0VGltZW91dCgoKT0+e2VsLnN0eWxlLmRpc3BsYXk9J25vbmUnO30sIDMwMDApOwp9CgovLyDilZDilZDilZDilZAgTkFWIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBzdyhuYW1lLCBlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZWMnKS5mb3JFYWNoKHM9PnMuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobj0+bi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nK25hbWUpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChuYW1lPT09J2NyZWF0ZScpIGNsb3NlRm9ybSgpOwogIGlmIChuYW1lPT09J2Rhc2hib2FyZCcpIGxvYWREYXNoKCk7CiAgaWYgKG5hbWU9PT0nbWFuYWdlJykgbG9hZFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0nb25saW5lJykgbG9hZE9ubGluZSgpOwogIGlmIChuYW1lPT09J2JhbicpIGxvYWRCYW5uZWRVc2VycygpOwogIGlmIChuYW1lPT09J3VwZGF0ZScpIHsgLyogbm8gYXV0by1sb2FkICovIH0KfQoKLy8g4pSA4pSAIEZvcm0gbmF2IOKUgOKUgApsZXQgX2N1ckZvcm0gPSBudWxsOwpmdW5jdGlvbiBvcGVuRm9ybShpZCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9IGY9PT1pZCA/ICdibG9jaycgOiAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBpZDsKICBpZiAoaWQ9PT0nc3NoJykgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgd2luZG93LnNjcm9sbFRvKDAsMCk7Cn0KZnVuY3Rpb24gY2xvc2VGb3JtKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIFsnYWlzJywndHJ1ZScsJ3NzaCddLmZvckVhY2goZiA9PiB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9ybS0nK2YpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBudWxsOwp9CgpsZXQgX3dzUG9ydCA9ICc4MCc7CmZ1bmN0aW9uIHRvZ1BvcnQoYnRuLCBwb3J0KSB7CiAgX3dzUG9ydCA9IHBvcnQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzODAtYnRuJykuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgcG9ydD09PSc4MCcpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd3czQ0My1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzQ0MycpOwp9CmZ1bmN0aW9uIHRvZ0dyb3VwKGJ0biwgY2xzKSB7CiAgYnRuLmNsb3Nlc3QoJ2RpdicpLnF1ZXJ5U2VsZWN0b3JBbGwoY2xzKS5mb3JFYWNoKGI9PmIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGJ0bi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIFhVSSBMT0dJTiAoY29va2llKSDilZDilZDilZDilZAKbGV0IF94dWlPayA9IGZhbHNlOwphc3luYyBmdW5jdGlvbiB4dWlMb2dpbigpIHsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyLCBwYXNzd29yZDogX3MucGFzcyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aU9rID0gISFkLnN1Y2Nlc3M7CiAgcmV0dXJuIF94dWlPazsKfQphc3luYyBmdW5jdGlvbiB4dWlHZXQocGF0aCkgewogIGlmICghX3h1aU9rKSBhd2FpdCB4dWlMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIC8vIEF1dG8gcmUtbG9naW4g4LiW4LmJ4LiyIHNlc3Npb24g4Lir4Lih4LiUICg0MDEvNDAzL3JlZGlyZWN0IHRvIGxvZ2luKQogIGlmIChyLnN0YXR1cyA9PT0gNDAxIHx8IHIuc3RhdHVzID09PSA0MDMgfHwgci51cmwuaW5jbHVkZXMoJy9sb2dpbicpKSB7CiAgICBfeHVpT2sgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUxvZ2luKCk7CiAgICBjb25zdCByMiA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7CiAgICByZXR1cm4gcjIuanNvbigpOwogIH0KICByZXR1cm4gci5qc29uKCk7Cn0KYXN5bmMgZnVuY3Rpb24geHVpUG9zdChwYXRoLCBib2R5KSB7CiAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgYm9keTogSlNPTi5zdHJpbmdpZnkoYm9keSkKICB9KTsKICAvLyBBdXRvIHJlLWxvZ2luIOC4luC5ieC4siBzZXNzaW9uIOC4q+C4oeC4lAogIGlmIChyLnN0YXR1cyA9PT0gNDAxIHx8IHIuc3RhdHVzID09PSA0MDMgfHwgci51cmwuaW5jbHVkZXMoJy9sb2dpbicpKSB7CiAgICBfeHVpT2sgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUxvZ2luKCk7CiAgICBjb25zdCByMiA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgICAgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoYm9keSkKICAgIH0pOwogICAgcmV0dXJuIHIyLmpzb24oKTsKICB9CiAgcmV0dXJuIHIuanNvbigpOwp9CgovLyDilZDilZDilZDilZAgREFTSEJPQVJEIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkRGFzaCgpIHsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLXJlZnJlc2gnKTsKICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IC4uLic7CiAgX3h1aU9rID0gZmFsc2U7IC8vIGZvcmNlIHJlLWxvZ2luIOC5gOC4quC4oeC4rQoKICB0cnkgewogICAgLy8gU1NIIEFQSSBzdGF0dXMKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgcmVuZGVyU2VydmljZXMoc3QgPyAoc3Quc2VydmljZXMgfHwge30pIDogbnVsbCk7CgogICAgLy8gWFVJIHNlcnZlciBzdGF0dXMKICAgIGNvbnN0IG9rID0gYXdhaXQgeHVpTG9naW4oKTsKICAgIGlmICghb2spIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+TG9naW4g4LmE4Lih4LmI4LmE4LiU4LmJJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0gJ29waWxsIG9mZic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHN2ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL3NlcnZlci9zdGF0dXMnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3YgJiYgc3Yuc3VjY2VzcyAmJiBzdi5vYmopIHsKICAgICAgY29uc3QgbyA9IHN2Lm9iajsKICAgICAgLy8gQ1BVCiAgICAgIGNvbnN0IGNwdSA9IE1hdGgucm91bmQoby5jcHUgfHwgMCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtcGN0JykudGV4dENvbnRlbnQgPSBjcHUgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtY29yZXMnKS50ZXh0Q29udGVudCA9IChvLmNwdUNvcmVzIHx8IG8ubG9naWNhbFBybyB8fCAnLS0nKSArICcgY29yZXMnOwogICAgICBzZXRSaW5nKCdjcHUtcmluZycsIGNwdSk7IHNldEJhcignY3B1LWJhcicsIGNwdSwgdHJ1ZSk7CgogICAgICAvLyBSQU0KICAgICAgY29uc3QgcmFtVCA9ICgoby5tZW0/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgcmFtVSA9ICgoby5tZW0/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCByYW1QID0gcmFtVCA+IDAgPyBNYXRoLnJvdW5kKHJhbVUvcmFtVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1wY3QnKS50ZXh0Q29udGVudCA9IHJhbVAgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tZGV0YWlsJykudGV4dENvbnRlbnQgPSByYW1VLnRvRml4ZWQoMSkrJyAvICcrcmFtVC50b0ZpeGVkKDEpKycgR0InOwogICAgICBzZXRSaW5nKCdyYW0tcmluZycsIHJhbVApOyBzZXRCYXIoJ3JhbS1iYXInLCByYW1QLCB0cnVlKTsKCiAgICAgIC8vIERpc2sKICAgICAgY29uc3QgZHNrVCA9ICgoby5kaXNrPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIGRza1UgPSAoKG8uZGlzaz8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IGRza1AgPSBkc2tUID4gMCA/IE1hdGgucm91bmQoZHNrVS9kc2tUKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1wY3QnKS5pbm5lckhUTUwgPSBkc2tQICsgJzxzcGFuPiU8L3NwYW4+JzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stZGV0YWlsJykudGV4dENvbnRlbnQgPSBkc2tVLnRvRml4ZWQoMCkrJyAvICcrZHNrVC50b0ZpeGVkKDApKycgR0InOwogICAgICBzZXRCYXIoJ2Rpc2stYmFyJywgZHNrUCwgdHJ1ZSk7CgogICAgICAvLyBVcHRpbWUKICAgICAgY29uc3QgdXAgPSBvLnVwdGltZSB8fCAwOwogICAgICBjb25zdCB1ZCA9IE1hdGguZmxvb3IodXAvODY0MDApLCB1aCA9IE1hdGguZmxvb3IoKHVwJTg2NDAwKS8zNjAwKSwgdW0gPSBNYXRoLmZsb29yKCh1cCUzNjAwKS82MCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtdmFsJykudGV4dENvbnRlbnQgPSB1ZCA+IDAgPyB1ZCsnZCAnK3VoKydoJyA6IHVoKydoICcrdW0rJ20nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXN1YicpLnRleHRDb250ZW50ID0gdWQrJ+C4p+C4seC4mSAnK3VoKyfguIrguKEuICcrdW0rJ+C4meC4suC4l+C4tSc7CiAgICAgIGNvbnN0IGxvYWRzID0gby5sb2FkcyB8fCBbXTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvYWQtY2hpcHMnKS5pbm5lckhUTUwgPSBsb2Fkcy5tYXAoKGwsaSk9PgogICAgICAgIGA8c3BhbiBjbGFzcz0iYmRnIj4ke1snMW0nLCc1bScsJzE1bSddW2ldfTogJHtsLnRvRml4ZWQoMil9PC9zcGFuPmApLmpvaW4oJycpOwoKICAgICAgLy8gTmV0d29yawogICAgICBpZiAoby5uZXRJTykgewogICAgICAgIGNvbnN0IHVwX2IgPSBvLm5ldElPLnVwfHwwLCBkbl9iID0gby5uZXRJTy5kb3dufHwwOwogICAgICAgIGNvbnN0IHVwRm10ID0gZm10Qnl0ZXModXBfYiksIGRuRm10ID0gZm10Qnl0ZXMoZG5fYik7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cCcpLmlubmVySFRNTCA9IHVwRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4nKS5pbm5lckhUTUwgPSBkbkZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgfQogICAgICBpZiAoby5uZXRUcmFmZmljKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cC10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5zZW50fHwwKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnJlY3Z8fDApOwogICAgICB9CgogICAgICAvLyBYVUkgdmVyc2lvbgogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXZlcicpLnRleHRDb250ZW50ID0gby54cmF5VmVyc2lvbiB8fCAnLS0nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPuC4reC4reC4meC5hOC4peC4meC5jCc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCc7CiAgICB9CgogICAgLy8gSW5ib3VuZHMgY291bnQKICAgIGNvbnN0IGlibCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKGlibCAmJiBpYmwuc3VjY2VzcykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLWluYm91bmRzJykudGV4dENvbnRlbnQgPSAoaWJsLm9ianx8W10pLmxlbmd0aDsKICAgIH0KCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbGFzdC11cGRhdGUnKS50ZXh0Q29udGVudCA9ICfguK3guLHguJ7guYDguJTguJfguKXguYjguLLguKrguLjguJQ6ICcgKyBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnNvbGUuZXJyb3IoZSk7CiAgfSBmaW5hbGx5IHsKICAgIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsg4Lij4Li14LmA4Lif4Lij4LiKJzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTRVJWSUNFUyDilZDilZDilZDilZAKY29uc3QgU1ZDX0RFRiA9IFsKICB7IGtleToneHVpJywgICAgICBpY29uOifwn5OhJywgbmFtZToneC11aSBQYW5lbCcsICAgICAgcG9ydDonOjIwNTMnIH0sCiAgeyBrZXk6J3NzaCcsICAgICAgaWNvbjon8J+QjScsIG5hbWU6J1NTSCBBUEknLCAgICAgICAgICBwb3J0Oic6Njc4OScgfSwKICB7IGtleTonZHJvcGJlYXInLCBpY29uOifwn5C7JywgbmFtZTonRHJvcGJlYXIgU1NIJywgICAgIHBvcnQ6JzoxNDMgOjEwOScgfSwKICB7IGtleTonbmdpbngnLCAgICBpY29uOifwn4yQJywgbmFtZTonbmdpbnggLyBQYW5lbCcsICAgIHBvcnQ6Jzo4MCA6NDQzJyB9LAogIHsga2V5Oidzc2h3cycsICAgIGljb246J/CflJInLCBuYW1lOidXUy1TdHVubmVsJywgICAgICAgcG9ydDonOjgw4oaSOjE0MycgfSwKICB7IGtleTonYmFkdnBuJywgICBpY29uOifwn46uJywgbmFtZTonQmFkVlBOIFVEUEdXJywgICAgIHBvcnQ6Jzo3MzAwJyB9LApdOwpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcyhtYXApIHsKICBjb25zdCB0cyA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcse2hvdXI6JzItZGlnaXQnLG1pbnV0ZTonMi1kaWdpdCcsc2Vjb25kOicyLWRpZ2l0J30pOwogIGNvbnN0IGlzVW5rbm93biA9ICFtYXA7CiAgaWYgKCFtYXApIG1hcCA9IHt9OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtbGlzdCcpLmlubmVySFRNTCA9IFNWQ19ERUYubWFwKHMgPT4gewogICAgY29uc3QgdXAgPSBtYXBbcy5rZXldID09PSB0cnVlIHx8IG1hcFtzLmtleV0gPT09ICdhY3RpdmUnOwogICAgY29uc3QgdW5rbm93biA9IGlzVW5rbm93bjsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0ic3ZjICR7dW5rbm93bj8nJzonJ30keyghdW5rbm93biYmIXVwKT8nZG93bic6Jyd9Ij4KICAgICAgPGRpdiBjbGFzcz0ic3ZjLWwiPjxzcGFuIGNsYXNzPSJkZyAke3Vua25vd24/J29yYW5nZSc6dXA/Jyc6J3JlZCd9Ij48L3NwYW4+PHNwYW4+JHtzLmljb259PC9zcGFuPgogICAgICAgIDxkaXY+PGRpdiBjbGFzcz0ic3ZjLW4iPiR7cy5uYW1lfTwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj4ke3MucG9ydH08L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJyYmRnICR7dW5rbm93bj8nd2Fybic6dXA/Jyc6J2Rvd24nfSI+JHt1bmtub3duPycuLi4nOnVwPydSVU5OSU5HJzonRE9XTid9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKSArIGA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOnJpZ2h0O2ZvbnQtc2l6ZTo5cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO3BhZGRpbmctdG9wOjZweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoxcHgiPkxJVkUgwrcgJHt0c308L2Rpdj5gOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRTZXJ2aWNlcygpIHsKICB0cnkgewogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXM/dD0nK0RhdGUubm93KCksIHtjYWNoZTonbm8tc3RvcmUnfSkudGhlbihyPT5yLmpzb24oKSk7CiAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgfSBjYXRjaChlKSB7CiAgICByZW5kZXJTZXJ2aWNlcyhudWxsKTsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggUElDS0VSIFNUQVRFIOKVkOKVkOKVkOKVkApjb25zdCBQUk9TID0gewogIGR0YWM6IHsKICAgIG5hbWU6ICdEVEFDIEdBTUlORycsCiAgICBwcm94eTogJzEwNC4xOC42My4xMjQ6ODAnLAogICAgcGF5bG9hZDogJ0NPTk5FQ1QgLyAgSFRUUC8xLjEgW2NybGZdSG9zdDogZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbSBbY3JsZl1bY3JsZl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDpbaG9zdF1bY3JsZl1VcGdyYWRlOlVzZXItQWdlbnQ6IFt1YV1bY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfSwKICB0cnVlOiB7CiAgICBuYW1lOiAnVFJVRSBUV0lUVEVSJywKICAgIHByb3h5OiAnMTA0LjE4LjM5LjI0OjgwJywKICAgIHBheWxvYWQ6ICdQT1NUIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OmhlbHAueC5jb21bY3JsZl1Vc2VyLUFnZW50OiBbdWFdW2NybGZdW2NybGZdW3NwbGl0XVtjcl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDogW2hvc3RdW2NybGZdVXBncmFkZTogd2Vic29ja2V0W2NybGZdQ29ubmVjdGlvbjpVcGdyYWRlW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0KfTsKY29uc3QgTlBWX0hPU1QgPSAnd3d3LnByb2plY3QuZ29kdnBuLnNob3AnLCBOUFZfUE9SVCA9IDgwOwpsZXQgX3NzaFBybyA9ICdkdGFjJywgX3NzaEFwcCA9ICducHYnLCBfc3NoUG9ydCA9ICc4MCc7CgpmdW5jdGlvbiBwaWNrUG9ydChwKSB7CiAgX3NzaFBvcnQgPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi04MCcpLmNsYXNzTmFtZSAgPSAncG9ydC1idG4nICsgKHA9PT0nODAnICA/ICcgYWN0aXZlLXA4MCcgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi00NDMnKS5jbGFzc05hbWUgPSAncG9ydC1idG4nICsgKHA9PT0nNDQzJyA/ICcgYWN0aXZlLXA0NDMnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tQcm8ocCkgewogIF9zc2hQcm8gPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tZHRhYycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSdkdGFjJyA/ICcgYS1kdGFjJyA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLXRydWUnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0ndHJ1ZScgPyAnIGEtdHJ1ZScgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja0FwcChhKSB7CiAgX3NzaEFwcCA9IGE7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcC1ucHYnKS5jbGFzc05hbWUgID0gJ3BpY2stb3B0JyArIChhPT09J25wdicgID8gJyBhLW5wdicgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtZGFyaycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAoYT09PSdkYXJrJyA/ICcgYS1kYXJrJyA6ICcnKTsKfQpmdW5jdGlvbiBidWlsZE5wdkxpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgaiA9IHsKICAgIHNzaENvbmZpZ1R5cGU6J1NTSC1Qcm94eS1QYXlsb2FkJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6TlBWX0hPU1QsIHNzaFBvcnQ6TlBWX1BPUlQsCiAgICBzc2hVc2VybmFtZTpuYW1lLCBzc2hQYXNzd29yZDpwYXNzLAogICAgc25pOicnLCB0bHNWZXJzaW9uOidERUZBVUxUJywKICAgIGh0dHBQcm94eTpwcm8ucHJveHksIGF1dGhlbnRpY2F0ZVByb3h5OmZhbHNlLAogICAgcHJveHlVc2VybmFtZTonJywgcHJveHlQYXNzd29yZDonJywKICAgIHBheWxvYWQ6cHJvLnBheWxvYWQsCiAgICBkbnNNb2RlOidVRFAnLCBkbnNTZXJ2ZXI6JycsIG5hbWVzZXJ2ZXI6JycsIHB1YmxpY0tleTonJywKICAgIHVkcGd3UG9ydDo3MzAwLCB1ZHBnd1RyYW5zcGFyZW50RE5TOnRydWUKICB9OwogIHJldHVybiAnbnB2dC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KZnVuY3Rpb24gYnVpbGREYXJrTGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBwcCA9IChwcm8ucHJveHl8fCcnKS5zcGxpdCgnOicpOwogIGNvbnN0IGRoID0gcHBbMF0gfHwgcHJvLmRhcmtQcm94eTsKICBjb25zdCBqID0gewogICAgY29uZmlnVHlwZTonU1NILVBST1hZJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6SE9TVCwgc3NoUG9ydDoxNDMsCiAgICBzc2hVc2VyOm5hbWUsIHNzaFBhc3M6cGFzcywKICAgIHBheWxvYWQ6J0dFVCAvIEhUVFAvMS4xXHJcbkhvc3Q6ICcrSE9TVCsnXHJcblVwZ3JhZGU6IHdlYnNvY2tldFxyXG5Db25uZWN0aW9uOiBVcGdyYWRlXHJcblxyXG4nLAogICAgcHJveHlIb3N0OmRoLCBwcm94eVBvcnQ6ODAsCiAgICB1ZHBnd0FkZHI6JzEyNy4wLjAuMScsIHVkcGd3UG9ydDo3MzAwLCB0bHNFbmFibGVkOmZhbHNlCiAgfTsKICByZXR1cm4gJ2Rhcmt0dW5uZWwtc3NoOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CgovLyDilZDilZDilZDilZAgQ1JFQVRFIFNTSCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1kYXlzJykudmFsdWUpfHwzMDsKICBjb25zdCBpcGwgID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpID8gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpLnZhbHVlIDogMil8fDI7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIXBhc3MpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBQYXNzd29yZCcsJ2VycicpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMzQsMTk3LDk0LC4zKTtib3JkZXItdG9wLWNvbG9yOiMyMmM1NWUiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBjb25zdCByZXNFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtbGluay1yZXN1bHQnKTsKICBpZiAocmVzRWwpIHJlc0VsLmNsYXNzTmFtZT0nbGluay1yZXN1bHQnOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvY3JlYXRlX3NzaCcsIHsKICAgICAgbWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoe3VzZXIsIHBhc3N3b3JkOnBhc3MsIGRheXMsIGlwX2xpbWl0OmlwbH0pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0IHBybyAgPSBQUk9TW19zc2hQcm9dIHx8IFBST1MuZHRhYzsKICAgIGNvbnN0IGxpbmsgPSBfc3NoQXBwPT09J25wdicgPyBidWlsZE5wdkxpbmsodXNlcixwYXNzLHBybykgOiBidWlsZERhcmtMaW5rKHVzZXIscGFzcyxwcm8pOwogICAgY29uc3QgaXNOcHYgPSBfc3NoQXBwPT09J25wdic7CiAgICBjb25zdCBscENscyA9IGlzTnB2ID8gJycgOiAnIGRhcmstbHAnOwogICAgY29uc3QgY0NscyAgPSBpc05wdiA/ICducHYnIDogJ2RhcmsnOwogICAgY29uc3QgYXBwTGFiZWwgPSBpc05wdiA/ICdOcHZ0JyA6ICdEYXJrVHVubmVsJzsKCiAgICBpZiAocmVzRWwpIHsKICAgICAgcmVzRWwuY2xhc3NOYW1lID0gJ2xpbmstcmVzdWx0IHNob3cnOwogICAgICBjb25zdCBzYWZlTGluayA9IGxpbmsucmVwbGFjZSgvXFwvZywnXFxcXCcpLnJlcGxhY2UoLycvZywiXFwnIik7CiAgICAgIHJlc0VsLmlubmVySFRNTCA9CiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcmVzdWx0LWhkcic+IiArCiAgICAgICAgICAiPHNwYW4gY2xhc3M9J2ltcC1iYWRnZSAiK2NDbHMrIic+IithcHBMYWJlbCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOnZhcigtLW11dGVkKSc+Iitwcm8ubmFtZSsiIFx4YjcgUG9ydCAiK19zc2hQb3J0KyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6IzIyYzU1ZTttYXJnaW4tbGVmdDphdXRvJz5cdTI3MDUgIit1c2VyKyI8L3NwYW4+IiArCiAgICAgICAgIjwvZGl2PiIgKwogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXByZXZpZXciK2xwQ2xzKyInPiIrbGluaysiPC9kaXY+IiArCiAgICAgICAgIjxidXR0b24gY2xhc3M9J2NvcHktbGluay1idG4gIitjQ2xzKyInIGlkPSdjb3B5LXNzaC1idG4nIG9uY2xpY2s9XCJjb3B5U1NITGluaygpXCI+IisKICAgICAgICAgICJcdWQ4M2RcdWRjY2IgQ29weSAiK2FwcExhYmVsKyIgTGluayIrCiAgICAgICAgIjwvYnV0dG9uPiI7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExpbmsgPSBsaW5rOwogICAgICB3aW5kb3cuX2xhc3RTU0hBcHAgID0gY0NsczsKICAgICAgd2luZG93Ll9sYXN0U1NITGFiZWwgPSBhcHBMYWJlbDsKICAgIH0KCiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIIMK3IOC4q+C4oeC4lOC4reC4suC4ouC4uCAnK2QuZXhwLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWU9Jyc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZT0nJzsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfinpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXInOyB9Cn0KZnVuY3Rpb24gY29weVNTSExpbmsoKSB7CiAgY29uc3QgbGluayA9IHdpbmRvdy5fbGFzdFNTSExpbmt8fCcnOwogIGNvbnN0IGNDbHMgPSB3aW5kb3cuX2xhc3RTU0hBcHB8fCducHYnOwogIGNvbnN0IGxhYmVsID0gd2luZG93Ll9sYXN0U1NITGFiZWx8fCdMaW5rJzsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dChsaW5rKS50aGVuKGZ1bmN0aW9uKCl7CiAgICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvcHktc3NoLWJ0bicpOwogICAgaWYoYil7IGIudGV4dENvbnRlbnQ9J1x1MjcwNSDguITguLHguJTguKXguK3guIHguYHguKXguYnguKchJzsgc2V0VGltZW91dChmdW5jdGlvbigpe2IudGV4dENvbnRlbnQ9J1x1ZDgzZFx1ZGNjYiBDb3B5ICcrbGFiZWwrJyBMaW5rJzt9LDIwMDApOyB9CiAgfSkuY2F0Y2goZnVuY3Rpb24oKXsgcHJvbXB0KCdDb3B5IGxpbms6JyxsaW5rKTsgfSk7Cn0KCi8vIFNTSCB1c2VyIHRhYmxlCmxldCBfc3NoVGFibGVVc2VycyA9IFtdOwphc3luYyBmdW5jdGlvbiBsb2FkU1NIVGFibGVJbkZvcm0oKSB7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgX3NzaFRhYmxlVXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICAgIGlmKHRiKSB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiNlZjQ0NDQ7cGFkZGluZzoxNnB4Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gU1NIIEFQSSDguYTguKHguYjguYTguJTguYk8L3RkPjwvdHI+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyU1NIVGFibGUodXNlcnMpIHsKICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogIGlmICghdGIpIHJldHVybjsKICBpZiAoIXVzZXJzLmxlbmd0aCkgewogICAgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzoyMHB4Ij7guYTguKHguYjguKHguLUgU1NIIHVzZXJzPC90ZD48L3RyPic7CiAgICByZXR1cm47CiAgfQogIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICB0Yi5pbm5lckhUTUwgPSB1c2Vycy5tYXAoZnVuY3Rpb24odSxpKXsKICAgIGNvbnN0IGV4cGlyZWQgPSB1LmV4cCAmJiB1LmV4cCA8IG5vdzsKICAgIGNvbnN0IGFjdGl2ZSAgPSB1LmFjdGl2ZSAhPT0gZmFsc2UgJiYgIWV4cGlyZWQ7CiAgICBjb25zdCBkTGVmdCAgID0gdS5leHAgPyBNYXRoLmNlaWwoKG5ldyBEYXRlKHUuZXhwKS1EYXRlLm5vdygpKS84NjQwMDAwMCkgOiBudWxsOwogICAgY29uc3QgYmFkZ2UgICA9IGFjdGl2ZQogICAgICA/ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1nIj5BQ1RJVkU8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1yIj5FWFBJUkVEPC9zcGFuPic7CiAgICBjb25zdCBkVGFnID0gZExlZnQhPT1udWxsCiAgICAgID8gJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj4nKyhkTGVmdD4wP2RMZWZ0KydkJzon4Lir4Lih4LiUJykrJzwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj5cdTIyMWU8L3NwYW4+JzsKICAgIHJldHVybiAnPHRyPjx0ZCBzdHlsZT0iY29sb3I6dmFyKC0tbXV0ZWQpIj4nKyhpKzEpKyc8L3RkPicgKwogICAgICAnPHRkPjxiPicrdS51c2VyKyc8L2I+PC90ZD4nICsKICAgICAgJzx0ZCBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6JysoZXhwaXJlZD8nI2VmNDQ0NCc6J3ZhcigtLW11dGVkKScpKyciPicrCiAgICAgICAgKHUuZXhwfHwn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJzwvdGQ+JyArCiAgICAgICc8dGQ+JytiYWRnZSsnPC90ZD4nICsKICAgICAgJzx0ZD48ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjRweDthbGlnbi1pdGVtczpjZW50ZXIiPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguJXguYjguK3guK3guLLguKLguLgiIG9uY2xpY2s9InJlbmV3U1NIVXNlcihcJycrdS51c2VyKydcJykiPvCflIQ8L2J1dHRvbj4nKwogICAgICAgICc8YnV0dG9uIGNsYXNzPSJidG4tdGJsIiB0aXRsZT0i4Lil4LiaIiBvbmNsaWNrPSJkZWxTU0hVc2VyKFwnJyt1LnVzZXIrJ1wnKSIgc3R5bGU9ImJvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwuMykiPvCfl5HvuI88L2J1dHRvbj4nKwogICAgICAgIGRUYWcrCiAgICAgICc8L2Rpdj48L3RkPjwvdHI+JzsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJTU0hVc2VycyhxKSB7CiAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMuZmlsdGVyKGZ1bmN0aW9uKHUpe3JldHVybiAodS51c2VyfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpO30pKTsKfQphc3luYyBmdW5jdGlvbiByZW5ld1NTSFVzZXIodXNlcikgewogIGNvbnN0IGRheXMgPSBwYXJzZUludChwcm9tcHQoJ+C4leC5iOC4reC4reC4suC4ouC4uCAnK3VzZXIrJyDguIHguLXguYjguKfguLHguJk/JywnMzAnKSk7CiAgaWYgKCFkYXlzfHxkYXlzPD0wKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9leHRlbmRfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcixkYXlzfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4LiV4LmI4Lit4Lit4Liy4Lii4Li4ICcrdXNlcisnICsnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBhbGVydCgnXHUyNzRjICcrZS5tZXNzYWdlKTsgfQp9CmFzeW5jIGZ1bmN0aW9uIGRlbFNTSFVzZXIodXNlcikgewogIGlmICghY29uZmlybSgn4Lil4LiaIFNTSCB1c2VyICInK3VzZXIrJyIg4LiW4Liy4Lin4LijPycpKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9kZWxldGVfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pCiAgICB9KS50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKTt9KTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKHIuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzA1IOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IGFsZXJ0KCdcdTI3NGMgJytlLm1lc3NhZ2UpOyB9Cn0KLy8g4pWQ4pWQ4pWQ4pWQIENSRUFURSBWTEVTUyDilZDilZDilZDilZAKZnVuY3Rpb24gZ2VuVVVJRCgpIHsKICByZXR1cm4gJ3h4eHh4eHh4LXh4eHgtNHh4eC15eHh4LXh4eHh4eHh4eHh4eCcucmVwbGFjZSgvW3h5XS9nLGM9PnsKICAgIGNvbnN0IHI9TWF0aC5yYW5kb20oKSoxNnwwOyByZXR1cm4gKGM9PT0neCc/cjoociYweDN8MHg4KSkudG9TdHJpbmcoMTYpOwogIH0pOwp9CmFzeW5jIGZ1bmN0aW9uIGNyZWF0ZVZMRVNTKGNhcnJpZXIpIHsKICBjb25zdCBlbWFpbEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWVtYWlsJyk7CiAgY29uc3QgZGF5c0VsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1kYXlzJyk7CiAgY29uc3QgaXBFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1pcCcpOwogIGNvbnN0IGdiRWwgICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZ2InKTsKICBjb25zdCBlbWFpbCAgID0gZW1haWxFbC52YWx1ZS50cmltKCk7CiAgY29uc3QgZGF5cyAgICA9IHBhcnNlSW50KGRheXNFbC52YWx1ZSl8fDMwOwogIGNvbnN0IGlwTGltaXQgPSBwYXJzZUludChpcEVsLnZhbHVlKXx8MjsKICBjb25zdCBnYiAgICAgID0gcGFyc2VJbnQoZ2JFbC52YWx1ZSl8fDA7CiAgaWYgKCFlbWFpbCkgcmV0dXJuIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggRW1haWwvVXNlcm5hbWUnLCdlcnInKTsKCiAgY29uc3QgcG9ydCA9IGNhcnJpZXI9PT0nYWlzJyA/IDgwODAgOiA4ODgwOwogIGNvbnN0IHNuaSAgPSBjYXJyaWVyPT09J2FpcycgPyAnY2otZWJiLnNwZWVkdGVzdC5uZXQnIDogJ3RydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXMnOwoKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYnRuJyk7CiAgYnRuLmRpc2FibGVkPXRydWU7IGJ0bi5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CgogIHRyeSB7CiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKICAgIC8vIOC4q+C4siBpbmJvdW5kIGlkCiAgICBjb25zdCBsaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliID0gKGxpc3Qub2JqfHxbXSkuZmluZCh4PT54LnBvcnQ9PT1wb3J0KTsKICAgIGlmICghaWIpIHRocm93IG5ldyBFcnJvcihg4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCAke3BvcnR9IOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZYCk7CgogICAgY29uc3QgdWlkID0gZ2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXMgPSBkYXlzID4gMCA/IChEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMCkgOiAwOwogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDp1aWQsIGZsb3c6JycsIGVtYWlsLCBsaW1pdElwOmlwTGltaXQsCiAgICAgICAgdG90YWxHQjp0b3RhbEJ5dGVzLCBleHBpcnlUaW1lOmV4cE1zLCBlbmFibGU6dHJ1ZSwgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgbGluayA9IGB2bGVzczovLyR7dWlkfUAke0hPU1R9OiR7cG9ydH0/dHlwZT13cyZzZWN1cml0eT1ub25lJnBhdGg9JTJGdmxlc3MmaG9zdD0ke3NuaX0jJHtlbmNvZGVVUklDb21wb25lbnQoKGNhcnJpZXI9PT0nYWlzJz8nQUlTLeC4geC4seC4meC4o+C4seC5iOC4pyc6J1RSVUUtVkRPJykrJy0nK2VtYWlsKX1gOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWVtYWlsJykudGV4dENvbnRlbnQgPSBlbWFpbDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLXV1aWQnKS50ZXh0Q29udGVudCA9IHVpZDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWV4cCcpLnRleHRDb250ZW50ID0gZXhwTXMgPiAwID8gZm10RGF0ZShleHBNcykgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWxpbmsnKS50ZXh0Q29udGVudCA9IGxpbms7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0Jykuc3R5bGUuZGlzcGxheT0nYmxvY2snOwogICAgY29uc3QgcXJEaXYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcXInKTsKICAgIGlmIChxckRpdikgeyBxckRpdi5pbm5lckhUTUwgPSAnJzsgdHJ5IHsgbmV3IFFSQ29kZShxckRpdiwgeyB0ZXh0OiBsaW5rLCB3aWR0aDogMTgwLCBoZWlnaHQ6IDE4MCwgY29ycmVjdExldmVsOiBRUkNvZGUuQ29ycmVjdExldmVsLk0gfSk7IH0gY2F0Y2gocXJFcnIpIHt9IH0KICAgIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHIFZMRVNTIEFjY291bnQg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGVtYWlsRWwudmFsdWU9Jyc7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4pqhIOC4quC4o+C5ieC4suC4hyAnKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSsnIEFjY291bnQnOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBNQU5BR0UgVVNFUlMg4pWQ4pWQ4pWQ4pWQCmxldCBfYWxsVXNlcnMgPSBbXSwgX2N1clVzZXIgPSBudWxsOwphc3luYyBmdW5jdGlvbiBsb2FkVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICAvLyDguJTguLbguIfguIjguLLguIEgU1NIIEFQSSDguJfguLXguYjguK3guYjguLLguJkgY2xpZW50X3RyYWZmaWNzIERCIOC5guC4lOC4ouC4leC4o+C4hyDigJQg4LmB4Lii4LiBIHRyYWZmaWMg4Lij4Liy4Lii4LiE4LiZ4LiW4Li54LiB4LiV4LmJ4Lit4LiHCiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvdmxlc3NfdXNlcnM/dD0nK0RhdGUubm93KCksIHtjYWNoZTonbm8tc3RvcmUnfSkudGhlbihyPT5yLmpzb24oKSk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcign4LmC4Lir4Lil4LiU4LmE4Lih4LmI4LmE4LiU4LmJJyk7CiAgICBfYWxsVXNlcnMgPSAoZC51c2Vyc3x8W10pLm1hcCh1ID0+ICh7CiAgICAgIGliSWQ6IHUuaW5ib3VuZElkLCBwb3J0OiB1LnBvcnQsIHByb3RvOiB1LnByb3RvY29sLAogICAgICBlbWFpbDogdS51c2VyLCB1dWlkOiB1LnV1aWQsCiAgICAgIGV4cDogdS5leHBpcnlUaW1lfHwwLCB0b3RhbDogdS50b3RhbEdCfHwwLAogICAgICB1cDogdS51cHx8MCwgZG93bjogdS5kb3dufHwwLCBsaW1pdElwOiB1LmxpbWl0SXB8fDAKICAgIH0pKTsKICAgIHJlbmRlclVzZXJzKF9hbGxVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyVXNlcnModXNlcnMpIHsKICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfk608L2Rpdj48cD7guYTguKHguYjguJ7guJrguKLguLnguKrguYDguIvguK3guKPguYw8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHUgPT4gewogICAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgICBsZXQgYmFkZ2UsIGNsczsKICAgIGlmICghdS5leHAgfHwgdS5leHA9PT0wKSB7IGJhZGdlPSfinJMg4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsgY2xzPSdvayc7IH0KICAgIGVsc2UgaWYgKGRsIDwgMCkgICAgICAgICB7IGJhZGdlPSfguKvguKHguJTguK3guLLguKLguLgnOyBjbHM9J2V4cCc7IH0KICAgIGVsc2UgaWYgKGRsIDw9IDMpICAgICAgICB7IGJhZGdlPSfimqAgJytkbCsnZCc7IGNscz0nc29vbic7IH0KICAgIGVsc2UgICAgICAgICAgICAgICAgICAgICB7IGJhZGdlPSfinJMgJytkbCsnZCc7IGNscz0nb2snOyB9CiAgICBjb25zdCBhdkNscyA9IGRsIDwgMCA/ICdhdi14JyA6ICdhdi1nJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIG9uY2xpY2s9Im9wZW5Vc2VyKCR7SlNPTi5zdHJpbmdpZnkodSkucmVwbGFjZSgvIi9nLCcmcXVvdDsnKX0pIj4KICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YXZDbHN9Ij4keyh1LmVtYWlsfHwnPycpWzBdLnRvVXBwZXJDYXNlKCl9PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS5lbWFpbH08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+UG9ydCAke3UucG9ydH0gwrcgJHtmbXRCeXRlcyh1LnVwK3UuZG93bil9IOC5g+C4iuC5iTwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHtjbHN9Ij4ke2JhZGdlfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsdGVyVXNlcnMocSkgewogIHJlbmRlclVzZXJzKF9hbGxVc2Vycy5maWx0ZXIodT0+KHUuZW1haWx8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSkpKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1PREFMIFVTRVIg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIG9wZW5Vc2VyKHUpIHsKICBpZiAodHlwZW9mIHUgPT09ICdzdHJpbmcnKSB1ID0gSlNPTi5wYXJzZSh1KTsKICBfY3VyVXNlciA9IHU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ210JykudGV4dENvbnRlbnQgPSAn4pqZ77iPICcrdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHUnKS50ZXh0Q29udGVudCA9IHUuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RwJykudGV4dENvbnRlbnQgPSB1LnBvcnQ7CiAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgY29uc3QgZXhwVHh0ID0gIXUuZXhwfHx1LmV4cD09PTAgPyAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJyA6IGZtdERhdGUodS5leHApOwogIGNvbnN0IGRlID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RlJyk7CiAgZGUudGV4dENvbnRlbnQgPSBleHBUeHQ7CiAgZGUuY2xhc3NOYW1lID0gJ2R2JyArIChkbCAhPT0gbnVsbCAmJiBkbCA8IDAgPyAnIHJlZCcgOiAnIGdyZWVuJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RkJykudGV4dENvbnRlbnQgPSB1LnRvdGFsID4gMCA/IGZtdEJ5dGVzKHUudG90YWwpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R0cicpLnRleHRDb250ZW50ID0gZm10Qnl0ZXModS51cCt1LmRvd24pOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaScpLnRleHRDb250ZW50ID0gdS5saW1pdElwIHx8ICfiiJ4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdXUnKS50ZXh0Q29udGVudCA9IHUudXVpZDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY20oKXsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7Cn0KCi8vIOKUgOKUgCBNT0RBTCA2LUFDVElPTiBTWVNURU0g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNvbnN0IF9tU3VicyA9IFsncmVuZXcnLCdleHRlbmQnLCdhZGRkYXRhJywnc2V0ZGF0YScsJ3Jlc2V0JywnZGVsZXRlJ107CmZ1bmN0aW9uIG1BY3Rpb24oa2V5KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2tleSk7CiAgY29uc3QgaXNPcGVuID0gZWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgaWYgKCFpc09wZW4pIHsKICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgIGlmIChrZXk9PT0nZGVsZXRlJyAmJiBfY3VyVXNlcikgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZGVsLW5hbWUnKS50ZXh0Q29udGVudCA9IF9jdXJVc2VyLmVtYWlsOwogICAgc2V0VGltZW91dCgoKT0+ZWwuc2Nyb2xsSW50b1ZpZXcoe2JlaGF2aW9yOidzbW9vdGgnLGJsb2NrOiduZWFyZXN0J30pLDEwMCk7CiAgfQp9CmZ1bmN0aW9uIF9tQnRuTG9hZChpZCwgbG9hZGluZywgb3JpZ1RleHQpIHsKICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghYikgcmV0dXJuOwogIGIuZGlzYWJsZWQgPSBsb2FkaW5nOwogIGlmIChsb2FkaW5nKSB7IGIuZGF0YXNldC5vcmlnID0gYi50ZXh0Q29udGVudDsgYi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj4g4LiB4Liz4Lil4Lix4LiH4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijLi4uJzsgfQogIGVsc2UgaWYgKGIuZGF0YXNldC5vcmlnKSBiLnRleHRDb250ZW50ID0gYi5kYXRhc2V0Lm9yaWc7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvUmVuZXdVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tcmVuZXctZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoZGF5cyA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iOC4s+C4meC4p+C4meC4p+C4seC4mScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1yZW5ldy1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgZXhwTXMgPSBEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpfY3VyVXNlci50b3RhbCxleHBpcnlUaW1lOmV4cE1zLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguJXguYjguK3guK3guLLguKLguLjguKrguLPguYDguKPguYfguIggJytkYXlzKycg4Lin4Lix4LiZICjguKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYkpJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVuZXctYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRXh0ZW5kVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWV4dGVuZC1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLWV4dGVuZC1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgYmFzZSA9IChfY3VyVXNlci5leHAgJiYgX2N1clVzZXIuZXhwID4gRGF0ZS5ub3coKSkgPyBfY3VyVXNlci5leHAgOiBEYXRlLm5vdygpOwogICAgY29uc3QgZXhwTXMgPSBiYXNlICsgZGF5cyo4NjQwMDAwMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpfY3VyVXNlci50b3RhbCxleHBpcnlUaW1lOmV4cE1zLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguYDguJ7guLTguYjguKEgJytkYXlzKycg4Lin4Lix4LiZIOC4quC4s+C5gOC4o+C5h+C4iCAo4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUKScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWV4dGVuZC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9BZGREYXRhKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBhZGRHYiA9IHBhcnNlRmxvYXQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tYWRkZGF0YS1nYicpLnZhbHVlKXx8MDsKICBpZiAoYWRkR2IgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIEgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLWFkZGRhdGEtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IG5ld1RvdGFsID0gKF9jdXJVc2VyLnRvdGFsfHwwKSArIGFkZEdiKjEwNzM3NDE4MjQ7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6bmV3VG90YWwsZXhwaXJ5VGltZTpfY3VyVXNlci5leHB8fDAsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSBEYXRhICsnK2FkZEdiKycgR0Ig4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tYWRkZGF0YS1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9TZXREYXRhKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBnYiA9IHBhcnNlRmxvYXQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tc2V0ZGF0YS1nYicpLnZhbHVlKTsKICBpZiAoaXNOYU4oZ2IpfHxnYjwwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tc2V0ZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOnRvdGFsQnl0ZXMsZXhwaXJ5VGltZTpfY3VyVXNlci5leHB8fDAsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC4seC5ieC4hyBEYXRhIExpbWl0ICcrKGdiPjA/Z2IrJyBHQic6J+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcpKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tc2V0ZGF0YS1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9SZXNldFRyYWZmaWMoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIF9tQnRuTG9hZCgnbS1yZXNldC1idG4nLCB0cnVlKTsKICB0cnkgewogICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICAvLyDguYPguIrguYkgZmV0Y2gg4LmC4LiU4Lii4LiV4Lij4LiH4LmA4Lie4Li34LmI4Lit4LiI4Lix4LiU4LiB4Liy4LijIHJlc3BvbnNlIOC4l+C4teC5iOC4reC4suC4iOC5hOC4oeC5iOC5g+C4iuC5iCBKU09OCiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL3Jlc2V0Q2xpZW50VHJhZmZpYy8nK19jdXJVc2VyLmVtYWlsLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJwogICAgfSk7CiAgICBsZXQgcmVzID0ge307CiAgICB0cnkgeyByZXMgPSBhd2FpdCByLmpzb24oKTsgfSBjYXRjaChqZSkgeyByZXMgPSB7c3VjY2Vzczogci5va307IH0KICAgIGlmICghcmVzLnN1Y2Nlc3MgJiYgIXIub2spIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIIChIVFRQICcrci5zdGF0dXMrJyknKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE1MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRGVsZXRlVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICAvLyDguYPguIrguYkgZmV0Y2gg4LmC4LiU4Lii4LiV4Lij4LiH4LmA4Lie4Li34LmI4Lit4LiI4Lix4LiU4LiB4Liy4LijIHJlc3BvbnNlIOC4l+C4teC5iOC4reC4suC4iOC5hOC4oeC5iOC5g+C4iuC5iCBKU09OCiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL2RlbENsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnCiAgICB9KTsKICAgIGxldCByZXMgPSB7fTsKICAgIHRyeSB7IHJlcyA9IGF3YWl0IHIuanNvbigpOyB9IGNhdGNoKGplKSB7IHJlcyA9IHtzdWNjZXNzOiByLm9rfTsgfQogICAgaWYgKCFyZXMuc3VjY2VzcyAmJiAhci5vaykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguKXguJrguKLguLnguKrguYTguKHguYjguKrguLPguYDguKPguYfguIggKEhUVFAgJytyLnN0YXR1cysnKScpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKXguJrguKLguLnguKogJytfY3VyVXNlci5lbWFpbCsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxMjAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCBmYWxzZSk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpIHsKICBjb25zdCBsb2FkRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1sb2FkaW5nJyk7CiAgY29uc3Qgdmxlc3NFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtdmxlc3Mtc2VjdGlvbicpOwogIGNvbnN0IHNzaEVsICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXNzaC1zZWN0aW9uJyk7CiAgY29uc3QgZW1wdHlFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtZW1wdHknKTsKICBjb25zdCBjb3VudEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1jb3VudCcpOwogIGNvbnN0IHRpbWVFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKTsKCiAgbG9hZEVsLmlubmVySFRNTCAgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiU4LiC4LmJ4Lit4Lih4Li54Lil4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMLi4uPC9kaXY+JzsKICBsb2FkRWwuc3R5bGUuZGlzcGxheSAgPSAnYmxvY2snOwogIHZsZXNzRWwuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBzc2hFbC5zdHlsZS5kaXNwbGF5ICAgPSAnbm9uZSc7CiAgZW1wdHlFbC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwoKICB0cnkgewogICAgLy8g4pSA4pSAIDEuIExvZ2luIHgtdWkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACiAgICBpZiAoIV94dWlPaykgYXdhaXQgeHVpTG9naW4oKTsKCiAgICAvLyDilIDilIAgMi4g4LmC4Lir4Lil4LiUIFZMRVNTIG9ubGluZSBlbWFpbHMg4LiI4Liy4LiBIHgtdWkgKOC4quC4lCkg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACiAgICBsZXQgb25saW5lRW1haWxzID0gW107CiAgICB0cnkgewogICAgICAvLyDguJTguLbguIcgVkxFU1Mgb25saW5lIOC4iOC4suC4gSBTU0ggQVBJICjguJfguLXguYggbG9naW4geC11aSDguYPguKvguYnguYDguK3guIcpCiAgICAgIGNvbnN0IG9kID0gYXdhaXQgZmV0Y2goQVBJKycvdmxlc3Nfb25saW5lP3Q9JytEYXRlLm5vdygpLCB7Y2FjaGU6J25vLXN0b3JlJ30pLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgICAgaWYgKG9kICYmIG9kLm9rICYmIEFycmF5LmlzQXJyYXkob2Qub25saW5lKSkgewogICAgICAgIG9ubGluZUVtYWlscyA9IG9kLm9ubGluZTsKICAgICAgfQogICAgfSBjYXRjaChlMikge30KCiAgICAvLyDilIDilIAgMy4g4LmC4Lir4Lil4LiUIGNsaWVudFN0YXRzIOC4guC4reC4h+C5geC4leC5iOC4peC4sCB1c2VyICh0cmFmZmljIOC4iOC4o+C4tOC4hykg4pSA4pSACiAgICAvLyDguYPguIrguYkgX2FsbFVzZXJzIOC4luC5ieC4suC4oeC4teC5geC4peC5ieC4pyDguYTguKHguYjguIfguLHguYnguJnguYLguKvguKXguJTguYPguKvguKHguYgKICAgIGlmICghX2FsbFVzZXJzLmxlbmd0aCkgYXdhaXQgbG9hZFVzZXJzUXVpZXQoKTsKICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHUgPT4geyB1TWFwW3UuZW1haWxdID0gdTsgfSk7CgogICAgLy8g4pSA4pSAIDQuIOC5guC4q+C4peC4lCBTU0ggb25saW5lIOC4iOC4suC4gSBTU0ggQVBJIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgAogICAgbGV0IHNzaE9ubGluZSA9IFtdOwogICAgbGV0IHNzaENvbm5Db3VudCA9IDA7CiAgICB0cnkgewogICAgICBjb25zdCBvblJlc3AgPSBhd2FpdCBmZXRjaChBUEkrJy9vbmxpbmVfc3NoJywge2NhY2hlOiduby1zdG9yZSd9KS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAgIGlmIChvblJlc3AgJiYgb25SZXNwLm9rKSB7CiAgICAgICAgc3NoT25saW5lID0gKG9uUmVzcC5vbmxpbmUgfHwgW10pLmZpbHRlcih1ID0+ICF1LmNvbm5fb25seSk7CiAgICAgICAgLy8gY29ubl9vbmx5ID0g4LmE4Lih4LmI4Lij4Li54LmJ4LiK4Li34LmI4LitIHVzZXIg4LmB4LiV4LmI4Lij4Li54LmJ4Lin4LmI4Liy4Lih4Li1IGNvbm5lY3Rpb24KICAgICAgICBjb25zdCBjb25uT25seSA9IChvblJlc3Aub25saW5lIHx8IFtdKS5maW5kKHUgPT4gdS5jb25uX29ubHkpOwogICAgICAgIGlmIChjb25uT25seSkgewogICAgICAgICAgY29uc3QgbSA9IFN0cmluZyhjb25uT25seS51c2VyKS5tYXRjaCgvKFxkKykvKTsKICAgICAgICAgIHNzaENvbm5Db3VudCA9IG0gPyBwYXJzZUludChtWzFdKSA6IDE7CiAgICAgICAgfQogICAgICB9CiAgICAgIC8vIGZhbGxiYWNrOiDguYPguIrguYkgY29ubmVjdGlvbiBjb3VudCDguIjguLLguIEgL2FwaS9zdGF0dXMKICAgICAgaWYgKCFzc2hPbmxpbmUubGVuZ3RoICYmIHNzaENvbm5Db3VudCA9PT0gMCkgewogICAgICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJywge2NhY2hlOiduby1zdG9yZSd9KS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAgICAgaWYgKHN0KSBzc2hDb25uQ291bnQgPSAoc3QuY29ubl8xNDN8fDApICsgKHN0LmNvbm5fMTA5fHwwKSArIChzdC5jb25uXzgwfHwwKTsKICAgICAgfQogICAgfSBjYXRjaChlMykge30KCiAgICBjb25zdCB0b3RhbE9ubGluZSA9IG9ubGluZUVtYWlscy5sZW5ndGggKyBzc2hPbmxpbmUubGVuZ3RoICsgKHNzaENvbm5Db3VudCA+IDAgJiYgc3NoT25saW5lLmxlbmd0aCA9PT0gMCA/IDEgOiAwKTsKICAgIGNvdW50RWwudGV4dENvbnRlbnQgPSBvbmxpbmVFbWFpbHMubGVuZ3RoICsgc3NoT25saW5lLmxlbmd0aDsKICAgIGlmICh0aW1lRWwpIHRpbWVFbC50ZXh0Q29udGVudCA9ICfguK3guLHguJ7guYDguJTguJU6ICcrbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgICBsb2FkRWwuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKCiAgICBpZiAob25saW5lRW1haWxzLmxlbmd0aCA9PT0gMCAmJiBzc2hPbmxpbmUubGVuZ3RoID09PSAwICYmIHNzaENvbm5Db3VudCA9PT0gMCkgewogICAgICBlbXB0eUVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogICAgICByZXR1cm47CiAgICB9CgogICAgLy8g4pSA4pSAIDUuIOC5geC4quC4lOC4hyBWTEVTUyBvbmxpbmUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACiAgICBpZiAob25saW5lRW1haWxzLmxlbmd0aCA+IDApIHsKICAgICAgdmxlc3NFbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS12bGVzcy1saXN0JykuaW5uZXJIVE1MID0gb25saW5lRW1haWxzLm1hcChlbWFpbCA9PiB7CiAgICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdIHx8IHt9OwogICAgICAgIGNvbnN0IHVzZWRCeXRlcyAgPSAodS51cHx8MCkgKyAodS5kb3dufHwwKTsKICAgICAgICBjb25zdCB0b3RhbEJ5dGVzID0gdS50b3RhbCB8fCAwOwogICAgICAgIGNvbnN0IHBjdCAgICAgICAgPSB0b3RhbEJ5dGVzID4gMCA/IE1hdGgubWluKDEwMCwgTWF0aC5yb3VuZCh1c2VkQnl0ZXMvdG90YWxCeXRlcyoxMDApKSA6IDA7CiAgICAgICAgY29uc3QgdXNlZEdCICAgICA9ICh1c2VkQnl0ZXMvMTA3Mzc0MTgyNCkudG9GaXhlZCgyKTsKICAgICAgICBjb25zdCB0b3RhbEdCICAgID0gdG90YWxCeXRlcyA+IDAgPyAodG90YWxCeXRlcy8xMDczNzQxODI0KS50b0ZpeGVkKDEpIDogJ+KInic7CiAgICAgICAgY29uc3QgYmFyQ29sb3IgICA9IHBjdCA+IDg1ID8gJyNlZjQ0NDQnIDogcGN0ID4gNjUgPyAnI2Y5NzMxNicgOiAndmFyKC0tYWMpJzsKICAgICAgICBjb25zdCBwb3J0ICAgICAgID0gdS5wb3J0IHx8ICc/JzsKICAgICAgICBjb25zdCBjYXJyaWVyICAgID0gcG9ydCA9PSA4MDgwID8gJ0FJUycgOiBwb3J0ID09IDg4ODAgPyAnVFJVRScgOiAnVkwnOwogICAgICAgIC8vIOC4p+C4seC4meC4q+C4oeC4lOC4reC4suC4ouC4uAogICAgICAgIGNvbnN0IGRsID0gdS5leHAgJiYgdS5leHAgPiAwID8gTWF0aC5jZWlsKCh1LmV4cCAtIERhdGUubm93KCkpLzg2NDAwMDAwKSA6IG51bGw7CiAgICAgICAgY29uc3QgZXhwVHh0ID0gZGwgPT09IG51bGwgPyAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJyA6IGRsIDwgMCA/ICfguKvguKHguJTguK3guLLguKLguLjguYHguKXguYnguKcnIDogZGwrJ2QnOwogICAgICAgIGNvbnN0IGV4cENscyA9IGRsICE9PSBudWxsICYmIGRsIDwgMCA/ICcjZWY0NDQ0JyA6IGRsICE9PSBudWxsICYmIGRsIDw9IDMgPyAnI2Y5NzMxNicgOiAndmFyKC0tYWMpJzsKICAgICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIiBzdHlsZT0iZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOnN0cmV0Y2g7Z2FwOjhweDtjdXJzb3I6ZGVmYXVsdCI+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4Ij4KICAgICAgICAgICAgPGRpdiBjbGFzcz0idWF2IGF2LWciIHN0eWxlPSJmbGV4LXNocmluazowO3Bvc2l0aW9uOnJlbGF0aXZlIj4KICAgICAgICAgICAgICA8c3BhbiBzdHlsZT0iZm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXdlaWdodDo3MDAiPiR7Y2Fycmllcn08L3NwYW4+CiAgICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImRvdCIgc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO3RvcDotMnB4O3JpZ2h0Oi0ycHg7d2lkdGg6NnB4O2hlaWdodDo2cHgiPjwvc3Bhbj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MTttaW4td2lkdGg6MCI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7ZW1haWx9PC9kaXY+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0idW0iIHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjhweDthbGlnbi1pdGVtczpjZW50ZXIiPgogICAgICAgICAgICAgICAgPHNwYW4+UG9ydCAke3BvcnR9PC9zcGFuPgogICAgICAgICAgICAgICAgPHNwYW4gc3R5bGU9ImNvbG9yOiR7ZXhwQ2xzfTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4Ij4ke2V4cFR4dH08L3NwYW4+CiAgICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayIgc3R5bGU9ImZvbnQtc2l6ZTo5cHg7d2hpdGUtc3BhY2U6bm93cmFwIj7il48gT05MSU5FPC9zcGFuPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJwYWRkaW5nLWxlZnQ6NDZweCI+CiAgICAgICAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbTo0cHgiPgogICAgICAgICAgICAgIDxzcGFuPiR7dXNlZEdCfSBHQiDguYPguIrguYnguYTguJs8L3NwYW4+CiAgICAgICAgICAgICAgPHNwYW4gc3R5bGU9ImNvbG9yOiR7YmFyQ29sb3J9O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlIj4ke3RvdGFsR0IgPT09ICfiiJ4nID8gJ+KInicgOiB0b3RhbEdCKycgR0InfSDCtyAke3BjdH0lPC9zcGFuPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iaGVpZ2h0OjZweDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsMC4wNik7Ym9yZGVyLXJhZGl1czozcHg7b3ZlcmZsb3c6aGlkZGVuIj4KICAgICAgICAgICAgICA8ZGl2IHN0eWxlPSJoZWlnaHQ6MTAwJTt3aWR0aDoke3BjdH0lO2JhY2tncm91bmQ6JHtiYXJDb2xvcn07Ym9yZGVyLXJhZGl1czozcHg7dHJhbnNpdGlvbjp3aWR0aCAwLjhzIGVhc2UiPjwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PmA7CiAgICAgIH0pLmpvaW4oJycpOwogICAgfQoKICAgIC8vIOKUgOKUgCA2LiDguYHguKrguJTguIcgU1NIIG9ubGluZSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKICAgIGlmIChzc2hPbmxpbmUubGVuZ3RoID4gMCkgewogICAgICBzc2hFbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1zc2gtbGlzdCcpLmlubmVySFRNTCA9IHNzaE9ubGluZS5tYXAodSA9PiB7CiAgICAgICAgY29uc3QgZGwgPSB1LmV4cCA/IE1hdGguY2VpbCgobmV3IERhdGUodS5leHApIC0gbmV3IERhdGUoKSkvODY0MDAwMDApIDogbnVsbDsKICAgICAgICBjb25zdCBleHBUeHQgPSBkbCA9PT0gbnVsbCA/ICfguYTguKHguYjguIjguLPguIHguLHguJQnIDogZGwgPCAwID8gJ+C4q+C4oeC4lOC4reC4suC4ouC4uCcgOiBkbCsnZCc7CiAgICAgICAgY29uc3QgZXhwQ2xzID0gZGwgIT09IG51bGwgJiYgZGwgPCAwID8gJyNlZjQ0NDQnIDogZGwgIT09IG51bGwgJiYgZGwgPD0gMyA/ICcjZjk3MzE2JyA6ICcjM2I4MmY2JzsKICAgICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIiBzdHlsZT0iY3Vyc29yOmRlZmF1bHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0idWF2IiBzdHlsZT0iYmFja2dyb3VuZDpyZ2JhKDU5LDEzMCwyNDYsMC4xNSk7Y29sb3I6IzNiODJmNjtib3JkZXI6MXB4IHNvbGlkIHJnYmEoNTksMTMwLDI0NiwuMjUpO2ZsZXgtc2hyaW5rOjA7cG9zaXRpb246cmVsYXRpdmUiPgogICAgICAgICAgICA8c3BhbiBzdHlsZT0iZm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXdlaWdodDo3MDAiPlNTSDwvc3Bhbj4KICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImRvdCIgc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO3RvcDotMnB4O3JpZ2h0Oi0ycHg7d2lkdGg6NnB4O2hlaWdodDo2cHg7YmFja2dyb3VuZDojM2I4MmY2O2JveC1zaGFkb3c6MCAwIDZweCAjM2I4MmY2O2FuaW1hdGlvbjpwbHMgMS41cyBpbmZpbml0ZSI+PC9zcGFuPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjE7bWluLXdpZHRoOjAiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LnVzZXJ9PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InVtIiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo4cHg7YWxpZ24taXRlbXM6Y2VudGVyIj4KICAgICAgICAgICAgICA8c3Bhbj5Ecm9wYmVhciA6MTQzLzoxMDk8L3NwYW4+CiAgICAgICAgICAgICAgPHNwYW4gc3R5bGU9ImNvbG9yOiR7ZXhwQ2xzfTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4Ij4ke2V4cFR4dH08L3NwYW4+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayIgc3R5bGU9ImZvbnQtc2l6ZTo5cHg7d2hpdGUtc3BhY2U6bm93cmFwIj7il48gT05MSU5FPC9zcGFuPgogICAgICAgIDwvZGl2PmA7CiAgICAgIH0pLmpvaW4oJycpOwogICAgfSBlbHNlIGlmIChzc2hDb25uQ291bnQgPiAwKSB7CiAgICAgIC8vIOC4oeC4tSBjb25uZWN0aW9uIOC5geC4leC5iOC5hOC4oeC5iOC4o+C4ueC5ieC4iuC4t+C5iOC4rSB1c2VyIOKGkiDguYHguKrguJTguIfguYDguJvguYfguJkgY29ubmVjdGlvbiBjb3VudAogICAgICBzc2hFbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1zc2gtbGlzdCcpLmlubmVySFRNTCA9CiAgICAgICAgYDxkaXYgY2xhc3M9InVpdGVtIiBzdHlsZT0iY3Vyc29yOmRlZmF1bHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0idWF2IiBzdHlsZT0iYmFja2dyb3VuZDpyZ2JhKDU5LDEzMCwyNDYsMC4xNSk7Y29sb3I6IzNiODJmNjtib3JkZXI6MXB4IHNvbGlkIHJnYmEoNTksMTMwLDI0NiwuMjUpO2ZsZXgtc2hyaW5rOjA7cG9zaXRpb246cmVsYXRpdmUiPgogICAgICAgICAgICA8c3BhbiBzdHlsZT0iZm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXdlaWdodDo3MDAiPlNTSDwvc3Bhbj4KICAgICAgICAgICAgPHNwYW4gY2xhc3M9ImRvdCIgc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO3RvcDotMnB4O3JpZ2h0Oi0ycHg7d2lkdGg6NnB4O2hlaWdodDo2cHg7YmFja2dyb3VuZDojM2I4MmY2O2JveC1zaGFkb3c6MCAwIDZweCAjM2I4MmY2O2FuaW1hdGlvbjpwbHMgMS41cyBpbmZpbml0ZSI+PC9zcGFuPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHtzc2hDb25uQ291bnR9IGFjdGl2ZSBjb25uZWN0aW9uJHtzc2hDb25uQ291bnQ+MT8ncyc6Jyd9PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InVtIj5Ecm9wYmVhciDCtyBwb3J0IDE0My8xMDkvODA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgb2siIHN0eWxlPSJmb250LXNpemU6OXB4O3doaXRlLXNwYWNlOm5vd3JhcCI+4pePIE9OTElORTwvc3Bhbj4KICAgICAgICA8L2Rpdj5gOwogICAgfQoKICB9IGNhdGNoKGUpIHsKICAgIGxvYWRFbC5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPuKdjCAnK2UubWVzc2FnZSsnPC9kaXY+JzsKICAgIGxvYWRFbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICB9Cn0KCi8vIOC5guC4q+C4peC4lCB1c2VycyDguYHguJrguJrguYDguIfguLXguKLguJrguYYg4LmE4Lih4LmIIHJlbmRlciBVSQphc3luYyBmdW5jdGlvbiBsb2FkVXNlcnNRdWlldCgpIHsKICB0cnkgewogICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICBjb25zdCBkID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGlmICghZC5zdWNjZXNzKSByZXR1cm47CiAgICBfYWxsVXNlcnMgPSBbXTsKICAgIC8vIOC4lOC4tuC4hyBjbGllbnRTdGF0cyDguYHguKLguIHguJXguYjguLLguIfguKvguLLguIEKICAgIGNvbnN0IHN0YXRzTWFwID0ge307CiAgICB0cnkgewogICAgICBjb25zdCBzdGF0c0FsbCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9jbGllbnRUcmFmZmljcy9hbGwnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAgIGlmIChzdGF0c0FsbCAmJiBzdGF0c0FsbC5zdWNjZXNzICYmIHN0YXRzQWxsLm9iaikgewogICAgICAgIHN0YXRzQWxsLm9iai5mb3JFYWNoKHMgPT4geyBzdGF0c01hcFtzLmVtYWlsXSA9IHM7IH0pOwogICAgICB9CiAgICB9IGNhdGNoKGUyKSB7fQogICAgKGQub2JqfHxbXSkuZm9yRWFjaChpYiA9PiB7CiAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAoc2V0dGluZ3MuY2xpZW50c3x8W10pLmZvckVhY2goYyA9PiB7CiAgICAgICAgY29uc3QgZW1haWwgPSBjLmVtYWlsfHxjLmlkOwogICAgICAgIGNvbnN0IHN0ID0gc3RhdHNNYXBbZW1haWxdOwogICAgICAgIF9hbGxVc2Vycy5wdXNoKHsKICAgICAgICAgIGliSWQ6IGliLmlkLCBwb3J0OiBpYi5wb3J0LCBwcm90bzogaWIucHJvdG9jb2wsCiAgICAgICAgICBlbWFpbDogZW1haWwsIHV1aWQ6IGMuaWQsCiAgICAgICAgICBleHA6IGMuZXhwaXJ5VGltZXx8MCwgdG90YWw6IGMudG90YWxHQnx8MCwKICAgICAgICAgIHVwOiBzdCA/IChzdC51cHx8MCkgOiAwLCBkb3duOiBzdCA/IChzdC5kb3dufHwwKSA6IDAsIGxpbWl0SXA6IGMubGltaXRJcHx8MAogICAgICAgIH0pOwogICAgICB9KTsKICAgIH0pOwogIH0gY2F0Y2goZSkge30KfQoKLy8g4pWQ4pWQ4pWQ4pWQIEJBTiAvIFVOQkFOIFNZU1RFTSDilZDilZDilZDilZAKLy8g4LiV4Lix4Lin4LmB4Lib4Lij4LmA4LiB4LmH4Lia4Lij4Liy4Lii4LiB4Liy4LijIGJhbm5lZCB1c2VycyArIGNvdW50ZG93biB0aW1lcnMKbGV0IF9iYW5uZWRUaW1lcnMgPSB7fTsKbGV0IF9iYW5uZWRVc2VycyA9IFtdOwoKLy8g4LmC4Lir4Lil4LiU4Lij4Liy4Lii4LiB4Liy4Lij4LiX4Li14LmI4LiW4Li54LiB4LmB4Lia4LiZCmFzeW5jIGZ1bmN0aW9uIGxvYWRCYW5uZWRVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFubmVkLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy9iYW5uZWQnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAvLyDguJbguYnguLIgQVBJIOC4ouC4seC4h+C5hOC4oeC5iOC4o+C4reC4h+C4o+C4seC4miBlbmRwb2ludCAvYmFubmVkIOC5g+C4q+C5ieC5g+C4iuC5ieC4guC5ieC4reC4oeC4ueC4peC4iOC4suC4gSB4LXVpIGNsaWVudFN0YXRzCiAgICBsZXQgYmFubmVkID0gW107CiAgICBpZiAoZCAmJiBkLmJhbm5lZCkgewogICAgICBiYW5uZWQgPSBkLmJhbm5lZDsKICAgIH0gZWxzZSB7CiAgICAgIC8vIGZhbGxiYWNrOiDguJTguLbguIfguIjguLLguIEgeC11aSDguJXguKPguKfguIggY2xpZW50cyDguJfguLXguYjguJbguLnguIEgZGlzYWJsZSDguYDguJ7guKPguLLguLAgSVAgbGltaXQKICAgICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICAgIGNvbnN0IGliTGlzdCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgICBpZiAoaWJMaXN0ICYmIGliTGlzdC5vYmopIHsKICAgICAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgICAgIChpYkxpc3Qub2JqfHxbXSkuZm9yRWFjaChpYiA9PiB7CiAgICAgICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICAgICAgaWYgKGMuZW5hYmxlID09PSBmYWxzZSkgewogICAgICAgICAgICAgIC8vIOC4luC5ieC4siB1c2VyIOC4luC4ueC4gSBkaXNhYmxlIOC4luC4t+C4reC4p+C5iOC4suC5guC4lOC4meC5geC4muC4mQogICAgICAgICAgICAgIGJhbm5lZC5wdXNoKHsKICAgICAgICAgICAgICAgIHVzZXI6IGMuZW1haWwgfHwgYy5pZCwKICAgICAgICAgICAgICAgIHR5cGU6ICd2bGVzcycsCiAgICAgICAgICAgICAgICBwb3J0OiBpYi5wb3J0LAogICAgICAgICAgICAgICAgYmFuVGltZTogbm93LAogICAgICAgICAgICAgICAgdW5iYW5UaW1lOiBub3cgKyAzNjAwMDAwIC8vIDEg4LiK4Lix4LmI4Lin4LmC4Lih4LiHICjguKrguKHguKHguLjguJXguLQpCiAgICAgICAgICAgICAgfSk7CiAgICAgICAgICAgIH0KICAgICAgICAgIH0pOwogICAgICAgIH0pOwogICAgICB9CiAgICB9CiAgICBfYmFubmVkVXNlcnMgPSBiYW5uZWQ7CgogICAgLy8gQ2xlYXIgb2xkIHRpbWVycwogICAgT2JqZWN0LnZhbHVlcyhfYmFubmVkVGltZXJzKS5mb3JFYWNoKHQ9PmNsZWFySW50ZXJ2YWwodCkpOwogICAgX2Jhbm5lZFRpbWVycyA9IHt9OwoKICAgIGlmICghYmFubmVkLmxlbmd0aCkgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFubmVkLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+4pyFPC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4LmA4LiL4Lit4Lij4LmM4LiW4Li54LiB4LmB4Lia4LiZ4Lit4Lii4Li54LmIPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIHJlbmRlckJhbm5lZExpc3QoYmFubmVkKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW5uZWQtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQoKZnVuY3Rpb24gcmVuZGVyQmFubmVkTGlzdChiYW5uZWQpIHsKICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW5uZWQtbGlzdCcpLmlubmVySFRNTCA9IGJhbm5lZC5tYXAoKGIsaSkgPT4gewogICAgY29uc3QgcmVtYWluaW5nID0gYi51bmJhblRpbWUgPyBNYXRoLm1heCgwLCBiLnVuYmFuVGltZSAtIG5vdykgOiAzNjAwMDAwOwogICAgY29uc3QgbWlucyA9IE1hdGguZmxvb3IocmVtYWluaW5nLzYwMDAwKTsKICAgIGNvbnN0IHNlY3MgPSBNYXRoLmZsb29yKChyZW1haW5pbmclNjAwMDApLzEwMDApOwogICAgY29uc3QgdHlwZUxhYmVsID0gYi50eXBlPT09J3NzaCcgPyAnU1NIJyA6ICdWTEVTUyc7CiAgICBjb25zdCB0eXBlQmcgPSBiLnR5cGU9PT0nc3NoJyA/ICdyZ2JhKDU5LDEzMCwyNDYsMC4xNSknIDogJ3JnYmEoMjM5LDY4LDY4LDAuMTIpJzsKICAgIGNvbnN0IHR5cGVDb2xvciA9IGIudHlwZT09PSdzc2gnID8gJyMzYjgyZjYnIDogJyNlZjQ0NDQnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSIgaWQ9ImJhbm5lZC1pdGVtLSR7aX0iIHN0eWxlPSJmbGV4LWRpcmVjdGlvbjpjb2x1bW47YWxpZ24taXRlbXM6c3RyZXRjaDtnYXA6OHB4Ij4KICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweCI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2IiBzdHlsZT0iYmFja2dyb3VuZDoke3R5cGVCZ307Y29sb3I6JHt0eXBlQ29sb3J9O2JvcmRlcjoxcHggc29saWQgJHt0eXBlQ29sb3J9MzM7ZmxleC1zaHJpbms6MCI+CiAgICAgICAgICA8c3BhbiBzdHlsZT0iZm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXdlaWdodDo3MDAiPiR7dHlwZUxhYmVsfTwvc3Bhbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7Yi51c2VyfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idW0iPlBvcnQgJHtiLnBvcnR8fCc/J30gwrcg4LmA4LiB4Li04LiZIElQIExpbWl0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBvbmNsaWNrPSJ1bmJhblVzZXJEaXJlY3QoJyR7Yi51c2VyfScsJyR7Yi50eXBlfHwndmxlc3MnfScsJHtiLmliSWR8fDB9LCcke2IudXVpZHx8Jyd9JykiIAogICAgICAgICAgc3R5bGU9ImJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjYjQ1MzA5LCNkOTc3MDYpO2JvcmRlcjpub25lO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6I2ZmZjtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtmb250LXdlaWdodDo3MDA7d2hpdGUtc3BhY2U6bm93cmFwIj4KICAgICAgICAgIPCflJMg4Lib4Lil4LiUCiAgICAgICAgPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJwYWRkaW5nLWxlZnQ6NDZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHgiPgogICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSI+4Lir4Lih4LiU4LmB4Lia4LiZ4LmD4LiZOjwvZGl2PgogICAgICAgIDxkaXYgaWQ9ImNvdW50ZG93bi0ke2l9IiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOiNmOTczMTY7YmFja2dyb3VuZDpyZ2JhKDI0OSwxMTUsMjIsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ5LDExNSwyMiwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6MnB4IDhweCI+CiAgICAgICAgICAke1N0cmluZyhtaW5zKS5wYWRTdGFydCgyLCcwJyl9OiR7U3RyaW5nKHNlY3MpLnBhZFN0YXJ0KDIsJzAnKX0KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjE7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsMC4wNik7Ym9yZGVyLXJhZGl1czoycHg7b3ZlcmZsb3c6aGlkZGVuIj4KICAgICAgICAgIDxkaXYgaWQ9ImNvdW50ZG93bi1iYXItJHtpfSIgc3R5bGU9ImhlaWdodDoxMDAlO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmOTczMTYsI2ZiOTIzYyk7Ym9yZGVyLXJhZGl1czoycHg7dHJhbnNpdGlvbjp3aWR0aCAxcyBsaW5lYXI7d2lkdGg6JHtNYXRoLm1pbigxMDAsKHJlbWFpbmluZy8zNjAwMDAwKSoxMDApfSUiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7CgogIC8vIFN0YXJ0IGNvdW50ZG93bnMKICBiYW5uZWQuZm9yRWFjaCgoYixpKSA9PiB7CiAgICBfYmFubmVkVGltZXJzW2ldID0gc2V0SW50ZXJ2YWwoKCkgPT4gewogICAgICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb3VudGRvd24tJytpKTsKICAgICAgY29uc3QgYmFyRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY291bnRkb3duLWJhci0nK2kpOwogICAgICBpZiAoIWVsKSB7IGNsZWFySW50ZXJ2YWwoX2Jhbm5lZFRpbWVyc1tpXSk7IHJldHVybjsgfQogICAgICBjb25zdCByZW0gPSBNYXRoLm1heCgwLCBiLnVuYmFuVGltZSAtIERhdGUubm93KCkpOwogICAgICBjb25zdCBtID0gTWF0aC5mbG9vcihyZW0vNjAwMDApOwogICAgICBjb25zdCBzID0gTWF0aC5mbG9vcigocmVtJTYwMDAwKS8xMDAwKTsKICAgICAgZWwudGV4dENvbnRlbnQgPSBTdHJpbmcobSkucGFkU3RhcnQoMiwnMCcpKyc6JytTdHJpbmcocykucGFkU3RhcnQoMiwnMCcpOwogICAgICBpZiAoYmFyRWwpIGJhckVsLnN0eWxlLndpZHRoID0gTWF0aC5taW4oMTAwLChyZW0vMzYwMDAwMCkqMTAwKSsnJSc7CiAgICAgIGlmIChyZW0gPD0gMCkgewogICAgICAgIGNsZWFySW50ZXJ2YWwoX2Jhbm5lZFRpbWVyc1tpXSk7CiAgICAgICAgZWwudGV4dENvbnRlbnQgPSAnMDA6MDAnOwogICAgICAgIGVsLnN0eWxlLmNvbG9yID0gJ3ZhcigtLWFjKSc7CiAgICAgICAgZWwuc3R5bGUuYm9yZGVyQ29sb3IgPSAncmdiYSgzNCwxOTcsOTQsMC4zKSc7CiAgICAgICAgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdyZ2JhKDM0LDE5Nyw5NCwwLjEpJzsKICAgICAgICAvLyBBdXRvIHJlbG9hZCBhZnRlciBiYW4gdGltZQogICAgICAgIHNldFRpbWVvdXQobG9hZEJhbm5lZFVzZXJzLCAyMDAwKTsKICAgICAgfQogICAgfSwgMTAwMCk7CiAgfSk7Cn0KCi8vIOC4m+C4peC4lOC4peC5h+C4reC4hOC5guC4lOC4ouC4nuC4tOC4oeC4nuC5jOC4iuC4t+C5iOC4reC5g+C4meC4iuC5iOC4reC4hyBpbnB1dAphc3luYyBmdW5jdGlvbiB1bmJhblVzZXIoKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVlLnRyaW0oKTsKICBpZiAoIXVzZXIpIHJldHVybiBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBVc2VybmFtZSDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguJvguKXguJTguKXguYfguK3guIQnLCdlcnInKTsKICAKICBjb25zdCBidG4gPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yKCdbb25jbGljaz0idW5iYW5Vc2VyKCkiXScpOwogIGlmIChidG4pIHsgYnRuLmRpc2FibGVkPXRydWU7IGJ0bi5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+IOC4geC4s+C4peC4seC4h+C4m+C4peC4lC4uLic7IH0KICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CgogIHRyeSB7CiAgICAvLyDguJ7guKLguLLguKLguLLguKEgZW5hYmxlIGNsaWVudCDguYPguJkgeC11aQogICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICAKICAgIGxldCBmb3VuZCA9IGZhbHNlOwogICAgY29uc3QgaWJMaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoaWJMaXN0ICYmIGliTGlzdC5vYmopIHsKICAgICAgZm9yIChjb25zdCBpYiBvZiBpYkxpc3Qub2JqKSB7CiAgICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgICAgY29uc3QgY2xpZW50ID0gKHNldHRpbmdzLmNsaWVudHN8fFtdKS5maW5kKGMgPT4gKGMuZW1haWx8fGMuaWQpID09PSB1c2VyKTsKICAgICAgICBpZiAoY2xpZW50KSB7CiAgICAgICAgICAvLyBFbmFibGUgY2xpZW50CiAgICAgICAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK2NsaWVudC5pZCwgewogICAgICAgICAgICBpZDogaWIuaWQsCiAgICAgICAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbewogICAgICAgICAgICAgIGlkOmNsaWVudC5pZCwgZmxvdzpjbGllbnQuZmxvd3x8JycsIGVtYWlsOmNsaWVudC5lbWFpbHx8Y2xpZW50LmlkLAogICAgICAgICAgICAgIGxpbWl0SXA6Y2xpZW50LmxpbWl0SXB8fDAsIHRvdGFsR0I6Y2xpZW50LnRvdGFsR0J8fDAsCiAgICAgICAgICAgICAgZXhwaXJ5VGltZTpjbGllbnQuZXhwaXJ5VGltZXx8MCwgZW5hYmxlOnRydWUsCiAgICAgICAgICAgICAgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgICAgICAgfV19KQogICAgICAgICAgfSk7CiAgICAgICAgICBpZiAocmVzLnN1Y2Nlc3MpIHsgZm91bmQgPSB0cnVlOyBicmVhazsgfQogICAgICAgIH0KICAgICAgfQogICAgfQogICAgCiAgICAvLyDguKXguJrguK3guK3guIHguIjguLLguIEgaXB0YWJsZXMgKOC4luC5ieC4siBTU0ggYmFuKQogICAgYXdhaXQgZmV0Y2goQVBJKycvdW5iYW4nLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pCiAgICB9KS5jYXRjaCgoKT0+e30pOwoKICAgIGlmIChmb3VuZCkgewogICAgICBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+KchSDguJvguKXguJTguKXguYfguK3guIQgJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIIOKAlCDguKrguLLguKHguLLguKPguJbguYDguIrguLfguYjguK3guKHguJXguYjguK3guYTguJTguYnguJfguLHguJnguJfguLUnLCdvaycpOwogICAgfSBlbHNlIHsKICAgICAgLy8g4LmE4Lih4LmI4Lie4Lia4LmD4LiZIHgtdWkg4LmB4LiV4LmI4Lit4Liy4LiI4LmA4Lib4LmH4LiZIFNTSCDigJQg4LiW4Li34Lit4Lin4LmI4Liy4Lib4Lil4LiU4LmE4LiU4LmJCiAgICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4quC5iOC4h+C4hOC4s+C4quC4seC5iOC4h+C4m+C4peC4lOC4peC5h+C4reC4hCAnK3VzZXIrJyDguYHguKXguYnguKcnLCdvaycpOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBsb2FkQmFubmVkVXNlcnMoKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7CiAgICBpZiAoYnRuKSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n8J+UkyDguJvguKXguJTguKXguYfguK3guIQgSVAgQmFuJzsgfQogIH0KfQoKLy8g4Lib4Lil4LiU4Lil4LmH4Lit4LiE4LmC4LiU4Lii4LiB4LiU4Lib4Li44LmI4Lih4LiI4Liy4LiB4Lij4Liy4Lii4LiB4Liy4LijCmFzeW5jIGZ1bmN0aW9uIHVuYmFuVXNlckRpcmVjdCh1c2VyLCB0eXBlLCBpYklkLCB1dWlkKSB7CiAgdHJ5IHsKICAgIGlmICh0eXBlID09PSAndmxlc3MnICYmIHV1aWQpIHsKICAgICAgaWYgKCFfeHVpT2spIGF3YWl0IHh1aUxvZ2luKCk7CiAgICAgIC8vIOC4leC5ieC4reC4h+C4lOC4tuC4hyBjbGllbnQgZGF0YSDguYDguJXguYfguKHguIHguYjguK3guJkKICAgICAgY29uc3QgaWJMaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAgIGxldCBmb3VuZCA9IGZhbHNlOwogICAgICBpZiAoaWJMaXN0ICYmIGliTGlzdC5vYmopIHsKICAgICAgICBmb3IgKGNvbnN0IGliIG9mIGliTGlzdC5vYmopIHsKICAgICAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAgICAgY29uc3QgY2xpZW50ID0gKHNldHRpbmdzLmNsaWVudHN8fFtdKS5maW5kKGMgPT4gKGMuZW1haWx8fGMuaWQpID09PSB1c2VyKTsKICAgICAgICAgIGlmIChjbGllbnQpIHsKICAgICAgICAgICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytjbGllbnQuaWQsIHsKICAgICAgICAgICAgICBpZDogaWIuaWQsCiAgICAgICAgICAgICAgc2V0dGluZ3M6IEpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7CiAgICAgICAgICAgICAgICBpZDpjbGllbnQuaWQsIGZsb3c6Y2xpZW50LmZsb3d8fCcnLCBlbWFpbDpjbGllbnQuZW1haWx8fGNsaWVudC5pZCwKICAgICAgICAgICAgICAgIGxpbWl0SXA6Y2xpZW50LmxpbWl0SXB8fDAsIHRvdGFsR0I6Y2xpZW50LnRvdGFsR0J8fDAsCiAgICAgICAgICAgICAgICBleHBpcnlUaW1lOmNsaWVudC5leHBpcnlUaW1lfHwwLCBlbmFibGU6dHJ1ZSwKICAgICAgICAgICAgICAgIHRnSWQ6JycsIHN1YklkOicnLCBjb21tZW50OicnLCByZXNldDowCiAgICAgICAgICAgICAgfV19KQogICAgICAgICAgICB9KTsKICAgICAgICAgICAgaWYgKHJlcy5zdWNjZXNzKSB7IGZvdW5kID0gdHJ1ZTsgYnJlYWs7IH0KICAgICAgICAgIH0KICAgICAgICB9CiAgICAgIH0KICAgIH0KICAgIGF3YWl0IGZldGNoKEFQSSsnL3VuYmFuJywgewogICAgICBtZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJ9KQogICAgfSkuY2F0Y2goKCk9Pnt9KTsKICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4m+C4peC4lOC4peC5h+C4reC4hCAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBzZXRUaW1lb3V0KGxvYWRCYW5uZWRVc2VycywgODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCi8vIExlZ2FjeTog4Lii4Lix4LiH4LiE4LiHIGRlbGV0ZVNTSCDguYTguKfguYnguYPguIrguYnguIjguLLguIHguJfguLXguYjguK3guLfguYjguJkKYXN5bmMgZnVuY3Rpb24gZGVsZXRlU1NIKCkgewogIHJldHVybiB1bmJhblVzZXIoKTsKfQoKLy8g4LmC4Lir4Lil4LiUIFNTSCBVc2VycyDguKrguLPguKvguKPguLHguJogcmVmZXJlbmNlCmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hVc2VycygpIHsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICByZXR1cm4gZC51c2VycyB8fCBbXTsKICB9IGNhdGNoKGUpIHsgcmV0dXJuIFtdOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBDT1BZIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBjb3B5TGluayhpZCwgYnRuKSB7CiAgY29uc3QgdHh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHR4dCkudGhlbigoKT0+ewogICAgY29uc3Qgb3JpZyA9IGJ0bi50ZXh0Q29udGVudDsKICAgIGJ0bi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0ncmdiYSgzNCwxOTcsOTQsLjE1KSc7CiAgICBzZXRUaW1lb3V0KCgpPT57IGJ0bi50ZXh0Q29udGVudD1vcmlnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0nJzsgfSwgMjAwMCk7CiAgfSkuY2F0Y2goKCk9PnsgcHJvbXB0KCdDb3B5IGxpbms6JywgdHh0KTsgfSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBMT0dPVVQg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGRvTG9nb3V0KCkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIFVQREFURSDilZDilZDilZDilZAKbGV0IF91cGRhdGVBY3RpdmUgPSBmYWxzZTsKbGV0IF91cGRhdGVTaWQgPSBudWxsOwpsZXQgX3Byb21wdFRpbWVyID0gbnVsbDsKZnVuY3Rpb24gY2xlYXJVcGRhdGVMb2coKSB7CiAgY29uc3QgbG9nID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1sb2cnKTsKICBpZiAobG9nKSB7IGxvZy50ZXh0Q29udGVudCA9ICcnOyBsb2cuc3R5bGUuZGlzcGxheSA9ICdub25lJzsgfQogIGNvbnN0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1zdGF0dXMnKTsKICBpZiAoc3QpIHN0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgY29uc3QgcHcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLXByb2dyZXNzLXdyYXAnKTsKICBpZiAocHcpIHB3LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgaGlkZVVwZGF0ZUlucHV0KCk7Cn0KZnVuY3Rpb24gc2hvd1VwZGF0ZUlucHV0KGxhYmVsKSB7CiAgY29uc3Qgd3JhcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGRhdGUtaW5wdXQtd3JhcCcpOwogIGNvbnN0IGxibCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLWlucHV0LWxhYmVsJyk7CiAgY29uc3QgYm94ICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGRhdGUtaW5wdXQtYm94Jyk7CiAgaWYgKCF3cmFwKSByZXR1cm47CiAgaWYgKGxhYmVsKSBsYmwudGV4dENvbnRlbnQgPSBsYWJlbDsKICB3cmFwLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIGJveC52YWx1ZSA9ICcnOwogIHNldFRpbWVvdXQoKCk9PmJveC5mb2N1cygpLCA1MCk7Cn0KZnVuY3Rpb24gaGlkZVVwZGF0ZUlucHV0KCkgewogIGNvbnN0IHdyYXAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLWlucHV0LXdyYXAnKTsKICBpZiAod3JhcCkgd3JhcC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIGlmIChfcHJvbXB0VGltZXIpIHsgY2xlYXJUaW1lb3V0KF9wcm9tcHRUaW1lcik7IF9wcm9tcHRUaW1lciA9IG51bGw7IH0KfQphc3luYyBmdW5jdGlvbiBzZW5kVXBkYXRlSW5wdXQoZm9yY2VkKSB7CiAgaWYgKCFfdXBkYXRlU2lkKSByZXR1cm47CiAgY29uc3QgYm94ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1pbnB1dC1ib3gnKTsKICBjb25zdCB2YWwgPSAoZm9yY2VkICE9PSB1bmRlZmluZWQpID8gZm9yY2VkIDogKGJveCA/IGJveC52YWx1ZSA6ICcnKTsKICB0cnkgewogICAgYXdhaXQgZmV0Y2goQVBJICsgJy91cGRhdGVfaW5wdXQnLCB7CiAgICAgIG1ldGhvZDogJ1BPU1QnLAogICAgICBoZWFkZXJzOiB7ICdDb250ZW50LVR5cGUnOiAnYXBwbGljYXRpb24vanNvbicgfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoeyBzaWQ6IF91cGRhdGVTaWQsIGlucHV0OiB2YWwgfSkKICAgIH0pOwogICAgaWYgKGJveCkgYm94LnZhbHVlID0gJyc7CiAgICBoaWRlVXBkYXRlSW5wdXQoKTsKICB9IGNhdGNoKGUpIHsKICAgIGFsZXJ0KCfguKrguYjguIcgaW5wdXQg4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIOiAnICsgZS5tZXNzYWdlKTsKICB9Cn0KLy8g4LmA4LiK4LmH4LiE4Lin4LmI4LiyIHRleHQg4LiU4Li54LmA4Lir4Lih4Li34Lit4LiZIHByb21wdCDguJfguLXguYjguKPguK0gaW5wdXQg4LiI4Liy4LiBIHVzZXIg4Lir4Lij4Li34Lit4LmE4Lih4LmICmZ1bmN0aW9uIGxvb2tzTGlrZVByb21wdChidWYpIHsKICBpZiAoIWJ1ZikgcmV0dXJuIG51bGw7CiAgLy8g4LmA4Lit4Liy4LmA4LiJ4Lie4Liy4Liw4Lia4Lij4Lij4LiX4Lix4LiU4Liq4Li44LiU4LiX4LmJ4Liy4Lii4LiX4Li14LmI4Lii4Lix4LiH4LmE4Lih4LmI4Lih4Li1IG5ld2xpbmUKICBjb25zdCBpZHggPSBidWYubGFzdEluZGV4T2YoJ1xuJyk7CiAgY29uc3QgdGFpbCA9IChpZHggPj0gMCA/IGJ1Zi5zbGljZShpZHgrMSkgOiBidWYpLnJlcGxhY2UoL1x4MWJcW1swLTk7XSpbYS16QS1aXS9nLCcnKS50cmltKCk7CiAgaWYgKCF0YWlsKSByZXR1cm4gbnVsbDsKICAvLyBQYXR0ZXJuOiDguKXguIfguJfguYnguLLguKLguJTguYnguKfguKIgOiA/IF0gPiDguKvguKPguLfguK3guKHguLXguITguLPguKfguYjguLIgIuC4geC4o+C4uOC4k+C4siIgIuC5guC4m+C4o+C4lCIgIkVudGVyIiAiW1kvbl0iCiAgaWYgKC9bOj8+XF1dXHMqJC8udGVzdCh0YWlsKSkgcmV0dXJuIHRhaWw7CiAgaWYgKC9cW3lcL25cXXxcW1lcL25cXXxcW3lcL05cXS9pLnRlc3QodGFpbCkpIHJldHVybiB0YWlsOwogIGlmICgvKOC4geC4o+C4uOC4k+C4snzguYLguJvguKPguJR84LmD4Liq4LmIfOC4nuC4tOC4oeC4nuC5jHzguJvguYnguK3guJl84Lij4Liw4Lia4Li4KS4qWzo/XT9ccyokLy50ZXN0KHRhaWwpKSByZXR1cm4gdGFpbDsKICBpZiAoLyhlbnRlcnxpbnB1dHxwYXNzd29yZHx1c2VybmFtZXxkb21haW58ZW1haWwpL2kudGVzdCh0YWlsKSAmJiB0YWlsLmxlbmd0aCA8IDEyMCkgcmV0dXJuIHRhaWw7CiAgcmV0dXJuIG51bGw7Cn0KYXN5bmMgZnVuY3Rpb24gc3RhcnRVcGRhdGUoKSB7CiAgaWYgKF91cGRhdGVBY3RpdmUpIHJldHVybjsKICBjb25zdCB1cmwgPSAoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS11cmwnKS52YWx1ZSB8fCAnJykudHJpbSgpOwogIGlmICghdXJsLnN0YXJ0c1dpdGgoJ2h0dHBzOi8vJykpIHJldHVybiBhbGVydCgnVVJMIOC5hOC4oeC5iOC4luC4ueC4geC4leC5ieC4reC4hycpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGRhdGUtYnRuJyk7CiAgY29uc3QgbG9nID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1sb2cnKTsKICBjb25zdCBzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGRhdGUtc3RhdHVzJyk7CiAgY29uc3QgcHcgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkYXRlLXByb2dyZXNzLXdyYXAnKTsKICBjb25zdCBwYmFyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1wcm9ncmVzcy1iYXInKTsKICBjb25zdCBwbGJsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZGF0ZS1wcm9ncmVzcy1sYWJlbCcpOwogIF91cGRhdGVBY3RpdmUgPSB0cnVlOwogIF91cGRhdGVTaWQgPSBudWxsOwogIGhpZGVVcGRhdGVJbnB1dCgpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPiDguIHguLPguKXguLHguIcgVXBkYXRlLi4uJzsKICBsb2cudGV4dENvbnRlbnQgPSAnJzsKICBsb2cuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgcHcuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgcGJhci5zdHlsZS53aWR0aCA9ICc1JSc7CiAgcGxibC50ZXh0Q29udGVudCA9ICfguIHguLPguKXguLHguIfguYDguIrguLfguYjguK3guKHguJXguYjguK0uLi4nOwogIHN0LnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgbGV0IGxpbmVDb3VudCA9IDA7CiAgdHJ5IHsKICAgIGNvbnN0IHJlc3AgPSBhd2FpdCBmZXRjaChBUEkgKyAnL3VwZGF0ZScsIHsKICAgICAgbWV0aG9kOiAnUE9TVCcsCiAgICAgIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJyB9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7IHVybCB9KQogICAgfSk7CiAgICBpZiAoIXJlc3Aub2sgfHwgIXJlc3AuYm9keSkgdGhyb3cgbmV3IEVycm9yKCdTZXJ2ZXIg4LmE4Lih4LmI4LiV4Lit4Lia4Liq4LiZ4Lit4LiHJyk7CiAgICBjb25zdCByZWFkZXIgPSByZXNwLmJvZHkuZ2V0UmVhZGVyKCk7CiAgICBjb25zdCBkZWNvZGVyID0gbmV3IFRleHREZWNvZGVyKCd1dGYtOCcpOwogICAgbGV0IGRvbmUgPSBmYWxzZSwgYnVmID0gJyc7CiAgICBsZXQgcHJvZyA9IDU7CiAgICAvLyDguYDguIHguYfguJogInRhaWwiIOC4l+C4teC5iOC4ouC4seC4h+C5hOC4oeC5iOC4oeC4tSBuZXdsaW5lIOKAlCDguYPguIrguYkgZGV0ZWN0IHByb21wdAogICAgbGV0IHRhaWxTaW5jZU5ld2xpbmUgPSAnJzsKICAgIC8vIGhlbHBlcjogYXBwZW5kIHJhdyB0ZXh0IOC5hOC4m+C4ouC4seC4hyBsb2cgKOC4nuC4o+C5ieC4reC4oSBjb2xvcikKICAgIGNvbnN0IGFwcGVuZExvZyA9ICh0eHQpID0+IHsKICAgICAgaWYgKHR4dC5pbmNsdWRlcygnW09LXScpIHx8IHR4dC5pbmNsdWRlcygn4pyFJykgfHwgdHh0LmluY2x1ZGVzKCfguKrguLPguYDguKPguYfguIgnKSkgewogICAgICAgIGxvZy5pbm5lckhUTUwgKz0gJzxzcGFuIHN0eWxlPSJjb2xvcjojNGFkZTgwIj4nICsgZXNjSHRtbCh0eHQpICsgJzwvc3Bhbj4nOwogICAgICB9IGVsc2UgaWYgKHR4dC5pbmNsdWRlcygnW0VSUl0nKSB8fCB0eHQuaW5jbHVkZXMoJ0VSUicpIHx8IHR4dC5pbmNsdWRlcygn4Lil4LmJ4Lih4LmA4Lir4Lil4LinJykpIHsKICAgICAgICBsb2cuaW5uZXJIVE1MICs9ICc8c3BhbiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JyArIGVzY0h0bWwodHh0KSArICc8L3NwYW4+JzsKICAgICAgfSBlbHNlIGlmICh0eHQuaW5jbHVkZXMoJ1tJTkZPXScpIHx8IHR4dC5pbmNsdWRlcygnW1dBUk5dJykpIHsKICAgICAgICBsb2cuaW5uZXJIVE1MICs9ICc8c3BhbiBzdHlsZT0iY29sb3I6I2ZiYmYyNCI+JyArIGVzY0h0bWwodHh0KSArICc8L3NwYW4+JzsKICAgICAgfSBlbHNlIHsKICAgICAgICBsb2cuaW5uZXJIVE1MICs9IGVzY0h0bWwodHh0KTsKICAgICAgfQogICAgICBsb2cuc2Nyb2xsVG9wID0gbG9nLnNjcm9sbEhlaWdodDsKICAgIH07CiAgICAvLyDguKvguKXguLHguIcgc3RyZWFtIOC5gOC4h+C4teC4ouC4miA1MDBtcyDguYHguKXguLDguKHguLUgdGFpbCDguITguYnguLLguIfguK3guKLguLnguYgg4oaSIOC4luC4t+C4reC4p+C5iOC4suC5gOC4m+C5h+C4mSBwcm9tcHQKICAgIGNvbnN0IHNjaGVkdWxlUHJvbXB0Q2hlY2sgPSAoKSA9PiB7CiAgICAgIGlmIChfcHJvbXB0VGltZXIpIGNsZWFyVGltZW91dChfcHJvbXB0VGltZXIpOwogICAgICBfcHJvbXB0VGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICBjb25zdCBwID0gbG9va3NMaWtlUHJvbXB0KHRhaWxTaW5jZU5ld2xpbmUpOwogICAgICAgIGlmIChwICYmIF91cGRhdGVBY3RpdmUgJiYgX3VwZGF0ZVNpZCkgc2hvd1VwZGF0ZUlucHV0KHApOwogICAgICB9LCA1MDApOwogICAgfTsKICAgIHdoaWxlICghZG9uZSkgewogICAgICBjb25zdCB7IHZhbHVlLCBkb25lOiBkIH0gPSBhd2FpdCByZWFkZXIucmVhZCgpOwogICAgICBkb25lID0gZDsKICAgICAgaWYgKHZhbHVlKSB7CiAgICAgICAgY29uc3QgY2h1bmsgPSBkZWNvZGVyLmRlY29kZSh2YWx1ZSwgeyBzdHJlYW06IHRydWUgfSk7CiAgICAgICAgYnVmICs9IGNodW5rOwogICAgICAgIC8vIOC4reC4seC4nuC5gOC4lOC4lSB0YWlsIHRyYWNraW5nCiAgICAgICAgZm9yIChjb25zdCBjaCBvZiBjaHVuaykgewogICAgICAgICAgaWYgKGNoID09PSAnXG4nKSB0YWlsU2luY2VOZXdsaW5lID0gJyc7CiAgICAgICAgICBlbHNlIHRhaWxTaW5jZU5ld2xpbmUgKz0gY2g7CiAgICAgICAgfQogICAgICAgIC8vIOC5geC4ouC4gSBzZXNzaW9uIGlkIOC4muC4o+C4o+C4l+C4seC4lOC5geC4o+C4gSAo4LiW4LmJ4Liy4Lih4Li1KQogICAgICAgIGlmICghX3VwZGF0ZVNpZCkgewogICAgICAgICAgY29uc3Qgc2lkTWF0Y2ggPSBidWYubWF0Y2goL15fX1NJRF9fOihbYS1mMC05XSspXG4vKTsKICAgICAgICAgIGlmIChzaWRNYXRjaCkgewogICAgICAgICAgICBfdXBkYXRlU2lkID0gc2lkTWF0Y2hbMV07CiAgICAgICAgICAgIGJ1ZiA9IGJ1Zi5zbGljZShzaWRNYXRjaFswXS5sZW5ndGgpOwogICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBjb25zdCBsaW5lcyA9IGJ1Zi5zcGxpdCgnXG4nKTsKICAgICAgICBidWYgPSBsaW5lcy5wb3AoKTsKICAgICAgICBsZXQgc3RvcExvb3AgPSBmYWxzZTsKICAgICAgICBmb3IgKGNvbnN0IGxpbmUgb2YgbGluZXMpIHsKICAgICAgICAgIGxpbmVDb3VudCsrOwogICAgICAgICAgY29uc3QgdHh0ID0gbGluZSArICdcbic7CiAgICAgICAgICAvLyDguIvguYjguK3guJkgaW5wdXQgYm94IOC5gOC4oeC4t+C5iOC4reC4oeC4teC4muC4o+C4o+C4l+C4seC4lOC5g+C4q+C4oeC5iCAodXNlciDguJXguK3guJrguYHguKXguYnguKcg4Lir4Lij4Li34Lit4Lih4Li1IG91dHB1dCDguJXguYjguK0pCiAgICAgICAgICBoaWRlVXBkYXRlSW5wdXQoKTsKICAgICAgICAgIGFwcGVuZExvZyh0eHQpOwogICAgICAgICAgcHJvZyA9IE1hdGgubWluKDk1LCBwcm9nICsgMC4zKTsKICAgICAgICAgIHBiYXIuc3R5bGUud2lkdGggPSBwcm9nICsgJyUnOwogICAgICAgICAgaWYgKHR4dC5pbmNsdWRlcygnX19ET05FX09LX18nKSkgewogICAgICAgICAgICBwYmFyLnN0eWxlLndpZHRoID0gJzEwMCUnOyBwYmFyLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCMyMmM1NWUsIzRhZGU4MCknOwogICAgICAgICAgICBwbGJsLnRleHRDb250ZW50ID0gJ+KchSDguK3guLHguJ7guYDguJTguJXguKrguLPguYDguKPguYfguIghJzsgcGxibC5zdHlsZS5jb2xvciA9ICcjMjJjNTVlJzsKICAgICAgICAgICAgc3QuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImFsZXJ0IG9rIiBzdHlsZT0iZGlzcGxheTpibG9jayI+4pyFIOC4reC4seC4nuC5gOC4lOC4leC5gOC4quC4o+C5h+C4iOC4quC4tOC5ieC4mSDigJQg4LiB4Lij4Li44LiT4LiyIFJlZnJlc2gg4Lir4LiZ4LmJ4LiyPC9kaXY+JzsKICAgICAgICAgICAgc3RvcExvb3AgPSB0cnVlOyBicmVhazsKICAgICAgICAgIH0KICAgICAgICAgIGlmICh0eHQuaW5jbHVkZXMoJ19fRE9ORV9MQVRFU1RfXycpKSB7CiAgICAgICAgICAgIHBiYXIuc3R5bGUud2lkdGggPSAnMTAwJSc7IHBiYXIuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSc7CiAgICAgICAgICAgIHBsYmwudGV4dENvbnRlbnQgPSAn4pyFIOC5gOC4p+C4reC4o+C5jOC4iuC4seC5iOC4meC4peC5iOC4suC4quC4uOC4lOC5geC4peC5ieC4pyc7IHBsYmwuc3R5bGUuY29sb3IgPSAnIzNiODJmNic7CiAgICAgICAgICAgIHN0LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJhbGVydCBvayIgc3R5bGU9ImRpc3BsYXk6YmxvY2s7YmFja2dyb3VuZDojZWZmNmZmO2JvcmRlci1jb2xvcjojOTNjNWZkO2NvbG9yOiMxZDRlZDgiPuKchSBTY3JpcHQg4LmA4Lib4LmH4LiZ4LmA4Lin4Lit4Lij4LmM4LiK4Lix4LmI4LiZ4Lil4LmI4Liy4Liq4Li44LiU4LmB4Lil4LmJ4LinIOC5hOC4oeC5iOC4iOC4s+C5gOC4m+C5h+C4meC4leC5ieC4reC4h+C4reC4seC4nuC5gOC4lOC4lTwvZGl2Pic7CiAgICAgICAgICAgIHN0b3BMb29wID0gdHJ1ZTsgYnJlYWs7CiAgICAgICAgICB9CiAgICAgICAgICBpZiAodHh0LmluY2x1ZGVzKCdfX0RPTkVfRkFJTF9fJykpIHsKICAgICAgICAgICAgcGJhci5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpJzsKICAgICAgICAgICAgcGxibC50ZXh0Q29udGVudCA9ICfinYwg4Lit4Lix4Lie4LmA4LiU4LiV4Lil4LmJ4Lih4LmA4Lir4Lil4LinJzsgcGxibC5zdHlsZS5jb2xvciA9ICcjZWY0NDQ0JzsKICAgICAgICAgICAgc3QuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImFsZXJ0IGVyciIgc3R5bGU9ImRpc3BsYXk6YmxvY2siPuKdjCDguK3guLHguJ7guYDguJTguJXguKXguYnguKHguYDguKvguKXguKcg4LiU4Li5IExvZyDguJTguYnguLLguJnguJrguJk8L2Rpdj4nOwogICAgICAgICAgICBzdG9wTG9vcCA9IHRydWU7IGJyZWFrOwogICAgICAgICAgfQogICAgICAgIH0KICAgICAgICBpZiAoc3RvcExvb3ApIGJyZWFrOwogICAgICAgIC8vIOC5geC4quC4lOC4hyB0YWlsIOC4l+C4teC5iOC4ouC4seC4h+C5hOC4oeC5iOC4oeC4tSBuZXdsaW5lIOC4peC4h+C5g+C4mSBsb2cgKHByb21wdCB0ZXh0KSArIOC4leC4seC5ieC4hyBwcm9tcHQgY2hlY2sKICAgICAgICBpZiAoYnVmKSB7CiAgICAgICAgICAvLyDguYHguKrguJTguIcgcGFydGlhbCBsaW5lOiBhcHBlbmQg4LiV4LmI4Lit4LiX4LmJ4Liy4Lii4LmB4LiV4LmI4LiI4Liw4LiW4Li54LiBIG92ZXJ3cml0ZSDguYDguKHguLfguYjguK3guKHguLUgbmV3bGluZSDguIjguKPguLTguIcKICAgICAgICAgIC8vIOC5g+C4iuC5iSBhcHByb2FjaDogYXBwZW5kIOC5gOC4ieC4nuC4suC4sOC4quC5iOC4p+C4meC4l+C4teC5iOC4ouC4seC4h+C5hOC4oeC5iOC5hOC4lOC5ieC5geC4quC4lOC4hwogICAgICAgICAgY29uc3Qgc2hvd24gPSBsb2cuZGF0YXNldC5wYXJ0aWFsIHx8ICcnOwogICAgICAgICAgaWYgKGJ1ZiAhPT0gc2hvd24pIHsKICAgICAgICAgICAgLy8g4Lil4LiaIHBhcnRpYWwg4LmA4LiB4LmI4LiyIOC5geC4peC5ieC4p+C5g+C4quC5iOC5g+C4q+C4oeC5iAogICAgICAgICAgICBpZiAoc2hvd24gJiYgbG9nLmlubmVySFRNTC5lbmRzV2l0aCgnPHNwYW4gY2xhc3M9InVwZC1wYXJ0aWFsIj4nICsgZXNjSHRtbChzaG93bikgKyAnPC9zcGFuPicpKSB7CiAgICAgICAgICAgICAgbG9nLmlubmVySFRNTCA9IGxvZy5pbm5lckhUTUwuc2xpY2UoMCwgbG9nLmlubmVySFRNTC5sZW5ndGggLSAoJzxzcGFuIGNsYXNzPSJ1cGQtcGFydGlhbCI+JyArIGVzY0h0bWwoc2hvd24pICsgJzwvc3Bhbj4nKS5sZW5ndGgpOwogICAgICAgICAgICB9CiAgICAgICAgICAgIGxvZy5pbm5lckhUTUwgKz0gJzxzcGFuIGNsYXNzPSJ1cGQtcGFydGlhbCIgc3R5bGU9ImNvbG9yOiNmYmJmMjQiPicgKyBlc2NIdG1sKGJ1ZikgKyAnPC9zcGFuPic7CiAgICAgICAgICAgIGxvZy5kYXRhc2V0LnBhcnRpYWwgPSBidWY7CiAgICAgICAgICAgIGxvZy5zY3JvbGxUb3AgPSBsb2cuc2Nyb2xsSGVpZ2h0OwogICAgICAgICAgfQogICAgICAgICAgc2NoZWR1bGVQcm9tcHRDaGVjaygpOwogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICBsb2cuZGF0YXNldC5wYXJ0aWFsID0gJyc7CiAgICAgICAgfQogICAgICB9CiAgICB9CiAgfSBjYXRjaChlKSB7CiAgICBsb2cuaW5uZXJIVE1MICs9ICc8c3BhbiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+W0VSUl0gJyArIGVzY0h0bWwoZS5tZXNzYWdlKSArICdcbjwvc3Bhbj4nOwogICAgcGxibC50ZXh0Q29udGVudCA9ICfinYwg4LmA4LiB4Li04LiU4LiC4LmJ4Lit4Lic4Li04LiU4Lie4Lil4Liy4LiUJzsgcGxibC5zdHlsZS5jb2xvciA9ICcjZWY0NDQ0JzsKICAgIHN0LmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJhbGVydCBlcnIiIHN0eWxlPSJkaXNwbGF5OmJsb2NrIj7inYwgJyArIGVzY0h0bWwoZS5tZXNzYWdlKSArICc8L2Rpdj4nOwogIH0gZmluYWxseSB7CiAgICBfdXBkYXRlQWN0aXZlID0gZmFsc2U7CiAgICBfdXBkYXRlU2lkID0gbnVsbDsKICAgIGhpZGVVcGRhdGVJbnB1dCgpOwogICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICBidG4uaW5uZXJIVE1MID0gJ+Kshu+4jyDguYDguKPguLTguYjguKEgVXBkYXRlJzsKICB9Cn0KZnVuY3Rpb24gc3RyaXBBbnNpKHMpIHsKICByZXR1cm4gcy5yZXBsYWNlKC9ceDFiXFtbMC05O10qW21HS0hGXS9nLCAnJykucmVwbGFjZSgvXFtcZCs7P1xkKm0vZywgJycpOwp9CmZ1bmN0aW9uIGVzY0h0bWwocykgewogIHJldHVybiBzdHJpcEFuc2kocykucmVwbGFjZSgvJi9nLCcmYW1wOycpLnJlcGxhY2UoLzwvZywnJmx0OycpLnJlcGxhY2UoLz4vZywnJmd0OycpOwp9CgovLyDilZDilZDilZDilZAgSU5JVCDilZDilZDilZDilZAKbG9hZERhc2goKTsKbG9hZFNlcnZpY2VzKCk7CgovLyBSZWFsdGltZSBwb2xsaW5nIOKAlCBzZXJ2aWNlcyDguJfguLjguIEgOCDguKfguLQgKEFQSSDguYDguJrguLIpLCBkYXNoYm9hcmQg4LiX4Li44LiBIDE1IOC4p+C4tApzZXRJbnRlcnZhbChhc3luYyBmdW5jdGlvbigpIHsKICB0cnkgewogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICByZW5kZXJTZXJ2aWNlcyhzdCA/IChzdC5zZXJ2aWNlcyB8fCB7fSkgOiBudWxsKTsKICB9IGNhdGNoKGUpIHt9Cn0sIDgwMDApOwoKc2V0SW50ZXJ2YWwobG9hZERhc2gsIDE1MDAwKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=
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
# restart dropbear อีกครั้งเพื่อให้แน่ใจ (บางครั้ง race condition ตอนติดตั้ง)
systemctl restart dropbear 2>/dev/null || true
sleep 5

for svc in nginx x-ui dropbear chaiya-sshws chaiya-ssh-api chaiya-badvpn; do
  if systemctl is-active --quiet "$svc"; then
    ok "$svc ✅"
  else
    warn "$svc ⚠️"
    journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
  fi
done

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   CHAIYA VPN PANEL v8 - ติดตั้งสำเร็จ! 🚀  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
if [[ $USE_SSL -eq 1 ]]; then
  echo -e "  🌐 Panel URL   : ${CYAN}${BOLD}https://${DOMAIN}${NC}"
  echo -e "  🔒 SSL         : ${GREEN}✅ HTTPS พร้อม${NC}"
else
  echo -e "  🌐 Panel URL   : ${YELLOW}http://${DOMAIN}:443 (ยังไม่มี SSL)${NC}"
  echo -e "  🔒 SSL         : ${YELLOW}⚠️  ยังไม่มี${NC}"
  echo -e "              รัน: certbot certonly --standalone -d ${DOMAIN}"
fi
echo -e "  👤 3x-ui User  : ${YELLOW}${XUI_USER}${NC}"
echo -e "  🔒 3x-ui Pass  : ${YELLOW}${XUI_PASS}${NC}"
if [[ $USE_SSL -eq 1 ]]; then
  echo -e "  🖥  3x-ui Panel : ${CYAN}${BOLD}https://${DOMAIN}:2503/${NC} (ผ่าน nginx proxy)"
else
  echo -e "  🖥  3x-ui Panel : ${CYAN}${BOLD}http://${DOMAIN}:2503/${NC} (ผ่าน nginx proxy)"
fi
echo -e "  🐻 Dropbear    : ${CYAN}port 143, 109${NC}"
echo -e "  🌐 WS-Tunnel   : ${CYAN}port 80 → Dropbear:143${NC}"
echo -e "  🎮 BadVPN UDPGW: ${CYAN}port 7300${NC}"
echo -e "  📡 VMess-WS    : ${CYAN}port 8080, path /vmess${NC}"
echo -e "  📡 VLESS-WS    : ${CYAN}port 8880, path /vless${NC}"
echo ""
echo -e "  💡 พิมพ์ ${CYAN}menu${NC} เพื่อดูรายละเอียด"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
