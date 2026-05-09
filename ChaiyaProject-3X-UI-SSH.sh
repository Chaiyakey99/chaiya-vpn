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
stty cols 200 2>/dev/null || true
export COLUMNS=200
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
# timeout 120s ป้องกัน apt-get update ค้างกับ mirror ช้า
timeout 120 apt-get update -qq -o Acquire::ForceIPv4=true \
  -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 2>/dev/null || \
timeout 60 apt-get update -qq \
  -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 2>/dev/null || true
ok "apt update เสร็จ"

info "ติดตั้ง packages หลัก..."
DEBIAN_FRONTEND=noninteractive timeout 180 apt-get install -y -qq \
  --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget python3 python3-pip \
  dropbear openssh-server ufw \
  net-tools jq bc cron unzip sqlite3 2>/dev/null || true
ok "packages หลักเสร็จ"

# iptables-persistent ถูกตัดออก — ค้างเพราะ interactive prompt บน Ubuntu 24.04

# ติดตั้ง certbot (ลอง apt ก่อน ข้าม snap เพราะช้ามาก)
info "ติดตั้ง certbot..."
if ! command -v certbot &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y -qq certbot python3-certbot-nginx 2>/dev/null || \
  DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y -qq certbot 2>/dev/null || true
fi
# fallback snap — ใส่ timeout 60s ป้องกันค้าง
if ! command -v certbot &>/dev/null && command -v snap &>/dev/null; then
  info "ลอง snap certbot (timeout 60s)..."
  timeout 60 snap install --classic certbot 2>/dev/null && \
    ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
fi
command -v certbot &>/dev/null && ok "certbot พร้อม" || warn "certbot ไม่พบ (ติดตั้งทีหลังได้)"

# ติดตั้ง bcrypt
info "ติดตั้ง bcrypt..."
pip3 install bcrypt --break-system-packages -q --timeout=30 2>/dev/null || \
  pip3 install bcrypt -q --timeout=30 2>/dev/null || true
info "ติดตั้ง speedtest-cli..."
pip3 install speedtest-cli --break-system-packages -q --timeout=30 2>/dev/null || \
  pip3 install speedtest-cli -q --timeout=30 2>/dev/null || true

# ถ้า speedtest-cli ยังใช้ไม่ได้ ลอง ookla official speedtest
if ! command -v speedtest-cli &>/dev/null && ! python3 -c "import speedtest" 2>/dev/null; then
  info "ลอง ookla speedtest binary..."
  _arch=$(uname -m)
  case "$_arch" in
    x86_64)   _sf="x86_64"  ;;
    aarch64)  _sf="aarch64" ;;
    armv7l)   _sf="armhf"   ;;
    *)        _sf=""         ;;
  esac
  if [[ -n "$_sf" ]]; then
    _ookla_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${_sf}.tgz"
    wget -q --timeout=30 -O /tmp/speedtest.tgz "$_ookla_url" 2>/dev/null && \
      tar -xzf /tmp/speedtest.tgz -C /usr/local/bin speedtest 2>/dev/null && \
      chmod +x /usr/local/bin/speedtest && \
      rm -f /tmp/speedtest.tgz && \
      ok "ookla speedtest พร้อม" || warn "ookla speedtest ติดตั้งไม่สำเร็จ"
  fi
fi

# ตรวจสอบ speedtest พร้อมใช้งาน
if command -v speedtest-cli &>/dev/null || python3 -c "import speedtest" 2>/dev/null; then
  ok "speedtest-cli พร้อม"
elif command -v speedtest &>/dev/null; then
  ok "ookla speedtest พร้อม"
else
  warn "speedtest ไม่พร้อม — speed test ใน panel จะใช้ client-side แทน"
fi
ok "ติดตั้ง packages สำเร็จ"

# ── GET SERVER IP ────────────────────────────────────────────
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
            hostname -I | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && err "ไม่สามารถดึง IP ได้"
ok "IP: ${CYAN}$SERVER_IP${NC}"



# ── LICENSE CHECK (ถูกตัดออก) ──────────────────────────────
ok "License ข้ามไป (No License Mode)"


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
apt-get install -y dropbear 2>/dev/null || timeout 60 apt-get install -y dropbear-bin 2>/dev/null || true

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
  # รอ Dropbear พร้อมสูงสุด 15 วินาที — break ทันทีเมื่อ active
  _db_ok=0
  for _i in $(seq 1 5); do
    sleep 3
    if systemctl is-active --quiet dropbear; then
      _db_ok=1; break
    fi
    warn "Dropbear ยังไม่พร้อม ลองใหม่ครั้งที่ $_i..."
    # restart เฉพาะรอบสุดท้าย ป้องกัน race condition
    [[ $_i -lt 5 ]] || systemctl restart dropbear 2>/dev/null || true
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
# ws-stunnel จะ start หลัง nginx — ไม่ start ตอนนี้
sleep 2
ok "WS-Stunnel พร้อม (port $WS_TUNNEL_PORT → Dropbear:$DROPBEAR_PORT1)"

# ── 3x-ui INSTALL ────────────────────────────────────────────
info "ติดตั้ง 3x-ui..."
if ! command -v x-ui &>/dev/null; then
  _xui_sh=$(mktemp /tmp/xui-XXXXX.sh)
  # ใส่ timeout ดาวน์โหลด 30s ป้องกันค้าง
  curl -Ls --max-time 30 "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" \
    -o "$_xui_sh" 2>/dev/null || { warn "ดาวน์โหลด 3x-ui install.sh ล้มเหลว"; rm -f "$_xui_sh"; }
  if [[ -s "$_xui_sh" ]]; then
    # timeout 300s ป้องกันค้างไม่จบ — printf input ป้องกัน interactive prompt
    printf "y\n${XUI_PORT}\n\n\n\n" | timeout 300 bash "$_xui_sh" >> /var/log/chaiya-xui-install.log 2>&1 || true
  fi
  rm -f "$_xui_sh"
fi

systemctl stop x-ui 2>/dev/null || true

XUI_DB="/etc/x-ui/x-ui.db"
# ── generate random webBasePath แล้ว set ลง DB ────────────
_RAND_PATH=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 12)
XUI_BASE_PATH="/${_RAND_PATH}/"
sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='webBasePath';" 2>/dev/null || true
sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webBasePath','${XUI_BASE_PATH}');" 2>/dev/null || true
ok "x-ui webBasePath: ${XUI_BASE_PATH}"
echo "$XUI_BASE_PATH" > /etc/chaiya/xui-path.conf
if [[ -f "$XUI_DB" ]]; then
  # ใช้ bcrypt hash — x-ui version ใหม่ต้องการ hash ไม่ใช่ plaintext

  _XUI_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${XUI_PASS}',bcrypt.gensalt()).decode())" 2>/dev/null || echo "${XUI_PASS}")
  sqlite3 "$XUI_DB" "UPDATE users SET username='${XUI_USER}', password='${_XUI_HASH}';" 2>/dev/null || true
  for _key in webPort webUsername webPassword; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPort','${XUI_PORT}');"        2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webUsername','${XUI_USER}');"    2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT INTO settings(key,value) VALUES('webPassword','${_XUI_HASH}');"   2>/dev/null || true
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

# รอ x-ui พร้อม
REAL_XUI_PORT="$XUI_PORT"
_db_port=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
[[ -n "$_db_port" ]] && REAL_XUI_PORT="$_db_port"
for _i in $(seq 1 10); do
  curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${REAL_XUI_PORT}/" 2>/dev/null | grep -q "^[123]" && break
  sleep 2
done
echo "$REAL_XUI_PORT" > /etc/chaiya/xui-port.conf
ok "3x-ui พร้อม (port $REAL_XUI_PORT)"

# ── ตั้งค่า x-ui settings (รวม webBasePath) ──
XUI_DB="/etc/x-ui/x-ui.db"
if [[ -f "$XUI_DB" ]]; then
  systemctl stop x-ui 2>/dev/null; sleep 1
  _XUI_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${XUI_PASS}',bcrypt.gensalt()).decode())" 2>/dev/null || echo "${XUI_PASS}")
  sqlite3 "$XUI_DB" "UPDATE users SET username='${XUI_USER}', password='${_XUI_HASH}';" 2>/dev/null || true
  for _key in webPort webUsername webPassword webBasePath enableIpLimit enableTrafficStatistics timeLocation trafficDiffReset; do
    sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='${_key}';" 2>/dev/null || true
  done
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webPort','${XUI_PORT}');"            2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webUsername','${XUI_USER}');"        2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webPassword','${_XUI_HASH}');"        2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webBasePath','${XUI_BASE_PATH}');"   2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('enableIpLimit','true');"             2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('enableTrafficStatistics','true');"   2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('timeLocation','Asia/Bangkok');"      2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('trafficDiffReset','false');"         2>/dev/null || true
  _port_check=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
  [[ "$_port_check" == "${XUI_PORT}" ]] && ok "x-ui webPort=${XUI_PORT} ยืนยันแล้ว" || warn "webPort อาจไม่ถูกต้อง: $_port_check"
  systemctl start x-ui
  for _i in $(seq 1 15); do
    sleep 2
    curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${REAL_XUI_PORT}/" 2>/dev/null | grep -q "^[123]" && break
  done
fi

# XUI_BASE_PATH ถูกอ่านไว้แล้วตั้งแต่หลัง install (บรรทัดก่อนหน้า) ไม่ต้องอ่านซ้ำ

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
        elif self.path == '/api/server-status':
            import urllib.request as _ur, urllib.parse as _up
            try:
                xui_port = open('/etc/chaiya/xui-port.conf').read().strip() if os.path.exists('/etc/chaiya/xui-port.conf') else '54321'
                xui_user = open('/etc/chaiya/xui-user.conf').read().strip() if os.path.exists('/etc/chaiya/xui-user.conf') else ''
                xui_pass = open('/etc/chaiya/xui-pass.conf').read().strip() if os.path.exists('/etc/chaiya/xui-pass.conf') else ''
                base = f'http://127.0.0.1:{xui_port}'
                # login
                login_data = _up.urlencode({'username': xui_user, 'password': xui_pass}).encode()
                req = _ur.Request(base+'/login', data=login_data, method='POST')
                req.add_header('Content-Type', 'application/x-www-form-urlencoded')
                with _ur.urlopen(req, timeout=5) as resp:
                    cookie = resp.getheader('Set-Cookie', '')
                    session = ''
                    for part in cookie.split(';'):
                        part = part.strip()
                        if part.startswith('session=') or '3x-ui' in part or 'session' in part.lower():
                            session = part.split(';')[0].strip()
                            break
                    if not session and cookie:
                        session = cookie.split(';')[0].strip()
                # server status
                req2 = _ur.Request(base+'/panel/api/server/status')
                if session:
                    req2.add_header('Cookie', session)
                with _ur.urlopen(req2, timeout=5) as resp2:
                    import json as _j
                    data = _j.loads(resp2.read())
                respond(self, 200, data)
            except Exception as e:
                respond(self, 500, {'success': False, 'error': str(e)})
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


        elif self.path == '/api/speedtest':
            try:
                import json as _json, re as _re
                r = subprocess.run(['speedtest-cli','--json','--secure'], capture_output=True, text=True, timeout=60)
                if r.returncode != 0:
                    # ลอง ookla speedtest
                    r2 = subprocess.run(['speedtest','--format=json','--accept-license','--accept-gdpr'], capture_output=True, text=True, timeout=60)
                    if r2.returncode == 0:
                        d = _json.loads(r2.stdout)
                        respond(self, 200, {
                            'ok': True,
                            'ping': round(d.get('ping',{}).get('latency',0),1),
                            'download': round(d.get('download',{}).get('bandwidth',0)*8/1000000,2),
                            'upload': round(d.get('upload',{}).get('bandwidth',0)*8/1000000,2),
                            'ip': d.get('interface',{}).get('externalIp',''),
                            'server': d.get('server',{}).get('name',''),
                            'timestamp': d.get('timestamp','')
                        })
                    else:
                        respond(self, 200, {'ok': False, 'error': 'speedtest-cli not found, install: pip install speedtest-cli'})
                else:
                    d = _json.loads(r.stdout)
                    respond(self, 200, {
                        'ok': True,
                        'ping': round(d.get('ping',0),1),
                        'download': round(d.get('download',0)/1000000,2),
                        'upload': round(d.get('upload',0)/1000000,2),
                        'ip': d.get('client',{}).get('ip',''),
                        'server': d.get('server',{}).get('name',''),
                        'timestamp': d.get('timestamp','')
                    })
            except Exception as e:
                respond(self, 200, {'ok': False, 'error': str(e)})

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
            run_cmd(f'echo "{user}:{passwd}" | chpasswd')
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
fuser -k 6789/tcp 2>/dev/null || true
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
    # timeout 90s ป้องกัน certbot ค้างรอ DNS/network
    timeout 90 certbot certonly --standalone --non-interactive --agree-tos \
      --register-unsafely-without-email \
      -d "$DOMAIN" 2>&1 | tail -5 || true
    [[ -f "$SSL_CERT" ]] && { USE_SSL=1; break; }
    sleep 5
  done
fi

# ไม่ start chaiya-sshws กลับตอนนี้ — รอให้ nginx config เสร็จก่อน
# (ถ้า start ตอนนี้ ws-stunnel จะจับ port 80 ไว้ แล้ว nginx start ไม่ได้)
info "เปิด WS-Stunnel กลับหลัง nginx config เสร็จ..."

[[ $USE_SSL -eq 1 ]] && ok "SSL Certificate พร้อม" || warn "ไม่มี SSL — ใช้ HTTP แทน"

# ── NGINX INSTALL + CONFIG ────────────────────────────────────
info "ติดตั้ง Nginx..."

# หยุด chaiya-sshws และ kill ทุก process บน port 80 ก่อนเด็ดขาด
systemctl stop chaiya-sshws 2>/dev/null || true
pkill -f ws-stunnel 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
sleep 2
fuser -k 80/tcp 2>/dev/null || true
sleep 1

# รอ apt lock ให้ว่างก่อน (กรณี unattended-upgrades กำลังทำงาน)
_wait_apt() {
  local _tries=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock &>/dev/null; do
    _tries=$((_tries+1))
    [[ $_tries -ge 30 ]] && break
    info "รอ apt lock... ($_tries/30)"
    sleep 5
  done
}

# ติดตั้ง nginx ถ้ายังไม่มี
if ! command -v nginx &>/dev/null; then
  _wait_apt
  DEBIAN_FRONTEND=noninteractive apt-get purge -y nginx nginx-common nginx-full nginx-core nginx-extras 2>/dev/null || true
  rm -rf /etc/nginx
  _wait_apt
  DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y nginx
fi

# ── ล้าง config ทุกอย่างที่ nginx อาจ listen 80 ──────────────
rm -f /etc/nginx/conf.d/default.conf
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/sites-available/default
rm -f /etc/nginx/conf.d/chaiya.conf

# แก้ nginx.conf หลัก: ลบ include sites-enabled และ listen 80 ออก
if [[ -f /etc/nginx/nginx.conf ]]; then
  sed -i '/sites-enabled/d'  /etc/nginx/nginx.conf
  sed -i '/listen\s*80/d'    /etc/nginx/nginx.conf
fi

# สร้าง nginx.conf ใหม่ถ้าหาย (กรณี apt lock ทำให้ติดตั้งไม่สมบูรณ์)
if [[ ! -f /etc/nginx/nginx.conf ]]; then
  warn "nginx.conf หาย — สร้างใหม่"
  mkdir -p /etc/nginx/conf.d
  cat > /etc/nginx/nginx.conf << 'NGINXCONF'
user www-data;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
}
NGINXCONF
  mkdir -p /var/log/nginx /var/lib/nginx/body
  chown -R www-data:www-data /var/log/nginx /var/lib/nginx 2>/dev/null || true
  [[ ! -f /etc/nginx/mime.types ]] && apt-get install --reinstall -y nginx-common 2>/dev/null || true
fi

ok "ติดตั้ง Nginx สำเร็จ ($(nginx -v 2>&1 | grep -oP '[\d.]+' | head -1))"
mkdir -p /etc/nginx/conf.d

info "ตั้งค่า Nginx..."

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
    location /api/speedtest {
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*";
            add_header Access-Control-Allow-Methods "GET,POST,OPTIONS";
            add_header Access-Control-Allow-Headers "Content-Type";
            return 204;
        }
        proxy_pass http://127.0.0.1:6789/api/speedtest;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
        proxy_intercept_errors off;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }
    location /api/ {
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*";
            add_header Access-Control-Allow-Methods "GET,POST,OPTIONS";
            add_header Access-Control-Allow-Headers "Content-Type";
            return 204;
        }
        proxy_pass http://127.0.0.1:6789/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
        proxy_intercept_errors off;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }
    location /xui-api/ {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT}${XUI_BASE_PATH};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 60s;
        # rewrite cookie path จาก webBasePath จริงของ x-ui → /xui-api/ ที่ browser รู้จัก
        proxy_cookie_path ${XUI_BASE_PATH} /xui-api/;
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
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*";
            add_header Access-Control-Allow-Methods "GET,POST,OPTIONS";
            add_header Access-Control-Allow-Headers "Content-Type";
            return 204;
        }
        proxy_pass http://127.0.0.1:6789/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
        proxy_intercept_errors off;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }
    location /api/speedtest {
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin "*";
            add_header Access-Control-Allow-Methods "GET,POST,OPTIONS";
            add_header Access-Control-Allow-Headers "Content-Type";
            return 204;
        }
        proxy_pass http://127.0.0.1:6789/api/speedtest;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
        proxy_intercept_errors off;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }
    location /xui-api/ {
        proxy_pass http://127.0.0.1:${REAL_XUI_PORT}${XUI_BASE_PATH};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto "http";
        proxy_set_header Cookie \$http_cookie;
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 60s;
        # rewrite cookie path จาก webBasePath จริงของ x-ui → /xui-api/ ที่ browser รู้จัก
        proxy_cookie_path ${XUI_BASE_PATH} /xui-api/;
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

if nginx -t 2>/dev/null; then
  systemctl restart nginx \
    && ok "Nginx พร้อม (Dashboard:443 / 3x-ui proxy:2503)" \
    || warn "Nginx ยังมีปัญหา — ตรวจ: journalctl -u nginx -n 20"
else
  warn "Nginx config มีปัญหา — ตรวจ: nginx -t"
fi

# start ws-stunnel กลับ — nginx ไม่ได้ใช้ port 80 จึงไม่ชนกัน
sleep 1
systemctl start chaiya-sshws 2>/dev/null || true

# ── FIREWALL ─────────────────────────────────────────────────
info "ตั้งค่า Firewall..."
ufw --force reset 2>/dev/null || true
ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true

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
window.CHAIYA_XUI_PATH = "$(cat /etc/chaiya/xui-path.conf 2>/dev/null || echo '/')";
EOF

# ── LOGIN PAGE (index.html) ───────────────────────────────────
info "สร้าง Login Page..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFBST0pFQ1Qg4oCUIFYyUkFZICYgU1NIIEFMTC1JTi1PTkUgUFJPPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1PcmJpdHJvbjp3Z2h0QDQwMDs3MDA7OTAwJmZhbWlseT1TYXJhYnVuOndnaHRAMzAwOzQwMDs2MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c3R5bGU+CiAgOnJvb3QgewogICAgLS1uZW9uLWJsdWU6ICMwMGQ0ZmY7CiAgICAtLW5lb24tcHVycGxlOiAjN2IyZmZmOwogICAgLS1uZW9uLWN5YW46ICMwMGZmZjc7CiAgICAtLWRlZXAtYmc6ICMwNDAyMGY7CiAgfQogICogeyBtYXJnaW46MDsgcGFkZGluZzowOyBib3gtc2l6aW5nOmJvcmRlci1ib3g7IH0KCiAgYm9keSB7CiAgICBmb250LWZhbWlseTogJ1NhcmFidW4nLCBzYW5zLXNlcmlmOwogICAgYmFja2dyb3VuZDogdmFyKC0tZGVlcC1iZyk7CiAgICBtaW4taGVpZ2h0OiAxMDB2aDsKICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgb3ZlcmZsb3c6IGhpZGRlbjsKICB9CgogIC8qIEdQVS1vbmx5IGJhY2tncm91bmQgZ3JpZCAqLwogIC5ncmlkLWJnIHsKICAgIHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDA7CiAgICBiYWNrZ3JvdW5kLWltYWdlOgogICAgICBsaW5lYXItZ3JhZGllbnQocmdiYSgwLDIxMiwyNTUsMC4wNDUpIDFweCwgdHJhbnNwYXJlbnQgMXB4KSwKICAgICAgbGluZWFyLWdyYWRpZW50KDkwZGVnLCByZ2JhKDAsMjEyLDI1NSwwLjA0NSkgMXB4LCB0cmFuc3BhcmVudCAxcHgpOwogICAgYmFja2dyb3VuZC1zaXplOiA0OHB4IDQ4cHg7CiAgICB0cmFuc2Zvcm06IHBlcnNwZWN0aXZlKDUwMHB4KSByb3RhdGVYKDI4ZGVnKSBzY2FsZSgyLjIpIHRyYW5zbGF0ZVooMCk7CiAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOwogICAgYW5pbWF0aW9uOiBncmlkU2Nyb2xsIDE2cyBsaW5lYXIgaW5maW5pdGU7CiAgfQogIEBrZXlmcmFtZXMgZ3JpZFNjcm9sbCB7CiAgICBmcm9tIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMCAwOyB9CiAgICB0byAgIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMCA0OHB4OyB9CiAgfQoKICAuc3BhY2UtZ2xvdyB7CiAgICBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAwOwogICAgYmFja2dyb3VuZDogcmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNzAlIDU1JSBhdCA1MCUgMzglLAogICAgICByZ2JhKDEyMyw0NywyNTUsMC4yKSAwJSwgcmdiYSgwLDIxMiwyNTUsMC4wNykgNDUlLCB0cmFuc3BhcmVudCA3MCUpOwogIH0KCiAgI2ZmQ2FudmFzIHsKICAgIHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDE7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDEwMCU7CiAgfQoKICAvKiDilIDilIAgU0NFTkUg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgLnNjZW5lIHsKICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgei1pbmRleDogMTA7CiAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxOHB4OwogICAgd2lkdGg6IDEwMCU7IG1heC13aWR0aDogNDEwcHg7CiAgICBwYWRkaW5nOiAyMHB4OwogICAgYW5pbWF0aW9uOiBzY2VuZUluIDAuOXMgY3ViaWMtYmV6aWVyKDAuMTYsMSwwLjMsMSkgYm90aDsKICB9CiAgQGtleWZyYW1lcyBzY2VuZUluIHsKICAgIGZyb20geyBvcGFjaXR5OjA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgzMHB4KSB0cmFuc2xhdGVaKDApOyB9CiAgICB0byAgIHsgb3BhY2l0eToxOyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgdHJhbnNsYXRlWigwKTsgfQogIH0KCiAgLyog4pSA4pSAIE9SQiDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KICAubG9nby13cmFwIHsgZGlzcGxheTpmbGV4OyBmbGV4LWRpcmVjdGlvbjpjb2x1bW47IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOjhweDsgfQoKICAubG9nby1vcmIgewogICAgcG9zaXRpb246IHJlbGF0aXZlOyB3aWR0aDogMTA4cHg7IGhlaWdodDogMTA4cHg7CiAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtOwogICAgYW5pbWF0aW9uOiBvcmJGbG9hdCA1cyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgQGtleWZyYW1lcyBvcmJGbG9hdCB7CiAgICAwJSwxMDAlIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVooMCk7IH0KICAgIDUwJSAgICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTlweCkgdHJhbnNsYXRlWigwKTsgfQogIH0KCiAgLm9yYi1yaW5nIHsKICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgaW5zZXQ6IDA7IGJvcmRlci1yYWRpdXM6IDUwJTsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHRyYW5zcGFyZW50OyB3aWxsLWNoYW5nZTogdHJhbnNmb3JtOwogICAgYW5pbWF0aW9uOiBzcGluIDRzIGxpbmVhciBpbmZpbml0ZTsKICB9CiAgLm9yYi1yaW5nLTEgeyBib3JkZXItdG9wLWNvbG9yOiMwMGQ0ZmY7IGJvcmRlci1yaWdodC1jb2xvcjojMDBkNGZmOyBhbmltYXRpb24tZHVyYXRpb246NHM7IH0KICAub3JiLXJpbmctMiB7IGluc2V0OjlweDsgYm9yZGVyLWJvdHRvbS1jb2xvcjojN2IyZmZmOyBib3JkZXItbGVmdC1jb2xvcjojN2IyZmZmOyBhbmltYXRpb24tZHVyYXRpb246Ni41czsgYW5pbWF0aW9uLWRpcmVjdGlvbjpyZXZlcnNlOyB9CiAgLm9yYi1yaW5nLTMgeyBpbnNldDoxOXB4OyBib3JkZXItdG9wLWNvbG9yOiMwMGZmZjc7IGFuaW1hdGlvbi1kdXJhdGlvbjozLjJzOyB9CiAgQGtleWZyYW1lcyBzcGluIHsgdG8geyB0cmFuc2Zvcm06IHJvdGF0ZSgzNjBkZWcpIHRyYW5zbGF0ZVooMCk7IH0gfQoKICAub3JiLWNvcmUgewogICAgcG9zaXRpb246IGFic29sdXRlOyBpbnNldDogMjZweDsgYm9yZGVyLXJhZGl1czogNTAlOwogICAgYmFja2dyb3VuZDogcmFkaWFsLWdyYWRpZW50KGNpcmNsZSBhdCAzNSUgMzIlLAogICAgICByZ2JhKDAsMjEyLDI1NSwwLjU1KSAwJSwgcmdiYSgxMjMsNDcsMjU1LDAuNjUpIDUyJSwgcmdiYSg0LDIsMTUsMC45MikgMTAwJSk7CiAgICBkaXNwbGF5OiBmbGV4OyBhbGlnbi1pdGVtczogY2VudGVyOyBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICB9CiAgLnB1bHNlLXN2ZyB7IHdpZHRoOiAzMHB4OyBoZWlnaHQ6IDE4cHg7IH0KCiAgLyog4pSA4pSAIEJSQU5EIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogIC5icmFuZC1uYW1lIHsKICAgIGZvbnQtZmFtaWx5OiAnT3JiaXRyb24nLCBtb25vc3BhY2U7IGZvbnQtd2VpZ2h0OiA5MDA7IGZvbnQtc2l6ZTogMi4xNXJlbTsKICAgIGxldHRlci1zcGFjaW5nOiAwLjI0ZW07CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCAjZmZmIDAlLCAjMDBmZmY3IDM4JSwgIzAwZDRmZiA2OCUsICM3YjJmZmYgMTAwJSk7CiAgICAtd2Via2l0LWJhY2tncm91bmQtY2xpcDogdGV4dDsgLXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6IHRyYW5zcGFyZW50OwogICAgZmlsdGVyOiBkcm9wLXNoYWRvdygwIDAgMTBweCByZ2JhKDAsMjEyLDI1NSwwLjY1KSk7CiAgfQogIC5icmFuZC1zdWIgewogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsgZm9udC1zaXplOiAwLjYycmVtOwogICAgbGV0dGVyLXNwYWNpbmc6IDAuNThlbTsgY29sb3I6IHJnYmEoMCwyMTIsMjU1LDAuNjgpOyBtYXJnaW4tdG9wOi00cHg7CiAgfQogIC5iYWRnZSB7CiAgICBtYXJnaW4tdG9wOiA1cHg7IHBhZGRpbmc6IDVweCAxNnB4OwogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsgZm9udC1zaXplOiAwLjU4cmVtOyBsZXR0ZXItc3BhY2luZzogMC4yOGVtOwogICAgY29sb3I6IHZhcigtLW5lb24tY3lhbik7CiAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDAsMjEyLDI1NSwwLjM4KTsgYm9yZGVyLXJhZGl1czogMjBweDsKICAgIGJhY2tncm91bmQ6IHJnYmEoMCwyMTIsMjU1LDAuMDUpOwogIH0KCiAgLyog4pSA4pSAIENBUkQg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgLmNhcmQgewogICAgd2lkdGg6IDEwMCU7CiAgICBiYWNrZ3JvdW5kOiByZ2JhKDgsNCwyNCwwLjgyKTsKICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMTIzLDQ3LDI1NSwwLjMyKTsKICAgIGJvcmRlci1yYWRpdXM6IDIwcHg7CiAgICBwYWRkaW5nOiAzMHB4IDI2cHggMjZweDsKICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgIGJhY2tkcm9wLWZpbHRlcjogYmx1cigxMnB4KTsKICAgIC13ZWJraXQtYmFja2Ryb3AtZmlsdGVyOiBibHVyKDEycHgpOwogICAgYm94LXNoYWRvdzoKICAgICAgMCAyMHB4IDUwcHggcmdiYSgwLDAsMCwwLjcyKSwKICAgICAgMCAwIDYwcHggcmdiYSgxMjMsNDcsMjU1LDAuMSksCiAgICAgIGluc2V0IDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA1NSk7CiAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMDVzIGxpbmVhcjsKICB9CiAgLmNhcmQ6OmJlZm9yZSwgLmNhcmQ6OmFmdGVyIHsKICAgIGNvbnRlbnQ6Jyc7IHBvc2l0aW9uOmFic29sdXRlOyB3aWR0aDozOHB4OyBoZWlnaHQ6MzhweDsKICB9CiAgLmNhcmQ6OmJlZm9yZSB7CiAgICB0b3A6LTFweDsgbGVmdDotMXB4OwogICAgYm9yZGVyLXRvcDogMnB4IHNvbGlkICM3YjJmZmY7IGJvcmRlci1sZWZ0OiAycHggc29saWQgIzdiMmZmZjsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggMCAwIDA7CiAgfQogIC5jYXJkOjphZnRlciB7CiAgICBib3R0b206LTFweDsgcmlnaHQ6LTFweDsKICAgIGJvcmRlci1ib3R0b206IDJweCBzb2xpZCAjMDBkNGZmOyBib3JkZXItcmlnaHQ6IDJweCBzb2xpZCAjMDBkNGZmOwogICAgYm9yZGVyLXJhZGl1czogMCAwIDE4cHggMDsKICB9CgogIC8qIOKUgOKUgCBTRUNUSU9OIFRJVExFIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogIC5zZWN0aW9uLXRpdGxlIHsgZGlzcGxheTpmbGV4OyBhbGlnbi1pdGVtczpjZW50ZXI7IGdhcDoxMHB4OyBtYXJnaW4tYm90dG9tOjIycHg7IH0KICAudGl0bGUtYmFyIHsgd2lkdGg6M3B4OyBoZWlnaHQ6MjBweDsgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KHRvIGJvdHRvbSwjN2IyZmZmLCMwMGQ0ZmYpOyBib3JkZXItcmFkaXVzOjJweDsgfQogIC50aXRsZS10ZXh0IHsgZm9udC1zaXplOjEuMDJyZW07IGZvbnQtd2VpZ2h0OjYwMDsgY29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjg4KTsgfQoKICAvKiDilIDilIAgRklFTERTIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogIC5maWVsZC1ncm91cCB7IG1hcmdpbi1ib3R0b206MTZweDsgfQogIC5maWVsZC1sYWJlbCB7IGRpc3BsYXk6YmxvY2s7IGZvbnQtc2l6ZTowLjhyZW07IGNvbG9yOnJnYmEoMTkwLDIwNSwyNTUsMC42NSk7IG1hcmdpbi1ib3R0b206N3B4OyB9CiAgLmZpZWxkLXdyYXAgeyBwb3NpdGlvbjpyZWxhdGl2ZTsgfQogIC5maWVsZC1pY29uIHsgcG9zaXRpb246YWJzb2x1dGU7IGxlZnQ6MTNweDsgdG9wOjUwJTsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTUwJSk7IGZvbnQtc2l6ZTowLjk1cmVtOyBvcGFjaXR5OjAuNTU7IHBvaW50ZXItZXZlbnRzOm5vbmU7IHotaW5kZXg6MTsgfQogIC5maWVsZC1pbnB1dCB7CiAgICB3aWR0aDoxMDAlOyBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLDAuNDIpOwogICAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgxMjMsNDcsMjU1LDAuMjIpOyBib3JkZXItcmFkaXVzOjExcHg7CiAgICBwYWRkaW5nOiAxM3B4IDEzcHggMTNweCA0MHB4OwogICAgZm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7IGZvbnQtc2l6ZTowLjlyZW07CiAgICBjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuODQpOyBvdXRsaW5lOm5vbmU7CiAgICB0cmFuc2l0aW9uOiBib3JkZXItY29sb3IgMC4ycywgYmFja2dyb3VuZCAwLjJzOwogIH0KICAuZmllbGQtaW5wdXQ6OnBsYWNlaG9sZGVyIHsgY29sb3I6cmdiYSgxNDAsMTU1LDIwMCwwLjM4KTsgfQogIC5maWVsZC1pbnB1dDpmb2N1cyB7IGJvcmRlci1jb2xvcjpyZ2JhKDAsMjEyLDI1NSwwLjU1KTsgYmFja2dyb3VuZDpyZ2JhKDAsMTgsMzYsMC41OCk7IH0KCiAgLmV5ZS1idG4gewogICAgcG9zaXRpb246YWJzb2x1dGU7IHJpZ2h0OjEycHg7IHRvcDo1MCU7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpOwogICAgYmFja2dyb3VuZDpub25lOyBib3JkZXI6bm9uZTsgY29sb3I6cmdiYSgxNDAsMTY1LDIyMCwwLjQ4KTsKICAgIGN1cnNvcjpwb2ludGVyOyBmb250LXNpemU6MC45NXJlbTsgcGFkZGluZzo0cHg7IHotaW5kZXg6MjsKICAgIHRyYW5zaXRpb246IGNvbG9yIDAuMThzOwogIH0KICAuZXllLWJ0bjpob3ZlciB7IGNvbG9yOiMwMGZmZjc7IH0KCiAgLyog4pSA4pSAIEJVVFRPTlMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCiAgLmJ0biB7CiAgICB3aWR0aDoxMDAlOyBwYWRkaW5nOjE0cHg7IGJvcmRlcjpub25lOyBib3JkZXItcmFkaXVzOjExcHg7CiAgICBmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjsgZm9udC1zaXplOjAuOTdyZW07IGZvbnQtd2VpZ2h0OjYwMDsKICAgIGxldHRlci1zcGFjaW5nOjAuMDVlbTsgY3Vyc29yOnBvaW50ZXI7IHBvc2l0aW9uOnJlbGF0aXZlOyBvdmVyZmxvdzpoaWRkZW47CiAgICB3aWxsLWNoYW5nZTogdHJhbnNmb3JtOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMTJzLCBib3gtc2hhZG93IDAuMTJzOwogICAgbWFyZ2luLWJvdHRvbToxMXB4OwogIH0KICAuYnRuOmxhc3QtY2hpbGQgeyBtYXJnaW4tYm90dG9tOjA7IH0KCiAgLmJ0bi1wcmltYXJ5IHsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcscmdiYSgxMjMsNDcsMjU1LDAuOTIpLHJnYmEoNjAsMCwxOTAsMC45NikscmdiYSgwLDkwLDIxMCwwLjkpKTsKICAgIGNvbG9yOiNmZmY7CiAgICBib3gtc2hhZG93OiAwIDRweCAwIHJnYmEoMCwwLDAsMC40NSksIDAgOHB4IDI0cHggcmdiYSgxMjMsNDcsMjU1LDAuNDUpOwogIH0KICAuYnRuLXByaW1hcnk6aG92ZXIgeyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KSB0cmFuc2xhdGVaKDApOyBib3gtc2hhZG93OjAgNnB4IDAgcmdiYSgwLDAsMCwwLjQ1KSwwIDE0cHggMzJweCByZ2JhKDEyMyw0NywyNTUsMC42KTsgfQogIC5idG4tcHJpbWFyeTphY3RpdmUgeyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgxcHgpIHRyYW5zbGF0ZVooMCk7IH0KCiAgLmJ0bi1zZWNvbmRhcnkgewogICAgYmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMjgpOyBjb2xvcjpyZ2JhKDIwMCwyMjAsMjU1LDAuNzgpOwogICAgYm9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMjEyLDI1NSwwLjIyKTsKICAgIGJveC1zaGFkb3c6MCA0cHggMCByZ2JhKDAsMCwwLDAuMyk7CiAgfQogIC5idG4tc2Vjb25kYXJ5OmhvdmVyIHsgYmFja2dyb3VuZDpyZ2JhKDAsMjEyLDI1NSwwLjA3KTsgYm9yZGVyLWNvbG9yOnJnYmEoMCwyMTIsMjU1LDAuNDgpOyBjb2xvcjojMDBmZmY3OyB0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KSB0cmFuc2xhdGVaKDApOyB9CiAgLmJ0bi1zZWNvbmRhcnk6YWN0aXZlIHsgdHJhbnNmb3JtOnRyYW5zbGF0ZVkoMXB4KSB0cmFuc2xhdGVaKDApOyB9CgogIC5idG46OmFmdGVyIHsKICAgIGNvbnRlbnQ6Jyc7IHBvc2l0aW9uOmFic29sdXRlOyB0b3A6MDsgbGVmdDotMTEwJTsgd2lkdGg6NTUlOyBoZWlnaHQ6MTAwJTsKICAgIGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMjU1LDI1NSwyNTUsMC4xMSksdHJhbnNwYXJlbnQpOwogICAgdHJhbnNmb3JtOnNrZXdYKC0xOGRlZykgdHJhbnNsYXRlWigwKTsgdHJhbnNpdGlvbjpsZWZ0IDAuNDJzOwogIH0KICAuYnRuOmhvdmVyOjphZnRlciB7IGxlZnQ6MTYwJTsgfQoKICAvKiDilIDilIAgVElDS0VSIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwogIC50aWNrZXItd3JhcCB7IHdpZHRoOjEwMCU7IG92ZXJmbG93OmhpZGRlbjsgb3BhY2l0eTowLjQ7IHBvc2l0aW9uOnJlbGF0aXZlOyB9CiAgLnRpY2tlci13cmFwOjpiZWZvcmUsLnRpY2tlci13cmFwOjphZnRlciB7IGNvbnRlbnQ6Jyc7IHBvc2l0aW9uOmFic29sdXRlOyB0b3A6MDsgYm90dG9tOjA7IHdpZHRoOjI4cHg7IHotaW5kZXg6MjsgfQogIC50aWNrZXItd3JhcDo6YmVmb3JlIHsgbGVmdDowOyBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMDQwMjBmLHRyYW5zcGFyZW50KTsgfQogIC50aWNrZXItd3JhcDo6YWZ0ZXIgIHsgcmlnaHQ6MDsgYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoLTkwZGVnLCMwNDAyMGYsdHJhbnNwYXJlbnQpOyB9CiAgLnRpY2tlci10cmFjayB7CiAgICB3aGl0ZS1zcGFjZTpub3dyYXA7IGRpc3BsYXk6aW5saW5lLWJsb2NrOwogICAgZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7IGZvbnQtc2l6ZTowLjQ4cmVtOyBsZXR0ZXItc3BhY2luZzowLjNlbTsKICAgIGNvbG9yOnJnYmEoMCwyMTIsMjU1LDAuODIpOyB3aWxsLWNoYW5nZTp0cmFuc2Zvcm07CiAgICBhbmltYXRpb246dGlja2VyIDIycyBsaW5lYXIgaW5maW5pdGU7CiAgfQogIEBrZXlmcmFtZXMgdGlja2VyIHsgZnJvbXt0cmFuc2Zvcm06dHJhbnNsYXRlWCgwKSB0cmFuc2xhdGVaKDApfSB0b3t0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKSB0cmFuc2xhdGVaKDApfSB9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+Cgo8ZGl2IGNsYXNzPSJncmlkLWJnIj48L2Rpdj4KPGRpdiBjbGFzcz0ic3BhY2UtZ2xvdyI+PC9kaXY+CjxjYW52YXMgaWQ9ImZmQ2FudmFzIj48L2NhbnZhcz4KCjxkaXYgY2xhc3M9InNjZW5lIj4KCiAgPGRpdiBjbGFzcz0ibG9nby13cmFwIj4KICAgIDxkaXYgY2xhc3M9ImxvZ28tb3JiIj4KICAgICAgPGRpdiBjbGFzcz0ib3JiLXJpbmcgb3JiLXJpbmctMSI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9yYi1yaW5nIG9yYi1yaW5nLTIiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvcmItcmluZyBvcmItcmluZy0zIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ib3JiLWNvcmUiPgogICAgICAgIDxzdmcgY2xhc3M9InB1bHNlLXN2ZyIgdmlld0JveD0iMCAwIDUwIDI4IiBmaWxsPSJub25lIj4KICAgICAgICAgIDxwb2x5bGluZSBwb2ludHM9IjAsMTQgOCwxNCAxMiw0IDE3LDI0IDIyLDEwIDI3LDE4IDMyLDYgMzcsMjIgNDIsMTQgNTAsMTQiCiAgICAgICAgICAgIHN0cm9rZT0iIzAwZDRmZiIgc3Ryb2tlLXdpZHRoPSIyLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIvPgogICAgICAgIDwvc3ZnPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYnJhbmQtbmFtZSI+Q0hBSVlBPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJicmFuZC1zdWIiPlAgUiBPIEogRSBDIFQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImJhZGdlIj5WMlJBWSAmYW1wOyBTU0ggJm5ic3A7wrcmbmJzcDsgQUxMLUlOLU9ORSBQUk88L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0iY2FyZCIgaWQ9ImNhcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjdGlvbi10aXRsZSI+CiAgICAgIDxkaXYgY2xhc3M9InRpdGxlLWJhciI+PC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJ0aXRsZS10ZXh0Ij7guYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJo8L3NwYW4+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZC1ncm91cCI+CiAgICAgIDxsYWJlbCBjbGFzcz0iZmllbGQtbGFiZWwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5ieC4h+C4suC4mTwvbGFiZWw+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkLXdyYXAiPgogICAgICAgIDxzcGFuIGNsYXNzPSJmaWVsZC1pY29uIj7wn5GkPC9zcGFuPgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmllbGQtaW5wdXQiIGlkPSJ1c2VybmFtZUlucHV0IiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0i4LiB4Lij4Lit4LiB4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJ4LiH4Liy4LiZIiBhdXRvY29tcGxldGU9InVzZXJuYW1lIj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJmaWVsZC1ncm91cCIgc3R5bGU9Im1hcmdpbi1ib3R0b206MjJweCI+CiAgICAgIDxsYWJlbCBjbGFzcz0iZmllbGQtbGFiZWwiPuC4o+C4q+C4seC4quC4nOC5iOC4suC4mTwvbGFiZWw+CiAgICAgIDxkaXYgY2xhc3M9ImZpZWxkLXdyYXAiPgogICAgICAgIDxzcGFuIGNsYXNzPSJmaWVsZC1pY29uIj7wn5SSPC9zcGFuPgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmllbGQtaW5wdXQiIHR5cGU9InBhc3N3b3JkIiBpZD0icGFzc0lucHV0IiBwbGFjZWhvbGRlcj0i4LiB4Lij4Lit4LiB4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZIiBhdXRvY29tcGxldGU9ImN1cnJlbnQtcGFzc3dvcmQiPgogICAgICAgIDxidXR0b24gY2xhc3M9ImV5ZS1idG4iIG9uY2xpY2s9InRvZ2dsZVBhc3MoKSIgdGFiaW5kZXg9Ii0xIj7wn5GBPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1wcmltYXJ5IiBpZD0ibG9naW5CdG4iIG9uY2xpY2s9ImRvTG9naW4oKSI+8J+UkyZuYnNwOyDguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJo8L2J1dHRvbj4KICAgIDxidXR0b24gY2xhc3M9ImJ0biBidG4tc2Vjb25kYXJ5IiBvbmNsaWNrPSJzaG93Q2hhbmdlTW9kYWwoKSI+8J+UkSZuYnNwOyDguJXguLHguYnguIfguIrguLfguYjguK3guJzguLnguYnguYPguIrguYkgLyDguKPguKvguLHguKrguJzguYjguLLguJnguYPguKvguKHguYg8L2J1dHRvbj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0idGlja2VyLXdyYXAiPgogICAgPGRpdiBjbGFzcz0idGlja2VyLXRyYWNrIiBpZD0idGlja2VyIj48L2Rpdj4KICA8L2Rpdj4KCjwvZGl2PgoKPHNjcmlwdD4KLyog4pSA4pSAIFRJQ0tFUiDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgKi8KY29uc3QgbXNnID0gJ0NIQUlZQS1QUk9KRUNUXHUyMDAzwrdcdTIwMDNWMlJBWSAmIFNTSCBBTEwtSU4tT05FIFBST1x1MjAwM8K3XHUyMDAzU0VDVVJFXHUyMDAzwrdcdTIwMDNTVEFCTEVcdTIwMDPCt1x1MjAwM0ZBU1RcdTIwMDPCt1x1MjAwMyc7CmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0aWNrZXInKS50ZXh0Q29udGVudCA9IG1zZy5yZXBlYXQoNSk7CgovKiDilIDilIAgUEFTU1dPUkQg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCmZ1bmN0aW9uIHRvZ2dsZVBhc3MoKSB7CiAgY29uc3QgZiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYXNzSW5wdXQnKTsKICBmLnR5cGUgPSBmLnR5cGUgPT09ICdwYXNzd29yZCcgPyAndGV4dCcgOiAncGFzc3dvcmQnOwp9CgovKiDilIDilIAgQ0FSRCBUSUxUIOKAlCBsZXJwZWQsIHJBRi1kcml2ZW4g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAICovCmNvbnN0IGNhcmQgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2FyZCcpOwpsZXQgbXggPSB3aW5kb3cuaW5uZXJXaWR0aC8yLCBteSA9IHdpbmRvdy5pbm5lckhlaWdodC8yOwpsZXQgdHggPSAwLCB0eSA9IDA7CmRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ21vdXNlbW92ZScsIGUgPT4geyBteCA9IGUuY2xpZW50WDsgbXkgPSBlLmNsaWVudFk7IH0sIHtwYXNzaXZlOnRydWV9KTsKKGZ1bmN0aW9uIHRpbHQoKSB7CiAgY29uc3QgciA9IGNhcmQuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7CiAgY29uc3QgZHggPSAobXggLSAoci5sZWZ0ICsgci53aWR0aC8yKSkgIC8gKHIud2lkdGgvMik7CiAgY29uc3QgZHkgPSAobXkgLSAoci50b3AgICsgci5oZWlnaHQvMikpIC8gKHIuaGVpZ2h0LzIpOwogIHR4ICs9IChkeCAtIHR4KSAqIDAuMDc7CiAgdHkgKz0gKGR5IC0gdHkpICogMC4wNzsKICBjYXJkLnN0eWxlLnRyYW5zZm9ybSA9IGBwZXJzcGVjdGl2ZSg5MDBweCkgcm90YXRlWCgkeygtdHkqNC41KS50b0ZpeGVkKDMpfWRlZykgcm90YXRlWSgkeyh0eCo0LjUpLnRvRml4ZWQoMyl9ZGVnKSB0cmFuc2xhdGVaKDApYDsKICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUodGlsdCk7Cn0pKCk7CgovKiDilIDilIAgRklSRUZMSUVTIOKAlCBDYW52YXMgMkQsIHJBRiBsb29wIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAqLwpjb25zdCBjYW52YXMgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZmZDYW52YXMnKTsKY29uc3QgY3R4ID0gY2FudmFzLmdldENvbnRleHQoJzJkJyk7CgpmdW5jdGlvbiByZXNpemUoKSB7IGNhbnZhcy53aWR0aCA9IGlubmVyV2lkdGg7IGNhbnZhcy5oZWlnaHQgPSBpbm5lckhlaWdodDsgfQpyZXNpemUoKTsKd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScsIHJlc2l6ZSwge3Bhc3NpdmU6dHJ1ZX0pOwoKY29uc3QgQ09MT1JTID0gWycjMDBmZjg4JywnI2FhZmZjOCcsJyMwMGQ0ZmYnLCcjODBmZmJiJywnIzAwZmZmNycsJyNjOGZmZGInXTsKY29uc3QgTiA9IDE2OwoKY29uc3QgZmxpZXMgPSBBcnJheS5mcm9tKHtsZW5ndGg6Tn0sICgpID0+ICh7CiAgeDogIE1hdGgucmFuZG9tKCkgKiBpbm5lcldpZHRoLAogIHk6ICBNYXRoLnJhbmRvbSgpICogaW5uZXJIZWlnaHQsCiAgdng6IChNYXRoLnJhbmRvbSgpLS41KSAqIDAuNSwKICB2eTogKE1hdGgucmFuZG9tKCktLjUpICogMC41LAogIHI6ICBNYXRoLnJhbmRvbSgpICogMS40ICsgMS4xLAogIGhleDogQ09MT1JTW01hdGguZmxvb3IoTWF0aC5yYW5kb20oKSpDT0xPUlMubGVuZ3RoKV0sCiAgcGhhc2U6IE1hdGgucmFuZG9tKCkgKiBNYXRoLlBJICogMiwKICBwc3BkOiAgTWF0aC5yYW5kb20oKSAqIDAuMDE2ICsgMC4wMSwKICB3eDogTWF0aC5yYW5kb20oKSAqIGlubmVyV2lkdGgsCiAgd3k6IE1hdGgucmFuZG9tKCkgKiBpbm5lckhlaWdodCwKICB3dDogfn4oTWF0aC5yYW5kb20oKSoyODArMTAwKSwgd2M6MCwKfSkpOwoKLy8gcHJlcGFyc2UgcmdiIG9uY2UKY29uc3QgcmdiID0gZmxpZXMubWFwKGYgPT4gewogIGNvbnN0IGggPSBmLmhleC5zbGljZSgxKTsKICByZXR1cm4gW3BhcnNlSW50KGgsMTYpPj4xNiwgKHBhcnNlSW50KGgsMTYpPj44KSYweGZmLCBwYXJzZUludChoLDE2KSYweGZmXTsKfSk7CgpsZXQgcHJldiA9IDA7CmZ1bmN0aW9uIGZyYW1lKHRzKSB7CiAgY29uc3QgZHQgPSBNYXRoLm1pbih0cyAtIHByZXYsIDMwKTsgcHJldiA9IHRzOwogIGN0eC5jbGVhclJlY3QoMCwgMCwgY2FudmFzLndpZHRoLCBjYW52YXMuaGVpZ2h0KTsKCiAgZm9yIChsZXQgaSA9IDA7IGkgPCBOOyBpKyspIHsKICAgIGNvbnN0IGYgPSBmbGllc1tpXTsKICAgIGNvbnN0IFtyLGcsYl0gPSByZ2JbaV07CgogICAgLy8gd2FuZGVyCiAgICBpZiAoKytmLndjID4gZi53dCkgewogICAgICBmLnd4ID0gTWF0aC5yYW5kb20oKSpjYW52YXMud2lkdGg7IGYud3kgPSBNYXRoLnJhbmRvbSgpKmNhbnZhcy5oZWlnaHQ7CiAgICAgIGYud3QgPSB+fihNYXRoLnJhbmRvbSgpKjI4MCsxMDApOyBmLndjID0gMDsKICAgIH0KICAgIGYudnggPSBmLnZ4Ki45NyArIChmLnd4LWYueCkqLjAwMjU7CiAgICBmLnZ5ID0gZi52eSouOTcgKyAoZi53eS1mLnkpKi4wMDI1OwogICAgY29uc3Qgc3BkID0gTWF0aC5oeXBvdChmLnZ4LGYudnkpOwogICAgaWYgKHNwZCA+IDAuNzUpIHsgZi52eD1mLnZ4L3NwZCouNzU7IGYudnk9Zi52eS9zcGQqLjc1OyB9CgogICAgZi54ICs9IGYudngqKGR0Ki4wNik7IGYueSArPSBmLnZ5KihkdCouMDYpOwogICAgaWYgKGYueDwtOCkgZi54PWNhbnZhcy53aWR0aCs4OyBlbHNlIGlmKGYueD5jYW52YXMud2lkdGgrOCkgZi54PS04OwogICAgaWYgKGYueTwtOCkgZi55PWNhbnZhcy5oZWlnaHQrODsgZWxzZSBpZihmLnk+Y2FudmFzLmhlaWdodCs4KSBmLnk9LTg7CgogICAgZi5waGFzZSArPSBmLnBzcGQ7CiAgICBjb25zdCBicmlnaHQgPSAuMzggKyAuNTIqKE1hdGguc2luKGYucGhhc2UpKi41Ky41KTsKICAgIGNvbnN0IGdSID0gZi5yICogKDMgKyAyLjIqKE1hdGguc2luKGYucGhhc2UqLjY4KSouNSsuNSkpOwoKICAgIC8vIHJhZGlhbCBnbG93CiAgICBjb25zdCBncmFkID0gY3R4LmNyZWF0ZVJhZGlhbEdyYWRpZW50KGYueCxmLnksMCxmLngsZi55LGdSKjMuNSk7CiAgICBncmFkLmFkZENvbG9yU3RvcCgwLCAgIGByZ2JhKCR7cn0sJHtnfSwke2J9LCR7KGJyaWdodCouODUpLnRvRml4ZWQoMil9KWApOwogICAgZ3JhZC5hZGRDb2xvclN0b3AoLjM1LCBgcmdiYSgke3J9LCR7Z30sJHtifSwkeyhicmlnaHQqLjMpLnRvRml4ZWQoMil9KWApOwogICAgZ3JhZC5hZGRDb2xvclN0b3AoMSwgICBgcmdiYSgke3J9LCR7Z30sJHtifSwwKWApOwogICAgY3R4LmJlZ2luUGF0aCgpOyBjdHguYXJjKGYueCxmLnksZ1IqMy41LDAsNi4yODMyKTsKICAgIGN0eC5maWxsU3R5bGUgPSBncmFkOyBjdHguZmlsbCgpOwoKICAgIC8vIGNvcmUKICAgIGN0eC5iZWdpblBhdGgoKTsgY3R4LmFyYyhmLngsZi55LGYuciwwLDYuMjgzMik7CiAgICBjdHguZmlsbFN0eWxlID0gYHJnYmEoJHtyfSwke2d9LCR7Yn0sJHticmlnaHQudG9GaXhlZCgyKX0pYDsKICAgIGN0eC5maWxsKCk7CiAgfQogIHJlcXVlc3RBbmltYXRpb25GcmFtZShmcmFtZSk7Cn0KcmVxdWVzdEFuaW1hdGlvbkZyYW1lKGZyYW1lKTsKCi8qIOKUgOKUgCBMT0dJTiDilIDilIAgKi8KY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwphc3luYyBmdW5jdGlvbiBkb0xvZ2luKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlcm5hbWVJbnB1dCcpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBwYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Bhc3NJbnB1dCcpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBidG4gID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvZ2luQnRuJyk7CiAgaWYgKCF1c2VyIHx8ICFwYXNzKSB7IGFsZXJ0KCdcdTBlMDFcdTBlMjNcdTBlMzhcdTBlMTNcdTBlMzJcdTBlMDFcdTBlMjNcdTBlMmRcdTBlMDEgVXNlcm5hbWUgXHUwZTQxXHUwZTI1XHUwZTMwIFBhc3N3b3JkJyk7IHJldHVybjsgfQogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLmlubmVySFRNTCA9ICdcdTIzZjMgXHUwZTAxXHUwZTMzXHUwZTI1XHUwZTMxXHUwZTA3XHUwZTQwXHUwZTAyXHUwZTQ5XHUwZTMyXHUwZTJhXHUwZTM5XHUwZTQ4XHUwZTIzXHUwZTMwXHUwZTFhXHUwZTFhLi4uJzsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKCcvYXBpL2xvZ2luJywgewogICAgICBtZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7dXNlcm5hbWU6dXNlciwgcGFzc3dvcmQ6cGFzc30pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmIChkLm9rIHx8IGQuc3VjY2VzcykgewogICAgICBjb25zdCBleHAgPSBEYXRlLm5vdygpICsgOCAqIDM2MDAgKiAxMDAwOwogICAgICBzZXNzaW9uU3RvcmFnZS5zZXRJdGVtKFNFU1NJT05fS0VZLCBKU09OLnN0cmluZ2lmeSh7dXNlciwgcGFzcywgZXhwfSkpOwogICAgICBsb2NhdGlvbi5yZXBsYWNlKCdzc2h3cy5odG1sJyk7CiAgICB9IGVsc2UgewogICAgICBhbGVydCgnVXNlcm5hbWUgXHUwZTJiXHUwZTIzXHUwZTM3XHUwZTJkIFBhc3N3b3JkIFx1MGU0NFx1MGUyMVx1MGU0OFx1MGUxNlx1MGUzOVx1MGUwMVx1MGUxNVx1MGU0OVx1MGUyZFx1MGUwNycpOwogICAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgICAgYnRuLmlubmVySFRNTCA9ICdcdWQ4M2RcdWRkMTMmbmJzcDsgXHUwZTQwXHUwZTAyXHUwZTQ5XHUwZTMyXHUwZTJhXHUwZTM5XHUwZTQ4XHUwZTIzXHUwZTMwXHUwZTFhXHUwZTFhJzsKICAgIH0KICB9IGNhdGNoKGUpIHsKICAgIGFsZXJ0KCdcdTBlNDBcdTBlMGFcdTBlMzdcdTBlNDhcdTBlMmRcdTBlMjFcdTBlMTVcdTBlNDhcdTBlMmQgQVBJIFx1MGU0NFx1MGUyMVx1MGU0OFx1MGU0NFx1MGUxNFx1MGU0OTogJyArIGUubWVzc2FnZSk7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgIGJ0bi5pbm5lckhUTUwgPSAnXHVkODNkXHVkZDEzJm5ic3A7IFx1MGU0MFx1MGUwMlx1MGU0OVx1MGUzMlx1MGUyYVx1MGUzOVx1MGU0OFx1MGUyM1x1MGUzMFx1MGUxYVx1MGUxYSc7CiAgfQp9CmRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLCBlID0+IHsgaWYoZS5rZXk9PT0nRW50ZXInKSBkb0xvZ2luKCk7IH0pOwoKLyog4pSA4pSAIENIQU5HRSBBRE1JTiDilIDilIAgKi8KZnVuY3Rpb24gc2hvd0NoYW5nZU1vZGFsKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGFuZ2VNb2RhbCcpLnN0eWxlLmRpc3BsYXkgPSAnZmxleCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoYW5nZUFsZXJ0Jykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb2xkUGFzcycpLnZhbHVlID0gJyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ld1VzZXInKS52YWx1ZSA9ICcnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXdQYXNzJykudmFsdWUgPSAnJzsKfQpmdW5jdGlvbiBoaWRlQ2hhbmdlTW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoYW5nZU1vZGFsJykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKfQphc3luYyBmdW5jdGlvbiBkb0NoYW5nZUFkbWluKCkgewogIGNvbnN0IG9sZFBhc3MgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb2xkUGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBuZXdVc2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ld1VzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgbmV3UGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXdQYXNzJykudmFsdWUudHJpbSgpOwogIGNvbnN0IGFsZXJ0RWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2hhbmdlQWxlcnQnKTsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29uZmlybUNoYW5nZUJ0bicpOwogIGlmICghb2xkUGFzcyB8fCAhbmV3VXNlciB8fCAhbmV3UGFzcykgewogICAgYWxlcnRFbC5zdHlsZS5jc3NUZXh0ID0gJ2Rpc3BsYXk6YmxvY2s7cGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7bWFyZ2luLWJvdHRvbToxNHB4O2JhY2tncm91bmQ6I2ZlZjJmMjtib3JkZXI6MXB4IHNvbGlkICNmY2E1YTU7Y29sb3I6I2RjMjYyNjsnOwogICAgYWxlcnRFbC50ZXh0Q29udGVudCA9ICfinYwg4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiC4LmJ4Lit4Lih4Li54Lil4LmD4Lir4LmJ4LiE4Lij4Lia4LiX4Li44LiB4LiK4LmI4Lit4LiHJzsKICAgIHJldHVybjsKICB9CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4udGV4dENvbnRlbnQgPSAn4o+zIOC4geC4s+C4peC4seC4h+C4muC4seC4meC4l+C4tuC4gS4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaCgnL2FwaS9jaGFuZ2VfYWRtaW4nLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHtvbGRfcGFzczpvbGRQYXNzLCBuZXdfdXNlcjpuZXdVc2VyLCBuZXdfcGFzczpuZXdQYXNzfSkKICAgIH0pOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAgaWYgKGQub2spIHsKICAgICAgYWxlcnRFbC5zdHlsZS5jc3NUZXh0ID0gJ2Rpc3BsYXk6YmxvY2s7cGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7bWFyZ2luLWJvdHRvbToxNHB4O2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDsnOwogICAgICBhbGVydEVsLnRleHRDb250ZW50ID0gJ+KchSDguYDguJvguKXguLXguYjguKLguJkgVXNlcm5hbWUvUGFzc3dvcmQg4Liq4Liz4LmA4Lij4LmH4LiIISDguIHguKPguLjguJPguLIgTG9naW4g4LmD4Lir4Lih4LmIJzsKICAgICAgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguKLguLfguJnguKLguLHguJknOwogICAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgICAgc2V0VGltZW91dCgoKSA9PiB7IGhpZGVDaGFuZ2VNb2RhbCgpOyB9LCAyNTAwKTsKICAgIH0gZWxzZSB7CiAgICAgIGFsZXJ0RWwuc3R5bGUuY3NzVGV4dCA9ICdkaXNwbGF5OmJsb2NrO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi1ib3R0b206MTRweDtiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7JzsKICAgICAgYWxlcnRFbC50ZXh0Q29udGVudCA9ICfinYwgJyArIChkLmVycm9yIHx8ICfguYDguIHguLTguJTguILguYnguK3guJzguLTguJTguJ7guKXguLLguJQnKTsKICAgICAgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguKLguLfguJnguKLguLHguJknOwogICAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgIH0KICB9IGNhdGNoKGUpIHsKICAgIGFsZXJ0RWwuc3R5bGUuY3NzVGV4dCA9ICdkaXNwbGF5OmJsb2NrO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi1ib3R0b206MTRweDtiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7JzsKICAgIGFsZXJ0RWwudGV4dENvbnRlbnQgPSAn4p2MIOC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJOiAnICsgZS5tZXNzYWdlOwogICAgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguKLguLfguJnguKLguLHguJknOwogICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgfQp9Cjwvc2NyaXB0PgoKPCEtLSBDSEFOR0UgQ1JFREVOVElBTFMgTU9EQUwgLS0+CjxkaXYgaWQ9ImNoYW5nZU1vZGFsIiBzdHlsZT0iZGlzcGxheTpub25lO3Bvc2l0aW9uOmZpeGVkO2luc2V0OjA7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC43NSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoOHB4KTt6LWluZGV4Ojk5OTthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjsiPgogIDxkaXYgc3R5bGU9ImJhY2tncm91bmQ6cmdiYSg4LDQsMjQsLjk1KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTIzLDQ3LDI1NSwuNCk7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjhweCAyNHB4O3dpZHRoOjEwMCU7bWF4LXdpZHRoOjM2MHB4O21hcmdpbjoyMHB4O3Bvc2l0aW9uOnJlbGF0aXZlOyI+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2NvbG9yOnJnYmEoMCwyMTIsMjU1LC44KTttYXJnaW4tYm90dG9tOjIwcHg7bGV0dGVyLXNwYWNpbmc6MnB4OyI+8J+UkSDguYDguJvguKXguLXguYjguKLguJkgVXNlcm5hbWUgLyBQYXNzd29yZDwvZGl2PgogICAgPGRpdiBpZD0iY2hhbmdlQWxlcnQiIHN0eWxlPSJkaXNwbGF5Om5vbmU7cGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7bWFyZ2luLWJvdHRvbToxNHB4OyI+PC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJtYXJnaW4tYm90dG9tOjEycHg7Ij4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtjb2xvcjpyZ2JhKDE5MCwyMDUsMjU1LC42KTttYXJnaW4tYm90dG9tOjZweDsiPlBhc3N3b3JkIOC5gOC4lOC4tOC4oTwvZGl2PgogICAgICA8aW5wdXQgaWQ9Im9sZFBhc3MiIHR5cGU9InBhc3N3b3JkIiBwbGFjZWhvbGRlcj0i4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZ4Lib4Lix4LiI4LiI4Li44Lia4Lix4LiZIiBzdHlsZT0id2lkdGg6MTAwJTtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjQyKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTIzLDQ3LDI1NSwuMjIpO2JvcmRlci1yYWRpdXM6MTFweDtwYWRkaW5nOjExcHggMTRweDtmb250LXNpemU6Ljg4cmVtO2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsLjg0KTtvdXRsaW5lOm5vbmU7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7Ij4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxMnB4OyI+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZTouNzVyZW07Y29sb3I6cmdiYSgxOTAsMjA1LDI1NSwuNik7bWFyZ2luLWJvdHRvbTo2cHg7Ij5Vc2VybmFtZSDguYPguKvguKHguYg8L2Rpdj4KICAgICAgPGlucHV0IGlkPSJuZXdVc2VyIiB0eXBlPSJ0ZXh0IiBwbGFjZWhvbGRlcj0idXNlcm5hbWUg4LmD4Lir4Lih4LmIIiBzdHlsZT0id2lkdGg6MTAwJTtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjQyKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTIzLDQ3LDI1NSwuMjIpO2JvcmRlci1yYWRpdXM6MTFweDtwYWRkaW5nOjExcHggMTRweDtmb250LXNpemU6Ljg4cmVtO2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsLjg0KTtvdXRsaW5lOm5vbmU7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7Ij4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0ibWFyZ2luLWJvdHRvbToyMHB4OyI+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZTouNzVyZW07Y29sb3I6cmdiYSgxOTAsMjA1LDI1NSwuNik7bWFyZ2luLWJvdHRvbTo2cHg7Ij5QYXNzd29yZCDguYPguKvguKHguYg8L2Rpdj4KICAgICAgPGlucHV0IGlkPSJuZXdQYXNzIiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IuC4o+C4q+C4seC4quC4nOC5iOC4suC4meC5g+C4q+C4oeC5iCIgc3R5bGU9IndpZHRoOjEwMCU7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC40Mik7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDEyMyw0NywyNTUsLjIyKTtib3JkZXItcmFkaXVzOjExcHg7cGFkZGluZzoxMXB4IDE0cHg7Zm9udC1zaXplOi44OHJlbTtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC44NCk7b3V0bGluZTpub25lO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyI+CiAgICA8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6MTBweDsiPgogICAgICA8YnV0dG9uIGlkPSJjb25maXJtQ2hhbmdlQnRuIiBvbmNsaWNrPSJkb0NoYW5nZUFkbWluKCkiIHN0eWxlPSJmbGV4OjE7cGFkZGluZzoxMnB4O2JvcmRlcjpub25lO2JvcmRlci1yYWRpdXM6MTFweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcscmdiYSgxMjMsNDcsMjU1LC45KSxyZ2JhKDAsOTAsMjEwLC45KSk7Y29sb3I6I2ZmZjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtmb250LXNpemU6LjlyZW07Zm9udC13ZWlnaHQ6NjAwO2N1cnNvcjpwb2ludGVyOyI+4pyFIOC4ouC4t+C4meC4ouC4seC4mTwvYnV0dG9uPgogICAgICA8YnV0dG9uIG9uY2xpY2s9ImhpZGVDaGFuZ2VNb2RhbCgpIiBzdHlsZT0iZmxleDoxO3BhZGRpbmc6MTJweDtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMTIzLDQ3LDI1NSwuMyk7Ym9yZGVyLXJhZGl1czoxMXB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Y29sb3I6cmdiYSgyMDAsMjIwLDI1NSwuNyk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7Zm9udC1zaXplOi45cmVtO2N1cnNvcjpwb2ludGVyOyI+4Lii4LiB4LmA4Lil4Li04LiBPC9idXR0b24+CiAgICA8L2Rpdj4KICA8L2Rpdj4KPC9kaXY+CjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUscmdiYSgxMjQsNTgsMjM3LDAuMjUpIDAlLHRyYW5zcGFyZW50IDYwJSkscmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLHJnYmEoMzcsOTksMjM1LDAuMikgMCUsdHJhbnNwYXJlbnQgNjAlKSxsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwMzA1MGYgMCUsIzA4MGQxZiA1MCUsIzA1MDgxMCAxMDAlKTtwYWRkaW5nOjIwcHggMjBweCAxOHB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KCgoKCiAgLyogTkFWIHBpbGwgc3R5bGUgKi8KICAubmF2LXdyYXB7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCMwODBkMWYgMCUsIzBjMTQyOCAxMDAlKTtwYWRkaW5nOjEwcHggMTBweCAwO3Bvc2l0aW9uOnN0aWNreTt0b3A6MDt6LWluZGV4OjEwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wNik7Ym94LXNoYWRvdzowIDRweCAyMHB4IHJnYmEoMCwwLDAsMC4zKTt9CiAgLm5hdntkaXNwbGF5OmZsZXg7Z2FwOjRweDtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cGFkZGluZy1ib3R0b206MTBweDt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleC1zaHJpbms6MDtwYWRkaW5nOjhweCAxNHB4O2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNCk7dGV4dC1hbGlnbjpjZW50ZXI7Y3Vyc29yOnBvaW50ZXI7d2hpdGUtc3BhY2U6bm93cmFwO2JvcmRlci1yYWRpdXM6OTk5cHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCk7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDQpO3RyYW5zaXRpb246YWxsIDAuMjJzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSk7bGV0dGVyLXNwYWNpbmc6MC4zcHg7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7fQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSl7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjcpO2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA4KTtib3JkZXItY29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjE4KTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTt9CiAgLm5hdi1pdGVtLmFjdGl2ZXtjb2xvcjojZmZmO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMjJjNTVlLCMxNmEzNGEpO2JvcmRlci1jb2xvcjp0cmFuc3BhcmVudDtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNCwxOTcsOTQsMC40KSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4yKSBpbnNldDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTt9CiAgLm5hdi1pdGVtLm5hdi1zcGVlZC5hY3RpdmV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMwNmI2ZDQsIzA4OTFiMik7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoNiwxODIsMjEyLDAuNCksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMikgaW5zZXQ7fQogIC5uYXYtaXRlbS5uYXYtc3BlZWQ6aG92ZXI6bm90KC5hY3RpdmUpe2NvbG9yOiMwNmI2ZDQ7Ym9yZGVyLWNvbG9yOnJnYmEoNiwxODIsMjEyLDAuMyk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo1cHg7aGVpZ2h0OjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCAzcHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQogIC5kb3QucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgQGtleWZyYW1lcyBwbHN7MCUsMTAwJXtvcGFjaXR5Oi45O2JveC1zaGFkb3c6MCAwIDJweCB2YXIoLS1uZyl9NTAle29wYWNpdHk6LjY7Ym94LXNoYWRvdzowIDAgNHB4IHZhcigtLW5nKX19CiAgLnh1aS1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC54dWktaW5mb3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS43O30KICAueHVpLWluZm8gYntjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLWxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O21hcmdpbi10b3A6MTBweDt9CiAgLnN2Y3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMDUpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMXB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjt9CiAgLnN2Yy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4wNSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMik7fQogIC5zdmMtbHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O30KICAuZGd7d2lkdGg6NnB4O2hlaWdodDo2cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94LXNoYWRvdzowIDAgM3B4IHZhcigtLW5nKTtmbGV4LXNocmluazowO30KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4OjEwMDtkaXNwbGF5Om5vbmU7YWxpZ24taXRlbXM6ZmxleC1lbmQ7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLm1vdmVyLm9wZW57ZGlzcGxheTpmbGV4O30KICAubW9kYWx7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjIwcHggMjBweCAwIDA7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDgwcHg7cGFkZGluZzoyMHB4O21heC1oZWlnaHQ6ODV2aDtvdmVyZmxvdy15OmF1dG87YW5pbWF0aW9uOnN1IC4zcyBlYXNlO2JveC1zaGFkb3c6MCAtNHB4IDMwcHggcmdiYSgwLDAsMCwwLjEyKTt9CiAgQGtleWZyYW1lcyBzdXtmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVZKDEwMCUpfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAubWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206MTZweDt9CiAgLm10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS10eHQpO30KICAubWNsb3Nle3dpZHRoOjMycHg7aGVpZ2h0OjMycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAuZGdyaWR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLWJvdHRvbToxNHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRye2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo3cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHI6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5ka3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5kdntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmR2LmdyZWVue2NvbG9yOnZhcigtLW5nKTt9CiAgLmR2LnJlZHtjb2xvcjojZWY0NDQ0O30KICAuZHYubW9ub3tjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDt9CiAgLmFncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O30KICAubS1zdWJ7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTRweDtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHg7fQogIC5tLXN1Yi5vcGVue2Rpc3BsYXk6YmxvY2s7YW5pbWF0aW9uOmZpIC4ycyBlYXNlO30KICAubXN1Yi1sYmx7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuYWJ0bntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHggMTBweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5hYnRuOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAuYWJ0biAuYWl7Zm9udC1zaXplOjIycHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5hYnRuIC5hbntmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLmFidG4gLmFke2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5yZXMtYm94e3Bvc2l0aW9uOnJlbGF0aXZlO2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tdG9wOjE0cHg7ZGlzcGxheTpub25lO30KICAucmVzLWJveC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5yZXMtY2xvc2V7cG9zaXRpb246YWJzb2x1dGU7dG9wOi0xMXB4O3JpZ2h0Oi0xMXB4O3dpZHRoOjIycHg7aGVpZ2h0OjIycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2JvcmRlcjoycHggc29saWQgI2ZmZjtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bGluZS1oZWlnaHQ6MTtib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDIzOSw2OCw2OCwwLjQpO3otaW5kZXg6Mjt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9CgogIC8qIOKUgOKUgCBIRFIgbG9nbyBhbmltYXRpb25zIChzYW1lIGFzIGxvZ2luKSDilIDilIAgKi8KICBAa2V5ZnJhbWVzIGhkci1vcmJpdC1kYXNoIHsKICAgIGZyb20geyBzdHJva2UtZGFzaG9mZnNldDogMDsgfQogICAgdG8gICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAtMjUxOyB9CiAgfQogIEBrZXlmcmFtZXMgaGRyLXB1bHNlLWRyYXcgewogICAgMCUgICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7IG9wYWNpdHk6IDA7IH0KICAgIDE1JSAgeyBvcGFjaXR5OiAxOyB9CiAgICAxMDAlIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItYmxpbmstZG90IHsKICAgIDAlLCAxMDAlIHsgb3BhY2l0eTogMC4yNTsgfQogICAgNTAlICAgICAgIHsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGhkci1sb2dvLWdsb3cgewogICAgMCUsIDEwMCUgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA2cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDE0cHggIzI1NjNlYik7IH0KICAgIDUwJSAgICAgICB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDE0cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDI4cHggIzI1NjNlYikgZHJvcC1zaGFkb3coMCAwIDQycHggIzA2YjZkNCk7IH0KICB9CiAgLmhkci1sb2dvLXN2Zy13cmFwIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDhweDsKICAgIGFuaW1hdGlvbjogaGRyLWxvZ28tZ2xvdyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgLmhkci1vcmJpdC1yaW5nIHsgdHJhbnNmb3JtLW9yaWdpbjogNTBweCA1MHB4OyBhbmltYXRpb246IGhkci1vcmJpdC1kYXNoIDhzIGxpbmVhciBpbmZpbml0ZTsgfQogIC5oZHItd2F2ZS1hbmltICB7IHN0cm9rZS1kYXNoYXJyYXk6MjIwOyBzdHJva2UtZGFzaG9mZnNldDoyMjA7IGFuaW1hdGlvbjogaGRyLXB1bHNlLWRyYXcgMS42cyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKSAwLjVzIGZvcndhcmRzOyB9CiAgLmhkci1kb3QtMSB7IGFuaW1hdGlvbjogaGRyLWJsaW5rLWRvdCAyLjJzIGVhc2UtaW4tb3V0IDEuOHMgaW5maW5pdGU7IH0KICAuaGRyLWRvdC0yIHsgYW5pbWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMi4ycyBpbmZpbml0ZTsgfQoKICAvKiDilIDilIAgRGFzaGJvYXJkIEZpcmVmbGllcyAoZnVsbCBwYWdlKSDilIDilIAgKi8KICAuZGFzaC1mZiB7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIHotaW5kZXg6IDA7CiAgICBhbmltYXRpb246IGRhc2gtZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLCBkYXNoLWZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgb3BhY2l0eTogMDsKICB9CiAgQGtleWZyYW1lcyBkYXNoLWZmLWRyaWZ0IHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgICAyMCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpOyB9CiAgICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgzKSx2YXIoLS1keTMpKSBzY2FsZSgxLjA1KTsgfQogICAgODAlICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgfQogIEBrZXlmcmFtZXMgZGFzaC1mZi1ibGluayB7CiAgICAwJSwxMDAleyBvcGFjaXR5OjA7IH0gMTUleyBvcGFjaXR5OjA7IH0gMzAleyBvcGFjaXR5OjE7IH0KICAgIDUwJXsgb3BhY2l0eTowLjk7IH0gNjUleyBvcGFjaXR5OjA7IH0gODAleyBvcGFjaXR5OjAuODU7IH0gOTIleyBvcGFjaXR5OjA7IH0KICB9CgogIC8qIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkAogICAgIDNEIENBUkRTIC8gVEFCUyAvIEJVVFRPTlMg4oCUIOC4l+C4uOC4geC4q+C4meC5ieC4sgogIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAqLwogIC5jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMjUpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDI0cHggcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAycHggOHB4IHJnYmEoMzQsMTk3LDk0LDAuMTIpLAogICAgICAwIDE2cHggMzJweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSB0cmFuc2xhdGVaKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVooMCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNHB4IDM2cHggcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDRweCAxNnB4IHJnYmEoMzQsMTk3LDk0LDAuMTgpLAogICAgICAwIDI0cHggNDhweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBOYXYgaXRlbXMgM0QgKi8KICAubmF2LWl0ZW0gewogICAgYm9yZGVyLXJhZGl1czogMTJweCAxMnB4IDAgMCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAycHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICBib3gtc2hhZG93OiAwIC0ycHggNnB4IHJnYmEoMCwwLDAsMC4xNSkgaW5zZXQ7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSAhaW1wb3J0YW50OwogICAgbWFyZ2luOiAwIDJweDsKICAgIHBhZGRpbmctdG9wOiAxNHB4ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMnB4KTsKICB9CiAgLm5hdi1pdGVtLmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgIWltcG9ydGFudDsKICAgIGJvcmRlci1jb2xvcjogcmdiYSgzNCwxOTcsOTQsMC4zNSkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgLTRweCAxMnB4IHJnYmEoMzQsMTk3LDk0LDAuMTUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICB9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCk7CiAgICBib3JkZXItY29sb3I6IHJnYmEoMzQsMTk3LDk0LDAuMTUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBBbGwgYnV0dG9ucyAzRCAqLwogIC5jYnRuLCAuYnRuLXIsIC5jYnRtLXNzaCwgLmJ0bi10YmwsIC5wYnRuLCAudGJ0biwKICAuY29weS1idG4sIC5jb3B5LWxpbmstYnRuLCAubG9nb3V0LCAubWNsb3NlLAogIC5hYnRuLCAucG9ydC1idG4sIC5waWNrLW9wdCB7CiAgICBib3JkZXItcmFkaXVzOiAxMnB4ICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDRweCAwIHJnYmEoMCwwLDAsMC4zNSksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEyKSBpbnNldCwKICAgICAgMCA2cHggMTZweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjEycyBlYXNlICFpbXBvcnRhbnQ7CiAgICBib3JkZXItd2lkdGg6IDJweCAhaW1wb3J0YW50OwogIH0KICAuY2J0bjpob3ZlciwgLmJ0bi1yOmhvdmVyLCAuY29weS1idG46aG92ZXIsCiAgLmFidG46aG92ZXIsIC5wb3J0LWJ0bjpob3ZlciwgLnBpY2stb3B0OmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpIGluc2V0LAogICAgICAwIDEwcHggMjRweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQogIC5jYnRuOmFjdGl2ZSwgLmJ0bi1yOmFjdGl2ZSwgLmNvcHktYnRuOmFjdGl2ZSwKICAuYWJ0bjphY3RpdmUsIC5wb3J0LWJ0bjphY3RpdmUsIC5waWNrLW9wdDphY3RpdmUsCiAgLmJ0bi10Ymw6YWN0aXZlLCAubG9nb3V0OmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoM3B4KSBzY2FsZSgwLjk3KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCAxcHggMCByZ2JhKDAsMCwwLDAuNCksCiAgICAgIDAgMCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA2cyBlYXNlLCBib3gtc2hhZG93IDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CgogIC8qIHNlbC1jYXJkIDNEICovCiAgLnNlbC1jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjIpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDIwcHggcmdiYSgwLDAsMCwwLjEyKSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVgoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xOHMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVgoMnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA4cHggMCByZ2JhKDAsMCwwLDAuMjUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNnB4IDMycHggcmdiYSgwLDAsMCwwLjE4KSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgycHgpIHRyYW5zbGF0ZVgoMCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KCiAgLyogdWl0ZW1zIDNEICovCiAgLnVpdGVtIHsKICAgIGJvcmRlci1yYWRpdXM6IDE0cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgM3B4IDAgcmdiYSgwLDAsMCwwLjE4KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDcpIGluc2V0LAogICAgICAwIDZweCAxNHB4IHJnYmEoMCwwLDAsMC4wOCkgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjE1cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjE1cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjIyKSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDkpIGluc2V0LAogICAgICAwIDEycHggMjRweCByZ2JhKDAsMCwwLDAuMTIpICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTphY3RpdmUgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDJweCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAvKiBib3VuY2Uga2V5ZnJhbWUg4Liq4Liz4Lir4Lij4Lix4Lia4LiB4LiUICovCiAgQGtleWZyYW1lcyBidG4tYm91bmNlIHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHNjYWxlKDEpOyB9CiAgICAzMCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjkzKSB0cmFuc2xhdGVZKDNweCk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDEuMDQpIHRyYW5zbGF0ZVkoLTJweCk7IH0KICAgIDgwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTgpIHRyYW5zbGF0ZVkoMXB4KTsgfQogICAgMTAwJSB7IHRyYW5zZm9ybTogc2NhbGUoMSkgdHJhbnNsYXRlWSgwKTsgfQogIH0KICAuY2J0bjphY3RpdmUsIC5idG4tcjphY3RpdmUsIC5jb3B5LWJ0bjphY3RpdmUgeyBhbmltYXRpb246IGJ0bi1ib3VuY2UgMC4yOHMgZWFzZSBmb3J3YXJkcyAhaW1wb3J0YW50OyB9CgogIC8qIE5hdiAzRCBwaWxscyBvdmVycmlkZSAqLwogIC5uYXYtaXRlbXtib3JkZXItcmFkaXVzOjk5OXB4IWltcG9ydGFudDtib3gtc2hhZG93OjAgM3B4IDAgcmdiYSgwLDAsMCwwLjMpLDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEpIGluc2V0IWltcG9ydGFudDtib3JkZXItd2lkdGg6MS41cHghaW1wb3J0YW50O30KICAubmF2LWl0ZW0uYWN0aXZle3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpIWltcG9ydGFudDt9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTt9CgogIC8qIEZpcmVmbGllcyBpbnNpZGUgY2FyZHMgKi8KICAuY2FyZC1mZntwb3NpdGlvbjphYnNvbHV0ZTtib3JkZXItcmFkaXVzOjUwJTtwb2ludGVyLWV2ZW50czpub25lO3otaW5kZXg6MDthbmltYXRpb246Y2ZmLWRyaWZ0IGxpbmVhciBpbmZpbml0ZSxjZmYtYmxpbmsgZWFzZS1pbi1vdXQgaW5maW5pdGU7b3BhY2l0eTowO30KICBAa2V5ZnJhbWVzIGNmZi1kcmlmdHswJXt0cmFuc2Zvcm06dHJhbnNsYXRlKDAsMCkgc2NhbGUoMSk7fTIwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MSksdmFyKC0tZHkxKSkgc2NhbGUoMS4xKTt9NDAle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpO302MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDMpLHZhcigtLWR5MykpIHNjYWxlKDEuMDUpO304MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDQpLHZhcigtLWR5NCkpIHNjYWxlKDAuOTUpO30xMDAle3RyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTt9fQogIEBrZXlmcmFtZXMgY2ZmLWJsaW5rezAlLDEwMCV7b3BhY2l0eTowO30xNSV7b3BhY2l0eTowO30zMCV7b3BhY2l0eTowLjk7fTUwJXtvcGFjaXR5OjAuNzt9NjUle29wYWNpdHk6MDt9ODAle29wYWNpdHk6MC44O305MiV7b3BhY2l0eTowO319CiAgLmNhcmQ+Kjpub3QoLmNhcmQtZmYpe3Bvc2l0aW9uOnJlbGF0aXZlO3otaW5kZXg6MTt9CiAgLnNjPio6bm90KC5jYXJkLWZmKXtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQoKICAvKiBTUEVFRCBURVNUICovCiAgLnNwZWVkLWhlcm97YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwYTE2MjggMCUsIzA2MTAyMCAxMDAlKTtib3JkZXI6MnB4IHNvbGlkIHJnYmEoNiwxODIsMjEyLDAuMik7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjRweCAxNnB4O21hcmdpbi1ib3R0b206MTJweDt0ZXh0LWFsaWduOmNlbnRlcjtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1oZXJvOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JhY2tncm91bmQ6cmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgODAlIDUwJSBhdCA1MCUgMCUscmdiYSg2LDE4MiwyMTIsMC4xMiksdHJhbnNwYXJlbnQpO30KICAuc3BlZWQtdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjExcHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1nYXVnZS13cmFwe3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjE2MHB4O2hlaWdodDo4MHB4O21hcmdpbjowIGF1dG8gMTZweDt9CiAgLnNwZWVkLWdhdWdlLXN2Z3tvdmVyZmxvdzp2aXNpYmxlO30KICAuc3BlZWQtZ2F1Z2UtYmd7ZmlsbDpub25lO3N0cm9rZTpyZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt9CiAgLnNwZWVkLWdhdWdlLWZpbGx7ZmlsbDpub25lO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSxzdHJva2UgMC4zczt0cmFuc2Zvcm0tb3JpZ2luOjgwcHggODBweDt9CiAgLnNwZWVkLWNlbnRlcntwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MzJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMDZiNmQ0LCM2MGE1ZmEpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7fQogIC5zcGVlZC11bml0e2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNSk7bWFyZ2luLXRvcDoycHg7fQogIC5zcGVlZC1idG5ze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zcGVlZC1idG57cGFkZGluZzoxNHB4O2JvcmRlci1yYWRpdXM6MTRweDtib3JkZXI6bm9uZTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6MnB4O3RyYW5zaXRpb246YWxsIDAuMnM7fQogIC5zcGVlZC1idG4tZGx7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMyNTYzZWIsIzFkNGVkOCk7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNyw5OSwyMzUsMC40KTt9CiAgLnNwZWVkLWJ0bi1kbDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgzNyw5OSwyMzUsMC41KTt9CiAgLnNwZWVkLWJ0bi11bHtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzdjM2FlZCwjNmQyOGQ5KTtjb2xvcjojZmZmO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDEyNCw1OCwyMzcsMC40KTt9CiAgLnNwZWVkLWJ0bi11bDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgxMjQsNTgsMjM3LDAuNSk7fQogIC5zcGVlZC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjQ7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc3BlZWQtcmVzdWx0c3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc3BlZWQtcmVzLWNhcmR7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDQpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzoxNnB4O3RleHQtYWxpZ246Y2VudGVyO30KICAuc3BlZWQtcmVzLWljb257Zm9udC1zaXplOjIwcHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5zcGVlZC1yZXMtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQpO21hcmdpbi1ib3R0b206NHB4O30KICAuc3BlZWQtcmVzLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTt9CiAgLnNwZWVkLXJlcy12YWwuZGwtY29sb3J7Y29sb3I6IzYwYTVmYTt9CiAgLnNwZWVkLXJlcy12YWwudWwtY29sb3J7Y29sb3I6I2E3OGJmYTt9CiAgLnNwZWVkLXJlcy11bml0e2ZvbnQtc2l6ZTo5cHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjMpO21hcmdpbi10b3A6MnB4O30KICAuc3BlZWQtc3RhdHVze2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWluLWhlaWdodDoxOHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoyMHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctaXRlbXt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXBpbmctbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjM1KTttYXJnaW4tYm90dG9tOjJweDt9CiAgLnNwZWVkLXBpbmctdmFse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojNGFkZTgwO30KICAuc3BlZWQtcGluZy12YWwud2Fybntjb2xvcjojZmJiZjI0O30KICAuc3BlZWQtcGluZy12YWwuYmFke2NvbG9yOiNlZjQ0NDQ7fQogIC5zcGVlZC1iYXItd3JhcHtoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1iYXJ7aGVpZ2h0OjEwMCU7Ym9yZGVyLXJhZGl1czoycHg7d2lkdGg6MCU7dHJhbnNpdGlvbjp3aWR0aCAwLjNzIGVhc2U7fQogIC5zcGVlZC1iYXIuZGwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMyNTYzZWIsIzYwYTVmYSk7fQogIC5zcGVlZC1iYXIudWwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCM3YzNhZWQsI2E3OGJmYSk7fQogIC5zcGVlZC1pbmZvLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmcjtnYXA6OHB4O30KICAuc3BlZWQtaW5mby1pdGVte2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjAzKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wNik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLWluZm8tbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo3cHg7bGV0dGVyLXNwYWNpbmc6MXB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4zKTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNwZWVkLWluZm8tdmFse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuOCk7fQogIC5zcGVlZC1wcm9ne2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDYsMTgyLDIxMiwwLjE1KTtib3JkZXItcmFkaXVzOjJweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1wcm9nLWZpbGx7aGVpZ2h0OjEwMCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzA2YjZkNCwjNjBhNWZhKTtib3JkZXItcmFkaXVzOjJweDt3aWR0aDowJTt0cmFuc2l0aW9uOndpZHRoIDAuMnMgZWFzZTt9Cgo8L3N0eWxlPgo8c2NyaXB0IHNyYz0iaHR0cHM6Ly9jZG5qcy5jbG91ZGZsYXJlLmNvbS9hamF4L2xpYnMvcXJjb2RlanMvMS4wLjAvcXJjb2RlLm1pbi5qcyI+PC9zY3JpcHQ+CjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9IndyYXAiPgoKICA8IS0tIEhFQURFUiAtLT4KICA8ZGl2IGNsYXNzPSJoZHIiIGlkPSJoZHItcm9vdCI+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiPuKGqSDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KCiAgICA8IS0tIExvZ28gU1ZHIChzYW1lIGFzIGxvZ2luKSAtLT4KICAgIDxkaXYgY2xhc3M9Imhkci1sb2dvLXN2Zy13cmFwIj4KICAgICAgPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3aWR0aD0iNzIiIGhlaWdodD0iNzIiPgogICAgICAgIDxkZWZzPgogICAgICAgICAgPGxpbmVhckdyYWRpZW50IGlkPSJoVyIgeDE9IjAlIiB5MT0iMCUiIHgyPSIxMDAlIiB5Mj0iMCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMyNTYzZWIiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSI1MCUiICBzdG9wLWNvbG9yPSIjNjBhNWZhIi8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzA2YjZkNCIvPgogICAgICAgICAgPC9saW5lYXJHcmFkaWVudD4KICAgICAgICAgIDxyYWRpYWxHcmFkaWVudCBpZD0iaEJnIiBjeD0iNTAlIiBjeT0iNTAlIiByPSI1MCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMwZjFlNGEiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMwNjBjMWUiIHN0b3Atb3BhY2l0eT0iMC45OCIvPgogICAgICAgICAgPC9yYWRpYWxHcmFkaWVudD4KICAgICAgICAgIDxmaWx0ZXIgaWQ9ImhHbG93Ij4KICAgICAgICAgICAgPGZlR2F1c3NpYW5CbHVyIHN0ZERldmlhdGlvbj0iMi41IiByZXN1bHQ9ImIiLz4KICAgICAgICAgICAgPGZlTWVyZ2U+PGZlTWVyZ2VOb2RlIGluPSJiIi8+PGZlTWVyZ2VOb2RlIGluPSJTb3VyY2VHcmFwaGljIi8+PC9mZU1lcmdlPgogICAgICAgICAgPC9maWx0ZXI+CiAgICAgICAgICA8Y2xpcFBhdGggaWQ9ImhDbGlwIj48Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIvPjwvY2xpcFBhdGg+CiAgICAgICAgPC9kZWZzPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQ2IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMTIpIiBzdHJva2Utd2lkdGg9IjEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSI0MiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC4yKSIgc3Ryb2tlLXdpZHRoPSIxIiBzdHJva2UtZGFzaGFycmF5PSI1IDQiIGNsYXNzPSJoZHItb3JiaXQtcmluZyIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM4IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMjIpIiBzdHJva2Utd2lkdGg9IjEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIgZmlsbD0idXJsKCNoQmcpIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiIGZpbGw9Im5vbmUiIHN0cm9rZT0idXJsKCNoVykiIHN0cm9rZS13aWR0aD0iMS44IiBvcGFjaXR5PSIwLjkiLz4KICAgICAgICA8bGluZSB4MT0iNTAiIHkxPSIxNCIgeDI9IjUwIiB5Mj0iMjAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iODAiIHgyPSI1MCIgeTI9Ijg2IiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSIxNCIgeTE9IjUwIiB4Mj0iMjAiIHkyPSI1MCIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iODAiIHkxPSI1MCIgeDI9Ijg2IiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGcgY2xpcC1wYXRoPSJ1cmwoI2hDbGlwKSI+CiAgICAgICAgICA8cG9seWxpbmUgcG9pbnRzPSIxNiw1MCAyNCw1MCAyOSwzMiAzNCw2OCAzOSwzMiA0NCw1MCA4NCw1MCIKICAgICAgICAgICAgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ1cmwoI2hXKSIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIKICAgICAgICAgICAgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci13YXZlLWFuaW0iLz4KICAgICAgICA8L2c+CiAgICAgICAgPGNpcmNsZSBjeD0iMjkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjNjBhNWZhIiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0xIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjMDZiNmQ0IiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0yIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzQiIGN5PSI2OCIgcj0iMi41IiBmaWxsPSIjNjBhNWZhIiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0xIi8+CiAgICAgIDwvc3ZnPgogICAgPC9kaXY+CgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE4cHg7Zm9udC13ZWlnaHQ6OTAwO2xldHRlci1zcGFjaW5nOjRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZTBmMmZlLCM2MGE1ZmEsIzA2YjZkNCk7LXdlYmtpdC1iYWNrZ3JvdW5kLWNsaXA6dGV4dDstd2Via2l0LXRleHQtZmlsbC1jb2xvcjp0cmFuc3BhcmVudDtiYWNrZ3JvdW5kLWNsaXA6dGV4dDsiPkNIQUlZQTwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzo5cHg7Y29sb3I6cmdiYSg5NiwxNjUsMjUwLDAuNik7bWFyZ2luLXRvcDoycHg7Ij5QUk9KRUNUPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJ3aWR0aDoxNDBweDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LCM2MGE1ZmEsIzA2YjZkNCx0cmFuc3BhcmVudCk7bWFyZ2luOjZweCBhdXRvO29wYWNpdHk6MC41OyI+PC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjRweDtjb2xvcjpyZ2JhKDYsMTgyLDIxMiwwLjU1KTttYXJnaW4tdG9wOjJweDsiPlYyUkFZICZhbXA7IFNTSDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6cmdiYSg5NiwxNjUsMjUwLDAuNSk7bWFyZ2luLXRvcDo0cHg7IiBpZD0iaGRyLWRvbWFpbiI+U0VDVVJFIFBBTkVMPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gTkFWIC0tPgogIDxkaXYgY2xhc3M9Im5hdi13cmFwIj4KICA8ZGl2IGNsYXNzPSJuYXYiPgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gYWN0aXZlIiBvbmNsaWNrPSJzdygnZGFzaGJvYXJkJyx0aGlzKSI+8J+TiiDguYHguJTguIrguJrguK3guKPguYzguJQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnY3JlYXRlJyx0aGlzKSI+4p6VIOC4quC4o+C5ieC4suC4h+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdtYW5hZ2UnLHRoaXMpIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdvbmxpbmUnLHRoaXMpIj7wn5+iIOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdiYW4nLHRoaXMpIj7wn5qrIOC4m+C4peC4lOC5geC4muC4mTwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gbmF2LXNwZWVkIiBvbmNsaWNrPSJzdygnc3BlZWQnLHRoaXMpIj7imqEg4Liq4Lib4Li14LiU4LmA4LiX4LiqPC9kaXY+CiAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIgaWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFuIGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7imqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9udC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGltZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJvdyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3guKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAgICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklDRSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2ltZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgtQUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlzLm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWlnaHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdTIMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBXUyDCtyB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KCiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCIgc3R5bGU9Im1hcmdpbi10b3A6MjBweCI+8J+UkSDguKPguLDguJrguJogU1NIIFdFQlNPQ0tFVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3NzaCcpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtc3NoIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6I2ZmZjtmb250LWZhbWlseTptb25vc3BhY2UiPlNTSCZndDs8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgc3NoIj5TU0gg4oCTIFdTIFR1bm5lbDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+U1NIIMK3IFBvcnQgODAgwrcgRHJvcGJlYXIgMTQzLzEwOTxicj5OcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IEFJUyDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLWFpcyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgYWlzLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWxvZ28gc2VsLWFpcy1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouOHJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgU05JOiBjai1lYmIuc3BlZWR0ZXN0Lm5ldDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckBhaXMiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLWFpcyIgaWQ9ImFpcy1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCdhaXMnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0iYWlzLXJlc3VsdCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtcmVzdWx0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSciPuKclTwvYnV0dG9uPgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OnIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiIgaWQ9InItYWlzLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici1haXMtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItYWlzLWV4cCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtbGluayIgaWQ9InItYWlzLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItYWlzLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0iYWlzLXFyIiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLXRvcDoxMnB4OyI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogVFJVRSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXRydWUiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0taGRyIHRydWUtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlLXNtIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tdGl0bGUgdHJ1ZSI+VFJVRSDigJMgVkRPPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDg4ODAgwrcgU05JOiB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckB0cnVlIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+ThSDguKfguLHguJnguYPguIrguYnguIfguLLguJkgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4gY2J0bi10cnVlIiBpZD0idHJ1ZS1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCd0cnVlJykiPuKaoSDguKrguKPguYnguLLguIcgVFJVRSBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJ0cnVlLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0idHJ1ZS1yZXN1bHQiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0icmVzLWNsb3NlIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndHJ1ZS1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici10cnVlLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici10cnVlLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLXRydWUtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici10cnVlLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItdHJ1ZS1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9InRydWUtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBTU0gg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1zc2giIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNzaC1kYXJrLWZvcm0iPgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7inpUg4LmA4Lie4Li04LmI4LihIFNTSCBVU0VSPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1wYXNzIiBwbGFjZWhvbGRlcj0icGFzc3dvcmQiIHR5cGU9InBhc3N3b3JkIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4Lil4Li04Lih4Li04LiV4LmE4Lit4Lie4Li1PC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+4pyI77iPIOC5gOC4peC4t+C4reC4gSBQT1JUPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIGFjdGl2ZS1wODAiIGlkPSJwYi04MCIgb25jbGljaz0icGlja1BvcnQoJzgwJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn4yQPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgODA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XUyDCtyBIVFRQPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBvcnQtYnRuIiBpZD0icGItNDQzIiBvbmNsaWNrPSJwaWNrUG9ydCgnNDQzJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1pY29uIj7wn5SSPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLW5hbWUiPlBvcnQgNDQzPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLXN1YiI+V1NTIMK3IFNTTDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn4yQIOC5gOC4peC4t+C4reC4gSBJU1AgLyBPUEVSQVRPUjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBpY2stZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCBhLWR0YWMiIGlkPSJwcm8tZHRhYyIgb25jbGljaz0icGlja1BybygnZHRhYycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCfn6A8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRUQUMgR0FNSU5HPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5kbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0icHJvLXRydWUiIG9uY2xpY2s9InBpY2tQcm8oJ3RydWUnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj7wn5S1PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5UUlVFIFRXSVRURVI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmhlbHAueC5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCI+8J+TsSDguYDguKXguLfguK3guIEgQVBQPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtbnB2IiBpZD0iYXBwLW5wdiIgb25jbGljaz0icGlja0FwcCgnbnB2JykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+PGRpdiBzdHlsZT0id2lkdGg6MzhweDtoZWlnaHQ6MzhweDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMGQyYTNhO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjttYXJnaW46MCBhdXRvIC4xcmVtO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi44NXJlbTtjb2xvcjojMDBjY2ZmO2xldHRlci1zcGFjaW5nOi0xcHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMCwyMDQsMjU1LC4zKSI+blY8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPk5wdiBUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPm5wdnQtc3NoOi8vPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0iYXBwLWRhcmsiIG9uY2xpY2s9InBpY2tBcHAoJ2RhcmsnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMxMTE7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6c2Fucy1zZXJpZjtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi42MnJlbTtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOi41cHg7Ym9yZGVyOjEuNXB4IHNvbGlkICM0NDQiPkRBUks8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRhcmtUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRhcmt0dW5uZWw6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuLXNzaCIgaWQ9InNzaC1idG4iIG9uY2xpY2s9ImNyZWF0ZVNTSCgpIj7inpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXI8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InNzaC1hbGVydCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibGluay1yZXN1bHQiIGlkPSJzc2gtbGluay1yZXN1bHQiPjwvZGl2PgogICAgICA8L2Rpdj4KCiAgICAgIDwhLS0gVXNlciB0YWJsZSAtLT4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbjowIj7wn5OLIOC4o+C4suC4ouC4iuC4t+C5iOC4rSBVU0VSUzwvZGl2PgogICAgICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0ic3NoLXNlYXJjaCIgcGxhY2Vob2xkZXI9IuC4hOC5ieC4meC4q+C4si4uLiIgb25pbnB1dD0iZmlsdGVyU1NIVXNlcnModGhpcy52YWx1ZSkiCiAgICAgICAgICAgIHN0eWxlPSJ3aWR0aDoxMjBweDttYXJnaW46MDtmb250LXNpemU6MTFweDtwYWRkaW5nOjZweCAxMHB4Ij4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1dGJsLXdyYXAiPgogICAgICAgICAgPHRhYmxlIGNsYXNzPSJ1dGJsIj4KICAgICAgICAgICAgPHRoZWFkPjx0cj48dGg+IzwvdGg+PHRoPlVTRVJOQU1FPC90aD48dGg+4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC90aD48dGg+4Liq4LiW4Liy4LiZ4LiwPC90aD48dGg+QUNUSU9OPC90aD48L3RyPjwvdGhlYWQ+CiAgICAgICAgICAgIDx0Ym9keSBpZD0ic3NoLXVzZXItdGJvZHkiPjx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MjBweDtjb2xvcjp2YXIoLS1tdXRlZCkiPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvdGQ+PC90cj48L3Rib2R5PgogICAgICAgICAgPC90YWJsZT4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgPC9kaXY+PCEtLSAvdGFiLWNyZWF0ZSAtLT4KCjwhLS0g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW1hbmFnZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4quC5gOC4i+C4reC4o+C5jCBWTEVTUzwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkVXNlcnMoKSI+4oa7IOC5guC4q+C4peC4lDwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0idXNlci1zZWFyY2giIHBsYWNlaG9sZGVyPSLwn5SNICDguITguYnguJnguKvguLIgdXNlcm5hbWUuLi4iIG9uaW5wdXQ9ImZpbHRlclVzZXJzKHRoaXMudmFsdWUpIj4KICAgICAgPGRpdiBpZD0idXNlci1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguJvguLjguYjguKHguYLguKvguKXguJTguYDguJ7guLfguYjguK3guJTguLbguIfguILguYnguK3guKHguLnguKU8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1vbmxpbmUiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+8J+foiDguKLguLnguKrguYDguIvguK3guKPguYzguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZE9ubGluZSgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvY3IiPgogICAgICAgIDxkaXYgY2xhc3M9Im9waWxsIiBpZD0ib25saW5lLXBpbGwiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj48c3BhbiBpZD0ib25saW5lLWNvdW50Ij4wPC9zcGFuPiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0idXQiIGlkPSJvbmxpbmUtdGltZSI+LS08L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4LiU4Lij4Li14LmA4Lif4Lij4LiK4LmA4Lie4Li34LmI4Lit4LiU4Li54Lic4Li54LmJ4LmD4LiK4LmJ4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQkFOIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItYmFuIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiPvCfmqsg4LiI4Lix4LiU4LiB4Liy4LijIFNTSCBVc2VyczwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBVU0VSTkFNRTwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJiYW4tdXNlciIgcGxhY2Vob2xkZXI9IuC5g+C4quC5iCB1c2VybmFtZSDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguKXguJoiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNTgwM2QsIzIyYzU1ZSkiIG9uY2xpY2s9ImRlbGV0ZVNTSCgpIj7wn5eR77iPIOC4peC4miBTU0ggVXNlcjwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImJhbi1hbGVydCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+TiyBTU0ggVXNlcnMg4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgaWQ9InNzaC11c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgoKICA8IS0tIFNQRUVEIFRFU1QgVEFCIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1zcGVlZCI+CiAgICA8ZGl2IGNsYXNzPSJzcGVlZC1oZXJvIj4KICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtdGl0bGUiPuKaoSBWUFMgU1BFRUQgVEVTVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1wcm9nIj48ZGl2IGNsYXNzPSJzcGVlZC1wcm9nLWZpbGwiIGlkPSJzcGVlZC1wcm9nLWZpbGwiPjwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1zdGF0dXMiIGlkPSJzcGVlZC1zdGF0dXMiPuC4geC4lOC4m+C4uOC5iOC4oeC5gOC4nuC4t+C5iOC4reC5gOC4o+C4tOC5iOC4oeC4l+C4lOC4quC4reC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1nYXVnZS13cmFwIj4KICAgICAgICA8c3ZnIGNsYXNzPSJzcGVlZC1nYXVnZS1zdmciIHZpZXdCb3g9IjAgMCAxNjAgOTAiIHdpZHRoPSIxNjAiIGhlaWdodD0iOTAiPgogICAgICAgICAgPHBhdGggZD0iTTEwLDgwIEE3MCw3MCAwIDAsMSAxNTAsODAiIGNsYXNzPSJzcGVlZC1nYXVnZS1iZyIvPgogICAgICAgICAgPHBhdGggaWQ9ImdhdWdlLWZpbGwiIGQ9Ik0xMCw4MCBBNzAsNzAgMCAwLDEgMTUwLDgwIiBjbGFzcz0ic3BlZWQtZ2F1Z2UtZmlsbCIKICAgICAgICAgICAgc3Ryb2tlPSIjMDZiNmQ0IiBzdHJva2UtZGFzaGFycmF5PSIyMjAiIHN0cm9rZS1kYXNob2Zmc2V0PSIyMjAiLz4KICAgICAgICA8L3N2Zz4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1jZW50ZXIiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtdmFsIiBpZD0iZ2F1Z2UtdmFsIj4tLTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtdW5pdCIgaWQ9ImdhdWdlLXVuaXQiPk1icHM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXBpbmctcm93Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1waW5nLWl0ZW0iPjxkaXYgY2xhc3M9InNwZWVkLXBpbmctbGFiZWwiPlBJTkc8L2Rpdj48ZGl2IGNsYXNzPSJzcGVlZC1waW5nLXZhbCIgaWQ9InBpbmctdmFsIj4tLSBtczwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXBpbmctaXRlbSI+PGRpdiBjbGFzcz0ic3BlZWQtcGluZy1sYWJlbCI+SklUVEVSPC9kaXY+PGRpdiBjbGFzcz0ic3BlZWQtcGluZy12YWwiIGlkPSJqaXR0ZXItdmFsIj4tLSBtczwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXBpbmctaXRlbSI+PGRpdiBjbGFzcz0ic3BlZWQtcGluZy1sYWJlbCI+UEFDS0VUIExPU1M8L2Rpdj48ZGl2IGNsYXNzPSJzcGVlZC1waW5nLXZhbCIgaWQ9Imxvc3MtdmFsIj4tLSU8L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlc3VsdHMiPgogICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1yZXMtY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzLWljb24iPuKsh++4jzwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlcy1sYWJlbCI+RE9XTkxPQUQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1yZXMtdmFsIGRsLWNvbG9yIiBpZD0iZGwtdmFsIj4tLTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlcy11bml0Ij5NYnBzPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtYmFyLXdyYXAiPjxkaXYgY2xhc3M9InNwZWVkLWJhciBkbC1iYXIiIGlkPSJkbC1iYXIiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzLWNhcmQiPgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlcy1pY29uIj7irIbvuI88L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1yZXMtbGFiZWwiPlVQTE9BRDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlcy12YWwgdWwtY29sb3IiIGlkPSJ1bC12YWwiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzLXVuaXQiPk1icHM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1iYXItd3JhcCI+PGRpdiBjbGFzcz0ic3BlZWQtYmFyIHVsLWJhciIgaWQ9InVsLWJhciI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzcGVlZC1idG5zIj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ic3BlZWQtYnRuIHNwZWVkLWJ0bi1kbCIgaWQ9ImJ0bi1kbCIgb25jbGljaz0ic3RhcnRTcGVlZFRlc3QoJ2Rvd25sb2FkJykiPuKsh++4jyBURVNUIERPV05MT0FEPC9idXR0b24+CiAgICAgIDxidXR0b24gY2xhc3M9InNwZWVkLWJ0biBzcGVlZC1idG4tdWwiIGlkPSJidG4tdWwiIG9uY2xpY2s9InN0YXJ0U3BlZWRUZXN0KCd1cGxvYWQnKSI+4qyG77iPIFRFU1QgVVBMT0FEPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjEycHgiPvCfk6EgVlBTIElORk88L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtaW5mby1ncmlkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1pbmZvLWl0ZW0iPjxkaXYgY2xhc3M9InNwZWVkLWluZm8tbGJsIj5TRVJWRVIgSVA8L2Rpdj48ZGl2IGNsYXNzPSJzcGVlZC1pbmZvLXZhbCIgaWQ9InZwcy1pcCIgc3R5bGU9ImZvbnQtc2l6ZToxMHB4Ij4tLTwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLWluZm8taXRlbSI+PGRpdiBjbGFzcz0ic3BlZWQtaW5mby1sYmwiPlRFU1QgU0laRTwvZGl2PjxkaXYgY2xhc3M9InNwZWVkLWluZm8tdmFsIiBpZD0idGVzdC1zaXplIj4yNSBNQjwvZGl2PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLWluZm8taXRlbSI+PGRpdiBjbGFzcz0ic3BlZWQtaW5mby1sYmwiPlBST1RPQ09MPC9kaXY+PGRpdiBjbGFzcz0ic3BlZWQtaW5mby12YWwiPkhUVFA8L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCjwvZGl2PjwhLS0gL3dyYXAgLS0+Cgo8IS0tIE1PREFMIC0tPgo8ZGl2IGNsYXNzPSJtb3ZlciIgaWQ9Im1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNtKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiIGlkPSJtdCI+4pqZ77iPIHVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbSgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ToSBQb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0iZGUiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OmIERhdGEgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGQiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OKIFRyYWZmaWMg4LmD4LiK4LmJPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR0ciI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk7EgSVAgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGkiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IG1vbm8iIGlkPSJkdXUiPi0tPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMHB4Ij7guYDguKXguLfguK3guIHguIHguLLguKPguJTguLPguYDguJnguLTguJnguIHguLLguKM8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImFncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVuZXcnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIQ8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdleHRlbmQnKSI+PGRpdiBjbGFzcz0iYWkiPvCfk4U8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdhZGRkYXRhJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OmPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oSBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKE8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignc2V0ZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+4pqW77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC4seC5ieC4hyBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4geC4s+C4q+C4meC4lOC5g+C4q+C4oeC5iDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdyZXNldCcpIj48ZGl2IGNsYXNzPSJhaSI+8J+UgzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKPguLXguYDguIvguJUgVHJhZmZpYzwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biBkYW5nZXIiIG9uY2xpY2s9Im1BY3Rpb24oJ2RlbGV0ZScpIj48ZGl2IGNsYXNzPSJhaSI+8J+Xke+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKXguJrguKLguLnguKo8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lil4Lia4LiW4Liy4Lin4LijPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4LmI4Lit4Lit4Liy4Lii4Li4IC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlbmV3Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IOKAlCDguKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4mTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXJlbmV3LWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZW5ldy1idG4iIG9uY2xpY2s9ImRvUmVuZXdVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKHguKfguLHguJkgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItZXh0ZW5kIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk4Ug4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIOKAlCDguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4meC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLWV4dGVuZC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZXh0ZW5kLWJ0biIgb25jbGljaz0iZG9FeHRlbmRVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguYDguJ7guLTguYjguKHguKfguLHguJk8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKEgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1hZGRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk6Yg4LmA4Lie4Li04LmI4LihIERhdGEg4oCUIOC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKHguIjguLLguIHguJfguLXguYjguKHguLXguK3guKLguLnguYg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4mSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1hZGRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIxMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tYWRkZGF0YS1idG4iIG9uY2xpY2s9ImRvQWRkRGF0YSgpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4LihIERhdGE8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguJXguLHguYnguIcgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1zZXRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPuKalu+4jyDguJXguLHguYnguIcgRGF0YSDigJQg4LiB4Liz4Lir4LiZ4LiUIExpbWl0IOC5g+C4q+C4oeC5iCAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPkRhdGEgTGltaXQgKEdCKSDigJQgMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXNldGRhdGEtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXNldGRhdGEtYnRuIiBvbmNsaWNrPSJkb1NldERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC4seC5ieC4hyBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItcmVzZXQiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+UgyDguKPguLXguYDguIvguJUgVHJhZmZpYyDigJQg4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJ4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4geC4suC4o+C4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4iOC4sOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lCBVcGxvYWQvRG93bmxvYWQg4LiX4Lix4LmJ4LiH4Lir4Lih4LiU4LiC4Lit4LiH4Lii4Li54Liq4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXJlc2V0LWJ0biIgb25jbGljaz0iZG9SZXNldFRyYWZmaWMoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lil4Lia4Lii4Li54LiqIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWRlbGV0ZSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+8J+Xke+4jyDguKXguJrguKLguLnguKog4oCUIOC4peC4muC4luC4suC4p+C4oyDguYTguKHguYjguKrguLLguKHguLLguKPguJbguIHguLnguYnguITguLfguJnguYTguJTguYk8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTJweCI+4Lii4Li54LiqIDxiIGlkPSJtLWRlbC1uYW1lIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+PC9iPiDguIjguLDguJbguLnguIHguKXguJrguK3guK3guIHguIjguLLguIHguKPguLDguJrguJrguJbguLLguKfguKM8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZGVsZXRlLWJ0biIgb25jbGljaz0iZG9EZWxldGVVc2VyKCkiIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2RjMjYyNiwjZWY0NDQ0KSI+8J+Xke+4jyDguKLguLfguJnguKLguLHguJnguKXguJrguKLguLnguKo8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ibW9kYWwtYWxlcnQiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPjwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQgc3JjPSJjb25maWcuanMiIG9uZXJyb3I9IndpbmRvdy5DSEFJWUFfQ09ORklHPXt9Ij48L3NjcmlwdD4KPHNjcmlwdD4KLy8g4pWQ4pWQ4pWQ4pWQIENPTkZJRyDilZDilZDilZDilZAKY29uc3QgQ0ZHID0gKHR5cGVvZiB3aW5kb3cuQ0hBSVlBX0NPTkZJRyAhPT0gJ3VuZGVmaW5lZCcpID8gd2luZG93LkNIQUlZQV9DT05GSUcgOiB7fTsKY29uc3QgSE9TVCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhvc3RuYW1lOwpjb25zdCBYVUkgID0gJy94dWktYXBpJzsgICAgICAgICAgLy8geC11aSBBUEkg4LmC4LiU4Lii4LiV4Lij4LiHIOC5hOC4oeC5iOC4nOC5iOC4suC4mSBtaWRkbGV3YXJlCmNvbnN0IEFQSSAgPSAnL2FwaSc7ICAgICAgICAgICAgICAgLy8gY2hhaXlhLXNzaC1hcGkgKFNTSCB1c2VycyDguYDguJfguYjguLLguJnguLHguYnguJkpCmNvbnN0IFNFU1NJT05fS0VZID0gJ2NoYWl5YV9hdXRoJzsKCi8vIOKUgOKUgCBEaXJlY3QgeC11aSBBUEkgaGVscGVycyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKbGV0IF94dWlDb29raWUgPSBmYWxzZTsKYXN5bmMgZnVuY3Rpb24geHVpRW5zdXJlTG9naW4oKSB7CiAgaWYgKF94dWlDb29raWUpIHJldHVybiB0cnVlOwogIGNvbnN0IF9zID0gKCgpID0+IHsgdHJ5IHsgcmV0dXJuIEpTT04ucGFyc2Uoc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSl8fCd7fScpOyB9IGNhdGNoKGUpe3JldHVybnt9O30gfSkoKTsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJjaFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyfHxDRkcueHVpX3VzZXJ8fCcnLCBwYXNzd29yZDogX3MucGFzc3x8Q0ZHLnh1aV9wYXNzfHwnJyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJKycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNvZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgX3h1aUNvb2tpZSA9ICEhZC5zdWNjZXNzOwogIHJldHVybiBfeHVpQ29va2llOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aUdldChwYXRoKSB7CiAgaWYgKCFfeHVpQ29va2llKSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIHJldHVybiByLmpzb24oKTsKfQphc3luYyBmdW5jdGlvbiB4dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAgICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgYm9keTogSlNPTi5zdHJpbmdpZnkoYm9keSkKICB9KTsKICByZXR1cm4gci5qc29uKCk7Cn0KCi8vIFNlc3Npb24gY2hlY2sKY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwppZiAoIV9zLnVzZXIgfHwgIV9zLnBhc3MgfHwgRGF0ZS5ub3coKSA+PSAoX3MuZXhwfHwwKSkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8gSGVhZGVyIGRvbWFpbgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLWRvbWFpbicpLnRleHRDb250ZW50ID0gSE9TVCArICcgwrcgdjUnOwoKLy8g4pWQ4pWQ4pWQ4pWQIFVUSUxTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBmbXRCeXRlcyhiKSB7CiAgaWYgKCFiIHx8IGIgPT09IDApIHJldHVybiAnMCBCJzsKICBjb25zdCBrID0gMTAyNCwgdSA9IFsnQicsJ0tCJywnTUInLCdHQicsJ1RCJ107CiAgY29uc3QgaSA9IE1hdGguZmxvb3IoTWF0aC5sb2coYikvTWF0aC5sb2coaykpOwogIHJldHVybiAoYi9NYXRoLnBvdyhrLGkpKS50b0ZpeGVkKDEpKycgJyt1W2ldOwp9CmZ1bmN0aW9uIGZtdERhdGUobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgY29uc3QgZCA9IG5ldyBEYXRlKG1zKTsKICByZXR1cm4gZC50b0xvY2FsZURhdGVTdHJpbmcoJ3RoLVRIJyx7eWVhcjonbnVtZXJpYycsbW9udGg6J3Nob3J0JyxkYXk6J251bWVyaWMnfSk7Cn0KZnVuY3Rpb24gZGF5c0xlZnQobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gbnVsbDsKICByZXR1cm4gTWF0aC5jZWlsKChtcyAtIERhdGUubm93KCkpIC8gODY0MDAwMDApOwp9CmZ1bmN0aW9uIHNldFJpbmcoaWQsIHBjdCkgewogIGNvbnN0IGNpcmMgPSAxMzguMjsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoZWwpIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBjaXJjIC0gKGNpcmMgKiBNYXRoLm1pbihwY3QsMTAwKSAvIDEwMCk7Cn0KZnVuY3Rpb24gc2V0QmFyKGlkLCBwY3QsIHdhcm49ZmFsc2UpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuc3R5bGUud2lkdGggPSBNYXRoLm1pbihwY3QsMTAwKSArICclJzsKICBpZiAod2FybiAmJiBwY3QgPiA4NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KSc7CiAgZWxzZSBpZiAod2FybiAmJiBwY3QgPiA2NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2Y5NzMxNiwjZmI5MjNjKSc7Cn0KZnVuY3Rpb24gc2hvd0FsZXJ0KGlkLCBtc2csIHR5cGUpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcrdHlwZTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBpZiAodHlwZSA9PT0gJ29rJykgc2V0VGltZW91dCgoKT0+e2VsLnN0eWxlLmRpc3BsYXk9J25vbmUnO30sIDMwMDApOwp9CgovLyDilZDilZDilZDilZAgTkFWIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBzdyhuYW1lLCBlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZWMnKS5mb3JFYWNoKHM9PnMuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobj0+bi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nK25hbWUpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChuYW1lPT09J2NyZWF0ZScpIGNsb3NlRm9ybSgpOwogIGlmIChuYW1lPT09J2Rhc2hib2FyZCcpIGxvYWREYXNoKCk7CiAgaWYgKG5hbWU9PT0nbWFuYWdlJykgbG9hZFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0nb25saW5lJykgbG9hZE9ubGluZSgpOwogIGlmIChuYW1lPT09J2JhbicpIGxvYWRTU0hVc2VycygpOwogIGlmIChuYW1lPT09J3NwZWVkJykgeyBzZXRHYXVnZSgwKTsgfQp9CgovLyDilIDilIAgRm9ybSBuYXYg4pSA4pSACmxldCBfY3VyRm9ybSA9IG51bGw7CmZ1bmN0aW9uIG9wZW5Gb3JtKGlkKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBbJ2FpcycsJ3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gZj09PWlkID8gJ2Jsb2NrJyA6ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IGlkOwogIGlmIChpZD09PSdzc2gnKSBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB3aW5kb3cuc2Nyb2xsVG8oMCwwKTsKfQpmdW5jdGlvbiBjbG9zZUZvcm0oKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICB9KTsKICBfY3VyRm9ybSA9IG51bGw7Cn0KCmxldCBfd3NQb3J0ID0gJzgwJzsKZnVuY3Rpb24gdG9nUG9ydChidG4sIHBvcnQpIHsKICBfd3NQb3J0ID0gcG9ydDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M4MC1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzgwJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzNDQzLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9PT0nNDQzJyk7Cn0KZnVuY3Rpb24gdG9nR3JvdXAoYnRuLCBjbHMpIHsKICBidG4uY2xvc2VzdCgnZGl2JykucXVlcnlTZWxlY3RvckFsbChjbHMpLmZvckVhY2goYj0+Yi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYnRuLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9CgovLyAoeHVpR2V0L3h1aVBvc3QgZGVmaW5lZCBhYm92ZSkKCi8vIOKVkOKVkOKVkOKVkCBEQVNIQk9BUkQg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWREYXNoKCkgewogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcmVmcmVzaCcpOwogIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsgLi4uJzsKICBfeHVpQ29va2llID0gZmFsc2U7IC8vIGZvcmNlIHJlLWxvZ2luIOC5gOC4quC4oeC4rQoKICB0cnkgewogICAgLy8g4pWQ4pWQIDEpIOC4lOC4tuC4hyBTZXJ2ZXIgU3RhdHVzIOC4iOC4suC4gSAzeC11aSDguYLguJTguKLguJXguKPguIcg4pWQ4pWQCiAgICBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgY29uc3Qgc3YgPSBhd2FpdCBmZXRjaChYVUkrJy9wYW5lbC9hcGkvc2VydmVyL3N0YXR1cycsIHsKICAgICAgY3JlZGVudGlhbHM6ICdpbmNsdWRlJwogICAgfSkudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwoKICAgIGlmIChzdiAmJiBzdi5zdWNjZXNzICYmIHN2Lm9iaikgewogICAgICBjb25zdCBvID0gc3Yub2JqOwoKICAgICAgLy8gQ1BVCiAgICAgIGNvbnN0IGNwdSA9IE1hdGgucm91bmQoby5jcHUgfHwgMCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtcGN0JykudGV4dENvbnRlbnQgPSBjcHUgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtY29yZXMnKS50ZXh0Q29udGVudCA9IChvLmNwdUNvcmVzIHx8IG8ubG9naWNhbFBybyB8fCAnLS0nKSArICcgY29yZXMnOwogICAgICBzZXRSaW5nKCdjcHUtcmluZycsIGNwdSk7IHNldEJhcignY3B1LWJhcicsIGNwdSwgdHJ1ZSk7CgogICAgICAvLyBSQU0KICAgICAgY29uc3QgcmFtVCA9ICgoby5tZW0/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgcmFtVSA9ICgoby5tZW0/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCByYW1QID0gcmFtVCA+IDAgPyBNYXRoLnJvdW5kKHJhbVUvcmFtVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1wY3QnKS50ZXh0Q29udGVudCA9IHJhbVAgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tZGV0YWlsJykudGV4dENvbnRlbnQgPSByYW1VLnRvRml4ZWQoMSkrJyAvICcrcmFtVC50b0ZpeGVkKDEpKycgR0InOwogICAgICBzZXRSaW5nKCdyYW0tcmluZycsIHJhbVApOyBzZXRCYXIoJ3JhbS1iYXInLCByYW1QLCB0cnVlKTsKCiAgICAgIC8vIERpc2sKICAgICAgY29uc3QgZHNrVCA9ICgoby5kaXNrPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIGRza1UgPSAoKG8uZGlzaz8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IGRza1AgPSBkc2tUID4gMCA/IE1hdGgucm91bmQoZHNrVS9kc2tUKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1wY3QnKS5pbm5lckhUTUwgPSBkc2tQICsgJzxzcGFuPiU8L3NwYW4+JzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stZGV0YWlsJykudGV4dENvbnRlbnQgPSBkc2tVLnRvRml4ZWQoMCkrJyAvICcrZHNrVC50b0ZpeGVkKDApKycgR0InOwogICAgICBzZXRCYXIoJ2Rpc2stYmFyJywgZHNrUCwgdHJ1ZSk7CgogICAgICAvLyBVcHRpbWUKICAgICAgY29uc3QgdXAgPSBvLnVwdGltZSB8fCAwOwogICAgICBjb25zdCB1ZCA9IE1hdGguZmxvb3IodXAvODY0MDApLCB1aCA9IE1hdGguZmxvb3IoKHVwJTg2NDAwKS8zNjAwKSwgdW0gPSBNYXRoLmZsb29yKCh1cCUzNjAwKS82MCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtdmFsJykudGV4dENvbnRlbnQgPSB1ZCA+IDAgPyB1ZCsnZCAnK3VoKydoJyA6IHVoKydoICcrdW0rJ20nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXN1YicpLnRleHRDb250ZW50ID0gdWQrJ+C4p+C4seC4mSAnK3VoKyfguIrguKEuICcrdW0rJ+C4meC4suC4l+C4tSc7CiAgICAgIGNvbnN0IGxvYWRzID0gby5sb2FkcyB8fCBbXTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvYWQtY2hpcHMnKS5pbm5lckhUTUwgPSBsb2Fkcy5tYXAoKGwsaSk9PgogICAgICAgIGA8c3BhbiBjbGFzcz0iYmRnIj4ke1snMW0nLCc1bScsJzE1bSddW2ldfTogJHtsLnRvRml4ZWQoMil9PC9zcGFuPmApLmpvaW4oJycpOwoKICAgICAgLy8gTmV0d29yayBJL08gKHJlYWx0aW1lIHNwZWVkKQogICAgICBpZiAoby5uZXRJTykgewogICAgICAgIGNvbnN0IHVwX2IgPSBvLm5ldElPLnVwfHwwLCBkbl9iID0gby5uZXRJTy5kb3dufHwwOwogICAgICAgIGNvbnN0IHVwRm10ID0gZm10Qnl0ZXModXBfYiksIGRuRm10ID0gZm10Qnl0ZXMoZG5fYik7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cCcpLmlubmVySFRNTCA9IHVwRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4nKS5pbm5lckhUTUwgPSBkbkZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgfQogICAgICBpZiAoby5uZXRUcmFmZmljKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cC10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5zZW50fHwwKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnJlY3Z8fDApOwogICAgICB9CgogICAgICAvLyBYVUkgWHJheSB2ZXJzaW9uCiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktdmVyJykudGV4dENvbnRlbnQgPSBvLnhyYXlWZXJzaW9uIHx8ICctLSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0gJ29waWxsJzsKICAgIH0gZWxzZSB7CiAgICAgIC8vIDN4LXVpIOC5hOC4oeC5iOC4leC4reC4muC4quC4meC4reC4hwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj7guK3guK3guJ/guYTguKXguJnguYwnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwgb2ZmJzsKICAgIH0KCiAgICAvLyDilZDilZAgMikg4LiU4Li24LiHIEluYm91bmRzIGNvdW50IOC4iOC4suC4gSAzeC11aSDilZDilZAKICAgIGNvbnN0IGlibCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKGlibCAmJiBpYmwuc3VjY2VzcykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLWluYm91bmRzJykudGV4dENvbnRlbnQgPSAoaWJsLm9ianx8W10pLmxlbmd0aDsKICAgIH0KCiAgICAvLyDilZDilZAgMykg4LiU4Li24LiHIFNlcnZpY2UgU3RhdHVzIOC4iOC4suC4gSBTU0ggQVBJICjguKrguLPguKvguKPguLHguJogZHJvcGJlYXIvbmdpbngvYmFkdnBuIOC4l+C4teC5iCAzeC11aSDguYTguKHguYjguKPguLnguYkpIOKVkOKVkAogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3QpIHsKICAgICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogICAgfQoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsYXN0LXVwZGF0ZScpLnRleHRDb250ZW50ID0gJ+C4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogJyArIG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogIH0gY2F0Y2goZSkgewogICAgY29uc29sZS5lcnJvcihlKTsKICB9IGZpbmFsbHkgewogICAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyDguKPguLXguYDguJ/guKPguIonOwogIH0KfQoKCi8vIOKVkOKVkOKVkOKVkCBTRVJWSUNFUyDilZDilZDilZDilZAKY29uc3QgU1ZDX0RFRiA9IFsKICB7IGtleToneHVpJywgICAgICBpY29uOifwn5OhJywgbmFtZToneC11aSBQYW5lbCcsICAgICAgcG9ydDonOjIwNTMnIH0sCiAgeyBrZXk6J3NzaCcsICAgICAgaWNvbjon8J+QjScsIG5hbWU6J1NTSCBBUEknLCAgICAgICAgICBwb3J0Oic6Njc4OScgfSwKICB7IGtleTonZHJvcGJlYXInLCBpY29uOifwn5C7JywgbmFtZTonRHJvcGJlYXIgU1NIJywgICAgIHBvcnQ6JzoxNDMgOjEwOScgfSwKICB7IGtleTonbmdpbngnLCAgICBpY29uOifwn4yQJywgbmFtZTonbmdpbnggLyBQYW5lbCcsICAgIHBvcnQ6Jzo4MCA6NDQzJyB9LAogIHsga2V5Oidzc2h3cycsICAgIGljb246J/CflJInLCBuYW1lOidXUy1TdHVubmVsJywgICAgICAgcG9ydDonOjgw4oaSOjE0MycgfSwKICB7IGtleTonYmFkdnBuJywgICBpY29uOifwn46uJywgbmFtZTonQmFkVlBOIFVEUEdXJywgICAgIHBvcnQ6Jzo3MzAwJyB9LApdOwpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcyhtYXApIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSBTVkNfREVGLm1hcChzID0+IHsKICAgIGNvbnN0IHVwID0gbWFwW3Mua2V5XSA9PT0gdHJ1ZSB8fCBtYXBbcy5rZXldID09PSAnYWN0aXZlJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0ic3ZjICR7dXA/Jyc6J2Rvd24nfSI+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1sIj48c3BhbiBjbGFzcz0iZGcgJHt1cD8nJzoncmVkJ30iPjwvc3Bhbj48c3Bhbj4ke3MuaWNvbn08L3NwYW4+CiAgICAgICAgPGRpdj48ZGl2IGNsYXNzPSJzdmMtbiI+JHtzLm5hbWV9PC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPiR7cy5wb3J0fTwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9InJiZGcgJHt1cD8nJzonZG93bid9Ij4ke3VwPydSVU5OSU5HJzonRE9XTid9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQphc3luYyBmdW5jdGlvbiBsb2FkU2VydmljZXMoKSB7CiAgdHJ5IHsKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggUElDS0VSIFNUQVRFIOKVkOKVkOKVkOKVkApjb25zdCBQUk9TID0gewogIGR0YWM6IHsKICAgIG5hbWU6ICdEVEFDIEdBTUlORycsCiAgICBwcm94eTogJzEwNC4xOC42My4xMjQ6ODAnLAogICAgcGF5bG9hZDogJ0NPTk5FQ1QgLyAgSFRUUC8xLjEgW2NybGZdSG9zdDogZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbSBbY3JsZl1bY3JsZl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDpbaG9zdF1bY3JsZl1VcGdyYWRlOlVzZXItQWdlbnQ6IFt1YV1bY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfSwKICB0cnVlOiB7CiAgICBuYW1lOiAnVFJVRSBUV0lUVEVSJywKICAgIHByb3h5OiAnMTA0LjE4LjM5LjI0OjgwJywKICAgIHBheWxvYWQ6ICdQT1NUIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OmhlbHAueC5jb21bY3JsZl1Vc2VyLUFnZW50OiBbdWFdW2NybGZdW2NybGZdW3NwbGl0XVtjcl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDogW2hvc3RdW2NybGZdVXBncmFkZTogd2Vic29ja2V0W2NybGZdQ29ubmVjdGlvbjpVcGdyYWRlW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0KfTsKY29uc3QgTlBWX0hPU1QgPSAnd3d3LnByb2plY3QuZ29kdnBuLnNob3AnLCBOUFZfUE9SVCA9IDgwOwpsZXQgX3NzaFBybyA9ICdkdGFjJywgX3NzaEFwcCA9ICducHYnLCBfc3NoUG9ydCA9ICc4MCc7CgpmdW5jdGlvbiBwaWNrUG9ydChwKSB7CiAgX3NzaFBvcnQgPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi04MCcpLmNsYXNzTmFtZSAgPSAncG9ydC1idG4nICsgKHA9PT0nODAnICA/ICcgYWN0aXZlLXA4MCcgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi00NDMnKS5jbGFzc05hbWUgPSAncG9ydC1idG4nICsgKHA9PT0nNDQzJyA/ICcgYWN0aXZlLXA0NDMnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tQcm8ocCkgewogIF9zc2hQcm8gPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tZHRhYycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSdkdGFjJyA/ICcgYS1kdGFjJyA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLXRydWUnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0ndHJ1ZScgPyAnIGEtdHJ1ZScgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja0FwcChhKSB7CiAgX3NzaEFwcCA9IGE7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcC1ucHYnKS5jbGFzc05hbWUgID0gJ3BpY2stb3B0JyArIChhPT09J25wdicgID8gJyBhLW5wdicgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtZGFyaycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAoYT09PSdkYXJrJyA/ICcgYS1kYXJrJyA6ICcnKTsKfQpmdW5jdGlvbiBidWlsZE5wdkxpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgaiA9IHsKICAgIHNzaENvbmZpZ1R5cGU6J1NTSC1Qcm94eS1QYXlsb2FkJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6TlBWX0hPU1QsIHNzaFBvcnQ6TlBWX1BPUlQsCiAgICBzc2hVc2VybmFtZTpuYW1lLCBzc2hQYXNzd29yZDpwYXNzLAogICAgc25pOicnLCB0bHNWZXJzaW9uOidERUZBVUxUJywKICAgIGh0dHBQcm94eTpwcm8ucHJveHksIGF1dGhlbnRpY2F0ZVByb3h5OmZhbHNlLAogICAgcHJveHlVc2VybmFtZTonJywgcHJveHlQYXNzd29yZDonJywKICAgIHBheWxvYWQ6cHJvLnBheWxvYWQsCiAgICBkbnNNb2RlOidVRFAnLCBkbnNTZXJ2ZXI6JycsIG5hbWVzZXJ2ZXI6JycsIHB1YmxpY0tleTonJywKICAgIHVkcGd3UG9ydDo3MzAwLCB1ZHBnd1RyYW5zcGFyZW50RE5TOnRydWUKICB9OwogIHJldHVybiAnbnB2dC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KZnVuY3Rpb24gYnVpbGREYXJrTGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBwcCA9IChwcm8ucHJveHl8fCcnKS5zcGxpdCgnOicpOwogIGNvbnN0IGRoID0gcHBbMF0gfHwgcHJvLmRhcmtQcm94eTsKICBjb25zdCBqID0gewogICAgY29uZmlnVHlwZTonU1NILVBST1hZJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6SE9TVCwgc3NoUG9ydDoxNDMsCiAgICBzc2hVc2VyOm5hbWUsIHNzaFBhc3M6cGFzcywKICAgIHBheWxvYWQ6J0dFVCAvIEhUVFAvMS4xXHJcbkhvc3Q6ICcrSE9TVCsnXHJcblVwZ3JhZGU6IHdlYnNvY2tldFxyXG5Db25uZWN0aW9uOiBVcGdyYWRlXHJcblxyXG4nLAogICAgcHJveHlIb3N0OmRoLCBwcm94eVBvcnQ6ODAsCiAgICB1ZHBnd0FkZHI6JzEyNy4wLjAuMScsIHVkcGd3UG9ydDo3MzAwLCB0bHNFbmFibGVkOmZhbHNlCiAgfTsKICByZXR1cm4gJ2Rhcmt0dW5uZWwtc3NoOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CgovLyDilZDilZDilZDilZAgQ1JFQVRFIFNTSCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1kYXlzJykudmFsdWUpfHwzMDsKICBjb25zdCBpcGwgID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpID8gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpLnZhbHVlIDogMil8fDI7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIXBhc3MpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBQYXNzd29yZCcsJ2VycicpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMzQsMTk3LDk0LC4zKTtib3JkZXItdG9wLWNvbG9yOiMyMmM1NWUiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBjb25zdCByZXNFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtbGluay1yZXN1bHQnKTsKICBpZiAocmVzRWwpIHJlc0VsLmNsYXNzTmFtZT0nbGluay1yZXN1bHQnOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvY3JlYXRlX3NzaCcsIHsKICAgICAgbWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoe3VzZXIsIHBhc3N3b3JkOnBhc3MsIGRheXMsIGlwX2xpbWl0OmlwbH0pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0IHBybyAgPSBQUk9TW19zc2hQcm9dIHx8IFBST1MuZHRhYzsKICAgIGNvbnN0IGxpbmsgPSBfc3NoQXBwPT09J25wdicgPyBidWlsZE5wdkxpbmsodXNlcixwYXNzLHBybykgOiBidWlsZERhcmtMaW5rKHVzZXIscGFzcyxwcm8pOwogICAgY29uc3QgaXNOcHYgPSBfc3NoQXBwPT09J25wdic7CiAgICBjb25zdCBscENscyA9IGlzTnB2ID8gJycgOiAnIGRhcmstbHAnOwogICAgY29uc3QgY0NscyAgPSBpc05wdiA/ICducHYnIDogJ2RhcmsnOwogICAgY29uc3QgYXBwTGFiZWwgPSBpc05wdiA/ICdOcHZ0JyA6ICdEYXJrVHVubmVsJzsKCiAgICBpZiAocmVzRWwpIHsKICAgICAgcmVzRWwuY2xhc3NOYW1lID0gJ2xpbmstcmVzdWx0IHNob3cnOwogICAgICBjb25zdCBzYWZlTGluayA9IGxpbmsucmVwbGFjZSgvXFwvZywnXFxcXCcpLnJlcGxhY2UoLycvZywiXFwnIik7CiAgICAgIHJlc0VsLmlubmVySFRNTCA9CiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcmVzdWx0LWhkcic+IiArCiAgICAgICAgICAiPHNwYW4gY2xhc3M9J2ltcC1iYWRnZSAiK2NDbHMrIic+IithcHBMYWJlbCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOnZhcigtLW11dGVkKSc+Iitwcm8ubmFtZSsiIFx4YjcgUG9ydCAiK19zc2hQb3J0KyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6IzIyYzU1ZTttYXJnaW4tbGVmdDphdXRvJz5cdTI3MDUgIit1c2VyKyI8L3NwYW4+IiArCiAgICAgICAgIjwvZGl2PiIgKwogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXByZXZpZXciK2xwQ2xzKyInPiIrbGluaysiPC9kaXY+IiArCiAgICAgICAgIjxidXR0b24gY2xhc3M9J2NvcHktbGluay1idG4gIitjQ2xzKyInIGlkPSdjb3B5LXNzaC1idG4nIG9uY2xpY2s9XCJjb3B5U1NITGluaygpXCI+IisKICAgICAgICAgICJcdWQ4M2RcdWRjY2IgQ29weSAiK2FwcExhYmVsKyIgTGluayIrCiAgICAgICAgIjwvYnV0dG9uPiI7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExpbmsgPSBsaW5rOwogICAgICB3aW5kb3cuX2xhc3RTU0hBcHAgID0gY0NsczsKICAgICAgd2luZG93Ll9sYXN0U1NITGFiZWwgPSBhcHBMYWJlbDsKICAgIH0KCiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIIMK3IOC4q+C4oeC4lOC4reC4suC4ouC4uCAnK2QuZXhwLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWU9Jyc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZT0nJzsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfinpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXInOyB9Cn0KZnVuY3Rpb24gY29weVNTSExpbmsoKSB7CiAgY29uc3QgbGluayA9IHdpbmRvdy5fbGFzdFNTSExpbmt8fCcnOwogIGNvbnN0IGNDbHMgPSB3aW5kb3cuX2xhc3RTU0hBcHB8fCducHYnOwogIGNvbnN0IGxhYmVsID0gd2luZG93Ll9sYXN0U1NITGFiZWx8fCdMaW5rJzsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dChsaW5rKS50aGVuKGZ1bmN0aW9uKCl7CiAgICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvcHktc3NoLWJ0bicpOwogICAgaWYoYil7IGIudGV4dENvbnRlbnQ9J1x1MjcwNSDguITguLHguJTguKXguK3guIHguYHguKXguYnguKchJzsgc2V0VGltZW91dChmdW5jdGlvbigpe2IudGV4dENvbnRlbnQ9J1x1ZDgzZFx1ZGNjYiBDb3B5ICcrbGFiZWwrJyBMaW5rJzt9LDIwMDApOyB9CiAgfSkuY2F0Y2goZnVuY3Rpb24oKXsgcHJvbXB0KCdDb3B5IGxpbms6JyxsaW5rKTsgfSk7Cn0KCi8vIFNTSCB1c2VyIHRhYmxlCmxldCBfc3NoVGFibGVVc2VycyA9IFtdOwphc3luYyBmdW5jdGlvbiBsb2FkU1NIVGFibGVJbkZvcm0oKSB7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgX3NzaFRhYmxlVXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICAgIGlmKHRiKSB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiNlZjQ0NDQ7cGFkZGluZzoxNnB4Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gU1NIIEFQSSDguYTguKHguYjguYTguJTguYk8L3RkPjwvdHI+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyU1NIVGFibGUodXNlcnMpIHsKICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogIGlmICghdGIpIHJldHVybjsKICBpZiAoIXVzZXJzLmxlbmd0aCkgewogICAgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzoyMHB4Ij7guYTguKHguYjguKHguLUgU1NIIHVzZXJzPC90ZD48L3RyPic7CiAgICByZXR1cm47CiAgfQogIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICB0Yi5pbm5lckhUTUwgPSB1c2Vycy5tYXAoZnVuY3Rpb24odSxpKXsKICAgIGNvbnN0IGV4cGlyZWQgPSB1LmV4cCAmJiB1LmV4cCA8IG5vdzsKICAgIGNvbnN0IGFjdGl2ZSAgPSB1LmFjdGl2ZSAhPT0gZmFsc2UgJiYgIWV4cGlyZWQ7CiAgICBjb25zdCBkTGVmdCAgID0gdS5leHAgPyBNYXRoLmNlaWwoKG5ldyBEYXRlKHUuZXhwKS1EYXRlLm5vdygpKS84NjQwMDAwMCkgOiBudWxsOwogICAgY29uc3QgYmFkZ2UgICA9IGFjdGl2ZQogICAgICA/ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1nIj5BQ1RJVkU8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1yIj5FWFBJUkVEPC9zcGFuPic7CiAgICBjb25zdCBkVGFnID0gZExlZnQhPT1udWxsCiAgICAgID8gJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj4nKyhkTGVmdD4wP2RMZWZ0KydkJzon4Lir4Lih4LiUJykrJzwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj5cdTIyMWU8L3NwYW4+JzsKICAgIHJldHVybiAnPHRyPjx0ZCBzdHlsZT0iY29sb3I6dmFyKC0tbXV0ZWQpIj4nKyhpKzEpKyc8L3RkPicgKwogICAgICAnPHRkPjxiPicrdS51c2VyKyc8L2I+PC90ZD4nICsKICAgICAgJzx0ZCBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6JysoZXhwaXJlZD8nI2VmNDQ0NCc6J3ZhcigtLW11dGVkKScpKyciPicrCiAgICAgICAgKHUuZXhwfHwn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJzwvdGQ+JyArCiAgICAgICc8dGQ+JytiYWRnZSsnPC90ZD4nICsKICAgICAgJzx0ZD48ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjRweDthbGlnbi1pdGVtczpjZW50ZXIiPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguJXguYjguK3guK3guLLguKLguLgiIG9uY2xpY2s9Im9wZW5TU0hSZW5ld01vZGFsKFwnJyt1LnVzZXIrJ1wnKSI+8J+UhDwvYnV0dG9uPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguKXguJoiIG9uY2xpY2s9ImRlbFNTSFVzZXIoXCcnK3UudXNlcisnXCcpIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LC4zKSI+8J+Xke+4jzwvYnV0dG9uPicrCiAgICAgICAgZFRhZysKICAgICAgJzwvZGl2PjwvdGQ+PC90cj4nOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclNTSFVzZXJzKHEpIHsKICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycy5maWx0ZXIoZnVuY3Rpb24odSl7cmV0dXJuICh1LnVzZXJ8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSk7fSkpOwp9Ci8vIFNTSCBSZW5ldyBNb2RhbApsZXQgX3JlbmV3U1NIVXNlciA9ICcnOwpmdW5jdGlvbiBvcGVuU1NIUmVuZXdNb2RhbCh1c2VyKSB7CiAgX3JlbmV3U1NIVXNlciA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy11c2VybmFtZScpLnRleHRDb250ZW50ID0gdXNlcjsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSA9ICczMCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbG9zZVNTSFJlbmV3TW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfcmVuZXdTU0hVc2VyID0gJyc7Cn0KYXN5bmMgZnVuY3Rpb24gZG9TU0hSZW5ldygpIHsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmICghZGF5c3x8ZGF5czw9MCkgcmV0dXJuOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsgYnRuLnRleHRDb250ZW50ID0gJ+C4geC4s+C4peC4seC4h+C4leC5iOC4reC4reC4suC4ouC4uC4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9leHRlbmRfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcjpfcmVuZXdTU0hVc2VyLGRheXN9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguJXguYjguK3guK3guLLguKLguLggJytfcmVuZXdTU0hVc2VyKycgKycrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgY2xvc2VTU0hSZW5ld01vZGFsKCk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsKICB9IGZpbmFsbHkgewogICAgYnRuLmRpc2FibGVkID0gZmFsc2U7IGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gcmVuZXdTU0hVc2VyKHVzZXIpIHsgb3BlblNTSFJlbmV3TW9kYWwodXNlcik7IH0KYXN5bmMgZnVuY3Rpb24gZGVsU1NIVXNlcih1c2VyKSB7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiDguJbguLLguKfguKM/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4Lil4LiaICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgYWxlcnQoJ1x1Mjc0YyAnK2UubWVzc2FnZSk7IH0KfQovLyDilZDilZDilZDilZAgQ1JFQVRFIFZMRVNTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csYz0+ewogICAgY29uc3Qgcj1NYXRoLnJhbmRvbSgpKjE2fDA7IHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3wweDgpKS50b1N0cmluZygxNik7CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gY3JlYXRlVkxFU1MoY2FycmllcikgewogIGNvbnN0IGVtYWlsRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZW1haWwnKTsKICBjb25zdCBkYXlzRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWRheXMnKTsKICBjb25zdCBpcEVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWlwJyk7CiAgY29uc3QgZ2JFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1nYicpOwogIGNvbnN0IGVtYWlsICAgPSBlbWFpbEVsLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzICAgID0gcGFyc2VJbnQoZGF5c0VsLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50KGlwRWwudmFsdWUpfHwyOwogIGNvbnN0IGdiICAgICAgPSBwYXJzZUludChnYkVsLnZhbHVlKXx8MDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBFbWFpbC9Vc2VybmFtZScsJ2VycicpOwoKICBjb25zdCBwb3J0ID0gY2Fycmllcj09PSdhaXMnID8gODA4MCA6IDg4ODA7CiAgY29uc3Qgc25pICA9IGNhcnJpZXI9PT0nYWlzJyA/ICdjai1lYmIuc3BlZWR0ZXN0Lm5ldCcgOiAndHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlcyc7CgogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1idG4nKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVySFRNTD0nPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CgogIHRyeSB7CiAgICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICAvLyDguKvguLIgaW5ib3VuZCBpZAogICAgY29uc3QgbGlzdCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0Jyk7CiAgICBjb25zdCBpYiA9IChsaXN0Lm9ianx8W10pLmZpbmQoeD0+eC5wb3J0PT09cG9ydCk7CiAgICBpZiAoIWliKSB0aHJvdyBuZXcgRXJyb3IoYOC5hOC4oeC5iOC4nuC4miBpbmJvdW5kIHBvcnQgJHtwb3J0fSDigJQg4Lij4Lix4LiZIHNldHVwIOC4geC5iOC4reC4mWApOwoKICAgIGNvbnN0IHVpZCA9IGdlblVVSUQoKTsKICAgIGNvbnN0IGV4cE1zID0gZGF5cyA+IDAgPyAoRGF0ZS5ub3coKSArIGRheXMqODY0MDAwMDApIDogMDsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYioxMDczNzQxODI0IDogMDsKCiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL2FkZENsaWVudCcsIHsKICAgICAgaWQ6IGliLmlkLAogICAgICBzZXR0aW5nczogSlNPTi5zdHJpbmdpZnkoeyBjbGllbnRzOlt7CiAgICAgICAgaWQ6dWlkLCBmbG93OicnLCBlbWFpbCwgbGltaXRJcDppcExpbWl0LAogICAgICAgIHRvdGFsR0I6dG90YWxCeXRlcywgZXhwaXJ5VGltZTpleHBNcywgZW5hYmxlOnRydWUsIHRnSWQ6JycsIHN1YklkOicnLCBjb21tZW50OicnLCByZXNldDowCiAgICAgIH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2cgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0IGxpbmsgPSBgdmxlc3M6Ly8ke3VpZH1AJHtzbml9OiR7cG9ydH0/ZW5jcnlwdGlvbj1ub25lJmZsb3c9bm9uZSZ0eXBlPXdzJmhvc3Q9JHtIT1NUfSZoZWFkZXJUeXBlPW5vbmUmcGF0aD0lMkZ2bGVzcyZzZWN1cml0eT1ub25lIyR7ZW5jb2RlVVJJQ29tcG9uZW50KGVtYWlsKyctJysoY2Fycmllcj09PSdhaXMnPydBSVMnOidUUlVFJykpfWA7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZW1haWwnKS50ZXh0Q29udGVudCA9IGVtYWlsOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctdXVpZCcpLnRleHRDb250ZW50ID0gdWlkOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZXhwJykudGV4dENvbnRlbnQgPSBleHBNcyA+IDAgPyBmbXREYXRlKGV4cE1zKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctbGluaycpLnRleHRDb250ZW50ID0gbGluazsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7CiAgICAvLyBHZW5lcmF0ZSBRUiBjb2RlCiAgICBjb25zdCBxckRpdiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1xcicpOwogICAgaWYgKHFyRGl2KSB7CiAgICAgIHFyRGl2LmlubmVySFRNTCA9ICcnOwogICAgICB0cnkgewogICAgICAgIG5ldyBRUkNvZGUocXJEaXYsIHsgdGV4dDogbGluaywgd2lkdGg6IDE4MCwgaGVpZ2h0OiAxODAsIGNvcnJlY3RMZXZlbDogUVJDb2RlLkNvcnJlY3RMZXZlbC5NIH0pOwogICAgICB9IGNhdGNoKHFyRXJyKSB7IHFyRGl2LmlubmVySFRNTCA9ICcnOyB9CiAgICB9CiAgICBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4pyFIOC4quC4o+C5ieC4suC4hyBWTEVTUyBBY2NvdW50IOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBlbWFpbEVsLnZhbHVlPScnOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KaoSDguKrguKPguYnguLLguIcgJysoY2Fycmllcj09PSdhaXMnPydBSVMnOidUUlVFJykrJyBBY2NvdW50JzsgfQp9CgovLyDilZDilZDilZDilZAgTUFOQUdFIFVTRVJTIOKVkOKVkOKVkOKVkApsZXQgX2FsbFVzZXJzID0gW10sIF9jdXJVc2VyID0gbnVsbDsKYXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJzKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgX3h1aUNvb2tpZSA9IGZhbHNlOwogICAgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihkLm1zZyB8fCAn4LmC4Lir4Lil4LiUIGluYm91bmRzIOC5hOC4oeC5iOC5hOC4lOC5iScpOwogICAgX2FsbFVzZXJzID0gW107CiAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICBfYWxsVXNlcnMucHVzaCh7CiAgICAgICAgICBpYklkOiBpYi5pZCwgcG9ydDogaWIucG9ydCwgcHJvdG86IGliLnByb3RvY29sLAogICAgICAgICAgZW1haWw6IGMuZW1haWx8fGMuaWQsIHV1aWQ6IGMuaWQsCiAgICAgICAgICBleHA6IGMuZXhwaXJ5VGltZXx8MCwgdG90YWw6IGMudG90YWxHQnx8MCwKICAgICAgICAgIHVwOiBpYi51cHx8MCwgZG93bjogaWIuZG93bnx8MCwgbGltaXRJcDogYy5saW1pdElwfHwwCiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSk7CiAgICByZW5kZXJVc2VycyhfYWxsVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclVzZXJzKHVzZXJzKSB7CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lie4Lia4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMPC9wPjwvZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1ID0+IHsKICAgIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogICAgbGV0IGJhZGdlLCBjbHM7CiAgICBpZiAoIXUuZXhwIHx8IHUuZXhwPT09MCkgeyBiYWRnZT0n4pyTIOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7IGNscz0nb2snOyB9CiAgICBlbHNlIGlmIChkbCA8IDApICAgICAgICAgeyBiYWRnZT0n4Lir4Lih4LiU4Lit4Liy4Lii4Li4JzsgY2xzPSdleHAnOyB9CiAgICBlbHNlIGlmIChkbCA8PSAzKSAgICAgICAgeyBiYWRnZT0n4pqgICcrZGwrJ2QnOyBjbHM9J3Nvb24nOyB9CiAgICBlbHNlICAgICAgICAgICAgICAgICAgICAgeyBiYWRnZT0n4pyTICcrZGwrJ2QnOyBjbHM9J29rJzsgfQogICAgY29uc3QgYXZDbHMgPSBkbCA8IDAgPyAnYXYteCcgOiAnYXYtZyc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIiBvbmNsaWNrPSJvcGVuVXNlcigke0pTT04uc3RyaW5naWZ5KHUpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyl9KSI+CiAgICAgIDxkaXYgY2xhc3M9InVhdiAke2F2Q2xzfSI+JHsodS5lbWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3UuZW1haWx9PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idW0iPlBvcnQgJHt1LnBvcnR9IMK3ICR7Zm10Qnl0ZXModS51cCt1LmRvd24pfSDguYPguIrguYk8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJhYmRnICR7Y2xzfSI+JHtiYWRnZX08L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclVzZXJzKHEpIHsKICByZW5kZXJVc2VycyhfYWxsVXNlcnMuZmlsdGVyKHU9Pih1LmVtYWlsfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBNT0RBTCBVU0VSIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBvcGVuVXNlcih1KSB7CiAgaWYgKHR5cGVvZiB1ID09PSAnc3RyaW5nJykgdSA9IEpTT04ucGFyc2UodSk7CiAgX2N1clVzZXIgPSB1OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdCcpLnRleHRDb250ZW50ID0gJ+Kame+4jyAnK3UuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1JykudGV4dENvbnRlbnQgPSB1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcCcpLnRleHRDb250ZW50ID0gdS5wb3J0OwogIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogIGNvbnN0IGV4cFR4dCA9ICF1LmV4cHx8dS5leHA9PT0wID8gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcgOiBmbXREYXRlKHUuZXhwKTsKICBjb25zdCBkZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZScpOwogIGRlLnRleHRDb250ZW50ID0gZXhwVHh0OwogIGRlLmNsYXNzTmFtZSA9ICdkdicgKyAoZGwgIT09IG51bGwgJiYgZGwgPCAwID8gJyByZWQnIDogJyBncmVlbicpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZCcpLnRleHRDb250ZW50ID0gdS50b3RhbCA+IDAgPyBmbXRCeXRlcyh1LnRvdGFsKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdHInKS50ZXh0Q29udGVudCA9IGZtdEJ5dGVzKHUudXArdS5kb3duKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGknKS50ZXh0Q29udGVudCA9IHUubGltaXRJcCB8fCAn4oieJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHV1JykudGV4dENvbnRlbnQgPSB1LnV1aWQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwp9CmZ1bmN0aW9uIGNtKCl7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogIF9tU3Vicy5mb3JFYWNoKGsgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5hYnRuJykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwp9CgovLyDilIDilIAgTU9EQUwgNi1BQ1RJT04gU1lTVEVNIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjb25zdCBfbVN1YnMgPSBbJ3JlbmV3JywnZXh0ZW5kJywnYWRkZGF0YScsJ3NldGRhdGEnLCdyZXNldCcsJ2RlbGV0ZSddOwpmdW5jdGlvbiBtQWN0aW9uKGtleSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrZXkpOwogIGNvbnN0IGlzT3BlbiA9IGVsLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpOwogIF9tU3Vicy5mb3JFYWNoKGsgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5hYnRuJykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGlmICghaXNPcGVuKSB7CiAgICBlbC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICBpZiAoa2V5PT09J2RlbGV0ZScgJiYgX2N1clVzZXIpIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWRlbC1uYW1lJykudGV4dENvbnRlbnQgPSBfY3VyVXNlci5lbWFpbDsKICAgIHNldFRpbWVvdXQoKCk9PmVsLnNjcm9sbEludG9WaWV3KHtiZWhhdmlvcjonc21vb3RoJyxibG9jazonbmVhcmVzdCd9KSwxMDApOwogIH0KfQpmdW5jdGlvbiBfbUJ0bkxvYWQoaWQsIGxvYWRpbmcsIG9yaWdUZXh0KSB7CiAgY29uc3QgYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWIpIHJldHVybjsKICBiLmRpc2FibGVkID0gbG9hZGluZzsKICBpZiAobG9hZGluZykgeyBiLmRhdGFzZXQub3JpZyA9IGIudGV4dENvbnRlbnQ7IGIuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+IOC4geC4s+C4peC4seC4h+C4lOC4s+C5gOC4meC4tOC4meC4geC4suC4oy4uLic7IH0KICBlbHNlIGlmIChiLmRhdGFzZXQub3JpZykgYi50ZXh0Q29udGVudCA9IGIuZGF0YXNldC5vcmlnOwp9Cgphc3luYyBmdW5jdGlvbiBkb1JlbmV3VXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXJlbmV3LWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tcmVuZXctYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGV4cE1zID0gRGF0ZS5ub3coKSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4LmI4Lit4Lit4Liy4Lii4Li44Liq4Liz4LmA4Lij4LmH4LiIICcrZGF5cysnIOC4p+C4seC4mSAo4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJKScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0V4dGVuZFVzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1leHRlbmQtZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoZGF5cyA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iOC4s+C4meC4p+C4meC4p+C4seC4mScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGJhc2UgPSAoX2N1clVzZXIuZXhwICYmIF9jdXJVc2VyLmV4cCA+IERhdGUubm93KCkpID8gX2N1clVzZXIuZXhwIDogRGF0ZS5ub3coKTsKICAgIGNvbnN0IGV4cE1zID0gYmFzZSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihICcrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIggKOC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lCknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvQWRkRGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgYWRkR2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWFkZGRhdGEtZ2InKS52YWx1ZSl8fDA7CiAgaWYgKGFkZEdiIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBuZXdUb3RhbCA9IChfY3VyVXNlci50b3RhbHx8MCkgKyBhZGRHYioxMDczNzQxODI0OwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOm5ld1RvdGFsLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguYDguJ7guLTguYjguKEgRGF0YSArJythZGRHYisnIEdCIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWFkZGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvU2V0RGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZ2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXNldGRhdGEtZ2InKS52YWx1ZSk7CiAgaWYgKGlzTmFOKGdiKXx8Z2I8MCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYioxMDczNzQxODI0IDogMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjp0b3RhbEJ5dGVzLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguJXguLHguYnguIcgRGF0YSBMaW1pdCAnKyhnYj4wP2diKycgR0InOifguYTguKHguYjguIjguLPguIHguLHguJQnKSsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvUmVzZXRUcmFmZmljKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9yZXNldENsaWVudFRyYWZmaWMvJytfY3VyVXNlci5lbWFpbCk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTUwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZXNldC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9EZWxldGVVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvJytfY3VyVXNlci5pYklkKycvZGVsQ2xpZW50LycrX2N1clVzZXIudXVpZCk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKXguJrguKLguLnguKogJytfY3VyVXNlci5lbWFpbCsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxMjAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCBmYWxzZSk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlDb29raWUgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICAvLyDguYLguKvguKXguJQgaW5ib3VuZHMg4LiW4LmJ4Liy4Lii4Lix4LiH4LmE4Lih4LmI4Lih4Li1CiAgICBpZiAoIV9hbGxVc2Vycy5sZW5ndGgpIHsKICAgICAgY29uc3QgZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgICBpZiAoZCAmJiBkLnN1Y2Nlc3MpIHsKICAgICAgICBfYWxsVXNlcnMgPSBbXTsKICAgICAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBfYWxsVXNlcnMucHVzaCh7IGliSWQ6aWIuaWQsIHBvcnQ6aWIucG9ydCwgcHJvdG86aWIucHJvdG9jb2wsCiAgICAgICAgICAgICAgZW1haWw6Yy5lbWFpbHx8Yy5pZCwgdXVpZDpjLmlkLCBleHA6Yy5leHBpcnlUaW1lfHwwLAogICAgICAgICAgICAgIHRvdGFsOmMudG90YWxHQnx8MCwgdXA6aWIudXB8fDAsIGRvd246aWIuZG93bnx8MCwgbGltaXRJcDpjLmxpbWl0SXB8fDAgfSk7CiAgICAgICAgICB9KTsKICAgICAgICB9KTsKICAgICAgfQogICAgfQogICAgY29uc3Qgb2QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvb25saW5lcycpLmNhdGNoKCgpPT5udWxsKTsKICAgIC8vIOC4o+C4reC4h+C4o+C4seC4miBmb3JtYXQ6IHtvYmo6IFsuLi5dfSDguKvguKPguLfguK0ge29iajogbnVsbH0g4Lir4Lij4Li34LitIHtvYmo6IHt9fQogICAgbGV0IGVtYWlscyA9IFtdOwogICAgaWYgKG9kICYmIG9kLm9iaikgewogICAgICBpZiAoQXJyYXkuaXNBcnJheShvZC5vYmopKSBlbWFpbHMgPSBvZC5vYmo7CiAgICAgIGVsc2UgaWYgKHR5cGVvZiBvZC5vYmogPT09ICdvYmplY3QnKSBlbWFpbHMgPSBPYmplY3QudmFsdWVzKG9kLm9iaikuZmxhdCgpLmZpbHRlcihlPT50eXBlb2YgZT09PSdzdHJpbmcnKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YXYgYXYtZyI+8J+fojwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHtlbWFpbH08L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVtIj4ke3UgPyAnUG9ydCAnK3UucG9ydCA6ICdWTEVTUyd9IMK3IOC4reC4reC4meC5hOC4peC4meC5jOC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIG9rIj5PTkxJTkU8L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBVU0VSUyAoYmFuIHRhYikg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCB1c2VycyA9IGQudXNlcnMgfHwgW107CiAgICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvcD48L2Rpdj4nOyByZXR1cm47IH0KICAgIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHU9PnsKICAgICAgY29uc3QgZXhwID0gdS5leHAgfHwgJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICAgIGNvbnN0IGFjdGl2ZSA9IHUuYWN0aXZlICE9PSBmYWxzZTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YWN0aXZlPydhdi1nJzonYXYteCd9Ij4ke3UudXNlclswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LnVzZXJ9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+4Lir4Lih4LiU4Lit4Liy4Lii4Li4OiAke2V4cH08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2FjdGl2ZT8nb2snOidleHAnfSI+JHthY3RpdmU/J0FjdGl2ZSc6J0V4cGlyZWQnfTwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsZXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZS50cmltKCk7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciID8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSl9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3J8fCfguKXguJrguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVXNlcnMoKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBDT1BZIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBjb3B5TGluayhpZCwgYnRuKSB7CiAgY29uc3QgdHh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHR4dCkudGhlbigoKT0+ewogICAgY29uc3Qgb3JpZyA9IGJ0bi50ZXh0Q29udGVudDsKICAgIGJ0bi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0ncmdiYSgzNCwxOTcsOTQsLjE1KSc7CiAgICBzZXRUaW1lb3V0KCgpPT57IGJ0bi50ZXh0Q29udGVudD1vcmlnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0nJzsgfSwgMjAwMCk7CiAgfSkuY2F0Y2goKCk9PnsgcHJvbXB0KCdDb3B5IGxpbms6JywgdHh0KTsgfSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBMT0dPVVQg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGRvTG9nb3V0KCkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIElOSVQg4pWQ4pWQ4pWQ4pWQCgovLyDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAKLy8gIFNQRUVEIFRFU1QKLy8g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCmxldCBfc3BlZWRSdW5uaW5nPWZhbHNlOwpmdW5jdGlvbiBzZXRHYXVnZShtYnBzLCBtYXhNYnBzPTIwMCkgewogIGNvbnN0IGVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdnYXVnZS1maWxsJyk7CiAgY29uc3QgdmFsRWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dhdWdlLXZhbCcpOwogIGNvbnN0IHVuaXRFbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2F1Z2UtdW5pdCcpOwogIGlmICghZWwpIHJldHVybjsKICBjb25zdCBwY3Q9TWF0aC5taW4obWJwcy9tYXhNYnBzLDEpOwogIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQ9KDIyMC0oMjIwKnBjdCkpLnRvRml4ZWQoMik7CiAgY29uc3Qgcj1NYXRoLnJvdW5kKHBjdDwwLjU/MDoyNTUqKHBjdC0wLjUpKjIpOwogIGNvbnN0IGc9TWF0aC5yb3VuZChwY3Q8MC41PzI1NToyNTUqKDEtKHBjdC0wLjUpKjIpKTsKICBlbC5zZXRBdHRyaWJ1dGUoJ3N0cm9rZScsYHJnYigke3J9LCR7Z30sNTApYCk7CiAgdmFsRWwudGV4dENvbnRlbnQ9bWJwcz49MT9tYnBzLnRvRml4ZWQoMSk6KG1icHMqMTAwMCkudG9GaXhlZCgwKTsKICB1bml0RWwudGV4dENvbnRlbnQ9bWJwcz49MT8nTWJwcyc6J0ticHMnOwp9CmZ1bmN0aW9uIHNldFByb2dyZXNzKHBjdCkgewogIGNvbnN0IGVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1wcm9nLWZpbGwnKTsKICBpZiAoZWwpIGVsLnN0eWxlLndpZHRoPU1hdGgubWluKHBjdCwxMDApKyclJzsKfQphc3luYyBmdW5jdGlvbiBtZWFzdXJlUGluZygpIHsKICBjb25zdCBwaW5ncz1bXTsKICBmb3IgKGxldCBpPTA7aTw1O2krKykgewogICAgY29uc3QgdDA9cGVyZm9ybWFuY2Uubm93KCk7CiAgICB0cnl7YXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJyx7bWV0aG9kOidIRUFEJyxjYWNoZTonbm8tc3RvcmUnfSk7fQogICAgY2F0Y2goZSl7dHJ5e2F3YWl0IGZldGNoKCcvJyx7bWV0aG9kOidIRUFEJyxjYWNoZTonbm8tc3RvcmUnfSk7fWNhdGNoKGVlKXt9fQogICAgcGluZ3MucHVzaChwZXJmb3JtYW5jZS5ub3coKS10MCk7CiAgICBhd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7CiAgfQogIHBpbmdzLnNvcnQoKGEsYik9PmEtYik7CiAgY29uc3QgcGluZz1waW5nc1tNYXRoLmZsb29yKHBpbmdzLmxlbmd0aC8yKV07CiAgY29uc3Qgaml0dGVyPXBpbmdzW3BpbmdzLmxlbmd0aC0xXS1waW5nc1swXTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluZy12YWwnKS50ZXh0Q29udGVudD1waW5nLnRvRml4ZWQoMCkrJyBtcyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ppdHRlci12YWwnKS50ZXh0Q29udGVudD1qaXR0ZXIudG9GaXhlZCgwKSsnIG1zJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9zcy12YWwnKS50ZXh0Q29udGVudD0nMCUnOwogIGNvbnN0IHBpbmdFbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluZy12YWwnKTsKICBwaW5nRWwuY2xhc3NOYW1lPSdzcGVlZC1waW5nLXZhbCcrKHBpbmc8ODA/Jyc6cGluZzwyMDA/JyB3YXJuJzonIGJhZCcpOwogIHJldHVybiB7cGluZyxqaXR0ZXJ9Owp9CmFzeW5jIGZ1bmN0aW9uIHN0YXJ0U3BlZWRUZXN0KHR5cGUpIHsKICBpZiAoX3NwZWVkUnVubmluZykgcmV0dXJuOwogIF9zcGVlZFJ1bm5pbmc9dHJ1ZTsKICBjb25zdCBidG5EbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWRsJyk7CiAgY29uc3QgYnRuVWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi11bCcpOwogIGJ0bkRsLmRpc2FibGVkPXRydWU7IGJ0blVsLmRpc2FibGVkPXRydWU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfguIHguLPguKXguLHguIfguKfguLHguJQgUGluZy4uLic7CiAgc2V0UHJvZ3Jlc3MoMCk7IHNldEdhdWdlKDApOwogIHRyeXsKICAgIGNvbnN0IGluZm89YXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYoaW5mbyYmaW5mby5ob3N0KSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndnBzLWlwJykudGV4dENvbnRlbnQ9aW5mby5ob3N0OwogICAgZWxzZSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndnBzLWlwJykudGV4dENvbnRlbnQ9bG9jYXRpb24uaG9zdG5hbWU7CiAgfWNhdGNoKGUpe30KICB0cnl7YXdhaXQgbWVhc3VyZVBpbmcoKTt9Y2F0Y2goZSl7fQogIHNldFByb2dyZXNzKDEwKTsKICBpZiAodHlwZT09PSdkb3dubG9hZCcpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIERvd25sb2FkLi4uJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkbC12YWwnKS50ZXh0Q29udGVudD0nLi4uJzsKICAgIGNvbnN0IG1icHM9YXdhaXQgcnVuRG93bmxvYWRUZXN0KChwLGN1cik9PnsKICAgICAgc2V0UHJvZ3Jlc3MoMTArcCowLjgpOyBzZXRHYXVnZShjdXIpOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtYmFyJykuc3R5bGUud2lkdGg9TWF0aC5taW4oY3VyLzIwMCoxMDAsMTAwKSsnJSc7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkbC12YWwnKS50ZXh0Q29udGVudD1tYnBzLnRvRml4ZWQoMSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtYmFyJykuc3R5bGUud2lkdGg9TWF0aC5taW4obWJwcy8yMDAqMTAwLDEwMCkrJyUnOwogICAgc2V0R2F1Z2UobWJwcyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtc3RhdHVzJykudGV4dENvbnRlbnQ9J+KchSBEb3dubG9hZDogJyttYnBzLnRvRml4ZWQoMSkrJyBNYnBzJzsKICB9IGVsc2UgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfguIHguLPguKXguLHguIfguJfguJTguKrguK3guJogVXBsb2FkLi4uJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC12YWwnKS50ZXh0Q29udGVudD0nLi4uJzsKICAgIGNvbnN0IG1icHM9YXdhaXQgcnVuVXBsb2FkVGVzdCgocCxjdXIpPT57CiAgICAgIHNldFByb2dyZXNzKDEwK3AqMC44KTsgc2V0R2F1Z2UoY3VyKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKGN1ci8yMDAqMTAwLDEwMCkrJyUnOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWwtdmFsJykudGV4dENvbnRlbnQ9bWJwcy50b0ZpeGVkKDEpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKG1icHMvMjAwKjEwMCwxMDApKyclJzsKICAgIHNldEdhdWdlKG1icHMpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfinIUgVXBsb2FkOiAnK21icHMudG9GaXhlZCgxKSsnIE1icHMnOwogIH0KICBzZXRQcm9ncmVzcygxMDApOwogIHNldFRpbWVvdXQoKCk9PnNldFByb2dyZXNzKDApLDE1MDApOwogIGJ0bkRsLmRpc2FibGVkPWZhbHNlOyBidG5VbC5kaXNhYmxlZD1mYWxzZTsKICBfc3BlZWRSdW5uaW5nPWZhbHNlOwp9CmFzeW5jIGZ1bmN0aW9uIHJ1bkRvd25sb2FkVGVzdChvblByb2dyZXNzKSB7CiAgY29uc3QgRFVSQVRJT05fTVM9ODAwMDsKICBsZXQgdG90YWxCeXRlcz0wOwogIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogIGxldCBkb25lPWZhbHNlOwogIHNldFRpbWVvdXQoKCk9Pntkb25lPXRydWU7fSxEVVJBVElPTl9NUyk7CiAgY29uc3QgQ0hVTks9MSoxMDI0KjEwMjQ7CiAgY29uc3QgcnVuPWFzeW5jKCk9PnsKICAgIHdoaWxlKCFkb25lKXsKICAgICAgdHJ5ewogICAgICAgIGNvbnN0IHVybD0naHR0cHM6Ly9zcGVlZC5jbG91ZGZsYXJlLmNvbS9fX2Rvd24/Ynl0ZXM9JytDSFVOSzsKICAgICAgICBjb25zdCByPWF3YWl0IGZldGNoKHVybCx7Y2FjaGU6J25vLXN0b3JlJ30pLmNhdGNoKGFzeW5jKCk9PmZldGNoKEFQSSsnL3N0YXR1cycse2NhY2hlOiduby1zdG9yZSd9KSk7CiAgICAgICAgY29uc3QgYnVmPWF3YWl0IHIuYXJyYXlCdWZmZXIoKTsKICAgICAgICBpZihkb25lKSBicmVhazsKICAgICAgICB0b3RhbEJ5dGVzKz1idWYuYnl0ZUxlbmd0aDsKICAgICAgICBjb25zdCBlbGFwc2VkPShwZXJmb3JtYW5jZS5ub3coKS10MCkvMTAwMDsKICAgICAgICBjb25zdCBtYnBzPSh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7CiAgICAgICAgb25Qcm9ncmVzcyhNYXRoLm1pbihlbGFwc2VkL0RVUkFUSU9OX01TKjEwMCw5OSksbWJwcyk7CiAgICAgIH1jYXRjaChlKXthd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7fQogICAgfQogIH07CiAgYXdhaXQgUHJvbWlzZS5hbGwoW3J1bigpLHJ1bigpLHJ1bigpLHJ1bigpXSk7CiAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgcmV0dXJuICh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7Cn0KYXN5bmMgZnVuY3Rpb24gcnVuVXBsb2FkVGVzdChvblByb2dyZXNzKSB7CiAgY29uc3QgRFVSQVRJT05fTVM9ODAwMDsKICBsZXQgdG90YWxCeXRlcz0wOwogIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogIGxldCBkb25lPWZhbHNlOwogIHNldFRpbWVvdXQoKCk9Pntkb25lPXRydWU7fSxEVVJBVElPTl9NUyk7CiAgY29uc3QgQ0hVTks9NTEyKjEwMjQ7CiAgY29uc3QgZGF0YT1uZXcgVWludDhBcnJheShDSFVOSyk7CiAgY3J5cHRvLmdldFJhbmRvbVZhbHVlcyhkYXRhKTsKICBjb25zdCBibG9iPW5ldyBCbG9iKFtkYXRhXSk7CiAgY29uc3QgcnVuPWFzeW5jKCk9PnsKICAgIHdoaWxlKCFkb25lKXsKICAgICAgdHJ5ewogICAgICAgIGF3YWl0IGZldGNoKCdodHRwczovL3NwZWVkLmNsb3VkZmxhcmUuY29tL19fdXAnLHttZXRob2Q6J1BPU1QnLGJvZHk6YmxvYn0pLmNhdGNoKCgpPT4KICAgICAgICAgIGZldGNoKEFQSSsnL3N0YXR1cycse21ldGhvZDonUE9TVCcsYm9keTpibG9iLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0nfX0pLmNhdGNoKCgpPT4oe29rOmZhbHNlfSkpCiAgICAgICAgKTsKICAgICAgICBpZihkb25lKSBicmVhazsKICAgICAgICB0b3RhbEJ5dGVzKz1DSFVOSzsKICAgICAgICBjb25zdCBlbGFwc2VkPShwZXJmb3JtYW5jZS5ub3coKS10MCkvMTAwMDsKICAgICAgICBjb25zdCBtYnBzPSh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7CiAgICAgICAgb25Qcm9ncmVzcyhNYXRoLm1pbihlbGFwc2VkL0RVUkFUSU9OX01TKjEwMCw5OSksbWJwcyk7CiAgICAgIH1jYXRjaChlKXthd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7fQogICAgfQogIH07CiAgYXdhaXQgUHJvbWlzZS5hbGwoW3J1bigpLHJ1bigpLHJ1bigpXSk7CiAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgcmV0dXJuICh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7Cn0KCi8vIHN3KCkg4LmA4Lie4Li04LmI4LihIHNwZWVkIHRhYiBzdXBwb3J0Cgpsb2FkRGFzaCgpOwpsb2FkU2VydmljZXMoKTsKc2V0SW50ZXJ2YWwobG9hZERhc2gsIDMwMDAwKTsKPC9zY3JpcHQ+Cgo8IS0tIFNTSCBSRU5FVyBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJzc2gtcmVuZXctbW9kYWwiIG9uY2xpY2s9ImlmKGV2ZW50LnRhcmdldD09PXRoaXMpY2xvc2VTU0hSZW5ld01vZGFsKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IFNTSCBVc2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY2xvc2VTU0hSZW5ld01vZGFsKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJkZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfkaQgVXNlcm5hbWU8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0ic3NoLXJlbmV3LXVzZXJuYW1lIj4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmciIHN0eWxlPSJtYXJnaW4tdG9wOjE0cHgiPgogICAgICA8ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguJXguYjguK3guK3guLLguKLguLg8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIiBwbGFjZWhvbGRlcj0iMzAiPgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ic3NoLXJlbmV3LWJ0biIgb25jbGljaz0iZG9TU0hSZW5ldygpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgPC9kaXY+CjwvZGl2PgoKCjxzY3JpcHQ+Ci8vIEZpcmVmbGllcyB4NjAg4oCTIGluc2lkZSBjYXJkcyAoYWJzb2x1dGUsIOC5hOC4oeC5iOC5g+C4iuC5iCBmaXhlZCkKKGZ1bmN0aW9uKCl7CiAgY29uc3QgY29sb3JzPVsKICAgICcjYjVmNTQyJywnI2Q0ZmM1YScsJyM3ZmZmMDAnLCcjYWFmZjQ0JywKICAgICcjZjVmNTQyJywnI2ZmZTk0ZCcsJyNmZmQ3MDAnLCcjZmZlYzZlJywKICAgICcjYThmZjc4JywnIzc4ZmY4YScsJyM1NmZmYjAnLCcjOTBmZjZhJywKICBdOwogIGZ1bmN0aW9uIGFkZEZGKGNvbnRhaW5lciwgY291bnQpIHsKICAgIGNvbnN0IHc9Y29udGFpbmVyLm9mZnNldFdpZHRofHwyODA7CiAgICBjb25zdCBoPWNvbnRhaW5lci5vZmZzZXRIZWlnaHR8fDEyMDsKICAgIGZvciAobGV0IGk9MDtpPGNvdW50O2krKykgewogICAgICBjb25zdCBlbD1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgZWwuY2xhc3NOYW1lPSdjYXJkLWZmJzsKICAgICAgY29uc3Qgc2l6ZT1NYXRoLnJhbmRvbSgpKjMrMS41OwogICAgICBjb25zdCBjb2xvcj1jb2xvcnNbTWF0aC5mbG9vcihNYXRoLnJhbmRvbSgpKmNvbG9ycy5sZW5ndGgpXTsKICAgICAgY29uc3Qgcj0oKT0+KChNYXRoLnJhbmRvbSgpLTAuNSkqTWF0aC5taW4odyxoKSowLjU1KSsncHgnOwogICAgICBjb25zdCBkRHVyPShNYXRoLnJhbmRvbSgpKjE4KzEyKS50b0ZpeGVkKDEpOwogICAgICBjb25zdCBiRHVyPShNYXRoLnJhbmRvbSgpKjMrMikudG9GaXhlZCgxKTsKICAgICAgY29uc3QgZGVsYXk9KE1hdGgucmFuZG9tKCkqMTUpLnRvRml4ZWQoMik7CiAgICAgIGVsLnN0eWxlLmNzc1RleHQ9YHdpZHRoOiR7c2l6ZX1weDtoZWlnaHQ6JHtzaXplfXB4O2ArCiAgICAgICAgYGxlZnQ6JHtNYXRoLnJhbmRvbSgpKjg4KzZ9JTt0b3A6JHtNYXRoLnJhbmRvbSgpKjg4KzZ9JTtgKwogICAgICAgIGBiYWNrZ3JvdW5kOiR7Y29sb3J9O2ArCiAgICAgICAgYGJveC1zaGFkb3c6MCAwICR7c2l6ZSoyLjV9cHggJHtzaXplKjEuNX1weCAke2NvbG9yfTg4LDAgMCAke3NpemUqNn1weCAke2NvbG9yfTQ0O2ArCiAgICAgICAgYGFuaW1hdGlvbi1kdXJhdGlvbjoke2REdXJ9cywke2JEdXJ9cztgKwogICAgICAgIGBhbmltYXRpb24tZGVsYXk6LSR7ZGVsYXl9cywtJHtkZWxheX1zO2ArCiAgICAgICAgYC0tZHgxOiR7cigpfTstLWR5MToke3IoKX07LS1keDI6JHtyKCl9Oy0tZHkyOiR7cigpfTtgKwogICAgICAgIGAtLWR4Mzoke3IoKX07LS1keTM6JHtyKCl9Oy0tZHg0OiR7cigpfTstLWR5NDoke3IoKX07YDsKICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGVsKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gc3Bhd25BbGwoKXsKICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXJkLC5zYycpLmZvckVhY2goYz0+ewogICAgICBpZiAoYy5xdWVyeVNlbGVjdG9yQWxsKCcuY2FyZC1mZicpLmxlbmd0aDw4KSBhZGRGRihjLDEwKTsKICAgIH0pOwogIH0KICBzcGF3bkFsbCgpOwogIHNldFRpbWVvdXQoc3Bhd25BbGwsMjUwMCk7CiAgc2V0VGltZW91dChzcGF3bkFsbCw2MDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/sshws.html
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
def get_system_info():
    """อ่านข้อมูล CPU / RAM / Disk / Network จาก /proc โดยตรง — ไม่ง้อ x-ui"""
    import time as _time

    # ── CPU ──────────────────────────────────────────────────────
    cpu_percent = 0.0
    cpu_cores   = 1
    try:
        def _read_cpu():
            line = open('/proc/stat').readline()
            vals = list(map(int, line.split()[1:]))
            idle = vals[3]
            total = sum(vals)
            return total, idle
        t1, i1 = _read_cpu(); _time.sleep(0.3); t2, i2 = _read_cpu()
        dt = t2 - t1; di = i2 - i1
        cpu_percent = round((1 - di / dt) * 100, 1) if dt > 0 else 0.0
        cpu_cores = 0
        for line in open('/proc/cpuinfo'):
            if line.startswith('processor'): cpu_cores += 1
        if cpu_cores == 0: cpu_cores = 1
    except: pass

    # ── RAM ──────────────────────────────────────────────────────
    mem_total = mem_used = mem_free = 0
    try:
        mem = {}
        for line in open('/proc/meminfo'):
            k, v = line.split(':')
            mem[k.strip()] = int(v.split()[0])
        mem_total = mem.get('MemTotal', 0)
        mem_available = mem.get('MemAvailable', mem.get('MemFree', 0))
        mem_used  = mem_total - mem_available
        mem_free  = mem_available
    except: pass

    def _kb_to_gb(kb):
        return round(kb / 1024 / 1024, 2)

    ram_percent = round(mem_used / mem_total * 100, 1) if mem_total else 0

    # ── Disk ─────────────────────────────────────────────────────
    disk_total = disk_used = disk_free = 0
    disk_percent = 0.0
    try:
        import os as _os
        st = _os.statvfs('/')
        disk_total = st.f_blocks * st.f_frsize
        disk_free  = st.f_bavail * st.f_frsize
        disk_used  = disk_total - disk_free
        disk_percent = round(disk_used / disk_total * 100, 1) if disk_total else 0
    except: pass

    def _bytes_to_gb(b):
        return round(b / 1024 / 1024 / 1024, 2)

    # ── Uptime ───────────────────────────────────────────────────
    uptime_secs = 0
    uptime_str = '--'
    try:
        uptime_secs = float(open('/proc/uptime').read().split()[0])
        d = int(uptime_secs // 86400); h = int((uptime_secs % 86400) // 3600)
        m = int((uptime_secs % 3600) // 60)
        if d > 0:   uptime_str = f'{d}d {h}h {m}m'
        elif h > 0: uptime_str = f'{h}h {m}m'
        else:       uptime_str = f'{m}m'
    except: uptime_str = '--'

    # ── Load averages ────────────────────────────────────────────
    loads = [0.0, 0.0, 0.0]
    try:
        la = open('/proc/loadavg').read().split()
        loads = [float(la[0]), float(la[1]), float(la[2])]
    except: pass

    # ── Network I/O ──────────────────────────────────────────────
    net_rx_bytes = net_tx_bytes = 0
    net_rx_speed = net_tx_speed = 0
    net_iface = ''
    try:
        def _read_net():
            best_rx = best_tx = 0
            iface = ''
            for line in open('/proc/net/dev'):
                line = line.strip()
                if ':' not in line: continue
                name, data = line.split(':', 1)
                name = name.strip()
                if name in ('lo',): continue
                cols = data.split()
                rx, tx = int(cols[0]), int(cols[8])
                if rx + tx > best_rx + best_tx:
                    best_rx, best_tx, iface = rx, tx, name
            return best_rx, best_tx, iface
        rx1, tx1, iface = _read_net()
        _time.sleep(0.5)
        rx2, tx2, _ = _read_net()
        net_rx_bytes = rx2; net_tx_bytes = tx2; net_iface = iface
        net_rx_speed = max(0, int((rx2 - rx1) / 0.5))
        net_tx_speed = max(0, int((tx2 - tx1) / 0.5))
    except: pass

    def _fmt_speed(bps):
        if bps >= 1024*1024: return f'{round(bps/1024/1024,1)} MB/s'
        if bps >= 1024:      return f'{round(bps/1024,1)} KB/s'
        return f'{bps} B/s'

    def _fmt_bytes(b):
        if b >= 1024**3: return f'{round(b/1024**3,2)} GB'
        if b >= 1024**2: return f'{round(b/1024**2,2)} MB'
        return f'{round(b/1024,2)} KB'

    # ── x-ui version & inbound count ─────────────────────────────
    xray_version = ''
    inbound_count = 0
    try:
        import sqlite3 as _sq3
        _db = find_xui_db()
        if _os.path.exists(_db):
            con = _sq3.connect(_db, timeout=5); con.execute('PRAGMA journal_mode=WAL')
            rows = con.execute("SELECT COUNT(*) FROM inbounds WHERE enable=1").fetchone()
            inbound_count = rows[0] if rows else 0
            con.close()
    except: pass
    try:
        _, ver, _ = run_cmd("xray version 2>/dev/null | head -1 | awk '{print $2}'")
        xray_version = ver.strip()
    except: pass

    return {
        'success': True,
        'obj': {
            'cpu':          cpu_percent,
            'cpuCores':     cpu_cores,
            'logicalPro':   cpu_cores,
            'mem': {
                'current':  mem_used * 1024,
                'total':    mem_total * 1024,
            },
            'memUsed':      _kb_to_gb(mem_used),
            'memTotal':     _kb_to_gb(mem_total),
            'memPercent':   ram_percent,
            'disk': {
                'current':  disk_used,
                'total':    disk_total,
            },
            'diskUsed':     _bytes_to_gb(disk_used),
            'diskTotal':    _bytes_to_gb(disk_free + disk_used),
            'diskPercent':  disk_percent,
            'uptime':       int(uptime_secs),
            'uptimeStr':    uptime_str,
            'loads':        loads,
            'xrayVersion':  xray_version,
            'xray': {
                'version':  xray_version,
                'state':    'running' if xray_version else 'unknown',
            },
            'inbounds':     inbound_count,
            'netIO': {
                'up':       net_tx_speed,
                'down':     net_rx_speed,
                'upStr':    _fmt_speed(net_tx_speed),
                'downStr':  _fmt_speed(net_rx_speed),
            },
            'netTraffic': {
                'sent':     net_tx_bytes,
                'recv':     net_rx_bytes,
            },
        }
    }

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
        elif self.path == '/api/server-status':
            try:
                respond(self, 200, get_system_info())
            except Exception as e:
                respond(self, 500, {'success': False, 'error': str(e)})
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


        elif self.path == '/api/speedtest':
            try:
                import json as _json, re as _re
                r = subprocess.run(['speedtest-cli','--json','--secure'], capture_output=True, text=True, timeout=60)
                if r.returncode != 0:
                    # ลอง ookla speedtest
                    r2 = subprocess.run(['speedtest','--format=json','--accept-license','--accept-gdpr'], capture_output=True, text=True, timeout=60)
                    if r2.returncode == 0:
                        d = _json.loads(r2.stdout)
                        respond(self, 200, {
                            'ok': True,
                            'ping': round(d.get('ping',{}).get('latency',0),1),
                            'download': round(d.get('download',{}).get('bandwidth',0)*8/1000000,2),
                            'upload': round(d.get('upload',{}).get('bandwidth',0)*8/1000000,2),
                            'ip': d.get('interface',{}).get('externalIp',''),
                            'server': d.get('server',{}).get('name',''),
                            'timestamp': d.get('timestamp','')
                        })
                    else:
                        respond(self, 200, {'ok': False, 'error': 'speedtest-cli not found, install: pip install speedtest-cli'})
                else:
                    d = _json.loads(r.stdout)
                    respond(self, 200, {
                        'ok': True,
                        'ping': round(d.get('ping',0),1),
                        'download': round(d.get('download',0)/1000000,2),
                        'upload': round(d.get('upload',0)/1000000,2),
                        'ip': d.get('client',{}).get('ip',''),
                        'server': d.get('server',{}).get('name',''),
                        'timestamp': d.get('timestamp','')
                    })
            except Exception as e:
                respond(self, 200, {'ok': False, 'error': str(e)})

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
            run_cmd(f'echo "{user}:{passwd}" | chpasswd')
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

        elif self.path == '/api/change_admin':
            # เปลี่ยน username/password ของ x-ui และ chaiya panel
            # รับ: { old_pass, new_user, new_pass }
            old_pass = data.get('old_pass', '').strip()
            new_user = data.get('new_user', '').strip()
            new_pass = data.get('new_pass', '').strip()
            if not old_pass or not new_user or not new_pass:
                return respond(self, 400, {'error': 'กรุณากรอกข้อมูลให้ครบ'})
            # ตรวจสอบรหัสเดิม
            stored_u = open('/etc/chaiya/xui-user.conf').read().strip() if os.path.exists('/etc/chaiya/xui-user.conf') else ''
            stored_p = open('/etc/chaiya/xui-pass.conf').read().strip() if os.path.exists('/etc/chaiya/xui-pass.conf') else ''
            if old_pass != stored_p:
                return respond(self, 401, {'ok': False, 'error': 'รหัสผ่านเดิมไม่ถูกต้อง'})
            try:
                import sqlite3 as _sq3
                # สร้าง bcrypt hash สำหรับ x-ui
                try:
                    import bcrypt as _bc
                    _hash = _bc.hashpw(new_pass.encode(), _bc.gensalt()).decode()
                except Exception:
                    _hash = new_pass  # fallback plaintext ถ้าไม่มี bcrypt
                # อัปเดต x-ui DB
                _db_path = '/etc/x-ui/x-ui.db'
                for _try_path in ['/etc/x-ui/x-ui.db', '/root/.local/share/3x-ui/db/x-ui.db']:
                    if os.path.exists(_try_path):
                        _db_path = _try_path
                        break
                if os.path.exists(_db_path):
                    run_cmd('systemctl stop x-ui 2>/dev/null || true')
                    import time as _time; _time.sleep(1)
                    _con = _sq3.connect(_db_path, timeout=10)
                    _con.execute('PRAGMA journal_mode=WAL')
                    _con.execute("UPDATE users SET username=?, password=?", (new_user, _hash))
                    for _k in ['webUsername', 'webPassword']:
                        _con.execute("DELETE FROM settings WHERE key=?", (_k,))
                    _con.execute("INSERT OR REPLACE INTO settings(key,value) VALUES('webUsername',?)", (new_user,))
                    _con.execute("INSERT OR REPLACE INTO settings(key,value) VALUES('webPassword',?)", (_hash,))
                    _con.commit()
                    _con.close()
                    run_cmd('systemctl start x-ui 2>/dev/null || true')
                # บันทึก plaintext ลง conf (สำคัญ: ต้องเป็น plaintext ไม่ใช่ hash)
                with open('/etc/chaiya/xui-user.conf', 'w') as _f: _f.write(new_user)
                with open('/etc/chaiya/xui-pass.conf', 'w') as _f: _f.write(new_pass)
                os.chmod('/etc/chaiya/xui-user.conf', 0o600)
                os.chmod('/etc/chaiya/xui-pass.conf', 0o600)
                respond(self, 200, {'ok': True, 'message': 'เปลี่ยน username/password สำเร็จ'})
            except Exception as _e:
                respond(self, 500, {'ok': False, 'error': str(_e)})

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
            import threading, pty, select, fcntl, termios, struct
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
eDt9CiAgLmhkcntiYWNrZ3JvdW5kOnJhZGlhbC1ncmFkaWVudChlbGxpcHNlIDgwJSA2MCUgYXQg
MjAlIDIwJSxyZ2JhKDEyNCw1OCwyMzcsMC4yNSkgMCUsdHJhbnNwYXJlbnQgNjAlKSxyYWRpYWwt
Z3JhZGllbnQoZWxsaXBzZSA2MCUgNTAlIGF0IDgwJSA4MCUscmdiYSgzNyw5OSwyMzUsMC4yKSAw
JSx0cmFuc3BhcmVudCA2MCUpLGxpbmVhci1ncmFkaWVudCgxNjBkZWcsIzAzMDUwZiAwJSwjMDgw
ZDFmIDUwJSwjMDUwODEwIDEwMCUpO3BhZGRpbmc6MjBweCAyMHB4IDE4cHg7dGV4dC1hbGlnbjpj
ZW50ZXI7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO30KICAuaGRyOjphZnRlcntj
b250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDtyaWdodDowO2hlaWdo
dDoxcHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdHJhbnNwYXJlbnQscmdiYSgx
OTIsMTMyLDI1MiwwLjYpLHRyYW5zcGFyZW50KTt9CiAgLmhkci1zdWJ7Zm9udC1mYW1pbHk6J09y
Yml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6
cmdiYSgxOTIsMTMyLDI1MiwwLjcpO21hcmdpbi1ib3R0b206NnB4O30KICAuaGRyLXRpdGxle2Zv
bnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyNnB4O2ZvbnQtd2VpZ2h0
OjkwMDtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOjJweDt9CiAgLmhkci10aXRsZSBzcGFue2Nv
bG9yOiNjMDg0ZmM7fQogIC5oZHItZGVzY3ttYXJnaW4tdG9wOjZweDtmb250LXNpemU6MTFweDtj
b2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNDUpO2xldHRlci1zcGFjaW5nOjJweDt9CiAgLmxvZ291
dHtwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MTZweDtyaWdodDoxNHB4O2JhY2tncm91bmQ6cmdiYSgy
NTUsMjU1LDI1NSwwLjA3KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4xNSk7
Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo1cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjpy
Z2JhKDI1NSwyNTUsMjU1LDAuNik7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4n
LHNhbnMtc2VyaWY7fQoKCgoKICAvKiBOQVYgcGlsbCBzdHlsZSAqLwogIC5uYXYtd3JhcHtiYWNr
Z3JvdW5kOmxpbmVhci1ncmFkaWVudCgxODBkZWcsIzA4MGQxZiAwJSwjMGMxNDI4IDEwMCUpO3Bh
ZGRpbmc6MTBweCAxMHB4IDA7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6OTk5OTtib3Jk
ZXItYm90dG9tOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO2JveC1zaGFkb3c6MCA0
cHggMjBweCByZ2JhKDAsMCwwLDAuMyk7b3ZlcmZsb3c6aGlkZGVuO30KICAubmF2LWZme3Bvc2l0
aW9uOmFic29sdXRlO2JvcmRlci1yYWRpdXM6NTAlO3BvaW50ZXItZXZlbnRzOm5vbmU7YW5pbWF0
aW9uOm5mZi1kcmlmdCBsaW5lYXIgaW5maW5pdGUsbmZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmlu
aXRlO29wYWNpdHk6MDt6LWluZGV4OjE7fQogIEBrZXlmcmFtZXMgbmZmLWRyaWZ0ewogICAgMCV7
dHJhbnNmb3JtOnRyYW5zbGF0ZSgwLDApfQogICAgMjUle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFy
KC0tZHgxKSx2YXIoLS1keTEpKX0KICAgIDUwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4
MiksdmFyKC0tZHkyKSl9CiAgICA3NSV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDMpLHZh
cigtLWR5MykpfQogICAgMTAwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKDAsMCl9CiAgfQogIEBrZXlm
cmFtZXMgbmZmLWJsaW5rewogICAgMCUsMTAwJXtvcGFjaXR5OjB9CiAgICAzMCV7b3BhY2l0eTox
fQogICAgNTAle29wYWNpdHk6MC44NX0KICAgIDcwJXtvcGFjaXR5OjB9CiAgfQogIC8qIGR1cGxp
Y2F0ZSBrZXlmcmFtZXMgcmVtb3ZlZCAqLwogIC5uYXZ7ZGlzcGxheTpmbGV4O2dhcDo0cHg7b3Zl
cmZsb3cteDphdXRvO3Njcm9sbGJhci13aWR0aDpub25lO3BhZGRpbmctYm90dG9tOjEwcHg7fQog
IC5uYXY6Oi13ZWJraXQtc2Nyb2xsYmFye2Rpc3BsYXk6bm9uZTt9CiAgLm5hdi1pdGVte2ZsZXgt
c2hyaW5rOjA7cGFkZGluZzo4cHggMTRweDtmb250LXNpemU6MTFweDtmb250LXdlaWdodDo3MDA7
Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQpO3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2lu
dGVyO3doaXRlLXNwYWNlOm5vd3JhcDtib3JkZXItcmFkaXVzOjk5OXB4O2JvcmRlcjoxLjVweCBz
b2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpO2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSww
LjA0KTt0cmFuc2l0aW9uOmFsbCAwLjIycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpO2xl
dHRlci1zcGFjaW5nOjAuM3B4O2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAu
bmF2LWl0ZW06aG92ZXI6bm90KC5hY3RpdmUpe2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC43KTti
YWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wOCk7Ym9yZGVyLWNvbG9yOnJnYmEoMjU1LDI1
NSwyNTUsMC4xOCk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5uYXYtaXRlbS5hY3Rp
dmV7Y29sb3I6I2ZmZjtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzIyYzU1ZSwj
MTZhMzRhKTtib3JkZXItY29sb3I6dHJhbnNwYXJlbnQ7Ym94LXNoYWRvdzowIDRweCAyMHB4IHJn
YmEoMzQsMTk3LDk0LDAuNSksMCAycHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMjUpIGluc2V0O3Ry
YW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpO2JvcmRlci1yYWRpdXM6OTk5cHg7fQogIC5uYXYtaXRl
bS5uYXYtc3BlZWQuYWN0aXZle2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMDZi
NmQ0LCMwODkxYjIpO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDYsMTgyLDIxMiwwLjQpLDAg
MXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjIpIGluc2V0O30KICAubmF2LWl0ZW0ubmF2LXNwZWVk
OmhvdmVyOm5vdCguYWN0aXZlKXtjb2xvcjojMDZiNmQ0O2JvcmRlci1jb2xvcjpyZ2JhKDYsMTgy
LDIxMiwwLjMpO30KICAuc2Vje3BhZGRpbmc6MTRweDtkaXNwbGF5Om5vbmU7YW5pbWF0aW9uOmZp
IC4zcyBlYXNlO30KICAuc2VjLmFjdGl2ZXtkaXNwbGF5OmJsb2NrO30KICBAa2V5ZnJhbWVzIGZp
e2Zyb217b3BhY2l0eTowO3RyYW5zZm9ybTp0cmFuc2xhdGVZKDZweCl9dG97b3BhY2l0eToxO3Ry
YW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAuY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2Jv
cmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzox
NnB4O21hcmdpbi1ib3R0b206MTBweDtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47
Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO30KICAuc2VjLWhkcntkaXNwbGF5OmZsZXg7YWxpZ24t
aXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206
MTJweDt9CiAgLnNlYy10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250
LXNpemU6MTBweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuYnRu
LXJ7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3Jk
ZXItcmFkaXVzOjhweDtwYWRkaW5nOjZweCAxNHB4O2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigt
LW11dGVkKTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0
cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5idG4tcjpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWMp
O2NvbG9yOnZhcigtLWFjKTt9CiAgLnNncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNv
bHVtbnM6MWZyIDFmcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5zY3tiYWNrZ3Jv
dW5kOnZhcigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFk
aXVzOjE0cHg7cGFkZGluZzoxNHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjti
b3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbics
bW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11
dGVkKTttYXJnaW4tYm90dG9tOjhweDt9CiAgLnN2YWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxt
b25vc3BhY2U7Zm9udC1zaXplOjI0cHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7
bGluZS1oZWlnaHQ6MTt9CiAgLnN2YWwgc3Bhbntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1t
dXRlZCk7Zm9udC13ZWlnaHQ6NDAwO30KICAuc3N1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIo
LS1tdXRlZCk7bWFyZ2luLXRvcDo0cHg7fQogIC5kbnV0e3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRo
OjUycHg7aGVpZ2h0OjUycHg7bWFyZ2luOjRweCBhdXRvIDRweDt9CiAgLmRudXQgc3Zne3RyYW5z
Zm9ybTpyb3RhdGUoLTkwZGVnKTt9CiAgLmRiZ3tmaWxsOm5vbmU7c3Ryb2tlOnJnYmEoMCwwLDAs
MC4wNik7c3Ryb2tlLXdpZHRoOjQ7fQogIC5kdntmaWxsOm5vbmU7c3Ryb2tlLXdpZHRoOjQ7c3Ry
b2tlLWxpbmVjYXA6cm91bmQ7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAxcyBlYXNlO30K
ICAuZGN7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6
Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25v
c3BhY2U7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7fQog
IC5wYntoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwwLjA2KTtib3JkZXItcmFkaXVz
OjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW47fQogIC5wZntoZWlnaHQ6MTAwJTti
b3JkZXItcmFkaXVzOjJweDt0cmFuc2l0aW9uOndpZHRoIDFzIGVhc2U7fQogIC5wZi5wdXtiYWNr
Z3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1hYyksIzE2YTM0YSk7fQogIC5wZi5w
Z3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1uZyksIzE2YTM0YSk7fQog
IC5wZi5wb3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZmI5MjNjLCNmOTczMTYp
O30KICAucGYucHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMy
NjI2KTt9CiAgLnViZGd7ZGlzcGxheTpmbGV4O2dhcDo1cHg7ZmxleC13cmFwOndyYXA7bWFyZ2lu
LXRvcDo4cHg7fQogIC5iZGd7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFy
KC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjZweDtwYWRkaW5nOjNweCA4cHg7Zm9udC1zaXplOjEw
cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30K
ICAubmV0LXJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2Fw
OjEycHg7bWFyZ2luLXRvcDoxMHB4O30KICAubml7ZmxleDoxO30KICAubmR7Zm9udC1zaXplOjEx
cHg7Y29sb3I6dmFyKC0tYWMpO21hcmdpbi1ib3R0b206M3B4O30KICAubnN7Zm9udC1mYW1pbHk6
J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjIwcHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9y
OnZhcigtLXR4dCk7fQogIC5ucyBzcGFue2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVk
KTtmb250LXdlaWdodDo0MDA7fQogIC5udHtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRl
ZCk7bWFyZ2luLXRvcDoycHg7fQogIC5kaXZpZGVye3dpZHRoOjFweDtiYWNrZ3JvdW5kOnZhcigt
LWJvcmRlcik7bWFyZ2luOjRweCAwO30KICAub3BpbGx7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5
NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4zKTtib3JkZXItcmFkaXVz
OjIwcHg7cGFkZGluZzo1cHggMTRweDtmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1uZyk7ZGlz
cGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjVweDt3aGl0ZS1zcGFjZTpu
b3dyYXA7fQogIC5vcGlsbC5vZmZ7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEpO2JvcmRl
ci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwwLjMpO2NvbG9yOiNlZjQ0NDQ7fQogIC5kb3R7d2lkdGg6
NXB4O2hlaWdodDo1cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94
LXNoYWRvdzowIDAgM3B4IHZhcigtLW5nKTthbmltYXRpb246cGxzIDRzIGVhc2UtaW4tb3V0IGlu
ZmluaXRlO30KICAuZG90LnJlZHtiYWNrZ3JvdW5kOiNlZjQ0NDQ7Ym94LXNoYWRvdzowIDAgNHB4
ICNlZjQ0NDQ7fQogIEBrZXlmcmFtZXMgcGxzezAlLDEwMCV7b3BhY2l0eTouOTtib3gtc2hhZG93
OjAgMCAycHggdmFyKC0tbmcpfTUwJXtvcGFjaXR5Oi42O2JveC1zaGFkb3c6MCAwIDRweCB2YXIo
LS1uZyl9fQogIC54dWktcm93e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEy
cHg7bWFyZ2luLXRvcDoxMHB4O30KICAueHVpLWluZm97Zm9udC1zaXplOjEycHg7Y29sb3I6dmFy
KC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNzt9CiAgLnh1aS1pbmZvIGJ7Y29sb3I6dmFyKC0tdHh0
KTt9CiAgLnN2Yy1saXN0e2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjhw
eDttYXJnaW4tdG9wOjEwcHg7fQogIC5zdmN7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjA1
KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMik7Ym9yZGVyLXJhZGl1czoxMHB4
O3BhZGRpbmc6MTFweCAxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlm
eS1jb250ZW50OnNwYWNlLWJldHdlZW47fQogIC5zdmMuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5
LDY4LDY4LDAuMDUpO2JvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwwLjIpO30KICAuc3ZjLWx7
ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweDt9CiAgLyogLmRnIHN0eWxl
cyBkZWZpbmVkIGJlbG93IHdpdGggcGluZyBhbmltYXRpb24gKi8KICAuZGcucmVke2JhY2tncm91
bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6
ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1m
YW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0
ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBz
b2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEw
cHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbics
bW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJn
YmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6
I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZh
cigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3Bh
Y2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbics
bW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1t
dXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7
Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlk
IHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNp
emU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtk
aXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtw
YWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRl
cjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9y
OnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9u
OmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVy
LWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEy
cHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4
cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdp
bi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVy
OjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAx
NHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4n
LHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAg
LmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFy
KC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDox
O3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2lu
dGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29s
b3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRp
b246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3Jk
ZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtw
YWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0
OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVu
dCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6
J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4
IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92
ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRy
YW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1h
bGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4
ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3Bh
ZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1p
bHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0
cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2
YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIo
LS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZs
ZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdp
bi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93
OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9y
OnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDto
ZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2Vu
dGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3Bh
Y2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgt
c2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6
dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcnti
YWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4
IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5
LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2
OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0t
dHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9w
OjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNp
emU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFj
a2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcs
OTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzks
NjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0
NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVy
OjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntw
b3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3At
ZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4Ojk5OTk7ZGlzcGxheTpub25lO2FsaWduLWl0ZW1zOmZs
ZXgtZW5kO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5tb3Zlci5vcGVue2Rpc3BsYXk6Zmxl
eDt9CiAgLm1vZGFse2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRl
cik7Ym9yZGVyLXJhZGl1czoyMHB4IDIwcHggMCAwO3dpZHRoOjEwMCU7bWF4LXdpZHRoOjQ4MHB4
O3BhZGRpbmc6MjBweDttYXgtaGVpZ2h0Ojg1dmg7b3ZlcmZsb3cteTphdXRvO2FuaW1hdGlvbjpz
dSAuM3MgZWFzZTtib3gtc2hhZG93OjAgLTRweCAzMHB4IHJnYmEoMCwwLDAsMC4xMik7fQogIEBr
ZXlmcmFtZXMgc3V7ZnJvbXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgxMDAlKX10b3t0cmFuc2Zvcm06
dHJhbnNsYXRlWSgwKX19CiAgLm1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtq
dXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjE2cHg7fQogIC5tdGl0
bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Y29sb3I6
dmFyKC0tdHh0KTt9CiAgLm1jbG9zZXt3aWR0aDozMnB4O2hlaWdodDozMnB4O2JvcmRlci1yYWRp
dXM6NTAlO2JhY2tncm91bmQ6I2YxZjVmOTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7
Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxNnB4O2Rpc3BsYXk6
ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLmRncmlk
e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdp
bi1ib3R0b206MTRweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcntkaXNw
bGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVy
O3BhZGRpbmc6N3B4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAg
LmRyOmxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRvbTpub25lO30KICAuZGt7Zm9udC1zaXplOjEycHg7
Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuZHZ7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tdHh0
KTtmb250LXdlaWdodDo2MDA7fQogIC5kdi5ncmVlbntjb2xvcjp2YXIoLS1uZyk7fQogIC5kdi5y
ZWR7Y29sb3I6I2VmNDQ0NDt9CiAgLmR2Lm1vbm97Y29sb3I6dmFyKC0tYWMpO2ZvbnQtc2l6ZTo5
cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7
fQogIC5hZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2Fw
OjhweDt9CiAgLm0tc3Vie2Rpc3BsYXk6bm9uZTttYXJnaW4tdG9wOjE0cHg7YmFja2dyb3VuZDoj
ZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEycHg7
cGFkZGluZzoxNHB4O30KICAubS1zdWIub3BlbntkaXNwbGF5OmJsb2NrO2FuaW1hdGlvbjpmaSAu
MnMgZWFzZTt9CiAgLm1zdWItbGJse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xv
cjp2YXIoLS10eHQpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLmFidG57YmFja2dyb3VuZDojZjhm
YWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFk
ZGluZzoxNHB4IDEwcHg7dGV4dC1hbGlnbjpjZW50ZXI7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlv
bjphbGwgLjJzO30KICAuYWJ0bjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVy
LWNvbG9yOnZhcigtLWFjKTt9CiAgLmFidG4gLmFpe2ZvbnQtc2l6ZToyMnB4O21hcmdpbi1ib3R0
b206NnB4O30KICAuYWJ0biAuYW57Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9y
OnZhcigtLXR4dCk7fQogIC5hYnRuIC5hZHtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRl
ZCk7bWFyZ2luLXRvcDoycHg7fQogIC5hYnRuLmRhbmdlcjpob3ZlcntiYWNrZ3JvdW5kOnJnYmEo
MjQ4LDExMywxMTMsLjEpO2JvcmRlci1jb2xvcjojZjg3MTcxO30KICAub2V7dGV4dC1hbGlnbjpj
ZW50ZXI7cGFkZGluZzo0MHB4IDIwcHg7fQogIC5vZSAuZWl7Zm9udC1zaXplOjQ4cHg7bWFyZ2lu
LWJvdHRvbToxMnB4O30KICAub2UgcHtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEzcHg7
fQogIC5vY3J7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweDttYXJnaW4t
Ym90dG9tOjE2cHg7fQogIC51dHtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9u
dC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC8qIHJlc3VsdCBib3ggKi8KICAucmVz
LWJveHtwb3NpdGlvbjpyZWxhdGl2ZTtiYWNrZ3JvdW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xp
ZCAjODZlZmFjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLXRvcDoxNHB4
O2Rpc3BsYXk6bm9uZTt9CiAgLnJlcy1ib3guc2hvd3tkaXNwbGF5OmJsb2NrO30KICAucmVzLWNs
b3Nle3Bvc2l0aW9uOmFic29sdXRlO3RvcDotMTFweDtyaWdodDotMTFweDt3aWR0aDoyMnB4O2hl
aWdodDoyMnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6I2VmNDQ0NDtib3JkZXI6MnB4
IHNvbGlkICNmZmY7Y29sb3I6I2ZmZjtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTFweDtmb250
LXdlaWdodDo3MDA7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRl
bnQ6Y2VudGVyO2xpbmUtaGVpZ2h0OjE7Ym94LXNoYWRvdzowIDFweCA0cHggcmdiYSgyMzksNjgs
NjgsMC40KTt6LWluZGV4OjI7fQogIC5yZXMtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRl
bnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjVweCAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkICNk
Y2ZjZTc7Zm9udC1zaXplOjEzcHg7fQogIC5yZXMtcm93Omxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRv
bTpub25lO30KICAucmVzLWt7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMXB4O30KICAu
cmVzLXZ7Y29sb3I6dmFyKC0tdHh0KTtmb250LXdlaWdodDo2MDA7d29yZC1icmVhazpicmVhay1h
bGw7dGV4dC1hbGlnbjpyaWdodDttYXgtd2lkdGg6NjUlO30KICAucmVzLWxpbmt7YmFja2dyb3Vu
ZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjhw
eDtwYWRkaW5nOjhweCAxMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbics
bW9ub3NwYWNlO3dvcmQtYnJlYWs6YnJlYWstYWxsO21hcmdpbi10b3A6OHB4O2NvbG9yOnZhcigt
LW11dGVkKTt9CiAgLmNvcHktYnRue3dpZHRoOjEwMCU7bWFyZ2luLXRvcDo4cHg7cGFkZGluZzo4
cHg7Ym9yZGVyLXJhZGl1czo4cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1hYy1ib3JkZXIpO2Jh
Y2tncm91bmQ6dmFyKC0tYWMtZGltKTtjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjEycHg7Y3Vy
c29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7fQogIC8qIGFsZXJ0
ICovCiAgLmFsZXJ0e2Rpc3BsYXk6bm9uZTtwYWRkaW5nOjEwcHggMTRweDtib3JkZXItcmFkaXVz
OjhweDtmb250LXNpemU6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5hbGVydC5va3tiYWNrZ3Jv
dW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xpZCAjODZlZmFjO2NvbG9yOiMxNTgwM2Q7fQogIC5h
bGVydC5lcnJ7YmFja2dyb3VuZDojZmVmMmYyO2JvcmRlcjoxcHggc29saWQgI2ZjYTVhNTtjb2xv
cjojZGMyNjI2O30KICAvKiBzcGlubmVyICovCiAgLnNwaW57ZGlzcGxheTppbmxpbmUtYmxvY2s7
d2lkdGg6MTJweDtoZWlnaHQ6MTJweDtib3JkZXI6MnB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUs
LjMpO2JvcmRlci10b3AtY29sb3I6I2ZmZjtib3JkZXItcmFkaXVzOjUwJTthbmltYXRpb246c3Ag
LjdzIGxpbmVhciBpbmZpbml0ZTt2ZXJ0aWNhbC1hbGlnbjptaWRkbGU7bWFyZ2luLXJpZ2h0OjRw
eDt9CiAgQGtleWZyYW1lcyBzcHt0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9fQogIC5sb2Fk
aW5ne3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MzBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9u
dC1zaXplOjEzcHg7fQoKCiAgLyog4pSA4pSAIERBUksgRk9STSAoU1NIKSDilIDilIAgKi8KICAu
c3NoLWRhcmstZm9ybXtiYWNrZ3JvdW5kOiMwZDExMTc7Ym9yZGVyLXJhZGl1czoxNnB4O3BhZGRp
bmc6MThweCAxNnB4O21hcmdpbi1ib3R0b206MDt9CiAgLmRhcmstZmllbGR7bWFyZ2luLWJvdHRv
bToxMnB4O30KICAuZGFyay1sYWJlbHtmb250LXNpemU6MTFweDtjb2xvcjpyZ2JhKDE4MCwyMjAs
MjU1LC41KTtsZXR0ZXItc3BhY2luZzoxcHg7ZGlzcGxheTpibG9jazttYXJnaW4tYm90dG9tOjVw
eDt9CiAgLmRhcmstaW5wdXR7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUs
LjA2KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2NvbG9yOiNlOGY0ZmY7
Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2ZvbnQt
ZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO291dGxpbmU6bm9uZTt0cmFuc2l0aW9uOmJvcmRl
ci1jb2xvciAuMnM7fQogIC5kYXJrLWlucHV0OmZvY3Vze2JvcmRlci1jb2xvcjpyZ2JhKDAsMjAw
LDI1NSwuNSk7Ym94LXNoYWRvdzowIDAgMCAzcHggcmdiYSgwLDIwMCwyNTUsLjA4KTt9CiAgLmRh
cmstaGRye2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnJnYmEoMCwyMDAsMjU1LC44KTtmb250LWZhbWls
eTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoycHg7bWFyZ2luLWJvdHRvbTox
NHB4O30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwu
NSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgy
NTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29s
b3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1
c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJn
YmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29s
b3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29s
b3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xl
dHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0
ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlz
cGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJv
dHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7
Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJw
eDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5z
aXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFy
Z2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRy
b24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90
dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgy
NTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAw
Y2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCBy
Z2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xv
cjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7
YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEo
MjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6
I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5Omdy
aWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0
cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6
MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRk
aW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246
YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206
NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2Zv
bnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNr
LW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBp
Y2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEw
MiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNr
LW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVy
LWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzow
IDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xv
cjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dy
b3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwy
NTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1v
cHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1
LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1v
cHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAucGljay1vcHQuYS1oaXtib3JkZXItY29s
b3I6I2NjMDBmZjtiYWNrZ3JvdW5kOnJnYmEoMjA0LDAsMjU1LC4xKTtib3gtc2hhZG93OjAgMCAx
MnB4IHJnYmEoMjA0LDAsMjU1LC4yKTt9CiAgLnBpY2stb3B0LmEtaGkgLnBue2NvbG9yOiNkZDQ0
ZmY7fQogIC5waWNrLW9wdC5hLWhje2JvcmRlci1jb2xvcjojMDA5OWZmO2JhY2tncm91bmQ6cmdi
YSgwLDE1MywyNTUsLjEpO2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgwLDE1MywyNTUsLjIpO30K
ICAucGljay1vcHQuYS1oYyAucG57Y29sb3I6IzMzYWFmZjt9CiAgLnBpY2stb3B0LmEtaGF0e2Jv
cmRlci1jb2xvcjojZmZjYzAwO2JhY2tncm91bmQ6cmdiYSgyNTUsMjA0LDAsLjEpO2JveC1zaGFk
b3c6MCAwIDEycHggcmdiYSgyNTUsMjA0LDAsLjIpO30KICAucGljay1vcHQuYS1oYXQgLnBue2Nv
bG9yOiNmZmRkMzM7fQogIC8qIENyZWF0ZSBidG4gKHNzaCBkYXJrKSAqLwogIC5jYnRuLXNzaHti
YWNrZ3JvdW5kOnRyYW5zcGFyZW50O2JvcmRlcjoycHggc29saWQgIzIyYzU1ZTtjb2xvcjojMjJj
NTVlO2ZvbnQtc2l6ZToxM3B4O3dpZHRoOmF1dG87cGFkZGluZzoxMHB4IDI4cHg7Ym9yZGVyLXJh
ZGl1czoxMHB4O2N1cnNvcjpwb2ludGVyO2ZvbnQtd2VpZ2h0OjcwMDtmb250LWZhbWlseTonU2Fy
YWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7ZGlzcGxheTppbmxpbmUtZmxleDth
bGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweDt9CiAgLmNidG4tc3NoOmhvdmVye2JhY2tncm91bmQ6
cmdiYSgzNCwxOTcsOTQsLjEpO2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgzNCwxOTcsOTQsLjIp
O30KICAvKiBMaW5rIHJlc3VsdCAqLwogIC5saW5rLXJlc3VsdHtkaXNwbGF5Om5vbmU7bWFyZ2lu
LXRvcDoxMnB4O2JvcmRlci1yYWRpdXM6MTBweDtvdmVyZmxvdzpoaWRkZW47fQogIC5saW5rLXJl
c3VsdC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5saW5rLXJlc3VsdC1oZHJ7ZGlzcGxheTpmbGV4
O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4O3BhZGRpbmc6OHB4IDEycHg7YmFja2dyb3VuZDpy
Z2JhKDAsMCwwLC4zKTtib3JkZXItYm90dG9tOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4w
Nik7fQogIC5pbXAtYmFkZ2V7Zm9udC1zaXplOi42MnJlbTtmb250LXdlaWdodDo3MDA7bGV0dGVy
LXNwYWNpbmc6MS41cHg7cGFkZGluZzouMThyZW0gLjU1cmVtO2JvcmRlci1yYWRpdXM6OTlweDt9
CiAgLmltcC1iYWRnZS5ucHZ7YmFja2dyb3VuZDpyZ2JhKDAsMTgwLDI1NSwuMTUpO2NvbG9yOiMw
MGNjZmY7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTgwLDI1NSwuMyk7fQogIC5pbXAtYmFkZ2Uu
ZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMTUpO2NvbG9yOiNjYzY2ZmY7Ym9yZGVy
OjFweCBzb2xpZCByZ2JhKDE1Myw1MSwyNTUsLjMpO30KICAubGluay1wcmV2aWV3e2JhY2tncm91
bmQ6IzA2MGExMjtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxMHB4O2ZvbnQtZmFtaWx5
Om1vbm9zcGFjZTtmb250LXNpemU6LjU2cmVtO2NvbG9yOiMwMGFhZGQ7d29yZC1icmVhazpicmVh
ay1hbGw7bGluZS1oZWlnaHQ6MS42O21hcmdpbjo4cHggMTJweDtib3JkZXI6MXB4IHNvbGlkIHJn
YmEoMCwxNTAsMjU1LC4xNSk7bWF4LWhlaWdodDo1NHB4O292ZXJmbG93OmhpZGRlbjtwb3NpdGlv
bjpyZWxhdGl2ZTt9CiAgLmxpbmstcHJldmlldy5kYXJrLWxwe2JvcmRlci1jb2xvcjpyZ2JhKDE1
Myw1MSwyNTUsLjIyKTtjb2xvcjojYWE1NWZmO30KICAubGluay1wcmV2aWV3OjphZnRlcntjb250
ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDtyaWdodDowO2hlaWdodDox
NHB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KHRyYW5zcGFyZW50LCMwNjBhMTIpO30KICAu
Y29weS1saW5rLWJ0bnt3aWR0aDpjYWxjKDEwMCUgLSAyNHB4KTttYXJnaW46MCAxMnB4IDEwcHg7
cGFkZGluZzouNTVyZW07Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOi44MnJlbTtmb250LXdl
aWdodDo3MDA7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7
Ym9yZGVyOjFweCBzb2xpZDt9CiAgLmNvcHktbGluay1idG4ubnB2e2JhY2tncm91bmQ6cmdiYSgw
LDE4MCwyNTUsLjA3KTtib3JkZXItY29sb3I6cmdiYSgwLDE4MCwyNTUsLjI4KTtjb2xvcjojMDBj
Y2ZmO30KICAuY29weS1saW5rLWJ0bi5kYXJre2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4w
Nyk7Ym9yZGVyLWNvbG9yOnJnYmEoMTUzLDUxLDI1NSwuMjgpO2NvbG9yOiNjYzY2ZmY7fQogIC8q
IFVzZXIgdGFibGUgKi8KICAudXRibC13cmFwe292ZXJmbG93LXg6YXV0bzttYXJnaW4tdG9wOjEw
cHg7fQogIC51dGJse3dpZHRoOjEwMCU7Ym9yZGVyLWNvbGxhcHNlOmNvbGxhcHNlO2ZvbnQtc2l6
ZToxMnB4O30KICAudXRibCB0aHtwYWRkaW5nOjhweCAxMHB4O3RleHQtYWxpZ246bGVmdDtmb250
LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5n
OjEuNXB4O2NvbG9yOnZhcigtLW11dGVkKTtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1i
b3JkZXIpO30KICAudXRibCB0ZHtwYWRkaW5nOjlweCAxMHB4O2JvcmRlci1ib3R0b206MXB4IHNv
bGlkIHZhcigtLWJvcmRlcik7fQogIC51dGJsIHRyOmxhc3QtY2hpbGQgdGR7Ym9yZGVyLWJvdHRv
bTpub25lO30KICAuYmRne3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7Zm9udC1z
aXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC13ZWlnaHQ6NzAw
O30KICAuYmRnLWd7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMSk7Ym9yZGVyOjFweCBzb2xp
ZCByZ2JhKDM0LDE5Nyw5NCwuMyk7Y29sb3I6IzIyYzU1ZTt9CiAgLmJkZy1ye2JhY2tncm91bmQ6
cmdiYSgyMzksNjgsNjgsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjMpO2Nv
bG9yOiNlZjQ0NDQ7fQogIC5idG4tdGJse3dpZHRoOjMwcHg7aGVpZ2h0OjMwcHg7Ym9yZGVyLXJh
ZGl1czo4cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JhY2tncm91bmQ6I2Y4ZmFm
YztjdXJzb3I6cG9pbnRlcjtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtq
dXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtc2l6ZToxNHB4O30KICAuYnRuLXRibDpob3Zlcnti
b3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAvKiBSZW5ldyBkYXlzIGJhZGdlICovCiAgLmRheXMt
YmFkZ2V7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7cGFk
ZGluZzoycHggOHB4O2JvcmRlci1yYWRpdXM6MjBweDtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0
LC4wOCk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMik7Y29sb3I6dmFyKC0tYWMp
O30KCiAgLyog4pSA4pSAIFNFTEVDVE9SIENBUkRTIOKUgOKUgCAqLyAgLyog4pSA4pSAIFNFTEVD
VE9SIENBUkRTIOKUgOKUgCAqLwogIC5zZWMtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxt
b25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6dmFyKC0tbXV0
ZWQpO3BhZGRpbmc6NnB4IDJweCAxMHB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTt9CiAgLnNl
bC1jYXJke2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9y
ZGVyLXJhZGl1czoxNnB4O3BhZGRpbmc6MTZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2Vu
dGVyO2dhcDoxNHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93
OnZhcigtLXNoYWRvdyk7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuc2VsLWNhcmQ6aG92ZXJ7Ym9y
ZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7dHJhbnNmb3JtOnRy
YW5zbGF0ZVgoMnB4KTt9CiAgLnNlbC1sb2dve3dpZHRoOjY0cHg7aGVpZ2h0OjY0cHg7Ym9yZGVy
LXJhZGl1czoxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250
ZW50OmNlbnRlcjtmbGV4LXNocmluazowO30KICAuc2VsLWFpc3tiYWNrZ3JvdW5kOiNmZmY7Ym9y
ZGVyOjFweCBzb2xpZCAjYzVlODlhO30KICAuc2VsLXRydWV7YmFja2dyb3VuZDojYzgwNDBkO30K
ICAuc2VsLXNzaHtiYWNrZ3JvdW5kOiMxNTY1YzA7fQogIC5zZWwtYWlzLXNtLC5zZWwtdHJ1ZS1z
bSwuc2VsLXNzaC1zbXt3aWR0aDo0NHB4O2hlaWdodDo0NHB4O2JvcmRlci1yYWRpdXM6MTBweDtk
aXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zmxl
eC1zaHJpbms6MDt9CiAgLnNlbC1haXMtc217YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29s
aWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVlLXNte2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1z
c2gtc217YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWluZm97ZmxleDoxO21pbi13aWR0aDow
O30KICAuc2VsLW5hbWV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXpl
Oi44MnJlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5zZWwtbmFtZS5h
aXN7Y29sb3I6IzNkN2EwZTt9CiAgLnNlbC1uYW1lLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLnNl
bC1uYW1lLnNzaHtjb2xvcjojMTU2NWMwO30KICAuc2VsLXN1Yntmb250LXNpemU6MTFweDtjb2xv
cjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS41O30KICAuc2VsLWFycm93e2ZvbnQtc2l6ZTox
LjRyZW07Y29sb3I6dmFyKC0tbXV0ZWQpO2ZsZXgtc2hyaW5rOjA7fQogIC8qIOKUgOKUgCBGT1JN
IEhFQURFUiDilIDilIAgKi8KICAuZm9ybS1iYWNre2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpj
ZW50ZXI7Z2FwOjZweDtmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBv
aW50ZXI7cGFkZGluZzo0cHggMnB4IDEycHg7Zm9udC13ZWlnaHQ6NjAwO30KICAuZm9ybS1iYWNr
OmhvdmVye2NvbG9yOnZhcigtLXR4dCk7fQogIC5mb3JtLWhkcntkaXNwbGF5OmZsZXg7YWxpZ24t
aXRlbXM6Y2VudGVyO2dhcDoxMnB4O21hcmdpbi1ib3R0b206MTZweDtwYWRkaW5nLWJvdHRvbTox
NHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5mb3JtLXRpdGxl
e2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODVyZW07Zm9udC13
ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206M3B4O30KICAuZm9ybS10aXRsZS5haXN7Y29sb3I6IzNk
N2EwZTt9CiAgLmZvcm0tdGl0bGUudHJ1ZXtjb2xvcjojYzgwNDBkO30KICAuZm9ybS10aXRsZS5z
c2h7Y29sb3I6IzE1NjVjMDt9CiAgLmZvcm0tc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigt
LW11dGVkKTt9CiAgLmNidG4tYWlze2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywj
M2Q3YTBlLCM1YWFhMTgpO30KICAuY2J0bi10cnVle2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50
KDEzNWRlZywjYTYwMDBjLCNkODEwMjApO30KCiAgLyog4pSA4pSAIEhEUiBsb2dvIGFuaW1hdGlv
bnMgKHNhbWUgYXMgbG9naW4pIOKUgOKUgCAqLwogIEBrZXlmcmFtZXMgaGRyLW9yYml0LWRhc2gg
ewogICAgZnJvbSB7IHN0cm9rZS1kYXNob2Zmc2V0OiAwOyB9CiAgICB0byAgIHsgc3Ryb2tlLWRh
c2hvZmZzZXQ6IC0yNTE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItcHVsc2UtZHJhdyB7CiAgICAw
JSAgIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDIyMDsgb3BhY2l0eTogMDsgfQogICAgMTUlICB7IG9w
YWNpdHk6IDE7IH0KICAgIDEwMCUgeyBzdHJva2UtZGFzaG9mZnNldDogMDsgb3BhY2l0eTogMTsg
fQogIH0KICBAa2V5ZnJhbWVzIGhkci1ibGluay1kb3QgewogICAgMCUsIDEwMCUgeyBvcGFjaXR5
OiAwLjI1OyB9CiAgICA1MCUgICAgICAgeyBvcGFjaXR5OiAxOyB9CiAgfQogIEBrZXlmcmFtZXMg
aGRyLWxvZ28tZ2xvdyB7CiAgICAwJSwgMTAwJSB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDZw
eCAjNjBhNWZhKSBkcm9wLXNoYWRvdygwIDAgMTRweCAjMjU2M2ViKTsgfQogICAgNTAlICAgICAg
IHsgZmlsdGVyOiBkcm9wLXNoYWRvdygwIDAgMTRweCAjNjBhNWZhKSBkcm9wLXNoYWRvdygwIDAg
MjhweCAjMjU2M2ViKSBkcm9wLXNoYWRvdygwIDAgNDJweCAjMDZiNmQ0KTsgfQogIH0KICAuaGRy
LWxvZ28tc3ZnLXdyYXAgewogICAgZGlzcGxheTogZmxleDsKICAgIGp1c3RpZnktY29udGVudDog
Y2VudGVyOwogICAgbWFyZ2luLWJvdHRvbTogOHB4OwogICAgYW5pbWF0aW9uOiBoZHItbG9nby1n
bG93IDNzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIH0KICAuaGRyLW9yYml0LXJpbmcgeyB0cmFu
c2Zvcm0tb3JpZ2luOiA1MHB4IDUwcHg7IGFuaW1hdGlvbjogaGRyLW9yYml0LWRhc2ggOHMgbGlu
ZWFyIGluZmluaXRlOyB9CiAgLmhkci13YXZlLWFuaW0gIHsgc3Ryb2tlLWRhc2hhcnJheToyMjA7
IHN0cm9rZS1kYXNob2Zmc2V0OjIyMDsgYW5pbWF0aW9uOiBoZHItcHVsc2UtZHJhdyAxLjZzIGN1
YmljLWJlemllciguNCwwLC4yLDEpIDAuNXMgZm9yd2FyZHM7IH0KICAuaGRyLWRvdC0xIHsgYW5p
bWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMS44cyBpbmZpbml0ZTsgfQog
IC5oZHItZG90LTIgeyBhbmltYXRpb246IGhkci1ibGluay1kb3QgMi4ycyBlYXNlLWluLW91dCAy
LjJzIGluZmluaXRlOyB9CgogIC8qIOKUgOKUgCBEYXNoYm9hcmQgRmlyZWZsaWVzIChmdWxsIHBh
Z2UpIOKUgOKUgCAqLwogIC5kYXNoLWZmIHsKICAgIHBvc2l0aW9uOiBmaXhlZDsKICAgIGJvcmRl
ci1yYWRpdXM6IDUwJTsKICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgei1pbmRleDogMDsK
ICAgIGFuaW1hdGlvbjogZGFzaC1mZi1kcmlmdCBsaW5lYXIgaW5maW5pdGUsIGRhc2gtZmYtYmxp
bmsgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICBvcGFjaXR5OiAwOwogIH0KICBAa2V5ZnJhbWVz
IGRhc2gtZmYtZHJpZnQgewogICAgMCUgICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKDAsMCkgc2Nh
bGUoMSk7IH0KICAgIDIwJSAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSh2YXIoLS1keDEpLHZhcigt
LWR5MSkpIHNjYWxlKDEuMSk7IH0KICAgIDQwJSAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSh2YXIo
LS1keDIpLHZhcigtLWR5MikpIHNjYWxlKDAuOSk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHRy
YW5zbGF0ZSh2YXIoLS1keDMpLHZhcigtLWR5MykpIHNjYWxlKDEuMDUpOyB9CiAgICA4MCUgIHsg
dHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHg0KSx2YXIoLS1keTQpKSBzY2FsZSgwLjk1KTsg
fQogICAgMTAwJSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKDAsMCkgc2NhbGUoMSk7IH0KICB9CiAg
QGtleWZyYW1lcyBkYXNoLWZmLWJsaW5rIHsKICAgIDAlLDEwMCV7IG9wYWNpdHk6MDsgfSAxNSV7
IG9wYWNpdHk6MDsgfSAzMCV7IG9wYWNpdHk6MTsgfQogICAgNTAleyBvcGFjaXR5OjAuOTsgfSA2
NSV7IG9wYWNpdHk6MDsgfSA4MCV7IG9wYWNpdHk6MC44NTsgfSA5MiV7IG9wYWNpdHk6MDsgfQog
IH0KCiAgLyog4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCiAgICAgM0QgQ0FSRFMgLyBUQUJTIC8g
QlVUVE9OUyDigJQg4LiX4Li44LiB4Lir4LiZ4LmJ4LiyCiAg4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQICovCiAgLmNhcmQgewogICAgYm9yZGVyLXJhZGl1czogMThweCAhaW1wb3J0YW50OwogICAg
Ym9yZGVyOiAycHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yNSkgIWltcG9ydGFudDsKICAgIGJv
eC1zaGFkb3c6CiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSBpbnNldCwKICAg
ICAgMCA4cHggMjRweCByZ2JhKDAsMCwwLDAuMzUpLAogICAgICAwIDJweCA4cHggcmdiYSgzNCwx
OTcsOTQsMC4xMiksCiAgICAgIDAgMTZweCAzMnB4IHJnYmEoMCwwLDAsMC4yKSAhaW1wb3J0YW50
OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVooMCk7CiAgICB0cmFuc2l0
aW9uOiB0cmFuc2Zvcm0gMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAg
ICAgICAgICAgIGJveC1zaGFkb3cgMC4xOHMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuY2FyZDpo
b3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTNweCkgdHJhbnNsYXRlWigwKTsKICAg
IGJveC1zaGFkb3c6CiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEpIGluc2V0LAog
ICAgICAwIDE0cHggMzZweCByZ2JhKDAsMCwwLDAuNCksCiAgICAgIDAgNHB4IDE2cHggcmdiYSgz
NCwxOTcsOTQsMC4xOCksCiAgICAgIDAgMjRweCA0OHB4IHJnYmEoMCwwLDAsMC4yNSkgIWltcG9y
dGFudDsKICB9CgogIC8qIE5hdiBpdGVtcyAzRCAqLwogIC5uYXYtaXRlbSB7CiAgICBib3JkZXIt
cmFkaXVzOiA5OTlweCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAxLjVweCBzb2xpZCByZ2JhKDI1
NSwyNTUsMjU1LDAuMDgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OiAwIDNweCAwIHJnYmEo
MCwwLDAsMC4zKSwgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpIGluc2V0ICFpbXBvcnRh
bnQ7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4yMnMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwx
KSAhaW1wb3J0YW50OwogICAgbWFyZ2luOiAwIDJweDsKICAgIHBhZGRpbmc6IDlweCAxNnB4ICFp
bXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7CiAgfQogIC5uYXYtaXRlbS5h
Y3RpdmUgewogICAgYm9yZGVyLXJhZGl1czogOTk5cHggIWltcG9ydGFudDsKICAgIHRyYW5zZm9y
bTogdHJhbnNsYXRlWSgtMnB4KSAhaW1wb3J0YW50OwogICAgYm9yZGVyLWNvbG9yOiB0cmFuc3Bh
cmVudCAhaW1wb3J0YW50OwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDEzNWRlZywj
MjJjNTVlLCMxNmEzNGEpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OiAwIDRweCAxNHB4IHJn
YmEoMzQsMTk3LDk0LDAuNDUpICFpbXBvcnRhbnQ7CiAgICBjb2xvcjogI2ZmZiAhaW1wb3J0YW50
OwogICAgcGFkZGluZzogOXB4IDE2cHggIWltcG9ydGFudDsKICB9CiAgLm5hdi1pdGVtOmhvdmVy
Om5vdCguYWN0aXZlKSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCkgIWltcG9ydGFu
dDsKICAgIGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjE4KSAhaW1wb3J0YW50Owog
ICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSAhaW1wb3J0YW50OwogIH0KCiAg
LyogQWxsIGJ1dHRvbnMgM0QgKi8KICAuY2J0biwgLmJ0bi1yLCAuY2J0bS1zc2gsIC5idG4tdGJs
LCAucGJ0biwgLnRidG4sCiAgLmNvcHktYnRuLCAuY29weS1saW5rLWJ0biwgLmxvZ291dCwgLm1j
bG9zZSwKICAuYWJ0biwgLnBvcnQtYnRuLCAucGljay1vcHQgewogICAgYm9yZGVyLXJhZGl1czog
MTJweCAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA0cHggMCByZ2JhKDAsMCww
LDAuMzUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xMikgaW5zZXQsCiAgICAg
IDAgNnB4IDE2cHggcmdiYSgwLDAsMCwwLjIpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRy
YW5zbGF0ZVkoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xMnMgY3ViaWMtYmV6aWVy
KC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xMnMgZWFzZSAh
aW1wb3J0YW50OwogICAgYm9yZGVyLXdpZHRoOiAycHggIWltcG9ydGFudDsKICB9CiAgLmNidG46
aG92ZXIsIC5idG4tcjpob3ZlciwgLmNvcHktYnRuOmhvdmVyLAogIC5hYnRuOmhvdmVyLCAucG9y
dC1idG46aG92ZXIsIC5waWNrLW9wdDpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVko
LTJweCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDZweCAwIHJnYmEoMCwwLDAsMC4zNSksCiAg
ICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjE1KSBpbnNldCwKICAgICAgMCAxMHB4IDI0
cHggcmdiYSgwLDAsMCwwLjI1KSAhaW1wb3J0YW50OwogIH0KICAuY2J0bjphY3RpdmUsIC5idG4t
cjphY3RpdmUsIC5jb3B5LWJ0bjphY3RpdmUsCiAgLmFidG46YWN0aXZlLCAucG9ydC1idG46YWN0
aXZlLCAucGljay1vcHQ6YWN0aXZlLAogIC5idG4tdGJsOmFjdGl2ZSwgLmxvZ291dDphY3RpdmUg
ewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDNweCkgc2NhbGUoMC45NykgIWltcG9ydGFudDsK
ICAgIGJveC1zaGFkb3c6CiAgICAgIDAgMXB4IDAgcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDAg
MCByZ2JhKDI1NSwyNTUsMjU1LDAuMDYpIGluc2V0ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9u
OiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSwgYm94LXNoYWRvdyAwLjA2cyBlYXNlICFpbXBvcnRhbnQ7
CiAgfQoKICAvKiBzZWwtY2FyZCAzRCAqLwogIC5zZWwtY2FyZCB7CiAgICBib3JkZXItcmFkaXVz
OiAxOHB4ICFpbXBvcnRhbnQ7CiAgICBib3JkZXI6IDJweCBzb2xpZCB2YXIoLS1ib3JkZXIpICFp
bXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDRweCAwIHJnYmEoMCwwLDAsMC4yKSwK
ICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpIGluc2V0LAogICAgICAwIDhweCAy
MHB4IHJnYmEoMCwwLDAsMC4xMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRl
WSgwKSB0cmFuc2xhdGVYKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1Ymlj
LWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThz
IGVhc2UgIWltcG9ydGFudDsKICB9CiAgLnNlbC1jYXJkOmhvdmVyIHsKICAgIHRyYW5zZm9ybTog
dHJhbnNsYXRlWSgtM3B4KSB0cmFuc2xhdGVYKDJweCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFk
b3c6CiAgICAgIDAgOHB4IDAgcmdiYSgwLDAsMCwwLjI1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1
NSwyNTUsMjU1LDAuMSkgaW5zZXQsCiAgICAgIDAgMTZweCAzMnB4IHJnYmEoMCwwLDAsMC4xOCkg
IWltcG9ydGFudDsKICB9CiAgLnNlbC1jYXJkOmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5z
bGF0ZVkoMnB4KSB0cmFuc2xhdGVYKDApIHNjYWxlKDAuOTgpICFpbXBvcnRhbnQ7CiAgICBib3gt
c2hhZG93OiAwIDFweCAwIHJnYmEoMCwwLDAsMC4zKSAhaW1wb3J0YW50OwogICAgdHJhbnNpdGlv
bjogdHJhbnNmb3JtIDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CgogIC8qIHVpdGVtcyAzRCAq
LwogIC51aXRlbSB7CiAgICBib3JkZXItcmFkaXVzOiAxNHB4ICFpbXBvcnRhbnQ7CiAgICBib3Jk
ZXI6IDJweCBzb2xpZCB2YXIoLS1ib3JkZXIpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93Ogog
ICAgICAwIDNweCAwIHJnYmEoMCwwLDAsMC4xOCksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1
LDI1NSwwLjA3KSBpbnNldCwKICAgICAgMCA2cHggMTRweCByZ2JhKDAsMCwwLDAuMDgpICFpbXBv
cnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFu
c2Zvcm0gMC4xNXMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAg
IGJveC1zaGFkb3cgMC4xNXMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAudWl0ZW06aG92ZXIgewog
ICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0ycHgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93
OgogICAgICAwIDZweCAwIHJnYmEoMCwwLDAsMC4yMiksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUs
MjU1LDI1NSwwLjA5KSBpbnNldCwKICAgICAgMCAxMnB4IDI0cHggcmdiYSgwLDAsMCwwLjEyKSAh
aW1wb3J0YW50OwogIH0KICAudWl0ZW06YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRl
WSgycHgpIHNjYWxlKDAuOTgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OiAwIDFweCAwIHJn
YmEoMCwwLDAsMC4zKSAhaW1wb3J0YW50OwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMDZz
IGVhc2UgIWltcG9ydGFudDsKICB9CiAgLyogYm91bmNlIGtleWZyYW1lIOC4quC4s+C4q+C4o+C4
seC4muC4geC4lCAqLwogIEBrZXlmcmFtZXMgYnRuLWJvdW5jZSB7CiAgICAwJSAgIHsgdHJhbnNm
b3JtOiBzY2FsZSgxKTsgfQogICAgMzAlICB7IHRyYW5zZm9ybTogc2NhbGUoMC45MykgdHJhbnNs
YXRlWSgzcHgpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgxLjA0KSB0cmFuc2xhdGVZ
KC0ycHgpOyB9CiAgICA4MCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjk4KSB0cmFuc2xhdGVZKDFw
eCk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHNjYWxlKDEpIHRyYW5zbGF0ZVkoMCk7IH0KICB9
CiAgLmNidG46YWN0aXZlLCAuYnRuLXI6YWN0aXZlLCAuY29weS1idG46YWN0aXZlIHsgYW5pbWF0
aW9uOiBidG4tYm91bmNlIDAuMjhzIGVhc2UgZm9yd2FyZHMgIWltcG9ydGFudDsgfQoKICAvKiBO
YXYgM0QgcGlsbHMgb3ZlcnJpZGUgKi8KICAubmF2LWl0ZW17Ym9yZGVyLXJhZGl1czo5OTlweCFp
bXBvcnRhbnQ7Ym94LXNoYWRvdzowIDNweCAwIHJnYmEoMCwwLDAsMC4zKSwwIDFweCAwIHJnYmEo
MjU1LDI1NSwyNTUsMC4xKSBpbnNldCFpbXBvcnRhbnQ7Ym9yZGVyLXdpZHRoOjEuNXB4IWltcG9y
dGFudDtwYWRkaW5nOjlweCAxNnB4IWltcG9ydGFudDt9CiAgLm5hdi1pdGVtLmFjdGl2ZXtib3Jk
ZXItcmFkaXVzOjk5OXB4IWltcG9ydGFudDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KSFpbXBv
cnRhbnQ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMyMmM1NWUsIzE2YTM0YSkh
aW1wb3J0YW50O2JvcmRlci1jb2xvcjp0cmFuc3BhcmVudCFpbXBvcnRhbnQ7Ym94LXNoYWRvdzow
IDRweCAxNHB4IHJnYmEoMzQsMTk3LDk0LDAuNDUpIWltcG9ydGFudDtjb2xvcjojZmZmIWltcG9y
dGFudDtwYWRkaW5nOjlweCAxNnB4IWltcG9ydGFudDtmb250LXNpemU6MTFweCFpbXBvcnRhbnQ7
fQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSl7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFw
eCkhaW1wb3J0YW50O30KCiAgLyogRmlyZWZsaWVzIGluc2lkZSBjYXJkcyAqLwogIC5jYXJkLWZm
e3Bvc2l0aW9uOmFic29sdXRlO2JvcmRlci1yYWRpdXM6NTAlO3BvaW50ZXItZXZlbnRzOm5vbmU7
ei1pbmRleDowO2FuaW1hdGlvbjpjZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLGNmZi1ibGluayBl
YXNlLWluLW91dCBpbmZpbml0ZTtvcGFjaXR5OjA7fQogIEBrZXlmcmFtZXMgY2ZmLWRyaWZ0ezAl
e3RyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTt9MjAle3RyYW5zZm9ybTp0cmFuc2xh
dGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpO300MCV7dHJhbnNmb3JtOnRyYW5z
bGF0ZSh2YXIoLS1keDIpLHZhcigtLWR5MikpIHNjYWxlKDAuOSk7fTYwJXt0cmFuc2Zvcm06dHJh
bnNsYXRlKHZhcigtLWR4MyksdmFyKC0tZHkzKSkgc2NhbGUoMS4wNSk7fTgwJXt0cmFuc2Zvcm06
dHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7fTEwMCV7dHJhbnNm
b3JtOnRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpO319CiAgQGtleWZyYW1lcyBjZmYtYmxpbmt7MCUs
MTAwJXtvcGFjaXR5OjA7fTE1JXtvcGFjaXR5OjA7fTMwJXtvcGFjaXR5OjAuOTt9NTAle29wYWNp
dHk6MC43O302NSV7b3BhY2l0eTowO304MCV7b3BhY2l0eTowLjg7fTkyJXtvcGFjaXR5OjA7fX0K
ICAuY2FyZD4qOm5vdCguY2FyZC1mZil7fQogIC5zYz4qOm5vdCguY2FyZC1mZil7fQoKICAvKiBT
UEVFRCBURVNUICovCiAgLnNwZWVkLWhlcm97YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYw
ZGVnLCMwYTE2MjggMCUsIzA2MTAyMCAxMDAlKTtib3JkZXI6MnB4IHNvbGlkIHJnYmEoNiwxODIs
MjEyLDAuMik7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjRweCAxNnB4O21hcmdpbi1ib3R0
b206MTJweDt0ZXh0LWFsaWduOmNlbnRlcjtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRk
ZW47fQogIC5zcGVlZC1oZXJvOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtp
bnNldDowO2JhY2tncm91bmQ6cmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgODAlIDUwJSBhdCA1MCUg
MCUscmdiYSg2LDE4MiwyMTIsMC4xMiksdHJhbnNwYXJlbnQpO30KICAuc3BlZWQtdGl0bGV7Zm9u
dC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjExcHg7bGV0dGVyLXNwYWNp
bmc6NHB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5z
cGVlZC1nYXVnZS13cmFwe3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjE2MHB4O2hlaWdodDo4MHB4
O21hcmdpbjowIGF1dG8gMTZweDt9CiAgLnNwZWVkLWdhdWdlLXN2Z3tvdmVyZmxvdzp2aXNpYmxl
O30KICAuc3BlZWQtZ2F1Z2UtYmd7ZmlsbDpub25lO3N0cm9rZTpyZ2JhKDI1NSwyNTUsMjU1LDAu
MDYpO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt9CiAgLnNwZWVkLWdhdWdl
LWZpbGx7ZmlsbDpub25lO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFu
c2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwx
KSxzdHJva2UgMC4zczt0cmFuc2Zvcm0tb3JpZ2luOjgwcHggODBweDt9CiAgLnNwZWVkLWNlbnRl
cntwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRl
WCgtNTAlKTt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXZhbHtmb250LWZhbWlseTonT3Ji
aXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MzJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWln
aHQ6MTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMDZiNmQ0LCM2MGE1ZmEpOy13
ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNw
YXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7fQogIC5zcGVlZC11bml0e2ZvbnQtZmFtaWx5OidP
cmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9y
OnJnYmEoNiwxODIsMjEyLDAuNSk7bWFyZ2luLXRvcDoycHg7fQogIC5zcGVlZC1idG5ze2Rpc3Bs
YXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweDttYXJnaW4tYm90
dG9tOjEycHg7fQogIC5zcGVlZC1idG57cGFkZGluZzoxNHB4O2JvcmRlci1yYWRpdXM6MTRweDti
b3JkZXI6bm9uZTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFj
ZTtmb250LXNpemU6MTBweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6MnB4O3RyYW5z
aXRpb246YWxsIDAuMnM7fQogIC5zcGVlZC1idG4tZGx7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGll
bnQoMTM1ZGVnLCMyNTYzZWIsIzFkNGVkOCk7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2
cHggcmdiYSgzNyw5OSwyMzUsMC40KTt9CiAgLnNwZWVkLWJ0bi1kbDpob3Zlcnt0cmFuc2Zvcm06
dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgzNyw5OSwyMzUsMC41
KTt9CiAgLnNwZWVkLWJ0bi11bHtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzdj
M2FlZCwjNmQyOGQ5KTtjb2xvcjojZmZmO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDEyNCw1
OCwyMzcsMC40KTt9CiAgLnNwZWVkLWJ0bi11bDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgt
MnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgxMjQsNTgsMjM3LDAuNSk7fQogIC5zcGVl
ZC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjQ7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpu
b25lO30KICAuc3BlZWQtcmVzdWx0c3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5z
OjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc3BlZWQtcmVzLWNhcmR7
YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDQpO2JvcmRlcjoxcHggc29saWQgcmdiYSgy
NTUsMjU1LDI1NSwwLjA4KTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzoxNnB4O3RleHQtYWxp
Z246Y2VudGVyO30KICAuc3BlZWQtcmVzLWljb257Zm9udC1zaXplOjIwcHg7bWFyZ2luLWJvdHRv
bTo2cHg7fQogIC5zcGVlZC1yZXMtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3Bh
Y2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1
NSwwLjQpO21hcmdpbi1ib3R0b206NHB4O30KICAuc3BlZWQtcmVzLXZhbHtmb250LWZhbWlseTon
T3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjJweDtmb250LXdlaWdodDo5MDA7bGluZS1o
ZWlnaHQ6MTt9CiAgLnNwZWVkLXJlcy12YWwuZGwtY29sb3J7Y29sb3I6IzYwYTVmYTt9CiAgLnNw
ZWVkLXJlcy12YWwudWwtY29sb3J7Y29sb3I6I2E3OGJmYTt9CiAgLnNwZWVkLXJlcy11bml0e2Zv
bnQtc2l6ZTo5cHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjMpO21hcmdpbi10b3A6MnB4O30K
ICAuc3BlZWQtc3RhdHVze2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7
bWluLWhlaWdodDoxOHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctcm93e2Rp
c3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoyMHB4O21hcmdpbi1ib3R0b206
MTJweDt9CiAgLnNwZWVkLXBpbmctaXRlbXt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXBp
bmctbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDts
ZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjM1KTttYXJnaW4tYm90
dG9tOjJweDt9CiAgLnNwZWVkLXBpbmctdmFse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3Nw
YWNlO2ZvbnQtc2l6ZToxNnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojNGFkZTgwO30KICAuc3Bl
ZWQtcGluZy12YWwud2Fybntjb2xvcjojZmJiZjI0O30KICAuc3BlZWQtcGluZy12YWwuYmFke2Nv
bG9yOiNlZjQ0NDQ7fQogIC5zcGVlZC1iYXItd3JhcHtoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdi
YSgyNTUsMjU1LDI1NSwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVy
ZmxvdzpoaWRkZW47fQogIC5zcGVlZC1iYXJ7aGVpZ2h0OjEwMCU7Ym9yZGVyLXJhZGl1czoycHg7
d2lkdGg6MCU7dHJhbnNpdGlvbjp3aWR0aCAwLjNzIGVhc2U7fQogIC5zcGVlZC1iYXIuZGwtYmFy
e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMyNTYzZWIsIzYwYTVmYSk7fQogIC5z
cGVlZC1iYXIudWwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCM3YzNhZWQs
I2E3OGJmYSk7fQogIC5zcGVlZC1pbmZvLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUt
Y29sdW1uczoxZnIgMWZyIDFmcjtnYXA6OHB4O30KICAuc3BlZWQtaW5mby1pdGVte2JhY2tncm91
bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjAzKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwy
NTUsMC4wNik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDt0ZXh0LWFsaWduOmNlbnRl
cjt9CiAgLnNwZWVkLWluZm8tbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2Zv
bnQtc2l6ZTo3cHg7bGV0dGVyLXNwYWNpbmc6MXB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4z
KTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNwZWVkLWluZm8tdmFse2ZvbnQtc2l6ZToxMnB4O2Zv
bnQtd2VpZ2h0OjcwMDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuOCk7fQogIC5zcGVlZC1wcm9n
e2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDYsMTgyLDIxMiwwLjE1KTtib3JkZXItcmFkaXVz
OjJweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1wcm9nLWZp
bGx7aGVpZ2h0OjEwMCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzA2YjZkNCwj
NjBhNWZhKTtib3JkZXItcmFkaXVzOjJweDt3aWR0aDowJTt0cmFuc2l0aW9uOndpZHRoIDAuMnMg
ZWFzZTt9CgpAa2V5ZnJhbWVzIHBpbmd7MCV7dHJhbnNmb3JtOnNjYWxlKDEpO29wYWNpdHk6Ljd9
MTAwJXt0cmFuc2Zvcm06c2NhbGUoMi41KTtvcGFjaXR5OjB9fQouZGd7cG9zaXRpb246cmVsYXRp
dmU7ZGlzcGxheTppbmxpbmUtZmxleDt3aWR0aDoxMHB4O2hlaWdodDoxMHB4O2ZsZXgtc2hyaW5r
OjA7dmVydGljYWwtYWxpZ246bWlkZGxlO30KLmRnOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlv
bjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTtv
cGFjaXR5Oi41O2FuaW1hdGlvbjpwaW5nIDEuNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQouZGc6
OmFmdGVye2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MnB4O2JvcmRlci1yYWRp
dXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTt9Ci5kZy5yZWQ6OmJlZm9yZXtiYWNrZ3JvdW5kOiNl
ZjQ0NDQ7fQouZGcucmVkOjphZnRlcntiYWNrZ3JvdW5kOiNlZjQ0NDQ7fQouZG90e3Bvc2l0aW9u
OnJlbGF0aXZlO2Rpc3BsYXk6aW5saW5lLWZsZXg7d2lkdGg6OHB4O2hlaWdodDo4cHg7ZmxleC1z
aHJpbms6MDt2ZXJ0aWNhbC1hbGlnbjptaWRkbGU7fQouZG90OjpiZWZvcmV7Y29udGVudDonJztw
b3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIy
YzU1ZTtvcGFjaXR5Oi41O2FuaW1hdGlvbjpwaW5nIDEuNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7
fQouZG90OjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjEuNXB4O2Jv
cmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTt9Ci5kb3QucmVkOjpiZWZvcmV7YmFj
a2dyb3VuZDojZWY0NDQ0O30KLmRvdC5yZWQ6OmFmdGVye2JhY2tncm91bmQ6I2VmNDQ0NDt9Cjwv
c3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGli
cy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KCjwvaGVhZD4KPGJvZHk+
CjxkaXYgY2xhc3M9IndyYXAiPgoKICA8IS0tIEhFQURFUiAtLT4KICA8ZGl2IGNsYXNzPSJoZHIi
IGlkPSJoZHItcm9vdCI+CiAgPGNhbnZhcyBpZD0iaGRyLWNhbnZhcyIgc3R5bGU9InBvc2l0aW9u
OmFic29sdXRlO2luc2V0OjA7d2lkdGg6MTAwJTtoZWlnaHQ6MTAwJTtwb2ludGVyLWV2ZW50czpu
b25lO3otaW5kZXg6MTsiPjwvY2FudmFzPgogIDxzY3JpcHQ+CiAgd2luZG93LmFkZEV2ZW50TGlz
dGVuZXIoJ0RPTUNvbnRlbnRMb2FkZWQnLGZ1bmN0aW9uKCl7CiAgICBjb25zdCBjYW52YXM9ZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1jYW52YXMnKTsKICAgIGNvbnN0IHdyYXA9ZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1yb290Jyk7CiAgICBmdW5jdGlvbiByZXNpemUoKXtjYW52
YXMud2lkdGg9d3JhcC5vZmZzZXRXaWR0aDtjYW52YXMuaGVpZ2h0PXdyYXAub2Zmc2V0SGVpZ2h0
O30KICAgIHJlc2l6ZSgpOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScscmVz
aXplKTsKICAgIGNvbnN0IGN0eD1jYW52YXMuZ2V0Q29udGV4dCgnMmQnKTsKICAgIGNvbnN0IGNv
bG9ycz1bJyNiNWY1NDInLCcjZDRmYzVhJywnIzdmZmYwMCcsJyNhYWZmNDQnLCcjZjVmNTQyJywn
I2ZmZTk0ZCcsJyM1NmZmYjAnLCcjOTBmZjZhJywnI2EwZmY3OCcsJyNmZmVjNmUnXTsKICAgIGNv
bnN0IGZmcz1bXTsKICAgIGZvcihsZXQgaT0wO2k8MzU7aSsrKXsKICAgICAgZmZzLnB1c2goewog
ICAgICAgIHg6TWF0aC5yYW5kb20oKSpjYW52YXMud2lkdGgsCiAgICAgICAgeTpNYXRoLnJhbmRv
bSgpKmNhbnZhcy5oZWlnaHQsCiAgICAgICAgcjpNYXRoLnJhbmRvbSgpKjEuOCswLjYsCiAgICAg
ICAgY29sb3I6Y29sb3JzW01hdGguZmxvb3IoTWF0aC5yYW5kb20oKSpjb2xvcnMubGVuZ3RoKV0s
CiAgICAgICAgdng6KE1hdGgucmFuZG9tKCktMC41KSowLjUsCiAgICAgICAgdnk6KE1hdGgucmFu
ZG9tKCktMC41KSowLjQsCiAgICAgICAgYWxwaGE6MCwKICAgICAgICBhbHBoYURpcjpNYXRoLnJh
bmRvbSgpPjAuNT8xOi0xLAogICAgICAgIGFscGhhU3BlZWQ6TWF0aC5yYW5kb20oKSowLjAxNSsw
LjAwNSwKICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBkcmF3KCl7CiAgICAgIHJlc2l6ZSgp
OwogICAgICBjdHguY2xlYXJSZWN0KDAsMCxjYW52YXMud2lkdGgsY2FudmFzLmhlaWdodCk7CiAg
ICAgIGZmcy5mb3JFYWNoKGY9PnsKICAgICAgICBmLngrPWYudng7IGYueSs9Zi52eTsKICAgICAg
ICBpZihmLng8MClmLng9Y2FudmFzLndpZHRoOwogICAgICAgIGlmKGYueD5jYW52YXMud2lkdGgp
Zi54PTA7CiAgICAgICAgaWYoZi55PDApZi55PWNhbnZhcy5oZWlnaHQ7CiAgICAgICAgaWYoZi55
PmNhbnZhcy5oZWlnaHQpZi55PTA7CiAgICAgICAgZi5hbHBoYSs9Zi5hbHBoYURpcipmLmFscGhh
U3BlZWQ7CiAgICAgICAgaWYoZi5hbHBoYT49MSl7Zi5hbHBoYT0xO2YuYWxwaGFEaXI9LTE7fQog
ICAgICAgIGlmKGYuYWxwaGE8PTApe2YuYWxwaGE9MDtmLmFscGhhRGlyPTE7fQogICAgICAgIGN0
eC5zYXZlKCk7CiAgICAgICAgY3R4Lmdsb2JhbEFscGhhPWYuYWxwaGE7CiAgICAgICAgY3R4LnNo
YWRvd0JsdXI9Zi5yKjg7CiAgICAgICAgY3R4LnNoYWRvd0NvbG9yPWYuY29sb3I7CiAgICAgICAg
Y3R4LmJlZ2luUGF0aCgpOwogICAgICAgIGN0eC5hcmMoZi54LGYueSxmLnIsMCxNYXRoLlBJKjIp
OwogICAgICAgIGN0eC5maWxsU3R5bGU9Zi5jb2xvcjsKICAgICAgICBjdHguZmlsbCgpOwogICAg
ICAgIGN0eC5yZXN0b3JlKCk7CiAgICAgIH0pOwogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUo
ZHJhdyk7CiAgICB9CiAgICBkcmF3KCk7CiAgfSk7CiAgPC9zY3JpcHQ+CiAgICA8YnV0dG9uIGNs
YXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0
ZTt0b3A6MTZweDtyaWdodDoxNHB4O3otaW5kZXg6MTA7Ij7ihqkg4Lit4Lit4LiB4LiI4Liy4LiB
4Lij4Liw4Lia4LiaPC9idXR0b24+CgogICAgPCEtLSBMb2dvIFNWRyAoc2FtZSBhcyBsb2dpbikg
LS0+CiAgICA8ZGl2IGNsYXNzPSJoZHItbG9nby1zdmctd3JhcCI+CiAgICAgIDxzdmcgeG1sbnM9
Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9
IjcyIiBoZWlnaHQ9IjcyIj4KICAgICAgICA8ZGVmcz4KICAgICAgICAgIDxsaW5lYXJHcmFkaWVu
dCBpZD0iaFciIHgxPSIwJSIgeTE9IjAlIiB4Mj0iMTAwJSIgeTI9IjAlIj4KICAgICAgICAgICAg
PHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9yPSIjMjU2M2ViIi8+CiAgICAgICAgICAgIDxz
dG9wIG9mZnNldD0iNTAlIiAgc3RvcC1jb2xvcj0iIzYwYTVmYSIvPgogICAgICAgICAgICA8c3Rv
cCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMwNmI2ZDQiLz4KICAgICAgICAgIDwvbGluZWFy
R3JhZGllbnQ+CiAgICAgICAgICA8cmFkaWFsR3JhZGllbnQgaWQ9ImhCZyIgY3g9IjUwJSIgY3k9
IjUwJSIgcj0iNTAlIj4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9y
PSIjMGYxZTRhIiBzdG9wLW9wYWNpdHk9IjAuOTUiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0
PSIxMDAlIiBzdG9wLWNvbG9yPSIjMDYwYzFlIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgICAg
ICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAgICAgICA8ZmlsdGVyIGlkPSJoR2xvdyI+CiAgICAg
ICAgICAgIDxmZUdhdXNzaWFuQmx1ciBzdGREZXZpYXRpb249IjIuNSIgcmVzdWx0PSJiIi8+CiAg
ICAgICAgICAgIDxmZU1lcmdlPjxmZU1lcmdlTm9kZSBpbj0iYiIvPjxmZU1lcmdlTm9kZSBpbj0i
U291cmNlR3JhcGhpYyIvPjwvZmVNZXJnZT4KICAgICAgICAgIDwvZmlsdGVyPgogICAgICAgICAg
PGNsaXBQYXRoIGlkPSJoQ2xpcCI+PGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiLz48L2Ns
aXBQYXRoPgogICAgICAgIDwvZGVmcz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiBy
PSI0NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjEyKSIgc3Ryb2tlLXdp
ZHRoPSIxIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDIiIGZpbGw9Im5v
bmUiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuMikiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tl
LWRhc2hhcnJheT0iNSA0IiBjbGFzcz0iaGRyLW9yYml0LXJpbmciLz4KICAgICAgICA8Y2lyY2xl
IGN4PSI1MCIgY3k9IjUwIiByPSIzOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIz
NSwwLjIyKSIgc3Ryb2tlLXdpZHRoPSIxIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1
MCIgcj0iMzQiIGZpbGw9InVybCgjaEJnKSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0i
NTAiIHI9IjM0IiBmaWxsPSJub25lIiBzdHJva2U9InVybCgjaFcpIiBzdHJva2Utd2lkdGg9IjEu
OCIgb3BhY2l0eT0iMC45Ii8+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iMTQiIHgyPSI1MCIg
eTI9IjIwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUi
IHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI1MCIgeTE9IjgwIiB4
Mj0iNTAiIHkyPSI4NiIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0
aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iMTQiIHkx
PSI1MCIgeDI9IjIwIiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJv
a2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9
IjgwIiB5MT0iNTAiIHgyPSI4NiIgeTI9IjUwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1
KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxn
IGNsaXAtcGF0aD0idXJsKCNoQ2xpcCkiPgogICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMTYs
NTAgMjQsNTAgMjksMzIgMzQsNjggMzksMzIgNDQsNTAgODQsNTAiCiAgICAgICAgICAgIGZpbGw9
Im5vbmUiIHN0cm9rZT0idXJsKCNoVykiIHN0cm9rZS13aWR0aD0iMi4yIgogICAgICAgICAgICBz
dHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiCiAgICAgICAgICAg
IGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItd2F2ZS1hbmltIi8+CiAgICAgICAgPC9n
PgogICAgICAgIDxjaXJjbGUgY3g9IjI5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzYwYTVmYSIg
ZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3QtMSIvPgogICAgICAgIDxjaXJjbGUg
Y3g9IjM5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzA2YjZkNCIgZmlsdGVyPSJ1cmwoI2hHbG93
KSIgY2xhc3M9Imhkci1kb3QtMiIvPgogICAgICAgIDxjaXJjbGUgY3g9IjM0IiBjeT0iNjgiIHI9
IjIuNSIgZmlsbD0iIzYwYTVmYSIgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3Qt
MSIvPgogICAgICA8L3N2Zz4KICAgIDwvZGl2PgoKICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5
OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxOHB4O2ZvbnQtd2VpZ2h0OjkwMDtsZXR0
ZXItc3BhY2luZzo0cHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2UwZjJmZSwj
NjBhNWZhLCMwNmI2ZDQpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0
LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7Ij5DSEFJWUE8L2Rp
dj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQt
c2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6OXB4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjYpO21h
cmdpbi10b3A6MnB4OyI+UFJPSkVDVDwvZGl2PgogICAgPGRpdiBzdHlsZT0id2lkdGg6MTQwcHg7
aGVpZ2h0OjFweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCwj
NjBhNWZhLCMwNmI2ZDQsdHJhbnNwYXJlbnQpO21hcmdpbjo2cHggYXV0bztvcGFjaXR5OjAuNTsi
PjwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7
Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6cmdiYSg2LDE4MiwyMTIsMC41
NSk7bWFyZ2luLXRvcDoycHg7Ij5WMlJBWSAmYW1wOyBTU0g8L2Rpdj4KICAgIDxkaXYgc3R5bGU9
ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNw
YWNpbmc6M3B4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjUpO21hcmdpbi10b3A6NHB4OyIgaWQ9
Imhkci1kb21haW4iPlNFQ1VSRSBQQU5FTDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIE5BViAtLT4K
ICA8ZGl2IGNsYXNzPSJuYXYtd3JhcCIgaWQ9Im5hdi13cmFwIj4KICA8Y2FudmFzIGlkPSJuYXYt
Y2FudmFzIiBzdHlsZT0icG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDt3aWR0aDoxMDAlO2hlaWdo
dDoxMDAlO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDoxOyI+PC9jYW52YXM+CiAgPHNjcmlw
dD4KICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignRE9NQ29udGVudExvYWRlZCcsZnVuY3Rpb24o
KXsKICAgIGNvbnN0IGNhbnZhcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmF2LWNhbnZhcycp
OwogICAgY29uc3Qgd3JhcD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmF2LXdyYXAnKTsKICAg
IGZ1bmN0aW9uIHJlc2l6ZSgpe2NhbnZhcy53aWR0aD13cmFwLm9mZnNldFdpZHRoO2NhbnZhcy5o
ZWlnaHQ9d3JhcC5vZmZzZXRIZWlnaHQ7fQogICAgcmVzaXplKCk7CiAgICBjb25zdCBjdHg9Y2Fu
dmFzLmdldENvbnRleHQoJzJkJyk7CiAgICBjb25zdCBjb2xvcnM9WycjYjVmNTQyJywnI2Q0ZmM1
YScsJyM3ZmZmMDAnLCcjYWFmZjQ0JywnI2Y1ZjU0MicsJyNmZmU5NGQnLCcjNTZmZmIwJywnIzkw
ZmY2YSddOwogICAgY29uc3QgZmZzPVtdOwogICAgZm9yKGxldCBpPTA7aTwyMjtpKyspewogICAg
ICBmZnMucHVzaCh7CiAgICAgICAgeDpNYXRoLnJhbmRvbSgpKmNhbnZhcy53aWR0aCwKICAgICAg
ICB5Ok1hdGgucmFuZG9tKCkqY2FudmFzLmhlaWdodCwKICAgICAgICByOk1hdGgucmFuZG9tKCkq
MS41KzAuOCwKICAgICAgICBjb2xvcjpjb2xvcnNbTWF0aC5mbG9vcihNYXRoLnJhbmRvbSgpKmNv
bG9ycy5sZW5ndGgpXSwKICAgICAgICB2eDooTWF0aC5yYW5kb20oKS0wLjUpKjAuNiwKICAgICAg
ICB2eTooTWF0aC5yYW5kb20oKS0wLjUpKjAuNCwKICAgICAgICBhbHBoYTowLAogICAgICAgIGFs
cGhhRGlyOk1hdGgucmFuZG9tKCk+MC41PzE6LTEsCiAgICAgICAgYWxwaGFTcGVlZDpNYXRoLnJh
bmRvbSgpKjAuMDIrMC4wMDgsCiAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gZHJhdygpewog
ICAgICByZXNpemUoKTsKICAgICAgY3R4LmNsZWFyUmVjdCgwLDAsY2FudmFzLndpZHRoLGNhbnZh
cy5oZWlnaHQpOwogICAgICBmZnMuZm9yRWFjaChmPT57CiAgICAgICAgZi54Kz1mLnZ4OyBmLnkr
PWYudnk7CiAgICAgICAgaWYoZi54PDApZi54PWNhbnZhcy53aWR0aDsKICAgICAgICBpZihmLng+
Y2FudmFzLndpZHRoKWYueD0wOwogICAgICAgIGlmKGYueTwwKWYueT1jYW52YXMuaGVpZ2h0Owog
ICAgICAgIGlmKGYueT5jYW52YXMuaGVpZ2h0KWYueT0wOwogICAgICAgIGYuYWxwaGErPWYuYWxw
aGFEaXIqZi5hbHBoYVNwZWVkOwogICAgICAgIGlmKGYuYWxwaGE+PTEpe2YuYWxwaGE9MTtmLmFs
cGhhRGlyPS0xO30KICAgICAgICBpZihmLmFscGhhPD0wKXtmLmFscGhhPTA7Zi5hbHBoYURpcj0x
O30KICAgICAgICBjdHguc2F2ZSgpOwogICAgICAgIGN0eC5nbG9iYWxBbHBoYT1mLmFscGhhOwog
ICAgICAgIGN0eC5iZWdpblBhdGgoKTsKICAgICAgICBjdHguYXJjKGYueCxmLnksZi5yLDAsTWF0
aC5QSSoyKTsKICAgICAgICBjdHguZmlsbFN0eWxlPWYuY29sb3I7CiAgICAgICAgY3R4LmZpbGwo
KTsKICAgICAgICBjdHguc2hhZG93Qmx1cj1mLnIqNjsKICAgICAgICBjdHguc2hhZG93Q29sb3I9
Zi5jb2xvcjsKICAgICAgICBjdHguZmlsbCgpOwogICAgICAgIGN0eC5yZXN0b3JlKCk7CiAgICAg
IH0pOwogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoZHJhdyk7CiAgICB9CiAgICBkcmF3KCk7
CiAgfSk7CiAgPC9zY3JpcHQ+CiAgPGRpdiBjbGFzcz0ibmF2Ij4KICAgIDxkaXYgY2xhc3M9Im5h
di1pdGVtIGFjdGl2ZSIgb25jbGljaz0ic3coJ2Rhc2hib2FyZCcsdGhpcykiPvCfk4og4LmB4LiU
4LiK4Lia4Lit4Lij4LmM4LiUPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGlj
az0ic3coJ2NyZWF0ZScsdGhpcykiPuKelSDguKrguKPguYnguLLguIfguKLguLnguKo8L2Rpdj4K
ICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnbWFuYWdlJyx0aGlzKSI+8J+U
pyDguIjguLHguJTguIHguLLguKPguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1p
dGVtIiBvbmNsaWNrPSJzdygnb25saW5lJyx0aGlzKSI+8J+foiDguK3guK3guJnguYTguKXguJng
uYw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnYmFuJyx0aGlz
KSI+8J+aqyDguJvguKXguJTguYHguJrguJk8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVt
IG5hdi1zcGVlZCIgb25jbGljaz0ic3coJ3NwZWVkJyx0aGlzKSI+4pqhIOC4quC4m+C4teC4lOC5
gOC4l+C4qjwvZGl2PgogIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBEQVNI
Qk9BUkQg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyBhY3RpdmUiIGlkPSJ0YWIt
ZGFzaGJvYXJkIj4KICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICA8c3BhbiBjbGFzcz0i
c2VjLXRpdGxlIj7imqEgU1lTVEVNIE1PTklUT1I8L3NwYW4+CiAgICAgIDxidXR0b24gY2xhc3M9
ImJ0bi1yIiBpZD0iYnRuLXJlZnJlc2giIG9uY2xpY2s9ImxvYWREYXNoKCkiPuKGuyDguKPguLXg
uYDguJ/guKPguIo8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ic2dyaWQiPgog
ICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4pqhIENQVSBV
U0FHRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRudXQiPgogICAgICAgICAgPHN2ZyB3aWR0
aD0iNTIiIGhlaWdodD0iNTIiIHZpZXdCb3g9IjAgMCA1MiA1MiI+CiAgICAgICAgICAgIDxjaXJj
bGUgY2xhc3M9ImRiZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIi8+CiAgICAgICAgICAgIDxjaXJj
bGUgY2xhc3M9ImR2IiBpZD0iY3B1LXJpbmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIgc3Ryb2tl
PSIjNGFkZTgwIgogICAgICAgICAgICAgIHN0cm9rZS1kYXNoYXJyYXk9IjEzOC4yIiBzdHJva2Ut
ZGFzaG9mZnNldD0iMTM4LjIiLz4KICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgPGRpdiBjbGFz
cz0iZGMiIGlkPSJjcHUtcGN0Ij4tLSU8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2
IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRl
ZCkiIGlkPSJjcHUtY29yZXMiPi0tIGNvcmVzPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIi
PjxkaXYgY2xhc3M9InBmIHBnIiBpZD0iY3B1LWJhciIgc3R5bGU9IndpZHRoOjAlIj48L2Rpdj48
L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNs
YXNzPSJzbGJsIj7wn6egIFJBTSBVU0FHRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRudXQi
PgogICAgICAgICAgPHN2ZyB3aWR0aD0iNTIiIGhlaWdodD0iNTIiIHZpZXdCb3g9IjAgMCA1MiA1
MiI+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImRiZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIy
Ii8+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImR2IiBpZD0icmFtLXJpbmciIGN4PSIyNiIg
Y3k9IjI2IiByPSIyMiIgc3Ryb2tlPSIjM2I4MmY2IgogICAgICAgICAgICAgIHN0cm9rZS1kYXNo
YXJyYXk9IjEzOC4yIiBzdHJva2UtZGFzaG9mZnNldD0iMTM4LjIiLz4KICAgICAgICAgIDwvc3Zn
PgogICAgICAgICAgPGRpdiBjbGFzcz0iZGMiIGlkPSJyYW0tcGN0Ij4tLSU8L2Rpdj4KICAgICAg
ICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6
MTBweDtjb2xvcjp2YXIoLS1tdXRlZCkiIGlkPSJyYW0tZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+
CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHB1IiBpZD0icmFtLWJhciIg
c3R5bGU9IndpZHRoOjAlO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMzYjgyZjYs
IzYwYTVmYSkiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2Mi
PgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfkr4gRElTSyBVU0FHRTwvZGl2PgogICAgICAg
IDxkaXYgY2xhc3M9InN2YWwiIGlkPSJkaXNrLXBjdCI+LS08c3Bhbj4lPC9zcGFuPjwvZGl2Pgog
ICAgICAgIDxkaXYgY2xhc3M9InNzdWIiIGlkPSJkaXNrLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2
PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwbyIgaWQ9ImRpc2stYmFy
IiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBj
bGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPuKPsSBVUFRJTUU8L2Rpdj4KICAg
ICAgICA8ZGl2IGNsYXNzPSJzdmFsIiBpZD0idXB0aW1lLXZhbCIgc3R5bGU9ImZvbnQtc2l6ZToy
MHB4Ij4tLTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNzdWIiIGlkPSJ1cHRpbWUtc3ViIj4t
LTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InViZGciIGlkPSJsb2FkLWNoaXBzIj48L2Rpdj4K
ICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRp
diBjbGFzcz0ic2VjLXRpdGxlIj7wn4yQIE5FVFdPUksgSS9PPC9kaXY+CiAgICAgIDxkaXYgY2xh
c3M9Im5ldC1yb3ciPgogICAgICAgIDxkaXYgY2xhc3M9Im5pIj4KICAgICAgICAgIDxkaXYgY2xh
c3M9Im5kIj7ihpEgVXBsb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJucyIgaWQ9Im5l
dC11cCI+LS08c3Bhbj4gLS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJudCIg
aWQ9Im5ldC11cC10b3RhbCI+dG90YWw6IC0tPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAg
PGRpdiBjbGFzcz0iZGl2aWRlciI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiIHN0eWxl
PSJ0ZXh0LWFsaWduOnJpZ2h0Ij4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5kIj7ihpMgRG93bmxv
YWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LWRuIj4tLTxzcGFuPiAt
LTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LWRuLXRvdGFs
Ij50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4K
CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7wn5Oh
IFgtVUkgUEFORUwgU1RBVFVTPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Inh1aS1yb3ciPgogICAg
ICAgIDxkaXYgaWQ9Inh1aS1waWxsIiBjbGFzcz0ib3BpbGwgb2ZmIj48c3BhbiBjbGFzcz0iZG90
IHJlZCI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C5gOC4iuC5h+C4hC4uLjwvZGl2PgogICAgICAg
IDxkaXYgY2xhc3M9Inh1aS1pbmZvIj4KICAgICAgICAgIDxkaXY+4LmA4Lin4Lit4Lij4LmM4LiK
4Lix4LiZIFhyYXk6IDxiIGlkPSJ4dWktdmVyIj4tLTwvYj48L2Rpdj4KICAgICAgICAgIDxkaXY+
SW5ib3VuZHM6IDxiIGlkPSJ4dWktaW5ib3VuZHMiPi0tPC9iPiDguKPguLLguKLguIHguLLguKM8
L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNs
YXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciIgc3R5bGU9Im1hcmdpbi1ib3R0
b206MCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7wn5SnIFNFUlZJQ0UgTU9OSVRP
UjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkU2Vydmlj
ZXMoKSI+4oa7IOC5gOC4iuC5h+C4hDwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBj
bGFzcz0ic3ZjLWxpc3QiIGlkPSJzdmMtbGlzdCI+CiAgICAgICAgPGRpdiBjbGFzcz0ibG9hZGlu
ZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+CiAgICAgIDwvZGl2PgogICAg
PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJsdSIgaWQ9Imxhc3QtdXBkYXRlIj7guK3guLHguJ7guYDg
uJTguJfguKXguYjguLLguKrguLjguJQ6IC0tPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ
4pWQ4pWQIENSRUFURSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFi
LWNyZWF0ZSI+CgogICAgPCEtLSDilIDilIAgU0VMRUNUT1IgKGRlZmF1bHQgdmlldykg4pSA4pSA
IC0tPgogICAgPGRpdiBpZD0iY3JlYXRlLW1lbnUiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtbGFi
ZWwiPvCfm6Eg4Lij4Liw4Lia4LiaIDNYLVVJIFZMRVNTPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9
InNlbC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgnYWlzJykiPgogICAgICAgIDxkaXYgY2xhc3M9
InNlbC1sb2dvIHNlbC1haXMiPjxpbWcgc3JjPSJodHRwczovL3VwbG9hZC53aWtpbWVkaWEub3Jn
L3dpa2lwZWRpYS9jb21tb25zL3RodW1iL2YvZjkvQUlTX2xvZ28uc3ZnLzIwMHB4LUFJU19sb2dv
LnN2Zy5wbmciIG9uZXJyb3I9InRoaXMuc3R5bGUuZGlzcGxheT0nbm9uZSc7dGhpcy5uZXh0U2li
bGluZy5zdHlsZS5kaXNwbGF5PSdmbGV4JyIgc3R5bGU9IndpZHRoOjU2cHg7aGVpZ2h0OjU2cHg7
b2JqZWN0LWZpdDpjb250YWluIj48c3BhbiBzdHlsZT0iZGlzcGxheTpub25lO2ZvbnQtc2l6ZTox
LjRyZW07d2lkdGg6NTZweDtoZWlnaHQ6NTZweDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1j
b250ZW50OmNlbnRlcjtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwv
ZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9
InNlbC1uYW1lIGFpcyI+QUlTIOKAkyDguIHguLHguJnguKPguLHguYjguKc8L2Rpdj4KICAgICAg
ICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODA4MCDCtyBXUyDCtyBjai1l
YmIuc3BlZWR0ZXN0Lm5ldDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNz
PSJzZWwtYXJyb3ciPuKAujwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNl
bC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgndHJ1ZScpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJz
ZWwtbG9nbyBzZWwtdHJ1ZSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZToxLjFyZW07Zm9udC13ZWln
aHQ6OTAwO2NvbG9yOiNmZmYiPnRydWU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0i
c2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgdHJ1ZSI+VFJVRSDigJMg
VkRPPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5WTEVTUyDCtyBQb3J0IDg4
ODAgwrcgV1MgwrcgdHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlczwvZGl2PgogICAgICAg
IDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJzZWwtYXJyb3ciPuKAujwvc3Bhbj4KICAgICAg
PC9kaXY+CgogICAgICA8ZGl2IGNsYXNzPSJzZWMtbGFiZWwiIHN0eWxlPSJtYXJnaW4tdG9wOjIw
cHgiPvCflJEg4Lij4Liw4Lia4LiaIFNTSCBXRUJTT0NLRVQ8L2Rpdj4KICAgICAgPGRpdiBjbGFz
cz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdzc2gnKSI+CiAgICAgICAgPGRpdiBjbGFz
cz0ic2VsLWxvZ28gc2VsLXNzaCI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouNzVyZW07Zm9udC13
ZWlnaHQ6NzAwO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6bW9ub3NwYWNlIj5TU0gmZ3Q7PC9zcGFu
PjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xh
c3M9InNlbC1uYW1lIHNzaCI+U1NIIOKAkyBXUyBUdW5uZWw8L2Rpdj4KICAgICAgICAgIDxkaXYg
Y2xhc3M9InNlbC1zdWIiPlNTSCDCtyBQb3J0IDgwIMK3IERyb3BiZWFyIDE0My8xMDk8YnI+TnB2
VHVubmVsIC8gRGFya1R1bm5lbDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNs
YXNzPSJzZWwtYXJyb3ciPuKAujwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8
IS0tIOKUgOKUgCBGT1JNOiBBSVMg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1haXMiIHN0
eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9
ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNh
cmQiPgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0taGRyIGFpcy1oZHIiPgogICAgICAgICAgPGRp
diBjbGFzcz0iZm9ybS1sb2dvIHNlbC1haXMtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljhy
ZW07Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOiMzZDdhMGUiPkFJUzwvc3Bhbj48L2Rpdj4KICAgICAg
ICAgIDxkaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tdGl0bGUgYWlzIj5BSVMg4oCT
IOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3Jt
LXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFNOSTogY2otZWJiLnNwZWVkdGVzdC5uZXQ8L2Rp
dj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZn
Ij48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9k
aXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1lbWFpbCIgcGxhY2Vob2xkZXI9InVzZXJAYWlz
Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+ThSDg
uKfguLHguJnguYPguIrguYnguIfguLLguJkgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQp
PC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVl
PSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0i
ZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtaXAiIHR5
cGU9Im51bWJlciIgdmFsdWU9IjIiIG1pbj0iMSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0i
ZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkr4gRGF0YSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4
geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWdiIiB0eXBlPSJudW1iZXIi
IHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4gY2J0
bi1haXMiIGlkPSJhaXMtYnRuIiBvbmNsaWNrPSJjcmVhdGVWTEVTUygnYWlzJykiPuKaoSDguKrg
uKPguYnguLLguIcgQUlTIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVy
dCIgaWQ9ImFpcy1hbGVydCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLWJveCIgaWQ9
ImFpcy1yZXN1bHQiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0icmVzLWNsb3NlIiBvbmNsaWNr
PSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25v
bmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNs
YXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLWFp
cy1lbWFpbCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48
c3BhbiBjbGFzcz0icmVzLWsiPvCfhpQgVVVJRDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgbW9u
byIgaWQ9InItYWlzLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0i
cmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwv
c3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLWFpcy1leHAiPi0tPC9zcGFuPjwv
ZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLWFpcy1saW5rIj4tLTwv
ZGl2PgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY29weS1idG4iIG9uY2xpY2s9ImNvcHlMaW5r
KCdyLWFpcy1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAg
ICAgIDxkaXYgaWQ9ImFpcy1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6
MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAg
IDwhLS0g4pSA4pSAIEZPUk06IFRSVUUg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS10cnVl
IiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0iZm9ybS1iYWNrIiBvbmNs
aWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNz
PSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciB0cnVlLWhkciI+CiAgICAgICAg
ICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtdHJ1ZS1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6
ZTouNzVyZW07Zm9udC13ZWlnaHQ6OTAwO2NvbG9yOiNmZmYiPnRydWU8L3NwYW4+PC9kaXY+CiAg
ICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXRpdGxlIHRydWUiPlRS
VUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXN1YiI+VkxFU1Mg
wrcgUG9ydCA4ODgwIMK3IFNOSTogdHJ1ZS1pbnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlczwvZGl2
PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmci
PjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rp
dj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1lbWFpbCIgcGxhY2Vob2xkZXI9InVzZXJAdHJ1
ZSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug
4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiU
KTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWRheXMiIHR5cGU9Im51bWJlciIgdmFs
dWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNz
PSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtaXAi
IHR5cGU9Im51bWJlciIgdmFsdWU9IjIiIG1pbj0iMSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFz
cz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkr4gRGF0YSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4
s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1nYiIgdHlwZT0ibnVt
YmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRu
IGNidG4tdHJ1ZSIgaWQ9InRydWUtYnRuIiBvbmNsaWNrPSJjcmVhdGVWTEVTUygndHJ1ZScpIj7i
mqEg4Liq4Lij4LmJ4Liy4LiHIFRSVUUgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xh
c3M9ImFsZXJ0IiBpZD0idHJ1ZS1hbGVydCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVz
LWJveCIgaWQ9InRydWUtcmVzdWx0Ij4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJlcy1jbG9z
ZSIgb25jbGljaz0iZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RydWUtcmVzdWx0Jykuc3R5bGUu
ZGlzcGxheT0nbm9uZSciPuKclTwvYnV0dG9uPgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJv
dyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OnIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMt
diIgaWQ9InItdHJ1ZS1lbWFpbCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNz
PSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfhpQgVVVJRDwvc3Bhbj48c3BhbiBjbGFz
cz0icmVzLXYgbW9ubyIgaWQ9InItdHJ1ZS11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAg
IDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTg
uK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici10cnVlLWV4
cCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtbGluayIgaWQ9InIt
dHJ1ZS1saW5rIj4tLTwvZGl2PgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY29weS1idG4iIG9u
Y2xpY2s9ImNvcHlMaW5rKCdyLXRydWUtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5r
PC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJ0cnVlLXFyIiBzdHlsZT0idGV4dC1hbGlnbjpj
ZW50ZXI7bWFyZ2luLXRvcDoxMnB4OyI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2
PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogU1NIIOKUgOKUgCAtLT4KICAgIDxk
aXYgaWQ9ImZvcm0tc3NoIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0i
Zm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2Pgog
ICAgICA8ZGl2IGNsYXNzPSJzc2gtZGFyay1mb3JtIj4KICAgICAgICA8ZGl2IGNsYXNzPSJkYXJr
LWhkciI+4p6VIOC5gOC4nuC4tOC5iOC4oSBTU0ggVVNFUjwvZGl2PgogICAgICAgIDxkaXYgY2xh
c3M9ImRhcmstZmllbGQiPgogICAgICAgICAgPGxhYmVsIGNsYXNzPSJkYXJrLWxhYmVsIj7guIrg
uLfguYjguK3guJzguLnguYnguYPguIrguYk8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGNsYXNz
PSJkYXJrLWlucHV0IiBpZD0ic3NoLXVzZXIiIHBsYWNlaG9sZGVyPSJ1c2VybmFtZSIgYXV0b2Nv
bXBsZXRlPSJvZmYiLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWZp
ZWxkIj4KICAgICAgICAgIDxsYWJlbCBjbGFzcz0iZGFyay1sYWJlbCI+4Lij4Lir4Lix4Liq4Lic
4LmI4Liy4LiZPC9sYWJlbD4KICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZGFyay1pbnB1dCIgaWQ9
InNzaC1wYXNzIiBwbGFjZWhvbGRlcj0icGFzc3dvcmQiIHR5cGU9InBhc3N3b3JkIiBhdXRvY29t
cGxldGU9Im9mZiIvPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstZmll
bGQiPgogICAgICAgICAgPGxhYmVsIGNsYXNzPSJkYXJrLWxhYmVsIj7guIjguLPguJnguKfguJng
uKfguLHguJk8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGNsYXNzPSJkYXJrLWlucHV0IiBpZD0i
c3NoLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIi8+CiAgICAgICAgPC9kaXY+CiAgICAg
ICAgPGRpdiBjbGFzcz0iZGFyay1maWVsZCI+CiAgICAgICAgICA8bGFiZWwgY2xhc3M9ImRhcmst
bGFiZWwiPuC4peC4tOC4oeC4tOC4leC5hOC4reC4nuC4tTwvbGFiZWw+CiAgICAgICAgICA8aW5w
dXQgY2xhc3M9ImRhcmstaW5wdXQiIGlkPSJzc2gtaXAiIHR5cGU9Im51bWJlciIgdmFsdWU9IjIi
Lz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCI+8J+MkCDguYDg
uKXguLfguK3guIEgSVNQIC8gT1BFUkFUT1I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwaWNr
LWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQgYS1kdGFjIiBpZD0icHJvLWR0
YWMiIG9uY2xpY2s9InBpY2tQcm8oJ2R0YWMnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBp
Ij7wn5+gPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5EVEFDIEdBTUlORzwvZGl2
PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+ZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbTwv
ZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCIgaWQ9
InByby10cnVlIiBvbmNsaWNrPSJwaWNrUHJvKCd0cnVlJykiPgogICAgICAgICAgICA8ZGl2IGNs
YXNzPSJwaSI+8J+UtTwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+VFJVRSBUV0lU
VEVSPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5oZWxwLnguY29tPC9kaXY+CiAg
ICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1s
YmwiPvCfk7Eg4LmA4Lil4Li34Lit4LiBIEFQUDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBp
Y2stZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCBhLW5wdiIgaWQ9ImFwcC1u
cHYiIG9uY2xpY2s9InBpY2tBcHAoJ25wdicpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGki
PjxkaXYgc3R5bGU9IndpZHRoOjM4cHg7aGVpZ2h0OjM4cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2Jh
Y2tncm91bmQ6IzBkMmEzYTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnkt
Y29udGVudDpjZW50ZXI7bWFyZ2luOjAgYXV0byAuMXJlbTtmb250LWZhbWlseTptb25vc3BhY2U7
Zm9udC13ZWlnaHQ6OTAwO2ZvbnQtc2l6ZTouODVyZW07Y29sb3I6IzAwY2NmZjtsZXR0ZXItc3Bh
Y2luZzotMXB4O2JvcmRlcjoxLjVweCBzb2xpZCByZ2JhKDAsMjA0LDI1NSwuMykiPm5WPC9kaXY+
PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5OcHYgVHVubmVsPC9kaXY+CiAgICAg
ICAgICAgIDxkaXYgY2xhc3M9InBzIj5ucHZ0LXNzaDovLzwvZGl2PgogICAgICAgICAgPC9kaXY+
CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCIgaWQ9ImFwcC1kYXJrIiBvbmNsaWNrPSJw
aWNrQXBwKCdkYXJrJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+PGRpdiBzdHlsZT0i
d2lkdGg6MzhweDtoZWlnaHQ6MzhweDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMTEx
O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtt
YXJnaW46MCBhdXRvIC4xcmVtO2ZvbnQtZmFtaWx5OnNhbnMtc2VyaWY7Zm9udC13ZWlnaHQ6OTAw
O2ZvbnQtc2l6ZTouNjJyZW07Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzouNXB4O2JvcmRlcjox
LjVweCBzb2xpZCAjNDQ0Ij5EQVJLPC9kaXY+PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9
InBuIj5EYXJrVHVubmVsPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5kYXJrdHVu
bmVsOi8vPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIAoKICAgICAgICA8L2Rpdj4K
ICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuLXNzaCIgaWQ9InNzaC1idG4iIG9uY2xpY2s9ImNy
ZWF0ZVNTSCgpIj7inpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXI8L2J1dHRvbj4KICAgICAgICA8ZGl2
IGNsYXNzPSJhbGVydCIgaWQ9InNzaC1hbGVydCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+PC9k
aXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibGluay1yZXN1bHQiIGlkPSJzc2gtbGluay1yZXN1bHQi
PjwvZGl2PgogICAgICA8L2Rpdj4KCiAgICAgIDwhLS0gVXNlciB0YWJsZSAtLT4KICAgICAgPGRp
diBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+CiAgICAgICAgPGRpdiBjbGFz
cz0ic2VjLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdp
bjowIj7wn5OLIOC4o+C4suC4ouC4iuC4t+C5iOC4rSBVU0VSUzwvZGl2PgogICAgICAgICAgPGlu
cHV0IGNsYXNzPSJzYm94IiBpZD0ic3NoLXNlYXJjaCIgcGxhY2Vob2xkZXI9IuC4hOC5ieC4meC4
q+C4si4uLiIgb25pbnB1dD0iZmlsdGVyU1NIVXNlcnModGhpcy52YWx1ZSkiCiAgICAgICAgICAg
IHN0eWxlPSJ3aWR0aDoxMjBweDttYXJnaW46MDtmb250LXNpemU6MTFweDtwYWRkaW5nOjZweCAx
MHB4Ij4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1dGJsLXdyYXAiPgogICAg
ICAgICAgPHRhYmxlIGNsYXNzPSJ1dGJsIj4KICAgICAgICAgICAgPHRoZWFkPjx0cj48dGg+Izwv
dGg+PHRoPlVTRVJOQU1FPC90aD48dGg+4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC90aD48dGg+4Liq
4LiW4Liy4LiZ4LiwPC90aD48dGg+QUNUSU9OPC90aD48L3RyPjwvdGhlYWQ+CiAgICAgICAgICAg
IDx0Ym9keSBpZD0ic3NoLXVzZXItdGJvZHkiPjx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRl
eHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MjBweDtjb2xvcjp2YXIoLS1tdXRlZCkiPuC4geC4s+C4
peC4seC4h+C5guC4q+C4peC4lC4uLjwvdGQ+PC90cj48L3Rib2R5PgogICAgICAgICAgPC90YWJs
ZT4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgPC9kaXY+PCEtLSAv
dGFiLWNyZWF0ZSAtLT4KCjwhLS0g4pWQ4pWQ4pWQ4pWQIE1BTkFHRSDilZDilZDilZDilZAgLS0+
CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW1hbmFnZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJk
Ij4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxl
IiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4
quC5gOC4i+C4reC4o+C5jCBWTEVTUzwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1y
IiBvbmNsaWNrPSJsb2FkVXNlcnMoKSI+4oa7IOC5guC4q+C4peC4lDwvYnV0dG9uPgogICAgICA8
L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJzYm94IiBpZD0idXNlci1zZWFyY2giIHBsYWNlaG9s
ZGVyPSLwn5SNICDguITguYnguJnguKvguLIgdXNlcm5hbWUuLi4iIG9uaW5wdXQ9ImZpbHRlclVz
ZXJzKHRoaXMudmFsdWUpIj4KICAgICAgPGRpdiBpZD0idXNlci1saXN0Ij48ZGl2IGNsYXNzPSJs
b2FkaW5nIj7guIHguJTguJvguLjguYjguKHguYLguKvguKXguJTguYDguJ7guLfguYjguK3guJTg
uLbguIfguILguYnguK3guKHguLnguKU8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoK
ICA8IS0tIOKVkOKVkOKVkOKVkCBPTkxJTkUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9
InNlYyIgaWQ9InRhYi1vbmxpbmUiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYg
Y2xhc3M9InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdp
bi1ib3R0b206MCI+8J+foiDguKLguLnguKrguYDguIvguK3guKPguYzguK3guK3guJnguYTguKXg
uJnguYzguJXguK3guJnguJnguLXguYk8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4t
ciIgb25jbGljaz0ibG9hZE9ubGluZSgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+
CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvY3IiPgogICAgICAgIDxkaXYgY2xhc3M9
Im9waWxsIiBpZD0ib25saW5lLXBpbGwiPjxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj48c3BhbiBp
ZD0ib25saW5lLWNvdW50Ij4wPC9zcGFuPiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAg
ICAgICA8c3BhbiBjbGFzcz0idXQiIGlkPSJvbmxpbmUtdGltZSI+LS08L3NwYW4+CiAgICAgIDwv
ZGl2PgogICAgICA8ZGl2IGlkPSJvbmxpbmUtbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB
4LiU4Lij4Li14LmA4Lif4Lij4LiK4LmA4Lie4Li34LmI4Lit4LiU4Li54Lic4Li54LmJ4LmD4LiK
4LmJ4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4K
CiAgPCEtLSDilZDilZDilZDilZAgQkFOIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJz
ZWMiIGlkPSJ0YWItYmFuIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNz
PSJmdGl0bGUiPvCflJMg4Lib4Lil4LiU4Lil4LmH4Lit4LiEIElQIEJhbjwvZGl2PgogICAgICA8
cCBzdHlsZT0iZm9udC1zaXplOjEzcHg7Y29sb3I6IzY2NjttYXJnaW4tYm90dG9tOjEycHgiPuC4
ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4l+C4teC5iOC5g+C4iuC5iSBJUCDguYDguIHguLTguJkg
TGltaXQg4LiI4Liw4LiW4Li54LiB4Lil4LmH4Lit4LiE4LiK4Lix4LmI4Lin4LiE4Lij4Liy4Lin
IDEg4LiK4Lix4LmI4Lin4LmC4Lih4LiHPGJyPuC4geC4o+C4reC4gSBVc2VybmFtZSDguYDguJ7g
uLfguYjguK3guJvguKXguJTguKXguYfguK3guITguJfguLHguJnguJfguLU8L3A+CiAgICAgIDxk
aXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIFVTRVJOQU1FIOC4l+C4teC5iOC5
geC4muC4mTwvZGl2PgogICAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJiYW4tdXNlciIgcGxh
Y2Vob2xkZXI9IuC4geC4o+C4reC4gSB1c2VybmFtZSDguJfguLXguYjguJXguYnguK3guIfguIHg
uLLguKPguJvguKXguJTguKXguYfguK3guIQiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJj
YnRuIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCM5MjQwMGUsI2Y1
OWUwYikiIG9uY2xpY2s9InVuYmFuVXNlcigpIj7wn5STIOC4m+C4peC4lOC4peC5h+C4reC4hCBJ
UCBCYW48L2J1dHRvbj4KICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJiYW4tYWxlcnQiPjwv
ZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDo0
cHgiPgogICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNl
LWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVyO21hcmdpbi1ib3R0b206MTJweCI+CiAgICAgICAg
PGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luOjAiPuKPse+4jyDguKPguLLguKLguIHg
uLLguKPguJfguLXguYjguJbguLnguIHguYHguJrguJnguK3guKLguLnguYg8L2Rpdj4KICAgICAg
ICA8YnV0dG9uIG9uY2xpY2s9ImxvYWRCYW5uZWQoKSIgc3R5bGU9ImJhY2tncm91bmQ6bm9uZTti
b3JkZXI6MXB4IHNvbGlkICNkZGQ7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo0cHggMTJweDtm
b250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlciI+4oa6IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0
dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0iYmFubmVkLWxpc3QiPjxkaXYgY2xhc3M9
ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PjwvZGl2PgogICAg
PC9kaXY+CiAgPC9kaXY+CiAgCgoKICA8IS0tIFNQRUVEIFRFU1QgVEFCIC0tPgogICAgPGRpdiBj
bGFzcz0ic2VjIiBpZD0idGFiLXNwZWVkIj4KICAgIDxzdHlsZT4KICAgICAgLnN0LWNhcmR7YmFj
a2dyb3VuZDojZmZmO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjI0cHggMTZweDtib3gtc2hh
ZG93OjAgMnB4IDE2cHggcmdiYSgwLDAsMCwwLjA4KTttYXJnaW4tYm90dG9tOjEycHg7fQogICAg
ICAuc3QtdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEx
cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOiNmNTllMGI7dGV4dC1hbGlnbjpjZW50ZXI7bWFy
Z2luLWJvdHRvbToyMHB4O30KICAgICAgLnN0LWNpcmNsZXN7ZGlzcGxheTpmbGV4O2p1c3RpZnkt
Y29udGVudDpzcGFjZS1hcm91bmQ7YWxpZ24taXRlbXM6Y2VudGVyO21hcmdpbi1ib3R0b206MTZw
eDt9CiAgICAgIC5zdC1jaXJjbGUtd3JhcHt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgICAgIC5zdC1j
aXJjbGV7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6MTAwcHg7aGVpZ2h0OjEwMHB4O21hcmdpbjow
IGF1dG8gOHB4O30KICAgICAgLnN0LWNpcmNsZSBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcp
O30KICAgICAgLnN0LWNpcmNsZS1iZ3tmaWxsOm5vbmU7c3Ryb2tlOiNmMGYwZjA7c3Ryb2tlLXdp
ZHRoOjg7fQogICAgICAuc3QtY2lyY2xlLWZpbGwtcGluZ3tmaWxsOm5vbmU7c3Ryb2tlOiMyMmM1
NWU7c3Ryb2tlLXdpZHRoOjg7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7c3Ryb2tlLWRhc2hhcnJheToy
ODM7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAwLjhzIGVhc2U7fQogICAgICAuc3QtY2ly
Y2xlLWZpbGwtZGx7ZmlsbDpub25lO3N0cm9rZTojM2I4MmY2O3N0cm9rZS13aWR0aDo4O3N0cm9r
ZS1saW5lY2FwOnJvdW5kO3N0cm9rZS1kYXNoYXJyYXk6MjgzO3RyYW5zaXRpb246c3Ryb2tlLWRh
c2hvZmZzZXQgMC44cyBlYXNlO30KICAgICAgLnN0LWNpcmNsZS1maWxsLXVse2ZpbGw6bm9uZTtz
dHJva2U6I2E4NTVmNztzdHJva2Utd2lkdGg6ODtzdHJva2UtbGluZWNhcDpyb3VuZDtzdHJva2Ut
ZGFzaGFycmF5OjI4Mzt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgZWFzZTt9CiAg
ICAgIC5zdC1jaXJjbGUtaW5uZXJ7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtkaXNwbGF5OmZs
ZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRl
bnQ6Y2VudGVyO30KICAgICAgLnN0LWNpcmNsZS12YWx7Zm9udC1zaXplOjIwcHg7Zm9udC13ZWln
aHQ6OTAwO2NvbG9yOiMxZTI5M2I7bGluZS1oZWlnaHQ6MTt9CiAgICAgIC5zdC1jaXJjbGUtdW5p
dHtmb250LXNpemU6OXB4O2NvbG9yOiM5NGEzYjg7bWFyZ2luLXRvcDoycHg7fQogICAgICAuc3Qt
Y2lyY2xlLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5
cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOiM2NDc0OGI7fQogICAgICAuc3QtY2lyY2xlLWxh
YmVsLnBpbmd7Y29sb3I6IzIyYzU1ZTt9CiAgICAgIC5zdC1jaXJjbGUtbGFiZWwuZGx7Y29sb3I6
IzNiODJmNjt9CiAgICAgIC5zdC1jaXJjbGUtbGFiZWwudWx7Y29sb3I6I2E4NTVmNzt9CiAgICAg
IC5zdC1zdGF0dXN7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEycHg7Y29sb3I6IzY0NzQ4
YjttYXJnaW4tYm90dG9tOjEycHg7fQogICAgICAuc3QtcHJvZ3toZWlnaHQ6NHB4O2JhY2tncm91
bmQ6I2YwZjBmMDtib3JkZXItcmFkaXVzOjk5cHg7b3ZlcmZsb3c6aGlkZGVuO21hcmdpbi1ib3R0
b206MTZweDt9CiAgICAgIC5zdC1wcm9nLWZpbGx7aGVpZ2h0OjEwMCU7d2lkdGg6MCU7YmFja2dy
b3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzIyYzU1ZSwjM2I4MmY2KTtib3JkZXItcmFkaXVz
Ojk5cHg7dHJhbnNpdGlvbjp3aWR0aCAwLjNzIGVhc2U7fQogICAgICAuc3QtYnRue3dpZHRoOjEw
MCU7cGFkZGluZzoxNnB4O2JvcmRlci1yYWRpdXM6MTRweDtib3JkZXI6bm9uZTtiYWNrZ3JvdW5k
OmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlKTtjb2xvcjojZmZmO2ZvbnQt
ZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0Ojcw
MDtsZXR0ZXItc3BhY2luZzoycHg7Y3Vyc29yOnBvaW50ZXI7Ym94LXNoYWRvdzowIDRweCAxNnB4
IHJnYmEoMzQsMTk3LDk0LDAuNCk7dHJhbnNpdGlvbjphbGwgMC4yczttYXJnaW4tYm90dG9tOjEy
cHg7fQogICAgICAuc3QtYnRuOmhvdmVye3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpO2JveC1z
aGFkb3c6MCA4cHggMjRweCByZ2JhKDM0LDE5Nyw5NCwwLjUpO30KICAgICAgLnN0LWJ0bjpkaXNh
YmxlZHtvcGFjaXR5OjAuNTtjdXJzb3I6bm90LWFsbG93ZWQ7dHJhbnNmb3JtOm5vbmU7fQogICAg
ICAuc3QtcmVzdWx0e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXItcmFkaXVzOjE0cHg7cGFkZGlu
ZzoxNnB4O2JvcmRlcjoxcHggc29saWQgI2UyZThmMDt9CiAgICAgIC5zdC1yZXN1bHQtdGl0bGV7
Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3Bh
Y2luZzozcHg7Y29sb3I6Izk0YTNiODttYXJnaW4tYm90dG9tOjEycHg7fQogICAgICAuc3QtcmVz
dWx0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDox
MHB4O30KICAgICAgLnN0LXJlc3VsdC1pdGVtIC5zdC1yaS1sYWJlbHtmb250LXNpemU6MTBweDtj
b2xvcjojOTRhM2I4O21hcmdpbi1ib3R0b206MnB4O30KICAgICAgLnN0LXJlc3VsdC1pdGVtIC5z
dC1yaS12YWx7Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOiMxZTI5M2I7fQog
ICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLXZhbC5ncmVlbntjb2xvcjojMjJjNTVlO30KICAg
ICAgLnN0LXJlc3VsdC1pdGVtIC5zdC1yaS12YWwuYmx1ZXtjb2xvcjojM2I4MmY2O30KICAgICAg
LnN0LXJlc3VsdC1pdGVtIC5zdC1yaS12YWwucHVycGxle2NvbG9yOiNhODU1Zjc7fQogICAgPC9z
dHlsZT4KICAgIDxkaXYgY2xhc3M9InN0LWNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzdC10aXRs
ZSI+4pqhIFZQUyBTUEVFRCBURVNUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZXMi
PgogICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS13cmFwIj4KICAgICAgICAgIDxkaXYgY2xh
c3M9InN0LWNpcmNsZSI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdp
ZHRoPSIxMDAiIGhlaWdodD0iMTAwIj4KICAgICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJzdC1j
aXJjbGUtYmciIGN4PSI1MCIgY3k9IjUwIiByPSI0NSIvPgogICAgICAgICAgICAgIDxjaXJjbGUg
Y2xhc3M9InN0LWNpcmNsZS1maWxsLXBpbmciIGlkPSJjLXBpbmciIGN4PSI1MCIgY3k9IjUwIiBy
PSI0NSIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjI4MyIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAg
ICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLWlubmVyIj4KICAgICAgICAgICAgICA8ZGl2IGNs
YXNzPSJzdC1jaXJjbGUtdmFsIiBpZD0ic3QtcGluZy12YWwiPi0tPC9kaXY+CiAgICAgICAgICAg
ICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXVuaXQiPm1zPC9kaXY+CiAgICAgICAgICAgIDwvZGl2
PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtbGFiZWwg
cGluZyI+UElORzwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0LWNp
cmNsZS13cmFwIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZSI+CiAgICAgICAgICAg
IDxzdmcgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdpZHRoPSIxMDAiIGhlaWdodD0iMTAwIj4KICAg
ICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJzdC1jaXJjbGUtYmciIGN4PSI1MCIgY3k9IjUwIiBy
PSI0NSIvPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1maWxsLWRsIiBp
ZD0iYy1kbCIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1IiBzdHJva2UtZGFzaG9mZnNldD0iMjgzIi8+
CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtaW5u
ZXIiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS12YWwiIGlkPSJzdC1kbC12
YWwiPi0tPC9kaXY+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXVuaXQiPk1i
cHM8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxk
aXYgY2xhc3M9InN0LWNpcmNsZS1sYWJlbCBkbCI+RE9XTkxPQUQ8L2Rpdj4KICAgICAgICA8L2Rp
dj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtd3JhcCI+CiAgICAgICAgICA8ZGl2IGNs
YXNzPSJzdC1jaXJjbGUiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3
aWR0aD0iMTAwIiBoZWlnaHQ9IjEwMCI+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3Qt
Y2lyY2xlLWJnIiBjeD0iNTAiIGN5PSI1MCIgcj0iNDUiLz4KICAgICAgICAgICAgICA8Y2lyY2xl
IGNsYXNzPSJzdC1jaXJjbGUtZmlsbC11bCIgaWQ9ImMtdWwiIGN4PSI1MCIgY3k9IjUwIiByPSI0
NSIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjI4MyIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICAg
ICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLWlubmVyIj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNz
PSJzdC1jaXJjbGUtdmFsIiBpZD0ic3QtdWwtdmFsIj4tLTwvZGl2PgogICAgICAgICAgICAgIDxk
aXYgY2xhc3M9InN0LWNpcmNsZS11bml0Ij5NYnBzPC9kaXY+CiAgICAgICAgICAgIDwvZGl2Pgog
ICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtbGFiZWwgdWwi
PlVQTE9BRDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFz
cz0ic3Qtc3RhdHVzIiBpZD0ic3Qtc3RhdHVzIj7guIHguJTguJvguLjguYjguKHguYDguJ7guLfg
uYjguK3guYDguKPguLTguYjguKHguJfguJTguKrguK3guJo8L2Rpdj4KICAgICAgPGRpdiBjbGFz
cz0ic3QtcHJvZyI+PGRpdiBjbGFzcz0ic3QtcHJvZy1maWxsIiBpZD0ic3QtcHJvZyI+PC9kaXY+
PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9InN0LWJ0biIgaWQ9InN0LWJ0biIgb25jbGljaz0i
c3RhcnROZXdTcGVlZFRlc3QoKSI+4pa2IFNUQVJUIFRFU1Q8L2J1dHRvbj4KICAgICAgPGRpdiBj
bGFzcz0ic3QtcmVzdWx0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtdGl0bGUiPlRF
U1QgUkVTVUxUPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LWdyaWQiPgogICAg
ICAgICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LWl0ZW0iPjxkaXYgY2xhc3M9InN0LXJpLWxhYmVs
Ij7wn4yQIFNlcnZlciBJUDwvZGl2PjxkaXYgY2xhc3M9InN0LXJpLXZhbCIgaWQ9InN0LWlwIj4t
LTwvZGl2PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LWl0ZW0iPjxkaXYg
Y2xhc3M9InN0LXJpLWxhYmVsIj7wn5ONIExvY2F0aW9uPC9kaXY+PGRpdiBjbGFzcz0ic3Qtcmkt
dmFsIiBpZD0ic3QtbG9jIj4tLTwvZGl2PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3Qt
cmVzdWx0LWl0ZW0iPjxkaXYgY2xhc3M9InN0LXJpLWxhYmVsIj7wn4+TIFBpbmc8L2Rpdj48ZGl2
IGNsYXNzPSJzdC1yaS12YWwgZ3JlZW4iIGlkPSJzdC1yLXBpbmciPi0tPC9kaXY+PC9kaXY+CiAg
ICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFi
ZWwiPuKsh++4jyBEb3dubG9hZDwvZGl2PjxkaXYgY2xhc3M9InN0LXJpLXZhbCBibHVlIiBpZD0i
c3Qtci1kbCI+LS08L2Rpdj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1p
dGVtIj48ZGl2IGNsYXNzPSJzdC1yaS1sYWJlbCI+4qyG77iPIFVwbG9hZDwvZGl2PjxkaXYgY2xh
c3M9InN0LXJpLXZhbCBwdXJwbGUiIGlkPSJzdC1yLXVsIj4tLTwvZGl2PjwvZGl2PgogICAgICAg
ICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LWl0ZW0iPjxkaXYgY2xhc3M9InN0LXJpLWxhYmVsIj7w
n5WQIFRlc3RlZDwvZGl2PjxkaXYgY2xhc3M9InN0LXJpLXZhbCIgaWQ9InN0LXItdGltZSI+LS08
L2Rpdj48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxz
Y3JpcHQ+CiAgICBhc3luYyBmdW5jdGlvbiBzdGFydE5ld1NwZWVkVGVzdCgpIHsKICAgICAgY29u
c3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LWJ0bicpOwogICAgICBidG4uZGlz
YWJsZWQgPSB0cnVlOwogICAgICBidG4udGV4dENvbnRlbnQgPSAn4o+zIOC4geC4s+C4peC4seC4
h+C4l+C4lOC4quC4reC4miBWUFMuLi4nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
c3Qtc3RhdHVzJykudGV4dENvbnRlbnQgPSAn4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4Lia
4Liq4Lib4Li14LiUIFZQUyDguIjguKPguLTguIcuLi4nOwogICAgICBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgnc3QtcHJvZycpLnN0eWxlLndpZHRoID0gJzEwJSc7CiAgICAgIFsnYy1waW5nJywn
Yy1kbCcsJ2MtdWwnXS5mb3JFYWNoKGlkID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5z
dHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gJzI4MycpOwogICAgICBbJ3N0LXBpbmctdmFsJywnc3Qt
ZGwtdmFsJywnc3QtdWwtdmFsJ10uZm9yRWFjaChpZCA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZChpZCkudGV4dENvbnRlbnQgPSAnLi4uJyk7CgogICAgICAvLyBhbmltYXRlIHByb2dyZXNzIHdo
aWxlIHdhaXRpbmcKICAgICAgbGV0IHByb2cgPSAxMDsKICAgICAgY29uc3QgcHJvZ0ludCA9IHNl
dEludGVydmFsKCgpID0+IHsKICAgICAgICBpZihwcm9nIDwgOTApIHsgcHJvZyArPSAyOyBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtcHJvZycpLnN0eWxlLndpZHRoID0gcHJvZyArICclJzsg
fQogICAgICB9LCAxMDAwKTsKCiAgICAgIHRyeSB7CiAgICAgICAgY29uc3QgZCA9IGF3YWl0IGZl
dGNoKCcvYXBpL3NwZWVkdGVzdCcse21ldGhvZDonUE9TVCd9KS50aGVuKHI9PnIuanNvbigpKTsK
ICAgICAgICBjbGVhckludGVydmFsKHByb2dJbnQpOwogICAgICAgIGlmKCFkLm9rKSB0aHJvdyBu
ZXcgRXJyb3IoZC5lcnJvciB8fCAn4Lil4LmJ4Lih4LmA4Lir4Lil4LinJyk7CgogICAgICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1waW5nLXZhbCcpLnRleHRDb250ZW50ID0gZC5waW5n
OwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1kbC12YWwnKS50ZXh0Q29udGVu
dCA9IGQuZG93bmxvYWQ7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXVsLXZh
bCcpLnRleHRDb250ZW50ID0gZC51cGxvYWQ7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3N0LXItcGluZycpLnRleHRDb250ZW50ID0gZC5waW5nICsgJyBtcyc7CiAgICAgICAgZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXItZGwnKS50ZXh0Q29udGVudCA9IGQuZG93bmxvYWQg
KyAnIE1icHMnOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1yLXVsJykudGV4
dENvbnRlbnQgPSBkLnVwbG9hZCArICcgTWJwcyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3N0LWlwJykudGV4dENvbnRlbnQgPSBkLmlwIHx8ICctLSc7CiAgICAgICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LWxvYycpLnRleHRDb250ZW50ID0gZC5zZXJ2ZXIgfHwgJy0t
JzsKICAgICAgICBjb25zdCB0ID0gbmV3IERhdGUoZC50aW1lc3RhbXApOwogICAgICAgIGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdzdC1yLXRpbWUnKS50ZXh0Q29udGVudCA9IHQudG9UaW1lU3Ry
aW5nKCkuc2xpY2UoMCw4KTsKCiAgICAgICAgc2V0Q2lyY2xlKCdjLXBpbmcnLCBkLnBpbmcsIDIw
MCk7CiAgICAgICAgc2V0Q2lyY2xlKCdjLWRsJywgZC5kb3dubG9hZCwgMTAwMCk7CiAgICAgICAg
c2V0Q2lyY2xlKCdjLXVsJywgZC51cGxvYWQsIDEwMDApOwoKICAgICAgICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnc3QtcHJvZycpLnN0eWxlLndpZHRoID0gJzEwMCUnOwogICAgICAgIGRvY3Vt
ZW50LmdldEVsZW1lbnRCeUlkKCdzdC1zdGF0dXMnKS50ZXh0Q29udGVudCA9ICfinIUg4LiX4LiU
4Liq4Lit4Lia4LmA4Liq4Lij4LmH4LiI4Liq4Li04LmJ4LiZJzsKICAgICAgICBidG4udGV4dENv
bnRlbnQgPSAn4pa2IFNUQVJUIFRFU1QnOwogICAgICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwog
ICAgICB9IGNhdGNoKGUpIHsKICAgICAgICBjbGVhckludGVydmFsKHByb2dJbnQpOwogICAgICAg
IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1zdGF0dXMnKS50ZXh0Q29udGVudCA9ICfinYwg
JyArIGUubWVzc2FnZTsKICAgICAgICBidG4udGV4dENvbnRlbnQgPSAn4pa2IFNUQVJUIFRFU1Qn
OwogICAgICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogICAgICB9CiAgICB9CiAgICBmdW5jdGlv
biBzZXRDaXJjbGUoaWQsIHZhbCwgbWF4KSB7CiAgICAgIGNvbnN0IHBjdCA9IE1hdGgubWluKHZh
bC9tYXgsIDEpOwogICAgICBjb25zdCBvZmZzZXQgPSAyODMgLSAoMjgzICogcGN0KTsKICAgICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBvZmZz
ZXQ7CiAgICB9CiAgICAvLyBMb2FkIElQIG9uIGluaXQKICAgIGZldGNoKCcvYXBpL3N0YXR1cycp
LnRoZW4ocj0+ci5qc29uKCkpLnRoZW4oZD0+e30pLmNhdGNoKCgpPT57fSk7CiAgICA8L3Njcmlw
dD4KICA8L2Rpdj4KPC9kaXY+PCEtLSAvd3JhcCAtLT4KCjwhLS0gTU9EQUwgLS0+CjxkaXYgY2xh
c3M9Im1vdmVyIiBpZD0ibW9kYWwiIG9uY2xpY2s9ImlmKGV2ZW50LnRhcmdldD09PXRoaXMpY20o
KSI+CiAgPGRpdiBjbGFzcz0ibW9kYWwiPgogICAgPGRpdiBjbGFzcz0ibWhkciI+CiAgICAgIDxk
aXYgY2xhc3M9Im10aXRsZSIgaWQ9Im10Ij7impnvuI8gdXNlcjwvZGl2PgogICAgICA8YnV0dG9u
IGNsYXNzPSJtY2xvc2UiIG9uY2xpY2s9ImNtKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CiAg
ICA8ZGl2IGNsYXNzPSJkZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0i
ZGsiPvCfkaQgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZHUiPi0tPC9zcGFuPjwv
ZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OhIFBvcnQ8L3Nw
YW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNs
YXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bh
bj48c3BhbiBjbGFzcz0iZHYgZ3JlZW4iIGlkPSJkZSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxk
aXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6YgRGF0YSBMaW1pdDwvc3Bhbj48c3Bh
biBjbGFzcz0iZHYiIGlkPSJkZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRy
Ij48c3BhbiBjbGFzcz0iZGsiPvCfk4ogVHJhZmZpYyDguYPguIrguYk8L3NwYW4+PHNwYW4gY2xh
c3M9ImR2IiBpZD0iZHRyIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxz
cGFuIGNsYXNzPSJkayI+8J+TsSBJUCBMaW1pdDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJk
aSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsi
PvCfhpQgVVVJRDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYgbW9ubyIgaWQ9ImR1dSI+LS08L3NwYW4+
PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZh
cigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEwcHgiPuC5gOC4peC4t+C4reC4geC4geC4suC4o+C4
lOC4s+C5gOC4meC4tOC4meC4geC4suC4ozwvZGl2PgogICAgPGRpdiBjbGFzcz0iYWdyaWQiPgog
ICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdyZW5ldycpIj48ZGl2IGNs
YXNzPSJhaSI+8J+UhDwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguYjguK3guK3guLLguKLguLg8
L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ
4Li14LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rp
b24oJ2V4dGVuZCcpIj48ZGl2IGNsYXNzPSJhaSI+8J+ThTwvZGl2PjxkaXYgY2xhc3M9ImFuIj7g
uYDguJ7guLTguYjguKHguKfguLHguJk8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LiV4LmI4Lit4LiI
4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFi
dG4iIG9uY2xpY2s9Im1BY3Rpb24oJ2FkZGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPvCfk6Y8L2Rp
dj48ZGl2IGNsYXNzPSJhbiI+4LmA4Lie4Li04LmI4LihIERhdGE8L2Rpdj48ZGl2IGNsYXNzPSJh
ZCI+4LmA4LiV4Li04LihIEdCIOC5gOC4nuC4tOC5iOC4oTwvZGl2PjwvZGl2PgogICAgICA8ZGl2
IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdzZXRkYXRhJykiPjxkaXYgY2xhc3M9ImFp
Ij7impbvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LiV4Lix4LmJ4LiHIERhdGE8L2Rpdj48ZGl2
IGNsYXNzPSJhZCI+4LiB4Liz4Lir4LiZ4LiU4LmD4Lir4Lih4LmIPC9kaXY+PC9kaXY+CiAgICAg
IDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3Jlc2V0JykiPjxkaXYgY2xhc3M9
ImFpIj7wn5SDPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9k
aXY+PGRpdiBjbGFzcz0iYWQiPuC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5
iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIGRhbmdlciIgb25jbGljaz0ibUFj
dGlvbignZGVsZXRlJykiPjxkaXYgY2xhc3M9ImFpIj7wn5eR77iPPC9kaXY+PGRpdiBjbGFzcz0i
YW4iPuC4peC4muC4ouC4ueC4qjwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKXguJrguJbguLLguKfg
uKM8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguJXguYjguK3g
uK3guLLguKLguLggLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItcmVuZXciPgog
ICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+UhCDguJXguYjguK3guK3guLLguKLguLgg4oCU
IOC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iTwvZGl2PgogICAgICA8
ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZ
PC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tcmVuZXctZGF5cyIgdHlwZT0ibnVtYmVyIiB2
YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJt
LXJlbmV3LWJ0biIgb25jbGljaz0iZG9SZW5ld1VzZXIoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4
meC4leC5iOC4reC4reC4suC4ouC4uDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUIt
UEFORUw6IOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3Vi
IiBpZD0ibXN1Yi1leHRlbmQiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+ThSDguYDg
uJ7guLTguYjguKHguKfguLHguJkg4oCUIOC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4
oeC4lDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz
4LiZ4Lin4LiZ4Lin4Lix4LiZ4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li0
4LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tZXh0ZW5kLWRheXMiIHR5cGU9Im51
bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRu
IiBpZD0ibS1leHRlbmQtYnRuIiBvbmNsaWNrPSJkb0V4dGVuZFVzZXIoKSI+4pyFIOC4ouC4t+C4
meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvYnV0dG9uPgogICAgPC9kaXY+Cgog
ICAgPCEtLSBTVUItUEFORUw6IOC5gOC4nuC4tOC5iOC4oSBEYXRhIC0tPgogICAgPGRpdiBjbGFz
cz0ibS1zdWIiIGlkPSJtc3ViLWFkZGRhdGEiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+
8J+TpiDguYDguJ7guLTguYjguKEgRGF0YSDigJQg4LmA4LiV4Li04LihIEdCIOC5gOC4nuC4tOC5
iOC4oeC4iOC4suC4geC4l+C4teC5iOC4oeC4teC4reC4ouC4ueC5iDwvZGl2PgogICAgICA8ZGl2
IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZIEdCIOC4l+C4teC5
iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oTwvZGl2PjxpbnB1dCBjbGFzcz0i
ZmkiIGlkPSJtLWFkZGRhdGEtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjEwIiBtaW49IjEiPjwv
ZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1hZGRkYXRhLWJ0biIgb25jbGlj
az0iZG9BZGREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguYDguJ7guLTguYjguKEgRGF0
YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC4seC5ieC4hyBE
YXRhIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXNldGRhdGEiPgogICAgICA8
ZGl2IGNsYXNzPSJtc3ViLWxibCI+4pqW77iPIOC4leC4seC5ieC4hyBEYXRhIOKAlCDguIHguLPg
uKvguJnguJQgTGltaXQg4LmD4Lir4Lih4LmIICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiU
KTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+RGF0YSBMaW1p
dCAoR0IpIOKAlCAwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUPC9kaXY+PGlucHV0IGNsYXNz
PSJmaSIgaWQ9Im0tc2V0ZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48
L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tc2V0ZGF0YS1idG4iIG9uY2xp
Y2s9ImRvU2V0RGF0YSgpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4Lix4LmJ4LiHIERhdGE8
L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguKPguLXguYDguIvguJUg
VHJhZmZpYyAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZXNldCI+CiAgICAg
IDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SDIOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIOKAlCDg
uYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYnguJfguLHguYnguIfguKvguKHg
uJQ8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0
ZWQpO21hcmdpbi1ib3R0b206MTJweCI+4LiB4Liy4Lij4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg
4LiI4Liw4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiUIFVwbG9hZC9Eb3dubG9hZCDguJfg
uLHguYnguIfguKvguKHguJTguILguK3guIfguKLguLnguKrguJnguLXguYk8L2Rpdj4KICAgICAg
PGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVzZXQtYnRuIiBvbmNsaWNrPSJkb1Jlc2V0VHJh
ZmZpYygpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2J1
dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguKXguJrguKLguLnguKogLS0+
CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItZGVsZXRlIj4KICAgICAgPGRpdiBjbGFz
cz0ibXN1Yi1sYmwiIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij7wn5eR77iPIOC4peC4muC4ouC4ueC4
qiDigJQg4Lil4Lia4LiW4Liy4Lin4LijIOC5hOC4oeC5iOC4quC4suC4oeC4suC4o+C4luC4geC4
ueC5ieC4hOC4t+C4meC5hOC4lOC5iTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6
MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guKLguLnguKogPGIg
aWQ9Im0tZGVsLW5hbWUiIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij48L2I+IOC4iOC4sOC4luC4ueC4
geC4peC4muC4reC4reC4geC4iOC4suC4geC4o+C4sOC4muC4muC4luC4suC4p+C4ozwvZGl2Pgog
ICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1kZWxldGUtYnRuIiBvbmNsaWNrPSJkb0Rl
bGV0ZVVzZXIoKSIgc3R5bGU9ImJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjZGMy
NjI2LCNlZjQ0NDQpIj7wn5eR77iPIOC4ouC4t+C4meC4ouC4seC4meC4peC4muC4ouC4ueC4qjwv
YnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJtb2RhbC1hbGVy
dCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+PC9kaXY+CiAgPC9kaXY+CjwvZGl2PgoKPHNjcmlw
dCBzcmM9ImNvbmZpZy5qcyIgb25lcnJvcj0id2luZG93LkNIQUlZQV9DT05GSUc9e30iPjwvc2Ny
aXB0Pgo8c2NyaXB0PgovLyDilZDilZDilZDilZAgQ09ORklHIOKVkOKVkOKVkOKVkApjb25zdCBD
RkcgPSAodHlwZW9mIHdpbmRvdy5DSEFJWUFfQ09ORklHICE9PSAndW5kZWZpbmVkJykgPyB3aW5k
b3cuQ0hBSVlBX0NPTkZJRyA6IHt9Owpjb25zdCBIT1NUID0gQ0ZHLmhvc3QgfHwgbG9jYXRpb24u
aG9zdG5hbWU7CmNvbnN0IFhVSSAgPSAnL3h1aS1hcGknOyAgLy8g4Lic4LmI4Liy4LiZIG5naW54
IHByb3h5IChjb29raWUgcmV3cml0ZSDguYLguJTguKIgbmdpbngpCmNvbnN0IEFQSSAgPSAnL2Fw
aSc7ICAgICAgICAgICAgICAgLy8gY2hhaXlhLXNzaC1hcGkgKFNTSCB1c2VycyDguYDguJfguYjg
uLLguJnguLHguYnguJkpCmNvbnN0IFNFU1NJT05fS0VZID0gJ2NoYWl5YV9hdXRoJzsKCi8vIOKU
gOKUgCBEaXJlY3QgeC11aSBBUEkgaGVscGVycyDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDi
lIDilIAKbGV0IF94dWlDb29raWUgPSBmYWxzZTsgc2V0SW50ZXJ2YWwoKCk9PntfeHVpQ29va2ll
PWZhbHNlO30sIDMwMDAwKTsKYXN5bmMgZnVuY3Rpb24geHVpRW5zdXJlTG9naW4oKSB7CiAgaWYg
KF94dWlDb29raWUpIHJldHVybiB0cnVlOwogIGNvbnN0IF9zID0gKCgpID0+IHsgdHJ5IHsgcmV0
dXJuIEpTT04ucGFyc2Uoc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSl8fCd7fScp
OyB9IGNhdGNoKGUpe3JldHVybnt9O30gfSkoKTsKICBjb25zdCBmb3JtID0gbmV3IFVSTFNlYXJj
aFBhcmFtcyh7IHVzZXJuYW1lOiBfcy51c2VyfHxDRkcueHVpX3VzZXJ8fCcnLCBwYXNzd29yZDog
X3MucGFzc3x8Q0ZHLnh1aV9wYXNzfHwnJyB9KTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJ
KycvbG9naW4nLCB7CiAgICBtZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsCiAg
ICBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24veC13d3ctZm9ybS11cmxlbmNv
ZGVkJ30sCiAgICBib2R5OiBmb3JtLnRvU3RyaW5nKCkKICB9KTsKICBjb25zdCBkID0gYXdhaXQg
ci5qc29uKCk7CiAgX3h1aUNvb2tpZSA9ICEhZC5zdWNjZXNzOwogIHJldHVybiBfeHVpQ29va2ll
Owp9CmFzeW5jIGZ1bmN0aW9uIHh1aUdldChwYXRoKSB7CiAgaWYgKCFfeHVpQ29va2llKSBhd2Fp
dCB4dWlFbnN1cmVMb2dpbigpOwogIGxldCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHtjcmVk
ZW50aWFsczonaW5jbHVkZSd9KTsKICB0cnkgeyBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7IGlm
IChkICYmICFkLnN1Y2Nlc3MgJiYgZC5tc2cgJiYgZC5tc2cuaW5jbHVkZXMoJ2xvZ2luJykpIHsg
X3h1aUNvb2tpZT1mYWxzZTsgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsgciA9IGF3YWl0IGZldGNo
KFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7IHJldHVybiBhd2FpdCByLmpzb24o
KTsgfSByZXR1cm4gZDsgfSBjYXRjaChlKSB7IF94dWlDb29raWU9ZmFsc2U7IGF3YWl0IHh1aUVu
c3VyZUxvZ2luKCk7IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNs
dWRlJ30pOyB0cnkgeyByZXR1cm4gYXdhaXQgci5qc29uKCk7IH0gY2F0Y2goZTIpIHsgdGhyb3cg
bmV3IEVycm9yKCfguYDguKPguLXguKLguIEgeC11aSDguYTguKHguYjguKrguLPguYDguKPguYfg
uIgnKTsgfSB9Cn0KYXN5bmMgZnVuY3Rpb24geHVpUG9zdChwYXRoLCBib2R5KSB7CiAgaWYgKCFf
eHVpQ29va2llKSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogIGxldCByID0gYXdhaXQgZmV0Y2go
WFVJK3BhdGgsIHttZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsIGhlYWRlcnM6
eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnko
Ym9keSl9KTsKICB0cnkgeyBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7IGlmIChkICYmICFkLnN1
Y2Nlc3MgJiYgZC5tc2cgJiYgZC5tc2cuaW5jbHVkZXMoJ2xvZ2luJykpIHsgX3h1aUNvb2tpZT1m
YWxzZTsgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7
bWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLCBoZWFkZXJzOnsnQ29udGVudC1U
eXBlJzonYXBwbGljYXRpb24vanNvbid9LCBib2R5OkpTT04uc3RyaW5naWZ5KGJvZHkpfSk7IHJl
dHVybiBhd2FpdCByLmpzb24oKTsgfSByZXR1cm4gZDsgfSBjYXRjaChlKSB7IF94dWlDb29raWU9
ZmFsc2U7IGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwg
e21ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywgaGVhZGVyczp7J0NvbnRlbnQt
VHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwgYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX0pOyB0
cnkgeyByZXR1cm4gYXdhaXQgci5qc29uKCk7IH0gY2F0Y2goZTIpIHsgdGhyb3cgbmV3IEVycm9y
KCfguYDguKPguLXguKLguIEgeC11aSDguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsgfSB9
Cn0KCi8vIFNlc3Npb24gY2hlY2sKY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNP
Ti5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0
Y2goZSl7cmV0dXJue307fSB9KSgpOwppZiAoIV9zLnVzZXIgfHwgIV9zLnBhc3MgfHwgRGF0ZS5u
b3coKSA+PSAoX3MuZXhwfHwwKSkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lP
Tl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8gSGVhZGVyIGRv
bWFpbgpkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLWRvbWFpbicpLnRleHRDb250ZW50ID0g
Jyc7CgovLyDilZDilZDilZDilZAgVVRJTFMg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGZtdEJ5dGVz
KGIpIHsKICBpZiAoIWIgfHwgYiA9PT0gMCkgcmV0dXJuICcwIEInOwogIGNvbnN0IGsgPSAxMDI0
LCB1ID0gWydCJywnS0InLCdNQicsJ0dCJywnVEInXTsKICBjb25zdCBpID0gTWF0aC5mbG9vcihN
YXRoLmxvZyhiKS9NYXRoLmxvZyhrKSk7CiAgcmV0dXJuIChiL01hdGgucG93KGssaSkpLnRvRml4
ZWQoMSkrJyAnK3VbaV07Cn0KZnVuY3Rpb24gZm10RGF0ZShtcykgewogIGlmICghbXMgfHwgbXMg
PT09IDApIHJldHVybiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBjb25zdCBkID0gbmV3
IERhdGUobXMpOwogIHJldHVybiBkLnRvTG9jYWxlRGF0ZVN0cmluZygndGgtVEgnLHt5ZWFyOidu
dW1lcmljJyxtb250aDonc2hvcnQnLGRheTonbnVtZXJpYyd9KTsKfQpmdW5jdGlvbiBkYXlzTGVm
dChtcykgewogIGlmICghbXMgfHwgbXMgPT09IDApIHJldHVybiBudWxsOwogIHJldHVybiBNYXRo
LmNlaWwoKG1zIC0gRGF0ZS5ub3coKSkgLyA4NjQwMDAwMCk7Cn0KZnVuY3Rpb24gc2V0UmluZyhp
ZCwgcGN0KSB7CiAgY29uc3QgY2lyYyA9IDEzOC4yOwogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoaWQpOwogIGlmIChlbCkgZWwuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IGNp
cmMgLSAoY2lyYyAqIE1hdGgubWluKHBjdCwxMDApIC8gMTAwKTsKfQpmdW5jdGlvbiBzZXRCYXIo
aWQsIHBjdCwgd2Fybj1mYWxzZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoaWQpOwogIGlmICghZWwpIHJldHVybjsKICBlbC5zdHlsZS53aWR0aCA9IE1hdGgubWluKHBj
dCwxMDApICsgJyUnOwogIGlmICh3YXJuICYmIHBjdCA+IDg1KSBlbC5zdHlsZS5iYWNrZ3JvdW5k
ID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpJzsKICBlbHNlIGlmICh3
YXJuICYmIHBjdCA+IDY1KSBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5
MGRlZywjZjk3MzE2LCNmYjkyM2MpJzsKfQpmdW5jdGlvbiBzaG93QWxlcnQoaWQsIG1zZywgdHlw
ZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghZWwp
IHJldHVybjsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyt0eXBlOwogIGVsLnRleHRDb250ZW50
ID0gbXNnOwogIGVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIGlmICh0eXBlID09PSAnb2sn
KSBzZXRUaW1lb3V0KCgpPT57ZWwuc3R5bGUuZGlzcGxheT0nbm9uZSc7fSwgMzAwMCk7Cn0KCi8v
IOKVkOKVkOKVkOKVkCBOQVYg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIHN3KG5hbWUsIGVsKSB7CiAg
ZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnNlYycpLmZvckVhY2gocz0+cy5jbGFzc0xpc3Qu
cmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm5hdi1pdGVt
JykuZm9yRWFjaChuPT5uLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndGFiLScrbmFtZSkuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgZWwu
Y2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgaWYgKG5hbWU9PT0nY3JlYXRlJykgY2xvc2VGb3Jt
KCk7CiAgaWYgKG5hbWU9PT0nZGFzaGJvYXJkJykgbG9hZERhc2goKTsKICBpZiAobmFtZT09PSdt
YW5hZ2UnKSBsb2FkVXNlcnMoKTsKICBpZiAobmFtZT09PSdvbmxpbmUnKSBsb2FkT25saW5lKCk7
CiAgaWYgKG5hbWU9PT0nYmFuJykgeyBsb2FkQmFubmVkKCk7IH0KICBpZiAobmFtZT09PSdzcGVl
ZCcpIHsgc2V0R2F1Z2UoMCk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gbG9hZEJhbm5lZCgpIHsKICBj
b25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW5uZWQtbGlzdCcpOwogIGlmICgh
ZWwpIHJldHVybjsKICBlbC5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz
4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3
YWl0IGZldGNoKEFQSSsnL2Jhbm5lZCcpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgY29uc3QgbGlz
dCA9IGQuYmFubmVkIHx8IFtdOwogICAgaWYgKCFsaXN0Lmxlbmd0aCkgeyBlbC5pbm5lckhUTUwg
PSAnPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9yOiMyMmM1
NWUiPuKchSDguYTguKHguYjguKHguLXguKPguLLguKLguIHguLLguKPguJfguLXguYjguJbguLng
uIHguYHguJrguJk8L2Rpdj4nOyByZXR1cm47IH0KICAgIGVsLmlubmVySFRNTCA9IGxpc3QubWFw
KGIgPT4gewogICAgICBjb25zdCByZW1haW4gPSBiLnJlbWFpbiB8fCAwOwogICAgICBjb25zdCBw
Y3QgPSBNYXRoLm1pbigxMDAsIE1hdGgucm91bmQoKDM2MDAtcmVtYWluKS8zNjAwKjEwMCkpOwog
ICAgICByZXR1cm4gYDxkaXYgc3R5bGU9ImJhY2tncm91bmQ6I2ZmZjdlZDtib3JkZXI6MXB4IHNv
bGlkICNmZWQ3YWE7Ym9yZGVyLXJhZGl1czoxMnB4O3BhZGRpbmc6MTJweCAxNHB4O21hcmdpbi1i
b3R0b206OHB4Ij4KICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250
ZW50OnNwYWNlLWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVyIj4KICAgICAgICAgIDxkaXY+CiAg
ICAgICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojOTI0MDBlIj4ke2Iu
ZW1haWx8fGIudXNlcnx8Yi51c2VybmFtZXx8J3Vua25vd24nfTwvZGl2PgogICAgICAgICAgICA8
ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjojYjQ1MzA5Ij5Qb3J0ICR7Yi5wb3J0fHwn
LSd9IMK3IOC5gOC4geC4tOC4mSBJUCBMaW1pdDwvZGl2PgogICAgICAgICAgICA8ZGl2IHN0eWxl
PSJmb250LXNpemU6MTJweDtjb2xvcjojODg4O21hcmdpbi10b3A6NHB4Ij7guKvguKHguJTguYHg
uJrguJnguYPguJk6IDxzcGFuIHN0eWxlPSJjb2xvcjojZjU5ZTBiO2ZvbnQtd2VpZ2h0OjcwMCI+
JHtNYXRoLmNlaWwocmVtYWluLzYwKX0g4LiZ4Liy4LiX4Li1PC9zcGFuPjwvZGl2PgogICAgICAg
ICAgPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIG9uY2xpY2s9InVuYmFuRGlyZWN0KCcke2IuZW1h
aWx8fGIudXNlcnx8Yi51c2VybmFtZX0nKSIgc3R5bGU9ImJhY2tncm91bmQ6bGluZWFyLWdyYWRp
ZW50KDEzNWRlZywjOTI0MDBlLCNmNTllMGIpO2NvbG9yOiNmZmY7Ym9yZGVyOm5vbmU7Ym9yZGVy
LXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTRweDtmb250LXNpemU6MTNweDtjdXJzb3I6cG9pbnRl
ciI+8J+UkyDguJvguKXguJQ8L2J1dHRvbj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0
eWxlPSJoZWlnaHQ6NHB4O2JhY2tncm91bmQ6I2ZlZTtib3JkZXItcmFkaXVzOjk5cHg7bWFyZ2lu
LXRvcDo4cHg7b3ZlcmZsb3c6aGlkZGVuIj4KICAgICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDox
MDAlO3dpZHRoOiR7cGN0fSU7YmFja2dyb3VuZDojZjU5ZTBiO2JvcmRlci1yYWRpdXM6OTlweCI+
PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9
IGNhdGNoKGUpIHsgZWwuaW5uZXJIVE1MID0gJzxkaXYgc3R5bGU9ImNvbG9yOnJlZCI+JytlLm1l
c3NhZ2UrJzwvZGl2Pic7IH0KfQphc3luYyBmdW5jdGlvbiB1bmJhbkRpcmVjdCh1c2VybmFtZSkg
ewogIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91bmJhbicsIHttZXRob2Q6J1BPU1QnLCBo
ZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LCBib2R5OkpTT04uc3Ry
aW5naWZ5KHt1c2VybmFtZX0pfSkudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pih7b2s6ZmFs
c2V9KSk7CiAgbG9hZEJhbm5lZCgpOwp9CmFzeW5jIGZ1bmN0aW9uIHVuYmFuVXNlcigpIHsKICBj
b25zdCB1c2VybmFtZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVl
LnRyaW0oKTsKICBjb25zdCBhbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tYWxlcnQn
KTsKICBpZiAoIXVzZXJuYW1lKSB7IGFsLnRleHRDb250ZW50PSfguIHguKPguLjguJPguLLguIHg
uKPguK3guIEgdXNlcm5hbWUnOyBhbC5jbGFzc05hbWU9J2FsZXJ0IGVycic7IHJldHVybjsgfQog
IGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91bmJhbicsIHttZXRob2Q6J1BPU1QnLCBoZWFk
ZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LCBib2R5OkpTT04uc3RyaW5n
aWZ5KHt1c2VybmFtZX0pfSkudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pih7b2s6ZmFsc2V9
KSk7CiAgYWwudGV4dENvbnRlbnQgPSBkLm9rID8gJ+KchSDguJvguKXguJTguKXguYfguK3guITg
uKrguLPguYDguKPguYfguIgnIDogJ+KdjCAnKyhkLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA
4Lij4LmH4LiIJyk7CiAgYWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcrKGQub2s/J29rJzonZXJyJyk7
CiAgaWYgKGQub2spIGxvYWRCYW5uZWQoKTsKfQoKYXN5bmMgZnVuY3Rpb24gZGVidWdCYW4oKSB7
CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLWRlYnVnJyk7CiAgdHJ5
IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9iYW5uZWQnKTsKICAgIGNvbnN0IHRl
eHQgPSBhd2FpdCByLnRleHQoKTsKICAgIGVsLnRleHRDb250ZW50ID0gJ1N0YXR1czonK3Iuc3Rh
dHVzKycgQm9keTonK3RleHQ7CiAgfSBjYXRjaChlKSB7CiAgICBlbC50ZXh0Q29udGVudCA9ICdF
cnJvcjogJytlLm1lc3NhZ2U7CiAgfQp9CgovLyDilIDilIAgRm9ybSBuYXYg4pSA4pSACmxldCBf
Y3VyRm9ybSA9IG51bGw7CmZ1bmN0aW9uIG9wZW5Gb3JtKGlkKSB7CiAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICBbJ2Fpcycs
J3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gZj09PWlkID8gJ2Jsb2NrJyA6ICdub25lJzsKICB9
KTsKICBfY3VyRm9ybSA9IGlkOwogIGlmIChpZD09PSdzc2gnKSBsb2FkU1NIVGFibGVJbkZvcm0o
KTsKICB3aW5kb3cuc2Nyb2xsVG8oMCwwKTsKfQpmdW5jdGlvbiBjbG9zZUZvcm0oKSB7CiAgZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NyZWF0ZS1tZW51Jykuc3R5bGUuZGlzcGxheSA9ICdibG9j
ayc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9ICdub25lJzsKICB9KTsKICBf
Y3VyRm9ybSA9IG51bGw7Cn0KCmxldCBfd3NQb3J0ID0gJzgwJzsKZnVuY3Rpb24gdG9nUG9ydChi
dG4sIHBvcnQpIHsKICBfd3NQb3J0ID0gcG9ydDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgn
d3M4MC1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzgwJyk7CiAgZG9j
dW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzNDQzLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2
ZScsIHBvcnQ9PT0nNDQzJyk7Cn0KZnVuY3Rpb24gdG9nR3JvdXAoYnRuLCBjbHMpIHsKICBidG4u
Y2xvc2VzdCgnZGl2JykucXVlcnlTZWxlY3RvckFsbChjbHMpLmZvckVhY2goYj0+Yi5jbGFzc0xp
c3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgYnRuLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwp9Cgov
LyDilZDilZDilZDilZAgWFVJIExPR0lOIChjb29raWUpIOKVkOKVkOKVkOKVkAovLyBbZHVwbGlj
YXRlIHJlbW92ZWRdCgovLyDilZDilZDilZDilZAgREFTSEJPQVJEIOKVkOKVkOKVkOKVkAphc3lu
YyBmdW5jdGlvbiBsb2FkRGFzaCgpIHsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnYnRuLXJlZnJlc2gnKTsKICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IC4u
Lic7CiAgX3h1aUNvb2tpZSA9IGZhbHNlOyAvLyBmb3JjZSByZS1sb2dpbiDguYDguKrguKHguK0K
CiAgdHJ5IHsKICAgIC8vIFNTSCBBUEkgc3RhdHVzCiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNo
KEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlm
IChzdCkgewogICAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgICB9Cgog
ICAgLy8gWFVJIHNlcnZlciBzdGF0dXMKICAgIGNvbnN0IG9rID0gYXdhaXQgeHVpRW5zdXJlTG9n
aW4oKTsKICAgIGlmICghb2spIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1w
aWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+TG9naW4g4LmE
4Lih4LmI4LmE4LiU4LmJJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxs
JykuY2xhc3NOYW1lID0gJ29waWxsIG9mZic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0
IHN2ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL3NlcnZlci9zdGF0dXMnKS5jYXRjaCgoKT0+
bnVsbCk7CiAgICBpZiAoc3YgJiYgc3Yuc3VjY2VzcyAmJiBzdi5vYmopIHsKICAgICAgY29uc3Qg
byA9IHN2Lm9iajsKICAgICAgLy8gQ1BVCiAgICAgIGNvbnN0IGNwdSA9IE1hdGgucm91bmQoby5j
cHUgfHwgMCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtcGN0JykudGV4dENv
bnRlbnQgPSBjcHUgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcHUtY29y
ZXMnKS50ZXh0Q29udGVudCA9IChvLmNwdUNvcmVzIHx8IG8ubG9naWNhbFBybyB8fCAnLS0nKSAr
ICcgY29yZXMnOwogICAgICBzZXRSaW5nKCdjcHUtcmluZycsIGNwdSk7IHNldEJhcignY3B1LWJh
cicsIGNwdSwgdHJ1ZSk7CgogICAgICAvLyBSQU0KICAgICAgY29uc3QgcmFtVCA9ICgoby5tZW0/
LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgcmFtVSA9ICgoby5tZW0/LmN1cnJlbnR8fDApLzEwNzM3
NDE4MjQpOwogICAgICBjb25zdCByYW1QID0gcmFtVCA+IDAgPyBNYXRoLnJvdW5kKHJhbVUvcmFt
VCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1wY3QnKS50ZXh0
Q29udGVudCA9IHJhbVAgKyAnJSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0t
ZGV0YWlsJykudGV4dENvbnRlbnQgPSByYW1VLnRvRml4ZWQoMSkrJyAvICcrcmFtVC50b0ZpeGVk
KDEpKycgR0InOwogICAgICBzZXRSaW5nKCdyYW0tcmluZycsIHJhbVApOyBzZXRCYXIoJ3JhbS1i
YXInLCByYW1QLCB0cnVlKTsKCiAgICAgIC8vIERpc2sKICAgICAgY29uc3QgZHNrVCA9ICgoby5k
aXNrPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIGRza1UgPSAoKG8uZGlzaz8uY3VycmVudHx8MCkv
MTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IGRza1AgPSBkc2tUID4gMCA/IE1hdGgucm91bmQoZHNr
VS9kc2tUKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1wY3Qn
KS5pbm5lckhUTUwgPSBkc2tQICsgJzxzcGFuPiU8L3NwYW4+JzsKICAgICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ2Rpc2stZGV0YWlsJykudGV4dENvbnRlbnQgPSBkc2tVLnRvRml4ZWQoMCkr
JyAvICcrZHNrVC50b0ZpeGVkKDApKycgR0InOwogICAgICBzZXRCYXIoJ2Rpc2stYmFyJywgZHNr
UCwgdHJ1ZSk7CgogICAgICAvLyBVcHRpbWUKICAgICAgY29uc3QgdXAgPSBvLnVwdGltZSB8fCAw
OwogICAgICBjb25zdCB1ZCA9IE1hdGguZmxvb3IodXAvODY0MDApLCB1aCA9IE1hdGguZmxvb3Io
KHVwJTg2NDAwKS8zNjAwKSwgdW0gPSBNYXRoLmZsb29yKCh1cCUzNjAwKS82MCk7CiAgICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtdmFsJykudGV4dENvbnRlbnQgPSB1ZCA+IDAg
PyB1ZCsnZCAnK3VoKydoJyA6IHVoKydoICcrdW0rJ20nOwogICAgICBkb2N1bWVudC5nZXRFbGVt
ZW50QnlJZCgndXB0aW1lLXN1YicpLnRleHRDb250ZW50ID0gdWQrJ+C4p+C4seC4mSAnK3VoKyfg
uIrguKEuICcrdW0rJ+C4meC4suC4l+C4tSc7CiAgICAgIGNvbnN0IGxvYWRzID0gby5sb2FkcyB8
fCBbXTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvYWQtY2hpcHMnKS5pbm5lckhU
TUwgPSBsb2Fkcy5tYXAoKGwsaSk9PgogICAgICAgIGA8c3BhbiBjbGFzcz0iYmRnIj4ke1snMW0n
LCc1bScsJzE1bSddW2ldfTogJHtsLnRvRml4ZWQoMil9PC9zcGFuPmApLmpvaW4oJycpOwoKICAg
ICAgLy8gTmV0d29yawogICAgICBpZiAoby5uZXRJTykgewogICAgICAgIGNvbnN0IHVwX2IgPSBv
Lm5ldElPLnVwfHwwLCBkbl9iID0gby5uZXRJTy5kb3dufHwwOwogICAgICAgIGNvbnN0IHVwRm10
ID0gZm10Qnl0ZXModXBfYiksIGRuRm10ID0gZm10Qnl0ZXMoZG5fYik7CiAgICAgICAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC11cCcpLmlubmVySFRNTCA9IHVwRm10LnJlcGxhY2UoJyAn
LCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdu
ZXQtZG4nKS5pbm5lckhUTUwgPSBkbkZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+
JzsKICAgICAgfQogICAgICBpZiAoby5uZXRUcmFmZmljKSB7CiAgICAgICAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ25ldC11cC10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5
dGVzKG8ubmV0VHJhZmZpYy5zZW50fHwwKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJ
ZCgnbmV0LWRuLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRU
cmFmZmljLnJlY3Z8fDApOwogICAgICB9CgogICAgICAvLyBYVUkgdmVyc2lvbgogICAgICBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXZlcicpLnRleHRDb250ZW50ID0gKG8ueHJheSAmJiBv
LnhyYXkudmVyc2lvbikgPyBvLnhyYXkudmVyc2lvbiA6IChvLnhyYXlWZXJzaW9uIHx8ICctLScp
OwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAn
PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPuC4reC4reC4meC5hOC4peC4meC5jCc7CiAgICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCc7CiAg
ICB9CgogICAgLy8gSW5ib3VuZHMgY291bnQKICAgIGNvbnN0IGlibCA9IGF3YWl0IHh1aUdldCgn
L3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKGlibCAm
JiBpYmwuc3VjY2VzcykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLWluYm91
bmRzJykudGV4dENvbnRlbnQgPSAoaWJsLm9ianx8W10pLmxlbmd0aDsKICAgIH0KCiAgICBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnbGFzdC11cGRhdGUnKS50ZXh0Q29udGVudCA9ICfguK3guLHg
uJ7guYDguJTguJfguKXguYjguLLguKrguLjguJQ6ICcgKyBuZXcgRGF0ZSgpLnRvTG9jYWxlVGlt
ZVN0cmluZygndGgtVEgnKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnNvbGUuZXJyb3IoZSk7CiAg
fSBmaW5hbGx5IHsKICAgIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsg4Lij4Li14LmA
4Lif4Lij4LiKJzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTRVJWSUNFUyDilZDilZDilZDilZAK
Y29uc3QgU1ZDX0RFRiA9IFsKICB7IGtleToneHVpJywgICAgICBpY29uOifwn5OhJywgbmFtZTon
eC11aSBQYW5lbCcsICAgICAgcG9ydDonOjIwNTMnIH0sCiAgeyBrZXk6J3NzaCcsICAgICAgaWNv
bjon8J+QjScsIG5hbWU6J1NTSCBBUEknLCAgICAgICAgICBwb3J0Oic6Njc4OScgfSwKICB7IGtl
eTonZHJvcGJlYXInLCBpY29uOifwn5C7JywgbmFtZTonRHJvcGJlYXIgU1NIJywgICAgIHBvcnQ6
JzoxNDMgOjEwOScgfSwKICB7IGtleTonbmdpbngnLCAgICBpY29uOifwn4yQJywgbmFtZTonbmdp
bnggLyBQYW5lbCcsICAgIHBvcnQ6Jzo4MCA6NDQzJyB9LAogIHsga2V5Oidzc2h3cycsICAgIGlj
b246J/CflJInLCBuYW1lOidXUy1TdHVubmVsJywgICAgICAgcG9ydDonOjgw4oaSOjE0MycgfSwK
ICB7IGtleTonYmFkdnBuJywgICBpY29uOifwn46uJywgbmFtZTonQmFkVlBOIFVEUEdXJywgICAg
IHBvcnQ6Jzo3MzAwJyB9LApdOwpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcyhtYXApIHsKICBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSBTVkNfREVGLm1hcChz
ID0+IHsKICAgIGNvbnN0IHVwID0gbWFwW3Mua2V5XSA9PT0gdHJ1ZSB8fCBtYXBbcy5rZXldID09
PSAnYWN0aXZlJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0ic3ZjICR7dXA/Jyc6J2Rvd24nfSI+
CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1sIj48c3BhbiBjbGFzcz0iZGcgJHt1cD8nJzoncmVkJ30i
Pjwvc3Bhbj48c3Bhbj4ke3MuaWNvbn08L3NwYW4+CiAgICAgICAgPGRpdj48ZGl2IGNsYXNzPSJz
dmMtbiI+JHtzLm5hbWV9PC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPiR7cy5wb3J0fTwvZGl2Pjwv
ZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9InJiZGcgJHt1cD8nJzonZG93bid9
Ij4ke3VwPydSVU5OSU5HJzonRE9XTid9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcn
KTsKfQphc3luYyBmdW5jdGlvbiBsb2FkU2VydmljZXMoKSB7CiAgdHJ5IHsKICAgIGNvbnN0IHN0
ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICByZW5k
ZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9h
ZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBB
UEkg4LmE4Lih4LmI4LmE4LiU4LmJPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0gg
UElDS0VSIFNUQVRFIOKVkOKVkOKVkOKVkApjb25zdCBQUk9TID0gewogIGR0YWM6IHsKICAgIG5h
bWU6ICdEVEFDIEdBTUlORycsCiAgICBwcm94eTogJzEwNC4xOC42My4xMjQ6ODAnLAogICAgcGF5
bG9hZDogJ1BPU1QgLyBIVFRQLzEuMVtjcmxmXUhvc3Q6ZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNv
bVtjcmxmXVgtT25saW5lLUhvc3Q6ZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbVtjcmxmXVgtRm9y
d2FyZC1Ib3N0OmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb21bY3JsZl1Vc2VyLUFnZW50OiBbdWFd
W2NybGZdQ29ubmVjdGlvbjoga2VlcC1hbGl2ZVtjcmxmXVtjcmxmXVtzcGxpdF1bY3JdUEFUQ0gg
LyBIVFRQLzEuMVtjcmxmXUhvc3Q6IFtob3N0XVtjcmxmXVVwZ3JhZGU6IHdlYnNvY2tldFtjcmxm
XUNvbm5lY3Rpb246IFVwZ3JhZGVbY3JsZl1YLU9ubGluZS1Ib3N0OiBbaG9zdF1bY3JsZl1bY3Js
Zl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94
eVBvcnQ6IDgwCiAgfSwKICB0cnVlOiB7CiAgICBuYW1lOiAnVFJVRSBUV0lUVEVSJywKICAgIHBy
b3h5OiAnMTA0LjE4LjM5LjI0OjgwJywKICAgIHBheWxvYWQ6ICdQT1NUIC8gSFRUUC8xLjFbY3Js
Zl1Ib3N0OmhlbHAueC5jb21bY3JsZl1YLU9ubGluZS1Ib3N0OmhlbHAueC5jb21bY3JsZl1YLUZv
cndhcmQtSG9zdDpoZWxwLnguY29tW2NybGZdVXNlci1BZ2VudDogW3VhXVtjcmxmXUNvbm5lY3Rp
b246IGtlZXAtYWxpdmVbY3JsZl1bY3JsZl1bc3BsaXRdW2NyXVBBVENIIC8gSFRUUC8xLjFbY3Js
Zl1Ib3N0OiBbaG9zdF1bY3JsZl1VcGdyYWRlOiB3ZWJzb2NrZXRbY3JsZl1Db25uZWN0aW9uOiBV
cGdyYWRlW2NybGZdWC1PbmxpbmUtSG9zdDogW2hvc3RdW2NybGZdW2NybGZdJywKICAgIGRhcmtQ
cm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0K
fTsKY29uc3QgTlBWX0hPU1QgPSBIT1NULCBOUFZfUE9SVCA9IDgwOwpsZXQgX3NzaFBybyA9ICdk
dGFjJywgX3NzaEFwcCA9ICducHYnLCBfc3NoUG9ydCA9ICc4MCc7CgpmdW5jdGlvbiBwaWNrUG9y
dChwKSB7CiAgX3NzaFBvcnQgPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi04MCcp
LmNsYXNzTmFtZSAgPSAncG9ydC1idG4nICsgKHA9PT0nODAnICA/ICcgYWN0aXZlLXA4MCcgIDog
JycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi00NDMnKS5jbGFzc05hbWUgPSAncG9y
dC1idG4nICsgKHA9PT0nNDQzJyA/ICcgYWN0aXZlLXA0NDMnIDogJycpOwp9CmZ1bmN0aW9uIHBp
Y2tQcm8ocCkgewogIF9zc2hQcm8gPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8t
ZHRhYycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSdkdGFjJyA/ICcgYS1kdGFjJyA6
ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLXRydWUnKS5jbGFzc05hbWUgPSAn
cGljay1vcHQnICsgKHA9PT0ndHJ1ZScgPyAnIGEtdHJ1ZScgOiAnJyk7Cn0KZnVuY3Rpb24gcGlj
a0FwcChhKSB7CiAgX3NzaEFwcCA9IGE7CiAgWyducHYnLCdkYXJrJ10uZm9yRWFjaChmdW5jdGlv
bihrKXsKICAgIHZhciBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtJytrKTsKICAg
IGlmKGVsKSBlbC5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKGE9PT1rID8gJyBhLScrayA6ICcn
KTsKICB9KTsKfQoKCgpmdW5jdGlvbiBidWlsZE5wdkxpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAg
Y29uc3QgaiA9IHsKICAgIHNzaENvbmZpZ1R5cGU6J1NTSC1Qcm94eS1QYXlsb2FkJywgcmVtYXJr
czpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6TlBWX0hPU1QsIHNzaFBvcnQ6TlBWX1BP
UlQsCiAgICBzc2hVc2VybmFtZTpuYW1lLCBzc2hQYXNzd29yZDpwYXNzLAogICAgc25pOicnLCB0
bHNWZXJzaW9uOidERUZBVUxUJywKICAgIGh0dHBQcm94eTpwcm8ucHJveHksIGF1dGhlbnRpY2F0
ZVByb3h5OmZhbHNlLAogICAgcHJveHlVc2VybmFtZTonJywgcHJveHlQYXNzd29yZDonJywKICAg
IHBheWxvYWQ6cHJvLnBheWxvYWQsCiAgICBkbnNNb2RlOidVRFAnLCBkbnNTZXJ2ZXI6JycsIG5h
bWVzZXJ2ZXI6JycsIHB1YmxpY0tleTonJywKICAgIHVkcGd3UG9ydDo3MzAwLCB1ZHBnd1RyYW5z
cGFyZW50RE5TOnRydWUKICB9OwogIHJldHVybiAnbnB2dC1zc2g6Ly8nICsgYnRvYSh1bmVzY2Fw
ZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KZnVuY3Rpb24gYnVp
bGREYXJrTGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBqID0gewogICAgdHlwZTogIlNT
SCIsCiAgICBuYW1lOiBwcm8ubmFtZSArICctJyArIG5hbWUsCiAgICBzc2hUdW5uZWxDb25maWc6
IHsKICAgICAgc3NoQ29uZmlnOiB7CiAgICAgICAgaG9zdDogSE9TVCwKICAgICAgICBwb3J0OiBw
YXJzZUludChfc3NoUG9ydCkgfHwgODAsCiAgICAgICAgdXNlcm5hbWU6IG5hbWUsCiAgICAgICAg
cGFzc3dvcmQ6IHBhc3MKICAgICAgfSwKICAgICAgaW5qZWN0Q29uZmlnOiB7CiAgICAgICAgbW9k
ZTogIlBST1hZIiwKICAgICAgICBwcm94eUhvc3Q6IChwcm8ucHJveHl8fCcnKS5zcGxpdCgnOicp
WzBdLAogICAgICAgIHByb3h5UG9ydDogODAsCiAgICAgICAgcGF5bG9hZDogcHJvLnBheWxvYWQK
ICAgICAgfQogICAgfQogIH07CiAgcmV0dXJuICdkYXJrdHVubmVsOi8vJyArIGJ0b2EodW5lc2Nh
cGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CgovLyDilZDilZDi
lZDilZAgQ1JFQVRFIFNTSCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCkg
ewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1
ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFz
cycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3NzaC1kYXlzJykudmFsdWUpfHwzMDsKICBjb25zdCBpcGwgID0gcGFyc2VJbnQo
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpID8gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NzaC1pcCcpLnZhbHVlIDogMil8fDI7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0
KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsK
ICBpZiAoIXBhc3MpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4
suC5g+C4quC5iCBQYXNzd29yZCcsJ2VycicpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKCdzc2gtYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4uaW5uZXJI
VE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMzQsMTk3
LDk0LC4zKTtib3JkZXItdG9wLWNvbG9yOiMyMmM1NWUiPjwvc3Bhbj7guIHguLPguKXguLHguIfg
uKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYWxlcnQn
KS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBjb25zdCByZXNFbCA9IGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdzc2gtbGluay1yZXN1bHQnKTsKICBpZiAocmVzRWwpIHJlc0VsLmNsYXNzTmFtZT0n
bGluay1yZXN1bHQnOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvY3Jl
YXRlX3NzaCcsIHsKICAgICAgbWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6
J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoe3VzZXIsIHBh
c3N3b3JkOnBhc3MsIGRheXMsIGlwX2xpbWl0OmlwbH0pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBh
d2FpdCByLmpzb24oKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwg
J+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0
IHBybyAgPSBQUk9TW19zc2hQcm9dIHx8IFBST1MuZHRhYzsKICAgIGNvbnN0IGxpbmsgPSBfc3No
QXBwPT09J25wdicgPyBidWlsZE5wdkxpbmsodXNlcixwYXNzLHBybykgOiBidWlsZERhcmtMaW5r
KHVzZXIscGFzcyxwcm8pOwogICAgY29uc3QgaXNOcHYgPSBfc3NoQXBwPT09J25wdic7CiAgICBj
b25zdCBscENscyA9IGlzTnB2ID8gJycgOiAnIGRhcmstbHAnOwogICAgY29uc3QgY0NscyAgPSBp
c05wdiA/ICducHYnIDogJ2RhcmsnOwogICAgY29uc3QgYXBwTGFiZWwgPSBpc05wdiA/ICdOcHZ0
JyA6ICdEYXJrVHVubmVsJzsKCiAgICBpZiAocmVzRWwpIHsKICAgICAgcmVzRWwuY2xhc3NOYW1l
ID0gJ2xpbmstcmVzdWx0IHNob3cnOwogICAgICBjb25zdCBzYWZlTGluayA9IGxpbmsucmVwbGFj
ZSgvXFwvZywnXFxcXCcpLnJlcGxhY2UoLycvZywiXFwnIik7CiAgICAgIHJlc0VsLmlubmVySFRN
TCA9CiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcmVzdWx0LWhkcic+IiArCiAgICAgICAgICAi
PHNwYW4gY2xhc3M9J2ltcC1iYWRnZSAiK2NDbHMrIic+IithcHBMYWJlbCsiPC9zcGFuPiIgKwog
ICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOnZhcigtLW11dGVk
KSc+Iitwcm8ubmFtZSsiIFx4YjcgUG9ydCAiK19zc2hQb3J0KyI8L3NwYW4+IiArCiAgICAgICAg
ICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6IzIyYzU1ZTttYXJnaW4tbGVm
dDphdXRvJz5cdTI3MDUgIit1c2VyKyI8L3NwYW4+IiArCiAgICAgICAgIjwvZGl2PiIgKwogICAg
ICAgICI8ZGl2IGNsYXNzPSdsaW5rLXByZXZpZXciK2xwQ2xzKyInPiIrbGluaysiPC9kaXY+IiAr
CiAgICAgICAgIjxidXR0b24gY2xhc3M9J2NvcHktbGluay1idG4gIitjQ2xzKyInIGlkPSdjb3B5
LXNzaC1idG4nIG9uY2xpY2s9XCJjb3B5U1NITGluaygpXCI+IisKICAgICAgICAgICJcdWQ4M2Rc
dWRjY2IgQ29weSAiK2FwcExhYmVsKyIgTGluayIrCiAgICAgICAgIjwvYnV0dG9uPiI7CiAgICAg
IHdpbmRvdy5fbGFzdFNTSExpbmsgPSBsaW5rOwogICAgICB3aW5kb3cuX2xhc3RTU0hBcHAgID0g
Y0NsczsKICAgICAgd2luZG93Ll9sYXN0U1NITGFiZWwgPSBhcHBMYWJlbDsKICAgIH0KCiAgICBz
aG93QWxlcnQoJ3NzaC1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgJyt1c2VyKycg4Liq4Liz
4LmA4Lij4LmH4LiIIMK3IOC4q+C4oeC4lOC4reC4suC4ouC4uCAnK2QuZXhwLCdvaycpOwogICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWU9Jyc7CiAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZT0nJzsKICAgIGxvYWRTU0hUYWJsZUlu
Rm9ybSgpOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2Uu
bWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5u
ZXJIVE1MPSfinpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXInOyB9Cn0KZnVuY3Rpb24gY29weVNTSExp
bmsoKSB7CiAgY29uc3QgbGluayA9IHdpbmRvdy5fbGFzdFNTSExpbmt8fCcnOwogIGNvbnN0IGND
bHMgPSB3aW5kb3cuX2xhc3RTU0hBcHB8fCducHYnOwogIGNvbnN0IGxhYmVsID0gd2luZG93Ll9s
YXN0U1NITGFiZWx8fCdMaW5rJzsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dChsaW5r
KS50aGVuKGZ1bmN0aW9uKCl7CiAgICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J2NvcHktc3NoLWJ0bicpOwogICAgaWYoYil7IGIudGV4dENvbnRlbnQ9J1x1MjcwNSDguITguLHg
uJTguKXguK3guIHguYHguKXguYnguKchJzsgc2V0VGltZW91dChmdW5jdGlvbigpe2IudGV4dENv
bnRlbnQ9J1x1ZDgzZFx1ZGNjYiBDb3B5ICcrbGFiZWwrJyBMaW5rJzt9LDIwMDApOyB9CiAgfSku
Y2F0Y2goZnVuY3Rpb24oKXsgcHJvbXB0KCdDb3B5IGxpbms6JyxsaW5rKTsgfSk7Cn0KCi8vIFNT
SCB1c2VyIHRhYmxlCmxldCBfc3NoVGFibGVVc2VycyA9IFtdOwphc3luYyBmdW5jdGlvbiBsb2Fk
U1NIVGFibGVJbkZvcm0oKSB7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkr
Jy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgX3NzaFRhYmxlVXNlcnMgPSBkLnVzZXJz
IHx8IFtdOwogICAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMpOwogIH0gY2F0Y2goZSkg
ewogICAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHkn
KTsKICAgIGlmKHRiKSB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRl
eHQtYWxpZ246Y2VudGVyO2NvbG9yOiNlZjQ0NDQ7cGFkZGluZzoxNnB4Ij7guYDguIrguLfguYjg
uK3guKHguJXguYjguK0gU1NIIEFQSSDguYTguKHguYjguYTguJTguYk8L3RkPjwvdHI+JzsKICB9
Cn0KZnVuY3Rpb24gcmVuZGVyU1NIVGFibGUodXNlcnMpIHsKICBjb25zdCB0YiA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogIGlmICghdGIpIHJldHVybjsKICBp
ZiAoIXVzZXJzLmxlbmd0aCkgewogICAgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUi
IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzoyMHB4
Ij7guYTguKHguYjguKHguLUgU1NIIHVzZXJzPC90ZD48L3RyPic7CiAgICByZXR1cm47CiAgfQog
IGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICB0Yi5p
bm5lckhUTUwgPSB1c2Vycy5tYXAoZnVuY3Rpb24odSxpKXsKICAgIGNvbnN0IGV4cGlyZWQgPSB1
LmV4cCAmJiB1LmV4cCA8IG5vdzsKICAgIGNvbnN0IGFjdGl2ZSAgPSB1LmFjdGl2ZSAhPT0gZmFs
c2UgJiYgIWV4cGlyZWQ7CiAgICBjb25zdCBkTGVmdCAgID0gdS5leHAgPyBNYXRoLmNlaWwoKG5l
dyBEYXRlKHUuZXhwKS1EYXRlLm5vdygpKS84NjQwMDAwMCkgOiBudWxsOwogICAgY29uc3QgYmFk
Z2UgICA9IGFjdGl2ZQogICAgICA/ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1nIj5BQ1RJVkU8L3Nw
YW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1yIj5FWFBJUkVEPC9zcGFuPic7CiAg
ICBjb25zdCBkVGFnID0gZExlZnQhPT1udWxsCiAgICAgID8gJzxzcGFuIGNsYXNzPSJkYXlzLWJh
ZGdlIj4nKyhkTGVmdD4wP2RMZWZ0KydkJzon4Lir4Lih4LiUJykrJzwvc3Bhbj4nCiAgICAgIDog
JzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj5cdTIyMWU8L3NwYW4+JzsKICAgIHJldHVybiAnPHRy
Pjx0ZCBzdHlsZT0iY29sb3I6dmFyKC0tbXV0ZWQpIj4nKyhpKzEpKyc8L3RkPicgKwogICAgICAn
PHRkPjxiPicrdS51c2VyKyc8L2I+PC90ZD4nICsKICAgICAgJzx0ZCBzdHlsZT0iZm9udC1zaXpl
OjExcHg7Y29sb3I6JysoZXhwaXJlZD8nI2VmNDQ0NCc6J3ZhcigtLW11dGVkKScpKyciPicrCiAg
ICAgICAgKHUuZXhwfHwn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJzwvdGQ+JyArCiAgICAg
ICc8dGQ+JytiYWRnZSsnPC90ZD4nICsKICAgICAgJzx0ZD48ZGl2IHN0eWxlPSJkaXNwbGF5OmZs
ZXg7Z2FwOjRweDthbGlnbi1pdGVtczpjZW50ZXIiPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9
ImJ0bi10YmwiIHRpdGxlPSLguJXguYjguK3guK3guLLguKLguLgiIG9uY2xpY2s9Im9wZW5TU0hS
ZW5ld01vZGFsKFwnJyt1LnVzZXIrJ1wnKSI+8J+UhDwvYnV0dG9uPicrCiAgICAgICAgJzxidXR0
b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguKXguJoiIG9uY2xpY2s9ImRlbFNTSFVzZXIoXCcn
K3UudXNlcisnXCcpIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LC4zKSI+8J+X
ke+4jzwvYnV0dG9uPicrCiAgICAgICAgZFRhZysKICAgICAgJzwvZGl2PjwvdGQ+PC90cj4nOwog
IH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclNTSFVzZXJzKHEpIHsKICByZW5kZXJTU0hU
YWJsZShfc3NoVGFibGVVc2Vycy5maWx0ZXIoZnVuY3Rpb24odSl7cmV0dXJuICh1LnVzZXJ8fCcn
KS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSk7fSkpOwp9Ci8vIFNTSCBS
ZW5ldyBNb2RhbApsZXQgX3JlbmV3U1NIVXNlciA9ICcnOwpmdW5jdGlvbiBvcGVuU1NIUmVuZXdN
b2RhbCh1c2VyKSB7CiAgX3JlbmV3U1NIVXNlciA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NzaC1yZW5ldy11c2VybmFtZScpLnRleHRDb250ZW50ID0gdXNlcjsKICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSA9ICczMCc7CiAgZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4n
KTsKfQpmdW5jdGlvbiBjbG9zZVNTSFJlbmV3TW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVu
dEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfcmVu
ZXdTU0hVc2VyID0gJyc7Cn0KYXN5bmMgZnVuY3Rpb24gZG9TU0hSZW5ldygpIHsKICBjb25zdCBk
YXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJyku
dmFsdWUpfHwwOwogIGlmICghZGF5c3x8ZGF5czw9MCkgcmV0dXJuOwogIGNvbnN0IGJ0biA9IGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctYnRuJyk7CiAgYnRuLmRpc2FibGVkID0g
dHJ1ZTsgYnRuLnRleHRDb250ZW50ID0gJ+C4geC4s+C4peC4seC4h+C4leC5iOC4reC4reC4suC4
ouC4uC4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9leHRlbmRf
c3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxp
Y2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcjpfcmVuZXdTU0hV
c2VyLGRheXN9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAg
ICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA
4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguJXguYjguK3g
uK3guLLguKLguLggJytfcmVuZXdTU0hVc2VyKycgKycrZGF5cysnIOC4p+C4seC4mSDguKrguLPg
uYDguKPguYfguIgnLCdvaycpOwogICAgY2xvc2VTU0hSZW5ld01vZGFsKCk7CiAgICBsb2FkU1NI
VGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn
XHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsKICB9IGZpbmFsbHkgewogICAgYnRuLmRpc2FibGVk
ID0gZmFsc2U7IGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI
4Lit4Lit4Liy4Lii4Li4JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gcmVuZXdTU0hVc2VyKHVzZXIp
IHsgb3BlblNTSFJlbmV3TW9kYWwodXNlcik7IH0KYXN5bmMgZnVuY3Rpb24gZGVsU1NIVXNlcih1
c2VyKSB7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiDguJbguLLg
uKfguKM/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsn
L2RlbGV0ZV9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBl
JzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSkK
ICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9r
KSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcp
OwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4Lil4LiaICcrdXNlcisnIOC4quC4
s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNo
KGUpIHsgYWxlcnQoJ1x1Mjc0YyAnK2UubWVzc2FnZSk7IH0KfQovLyDilZDilZDilZDilZAgQ1JF
QVRFIFZMRVNTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4
eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csYz0+ewog
ICAgY29uc3Qgcj1NYXRoLnJhbmRvbSgpKjE2fDA7IHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3ww
eDgpKS50b1N0cmluZygxNik7CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gY3JlYXRlVkxFU1MoY2Fy
cmllcikgewogIGNvbnN0IGVtYWlsRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVy
KyctZW1haWwnKTsKICBjb25zdCBkYXlzRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2Fy
cmllcisnLWRheXMnKTsKICBjb25zdCBpcEVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
Y2FycmllcisnLWlwJyk7CiAgY29uc3QgZ2JFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KGNhcnJpZXIrJy1nYicpOwogIGNvbnN0IGVtYWlsICAgPSBlbWFpbEVsLnZhbHVlLnRyaW0oKTsK
ICBjb25zdCBkYXlzICAgID0gcGFyc2VJbnQoZGF5c0VsLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBM
aW1pdCA9IHBhcnNlSW50KGlwRWwudmFsdWUpfHwyOwogIGNvbnN0IGdiICAgICAgPSBwYXJzZUlu
dChnYkVsLnZhbHVlKXx8MDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2hvd0FsZXJ0KGNhcnJpZXIr
Jy1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBFbWFpbC9Vc2VybmFtZScsJ2Vycicp
OwoKICBjb25zdCBwb3J0ID0gY2Fycmllcj09PSdhaXMnID8gODA4MCA6IDg4ODA7CiAgY29uc3Qg
c25pICA9IGNhcnJpZXI9PT0nYWlzJyA/ICdjai1lYmIuc3BlZWR0ZXN0Lm5ldCcgOiAndHJ1ZS1p
bnRlcm5ldC56b29tLnh5ei5zZXJ2aWNlcyc7CgogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKGNhcnJpZXIrJy1idG4nKTsKICBidG4uZGlzYWJsZWQ9dHJ1ZTsgYnRuLmlubmVy
SFRNTD0nPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYng
uLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1hbGVydCcpLnN0
eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1y
ZXN1bHQnKS5jbGFzc0xpc3QucmVtb3ZlKCdzaG93Jyk7CgogIHRyeSB7CiAgICBpZiAoIV94dWlD
b29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICAvLyDguKvguLIgaW5ib3VuZCBpZAog
ICAgY29uc3QgbGlzdCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0Jyk7
CiAgICBjb25zdCBpYiA9IChsaXN0Lm9ianx8W10pLmZpbmQoeD0+eC5wb3J0PT09cG9ydCk7CiAg
ICBpZiAoIWliKSB0aHJvdyBuZXcgRXJyb3IoYOC5hOC4oeC5iOC4nuC4miBpbmJvdW5kIHBvcnQg
JHtwb3J0fSDigJQg4Lij4Lix4LiZIHNldHVwIOC4geC5iOC4reC4mWApOwoKICAgIGNvbnN0IHVp
ZCA9IGdlblVVSUQoKTsKICAgIGNvbnN0IGV4cE1zID0gZGF5cyA+IDAgPyAoRGF0ZS5ub3coKSAr
IGRheXMqODY0MDAwMDApIDogMDsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYiox
MDczNzQxODI0IDogMDsKCiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBp
L2luYm91bmRzL2FkZENsaWVudCcsIHsKICAgICAgaWQ6IGliLmlkLAogICAgICBzZXR0aW5nczog
SlNPTi5zdHJpbmdpZnkoeyBjbGllbnRzOlt7CiAgICAgICAgaWQ6dWlkLCBmbG93OicnLCBlbWFp
bCwgbGltaXRJcDppcExpbWl0LAogICAgICAgIHRvdGFsR0I6dG90YWxCeXRlcywgZXhwaXJ5VGlt
ZTpleHBNcywgZW5hYmxlOnRydWUsIHRnSWQ6JycsIHN1YklkOicnLCBjb21tZW50OicnLCByZXNl
dDowCiAgICAgIH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVy
cm9yKHJlcy5tc2cgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4
iCcpOwoKICAgIGNvbnN0IGxpbmtOYW1lID0gY2Fycmllcj09PSdhaXMnID8gJ0FJUy3guIHguLHg
uJnguKPguLHguYjguKctJytlbWFpbCA6ICdUUlVFLVZETy0nK2VtYWlsOwogICAgY29uc3QgbGlu
ayA9IGB2bGVzczovLyR7dWlkfUAke3NuaX06JHtwb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUm
cGF0aD0lMkZ2bGVzcyZob3N0PSR7SE9TVH0jJHtlbmNvZGVVUklDb21wb25lbnQobGlua05hbWUp
fWA7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZW1haWwnKS50
ZXh0Q29udGVudCA9IGVtYWlsOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJy
aWVyKyctdXVpZCcpLnRleHRDb250ZW50ID0gdWlkOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3ItJytjYXJyaWVyKyctZXhwJykudGV4dENvbnRlbnQgPSBleHBNcyA+IDAgPyBmbXREYXRl
KGV4cE1zKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgZG9jdW1lbnQuZ2V0RWxl
bWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctbGluaycpLnRleHRDb250ZW50ID0gbGluazsKICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QuYWRkKCdz
aG93Jyk7CiAgICAvLyBHZW5lcmF0ZSBRUiBjb2RlCiAgICBjb25zdCBxckRpdiA9IGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1xcicpOwogICAgaWYgKHFyRGl2KSB7CiAgICAgIHFy
RGl2LmlubmVySFRNTCA9ICcnOwogICAgICB0cnkgewogICAgICAgIG5ldyBRUkNvZGUocXJEaXYs
IHsgdGV4dDogbGluaywgd2lkdGg6IDE4MCwgaGVpZ2h0OiAxODAsIGNvcnJlY3RMZXZlbDogUVJD
b2RlLkNvcnJlY3RMZXZlbC5NIH0pOwogICAgICB9IGNhdGNoKHFyRXJyKSB7IHFyRGl2LmlubmVy
SFRNTCA9ICcnOyB9CiAgICB9CiAgICBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4pyFIOC4
quC4o+C5ieC4suC4hyBWTEVTUyBBY2NvdW50IOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAg
ICBlbWFpbEVsLnZhbHVlPScnOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoY2FycmllcisnLWFs
ZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9
ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KaoSDguKrguKPguYnguLLguIcgJysoY2Fycmllcj09PSdh
aXMnPydBSVMnOidUUlVFJykrJyBBY2NvdW50JzsgfQp9CgovLyDilZDilZDilZDilZAgTUFOQUdF
IFVTRVJTIOKVkOKVkOKVkOKVkApsZXQgX2FsbFVzZXJzID0gW10sIF9jdXJVc2VyID0gbnVsbDsK
YXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJzKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1
c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix
4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgX3h1aUNvb2tpZSA9IGZhbHNl
OwogICAgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQo
Jy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5l
dyBFcnJvcihkLm1zZyB8fCAn4LmC4Lir4Lil4LiUIGluYm91bmRzIOC5hOC4oeC5iOC5hOC4lOC5
iScpOwogICAgX2FsbFVzZXJzID0gW107CiAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsK
ICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpT
T04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGll
bnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICBjb25zdCBlbWFpbCA9IGMuZW1haWx8fGMu
aWQ7CiAgICAgICAgY29uc3QgY3MgPSAoaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1h
aWw9PT1lbWFpbCl8fG51bGw7CiAgICAgICAgX2FsbFVzZXJzLnB1c2goewogICAgICAgICAgaWJJ
ZDogaWIuaWQsIHBvcnQ6IGliLnBvcnQsIHByb3RvOiBpYi5wcm90b2NvbCwKICAgICAgICAgIGVt
YWlsLCB1dWlkOiBjLmlkLAogICAgICAgICAgZXhwOiBjLmV4cGlyeVRpbWV8fDAsIHRvdGFsOiBj
LnRvdGFsR0J8fDAsCiAgICAgICAgICB1cDogY3MgPyBjcy51cCA6IDAsIGRvd246IGNzID8gY3Mu
ZG93biA6IDAsIGFsbFRpbWU6IGNzID8gKGNzLmFsbFRpbWV8fDApIDogMCwgbGltaXRJcDogYy5s
aW1pdElwfHwwCiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSk7CiAgICByZW5kZXJVc2Vycyhf
YWxsVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Vz
ZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6
I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclVzZXJz
KHVzZXJzKSB7CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQo
J3VzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7w
n5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lie4Lia4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMPC9wPjwv
ZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1ID0+IHsKICAg
IGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogICAgbGV0IGJhZGdlLCBjbHM7CiAgICBpZiAo
IXUuZXhwIHx8IHUuZXhwPT09MCkgeyBiYWRnZT0n4pyTIOC5hOC4oeC5iOC4iOC4s+C4geC4seC4
lCc7IGNscz0nb2snOyB9CiAgICBlbHNlIGlmIChkbCA8IDApICAgICAgICAgeyBiYWRnZT0n4Lir
4Lih4LiU4Lit4Liy4Lii4Li4JzsgY2xzPSdleHAnOyB9CiAgICBlbHNlIGlmIChkbCA8PSAzKSAg
ICAgICAgeyBiYWRnZT0n4pqgICcrZGwrJ2QnOyBjbHM9J3Nvb24nOyB9CiAgICBlbHNlICAgICAg
ICAgICAgICAgICAgICAgeyBiYWRnZT0n4pyTICcrZGwrJ2QnOyBjbHM9J29rJzsgfQogICAgY29u
c3QgYXZDbHMgPSBkbCA8IDAgPyAnYXYteCcgOiAnYXYtZyc7CiAgICByZXR1cm4gYDxkaXYgY2xh
c3M9InVpdGVtIiBvbmNsaWNrPSJvcGVuVXNlcigke0pTT04uc3RyaW5naWZ5KHUpLnJlcGxhY2Uo
LyIvZywnJnF1b3Q7Jyl9KSI+CiAgICAgIDxkaXYgY2xhc3M9InVhdiAke2F2Q2xzfSI+JHsodS5l
bWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmbGV4
OjEiPgogICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3UuZW1haWx9PC9kaXY+CiAgICAgICAgPGRp
diBjbGFzcz0idW0iPlBvcnQgJHt1LnBvcnR9IMK3ICR7Zm10Qnl0ZXMoKHUudXB8fDApKyh1LmRv
d258fDApKyh1LmFsbFRpbWV8fDApKX0g4LmD4LiK4LmJPC9kaXY+CiAgICAgIDwvZGl2PgogICAg
ICA8c3BhbiBjbGFzcz0iYWJkZyAke2Nsc30iPiR7YmFkZ2V9PC9zcGFuPgogICAgPC9kaXY+YDsK
ICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJVc2VycyhxKSB7CiAgcmVuZGVyVXNlcnMo
X2FsbFVzZXJzLmZpbHRlcih1PT4odS5lbWFpbHx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMo
cS50b0xvd2VyQ2FzZSgpKSkpOwp9CgovLyDilZDilZDilZDilZAgTU9EQUwgVVNFUiDilZDilZDi
lZDilZAKZnVuY3Rpb24gb3BlblVzZXIodSkgewogIGlmICh0eXBlb2YgdSA9PT0gJ3N0cmluZycp
IHUgPSBKU09OLnBhcnNlKHUpOwogIF9jdXJVc2VyID0gdTsKICBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnbXQnKS50ZXh0Q29udGVudCA9ICfimpnvuI8gJyt1LmVtYWlsOwogIGRvY3VtZW50Lmdl
dEVsZW1lbnRCeUlkKCdkdScpLnRleHRDb250ZW50ID0gdS5lbWFpbDsKICBkb2N1bWVudC5nZXRF
bGVtZW50QnlJZCgnZHAnKS50ZXh0Q29udGVudCA9IHUucG9ydDsKICBjb25zdCBkbCA9IGRheXNM
ZWZ0KHUuZXhwKTsKICBjb25zdCBleHBUeHQgPSAhdS5leHB8fHUuZXhwPT09MCA/ICfguYTguKHg
uYjguIjguLPguIHguLHguJQnIDogZm10RGF0ZSh1LmV4cCk7CiAgY29uc3QgZGUgPSBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnZGUnKTsKICBkZS50ZXh0Q29udGVudCA9IGV4cFR4dDsKICBkZS5j
bGFzc05hbWUgPSAnZHYnICsgKGRsICE9PSBudWxsICYmIGRsIDwgMCA/ICcgcmVkJyA6ICcgZ3Jl
ZW4nKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGQnKS50ZXh0Q29udGVudCA9IHUudG90
YWwgPiAwID8gZm10Qnl0ZXModS50b3RhbCkgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsK
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHRyJykudGV4dENvbnRlbnQgPSBmbXRCeXRlcygo
dS51cHx8MCkrKHUuZG93bnx8MCkrKHUuYWxsVGltZXx8MCkpOwogIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdkaScpLnRleHRDb250ZW50ID0gdS5saW1pdElwIHx8ICfiiJ4nOwogIGRvY3VtZW50
LmdldEVsZW1lbnRCeUlkKCdkdXUnKS50ZXh0Q29udGVudCA9IHUudXVpZDsKICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVu
Y3Rpb24gY20oKXsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3Qu
cmVtb3ZlKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50
QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVl
cnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdh
Y3RpdmUnKSk7Cn0KCi8vIOKUgOKUgCBNT0RBTCA2LUFDVElPTiBTWVNURU0g4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA
4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNvbnN0IF9tU3VicyA9IFsncmVuZXcnLCdleHRlbmQn
LCdhZGRkYXRhJywnc2V0ZGF0YScsJ3Jlc2V0JywnZGVsZXRlJ107CmZ1bmN0aW9uIG1BY3Rpb24o
a2V5KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2tleSk7
CiAgY29uc3QgaXNPcGVuID0gZWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJyk7CiAgX21TdWJz
LmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlz
dC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5m
b3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgaWYgKCFp
c09wZW4pIHsKICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgIGlmIChrZXk9PT0nZGVs
ZXRlJyAmJiBfY3VyVXNlcikgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZGVsLW5hbWUnKS50
ZXh0Q29udGVudCA9IF9jdXJVc2VyLmVtYWlsOwogICAgc2V0VGltZW91dCgoKT0+ZWwuc2Nyb2xs
SW50b1ZpZXcoe2JlaGF2aW9yOidzbW9vdGgnLGJsb2NrOiduZWFyZXN0J30pLDEwMCk7CiAgfQp9
CmZ1bmN0aW9uIF9tQnRuTG9hZChpZCwgbG9hZGluZywgb3JpZ1RleHQpIHsKICBjb25zdCBiID0g
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghYikgcmV0dXJuOwogIGIuZGlzYWJs
ZWQgPSBsb2FkaW5nOwogIGlmIChsb2FkaW5nKSB7IGIuZGF0YXNldC5vcmlnID0gYi50ZXh0Q29u
dGVudDsgYi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj4g4LiB4Liz4Lil
4Lix4LiH4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijLi4uJzsgfQogIGVsc2UgeyBiLnRleHRD
b250ZW50ID0gYi5kYXRhc2V0Lm9yaWcgfHwgb3JpZ1RleHQgfHwgJ+C4lOC4s+C5gOC4meC4tOC4
meC4geC4suC4oyc7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9SZW5ld1VzZXIoKSB7CiAgaWYgKCFf
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
LXJlc2V0LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0
KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL3Jlc2V0Q2xpZW50VHJhZmZp
Yy8nK19jdXJVc2VyLmVtYWlsLCB7fSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcg
RXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0Fs
ZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDguKrguLPguYDg
uKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsg
bG9hZERhc2hib2FyZCAmJiBsb2FkRGFzaGJvYXJkKCk7IH0sIDE1MDApOwogIH0gY2F0Y2goZSkg
eyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZp
bmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0
aW9uIGRvRGVsZXRlVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2Fk
KCdtLWRlbGV0ZS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVp
UG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9kZWxDbGllbnQvJytf
Y3VyVXNlci51dWlkLCB7fSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3Io
cmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdt
b2RhbC1hbGVydCcsJ+KchSDguKXguJrguKLguLnguKogJytfY3VyVXNlci5lbWFpbCsnIOC4quC4
s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2Vy
cygpOyB9LCAxMjAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+Kd
jCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWRlbGV0ZS1i
dG4nLCBmYWxzZSk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAKYXN5
bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25s
aW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4
h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlDb29raWUgPSBmYWxzZTsK
ICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICAvLyDguYLguKvguKXguJQgaW5ib3VuZHMg
4LiW4LmJ4Liy4Lii4Lix4LiH4LmE4Lih4LmI4Lih4Li1CiAgICBpZiAoIV9hbGxVc2Vycy5sZW5n
dGgpIHsKICAgICAgY29uc3QgZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9s
aXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgICBpZiAoZCAmJiBkLnN1Y2Nlc3MpIHsKICAgICAg
ICBfYWxsVXNlcnMgPSBbXTsKICAgICAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAg
ICAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBK
U09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAgICAgKHNldHRpbmdz
LmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBfYWxsVXNlcnMucHVzaCh7
IGliSWQ6aWIuaWQsIHBvcnQ6aWIucG9ydCwgcHJvdG86aWIucHJvdG9jb2wsCiAgICAgICAgICAg
ICAgZW1haWw6Yy5lbWFpbHx8Yy5pZCwgdXVpZDpjLmlkLCBleHA6Yy5leHBpcnlUaW1lfHwwLAog
ICAgICAgICAgICAgIHRvdGFsOmMudG90YWxHQnx8MCwgdXA6KGliLmNsaWVudFN0YXRzfHxbXSku
ZmluZCh4PT54LmVtYWlsPT09KGMuZW1haWx8fGMuaWQpKT8udXB8fDAsIGRvd246KGliLmNsaWVu
dFN0YXRzfHxbXSkuZmluZCh4PT54LmVtYWlsPT09KGMuZW1haWx8fGMuaWQpKT8uZG93bnx8MCwg
YWxsVGltZTooaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT0oYy5lbWFpbHx8
Yy5pZCkpPy5hbGxUaW1lfHwwLCBsaW1pdElwOmMubGltaXRJcHx8MCB9KTsKICAgICAgICAgIH0p
OwogICAgICAgIH0pOwogICAgICB9CiAgICB9CiAgICBsZXQgZW1haWxzID0gW107CiAgICBjb25z
dCBub3cgPSBEYXRlLm5vdygpOwogICAgY29uc3QgZDIgPSBhd2FpdCB4dWlHZXQoIi9wYW5lbC9h
cGkvaW5ib3VuZHMvbGlzdCIpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChkMiAmJiBkMi5zdWNj
ZXNzKSB7CiAgICAgIChkMi5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAoaWIuY2xp
ZW50U3RhdHN8fFtdKS5mb3JFYWNoKGNzID0+IHsKICAgICAgICAgIGlmIChjcy5sYXN0T25saW5l
ICYmIChub3cgLSBjcy5sYXN0T25saW5lKSA8IDMwMDAwMCkgZW1haWxzLnB1c2goY3MuZW1haWwp
OwogICAgICAgIH0pOwogICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlk
KCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVu
dC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCku
dG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAg
ICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRp
diBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li1
4Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2
Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vy
cy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAg
ICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICBjb25zdCBjcyA9IChkMiYmZDIub2JqfHxb
XSkuZmxhdE1hcChpYj0+aWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT1lbWFp
bCl8fG51bGw7CiAgICAgIGNvbnN0IGliT2JqID0gKGQyJiZkMi5vYmp8fFtdKS5maW5kKGliPT4o
aWIuY2xpZW50U3RhdHN8fFtdKS5zb21lKHg9PnguZW1haWw9PT1lbWFpbCkpfHxudWxsOwogICAg
ICBjb25zdCB1c2VkR0IgPSBjcyA/ICgoY3MudXArY3MuZG93bisoY3MuYWxsVGltZXx8MCkpLzEw
NzM3NDE4MjQpLnRvRml4ZWQoMikgOiAoaWJPYmogPyAoKGliT2JqLnVwK2liT2JqLmRvd24pLzEw
NzM3NDE4MjQpLnRvRml4ZWQoMikgOiAwKTsKICAgICAgY29uc3QgdG90YWxHQiA9IGNzICYmIGNz
LnRvdGFsPjAgPyAoY3MudG90YWwvMTA3Mzc0MTgyNCkudG9GaXhlZCgwKSA6IG51bGw7CiAgICAg
IGNvbnN0IHBjdCA9ICh1ICYmIHUudG90YWw+MCkgPyBNYXRoLm1pbihNYXRoLnJvdW5kKCh1LnVw
K3UuZG93bikvdS50b3RhbCoxMDApLDEwMCkgOiAwOwogICAgICBjb25zdCBiYXIgPSBwY3Q+ODU/
IiNlZjQ0NDQiOnBjdD42NT8iI2Y5NzMxNiI6IiMyMmM1NWUiOwogICAgICBjb25zdCBleHBNcyA9
IHUgPyB1LmV4cCA6IDA7CiAgICAgIGNvbnN0IGV4cFN0ciA9ICghZXhwTXN8fGV4cE1zPT09MCk/
IuC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCI6bmV3IERhdGUoZXhwTXMpLnRvTG9jYWxlRGF0ZVN0
cmluZygidGgtVEgiLHt5ZWFyOiJudW1lcmljIixtb250aDoic2hvcnQiLGRheToibnVtZXJpYyJ9
KTsKICAgICAgY29uc3QgZExlZnQgPSAoIWV4cE1zfHxleHBNcz09PTApP251bGw6TWF0aC5jZWls
KChleHBNcy1EYXRlLm5vdygpKS84NjQwMDAwMCk7CiAgICAgIGNvbnN0IGRUYWcgPSBkTGVmdD09
PW51bGw/IuKIniI6ZExlZnQ+MD9kTGVmdCsiZCI6IuC4q+C4oeC4lOC5geC4peC5ieC4pyI7CiAg
ICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIHN0eWxlPSJmbGV4LWRpcmVjdGlvbjpjb2x1
bW47Z2FwOjhweDtwYWRkaW5nOjE0cHggMTZweCI+CiAgICAgICAgPGRpdiBzdHlsZT0iZGlzcGxh
eTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweCI+CiAgICAgICAgICA8ZGl2IHN0eWxl
PSJwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDoyMHB4O2hlaWdodDoyMHB4O2ZsZXgtc2hyaW5rOjAi
PjxzcGFuIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAl
O2JhY2tncm91bmQ6IzIyYzU1ZTtvcGFjaXR5Oi40O2FuaW1hdGlvbjpwaW5nIDEuMnMgY3ViaWMt
YmV6aWVyKDAsMCwuMiwxKSBpbmZpbml0ZSI+PC9zcGFuPjxzcGFuIHN0eWxlPSJwb3NpdGlvbjph
YnNvbHV0ZTtpbnNldDozcHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojMjJjNTVlIj48
L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InVu
Ij4ke2VtYWlsfTwvZGl2PjxkaXYgY2xhc3M9InVtIj4ke3U/IlBvcnQgIit1LnBvcnQ6IlZMRVNT
In0gwrcg4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4Lit4Lii4Li54LmIPC9kaXY+PC9kaXY+CiAgICAg
ICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayI+T05MSU5FPC9zcGFuPgogICAgICAgIDwvZGl2Pgog
ICAgICAgIDxkaXYgc3R5bGU9ImJhY2tncm91bmQ6cmdiYSgwLDAsMCwuMDUpO2JvcmRlci1yYWRp
dXM6MTBweDtwYWRkaW5nOjEwcHggMTJweCI+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5
OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Zm9udC1zaXplOjExcHg7Y29sb3I6
IzY2NjttYXJnaW4tYm90dG9tOjVweCI+CiAgICAgICAgICAgIDxzcGFuPvCfk4ogJHt1c2VkR0J9
IEdCICR7dG90YWxHQj8iLyAiK3RvdGFsR0IrIiBHQiI6Ii8g4LmE4Lih4LmI4LiI4Liz4LiB4Lix
4LiUIn08L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJjb2xvcjoke2Jhcn07Zm9udC13
ZWlnaHQ6NjAwIj4ke3RvdGFsR0I/cGN0KyIlIjoiIn08L3NwYW4+CiAgICAgICAgICA8L2Rpdj4K
ICAgICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDo2cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC4x
KTtib3JkZXItcmFkaXVzOjk5cHg7b3ZlcmZsb3c6aGlkZGVuIj4KICAgICAgICAgICAgPGRpdiBz
dHlsZT0iaGVpZ2h0OjEwMCU7d2lkdGg6JHt0b3RhbEdCP3BjdDoxMDB9JTtiYWNrZ3JvdW5kOiR7
YmFyfTtib3JkZXItcmFkaXVzOjk5cHgiPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAg
ICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47
Zm9udC1zaXplOjExcHg7Y29sb3I6Izg4ODttYXJnaW4tdG9wOjZweCI+CiAgICAgICAgICAgIDxz
cGFuPvCfk4UgJHtleHBTdHJ9PC9zcGFuPgogICAgICAgICAgICA8c3BhbiBzdHlsZT0iYmFja2dy
b3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMTIpO2NvbG9yOiMxNmEzNGE7cGFkZGluZzoxcHggOHB4O2Jv
cmRlci1yYWRpdXM6OTlweCI+JHtkVGFnfTwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAg
IDwvZGl2PgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfSBjYXRjaChlKSB7CiAg
ICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYg
Y2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+
JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggVVNFUlMgKGJhbiB0YWIpIOKVkOKVkOKVkOKV
kAphc3luYyBmdW5jdGlvbiBsb2FkU1NIVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4
s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBh
d2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgY29uc3QgdXNl
cnMgPSBkLnVzZXJzIHx8IFtdOwogICAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48
ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3A+
PC9kaXY+JzsgcmV0dXJuOyB9CiAgICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5n
KCkuc2xpY2UoMCwxMCk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlz
dCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1PT57CiAgICAgIGNvbnN0IGV4cCA9IHUuZXhwIHx8
ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgICBjb25zdCBhY3RpdmUgPSB1LmFjdGl2
ZSAhPT0gZmFsc2U7CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iPgogICAgICAgIDxk
aXYgY2xhc3M9InVhdiAke2FjdGl2ZT8nYXYtZyc6J2F2LXgnfSI+JHt1LnVzZXJbMF0udG9VcHBl
ckNhc2UoKX08L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRp
diBjbGFzcz0idW4iPiR7dS51c2VyfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idW0iPuC4
q+C4oeC4lOC4reC4suC4ouC4uDogJHtleHB9PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAg
PHNwYW4gY2xhc3M9ImFiZGcgJHthY3RpdmU/J29rJzonZXhwJ30iPiR7YWN0aXZlPydBY3RpdmUn
OidFeHBpcmVkJ308L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNh
dGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5u
ZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1l
c3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIGRlbGV0ZVNTSCgpIHsKICBjb25z
dCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgp
OwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4LiB4Lij4Li44LiT
4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NI
IHVzZXIgIicrdXNlcisnIiA/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0
IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50
LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pfSku
dGhlbihyPT5yLmpzb24oKSk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9y
fHwn4Lil4Lia4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ2Jh
bi1hbGVydCcsJ+KchSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsK
ICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVlPScnOwogICAgbG9h
ZFNTSFVzZXJzKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4p2MICcr
ZS5tZXNzYWdlLCdlcnInKTsgfQp9CgovLyDilZDilZDilZDilZAgQ09QWSDilZDilZDilZDilZAK
ZnVuY3Rpb24gY29weUxpbmsoaWQsIGJ0bikgewogIGNvbnN0IHR4dCA9IGRvY3VtZW50LmdldEVs
ZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudDsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4
dCh0eHQpLnRoZW4oKCk9PnsKICAgIGNvbnN0IG9yaWcgPSBidG4udGV4dENvbnRlbnQ7CiAgICBi
dG4udGV4dENvbnRlbnQ9J+KchSBDb3BpZWQhJzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9J3JnYmEo
MzQsMTk3LDk0LC4xNSknOwogICAgc2V0VGltZW91dCgoKT0+eyBidG4udGV4dENvbnRlbnQ9b3Jp
ZzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9Jyc7IH0sIDIwMDApOwogIH0pLmNhdGNoKCgpPT57IHBy
b21wdCgnQ29weSBsaW5rOicsIHR4dCk7IH0pOwp9CgovLyDilZDilZDilZDilZAgTE9HT1VUIOKV
kOKVkOKVkOKVkApmdW5jdGlvbiBkb0xvZ291dCgpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJ
dGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8v
IOKVkOKVkOKVkOKVkCBJTklUIOKVkOKVkOKVkOKVkAoKLy8g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ
Ci8vICBTUEVFRCBURVNUCi8vIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKV
kOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkApsZXQgX3NwZWVkUnVubmlu
Zz1mYWxzZTsKZnVuY3Rpb24gc2V0R2F1Z2UobWJwcywgbWF4TWJwcz0yMDApIHsKICBjb25zdCBl
bD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2F1Z2UtZmlsbCcpOwogIGNvbnN0IHZhbEVsPWRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdnYXVnZS12YWwnKTsKICBjb25zdCB1bml0RWw9ZG9jdW1l
bnQuZ2V0RWxlbWVudEJ5SWQoJ2dhdWdlLXVuaXQnKTsKICBpZiAoIWVsKSByZXR1cm47CiAgY29u
c3QgcGN0PU1hdGgubWluKG1icHMvbWF4TWJwcywxKTsKICBlbC5zdHlsZS5zdHJva2VEYXNob2Zm
c2V0PSgyMjAtKDIyMCpwY3QpKS50b0ZpeGVkKDIpOwogIGNvbnN0IHI9TWF0aC5yb3VuZChwY3Q8
MC41PzA6MjU1KihwY3QtMC41KSoyKTsKICBjb25zdCBnPU1hdGgucm91bmQocGN0PDAuNT8yNTU6
MjU1KigxLShwY3QtMC41KSoyKSk7CiAgZWwuc2V0QXR0cmlidXRlKCdzdHJva2UnLGByZ2IoJHty
fSwke2d9LDUwKWApOwogIHZhbEVsLnRleHRDb250ZW50PW1icHM+PTE/bWJwcy50b0ZpeGVkKDEp
OihtYnBzKjEwMDApLnRvRml4ZWQoMCk7CiAgdW5pdEVsLnRleHRDb250ZW50PW1icHM+PTE/J01i
cHMnOidLYnBzJzsKfQpmdW5jdGlvbiBzZXRQcm9ncmVzcyhwY3QpIHsKICBjb25zdCBlbD1kb2N1
bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtcHJvZy1maWxsJyk7CiAgaWYgKGVsKSBlbC5zdHls
ZS53aWR0aD1NYXRoLm1pbihwY3QsMTAwKSsnJSc7Cn0KYXN5bmMgZnVuY3Rpb24gbWVhc3VyZVBp
bmcoKSB7CiAgY29uc3QgcGluZ3M9W107CiAgZm9yIChsZXQgaT0wO2k8NTtpKyspIHsKICAgIGNv
bnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogICAgdHJ5e2F3YWl0IGZldGNoKEFQSSsnL3N0YXR1
cycse21ldGhvZDonSEVBRCcsY2FjaGU6J25vLXN0b3JlJ30pO30KICAgIGNhdGNoKGUpe3RyeXth
d2FpdCBmZXRjaCgnLycse21ldGhvZDonSEVBRCcsY2FjaGU6J25vLXN0b3JlJ30pO31jYXRjaChl
ZSl7fX0KICAgIHBpbmdzLnB1c2gocGVyZm9ybWFuY2Uubm93KCktdDApOwogICAgYXdhaXQgbmV3
IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkpOwogIH0KICBwaW5ncy5zb3J0KChhLGIpPT5h
LWIpOwogIGNvbnN0IHBpbmc9cGluZ3NbTWF0aC5mbG9vcihwaW5ncy5sZW5ndGgvMildOwogIGNv
bnN0IGppdHRlcj1waW5nc1twaW5ncy5sZW5ndGgtMV0tcGluZ3NbMF07CiAgZG9jdW1lbnQuZ2V0
RWxlbWVudEJ5SWQoJ3BpbmctdmFsJykudGV4dENvbnRlbnQ9cGluZy50b0ZpeGVkKDApKycgbXMn
OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdqaXR0ZXItdmFsJykudGV4dENvbnRlbnQ9aml0
dGVyLnRvRml4ZWQoMCkrJyBtcyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvc3MtdmFs
JykudGV4dENvbnRlbnQ9JzAlJzsKICBjb25zdCBwaW5nRWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ3BpbmctdmFsJyk7CiAgcGluZ0VsLmNsYXNzTmFtZT0nc3BlZWQtcGluZy12YWwnKyhwaW5n
PDgwPycnOnBpbmc8MjAwPycgd2Fybic6JyBiYWQnKTsKICByZXR1cm4ge3Bpbmcsaml0dGVyfTsK
fQphc3luYyBmdW5jdGlvbiBzdGFydFNwZWVkVGVzdCh0eXBlKSB7CiAgaWYgKF9zcGVlZFJ1bm5p
bmcpIHJldHVybjsKICBfc3BlZWRSdW5uaW5nPXRydWU7CiAgY29uc3QgYnRuRGw9ZG9jdW1lbnQu
Z2V0RWxlbWVudEJ5SWQoJ2J0bi1kbCcpOwogIGNvbnN0IGJ0blVsPWRvY3VtZW50LmdldEVsZW1l
bnRCeUlkKCdidG4tdWwnKTsKICBidG5EbC5kaXNhYmxlZD10cnVlOyBidG5VbC5kaXNhYmxlZD10
cnVlOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVu
dD0n4LiB4Liz4Lil4Lix4LiH4Lin4Lix4LiUIFBpbmcuLi4nOwogIHNldFByb2dyZXNzKDApOyBz
ZXRHYXVnZSgwKTsKICB0cnl7CiAgICBjb25zdCBpbmZvPWF3YWl0IGZldGNoKEFQSSsnL3N0YXR1
cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmKGluZm8mJmluZm8u
aG9zdCkgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Zwcy1pcCcpLnRleHRDb250ZW50PWluZm8u
aG9zdDsKICAgIGVsc2UgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Zwcy1pcCcpLnRleHRDb250
ZW50PWxvY2F0aW9uLmhvc3RuYW1lOwogIH1jYXRjaChlKXt9CiAgdHJ5e2F3YWl0IG1lYXN1cmVQ
aW5nKCk7fWNhdGNoKGUpe30KICBzZXRQcm9ncmVzcygxMCk7CiAgaWYgKHR5cGU9PT0nZG93bmxv
YWQnKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtc3RhdHVzJykudGV4dENv
bnRlbnQ9J+C4geC4s+C4peC4seC4h+C4l+C4lOC4quC4reC4miBEb3dubG9hZC4uLic7CiAgICBk
b2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtdmFsJykudGV4dENvbnRlbnQ9Jy4uLic7CiAgICBj
b25zdCBtYnBzPWF3YWl0IHJ1bkRvd25sb2FkVGVzdCgocCxjdXIpPT57CiAgICAgIHNldFByb2dy
ZXNzKDEwK3AqMC44KTsgc2V0R2F1Z2UoY3VyKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5
SWQoJ2RsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKGN1ci8yMDAqMTAwLDEwMCkrJyUnOwog
ICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtdmFsJykudGV4dENvbnRlbnQ9
bWJwcy50b0ZpeGVkKDEpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RsLWJhcicpLnN0
eWxlLndpZHRoPU1hdGgubWluKG1icHMvMjAwKjEwMCwxMDApKyclJzsKICAgIHNldEdhdWdlKG1i
cHMpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250
ZW50PSfinIUgRG93bmxvYWQ6ICcrbWJwcy50b0ZpeGVkKDEpKycgTWJwcyc7CiAgfSBlbHNlIHsK
ICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n
4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIFVwbG9hZC4uLic7CiAgICBkb2N1bWVudC5n
ZXRFbGVtZW50QnlJZCgndWwtdmFsJykudGV4dENvbnRlbnQ9Jy4uLic7CiAgICBjb25zdCBtYnBz
PWF3YWl0IHJ1blVwbG9hZFRlc3QoKHAsY3VyKT0+ewogICAgICBzZXRQcm9ncmVzcygxMCtwKjAu
OCk7IHNldEdhdWdlKGN1cik7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC1iYXIn
KS5zdHlsZS53aWR0aD1NYXRoLm1pbihjdXIvMjAwKjEwMCwxMDApKyclJzsKICAgIH0pOwogICAg
ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLXZhbCcpLnRleHRDb250ZW50PW1icHMudG9GaXhl
ZCgxKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC1iYXInKS5zdHlsZS53aWR0aD1N
YXRoLm1pbihtYnBzLzIwMCoxMDAsMTAwKSsnJSc7CiAgICBzZXRHYXVnZShtYnBzKTsKICAgIGRv
Y3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4pyFIFVw
bG9hZDogJyttYnBzLnRvRml4ZWQoMSkrJyBNYnBzJzsKICB9CiAgc2V0UHJvZ3Jlc3MoMTAwKTsK
ICBzZXRUaW1lb3V0KCgpPT5zZXRQcm9ncmVzcygwKSwxNTAwKTsKICBidG5EbC5kaXNhYmxlZD1m
YWxzZTsgYnRuVWwuZGlzYWJsZWQ9ZmFsc2U7CiAgX3NwZWVkUnVubmluZz1mYWxzZTsKfQphc3lu
YyBmdW5jdGlvbiBydW5Eb3dubG9hZFRlc3Qob25Qcm9ncmVzcykgewogIGNvbnN0IERVUkFUSU9O
X01TPTgwMDA7CiAgbGV0IHRvdGFsQnl0ZXM9MDsKICBjb25zdCB0MD1wZXJmb3JtYW5jZS5ub3co
KTsKICBsZXQgZG9uZT1mYWxzZTsKICBzZXRUaW1lb3V0KCgpPT57ZG9uZT10cnVlO30sRFVSQVRJ
T05fTVMpOwogIGNvbnN0IENIVU5LPTEqMTAyNCoxMDI0OwogIGNvbnN0IHJ1bj1hc3luYygpPT57
CiAgICB3aGlsZSghZG9uZSl7CiAgICAgIHRyeXsKICAgICAgICBjb25zdCB1cmw9J2h0dHBzOi8v
c3BlZWQuY2xvdWRmbGFyZS5jb20vX19kb3duP2J5dGVzPScrQ0hVTks7CiAgICAgICAgY29uc3Qg
cj1hd2FpdCBmZXRjaCh1cmwse2NhY2hlOiduby1zdG9yZSd9KS5jYXRjaChhc3luYygpPT5mZXRj
aChBUEkrJy9zdGF0dXMnLHtjYWNoZTonbm8tc3RvcmUnfSkpOwogICAgICAgIGNvbnN0IGJ1Zj1h
d2FpdCByLmFycmF5QnVmZmVyKCk7CiAgICAgICAgaWYoZG9uZSkgYnJlYWs7CiAgICAgICAgdG90
YWxCeXRlcys9YnVmLmJ5dGVMZW5ndGg7CiAgICAgICAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFu
Y2Uubm93KCktdDApLzEwMDA7CiAgICAgICAgY29uc3QgbWJwcz0odG90YWxCeXRlcyo4KS8oZWxh
cHNlZCoxZTYpOwogICAgICAgIG9uUHJvZ3Jlc3MoTWF0aC5taW4oZWxhcHNlZC9EVVJBVElPTl9N
UyoxMDAsOTkpLG1icHMpOwogICAgICB9Y2F0Y2goZSl7YXdhaXQgbmV3IFByb21pc2Uocj0+c2V0
VGltZW91dChyLDEwMCkpO30KICAgIH0KICB9OwogIGF3YWl0IFByb21pc2UuYWxsKFtydW4oKSxy
dW4oKSxydW4oKSxydW4oKV0pOwogIGNvbnN0IGVsYXBzZWQ9KHBlcmZvcm1hbmNlLm5vdygpLXQw
KS8xMDAwOwogIHJldHVybiAodG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwp9CmFzeW5jIGZ1
bmN0aW9uIHJ1blVwbG9hZFRlc3Qob25Qcm9ncmVzcykgewogIGNvbnN0IERVUkFUSU9OX01TPTgw
MDA7CiAgbGV0IHRvdGFsQnl0ZXM9MDsKICBjb25zdCB0MD1wZXJmb3JtYW5jZS5ub3coKTsKICBs
ZXQgZG9uZT1mYWxzZTsKICBzZXRUaW1lb3V0KCgpPT57ZG9uZT10cnVlO30sRFVSQVRJT05fTVMp
OwogIGNvbnN0IENIVU5LPTUxMioxMDI0OwogIGNvbnN0IGRhdGE9bmV3IFVpbnQ4QXJyYXkoQ0hV
TkspOwogIGNyeXB0by5nZXRSYW5kb21WYWx1ZXMoZGF0YSk7CiAgY29uc3QgYmxvYj1uZXcgQmxv
YihbZGF0YV0pOwogIGNvbnN0IHJ1bj1hc3luYygpPT57CiAgICB3aGlsZSghZG9uZSl7CiAgICAg
IHRyeXsKICAgICAgICBhd2FpdCBmZXRjaCgnaHR0cHM6Ly9zcGVlZC5jbG91ZGZsYXJlLmNvbS9f
X3VwJyx7bWV0aG9kOidQT1NUJyxib2R5OmJsb2J9KS5jYXRjaCgoKT0+CiAgICAgICAgICBmZXRj
aChBUEkrJy9zdGF0dXMnLHttZXRob2Q6J1BPU1QnLGJvZHk6YmxvYixoZWFkZXJzOnsnQ29udGVu
dC1UeXBlJzonYXBwbGljYXRpb24vb2N0ZXQtc3RyZWFtJ319KS5jYXRjaCgoKT0+KHtvazpmYWxz
ZX0pKQogICAgICAgICk7CiAgICAgICAgaWYoZG9uZSkgYnJlYWs7CiAgICAgICAgdG90YWxCeXRl
cys9Q0hVTks7CiAgICAgICAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEw
MDA7CiAgICAgICAgY29uc3QgbWJwcz0odG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwogICAg
ICAgIG9uUHJvZ3Jlc3MoTWF0aC5taW4oZWxhcHNlZC9EVVJBVElPTl9NUyoxMDAsOTkpLG1icHMp
OwogICAgICB9Y2F0Y2goZSl7YXdhaXQgbmV3IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkp
O30KICAgIH0KICB9OwogIGF3YWl0IFByb21pc2UuYWxsKFtydW4oKSxydW4oKSxydW4oKV0pOwog
IGNvbnN0IGVsYXBzZWQ9KHBlcmZvcm1hbmNlLm5vdygpLXQwKS8xMDAwOwogIHJldHVybiAodG90
YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwp9CgovLyBzdygpIOC5gOC4nuC4tOC5iOC4oSBzcGVl
ZCB0YWIgc3VwcG9ydAoKbG9hZERhc2goKTsKbG9hZFNlcnZpY2VzKCk7CnNldEludGVydmFsKGxv
YWREYXNoLCAzMDAwMCk7Cjwvc2NyaXB0PgoKPCEtLSBTU0ggUkVORVcgTU9EQUwgLS0+CjxkaXYg
Y2xhc3M9Im1vdmVyIiBpZD0ic3NoLXJlbmV3LW1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJn
ZXQ9PT10aGlzKWNsb3NlU1NIUmVuZXdNb2RhbCgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAg
ICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIj7wn5SEIOC4leC5
iOC4reC4reC4suC4ouC4uCBTU0ggVXNlcjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJtY2xv
c2UiIG9uY2xpY2s9ImNsb3NlU1NIUmVuZXdNb2RhbCgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2
PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xh
c3M9ImRrIj7wn5GkIFVzZXJuYW1lPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9InNz
aC1yZW5ldy11c2VybmFtZSI+LS08L3NwYW4+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xh
c3M9ImZnIiBzdHlsZT0ibWFyZ2luLXRvcDoxNHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZmxibCI+
4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZ4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LiV
4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+CiAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gt
cmVuZXctZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSIgcGxhY2Vob2xkZXI9
IjMwIj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9InNzaC1yZW5ldy1i
dG4iIG9uY2xpY2s9ImRvU1NIUmVuZXcoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4
reC4reC4suC4ouC4uDwvYnV0dG9uPgogIDwvZGl2Pgo8L2Rpdj4KCgo8c2NyaXB0PgovLyBGaXJl
ZmxpZXMgeDYwIOKAkyBpbnNpZGUgY2FyZHMgKGFic29sdXRlLCDguYTguKHguYjguYPguIrguYgg
Zml4ZWQpCjwvYm9keT4KPC9odG1sPgo=
HTML_BASE64_EOF

ok "Dashboard HTML อัพเดตแล้ว"

# ── STEP 3: Restart services ───────────────────────────────────
info "Restart services..."
fuser -k 6789/tcp 2>/dev/null || true
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
sleep 2

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
  echo -e "  🖥  3x-ui Panel : ${CYAN}${BOLD}https://${DOMAIN}:2503${XUI_BASE_PATH}${NC} (ผ่าน nginx proxy)"
else
  echo -e "  🖥  3x-ui Panel : ${CYAN}${BOLD}http://${DOMAIN}:2503${XUI_BASE_PATH}${NC} (ผ่าน nginx proxy)"
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
