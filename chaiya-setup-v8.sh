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

# ── FORCE FREE PORTS ─────────────────────────────────────────
# พอร์ตทุกตัวที่สคริปต์ใช้ — ถ้ามี process อื่นจับอยู่ให้ kill ทันที
_REQUIRED_PORTS=(80 109 143 443 2503 7300 8080 8880 54321 6789)  # ไม่รวม 22 — ห้าม kill SSH
for _port in "${_REQUIRED_PORTS[@]}"; do
  # หา pid ทุกตัวที่ฟังอยู่บน port นั้น (TCP)
  _pids=$(lsof -ti tcp:$_port 2>/dev/null)
  if [[ -z "$_pids" ]]; then
    _pids=$(fuser $_port/tcp 2>/dev/null)
  fi
  if [[ -n "$_pids" ]]; then
    for _pid in $_pids; do
      _pname=$(ps -p $_pid -o comm= 2>/dev/null || echo "unknown")
      warn "Port $_port ถูกใช้โดย $_pname (PID $_pid) — kill ทันที"
      kill -9 "$_pid" 2>/dev/null || true
    done
  fi
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
  for _key in webPort webUsername webPassword webBasePath; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPort','${XUI_PORT}');"          2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webBasePath','/');"                2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webUsername','${XUI_USER}');"      2>/dev/null || true
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

# รอ x-ui พร้อม — อ่าน port จาก DB ที่เราตั้งไว้เสมอ (ไม่ใช้ ss เพราะอาจได้ port เก่า)
REAL_XUI_PORT="$XUI_PORT"
_db_port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
[[ -n "$_db_port" ]] && REAL_XUI_PORT="$_db_port"
for _i in $(seq 1 15); do
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
  # force webPort + basePath ซ้ำหลัง x-ui start เพราะ x-ui อาจ overwrite ค่าตอน init
  for _key in webPort webBasePath enableIpLimit enableTrafficStatistics timeLocation trafficDiffReset; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webPort','${XUI_PORT}');"            2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webBasePath','/');"                  2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('enableIpLimit','true');"             2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('enableTrafficStatistics','true');"   2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('timeLocation','Asia/Bangkok');"      2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('trafficDiffReset','false');"         2>/dev/null || true
  # ยืนยัน
  _port_check=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
  _ip_setting=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='enableIpLimit';" 2>/dev/null)
  [[ "$_port_check" == "${XUI_PORT}" ]] && ok "x-ui webPort=${XUI_PORT} ยืนยันแล้ว" || warn "webPort อาจไม่ถูกต้อง: $_port_check"
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

        if self.path == '/api/login':
            u = data.get('username', '').strip()
            p = data.get('password', '').strip()
            stored_u = open('/etc/chaiya/xui-user.conf').read().strip() if os.path.exists('/etc/chaiya/xui-user.conf') else ''
            stored_p = open('/etc/chaiya/xui-pass.conf').read().strip() if os.path.exists('/etc/chaiya/xui-pass.conf') else ''
            if u == stored_u and p == stored_p:
                return respond(self, 200, {'ok': True, 'success': True})
            return respond(self, 401, {'ok': False, 'error': 'invalid credentials'})

        elif self.path == '/api/create_ssh':
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

# เปิดพอร์ตที่ต้องใช้งาน (public)
for port in 22 80 109 143 443 2503 8080 8880; do
  ufw allow "$port"/tcp &>/dev/null
  ok "ufw allow $port/tcp"
done

# 7300/udp สำหรับ badvpn-udpgw (client tunnel ผ่าน SSH มา)
ufw allow 7300/udp &>/dev/null
ok "ufw allow 7300/udp"

# ปิดพอร์ต internal — ห้ามเข้าจากนอก
for port in 6789 54321 8888; do
  ufw deny "$port"/tcp &>/dev/null
done

ufw --force enable &>/dev/null

# ยืนยันว่าพอร์ตสำคัญเปิดอยู่จริง
info "ตรวจสอบพอร์ต..."
for port in 22 80 109 143 443 2503 8080 8880; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} " ||      ufw status | grep -q "^${port}"; then
    ok "port $port พร้อม"
  else
    warn "port $port ยังไม่มี service ฟัง (อาจปกติถ้า service ยังไม่ start)"
  fi
done
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
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFBST0pFQ1Qg4oCTIExvZ2luPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1PcmJpdHJvbjp3Z2h0QDQwMDs3MDA7OTAwJmZhbWlseT1TYXJhYnVuOndnaHRAMzAwOzQwMDs2MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c3R5bGU+CiAgOnJvb3QgewogICAgLS1wdXJwbGU6ICM3YzNhZWQ7CiAgICAtLXB1cnBsZS1saWdodDogI2E4NTVmNzsKICAgIC0tYmx1ZTogIzI1NjNlYjsKICAgIC0tYmx1ZS1saWdodDogIzYwYTVmYTsKICAgIC0tY3lhbjogIzA2YjZkNDsKICAgIC0tZGFyazogIzAzMDUwZjsKICAgIC0tZGFyazI6ICMwODBkMWY7CiAgICAtLWNhcmQtYmc6IHJnYmEoMTAsMTUsNDAsMC44NSk7CiAgICAtLWJvcmRlcjogcmdiYSgxMjQsNTgsMjM3LDAuNCk7CiAgICAtLWdsb3ctcHVycGxlOiByZ2JhKDEyNCw1OCwyMzcsMC42KTsKICAgIC0tZ2xvdy1ibHVlOiByZ2JhKDM3LDk5LDIzNSwwLjUpOwogICAgLS10ZXh0OiAjZTJlOGYwOwogICAgLS1tdXRlZDogcmdiYSgxODAsMTkwLDIyMCwwLjUpOwogIH0KCiAgKiB7IG1hcmdpbjowOyBwYWRkaW5nOjA7IGJveC1zaXppbmc6Ym9yZGVyLWJveDsgfQoKICBib2R5IHsKICAgIG1pbi1oZWlnaHQ6IDEwMHZoOwogICAgYmFja2dyb3VuZDogdmFyKC0tZGFyayk7CiAgICBmb250LWZhbWlseTogJ1NhcmFidW4nLCBzYW5zLXNlcmlmOwogICAgY29sb3I6IHZhcigtLXRleHQpOwogICAgZGlzcGxheTogZmxleDsKICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG92ZXJmbG93OiBoaWRkZW47CiAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgfQoKICAvKiDilIDilIAgQmFja2dyb3VuZCDilIDilIAgKi8KICAuYmcgewogICAgcG9zaXRpb246IGZpeGVkOwogICAgaW5zZXQ6IDA7CiAgICBiYWNrZ3JvdW5kOgogICAgICByYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUsIHJnYmEoMTI0LDU4LDIzNywwLjI1KSAwJSwgdHJhbnNwYXJlbnQgNjAlKSwKICAgICAgcmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLCByZ2JhKDM3LDk5LDIzNSwwLjIpIDAlLCB0cmFuc3BhcmVudCA2MCUpLAogICAgICByYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA0MCUgNDAlIGF0IDUwJSA1MCUsIHJnYmEoNiwxODIsMjEyLDAuMDgpIDAlLCB0cmFuc3BhcmVudCA3MCUpLAogICAgICBsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCAjMDMwNTBmIDAlLCAjMDgwZDFmIDUwJSwgIzA1MDgxMCAxMDAlKTsKICAgIHotaW5kZXg6IDA7CiAgfQoKICAvKiBncmlkIGxpbmVzICovCiAgLmJnOjpiZWZvcmUgewogICAgY29udGVudDogJyc7CiAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICBpbnNldDogMDsKICAgIGJhY2tncm91bmQtaW1hZ2U6CiAgICAgIGxpbmVhci1ncmFkaWVudChyZ2JhKDEyNCw1OCwyMzcsMC4wNikgMXB4LCB0cmFuc3BhcmVudCAxcHgpLAogICAgICBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHJnYmEoMTI0LDU4LDIzNywwLjA2KSAxcHgsIHRyYW5zcGFyZW50IDFweCk7CiAgICBiYWNrZ3JvdW5kLXNpemU6IDUwcHggNTBweDsKICAgIGFuaW1hdGlvbjogZ3JpZE1vdmUgMjBzIGxpbmVhciBpbmZpbml0ZTsKICB9CgogIEBrZXlmcmFtZXMgZ3JpZE1vdmUgewogICAgMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoNTBweCk7IH0KICB9CgogIC8qIOKUgOKUgCBGaXJlZmxpZXMg4pSA4pSAICovCiAgLmZpcmVmbHkgewogICAgcG9zaXRpb246IGZpeGVkOwogICAgYm9yZGVyLXJhZGl1czogNTAlOwogICAgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgICBhbmltYXRpb246IGZmLWRyaWZ0IGxpbmVhciBpbmZpbml0ZSwgZmYtYmxpbmsgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICBvcGFjaXR5OiAwOwogIH0KCiAgQGtleWZyYW1lcyBmZi1kcmlmdCB7CiAgICAwJSAgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUoMCwgMCkgc2NhbGUoMSk7IH0KICAgIDIwJSAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSh2YXIoLS1keDEpLCB2YXIoLS1keTEpKSBzY2FsZSgxLjEpOyB9CiAgICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgyKSwgdmFyKC0tZHkyKSkgc2NhbGUoMC45KTsgfQogICAgNjAlICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKHZhcigtLWR4MyksIHZhcigtLWR5MykpIHNjYWxlKDEuMDUpOyB9CiAgICA4MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHg0KSwgdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLCAwKSBzY2FsZSgxKTsgfQogIH0KCiAgQGtleWZyYW1lcyBmZi1ibGluayB7CiAgICAwJSwxMDAlIHsgb3BhY2l0eTogMDsgfQogICAgMTUlICAgICB7IG9wYWNpdHk6IDA7IH0KICAgIDMwJSAgICAgeyBvcGFjaXR5OiAxOyB9CiAgICA1MCUgICAgIHsgb3BhY2l0eTogMC45OyB9CiAgICA2NSUgICAgIHsgb3BhY2l0eTogMDsgfQogICAgODAlICAgICB7IG9wYWNpdHk6IDAuODU7IH0KICAgIDkwJSAgICAgeyBvcGFjaXR5OiAwOyB9CiAgfQoKICAvKiDilIDilIAgTG9nbyBhcmVhIOKUgOKUgCAqLwogIC5sb2dvLXdyYXAgewogICAgdGV4dC1hbGlnbjogY2VudGVyOwogICAgbWFyZ2luLWJvdHRvbTogMjRweDsKICAgIGFuaW1hdGlvbjogZmFkZURvd24gMC44cyBlYXNlIGJvdGg7CiAgfQoKICAvKiBTaWduYWwgUHVsc2UgbG9nbyBhbmltYXRpb25zICovCiAgQGtleWZyYW1lcyBvcmJpdC1kYXNoIHsKICAgIGZyb20geyBzdHJva2UtZGFzaG9mZnNldDogMDsgfQogICAgdG8gICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAtMjUxOyB9CiAgfQogIEBrZXlmcmFtZXMgcHVsc2UtZHJhdyB7CiAgICAwJSAgIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDIyMDsgb3BhY2l0eTogMDsgfQogICAgMTUlICB7IG9wYWNpdHk6IDE7IH0KICAgIDEwMCUgeyBzdHJva2UtZGFzaG9mZnNldDogMDsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGJsaW5rLWRvdCB7CiAgICAwJSwgMTAwJSB7IG9wYWNpdHk6IDAuMjU7IH0KICAgIDUwJSAgICAgICB7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBsb2dvLWdsb3cgewogICAgMCUsIDEwMCUgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA2cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDE0cHggIzI1NjNlYik7IH0KICAgIDUwJSAgICAgICB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDE0cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDI4cHggIzI1NjNlYikgZHJvcC1zaGFkb3coMCAwIDQycHggIzA2YjZkNCk7IH0KICB9CgogIC5sb2dvLXN2Zy13cmFwIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDEwcHg7CiAgICBhbmltYXRpb246IGxvZ28tZ2xvdyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CgogIC5vcmJpdC1yaW5nLWFuaW0gewogICAgdHJhbnNmb3JtLW9yaWdpbjogNTBweCA1MHB4OwogICAgYW5pbWF0aW9uOiBvcmJpdC1kYXNoIDhzIGxpbmVhciBpbmZpbml0ZTsKICB9CgogIC53YXZlLWFuaW0gewogICAgc3Ryb2tlLWRhc2hhcnJheTogMjIwOwogICAgc3Ryb2tlLWRhc2hvZmZzZXQ6IDIyMDsKICAgIGFuaW1hdGlvbjogcHVsc2UtZHJhdyAxLjZzIGN1YmljLWJlemllciguNCwwLC4yLDEpIDAuNXMgZm9yd2FyZHM7CiAgfQoKICAuZG90LWFuaW0tMSB7IGFuaW1hdGlvbjogYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMS44cyBpbmZpbml0ZTsgfQogIC5kb3QtYW5pbS0yIHsgYW5pbWF0aW9uOiBibGluay1kb3QgMi4ycyBlYXNlLWluLW91dCAyLjJzIGluZmluaXRlOyB9CgogIC8qIOKUgOKUgCBDYXJkIOKUgOKUgCAqLwogIC5jYXJkIHsKICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgIHotaW5kZXg6IDEwOwogICAgd2lkdGg6IDEwMCU7CiAgICBtYXgtd2lkdGg6IDQwMHB4OwogICAgcGFkZGluZzogMzJweCAyOHB4OwogICAgYmFja2dyb3VuZDogdmFyKC0tY2FyZC1iZyk7CiAgICBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoMjBweCk7CiAgICBib3JkZXItcmFkaXVzOiAyMHB4OwogICAgYm9yZGVyOiAxcHggc29saWQgdmFyKC0tYm9yZGVyKTsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgMCAwIDFweCByZ2JhKDEyNCw1OCwyMzcsMC4xKSwKICAgICAgMCAyMHB4IDYwcHggcmdiYSgwLDAsMCwwLjYpLAogICAgICBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7CiAgICBhbmltYXRpb246IGZhZGVVcCAwLjhzIGVhc2UgYm90aCAwLjJzOwogICAgbWFyZ2luOiAyMHB4OwogIH0KCiAgLyogY29ybmVyIGRlY29yYXRpb25zICovCiAgLmNhcmQ6OmJlZm9yZSwgLmNhcmQ6OmFmdGVyIHsKICAgIGNvbnRlbnQ6ICcnOwogICAgcG9zaXRpb246IGFic29sdXRlOwogICAgd2lkdGg6IDIwcHg7CiAgICBoZWlnaHQ6IDIwcHg7CiAgICBib3JkZXItY29sb3I6IHZhcigtLXB1cnBsZS1saWdodCk7CiAgICBib3JkZXItc3R5bGU6IHNvbGlkOwogIH0KICAuY2FyZDo6YmVmb3JlIHsgdG9wOiAtMXB4OyBsZWZ0OiAtMXB4OyBib3JkZXItd2lkdGg6IDJweCAwIDAgMnB4OyBib3JkZXItcmFkaXVzOiA0cHggMCAwIDA7IH0KICAuY2FyZDo6YWZ0ZXIgeyBib3R0b206IC0xcHg7IHJpZ2h0OiAtMXB4OyBib3JkZXItd2lkdGg6IDAgMnB4IDJweCAwOyBib3JkZXItcmFkaXVzOiAwIDAgNHB4IDA7IH0KCiAgQGtleWZyYW1lcyBmYWRlVXAgewogICAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgzMHB4KTsgfQogICAgdG8geyBvcGFjaXR5OiAxOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KICB9CgogIEBrZXlmcmFtZXMgZmFkZURvd24gewogICAgZnJvbSB7IG9wYWNpdHk6IDA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMjBweCk7IH0KICAgIHRvIHsgb3BhY2l0eTogMTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgfQoKICAvKiDilIDilIAgU2VjdGlvbiB0aXRsZSDilIDilIAgKi8KICAuc2VjdGlvbi10aXRsZSB7CiAgICBmb250LXNpemU6IDExcHg7CiAgICBsZXR0ZXItc3BhY2luZzogM3B4OwogICAgY29sb3I6IHZhcigtLXB1cnBsZS1saWdodCk7CiAgICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogICAgbWFyZ2luLWJvdHRvbTogMTZweDsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBhbGlnbi1pdGVtczogY2VudGVyOwogICAgZ2FwOiA4cHg7CiAgfQoKICAuc2VjdGlvbi10aXRsZTo6YmVmb3JlIHsKICAgIGNvbnRlbnQ6ICcnOwogICAgd2lkdGg6IDRweDsKICAgIGhlaWdodDogMTRweDsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsIHZhcigtLXB1cnBsZSksIHZhcigtLWJsdWUpKTsKICAgIGJvcmRlci1yYWRpdXM6IDJweDsKICAgIGRpc3BsYXk6IGlubGluZS1ibG9jazsKICB9CgogIC8qIOKUgOKUgCBJbnB1dCBncm91cCDilIDilIAgKi8KICAuZmllbGQgewogICAgbWFyZ2luLWJvdHRvbTogMTRweDsKICB9CgogIC5maWVsZC1sYWJlbCB7CiAgICBmb250LXNpemU6IDExcHg7CiAgICBjb2xvcjogdmFyKC0tbXV0ZWQpOwogICAgbWFyZ2luLWJvdHRvbTogNnB4OwogICAgbGV0dGVyLXNwYWNpbmc6IDFweDsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBhbGlnbi1pdGVtczogY2VudGVyOwogICAgZ2FwOiA2cHg7CiAgfQoKICAuaW5wdXQtd3JhcCB7CiAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgfQoKICAuaW5wdXQtaWNvbiB7CiAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICBsZWZ0OiAxNHB4OwogICAgdG9wOiA1MCU7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTUwJSk7CiAgICBjb2xvcjogdmFyKC0tcHVycGxlLWxpZ2h0KTsKICAgIGZvbnQtc2l6ZTogMTZweDsKICAgIG9wYWNpdHk6IDAuNzsKICAgIHotaW5kZXg6IDE7CiAgfQoKICAuZmkgewogICAgd2lkdGg6IDEwMCU7CiAgICBiYWNrZ3JvdW5kOiByZ2JhKDE1LDIwLDUwLDAuOCk7CiAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEyNCw1OCwyMzcsMC4zKTsKICAgIGJvcmRlci1yYWRpdXM6IDEwcHg7CiAgICBwYWRkaW5nOiAxMnB4IDE0cHggMTJweCA0MnB4OwogICAgY29sb3I6IHZhcigtLXRleHQpOwogICAgZm9udC1mYW1pbHk6ICdTYXJhYnVuJywgc2Fucy1zZXJpZjsKICAgIGZvbnQtc2l6ZTogMTRweDsKICAgIG91dGxpbmU6IG5vbmU7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4zczsKICB9CgogIC5maTpmb2N1cyB7CiAgICBib3JkZXItY29sb3I6IHZhcigtLXB1cnBsZS1saWdodCk7CiAgICBiYWNrZ3JvdW5kOiByZ2JhKDIwLDI1LDYwLDAuOSk7CiAgICBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSgxMjQsNTgsMjM3LDAuMTUpLCAwIDAgMjBweCByZ2JhKDEyNCw1OCwyMzcsMC4xKTsKICB9CgogIC5maTo6cGxhY2Vob2xkZXIgeyBjb2xvcjogcmdiYSgxODAsMTkwLDIyMCwwLjMpOyB9CgogIC5leWUtdG9nZ2xlIHsKICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsKICAgIHJpZ2h0OiAxNHB4OwogICAgdG9wOiA1MCU7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTUwJSk7CiAgICBiYWNrZ3JvdW5kOiBub25lOwogICAgYm9yZGVyOiBub25lOwogICAgY29sb3I6IHZhcigtLW11dGVkKTsKICAgIGN1cnNvcjogcG9pbnRlcjsKICAgIGZvbnQtc2l6ZTogMTZweDsKICAgIHBhZGRpbmc6IDA7CiAgICB0cmFuc2l0aW9uOiBjb2xvciAwLjJzOwogIH0KCiAgLmV5ZS10b2dnbGU6aG92ZXIgeyBjb2xvcjogdmFyKC0tcHVycGxlLWxpZ2h0KTsgfQoKICAvKiDilIDilIAgQnV0dG9uIOKUgOKUgCAqLwogIC5idG4tbWFpbiB7CiAgICB3aWR0aDogMTAwJTsKICAgIHBhZGRpbmc6IDE0cHg7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCB2YXIoLS1wdXJwbGUpLCB2YXIoLS1ibHVlKSk7CiAgICBib3JkZXI6IG5vbmU7CiAgICBib3JkZXItcmFkaXVzOiAxMHB4OwogICAgY29sb3I6ICNmZmY7CiAgICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogICAgZm9udC1zaXplOiAxM3B4OwogICAgZm9udC13ZWlnaHQ6IDcwMDsKICAgIGxldHRlci1zcGFjaW5nOiAycHg7CiAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgdHJhbnNpdGlvbjogYWxsIDAuM3M7CiAgICBib3gtc2hhZG93OiAwIDRweCAyMHB4IHJnYmEoMTI0LDU4LDIzNywwLjQpOwogICAgbWFyZ2luLXRvcDogNHB4OwogIH0KCiAgLmJ0bi1tYWluOjpiZWZvcmUgewogICAgY29udGVudDogJyc7CiAgICBwb3NpdGlvbjogYWJzb2x1dGU7CiAgICBpbnNldDogMDsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsIHJnYmEoMjU1LDI1NSwyNTUsMC4xNSksIHRyYW5zcGFyZW50KTsKICAgIG9wYWNpdHk6IDA7CiAgICB0cmFuc2l0aW9uOiBvcGFjaXR5IDAuM3M7CiAgfQoKICAuYnRuLW1haW46aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0ycHgpOwogICAgYm94LXNoYWRvdzogMCA4cHggMzBweCByZ2JhKDEyNCw1OCwyMzcsMC42KSwgMCAwIDYwcHggcmdiYSgzNyw5OSwyMzUsMC4zKTsKICB9CgogIC5idG4tbWFpbjpob3Zlcjo6YmVmb3JlIHsgb3BhY2l0eTogMTsgfQogIC5idG4tbWFpbjphY3RpdmUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KCiAgLmJ0bi1tYWluIC5idG4tc2hpbmUgewogICAgcG9zaXRpb246IGFic29sdXRlOwogICAgdG9wOiAwOyBsZWZ0OiAtMTAwJTsKICAgIHdpZHRoOiA2MCU7CiAgICBoZWlnaHQ6IDEwMCU7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsIHRyYW5zcGFyZW50LCByZ2JhKDI1NSwyNTUsMjU1LDAuMiksIHRyYW5zcGFyZW50KTsKICAgIHRyYW5zZm9ybTogc2tld1goLTIwZGVnKTsKICAgIGFuaW1hdGlvbjogc2hpbmUgM3MgZWFzZS1pbi1vdXQgaW5maW5pdGUgMXM7CiAgfQoKICBAa2V5ZnJhbWVzIHNoaW5lIHsKICAgIDAlIHsgbGVmdDogLTEwMCU7IH0KICAgIDMwJSwgMTAwJSB7IGxlZnQ6IDE1MCU7IH0KICB9CgogIC8qIOKUgOKUgCBEaXZpZGVyIOKUgOKUgCAqLwogIC5kaXZpZGVyIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBhbGlnbi1pdGVtczogY2VudGVyOwogICAgZ2FwOiAxMnB4OwogICAgbWFyZ2luOiAyMHB4IDA7CiAgICBjb2xvcjogdmFyKC0tbXV0ZWQpOwogICAgZm9udC1zaXplOiAxMXB4OwogICAgbGV0dGVyLXNwYWNpbmc6IDJweDsKICB9CgogIC5kaXZpZGVyOjpiZWZvcmUsIC5kaXZpZGVyOjphZnRlciB7CiAgICBjb250ZW50OiAnJzsKICAgIGZsZXg6IDE7CiAgICBoZWlnaHQ6IDFweDsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgdHJhbnNwYXJlbnQsIHJnYmEoMTI0LDU4LDIzNywwLjMpLCB0cmFuc3BhcmVudCk7CiAgfQoKICAvKiDilIDilIAgUmVzZXQgc2VjdGlvbiDilIDilIAgKi8KICAucmVzZXQtc2VjdGlvbiB7CiAgICBiYWNrZ3JvdW5kOiByZ2JhKDEyNCw1OCwyMzcsMC4wNSk7CiAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDEyNCw1OCwyMzcsMC4yKTsKICAgIGJvcmRlci1yYWRpdXM6IDEycHg7CiAgICBwYWRkaW5nOiAxNnB4OwogICAgbWFyZ2luLXRvcDogNHB4OwogIH0KCiAgLmJ0bi1yZXNldCB7CiAgICB3aWR0aDogMTAwJTsKICAgIHBhZGRpbmc6IDEycHg7CiAgICBiYWNrZ3JvdW5kOiB0cmFuc3BhcmVudDsKICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoOTYsMTY1LDI1MCwwLjQpOwogICAgYm9yZGVyLXJhZGl1czogMTBweDsKICAgIGNvbG9yOiB2YXIoLS1ibHVlLWxpZ2h0KTsKICAgIGZvbnQtZmFtaWx5OiAnT3JiaXRyb24nLCBtb25vc3BhY2U7CiAgICBmb250LXNpemU6IDEycHg7CiAgICBmb250LXdlaWdodDogNzAwOwogICAgbGV0dGVyLXNwYWNpbmc6IDJweDsKICAgIGN1cnNvcjogcG9pbnRlcjsKICAgIHRyYW5zaXRpb246IGFsbCAwLjNzOwogICAgbWFyZ2luLXRvcDogNHB4OwogICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgb3ZlcmZsb3c6IGhpZGRlbjsKICB9CgogIC5idG4tcmVzZXQ6aG92ZXIgewogICAgYmFja2dyb3VuZDogcmdiYSgzNyw5OSwyMzUsMC4xNSk7CiAgICBib3JkZXItY29sb3I6IHZhcigtLWJsdWUtbGlnaHQpOwogICAgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgzNyw5OSwyMzUsMC4zKTsKICB9CgogIC8qIOKUgOKUgCBGb290ZXIg4pSA4pSAICovCiAgLmZvb3RlciB7CiAgICB0ZXh0LWFsaWduOiBjZW50ZXI7CiAgICBtYXJnaW4tdG9wOiAyMHB4OwogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsKICAgIGZvbnQtc2l6ZTogOHB4OwogICAgbGV0dGVyLXNwYWNpbmc6IDNweDsKICAgIGNvbG9yOiB2YXIoLS1tdXRlZCk7CiAgICBkaXNwbGF5OiBmbGV4OwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgIGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgZ2FwOiA4cHg7CiAgfQoKICAuZm9vdGVyLWRvdCB7CiAgICB3aWR0aDogM3B4OwogICAgaGVpZ2h0OiAzcHg7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBiYWNrZ3JvdW5kOiB2YXIoLS1wdXJwbGUtbGlnaHQpOwogICAgb3BhY2l0eTogMC41OwogIH0KCiAgLyog4pSA4pSAIFJlc2V0IGJ1dHRvbiAocmVwbGFjZXMgcmVzZXQtc2VjdGlvbikg4pSA4pSAICovCiAgLmJ0bi1vcGVuLXJlc2V0IHsKICAgIHdpZHRoOiAxMDAlOwogICAgcGFkZGluZzogMTNweDsKICAgIGJhY2tncm91bmQ6IHRyYW5zcGFyZW50OwogICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg5NiwxNjUsMjUwLDAuMzUpOwogICAgYm9yZGVyLXJhZGl1czogMTBweDsKICAgIGNvbG9yOiB2YXIoLS1ibHVlLWxpZ2h0KTsKICAgIGZvbnQtZmFtaWx5OiAnT3JiaXRyb24nLCBtb25vc3BhY2U7CiAgICBmb250LXNpemU6IDExcHg7CiAgICBmb250LXdlaWdodDogNzAwOwogICAgbGV0dGVyLXNwYWNpbmc6IDJweDsKICAgIGN1cnNvcjogcG9pbnRlcjsKICAgIHRyYW5zaXRpb246IGFsbCAwLjNzOwogICAgcG9zaXRpb246IHJlbGF0aXZlOwogICAgb3ZlcmZsb3c6IGhpZGRlbjsKICB9CiAgLmJ0bi1vcGVuLXJlc2V0OmhvdmVyIHsKICAgIGJhY2tncm91bmQ6IHJnYmEoMzcsOTksMjM1LDAuMTIpOwogICAgYm9yZGVyLWNvbG9yOiB2YXIoLS1ibHVlLWxpZ2h0KTsKICAgIGJveC1zaGFkb3c6IDAgMCAyMHB4IHJnYmEoMzcsOTksMjM1LDAuMjUpOwogIH0KCiAgLyog4pSA4pSAIE1vZGFsIG92ZXJsYXkg4pSA4pSAICovCiAgLm1vZGFsLW92ZXJsYXkgewogICAgZGlzcGxheTogbm9uZTsKICAgIHBvc2l0aW9uOiBmaXhlZDsKICAgIGluc2V0OiAwOwogICAgYmFja2dyb3VuZDogcmdiYSgyLDQsMTUsMC43NSk7CiAgICBiYWNrZHJvcC1maWx0ZXI6IGJsdXIoNnB4KTsKICAgIHotaW5kZXg6IDEwMDsKICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIHBhZGRpbmc6IDIwcHg7CiAgfQogIC5tb2RhbC1vdmVybGF5Lm9wZW4gewogICAgZGlzcGxheTogZmxleDsKICAgIGFuaW1hdGlvbjogZmFkZUluIDAuMjVzIGVhc2UgYm90aDsKICB9CiAgQGtleWZyYW1lcyBmYWRlSW4gewogICAgZnJvbSB7IG9wYWNpdHk6IDA7IH0KICAgIHRvICAgeyBvcGFjaXR5OiAxOyB9CiAgfQoKICAubW9kYWwgewogICAgd2lkdGg6IDEwMCU7CiAgICBtYXgtd2lkdGg6IDM4MHB4OwogICAgYmFja2dyb3VuZDogcmdiYSg4LDEyLDM1LDAuOTcpOwogICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg5NiwxNjUsMjUwLDAuMyk7CiAgICBib3JkZXItcmFkaXVzOiAyMHB4OwogICAgcGFkZGluZzogMjhweCAyNHB4IDI0cHg7CiAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICBib3gtc2hhZG93OiAwIDAgMCAxcHggcmdiYSgzNyw5OSwyMzUsMC4xKSwgMCAyNHB4IDY0cHggcmdiYSgwLDAsMCwwLjcpOwogICAgYW5pbWF0aW9uOiBzbGlkZVVwIDAuM3MgY3ViaWMtYmV6aWVyKC40LDAsLjIsMSkgYm90aDsKICB9CiAgQGtleWZyYW1lcyBzbGlkZVVwIHsKICAgIGZyb20geyBvcGFjaXR5OiAwOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMjRweCk7IH0KICAgIHRvICAgeyBvcGFjaXR5OiAxOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KICB9CiAgLm1vZGFsOjpiZWZvcmUgeyBjb250ZW50OicnOyBwb3NpdGlvbjphYnNvbHV0ZTsgdG9wOi0xcHg7IGxlZnQ6LTFweDsgd2lkdGg6MjBweDsgaGVpZ2h0OjIwcHg7IGJvcmRlci10b3A6MS41cHggc29saWQgcmdiYSg5NiwxNjUsMjUwLDAuNSk7IGJvcmRlci1sZWZ0OjEuNXB4IHNvbGlkIHJnYmEoOTYsMTY1LDI1MCwwLjUpOyBib3JkZXItcmFkaXVzOjRweCAwIDAgMDsgfQogIC5tb2RhbDo6YWZ0ZXIgIHsgY29udGVudDonJzsgcG9zaXRpb246YWJzb2x1dGU7IGJvdHRvbTotMXB4OyByaWdodDotMXB4OyB3aWR0aDoyMHB4OyBoZWlnaHQ6MjBweDsgYm9yZGVyLWJvdHRvbToxLjVweCBzb2xpZCByZ2JhKDYsMTgyLDIxMiwwLjUpOyBib3JkZXItcmlnaHQ6MS41cHggc29saWQgcmdiYSg2LDE4MiwyMTIsMC41KTsgYm9yZGVyLXJhZGl1czowIDAgNHB4IDA7IH0KCiAgLm1vZGFsLWhlYWRlciB7CiAgICBkaXNwbGF5OiBmbGV4OwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgIGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsKICAgIG1hcmdpbi1ib3R0b206IDIwcHg7CiAgfQogIC5tb2RhbC10aXRsZSB7CiAgICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogICAgZm9udC1zaXplOiAxMXB4OwogICAgZm9udC13ZWlnaHQ6IDcwMDsKICAgIGxldHRlci1zcGFjaW5nOiAzcHg7CiAgICBjb2xvcjogdmFyKC0tYmx1ZS1saWdodCk7CiAgICBkaXNwbGF5OiBmbGV4OwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsKICAgIGdhcDogOHB4OwogIH0KICAubW9kYWwtdGl0bGU6OmJlZm9yZSB7CiAgICBjb250ZW50OiAnJzsKICAgIHdpZHRoOiA0cHg7IGhlaWdodDogMTRweDsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxODBkZWcsIHZhcigtLWJsdWUpLCB2YXIoLS1jeWFuKSk7CiAgICBib3JkZXItcmFkaXVzOiAycHg7CiAgfQogIC5tb2RhbC1jbG9zZSB7CiAgICBiYWNrZ3JvdW5kOiBub25lOwogICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSg5NiwxNjUsMjUwLDAuMik7CiAgICBib3JkZXItcmFkaXVzOiA4cHg7CiAgICBjb2xvcjogdmFyKC0tbXV0ZWQpOwogICAgZm9udC1zaXplOiAxNnB4OwogICAgd2lkdGg6IDMycHg7IGhlaWdodDogMzJweDsKICAgIGN1cnNvcjogcG9pbnRlcjsKICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgdHJhbnNpdGlvbjogYWxsIDAuMnM7CiAgICBsaW5lLWhlaWdodDogMTsKICB9CiAgLm1vZGFsLWNsb3NlOmhvdmVyIHsgYm9yZGVyLWNvbG9yOiByZ2JhKDk2LDE2NSwyNTAsMC41KTsgY29sb3I6IHZhcigtLWJsdWUtbGlnaHQpOyB9CgogIC8qIG1vZGFsIGlucHV0OiB1c2UgYmx1ZSBhY2NlbnQgaW5zdGVhZCBvZiBwdXJwbGUgKi8KICAubW9kYWwgLmZpIHsgYm9yZGVyLWNvbG9yOiByZ2JhKDM3LDk5LDIzNSwwLjMpOyB9CiAgLm1vZGFsIC5maTpmb2N1cyB7IGJvcmRlci1jb2xvcjogdmFyKC0tYmx1ZS1saWdodCk7IGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDM3LDk5LDIzNSwwLjE1KTsgfQogIC5tb2RhbCAuaW5wdXQtaWNvbiB7IGNvbG9yOiB2YXIoLS1ibHVlLWxpZ2h0KTsgfQoKICAuYnRuLWNyZWF0ZSB7CiAgICB3aWR0aDogMTAwJTsKICAgIHBhZGRpbmc6IDE0cHg7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCB2YXIoLS1ibHVlKSwgIzBlYTVlOSk7CiAgICBib3JkZXI6IG5vbmU7CiAgICBib3JkZXItcmFkaXVzOiAxMHB4OwogICAgY29sb3I6ICNmZmY7CiAgICBmb250LWZhbWlseTogJ09yYml0cm9uJywgbW9ub3NwYWNlOwogICAgZm9udC1zaXplOiAxMnB4OwogICAgZm9udC13ZWlnaHQ6IDcwMDsKICAgIGxldHRlci1zcGFjaW5nOiAycHg7CiAgICBjdXJzb3I6IHBvaW50ZXI7CiAgICBtYXJnaW4tdG9wOiA0cHg7CiAgICBwb3NpdGlvbjogcmVsYXRpdmU7CiAgICBvdmVyZmxvdzogaGlkZGVuOwogICAgdHJhbnNpdGlvbjogYWxsIDAuM3M7CiAgICBib3gtc2hhZG93OiAwIDRweCAyMHB4IHJnYmEoMzcsOTksMjM1LDAuNCk7CiAgfQogIC5idG4tY3JlYXRlOmhvdmVyIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0ycHgpOyBib3gtc2hhZG93OiAwIDhweCAyOHB4IHJnYmEoMzcsOTksMjM1LDAuNTUpOyB9CiAgLmJ0bi1jcmVhdGU6YWN0aXZlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgLmJ0bi1jcmVhdGUgLmJ0bi1zaGluZSB7CiAgICBwb3NpdGlvbjphYnNvbHV0ZTsgdG9wOjA7IGxlZnQ6LTEwMCU7IHdpZHRoOjYwJTsgaGVpZ2h0OjEwMCU7CiAgICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCxyZ2JhKDI1NSwyNTUsMjU1LDAuMTgpLHRyYW5zcGFyZW50KTsKICAgIHRyYW5zZm9ybTpza2V3WCgtMjBkZWcpOwogICAgYW5pbWF0aW9uOnNoaW5lIDNzIGVhc2UtaW4tb3V0IGluZmluaXRlIDEuMnM7CiAgfQoKICAuYWxlcnQgewogICAgcGFkZGluZzogMTBweCAxNHB4OwogICAgYm9yZGVyLXJhZGl1czogOHB4OwogICAgZm9udC1zaXplOiAxMnB4OwogICAgbWFyZ2luLWJvdHRvbTogMTJweDsKICAgIGRpc3BsYXk6IG5vbmU7CiAgICBib3JkZXI6IDFweCBzb2xpZDsKICB9CgogIC5hbGVydC5lcnIgeyBiYWNrZ3JvdW5kOiByZ2JhKDIzOSw2OCw2OCwwLjEpOyBib3JkZXItY29sb3I6IHJnYmEoMjM5LDY4LDY4LDAuMyk7IGNvbG9yOiAjZmNhNWE1OyB9CiAgLmFsZXJ0Lm9rIHsgYmFja2dyb3VuZDogcmdiYSgzNCwxOTcsOTQsMC4xKTsgYm9yZGVyLWNvbG9yOiByZ2JhKDM0LDE5Nyw5NCwwLjMpOyBjb2xvcjogIzg2ZWZhYzsgfQoKICAvKiDilZDilZAgM0QgQ2FyZHMgJiBCdXR0b25zIOKVkOKVkCAqLwogIC5jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDIwcHggIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA2KSBpbnNldCwKICAgICAgMCAwIDAgMXB4IHJnYmEoMTI0LDU4LDIzNywwLjEpLAogICAgICAwIDIwcHggNjBweCByZ2JhKDAsMCwwLDAuNiksCiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjUpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4ycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjJzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmNhcmQ6aG92ZXIgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTNweCk7IH0KCiAgLmJ0bi1tYWluIHsKICAgIGJvcmRlci1yYWRpdXM6IDEycHggIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xNSkgaW5zZXQsCiAgICAgIDAgNHB4IDIwcHggcmdiYSgxMjQsNTgsMjM3LDAuNCkgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjEycyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC5idG4tbWFpbjpob3ZlciAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsgYm94LXNoYWRvdzogMCA2cHggMCByZ2JhKDAsMCwwLDAuNCksIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjE1KSBpbnNldCwgMCA4cHggMzBweCByZ2JhKDEyNCw1OCwyMzcsMC42KSAhaW1wb3J0YW50OyB9CiAgLmJ0bi1tYWluOmFjdGl2ZSB7IGFuaW1hdGlvbjogYnRuLWJvdW5jZS1sb2dpbiAwLjI4cyBlYXNlIGZvcndhcmRzICFpbXBvcnRhbnQ7IH0KCiAgLmJ0bi1vcGVuLXJlc2V0IHsKICAgIGJvcmRlci1yYWRpdXM6IDEycHggIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgNHB4IDAgcmdiYSgwLDAsMCwwLjMpLCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLCBib3gtc2hhZG93IDAuMTJzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmJ0bi1vcGVuLXJlc2V0OmhvdmVyICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KSAhaW1wb3J0YW50OyB9CiAgLmJ0bi1vcGVuLXJlc2V0OmFjdGl2ZSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgzcHgpIHNjYWxlKDAuOTcpICFpbXBvcnRhbnQ7IGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjQpICFpbXBvcnRhbnQ7IH0KCiAgLmJ0bi1jcmVhdGUgewogICAgYm9yZGVyLXJhZGl1czogMTJweCAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCA0cHggMCByZ2JhKDAsMCwwLDAuMzUpLCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xMikgaW5zZXQsIDAgNHB4IDIwcHggcmdiYSgzNyw5OSwyMzUsMC40KSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMTJzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksIGJveC1zaGFkb3cgMC4xMnMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuYnRuLWNyZWF0ZTpob3ZlciAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsgfQogIC5idG4tY3JlYXRlOmFjdGl2ZSB7IGFuaW1hdGlvbjogYnRuLWJvdW5jZS1sb2dpbiAwLjI4cyBlYXNlIGZvcndhcmRzICFpbXBvcnRhbnQ7IH0KCiAgQGtleWZyYW1lcyBidG4tYm91bmNlLWxvZ2luIHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHNjYWxlKDEpOyB9CiAgICAzMCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjkzKSB0cmFuc2xhdGVZKDNweCk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDEuMDQpIHRyYW5zbGF0ZVkoLTJweCk7IH0KICAgIDgwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTgpIHRyYW5zbGF0ZVkoMXB4KTsgfQogICAgMTAwJSB7IHRyYW5zZm9ybTogc2NhbGUoMSkgdHJhbnNsYXRlWSgwKTsgfQogIH0KPC9zdHlsZT4KPC9oZWFkPgo8Ym9keT4KCjxkaXYgY2xhc3M9ImJnIj48L2Rpdj4KCjwhLS0gRmlyZWZsaWVzIHg2MCAtLT4KPHNjcmlwdD4KKGZ1bmN0aW9uKCl7CiAgY29uc3QgY29sb3JzID0gWwogICAgJyNiNWY1NDInLCcjZDRmYzVhJywnIzdmZmYwMCcsJyNhYWZmNDQnLAogICAgJyNmNWY1NDInLCcjZmZlOTRkJywnI2ZmZDcwMCcsJyNmZmVjNmUnLAogICAgJyNhOGZmNzgnLCcjNzhmZjhhJywnIzU2ZmZiMCcsJyM5MGZmNmEnLAogIF07CiAgZm9yIChsZXQgaSA9IDA7IGkgPCA2MDsgaSsrKSB7CiAgICBjb25zdCBlbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgZWwuY2xhc3NOYW1lID0gJ2ZpcmVmbHknOwogICAgY29uc3Qgc2l6ZSA9IE1hdGgucmFuZG9tKCkgKiAzLjUgKyAxLjU7CiAgICBjb25zdCBjb2xvciA9IGNvbG9yc1tNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkgKiBjb2xvcnMubGVuZ3RoKV07CiAgICBjb25zdCByID0gKCkgPT4gKE1hdGgucmFuZG9tKCkgLSAwLjUpICogMTYwICsgJ3B4JzsKICAgIGNvbnN0IGRyaWZ0RHVyID0gKE1hdGgucmFuZG9tKCkgKiAxOCArIDEyKS50b0ZpeGVkKDEpOwogICAgY29uc3QgYmxpbmtEdXIgPSAoTWF0aC5yYW5kb20oKSAqIDMgICsgMikudG9GaXhlZCgxKTsKICAgIGNvbnN0IGRlbGF5ICAgID0gKE1hdGgucmFuZG9tKCkgKiAxNSkudG9GaXhlZCgyKTsKICAgIGVsLnN0eWxlLmNzc1RleHQgPSBgCiAgICAgIHdpZHRoOiR7c2l6ZX1weDsgaGVpZ2h0OiR7c2l6ZX1weDsKICAgICAgbGVmdDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICAgIHRvcDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICAgIGJhY2tncm91bmQ6JHtjb2xvcn07CiAgICAgIGJveC1zaGFkb3c6IDAgMCAke3NpemUqMi41fXB4ICR7c2l6ZSoxLjV9cHggJHtjb2xvcn04OCwKICAgICAgICAgICAgICAgICAgMCAwICR7c2l6ZSo2fXB4ICAgJHtjb2xvcn00NDsKICAgICAgYW5pbWF0aW9uLWR1cmF0aW9uOiAke2RyaWZ0RHVyfXMsICR7YmxpbmtEdXJ9czsKICAgICAgYW5pbWF0aW9uLWRlbGF5OiAtJHtkZWxheX1zLCAtJHtkZWxheX1zOwogICAgICAtLWR4MToke3IoKX07IC0tZHkxOiR7cigpfTsKICAgICAgLS1keDI6JHtyKCl9OyAtLWR5Mjoke3IoKX07CiAgICAgIC0tZHgzOiR7cigpfTsgLS1keTM6JHtyKCl9OwogICAgICAtLWR4NDoke3IoKX07IC0tZHk0OiR7cigpfTsKICAgIGA7CiAgICBkb2N1bWVudC5ib2R5LmFwcGVuZENoaWxkKGVsKTsKICB9Cn0pKCk7Cjwvc2NyaXB0PgoKPGRpdiBzdHlsZT0icG9zaXRpb246cmVsYXRpdmU7ei1pbmRleDoxMDt3aWR0aDoxMDAlO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6MjBweCAwIj4KCiAgPCEtLSBMb2dvIC0tPgogIDxkaXYgY2xhc3M9ImxvZ28td3JhcCI+CiAgICA8IS0tIFNpZ25hbCBQdWxzZSBTVkcgTG9nbyAtLT4KICAgIDxkaXYgY2xhc3M9ImxvZ28tc3ZnLXdyYXAiPgogICAgICA8c3ZnIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdpZHRoPSI5MCIgaGVpZ2h0PSI5MCI+CiAgICAgICAgPGRlZnM+CiAgICAgICAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImxnVyIgeDE9IjAlIiB5MT0iMCUiIHgyPSIxMDAlIiB5Mj0iMCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMyNTYzZWIiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSI1MCUiICBzdG9wLWNvbG9yPSIjNjBhNWZhIi8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzA2YjZkNCIvPgogICAgICAgICAgPC9saW5lYXJHcmFkaWVudD4KICAgICAgICAgIDxyYWRpYWxHcmFkaWVudCBpZD0ibGdCZyIgY3g9IjUwJSIgY3k9IjUwJSIgcj0iNTAlIj4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9yPSIjMGYxZTRhIiBzdG9wLW9wYWNpdHk9IjAuOTUiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjMDYwYzFlIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgICAgICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAgICAgICA8ZmlsdGVyIGlkPSJsZ0dsb3ciPgogICAgICAgICAgICA8ZmVHYXVzc2lhbkJsdXIgc3RkRGV2aWF0aW9uPSIyLjUiIHJlc3VsdD0iYiIvPgogICAgICAgICAgICA8ZmVNZXJnZT48ZmVNZXJnZU5vZGUgaW49ImIiLz48ZmVNZXJnZU5vZGUgaW49IlNvdXJjZUdyYXBoaWMiLz48L2ZlTWVyZ2U+CiAgICAgICAgICA8L2ZpbHRlcj4KICAgICAgICAgIDxjbGlwUGF0aCBpZD0ibGdDbGlwIj48Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIvPjwvY2xpcFBhdGg+CiAgICAgICAgPC9kZWZzPgoKICAgICAgICA8IS0tIE91dGVyIGZhaW50IHJpbmcgLS0+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSgzNyw5OSwyMzUsMC4xMikiIHN0cm9rZS13aWR0aD0iMSIvPgoKICAgICAgICA8IS0tIE9yYml0aW5nIGRhc2hlZCByaW5nIC0tPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQyIgogICAgICAgICAgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC4yKSIgc3Ryb2tlLXdpZHRoPSIxIgogICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iNSA0IgogICAgICAgICAgY2xhc3M9Im9yYml0LXJpbmctYW5pbSIvPgoKICAgICAgICA8IS0tIE1pZCByaW5nIC0tPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM4IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMjIpIiBzdHJva2Utd2lkdGg9IjEiLz4KCiAgICAgICAgPCEtLSBDaXJjbGUgYm9keSAtLT4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIgZmlsbD0idXJsKCNsZ0JnKSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0IiBmaWxsPSJub25lIiBzdHJva2U9InVybCgjbGdXKSIgc3Ryb2tlLXdpZHRoPSIxLjgiIG9wYWNpdHk9IjAuOSIvPgoKICAgICAgICA8IS0tIENvbXBhc3MgdGlja3MgLS0+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iMTQiIHgyPSI1MCIgeTI9IjIwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI1MCIgeTE9IjgwIiB4Mj0iNTAiIHkyPSI4NiIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iMTQiIHkxPSI1MCIgeDI9IjIwIiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjgwIiB5MT0iNTAiIHgyPSI4NiIgeTI9IjUwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgoKICAgICAgICA8IS0tIERpYWdvbmFsIHRpY2tzIC0tPgogICAgICAgIDxsaW5lIHgxPSI3NCIgeTE9IjI0IiB4Mj0iNzgiIHkyPSIyMCIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjQpIiBzdHJva2Utd2lkdGg9IjEiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSIyNiIgeTE9IjI0IiB4Mj0iMjIiIHkyPSIyMCIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjQpIiBzdHJva2Utd2lkdGg9IjEiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI3NCIgeTE9Ijc2IiB4Mj0iNzgiIHkyPSI4MCIgc3Ryb2tlPSJyZ2JhKDYsMTgyLDIxMiwwLjQpIiAgc3Ryb2tlLXdpZHRoPSIxIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iMjYiIHkxPSI3NiIgeDI9IjIyIiB5Mj0iODAiIHN0cm9rZT0icmdiYSg2LDE4MiwyMTIsMC40KSIgIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CgogICAgICAgIDwhLS0gV2F2ZWZvcm0gKGNsaXBwZWQpIC0tPgogICAgICAgIDxnIGNsaXAtcGF0aD0idXJsKCNsZ0NsaXApIj4KICAgICAgICAgIDxwb2x5bGluZQogICAgICAgICAgICBwb2ludHM9IjE2LDUwIDI0LDUwIDI5LDMyIDM0LDY4IDM5LDMyIDQ0LDUwIDg0LDUwIgogICAgICAgICAgICBmaWxsPSJub25lIiBzdHJva2U9InVybCgjbGdXKSIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIKICAgICAgICAgICAgZmlsdGVyPSJ1cmwoI2xnR2xvdykiCiAgICAgICAgICAgIGNsYXNzPSJ3YXZlLWFuaW0iLz4KICAgICAgICA8L2c+CgogICAgICAgIDwhLS0gUGVhayBkb3RzIC0tPgogICAgICAgIDxjaXJjbGUgY3g9IjI5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzYwYTVmYSIgZmlsdGVyPSJ1cmwoI2xnR2xvdykiIGNsYXNzPSJkb3QtYW5pbS0xIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjMDZiNmQ0IiBmaWx0ZXI9InVybCgjbGdHbG93KSIgY2xhc3M9ImRvdC1hbmltLTIiLz4KICAgICAgICA8Y2lyY2xlIGN4PSIzNCIgY3k9IjY4IiByPSIyLjUiIGZpbGw9IiM2MGE1ZmEiIGZpbHRlcj0idXJsKCNsZ0dsb3cpIiBjbGFzcz0iZG90LWFuaW0tMSIvPgogICAgICA8L3N2Zz4KICAgIDwvZGl2PgoKICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyMHB4O2ZvbnQtd2VpZ2h0OjkwMDtsZXR0ZXItc3BhY2luZzo0cHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2UwZjJmZSwjNjBhNWZhLCMwNmI2ZDQpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7Ij5DSEFJWUE8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6OXB4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjYpO21hcmdpbi10b3A6MnB4OyI+UFJPSkVDVDwvZGl2PgogICAgPGRpdiBzdHlsZT0id2lkdGg6MTYwcHg7aGVpZ2h0OjFweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCwjNjBhNWZhLCMwNmI2ZDQsdHJhbnNwYXJlbnQpO21hcmdpbjo4cHggYXV0bztvcGFjaXR5OjAuNTsiPjwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6cmdiYSg2LDE4MiwyMTIsMC41NSk7bWFyZ2luLXRvcDoycHg7Ij5WMlJBWSAmYW1wOyBTU0g8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6aW5saW5lLWJsb2NrO21hcmdpbi10b3A6OHB4O3BhZGRpbmc6M3B4IDE0cHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDk2LDE2NSwyNTAsMC4zNSk7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOiM2MGE1ZmE7YmFja2dyb3VuZDpyZ2JhKDM3LDk5LDIzNSwwLjEpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlOyI+QUxMLUlOLU9ORSBQUk88L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSBDYXJkIC0tPgogIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgPGRpdiBpZD0iYWxlcnQtYm94IiBjbGFzcz0iYWxlcnQiPjwvZGl2PgoKICAgIDwhLS0gTG9naW4gc2VjdGlvbiAtLT4KICAgIDxkaXYgY2xhc3M9InNlY3Rpb24tdGl0bGUiPuC5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mjwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpZWxkIj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQtbGFiZWwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5ieC4h+C4suC4mTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbnB1dC13cmFwIj4KICAgICAgICA8c3BhbiBjbGFzcz0iaW5wdXQtaWNvbiI+8J+RpDwvc3Bhbj4KICAgICAgICA8aW5wdXQgY2xhc3M9ImZpIiBpZD0idXNlcm5hbWUiIHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLguIHguKPguK3guIHguIrguLfguYjguK3guJzguLnguYnguYPguIrguYnguIfguLLguJkiIGF1dG9jb21wbGV0ZT0ib2ZmIj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkLWxhYmVsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5wdXQtd3JhcCI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImlucHV0LWljb24iPvCflJI8L3NwYW4+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9InBhc3N3b3JkIiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IuC4geC4o+C4reC4geC4o+C4q+C4seC4quC4nOC5iOC4suC4mSI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iZXllLXRvZ2dsZSIgb25jbGljaz0idG9nZ2xlUHcoJ3Bhc3N3b3JkJyx0aGlzKSIgdGFiaW5kZXg9Ii0xIj7wn5GBPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuLW1haW4iIG9uY2xpY2s9ImRvTG9naW4oKSI+CiAgICAgIDxkaXYgY2xhc3M9ImJ0bi1zaGluZSI+PC9kaXY+CiAgICAgIPCflJAgJm5ic3A74LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4LiaCiAgICA8L2J1dHRvbj4KCiAgICA8IS0tIFJlc2V0IGJ1dHRvbiAtLT4KICAgIDxidXR0b24gY2xhc3M9ImJ0bi1vcGVuLXJlc2V0IiBvbmNsaWNrPSJvcGVuTW9kYWwoKSI+CiAgICAgIPCflJEgJm5ic3A74LiV4Lix4LmJ4LiH4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJIC8g4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZ4LmD4Lir4Lih4LmICiAgICA8L2J1dHRvbj4KCiAgICA8IS0tIEZvb3RlciAtLT4KICAgIDxkaXYgY2xhc3M9ImZvb3RlciI+CiAgICAgIENIQUlZQS1QUk9KRUNUIFYyUkFZJmFtcDtTU0ggQUxMLUlOLU9ORSBQUk8KICAgICAgPGRpdiBjbGFzcz0iZm9vdGVyLWRvdCI+PC9kaXY+CiAgICAgIFNFQ1VSRQogICAgICA8ZGl2IGNsYXNzPSJmb290ZXItZG90Ij48L2Rpdj4KICAgICAgU1RBQkxFCiAgICAgIDxkaXYgY2xhc3M9ImZvb3Rlci1kb3QiPjwvZGl2PgogICAgICBGQVNUCiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8IS0tIFJlc2V0IE1vZGFsIC0tPgo8ZGl2IGNsYXNzPSJtb2RhbC1vdmVybGF5IiBpZD0icmVzZXRNb2RhbCIgb25jbGljaz0iY2xvc2VNb2RhbE91dHNpZGUoZXZlbnQpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtb2RhbC1oZWFkZXIiPgogICAgICA8ZGl2IGNsYXNzPSJtb2RhbC10aXRsZSI+4LiV4Lix4LmJ4LiH4LiE4LmI4Liy4Lic4Li54LmJ4LmD4LiK4LmJ4LmD4Lir4Lih4LmIPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1vZGFsLWNsb3NlIiBvbmNsaWNrPSJjbG9zZU1vZGFsKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBpZD0ibW9kYWwtYWxlcnQiIGNsYXNzPSJhbGVydCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTRweCI+PC9kaXY+CgogICAgPGRpdiBjbGFzcz0iZmllbGQiPgogICAgICA8ZGl2IGNsYXNzPSJmaWVsZC1sYWJlbCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJ4LmD4Lir4Lih4LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImlucHV0LXdyYXAiPgogICAgICAgIDxzcGFuIGNsYXNzPSJpbnB1dC1pY29uIj7wn5GkPC9zcGFuPgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJuZXctdXNlciIgdHlwZT0idGV4dCIgcGxhY2Vob2xkZXI9IuC4geC4o+C4reC4geC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5ieC5g+C4q+C4oeC5iCIgYXV0b2NvbXBsZXRlPSJvZmYiPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpZWxkIj4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQtbGFiZWwiPuC4o+C4q+C4seC4quC4nOC5iOC4suC4meC5g+C4q+C4oeC5iDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJpbnB1dC13cmFwIj4KICAgICAgICA8c3BhbiBjbGFzcz0iaW5wdXQtaWNvbiI+8J+UkTwvc3Bhbj4KICAgICAgICA8aW5wdXQgY2xhc3M9ImZpIiBpZD0ibmV3LXBhc3MiIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0i4LiB4Lij4Lit4LiB4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZ4LmD4Lir4Lih4LmIIj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJleWUtdG9nZ2xlIiBvbmNsaWNrPSJ0b2dnbGVQdygnbmV3LXBhc3MnLHRoaXMpIiB0YWJpbmRleD0iLTEiPvCfkYE8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTZweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkLWxhYmVsIj7guKLguLfguJnguKLguLHguJnguKPguKvguLHguKrguJzguYjguLLguJnguYPguKvguKHguYg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iaW5wdXQtd3JhcCI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImlucHV0LWljb24iPvCflJE8L3NwYW4+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImNvbmZpcm0tcGFzcyIgdHlwZT0icGFzc3dvcmQiIHBsYWNlaG9sZGVyPSLguKLguLfguJnguKLguLHguJnguKPguKvguLHguKrguJzguYjguLLguJnguYPguKvguKHguYgiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImV5ZS10b2dnbGUiIG9uY2xpY2s9InRvZ2dsZVB3KCdjb25maXJtLXBhc3MnLHRoaXMpIiB0YWJpbmRleD0iLTEiPvCfkYE8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8YnV0dG9uIGNsYXNzPSJidG4tY3JlYXRlIiBvbmNsaWNrPSJkb1Jlc2V0KCkiPgogICAgICA8ZGl2IGNsYXNzPSJidG4tc2hpbmUiPjwvZGl2PgogICAgICDinIUgJm5ic3A74Liq4Lij4LmJ4Liy4LiH4Lic4Li54LmJ4LmD4LiK4LmJ4LmD4Lir4Lih4LmICiAgICA8L2J1dHRvbj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0PgpmdW5jdGlvbiB0b2dnbGVQdyhpZCwgYnRuKSB7CiAgY29uc3QgaW5wID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlucC50eXBlID0gaW5wLnR5cGUgPT09ICdwYXNzd29yZCcgPyAndGV4dCcgOiAncGFzc3dvcmQnOwogIGJ0bi50ZXh0Q29udGVudCA9IGlucC50eXBlID09PSAncGFzc3dvcmQnID8gJ/CfkYEnIDogJ/CfmYgnOwp9CgpmdW5jdGlvbiBzaG93QWxlcnQobXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWxlcnQtYm94Jyk7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcgKyB0eXBlOwogIGVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIHNldFRpbWVvdXQoKCkgPT4geyBlbC5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOyB9LCAzMDAwKTsKfQoKZnVuY3Rpb24gc2hvd01vZGFsQWxlcnQobXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyArIHR5cGU7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgc2V0VGltZW91dCgoKSA9PiB7IGVsLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7IH0sIDMwMDApOwp9CgpmdW5jdGlvbiBvcGVuTW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Jlc2V0TW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgZG9jdW1lbnQuYm9keS5zdHlsZS5vdmVyZmxvdyA9ICdoaWRkZW4nOwogIHNldFRpbWVvdXQoKCkgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldy11c2VyJykuZm9jdXMoKSwgMzAwKTsKfQoKZnVuY3Rpb24gY2xvc2VNb2RhbCgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmVzZXRNb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBkb2N1bWVudC5ib2R5LnN0eWxlLm92ZXJmbG93ID0gJyc7Cn0KCmZ1bmN0aW9uIGNsb3NlTW9kYWxPdXRzaWRlKGUpIHsKICBpZiAoZS50YXJnZXQgPT09IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyZXNldE1vZGFsJykpIGNsb3NlTW9kYWwoKTsKfQoKZnVuY3Rpb24gZG9Mb2dpbigpIHsKICBjb25zdCB1ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXJuYW1lJykudmFsdWUudHJpbSgpOwogIGNvbnN0IHAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzc3dvcmQnKS52YWx1ZTsKICBpZiAoIXUgfHwgIXApIHJldHVybiBzaG93QWxlcnQoJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5ieC5geC4peC4sOC4o+C4q+C4seC4quC4nOC5iOC4suC4mScsICdlcnInKTsKICBzaG93QWxlcnQoJ+C4geC4s+C4peC4seC4h+C5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mi4uLicsICdvaycpOwogIGZldGNoKCcvYXBpL2xvZ2luJywgewogICAgbWV0aG9kOiAnUE9TVCcsCiAgICBoZWFkZXJzOiB7J0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJ30sCiAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7dXNlcm5hbWU6IHUsIHBhc3N3b3JkOiBwfSkKICB9KQogIC50aGVuKHIgPT4gci5qc29uKCkpCiAgLnRoZW4oZCA9PiB7CiAgICBpZiAoZC5vayB8fCBkLnN1Y2Nlc3MpIHsKICAgICAgc2hvd0FsZXJ0KCfguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJrguKrguLPguYDguKPguYfguIgg4pyTJywgJ29rJyk7CiAgICAgIHNldFRpbWVvdXQoKCkgPT4geyBzZXNzaW9uU3RvcmFnZS5zZXRJdGVtKCdjaGFpeWFfYXV0aCcsIEpTT04uc3RyaW5naWZ5KHt1c2VyOnUsIHBhc3M6cCwgZXhwOkRhdGUubm93KCkrODY0MDAwMDB9KSk7IHdpbmRvdy5sb2NhdGlvbi5ocmVmID0gJy9zc2h3cy5odG1sJzsgfSwgODAwKTsKICAgIH0gZWxzZSB7CiAgICAgIHNob3dBbGVydCgn4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJ4Lir4Lij4Li34Lit4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZ4LmE4Lih4LmI4LiW4Li54LiB4LiV4LmJ4Lit4LiHJywgJ2VycicpOwogICAgfQogIH0pCiAgLmNhdGNoKCgpID0+IHNob3dBbGVydCgn4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LmA4LiK4Li34LmI4Lit4Lih4LiV4LmI4LitIEFQSSDguYTguJTguYknLCAnZXJyJykpOwp9Cgphc3luYyBmdW5jdGlvbiBkb1Jlc2V0KCkgewogIGNvbnN0IHUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV3LXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXctcGFzcycpLnZhbHVlOwogIGNvbnN0IGMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29uZmlybS1wYXNzJykudmFsdWU7CiAgaWYgKCF1IHx8ICFwIHx8ICFjKSByZXR1cm4gc2hvd01vZGFsQWxlcnQoJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4guC5ieC4reC4oeC4ueC4peC5g+C4q+C5ieC4hOC4o+C4micsICdlcnInKTsKICBpZiAocCAhPT0gYykgcmV0dXJuIHNob3dNb2RhbEFsZXJ0KCfguKPguKvguLHguKrguJzguYjguLLguJnguYTguKHguYjguJXguKPguIfguIHguLHguJknLCAnZXJyJyk7CiAgc2hvd01vZGFsQWxlcnQoJ+C4geC4s+C4peC4seC4h+C4reC4seC4nuC5gOC4lOC4lS4uLicsICdvaycpOwogIHRyeSB7CiAgICAvLyBTdGVwIDE6IGxvZ2luIHgtdWkg4LiU4LmJ4Lin4LiiIGNyZWRlbnRpYWxzIOC5gOC4lOC4tOC4oSAo4LiI4Liy4LiBIHNlc3Npb25TdG9yYWdlKQogICAgY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKCdjaGFpeWFfYXV0aCcpfHwne30nKTsgfSBjYXRjaChlKXtyZXR1cm57fTt9IH0pKCk7CiAgICBjb25zdCBsb2dpbkZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IF9zLnVzZXJ8fCcnLCBwYXNzd29yZDogX3MucGFzc3x8JycgfSk7CiAgICBjb25zdCBsciA9IGF3YWl0IGZldGNoKCcveHVpLWFwaS9sb2dpbicsIHsKICAgICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLAogICAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICAgIGJvZHk6IGxvZ2luRm9ybS50b1N0cmluZygpCiAgICB9KTsKICAgIGNvbnN0IGxkID0gYXdhaXQgbHIuanNvbigpOwogICAgaWYgKCFsZC5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IoJ0xvZ2luIHgtdWkg4Lil4LmJ4Lih4LmA4Lir4Lil4LinIOKAlCDguJXguKPguKfguIjguKrguK3guJrguKPguKvguLHguKrguYDguJTguLTguKEnKTsKCiAgICAvLyBTdGVwIDI6IOC5gOC4m+C4peC4teC5iOC4ouC4mSB1c2VybmFtZS9wYXNzd29yZCDguJzguYjguLLguJkgeC11aSBzZXR0aW5ncyBBUEkKICAgIGNvbnN0IHNyID0gYXdhaXQgZmV0Y2goJy94dWktYXBpL3BhbmVsL2FwaS9zZXR0aW5ncy91cGRhdGUnLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgICAgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoeyB1c2VybmFtZTogdSwgcGFzc3dvcmQ6IHAgfSkKICAgIH0pOwogICAgY29uc3Qgc2QgPSBhd2FpdCBzci5qc29uKCk7CiAgICBpZiAoIXNkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihzZC5tc2cgfHwgJ+C4reC4seC4nuC5gOC4lOC4lSB4LXVpIHNldHRpbmdzIOC4peC5ieC4oeC5gOC4q+C4peC4pycpOwoKICAgIC8vIFN0ZXAgMzogcmVzdGFydCB4LXVpIOC5gOC4nuC4t+C5iOC4reC5g+C4q+C5iSBjcmVkZW50aWFscyDguYPguKvguKHguYjguKHguLXguJzguKUKICAgIGF3YWl0IGZldGNoKCcveHVpLWFwaS9wYW5lbC9hcGkvcmVzdGFydCcsIHsKICAgICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnCiAgICB9KS5jYXRjaCgoKT0+e30pOwoKICAgIC8vIFN0ZXAgNDog4Lit4Lix4Lie4LmA4LiU4LiVIHNlc3Npb25TdG9yYWdlIOC4lOC5ieC4p+C4oiBjcmVkZW50aWFscyDguYPguKvguKHguYgKICAgIHNlc3Npb25TdG9yYWdlLnNldEl0ZW0oJ2NoYWl5YV9hdXRoJywgSlNPTi5zdHJpbmdpZnkoewogICAgICB1c2VyOiB1LCBwYXNzOiBwLCBleHA6IERhdGUubm93KCkgKyA4NjQwMDAwMAogICAgfSkpOwoKICAgIHNob3dNb2RhbEFsZXJ0KCfinIUg4Lit4Lix4Lie4LmA4LiU4LiVIHVzZXJuYW1lL3Bhc3N3b3JkIOC4quC4s+C5gOC4o+C5h+C4iCEg4LiB4Liz4Lil4Lix4LiHIHJlbG9hZC4uLicsICdvaycpOwogICAgc2V0VGltZW91dCgoKSA9PiB7IGNsb3NlTW9kYWwoKTsgbG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOyB9LCAyMjAwKTsKICB9IGNhdGNoKGUpIHsKICAgIHNob3dNb2RhbEFsZXJ0KCfinYwgJyArIGUubWVzc2FnZSwgJ2VycicpOwogIH0KfQo8L3NjcmlwdD4KCjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUscmdiYSgxMjQsNTgsMjM3LDAuMjUpIDAlLHRyYW5zcGFyZW50IDYwJSkscmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLHJnYmEoMzcsOTksMjM1LDAuMikgMCUsdHJhbnNwYXJlbnQgNjAlKSxsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwMzA1MGYgMCUsIzA4MGQxZiA1MCUsIzA1MDgxMCAxMDAlKTtwYWRkaW5nOjIwcHggMjBweCAxOHB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tncm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo1cHg7aGVpZ2h0OjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCAzcHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQogIC5kb3QucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgQGtleWZyYW1lcyBwbHN7MCUsMTAwJXtvcGFjaXR5Oi45O2JveC1zaGFkb3c6MCAwIDJweCB2YXIoLS1uZyl9NTAle29wYWNpdHk6LjY7Ym94LXNoYWRvdzowIDAgNHB4IHZhcigtLW5nKX19CiAgLnh1aS1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC54dWktaW5mb3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS43O30KICAueHVpLWluZm8gYntjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLWxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O21hcmdpbi10b3A6MTBweDt9CiAgLnN2Y3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMDUpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMXB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjt9CiAgLnN2Yy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4wNSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMik7fQogIC5zdmMtbHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O30KICAuZGd7d2lkdGg6NnB4O2hlaWdodDo2cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94LXNoYWRvdzowIDAgM3B4IHZhcigtLW5nKTtmbGV4LXNocmluazowO30KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4OjEwMDtkaXNwbGF5Om5vbmU7YWxpZ24taXRlbXM6ZmxleC1lbmQ7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLm1vdmVyLm9wZW57ZGlzcGxheTpmbGV4O30KICAubW9kYWx7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjIwcHggMjBweCAwIDA7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDgwcHg7cGFkZGluZzoyMHB4O21heC1oZWlnaHQ6ODV2aDtvdmVyZmxvdy15OmF1dG87YW5pbWF0aW9uOnN1IC4zcyBlYXNlO2JveC1zaGFkb3c6MCAtNHB4IDMwcHggcmdiYSgwLDAsMCwwLjEyKTt9CiAgQGtleWZyYW1lcyBzdXtmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVZKDEwMCUpfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAubWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206MTZweDt9CiAgLm10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS10eHQpO30KICAubWNsb3Nle3dpZHRoOjMycHg7aGVpZ2h0OjMycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAuZGdyaWR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLWJvdHRvbToxNHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRye2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo3cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHI6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5ka3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5kdntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmR2LmdyZWVue2NvbG9yOnZhcigtLW5nKTt9CiAgLmR2LnJlZHtjb2xvcjojZWY0NDQ0O30KICAuZHYubW9ub3tjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDt9CiAgLmFncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O30KICAubS1zdWJ7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTRweDtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHg7fQogIC5tLXN1Yi5vcGVue2Rpc3BsYXk6YmxvY2s7YW5pbWF0aW9uOmZpIC4ycyBlYXNlO30KICAubXN1Yi1sYmx7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuYWJ0bntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHggMTBweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5hYnRuOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAuYWJ0biAuYWl7Zm9udC1zaXplOjIycHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5hYnRuIC5hbntmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLmFidG4gLmFke2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5yZXMtYm94e3Bvc2l0aW9uOnJlbGF0aXZlO2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tdG9wOjE0cHg7ZGlzcGxheTpub25lO30KICAucmVzLWJveC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5yZXMtY2xvc2V7cG9zaXRpb246YWJzb2x1dGU7dG9wOi0xMXB4O3JpZ2h0Oi0xMXB4O3dpZHRoOjIycHg7aGVpZ2h0OjIycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2JvcmRlcjoycHggc29saWQgI2ZmZjtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bGluZS1oZWlnaHQ6MTtib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDIzOSw2OCw2OCwwLjQpO3otaW5kZXg6Mjt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9CgogIC8qIOKUgOKUgCBIRFIgbG9nbyBhbmltYXRpb25zIChzYW1lIGFzIGxvZ2luKSDilIDilIAgKi8KICBAa2V5ZnJhbWVzIGhkci1vcmJpdC1kYXNoIHsKICAgIGZyb20geyBzdHJva2UtZGFzaG9mZnNldDogMDsgfQogICAgdG8gICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAtMjUxOyB9CiAgfQogIEBrZXlmcmFtZXMgaGRyLXB1bHNlLWRyYXcgewogICAgMCUgICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7IG9wYWNpdHk6IDA7IH0KICAgIDE1JSAgeyBvcGFjaXR5OiAxOyB9CiAgICAxMDAlIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItYmxpbmstZG90IHsKICAgIDAlLCAxMDAlIHsgb3BhY2l0eTogMC4yNTsgfQogICAgNTAlICAgICAgIHsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGhkci1sb2dvLWdsb3cgewogICAgMCUsIDEwMCUgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA2cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDE0cHggIzI1NjNlYik7IH0KICAgIDUwJSAgICAgICB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDE0cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDI4cHggIzI1NjNlYikgZHJvcC1zaGFkb3coMCAwIDQycHggIzA2YjZkNCk7IH0KICB9CiAgLmhkci1sb2dvLXN2Zy13cmFwIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDhweDsKICAgIGFuaW1hdGlvbjogaGRyLWxvZ28tZ2xvdyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgLmhkci1vcmJpdC1yaW5nIHsgdHJhbnNmb3JtLW9yaWdpbjogNTBweCA1MHB4OyBhbmltYXRpb246IGhkci1vcmJpdC1kYXNoIDhzIGxpbmVhciBpbmZpbml0ZTsgfQogIC5oZHItd2F2ZS1hbmltICB7IHN0cm9rZS1kYXNoYXJyYXk6MjIwOyBzdHJva2UtZGFzaG9mZnNldDoyMjA7IGFuaW1hdGlvbjogaGRyLXB1bHNlLWRyYXcgMS42cyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKSAwLjVzIGZvcndhcmRzOyB9CiAgLmhkci1kb3QtMSB7IGFuaW1hdGlvbjogaGRyLWJsaW5rLWRvdCAyLjJzIGVhc2UtaW4tb3V0IDEuOHMgaW5maW5pdGU7IH0KICAuaGRyLWRvdC0yIHsgYW5pbWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMi4ycyBpbmZpbml0ZTsgfQoKICAvKiDilIDilIAgRGFzaGJvYXJkIEZpcmVmbGllcyAoZnVsbCBwYWdlKSDilIDilIAgKi8KICAuZGFzaC1mZiB7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIHotaW5kZXg6IDA7CiAgICBhbmltYXRpb246IGRhc2gtZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLCBkYXNoLWZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgb3BhY2l0eTogMDsKICB9CiAgQGtleWZyYW1lcyBkYXNoLWZmLWRyaWZ0IHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgICAyMCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpOyB9CiAgICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgzKSx2YXIoLS1keTMpKSBzY2FsZSgxLjA1KTsgfQogICAgODAlICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgfQogIEBrZXlmcmFtZXMgZGFzaC1mZi1ibGluayB7CiAgICAwJSwxMDAleyBvcGFjaXR5OjA7IH0gMTUleyBvcGFjaXR5OjA7IH0gMzAleyBvcGFjaXR5OjE7IH0KICAgIDUwJXsgb3BhY2l0eTowLjk7IH0gNjUleyBvcGFjaXR5OjA7IH0gODAleyBvcGFjaXR5OjAuODU7IH0gOTIleyBvcGFjaXR5OjA7IH0KICB9CgogIC8qIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkAogICAgIDNEIENBUkRTIC8gVEFCUyAvIEJVVFRPTlMg4oCUIOC4l+C4uOC4geC4q+C4meC5ieC4sgogIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAqLwogIC5jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMjUpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDI0cHggcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAycHggOHB4IHJnYmEoMzQsMTk3LDk0LDAuMTIpLAogICAgICAwIDE2cHggMzJweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSB0cmFuc2xhdGVaKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVooMCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNHB4IDM2cHggcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDRweCAxNnB4IHJnYmEoMzQsMTk3LDk0LDAuMTgpLAogICAgICAwIDI0cHggNDhweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBOYXYgaXRlbXMgM0QgKi8KICAubmF2LWl0ZW0gewogICAgYm9yZGVyLXJhZGl1czogMTJweCAxMnB4IDAgMCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAycHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICBib3gtc2hhZG93OiAwIC0ycHggNnB4IHJnYmEoMCwwLDAsMC4xNSkgaW5zZXQ7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSAhaW1wb3J0YW50OwogICAgbWFyZ2luOiAwIDJweDsKICAgIHBhZGRpbmctdG9wOiAxNHB4ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMnB4KTsKICB9CiAgLm5hdi1pdGVtLmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgIWltcG9ydGFudDsKICAgIGJvcmRlci1jb2xvcjogcmdiYSgzNCwxOTcsOTQsMC4zNSkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgLTRweCAxMnB4IHJnYmEoMzQsMTk3LDk0LDAuMTUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICB9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCk7CiAgICBib3JkZXItY29sb3I6IHJnYmEoMzQsMTk3LDk0LDAuMTUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBBbGwgYnV0dG9ucyAzRCAqLwogIC5jYnRuLCAuYnRuLXIsIC5jYnRtLXNzaCwgLmJ0bi10YmwsIC5wYnRuLCAudGJ0biwKICAuY29weS1idG4sIC5jb3B5LWxpbmstYnRuLCAubG9nb3V0LCAubWNsb3NlLAogIC5hYnRuLCAucG9ydC1idG4sIC5waWNrLW9wdCB7CiAgICBib3JkZXItcmFkaXVzOiAxMnB4ICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDRweCAwIHJnYmEoMCwwLDAsMC4zNSksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEyKSBpbnNldCwKICAgICAgMCA2cHggMTZweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjEycyBlYXNlICFpbXBvcnRhbnQ7CiAgICBib3JkZXItd2lkdGg6IDJweCAhaW1wb3J0YW50OwogIH0KICAuY2J0bjpob3ZlciwgLmJ0bi1yOmhvdmVyLCAuY29weS1idG46aG92ZXIsCiAgLmFidG46aG92ZXIsIC5wb3J0LWJ0bjpob3ZlciwgLnBpY2stb3B0OmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpIGluc2V0LAogICAgICAwIDEwcHggMjRweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQogIC5jYnRuOmFjdGl2ZSwgLmJ0bi1yOmFjdGl2ZSwgLmNvcHktYnRuOmFjdGl2ZSwKICAuYWJ0bjphY3RpdmUsIC5wb3J0LWJ0bjphY3RpdmUsIC5waWNrLW9wdDphY3RpdmUsCiAgLmJ0bi10Ymw6YWN0aXZlLCAubG9nb3V0OmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoM3B4KSBzY2FsZSgwLjk3KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCAxcHggMCByZ2JhKDAsMCwwLDAuNCksCiAgICAgIDAgMCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA2cyBlYXNlLCBib3gtc2hhZG93IDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CgogIC8qIHNlbC1jYXJkIDNEICovCiAgLnNlbC1jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjIpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDIwcHggcmdiYSgwLDAsMCwwLjEyKSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVgoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xOHMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVgoMnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA4cHggMCByZ2JhKDAsMCwwLDAuMjUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNnB4IDMycHggcmdiYSgwLDAsMCwwLjE4KSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgycHgpIHRyYW5zbGF0ZVgoMCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KCiAgLyogdWl0ZW1zIDNEICovCiAgLnVpdGVtIHsKICAgIGJvcmRlci1yYWRpdXM6IDE0cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgM3B4IDAgcmdiYSgwLDAsMCwwLjE4KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDcpIGluc2V0LAogICAgICAwIDZweCAxNHB4IHJnYmEoMCwwLDAsMC4wOCkgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjE1cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjE1cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjIyKSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDkpIGluc2V0LAogICAgICAwIDEycHggMjRweCByZ2JhKDAsMCwwLDAuMTIpICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTphY3RpdmUgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDJweCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAvKiBib3VuY2Uga2V5ZnJhbWUg4Liq4Liz4Lir4Lij4Lix4Lia4LiB4LiUICovCiAgQGtleWZyYW1lcyBidG4tYm91bmNlIHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHNjYWxlKDEpOyB9CiAgICAzMCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjkzKSB0cmFuc2xhdGVZKDNweCk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDEuMDQpIHRyYW5zbGF0ZVkoLTJweCk7IH0KICAgIDgwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTgpIHRyYW5zbGF0ZVkoMXB4KTsgfQogICAgMTAwJSB7IHRyYW5zZm9ybTogc2NhbGUoMSkgdHJhbnNsYXRlWSgwKTsgfQogIH0KICAuY2J0bjphY3RpdmUsIC5idG4tcjphY3RpdmUsIC5jb3B5LWJ0bjphY3RpdmUgeyBhbmltYXRpb246IGJ0bi1ib3VuY2UgMC4yOHMgZWFzZSBmb3J3YXJkcyAhaW1wb3J0YW50OyB9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gSEVBREVSIC0tPgogIDxkaXYgY2xhc3M9ImhkciIgaWQ9Imhkci1yb290Ij4KICAgIDxidXR0b24gY2xhc3M9ImxvZ291dCIgb25jbGljaz0iZG9Mb2dvdXQoKSI+4oapIOC4reC4reC4geC4iOC4suC4geC4o+C4sOC4muC4mjwvYnV0dG9uPgoKICAgIDwhLS0gTG9nbyBTVkcgKHNhbWUgYXMgbG9naW4pIC0tPgogICAgPGRpdiBjbGFzcz0iaGRyLWxvZ28tc3ZnLXdyYXAiPgogICAgICA8c3ZnIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdpZHRoPSI3MiIgaGVpZ2h0PSI3MiI+CiAgICAgICAgPGRlZnM+CiAgICAgICAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImhXIiB4MT0iMCUiIHkxPSIwJSIgeDI9IjEwMCUiIHkyPSIwJSI+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMCUiICAgc3RvcC1jb2xvcj0iIzI1NjNlYiIvPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjUwJSIgIHN0b3AtY29sb3I9IiM2MGE1ZmEiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjMDZiNmQ0Ii8+CiAgICAgICAgICA8L2xpbmVhckdyYWRpZW50PgogICAgICAgICAgPHJhZGlhbEdyYWRpZW50IGlkPSJoQmciIGN4PSI1MCUiIGN5PSI1MCUiIHI9IjUwJSI+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMCUiICAgc3RvcC1jb2xvcj0iIzBmMWU0YSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzA2MGMxZSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICAgICAgICA8L3JhZGlhbEdyYWRpZW50PgogICAgICAgICAgPGZpbHRlciBpZD0iaEdsb3ciPgogICAgICAgICAgICA8ZmVHYXVzc2lhbkJsdXIgc3RkRGV2aWF0aW9uPSIyLjUiIHJlc3VsdD0iYiIvPgogICAgICAgICAgICA8ZmVNZXJnZT48ZmVNZXJnZU5vZGUgaW49ImIiLz48ZmVNZXJnZU5vZGUgaW49IlNvdXJjZUdyYXBoaWMiLz48L2ZlTWVyZ2U+CiAgICAgICAgICA8L2ZpbHRlcj4KICAgICAgICAgIDxjbGlwUGF0aCBpZD0iaENsaXAiPjxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0Ii8+PC9jbGlwUGF0aD4KICAgICAgICA8L2RlZnM+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSgzNyw5OSwyMzUsMC4xMikiIHN0cm9rZS13aWR0aD0iMSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQyIiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjIpIiBzdHJva2Utd2lkdGg9IjEiIHN0cm9rZS1kYXNoYXJyYXk9IjUgNCIgY2xhc3M9Imhkci1vcmJpdC1yaW5nIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzgiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSgzNyw5OSwyMzUsMC4yMikiIHN0cm9rZS13aWR0aD0iMSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0IiBmaWxsPSJ1cmwoI2hCZykiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ1cmwoI2hXKSIgc3Ryb2tlLXdpZHRoPSIxLjgiIG9wYWNpdHk9IjAuOSIvPgogICAgICAgIDxsaW5lIHgxPSI1MCIgeTE9IjE0IiB4Mj0iNTAiIHkyPSIyMCIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iNTAiIHkxPSI4MCIgeDI9IjUwIiB5Mj0iODYiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjE0IiB5MT0iNTAiIHgyPSIyMCIgeTI9IjUwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI4MCIgeTE9IjUwIiB4Mj0iODYiIHkyPSI1MCIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8ZyBjbGlwLXBhdGg9InVybCgjaENsaXApIj4KICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjE2LDUwIDI0LDUwIDI5LDMyIDM0LDY4IDM5LDMyIDQ0LDUwIDg0LDUwIgogICAgICAgICAgICBmaWxsPSJub25lIiBzdHJva2U9InVybCgjaFcpIiBzdHJva2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIgogICAgICAgICAgICBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLXdhdmUtYW5pbSIvPgogICAgICAgIDwvZz4KICAgICAgICA8Y2lyY2xlIGN4PSIyOSIgY3k9IjMyIiByPSIyLjUiIGZpbGw9IiM2MGE1ZmEiIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItZG90LTEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSIzOSIgY3k9IjMyIiByPSIyLjUiIGZpbGw9IiMwNmI2ZDQiIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItZG90LTIiLz4KICAgICAgICA8Y2lyY2xlIGN4PSIzNCIgY3k9IjY4IiByPSIyLjUiIGZpbGw9IiM2MGE1ZmEiIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItZG90LTEiLz4KICAgICAgPC9zdmc+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MThweDtmb250LXdlaWdodDo5MDA7bGV0dGVyLXNwYWNpbmc6NHB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNlMGYyZmUsIzYwYTVmYSwjMDZiNmQ0KTstd2Via2l0LWJhY2tncm91bmQtY2xpcDp0ZXh0Oy13ZWJraXQtdGV4dC1maWxsLWNvbG9yOnRyYW5zcGFyZW50O2JhY2tncm91bmQtY2xpcDp0ZXh0OyI+Q0hBSVlBPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjlweDtjb2xvcjpyZ2JhKDk2LDE2NSwyNTAsMC42KTttYXJnaW4tdG9wOjJweDsiPlBST0pFQ1Q8L2Rpdj4KICAgIDxkaXYgc3R5bGU9IndpZHRoOjE0MHB4O2hlaWdodDoxcHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdHJhbnNwYXJlbnQsIzYwYTVmYSwjMDZiNmQ0LHRyYW5zcGFyZW50KTttYXJnaW46NnB4IGF1dG87b3BhY2l0eTowLjU7Ij48L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNTUpO21hcmdpbi10b3A6MnB4OyI+VjJSQVkgJmFtcDsgU1NIPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjpyZ2JhKDk2LDE2NSwyNTAsMC41KTttYXJnaW4tdG9wOjRweDsiIGlkPSJoZHItZG9tYWluIj5TRUNVUkUgUEFORUw8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSBOQVYgLS0+CiAgPGRpdiBjbGFzcz0ibmF2Ij4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIGFjdGl2ZSIgb25jbGljaz0ic3coJ2Rhc2hib2FyZCcsdGhpcykiPvCfk4og4LmB4LiU4LiK4Lia4Lit4Lij4LmM4LiUPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2NyZWF0ZScsdGhpcykiPuKelSDguKrguKPguYnguLLguIfguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnbWFuYWdlJyx0aGlzKSI+8J+UpyDguIjguLHguJTguIHguLLguKPguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnb25saW5lJyx0aGlzKSI+8J+foiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnYmFuJyx0aGlzKSI+8J+aqyDguJvguKXguJTguYHguJrguJk8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgREFTSEJPQVJEIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMgYWN0aXZlIiBpZD0idGFiLWRhc2hib2FyZCI+CiAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgPHNwYW4gY2xhc3M9InNlYy10aXRsZSI+4pqhIFNZU1RFTSBNT05JVE9SPC9zcGFuPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgaWQ9ImJ0bi1yZWZyZXNoIiBvbmNsaWNrPSJsb2FkRGFzaCgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InNncmlkIj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPuKaoSBDUFUgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9ImNwdS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzRhZGU4MCIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0iY3B1LXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0iY3B1LWNvcmVzIj4tLSBjb3JlczwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwZyIgaWQ9ImNwdS1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+noCBSQU0gVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9InJhbS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzNiODJmNiIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0icmFtLXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0icmFtLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwdSIgaWQ9InJhbS1iYXIiIHN0eWxlPSJ3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjM2I4MmY2LCM2MGE1ZmEpIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7wn5K+IERJU0sgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdmFsIiBpZD0iZGlzay1wY3QiPi0tPHNwYW4+JTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0iZGlzay1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcG8iIGlkPSJkaXNrLWJhciIgc3R5bGU9IndpZHRoOjAlIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7ij7EgVVBUSU1FPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9InVwdGltZS12YWwiIHN0eWxlPSJmb250LXNpemU6MjBweCI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0idXB0aW1lLXN1YiI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YmRnIiBpZD0ibG9hZC1jaGlwcyI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+MkCBORVRXT1JLIEkvTzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJuZXQtcm93Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaRIFVwbG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtdXAiPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtdXAtdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRpdmlkZXIiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Im5pIiBzdHlsZT0idGV4dC1hbGlnbjpyaWdodCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaTIERvd25sb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJucyIgaWQ9Im5ldC1kbiI+LS08c3Bhbj4gLS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJudCIgaWQ9Im5ldC1kbi10b3RhbCI+dG90YWw6IC0tPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+ToSBYLVVJIFBBTkVMIFNUQVRVUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ4dWktcm93Ij4KICAgICAgICA8ZGl2IGlkPSJ4dWktcGlsbCIgY2xhc3M9Im9waWxsIG9mZiI+PHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj7guIHguLPguKXguLHguIfguYDguIrguYfguIQuLi48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ4dWktaW5mbyI+CiAgICAgICAgICA8ZGl2PuC5gOC4p+C4reC4o+C5jOC4iuC4seC4mSBYcmF5OiA8YiBpZD0ieHVpLXZlciI+LS08L2I+PC9kaXY+CiAgICAgICAgICA8ZGl2PkluYm91bmRzOiA8YiBpZD0ieHVpLWluYm91bmRzIj4tLTwvYj4g4Lij4Liy4Lii4LiB4Liy4LijPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPgogICAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+UpyBTRVJWSUNFIE1PTklUT1I8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZFNlcnZpY2VzKCkiPuKGuyDguYDguIrguYfguIQ8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1saXN0IiBpZD0ic3ZjLWxpc3QiPgogICAgICAgIDxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibHUiIGlkPSJsYXN0LXVwZGF0ZSI+4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAtLTwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBDUkVBVEUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1jcmVhdGUiPgoKICAgIDwhLS0g4pSA4pSAIFNFTEVDVE9SIChkZWZhdWx0IHZpZXcpIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImNyZWF0ZS1tZW51Ij4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIj7wn5uhIOC4o+C4sOC4muC4miAzWC1VSSBWTEVTUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ2FpcycpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtYWlzIj48aW1nIHNyYz0iaHR0cHM6Ly91cGxvYWQud2lraW1lZGlhLm9yZy93aWtpcGVkaWEvY29tbW9ucy90aHVtYi9mL2Y5L0FJU19sb2dvLnN2Zy8yMDBweC1BSVNfbG9nby5zdmcucG5nIiBvbmVycm9yPSJ0aGlzLnN0eWxlLmRpc3BsYXk9J25vbmUnO3RoaXMubmV4dFNpYmxpbmcuc3R5bGUuZGlzcGxheT0nZmxleCciIHN0eWxlPSJ3aWR0aDo1NnB4O2hlaWdodDo1NnB4O29iamVjdC1maXQ6Y29udGFpbiI+PHNwYW4gc3R5bGU9ImRpc3BsYXk6bm9uZTtmb250LXNpemU6MS40cmVtO3dpZHRoOjU2cHg7aGVpZ2h0OjU2cHg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOiMzZDdhMGUiPkFJUzwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgV1MgwrcgY2otZWJiLnNwZWVkdGVzdC5uZXQ8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3RydWUnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUiPjxzcGFuIHN0eWxlPSJmb250LXNpemU6MS4xcmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1uYW1lIHRydWUiPlRSVUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4ODgwIMK3IFdTIMK3IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgoKICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIiBzdHlsZT0ibWFyZ2luLXRvcDoyMHB4Ij7wn5SRIOC4o+C4sOC4muC4miBTU0ggV0VCU09DS0VUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlbC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgnc3NoJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC1zc2giPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZSI+U1NIJmd0Ozwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBzc2giPlNTSCDigJMgV1MgVHVubmVsPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5TU0ggwrcgUG9ydCA4MCDCtyBEcm9wYmVhciAxNDMvMTA5PGJyPk5wdlR1bm5lbCAvIERhcmtUdW5uZWw8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogQUlTIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tYWlzIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0iZm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciBhaXMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tbG9nbyBzZWwtYWlzLXNtIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi44cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXRpdGxlIGFpcyI+QUlTIOKAkyDguIHguLHguJnguKPguLHguYjguKc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODA4MCDCtyBTTkk6IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQGFpcyI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIGNidG4tYWlzIiBpZD0iYWlzLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ2FpcycpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIEFJUyBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJhaXMtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJhaXMtcmVzdWx0Ij4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJlcy1jbG9zZSIgb25jbGljaz0iZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fpcy1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1haXMtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLWFpcy11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici1haXMtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici1haXMtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci1haXMtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5rPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJhaXMtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBUUlVFIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tdHJ1ZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgdHJ1ZS1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBTTkk6IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQHRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLXRydWUiIGlkPSJ0cnVlLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ3RydWUnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBUUlVFIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0cnVlLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXRydWUtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLXRydWUtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItdHJ1ZS1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLXRydWUtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci10cnVlLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0idHJ1ZS1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFNTSCDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXNzaCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3NoLWRhcmstZm9ybSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPuKelSDguYDguJ7guLTguYjguKEgU1NIIFVTRVI8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgdHlwZT0icGFzc3dvcmQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKXguLTguKHguLTguJXguYTguK3guJ7guLU8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij7inIjvuI8g4LmA4Lil4Li34Lit4LiBIFBPUlQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwb3J0LWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4gYWN0aXZlLXA4MCIgaWQ9InBiLTgwIiBvbmNsaWNrPSJwaWNrUG9ydCgnODAnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCfjJA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA4MDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1zdWIiPldTIMK3IEhUVFA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4iIGlkPSJwYi00NDMiIG9uY2xpY2s9InBpY2tQb3J0KCc0NDMnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCflJI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA0NDM8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XU1MgwrcgU1NMPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPvCfjJAg4LmA4Lil4Li34Lit4LiBIElTUCAvIE9QRVJBVE9SPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtZHRhYyIgaWQ9InByby1kdGFjIiBvbmNsaWNrPSJwaWNrUHJvKCdkdGFjJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+8J+foDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RFRBQyBHQU1JTkc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJwcm8tdHJ1ZSIgb25jbGljaz0icGlja1BybygndHJ1ZScpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCflLU8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPlRSVUUgVFdJVFRFUjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+aGVscC54LmNvbTwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn5OxIOC5gOC4peC4t+C4reC4gSBBUFA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQgYS1ucHYiIGlkPSJhcHAtbnB2IiBvbmNsaWNrPSJwaWNrQXBwKCducHYnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMwZDJhM2E7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6Ljg1cmVtO2NvbG9yOiMwMGNjZmY7bGV0dGVyLXNwYWNpbmc6LTFweDtib3JkZXI6MS41cHggc29saWQgcmdiYSgwLDIwNCwyNTUsLjMpIj5uVjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+TnB2IFR1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+bnB2dC1zc2g6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJhcHAtZGFyayIgb25jbGljaz0icGlja0FwcCgnZGFyaycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPjxkaXYgc3R5bGU9IndpZHRoOjM4cHg7aGVpZ2h0OjM4cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6IzExMTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bWFyZ2luOjAgYXV0byAuMXJlbTtmb250LWZhbWlseTpzYW5zLXNlcmlmO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6LjYycmVtO2NvbG9yOiNmZmY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3JkZXI6MS41cHggc29saWQgIzQ0NCI+REFSSzwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RGFya1R1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+ZGFya3R1bm5lbDovLzwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4tc3NoIiBpZD0ic3NoLWJ0biIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKelSDguKrguKPguYnguLLguIcgVXNlcjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsaW5rLXJlc3VsdCIgaWQ9InNzaC1saW5rLXJlc3VsdCI+PC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBVc2VyIHRhYmxlIC0tPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIiBzdHlsZT0ibWFyZ2luOjAiPvCfk4sg4Lij4Liy4Lii4LiK4Li34LmI4LitIFVTRVJTPC9kaXY+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJzc2gtc2VhcmNoIiBwbGFjZWhvbGRlcj0i4LiE4LmJ4LiZ4Lir4LiyLi4uIiBvbmlucHV0PSJmaWx0ZXJTU0hVc2Vycyh0aGlzLnZhbHVlKSIKICAgICAgICAgICAgc3R5bGU9IndpZHRoOjEyMHB4O21hcmdpbjowO2ZvbnQtc2l6ZToxMXB4O3BhZGRpbmc6NnB4IDEwcHgiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InV0Ymwtd3JhcCI+CiAgICAgICAgICA8dGFibGUgY2xhc3M9InV0YmwiPgogICAgICAgICAgICA8dGhlYWQ+PHRyPjx0aD4jPC90aD48dGg+VVNFUk5BTUU8L3RoPjx0aD7guKvguKHguJTguK3guLLguKLguLg8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BQ1RJT048L3RoPjwvdHI+PC90aGVhZD4KICAgICAgICAgICAgPHRib2R5IGlkPSJzc2gtdXNlci10Ym9keSI+PHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9yOnZhcigtLW11dGVkKSI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwvdGJvZHk+CiAgICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICA8L2Rpdj48IS0tIC90YWItY3JlYXRlIC0tPgoKPCEtLSDilZDilZDilZDilZAgTUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJ1c2VyLXNlYXJjaCIgcGxhY2Vob2xkZXI9IvCflI0gIOC4hOC5ieC4meC4q+C4siB1c2VybmFtZS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgICA8ZGl2IGlkPSJ1c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4m+C4uOC5iOC4oeC5guC4q+C4peC4lOC5gOC4nuC4t+C5iOC4reC4lOC4tuC4h+C4guC5ieC4reC4oeC4ueC4pTwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkT25saW5lKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9jciI+CiAgICAgICAgPGRpdiBjbGFzcz0ib3BpbGwiIGlkPSJvbmxpbmUtcGlsbCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJvbmxpbmUtY291bnQiPjA8L3NwYW4+IOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJ1dCIgaWQ9Im9ubGluZS10aW1lIj4tLTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguKPguLXguYDguJ/guKPguIrguYDguJ7guLfguYjguK3guJTguLnguJzguLnguYnguYPguIrguYnguK3guK3guJnguYTguKXguJnguYw8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBCQU4g4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1iYW4iPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+aqyDguIjguLHguJTguIHguLLguKMgU1NIIFVzZXJzPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIFVTRVJOQU1FPC9kaXY+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImJhbi11c2VyIiBwbGFjZWhvbGRlcj0i4LmD4Liq4LmIIHVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4peC4miI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE1ODAzZCwjMjJjNTVlKSIgb25jbGljaz0iZGVsZXRlU1NIKCkiPvCfl5HvuI8g4Lil4LiaIFNTSCBVc2VyPC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYmFuLWFsZXJ0Ij48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIj7wn5OLIFNTSCBVc2VycyDguJfguLHguYnguIfguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBpZD0ic3NoLXVzZXItbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCjwvZGl2PjwhLS0gL3dyYXAgLS0+Cgo8IS0tIE1PREFMIC0tPgo8ZGl2IGNsYXNzPSJtb3ZlciIgaWQ9Im1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNtKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiIGlkPSJtdCI+4pqZ77iPIHVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbSgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ToSBQb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0iZGUiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OmIERhdGEgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGQiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OKIFRyYWZmaWMg4LmD4LiK4LmJPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR0ciI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk7EgSVAgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGkiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IG1vbm8iIGlkPSJkdXUiPi0tPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMHB4Ij7guYDguKXguLfguK3guIHguIHguLLguKPguJTguLPguYDguJnguLTguJnguIHguLLguKM8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImFncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVuZXcnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIQ8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdleHRlbmQnKSI+PGRpdiBjbGFzcz0iYWkiPvCfk4U8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdhZGRkYXRhJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OmPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oSBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKE8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignc2V0ZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+4pqW77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC4seC5ieC4hyBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4geC4s+C4q+C4meC4lOC5g+C4q+C4oeC5iDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdyZXNldCcpIj48ZGl2IGNsYXNzPSJhaSI+8J+UgzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKPguLXguYDguIvguJUgVHJhZmZpYzwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biBkYW5nZXIiIG9uY2xpY2s9Im1BY3Rpb24oJ2RlbGV0ZScpIj48ZGl2IGNsYXNzPSJhaSI+8J+Xke+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKXguJrguKLguLnguKo8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lil4Lia4LiW4Liy4Lin4LijPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4LmI4Lit4Lit4Liy4Lii4Li4IC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlbmV3Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IOKAlCDguKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4mTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXJlbmV3LWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZW5ldy1idG4iIG9uY2xpY2s9ImRvUmVuZXdVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKHguKfguLHguJkgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItZXh0ZW5kIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk4Ug4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIOKAlCDguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4meC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLWV4dGVuZC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZXh0ZW5kLWJ0biIgb25jbGljaz0iZG9FeHRlbmRVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguYDguJ7guLTguYjguKHguKfguLHguJk8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKEgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1hZGRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk6Yg4LmA4Lie4Li04LmI4LihIERhdGEg4oCUIOC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKHguIjguLLguIHguJfguLXguYjguKHguLXguK3guKLguLnguYg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4mSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1hZGRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIxMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tYWRkZGF0YS1idG4iIG9uY2xpY2s9ImRvQWRkRGF0YSgpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4LihIERhdGE8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguJXguLHguYnguIcgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1zZXRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPuKalu+4jyDguJXguLHguYnguIcgRGF0YSDigJQg4LiB4Liz4Lir4LiZ4LiUIExpbWl0IOC5g+C4q+C4oeC5iCAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPkRhdGEgTGltaXQgKEdCKSDigJQgMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXNldGRhdGEtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXNldGRhdGEtYnRuIiBvbmNsaWNrPSJkb1NldERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC4seC5ieC4hyBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItcmVzZXQiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+UgyDguKPguLXguYDguIvguJUgVHJhZmZpYyDigJQg4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJ4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4geC4suC4o+C4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4iOC4sOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lCBVcGxvYWQvRG93bmxvYWQg4LiX4Lix4LmJ4LiH4Lir4Lih4LiU4LiC4Lit4LiH4Lii4Li54Liq4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXJlc2V0LWJ0biIgb25jbGljaz0iZG9SZXNldFRyYWZmaWMoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lil4Lia4Lii4Li54LiqIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWRlbGV0ZSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+8J+Xke+4jyDguKXguJrguKLguLnguKog4oCUIOC4peC4muC4luC4suC4p+C4oyDguYTguKHguYjguKrguLLguKHguLLguKPguJbguIHguLnguYnguITguLfguJnguYTguJTguYk8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTJweCI+4Lii4Li54LiqIDxiIGlkPSJtLWRlbC1uYW1lIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+PC9iPiDguIjguLDguJbguLnguIHguKXguJrguK3guK3guIHguIjguLLguIHguKPguLDguJrguJrguJbguLLguKfguKM8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZGVsZXRlLWJ0biIgb25jbGljaz0iZG9EZWxldGVVc2VyKCkiIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2RjMjYyNiwjZWY0NDQ0KSI+8J+Xke+4jyDguKLguLfguJnguKLguLHguJnguKXguJrguKLguLnguKo8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ibW9kYWwtYWxlcnQiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPjwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQgc3JjPSJjb25maWcuanMiIG9uZXJyb3I9IndpbmRvdy5DSEFJWUFfQ09ORklHPXt9Ij48L3NjcmlwdD4KPHNjcmlwdD4KLy8g4pWQ4pWQ4pWQ4pWQIENPTkZJRyDilZDilZDilZDilZAKY29uc3QgQ0ZHID0gKHR5cGVvZiB3aW5kb3cuQ0hBSVlBX0NPTkZJRyAhPT0gJ3VuZGVmaW5lZCcpID8gd2luZG93LkNIQUlZQV9DT05GSUcgOiB7fTsKY29uc3QgSE9TVCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhvc3RuYW1lOwpjb25zdCBYVUkgID0gJy94dWktYXBpJzsgICAgICAgICAgLy8geC11aSBBUEkg4LmC4LiU4Lii4LiV4Lij4LiHIOC5hOC4oeC5iOC4nOC5iOC4suC4mSBtaWRkbGV3YXJlCmNvbnN0IEFQSSAgPSAnL2FwaSc7ICAgICAgICAgICAgICAgLy8gY2hhaXlhLXNzaC1hcGkgKFNTSCB1c2VycyDguYDguJfguYjguLLguJnguLHguYnguJkpCmNvbnN0IFNFU1NJT05fS0VZID0gJ2NoYWl5YV9hdXRoJzsKCi8vIOKUgOKUgCBEaXJlY3QgeC11aSBBUEkgaGVscGVycyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbGV0IF94dWlDb29raWUgPSBmYWxzZTsKYXN5bmMgZnVuY3Rpb24geHVpRW5zdXJlTG9naW4oKSB7CiAgaWYgKF94dWlDb29raWUpIHJldHVybiB0cnVlOwogIGNvbnN0IF9zID0gKCgpID0+IHsgdHJ5IHsgcmV0dXJuIEpTT04ucGFyc2Uoc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSl8fCd7fScpOyB9IGNhdGNoKGUpe3JldHVybnt9O30gfSkoKTsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyfHxDRkcueHVpX3VzZXJ8fCcnLCBwYXNzd29yZDogX3MucGFzc3x8Q0ZHLnh1aV9wYXNzfHwnJyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aUNvb2tpZSA9ICEhZC5zdWNjZXNzOwogIHJldHVybiBfeHVpQ29va2llOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aUdldChwYXRoKSB7CiAgaWYgKCFfeHVpQ29va2llKSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIHJldHVybiByLmpzb24oKTsKfQphc3luYyBmdW5jdGlvbiB4dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgYm9keTogSlNPTi5zdHJpbmdpZnkoYm9keSkKICB9KTsKICByZXR1cm4gci5qc29uKCk7Cn0KCi8vIFNlc3Npb24gY2hlY2sKY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwppZiAoIV9zLnVzZXIgfHwgIV9zLnBhc3MgfHwgRGF0ZS5ub3coKSA+PSAoX3MuZXhwfHwwKSkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8gSGVhZGVyIGRvbWFpbgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLWRvbWFpbicpLnRleHRDb250ZW50ID0gSE9TVCArICcgwrcgdjUnOwoKLy8g4pWQ4pWQ4pWQ4pWQIFVUSUxTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBmbXRCeXRlcyhiKSB7CiAgaWYgKCFiIHx8IGIgPT09IDApIHJldHVybiAnMCBCJzsKICBjb25zdCBrID0gMTAyNCwgdSA9IFsnQicsJ0tCJywnTUInLCdHQicsJ1RCJ107CiAgY29uc3QgaSA9IE1hdGguZmxvb3IoTWF0aC5sb2coYikvTWF0aC5sb2coaykpOwogIHJldHVybiAoYi9NYXRoLnBvdyhrLGkpKS50b0ZpeGVkKDEpKycgJyt1W2ldOwp9CmZ1bmN0aW9uIGZtdERhdGUobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgY29uc3QgZCA9IG5ldyBEYXRlKG1zKTsKICByZXR1cm4gZC50b0xvY2FsZURhdGVTdHJpbmcoJ3RoLVRIJyx7eWVhcjonbnVtZXJpYycsbW9udGg6J3Nob3J0JyxkYXk6J251bWVyaWMnfSk7Cn0KZnVuY3Rpb24gZGF5c0xlZnQobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gbnVsbDsKICByZXR1cm4gTWF0aC5jZWlsKChtcyAtIERhdGUubm93KCkpIC8gODY0MDAwMDApOwp9CmZ1bmN0aW9uIHNldFJpbmcoaWQsIHBjdCkgewogIGNvbnN0IGNpcmMgPSAxMzguMjsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoZWwpIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBjaXJjIC0gKGNpcmMgKiBNYXRoLm1pbihwY3QsMTAwKSAvIDEwMCk7Cn0KZnVuY3Rpb24gc2V0QmFyKGlkLCBwY3QsIHdhcm49ZmFsc2UpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuc3R5bGUud2lkdGggPSBNYXRoLm1pbihwY3QsMTAwKSArICclJzsKICBpZiAod2FybiAmJiBwY3QgPiA4NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KSc7CiAgZWxzZSBpZiAod2FybiAmJiBwY3QgPiA2NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2Y5NzMxNiwjZmI5MjNjKSc7Cn0KZnVuY3Rpb24gc2hvd0FsZXJ0KGlkLCBtc2csIHR5cGUpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcrdHlwZTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBpZiAodHlwZSA9PT0gJ29rJykgc2V0VGltZW91dCgoKT0+e2VsLnN0eWxlLmRpc3BsYXk9J25vbmUnO30sIDMwMDApOwp9CgovLyDilZDilZDilZDilZAgTkFWIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBzdyhuYW1lLCBlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZWMnKS5mb3JFYWNoKHM9PnMuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobj0+bi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nK25hbWUpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChuYW1lPT09J2NyZWF0ZScpIGNsb3NlRm9ybSgpOwogIGlmIChuYW1lPT09J2Rhc2hib2FyZCcpIGxvYWREYXNoKCk7CiAgaWYgKG5hbWU9PT0nbWFuYWdlJykgbG9hZFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0nb25saW5lJykgbG9hZE9ubGluZSgpOwogIGlmIChuYW1lPT09J2JhbicpIGxvYWRTU0hVc2VycygpOwp9CgovLyDilIDilIAgRm9ybSBuYXYg4pSA4pSACmxldCBfY3VyRm9ybSA9IG51bGw7CmZ1bmN0aW9uIG9wZW5Gb3JtKGlkKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBbJ2FpcycsJ3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gZj09PWlkID8gJ2Jsb2NrJyA6ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IGlkOwogIGlmIChpZD09PSdzc2gnKSBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB3aW5kb3cuc2Nyb2xsVG8oMCwwKTsKfQpmdW5jdGlvbiBjbG9zZUZvcm0oKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IG51bGw7Cn0KCmxldCBfd3NQb3J0ID0gJzgwJzsKZnVuY3Rpb24gdG9nUG9ydChidG4sIHBvcnQpIHsKICBfd3NQb3J0ID0gcG9ydDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M4MC1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzgwJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzNDQzLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9PT0nNDQzJyk7Cn0KZnVuY3Rpb24gdG9nR3JvdXAoYnRuLCBjbHMpIHsKICBidG4uY2xvc2VzdCgnZGl2JykucXVlcnlTZWxlY3RvckFsbChjbHMpLmZvckVhY2goYj0+Yi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYnRuLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9CgovLyDilZDilZDilZDilZAgWFVJIExPR0lOIChjb29raWUpIOKVkOKVkOKVkOKVkApsZXQgX3h1aUNvb2tpZSA9IGZhbHNlOwphc3luYyBmdW5jdGlvbiB4dWlMb2dpbigpIHsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyLCBwYXNzd29yZDogX3MucGFzcyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aUNvb2tpZSA9ICEhZC5zdWNjZXNzOwogIHJldHVybiBfeHVpT2s7Cn0KYXN5bmMgZnVuY3Rpb24geHVpR2V0KHBhdGgpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7CiAgcmV0dXJuIHIuanNvbigpOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aVBvc3QocGF0aCwgYm9keSkgewogIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICBib2R5OiBKU09OLnN0cmluZ2lmeShib2R5KQogIH0pOwogIHJldHVybiByLmpzb24oKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZERhc2goKSB7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1yZWZyZXNoJyk7CiAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyAuLi4nOwogIF94dWlDb29raWUgPSBmYWxzZTsgLy8gZm9yY2UgcmUtbG9naW4g4LmA4Liq4Lih4LitCgogIHRyeSB7CiAgICAvLyBTU0ggQVBJIHN0YXR1cwogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3QpIHsKICAgICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogICAgfQoKICAgIC8vIFhVSSBzZXJ2ZXIgc3RhdHVzCiAgICBjb25zdCBvayA9IGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICBpZiAoIW9rKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90IHJlZCI+PC9zcGFuPkxvZ2luIOC5hOC4oeC5iOC5hOC4lOC5iSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCBvZmYnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdiA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9zZXJ2ZXIvc3RhdHVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKHN2ICYmIHN2LnN1Y2Nlc3MgJiYgc3Yub2JqKSB7CiAgICAgIGNvbnN0IG8gPSBzdi5vYmo7CiAgICAgIC8vIENQVQogICAgICBjb25zdCBjcHUgPSBNYXRoLnJvdW5kKG8uY3B1IHx8IDApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LXBjdCcpLnRleHRDb250ZW50ID0gY3B1ICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LWNvcmVzJykudGV4dENvbnRlbnQgPSAoby5jcHVDb3JlcyB8fCBvLmxvZ2ljYWxQcm8gfHwgJy0tJykgKyAnIGNvcmVzJzsKICAgICAgc2V0UmluZygnY3B1LXJpbmcnLCBjcHUpOyBzZXRCYXIoJ2NwdS1iYXInLCBjcHUsIHRydWUpOwoKICAgICAgLy8gUkFNCiAgICAgIGNvbnN0IHJhbVQgPSAoKG8ubWVtPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIHJhbVUgPSAoKG8ubWVtPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgcmFtUCA9IHJhbVQgPiAwID8gTWF0aC5yb3VuZChyYW1VL3JhbVQqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tcGN0JykudGV4dENvbnRlbnQgPSByYW1QICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLWRldGFpbCcpLnRleHRDb250ZW50ID0gcmFtVS50b0ZpeGVkKDEpKycgLyAnK3JhbVQudG9GaXhlZCgxKSsnIEdCJzsKICAgICAgc2V0UmluZygncmFtLXJpbmcnLCByYW1QKTsgc2V0QmFyKCdyYW0tYmFyJywgcmFtUCwgdHJ1ZSk7CgogICAgICAvLyBEaXNrCiAgICAgIGNvbnN0IGRza1QgPSAoKG8uZGlzaz8udG90YWx8fDApLzEwNzM3NDE4MjQpLCBkc2tVID0gKChvLmRpc2s/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCBkc2tQID0gZHNrVCA+IDAgPyBNYXRoLnJvdW5kKGRza1UvZHNrVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stcGN0JykuaW5uZXJIVE1MID0gZHNrUCArICc8c3Bhbj4lPC9zcGFuPic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLWRldGFpbCcpLnRleHRDb250ZW50ID0gZHNrVS50b0ZpeGVkKDApKycgLyAnK2Rza1QudG9GaXhlZCgwKSsnIEdCJzsKICAgICAgc2V0QmFyKCdkaXNrLWJhcicsIGRza1AsIHRydWUpOwoKICAgICAgLy8gVXB0aW1lCiAgICAgIGNvbnN0IHVwID0gby51cHRpbWUgfHwgMDsKICAgICAgY29uc3QgdWQgPSBNYXRoLmZsb29yKHVwLzg2NDAwKSwgdWggPSBNYXRoLmZsb29yKCh1cCU4NjQwMCkvMzYwMCksIHVtID0gTWF0aC5mbG9vcigodXAlMzYwMCkvNjApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXZhbCcpLnRleHRDb250ZW50ID0gdWQgPiAwID8gdWQrJ2QgJyt1aCsnaCcgOiB1aCsnaCAnK3VtKydtJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS1zdWInKS50ZXh0Q29udGVudCA9IHVkKyfguKfguLHguJkgJyt1aCsn4LiK4LihLiAnK3VtKyfguJnguLLguJfguLUnOwogICAgICBjb25zdCBsb2FkcyA9IG8ubG9hZHMgfHwgW107CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2FkLWNoaXBzJykuaW5uZXJIVE1MID0gbG9hZHMubWFwKChsLGkpPT4KICAgICAgICBgPHNwYW4gY2xhc3M9ImJkZyI+JHtbJzFtJywnNW0nLCcxNW0nXVtpXX06ICR7bC50b0ZpeGVkKDIpfTwvc3Bhbj5gKS5qb2luKCcnKTsKCiAgICAgIC8vIE5ldHdvcmsKICAgICAgaWYgKG8ubmV0SU8pIHsKICAgICAgICBjb25zdCB1cF9iID0gby5uZXRJTy51cHx8MCwgZG5fYiA9IG8ubmV0SU8uZG93bnx8MDsKICAgICAgICBjb25zdCB1cEZtdCA9IGZtdEJ5dGVzKHVwX2IpLCBkbkZtdCA9IGZtdEJ5dGVzKGRuX2IpOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAnKS5pbm5lckhUTUwgPSB1cEZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuJykuaW5uZXJIVE1MID0gZG5GbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgIH0KICAgICAgaWYgKG8ubmV0VHJhZmZpYykgewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAtdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMuc2VudHx8MCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbi10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5yZWN2fHwwKTsKICAgICAgfQoKICAgICAgLy8gWFVJIHZlcnNpb24KICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS12ZXInKS50ZXh0Q29udGVudCA9IG8ueHJheVZlcnNpb24gfHwgJy0tJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj7guK3guK3guJnguYTguKXguJnguYwnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwnOwogICAgfQoKICAgIC8vIEluYm91bmRzIGNvdW50CiAgICBjb25zdCBpYmwgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChpYmwgJiYgaWJsLnN1Y2Nlc3MpIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1pbmJvdW5kcycpLnRleHRDb250ZW50ID0gKGlibC5vYmp8fFtdKS5sZW5ndGg7CiAgICB9CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xhc3QtdXBkYXRlJykudGV4dENvbnRlbnQgPSAn4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAnICsgbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zb2xlLmVycm9yKGUpOwogIH0gZmluYWxseSB7CiAgICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IOC4o+C4teC5gOC4n+C4o+C4iic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU0VSVklDRVMg4pWQ4pWQ4pWQ4pWQCmNvbnN0IFNWQ19ERUYgPSBbCiAgeyBrZXk6J3h1aScsICAgICAgaWNvbjon8J+ToScsIG5hbWU6J3gtdWkgUGFuZWwnLCAgICAgIHBvcnQ6JzoyMDUzJyB9LAogIHsga2V5Oidzc2gnLCAgICAgIGljb246J/CfkI0nLCBuYW1lOidTU0ggQVBJJywgICAgICAgICAgcG9ydDonOjY3ODknIH0sCiAgeyBrZXk6J2Ryb3BiZWFyJywgaWNvbjon8J+QuycsIG5hbWU6J0Ryb3BiZWFyIFNTSCcsICAgICBwb3J0Oic6MTQzIDoxMDknIH0sCiAgeyBrZXk6J25naW54JywgICAgaWNvbjon8J+MkCcsIG5hbWU6J25naW54IC8gUGFuZWwnLCAgICBwb3J0Oic6ODAgOjQ0MycgfSwKICB7IGtleTonc3Nod3MnLCAgICBpY29uOifwn5SSJywgbmFtZTonV1MtU3R1bm5lbCcsICAgICAgIHBvcnQ6Jzo4MOKGkjoxNDMnIH0sCiAgeyBrZXk6J2JhZHZwbicsICAgaWNvbjon8J+OricsIG5hbWU6J0JhZFZQTiBVRFBHVycsICAgICBwb3J0Oic6NzMwMCcgfSwKXTsKZnVuY3Rpb24gcmVuZGVyU2VydmljZXMobWFwKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gU1ZDX0RFRi5tYXAocyA9PiB7CiAgICBjb25zdCB1cCA9IG1hcFtzLmtleV0gPT09IHRydWUgfHwgbWFwW3Mua2V5XSA9PT0gJ2FjdGl2ZSc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InN2YyAke3VwPycnOidkb3duJ30iPgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnICR7dXA/Jyc6J3JlZCd9Ij48L3NwYW4+PHNwYW4+JHtzLmljb259PC9zcGFuPgogICAgICAgIDxkaXY+PGRpdiBjbGFzcz0ic3ZjLW4iPiR7cy5uYW1lfTwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj4ke3MucG9ydH08L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJyYmRnICR7dXA/Jyc6J2Rvd24nfSI+JHt1cD8nUlVOTklORyc6J0RPV04nfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFNlcnZpY2VzKCkgewogIHRyeSB7CiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvZGl2Pic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU1NIIFBJQ0tFUiBTVEFURSDilZDilZDilZDilZAKY29uc3QgUFJPUyA9IHsKICBkdGFjOiB7CiAgICBuYW1lOiAnRFRBQyBHQU1JTkcnLAogICAgcHJveHk6ICcxMDQuMTguNjMuMTI0OjgwJywKICAgIHBheWxvYWQ6ICdDT05ORUNUIC8gIEhUVFAvMS4xIFtjcmxmXUhvc3Q6IGRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb20gW2NybGZdW2NybGZdUEFUQ0ggLyBIVFRQLzEuMVtjcmxmXUhvc3Q6W2hvc3RdW2NybGZdVXBncmFkZTpVc2VyLUFnZW50OiBbdWFdW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0sCiAgdHJ1ZTogewogICAgbmFtZTogJ1RSVUUgVFdJVFRFUicsCiAgICBwcm94eTogJzEwNC4xOC4zOS4yNDo4MCcsCiAgICBwYXlsb2FkOiAnUE9TVCAvIEhUVFAvMS4xW2NybGZdSG9zdDpoZWxwLnguY29tW2NybGZdVXNlci1BZ2VudDogW3VhXVtjcmxmXVtjcmxmXVtzcGxpdF1bY3JdUEFUQ0ggLyBIVFRQLzEuMVtjcmxmXUhvc3Q6IFtob3N0XVtjcmxmXVVwZ3JhZGU6IHdlYnNvY2tldFtjcmxmXUNvbm5lY3Rpb246VXBncmFkZVtjcmxmXVtjcmxmXScsCiAgICBkYXJrUHJveHk6ICd0cnVldmlwYW5saW5lLmdvZHZwbi5zaG9wJywgZGFya1Byb3h5UG9ydDogODAKICB9Cn07CmNvbnN0IE5QVl9IT1NUID0gJ3d3dy5wcm9qZWN0LmdvZHZwbi5zaG9wJywgTlBWX1BPUlQgPSA4MDsKbGV0IF9zc2hQcm8gPSAnZHRhYycsIF9zc2hBcHAgPSAnbnB2JywgX3NzaFBvcnQgPSAnODAnOwoKZnVuY3Rpb24gcGlja1BvcnQocCkgewogIF9zc2hQb3J0ID0gcDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGItODAnKS5jbGFzc05hbWUgID0gJ3BvcnQtYnRuJyArIChwPT09JzgwJyAgPyAnIGFjdGl2ZS1wODAnICA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGItNDQzJykuY2xhc3NOYW1lID0gJ3BvcnQtYnRuJyArIChwPT09JzQ0MycgPyAnIGFjdGl2ZS1wNDQzJyA6ICcnKTsKfQpmdW5jdGlvbiBwaWNrUHJvKHApIHsKICBfc3NoUHJvID0gcDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLWR0YWMnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0nZHRhYycgPyAnIGEtZHRhYycgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byby10cnVlJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChwPT09J3RydWUnID8gJyBhLXRydWUnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tBcHAoYSkgewogIF9zc2hBcHAgPSBhOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtbnB2JykuY2xhc3NOYW1lICA9ICdwaWNrLW9wdCcgKyAoYT09PSducHYnICA/ICcgYS1ucHYnICA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwLWRhcmsnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKGE9PT0nZGFyaycgPyAnIGEtZGFyaycgOiAnJyk7Cn0KZnVuY3Rpb24gYnVpbGROcHZMaW5rKG5hbWUsIHBhc3MsIHBybykgewogIGNvbnN0IGogPSB7CiAgICBzc2hDb25maWdUeXBlOidTU0gtUHJveHktUGF5bG9hZCcsIHJlbWFya3M6cHJvLm5hbWUrJy0nK25hbWUsCiAgICBzc2hIb3N0Ok5QVl9IT1NULCBzc2hQb3J0Ok5QVl9QT1JULAogICAgc3NoVXNlcm5hbWU6bmFtZSwgc3NoUGFzc3dvcmQ6cGFzcywKICAgIHNuaTonJywgdGxzVmVyc2lvbjonREVGQVVMVCcsCiAgICBodHRwUHJveHk6cHJvLnByb3h5LCBhdXRoZW50aWNhdGVQcm94eTpmYWxzZSwKICAgIHByb3h5VXNlcm5hbWU6JycsIHByb3h5UGFzc3dvcmQ6JycsCiAgICBwYXlsb2FkOnByby5wYXlsb2FkLAogICAgZG5zTW9kZTonVURQJywgZG5zU2VydmVyOicnLCBuYW1lc2VydmVyOicnLCBwdWJsaWNLZXk6JycsCiAgICB1ZHBnd1BvcnQ6NzMwMCwgdWRwZ3dUcmFuc3BhcmVudEROUzp0cnVlCiAgfTsKICByZXR1cm4gJ25wdnQtc3NoOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CmZ1bmN0aW9uIGJ1aWxkRGFya0xpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgcHAgPSAocHJvLnByb3h5fHwnJykuc3BsaXQoJzonKTsKICBjb25zdCBkaCA9IHBwWzBdIHx8IHByby5kYXJrUHJveHk7CiAgY29uc3QgaiA9IHsKICAgIGNvbmZpZ1R5cGU6J1NTSC1QUk9YWScsIHJlbWFya3M6cHJvLm5hbWUrJy0nK25hbWUsCiAgICBzc2hIb3N0OkhPU1QsIHNzaFBvcnQ6MTQzLAogICAgc3NoVXNlcjpuYW1lLCBzc2hQYXNzOnBhc3MsCiAgICBwYXlsb2FkOidHRVQgLyBIVFRQLzEuMVxyXG5Ib3N0OiAnK0hPU1QrJ1xyXG5VcGdyYWRlOiB3ZWJzb2NrZXRcclxuQ29ubmVjdGlvbjogVXBncmFkZVxyXG5cclxuJywKICAgIHByb3h5SG9zdDpkaCwgcHJveHlQb3J0OjgwLAogICAgdWRwZ3dBZGRyOicxMjcuMC4wLjEnLCB1ZHBnd1BvcnQ6NzMwMCwgdGxzRW5hYmxlZDpmYWxzZQogIH07CiAgcmV0dXJuICdkYXJrdHVubmVsLXNzaDovLycgKyBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChKU09OLnN0cmluZ2lmeShqKSkpKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIENSRUFURSBTU0gg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGNyZWF0ZVNTSCgpIHsKICBjb25zdCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWUudHJpbSgpOwogIGNvbnN0IHBhc3MgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZS50cmltKCk7CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtZGF5cycpLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBsICA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtaXAnKSA/IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtaXAnKS52YWx1ZSA6IDIpfHwyOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFwYXNzKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggUGFzc3dvcmQnLCdlcnInKTsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3BpbiIgc3R5bGU9ImJvcmRlci1jb2xvcjpyZ2JhKDM0LDE5Nyw5NCwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojMjJjNTVlIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgY29uc3QgcmVzRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWxpbmstcmVzdWx0Jyk7CiAgaWYgKHJlc0VsKSByZXNFbC5jbGFzc05hbWU9J2xpbmstcmVzdWx0JzsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2NyZWF0ZV9zc2gnLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHt1c2VyLCBwYXNzd29yZDpwYXNzLCBkYXlzLCBpcF9saW1pdDppcGx9KQogICAgfSk7CiAgICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBwcm8gID0gUFJPU1tfc3NoUHJvXSB8fCBQUk9TLmR0YWM7CiAgICBjb25zdCBsaW5rID0gX3NzaEFwcD09PSducHYnID8gYnVpbGROcHZMaW5rKHVzZXIscGFzcyxwcm8pIDogYnVpbGREYXJrTGluayh1c2VyLHBhc3MscHJvKTsKICAgIGNvbnN0IGlzTnB2ID0gX3NzaEFwcD09PSducHYnOwogICAgY29uc3QgbHBDbHMgPSBpc05wdiA/ICcnIDogJyBkYXJrLWxwJzsKICAgIGNvbnN0IGNDbHMgID0gaXNOcHYgPyAnbnB2JyA6ICdkYXJrJzsKICAgIGNvbnN0IGFwcExhYmVsID0gaXNOcHYgPyAnTnB2dCcgOiAnRGFya1R1bm5lbCc7CgogICAgaWYgKHJlc0VsKSB7CiAgICAgIHJlc0VsLmNsYXNzTmFtZSA9ICdsaW5rLXJlc3VsdCBzaG93JzsKICAgICAgY29uc3Qgc2FmZUxpbmsgPSBsaW5rLnJlcGxhY2UoL1xcL2csJ1xcXFwnKS5yZXBsYWNlKC8nL2csIlxcJyIpOwogICAgICByZXNFbC5pbm5lckhUTUwgPQogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXJlc3VsdC1oZHInPiIgKwogICAgICAgICAgIjxzcGFuIGNsYXNzPSdpbXAtYmFkZ2UgIitjQ2xzKyInPiIrYXBwTGFiZWwrIjwvc3Bhbj4iICsKICAgICAgICAgICI8c3BhbiBzdHlsZT0nZm9udC1zaXplOi42NXJlbTtjb2xvcjp2YXIoLS1tdXRlZCknPiIrcHJvLm5hbWUrIiBceGI3IFBvcnQgIitfc3NoUG9ydCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOiMyMmM1NWU7bWFyZ2luLWxlZnQ6YXV0byc+XHUyNzA1ICIrdXNlcisiPC9zcGFuPiIgKwogICAgICAgICI8L2Rpdj4iICsKICAgICAgICAiPGRpdiBjbGFzcz0nbGluay1wcmV2aWV3IitscENscysiJz4iK2xpbmsrIjwvZGl2PiIgKwogICAgICAgICI8YnV0dG9uIGNsYXNzPSdjb3B5LWxpbmstYnRuICIrY0NscysiJyBpZD0nY29weS1zc2gtYnRuJyBvbmNsaWNrPVwiY29weVNTSExpbmsoKVwiPiIrCiAgICAgICAgICAiXHVkODNkXHVkY2NiIENvcHkgIithcHBMYWJlbCsiIExpbmsiKwogICAgICAgICI8L2J1dHRvbj4iOwogICAgICB3aW5kb3cuX2xhc3RTU0hMaW5rID0gbGluazsKICAgICAgd2luZG93Ll9sYXN0U1NIQXBwICA9IGNDbHM7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExhYmVsID0gYXBwTGFiZWw7CiAgICB9CgogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCDCtyDguKvguKHguJTguK3guLLguKLguLggJytkLmV4cCwnb2snKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlcicpLnZhbHVlPScnOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1wYXNzJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3NGMgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4p6VIOC4quC4o+C5ieC4suC4hyBVc2VyJzsgfQp9CmZ1bmN0aW9uIGNvcHlTU0hMaW5rKCkgewogIGNvbnN0IGxpbmsgPSB3aW5kb3cuX2xhc3RTU0hMaW5rfHwnJzsKICBjb25zdCBjQ2xzID0gd2luZG93Ll9sYXN0U1NIQXBwfHwnbnB2JzsKICBjb25zdCBsYWJlbCA9IHdpbmRvdy5fbGFzdFNTSExhYmVsfHwnTGluayc7CiAgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQobGluaykudGhlbihmdW5jdGlvbigpewogICAgY29uc3QgYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb3B5LXNzaC1idG4nKTsKICAgIGlmKGIpeyBiLnRleHRDb250ZW50PSdcdTI3MDUg4LiE4Lix4LiU4Lil4Lit4LiB4LmB4Lil4LmJ4LinISc7IHNldFRpbWVvdXQoZnVuY3Rpb24oKXtiLnRleHRDb250ZW50PSdcdWQ4M2RcdWRjY2IgQ29weSAnK2xhYmVsKycgTGluayc7fSwyMDAwKTsgfQogIH0pLmNhdGNoKGZ1bmN0aW9uKCl7IHByb21wdCgnQ29weSBsaW5rOicsbGluayk7IH0pOwp9CgovLyBTU0ggdXNlciB0YWJsZQpsZXQgX3NzaFRhYmxlVXNlcnMgPSBbXTsKYXN5bmMgZnVuY3Rpb24gbG9hZFNTSFRhYmxlSW5Gb3JtKCkgewogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvdXNlcnMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIF9zc2hUYWJsZVVzZXJzID0gZC51c2VycyB8fCBbXTsKICAgIHJlbmRlclNTSFRhYmxlKF9zc2hUYWJsZVVzZXJzKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnN0IHRiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLXRib2R5Jyk7CiAgICBpZih0YikgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjojZWY0NDQ0O3BhZGRpbmc6MTZweCI+4LmA4LiK4Li34LmI4Lit4Lih4LiV4LmI4LitIFNTSCBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJPC90ZD48L3RyPic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclNTSFRhYmxlKHVzZXJzKSB7CiAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICBpZiAoIXRiKSByZXR1cm47CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsKICAgIHRiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO3BhZGRpbmc6MjBweCI+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvdGQ+PC90cj4nOwogICAgcmV0dXJuOwogIH0KICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiAgdGIuaW5uZXJIVE1MID0gdXNlcnMubWFwKGZ1bmN0aW9uKHUsaSl7CiAgICBjb25zdCBleHBpcmVkID0gdS5leHAgJiYgdS5leHAgPCBub3c7CiAgICBjb25zdCBhY3RpdmUgID0gdS5hY3RpdmUgIT09IGZhbHNlICYmICFleHBpcmVkOwogICAgY29uc3QgZExlZnQgICA9IHUuZXhwID8gTWF0aC5jZWlsKChuZXcgRGF0ZSh1LmV4cCktRGF0ZS5ub3coKSkvODY0MDAwMDApIDogbnVsbDsKICAgIGNvbnN0IGJhZGdlICAgPSBhY3RpdmUKICAgICAgPyAnPHNwYW4gY2xhc3M9ImJkZyBiZGctZyI+QUNUSVZFPC9zcGFuPicKICAgICAgOiAnPHNwYW4gY2xhc3M9ImJkZyBiZGctciI+RVhQSVJFRDwvc3Bhbj4nOwogICAgY29uc3QgZFRhZyA9IGRMZWZ0IT09bnVsbAogICAgICA/ICc8c3BhbiBjbGFzcz0iZGF5cy1iYWRnZSI+JysoZExlZnQ+MD9kTGVmdCsnZCc6J+C4q+C4oeC4lCcpKyc8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iZGF5cy1iYWRnZSI+XHUyMjFlPC9zcGFuPic7CiAgICByZXR1cm4gJzx0cj48dGQgc3R5bGU9ImNvbG9yOnZhcigtLW11dGVkKSI+JysoaSsxKSsnPC90ZD4nICsKICAgICAgJzx0ZD48Yj4nK3UudXNlcisnPC9iPjwvdGQ+JyArCiAgICAgICc8dGQgc3R5bGU9ImZvbnQtc2l6ZToxMXB4O2NvbG9yOicrKGV4cGlyZWQ/JyNlZjQ0NDQnOid2YXIoLS1tdXRlZCknKSsnIj4nKwogICAgICAgICh1LmV4cHx8J+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcpKyc8L3RkPicgKwogICAgICAnPHRkPicrYmFkZ2UrJzwvdGQ+JyArCiAgICAgICc8dGQ+PGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo0cHg7YWxpZ24taXRlbXM6Y2VudGVyIj4nKwogICAgICAgICc8YnV0dG9uIGNsYXNzPSJidG4tdGJsIiB0aXRsZT0i4LiV4LmI4Lit4Lit4Liy4Lii4Li4IiBvbmNsaWNrPSJvcGVuU1NIUmVuZXdNb2RhbChcJycrdS51c2VyKydcJykiPvCflIQ8L2J1dHRvbj4nKwogICAgICAgICc8YnV0dG9uIGNsYXNzPSJidG4tdGJsIiB0aXRsZT0i4Lil4LiaIiBvbmNsaWNrPSJkZWxTU0hVc2VyKFwnJyt1LnVzZXIrJ1wnKSIgc3R5bGU9ImJvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwuMykiPvCfl5HvuI88L2J1dHRvbj4nKwogICAgICAgIGRUYWcrCiAgICAgICc8L2Rpdj48L3RkPjwvdHI+JzsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJTU0hVc2VycyhxKSB7CiAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMuZmlsdGVyKGZ1bmN0aW9uKHUpe3JldHVybiAodS51c2VyfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpO30pKTsKfQovLyBTU0ggUmVuZXcgTW9kYWwKbGV0IF9yZW5ld1NTSFVzZXIgPSAnJzsKZnVuY3Rpb24gb3BlblNTSFJlbmV3TW9kYWwodXNlcikgewogIF9yZW5ld1NTSFVzZXIgPSB1c2VyOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctdXNlcm5hbWUnKS50ZXh0Q29udGVudCA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJykudmFsdWUgPSAnMzAnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY2xvc2VTU0hSZW5ld01vZGFsKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX3JlbmV3U1NIVXNlciA9ICcnOwp9CmFzeW5jIGZ1bmN0aW9uIGRvU1NIUmVuZXcoKSB7CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoIWRheXN8fGRheXM8PTApIHJldHVybjsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7IGJ0bi50ZXh0Q29udGVudCA9ICfguIHguLPguKXguLHguIfguJXguYjguK3guK3guLLguKLguLguLi4nOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvZXh0ZW5kX3NzaCcsewogICAgICBtZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXI6X3JlbmV3U1NIVXNlcixkYXlzfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4LiV4LmI4Lit4Lit4Liy4Lii4Li4ICcrX3JlbmV3U1NIVXNlcisnICsnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGNsb3NlU1NIUmVuZXdNb2RhbCgpOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7CiAgfSBmaW5hbGx5IHsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOyBidG4udGV4dENvbnRlbnQgPSAn4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4reC4reC4suC4ouC4uCc7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIHJlbmV3U1NIVXNlcih1c2VyKSB7IG9wZW5TU0hSZW5ld01vZGFsKHVzZXIpOyB9CmFzeW5jIGZ1bmN0aW9uIGRlbFNTSFVzZXIodXNlcikgewogIGlmICghY29uZmlybSgn4Lil4LiaIFNTSCB1c2VyICInK3VzZXIrJyIg4LiW4Liy4Lin4LijPycpKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9kZWxldGVfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pCiAgICB9KS50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKTt9KTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKHIuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzA1IOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IGFsZXJ0KCdcdTI3NGMgJytlLm1lc3NhZ2UpOyB9Cn0KLy8g4pWQ4pWQ4pWQ4pWQIENSRUFURSBWTEVTUyDilZDilZDilZDilZAKZnVuY3Rpb24gZ2VuVVVJRCgpIHsKICByZXR1cm4gJ3h4eHh4eHh4LXh4eHgtNHh4eC15eHh4LXh4eHh4eHh4eHh4eCcucmVwbGFjZSgvW3h5XS9nLGM9PnsKICAgIGNvbnN0IHI9TWF0aC5yYW5kb20oKSoxNnwwOyByZXR1cm4gKGM9PT0neCc/cjoociYweDN8MHg4KSkudG9TdHJpbmcoMTYpOwogIH0pOwp9CmFzeW5jIGZ1bmN0aW9uIGNyZWF0ZVZMRVNTKGNhcnJpZXIpIHsKICBjb25zdCBlbWFpbEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWVtYWlsJyk7CiAgY29uc3QgZGF5c0VsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1kYXlzJyk7CiAgY29uc3QgaXBFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1pcCcpOwogIGNvbnN0IGdiRWwgICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZ2InKTsKICBjb25zdCBlbWFpbCAgID0gZW1haWxFbC52YWx1ZS50cmltKCk7CiAgY29uc3QgZGF5cyAgICA9IHBhcnNlSW50KGRheXNFbC52YWx1ZSl8fDMwOwogIGNvbnN0IGlwTGltaXQgPSBwYXJzZUludChpcEVsLnZhbHVlKXx8MjsKICBjb25zdCBnYiAgICAgID0gcGFyc2VJbnQoZ2JFbC52YWx1ZSl8fDA7CiAgaWYgKCFlbWFpbCkgcmV0dXJuIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggRW1haWwvVXNlcm5hbWUnLCdlcnInKTsKCiAgY29uc3QgcG9ydCA9IGNhcnJpZXI9PT0nYWlzJyA/IDgwODAgOiA4ODgwOwogIGNvbnN0IHNuaSAgPSBjYXJyaWVyPT09J2FpcycgPyAnY2otZWJiLnNwZWVkdGVzdC5uZXQnIDogJ3RydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXMnOwoKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYnRuJyk7CiAgYnRuLmRpc2FibGVkPXRydWU7IGJ0bi5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0JykuY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpOwoKICB0cnkgewogICAgaWYgKCFfeHVpQ29va2llKSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgLy8g4Lir4LiyIGluYm91bmQgaWQKICAgIGNvbnN0IGxpc3QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgY29uc3QgaWIgPSAobGlzdC5vYmp8fFtdKS5maW5kKHg9PngucG9ydD09PXBvcnQpOwogICAgaWYgKCFpYikgdGhyb3cgbmV3IEVycm9yKGDguYTguKHguYjguJ7guJogaW5ib3VuZCBwb3J0ICR7cG9ydH0g4oCUIOC4o+C4seC4mSBzZXR1cCDguIHguYjguK3guJlgKTsKCiAgICBjb25zdCB1aWQgPSBnZW5VVUlEKCk7CiAgICBjb25zdCBleHBNcyA9IGRheXMgPiAwID8gKERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwKSA6IDA7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CgogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9hZGRDbGllbnQnLCB7CiAgICAgIGlkOiBpYi5pZCwKICAgICAgc2V0dGluZ3M6IEpTT04uc3RyaW5naWZ5KHsgY2xpZW50czpbewogICAgICAgIGlkOnVpZCwgZmxvdzonJywgZW1haWwsIGxpbWl0SXA6aXBMaW1pdCwKICAgICAgICB0b3RhbEdCOnRvdGFsQnl0ZXMsIGV4cGlyeVRpbWU6ZXhwTXMsIGVuYWJsZTp0cnVlLCB0Z0lkOicnLCBzdWJJZDonJywgY29tbWVudDonJywgcmVzZXQ6MAogICAgICB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBsaW5rID0gYHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06JHtwb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChlbWFpbCsnLScrKGNhcnJpZXI9PT0nYWlzJz8nQUlTJzonVFJVRScpKX1gOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWVtYWlsJykudGV4dENvbnRlbnQgPSBlbWFpbDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLXV1aWQnKS50ZXh0Q29udGVudCA9IHVpZDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWV4cCcpLnRleHRDb250ZW50ID0gZXhwTXMgPiAwID8gZm10RGF0ZShleHBNcykgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWxpbmsnKS50ZXh0Q29udGVudCA9IGxpbms7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0JykuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgLy8gR2VuZXJhdGUgUVIgY29kZQogICAgY29uc3QgcXJEaXYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcXInKTsKICAgIGlmIChxckRpdikgewogICAgICBxckRpdi5pbm5lckhUTUwgPSAnJzsKICAgICAgdHJ5IHsKICAgICAgICBuZXcgUVJDb2RlKHFyRGl2LCB7IHRleHQ6IGxpbmssIHdpZHRoOiAxODAsIGhlaWdodDogMTgwLCBjb3JyZWN0TGV2ZWw6IFFSQ29kZS5Db3JyZWN0TGV2ZWwuTSB9KTsKICAgICAgfSBjYXRjaChxckVycikgeyBxckRpdi5pbm5lckhUTUwgPSAnJzsgfQogICAgfQogICAgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgVkxFU1MgQWNjb3VudCDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZW1haWxFbC52YWx1ZT0nJzsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfimqEg4Liq4Lij4LmJ4Liy4LiHICcrKGNhcnJpZXI9PT0nYWlzJz8nQUlTJzonVFJVRScpKycgQWNjb3VudCc7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSBVU0VSUyDilZDilZDilZDilZAKbGV0IF9hbGxVc2VycyA9IFtdLCBfY3VyVXNlciA9IG51bGw7CmFzeW5jIGZ1bmN0aW9uIGxvYWRVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlDb29raWUgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICBjb25zdCBkID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGlmICghZC5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IoZC5tc2cgfHwgJ+C5guC4q+C4peC4lCBpbmJvdW5kcyDguYTguKHguYjguYTguJTguYknKTsKICAgIF9hbGxVc2VycyA9IFtdOwogICAgKGQub2JqfHxbXSkuZm9yRWFjaChpYiA9PiB7CiAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAoc2V0dGluZ3MuY2xpZW50c3x8W10pLmZvckVhY2goYyA9PiB7CiAgICAgICAgX2FsbFVzZXJzLnB1c2goewogICAgICAgICAgaWJJZDogaWIuaWQsIHBvcnQ6IGliLnBvcnQsIHByb3RvOiBpYi5wcm90b2NvbCwKICAgICAgICAgIGVtYWlsOiBjLmVtYWlsfHxjLmlkLCB1dWlkOiBjLmlkLAogICAgICAgICAgZXhwOiBjLmV4cGlyeVRpbWV8fDAsIHRvdGFsOiBjLnRvdGFsR0J8fDAsCiAgICAgICAgICB1cDogaWIudXB8fDAsIGRvd246IGliLmRvd258fDAsIGxpbWl0SXA6IGMubGltaXRJcHx8MAogICAgICAgIH0pOwogICAgICB9KTsKICAgIH0pOwogICAgcmVuZGVyVXNlcnMoX2FsbFVzZXJzKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQpmdW5jdGlvbiByZW5kZXJVc2Vycyh1c2VycykgewogIGlmICghdXNlcnMubGVuZ3RoKSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4nuC4muC4ouC4ueC4quC5gOC4i+C4reC4o+C5jDwvcD48L2Rpdj4nOyByZXR1cm47IH0KICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSB1c2Vycy5tYXAodSA9PiB7CiAgICBjb25zdCBkbCA9IGRheXNMZWZ0KHUuZXhwKTsKICAgIGxldCBiYWRnZSwgY2xzOwogICAgaWYgKCF1LmV4cCB8fCB1LmV4cD09PTApIHsgYmFkZ2U9J+KckyDguYTguKHguYjguIjguLPguIHguLHguJQnOyBjbHM9J29rJzsgfQogICAgZWxzZSBpZiAoZGwgPCAwKSAgICAgICAgIHsgYmFkZ2U9J+C4q+C4oeC4lOC4reC4suC4ouC4uCc7IGNscz0nZXhwJzsgfQogICAgZWxzZSBpZiAoZGwgPD0gMykgICAgICAgIHsgYmFkZ2U9J+KaoCAnK2RsKydkJzsgY2xzPSdzb29uJzsgfQogICAgZWxzZSAgICAgICAgICAgICAgICAgICAgIHsgYmFkZ2U9J+KckyAnK2RsKydkJzsgY2xzPSdvayc7IH0KICAgIGNvbnN0IGF2Q2xzID0gZGwgPCAwID8gJ2F2LXgnIDogJ2F2LWcnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSIgb25jbGljaz0ib3BlblVzZXIoJHtKU09OLnN0cmluZ2lmeSh1KS5yZXBsYWNlKC8iL2csJyZxdW90OycpfSkiPgogICAgICA8ZGl2IGNsYXNzPSJ1YXYgJHthdkNsc30iPiR7KHUuZW1haWx8fCc/JylbMF0udG9VcHBlckNhc2UoKX08L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LmVtYWlsfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InVtIj5Qb3J0ICR7dS5wb3J0fSDCtyAke2ZtdEJ5dGVzKHUudXArdS5kb3duKX0g4LmD4LiK4LmJPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2Nsc30iPiR7YmFkZ2V9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJVc2VycyhxKSB7CiAgcmVuZGVyVXNlcnMoX2FsbFVzZXJzLmZpbHRlcih1PT4odS5lbWFpbHx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50b0xvd2VyQ2FzZSgpKSkpOwp9CgovLyDilZDilZDilZDilZAgTU9EQUwgVVNFUiDilZDilZDilZDilZAKZnVuY3Rpb24gb3BlblVzZXIodSkgewogIGlmICh0eXBlb2YgdSA9PT0gJ3N0cmluZycpIHUgPSBKU09OLnBhcnNlKHUpOwogIF9jdXJVc2VyID0gdTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXQnKS50ZXh0Q29udGVudCA9ICfimpnvuI8gJyt1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdScpLnRleHRDb250ZW50ID0gdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHAnKS50ZXh0Q29udGVudCA9IHUucG9ydDsKICBjb25zdCBkbCA9IGRheXNMZWZ0KHUuZXhwKTsKICBjb25zdCBleHBUeHQgPSAhdS5leHB8fHUuZXhwPT09MCA/ICfguYTguKHguYjguIjguLPguIHguLHguJQnIDogZm10RGF0ZSh1LmV4cCk7CiAgY29uc3QgZGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGUnKTsKICBkZS50ZXh0Q29udGVudCA9IGV4cFR4dDsKICBkZS5jbGFzc05hbWUgPSAnZHYnICsgKGRsICE9PSBudWxsICYmIGRsIDwgMCA/ICcgcmVkJyA6ICcgZ3JlZW4nKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGQnKS50ZXh0Q29udGVudCA9IHUudG90YWwgPiAwID8gZm10Qnl0ZXModS50b3RhbCkgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHRyJykudGV4dENvbnRlbnQgPSBmbXRCeXRlcyh1LnVwK3UuZG93bik7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RpJykudGV4dENvbnRlbnQgPSB1LmxpbWl0SXAgfHwgJ+KInic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1dScpLnRleHRDb250ZW50ID0gdS51dWlkOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbSgpewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfbVN1YnMuZm9yRWFjaChrID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKfQoKLy8g4pSA4pSAIE1PREFMIDYtQUNUSU9OIFNZU1RFTSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY29uc3QgX21TdWJzID0gWydyZW5ldycsJ2V4dGVuZCcsJ2FkZGRhdGEnLCdzZXRkYXRhJywncmVzZXQnLCdkZWxldGUnXTsKZnVuY3Rpb24gbUFjdGlvbihrZXkpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScra2V5KTsKICBjb25zdCBpc09wZW4gPSBlbC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKTsKICBfbVN1YnMuZm9yRWFjaChrID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBpZiAoIWlzT3BlbikgewogICAgZWwuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgaWYgKGtleT09PSdkZWxldGUnICYmIF9jdXJVc2VyKSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1kZWwtbmFtZScpLnRleHRDb250ZW50ID0gX2N1clVzZXIuZW1haWw7CiAgICBzZXRUaW1lb3V0KCgpPT5lbC5zY3JvbGxJbnRvVmlldyh7YmVoYXZpb3I6J3Ntb290aCcsYmxvY2s6J25lYXJlc3QnfSksMTAwKTsKICB9Cn0KZnVuY3Rpb24gX21CdG5Mb2FkKGlkLCBsb2FkaW5nLCBvcmlnVGV4dCkgewogIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFiKSByZXR1cm47CiAgYi5kaXNhYmxlZCA9IGxvYWRpbmc7CiAgaWYgKGxvYWRpbmcpIHsgYi5kYXRhc2V0Lm9yaWcgPSBiLnRleHRDb250ZW50OyBiLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPiDguIHguLPguKXguLHguIfguJTguLPguYDguJnguLTguJnguIHguLLguKMuLi4nOyB9CiAgZWxzZSBpZiAoYi5kYXRhc2V0Lm9yaWcpIGIudGV4dENvbnRlbnQgPSBiLmRhdGFzZXQub3JpZzsKfQoKYXN5bmMgZnVuY3Rpb24gZG9SZW5ld1VzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBleHBNcyA9IERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC5iOC4reC4reC4suC4ouC4uOC4quC4s+C5gOC4o+C5h+C4iCAnK2RheXMrJyDguKfguLHguJkgKOC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iSknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZW5ldy1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9FeHRlbmRVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZXh0ZW5kLWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBiYXNlID0gKF9jdXJVc2VyLmV4cCAmJiBfY3VyVXNlci5leHAgPiBEYXRlLm5vdygpKSA/IF9jdXJVc2VyLmV4cCA6IERhdGUubm93KCk7CiAgICBjb25zdCBleHBNcyA9IGJhc2UgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSAnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIICjguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQpJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0FkZERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGFkZEdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1hZGRkYXRhLWdiJykudmFsdWUpfHwwOwogIGlmIChhZGRHYiA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKEnLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tYWRkZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgbmV3VG90YWwgPSAoX2N1clVzZXIudG90YWx8fDApICsgYWRkR2IqMTA3Mzc0MTgyNDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpuZXdUb3RhbCxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihIERhdGEgKycrYWRkR2IrJyBHQiDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1NldERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1zZXRkYXRhLWdiJykudmFsdWUpOwogIGlmIChpc05hTihnYil8fGdiPDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6dG90YWxCeXRlcyxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4Lix4LmJ4LiHIERhdGEgTGltaXQgJysoZ2I+MD9nYisnIEdCJzon4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1Jlc2V0VHJhZmZpYygpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLXJlc2V0LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvJytfY3VyVXNlci5pYklkKycvcmVzZXRDbGllbnRUcmFmZmljLycrX2N1clVzZXIuZW1haWwpOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE1MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRGVsZXRlVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL2RlbENsaWVudC8nK19jdXJVc2VyLnV1aWQpOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4Lil4Lia4Lii4Li54LiqICcrX2N1clVzZXIuZW1haWwrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTIwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1kZWxldGUtYnRuJywgZmFsc2UpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRPbmxpbmUoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBfeHVpQ29va2llID0gZmFsc2U7CiAgICBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgLy8g4LmC4Lir4Lil4LiUIGluYm91bmRzIOC4luC5ieC4suC4ouC4seC4h+C5hOC4oeC5iOC4oeC4tQogICAgaWYgKCFfYWxsVXNlcnMubGVuZ3RoKSB7CiAgICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpLmNhdGNoKCgpPT5udWxsKTsKICAgICAgaWYgKGQgJiYgZC5zdWNjZXNzKSB7CiAgICAgICAgX2FsbFVzZXJzID0gW107CiAgICAgICAgKGQub2JqfHxbXSkuZm9yRWFjaChpYiA9PiB7CiAgICAgICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICAgICAgX2FsbFVzZXJzLnB1c2goeyBpYklkOmliLmlkLCBwb3J0OmliLnBvcnQsIHByb3RvOmliLnByb3RvY29sLAogICAgICAgICAgICAgIGVtYWlsOmMuZW1haWx8fGMuaWQsIHV1aWQ6Yy5pZCwgZXhwOmMuZXhwaXJ5VGltZXx8MCwKICAgICAgICAgICAgICB0b3RhbDpjLnRvdGFsR0J8fDAsIHVwOmliLnVwfHwwLCBkb3duOmliLmRvd258fDAsIGxpbWl0SXA6Yy5saW1pdElwfHwwIH0pOwogICAgICAgICAgfSk7CiAgICAgICAgfSk7CiAgICAgIH0KICAgIH0KICAgIGNvbnN0IG9kID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL29ubGluZXMnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAvLyDguKPguK3guIfguKPguLHguJogZm9ybWF0OiB7b2JqOiBbLi4uXX0g4Lir4Lij4Li34LitIHtvYmo6IG51bGx9IOC4q+C4o+C4t+C4rSB7b2JqOiB7fX0KICAgIGxldCBlbWFpbHMgPSBbXTsKICAgIGlmIChvZCAmJiBvZC5vYmopIHsKICAgICAgaWYgKEFycmF5LmlzQXJyYXkob2Qub2JqKSkgZW1haWxzID0gb2Qub2JqOwogICAgICBlbHNlIGlmICh0eXBlb2Ygb2Qub2JqID09PSAnb2JqZWN0JykgZW1haWxzID0gT2JqZWN0LnZhbHVlcyhvZC5vYmopLmZsYXQoKS5maWx0ZXIoZT0+dHlwZW9mIGU9PT0nc3RyaW5nJyk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWNvdW50JykudGV4dENvbnRlbnQgPSBlbWFpbHMubGVuZ3RoOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS10aW1lJykudGV4dENvbnRlbnQgPSBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKICAgIGlmICghZW1haWxzLmxlbmd0aCkgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+YtDwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4teC4ouC4ueC4quC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvcD48L2Rpdj4nOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCB1TWFwID0ge307CiAgICBfYWxsVXNlcnMuZm9yRWFjaCh1PT57IHVNYXBbdS5lbWFpbF09dTsgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUwgPSBlbWFpbHMubWFwKGVtYWlsPT57CiAgICAgIGNvbnN0IHUgPSB1TWFwW2VtYWlsXTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2IGF2LWciPvCfn6I8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7ZW1haWx9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+JHt1ID8gJ1BvcnQgJyt1LnBvcnQgOiAnVkxFU1MnfSDCtyDguK3guK3guJnguYTguKXguJnguYzguK3guKLguLnguYg8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayI+T05MSU5FPC9zcGFuPgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggVVNFUlMgKGJhbiB0YWIpIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkU1NIVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgY29uc3QgdXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1PT57CiAgICAgIGNvbnN0IGV4cCA9IHUuZXhwIHx8ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgICBjb25zdCBhY3RpdmUgPSB1LmFjdGl2ZSAhPT0gZmFsc2U7CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iPgogICAgICAgIDxkaXYgY2xhc3M9InVhdiAke2FjdGl2ZT8nYXYtZyc6J2F2LXgnfSI+JHt1LnVzZXJbMF0udG9VcHBlckNhc2UoKX08L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS51c2VyfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idW0iPuC4q+C4oeC4lOC4reC4suC4ouC4uDogJHtleHB9PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHthY3RpdmU/J29rJzonZXhwJ30iPiR7YWN0aXZlPydBY3RpdmUnOidFeHBpcmVkJ308L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIGRlbGV0ZVNTSCgpIHsKICBjb25zdCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgpOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiA/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pfSkudGhlbihyPT5yLmpzb24oKSk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yfHwn4Lil4Lia4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+KchSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVlPScnOwogICAgbG9hZFNTSFVzZXJzKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQp9CgovLyDilZDilZDilZDilZAgQ09QWSDilZDilZDilZDilZAKZnVuY3Rpb24gY29weUxpbmsoaWQsIGJ0bikgewogIGNvbnN0IHR4dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudDsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0eHQpLnRoZW4oKCk9PnsKICAgIGNvbnN0IG9yaWcgPSBidG4udGV4dENvbnRlbnQ7CiAgICBidG4udGV4dENvbnRlbnQ9J+KchSBDb3BpZWQhJzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9J3JnYmEoMzQsMTk3LDk0LC4xNSknOwogICAgc2V0VGltZW91dCgoKT0+eyBidG4udGV4dENvbnRlbnQ9b3JpZzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9Jyc7IH0sIDIwMDApOwogIH0pLmNhdGNoKCgpPT57IHByb21wdCgnQ29weSBsaW5rOicsIHR4dCk7IH0pOwp9CgovLyDilZDilZDilZDilZAgTE9HT1VUIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBkb0xvZ291dCgpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBJTklUIOKVkOKVkOKVkOKVkApsb2FkRGFzaCgpOwpsb2FkU2VydmljZXMoKTsKc2V0SW50ZXJ2YWwobG9hZERhc2gsIDMwMDAwKTsKPC9zY3JpcHQ+Cgo8IS0tIFNTSCBSRU5FVyBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJzc2gtcmVuZXctbW9kYWwiIG9uY2xpY2s9ImlmKGV2ZW50LnRhcmdldD09PXRoaXMpY2xvc2VTU0hSZW5ld01vZGFsKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IFNTSCBVc2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY2xvc2VTU0hSZW5ld01vZGFsKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJkZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfkaQgVXNlcm5hbWU8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0ic3NoLXJlbmV3LXVzZXJuYW1lIj4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmciIHN0eWxlPSJtYXJnaW4tdG9wOjE0cHgiPgogICAgICA8ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguJXguYjguK3guK3guLLguKLguLg8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIiBwbGFjZWhvbGRlcj0iMzAiPgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ic3NoLXJlbmV3LWJ0biIgb25jbGljaz0iZG9TU0hSZW5ldygpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgPC9kaXY+CjwvZGl2PgoKCjxzY3JpcHQ+Ci8vIERhc2hib2FyZCBGaXJlZmxpZXMgeDYwIOKAlCBmdWxsIHBhZ2UgZml4ZWQKKGZ1bmN0aW9uKCl7CiAgY29uc3QgY29sb3JzID0gWwogICAgJyNiNWY1NDInLCcjZDRmYzVhJywnIzdmZmYwMCcsJyNhYWZmNDQnLAogICAgJyNmNWY1NDInLCcjZmZlOTRkJywnI2ZmZDcwMCcsJyNmZmVjNmUnLAogICAgJyNhOGZmNzgnLCcjNzhmZjhhJywnIzU2ZmZiMCcsJyM5MGZmNmEnLAogIF07CiAgZm9yIChsZXQgaSA9IDA7IGkgPCA2MDsgaSsrKSB7CiAgICBjb25zdCBlbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgZWwuY2xhc3NOYW1lID0gJ2Rhc2gtZmYnOwogICAgY29uc3Qgc2l6ZSA9IE1hdGgucmFuZG9tKCkgKiAzLjUgKyAxLjU7CiAgICBjb25zdCBjb2xvciA9IGNvbG9yc1tNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkgKiBjb2xvcnMubGVuZ3RoKV07CiAgICBjb25zdCByID0gKCkgPT4gKChNYXRoLnJhbmRvbSgpIC0gMC41KSAqIDE4MCkgKyAncHgnOwogICAgY29uc3QgZER1ciA9IChNYXRoLnJhbmRvbSgpICogMTggKyAxMikudG9GaXhlZCgxKTsKICAgIGNvbnN0IGJEdXIgPSAoTWF0aC5yYW5kb20oKSAqIDMgICsgMikudG9GaXhlZCgxKTsKICAgIGNvbnN0IGRlbGF5ID0gKE1hdGgucmFuZG9tKCkgKiAxNSkudG9GaXhlZCgyKTsKICAgIGVsLnN0eWxlLmNzc1RleHQgPSBgCiAgICAgIHdpZHRoOiR7c2l6ZX1weDsgaGVpZ2h0OiR7c2l6ZX1weDsKICAgICAgbGVmdDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICAgIHRvcDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICAgIGJhY2tncm91bmQ6JHtjb2xvcn07CiAgICAgIGJveC1zaGFkb3c6IDAgMCAke3NpemUqMi41fXB4ICR7c2l6ZSoxLjV9cHggJHtjb2xvcn04OCwKICAgICAgICAgICAgICAgICAgMCAwICR7c2l6ZSo2fXB4ICR7Y29sb3J9NDQ7CiAgICAgIGFuaW1hdGlvbi1kdXJhdGlvbjogJHtkRHVyfXMsICR7YkR1cn1zOwogICAgICBhbmltYXRpb24tZGVsYXk6IC0ke2RlbGF5fXMsIC0ke2RlbGF5fXM7CiAgICAgIC0tZHgxOiR7cigpfTsgLS1keTE6JHtyKCl9OwogICAgICAtLWR4Mjoke3IoKX07IC0tZHkyOiR7cigpfTsKICAgICAgLS1keDM6JHtyKCl9OyAtLWR5Mzoke3IoKX07CiAgICAgIC0tZHg0OiR7cigpfTsgLS1keTQ6JHtyKCl9OwogICAgYDsKICAgIGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoZWwpOwogIH0KfSkoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/sshws.html
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

        if self.path == '/api/login':
            u = data.get('username', '').strip()
            p = data.get('password', '').strip()
            stored_u = open('/etc/chaiya/xui-user.conf').read().strip() if os.path.exists('/etc/chaiya/xui-user.conf') else ''
            stored_p = open('/etc/chaiya/xui-pass.conf').read().strip() if os.path.exists('/etc/chaiya/xui-pass.conf') else ''
            if u == stored_u and p == stored_p:
                return respond(self, 200, {'ok': True, 'success': True})
            return respond(self, 401, {'ok': False, 'error': 'invalid credentials'})

        elif self.path == '/api/create_ssh':
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
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUscmdiYSgxMjQsNTgsMjM3LDAuMjUpIDAlLHRyYW5zcGFyZW50IDYwJSkscmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLHJnYmEoMzcsOTksMjM1LDAuMikgMCUsdHJhbnNwYXJlbnQgNjAlKSxsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwMzA1MGYgMCUsIzA4MGQxZiA1MCUsIzA1MDgxMCAxMDAlKTtwYWRkaW5nOjIwcHggMjBweCAxOHB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2e2JhY2tncm91bmQ6I2ZmZjtkaXNwbGF5OmZsZXg7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6MTA7Ym94LXNoYWRvdzowIDJweCA4cHggcmdiYSgwLDAsMCwwLjA2KTt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleDoxO3BhZGRpbmc6MTNweCA2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLW11dGVkKTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLWJvdHRvbToycHggc29saWQgdHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjphbGwgLjJzO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOnZhcigtLWFjKTtib3JkZXItYm90dG9tLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo1cHg7aGVpZ2h0OjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCAzcHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQogIC5kb3QucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgQGtleWZyYW1lcyBwbHN7MCUsMTAwJXtvcGFjaXR5Oi45O2JveC1zaGFkb3c6MCAwIDJweCB2YXIoLS1uZyl9NTAle29wYWNpdHk6LjY7Ym94LXNoYWRvdzowIDAgNHB4IHZhcigtLW5nKX19CiAgLnh1aS1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC54dWktaW5mb3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS43O30KICAueHVpLWluZm8gYntjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLWxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O21hcmdpbi10b3A6MTBweDt9CiAgLnN2Y3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMDUpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMXB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjt9CiAgLnN2Yy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4wNSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMik7fQogIC5zdmMtbHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O30KICAuZGd7d2lkdGg6NnB4O2hlaWdodDo2cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94LXNoYWRvdzowIDAgM3B4IHZhcigtLW5nKTtmbGV4LXNocmluazowO30KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4OjEwMDtkaXNwbGF5Om5vbmU7YWxpZ24taXRlbXM6ZmxleC1lbmQ7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLm1vdmVyLm9wZW57ZGlzcGxheTpmbGV4O30KICAubW9kYWx7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjIwcHggMjBweCAwIDA7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDgwcHg7cGFkZGluZzoyMHB4O21heC1oZWlnaHQ6ODV2aDtvdmVyZmxvdy15OmF1dG87YW5pbWF0aW9uOnN1IC4zcyBlYXNlO2JveC1zaGFkb3c6MCAtNHB4IDMwcHggcmdiYSgwLDAsMCwwLjEyKTt9CiAgQGtleWZyYW1lcyBzdXtmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVZKDEwMCUpfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAubWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206MTZweDt9CiAgLm10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS10eHQpO30KICAubWNsb3Nle3dpZHRoOjMycHg7aGVpZ2h0OjMycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAuZGdyaWR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLWJvdHRvbToxNHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRye2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo3cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHI6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5ka3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5kdntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmR2LmdyZWVue2NvbG9yOnZhcigtLW5nKTt9CiAgLmR2LnJlZHtjb2xvcjojZWY0NDQ0O30KICAuZHYubW9ub3tjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDt9CiAgLmFncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O30KICAubS1zdWJ7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTRweDtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHg7fQogIC5tLXN1Yi5vcGVue2Rpc3BsYXk6YmxvY2s7YW5pbWF0aW9uOmZpIC4ycyBlYXNlO30KICAubXN1Yi1sYmx7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuYWJ0bntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHggMTBweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5hYnRuOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAuYWJ0biAuYWl7Zm9udC1zaXplOjIycHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5hYnRuIC5hbntmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLmFidG4gLmFke2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5yZXMtYm94e3Bvc2l0aW9uOnJlbGF0aXZlO2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tdG9wOjE0cHg7ZGlzcGxheTpub25lO30KICAucmVzLWJveC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5yZXMtY2xvc2V7cG9zaXRpb246YWJzb2x1dGU7dG9wOi0xMXB4O3JpZ2h0Oi0xMXB4O3dpZHRoOjIycHg7aGVpZ2h0OjIycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2JvcmRlcjoycHggc29saWQgI2ZmZjtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bGluZS1oZWlnaHQ6MTtib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDIzOSw2OCw2OCwwLjQpO3otaW5kZXg6Mjt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9CgogIC8qIOKUgOKUgCBIRFIgbG9nbyBhbmltYXRpb25zIChzYW1lIGFzIGxvZ2luKSDilIDilIAgKi8KICBAa2V5ZnJhbWVzIGhkci1vcmJpdC1kYXNoIHsKICAgIGZyb20geyBzdHJva2UtZGFzaG9mZnNldDogMDsgfQogICAgdG8gICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAtMjUxOyB9CiAgfQogIEBrZXlmcmFtZXMgaGRyLXB1bHNlLWRyYXcgewogICAgMCUgICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7IG9wYWNpdHk6IDA7IH0KICAgIDE1JSAgeyBvcGFjaXR5OiAxOyB9CiAgICAxMDAlIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItYmxpbmstZG90IHsKICAgIDAlLCAxMDAlIHsgb3BhY2l0eTogMC4yNTsgfQogICAgNTAlICAgICAgIHsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGhkci1sb2dvLWdsb3cgewogICAgMCUsIDEwMCUgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA2cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDE0cHggIzI1NjNlYik7IH0KICAgIDUwJSAgICAgICB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDE0cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDI4cHggIzI1NjNlYikgZHJvcC1zaGFkb3coMCAwIDQycHggIzA2YjZkNCk7IH0KICB9CiAgLmhkci1sb2dvLXN2Zy13cmFwIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDhweDsKICAgIGFuaW1hdGlvbjogaGRyLWxvZ28tZ2xvdyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgLmhkci1vcmJpdC1yaW5nIHsgdHJhbnNmb3JtLW9yaWdpbjogNTBweCA1MHB4OyBhbmltYXRpb246IGhkci1vcmJpdC1kYXNoIDhzIGxpbmVhciBpbmZpbml0ZTsgfQogIC5oZHItd2F2ZS1hbmltICB7IHN0cm9rZS1kYXNoYXJyYXk6MjIwOyBzdHJva2UtZGFzaG9mZnNldDoyMjA7IGFuaW1hdGlvbjogaGRyLXB1bHNlLWRyYXcgMS42cyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKSAwLjVzIGZvcndhcmRzOyB9CiAgLmhkci1kb3QtMSB7IGFuaW1hdGlvbjogaGRyLWJsaW5rLWRvdCAyLjJzIGVhc2UtaW4tb3V0IDEuOHMgaW5maW5pdGU7IH0KICAuaGRyLWRvdC0yIHsgYW5pbWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMi4ycyBpbmZpbml0ZTsgfQoKICAvKiDilIDilIAgRGFzaGJvYXJkIEZpcmVmbGllcyAoZnVsbCBwYWdlKSDilIDilIAgKi8KICAuZGFzaC1mZiB7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIHotaW5kZXg6IDA7CiAgICBhbmltYXRpb246IGRhc2gtZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLCBkYXNoLWZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgb3BhY2l0eTogMDsKICB9CiAgQGtleWZyYW1lcyBkYXNoLWZmLWRyaWZ0IHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgICAyMCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpOyB9CiAgICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgzKSx2YXIoLS1keTMpKSBzY2FsZSgxLjA1KTsgfQogICAgODAlICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgfQogIEBrZXlmcmFtZXMgZGFzaC1mZi1ibGluayB7CiAgICAwJSwxMDAleyBvcGFjaXR5OjA7IH0gMTUleyBvcGFjaXR5OjA7IH0gMzAleyBvcGFjaXR5OjE7IH0KICAgIDUwJXsgb3BhY2l0eTowLjk7IH0gNjUleyBvcGFjaXR5OjA7IH0gODAleyBvcGFjaXR5OjAuODU7IH0gOTIleyBvcGFjaXR5OjA7IH0KICB9CgogIC8qIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkAogICAgIDNEIENBUkRTIC8gVEFCUyAvIEJVVFRPTlMg4oCUIOC4l+C4uOC4geC4q+C4meC5ieC4sgogIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAqLwogIC5jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMjUpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDI0cHggcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAycHggOHB4IHJnYmEoMzQsMTk3LDk0LDAuMTIpLAogICAgICAwIDE2cHggMzJweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSB0cmFuc2xhdGVaKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVooMCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNHB4IDM2cHggcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDRweCAxNnB4IHJnYmEoMzQsMTk3LDk0LDAuMTgpLAogICAgICAwIDI0cHggNDhweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBOYXYgaXRlbXMgM0QgKi8KICAubmF2LWl0ZW0gewogICAgYm9yZGVyLXJhZGl1czogMTJweCAxMnB4IDAgMCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAycHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICBib3gtc2hhZG93OiAwIC0ycHggNnB4IHJnYmEoMCwwLDAsMC4xNSkgaW5zZXQ7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSAhaW1wb3J0YW50OwogICAgbWFyZ2luOiAwIDJweDsKICAgIHBhZGRpbmctdG9wOiAxNHB4ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMnB4KTsKICB9CiAgLm5hdi1pdGVtLmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgIWltcG9ydGFudDsKICAgIGJvcmRlci1jb2xvcjogcmdiYSgzNCwxOTcsOTQsMC4zNSkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgLTRweCAxMnB4IHJnYmEoMzQsMTk3LDk0LDAuMTUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICB9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCk7CiAgICBib3JkZXItY29sb3I6IHJnYmEoMzQsMTk3LDk0LDAuMTUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBBbGwgYnV0dG9ucyAzRCAqLwogIC5jYnRuLCAuYnRuLXIsIC5jYnRtLXNzaCwgLmJ0bi10YmwsIC5wYnRuLCAudGJ0biwKICAuY29weS1idG4sIC5jb3B5LWxpbmstYnRuLCAubG9nb3V0LCAubWNsb3NlLAogIC5hYnRuLCAucG9ydC1idG4sIC5waWNrLW9wdCB7CiAgICBib3JkZXItcmFkaXVzOiAxMnB4ICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDRweCAwIHJnYmEoMCwwLDAsMC4zNSksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEyKSBpbnNldCwKICAgICAgMCA2cHggMTZweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjEycyBlYXNlICFpbXBvcnRhbnQ7CiAgICBib3JkZXItd2lkdGg6IDJweCAhaW1wb3J0YW50OwogIH0KICAuY2J0bjpob3ZlciwgLmJ0bi1yOmhvdmVyLCAuY29weS1idG46aG92ZXIsCiAgLmFidG46aG92ZXIsIC5wb3J0LWJ0bjpob3ZlciwgLnBpY2stb3B0OmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpIGluc2V0LAogICAgICAwIDEwcHggMjRweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQogIC5jYnRuOmFjdGl2ZSwgLmJ0bi1yOmFjdGl2ZSwgLmNvcHktYnRuOmFjdGl2ZSwKICAuYWJ0bjphY3RpdmUsIC5wb3J0LWJ0bjphY3RpdmUsIC5waWNrLW9wdDphY3RpdmUsCiAgLmJ0bi10Ymw6YWN0aXZlLCAubG9nb3V0OmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoM3B4KSBzY2FsZSgwLjk3KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCAxcHggMCByZ2JhKDAsMCwwLDAuNCksCiAgICAgIDAgMCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA2cyBlYXNlLCBib3gtc2hhZG93IDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CgogIC8qIHNlbC1jYXJkIDNEICovCiAgLnNlbC1jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjIpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDIwcHggcmdiYSgwLDAsMCwwLjEyKSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVgoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xOHMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVgoMnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA4cHggMCByZ2JhKDAsMCwwLDAuMjUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNnB4IDMycHggcmdiYSgwLDAsMCwwLjE4KSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgycHgpIHRyYW5zbGF0ZVgoMCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KCiAgLyogdWl0ZW1zIDNEICovCiAgLnVpdGVtIHsKICAgIGJvcmRlci1yYWRpdXM6IDE0cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgM3B4IDAgcmdiYSgwLDAsMCwwLjE4KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDcpIGluc2V0LAogICAgICAwIDZweCAxNHB4IHJnYmEoMCwwLDAsMC4wOCkgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjE1cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjE1cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjIyKSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDkpIGluc2V0LAogICAgICAwIDEycHggMjRweCByZ2JhKDAsMCwwLDAuMTIpICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTphY3RpdmUgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDJweCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAvKiBib3VuY2Uga2V5ZnJhbWUg4Liq4Liz4Lir4Lij4Lix4Lia4LiB4LiUICovCiAgQGtleWZyYW1lcyBidG4tYm91bmNlIHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHNjYWxlKDEpOyB9CiAgICAzMCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjkzKSB0cmFuc2xhdGVZKDNweCk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDEuMDQpIHRyYW5zbGF0ZVkoLTJweCk7IH0KICAgIDgwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTgpIHRyYW5zbGF0ZVkoMXB4KTsgfQogICAgMTAwJSB7IHRyYW5zZm9ybTogc2NhbGUoMSkgdHJhbnNsYXRlWSgwKTsgfQogIH0KICAuY2J0bjphY3RpdmUsIC5idG4tcjphY3RpdmUsIC5jb3B5LWJ0bjphY3RpdmUgeyBhbmltYXRpb246IGJ0bi1ib3VuY2UgMC4yOHMgZWFzZSBmb3J3YXJkcyAhaW1wb3J0YW50OyB9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gSEVBREVSIC0tPgogIDxkaXYgY2xhc3M9ImhkciIgaWQ9Imhkci1yb290Ij4KICAgIDxidXR0b24gY2xhc3M9ImxvZ291dCIgb25jbGljaz0iZG9Mb2dvdXQoKSI+4oapIOC4reC4reC4geC4iOC4suC4geC4o+C4sOC4muC4mjwvYnV0dG9uPgoKICAgIDwhLS0gTG9nbyBTVkcgKHNhbWUgYXMgbG9naW4pIC0tPgogICAgPGRpdiBjbGFzcz0iaGRyLWxvZ28tc3ZnLXdyYXAiPgogICAgICA8c3ZnIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdpZHRoPSI3MiIgaGVpZ2h0PSI3MiI+CiAgICAgICAgPGRlZnM+CiAgICAgICAgICA8bGluZWFyR3JhZGllbnQgaWQ9ImhXIiB4MT0iMCUiIHkxPSIwJSIgeDI9IjEwMCUiIHkyPSIwJSI+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMCUiICAgc3RvcC1jb2xvcj0iIzI1NjNlYiIvPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjUwJSIgIHN0b3AtY29sb3I9IiM2MGE1ZmEiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjMDZiNmQ0Ii8+CiAgICAgICAgICA8L2xpbmVhckdyYWRpZW50PgogICAgICAgICAgPHJhZGlhbEdyYWRpZW50IGlkPSJoQmciIGN4PSI1MCUiIGN5PSI1MCUiIHI9IjUwJSI+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMCUiICAgc3RvcC1jb2xvcj0iIzBmMWU0YSIgc3RvcC1vcGFjaXR5PSIwLjk1Ii8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzA2MGMxZSIgc3RvcC1vcGFjaXR5PSIwLjk4Ii8+CiAgICAgICAgICA8L3JhZGlhbEdyYWRpZW50PgogICAgICAgICAgPGZpbHRlciBpZD0iaEdsb3ciPgogICAgICAgICAgICA8ZmVHYXVzc2lhbkJsdXIgc3RkRGV2aWF0aW9uPSIyLjUiIHJlc3VsdD0iYiIvPgogICAgICAgICAgICA8ZmVNZXJnZT48ZmVNZXJnZU5vZGUgaW49ImIiLz48ZmVNZXJnZU5vZGUgaW49IlNvdXJjZUdyYXBoaWMiLz48L2ZlTWVyZ2U+CiAgICAgICAgICA8L2ZpbHRlcj4KICAgICAgICAgIDxjbGlwUGF0aCBpZD0iaENsaXAiPjxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0Ii8+PC9jbGlwUGF0aD4KICAgICAgICA8L2RlZnM+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDYiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSgzNyw5OSwyMzUsMC4xMikiIHN0cm9rZS13aWR0aD0iMSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQyIiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjIpIiBzdHJva2Utd2lkdGg9IjEiIHN0cm9rZS1kYXNoYXJyYXk9IjUgNCIgY2xhc3M9Imhkci1vcmJpdC1yaW5nIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzgiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSgzNyw5OSwyMzUsMC4yMikiIHN0cm9rZS13aWR0aD0iMSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0IiBmaWxsPSJ1cmwoI2hCZykiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ1cmwoI2hXKSIgc3Ryb2tlLXdpZHRoPSIxLjgiIG9wYWNpdHk9IjAuOSIvPgogICAgICAgIDxsaW5lIHgxPSI1MCIgeTE9IjE0IiB4Mj0iNTAiIHkyPSIyMCIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iNTAiIHkxPSI4MCIgeDI9IjUwIiB5Mj0iODYiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjE0IiB5MT0iNTAiIHgyPSIyMCIgeTI9IjUwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI4MCIgeTE9IjUwIiB4Mj0iODYiIHkyPSI1MCIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8ZyBjbGlwLXBhdGg9InVybCgjaENsaXApIj4KICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjE2LDUwIDI0LDUwIDI5LDMyIDM0LDY4IDM5LDMyIDQ0LDUwIDg0LDUwIgogICAgICAgICAgICBmaWxsPSJub25lIiBzdHJva2U9InVybCgjaFcpIiBzdHJva2Utd2lkdGg9IjIuMiIKICAgICAgICAgICAgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIgogICAgICAgICAgICBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLXdhdmUtYW5pbSIvPgogICAgICAgIDwvZz4KICAgICAgICA8Y2lyY2xlIGN4PSIyOSIgY3k9IjMyIiByPSIyLjUiIGZpbGw9IiM2MGE1ZmEiIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItZG90LTEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSIzOSIgY3k9IjMyIiByPSIyLjUiIGZpbGw9IiMwNmI2ZDQiIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItZG90LTIiLz4KICAgICAgICA8Y2lyY2xlIGN4PSIzNCIgY3k9IjY4IiByPSIyLjUiIGZpbGw9IiM2MGE1ZmEiIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItZG90LTEiLz4KICAgICAgPC9zdmc+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MThweDtmb250LXdlaWdodDo5MDA7bGV0dGVyLXNwYWNpbmc6NHB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNlMGYyZmUsIzYwYTVmYSwjMDZiNmQ0KTstd2Via2l0LWJhY2tncm91bmQtY2xpcDp0ZXh0Oy13ZWJraXQtdGV4dC1maWxsLWNvbG9yOnRyYW5zcGFyZW50O2JhY2tncm91bmQtY2xpcDp0ZXh0OyI+Q0hBSVlBPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjlweDtjb2xvcjpyZ2JhKDk2LDE2NSwyNTAsMC42KTttYXJnaW4tdG9wOjJweDsiPlBST0pFQ1Q8L2Rpdj4KICAgIDxkaXYgc3R5bGU9IndpZHRoOjE0MHB4O2hlaWdodDoxcHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdHJhbnNwYXJlbnQsIzYwYTVmYSwjMDZiNmQ0LHRyYW5zcGFyZW50KTttYXJnaW46NnB4IGF1dG87b3BhY2l0eTowLjU7Ij48L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNTUpO21hcmdpbi10b3A6MnB4OyI+VjJSQVkgJmFtcDsgU1NIPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjpyZ2JhKDk2LDE2NSwyNTAsMC41KTttYXJnaW4tdG9wOjRweDsiIGlkPSJoZHItZG9tYWluIj5TRUNVUkUgUEFORUw8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSBOQVYgLS0+CiAgPGRpdiBjbGFzcz0ibmF2Ij4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIGFjdGl2ZSIgb25jbGljaz0ic3coJ2Rhc2hib2FyZCcsdGhpcykiPvCfk4og4LmB4LiU4LiK4Lia4Lit4Lij4LmM4LiUPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2NyZWF0ZScsdGhpcykiPuKelSDguKrguKPguYnguLLguIfguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnbWFuYWdlJyx0aGlzKSI+8J+UpyDguIjguLHguJTguIHguLLguKPguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnb25saW5lJyx0aGlzKSI+8J+foiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnYmFuJyx0aGlzKSI+8J+aqyDguJvguKXguJTguYHguJrguJk8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgREFTSEJPQVJEIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMgYWN0aXZlIiBpZD0idGFiLWRhc2hib2FyZCI+CiAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgPHNwYW4gY2xhc3M9InNlYy10aXRsZSI+4pqhIFNZU1RFTSBNT05JVE9SPC9zcGFuPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgaWQ9ImJ0bi1yZWZyZXNoIiBvbmNsaWNrPSJsb2FkRGFzaCgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InNncmlkIj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPuKaoSBDUFUgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9ImNwdS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzRhZGU4MCIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0iY3B1LXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0iY3B1LWNvcmVzIj4tLSBjb3JlczwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwZyIgaWQ9ImNwdS1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+noCBSQU0gVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9InJhbS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzNiODJmNiIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0icmFtLXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0icmFtLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwdSIgaWQ9InJhbS1iYXIiIHN0eWxlPSJ3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjM2I4MmY2LCM2MGE1ZmEpIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7wn5K+IERJU0sgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdmFsIiBpZD0iZGlzay1wY3QiPi0tPHNwYW4+JTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0iZGlzay1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcG8iIGlkPSJkaXNrLWJhciIgc3R5bGU9IndpZHRoOjAlIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7ij7EgVVBUSU1FPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9InVwdGltZS12YWwiIHN0eWxlPSJmb250LXNpemU6MjBweCI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0idXB0aW1lLXN1YiI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YmRnIiBpZD0ibG9hZC1jaGlwcyI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+MkCBORVRXT1JLIEkvTzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJuZXQtcm93Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaRIFVwbG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtdXAiPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtdXAtdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRpdmlkZXIiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Im5pIiBzdHlsZT0idGV4dC1hbGlnbjpyaWdodCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaTIERvd25sb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJucyIgaWQ9Im5ldC1kbiI+LS08c3Bhbj4gLS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJudCIgaWQ9Im5ldC1kbi10b3RhbCI+dG90YWw6IC0tPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+ToSBYLVVJIFBBTkVMIFNUQVRVUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ4dWktcm93Ij4KICAgICAgICA8ZGl2IGlkPSJ4dWktcGlsbCIgY2xhc3M9Im9waWxsIG9mZiI+PHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj7guIHguLPguKXguLHguIfguYDguIrguYfguIQuLi48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ4dWktaW5mbyI+CiAgICAgICAgICA8ZGl2PuC5gOC4p+C4reC4o+C5jOC4iuC4seC4mSBYcmF5OiA8YiBpZD0ieHVpLXZlciI+LS08L2I+PC9kaXY+CiAgICAgICAgICA8ZGl2PkluYm91bmRzOiA8YiBpZD0ieHVpLWluYm91bmRzIj4tLTwvYj4g4Lij4Liy4Lii4LiB4Liy4LijPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPgogICAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+UpyBTRVJWSUNFIE1PTklUT1I8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZFNlcnZpY2VzKCkiPuKGuyDguYDguIrguYfguIQ8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1saXN0IiBpZD0ic3ZjLWxpc3QiPgogICAgICAgIDxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibHUiIGlkPSJsYXN0LXVwZGF0ZSI+4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAtLTwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBDUkVBVEUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1jcmVhdGUiPgoKICAgIDwhLS0g4pSA4pSAIFNFTEVDVE9SIChkZWZhdWx0IHZpZXcpIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImNyZWF0ZS1tZW51Ij4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIj7wn5uhIOC4o+C4sOC4muC4miAzWC1VSSBWTEVTUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ2FpcycpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtYWlzIj48aW1nIHNyYz0iaHR0cHM6Ly91cGxvYWQud2lraW1lZGlhLm9yZy93aWtpcGVkaWEvY29tbW9ucy90aHVtYi9mL2Y5L0FJU19sb2dvLnN2Zy8yMDBweC1BSVNfbG9nby5zdmcucG5nIiBvbmVycm9yPSJ0aGlzLnN0eWxlLmRpc3BsYXk9J25vbmUnO3RoaXMubmV4dFNpYmxpbmcuc3R5bGUuZGlzcGxheT0nZmxleCciIHN0eWxlPSJ3aWR0aDo1NnB4O2hlaWdodDo1NnB4O29iamVjdC1maXQ6Y29udGFpbiI+PHNwYW4gc3R5bGU9ImRpc3BsYXk6bm9uZTtmb250LXNpemU6MS40cmVtO3dpZHRoOjU2cHg7aGVpZ2h0OjU2cHg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOiMzZDdhMGUiPkFJUzwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgV1MgwrcgY2otZWJiLnNwZWVkdGVzdC5uZXQ8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3RydWUnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUiPjxzcGFuIHN0eWxlPSJmb250LXNpemU6MS4xcmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1uYW1lIHRydWUiPlRSVUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4ODgwIMK3IFdTIMK3IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgoKICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIiBzdHlsZT0ibWFyZ2luLXRvcDoyMHB4Ij7wn5SRIOC4o+C4sOC4muC4miBTU0ggV0VCU09DS0VUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlbC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgnc3NoJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC1zc2giPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZSI+U1NIJmd0Ozwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBzc2giPlNTSCDigJMgV1MgVHVubmVsPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5TU0ggwrcgUG9ydCA4MCDCtyBEcm9wYmVhciAxNDMvMTA5PGJyPk5wdlR1bm5lbCAvIERhcmtUdW5uZWw8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogQUlTIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tYWlzIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0iZm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciBhaXMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tbG9nbyBzZWwtYWlzLXNtIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi44cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXRpdGxlIGFpcyI+QUlTIOKAkyDguIHguLHguJnguKPguLHguYjguKc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODA4MCDCtyBTTkk6IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQGFpcyI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIGNidG4tYWlzIiBpZD0iYWlzLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ2FpcycpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIEFJUyBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJhaXMtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJhaXMtcmVzdWx0Ij4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJlcy1jbG9zZSIgb25jbGljaz0iZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fpcy1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1haXMtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLWFpcy11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici1haXMtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici1haXMtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci1haXMtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5rPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJhaXMtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBUUlVFIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tdHJ1ZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgdHJ1ZS1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBTTkk6IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQHRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLXRydWUiIGlkPSJ0cnVlLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ3RydWUnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBUUlVFIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0cnVlLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXRydWUtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLXRydWUtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItdHJ1ZS1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLXRydWUtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci10cnVlLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0idHJ1ZS1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFNTSCDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXNzaCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3NoLWRhcmstZm9ybSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPuKelSDguYDguJ7guLTguYjguKEgU1NIIFVTRVI8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgdHlwZT0icGFzc3dvcmQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKXguLTguKHguLTguJXguYTguK3guJ7guLU8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij7inIjvuI8g4LmA4Lil4Li34Lit4LiBIFBPUlQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwb3J0LWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4gYWN0aXZlLXA4MCIgaWQ9InBiLTgwIiBvbmNsaWNrPSJwaWNrUG9ydCgnODAnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCfjJA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA4MDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1zdWIiPldTIMK3IEhUVFA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4iIGlkPSJwYi00NDMiIG9uY2xpY2s9InBpY2tQb3J0KCc0NDMnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCflJI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA0NDM8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XU1MgwrcgU1NMPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPvCfjJAg4LmA4Lil4Li34Lit4LiBIElTUCAvIE9QRVJBVE9SPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtZHRhYyIgaWQ9InByby1kdGFjIiBvbmNsaWNrPSJwaWNrUHJvKCdkdGFjJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+8J+foDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RFRBQyBHQU1JTkc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJwcm8tdHJ1ZSIgb25jbGljaz0icGlja1BybygndHJ1ZScpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCflLU8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPlRSVUUgVFdJVFRFUjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+aGVscC54LmNvbTwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn5OxIOC5gOC4peC4t+C4reC4gSBBUFA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQgYS1ucHYiIGlkPSJhcHAtbnB2IiBvbmNsaWNrPSJwaWNrQXBwKCducHYnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMwZDJhM2E7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6Ljg1cmVtO2NvbG9yOiMwMGNjZmY7bGV0dGVyLXNwYWNpbmc6LTFweDtib3JkZXI6MS41cHggc29saWQgcmdiYSgwLDIwNCwyNTUsLjMpIj5uVjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+TnB2IFR1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+bnB2dC1zc2g6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJhcHAtZGFyayIgb25jbGljaz0icGlja0FwcCgnZGFyaycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPjxkaXYgc3R5bGU9IndpZHRoOjM4cHg7aGVpZ2h0OjM4cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6IzExMTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bWFyZ2luOjAgYXV0byAuMXJlbTtmb250LWZhbWlseTpzYW5zLXNlcmlmO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6LjYycmVtO2NvbG9yOiNmZmY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3JkZXI6MS41cHggc29saWQgIzQ0NCI+REFSSzwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RGFya1R1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+ZGFya3R1bm5lbDovLzwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4tc3NoIiBpZD0ic3NoLWJ0biIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKelSDguKrguKPguYnguLLguIcgVXNlcjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsaW5rLXJlc3VsdCIgaWQ9InNzaC1saW5rLXJlc3VsdCI+PC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBVc2VyIHRhYmxlIC0tPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIiBzdHlsZT0ibWFyZ2luOjAiPvCfk4sg4Lij4Liy4Lii4LiK4Li34LmI4LitIFVTRVJTPC9kaXY+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJzc2gtc2VhcmNoIiBwbGFjZWhvbGRlcj0i4LiE4LmJ4LiZ4Lir4LiyLi4uIiBvbmlucHV0PSJmaWx0ZXJTU0hVc2Vycyh0aGlzLnZhbHVlKSIKICAgICAgICAgICAgc3R5bGU9IndpZHRoOjEyMHB4O21hcmdpbjowO2ZvbnQtc2l6ZToxMXB4O3BhZGRpbmc6NnB4IDEwcHgiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InV0Ymwtd3JhcCI+CiAgICAgICAgICA8dGFibGUgY2xhc3M9InV0YmwiPgogICAgICAgICAgICA8dGhlYWQ+PHRyPjx0aD4jPC90aD48dGg+VVNFUk5BTUU8L3RoPjx0aD7guKvguKHguJTguK3guLLguKLguLg8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BQ1RJT048L3RoPjwvdHI+PC90aGVhZD4KICAgICAgICAgICAgPHRib2R5IGlkPSJzc2gtdXNlci10Ym9keSI+PHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9yOnZhcigtLW11dGVkKSI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwvdGJvZHk+CiAgICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICA8L2Rpdj48IS0tIC90YWItY3JlYXRlIC0tPgoKPCEtLSDilZDilZDilZDilZAgTUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJ1c2VyLXNlYXJjaCIgcGxhY2Vob2xkZXI9IvCflI0gIOC4hOC5ieC4meC4q+C4siB1c2VybmFtZS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgICA8ZGl2IGlkPSJ1c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4m+C4uOC5iOC4oeC5guC4q+C4peC4lOC5gOC4nuC4t+C5iOC4reC4lOC4tuC4h+C4guC5ieC4reC4oeC4ueC4pTwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkT25saW5lKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9jciI+CiAgICAgICAgPGRpdiBjbGFzcz0ib3BpbGwiIGlkPSJvbmxpbmUtcGlsbCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJvbmxpbmUtY291bnQiPjA8L3NwYW4+IOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJ1dCIgaWQ9Im9ubGluZS10aW1lIj4tLTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguKPguLXguYDguJ/guKPguIrguYDguJ7guLfguYjguK3guJTguLnguJzguLnguYnguYPguIrguYnguK3guK3guJnguYTguKXguJnguYw8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBCQU4g4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1iYW4iPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+aqyDguIjguLHguJTguIHguLLguKMgU1NIIFVzZXJzPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIFVTRVJOQU1FPC9kaXY+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImJhbi11c2VyIiBwbGFjZWhvbGRlcj0i4LmD4Liq4LmIIHVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4peC4miI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE1ODAzZCwjMjJjNTVlKSIgb25jbGljaz0iZGVsZXRlU1NIKCkiPvCfl5HvuI8g4Lil4LiaIFNTSCBVc2VyPC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYmFuLWFsZXJ0Ij48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIj7wn5OLIFNTSCBVc2VycyDguJfguLHguYnguIfguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBpZD0ic3NoLXVzZXItbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCjwvZGl2PjwhLS0gL3dyYXAgLS0+Cgo8IS0tIE1PREFMIC0tPgo8ZGl2IGNsYXNzPSJtb3ZlciIgaWQ9Im1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNtKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiIGlkPSJtdCI+4pqZ77iPIHVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbSgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ToSBQb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0iZGUiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OmIERhdGEgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGQiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OKIFRyYWZmaWMg4LmD4LiK4LmJPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR0ciI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk7EgSVAgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGkiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IG1vbm8iIGlkPSJkdXUiPi0tPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMHB4Ij7guYDguKXguLfguK3guIHguIHguLLguKPguJTguLPguYDguJnguLTguJnguIHguLLguKM8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImFncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVuZXcnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIQ8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdleHRlbmQnKSI+PGRpdiBjbGFzcz0iYWkiPvCfk4U8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdhZGRkYXRhJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OmPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oSBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKE8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignc2V0ZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+4pqW77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC4seC5ieC4hyBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4geC4s+C4q+C4meC4lOC5g+C4q+C4oeC5iDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdyZXNldCcpIj48ZGl2IGNsYXNzPSJhaSI+8J+UgzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKPguLXguYDguIvguJUgVHJhZmZpYzwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biBkYW5nZXIiIG9uY2xpY2s9Im1BY3Rpb24oJ2RlbGV0ZScpIj48ZGl2IGNsYXNzPSJhaSI+8J+Xke+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKXguJrguKLguLnguKo8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lil4Lia4LiW4Liy4Lin4LijPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4LmI4Lit4Lit4Liy4Lii4Li4IC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlbmV3Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IOKAlCDguKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4mTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXJlbmV3LWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZW5ldy1idG4iIG9uY2xpY2s9ImRvUmVuZXdVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKHguKfguLHguJkgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItZXh0ZW5kIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk4Ug4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIOKAlCDguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4meC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLWV4dGVuZC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZXh0ZW5kLWJ0biIgb25jbGljaz0iZG9FeHRlbmRVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguYDguJ7guLTguYjguKHguKfguLHguJk8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKEgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1hZGRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk6Yg4LmA4Lie4Li04LmI4LihIERhdGEg4oCUIOC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKHguIjguLLguIHguJfguLXguYjguKHguLXguK3guKLguLnguYg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4mSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1hZGRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIxMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tYWRkZGF0YS1idG4iIG9uY2xpY2s9ImRvQWRkRGF0YSgpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4LihIERhdGE8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguJXguLHguYnguIcgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1zZXRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPuKalu+4jyDguJXguLHguYnguIcgRGF0YSDigJQg4LiB4Liz4Lir4LiZ4LiUIExpbWl0IOC5g+C4q+C4oeC5iCAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPkRhdGEgTGltaXQgKEdCKSDigJQgMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXNldGRhdGEtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXNldGRhdGEtYnRuIiBvbmNsaWNrPSJkb1NldERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC4seC5ieC4hyBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItcmVzZXQiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+UgyDguKPguLXguYDguIvguJUgVHJhZmZpYyDigJQg4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJ4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4geC4suC4o+C4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4iOC4sOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lCBVcGxvYWQvRG93bmxvYWQg4LiX4Lix4LmJ4LiH4Lir4Lih4LiU4LiC4Lit4LiH4Lii4Li54Liq4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXJlc2V0LWJ0biIgb25jbGljaz0iZG9SZXNldFRyYWZmaWMoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lil4Lia4Lii4Li54LiqIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWRlbGV0ZSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+8J+Xke+4jyDguKXguJrguKLguLnguKog4oCUIOC4peC4muC4luC4suC4p+C4oyDguYTguKHguYjguKrguLLguKHguLLguKPguJbguIHguLnguYnguITguLfguJnguYTguJTguYk8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTJweCI+4Lii4Li54LiqIDxiIGlkPSJtLWRlbC1uYW1lIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+PC9iPiDguIjguLDguJbguLnguIHguKXguJrguK3guK3guIHguIjguLLguIHguKPguLDguJrguJrguJbguLLguKfguKM8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZGVsZXRlLWJ0biIgb25jbGljaz0iZG9EZWxldGVVc2VyKCkiIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2RjMjYyNiwjZWY0NDQ0KSI+8J+Xke+4jyDguKLguLfguJnguKLguLHguJnguKXguJrguKLguLnguKo8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ibW9kYWwtYWxlcnQiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPjwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQgc3JjPSJjb25maWcuanMiIG9uZXJyb3I9IndpbmRvdy5DSEFJWUFfQ09ORklHPXt9Ij48L3NjcmlwdD4KPHNjcmlwdD4KLy8g4pWQ4pWQ4pWQ4pWQIENPTkZJRyDilZDilZDilZDilZAKY29uc3QgQ0ZHID0gKHR5cGVvZiB3aW5kb3cuQ0hBSVlBX0NPTkZJRyAhPT0gJ3VuZGVmaW5lZCcpID8gd2luZG93LkNIQUlZQV9DT05GSUcgOiB7fTsKY29uc3QgSE9TVCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhvc3RuYW1lOwpjb25zdCBYVUkgID0gJy94dWktYXBpJzsgICAgICAgICAgLy8geC11aSBBUEkg4LmC4LiU4Lii4LiV4Lij4LiHIOC5hOC4oeC5iOC4nOC5iOC4suC4mSBtaWRkbGV3YXJlCmNvbnN0IEFQSSAgPSAnL2FwaSc7ICAgICAgICAgICAgICAgLy8gY2hhaXlhLXNzaC1hcGkgKFNTSCB1c2VycyDguYDguJfguYjguLLguJnguLHguYnguJkpCmNvbnN0IFNFU1NJT05fS0VZID0gJ2NoYWl5YV9hdXRoJzsKCi8vIOKUgOKUgCBEaXJlY3QgeC11aSBBUEkgaGVscGVycyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbGV0IF94dWlDb29raWUgPSBmYWxzZTsKYXN5bmMgZnVuY3Rpb24geHVpRW5zdXJlTG9naW4oKSB7CiAgaWYgKF94dWlDb29raWUpIHJldHVybiB0cnVlOwogIGNvbnN0IF9zID0gKCgpID0+IHsgdHJ5IHsgcmV0dXJuIEpTT04ucGFyc2Uoc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSl8fCd7fScpOyB9IGNhdGNoKGUpe3JldHVybnt9O30gfSkoKTsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyfHxDRkcueHVpX3VzZXJ8fCcnLCBwYXNzd29yZDogX3MucGFzc3x8Q0ZHLnh1aV9wYXNzfHwnJyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aUNvb2tpZSA9ICEhZC5zdWNjZXNzOwogIHJldHVybiBfeHVpQ29va2llOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aUdldChwYXRoKSB7CiAgaWYgKCFfeHVpQ29va2llKSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIHJldHVybiByLmpzb24oKTsKfQphc3luYyBmdW5jdGlvbiB4dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgYm9keTogSlNPTi5zdHJpbmdpZnkoYm9keSkKICB9KTsKICByZXR1cm4gci5qc29uKCk7Cn0KCi8vIFNlc3Npb24gY2hlY2sKY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwppZiAoIV9zLnVzZXIgfHwgIV9zLnBhc3MgfHwgRGF0ZS5ub3coKSA+PSAoX3MuZXhwfHwwKSkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8gSGVhZGVyIGRvbWFpbgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLWRvbWFpbicpLnRleHRDb250ZW50ID0gSE9TVCArICcgwrcgdjUnOwoKLy8g4pWQ4pWQ4pWQ4pWQIFVUSUxTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBmbXRCeXRlcyhiKSB7CiAgaWYgKCFiIHx8IGIgPT09IDApIHJldHVybiAnMCBCJzsKICBjb25zdCBrID0gMTAyNCwgdSA9IFsnQicsJ0tCJywnTUInLCdHQicsJ1RCJ107CiAgY29uc3QgaSA9IE1hdGguZmxvb3IoTWF0aC5sb2coYikvTWF0aC5sb2coaykpOwogIHJldHVybiAoYi9NYXRoLnBvdyhrLGkpKS50b0ZpeGVkKDEpKycgJyt1W2ldOwp9CmZ1bmN0aW9uIGZtdERhdGUobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgY29uc3QgZCA9IG5ldyBEYXRlKG1zKTsKICByZXR1cm4gZC50b0xvY2FsZURhdGVTdHJpbmcoJ3RoLVRIJyx7eWVhcjonbnVtZXJpYycsbW9udGg6J3Nob3J0JyxkYXk6J251bWVyaWMnfSk7Cn0KZnVuY3Rpb24gZGF5c0xlZnQobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gbnVsbDsKICByZXR1cm4gTWF0aC5jZWlsKChtcyAtIERhdGUubm93KCkpIC8gODY0MDAwMDApOwp9CmZ1bmN0aW9uIHNldFJpbmcoaWQsIHBjdCkgewogIGNvbnN0IGNpcmMgPSAxMzguMjsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoZWwpIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBjaXJjIC0gKGNpcmMgKiBNYXRoLm1pbihwY3QsMTAwKSAvIDEwMCk7Cn0KZnVuY3Rpb24gc2V0QmFyKGlkLCBwY3QsIHdhcm49ZmFsc2UpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuc3R5bGUud2lkdGggPSBNYXRoLm1pbihwY3QsMTAwKSArICclJzsKICBpZiAod2FybiAmJiBwY3QgPiA4NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KSc7CiAgZWxzZSBpZiAod2FybiAmJiBwY3QgPiA2NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2Y5NzMxNiwjZmI5MjNjKSc7Cn0KZnVuY3Rpb24gc2hvd0FsZXJ0KGlkLCBtc2csIHR5cGUpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcrdHlwZTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBpZiAodHlwZSA9PT0gJ29rJykgc2V0VGltZW91dCgoKT0+e2VsLnN0eWxlLmRpc3BsYXk9J25vbmUnO30sIDMwMDApOwp9CgovLyDilZDilZDilZDilZAgTkFWIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBzdyhuYW1lLCBlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZWMnKS5mb3JFYWNoKHM9PnMuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobj0+bi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nK25hbWUpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChuYW1lPT09J2NyZWF0ZScpIGNsb3NlRm9ybSgpOwogIGlmIChuYW1lPT09J2Rhc2hib2FyZCcpIGxvYWREYXNoKCk7CiAgaWYgKG5hbWU9PT0nbWFuYWdlJykgbG9hZFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0nb25saW5lJykgbG9hZE9ubGluZSgpOwogIGlmIChuYW1lPT09J2JhbicpIGxvYWRTU0hVc2VycygpOwp9CgovLyDilIDilIAgRm9ybSBuYXYg4pSA4pSACmxldCBfY3VyRm9ybSA9IG51bGw7CmZ1bmN0aW9uIG9wZW5Gb3JtKGlkKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBbJ2FpcycsJ3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gZj09PWlkID8gJ2Jsb2NrJyA6ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IGlkOwogIGlmIChpZD09PSdzc2gnKSBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB3aW5kb3cuc2Nyb2xsVG8oMCwwKTsKfQpmdW5jdGlvbiBjbG9zZUZvcm0oKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IG51bGw7Cn0KCmxldCBfd3NQb3J0ID0gJzgwJzsKZnVuY3Rpb24gdG9nUG9ydChidG4sIHBvcnQpIHsKICBfd3NQb3J0ID0gcG9ydDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M4MC1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzgwJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzNDQzLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9PT0nNDQzJyk7Cn0KZnVuY3Rpb24gdG9nR3JvdXAoYnRuLCBjbHMpIHsKICBidG4uY2xvc2VzdCgnZGl2JykucXVlcnlTZWxlY3RvckFsbChjbHMpLmZvckVhY2goYj0+Yi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYnRuLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9CgovLyDilZDilZDilZDilZAgWFVJIExPR0lOIChjb29raWUpIOKVkOKVkOKVkOKVkApsZXQgX3h1aUNvb2tpZSA9IGZhbHNlOwphc3luYyBmdW5jdGlvbiB4dWlMb2dpbigpIHsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyLCBwYXNzd29yZDogX3MucGFzcyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aUNvb2tpZSA9ICEhZC5zdWNjZXNzOwogIHJldHVybiBfeHVpT2s7Cn0KYXN5bmMgZnVuY3Rpb24geHVpR2V0KHBhdGgpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7CiAgcmV0dXJuIHIuanNvbigpOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aVBvc3QocGF0aCwgYm9keSkgewogIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICBib2R5OiBKU09OLnN0cmluZ2lmeShib2R5KQogIH0pOwogIHJldHVybiByLmpzb24oKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZERhc2goKSB7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1yZWZyZXNoJyk7CiAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyAuLi4nOwogIF94dWlDb29raWUgPSBmYWxzZTsgLy8gZm9yY2UgcmUtbG9naW4g4LmA4Liq4Lih4LitCgogIHRyeSB7CiAgICAvLyBTU0ggQVBJIHN0YXR1cwogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3QpIHsKICAgICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogICAgfQoKICAgIC8vIFhVSSBzZXJ2ZXIgc3RhdHVzCiAgICBjb25zdCBvayA9IGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICBpZiAoIW9rKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90IHJlZCI+PC9zcGFuPkxvZ2luIOC5hOC4oeC5iOC5hOC4lOC5iSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCBvZmYnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdiA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9zZXJ2ZXIvc3RhdHVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKHN2ICYmIHN2LnN1Y2Nlc3MgJiYgc3Yub2JqKSB7CiAgICAgIGNvbnN0IG8gPSBzdi5vYmo7CiAgICAgIC8vIENQVQogICAgICBjb25zdCBjcHUgPSBNYXRoLnJvdW5kKG8uY3B1IHx8IDApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LXBjdCcpLnRleHRDb250ZW50ID0gY3B1ICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LWNvcmVzJykudGV4dENvbnRlbnQgPSAoby5jcHVDb3JlcyB8fCBvLmxvZ2ljYWxQcm8gfHwgJy0tJykgKyAnIGNvcmVzJzsKICAgICAgc2V0UmluZygnY3B1LXJpbmcnLCBjcHUpOyBzZXRCYXIoJ2NwdS1iYXInLCBjcHUsIHRydWUpOwoKICAgICAgLy8gUkFNCiAgICAgIGNvbnN0IHJhbVQgPSAoKG8ubWVtPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIHJhbVUgPSAoKG8ubWVtPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgcmFtUCA9IHJhbVQgPiAwID8gTWF0aC5yb3VuZChyYW1VL3JhbVQqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tcGN0JykudGV4dENvbnRlbnQgPSByYW1QICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLWRldGFpbCcpLnRleHRDb250ZW50ID0gcmFtVS50b0ZpeGVkKDEpKycgLyAnK3JhbVQudG9GaXhlZCgxKSsnIEdCJzsKICAgICAgc2V0UmluZygncmFtLXJpbmcnLCByYW1QKTsgc2V0QmFyKCdyYW0tYmFyJywgcmFtUCwgdHJ1ZSk7CgogICAgICAvLyBEaXNrCiAgICAgIGNvbnN0IGRza1QgPSAoKG8uZGlzaz8udG90YWx8fDApLzEwNzM3NDE4MjQpLCBkc2tVID0gKChvLmRpc2s/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCBkc2tQID0gZHNrVCA+IDAgPyBNYXRoLnJvdW5kKGRza1UvZHNrVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stcGN0JykuaW5uZXJIVE1MID0gZHNrUCArICc8c3Bhbj4lPC9zcGFuPic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLWRldGFpbCcpLnRleHRDb250ZW50ID0gZHNrVS50b0ZpeGVkKDApKycgLyAnK2Rza1QudG9GaXhlZCgwKSsnIEdCJzsKICAgICAgc2V0QmFyKCdkaXNrLWJhcicsIGRza1AsIHRydWUpOwoKICAgICAgLy8gVXB0aW1lCiAgICAgIGNvbnN0IHVwID0gby51cHRpbWUgfHwgMDsKICAgICAgY29uc3QgdWQgPSBNYXRoLmZsb29yKHVwLzg2NDAwKSwgdWggPSBNYXRoLmZsb29yKCh1cCU4NjQwMCkvMzYwMCksIHVtID0gTWF0aC5mbG9vcigodXAlMzYwMCkvNjApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXZhbCcpLnRleHRDb250ZW50ID0gdWQgPiAwID8gdWQrJ2QgJyt1aCsnaCcgOiB1aCsnaCAnK3VtKydtJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS1zdWInKS50ZXh0Q29udGVudCA9IHVkKyfguKfguLHguJkgJyt1aCsn4LiK4LihLiAnK3VtKyfguJnguLLguJfguLUnOwogICAgICBjb25zdCBsb2FkcyA9IG8ubG9hZHMgfHwgW107CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2FkLWNoaXBzJykuaW5uZXJIVE1MID0gbG9hZHMubWFwKChsLGkpPT4KICAgICAgICBgPHNwYW4gY2xhc3M9ImJkZyI+JHtbJzFtJywnNW0nLCcxNW0nXVtpXX06ICR7bC50b0ZpeGVkKDIpfTwvc3Bhbj5gKS5qb2luKCcnKTsKCiAgICAgIC8vIE5ldHdvcmsKICAgICAgaWYgKG8ubmV0SU8pIHsKICAgICAgICBjb25zdCB1cF9iID0gby5uZXRJTy51cHx8MCwgZG5fYiA9IG8ubmV0SU8uZG93bnx8MDsKICAgICAgICBjb25zdCB1cEZtdCA9IGZtdEJ5dGVzKHVwX2IpLCBkbkZtdCA9IGZtdEJ5dGVzKGRuX2IpOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAnKS5pbm5lckhUTUwgPSB1cEZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuJykuaW5uZXJIVE1MID0gZG5GbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgIH0KICAgICAgaWYgKG8ubmV0VHJhZmZpYykgewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAtdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMuc2VudHx8MCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbi10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5yZWN2fHwwKTsKICAgICAgfQoKICAgICAgLy8gWFVJIHZlcnNpb24KICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS12ZXInKS50ZXh0Q29udGVudCA9IG8ueHJheVZlcnNpb24gfHwgJy0tJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj7guK3guK3guJnguYTguKXguJnguYwnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwnOwogICAgfQoKICAgIC8vIEluYm91bmRzIGNvdW50CiAgICBjb25zdCBpYmwgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChpYmwgJiYgaWJsLnN1Y2Nlc3MpIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1pbmJvdW5kcycpLnRleHRDb250ZW50ID0gKGlibC5vYmp8fFtdKS5sZW5ndGg7CiAgICB9CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xhc3QtdXBkYXRlJykudGV4dENvbnRlbnQgPSAn4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAnICsgbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zb2xlLmVycm9yKGUpOwogIH0gZmluYWxseSB7CiAgICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IOC4o+C4teC5gOC4n+C4o+C4iic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU0VSVklDRVMg4pWQ4pWQ4pWQ4pWQCmNvbnN0IFNWQ19ERUYgPSBbCiAgeyBrZXk6J3h1aScsICAgICAgaWNvbjon8J+ToScsIG5hbWU6J3gtdWkgUGFuZWwnLCAgICAgIHBvcnQ6JzoyMDUzJyB9LAogIHsga2V5Oidzc2gnLCAgICAgIGljb246J/CfkI0nLCBuYW1lOidTU0ggQVBJJywgICAgICAgICAgcG9ydDonOjY3ODknIH0sCiAgeyBrZXk6J2Ryb3BiZWFyJywgaWNvbjon8J+QuycsIG5hbWU6J0Ryb3BiZWFyIFNTSCcsICAgICBwb3J0Oic6MTQzIDoxMDknIH0sCiAgeyBrZXk6J25naW54JywgICAgaWNvbjon8J+MkCcsIG5hbWU6J25naW54IC8gUGFuZWwnLCAgICBwb3J0Oic6ODAgOjQ0MycgfSwKICB7IGtleTonc3Nod3MnLCAgICBpY29uOifwn5SSJywgbmFtZTonV1MtU3R1bm5lbCcsICAgICAgIHBvcnQ6Jzo4MOKGkjoxNDMnIH0sCiAgeyBrZXk6J2JhZHZwbicsICAgaWNvbjon8J+OricsIG5hbWU6J0JhZFZQTiBVRFBHVycsICAgICBwb3J0Oic6NzMwMCcgfSwKXTsKZnVuY3Rpb24gcmVuZGVyU2VydmljZXMobWFwKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gU1ZDX0RFRi5tYXAocyA9PiB7CiAgICBjb25zdCB1cCA9IG1hcFtzLmtleV0gPT09IHRydWUgfHwgbWFwW3Mua2V5XSA9PT0gJ2FjdGl2ZSc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InN2YyAke3VwPycnOidkb3duJ30iPgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnICR7dXA/Jyc6J3JlZCd9Ij48L3NwYW4+PHNwYW4+JHtzLmljb259PC9zcGFuPgogICAgICAgIDxkaXY+PGRpdiBjbGFzcz0ic3ZjLW4iPiR7cy5uYW1lfTwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj4ke3MucG9ydH08L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJyYmRnICR7dXA/Jyc6J2Rvd24nfSI+JHt1cD8nUlVOTklORyc6J0RPV04nfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFNlcnZpY2VzKCkgewogIHRyeSB7CiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvZGl2Pic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU1NIIFBJQ0tFUiBTVEFURSDilZDilZDilZDilZAKY29uc3QgUFJPUyA9IHsKICBkdGFjOiB7CiAgICBuYW1lOiAnRFRBQyBHQU1JTkcnLAogICAgcHJveHk6ICcxMDQuMTguNjMuMTI0OjgwJywKICAgIHBheWxvYWQ6ICdDT05ORUNUIC8gIEhUVFAvMS4xIFtjcmxmXUhvc3Q6IGRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb20gW2NybGZdW2NybGZdUEFUQ0ggLyBIVFRQLzEuMVtjcmxmXUhvc3Q6W2hvc3RdW2NybGZdVXBncmFkZTpVc2VyLUFnZW50OiBbdWFdW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0sCiAgdHJ1ZTogewogICAgbmFtZTogJ1RSVUUgVFdJVFRFUicsCiAgICBwcm94eTogJzEwNC4xOC4zOS4yNDo4MCcsCiAgICBwYXlsb2FkOiAnUE9TVCAvIEhUVFAvMS4xW2NybGZdSG9zdDpoZWxwLnguY29tW2NybGZdVXNlci1BZ2VudDogW3VhXVtjcmxmXVtjcmxmXVtzcGxpdF1bY3JdUEFUQ0ggLyBIVFRQLzEuMVtjcmxmXUhvc3Q6IFtob3N0XVtjcmxmXVVwZ3JhZGU6IHdlYnNvY2tldFtjcmxmXUNvbm5lY3Rpb246VXBncmFkZVtjcmxmXVtjcmxmXScsCiAgICBkYXJrUHJveHk6ICd0cnVldmlwYW5saW5lLmdvZHZwbi5zaG9wJywgZGFya1Byb3h5UG9ydDogODAKICB9Cn07CmNvbnN0IE5QVl9IT1NUID0gJ3d3dy5wcm9qZWN0LmdvZHZwbi5zaG9wJywgTlBWX1BPUlQgPSA4MDsKbGV0IF9zc2hQcm8gPSAnZHRhYycsIF9zc2hBcHAgPSAnbnB2JywgX3NzaFBvcnQgPSAnODAnOwoKZnVuY3Rpb24gcGlja1BvcnQocCkgewogIF9zc2hQb3J0ID0gcDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGItODAnKS5jbGFzc05hbWUgID0gJ3BvcnQtYnRuJyArIChwPT09JzgwJyAgPyAnIGFjdGl2ZS1wODAnICA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGItNDQzJykuY2xhc3NOYW1lID0gJ3BvcnQtYnRuJyArIChwPT09JzQ0MycgPyAnIGFjdGl2ZS1wNDQzJyA6ICcnKTsKfQpmdW5jdGlvbiBwaWNrUHJvKHApIHsKICBfc3NoUHJvID0gcDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLWR0YWMnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0nZHRhYycgPyAnIGEtZHRhYycgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byby10cnVlJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChwPT09J3RydWUnID8gJyBhLXRydWUnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tBcHAoYSkgewogIF9zc2hBcHAgPSBhOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtbnB2JykuY2xhc3NOYW1lICA9ICdwaWNrLW9wdCcgKyAoYT09PSducHYnICA/ICcgYS1ucHYnICA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwLWRhcmsnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKGE9PT0nZGFyaycgPyAnIGEtZGFyaycgOiAnJyk7Cn0KZnVuY3Rpb24gYnVpbGROcHZMaW5rKG5hbWUsIHBhc3MsIHBybykgewogIGNvbnN0IGogPSB7CiAgICBzc2hDb25maWdUeXBlOidTU0gtUHJveHktUGF5bG9hZCcsIHJlbWFya3M6cHJvLm5hbWUrJy0nK25hbWUsCiAgICBzc2hIb3N0Ok5QVl9IT1NULCBzc2hQb3J0Ok5QVl9QT1JULAogICAgc3NoVXNlcm5hbWU6bmFtZSwgc3NoUGFzc3dvcmQ6cGFzcywKICAgIHNuaTonJywgdGxzVmVyc2lvbjonREVGQVVMVCcsCiAgICBodHRwUHJveHk6cHJvLnByb3h5LCBhdXRoZW50aWNhdGVQcm94eTpmYWxzZSwKICAgIHByb3h5VXNlcm5hbWU6JycsIHByb3h5UGFzc3dvcmQ6JycsCiAgICBwYXlsb2FkOnByby5wYXlsb2FkLAogICAgZG5zTW9kZTonVURQJywgZG5zU2VydmVyOicnLCBuYW1lc2VydmVyOicnLCBwdWJsaWNLZXk6JycsCiAgICB1ZHBnd1BvcnQ6NzMwMCwgdWRwZ3dUcmFuc3BhcmVudEROUzp0cnVlCiAgfTsKICByZXR1cm4gJ25wdnQtc3NoOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CmZ1bmN0aW9uIGJ1aWxkRGFya0xpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgcHAgPSAocHJvLnByb3h5fHwnJykuc3BsaXQoJzonKTsKICBjb25zdCBkaCA9IHBwWzBdIHx8IHByby5kYXJrUHJveHk7CiAgY29uc3QgaiA9IHsKICAgIGNvbmZpZ1R5cGU6J1NTSC1QUk9YWScsIHJlbWFya3M6cHJvLm5hbWUrJy0nK25hbWUsCiAgICBzc2hIb3N0OkhPU1QsIHNzaFBvcnQ6MTQzLAogICAgc3NoVXNlcjpuYW1lLCBzc2hQYXNzOnBhc3MsCiAgICBwYXlsb2FkOidHRVQgLyBIVFRQLzEuMVxyXG5Ib3N0OiAnK0hPU1QrJ1xyXG5VcGdyYWRlOiB3ZWJzb2NrZXRcclxuQ29ubmVjdGlvbjogVXBncmFkZVxyXG5cclxuJywKICAgIHByb3h5SG9zdDpkaCwgcHJveHlQb3J0OjgwLAogICAgdWRwZ3dBZGRyOicxMjcuMC4wLjEnLCB1ZHBnd1BvcnQ6NzMwMCwgdGxzRW5hYmxlZDpmYWxzZQogIH07CiAgcmV0dXJuICdkYXJrdHVubmVsLXNzaDovLycgKyBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChKU09OLnN0cmluZ2lmeShqKSkpKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIENSRUFURSBTU0gg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGNyZWF0ZVNTSCgpIHsKICBjb25zdCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWUudHJpbSgpOwogIGNvbnN0IHBhc3MgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZS50cmltKCk7CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtZGF5cycpLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBsICA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtaXAnKSA/IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtaXAnKS52YWx1ZSA6IDIpfHwyOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFwYXNzKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggUGFzc3dvcmQnLCdlcnInKTsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3BpbiIgc3R5bGU9ImJvcmRlci1jb2xvcjpyZ2JhKDM0LDE5Nyw5NCwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojMjJjNTVlIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgY29uc3QgcmVzRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWxpbmstcmVzdWx0Jyk7CiAgaWYgKHJlc0VsKSByZXNFbC5jbGFzc05hbWU9J2xpbmstcmVzdWx0JzsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2NyZWF0ZV9zc2gnLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHt1c2VyLCBwYXNzd29yZDpwYXNzLCBkYXlzLCBpcF9saW1pdDppcGx9KQogICAgfSk7CiAgICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBwcm8gID0gUFJPU1tfc3NoUHJvXSB8fCBQUk9TLmR0YWM7CiAgICBjb25zdCBsaW5rID0gX3NzaEFwcD09PSducHYnID8gYnVpbGROcHZMaW5rKHVzZXIscGFzcyxwcm8pIDogYnVpbGREYXJrTGluayh1c2VyLHBhc3MscHJvKTsKICAgIGNvbnN0IGlzTnB2ID0gX3NzaEFwcD09PSducHYnOwogICAgY29uc3QgbHBDbHMgPSBpc05wdiA/ICcnIDogJyBkYXJrLWxwJzsKICAgIGNvbnN0IGNDbHMgID0gaXNOcHYgPyAnbnB2JyA6ICdkYXJrJzsKICAgIGNvbnN0IGFwcExhYmVsID0gaXNOcHYgPyAnTnB2dCcgOiAnRGFya1R1bm5lbCc7CgogICAgaWYgKHJlc0VsKSB7CiAgICAgIHJlc0VsLmNsYXNzTmFtZSA9ICdsaW5rLXJlc3VsdCBzaG93JzsKICAgICAgY29uc3Qgc2FmZUxpbmsgPSBsaW5rLnJlcGxhY2UoL1xcL2csJ1xcXFwnKS5yZXBsYWNlKC8nL2csIlxcJyIpOwogICAgICByZXNFbC5pbm5lckhUTUwgPQogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXJlc3VsdC1oZHInPiIgKwogICAgICAgICAgIjxzcGFuIGNsYXNzPSdpbXAtYmFkZ2UgIitjQ2xzKyInPiIrYXBwTGFiZWwrIjwvc3Bhbj4iICsKICAgICAgICAgICI8c3BhbiBzdHlsZT0nZm9udC1zaXplOi42NXJlbTtjb2xvcjp2YXIoLS1tdXRlZCknPiIrcHJvLm5hbWUrIiBceGI3IFBvcnQgIitfc3NoUG9ydCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOiMyMmM1NWU7bWFyZ2luLWxlZnQ6YXV0byc+XHUyNzA1ICIrdXNlcisiPC9zcGFuPiIgKwogICAgICAgICI8L2Rpdj4iICsKICAgICAgICAiPGRpdiBjbGFzcz0nbGluay1wcmV2aWV3IitscENscysiJz4iK2xpbmsrIjwvZGl2PiIgKwogICAgICAgICI8YnV0dG9uIGNsYXNzPSdjb3B5LWxpbmstYnRuICIrY0NscysiJyBpZD0nY29weS1zc2gtYnRuJyBvbmNsaWNrPVwiY29weVNTSExpbmsoKVwiPiIrCiAgICAgICAgICAiXHVkODNkXHVkY2NiIENvcHkgIithcHBMYWJlbCsiIExpbmsiKwogICAgICAgICI8L2J1dHRvbj4iOwogICAgICB3aW5kb3cuX2xhc3RTU0hMaW5rID0gbGluazsKICAgICAgd2luZG93Ll9sYXN0U1NIQXBwICA9IGNDbHM7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExhYmVsID0gYXBwTGFiZWw7CiAgICB9CgogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCDCtyDguKvguKHguJTguK3guLLguKLguLggJytkLmV4cCwnb2snKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlcicpLnZhbHVlPScnOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1wYXNzJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3NGMgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4p6VIOC4quC4o+C5ieC4suC4hyBVc2VyJzsgfQp9CmZ1bmN0aW9uIGNvcHlTU0hMaW5rKCkgewogIGNvbnN0IGxpbmsgPSB3aW5kb3cuX2xhc3RTU0hMaW5rfHwnJzsKICBjb25zdCBjQ2xzID0gd2luZG93Ll9sYXN0U1NIQXBwfHwnbnB2JzsKICBjb25zdCBsYWJlbCA9IHdpbmRvdy5fbGFzdFNTSExhYmVsfHwnTGluayc7CiAgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQobGluaykudGhlbihmdW5jdGlvbigpewogICAgY29uc3QgYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb3B5LXNzaC1idG4nKTsKICAgIGlmKGIpeyBiLnRleHRDb250ZW50PSdcdTI3MDUg4LiE4Lix4LiU4Lil4Lit4LiB4LmB4Lil4LmJ4LinISc7IHNldFRpbWVvdXQoZnVuY3Rpb24oKXtiLnRleHRDb250ZW50PSdcdWQ4M2RcdWRjY2IgQ29weSAnK2xhYmVsKycgTGluayc7fSwyMDAwKTsgfQogIH0pLmNhdGNoKGZ1bmN0aW9uKCl7IHByb21wdCgnQ29weSBsaW5rOicsbGluayk7IH0pOwp9CgovLyBTU0ggdXNlciB0YWJsZQpsZXQgX3NzaFRhYmxlVXNlcnMgPSBbXTsKYXN5bmMgZnVuY3Rpb24gbG9hZFNTSFRhYmxlSW5Gb3JtKCkgewogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvdXNlcnMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIF9zc2hUYWJsZVVzZXJzID0gZC51c2VycyB8fCBbXTsKICAgIHJlbmRlclNTSFRhYmxlKF9zc2hUYWJsZVVzZXJzKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnN0IHRiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLXRib2R5Jyk7CiAgICBpZih0YikgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjojZWY0NDQ0O3BhZGRpbmc6MTZweCI+4LmA4LiK4Li34LmI4Lit4Lih4LiV4LmI4LitIFNTSCBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJPC90ZD48L3RyPic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclNTSFRhYmxlKHVzZXJzKSB7CiAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICBpZiAoIXRiKSByZXR1cm47CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsKICAgIHRiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO3BhZGRpbmc6MjBweCI+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvdGQ+PC90cj4nOwogICAgcmV0dXJuOwogIH0KICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiAgdGIuaW5uZXJIVE1MID0gdXNlcnMubWFwKGZ1bmN0aW9uKHUsaSl7CiAgICBjb25zdCBleHBpcmVkID0gdS5leHAgJiYgdS5leHAgPCBub3c7CiAgICBjb25zdCBhY3RpdmUgID0gdS5hY3RpdmUgIT09IGZhbHNlICYmICFleHBpcmVkOwogICAgY29uc3QgZExlZnQgICA9IHUuZXhwID8gTWF0aC5jZWlsKChuZXcgRGF0ZSh1LmV4cCktRGF0ZS5ub3coKSkvODY0MDAwMDApIDogbnVsbDsKICAgIGNvbnN0IGJhZGdlICAgPSBhY3RpdmUKICAgICAgPyAnPHNwYW4gY2xhc3M9ImJkZyBiZGctZyI+QUNUSVZFPC9zcGFuPicKICAgICAgOiAnPHNwYW4gY2xhc3M9ImJkZyBiZGctciI+RVhQSVJFRDwvc3Bhbj4nOwogICAgY29uc3QgZFRhZyA9IGRMZWZ0IT09bnVsbAogICAgICA/ICc8c3BhbiBjbGFzcz0iZGF5cy1iYWRnZSI+JysoZExlZnQ+MD9kTGVmdCsnZCc6J+C4q+C4oeC4lCcpKyc8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iZGF5cy1iYWRnZSI+XHUyMjFlPC9zcGFuPic7CiAgICByZXR1cm4gJzx0cj48dGQgc3R5bGU9ImNvbG9yOnZhcigtLW11dGVkKSI+JysoaSsxKSsnPC90ZD4nICsKICAgICAgJzx0ZD48Yj4nK3UudXNlcisnPC9iPjwvdGQ+JyArCiAgICAgICc8dGQgc3R5bGU9ImZvbnQtc2l6ZToxMXB4O2NvbG9yOicrKGV4cGlyZWQ/JyNlZjQ0NDQnOid2YXIoLS1tdXRlZCknKSsnIj4nKwogICAgICAgICh1LmV4cHx8J+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcpKyc8L3RkPicgKwogICAgICAnPHRkPicrYmFkZ2UrJzwvdGQ+JyArCiAgICAgICc8dGQ+PGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo0cHg7YWxpZ24taXRlbXM6Y2VudGVyIj4nKwogICAgICAgICc8YnV0dG9uIGNsYXNzPSJidG4tdGJsIiB0aXRsZT0i4LiV4LmI4Lit4Lit4Liy4Lii4Li4IiBvbmNsaWNrPSJvcGVuU1NIUmVuZXdNb2RhbChcJycrdS51c2VyKydcJykiPvCflIQ8L2J1dHRvbj4nKwogICAgICAgICc8YnV0dG9uIGNsYXNzPSJidG4tdGJsIiB0aXRsZT0i4Lil4LiaIiBvbmNsaWNrPSJkZWxTU0hVc2VyKFwnJyt1LnVzZXIrJ1wnKSIgc3R5bGU9ImJvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwuMykiPvCfl5HvuI88L2J1dHRvbj4nKwogICAgICAgIGRUYWcrCiAgICAgICc8L2Rpdj48L3RkPjwvdHI+JzsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJTU0hVc2VycyhxKSB7CiAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMuZmlsdGVyKGZ1bmN0aW9uKHUpe3JldHVybiAodS51c2VyfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpO30pKTsKfQovLyBTU0ggUmVuZXcgTW9kYWwKbGV0IF9yZW5ld1NTSFVzZXIgPSAnJzsKZnVuY3Rpb24gb3BlblNTSFJlbmV3TW9kYWwodXNlcikgewogIF9yZW5ld1NTSFVzZXIgPSB1c2VyOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctdXNlcm5hbWUnKS50ZXh0Q29udGVudCA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJykudmFsdWUgPSAnMzAnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY2xvc2VTU0hSZW5ld01vZGFsKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX3JlbmV3U1NIVXNlciA9ICcnOwp9CmFzeW5jIGZ1bmN0aW9uIGRvU1NIUmVuZXcoKSB7CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoIWRheXN8fGRheXM8PTApIHJldHVybjsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7IGJ0bi50ZXh0Q29udGVudCA9ICfguIHguLPguKXguLHguIfguJXguYjguK3guK3guLLguKLguLguLi4nOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvZXh0ZW5kX3NzaCcsewogICAgICBtZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXI6X3JlbmV3U1NIVXNlcixkYXlzfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4LiV4LmI4Lit4Lit4Liy4Lii4Li4ICcrX3JlbmV3U1NIVXNlcisnICsnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGNsb3NlU1NIUmVuZXdNb2RhbCgpOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7CiAgfSBmaW5hbGx5IHsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOyBidG4udGV4dENvbnRlbnQgPSAn4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4reC4reC4suC4ouC4uCc7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIHJlbmV3U1NIVXNlcih1c2VyKSB7IG9wZW5TU0hSZW5ld01vZGFsKHVzZXIpOyB9CmFzeW5jIGZ1bmN0aW9uIGRlbFNTSFVzZXIodXNlcikgewogIGlmICghY29uZmlybSgn4Lil4LiaIFNTSCB1c2VyICInK3VzZXIrJyIg4LiW4Liy4Lin4LijPycpKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9kZWxldGVfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pCiAgICB9KS50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKTt9KTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKHIuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzA1IOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IGFsZXJ0KCdcdTI3NGMgJytlLm1lc3NhZ2UpOyB9Cn0KLy8g4pWQ4pWQ4pWQ4pWQIENSRUFURSBWTEVTUyDilZDilZDilZDilZAKZnVuY3Rpb24gZ2VuVVVJRCgpIHsKICByZXR1cm4gJ3h4eHh4eHh4LXh4eHgtNHh4eC15eHh4LXh4eHh4eHh4eHh4eCcucmVwbGFjZSgvW3h5XS9nLGM9PnsKICAgIGNvbnN0IHI9TWF0aC5yYW5kb20oKSoxNnwwOyByZXR1cm4gKGM9PT0neCc/cjoociYweDN8MHg4KSkudG9TdHJpbmcoMTYpOwogIH0pOwp9CmFzeW5jIGZ1bmN0aW9uIGNyZWF0ZVZMRVNTKGNhcnJpZXIpIHsKICBjb25zdCBlbWFpbEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWVtYWlsJyk7CiAgY29uc3QgZGF5c0VsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1kYXlzJyk7CiAgY29uc3QgaXBFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1pcCcpOwogIGNvbnN0IGdiRWwgICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZ2InKTsKICBjb25zdCBlbWFpbCAgID0gZW1haWxFbC52YWx1ZS50cmltKCk7CiAgY29uc3QgZGF5cyAgICA9IHBhcnNlSW50KGRheXNFbC52YWx1ZSl8fDMwOwogIGNvbnN0IGlwTGltaXQgPSBwYXJzZUludChpcEVsLnZhbHVlKXx8MjsKICBjb25zdCBnYiAgICAgID0gcGFyc2VJbnQoZ2JFbC52YWx1ZSl8fDA7CiAgaWYgKCFlbWFpbCkgcmV0dXJuIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggRW1haWwvVXNlcm5hbWUnLCdlcnInKTsKCiAgY29uc3QgcG9ydCA9IGNhcnJpZXI9PT0nYWlzJyA/IDgwODAgOiA4ODgwOwogIGNvbnN0IHNuaSAgPSBjYXJyaWVyPT09J2FpcycgPyAnY2otZWJiLnNwZWVkdGVzdC5uZXQnIDogJ3RydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXMnOwoKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYnRuJyk7CiAgYnRuLmRpc2FibGVkPXRydWU7IGJ0bi5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0JykuY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpOwoKICB0cnkgewogICAgaWYgKCFfeHVpQ29va2llKSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgLy8g4Lir4LiyIGluYm91bmQgaWQKICAgIGNvbnN0IGxpc3QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgY29uc3QgaWIgPSAobGlzdC5vYmp8fFtdKS5maW5kKHg9PngucG9ydD09PXBvcnQpOwogICAgaWYgKCFpYikgdGhyb3cgbmV3IEVycm9yKGDguYTguKHguYjguJ7guJogaW5ib3VuZCBwb3J0ICR7cG9ydH0g4oCUIOC4o+C4seC4mSBzZXR1cCDguIHguYjguK3guJlgKTsKCiAgICBjb25zdCB1aWQgPSBnZW5VVUlEKCk7CiAgICBjb25zdCBleHBNcyA9IGRheXMgPiAwID8gKERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwKSA6IDA7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CgogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9hZGRDbGllbnQnLCB7CiAgICAgIGlkOiBpYi5pZCwKICAgICAgc2V0dGluZ3M6IEpTT04uc3RyaW5naWZ5KHsgY2xpZW50czpbewogICAgICAgIGlkOnVpZCwgZmxvdzonJywgZW1haWwsIGxpbWl0SXA6aXBMaW1pdCwKICAgICAgICB0b3RhbEdCOnRvdGFsQnl0ZXMsIGV4cGlyeVRpbWU6ZXhwTXMsIGVuYWJsZTp0cnVlLCB0Z0lkOicnLCBzdWJJZDonJywgY29tbWVudDonJywgcmVzZXQ6MAogICAgICB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBsaW5rID0gYHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06JHtwb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChlbWFpbCsnLScrKGNhcnJpZXI9PT0nYWlzJz8nQUlTJzonVFJVRScpKX1gOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWVtYWlsJykudGV4dENvbnRlbnQgPSBlbWFpbDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLXV1aWQnKS50ZXh0Q29udGVudCA9IHVpZDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWV4cCcpLnRleHRDb250ZW50ID0gZXhwTXMgPiAwID8gZm10RGF0ZShleHBNcykgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWxpbmsnKS50ZXh0Q29udGVudCA9IGxpbms7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0JykuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgLy8gR2VuZXJhdGUgUVIgY29kZQogICAgY29uc3QgcXJEaXYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcXInKTsKICAgIGlmIChxckRpdikgewogICAgICBxckRpdi5pbm5lckhUTUwgPSAnJzsKICAgICAgdHJ5IHsKICAgICAgICBuZXcgUVJDb2RlKHFyRGl2LCB7IHRleHQ6IGxpbmssIHdpZHRoOiAxODAsIGhlaWdodDogMTgwLCBjb3JyZWN0TGV2ZWw6IFFSQ29kZS5Db3JyZWN0TGV2ZWwuTSB9KTsKICAgICAgfSBjYXRjaChxckVycikgeyBxckRpdi5pbm5lckhUTUwgPSAnJzsgfQogICAgfQogICAgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgVkxFU1MgQWNjb3VudCDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZW1haWxFbC52YWx1ZT0nJzsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfimqEg4Liq4Lij4LmJ4Liy4LiHICcrKGNhcnJpZXI9PT0nYWlzJz8nQUlTJzonVFJVRScpKycgQWNjb3VudCc7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSBVU0VSUyDilZDilZDilZDilZAKbGV0IF9hbGxVc2VycyA9IFtdLCBfY3VyVXNlciA9IG51bGw7CmFzeW5jIGZ1bmN0aW9uIGxvYWRVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlDb29raWUgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICBjb25zdCBkID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGlmICghZC5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IoZC5tc2cgfHwgJ+C5guC4q+C4peC4lCBpbmJvdW5kcyDguYTguKHguYjguYTguJTguYknKTsKICAgIF9hbGxVc2VycyA9IFtdOwogICAgKGQub2JqfHxbXSkuZm9yRWFjaChpYiA9PiB7CiAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAoc2V0dGluZ3MuY2xpZW50c3x8W10pLmZvckVhY2goYyA9PiB7CiAgICAgICAgX2FsbFVzZXJzLnB1c2goewogICAgICAgICAgaWJJZDogaWIuaWQsIHBvcnQ6IGliLnBvcnQsIHByb3RvOiBpYi5wcm90b2NvbCwKICAgICAgICAgIGVtYWlsOiBjLmVtYWlsfHxjLmlkLCB1dWlkOiBjLmlkLAogICAgICAgICAgZXhwOiBjLmV4cGlyeVRpbWV8fDAsIHRvdGFsOiBjLnRvdGFsR0J8fDAsCiAgICAgICAgICB1cDogaWIudXB8fDAsIGRvd246IGliLmRvd258fDAsIGxpbWl0SXA6IGMubGltaXRJcHx8MAogICAgICAgIH0pOwogICAgICB9KTsKICAgIH0pOwogICAgcmVuZGVyVXNlcnMoX2FsbFVzZXJzKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQpmdW5jdGlvbiByZW5kZXJVc2Vycyh1c2VycykgewogIGlmICghdXNlcnMubGVuZ3RoKSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4nuC4muC4ouC4ueC4quC5gOC4i+C4reC4o+C5jDwvcD48L2Rpdj4nOyByZXR1cm47IH0KICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSB1c2Vycy5tYXAodSA9PiB7CiAgICBjb25zdCBkbCA9IGRheXNMZWZ0KHUuZXhwKTsKICAgIGxldCBiYWRnZSwgY2xzOwogICAgaWYgKCF1LmV4cCB8fCB1LmV4cD09PTApIHsgYmFkZ2U9J+KckyDguYTguKHguYjguIjguLPguIHguLHguJQnOyBjbHM9J29rJzsgfQogICAgZWxzZSBpZiAoZGwgPCAwKSAgICAgICAgIHsgYmFkZ2U9J+C4q+C4oeC4lOC4reC4suC4ouC4uCc7IGNscz0nZXhwJzsgfQogICAgZWxzZSBpZiAoZGwgPD0gMykgICAgICAgIHsgYmFkZ2U9J+KaoCAnK2RsKydkJzsgY2xzPSdzb29uJzsgfQogICAgZWxzZSAgICAgICAgICAgICAgICAgICAgIHsgYmFkZ2U9J+KckyAnK2RsKydkJzsgY2xzPSdvayc7IH0KICAgIGNvbnN0IGF2Q2xzID0gZGwgPCAwID8gJ2F2LXgnIDogJ2F2LWcnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSIgb25jbGljaz0ib3BlblVzZXIoJHtKU09OLnN0cmluZ2lmeSh1KS5yZXBsYWNlKC8iL2csJyZxdW90OycpfSkiPgogICAgICA8ZGl2IGNsYXNzPSJ1YXYgJHthdkNsc30iPiR7KHUuZW1haWx8fCc/JylbMF0udG9VcHBlckNhc2UoKX08L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZmxleDoxIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LmVtYWlsfTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InVtIj5Qb3J0ICR7dS5wb3J0fSDCtyAke2ZtdEJ5dGVzKHUudXArdS5kb3duKX0g4LmD4LiK4LmJPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2Nsc30iPiR7YmFkZ2V9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJVc2VycyhxKSB7CiAgcmVuZGVyVXNlcnMoX2FsbFVzZXJzLmZpbHRlcih1PT4odS5lbWFpbHx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50b0xvd2VyQ2FzZSgpKSkpOwp9CgovLyDilZDilZDilZDilZAgTU9EQUwgVVNFUiDilZDilZDilZDilZAKZnVuY3Rpb24gb3BlblVzZXIodSkgewogIGlmICh0eXBlb2YgdSA9PT0gJ3N0cmluZycpIHUgPSBKU09OLnBhcnNlKHUpOwogIF9jdXJVc2VyID0gdTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXQnKS50ZXh0Q29udGVudCA9ICfimpnvuI8gJyt1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdScpLnRleHRDb250ZW50ID0gdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHAnKS50ZXh0Q29udGVudCA9IHUucG9ydDsKICBjb25zdCBkbCA9IGRheXNMZWZ0KHUuZXhwKTsKICBjb25zdCBleHBUeHQgPSAhdS5leHB8fHUuZXhwPT09MCA/ICfguYTguKHguYjguIjguLPguIHguLHguJQnIDogZm10RGF0ZSh1LmV4cCk7CiAgY29uc3QgZGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGUnKTsKICBkZS50ZXh0Q29udGVudCA9IGV4cFR4dDsKICBkZS5jbGFzc05hbWUgPSAnZHYnICsgKGRsICE9PSBudWxsICYmIGRsIDwgMCA/ICcgcmVkJyA6ICcgZ3JlZW4nKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGQnKS50ZXh0Q29udGVudCA9IHUudG90YWwgPiAwID8gZm10Qnl0ZXModS50b3RhbCkgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHRyJykudGV4dENvbnRlbnQgPSBmbXRCeXRlcyh1LnVwK3UuZG93bik7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RpJykudGV4dENvbnRlbnQgPSB1LmxpbWl0SXAgfHwgJ+KInic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1dScpLnRleHRDb250ZW50ID0gdS51dWlkOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbSgpewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfbVN1YnMuZm9yRWFjaChrID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKfQoKLy8g4pSA4pSAIE1PREFMIDYtQUNUSU9OIFNZU1RFTSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY29uc3QgX21TdWJzID0gWydyZW5ldycsJ2V4dGVuZCcsJ2FkZGRhdGEnLCdzZXRkYXRhJywncmVzZXQnLCdkZWxldGUnXTsKZnVuY3Rpb24gbUFjdGlvbihrZXkpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScra2V5KTsKICBjb25zdCBpc09wZW4gPSBlbC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKTsKICBfbVN1YnMuZm9yRWFjaChrID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBpZiAoIWlzT3BlbikgewogICAgZWwuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgaWYgKGtleT09PSdkZWxldGUnICYmIF9jdXJVc2VyKSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1kZWwtbmFtZScpLnRleHRDb250ZW50ID0gX2N1clVzZXIuZW1haWw7CiAgICBzZXRUaW1lb3V0KCgpPT5lbC5zY3JvbGxJbnRvVmlldyh7YmVoYXZpb3I6J3Ntb290aCcsYmxvY2s6J25lYXJlc3QnfSksMTAwKTsKICB9Cn0KZnVuY3Rpb24gX21CdG5Mb2FkKGlkLCBsb2FkaW5nLCBvcmlnVGV4dCkgewogIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFiKSByZXR1cm47CiAgYi5kaXNhYmxlZCA9IGxvYWRpbmc7CiAgaWYgKGxvYWRpbmcpIHsgYi5kYXRhc2V0Lm9yaWcgPSBiLnRleHRDb250ZW50OyBiLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPiDguIHguLPguKXguLHguIfguJTguLPguYDguJnguLTguJnguIHguLLguKMuLi4nOyB9CiAgZWxzZSBpZiAoYi5kYXRhc2V0Lm9yaWcpIGIudGV4dENvbnRlbnQgPSBiLmRhdGFzZXQub3JpZzsKfQoKYXN5bmMgZnVuY3Rpb24gZG9SZW5ld1VzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBleHBNcyA9IERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC5iOC4reC4reC4suC4ouC4uOC4quC4s+C5gOC4o+C5h+C4iCAnK2RheXMrJyDguKfguLHguJkgKOC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iSknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZW5ldy1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9FeHRlbmRVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZXh0ZW5kLWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBiYXNlID0gKF9jdXJVc2VyLmV4cCAmJiBfY3VyVXNlci5leHAgPiBEYXRlLm5vdygpKSA/IF9jdXJVc2VyLmV4cCA6IERhdGUubm93KCk7CiAgICBjb25zdCBleHBNcyA9IGJhc2UgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSAnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIICjguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQpJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0FkZERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGFkZEdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1hZGRkYXRhLWdiJykudmFsdWUpfHwwOwogIGlmIChhZGRHYiA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKEnLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tYWRkZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgbmV3VG90YWwgPSAoX2N1clVzZXIudG90YWx8fDApICsgYWRkR2IqMTA3Mzc0MTgyNDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpuZXdUb3RhbCxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihIERhdGEgKycrYWRkR2IrJyBHQiDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1NldERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1zZXRkYXRhLWdiJykudmFsdWUpOwogIGlmIChpc05hTihnYil8fGdiPDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6dG90YWxCeXRlcyxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4Lix4LmJ4LiHIERhdGEgTGltaXQgJysoZ2I+MD9nYisnIEdCJzon4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1Jlc2V0VHJhZmZpYygpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLXJlc2V0LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvJytfY3VyVXNlci5pYklkKycvcmVzZXRDbGllbnRUcmFmZmljLycrX2N1clVzZXIuZW1haWwpOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE1MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRGVsZXRlVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL2RlbENsaWVudC8nK19jdXJVc2VyLnV1aWQpOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4Lil4Lia4Lii4Li54LiqICcrX2N1clVzZXIuZW1haWwrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTIwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1kZWxldGUtYnRuJywgZmFsc2UpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRPbmxpbmUoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBfeHVpQ29va2llID0gZmFsc2U7CiAgICBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgLy8g4LmC4Lir4Lil4LiUIGluYm91bmRzIOC4luC5ieC4suC4ouC4seC4h+C5hOC4oeC5iOC4oeC4tQogICAgaWYgKCFfYWxsVXNlcnMubGVuZ3RoKSB7CiAgICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpLmNhdGNoKCgpPT5udWxsKTsKICAgICAgaWYgKGQgJiYgZC5zdWNjZXNzKSB7CiAgICAgICAgX2FsbFVzZXJzID0gW107CiAgICAgICAgKGQub2JqfHxbXSkuZm9yRWFjaChpYiA9PiB7CiAgICAgICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICAgICAgX2FsbFVzZXJzLnB1c2goeyBpYklkOmliLmlkLCBwb3J0OmliLnBvcnQsIHByb3RvOmliLnByb3RvY29sLAogICAgICAgICAgICAgIGVtYWlsOmMuZW1haWx8fGMuaWQsIHV1aWQ6Yy5pZCwgZXhwOmMuZXhwaXJ5VGltZXx8MCwKICAgICAgICAgICAgICB0b3RhbDpjLnRvdGFsR0J8fDAsIHVwOmliLnVwfHwwLCBkb3duOmliLmRvd258fDAsIGxpbWl0SXA6Yy5saW1pdElwfHwwIH0pOwogICAgICAgICAgfSk7CiAgICAgICAgfSk7CiAgICAgIH0KICAgIH0KICAgIGNvbnN0IG9kID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL29ubGluZXMnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAvLyDguKPguK3guIfguKPguLHguJogZm9ybWF0OiB7b2JqOiBbLi4uXX0g4Lir4Lij4Li34LitIHtvYmo6IG51bGx9IOC4q+C4o+C4t+C4rSB7b2JqOiB7fX0KICAgIGxldCBlbWFpbHMgPSBbXTsKICAgIGlmIChvZCAmJiBvZC5vYmopIHsKICAgICAgaWYgKEFycmF5LmlzQXJyYXkob2Qub2JqKSkgZW1haWxzID0gb2Qub2JqOwogICAgICBlbHNlIGlmICh0eXBlb2Ygb2Qub2JqID09PSAnb2JqZWN0JykgZW1haWxzID0gT2JqZWN0LnZhbHVlcyhvZC5vYmopLmZsYXQoKS5maWx0ZXIoZT0+dHlwZW9mIGU9PT0nc3RyaW5nJyk7CiAgICB9CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWNvdW50JykudGV4dENvbnRlbnQgPSBlbWFpbHMubGVuZ3RoOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS10aW1lJykudGV4dENvbnRlbnQgPSBuZXcgRGF0ZSgpLnRvTG9jYWxlVGltZVN0cmluZygndGgtVEgnKTsKICAgIGlmICghZW1haWxzLmxlbmd0aCkgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+YtDwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4teC4ouC4ueC4quC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvcD48L2Rpdj4nOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCB1TWFwID0ge307CiAgICBfYWxsVXNlcnMuZm9yRWFjaCh1PT57IHVNYXBbdS5lbWFpbF09dTsgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUwgPSBlbWFpbHMubWFwKGVtYWlsPT57CiAgICAgIGNvbnN0IHUgPSB1TWFwW2VtYWlsXTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2IGF2LWciPvCfn6I8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7ZW1haWx9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+JHt1ID8gJ1BvcnQgJyt1LnBvcnQgOiAnVkxFU1MnfSDCtyDguK3guK3guJnguYTguKXguJnguYzguK3guKLguLnguYg8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayI+T05MSU5FPC9zcGFuPgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggVVNFUlMgKGJhbiB0YWIpIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkU1NIVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgY29uc3QgdXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1PT57CiAgICAgIGNvbnN0IGV4cCA9IHUuZXhwIHx8ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgICBjb25zdCBhY3RpdmUgPSB1LmFjdGl2ZSAhPT0gZmFsc2U7CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iPgogICAgICAgIDxkaXYgY2xhc3M9InVhdiAke2FjdGl2ZT8nYXYtZyc6J2F2LXgnfSI+JHt1LnVzZXJbMF0udG9VcHBlckNhc2UoKX08L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS51c2VyfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idW0iPuC4q+C4oeC4lOC4reC4suC4ouC4uDogJHtleHB9PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHthY3RpdmU/J29rJzonZXhwJ30iPiR7YWN0aXZlPydBY3RpdmUnOidFeHBpcmVkJ308L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIGRlbGV0ZVNTSCgpIHsKICBjb25zdCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgpOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiA/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pfSkudGhlbihyPT5yLmpzb24oKSk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yfHwn4Lil4Lia4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+KchSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVlPScnOwogICAgbG9hZFNTSFVzZXJzKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQp9CgovLyDilZDilZDilZDilZAgQ09QWSDilZDilZDilZDilZAKZnVuY3Rpb24gY29weUxpbmsoaWQsIGJ0bikgewogIGNvbnN0IHR4dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudDsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0eHQpLnRoZW4oKCk9PnsKICAgIGNvbnN0IG9yaWcgPSBidG4udGV4dENvbnRlbnQ7CiAgICBidG4udGV4dENvbnRlbnQ9J+KchSBDb3BpZWQhJzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9J3JnYmEoMzQsMTk3LDk0LC4xNSknOwogICAgc2V0VGltZW91dCgoKT0+eyBidG4udGV4dENvbnRlbnQ9b3JpZzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9Jyc7IH0sIDIwMDApOwogIH0pLmNhdGNoKCgpPT57IHByb21wdCgnQ29weSBsaW5rOicsIHR4dCk7IH0pOwp9CgovLyDilZDilZDilZDilZAgTE9HT1VUIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBkb0xvZ291dCgpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBJTklUIOKVkOKVkOKVkOKVkApsb2FkRGFzaCgpOwpsb2FkU2VydmljZXMoKTsKc2V0SW50ZXJ2YWwobG9hZERhc2gsIDMwMDAwKTsKPC9zY3JpcHQ+Cgo8IS0tIFNTSCBSRU5FVyBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJzc2gtcmVuZXctbW9kYWwiIG9uY2xpY2s9ImlmKGV2ZW50LnRhcmdldD09PXRoaXMpY2xvc2VTU0hSZW5ld01vZGFsKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IFNTSCBVc2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY2xvc2VTU0hSZW5ld01vZGFsKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJkZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfkaQgVXNlcm5hbWU8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0ic3NoLXJlbmV3LXVzZXJuYW1lIj4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmciIHN0eWxlPSJtYXJnaW4tdG9wOjE0cHgiPgogICAgICA8ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguJXguYjguK3guK3guLLguKLguLg8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIiBwbGFjZWhvbGRlcj0iMzAiPgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ic3NoLXJlbmV3LWJ0biIgb25jbGljaz0iZG9TU0hSZW5ldygpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgPC9kaXY+CjwvZGl2PgoKCjxzY3JpcHQ+Ci8vIERhc2hib2FyZCBGaXJlZmxpZXMgeDYwIOKAlCBmdWxsIHBhZ2UgZml4ZWQKKGZ1bmN0aW9uKCl7CiAgY29uc3QgY29sb3JzID0gWwogICAgJyNiNWY1NDInLCcjZDRmYzVhJywnIzdmZmYwMCcsJyNhYWZmNDQnLAogICAgJyNmNWY1NDInLCcjZmZlOTRkJywnI2ZmZDcwMCcsJyNmZmVjNmUnLAogICAgJyNhOGZmNzgnLCcjNzhmZjhhJywnIzU2ZmZiMCcsJyM5MGZmNmEnLAogIF07CiAgZm9yIChsZXQgaSA9IDA7IGkgPCA2MDsgaSsrKSB7CiAgICBjb25zdCBlbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgZWwuY2xhc3NOYW1lID0gJ2Rhc2gtZmYnOwogICAgY29uc3Qgc2l6ZSA9IE1hdGgucmFuZG9tKCkgKiAzLjUgKyAxLjU7CiAgICBjb25zdCBjb2xvciA9IGNvbG9yc1tNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkgKiBjb2xvcnMubGVuZ3RoKV07CiAgICBjb25zdCByID0gKCkgPT4gKChNYXRoLnJhbmRvbSgpIC0gMC41KSAqIDE4MCkgKyAncHgnOwogICAgY29uc3QgZER1ciA9IChNYXRoLnJhbmRvbSgpICogMTggKyAxMikudG9GaXhlZCgxKTsKICAgIGNvbnN0IGJEdXIgPSAoTWF0aC5yYW5kb20oKSAqIDMgICsgMikudG9GaXhlZCgxKTsKICAgIGNvbnN0IGRlbGF5ID0gKE1hdGgucmFuZG9tKCkgKiAxNSkudG9GaXhlZCgyKTsKICAgIGVsLnN0eWxlLmNzc1RleHQgPSBgCiAgICAgIHdpZHRoOiR7c2l6ZX1weDsgaGVpZ2h0OiR7c2l6ZX1weDsKICAgICAgbGVmdDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICAgIHRvcDoke01hdGgucmFuZG9tKCkqMTAwfSU7CiAgICAgIGJhY2tncm91bmQ6JHtjb2xvcn07CiAgICAgIGJveC1zaGFkb3c6IDAgMCAke3NpemUqMi41fXB4ICR7c2l6ZSoxLjV9cHggJHtjb2xvcn04OCwKICAgICAgICAgICAgICAgICAgMCAwICR7c2l6ZSo2fXB4ICR7Y29sb3J9NDQ7CiAgICAgIGFuaW1hdGlvbi1kdXJhdGlvbjogJHtkRHVyfXMsICR7YkR1cn1zOwogICAgICBhbmltYXRpb24tZGVsYXk6IC0ke2RlbGF5fXMsIC0ke2RlbGF5fXM7CiAgICAgIC0tZHgxOiR7cigpfTsgLS1keTE6JHtyKCl9OwogICAgICAtLWR4Mjoke3IoKX07IC0tZHkyOiR7cigpfTsKICAgICAgLS1keDM6JHtyKCl9OyAtLWR5Mzoke3IoKX07CiAgICAgIC0tZHg0OiR7cigpfTsgLS1keTQ6JHtyKCl9OwogICAgYDsKICAgIGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoZWwpOwogIH0KfSkoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=
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
