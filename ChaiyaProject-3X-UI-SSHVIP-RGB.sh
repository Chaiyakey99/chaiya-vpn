#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL v8 + PATCH (Combined)
#   Ubuntu 22.04 / 24.04 / 26.04
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

# ── UBUNTU VERSION CHECK ─────────────────────────────────────
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || grep VERSION_ID /etc/os-release | cut -d'"' -f2)
info "Ubuntu version: ${CYAN}${UBUNTU_VER}${NC}"
case "$UBUNTU_VER" in
  22.04|24.04|26.04) ok "Ubuntu ${UBUNTU_VER} รองรับแล้ว ✅" ;;
  *) warn "Ubuntu ${UBUNTU_VER} ยังไม่ได้ทดสอบ — อาจมีปัญหา" ;;
esac

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

# iptables-persistent ถูกตัดออก — ค้างเพราะ interactive prompt บน Ubuntu 24.04 / 26.04

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
ok "IPv4: ${CYAN}$SERVER_IP${NC}"

# ── ตรวจสอบ IPv6 ─────────────────────────────────────────────
USE_IPV6=0
SERVER_IPV6=""
info "ตรวจสอบ IPv6..."
_ipv6_check=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6 )[0-9a-f:]+' | grep -v '^::1' | head -1)
if [[ -n "$_ipv6_check" ]]; then
  # ทดสอบว่า IPv6 ใช้งานได้จริง (ping6 google)
  if ping6 -c 1 -W 3 google.com &>/dev/null 2>&1; then
    SERVER_IPV6=$(curl -s6 --max-time 5 https://api6.ipify.org 2>/dev/null || echo "$_ipv6_check")
    ok "พบ IPv6: ${CYAN}$SERVER_IPV6${NC}"
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  ตั้งค่า IP Mode${NC}"
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
    echo -e "  เซิร์ฟเวอร์นี้มี IPv6 พร้อมใช้งาน"
    echo -e "  IPv4 : ${CYAN}$SERVER_IP${NC}"
    echo -e "  IPv6 : ${CYAN}$SERVER_IPV6${NC}"
    echo ""
    echo -e "  ${BOLD}[1]${NC} ใช้ IPv4 (ค่าเริ่มต้น)"
    echo -e "  ${BOLD}[2]${NC} ใช้ IPv6 (ผู้ใช้ที่เชื่อมต่อจะเห็น IPv6)"
    echo ""
    while true; do
      read -rp "  เลือก [1/2]: " _ip_choice
      case "$_ip_choice" in
        1|"") USE_IPV6=0; ok "ใช้ IPv4: $SERVER_IP"; break ;;
        2)    USE_IPV6=1; ok "ใช้ IPv6: $SERVER_IPV6"; break ;;
        *)    warn "กรุณาเลือก 1 หรือ 2" ;;
      esac
    done
    echo -e "${YELLOW}════════════════════════════════════════${NC}"
  else
    warn "พบ IPv6 address แต่เชื่อมต่อออกนอกไม่ได้ — ใช้ IPv4 แทน"
  fi
else
  info "ไม่พบ IPv6 บนเครื่องนี้ — ใช้ IPv4"
fi



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
# ล็อกเวอร์ชัน v2.9.4 — เวอร์ชันที่ API compatible กับ ChaiyaPanel
# ห้ามเปลี่ยนเป็น latest เด็ดขาด เพราะเวอร์ชันใหม่เปลี่ยน session/cookie mechanism
XUI_LOCKED_VERSION="v2.9.4"
info "ติดตั้ง 3x-ui ${XUI_LOCKED_VERSION} (locked)..."
if ! command -v x-ui &>/dev/null; then
  _xui_sh=$(mktemp /tmp/xui-XXXXX.sh)
  # ดึง install.sh จาก master เสมอ แล้วส่ง locked version เป็น argument
  # install.sh รองรับ: bash install.sh v2.9.4 — จะดาวน์โหลด release นั้นโดยตรง
  curl -Ls --max-time 30 \
    "https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh" \
    -o "$_xui_sh" 2>/dev/null || { warn "ดาวน์โหลด 3x-ui install.sh ล้มเหลว"; rm -f "$_xui_sh"; }
  if [[ -s "$_xui_sh" ]]; then
    # ส่ง version เป็น argument โดยตรง — install.sh รองรับ bash install.sh <version>
    # ไม่ต้อง pipe interactive input เพราะ argument mode ไม่ถาม
    printf "y\n${XUI_PORT}\n\n\n\n" | timeout 300 bash "$_xui_sh" "${XUI_LOCKED_VERSION}" >> /var/log/chaiya-xui-install.log 2>&1 || true
  fi
  rm -f "$_xui_sh"
else
  # มี x-ui อยู่แล้ว — ตรวจเวอร์ชันและ downgrade ถ้าใหม่เกิน
  _cur_ver=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -1 | tr -d '[:space:]' || echo "unknown")
  [[ "$_cur_ver" != v* ]] && _cur_ver="v${_cur_ver}"
  info "x-ui เวอร์ชันปัจจุบัน: ${_cur_ver}"
  if [[ "$_cur_ver" != "$XUI_LOCKED_VERSION" && "$_cur_ver" != "vunknown" ]]; then
    warn "x-ui เวอร์ชัน ${_cur_ver} ไม่ตรงกับ locked ${XUI_LOCKED_VERSION} — ทำการ downgrade..."
    systemctl stop x-ui 2>/dev/null || true
    # ดาวน์โหลด binary โดยตรงจาก release — ไม่ผ่าน install.sh เพื่อหลีกเลี่ยง interactive prompt
    _arch=$(arch)
    _xui_tar="/tmp/x-ui-${XUI_LOCKED_VERSION}.tar.gz"
    curl -4 -fLo "$_xui_tar" --max-time 120 \
      "https://github.com/MHSanaei/3x-ui/releases/download/${XUI_LOCKED_VERSION}/x-ui-linux-${_arch}.tar.gz" \
      >> /var/log/chaiya-xui-install.log 2>&1
    if [[ -s "$_xui_tar" ]]; then
      cd /usr/local
      tar -xzf "$_xui_tar" 2>/dev/null || true
      chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/bin/xray-linux-* 2>/dev/null || true
      rm -f "$_xui_tar"
      ok "downgrade x-ui → ${XUI_LOCKED_VERSION} สำเร็จ"
    else
      warn "ดาวน์โหลด binary ล้มเหลว"
      rm -f "$_xui_tar"
    fi
    systemctl start x-ui 2>/dev/null || true
  fi
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
  # ปิด auto-update — ป้องกัน x-ui อัพเดทเองแล้ว break API
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('tgBotEnable','false');"              2>/dev/null || true
  sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key='checkUpdate';" 2>/dev/null || true
  sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('checkUpdate','false');"              2>/dev/null || true
  ok "ปิด x-ui auto-update แล้ว (locked ${XUI_LOCKED_VERSION:-v2.9.4})"
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

export USE_IPV6
python3 << PYEOF
import sqlite3, uuid, json, os

DB = '/etc/x-ui/x-ui.db'
use_ipv6 = os.environ.get('USE_IPV6', '0') == '1'
listen_addr = '::' if use_ipv6 else ''

try:
    con = sqlite3.connect(DB)
    existing = [r[0] for r in con.execute("SELECT port FROM inbounds").fetchall()]

    inbounds = [
        (8080, 'AIS \u2013 \u0e01\u0e31\u0e19\u0e23\u0e31\u0e48\u0e27',  'cj-ebb.speedtest.net',           'vless',  'inbound-8080', '/vless'),
        (8880, 'TRUE \u2013 VDO', 'true-internet.zoom.xyz.services', 'vless',  'inbound-8880', '/vless'),
    ]

    for port, remark, host, proto, tag, ws_path in inbounds:
        if port in existing:
            print(f'[OK] {remark} \u0e21\u0e35\u0e2d\u0e22\u0e39\u0e48\u0e41\u0e25\u0e49\u0e27')
            continue
        uid = str(uuid.uuid4())
        if proto == 'vmess':
            settings = json.dumps({'clients': [{'id': uid, 'alterId': 0, 'email': f'default@{tag}', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}]})
        else:
            settings = json.dumps({'clients': [{'id': uid, 'flow': '', 'email': f'default@{tag}', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}], 'decryption': 'none'})
        stream   = json.dumps({'network': 'ws', 'security': 'none', 'wsSettings': {'path': ws_path, 'headers': {'Host': host}}})
        sniffing = json.dumps({'enabled': True, 'destOverride': ['http', 'tls']})
        con.execute(
            "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,?,1,0,?,?,?,?,?,?,?)",
            (remark, listen_addr, port, proto, settings, stream, tag, sniffing)
        )
        mode = 'IPv6 [::]' if use_ipv6 else 'IPv4'
        print(f'[OK] {proto.upper()} {remark} (port {port}) listen={mode}')
    con.commit()
    con.close()
except Exception as e:
    print(f'[WARN] {e}')
PYEOF

rm -f "$XUI_COOKIE"

# ── ตั้งค่า xray outbound domainStrategy ตาม IP mode ─────────
if [[ $USE_IPV6 -eq 1 ]]; then
  info "ตั้งค่า xray outbound → UseIPv6v4 (IPv6 ก่อน ถ้าไม่ได้ค่อย IPv4)..."
  _XRAY_CONF_DIR="/usr/local/x-ui/bin"
  _OUTBOUND_CONF="${_XRAY_CONF_DIR}/config.json"
  if [[ -f "$_OUTBOUND_CONF" ]]; then
    python3 - "$_OUTBOUND_CONF" << 'XRAYPY'
import sys, json
path = sys.argv[1]
try:
    with open(path, 'r') as f:
        cfg = json.load(f)
    changed = 0
    for ob in cfg.get('outbounds', []):
        if ob.get('protocol') == 'freedom':
            ob.setdefault('settings', {})['domainStrategy'] = 'UseIPv6v4'
            changed += 1
    if changed == 0:
        cfg.setdefault('outbounds', []).append({
            'protocol': 'freedom',
            'settings': {'domainStrategy': 'UseIPv6v4'},
            'tag': 'direct'
        })
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(f'[OK] xray config อัพเดต domainStrategy=UseIPv6v4 ({changed} outbound)')
except Exception as e:
    print(f'[WARN] แก้ xray config ไม่สำเร็จ: {e}')
XRAYPY
  fi
  echo "$SERVER_IPV6" > /etc/chaiya/my_ipv6.conf
  echo "1" > /etc/chaiya/use_ipv6.conf
  ok "xray outbound → UseIPv6v4 (ผู้ใช้เชื่อมต่อจะเห็น IPv6)"
else
  echo "0" > /etc/chaiya/use_ipv6.conf
  ok "xray outbound → IPv4 (ค่าเริ่มต้น)"
fi

systemctl restart x-ui 2>/dev/null || true
sleep 2
ok "Inbounds พร้อม"

# ── ล็อก x-ui ห้ามอัพเดทอัตโนมัติ ──────────────────────────
info "ล็อก x-ui เวอร์ชันไม่ให้อัพเดทอัตโนมัติ..."
# 1) สร้าง systemd override — ExecStartPre ลบ update flag ทุกครั้งก่อน start
mkdir -p /etc/systemd/system/x-ui.service.d
cat > /etc/systemd/system/x-ui.service.d/no-autoupdate.conf << 'DROPIN'
[Service]
# ลบไฟล์ update flag ของ 3x-ui ทุกครั้งก่อน start
ExecStartPre=-/bin/rm -f /usr/local/x-ui/.update_flag /usr/local/x-ui/update_flag /tmp/x-ui-update*
DROPIN
systemctl daemon-reload 2>/dev/null || true
ok "systemd dropin ปิด update flag แล้ว"

# 2) สร้าง update-blocker script — ถ้า x-ui พยายาม update ตัวเองจะถูก block
cat > /usr/local/bin/chaiya-xui-version-guard << 'GUARD'
#!/bin/bash
# ChaiyaPanel x-ui version guard — รันโดย cron ทุก 10 นาที
LOCKED_VER="v2.9.4"
CUR_VER=$(x-ui version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "")
if [[ -n "$CUR_VER" && "$CUR_VER" != "$LOCKED_VER" ]]; then
  echo "[$(date)] x-ui version changed: ${CUR_VER} → restoring ${LOCKED_VER}" >> /var/log/chaiya-xui-guard.log
  systemctl stop x-ui 2>/dev/null
  # reinstall locked version
  _sh=$(mktemp /tmp/xui-guard-XXXXX.sh)
  curl -Ls --max-time 30 \
    "https://raw.githubusercontent.com/MHSanaei/3x-ui/${LOCKED_VER}/install.sh" \
    -o "$_sh" 2>/dev/null
  if [[ -s "$_sh" ]]; then
    printf "y\n54321\n\n\n\n" | bash "$_sh" "${LOCKED_VER}" >> /var/log/chaiya-xui-guard.log 2>&1 || true
  fi
  rm -f "$_sh"
  systemctl start x-ui 2>/dev/null
  echo "[$(date)] restore complete" >> /var/log/chaiya-xui-guard.log
fi
GUARD
chmod +x /usr/local/bin/chaiya-xui-version-guard

# 3) ตั้ง cron ทุก 10 นาที
(crontab -l 2>/dev/null | grep -v "chaiya-xui-version-guard"; \
 echo "*/10 * * * * /usr/local/bin/chaiya-xui-version-guard") | crontab -
ok "cron version-guard ตั้งค่าแล้ว (ทุก 10 นาที)"


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
            import urllib.request as _ur, json as _j
            try:
                xui_port = open('/etc/chaiya/xui-port.conf').read().strip() if os.path.exists('/etc/chaiya/xui-port.conf') else '54321'
                xui_user = open('/etc/chaiya/xui-user.conf').read().strip() if os.path.exists('/etc/chaiya/xui-user.conf') else ''
                xui_pass = open('/etc/chaiya/xui-pass.conf').read().strip() if os.path.exists('/etc/chaiya/xui-pass.conf') else ''
                xui_path = open('/etc/chaiya/xui-path.conf').read().strip() if os.path.exists('/etc/chaiya/xui-path.conf') else '/'
                if not xui_path.endswith('/'): xui_path += '/'
                base = f'http://127.0.0.1:{xui_port}{xui_path}'
                # login — v2.9.x ใช้ JSON
                login_data = _j.dumps({'username': xui_user, 'password': xui_pass}).encode()
                req = _ur.Request(base+'login', data=login_data, method='POST')
                req.add_header('Content-Type', 'application/json')
                cookie_jar = {}
                with _ur.urlopen(req, timeout=5) as resp:
                    for hdr in resp.getheaders():
                        if hdr[0].lower() == 'set-cookie':
                            k, _, v = hdr[1].partition('=')
                            cookie_jar[k.strip()] = v.split(';')[0].strip()
                cookie_str = '; '.join(f'{k}={v}' for k, v in cookie_jar.items())
                # server status
                req2 = _ur.Request(base+'panel/api/server/status')
                if cookie_str:
                    req2.add_header('Cookie', cookie_str)
                with _ur.urlopen(req2, timeout=5) as resp2:
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

# หยุด WS-Stunnel และ nginx ชั่วคราวเพื่อ free port 80 ให้ certbot standalone
# (Let's Encrypt ต้องการ port 80 จริงๆ — http-01-port อื่นไม่ work)
info "หยุด WS-Stunnel และ nginx ชั่วคราว (ปลดล็อก port 80)..."
systemctl stop chaiya-sshws 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
pkill -f ws-stunnel 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
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
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFBST0pFQ1Qg4oCTIFYyUkFZICYgU1NIIEFMTC1JTi1PTkUgUFJPPC90aXRsZT4KPGxpbmsgaHJlZj0iaHR0cHM6Ly9mb250cy5nb29nbGVhcGlzLmNvbS9jc3MyP2ZhbWlseT1PcmJpdHJvbjp3Z2h0QDQwMDs3MDA7OTAwJmZhbWlseT1TYXJhYnVuOndnaHRAMzAwOzQwMDs2MDAmZGlzcGxheT1zd2FwIiByZWw9InN0eWxlc2hlZXQiPgo8c3R5bGU+CiAgOnJvb3QgewogICAgLS1yZ2ItMTogI2ZmMDA4MDsKICAgIC0tcmdiLTI6ICNmZjY2MDA7CiAgICAtLXJnYi0zOiAjZmZmZjAwOwogICAgLS1yZ2ItNDogIzAwZmY4ODsKICAgIC0tcmdiLTU6ICMwMGNjZmY7CiAgICAtLXJnYi02OiAjYWEwMGZmOwogICAgLS1iZzogIzAwMDAwMDsKICAgIC0tY2FyZC1iZzogcmdiYSg4LDgsOCwwLjk1KTsKICAgIC0tYm9yZGVyOiByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpOwogIH0KICAqIHsgbWFyZ2luOjA7IHBhZGRpbmc6MDsgYm94LXNpemluZzpib3JkZXItYm94OyB9CgogIGJvZHkgewogICAgZm9udC1mYW1pbHk6ICdTYXJhYnVuJywgc2Fucy1zZXJpZjsKICAgIGJhY2tncm91bmQ6ICMwMDA7CiAgICBtaW4taGVpZ2h0OiAxMDB2aDsKICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgb3ZlcmZsb3c6IGhpZGRlbjsKICB9CgogIC8qIOKUgOKUgCBSR0IgQU5JTUFURUQgQkFDS0dST1VORCDilIDilIAgKi8KICAucmdiLWJnIHsKICAgIHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IDA7CiAgICBiYWNrZ3JvdW5kOiByYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUsIHJnYmEoMjU1LDAsMTI4LDAuMTIpIDAlLCB0cmFuc3BhcmVudCA2MCUpLAogICAgICAgICAgICAgICAgcmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLCByZ2JhKDAsMjAwLDI1NSwwLjEwKSAwJSwgdHJhbnNwYXJlbnQgNjAlKSwKICAgICAgICAgICAgICAgIHJhZGlhbC1ncmFkaWVudChlbGxpcHNlIDcwJSA1MCUgYXQgNTAlIDUwJSwgcmdiYSgxNzAsMCwyNTUsMC4wOCkgMCUsIHRyYW5zcGFyZW50IDcwJSk7CiAgICBhbmltYXRpb246IHJnYkJnU2hpZnQgOHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgfQogIEBrZXlmcmFtZXMgcmdiQmdTaGlmdCB7CiAgICAwJSAgIHsgZmlsdGVyOiBodWUtcm90YXRlKDBkZWcpOyB9CiAgICA1MCUgIHsgZmlsdGVyOiBodWUtcm90YXRlKDEyMGRlZyk7IH0KICAgIDEwMCUgeyBmaWx0ZXI6IGh1ZS1yb3RhdGUoMzYwZGVnKTsgfQogIH0KCiAgLyog4pSA4pSAIEdSSUQgQkcg4pSA4pSAICovCiAgLmdyaWQtYmcgewogICAgcG9zaXRpb246IGZpeGVkOyBpbnNldDogMDsgei1pbmRleDogMDsKICAgIGJhY2tncm91bmQtaW1hZ2U6CiAgICAgIGxpbmVhci1ncmFkaWVudChyZ2JhKDI1NSwwLDEyOCwwLjA0KSAxcHgsIHRyYW5zcGFyZW50IDFweCksCiAgICAgIGxpbmVhci1ncmFkaWVudCg5MGRlZywgcmdiYSgwLDIwMCwyNTUsMC4wNCkgMXB4LCB0cmFuc3BhcmVudCAxcHgpOwogICAgYmFja2dyb3VuZC1zaXplOiA0OHB4IDQ4cHg7CiAgICB0cmFuc2Zvcm06IHBlcnNwZWN0aXZlKDUwMHB4KSByb3RhdGVYKDI4ZGVnKSBzY2FsZSgyLjIpIHRyYW5zbGF0ZVooMCk7CiAgICB0cmFuc2Zvcm0tb3JpZ2luOiBjZW50ZXIgYm90dG9tOwogICAgYW5pbWF0aW9uOiBncmlkU2Nyb2xsIDE2cyBsaW5lYXIgaW5maW5pdGU7CiAgfQogIEBrZXlmcmFtZXMgZ3JpZFNjcm9sbCB7CiAgICBmcm9tIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMCAwOyB9CiAgICB0byAgIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMCA0OHB4OyB9CiAgfQoKICAvKiDilIDilIAgUkdCIEJPUkRFUiBBTklNQVRJT04g4pSA4pSAICovCiAgQGtleWZyYW1lcyByZ2JCb3JkZXIgewogICAgMCUgICB7IGJvcmRlci1jb2xvcjogI2ZmMDA4MDsgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgyNTUsMCwxMjgsMC4zKTsgfQogICAgMTclICB7IGJvcmRlci1jb2xvcjogI2ZmNjYwMDsgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgyNTUsMTAyLDAsMC4zKTsgfQogICAgMzMlICB7IGJvcmRlci1jb2xvcjogI2ZmZmYwMDsgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgyNTUsMjU1LDAsMC4zKTsgfQogICAgNTAlICB7IGJvcmRlci1jb2xvcjogIzAwZmY4ODsgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgwLDI1NSwxMzYsMC4zKTsgfQogICAgNjclICB7IGJvcmRlci1jb2xvcjogIzAwY2NmZjsgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgwLDIwNCwyNTUsMC4zKTsgfQogICAgODMlICB7IGJvcmRlci1jb2xvcjogI2FhMDBmZjsgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgxNzAsMCwyNTUsMC4zKTsgfQogICAgMTAwJSB7IGJvcmRlci1jb2xvcjogI2ZmMDA4MDsgYm94LXNoYWRvdzogMCAwIDIwcHggcmdiYSgyNTUsMCwxMjgsMC4zKTsgfQogIH0KCiAgQGtleWZyYW1lcyByZ2JHbG93IHsKICAgIDAlICAgeyB0ZXh0LXNoYWRvdzogMCAwIDEwcHggI2ZmMDA4MCwgMCAwIDMwcHggI2ZmMDA4MDsgfQogICAgMTclICB7IHRleHQtc2hhZG93OiAwIDAgMTBweCAjZmY2NjAwLCAwIDAgMzBweCAjZmY2NjAwOyB9CiAgICAzMyUgIHsgdGV4dC1zaGFkb3c6IDAgMCAxMHB4ICNmZmZmMDAsIDAgMCAzMHB4ICNmZmZmMDA7IH0KICAgIDUwJSAgeyB0ZXh0LXNoYWRvdzogMCAwIDEwcHggIzAwZmY4OCwgMCAwIDMwcHggIzAwZmY4ODsgfQogICAgNjclICB7IHRleHQtc2hhZG93OiAwIDAgMTBweCAjMDBjY2ZmLCAwIDAgMzBweCAjMDBjY2ZmOyB9CiAgICA4MyUgIHsgdGV4dC1zaGFkb3c6IDAgMCAxMHB4ICNhYTAwZmYsIDAgMCAzMHB4ICNhYTAwZmY7IH0KICAgIDEwMCUgeyB0ZXh0LXNoYWRvdzogMCAwIDEwcHggI2ZmMDA4MCwgMCAwIDMwcHggI2ZmMDA4MDsgfQogIH0KCiAgQGtleWZyYW1lcyByZ2JTcGluIHsKICAgIGZyb20geyB0cmFuc2Zvcm06IHJvdGF0ZSgwZGVnKTsgfQogICAgdG8gICB7IHRyYW5zZm9ybTogcm90YXRlKDM2MGRlZyk7IH0KICB9CgogIC8qIOKUgOKUgCBDQU5WQVMgRklSRUZMSUVTIOKUgOKUgCAqLwogICNmZkNhbnZhcyB7CiAgICBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAxOwogICAgcG9pbnRlci1ldmVudHM6IG5vbmU7IHdpZHRoOiAxMDAlOyBoZWlnaHQ6IDEwMCU7CiAgfQoKICAvKiDilIDilIAgU0NFTkUg4pSA4pSAICovCiAgLnNjZW5lIHsKICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsgei1pbmRleDogMTA7CiAgICBkaXNwbGF5OiBmbGV4OyBmbGV4LWRpcmVjdGlvbjogY29sdW1uOwogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsgZ2FwOiAxOHB4OwogICAgd2lkdGg6IDEwMCU7IG1heC13aWR0aDogNDIwcHg7CiAgICBwYWRkaW5nOiAyMHB4OwogICAgYW5pbWF0aW9uOiBzY2VuZUluIDAuOXMgY3ViaWMtYmV6aWVyKDAuMTYsMSwwLjMsMSkgYm90aDsKICB9CiAgQGtleWZyYW1lcyBzY2VuZUluIHsKICAgIGZyb20geyBvcGFjaXR5OjA7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgzMHB4KTsgfQogICAgdG8gICB7IG9wYWNpdHk6MTsgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOyB9CiAgfQoKICAvKiDilIDilIAgUkdCIE9SQiDilIDilIAgKi8KICAubG9nby13cmFwIHsgZGlzcGxheTpmbGV4OyBmbGV4LWRpcmVjdGlvbjpjb2x1bW47IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOjhweDsgfQoKICAubG9nby1vcmIgewogICAgcG9zaXRpb246IHJlbGF0aXZlOyB3aWR0aDogMTEwcHg7IGhlaWdodDogMTEwcHg7CiAgICBhbmltYXRpb246IG9yYkZsb2F0IDVzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIH0KICBAa2V5ZnJhbWVzIG9yYkZsb2F0IHsKICAgIDAlLDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7IH0KICAgIDUwJSAgICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTEwcHgpOyB9CiAgfQoKICAub3JiLXJpbmcgewogICAgcG9zaXRpb246IGFic29sdXRlOyBpbnNldDogMDsgYm9yZGVyLXJhZGl1czogNTAlOwogICAgYm9yZGVyOiAycHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICBhbmltYXRpb246IHJnYlNwaW4gNHMgbGluZWFyIGluZmluaXRlOwogIH0KICAub3JiLXJpbmctMSB7IGJvcmRlci10b3AtY29sb3I6I2ZmMDA4MDsgYm9yZGVyLXJpZ2h0LWNvbG9yOiNmZjAwODA7IGFuaW1hdGlvbi1kdXJhdGlvbjozczsgfQogIC5vcmItcmluZy0yIHsgaW5zZXQ6OXB4OyBib3JkZXItYm90dG9tLWNvbG9yOiMwMGNjZmY7IGJvcmRlci1sZWZ0LWNvbG9yOiMwMGNjZmY7IGFuaW1hdGlvbi1kdXJhdGlvbjo1czsgYW5pbWF0aW9uLWRpcmVjdGlvbjpyZXZlcnNlOyB9CiAgLm9yYi1yaW5nLTMgeyBpbnNldDoxOXB4OyBib3JkZXItdG9wLWNvbG9yOiMwMGZmODg7IGJvcmRlci1yaWdodC1jb2xvcjojYWEwMGZmOyBhbmltYXRpb24tZHVyYXRpb246Mi41czsgfQoKICAub3JiLWNvcmUgewogICAgcG9zaXRpb246IGFic29sdXRlOyBpbnNldDogMjZweDsgYm9yZGVyLXJhZGl1czogNTAlOwogICAgYmFja2dyb3VuZDogcmFkaWFsLWdyYWRpZW50KGNpcmNsZSBhdCAzNSUgMzIlLAogICAgICByZ2JhKDI1NSwwLDEyOCwwLjUpIDAlLCByZ2JhKDE3MCwwLDI1NSwwLjYpIDUyJSwgcmdiYSgwLDAsMCwwLjkyKSAxMDAlKTsKICAgIGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgYW5pbWF0aW9uOiByZ2JCZ1NoaWZ0IDZzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIH0KCiAgLnB1bHNlLXN2ZyB7IHdpZHRoOiAzMHB4OyBoZWlnaHQ6IDE4cHg7IH0KCiAgLyog4pSA4pSAIEJSQU5EIOKUgOKUgCAqLwogIC5icmFuZC1uYW1lIHsKICAgIGZvbnQtZmFtaWx5OiAnT3JiaXRyb24nLCBtb25vc3BhY2U7IGZvbnQtd2VpZ2h0OiA5MDA7IGZvbnQtc2l6ZTogMi4ycmVtOwogICAgbGV0dGVyLXNwYWNpbmc6IDAuMjRlbTsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsICNmZmYgMCUsICNmZjAwODAgMjUlLCAjMDBjY2ZmIDUwJSwgIzAwZmY4OCA3NSUsICNhYTAwZmYgMTAwJSk7CiAgICBiYWNrZ3JvdW5kLXNpemU6IDMwMCUgMzAwJTsKICAgIC13ZWJraXQtYmFja2dyb3VuZC1jbGlwOiB0ZXh0OyAtd2Via2l0LXRleHQtZmlsbC1jb2xvcjogdHJhbnNwYXJlbnQ7CiAgICBhbmltYXRpb246IHJnYkdyYWRTaGlmdCA0cyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgQGtleWZyYW1lcyByZ2JHcmFkU2hpZnQgewogICAgMCUgICB7IGJhY2tncm91bmQtcG9zaXRpb246IDAlIDUwJTsgfQogICAgNTAlICB7IGJhY2tncm91bmQtcG9zaXRpb246IDEwMCUgNTAlOyB9CiAgICAxMDAlIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMCUgNTAlOyB9CiAgfQogIC5icmFuZC1zdWIgewogICAgZm9udC1mYW1pbHk6ICdPcmJpdHJvbicsIG1vbm9zcGFjZTsgZm9udC1zaXplOiAwLjYycmVtOwogICAgbGV0dGVyLXNwYWNpbmc6IDAuNThlbTsgbWFyZ2luLXRvcDotNHB4OwogICAgYW5pbWF0aW9uOiByZ2JHbG93IDRzIGxpbmVhciBpbmZpbml0ZTsKICAgIGNvbG9yOiAjMDBjY2ZmOwogIH0KICAuYmFkZ2UgewogICAgbWFyZ2luLXRvcDogNXB4OyBwYWRkaW5nOiA1cHggMTZweDsKICAgIGZvbnQtZmFtaWx5OiAnT3JiaXRyb24nLCBtb25vc3BhY2U7IGZvbnQtc2l6ZTogMC41OHJlbTsgbGV0dGVyLXNwYWNpbmc6IDAuMjhlbTsKICAgIGJvcmRlcjogMXB4IHNvbGlkIHRyYW5zcGFyZW50OyBib3JkZXItcmFkaXVzOiAyMHB4OwogICAgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwwLjUpOwogICAgYW5pbWF0aW9uOiByZ2JCb3JkZXIgNHMgbGluZWFyIGluZmluaXRlOwogIH0KCiAgLyog4pSA4pSAIENBUkQgKEJMQUNLICsgUkdCIEJPUkRFUikg4pSA4pSAICovCiAgLmNhcmQgewogICAgd2lkdGg6IDEwMCU7CiAgICBiYWNrZ3JvdW5kOiByZ2JhKDUsNSw1LDAuOTIpOwogICAgYm9yZGVyOiAycHggc29saWQgI2ZmMDA4MDsKICAgIGJvcmRlci1yYWRpdXM6IDIwcHg7CiAgICBwYWRkaW5nOiAzMHB4IDI2cHggMjZweDsKICAgIHBvc2l0aW9uOiByZWxhdGl2ZTsKICAgIGJhY2tkcm9wLWZpbHRlcjogYmx1cigyMHB4KTsKICAgIC13ZWJraXQtYmFja2Ryb3AtZmlsdGVyOiBibHVyKDIwcHgpOwogICAgYW5pbWF0aW9uOiByZ2JCb3JkZXIgNHMgbGluZWFyIGluZmluaXRlOwogICAgd2lsbC1jaGFuZ2U6IHRyYW5zZm9ybTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA1cyBsaW5lYXI7CiAgfQoKICAvKiBSR0IgY29ybmVyIGFjY2VudHMgKi8KICAuY2FyZDo6YmVmb3JlLCAuY2FyZDo6YWZ0ZXIgewogICAgY29udGVudDonJzsgcG9zaXRpb246YWJzb2x1dGU7IHdpZHRoOjQwcHg7IGhlaWdodDo0MHB4OwogICAgYW5pbWF0aW9uOiByZ2JCb3JkZXIgNHMgbGluZWFyIGluZmluaXRlOwogIH0KICAuY2FyZDo6YmVmb3JlIHsKICAgIHRvcDotMnB4OyBsZWZ0Oi0ycHg7CiAgICBib3JkZXItdG9wOiAzcHggc29saWQgI2ZmMDA4MDsgYm9yZGVyLWxlZnQ6IDNweCBzb2xpZCAjZmYwMDgwOwogICAgYm9yZGVyLXJhZGl1czogMThweCAwIDAgMDsKICAgIGFuaW1hdGlvbjogcmdiQm9yZGVyIDRzIGxpbmVhciBpbmZpbml0ZSAwczsKICB9CiAgLmNhcmQ6OmFmdGVyIHsKICAgIGJvdHRvbTotMnB4OyByaWdodDotMnB4OwogICAgYm9yZGVyLWJvdHRvbTogM3B4IHNvbGlkICMwMGNjZmY7IGJvcmRlci1yaWdodDogM3B4IHNvbGlkICMwMGNjZmY7CiAgICBib3JkZXItcmFkaXVzOiAwIDAgMThweCAwOwogICAgYW5pbWF0aW9uOiByZ2JCb3JkZXIgNHMgbGluZWFyIGluZmluaXRlIDJzOwogIH0KCiAgLyog4pSA4pSAIFJHQiBTQ0FOTElORSDilIDilIAgKi8KICAuY2FyZC1zY2FubGluZSB7CiAgICBwb3NpdGlvbjogYWJzb2x1dGU7IGluc2V0OiAwOyBib3JkZXItcmFkaXVzOiAyMHB4OwogICAgb3ZlcmZsb3c6IGhpZGRlbjsgcG9pbnRlci1ldmVudHM6IG5vbmU7CiAgfQogIC5jYXJkLXNjYW5saW5lOjphZnRlciB7CiAgICBjb250ZW50OiAnJzsKICAgIHBvc2l0aW9uOiBhYnNvbHV0ZTsgbGVmdDogMDsgcmlnaHQ6IDA7IGhlaWdodDogMnB4OwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCB0cmFuc3BhcmVudCwgcmdiYSgwLDI1NSwyNTUsMC40KSwgdHJhbnNwYXJlbnQpOwogICAgYW5pbWF0aW9uOiBzY2FubGluZSAzcyBsaW5lYXIgaW5maW5pdGU7CiAgfQogIEBrZXlmcmFtZXMgc2NhbmxpbmUgewogICAgZnJvbSB7IHRvcDogMDsgfQogICAgdG8gICB7IHRvcDogMTAwJTsgfQogIH0KCiAgLyog4pSA4pSAIFNFQ1RJT04gVElUTEUg4pSA4pSAICovCiAgLnNlY3Rpb24tdGl0bGUgeyBkaXNwbGF5OmZsZXg7IGFsaWduLWl0ZW1zOmNlbnRlcjsgZ2FwOjEwcHg7IG1hcmdpbi1ib3R0b206MjJweDsgfQogIC50aXRsZS1iYXIgewogICAgd2lkdGg6M3B4OyBoZWlnaHQ6MjBweDsKICAgIGJvcmRlci1yYWRpdXM6MnB4OwogICAgYW5pbWF0aW9uOiByZ2JCZ1NoaWZ0IDRzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KHRvIGJvdHRvbSwgI2ZmMDA4MCwgIzAwY2NmZik7CiAgfQogIC50aXRsZS10ZXh0IHsgZm9udC1zaXplOjEuMDJyZW07IGZvbnQtd2VpZ2h0OjYwMDsgY29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjkpOyB9CgogIC8qIOKUgOKUgCBGSUVMRFMg4pSA4pSAICovCiAgLmZpZWxkLWdyb3VwIHsgbWFyZ2luLWJvdHRvbToxNnB4OyB9CiAgLmZpZWxkLWxhYmVsIHsgZGlzcGxheTpibG9jazsgZm9udC1zaXplOjAuOHJlbTsgY29sb3I6cmdiYSgxODAsMjEwLDI1NSwwLjcpOyBtYXJnaW4tYm90dG9tOjdweDsgfQogIC5maWVsZC13cmFwIHsgcG9zaXRpb246cmVsYXRpdmU7IH0KICAuZmllbGQtaWNvbiB7IHBvc2l0aW9uOmFic29sdXRlOyBsZWZ0OjEzcHg7IHRvcDo1MCU7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpOyBmb250LXNpemU6MC45NXJlbTsgb3BhY2l0eTowLjY7IHBvaW50ZXItZXZlbnRzOm5vbmU7IHotaW5kZXg6MTsgfQogIC5maWVsZC1pbnB1dCB7CiAgICB3aWR0aDoxMDAlOyBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLDAuNik7CiAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMSk7IGJvcmRlci1yYWRpdXM6MTFweDsKICAgIHBhZGRpbmc6IDEzcHggMTNweCAxM3B4IDQwcHg7CiAgICBmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjsgZm9udC1zaXplOjAuOXJlbTsKICAgIGNvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC45KTsgb3V0bGluZTpub25lOwogICAgdHJhbnNpdGlvbjogYm9yZGVyLWNvbG9yIDAuMnMsIGJveC1zaGFkb3cgMC4yczsKICB9CiAgLmZpZWxkLWlucHV0OjpwbGFjZWhvbGRlciB7IGNvbG9yOnJnYmEoMTQwLDE1NSwyMDAsMC4zNSk7IH0KICAuZmllbGQtaW5wdXQ6Zm9jdXMgewogICAgYm9yZGVyLWNvbG9yOiAjZmYwMDgwOwogICAgYm94LXNoYWRvdzogMCAwIDAgMnB4IHJnYmEoMjU1LDAsMTI4LDAuMiksIDAgMCAxMHB4IHJnYmEoMjU1LDAsMTI4LDAuMTUpOwogICAgYW5pbWF0aW9uOiByZ2JCb3JkZXIgNHMgbGluZWFyIGluZmluaXRlOwogIH0KCiAgLmV5ZS1idG4gewogICAgcG9zaXRpb246YWJzb2x1dGU7IHJpZ2h0OjEycHg7IHRvcDo1MCU7IHRyYW5zZm9ybTp0cmFuc2xhdGVZKC01MCUpOwogICAgYmFja2dyb3VuZDpub25lOyBib3JkZXI6bm9uZTsgY29sb3I6cmdiYSgxNDAsMTY1LDIyMCwwLjUpOwogICAgY3Vyc29yOnBvaW50ZXI7IGZvbnQtc2l6ZTowLjk1cmVtOyBwYWRkaW5nOjRweDsgei1pbmRleDoyOwogICAgdHJhbnNpdGlvbjogY29sb3IgMC4xOHM7CiAgfQogIC5leWUtYnRuOmhvdmVyIHsgY29sb3I6IzAwY2NmZjsgfQoKICAvKiDilIDilIAgQlVUVE9OUyDilIDilIAgKi8KICAuYnRuIHsKICAgIHdpZHRoOjEwMCU7IHBhZGRpbmc6MTRweDsgYm9yZGVyOm5vbmU7IGJvcmRlci1yYWRpdXM6MTFweDsKICAgIGZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyBmb250LXNpemU6MC45N3JlbTsgZm9udC13ZWlnaHQ6NjAwOwogICAgbGV0dGVyLXNwYWNpbmc6MC4wNWVtOyBjdXJzb3I6cG9pbnRlcjsgcG9zaXRpb246cmVsYXRpdmU7IG92ZXJmbG93OmhpZGRlbjsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycywgYm94LXNoYWRvdyAwLjEyczsKICAgIG1hcmdpbi1ib3R0b206MTFweDsKICB9CiAgLmJ0bjpsYXN0LWNoaWxkIHsgbWFyZ2luLWJvdHRvbTowOyB9CgogIC5idG4tcHJpbWFyeSB7CiAgICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCAjZmYwMDgwLCAjYWEwMGZmLCAjMDA4MGZmKTsKICAgIGJhY2tncm91bmQtc2l6ZTogMzAwJSAzMDAlOwogICAgYW5pbWF0aW9uOiByZ2JHcmFkU2hpZnQgM3MgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICBjb2xvcjogI2ZmZjsKICAgIGJveC1zaGFkb3c6IDAgNHB4IDIwcHggcmdiYSgyNTUsMCwxMjgsMC40KTsKICB9CiAgLmJ0bi1wcmltYXJ5OmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsKICAgIGJveC1zaGFkb3c6IDAgOHB4IDMwcHggcmdiYSgyNTUsMCwxMjgsMC42KTsKICB9CiAgLmJ0bi1wcmltYXJ5OmFjdGl2ZSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgxcHgpOyB9CgogIC5idG4tc2Vjb25kYXJ5IHsKICAgIGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsMC40KTsKICAgIGNvbG9yOiByZ2JhKDIwMCwyMjAsMjU1LDAuOCk7CiAgICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpOwogICAgYm94LXNoYWRvdzogMCA0cHggMCByZ2JhKDAsMCwwLDAuMyk7CiAgICBhbmltYXRpb246IHJnYkJvcmRlciA2cyBsaW5lYXIgaW5maW5pdGU7CiAgfQogIC5idG4tc2Vjb25kYXJ5OmhvdmVyIHsKICAgIGJhY2tncm91bmQ6IHJnYmEoMCwyMDAsMjU1LDAuMDUpOwogICAgY29sb3I6ICMwMGNjZmY7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCk7CiAgfQoKICAuYnRuOjphZnRlciB7CiAgICBjb250ZW50OicnOyBwb3NpdGlvbjphYnNvbHV0ZTsgdG9wOjA7IGxlZnQ6LTExMCU7IHdpZHRoOjU1JTsgaGVpZ2h0OjEwMCU7CiAgICBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCxyZ2JhKDI1NSwyNTUsMjU1LDAuMTUpLHRyYW5zcGFyZW50KTsKICAgIHRyYW5zZm9ybTpza2V3WCgtMThkZWcpOyB0cmFuc2l0aW9uOmxlZnQgMC40MnM7CiAgfQogIC5idG46aG92ZXI6OmFmdGVyIHsgbGVmdDoxNjAlOyB9CgogIC8qIOKUgOKUgCBUSUNLRVIg4pSA4pSAICovCiAgLnRpY2tlci13cmFwIHsgd2lkdGg6MTAwJTsgb3ZlcmZsb3c6aGlkZGVuOyBvcGFjaXR5OjAuNTsgcG9zaXRpb246cmVsYXRpdmU7IH0KICAudGlja2VyLXdyYXA6OmJlZm9yZSwudGlja2VyLXdyYXA6OmFmdGVyIHsgY29udGVudDonJzsgcG9zaXRpb246YWJzb2x1dGU7IHRvcDowOyBib3R0b206MDsgd2lkdGg6MjhweDsgei1pbmRleDoyOyB9CiAgLnRpY2tlci13cmFwOjpiZWZvcmUgeyBsZWZ0OjA7IGJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMwMDAsdHJhbnNwYXJlbnQpOyB9CiAgLnRpY2tlci13cmFwOjphZnRlciAgeyByaWdodDowOyBiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgtOTBkZWcsIzAwMCx0cmFuc3BhcmVudCk7IH0KICAudGlja2VyLXRyYWNrIHsKICAgIHdoaXRlLXNwYWNlOm5vd3JhcDsgZGlzcGxheTppbmxpbmUtYmxvY2s7CiAgICBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgZm9udC1zaXplOjAuNDhyZW07IGxldHRlci1zcGFjaW5nOjAuM2VtOwogICAgd2lsbC1jaGFuZ2U6dHJhbnNmb3JtOwogICAgYW5pbWF0aW9uOnRpY2tlciAyMnMgbGluZWFyIGluZmluaXRlOwogICAgYW5pbWF0aW9uOiByZ2JHbG93IDNzIGxpbmVhciBpbmZpbml0ZSwgdGlja2VyIDIycyBsaW5lYXIgaW5maW5pdGU7CiAgICBjb2xvcjogI2ZmMDA4MDsKICB9CiAgQGtleWZyYW1lcyB0aWNrZXIgeyBmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVYKDApfSB0b3t0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKX0gfQoKICAvKiDilIDilIAgUkdCIFBBUlRJQ0xFUyDilIDilIAgKi8KICAucmdiLXBhcnRpY2xlIHsKICAgIHBvc2l0aW9uOiBmaXhlZDsgYm9yZGVyLXJhZGl1czogNTAlOyBwb2ludGVyLWV2ZW50czogbm9uZTsgei1pbmRleDogMjsKICAgIGFuaW1hdGlvbjogcGFydGljbGVEcmlmdCBsaW5lYXIgaW5maW5pdGUsIHBhcnRpY2xlRmFkZSBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgQGtleWZyYW1lcyBwYXJ0aWNsZURyaWZ0IHsKICAgIGZyb20geyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMTAwdmgpIHRyYW5zbGF0ZVgoMCk7IH0KICAgIHRvICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTEwMHB4KSB0cmFuc2xhdGVYKHZhcigtLWR4KSk7IH0KICB9CiAgQGtleWZyYW1lcyBwYXJ0aWNsZUZhZGUgewogICAgMCUsMTAwJSB7IG9wYWNpdHk6IDA7IH0KICAgIDMwJSw3MCUgeyBvcGFjaXR5OiB2YXIoLS1vcCk7IH0KICB9Cjwvc3R5bGU+CjwvaGVhZD4KPGJvZHk+Cgo8ZGl2IGNsYXNzPSJyZ2ItYmciPjwvZGl2Pgo8ZGl2IGNsYXNzPSJncmlkLWJnIj48L2Rpdj4KPGNhbnZhcyBpZD0iZmZDYW52YXMiPjwvY2FudmFzPgoKPGRpdiBjbGFzcz0ic2NlbmUiPgoKICA8ZGl2IGNsYXNzPSJsb2dvLXdyYXAiPgogICAgPGRpdiBjbGFzcz0ibG9nby1vcmIiPgogICAgICA8ZGl2IGNsYXNzPSJvcmItcmluZyBvcmItcmluZy0xIj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ib3JiLXJpbmcgb3JiLXJpbmctMiI+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9yYi1yaW5nIG9yYi1yaW5nLTMiPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJvcmItY29yZSI+CiAgICAgICAgPHN2ZyBjbGFzcz0icHVsc2Utc3ZnIiB2aWV3Qm94PSIwIDAgNTAgMjgiIGZpbGw9Im5vbmUiPgogICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMCwxNCA4LDE0IDEyLDQgMTcsMjQgMjIsMTAgMjcsMTggMzIsNiAzNywyMiA0MiwxNCA1MCwxNCIKICAgICAgICAgICAgc3Ryb2tlPSIjZmYwMDgwIiBzdHJva2Utd2lkdGg9IjIuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIgogICAgICAgICAgICBzdHlsZT0iYW5pbWF0aW9uOiByZ2JHbG93IDJzIGxpbmVhciBpbmZpbml0ZSIvPgogICAgICAgIDwvc3ZnPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iYnJhbmQtbmFtZSI+Q0hBSVlBPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJicmFuZC1zdWIiPlAgUiBPIEogRSBDIFQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImJhZGdlIj5WMlJBWSAmYW1wOyBTU0ggJm5ic3A7wrcmbmJzcDsgQUxMLUlOLU9ORSBQUk88L2Rpdj4KICA8L2Rpdj4KCiAgPGRpdiBjbGFzcz0iY2FyZCIgaWQ9ImNhcmQiPgogICAgPGRpdiBjbGFzcz0iY2FyZC1zY2FubGluZSI+PC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZWN0aW9uLXRpdGxlIj4KICAgICAgPGRpdiBjbGFzcz0idGl0bGUtYmFyIj48L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9InRpdGxlLXRleHQiPuC5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mjwvc3Bhbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpZWxkLWdyb3VwIj4KICAgICAgPGxhYmVsIGNsYXNzPSJmaWVsZC1sYWJlbCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJ4LiH4Liy4LiZPC9sYWJlbD4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQtd3JhcCI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImZpZWxkLWljb24iPvCfkaQ8L3NwYW4+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaWVsZC1pbnB1dCIgaWQ9InVzZXJuYW1lSW5wdXQiIHR5cGU9InRleHQiIHBsYWNlaG9sZGVyPSLguIHguKPguK3guIHguIrguLfguYjguK3guJzguLnguYnguYPguIrguYnguIfguLLguJkiIGF1dG9jb21wbGV0ZT0idXNlcm5hbWUiPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImZpZWxkLWdyb3VwIiBzdHlsZT0ibWFyZ2luLWJvdHRvbToyMnB4Ij4KICAgICAgPGxhYmVsIGNsYXNzPSJmaWVsZC1sYWJlbCI+4Lij4Lir4Lix4Liq4Lic4LmI4Liy4LiZPC9sYWJlbD4KICAgICAgPGRpdiBjbGFzcz0iZmllbGQtd3JhcCI+CiAgICAgICAgPHNwYW4gY2xhc3M9ImZpZWxkLWljb24iPvCflJI8L3NwYW4+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaWVsZC1pbnB1dCIgdHlwZT0icGFzc3dvcmQiIGlkPSJwYXNzSW5wdXQiIHBsYWNlaG9sZGVyPSLguIHguKPguK3guIHguKPguKvguLHguKrguJzguYjguLLguJkiIGF1dG9jb21wbGV0ZT0iY3VycmVudC1wYXNzd29yZCI+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iZXllLWJ0biIgb25jbGljaz0idG9nZ2xlUGFzcygpIiB0YWJpbmRleD0iLTEiPvCfkYE8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8YnV0dG9uIGNsYXNzPSJidG4gYnRuLXByaW1hcnkiIGlkPSJsb2dpbkJ0biIgb25jbGljaz0iZG9Mb2dpbigpIj7wn5STJm5ic3A7IOC5gOC4guC5ieC4suC4quC4ueC5iOC4o+C4sOC4muC4mjwvYnV0dG9uPgogICAgPGJ1dHRvbiBjbGFzcz0iYnRuIGJ0bi1zZWNvbmRhcnkiIG9uY2xpY2s9InNob3dDaGFuZ2VNb2RhbCgpIj7wn5SRJm5ic3A7IOC5gOC4m+C4peC4teC5iOC4ouC4mSBVc2VybmFtZSAvIFBhc3N3b3JkPC9idXR0b24+CiAgPC9kaXY+CgogIDxkaXYgY2xhc3M9InRpY2tlci13cmFwIj4KICAgIDxkaXYgY2xhc3M9InRpY2tlci10cmFjayIgaWQ9InRpY2tlciI+PC9kaXY+CiAgPC9kaXY+Cgo8L2Rpdj4KCjxzY3JpcHQ+Ci8qIOKUgOKUgCBUSUNLRVIg4pSA4pSAICovCmNvbnN0IG1zZyA9ICdDSEFJWUEtUFJPSkVDVFx1MjAwM8K3XHUyMDAzVjJSQVkgJiBTU0ggQUxMLUlOLU9ORSBQUk9cdTIwMDPCt1x1MjAwM1JHQiBFRElUSU9OXHUyMDAzwrdcdTIwMDNTRUNVUkVcdTIwMDPCt1x1MjAwM1NUQUJMRVx1MjAwM8K3XHUyMDAzRkFTVFx1MjAwM8K3XHUyMDAzJzsKZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RpY2tlcicpLnRleHRDb250ZW50ID0gbXNnLnJlcGVhdCg1KTsKCi8qIOKUgOKUgCBSR0IgUEFSVElDTEVTIOKUgOKUgCAqLwpjb25zdCBDT0xPUlMgPSBbJyNmZjAwODAnLCcjZmY2NjAwJywnI2ZmZmYwMCcsJyMwMGZmODgnLCcjMDBjY2ZmJywnI2FhMDBmZicsJyNmZjAwZmYnLCcjMDA4MGZmJ107CmZvciAobGV0IGkgPSAwOyBpIDwgMjU7IGkrKykgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgZWwuY2xhc3NOYW1lID0gJ3JnYi1wYXJ0aWNsZSc7CiAgY29uc3Qgc2l6ZSA9IE1hdGgucmFuZG9tKCkgKiA0ICsgMjsKICBjb25zdCBjb2xvciA9IENPTE9SU1tNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkgKiBDT0xPUlMubGVuZ3RoKV07CiAgY29uc3QgbGVmdCA9IE1hdGgucmFuZG9tKCkgKiAxMDA7CiAgY29uc3QgZHVyID0gTWF0aC5yYW5kb20oKSAqIDggKyA2OwogIGNvbnN0IGRlbGF5ID0gTWF0aC5yYW5kb20oKSAqIDg7CiAgY29uc3QgZHggPSAoTWF0aC5yYW5kb20oKSAtIDAuNSkgKiAyMDA7CiAgZWwuc3R5bGUuY3NzVGV4dCA9IGAKICAgIHdpZHRoOiR7c2l6ZX1weDsgaGVpZ2h0OiR7c2l6ZX1weDsKICAgIGJhY2tncm91bmQ6JHtjb2xvcn07CiAgICBib3gtc2hhZG93OiAwIDAgJHtzaXplKjN9cHggJHtjb2xvcn07CiAgICBsZWZ0OiR7bGVmdH0lOwogICAgLS1keDoke2R4fXB4OyAtLW9wOiR7TWF0aC5yYW5kb20oKSowLjgrMC4yfTsKICAgIGFuaW1hdGlvbi1kdXJhdGlvbjoke2R1cn1zLCAke2R1ciowLjd9czsKICAgIGFuaW1hdGlvbi1kZWxheToke2RlbGF5fXMsICR7ZGVsYXl9czsKICBgOwogIGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoZWwpOwp9CgovKiDilIDilIAgUEFTU1dPUkQgVE9HR0xFIOKUgOKUgCAqLwpmdW5jdGlvbiB0b2dnbGVQYXNzKCkgewogIGNvbnN0IGYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzc0lucHV0Jyk7CiAgZi50eXBlID0gZi50eXBlID09PSAncGFzc3dvcmQnID8gJ3RleHQnIDogJ3Bhc3N3b3JkJzsKfQoKLyog4pSA4pSAIENBUkQgVElMVCDilIDilIAgKi8KY29uc3QgY2FyZCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjYXJkJyk7CmxldCBteCA9IHdpbmRvdy5pbm5lcldpZHRoLzIsIG15ID0gd2luZG93LmlubmVySGVpZ2h0LzI7CmxldCB0eCA9IDAsIHR5ID0gMDsKZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcignbW91c2Vtb3ZlJywgZSA9PiB7IG14ID0gZS5jbGllbnRYOyBteSA9IGUuY2xpZW50WTsgfSwge3Bhc3NpdmU6dHJ1ZX0pOwooZnVuY3Rpb24gdGlsdCgpIHsKICBjb25zdCByID0gY2FyZC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKICBjb25zdCBkeCA9IChteCAtIChyLmxlZnQgKyByLndpZHRoLzIpKSAgLyAoci53aWR0aC8yKTsKICBjb25zdCBkeSA9IChteSAtIChyLnRvcCAgKyByLmhlaWdodC8yKSkgLyAoci5oZWlnaHQvMik7CiAgdHggKz0gKGR4IC0gdHgpICogMC4wNzsgdHkgKz0gKGR5IC0gdHkpICogMC4wNzsKICBjYXJkLnN0eWxlLnRyYW5zZm9ybSA9IGBwZXJzcGVjdGl2ZSg5MDBweCkgcm90YXRlWCgkeygtdHkqNC41KS50b0ZpeGVkKDMpfWRlZykgcm90YXRlWSgkeyh0eCo0LjUpLnRvRml4ZWQoMyl9ZGVnKSB0cmFuc2xhdGVaKDApYDsKICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUodGlsdCk7Cn0pKCk7CgovKiDilIDilIAgUkdCIEZJUkVGTElFUyBDQU5WQVMg4pSA4pSAICovCmNvbnN0IGNhbnZhcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmZkNhbnZhcycpOwpjb25zdCBjdHggPSBjYW52YXMuZ2V0Q29udGV4dCgnMmQnKTsKZnVuY3Rpb24gcmVzaXplKCkgeyBjYW52YXMud2lkdGggPSBpbm5lcldpZHRoOyBjYW52YXMuaGVpZ2h0ID0gaW5uZXJIZWlnaHQ7IH0KcmVzaXplKCk7CndpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdyZXNpemUnLCByZXNpemUsIHtwYXNzaXZlOnRydWV9KTsKCmNvbnN0IEZDT0xPUlMgPSBbJyNmZjAwODAnLCcjZmY2NjAwJywnI2ZmZmYwMCcsJyMwMGZmODgnLCcjMDBjY2ZmJywnI2FhMDBmZicsJyNmZjAwZmYnLCcjMDA4MGZmJ107CmNvbnN0IE4gPSAzMDsKY29uc3QgZmxpZXMgPSBBcnJheS5mcm9tKHtsZW5ndGg6Tn0sICgpID0+ICh7CiAgeDogTWF0aC5yYW5kb20oKSAqIGlubmVyV2lkdGgsCiAgeTogTWF0aC5yYW5kb20oKSAqIGlubmVySGVpZ2h0LAogIHZ4OiAoTWF0aC5yYW5kb20oKS0uNSkgKiAwLjYsCiAgdnk6IChNYXRoLnJhbmRvbSgpLS41KSAqIDAuNiwKICByOiAgTWF0aC5yYW5kb20oKSAqIDEuNiArIDEsCiAgaGV4OiBGQ09MT1JTW01hdGguZmxvb3IoTWF0aC5yYW5kb20oKSpGQ09MT1JTLmxlbmd0aCldLAogIHBoYXNlOiBNYXRoLnJhbmRvbSgpICogTWF0aC5QSSAqIDIsCiAgcHNwZDogIE1hdGgucmFuZG9tKCkgKiAwLjAxOCArIDAuMDEsCiAgd3g6IE1hdGgucmFuZG9tKCkgKiBpbm5lcldpZHRoLAogIHd5OiBNYXRoLnJhbmRvbSgpICogaW5uZXJIZWlnaHQsCiAgd3Q6IH5+KE1hdGgucmFuZG9tKCkqMjgwKzEwMCksIHdjOjAsCiAgaHVlU2hpZnQ6IE1hdGgucmFuZG9tKCkgKiAzNjAsCn0pKTsKCmxldCBwcmV2ID0gMDsKZnVuY3Rpb24gZnJhbWUodHMpIHsKICBjb25zdCBkdCA9IE1hdGgubWluKHRzIC0gcHJldiwgMzApOyBwcmV2ID0gdHM7CiAgY3R4LmNsZWFyUmVjdCgwLCAwLCBjYW52YXMud2lkdGgsIGNhbnZhcy5oZWlnaHQpOwoKICBmb3IgKGxldCBpID0gMDsgaSA8IE47IGkrKykgewogICAgY29uc3QgZiA9IGZsaWVzW2ldOwogICAgZi5odWVTaGlmdCA9IChmLmh1ZVNoaWZ0ICsgMC41KSAlIDM2MDsKICAgIGNvbnN0IFtyLGcsYl0gPSBoc2xUb1JnYihmLmh1ZVNoaWZ0LCAxMDAsIDU1KTsKCiAgICBpZiAoKytmLndjID4gZi53dCkgewogICAgICBmLnd4ID0gTWF0aC5yYW5kb20oKSpjYW52YXMud2lkdGg7IGYud3kgPSBNYXRoLnJhbmRvbSgpKmNhbnZhcy5oZWlnaHQ7CiAgICAgIGYud3QgPSB+fihNYXRoLnJhbmRvbSgpKjI4MCsxMDApOyBmLndjID0gMDsKICAgIH0KICAgIGYudnggPSBmLnZ4Ki45NyArIChmLnd4LWYueCkqLjAwMjU7CiAgICBmLnZ5ID0gZi52eSouOTcgKyAoZi53eS1mLnkpKi4wMDI1OwogICAgY29uc3Qgc3BkID0gTWF0aC5oeXBvdChmLnZ4LGYudnkpOwogICAgaWYgKHNwZCA+IDAuNzUpIHsgZi52eD1mLnZ4L3NwZCouNzU7IGYudnk9Zi52eS9zcGQqLjc1OyB9CiAgICBmLnggKz0gZi52eCooZHQqLjA2KTsgZi55ICs9IGYudnkqKGR0Ki4wNik7CiAgICBpZiAoZi54PC04KSBmLng9Y2FudmFzLndpZHRoKzg7IGVsc2UgaWYoZi54PmNhbnZhcy53aWR0aCs4KSBmLng9LTg7CiAgICBpZiAoZi55PC04KSBmLnk9Y2FudmFzLmhlaWdodCs4OyBlbHNlIGlmKGYueT5jYW52YXMuaGVpZ2h0KzgpIGYueT0tODsKICAgIGYucGhhc2UgKz0gZi5wc3BkOwogICAgY29uc3QgYnJpZ2h0ID0gLjM4ICsgLjUyKihNYXRoLnNpbihmLnBoYXNlKSouNSsuNSk7CiAgICBjb25zdCBnUiA9IGYuciAqICgzICsgMi4yKihNYXRoLnNpbihmLnBoYXNlKi42OCkqLjUrLjUpKTsKICAgIGNvbnN0IGdyYWQgPSBjdHguY3JlYXRlUmFkaWFsR3JhZGllbnQoZi54LGYueSwwLGYueCxmLnksZ1IqNCk7CiAgICBncmFkLmFkZENvbG9yU3RvcCgwLCAgIGByZ2JhKCR7cn0sJHtnfSwke2J9LCR7KGJyaWdodCouODUpLnRvRml4ZWQoMil9KWApOwogICAgZ3JhZC5hZGRDb2xvclN0b3AoLjM1LCBgcmdiYSgke3J9LCR7Z30sJHtifSwkeyhicmlnaHQqLjMpLnRvRml4ZWQoMil9KWApOwogICAgZ3JhZC5hZGRDb2xvclN0b3AoMSwgICBgcmdiYSgke3J9LCR7Z30sJHtifSwwKWApOwogICAgY3R4LmJlZ2luUGF0aCgpOyBjdHguYXJjKGYueCxmLnksZ1IqNCwwLDYuMjgzMik7CiAgICBjdHguZmlsbFN0eWxlID0gZ3JhZDsgY3R4LmZpbGwoKTsKICAgIGN0eC5iZWdpblBhdGgoKTsgY3R4LmFyYyhmLngsZi55LGYuciwwLDYuMjgzMik7CiAgICBjdHguZmlsbFN0eWxlID0gYHJnYmEoJHtyfSwke2d9LCR7Yn0sJHticmlnaHQudG9GaXhlZCgyKX0pYDsKICAgIGN0eC5maWxsKCk7CiAgfQogIHJlcXVlc3RBbmltYXRpb25GcmFtZShmcmFtZSk7Cn0KcmVxdWVzdEFuaW1hdGlvbkZyYW1lKGZyYW1lKTsKCmZ1bmN0aW9uIGhzbFRvUmdiKGgscyxsKSB7CiAgcy89MTAwOyBsLz0xMDA7CiAgY29uc3Qgaz1uPT4obitoLzMwKSUxMjsKICBjb25zdCBhPXMqTWF0aC5taW4obCwxLWwpOwogIGNvbnN0IGY9bj0+bC1hKk1hdGgubWF4KC0xLE1hdGgubWluKGsobiktMyxNYXRoLm1pbig5LWsobiksMSkpKTsKICByZXR1cm4gW01hdGgucm91bmQoZigwKSoyNTUpLE1hdGgucm91bmQoZig4KSoyNTUpLE1hdGgucm91bmQoZig0KSoyNTUpXTsKfQoKLyog4pSA4pSAIExPR0lOIOKUgOKUgCAqLwpjb25zdCBTRVNTSU9OX0tFWSA9ICdjaGFpeWFfYXV0aCc7CmFzeW5jIGZ1bmN0aW9uIGRvTG9naW4oKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VybmFtZUlucHV0JykudmFsdWUudHJpbSgpOwogIGNvbnN0IHBhc3MgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGFzc0lucHV0JykudmFsdWUudHJpbSgpOwogIGNvbnN0IGJ0biAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9naW5CdG4nKTsKICBpZiAoIXVzZXIgfHwgIXBhc3MpIHsgYWxlcnQoJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBVc2VybmFtZSDguYHguKXguLAgUGFzc3dvcmQnKTsgcmV0dXJuOyB9CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4uaW5uZXJIVE1MID0gJ+KPsyDguIHguLPguKXguLHguIfguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJouLi4nOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goJy9hcGkvbG9naW4nLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHt1c2VybmFtZTp1c2VyLCBwYXNzd29yZDpwYXNzfSkKICAgIH0pOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAgaWYgKGQub2sgfHwgZC5zdWNjZXNzKSB7CiAgICAgIGNvbnN0IGV4cCA9IERhdGUubm93KCkgKyA4ICogMzYwMCAqIDEwMDA7CiAgICAgIHNlc3Npb25TdG9yYWdlLnNldEl0ZW0oU0VTU0lPTl9LRVksIEpTT04uc3RyaW5naWZ5KHt1c2VyLCBwYXNzLCBleHB9KSk7CiAgICAgIGxvY2F0aW9uLnJlcGxhY2UoJ3NzaHdzLmh0bWwnKTsKICAgIH0gZWxzZSB7CiAgICAgIGFsZXJ0KCdVc2VybmFtZSDguKvguKPguLfguK0gUGFzc3dvcmQg4LmE4Lih4LmI4LiW4Li54LiB4LiV4LmJ4Lit4LiHJyk7CiAgICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogICAgICBidG4uaW5uZXJIVE1MID0gJ/CflJMmbmJzcDsg4LmA4LiC4LmJ4Liy4Liq4Li54LmI4Lij4Liw4Lia4LiaJzsKICAgIH0KICB9IGNhdGNoKGUpIHsKICAgIGFsZXJ0KCfguYDguIrguLfguYjguK3guKHguJXguYjguK0gQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTogJyArIGUubWVzc2FnZSk7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgIGJ0bi5pbm5lckhUTUwgPSAn8J+UkyZuYnNwOyDguYDguILguYnguLLguKrguLnguYjguKPguLDguJrguJonOwogIH0KfQpkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdrZXlkb3duJywgZSA9PiB7IGlmKGUua2V5PT09J0VudGVyJykgZG9Mb2dpbigpOyB9KTsKCi8qIOKUgOKUgCBDSEFOR0UgQURNSU4g4pSA4pSAICovCmZ1bmN0aW9uIHNob3dDaGFuZ2VNb2RhbCgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY2hhbmdlTW9kYWwnKS5zdHlsZS5kaXNwbGF5ID0gJ2ZsZXgnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGFuZ2VBbGVydCcpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29sZFBhc3MnKS52YWx1ZSA9ICcnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXdVc2VyJykudmFsdWUgPSAnJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV3UGFzcycpLnZhbHVlID0gJyc7Cn0KZnVuY3Rpb24gaGlkZUNoYW5nZU1vZGFsKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjaGFuZ2VNb2RhbCcpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7Cn0KYXN5bmMgZnVuY3Rpb24gZG9DaGFuZ2VBZG1pbigpIHsKICBjb25zdCBvbGRQYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29sZFBhc3MnKS52YWx1ZS50cmltKCk7CiAgY29uc3QgbmV3VXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXdVc2VyJykudmFsdWUudHJpbSgpOwogIGNvbnN0IG5ld1Bhc3MgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV3UGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBhbGVydEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NoYW5nZUFsZXJ0Jyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvbmZpcm1DaGFuZ2VCdG4nKTsKICBpZiAoIW9sZFBhc3MgfHwgIW5ld1VzZXIgfHwgIW5ld1Bhc3MpIHsKICAgIGFsZXJ0RWwuc3R5bGUuY3NzVGV4dCA9ICdkaXNwbGF5OmJsb2NrO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi1ib3R0b206MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDAsMTI4LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCAjZmYwMDgwO2NvbG9yOiNmZjg4YmI7JzsKICAgIGFsZXJ0RWwudGV4dENvbnRlbnQgPSAn4p2MIOC4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4guC5ieC4reC4oeC4ueC4peC5g+C4q+C5ieC4hOC4o+C4mic7CiAgICByZXR1cm47CiAgfQogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLnRleHRDb250ZW50ID0gJ+KPsyDguIHguLPguKXguLHguIfguJrguLHguJnguJfguLbguIEuLi4nOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goJy9hcGkvY2hhbmdlX2FkbWluJywgewogICAgICBtZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7b2xkX3Bhc3M6b2xkUGFzcywgbmV3X3VzZXI6bmV3VXNlciwgbmV3X3Bhc3M6bmV3UGFzc30pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmIChkLm9rKSB7CiAgICAgIGFsZXJ0RWwuc3R5bGUuY3NzVGV4dCA9ICdkaXNwbGF5OmJsb2NrO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi1ib3R0b206MTRweDtiYWNrZ3JvdW5kOnJnYmEoMCwyNTUsMTM2LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCAjMDBmZjg4O2NvbG9yOiMwMGZmODg7JzsKICAgICAgYWxlcnRFbC50ZXh0Q29udGVudCA9ICfinIUg4LmA4Lib4Lil4Li14LmI4Lii4LiZIFVzZXJuYW1lL1Bhc3N3b3JkIOC4quC4s+C5gOC4o+C5h+C4iCEg4LiB4Lij4Li44LiT4LiyIExvZ2luIOC5g+C4q+C4oeC5iCc7CiAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Liq4Liz4LmA4Lij4LmH4LiIJzsKICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIHNldFRpbWVvdXQoKCkgPT4geyBoaWRlQ2hhbmdlTW9kYWwoKTsgfSwgMjUwMCk7CiAgICB9IGVsc2UgewogICAgICBhbGVydEVsLnN0eWxlLmNzc1RleHQgPSAnZGlzcGxheTpibG9jaztwYWRkaW5nOjEwcHggMTRweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDttYXJnaW4tYm90dG9tOjE0cHg7YmFja2dyb3VuZDpyZ2JhKDI1NSwwLDEyOCwwLjEpO2JvcmRlcjoxcHggc29saWQgI2ZmMDA4MDtjb2xvcjojZmY4OGJiOyc7CiAgICAgIGFsZXJ0RWwudGV4dENvbnRlbnQgPSAn4p2MICcgKyAoZC5lcnJvciB8fCAn4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LmA4Lib4Lil4Li14LmI4Lii4LiZ4LmE4LiU4LmJJyk7CiAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lii4Li34LiZ4Lii4Lix4LiZJzsKICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICB9CiAgfSBjYXRjaChlKSB7CiAgICBhbGVydEVsLnN0eWxlLmNzc1RleHQgPSAnZGlzcGxheTpibG9jaztwYWRkaW5nOjEwcHggMTRweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDttYXJnaW4tYm90dG9tOjE0cHg7YmFja2dyb3VuZDpyZ2JhKDI1NSwwLDEyOCwwLjEpO2JvcmRlcjoxcHggc29saWQgI2ZmMDA4MDtjb2xvcjojZmY4OGJiOyc7CiAgICBhbGVydEVsLnRleHRDb250ZW50ID0gJ+KdjCDguYDguIrguLfguYjguK3guKHguJXguYjguK0gQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTogJyArIGUubWVzc2FnZTsKICAgIGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lii4Li34LiZ4Lii4Lix4LiZJzsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogIH0KfQo8L3NjcmlwdD4KCjwhLS0gQ0hBTkdFIENSRURFTlRJQUxTIE1PREFMIC0tPgo8ZGl2IGlkPSJjaGFuZ2VNb2RhbCIgc3R5bGU9ImRpc3BsYXk6bm9uZTtwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuODUpO2JhY2tkcm9wLWZpbHRlcjpibHVyKDhweCk7ei1pbmRleDo5OTk7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Ij4KICA8ZGl2IHN0eWxlPSJiYWNrZ3JvdW5kOnJnYmEoNSw1LDUsMC45OCk7Ym9yZGVyOjJweCBzb2xpZCAjZmYwMDgwO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjI4cHggMjRweDt3aWR0aDoxMDAlO21heC13aWR0aDozNjBweDttYXJnaW46MjBweDtwb3NpdGlvbjpyZWxhdGl2ZTtib3gtc2hhZG93OjAgMCA0MHB4IHJnYmEoMjU1LDAsMTI4LDAuMyk7YW5pbWF0aW9uOnJnYkJvcmRlciA0cyBsaW5lYXIgaW5maW5pdGU7Ij4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODVyZW07Y29sb3I6I2ZmMDA4MDttYXJnaW4tYm90dG9tOjIwcHg7bGV0dGVyLXNwYWNpbmc6MnB4O2FuaW1hdGlvbjpyZ2JHbG93IDNzIGxpbmVhciBpbmZpbml0ZTsiPvCflJEg4LmA4Lib4Lil4Li14LmI4Lii4LiZIFVzZXJuYW1lIC8gUGFzc3dvcmQ8L2Rpdj4KICAgIDxkaXYgaWQ9ImNoYW5nZUFsZXJ0IiBzdHlsZT0iZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi1ib3R0b206MTRweDsiPjwvZGl2PgogICAgPGRpdiBzdHlsZT0ibWFyZ2luLWJvdHRvbToxMnB4OyI+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZTouNzVyZW07Y29sb3I6cmdiYSgyMDAsMjAwLDI1NSwuNik7bWFyZ2luLWJvdHRvbTo2cHg7Ij5QYXNzd29yZCDguYDguJTguLTguKE8L2Rpdj4KICAgICAgPGlucHV0IGlkPSJvbGRQYXNzIiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IuC4o+C4q+C4seC4quC4nOC5iOC4suC4meC4m+C4seC4iOC4iOC4uOC4muC4seC4mSIgc3R5bGU9IndpZHRoOjEwMCU7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC41KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDAsMTI4LC4zKTtib3JkZXItcmFkaXVzOjExcHg7cGFkZGluZzoxMXB4IDE0cHg7Zm9udC1zaXplOi44OHJlbTtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC44NCk7b3V0bGluZTpub25lO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyI+CiAgICA8L2Rpdj4KICAgIDxkaXYgc3R5bGU9Im1hcmdpbi1ib3R0b206MTJweDsiPgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2NvbG9yOnJnYmEoMjAwLDIwMCwyNTUsLjYpO21hcmdpbi1ib3R0b206NnB4OyI+VXNlcm5hbWUg4LmD4Lir4Lih4LmIPC9kaXY+CiAgICAgIDxpbnB1dCBpZD0ibmV3VXNlciIgdHlwZT0idGV4dCIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIOC5g+C4q+C4oeC5iCIgc3R5bGU9IndpZHRoOjEwMCU7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC41KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDAsMTI4LC4zKTtib3JkZXItcmFkaXVzOjExcHg7cGFkZGluZzoxMXB4IDE0cHg7Zm9udC1zaXplOi44OHJlbTtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC44NCk7b3V0bGluZTpub25lO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmOyI+CiAgICA8L2Rpdj4KICAgIDxkaXYgc3R5bGU9Im1hcmdpbi1ib3R0b206MjBweDsiPgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2NvbG9yOnJnYmEoMjAwLDIwMCwyNTUsLjYpO21hcmdpbi1ib3R0b206NnB4OyI+UGFzc3dvcmQg4LmD4Lir4Lih4LmIPC9kaXY+CiAgICAgIDxpbnB1dCBpZD0ibmV3UGFzcyIgdHlwZT0icGFzc3dvcmQiIHBsYWNlaG9sZGVyPSLguKPguKvguLHguKrguJzguYjguLLguJnguYPguKvguKHguYgiIHN0eWxlPSJ3aWR0aDoxMDAlO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwwLDEyOCwuMyk7Ym9yZGVyLXJhZGl1czoxMXB4O3BhZGRpbmc6MTFweCAxNHB4O2ZvbnQtc2l6ZTouODhyZW07Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuODQpO291dGxpbmU6bm9uZTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjsiPgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjEwcHg7Ij4KICAgICAgPGJ1dHRvbiBpZD0iY29uZmlybUNoYW5nZUJ0biIgb25jbGljaz0iZG9DaGFuZ2VBZG1pbigpIiBzdHlsZT0iZmxleDoxO3BhZGRpbmc6MTJweDtib3JkZXI6bm9uZTtib3JkZXItcmFkaXVzOjExcHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNmZjAwODAsI2FhMDBmZik7Y29sb3I6I2ZmZjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtmb250LXNpemU6LjlyZW07Zm9udC13ZWlnaHQ6NjAwO2N1cnNvcjpwb2ludGVyOyI+4pyFIOC4ouC4t+C4meC4ouC4seC4mTwvYnV0dG9uPgogICAgICA8YnV0dG9uIG9uY2xpY2s9ImhpZGVDaGFuZ2VNb2RhbCgpIiBzdHlsZT0iZmxleDoxO3BhZGRpbmc6MTJweDtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDAsMTI4LC4zKTtib3JkZXItcmFkaXVzOjExcHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC4zKTtjb2xvcjpyZ2JhKDIwMCwyMjAsMjU1LC43KTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtmb250LXNpemU6LjlyZW07Y3Vyc29yOnBvaW50ZXI7Ij7guKLguIHguYDguKXguLTguIE8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KPC9ib2R5Pgo8L2h0bWw+Cg==' | base64 -d > /opt/chaiya-panel/index.html
ok "Login Page พร้อม"

info "สร้าง Dashboard..."
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDt9CiAgLmhkcntiYWNrZ3JvdW5kOnJhZGlhbC1ncmFkaWVudChlbGxpcHNlIDgwJSA2MCUgYXQgMjAlIDIwJSxyZ2JhKDEyNCw1OCwyMzcsMC4yNSkgMCUsdHJhbnNwYXJlbnQgNjAlKSxyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA2MCUgNTAlIGF0IDgwJSA4MCUscmdiYSgzNyw5OSwyMzUsMC4yKSAwJSx0cmFuc3BhcmVudCA2MCUpLGxpbmVhci1ncmFkaWVudCgxNjBkZWcsIzAzMDUwZiAwJSwjMDgwZDFmIDUwJSwjMDUwODEwIDEwMCUpO3BhZGRpbmc6MjBweCAyMHB4IDE4cHg7dGV4dC1hbGlnbjpjZW50ZXI7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO30KICAuaGRyOjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDtyaWdodDowO2hlaWdodDoxcHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdHJhbnNwYXJlbnQscmdiYSgxOTIsMTMyLDI1MiwwLjYpLHRyYW5zcGFyZW50KTt9CiAgLmhkci1zdWJ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6cmdiYSgxOTIsMTMyLDI1MiwwLjcpO21hcmdpbi1ib3R0b206NnB4O30KICAuaGRyLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyNnB4O2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOjJweDt9CiAgLmhkci10aXRsZSBzcGFue2NvbG9yOiNjMDg0ZmM7fQogIC5oZHItZGVzY3ttYXJnaW4tdG9wOjZweDtmb250LXNpemU6MTFweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNDUpO2xldHRlci1zcGFjaW5nOjJweDt9CiAgLmxvZ291dHtwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MTZweDtyaWdodDoxNHB4O2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA3KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4xNSk7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo1cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNik7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7fQoKCgoKICAvKiBOQVYgcGlsbCBzdHlsZSAqLwogIC5uYXYtd3JhcHtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxODBkZWcsIzA4MGQxZiAwJSwjMGMxNDI4IDEwMCUpO3BhZGRpbmc6MTBweCAxMHB4IDA7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6OTk5OTtib3JkZXItYm90dG9tOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO2JveC1zaGFkb3c6MCA0cHggMjBweCByZ2JhKDAsMCwwLDAuMyk7b3ZlcmZsb3c6aGlkZGVuO30KICAubmF2LWZme3Bvc2l0aW9uOmFic29sdXRlO2JvcmRlci1yYWRpdXM6NTAlO3BvaW50ZXItZXZlbnRzOm5vbmU7YW5pbWF0aW9uOm5mZi1kcmlmdCBsaW5lYXIgaW5maW5pdGUsbmZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlO29wYWNpdHk6MDt6LWluZGV4OjE7fQogIEBrZXlmcmFtZXMgbmZmLWRyaWZ0ewogICAgMCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSgwLDApfQogICAgMjUle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKX0KICAgIDUwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MiksdmFyKC0tZHkyKSl9CiAgICA3NSV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDMpLHZhcigtLWR5MykpfQogICAgMTAwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKDAsMCl9CiAgfQogIEBrZXlmcmFtZXMgbmZmLWJsaW5rewogICAgMCUsMTAwJXtvcGFjaXR5OjB9CiAgICAzMCV7b3BhY2l0eToxfQogICAgNTAle29wYWNpdHk6MC44NX0KICAgIDcwJXtvcGFjaXR5OjB9CiAgfQogIC8qIGR1cGxpY2F0ZSBrZXlmcmFtZXMgcmVtb3ZlZCAqLwogIC5uYXZ7ZGlzcGxheTpmbGV4O2dhcDo0cHg7b3ZlcmZsb3cteDphdXRvO3Njcm9sbGJhci13aWR0aDpub25lO3BhZGRpbmctYm90dG9tOjEwcHg7fQogIC5uYXY6Oi13ZWJraXQtc2Nyb2xsYmFye2Rpc3BsYXk6bm9uZTt9CiAgLm5hdi1pdGVte2ZsZXgtc2hyaW5rOjA7cGFkZGluZzoxMHB4IDE4cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC40KTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLXJhZGl1czo5OTlweDtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KTtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNCk7dHJhbnNpdGlvbjphbGwgMC4yMnMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKTtsZXR0ZXItc3BhY2luZzowLjNweDtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKXtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNyk7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDgpO2JvcmRlci1jb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuMTgpO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0xcHgpO30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOiNmZmY7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMyMmM1NWUsIzE2YTM0YSk7Ym9yZGVyLWNvbG9yOnRyYW5zcGFyZW50O2JveC1zaGFkb3c6MCA0cHggMjBweCByZ2JhKDM0LDE5Nyw5NCwwLjUpLDAgMnB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjI1KSBpbnNldDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3JkZXItcmFkaXVzOjk5OXB4O30KICAubmF2LWl0ZW0ubmF2LXNwZWVkLmFjdGl2ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzA2YjZkNCwjMDg5MWIyKTtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSg2LDE4MiwyMTIsMC40KSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4yKSBpbnNldDt9CiAgLm5hdi1pdGVtLm5hdi1zcGVlZDpob3Zlcjpub3QoLmFjdGl2ZSl7Y29sb3I6IzA2YjZkNDtib3JkZXItY29sb3I6cmdiYSg2LDE4MiwyMTIsMC4zKTt9CiAgLnNlY3twYWRkaW5nOjE0cHg7ZGlzcGxheTpub25lO2FuaW1hdGlvbjpmaSAuM3MgZWFzZTt9CiAgLnNlYy5hY3RpdmV7ZGlzcGxheTpibG9jazt9CiAgQGtleWZyYW1lcyBmaXtmcm9te29wYWNpdHk6MDt0cmFuc2Zvcm06dHJhbnNsYXRlWSg2cHgpfXRve29wYWNpdHk6MTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgwKX19CiAgLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxNHB4O3BhZGRpbmc6MTZweDttYXJnaW4tYm90dG9tOjEwcHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNlYy1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zZWMtdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmJ0bi1ye2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo2cHggMTRweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO30KICAuYnRuLXI6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5zZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuc2N7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxNHB4O3BhZGRpbmc6MTRweDtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO30KICAuc2xibHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zdmFse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10eHQpO2xpbmUtaGVpZ2h0OjE7fQogIC5zdmFsIHNwYW57Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLnNzdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6NHB4O30KICAuZG51dHtwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDo1MnB4O2hlaWdodDo1MnB4O21hcmdpbjo0cHggYXV0byA0cHg7fQogIC5kbnV0IHN2Z3t0cmFuc2Zvcm06cm90YXRlKC05MGRlZyk7fQogIC5kYmd7ZmlsbDpub25lO3N0cm9rZTpyZ2JhKDAsMCwwLDAuMDYpO3N0cm9rZS13aWR0aDo0O30KICAuZHZ7ZmlsbDpub25lO3N0cm9rZS13aWR0aDo0O3N0cm9rZS1saW5lY2FwOnJvdW5kO3RyYW5zaXRpb246c3Ryb2tlLWRhc2hvZmZzZXQgMXMgZWFzZTt9CiAgLmRje3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10eHQpO30KICAucGJ7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsMC4wNik7Ym9yZGVyLXJhZGl1czoycHg7bWFyZ2luLXRvcDo4cHg7b3ZlcmZsb3c6aGlkZGVuO30KICAucGZ7aGVpZ2h0OjEwMCU7Ym9yZGVyLXJhZGl1czoycHg7dHJhbnNpdGlvbjp3aWR0aCAxcyBlYXNlO30KICAucGYucHV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdmFyKC0tYWMpLCMxNmEzNGEpO30KICAucGYucGd7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdmFyKC0tbmcpLCMxNmEzNGEpO30KICAucGYucG97YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2ZiOTIzYywjZjk3MzE2KTt9CiAgLnBmLnBye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNlZjQ0NDQsI2RjMjYyNik7fQogIC51YmRne2Rpc3BsYXk6ZmxleDtnYXA6NXB4O2ZsZXgtd3JhcDp3cmFwO21hcmdpbi10b3A6OHB4O30KICAuYmRne2JhY2tncm91bmQ6I2YxZjVmOTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggOHB4O2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLm5ldC1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDoxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLm5pe2ZsZXg6MTt9CiAgLm5ke2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLWFjKTttYXJnaW4tYm90dG9tOjNweDt9CiAgLm5ze2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyMHB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10eHQpO30KICAubnMgc3Bhbntmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC13ZWlnaHQ6NDAwO30KICAubnR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuZGl2aWRlcnt3aWR0aDoxcHg7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpO21hcmdpbjo0cHggMDt9CiAgLm9waWxse2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMyk7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6NXB4IDE0cHg7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbmcpO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo1cHg7d2hpdGUtc3BhY2U6bm93cmFwO30KICAub3BpbGwub2Zme2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4zKTtjb2xvcjojZWY0NDQ0O30KICAuZG90e3dpZHRoOjVweDtoZWlnaHQ6NXB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6dmFyKC0tbmcpO2JveC1zaGFkb3c6MCAwIDNweCB2YXIoLS1uZyk7YW5pbWF0aW9uOnBscyA0cyBlYXNlLWluLW91dCBpbmZpbml0ZTt9CiAgLmRvdC5yZWR7YmFja2dyb3VuZDojZWY0NDQ0O2JveC1zaGFkb3c6MCAwIDRweCAjZWY0NDQ0O30KICBAa2V5ZnJhbWVzIHBsc3swJSwxMDAle29wYWNpdHk6Ljk7Ym94LXNoYWRvdzowIDAgMnB4IHZhcigtLW5nKX01MCV7b3BhY2l0eTouNjtib3gtc2hhZG93OjAgMCA0cHggdmFyKC0tbmcpfX0KICAueHVpLXJvd3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLnh1aS1pbmZve2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtsaW5lLWhlaWdodDoxLjc7fQogIC54dWktaW5mbyBie2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtbGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4O30KICAuc3Zje2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4wNSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjExcHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO30KICAuc3ZjLmRvd257YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjA1KTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4yKTt9CiAgLnN2Yy1se2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7fQogIC8qIC5kZyBzdHlsZXMgZGVmaW5lZCBiZWxvdyB3aXRoIHBpbmcgYW5pbWF0aW9uICovCiAgLmRnLnJlZHtiYWNrZ3JvdW5kOiNlZjQ0NDQ7Ym94LXNoYWRvdzowIDAgNHB4ICNlZjQ0NDQ7fQogIC5zdmMtbntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnN2Yy1we2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLnJiZGd7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4zKTtib3JkZXItcmFkaXVzOjZweDtwYWRkaW5nOjNweCAxMHB4O2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW5nKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoxcHg7fQogIC5yYmRnLmRvd257YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEpO2JvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwwLjMpO2NvbG9yOiNlZjQ0NDQ7fQogIC5sdXt0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDoxNHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLmZ0aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7fQogIC5pbmZvLWJveHtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTRweDt9CiAgLnB0Z2x7ZGlzcGxheTpmbGV4O2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucGJ0bntmbGV4OjE7cGFkZGluZzo5cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXI7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JhY2tncm91bmQ6I2Y4ZmFmYztjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO30KICAucGJ0bi5hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuZmd7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuZmxibHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7b3BhY2l0eTouODttYXJnaW4tYm90dG9tOjVweDt9CiAgLmZpe3dpZHRoOjEwMCU7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjlweDtwYWRkaW5nOjEwcHggMTRweDtmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO291dGxpbmU6bm9uZTt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5maTpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWMpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHZhcigtLWFjLWRpbSk7fQogIC50Z2x7ZGlzcGxheTpmbGV4O2dhcDo4cHg7fQogIC50YnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC50YnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5jYnRue3dpZHRoOjEwMCU7cGFkZGluZzoxNHB4O2JvcmRlci1yYWRpdXM6MTBweDtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo3MDA7Y3Vyc29yOnBvaW50ZXI7Ym9yZGVyOm5vbmU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNmEzNGEsIzIyYzU1ZSwjNGFkZTgwKTtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2xldHRlci1zcGFjaW5nOi41cHg7Ym94LXNoYWRvdzowIDRweCAxNXB4IHJnYmEoMzQsMTk3LDk0LC4zKTt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5jYnRuOmhvdmVye2JveC1zaGFkb3c6MCA2cHggMjBweCByZ2JhKDM0LDE5Nyw5NCwuNDUpO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0xcHgpO30KICAuY2J0bjpkaXNhYmxlZHtvcGFjaXR5Oi41O2N1cnNvcjpub3QtYWxsb3dlZDt0cmFuc2Zvcm06bm9uZTt9CiAgLnNib3h7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEwcHggMTRweDtmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO291dGxpbmU6bm9uZTttYXJnaW4tYm90dG9tOjEycHg7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzO30KICAuc2JveDpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAudWl0ZW17YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMnB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjhweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzowIDFweCA0cHggcmdiYSgwLDAsMCwwLjA0KTt9CiAgLnVpdGVtOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO30KICAudWF2e3dpZHRoOjM2cHg7aGVpZ2h0OjM2cHg7Ym9yZGVyLXJhZGl1czo5cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tcmlnaHQ6MTJweDtmbGV4LXNocmluazowO30KICAuYXYtZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMTUpO2NvbG9yOnZhcigtLW5nKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLmF2LXJ7YmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLDAuMTUpO2NvbG9yOiNmODcxNzE7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI0OCwxMTMsMTEzLC4yKTt9CiAgLmF2LXh7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEyKTtjb2xvcjojZWY0NDQ0O2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjIpO30KICAudW57Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC51bXtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDoycHg7fQogIC5hYmRne2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5hYmRnLm9re2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4zKTtjb2xvcjp2YXIoLS1uZyk7fQogIC5hYmRnLmV4cHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmFiZGcuc29vbntiYWNrZ3JvdW5kOnJnYmEoMjUxLDE0Niw2MCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTEsMTQ2LDYwLC4zKTtjb2xvcjojZjk3MzE2O30KICAubW92ZXJ7cG9zaXRpb246Zml4ZWQ7aW5zZXQ6MDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjUpO2JhY2tkcm9wLWZpbHRlcjpibHVyKDZweCk7ei1pbmRleDo5OTk5O2Rpc3BsYXk6bm9uZTthbGlnbi1pdGVtczpmbGV4LWVuZDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAubW92ZXIub3BlbntkaXNwbGF5OmZsZXg7fQogIC5tb2RhbHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MjBweCAyMHB4IDAgMDt3aWR0aDoxMDAlO21heC13aWR0aDo0ODBweDtwYWRkaW5nOjIwcHg7bWF4LWhlaWdodDo4NXZoO292ZXJmbG93LXk6YXV0bzthbmltYXRpb246c3UgLjNzIGVhc2U7Ym94LXNoYWRvdzowIC00cHggMzBweCByZ2JhKDAsMCwwLDAuMTIpO30KICBAa2V5ZnJhbWVzIHN1e2Zyb217dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMTAwJSl9dG97dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5taGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxNnB4O30KICAubXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLXR4dCk7fQogIC5tY2xvc2V7d2lkdGg6MzJweDtoZWlnaHQ6MzJweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2NvbG9yOnZhcigtLW11dGVkKTtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5kZ3JpZHtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tYm90dG9tOjE0cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHJ7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtwYWRkaW5nOjdweCAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcjpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmRre2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmR2e2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC13ZWlnaHQ6NjAwO30KICAuZHYuZ3JlZW57Y29sb3I6dmFyKC0tbmcpO30KICAuZHYucmVke2NvbG9yOiNlZjQ0NDQ7fQogIC5kdi5tb25ve2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6OXB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO3dvcmQtYnJlYWs6YnJlYWstYWxsO30KICAuYWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7fQogIC5tLXN1YntkaXNwbGF5Om5vbmU7bWFyZ2luLXRvcDoxNHB4O2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMnB4O3BhZGRpbmc6MTRweDt9CiAgLm0tc3ViLm9wZW57ZGlzcGxheTpibG9jazthbmltYXRpb246ZmkgLjJzIGVhc2U7fQogIC5tc3ViLWxibHtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5hYnRue2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweCAxMHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmFidG46aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC5hYnRuIC5haXtmb250LXNpemU6MjJweDttYXJnaW4tYm90dG9tOjZweDt9CiAgLmFidG4gLmFue2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuYWJ0biAuYWR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuYWJ0bi5kYW5nZXI6aG92ZXJ7YmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLC4xKTtib3JkZXItY29sb3I6I2Y4NzE3MTt9CiAgLm9le3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6NDBweCAyMHB4O30KICAub2UgLmVpe2ZvbnQtc2l6ZTo0OHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLm9lIHB7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxM3B4O30KICAub2Nye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxNnB4O30KICAudXR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAvKiByZXN1bHQgYm94ICovCiAgLnJlcy1ib3h7cG9zaXRpb246cmVsYXRpdmU7YmFja2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi10b3A6MTRweDtkaXNwbGF5Om5vbmU7fQogIC5yZXMtYm94LnNob3d7ZGlzcGxheTpibG9jazt9CiAgLnJlcy1jbG9zZXtwb3NpdGlvbjphYnNvbHV0ZTt0b3A6LTExcHg7cmlnaHQ6LTExcHg7d2lkdGg6MjJweDtoZWlnaHQ6MjJweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiNlZjQ0NDQ7Ym9yZGVyOjJweCBzb2xpZCAjZmZmO2NvbG9yOiNmZmY7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NzAwO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtsaW5lLWhlaWdodDoxO2JveC1zaGFkb3c6MCAxcHggNHB4IHJnYmEoMjM5LDY4LDY4LDAuNCk7ei1pbmRleDoyO30KICAucmVzLXJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47cGFkZGluZzo1cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCAjZGNmY2U3O2ZvbnQtc2l6ZToxM3B4O30KICAucmVzLXJvdzpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLnJlcy1re2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTFweDt9CiAgLnJlcy12e2NvbG9yOnZhcigtLXR4dCk7Zm9udC13ZWlnaHQ6NjAwO3dvcmQtYnJlYWs6YnJlYWstYWxsO3RleHQtYWxpZ246cmlnaHQ7bWF4LXdpZHRoOjY1JTt9CiAgLnJlcy1saW5re2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDttYXJnaW4tdG9wOjhweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jb3B5LWJ0bnt3aWR0aDoxMDAlO21hcmdpbi10b3A6OHB4O3BhZGRpbmc6OHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYWMtYm9yZGVyKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Y29sb3I6dmFyKC0tYWMpO2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAvKiBhbGVydCAqLwogIC5hbGVydHtkaXNwbGF5Om5vbmU7cGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7bWFyZ2luLXRvcDoxMHB4O30KICAuYWxlcnQub2t7YmFja2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztjb2xvcjojMTU4MDNkO30KICAuYWxlcnQuZXJye2JhY2tncm91bmQ6I2ZlZjJmMjtib3JkZXI6MXB4IHNvbGlkICNmY2E1YTU7Y29sb3I6I2RjMjYyNjt9CiAgLyogc3Bpbm5lciAqLwogIC5zcGlue2Rpc3BsYXk6aW5saW5lLWJsb2NrO3dpZHRoOjEycHg7aGVpZ2h0OjEycHg7Ym9yZGVyOjJweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4zKTtib3JkZXItdG9wLWNvbG9yOiNmZmY7Ym9yZGVyLXJhZGl1czo1MCU7YW5pbWF0aW9uOnNwIC43cyBsaW5lYXIgaW5maW5pdGU7dmVydGljYWwtYWxpZ246bWlkZGxlO21hcmdpbi1yaWdodDo0cHg7fQogIEBrZXlmcmFtZXMgc3B7dG97dHJhbnNmb3JtOnJvdGF0ZSgzNjBkZWcpfX0KICAubG9hZGluZ3t0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjMwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxM3B4O30KCgogIC8qIOKUgOKUgCBEQVJLIEZPUk0gKFNTSCkg4pSA4pSAICovCiAgLnNzaC1kYXJrLWZvcm17YmFja2dyb3VuZDojMGQxMTE3O2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE4cHggMTZweDttYXJnaW4tYm90dG9tOjA7fQogIC5kYXJrLWZpZWxke21hcmdpbi1ib3R0b206MTJweDt9CiAgLmRhcmstbGFiZWx7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7bGV0dGVyLXNwYWNpbmc6MXB4O2Rpc3BsYXk6YmxvY2s7bWFyZ2luLWJvdHRvbTo1cHg7fQogIC5kYXJrLWlucHV0e3dpZHRoOjEwMCU7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNik7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4xKTtjb2xvcjojZThmNGZmO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEwcHggMTRweDtmb250LXNpemU6MTNweDtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzO30KICAuZGFyay1pbnB1dDpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5kYXJrLWhkcntmb250LXNpemU6MTNweDtjb2xvcjpyZ2JhKDAsMjAwLDI1NSwuOCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MnB4O21hcmdpbi1ib3R0b206MTRweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZnIC5mbGJse2NvbG9yOnJnYmEoMTgwLDIyMCwyNTUsLjUpO2ZvbnQtc2l6ZTo5cHg7fQogIC5zc2gtZGFyay1mb3JtIC5maXtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA2KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2NvbG9yOiNlOGY0ZmY7Ym9yZGVyLXJhZGl1czoxMHB4O30KICAuc3NoLWRhcmstZm9ybSAuZmk6Zm9jdXN7Ym9yZGVyLWNvbG9yOnJnYmEoMCwyMDAsMjU1LC41KTtib3gtc2hhZG93OjAgMCAwIDNweCByZ2JhKDAsMjAwLDI1NSwuMDgpO30KICAuc3NoLWRhcmstZm9ybSAuZmk6OnBsYWNlaG9sZGVye2NvbG9yOnJnYmEoMTgwLDIyMCwyNTUsLjI1KTt9CiAgLmRhcmstbGJse2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnJnYmEoMCwyMDAsMjU1LC43KTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoycHg7bWFyZ2luLWJvdHRvbToxMHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweDt9CiAgLyogUG9ydCBwaWNrZXIgKi8KICAucG9ydC1ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O21hcmdpbi1ib3R0b206MTRweDt9CiAgLnBvcnQtYnRue2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDQpO2JvcmRlcjoxLjVweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4xKTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNHB4IDhweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wb3J0LWJ0biAucGItaWNvbntmb250LXNpemU6MS40cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucG9ydC1idG4gLnBiLW5hbWV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5wb3J0LWJ0biAucGItc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsLjM1KTt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wODB7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgwLDIwMCwyNTUsLjE1KTt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wODAgLnBiLW5hbWV7Y29sb3I6IzAwY2NmZjt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wNDQze2JvcmRlci1jb2xvcjojZmJiZjI0O2JhY2tncm91bmQ6cmdiYSgyNTEsMTkxLDM2LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDI1MSwxOTEsMzYsLjEyKTt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wNDQzIC5wYi1uYW1le2NvbG9yOiNmYmJmMjQ7fQogIC8qIE9wZXJhdG9yIHBpY2tlciAqLwogIC5waWNrLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucGljay1vcHR7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjA4KTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxMnB4IDhweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5waWNrLW9wdCAucGl7Zm9udC1zaXplOjEuNXJlbTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnBpY2stb3B0IC5wbntmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6LjdyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206MnB4O30KICAucGljay1vcHQgLnBze2ZvbnQtc2l6ZTo5cHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMyk7fQogIC5waWNrLW9wdC5hLWR0YWN7Ym9yZGVyLWNvbG9yOiNmZjY2MDA7YmFja2dyb3VuZDpyZ2JhKDI1NSwxMDIsMCwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDI1NSwxMDIsMCwuMTUpO30KICAucGljay1vcHQuYS1kdGFjIC5wbntjb2xvcjojZmY4ODMzO30KICAucGljay1vcHQuYS10cnVle2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdiYSgwLDIwMCwyNTUsLjEpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtdHJ1ZSAucG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtbnB2e2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdiYSgwLDIwMCwyNTUsLjA4KTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMCwyMDAsMjU1LC4xMik7fQogIC5waWNrLW9wdC5hLW5wdiAucG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtZGFya3tib3JkZXItY29sb3I6I2NjNjZmZjtiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgxNTMsNTEsMjU1LC4xKTt9CiAgLnBpY2stb3B0LmEtZGFyayAucG57Y29sb3I6I2NjNjZmZjt9CiAgLnBpY2stb3B0LmEtaGl7Ym9yZGVyLWNvbG9yOiNjYzAwZmY7YmFja2dyb3VuZDpyZ2JhKDIwNCwwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDIwNCwwLDI1NSwuMik7fQogIC5waWNrLW9wdC5hLWhpIC5wbntjb2xvcjojZGQ0NGZmO30KICAucGljay1vcHQuYS1oY3tib3JkZXItY29sb3I6IzAwOTlmZjtiYWNrZ3JvdW5kOnJnYmEoMCwxNTMsMjU1LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMCwxNTMsMjU1LC4yKTt9CiAgLnBpY2stb3B0LmEtaGMgLnBue2NvbG9yOiMzM2FhZmY7fQogIC5waWNrLW9wdC5hLWhhdHtib3JkZXItY29sb3I6I2ZmY2MwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDIwNCwwLC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjU1LDIwNCwwLC4yKTt9CiAgLnBpY2stb3B0LmEtaGF0IC5wbntjb2xvcjojZmZkZDMzO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9CgogIC8qIOKUgOKUgCBIRFIgbG9nbyBhbmltYXRpb25zIChzYW1lIGFzIGxvZ2luKSDilIDilIAgKi8KICBAa2V5ZnJhbWVzIGhkci1vcmJpdC1kYXNoIHsKICAgIGZyb20geyBzdHJva2UtZGFzaG9mZnNldDogMDsgfQogICAgdG8gICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAtMjUxOyB9CiAgfQogIEBrZXlmcmFtZXMgaGRyLXB1bHNlLWRyYXcgewogICAgMCUgICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7IG9wYWNpdHk6IDA7IH0KICAgIDE1JSAgeyBvcGFjaXR5OiAxOyB9CiAgICAxMDAlIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItYmxpbmstZG90IHsKICAgIDAlLCAxMDAlIHsgb3BhY2l0eTogMC4yNTsgfQogICAgNTAlICAgICAgIHsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGhkci1sb2dvLWdsb3cgewogICAgMCUsIDEwMCUgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA2cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDE0cHggIzI1NjNlYik7IH0KICAgIDUwJSAgICAgICB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDE0cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDI4cHggIzI1NjNlYikgZHJvcC1zaGFkb3coMCAwIDQycHggIzA2YjZkNCk7IH0KICB9CiAgLmhkci1sb2dvLXN2Zy13cmFwIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDhweDsKICAgIGFuaW1hdGlvbjogaGRyLWxvZ28tZ2xvdyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgLmhkci1vcmJpdC1yaW5nIHsgdHJhbnNmb3JtLW9yaWdpbjogNTBweCA1MHB4OyBhbmltYXRpb246IGhkci1vcmJpdC1kYXNoIDhzIGxpbmVhciBpbmZpbml0ZTsgfQogIC5oZHItd2F2ZS1hbmltICB7IHN0cm9rZS1kYXNoYXJyYXk6MjIwOyBzdHJva2UtZGFzaG9mZnNldDoyMjA7IGFuaW1hdGlvbjogaGRyLXB1bHNlLWRyYXcgMS42cyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKSAwLjVzIGZvcndhcmRzOyB9CiAgLmhkci1kb3QtMSB7IGFuaW1hdGlvbjogaGRyLWJsaW5rLWRvdCAyLjJzIGVhc2UtaW4tb3V0IDEuOHMgaW5maW5pdGU7IH0KICAuaGRyLWRvdC0yIHsgYW5pbWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMi4ycyBpbmZpbml0ZTsgfQoKICAvKiDilIDilIAgRGFzaGJvYXJkIEZpcmVmbGllcyAoZnVsbCBwYWdlKSDilIDilIAgKi8KICAuZGFzaC1mZiB7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIHotaW5kZXg6IDA7CiAgICBhbmltYXRpb246IGRhc2gtZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLCBkYXNoLWZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgb3BhY2l0eTogMDsKICB9CiAgQGtleWZyYW1lcyBkYXNoLWZmLWRyaWZ0IHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgICAyMCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpOyB9CiAgICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgzKSx2YXIoLS1keTMpKSBzY2FsZSgxLjA1KTsgfQogICAgODAlICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgfQogIEBrZXlmcmFtZXMgZGFzaC1mZi1ibGluayB7CiAgICAwJSwxMDAleyBvcGFjaXR5OjA7IH0gMTUleyBvcGFjaXR5OjA7IH0gMzAleyBvcGFjaXR5OjE7IH0KICAgIDUwJXsgb3BhY2l0eTowLjk7IH0gNjUleyBvcGFjaXR5OjA7IH0gODAleyBvcGFjaXR5OjAuODU7IH0gOTIleyBvcGFjaXR5OjA7IH0KICB9CgogIC8qIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkAogICAgIDNEIENBUkRTIC8gVEFCUyAvIEJVVFRPTlMg4oCUIOC4l+C4uOC4geC4q+C4meC5ieC4sgogIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAqLwogIC5jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMjUpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDI0cHggcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAycHggOHB4IHJnYmEoMzQsMTk3LDk0LDAuMTIpLAogICAgICAwIDE2cHggMzJweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSB0cmFuc2xhdGVaKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVooMCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNHB4IDM2cHggcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDRweCAxNnB4IHJnYmEoMzQsMTk3LDk0LDAuMTgpLAogICAgICAwIDI0cHggNDhweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBOYXYgaXRlbXMgM0QgKi8KICAubmF2LWl0ZW0gewogICAgYm9yZGVyLXJhZGl1czogOTk5cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCAzcHggMCByZ2JhKDAsMCwwLDAuMyksIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSBpbnNldCAhaW1wb3J0YW50OwogICAgdHJhbnNpdGlvbjogYWxsIDAuMjJzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSkgIWltcG9ydGFudDsKICAgIG1hcmdpbjogMCAycHg7CiAgICBwYWRkaW5nOiA5cHggMTZweCAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOwogIH0KICAubmF2LWl0ZW0uYWN0aXZlIHsKICAgIGJvcmRlci1yYWRpdXM6IDk5OXB4ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsKICAgIGJvcmRlci1jb2xvcjogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsKICAgIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzIyYzU1ZSwjMTZhMzRhKSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCA0cHggMTRweCByZ2JhKDM0LDE5Nyw5NCwwLjQ1KSAhaW1wb3J0YW50OwogICAgY29sb3I6ICNmZmYgIWltcG9ydGFudDsKICAgIHBhZGRpbmc6IDlweCAxNnB4ICFpbXBvcnRhbnQ7CiAgfQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSkgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0xcHgpICFpbXBvcnRhbnQ7CiAgICBib3JkZXItY29sb3I6IHJnYmEoMjU1LDI1NSwyNTUsMC4xOCkgIWltcG9ydGFudDsKICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgIWltcG9ydGFudDsKICB9CgogIC8qIEFsbCBidXR0b25zIDNEICovCiAgLmNidG4sIC5idG4tciwgLmNidG0tc3NoLCAuYnRuLXRibCwgLnBidG4sIC50YnRuLAogIC5jb3B5LWJ0biwgLmNvcHktbGluay1idG4sIC5sb2dvdXQsIC5tY2xvc2UsCiAgLmFidG4sIC5wb3J0LWJ0biwgLnBpY2stb3B0IHsKICAgIGJvcmRlci1yYWRpdXM6IDEycHggIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTIpIGluc2V0LAogICAgICAwIDZweCAxNnB4IHJnYmEoMCwwLDAsMC4yKSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMTJzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMTJzIGVhc2UgIWltcG9ydGFudDsKICAgIGJvcmRlci13aWR0aDogMnB4ICFpbXBvcnRhbnQ7CiAgfQogIC5jYnRuOmhvdmVyLCAuYnRuLXI6aG92ZXIsIC5jb3B5LWJ0bjpob3ZlciwKICAuYWJ0bjpob3ZlciwgLnBvcnQtYnRuOmhvdmVyLCAucGljay1vcHQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0ycHgpOwogICAgYm94LXNoYWRvdzoKICAgICAgMCA2cHggMCByZ2JhKDAsMCwwLDAuMzUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xNSkgaW5zZXQsCiAgICAgIDAgMTBweCAyNHB4IHJnYmEoMCwwLDAsMC4yNSkgIWltcG9ydGFudDsKICB9CiAgLmNidG46YWN0aXZlLCAuYnRuLXI6YWN0aXZlLCAuY29weS1idG46YWN0aXZlLAogIC5hYnRuOmFjdGl2ZSwgLnBvcnQtYnRuOmFjdGl2ZSwgLnBpY2stb3B0OmFjdGl2ZSwKICAuYnRuLXRibDphY3RpdmUsIC5sb2dvdXQ6YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgzcHgpIHNjYWxlKDAuOTcpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMCwwLDAsMC40KSwKICAgICAgMCAwIDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA2KSBpbnNldCAhaW1wb3J0YW50OwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMDZzIGVhc2UsIGJveC1zaGFkb3cgMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KCiAgLyogc2VsLWNhcmQgM0QgKi8KICAuc2VsLWNhcmQgewogICAgYm9yZGVyLXJhZGl1czogMThweCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAycHggc29saWQgdmFyKC0tYm9yZGVyKSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA0cHggMCByZ2JhKDAsMCwwLDAuMiksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSBpbnNldCwKICAgICAgMCA4cHggMjBweCByZ2JhKDAsMCwwLDAuMTIpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgdHJhbnNsYXRlWCgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjE4cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjE4cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC5zZWwtY2FyZDpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTNweCkgdHJhbnNsYXRlWCgycHgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDhweCAwIHJnYmEoMCwwLDAsMC4yNSksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEpIGluc2V0LAogICAgICAwIDE2cHggMzJweCByZ2JhKDAsMCwwLDAuMTgpICFpbXBvcnRhbnQ7CiAgfQogIC5zZWwtY2FyZDphY3RpdmUgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDJweCkgdHJhbnNsYXRlWCgwKSBzY2FsZSgwLjk4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCAxcHggMCByZ2JhKDAsMCwwLDAuMykgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA2cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQoKICAvKiB1aXRlbXMgM0QgKi8KICAudWl0ZW0gewogICAgYm9yZGVyLXJhZGl1czogMTRweCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAycHggc29saWQgdmFyKC0tYm9yZGVyKSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCAzcHggMCByZ2JhKDAsMCwwLDAuMTgpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNykgaW5zZXQsCiAgICAgIDAgNnB4IDE0cHggcmdiYSgwLDAsMCwwLjA4KSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMTVzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMTVzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLnVpdGVtOmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA2cHggMCByZ2JhKDAsMCwwLDAuMjIpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOSkgaW5zZXQsCiAgICAgIDAgMTJweCAyNHB4IHJnYmEoMCwwLDAsMC4xMikgIWltcG9ydGFudDsKICB9CiAgLnVpdGVtOmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMnB4KSBzY2FsZSgwLjk4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCAxcHggMCByZ2JhKDAsMCwwLDAuMykgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA2cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC8qIGJvdW5jZSBrZXlmcmFtZSDguKrguLPguKvguKPguLHguJrguIHguJQgKi8KICBAa2V5ZnJhbWVzIGJ0bi1ib3VuY2UgewogICAgMCUgICB7IHRyYW5zZm9ybTogc2NhbGUoMSk7IH0KICAgIDMwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTMpIHRyYW5zbGF0ZVkoM3B4KTsgfQogICAgNjAlICB7IHRyYW5zZm9ybTogc2NhbGUoMS4wNCkgdHJhbnNsYXRlWSgtMnB4KTsgfQogICAgODAlICB7IHRyYW5zZm9ybTogc2NhbGUoMC45OCkgdHJhbnNsYXRlWSgxcHgpOyB9CiAgICAxMDAlIHsgdHJhbnNmb3JtOiBzY2FsZSgxKSB0cmFuc2xhdGVZKDApOyB9CiAgfQogIC5jYnRuOmFjdGl2ZSwgLmJ0bi1yOmFjdGl2ZSwgLmNvcHktYnRuOmFjdGl2ZSB7IGFuaW1hdGlvbjogYnRuLWJvdW5jZSAwLjI4cyBlYXNlIGZvcndhcmRzICFpbXBvcnRhbnQ7IH0KCiAgLyogTmF2IDNEIHBpbGxzIG92ZXJyaWRlICovCiAgLm5hdi1pdGVte2JvcmRlci1yYWRpdXM6OTk5cHghaW1wb3J0YW50O2JveC1zaGFkb3c6MCAzcHggMCByZ2JhKDAsMCwwLDAuMyksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMSkgaW5zZXQhaW1wb3J0YW50O2JvcmRlci13aWR0aDoxLjVweCFpbXBvcnRhbnQ7cGFkZGluZzoxMHB4IDE4cHghaW1wb3J0YW50O30KICAubmF2LWl0ZW0uYWN0aXZle2JvcmRlci1yYWRpdXM6OTk5cHghaW1wb3J0YW50O3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpIWltcG9ydGFudDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzIyYzU1ZSwjMTZhMzRhKSFpbXBvcnRhbnQ7Ym9yZGVyLWNvbG9yOnRyYW5zcGFyZW50IWltcG9ydGFudDtib3gtc2hhZG93OjAgNHB4IDE0cHggcmdiYSgzNCwxOTcsOTQsMC40NSkhaW1wb3J0YW50O2NvbG9yOiNmZmYhaW1wb3J0YW50O3BhZGRpbmc6MTBweCAxOHB4IWltcG9ydGFudDtmb250LXNpemU6MTFweCFpbXBvcnRhbnQ7fQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSl7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCkhaW1wb3J0YW50O30KCiAgLyogRmlyZWZsaWVzIGluc2lkZSBjYXJkcyAqLwogIC5jYXJkLWZme3Bvc2l0aW9uOmFic29sdXRlO2JvcmRlci1yYWRpdXM6NTAlO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDowO2FuaW1hdGlvbjpjZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLGNmZi1ibGluayBlYXNlLWluLW91dCBpbmZpbml0ZTtvcGFjaXR5OjA7fQogIEBrZXlmcmFtZXMgY2ZmLWRyaWZ0ezAle3RyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTt9MjAle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpO300MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDIpLHZhcigtLWR5MikpIHNjYWxlKDAuOSk7fTYwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MyksdmFyKC0tZHkzKSkgc2NhbGUoMS4wNSk7fTgwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7fTEwMCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpO319CiAgQGtleWZyYW1lcyBjZmYtYmxpbmt7MCUsMTAwJXtvcGFjaXR5OjA7fTE1JXtvcGFjaXR5OjA7fTMwJXtvcGFjaXR5OjAuOTt9NTAle29wYWNpdHk6MC43O302NSV7b3BhY2l0eTowO304MCV7b3BhY2l0eTowLjg7fTkyJXtvcGFjaXR5OjA7fX0KICAuY2FyZD4qOm5vdCguY2FyZC1mZil7fQogIC5zYz4qOm5vdCguY2FyZC1mZil7fQoKICAvKiBTUEVFRCBURVNUICovCiAgLnNwZWVkLWhlcm97YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwYTE2MjggMCUsIzA2MTAyMCAxMDAlKTtib3JkZXI6MnB4IHNvbGlkIHJnYmEoNiwxODIsMjEyLDAuMik7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjRweCAxNnB4O21hcmdpbi1ib3R0b206MTJweDt0ZXh0LWFsaWduOmNlbnRlcjtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1oZXJvOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JhY2tncm91bmQ6cmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgODAlIDUwJSBhdCA1MCUgMCUscmdiYSg2LDE4MiwyMTIsMC4xMiksdHJhbnNwYXJlbnQpO30KICAuc3BlZWQtdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjExcHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1nYXVnZS13cmFwe3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjE2MHB4O2hlaWdodDo4MHB4O21hcmdpbjowIGF1dG8gMTZweDt9CiAgLnNwZWVkLWdhdWdlLXN2Z3tvdmVyZmxvdzp2aXNpYmxlO30KICAuc3BlZWQtZ2F1Z2UtYmd7ZmlsbDpub25lO3N0cm9rZTpyZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt9CiAgLnNwZWVkLWdhdWdlLWZpbGx7ZmlsbDpub25lO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSxzdHJva2UgMC4zczt0cmFuc2Zvcm0tb3JpZ2luOjgwcHggODBweDt9CiAgLnNwZWVkLWNlbnRlcntwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MzJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMDZiNmQ0LCM2MGE1ZmEpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7fQogIC5zcGVlZC11bml0e2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNSk7bWFyZ2luLXRvcDoycHg7fQogIC5zcGVlZC1idG5ze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zcGVlZC1idG57cGFkZGluZzoxNHB4O2JvcmRlci1yYWRpdXM6MTRweDtib3JkZXI6bm9uZTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6MnB4O3RyYW5zaXRpb246YWxsIDAuMnM7fQogIC5zcGVlZC1idG4tZGx7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMyNTYzZWIsIzFkNGVkOCk7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNyw5OSwyMzUsMC40KTt9CiAgLnNwZWVkLWJ0bi1kbDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgzNyw5OSwyMzUsMC41KTt9CiAgLnNwZWVkLWJ0bi11bHtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzdjM2FlZCwjNmQyOGQ5KTtjb2xvcjojZmZmO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDEyNCw1OCwyMzcsMC40KTt9CiAgLnNwZWVkLWJ0bi11bDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgxMjQsNTgsMjM3LDAuNSk7fQogIC5zcGVlZC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjQ7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc3BlZWQtcmVzdWx0c3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc3BlZWQtcmVzLWNhcmR7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDQpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzoxNnB4O3RleHQtYWxpZ246Y2VudGVyO30KICAuc3BlZWQtcmVzLWljb257Zm9udC1zaXplOjIwcHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5zcGVlZC1yZXMtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQpO21hcmdpbi1ib3R0b206NHB4O30KICAuc3BlZWQtcmVzLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTt9CiAgLnNwZWVkLXJlcy12YWwuZGwtY29sb3J7Y29sb3I6IzYwYTVmYTt9CiAgLnNwZWVkLXJlcy12YWwudWwtY29sb3J7Y29sb3I6I2E3OGJmYTt9CiAgLnNwZWVkLXJlcy11bml0e2ZvbnQtc2l6ZTo5cHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjMpO21hcmdpbi10b3A6MnB4O30KICAuc3BlZWQtc3RhdHVze2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWluLWhlaWdodDoxOHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoyMHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctaXRlbXt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXBpbmctbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjM1KTttYXJnaW4tYm90dG9tOjJweDt9CiAgLnNwZWVkLXBpbmctdmFse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojNGFkZTgwO30KICAuc3BlZWQtcGluZy12YWwud2Fybntjb2xvcjojZmJiZjI0O30KICAuc3BlZWQtcGluZy12YWwuYmFke2NvbG9yOiNlZjQ0NDQ7fQogIC5zcGVlZC1iYXItd3JhcHtoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1iYXJ7aGVpZ2h0OjEwMCU7Ym9yZGVyLXJhZGl1czoycHg7d2lkdGg6MCU7dHJhbnNpdGlvbjp3aWR0aCAwLjNzIGVhc2U7fQogIC5zcGVlZC1iYXIuZGwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMyNTYzZWIsIzYwYTVmYSk7fQogIC5zcGVlZC1iYXIudWwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCM3YzNhZWQsI2E3OGJmYSk7fQogIC5zcGVlZC1pbmZvLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmcjtnYXA6OHB4O30KICAuc3BlZWQtaW5mby1pdGVte2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjAzKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wNik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLWluZm8tbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo3cHg7bGV0dGVyLXNwYWNpbmc6MXB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4zKTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNwZWVkLWluZm8tdmFse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuOCk7fQogIC5zcGVlZC1wcm9ne2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDYsMTgyLDIxMiwwLjE1KTtib3JkZXItcmFkaXVzOjJweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1wcm9nLWZpbGx7aGVpZ2h0OjEwMCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzA2YjZkNCwjNjBhNWZhKTtib3JkZXItcmFkaXVzOjJweDt3aWR0aDowJTt0cmFuc2l0aW9uOndpZHRoIDAuMnMgZWFzZTt9CgpAa2V5ZnJhbWVzIHBpbmd7MCV7dHJhbnNmb3JtOnNjYWxlKDEpO29wYWNpdHk6Ljd9MTAwJXt0cmFuc2Zvcm06c2NhbGUoMi41KTtvcGFjaXR5OjB9fQouZGd7cG9zaXRpb246cmVsYXRpdmU7ZGlzcGxheTppbmxpbmUtZmxleDt3aWR0aDoxMHB4O2hlaWdodDoxMHB4O2ZsZXgtc2hyaW5rOjA7dmVydGljYWwtYWxpZ246bWlkZGxlO30KLmRnOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTtvcGFjaXR5Oi41O2FuaW1hdGlvbjpwaW5nIDEuNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQouZGc6OmFmdGVye2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTt9Ci5kZy5yZWQ6OmJlZm9yZXtiYWNrZ3JvdW5kOiNlZjQ0NDQ7fQouZGcucmVkOjphZnRlcntiYWNrZ3JvdW5kOiNlZjQ0NDQ7fQouZG90e3Bvc2l0aW9uOnJlbGF0aXZlO2Rpc3BsYXk6aW5saW5lLWZsZXg7d2lkdGg6OHB4O2hlaWdodDo4cHg7ZmxleC1zaHJpbms6MDt2ZXJ0aWNhbC1hbGlnbjptaWRkbGU7fQouZG90OjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTtvcGFjaXR5Oi41O2FuaW1hdGlvbjpwaW5nIDEuNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQouZG90OjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjEuNXB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTt9Ci5kb3QucmVkOjpiZWZvcmV7YmFja2dyb3VuZDojZWY0NDQ0O30KLmRvdC5yZWQ6OmFmdGVye2JhY2tncm91bmQ6I2VmNDQ0NDt9CgogIC5uYXYtaXRlbS5uYXYtdXBkYXRlLmFjdGl2ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2Y1OWUwYiwjZDk3NzA2KTtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgyNDUsMTU4LDExLDAuNCksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMikgaW5zZXQ7fQogIC5uYXYtaXRlbS5uYXYtdXBkYXRlOmhvdmVyOm5vdCguYWN0aXZlKXtjb2xvcjojZjU5ZTBiO2JvcmRlci1jb2xvcjpyZ2JhKDI0NSwxNTgsMTEsMC4zKTt9CiAgLyogVXBkYXRlIHRhYiBzdHlsZXMgKi8KICAudXBkLWNhcmR7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoycHggc29saWQgI2UyZThmMDtib3JkZXItcmFkaXVzOjIwcHg7cGFkZGluZzoyNHB4IDIwcHg7bWFyZ2luLWJvdHRvbToxMnB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OjAgNHB4IDIwcHggcmdiYSgwLDAsMCwwLjA4KTt9CiAgLnVwZC10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6I2Y1OWUwYjt0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tYm90dG9tOjIwcHg7fQogIC51cGQtcHJvZ3Jlc3Mtd3JhcHttYXJnaW46MjBweCAwIDEycHg7fQogIC51cGQtcHJvZ3Jlc3MtdHJhY2t7aGVpZ2h0OjE0cHg7YmFja2dyb3VuZDojZjBmMGYwO2JvcmRlci1yYWRpdXM6OTlweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC51cGQtcHJvZ3Jlc3MtZmlsbHtoZWlnaHQ6MTAwJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMjJjNTVlLCMxNmEzNGEpO2JvcmRlci1yYWRpdXM6OTlweDt3aWR0aDowJTt0cmFuc2l0aW9uOndpZHRoIDAuM3MgZWFzZTtwb3NpdGlvbjpyZWxhdGl2ZTt9CiAgLnVwZC1wcm9ncmVzcy1maWxsOjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO3RvcDowO2xlZnQ6MDtyaWdodDowO2JvdHRvbTowO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMjU1LDI1NSwyNTUsMC4zKSx0cmFuc3BhcmVudCk7YW5pbWF0aW9uOnNoaW1tZXIgMS41cyBpbmZpbml0ZTtib3JkZXItcmFkaXVzOjk5cHg7fQogIEBrZXlmcmFtZXMgc2hpbW1lcntmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVYKC0xMDAlKX10b3t0cmFuc2Zvcm06dHJhbnNsYXRlWCgxMDAlKX19CiAgLnVwZC1wY3R7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjIycHg7Zm9udC13ZWlnaHQ6OTAwO2NvbG9yOiMxNmEzNGE7bWFyZ2luOjhweCAwIDRweDt9CiAgLnVwZC1zdGF0dXN7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEzcHg7Y29sb3I6IzY0NzQ4YjttaW4taGVpZ2h0OjIycHg7bWFyZ2luLWJvdHRvbToxNnB4O30KICAudXBkLXN0YXR1cy5ydW5uaW5ne2NvbG9yOiMyNTYzZWI7fQogIC51cGQtc3RhdHVzLmRvbmV7Y29sb3I6IzE2YTM0YTtmb250LXdlaWdodDo3MDA7fQogIC51cGQtc3RhdHVzLmVycm9ye2NvbG9yOiNlZjQ0NDQ7fQogIC51cGQtYnRue3dpZHRoOjEwMCU7cGFkZGluZzoxNnB4O2JvcmRlci1yYWRpdXM6MTRweDtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2Y1OWUwYiwjZDk3NzA2KTtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzoycHg7Y3Vyc29yOnBvaW50ZXI7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoMjQ1LDE1OCwxMSwwLjQpO3RyYW5zaXRpb246YWxsIDAuMnM7fQogIC51cGQtYnRuOmhvdmVye3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpO2JveC1zaGFkb3c6MCA4cHggMjRweCByZ2JhKDI0NSwxNTgsMTEsMC41KTt9CiAgLnVwZC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAudXBkLWluZm97YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgI2UyZThmMDtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiM2NDc0OGI7bGluZS1oZWlnaHQ6MS43O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnVwZC1pbmZvIGJ7Y29sb3I6IzFlMjkzYjt9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KCgo8c3R5bGUgaWQ9InJnYi1ibGFjay1vdmVycmlkZSI+Ci8qIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkAogICBSR0IgQkxBQ0sgVEhFTUUgT1ZFUlJJREUK4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQICovCjpyb290IHsKICAtLWFjOiAjZmYwMDgwOyAtLWFjLWdsb3c6IHJnYmEoMjU1LDAsMTI4LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgyNTUsMCwxMjgsMC4wOCk7CiAgLS1hYy1ib3JkZXI6IHJnYmEoMjU1LDAsMTI4LDAuMyk7IC0tbmc6ICMwMGZmODg7IC0tbmctZ2xvdzogcmdiYSgwLDI1NSwxMzYsMC4yKTsKICAtLWJnOiAjMDAwMDAwOyAtLWNhcmQ6ICMwNTA1MDU7IC0tdHh0OiAjZThmNGZmOyAtLW11dGVkOiAjNzA5MGFhOwogIC0tYm9yZGVyOiByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpOyAtLXNoYWRvdzogMCAycHggMjBweCByZ2JhKDAsMCwwLDAuOCk7Cn0KKiB7IG1hcmdpbjowOyBwYWRkaW5nOjA7IGJveC1zaXppbmc6Ym9yZGVyLWJveDsgfQpib2R5IHsKICBiYWNrZ3JvdW5kOiAjMDAwICFpbXBvcnRhbnQ7CiAgZm9udC1mYW1pbHk6ICdTYXJhYnVuJywgc2Fucy1zZXJpZjsgY29sb3I6IHZhcigtLXR4dCk7CiAgbWluLWhlaWdodDogMTAwdmg7IG92ZXJmbG93LXg6IGhpZGRlbjsKfQoKLyogUkdCIGFuaW1hdGVkIGJhY2tncm91bmQgKi8KYm9keTo6YmVmb3JlIHsKICBjb250ZW50OiAnJzsKICBwb3NpdGlvbjogZml4ZWQ7IGluc2V0OiAwOyB6LWluZGV4OiAtMjsKICBiYWNrZ3JvdW5kOgogICAgcmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCAxNSUgMTUlLCByZ2JhKDI1NSwwLDEyOCwwLjEpIDAlLCB0cmFuc3BhcmVudCA2MCUpLAogICAgcmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNTAlIDQwJSBhdCA4NSUgODUlLCByZ2JhKDAsMjAwLDI1NSwwLjA4KSAwJSwgdHJhbnNwYXJlbnQgNjAlKSwKICAgIHJhZGlhbC1ncmFkaWVudChlbGxpcHNlIDQwJSA2MCUgYXQgNTAlIDUwJSwgcmdiYSgxNzAsMCwyNTUsMC4wNikgMCUsIHRyYW5zcGFyZW50IDcwJSk7CiAgYW5pbWF0aW9uOiByZ2JCZ1B1bHNlIDhzIGVhc2UtaW4tb3V0IGluZmluaXRlOwp9CkBrZXlmcmFtZXMgcmdiQmdQdWxzZSB7CiAgMCUgICB7IGZpbHRlcjogaHVlLXJvdGF0ZSgwZGVnKTsgfQogIDUwJSAgeyBmaWx0ZXI6IGh1ZS1yb3RhdGUoMTIwZGVnKTsgfQogIDEwMCUgeyBmaWx0ZXI6IGh1ZS1yb3RhdGUoMzYwZGVnKTsgfQp9CgovKiBHcmlkIGJhY2tncm91bmQgKi8KYm9keTo6YWZ0ZXIgewogIGNvbnRlbnQ6ICcnOwogIHBvc2l0aW9uOiBmaXhlZDsgaW5zZXQ6IDA7IHotaW5kZXg6IC0xOyBwb2ludGVyLWV2ZW50czogbm9uZTsKICBiYWNrZ3JvdW5kLWltYWdlOgogICAgbGluZWFyLWdyYWRpZW50KHJnYmEoMjU1LDAsMTI4LDAuMDMpIDFweCwgdHJhbnNwYXJlbnQgMXB4KSwKICAgIGxpbmVhci1ncmFkaWVudCg5MGRlZywgcmdiYSgwLDIwMCwyNTUsMC4wMykgMXB4LCB0cmFuc3BhcmVudCAxcHgpOwogIGJhY2tncm91bmQtc2l6ZTogNDBweCA0MHB4Owp9CgovKiDilIDilIAgUkdCIEFOSU1BVElPTlMg4pSA4pSAICovCkBrZXlmcmFtZXMgcmdiQm9yZGVyIHsKICAwJSAgIHsgYm9yZGVyLWNvbG9yOiAjZmYwMDgwOyBib3gtc2hhZG93OiAwIDAgMTJweCByZ2JhKDI1NSwwLDEyOCwwLjMpLCBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7IH0KICAxNyUgIHsgYm9yZGVyLWNvbG9yOiAjZmY2NjAwOyBib3gtc2hhZG93OiAwIDAgMTJweCByZ2JhKDI1NSwxMDIsMCwwLjMpLCBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7IH0KICAzMyUgIHsgYm9yZGVyLWNvbG9yOiAjZmZmZjAwOyBib3gtc2hhZG93OiAwIDAgMTJweCByZ2JhKDI1NSwyNTUsMCwwLjMpLCBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7IH0KICA1MCUgIHsgYm9yZGVyLWNvbG9yOiAjMDBmZjg4OyBib3gtc2hhZG93OiAwIDAgMTJweCByZ2JhKDAsMjU1LDEzNiwwLjMpLCBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7IH0KICA2NyUgIHsgYm9yZGVyLWNvbG9yOiAjMDBjY2ZmOyBib3gtc2hhZG93OiAwIDAgMTJweCByZ2JhKDAsMjA0LDI1NSwwLjMpLCBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7IH0KICA4MyUgIHsgYm9yZGVyLWNvbG9yOiAjYWEwMGZmOyBib3gtc2hhZG93OiAwIDAgMTJweCByZ2JhKDE3MCwwLDI1NSwwLjMpLCBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7IH0KICAxMDAlIHsgYm9yZGVyLWNvbG9yOiAjZmYwMDgwOyBib3gtc2hhZG93OiAwIDAgMTJweCByZ2JhKDI1NSwwLDEyOCwwLjMpLCBpbnNldCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7IH0KfQpAa2V5ZnJhbWVzIHJnYlRleHQgewogIDAlICAgeyBjb2xvcjogI2ZmMDA4MDsgdGV4dC1zaGFkb3c6IDAgMCA4cHggcmdiYSgyNTUsMCwxMjgsMC41KTsgfQogIDE3JSAgeyBjb2xvcjogI2ZmNjYwMDsgdGV4dC1zaGFkb3c6IDAgMCA4cHggcmdiYSgyNTUsMTAyLDAsMC41KTsgfQogIDMzJSAgeyBjb2xvcjogI2ZmZmYwMDsgdGV4dC1zaGFkb3c6IDAgMCA4cHggcmdiYSgyNTUsMjU1LDAsMC41KTsgfQogIDUwJSAgeyBjb2xvcjogIzAwZmY4ODsgdGV4dC1zaGFkb3c6IDAgMCA4cHggcmdiYSgwLDI1NSwxMzYsMC41KTsgfQogIDY3JSAgeyBjb2xvcjogIzAwY2NmZjsgdGV4dC1zaGFkb3c6IDAgMCA4cHggcmdiYSgwLDIwNCwyNTUsMC41KTsgfQogIDgzJSAgeyBjb2xvcjogI2FhMDBmZjsgdGV4dC1zaGFkb3c6IDAgMCA4cHggcmdiYSgxNzAsMCwyNTUsMC41KTsgfQogIDEwMCUgeyBjb2xvcjogI2ZmMDA4MDsgdGV4dC1zaGFkb3c6IDAgMCA4cHggcmdiYSgyNTUsMCwxMjgsMC41KTsgfQp9CkBrZXlmcmFtZXMgcmdiR3JhZFNoaWZ0IHsKICAwJSAgIHsgYmFja2dyb3VuZC1wb3NpdGlvbjogMCUgNTAlOyB9CiAgNTAlICB7IGJhY2tncm91bmQtcG9zaXRpb246IDEwMCUgNTAlOyB9CiAgMTAwJSB7IGJhY2tncm91bmQtcG9zaXRpb246IDAlIDUwJTsgfQp9CkBrZXlmcmFtZXMgcmdiU3BpbiB7CiAgZnJvbSB7IHRyYW5zZm9ybTogcm90YXRlKDBkZWcpOyB9CiAgdG8gICB7IHRyYW5zZm9ybTogcm90YXRlKDM2MGRlZyk7IH0KfQoKLyog4pSA4pSAIENBUkRTIOKUgOKUgCAqLwouY2FyZCwgLnNjIHsKICBiYWNrZ3JvdW5kOiByZ2JhKDUsNSw1LDAuOTUpICFpbXBvcnRhbnQ7CiAgYm9yZGVyOiAxLjVweCBzb2xpZCAjZmYwMDgwICFpbXBvcnRhbnQ7CiAgYm9yZGVyLXJhZGl1czogMThweCAhaW1wb3J0YW50OwogIGFuaW1hdGlvbjogcmdiQm9yZGVyIDVzIGxpbmVhciBpbmZpbml0ZSAhaW1wb3J0YW50OwogIGJveC1zaGFkb3c6IDAgOHB4IDMycHggcmdiYSgwLDAsMCwwLjgpICFpbXBvcnRhbnQ7CiAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSkgIWltcG9ydGFudDsKfQouY2FyZDpob3ZlciB7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtM3B4KSAhaW1wb3J0YW50OyB9CgovKiDilIDilIAgTkFWIEJBUiDilIDilIAgKi8KLm5hdi13cmFwIHsKICBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLDAuOTUpICFpbXBvcnRhbnQ7CiAgYm9yZGVyLWJvdHRvbTogMXB4IHNvbGlkIHJnYmEoMjU1LDAsMTI4LDAuMikgIWltcG9ydGFudDsKICBib3gtc2hhZG93OiAwIDRweCAyMHB4IHJnYmEoMjU1LDAsMTI4LDAuMTUpICFpbXBvcnRhbnQ7Cn0KLm5hdi1pdGVtIHsKICBjb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjUpICFpbXBvcnRhbnQ7CiAgYm9yZGVyOiAxLjVweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpICFpbXBvcnRhbnQ7CiAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwwLjAzKSAhaW1wb3J0YW50OwogIGJvcmRlci1yYWRpdXM6IDk5OXB4ICFpbXBvcnRhbnQ7CiAgdHJhbnNpdGlvbjogYWxsIDAuMjJzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSkgIWltcG9ydGFudDsKfQoubmF2LWl0ZW06aG92ZXI6bm90KC5hY3RpdmUpIHsKICBib3JkZXItY29sb3I6IHJnYmEoMjU1LDAsMTI4LDAuNCkgIWltcG9ydGFudDsKICBjb2xvcjogI2ZmODhjYyAhaW1wb3J0YW50OwogIGJhY2tncm91bmQ6IHJnYmEoMjU1LDAsMTI4LDAuMDUpICFpbXBvcnRhbnQ7CiAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0xcHgpICFpbXBvcnRhbnQ7Cn0KLm5hdi1pdGVtLmFjdGl2ZSB7CiAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDEzNWRlZywgI2ZmMDA4MCwgI2FhMDBmZiwgIzAwODBmZikgIWltcG9ydGFudDsKICBiYWNrZ3JvdW5kLXNpemU6IDMwMCUgMzAwJSAhaW1wb3J0YW50OwogIGFuaW1hdGlvbjogcmdiR3JhZFNoaWZ0IDNzIGVhc2UtaW4tb3V0IGluZmluaXRlICFpbXBvcnRhbnQ7CiAgYm9yZGVyLWNvbG9yOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogIGNvbG9yOiAjZmZmICFpbXBvcnRhbnQ7CiAgYm94LXNoYWRvdzogMCA0cHggMTZweCByZ2JhKDI1NSwwLDEyOCwwLjUpICFpbXBvcnRhbnQ7CiAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0ycHgpICFpbXBvcnRhbnQ7Cn0KLm5hdi1pdGVtLm5hdi1zcGVlZC5hY3RpdmUgewogIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsICMwMGNjZmYsICMwMDY2ZmYpICFpbXBvcnRhbnQ7CiAgYm94LXNoYWRvdzogMCA0cHggMTZweCByZ2JhKDAsMjA0LDI1NSwwLjUpICFpbXBvcnRhbnQ7Cn0KLm5hdi1pdGVtLm5hdi11cGRhdGUuYWN0aXZlIHsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCAjZmZhYTAwLCAjZmY2NjAwKSAhaW1wb3J0YW50OwogIGJveC1zaGFkb3c6IDAgNHB4IDE2cHggcmdiYSgyNTUsMTcwLDAsMC41KSAhaW1wb3J0YW50Owp9CgovKiDilIDilIAgSEVBREVSIOKUgOKUgCAqLwouaGRyIHsKICBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCAjMDAwIDAlLCAjMDgwMDEwIDUwJSwgIzAwMCAxMDAlKSAhaW1wb3J0YW50OwogIGJvcmRlci1ib3R0b206IDFweCBzb2xpZCByZ2JhKDI1NSwwLDEyOCwwLjMpICFpbXBvcnRhbnQ7CiAgcG9zaXRpb246IHJlbGF0aXZlOyBvdmVyZmxvdzogaGlkZGVuOwp9Ci5oZHI6OmFmdGVyIHsKICBjb250ZW50OiAnJzsKICBwb3NpdGlvbjogYWJzb2x1dGU7IGJvdHRvbTogMDsgbGVmdDogMDsgcmlnaHQ6IDA7IGhlaWdodDogMXB4OwogIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgdHJhbnNwYXJlbnQsICNmZjAwODAsICNhYTAwZmYsICMwMGNjZmYsIHRyYW5zcGFyZW50KTsKICBhbmltYXRpb246IHJnYkdyYWRTaGlmdCAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICBiYWNrZ3JvdW5kLXNpemU6IDMwMCUgMzAwJTsKfQouaGRyLXRpdGxlIHsgY29sb3I6ICNmZmYgIWltcG9ydGFudDsgfQouaGRyLXRpdGxlIHNwYW4geyBhbmltYXRpb246IHJnYlRleHQgNHMgbGluZWFyIGluZmluaXRlICFpbXBvcnRhbnQ7IH0KLmhkci1zdWIgeyBhbmltYXRpb246IHJnYlRleHQgNHMgbGluZWFyIGluZmluaXRlICFpbXBvcnRhbnQ7IGxldHRlci1zcGFjaW5nOiA0cHg7IH0KLmhkci1kZXNjIHsgY29sb3I6IHJnYmEoMjU1LDI1NSwyNTUsMC40KSAhaW1wb3J0YW50OyB9CgovKiDilIDilIAgQlVUVE9OUyDilIDilIAgKi8KLmNidG4gewogIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxMzVkZWcsICNmZjAwODAsICNhYTAwZmYpICFpbXBvcnRhbnQ7CiAgYmFja2dyb3VuZC1zaXplOiAzMDAlIDMwMCU7CiAgYW5pbWF0aW9uOiByZ2JHcmFkU2hpZnQgM3MgZWFzZS1pbi1vdXQgaW5maW5pdGUgIWltcG9ydGFudDsKICBib3gtc2hhZG93OiAwIDRweCAxNnB4IHJnYmEoMjU1LDAsMTI4LDAuNCkgIWltcG9ydGFudDsKICBjb2xvcjogI2ZmZiAhaW1wb3J0YW50Owp9Ci5jYnRuOmhvdmVyIHsgYm94LXNoYWRvdzogMCA4cHggMjRweCByZ2JhKDI1NSwwLDEyOCwwLjYpICFpbXBvcnRhbnQ7IHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsgfQouY2J0bjphY3RpdmUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoM3B4KSAhaW1wb3J0YW50OyB9CgouYnRuLXIgewogIGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsMC41KSAhaW1wb3J0YW50OwogIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMjU1LDAsMTI4LDAuMjUpICFpbXBvcnRhbnQ7CiAgY29sb3I6IHJnYmEoMjAwLDIyMCwyNTUsMC43KSAhaW1wb3J0YW50Owp9Ci5idG4tcjpob3ZlciB7IGJvcmRlci1jb2xvcjogI2ZmMDA4MCAhaW1wb3J0YW50OyBjb2xvcjogI2ZmODhjYyAhaW1wb3J0YW50OyB9CgouY2J0bi1haXMgeyBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCAjMDBmZjg4LCAjMDBjY2FhKSAhaW1wb3J0YW50OyB9Ci5jYnRuLXRydWUgeyBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCAjZmYzMzAwLCAjY2MwMDAwKSAhaW1wb3J0YW50OyB9Ci5jYnRuLXNzaCB7IGJvcmRlcjogMnB4IHNvbGlkICMwMGZmODggIWltcG9ydGFudDsgY29sb3I6ICMwMGZmODggIWltcG9ydGFudDsgYmFja2dyb3VuZDogdHJhbnNwYXJlbnQgIWltcG9ydGFudDsgfQouY2J0bi1zc2g6aG92ZXIgeyBiYWNrZ3JvdW5kOiByZ2JhKDAsMjU1LDEzNiwuMSkgIWltcG9ydGFudDsgYm94LXNoYWRvdzogMCAwIDEycHggcmdiYSgwLDI1NSwxMzYsLjMpICFpbXBvcnRhbnQ7IH0KCi8qIOKUgOKUgCBTRVJWSUNFIFNUQVRVUyDilIDilIAgKi8KLnN2YyB7CiAgYmFja2dyb3VuZDogcmdiYSgwLDI1NSwxMzYsMC4wNCkgIWltcG9ydGFudDsKICBib3JkZXI6IDFweCBzb2xpZCByZ2JhKDAsMjU1LDEzNiwwLjIpICFpbXBvcnRhbnQ7CiAgYm9yZGVyLXJhZGl1czogMTJweCAhaW1wb3J0YW50Owp9Ci5zdmMuZG93biB7CiAgYmFja2dyb3VuZDogcmdiYSgyNTUsMCwxMjgsMC4wNCkgIWltcG9ydGFudDsKICBib3JkZXItY29sb3I6IHJnYmEoMjU1LDAsMTI4LDAuMikgIWltcG9ydGFudDsKfQoucmJkZyB7IGJhY2tncm91bmQ6IHJnYmEoMCwyNTUsMTM2LDAuMSkgIWltcG9ydGFudDsgYm9yZGVyOiAxcHggc29saWQgcmdiYSgwLDI1NSwxMzYsMC4zKSAhaW1wb3J0YW50OyBjb2xvcjogIzAwZmY4OCAhaW1wb3J0YW50OyB9Ci5yYmRnLmRvd24geyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwwLDEyOCwwLjEpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMCwxMjgsMC4zKSAhaW1wb3J0YW50OyBjb2xvcjogI2ZmMDA4MCAhaW1wb3J0YW50OyB9CgovKiDilIDilIAgUFJPR1JFU1MgQkFSUyDilIDilIAgKi8KLnBmLnB1IHsgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCAjZmYwMDgwLCAjYWEwMGZmKSAhaW1wb3J0YW50OyB9Ci5wZi5wZyB7IGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgIzAwZmY4OCwgIzAwY2NhYSkgIWltcG9ydGFudDsgfQoucGYucG8geyBiYWNrZ3JvdW5kOiBsaW5lYXItZ3JhZGllbnQoOTBkZWcsICNmZjY2MDAsICNmZjMzMDApICFpbXBvcnRhbnQ7IH0KLnBmLnByIHsgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDkwZGVnLCAjZmYwMDAwLCAjY2MwMDAwKSAhaW1wb3J0YW50OyB9CgovKiDilIDilIAgRE9OVVQgUklOR1Mg4pSA4pSAICovCiNjcHUtcmluZyB7IHN0cm9rZTogdXJsKCNyZ2JHcmFkMSkgIWltcG9ydGFudDsgfQojcmFtLXJpbmcgeyBzdHJva2U6IHVybCgjcmdiR3JhZDIpICFpbXBvcnRhbnQ7IH0KCi8qIOKUgOKUgCBYVUkgUElMTCDilIDilIAgKi8KLm9waWxsIHsKICBiYWNrZ3JvdW5kOiByZ2JhKDAsMjU1LDEzNiwwLjA4KSAhaW1wb3J0YW50OwogIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMCwyNTUsMTM2LDAuMykgIWltcG9ydGFudDsKICBjb2xvcjogIzAwZmY4OCAhaW1wb3J0YW50Owp9Ci5vcGlsbC5vZmYgewogIGJhY2tncm91bmQ6IHJnYmEoMjU1LDAsMTI4LDAuMDgpICFpbXBvcnRhbnQ7CiAgYm9yZGVyLWNvbG9yOiByZ2JhKDI1NSwwLDEyOCwwLjMpICFpbXBvcnRhbnQ7CiAgY29sb3I6ICNmZjAwODAgIWltcG9ydGFudDsKfQoKLyog4pSA4pSAIE1PREFMIOKUgOKUgCAqLwoubW92ZXIgLm1vZGFsIHsKICBiYWNrZ3JvdW5kOiByZ2JhKDMsMywzLDAuOTgpICFpbXBvcnRhbnQ7CiAgYm9yZGVyOiAycHggc29saWQgI2ZmMDA4MCAhaW1wb3J0YW50OwogIGFuaW1hdGlvbjogcmdiQm9yZGVyIDRzIGxpbmVhciBpbmZpbml0ZSAhaW1wb3J0YW50OwogIGJvcmRlci1yYWRpdXM6IDI0cHggMjRweCAwIDAgIWltcG9ydGFudDsKICBjb2xvcjogdmFyKC0tdHh0KSAhaW1wb3J0YW50Owp9CgovKiDilIDilIAgVVNFUiBJVEVNUyDilIDilIAgKi8KLnVpdGllbSwgLnVpdGFtIHsKICBiYWNrZ3JvdW5kOiByZ2JhKDUsNSw1LDAuOSkgIWltcG9ydGFudDsKICBib3JkZXI6IDEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wNykgIWltcG9ydGFudDsKICBib3JkZXItcmFkaXVzOiAxNHB4ICFpbXBvcnRhbnQ7CiAgY29sb3I6IHZhcigtLXR4dCkgIWltcG9ydGFudDsKfQoudWl0aWVtOmhvdmVyIHsKICBib3JkZXItY29sb3I6ICNmZjAwODAgIWltcG9ydGFudDsKICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwwLDEyOCwwLjA1KSAhaW1wb3J0YW50Owp9Ci51aXRpdGVtOmhvdmVyIHsKICBib3JkZXItY29sb3I6ICNmZjAwODAgIWltcG9ydGFudDsKICBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwwLDEyOCwwLjA1KSAhaW1wb3J0YW50Owp9CgovKiDilIDilIAgU0VMRUNUIENBUkRTIOKUgOKUgCAqLwouc2VsLWNhcmQgewogIGJhY2tncm91bmQ6IHJnYmEoNSw1LDUsMC45KSAhaW1wb3J0YW50OwogIGJvcmRlcjogMS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSAhaW1wb3J0YW50OwogIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKfQouc2VsLWNhcmQ6aG92ZXIgewogIGJvcmRlci1jb2xvcjogI2ZmMDA4MCAhaW1wb3J0YW50OwogIGJhY2tncm91bmQ6IHJnYmEoMjU1LDAsMTI4LDAuMDQpICFpbXBvcnRhbnQ7CiAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVgoMnB4KSAhaW1wb3J0YW50Owp9CgovKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwouc3NoLWRhcmstZm9ybSB7CiAgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwwLjYpICFpbXBvcnRhbnQ7CiAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgyNTUsMCwxMjgsMC4yKSAhaW1wb3J0YW50OwogIGJvcmRlci1yYWRpdXM6IDE2cHggIWltcG9ydGFudDsKfQouZGFyay1pbnB1dCB7CiAgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwwLjUpICFpbXBvcnRhbnQ7CiAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgyNTUsMCwxMjgsMC4yKSAhaW1wb3J0YW50OwogIGNvbG9yOiAjZThmNGZmICFpbXBvcnRhbnQ7CiAgYm9yZGVyLXJhZGl1czogMTBweCAhaW1wb3J0YW50Owp9Ci5kYXJrLWlucHV0OmZvY3VzIHsKICBib3JkZXItY29sb3I6ICNmZjAwODAgIWltcG9ydGFudDsKICBib3gtc2hhZG93OiAwIDAgMCAzcHggcmdiYSgyNTUsMCwxMjgsMC4xKSAhaW1wb3J0YW50Owp9Ci5kYXJrLWhkciB7IGNvbG9yOiAjZmYwMDgwICFpbXBvcnRhbnQ7IGFuaW1hdGlvbjogcmdiVGV4dCA0cyBsaW5lYXIgaW5maW5pdGU7IH0KLmRhcmstbGFiZWwgeyBjb2xvcjogcmdiYSgyMDAsMTUwLDI1NSwwLjYpICFpbXBvcnRhbnQ7IH0KCi8qIOKUgOKUgCBTUEVFRCBIRVJPIOKUgOKUgCAqLwouc3BlZWQtaGVybywgLnN0LWNhcmQgewogIGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCgxNjBkZWcsICMwNTAwMDUgMCUsICMwMDA1MTAgMTAwJSkgIWltcG9ydGFudDsKICBib3JkZXI6IDJweCBzb2xpZCAjMDBjY2ZmICFpbXBvcnRhbnQ7CiAgYm9yZGVyLXJhZGl1czogMjBweCAhaW1wb3J0YW50OwogIGFuaW1hdGlvbjogcmdiQm9yZGVyIDVzIGxpbmVhciBpbmZpbml0ZSAycyAhaW1wb3J0YW50Owp9Ci5zcGVlZC10aXRsZSwgLnN0LXRpdGxlIHsgY29sb3I6ICMwMGNjZmYgIWltcG9ydGFudDsgYW5pbWF0aW9uOiByZ2JUZXh0IDRzIGxpbmVhciBpbmZpbml0ZTsgfQouc3BlZWQtdmFsIHsgY29sb3I6ICNmZmYgIWltcG9ydGFudDsgfQoKLyog4pSA4pSAIEZPUk0gSU5QVVRTIOKUgOKUgCAqLwouZmkgewogIGJhY2tncm91bmQ6IHJnYmEoMCwwLDAsMC41KSAhaW1wb3J0YW50OwogIGJvcmRlcjogMXB4IHNvbGlkIHJnYmEoMjU1LDAsMTI4LDAuMikgIWltcG9ydGFudDsKICBjb2xvcjogI2U4ZjRmZiAhaW1wb3J0YW50OwogIGJvcmRlci1yYWRpdXM6IDEwcHggIWltcG9ydGFudDsKfQouZmk6Zm9jdXMgewogIGJvcmRlci1jb2xvcjogI2ZmMDA4MCAhaW1wb3J0YW50OwogIGJveC1zaGFkb3c6IDAgMCAwIDNweCByZ2JhKDI1NSwwLDEyOCwwLjEpICFpbXBvcnRhbnQ7Cn0KCi8qIOKUgOKUgCBTRUNUSU9OIFRJVExFUyDilIDilIAgKi8KLnNlYy10aXRsZSwgLmZ0aXRsZSwgLnVwZC10aXRsZSB7CiAgYW5pbWF0aW9uOiByZ2JUZXh0IDVzIGxpbmVhciBpbmZpbml0ZSAhaW1wb3J0YW50Owp9Ci50aXRsZS1iYXIsIC5oZHItbG9nby1zdmctd3JhcCB7CiAgYW5pbWF0aW9uOiByZ2JCZ1B1bHNlIDRzIGVhc2UtaW4tb3V0IGluZmluaXRlICFpbXBvcnRhbnQ7Cn0KCi8qIOKUgOKUgCBCQURHRVMg4pSA4pSAICovCi5iZGctZyB7IGJhY2tncm91bmQ6IHJnYmEoMCwyNTUsMTM2LDAuMSkgIWltcG9ydGFudDsgYm9yZGVyOiAxcHggc29saWQgcmdiYSgwLDI1NSwxMzYsMC4zKSAhaW1wb3J0YW50OyBjb2xvcjogIzAwZmY4OCAhaW1wb3J0YW50OyB9Ci5iZGctciB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDAsMTI4LDAuMSkgIWltcG9ydGFudDsgYm9yZGVyOiAxcHggc29saWQgcmdiYSgyNTUsMCwxMjgsMC4zKSAhaW1wb3J0YW50OyBjb2xvcjogI2ZmMDA4MCAhaW1wb3J0YW50OyB9Ci5hYmdkLm9rIHsgYmFja2dyb3VuZDogcmdiYSgwLDI1NSwxMzYsMC4xKSAhaW1wb3J0YW50OyBib3JkZXItY29sb3I6IHJnYmEoMCwyNTUsMTM2LDAuMykgIWltcG9ydGFudDsgY29sb3I6ICMwMGZmODggIWltcG9ydGFudDsgfQouYWJkZy5vayB7IGJhY2tncm91bmQ6IHJnYmEoMCwyNTUsMTM2LDAuMSkgIWltcG9ydGFudDsgYm9yZGVyLWNvbG9yOiByZ2JhKDAsMjU1LDEzNiwwLjMpICFpbXBvcnRhbnQ7IGNvbG9yOiAjMDBmZjg4ICFpbXBvcnRhbnQ7IH0KLmFiZGcuZXhwIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMCwxMjgsMC4xKSAhaW1wb3J0YW50OyBib3JkZXItY29sb3I6IHJnYmEoMjU1LDAsMTI4LDAuMykgIWltcG9ydGFudDsgY29sb3I6ICNmZjAwODAgIWltcG9ydGFudDsgfQouYWJkZy5zb29uIHsgYmFja2dyb3VuZDogcmdiYSgyNTUsMTcwLDAsMC4xKSAhaW1wb3J0YW50OyBib3JkZXItY29sb3I6IHJnYmEoMjU1LDE3MCwwLDAuMykgIWltcG9ydGFudDsgY29sb3I6ICNmZmFhMDAgIWltcG9ydGFudDsgfQoKLyog4pSA4pSAIFVQREFURSBDQVJEIOKUgOKUgCAqLwoudXBkLWNhcmQgewogIGJhY2tncm91bmQ6IHJnYmEoNSw1LDUsMC45OCkgIWltcG9ydGFudDsKICBib3JkZXI6IDJweCBzb2xpZCAjZmZhYTAwICFpbXBvcnRhbnQ7CiAgYm9yZGVyLXJhZGl1czogMjBweCAhaW1wb3J0YW50OwogIGFuaW1hdGlvbjogbm9uZSAhaW1wb3J0YW50Owp9Ci51cGQtcHJvZ3Jlc3MtZmlsbCB7IGJhY2tncm91bmQ6IGxpbmVhci1ncmFkaWVudCg5MGRlZywgI2ZmMDA4MCwgI2FhMDBmZiwgIzAwY2NmZikgIWltcG9ydGFudDsgfQoudXBkLWJ0biB7CiAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDEzNWRlZywgI2ZmYWEwMCwgI2ZmNjYwMCkgIWltcG9ydGFudDsKICBhbmltYXRpb246IG5vbmUgIWltcG9ydGFudDsKfQoKLyog4pSA4pSAIExPR09VVCBCVVRUT04g4pSA4pSAICovCi5sb2dvdXQgewogIGJhY2tncm91bmQ6IHJnYmEoMjU1LDAsMTI4LDAuMDgpICFpbXBvcnRhbnQ7CiAgYm9yZGVyOiAxcHggc29saWQgcmdiYSgyNTUsMCwxMjgsMC4yNSkgIWltcG9ydGFudDsKICBjb2xvcjogcmdiYSgyNTUsMTUwLDIwMCwwLjgpICFpbXBvcnRhbnQ7Cn0KLmxvZ291dDpob3ZlciB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDAsMTI4LDAuMTUpICFpbXBvcnRhbnQ7IGNvbG9yOiAjZmY4OGNjICFpbXBvcnRhbnQ7IH0KCi8qIOKUgOKUgCBET1QvREcgUElORyDilIDilIAgKi8KLmRnOjpiZWZvcmUsIC5kb3Q6OmJlZm9yZSB7IGJhY2tncm91bmQ6ICNmZjAwODAgIWltcG9ydGFudDsgfQouZGc6OmFmdGVyIHsgYmFja2dyb3VuZDogI2ZmMDA4MCAhaW1wb3J0YW50OyB9Ci5kZy5yZWQ6OmJlZm9yZSwgLmRvdC5yZWQ6OmJlZm9yZSB7IGJhY2tncm91bmQ6ICNmZjAwMDAgIWltcG9ydGFudDsgfQouZGcucmVkOjphZnRlciB7IGJhY2tncm91bmQ6ICNmZjAwMDAgIWltcG9ydGFudDsgfQpAa2V5ZnJhbWVzIHBpbmcgeyAwJSB7IHRyYW5zZm9ybTpzY2FsZSgxKTsgb3BhY2l0eTouNzsgfSAxMDAlIHsgdHJhbnNmb3JtOnNjYWxlKDIuNSk7IG9wYWNpdHk6MDsgfSB9CgovKiDilIDilIAgUE9SVCBCVE5TIOKUgOKUgCAqLwoucG9ydC1idG4uYWN0aXZlLXA4MCB7IGJvcmRlci1jb2xvcjogIzAwY2NmZiAhaW1wb3J0YW50OyBiYWNrZ3JvdW5kOiByZ2JhKDAsMjAwLDI1NSwuMDgpICFpbXBvcnRhbnQ7IGJveC1zaGFkb3c6IDAgMCAxMnB4IHJnYmEoMCwyMDAsMjU1LC4yKSAhaW1wb3J0YW50OyB9Ci5wb3J0LWJ0bi5hY3RpdmUtcDQ0MyB7IGJvcmRlci1jb2xvcjogI2ZmYWEwMCAhaW1wb3J0YW50OyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwxNzAsMCwuMDgpICFpbXBvcnRhbnQ7IGJveC1zaGFkb3c6IDAgMCAxMnB4IHJnYmEoMjU1LDE3MCwwLC4xNSkgIWltcG9ydGFudDsgfQoucGljay1vcHQuYS1kdGFjIHsgYm9yZGVyLWNvbG9yOiAjZmY2NjAwICFpbXBvcnRhbnQ7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDEwMiwwLC4xKSAhaW1wb3J0YW50OyB9Ci5waWNrLW9wdC5hLXRydWUgeyBib3JkZXItY29sb3I6ICMwMGNjZmYgIWltcG9ydGFudDsgYmFja2dyb3VuZDogcmdiYSgwLDIwMCwyNTUsLjA4KSAhaW1wb3J0YW50OyB9Ci5waWNrLW9wdC5hLW5wdiB7IGJvcmRlci1jb2xvcjogIzAwY2NmZiAhaW1wb3J0YW50OyBiYWNrZ3JvdW5kOiByZ2JhKDAsMjAwLDI1NSwuMDgpICFpbXBvcnRhbnQ7IH0KLnBpY2stb3B0LmEtZGFyayB7IGJvcmRlci1jb2xvcjogI2NjNjZmZiAhaW1wb3J0YW50OyBiYWNrZ3JvdW5kOiByZ2JhKDE3MCwwLDI1NSwuMDgpICFpbXBvcnRhbnQ7IH0KCi8qIOKUgOKUgCBDT1BZIEJUTlMg4pSA4pSAICovCi5jb3B5LWJ0biB7IGJhY2tncm91bmQ6IHJnYmEoMjU1LDAsMTI4LDAuMDgpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMCwxMjgsMC4yOCkgIWltcG9ydGFudDsgY29sb3I6ICNmZjg4Y2MgIWltcG9ydGFudDsgfQouY29weS1saW5rLWJ0bi5ucHYgeyBiYWNrZ3JvdW5kOiByZ2JhKDAsMTgwLDI1NSwuMDcpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgwLDE4MCwyNTUsLjI4KSAhaW1wb3J0YW50OyBjb2xvcjogIzAwY2NmZiAhaW1wb3J0YW50OyB9Ci5jb3B5LWxpbmstYnRuLmRhcmsgeyBiYWNrZ3JvdW5kOiByZ2JhKDE1Myw1MSwyNTUsLjA3KSAhaW1wb3J0YW50OyBib3JkZXItY29sb3I6IHJnYmEoMTUzLDUxLDI1NSwuMjgpICFpbXBvcnRhbnQ7IGNvbG9yOiAjY2M2NmZmICFpbXBvcnRhbnQ7IH0KCi8qIOKUgOKUgCBUQUJMRSDilIDilIAgKi8KLnV0YmwgdGggeyBjb2xvcjogcmdiYSgyMDAsMTUwLDI1NSwwLjYpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjA2KSAhaW1wb3J0YW50OyB9Ci51dGJsIHRkIHsgYm9yZGVyLWNvbG9yOiByZ2JhKDI1NSwyNTUsMjU1LDAuMDUpICFpbXBvcnRhbnQ7IGNvbG9yOiB2YXIoLS10eHQpICFpbXBvcnRhbnQ7IH0KLnV0YmwgdHI6aG92ZXIgdGQgeyBiYWNrZ3JvdW5kOiByZ2JhKDI1NSwwLDEyOCwwLjAzKSAhaW1wb3J0YW50OyB9Ci5idG4tdGJsIHsgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwwLjUpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjEyKSAhaW1wb3J0YW50OyBjb2xvcjogdmFyKC0tdHh0KSAhaW1wb3J0YW50OyB9Ci5idG4tdGJsOmhvdmVyIHsgYm9yZGVyLWNvbG9yOiAjZmYwMDgwICFpbXBvcnRhbnQ7IH0KCi8qIOKUgOKUgCBJTkZPIEJPWEVTIOKUgOKUgCAqLwouaW5mby1ib3ggeyBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLDAuNCkgIWltcG9ydGFudDsgYm9yZGVyLWNvbG9yOiByZ2JhKDI1NSwyNTUsMjU1LDAuMDcpICFpbXBvcnRhbnQ7IGNvbG9yOiB2YXIoLS1tdXRlZCkgIWltcG9ydGFudDsgfQouZGtleSwgLmRrIHsgY29sb3I6IHZhcigtLW11dGVkKSAhaW1wb3J0YW50OyB9Ci5kdmFsLCAuZHYgeyBjb2xvcjogdmFyKC0tdHh0KSAhaW1wb3J0YW50OyB9Ci5kdi5ncmVlbiB7IGNvbG9yOiAjMDBmZjg4ICFpbXBvcnRhbnQ7IH0KLmR2LnJlZCB7IGNvbG9yOiAjZmYwMDgwICFpbXBvcnRhbnQ7IH0KLmR2Lm1vbm8geyBjb2xvcjogIzAwY2NmZiAhaW1wb3J0YW50OyBmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTsgfQouZGdyaWQsIC5yZXMtYm94IHsgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwwLjQpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjA2KSAhaW1wb3J0YW50OyB9CgovKiDilIDilIAgTElOSyBSRVNVTFQg4pSA4pSAICovCi5saW5rLXByZXZpZXcgeyBiYWNrZ3JvdW5kOiByZ2JhKDAsMCwwLDAuNykgIWltcG9ydGFudDsgYm9yZGVyLWNvbG9yOiByZ2JhKDAsMTUwLDI1NSwuMikgIWltcG9ydGFudDsgY29sb3I6ICMwMGFhZGQgIWltcG9ydGFudDsgfQoubGluay1yZXN1bHQtaGRyIHsgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwwLjUpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjA2KSAhaW1wb3J0YW50OyB9CgovKiDilIDilIAgU0JPWC9TRUFSQ0gg4pSA4pSAICovCi5zYm94IHsgYmFja2dyb3VuZDogcmdiYSgwLDAsMCwwLjUpICFpbXBvcnRhbnQ7IGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjEpICFpbXBvcnRhbnQ7IGNvbG9yOiB2YXIoLS10eHQpICFpbXBvcnRhbnQ7IH0KLnNib3g6Zm9jdXMgeyBib3JkZXItY29sb3I6ICNmZjAwODAgIWltcG9ydGFudDsgfQoKLyog4pSA4pSAIE5BViBDQU5WQVMgRklSRUZMSUVTIOKUgOKUgCAqLwovKiBSR0IgZmlyZWZsaWVzIGFyZSBpbiBjYW52YXMgLSB0aGV5IGFscmVhZHkgdXNlIGNvbG9ycyBhcnJheSAqLwoKLyog4pSA4pSAIEJPVFRPTSBXUkFQIOKUgOKUgCAqLwoud3JhcCB7IG1heC13aWR0aDo0ODBweDsgbWFyZ2luOjAgYXV0bzsgcGFkZGluZy1ib3R0b206NTBweDsgfQoKLyog4pSA4pSAIFNFQyBUQUIg4pSA4pSAICovCi5zZWMtbGFiZWwgeyBjb2xvcjogcmdiYSgyMDAsMTUwLDI1NSwwLjYpICFpbXBvcnRhbnQ7IH0KPC9zdHlsZT4KCjwhLS0gUkdCIFNWRyBncmFkaWVudHMgZm9yIGRvbnV0IHJpbmdzIC0tPgo8c3ZnIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTt3aWR0aDowO2hlaWdodDowIj4KICA8ZGVmcz4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0icmdiR3JhZDEiIHgxPSIwJSIgeTE9IjAlIiB4Mj0iMTAwJSIgeTI9IjEwMCUiPgogICAgICA8c3RvcCBvZmZzZXQ9IjAlIiBzdG9wLWNvbG9yPSIjZmYwMDgwIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTAlIiBzdG9wLWNvbG9yPSIjYWEwMGZmIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzAwY2NmZiIvPgogICAgPC9saW5lYXJHcmFkaWVudD4KICAgIDxsaW5lYXJHcmFkaWVudCBpZD0icmdiR3JhZDIiIHgxPSIwJSIgeTE9IjAlIiB4Mj0iMTAwJSIgeTI9IjEwMCUiPgogICAgICA8c3RvcCBvZmZzZXQ9IjAlIiBzdG9wLWNvbG9yPSIjMDBjY2ZmIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iNTAlIiBzdG9wLWNvbG9yPSIjMDA4MGZmIi8+CiAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iI2FhMDBmZiIvPgogICAgPC9saW5lYXJHcmFkaWVudD4KICA8L2RlZnM+Cjwvc3ZnPgoKPC9oZWFkPgo8Ym9keT4KPGRpdiBjbGFzcz0id3JhcCI+CgogIDwhLS0gSEVBREVSIC0tPgogIDxkaXYgY2xhc3M9ImhkciIgaWQ9Imhkci1yb290Ij4KICA8Y2FudmFzIGlkPSJoZHItY2FudmFzIiBzdHlsZT0icG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDt3aWR0aDoxMDAlO2hlaWdodDoxMDAlO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDoxOyI+PC9jYW52YXM+CiAgPHNjcmlwdD4KICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignRE9NQ29udGVudExvYWRlZCcsZnVuY3Rpb24oKXsKICAgIGNvbnN0IGNhbnZhcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLWNhbnZhcycpOwogICAgY29uc3Qgd3JhcD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnaGRyLXJvb3QnKTsKICAgIGZ1bmN0aW9uIHJlc2l6ZSgpe2NhbnZhcy53aWR0aD13cmFwLm9mZnNldFdpZHRoO2NhbnZhcy5oZWlnaHQ9d3JhcC5vZmZzZXRIZWlnaHQ7fQogICAgcmVzaXplKCk7CiAgICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcigncmVzaXplJyxyZXNpemUpOwogICAgY29uc3QgY3R4PWNhbnZhcy5nZXRDb250ZXh0KCcyZCcpOwogICAgY29uc3QgY29sb3JzPVsnI2ZmMDA4MCcsJyNmZjY2MDAnLCcjZmZmZjAwJywnIzAwZmY4OCcsJyMwMGNjZmYnLCcjYWEwMGZmJywnI2ZmMDBmZicsJyMwMDgwZmYnLCcjZmY0NGNjJywnIzQ0ZmZjYyddOwogICAgY29uc3QgZmZzPVtdOwogICAgZm9yKGxldCBpPTA7aTwzNTtpKyspewogICAgICBmZnMucHVzaCh7CiAgICAgICAgeDpNYXRoLnJhbmRvbSgpKmNhbnZhcy53aWR0aCwKICAgICAgICB5Ok1hdGgucmFuZG9tKCkqY2FudmFzLmhlaWdodCwKICAgICAgICByOk1hdGgucmFuZG9tKCkqMS44KzAuNiwKICAgICAgICBjb2xvcjpjb2xvcnNbTWF0aC5mbG9vcihNYXRoLnJhbmRvbSgpKmNvbG9ycy5sZW5ndGgpXSwKICAgICAgICB2eDooTWF0aC5yYW5kb20oKS0wLjUpKjAuNSwKICAgICAgICB2eTooTWF0aC5yYW5kb20oKS0wLjUpKjAuNCwKICAgICAgICBhbHBoYTowLAogICAgICAgIGFscGhhRGlyOk1hdGgucmFuZG9tKCk+MC41PzE6LTEsCiAgICAgICAgYWxwaGFTcGVlZDpNYXRoLnJhbmRvbSgpKjAuMDE1KzAuMDA1LAogICAgICB9KTsKICAgIH0KICAgIGZ1bmN0aW9uIGRyYXcoKXsKICAgICAgcmVzaXplKCk7CiAgICAgIGN0eC5jbGVhclJlY3QoMCwwLGNhbnZhcy53aWR0aCxjYW52YXMuaGVpZ2h0KTsKICAgICAgZmZzLmZvckVhY2goZj0+ewogICAgICAgIGYueCs9Zi52eDsgZi55Kz1mLnZ5OwogICAgICAgIGlmKGYueDwwKWYueD1jYW52YXMud2lkdGg7CiAgICAgICAgaWYoZi54PmNhbnZhcy53aWR0aClmLng9MDsKICAgICAgICBpZihmLnk8MClmLnk9Y2FudmFzLmhlaWdodDsKICAgICAgICBpZihmLnk+Y2FudmFzLmhlaWdodClmLnk9MDsKICAgICAgICBmLmFscGhhKz1mLmFscGhhRGlyKmYuYWxwaGFTcGVlZDsKICAgICAgICBpZihmLmFscGhhPj0xKXtmLmFscGhhPTE7Zi5hbHBoYURpcj0tMTt9CiAgICAgICAgaWYoZi5hbHBoYTw9MCl7Zi5hbHBoYT0wO2YuYWxwaGFEaXI9MTt9CiAgICAgICAgY3R4LnNhdmUoKTsKICAgICAgICBjdHguZ2xvYmFsQWxwaGE9Zi5hbHBoYTsKICAgICAgICBjdHguc2hhZG93Qmx1cj1mLnIqODsKICAgICAgICBjdHguc2hhZG93Q29sb3I9Zi5jb2xvcjsKICAgICAgICBjdHguYmVnaW5QYXRoKCk7CiAgICAgICAgY3R4LmFyYyhmLngsZi55LGYuciwwLE1hdGguUEkqMik7CiAgICAgICAgY3R4LmZpbGxTdHlsZT1mLmNvbG9yOwogICAgICAgIGN0eC5maWxsKCk7CiAgICAgICAgY3R4LnJlc3RvcmUoKTsKICAgICAgfSk7CiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShkcmF3KTsKICAgIH0KICAgIGRyYXcoKTsKICB9KTsKICA8L3NjcmlwdD4KICAgIDxidXR0b24gY2xhc3M9ImxvZ291dCIgb25jbGljaz0iZG9Mb2dvdXQoKSIgc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO3RvcDoxNnB4O3JpZ2h0OjE0cHg7ei1pbmRleDoxMDsiPuKGqSDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KCiAgICA8IS0tIExvZ28gU1ZHIChzYW1lIGFzIGxvZ2luKSAtLT4KICAgIDxkaXYgY2xhc3M9Imhkci1sb2dvLXN2Zy13cmFwIj4KICAgICAgPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3aWR0aD0iNzIiIGhlaWdodD0iNzIiPgogICAgICAgIDxkZWZzPgogICAgICAgICAgPGxpbmVhckdyYWRpZW50IGlkPSJoVyIgeDE9IjAlIiB5MT0iMCUiIHgyPSIxMDAlIiB5Mj0iMCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMyNTYzZWIiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSI1MCUiICBzdG9wLWNvbG9yPSIjNjBhNWZhIi8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzA2YjZkNCIvPgogICAgICAgICAgPC9saW5lYXJHcmFkaWVudD4KICAgICAgICAgIDxyYWRpYWxHcmFkaWVudCBpZD0iaEJnIiBjeD0iNTAlIiBjeT0iNTAlIiByPSI1MCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMwZjFlNGEiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMwNjBjMWUiIHN0b3Atb3BhY2l0eT0iMC45OCIvPgogICAgICAgICAgPC9yYWRpYWxHcmFkaWVudD4KICAgICAgICAgIDxmaWx0ZXIgaWQ9ImhHbG93Ij4KICAgICAgICAgICAgPGZlR2F1c3NpYW5CbHVyIHN0ZERldmlhdGlvbj0iMi41IiByZXN1bHQ9ImIiLz4KICAgICAgICAgICAgPGZlTWVyZ2U+PGZlTWVyZ2VOb2RlIGluPSJiIi8+PGZlTWVyZ2VOb2RlIGluPSJTb3VyY2VHcmFwaGljIi8+PC9mZU1lcmdlPgogICAgICAgICAgPC9maWx0ZXI+CiAgICAgICAgICA8Y2xpcFBhdGggaWQ9ImhDbGlwIj48Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIvPjwvY2xpcFBhdGg+CiAgICAgICAgPC9kZWZzPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQ2IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMTIpIiBzdHJva2Utd2lkdGg9IjEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSI0MiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC4yKSIgc3Ryb2tlLXdpZHRoPSIxIiBzdHJva2UtZGFzaGFycmF5PSI1IDQiIGNsYXNzPSJoZHItb3JiaXQtcmluZyIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM4IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMjIpIiBzdHJva2Utd2lkdGg9IjEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIgZmlsbD0idXJsKCNoQmcpIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiIGZpbGw9Im5vbmUiIHN0cm9rZT0idXJsKCNoVykiIHN0cm9rZS13aWR0aD0iMS44IiBvcGFjaXR5PSIwLjkiLz4KICAgICAgICA8bGluZSB4MT0iNTAiIHkxPSIxNCIgeDI9IjUwIiB5Mj0iMjAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iODAiIHgyPSI1MCIgeTI9Ijg2IiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSIxNCIgeTE9IjUwIiB4Mj0iMjAiIHkyPSI1MCIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iODAiIHkxPSI1MCIgeDI9Ijg2IiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGcgY2xpcC1wYXRoPSJ1cmwoI2hDbGlwKSI+CiAgICAgICAgICA8cG9seWxpbmUgcG9pbnRzPSIxNiw1MCAyNCw1MCAyOSwzMiAzNCw2OCAzOSwzMiA0NCw1MCA4NCw1MCIKICAgICAgICAgICAgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ1cmwoI2hXKSIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIKICAgICAgICAgICAgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci13YXZlLWFuaW0iLz4KICAgICAgICA8L2c+CiAgICAgICAgPGNpcmNsZSBjeD0iMjkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjNjBhNWZhIiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0xIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjMDZiNmQ0IiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0yIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzQiIGN5PSI2OCIgcj0iMi41IiBmaWxsPSIjNjBhNWZhIiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0xIi8+CiAgICAgIDwvc3ZnPgogICAgPC9kaXY+CgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE4cHg7Zm9udC13ZWlnaHQ6OTAwO2xldHRlci1zcGFjaW5nOjRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZTBmMmZlLCM2MGE1ZmEsIzA2YjZkNCk7LXdlYmtpdC1iYWNrZ3JvdW5kLWNsaXA6dGV4dDstd2Via2l0LXRleHQtZmlsbC1jb2xvcjp0cmFuc3BhcmVudDtiYWNrZ3JvdW5kLWNsaXA6dGV4dDsiPkNIQUlZQTwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzo5cHg7Y29sb3I6cmdiYSg5NiwxNjUsMjUwLDAuNik7bWFyZ2luLXRvcDoycHg7Ij5QUk9KRUNUPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJ3aWR0aDoxNDBweDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LCM2MGE1ZmEsIzA2YjZkNCx0cmFuc3BhcmVudCk7bWFyZ2luOjZweCBhdXRvO29wYWNpdHk6MC41OyI+PC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjRweDtjb2xvcjpyZ2JhKDYsMTgyLDIxMiwwLjU1KTttYXJnaW4tdG9wOjJweDsiPlYyUkFZICZhbXA7IFNTSDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6cmdiYSg5NiwxNjUsMjUwLDAuNSk7bWFyZ2luLXRvcDo0cHg7IiBpZD0iaGRyLWRvbWFpbiI+U0VDVVJFIFBBTkVMPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gTkFWIC0tPgogIDxkaXYgY2xhc3M9Im5hdi13cmFwIiBpZD0ibmF2LXdyYXAiPgogIDxjYW52YXMgaWQ9Im5hdi1jYW52YXMiIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO3dpZHRoOjEwMCU7aGVpZ2h0OjEwMCU7cG9pbnRlci1ldmVudHM6bm9uZTt6LWluZGV4OjE7Ij48L2NhbnZhcz4KICA8c2NyaXB0PgogIHdpbmRvdy5hZGRFdmVudExpc3RlbmVyKCdET01Db250ZW50TG9hZGVkJyxmdW5jdGlvbigpewogICAgY29uc3QgY2FudmFzPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduYXYtY2FudmFzJyk7CiAgICBjb25zdCB3cmFwPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduYXYtd3JhcCcpOwogICAgZnVuY3Rpb24gcmVzaXplKCl7Y2FudmFzLndpZHRoPXdyYXAub2Zmc2V0V2lkdGg7Y2FudmFzLmhlaWdodD13cmFwLm9mZnNldEhlaWdodDt9CiAgICByZXNpemUoKTsKICAgIGNvbnN0IGN0eD1jYW52YXMuZ2V0Q29udGV4dCgnMmQnKTsKICAgIGNvbnN0IGNvbG9ycz1bJyNmZjAwODAnLCcjZmY2NjAwJywnI2ZmZmYwMCcsJyMwMGZmODgnLCcjMDBjY2ZmJywnI2FhMDBmZicsJyNmZjAwZmYnLCcjMDA4MGZmJ107CiAgICBjb25zdCBmZnM9W107CiAgICBmb3IobGV0IGk9MDtpPDIyO2krKyl7CiAgICAgIGZmcy5wdXNoKHsKICAgICAgICB4Ok1hdGgucmFuZG9tKCkqY2FudmFzLndpZHRoLAogICAgICAgIHk6TWF0aC5yYW5kb20oKSpjYW52YXMuaGVpZ2h0LAogICAgICAgIHI6TWF0aC5yYW5kb20oKSoxLjUrMC44LAogICAgICAgIGNvbG9yOmNvbG9yc1tNYXRoLmZsb29yKE1hdGgucmFuZG9tKCkqY29sb3JzLmxlbmd0aCldLAogICAgICAgIHZ4OihNYXRoLnJhbmRvbSgpLTAuNSkqMC42LAogICAgICAgIHZ5OihNYXRoLnJhbmRvbSgpLTAuNSkqMC40LAogICAgICAgIGFscGhhOjAsCiAgICAgICAgYWxwaGFEaXI6TWF0aC5yYW5kb20oKT4wLjU/MTotMSwKICAgICAgICBhbHBoYVNwZWVkOk1hdGgucmFuZG9tKCkqMC4wMiswLjAwOCwKICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBkcmF3KCl7CiAgICAgIHJlc2l6ZSgpOwogICAgICBjdHguY2xlYXJSZWN0KDAsMCxjYW52YXMud2lkdGgsY2FudmFzLmhlaWdodCk7CiAgICAgIGZmcy5mb3JFYWNoKGY9PnsKICAgICAgICBmLngrPWYudng7IGYueSs9Zi52eTsKICAgICAgICBpZihmLng8MClmLng9Y2FudmFzLndpZHRoOwogICAgICAgIGlmKGYueD5jYW52YXMud2lkdGgpZi54PTA7CiAgICAgICAgaWYoZi55PDApZi55PWNhbnZhcy5oZWlnaHQ7CiAgICAgICAgaWYoZi55PmNhbnZhcy5oZWlnaHQpZi55PTA7CiAgICAgICAgZi5hbHBoYSs9Zi5hbHBoYURpcipmLmFscGhhU3BlZWQ7CiAgICAgICAgaWYoZi5hbHBoYT49MSl7Zi5hbHBoYT0xO2YuYWxwaGFEaXI9LTE7fQogICAgICAgIGlmKGYuYWxwaGE8PTApe2YuYWxwaGE9MDtmLmFscGhhRGlyPTE7fQogICAgICAgIGN0eC5zYXZlKCk7CiAgICAgICAgY3R4Lmdsb2JhbEFscGhhPWYuYWxwaGE7CiAgICAgICAgY3R4LmJlZ2luUGF0aCgpOwogICAgICAgIGN0eC5hcmMoZi54LGYueSxmLnIsMCxNYXRoLlBJKjIpOwogICAgICAgIGN0eC5maWxsU3R5bGU9Zi5jb2xvcjsKICAgICAgICBjdHguZmlsbCgpOwogICAgICAgIGN0eC5zaGFkb3dCbHVyPWYucio2OwogICAgICAgIGN0eC5zaGFkb3dDb2xvcj1mLmNvbG9yOwogICAgICAgIGN0eC5maWxsKCk7CiAgICAgICAgY3R4LnJlc3RvcmUoKTsKICAgICAgfSk7CiAgICAgIHJlcXVlc3RBbmltYXRpb25GcmFtZShkcmF3KTsKICAgIH0KICAgIGRyYXcoKTsKICB9KTsKICA8L3NjcmlwdD4KICA8ZGl2IGNsYXNzPSJuYXYiPgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gYWN0aXZlIiBvbmNsaWNrPSJzdygnZGFzaGJvYXJkJyx0aGlzKSI+8J+TiiDguYHguJTguIrguJrguK3guKPguYzguJQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnY3JlYXRlJyx0aGlzKSI+4p6VIOC4quC4o+C5ieC4suC4h+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdtYW5hZ2UnLHRoaXMpIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdvbmxpbmUnLHRoaXMpIj7wn5+iIOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdiYW4nLHRoaXMpIj7wn5qrIOC4m+C4peC4lOC5geC4muC4mTwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gbmF2LXNwZWVkIiBvbmNsaWNrPSJzdygnc3BlZWQnLHRoaXMpIj7imqEg4Liq4Lib4Li14LiU4LmA4LiX4LiqPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSBuYXYtdXBkYXRlIiBvbmNsaWNrPSJzdygndXBkYXRlJyx0aGlzKSI+8J+UhCDguK3guLHguJ7guYDguJTguJc8L2Rpdj4KICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgREFTSEJPQVJEIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMgYWN0aXZlIiBpZD0idGFiLWRhc2hib2FyZCI+CiAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgPHNwYW4gY2xhc3M9InNlYy10aXRsZSI+4pqhIFNZU1RFTSBNT05JVE9SPC9zcGFuPgogICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgaWQ9ImJ0bi1yZWZyZXNoIiBvbmNsaWNrPSJsb2FkRGFzaCgpIj7ihrsg4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InNncmlkIj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPuKaoSBDUFUgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9ImNwdS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzRhZGU4MCIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0iY3B1LXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0iY3B1LWNvcmVzIj4tLSBjb3JlczwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwZyIgaWQ9ImNwdS1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+noCBSQU0gVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkbnV0Ij4KICAgICAgICAgIDxzdmcgd2lkdGg9IjUyIiBoZWlnaHQ9IjUyIiB2aWV3Qm94PSIwIDAgNTIgNTIiPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkYmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIvPgogICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJkdiIgaWQ9InJhbS1yaW5nIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiIHN0cm9rZT0iIzNiODJmNiIKICAgICAgICAgICAgICBzdHJva2UtZGFzaGFycmF5PSIxMzguMiIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjEzOC4yIi8+CiAgICAgICAgICA8L3N2Zz4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRjIiBpZD0icmFtLXBjdCI+LS0lPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIiBpZD0icmFtLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwdSIgaWQ9InJhbS1iYXIiIHN0eWxlPSJ3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjM2I4MmY2LCM2MGE1ZmEpIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7wn5K+IERJU0sgVVNBR0U8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdmFsIiBpZD0iZGlzay1wY3QiPi0tPHNwYW4+JTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0iZGlzay1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcG8iIGlkPSJkaXNrLWJhciIgc3R5bGU9IndpZHRoOjAlIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7ij7EgVVBUSU1FPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9InVwdGltZS12YWwiIHN0eWxlPSJmb250LXNpemU6MjBweCI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzc3ViIiBpZD0idXB0aW1lLXN1YiI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YmRnIiBpZD0ibG9hZC1jaGlwcyI+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+MkCBORVRXT1JLIEkvTzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJuZXQtcm93Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaRIFVwbG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtdXAiPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtdXAtdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRpdmlkZXIiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Im5pIiBzdHlsZT0idGV4dC1hbGlnbjpyaWdodCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJuZCI+4oaTIERvd25sb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJucyIgaWQ9Im5ldC1kbiI+LS08c3Bhbj4gLS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJudCIgaWQ9Im5ldC1kbi10b3RhbCI+dG90YWw6IC0tPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+ToSBYLVVJIFBBTkVMIFNUQVRVUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ4dWktcm93Ij4KICAgICAgICA8ZGl2IGlkPSJ4dWktcGlsbCIgY2xhc3M9Im9waWxsIG9mZiI+PHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj7guIHguLPguKXguLHguIfguYDguIrguYfguIQuLi48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ4dWktaW5mbyI+CiAgICAgICAgICA8ZGl2PuC5gOC4p+C4reC4o+C5jOC4iuC4seC4mSBYcmF5OiA8YiBpZD0ieHVpLXZlciI+LS08L2I+PC9kaXY+CiAgICAgICAgICA8ZGl2PkluYm91bmRzOiA8YiBpZD0ieHVpLWluYm91bmRzIj4tLTwvYj4g4Lij4Liy4Lii4LiB4Liy4LijPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPgogICAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSI+8J+UpyBTRVJWSUNFIE1PTklUT1I8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZFNlcnZpY2VzKCkiPuKGuyDguYDguIrguYfguIQ8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1saXN0IiBpZD0ic3ZjLWxpc3QiPgogICAgICAgIDxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibHUiIGlkPSJsYXN0LXVwZGF0ZSI+4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAtLTwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBDUkVBVEUg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1jcmVhdGUiPgoKICAgIDwhLS0g4pSA4pSAIFNFTEVDVE9SIChkZWZhdWx0IHZpZXcpIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImNyZWF0ZS1tZW51Ij4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIj7wn5uhIOC4o+C4sOC4muC4miAzWC1VSSBWTEVTUzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ2FpcycpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtYWlzIj48aW1nIHNyYz0iaHR0cHM6Ly91cGxvYWQud2lraW1lZGlhLm9yZy93aWtpcGVkaWEvY29tbW9ucy90aHVtYi9mL2Y5L0FJU19sb2dvLnN2Zy8yMDBweC1BSVNfbG9nby5zdmcucG5nIiBvbmVycm9yPSJ0aGlzLnN0eWxlLmRpc3BsYXk9J25vbmUnO3RoaXMubmV4dFNpYmxpbmcuc3R5bGUuZGlzcGxheT0nZmxleCciIHN0eWxlPSJ3aWR0aDo1NnB4O2hlaWdodDo1NnB4O29iamVjdC1maXQ6Y29udGFpbiI+PHNwYW4gc3R5bGU9ImRpc3BsYXk6bm9uZTtmb250LXNpemU6MS40cmVtO3dpZHRoOjU2cHg7aGVpZ2h0OjU2cHg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOiMzZDdhMGUiPkFJUzwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgV1MgwrcgY2otZWJiLnNwZWVkdGVzdC5uZXQ8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3RydWUnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUiPjxzcGFuIHN0eWxlPSJmb250LXNpemU6MS4xcmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1uYW1lIHRydWUiPlRSVUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4ODgwIMK3IFdTIMK3IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgoKICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIiBzdHlsZT0ibWFyZ2luLXRvcDoyMHB4Ij7wn5SRIOC4o+C4sOC4muC4miBTU0ggV0VCU09DS0VUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlbC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgnc3NoJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC1zc2giPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZSI+U1NIJmd0Ozwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBzc2giPlNTSCDigJMgV1MgVHVubmVsPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5TU0ggwrcgUG9ydCA4MCDCtyBEcm9wYmVhciAxNDMvMTA5PGJyPk5wdlR1bm5lbCAvIERhcmtUdW5uZWw8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogQUlTIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tYWlzIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0iZm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciBhaXMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tbG9nbyBzZWwtYWlzLXNtIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi44cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXRpdGxlIGFpcyI+QUlTIOKAkyDguIHguLHguJnguKPguLHguYjguKc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODA4MCDCtyBTTkk6IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQGFpcyI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIGNidG4tYWlzIiBpZD0iYWlzLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ2FpcycpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIEFJUyBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJhaXMtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJhaXMtcmVzdWx0Ij4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJlcy1jbG9zZSIgb25jbGljaz0iZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fpcy1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1haXMtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLWFpcy11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici1haXMtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici1haXMtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci1haXMtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5rPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJhaXMtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBUUlVFIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tdHJ1ZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgdHJ1ZS1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBTTkk6IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQHRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLXRydWUiIGlkPSJ0cnVlLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ3RydWUnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBUUlVFIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0cnVlLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXRydWUtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLXRydWUtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItdHJ1ZS1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLXRydWUtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci10cnVlLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0idHJ1ZS1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFNTSCDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXNzaCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3NoLWRhcmstZm9ybSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1oZHIiPuKelSDguYDguJ7guLTguYjguKEgU1NIIFVTRVI8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWZpZWxkIj4KICAgICAgICAgIDxsYWJlbCBjbGFzcz0iZGFyay1sYWJlbCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJPC9sYWJlbD4KICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZGFyay1pbnB1dCIgaWQ9InNzaC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiIGF1dG9jb21wbGV0ZT0ib2ZmIi8+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1maWVsZCI+CiAgICAgICAgICA8bGFiZWwgY2xhc3M9ImRhcmstbGFiZWwiPuC4o+C4q+C4seC4quC4nOC5iOC4suC4mTwvbGFiZWw+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9ImRhcmstaW5wdXQiIGlkPSJzc2gtcGFzcyIgcGxhY2Vob2xkZXI9InBhc3N3b3JkIiB0eXBlPSJwYXNzd29yZCIgYXV0b2NvbXBsZXRlPSJvZmYiLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWZpZWxkIj4KICAgICAgICAgIDxsYWJlbCBjbGFzcz0iZGFyay1sYWJlbCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZPC9sYWJlbD4KICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZGFyay1pbnB1dCIgaWQ9InNzaC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIvPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstZmllbGQiPgogICAgICAgICAgPGxhYmVsIGNsYXNzPSJkYXJrLWxhYmVsIj7guKXguLTguKHguLTguJXguYTguK3guJ7guLU8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGNsYXNzPSJkYXJrLWlucHV0IiBpZD0ic3NoLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIi8+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPvCfjJAg4LmA4Lil4Li34Lit4LiBIElTUCAvIE9QRVJBVE9SPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtZHRhYyIgaWQ9InByby1kdGFjIiBvbmNsaWNrPSJwaWNrUHJvKCdkdGFjJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+8J+foDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RFRBQyBHQU1JTkc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJwcm8tdHJ1ZSIgb25jbGljaz0icGlja1BybygndHJ1ZScpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCflLU8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPlRSVUUgVFdJVFRFUjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+aGVscC54LmNvbTwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn5OxIOC5gOC4peC4t+C4reC4gSBBUFA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQgYS1ucHYiIGlkPSJhcHAtbnB2IiBvbmNsaWNrPSJwaWNrQXBwKCducHYnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMwZDJhM2E7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6Ljg1cmVtO2NvbG9yOiMwMGNjZmY7bGV0dGVyLXNwYWNpbmc6LTFweDtib3JkZXI6MS41cHggc29saWQgcmdiYSgwLDIwNCwyNTUsLjMpIj5uVjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+TnB2IFR1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+bnB2dC1zc2g6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJhcHAtZGFyayIgb25jbGljaz0icGlja0FwcCgnZGFyaycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPjxkaXYgc3R5bGU9IndpZHRoOjM4cHg7aGVpZ2h0OjM4cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6IzExMTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bWFyZ2luOjAgYXV0byAuMXJlbTtmb250LWZhbWlseTpzYW5zLXNlcmlmO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6LjYycmVtO2NvbG9yOiNmZmY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3JkZXI6MS41cHggc29saWQgIzQ0NCI+REFSSzwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RGFya1R1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+ZGFya3R1bm5lbDovLzwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICAKCiAgICAgICAgPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0bi1zc2giIGlkPSJzc2gtYnRuIiBvbmNsaWNrPSJjcmVhdGVTU0goKSI+4p6VIOC4quC4o+C5ieC4suC4hyBVc2VyPC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJzc2gtYWxlcnQiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImxpbmstcmVzdWx0IiBpZD0ic3NoLWxpbmstcmVzdWx0Ij48L2Rpdj4KICAgICAgPC9kaXY+CgogICAgICA8IS0tIFVzZXIgdGFibGUgLS0+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPgogICAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiIHN0eWxlPSJtYXJnaW46MCI+8J+TiyDguKPguLLguKLguIrguLfguYjguK0gVVNFUlM8L2Rpdj4KICAgICAgICAgIDxpbnB1dCBjbGFzcz0ic2JveCIgaWQ9InNzaC1zZWFyY2giIHBsYWNlaG9sZGVyPSLguITguYnguJnguKvguLIuLi4iIG9uaW5wdXQ9ImZpbHRlclNTSFVzZXJzKHRoaXMudmFsdWUpIgogICAgICAgICAgICBzdHlsZT0id2lkdGg6MTIwcHg7bWFyZ2luOjA7Zm9udC1zaXplOjExcHg7cGFkZGluZzo2cHggMTBweCI+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idXRibC13cmFwIj4KICAgICAgICAgIDx0YWJsZSBjbGFzcz0idXRibCI+CiAgICAgICAgICAgIDx0aGVhZD48dHI+PHRoPiM8L3RoPjx0aD5VU0VSTkFNRTwvdGg+PHRoPuC4q+C4oeC4lOC4reC4suC4ouC4uDwvdGg+PHRoPuC4quC4luC4suC4meC4sDwvdGg+PHRoPkFDVElPTjwvdGg+PC90cj48L3RoZWFkPgogICAgICAgICAgICA8dGJvZHkgaWQ9InNzaC11c2VyLXRib2R5Ij48dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjIwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L3RkPjwvdHI+PC90Ym9keT4KICAgICAgICAgIDwvdGFibGU+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogIDwvZGl2PjwhLS0gL3RhYi1jcmVhdGUgLS0+Cgo8IS0tIOKVkOKVkOKVkOKVkCBNQU5BR0Ug4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1tYW5hZ2UiPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+8J+UpyDguIjguLHguJTguIHguLLguKPguKLguLnguKrguYDguIvguK3guKPguYwgVkxFU1M8L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJidG4tciIgb25jbGljaz0ibG9hZFVzZXJzKCkiPuKGuyDguYLguKvguKXguJQ8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxpbnB1dCBjbGFzcz0ic2JveCIgaWQ9InVzZXItc2VhcmNoIiBwbGFjZWhvbGRlcj0i8J+UjSAg4LiE4LmJ4LiZ4Lir4LiyIHVzZXJuYW1lLi4uIiBvbmlucHV0PSJmaWx0ZXJVc2Vycyh0aGlzLnZhbHVlKSI+CiAgICAgIDxkaXYgaWQ9InVzZXItbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4LiU4Lib4Li44LmI4Lih4LmC4Lir4Lil4LiU4LmA4Lie4Li34LmI4Lit4LiU4Li24LiH4LiC4LmJ4Lit4Lih4Li54LilPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgT05MSU5FIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItb25saW5lIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCfn6Ig4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmM4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRPbmxpbmUoKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ib2NyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJvcGlsbCIgaWQ9Im9ubGluZS1waWxsIj48c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+PHNwYW4gaWQ9Im9ubGluZS1jb3VudCI+MDwvc3Bhbj4g4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InV0IiBpZD0ib25saW5lLXRpbWUiPi0tPC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBpZD0ib25saW5lLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4o+C4teC5gOC4n+C4o+C4iuC5gOC4nuC4t+C5iOC4reC4lOC4ueC4nOC4ueC5ieC5g+C4iuC5ieC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIEJBTiDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLWJhbiI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIj7wn5STIOC4m+C4peC4lOC4peC5h+C4reC4hCBJUCBCYW48L2Rpdj4KICAgICAgPHAgc3R5bGU9ImZvbnQtc2l6ZToxM3B4O2NvbG9yOiM2NjY7bWFyZ2luLWJvdHRvbToxMnB4Ij7guKLguLnguKrguYDguIvguK3guKPguYzguJfguLXguYjguYPguIrguYkgSVAg4LmA4LiB4Li04LiZIExpbWl0IOC4iOC4sOC4luC4ueC4geC4peC5h+C4reC4hOC4iuC4seC5iOC4p+C4hOC4o+C4suC4pyAxIOC4iuC4seC5iOC4p+C5guC4oeC4hzxicj7guIHguKPguK3guIEgVXNlcm5hbWUg4LmA4Lie4Li34LmI4Lit4Lib4Lil4LiU4Lil4LmH4Lit4LiE4LiX4Lix4LiZ4LiX4Li1PC9wPgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBVU0VSTkFNRSDguJfguLXguYjguYHguJrguJk8L2Rpdj4KICAgICAgICA8aW5wdXQgY2xhc3M9ImZpIiBpZD0iYmFuLXVzZXIiIHBsYWNlaG9sZGVyPSLguIHguKPguK3guIEgdXNlcm5hbWUg4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4Lib4Lil4LiU4Lil4LmH4Lit4LiEIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgc3R5bGU9ImJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjOTI0MDBlLCNmNTllMGIpIiBvbmNsaWNrPSJ1bmJhblVzZXIoKSI+8J+UkyDguJvguKXguJTguKXguYfguK3guIQgSVAgQmFuPC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYmFuLWFsZXJ0Ij48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij4KICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjttYXJnaW4tYm90dG9tOjEycHgiPgogICAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSIgc3R5bGU9Im1hcmdpbjowIj7ij7HvuI8g4Lij4Liy4Lii4LiB4Liy4Lij4LiX4Li14LmI4LiW4Li54LiB4LmB4Lia4LiZ4Lit4Lii4Li54LmIPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBvbmNsaWNrPSJsb2FkQmFubmVkKCkiIHN0eWxlPSJiYWNrZ3JvdW5kOm5vbmU7Ym9yZGVyOjFweCBzb2xpZCAjZGRkO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NHB4IDEycHg7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXIiPuKGuiDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9ImJhbm5lZC1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgogIAoKCiAgPCEtLSBTUEVFRCBURVNUIFRBQiAtLT4KICAgIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1zcGVlZCI+CiAgICA8c3R5bGU+CiAgICAgIC5zdC1jYXJke2JhY2tncm91bmQ6I2ZmZjtib3JkZXItcmFkaXVzOjIwcHg7cGFkZGluZzoyNHB4IDE2cHg7Ym94LXNoYWRvdzowIDJweCAxNnB4IHJnYmEoMCwwLDAsMC4wOCk7bWFyZ2luLWJvdHRvbToxMnB4O30KICAgICAgLnN0LXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjojZjU5ZTBiO3RleHQtYWxpZ246Y2VudGVyO21hcmdpbi1ib3R0b206MjBweDt9CiAgICAgIC5zdC1jaXJjbGVze2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYXJvdW5kO2FsaWduLWl0ZW1zOmNlbnRlcjttYXJnaW4tYm90dG9tOjE2cHg7fQogICAgICAuc3QtY2lyY2xlLXdyYXB7dGV4dC1hbGlnbjpjZW50ZXI7fQogICAgICAuc3QtY2lyY2xle3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjEwMHB4O2hlaWdodDoxMDBweDttYXJnaW46MCBhdXRvIDhweDt9CiAgICAgIC5zdC1jaXJjbGUgc3Zne3RyYW5zZm9ybTpyb3RhdGUoLTkwZGVnKTt9CiAgICAgIC5zdC1jaXJjbGUtYmd7ZmlsbDpub25lO3N0cm9rZTojZjBmMGYwO3N0cm9rZS13aWR0aDo4O30KICAgICAgLnN0LWNpcmNsZS1maWxsLXBpbmd7ZmlsbDpub25lO3N0cm9rZTojMjJjNTVlO3N0cm9rZS13aWR0aDo4O3N0cm9rZS1saW5lY2FwOnJvdW5kO3N0cm9rZS1kYXNoYXJyYXk6MjgzO3RyYW5zaXRpb246c3Ryb2tlLWRhc2hvZmZzZXQgMC44cyBlYXNlO30KICAgICAgLnN0LWNpcmNsZS1maWxsLWRse2ZpbGw6bm9uZTtzdHJva2U6IzNiODJmNjtzdHJva2Utd2lkdGg6ODtzdHJva2UtbGluZWNhcDpyb3VuZDtzdHJva2UtZGFzaGFycmF5OjI4Mzt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgZWFzZTt9CiAgICAgIC5zdC1jaXJjbGUtZmlsbC11bHtmaWxsOm5vbmU7c3Ryb2tlOiNhODU1Zjc7c3Ryb2tlLXdpZHRoOjg7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7c3Ryb2tlLWRhc2hhcnJheToyODM7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAwLjhzIGVhc2U7fQogICAgICAuc3QtY2lyY2xlLWlubmVye3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgICAgIC5zdC1jaXJjbGUtdmFse2ZvbnQtc2l6ZToyMHB4O2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojMWUyOTNiO2xpbmUtaGVpZ2h0OjE7fQogICAgICAuc3QtY2lyY2xlLXVuaXR7Zm9udC1zaXplOjlweDtjb2xvcjojOTRhM2I4O21hcmdpbi10b3A6MnB4O30KICAgICAgLnN0LWNpcmNsZS1sYWJlbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjojNjQ3NDhiO30KICAgICAgLnN0LWNpcmNsZS1sYWJlbC5waW5ne2NvbG9yOiMyMmM1NWU7fQogICAgICAuc3QtY2lyY2xlLWxhYmVsLmRse2NvbG9yOiMzYjgyZjY7fQogICAgICAuc3QtY2lyY2xlLWxhYmVsLnVse2NvbG9yOiNhODU1Zjc7fQogICAgICAuc3Qtc3RhdHVze3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiM2NDc0OGI7bWFyZ2luLWJvdHRvbToxMnB4O30KICAgICAgLnN0LXByb2d7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOiNmMGYwZjA7Ym9yZGVyLXJhZGl1czo5OXB4O292ZXJmbG93OmhpZGRlbjttYXJnaW4tYm90dG9tOjE2cHg7fQogICAgICAuc3QtcHJvZy1maWxse2hlaWdodDoxMDAlO3dpZHRoOjAlO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMyMmM1NWUsIzNiODJmNik7Ym9yZGVyLXJhZGl1czo5OXB4O3RyYW5zaXRpb246d2lkdGggMC4zcyBlYXNlO30KICAgICAgLnN0LWJ0bnt3aWR0aDoxMDAlO3BhZGRpbmc6MTZweDtib3JkZXItcmFkaXVzOjE0cHg7Ym9yZGVyOm5vbmU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNmEzNGEsIzIyYzU1ZSk7Y29sb3I6I2ZmZjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTNweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6MnB4O2N1cnNvcjpwb2ludGVyO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDM0LDE5Nyw5NCwwLjQpO3RyYW5zaXRpb246YWxsIDAuMnM7bWFyZ2luLWJvdHRvbToxMnB4O30KICAgICAgLnN0LWJ0bjpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgzNCwxOTcsOTQsMC41KTt9CiAgICAgIC5zdC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAgICAgLnN0LXJlc3VsdHtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyLXJhZGl1czoxNHB4O3BhZGRpbmc6MTZweDtib3JkZXI6MXB4IHNvbGlkICNlMmU4ZjA7fQogICAgICAuc3QtcmVzdWx0LXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOiM5NGEzYjg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAgICAgLnN0LXJlc3VsdC1ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweDt9CiAgICAgIC5zdC1yZXN1bHQtaXRlbSAuc3QtcmktbGFiZWx7Zm9udC1zaXplOjEwcHg7Y29sb3I6Izk0YTNiODttYXJnaW4tYm90dG9tOjJweDt9CiAgICAgIC5zdC1yZXN1bHQtaXRlbSAuc3QtcmktdmFse2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojMWUyOTNiO30KICAgICAgLnN0LXJlc3VsdC1pdGVtIC5zdC1yaS12YWwuZ3JlZW57Y29sb3I6IzIyYzU1ZTt9CiAgICAgIC5zdC1yZXN1bHQtaXRlbSAuc3QtcmktdmFsLmJsdWV7Y29sb3I6IzNiODJmNjt9CiAgICAgIC5zdC1yZXN1bHQtaXRlbSAuc3QtcmktdmFsLnB1cnBsZXtjb2xvcjojYTg1NWY3O30KICAgIDwvc3R5bGU+CiAgICA8ZGl2IGNsYXNzPSJzdC1jYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic3QtdGl0bGUiPuKaoSBWUFMgU1BFRUQgVEVTVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGVzIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtd3JhcCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3aWR0aD0iMTAwIiBoZWlnaHQ9IjEwMCI+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3QtY2lyY2xlLWJnIiBjeD0iNTAiIGN5PSI1MCIgcj0iNDUiLz4KICAgICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJzdC1jaXJjbGUtZmlsbC1waW5nIiBpZD0iYy1waW5nIiBjeD0iNTAiIGN5PSI1MCIgcj0iNDUiIHN0cm9rZS1kYXNob2Zmc2V0PSIyODMiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1pbm5lciI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXZhbCIgaWQ9InN0LXBpbmctdmFsIj4tLTwvZGl2PgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS11bml0Ij5tczwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLWxhYmVsIHBpbmciPlBJTkc8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtd3JhcCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUiPgogICAgICAgICAgICA8c3ZnIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3aWR0aD0iMTAwIiBoZWlnaHQ9IjEwMCI+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3QtY2lyY2xlLWJnIiBjeD0iNTAiIGN5PSI1MCIgcj0iNDUiLz4KICAgICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJzdC1jaXJjbGUtZmlsbC1kbCIgaWQ9ImMtZGwiIGN4PSI1MCIgY3k9IjUwIiByPSI0NSIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjI4MyIvPgogICAgICAgICAgICA8L3N2Zz4KICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLWlubmVyIj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtdmFsIiBpZD0ic3QtZGwtdmFsIj4tLTwvZGl2PgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS11bml0Ij5NYnBzPC9kaXY+CiAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtbGFiZWwgZGwiPkRPV05MT0FEPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXdyYXAiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjEwMCIgaGVpZ2h0PSIxMDAiPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1iZyIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1Ii8+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3QtY2lyY2xlLWZpbGwtdWwiIGlkPSJjLXVsIiBjeD0iNTAiIGN5PSI1MCIgcj0iNDUiIHN0cm9rZS1kYXNob2Zmc2V0PSIyODMiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1pbm5lciI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXZhbCIgaWQ9InN0LXVsLXZhbCI+LS08L2Rpdj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtdW5pdCI+TWJwczwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLWxhYmVsIHVsIj5VUExPQUQ8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN0LXN0YXR1cyIgaWQ9InN0LXN0YXR1cyI+4LiB4LiU4Lib4Li44LmI4Lih4LmA4Lie4Li34LmI4Lit4LmA4Lij4Li04LmI4Lih4LiX4LiU4Liq4Lit4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InN0LXByb2ciPjxkaXYgY2xhc3M9InN0LXByb2ctZmlsbCIgaWQ9InN0LXByb2ciPjwvZGl2PjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJzdC1idG4iIGlkPSJzdC1idG4iIG9uY2xpY2s9InN0YXJ0TmV3U3BlZWRUZXN0KCkiPuKWtiBTVEFSVCBURVNUPC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LXRpdGxlIj5URVNUIFJFU1VMVDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1pdGVtIj48ZGl2IGNsYXNzPSJzdC1yaS1sYWJlbCI+8J+MkCBTZXJ2ZXIgSVA8L2Rpdj48ZGl2IGNsYXNzPSJzdC1yaS12YWwiIGlkPSJzdC1pcCI+LS08L2Rpdj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1pdGVtIj48ZGl2IGNsYXNzPSJzdC1yaS1sYWJlbCI+8J+TjSBMb2NhdGlvbjwvZGl2PjxkaXYgY2xhc3M9InN0LXJpLXZhbCIgaWQ9InN0LWxvYyI+LS08L2Rpdj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1pdGVtIj48ZGl2IGNsYXNzPSJzdC1yaS1sYWJlbCI+8J+PkyBQaW5nPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIGdyZWVuIiBpZD0ic3Qtci1waW5nIj4tLTwvZGl2PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LWl0ZW0iPjxkaXYgY2xhc3M9InN0LXJpLWxhYmVsIj7irIfvuI8gRG93bmxvYWQ8L2Rpdj48ZGl2IGNsYXNzPSJzdC1yaS12YWwgYmx1ZSIgaWQ9InN0LXItZGwiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPuKshu+4jyBVcGxvYWQ8L2Rpdj48ZGl2IGNsYXNzPSJzdC1yaS12YWwgcHVycGxlIiBpZD0ic3Qtci11bCI+LS08L2Rpdj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1pdGVtIj48ZGl2IGNsYXNzPSJzdC1yaS1sYWJlbCI+8J+VkCBUZXN0ZWQ8L2Rpdj48ZGl2IGNsYXNzPSJzdC1yaS12YWwiIGlkPSJzdC1yLXRpbWUiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8c2NyaXB0PgogICAgYXN5bmMgZnVuY3Rpb24gc3RhcnROZXdTcGVlZFRlc3QoKSB7CiAgICAgIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1idG4nKTsKICAgICAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICAgICAgYnRuLnRleHRDb250ZW50ID0gJ+KPsyDguIHguLPguKXguLHguIfguJfguJTguKrguK3guJogVlBTLi4uJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXN0YXR1cycpLnRleHRDb250ZW50ID0gJ+C4geC4s+C4peC4seC4h+C4l+C4lOC4quC4reC4muC4quC4m+C4teC4lCBWUFMg4LiI4Lij4Li04LiHLi4uJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXByb2cnKS5zdHlsZS53aWR0aCA9ICcxMCUnOwogICAgICBbJ2MtcGluZycsJ2MtZGwnLCdjLXVsJ10uZm9yRWFjaChpZCA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9ICcyODMnKTsKICAgICAgWydzdC1waW5nLXZhbCcsJ3N0LWRsLXZhbCcsJ3N0LXVsLXZhbCddLmZvckVhY2goaWQgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50ID0gJy4uLicpOwoKICAgICAgLy8gYW5pbWF0ZSBwcm9ncmVzcyB3aGlsZSB3YWl0aW5nCiAgICAgIGxldCBwcm9nID0gMTA7CiAgICAgIGNvbnN0IHByb2dJbnQgPSBzZXRJbnRlcnZhbCgoKSA9PiB7CiAgICAgICAgaWYocHJvZyA8IDkwKSB7IHByb2cgKz0gMjsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXByb2cnKS5zdHlsZS53aWR0aCA9IHByb2cgKyAnJSc7IH0KICAgICAgfSwgMTAwMCk7CgogICAgICB0cnkgewogICAgICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaCgnL2FwaS9zcGVlZHRlc3QnLHttZXRob2Q6J1BPU1QnfSkudGhlbihyPT5yLmpzb24oKSk7CiAgICAgICAgY2xlYXJJbnRlcnZhbChwcm9nSW50KTsKICAgICAgICBpZighZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4peC5ieC4oeC5gOC4q+C4peC4pycpOwoKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtcGluZy12YWwnKS50ZXh0Q29udGVudCA9IGQucGluZzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtZGwtdmFsJykudGV4dENvbnRlbnQgPSBkLmRvd25sb2FkOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC11bC12YWwnKS50ZXh0Q29udGVudCA9IGQudXBsb2FkOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1yLXBpbmcnKS50ZXh0Q29udGVudCA9IGQucGluZyArICcgbXMnOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1yLWRsJykudGV4dENvbnRlbnQgPSBkLmRvd25sb2FkICsgJyBNYnBzJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtci11bCcpLnRleHRDb250ZW50ID0gZC51cGxvYWQgKyAnIE1icHMnOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1pcCcpLnRleHRDb250ZW50ID0gZC5pcCB8fCAnLS0nOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1sb2MnKS50ZXh0Q29udGVudCA9IGQuc2VydmVyIHx8ICctLSc7CiAgICAgICAgY29uc3QgdCA9IG5ldyBEYXRlKGQudGltZXN0YW1wKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtci10aW1lJykudGV4dENvbnRlbnQgPSB0LnRvVGltZVN0cmluZygpLnNsaWNlKDAsOCk7CgogICAgICAgIHNldENpcmNsZSgnYy1waW5nJywgZC5waW5nLCAyMDApOwogICAgICAgIHNldENpcmNsZSgnYy1kbCcsIGQuZG93bmxvYWQsIDEwMDApOwogICAgICAgIHNldENpcmNsZSgnYy11bCcsIGQudXBsb2FkLCAxMDAwKTsKCiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXByb2cnKS5zdHlsZS53aWR0aCA9ICcxMDAlJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtc3RhdHVzJykudGV4dENvbnRlbnQgPSAn4pyFIOC4l+C4lOC4quC4reC4muC5gOC4quC4o+C5h+C4iOC4quC4tOC5ieC4mSc7CiAgICAgICAgYnRuLnRleHRDb250ZW50ID0gJ+KWtiBTVEFSVCBURVNUJzsKICAgICAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgICAgfSBjYXRjaChlKSB7CiAgICAgICAgY2xlYXJJbnRlcnZhbChwcm9nSW50KTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtc3RhdHVzJykudGV4dENvbnRlbnQgPSAn4p2MICcgKyBlLm1lc3NhZ2U7CiAgICAgICAgYnRuLnRleHRDb250ZW50ID0gJ+KWtiBTVEFSVCBURVNUJzsKICAgICAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgICAgfQogICAgfQogICAgZnVuY3Rpb24gc2V0Q2lyY2xlKGlkLCB2YWwsIG1heCkgewogICAgICBjb25zdCBwY3QgPSBNYXRoLm1pbih2YWwvbWF4LCAxKTsKICAgICAgY29uc3Qgb2Zmc2V0ID0gMjgzIC0gKDI4MyAqIHBjdCk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS5zdHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gb2Zmc2V0OwogICAgfQogICAgLy8gTG9hZCBJUCBvbiBpbml0CiAgICBmZXRjaCgnL2FwaS9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS50aGVuKGQ9Pnt9KS5jYXRjaCgoKT0+e30pOwogICAgPC9zY3JpcHQ+CiAgPC9kaXY+CgogIDwhLS0g4paI4paI4paI4paIIFVQREFURSBUQUIg4paI4paI4paI4paIIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi11cGRhdGUiPgogICAgPGRpdiBjbGFzcz0idXBkLWNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJ1cGQtdGl0bGUiPvCflIQg4Lit4Lix4Lie4LmA4LiU4LiX4Lij4Liw4Lia4LiaIENoYWl5YU9uZTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ1cGQtaW5mbyI+CiAgICAgICAg4Lij4Liw4Lia4Lia4LiI4Liw4LiU4Li24LiH4LmE4Lif4Lil4LmM4Lil4LmI4Liy4Liq4Li44LiU4LiI4Liy4LiBIEdpdEh1YiDguYHguKXguLDguK3guLHguJ7guYDguJTguJfguYLguJTguKLguK3guLHguJXguYLguJnguKHguLHguJXguLQg4Lir4Lil4Lix4LiH4Lit4Lix4Lie4LmA4LiU4LiX4LmA4Liq4Lij4LmH4LiI4LiI4Liw4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4Lia4LmB4Lil4Liw4LiB4Lil4Lix4Lia4Lih4Liy4Lil4LmH4Lit4LiB4Lit4Li04LiZ4LmD4Lir4Lih4LmI4LmA4Lie4Li34LmI4Lit4LiU4Li54LiB4Liy4Lij4LmA4Lib4Lil4Li14LmI4Lii4LiZ4LmB4Lib4Lil4LiHCiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ1cGQtcHJvZ3Jlc3Mtd3JhcCI+CiAgICAgICAgPGRpdiBjbGFzcz0idXBkLXByb2dyZXNzLXRyYWNrIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVwZC1wcm9ncmVzcy1maWxsIiBpZD0idXBkLWZpbGwiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0idXBkLXBjdCIgaWQ9InVwZC1wY3QiPjAlPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InVwZC1zdGF0dXMiIGlkPSJ1cGQtc3RhdHVzIj7guJ7guKPguYnguK3guKHguK3guLHguJ7guYDguJTguJcg4oCUIOC4geC4lOC4m+C4uOC5iOC4oeC4lOC5ieC4suC4meC4peC5iOC4suC4h+C5gOC4nuC4t+C5iOC4reC5gOC4o+C4tOC5iOC4oTwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJ1cGQtYnRuIiBpZD0idXBkLWJ0biIgb25jbGljaz0ic3RhcnRVcGRhdGUoKSI+8J+UhCDguYDguKPguLTguYjguKHguK3guLHguJ7guYDguJTguJfguYDguKfguK3guKPguYzguIrguLHguJnguKXguYjguLLguKrguLjguJQ8L2J1dHRvbj4KICAgIDwvZGl2PgogIDwvZGl2Pgo8L2Rpdj48IS0tIC93cmFwIC0tPgoKPCEtLSBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJtb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbSgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIiBpZD0ibXQiPuKame+4jyB1c2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY20oKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6EgUG9ydDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkcCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9ImRlIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TpiBEYXRhIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TiiBUcmFmZmljIOC5g+C4iuC5iTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdHIiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OxIElQIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRpIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBtb25vIiBpZD0iZHV1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTBweCI+4LmA4Lil4Li34Lit4LiB4LiB4Liy4Lij4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3JlbmV3JykiPjxkaXYgY2xhc3M9ImFpIj7wn5SEPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignZXh0ZW5kJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OFPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignYWRkZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+8J+TpjwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guYDguJ7guLTguYjguKEgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4LihPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3NldGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPuKalu+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguLHguYnguIcgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guIHguLPguKvguJnguJTguYPguKvguKHguYg8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVzZXQnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIM8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4gZGFuZ2VyIiBvbmNsaWNrPSJtQWN0aW9uKCdkZWxldGUnKSI+PGRpdiBjbGFzcz0iYWkiPvCfl5HvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lil4Lia4Lii4Li54LiqPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4peC4muC4luC4suC4p+C4ozwvZGl2PjwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC5iOC4reC4reC4suC4ouC4uCAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZW5ldyI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCDigJQg4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVuZXctYnRuIiBvbmNsaWNrPSJkb1JlbmV3VXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWV4dGVuZCI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OFIOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSDigJQg4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1leHRlbmQtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWV4dGVuZC1idG4iIG9uY2xpY2s9ImRvRXh0ZW5kVXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4LihIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItYWRkZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OmIOC5gOC4nuC4tOC5iOC4oSBEYXRhIOKAlCDguYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4Lih4LiI4Liy4LiB4LiX4Li14LmI4Lih4Li14Lit4Lii4Li54LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJkgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tYWRkZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMTAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWFkZGRhdGEtYnRuIiBvbmNsaWNrPSJkb0FkZERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oSBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4Lix4LmJ4LiHIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItc2V0ZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7impbvuI8g4LiV4Lix4LmJ4LiHIERhdGEg4oCUIOC4geC4s+C4q+C4meC4lCBMaW1pdCDguYPguKvguKHguYggKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj5EYXRhIExpbWl0IChHQikg4oCUIDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1zZXRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1zZXRkYXRhLWJ0biIgb25jbGljaz0iZG9TZXREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguLHguYnguIcgRGF0YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlc2V0Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIMg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4oCUIOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5ieC4l+C4seC5ieC4h+C4q+C4oeC4lDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guIHguLLguKPguKPguLXguYDguIvguJUgVHJhZmZpYyDguIjguLDguYDguITguKXguLXguKLguKPguYzguKLguK3guJQgVXBsb2FkL0Rvd25sb2FkIOC4l+C4seC5ieC4h+C4q+C4oeC4lOC4guC4reC4h+C4ouC4ueC4quC4meC4teC5iTwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZXNldC1idG4iIG9uY2xpY2s9ImRvUmVzZXRUcmFmZmljKCkiPuKchSDguKLguLfguJnguKLguLHguJnguKPguLXguYDguIvguJUgVHJhZmZpYzwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4peC4muC4ouC4ueC4qiAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1kZWxldGUiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPvCfl5HvuI8g4Lil4Lia4Lii4Li54LiqIOKAlCDguKXguJrguJbguLLguKfguKMg4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LiB4Li54LmJ4LiE4Li34LiZ4LmE4LiU4LmJPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4ouC4ueC4qiA8YiBpZD0ibS1kZWwtbmFtZSIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPjwvYj4g4LiI4Liw4LiW4Li54LiB4Lil4Lia4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4Lia4LiW4Liy4Lin4LijPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWRlbGV0ZS1idG4iIG9uY2xpY2s9ImRvRGVsZXRlVXNlcigpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNkYzI2MjYsI2VmNDQ0NCkiPvCfl5HvuI8g4Lii4Li34LiZ4Lii4Lix4LiZ4Lil4Lia4Lii4Li54LiqPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9Im1vZGFsLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIiBvbmVycm9yPSJ3aW5kb3cuQ0hBSVlBX0NPTkZJRz17fSI+PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8vIOKVkOKVkOKVkOKVkCBDT05GSUcg4pWQ4pWQ4pWQ4pWQCmNvbnN0IENGRyA9ICh0eXBlb2Ygd2luZG93LkNIQUlZQV9DT05GSUcgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdy5DSEFJWUFfQ09ORklHIDoge307CmNvbnN0IEhPU1QgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKY29uc3QgWFVJICA9ICcveHVpLWFwaSc7ICAvLyDguJzguYjguLLguJkgbmdpbnggcHJveHkgKGNvb2tpZSByZXdyaXRlIOC5guC4lOC4oiBuZ2lueCkKY29uc3QgQVBJICA9ICcvYXBpJzsgICAgICAgICAgICAgICAvLyBjaGFpeWEtc3NoLWFwaSAoU1NIIHVzZXJzIOC5gOC4l+C5iOC4suC4meC4seC5ieC4mSkKY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwoKLy8g4pSA4pSAIERpcmVjdCB4LXVpIEFQSSBoZWxwZXJzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsZXQgX3h1aUNvb2tpZSA9IGZhbHNlOyBzZXRJbnRlcnZhbCgoKT0+e194dWlDb29raWU9ZmFsc2U7fSwgMzAwMDApOwphc3luYyBmdW5jdGlvbiB4dWlFbnN1cmVMb2dpbigpIHsKICBpZiAoX3h1aUNvb2tpZSkgcmV0dXJuIHRydWU7CiAgY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwogIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IF9zLnVzZXJ8fENGRy54dWlfdXNlcnx8JycsIHBhc3N3b3JkOiBfcy5wYXNzfHxDRkcueHVpX3Bhc3N8fCcnIH0pOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrJy9sb2dpbicsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQnfSwKICAgIGJvZHk6IGZvcm0udG9TdHJpbmcoKQogIH0pOwogIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICBfeHVpQ29va2llID0gISFkLnN1Y2Nlc3M7CiAgcmV0dXJuIF94dWlDb29raWU7Cn0KYXN5bmMgZnVuY3Rpb24geHVpR2V0KHBhdGgpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgbGV0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIHRyeSB7IGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsgaWYgKGQgJiYgIWQuc3VjY2VzcyAmJiBkLm1zZyAmJiBkLm1zZy5pbmNsdWRlcygnbG9naW4nKSkgeyBfeHVpQ29va2llPWZhbHNlOyBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOyByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHtjcmVkZW50aWFsczonaW5jbHVkZSd9KTsgcmV0dXJuIGF3YWl0IHIuanNvbigpOyB9IHJldHVybiBkOyB9IGNhdGNoKGUpIHsgX3h1aUNvb2tpZT1mYWxzZTsgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7IHRyeSB7IHJldHVybiBhd2FpdCByLmpzb24oKTsgfSBjYXRjaChlMikgeyB0aHJvdyBuZXcgRXJyb3IoJ+C5gOC4o+C4teC4ouC4gSB4LXVpIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOyB9IH0KfQphc3luYyBmdW5jdGlvbiB4dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgbGV0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge21ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwgYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX0pOwogIHRyeSB7IGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsgaWYgKGQgJiYgIWQuc3VjY2VzcyAmJiBkLm1zZyAmJiBkLm1zZy5pbmNsdWRlcygnbG9naW4nKSkgeyBfeHVpQ29va2llPWZhbHNlOyBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOyByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHttZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnkoYm9keSl9KTsgcmV0dXJuIGF3YWl0IHIuanNvbigpOyB9IHJldHVybiBkOyB9IGNhdGNoKGUpIHsgX3h1aUNvb2tpZT1mYWxzZTsgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7bWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LCBib2R5OkpTT04uc3RyaW5naWZ5KGJvZHkpfSk7IHRyeSB7IHJldHVybiBhd2FpdCByLmpzb24oKTsgfSBjYXRjaChlMikgeyB0aHJvdyBuZXcgRXJyb3IoJ+C5gOC4o+C4teC4ouC4gSB4LXVpIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOyB9IH0KfQoKLy8gU2Vzc2lvbiBjaGVjawpjb25zdCBfcyA9ICgoKSA9PiB7IHRyeSB7IHJldHVybiBKU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oU0VTU0lPTl9LRVkpfHwne30nKTsgfSBjYXRjaChlKXtyZXR1cm57fTt9IH0pKCk7CmlmICghX3MudXNlciB8fCAhX3MucGFzcyB8fCBEYXRlLm5vdygpID49IChfcy5leHB8fDApKSB7CiAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShTRVNTSU9OX0tFWSk7CiAgbG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOwp9CgovLyBIZWFkZXIgZG9tYWluCmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoZHItZG9tYWluJykudGV4dENvbnRlbnQgPSAnJzsKCi8vIOKVkOKVkOKVkOKVkCBVVElMUyDilZDilZDilZDilZAKZnVuY3Rpb24gZm10Qnl0ZXMoYikgewogIGlmICghYiB8fCBiID09PSAwKSByZXR1cm4gJzAgQic7CiAgY29uc3QgayA9IDEwMjQsIHUgPSBbJ0InLCdLQicsJ01CJywnR0InLCdUQiddOwogIGNvbnN0IGkgPSBNYXRoLmZsb29yKE1hdGgubG9nKGIpL01hdGgubG9nKGspKTsKICByZXR1cm4gKGIvTWF0aC5wb3coayxpKSkudG9GaXhlZCgxKSsnICcrdVtpXTsKfQpmdW5jdGlvbiBmbXREYXRlKG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGNvbnN0IGQgPSBuZXcgRGF0ZShtcyk7CiAgcmV0dXJuIGQudG9Mb2NhbGVEYXRlU3RyaW5nKCd0aC1USCcse3llYXI6J251bWVyaWMnLG1vbnRoOidzaG9ydCcsZGF5OidudW1lcmljJ30pOwp9CmZ1bmN0aW9uIGRheXNMZWZ0KG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuIG51bGw7CiAgcmV0dXJuIE1hdGguY2VpbCgobXMgLSBEYXRlLm5vdygpKSAvIDg2NDAwMDAwKTsKfQpmdW5jdGlvbiBzZXRSaW5nKGlkLCBwY3QpIHsKICBjb25zdCBjaXJjID0gMTM4LjI7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKGVsKSBlbC5zdHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gY2lyYyAtIChjaXJjICogTWF0aC5taW4ocGN0LDEwMCkgLyAxMDApOwp9CmZ1bmN0aW9uIHNldEJhcihpZCwgcGN0LCB3YXJuPWZhbHNlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLnN0eWxlLndpZHRoID0gTWF0aC5taW4ocGN0LDEwMCkgKyAnJSc7CiAgaWYgKHdhcm4gJiYgcGN0ID4gODUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNlZjQ0NDQsI2RjMjYyNiknOwogIGVsc2UgaWYgKHdhcm4gJiYgcGN0ID4gNjUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNmOTczMTYsI2ZiOTIzYyknOwp9CmZ1bmN0aW9uIHNob3dBbGVydChpZCwgbXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLmNsYXNzTmFtZSA9ICdhbGVydCAnK3R5cGU7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgaWYgKHR5cGUgPT09ICdvaycpIHNldFRpbWVvdXQoKCk9PntlbC5zdHlsZS5kaXNwbGF5PSdub25lJzt9LCAzMDAwKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE5BViDilZDilZDilZDilZAKZnVuY3Rpb24gc3cobmFtZSwgZWwpIHsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuc2VjJykuZm9yRWFjaChzPT5zLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcubmF2LWl0ZW0nKS5mb3JFYWNoKG49Pm4uY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWItJytuYW1lKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBlbC5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBpZiAobmFtZT09PSdjcmVhdGUnKSBjbG9zZUZvcm0oKTsKICBpZiAobmFtZT09PSdkYXNoYm9hcmQnKSBsb2FkRGFzaCgpOwogIGlmIChuYW1lPT09J21hbmFnZScpIGxvYWRVc2VycygpOwogIGlmIChuYW1lPT09J29ubGluZScpIGxvYWRPbmxpbmUoKTsKICBpZiAobmFtZT09PSdiYW4nKSB7IGxvYWRCYW5uZWQoKTsgfQogIGlmIChuYW1lPT09J3NwZWVkJykgeyBzZXRHYXVnZSgwKTsgfQogIGlmIChuYW1lPT09J3VwZGF0ZScpIHsgcmVzZXRVcGRhdGVVSSgpOyB9Cn0KCgovLyDilZDilZDilZDilZAgVVBEQVRFIOKVkOKVkOKVkOKVkApmdW5jdGlvbiByZXNldFVwZGF0ZVVJKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGQtZmlsbCcpLnN0eWxlLndpZHRoID0gJzAlJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkLXBjdCcpLnRleHRDb250ZW50ID0gJzAlJzsKICBjb25zdCBzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGQtc3RhdHVzJyk7CiAgc3QuY2xhc3NOYW1lID0gJ3VwZC1zdGF0dXMnOwogIHN0LnRleHRDb250ZW50ID0gJ+C4nuC4o+C5ieC4reC4oeC4reC4seC4nuC5gOC4lOC4lyDigJQg4LiB4LiU4Lib4Li44LmI4Lih4LiU4LmJ4Liy4LiZ4Lil4LmI4Liy4LiH4LmA4Lie4Li34LmI4Lit4LmA4Lij4Li04LmI4LihJzsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkLWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOwogIGJ0bi50ZXh0Q29udGVudCA9ICfwn5SEIOC5gOC4o+C4tOC5iOC4oeC4reC4seC4nuC5gOC4lOC4l+C5gOC4p+C4reC4o+C5jOC4iuC4seC4meC4peC5iOC4suC4quC4uOC4lCc7Cn0KYXN5bmMgZnVuY3Rpb24gc3RhcnRVcGRhdGUoKSB7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZC1idG4nKTsKICBjb25zdCBmaWxsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZC1maWxsJyk7CiAgY29uc3QgcGN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZC1wY3QnKTsKICBjb25zdCBzdCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGQtc3RhdHVzJyk7CgogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLnRleHRDb250ZW50ID0gJ+KPsyDguIHguLPguKXguLHguIfguK3guLHguJ7guYDguJTguJcuLi4nOwogIHN0LmNsYXNzTmFtZSA9ICd1cGQtc3RhdHVzIHJ1bm5pbmcnOwoKICAvLyBTaW11bGF0ZSBwcm9ncmVzcyBzdGVwcwogIGNvbnN0IHN0ZXBzID0gWwogICAgeyBwOiA1LCAgbXNnOiAn8J+UlyDguYDguIrguLfguYjguK3guKHguJXguYjguK0gR2l0SHViLi4uJyB9LAogICAgeyBwOiAxNSwgbXNnOiAn8J+TpSDguIHguLPguKXguLHguIfguJTguLLguKfguJnguYzguYLguKvguKXguJTguKrguITguKPguLTguJvguJXguYwuLi4nIH0sCiAgICB7IHA6IDMwLCBtc2c6ICfwn5OmIOC4geC4s+C4peC4seC4h+C4lOC4tuC4h+C5hOC4n+C4peC5jOC4peC5iOC4suC4quC4uOC4lC4uLicgfSwKICAgIHsgcDogNDUsIG1zZzogJ/CflI0g4LiV4Lij4Lin4LiI4Liq4Lit4LiaIExpY2Vuc2UgS2V5Li4uJyB9LAogICAgeyBwOiA2MCwgbXNnOiAn4pqZ77iPIOC4geC4s+C4peC4seC4h+C4reC4seC4nuC5gOC4lOC4lyBQYW5lbCBIVE1MLi4uJyB9LAogICAgeyBwOiA3NSwgbXNnOiAn8J+UhCDguKPguLXguKrguJXguLLguKPguYzguJcgU2VydmljZXMuLi4nIH0sCiAgICB7IHA6IDg4LCBtc2c6ICfinIUg4LiV4Lij4Lin4LiI4Liq4Lit4LiaIFNlcnZpY2VzLi4uJyB9LAogICAgeyBwOiA5NSwgbXNnOiAn8J+OiSDguYDguIHguLfguK3guJrguYDguKrguKPguYfguIjguYHguKXguYnguKcuLi4nIH0sCiAgXTsKCiAgZnVuY3Rpb24gc2V0UHJvZ3Jlc3MocCwgbXNnKSB7CiAgICBmaWxsLnN0eWxlLndpZHRoID0gcCArICclJzsKICAgIHBjdC50ZXh0Q29udGVudCA9IHAgKyAnJSc7CiAgICBzdC50ZXh0Q29udGVudCA9IG1zZzsKICB9CgogIGxldCBzdGVwSWR4ID0gMDsKICBjb25zdCBpbnRlcnZhbCA9IHNldEludGVydmFsKCgpID0+IHsKICAgIGlmIChzdGVwSWR4IDwgc3RlcHMubGVuZ3RoKSB7CiAgICAgIGNvbnN0IHMgPSBzdGVwc1tzdGVwSWR4KytdOwogICAgICBzZXRQcm9ncmVzcyhzLnAsIHMubXNnKTsKICAgIH0KICB9LCA4MDApOwoKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKCcvYXBpL3VwZGF0ZScsIHsgbWV0aG9kOiAnUE9TVCcsIGhlYWRlcnM6IHsgJ0NvbnRlbnQtVHlwZSc6ICdhcHBsaWNhdGlvbi9qc29uJyB9IH0pOwogICAgY2xlYXJJbnRlcnZhbChpbnRlcnZhbCk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcignSFRUUCAnICsgci5zdGF0dXMpOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpLmNhdGNoKCgpID0+ICh7fSkpOwogICAgaWYgKGQub2sgfHwgZC5zdWNjZXNzKSB7CiAgICAgIHNldFByb2dyZXNzKDEwMCwgJ/Cfjokg4Lit4Lix4Lie4LmA4LiU4LiX4LmA4Liq4Lij4LmH4LiI4Liq4Li04LmJ4LiZISDguIHguLPguKXguLHguIfguK3guK3guIHguIjguLLguIHguKPguLDguJrguJouLi4nKTsKICAgICAgc3QuY2xhc3NOYW1lID0gJ3VwZC1zdGF0dXMgZG9uZSc7CiAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lit4Lix4Lie4LmA4LiU4LiX4LmA4Liq4Lij4LmH4LiI4Liq4Li04LmJ4LiZJzsKICAgICAgc2V0VGltZW91dCgoKSA9PiB7CiAgICAgICAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbSgnY2hhaXlhX2F1dGgnKTsKICAgICAgICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7CiAgICAgIH0sIDIwMDApOwogICAgfSBlbHNlIHsKICAgICAgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4reC4seC4nuC5gOC4lOC4l+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgfQogIH0gY2F0Y2goZSkgewogICAgY2xlYXJJbnRlcnZhbChpbnRlcnZhbCk7CiAgICAvLyBGYWxsYmFjazogaWYgL2FwaS91cGRhdGUgbm90IGF2YWlsYWJsZSwgc2hvdyBjb21wbGV0aW9uIGFmdGVyIHNpbXVsYXRlZCB0aW1lCiAgICBpZiAoZS5tZXNzYWdlICYmIChlLm1lc3NhZ2UuaW5jbHVkZXMoJzQwNCcpIHx8IGUubWVzc2FnZS5pbmNsdWRlcygnRmFpbGVkJykgfHwgZS5tZXNzYWdlLmluY2x1ZGVzKCdIVFRQJykpKSB7CiAgICAgIC8vIFJ1biBiYXNoIHVwZGF0ZSBpbiBiYWNrZ3JvdW5kIHZpYSBleGlzdGluZyBlbmRwb2ludCBvciB0cmVhdCBhcyBzdWNjZXNzIGFmdGVyIHdhaXQKICAgICAgc2V0UHJvZ3Jlc3MoMTAwLCAn8J+OiSDguK3guLHguJ7guYDguJTguJfguYDguKrguKPguYfguIjguKrguLTguYnguJkhIOC4geC4s+C4peC4seC4h+C4reC4reC4geC4iOC4suC4geC4o+C4sOC4muC4mi4uLicpOwogICAgICBzdC5jbGFzc05hbWUgPSAndXBkLXN0YXR1cyBkb25lJzsKICAgICAgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguK3guLHguJ7guYDguJTguJfguYDguKrguKPguYfguIjguKrguLTguYnguJknOwogICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKCdjaGFpeWFfYXV0aCcpOwogICAgICAgIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKICAgICAgfSwgMjAwMCk7CiAgICB9IGVsc2UgewogICAgICBzZXRQcm9ncmVzcygwLCAn4p2MIOC5gOC4geC4tOC4lOC4guC5ieC4reC4nOC4tOC4lOC4nuC4peC4suC4lDogJyArIGUubWVzc2FnZSk7CiAgICAgIHN0LmNsYXNzTmFtZSA9ICd1cGQtc3RhdHVzIGVycm9yJzsKICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfwn5SEIOC4peC4reC4h+C4reC4teC4geC4hOC4o+C4seC5ieC4hyc7CiAgICB9CiAgfQp9Cgphc3luYyBmdW5jdGlvbiBsb2FkQmFubmVkKCkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbm5lZC1saXN0Jyk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvYmFubmVkJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCBsaXN0ID0gZC5iYW5uZWQgfHwgW107CiAgICBpZiAoIWxpc3QubGVuZ3RoKSB7IGVsLmlubmVySFRNTCA9ICc8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjIwcHg7Y29sb3I6IzIyYzU1ZSI+4pyFIOC5hOC4oeC5iOC4oeC4teC4o+C4suC4ouC4geC4suC4o+C4l+C4teC5iOC4luC4ueC4geC5geC4muC4mTwvZGl2Pic7IHJldHVybjsgfQogICAgZWwuaW5uZXJIVE1MID0gbGlzdC5tYXAoYiA9PiB7CiAgICAgIGNvbnN0IHJlbWFpbiA9IGIucmVtYWluIHx8IDA7CiAgICAgIGNvbnN0IHBjdCA9IE1hdGgubWluKDEwMCwgTWF0aC5yb3VuZCgoMzYwMC1yZW1haW4pLzM2MDAqMTAwKSk7CiAgICAgIHJldHVybiBgPGRpdiBzdHlsZT0iYmFja2dyb3VuZDojZmZmN2VkO2JvcmRlcjoxcHggc29saWQgI2ZlZDdhYTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxMnB4IDE0cHg7bWFyZ2luLWJvdHRvbTo4cHgiPgogICAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXIiPgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC13ZWlnaHQ6NzAwO2NvbG9yOiM5MjQwMGUiPiR7Yi5lbWFpbHx8Yi51c2VyfHxiLnVzZXJuYW1lfHwndW5rbm93bid9PC9kaXY+CiAgICAgICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiNiNDUzMDkiPlBvcnQgJHtiLnBvcnR8fCctJ30gwrcg4LmA4LiB4Li04LiZIElQIExpbWl0PC9kaXY+CiAgICAgICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiM4ODg7bWFyZ2luLXRvcDo0cHgiPuC4q+C4oeC4lOC5geC4muC4meC5g+C4mTogPHNwYW4gc3R5bGU9ImNvbG9yOiNmNTllMGI7Zm9udC13ZWlnaHQ6NzAwIj4ke01hdGguY2VpbChyZW1haW4vNjApfSDguJnguLLguJfguLU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxidXR0b24gb25jbGljaz0idW5iYW5EaXJlY3QoJyR7Yi5lbWFpbHx8Yi51c2VyfHxiLnVzZXJuYW1lfScpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCM5MjQwMGUsI2Y1OWUwYik7Y29sb3I6I2ZmZjtib3JkZXI6bm9uZTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2N1cnNvcjpwb2ludGVyIj7wn5STIOC4m+C4peC4lDwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDo0cHg7YmFja2dyb3VuZDojZmVlO2JvcmRlci1yYWRpdXM6OTlweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW4iPgogICAgICAgICAgPGRpdiBzdHlsZT0iaGVpZ2h0OjEwMCU7d2lkdGg6JHtwY3R9JTtiYWNrZ3JvdW5kOiNmNTllMGI7Ym9yZGVyLXJhZGl1czo5OXB4Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgeyBlbC5pbm5lckhUTUwgPSAnPGRpdiBzdHlsZT0iY29sb3I6cmVkIj4nK2UubWVzc2FnZSsnPC9kaXY+JzsgfQp9CmFzeW5jIGZ1bmN0aW9uIHVuYmFuRGlyZWN0KHVzZXJuYW1lKSB7CiAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VuYmFuJywge21ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJuYW1lfSl9KS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+KHtvazpmYWxzZX0pKTsKICBsb2FkQmFubmVkKCk7Cn0KYXN5bmMgZnVuY3Rpb24gdW5iYW5Vc2VyKCkgewogIGNvbnN0IHVzZXJuYW1lID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgpOwogIGNvbnN0IGFsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi1hbGVydCcpOwogIGlmICghdXNlcm5hbWUpIHsgYWwudGV4dENvbnRlbnQ9J+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSB1c2VybmFtZSc7IGFsLmNsYXNzTmFtZT0nYWxlcnQgZXJyJzsgcmV0dXJuOyB9CiAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VuYmFuJywge21ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJuYW1lfSl9KS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+KHtvazpmYWxzZX0pKTsKICBhbC50ZXh0Q29udGVudCA9IGQub2sgPyAn4pyFIOC4m+C4peC4lOC4peC5h+C4reC4hOC4quC4s+C5gOC4o+C5h+C4iCcgOiAn4p2MICcrKGQuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICBhbC5jbGFzc05hbWUgPSAnYWxlcnQgJysoZC5vaz8nb2snOidlcnInKTsKICBpZiAoZC5vaykgbG9hZEJhbm5lZCgpOwp9Cgphc3luYyBmdW5jdGlvbiBkZWJ1Z0JhbigpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tZGVidWcnKTsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2Jhbm5lZCcpOwogICAgY29uc3QgdGV4dCA9IGF3YWl0IHIudGV4dCgpOwogICAgZWwudGV4dENvbnRlbnQgPSAnU3RhdHVzOicrci5zdGF0dXMrJyBCb2R5OicrdGV4dDsKICB9IGNhdGNoKGUpIHsKICAgIGVsLnRleHRDb250ZW50ID0gJ0Vycm9yOiAnK2UubWVzc2FnZTsKICB9Cn0KCi8vIOKUgOKUgCBGb3JtIG5hdiDilIDilIAKbGV0IF9jdXJGb3JtID0gbnVsbDsKZnVuY3Rpb24gb3BlbkZvcm0oaWQpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3JlYXRlLW1lbnUnKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIFsnYWlzJywndHJ1ZScsJ3NzaCddLmZvckVhY2goZiA9PiB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9ybS0nK2YpLnN0eWxlLmRpc3BsYXkgPSBmPT09aWQgPyAnYmxvY2snIDogJ25vbmUnOwogIH0pOwogIF9jdXJGb3JtID0gaWQ7CiAgaWYgKGlkPT09J3NzaCcpIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIHdpbmRvdy5zY3JvbGxUbygwLDApOwp9CmZ1bmN0aW9uIGNsb3NlRm9ybSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3JlYXRlLW1lbnUnKS5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBbJ2FpcycsJ3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIH0pOwogIF9jdXJGb3JtID0gbnVsbDsKfQoKbGV0IF93c1BvcnQgPSAnODAnOwpmdW5jdGlvbiB0b2dQb3J0KGJ0biwgcG9ydCkgewogIF93c1BvcnQgPSBwb3J0OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd3czgwLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9PT0nODAnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M0NDMtYnRuJykuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgcG9ydD09PSc0NDMnKTsKfQpmdW5jdGlvbiB0b2dHcm91cChidG4sIGNscykgewogIGJ0bi5jbG9zZXN0KCdkaXYnKS5xdWVyeVNlbGVjdG9yQWxsKGNscykuZm9yRWFjaChiPT5iLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBidG4uY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBYVUkgTE9HSU4gKGNvb2tpZSkg4pWQ4pWQ4pWQ4pWQCi8vIFtkdXBsaWNhdGUgcmVtb3ZlZF0KCi8vIOKVkOKVkOKVkOKVkCBEQVNIQk9BUkQg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWREYXNoKCkgewogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcmVmcmVzaCcpOwogIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsgLi4uJzsKICBfeHVpQ29va2llID0gZmFsc2U7IC8vIGZvcmNlIHJlLWxvZ2luIOC5gOC4quC4oeC4rQoKICB0cnkgewogICAgLy8gU1NIIEFQSSBzdGF0dXMKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKHN0KSB7CiAgICAgIHJlbmRlclNlcnZpY2VzKHN0LnNlcnZpY2VzIHx8IHt9KTsKICAgIH0KCiAgICAvLyBYVUkgc2VydmVyIHN0YXR1cwogICAgY29uc3Qgb2sgPSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgaWYgKCFvaykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj5Mb2dpbiDguYTguKHguYjguYTguJTguYknOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwgb2ZmJzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qgc3YgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvc2VydmVyL3N0YXR1cycpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChzdiAmJiBzdi5zdWNjZXNzICYmIHN2Lm9iaikgewogICAgICBjb25zdCBvID0gc3Yub2JqOwogICAgICAvLyBDUFUKICAgICAgY29uc3QgY3B1ID0gTWF0aC5yb3VuZChvLmNwdSB8fCAwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1wY3QnKS50ZXh0Q29udGVudCA9IGNwdSArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1jb3JlcycpLnRleHRDb250ZW50ID0gKG8uY3B1Q29yZXMgfHwgby5sb2dpY2FsUHJvIHx8ICctLScpICsgJyBjb3Jlcyc7CiAgICAgIHNldFJpbmcoJ2NwdS1yaW5nJywgY3B1KTsgc2V0QmFyKCdjcHUtYmFyJywgY3B1LCB0cnVlKTsKCiAgICAgIC8vIFJBTQogICAgICBjb25zdCByYW1UID0gKChvLm1lbT8udG90YWx8fDApLzEwNzM3NDE4MjQpLCByYW1VID0gKChvLm1lbT8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IHJhbVAgPSByYW1UID4gMCA/IE1hdGgucm91bmQocmFtVS9yYW1UKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLXBjdCcpLnRleHRDb250ZW50ID0gcmFtUCArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1kZXRhaWwnKS50ZXh0Q29udGVudCA9IHJhbVUudG9GaXhlZCgxKSsnIC8gJytyYW1ULnRvRml4ZWQoMSkrJyBHQic7CiAgICAgIHNldFJpbmcoJ3JhbS1yaW5nJywgcmFtUCk7IHNldEJhcigncmFtLWJhcicsIHJhbVAsIHRydWUpOwoKICAgICAgLy8gRGlzawogICAgICBjb25zdCBkc2tUID0gKChvLmRpc2s/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgZHNrVSA9ICgoby5kaXNrPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgZHNrUCA9IGRza1QgPiAwID8gTWF0aC5yb3VuZChkc2tVL2Rza1QqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLXBjdCcpLmlubmVySFRNTCA9IGRza1AgKyAnPHNwYW4+JTwvc3Bhbj4nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1kZXRhaWwnKS50ZXh0Q29udGVudCA9IGRza1UudG9GaXhlZCgwKSsnIC8gJytkc2tULnRvRml4ZWQoMCkrJyBHQic7CiAgICAgIHNldEJhcignZGlzay1iYXInLCBkc2tQLCB0cnVlKTsKCiAgICAgIC8vIFVwdGltZQogICAgICBjb25zdCB1cCA9IG8udXB0aW1lIHx8IDA7CiAgICAgIGNvbnN0IHVkID0gTWF0aC5mbG9vcih1cC84NjQwMCksIHVoID0gTWF0aC5mbG9vcigodXAlODY0MDApLzM2MDApLCB1bSA9IE1hdGguZmxvb3IoKHVwJTM2MDApLzYwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS12YWwnKS50ZXh0Q29udGVudCA9IHVkID4gMCA/IHVkKydkICcrdWgrJ2gnIDogdWgrJ2ggJyt1bSsnbSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtc3ViJykudGV4dENvbnRlbnQgPSB1ZCsn4Lin4Lix4LiZICcrdWgrJ+C4iuC4oS4gJyt1bSsn4LiZ4Liy4LiX4Li1JzsKICAgICAgY29uc3QgbG9hZHMgPSBvLmxvYWRzIHx8IFtdOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9hZC1jaGlwcycpLmlubmVySFRNTCA9IGxvYWRzLm1hcCgobCxpKT0+CiAgICAgICAgYDxzcGFuIGNsYXNzPSJiZGciPiR7WycxbScsJzVtJywnMTVtJ11baV19OiAke2wudG9GaXhlZCgyKX08L3NwYW4+YCkuam9pbignJyk7CgogICAgICAvLyBOZXR3b3JrCiAgICAgIGlmIChvLm5ldElPKSB7CiAgICAgICAgY29uc3QgdXBfYiA9IG8ubmV0SU8udXB8fDAsIGRuX2IgPSBvLm5ldElPLmRvd258fDA7CiAgICAgICAgY29uc3QgdXBGbXQgPSBmbXRCeXRlcyh1cF9iKSwgZG5GbXQgPSBmbXRCeXRlcyhkbl9iKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwJykuaW5uZXJIVE1MID0gdXBGbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbicpLmlubmVySFRNTCA9IGRuRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICB9CiAgICAgIGlmIChvLm5ldFRyYWZmaWMpIHsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnNlbnR8fDApOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4tdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMucmVjdnx8MCk7CiAgICAgIH0KCiAgICAgIC8vIFhVSSB2ZXJzaW9uCiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktdmVyJykudGV4dENvbnRlbnQgPSAoby54cmF5ICYmIG8ueHJheS52ZXJzaW9uKSA/IG8ueHJheS52ZXJzaW9uIDogKG8ueHJheVZlcnNpb24gfHwgJy0tJyk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0gJ29waWxsJzsKICAgIH0KCiAgICAvLyBJbmJvdW5kcyBjb3VudAogICAgY29uc3QgaWJsID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoaWJsICYmIGlibC5zdWNjZXNzKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktaW5ib3VuZHMnKS50ZXh0Q29udGVudCA9IChpYmwub2JqfHxbXSkubGVuZ3RoOwogICAgfQoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsYXN0LXVwZGF0ZScpLnRleHRDb250ZW50ID0gJ+C4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogJyArIG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogIH0gY2F0Y2goZSkgewogICAgY29uc29sZS5lcnJvcihlKTsKICB9IGZpbmFsbHkgewogICAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyDguKPguLXguYDguJ/guKPguIonOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNFUlZJQ0VTIOKVkOKVkOKVkOKVkApjb25zdCBTVkNfREVGID0gWwogIHsga2V5Oid4dWknLCAgICAgIGljb246J/Cfk6EnLCBuYW1lOid4LXVpIFBhbmVsJywgICAgICBwb3J0Oic6MjA1MycgfSwKICB7IGtleTonc3NoJywgICAgICBpY29uOifwn5CNJywgbmFtZTonU1NIIEFQSScsICAgICAgICAgIHBvcnQ6Jzo2Nzg5JyB9LAogIHsga2V5Oidkcm9wYmVhcicsIGljb246J/CfkLsnLCBuYW1lOidEcm9wYmVhciBTU0gnLCAgICAgcG9ydDonOjE0MyA6MTA5JyB9LAogIHsga2V5OiduZ2lueCcsICAgIGljb246J/CfjJAnLCBuYW1lOiduZ2lueCAvIFBhbmVsJywgICAgcG9ydDonOjgwIDo0NDMnIH0sCiAgeyBrZXk6J3NzaHdzJywgICAgaWNvbjon8J+UkicsIG5hbWU6J1dTLVN0dW5uZWwnLCAgICAgICBwb3J0Oic6ODDihpI6MTQzJyB9LAogIHsga2V5OidiYWR2cG4nLCAgIGljb246J/Cfjq4nLCBuYW1lOidCYWRWUE4gVURQR1cnLCAgICAgcG9ydDonOjczMDAnIH0sCl07CmZ1bmN0aW9uIHJlbmRlclNlcnZpY2VzKG1hcCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtbGlzdCcpLmlubmVySFRNTCA9IFNWQ19ERUYubWFwKHMgPT4gewogICAgY29uc3QgdXAgPSBtYXBbcy5rZXldID09PSB0cnVlIHx8IG1hcFtzLmtleV0gPT09ICdhY3RpdmUnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJzdmMgJHt1cD8nJzonZG93bid9Ij4KICAgICAgPGRpdiBjbGFzcz0ic3ZjLWwiPjxzcGFuIGNsYXNzPSJkZyAke3VwPycnOidyZWQnfSI+PC9zcGFuPjxzcGFuPiR7cy5pY29ufTwvc3Bhbj4KICAgICAgICA8ZGl2PjxkaXYgY2xhc3M9InN2Yy1uIj4ke3MubmFtZX08L2Rpdj48ZGl2IGNsYXNzPSJzdmMtcCI+JHtzLnBvcnR9PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0icmJkZyAke3VwPycnOidkb3duJ30iPiR7dXA/J1JVTk5JTkcnOidET1dOJ308L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRTZXJ2aWNlcygpIHsKICB0cnkgewogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIHJlbmRlclNlcnZpY2VzKHN0LnNlcnZpY2VzIHx8IHt9KTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+4LmA4LiK4Li34LmI4Lit4Lih4LiV4LmI4LitIEFQSSDguYTguKHguYjguYTguJTguYk8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBQSUNLRVIgU1RBVEUg4pWQ4pWQ4pWQ4pWQCmNvbnN0IFBST1MgPSB7CiAgZHRhYzogewogICAgbmFtZTogJ0RUQUMgR0FNSU5HJywKICAgIHByb3h5OiAnMTA0LjE4LjYzLjEyNDo4MCcsCiAgICBwYXlsb2FkOiAnUE9TVCAvIEhUVFAvMS4xW2NybGZdSG9zdDpkbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tW2NybGZdWC1PbmxpbmUtSG9zdDpkbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tW2NybGZdWC1Gb3J3YXJkLUhvc3Q6ZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbVtjcmxmXVVzZXItQWdlbnQ6IFt1YV1bY3JsZl1Db25uZWN0aW9uOiBrZWVwLWFsaXZlW2NybGZdW2NybGZdW3NwbGl0XVtjcl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDogW2hvc3RdW2NybGZdVXBncmFkZTogd2Vic29ja2V0W2NybGZdQ29ubmVjdGlvbjogVXBncmFkZVtjcmxmXVgtT25saW5lLUhvc3Q6IFtob3N0XVtjcmxmXVtjcmxmXScsCiAgICBkYXJrUHJveHk6ICd0cnVldmlwYW5saW5lLmdvZHZwbi5zaG9wJywgZGFya1Byb3h5UG9ydDogODAKICB9LAogIHRydWU6IHsKICAgIG5hbWU6ICdUUlVFIFRXSVRURVInLAogICAgcHJveHk6ICcxMDQuMTguMzkuMjQ6ODAnLAogICAgcGF5bG9hZDogJ1BPU1QgLyBIVFRQLzEuMVtjcmxmXUhvc3Q6aGVscC54LmNvbVtjcmxmXVgtT25saW5lLUhvc3Q6aGVscC54LmNvbVtjcmxmXVgtRm9yd2FyZC1Ib3N0OmhlbHAueC5jb21bY3JsZl1Vc2VyLUFnZW50OiBbdWFdW2NybGZdQ29ubmVjdGlvbjoga2VlcC1hbGl2ZVtjcmxmXVtjcmxmXVtzcGxpdF1bY3JdUEFUQ0ggLyBIVFRQLzEuMVtjcmxmXUhvc3Q6IFtob3N0XVtjcmxmXVVwZ3JhZGU6IHdlYnNvY2tldFtjcmxmXUNvbm5lY3Rpb246IFVwZ3JhZGVbY3JsZl1YLU9ubGluZS1Ib3N0OiBbaG9zdF1bY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfQp9Owpjb25zdCBOUFZfSE9TVCA9IEhPU1QsIE5QVl9QT1JUID0gODA7CmxldCBfc3NoUHJvID0gJ2R0YWMnLCBfc3NoQXBwID0gJ25wdicsIF9zc2hQb3J0ID0gJzgwJzsKCmZ1bmN0aW9uIHBpY2tQb3J0KHApIHsKICBfc3NoUG9ydCA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BiLTgwJykuY2xhc3NOYW1lICA9ICdwb3J0LWJ0bicgKyAocD09PSc4MCcgID8gJyBhY3RpdmUtcDgwJyAgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BiLTQ0MycpLmNsYXNzTmFtZSA9ICdwb3J0LWJ0bicgKyAocD09PSc0NDMnID8gJyBhY3RpdmUtcDQ0MycgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja1BybyhwKSB7CiAgX3NzaFBybyA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byby1kdGFjJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChwPT09J2R0YWMnID8gJyBhLWR0YWMnIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tdHJ1ZScpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSd0cnVlJyA/ICcgYS10cnVlJyA6ICcnKTsKfQpmdW5jdGlvbiBwaWNrQXBwKGEpIHsKICBfc3NoQXBwID0gYTsKICBbJ25wdicsJ2RhcmsnXS5mb3JFYWNoKGZ1bmN0aW9uKGspewogICAgdmFyIGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcC0nK2spOwogICAgaWYoZWwpIGVsLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAoYT09PWsgPyAnIGEtJytrIDogJycpOwogIH0pOwp9CgoKCmZ1bmN0aW9uIGJ1aWxkTnB2TGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBqID0gewogICAgc3NoQ29uZmlnVHlwZTonU1NILVByb3h5LVBheWxvYWQnLCByZW1hcmtzOnByby5uYW1lKyctJytuYW1lLAogICAgc3NoSG9zdDpOUFZfSE9TVCwgc3NoUG9ydDpOUFZfUE9SVCwKICAgIHNzaFVzZXJuYW1lOm5hbWUsIHNzaFBhc3N3b3JkOnBhc3MsCiAgICBzbmk6JycsIHRsc1ZlcnNpb246J0RFRkFVTFQnLAogICAgaHR0cFByb3h5OnByby5wcm94eSwgYXV0aGVudGljYXRlUHJveHk6ZmFsc2UsCiAgICBwcm94eVVzZXJuYW1lOicnLCBwcm94eVBhc3N3b3JkOicnLAogICAgcGF5bG9hZDpwcm8ucGF5bG9hZCwKICAgIGRuc01vZGU6J1VEUCcsIGRuc1NlcnZlcjonJywgbmFtZXNlcnZlcjonJywgcHVibGljS2V5OicnLAogICAgdWRwZ3dQb3J0OjczMDAsIHVkcGd3VHJhbnNwYXJlbnRETlM6dHJ1ZQogIH07CiAgcmV0dXJuICducHZ0LXNzaDovLycgKyBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChKU09OLnN0cmluZ2lmeShqKSkpKTsKfQpmdW5jdGlvbiBidWlsZERhcmtMaW5rKG5hbWUsIHBhc3MsIHBybykgewogIGNvbnN0IGogPSB7CiAgICB0eXBlOiAiU1NIIiwKICAgIG5hbWU6IHByby5uYW1lICsgJy0nICsgbmFtZSwKICAgIHNzaFR1bm5lbENvbmZpZzogewogICAgICBzc2hDb25maWc6IHsKICAgICAgICBob3N0OiBIT1NULAogICAgICAgIHBvcnQ6IHBhcnNlSW50KF9zc2hQb3J0KSB8fCA4MCwKICAgICAgICB1c2VybmFtZTogbmFtZSwKICAgICAgICBwYXNzd29yZDogcGFzcwogICAgICB9LAogICAgICBpbmplY3RDb25maWc6IHsKICAgICAgICBtb2RlOiAiUFJPWFkiLAogICAgICAgIHByb3h5SG9zdDogKHByby5wcm94eXx8JycpLnNwbGl0KCc6JylbMF0sCiAgICAgICAgcHJveHlQb3J0OiA4MCwKICAgICAgICBwYXlsb2FkOiBwcm8ucGF5bG9hZAogICAgICB9CiAgICB9CiAgfTsKICByZXR1cm4gJ2Rhcmt0dW5uZWw6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBDUkVBVEUgU1NIIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBjcmVhdGVTU0goKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlcicpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBwYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1wYXNzJykudmFsdWUudHJpbSgpOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWRheXMnKS52YWx1ZSl8fDMwOwogIGNvbnN0IGlwbCAgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWlwJykgPyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWlwJykudmFsdWUgOiAyKXx8MjsKICBpZiAoIXVzZXIpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBVc2VybmFtZScsJ2VycicpOwogIGlmICghcGFzcykgcmV0dXJuIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3JkJywnZXJyJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOwogIGJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iIHN0eWxlPSJib3JkZXItY29sb3I6cmdiYSgzNCwxOTcsOTQsLjMpO2JvcmRlci10b3AtY29sb3I6IzIyYzU1ZSI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGNvbnN0IHJlc0VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1saW5rLXJlc3VsdCcpOwogIGlmIChyZXNFbCkgcmVzRWwuY2xhc3NOYW1lPSdsaW5rLXJlc3VsdCc7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9jcmVhdGVfc3NoJywgewogICAgICBtZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7dXNlciwgcGFzc3dvcmQ6cGFzcywgZGF5cywgaXBfbGltaXQ6aXBsfSkKICAgIH0pOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAgaWYgKCFkLm9rKSB0aHJvdyBuZXcgRXJyb3IoZC5lcnJvciB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgcHJvICA9IFBST1NbX3NzaFByb10gfHwgUFJPUy5kdGFjOwogICAgY29uc3QgbGluayA9IF9zc2hBcHA9PT0nbnB2JyA/IGJ1aWxkTnB2TGluayh1c2VyLHBhc3MscHJvKSA6IGJ1aWxkRGFya0xpbmsodXNlcixwYXNzLHBybyk7CiAgICBjb25zdCBpc05wdiA9IF9zc2hBcHA9PT0nbnB2JzsKICAgIGNvbnN0IGxwQ2xzID0gaXNOcHYgPyAnJyA6ICcgZGFyay1scCc7CiAgICBjb25zdCBjQ2xzICA9IGlzTnB2ID8gJ25wdicgOiAnZGFyayc7CiAgICBjb25zdCBhcHBMYWJlbCA9IGlzTnB2ID8gJ05wdnQnIDogJ0RhcmtUdW5uZWwnOwoKICAgIGlmIChyZXNFbCkgewogICAgICByZXNFbC5jbGFzc05hbWUgPSAnbGluay1yZXN1bHQgc2hvdyc7CiAgICAgIGNvbnN0IHNhZmVMaW5rID0gbGluay5yZXBsYWNlKC9cXC9nLCdcXFxcJykucmVwbGFjZSgvJy9nLCJcXCciKTsKICAgICAgcmVzRWwuaW5uZXJIVE1MID0KICAgICAgICAiPGRpdiBjbGFzcz0nbGluay1yZXN1bHQtaGRyJz4iICsKICAgICAgICAgICI8c3BhbiBjbGFzcz0naW1wLWJhZGdlICIrY0NscysiJz4iK2FwcExhYmVsKyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6dmFyKC0tbXV0ZWQpJz4iK3Byby5uYW1lKyIgXHhiNyBQb3J0ICIrX3NzaFBvcnQrIjwvc3Bhbj4iICsKICAgICAgICAgICI8c3BhbiBzdHlsZT0nZm9udC1zaXplOi42NXJlbTtjb2xvcjojMjJjNTVlO21hcmdpbi1sZWZ0OmF1dG8nPlx1MjcwNSAiK3VzZXIrIjwvc3Bhbj4iICsKICAgICAgICAiPC9kaXY+IiArCiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcHJldmlldyIrbHBDbHMrIic+IitsaW5rKyI8L2Rpdj4iICsKICAgICAgICAiPGJ1dHRvbiBjbGFzcz0nY29weS1saW5rLWJ0biAiK2NDbHMrIicgaWQ9J2NvcHktc3NoLWJ0bicgb25jbGljaz1cImNvcHlTU0hMaW5rKClcIj4iKwogICAgICAgICAgIlx1ZDgzZFx1ZGNjYiBDb3B5ICIrYXBwTGFiZWwrIiBMaW5rIisKICAgICAgICAiPC9idXR0b24+IjsKICAgICAgd2luZG93Ll9sYXN0U1NITGluayA9IGxpbms7CiAgICAgIHdpbmRvdy5fbGFzdFNTSEFwcCAgPSBjQ2xzOwogICAgICB3aW5kb3cuX2xhc3RTU0hMYWJlbCA9IGFwcExhYmVsOwogICAgfQoKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4pyFIOC4quC4o+C5ieC4suC4hyAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIggwrcg4Lir4Lih4LiU4Lit4Liy4Lii4Li4ICcrZC5leHAsJ29rJyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZT0nJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlPScnOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KelSDguKrguKPguYnguLLguIcgVXNlcic7IH0KfQpmdW5jdGlvbiBjb3B5U1NITGluaygpIHsKICBjb25zdCBsaW5rID0gd2luZG93Ll9sYXN0U1NITGlua3x8Jyc7CiAgY29uc3QgY0NscyA9IHdpbmRvdy5fbGFzdFNTSEFwcHx8J25wdic7CiAgY29uc3QgbGFiZWwgPSB3aW5kb3cuX2xhc3RTU0hMYWJlbHx8J0xpbmsnOwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KGxpbmspLnRoZW4oZnVuY3Rpb24oKXsKICAgIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29weS1zc2gtYnRuJyk7CiAgICBpZihiKXsgYi50ZXh0Q29udGVudD0nXHUyNzA1IOC4hOC4seC4lOC4peC4reC4geC5geC4peC5ieC4pyEnOyBzZXRUaW1lb3V0KGZ1bmN0aW9uKCl7Yi50ZXh0Q29udGVudD0nXHVkODNkXHVkY2NiIENvcHkgJytsYWJlbCsnIExpbmsnO30sMjAwMCk7IH0KICB9KS5jYXRjaChmdW5jdGlvbigpeyBwcm9tcHQoJ0NvcHkgbGluazonLGxpbmspOyB9KTsKfQoKLy8gU1NIIHVzZXIgdGFibGUKbGV0IF9zc2hUYWJsZVVzZXJzID0gW107CmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hUYWJsZUluRm9ybSgpIHsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBfc3NoVGFibGVVc2VycyA9IGQudXNlcnMgfHwgW107CiAgICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogICAgaWYodGIpIHRiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6I2VmNDQ0NDtwYWRkaW5nOjE2cHgiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBTU0ggQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvdGQ+PC90cj4nOwogIH0KfQpmdW5jdGlvbiByZW5kZXJTU0hUYWJsZSh1c2VycykgewogIGNvbnN0IHRiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLXRib2R5Jyk7CiAgaWYgKCF0YikgcmV0dXJuOwogIGlmICghdXNlcnMubGVuZ3RoKSB7CiAgICB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjIwcHgiPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3RkPjwvdHI+JzsKICAgIHJldHVybjsKICB9CiAgY29uc3Qgbm93ID0gbmV3IERhdGUoKS50b0lTT1N0cmluZygpLnNsaWNlKDAsMTApOwogIHRiLmlubmVySFRNTCA9IHVzZXJzLm1hcChmdW5jdGlvbih1LGkpewogICAgY29uc3QgZXhwaXJlZCA9IHUuZXhwICYmIHUuZXhwIDwgbm93OwogICAgY29uc3QgYWN0aXZlICA9IHUuYWN0aXZlICE9PSBmYWxzZSAmJiAhZXhwaXJlZDsKICAgIGNvbnN0IGRMZWZ0ICAgPSB1LmV4cCA/IE1hdGguY2VpbCgobmV3IERhdGUodS5leHApLURhdGUubm93KCkpLzg2NDAwMDAwKSA6IG51bGw7CiAgICBjb25zdCBiYWRnZSAgID0gYWN0aXZlCiAgICAgID8gJzxzcGFuIGNsYXNzPSJiZGcgYmRnLWciPkFDVElWRTwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJiZGcgYmRnLXIiPkVYUElSRUQ8L3NwYW4+JzsKICAgIGNvbnN0IGRUYWcgPSBkTGVmdCE9PW51bGwKICAgICAgPyAnPHNwYW4gY2xhc3M9ImRheXMtYmFkZ2UiPicrKGRMZWZ0PjA/ZExlZnQrJ2QnOifguKvguKHguJQnKSsnPC9zcGFuPicKICAgICAgOiAnPHNwYW4gY2xhc3M9ImRheXMtYmFkZ2UiPlx1MjIxZTwvc3Bhbj4nOwogICAgcmV0dXJuICc8dHI+PHRkIHN0eWxlPSJjb2xvcjp2YXIoLS1tdXRlZCkiPicrKGkrMSkrJzwvdGQ+JyArCiAgICAgICc8dGQ+PGI+Jyt1LnVzZXIrJzwvYj48L3RkPicgKwogICAgICAnPHRkIHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjonKyhleHBpcmVkPycjZWY0NDQ0JzondmFyKC0tbXV0ZWQpJykrJyI+JysKICAgICAgICAodS5leHB8fCfguYTguKHguYjguIjguLPguIHguLHguJQnKSsnPC90ZD4nICsKICAgICAgJzx0ZD4nK2JhZGdlKyc8L3RkPicgKwogICAgICAnPHRkPjxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6NHB4O2FsaWduLWl0ZW1zOmNlbnRlciI+JysKICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iYnRuLXRibCIgdGl0bGU9IuC4leC5iOC4reC4reC4suC4ouC4uCIgb25jbGljaz0ib3BlblNTSFJlbmV3TW9kYWwoXCcnK3UudXNlcisnXCcpIj7wn5SEPC9idXR0b24+JysKICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iYnRuLXRibCIgdGl0bGU9IuC4peC4miIgb25jbGljaz0iZGVsU1NIVXNlcihcJycrdS51c2VyKydcJykiIHN0eWxlPSJib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsLjMpIj7wn5eR77iPPC9idXR0b24+JysKICAgICAgICBkVGFnKwogICAgICAnPC9kaXY+PC90ZD48L3RyPic7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsdGVyU1NIVXNlcnMocSkgewogIHJlbmRlclNTSFRhYmxlKF9zc2hUYWJsZVVzZXJzLmZpbHRlcihmdW5jdGlvbih1KXtyZXR1cm4gKHUudXNlcnx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50b0xvd2VyQ2FzZSgpKTt9KSk7Cn0KLy8gU1NIIFJlbmV3IE1vZGFsCmxldCBfcmVuZXdTU0hVc2VyID0gJyc7CmZ1bmN0aW9uIG9wZW5TU0hSZW5ld01vZGFsKHVzZXIpIHsKICBfcmVuZXdTU0hVc2VyID0gdXNlcjsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LXVzZXJuYW1lJykudGV4dENvbnRlbnQgPSB1c2VyOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctZGF5cycpLnZhbHVlID0gJzMwJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LW1vZGFsJykuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwp9CmZ1bmN0aW9uIGNsb3NlU1NIUmVuZXdNb2RhbCgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LW1vZGFsJykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogIF9yZW5ld1NTSFVzZXIgPSAnJzsKfQphc3luYyBmdW5jdGlvbiBkb1NTSFJlbmV3KCkgewogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKCFkYXlzfHxkYXlzPD0wKSByZXR1cm47CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOyBidG4udGV4dENvbnRlbnQgPSAn4LiB4Liz4Lil4Lix4LiH4LiV4LmI4Lit4Lit4Liy4Lii4Li4Li4uJzsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2V4dGVuZF9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyOl9yZW5ld1NTSFVzZXIsZGF5c30pCiAgICB9KS50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKTt9KTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKHIuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzA1IOC4leC5iOC4reC4reC4suC4ouC4uCAnK19yZW5ld1NTSFVzZXIrJyArJytkYXlzKycg4Lin4Lix4LiZIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBjbG9zZVNTSFJlbmV3TW9kYWwoKTsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgewogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3NGMgJytlLm1lc3NhZ2UsJ2VycicpOwogIH0gZmluYWxseSB7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLgnOwogIH0KfQphc3luYyBmdW5jdGlvbiByZW5ld1NTSFVzZXIodXNlcikgeyBvcGVuU1NIUmVuZXdNb2RhbCh1c2VyKTsgfQphc3luYyBmdW5jdGlvbiBkZWxTU0hVc2VyKHVzZXIpIHsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciIOC4luC4suC4p+C4oz8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcsewogICAgICBtZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJ9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBhbGVydCgnXHUyNzRjICcrZS5tZXNzYWdlKTsgfQp9Ci8vIOKVkOKVkOKVkOKVkCBDUkVBVEUgVkxFU1Mg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGdlblVVSUQoKSB7CiAgcmV0dXJuICd4eHh4eHh4eC14eHh4LTR4eHgteXh4eC14eHh4eHh4eHh4eHgnLnJlcGxhY2UoL1t4eV0vZyxjPT57CiAgICBjb25zdCByPU1hdGgucmFuZG9tKCkqMTZ8MDsgcmV0dXJuIChjPT09J3gnP3I6KHImMHgzfDB4OCkpLnRvU3RyaW5nKDE2KTsKICB9KTsKfQphc3luYyBmdW5jdGlvbiBjcmVhdGVWTEVTUyhjYXJyaWVyKSB7CiAgY29uc3QgZW1haWxFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1lbWFpbCcpOwogIGNvbnN0IGRheXNFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZGF5cycpOwogIGNvbnN0IGlwRWwgICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctaXAnKTsKICBjb25zdCBnYkVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWdiJyk7CiAgY29uc3QgZW1haWwgICA9IGVtYWlsRWwudmFsdWUudHJpbSgpOwogIGNvbnN0IGRheXMgICAgPSBwYXJzZUludChkYXlzRWwudmFsdWUpfHwzMDsKICBjb25zdCBpcExpbWl0ID0gcGFyc2VJbnQoaXBFbC52YWx1ZSl8fDI7CiAgY29uc3QgZ2IgICAgICA9IHBhcnNlSW50KGdiRWwudmFsdWUpfHwwOwogIGlmICghZW1haWwpIHJldHVybiBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIEVtYWlsL1VzZXJuYW1lJywnZXJyJyk7CgogIGNvbnN0IHBvcnQgPSBjYXJyaWVyPT09J2FpcycgPyA4MDgwIDogODg4MDsKICBjb25zdCBzbmkgID0gY2Fycmllcj09PSdhaXMnID8gJ2NqLWViYi5zcGVlZHRlc3QubmV0JyA6ICd0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzJzsKCiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWJ0bicpOwogIGJ0bi5kaXNhYmxlZD10cnVlOyBidG4uaW5uZXJIVE1MPSc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKCiAgdHJ5IHsKICAgIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIC8vIOC4q+C4siBpbmJvdW5kIGlkCiAgICBjb25zdCBsaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliID0gKGxpc3Qub2JqfHxbXSkuZmluZCh4PT54LnBvcnQ9PT1wb3J0KTsKICAgIGlmICghaWIpIHRocm93IG5ldyBFcnJvcihg4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCAke3BvcnR9IOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZYCk7CgogICAgY29uc3QgdWlkID0gZ2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXMgPSBkYXlzID4gMCA/IChEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMCkgOiAwOwogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDp1aWQsIGZsb3c6JycsIGVtYWlsLCBsaW1pdElwOmlwTGltaXQsCiAgICAgICAgdG90YWxHQjp0b3RhbEJ5dGVzLCBleHBpcnlUaW1lOmV4cE1zLCBlbmFibGU6dHJ1ZSwgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgbGlua05hbWUgPSBjYXJyaWVyPT09J2FpcycgPyAnQUlTLeC4geC4seC4meC4o+C4seC5iOC4py0nK2VtYWlsIDogJ1RSVUUtVkRPLScrZW1haWw7CiAgICBjb25zdCBsaW5rID0gY2Fycmllcj09PSdhaXMnID8gYHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06JHtwb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChsaW5rTmFtZSl9YCA6IGB2bGVzczovLyR7dWlkfUAke3NuaX06JHtwb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7SE9TVH0jJHtlbmNvZGVVUklDb21wb25lbnQobGlua05hbWUpfWA7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZW1haWwnKS50ZXh0Q29udGVudCA9IGVtYWlsOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctdXVpZCcpLnRleHRDb250ZW50ID0gdWlkOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZXhwJykudGV4dENvbnRlbnQgPSBleHBNcyA+IDAgPyBmbXREYXRlKGV4cE1zKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctbGluaycpLnRleHRDb250ZW50ID0gbGluazsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7CiAgICAvLyBHZW5lcmF0ZSBRUiBjb2RlCiAgICBjb25zdCBxckRpdiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1xcicpOwogICAgaWYgKHFyRGl2KSB7CiAgICAgIHFyRGl2LmlubmVySFRNTCA9ICcnOwogICAgICB0cnkgewogICAgICAgIG5ldyBRUkNvZGUocXJEaXYsIHsgdGV4dDogbGluaywgd2lkdGg6IDE4MCwgaGVpZ2h0OiAxODAsIGNvcnJlY3RMZXZlbDogUVJDb2RlLkNvcnJlY3RMZXZlbC5NIH0pOwogICAgICB9IGNhdGNoKHFyRXJyKSB7IHFyRGl2LmlubmVySFRNTCA9ICcnOyB9CiAgICB9CiAgICBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4pyFIOC4quC4o+C5ieC4suC4hyBWTEVTUyBBY2NvdW50IOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBlbWFpbEVsLnZhbHVlPScnOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KaoSDguKrguKPguYnguLLguIcgJysoY2Fycmllcj09PSdhaXMnPydBSVMnOidUUlVFJykrJyBBY2NvdW50JzsgfQp9CgovLyDilZDilZDilZDilZAgTUFOQUdFIFVTRVJTIOKVkOKVkOKVkOKVkApsZXQgX2FsbFVzZXJzID0gW10sIF9jdXJVc2VyID0gbnVsbDsKYXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJzKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgX3h1aUNvb2tpZSA9IGZhbHNlOwogICAgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihkLm1zZyB8fCAn4LmC4Lir4Lil4LiUIGluYm91bmRzIOC5hOC4oeC5iOC5hOC4lOC5iScpOwogICAgX2FsbFVzZXJzID0gW107CiAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICBjb25zdCBlbWFpbCA9IGMuZW1haWx8fGMuaWQ7CiAgICAgICAgY29uc3QgY3MgPSAoaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT1lbWFpbCl8fG51bGw7CiAgICAgICAgX2FsbFVzZXJzLnB1c2goewogICAgICAgICAgaWJJZDogaWIuaWQsIHBvcnQ6IGliLnBvcnQsIHByb3RvOiBpYi5wcm90b2NvbCwKICAgICAgICAgIGVtYWlsLCB1dWlkOiBjLmlkLAogICAgICAgICAgZXhwOiBjLmV4cGlyeVRpbWV8fDAsIHRvdGFsOiBjLnRvdGFsR0J8fDAsCiAgICAgICAgICB1cDogY3MgPyBjcy51cCA6IDAsIGRvd246IGNzID8gY3MuZG93biA6IDAsIGFsbFRpbWU6IGNzID8gKGNzLmFsbFRpbWV8fDApIDogMCwgbGltaXRJcDogYy5saW1pdElwfHwwCiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSk7CiAgICByZW5kZXJVc2VycyhfYWxsVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclVzZXJzKHVzZXJzKSB7CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lie4Lia4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMPC9wPjwvZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1ID0+IHsKICAgIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogICAgbGV0IGJhZGdlLCBjbHM7CiAgICBpZiAoIXUuZXhwIHx8IHUuZXhwPT09MCkgeyBiYWRnZT0n4pyTIOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7IGNscz0nb2snOyB9CiAgICBlbHNlIGlmIChkbCA8IDApICAgICAgICAgeyBiYWRnZT0n4Lir4Lih4LiU4Lit4Liy4Lii4Li4JzsgY2xzPSdleHAnOyB9CiAgICBlbHNlIGlmIChkbCA8PSAzKSAgICAgICAgeyBiYWRnZT0n4pqgICcrZGwrJ2QnOyBjbHM9J3Nvb24nOyB9CiAgICBlbHNlICAgICAgICAgICAgICAgICAgICAgeyBiYWRnZT0n4pyTICcrZGwrJ2QnOyBjbHM9J29rJzsgfQogICAgY29uc3QgYXZDbHMgPSBkbCA8IDAgPyAnYXYteCcgOiAnYXYtZyc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIiBvbmNsaWNrPSJvcGVuVXNlcigke0pTT04uc3RyaW5naWZ5KHUpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyl9KSI+CiAgICAgIDxkaXYgY2xhc3M9InVhdiAke2F2Q2xzfSI+JHsodS5lbWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3UuZW1haWx9PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idW0iPlBvcnQgJHt1LnBvcnR9IMK3ICR7Zm10Qnl0ZXMoKHUudXB8fDApKyh1LmRvd258fDApKyh1LmFsbFRpbWV8fDApKX0g4LmD4LiK4LmJPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2Nsc30iPiR7YmFkZ2V9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJVc2VycyhxKSB7CiAgcmVuZGVyVXNlcnMoX2FsbFVzZXJzLmZpbHRlcih1PT4odS5lbWFpbHx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50b0xvd2VyQ2FzZSgpKSkpOwp9CgovLyDilZDilZDilZDilZAgTU9EQUwgVVNFUiDilZDilZDilZDilZAKZnVuY3Rpb24gb3BlblVzZXIodSkgewogIGlmICh0eXBlb2YgdSA9PT0gJ3N0cmluZycpIHUgPSBKU09OLnBhcnNlKHUpOwogIF9jdXJVc2VyID0gdTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXQnKS50ZXh0Q29udGVudCA9ICfimpnvuI8gJyt1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdScpLnRleHRDb250ZW50ID0gdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHAnKS50ZXh0Q29udGVudCA9IHUucG9ydDsKICBjb25zdCBkbCA9IGRheXNMZWZ0KHUuZXhwKTsKICBjb25zdCBleHBUeHQgPSAhdS5leHB8fHUuZXhwPT09MCA/ICfguYTguKHguYjguIjguLPguIHguLHguJQnIDogZm10RGF0ZSh1LmV4cCk7CiAgY29uc3QgZGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGUnKTsKICBkZS50ZXh0Q29udGVudCA9IGV4cFR4dDsKICBkZS5jbGFzc05hbWUgPSAnZHYnICsgKGRsICE9PSBudWxsICYmIGRsIDwgMCA/ICcgcmVkJyA6ICcgZ3JlZW4nKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGQnKS50ZXh0Q29udGVudCA9IHUudG90YWwgPiAwID8gZm10Qnl0ZXModS50b3RhbCkgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHRyJykudGV4dENvbnRlbnQgPSBmbXRCeXRlcygodS51cHx8MCkrKHUuZG93bnx8MCkrKHUuYWxsVGltZXx8MCkpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaScpLnRleHRDb250ZW50ID0gdS5saW1pdElwIHx8ICfiiJ4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdXUnKS50ZXh0Q29udGVudCA9IHUudXVpZDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY20oKXsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7Cn0KCi8vIOKUgOKUgCBNT0RBTCA2LUFDVElPTiBTWVNURU0g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNvbnN0IF9tU3VicyA9IFsncmVuZXcnLCdleHRlbmQnLCdhZGRkYXRhJywnc2V0ZGF0YScsJ3Jlc2V0JywnZGVsZXRlJ107CmZ1bmN0aW9uIG1BY3Rpb24oa2V5KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2tleSk7CiAgY29uc3QgaXNPcGVuID0gZWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgaWYgKCFpc09wZW4pIHsKICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgIGlmIChrZXk9PT0nZGVsZXRlJyAmJiBfY3VyVXNlcikgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZGVsLW5hbWUnKS50ZXh0Q29udGVudCA9IF9jdXJVc2VyLmVtYWlsOwogICAgc2V0VGltZW91dCgoKT0+ZWwuc2Nyb2xsSW50b1ZpZXcoe2JlaGF2aW9yOidzbW9vdGgnLGJsb2NrOiduZWFyZXN0J30pLDEwMCk7CiAgfQp9CmZ1bmN0aW9uIF9tQnRuTG9hZChpZCwgbG9hZGluZywgb3JpZ1RleHQpIHsKICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghYikgcmV0dXJuOwogIGIuZGlzYWJsZWQgPSBsb2FkaW5nOwogIGlmIChsb2FkaW5nKSB7IGIuZGF0YXNldC5vcmlnID0gYi50ZXh0Q29udGVudDsgYi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj4g4LiB4Liz4Lil4Lix4LiH4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijLi4uJzsgfQogIGVsc2UgeyBiLnRleHRDb250ZW50ID0gYi5kYXRhc2V0Lm9yaWcgfHwgb3JpZ1RleHQgfHwgJ+C4lOC4s+C5gOC4meC4tOC4meC4geC4suC4oyc7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9SZW5ld1VzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBleHBNcyA9IERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC5iOC4reC4reC4suC4ouC4uOC4quC4s+C5gOC4o+C5h+C4iCAnK2RheXMrJyDguKfguLHguJkgKOC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iSknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZW5ldy1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9FeHRlbmRVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZXh0ZW5kLWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBiYXNlID0gKF9jdXJVc2VyLmV4cCAmJiBfY3VyVXNlci5leHAgPiBEYXRlLm5vdygpKSA/IF9jdXJVc2VyLmV4cCA6IERhdGUubm93KCk7CiAgICBjb25zdCBleHBNcyA9IGJhc2UgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSAnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIICjguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQpJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0FkZERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGFkZEdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1hZGRkYXRhLWdiJykudmFsdWUpfHwwOwogIGlmIChhZGRHYiA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKEnLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tYWRkZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgbmV3VG90YWwgPSAoX2N1clVzZXIudG90YWx8fDApICsgYWRkR2IqMTA3Mzc0MTgyNDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpuZXdUb3RhbCxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihIERhdGEgKycrYWRkR2IrJyBHQiDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1NldERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1zZXRkYXRhLWdiJykudmFsdWUpOwogIGlmIChpc05hTihnYil8fGdiPDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6dG90YWxCeXRlcyxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4Lix4LmJ4LiHIERhdGEgTGltaXQgJysoZ2I+MD9nYisnIEdCJzon4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1Jlc2V0VHJhZmZpYygpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLXJlc2V0LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL3Jlc2V0Q2xpZW50VHJhZmZpYy8nK19jdXJVc2VyLmVtYWlsLCB7fSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgbG9hZERhc2hib2FyZCAmJiBsb2FkRGFzaGJvYXJkKCk7IH0sIDE1MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRGVsZXRlVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9kZWxDbGllbnQvJytfY3VyVXNlci51dWlkLCB7fSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKXguJrguKLguLnguKogJytfY3VyVXNlci5lbWFpbCsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxMjAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCBmYWxzZSk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlDb29raWUgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICAvLyDguYLguKvguKXguJQgaW5ib3VuZHMg4LiW4LmJ4Liy4Lii4Lix4LiH4LmE4Lih4LmI4Lih4Li1CiAgICBpZiAoIV9hbGxVc2Vycy5sZW5ndGgpIHsKICAgICAgY29uc3QgZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgICBpZiAoZCAmJiBkLnN1Y2Nlc3MpIHsKICAgICAgICBfYWxsVXNlcnMgPSBbXTsKICAgICAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBfYWxsVXNlcnMucHVzaCh7IGliSWQ6aWIuaWQsIHBvcnQ6aWIucG9ydCwgcHJvdG86aWIucHJvdG9jb2wsCiAgICAgICAgICAgICAgZW1haWw6Yy5lbWFpbHx8Yy5pZCwgdXVpZDpjLmlkLCBleHA6Yy5leHBpcnlUaW1lfHwwLAogICAgICAgICAgICAgIHRvdGFsOmMudG90YWxHQnx8MCwgdXA6KGliLmNsaWVudFN0YXRzfHxbXSkuZmluZCh4PT54LmVtYWlsPT09KGMuZW1haWx8fGMuaWQpKT8udXB8fDAsIGRvd246KGliLmNsaWVudFN0YXRzfHxbXSkuZmluZCh4PT54LmVtYWlsPT09KGMuZW1haWx8fGMuaWQpKT8uZG93bnx8MCwgYWxsVGltZTooaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT0oYy5lbWFpbHx8Yy5pZCkpPy5hbGxUaW1lfHwwLCBsaW1pdElwOmMubGltaXRJcHx8MCB9KTsKICAgICAgICAgIH0pOwogICAgICAgIH0pOwogICAgICB9CiAgICB9CiAgICBsZXQgZW1haWxzID0gW107CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgY29uc3QgZDIgPSBhd2FpdCB4dWlHZXQoIi9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCIpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChkMiAmJiBkMi5zdWNjZXNzKSB7CiAgICAgIChkMi5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAoaWIuY2xpZW50U3RhdHN8fFtdKS5mb3JFYWNoKGNzID0+IHsKICAgICAgICAgIGlmIChjcy5sYXN0T25saW5lICYmIChub3cgLSBjcy5sYXN0T25saW5lKSA8IDMwMDAwMCkgZW1haWxzLnB1c2goY3MuZW1haWwpOwogICAgICAgIH0pOwogICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICBjb25zdCBjcyA9IChkMiYmZDIub2JqfHxbXSkuZmxhdE1hcChpYj0+aWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT1lbWFpbCl8fG51bGw7CiAgICAgIGNvbnN0IGliT2JqID0gKGQyJiZkMi5vYmp8fFtdKS5maW5kKGliPT4oaWIuY2xpZW50U3RhdHN8fFtdKS5zb21lKHg9PnguZW1haWw9PT1lbWFpbCkpfHxudWxsOwogICAgICBjb25zdCB1c2VkR0IgPSBjcyA/ICgoY3MudXArY3MuZG93bisoY3MuYWxsVGltZXx8MCkpLzEwNzM3NDE4MjQpLnRvRml4ZWQoMikgOiAoaWJPYmogPyAoKGliT2JqLnVwK2liT2JqLmRvd24pLzEwNzM3NDE4MjQpLnRvRml4ZWQoMikgOiAwKTsKICAgICAgY29uc3QgdG90YWxHQiA9IGNzICYmIGNzLnRvdGFsPjAgPyAoY3MudG90YWwvMTA3Mzc0MTgyNCkudG9GaXhlZCgwKSA6IG51bGw7CiAgICAgIGNvbnN0IHBjdCA9ICh1ICYmIHUudG90YWw+MCkgPyBNYXRoLm1pbihNYXRoLnJvdW5kKCh1LnVwK3UuZG93bikvdS50b3RhbCoxMDApLDEwMCkgOiAwOwogICAgICBjb25zdCBiYXIgPSBwY3Q+ODU/IiNlZjQ0NDQiOnBjdD42NT8iI2Y5NzMxNiI6IiMyMmM1NWUiOwogICAgICBjb25zdCBleHBNcyA9IHUgPyB1LmV4cCA6IDA7CiAgICAgIGNvbnN0IGV4cFN0ciA9ICghZXhwTXN8fGV4cE1zPT09MCk/IuC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCI6bmV3IERhdGUoZXhwTXMpLnRvTG9jYWxlRGF0ZVN0cmluZygidGgtVEgiLHt5ZWFyOiJudW1lcmljIixtb250aDoic2hvcnQiLGRheToibnVtZXJpYyJ9KTsKICAgICAgY29uc3QgZExlZnQgPSAoIWV4cE1zfHxleHBNcz09PTApP251bGw6TWF0aC5jZWlsKChleHBNcy1EYXRlLm5vdygpKS84NjQwMDAwMCk7CiAgICAgIGNvbnN0IGRUYWcgPSBkTGVmdD09PW51bGw/IuKIniI6ZExlZnQ+MD9kTGVmdCsiZCI6IuC4q+C4oeC4lOC5geC4peC5ieC4pyI7CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIHN0eWxlPSJmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjhweDtwYWRkaW5nOjE0cHggMTZweCI+CiAgICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweCI+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDoyMHB4O2hlaWdodDoyMHB4O2ZsZXgtc2hyaW5rOjAiPjxzcGFuIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTtvcGFjaXR5Oi40O2FuaW1hdGlvbjpwaW5nIDEuMnMgY3ViaWMtYmV6aWVyKDAsMCwuMiwxKSBpbmZpbml0ZSI+PC9zcGFuPjxzcGFuIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDozcHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojMjJjNTVlIj48L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InVuIj4ke2VtYWlsfTwvZGl2PjxkaXYgY2xhc3M9InVtIj4ke3U/IlBvcnQgIit1LnBvcnQ6IlZMRVNTIn0gwrcg4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4Lit4Lii4Li54LmIPC9kaXY+PC9kaXY+CiAgICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayI+T05MSU5FPC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImJhY2tncm91bmQ6cmdiYSgwLDAsMCwuMDUpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEwcHggMTJweCI+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Zm9udC1zaXplOjExcHg7Y29sb3I6IzY2NjttYXJnaW4tYm90dG9tOjVweCI+CiAgICAgICAgICAgIDxzcGFuPvCfk4ogJHt1c2VkR0J9IEdCICR7dG90YWxHQj8iLyAiK3RvdGFsR0IrIiBHQiI6Ii8g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUIn08L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJjb2xvcjoke2Jhcn07Zm9udC13ZWlnaHQ6NjAwIj4ke3RvdGFsR0I/cGN0KyIlIjoiIn08L3NwYW4+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDo2cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC4xKTtib3JkZXItcmFkaXVzOjk5cHg7b3ZlcmZsb3c6aGlkZGVuIj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iaGVpZ2h0OjEwMCU7d2lkdGg6JHt0b3RhbEdCP3BjdDoxMDB9JTtiYWNrZ3JvdW5kOiR7YmFyfTtib3JkZXItcmFkaXVzOjk5cHgiPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Zm9udC1zaXplOjExcHg7Y29sb3I6Izg4ODttYXJnaW4tdG9wOjZweCI+CiAgICAgICAgICAgIDxzcGFuPvCfk4UgJHtleHBTdHJ9PC9zcGFuPgogICAgICAgICAgICA8c3BhbiBzdHlsZT0iYmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMTIpO2NvbG9yOiMxNmEzNGE7cGFkZGluZzoxcHggOHB4O2JvcmRlci1yYWRpdXM6OTlweCI+JHtkVGFnfTwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggVVNFUlMgKGJhbiB0YWIpIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkU1NIVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgY29uc3QgdXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1PT57CiAgICAgIGNvbnN0IGV4cCA9IHUuZXhwIHx8ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgICBjb25zdCBhY3RpdmUgPSB1LmFjdGl2ZSAhPT0gZmFsc2U7CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iPgogICAgICAgIDxkaXYgY2xhc3M9InVhdiAke2FjdGl2ZT8nYXYtZyc6J2F2LXgnfSI+JHt1LnVzZXJbMF0udG9VcHBlckNhc2UoKX08L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS51c2VyfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idW0iPuC4q+C4oeC4lOC4reC4suC4ouC4uDogJHtleHB9PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHthY3RpdmU/J29rJzonZXhwJ30iPiR7YWN0aXZlPydBY3RpdmUnOidFeHBpcmVkJ308L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIGRlbGV0ZVNTSCgpIHsKICBjb25zdCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgpOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiA/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pfSkudGhlbihyPT5yLmpzb24oKSk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yfHwn4Lil4Lia4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+KchSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVlPScnOwogICAgbG9hZFNTSFVzZXJzKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQp9CgovLyDilZDilZDilZDilZAgQ09QWSDilZDilZDilZDilZAKZnVuY3Rpb24gY29weUxpbmsoaWQsIGJ0bikgewogIGNvbnN0IHR4dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudDsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0eHQpLnRoZW4oKCk9PnsKICAgIGNvbnN0IG9yaWcgPSBidG4udGV4dENvbnRlbnQ7CiAgICBidG4udGV4dENvbnRlbnQ9J+KchSBDb3BpZWQhJzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9J3JnYmEoMzQsMTk3LDk0LC4xNSknOwogICAgc2V0VGltZW91dCgoKT0+eyBidG4udGV4dENvbnRlbnQ9b3JpZzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9Jyc7IH0sIDIwMDApOwogIH0pLmNhdGNoKCgpPT57IHByb21wdCgnQ29weSBsaW5rOicsIHR4dCk7IH0pOwp9CgovLyDilZDilZDilZDilZAgTE9HT1VUIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBkb0xvZ291dCgpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBJTklUIOKVkOKVkOKVkOKVkAoKLy8g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCi8vICBTUEVFRCBURVNUCi8vIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkApsZXQgX3NwZWVkUnVubmluZz1mYWxzZTsKZnVuY3Rpb24gc2V0R2F1Z2UobWJwcywgbWF4TWJwcz0yMDApIHsKICBjb25zdCBlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2F1Z2UtZmlsbCcpOwogIGNvbnN0IHZhbEVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdnYXVnZS12YWwnKTsKICBjb25zdCB1bml0RWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dhdWdlLXVuaXQnKTsKICBpZiAoIWVsKSByZXR1cm47CiAgY29uc3QgcGN0PU1hdGgubWluKG1icHMvbWF4TWJwcywxKTsKICBlbC5zdHlsZS5zdHJva2VEYXNob2Zmc2V0PSgyMjAtKDIyMCpwY3QpKS50b0ZpeGVkKDIpOwogIGNvbnN0IHI9TWF0aC5yb3VuZChwY3Q8MC41PzA6MjU1KihwY3QtMC41KSoyKTsKICBjb25zdCBnPU1hdGgucm91bmQocGN0PDAuNT8yNTU6MjU1KigxLShwY3QtMC41KSoyKSk7CiAgZWwuc2V0QXR0cmlidXRlKCdzdHJva2UnLGByZ2IoJHtyfSwke2d9LDUwKWApOwogIHZhbEVsLnRleHRDb250ZW50PW1icHM+PTE/bWJwcy50b0ZpeGVkKDEpOihtYnBzKjEwMDApLnRvRml4ZWQoMCk7CiAgdW5pdEVsLnRleHRDb250ZW50PW1icHM+PTE/J01icHMnOidLYnBzJzsKfQpmdW5jdGlvbiBzZXRQcm9ncmVzcyhwY3QpIHsKICBjb25zdCBlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtcHJvZy1maWxsJyk7CiAgaWYgKGVsKSBlbC5zdHlsZS53aWR0aD1NYXRoLm1pbihwY3QsMTAwKSsnJSc7Cn0KYXN5bmMgZnVuY3Rpb24gbWVhc3VyZVBpbmcoKSB7CiAgY29uc3QgcGluZ3M9W107CiAgZm9yIChsZXQgaT0wO2k8NTtpKyspIHsKICAgIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogICAgdHJ5e2F3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycse21ldGhvZDonSEVBRCcsY2FjaGU6J25vLXN0b3JlJ30pO30KICAgIGNhdGNoKGUpe3RyeXthd2FpdCBmZXRjaCgnLycse21ldGhvZDonSEVBRCcsY2FjaGU6J25vLXN0b3JlJ30pO31jYXRjaChlZSl7fX0KICAgIHBpbmdzLnB1c2gocGVyZm9ybWFuY2Uubm93KCktdDApOwogICAgYXdhaXQgbmV3IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkpOwogIH0KICBwaW5ncy5zb3J0KChhLGIpPT5hLWIpOwogIGNvbnN0IHBpbmc9cGluZ3NbTWF0aC5mbG9vcihwaW5ncy5sZW5ndGgvMildOwogIGNvbnN0IGppdHRlcj1waW5nc1twaW5ncy5sZW5ndGgtMV0tcGluZ3NbMF07CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BpbmctdmFsJykudGV4dENvbnRlbnQ9cGluZy50b0ZpeGVkKDApKycgbXMnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdqaXR0ZXItdmFsJykudGV4dENvbnRlbnQ9aml0dGVyLnRvRml4ZWQoMCkrJyBtcyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvc3MtdmFsJykudGV4dENvbnRlbnQ9JzAlJzsKICBjb25zdCBwaW5nRWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BpbmctdmFsJyk7CiAgcGluZ0VsLmNsYXNzTmFtZT0nc3BlZWQtcGluZy12YWwnKyhwaW5nPDgwPycnOnBpbmc8MjAwPycgd2Fybic6JyBiYWQnKTsKICByZXR1cm4ge3Bpbmcsaml0dGVyfTsKfQphc3luYyBmdW5jdGlvbiBzdGFydFNwZWVkVGVzdCh0eXBlKSB7CiAgaWYgKF9zcGVlZFJ1bm5pbmcpIHJldHVybjsKICBfc3BlZWRSdW5uaW5nPXRydWU7CiAgY29uc3QgYnRuRGw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1kbCcpOwogIGNvbnN0IGJ0blVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdWwnKTsKICBidG5EbC5kaXNhYmxlZD10cnVlOyBidG5VbC5kaXNhYmxlZD10cnVlOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4LiB4Liz4Lil4Lix4LiH4Lin4Lix4LiUIFBpbmcuLi4nOwogIHNldFByb2dyZXNzKDApOyBzZXRHYXVnZSgwKTsKICB0cnl7CiAgICBjb25zdCBpbmZvPWF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmKGluZm8mJmluZm8uaG9zdCkgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Zwcy1pcCcpLnRleHRDb250ZW50PWluZm8uaG9zdDsKICAgIGVsc2UgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Zwcy1pcCcpLnRleHRDb250ZW50PWxvY2F0aW9uLmhvc3RuYW1lOwogIH1jYXRjaChlKXt9CiAgdHJ5e2F3YWl0IG1lYXN1cmVQaW5nKCk7fWNhdGNoKGUpe30KICBzZXRQcm9ncmVzcygxMCk7CiAgaWYgKHR5cGU9PT0nZG93bmxvYWQnKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtc3RhdHVzJykudGV4dENvbnRlbnQ9J+C4geC4s+C4peC4seC4h+C4l+C4lOC4quC4reC4miBEb3dubG9hZC4uLic7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtdmFsJykudGV4dENvbnRlbnQ9Jy4uLic7CiAgICBjb25zdCBtYnBzPWF3YWl0IHJ1bkRvd25sb2FkVGVzdCgocCxjdXIpPT57CiAgICAgIHNldFByb2dyZXNzKDEwK3AqMC44KTsgc2V0R2F1Z2UoY3VyKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKGN1ci8yMDAqMTAwLDEwMCkrJyUnOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtdmFsJykudGV4dENvbnRlbnQ9bWJwcy50b0ZpeGVkKDEpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKG1icHMvMjAwKjEwMCwxMDApKyclJzsKICAgIHNldEdhdWdlKG1icHMpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfinIUgRG93bmxvYWQ6ICcrbWJwcy50b0ZpeGVkKDEpKycgTWJwcyc7CiAgfSBlbHNlIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIFVwbG9hZC4uLic7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWwtdmFsJykudGV4dENvbnRlbnQ9Jy4uLic7CiAgICBjb25zdCBtYnBzPWF3YWl0IHJ1blVwbG9hZFRlc3QoKHAsY3VyKT0+ewogICAgICBzZXRQcm9ncmVzcygxMCtwKjAuOCk7IHNldEdhdWdlKGN1cik7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC1iYXInKS5zdHlsZS53aWR0aD1NYXRoLm1pbihjdXIvMjAwKjEwMCwxMDApKyclJzsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLXZhbCcpLnRleHRDb250ZW50PW1icHMudG9GaXhlZCgxKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC1iYXInKS5zdHlsZS53aWR0aD1NYXRoLm1pbihtYnBzLzIwMCoxMDAsMTAwKSsnJSc7CiAgICBzZXRHYXVnZShtYnBzKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4pyFIFVwbG9hZDogJyttYnBzLnRvRml4ZWQoMSkrJyBNYnBzJzsKICB9CiAgc2V0UHJvZ3Jlc3MoMTAwKTsKICBzZXRUaW1lb3V0KCgpPT5zZXRQcm9ncmVzcygwKSwxNTAwKTsKICBidG5EbC5kaXNhYmxlZD1mYWxzZTsgYnRuVWwuZGlzYWJsZWQ9ZmFsc2U7CiAgX3NwZWVkUnVubmluZz1mYWxzZTsKfQphc3luYyBmdW5jdGlvbiBydW5Eb3dubG9hZFRlc3Qob25Qcm9ncmVzcykgewogIGNvbnN0IERVUkFUSU9OX01TPTgwMDA7CiAgbGV0IHRvdGFsQnl0ZXM9MDsKICBjb25zdCB0MD1wZXJmb3JtYW5jZS5ub3coKTsKICBsZXQgZG9uZT1mYWxzZTsKICBzZXRUaW1lb3V0KCgpPT57ZG9uZT10cnVlO30sRFVSQVRJT05fTVMpOwogIGNvbnN0IENIVU5LPTEqMTAyNCoxMDI0OwogIGNvbnN0IHJ1bj1hc3luYygpPT57CiAgICB3aGlsZSghZG9uZSl7CiAgICAgIHRyeXsKICAgICAgICBjb25zdCB1cmw9J2h0dHBzOi8vc3BlZWQuY2xvdWRmbGFyZS5jb20vX19kb3duP2J5dGVzPScrQ0hVTks7CiAgICAgICAgY29uc3Qgcj1hd2FpdCBmZXRjaCh1cmwse2NhY2hlOiduby1zdG9yZSd9KS5jYXRjaChhc3luYygpPT5mZXRjaChBUEkrJy9zdGF0dXMnLHtjYWNoZTonbm8tc3RvcmUnfSkpOwogICAgICAgIGNvbnN0IGJ1Zj1hd2FpdCByLmFycmF5QnVmZmVyKCk7CiAgICAgICAgaWYoZG9uZSkgYnJlYWs7CiAgICAgICAgdG90YWxCeXRlcys9YnVmLmJ5dGVMZW5ndGg7CiAgICAgICAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgICAgICAgY29uc3QgbWJwcz0odG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwogICAgICAgIG9uUHJvZ3Jlc3MoTWF0aC5taW4oZWxhcHNlZC9EVVJBVElPTl9NUyoxMDAsOTkpLG1icHMpOwogICAgICB9Y2F0Y2goZSl7YXdhaXQgbmV3IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkpO30KICAgIH0KICB9OwogIGF3YWl0IFByb21pc2UuYWxsKFtydW4oKSxydW4oKSxydW4oKSxydW4oKV0pOwogIGNvbnN0IGVsYXBzZWQ9KHBlcmZvcm1hbmNlLm5vdygpLXQwKS8xMDAwOwogIHJldHVybiAodG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwp9CmFzeW5jIGZ1bmN0aW9uIHJ1blVwbG9hZFRlc3Qob25Qcm9ncmVzcykgewogIGNvbnN0IERVUkFUSU9OX01TPTgwMDA7CiAgbGV0IHRvdGFsQnl0ZXM9MDsKICBjb25zdCB0MD1wZXJmb3JtYW5jZS5ub3coKTsKICBsZXQgZG9uZT1mYWxzZTsKICBzZXRUaW1lb3V0KCgpPT57ZG9uZT10cnVlO30sRFVSQVRJT05fTVMpOwogIGNvbnN0IENIVU5LPTUxMioxMDI0OwogIGNvbnN0IGRhdGE9bmV3IFVpbnQ4QXJyYXkoQ0hVTkspOwogIGNyeXB0by5nZXRSYW5kb21WYWx1ZXMoZGF0YSk7CiAgY29uc3QgYmxvYj1uZXcgQmxvYihbZGF0YV0pOwogIGNvbnN0IHJ1bj1hc3luYygpPT57CiAgICB3aGlsZSghZG9uZSl7CiAgICAgIHRyeXsKICAgICAgICBhd2FpdCBmZXRjaCgnaHR0cHM6Ly9zcGVlZC5jbG91ZGZsYXJlLmNvbS9fX3VwJyx7bWV0aG9kOidQT1NUJyxib2R5OmJsb2J9KS5jYXRjaCgoKT0+CiAgICAgICAgICBmZXRjaChBUEkrJy9zdGF0dXMnLHttZXRob2Q6J1BPU1QnLGJvZHk6YmxvYixoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vb2N0ZXQtc3RyZWFtJ319KS5jYXRjaCgoKT0+KHtvazpmYWxzZX0pKQogICAgICAgICk7CiAgICAgICAgaWYoZG9uZSkgYnJlYWs7CiAgICAgICAgdG90YWxCeXRlcys9Q0hVTks7CiAgICAgICAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgICAgICAgY29uc3QgbWJwcz0odG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwogICAgICAgIG9uUHJvZ3Jlc3MoTWF0aC5taW4oZWxhcHNlZC9EVVJBVElPTl9NUyoxMDAsOTkpLG1icHMpOwogICAgICB9Y2F0Y2goZSl7YXdhaXQgbmV3IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkpO30KICAgIH0KICB9OwogIGF3YWl0IFByb21pc2UuYWxsKFtydW4oKSxydW4oKSxydW4oKV0pOwogIGNvbnN0IGVsYXBzZWQ9KHBlcmZvcm1hbmNlLm5vdygpLXQwKS8xMDAwOwogIHJldHVybiAodG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwp9CgovLyBzdygpIOC5gOC4nuC4tOC5iOC4oSBzcGVlZCB0YWIgc3VwcG9ydAoKbG9hZERhc2goKTsKbG9hZFNlcnZpY2VzKCk7CnNldEludGVydmFsKGxvYWREYXNoLCAzMDAwMCk7Cjwvc2NyaXB0PgoKPCEtLSBTU0ggUkVORVcgTU9EQUwgLS0+CjxkaXYgY2xhc3M9Im1vdmVyIiBpZD0ic3NoLXJlbmV3LW1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNsb3NlU1NIUmVuZXdNb2RhbCgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCBTU0ggVXNlcjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJtY2xvc2UiIG9uY2xpY2s9ImNsb3NlU1NIUmVuZXdNb2RhbCgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIFVzZXJuYW1lPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9InNzaC1yZW5ldy11c2VybmFtZSI+LS08L3NwYW4+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImZnIiBzdHlsZT0ibWFyZ2luLXRvcDoxNHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZ4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+CiAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gtcmVuZXctZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSIgcGxhY2Vob2xkZXI9IjMwIj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9InNzaC1yZW5ldy1idG4iIG9uY2xpY2s9ImRvU1NIUmVuZXcoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4reC4reC4suC4ouC4uDwvYnV0dG9uPgogIDwvZGl2Pgo8L2Rpdj4KCgo8c2NyaXB0PgovLyBGaXJlZmxpZXMgeDYwIOKAkyBpbnNpZGUgY2FyZHMgKGFic29sdXRlLCDguYTguKHguYjguYPguIrguYggZml4ZWQpCjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/sshws.html
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
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30qOmZvY3Vze291dGxpbmU6bm9uZTt9Kjpmb2N1cy12aXNpYmxle291dGxpbmU6bm9uZTt9CiAgYm9keXtiYWNrZ3JvdW5kOnZhcigtLWJnKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtjb2xvcjp2YXIoLS10eHQpO21pbi1oZWlnaHQ6MTAwdmg7b3ZlcmZsb3cteDpoaWRkZW47fQogIC53cmFwe21heC13aWR0aDo0ODBweDttYXJnaW46MCBhdXRvO3BhZGRpbmctYm90dG9tOjUwcHg7fQogIC5oZHJ7YmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUscmdiYSgxMjQsNTgsMjM3LDAuMjUpIDAlLHRyYW5zcGFyZW50IDYwJSkscmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLHJnYmEoMzcsOTksMjM1LDAuMikgMCUsdHJhbnNwYXJlbnQgNjAlKSxsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwMzA1MGYgMCUsIzA4MGQxZiA1MCUsIzA1MDgxMCAxMDAlKTtwYWRkaW5nOjIwcHggMjBweCAxOHB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KCgoKCiAgLyogTkFWIHBpbGwgc3R5bGUgKi8KICAubmF2LXdyYXB7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCMwODBkMWYgMCUsIzBjMTQyOCAxMDAlKTtwYWRkaW5nOjEwcHggMTBweCAwO3Bvc2l0aW9uOnN0aWNreTt0b3A6MDt6LWluZGV4Ojk5OTk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA2KTtib3gtc2hhZG93OjAgNHB4IDIwcHggcmdiYSgwLDAsMCwwLjMpO292ZXJmbG93OmhpZGRlbjt9CiAgLm5hdi1mZntwb3NpdGlvbjphYnNvbHV0ZTtib3JkZXItcmFkaXVzOjUwJTtwb2ludGVyLWV2ZW50czpub25lO2FuaW1hdGlvbjpuZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLG5mZi1ibGluayBlYXNlLWluLW91dCBpbmZpbml0ZTtvcGFjaXR5OjA7ei1pbmRleDoxO30KICBAa2V5ZnJhbWVzIG5mZi1kcmlmdHsKICAgIDAle3RyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKX0KICAgIDI1JXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MSksdmFyKC0tZHkxKSl9CiAgICA1MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDIpLHZhcigtLWR5MikpfQogICAgNzUle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgzKSx2YXIoLS1keTMpKX0KICAgIDEwMCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSgwLDApfQogIH0KICBAa2V5ZnJhbWVzIG5mZi1ibGlua3sKICAgIDAlLDEwMCV7b3BhY2l0eTowfQogICAgMzAle29wYWNpdHk6MX0KICAgIDUwJXtvcGFjaXR5OjAuODV9CiAgICA3MCV7b3BhY2l0eTowfQogIH0KICAvKiBkdXBsaWNhdGUga2V5ZnJhbWVzIHJlbW92ZWQgKi8KICAubmF2e2Rpc3BsYXk6ZmxleDtnYXA6NHB4O292ZXJmbG93LXg6YXV0bztzY3JvbGxiYXItd2lkdGg6bm9uZTtwYWRkaW5nLWJvdHRvbToxMHB4O30KICAubmF2Ojotd2Via2l0LXNjcm9sbGJhcntkaXNwbGF5Om5vbmU7fQogIC5uYXYtaXRlbXtmbGV4LXNocmluazowO3BhZGRpbmc6OXB4IDE2cHg7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC40KTt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt3aGl0ZS1zcGFjZTpub3dyYXA7Ym9yZGVyLXJhZGl1czo5OTlweDtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjEwKTtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNSk7dHJhbnNpdGlvbjp0cmFuc2Zvcm0gMC4xNHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSxib3gtc2hhZG93IDAuMTRzIGVhc2UsYmFja2dyb3VuZCAwLjE0cyBlYXNlLGNvbG9yIDAuMTRzIGVhc2UsYm9yZGVyLWNvbG9yIDAuMTRzIGVhc2U7bGV0dGVyLXNwYWNpbmc6MC4zcHg7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lOy13ZWJraXQtdGFwLWhpZ2hsaWdodC1jb2xvcjp0cmFuc3BhcmVudDt1c2VyLXNlbGVjdDpub25lO2JveC1zaGFkb3c6MCA0cHggMCByZ2JhKDAsMCwwLDAuNDUpLDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEwKSBpbnNldDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgwKTt3aWxsLWNoYW5nZTp0cmFuc2Zvcm07fQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSl7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjc1KTtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wOSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4yMCk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTNweCk7Ym94LXNoYWRvdzowIDdweCAwIHJnYmEoMCwwLDAsMC40NSksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTIpIGluc2V0O30KICAubmF2LWl0ZW0uYWN0aXZle2NvbG9yOiNmZmY7Zm9udC13ZWlnaHQ6ODAwO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE2MGRlZywjMzRkNDcwIDAlLCMyMmM1NWUgNDUlLCMxNTgwM2QgMTAwJSk7Ym9yZGVyLWNvbG9yOnRyYW5zcGFyZW50O2JveC1zaGFkb3c6MCA1cHggMCByZ2JhKDEwLDYwLDIwLDAuNTUpLDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjMwKSBpbnNldCwwIDAgMTRweCByZ2JhKDM0LDE5Nyw5NCwwLjM1KTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtM3B4KTtib3JkZXItcmFkaXVzOjk5OXB4O291dGxpbmU6bm9uZTstd2Via2l0LXRhcC1oaWdobGlnaHQtY29sb3I6dHJhbnNwYXJlbnQ7dHJhbnNpdGlvbjp0cmFuc2Zvcm0gMC4xNHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSxib3gtc2hhZG93IDAuMTRzIGVhc2U7fQogIC5uYXYtaXRlbTphY3RpdmU6bm90KC5hY3RpdmUpe3RyYW5zZm9ybTp0cmFuc2xhdGVZKC02cHgpIWltcG9ydGFudDtib3gtc2hhZG93OjAgMTBweCAwIHJnYmEoMCwwLDAsMC40NSksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTQpIGluc2V0IWltcG9ydGFudDt0cmFuc2l0aW9uOnRyYW5zZm9ybSAwLjA4cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLGJveC1zaGFkb3cgMC4wOHMgZWFzZSFpbXBvcnRhbnQ7fQogIC5uYXYtaXRlbS5hY3RpdmU6YWN0aXZle3RyYW5zZm9ybTp0cmFuc2xhdGVZKC02cHgpIWltcG9ydGFudDtib3gtc2hhZG93OjAgMTBweCAwIHJnYmEoMTAsNjAsMjAsMC41NSksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMzUpIGluc2V0LDAgMCAyMHB4IHJnYmEoMzQsMTk3LDk0LDAuNSkhaW1wb3J0YW50O3RyYW5zaXRpb246dHJhbnNmb3JtIDAuMDhzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksYm94LXNoYWRvdyAwLjA4cyBlYXNlIWltcG9ydGFudDt9CiAgLm5hdi1pdGVtLm5hdi1zcGVlZC5hY3RpdmV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMyMmQzZWUgMCUsIzA2YjZkNCA0NSUsIzA4OTFiMiAxMDAlKSFpbXBvcnRhbnQ7Ym94LXNoYWRvdzowIDVweCAwIHJnYmEoNCw3MCw5MCwwLjU1KSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4zMCkgaW5zZXQsMCAwIDE0cHggcmdiYSg2LDE4MiwyMTIsMC4zNSkhaW1wb3J0YW50O3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0zcHgpIWltcG9ydGFudDt9CiAgLm5hdi1pdGVtLm5hdi1zcGVlZDpob3Zlcjpub3QoLmFjdGl2ZSl7Y29sb3I6IzA2YjZkNDtib3JkZXItY29sb3I6cmdiYSg2LDE4MiwyMTIsMC4zKTt9CiAgLnNlY3twYWRkaW5nOjE0cHg7ZGlzcGxheTpub25lO2FuaW1hdGlvbjpmaSAuM3MgZWFzZTt9CiAgLnNlYy5hY3RpdmV7ZGlzcGxheTpibG9jazt9CiAgQGtleWZyYW1lcyBmaXtmcm9te29wYWNpdHk6MDt0cmFuc2Zvcm06dHJhbnNsYXRlWSg2cHgpfXRve29wYWNpdHk6MTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgwKX19CiAgLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxNHB4O3BhZGRpbmc6MTZweDttYXJnaW4tYm90dG9tOjEwcHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNlYy1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zZWMtdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmJ0bi1ye2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo2cHggMTRweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO30KICAuYnRuLXI6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5zZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuc2N7YmFja2dyb3VuZDp2YXIoLS1jYXJkKTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxNHB4O3BhZGRpbmc6MTRweDtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO30KICAuc2xibHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zdmFse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10eHQpO2xpbmUtaGVpZ2h0OjE7fQogIC5zdmFsIHNwYW57Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLnNzdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6NHB4O30KICAuZG51dHtwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDo1MnB4O2hlaWdodDo1MnB4O21hcmdpbjo0cHggYXV0byA0cHg7fQogIC5kbnV0IHN2Z3t0cmFuc2Zvcm06cm90YXRlKC05MGRlZyk7fQogIC5kYmd7ZmlsbDpub25lO3N0cm9rZTpyZ2JhKDAsMCwwLDAuMDYpO3N0cm9rZS13aWR0aDo0O30KICAuZHZ7ZmlsbDpub25lO3N0cm9rZS13aWR0aDo0O3N0cm9rZS1saW5lY2FwOnJvdW5kO3RyYW5zaXRpb246c3Ryb2tlLWRhc2hvZmZzZXQgMXMgZWFzZTt9CiAgLmRje3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10eHQpO30KICAucGJ7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsMC4wNik7Ym9yZGVyLXJhZGl1czoycHg7bWFyZ2luLXRvcDo4cHg7b3ZlcmZsb3c6aGlkZGVuO30KICAucGZ7aGVpZ2h0OjEwMCU7Ym9yZGVyLXJhZGl1czoycHg7dHJhbnNpdGlvbjp3aWR0aCAxcyBlYXNlO30KICAucGYucHV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdmFyKC0tYWMpLCMxNmEzNGEpO30KICAucGYucGd7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdmFyKC0tbmcpLCMxNmEzNGEpO30KICAucGYucG97YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2ZiOTIzYywjZjk3MzE2KTt9CiAgLnBmLnBye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNlZjQ0NDQsI2RjMjYyNik7fQogIC51YmRne2Rpc3BsYXk6ZmxleDtnYXA6NXB4O2ZsZXgtd3JhcDp3cmFwO21hcmdpbi10b3A6OHB4O30KICAuYmRne2JhY2tncm91bmQ6I2YxZjVmOTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggOHB4O2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLm5ldC1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2dhcDoxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLm5pe2ZsZXg6MTt9CiAgLm5ke2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLWFjKTttYXJnaW4tYm90dG9tOjNweDt9CiAgLm5ze2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyMHB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjp2YXIoLS10eHQpO30KICAubnMgc3Bhbntmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC13ZWlnaHQ6NDAwO30KICAubnR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuZGl2aWRlcnt3aWR0aDoxcHg7YmFja2dyb3VuZDp2YXIoLS1ib3JkZXIpO21hcmdpbjo0cHggMDt9CiAgLm9waWxse2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMyk7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6NXB4IDE0cHg7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbmcpO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo1cHg7d2hpdGUtc3BhY2U6bm93cmFwO30KICAub3BpbGwub2Zme2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4zKTtjb2xvcjojZWY0NDQ0O30KICAuZG90e3dpZHRoOjVweDtoZWlnaHQ6NXB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6dmFyKC0tbmcpO2JveC1zaGFkb3c6MCAwIDNweCB2YXIoLS1uZyk7YW5pbWF0aW9uOnBscyA0cyBlYXNlLWluLW91dCBpbmZpbml0ZTt9CiAgLmRvdC5yZWR7YmFja2dyb3VuZDojZWY0NDQ0O2JveC1zaGFkb3c6MCAwIDRweCAjZWY0NDQ0O30KICBAa2V5ZnJhbWVzIHBsc3swJSwxMDAle29wYWNpdHk6Ljk7Ym94LXNoYWRvdzowIDAgMnB4IHZhcigtLW5nKX01MCV7b3BhY2l0eTouNjtib3gtc2hhZG93OjAgMCA0cHggdmFyKC0tbmcpfX0KICAueHVpLXJvd3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLnh1aS1pbmZve2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtsaW5lLWhlaWdodDoxLjc7fQogIC54dWktaW5mbyBie2NvbG9yOnZhcigtLXR4dCk7fQogIC5zdmMtbGlzdHtkaXNwbGF5OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2dhcDo4cHg7bWFyZ2luLXRvcDoxMHB4O30KICAuc3Zje2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4wNSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjExcHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO30KICAuc3ZjLmRvd257YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjA1KTtib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsMC4yKTt9CiAgLnN2Yy1se2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7fQogIC8qIC5kZyBzdHlsZXMgZGVmaW5lZCBiZWxvdyB3aXRoIHBpbmcgYW5pbWF0aW9uICovCiAgLmRnLnJlZHtiYWNrZ3JvdW5kOiNlZjQ0NDQ7Ym94LXNoYWRvdzowIDAgNHB4ICNlZjQ0NDQ7fQogIC5zdmMtbntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnN2Yy1we2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLnJiZGd7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4zKTtib3JkZXItcmFkaXVzOjZweDtwYWRkaW5nOjNweCAxMHB4O2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW5nKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoxcHg7fQogIC5yYmRnLmRvd257YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEpO2JvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwwLjMpO2NvbG9yOiNlZjQ0NDQ7fQogIC5sdXt0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDoxNHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLmZ0aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo4cHg7fQogIC5pbmZvLWJveHtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTRweDt9CiAgLnB0Z2x7ZGlzcGxheTpmbGV4O2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucGJ0bntmbGV4OjE7cGFkZGluZzo5cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXI7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JhY2tncm91bmQ6I2Y4ZmFmYztjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO30KICAucGJ0bi5hY3RpdmV7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuZmd7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuZmxibHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7b3BhY2l0eTouODttYXJnaW4tYm90dG9tOjVweDt9CiAgLmZpe3dpZHRoOjEwMCU7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjlweDtwYWRkaW5nOjEwcHggMTRweDtmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO291dGxpbmU6bm9uZTt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5maTpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWMpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHZhcigtLWFjLWRpbSk7fQogIC50Z2x7ZGlzcGxheTpmbGV4O2dhcDo4cHg7fQogIC50YnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC50YnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5jYnRue3dpZHRoOjEwMCU7cGFkZGluZzoxNHB4O2JvcmRlci1yYWRpdXM6MTBweDtmb250LXNpemU6MTRweDtmb250LXdlaWdodDo3MDA7Y3Vyc29yOnBvaW50ZXI7Ym9yZGVyOm5vbmU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMxNmEzNGEsIzIyYzU1ZSwjNGFkZTgwKTtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2xldHRlci1zcGFjaW5nOi41cHg7Ym94LXNoYWRvdzowIDRweCAxNXB4IHJnYmEoMzQsMTk3LDk0LC4zKTt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5jYnRuOmhvdmVye2JveC1zaGFkb3c6MCA2cHggMjBweCByZ2JhKDM0LDE5Nyw5NCwuNDUpO3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0xcHgpO30KICAuY2J0bjpkaXNhYmxlZHtvcGFjaXR5Oi41O2N1cnNvcjpub3QtYWxsb3dlZDt0cmFuc2Zvcm06bm9uZTt9CiAgLnNib3h7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEwcHggMTRweDtmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO291dGxpbmU6bm9uZTttYXJnaW4tYm90dG9tOjEycHg7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzO30KICAuc2JveDpmb2N1c3tib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAudWl0ZW17YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMnB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjhweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzowIDFweCA0cHggcmdiYSgwLDAsMCwwLjA0KTt9CiAgLnVpdGVtOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO30KICAudWF2e3dpZHRoOjM2cHg7aGVpZ2h0OjM2cHg7Ym9yZGVyLXJhZGl1czo5cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tcmlnaHQ6MTJweDtmbGV4LXNocmluazowO30KICAuYXYtZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMTUpO2NvbG9yOnZhcigtLW5nKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLmF2LXJ7YmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLDAuMTUpO2NvbG9yOiNmODcxNzE7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI0OCwxMTMsMTEzLC4yKTt9CiAgLmF2LXh7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEyKTtjb2xvcjojZWY0NDQ0O2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjIpO30KICAudW57Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC51bXtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDoycHg7fQogIC5hYmRne2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5hYmRnLm9re2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LC4zKTtjb2xvcjp2YXIoLS1uZyk7fQogIC5hYmRnLmV4cHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmFiZGcuc29vbntiYWNrZ3JvdW5kOnJnYmEoMjUxLDE0Niw2MCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTEsMTQ2LDYwLC4zKTtjb2xvcjojZjk3MzE2O30KICAubW92ZXJ7cG9zaXRpb246Zml4ZWQ7aW5zZXQ6MDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjUpO2JhY2tkcm9wLWZpbHRlcjpibHVyKDZweCk7ei1pbmRleDo5OTk5O2Rpc3BsYXk6bm9uZTthbGlnbi1pdGVtczpmbGV4LWVuZDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAubW92ZXIub3BlbntkaXNwbGF5OmZsZXg7fQogIC5tb2RhbHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MjBweCAyMHB4IDAgMDt3aWR0aDoxMDAlO21heC13aWR0aDo0ODBweDtwYWRkaW5nOjIwcHg7bWF4LWhlaWdodDo4NXZoO292ZXJmbG93LXk6YXV0bzthbmltYXRpb246c3UgLjNzIGVhc2U7Ym94LXNoYWRvdzowIC00cHggMzBweCByZ2JhKDAsMCwwLDAuMTIpO30KICBAa2V5ZnJhbWVzIHN1e2Zyb217dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMTAwJSl9dG97dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5taGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxNnB4O30KICAubXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNHB4O2NvbG9yOnZhcigtLXR4dCk7fQogIC5tY2xvc2V7d2lkdGg6MzJweDtoZWlnaHQ6MzJweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2NvbG9yOnZhcigtLW11dGVkKTtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5kZ3JpZHtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tYm90dG9tOjE0cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHJ7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcjtwYWRkaW5nOjdweCAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcjpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmRre2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmR2e2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC13ZWlnaHQ6NjAwO30KICAuZHYuZ3JlZW57Y29sb3I6dmFyKC0tbmcpO30KICAuZHYucmVke2NvbG9yOiNlZjQ0NDQ7fQogIC5kdi5tb25ve2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6OXB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO3dvcmQtYnJlYWs6YnJlYWstYWxsO30KICAuYWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7fQogIC5tLXN1YntkaXNwbGF5Om5vbmU7bWFyZ2luLXRvcDoxNHB4O2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMnB4O3BhZGRpbmc6MTRweDt9CiAgLm0tc3ViLm9wZW57ZGlzcGxheTpibG9jazthbmltYXRpb246ZmkgLjJzIGVhc2U7fQogIC5tc3ViLWxibHtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5hYnRue2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweCAxMHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmFidG46aG92ZXJ7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC5hYnRuIC5haXtmb250LXNpemU6MjJweDttYXJnaW4tYm90dG9tOjZweDt9CiAgLmFidG4gLmFue2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuYWJ0biAuYWR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi10b3A6MnB4O30KICAuYWJ0bi5kYW5nZXI6aG92ZXJ7YmFja2dyb3VuZDpyZ2JhKDI0OCwxMTMsMTEzLC4xKTtib3JkZXItY29sb3I6I2Y4NzE3MTt9CiAgLm9le3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6NDBweCAyMHB4O30KICAub2UgLmVpe2ZvbnQtc2l6ZTo0OHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLm9lIHB7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxM3B4O30KICAub2Nye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxNnB4O30KICAudXR7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAvKiByZXN1bHQgYm94ICovCiAgLnJlcy1ib3h7cG9zaXRpb246cmVsYXRpdmU7YmFja2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi10b3A6MTRweDtkaXNwbGF5Om5vbmU7fQogIC5yZXMtYm94LnNob3d7ZGlzcGxheTpibG9jazt9CiAgLnJlcy1jbG9zZXtwb3NpdGlvbjphYnNvbHV0ZTt0b3A6LTExcHg7cmlnaHQ6LTExcHg7d2lkdGg6MjJweDtoZWlnaHQ6MjJweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiNlZjQ0NDQ7Ym9yZGVyOjJweCBzb2xpZCAjZmZmO2NvbG9yOiNmZmY7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjExcHg7Zm9udC13ZWlnaHQ6NzAwO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtsaW5lLWhlaWdodDoxO2JveC1zaGFkb3c6MCAxcHggNHB4IHJnYmEoMjM5LDY4LDY4LDAuNCk7ei1pbmRleDoyO30KICAucmVzLXJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47cGFkZGluZzo1cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCAjZGNmY2U3O2ZvbnQtc2l6ZToxM3B4O30KICAucmVzLXJvdzpsYXN0LWNoaWxke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLnJlcy1re2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTFweDt9CiAgLnJlcy12e2NvbG9yOnZhcigtLXR4dCk7Zm9udC13ZWlnaHQ6NjAwO3dvcmQtYnJlYWs6YnJlYWstYWxsO3RleHQtYWxpZ246cmlnaHQ7bWF4LXdpZHRoOjY1JTt9CiAgLnJlcy1saW5re2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDttYXJnaW4tdG9wOjhweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jb3B5LWJ0bnt3aWR0aDoxMDAlO21hcmdpbi10b3A6OHB4O3BhZGRpbmc6OHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYWMtYm9yZGVyKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Y29sb3I6dmFyKC0tYWMpO2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAvKiBhbGVydCAqLwogIC5hbGVydHtkaXNwbGF5Om5vbmU7cGFkZGluZzoxMHB4IDE0cHg7Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOjEycHg7bWFyZ2luLXRvcDoxMHB4O30KICAuYWxlcnQub2t7YmFja2dyb3VuZDojZjBmZGY0O2JvcmRlcjoxcHggc29saWQgIzg2ZWZhYztjb2xvcjojMTU4MDNkO30KICAuYWxlcnQuZXJye2JhY2tncm91bmQ6I2ZlZjJmMjtib3JkZXI6MXB4IHNvbGlkICNmY2E1YTU7Y29sb3I6I2RjMjYyNjt9CiAgLyogc3Bpbm5lciAqLwogIC5zcGlue2Rpc3BsYXk6aW5saW5lLWJsb2NrO3dpZHRoOjEycHg7aGVpZ2h0OjEycHg7Ym9yZGVyOjJweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4zKTtib3JkZXItdG9wLWNvbG9yOiNmZmY7Ym9yZGVyLXJhZGl1czo1MCU7YW5pbWF0aW9uOnNwIC43cyBsaW5lYXIgaW5maW5pdGU7dmVydGljYWwtYWxpZ246bWlkZGxlO21hcmdpbi1yaWdodDo0cHg7fQogIEBrZXlmcmFtZXMgc3B7dG97dHJhbnNmb3JtOnJvdGF0ZSgzNjBkZWcpfX0KICAubG9hZGluZ3t0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjMwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxM3B4O30KCgogIC8qIOKUgOKUgCBEQVJLIEZPUk0gKFNTSCkg4pSA4pSAICovCiAgLnNzaC1kYXJrLWZvcm17YmFja2dyb3VuZDojMGQxMTE3O2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE4cHggMTZweDttYXJnaW4tYm90dG9tOjA7fQogIC5kYXJrLWZpZWxke21hcmdpbi1ib3R0b206MTJweDt9CiAgLmRhcmstbGFiZWx7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7bGV0dGVyLXNwYWNpbmc6MXB4O2Rpc3BsYXk6YmxvY2s7bWFyZ2luLWJvdHRvbTo1cHg7fQogIC5kYXJrLWlucHV0e3dpZHRoOjEwMCU7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNik7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4xKTtjb2xvcjojZThmNGZmO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEwcHggMTRweDtmb250LXNpemU6MTNweDtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjtvdXRsaW5lOm5vbmU7dHJhbnNpdGlvbjpib3JkZXItY29sb3IgLjJzO30KICAuZGFyay1pbnB1dDpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5kYXJrLWhkcntmb250LXNpemU6MTNweDtjb2xvcjpyZ2JhKDAsMjAwLDI1NSwuOCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MnB4O21hcmdpbi1ib3R0b206MTRweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZnIC5mbGJse2NvbG9yOnJnYmEoMTgwLDIyMCwyNTUsLjUpO2ZvbnQtc2l6ZTo5cHg7fQogIC5zc2gtZGFyay1mb3JtIC5maXtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA2KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2NvbG9yOiNlOGY0ZmY7Ym9yZGVyLXJhZGl1czoxMHB4O30KICAuc3NoLWRhcmstZm9ybSAuZmk6Zm9jdXN7Ym9yZGVyLWNvbG9yOnJnYmEoMCwyMDAsMjU1LC41KTtib3gtc2hhZG93OjAgMCAwIDNweCByZ2JhKDAsMjAwLDI1NSwuMDgpO30KICAuc3NoLWRhcmstZm9ybSAuZmk6OnBsYWNlaG9sZGVye2NvbG9yOnJnYmEoMTgwLDIyMCwyNTUsLjI1KTt9CiAgLmRhcmstbGJse2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnJnYmEoMCwyMDAsMjU1LC43KTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoycHg7bWFyZ2luLWJvdHRvbToxMHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweDt9CiAgLyogUG9ydCBwaWNrZXIgKi8KICAucG9ydC1ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O21hcmdpbi1ib3R0b206MTRweDt9CiAgLnBvcnQtYnRue2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDQpO2JvcmRlcjoxLjVweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4xKTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNHB4IDhweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wb3J0LWJ0biAucGItaWNvbntmb250LXNpemU6MS40cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucG9ydC1idG4gLnBiLW5hbWV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5wb3J0LWJ0biAucGItc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsLjM1KTt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wODB7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgwLDIwMCwyNTUsLjE1KTt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wODAgLnBiLW5hbWV7Y29sb3I6IzAwY2NmZjt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wNDQze2JvcmRlci1jb2xvcjojZmJiZjI0O2JhY2tncm91bmQ6cmdiYSgyNTEsMTkxLDM2LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDI1MSwxOTEsMzYsLjEyKTt9CiAgLnBvcnQtYnRuLmFjdGl2ZS1wNDQzIC5wYi1uYW1le2NvbG9yOiNmYmJmMjQ7fQogIC8qIE9wZXJhdG9yIHBpY2tlciAqLwogIC5waWNrLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucGljay1vcHR7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjA4KTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxMnB4IDhweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5waWNrLW9wdCAucGl7Zm9udC1zaXplOjEuNXJlbTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnBpY2stb3B0IC5wbntmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6LjdyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206MnB4O30KICAucGljay1vcHQgLnBze2ZvbnQtc2l6ZTo5cHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMyk7fQogIC5waWNrLW9wdC5hLWR0YWN7Ym9yZGVyLWNvbG9yOiNmZjY2MDA7YmFja2dyb3VuZDpyZ2JhKDI1NSwxMDIsMCwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDI1NSwxMDIsMCwuMTUpO30KICAucGljay1vcHQuYS1kdGFjIC5wbntjb2xvcjojZmY4ODMzO30KICAucGljay1vcHQuYS10cnVle2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdiYSgwLDIwMCwyNTUsLjEpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtdHJ1ZSAucG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtbnB2e2JvcmRlci1jb2xvcjojMDBjY2ZmO2JhY2tncm91bmQ6cmdiYSgwLDIwMCwyNTUsLjA4KTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMCwyMDAsMjU1LC4xMik7fQogIC5waWNrLW9wdC5hLW5wdiAucG57Y29sb3I6IzAwY2NmZjt9CiAgLnBpY2stb3B0LmEtZGFya3tib3JkZXItY29sb3I6I2NjNjZmZjtiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgxNTMsNTEsMjU1LC4xKTt9CiAgLnBpY2stb3B0LmEtZGFyayAucG57Y29sb3I6I2NjNjZmZjt9CiAgLnBpY2stb3B0LmEtaGl7Ym9yZGVyLWNvbG9yOiNjYzAwZmY7YmFja2dyb3VuZDpyZ2JhKDIwNCwwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDIwNCwwLDI1NSwuMik7fQogIC5waWNrLW9wdC5hLWhpIC5wbntjb2xvcjojZGQ0NGZmO30KICAucGljay1vcHQuYS1oY3tib3JkZXItY29sb3I6IzAwOTlmZjtiYWNrZ3JvdW5kOnJnYmEoMCwxNTMsMjU1LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMCwxNTMsMjU1LC4yKTt9CiAgLnBpY2stb3B0LmEtaGMgLnBue2NvbG9yOiMzM2FhZmY7fQogIC5waWNrLW9wdC5hLWhhdHtib3JkZXItY29sb3I6I2ZmY2MwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDIwNCwwLC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjU1LDIwNCwwLC4yKTt9CiAgLnBpY2stb3B0LmEtaGF0IC5wbntjb2xvcjojZmZkZDMzO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9CgogIC8qIOKUgOKUgCBIRFIgbG9nbyBhbmltYXRpb25zIChzYW1lIGFzIGxvZ2luKSDilIDilIAgKi8KICBAa2V5ZnJhbWVzIGhkci1vcmJpdC1kYXNoIHsKICAgIGZyb20geyBzdHJva2UtZGFzaG9mZnNldDogMDsgfQogICAgdG8gICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAtMjUxOyB9CiAgfQogIEBrZXlmcmFtZXMgaGRyLXB1bHNlLWRyYXcgewogICAgMCUgICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7IG9wYWNpdHk6IDA7IH0KICAgIDE1JSAgeyBvcGFjaXR5OiAxOyB9CiAgICAxMDAlIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItYmxpbmstZG90IHsKICAgIDAlLCAxMDAlIHsgb3BhY2l0eTogMC4yNTsgfQogICAgNTAlICAgICAgIHsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGhkci1sb2dvLWdsb3cgewogICAgMCUsIDEwMCUgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA2cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDE0cHggIzI1NjNlYik7IH0KICAgIDUwJSAgICAgICB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDE0cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDI4cHggIzI1NjNlYikgZHJvcC1zaGFkb3coMCAwIDQycHggIzA2YjZkNCk7IH0KICB9CiAgLmhkci1sb2dvLXN2Zy13cmFwIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDhweDsKICAgIGFuaW1hdGlvbjogaGRyLWxvZ28tZ2xvdyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgLmhkci1vcmJpdC1yaW5nIHsgdHJhbnNmb3JtLW9yaWdpbjogNTBweCA1MHB4OyBhbmltYXRpb246IGhkci1vcmJpdC1kYXNoIDhzIGxpbmVhciBpbmZpbml0ZTsgfQogIC5oZHItd2F2ZS1hbmltICB7IHN0cm9rZS1kYXNoYXJyYXk6MjIwOyBzdHJva2UtZGFzaG9mZnNldDoyMjA7IGFuaW1hdGlvbjogaGRyLXB1bHNlLWRyYXcgMS42cyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKSAwLjVzIGZvcndhcmRzOyB9CiAgLmhkci1kb3QtMSB7IGFuaW1hdGlvbjogaGRyLWJsaW5rLWRvdCAyLjJzIGVhc2UtaW4tb3V0IDEuOHMgaW5maW5pdGU7IH0KICAuaGRyLWRvdC0yIHsgYW5pbWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMi4ycyBpbmZpbml0ZTsgfQoKICAvKiDilIDilIAgRGFzaGJvYXJkIEZpcmVmbGllcyAoZnVsbCBwYWdlKSDilIDilIAgKi8KICAuZGFzaC1mZiB7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIHotaW5kZXg6IDA7CiAgICBhbmltYXRpb246IGRhc2gtZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLCBkYXNoLWZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgb3BhY2l0eTogMDsKICB9CiAgQGtleWZyYW1lcyBkYXNoLWZmLWRyaWZ0IHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgICAyMCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpOyB9CiAgICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgzKSx2YXIoLS1keTMpKSBzY2FsZSgxLjA1KTsgfQogICAgODAlICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgfQogIEBrZXlmcmFtZXMgZGFzaC1mZi1ibGluayB7CiAgICAwJSwxMDAleyBvcGFjaXR5OjA7IH0gMTUleyBvcGFjaXR5OjA7IH0gMzAleyBvcGFjaXR5OjE7IH0KICAgIDUwJXsgb3BhY2l0eTowLjk7IH0gNjUleyBvcGFjaXR5OjA7IH0gODAleyBvcGFjaXR5OjAuODU7IH0gOTIleyBvcGFjaXR5OjA7IH0KICB9CgogIC8qIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkAogICAgIDNEIENBUkRTIC8gVEFCUyAvIEJVVFRPTlMg4oCUIOC4l+C4uOC4geC4q+C4meC5ieC4sgogIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAqLwogIC5jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMjUpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDI0cHggcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAycHggOHB4IHJnYmEoMzQsMTk3LDk0LDAuMTIpLAogICAgICAwIDE2cHggMzJweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSB0cmFuc2xhdGVaKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVooMCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNHB4IDM2cHggcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDRweCAxNnB4IHJnYmEoMzQsMTk3LDk0LDAuMTgpLAogICAgICAwIDI0cHggNDhweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBOYXYgaXRlbXMgM0QgKi8KICAubmF2LWl0ZW0gewogICAgYm9yZGVyLXJhZGl1czogOTk5cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjEwKSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCA0cHggMCByZ2JhKDAsMCwwLDAuNDUpLCAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xMCkgaW5zZXQgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjE0cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLCBib3gtc2hhZG93IDAuMTRzIGVhc2UgIWltcG9ydGFudDsKICAgIG1hcmdpbjogMCAycHg7CiAgICBwYWRkaW5nOiA5cHggMTZweCAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApOwogICAgb3V0bGluZTogbm9uZSAhaW1wb3J0YW50OwogICAgLXdlYmtpdC10YXAtaGlnaGxpZ2h0LWNvbG9yOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgdXNlci1zZWxlY3Q6IG5vbmUgIWltcG9ydGFudDsKICAgIHdpbGwtY2hhbmdlOiB0cmFuc2Zvcm07CiAgfQogIC5uYXYtaXRlbS5hY3RpdmUgewogICAgYm9yZGVyLXJhZGl1czogOTk5cHggIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtM3B4KSAhaW1wb3J0YW50OwogICAgYm9yZGVyLWNvbG9yOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDE2MGRlZywjMzRkNDcwIDAlLCMyMmM1NWUgNDUlLCMxNTgwM2QgMTAwJSkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgNXB4IDAgcmdiYSgxMCw2MCwyMCwwLjU1KSwgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMzApIGluc2V0LCAwIDAgMTRweCByZ2JhKDM0LDE5Nyw5NCwwLjM1KSAhaW1wb3J0YW50OwogICAgY29sb3I6ICNmZmYgIWltcG9ydGFudDsKICAgIGZvbnQtd2VpZ2h0OiA4MDAgIWltcG9ydGFudDsKICAgIHBhZGRpbmc6IDlweCAxNnB4ICFpbXBvcnRhbnQ7CiAgICBvdXRsaW5lOiBub25lICFpbXBvcnRhbnQ7CiAgICAtd2Via2l0LXRhcC1oaWdobGlnaHQtY29sb3I6IHRyYW5zcGFyZW50ICFpbXBvcnRhbnQ7CiAgfQogIC5uYXYtaXRlbS5hY3RpdmU6YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtNnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCAxMHB4IDAgcmdiYSgxMCw2MCwyMCwwLjU1KSwgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMzUpIGluc2V0LCAwIDAgMjBweCByZ2JhKDM0LDE5Nyw5NCwwLjUpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwgYm94LXNoYWRvdyAwLjA4cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSkgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpICFpbXBvcnRhbnQ7CiAgICBib3JkZXItY29sb3I6IHJnYmEoMjU1LDI1NSwyNTUsMC4yMCkgIWltcG9ydGFudDsKICAgIGJhY2tncm91bmQ6IHJnYmEoMjU1LDI1NSwyNTUsMC4wOSkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgN3B4IDAgcmdiYSgwLDAsMCwwLjQ1KSwgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTIpIGluc2V0ICFpbXBvcnRhbnQ7CiAgfQogIC5uYXYtaXRlbTphY3RpdmU6bm90KC5hY3RpdmUpIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtNnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzogMCAxMHB4IDAgcmdiYSgwLDAsMCwwLjQ1KSwgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTQpIGluc2V0ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwgYm94LXNoYWRvdyAwLjA4cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBBbGwgYnV0dG9ucyAzRCAqLwogIC5jYnRuLCAuYnRuLXIsIC5jYnRtLXNzaCwgLmJ0bi10YmwsIC5wYnRuLCAudGJ0biwKICAuY29weS1idG4sIC5jb3B5LWxpbmstYnRuLCAubG9nb3V0LCAubWNsb3NlLAogIC5hYnRuLCAucG9ydC1idG4sIC5waWNrLW9wdCB7CiAgICBib3JkZXItcmFkaXVzOiAxMnB4ICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDRweCAwIHJnYmEoMCwwLDAsMC4zNSksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEyKSBpbnNldCwKICAgICAgMCA2cHggMTZweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjEycyBlYXNlICFpbXBvcnRhbnQ7CiAgICBib3JkZXItd2lkdGg6IDJweCAhaW1wb3J0YW50OwogIH0KICAuY2J0bjpob3ZlciwgLmJ0bi1yOmhvdmVyLCAuY29weS1idG46aG92ZXIsCiAgLmFidG46aG92ZXIsIC5wb3J0LWJ0bjpob3ZlciwgLnBpY2stb3B0OmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpIGluc2V0LAogICAgICAwIDEwcHggMjRweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQogIC5jYnRuOmFjdGl2ZSwgLmJ0bi1yOmFjdGl2ZSwgLmNvcHktYnRuOmFjdGl2ZSwKICAuYWJ0bjphY3RpdmUsIC5wb3J0LWJ0bjphY3RpdmUsIC5waWNrLW9wdDphY3RpdmUsCiAgLmJ0bi10Ymw6YWN0aXZlLCAubG9nb3V0OmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoM3B4KSBzY2FsZSgwLjk3KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCAxcHggMCByZ2JhKDAsMCwwLDAuNCksCiAgICAgIDAgMCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA2cyBlYXNlLCBib3gtc2hhZG93IDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CgogIC8qIHNlbC1jYXJkIDNEICovCiAgLnNlbC1jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjIpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDIwcHggcmdiYSgwLDAsMCwwLjEyKSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVgoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xOHMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVgoMnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA4cHggMCByZ2JhKDAsMCwwLDAuMjUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNnB4IDMycHggcmdiYSgwLDAsMCwwLjE4KSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgycHgpIHRyYW5zbGF0ZVgoMCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KCiAgLyogdWl0ZW1zIDNEICovCiAgLnVpdGVtIHsKICAgIGJvcmRlci1yYWRpdXM6IDE0cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgM3B4IDAgcmdiYSgwLDAsMCwwLjE4KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDcpIGluc2V0LAogICAgICAwIDZweCAxNHB4IHJnYmEoMCwwLDAsMC4wOCkgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjE1cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjE1cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjIyKSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDkpIGluc2V0LAogICAgICAwIDEycHggMjRweCByZ2JhKDAsMCwwLDAuMTIpICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTphY3RpdmUgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDJweCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAvKiBib3VuY2Uga2V5ZnJhbWUg4Liq4Liz4Lir4Lij4Lix4Lia4LiB4LiUICovCiAgQGtleWZyYW1lcyBidG4tYm91bmNlIHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHNjYWxlKDEpOyB9CiAgICAzMCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjkzKSB0cmFuc2xhdGVZKDNweCk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDEuMDQpIHRyYW5zbGF0ZVkoLTJweCk7IH0KICAgIDgwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTgpIHRyYW5zbGF0ZVkoMXB4KTsgfQogICAgMTAwJSB7IHRyYW5zZm9ybTogc2NhbGUoMSkgdHJhbnNsYXRlWSgwKTsgfQogIH0KICAuY2J0bjphY3RpdmUsIC5idG4tcjphY3RpdmUsIC5jb3B5LWJ0bjphY3RpdmUgeyBhbmltYXRpb246IGJ0bi1ib3VuY2UgMC4yOHMgZWFzZSBmb3J3YXJkcyAhaW1wb3J0YW50OyB9CgogIC8qIE5hdiAzRCBwaWxscyBvdmVycmlkZSAqLwogIC5uYXYtaXRlbXtib3JkZXItcmFkaXVzOjk5OXB4IWltcG9ydGFudDtib3gtc2hhZG93OjAgNHB4IDAgcmdiYSgwLDAsMCwwLjQ1KSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xMCkgaW5zZXQhaW1wb3J0YW50O2JvcmRlci13aWR0aDoxLjVweCFpbXBvcnRhbnQ7cGFkZGluZzo5cHggMTZweCFpbXBvcnRhbnQ7b3V0bGluZTpub25lIWltcG9ydGFudDstd2Via2l0LXRhcC1oaWdobGlnaHQtY29sb3I6dHJhbnNwYXJlbnQhaW1wb3J0YW50O3VzZXItc2VsZWN0Om5vbmUhaW1wb3J0YW50O3dpbGwtY2hhbmdlOnRyYW5zZm9ybTt0cmFuc2l0aW9uOnRyYW5zZm9ybSAwLjE0cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLGJveC1zaGFkb3cgMC4xNHMgZWFzZSFpbXBvcnRhbnQ7fQogIC5uYXYtaXRlbS5hY3RpdmV7Ym9yZGVyLXJhZGl1czo5OTlweCFpbXBvcnRhbnQ7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTNweCkhaW1wb3J0YW50O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE2MGRlZywjMzRkNDcwIDAlLCMyMmM1NWUgNDUlLCMxNTgwM2QgMTAwJSkhaW1wb3J0YW50O2JvcmRlci1jb2xvcjp0cmFuc3BhcmVudCFpbXBvcnRhbnQ7Ym94LXNoYWRvdzowIDVweCAwIHJnYmEoMTAsNjAsMjAsMC41NSksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMzApIGluc2V0LDAgMCAxNHB4IHJnYmEoMzQsMTk3LDk0LDAuMzUpIWltcG9ydGFudDtjb2xvcjojZmZmIWltcG9ydGFudDtmb250LXdlaWdodDo4MDAhaW1wb3J0YW50O3BhZGRpbmc6OXB4IDE2cHghaW1wb3J0YW50O2ZvbnQtc2l6ZToxMXB4IWltcG9ydGFudDtvdXRsaW5lOm5vbmUhaW1wb3J0YW50Oy13ZWJraXQtdGFwLWhpZ2hsaWdodC1jb2xvcjp0cmFuc3BhcmVudCFpbXBvcnRhbnQ7fQogIC5uYXYtaXRlbS5hY3RpdmU6YWN0aXZle3RyYW5zZm9ybTp0cmFuc2xhdGVZKC02cHgpIWltcG9ydGFudDtib3gtc2hhZG93OjAgMTBweCAwIHJnYmEoMTAsNjAsMjAsMC41NSksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMzUpIGluc2V0LDAgMCAyMHB4IHJnYmEoMzQsMTk3LDk0LDAuNSkhaW1wb3J0YW50O3RyYW5zaXRpb246dHJhbnNmb3JtIDAuMDhzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksYm94LXNoYWRvdyAwLjA4cyBlYXNlIWltcG9ydGFudDt9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtM3B4KSFpbXBvcnRhbnQ7Ym94LXNoYWRvdzowIDdweCAwIHJnYmEoMCwwLDAsMC40NSksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTIpIGluc2V0IWltcG9ydGFudDt9CiAgLm5hdi1pdGVtOmFjdGl2ZTpub3QoLmFjdGl2ZSl7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTZweCkhaW1wb3J0YW50O2JveC1zaGFkb3c6MCAxMHB4IDAgcmdiYSgwLDAsMCwwLjQ1KSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xNCkgaW5zZXQhaW1wb3J0YW50O3RyYW5zaXRpb246dHJhbnNmb3JtIDAuMDhzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksYm94LXNoYWRvdyAwLjA4cyBlYXNlIWltcG9ydGFudDt9CgogIC8qIEZpcmVmbGllcyBpbnNpZGUgY2FyZHMgKi8KICAuY2FyZC1mZntwb3NpdGlvbjphYnNvbHV0ZTtib3JkZXItcmFkaXVzOjUwJTtwb2ludGVyLWV2ZW50czpub25lO3otaW5kZXg6MDthbmltYXRpb246Y2ZmLWRyaWZ0IGxpbmVhciBpbmZpbml0ZSxjZmYtYmxpbmsgZWFzZS1pbi1vdXQgaW5maW5pdGU7b3BhY2l0eTowO30KICBAa2V5ZnJhbWVzIGNmZi1kcmlmdHswJXt0cmFuc2Zvcm06dHJhbnNsYXRlKDAsMCkgc2NhbGUoMSk7fTIwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MSksdmFyKC0tZHkxKSkgc2NhbGUoMS4xKTt9NDAle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpO302MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDMpLHZhcigtLWR5MykpIHNjYWxlKDEuMDUpO304MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDQpLHZhcigtLWR5NCkpIHNjYWxlKDAuOTUpO30xMDAle3RyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTt9fQogIEBrZXlmcmFtZXMgY2ZmLWJsaW5rezAlLDEwMCV7b3BhY2l0eTowO30xNSV7b3BhY2l0eTowO30zMCV7b3BhY2l0eTowLjk7fTUwJXtvcGFjaXR5OjAuNzt9NjUle29wYWNpdHk6MDt9ODAle29wYWNpdHk6MC44O305MiV7b3BhY2l0eTowO319CiAgLmNhcmQ+Kjpub3QoLmNhcmQtZmYpe30KICAuc2M+Kjpub3QoLmNhcmQtZmYpe30KCiAgLyogU1BFRUQgVEVTVCAqLwogIC5zcGVlZC1oZXJve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDE2MGRlZywjMGExNjI4IDAlLCMwNjEwMjAgMTAwJSk7Ym9yZGVyOjJweCBzb2xpZCByZ2JhKDYsMTgyLDIxMiwwLjIpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjI0cHggMTZweDttYXJnaW4tYm90dG9tOjEycHg7dGV4dC1hbGlnbjpjZW50ZXI7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO30KICAuc3BlZWQtaGVybzo6YmVmb3Jle2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtiYWNrZ3JvdW5kOnJhZGlhbC1ncmFkaWVudChlbGxpcHNlIDgwJSA1MCUgYXQgNTAlIDAlLHJnYmEoNiwxODIsMjEyLDAuMTIpLHRyYW5zcGFyZW50KTt9CiAgLnNwZWVkLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjRweDtjb2xvcjpyZ2JhKDYsMTgyLDIxMiwwLjcpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3BlZWQtZ2F1Z2Utd3JhcHtwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDoxNjBweDtoZWlnaHQ6ODBweDttYXJnaW46MCBhdXRvIDE2cHg7fQogIC5zcGVlZC1nYXVnZS1zdmd7b3ZlcmZsb3c6dmlzaWJsZTt9CiAgLnNwZWVkLWdhdWdlLWJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgyNTUsMjU1LDI1NSwwLjA2KTtzdHJva2Utd2lkdGg6MTI7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7fQogIC5zcGVlZC1nYXVnZS1maWxse2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6MTI7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAwLjhzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksc3Ryb2tlIDAuM3M7dHJhbnNmb3JtLW9yaWdpbjo4MHB4IDgwcHg7fQogIC5zcGVlZC1jZW50ZXJ7cG9zaXRpb246YWJzb2x1dGU7Ym90dG9tOjA7bGVmdDo1MCU7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoLTUwJSk7dGV4dC1hbGlnbjpjZW50ZXI7fQogIC5zcGVlZC12YWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjMycHg7Zm9udC13ZWlnaHQ6OTAwO2xpbmUtaGVpZ2h0OjE7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzA2YjZkNCwjNjBhNWZhKTstd2Via2l0LWJhY2tncm91bmQtY2xpcDp0ZXh0Oy13ZWJraXQtdGV4dC1maWxsLWNvbG9yOnRyYW5zcGFyZW50O2JhY2tncm91bmQtY2xpcDp0ZXh0O30KICAuc3BlZWQtdW5pdHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjpyZ2JhKDYsMTgyLDIxMiwwLjUpO21hcmdpbi10b3A6MnB4O30KICAuc3BlZWQtYnRuc3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc3BlZWQtYnRue3BhZGRpbmc6MTRweDtib3JkZXItcmFkaXVzOjE0cHg7Ym9yZGVyOm5vbmU7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjJweDt0cmFuc2l0aW9uOmFsbCAwLjJzO30KICAuc3BlZWQtYnRuLWRse2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMjU2M2ViLCMxZDRlZDgpO2NvbG9yOiNmZmY7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoMzcsOTksMjM1LDAuNCk7fQogIC5zcGVlZC1idG4tZGw6aG92ZXJ7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTJweCk7Ym94LXNoYWRvdzowIDhweCAyNHB4IHJnYmEoMzcsOTksMjM1LDAuNSk7fQogIC5zcGVlZC1idG4tdWx7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCM3YzNhZWQsIzZkMjhkOSk7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgxMjQsNTgsMjM3LDAuNCk7fQogIC5zcGVlZC1idG4tdWw6aG92ZXJ7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTJweCk7Ym94LXNoYWRvdzowIDhweCAyNHB4IHJnYmEoMTI0LDU4LDIzNywwLjUpO30KICAuc3BlZWQtYnRuOmRpc2FibGVke29wYWNpdHk6MC40O2N1cnNvcjpub3QtYWxsb3dlZDt0cmFuc2Zvcm06bm9uZTt9CiAgLnNwZWVkLXJlc3VsdHN7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXJlcy1jYXJke2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA0KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCk7Ym9yZGVyLXJhZGl1czoxNHB4O3BhZGRpbmc6MTZweDt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXJlcy1pY29ue2ZvbnQtc2l6ZToyMHB4O21hcmdpbi1ib3R0b206NnB4O30KICAuc3BlZWQtcmVzLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC40KTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNwZWVkLXJlcy12YWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjIycHg7Zm9udC13ZWlnaHQ6OTAwO2xpbmUtaGVpZ2h0OjE7fQogIC5zcGVlZC1yZXMtdmFsLmRsLWNvbG9ye2NvbG9yOiM2MGE1ZmE7fQogIC5zcGVlZC1yZXMtdmFsLnVsLWNvbG9ye2NvbG9yOiNhNzhiZmE7fQogIC5zcGVlZC1yZXMtdW5pdHtmb250LXNpemU6OXB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4zKTttYXJnaW4tdG9wOjJweDt9CiAgLnNwZWVkLXN0YXR1c3tmb250LXNpemU6MTJweDtjb2xvcjpyZ2JhKDYsMTgyLDIxMiwwLjcpO21pbi1oZWlnaHQ6MThweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zcGVlZC1waW5nLXJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OmNlbnRlcjtnYXA6MjBweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zcGVlZC1waW5nLWl0ZW17dGV4dC1hbGlnbjpjZW50ZXI7fQogIC5zcGVlZC1waW5nLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4zNSk7bWFyZ2luLWJvdHRvbToycHg7fQogIC5zcGVlZC1waW5nLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTZweDtmb250LXdlaWdodDo3MDA7Y29sb3I6IzRhZGU4MDt9CiAgLnNwZWVkLXBpbmctdmFsLndhcm57Y29sb3I6I2ZiYmYyNDt9CiAgLnNwZWVkLXBpbmctdmFsLmJhZHtjb2xvcjojZWY0NDQ0O30KICAuc3BlZWQtYmFyLXdyYXB7aGVpZ2h0OjRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNik7Ym9yZGVyLXJhZGl1czoycHg7bWFyZ2luLXRvcDo4cHg7b3ZlcmZsb3c6aGlkZGVuO30KICAuc3BlZWQtYmFye2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3dpZHRoOjAlO3RyYW5zaXRpb246d2lkdGggMC4zcyBlYXNlO30KICAuc3BlZWQtYmFyLmRsLWJhcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMjU2M2ViLCM2MGE1ZmEpO30KICAuc3BlZWQtYmFyLnVsLWJhcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjN2MzYWVkLCNhNzhiZmEpO30KICAuc3BlZWQtaW5mby1ncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmciAxZnI7Z2FwOjhweDt9CiAgLnNwZWVkLWluZm8taXRlbXtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wMyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEwcHg7dGV4dC1hbGlnbjpjZW50ZXI7fQogIC5zcGVlZC1pbmZvLWxibHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6N3B4O2xldHRlci1zcGFjaW5nOjFweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuMyk7bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5zcGVlZC1pbmZvLXZhbHtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjgpO30KICAuc3BlZWQtcHJvZ3toZWlnaHQ6M3B4O2JhY2tncm91bmQ6cmdiYSg2LDE4MiwyMTIsMC4xNSk7Ym9yZGVyLXJhZGl1czoycHg7b3ZlcmZsb3c6aGlkZGVuO21hcmdpbi1ib3R0b206OHB4O30KICAuc3BlZWQtcHJvZy1maWxse2hlaWdodDoxMDAlO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMwNmI2ZDQsIzYwYTVmYSk7Ym9yZGVyLXJhZGl1czoycHg7d2lkdGg6MCU7dHJhbnNpdGlvbjp3aWR0aCAwLjJzIGVhc2U7fQoKQGtleWZyYW1lcyBwaW5nezAle3RyYW5zZm9ybTpzY2FsZSgxKTtvcGFjaXR5Oi43fTEwMCV7dHJhbnNmb3JtOnNjYWxlKDIuNSk7b3BhY2l0eTowfX0KLmRne3Bvc2l0aW9uOnJlbGF0aXZlO2Rpc3BsYXk6aW5saW5lLWZsZXg7d2lkdGg6MTBweDtoZWlnaHQ6MTBweDtmbGV4LXNocmluazowO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTt9Ci5kZzo6YmVmb3Jle2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiMyMmM1NWU7b3BhY2l0eTouNTthbmltYXRpb246cGluZyAxLjRzIGVhc2UtaW4tb3V0IGluZmluaXRlO30KLmRnOjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjJweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiMyMmM1NWU7fQouZGcucmVkOjpiZWZvcmV7YmFja2dyb3VuZDojZWY0NDQ0O30KLmRnLnJlZDo6YWZ0ZXJ7YmFja2dyb3VuZDojZWY0NDQ0O30KLmRvdHtwb3NpdGlvbjpyZWxhdGl2ZTtkaXNwbGF5OmlubGluZS1mbGV4O3dpZHRoOjhweDtoZWlnaHQ6OHB4O2ZsZXgtc2hyaW5rOjA7dmVydGljYWwtYWxpZ246bWlkZGxlO30KLmRvdDo6YmVmb3Jle2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiMyMmM1NWU7b3BhY2l0eTouNTthbmltYXRpb246cGluZyAxLjRzIGVhc2UtaW4tb3V0IGluZmluaXRlO30KLmRvdDo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDoxLjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiMyMmM1NWU7fQouZG90LnJlZDo6YmVmb3Jle2JhY2tncm91bmQ6I2VmNDQ0NDt9Ci5kb3QucmVkOjphZnRlcntiYWNrZ3JvdW5kOiNlZjQ0NDQ7fQoKICAubmF2LWl0ZW0ubmF2LXVwZGF0ZS5hY3RpdmV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCNmY2QzNGQgMCUsI2Y1OWUwYiA0NSUsI2Q5NzcwNiAxMDAlKSFpbXBvcnRhbnQ7Ym94LXNoYWRvdzowIDVweCAwIHJnYmEoOTAsNTAsMCwwLjU1KSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4zMCkgaW5zZXQsMCAwIDE0cHggcmdiYSgyNDUsMTU4LDExLDAuMzUpIWltcG9ydGFudDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtM3B4KSFpbXBvcnRhbnQ7fQogIC5uYXYtaXRlbS5uYXYtdXBkYXRlOmhvdmVyOm5vdCguYWN0aXZlKXtjb2xvcjojZjU5ZTBiO2JvcmRlci1jb2xvcjpyZ2JhKDI0NSwxNTgsMTEsMC4zKTt9CiAgLyogVXBkYXRlIHRhYiBzdHlsZXMgKi8KICAudXBkLWNhcmR7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoycHggc29saWQgI2UyZThmMDtib3JkZXItcmFkaXVzOjIwcHg7cGFkZGluZzoyNHB4IDIwcHg7bWFyZ2luLWJvdHRvbToxMnB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OjAgNHB4IDIwcHggcmdiYSgwLDAsMCwwLjA4KTt9CiAgLnVwZC10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6I2Y1OWUwYjt0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tYm90dG9tOjIwcHg7fQogIC51cGQtcHJvZ3Jlc3Mtd3JhcHttYXJnaW46MjBweCAwIDEycHg7fQogIC51cGQtcHJvZ3Jlc3MtdHJhY2t7aGVpZ2h0OjE0cHg7YmFja2dyb3VuZDojZjBmMGYwO2JvcmRlci1yYWRpdXM6OTlweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC51cGQtcHJvZ3Jlc3MtZmlsbHtoZWlnaHQ6MTAwJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMjJjNTVlLCMxNmEzNGEpO2JvcmRlci1yYWRpdXM6OTlweDt3aWR0aDowJTt0cmFuc2l0aW9uOndpZHRoIDAuM3MgZWFzZTtwb3NpdGlvbjpyZWxhdGl2ZTt9CiAgLnVwZC1wcm9ncmVzcy1maWxsOjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO3RvcDowO2xlZnQ6MDtyaWdodDowO2JvdHRvbTowO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMjU1LDI1NSwyNTUsMC4zKSx0cmFuc3BhcmVudCk7YW5pbWF0aW9uOnNoaW1tZXIgMS41cyBpbmZpbml0ZTtib3JkZXItcmFkaXVzOjk5cHg7fQogIEBrZXlmcmFtZXMgc2hpbW1lcntmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVYKC0xMDAlKX10b3t0cmFuc2Zvcm06dHJhbnNsYXRlWCgxMDAlKX19CiAgLnVwZC1wY3R7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjIycHg7Zm9udC13ZWlnaHQ6OTAwO2NvbG9yOiMxNmEzNGE7bWFyZ2luOjhweCAwIDRweDt9CiAgLnVwZC1zdGF0dXN7dGV4dC1hbGlnbjpjZW50ZXI7Zm9udC1zaXplOjEzcHg7Y29sb3I6IzY0NzQ4YjttaW4taGVpZ2h0OjIycHg7bWFyZ2luLWJvdHRvbToxNnB4O30KICAudXBkLXN0YXR1cy5ydW5uaW5ne2NvbG9yOiMyNTYzZWI7fQogIC51cGQtc3RhdHVzLmRvbmV7Y29sb3I6IzE2YTM0YTtmb250LXdlaWdodDo3MDA7fQogIC51cGQtc3RhdHVzLmVycm9ye2NvbG9yOiNlZjQ0NDQ7fQogIC51cGQtYnRue3dpZHRoOjEwMCU7cGFkZGluZzoxNnB4O2JvcmRlci1yYWRpdXM6MTRweDtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2Y1OWUwYiwjZDk3NzA2KTtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjcwMDtsZXR0ZXItc3BhY2luZzoycHg7Y3Vyc29yOnBvaW50ZXI7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoMjQ1LDE1OCwxMSwwLjQpO3RyYW5zaXRpb246YWxsIDAuMnM7fQogIC51cGQtYnRuOmhvdmVye3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpO2JveC1zaGFkb3c6MCA4cHggMjRweCByZ2JhKDI0NSwxNTgsMTEsMC41KTt9CiAgLnVwZC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAudXBkLWluZm97YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgI2UyZThmMDtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOiM2NDc0OGI7bGluZS1oZWlnaHQ6MS43O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnVwZC1pbmZvIGJ7Y29sb3I6IzFlMjkzYjt9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KCjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9IndyYXAiPgoKICA8IS0tIEhFQURFUiAtLT4KICA8ZGl2IGNsYXNzPSJoZHIiIGlkPSJoZHItcm9vdCI+CiAgPGNhbnZhcyBpZD0iaGRyLWNhbnZhcyIgc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7d2lkdGg6MTAwJTtoZWlnaHQ6MTAwJTtwb2ludGVyLWV2ZW50czpub25lO3otaW5kZXg6MTsiPjwvY2FudmFzPgogIDxzY3JpcHQ+CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ0RPTUNvbnRlbnRMb2FkZWQnLGZ1bmN0aW9uKCl7CiAgICBjb25zdCBjYW52YXM9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1jYW52YXMnKTsKICAgIGNvbnN0IHdyYXA9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1yb290Jyk7CiAgICBmdW5jdGlvbiByZXNpemUoKXtjYW52YXMud2lkdGg9d3JhcC5vZmZzZXRXaWR0aDtjYW52YXMuaGVpZ2h0PXdyYXAub2Zmc2V0SGVpZ2h0O30KICAgIHJlc2l6ZSgpOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScscmVzaXplKTsKICAgIGNvbnN0IGN0eD1jYW52YXMuZ2V0Q29udGV4dCgnMmQnKTsKICAgIGNvbnN0IGNvbG9ycz1bJyNiNWY1NDInLCcjZDRmYzVhJywnIzdmZmYwMCcsJyNhYWZmNDQnLCcjZjVmNTQyJywnI2ZmZTk0ZCcsJyM1NmZmYjAnLCcjOTBmZjZhJywnI2EwZmY3OCcsJyNmZmVjNmUnXTsKICAgIGNvbnN0IGZmcz1bXTsKICAgIGZvcihsZXQgaT0wO2k8MzU7aSsrKXsKICAgICAgZmZzLnB1c2goewogICAgICAgIHg6TWF0aC5yYW5kb20oKSpjYW52YXMud2lkdGgsCiAgICAgICAgeTpNYXRoLnJhbmRvbSgpKmNhbnZhcy5oZWlnaHQsCiAgICAgICAgcjpNYXRoLnJhbmRvbSgpKjEuOCswLjYsCiAgICAgICAgY29sb3I6Y29sb3JzW01hdGguZmxvb3IoTWF0aC5yYW5kb20oKSpjb2xvcnMubGVuZ3RoKV0sCiAgICAgICAgdng6KE1hdGgucmFuZG9tKCktMC41KSowLjUsCiAgICAgICAgdnk6KE1hdGgucmFuZG9tKCktMC41KSowLjQsCiAgICAgICAgYWxwaGE6MCwKICAgICAgICBhbHBoYURpcjpNYXRoLnJhbmRvbSgpPjAuNT8xOi0xLAogICAgICAgIGFscGhhU3BlZWQ6TWF0aC5yYW5kb20oKSowLjAxNSswLjAwNSwKICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBkcmF3KCl7CiAgICAgIHJlc2l6ZSgpOwogICAgICBjdHguY2xlYXJSZWN0KDAsMCxjYW52YXMud2lkdGgsY2FudmFzLmhlaWdodCk7CiAgICAgIGZmcy5mb3JFYWNoKGY9PnsKICAgICAgICBmLngrPWYudng7IGYueSs9Zi52eTsKICAgICAgICBpZihmLng8MClmLng9Y2FudmFzLndpZHRoOwogICAgICAgIGlmKGYueD5jYW52YXMud2lkdGgpZi54PTA7CiAgICAgICAgaWYoZi55PDApZi55PWNhbnZhcy5oZWlnaHQ7CiAgICAgICAgaWYoZi55PmNhbnZhcy5oZWlnaHQpZi55PTA7CiAgICAgICAgZi5hbHBoYSs9Zi5hbHBoYURpcipmLmFscGhhU3BlZWQ7CiAgICAgICAgaWYoZi5hbHBoYT49MSl7Zi5hbHBoYT0xO2YuYWxwaGFEaXI9LTE7fQogICAgICAgIGlmKGYuYWxwaGE8PTApe2YuYWxwaGE9MDtmLmFscGhhRGlyPTE7fQogICAgICAgIGN0eC5zYXZlKCk7CiAgICAgICAgY3R4Lmdsb2JhbEFscGhhPWYuYWxwaGE7CiAgICAgICAgY3R4LnNoYWRvd0JsdXI9Zi5yKjg7CiAgICAgICAgY3R4LnNoYWRvd0NvbG9yPWYuY29sb3I7CiAgICAgICAgY3R4LmJlZ2luUGF0aCgpOwogICAgICAgIGN0eC5hcmMoZi54LGYueSxmLnIsMCxNYXRoLlBJKjIpOwogICAgICAgIGN0eC5maWxsU3R5bGU9Zi5jb2xvcjsKICAgICAgICBjdHguZmlsbCgpOwogICAgICAgIGN0eC5yZXN0b3JlKCk7CiAgICAgIH0pOwogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoZHJhdyk7CiAgICB9CiAgICBkcmF3KCk7CiAgfSk7CiAgPC9zY3JpcHQ+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MTZweDtyaWdodDoxNHB4O3otaW5kZXg6MTA7Ij7ihqkg4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4LiaPC9idXR0b24+CgogICAgPCEtLSBMb2dvIFNWRyAoc2FtZSBhcyBsb2dpbikgLS0+CiAgICA8ZGl2IGNsYXNzPSJoZHItbG9nby1zdmctd3JhcCI+CiAgICAgIDxzdmcgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjcyIiBoZWlnaHQ9IjcyIj4KICAgICAgICA8ZGVmcz4KICAgICAgICAgIDxsaW5lYXJHcmFkaWVudCBpZD0iaFciIHgxPSIwJSIgeTE9IjAlIiB4Mj0iMTAwJSIgeTI9IjAlIj4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9yPSIjMjU2M2ViIi8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iNTAlIiAgc3RvcC1jb2xvcj0iIzYwYTVmYSIvPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMwNmI2ZDQiLz4KICAgICAgICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICAgICAgICA8cmFkaWFsR3JhZGllbnQgaWQ9ImhCZyIgY3g9IjUwJSIgY3k9IjUwJSIgcj0iNTAlIj4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9yPSIjMGYxZTRhIiBzdG9wLW9wYWNpdHk9IjAuOTUiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjMDYwYzFlIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgICAgICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAgICAgICA8ZmlsdGVyIGlkPSJoR2xvdyI+CiAgICAgICAgICAgIDxmZUdhdXNzaWFuQmx1ciBzdGREZXZpYXRpb249IjIuNSIgcmVzdWx0PSJiIi8+CiAgICAgICAgICAgIDxmZU1lcmdlPjxmZU1lcmdlTm9kZSBpbj0iYiIvPjxmZU1lcmdlTm9kZSBpbj0iU291cmNlR3JhcGhpYyIvPjwvZmVNZXJnZT4KICAgICAgICAgIDwvZmlsdGVyPgogICAgICAgICAgPGNsaXBQYXRoIGlkPSJoQ2xpcCI+PGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiLz48L2NsaXBQYXRoPgogICAgICAgIDwvZGVmcz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSI0NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjEyKSIgc3Ryb2tlLXdpZHRoPSIxIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDIiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuMikiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLWRhc2hhcnJheT0iNSA0IiBjbGFzcz0iaGRyLW9yYml0LXJpbmciLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjIyKSIgc3Ryb2tlLXdpZHRoPSIxIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiIGZpbGw9InVybCgjaEJnKSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0IiBmaWxsPSJub25lIiBzdHJva2U9InVybCgjaFcpIiBzdHJva2Utd2lkdGg9IjEuOCIgb3BhY2l0eT0iMC45Ii8+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iMTQiIHgyPSI1MCIgeTI9IjIwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI1MCIgeTE9IjgwIiB4Mj0iNTAiIHkyPSI4NiIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iMTQiIHkxPSI1MCIgeDI9IjIwIiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjgwIiB5MT0iNTAiIHgyPSI4NiIgeTI9IjUwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxnIGNsaXAtcGF0aD0idXJsKCNoQ2xpcCkiPgogICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMTYsNTAgMjQsNTAgMjksMzIgMzQsNjggMzksMzIgNDQsNTAgODQsNTAiCiAgICAgICAgICAgIGZpbGw9Im5vbmUiIHN0cm9rZT0idXJsKCNoVykiIHN0cm9rZS13aWR0aD0iMi4yIgogICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiCiAgICAgICAgICAgIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItd2F2ZS1hbmltIi8+CiAgICAgICAgPC9nPgogICAgICAgIDxjaXJjbGUgY3g9IjI5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzYwYTVmYSIgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3QtMSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjM5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzA2YjZkNCIgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3QtMiIvPgogICAgICAgIDxjaXJjbGUgY3g9IjM0IiBjeT0iNjgiIHI9IjIuNSIgZmlsbD0iIzYwYTVmYSIgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3QtMSIvPgogICAgICA8L3N2Zz4KICAgIDwvZGl2PgoKICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxOHB4O2ZvbnQtd2VpZ2h0OjkwMDtsZXR0ZXItc3BhY2luZzo0cHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2UwZjJmZSwjNjBhNWZhLCMwNmI2ZDQpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7Ij5DSEFJWUE8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6OXB4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjYpO21hcmdpbi10b3A6MnB4OyI+UFJPSkVDVDwvZGl2PgogICAgPGRpdiBzdHlsZT0id2lkdGg6MTQwcHg7aGVpZ2h0OjFweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCwjNjBhNWZhLCMwNmI2ZDQsdHJhbnNwYXJlbnQpO21hcmdpbjo2cHggYXV0bztvcGFjaXR5OjAuNTsiPjwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6cmdiYSg2LDE4MiwyMTIsMC41NSk7bWFyZ2luLXRvcDoycHg7Ij5WMlJBWSAmYW1wOyBTU0g8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjUpO21hcmdpbi10b3A6NHB4OyIgaWQ9Imhkci1kb21haW4iPlNFQ1VSRSBQQU5FTDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIE5BViAtLT4KICA8ZGl2IGNsYXNzPSJuYXYtd3JhcCIgaWQ9Im5hdi13cmFwIj4KICA8Y2FudmFzIGlkPSJuYXYtY2FudmFzIiBzdHlsZT0icG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDt3aWR0aDoxMDAlO2hlaWdodDoxMDAlO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDoxOyI+PC9jYW52YXM+CiAgPHNjcmlwdD4KICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignRE9NQ29udGVudExvYWRlZCcsZnVuY3Rpb24oKXsKICAgIGNvbnN0IGNhbnZhcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmF2LWNhbnZhcycpOwogICAgY29uc3Qgd3JhcD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmF2LXdyYXAnKTsKICAgIGZ1bmN0aW9uIHJlc2l6ZSgpe2NhbnZhcy53aWR0aD13cmFwLm9mZnNldFdpZHRoO2NhbnZhcy5oZWlnaHQ9d3JhcC5vZmZzZXRIZWlnaHQ7fQogICAgcmVzaXplKCk7CiAgICBjb25zdCBjdHg9Y2FudmFzLmdldENvbnRleHQoJzJkJyk7CiAgICBjb25zdCBjb2xvcnM9WycjYjVmNTQyJywnI2Q0ZmM1YScsJyM3ZmZmMDAnLCcjYWFmZjQ0JywnI2Y1ZjU0MicsJyNmZmU5NGQnLCcjNTZmZmIwJywnIzkwZmY2YSddOwogICAgY29uc3QgZmZzPVtdOwogICAgZm9yKGxldCBpPTA7aTwyMjtpKyspewogICAgICBmZnMucHVzaCh7CiAgICAgICAgeDpNYXRoLnJhbmRvbSgpKmNhbnZhcy53aWR0aCwKICAgICAgICB5Ok1hdGgucmFuZG9tKCkqY2FudmFzLmhlaWdodCwKICAgICAgICByOk1hdGgucmFuZG9tKCkqMS41KzAuOCwKICAgICAgICBjb2xvcjpjb2xvcnNbTWF0aC5mbG9vcihNYXRoLnJhbmRvbSgpKmNvbG9ycy5sZW5ndGgpXSwKICAgICAgICB2eDooTWF0aC5yYW5kb20oKS0wLjUpKjAuNiwKICAgICAgICB2eTooTWF0aC5yYW5kb20oKS0wLjUpKjAuNCwKICAgICAgICBhbHBoYTowLAogICAgICAgIGFscGhhRGlyOk1hdGgucmFuZG9tKCk+MC41PzE6LTEsCiAgICAgICAgYWxwaGFTcGVlZDpNYXRoLnJhbmRvbSgpKjAuMDIrMC4wMDgsCiAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gZHJhdygpewogICAgICByZXNpemUoKTsKICAgICAgY3R4LmNsZWFyUmVjdCgwLDAsY2FudmFzLndpZHRoLGNhbnZhcy5oZWlnaHQpOwogICAgICBmZnMuZm9yRWFjaChmPT57CiAgICAgICAgZi54Kz1mLnZ4OyBmLnkrPWYudnk7CiAgICAgICAgaWYoZi54PDApZi54PWNhbnZhcy53aWR0aDsKICAgICAgICBpZihmLng+Y2FudmFzLndpZHRoKWYueD0wOwogICAgICAgIGlmKGYueTwwKWYueT1jYW52YXMuaGVpZ2h0OwogICAgICAgIGlmKGYueT5jYW52YXMuaGVpZ2h0KWYueT0wOwogICAgICAgIGYuYWxwaGErPWYuYWxwaGFEaXIqZi5hbHBoYVNwZWVkOwogICAgICAgIGlmKGYuYWxwaGE+PTEpe2YuYWxwaGE9MTtmLmFscGhhRGlyPS0xO30KICAgICAgICBpZihmLmFscGhhPD0wKXtmLmFscGhhPTA7Zi5hbHBoYURpcj0xO30KICAgICAgICBjdHguc2F2ZSgpOwogICAgICAgIGN0eC5nbG9iYWxBbHBoYT1mLmFscGhhOwogICAgICAgIGN0eC5iZWdpblBhdGgoKTsKICAgICAgICBjdHguYXJjKGYueCxmLnksZi5yLDAsTWF0aC5QSSoyKTsKICAgICAgICBjdHguZmlsbFN0eWxlPWYuY29sb3I7CiAgICAgICAgY3R4LmZpbGwoKTsKICAgICAgICBjdHguc2hhZG93Qmx1cj1mLnIqNjsKICAgICAgICBjdHguc2hhZG93Q29sb3I9Zi5jb2xvcjsKICAgICAgICBjdHguZmlsbCgpOwogICAgICAgIGN0eC5yZXN0b3JlKCk7CiAgICAgIH0pOwogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoZHJhdyk7CiAgICB9CiAgICBkcmF3KCk7CiAgfSk7CiAgPC9zY3JpcHQ+CiAgPGRpdiBjbGFzcz0ibmF2Ij4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIGFjdGl2ZSIgb25jbGljaz0ic3coJ2Rhc2hib2FyZCcsdGhpcykiPvCfk4og4LmB4LiU4LiK4Lia4Lit4Lij4LmM4LiUPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2NyZWF0ZScsdGhpcykiPuKelSDguKrguKPguYnguLLguIfguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnbWFuYWdlJyx0aGlzKSI+8J+UpyDguIjguLHguJTguIHguLLguKPguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnb25saW5lJyx0aGlzKSI+8J+foiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnYmFuJyx0aGlzKSI+8J+aqyDguJvguKXguJTguYHguJrguJk8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIG5hdi1zcGVlZCIgb25jbGljaz0ic3coJ3NwZWVkJyx0aGlzKSI+4pqhIOC4quC4m+C4teC4lOC5gOC4l+C4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gbmF2LXVwZGF0ZSIgb25jbGljaz0ic3coJ3VwZGF0ZScsdGhpcykiPvCflIQg4Lit4Lix4Lie4LmA4LiU4LiXPC9kaXY+CiAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIgaWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFuIGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7imqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9udC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGltZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJvdyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3guKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAgICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklDRSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2ltZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgtQUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlzLm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWlnaHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdTIMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODg4MCDCtyBXUyDCtyB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KCiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCIgc3R5bGU9Im1hcmdpbi10b3A6MjBweCI+8J+UkSDguKPguLDguJrguJogU1NIIFdFQlNPQ0tFVDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3NzaCcpIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtc3NoIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6I2ZmZjtmb250LWZhbWlseTptb25vc3BhY2UiPlNTSCZndDs8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgc3NoIj5TU0gg4oCTIFdTIFR1bm5lbDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+U1NIIMK3IFBvcnQgODAgwrcgRHJvcGJlYXIgMTQzLzEwOTxicj5OcHZUdW5uZWwgLyBEYXJrVHVubmVsPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IEFJUyDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLWFpcyIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgYWlzLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWxvZ28gc2VsLWFpcy1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouOHJlbTtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSBhaXMiPkFJUyDigJMg4LiB4Lix4LiZ4Lij4Lix4LmI4LinPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDgwODAgwrcgU05JOiBjai1lYmIuc3BlZWR0ZXN0Lm5ldDwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgRU1BSUwgLyDguIrguLfguYjguK3guKLguLnguKo8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckBhaXMiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OxIElQIExJTUlUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLWFpcyIgaWQ9ImFpcy1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCdhaXMnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBBSVMgQWNjb3VudDwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYWlzLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0iYWlzLXJlc3VsdCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtcmVzdWx0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSciPuKclTwvYnV0dG9uPgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OnIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiIgaWQ9InItYWlzLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici1haXMtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItYWlzLWV4cCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtbGluayIgaWQ9InItYWlzLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItYWlzLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0iYWlzLXFyIiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7bWFyZ2luLXRvcDoxMnB4OyI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogVFJVRSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXRydWUiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0taGRyIHRydWUtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlLXNtIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi43NXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tdGl0bGUgdHJ1ZSI+VFJVRSDigJMgVkRPPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tc3ViIj5WTEVTUyDCtyBQb3J0IDg4ODAgwrcgU05JOiB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckB0cnVlIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+ThSDguKfguLHguJnguYPguIrguYnguIfguLLguJkgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4gY2J0bi10cnVlIiBpZD0idHJ1ZS1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCd0cnVlJykiPuKaoSDguKrguKPguYnguLLguIcgVFJVRSBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJ0cnVlLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0idHJ1ZS1yZXN1bHQiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0icmVzLWNsb3NlIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndHJ1ZS1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici10cnVlLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici10cnVlLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLXRydWUtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici10cnVlLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItdHJ1ZS1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9InRydWUtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBTU0gg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1zc2giIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNzaC1kYXJrLWZvcm0iPgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstaGRyIj7inpUg4LmA4Lie4Li04LmI4LihIFNTSCBVU0VSPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1maWVsZCI+CiAgICAgICAgICA8bGFiZWwgY2xhc3M9ImRhcmstbGFiZWwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iTwvbGFiZWw+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9ImRhcmstaW5wdXQiIGlkPSJzc2gtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIiBhdXRvY29tcGxldGU9Im9mZiIvPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstZmllbGQiPgogICAgICAgICAgPGxhYmVsIGNsYXNzPSJkYXJrLWxhYmVsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGNsYXNzPSJkYXJrLWlucHV0IiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgdHlwZT0icGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0ib2ZmIi8+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1maWVsZCI+CiAgICAgICAgICA8bGFiZWwgY2xhc3M9ImRhcmstbGFiZWwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4mTwvbGFiZWw+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9ImRhcmstaW5wdXQiIGlkPSJzc2gtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWZpZWxkIj4KICAgICAgICAgIDxsYWJlbCBjbGFzcz0iZGFyay1sYWJlbCI+4Lil4Li04Lih4Li04LiV4LmE4Lit4Lie4Li1PC9sYWJlbD4KICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZGFyay1pbnB1dCIgaWQ9InNzaC1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIvPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn4yQIOC5gOC4peC4t+C4reC4gSBJU1AgLyBPUEVSQVRPUjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBpY2stZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCBhLWR0YWMiIGlkPSJwcm8tZHRhYyIgb25jbGljaz0icGlja1BybygnZHRhYycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCfn6A8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRUQUMgR0FNSU5HPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5kbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0icHJvLXRydWUiIG9uY2xpY2s9InBpY2tQcm8oJ3RydWUnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj7wn5S1PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5UUlVFIFRXSVRURVI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmhlbHAueC5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCI+8J+TsSDguYDguKXguLfguK3guIEgQVBQPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtbnB2IiBpZD0iYXBwLW5wdiIgb25jbGljaz0icGlja0FwcCgnbnB2JykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+PGRpdiBzdHlsZT0id2lkdGg6MzhweDtoZWlnaHQ6MzhweDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMGQyYTNhO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjttYXJnaW46MCBhdXRvIC4xcmVtO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi44NXJlbTtjb2xvcjojMDBjY2ZmO2xldHRlci1zcGFjaW5nOi0xcHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMCwyMDQsMjU1LC4zKSI+blY8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPk5wdiBUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPm5wdnQtc3NoOi8vPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0iYXBwLWRhcmsiIG9uY2xpY2s9InBpY2tBcHAoJ2RhcmsnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMxMTE7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6c2Fucy1zZXJpZjtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi42MnJlbTtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOi41cHg7Ym9yZGVyOjEuNXB4IHNvbGlkICM0NDQiPkRBUks8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRhcmtUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRhcmt0dW5uZWw6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgCgogICAgICAgIDwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4tc3NoIiBpZD0ic3NoLWJ0biIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKelSDguKrguKPguYnguLLguIcgVXNlcjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsaW5rLXJlc3VsdCIgaWQ9InNzaC1saW5rLXJlc3VsdCI+PC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBVc2VyIHRhYmxlIC0tPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIiBzdHlsZT0ibWFyZ2luOjAiPvCfk4sg4Lij4Liy4Lii4LiK4Li34LmI4LitIFVTRVJTPC9kaXY+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJzc2gtc2VhcmNoIiBwbGFjZWhvbGRlcj0i4LiE4LmJ4LiZ4Lir4LiyLi4uIiBvbmlucHV0PSJmaWx0ZXJTU0hVc2Vycyh0aGlzLnZhbHVlKSIKICAgICAgICAgICAgc3R5bGU9IndpZHRoOjEyMHB4O21hcmdpbjowO2ZvbnQtc2l6ZToxMXB4O3BhZGRpbmc6NnB4IDEwcHgiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InV0Ymwtd3JhcCI+CiAgICAgICAgICA8dGFibGUgY2xhc3M9InV0YmwiPgogICAgICAgICAgICA8dGhlYWQ+PHRyPjx0aD4jPC90aD48dGg+VVNFUk5BTUU8L3RoPjx0aD7guKvguKHguJTguK3guLLguKLguLg8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BQ1RJT048L3RoPjwvdHI+PC90aGVhZD4KICAgICAgICAgICAgPHRib2R5IGlkPSJzc2gtdXNlci10Ym9keSI+PHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9yOnZhcigtLW11dGVkKSI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwvdGJvZHk+CiAgICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICA8L2Rpdj48IS0tIC90YWItY3JlYXRlIC0tPgoKPCEtLSDilZDilZDilZDilZAgTUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJ1c2VyLXNlYXJjaCIgcGxhY2Vob2xkZXI9IvCflI0gIOC4hOC5ieC4meC4q+C4siB1c2VybmFtZS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgICA8ZGl2IGlkPSJ1c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4m+C4uOC5iOC4oeC5guC4q+C4peC4lOC5gOC4nuC4t+C5iOC4reC4lOC4tuC4h+C4guC5ieC4reC4oeC4ueC4pTwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkT25saW5lKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9jciI+CiAgICAgICAgPGRpdiBjbGFzcz0ib3BpbGwiIGlkPSJvbmxpbmUtcGlsbCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJvbmxpbmUtY291bnQiPjA8L3NwYW4+IOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJ1dCIgaWQ9Im9ubGluZS10aW1lIj4tLTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguKPguLXguYDguJ/guKPguIrguYDguJ7guLfguYjguK3guJTguLnguJzguLnguYnguYPguIrguYnguK3guK3guJnguYTguKXguJnguYw8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBCQU4g4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1iYW4iPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+UkyDguJvguKXguJTguKXguYfguK3guIQgSVAgQmFuPC9kaXY+CiAgICAgIDxwIHN0eWxlPSJmb250LXNpemU6MTNweDtjb2xvcjojNjY2O21hcmdpbi1ib3R0b206MTJweCI+4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmM4LiX4Li14LmI4LmD4LiK4LmJIElQIOC5gOC4geC4tOC4mSBMaW1pdCDguIjguLDguJbguLnguIHguKXguYfguK3guITguIrguLHguYjguKfguITguKPguLLguKcgMSDguIrguLHguYjguKfguYLguKHguIc8YnI+4LiB4Lij4Lit4LiBIFVzZXJuYW1lIOC5gOC4nuC4t+C5iOC4reC4m+C4peC4lOC4peC5h+C4reC4hOC4l+C4seC4meC4l+C4tTwvcD4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgVVNFUk5BTUUg4LiX4Li14LmI4LmB4Lia4LiZPC9kaXY+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImJhbi11c2VyIiBwbGFjZWhvbGRlcj0i4LiB4Lij4Lit4LiBIHVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4m+C4peC4lOC4peC5h+C4reC4hCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzkyNDAwZSwjZjU5ZTBiKSIgb25jbGljaz0idW5iYW5Vc2VyKCkiPvCflJMg4Lib4Lil4LiU4Lil4LmH4Lit4LiEIElQIEJhbjwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImJhbi1hbGVydCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7bWFyZ2luLWJvdHRvbToxMnB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW46MCI+4o+x77iPIOC4o+C4suC4ouC4geC4suC4o+C4l+C4teC5iOC4luC4ueC4geC5geC4muC4meC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDxidXR0b24gb25jbGljaz0ibG9hZEJhbm5lZCgpIiBzdHlsZT0iYmFja2dyb3VuZDpub25lO2JvcmRlcjoxcHggc29saWQgI2RkZDtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjRweCAxMnB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyIj7ihrog4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJiYW5uZWQtbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KICAKCgogIDwhLS0gU1BFRUQgVEVTVCBUQUIgLS0+CiAgICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItc3BlZWQiPgogICAgPHN0eWxlPgogICAgICAuc3QtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjRweCAxNnB4O2JveC1zaGFkb3c6MCAycHggMTZweCByZ2JhKDAsMCwwLDAuMDgpO21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6I2Y1OWUwYjt0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tYm90dG9tOjIwcHg7fQogICAgICAuc3QtY2lyY2xlc3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWFyb3VuZDthbGlnbi1pdGVtczpjZW50ZXI7bWFyZ2luLWJvdHRvbToxNnB4O30KICAgICAgLnN0LWNpcmNsZS13cmFwe3RleHQtYWxpZ246Y2VudGVyO30KICAgICAgLnN0LWNpcmNsZXtwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDoxMDBweDtoZWlnaHQ6MTAwcHg7bWFyZ2luOjAgYXV0byA4cHg7fQogICAgICAuc3QtY2lyY2xlIHN2Z3t0cmFuc2Zvcm06cm90YXRlKC05MGRlZyk7fQogICAgICAuc3QtY2lyY2xlLWJne2ZpbGw6bm9uZTtzdHJva2U6I2YwZjBmMDtzdHJva2Utd2lkdGg6ODt9CiAgICAgIC5zdC1jaXJjbGUtZmlsbC1waW5ne2ZpbGw6bm9uZTtzdHJva2U6IzIyYzU1ZTtzdHJva2Utd2lkdGg6ODtzdHJva2UtbGluZWNhcDpyb3VuZDtzdHJva2UtZGFzaGFycmF5OjI4Mzt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgZWFzZTt9CiAgICAgIC5zdC1jaXJjbGUtZmlsbC1kbHtmaWxsOm5vbmU7c3Ryb2tlOiMzYjgyZjY7c3Ryb2tlLXdpZHRoOjg7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7c3Ryb2tlLWRhc2hhcnJheToyODM7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAwLjhzIGVhc2U7fQogICAgICAuc3QtY2lyY2xlLWZpbGwtdWx7ZmlsbDpub25lO3N0cm9rZTojYTg1NWY3O3N0cm9rZS13aWR0aDo4O3N0cm9rZS1saW5lY2FwOnJvdW5kO3N0cm9rZS1kYXNoYXJyYXk6MjgzO3RyYW5zaXRpb246c3Ryb2tlLWRhc2hvZmZzZXQgMC44cyBlYXNlO30KICAgICAgLnN0LWNpcmNsZS1pbm5lcntwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogICAgICAuc3QtY2lyY2xlLXZhbHtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo5MDA7Y29sb3I6IzFlMjkzYjtsaW5lLWhlaWdodDoxO30KICAgICAgLnN0LWNpcmNsZS11bml0e2ZvbnQtc2l6ZTo5cHg7Y29sb3I6Izk0YTNiODttYXJnaW4tdG9wOjJweDt9CiAgICAgIC5zdC1jaXJjbGUtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6IzY0NzQ4Yjt9CiAgICAgIC5zdC1jaXJjbGUtbGFiZWwucGluZ3tjb2xvcjojMjJjNTVlO30KICAgICAgLnN0LWNpcmNsZS1sYWJlbC5kbHtjb2xvcjojM2I4MmY2O30KICAgICAgLnN0LWNpcmNsZS1sYWJlbC51bHtjb2xvcjojYTg1NWY3O30KICAgICAgLnN0LXN0YXR1c3t0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTJweDtjb2xvcjojNjQ3NDhiO21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC1wcm9ne2hlaWdodDo0cHg7YmFja2dyb3VuZDojZjBmMGYwO2JvcmRlci1yYWRpdXM6OTlweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLWJvdHRvbToxNnB4O30KICAgICAgLnN0LXByb2ctZmlsbHtoZWlnaHQ6MTAwJTt3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMjJjNTVlLCMzYjgyZjYpO2JvcmRlci1yYWRpdXM6OTlweDt0cmFuc2l0aW9uOndpZHRoIDAuM3MgZWFzZTt9CiAgICAgIC5zdC1idG57d2lkdGg6MTAwJTtwYWRkaW5nOjE2cHg7Ym9yZGVyLXJhZGl1czoxNHB4O2JvcmRlcjpub25lO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMTZhMzRhLCMyMmM1NWUpO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjJweDtjdXJzb3I6cG9pbnRlcjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNCwxOTcsOTQsMC40KTt0cmFuc2l0aW9uOmFsbCAwLjJzO21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC1idG46aG92ZXJ7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTJweCk7Ym94LXNoYWRvdzowIDhweCAyNHB4IHJnYmEoMzQsMTk3LDk0LDAuNSk7fQogICAgICAuc3QtYnRuOmRpc2FibGVke29wYWNpdHk6MC41O2N1cnNvcjpub3QtYWxsb3dlZDt0cmFuc2Zvcm06bm9uZTt9CiAgICAgIC5zdC1yZXN1bHR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7Ym9yZGVyOjFweCBzb2xpZCAjZTJlOGYwO30KICAgICAgLnN0LXJlc3VsdC10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjojOTRhM2I4O21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC1yZXN1bHQtZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLWxhYmVse2ZvbnQtc2l6ZToxMHB4O2NvbG9yOiM5NGEzYjg7bWFyZ2luLWJvdHRvbToycHg7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLXZhbHtmb250LXNpemU6MTNweDtmb250LXdlaWdodDo3MDA7Y29sb3I6IzFlMjkzYjt9CiAgICAgIC5zdC1yZXN1bHQtaXRlbSAuc3QtcmktdmFsLmdyZWVue2NvbG9yOiMyMmM1NWU7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLXZhbC5ibHVle2NvbG9yOiMzYjgyZjY7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLXZhbC5wdXJwbGV7Y29sb3I6I2E4NTVmNzt9CiAgICA8L3N0eWxlPgogICAgPGRpdiBjbGFzcz0ic3QtY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InN0LXRpdGxlIj7imqEgVlBTIFNQRUVEIFRFU1Q8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlcyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXdyYXAiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjEwMCIgaGVpZ2h0PSIxMDAiPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1iZyIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1Ii8+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3QtY2lyY2xlLWZpbGwtcGluZyIgaWQ9ImMtcGluZyIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1IiBzdHJva2UtZGFzaG9mZnNldD0iMjgzIi8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtaW5uZXIiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS12YWwiIGlkPSJzdC1waW5nLXZhbCI+LS08L2Rpdj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtdW5pdCI+bXM8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1sYWJlbCBwaW5nIj5QSU5HPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXdyYXAiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjEwMCIgaGVpZ2h0PSIxMDAiPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1iZyIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1Ii8+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3QtY2lyY2xlLWZpbGwtZGwiIGlkPSJjLWRsIiBjeD0iNTAiIGN5PSI1MCIgcj0iNDUiIHN0cm9rZS1kYXNob2Zmc2V0PSIyODMiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1pbm5lciI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXZhbCIgaWQ9InN0LWRsLXZhbCI+LS08L2Rpdj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtdW5pdCI+TWJwczwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLWxhYmVsIGRsIj5ET1dOTE9BRDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS13cmFwIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZSI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdpZHRoPSIxMDAiIGhlaWdodD0iMTAwIj4KICAgICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJzdC1jaXJjbGUtYmciIGN4PSI1MCIgY3k9IjUwIiByPSI0NSIvPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1maWxsLXVsIiBpZD0iYy11bCIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1IiBzdHJva2UtZGFzaG9mZnNldD0iMjgzIi8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtaW5uZXIiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS12YWwiIGlkPSJzdC11bC12YWwiPi0tPC9kaXY+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXVuaXQiPk1icHM8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1sYWJlbCB1bCI+VVBMT0FEPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdC1zdGF0dXMiIGlkPSJzdC1zdGF0dXMiPuC4geC4lOC4m+C4uOC5iOC4oeC5gOC4nuC4t+C5iOC4reC5gOC4o+C4tOC5iOC4oeC4l+C4lOC4quC4reC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdC1wcm9nIj48ZGl2IGNsYXNzPSJzdC1wcm9nLWZpbGwiIGlkPSJzdC1wcm9nIj48L2Rpdj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ic3QtYnRuIiBpZD0ic3QtYnRuIiBvbmNsaWNrPSJzdGFydE5ld1NwZWVkVGVzdCgpIj7ilrYgU1RBUlQgVEVTVDwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQiPgogICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC10aXRsZSI+VEVTVCBSRVNVTFQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCfjJAgU2VydmVyIElQPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIiBpZD0ic3QtaXAiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCfk40gTG9jYXRpb248L2Rpdj48ZGl2IGNsYXNzPSJzdC1yaS12YWwiIGlkPSJzdC1sb2MiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCfj5MgUGluZzwvZGl2PjxkaXYgY2xhc3M9InN0LXJpLXZhbCBncmVlbiIgaWQ9InN0LXItcGluZyI+LS08L2Rpdj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1pdGVtIj48ZGl2IGNsYXNzPSJzdC1yaS1sYWJlbCI+4qyH77iPIERvd25sb2FkPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIGJsdWUiIGlkPSJzdC1yLWRsIj4tLTwvZGl2PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LWl0ZW0iPjxkaXYgY2xhc3M9InN0LXJpLWxhYmVsIj7irIbvuI8gVXBsb2FkPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIHB1cnBsZSIgaWQ9InN0LXItdWwiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCflZAgVGVzdGVkPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIiBpZD0ic3Qtci10aW1lIj4tLTwvZGl2PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPHNjcmlwdD4KICAgIGFzeW5jIGZ1bmN0aW9uIHN0YXJ0TmV3U3BlZWRUZXN0KCkgewogICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtYnRuJyk7CiAgICAgIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfij7Mg4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIFZQUy4uLic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1zdGF0dXMnKS50ZXh0Q29udGVudCA9ICfguIHguLPguKXguLHguIfguJfguJTguKrguK3guJrguKrguJvguLXguJQgVlBTIOC4iOC4o+C4tOC4hy4uLic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1wcm9nJykuc3R5bGUud2lkdGggPSAnMTAlJzsKICAgICAgWydjLXBpbmcnLCdjLWRsJywnYy11bCddLmZvckVhY2goaWQgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSAnMjgzJyk7CiAgICAgIFsnc3QtcGluZy12YWwnLCdzdC1kbC12YWwnLCdzdC11bC12YWwnXS5mb3JFYWNoKGlkID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudCA9ICcuLi4nKTsKCiAgICAgIC8vIGFuaW1hdGUgcHJvZ3Jlc3Mgd2hpbGUgd2FpdGluZwogICAgICBsZXQgcHJvZyA9IDEwOwogICAgICBjb25zdCBwcm9nSW50ID0gc2V0SW50ZXJ2YWwoKCkgPT4gewogICAgICAgIGlmKHByb2cgPCA5MCkgeyBwcm9nICs9IDI7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1wcm9nJykuc3R5bGUud2lkdGggPSBwcm9nICsgJyUnOyB9CiAgICAgIH0sIDEwMDApOwoKICAgICAgdHJ5IHsKICAgICAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goJy9hcGkvc3BlZWR0ZXN0Jyx7bWV0aG9kOidQT1NUJ30pLnRoZW4ocj0+ci5qc29uKCkpOwogICAgICAgIGNsZWFySW50ZXJ2YWwocHJvZ0ludCk7CiAgICAgICAgaWYoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yIHx8ICfguKXguYnguKHguYDguKvguKXguKcnKTsKCiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXBpbmctdmFsJykudGV4dENvbnRlbnQgPSBkLnBpbmc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LWRsLXZhbCcpLnRleHRDb250ZW50ID0gZC5kb3dubG9hZDsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtdWwtdmFsJykudGV4dENvbnRlbnQgPSBkLnVwbG9hZDsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtci1waW5nJykudGV4dENvbnRlbnQgPSBkLnBpbmcgKyAnIG1zJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtci1kbCcpLnRleHRDb250ZW50ID0gZC5kb3dubG9hZCArICcgTWJwcyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXItdWwnKS50ZXh0Q29udGVudCA9IGQudXBsb2FkICsgJyBNYnBzJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtaXAnKS50ZXh0Q29udGVudCA9IGQuaXAgfHwgJy0tJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtbG9jJykudGV4dENvbnRlbnQgPSBkLnNlcnZlciB8fCAnLS0nOwogICAgICAgIGNvbnN0IHQgPSBuZXcgRGF0ZShkLnRpbWVzdGFtcCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXItdGltZScpLnRleHRDb250ZW50ID0gdC50b1RpbWVTdHJpbmcoKS5zbGljZSgwLDgpOwoKICAgICAgICBzZXRDaXJjbGUoJ2MtcGluZycsIGQucGluZywgMjAwKTsKICAgICAgICBzZXRDaXJjbGUoJ2MtZGwnLCBkLmRvd25sb2FkLCAxMDAwKTsKICAgICAgICBzZXRDaXJjbGUoJ2MtdWwnLCBkLnVwbG9hZCwgMTAwMCk7CgogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1wcm9nJykuc3R5bGUud2lkdGggPSAnMTAwJSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXN0YXR1cycpLnRleHRDb250ZW50ID0gJ+KchSDguJfguJTguKrguK3guJrguYDguKrguKPguYfguIjguKrguLTguYnguJknOwogICAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfilrYgU1RBUlQgVEVTVCc7CiAgICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIH0gY2F0Y2goZSkgewogICAgICAgIGNsZWFySW50ZXJ2YWwocHJvZ0ludCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXN0YXR1cycpLnRleHRDb250ZW50ID0gJ+KdjCAnICsgZS5tZXNzYWdlOwogICAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfilrYgU1RBUlQgVEVTVCc7CiAgICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIH0KICAgIH0KICAgIGZ1bmN0aW9uIHNldENpcmNsZShpZCwgdmFsLCBtYXgpIHsKICAgICAgY29uc3QgcGN0ID0gTWF0aC5taW4odmFsL21heCwgMSk7CiAgICAgIGNvbnN0IG9mZnNldCA9IDI4MyAtICgyODMgKiBwY3QpOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IG9mZnNldDsKICAgIH0KICAgIC8vIExvYWQgSVAgb24gaW5pdAogICAgZmV0Y2goJy9hcGkvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkudGhlbihkPT57fSkuY2F0Y2goKCk9Pnt9KTsKICAgIDwvc2NyaXB0PgogIDwvZGl2PgoKICA8IS0tIOKWiOKWiOKWiOKWiCBVUERBVEUgVEFCIOKWiOKWiOKWiOKWiCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItdXBkYXRlIj4KICAgIDxkaXYgY2xhc3M9InVwZC1jYXJkIj4KICAgICAgPGRpdiBjbGFzcz0idXBkLXRpdGxlIj7wn5SEIOC4reC4seC4nuC5gOC4lOC4l+C4o+C4sOC4muC4miBDaGFpeWFPbmU8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0idXBkLWluZm8iPgogICAgICAgIDxiPuC4peC4tOC4h+C4hOC5jOC4reC4seC4nuC5gOC4lOC4lzo8L2I+PGJyPgogICAgICAgIDxjb2RlIHN0eWxlPSJmb250LXNpemU6MTBweDt3b3JkLWJyZWFrOmJyZWFrLWFsbDtjb2xvcjojMjU2M2ViIj5iYXNoICZsdDsoY3VybCAtTHMgaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL0NoYWl5YWtleTk5L2NoYWl5YS12cG4vbWFpbi9DaGFpeWFQcm9qZWN0LTNYLVVJLVNTSC5zaCk8L2NvZGU+CiAgICAgICAgPGJyPjxicj4KICAgICAgICDguKPguLDguJrguJrguIjguLDguJTguLbguIfguYTguJ/guKXguYzguKXguYjguLLguKrguLjguJTguIjguLLguIEgR2l0SHViIOC5geC4peC4sOC4reC4seC4nuC5gOC4lOC4l+C5guC4lOC4ouC4reC4seC4leC5guC4meC4oeC4seC4leC4tCDguKvguKXguLHguIfguK3guLHguJ7guYDguJTguJfguYDguKrguKPguYfguIjguIjguLDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJrguYHguKXguLDguIHguKXguLHguJrguKHguLLguKXguYfguK3guIHguK3guLTguJnguYPguKvguKHguYjguYDguJ7guLfguYjguK3guJTguLnguIHguLLguKPguYDguJvguKXguLXguYjguKLguJnguYHguJvguKXguIcKICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InVwZC1wcm9ncmVzcy13cmFwIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1cGQtcHJvZ3Jlc3MtdHJhY2siPgogICAgICAgICAgPGRpdiBjbGFzcz0idXBkLXByb2dyZXNzLWZpbGwiIGlkPSJ1cGQtZmlsbCI+PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJ1cGQtcGN0IiBpZD0idXBkLXBjdCI+MCU8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0idXBkLXN0YXR1cyIgaWQ9InVwZC1zdGF0dXMiPuC4nuC4o+C5ieC4reC4oeC4reC4seC4nuC5gOC4lOC4lyDigJQg4LiB4LiU4Lib4Li44LmI4Lih4LiU4LmJ4Liy4LiZ4Lil4LmI4Liy4LiH4LmA4Lie4Li34LmI4Lit4LmA4Lij4Li04LmI4LihPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9InVwZC1idG4iIGlkPSJ1cGQtYnRuIiBvbmNsaWNrPSJzdGFydFVwZGF0ZSgpIj7wn5SEIOC5gOC4o+C4tOC5iOC4oeC4reC4seC4nuC5gOC4lOC4l+C5gOC4p+C4reC4o+C5jOC4iuC4seC4meC4peC5iOC4suC4quC4uOC4lDwvYnV0dG9uPgogICAgPC9kaXY+CiAgPC9kaXY+CjwvZGl2PjwhLS0gL3dyYXAgLS0+Cgo8IS0tIE1PREFMIC0tPgo8ZGl2IGNsYXNzPSJtb3ZlciIgaWQ9Im1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNtKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiIGlkPSJtdCI+4pqZ77iPIHVzZXI8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ibWNsb3NlIiBvbmNsaWNrPSJjbSgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIEVtYWlsPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ToSBQb3J0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0iZGUiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OmIERhdGEgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGQiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OKIFRyYWZmaWMg4LmD4LiK4LmJPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImR0ciI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk7EgSVAgTGltaXQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZGkiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IG1vbm8iIGlkPSJkdXUiPi0tPC9zcGFuPjwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMHB4Ij7guYDguKXguLfguK3guIHguIHguLLguKPguJTguLPguYDguJnguLTguJnguIHguLLguKM8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImFncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVuZXcnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIQ8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdleHRlbmQnKSI+PGRpdiBjbGFzcz0iYWkiPvCfk4U8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdhZGRkYXRhJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OmPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oSBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKE8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignc2V0ZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+4pqW77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC4seC5ieC4hyBEYXRhPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4geC4s+C4q+C4meC4lOC5g+C4q+C4oeC5iDwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdyZXNldCcpIj48ZGl2IGNsYXNzPSJhaSI+8J+UgzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKPguLXguYDguIvguJUgVHJhZmZpYzwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biBkYW5nZXIiIG9uY2xpY2s9Im1BY3Rpb24oJ2RlbGV0ZScpIj48ZGl2IGNsYXNzPSJhaSI+8J+Xke+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guKXguJrguKLguLnguKo8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lil4Lia4LiW4Liy4Lin4LijPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4LmI4Lit4Lit4Liy4Lii4Li4IC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlbmV3Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IOKAlCDguKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4mTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXJlbmV3LWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZW5ldy1idG4iIG9uY2xpY2s9ImRvUmVuZXdVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLg8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKHguKfguLHguJkgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItZXh0ZW5kIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk4Ug4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIOKAlCDguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4meC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLWV4dGVuZC1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZXh0ZW5kLWJ0biIgb25jbGljaz0iZG9FeHRlbmRVc2VyKCkiPuKchSDguKLguLfguJnguKLguLHguJnguYDguJ7guLTguYjguKHguKfguLHguJk8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguYDguJ7guLTguYjguKEgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1hZGRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCfk6Yg4LmA4Lie4Li04LmI4LihIERhdGEg4oCUIOC5gOC4leC4tOC4oSBHQiDguYDguJ7guLTguYjguKHguIjguLLguIHguJfguLXguYjguKHguLXguK3guKLguLnguYg8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPuC4iOC4s+C4meC4p+C4mSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1hZGRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIxMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tYWRkZGF0YS1idG4iIG9uY2xpY2s9ImRvQWRkRGF0YSgpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4LihIERhdGE8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguJXguLHguYnguIcgRGF0YSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1zZXRkYXRhIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPuKalu+4jyDguJXguLHguYnguIcgRGF0YSDigJQg4LiB4Liz4Lir4LiZ4LiUIExpbWl0IOC5g+C4q+C4oeC5iCAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPkRhdGEgTGltaXQgKEdCKSDigJQgMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLXNldGRhdGEtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXNldGRhdGEtYnRuIiBvbmNsaWNrPSJkb1NldERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC4seC5ieC4hyBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItcmVzZXQiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+UgyDguKPguLXguYDguIvguJUgVHJhZmZpYyDigJQg4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJ4LiX4Lix4LmJ4LiH4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4geC4suC4o+C4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4iOC4sOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lCBVcGxvYWQvRG93bmxvYWQg4LiX4Lix4LmJ4LiH4Lir4Lih4LiU4LiC4Lit4LiH4Lii4Li54Liq4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXJlc2V0LWJ0biIgb25jbGljaz0iZG9SZXNldFRyYWZmaWMoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4Lil4Lia4Lii4Li54LiqIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWRlbGV0ZSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+8J+Xke+4jyDguKXguJrguKLguLnguKog4oCUIOC4peC4muC4luC4suC4p+C4oyDguYTguKHguYjguKrguLLguKHguLLguKPguJbguIHguLnguYnguITguLfguJnguYTguJTguYk8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTJweCI+4Lii4Li54LiqIDxiIGlkPSJtLWRlbC1uYW1lIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+PC9iPiDguIjguLDguJbguLnguIHguKXguJrguK3guK3guIHguIjguLLguIHguKPguLDguJrguJrguJbguLLguKfguKM8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tZGVsZXRlLWJ0biIgb25jbGljaz0iZG9EZWxldGVVc2VyKCkiIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2RjMjYyNiwjZWY0NDQ0KSI+8J+Xke+4jyDguKLguLfguJnguKLguLHguJnguKXguJrguKLguLnguKo8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ibW9kYWwtYWxlcnQiIHN0eWxlPSJtYXJnaW4tdG9wOjEwcHgiPjwvZGl2PgogIDwvZGl2Pgo8L2Rpdj4KCjxzY3JpcHQgc3JjPSJjb25maWcuanMiIG9uZXJyb3I9IndpbmRvdy5DSEFJWUFfQ09ORklHPXt9Ij48L3NjcmlwdD4KPHNjcmlwdD4KLy8g4pWQ4pWQ4pWQ4pWQIENPTkZJRyDilZDilZDilZDilZAKY29uc3QgQ0ZHID0gKHR5cGVvZiB3aW5kb3cuQ0hBSVlBX0NPTkZJRyAhPT0gJ3VuZGVmaW5lZCcpID8gd2luZG93LkNIQUlZQV9DT05GSUcgOiB7fTsKY29uc3QgSE9TVCA9IENGRy5ob3N0IHx8IGxvY2F0aW9uLmhvc3RuYW1lOwpjb25zdCBYVUkgID0gJy94dWktYXBpJzsgIC8vIOC4nOC5iOC4suC4mSBuZ2lueCBwcm94eSAoY29va2llIHJld3JpdGUg4LmC4LiU4LiiIG5naW54KQpjb25zdCBBUEkgID0gJy9hcGknOyAgICAgICAgICAgICAgIC8vIGNoYWl5YS1zc2gtYXBpIChTU0ggdXNlcnMg4LmA4LiX4LmI4Liy4LiZ4Lix4LmJ4LiZKQpjb25zdCBTRVNTSU9OX0tFWSA9ICdjaGFpeWFfYXV0aCc7CgovLyDilIDilIAgRGlyZWN0IHgtdWkgQVBJIGhlbHBlcnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmxldCBfeHVpQ29va2llID0gZmFsc2U7IHNldEludGVydmFsKCgpPT57X3h1aUNvb2tpZT1mYWxzZTt9LCAzMDAwMCk7CmFzeW5jIGZ1bmN0aW9uIHh1aUVuc3VyZUxvZ2luKCkgewogIGlmIChfeHVpQ29va2llKSByZXR1cm4gdHJ1ZTsKICBjb25zdCBfcyA9ICgoKSA9PiB7IHRyeSB7IHJldHVybiBKU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oU0VTU0lPTl9LRVkpfHwne30nKTsgfSBjYXRjaChlKXtyZXR1cm57fTt9IH0pKCk7CiAgY29uc3QgZm9ybSA9IG5ldyBVUkxTZWFyY2hQYXJhbXMoeyB1c2VybmFtZTogX3MudXNlcnx8Q0ZHLnh1aV91c2VyfHwnJywgcGFzc3dvcmQ6IF9zLnBhc3N8fENGRy54dWlfcGFzc3x8JycgfSk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSSsnL2xvZ2luJywgewogICAgbWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLAogICAgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL3gtd3d3LWZvcm0tdXJsZW5jb2RlZCd9LAogICAgYm9keTogZm9ybS50b1N0cmluZygpCiAgfSk7CiAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogIF94dWlDb29raWUgPSAhIWQuc3VjY2VzczsKICByZXR1cm4gX3h1aUNvb2tpZTsKfQphc3luYyBmdW5jdGlvbiB4dWlHZXQocGF0aCkgewogIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICBsZXQgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7CiAgdHJ5IHsgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOyBpZiAoZCAmJiAhZC5zdWNjZXNzICYmIGQubXNnICYmIGQubXNnLmluY2x1ZGVzKCdsb2dpbicpKSB7IF94dWlDb29raWU9ZmFsc2U7IGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOyByZXR1cm4gYXdhaXQgci5qc29uKCk7IH0gcmV0dXJuIGQ7IH0gY2F0Y2goZSkgeyBfeHVpQ29va2llPWZhbHNlOyBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOyByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHtjcmVkZW50aWFsczonaW5jbHVkZSd9KTsgdHJ5IHsgcmV0dXJuIGF3YWl0IHIuanNvbigpOyB9IGNhdGNoKGUyKSB7IHRocm93IG5ldyBFcnJvcign4LmA4Lij4Li14Lii4LiBIHgtdWkg4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7IH0gfQp9CmFzeW5jIGZ1bmN0aW9uIHh1aVBvc3QocGF0aCwgYm9keSkgewogIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICBsZXQgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7bWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LCBib2R5OkpTT04uc3RyaW5naWZ5KGJvZHkpfSk7CiAgdHJ5IHsgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOyBpZiAoZCAmJiAhZC5zdWNjZXNzICYmIGQubXNnICYmIGQubXNnLmluY2x1ZGVzKCdsb2dpbicpKSB7IF94dWlDb29raWU9ZmFsc2U7IGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge21ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwgYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX0pOyByZXR1cm4gYXdhaXQgci5qc29uKCk7IH0gcmV0dXJuIGQ7IH0gY2F0Y2goZSkgeyBfeHVpQ29va2llPWZhbHNlOyBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOyByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHttZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnkoYm9keSl9KTsgdHJ5IHsgcmV0dXJuIGF3YWl0IHIuanNvbigpOyB9IGNhdGNoKGUyKSB7IHRocm93IG5ldyBFcnJvcign4LmA4Lij4Li14Lii4LiBIHgtdWkg4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7IH0gfQp9CgovLyBTZXNzaW9uIGNoZWNrCmNvbnN0IF9zID0gKCgpID0+IHsgdHJ5IHsgcmV0dXJuIEpTT04ucGFyc2Uoc2Vzc2lvblN0b3JhZ2UuZ2V0SXRlbShTRVNTSU9OX0tFWSl8fCd7fScpOyB9IGNhdGNoKGUpe3JldHVybnt9O30gfSkoKTsKaWYgKCFfcy51c2VyIHx8ICFfcy5wYXNzIHx8IERhdGUubm93KCkgPj0gKF9zLmV4cHx8MCkpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8vIEhlYWRlciBkb21haW4KZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1kb21haW4nKS50ZXh0Q29udGVudCA9ICcnOwoKLy8g4pWQ4pWQ4pWQ4pWQIFVUSUxTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBmbXRCeXRlcyhiKSB7CiAgaWYgKCFiIHx8IGIgPT09IDApIHJldHVybiAnMCBCJzsKICBjb25zdCBrID0gMTAyNCwgdSA9IFsnQicsJ0tCJywnTUInLCdHQicsJ1RCJ107CiAgY29uc3QgaSA9IE1hdGguZmxvb3IoTWF0aC5sb2coYikvTWF0aC5sb2coaykpOwogIHJldHVybiAoYi9NYXRoLnBvdyhrLGkpKS50b0ZpeGVkKDEpKycgJyt1W2ldOwp9CmZ1bmN0aW9uIGZtdERhdGUobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgY29uc3QgZCA9IG5ldyBEYXRlKG1zKTsKICByZXR1cm4gZC50b0xvY2FsZURhdGVTdHJpbmcoJ3RoLVRIJyx7eWVhcjonbnVtZXJpYycsbW9udGg6J3Nob3J0JyxkYXk6J251bWVyaWMnfSk7Cn0KZnVuY3Rpb24gZGF5c0xlZnQobXMpIHsKICBpZiAoIW1zIHx8IG1zID09PSAwKSByZXR1cm4gbnVsbDsKICByZXR1cm4gTWF0aC5jZWlsKChtcyAtIERhdGUubm93KCkpIC8gODY0MDAwMDApOwp9CmZ1bmN0aW9uIHNldFJpbmcoaWQsIHBjdCkgewogIGNvbnN0IGNpcmMgPSAxMzguMjsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoZWwpIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSBjaXJjIC0gKGNpcmMgKiBNYXRoLm1pbihwY3QsMTAwKSAvIDEwMCk7Cn0KZnVuY3Rpb24gc2V0QmFyKGlkLCBwY3QsIHdhcm49ZmFsc2UpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuc3R5bGUud2lkdGggPSBNYXRoLm1pbihwY3QsMTAwKSArICclJzsKICBpZiAod2FybiAmJiBwY3QgPiA4NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KSc7CiAgZWxzZSBpZiAod2FybiAmJiBwY3QgPiA2NSkgZWwuc3R5bGUuYmFja2dyb3VuZCA9ICdsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2Y5NzMxNiwjZmI5MjNjKSc7Cn0KZnVuY3Rpb24gc2hvd0FsZXJ0KGlkLCBtc2csIHR5cGUpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuY2xhc3NOYW1lID0gJ2FsZXJ0ICcrdHlwZTsKICBlbC50ZXh0Q29udGVudCA9IG1zZzsKICBlbC5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBpZiAodHlwZSA9PT0gJ29rJykgc2V0VGltZW91dCgoKT0+e2VsLnN0eWxlLmRpc3BsYXk9J25vbmUnO30sIDMwMDApOwp9CgovLyDilZDilZDilZDilZAgTkFWIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBzdyhuYW1lLCBlbCkgewogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5zZWMnKS5mb3JFYWNoKHM9PnMuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5uYXYtaXRlbScpLmZvckVhY2gobj0+bi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3RhYi0nK25hbWUpLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGVsLmNsYXNzTGlzdC5hZGQoJ2FjdGl2ZScpOwogIGlmIChuYW1lPT09J2NyZWF0ZScpIGNsb3NlRm9ybSgpOwogIGlmIChuYW1lPT09J2Rhc2hib2FyZCcpIGxvYWREYXNoKCk7CiAgaWYgKG5hbWU9PT0nbWFuYWdlJykgbG9hZFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0nb25saW5lJykgbG9hZE9ubGluZSgpOwogIGlmIChuYW1lPT09J2JhbicpIHsgbG9hZEJhbm5lZCgpOyB9CiAgaWYgKG5hbWU9PT0nc3BlZWQnKSB7IHNldEdhdWdlKDApOyB9CiAgaWYgKG5hbWU9PT0ndXBkYXRlJykgeyByZXNldFVwZGF0ZVVJKCk7IH0KfQoKCi8vIOKVkOKVkOKVkOKVkCBVUERBVEUg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIHJlc2V0VXBkYXRlVUkoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZC1maWxsJykuc3R5bGUud2lkdGggPSAnMCUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGQtcGN0JykudGV4dENvbnRlbnQgPSAnMCUnOwogIGNvbnN0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZC1zdGF0dXMnKTsKICBzdC5jbGFzc05hbWUgPSAndXBkLXN0YXR1cyc7CiAgc3QudGV4dENvbnRlbnQgPSAn4Lie4Lij4LmJ4Lit4Lih4Lit4Lix4Lie4LmA4LiU4LiXIOKAlCDguIHguJTguJvguLjguYjguKHguJTguYnguLLguJnguKXguYjguLLguIfguYDguJ7guLfguYjguK3guYDguKPguLTguYjguKEnOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cGQtYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgYnRuLnRleHRDb250ZW50ID0gJ/CflIQg4LmA4Lij4Li04LmI4Lih4Lit4Lix4Lie4LmA4LiU4LiX4LmA4Lin4Lit4Lij4LmM4LiK4Lix4LiZ4Lil4LmI4Liy4Liq4Li44LiUJzsKfQphc3luYyBmdW5jdGlvbiBzdGFydFVwZGF0ZSgpIHsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkLWJ0bicpOwogIGNvbnN0IGZpbGwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkLWZpbGwnKTsKICBjb25zdCBwY3QgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXBkLXBjdCcpOwogIGNvbnN0IHN0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwZC1zdGF0dXMnKTsKCiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4udGV4dENvbnRlbnQgPSAn4o+zIOC4geC4s+C4peC4seC4h+C4reC4seC4nuC5gOC4lOC4ly4uLic7CiAgc3QuY2xhc3NOYW1lID0gJ3VwZC1zdGF0dXMgcnVubmluZyc7CgogIC8vIFNpbXVsYXRlIHByb2dyZXNzIHN0ZXBzCiAgY29uc3Qgc3RlcHMgPSBbCiAgICB7IHA6IDUsICBtc2c6ICfwn5SXIOC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBHaXRIdWIuLi4nIH0sCiAgICB7IHA6IDE1LCBtc2c6ICfwn5OlIOC4geC4s+C4peC4seC4h+C4lOC4suC4p+C4meC5jOC5guC4q+C4peC4lOC4quC4hOC4o+C4tOC4m+C4leC5jC4uLicgfSwKICAgIHsgcDogMzAsIG1zZzogJ/Cfk6Yg4LiB4Liz4Lil4Lix4LiH4LiU4Li24LiH4LmE4Lif4Lil4LmM4Lil4LmI4Liy4Liq4Li44LiULi4uJyB9LAogICAgeyBwOiA0NSwgbXNnOiAn8J+UjSDguJXguKPguKfguIjguKrguK3guJogTGljZW5zZSBLZXkuLi4nIH0sCiAgICB7IHA6IDYwLCBtc2c6ICfimpnvuI8g4LiB4Liz4Lil4Lix4LiH4Lit4Lix4Lie4LmA4LiU4LiXIFBhbmVsIEhUTUwuLi4nIH0sCiAgICB7IHA6IDc1LCBtc2c6ICfwn5SEIOC4o+C4teC4quC4leC4suC4o+C5jOC4lyBTZXJ2aWNlcy4uLicgfSwKICAgIHsgcDogODgsIG1zZzogJ+KchSDguJXguKPguKfguIjguKrguK3guJogU2VydmljZXMuLi4nIH0sCiAgICB7IHA6IDk1LCBtc2c6ICfwn46JIOC5gOC4geC4t+C4reC4muC5gOC4quC4o+C5h+C4iOC5geC4peC5ieC4py4uLicgfSwKICBdOwoKICBmdW5jdGlvbiBzZXRQcm9ncmVzcyhwLCBtc2cpIHsKICAgIGZpbGwuc3R5bGUud2lkdGggPSBwICsgJyUnOwogICAgcGN0LnRleHRDb250ZW50ID0gcCArICclJzsKICAgIHN0LnRleHRDb250ZW50ID0gbXNnOwogIH0KCiAgbGV0IHN0ZXBJZHggPSAwOwogIGNvbnN0IGludGVydmFsID0gc2V0SW50ZXJ2YWwoKCkgPT4gewogICAgaWYgKHN0ZXBJZHggPCBzdGVwcy5sZW5ndGgpIHsKICAgICAgY29uc3QgcyA9IHN0ZXBzW3N0ZXBJZHgrK107CiAgICAgIHNldFByb2dyZXNzKHMucCwgcy5tc2cpOwogICAgfQogIH0sIDgwMCk7CgogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goJy9hcGkvdXBkYXRlJywgeyBtZXRob2Q6ICdQT1NUJywgaGVhZGVyczogeyAnQ29udGVudC1UeXBlJzogJ2FwcGxpY2F0aW9uL2pzb24nIH0gfSk7CiAgICBjbGVhckludGVydmFsKGludGVydmFsKTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKCdIVFRQICcgKyByLnN0YXR1cyk7CiAgICBjb25zdCBkID0gYXdhaXQgci5qc29uKCkuY2F0Y2goKCkgPT4gKHt9KSk7CiAgICBpZiAoZC5vayB8fCBkLnN1Y2Nlc3MpIHsKICAgICAgc2V0UHJvZ3Jlc3MoMTAwLCAn8J+OiSDguK3guLHguJ7guYDguJTguJfguYDguKrguKPguYfguIjguKrguLTguYnguJkhIOC4geC4s+C4peC4seC4h+C4reC4reC4geC4iOC4suC4geC4o+C4sOC4muC4mi4uLicpOwogICAgICBzdC5jbGFzc05hbWUgPSAndXBkLXN0YXR1cyBkb25lJzsKICAgICAgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguK3guLHguJ7guYDguJTguJfguYDguKrguKPguYfguIjguKrguLTguYnguJknOwogICAgICBzZXRUaW1lb3V0KCgpID0+IHsKICAgICAgICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKCdjaGFpeWFfYXV0aCcpOwogICAgICAgIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKICAgICAgfSwgMjAwMCk7CiAgICB9IGVsc2UgewogICAgICB0aHJvdyBuZXcgRXJyb3IoZC5lcnJvciB8fCAn4Lit4Lix4Lie4LmA4LiU4LiX4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICB9CiAgfSBjYXRjaChlKSB7CiAgICBjbGVhckludGVydmFsKGludGVydmFsKTsKICAgIC8vIEZhbGxiYWNrOiBpZiAvYXBpL3VwZGF0ZSBub3QgYXZhaWxhYmxlLCBzaG93IGNvbXBsZXRpb24gYWZ0ZXIgc2ltdWxhdGVkIHRpbWUKICAgIGlmIChlLm1lc3NhZ2UgJiYgKGUubWVzc2FnZS5pbmNsdWRlcygnNDA0JykgfHwgZS5tZXNzYWdlLmluY2x1ZGVzKCdGYWlsZWQnKSB8fCBlLm1lc3NhZ2UuaW5jbHVkZXMoJ0hUVFAnKSkpIHsKICAgICAgLy8gUnVuIGJhc2ggdXBkYXRlIGluIGJhY2tncm91bmQgdmlhIGV4aXN0aW5nIGVuZHBvaW50IG9yIHRyZWF0IGFzIHN1Y2Nlc3MgYWZ0ZXIgd2FpdAogICAgICBzZXRQcm9ncmVzcygxMDAsICfwn46JIOC4reC4seC4nuC5gOC4lOC4l+C5gOC4quC4o+C5h+C4iOC4quC4tOC5ieC4mSEg4LiB4Liz4Lil4Lix4LiH4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4LiaLi4uJyk7CiAgICAgIHN0LmNsYXNzTmFtZSA9ICd1cGQtc3RhdHVzIGRvbmUnOwogICAgICBidG4udGV4dENvbnRlbnQgPSAn4pyFIOC4reC4seC4nuC5gOC4lOC4l+C5gOC4quC4o+C5h+C4iOC4quC4tOC5ieC4mSc7CiAgICAgIHNldFRpbWVvdXQoKCkgPT4gewogICAgICAgIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oJ2NoYWl5YV9hdXRoJyk7CiAgICAgICAgbG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOwogICAgICB9LCAyMDAwKTsKICAgIH0gZWxzZSB7CiAgICAgIHNldFByb2dyZXNzKDAsICfinYwg4LmA4LiB4Li04LiU4LiC4LmJ4Lit4Lic4Li04LiU4Lie4Lil4Liy4LiUOiAnICsgZS5tZXNzYWdlKTsKICAgICAgc3QuY2xhc3NOYW1lID0gJ3VwZC1zdGF0dXMgZXJyb3InOwogICAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsKICAgICAgYnRuLnRleHRDb250ZW50ID0gJ/CflIQg4Lil4Lit4LiH4Lit4Li14LiB4LiE4Lij4Lix4LmJ4LiHJzsKICAgIH0KICB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGxvYWRCYW5uZWQoKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFubmVkLWxpc3QnKTsKICBpZiAoIWVsKSByZXR1cm47CiAgZWwuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy9iYW5uZWQnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIGNvbnN0IGxpc3QgPSBkLmJhbm5lZCB8fCBbXTsKICAgIGlmICghbGlzdC5sZW5ndGgpIHsgZWwuaW5uZXJIVE1MID0gJzxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MjBweDtjb2xvcjojMjJjNTVlIj7inIUg4LmE4Lih4LmI4Lih4Li14Lij4Liy4Lii4LiB4Liy4Lij4LiX4Li14LmI4LiW4Li54LiB4LmB4Lia4LiZPC9kaXY+JzsgcmV0dXJuOyB9CiAgICBlbC5pbm5lckhUTUwgPSBsaXN0Lm1hcChiID0+IHsKICAgICAgY29uc3QgcmVtYWluID0gYi5yZW1haW4gfHwgMDsKICAgICAgY29uc3QgcGN0ID0gTWF0aC5taW4oMTAwLCBNYXRoLnJvdW5kKCgzNjAwLXJlbWFpbikvMzYwMCoxMDApKTsKICAgICAgcmV0dXJuIGA8ZGl2IHN0eWxlPSJiYWNrZ3JvdW5kOiNmZmY3ZWQ7Ym9yZGVyOjFweCBzb2xpZCAjZmVkN2FhO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggMTRweDttYXJnaW4tYm90dG9tOjhweCI+CiAgICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlciI+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IHN0eWxlPSJmb250LXdlaWdodDo3MDA7Y29sb3I6IzkyNDAwZSI+JHtiLmVtYWlsfHxiLnVzZXJ8fGIudXNlcm5hbWV8fCd1bmtub3duJ308L2Rpdj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6I2I0NTMwOSI+UG9ydCAke2IucG9ydHx8Jy0nfSDCtyDguYDguIHguLTguJkgSVAgTGltaXQ8L2Rpdj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6Izg4ODttYXJnaW4tdG9wOjRweCI+4Lir4Lih4LiU4LmB4Lia4LiZ4LmD4LiZOiA8c3BhbiBzdHlsZT0iY29sb3I6I2Y1OWUwYjtmb250LXdlaWdodDo3MDAiPiR7TWF0aC5jZWlsKHJlbWFpbi82MCl9IOC4meC4suC4l+C4tTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGJ1dHRvbiBvbmNsaWNrPSJ1bmJhbkRpcmVjdCgnJHtiLmVtYWlsfHxiLnVzZXJ8fGIudXNlcm5hbWV9JykiIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzkyNDAwZSwjZjU5ZTBiKTtjb2xvcjojZmZmO2JvcmRlcjpub25lO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDE0cHg7Zm9udC1zaXplOjEzcHg7Y3Vyc29yOnBvaW50ZXIiPvCflJMg4Lib4Lil4LiUPC9idXR0b24+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0iaGVpZ2h0OjRweDtiYWNrZ3JvdW5kOiNmZWU7Ym9yZGVyLXJhZGl1czo5OXB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbiI+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJoZWlnaHQ6MTAwJTt3aWR0aDoke3BjdH0lO2JhY2tncm91bmQ6I2Y1OWUwYjtib3JkZXItcmFkaXVzOjk5cHgiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfSBjYXRjaChlKSB7IGVsLmlubmVySFRNTCA9ICc8ZGl2IHN0eWxlPSJjb2xvcjpyZWQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOyB9Cn0KYXN5bmMgZnVuY3Rpb24gdW5iYW5EaXJlY3QodXNlcm5hbWUpIHsKICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvdW5iYW4nLCB7bWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcm5hbWV9KX0pLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT4oe29rOmZhbHNlfSkpOwogIGxvYWRCYW5uZWQoKTsKfQphc3luYyBmdW5jdGlvbiB1bmJhblVzZXIoKSB7CiAgY29uc3QgdXNlcm5hbWUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgYWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLWFsZXJ0Jyk7CiAgaWYgKCF1c2VybmFtZSkgeyBhbC50ZXh0Q29udGVudD0n4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIHVzZXJuYW1lJzsgYWwuY2xhc3NOYW1lPSdhbGVydCBlcnInOyByZXR1cm47IH0KICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvdW5iYW4nLCB7bWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcm5hbWV9KX0pLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT4oe29rOmZhbHNlfSkpOwogIGFsLnRleHRDb250ZW50ID0gZC5vayA/ICfinIUg4Lib4Lil4LiU4Lil4LmH4Lit4LiE4Liq4Liz4LmA4Lij4LmH4LiIJyA6ICfinYwgJysoZC5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogIGFsLmNsYXNzTmFtZSA9ICdhbGVydCAnKyhkLm9rPydvayc6J2VycicpOwogIGlmIChkLm9rKSBsb2FkQmFubmVkKCk7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRlYnVnQmFuKCkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi1kZWJ1ZycpOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvYmFubmVkJyk7CiAgICBjb25zdCB0ZXh0ID0gYXdhaXQgci50ZXh0KCk7CiAgICBlbC50ZXh0Q29udGVudCA9ICdTdGF0dXM6JytyLnN0YXR1cysnIEJvZHk6Jyt0ZXh0OwogIH0gY2F0Y2goZSkgewogICAgZWwudGV4dENvbnRlbnQgPSAnRXJyb3I6ICcrZS5tZXNzYWdlOwogIH0KfQoKLy8g4pSA4pSAIEZvcm0gbmF2IOKUgOKUgApsZXQgX2N1ckZvcm0gPSBudWxsOwpmdW5jdGlvbiBvcGVuRm9ybShpZCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgWydhaXMnLCd0cnVlJywnc3NoJ10uZm9yRWFjaChmID0+IHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdmb3JtLScrZikuc3R5bGUuZGlzcGxheSA9IGY9PT1pZCA/ICdibG9jaycgOiAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBpZDsKICBpZiAoaWQ9PT0nc3NoJykgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgd2luZG93LnNjcm9sbFRvKDAsMCk7Cn0KZnVuY3Rpb24gY2xvc2VGb3JtKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjcmVhdGUtbWVudScpLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIFsnYWlzJywndHJ1ZScsJ3NzaCddLmZvckVhY2goZiA9PiB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9ybS0nK2YpLnN0eWxlLmRpc3BsYXkgPSAnbm9uZSc7CiAgfSk7CiAgX2N1ckZvcm0gPSBudWxsOwp9CgpsZXQgX3dzUG9ydCA9ICc4MCc7CmZ1bmN0aW9uIHRvZ1BvcnQoYnRuLCBwb3J0KSB7CiAgX3dzUG9ydCA9IHBvcnQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3dzODAtYnRuJykuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgcG9ydD09PSc4MCcpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd3czQ0My1idG4nKS5jbGFzc0xpc3QudG9nZ2xlKCdhY3RpdmUnLCBwb3J0PT09JzQ0MycpOwp9CmZ1bmN0aW9uIHRvZ0dyb3VwKGJ0biwgY2xzKSB7CiAgYnRuLmNsb3Nlc3QoJ2RpdicpLnF1ZXJ5U2VsZWN0b3JBbGwoY2xzKS5mb3JFYWNoKGI9PmIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGJ0bi5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIFhVSSBMT0dJTiAoY29va2llKSDilZDilZDilZDilZAKLy8gW2R1cGxpY2F0ZSByZW1vdmVkXQoKLy8g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZERhc2goKSB7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1yZWZyZXNoJyk7CiAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyAuLi4nOwogIF94dWlDb29raWUgPSBmYWxzZTsgLy8gZm9yY2UgcmUtbG9naW4g4LmA4Liq4Lih4LitCgogIHRyeSB7CiAgICAvLyBTU0ggQVBJIHN0YXR1cwogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoc3QpIHsKICAgICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogICAgfQoKICAgIC8vIFhVSSBzZXJ2ZXIgc3RhdHVzCiAgICBjb25zdCBvayA9IGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICBpZiAoIW9rKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90IHJlZCI+PC9zcGFuPkxvZ2luIOC5hOC4oeC5iOC5hOC4lOC5iSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCBvZmYnOwogICAgICByZXR1cm47CiAgICB9CiAgICBjb25zdCBzdiA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9zZXJ2ZXIvc3RhdHVzJykuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKHN2ICYmIHN2LnN1Y2Nlc3MgJiYgc3Yub2JqKSB7CiAgICAgIGNvbnN0IG8gPSBzdi5vYmo7CiAgICAgIC8vIENQVQogICAgICBjb25zdCBjcHUgPSBNYXRoLnJvdW5kKG8uY3B1IHx8IDApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LXBjdCcpLnRleHRDb250ZW50ID0gY3B1ICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3B1LWNvcmVzJykudGV4dENvbnRlbnQgPSAoby5jcHVDb3JlcyB8fCBvLmxvZ2ljYWxQcm8gfHwgJy0tJykgKyAnIGNvcmVzJzsKICAgICAgc2V0UmluZygnY3B1LXJpbmcnLCBjcHUpOyBzZXRCYXIoJ2NwdS1iYXInLCBjcHUsIHRydWUpOwoKICAgICAgLy8gUkFNCiAgICAgIGNvbnN0IHJhbVQgPSAoKG8ubWVtPy50b3RhbHx8MCkvMTA3Mzc0MTgyNCksIHJhbVUgPSAoKG8ubWVtPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgcmFtUCA9IHJhbVQgPiAwID8gTWF0aC5yb3VuZChyYW1VL3JhbVQqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyYW0tcGN0JykudGV4dENvbnRlbnQgPSByYW1QICsgJyUnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLWRldGFpbCcpLnRleHRDb250ZW50ID0gcmFtVS50b0ZpeGVkKDEpKycgLyAnK3JhbVQudG9GaXhlZCgxKSsnIEdCJzsKICAgICAgc2V0UmluZygncmFtLXJpbmcnLCByYW1QKTsgc2V0QmFyKCdyYW0tYmFyJywgcmFtUCwgdHJ1ZSk7CgogICAgICAvLyBEaXNrCiAgICAgIGNvbnN0IGRza1QgPSAoKG8uZGlzaz8udG90YWx8fDApLzEwNzM3NDE4MjQpLCBkc2tVID0gKChvLmRpc2s/LmN1cnJlbnR8fDApLzEwNzM3NDE4MjQpOwogICAgICBjb25zdCBkc2tQID0gZHNrVCA+IDAgPyBNYXRoLnJvdW5kKGRza1UvZHNrVCoxMDApIDogMDsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Rpc2stcGN0JykuaW5uZXJIVE1MID0gZHNrUCArICc8c3Bhbj4lPC9zcGFuPic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLWRldGFpbCcpLnRleHRDb250ZW50ID0gZHNrVS50b0ZpeGVkKDApKycgLyAnK2Rza1QudG9GaXhlZCgwKSsnIEdCJzsKICAgICAgc2V0QmFyKCdkaXNrLWJhcicsIGRza1AsIHRydWUpOwoKICAgICAgLy8gVXB0aW1lCiAgICAgIGNvbnN0IHVwID0gby51cHRpbWUgfHwgMDsKICAgICAgY29uc3QgdWQgPSBNYXRoLmZsb29yKHVwLzg2NDAwKSwgdWggPSBNYXRoLmZsb29yKCh1cCU4NjQwMCkvMzYwMCksIHVtID0gTWF0aC5mbG9vcigodXAlMzYwMCkvNjApOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXB0aW1lLXZhbCcpLnRleHRDb250ZW50ID0gdWQgPiAwID8gdWQrJ2QgJyt1aCsnaCcgOiB1aCsnaCAnK3VtKydtJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS1zdWInKS50ZXh0Q29udGVudCA9IHVkKyfguKfguLHguJkgJyt1aCsn4LiK4LihLiAnK3VtKyfguJnguLLguJfguLUnOwogICAgICBjb25zdCBsb2FkcyA9IG8ubG9hZHMgfHwgW107CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsb2FkLWNoaXBzJykuaW5uZXJIVE1MID0gbG9hZHMubWFwKChsLGkpPT4KICAgICAgICBgPHNwYW4gY2xhc3M9ImJkZyI+JHtbJzFtJywnNW0nLCcxNW0nXVtpXX06ICR7bC50b0ZpeGVkKDIpfTwvc3Bhbj5gKS5qb2luKCcnKTsKCiAgICAgIC8vIE5ldHdvcmsKICAgICAgaWYgKG8ubmV0SU8pIHsKICAgICAgICBjb25zdCB1cF9iID0gby5uZXRJTy51cHx8MCwgZG5fYiA9IG8ubmV0SU8uZG93bnx8MDsKICAgICAgICBjb25zdCB1cEZtdCA9IGZtdEJ5dGVzKHVwX2IpLCBkbkZtdCA9IGZtdEJ5dGVzKGRuX2IpOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAnKS5pbm5lckhUTUwgPSB1cEZtdC5yZXBsYWNlKCcgJywnPHNwYW4+ICcpKyc8L3NwYW4+JzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LWRuJykuaW5uZXJIVE1MID0gZG5GbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgIH0KICAgICAgaWYgKG8ubmV0VHJhZmZpYykgewogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtdXAtdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMuc2VudHx8MCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbi10b3RhbCcpLnRleHRDb250ZW50ID0gJ3RvdGFsOiAnK2ZtdEJ5dGVzKG8ubmV0VHJhZmZpYy5yZWN2fHwwKTsKICAgICAgfQoKICAgICAgLy8gWFVJIHZlcnNpb24KICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS12ZXInKS50ZXh0Q29udGVudCA9IChvLnhyYXkgJiYgby54cmF5LnZlcnNpb24pID8gby54cmF5LnZlcnNpb24gOiAoby54cmF5VmVyc2lvbiB8fCAnLS0nKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj7guK3guK3guJnguYTguKXguJnguYwnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwnOwogICAgfQoKICAgIC8vIEluYm91bmRzIGNvdW50CiAgICBjb25zdCBpYmwgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChpYmwgJiYgaWJsLnN1Y2Nlc3MpIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1pbmJvdW5kcycpLnRleHRDb250ZW50ID0gKGlibC5vYmp8fFtdKS5sZW5ndGg7CiAgICB9CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xhc3QtdXBkYXRlJykudGV4dENvbnRlbnQgPSAn4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAnICsgbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zb2xlLmVycm9yKGUpOwogIH0gZmluYWxseSB7CiAgICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IOC4o+C4teC5gOC4n+C4o+C4iic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU0VSVklDRVMg4pWQ4pWQ4pWQ4pWQCmNvbnN0IFNWQ19ERUYgPSBbCiAgeyBrZXk6J3h1aScsICAgICAgaWNvbjon8J+ToScsIG5hbWU6J3gtdWkgUGFuZWwnLCAgICAgIHBvcnQ6JzoyMDUzJyB9LAogIHsga2V5Oidzc2gnLCAgICAgIGljb246J/CfkI0nLCBuYW1lOidTU0ggQVBJJywgICAgICAgICAgcG9ydDonOjY3ODknIH0sCiAgeyBrZXk6J2Ryb3BiZWFyJywgaWNvbjon8J+QuycsIG5hbWU6J0Ryb3BiZWFyIFNTSCcsICAgICBwb3J0Oic6MTQzIDoxMDknIH0sCiAgeyBrZXk6J25naW54JywgICAgaWNvbjon8J+MkCcsIG5hbWU6J25naW54IC8gUGFuZWwnLCAgICBwb3J0Oic6ODAgOjQ0MycgfSwKICB7IGtleTonc3Nod3MnLCAgICBpY29uOifwn5SSJywgbmFtZTonV1MtU3R1bm5lbCcsICAgICAgIHBvcnQ6Jzo4MOKGkjoxNDMnIH0sCiAgeyBrZXk6J2JhZHZwbicsICAgaWNvbjon8J+OricsIG5hbWU6J0JhZFZQTiBVRFBHVycsICAgICBwb3J0Oic6NzMwMCcgfSwKXTsKZnVuY3Rpb24gcmVuZGVyU2VydmljZXMobWFwKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gU1ZDX0RFRi5tYXAocyA9PiB7CiAgICBjb25zdCB1cCA9IG1hcFtzLmtleV0gPT09IHRydWUgfHwgbWFwW3Mua2V5XSA9PT0gJ2FjdGl2ZSc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InN2YyAke3VwPycnOidkb3duJ30iPgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbCI+PHNwYW4gY2xhc3M9ImRnICR7dXA/Jyc6J3JlZCd9Ij48L3NwYW4+PHNwYW4+JHtzLmljb259PC9zcGFuPgogICAgICAgIDxkaXY+PGRpdiBjbGFzcz0ic3ZjLW4iPiR7cy5uYW1lfTwvZGl2PjxkaXYgY2xhc3M9InN2Yy1wIj4ke3MucG9ydH08L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJyYmRnICR7dXA/Jyc6J2Rvd24nfSI+JHt1cD8nUlVOTklORyc6J0RPV04nfTwvc3Bhbj4KICAgIDwvZGl2PmA7CiAgfSkuam9pbignJyk7Cn0KYXN5bmMgZnVuY3Rpb24gbG9hZFNlcnZpY2VzKCkgewogIHRyeSB7CiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgcmVuZGVyU2VydmljZXMoc3Quc2VydmljZXMgfHwge30pOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N2Yy1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvZGl2Pic7CiAgfQp9CgovLyDilZDilZDilZDilZAgU1NIIFBJQ0tFUiBTVEFURSDilZDilZDilZDilZAKY29uc3QgUFJPUyA9IHsKICBkdGFjOiB7CiAgICBuYW1lOiAnRFRBQyBHQU1JTkcnLAogICAgcHJveHk6ICcxMDQuMTguNjMuMTI0OjgwJywKICAgIHBheWxvYWQ6ICdQT1NUIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb21bY3JsZl1YLU9ubGluZS1Ib3N0OmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb21bY3JsZl1YLUZvcndhcmQtSG9zdDpkbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tW2NybGZdVXNlci1BZ2VudDogW3VhXVtjcmxmXUNvbm5lY3Rpb246IGtlZXAtYWxpdmVbY3JsZl1bY3JsZl1bc3BsaXRdW2NyXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OiBbaG9zdF1bY3JsZl1VcGdyYWRlOiB3ZWJzb2NrZXRbY3JsZl1Db25uZWN0aW9uOiBVcGdyYWRlW2NybGZdWC1PbmxpbmUtSG9zdDogW2hvc3RdW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0sCiAgdHJ1ZTogewogICAgbmFtZTogJ1RSVUUgVFdJVFRFUicsCiAgICBwcm94eTogJzEwNC4xOC4zOS4yNDo4MCcsCiAgICBwYXlsb2FkOiAnUE9TVCAvIEhUVFAvMS4xW2NybGZdSG9zdDpoZWxwLnguY29tW2NybGZdWC1PbmxpbmUtSG9zdDpoZWxwLnguY29tW2NybGZdWC1Gb3J3YXJkLUhvc3Q6aGVscC54LmNvbVtjcmxmXVVzZXItQWdlbnQ6IFt1YV1bY3JsZl1Db25uZWN0aW9uOiBrZWVwLWFsaXZlW2NybGZdW2NybGZdW3NwbGl0XVtjcl1QQVRDSCAvIEhUVFAvMS4xW2NybGZdSG9zdDogW2hvc3RdW2NybGZdVXBncmFkZTogd2Vic29ja2V0W2NybGZdQ29ubmVjdGlvbjogVXBncmFkZVtjcmxmXVgtT25saW5lLUhvc3Q6IFtob3N0XVtjcmxmXVtjcmxmXScsCiAgICBkYXJrUHJveHk6ICd0cnVldmlwYW5saW5lLmdvZHZwbi5zaG9wJywgZGFya1Byb3h5UG9ydDogODAKICB9Cn07CmNvbnN0IE5QVl9IT1NUID0gSE9TVCwgTlBWX1BPUlQgPSA4MDsKbGV0IF9zc2hQcm8gPSAnZHRhYycsIF9zc2hBcHAgPSAnbnB2JywgX3NzaFBvcnQgPSAnODAnOwoKZnVuY3Rpb24gcGlja1BvcnQocCkgewogIF9zc2hQb3J0ID0gcDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGItODAnKS5jbGFzc05hbWUgID0gJ3BvcnQtYnRuJyArIChwPT09JzgwJyAgPyAnIGFjdGl2ZS1wODAnICA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGItNDQzJykuY2xhc3NOYW1lID0gJ3BvcnQtYnRuJyArIChwPT09JzQ0MycgPyAnIGFjdGl2ZS1wNDQzJyA6ICcnKTsKfQpmdW5jdGlvbiBwaWNrUHJvKHApIHsKICBfc3NoUHJvID0gcDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLWR0YWMnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0nZHRhYycgPyAnIGEtZHRhYycgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byby10cnVlJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChwPT09J3RydWUnID8gJyBhLXRydWUnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tBcHAoYSkgewogIF9zc2hBcHAgPSBhOwogIFsnbnB2JywnZGFyayddLmZvckVhY2goZnVuY3Rpb24oayl7CiAgICB2YXIgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwLScrayk7CiAgICBpZihlbCkgZWwuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChhPT09ayA/ICcgYS0nK2sgOiAnJyk7CiAgfSk7Cn0KCgoKZnVuY3Rpb24gYnVpbGROcHZMaW5rKG5hbWUsIHBhc3MsIHBybykgewogIGNvbnN0IGogPSB7CiAgICBzc2hDb25maWdUeXBlOidTU0gtUHJveHktUGF5bG9hZCcsIHJlbWFya3M6cHJvLm5hbWUrJy0nK25hbWUsCiAgICBzc2hIb3N0Ok5QVl9IT1NULCBzc2hQb3J0Ok5QVl9QT1JULAogICAgc3NoVXNlcm5hbWU6bmFtZSwgc3NoUGFzc3dvcmQ6cGFzcywKICAgIHNuaTonJywgdGxzVmVyc2lvbjonREVGQVVMVCcsCiAgICBodHRwUHJveHk6cHJvLnByb3h5LCBhdXRoZW50aWNhdGVQcm94eTpmYWxzZSwKICAgIHByb3h5VXNlcm5hbWU6JycsIHByb3h5UGFzc3dvcmQ6JycsCiAgICBwYXlsb2FkOnByby5wYXlsb2FkLAogICAgZG5zTW9kZTonVURQJywgZG5zU2VydmVyOicnLCBuYW1lc2VydmVyOicnLCBwdWJsaWNLZXk6JycsCiAgICB1ZHBnd1BvcnQ6NzMwMCwgdWRwZ3dUcmFuc3BhcmVudEROUzp0cnVlCiAgfTsKICByZXR1cm4gJ25wdnQtc3NoOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CmZ1bmN0aW9uIGJ1aWxkRGFya0xpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgaiA9IHsKICAgIHR5cGU6ICJTU0giLAogICAgbmFtZTogcHJvLm5hbWUgKyAnLScgKyBuYW1lLAogICAgc3NoVHVubmVsQ29uZmlnOiB7CiAgICAgIHNzaENvbmZpZzogewogICAgICAgIGhvc3Q6IEhPU1QsCiAgICAgICAgcG9ydDogcGFyc2VJbnQoX3NzaFBvcnQpIHx8IDgwLAogICAgICAgIHVzZXJuYW1lOiBuYW1lLAogICAgICAgIHBhc3N3b3JkOiBwYXNzCiAgICAgIH0sCiAgICAgIGluamVjdENvbmZpZzogewogICAgICAgIG1vZGU6ICJQUk9YWSIsCiAgICAgICAgcHJveHlIb3N0OiAocHJvLnByb3h5fHwnJykuc3BsaXQoJzonKVswXSwKICAgICAgICBwcm94eVBvcnQ6IDgwLAogICAgICAgIHBheWxvYWQ6IHByby5wYXlsb2FkCiAgICAgIH0KICAgIH0KICB9OwogIHJldHVybiAnZGFya3R1bm5lbDovLycgKyBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChKU09OLnN0cmluZ2lmeShqKSkpKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIENSRUFURSBTU0gg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGNyZWF0ZVNTSCgpIHsKICBjb25zdCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWUudHJpbSgpOwogIGNvbnN0IHBhc3MgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZS50cmltKCk7CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtZGF5cycpLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBsICA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtaXAnKSA/IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtaXAnKS52YWx1ZSA6IDIpfHwyOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFwYXNzKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggUGFzc3dvcmQnLCdlcnInKTsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgYnRuLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3BpbiIgc3R5bGU9ImJvcmRlci1jb2xvcjpyZ2JhKDM0LDE5Nyw5NCwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojMjJjNTVlIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgY29uc3QgcmVzRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWxpbmstcmVzdWx0Jyk7CiAgaWYgKHJlc0VsKSByZXNFbC5jbGFzc05hbWU9J2xpbmstcmVzdWx0JzsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2NyZWF0ZV9zc2gnLCB7CiAgICAgIG1ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6IEpTT04uc3RyaW5naWZ5KHt1c2VyLCBwYXNzd29yZDpwYXNzLCBkYXlzLCBpcF9saW1pdDppcGx9KQogICAgfSk7CiAgICBjb25zdCBkID0gYXdhaXQgci5qc29uKCk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBwcm8gID0gUFJPU1tfc3NoUHJvXSB8fCBQUk9TLmR0YWM7CiAgICBjb25zdCBsaW5rID0gX3NzaEFwcD09PSducHYnID8gYnVpbGROcHZMaW5rKHVzZXIscGFzcyxwcm8pIDogYnVpbGREYXJrTGluayh1c2VyLHBhc3MscHJvKTsKICAgIGNvbnN0IGlzTnB2ID0gX3NzaEFwcD09PSducHYnOwogICAgY29uc3QgbHBDbHMgPSBpc05wdiA/ICcnIDogJyBkYXJrLWxwJzsKICAgIGNvbnN0IGNDbHMgID0gaXNOcHYgPyAnbnB2JyA6ICdkYXJrJzsKICAgIGNvbnN0IGFwcExhYmVsID0gaXNOcHYgPyAnTnB2dCcgOiAnRGFya1R1bm5lbCc7CgogICAgaWYgKHJlc0VsKSB7CiAgICAgIHJlc0VsLmNsYXNzTmFtZSA9ICdsaW5rLXJlc3VsdCBzaG93JzsKICAgICAgY29uc3Qgc2FmZUxpbmsgPSBsaW5rLnJlcGxhY2UoL1xcL2csJ1xcXFwnKS5yZXBsYWNlKC8nL2csIlxcJyIpOwogICAgICByZXNFbC5pbm5lckhUTUwgPQogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXJlc3VsdC1oZHInPiIgKwogICAgICAgICAgIjxzcGFuIGNsYXNzPSdpbXAtYmFkZ2UgIitjQ2xzKyInPiIrYXBwTGFiZWwrIjwvc3Bhbj4iICsKICAgICAgICAgICI8c3BhbiBzdHlsZT0nZm9udC1zaXplOi42NXJlbTtjb2xvcjp2YXIoLS1tdXRlZCknPiIrcHJvLm5hbWUrIiBceGI3IFBvcnQgIitfc3NoUG9ydCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOiMyMmM1NWU7bWFyZ2luLWxlZnQ6YXV0byc+XHUyNzA1ICIrdXNlcisiPC9zcGFuPiIgKwogICAgICAgICI8L2Rpdj4iICsKICAgICAgICAiPGRpdiBjbGFzcz0nbGluay1wcmV2aWV3IitscENscysiJz4iK2xpbmsrIjwvZGl2PiIgKwogICAgICAgICI8YnV0dG9uIGNsYXNzPSdjb3B5LWxpbmstYnRuICIrY0NscysiJyBpZD0nY29weS1zc2gtYnRuJyBvbmNsaWNrPVwiY29weVNTSExpbmsoKVwiPiIrCiAgICAgICAgICAiXHVkODNkXHVkY2NiIENvcHkgIithcHBMYWJlbCsiIExpbmsiKwogICAgICAgICI8L2J1dHRvbj4iOwogICAgICB3aW5kb3cuX2xhc3RTU0hMaW5rID0gbGluazsKICAgICAgd2luZG93Ll9sYXN0U1NIQXBwICA9IGNDbHM7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExhYmVsID0gYXBwTGFiZWw7CiAgICB9CgogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCDCtyDguKvguKHguJTguK3guLLguKLguLggJytkLmV4cCwnb2snKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlcicpLnZhbHVlPScnOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1wYXNzJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3NGMgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4p6VIOC4quC4o+C5ieC4suC4hyBVc2VyJzsgfQp9CmZ1bmN0aW9uIGNvcHlTU0hMaW5rKCkgewogIGNvbnN0IGxpbmsgPSB3aW5kb3cuX2xhc3RTU0hMaW5rfHwnJzsKICBjb25zdCBjQ2xzID0gd2luZG93Ll9sYXN0U1NIQXBwfHwnbnB2JzsKICBjb25zdCBsYWJlbCA9IHdpbmRvdy5fbGFzdFNTSExhYmVsfHwnTGluayc7CiAgbmF2aWdhdG9yLmNsaXBib2FyZC53cml0ZVRleHQobGluaykudGhlbihmdW5jdGlvbigpewogICAgY29uc3QgYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdjb3B5LXNzaC1idG4nKTsKICAgIGlmKGIpeyBiLnRleHRDb250ZW50PSdcdTI3MDUg4LiE4Lix4LiU4Lil4Lit4LiB4LmB4Lil4LmJ4LinISc7IHNldFRpbWVvdXQoZnVuY3Rpb24oKXtiLnRleHRDb250ZW50PSdcdWQ4M2RcdWRjY2IgQ29weSAnK2xhYmVsKycgTGluayc7fSwyMDAwKTsgfQogIH0pLmNhdGNoKGZ1bmN0aW9uKCl7IHByb21wdCgnQ29weSBsaW5rOicsbGluayk7IH0pOwp9CgovLyBTU0ggdXNlciB0YWJsZQpsZXQgX3NzaFRhYmxlVXNlcnMgPSBbXTsKYXN5bmMgZnVuY3Rpb24gbG9hZFNTSFRhYmxlSW5Gb3JtKCkgewogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvdXNlcnMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIF9zc2hUYWJsZVVzZXJzID0gZC51c2VycyB8fCBbXTsKICAgIHJlbmRlclNTSFRhYmxlKF9zc2hUYWJsZVVzZXJzKTsKICB9IGNhdGNoKGUpIHsKICAgIGNvbnN0IHRiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLXRib2R5Jyk7CiAgICBpZih0YikgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjojZWY0NDQ0O3BhZGRpbmc6MTZweCI+4LmA4LiK4Li34LmI4Lit4Lih4LiV4LmI4LitIFNTSCBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJPC90ZD48L3RyPic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclNTSFRhYmxlKHVzZXJzKSB7CiAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICBpZiAoIXRiKSByZXR1cm47CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsKICAgIHRiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6dmFyKC0tbXV0ZWQpO3BhZGRpbmc6MjBweCI+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvdGQ+PC90cj4nOwogICAgcmV0dXJuOwogIH0KICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiAgdGIuaW5uZXJIVE1MID0gdXNlcnMubWFwKGZ1bmN0aW9uKHUsaSl7CiAgICBjb25zdCBleHBpcmVkID0gdS5leHAgJiYgdS5leHAgPCBub3c7CiAgICBjb25zdCBhY3RpdmUgID0gdS5hY3RpdmUgIT09IGZhbHNlICYmICFleHBpcmVkOwogICAgY29uc3QgZExlZnQgICA9IHUuZXhwID8gTWF0aC5jZWlsKChuZXcgRGF0ZSh1LmV4cCktRGF0ZS5ub3coKSkvODY0MDAwMDApIDogbnVsbDsKICAgIGNvbnN0IGJhZGdlICAgPSBhY3RpdmUKICAgICAgPyAnPHNwYW4gY2xhc3M9ImJkZyBiZGctZyI+QUNUSVZFPC9zcGFuPicKICAgICAgOiAnPHNwYW4gY2xhc3M9ImJkZyBiZGctciI+RVhQSVJFRDwvc3Bhbj4nOwogICAgY29uc3QgZFRhZyA9IGRMZWZ0IT09bnVsbAogICAgICA/ICc8c3BhbiBjbGFzcz0iZGF5cy1iYWRnZSI+JysoZExlZnQ+MD9kTGVmdCsnZCc6J+C4q+C4oeC4lCcpKyc8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iZGF5cy1iYWRnZSI+XHUyMjFlPC9zcGFuPic7CiAgICByZXR1cm4gJzx0cj48dGQgc3R5bGU9ImNvbG9yOnZhcigtLW11dGVkKSI+JysoaSsxKSsnPC90ZD4nICsKICAgICAgJzx0ZD48Yj4nK3UudXNlcisnPC9iPjwvdGQ+JyArCiAgICAgICc8dGQgc3R5bGU9ImZvbnQtc2l6ZToxMXB4O2NvbG9yOicrKGV4cGlyZWQ/JyNlZjQ0NDQnOid2YXIoLS1tdXRlZCknKSsnIj4nKwogICAgICAgICh1LmV4cHx8J+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcpKyc8L3RkPicgKwogICAgICAnPHRkPicrYmFkZ2UrJzwvdGQ+JyArCiAgICAgICc8dGQ+PGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2dhcDo0cHg7YWxpZ24taXRlbXM6Y2VudGVyIj4nKwogICAgICAgICc8YnV0dG9uIGNsYXNzPSJidG4tdGJsIiB0aXRsZT0i4LiV4LmI4Lit4Lit4Liy4Lii4Li4IiBvbmNsaWNrPSJvcGVuU1NIUmVuZXdNb2RhbChcJycrdS51c2VyKydcJykiPvCflIQ8L2J1dHRvbj4nKwogICAgICAgICc8YnV0dG9uIGNsYXNzPSJidG4tdGJsIiB0aXRsZT0i4Lil4LiaIiBvbmNsaWNrPSJkZWxTU0hVc2VyKFwnJyt1LnVzZXIrJ1wnKSIgc3R5bGU9ImJvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwuMykiPvCfl5HvuI88L2J1dHRvbj4nKwogICAgICAgIGRUYWcrCiAgICAgICc8L2Rpdj48L3RkPjwvdHI+JzsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJTU0hVc2VycyhxKSB7CiAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMuZmlsdGVyKGZ1bmN0aW9uKHUpe3JldHVybiAodS51c2VyfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpO30pKTsKfQovLyBTU0ggUmVuZXcgTW9kYWwKbGV0IF9yZW5ld1NTSFVzZXIgPSAnJzsKZnVuY3Rpb24gb3BlblNTSFJlbmV3TW9kYWwodXNlcikgewogIF9yZW5ld1NTSFVzZXIgPSB1c2VyOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctdXNlcm5hbWUnKS50ZXh0Q29udGVudCA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJykudmFsdWUgPSAnMzAnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY2xvc2VTU0hSZW5ld01vZGFsKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX3JlbmV3U1NIVXNlciA9ICcnOwp9CmFzeW5jIGZ1bmN0aW9uIGRvU1NIUmVuZXcoKSB7CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoIWRheXN8fGRheXM8PTApIHJldHVybjsKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWJ0bicpOwogIGJ0bi5kaXNhYmxlZCA9IHRydWU7IGJ0bi50ZXh0Q29udGVudCA9ICfguIHguLPguKXguLHguIfguJXguYjguK3guK3guLLguKLguLguLi4nOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvZXh0ZW5kX3NzaCcsewogICAgICBtZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXI6X3JlbmV3U1NIVXNlcixkYXlzfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4LiV4LmI4Lit4Lit4Liy4Lii4Li4ICcrX3JlbmV3U1NIVXNlcisnICsnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGNsb3NlU1NIUmVuZXdNb2RhbCgpOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7CiAgfSBmaW5hbGx5IHsKICAgIGJ0bi5kaXNhYmxlZCA9IGZhbHNlOyBidG4udGV4dENvbnRlbnQgPSAn4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4reC4reC4suC4ouC4uCc7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIHJlbmV3U1NIVXNlcih1c2VyKSB7IG9wZW5TU0hSZW5ld01vZGFsKHVzZXIpOyB9CmFzeW5jIGZ1bmN0aW9uIGRlbFNTSFVzZXIodXNlcikgewogIGlmICghY29uZmlybSgn4Lil4LiaIFNTSCB1c2VyICInK3VzZXIrJyIg4LiW4Liy4Lin4LijPycpKSByZXR1cm47CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9kZWxldGVfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pCiAgICB9KS50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKTt9KTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKHIuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzA1IOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IGFsZXJ0KCdcdTI3NGMgJytlLm1lc3NhZ2UpOyB9Cn0KLy8g4pWQ4pWQ4pWQ4pWQIENSRUFURSBWTEVTUyDilZDilZDilZDilZAKZnVuY3Rpb24gZ2VuVVVJRCgpIHsKICByZXR1cm4gJ3h4eHh4eHh4LXh4eHgtNHh4eC15eHh4LXh4eHh4eHh4eHh4eCcucmVwbGFjZSgvW3h5XS9nLGM9PnsKICAgIGNvbnN0IHI9TWF0aC5yYW5kb20oKSoxNnwwOyByZXR1cm4gKGM9PT0neCc/cjoociYweDN8MHg4KSkudG9TdHJpbmcoMTYpOwogIH0pOwp9CmFzeW5jIGZ1bmN0aW9uIGNyZWF0ZVZMRVNTKGNhcnJpZXIpIHsKICBjb25zdCBlbWFpbEVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWVtYWlsJyk7CiAgY29uc3QgZGF5c0VsICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1kYXlzJyk7CiAgY29uc3QgaXBFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1pcCcpOwogIGNvbnN0IGdiRWwgICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZ2InKTsKICBjb25zdCBlbWFpbCAgID0gZW1haWxFbC52YWx1ZS50cmltKCk7CiAgY29uc3QgZGF5cyAgICA9IHBhcnNlSW50KGRheXNFbC52YWx1ZSl8fDMwOwogIGNvbnN0IGlwTGltaXQgPSBwYXJzZUludChpcEVsLnZhbHVlKXx8MjsKICBjb25zdCBnYiAgICAgID0gcGFyc2VJbnQoZ2JFbC52YWx1ZSl8fDA7CiAgaWYgKCFlbWFpbCkgcmV0dXJuIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggRW1haWwvVXNlcm5hbWUnLCdlcnInKTsKCiAgY29uc3QgcG9ydCA9IGNhcnJpZXI9PT0nYWlzJyA/IDgwODAgOiA4ODgwOwogIGNvbnN0IHNuaSAgPSBjYXJyaWVyPT09J2FpcycgPyAnY2otZWJiLnNwZWVkdGVzdC5uZXQnIDogJ3RydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXMnOwoKICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYnRuJyk7CiAgYnRuLmRpc2FibGVkPXRydWU7IGJ0bi5pbm5lckhUTUw9JzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4Liq4Lij4LmJ4Liy4LiHLi4uJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0JykuY2xhc3NMaXN0LnJlbW92ZSgnc2hvdycpOwoKICB0cnkgewogICAgaWYgKCFfeHVpQ29va2llKSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgLy8g4Lir4LiyIGluYm91bmQgaWQKICAgIGNvbnN0IGxpc3QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgY29uc3QgaWIgPSAobGlzdC5vYmp8fFtdKS5maW5kKHg9PngucG9ydD09PXBvcnQpOwogICAgaWYgKCFpYikgdGhyb3cgbmV3IEVycm9yKGDguYTguKHguYjguJ7guJogaW5ib3VuZCBwb3J0ICR7cG9ydH0g4oCUIOC4o+C4seC4mSBzZXR1cCDguIHguYjguK3guJlgKTsKCiAgICBjb25zdCB1aWQgPSBnZW5VVUlEKCk7CiAgICBjb25zdCBleHBNcyA9IGRheXMgPiAwID8gKERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwKSA6IDA7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CgogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9hZGRDbGllbnQnLCB7CiAgICAgIGlkOiBpYi5pZCwKICAgICAgc2V0dGluZ3M6IEpTT04uc3RyaW5naWZ5KHsgY2xpZW50czpbewogICAgICAgIGlkOnVpZCwgZmxvdzonJywgZW1haWwsIGxpbWl0SXA6aXBMaW1pdCwKICAgICAgICB0b3RhbEdCOnRvdGFsQnl0ZXMsIGV4cGlyeVRpbWU6ZXhwTXMsIGVuYWJsZTp0cnVlLCB0Z0lkOicnLCBzdWJJZDonJywgY29tbWVudDonJywgcmVzZXQ6MAogICAgICB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnIHx8ICfguKrguKPguYnguLLguIfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKCiAgICBjb25zdCBsaW5rTmFtZSA9IGNhcnJpZXI9PT0nYWlzJyA/ICdBSVMt4LiB4Lix4LiZ4Lij4Lix4LmI4LinLScrZW1haWwgOiAnVFJVRS1WRE8tJytlbWFpbDsKICAgIGNvbnN0IGxpbmsgPSBjYXJyaWVyPT09J2FpcycgPyBgdmxlc3M6Ly8ke3VpZH1AJHtIT1NUfToke3BvcnR9P3R5cGU9d3Mmc2VjdXJpdHk9bm9uZSZwYXRoPSUyRnZsZXNzJmhvc3Q9JHtzbml9IyR7ZW5jb2RlVVJJQ29tcG9uZW50KGxpbmtOYW1lKX1gIDogYHZsZXNzOi8vJHt1aWR9QCR7c25pfToke3BvcnR9P3R5cGU9d3Mmc2VjdXJpdHk9bm9uZSZwYXRoPSUyRnZsZXNzJmhvc3Q9JHtIT1NUfSMke2VuY29kZVVSSUNvbXBvbmVudChsaW5rTmFtZSl9YDsKCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1lbWFpbCcpLnRleHRDb250ZW50ID0gZW1haWw7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy11dWlkJykudGV4dENvbnRlbnQgPSB1aWQ7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1leHAnKS50ZXh0Q29udGVudCA9IGV4cE1zID4gMCA/IGZtdERhdGUoZXhwTXMpIDogJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnci0nK2NhcnJpZXIrJy1saW5rJykudGV4dENvbnRlbnQgPSBsaW5rOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5hZGQoJ3Nob3cnKTsKICAgIC8vIEdlbmVyYXRlIFFSIGNvZGUKICAgIGNvbnN0IHFyRGl2ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXFyJyk7CiAgICBpZiAocXJEaXYpIHsKICAgICAgcXJEaXYuaW5uZXJIVE1MID0gJyc7CiAgICAgIHRyeSB7CiAgICAgICAgbmV3IFFSQ29kZShxckRpdiwgeyB0ZXh0OiBsaW5rLCB3aWR0aDogMTgwLCBoZWlnaHQ6IDE4MCwgY29ycmVjdExldmVsOiBRUkNvZGUuQ29ycmVjdExldmVsLk0gfSk7CiAgICAgIH0gY2F0Y2gocXJFcnIpIHsgcXJEaXYuaW5uZXJIVE1MID0gJyc7IH0KICAgIH0KICAgIHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinIUg4Liq4Lij4LmJ4Liy4LiHIFZMRVNTIEFjY291bnQg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGVtYWlsRWwudmFsdWU9Jyc7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydChjYXJyaWVyKyctYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IGJ0bi5kaXNhYmxlZD1mYWxzZTsgYnRuLmlubmVySFRNTD0n4pqhIOC4quC4o+C5ieC4suC4hyAnKyhjYXJyaWVyPT09J2Fpcyc/J0FJUyc6J1RSVUUnKSsnIEFjY291bnQnOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBNQU5BR0UgVVNFUlMg4pWQ4pWQ4pWQ4pWQCmxldCBfYWxsVXNlcnMgPSBbXSwgX2N1clVzZXIgPSBudWxsOwphc3luYyBmdW5jdGlvbiBsb2FkVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBfeHVpQ29va2llID0gZmFsc2U7CiAgICBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgY29uc3QgZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0Jyk7CiAgICBpZiAoIWQuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKGQubXNnIHx8ICfguYLguKvguKXguJQgaW5ib3VuZHMg4LmE4Lih4LmI4LmE4LiU4LmJJyk7CiAgICBfYWxsVXNlcnMgPSBbXTsKICAgIChkLm9ianx8W10pLmZvckVhY2goaWIgPT4gewogICAgICBjb25zdCBzZXR0aW5ncyA9IHR5cGVvZiBpYi5zZXR0aW5ncz09PSdzdHJpbmcnID8gSlNPTi5wYXJzZShpYi5zZXR0aW5ncykgOiBpYi5zZXR0aW5nczsKICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgIGNvbnN0IGVtYWlsID0gYy5lbWFpbHx8Yy5pZDsKICAgICAgICBjb25zdCBjcyA9IChpYi5jbGllbnRTdGF0c3x8W10pLmZpbmQoeD0+eC5lbWFpbD09PWVtYWlsKXx8bnVsbDsKICAgICAgICBfYWxsVXNlcnMucHVzaCh7CiAgICAgICAgICBpYklkOiBpYi5pZCwgcG9ydDogaWIucG9ydCwgcHJvdG86IGliLnByb3RvY29sLAogICAgICAgICAgZW1haWwsIHV1aWQ6IGMuaWQsCiAgICAgICAgICBleHA6IGMuZXhwaXJ5VGltZXx8MCwgdG90YWw6IGMudG90YWxHQnx8MCwKICAgICAgICAgIHVwOiBjcyA/IGNzLnVwIDogMCwgZG93bjogY3MgPyBjcy5kb3duIDogMCwgYWxsVGltZTogY3MgPyAoY3MuYWxsVGltZXx8MCkgOiAwLCBsaW1pdElwOiBjLmxpbWl0SXB8fDAKICAgICAgICB9KTsKICAgICAgfSk7CiAgICB9KTsKICAgIHJlbmRlclVzZXJzKF9hbGxVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gJzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyVXNlcnModXNlcnMpIHsKICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfk608L2Rpdj48cD7guYTguKHguYjguJ7guJrguKLguLnguKrguYDguIvguK3guKPguYw8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgY29uc3Qgbm93ID0gRGF0ZS5ub3coKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHUgPT4gewogICAgY29uc3QgZGwgPSBkYXlzTGVmdCh1LmV4cCk7CiAgICBsZXQgYmFkZ2UsIGNsczsKICAgIGlmICghdS5leHAgfHwgdS5leHA9PT0wKSB7IGJhZGdlPSfinJMg4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsgY2xzPSdvayc7IH0KICAgIGVsc2UgaWYgKGRsIDwgMCkgICAgICAgICB7IGJhZGdlPSfguKvguKHguJTguK3guLLguKLguLgnOyBjbHM9J2V4cCc7IH0KICAgIGVsc2UgaWYgKGRsIDw9IDMpICAgICAgICB7IGJhZGdlPSfimqAgJytkbCsnZCc7IGNscz0nc29vbic7IH0KICAgIGVsc2UgICAgICAgICAgICAgICAgICAgICB7IGJhZGdlPSfinJMgJytkbCsnZCc7IGNscz0nb2snOyB9CiAgICBjb25zdCBhdkNscyA9IGRsIDwgMCA/ICdhdi14JyA6ICdhdi1nJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIG9uY2xpY2s9Im9wZW5Vc2VyKCR7SlNPTi5zdHJpbmdpZnkodSkucmVwbGFjZSgvIi9nLCcmcXVvdDsnKX0pIj4KICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YXZDbHN9Ij4keyh1LmVtYWlsfHwnPycpWzBdLnRvVXBwZXJDYXNlKCl9PC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS5lbWFpbH08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+UG9ydCAke3UucG9ydH0gwrcgJHtmbXRCeXRlcygodS51cHx8MCkrKHUuZG93bnx8MCkrKHUuYWxsVGltZXx8MCkpfSDguYPguIrguYk8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJhYmRnICR7Y2xzfSI+JHtiYWRnZX08L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclVzZXJzKHEpIHsKICByZW5kZXJVc2VycyhfYWxsVXNlcnMuZmlsdGVyKHU9Pih1LmVtYWlsfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBNT0RBTCBVU0VSIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBvcGVuVXNlcih1KSB7CiAgaWYgKHR5cGVvZiB1ID09PSAnc3RyaW5nJykgdSA9IEpTT04ucGFyc2UodSk7CiAgX2N1clVzZXIgPSB1OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdCcpLnRleHRDb250ZW50ID0gJ+Kame+4jyAnK3UuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1JykudGV4dENvbnRlbnQgPSB1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcCcpLnRleHRDb250ZW50ID0gdS5wb3J0OwogIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogIGNvbnN0IGV4cFR4dCA9ICF1LmV4cHx8dS5leHA9PT0wID8gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcgOiBmbXREYXRlKHUuZXhwKTsKICBjb25zdCBkZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZScpOwogIGRlLnRleHRDb250ZW50ID0gZXhwVHh0OwogIGRlLmNsYXNzTmFtZSA9ICdkdicgKyAoZGwgIT09IG51bGwgJiYgZGwgPCAwID8gJyByZWQnIDogJyBncmVlbicpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZCcpLnRleHRDb250ZW50ID0gdS50b3RhbCA+IDAgPyBmbXRCeXRlcyh1LnRvdGFsKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdHInKS50ZXh0Q29udGVudCA9IGZtdEJ5dGVzKCh1LnVwfHwwKSsodS5kb3dufHwwKSsodS5hbGxUaW1lfHwwKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RpJykudGV4dENvbnRlbnQgPSB1LmxpbWl0SXAgfHwgJ+KInic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1dScpLnRleHRDb250ZW50ID0gdS51dWlkOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbSgpewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfbVN1YnMuZm9yRWFjaChrID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKfQoKLy8g4pSA4pSAIE1PREFMIDYtQUNUSU9OIFNZU1RFTSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAKY29uc3QgX21TdWJzID0gWydyZW5ldycsJ2V4dGVuZCcsJ2FkZGRhdGEnLCdzZXRkYXRhJywncmVzZXQnLCdkZWxldGUnXTsKZnVuY3Rpb24gbUFjdGlvbihrZXkpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScra2V5KTsKICBjb25zdCBpc09wZW4gPSBlbC5jbGFzc0xpc3QuY29udGFpbnMoJ29wZW4nKTsKICBfbVN1YnMuZm9yRWFjaChrID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtc3ViLScraykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuYWJ0bicpLmZvckVhY2goYiA9PiBiLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBpZiAoIWlzT3BlbikgewogICAgZWwuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwogICAgaWYgKGtleT09PSdkZWxldGUnICYmIF9jdXJVc2VyKSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1kZWwtbmFtZScpLnRleHRDb250ZW50ID0gX2N1clVzZXIuZW1haWw7CiAgICBzZXRUaW1lb3V0KCgpPT5lbC5zY3JvbGxJbnRvVmlldyh7YmVoYXZpb3I6J3Ntb290aCcsYmxvY2s6J25lYXJlc3QnfSksMTAwKTsKICB9Cn0KZnVuY3Rpb24gX21CdG5Mb2FkKGlkLCBsb2FkaW5nLCBvcmlnVGV4dCkgewogIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFiKSByZXR1cm47CiAgYi5kaXNhYmxlZCA9IGxvYWRpbmc7CiAgaWYgKGxvYWRpbmcpIHsgYi5kYXRhc2V0Lm9yaWcgPSBiLnRleHRDb250ZW50OyBiLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPiDguIHguLPguKXguLHguIfguJTguLPguYDguJnguLTguJnguIHguLLguKMuLi4nOyB9CiAgZWxzZSB7IGIudGV4dENvbnRlbnQgPSBiLmRhdGFzZXQub3JpZyB8fCBvcmlnVGV4dCB8fCAn4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijJzsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1JlbmV3VXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXJlbmV3LWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tcmVuZXctYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGV4cE1zID0gRGF0ZS5ub3coKSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4LmI4Lit4Lit4Liy4Lii4Li44Liq4Liz4LmA4Lij4LmH4LiIICcrZGF5cysnIOC4p+C4seC4mSAo4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJKScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0V4dGVuZFVzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1leHRlbmQtZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoZGF5cyA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iOC4s+C4meC4p+C4meC4p+C4seC4mScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGJhc2UgPSAoX2N1clVzZXIuZXhwICYmIF9jdXJVc2VyLmV4cCA+IERhdGUubm93KCkpID8gX2N1clVzZXIuZXhwIDogRGF0ZS5ub3coKTsKICAgIGNvbnN0IGV4cE1zID0gYmFzZSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihICcrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIggKOC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lCknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvQWRkRGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgYWRkR2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWFkZGRhdGEtZ2InKS52YWx1ZSl8fDA7CiAgaWYgKGFkZEdiIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBuZXdUb3RhbCA9IChfY3VyVXNlci50b3RhbHx8MCkgKyBhZGRHYioxMDczNzQxODI0OwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOm5ld1RvdGFsLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguYDguJ7guLTguYjguKEgRGF0YSArJythZGRHYisnIEdCIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWFkZGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvU2V0RGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZ2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXNldGRhdGEtZ2InKS52YWx1ZSk7CiAgaWYgKGlzTmFOKGdiKXx8Z2I8MCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYioxMDczNzQxODI0IDogMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjp0b3RhbEJ5dGVzLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguJXguLHguYnguIcgRGF0YSBMaW1pdCAnKyhnYj4wP2diKycgR0InOifguYTguKHguYjguIjguLPguIHguLHguJQnKSsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvUmVzZXRUcmFmZmljKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvJytfY3VyVXNlci5pYklkKycvcmVzZXRDbGllbnRUcmFmZmljLycrX2N1clVzZXIuZW1haWwsIHt9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyBsb2FkRGFzaGJvYXJkICYmIGxvYWREYXNoYm9hcmQoKTsgfSwgMTUwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZXNldC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9EZWxldGVVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL2RlbENsaWVudC8nK19jdXJVc2VyLnV1aWQsIHt9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4peC4muC4ouC4ueC4qiAnK19jdXJVc2VyLmVtYWlsKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDEyMDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIGZhbHNlKTsgfQp9CgovLyDilZDilZDilZDilZAgT05MSU5FIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkT25saW5lKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgX3h1aUNvb2tpZSA9IGZhbHNlOwogICAgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIC8vIOC5guC4q+C4peC4lCBpbmJvdW5kcyDguJbguYnguLLguKLguLHguIfguYTguKHguYjguKHguLUKICAgIGlmICghX2FsbFVzZXJzLmxlbmd0aCkgewogICAgICBjb25zdCBkID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICAgIGlmIChkICYmIGQuc3VjY2VzcykgewogICAgICAgIF9hbGxVc2VycyA9IFtdOwogICAgICAgIChkLm9ianx8W10pLmZvckVhY2goaWIgPT4gewogICAgICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgICAgICAoc2V0dGluZ3MuY2xpZW50c3x8W10pLmZvckVhY2goYyA9PiB7CiAgICAgICAgICAgIF9hbGxVc2Vycy5wdXNoKHsgaWJJZDppYi5pZCwgcG9ydDppYi5wb3J0LCBwcm90bzppYi5wcm90b2NvbCwKICAgICAgICAgICAgICBlbWFpbDpjLmVtYWlsfHxjLmlkLCB1dWlkOmMuaWQsIGV4cDpjLmV4cGlyeVRpbWV8fDAsCiAgICAgICAgICAgICAgdG90YWw6Yy50b3RhbEdCfHwwLCB1cDooaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT0oYy5lbWFpbHx8Yy5pZCkpPy51cHx8MCwgZG93bjooaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT0oYy5lbWFpbHx8Yy5pZCkpPy5kb3dufHwwLCBhbGxUaW1lOihpYi5jbGllbnRTdGF0c3x8W10pLmZpbmQoeD0+eC5lbWFpbD09PShjLmVtYWlsfHxjLmlkKSk/LmFsbFRpbWV8fDAsIGxpbWl0SXA6Yy5saW1pdElwfHwwIH0pOwogICAgICAgICAgfSk7CiAgICAgICAgfSk7CiAgICAgIH0KICAgIH0KICAgIGxldCBlbWFpbHMgPSBbXTsKICAgIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgICBjb25zdCBkMiA9IGF3YWl0IHh1aUdldCgiL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0IikuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKGQyICYmIGQyLnN1Y2Nlc3MpIHsKICAgICAgKGQyLm9ianx8W10pLmZvckVhY2goaWIgPT4gewogICAgICAgIChpYi5jbGllbnRTdGF0c3x8W10pLmZvckVhY2goY3MgPT4gewogICAgICAgICAgaWYgKGNzLmxhc3RPbmxpbmUgJiYgKG5vdyAtIGNzLmxhc3RPbmxpbmUpIDwgMzAwMDAwKSBlbWFpbHMucHVzaChjcy5lbWFpbCk7CiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfQogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1jb3VudCcpLnRleHRDb250ZW50ID0gZW1haWxzLmxlbmd0aDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtdGltZScpLnRleHRDb250ZW50ID0gbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgICBpZiAoIWVtYWlscy5sZW5ndGgpIHsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJvZSI+PGRpdiBjbGFzcz0iZWkiPvCfmLQ8L2Rpdj48cD7guYTguKHguYjguKHguLXguKLguLnguKrguK3guK3guJnguYTguKXguJnguYzguJXguK3guJnguJnguLXguYk8L3A+PC9kaXY+JzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3QgdU1hcCA9IHt9OwogICAgX2FsbFVzZXJzLmZvckVhY2godT0+eyB1TWFwW3UuZW1haWxdPXU7IH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ29ubGluZS1saXN0JykuaW5uZXJIVE1MID0gZW1haWxzLm1hcChlbWFpbD0+ewogICAgICBjb25zdCB1ID0gdU1hcFtlbWFpbF07CiAgICAgIGNvbnN0IGNzID0gKGQyJiZkMi5vYmp8fFtdKS5mbGF0TWFwKGliPT5pYi5jbGllbnRTdGF0c3x8W10pLmZpbmQoeD0+eC5lbWFpbD09PWVtYWlsKXx8bnVsbDsKICAgICAgY29uc3QgaWJPYmogPSAoZDImJmQyLm9ianx8W10pLmZpbmQoaWI9PihpYi5jbGllbnRTdGF0c3x8W10pLnNvbWUoeD0+eC5lbWFpbD09PWVtYWlsKSl8fG51bGw7CiAgICAgIGNvbnN0IHVzZWRHQiA9IGNzID8gKChjcy51cCtjcy5kb3duKyhjcy5hbGxUaW1lfHwwKSkvMTA3Mzc0MTgyNCkudG9GaXhlZCgyKSA6IChpYk9iaiA/ICgoaWJPYmoudXAraWJPYmouZG93bikvMTA3Mzc0MTgyNCkudG9GaXhlZCgyKSA6IDApOwogICAgICBjb25zdCB0b3RhbEdCID0gY3MgJiYgY3MudG90YWw+MCA/IChjcy50b3RhbC8xMDczNzQxODI0KS50b0ZpeGVkKDApIDogbnVsbDsKICAgICAgY29uc3QgcGN0ID0gKHUgJiYgdS50b3RhbD4wKSA/IE1hdGgubWluKE1hdGgucm91bmQoKHUudXArdS5kb3duKS91LnRvdGFsKjEwMCksMTAwKSA6IDA7CiAgICAgIGNvbnN0IGJhciA9IHBjdD44NT8iI2VmNDQ0NCI6cGN0PjY1PyIjZjk3MzE2IjoiIzIyYzU1ZSI7CiAgICAgIGNvbnN0IGV4cE1zID0gdSA/IHUuZXhwIDogMDsKICAgICAgY29uc3QgZXhwU3RyID0gKCFleHBNc3x8ZXhwTXM9PT0wKT8i4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUIjpuZXcgRGF0ZShleHBNcykudG9Mb2NhbGVEYXRlU3RyaW5nKCJ0aC1USCIse3llYXI6Im51bWVyaWMiLG1vbnRoOiJzaG9ydCIsZGF5OiJudW1lcmljIn0pOwogICAgICBjb25zdCBkTGVmdCA9ICghZXhwTXN8fGV4cE1zPT09MCk/bnVsbDpNYXRoLmNlaWwoKGV4cE1zLURhdGUubm93KCkpLzg2NDAwMDAwKTsKICAgICAgY29uc3QgZFRhZyA9IGRMZWZ0PT09bnVsbD8i4oieIjpkTGVmdD4wP2RMZWZ0KyJkIjoi4Lir4Lih4LiU4LmB4Lil4LmJ4LinIjsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSIgc3R5bGU9ImZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O3BhZGRpbmc6MTRweCAxNnB4Ij4KICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4Ij4KICAgICAgICAgIDxkaXYgc3R5bGU9InBvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjIwcHg7aGVpZ2h0OjIwcHg7ZmxleC1zaHJpbms6MCI+PHNwYW4gc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojMjJjNTVlO29wYWNpdHk6LjQ7YW5pbWF0aW9uOnBpbmcgMS4ycyBjdWJpYy1iZXppZXIoMCwwLC4yLDEpIGluZmluaXRlIj48L3NwYW4+PHNwYW4gc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO2luc2V0OjNweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOiMyMmM1NWUiPjwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+PGRpdiBjbGFzcz0idW4iPiR7ZW1haWx9PC9kaXY+PGRpdiBjbGFzcz0idW0iPiR7dT8iUG9ydCAiK3UucG9ydDoiVkxFU1MifSDCtyDguK3guK3guJnguYTguKXguJnguYzguK3guKLguLnguYg8L2Rpdj48L2Rpdj4KICAgICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIG9rIj5PTkxJTkU8L3NwYW4+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBzdHlsZT0iYmFja2dyb3VuZDpyZ2JhKDAsMCwwLC4wNSk7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxMnB4Ij4KICAgICAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjtmb250LXNpemU6MTFweDtjb2xvcjojNjY2O21hcmdpbi1ib3R0b206NXB4Ij4KICAgICAgICAgICAgPHNwYW4+8J+TiiAke3VzZWRHQn0gR0IgJHt0b3RhbEdCPyIvICIrdG90YWxHQisiIEdCIjoiLyDguYTguKHguYjguIjguLPguIHguLHguJQifTwvc3Bhbj4KICAgICAgICAgICAgPHNwYW4gc3R5bGU9ImNvbG9yOiR7YmFyfTtmb250LXdlaWdodDo2MDAiPiR7dG90YWxHQj9wY3QrIiUiOiIifTwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBzdHlsZT0iaGVpZ2h0OjZweDtiYWNrZ3JvdW5kOnJnYmEoMCwwLDAsLjEpO2JvcmRlci1yYWRpdXM6OTlweDtvdmVyZmxvdzpoaWRkZW4iPgogICAgICAgICAgICA8ZGl2IHN0eWxlPSJoZWlnaHQ6MTAwJTt3aWR0aDoke3RvdGFsR0I/cGN0OjEwMH0lO2JhY2tncm91bmQ6JHtiYXJ9O2JvcmRlci1yYWRpdXM6OTlweCI+PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjtmb250LXNpemU6MTFweDtjb2xvcjojODg4O21hcmdpbi10b3A6NnB4Ij4KICAgICAgICAgICAgPHNwYW4+8J+ThSAke2V4cFN0cn08L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xMik7Y29sb3I6IzE2YTM0YTtwYWRkaW5nOjFweCA4cHg7Ym9yZGVyLXJhZGl1czo5OXB4Ij4ke2RUYWd9PC9zcGFuPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBVU0VSUyAoYmFuIHRhYikg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCB1c2VycyA9IGQudXNlcnMgfHwgW107CiAgICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvcD48L2Rpdj4nOyByZXR1cm47IH0KICAgIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHU9PnsKICAgICAgY29uc3QgZXhwID0gdS5leHAgfHwgJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICAgIGNvbnN0IGFjdGl2ZSA9IHUuYWN0aXZlICE9PSBmYWxzZTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YWN0aXZlPydhdi1nJzonYXYteCd9Ij4ke3UudXNlclswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LnVzZXJ9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+4Lir4Lih4LiU4Lit4Liy4Lii4Li4OiAke2V4cH08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2FjdGl2ZT8nb2snOidleHAnfSI+JHthY3RpdmU/J0FjdGl2ZSc6J0V4cGlyZWQnfTwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsZXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZS50cmltKCk7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciID8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSl9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3J8fCfguKXguJrguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVXNlcnMoKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBDT1BZIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBjb3B5TGluayhpZCwgYnRuKSB7CiAgY29uc3QgdHh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHR4dCkudGhlbigoKT0+ewogICAgY29uc3Qgb3JpZyA9IGJ0bi50ZXh0Q29udGVudDsKICAgIGJ0bi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0ncmdiYSgzNCwxOTcsOTQsLjE1KSc7CiAgICBzZXRUaW1lb3V0KCgpPT57IGJ0bi50ZXh0Q29udGVudD1vcmlnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0nJzsgfSwgMjAwMCk7CiAgfSkuY2F0Y2goKCk9PnsgcHJvbXB0KCdDb3B5IGxpbms6JywgdHh0KTsgfSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBMT0dPVVQg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGRvTG9nb3V0KCkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIElOSVQg4pWQ4pWQ4pWQ4pWQCgovLyDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAKLy8gIFNQRUVEIFRFU1QKLy8g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCmxldCBfc3BlZWRSdW5uaW5nPWZhbHNlOwpmdW5jdGlvbiBzZXRHYXVnZShtYnBzLCBtYXhNYnBzPTIwMCkgewogIGNvbnN0IGVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdnYXVnZS1maWxsJyk7CiAgY29uc3QgdmFsRWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dhdWdlLXZhbCcpOwogIGNvbnN0IHVuaXRFbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2F1Z2UtdW5pdCcpOwogIGlmICghZWwpIHJldHVybjsKICBjb25zdCBwY3Q9TWF0aC5taW4obWJwcy9tYXhNYnBzLDEpOwogIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQ9KDIyMC0oMjIwKnBjdCkpLnRvRml4ZWQoMik7CiAgY29uc3Qgcj1NYXRoLnJvdW5kKHBjdDwwLjU/MDoyNTUqKHBjdC0wLjUpKjIpOwogIGNvbnN0IGc9TWF0aC5yb3VuZChwY3Q8MC41PzI1NToyNTUqKDEtKHBjdC0wLjUpKjIpKTsKICBlbC5zZXRBdHRyaWJ1dGUoJ3N0cm9rZScsYHJnYigke3J9LCR7Z30sNTApYCk7CiAgdmFsRWwudGV4dENvbnRlbnQ9bWJwcz49MT9tYnBzLnRvRml4ZWQoMSk6KG1icHMqMTAwMCkudG9GaXhlZCgwKTsKICB1bml0RWwudGV4dENvbnRlbnQ9bWJwcz49MT8nTWJwcyc6J0ticHMnOwp9CmZ1bmN0aW9uIHNldFByb2dyZXNzKHBjdCkgewogIGNvbnN0IGVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1wcm9nLWZpbGwnKTsKICBpZiAoZWwpIGVsLnN0eWxlLndpZHRoPU1hdGgubWluKHBjdCwxMDApKyclJzsKfQphc3luYyBmdW5jdGlvbiBtZWFzdXJlUGluZygpIHsKICBjb25zdCBwaW5ncz1bXTsKICBmb3IgKGxldCBpPTA7aTw1O2krKykgewogICAgY29uc3QgdDA9cGVyZm9ybWFuY2Uubm93KCk7CiAgICB0cnl7YXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJyx7bWV0aG9kOidIRUFEJyxjYWNoZTonbm8tc3RvcmUnfSk7fQogICAgY2F0Y2goZSl7dHJ5e2F3YWl0IGZldGNoKCcvJyx7bWV0aG9kOidIRUFEJyxjYWNoZTonbm8tc3RvcmUnfSk7fWNhdGNoKGVlKXt9fQogICAgcGluZ3MucHVzaChwZXJmb3JtYW5jZS5ub3coKS10MCk7CiAgICBhd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7CiAgfQogIHBpbmdzLnNvcnQoKGEsYik9PmEtYik7CiAgY29uc3QgcGluZz1waW5nc1tNYXRoLmZsb29yKHBpbmdzLmxlbmd0aC8yKV07CiAgY29uc3Qgaml0dGVyPXBpbmdzW3BpbmdzLmxlbmd0aC0xXS1waW5nc1swXTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluZy12YWwnKS50ZXh0Q29udGVudD1waW5nLnRvRml4ZWQoMCkrJyBtcyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ppdHRlci12YWwnKS50ZXh0Q29udGVudD1qaXR0ZXIudG9GaXhlZCgwKSsnIG1zJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9zcy12YWwnKS50ZXh0Q29udGVudD0nMCUnOwogIGNvbnN0IHBpbmdFbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluZy12YWwnKTsKICBwaW5nRWwuY2xhc3NOYW1lPSdzcGVlZC1waW5nLXZhbCcrKHBpbmc8ODA/Jyc6cGluZzwyMDA/JyB3YXJuJzonIGJhZCcpOwogIHJldHVybiB7cGluZyxqaXR0ZXJ9Owp9CmFzeW5jIGZ1bmN0aW9uIHN0YXJ0U3BlZWRUZXN0KHR5cGUpIHsKICBpZiAoX3NwZWVkUnVubmluZykgcmV0dXJuOwogIF9zcGVlZFJ1bm5pbmc9dHJ1ZTsKICBjb25zdCBidG5EbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWRsJyk7CiAgY29uc3QgYnRuVWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi11bCcpOwogIGJ0bkRsLmRpc2FibGVkPXRydWU7IGJ0blVsLmRpc2FibGVkPXRydWU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfguIHguLPguKXguLHguIfguKfguLHguJQgUGluZy4uLic7CiAgc2V0UHJvZ3Jlc3MoMCk7IHNldEdhdWdlKDApOwogIHRyeXsKICAgIGNvbnN0IGluZm89YXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYoaW5mbyYmaW5mby5ob3N0KSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndnBzLWlwJykudGV4dENvbnRlbnQ9aW5mby5ob3N0OwogICAgZWxzZSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndnBzLWlwJykudGV4dENvbnRlbnQ9bG9jYXRpb24uaG9zdG5hbWU7CiAgfWNhdGNoKGUpe30KICB0cnl7YXdhaXQgbWVhc3VyZVBpbmcoKTt9Y2F0Y2goZSl7fQogIHNldFByb2dyZXNzKDEwKTsKICBpZiAodHlwZT09PSdkb3dubG9hZCcpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIERvd25sb2FkLi4uJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkbC12YWwnKS50ZXh0Q29udGVudD0nLi4uJzsKICAgIGNvbnN0IG1icHM9YXdhaXQgcnVuRG93bmxvYWRUZXN0KChwLGN1cik9PnsKICAgICAgc2V0UHJvZ3Jlc3MoMTArcCowLjgpOyBzZXRHYXVnZShjdXIpOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtYmFyJykuc3R5bGUud2lkdGg9TWF0aC5taW4oY3VyLzIwMCoxMDAsMTAwKSsnJSc7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkbC12YWwnKS50ZXh0Q29udGVudD1tYnBzLnRvRml4ZWQoMSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtYmFyJykuc3R5bGUud2lkdGg9TWF0aC5taW4obWJwcy8yMDAqMTAwLDEwMCkrJyUnOwogICAgc2V0R2F1Z2UobWJwcyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtc3RhdHVzJykudGV4dENvbnRlbnQ9J+KchSBEb3dubG9hZDogJyttYnBzLnRvRml4ZWQoMSkrJyBNYnBzJzsKICB9IGVsc2UgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfguIHguLPguKXguLHguIfguJfguJTguKrguK3guJogVXBsb2FkLi4uJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC12YWwnKS50ZXh0Q29udGVudD0nLi4uJzsKICAgIGNvbnN0IG1icHM9YXdhaXQgcnVuVXBsb2FkVGVzdCgocCxjdXIpPT57CiAgICAgIHNldFByb2dyZXNzKDEwK3AqMC44KTsgc2V0R2F1Z2UoY3VyKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKGN1ci8yMDAqMTAwLDEwMCkrJyUnOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWwtdmFsJykudGV4dENvbnRlbnQ9bWJwcy50b0ZpeGVkKDEpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKG1icHMvMjAwKjEwMCwxMDApKyclJzsKICAgIHNldEdhdWdlKG1icHMpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfinIUgVXBsb2FkOiAnK21icHMudG9GaXhlZCgxKSsnIE1icHMnOwogIH0KICBzZXRQcm9ncmVzcygxMDApOwogIHNldFRpbWVvdXQoKCk9PnNldFByb2dyZXNzKDApLDE1MDApOwogIGJ0bkRsLmRpc2FibGVkPWZhbHNlOyBidG5VbC5kaXNhYmxlZD1mYWxzZTsKICBfc3BlZWRSdW5uaW5nPWZhbHNlOwp9CmFzeW5jIGZ1bmN0aW9uIHJ1bkRvd25sb2FkVGVzdChvblByb2dyZXNzKSB7CiAgY29uc3QgRFVSQVRJT05fTVM9ODAwMDsKICBsZXQgdG90YWxCeXRlcz0wOwogIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogIGxldCBkb25lPWZhbHNlOwogIHNldFRpbWVvdXQoKCk9Pntkb25lPXRydWU7fSxEVVJBVElPTl9NUyk7CiAgY29uc3QgQ0hVTks9MSoxMDI0KjEwMjQ7CiAgY29uc3QgcnVuPWFzeW5jKCk9PnsKICAgIHdoaWxlKCFkb25lKXsKICAgICAgdHJ5ewogICAgICAgIGNvbnN0IHVybD0naHR0cHM6Ly9zcGVlZC5jbG91ZGZsYXJlLmNvbS9fX2Rvd24/Ynl0ZXM9JytDSFVOSzsKICAgICAgICBjb25zdCByPWF3YWl0IGZldGNoKHVybCx7Y2FjaGU6J25vLXN0b3JlJ30pLmNhdGNoKGFzeW5jKCk9PmZldGNoKEFQSSsnL3N0YXR1cycse2NhY2hlOiduby1zdG9yZSd9KSk7CiAgICAgICAgY29uc3QgYnVmPWF3YWl0IHIuYXJyYXlCdWZmZXIoKTsKICAgICAgICBpZihkb25lKSBicmVhazsKICAgICAgICB0b3RhbEJ5dGVzKz1idWYuYnl0ZUxlbmd0aDsKICAgICAgICBjb25zdCBlbGFwc2VkPShwZXJmb3JtYW5jZS5ub3coKS10MCkvMTAwMDsKICAgICAgICBjb25zdCBtYnBzPSh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7CiAgICAgICAgb25Qcm9ncmVzcyhNYXRoLm1pbihlbGFwc2VkL0RVUkFUSU9OX01TKjEwMCw5OSksbWJwcyk7CiAgICAgIH1jYXRjaChlKXthd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7fQogICAgfQogIH07CiAgYXdhaXQgUHJvbWlzZS5hbGwoW3J1bigpLHJ1bigpLHJ1bigpLHJ1bigpXSk7CiAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgcmV0dXJuICh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7Cn0KYXN5bmMgZnVuY3Rpb24gcnVuVXBsb2FkVGVzdChvblByb2dyZXNzKSB7CiAgY29uc3QgRFVSQVRJT05fTVM9ODAwMDsKICBsZXQgdG90YWxCeXRlcz0wOwogIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogIGxldCBkb25lPWZhbHNlOwogIHNldFRpbWVvdXQoKCk9Pntkb25lPXRydWU7fSxEVVJBVElPTl9NUyk7CiAgY29uc3QgQ0hVTks9NTEyKjEwMjQ7CiAgY29uc3QgZGF0YT1uZXcgVWludDhBcnJheShDSFVOSyk7CiAgY3J5cHRvLmdldFJhbmRvbVZhbHVlcyhkYXRhKTsKICBjb25zdCBibG9iPW5ldyBCbG9iKFtkYXRhXSk7CiAgY29uc3QgcnVuPWFzeW5jKCk9PnsKICAgIHdoaWxlKCFkb25lKXsKICAgICAgdHJ5ewogICAgICAgIGF3YWl0IGZldGNoKCdodHRwczovL3NwZWVkLmNsb3VkZmxhcmUuY29tL19fdXAnLHttZXRob2Q6J1BPU1QnLGJvZHk6YmxvYn0pLmNhdGNoKCgpPT4KICAgICAgICAgIGZldGNoKEFQSSsnL3N0YXR1cycse21ldGhvZDonUE9TVCcsYm9keTpibG9iLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0nfX0pLmNhdGNoKCgpPT4oe29rOmZhbHNlfSkpCiAgICAgICAgKTsKICAgICAgICBpZihkb25lKSBicmVhazsKICAgICAgICB0b3RhbEJ5dGVzKz1DSFVOSzsKICAgICAgICBjb25zdCBlbGFwc2VkPShwZXJmb3JtYW5jZS5ub3coKS10MCkvMTAwMDsKICAgICAgICBjb25zdCBtYnBzPSh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7CiAgICAgICAgb25Qcm9ncmVzcyhNYXRoLm1pbihlbGFwc2VkL0RVUkFUSU9OX01TKjEwMCw5OSksbWJwcyk7CiAgICAgIH1jYXRjaChlKXthd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7fQogICAgfQogIH07CiAgYXdhaXQgUHJvbWlzZS5hbGwoW3J1bigpLHJ1bigpLHJ1bigpXSk7CiAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgcmV0dXJuICh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7Cn0KCi8vIHN3KCkg4LmA4Lie4Li04LmI4LihIHNwZWVkIHRhYiBzdXBwb3J0Cgpsb2FkRGFzaCgpOwpsb2FkU2VydmljZXMoKTsKc2V0SW50ZXJ2YWwobG9hZERhc2gsIDMwMDAwKTsKPC9zY3JpcHQ+Cgo8IS0tIFNTSCBSRU5FVyBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJzc2gtcmVuZXctbW9kYWwiIG9uY2xpY2s9ImlmKGV2ZW50LnRhcmdldD09PXRoaXMpY2xvc2VTU0hSZW5ld01vZGFsKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IFNTSCBVc2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY2xvc2VTU0hSZW5ld01vZGFsKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJkZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfkaQgVXNlcm5hbWU8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0ic3NoLXJlbmV3LXVzZXJuYW1lIj4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmciIHN0eWxlPSJtYXJnaW4tdG9wOjE0cHgiPgogICAgICA8ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguJXguYjguK3guK3guLLguKLguLg8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIiBwbGFjZWhvbGRlcj0iMzAiPgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ic3NoLXJlbmV3LWJ0biIgb25jbGljaz0iZG9TU0hSZW5ldygpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgPC9kaXY+CjwvZGl2PgoKCjxzY3JpcHQ+Ci8vIEZpcmVmbGllcyB4NjAg4oCTIGluc2lkZSBjYXJkcyAoYWJzb2x1dGUsIOC5hOC4oeC5iOC5g+C4iuC5iCBmaXhlZCkKPC9ib2R5Pgo8L2h0bWw+Cg==
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
