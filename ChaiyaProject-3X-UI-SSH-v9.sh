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

# ── PORT MAP (v9 — HAProxy + Xray front, UDP DNAT) ───────────
# 80     HAProxy (tcp) → Nginx:8880 → [A] npxproxy:8080 → Dropbear:143 (SSH-WS)
#                                    → [B] Xray:18080 (VLESS-WS)
# 443    HAProxy (tcp) → Xray:24443 (TLS terminate)
#                         → VLESS ถูกต้อง  → ใช้งานได้ (VLESS TCP TLS)
#                         → ไม่ใช่ VLESS    → fallback → SSH:22 (SSH TLS)
# 109    Dropbear SSH port 2
# 143    Dropbear SSH port 1 (ปลายทางของ npxproxy)
# 2503   nginx SSL proxy → 3x-ui panel (user เข้า URL นี้)
# 8443   Chaiya Dashboard HTTPS (ย้ายออกจาก 443 เพราะ 443 ให้ HAProxy/Xray ใช้แล้ว)
# 8080   npxproxy (SSH-WS backend, 127.0.0.1 เท่านั้น — อยู่หลัง Nginx:8880)
# 8880   Nginx L7 router (127.0.0.1 เท่านั้น — อยู่หลัง HAProxy:80)
# 18080  Xray VLESS-WS inbound (127.0.0.1 เท่านั้น — อยู่หลัง Nginx:8880)
# 24443  Xray VLESS+TCP+TLS inbound (127.0.0.1 เท่านั้น — อยู่หลัง HAProxy:443, fallback→22)
# 54321  3x-ui internal (ไม่ expose ออกนอก)
# 7300   badvpn-udpgw (127.0.0.1 เท่านั้น)
# 6789   chaiya-sshws-api (127.0.0.1 เท่านั้น)
# ── UDP / NAT ─────────────────────────────────────────────────
# 5667   ZiVPN UDP server
# 36712  UDP Custom (ผู้ใช้ต้องติดตั้ง binary เองตามคำแนะนำท้ายสคริปต์)
# 6000-6499, 6501-19999/udp → DNAT → :5667  (ZiVPN)
# 1-65535/udp (catch-all)   → DNAT → :36712 (UDP Custom)

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

# ── v9 architecture ports ────────────────────────────────────
DASHBOARD_PORT=8443     # Chaiya Dashboard HTTPS (ย้ายออกจาก 443)
NPXPROXY_PORT=8080      # SSH-WS backend (หลัง Nginx L7)
NGINX_L7_PORT=8880      # Nginx L7 router (หลัง HAProxy:80)
XRAY_VLESS_WS_PORT=18080   # VLESS-WS backend (หลัง Nginx L7)
XRAY_VLESS_TLS_PORT=24443  # VLESS+TCP+TLS (หลัง HAProxy:443, fallback→22)
ZIVPN_PORT=5667          # ZiVPN UDP
UDPCUSTOM_PORT=36712     # UDP Custom

# ── ปิด needrestart interactive prompt (Ubuntu 22.04+ ติดตั้งมาให้ในเครื่อง
#    จะ pop-up ถามว่าจะ restart service ไหนหลัง apt install ทุกครั้ง ทำให้
#    สคริปต์ที่รันแบบ bash <(curl ...) ไม่มี TTY ค้างแบบเงียบๆ) ──
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
if [[ -d /etc/needrestart ]] || command -v needrestart &>/dev/null; then
  mkdir -p /etc/needrestart/conf.d
  cat > /etc/needrestart/conf.d/99-chaiya-noninteractive.conf << 'NRCONF'
$nrconf{restart} = 'a';
$nrconf{ui} = 'NeedRestart::UI::stdio';
NRCONF
fi

# ── ป้องกัน apt lock ค้าง (VPS ใหม่มักมี unattended-upgrades/apt-daily/
#    cloud-init ทำงานอัตโนมัติตอนบูตเครื่อง ทำให้ apt-get ทุกคำสั่งค้างรอ lock นานหลายนาที) ──

# บน VPS ที่เพิ่งสร้างใหม่ cloud-init มักถือ apt lock อยู่ระหว่างตั้งค่าระบบรอบแรก
# รอให้มันทำงานเสร็จตามปกติก่อน (ไม่บังคับฆ่า เพราะเป็น process ที่ตั้งค่าระบบจริง)
# timeout 180s กันเคสที่ cloud-init ค้างจริงๆ ไม่ให้บล็อกสคริปต์ทั้งหมด
if command -v cloud-init &>/dev/null; then
  info "รอ cloud-init ตั้งค่าระบบรอบแรกให้เสร็จก่อน (สูงสุด 180s)..."
  timeout 180 cloud-init status --wait &>/dev/null || true
fi

disable_unattended_upgrades() {
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl disable unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily-upgrade.service 2>/dev/null || true
}

_wait_apt() {
  local _tries=0
  disable_unattended_upgrades
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock &>/dev/null; do
    _tries=$((_tries+1))
    if [[ $_tries -eq 12 ]]; then
      # รอมา 60s แล้วยังไม่ว่าง — เช็คว่ายังเป็น cloud-init อยู่ไหมก่อนจะบังคับฆ่า
      if pgrep -f cloud-init &>/dev/null; then
        warn "cloud-init ยังทำงานอยู่ — รอต่อ (ไม่ฆ่าเพื่อกันระบบตั้งค่าไม่ครบ)"
      else
        warn "apt lock ค้างนาน — กำลังบังคับปิด apt/dpkg ที่ค้างอยู่..."
        disable_unattended_upgrades
        pkill -9 -f "apt.systemd.daily" 2>/dev/null || true
        pkill -9 -x apt-get 2>/dev/null || true
        pkill -9 -x apt 2>/dev/null || true
        pkill -9 -x dpkg 2>/dev/null || true
        sleep 2
        rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
              /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
        dpkg --configure -a 2>/dev/null || true
      fi
    fi
    if [[ $_tries -ge 30 ]]; then
      warn "apt lock ยังไม่ว่างหลังรอ 150s — ข้ามและลองติดตั้งต่อ (อาจมี error บางจุด)"
      break
    fi
    info "รอ apt lock... ($_tries/30)"
    sleep 5
  done
}

# ── INSTALL DEPS ─────────────────────────────────────────────
info "อัปเดต packages..."
_wait_apt
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
  _wait_apt
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
info "ติดตั้ง Ookla speedtest (native binary)..."
# หมายเหตุ: pip speedtest-cli ใช้ API เก่าของ Ookla ที่ถูกบล็อก (403 Forbidden) ถาวรแล้ว
# ต้องใช้ Ookla native CLI เท่านั้น ติดตั้งเสมอไม่ขึ้นกับว่า speedtest-cli มีอยู่หรือไม่
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
    mkdir -p /tmp/speedtest-extract && \
    tar -xzf /tmp/speedtest.tgz -C /tmp/speedtest-extract speedtest 2>/dev/null && \
    cp /tmp/speedtest-extract/speedtest /usr/local/bin/speedtest-ookla && \
    chmod +x /usr/local/bin/speedtest-ookla && \
    rm -rf /tmp/speedtest.tgz /tmp/speedtest-extract && \
    /usr/local/bin/speedtest-ookla --format=json --accept-license --accept-gdpr >/dev/null 2>&1 && \
    ok "ookla speedtest พร้อม (/usr/local/bin/speedtest-ookla)" || warn "ookla speedtest ติดตั้งไม่สำเร็จ"
else
  warn "ไม่รู้จัก architecture ($_arch) — ข้ามการติดตั้ง ookla speedtest"
fi

# ตรวจสอบ speedtest พร้อมใช้งาน
if command -v /usr/local/bin/speedtest-ookla &>/dev/null; then
  ok "speedtest พร้อม"
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

# ── Panel subdomain — ให้เข้า Dashboard ผ่าน https://panel.<โดเมน> ล้วนๆ
# ไม่ต้องพิมพ์พอร์ต :8443 (ซ่อนพอร์ตจริงไว้หลัง HAProxy ด้วย SNI routing บน 443 เดียวกับ VPN)
# ต้องเพิ่ม DNS A record ของ panel.<โดเมน> ชี้มา IP เดียวกับ $SERVER_IP เองก่อน ไม่งั้นจะ fallback ไปใช้ :8443 แบบเดิม
PANEL_DOMAIN="panel.${DOMAIN}"
echo -e "  ${YELLOW}หมายเหตุ:${NC} ต้องเพิ่ม DNS A record ของ ${CYAN}${PANEL_DOMAIN}${NC} ชี้มา IP: ${CYAN}$SERVER_IP${NC} ด้วย"
echo -e "  ${YELLOW}(ถ้ายังไม่ได้เพิ่ม Dashboard จะ fallback ไปใช้ https://${DOMAIN}:${DASHBOARD_PORT} แทน)${NC}"

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
for _svc in chaiya-npxproxy chaiya-sshws chaiya-ssh-api chaiya-badvpn haproxy nginx x-ui dropbear zivpn chaiya-udp-custom; do
  systemctl stop "$_svc"    2>/dev/null || true
  systemctl disable "$_svc" 2>/dev/null || true
done

# kill โดยตรงกรณี systemctl ไม่จับ
pkill -f ws-stunnel      2>/dev/null || true
pkill -f npxproxy        2>/dev/null || true
pkill -f badvpn-udpgw    2>/dev/null || true
pkill -f chaiya-ssh-api  2>/dev/null || true
pkill -f 'app.py'        2>/dev/null || true
pkill -9 -x nginx        2>/dev/null || true
pkill -9 -x haproxy      2>/dev/null || true
sleep 2

# ล้าง nginx config เก่า
rm -f /etc/nginx/sites-enabled/*
rm -f /etc/nginx/sites-available/chaiya
rm -f /etc/nginx/sites-available/chaiya-tmp
rm -f /etc/nginx/conf.d/chaiya.conf
rm -f /etc/nginx/conf.d/default.conf

# ล้าง systemd unit เก่า
rm -f /etc/systemd/system/chaiya-sshws.service
rm -f /etc/systemd/system/chaiya-npxproxy.service
rm -f /etc/systemd/system/chaiya-ssh-api.service
rm -f /etc/systemd/system/chaiya-badvpn.service
rm -f /etc/systemd/system/chaiya-udp-custom.service
rm -f /etc/systemd/system/zivpn.service
rm -f /etc/systemd/system/dropbear.service.d/override.conf
rm -f /etc/haproxy/haproxy.cfg
systemctl daemon-reload

# ล้าง chaiya config/data
rm -rf /etc/chaiya
rm -rf /opt/chaiya-panel
rm -rf /opt/chaiya-ssh-api
rm -f  /usr/local/bin/ws-stunnel
rm -f  /usr/local/bin/npxproxy
rm -f  /usr/local/bin/menu

# ล้าง iptables DNAT เก่าของ ChaiyaPanel (มี comment กำกับไว้ทุกกฎ)
if command -v iptables &>/dev/null; then
  while iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | grep -q "CHAIYA-UDP"; do
    _ln=$(iptables -t nat -L PREROUTING --line-numbers -n 2>/dev/null | grep "CHAIYA-UDP" | head -1 | awk '{print $1}')
    [[ -n "$_ln" ]] && iptables -t nat -D PREROUTING "$_ln" 2>/dev/null || break
  done
fi

# ล้าง x-ui inbounds เก่า (เก็บ binary ไว้ — ไม่ uninstall)
if [[ -f /etc/x-ui/x-ui.db ]]; then
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds;" 2>/dev/null || true
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings;" 2>/dev/null || true
fi

# ── FORCE FREE PORTS ─────────────────────────────────────────
# พอร์ตทุกตัวที่สคริปต์ใช้ — ถ้ามี process อื่นจับอยู่ให้ kill ทันที
_REQUIRED_PORTS=(80 109 143 443 2503 7300 8080 8443 8880 18080 24443 54321 6789)  # ไม่รวม 22 — ห้าม kill SSH
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
echo "$PANEL_DOMAIN" > /etc/chaiya/panel-domain.conf
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

# แก้ dpkg ค้างจากรอบก่อนหน้า (ถ้ามี) ก่อนลองติดตั้งใหม่
dpkg --configure -a 2>/dev/null || true

# อัปเดต apt cache สั้นๆ อีกครั้งเฉพาะจุดนี้ กันเคส mirror ที่ dropbear อยู่ยังไม่ sync ตอน update รอบแรก
_wait_apt
timeout 30 apt-get update -qq 2>/dev/null || true

# ติดตั้ง dropbear — ต้องใส่ DEBIAN_FRONTEND=noninteractive เพราะรันผ่าน bash <(curl ...) ไม่มี TTY
# ถ้าไม่ใส่ postinst ของ dropbear (ถามว่าจะ start อัตโนมัติไหม) จะค้าง/fail แบบเงียบๆ
_DB_LOG=$(mktemp)
DEBIAN_FRONTEND=noninteractive timeout 90 apt-get install -y \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  dropbear > "$_DB_LOG" 2>&1
if [[ $? -ne 0 ]]; then
  warn "apt install dropbear ครั้งแรกล้มเหลว ลองอีกครั้ง..."
  dpkg --configure -a 2>/dev/null || true
  DEBIAN_FRONTEND=noninteractive timeout 90 apt-get install -y --fix-broken \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    dropbear >> "$_DB_LOG" 2>&1 || \
  DEBIAN_FRONTEND=noninteractive timeout 60 apt-get install -y dropbear-bin >> "$_DB_LOG" 2>&1 || true
fi

# หา binary (อาจอยู่ที่ /usr/sbin หรือ /usr/bin)
_DB_BIN=""
for _p in /usr/sbin/dropbear /usr/bin/dropbear; do
  [[ -x "$_p" ]] && _DB_BIN="$_p" && break
done

if [[ -z "$_DB_BIN" ]]; then
  warn "ไม่พบ dropbear binary — ข้ามขั้นตอนนี้"
  warn "รายละเอียด apt error (10 บรรทัดสุดท้าย):"
  tail -10 "$_DB_LOG" 2>/dev/null | sed 's/^/    /'
  warn "แก้เองได้ด้วย: apt-get update && apt-get install -y dropbear แล้วรัน systemctl status dropbear ดู error จริง"
  rm -f "$_DB_LOG"
else
  rm -f "$_DB_LOG"
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

# ── NPXPROXY (127.0.0.1:8080 → Dropbear:143) ────────────────
# เดิมชื่อ ws-stunnel ฟัง public port 80 ตรงๆ
# ตอนนี้ฟังเฉพาะ 127.0.0.1:8080 เป็น backend "SSH-WS" หลัง Nginx L7 (8880) → HAProxy (80)
info "ติดตั้ง npxproxy (SSH-WS backend)..."
cat > /usr/local/bin/npxproxy << 'WSPYEOF'
#!/usr/bin/python3
import socket, threading, select, sys, time

LISTENING_ADDR = '127.0.0.1'
LISTENING_PORT = 8080
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
    print(f'[npxproxy] Listening on {LISTENING_ADDR}:{LISTENING_PORT} → {DEFAULT_HOST}')
    srv = Server(LISTENING_ADDR, LISTENING_PORT)
    srv.start()
    try:
        while True: time.sleep(60)
    except KeyboardInterrupt:
        srv.close()

if __name__ == '__main__':
    main()
WSPYEOF
chmod +x /usr/local/bin/npxproxy

cat > /etc/systemd/system/chaiya-npxproxy.service << 'EOF'
[Unit]
Description=Chaiya npxproxy 127.0.0.1:8080 -> Dropbear:143 (SSH-WS backend)
After=network.target dropbear.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/npxproxy
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chaiya-npxproxy
systemctl restart chaiya-npxproxy 2>/dev/null || true
sleep 1
ok "npxproxy พร้อม (127.0.0.1:$NPXPROXY_PORT → Dropbear:$DROPBEAR_PORT1)"

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
    # แปลง arch ให้ตรงกับชื่อไฟล์ใน GitHub release (x86_64→amd64, aarch64→arm64)
    case "$(arch)" in
      x86_64)  _arch="amd64"  ;;
      aarch64) _arch="arm64"  ;;
      armv7l)  _arch="armv7"  ;;
      *)       _arch="$(arch)" ;;
    esac
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
export DOMAIN
export SSL_CERT_PATH="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
export SSL_KEY_PATH="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
export XRAY_VLESS_WS_PORT
export XRAY_VLESS_TLS_PORT
python3 << PYEOF
import sqlite3, uuid, json, os

DB = '/etc/x-ui/x-ui.db'
use_ipv6 = os.environ.get('USE_IPV6', '0') == '1'
# inbound หลังฉากเหล่านี้ต้องฟัง 127.0.0.1 เท่านั้น (VLESS-WS อยู่หลัง Nginx L7, VLESS-TLS อยู่หลัง HAProxy)
listen_addr = '127.0.0.1'
ws_port   = int(os.environ.get('XRAY_VLESS_WS_PORT', '18080'))
tls_port  = int(os.environ.get('XRAY_VLESS_TLS_PORT', '24443'))
cert_path = os.environ.get('SSL_CERT_PATH', '')
key_path  = os.environ.get('SSL_KEY_PATH', '')
have_cert = os.path.isfile(cert_path) and os.path.isfile(key_path)

try:
    con = sqlite3.connect(DB)
    existing = [r[0] for r in con.execute("SELECT port FROM inbounds").fetchall()]

    # ── [B] VLESS-WS (port :80 diagram) — หลัง Nginx L7 (8880) → HAProxy (80) ──
    if ws_port not in existing:
        uid_ws = str(uuid.uuid4())
        remark_ws = 'VLESS WS NONE TLS PORT 80'
        settings_ws = json.dumps({'clients': [{'id': uid_ws, 'flow': '', 'email': 'default@vless-ws', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}], 'decryption': 'none'})
        stream_ws   = json.dumps({'network': 'ws', 'security': 'none', 'wsSettings': {'path': '/vless', 'headers': {}}})
        sniffing_ws = json.dumps({'enabled': True, 'destOverride': ['http', 'tls']})
        con.execute(
            "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,?,1,0,?,?,?,?,?,?,?)",
            (remark_ws, listen_addr, ws_port, 'vless', settings_ws, stream_ws, 'inbound-vless-ws', sniffing_ws)
        )
        print(f'[OK] VLESS-WS (127.0.0.1:{ws_port}, path /vless) — uuid={uid_ws}')
    else:
        print(f'[OK] VLESS-WS port {ws_port} มีอยู่แล้ว')

    # หมายเหตุ: VLESS+TCP+TLS (port 443) จะถูกสร้างทีหลัง หลังขอ SSL cert สำเร็จ
    # (ดูขั้นตอน "XRAY VLESS+TLS INBOUND" ถัดจากส่วน SSL CERTIFICATE ด้านล่าง)
    if tls_port in existing:
        print(f'[OK] VLESS+TCP+TLS port {tls_port} มีอยู่แล้ว')

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
            _, ws,  _       = run_cmd("systemctl is-active chaiya-npxproxy")
            _, svc_haproxy, _ = run_cmd("systemctl is-active haproxy")
            _, svc_zivpn, _   = run_cmd("systemctl is-active zivpn")
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
                    'haproxy':  svc_haproxy.strip() == 'active',
                    'zivpn':    svc_zivpn.strip() == 'active',
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
                _sp_bin = '/usr/local/bin/speedtest-ookla'
                _sp_env = {**os.environ, 'HOME': '/root'}
                if not os.path.exists(_sp_bin):
                    respond(self, 200, {'ok': False, 'error': 'ookla speedtest not installed'})
                else:
                    r2 = subprocess.run([_sp_bin,'--format=json','--accept-license','--accept-gdpr'], capture_output=True, text=True, timeout=60, env=_sp_env)
                    if r2.returncode == 0 and r2.stdout.strip():
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
                        respond(self, 200, {'ok': False, 'error': (r2.stderr or 'speedtest failed').strip()[:200]})
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

# หยุด HAProxy/nginx ชั่วคราวเพื่อ free port 80 ให้ certbot standalone
# (npxproxy ฟังแค่ 127.0.0.1:8080 แล้ว ไม่ชนกับ port 80 อีกต่อไป)
# (Let's Encrypt ต้องการ port 80 จริงๆ — http-01-port อื่นไม่ work)
info "หยุด HAProxy/nginx ชั่วคราว (ปลดล็อก port 80)..."
systemctl stop haproxy 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
pkill -9 -x haproxy 2>/dev/null || true
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

# ── SSL CERTIFICATE สำหรับ panel subdomain (ให้เข้า Dashboard ผ่าน https:// ไม่มีพอร์ต) ──
# แยก cert ต่างหากจากโดเมนหลัก เพื่อไม่ให้ถ้า DNS ของ panel.<โดเมน> ยังไม่พร้อม ไปทำให้
# cert หลักที่ VLESS-TLS/SSH-TLS ต้องใช้พังไปด้วย (ล้มแค่ปลอดเฉพาะ dashboard เท่านั้น)
PANEL_SSL_CERT="/etc/letsencrypt/live/panel-${DOMAIN}/fullchain.pem"
PANEL_SSL_KEY="/etc/letsencrypt/live/panel-${DOMAIN}/privkey.pem"
USE_PANEL_SSL=0
if command -v certbot &>/dev/null; then
  info "ขอ SSL Certificate สำหรับ ${PANEL_DOMAIN} (สำหรับ Dashboard แบบไม่โชว์พอร์ต)..."
  timeout 90 certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email \
    --cert-name "panel-${DOMAIN}" \
    -d "$PANEL_DOMAIN" 2>&1 | tail -5 || true
  if [[ -f "$PANEL_SSL_CERT" ]]; then
    USE_PANEL_SSL=1
    ok "SSL สำหรับ ${PANEL_DOMAIN} พร้อม — Dashboard จะเข้าได้แบบไม่ต้องใส่พอร์ต"
  else
    warn "ขอ SSL สำหรับ ${PANEL_DOMAIN} ไม่สำเร็จ (เช็คว่าเพิ่ม DNS A record ชี้มา IP นี้แล้วหรือยัง)"
    warn "Dashboard จะ fallback ไปใช้ https://${DOMAIN}:${DASHBOARD_PORT} แทนไปก่อน"
  fi
fi
echo "$USE_PANEL_SSL" > /etc/chaiya/panel-ssl.conf

info "จะเปิด HAProxy/Nginx L7 กลับหลังตั้งค่าเสร็จ..."

[[ $USE_SSL -eq 1 ]] && ok "SSL Certificate พร้อม" || warn "ไม่มี SSL — ใช้ HTTP แทน"

# ── XRAY VLESS+TLS INBOUND (port 443 diagram, fallback→SSH:22) ──
if [[ $USE_SSL -eq 1 ]]; then
  info "สร้าง Xray VLESS+TCP+TLS inbound (fallback → SSH:22)..."
  systemctl stop x-ui 2>/dev/null || true
  sleep 1
  export SSL_CERT SSL_KEY XRAY_VLESS_TLS_PORT
  python3 << PYEOF
import sqlite3, uuid, json, os
DB = '/etc/x-ui/x-ui.db'
tls_port  = int(os.environ.get('XRAY_VLESS_TLS_PORT', '24443'))
cert_path = os.environ.get('SSL_CERT', '')
key_path  = os.environ.get('SSL_KEY', '')
try:
    con = sqlite3.connect(DB)
    existing = [r[0] for r in con.execute("SELECT port FROM inbounds").fetchall()]
    if tls_port in existing:
        print(f'[OK] VLESS+TCP+TLS port {tls_port} มีอยู่แล้ว')
    else:
        uid_tls = str(uuid.uuid4())
        settings_tls = json.dumps({
            'clients': [{'id': uid_tls, 'flow': '', 'email': 'default@vless-tls', 'limitIp': 2, 'totalGB': 0, 'expiryTime': 0, 'enable': True}],
            'decryption': 'none',
            'fallbacks': [{'dest': 22, 'xver': 1}]
        })
        stream_tls = json.dumps({
            'network': 'tcp', 'security': 'tls',
            'tlsSettings': {'certificates': [{'certificateFile': cert_path, 'keyFile': key_path}], 'minVersion': '1.2'}
        })
        sniffing_tls = json.dumps({'enabled': True, 'destOverride': ['http', 'tls']})
        con.execute(
            "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,?,1,0,'127.0.0.1',?,?,?,?,?,?)",
            ('VLESS TCP TLS PORT 443', tls_port, 'vless', settings_tls, stream_tls, 'inbound-vless-tls', sniffing_tls)
        )
        con.commit()
        print(f'[OK] VLESS+TCP+TLS (127.0.0.1:{tls_port}) fallback→SSH:22 — uuid={uid_tls}')
    con.close()
except Exception as e:
    print(f'[WARN] {e}')
PYEOF
  systemctl start x-ui 2>/dev/null || true
  sleep 2
  ok "Xray VLESS+TCP+TLS พร้อม"
else
  warn "ไม่มี SSL cert — ข้าม VLESS+TCP+TLS inbound (port 443 จะ fallback ไป SSH ทั้งหมดผ่าน HAProxy โดยตรง)"
fi

# ── NGINX INSTALL + CONFIG ────────────────────────────────────
info "ติดตั้ง Nginx..."

# หยุด haproxy และ kill ทุก process บน port 80/8880 ก่อนเด็ดขาด
systemctl stop haproxy 2>/dev/null || true
pkill -9 -x haproxy 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
sleep 2
fuser -k 80/tcp 2>/dev/null || true
fuser -k ${NGINX_L7_PORT}/tcp 2>/dev/null || true
sleep 1

# (ใช้ _wait_apt / disable_unattended_upgrades ที่ประกาศไว้ตอนต้นสคริปต์)

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

# เปิด port 8443 (Dashboard ย้ายมาจาก 443) / 2503 (3x-ui proxy)
ufw allow ${DASHBOARD_PORT}/tcp &>/dev/null || true
ufw allow 2503/tcp &>/dev/null || true

if [[ $USE_SSL -eq 1 ]]; then
cat > /etc/nginx/conf.d/chaiya.conf << EOF
# ── Dashboard (port ${DASHBOARD_PORT} HTTPS) — ย้ายออกจาก 443 เพราะ 443 ใช้กับ HAProxy/Xray ──
server {
    listen ${DASHBOARD_PORT} ssl http2;
    listen [::]:${DASHBOARD_PORT} ssl http2;
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

# ── Nginx L7 router (127.0.0.1:${NGINX_L7_PORT}) — หลัง HAProxy:80 ─────────
# [A] path /vless → Xray VLESS-WS (127.0.0.1:${XRAY_VLESS_WS_PORT})
# [B] default      → npxproxy SSH-WS (127.0.0.1:${NPXPROXY_PORT})
server {
    listen 127.0.0.1:${NGINX_L7_PORT};
    server_name _;
    location /vless {
        proxy_pass http://127.0.0.1:${XRAY_VLESS_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
    location / {
        proxy_pass http://127.0.0.1:${NPXPROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }
}
EOF
if [[ $USE_PANEL_SSL -eq 1 ]]; then
cat >> /etc/nginx/conf.d/chaiya.conf << EOF
# ── Dashboard เข้าทาง https://${PANEL_DOMAIN} (ไม่มีพอร์ต) — SNI เดียวกับ 8443 ──
# HAProxy:443 ส่ง TLS ต่อมาที่ 127.0.0.1:${DASHBOARD_PORT} ตรงนี้แบบ passthrough ตาม SNI
server {
    listen ${DASHBOARD_PORT} ssl http2;
    server_name ${PANEL_DOMAIN};
    ssl_certificate     ${PANEL_SSL_CERT};
    ssl_certificate_key ${PANEL_SSL_KEY};
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
        proxy_cookie_path ${XUI_BASE_PATH} /xui-api/;
        add_header Access-Control-Allow-Origin "\$http_origin" always;
        add_header Access-Control-Allow-Credentials "true" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type,Authorization,Cookie" always;
    }
}
EOF
fi
else
cat > /etc/nginx/conf.d/chaiya.conf << EOF
# ── Dashboard (port ${DASHBOARD_PORT} HTTP) ───────────────────────────────────
server {
    listen ${DASHBOARD_PORT};
    listen [::]:${DASHBOARD_PORT};
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

# ── Nginx L7 router (127.0.0.1:${NGINX_L7_PORT}) — หลัง HAProxy:80 ─────────
server {
    listen 127.0.0.1:${NGINX_L7_PORT};
    server_name _;
    location /vless {
        proxy_pass http://127.0.0.1:${XRAY_VLESS_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }
    location / {
        proxy_pass http://127.0.0.1:${NPXPROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
    }
}
EOF
fi

if nginx -t 2>/dev/null; then
  systemctl restart nginx \
    && ok "Nginx L7 พร้อม (Dashboard:${DASHBOARD_PORT} / 3x-ui proxy:2503 / L7 router:127.0.0.1:${NGINX_L7_PORT})" \
    || warn "Nginx ยังมีปัญหา — ตรวจ: journalctl -u nginx -n 20"
else
  warn "Nginx config มีปัญหา — ตรวจ: nginx -t"
fi

sleep 1
systemctl start chaiya-npxproxy 2>/dev/null || true

# ── HAPROXY (front port 80 + 443) ─────────────────────────────
info "ติดตั้ง HAProxy..."
_wait_apt
DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y -qq haproxy 2>/dev/null || true

if command -v haproxy &>/dev/null; then
  mkdir -p /etc/haproxy
  cat > /etc/haproxy/haproxy.cfg << HAPROXYEOF
global
    log /dev/log local0
    maxconn 20000
    daemon

defaults
    log     global
    mode    tcp
    timeout connect 10s
    timeout client  5m
    timeout server  5m

# ── Port 80: HAProxy → Nginx L7 (8880) → npxproxy(8080)/Xray-WS(18080) ──
frontend chaiya_http_80
    bind *:80
    mode tcp
    default_backend chaiya_nginx_l7

backend chaiya_nginx_l7
    mode tcp
    server nginx_l7 127.0.0.1:${NGINX_L7_PORT}

# ── Port 443: HAProxy → Xray (24443) TLS terminate + VLESS/SSH fallback ──
# SNI = panel.<โดเมน> → Dashboard (127.0.0.1:${DASHBOARD_PORT}) แบบ TLS passthrough (ไม่ต้องพิมพ์พอร์ต)
# SNI อื่น (รวมโดเมนหลัก) → Xray ตามเดิม ไม่กระทบ client VPN เดิม
frontend chaiya_tls_443
    bind *:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }
    use_backend chaiya_dashboard_tls if { req.ssl_sni -i ${PANEL_DOMAIN} }
    default_backend chaiya_xray_tls

backend chaiya_xray_tls
    mode tcp
    server xray_tls 127.0.0.1:${XRAY_VLESS_TLS_PORT}

backend chaiya_dashboard_tls
    mode tcp
    server dashboard_tls 127.0.0.1:${DASHBOARD_PORT}
HAPROXYEOF

  if [[ $USE_PANEL_SSL -ne 1 ]]; then
    # ยังไม่มี SSL ของ panel subdomain (DNS อาจยังไม่พร้อม) — ตัด SNI routing ออก กัน haproxy config พัง
    sed -i '/use_backend chaiya_dashboard_tls/d' /etc/haproxy/haproxy.cfg
  fi

  if haproxy -c -f /etc/haproxy/haproxy.cfg &>/dev/null; then
    systemctl enable haproxy 2>/dev/null || true
    systemctl restart haproxy \
      && ok "HAProxy พร้อม (80→Nginx L7, 443→Xray TLS$( [[ $USE_PANEL_SSL -eq 1 ]] && echo ', SNI panel→Dashboard' ))" \
      || warn "HAProxy start ไม่สำเร็จ — ตรวจ: journalctl -u haproxy -n 20"
  else
    warn "HAProxy config ผิดพลาด — ตรวจ: haproxy -c -f /etc/haproxy/haproxy.cfg"
  fi
else
  warn "ติดตั้ง HAProxy ไม่สำเร็จ — port 80/443 จะไม่มี service รับ traffic"
fi

# ── ZIVPN (UDP :5667) ──────────────────────────────────────────
info "ติดตั้ง ZiVPN (UDP)..."
_ZI_ARCH=$(uname -m)
case "$_ZI_ARCH" in
  x86_64)  _ZI_BIN="udp-zivpn-linux-amd64" ;;
  aarch64) _ZI_BIN="udp-zivpn-linux-arm64" ;;
  *)       _ZI_BIN="" ;;
esac
if [[ -n "$_ZI_BIN" ]]; then
  wget -q --timeout=20 -O /usr/local/bin/zivpn \
    "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/${_ZI_BIN}" 2>/dev/null && \
    chmod +x /usr/local/bin/zivpn || warn "ดาวน์โหลด zivpn binary ไม่สำเร็จ"
fi
if [[ -x /usr/local/bin/zivpn ]]; then
  mkdir -p /etc/zivpn
  cat > /etc/zivpn/config.json << ZIEOF
{
  "listen": ":${ZIVPN_PORT}",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": ["${XUI_PASS}"]
  }
}
ZIEOF
  [[ -f /etc/zivpn/zivpn.crt ]] || openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
    -subj "/CN=zivpn" -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt 2>/dev/null
  sysctl -w net.core.rmem_max=16777216 &>/dev/null || true
  sysctl -w net.core.wmem_max=16777216 &>/dev/null || true
  cat > /etc/systemd/system/zivpn.service << 'ZISVC'
[Unit]
Description=ZiVPN UDP Server
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
ZISVC
  systemctl daemon-reload
  systemctl enable zivpn 2>/dev/null || true
  systemctl restart zivpn \
    && ok "ZiVPN พร้อม (UDP :${ZIVPN_PORT}, password = 3x-ui password ที่ตั้งไว้)" \
    || warn "ZiVPN start ไม่สำเร็จ — ตรวจ: journalctl -u zivpn -n 20"
else
  warn "ไม่พบ zivpn binary — ข้ามการติดตั้ง ZiVPN"
fi

# ── UDP CUSTOM (UDP :36712) ────────────────────────────────────
# Binary: noobconner21/UDP-Custom-Script (เลือกใช้ตามที่ผู้ใช้ระบุ — เฉพาะ x86_64,
# ไม่มี build สำหรับ arm64 จาก repo นี้). ดาวน์โหลดเฉพาะตัว binary เท่านั้น —
# ไม่รันสคริปต์ install.sh ของ repo ต้นทาง เพราะมันจะ apt upgrade, เปลี่ยน timezone,
# ลงเมนูจัดการ user ของตัวเอง และ reboot เครื่องอัตโนมัติซึ่งจะพัง setup ส่วนอื่น
info "ติดตั้ง UDP Custom..."
if [[ ! -x /usr/local/bin/udp-custom ]]; then
  if [[ "$(uname -m)" == "x86_64" ]]; then
    wget -q --timeout=20 -O /usr/local/bin/udp-custom \
      "https://github.com/noobconner21/UDP-Custom-Script/raw/main/udp-custom-linux-amd64" 2>/dev/null && \
      chmod +x /usr/local/bin/udp-custom || warn "ดาวน์โหลด udp-custom binary ไม่สำเร็จ"
  else
    warn "สถาปัตยกรรม $(uname -m) — repo นี้มี binary เฉพาะ x86_64 เท่านั้น ข้ามการดาวน์โหลดอัตโนมัติ"
  fi
fi
mkdir -p /etc/udp-custom
[[ -f /etc/udp-custom/config.json ]] || cat > /etc/udp-custom/config.json << UDPCUSTOMEOF
{
  "listen": ":${UDPCUSTOM_PORT}",
  "stream_buffer": 209715200,
  "receive_buffer": 209715200,
  "auth": {
    "mode": "passwords",
    "config": ["${XUI_PASS}"]
  }
}
UDPCUSTOMEOF
cat > /etc/systemd/system/chaiya-udp-custom.service << UDPSVCEOF
[Unit]
Description=Chaiya UDP Custom (:${UDPCUSTOM_PORT})
After=network.target
[Service]
User=root
Type=simple
WorkingDirectory=/etc/udp-custom
ExecStart=/usr/local/bin/udp-custom server
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
UDPSVCEOF
systemctl daemon-reload
if [[ -x /usr/local/bin/udp-custom ]]; then
  systemctl enable --now chaiya-udp-custom 2>/dev/null \
    && ok "UDP Custom พร้อม (UDP :${UDPCUSTOM_PORT})" \
    || warn "UDP Custom start ไม่สำเร็จ — ตรวจ: journalctl -u chaiya-udp-custom -n 20"
else
  warn "ยังไม่พบ /usr/local/bin/udp-custom — สร้าง service ไว้ให้แล้ว แต่ยังไม่ start (ดูวิธีติดตั้งท้ายสคริปต์)"
fi

# ── UDP DNAT: ช่วงพอร์ตสาธารณะ → ZiVPN / UDP Custom ────────────
info "ตั้งค่า UDP DNAT..."
_WAN_IF=$(ip -4 route ls 2>/dev/null | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if command -v iptables &>/dev/null && [[ -n "$_WAN_IF" ]]; then
  iptables -t nat -A PREROUTING -i "$_WAN_IF" -p udp --dport 6000:6499   -j DNAT --to-destination :${ZIVPN_PORT} -m comment --comment CHAIYA-UDP-ZIVPN
  iptables -t nat -A PREROUTING -i "$_WAN_IF" -p udp --dport 6501:19999 -j DNAT --to-destination :${ZIVPN_PORT} -m comment --comment CHAIYA-UDP-ZIVPN
  iptables -t nat -A PREROUTING -i "$_WAN_IF" -p udp --dport 1:65535    -j DNAT --to-destination :${UDPCUSTOM_PORT} -m comment --comment CHAIYA-UDP-CUSTOM
  ok "DNAT UDP ตั้งค่าแล้ว (6000-6499,6501-19999→${ZIVPN_PORT} / catch-all→${UDPCUSTOM_PORT})"
  # เก็บกฎ iptables ไว้ให้รอดจาก reboot
  mkdir -p /etc/chaiya
  iptables-save > /etc/chaiya/iptables-udp-dnat.rules 2>/dev/null || true
  cat > /etc/systemd/system/chaiya-iptables-restore.service << IPTSVC
[Unit]
Description=Restore Chaiya UDP DNAT rules on boot
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/chaiya/iptables-udp-dnat.rules
RemainAfterExit=true
[Install]
WantedBy=multi-user.target
IPTSVC
  systemctl daemon-reload
  systemctl enable chaiya-iptables-restore 2>/dev/null || true
else
  warn "ไม่พบ iptables หรือ default interface — ข้าม UDP DNAT"
fi

# ── FIREWALL ─────────────────────────────────────────────────
info "ตั้งค่า Firewall..."

# ติดตั้ง ufw ถ้ายังไม่มี (บางครั้ง apt install รวมช่วงแรกพลาดแพคเกจนี้ไปเงียบๆ)
if ! command -v ufw &>/dev/null; then
  _wait_apt
  DEBIAN_FRONTEND=noninteractive timeout 90 apt-get install -y -qq ufw 2>/dev/null || true
fi

if ! command -v ufw &>/dev/null; then
  warn "ติดตั้ง ufw ไม่สำเร็จ — ข้าม Firewall (เปิด/ปิดพอร์ตเองด้วย iptables ถ้าจำเป็น)"
else
ufw --force reset 2>/dev/null || true
ufw default deny incoming 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true

# เปิดพอร์ตที่ต้องใช้งาน (public, TCP)
for port in 22 80 109 143 443 2503 ${DASHBOARD_PORT}; do
  ufw allow "$port"/tcp &>/dev/null
  ok "ufw allow $port/tcp"
done

# 7300/udp สำหรับ badvpn-udpgw (client tunnel ผ่าน SSH มา)
ufw allow 7300/udp &>/dev/null
ok "ufw allow 7300/udp"

# UDP: ZiVPN โดยตรง + ช่วงพอร์ตที่ DNAT มาหา ZiVPN/UDP Custom
ufw allow ${ZIVPN_PORT}/udp &>/dev/null
ufw allow ${UDPCUSTOM_PORT}/udp &>/dev/null
ufw allow 6000:19999/udp &>/dev/null
ok "ufw allow UDP (${ZIVPN_PORT}, ${UDPCUSTOM_PORT}, 6000:19999)"

# ปิดพอร์ต internal — ห้ามเข้าจากนอก (backend หลัง HAProxy/Nginx เท่านั้น)
for port in 6789 54321 8080 8880 18080 24443 8888; do
  ufw deny "$port"/tcp &>/dev/null
done

ufw --force enable &>/dev/null
fi

# ยืนยันว่าพอร์ตสำคัญเปิดอยู่จริง
info "ตรวจสอบพอร์ต..."
for port in 22 80 109 143 443 2503 ${DASHBOARD_PORT}; do
  if ss -tlnp 2>/dev/null | grep -q ":${port} " || { command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "^${port}"; }; then
    ok "port $port พร้อม"
  else
    warn "port $port ยังไม่มี service ฟัง (อาจปกติถ้า service ยังไม่ start)"
  fi
done
ok "Firewall พร้อม"

# ── CONFIG.JS ────────────────────────────────────────────────
if [[ $USE_PANEL_SSL -eq 1 ]]; then
  _PANEL_URL="https://${PANEL_DOMAIN}"
elif [[ $USE_SSL -eq 1 ]]; then
  _PANEL_URL="https://${DOMAIN}:${DASHBOARD_PORT}"
else
  _PANEL_URL="http://${DOMAIN}:${DASHBOARD_PORT}"
fi
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
echo 'PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQogIC5oZHJ7YmFja2dyb3VuZDpyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA4MCUgNjAlIGF0IDIwJSAyMCUscmdiYSgxMjQsNTgsMjM3LDAuMjUpIDAlLHRyYW5zcGFyZW50IDYwJSkscmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgNjAlIDUwJSBhdCA4MCUgODAlLHJnYmEoMzcsOTksMjM1LDAuMikgMCUsdHJhbnNwYXJlbnQgNjAlKSxsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwMzA1MGYgMCUsIzA4MGQxZiA1MCUsIzA1MDgxMCAxMDAlKTtwYWRkaW5nOjIwcHggMjBweCAxOHB4O3RleHQtYWxpZ246Y2VudGVyO3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjt9CiAgLmhkcjo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LHJnYmEoMTkyLDEzMiwyNTIsMC42KSx0cmFuc3BhcmVudCk7fQogIC5oZHItc3Vie2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoMTkyLDEzMiwyNTIsMC43KTttYXJnaW4tYm90dG9tOjZweDt9CiAgLmhkci10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjZweDtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZjtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5oZHItdGl0bGUgc3Bhbntjb2xvcjojYzA4NGZjO30KICAuaGRyLWRlc2N7bWFyZ2luLXRvcDo2cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQ1KTtsZXR0ZXItc3BhY2luZzoycHg7fQogIC5sb2dvdXR7cG9zaXRpb246YWJzb2x1dGU7dG9wOjE2cHg7cmlnaHQ6MTRweDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wNyk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NXB4IDEycHg7Zm9udC1zaXplOjExcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjYpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KCgoKCiAgLyogTkFWIHBpbGwgc3R5bGUgKi8KICAubmF2LXdyYXB7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTgwZGVnLCMwODBkMWYgMCUsIzBjMTQyOCAxMDAlKTtwYWRkaW5nOjEwcHggMTBweCAwO3Bvc2l0aW9uOnN0aWNreTt0b3A6MDt6LWluZGV4OjEwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wNik7Ym94LXNoYWRvdzowIDRweCAyMHB4IHJnYmEoMCwwLDAsMC4zKTt9CiAgLm5hdntkaXNwbGF5OmZsZXg7Z2FwOjRweDtvdmVyZmxvdy14OmF1dG87c2Nyb2xsYmFyLXdpZHRoOm5vbmU7cGFkZGluZy1ib3R0b206MTBweDt9CiAgLm5hdjo6LXdlYmtpdC1zY3JvbGxiYXJ7ZGlzcGxheTpub25lO30KICAubmF2LWl0ZW17ZmxleC1zaHJpbms6MDtwYWRkaW5nOjhweCAxNHB4O2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNCk7dGV4dC1hbGlnbjpjZW50ZXI7Y3Vyc29yOnBvaW50ZXI7d2hpdGUtc3BhY2U6bm93cmFwO2JvcmRlci1yYWRpdXM6OTk5cHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCk7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDQpO3RyYW5zaXRpb246YWxsIDAuMjJzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSk7bGV0dGVyLXNwYWNpbmc6MC4zcHg7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7fQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSl7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjcpO2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA4KTtib3JkZXItY29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjE4KTt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTt9CiAgLm5hdi1pdGVtLmFjdGl2ZXtjb2xvcjojZmZmO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMjJjNTVlLCMxNmEzNGEpO2JvcmRlci1jb2xvcjp0cmFuc3BhcmVudDtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNCwxOTcsOTQsMC40KSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4yKSBpbnNldDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTt9CiAgLm5hdi1pdGVtLm5hdi1zcGVlZC5hY3RpdmV7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMwNmI2ZDQsIzA4OTFiMik7Ym94LXNoYWRvdzowIDRweCAxNnB4IHJnYmEoNiwxODIsMjEyLDAuNCksMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMikgaW5zZXQ7fQogIC5uYXYtaXRlbS5uYXYtc3BlZWQ6aG92ZXI6bm90KC5hY3RpdmUpe2NvbG9yOiMwNmI2ZDQ7Ym9yZGVyLWNvbG9yOnJnYmEoNiwxODIsMjEyLDAuMyk7fQogIC5zZWN7cGFkZGluZzoxNHB4O2Rpc3BsYXk6bm9uZTthbmltYXRpb246ZmkgLjNzIGVhc2U7fQogIC5zZWMuYWN0aXZle2Rpc3BsYXk6YmxvY2s7fQogIEBrZXlmcmFtZXMgZml7ZnJvbXtvcGFjaXR5OjA7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoNnB4KX10b3tvcGFjaXR5OjE7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoMCl9fQogIC5jYXJke2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7bWFyZ2luLWJvdHRvbToxMHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zZWMtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc2VjLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5idG4tcntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6NnB4IDE0cHg7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmJ0bi1yOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Y29sb3I6dmFyKC0tYWMpO30KICAuc2dyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNje2JhY2tncm91bmQ6dmFyKC0tY2FyZCk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE0cHg7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO2JveC1zaGFkb3c6dmFyKC0tc2hhZG93KTt9CiAgLnNsYmx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206OHB4O30KICAuc3ZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjRweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTtsaW5lLWhlaWdodDoxO30KICAuc3ZhbCBzcGFue2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5zc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjRweDt9CiAgLmRudXR7cG9zaXRpb246cmVsYXRpdmU7d2lkdGg6NTJweDtoZWlnaHQ6NTJweDttYXJnaW46NHB4IGF1dG8gNHB4O30KICAuZG51dCBzdmd7dHJhbnNmb3JtOnJvdGF0ZSgtOTBkZWcpO30KICAuZGJne2ZpbGw6bm9uZTtzdHJva2U6cmdiYSgwLDAsMCwwLjA2KTtzdHJva2Utd2lkdGg6NDt9CiAgLmR2e2ZpbGw6bm9uZTtzdHJva2Utd2lkdGg6NDtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDFzIGVhc2U7fQogIC5kY3twb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTJweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnBie2hlaWdodDo0cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLDAuMDYpO2JvcmRlci1yYWRpdXM6MnB4O21hcmdpbi10b3A6OHB4O292ZXJmbG93OmhpZGRlbjt9CiAgLnBme2hlaWdodDoxMDAlO2JvcmRlci1yYWRpdXM6MnB4O3RyYW5zaXRpb246d2lkdGggMXMgZWFzZTt9CiAgLnBmLnB1e2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLWFjKSwjMTZhMzRhKTt9CiAgLnBmLnBne2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHZhcigtLW5nKSwjMTZhMzRhKTt9CiAgLnBmLnBve2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCNmYjkyM2MsI2Y5NzMxNik7fQogIC5wZi5wcntiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpO30KICAudWJkZ3tkaXNwbGF5OmZsZXg7Z2FwOjVweDtmbGV4LXdyYXA6d3JhcDttYXJnaW4tdG9wOjhweDt9CiAgLmJkZ3tiYWNrZ3JvdW5kOiNmMWY1Zjk7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDhweDtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC5uZXQtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5uaXtmbGV4OjE7fQogIC5uZHtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1hYyk7bWFyZ2luLWJvdHRvbTozcHg7fQogIC5uc3tmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo3MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm5zIHNwYW57Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtd2VpZ2h0OjQwMDt9CiAgLm50e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmRpdmlkZXJ7d2lkdGg6MXB4O2JhY2tncm91bmQ6dmFyKC0tYm9yZGVyKTttYXJnaW46NHB4IDA7fQogIC5vcGlsbHtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6MjBweDtwYWRkaW5nOjVweCAxNHB4O2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW5nKTtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4O3doaXRlLXNwYWNlOm5vd3JhcDt9CiAgLm9waWxsLm9mZntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmRvdHt3aWR0aDo1cHg7aGVpZ2h0OjVweDtib3JkZXItcmFkaXVzOjUwJTtiYWNrZ3JvdW5kOnZhcigtLW5nKTtib3gtc2hhZG93OjAgMCAzcHggdmFyKC0tbmcpO2FuaW1hdGlvbjpwbHMgNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQogIC5kb3QucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgQGtleWZyYW1lcyBwbHN7MCUsMTAwJXtvcGFjaXR5Oi45O2JveC1zaGFkb3c6MCAwIDJweCB2YXIoLS1uZyl9NTAle29wYWNpdHk6LjY7Ym94LXNoYWRvdzowIDAgNHB4IHZhcigtLW5nKX19CiAgLnh1aS1yb3d7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC54dWktaW5mb3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS43O30KICAueHVpLWluZm8gYntjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLWxpc3R7ZGlzcGxheTpmbGV4O2ZsZXgtZGlyZWN0aW9uOmNvbHVtbjtnYXA6OHB4O21hcmdpbi10b3A6MTBweDt9CiAgLnN2Y3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMDUpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxMXB4IDE0cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2Vlbjt9CiAgLnN2Yy5kb3due2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4wNSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMik7fQogIC5zdmMtbHtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O30KICAuZGd7d2lkdGg6NnB4O2hlaWdodDo2cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94LXNoYWRvdzowIDAgM3B4IHZhcigtLW5nKTtmbGV4LXNocmluazowO30KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4OjEwMDtkaXNwbGF5Om5vbmU7YWxpZ24taXRlbXM6ZmxleC1lbmQ7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLm1vdmVyLm9wZW57ZGlzcGxheTpmbGV4O30KICAubW9kYWx7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjIwcHggMjBweCAwIDA7d2lkdGg6MTAwJTttYXgtd2lkdGg6NDgwcHg7cGFkZGluZzoyMHB4O21heC1oZWlnaHQ6ODV2aDtvdmVyZmxvdy15OmF1dG87YW5pbWF0aW9uOnN1IC4zcyBlYXNlO2JveC1zaGFkb3c6MCAtNHB4IDMwcHggcmdiYSgwLDAsMCwwLjEyKTt9CiAgQGtleWZyYW1lcyBzdXtmcm9te3RyYW5zZm9ybTp0cmFuc2xhdGVZKDEwMCUpfXRve3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAubWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206MTZweDt9CiAgLm10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTRweDtjb2xvcjp2YXIoLS10eHQpO30KICAubWNsb3Nle3dpZHRoOjMycHg7aGVpZ2h0OjMycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7Zm9udC1zaXplOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO30KICAuZGdyaWR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLWJvdHRvbToxNHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRye2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7cGFkZGluZzo3cHggMDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZHI6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5ka3tmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5kdntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmR2LmdyZWVue2NvbG9yOnZhcigtLW5nKTt9CiAgLmR2LnJlZHtjb2xvcjojZWY0NDQ0O30KICAuZHYubW9ub3tjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjlweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt3b3JkLWJyZWFrOmJyZWFrLWFsbDt9CiAgLmFncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6OHB4O30KICAubS1zdWJ7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTRweDtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHg7fQogIC5tLXN1Yi5vcGVue2Rpc3BsYXk6YmxvY2s7YW5pbWF0aW9uOmZpIC4ycyBlYXNlO30KICAubXN1Yi1sYmx7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuYWJ0bntiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHggMTBweDt0ZXh0LWFsaWduOmNlbnRlcjtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5hYnRuOmhvdmVye2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAuYWJ0biAuYWl7Zm9udC1zaXplOjIycHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5hYnRuIC5hbntmb250LXNpemU6MTJweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLmFidG4gLmFke2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFidG4uZGFuZ2VyOmhvdmVye2JhY2tncm91bmQ6cmdiYSgyNDgsMTEzLDExMywuMSk7Ym9yZGVyLWNvbG9yOiNmODcxNzE7fQogIC5vZXt0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjQwcHggMjBweDt9CiAgLm9lIC5laXtmb250LXNpemU6NDhweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5vZSBwe2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CiAgLm9jcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O21hcmdpbi1ib3R0b206MTZweDt9CiAgLnV0e2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLyogcmVzdWx0IGJveCAqLwogIC5yZXMtYm94e3Bvc2l0aW9uOnJlbGF0aXZlO2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTRweDttYXJnaW4tdG9wOjE0cHg7ZGlzcGxheTpub25lO30KICAucmVzLWJveC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5yZXMtY2xvc2V7cG9zaXRpb246YWJzb2x1dGU7dG9wOi0xMXB4O3JpZ2h0Oi0xMXB4O3dpZHRoOjIycHg7aGVpZ2h0OjIycHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZWY0NDQ0O2JvcmRlcjoycHggc29saWQgI2ZmZjtjb2xvcjojZmZmO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxMXB4O2ZvbnQtd2VpZ2h0OjcwMDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bGluZS1oZWlnaHQ6MTtib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDIzOSw2OCw2OCwwLjQpO3otaW5kZXg6Mjt9CiAgLnJlcy1yb3d7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO3BhZGRpbmc6NXB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgI2RjZmNlNztmb250LXNpemU6MTNweDt9CiAgLnJlcy1yb3c6bGFzdC1jaGlsZHtib3JkZXItYm90dG9tOm5vbmU7fQogIC5yZXMta3tjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjExcHg7fQogIC5yZXMtdntjb2xvcjp2YXIoLS10eHQpO2ZvbnQtd2VpZ2h0OjYwMDt3b3JkLWJyZWFrOmJyZWFrLWFsbDt0ZXh0LWFsaWduOnJpZ2h0O21heC13aWR0aDo2NSU7fQogIC5yZXMtbGlua3tiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4IDEwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7bWFyZ2luLXRvcDo4cHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuY29weS1idG57d2lkdGg6MTAwJTttYXJnaW4tdG9wOjhweDtwYWRkaW5nOjhweDtib3JkZXItcmFkaXVzOjhweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWFjLWJvcmRlcik7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO2NvbG9yOnZhcigtLWFjKTtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt9CiAgLyogYWxlcnQgKi8KICAuYWxlcnR7ZGlzcGxheTpub25lO3BhZGRpbmc6MTBweCAxNHB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O21hcmdpbi10b3A6MTBweDt9CiAgLmFsZXJ0Lm9re2JhY2tncm91bmQ6I2YwZmRmNDtib3JkZXI6MXB4IHNvbGlkICM4NmVmYWM7Y29sb3I6IzE1ODAzZDt9CiAgLmFsZXJ0LmVycntiYWNrZ3JvdW5kOiNmZWYyZjI7Ym9yZGVyOjFweCBzb2xpZCAjZmNhNWE1O2NvbG9yOiNkYzI2MjY7fQogIC8qIHNwaW5uZXIgKi8KICAuc3BpbntkaXNwbGF5OmlubGluZS1ibG9jazt3aWR0aDoxMnB4O2hlaWdodDoxMnB4O2JvcmRlcjoycHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMyk7Ym9yZGVyLXRvcC1jb2xvcjojZmZmO2JvcmRlci1yYWRpdXM6NTAlO2FuaW1hdGlvbjpzcCAuN3MgbGluZWFyIGluZmluaXRlO3ZlcnRpY2FsLWFsaWduOm1pZGRsZTttYXJnaW4tcmlnaHQ6NHB4O30KICBAa2V5ZnJhbWVzIHNwe3Rve3RyYW5zZm9ybTpyb3RhdGUoMzYwZGVnKX19CiAgLmxvYWRpbmd7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzozMHB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXNpemU6MTNweDt9CgoKICAvKiDilIDilIAgREFSSyBGT1JNIChTU0gpIOKUgOKUgCAqLwogIC5zc2gtZGFyay1mb3Jte2JhY2tncm91bmQ6IzBkMTExNztib3JkZXItcmFkaXVzOjE2cHg7cGFkZGluZzoxOHB4IDE2cHg7bWFyZ2luLWJvdHRvbTowO30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAvKiBDcmVhdGUgYnRuIChzc2ggZGFyaykgKi8KICAuY2J0bi1zc2h7YmFja2dyb3VuZDp0cmFuc3BhcmVudDtib3JkZXI6MnB4IHNvbGlkICMyMmM1NWU7Y29sb3I6IzIyYzU1ZTtmb250LXNpemU6MTNweDt3aWR0aDphdXRvO3BhZGRpbmc6MTBweCAyOHB4O2JvcmRlci1yYWRpdXM6MTBweDtjdXJzb3I6cG9pbnRlcjtmb250LXdlaWdodDo3MDA7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7dHJhbnNpdGlvbjphbGwgLjJzO2Rpc3BsYXk6aW5saW5lLWZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7fQogIC5jYnRuLXNzaDpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMzQsMTk3LDk0LC4yKTt9CiAgLyogTGluayByZXN1bHQgKi8KICAubGluay1yZXN1bHR7ZGlzcGxheTpub25lO21hcmdpbi10b3A6MTJweDtib3JkZXItcmFkaXVzOjEwcHg7b3ZlcmZsb3c6aGlkZGVuO30KICAubGluay1yZXN1bHQuc2hvd3tkaXNwbGF5OmJsb2NrO30KICAubGluay1yZXN1bHQtaGRye2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDtwYWRkaW5nOjhweCAxMnB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuMyk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDYpO30KICAuaW1wLWJhZGdle2ZvbnQtc2l6ZTouNjJyZW07Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjEuNXB4O3BhZGRpbmc6LjE4cmVtIC41NXJlbTtib3JkZXItcmFkaXVzOjk5cHg7fQogIC5pbXAtYmFkZ2UubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjE1KTtjb2xvcjojMDBjY2ZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgwLDE4MCwyNTUsLjMpO30KICAuaW1wLWJhZGdlLmRhcmt7YmFja2dyb3VuZDpyZ2JhKDE1Myw1MSwyNTUsLjE1KTtjb2xvcjojY2M2NmZmO2JvcmRlcjoxcHggc29saWQgcmdiYSgxNTMsNTEsMjU1LC4zKTt9CiAgLmxpbmstcHJldmlld3tiYWNrZ3JvdW5kOiMwNjBhMTI7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTBweDtmb250LWZhbWlseTptb25vc3BhY2U7Zm9udC1zaXplOi41NnJlbTtjb2xvcjojMDBhYWRkO3dvcmQtYnJlYWs6YnJlYWstYWxsO2xpbmUtaGVpZ2h0OjEuNjttYXJnaW46OHB4IDEycHg7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTUwLDI1NSwuMTUpO21heC1oZWlnaHQ6NTRweDtvdmVyZmxvdzpoaWRkZW47cG9zaXRpb246cmVsYXRpdmU7fQogIC5saW5rLXByZXZpZXcuZGFyay1scHtib3JkZXItY29sb3I6cmdiYSgxNTMsNTEsMjU1LC4yMik7Y29sb3I6I2FhNTVmZjt9CiAgLmxpbmstcHJldmlldzo6YWZ0ZXJ7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjA7cmlnaHQ6MDtoZWlnaHQ6MTRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCh0cmFuc3BhcmVudCwjMDYwYTEyKTt9CiAgLmNvcHktbGluay1idG57d2lkdGg6Y2FsYygxMDAlIC0gMjRweCk7bWFyZ2luOjAgMTJweCAxMHB4O3BhZGRpbmc6LjU1cmVtO2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO2N1cnNvcjpwb2ludGVyO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2JvcmRlcjoxcHggc29saWQ7fQogIC5jb3B5LWxpbmstYnRuLm5wdntiYWNrZ3JvdW5kOnJnYmEoMCwxODAsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMCwxODAsMjU1LC4yOCk7Y29sb3I6IzAwY2NmZjt9CiAgLmNvcHktbGluay1idG4uZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMDcpO2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjI4KTtjb2xvcjojY2M2NmZmO30KICAvKiBVc2VyIHRhYmxlICovCiAgLnV0Ymwtd3JhcHtvdmVyZmxvdy14OmF1dG87bWFyZ2luLXRvcDoxMHB4O30KICAudXRibHt3aWR0aDoxMDAlO2JvcmRlci1jb2xsYXBzZTpjb2xsYXBzZTtmb250LXNpemU6MTJweDt9CiAgLnV0YmwgdGh7cGFkZGluZzo4cHggMTBweDt0ZXh0LWFsaWduOmxlZnQ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoxLjVweDtjb2xvcjp2YXIoLS1tdXRlZCk7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLnV0YmwgdGR7cGFkZGluZzo5cHggMTBweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0cjpsYXN0LWNoaWxkIHRke2JvcmRlci1ib3R0b206bm9uZTt9CiAgLmJkZ3twYWRkaW5nOjJweCA4cHg7Ym9yZGVyLXJhZGl1czoyMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjcwMDt9CiAgLmJkZy1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOiMyMmM1NWU7fQogIC5iZGctcntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYnRuLXRibHt3aWR0aDozMHB4O2hlaWdodDozMHB4O2JvcmRlci1yYWRpdXM6OHB4O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y3Vyc29yOnBvaW50ZXI7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXNpemU6MTRweDt9CiAgLmJ0bi10Ymw6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLyogUmVuZXcgZGF5cyBiYWRnZSAqLwogIC5kYXlzLWJhZGdle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMHB4O3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMDgpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO2NvbG9yOnZhcigtLWFjKTt9CgogIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8gIC8qIOKUgOKUgCBTRUxFQ1RPUiBDQVJEUyDilIDilIAgKi8KICAuc2VjLWxhYmVse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjZweCAycHggMTBweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7fQogIC5zZWwtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTZweDtwYWRkaW5nOjE2cHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTRweDtjdXJzb3I6cG9pbnRlcjt0cmFuc2l0aW9uOmFsbCAuMnM7Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLnNlbC1jYXJkOmhvdmVye2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7YmFja2dyb3VuZDp2YXIoLS1hYy1kaW0pO3RyYW5zZm9ybTp0cmFuc2xhdGVYKDJweCk7fQogIC5zZWwtbG9nb3t3aWR0aDo2NHB4O2hlaWdodDo2NHB4O2JvcmRlci1yYWRpdXM6MTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXN7YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVle2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2h7YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWFpcy1zbSwuc2VsLXRydWUtc20sLnNlbC1zc2gtc217d2lkdGg6NDRweDtoZWlnaHQ6NDRweDtib3JkZXItcmFkaXVzOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZsZXgtc2hyaW5rOjA7fQogIC5zZWwtYWlzLXNte2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkICNjNWU4OWE7fQogIC5zZWwtdHJ1ZS1zbXtiYWNrZ3JvdW5kOiNjODA0MGQ7fQogIC5zZWwtc3NoLXNte2JhY2tncm91bmQ6IzE1NjVjMDt9CiAgLnNlbC1pbmZve2ZsZXg6MTttaW4td2lkdGg6MDt9CiAgLnNlbC1uYW1le2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODJyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206NHB4O30KICAuc2VsLW5hbWUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5zZWwtbmFtZS50cnVle2NvbG9yOiNjODA0MGQ7fQogIC5zZWwtbmFtZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLnNlbC1zdWJ7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNTt9CiAgLnNlbC1hcnJvd3tmb250LXNpemU6MS40cmVtO2NvbG9yOnZhcigtLW11dGVkKTtmbGV4LXNocmluazowO30KICAvKiDilIDilIAgRk9STSBIRUFERVIg4pSA4pSAICovCiAgLmZvcm0tYmFja3tkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDo2cHg7Zm9udC1zaXplOjEzcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO3BhZGRpbmc6NHB4IDJweCAxMnB4O2ZvbnQtd2VpZ2h0OjYwMDt9CiAgLmZvcm0tYmFjazpob3Zlcntjb2xvcjp2YXIoLS10eHQpO30KICAuZm9ybS1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTJweDttYXJnaW4tYm90dG9tOjE2cHg7cGFkZGluZy1ib3R0b206MTRweDtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAuZm9ybS10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljg1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjNweDt9CiAgLmZvcm0tdGl0bGUuYWlze2NvbG9yOiMzZDdhMGU7fQogIC5mb3JtLXRpdGxlLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLmZvcm0tdGl0bGUuc3Noe2NvbG9yOiMxNTY1YzA7fQogIC5mb3JtLXN1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7fQogIC5jYnRuLWFpc3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzNkN2EwZSwjNWFhYTE4KTt9CiAgLmNidG4tdHJ1ZXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsI2E2MDAwYywjZDgxMDIwKTt9CgogIC8qIOKUgOKUgCBIRFIgbG9nbyBhbmltYXRpb25zIChzYW1lIGFzIGxvZ2luKSDilIDilIAgKi8KICBAa2V5ZnJhbWVzIGhkci1vcmJpdC1kYXNoIHsKICAgIGZyb20geyBzdHJva2UtZGFzaG9mZnNldDogMDsgfQogICAgdG8gICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAtMjUxOyB9CiAgfQogIEBrZXlmcmFtZXMgaGRyLXB1bHNlLWRyYXcgewogICAgMCUgICB7IHN0cm9rZS1kYXNob2Zmc2V0OiAyMjA7IG9wYWNpdHk6IDA7IH0KICAgIDE1JSAgeyBvcGFjaXR5OiAxOyB9CiAgICAxMDAlIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDA7IG9wYWNpdHk6IDE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItYmxpbmstZG90IHsKICAgIDAlLCAxMDAlIHsgb3BhY2l0eTogMC4yNTsgfQogICAgNTAlICAgICAgIHsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGhkci1sb2dvLWdsb3cgewogICAgMCUsIDEwMCUgeyBmaWx0ZXI6IGRyb3Atc2hhZG93KDAgMCA2cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDE0cHggIzI1NjNlYik7IH0KICAgIDUwJSAgICAgICB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDE0cHggIzYwYTVmYSkgZHJvcC1zaGFkb3coMCAwIDI4cHggIzI1NjNlYikgZHJvcC1zaGFkb3coMCAwIDQycHggIzA2YjZkNCk7IH0KICB9CiAgLmhkci1sb2dvLXN2Zy13cmFwIHsKICAgIGRpc3BsYXk6IGZsZXg7CiAgICBqdXN0aWZ5LWNvbnRlbnQ6IGNlbnRlcjsKICAgIG1hcmdpbi1ib3R0b206IDhweDsKICAgIGFuaW1hdGlvbjogaGRyLWxvZ28tZ2xvdyAzcyBlYXNlLWluLW91dCBpbmZpbml0ZTsKICB9CiAgLmhkci1vcmJpdC1yaW5nIHsgdHJhbnNmb3JtLW9yaWdpbjogNTBweCA1MHB4OyBhbmltYXRpb246IGhkci1vcmJpdC1kYXNoIDhzIGxpbmVhciBpbmZpbml0ZTsgfQogIC5oZHItd2F2ZS1hbmltICB7IHN0cm9rZS1kYXNoYXJyYXk6MjIwOyBzdHJva2UtZGFzaG9mZnNldDoyMjA7IGFuaW1hdGlvbjogaGRyLXB1bHNlLWRyYXcgMS42cyBjdWJpYy1iZXppZXIoLjQsMCwuMiwxKSAwLjVzIGZvcndhcmRzOyB9CiAgLmhkci1kb3QtMSB7IGFuaW1hdGlvbjogaGRyLWJsaW5rLWRvdCAyLjJzIGVhc2UtaW4tb3V0IDEuOHMgaW5maW5pdGU7IH0KICAuaGRyLWRvdC0yIHsgYW5pbWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMi4ycyBpbmZpbml0ZTsgfQoKICAvKiDilIDilIAgRGFzaGJvYXJkIEZpcmVmbGllcyAoZnVsbCBwYWdlKSDilIDilIAgKi8KICAuZGFzaC1mZiB7CiAgICBwb3NpdGlvbjogZml4ZWQ7CiAgICBib3JkZXItcmFkaXVzOiA1MCU7CiAgICBwb2ludGVyLWV2ZW50czogbm9uZTsKICAgIHotaW5kZXg6IDA7CiAgICBhbmltYXRpb246IGRhc2gtZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLCBkYXNoLWZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlOwogICAgb3BhY2l0eTogMDsKICB9CiAgQGtleWZyYW1lcyBkYXNoLWZmLWRyaWZ0IHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgICAyMCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpOyB9CiAgICA0MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHgzKSx2YXIoLS1keTMpKSBzY2FsZSgxLjA1KTsgfQogICAgODAlICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpOyB9CiAgfQogIEBrZXlmcmFtZXMgZGFzaC1mZi1ibGluayB7CiAgICAwJSwxMDAleyBvcGFjaXR5OjA7IH0gMTUleyBvcGFjaXR5OjA7IH0gMzAleyBvcGFjaXR5OjE7IH0KICAgIDUwJXsgb3BhY2l0eTowLjk7IH0gNjUleyBvcGFjaXR5OjA7IH0gODAleyBvcGFjaXR5OjAuODU7IH0gOTIleyBvcGFjaXR5OjA7IH0KICB9CgogIC8qIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkAogICAgIDNEIENBUkRTIC8gVEFCUyAvIEJVVFRPTlMg4oCUIOC4l+C4uOC4geC4q+C4meC5ieC4sgogIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkCAqLwogIC5jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMjUpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDI0cHggcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAycHggOHB4IHJnYmEoMzQsMTk3LDk0LDAuMTIpLAogICAgICAwIDE2cHggMzJweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSB0cmFuc2xhdGVaKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLmNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVooMCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNHB4IDM2cHggcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDRweCAxNnB4IHJnYmEoMzQsMTk3LDk0LDAuMTgpLAogICAgICAwIDI0cHggNDhweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBOYXYgaXRlbXMgM0QgKi8KICAubmF2LWl0ZW0gewogICAgYm9yZGVyLXJhZGl1czogMTJweCAxMnB4IDAgMCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAycHggc29saWQgdHJhbnNwYXJlbnQ7CiAgICBib3gtc2hhZG93OiAwIC0ycHggNnB4IHJnYmEoMCwwLDAsMC4xNSkgaW5zZXQ7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSAhaW1wb3J0YW50OwogICAgbWFyZ2luOiAwIDJweDsKICAgIHBhZGRpbmctdG9wOiAxNHB4ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMnB4KTsKICB9CiAgLm5hdi1pdGVtLmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCkgIWltcG9ydGFudDsKICAgIGJvcmRlci1jb2xvcjogcmdiYSgzNCwxOTcsOTQsMC4zNSkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgLTRweCAxMnB4IHJnYmEoMzQsMTk3LDk0LDAuMTUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICB9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCk7CiAgICBib3JkZXItY29sb3I6IHJnYmEoMzQsMTk3LDk0LDAuMTUpICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBBbGwgYnV0dG9ucyAzRCAqLwogIC5jYnRuLCAuYnRuLXIsIC5jYnRtLXNzaCwgLmJ0bi10YmwsIC5wYnRuLCAudGJ0biwKICAuY29weS1idG4sIC5jb3B5LWxpbmstYnRuLCAubG9nb3V0LCAubWNsb3NlLAogIC5hYnRuLCAucG9ydC1idG4sIC5waWNrLW9wdCB7CiAgICBib3JkZXItcmFkaXVzOiAxMnB4ICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDRweCAwIHJnYmEoMCwwLDAsMC4zNSksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEyKSBpbnNldCwKICAgICAgMCA2cHggMTZweCByZ2JhKDAsMCwwLDAuMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjEycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjEycyBlYXNlICFpbXBvcnRhbnQ7CiAgICBib3JkZXItd2lkdGg6IDJweCAhaW1wb3J0YW50OwogIH0KICAuY2J0bjpob3ZlciwgLmJ0bi1yOmhvdmVyLCAuY29weS1idG46aG92ZXIsCiAgLmFidG46aG92ZXIsIC5wb3J0LWJ0bjpob3ZlciwgLnBpY2stb3B0OmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KTsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjM1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpIGluc2V0LAogICAgICAwIDEwcHggMjRweCByZ2JhKDAsMCwwLDAuMjUpICFpbXBvcnRhbnQ7CiAgfQogIC5jYnRuOmFjdGl2ZSwgLmJ0bi1yOmFjdGl2ZSwgLmNvcHktYnRuOmFjdGl2ZSwKICAuYWJ0bjphY3RpdmUsIC5wb3J0LWJ0bjphY3RpdmUsIC5waWNrLW9wdDphY3RpdmUsCiAgLmJ0bi10Ymw6YWN0aXZlLCAubG9nb3V0OmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoM3B4KSBzY2FsZSgwLjk3KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCAxcHggMCByZ2JhKDAsMCwwLDAuNCksCiAgICAgIDAgMCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wNikgaW5zZXQgIWltcG9ydGFudDsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjA2cyBlYXNlLCBib3gtc2hhZG93IDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CgogIC8qIHNlbC1jYXJkIDNEICovCiAgLnNlbC1jYXJkIHsKICAgIGJvcmRlci1yYWRpdXM6IDE4cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNHB4IDAgcmdiYSgwLDAsMCwwLjIpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4wOCkgaW5zZXQsCiAgICAgIDAgOHB4IDIwcHggcmdiYSgwLDAsMCwwLjEyKSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVgoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xOHMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0zcHgpIHRyYW5zbGF0ZVgoMnB4KSAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA4cHggMCByZ2JhKDAsMCwwLDAuMjUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCwKICAgICAgMCAxNnB4IDMycHggcmdiYSgwLDAsMCwwLjE4KSAhaW1wb3J0YW50OwogIH0KICAuc2VsLWNhcmQ6YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgycHgpIHRyYW5zbGF0ZVgoMCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KCiAgLyogdWl0ZW1zIDNEICovCiAgLnVpdGVtIHsKICAgIGJvcmRlci1yYWRpdXM6IDE0cHggIWltcG9ydGFudDsKICAgIGJvcmRlcjogMnB4IHNvbGlkIHZhcigtLWJvcmRlcikgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgM3B4IDAgcmdiYSgwLDAsMCwwLjE4KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDcpIGluc2V0LAogICAgICAwIDZweCAxNHB4IHJnYmEoMCwwLDAsMC4wOCkgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKTsKICAgIHRyYW5zaXRpb246IHRyYW5zZm9ybSAwLjE1cyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpLAogICAgICAgICAgICAgICAgYm94LXNoYWRvdyAwLjE1cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgNnB4IDAgcmdiYSgwLDAsMCwwLjIyKSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDkpIGluc2V0LAogICAgICAwIDEycHggMjRweCByZ2JhKDAsMCwwLDAuMTIpICFpbXBvcnRhbnQ7CiAgfQogIC51aXRlbTphY3RpdmUgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDJweCkgc2NhbGUoMC45OCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6IDAgMXB4IDAgcmdiYSgwLDAsMCwwLjMpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAvKiBib3VuY2Uga2V5ZnJhbWUg4Liq4Liz4Lir4Lij4Lix4Lia4LiB4LiUICovCiAgQGtleWZyYW1lcyBidG4tYm91bmNlIHsKICAgIDAlICAgeyB0cmFuc2Zvcm06IHNjYWxlKDEpOyB9CiAgICAzMCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjkzKSB0cmFuc2xhdGVZKDNweCk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDEuMDQpIHRyYW5zbGF0ZVkoLTJweCk7IH0KICAgIDgwJSAgeyB0cmFuc2Zvcm06IHNjYWxlKDAuOTgpIHRyYW5zbGF0ZVkoMXB4KTsgfQogICAgMTAwJSB7IHRyYW5zZm9ybTogc2NhbGUoMSkgdHJhbnNsYXRlWSgwKTsgfQogIH0KICAuY2J0bjphY3RpdmUsIC5idG4tcjphY3RpdmUsIC5jb3B5LWJ0bjphY3RpdmUgeyBhbmltYXRpb246IGJ0bi1ib3VuY2UgMC4yOHMgZWFzZSBmb3J3YXJkcyAhaW1wb3J0YW50OyB9CgogIC8qIE5hdiAzRCBwaWxscyBvdmVycmlkZSAqLwogIC5uYXYtaXRlbXtib3JkZXItcmFkaXVzOjk5OXB4IWltcG9ydGFudDtib3gtc2hhZG93OjAgM3B4IDAgcmdiYSgwLDAsMCwwLjMpLDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEpIGluc2V0IWltcG9ydGFudDtib3JkZXItd2lkdGg6MS41cHghaW1wb3J0YW50O30KICAubmF2LWl0ZW0uYWN0aXZle3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpIWltcG9ydGFudDt9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMXB4KTt9CgogIC8qIEZpcmVmbGllcyBpbnNpZGUgY2FyZHMgKi8KICAuY2FyZC1mZntwb3NpdGlvbjphYnNvbHV0ZTtib3JkZXItcmFkaXVzOjUwJTtwb2ludGVyLWV2ZW50czpub25lO3otaW5kZXg6MDthbmltYXRpb246Y2ZmLWRyaWZ0IGxpbmVhciBpbmZpbml0ZSxjZmYtYmxpbmsgZWFzZS1pbi1vdXQgaW5maW5pdGU7b3BhY2l0eTowO30KICBAa2V5ZnJhbWVzIGNmZi1kcmlmdHswJXt0cmFuc2Zvcm06dHJhbnNsYXRlKDAsMCkgc2NhbGUoMSk7fTIwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MSksdmFyKC0tZHkxKSkgc2NhbGUoMS4xKTt9NDAle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgyKSx2YXIoLS1keTIpKSBzY2FsZSgwLjkpO302MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDMpLHZhcigtLWR5MykpIHNjYWxlKDEuMDUpO304MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDQpLHZhcigtLWR5NCkpIHNjYWxlKDAuOTUpO30xMDAle3RyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTt9fQogIEBrZXlmcmFtZXMgY2ZmLWJsaW5rezAlLDEwMCV7b3BhY2l0eTowO30xNSV7b3BhY2l0eTowO30zMCV7b3BhY2l0eTowLjk7fTUwJXtvcGFjaXR5OjAuNzt9NjUle29wYWNpdHk6MDt9ODAle29wYWNpdHk6MC44O305MiV7b3BhY2l0eTowO319CiAgLmNhcmQ+Kjpub3QoLmNhcmQtZmYpe3Bvc2l0aW9uOnJlbGF0aXZlO3otaW5kZXg6MTt9CiAgLnNjPio6bm90KC5jYXJkLWZmKXtwb3NpdGlvbjpyZWxhdGl2ZTt6LWluZGV4OjE7fQoKICAvKiBTUEVFRCBURVNUICovCiAgLnNwZWVkLWhlcm97YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwYTE2MjggMCUsIzA2MTAyMCAxMDAlKTtib3JkZXI6MnB4IHNvbGlkIHJnYmEoNiwxODIsMjEyLDAuMik7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjRweCAxNnB4O21hcmdpbi1ib3R0b206MTJweDt0ZXh0LWFsaWduOmNlbnRlcjtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1oZXJvOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JhY2tncm91bmQ6cmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgODAlIDUwJSBhdCA1MCUgMCUscmdiYSg2LDE4MiwyMTIsMC4xMiksdHJhbnNwYXJlbnQpO30KICAuc3BlZWQtdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjExcHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1nYXVnZS13cmFwe3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjE2MHB4O2hlaWdodDo4MHB4O21hcmdpbjowIGF1dG8gMTZweDt9CiAgLnNwZWVkLWdhdWdlLXN2Z3tvdmVyZmxvdzp2aXNpYmxlO30KICAuc3BlZWQtZ2F1Z2UtYmd7ZmlsbDpub25lO3N0cm9rZTpyZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt9CiAgLnNwZWVkLWdhdWdlLWZpbGx7ZmlsbDpub25lO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSxzdHJva2UgMC4zczt0cmFuc2Zvcm0tb3JpZ2luOjgwcHggODBweDt9CiAgLnNwZWVkLWNlbnRlcntwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MzJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMDZiNmQ0LCM2MGE1ZmEpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7fQogIC5zcGVlZC11bml0e2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNSk7bWFyZ2luLXRvcDoycHg7fQogIC5zcGVlZC1idG5ze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zcGVlZC1idG57cGFkZGluZzoxNHB4O2JvcmRlci1yYWRpdXM6MTRweDtib3JkZXI6bm9uZTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6MnB4O3RyYW5zaXRpb246YWxsIDAuMnM7fQogIC5zcGVlZC1idG4tZGx7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMyNTYzZWIsIzFkNGVkOCk7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNyw5OSwyMzUsMC40KTt9CiAgLnNwZWVkLWJ0bi1kbDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgzNyw5OSwyMzUsMC41KTt9CiAgLnNwZWVkLWJ0bi11bHtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzdjM2FlZCwjNmQyOGQ5KTtjb2xvcjojZmZmO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDEyNCw1OCwyMzcsMC40KTt9CiAgLnNwZWVkLWJ0bi11bDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgxMjQsNTgsMjM3LDAuNSk7fQogIC5zcGVlZC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjQ7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc3BlZWQtcmVzdWx0c3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc3BlZWQtcmVzLWNhcmR7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDQpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzoxNnB4O3RleHQtYWxpZ246Y2VudGVyO30KICAuc3BlZWQtcmVzLWljb257Zm9udC1zaXplOjIwcHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5zcGVlZC1yZXMtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQpO21hcmdpbi1ib3R0b206NHB4O30KICAuc3BlZWQtcmVzLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTt9CiAgLnNwZWVkLXJlcy12YWwuZGwtY29sb3J7Y29sb3I6IzYwYTVmYTt9CiAgLnNwZWVkLXJlcy12YWwudWwtY29sb3J7Y29sb3I6I2E3OGJmYTt9CiAgLnNwZWVkLXJlcy11bml0e2ZvbnQtc2l6ZTo5cHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjMpO21hcmdpbi10b3A6MnB4O30KICAuc3BlZWQtc3RhdHVze2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWluLWhlaWdodDoxOHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoyMHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctaXRlbXt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXBpbmctbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjM1KTttYXJnaW4tYm90dG9tOjJweDt9CiAgLnNwZWVkLXBpbmctdmFse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojNGFkZTgwO30KICAuc3BlZWQtcGluZy12YWwud2Fybntjb2xvcjojZmJiZjI0O30KICAuc3BlZWQtcGluZy12YWwuYmFke2NvbG9yOiNlZjQ0NDQ7fQogIC5zcGVlZC1iYXItd3JhcHtoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1iYXJ7aGVpZ2h0OjEwMCU7Ym9yZGVyLXJhZGl1czoycHg7d2lkdGg6MCU7dHJhbnNpdGlvbjp3aWR0aCAwLjNzIGVhc2U7fQogIC5zcGVlZC1iYXIuZGwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMyNTYzZWIsIzYwYTVmYSk7fQogIC5zcGVlZC1iYXIudWwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCM3YzNhZWQsI2E3OGJmYSk7fQogIC5zcGVlZC1pbmZvLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmcjtnYXA6OHB4O30KICAuc3BlZWQtaW5mby1pdGVte2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjAzKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wNik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLWluZm8tbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo3cHg7bGV0dGVyLXNwYWNpbmc6MXB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4zKTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNwZWVkLWluZm8tdmFse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuOCk7fQogIC5zcGVlZC1wcm9ne2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDYsMTgyLDIxMiwwLjE1KTtib3JkZXItcmFkaXVzOjJweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1wcm9nLWZpbGx7aGVpZ2h0OjEwMCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzA2YjZkNCwjNjBhNWZhKTtib3JkZXItcmFkaXVzOjJweDt3aWR0aDowJTt0cmFuc2l0aW9uOndpZHRoIDAuMnMgZWFzZTt9Cgo8L3N0eWxlPgo8c2NyaXB0IHNyYz0iaHR0cHM6Ly9jZG5qcy5jbG91ZGZsYXJlLmNvbS9hamF4L2xpYnMvcXJjb2RlanMvMS4wLjAvcXJjb2RlLm1pbi5qcyI+PC9zY3JpcHQ+CjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9IndyYXAiPgoKICA8IS0tIEhFQURFUiAtLT4KICA8ZGl2IGNsYXNzPSJoZHIiIGlkPSJoZHItcm9vdCI+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiPuKGqSDguK3guK3guIHguIjguLLguIHguKPguLDguJrguJo8L2J1dHRvbj4KCiAgICA8IS0tIExvZ28gU1ZHIChzYW1lIGFzIGxvZ2luKSAtLT4KICAgIDxkaXYgY2xhc3M9Imhkci1sb2dvLXN2Zy13cmFwIj4KICAgICAgPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDAgMTAwIiB3aWR0aD0iNzIiIGhlaWdodD0iNzIiPgogICAgICAgIDxkZWZzPgogICAgICAgICAgPGxpbmVhckdyYWRpZW50IGlkPSJoVyIgeDE9IjAlIiB5MT0iMCUiIHgyPSIxMDAlIiB5Mj0iMCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMyNTYzZWIiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSI1MCUiICBzdG9wLWNvbG9yPSIjNjBhNWZhIi8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iMTAwJSIgc3RvcC1jb2xvcj0iIzA2YjZkNCIvPgogICAgICAgICAgPC9saW5lYXJHcmFkaWVudD4KICAgICAgICAgIDxyYWRpYWxHcmFkaWVudCBpZD0iaEJnIiBjeD0iNTAlIiBjeT0iNTAlIiByPSI1MCUiPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjAlIiAgIHN0b3AtY29sb3I9IiMwZjFlNGEiIHN0b3Atb3BhY2l0eT0iMC45NSIvPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMwNjBjMWUiIHN0b3Atb3BhY2l0eT0iMC45OCIvPgogICAgICAgICAgPC9yYWRpYWxHcmFkaWVudD4KICAgICAgICAgIDxmaWx0ZXIgaWQ9ImhHbG93Ij4KICAgICAgICAgICAgPGZlR2F1c3NpYW5CbHVyIHN0ZERldmlhdGlvbj0iMi41IiByZXN1bHQ9ImIiLz4KICAgICAgICAgICAgPGZlTWVyZ2U+PGZlTWVyZ2VOb2RlIGluPSJiIi8+PGZlTWVyZ2VOb2RlIGluPSJTb3VyY2VHcmFwaGljIi8+PC9mZU1lcmdlPgogICAgICAgICAgPC9maWx0ZXI+CiAgICAgICAgICA8Y2xpcFBhdGggaWQ9ImhDbGlwIj48Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIvPjwvY2xpcFBhdGg+CiAgICAgICAgPC9kZWZzPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjQ2IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMTIpIiBzdHJva2Utd2lkdGg9IjEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSI0MiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC4yKSIgc3Ryb2tlLXdpZHRoPSIxIiBzdHJva2UtZGFzaGFycmF5PSI1IDQiIGNsYXNzPSJoZHItb3JiaXQtcmluZyIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM4IiBmaWxsPSJub25lIiBzdHJva2U9InJnYmEoMzcsOTksMjM1LDAuMjIpIiBzdHJva2Utd2lkdGg9IjEiLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzNCIgZmlsbD0idXJsKCNoQmcpIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiIGZpbGw9Im5vbmUiIHN0cm9rZT0idXJsKCNoVykiIHN0cm9rZS13aWR0aD0iMS44IiBvcGFjaXR5PSIwLjkiLz4KICAgICAgICA8bGluZSB4MT0iNTAiIHkxPSIxNCIgeDI9IjUwIiB5Mj0iMjAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iODAiIHgyPSI1MCIgeTI9Ijg2IiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSIxNCIgeTE9IjUwIiB4Mj0iMjAiIHkyPSI1MCIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iODAiIHkxPSI1MCIgeDI9Ijg2IiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGcgY2xpcC1wYXRoPSJ1cmwoI2hDbGlwKSI+CiAgICAgICAgICA8cG9seWxpbmUgcG9pbnRzPSIxNiw1MCAyNCw1MCAyOSwzMiAzNCw2OCAzOSwzMiA0NCw1MCA4NCw1MCIKICAgICAgICAgICAgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ1cmwoI2hXKSIgc3Ryb2tlLXdpZHRoPSIyLjIiCiAgICAgICAgICAgIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCIKICAgICAgICAgICAgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci13YXZlLWFuaW0iLz4KICAgICAgICA8L2c+CiAgICAgICAgPGNpcmNsZSBjeD0iMjkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjNjBhNWZhIiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0xIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzkiIGN5PSIzMiIgcj0iMi41IiBmaWxsPSIjMDZiNmQ0IiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0yIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iMzQiIGN5PSI2OCIgcj0iMi41IiBmaWxsPSIjNjBhNWZhIiBmaWx0ZXI9InVybCgjaEdsb3cpIiBjbGFzcz0iaGRyLWRvdC0xIi8+CiAgICAgIDwvc3ZnPgogICAgPC9kaXY+CgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE4cHg7Zm9udC13ZWlnaHQ6OTAwO2xldHRlci1zcGFjaW5nOjRweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZTBmMmZlLCM2MGE1ZmEsIzA2YjZkNCk7LXdlYmtpdC1iYWNrZ3JvdW5kLWNsaXA6dGV4dDstd2Via2l0LXRleHQtZmlsbC1jb2xvcjp0cmFuc3BhcmVudDtiYWNrZ3JvdW5kLWNsaXA6dGV4dDsiPkNIQUlZQTwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzo5cHg7Y29sb3I6cmdiYSg5NiwxNjUsMjUwLDAuNik7bWFyZ2luLXRvcDoycHg7Ij5QUk9KRUNUPC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJ3aWR0aDoxNDBweDtoZWlnaHQ6MXB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLHRyYW5zcGFyZW50LCM2MGE1ZmEsIzA2YjZkNCx0cmFuc3BhcmVudCk7bWFyZ2luOjZweCBhdXRvO29wYWNpdHk6MC41OyI+PC9kaXY+CiAgICA8ZGl2IHN0eWxlPSJmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OHB4O2xldHRlci1zcGFjaW5nOjRweDtjb2xvcjpyZ2JhKDYsMTgyLDIxMiwwLjU1KTttYXJnaW4tdG9wOjJweDsiPlYyUkFZICZhbXA7IFNTSDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6cmdiYSg5NiwxNjUsMjUwLDAuNSk7bWFyZ2luLXRvcDo0cHg7IiBpZD0iaGRyLWRvbWFpbiI+U0VDVVJFIFBBTkVMPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0gTkFWIC0tPgogIDxkaXYgY2xhc3M9Im5hdi13cmFwIj4KICA8ZGl2IGNsYXNzPSJuYXYiPgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gYWN0aXZlIiBvbmNsaWNrPSJzdygnZGFzaGJvYXJkJyx0aGlzKSI+8J+TiiDguYHguJTguIrguJrguK3guKPguYzguJQ8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnY3JlYXRlJyx0aGlzKSI+4p6VIOC4quC4o+C5ieC4suC4h+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdtYW5hZ2UnLHRoaXMpIj7wn5SnIOC4iOC4seC4lOC4geC4suC4o+C4ouC4ueC4qjwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdvbmxpbmUnLHRoaXMpIj7wn5+iIOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0iIG9uY2xpY2s9InN3KCdiYW4nLHRoaXMpIj7wn5qrIOC4m+C4peC4lOC5geC4muC4mTwvZGl2PgogICAgPGRpdiBjbGFzcz0ibmF2LWl0ZW0gbmF2LXNwZWVkIiBvbmNsaWNrPSJzdygnc3BlZWQnLHRoaXMpIj7imqEg4Liq4Lib4Li14LiU4LmA4LiX4LiqPC9kaXY+CiAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIGFjdGl2ZSIgaWQ9InRhYi1kYXNoYm9hcmQiPgogICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgIDxzcGFuIGNsYXNzPSJzZWMtdGl0bGUiPuKaoSBTWVNURU0gTU9OSVRPUjwvc3Bhbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIGlkPSJidG4tcmVmcmVzaCIgb25jbGljaz0ibG9hZERhc2goKSI+4oa7IOC4o+C4teC5gOC4n+C4o+C4ijwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJzZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7imqEgQ1BVIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJjcHUtcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiM0YWRlODAiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9ImNwdS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9ImNwdS1jb3JlcyI+LS0gY29yZXM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcGciIGlkPSJjcHUtYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfp6AgUkFNIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZG51dCI+CiAgICAgICAgICA8c3ZnIHdpZHRoPSI1MiIgaGVpZ2h0PSI1MiIgdmlld0JveD0iMCAwIDUyIDUyIj4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZGJnIiBjeD0iMjYiIGN5PSIyNiIgcj0iMjIiLz4KICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0iZHYiIGlkPSJyYW0tcmluZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIiBzdHJva2U9IiMzYjgyZjYiCiAgICAgICAgICAgICAgc3Ryb2tlLWRhc2hhcnJheT0iMTM4LjIiIHN0cm9rZS1kYXNob2Zmc2V0PSIxMzguMiIvPgogICAgICAgICAgPC9zdmc+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJkYyIgaWQ9InJhbS1wY3QiPi0tJTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKSIgaWQ9InJhbS1kZXRhaWwiPi0tIC8gLS0gR0I8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwYiI+PGRpdiBjbGFzcz0icGYgcHUiIGlkPSJyYW0tYmFyIiBzdHlsZT0id2lkdGg6MCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzNiODJmNiwjNjBhNWZhKSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+8J+SviBESVNLIFVTQUdFPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3ZhbCIgaWQ9ImRpc2stcGN0Ij4tLTxzcGFuPiU8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9ImRpc2stZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBvIiBpZD0iZGlzay1iYXIiIHN0eWxlPSJ3aWR0aDowJSI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4o+xIFVQVElNRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJ1cHRpbWUtdmFsIiBzdHlsZT0iZm9udC1zaXplOjIwcHgiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3N1YiIgaWQ9InVwdGltZS1zdWIiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idWJkZyIgaWQ9ImxvYWQtY2hpcHMiPjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfjJAgTkVUV09SSyBJL088L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ibmV0LXJvdyI+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkSBVcGxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LXVwIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LXVwLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkaXZpZGVyIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJuaSIgc3R5bGU9InRleHQtYWxpZ246cmlnaHQiPgogICAgICAgICAgPGRpdiBjbGFzcz0ibmQiPuKGkyBEb3dubG9hZDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnMiIGlkPSJuZXQtZG4iPi0tPHNwYW4+IC0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ibnQiIGlkPSJuZXQtZG4tdG90YWwiPnRvdGFsOiAtLTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCfk6EgWC1VSSBQQU5FTCBTVEFUVVM8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ieHVpLXJvdyI+CiAgICAgICAgPGRpdiBpZD0ieHVpLXBpbGwiIGNsYXNzPSJvcGlsbCBvZmYiPjxzcGFuIGNsYXNzPSJkb3QgcmVkIj48L3NwYW4+4LiB4Liz4Lil4Lix4LiH4LmA4LiK4LmH4LiELi4uPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ieHVpLWluZm8iPgogICAgICAgICAgPGRpdj7guYDguKfguK3guKPguYzguIrguLHguJkgWHJheTogPGIgaWQ9Inh1aS12ZXIiPi0tPC9iPjwvZGl2PgogICAgICAgICAgPGRpdj5JbmJvdW5kczogPGIgaWQ9Inh1aS1pbmJvdW5kcyI+LS08L2I+IOC4o+C4suC4ouC4geC4suC4ozwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtdGl0bGUiPvCflKcgU0VSVklDRSBNT05JVE9SPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRTZXJ2aWNlcygpIj7ihrsg4LmA4LiK4LmH4LiEPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdmMtbGlzdCIgaWQ9InN2Yy1saXN0Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Imx1IiBpZD0ibGFzdC11cGRhdGUiPuC4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogLS08L2Rpdj4KICA8L2Rpdj4KCiAgPCEtLSDilZDilZDilZDilZAgQ1JFQVRFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItY3JlYXRlIj4KCiAgICA8IS0tIOKUgOKUgCBTRUxFQ1RPUiAoZGVmYXVsdCB2aWV3KSDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJjcmVhdGUtbWVudSI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy1sYWJlbCI+8J+boSDguKPguLDguJrguJogM1gtVUkgVkxFU1M8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCdhaXMnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLWFpcyI+PGltZyBzcmM9Imh0dHBzOi8vdXBsb2FkLndpa2ltZWRpYS5vcmcvd2lraXBlZGlhL2NvbW1vbnMvdGh1bWIvZi9mOS9BSVNfbG9nby5zdmcvMjAwcHgtQUlTX2xvZ28uc3ZnLnBuZyIgb25lcnJvcj0idGhpcy5zdHlsZS5kaXNwbGF5PSdub25lJzt0aGlzLm5leHRTaWJsaW5nLnN0eWxlLmRpc3BsYXk9J2ZsZXgnIiBzdHlsZT0id2lkdGg6NTZweDtoZWlnaHQ6NTZweDtvYmplY3QtZml0OmNvbnRhaW4iPjxzcGFuIHN0eWxlPSJkaXNwbGF5Om5vbmU7Zm9udC1zaXplOjEuNHJlbTt3aWR0aDo1NnB4O2hlaWdodDo1NnB4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWluZm8iPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLW5hbWUgYWlzIj5BSVMtUExBWTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCA4MDgwIMK3IFdTIMK3IDEzLjIyNi4xMTUuNTY8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzZWwtY2FyZCIgb25jbGljaz0ib3BlbkZvcm0oJ3RydWUnKSI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUiPjxzcGFuIHN0eWxlPSJmb250LXNpemU6MS4xcmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1uYW1lIHRydWUiPlRSVUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLXN1YiI+VkxFU1MgwrcgUG9ydCAyMDk2IMK3IFdTIMK3IHpvb212ZG9jb25uZWN0LmNsb3VkemVyb3Zwcy5vbmxpbmU8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgoKICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIiBzdHlsZT0ibWFyZ2luLXRvcDoyMHB4Ij7wn5SRIOC4o+C4sOC4muC4miBTU0ggV0VCU09DS0VUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlbC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgnc3NoJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC1zc2giPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZSI+U1NIJmd0Ozwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBzc2giPlNTSCDigJMgV1MgVHVubmVsPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5TU0ggwrcgUG9ydCA4MCDCtyBEcm9wYmVhciAxNDMvMTA5PGJyPk5wdlR1bm5lbCAvIERhcmtUdW5uZWw8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSDilIDilIAgRk9STTogQUlTIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tYWlzIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0iZm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciBhaXMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tbG9nbyBzZWwtYWlzLXNtIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOi44cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojM2Q3YTBlIj5BSVM8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXRpdGxlIGFpcyI+QUlTLVBMQVk8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODA4MCDCtyBBZGRyZXNzOiAxMy4yMjYuMTE1LjU2PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQGFpcyI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfjJAgU05JIC8gSG9zdCAo4LmA4Lin4LmJ4LiZ4Lin4LmI4Liy4LiHID0g4LmD4LiK4LmJ4LmC4LiU4LmA4Lih4LiZ4LmB4LiX4LiZKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtc25pIiBwbGFjZWhvbGRlcj0i4LmA4LiK4LmI4LiZIOC4iOC4suC4geC4hOC4o+C4suC4p+C4n+C5ieC4reC4mSDigJQg4LmA4Lin4LmJ4LiZ4Lin4LmI4Liy4LiH4LmE4LiU4LmJIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+ThSDguKfguLHguJnguYPguIrguYnguIfguLLguJkgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtaXAiIHR5cGU9Im51bWJlciIgdmFsdWU9IjIiIG1pbj0iMSI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkr4gRGF0YSBHQiAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4gY2J0bi1haXMiIGlkPSJhaXMtYnRuIiBvbmNsaWNrPSJjcmVhdGVWTEVTUygnYWlzJykiPuKaoSDguKrguKPguYnguLLguIcgQUlTIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImFpcy1hbGVydCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icmVzLWJveCIgaWQ9ImFpcy1yZXN1bHQiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0icmVzLWNsb3NlIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLWFpcy1lbWFpbCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfhpQgVVVJRDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgbW9ubyIgaWQ9InItYWlzLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLWFpcy1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLWFpcy1saW5rIj4tLTwvZGl2PgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY29weS1idG4iIG9uY2xpY2s9ImNvcHlMaW5rKCdyLWFpcy1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9ImFpcy1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFRSVUUg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS10cnVlIiBzdHlsZT0iZGlzcGxheTpub25lIj4KICAgICAgPGRpdiBjbGFzcz0iZm9ybS1iYWNrIiBvbmNsaWNrPSJjbG9zZUZvcm0oKSI+4oC5IOC4geC4peC4seC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLWhkciB0cnVlLWhkciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbG9nbyBzZWwtdHJ1ZS1zbSI+PHNwYW4gc3R5bGU9ImZvbnQtc2l6ZTouNzVyZW07Zm9udC13ZWlnaHQ6OTAwO2NvbG9yOiNmZmYiPnRydWU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXRpdGxlIHRydWUiPlRSVUUg4oCTIFZETzwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXN1YiI+VkxFU1MgwrcgUG9ydCAyMDk2IMK3IEFkZHJlc3M6IHpvb212ZG9jb25uZWN0LmNsb3VkemVyb3Zwcy5vbmxpbmU8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIEVNQUlMIC8g4LiK4Li34LmI4Lit4Lii4Li54LiqPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQHRydWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5OFIOC4p+C4seC4meC5g+C4iuC5ieC4h+C4suC4mSAoMCA9IOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+TsSBJUCBMSU1JVDwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biBjYnRuLXRydWUiIGlkPSJ0cnVlLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ3RydWUnKSI+4pqhIOC4quC4o+C5ieC4suC4hyBUUlVFIEFjY291bnQ8L2J1dHRvbj4KICAgICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9InRydWUtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJ0cnVlLXJlc3VsdCI+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJyZXMtY2xvc2UiIG9uY2xpY2s9ImRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0cnVlLXJlc3VsdCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnIj7inJU8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+TpyBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYiIGlkPSJyLXRydWUtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLXRydWUtdXVpZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBncmVlbiIgaWQ9InItdHJ1ZS1leHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLWxpbmsiIGlkPSJyLXRydWUtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci10cnVlLWxpbmsnLHRoaXMpIj7wn5OLIENvcHkgVkxFU1MgTGluazwvYnV0dG9uPgogICAgICAgICAgPGRpdiBpZD0idHJ1ZS1xciIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO21hcmdpbi10b3A6MTJweDsiPjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0g4pSA4pSAIEZPUk06IFNTSCDilIDilIAgLS0+CiAgICA8ZGl2IGlkPSJmb3JtLXNzaCIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3NoLWRhcmstZm9ybSI+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPuKelSDguYDguJ7guLTguYjguKEgU1NIIFVTRVI8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiK4Li34LmI4Lit4Lic4Li54LmJ4LmD4LiK4LmJPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC11c2VyIiBwbGFjZWhvbGRlcj0idXNlcm5hbWUiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgdHlwZT0icGFzc3dvcmQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guKXguLTguKHguLTguJXguYTguK3guJ7guLU8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ic3NoLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij7inIjvuI8g4LmA4Lil4Li34Lit4LiBIFBPUlQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwb3J0LWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4gYWN0aXZlLXA4MCIgaWQ9InBiLTgwIiBvbmNsaWNrPSJwaWNrUG9ydCgnODAnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCfjJA8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA4MDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwYi1zdWIiPldTIMK3IEhUVFA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icG9ydC1idG4iIGlkPSJwYi00NDMiIG9uY2xpY2s9InBpY2tQb3J0KCc0NDMnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBiLWljb24iPvCflJI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItbmFtZSI+UG9ydCA0NDM8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGItc3ViIj5XU1MgwrcgU1NMPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KCiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1sYmwiPvCfjJAg4LmA4Lil4Li34Lit4LiBIElTUCAvIE9QRVJBVE9SPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtZHRhYyIgaWQ9InByby1kdGFjIiBvbmNsaWNrPSJwaWNrUHJvKCdkdGFjJykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+8J+foDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RFRBQyBHQU1JTkc8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJwcm8tdHJ1ZSIgb25jbGljaz0icGlja1BybygndHJ1ZScpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCflLU8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPlRSVUUgVFdJVFRFUjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+aGVscC54LmNvbTwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn5OxIOC5gOC4peC4t+C4reC4gSBBUFA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLWdyaWQiPgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQgYS1ucHYiIGlkPSJhcHAtbnB2IiBvbmNsaWNrPSJwaWNrQXBwKCducHYnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMwZDJhM2E7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6bW9ub3NwYWNlO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6Ljg1cmVtO2NvbG9yOiMwMGNjZmY7bGV0dGVyLXNwYWNpbmc6LTFweDtib3JkZXI6MS41cHggc29saWQgcmdiYSgwLDIwNCwyNTUsLjMpIj5uVjwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+TnB2IFR1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+bnB2dC1zc2g6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icGljay1vcHQiIGlkPSJhcHAtZGFyayIgb25jbGljaz0icGlja0FwcCgnZGFyaycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPjxkaXYgc3R5bGU9IndpZHRoOjM4cHg7aGVpZ2h0OjM4cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JhY2tncm91bmQ6IzExMTtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7bWFyZ2luOjAgYXV0byAuMXJlbTtmb250LWZhbWlseTpzYW5zLXNlcmlmO2ZvbnQtd2VpZ2h0OjkwMDtmb250LXNpemU6LjYycmVtO2NvbG9yOiNmZmY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3JkZXI6MS41cHggc29saWQgIzQ0NCI+REFSSzwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwbiI+RGFya1R1bm5lbDwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwcyI+ZGFya3R1bm5lbDovLzwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4tc3NoIiBpZD0ic3NoLWJ0biIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKelSDguKrguKPguYnguLLguIcgVXNlcjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsaW5rLXJlc3VsdCIgaWQ9InNzaC1saW5rLXJlc3VsdCI+PC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBVc2VyIHRhYmxlIC0tPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIiBzdHlsZT0ibWFyZ2luOjAiPvCfk4sg4Lij4Liy4Lii4LiK4Li34LmI4LitIFVTRVJTPC9kaXY+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJzc2gtc2VhcmNoIiBwbGFjZWhvbGRlcj0i4LiE4LmJ4LiZ4Lir4LiyLi4uIiBvbmlucHV0PSJmaWx0ZXJTU0hVc2Vycyh0aGlzLnZhbHVlKSIKICAgICAgICAgICAgc3R5bGU9IndpZHRoOjEyMHB4O21hcmdpbjowO2ZvbnQtc2l6ZToxMXB4O3BhZGRpbmc6NnB4IDEwcHgiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InV0Ymwtd3JhcCI+CiAgICAgICAgICA8dGFibGUgY2xhc3M9InV0YmwiPgogICAgICAgICAgICA8dGhlYWQ+PHRyPjx0aD4jPC90aD48dGg+VVNFUk5BTUU8L3RoPjx0aD7guKvguKHguJTguK3guLLguKLguLg8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BQ1RJT048L3RoPjwvdHI+PC90aGVhZD4KICAgICAgICAgICAgPHRib2R5IGlkPSJzc2gtdXNlci10Ym9keSI+PHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9yOnZhcigtLW11dGVkKSI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwvdGJvZHk+CiAgICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICA8L2Rpdj48IS0tIC90YWItY3JlYXRlIC0tPgoKPCEtLSDilZDilZDilZDilZAgTUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJ1c2VyLXNlYXJjaCIgcGxhY2Vob2xkZXI9IvCflI0gIOC4hOC5ieC4meC4q+C4siB1c2VybmFtZS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgICA8ZGl2IGlkPSJ1c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4m+C4uOC5iOC4oeC5guC4q+C4peC4lOC5gOC4nuC4t+C5iOC4reC4lOC4tuC4h+C4guC5ieC4reC4oeC4ueC4pTwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkT25saW5lKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9jciI+CiAgICAgICAgPGRpdiBjbGFzcz0ib3BpbGwiIGlkPSJvbmxpbmUtcGlsbCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJvbmxpbmUtY291bnQiPjA8L3NwYW4+IOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJ1dCIgaWQ9Im9ubGluZS10aW1lIj4tLTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguKPguLXguYDguJ/guKPguIrguYDguJ7guLfguYjguK3guJTguLnguJzguLnguYnguYPguIrguYnguK3guK3guJnguYTguKXguJnguYw8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBCQU4g4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1iYW4iPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+aqyDguIjguLHguJTguIHguLLguKMgU1NIIFVzZXJzPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5GkIFVTRVJOQU1FPC9kaXY+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImJhbi11c2VyIiBwbGFjZWhvbGRlcj0i4LmD4Liq4LmIIHVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4peC4miI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE1ODAzZCwjMjJjNTVlKSIgb25jbGljaz0iZGVsZXRlU1NIKCkiPvCfl5HvuI8g4Lil4LiaIFNTSCBVc2VyPC9idXR0b24+CiAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0iYmFuLWFsZXJ0Ij48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCIgc3R5bGU9Im1hcmdpbi10b3A6NHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIj7wn5OLIFNTSCBVc2VycyDguJfguLHguYnguIfguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBpZD0ic3NoLXVzZXItbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KCgogIDwhLS0gU1BFRUQgVEVTVCBUQUIgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLXNwZWVkIj4KICAgIDxkaXYgY2xhc3M9InNwZWVkLWhlcm8iPgogICAgICA8ZGl2IGNsYXNzPSJzcGVlZC10aXRsZSI+4pqhIFZQUyBTUEVFRCBURVNUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXByb2ciPjxkaXYgY2xhc3M9InNwZWVkLXByb2ctZmlsbCIgaWQ9InNwZWVkLXByb2ctZmlsbCI+PC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXN0YXR1cyIgaWQ9InNwZWVkLXN0YXR1cyI+4LiB4LiU4Lib4Li44LmI4Lih4LmA4Lie4Li34LmI4Lit4LmA4Lij4Li04LmI4Lih4LiX4LiU4Liq4Lit4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNwZWVkLWdhdWdlLXdyYXAiPgogICAgICAgIDxzdmcgY2xhc3M9InNwZWVkLWdhdWdlLXN2ZyIgdmlld0JveD0iMCAwIDE2MCA5MCIgd2lkdGg9IjE2MCIgaGVpZ2h0PSI5MCI+CiAgICAgICAgICA8cGF0aCBkPSJNMTAsODAgQTcwLDcwIDAgMCwxIDE1MCw4MCIgY2xhc3M9InNwZWVkLWdhdWdlLWJnIi8+CiAgICAgICAgICA8cGF0aCBpZD0iZ2F1Z2UtZmlsbCIgZD0iTTEwLDgwIEE3MCw3MCAwIDAsMSAxNTAsODAiIGNsYXNzPSJzcGVlZC1nYXVnZS1maWxsIgogICAgICAgICAgICBzdHJva2U9IiMwNmI2ZDQiIHN0cm9rZS1kYXNoYXJyYXk9IjIyMCIgc3Ryb2tlLWRhc2hvZmZzZXQ9IjIyMCIvPgogICAgICAgIDwvc3ZnPgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLWNlbnRlciI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC12YWwiIGlkPSJnYXVnZS12YWwiPi0tPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC11bml0IiBpZD0iZ2F1Z2UtdW5pdCI+TWJwczwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcGluZy1yb3ciPgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXBpbmctaXRlbSI+PGRpdiBjbGFzcz0ic3BlZWQtcGluZy1sYWJlbCI+UElORzwvZGl2PjxkaXYgY2xhc3M9InNwZWVkLXBpbmctdmFsIiBpZD0icGluZy12YWwiPi0tIG1zPC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcGluZy1pdGVtIj48ZGl2IGNsYXNzPSJzcGVlZC1waW5nLWxhYmVsIj5KSVRURVI8L2Rpdj48ZGl2IGNsYXNzPSJzcGVlZC1waW5nLXZhbCIgaWQ9ImppdHRlci12YWwiPi0tIG1zPC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcGluZy1pdGVtIj48ZGl2IGNsYXNzPSJzcGVlZC1waW5nLWxhYmVsIj5QQUNLRVQgTE9TUzwvZGl2PjxkaXYgY2xhc3M9InNwZWVkLXBpbmctdmFsIiBpZD0ibG9zcy12YWwiPi0tJTwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzdWx0cyI+CiAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlcy1jYXJkIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1yZXMtaWNvbiI+4qyH77iPPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzLWxhYmVsIj5ET1dOTE9BRDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlcy12YWwgZGwtY29sb3IiIGlkPSJkbC12YWwiPi0tPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzLXVuaXQiPk1icHM8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1iYXItd3JhcCI+PGRpdiBjbGFzcz0ic3BlZWQtYmFyIGRsLWJhciIgaWQ9ImRsLWJhciI+PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1yZXMtY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzLWljb24iPuKshu+4jzwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLXJlcy1sYWJlbCI+VVBMT0FEPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtcmVzLXZhbCB1bC1jb2xvciIgaWQ9InVsLXZhbCI+LS08L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1yZXMtdW5pdCI+TWJwczwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLWJhci13cmFwIj48ZGl2IGNsYXNzPSJzcGVlZC1iYXIgdWwtYmFyIiBpZD0idWwtYmFyIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9InNwZWVkLWJ0bnMiPgogICAgICA8YnV0dG9uIGNsYXNzPSJzcGVlZC1idG4gc3BlZWQtYnRuLWRsIiBpZD0iYnRuLWRsIiBvbmNsaWNrPSJzdGFydFNwZWVkVGVzdCgnZG93bmxvYWQnKSI+4qyH77iPIFRFU1QgRE9XTkxPQUQ8L2J1dHRvbj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ic3BlZWQtYnRuIHNwZWVkLWJ0bi11bCIgaWQ9ImJ0bi11bCIgb25jbGljaz0ic3RhcnRTcGVlZFRlc3QoJ3VwbG9hZCcpIj7irIbvuI8gVEVTVCBVUExPQUQ8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InNlYy10aXRsZSIgc3R5bGU9Im1hcmdpbi1ib3R0b206MTJweCI+8J+ToSBWUFMgSU5GTzwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzcGVlZC1pbmZvLWdyaWQiPgogICAgICAgIDxkaXYgY2xhc3M9InNwZWVkLWluZm8taXRlbSI+PGRpdiBjbGFzcz0ic3BlZWQtaW5mby1sYmwiPlNFUlZFUiBJUDwvZGl2PjxkaXYgY2xhc3M9InNwZWVkLWluZm8tdmFsIiBpZD0idnBzLWlwIiBzdHlsZT0iZm9udC1zaXplOjEwcHgiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtaW5mby1pdGVtIj48ZGl2IGNsYXNzPSJzcGVlZC1pbmZvLWxibCI+VEVTVCBTSVpFPC9kaXY+PGRpdiBjbGFzcz0ic3BlZWQtaW5mby12YWwiIGlkPSJ0ZXN0LXNpemUiPjI1IE1CPC9kaXY+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3BlZWQtaW5mby1pdGVtIj48ZGl2IGNsYXNzPSJzcGVlZC1pbmZvLWxibCI+UFJPVE9DT0w8L2Rpdj48ZGl2IGNsYXNzPSJzcGVlZC1pbmZvLXZhbCI+SFRUUDwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKPC9kaXY+PCEtLSAvd3JhcCAtLT4KCjwhLS0gTU9EQUwgLS0+CjxkaXYgY2xhc3M9Im1vdmVyIiBpZD0ibW9kYWwiIG9uY2xpY2s9ImlmKGV2ZW50LnRhcmdldD09PXRoaXMpY20oKSI+CiAgPGRpdiBjbGFzcz0ibW9kYWwiPgogICAgPGRpdiBjbGFzcz0ibWhkciI+CiAgICAgIDxkaXYgY2xhc3M9Im10aXRsZSIgaWQ9Im10Ij7impnvuI8gdXNlcjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJtY2xvc2UiIG9uY2xpY2s9ImNtKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJkZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfkaQgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZHUiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OhIFBvcnQ8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZHAiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYgZ3JlZW4iIGlkPSJkZSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6YgRGF0YSBMaW1pdDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkZCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk4ogVHJhZmZpYyDguYPguIrguYk8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IiBpZD0iZHRyIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TsSBJUCBMaW1pdDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkaSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfhpQgVVVJRDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYgbW9ubyIgaWQ9ImR1dSI+LS08L3NwYW4+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEwcHgiPuC5gOC4peC4t+C4reC4geC4geC4suC4o+C4lOC4s+C5gOC4meC4tOC4meC4geC4suC4ozwvZGl2PgogICAgPGRpdiBjbGFzcz0iYWdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdyZW5ldycpIj48ZGl2IGNsYXNzPSJhaSI+8J+UhDwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguYjguK3guK3guLLguKLguLg8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ2V4dGVuZCcpIj48ZGl2IGNsYXNzPSJhaSI+8J+ThTwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guYDguJ7guLTguYjguKHguKfguLHguJk8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ2FkZGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPvCfk6Y8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LmA4Lie4Li04LmI4LihIERhdGE8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiV4Li04LihIEdCIOC5gOC4nuC4tOC5iOC4oTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIiBvbmNsaWNrPSJtQWN0aW9uKCdzZXRkYXRhJykiPjxkaXYgY2xhc3M9ImFpIj7impbvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4LiV4Lix4LmJ4LiHIERhdGE8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LiB4Liz4Lir4LiZ4LiU4LmD4Lir4Lih4LmIPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3Jlc2V0JykiPjxkaXYgY2xhc3M9ImFpIj7wn5SDPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4o+C4teC5gOC4i+C4lSBUcmFmZmljPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5iTwvZGl2PjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJhYnRuIGRhbmdlciIgb25jbGljaz0ibUFjdGlvbignZGVsZXRlJykiPjxkaXYgY2xhc3M9ImFpIj7wn5eR77iPPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4peC4muC4ouC4ueC4qjwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKXguJrguJbguLLguKfguKM8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguJXguYjguK3guK3guLLguKLguLggLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItcmVuZXciPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+UhCDguJXguYjguK3guK3guLLguKLguLgg4oCUIOC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tcmVuZXctZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLXJlbmV3LWJ0biIgb25jbGljaz0iZG9SZW5ld1VzZXIoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4reC4reC4suC4ouC4uDwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1leHRlbmQiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+ThSDguYDguJ7guLTguYjguKHguKfguLHguJkg4oCUIOC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZ4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tZXh0ZW5kLWRheXMiIHR5cGU9Im51bWJlciIgdmFsdWU9IjMwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1leHRlbmQtYnRuIiBvbmNsaWNrPSJkb0V4dGVuZFVzZXIoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC5gOC4nuC4tOC5iOC4oSBEYXRhIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWFkZGRhdGEiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+8J+TpiDguYDguJ7guLTguYjguKEgRGF0YSDigJQg4LmA4LiV4Li04LihIEdCIOC5gOC4nuC4tOC5iOC4oeC4iOC4suC4geC4l+C4teC5iOC4oeC4teC4reC4ouC4ueC5iDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZIEdCIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJtLWFkZGRhdGEtZ2IiIHR5cGU9Im51bWJlciIgdmFsdWU9IjEwIiBtaW49IjEiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1hZGRkYXRhLWJ0biIgb25jbGljaz0iZG9BZGREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguYDguJ7guLTguYjguKEgRGF0YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC4seC5ieC4hyBEYXRhIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXNldGRhdGEiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCI+4pqW77iPIOC4leC4seC5ieC4hyBEYXRhIOKAlCDguIHguLPguKvguJnguJQgTGltaXQg4LmD4Lir4Lih4LmIICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+RGF0YSBMaW1pdCAoR0IpIOKAlCAwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tc2V0ZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tc2V0ZGF0YS1idG4iIG9uY2xpY2s9ImRvU2V0RGF0YSgpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4Lix4LmJ4LiHIERhdGE8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguKPguLXguYDguIvguJUgVHJhZmZpYyAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZXNldCI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SDIOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIOKAlCDguYDguITguKXguLXguKLguKPguYzguKLguK3guJTguYPguIrguYnguJfguLHguYnguIfguKvguKHguJQ8L2Rpdj4KICAgICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTJweCI+4LiB4Liy4Lij4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4LiI4Liw4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiUIFVwbG9hZC9Eb3dubG9hZCDguJfguLHguYnguIfguKvguKHguJTguILguK3guIfguKLguLnguKrguJnguLXguYk8L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVzZXQtYnRuIiBvbmNsaWNrPSJkb1Jlc2V0VHJhZmZpYygpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2J1dHRvbj4KICAgIDwvZGl2PgoKICAgIDwhLS0gU1VCLVBBTkVMOiDguKXguJrguKLguLnguKogLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItZGVsZXRlIj4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij7wn5eR77iPIOC4peC4muC4ouC4ueC4qiDigJQg4Lil4Lia4LiW4Liy4Lin4LijIOC5hOC4oeC5iOC4quC4suC4oeC4suC4o+C4luC4geC4ueC5ieC4hOC4t+C4meC5hOC4lOC5iTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guKLguLnguKogPGIgaWQ9Im0tZGVsLW5hbWUiIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij48L2I+IOC4iOC4sOC4luC4ueC4geC4peC4muC4reC4reC4geC4iOC4suC4geC4o+C4sOC4muC4muC4luC4suC4p+C4ozwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1kZWxldGUtYnRuIiBvbmNsaWNrPSJkb0RlbGV0ZVVzZXIoKSIgc3R5bGU9ImJhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjZGMyNjI2LCNlZjQ0NDQpIj7wn5eR77iPIOC4ouC4t+C4meC4ouC4seC4meC4peC4muC4ouC4ueC4qjwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJtb2RhbC1hbGVydCIgc3R5bGU9Im1hcmdpbi10b3A6MTBweCI+PC9kaXY+CiAgPC9kaXY+CjwvZGl2PgoKPHNjcmlwdCBzcmM9ImNvbmZpZy5qcyIgb25lcnJvcj0id2luZG93LkNIQUlZQV9DT05GSUc9e30iPjwvc2NyaXB0Pgo8c2NyaXB0PgovLyDilZDilZDilZDilZAgQ09ORklHIOKVkOKVkOKVkOKVkApjb25zdCBDRkcgPSAodHlwZW9mIHdpbmRvdy5DSEFJWUFfQ09ORklHICE9PSAndW5kZWZpbmVkJykgPyB3aW5kb3cuQ0hBSVlBX0NPTkZJRyA6IHt9Owpjb25zdCBIT1NUID0gQ0ZHLmhvc3QgfHwgbG9jYXRpb24uaG9zdG5hbWU7CmNvbnN0IFhVSSAgPSAnL3h1aS1hcGknOyAgICAgICAgICAvLyB4LXVpIEFQSSDguYLguJTguKLguJXguKPguIcg4LmE4Lih4LmI4Lic4LmI4Liy4LiZIG1pZGRsZXdhcmUKY29uc3QgQVBJICA9ICcvYXBpJzsgICAgICAgICAgICAgICAvLyBjaGFpeWEtc3NoLWFwaSAoU1NIIHVzZXJzIOC5gOC4l+C5iOC4suC4meC4seC5ieC4mSkKY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwoKLy8g4pSA4pSAIERpcmVjdCB4LXVpIEFQSSBoZWxwZXJzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsZXQgX3h1aUNvb2tpZSA9IGZhbHNlOwphc3luYyBmdW5jdGlvbiB4dWlFbnN1cmVMb2dpbigpIHsKICBpZiAoX3h1aUNvb2tpZSkgcmV0dXJuIHRydWU7CiAgY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwogIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IF9zLnVzZXJ8fENGRy54dWlfdXNlcnx8JycsIHBhc3N3b3JkOiBfcy5wYXNzfHxDRkcueHVpX3Bhc3N8fCcnIH0pOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrJy9sb2dpbicsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQnfSwKICAgIGJvZHk6IGZvcm0udG9TdHJpbmcoKQogIH0pOwogIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICBfeHVpQ29va2llID0gISFkLnN1Y2Nlc3M7CiAgcmV0dXJuIF94dWlDb29raWU7Cn0KYXN5bmMgZnVuY3Rpb24geHVpR2V0KHBhdGgpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgY29uc3QgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7CiAgcmV0dXJuIHIuanNvbigpOwp9CmFzeW5jIGZ1bmN0aW9uIHh1aVBvc3QocGF0aCwgYm9keSkgewogIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICBjb25zdCByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICBib2R5OiBKU09OLnN0cmluZ2lmeShib2R5KQogIH0pOwogIHJldHVybiByLmpzb24oKTsKfQoKLy8gU2Vzc2lvbiBjaGVjawpjb25zdCBfcyA9ICgoKSA9PiB7IHRyeSB7IHJldHVybiBKU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oU0VTU0lPTl9LRVkpfHwne30nKTsgfSBjYXRjaChlKXtyZXR1cm57fTt9IH0pKCk7CmlmICghX3MudXNlciB8fCAhX3MucGFzcyB8fCBEYXRlLm5vdygpID49IChfcy5leHB8fDApKSB7CiAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShTRVNTSU9OX0tFWSk7CiAgbG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOwp9CgovLyBIZWFkZXIgZG9tYWluCmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoZHItZG9tYWluJykudGV4dENvbnRlbnQgPSBIT1NUICsgJyDCtyB2NSc7CgovLyDilZDilZDilZDilZAgVVRJTFMg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGZtdEJ5dGVzKGIpIHsKICBpZiAoIWIgfHwgYiA9PT0gMCkgcmV0dXJuICcwIEInOwogIGNvbnN0IGsgPSAxMDI0LCB1ID0gWydCJywnS0InLCdNQicsJ0dCJywnVEInXTsKICBjb25zdCBpID0gTWF0aC5mbG9vcihNYXRoLmxvZyhiKS9NYXRoLmxvZyhrKSk7CiAgcmV0dXJuIChiL01hdGgucG93KGssaSkpLnRvRml4ZWQoMSkrJyAnK3VbaV07Cn0KZnVuY3Rpb24gZm10RGF0ZShtcykgewogIGlmICghbXMgfHwgbXMgPT09IDApIHJldHVybiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBjb25zdCBkID0gbmV3IERhdGUobXMpOwogIHJldHVybiBkLnRvTG9jYWxlRGF0ZVN0cmluZygndGgtVEgnLHt5ZWFyOidudW1lcmljJyxtb250aDonc2hvcnQnLGRheTonbnVtZXJpYyd9KTsKfQpmdW5jdGlvbiBkYXlzTGVmdChtcykgewogIGlmICghbXMgfHwgbXMgPT09IDApIHJldHVybiBudWxsOwogIHJldHVybiBNYXRoLmNlaWwoKG1zIC0gRGF0ZS5ub3coKSkgLyA4NjQwMDAwMCk7Cn0KZnVuY3Rpb24gc2V0UmluZyhpZCwgcGN0KSB7CiAgY29uc3QgY2lyYyA9IDEzOC4yOwogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmIChlbCkgZWwuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IGNpcmMgLSAoY2lyYyAqIE1hdGgubWluKHBjdCwxMDApIC8gMTAwKTsKfQpmdW5jdGlvbiBzZXRCYXIoaWQsIHBjdCwgd2Fybj1mYWxzZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghZWwpIHJldHVybjsKICBlbC5zdHlsZS53aWR0aCA9IE1hdGgubWluKHBjdCwxMDApICsgJyUnOwogIGlmICh3YXJuICYmIHBjdCA+IDg1KSBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZWY0NDQ0LCNkYzI2MjYpJzsKICBlbHNlIGlmICh3YXJuICYmIHBjdCA+IDY1KSBlbC5zdHlsZS5iYWNrZ3JvdW5kID0gJ2xpbmVhci1ncmFkaWVudCg5MGRlZywjZjk3MzE2LCNmYjkyM2MpJzsKfQpmdW5jdGlvbiBzaG93QWxlcnQoaWQsIG1zZywgdHlwZSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghZWwpIHJldHVybjsKICBlbC5jbGFzc05hbWUgPSAnYWxlcnQgJyt0eXBlOwogIGVsLnRleHRDb250ZW50ID0gbXNnOwogIGVsLnN0eWxlLmRpc3BsYXkgPSAnYmxvY2snOwogIGlmICh0eXBlID09PSAnb2snKSBzZXRUaW1lb3V0KCgpPT57ZWwuc3R5bGUuZGlzcGxheT0nbm9uZSc7fSwgMzAwMCk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBOQVYg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIHN3KG5hbWUsIGVsKSB7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLnNlYycpLmZvckVhY2gocz0+cy5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLm5hdi1pdGVtJykuZm9yRWFjaChuPT5uLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndGFiLScrbmFtZSkuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgZWwuY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7CiAgaWYgKG5hbWU9PT0nY3JlYXRlJykgY2xvc2VGb3JtKCk7CiAgaWYgKG5hbWU9PT0nZGFzaGJvYXJkJykgbG9hZERhc2goKTsKICBpZiAobmFtZT09PSdtYW5hZ2UnKSBsb2FkVXNlcnMoKTsKICBpZiAobmFtZT09PSdvbmxpbmUnKSBsb2FkT25saW5lKCk7CiAgaWYgKG5hbWU9PT0nYmFuJykgbG9hZFNTSFVzZXJzKCk7CiAgaWYgKG5hbWU9PT0nc3BlZWQnKSB7IHNldEdhdWdlKDApOyB9Cn0KCi8vIOKUgOKUgCBGb3JtIG5hdiDilIDilIAKbGV0IF9jdXJGb3JtID0gbnVsbDsKZnVuY3Rpb24gb3BlbkZvcm0oaWQpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3JlYXRlLW1lbnUnKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIFsnYWlzJywndHJ1ZScsJ3NzaCddLmZvckVhY2goZiA9PiB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9ybS0nK2YpLnN0eWxlLmRpc3BsYXkgPSBmPT09aWQgPyAnYmxvY2snIDogJ25vbmUnOwogIH0pOwogIF9jdXJGb3JtID0gaWQ7CiAgaWYgKGlkPT09J3NzaCcpIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIHdpbmRvdy5zY3JvbGxUbygwLDApOwp9CmZ1bmN0aW9uIGNsb3NlRm9ybSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3JlYXRlLW1lbnUnKS5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBbJ2FpcycsJ3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIH0pOwogIF9jdXJGb3JtID0gbnVsbDsKfQoKbGV0IF93c1BvcnQgPSAnODAnOwpmdW5jdGlvbiB0b2dQb3J0KGJ0biwgcG9ydCkgewogIF93c1BvcnQgPSBwb3J0OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd3czgwLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9PT0nODAnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M0NDMtYnRuJykuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgcG9ydD09PSc0NDMnKTsKfQpmdW5jdGlvbiB0b2dHcm91cChidG4sIGNscykgewogIGJ0bi5jbG9zZXN0KCdkaXYnKS5xdWVyeVNlbGVjdG9yQWxsKGNscykuZm9yRWFjaChiPT5iLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBidG4uY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7Cn0KCi8vICh4dWlHZXQveHVpUG9zdCBkZWZpbmVkIGFib3ZlKQoKLy8g4pWQ4pWQ4pWQ4pWQIERBU0hCT0FSRCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZERhc2goKSB7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1yZWZyZXNoJyk7CiAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyAuLi4nOwogIF94dWlDb29raWUgPSBmYWxzZTsgLy8gZm9yY2UgcmUtbG9naW4g4LmA4Liq4Lih4LitCgogIHRyeSB7CiAgICAvLyDilZDilZAgMSkg4LiU4Li24LiHIFNlcnZlciBTdGF0dXMg4LiI4Liy4LiBIDN4LXVpIOC5guC4lOC4ouC4leC4o+C4hyDilZDilZAKICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICBjb25zdCBzdiA9IGF3YWl0IGZldGNoKFhVSSsnL3BhbmVsL2FwaS9zZXJ2ZXIvc3RhdHVzJywgewogICAgICBjcmVkZW50aWFsczogJ2luY2x1ZGUnCiAgICB9KS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+bnVsbCk7CgogICAgaWYgKHN2ICYmIHN2LnN1Y2Nlc3MgJiYgc3Yub2JqKSB7CiAgICAgIGNvbnN0IG8gPSBzdi5vYmo7CgogICAgICAvLyBDUFUKICAgICAgY29uc3QgY3B1ID0gTWF0aC5yb3VuZChvLmNwdSB8fCAwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1wY3QnKS50ZXh0Q29udGVudCA9IGNwdSArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1jb3JlcycpLnRleHRDb250ZW50ID0gKG8uY3B1Q29yZXMgfHwgby5sb2dpY2FsUHJvIHx8ICctLScpICsgJyBjb3Jlcyc7CiAgICAgIHNldFJpbmcoJ2NwdS1yaW5nJywgY3B1KTsgc2V0QmFyKCdjcHUtYmFyJywgY3B1LCB0cnVlKTsKCiAgICAgIC8vIFJBTQogICAgICBjb25zdCByYW1UID0gKChvLm1lbT8udG90YWx8fDApLzEwNzM3NDE4MjQpLCByYW1VID0gKChvLm1lbT8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IHJhbVAgPSByYW1UID4gMCA/IE1hdGgucm91bmQocmFtVS9yYW1UKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLXBjdCcpLnRleHRDb250ZW50ID0gcmFtUCArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1kZXRhaWwnKS50ZXh0Q29udGVudCA9IHJhbVUudG9GaXhlZCgxKSsnIC8gJytyYW1ULnRvRml4ZWQoMSkrJyBHQic7CiAgICAgIHNldFJpbmcoJ3JhbS1yaW5nJywgcmFtUCk7IHNldEJhcigncmFtLWJhcicsIHJhbVAsIHRydWUpOwoKICAgICAgLy8gRGlzawogICAgICBjb25zdCBkc2tUID0gKChvLmRpc2s/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgZHNrVSA9ICgoby5kaXNrPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgZHNrUCA9IGRza1QgPiAwID8gTWF0aC5yb3VuZChkc2tVL2Rza1QqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLXBjdCcpLmlubmVySFRNTCA9IGRza1AgKyAnPHNwYW4+JTwvc3Bhbj4nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1kZXRhaWwnKS50ZXh0Q29udGVudCA9IGRza1UudG9GaXhlZCgwKSsnIC8gJytkc2tULnRvRml4ZWQoMCkrJyBHQic7CiAgICAgIHNldEJhcignZGlzay1iYXInLCBkc2tQLCB0cnVlKTsKCiAgICAgIC8vIFVwdGltZQogICAgICBjb25zdCB1cCA9IG8udXB0aW1lIHx8IDA7CiAgICAgIGNvbnN0IHVkID0gTWF0aC5mbG9vcih1cC84NjQwMCksIHVoID0gTWF0aC5mbG9vcigodXAlODY0MDApLzM2MDApLCB1bSA9IE1hdGguZmxvb3IoKHVwJTM2MDApLzYwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS12YWwnKS50ZXh0Q29udGVudCA9IHVkID4gMCA/IHVkKydkICcrdWgrJ2gnIDogdWgrJ2ggJyt1bSsnbSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtc3ViJykudGV4dENvbnRlbnQgPSB1ZCsn4Lin4Lix4LiZICcrdWgrJ+C4iuC4oS4gJyt1bSsn4LiZ4Liy4LiX4Li1JzsKICAgICAgY29uc3QgbG9hZHMgPSBvLmxvYWRzIHx8IFtdOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9hZC1jaGlwcycpLmlubmVySFRNTCA9IGxvYWRzLm1hcCgobCxpKT0+CiAgICAgICAgYDxzcGFuIGNsYXNzPSJiZGciPiR7WycxbScsJzVtJywnMTVtJ11baV19OiAke2wudG9GaXhlZCgyKX08L3NwYW4+YCkuam9pbignJyk7CgogICAgICAvLyBOZXR3b3JrIEkvTyAocmVhbHRpbWUgc3BlZWQpCiAgICAgIGlmIChvLm5ldElPKSB7CiAgICAgICAgY29uc3QgdXBfYiA9IG8ubmV0SU8udXB8fDAsIGRuX2IgPSBvLm5ldElPLmRvd258fDA7CiAgICAgICAgY29uc3QgdXBGbXQgPSBmbXRCeXRlcyh1cF9iKSwgZG5GbXQgPSBmbXRCeXRlcyhkbl9iKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwJykuaW5uZXJIVE1MID0gdXBGbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbicpLmlubmVySFRNTCA9IGRuRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICB9CiAgICAgIGlmIChvLm5ldFRyYWZmaWMpIHsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnNlbnR8fDApOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4tdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMucmVjdnx8MCk7CiAgICAgIH0KCiAgICAgIC8vIFhVSSBYcmF5IHZlcnNpb24KICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS12ZXInKS50ZXh0Q29udGVudCA9IG8ueHJheVZlcnNpb24gfHwgJy0tJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJkb3QiPjwvc3Bhbj7guK3guK3guJnguYTguKXguJnguYwnOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwnOwogICAgfSBlbHNlIHsKICAgICAgLy8gM3gtdWkg4LmE4Lih4LmI4LiV4Lit4Lia4Liq4LiZ4Lit4LiHCiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90IHJlZCI+PC9zcGFuPuC4reC4reC4n+C5hOC4peC4meC5jCc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmNsYXNzTmFtZSA9ICdvcGlsbCBvZmYnOwogICAgfQoKICAgIC8vIOKVkOKVkCAyKSDguJTguLbguIcgSW5ib3VuZHMgY291bnQg4LiI4Liy4LiBIDN4LXVpIOKVkOKVkAogICAgY29uc3QgaWJsID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoaWJsICYmIGlibC5zdWNjZXNzKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktaW5ib3VuZHMnKS50ZXh0Q29udGVudCA9IChpYmwub2JqfHxbXSkubGVuZ3RoOwogICAgfQoKICAgIC8vIOKVkOKVkCAzKSDguJTguLbguIcgU2VydmljZSBTdGF0dXMg4LiI4Liy4LiBIFNTSCBBUEkgKOC4quC4s+C4q+C4o+C4seC4miBkcm9wYmVhci9uZ2lueC9iYWR2cG4g4LiX4Li14LmIIDN4LXVpIOC5hOC4oeC5iOC4o+C4ueC5iSkg4pWQ4pWQCiAgICBjb25zdCBzdCA9IGF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChzdCkgewogICAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgICB9CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xhc3QtdXBkYXRlJykudGV4dENvbnRlbnQgPSAn4Lit4Lix4Lie4LmA4LiU4LiX4Lil4LmI4Liy4Liq4Li44LiUOiAnICsgbmV3IERhdGUoKS50b0xvY2FsZVRpbWVTdHJpbmcoJ3RoLVRIJyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zb2xlLmVycm9yKGUpOwogIH0gZmluYWxseSB7CiAgICBpZiAoYnRuKSBidG4udGV4dENvbnRlbnQgPSAn4oa7IOC4o+C4teC5gOC4n+C4o+C4iic7CiAgfQp9CgoKLy8g4pWQ4pWQ4pWQ4pWQIFNFUlZJQ0VTIOKVkOKVkOKVkOKVkApjb25zdCBTVkNfREVGID0gWwogIHsga2V5Oid4dWknLCAgICAgIGljb246J/Cfk6EnLCBuYW1lOid4LXVpIFBhbmVsJywgICAgICBwb3J0Oic6MjA1MycgfSwKICB7IGtleTonc3NoJywgICAgICBpY29uOifwn5CNJywgbmFtZTonU1NIIEFQSScsICAgICAgICAgIHBvcnQ6Jzo2Nzg5JyB9LAogIHsga2V5Oidkcm9wYmVhcicsIGljb246J/CfkLsnLCBuYW1lOidEcm9wYmVhciBTU0gnLCAgICAgcG9ydDonOjE0MyA6MTA5JyB9LAogIHsga2V5OiduZ2lueCcsICAgIGljb246J/CfjJAnLCBuYW1lOiduZ2lueCAvIFBhbmVsJywgICAgcG9ydDonOjgwIDo0NDMnIH0sCiAgeyBrZXk6J3NzaHdzJywgICAgaWNvbjon8J+UkicsIG5hbWU6J1dTLVN0dW5uZWwnLCAgICAgICBwb3J0Oic6ODDihpI6MTQzJyB9LAogIHsga2V5OidiYWR2cG4nLCAgIGljb246J/Cfjq4nLCBuYW1lOidCYWRWUE4gVURQR1cnLCAgICAgcG9ydDonOjczMDAnIH0sCl07CmZ1bmN0aW9uIHJlbmRlclNlcnZpY2VzKG1hcCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtbGlzdCcpLmlubmVySFRNTCA9IFNWQ19ERUYubWFwKHMgPT4gewogICAgY29uc3QgdXAgPSBtYXBbcy5rZXldID09PSB0cnVlIHx8IG1hcFtzLmtleV0gPT09ICdhY3RpdmUnOwogICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJzdmMgJHt1cD8nJzonZG93bid9Ij4KICAgICAgPGRpdiBjbGFzcz0ic3ZjLWwiPjxzcGFuIGNsYXNzPSJkZyAke3VwPycnOidyZWQnfSI+PC9zcGFuPjxzcGFuPiR7cy5pY29ufTwvc3Bhbj4KICAgICAgICA8ZGl2PjxkaXYgY2xhc3M9InN2Yy1uIj4ke3MubmFtZX08L2Rpdj48ZGl2IGNsYXNzPSJzdmMtcCI+JHtzLnBvcnR9PC9kaXY+PC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0icmJkZyAke3VwPycnOidkb3duJ30iPiR7dXA/J1JVTk5JTkcnOidET1dOJ308L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpOwp9CmFzeW5jIGZ1bmN0aW9uIGxvYWRTZXJ2aWNlcygpIHsKICB0cnkgewogICAgY29uc3Qgc3QgPSBhd2FpdCBmZXRjaChBUEkrJy9zdGF0dXMnKS50aGVuKHI9PnIuanNvbigpKTsKICAgIHJlbmRlclNlcnZpY2VzKHN0LnNlcnZpY2VzIHx8IHt9KTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdmMtbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+4LmA4LiK4Li34LmI4Lit4Lih4LiV4LmI4LitIEFQSSDguYTguKHguYjguYTguJTguYk8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBQSUNLRVIgU1RBVEUg4pWQ4pWQ4pWQ4pWQCmNvbnN0IFBST1MgPSB7CiAgZHRhYzogewogICAgbmFtZTogJ0RUQUMgR0FNSU5HJywKICAgIHByb3h5OiAnMTA0LjE4LjYzLjEyNDo4MCcsCiAgICBwYXlsb2FkOiAnQ09OTkVDVCAvICBIVFRQLzEuMSBbY3JsZl1Ib3N0OiBkbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tIFtjcmxmXVtjcmxmXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0Oltob3N0XVtjcmxmXVVwZ3JhZGU6VXNlci1BZ2VudDogW3VhXVtjcmxmXVtjcmxmXScsCiAgICBkYXJrUHJveHk6ICd0cnVldmlwYW5saW5lLmdvZHZwbi5zaG9wJywgZGFya1Byb3h5UG9ydDogODAKICB9LAogIHRydWU6IHsKICAgIG5hbWU6ICdUUlVFIFRXSVRURVInLAogICAgcHJveHk6ICcxMDQuMTguMzkuMjQ6ODAnLAogICAgcGF5bG9hZDogJ1BPU1QgLyBIVFRQLzEuMVtjcmxmXUhvc3Q6aGVscC54LmNvbVtjcmxmXVVzZXItQWdlbnQ6IFt1YV1bY3JsZl1bY3JsZl1bc3BsaXRdW2NyXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OiBbaG9zdF1bY3JsZl1VcGdyYWRlOiB3ZWJzb2NrZXRbY3JsZl1Db25uZWN0aW9uOlVwZ3JhZGVbY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfQp9Owpjb25zdCBOUFZfSE9TVCA9ICd3d3cucHJvamVjdC5nb2R2cG4uc2hvcCcsIE5QVl9QT1JUID0gODA7CmxldCBfc3NoUHJvID0gJ2R0YWMnLCBfc3NoQXBwID0gJ25wdicsIF9zc2hQb3J0ID0gJzgwJzsKCmZ1bmN0aW9uIHBpY2tQb3J0KHApIHsKICBfc3NoUG9ydCA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BiLTgwJykuY2xhc3NOYW1lICA9ICdwb3J0LWJ0bicgKyAocD09PSc4MCcgID8gJyBhY3RpdmUtcDgwJyAgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BiLTQ0MycpLmNsYXNzTmFtZSA9ICdwb3J0LWJ0bicgKyAocD09PSc0NDMnID8gJyBhY3RpdmUtcDQ0MycgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja1BybyhwKSB7CiAgX3NzaFBybyA9IHA7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Byby1kdGFjJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChwPT09J2R0YWMnID8gJyBhLWR0YWMnIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tdHJ1ZScpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSd0cnVlJyA/ICcgYS10cnVlJyA6ICcnKTsKfQpmdW5jdGlvbiBwaWNrQXBwKGEpIHsKICBfc3NoQXBwID0gYTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYXBwLW5wdicpLmNsYXNzTmFtZSAgPSAncGljay1vcHQnICsgKGE9PT0nbnB2JyAgPyAnIGEtbnB2JyAgOiAnJyk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2FwcC1kYXJrJykuY2xhc3NOYW1lID0gJ3BpY2stb3B0JyArIChhPT09J2RhcmsnID8gJyBhLWRhcmsnIDogJycpOwp9CmZ1bmN0aW9uIGJ1aWxkTnB2TGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBqID0gewogICAgc3NoQ29uZmlnVHlwZTonU1NILVByb3h5LVBheWxvYWQnLCByZW1hcmtzOnByby5uYW1lKyctJytuYW1lLAogICAgc3NoSG9zdDpOUFZfSE9TVCwgc3NoUG9ydDpOUFZfUE9SVCwKICAgIHNzaFVzZXJuYW1lOm5hbWUsIHNzaFBhc3N3b3JkOnBhc3MsCiAgICBzbmk6JycsIHRsc1ZlcnNpb246J0RFRkFVTFQnLAogICAgaHR0cFByb3h5OnByby5wcm94eSwgYXV0aGVudGljYXRlUHJveHk6ZmFsc2UsCiAgICBwcm94eVVzZXJuYW1lOicnLCBwcm94eVBhc3N3b3JkOicnLAogICAgcGF5bG9hZDpwcm8ucGF5bG9hZCwKICAgIGRuc01vZGU6J1VEUCcsIGRuc1NlcnZlcjonJywgbmFtZXNlcnZlcjonJywgcHVibGljS2V5OicnLAogICAgdWRwZ3dQb3J0OjczMDAsIHVkcGd3VHJhbnNwYXJlbnRETlM6dHJ1ZQogIH07CiAgcmV0dXJuICducHZ0LXNzaDovLycgKyBidG9hKHVuZXNjYXBlKGVuY29kZVVSSUNvbXBvbmVudChKU09OLnN0cmluZ2lmeShqKSkpKTsKfQpmdW5jdGlvbiBidWlsZERhcmtMaW5rKG5hbWUsIHBhc3MsIHBybykgewogIGNvbnN0IHBwID0gKHByby5wcm94eXx8JycpLnNwbGl0KCc6Jyk7CiAgY29uc3QgZGggPSBwcFswXSB8fCBwcm8uZGFya1Byb3h5OwogIGNvbnN0IGogPSB7CiAgICBjb25maWdUeXBlOidTU0gtUFJPWFknLCByZW1hcmtzOnByby5uYW1lKyctJytuYW1lLAogICAgc3NoSG9zdDpIT1NULCBzc2hQb3J0OjE0MywKICAgIHNzaFVzZXI6bmFtZSwgc3NoUGFzczpwYXNzLAogICAgcGF5bG9hZDonR0VUIC8gSFRUUC8xLjFcclxuSG9zdDogJytIT1NUKydcclxuVXBncmFkZTogd2Vic29ja2V0XHJcbkNvbm5lY3Rpb246IFVwZ3JhZGVcclxuXHJcbicsCiAgICBwcm94eUhvc3Q6ZGgsIHByb3h5UG9ydDo4MCwKICAgIHVkcGd3QWRkcjonMTI3LjAuMC4xJywgdWRwZ3dQb3J0OjczMDAsIHRsc0VuYWJsZWQ6ZmFsc2UKICB9OwogIHJldHVybiAnZGFya3R1bm5lbC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBDUkVBVEUgU1NIIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBjcmVhdGVTU0goKSB7CiAgY29uc3QgdXNlciA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlcicpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBwYXNzID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1wYXNzJykudmFsdWUudHJpbSgpOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWRheXMnKS52YWx1ZSl8fDMwOwogIGNvbnN0IGlwbCAgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWlwJykgPyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLWlwJykudmFsdWUgOiAyKXx8MjsKICBpZiAoIXVzZXIpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBVc2VybmFtZScsJ2VycicpOwogIGlmICghcGFzcykgcmV0dXJuIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFBhc3N3b3JkJywnZXJyJyk7CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOwogIGJ0bi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iIHN0eWxlPSJib3JkZXItY29sb3I6cmdiYSgzNCwxOTcsOTQsLjMpO2JvcmRlci10b3AtY29sb3I6IzIyYzU1ZSI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGNvbnN0IHJlc0VsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1saW5rLXJlc3VsdCcpOwogIGlmIChyZXNFbCkgcmVzRWwuY2xhc3NOYW1lPSdsaW5rLXJlc3VsdCc7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9jcmVhdGVfc3NoJywgewogICAgICBtZXRob2Q6J1BPU1QnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OiBKU09OLnN0cmluZ2lmeSh7dXNlciwgcGFzc3dvcmQ6cGFzcywgZGF5cywgaXBfbGltaXQ6aXBsfSkKICAgIH0pOwogICAgY29uc3QgZCA9IGF3YWl0IHIuanNvbigpOwogICAgaWYgKCFkLm9rKSB0aHJvdyBuZXcgRXJyb3IoZC5lcnJvciB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgcHJvICA9IFBST1NbX3NzaFByb10gfHwgUFJPUy5kdGFjOwogICAgY29uc3QgbGluayA9IF9zc2hBcHA9PT0nbnB2JyA/IGJ1aWxkTnB2TGluayh1c2VyLHBhc3MscHJvKSA6IGJ1aWxkRGFya0xpbmsodXNlcixwYXNzLHBybyk7CiAgICBjb25zdCBpc05wdiA9IF9zc2hBcHA9PT0nbnB2JzsKICAgIGNvbnN0IGxwQ2xzID0gaXNOcHYgPyAnJyA6ICcgZGFyay1scCc7CiAgICBjb25zdCBjQ2xzICA9IGlzTnB2ID8gJ25wdicgOiAnZGFyayc7CiAgICBjb25zdCBhcHBMYWJlbCA9IGlzTnB2ID8gJ05wdnQnIDogJ0RhcmtUdW5uZWwnOwoKICAgIGlmIChyZXNFbCkgewogICAgICByZXNFbC5jbGFzc05hbWUgPSAnbGluay1yZXN1bHQgc2hvdyc7CiAgICAgIGNvbnN0IHNhZmVMaW5rID0gbGluay5yZXBsYWNlKC9cXC9nLCdcXFxcJykucmVwbGFjZSgvJy9nLCJcXCciKTsKICAgICAgcmVzRWwuaW5uZXJIVE1MID0KICAgICAgICAiPGRpdiBjbGFzcz0nbGluay1yZXN1bHQtaGRyJz4iICsKICAgICAgICAgICI8c3BhbiBjbGFzcz0naW1wLWJhZGdlICIrY0NscysiJz4iK2FwcExhYmVsKyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6dmFyKC0tbXV0ZWQpJz4iK3Byby5uYW1lKyIgXHhiNyBQb3J0ICIrX3NzaFBvcnQrIjwvc3Bhbj4iICsKICAgICAgICAgICI8c3BhbiBzdHlsZT0nZm9udC1zaXplOi42NXJlbTtjb2xvcjojMjJjNTVlO21hcmdpbi1sZWZ0OmF1dG8nPlx1MjcwNSAiK3VzZXIrIjwvc3Bhbj4iICsKICAgICAgICAiPC9kaXY+IiArCiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcHJldmlldyIrbHBDbHMrIic+IitsaW5rKyI8L2Rpdj4iICsKICAgICAgICAiPGJ1dHRvbiBjbGFzcz0nY29weS1saW5rLWJ0biAiK2NDbHMrIicgaWQ9J2NvcHktc3NoLWJ0bicgb25jbGljaz1cImNvcHlTU0hMaW5rKClcIj4iKwogICAgICAgICAgIlx1ZDgzZFx1ZGNjYiBDb3B5ICIrYXBwTGFiZWwrIiBMaW5rIisKICAgICAgICAiPC9idXR0b24+IjsKICAgICAgd2luZG93Ll9sYXN0U1NITGluayA9IGxpbms7CiAgICAgIHdpbmRvdy5fbGFzdFNTSEFwcCAgPSBjQ2xzOwogICAgICB3aW5kb3cuX2xhc3RTU0hMYWJlbCA9IGFwcExhYmVsOwogICAgfQoKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0Jywn4pyFIOC4quC4o+C5ieC4suC4hyAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIggwrcg4Lir4Lih4LiU4Lit4Liy4Lii4Li4ICcrZC5leHAsJ29rJyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZT0nJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlPScnOwogICAgbG9hZFNTSFRhYmxlSW5Gb3JtKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KelSDguKrguKPguYnguLLguIcgVXNlcic7IH0KfQpmdW5jdGlvbiBjb3B5U1NITGluaygpIHsKICBjb25zdCBsaW5rID0gd2luZG93Ll9sYXN0U1NITGlua3x8Jyc7CiAgY29uc3QgY0NscyA9IHdpbmRvdy5fbGFzdFNTSEFwcHx8J25wdic7CiAgY29uc3QgbGFiZWwgPSB3aW5kb3cuX2xhc3RTU0hMYWJlbHx8J0xpbmsnOwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KGxpbmspLnRoZW4oZnVuY3Rpb24oKXsKICAgIGNvbnN0IGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY29weS1zc2gtYnRuJyk7CiAgICBpZihiKXsgYi50ZXh0Q29udGVudD0nXHUyNzA1IOC4hOC4seC4lOC4peC4reC4geC5geC4peC5ieC4pyEnOyBzZXRUaW1lb3V0KGZ1bmN0aW9uKCl7Yi50ZXh0Q29udGVudD0nXHVkODNkXHVkY2NiIENvcHkgJytsYWJlbCsnIExpbmsnO30sMjAwMCk7IH0KICB9KS5jYXRjaChmdW5jdGlvbigpeyBwcm9tcHQoJ0NvcHkgbGluazonLGxpbmspOyB9KTsKfQoKLy8gU1NIIHVzZXIgdGFibGUKbGV0IF9zc2hUYWJsZVVzZXJzID0gW107CmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hUYWJsZUluRm9ybSgpIHsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBfc3NoVGFibGVVc2VycyA9IGQudXNlcnMgfHwgW107CiAgICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycyk7CiAgfSBjYXRjaChlKSB7CiAgICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogICAgaWYodGIpIHRiLmlubmVySFRNTD0nPHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7Y29sb3I6I2VmNDQ0NDtwYWRkaW5nOjE2cHgiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBTU0ggQVBJIOC5hOC4oeC5iOC5hOC4lOC5iTwvdGQ+PC90cj4nOwogIH0KfQpmdW5jdGlvbiByZW5kZXJTU0hUYWJsZSh1c2VycykgewogIGNvbnN0IHRiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLXRib2R5Jyk7CiAgaWYgKCF0YikgcmV0dXJuOwogIGlmICghdXNlcnMubGVuZ3RoKSB7CiAgICB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOnZhcigtLW11dGVkKTtwYWRkaW5nOjIwcHgiPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3RkPjwvdHI+JzsKICAgIHJldHVybjsKICB9CiAgY29uc3Qgbm93ID0gbmV3IERhdGUoKS50b0lTT1N0cmluZygpLnNsaWNlKDAsMTApOwogIHRiLmlubmVySFRNTCA9IHVzZXJzLm1hcChmdW5jdGlvbih1LGkpewogICAgY29uc3QgZXhwaXJlZCA9IHUuZXhwICYmIHUuZXhwIDwgbm93OwogICAgY29uc3QgYWN0aXZlICA9IHUuYWN0aXZlICE9PSBmYWxzZSAmJiAhZXhwaXJlZDsKICAgIGNvbnN0IGRMZWZ0ICAgPSB1LmV4cCA/IE1hdGguY2VpbCgobmV3IERhdGUodS5leHApLURhdGUubm93KCkpLzg2NDAwMDAwKSA6IG51bGw7CiAgICBjb25zdCBiYWRnZSAgID0gYWN0aXZlCiAgICAgID8gJzxzcGFuIGNsYXNzPSJiZGcgYmRnLWciPkFDVElWRTwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJiZGcgYmRnLXIiPkVYUElSRUQ8L3NwYW4+JzsKICAgIGNvbnN0IGRUYWcgPSBkTGVmdCE9PW51bGwKICAgICAgPyAnPHNwYW4gY2xhc3M9ImRheXMtYmFkZ2UiPicrKGRMZWZ0PjA/ZExlZnQrJ2QnOifguKvguKHguJQnKSsnPC9zcGFuPicKICAgICAgOiAnPHNwYW4gY2xhc3M9ImRheXMtYmFkZ2UiPlx1MjIxZTwvc3Bhbj4nOwogICAgcmV0dXJuICc8dHI+PHRkIHN0eWxlPSJjb2xvcjp2YXIoLS1tdXRlZCkiPicrKGkrMSkrJzwvdGQ+JyArCiAgICAgICc8dGQ+PGI+Jyt1LnVzZXIrJzwvYj48L3RkPicgKwogICAgICAnPHRkIHN0eWxlPSJmb250LXNpemU6MTFweDtjb2xvcjonKyhleHBpcmVkPycjZWY0NDQ0JzondmFyKC0tbXV0ZWQpJykrJyI+JysKICAgICAgICAodS5leHB8fCfguYTguKHguYjguIjguLPguIHguLHguJQnKSsnPC90ZD4nICsKICAgICAgJzx0ZD4nK2JhZGdlKyc8L3RkPicgKwogICAgICAnPHRkPjxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6NHB4O2FsaWduLWl0ZW1zOmNlbnRlciI+JysKICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iYnRuLXRibCIgdGl0bGU9IuC4leC5iOC4reC4reC4suC4ouC4uCIgb25jbGljaz0ib3BlblNTSFJlbmV3TW9kYWwoXCcnK3UudXNlcisnXCcpIj7wn5SEPC9idXR0b24+JysKICAgICAgICAnPGJ1dHRvbiBjbGFzcz0iYnRuLXRibCIgdGl0bGU9IuC4peC4miIgb25jbGljaz0iZGVsU1NIVXNlcihcJycrdS51c2VyKydcJykiIHN0eWxlPSJib3JkZXItY29sb3I6cmdiYSgyMzksNjgsNjgsLjMpIj7wn5eR77iPPC9idXR0b24+JysKICAgICAgICBkVGFnKwogICAgICAnPC9kaXY+PC90ZD48L3RyPic7CiAgfSkuam9pbignJyk7Cn0KZnVuY3Rpb24gZmlsdGVyU1NIVXNlcnMocSkgewogIHJlbmRlclNTSFRhYmxlKF9zc2hUYWJsZVVzZXJzLmZpbHRlcihmdW5jdGlvbih1KXtyZXR1cm4gKHUudXNlcnx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50b0xvd2VyQ2FzZSgpKTt9KSk7Cn0KLy8gU1NIIFJlbmV3IE1vZGFsCmxldCBfcmVuZXdTU0hVc2VyID0gJyc7CmZ1bmN0aW9uIG9wZW5TU0hSZW5ld01vZGFsKHVzZXIpIHsKICBfcmVuZXdTU0hVc2VyID0gdXNlcjsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LXVzZXJuYW1lJykudGV4dENvbnRlbnQgPSB1c2VyOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctZGF5cycpLnZhbHVlID0gJzMwJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LW1vZGFsJykuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwp9CmZ1bmN0aW9uIGNsb3NlU1NIUmVuZXdNb2RhbCgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LW1vZGFsJykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogIF9yZW5ld1NTSFVzZXIgPSAnJzsKfQphc3luYyBmdW5jdGlvbiBkb1NTSFJlbmV3KCkgewogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKCFkYXlzfHxkYXlzPD0wKSByZXR1cm47CiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1idG4nKTsKICBidG4uZGlzYWJsZWQgPSB0cnVlOyBidG4udGV4dENvbnRlbnQgPSAn4LiB4Liz4Lil4Lix4LiH4LiV4LmI4Lit4Lit4Liy4Lii4Li4Li4uJzsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2V4dGVuZF9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyOl9yZW5ld1NTSFVzZXIsZGF5c30pCiAgICB9KS50aGVuKGZ1bmN0aW9uKHIpe3JldHVybiByLmpzb24oKTt9KTsKICAgIGlmICghci5vaykgdGhyb3cgbmV3IEVycm9yKHIuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzA1IOC4leC5iOC4reC4reC4suC4ouC4uCAnK19yZW5ld1NTSFVzZXIrJyArJytkYXlzKycg4Lin4Lix4LiZIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBjbG9zZVNTSFJlbmV3TW9kYWwoKTsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgewogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3NGMgJytlLm1lc3NhZ2UsJ2VycicpOwogIH0gZmluYWxseSB7CiAgICBidG4uZGlzYWJsZWQgPSBmYWxzZTsgYnRuLnRleHRDb250ZW50ID0gJ+KchSDguKLguLfguJnguKLguLHguJnguJXguYjguK3guK3guLLguKLguLgnOwogIH0KfQphc3luYyBmdW5jdGlvbiByZW5ld1NTSFVzZXIodXNlcikgeyBvcGVuU1NIUmVuZXdNb2RhbCh1c2VyKTsgfQphc3luYyBmdW5jdGlvbiBkZWxTU0hVc2VyKHVzZXIpIHsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciIOC4luC4suC4p+C4oz8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcsewogICAgICBtZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sCiAgICAgIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJ9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBhbGVydCgnXHUyNzRjICcrZS5tZXNzYWdlKTsgfQp9Ci8vIOKVkOKVkOKVkOKVkCBDUkVBVEUgVkxFU1Mg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGdlblVVSUQoKSB7CiAgcmV0dXJuICd4eHh4eHh4eC14eHh4LTR4eHgteXh4eC14eHh4eHh4eHh4eHgnLnJlcGxhY2UoL1t4eV0vZyxjPT57CiAgICBjb25zdCByPU1hdGgucmFuZG9tKCkqMTZ8MDsgcmV0dXJuIChjPT09J3gnP3I6KHImMHgzfDB4OCkpLnRvU3RyaW5nKDE2KTsKICB9KTsKfQphc3luYyBmdW5jdGlvbiBjcmVhdGVWTEVTUyhjYXJyaWVyKSB7CiAgY29uc3QgZW1haWxFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1lbWFpbCcpOwogIGNvbnN0IGRheXNFbCAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZGF5cycpOwogIGNvbnN0IGlwRWwgICAgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctaXAnKTsKICBjb25zdCBnYkVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWdiJyk7CiAgY29uc3QgZW1haWwgICA9IGVtYWlsRWwudmFsdWUudHJpbSgpOwogIGNvbnN0IGRheXMgICAgPSBwYXJzZUludChkYXlzRWwudmFsdWUpfHwzMDsKICBjb25zdCBpcExpbWl0ID0gcGFyc2VJbnQoaXBFbC52YWx1ZSl8fDI7CiAgY29uc3QgZ2IgICAgICA9IHBhcnNlSW50KGdiRWwudmFsdWUpfHwwOwogIGlmICghZW1haWwpIHJldHVybiBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIEVtYWlsL1VzZXJuYW1lJywnZXJyJyk7CgogIGNvbnN0IHBvcnQgPSBjYXJyaWVyPT09J2FpcycgPyA4MDgwIDogMjA5NjsKICBjb25zdCBhZGRyID0gY2Fycmllcj09PSdhaXMnID8gJzEzLjIyNi4xMTUuNTYnIDogJ3pvb212ZG9jb25uZWN0LmNsb3VkemVyb3Zwcy5vbmxpbmUnOwogIGxldCBzbmk7CiAgaWYgKGNhcnJpZXI9PT0nYWlzJykgewogICAgY29uc3Qgc25pRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYWlzLXNuaScpOwogICAgY29uc3Qgc25pSW5wdXQgPSBzbmlFbCA/IHNuaUVsLnZhbHVlLnRyaW0oKSA6ICcnOwogICAgc25pID0gc25pSW5wdXQgfHwgSE9TVDsgLy8g4LmA4Lin4LmJ4LiZ4Lin4LmI4Liy4LiHID0g4LmD4LiK4LmJ4LmC4LiU4LmA4Lih4LiZ4LmB4LiX4LiZIChTTkkg4LmA4Lib4Lil4Li14LmI4Lii4LiZ4LmE4LiU4LmJ4LiV4Liy4Lih4LiE4Lij4Liy4Lin4Lif4LmJ4Lit4LiZIOC4leC4seC5ieC4h+C4leC4suC4ouC4leC4seC4p+C5hOC4oeC5iOC5hOC4lOC5iSkKICB9IGVsc2UgewogICAgc25pID0gSE9TVDsgLy8gVFJVRS1WRE8g4LmD4LiK4LmJ4LmC4LiU4LmA4Lih4LiZ4LiC4Lit4LiH4Lie4Liy4LmA4LiZ4Lil4LmA4Lib4LmH4LiZIGhvc3QgaGVhZGVyIOC5gOC4quC4oeC4rQogIH0KCiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWJ0bicpOwogIGJ0bi5kaXNhYmxlZD10cnVlOyBidG4uaW5uZXJIVE1MPSc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKCiAgdHJ5IHsKICAgIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIC8vIOC4q+C4siBpbmJvdW5kIGlkCiAgICBjb25zdCBsaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliID0gKGxpc3Qub2JqfHxbXSkuZmluZCh4PT54LnBvcnQ9PT1wb3J0KTsKICAgIGlmICghaWIpIHRocm93IG5ldyBFcnJvcihg4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCAke3BvcnR9IOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZYCk7CgogICAgY29uc3QgdWlkID0gZ2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXMgPSBkYXlzID4gMCA/IChEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMCkgOiAwOwogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDp1aWQsIGZsb3c6JycsIGVtYWlsLCBsaW1pdElwOmlwTGltaXQsCiAgICAgICAgdG90YWxHQjp0b3RhbEJ5dGVzLCBleHBpcnlUaW1lOmV4cE1zLCBlbmFibGU6dHJ1ZSwgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgbGluayA9IGB2bGVzczovLyR7dWlkfUAke2FkZHJ9OiR7cG9ydH0/ZW5jcnlwdGlvbj1ub25lJmZsb3c9bm9uZSZ0eXBlPXdzJmhvc3Q9JHtzbml9JmhlYWRlclR5cGU9bm9uZSZwYXRoPSUyRnZsZXNzJnNlY3VyaXR5PW5vbmUjJHtlbmNvZGVVUklDb21wb25lbnQoZW1haWwrJy0nKyhjYXJyaWVyPT09J2Fpcyc/J0FJUy1QTEFZJzonVFJVRScpKX1gOwoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWVtYWlsJykudGV4dENvbnRlbnQgPSBlbWFpbDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLXV1aWQnKS50ZXh0Q29udGVudCA9IHVpZDsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWV4cCcpLnRleHRDb250ZW50ID0gZXhwTXMgPiAwID8gZm10RGF0ZShleHBNcykgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdyLScrY2FycmllcisnLWxpbmsnKS50ZXh0Q29udGVudCA9IGxpbms7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcmVzdWx0JykuY2xhc3NMaXN0LmFkZCgnc2hvdycpOwogICAgLy8gR2VuZXJhdGUgUVIgY29kZQogICAgY29uc3QgcXJEaXYgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctcXInKTsKICAgIGlmIChxckRpdikgewogICAgICBxckRpdi5pbm5lckhUTUwgPSAnJzsKICAgICAgdHJ5IHsKICAgICAgICBuZXcgUVJDb2RlKHFyRGl2LCB7IHRleHQ6IGxpbmssIHdpZHRoOiAxODAsIGhlaWdodDogMTgwLCBjb3JyZWN0TGV2ZWw6IFFSQ29kZS5Db3JyZWN0TGV2ZWwuTSB9KTsKICAgICAgfSBjYXRjaChxckVycikgeyBxckRpdi5pbm5lckhUTUwgPSAnJzsgfQogICAgfQogICAgc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgVkxFU1MgQWNjb3VudCDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZW1haWxFbC52YWx1ZT0nJzsKICAgIGlmIChjYXJyaWVyPT09J2FpcycpIHsgY29uc3Qgc25pRWwyPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhaXMtc25pJyk7IGlmIChzbmlFbDIpIHNuaUVsMi52YWx1ZT0nJzsgfQogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KaoSDguKrguKPguYnguLLguIcgJysoY2Fycmllcj09PSdhaXMnPydBSVMnOidUUlVFJykrJyBBY2NvdW50JzsgfQp9CgovLyDilZDilZDilZDilZAgTUFOQUdFIFVTRVJTIOKVkOKVkOKVkOKVkApsZXQgX2FsbFVzZXJzID0gW10sIF9jdXJVc2VyID0gbnVsbDsKYXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJzKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgX3h1aUNvb2tpZSA9IGZhbHNlOwogICAgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihkLm1zZyB8fCAn4LmC4Lir4Lil4LiUIGluYm91bmRzIOC5hOC4oeC5iOC5hOC4lOC5iScpOwogICAgX2FsbFVzZXJzID0gW107CiAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICBfYWxsVXNlcnMucHVzaCh7CiAgICAgICAgICBpYklkOiBpYi5pZCwgcG9ydDogaWIucG9ydCwgcHJvdG86IGliLnByb3RvY29sLAogICAgICAgICAgZW1haWw6IGMuZW1haWx8fGMuaWQsIHV1aWQ6IGMuaWQsCiAgICAgICAgICBleHA6IGMuZXhwaXJ5VGltZXx8MCwgdG90YWw6IGMudG90YWxHQnx8MCwKICAgICAgICAgIHVwOiBpYi51cHx8MCwgZG93bjogaWIuZG93bnx8MCwgbGltaXRJcDogYy5saW1pdElwfHwwCiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSk7CiAgICByZW5kZXJVc2VycyhfYWxsVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclVzZXJzKHVzZXJzKSB7CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lie4Lia4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMPC9wPjwvZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1ID0+IHsKICAgIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogICAgbGV0IGJhZGdlLCBjbHM7CiAgICBpZiAoIXUuZXhwIHx8IHUuZXhwPT09MCkgeyBiYWRnZT0n4pyTIOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7IGNscz0nb2snOyB9CiAgICBlbHNlIGlmIChkbCA8IDApICAgICAgICAgeyBiYWRnZT0n4Lir4Lih4LiU4Lit4Liy4Lii4Li4JzsgY2xzPSdleHAnOyB9CiAgICBlbHNlIGlmIChkbCA8PSAzKSAgICAgICAgeyBiYWRnZT0n4pqgICcrZGwrJ2QnOyBjbHM9J3Nvb24nOyB9CiAgICBlbHNlICAgICAgICAgICAgICAgICAgICAgeyBiYWRnZT0n4pyTICcrZGwrJ2QnOyBjbHM9J29rJzsgfQogICAgY29uc3QgYXZDbHMgPSBkbCA8IDAgPyAnYXYteCcgOiAnYXYtZyc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIiBvbmNsaWNrPSJvcGVuVXNlcigke0pTT04uc3RyaW5naWZ5KHUpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyl9KSI+CiAgICAgIDxkaXYgY2xhc3M9InVhdiAke2F2Q2xzfSI+JHsodS5lbWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3UuZW1haWx9PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idW0iPlBvcnQgJHt1LnBvcnR9IMK3ICR7Zm10Qnl0ZXModS51cCt1LmRvd24pfSDguYPguIrguYk8L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxzcGFuIGNsYXNzPSJhYmRnICR7Y2xzfSI+JHtiYWRnZX08L3NwYW4+CiAgICA8L2Rpdj5gOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclVzZXJzKHEpIHsKICByZW5kZXJVc2VycyhfYWxsVXNlcnMuZmlsdGVyKHU9Pih1LmVtYWlsfHwnJykudG9Mb3dlckNhc2UoKS5pbmNsdWRlcyhxLnRvTG93ZXJDYXNlKCkpKSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBNT0RBTCBVU0VSIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBvcGVuVXNlcih1KSB7CiAgaWYgKHR5cGVvZiB1ID09PSAnc3RyaW5nJykgdSA9IEpTT04ucGFyc2UodSk7CiAgX2N1clVzZXIgPSB1OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtdCcpLnRleHRDb250ZW50ID0gJ+Kame+4jyAnK3UuZW1haWw7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2R1JykudGV4dENvbnRlbnQgPSB1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkcCcpLnRleHRDb250ZW50ID0gdS5wb3J0OwogIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogIGNvbnN0IGV4cFR4dCA9ICF1LmV4cHx8dS5leHA9PT0wID8gJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCcgOiBmbXREYXRlKHUuZXhwKTsKICBjb25zdCBkZSA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZScpOwogIGRlLnRleHRDb250ZW50ID0gZXhwVHh0OwogIGRlLmNsYXNzTmFtZSA9ICdkdicgKyAoZGwgIT09IG51bGwgJiYgZGwgPCAwID8gJyByZWQnIDogJyBncmVlbicpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkZCcpLnRleHRDb250ZW50ID0gdS50b3RhbCA+IDAgPyBmbXRCeXRlcyh1LnRvdGFsKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdHInKS50ZXh0Q29udGVudCA9IGZtdEJ5dGVzKHUudXArdS5kb3duKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGknKS50ZXh0Q29udGVudCA9IHUubGltaXRJcCB8fCAn4oieJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHV1JykudGV4dENvbnRlbnQgPSB1LnV1aWQ7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LmFkZCgnb3BlbicpOwp9CmZ1bmN0aW9uIGNtKCl7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsJykuY2xhc3NMaXN0LnJlbW92ZSgnb3BlbicpOwogIF9tU3Vicy5mb3JFYWNoKGsgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5hYnRuJykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwp9CgovLyDilIDilIAgTU9EQUwgNi1BQ1RJT04gU1lTVEVNIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApjb25zdCBfbVN1YnMgPSBbJ3JlbmV3JywnZXh0ZW5kJywnYWRkZGF0YScsJ3NldGRhdGEnLCdyZXNldCcsJ2RlbGV0ZSddOwpmdW5jdGlvbiBtQWN0aW9uKGtleSkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrZXkpOwogIGNvbnN0IGlzT3BlbiA9IGVsLmNsYXNzTGlzdC5jb250YWlucygnb3BlbicpOwogIF9tU3Vicy5mb3JFYWNoKGsgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21zdWItJytrKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJykpOwogIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5hYnRuJykuZm9yRWFjaChiID0+IGIuY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtb2RhbC1hbGVydCcpLnN0eWxlLmRpc3BsYXk9J25vbmUnOwogIGlmICghaXNPcGVuKSB7CiAgICBlbC5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7CiAgICBpZiAoa2V5PT09J2RlbGV0ZScgJiYgX2N1clVzZXIpIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWRlbC1uYW1lJykudGV4dENvbnRlbnQgPSBfY3VyVXNlci5lbWFpbDsKICAgIHNldFRpbWVvdXQoKCk9PmVsLnNjcm9sbEludG9WaWV3KHtiZWhhdmlvcjonc21vb3RoJyxibG9jazonbmVhcmVzdCd9KSwxMDApOwogIH0KfQpmdW5jdGlvbiBfbUJ0bkxvYWQoaWQsIGxvYWRpbmcsIG9yaWdUZXh0KSB7CiAgY29uc3QgYiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKTsKICBpZiAoIWIpIHJldHVybjsKICBiLmRpc2FibGVkID0gbG9hZGluZzsKICBpZiAobG9hZGluZykgeyBiLmRhdGFzZXQub3JpZyA9IGIudGV4dENvbnRlbnQ7IGIuaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIj48L3NwYW4+IOC4geC4s+C4peC4seC4h+C4lOC4s+C5gOC4meC4tOC4meC4geC4suC4oy4uLic7IH0KICBlbHNlIGlmIChiLmRhdGFzZXQub3JpZykgYi50ZXh0Q29udGVudCA9IGIuZGF0YXNldC5vcmlnOwp9Cgphc3luYyBmdW5jdGlvbiBkb1JlbmV3VXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZGF5cyA9IHBhcnNlSW50KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXJlbmV3LWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tcmVuZXctYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGV4cE1zID0gRGF0ZS5ub3coKSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4LmI4Lit4Lit4Liy4Lii4Li44Liq4Liz4LmA4Lij4LmH4LiIICcrZGF5cysnIOC4p+C4seC4mSAo4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJKScsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0V4dGVuZFVzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1leHRlbmQtZGF5cycpLnZhbHVlKXx8MDsKICBpZiAoZGF5cyA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4geC4iOC4s+C4meC4p+C4meC4p+C4seC4mScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IGJhc2UgPSAoX2N1clVzZXIuZXhwICYmIF9jdXJVc2VyLmV4cCA+IERhdGUubm93KCkpID8gX2N1clVzZXIuZXhwIDogRGF0ZS5ub3coKTsKICAgIGNvbnN0IGV4cE1zID0gYmFzZSArIGRheXMqODY0MDAwMDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6X2N1clVzZXIudG90YWwsZXhwaXJ5VGltZTpleHBNcyxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihICcrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIggKOC4leC5iOC4reC4iOC4suC4geC4p+C4seC4meC4q+C4oeC4lCknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1leHRlbmQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvQWRkRGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgYWRkR2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLWFkZGRhdGEtZ2InKS52YWx1ZSl8fDA7CiAgaWYgKGFkZEdiIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C5gOC4nuC4tOC5iOC4oScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBuZXdUb3RhbCA9IChfY3VyVXNlci50b3RhbHx8MCkgKyBhZGRHYioxMDczNzQxODI0OwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOm5ld1RvdGFsLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguYDguJ7guLTguYjguKEgRGF0YSArJythZGRHYisnIEdCIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWFkZGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvU2V0RGF0YSgpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgY29uc3QgZ2IgPSBwYXJzZUZsb2F0KGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdtLXNldGRhdGEtZ2InKS52YWx1ZSk7CiAgaWYgKGlzTmFOKGdiKXx8Z2I8MCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHRvdGFsQnl0ZXMgPSBnYiA+IDAgPyBnYioxMDczNzQxODI0IDogMDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjp0b3RhbEJ5dGVzLGV4cGlyeVRpbWU6X2N1clVzZXIuZXhwfHwwLGVuYWJsZTp0cnVlLHRnSWQ6Jycsc3ViSWQ6JycsY29tbWVudDonJyxyZXNldDowfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguJXguLHguYnguIcgRGF0YSBMaW1pdCAnKyhnYj4wP2diKycgR0InOifguYTguKHguYjguIjguLPguIHguLHguJQnKSsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxODAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLXNldGRhdGEtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvUmVzZXRUcmFmZmljKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgdHJ1ZSk7CiAgdHJ5IHsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9yZXNldENsaWVudFRyYWZmaWMvJytfY3VyVXNlci5lbWFpbCk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTUwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZXNldC1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9EZWxldGVVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBfbUJ0bkxvYWQoJ20tZGVsZXRlLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvJytfY3VyVXNlci5pYklkKycvZGVsQ2xpZW50LycrX2N1clVzZXIudXVpZCk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKXguJrguKLguLnguKogJytfY3VyVXNlci5lbWFpbCsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxMjAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCBmYWxzZSk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlDb29raWUgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICAvLyDguYLguKvguKXguJQgaW5ib3VuZHMg4LiW4LmJ4Liy4Lii4Lix4LiH4LmE4Lih4LmI4Lih4Li1CiAgICBpZiAoIV9hbGxVc2Vycy5sZW5ndGgpIHsKICAgICAgY29uc3QgZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgICBpZiAoZCAmJiBkLnN1Y2Nlc3MpIHsKICAgICAgICBfYWxsVXNlcnMgPSBbXTsKICAgICAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBfYWxsVXNlcnMucHVzaCh7IGliSWQ6aWIuaWQsIHBvcnQ6aWIucG9ydCwgcHJvdG86aWIucHJvdG9jb2wsCiAgICAgICAgICAgICAgZW1haWw6Yy5lbWFpbHx8Yy5pZCwgdXVpZDpjLmlkLCBleHA6Yy5leHBpcnlUaW1lfHwwLAogICAgICAgICAgICAgIHRvdGFsOmMudG90YWxHQnx8MCwgdXA6aWIudXB8fDAsIGRvd246aWIuZG93bnx8MCwgbGltaXRJcDpjLmxpbWl0SXB8fDAgfSk7CiAgICAgICAgICB9KTsKICAgICAgICB9KTsKICAgICAgfQogICAgfQogICAgY29uc3Qgb2QgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvb25saW5lcycpLmNhdGNoKCgpPT5udWxsKTsKICAgIC8vIOC4o+C4reC4h+C4o+C4seC4miBmb3JtYXQ6IHtvYmo6IFsuLi5dfSDguKvguKPguLfguK0ge29iajogbnVsbH0g4Lir4Lij4Li34LitIHtvYmo6IHt9fQogICAgbGV0IGVtYWlscyA9IFtdOwogICAgaWYgKG9kICYmIG9kLm9iaikgewogICAgICBpZiAoQXJyYXkuaXNBcnJheShvZC5vYmopKSBlbWFpbHMgPSBvZC5vYmo7CiAgICAgIGVsc2UgaWYgKHR5cGVvZiBvZC5vYmogPT09ICdvYmplY3QnKSBlbWFpbHMgPSBPYmplY3QudmFsdWVzKG9kLm9iaikuZmxhdCgpLmZpbHRlcihlPT50eXBlb2YgZT09PSdzdHJpbmcnKTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIj4KICAgICAgICA8ZGl2IGNsYXNzPSJ1YXYgYXYtZyI+8J+fojwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHtlbWFpbH08L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InVtIj4ke3UgPyAnUG9ydCAnK3UucG9ydCA6ICdWTEVTUyd9IMK3IOC4reC4reC4meC5hOC4peC4meC5jOC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJhYmRnIG9rIj5PTkxJTkU8L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPicrZS5tZXNzYWdlKyc8L2Rpdj4nOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNTSCBVU0VSUyAoYmFuIHRhYikg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWRTU0hVc2VycygpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VzZXJzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCB1c2VycyA9IGQudXNlcnMgfHwgW107CiAgICBpZiAoIXVzZXJzLmxlbmd0aCkgeyBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li1IFNTSCB1c2VyczwvcD48L2Rpdj4nOyByZXR1cm47IH0KICAgIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MID0gdXNlcnMubWFwKHU9PnsKICAgICAgY29uc3QgZXhwID0gdS5leHAgfHwgJ+C5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7CiAgICAgIGNvbnN0IGFjdGl2ZSA9IHUuYWN0aXZlICE9PSBmYWxzZTsKICAgICAgcmV0dXJuIGA8ZGl2IGNsYXNzPSJ1aXRlbSI+CiAgICAgICAgPGRpdiBjbGFzcz0idWF2ICR7YWN0aXZlPydhdi1nJzonYXYteCd9Ij4ke3UudXNlclswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImZsZXg6MSI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1biI+JHt1LnVzZXJ9PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJ1bSI+4Lir4Lih4LiU4Lit4Liy4Lii4Li4OiAke2V4cH08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2FjdGl2ZT8nb2snOidleHAnfSI+JHthY3RpdmU/J0FjdGl2ZSc6J0V4cGlyZWQnfTwvc3Bhbj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gZGVsZXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYmFuLXVzZXInKS52YWx1ZS50cmltKCk7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIWNvbmZpcm0oJ+C4peC4miBTU0ggdXNlciAiJyt1c2VyKyciID8nKSkgcmV0dXJuOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvZGVsZXRlX3NzaCcse21ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSxib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSl9KS50aGVuKHI9PnIuanNvbigpKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3J8fCfguKXguJrguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4pyFIOC4peC4miAnK3VzZXIrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWU9Jyc7CiAgICBsb2FkU1NIVXNlcnMoKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdiYW4tYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBDT1BZIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBjb3B5TGluayhpZCwgYnRuKSB7CiAgY29uc3QgdHh0ID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnRleHRDb250ZW50OwogIG5hdmlnYXRvci5jbGlwYm9hcmQud3JpdGVUZXh0KHR4dCkudGhlbigoKT0+ewogICAgY29uc3Qgb3JpZyA9IGJ0bi50ZXh0Q29udGVudDsKICAgIGJ0bi50ZXh0Q29udGVudD0n4pyFIENvcGllZCEnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0ncmdiYSgzNCwxOTcsOTQsLjE1KSc7CiAgICBzZXRUaW1lb3V0KCgpPT57IGJ0bi50ZXh0Q29udGVudD1vcmlnOyBidG4uc3R5bGUuYmFja2dyb3VuZD0nJzsgfSwgMjAwMCk7CiAgfSkuY2F0Y2goKCk9PnsgcHJvbXB0KCdDb3B5IGxpbms6JywgdHh0KTsgfSk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBMT0dPVVQg4pWQ4pWQ4pWQ4pWQCmZ1bmN0aW9uIGRvTG9nb3V0KCkgewogIHNlc3Npb25TdG9yYWdlLnJlbW92ZUl0ZW0oU0VTU0lPTl9LRVkpOwogIGxvY2F0aW9uLnJlcGxhY2UoJ2luZGV4Lmh0bWwnKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIElOSVQg4pWQ4pWQ4pWQ4pWQCgovLyDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZDilZAKLy8gIFNQRUVEIFRFU1QKLy8g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCmxldCBfc3BlZWRSdW5uaW5nPWZhbHNlOwpmdW5jdGlvbiBzZXRHYXVnZShtYnBzLCBtYXhNYnBzPTIwMCkgewogIGNvbnN0IGVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdnYXVnZS1maWxsJyk7CiAgY29uc3QgdmFsRWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dhdWdlLXZhbCcpOwogIGNvbnN0IHVuaXRFbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2F1Z2UtdW5pdCcpOwogIGlmICghZWwpIHJldHVybjsKICBjb25zdCBwY3Q9TWF0aC5taW4obWJwcy9tYXhNYnBzLDEpOwogIGVsLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQ9KDIyMC0oMjIwKnBjdCkpLnRvRml4ZWQoMik7CiAgY29uc3Qgcj1NYXRoLnJvdW5kKHBjdDwwLjU/MDoyNTUqKHBjdC0wLjUpKjIpOwogIGNvbnN0IGc9TWF0aC5yb3VuZChwY3Q8MC41PzI1NToyNTUqKDEtKHBjdC0wLjUpKjIpKTsKICBlbC5zZXRBdHRyaWJ1dGUoJ3N0cm9rZScsYHJnYigke3J9LCR7Z30sNTApYCk7CiAgdmFsRWwudGV4dENvbnRlbnQ9bWJwcz49MT9tYnBzLnRvRml4ZWQoMSk6KG1icHMqMTAwMCkudG9GaXhlZCgwKTsKICB1bml0RWwudGV4dENvbnRlbnQ9bWJwcz49MT8nTWJwcyc6J0ticHMnOwp9CmZ1bmN0aW9uIHNldFByb2dyZXNzKHBjdCkgewogIGNvbnN0IGVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1wcm9nLWZpbGwnKTsKICBpZiAoZWwpIGVsLnN0eWxlLndpZHRoPU1hdGgubWluKHBjdCwxMDApKyclJzsKfQphc3luYyBmdW5jdGlvbiBtZWFzdXJlUGluZygpIHsKICBjb25zdCBwaW5ncz1bXTsKICBmb3IgKGxldCBpPTA7aTw1O2krKykgewogICAgY29uc3QgdDA9cGVyZm9ybWFuY2Uubm93KCk7CiAgICB0cnl7YXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJyx7bWV0aG9kOidIRUFEJyxjYWNoZTonbm8tc3RvcmUnfSk7fQogICAgY2F0Y2goZSl7dHJ5e2F3YWl0IGZldGNoKCcvJyx7bWV0aG9kOidIRUFEJyxjYWNoZTonbm8tc3RvcmUnfSk7fWNhdGNoKGVlKXt9fQogICAgcGluZ3MucHVzaChwZXJmb3JtYW5jZS5ub3coKS10MCk7CiAgICBhd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7CiAgfQogIHBpbmdzLnNvcnQoKGEsYik9PmEtYik7CiAgY29uc3QgcGluZz1waW5nc1tNYXRoLmZsb29yKHBpbmdzLmxlbmd0aC8yKV07CiAgY29uc3Qgaml0dGVyPXBpbmdzW3BpbmdzLmxlbmd0aC0xXS1waW5nc1swXTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluZy12YWwnKS50ZXh0Q29udGVudD1waW5nLnRvRml4ZWQoMCkrJyBtcyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2ppdHRlci12YWwnKS50ZXh0Q29udGVudD1qaXR0ZXIudG9GaXhlZCgwKSsnIG1zJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9zcy12YWwnKS50ZXh0Q29udGVudD0nMCUnOwogIGNvbnN0IHBpbmdFbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncGluZy12YWwnKTsKICBwaW5nRWwuY2xhc3NOYW1lPSdzcGVlZC1waW5nLXZhbCcrKHBpbmc8ODA/Jyc6cGluZzwyMDA/JyB3YXJuJzonIGJhZCcpOwogIHJldHVybiB7cGluZyxqaXR0ZXJ9Owp9CmFzeW5jIGZ1bmN0aW9uIHN0YXJ0U3BlZWRUZXN0KHR5cGUpIHsKICBpZiAoX3NwZWVkUnVubmluZykgcmV0dXJuOwogIF9zcGVlZFJ1bm5pbmc9dHJ1ZTsKICBjb25zdCBidG5EbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnYnRuLWRsJyk7CiAgY29uc3QgYnRuVWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi11bCcpOwogIGJ0bkRsLmRpc2FibGVkPXRydWU7IGJ0blVsLmRpc2FibGVkPXRydWU7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfguIHguLPguKXguLHguIfguKfguLHguJQgUGluZy4uLic7CiAgc2V0UHJvZ3Jlc3MoMCk7IHNldEdhdWdlKDApOwogIHRyeXsKICAgIGNvbnN0IGluZm89YXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYoaW5mbyYmaW5mby5ob3N0KSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndnBzLWlwJykudGV4dENvbnRlbnQ9aW5mby5ob3N0OwogICAgZWxzZSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndnBzLWlwJykudGV4dENvbnRlbnQ9bG9jYXRpb24uaG9zdG5hbWU7CiAgfWNhdGNoKGUpe30KICB0cnl7YXdhaXQgbWVhc3VyZVBpbmcoKTt9Y2F0Y2goZSl7fQogIHNldFByb2dyZXNzKDEwKTsKICBpZiAodHlwZT09PSdkb3dubG9hZCcpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIERvd25sb2FkLi4uJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkbC12YWwnKS50ZXh0Q29udGVudD0nLi4uJzsKICAgIGNvbnN0IG1icHM9YXdhaXQgcnVuRG93bmxvYWRUZXN0KChwLGN1cik9PnsKICAgICAgc2V0UHJvZ3Jlc3MoMTArcCowLjgpOyBzZXRHYXVnZShjdXIpOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtYmFyJykuc3R5bGUud2lkdGg9TWF0aC5taW4oY3VyLzIwMCoxMDAsMTAwKSsnJSc7CiAgICB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkbC12YWwnKS50ZXh0Q29udGVudD1tYnBzLnRvRml4ZWQoMSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtYmFyJykuc3R5bGUud2lkdGg9TWF0aC5taW4obWJwcy8yMDAqMTAwLDEwMCkrJyUnOwogICAgc2V0R2F1Z2UobWJwcyk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtc3RhdHVzJykudGV4dENvbnRlbnQ9J+KchSBEb3dubG9hZDogJyttYnBzLnRvRml4ZWQoMSkrJyBNYnBzJzsKICB9IGVsc2UgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfguIHguLPguKXguLHguIfguJfguJTguKrguK3guJogVXBsb2FkLi4uJzsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC12YWwnKS50ZXh0Q29udGVudD0nLi4uJzsKICAgIGNvbnN0IG1icHM9YXdhaXQgcnVuVXBsb2FkVGVzdCgocCxjdXIpPT57CiAgICAgIHNldFByb2dyZXNzKDEwK3AqMC44KTsgc2V0R2F1Z2UoY3VyKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKGN1ci8yMDAqMTAwLDEwMCkrJyUnOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWwtdmFsJykudGV4dENvbnRlbnQ9bWJwcy50b0ZpeGVkKDEpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKG1icHMvMjAwKjEwMCwxMDApKyclJzsKICAgIHNldEdhdWdlKG1icHMpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfinIUgVXBsb2FkOiAnK21icHMudG9GaXhlZCgxKSsnIE1icHMnOwogIH0KICBzZXRQcm9ncmVzcygxMDApOwogIHNldFRpbWVvdXQoKCk9PnNldFByb2dyZXNzKDApLDE1MDApOwogIGJ0bkRsLmRpc2FibGVkPWZhbHNlOyBidG5VbC5kaXNhYmxlZD1mYWxzZTsKICBfc3BlZWRSdW5uaW5nPWZhbHNlOwp9CmFzeW5jIGZ1bmN0aW9uIHJ1bkRvd25sb2FkVGVzdChvblByb2dyZXNzKSB7CiAgY29uc3QgRFVSQVRJT05fTVM9ODAwMDsKICBsZXQgdG90YWxCeXRlcz0wOwogIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogIGxldCBkb25lPWZhbHNlOwogIHNldFRpbWVvdXQoKCk9Pntkb25lPXRydWU7fSxEVVJBVElPTl9NUyk7CiAgY29uc3QgQ0hVTks9MSoxMDI0KjEwMjQ7CiAgY29uc3QgcnVuPWFzeW5jKCk9PnsKICAgIHdoaWxlKCFkb25lKXsKICAgICAgdHJ5ewogICAgICAgIGNvbnN0IHVybD0naHR0cHM6Ly9zcGVlZC5jbG91ZGZsYXJlLmNvbS9fX2Rvd24/Ynl0ZXM9JytDSFVOSzsKICAgICAgICBjb25zdCByPWF3YWl0IGZldGNoKHVybCx7Y2FjaGU6J25vLXN0b3JlJ30pLmNhdGNoKGFzeW5jKCk9PmZldGNoKEFQSSsnL3N0YXR1cycse2NhY2hlOiduby1zdG9yZSd9KSk7CiAgICAgICAgY29uc3QgYnVmPWF3YWl0IHIuYXJyYXlCdWZmZXIoKTsKICAgICAgICBpZihkb25lKSBicmVhazsKICAgICAgICB0b3RhbEJ5dGVzKz1idWYuYnl0ZUxlbmd0aDsKICAgICAgICBjb25zdCBlbGFwc2VkPShwZXJmb3JtYW5jZS5ub3coKS10MCkvMTAwMDsKICAgICAgICBjb25zdCBtYnBzPSh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7CiAgICAgICAgb25Qcm9ncmVzcyhNYXRoLm1pbihlbGFwc2VkL0RVUkFUSU9OX01TKjEwMCw5OSksbWJwcyk7CiAgICAgIH1jYXRjaChlKXthd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7fQogICAgfQogIH07CiAgYXdhaXQgUHJvbWlzZS5hbGwoW3J1bigpLHJ1bigpLHJ1bigpLHJ1bigpXSk7CiAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgcmV0dXJuICh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7Cn0KYXN5bmMgZnVuY3Rpb24gcnVuVXBsb2FkVGVzdChvblByb2dyZXNzKSB7CiAgY29uc3QgRFVSQVRJT05fTVM9ODAwMDsKICBsZXQgdG90YWxCeXRlcz0wOwogIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogIGxldCBkb25lPWZhbHNlOwogIHNldFRpbWVvdXQoKCk9Pntkb25lPXRydWU7fSxEVVJBVElPTl9NUyk7CiAgY29uc3QgQ0hVTks9NTEyKjEwMjQ7CiAgY29uc3QgZGF0YT1uZXcgVWludDhBcnJheShDSFVOSyk7CiAgY3J5cHRvLmdldFJhbmRvbVZhbHVlcyhkYXRhKTsKICBjb25zdCBibG9iPW5ldyBCbG9iKFtkYXRhXSk7CiAgY29uc3QgcnVuPWFzeW5jKCk9PnsKICAgIHdoaWxlKCFkb25lKXsKICAgICAgdHJ5ewogICAgICAgIGF3YWl0IGZldGNoKCdodHRwczovL3NwZWVkLmNsb3VkZmxhcmUuY29tL19fdXAnLHttZXRob2Q6J1BPU1QnLGJvZHk6YmxvYn0pLmNhdGNoKCgpPT4KICAgICAgICAgIGZldGNoKEFQSSsnL3N0YXR1cycse21ldGhvZDonUE9TVCcsYm9keTpibG9iLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0nfX0pLmNhdGNoKCgpPT4oe29rOmZhbHNlfSkpCiAgICAgICAgKTsKICAgICAgICBpZihkb25lKSBicmVhazsKICAgICAgICB0b3RhbEJ5dGVzKz1DSFVOSzsKICAgICAgICBjb25zdCBlbGFwc2VkPShwZXJmb3JtYW5jZS5ub3coKS10MCkvMTAwMDsKICAgICAgICBjb25zdCBtYnBzPSh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7CiAgICAgICAgb25Qcm9ncmVzcyhNYXRoLm1pbihlbGFwc2VkL0RVUkFUSU9OX01TKjEwMCw5OSksbWJwcyk7CiAgICAgIH1jYXRjaChlKXthd2FpdCBuZXcgUHJvbWlzZShyPT5zZXRUaW1lb3V0KHIsMTAwKSk7fQogICAgfQogIH07CiAgYXdhaXQgUHJvbWlzZS5hbGwoW3J1bigpLHJ1bigpLHJ1bigpXSk7CiAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgcmV0dXJuICh0b3RhbEJ5dGVzKjgpLyhlbGFwc2VkKjFlNik7Cn0KCi8vIHN3KCkg4LmA4Lie4Li04LmI4LihIHNwZWVkIHRhYiBzdXBwb3J0Cgpsb2FkRGFzaCgpOwpsb2FkU2VydmljZXMoKTsKc2V0SW50ZXJ2YWwobG9hZERhc2gsIDMwMDAwKTsKPC9zY3JpcHQ+Cgo8IS0tIFNTSCBSRU5FVyBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJzc2gtcmVuZXctbW9kYWwiIG9uY2xpY2s9ImlmKGV2ZW50LnRhcmdldD09PXRoaXMpY2xvc2VTU0hSZW5ld01vZGFsKCkiPgogIDxkaXYgY2xhc3M9Im1vZGFsIj4KICAgIDxkaXYgY2xhc3M9Im1oZHIiPgogICAgICA8ZGl2IGNsYXNzPSJtdGl0bGUiPvCflIQg4LiV4LmI4Lit4Lit4Liy4Lii4Li4IFNTSCBVc2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY2xvc2VTU0hSZW5ld01vZGFsKCkiPuKclTwvYnV0dG9uPgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJkZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfkaQgVXNlcm5hbWU8L3NwYW4+PHNwYW4gY2xhc3M9ImR2IGdyZWVuIiBpZD0ic3NoLXJlbmV3LXVzZXJuYW1lIj4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZmciIHN0eWxlPSJtYXJnaW4tdG9wOjE0cHgiPgogICAgICA8ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguJXguYjguK3guK3guLLguKLguLg8L2Rpdj4KICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9InNzaC1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIiBwbGFjZWhvbGRlcj0iMzAiPgogICAgPC9kaXY+CiAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ic3NoLXJlbmV3LWJ0biIgb25jbGljaz0iZG9TU0hSZW5ldygpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgPC9kaXY+CjwvZGl2PgoKCjxzY3JpcHQ+Ci8vIEZpcmVmbGllcyB4NjAg4oCTIGluc2lkZSBjYXJkcyAoYWJzb2x1dGUsIOC5hOC4oeC5iOC5g+C4iuC5iCBmaXhlZCkKKGZ1bmN0aW9uKCl7CiAgY29uc3QgY29sb3JzPVsKICAgICcjYjVmNTQyJywnI2Q0ZmM1YScsJyM3ZmZmMDAnLCcjYWFmZjQ0JywKICAgICcjZjVmNTQyJywnI2ZmZTk0ZCcsJyNmZmQ3MDAnLCcjZmZlYzZlJywKICAgICcjYThmZjc4JywnIzc4ZmY4YScsJyM1NmZmYjAnLCcjOTBmZjZhJywKICBdOwogIGZ1bmN0aW9uIGFkZEZGKGNvbnRhaW5lciwgY291bnQpIHsKICAgIGNvbnN0IHc9Y29udGFpbmVyLm9mZnNldFdpZHRofHwyODA7CiAgICBjb25zdCBoPWNvbnRhaW5lci5vZmZzZXRIZWlnaHR8fDEyMDsKICAgIGZvciAobGV0IGk9MDtpPGNvdW50O2krKykgewogICAgICBjb25zdCBlbD1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgICAgZWwuY2xhc3NOYW1lPSdjYXJkLWZmJzsKICAgICAgY29uc3Qgc2l6ZT1NYXRoLnJhbmRvbSgpKjMrMS41OwogICAgICBjb25zdCBjb2xvcj1jb2xvcnNbTWF0aC5mbG9vcihNYXRoLnJhbmRvbSgpKmNvbG9ycy5sZW5ndGgpXTsKICAgICAgY29uc3Qgcj0oKT0+KChNYXRoLnJhbmRvbSgpLTAuNSkqTWF0aC5taW4odyxoKSowLjU1KSsncHgnOwogICAgICBjb25zdCBkRHVyPShNYXRoLnJhbmRvbSgpKjE4KzEyKS50b0ZpeGVkKDEpOwogICAgICBjb25zdCBiRHVyPShNYXRoLnJhbmRvbSgpKjMrMikudG9GaXhlZCgxKTsKICAgICAgY29uc3QgZGVsYXk9KE1hdGgucmFuZG9tKCkqMTUpLnRvRml4ZWQoMik7CiAgICAgIGVsLnN0eWxlLmNzc1RleHQ9YHdpZHRoOiR7c2l6ZX1weDtoZWlnaHQ6JHtzaXplfXB4O2ArCiAgICAgICAgYGxlZnQ6JHtNYXRoLnJhbmRvbSgpKjg4KzZ9JTt0b3A6JHtNYXRoLnJhbmRvbSgpKjg4KzZ9JTtgKwogICAgICAgIGBiYWNrZ3JvdW5kOiR7Y29sb3J9O2ArCiAgICAgICAgYGJveC1zaGFkb3c6MCAwICR7c2l6ZSoyLjV9cHggJHtzaXplKjEuNX1weCAke2NvbG9yfTg4LDAgMCAke3NpemUqNn1weCAke2NvbG9yfTQ0O2ArCiAgICAgICAgYGFuaW1hdGlvbi1kdXJhdGlvbjoke2REdXJ9cywke2JEdXJ9cztgKwogICAgICAgIGBhbmltYXRpb24tZGVsYXk6LSR7ZGVsYXl9cywtJHtkZWxheX1zO2ArCiAgICAgICAgYC0tZHgxOiR7cigpfTstLWR5MToke3IoKX07LS1keDI6JHtyKCl9Oy0tZHkyOiR7cigpfTtgKwogICAgICAgIGAtLWR4Mzoke3IoKX07LS1keTM6JHtyKCl9Oy0tZHg0OiR7cigpfTstLWR5NDoke3IoKX07YDsKICAgICAgY29udGFpbmVyLmFwcGVuZENoaWxkKGVsKTsKICAgIH0KICB9CiAgZnVuY3Rpb24gc3Bhd25BbGwoKXsKICAgIGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoJy5jYXJkLC5zYycpLmZvckVhY2goYz0+ewogICAgICBpZiAoYy5xdWVyeVNlbGVjdG9yQWxsKCcuY2FyZC1mZicpLmxlbmd0aDw4KSBhZGRGRihjLDEwKTsKICAgIH0pOwogIH0KICBzcGF3bkFsbCgpOwogIHNldFRpbWVvdXQoc3Bhd25BbGwsMjUwMCk7CiAgc2V0VGltZW91dChzcGF3bkFsbCw2MDAwKTsKfSkoKTsKPC9zY3JpcHQ+CjwvYm9keT4KPC9odG1sPgo=' | base64 -d > /opt/chaiya-panel/sshws.html
ok "Dashboard พร้อม"

# ── CERTBOT AUTO-RENEW ────────────────────────────────────────
[[ $USE_SSL -eq 1 ]] && \
  (crontab -l 2>/dev/null; echo "0 3 * * * systemctl stop haproxy nginx && certbot renew --quiet --standalone && systemctl start nginx haproxy") | sort -u | crontab -

# ── MENU COMMAND ─────────────────────────────────────────────
cat > /usr/local/bin/menu << 'MENUEOF'
#!/bin/bash
G='\033[1;32m' C='\033[1;36m' Y='\033[1;33m' R='\033[0;31m' N='\033[0m'
DOMAIN=$(cat /etc/chaiya/domain.conf 2>/dev/null || echo "")
PANEL_DOMAIN=$(cat /etc/chaiya/panel-domain.conf 2>/dev/null || echo "")
USE_PANEL_SSL=$(cat /etc/chaiya/panel-ssl.conf 2>/dev/null || echo "0")
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
if [[ "$USE_PANEL_SSL" == "1" && -n "$PANEL_DOMAIN" ]]; then
  echo -e "  Dashboard   : ${C}https://$PANEL_DOMAIN${N} (ไม่โชว์พอร์ต)"
else
  echo -e "  Dashboard   : ${C}https://$DOMAIN:8443${N}"
fi
echo -e "  3x-ui Port  : ${C}$XUI_PORT${N}"
echo -e "  3x-ui User  : ${Y}$XUI_USER${N}"
echo ""
echo -e "  Dropbear SSH   : ${C}143, 109${N}"
echo -e "  SSH-WS         : ${C}HAProxy:80 → Nginx:8880 → npxproxy:8080${N}"
echo -e "  VLESS-WS       : ${C}HAProxy:80 → Nginx:8880 → Xray:18080 /vless${N}"
echo -e "  SSH-TLS/VLESS-TLS: ${C}HAProxy:443 → Xray:24443${N}"
echo -e "  BadVPN UDPGW   : ${C}7300${N}"
echo -e "  ZiVPN (UDP)    : ${C}5667${N}"
echo -e "  UDP Custom     : ${C}36712${N}"
echo ""
echo -e "  ┌─ Services ───────────────────────────────────┐"
for svc in nginx haproxy x-ui dropbear chaiya-npxproxy chaiya-ssh-api chaiya-badvpn zivpn; do
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
            _, ws,  _       = run_cmd("systemctl is-active chaiya-npxproxy")
            _, svc_haproxy, _ = run_cmd("systemctl is-active haproxy")
            _, svc_zivpn, _   = run_cmd("systemctl is-active zivpn")
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
                    'haproxy':  svc_haproxy.strip() == 'active',
                    'zivpn':    svc_zivpn.strip() == 'active',
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
                _sp_bin = '/usr/local/bin/speedtest-ookla'
                _sp_env = {**os.environ, 'HOME': '/root'}
                if not os.path.exists(_sp_bin):
                    respond(self, 200, {'ok': False, 'error': 'ookla speedtest not installed'})
                else:
                    r2 = subprocess.run([_sp_bin,'--format=json','--accept-license','--accept-gdpr'], capture_output=True, text=True, timeout=60, env=_sp_env)
                    if r2.returncode == 0 and r2.stdout.strip():
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
                        respond(self, 200, {'ok': False, 'error': (r2.stderr or 'speedtest failed').strip()[:200]})
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
PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+CjxzdHlsZT4KICA6cm9vdCB7CiAgICAtLWFjOiAjMjJjNTVlOyAtLWFjLWdsb3c6IHJnYmEoMzQsMTk3LDk0LDAuMjUpOyAtLWFjLWRpbTogcmdiYSgzNCwxOTcsOTQsMC4wOCk7CiAgICAtLWFjLWJvcmRlcjogcmdiYSgzNCwxOTcsOTQsMC4yNSk7IC0tbmc6ICMyMmM1NWU7IC0tbmctZ2xvdzogcmdiYSgzNCwxOTcsOTQsMC4yKTsKICAgIC0tYmc6ICNmMGYyZjU7IC0tY2FyZDogI2ZmZmZmZjsgLS10eHQ6ICMxZTI5M2I7IC0tbXV0ZWQ6ICM2NDc0OGI7CiAgICAtLWJvcmRlcjogI2UyZThmMDsgLS1zaGFkb3c6IDAgMnB4IDEycHggcmdiYSgwLDAsMCwwLjA3KTsKICB9CiAgKnttYXJnaW46MDtwYWRkaW5nOjA7Ym94LXNpemluZzpib3JkZXItYm94O30KICBib2R5e2JhY2tncm91bmQ6dmFyKC0tYmcpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO2NvbG9yOnZhcigtLXR4dCk7bWluLWhlaWdodDoxMDB2aDtvdmVyZmxvdy14OmhpZGRlbjt9CiAgLndyYXB7bWF4LXdpZHRoOjQ4MHB4O21hcmdpbjowIGF1dG87cGFkZGluZy1ib3R0b206NTBweDt9CiAgLmhkcntiYWNrZ3JvdW5kOnJhZGlhbC1ncmFkaWVudChlbGxpcHNlIDgwJSA2MCUgYXQgMjAlIDIwJSxyZ2JhKDEyNCw1OCwyMzcsMC4yNSkgMCUsdHJhbnNwYXJlbnQgNjAlKSxyYWRpYWwtZ3JhZGllbnQoZWxsaXBzZSA2MCUgNTAlIGF0IDgwJSA4MCUscmdiYSgzNyw5OSwyMzUsMC4yKSAwJSx0cmFuc3BhcmVudCA2MCUpLGxpbmVhci1ncmFkaWVudCgxNjBkZWcsIzAzMDUwZiAwJSwjMDgwZDFmIDUwJSwjMDUwODEwIDEwMCUpO3BhZGRpbmc6MjBweCAyMHB4IDE4cHg7dGV4dC1hbGlnbjpjZW50ZXI7cG9zaXRpb246cmVsYXRpdmU7b3ZlcmZsb3c6aGlkZGVuO30KICAuaGRyOjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDtyaWdodDowO2hlaWdodDoxcHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsdHJhbnNwYXJlbnQscmdiYSgxOTIsMTMyLDI1MiwwLjYpLHRyYW5zcGFyZW50KTt9CiAgLmhkci1zdWJ7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6cmdiYSgxOTIsMTMyLDI1MiwwLjcpO21hcmdpbi1ib3R0b206NnB4O30KICAuaGRyLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToyNnB4O2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOjJweDt9CiAgLmhkci10aXRsZSBzcGFue2NvbG9yOiNjMDg0ZmM7fQogIC5oZHItZGVzY3ttYXJnaW4tdG9wOjZweDtmb250LXNpemU6MTFweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNDUpO2xldHRlci1zcGFjaW5nOjJweDt9CiAgLmxvZ291dHtwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MTZweDtyaWdodDoxNHB4O2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA3KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4xNSk7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo1cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuNik7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7fQoKCgoKICAvKiBOQVYgcGlsbCBzdHlsZSAqLwogIC5uYXYtd3JhcHtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxODBkZWcsIzA4MGQxZiAwJSwjMGMxNDI4IDEwMCUpO3BhZGRpbmc6MTBweCAxMHB4IDA7cG9zaXRpb246c3RpY2t5O3RvcDowO3otaW5kZXg6OTk5OTtib3JkZXItYm90dG9tOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO2JveC1zaGFkb3c6MCA0cHggMjBweCByZ2JhKDAsMCwwLDAuMyk7b3ZlcmZsb3c6aGlkZGVuO30KICAubmF2LWZme3Bvc2l0aW9uOmFic29sdXRlO2JvcmRlci1yYWRpdXM6NTAlO3BvaW50ZXItZXZlbnRzOm5vbmU7YW5pbWF0aW9uOm5mZi1kcmlmdCBsaW5lYXIgaW5maW5pdGUsbmZmLWJsaW5rIGVhc2UtaW4tb3V0IGluZmluaXRlO29wYWNpdHk6MDt6LWluZGV4OjE7fQogIEBrZXlmcmFtZXMgbmZmLWRyaWZ0ewogICAgMCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSgwLDApfQogICAgMjUle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKX0KICAgIDUwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MiksdmFyKC0tZHkyKSl9CiAgICA3NSV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDMpLHZhcigtLWR5MykpfQogICAgMTAwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKDAsMCl9CiAgfQogIEBrZXlmcmFtZXMgbmZmLWJsaW5rewogICAgMCUsMTAwJXtvcGFjaXR5OjB9CiAgICAzMCV7b3BhY2l0eToxfQogICAgNTAle29wYWNpdHk6MC44NX0KICAgIDcwJXtvcGFjaXR5OjB9CiAgfQogIC8qIGR1cGxpY2F0ZSBrZXlmcmFtZXMgcmVtb3ZlZCAqLwogIC5uYXZ7ZGlzcGxheTpmbGV4O2dhcDo0cHg7b3ZlcmZsb3cteDphdXRvO3Njcm9sbGJhci13aWR0aDpub25lO3BhZGRpbmctYm90dG9tOjEwcHg7fQogIC5uYXY6Oi13ZWJraXQtc2Nyb2xsYmFye2Rpc3BsYXk6bm9uZTt9CiAgLm5hdi1pdGVte2ZsZXgtc2hyaW5rOjA7cGFkZGluZzo4cHggMTRweDtmb250LXNpemU6MTFweDtmb250LXdlaWdodDo3MDA7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQpO3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3doaXRlLXNwYWNlOm5vd3JhcDtib3JkZXItcmFkaXVzOjk5OXB4O2JvcmRlcjoxLjVweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpO2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA0KTt0cmFuc2l0aW9uOmFsbCAwLjIycyBjdWJpYy1iZXppZXIoLjM0LDEuNTYsLjY0LDEpO2xldHRlci1zcGFjaW5nOjAuM3B4O2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO30KICAubmF2LWl0ZW06aG92ZXI6bm90KC5hY3RpdmUpe2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC43KTtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsMC4wOCk7Ym9yZGVyLWNvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4xOCk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5uYXYtaXRlbS5hY3RpdmV7Y29sb3I6I2ZmZjtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzIyYzU1ZSwjMTZhMzRhKTtib3JkZXItY29sb3I6dHJhbnNwYXJlbnQ7Ym94LXNoYWRvdzowIDRweCAyMHB4IHJnYmEoMzQsMTk3LDk0LDAuNSksMCAycHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMjUpIGluc2V0O3RyYW5zZm9ybTp0cmFuc2xhdGVZKC0ycHgpO2JvcmRlci1yYWRpdXM6OTk5cHg7fQogIC5uYXYtaXRlbS5uYXYtc3BlZWQuYWN0aXZle2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMDZiNmQ0LCMwODkxYjIpO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDYsMTgyLDIxMiwwLjQpLDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjIpIGluc2V0O30KICAubmF2LWl0ZW0ubmF2LXNwZWVkOmhvdmVyOm5vdCguYWN0aXZlKXtjb2xvcjojMDZiNmQ0O2JvcmRlci1jb2xvcjpyZ2JhKDYsMTgyLDIxMiwwLjMpO30KICAuc2Vje3BhZGRpbmc6MTRweDtkaXNwbGF5Om5vbmU7YW5pbWF0aW9uOmZpIC4zcyBlYXNlO30KICAuc2VjLmFjdGl2ZXtkaXNwbGF5OmJsb2NrO30KICBAa2V5ZnJhbWVzIGZpe2Zyb217b3BhY2l0eTowO3RyYW5zZm9ybTp0cmFuc2xhdGVZKDZweCl9dG97b3BhY2l0eToxO3RyYW5zZm9ybTp0cmFuc2xhdGVZKDApfX0KICAuY2FyZHtiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzoxNnB4O21hcmdpbi1ib3R0b206MTBweDtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47Ym94LXNoYWRvdzp2YXIoLS1zaGFkb3cpO30KICAuc2VjLWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNlYy10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuYnRuLXJ7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjZweCAxNHB4O2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5idG4tcjpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLnNncmlke2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjEwcHg7fQogIC5zY3tiYWNrZ3JvdW5kOnZhcigtLWNhcmQpO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzoxNHB4O3Bvc2l0aW9uOnJlbGF0aXZlO292ZXJmbG93OmhpZGRlbjtib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7fQogIC5zbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjhweDt9CiAgLnN2YWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjI0cHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7bGluZS1oZWlnaHQ6MTt9CiAgLnN2YWwgc3Bhbntmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC13ZWlnaHQ6NDAwO30KICAuc3N1Yntmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDo0cHg7fQogIC5kbnV0e3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjUycHg7aGVpZ2h0OjUycHg7bWFyZ2luOjRweCBhdXRvIDRweDt9CiAgLmRudXQgc3Zne3RyYW5zZm9ybTpyb3RhdGUoLTkwZGVnKTt9CiAgLmRiZ3tmaWxsOm5vbmU7c3Ryb2tlOnJnYmEoMCwwLDAsMC4wNik7c3Ryb2tlLXdpZHRoOjQ7fQogIC5kdntmaWxsOm5vbmU7c3Ryb2tlLXdpZHRoOjQ7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAxcyBlYXNlO30KICAuZGN7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5wYntoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdiYSgwLDAsMCwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW47fQogIC5wZntoZWlnaHQ6MTAwJTtib3JkZXItcmFkaXVzOjJweDt0cmFuc2l0aW9uOndpZHRoIDFzIGVhc2U7fQogIC5wZi5wdXtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1hYyksIzE2YTM0YSk7fQogIC5wZi5wZ3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx2YXIoLS1uZyksIzE2YTM0YSk7fQogIC5wZi5wb3tiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjZmI5MjNjLCNmOTczMTYpO30KICAucGYucHJ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2VmNDQ0NCwjZGMyNjI2KTt9CiAgLnViZGd7ZGlzcGxheTpmbGV4O2dhcDo1cHg7ZmxleC13cmFwOndyYXA7bWFyZ2luLXRvcDo4cHg7fQogIC5iZGd7YmFja2dyb3VuZDojZjFmNWY5O2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjZweDtwYWRkaW5nOjNweCA4cHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO30KICAubmV0LXJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Z2FwOjEycHg7bWFyZ2luLXRvcDoxMHB4O30KICAubml7ZmxleDoxO30KICAubmR7Zm9udC1zaXplOjExcHg7Y29sb3I6dmFyKC0tYWMpO21hcmdpbi1ib3R0b206M3B4O30KICAubnN7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjIwcHg7Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5ucyBzcGFue2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTtmb250LXdlaWdodDo0MDA7fQogIC5udHtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDoycHg7fQogIC5kaXZpZGVye3dpZHRoOjFweDtiYWNrZ3JvdW5kOnZhcigtLWJvcmRlcik7bWFyZ2luOjRweCAwO30KICAub3BpbGx7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4zKTtib3JkZXItcmFkaXVzOjIwcHg7cGFkZGluZzo1cHggMTRweDtmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1uZyk7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjVweDt3aGl0ZS1zcGFjZTpub3dyYXA7fQogIC5vcGlsbC5vZmZ7YmFja2dyb3VuZDpyZ2JhKDIzOSw2OCw2OCwwLjEpO2JvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwwLjMpO2NvbG9yOiNlZjQ0NDQ7fQogIC5kb3R7d2lkdGg6NXB4O2hlaWdodDo1cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDp2YXIoLS1uZyk7Ym94LXNoYWRvdzowIDAgM3B4IHZhcigtLW5nKTthbmltYXRpb246cGxzIDRzIGVhc2UtaW4tb3V0IGluZmluaXRlO30KICAuZG90LnJlZHtiYWNrZ3JvdW5kOiNlZjQ0NDQ7Ym94LXNoYWRvdzowIDAgNHB4ICNlZjQ0NDQ7fQogIEBrZXlmcmFtZXMgcGxzezAlLDEwMCV7b3BhY2l0eTouOTtib3gtc2hhZG93OjAgMCAycHggdmFyKC0tbmcpfTUwJXtvcGFjaXR5Oi42O2JveC1zaGFkb3c6MCAwIDRweCB2YXIoLS1uZyl9fQogIC54dWktcm93e2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjEycHg7bWFyZ2luLXRvcDoxMHB4O30KICAueHVpLWluZm97Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO2xpbmUtaGVpZ2h0OjEuNzt9CiAgLnh1aS1pbmZvIGJ7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnN2Yy1saXN0e2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjhweDttYXJnaW4tdG9wOjEwcHg7fQogIC5zdmN7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjA1KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMzQsMTk3LDk0LDAuMik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTFweCAxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47fQogIC5zdmMuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMDUpO2JvcmRlci1jb2xvcjpyZ2JhKDIzOSw2OCw2OCwwLjIpO30KICAuc3ZjLWx7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweDt9CiAgLyogLmRnIHN0eWxlcyBkZWZpbmVkIGJlbG93IHdpdGggcGluZyBhbmltYXRpb24gKi8KICAuZGcucmVke2JhY2tncm91bmQ6I2VmNDQ0NDtib3gtc2hhZG93OjAgMCA0cHggI2VmNDQ0NDt9CiAgLnN2Yy1ue2ZvbnQtc2l6ZToxM3B4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO30KICAuc3ZjLXB7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAucmJkZ3tiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwwLjMpO2JvcmRlci1yYWRpdXM6NnB4O3BhZGRpbmc6M3B4IDEwcHg7Zm9udC1zaXplOjEwcHg7Y29sb3I6dmFyKC0tbmcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjFweDt9CiAgLnJiZGcuZG93bntiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMSk7Ym9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LDAuMyk7Y29sb3I6I2VmNDQ0NDt9CiAgLmx1e3RleHQtYWxpZ246Y2VudGVyO2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjE0cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7bGV0dGVyLXNwYWNpbmc6MXB4O30KICAuZnRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxMXB4O2xldHRlci1zcGFjaW5nOjJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjhweDt9CiAgLmluZm8tYm94e2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czo4cHg7cGFkZGluZzo4cHggMTJweDtmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucHRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5wYnRue2ZsZXg6MTtwYWRkaW5nOjlweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7YmFja2dyb3VuZDojZjhmYWZjO2NvbG9yOnZhcigtLW11dGVkKTtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7fQogIC5wYnRuLmFjdGl2ZXtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtjb2xvcjp2YXIoLS1hYyk7fQogIC5mZ3ttYXJnaW4tYm90dG9tOjEycHg7fQogIC5mbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6MnB4O2NvbG9yOnZhcigtLW11dGVkKTtvcGFjaXR5Oi44O21hcmdpbi1ib3R0b206NXB4O30KICAuZml7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOiNmOGZhZmM7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6OXB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO3RyYW5zaXRpb246Ym9yZGVyLWNvbG9yIC4yczt9CiAgLmZpOmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7Ym94LXNoYWRvdzowIDAgMCAzcHggdmFyKC0tYWMtZGltKTt9CiAgLnRnbHtkaXNwbGF5OmZsZXg7Z2FwOjhweDt9CiAgLnRidG57ZmxleDoxO3BhZGRpbmc6OXB4O2JvcmRlci1yYWRpdXM6OHB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtiYWNrZ3JvdW5kOiNmOGZhZmM7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnRidG4uYWN0aXZle2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtib3JkZXItY29sb3I6dmFyKC0tYWMpO2NvbG9yOnZhcigtLWFjKTt9CiAgLmNidG57d2lkdGg6MTAwJTtwYWRkaW5nOjE0cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2ZvbnQtc2l6ZToxNHB4O2ZvbnQtd2VpZ2h0OjcwMDtjdXJzb3I6cG9pbnRlcjtib3JkZXI6bm9uZTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzE2YTM0YSwjMjJjNTVlLCM0YWRlODApO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7bGV0dGVyLXNwYWNpbmc6LjVweDtib3gtc2hhZG93OjAgNHB4IDE1cHggcmdiYSgzNCwxOTcsOTQsLjMpO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLmNidG46aG92ZXJ7Ym94LXNoYWRvdzowIDZweCAyMHB4IHJnYmEoMzQsMTk3LDk0LC40NSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCk7fQogIC5jYnRuOmRpc2FibGVke29wYWNpdHk6LjU7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc2JveHt3aWR0aDoxMDAlO2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnZhcigtLXR4dCk7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7b3V0bGluZTpub25lO21hcmdpbi1ib3R0b206MTJweDt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5zYm94OmZvY3Vze2JvcmRlci1jb2xvcjp2YXIoLS1hYyk7fQogIC51aXRlbXtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEycHggMTRweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO21hcmdpbi1ib3R0b206OHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OjAgMXB4IDRweCByZ2JhKDAsMCwwLDAuMDQpO30KICAudWl0ZW06aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7fQogIC51YXZ7d2lkdGg6MzZweDtoZWlnaHQ6MzZweDtib3JkZXItcmFkaXVzOjlweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1yaWdodDoxMnB4O2ZsZXgtc2hyaW5rOjA7fQogIC5hdi1ne2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsMC4xNSk7Y29sb3I6dmFyKC0tbmcpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjIpO30KICAuYXYtcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsMC4xNSk7Y29sb3I6I2Y4NzE3MTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjQ4LDExMywxMTMsLjIpO30KICAuYXYteHtiYWNrZ3JvdW5kOnJnYmEoMjM5LDY4LDY4LDAuMTIpO2NvbG9yOiNlZjQ0NDQ7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDIzOSw2OCw2OCwuMik7fQogIC51bntmb250LXNpemU6MTNweDtmb250LXdlaWdodDo2MDA7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLnVte2ZvbnQtc2l6ZToxMXB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tdG9wOjJweDt9CiAgLmFiZGd7Ym9yZGVyLXJhZGl1czo2cHg7cGFkZGluZzozcHggMTBweDtmb250LXNpemU6MTBweDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTt9CiAgLmFiZGcub2t7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwwLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgzNCwxOTcsOTQsLjMpO2NvbG9yOnZhcigtLW5nKTt9CiAgLmFiZGcuZXhwe2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsMC4xKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjM5LDY4LDY4LC4zKTtjb2xvcjojZWY0NDQ0O30KICAuYWJkZy5zb29ue2JhY2tncm91bmQ6cmdiYSgyNTEsMTQ2LDYwLDAuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDI1MSwxNDYsNjAsLjMpO2NvbG9yOiNmOTczMTY7fQogIC5tb3Zlcntwb3NpdGlvbjpmaXhlZDtpbnNldDowO2JhY2tncm91bmQ6cmdiYSgwLDAsMCwuNSk7YmFja2Ryb3AtZmlsdGVyOmJsdXIoNnB4KTt6LWluZGV4Ojk5OTk7ZGlzcGxheTpub25lO2FsaWduLWl0ZW1zOmZsZXgtZW5kO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogIC5tb3Zlci5vcGVue2Rpc3BsYXk6ZmxleDt9CiAgLm1vZGFse2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoyMHB4IDIwcHggMCAwO3dpZHRoOjEwMCU7bWF4LXdpZHRoOjQ4MHB4O3BhZGRpbmc6MjBweDttYXgtaGVpZ2h0Ojg1dmg7b3ZlcmZsb3cteTphdXRvO2FuaW1hdGlvbjpzdSAuM3MgZWFzZTtib3gtc2hhZG93OjAgLTRweCAzMHB4IHJnYmEoMCwwLDAsMC4xMik7fQogIEBrZXlmcmFtZXMgc3V7ZnJvbXt0cmFuc2Zvcm06dHJhbnNsYXRlWSgxMDAlKX10b3t0cmFuc2Zvcm06dHJhbnNsYXRlWSgwKX19CiAgLm1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjttYXJnaW4tYm90dG9tOjE2cHg7fQogIC5tdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjE0cHg7Y29sb3I6dmFyKC0tdHh0KTt9CiAgLm1jbG9zZXt3aWR0aDozMnB4O2hlaWdodDozMnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6I2YxZjVmOTtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Y29sb3I6dmFyKC0tbXV0ZWQpO2N1cnNvcjpwb2ludGVyO2ZvbnQtc2l6ZToxNnB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjt9CiAgLmRncmlke2JhY2tncm91bmQ6I2Y4ZmFmYztib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4O21hcmdpbi1ib3R0b206MTRweDtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5kcntkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6N3B4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgdmFyKC0tYm9yZGVyKTt9CiAgLmRyOmxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRvbTpub25lO30KICAuZGt7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO30KICAuZHZ7Zm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tdHh0KTtmb250LXdlaWdodDo2MDA7fQogIC5kdi5ncmVlbntjb2xvcjp2YXIoLS1uZyk7fQogIC5kdi5yZWR7Y29sb3I6I2VmNDQ0NDt9CiAgLmR2Lm1vbm97Y29sb3I6dmFyKC0tYWMpO2ZvbnQtc2l6ZTo5cHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7d29yZC1icmVhazpicmVhay1hbGw7fQogIC5hZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDt9CiAgLm0tc3Vie2Rpc3BsYXk6bm9uZTttYXJnaW4tdG9wOjE0cHg7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxNHB4O30KICAubS1zdWIub3BlbntkaXNwbGF5OmJsb2NrO2FuaW1hdGlvbjpmaSAuMnMgZWFzZTt9CiAgLm1zdWItbGJse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjYwMDtjb2xvcjp2YXIoLS10eHQpO21hcmdpbi1ib3R0b206MTBweDt9CiAgLmFidG57YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjEwcHg7cGFkZGluZzoxNHB4IDEwcHg7dGV4dC1hbGlnbjpjZW50ZXI7Y3Vyc29yOnBvaW50ZXI7dHJhbnNpdGlvbjphbGwgLjJzO30KICAuYWJ0bjpob3ZlcntiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTt9CiAgLmFidG4gLmFpe2ZvbnQtc2l6ZToyMnB4O21hcmdpbi1ib3R0b206NnB4O30KICAuYWJ0biAuYW57Zm9udC1zaXplOjEycHg7Zm9udC13ZWlnaHQ6NjAwO2NvbG9yOnZhcigtLXR4dCk7fQogIC5hYnRuIC5hZHtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLXRvcDoycHg7fQogIC5hYnRuLmRhbmdlcjpob3ZlcntiYWNrZ3JvdW5kOnJnYmEoMjQ4LDExMywxMTMsLjEpO2JvcmRlci1jb2xvcjojZjg3MTcxO30KICAub2V7dGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzo0MHB4IDIwcHg7fQogIC5vZSAuZWl7Zm9udC1zaXplOjQ4cHg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAub2UgcHtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEzcHg7fQogIC5vY3J7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjE2cHg7fQogIC51dHtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7fQogIC8qIHJlc3VsdCBib3ggKi8KICAucmVzLWJveHtwb3NpdGlvbjpyZWxhdGl2ZTtiYWNrZ3JvdW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xpZCAjODZlZmFjO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjE0cHg7bWFyZ2luLXRvcDoxNHB4O2Rpc3BsYXk6bm9uZTt9CiAgLnJlcy1ib3guc2hvd3tkaXNwbGF5OmJsb2NrO30KICAucmVzLWNsb3Nle3Bvc2l0aW9uOmFic29sdXRlO3RvcDotMTFweDtyaWdodDotMTFweDt3aWR0aDoyMnB4O2hlaWdodDoyMnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6I2VmNDQ0NDtib3JkZXI6MnB4IHNvbGlkICNmZmY7Y29sb3I6I2ZmZjtjdXJzb3I6cG9pbnRlcjtmb250LXNpemU6MTFweDtmb250LXdlaWdodDo3MDA7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2xpbmUtaGVpZ2h0OjE7Ym94LXNoYWRvdzowIDFweCA0cHggcmdiYSgyMzksNjgsNjgsMC40KTt6LWluZGV4OjI7fQogIC5yZXMtcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjtwYWRkaW5nOjVweCAwO2JvcmRlci1ib3R0b206MXB4IHNvbGlkICNkY2ZjZTc7Zm9udC1zaXplOjEzcHg7fQogIC5yZXMtcm93Omxhc3QtY2hpbGR7Ym9yZGVyLWJvdHRvbTpub25lO30KICAucmVzLWt7Y29sb3I6dmFyKC0tbXV0ZWQpO2ZvbnQtc2l6ZToxMXB4O30KICAucmVzLXZ7Y29sb3I6dmFyKC0tdHh0KTtmb250LXdlaWdodDo2MDA7d29yZC1icmVhazpicmVhay1hbGw7dGV4dC1hbGlnbjpyaWdodDttYXgtd2lkdGg6NjUlO30KICAucmVzLWxpbmt7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlcjoxcHggc29saWQgdmFyKC0tYm9yZGVyKTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxMHB4O2ZvbnQtc2l6ZToxMHB4O2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO3dvcmQtYnJlYWs6YnJlYWstYWxsO21hcmdpbi10b3A6OHB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmNvcHktYnRue3dpZHRoOjEwMCU7bWFyZ2luLXRvcDo4cHg7cGFkZGluZzo4cHg7Ym9yZGVyLXJhZGl1czo4cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1hYy1ib3JkZXIpO2JhY2tncm91bmQ6dmFyKC0tYWMtZGltKTtjb2xvcjp2YXIoLS1hYyk7Zm9udC1zaXplOjEycHg7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7fQogIC8qIGFsZXJ0ICovCiAgLmFsZXJ0e2Rpc3BsYXk6bm9uZTtwYWRkaW5nOjEwcHggMTRweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTJweDttYXJnaW4tdG9wOjEwcHg7fQogIC5hbGVydC5va3tiYWNrZ3JvdW5kOiNmMGZkZjQ7Ym9yZGVyOjFweCBzb2xpZCAjODZlZmFjO2NvbG9yOiMxNTgwM2Q7fQogIC5hbGVydC5lcnJ7YmFja2dyb3VuZDojZmVmMmYyO2JvcmRlcjoxcHggc29saWQgI2ZjYTVhNTtjb2xvcjojZGMyNjI2O30KICAvKiBzcGlubmVyICovCiAgLnNwaW57ZGlzcGxheTppbmxpbmUtYmxvY2s7d2lkdGg6MTJweDtoZWlnaHQ6MTJweDtib3JkZXI6MnB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjMpO2JvcmRlci10b3AtY29sb3I6I2ZmZjtib3JkZXItcmFkaXVzOjUwJTthbmltYXRpb246c3AgLjdzIGxpbmVhciBpbmZpbml0ZTt2ZXJ0aWNhbC1hbGlnbjptaWRkbGU7bWFyZ2luLXJpZ2h0OjRweDt9CiAgQGtleWZyYW1lcyBzcHt0b3t0cmFuc2Zvcm06cm90YXRlKDM2MGRlZyl9fQogIC5sb2FkaW5ne3RleHQtYWxpZ246Y2VudGVyO3BhZGRpbmc6MzBweDtjb2xvcjp2YXIoLS1tdXRlZCk7Zm9udC1zaXplOjEzcHg7fQoKCiAgLyog4pSA4pSAIERBUksgRk9STSAoU1NIKSDilIDilIAgKi8KICAuc3NoLWRhcmstZm9ybXtiYWNrZ3JvdW5kOiMwZDExMTc7Ym9yZGVyLXJhZGl1czoxNnB4O3BhZGRpbmc6MThweCAxNnB4O21hcmdpbi1ib3R0b206MDt9CiAgLmRhcmstZmllbGR7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuZGFyay1sYWJlbHtmb250LXNpemU6MTFweDtjb2xvcjpyZ2JhKDE4MCwyMjAsMjU1LC41KTtsZXR0ZXItc3BhY2luZzoxcHg7ZGlzcGxheTpibG9jazttYXJnaW4tYm90dG9tOjVweDt9CiAgLmRhcmstaW5wdXR7d2lkdGg6MTAwJTtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA2KTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2NvbG9yOiNlOGY0ZmY7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2ZvbnQtZmFtaWx5OidTYXJhYnVuJyxzYW5zLXNlcmlmO291dGxpbmU6bm9uZTt0cmFuc2l0aW9uOmJvcmRlci1jb2xvciAuMnM7fQogIC5kYXJrLWlucHV0OmZvY3Vze2JvcmRlci1jb2xvcjpyZ2JhKDAsMjAwLDI1NSwuNSk7Ym94LXNoYWRvdzowIDAgMCAzcHggcmdiYSgwLDIwMCwyNTUsLjA4KTt9CiAgLmRhcmstaGRye2ZvbnQtc2l6ZToxM3B4O2NvbG9yOnJnYmEoMCwyMDAsMjU1LC44KTtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtsZXR0ZXItc3BhY2luZzoycHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAuc3NoLWRhcmstZm9ybSAuZmcgLmZsYmx7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuNSk7Zm9udC1zaXplOjlweDt9CiAgLnNzaC1kYXJrLWZvcm0gLmZpe2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwuMDYpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMSk7Y29sb3I6I2U4ZjRmZjtib3JkZXItcmFkaXVzOjEwcHg7fQogIC5zc2gtZGFyay1mb3JtIC5maTpmb2N1c3tib3JkZXItY29sb3I6cmdiYSgwLDIwMCwyNTUsLjUpO2JveC1zaGFkb3c6MCAwIDAgM3B4IHJnYmEoMCwyMDAsMjU1LC4wOCk7fQogIC5zc2gtZGFyay1mb3JtIC5maTo6cGxhY2Vob2xkZXJ7Y29sb3I6cmdiYSgxODAsMjIwLDI1NSwuMjUpO30KICAuZGFyay1sYmx7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgwLDIwMCwyNTUsLjcpO2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2xldHRlci1zcGFjaW5nOjJweDttYXJnaW4tYm90dG9tOjEwcHg7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6NnB4O30KICAvKiBQb3J0IHBpY2tlciAqLwogIC5wb3J0LWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyO2dhcDo4cHg7bWFyZ2luLWJvdHRvbToxNHB4O30KICAucG9ydC1idG57YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LC4wNCk7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsLjEpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjE0cHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBvcnQtYnRuIC5wYi1pY29ue2ZvbnQtc2l6ZToxLjRyZW07bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5wb3J0LWJ0biAucGItbmFtZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDttYXJnaW4tYm90dG9tOjJweDt9CiAgLnBvcnQtYnRuIC5wYi1zdWJ7Zm9udC1zaXplOjEwcHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwuMzUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MHtib3JkZXItY29sb3I6IzAwY2NmZjtiYWNrZ3JvdW5kOnJnYmEoMCwyMDAsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTJweCByZ2JhKDAsMjAwLDI1NSwuMTUpO30KICAucG9ydC1idG4uYWN0aXZlLXA4MCAucGItbmFtZXtjb2xvcjojMDBjY2ZmO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDN7Ym9yZGVyLWNvbG9yOiNmYmJmMjQ7YmFja2dyb3VuZDpyZ2JhKDI1MSwxOTEsMzYsLjA4KTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjUxLDE5MSwzNiwuMTIpO30KICAucG9ydC1idG4uYWN0aXZlLXA0NDMgLnBiLW5hbWV7Y29sb3I6I2ZiYmYyNDt9CiAgLyogT3BlcmF0b3IgcGlja2VyICovCiAgLnBpY2stZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjhweDttYXJnaW4tYm90dG9tOjE0cHg7fQogIC5waWNrLW9wdHtiYWNrZ3JvdW5kOnJnYmEoMjU1LDI1NSwyNTUsLjA0KTtib3JkZXI6MS41cHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwuMDgpO2JvcmRlci1yYWRpdXM6MTJweDtwYWRkaW5nOjEycHggOHB4O3RleHQtYWxpZ246Y2VudGVyO2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4yczt9CiAgLnBpY2stb3B0IC5waXtmb250LXNpemU6MS41cmVtO21hcmdpbi1ib3R0b206NHB4O30KICAucGljay1vcHQgLnBue2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouN3JlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbToycHg7fQogIC5waWNrLW9wdCAucHN7Zm9udC1zaXplOjlweDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LC4zKTt9CiAgLnBpY2stb3B0LmEtZHRhY3tib3JkZXItY29sb3I6I2ZmNjYwMDtiYWNrZ3JvdW5kOnJnYmEoMjU1LDEwMiwwLC4xKTtib3gtc2hhZG93OjAgMCAxMHB4IHJnYmEoMjU1LDEwMiwwLC4xNSk7fQogIC5waWNrLW9wdC5hLWR0YWMgLnBue2NvbG9yOiNmZjg4MzM7fQogIC5waWNrLW9wdC5hLXRydWV7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMSk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDAsMjAwLDI1NSwuMTIpO30KICAucGljay1vcHQuYS10cnVlIC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1ucHZ7Ym9yZGVyLWNvbG9yOiMwMGNjZmY7YmFja2dyb3VuZDpyZ2JhKDAsMjAwLDI1NSwuMDgpO2JveC1zaGFkb3c6MCAwIDEwcHggcmdiYSgwLDIwMCwyNTUsLjEyKTt9CiAgLnBpY2stb3B0LmEtbnB2IC5wbntjb2xvcjojMDBjY2ZmO30KICAucGljay1vcHQuYS1kYXJre2JvcmRlci1jb2xvcjojY2M2NmZmO2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wOCk7Ym94LXNoYWRvdzowIDAgMTBweCByZ2JhKDE1Myw1MSwyNTUsLjEpO30KICAucGljay1vcHQuYS1kYXJrIC5wbntjb2xvcjojY2M2NmZmO30KICAucGljay1vcHQuYS1oaXtib3JkZXItY29sb3I6I2NjMDBmZjtiYWNrZ3JvdW5kOnJnYmEoMjA0LDAsMjU1LC4xKTtib3gtc2hhZG93OjAgMCAxMnB4IHJnYmEoMjA0LDAsMjU1LC4yKTt9CiAgLnBpY2stb3B0LmEtaGkgLnBue2NvbG9yOiNkZDQ0ZmY7fQogIC5waWNrLW9wdC5hLWhje2JvcmRlci1jb2xvcjojMDA5OWZmO2JhY2tncm91bmQ6cmdiYSgwLDE1MywyNTUsLjEpO2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgwLDE1MywyNTUsLjIpO30KICAucGljay1vcHQuYS1oYyAucG57Y29sb3I6IzMzYWFmZjt9CiAgLnBpY2stb3B0LmEtaGF0e2JvcmRlci1jb2xvcjojZmZjYzAwO2JhY2tncm91bmQ6cmdiYSgyNTUsMjA0LDAsLjEpO2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgyNTUsMjA0LDAsLjIpO30KICAucGljay1vcHQuYS1oYXQgLnBue2NvbG9yOiNmZmRkMzM7fQogIC8qIENyZWF0ZSBidG4gKHNzaCBkYXJrKSAqLwogIC5jYnRuLXNzaHtiYWNrZ3JvdW5kOnRyYW5zcGFyZW50O2JvcmRlcjoycHggc29saWQgIzIyYzU1ZTtjb2xvcjojMjJjNTVlO2ZvbnQtc2l6ZToxM3B4O3dpZHRoOmF1dG87cGFkZGluZzoxMHB4IDI4cHg7Ym9yZGVyLXJhZGl1czoxMHB4O2N1cnNvcjpwb2ludGVyO2ZvbnQtd2VpZ2h0OjcwMDtmb250LWZhbWlseTonU2FyYWJ1bicsc2Fucy1zZXJpZjt0cmFuc2l0aW9uOmFsbCAuMnM7ZGlzcGxheTppbmxpbmUtZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweDt9CiAgLmNidG4tc3NoOmhvdmVye2JhY2tncm91bmQ6cmdiYSgzNCwxOTcsOTQsLjEpO2JveC1zaGFkb3c6MCAwIDEycHggcmdiYSgzNCwxOTcsOTQsLjIpO30KICAvKiBMaW5rIHJlc3VsdCAqLwogIC5saW5rLXJlc3VsdHtkaXNwbGF5Om5vbmU7bWFyZ2luLXRvcDoxMnB4O2JvcmRlci1yYWRpdXM6MTBweDtvdmVyZmxvdzpoaWRkZW47fQogIC5saW5rLXJlc3VsdC5zaG93e2Rpc3BsYXk6YmxvY2s7fQogIC5saW5rLXJlc3VsdC1oZHJ7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6OHB4O3BhZGRpbmc6OHB4IDEycHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC4zKTtib3JkZXItYm90dG9tOjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LC4wNik7fQogIC5pbXAtYmFkZ2V7Zm9udC1zaXplOi42MnJlbTtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6MS41cHg7cGFkZGluZzouMThyZW0gLjU1cmVtO2JvcmRlci1yYWRpdXM6OTlweDt9CiAgLmltcC1iYWRnZS5ucHZ7YmFja2dyb3VuZDpyZ2JhKDAsMTgwLDI1NSwuMTUpO2NvbG9yOiMwMGNjZmY7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDAsMTgwLDI1NSwuMyk7fQogIC5pbXAtYmFkZ2UuZGFya3tiYWNrZ3JvdW5kOnJnYmEoMTUzLDUxLDI1NSwuMTUpO2NvbG9yOiNjYzY2ZmY7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDE1Myw1MSwyNTUsLjMpO30KICAubGluay1wcmV2aWV3e2JhY2tncm91bmQ6IzA2MGExMjtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxMHB4O2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXNpemU6LjU2cmVtO2NvbG9yOiMwMGFhZGQ7d29yZC1icmVhazpicmVhay1hbGw7bGluZS1oZWlnaHQ6MS42O21hcmdpbjo4cHggMTJweDtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMCwxNTAsMjU1LC4xNSk7bWF4LWhlaWdodDo1NHB4O292ZXJmbG93OmhpZGRlbjtwb3NpdGlvbjpyZWxhdGl2ZTt9CiAgLmxpbmstcHJldmlldy5kYXJrLWxwe2JvcmRlci1jb2xvcjpyZ2JhKDE1Myw1MSwyNTUsLjIyKTtjb2xvcjojYWE1NWZmO30KICAubGluay1wcmV2aWV3OjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2JvdHRvbTowO2xlZnQ6MDtyaWdodDowO2hlaWdodDoxNHB4O2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KHRyYW5zcGFyZW50LCMwNjBhMTIpO30KICAuY29weS1saW5rLWJ0bnt3aWR0aDpjYWxjKDEwMCUgLSAyNHB4KTttYXJnaW46MCAxMnB4IDEwcHg7cGFkZGluZzouNTVyZW07Ym9yZGVyLXJhZGl1czo4cHg7Zm9udC1zaXplOi44MnJlbTtmb250LXdlaWdodDo3MDA7Y3Vyc29yOnBvaW50ZXI7Zm9udC1mYW1pbHk6J1NhcmFidW4nLHNhbnMtc2VyaWY7Ym9yZGVyOjFweCBzb2xpZDt9CiAgLmNvcHktbGluay1idG4ubnB2e2JhY2tncm91bmQ6cmdiYSgwLDE4MCwyNTUsLjA3KTtib3JkZXItY29sb3I6cmdiYSgwLDE4MCwyNTUsLjI4KTtjb2xvcjojMDBjY2ZmO30KICAuY29weS1saW5rLWJ0bi5kYXJre2JhY2tncm91bmQ6cmdiYSgxNTMsNTEsMjU1LC4wNyk7Ym9yZGVyLWNvbG9yOnJnYmEoMTUzLDUxLDI1NSwuMjgpO2NvbG9yOiNjYzY2ZmY7fQogIC8qIFVzZXIgdGFibGUgKi8KICAudXRibC13cmFwe292ZXJmbG93LXg6YXV0bzttYXJnaW4tdG9wOjEwcHg7fQogIC51dGJse3dpZHRoOjEwMCU7Ym9yZGVyLWNvbGxhcHNlOmNvbGxhcHNlO2ZvbnQtc2l6ZToxMnB4O30KICAudXRibCB0aHtwYWRkaW5nOjhweCAxMHB4O3RleHQtYWxpZ246bGVmdDtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjEuNXB4O2NvbG9yOnZhcigtLW11dGVkKTtib3JkZXItYm90dG9tOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO30KICAudXRibCB0ZHtwYWRkaW5nOjlweCAxMHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC51dGJsIHRyOmxhc3QtY2hpbGQgdGR7Ym9yZGVyLWJvdHRvbTpub25lO30KICAuYmRne3BhZGRpbmc6MnB4IDhweDtib3JkZXItcmFkaXVzOjIwcHg7Zm9udC1zaXplOjEwcHg7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC13ZWlnaHQ6NzAwO30KICAuYmRnLWd7YmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMSk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMyk7Y29sb3I6IzIyYzU1ZTt9CiAgLmJkZy1ye2JhY2tncm91bmQ6cmdiYSgyMzksNjgsNjgsLjEpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyMzksNjgsNjgsLjMpO2NvbG9yOiNlZjQ0NDQ7fQogIC5idG4tdGJse3dpZHRoOjMwcHg7aGVpZ2h0OjMwcHg7Ym9yZGVyLXJhZGl1czo4cHg7Ym9yZGVyOjFweCBzb2xpZCB2YXIoLS1ib3JkZXIpO2JhY2tncm91bmQ6I2Y4ZmFmYztjdXJzb3I6cG9pbnRlcjtkaXNwbGF5OmlubGluZS1mbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2ZvbnQtc2l6ZToxNHB4O30KICAuYnRuLXRibDpob3Zlcntib3JkZXItY29sb3I6dmFyKC0tYWMpO30KICAvKiBSZW5ldyBkYXlzIGJhZGdlICovCiAgLmRheXMtYmFkZ2V7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEwcHg7cGFkZGluZzoycHggOHB4O2JvcmRlci1yYWRpdXM6MjBweDtiYWNrZ3JvdW5kOnJnYmEoMzQsMTk3LDk0LC4wOCk7Ym9yZGVyOjFweCBzb2xpZCByZ2JhKDM0LDE5Nyw5NCwuMik7Y29sb3I6dmFyKC0tYWMpO30KCiAgLyog4pSA4pSAIFNFTEVDVE9SIENBUkRTIOKUgOKUgCAqLyAgLyog4pSA4pSAIFNFTEVDVE9SIENBUkRTIOKUgOKUgCAqLwogIC5zZWMtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6dmFyKC0tbXV0ZWQpO3BhZGRpbmc6NnB4IDJweCAxMHB4O3RleHQtdHJhbnNmb3JtOnVwcGVyY2FzZTt9CiAgLnNlbC1jYXJke2JhY2tncm91bmQ6I2ZmZjtib3JkZXI6MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7Ym9yZGVyLXJhZGl1czoxNnB4O3BhZGRpbmc6MTZweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxNHB4O2N1cnNvcjpwb2ludGVyO3RyYW5zaXRpb246YWxsIC4ycztib3gtc2hhZG93OnZhcigtLXNoYWRvdyk7bWFyZ2luLWJvdHRvbToxMHB4O30KICAuc2VsLWNhcmQ6aG92ZXJ7Ym9yZGVyLWNvbG9yOnZhcigtLWFjKTtiYWNrZ3JvdW5kOnZhcigtLWFjLWRpbSk7dHJhbnNmb3JtOnRyYW5zbGF0ZVgoMnB4KTt9CiAgLnNlbC1sb2dve3dpZHRoOjY0cHg7aGVpZ2h0OjY0cHg7Ym9yZGVyLXJhZGl1czoxNHB4O2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmbGV4LXNocmluazowO30KICAuc2VsLWFpc3tiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyOjFweCBzb2xpZCAjYzVlODlhO30KICAuc2VsLXRydWV7YmFja2dyb3VuZDojYzgwNDBkO30KICAuc2VsLXNzaHtiYWNrZ3JvdW5kOiMxNTY1YzA7fQogIC5zZWwtYWlzLXNtLC5zZWwtdHJ1ZS1zbSwuc2VsLXNzaC1zbXt3aWR0aDo0NHB4O2hlaWdodDo0NHB4O2JvcmRlci1yYWRpdXM6MTBweDtkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7ZmxleC1zaHJpbms6MDt9CiAgLnNlbC1haXMtc217YmFja2dyb3VuZDojZmZmO2JvcmRlcjoxcHggc29saWQgI2M1ZTg5YTt9CiAgLnNlbC10cnVlLXNte2JhY2tncm91bmQ6I2M4MDQwZDt9CiAgLnNlbC1zc2gtc217YmFja2dyb3VuZDojMTU2NWMwO30KICAuc2VsLWluZm97ZmxleDoxO21pbi13aWR0aDowO30KICAuc2VsLW5hbWV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOi44MnJlbTtmb250LXdlaWdodDo3MDA7bWFyZ2luLWJvdHRvbTo0cHg7fQogIC5zZWwtbmFtZS5haXN7Y29sb3I6IzNkN2EwZTt9CiAgLnNlbC1uYW1lLnRydWV7Y29sb3I6I2M4MDQwZDt9CiAgLnNlbC1uYW1lLnNzaHtjb2xvcjojMTU2NWMwO30KICAuc2VsLXN1Yntmb250LXNpemU6MTFweDtjb2xvcjp2YXIoLS1tdXRlZCk7bGluZS1oZWlnaHQ6MS41O30KICAuc2VsLWFycm93e2ZvbnQtc2l6ZToxLjRyZW07Y29sb3I6dmFyKC0tbXV0ZWQpO2ZsZXgtc2hyaW5rOjA7fQogIC8qIOKUgOKUgCBGT1JNIEhFQURFUiDilIDilIAgKi8KICAuZm9ybS1iYWNre2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjZweDtmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS1tdXRlZCk7Y3Vyc29yOnBvaW50ZXI7cGFkZGluZzo0cHggMnB4IDEycHg7Zm9udC13ZWlnaHQ6NjAwO30KICAuZm9ybS1iYWNrOmhvdmVye2NvbG9yOnZhcigtLXR4dCk7fQogIC5mb3JtLWhkcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMnB4O21hcmdpbi1ib3R0b206MTZweDtwYWRkaW5nLWJvdHRvbToxNHB4O2JvcmRlci1ib3R0b206MXB4IHNvbGlkIHZhcigtLWJvcmRlcik7fQogIC5mb3JtLXRpdGxle2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTouODVyZW07Zm9udC13ZWlnaHQ6NzAwO21hcmdpbi1ib3R0b206M3B4O30KICAuZm9ybS10aXRsZS5haXN7Y29sb3I6IzNkN2EwZTt9CiAgLmZvcm0tdGl0bGUudHJ1ZXtjb2xvcjojYzgwNDBkO30KICAuZm9ybS10aXRsZS5zc2h7Y29sb3I6IzE1NjVjMDt9CiAgLmZvcm0tc3Vie2ZvbnQtc2l6ZToxMHB4O2NvbG9yOnZhcigtLW11dGVkKTt9CiAgLmNidG4tYWlze2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjM2Q3YTBlLCM1YWFhMTgpO30KICAuY2J0bi10cnVle2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjYTYwMDBjLCNkODEwMjApO30KCiAgLyog4pSA4pSAIEhEUiBsb2dvIGFuaW1hdGlvbnMgKHNhbWUgYXMgbG9naW4pIOKUgOKUgCAqLwogIEBrZXlmcmFtZXMgaGRyLW9yYml0LWRhc2ggewogICAgZnJvbSB7IHN0cm9rZS1kYXNob2Zmc2V0OiAwOyB9CiAgICB0byAgIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IC0yNTE7IH0KICB9CiAgQGtleWZyYW1lcyBoZHItcHVsc2UtZHJhdyB7CiAgICAwJSAgIHsgc3Ryb2tlLWRhc2hvZmZzZXQ6IDIyMDsgb3BhY2l0eTogMDsgfQogICAgMTUlICB7IG9wYWNpdHk6IDE7IH0KICAgIDEwMCUgeyBzdHJva2UtZGFzaG9mZnNldDogMDsgb3BhY2l0eTogMTsgfQogIH0KICBAa2V5ZnJhbWVzIGhkci1ibGluay1kb3QgewogICAgMCUsIDEwMCUgeyBvcGFjaXR5OiAwLjI1OyB9CiAgICA1MCUgICAgICAgeyBvcGFjaXR5OiAxOyB9CiAgfQogIEBrZXlmcmFtZXMgaGRyLWxvZ28tZ2xvdyB7CiAgICAwJSwgMTAwJSB7IGZpbHRlcjogZHJvcC1zaGFkb3coMCAwIDZweCAjNjBhNWZhKSBkcm9wLXNoYWRvdygwIDAgMTRweCAjMjU2M2ViKTsgfQogICAgNTAlICAgICAgIHsgZmlsdGVyOiBkcm9wLXNoYWRvdygwIDAgMTRweCAjNjBhNWZhKSBkcm9wLXNoYWRvdygwIDAgMjhweCAjMjU2M2ViKSBkcm9wLXNoYWRvdygwIDAgNDJweCAjMDZiNmQ0KTsgfQogIH0KICAuaGRyLWxvZ28tc3ZnLXdyYXAgewogICAgZGlzcGxheTogZmxleDsKICAgIGp1c3RpZnktY29udGVudDogY2VudGVyOwogICAgbWFyZ2luLWJvdHRvbTogOHB4OwogICAgYW5pbWF0aW9uOiBoZHItbG9nby1nbG93IDNzIGVhc2UtaW4tb3V0IGluZmluaXRlOwogIH0KICAuaGRyLW9yYml0LXJpbmcgeyB0cmFuc2Zvcm0tb3JpZ2luOiA1MHB4IDUwcHg7IGFuaW1hdGlvbjogaGRyLW9yYml0LWRhc2ggOHMgbGluZWFyIGluZmluaXRlOyB9CiAgLmhkci13YXZlLWFuaW0gIHsgc3Ryb2tlLWRhc2hhcnJheToyMjA7IHN0cm9rZS1kYXNob2Zmc2V0OjIyMDsgYW5pbWF0aW9uOiBoZHItcHVsc2UtZHJhdyAxLjZzIGN1YmljLWJlemllciguNCwwLC4yLDEpIDAuNXMgZm9yd2FyZHM7IH0KICAuaGRyLWRvdC0xIHsgYW5pbWF0aW9uOiBoZHItYmxpbmstZG90IDIuMnMgZWFzZS1pbi1vdXQgMS44cyBpbmZpbml0ZTsgfQogIC5oZHItZG90LTIgeyBhbmltYXRpb246IGhkci1ibGluay1kb3QgMi4ycyBlYXNlLWluLW91dCAyLjJzIGluZmluaXRlOyB9CgogIC8qIOKUgOKUgCBEYXNoYm9hcmQgRmlyZWZsaWVzIChmdWxsIHBhZ2UpIOKUgOKUgCAqLwogIC5kYXNoLWZmIHsKICAgIHBvc2l0aW9uOiBmaXhlZDsKICAgIGJvcmRlci1yYWRpdXM6IDUwJTsKICAgIHBvaW50ZXItZXZlbnRzOiBub25lOwogICAgei1pbmRleDogMDsKICAgIGFuaW1hdGlvbjogZGFzaC1mZi1kcmlmdCBsaW5lYXIgaW5maW5pdGUsIGRhc2gtZmYtYmxpbmsgZWFzZS1pbi1vdXQgaW5maW5pdGU7CiAgICBvcGFjaXR5OiAwOwogIH0KICBAa2V5ZnJhbWVzIGRhc2gtZmYtZHJpZnQgewogICAgMCUgICB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKDAsMCkgc2NhbGUoMSk7IH0KICAgIDIwJSAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSh2YXIoLS1keDEpLHZhcigtLWR5MSkpIHNjYWxlKDEuMSk7IH0KICAgIDQwJSAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSh2YXIoLS1keDIpLHZhcigtLWR5MikpIHNjYWxlKDAuOSk7IH0KICAgIDYwJSAgeyB0cmFuc2Zvcm06IHRyYW5zbGF0ZSh2YXIoLS1keDMpLHZhcigtLWR5MykpIHNjYWxlKDEuMDUpOyB9CiAgICA4MCUgIHsgdHJhbnNmb3JtOiB0cmFuc2xhdGUodmFyKC0tZHg0KSx2YXIoLS1keTQpKSBzY2FsZSgwLjk1KTsgfQogICAgMTAwJSB7IHRyYW5zZm9ybTogdHJhbnNsYXRlKDAsMCkgc2NhbGUoMSk7IH0KICB9CiAgQGtleWZyYW1lcyBkYXNoLWZmLWJsaW5rIHsKICAgIDAlLDEwMCV7IG9wYWNpdHk6MDsgfSAxNSV7IG9wYWNpdHk6MDsgfSAzMCV7IG9wYWNpdHk6MTsgfQogICAgNTAleyBvcGFjaXR5OjAuOTsgfSA2NSV7IG9wYWNpdHk6MDsgfSA4MCV7IG9wYWNpdHk6MC44NTsgfSA5MiV7IG9wYWNpdHk6MDsgfQogIH0KCiAgLyog4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCiAgICAgM0QgQ0FSRFMgLyBUQUJTIC8gQlVUVE9OUyDigJQg4LiX4Li44LiB4Lir4LiZ4LmJ4LiyCiAg4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQICovCiAgLmNhcmQgewogICAgYm9yZGVyLXJhZGl1czogMThweCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAycHggc29saWQgcmdiYSgzNCwxOTcsOTQsMC4yNSkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSBpbnNldCwKICAgICAgMCA4cHggMjRweCByZ2JhKDAsMCwwLDAuMzUpLAogICAgICAwIDJweCA4cHggcmdiYSgzNCwxOTcsOTQsMC4xMiksCiAgICAgIDAgMTZweCAzMnB4IHJnYmEoMCwwLDAsMC4yKSAhaW1wb3J0YW50OwogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDApIHRyYW5zbGF0ZVooMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xOHMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAuY2FyZDpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTNweCkgdHJhbnNsYXRlWigwKTsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjEpIGluc2V0LAogICAgICAwIDE0cHggMzZweCByZ2JhKDAsMCwwLDAuNCksCiAgICAgIDAgNHB4IDE2cHggcmdiYSgzNCwxOTcsOTQsMC4xOCksCiAgICAgIDAgMjRweCA0OHB4IHJnYmEoMCwwLDAsMC4yNSkgIWltcG9ydGFudDsKICB9CgogIC8qIE5hdiBpdGVtcyAzRCAqLwogIC5uYXYtaXRlbSB7CiAgICBib3JkZXItcmFkaXVzOiA5OTlweCAhaW1wb3J0YW50OwogICAgYm9yZGVyOiAxLjVweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OiAwIDNweCAwIHJnYmEoMCwwLDAsMC4zKSwgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpIGluc2V0ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiBhbGwgMC4yMnMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSAhaW1wb3J0YW50OwogICAgbWFyZ2luOiAwIDJweDsKICAgIHBhZGRpbmc6IDlweCAxNnB4ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7CiAgfQogIC5uYXYtaXRlbS5hY3RpdmUgewogICAgYm9yZGVyLXJhZGl1czogOTk5cHggIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtMnB4KSAhaW1wb3J0YW50OwogICAgYm9yZGVyLWNvbG9yOiB0cmFuc3BhcmVudCAhaW1wb3J0YW50OwogICAgYmFja2dyb3VuZDogbGluZWFyLWdyYWRpZW50KDEzNWRlZywjMjJjNTVlLCMxNmEzNGEpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OiAwIDRweCAxNHB4IHJnYmEoMzQsMTk3LDk0LDAuNDUpICFpbXBvcnRhbnQ7CiAgICBjb2xvcjogI2ZmZiAhaW1wb3J0YW50OwogICAgcGFkZGluZzogOXB4IDE2cHggIWltcG9ydGFudDsKICB9CiAgLm5hdi1pdGVtOmhvdmVyOm5vdCguYWN0aXZlKSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTFweCkgIWltcG9ydGFudDsKICAgIGJvcmRlci1jb2xvcjogcmdiYSgyNTUsMjU1LDI1NSwwLjE4KSAhaW1wb3J0YW50OwogICAgYmFja2dyb3VuZDogcmdiYSgyNTUsMjU1LDI1NSwwLjA4KSAhaW1wb3J0YW50OwogIH0KCiAgLyogQWxsIGJ1dHRvbnMgM0QgKi8KICAuY2J0biwgLmJ0bi1yLCAuY2J0bS1zc2gsIC5idG4tdGJsLCAucGJ0biwgLnRidG4sCiAgLmNvcHktYnRuLCAuY29weS1saW5rLWJ0biwgLmxvZ291dCwgLm1jbG9zZSwKICAuYWJ0biwgLnBvcnQtYnRuLCAucGljay1vcHQgewogICAgYm9yZGVyLXJhZGl1czogMTJweCAhaW1wb3J0YW50OwogICAgYm94LXNoYWRvdzoKICAgICAgMCA0cHggMCByZ2JhKDAsMCwwLDAuMzUpLAogICAgICAwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xMikgaW5zZXQsCiAgICAgIDAgNnB4IDE2cHggcmdiYSgwLDAsMCwwLjIpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xMnMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xMnMgZWFzZSAhaW1wb3J0YW50OwogICAgYm9yZGVyLXdpZHRoOiAycHggIWltcG9ydGFudDsKICB9CiAgLmNidG46aG92ZXIsIC5idG4tcjpob3ZlciwgLmNvcHktYnRuOmhvdmVyLAogIC5hYnRuOmhvdmVyLCAucG9ydC1idG46aG92ZXIsIC5waWNrLW9wdDpob3ZlciB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoLTJweCk7CiAgICBib3gtc2hhZG93OgogICAgICAwIDZweCAwIHJnYmEoMCwwLDAsMC4zNSksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjE1KSBpbnNldCwKICAgICAgMCAxMHB4IDI0cHggcmdiYSgwLDAsMCwwLjI1KSAhaW1wb3J0YW50OwogIH0KICAuY2J0bjphY3RpdmUsIC5idG4tcjphY3RpdmUsIC5jb3B5LWJ0bjphY3RpdmUsCiAgLmFidG46YWN0aXZlLCAucG9ydC1idG46YWN0aXZlLCAucGljay1vcHQ6YWN0aXZlLAogIC5idG4tdGJsOmFjdGl2ZSwgLmxvZ291dDphY3RpdmUgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKDNweCkgc2NhbGUoMC45NykgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgMXB4IDAgcmdiYSgwLDAsMCwwLjQpLAogICAgICAwIDAgMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDYpIGluc2V0ICFpbXBvcnRhbnQ7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4wNnMgZWFzZSwgYm94LXNoYWRvdyAwLjA2cyBlYXNlICFpbXBvcnRhbnQ7CiAgfQoKICAvKiBzZWwtY2FyZCAzRCAqLwogIC5zZWwtY2FyZCB7CiAgICBib3JkZXItcmFkaXVzOiAxOHB4ICFpbXBvcnRhbnQ7CiAgICBib3JkZXI6IDJweCBzb2xpZCB2YXIoLS1ib3JkZXIpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDRweCAwIHJnYmEoMCwwLDAsMC4yKSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMDgpIGluc2V0LAogICAgICAwIDhweCAyMHB4IHJnYmEoMCwwLDAsMC4xMikgIWltcG9ydGFudDsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgwKSB0cmFuc2xhdGVYKDApOwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMThzIGN1YmljLWJlemllciguMzQsMS41NiwuNjQsMSksCiAgICAgICAgICAgICAgICBib3gtc2hhZG93IDAuMThzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLnNlbC1jYXJkOmhvdmVyIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgtM3B4KSB0cmFuc2xhdGVYKDJweCkgIWltcG9ydGFudDsKICAgIGJveC1zaGFkb3c6CiAgICAgIDAgOHB4IDAgcmdiYSgwLDAsMCwwLjI1KSwKICAgICAgMCAxcHggMCByZ2JhKDI1NSwyNTUsMjU1LDAuMSkgaW5zZXQsCiAgICAgIDAgMTZweCAzMnB4IHJnYmEoMCwwLDAsMC4xOCkgIWltcG9ydGFudDsKICB9CiAgLnNlbC1jYXJkOmFjdGl2ZSB7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMnB4KSB0cmFuc2xhdGVYKDApIHNjYWxlKDAuOTgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OiAwIDFweCAwIHJnYmEoMCwwLDAsMC4zKSAhaW1wb3J0YW50OwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CgogIC8qIHVpdGVtcyAzRCAqLwogIC51aXRlbSB7CiAgICBib3JkZXItcmFkaXVzOiAxNHB4ICFpbXBvcnRhbnQ7CiAgICBib3JkZXI6IDJweCBzb2xpZCB2YXIoLS1ib3JkZXIpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDNweCAwIHJnYmEoMCwwLDAsMC4xOCksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA3KSBpbnNldCwKICAgICAgMCA2cHggMTRweCByZ2JhKDAsMCwwLDAuMDgpICFpbXBvcnRhbnQ7CiAgICB0cmFuc2Zvcm06IHRyYW5zbGF0ZVkoMCk7CiAgICB0cmFuc2l0aW9uOiB0cmFuc2Zvcm0gMC4xNXMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSwKICAgICAgICAgICAgICAgIGJveC1zaGFkb3cgMC4xNXMgZWFzZSAhaW1wb3J0YW50OwogIH0KICAudWl0ZW06aG92ZXIgewogICAgdHJhbnNmb3JtOiB0cmFuc2xhdGVZKC0ycHgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OgogICAgICAwIDZweCAwIHJnYmEoMCwwLDAsMC4yMiksCiAgICAgIDAgMXB4IDAgcmdiYSgyNTUsMjU1LDI1NSwwLjA5KSBpbnNldCwKICAgICAgMCAxMnB4IDI0cHggcmdiYSgwLDAsMCwwLjEyKSAhaW1wb3J0YW50OwogIH0KICAudWl0ZW06YWN0aXZlIHsKICAgIHRyYW5zZm9ybTogdHJhbnNsYXRlWSgycHgpIHNjYWxlKDAuOTgpICFpbXBvcnRhbnQ7CiAgICBib3gtc2hhZG93OiAwIDFweCAwIHJnYmEoMCwwLDAsMC4zKSAhaW1wb3J0YW50OwogICAgdHJhbnNpdGlvbjogdHJhbnNmb3JtIDAuMDZzIGVhc2UgIWltcG9ydGFudDsKICB9CiAgLyogYm91bmNlIGtleWZyYW1lIOC4quC4s+C4q+C4o+C4seC4muC4geC4lCAqLwogIEBrZXlmcmFtZXMgYnRuLWJvdW5jZSB7CiAgICAwJSAgIHsgdHJhbnNmb3JtOiBzY2FsZSgxKTsgfQogICAgMzAlICB7IHRyYW5zZm9ybTogc2NhbGUoMC45MykgdHJhbnNsYXRlWSgzcHgpOyB9CiAgICA2MCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgxLjA0KSB0cmFuc2xhdGVZKC0ycHgpOyB9CiAgICA4MCUgIHsgdHJhbnNmb3JtOiBzY2FsZSgwLjk4KSB0cmFuc2xhdGVZKDFweCk7IH0KICAgIDEwMCUgeyB0cmFuc2Zvcm06IHNjYWxlKDEpIHRyYW5zbGF0ZVkoMCk7IH0KICB9CiAgLmNidG46YWN0aXZlLCAuYnRuLXI6YWN0aXZlLCAuY29weS1idG46YWN0aXZlIHsgYW5pbWF0aW9uOiBidG4tYm91bmNlIDAuMjhzIGVhc2UgZm9yd2FyZHMgIWltcG9ydGFudDsgfQoKICAvKiBOYXYgM0QgcGlsbHMgb3ZlcnJpZGUgKi8KICAubmF2LWl0ZW17Ym9yZGVyLXJhZGl1czo5OTlweCFpbXBvcnRhbnQ7Ym94LXNoYWRvdzowIDNweCAwIHJnYmEoMCwwLDAsMC4zKSwwIDFweCAwIHJnYmEoMjU1LDI1NSwyNTUsMC4xKSBpbnNldCFpbXBvcnRhbnQ7Ym9yZGVyLXdpZHRoOjEuNXB4IWltcG9ydGFudDtwYWRkaW5nOjlweCAxNnB4IWltcG9ydGFudDt9CiAgLm5hdi1pdGVtLmFjdGl2ZXtib3JkZXItcmFkaXVzOjk5OXB4IWltcG9ydGFudDt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KSFpbXBvcnRhbnQ7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMyMmM1NWUsIzE2YTM0YSkhaW1wb3J0YW50O2JvcmRlci1jb2xvcjp0cmFuc3BhcmVudCFpbXBvcnRhbnQ7Ym94LXNoYWRvdzowIDRweCAxNHB4IHJnYmEoMzQsMTk3LDk0LDAuNDUpIWltcG9ydGFudDtjb2xvcjojZmZmIWltcG9ydGFudDtwYWRkaW5nOjlweCAxNnB4IWltcG9ydGFudDtmb250LXNpemU6MTFweCFpbXBvcnRhbnQ7fQogIC5uYXYtaXRlbTpob3Zlcjpub3QoLmFjdGl2ZSl7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTFweCkhaW1wb3J0YW50O30KCiAgLyogRmlyZWZsaWVzIGluc2lkZSBjYXJkcyAqLwogIC5jYXJkLWZme3Bvc2l0aW9uOmFic29sdXRlO2JvcmRlci1yYWRpdXM6NTAlO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDowO2FuaW1hdGlvbjpjZmYtZHJpZnQgbGluZWFyIGluZmluaXRlLGNmZi1ibGluayBlYXNlLWluLW91dCBpbmZpbml0ZTtvcGFjaXR5OjA7fQogIEBrZXlmcmFtZXMgY2ZmLWRyaWZ0ezAle3RyYW5zZm9ybTp0cmFuc2xhdGUoMCwwKSBzY2FsZSgxKTt9MjAle3RyYW5zZm9ybTp0cmFuc2xhdGUodmFyKC0tZHgxKSx2YXIoLS1keTEpKSBzY2FsZSgxLjEpO300MCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSh2YXIoLS1keDIpLHZhcigtLWR5MikpIHNjYWxlKDAuOSk7fTYwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4MyksdmFyKC0tZHkzKSkgc2NhbGUoMS4wNSk7fTgwJXt0cmFuc2Zvcm06dHJhbnNsYXRlKHZhcigtLWR4NCksdmFyKC0tZHk0KSkgc2NhbGUoMC45NSk7fTEwMCV7dHJhbnNmb3JtOnRyYW5zbGF0ZSgwLDApIHNjYWxlKDEpO319CiAgQGtleWZyYW1lcyBjZmYtYmxpbmt7MCUsMTAwJXtvcGFjaXR5OjA7fTE1JXtvcGFjaXR5OjA7fTMwJXtvcGFjaXR5OjAuOTt9NTAle29wYWNpdHk6MC43O302NSV7b3BhY2l0eTowO304MCV7b3BhY2l0eTowLjg7fTkyJXtvcGFjaXR5OjA7fX0KICAuY2FyZD4qOm5vdCguY2FyZC1mZil7fQogIC5zYz4qOm5vdCguY2FyZC1mZil7fQoKICAvKiBTUEVFRCBURVNUICovCiAgLnNwZWVkLWhlcm97YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTYwZGVnLCMwYTE2MjggMCUsIzA2MTAyMCAxMDAlKTtib3JkZXI6MnB4IHNvbGlkIHJnYmEoNiwxODIsMjEyLDAuMik7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjRweCAxNnB4O21hcmdpbi1ib3R0b206MTJweDt0ZXh0LWFsaWduOmNlbnRlcjtwb3NpdGlvbjpyZWxhdGl2ZTtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1oZXJvOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JhY2tncm91bmQ6cmFkaWFsLWdyYWRpZW50KGVsbGlwc2UgODAlIDUwJSBhdCA1MCUgMCUscmdiYSg2LDE4MiwyMTIsMC4xMiksdHJhbnNwYXJlbnQpO30KICAuc3BlZWQtdGl0bGV7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjExcHg7bGV0dGVyLXNwYWNpbmc6NHB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1nYXVnZS13cmFwe3Bvc2l0aW9uOnJlbGF0aXZlO3dpZHRoOjE2MHB4O2hlaWdodDo4MHB4O21hcmdpbjowIGF1dG8gMTZweDt9CiAgLnNwZWVkLWdhdWdlLXN2Z3tvdmVyZmxvdzp2aXNpYmxlO30KICAuc3BlZWQtZ2F1Z2UtYmd7ZmlsbDpub25lO3N0cm9rZTpyZ2JhKDI1NSwyNTUsMjU1LDAuMDYpO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt9CiAgLnNwZWVkLWdhdWdlLWZpbGx7ZmlsbDpub25lO3N0cm9rZS13aWR0aDoxMjtzdHJva2UtbGluZWNhcDpyb3VuZDt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgY3ViaWMtYmV6aWVyKC4zNCwxLjU2LC42NCwxKSxzdHJva2UgMC4zczt0cmFuc2Zvcm0tb3JpZ2luOjgwcHggODBweDt9CiAgLnNwZWVkLWNlbnRlcntwb3NpdGlvbjphYnNvbHV0ZTtib3R0b206MDtsZWZ0OjUwJTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgtNTAlKTt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MzJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMDZiNmQ0LCM2MGE1ZmEpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7fQogIC5zcGVlZC11bml0e2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo5cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNSk7bWFyZ2luLXRvcDoycHg7fQogIC5zcGVlZC1idG5ze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6MWZyIDFmcjtnYXA6MTBweDttYXJnaW4tYm90dG9tOjEycHg7fQogIC5zcGVlZC1idG57cGFkZGluZzoxNHB4O2JvcmRlci1yYWRpdXM6MTRweDtib3JkZXI6bm9uZTtjdXJzb3I6cG9pbnRlcjtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTBweDtmb250LXdlaWdodDo3MDA7bGV0dGVyLXNwYWNpbmc6MnB4O3RyYW5zaXRpb246YWxsIDAuMnM7fQogIC5zcGVlZC1idG4tZGx7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCMyNTYzZWIsIzFkNGVkOCk7Y29sb3I6I2ZmZjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNyw5OSwyMzUsMC40KTt9CiAgLnNwZWVkLWJ0bi1kbDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgzNyw5OSwyMzUsMC41KTt9CiAgLnNwZWVkLWJ0bi11bHtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzdjM2FlZCwjNmQyOGQ5KTtjb2xvcjojZmZmO2JveC1zaGFkb3c6MCA0cHggMTZweCByZ2JhKDEyNCw1OCwyMzcsMC40KTt9CiAgLnNwZWVkLWJ0bi11bDpob3Zlcnt0cmFuc2Zvcm06dHJhbnNsYXRlWSgtMnB4KTtib3gtc2hhZG93OjAgOHB4IDI0cHggcmdiYSgxMjQsNTgsMjM3LDAuNSk7fQogIC5zcGVlZC1idG46ZGlzYWJsZWR7b3BhY2l0eTowLjQ7Y3Vyc29yOm5vdC1hbGxvd2VkO3RyYW5zZm9ybTpub25lO30KICAuc3BlZWQtcmVzdWx0c3tkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7bWFyZ2luLWJvdHRvbToxMnB4O30KICAuc3BlZWQtcmVzLWNhcmR7YmFja2dyb3VuZDpyZ2JhKDI1NSwyNTUsMjU1LDAuMDQpO2JvcmRlcjoxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjA4KTtib3JkZXItcmFkaXVzOjE0cHg7cGFkZGluZzoxNnB4O3RleHQtYWxpZ246Y2VudGVyO30KICAuc3BlZWQtcmVzLWljb257Zm9udC1zaXplOjIwcHg7bWFyZ2luLWJvdHRvbTo2cHg7fQogIC5zcGVlZC1yZXMtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjQpO21hcmdpbi1ib3R0b206NHB4O30KICAuc3BlZWQtcmVzLXZhbHtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MjJweDtmb250LXdlaWdodDo5MDA7bGluZS1oZWlnaHQ6MTt9CiAgLnNwZWVkLXJlcy12YWwuZGwtY29sb3J7Y29sb3I6IzYwYTVmYTt9CiAgLnNwZWVkLXJlcy12YWwudWwtY29sb3J7Y29sb3I6I2E3OGJmYTt9CiAgLnNwZWVkLXJlcy11bml0e2ZvbnQtc2l6ZTo5cHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjMpO21hcmdpbi10b3A6MnB4O30KICAuc3BlZWQtc3RhdHVze2ZvbnQtc2l6ZToxMnB4O2NvbG9yOnJnYmEoNiwxODIsMjEyLDAuNyk7bWluLWhlaWdodDoxOHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctcm93e2Rpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2dhcDoyMHB4O21hcmdpbi1ib3R0b206MTJweDt9CiAgLnNwZWVkLXBpbmctaXRlbXt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLXBpbmctbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6cmdiYSgyNTUsMjU1LDI1NSwwLjM1KTttYXJnaW4tYm90dG9tOjJweDt9CiAgLnNwZWVkLXBpbmctdmFse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxNnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojNGFkZTgwO30KICAuc3BlZWQtcGluZy12YWwud2Fybntjb2xvcjojZmJiZjI0O30KICAuc3BlZWQtcGluZy12YWwuYmFke2NvbG9yOiNlZjQ0NDQ7fQogIC5zcGVlZC1iYXItd3JhcHtoZWlnaHQ6NHB4O2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjA2KTtib3JkZXItcmFkaXVzOjJweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW47fQogIC5zcGVlZC1iYXJ7aGVpZ2h0OjEwMCU7Ym9yZGVyLXJhZGl1czoycHg7d2lkdGg6MCU7dHJhbnNpdGlvbjp3aWR0aCAwLjNzIGVhc2U7fQogIC5zcGVlZC1iYXIuZGwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMyNTYzZWIsIzYwYTVmYSk7fQogIC5zcGVlZC1iYXIudWwtYmFye2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCM3YzNhZWQsI2E3OGJmYSk7fQogIC5zcGVlZC1pbmZvLWdyaWR7ZGlzcGxheTpncmlkO2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnIgMWZyIDFmcjtnYXA6OHB4O30KICAuc3BlZWQtaW5mby1pdGVte2JhY2tncm91bmQ6cmdiYSgyNTUsMjU1LDI1NSwwLjAzKTtib3JkZXI6MXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4wNik7Ym9yZGVyLXJhZGl1czoxMHB4O3BhZGRpbmc6MTBweDt0ZXh0LWFsaWduOmNlbnRlcjt9CiAgLnNwZWVkLWluZm8tbGJse2ZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo3cHg7bGV0dGVyLXNwYWNpbmc6MXB4O2NvbG9yOnJnYmEoMjU1LDI1NSwyNTUsMC4zKTttYXJnaW4tYm90dG9tOjRweDt9CiAgLnNwZWVkLWluZm8tdmFse2ZvbnQtc2l6ZToxMnB4O2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjpyZ2JhKDI1NSwyNTUsMjU1LDAuOCk7fQogIC5zcGVlZC1wcm9ne2hlaWdodDozcHg7YmFja2dyb3VuZDpyZ2JhKDYsMTgyLDIxMiwwLjE1KTtib3JkZXItcmFkaXVzOjJweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLWJvdHRvbTo4cHg7fQogIC5zcGVlZC1wcm9nLWZpbGx7aGVpZ2h0OjEwMCU7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsIzA2YjZkNCwjNjBhNWZhKTtib3JkZXItcmFkaXVzOjJweDt3aWR0aDowJTt0cmFuc2l0aW9uOndpZHRoIDAuMnMgZWFzZTt9CgpAa2V5ZnJhbWVzIHBpbmd7MCV7dHJhbnNmb3JtOnNjYWxlKDEpO29wYWNpdHk6Ljd9MTAwJXt0cmFuc2Zvcm06c2NhbGUoMi41KTtvcGFjaXR5OjB9fQouZGd7cG9zaXRpb246cmVsYXRpdmU7ZGlzcGxheTppbmxpbmUtZmxleDt3aWR0aDoxMHB4O2hlaWdodDoxMHB4O2ZsZXgtc2hyaW5rOjA7dmVydGljYWwtYWxpZ246bWlkZGxlO30KLmRnOjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTtvcGFjaXR5Oi41O2FuaW1hdGlvbjpwaW5nIDEuNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQouZGc6OmFmdGVye2NvbnRlbnQ6Jyc7cG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MnB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTt9Ci5kZy5yZWQ6OmJlZm9yZXtiYWNrZ3JvdW5kOiNlZjQ0NDQ7fQouZGcucmVkOjphZnRlcntiYWNrZ3JvdW5kOiNlZjQ0NDQ7fQouZG90e3Bvc2l0aW9uOnJlbGF0aXZlO2Rpc3BsYXk6aW5saW5lLWZsZXg7d2lkdGg6OHB4O2hlaWdodDo4cHg7ZmxleC1zaHJpbms6MDt2ZXJ0aWNhbC1hbGlnbjptaWRkbGU7fQouZG90OjpiZWZvcmV7Y29udGVudDonJztwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTtvcGFjaXR5Oi41O2FuaW1hdGlvbjpwaW5nIDEuNHMgZWFzZS1pbi1vdXQgaW5maW5pdGU7fQouZG90OjphZnRlcntjb250ZW50OicnO3Bvc2l0aW9uOmFic29sdXRlO2luc2V0OjEuNXB4O2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTt9Ci5kb3QucmVkOjpiZWZvcmV7YmFja2dyb3VuZDojZWY0NDQ0O30KLmRvdC5yZWQ6OmFmdGVye2JhY2tncm91bmQ6I2VmNDQ0NDt9Cjwvc3R5bGU+CjxzY3JpcHQgc3JjPSJodHRwczovL2NkbmpzLmNsb3VkZmxhcmUuY29tL2FqYXgvbGlicy9xcmNvZGVqcy8xLjAuMC9xcmNvZGUubWluLmpzIj48L3NjcmlwdD4KCjwvaGVhZD4KPGJvZHk+CjxkaXYgY2xhc3M9IndyYXAiPgoKICA8IS0tIEhFQURFUiAtLT4KICA8ZGl2IGNsYXNzPSJoZHIiIGlkPSJoZHItcm9vdCI+CiAgPGNhbnZhcyBpZD0iaGRyLWNhbnZhcyIgc3R5bGU9InBvc2l0aW9uOmFic29sdXRlO2luc2V0OjA7d2lkdGg6MTAwJTtoZWlnaHQ6MTAwJTtwb2ludGVyLWV2ZW50czpub25lO3otaW5kZXg6MTsiPjwvY2FudmFzPgogIDxzY3JpcHQ+CiAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ0RPTUNvbnRlbnRMb2FkZWQnLGZ1bmN0aW9uKCl7CiAgICBjb25zdCBjYW52YXM9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1jYW52YXMnKTsKICAgIGNvbnN0IHdyYXA9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2hkci1yb290Jyk7CiAgICBmdW5jdGlvbiByZXNpemUoKXtjYW52YXMud2lkdGg9d3JhcC5vZmZzZXRXaWR0aDtjYW52YXMuaGVpZ2h0PXdyYXAub2Zmc2V0SGVpZ2h0O30KICAgIHJlc2l6ZSgpOwogICAgd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoJ3Jlc2l6ZScscmVzaXplKTsKICAgIGNvbnN0IGN0eD1jYW52YXMuZ2V0Q29udGV4dCgnMmQnKTsKICAgIGNvbnN0IGNvbG9ycz1bJyNiNWY1NDInLCcjZDRmYzVhJywnIzdmZmYwMCcsJyNhYWZmNDQnLCcjZjVmNTQyJywnI2ZmZTk0ZCcsJyM1NmZmYjAnLCcjOTBmZjZhJywnI2EwZmY3OCcsJyNmZmVjNmUnXTsKICAgIGNvbnN0IGZmcz1bXTsKICAgIGZvcihsZXQgaT0wO2k8MzU7aSsrKXsKICAgICAgZmZzLnB1c2goewogICAgICAgIHg6TWF0aC5yYW5kb20oKSpjYW52YXMud2lkdGgsCiAgICAgICAgeTpNYXRoLnJhbmRvbSgpKmNhbnZhcy5oZWlnaHQsCiAgICAgICAgcjpNYXRoLnJhbmRvbSgpKjEuOCswLjYsCiAgICAgICAgY29sb3I6Y29sb3JzW01hdGguZmxvb3IoTWF0aC5yYW5kb20oKSpjb2xvcnMubGVuZ3RoKV0sCiAgICAgICAgdng6KE1hdGgucmFuZG9tKCktMC41KSowLjUsCiAgICAgICAgdnk6KE1hdGgucmFuZG9tKCktMC41KSowLjQsCiAgICAgICAgYWxwaGE6MCwKICAgICAgICBhbHBoYURpcjpNYXRoLnJhbmRvbSgpPjAuNT8xOi0xLAogICAgICAgIGFscGhhU3BlZWQ6TWF0aC5yYW5kb20oKSowLjAxNSswLjAwNSwKICAgICAgfSk7CiAgICB9CiAgICBmdW5jdGlvbiBkcmF3KCl7CiAgICAgIHJlc2l6ZSgpOwogICAgICBjdHguY2xlYXJSZWN0KDAsMCxjYW52YXMud2lkdGgsY2FudmFzLmhlaWdodCk7CiAgICAgIGZmcy5mb3JFYWNoKGY9PnsKICAgICAgICBmLngrPWYudng7IGYueSs9Zi52eTsKICAgICAgICBpZihmLng8MClmLng9Y2FudmFzLndpZHRoOwogICAgICAgIGlmKGYueD5jYW52YXMud2lkdGgpZi54PTA7CiAgICAgICAgaWYoZi55PDApZi55PWNhbnZhcy5oZWlnaHQ7CiAgICAgICAgaWYoZi55PmNhbnZhcy5oZWlnaHQpZi55PTA7CiAgICAgICAgZi5hbHBoYSs9Zi5hbHBoYURpcipmLmFscGhhU3BlZWQ7CiAgICAgICAgaWYoZi5hbHBoYT49MSl7Zi5hbHBoYT0xO2YuYWxwaGFEaXI9LTE7fQogICAgICAgIGlmKGYuYWxwaGE8PTApe2YuYWxwaGE9MDtmLmFscGhhRGlyPTE7fQogICAgICAgIGN0eC5zYXZlKCk7CiAgICAgICAgY3R4Lmdsb2JhbEFscGhhPWYuYWxwaGE7CiAgICAgICAgY3R4LnNoYWRvd0JsdXI9Zi5yKjg7CiAgICAgICAgY3R4LnNoYWRvd0NvbG9yPWYuY29sb3I7CiAgICAgICAgY3R4LmJlZ2luUGF0aCgpOwogICAgICAgIGN0eC5hcmMoZi54LGYueSxmLnIsMCxNYXRoLlBJKjIpOwogICAgICAgIGN0eC5maWxsU3R5bGU9Zi5jb2xvcjsKICAgICAgICBjdHguZmlsbCgpOwogICAgICAgIGN0eC5yZXN0b3JlKCk7CiAgICAgIH0pOwogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoZHJhdyk7CiAgICB9CiAgICBkcmF3KCk7CiAgfSk7CiAgPC9zY3JpcHQ+CiAgICA8YnV0dG9uIGNsYXNzPSJsb2dvdXQiIG9uY2xpY2s9ImRvTG9nb3V0KCkiIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTt0b3A6MTZweDtyaWdodDoxNHB4O3otaW5kZXg6MTA7Ij7ihqkg4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4LiaPC9idXR0b24+CgogICAgPCEtLSBMb2dvIFNWRyAoc2FtZSBhcyBsb2dpbikgLS0+CiAgICA8ZGl2IGNsYXNzPSJoZHItbG9nby1zdmctd3JhcCI+CiAgICAgIDxzdmcgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjcyIiBoZWlnaHQ9IjcyIj4KICAgICAgICA8ZGVmcz4KICAgICAgICAgIDxsaW5lYXJHcmFkaWVudCBpZD0iaFciIHgxPSIwJSIgeTE9IjAlIiB4Mj0iMTAwJSIgeTI9IjAlIj4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9yPSIjMjU2M2ViIi8+CiAgICAgICAgICAgIDxzdG9wIG9mZnNldD0iNTAlIiAgc3RvcC1jb2xvcj0iIzYwYTVmYSIvPgogICAgICAgICAgICA8c3RvcCBvZmZzZXQ9IjEwMCUiIHN0b3AtY29sb3I9IiMwNmI2ZDQiLz4KICAgICAgICAgIDwvbGluZWFyR3JhZGllbnQ+CiAgICAgICAgICA8cmFkaWFsR3JhZGllbnQgaWQ9ImhCZyIgY3g9IjUwJSIgY3k9IjUwJSIgcj0iNTAlIj4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIwJSIgICBzdG9wLWNvbG9yPSIjMGYxZTRhIiBzdG9wLW9wYWNpdHk9IjAuOTUiLz4KICAgICAgICAgICAgPHN0b3Agb2Zmc2V0PSIxMDAlIiBzdG9wLWNvbG9yPSIjMDYwYzFlIiBzdG9wLW9wYWNpdHk9IjAuOTgiLz4KICAgICAgICAgIDwvcmFkaWFsR3JhZGllbnQ+CiAgICAgICAgICA8ZmlsdGVyIGlkPSJoR2xvdyI+CiAgICAgICAgICAgIDxmZUdhdXNzaWFuQmx1ciBzdGREZXZpYXRpb249IjIuNSIgcmVzdWx0PSJiIi8+CiAgICAgICAgICAgIDxmZU1lcmdlPjxmZU1lcmdlTm9kZSBpbj0iYiIvPjxmZU1lcmdlTm9kZSBpbj0iU291cmNlR3JhcGhpYyIvPjwvZmVNZXJnZT4KICAgICAgICAgIDwvZmlsdGVyPgogICAgICAgICAgPGNsaXBQYXRoIGlkPSJoQ2xpcCI+PGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiLz48L2NsaXBQYXRoPgogICAgICAgIDwvZGVmcz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSI0NiIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjEyKSIgc3Ryb2tlLXdpZHRoPSIxIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iNDIiIGZpbGw9Im5vbmUiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuMikiIHN0cm9rZS13aWR0aD0iMSIgc3Ryb2tlLWRhc2hhcnJheT0iNSA0IiBjbGFzcz0iaGRyLW9yYml0LXJpbmciLz4KICAgICAgICA8Y2lyY2xlIGN4PSI1MCIgY3k9IjUwIiByPSIzOCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJyZ2JhKDM3LDk5LDIzNSwwLjIyKSIgc3Ryb2tlLXdpZHRoPSIxIi8+CiAgICAgICAgPGNpcmNsZSBjeD0iNTAiIGN5PSI1MCIgcj0iMzQiIGZpbGw9InVybCgjaEJnKSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjUwIiBjeT0iNTAiIHI9IjM0IiBmaWxsPSJub25lIiBzdHJva2U9InVybCgjaFcpIiBzdHJva2Utd2lkdGg9IjEuOCIgb3BhY2l0eT0iMC45Ii8+CiAgICAgICAgPGxpbmUgeDE9IjUwIiB5MT0iMTQiIHgyPSI1MCIgeTI9IjIwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxsaW5lIHgxPSI1MCIgeTE9IjgwIiB4Mj0iNTAiIHkyPSI4NiIgc3Ryb2tlPSJyZ2JhKDk2LDE2NSwyNTAsMC41NSkiIHN0cm9rZS13aWR0aD0iMS41IiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KICAgICAgICA8bGluZSB4MT0iMTQiIHkxPSI1MCIgeDI9IjIwIiB5Mj0iNTAiIHN0cm9rZT0icmdiYSg5NiwxNjUsMjUwLDAuNTUpIiBzdHJva2Utd2lkdGg9IjEuNSIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIi8+CiAgICAgICAgPGxpbmUgeDE9IjgwIiB5MT0iNTAiIHgyPSI4NiIgeTI9IjUwIiBzdHJva2U9InJnYmEoOTYsMTY1LDI1MCwwLjU1KSIgc3Ryb2tlLXdpZHRoPSIxLjUiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIvPgogICAgICAgIDxnIGNsaXAtcGF0aD0idXJsKCNoQ2xpcCkiPgogICAgICAgICAgPHBvbHlsaW5lIHBvaW50cz0iMTYsNTAgMjQsNTAgMjksMzIgMzQsNjggMzksMzIgNDQsNTAgODQsNTAiCiAgICAgICAgICAgIGZpbGw9Im5vbmUiIHN0cm9rZT0idXJsKCNoVykiIHN0cm9rZS13aWR0aD0iMi4yIgogICAgICAgICAgICBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiCiAgICAgICAgICAgIGZpbHRlcj0idXJsKCNoR2xvdykiIGNsYXNzPSJoZHItd2F2ZS1hbmltIi8+CiAgICAgICAgPC9nPgogICAgICAgIDxjaXJjbGUgY3g9IjI5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzYwYTVmYSIgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3QtMSIvPgogICAgICAgIDxjaXJjbGUgY3g9IjM5IiBjeT0iMzIiIHI9IjIuNSIgZmlsbD0iIzA2YjZkNCIgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3QtMiIvPgogICAgICAgIDxjaXJjbGUgY3g9IjM0IiBjeT0iNjgiIHI9IjIuNSIgZmlsbD0iIzYwYTVmYSIgZmlsdGVyPSJ1cmwoI2hHbG93KSIgY2xhc3M9Imhkci1kb3QtMSIvPgogICAgICA8L3N2Zz4KICAgIDwvZGl2PgoKICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZToxOHB4O2ZvbnQtd2VpZ2h0OjkwMDtsZXR0ZXItc3BhY2luZzo0cHg7YmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoOTBkZWcsI2UwZjJmZSwjNjBhNWZhLCMwNmI2ZDQpOy13ZWJraXQtYmFja2dyb3VuZC1jbGlwOnRleHQ7LXdlYmtpdC10ZXh0LWZpbGwtY29sb3I6dHJhbnNwYXJlbnQ7YmFja2dyb3VuZC1jbGlwOnRleHQ7Ij5DSEFJWUE8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6OXB4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjYpO21hcmdpbi10b3A6MnB4OyI+UFJPSkVDVDwvZGl2PgogICAgPGRpdiBzdHlsZT0id2lkdGg6MTQwcHg7aGVpZ2h0OjFweDtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZyx0cmFuc3BhcmVudCwjNjBhNWZhLCMwNmI2ZDQsdHJhbnNwYXJlbnQpO21hcmdpbjo2cHggYXV0bztvcGFjaXR5OjAuNTsiPjwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjhweDtsZXR0ZXItc3BhY2luZzo0cHg7Y29sb3I6cmdiYSg2LDE4MiwyMTIsMC41NSk7bWFyZ2luLXRvcDoycHg7Ij5WMlJBWSAmYW1wOyBTU0g8L2Rpdj4KICAgIDxkaXYgc3R5bGU9ImZvbnQtZmFtaWx5OidPcmJpdHJvbicsbW9ub3NwYWNlO2ZvbnQtc2l6ZTo4cHg7bGV0dGVyLXNwYWNpbmc6M3B4O2NvbG9yOnJnYmEoOTYsMTY1LDI1MCwwLjUpO21hcmdpbi10b3A6NHB4OyIgaWQ9Imhkci1kb21haW4iPlNFQ1VSRSBQQU5FTDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIE5BViAtLT4KICA8ZGl2IGNsYXNzPSJuYXYtd3JhcCIgaWQ9Im5hdi13cmFwIj4KICA8Y2FudmFzIGlkPSJuYXYtY2FudmFzIiBzdHlsZT0icG9zaXRpb246YWJzb2x1dGU7aW5zZXQ6MDt3aWR0aDoxMDAlO2hlaWdodDoxMDAlO3BvaW50ZXItZXZlbnRzOm5vbmU7ei1pbmRleDoxOyI+PC9jYW52YXM+CiAgPHNjcmlwdD4KICB3aW5kb3cuYWRkRXZlbnRMaXN0ZW5lcignRE9NQ29udGVudExvYWRlZCcsZnVuY3Rpb24oKXsKICAgIGNvbnN0IGNhbnZhcz1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmF2LWNhbnZhcycpOwogICAgY29uc3Qgd3JhcD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmF2LXdyYXAnKTsKICAgIGZ1bmN0aW9uIHJlc2l6ZSgpe2NhbnZhcy53aWR0aD13cmFwLm9mZnNldFdpZHRoO2NhbnZhcy5oZWlnaHQ9d3JhcC5vZmZzZXRIZWlnaHQ7fQogICAgcmVzaXplKCk7CiAgICBjb25zdCBjdHg9Y2FudmFzLmdldENvbnRleHQoJzJkJyk7CiAgICBjb25zdCBjb2xvcnM9WycjYjVmNTQyJywnI2Q0ZmM1YScsJyM3ZmZmMDAnLCcjYWFmZjQ0JywnI2Y1ZjU0MicsJyNmZmU5NGQnLCcjNTZmZmIwJywnIzkwZmY2YSddOwogICAgY29uc3QgZmZzPVtdOwogICAgZm9yKGxldCBpPTA7aTwyMjtpKyspewogICAgICBmZnMucHVzaCh7CiAgICAgICAgeDpNYXRoLnJhbmRvbSgpKmNhbnZhcy53aWR0aCwKICAgICAgICB5Ok1hdGgucmFuZG9tKCkqY2FudmFzLmhlaWdodCwKICAgICAgICByOk1hdGgucmFuZG9tKCkqMS41KzAuOCwKICAgICAgICBjb2xvcjpjb2xvcnNbTWF0aC5mbG9vcihNYXRoLnJhbmRvbSgpKmNvbG9ycy5sZW5ndGgpXSwKICAgICAgICB2eDooTWF0aC5yYW5kb20oKS0wLjUpKjAuNiwKICAgICAgICB2eTooTWF0aC5yYW5kb20oKS0wLjUpKjAuNCwKICAgICAgICBhbHBoYTowLAogICAgICAgIGFscGhhRGlyOk1hdGgucmFuZG9tKCk+MC41PzE6LTEsCiAgICAgICAgYWxwaGFTcGVlZDpNYXRoLnJhbmRvbSgpKjAuMDIrMC4wMDgsCiAgICAgIH0pOwogICAgfQogICAgZnVuY3Rpb24gZHJhdygpewogICAgICByZXNpemUoKTsKICAgICAgY3R4LmNsZWFyUmVjdCgwLDAsY2FudmFzLndpZHRoLGNhbnZhcy5oZWlnaHQpOwogICAgICBmZnMuZm9yRWFjaChmPT57CiAgICAgICAgZi54Kz1mLnZ4OyBmLnkrPWYudnk7CiAgICAgICAgaWYoZi54PDApZi54PWNhbnZhcy53aWR0aDsKICAgICAgICBpZihmLng+Y2FudmFzLndpZHRoKWYueD0wOwogICAgICAgIGlmKGYueTwwKWYueT1jYW52YXMuaGVpZ2h0OwogICAgICAgIGlmKGYueT5jYW52YXMuaGVpZ2h0KWYueT0wOwogICAgICAgIGYuYWxwaGErPWYuYWxwaGFEaXIqZi5hbHBoYVNwZWVkOwogICAgICAgIGlmKGYuYWxwaGE+PTEpe2YuYWxwaGE9MTtmLmFscGhhRGlyPS0xO30KICAgICAgICBpZihmLmFscGhhPD0wKXtmLmFscGhhPTA7Zi5hbHBoYURpcj0xO30KICAgICAgICBjdHguc2F2ZSgpOwogICAgICAgIGN0eC5nbG9iYWxBbHBoYT1mLmFscGhhOwogICAgICAgIGN0eC5iZWdpblBhdGgoKTsKICAgICAgICBjdHguYXJjKGYueCxmLnksZi5yLDAsTWF0aC5QSSoyKTsKICAgICAgICBjdHguZmlsbFN0eWxlPWYuY29sb3I7CiAgICAgICAgY3R4LmZpbGwoKTsKICAgICAgICBjdHguc2hhZG93Qmx1cj1mLnIqNjsKICAgICAgICBjdHguc2hhZG93Q29sb3I9Zi5jb2xvcjsKICAgICAgICBjdHguZmlsbCgpOwogICAgICAgIGN0eC5yZXN0b3JlKCk7CiAgICAgIH0pOwogICAgICByZXF1ZXN0QW5pbWF0aW9uRnJhbWUoZHJhdyk7CiAgICB9CiAgICBkcmF3KCk7CiAgfSk7CiAgPC9zY3JpcHQ+CiAgPGRpdiBjbGFzcz0ibmF2Ij4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIGFjdGl2ZSIgb25jbGljaz0ic3coJ2Rhc2hib2FyZCcsdGhpcykiPvCfk4og4LmB4LiU4LiK4Lia4Lit4Lij4LmM4LiUPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJuYXYtaXRlbSIgb25jbGljaz0ic3coJ2NyZWF0ZScsdGhpcykiPuKelSDguKrguKPguYnguLLguIfguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnbWFuYWdlJyx0aGlzKSI+8J+UpyDguIjguLHguJTguIHguLLguKPguKLguLnguKo8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnb25saW5lJyx0aGlzKSI+8J+foiDguK3guK3guJnguYTguKXguJnguYw8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIiBvbmNsaWNrPSJzdygnYmFuJyx0aGlzKSI+8J+aqyDguJvguKXguJTguYHguJrguJk8L2Rpdj4KICAgIDxkaXYgY2xhc3M9Im5hdi1pdGVtIG5hdi1zcGVlZCIgb25jbGljaz0ic3coJ3NwZWVkJyx0aGlzKSI+4pqhIOC4quC4m+C4teC4lOC5gOC4l+C4qjwvZGl2PgogIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBEQVNIQk9BUkQg4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyBhY3RpdmUiIGlkPSJ0YWItZGFzaGJvYXJkIj4KICAgIDxkaXYgY2xhc3M9InNlYy1oZHIiPgogICAgICA8c3BhbiBjbGFzcz0ic2VjLXRpdGxlIj7imqEgU1lTVEVNIE1PTklUT1I8L3NwYW4+CiAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBpZD0iYnRuLXJlZnJlc2giIG9uY2xpY2s9ImxvYWREYXNoKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0ic2dyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJzYyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2xibCI+4pqhIENQVSBVU0FHRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRudXQiPgogICAgICAgICAgPHN2ZyB3aWR0aD0iNTIiIGhlaWdodD0iNTIiIHZpZXdCb3g9IjAgMCA1MiA1MiI+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImRiZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIi8+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImR2IiBpZD0iY3B1LXJpbmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIgc3Ryb2tlPSIjNGFkZTgwIgogICAgICAgICAgICAgIHN0cm9rZS1kYXNoYXJyYXk9IjEzOC4yIiBzdHJva2UtZGFzaG9mZnNldD0iMTM4LjIiLz4KICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgPGRpdiBjbGFzcz0iZGMiIGlkPSJjcHUtcGN0Ij4tLSU8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCkiIGlkPSJjcHUtY29yZXMiPi0tIGNvcmVzPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHBnIiBpZD0iY3B1LWJhciIgc3R5bGU9IndpZHRoOjAlIj48L2Rpdj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNjIj4KICAgICAgICA8ZGl2IGNsYXNzPSJzbGJsIj7wn6egIFJBTSBVU0FHRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRudXQiPgogICAgICAgICAgPHN2ZyB3aWR0aD0iNTIiIGhlaWdodD0iNTIiIHZpZXdCb3g9IjAgMCA1MiA1MiI+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImRiZyIgY3g9IjI2IiBjeT0iMjYiIHI9IjIyIi8+CiAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9ImR2IiBpZD0icmFtLXJpbmciIGN4PSIyNiIgY3k9IjI2IiByPSIyMiIgc3Ryb2tlPSIjM2I4MmY2IgogICAgICAgICAgICAgIHN0cm9rZS1kYXNoYXJyYXk9IjEzOC4yIiBzdHJva2UtZGFzaG9mZnNldD0iMTM4LjIiLz4KICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgPGRpdiBjbGFzcz0iZGMiIGlkPSJyYW0tcGN0Ij4tLSU8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTBweDtjb2xvcjp2YXIoLS1tdXRlZCkiIGlkPSJyYW0tZGV0YWlsIj4tLSAvIC0tIEdCPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGIiPjxkaXYgY2xhc3M9InBmIHB1IiBpZD0icmFtLWJhciIgc3R5bGU9IndpZHRoOjAlO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDkwZGVnLCMzYjgyZjYsIzYwYTVmYSkiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPvCfkr4gRElTSyBVU0FHRTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN2YWwiIGlkPSJkaXNrLXBjdCI+LS08c3Bhbj4lPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNzdWIiIGlkPSJkaXNrLWRldGFpbCI+LS0gLyAtLSBHQjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBiIj48ZGl2IGNsYXNzPSJwZiBwbyIgaWQ9ImRpc2stYmFyIiBzdHlsZT0id2lkdGg6MCUiPjwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2MiPgogICAgICAgIDxkaXYgY2xhc3M9InNsYmwiPuKPsSBVUFRJTUU8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdmFsIiBpZD0idXB0aW1lLXZhbCIgc3R5bGU9ImZvbnQtc2l6ZToyMHB4Ij4tLTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNzdWIiIGlkPSJ1cHRpbWUtc3ViIj4tLTwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InViZGciIGlkPSJsb2FkLWNoaXBzIj48L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7wn4yQIE5FVFdPUksgSS9PPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im5ldC1yb3ciPgogICAgICAgIDxkaXYgY2xhc3M9Im5pIj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5kIj7ihpEgVXBsb2FkPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJucyIgaWQ9Im5ldC11cCI+LS08c3Bhbj4gLS08L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJudCIgaWQ9Im5ldC11cC10b3RhbCI+dG90YWw6IC0tPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZGl2aWRlciI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ibmkiIHN0eWxlPSJ0ZXh0LWFsaWduOnJpZ2h0Ij4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5kIj7ihpMgRG93bmxvYWQ8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im5zIiBpZD0ibmV0LWRuIj4tLTxzcGFuPiAtLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9Im50IiBpZD0ibmV0LWRuLXRvdGFsIj50b3RhbDogLS08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7wn5OhIFgtVUkgUEFORUwgU1RBVFVTPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Inh1aS1yb3ciPgogICAgICAgIDxkaXYgaWQ9Inh1aS1waWxsIiBjbGFzcz0ib3BpbGwgb2ZmIj48c3BhbiBjbGFzcz0iZG90IHJlZCI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C5gOC4iuC5h+C4hC4uLjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9Inh1aS1pbmZvIj4KICAgICAgICAgIDxkaXY+4LmA4Lin4Lit4Lij4LmM4LiK4Lix4LiZIFhyYXk6IDxiIGlkPSJ4dWktdmVyIj4tLTwvYj48L2Rpdj4KICAgICAgICAgIDxkaXY+SW5ib3VuZHM6IDxiIGlkPSJ4dWktaW5ib3VuZHMiPi0tPC9iPiDguKPguLLguKLguIHguLLguKM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciIgc3R5bGU9Im1hcmdpbi1ib3R0b206MCI+CiAgICAgICAgPGRpdiBjbGFzcz0ic2VjLXRpdGxlIj7wn5SnIFNFUlZJQ0UgTU9OSVRPUjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkU2VydmljZXMoKSI+4oa7IOC5gOC4iuC5h+C4hDwvYnV0dG9uPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3ZjLWxpc3QiIGlkPSJzdmMtbGlzdCI+CiAgICAgICAgPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+CiAgICAgIDwvZGl2PgogICAgPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJsdSIgaWQ9Imxhc3QtdXBkYXRlIj7guK3guLHguJ7guYDguJTguJfguKXguYjguLLguKrguLjguJQ6IC0tPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIENSRUFURSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLWNyZWF0ZSI+CgogICAgPCEtLSDilIDilIAgU0VMRUNUT1IgKGRlZmF1bHQgdmlldykg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iY3JlYXRlLW1lbnUiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtbGFiZWwiPvCfm6Eg4Lij4Liw4Lia4LiaIDNYLVVJIFZMRVNTPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlbC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgnYWlzJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC1haXMiPjxpbWcgc3JjPSJodHRwczovL3VwbG9hZC53aWtpbWVkaWEub3JnL3dpa2lwZWRpYS9jb21tb25zL3RodW1iL2YvZjkvQUlTX2xvZ28uc3ZnLzIwMHB4LUFJU19sb2dvLnN2Zy5wbmciIG9uZXJyb3I9InRoaXMuc3R5bGUuZGlzcGxheT0nbm9uZSc7dGhpcy5uZXh0U2libGluZy5zdHlsZS5kaXNwbGF5PSdmbGV4JyIgc3R5bGU9IndpZHRoOjU2cHg7aGVpZ2h0OjU2cHg7b2JqZWN0LWZpdDpjb250YWluIj48c3BhbiBzdHlsZT0iZGlzcGxheTpub25lO2ZvbnQtc2l6ZToxLjRyZW07d2lkdGg6NTZweDtoZWlnaHQ6NTZweDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtmb250LXdlaWdodDo3MDA7Y29sb3I6IzNkN2EwZSI+QUlTPC9zcGFuPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1pbmZvIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1uYW1lIGFpcyI+QUlTIOKAkyDguIHguLHguJnguKPguLHguYjguKc8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODAgKEhBUHJveHnihpJOZ2lueOKGklhyYXkpIMK3IFdTIMK3IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9InNlbC1hcnJvdyI+4oC6PC9zcGFuPgogICAgICA8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic2VsLWNhcmQiIG9uY2xpY2s9Im9wZW5Gb3JtKCd0cnVlJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC10cnVlIj48c3BhbiBzdHlsZT0iZm9udC1zaXplOjEuMXJlbTtmb250LXdlaWdodDo5MDA7Y29sb3I6I2ZmZiI+dHJ1ZTwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InNlbC1zdWIiPlZMRVNTIMK3IFBvcnQgODAgKEhBUHJveHnihpJOZ2lueOKGklhyYXkpIMK3IFdTIMK3IHRydWUtaW50ZXJuZXQuem9vbS54eXouc2VydmljZXM8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8c3BhbiBjbGFzcz0ic2VsLWFycm93Ij7igLo8L3NwYW4+CiAgICAgIDwvZGl2PgoKICAgICAgPGRpdiBjbGFzcz0ic2VjLWxhYmVsIiBzdHlsZT0ibWFyZ2luLXRvcDoyMHB4Ij7wn5SRIOC4o+C4sOC4muC4miBTU0ggV0VCU09DS0VUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNlbC1jYXJkIiBvbmNsaWNrPSJvcGVuRm9ybSgnc3NoJykiPgogICAgICAgIDxkaXYgY2xhc3M9InNlbC1sb2dvIHNlbC1zc2giPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjcwMDtjb2xvcjojZmZmO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZSI+U1NIJmd0Ozwvc3Bhbj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtaW5mbyI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtbmFtZSBzc2giPlNTSCDigJMgV1MgVHVubmVsPC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzZWwtc3ViIj5TU0ggwrcgUG9ydCA4MCAoSEFQcm94eeKGkk5naW544oaSbnB4cHJveHkpIMK3IERyb3BiZWFyIDE0My8xMDk8YnI+TnB2VHVubmVsIC8gRGFya1R1bm5lbDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJzZWwtYXJyb3ciPuKAujwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBBSVMg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1haXMiIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICAgIDxkaXYgY2xhc3M9ImZvcm0taGRyIGFpcy1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1sb2dvIHNlbC1haXMtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6LjhyZW07Zm9udC13ZWlnaHQ6NzAwO2NvbG9yOiMzZDdhMGUiPkFJUzwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9ImZvcm0tdGl0bGUgYWlzIj5BSVMg4oCTIOC4geC4seC4meC4o+C4seC5iOC4pzwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJmb3JtLXN1YiI+VkxFU1MgwrcgUG9ydCA4MCDCtyBTTkk6IGNqLWViYi5zcGVlZHRlc3QubmV0PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZW1haWwiIHBsYWNlaG9sZGVyPSJ1c2VyQGFpcyI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk4Ug4Lin4Lix4LiZ4LmD4LiK4LmJ4LiH4Liy4LiZICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJhaXMtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0iYWlzLWlwIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIyIiBtaW49IjEiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7wn5K+IERhdGEgR0IgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9ImFpcy1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMCIgbWluPSIwIj48L2Rpdj4KICAgICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIGNidG4tYWlzIiBpZD0iYWlzLWJ0biIgb25jbGljaz0iY3JlYXRlVkxFU1MoJ2FpcycpIj7imqEg4Liq4Lij4LmJ4Liy4LiHIEFJUyBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJhaXMtYWxlcnQiPjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InJlcy1ib3giIGlkPSJhaXMtcmVzdWx0Ij4KICAgICAgICAgIDxidXR0b24gY2xhc3M9InJlcy1jbG9zZSIgb25jbGljaz0iZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Fpcy1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici1haXMtZW1haWwiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn4aUIFVVSUQ8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IG1vbm8iIGlkPSJyLWFpcy11dWlkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+ThSDguKvguKHguJTguK3guLLguKLguLg8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IGdyZWVuIiBpZD0ici1haXMtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici1haXMtbGluayI+LS08L2Rpdj4KICAgICAgICAgIDxidXR0b24gY2xhc3M9ImNvcHktYnRuIiBvbmNsaWNrPSJjb3B5TGluaygnci1haXMtbGluaycsdGhpcykiPvCfk4sgQ29weSBWTEVTUyBMaW5rPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGlkPSJhaXMtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBUUlVFIOKUgOKUgCAtLT4KICAgIDxkaXYgaWQ9ImZvcm0tdHJ1ZSIgc3R5bGU9ImRpc3BsYXk6bm9uZSI+CiAgICAgIDxkaXYgY2xhc3M9ImZvcm0tYmFjayIgb25jbGljaz0iY2xvc2VGb3JtKCkiPuKAuSDguIHguKXguLHguJo8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1oZHIgdHJ1ZS1oZHIiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic2VsLWxvZ28gc2VsLXRydWUtc20iPjxzcGFuIHN0eWxlPSJmb250LXNpemU6Ljc1cmVtO2ZvbnQtd2VpZ2h0OjkwMDtjb2xvcjojZmZmIj50cnVlPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS10aXRsZSB0cnVlIj5UUlVFIOKAkyBWRE88L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0iZm9ybS1zdWIiPlZMRVNTIMK3IFBvcnQgODAgwrcgU05JOiB0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+RpCBFTUFJTCAvIOC4iuC4t+C5iOC4reC4ouC4ueC4qjwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWVtYWlsIiBwbGFjZWhvbGRlcj0idXNlckB0cnVlIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+ThSDguKfguLHguJnguYPguIrguYnguIfguLLguJkgKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9InRydWUtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMCI+PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfk7EgSVAgTElNSVQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0idHJ1ZS1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIgbWluPSIxIj48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJmZyI+PGRpdiBjbGFzcz0iZmxibCI+8J+SviBEYXRhIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKTwvZGl2PjxpbnB1dCBjbGFzcz0iZmkiIGlkPSJ0cnVlLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4gY2J0bi10cnVlIiBpZD0idHJ1ZS1idG4iIG9uY2xpY2s9ImNyZWF0ZVZMRVNTKCd0cnVlJykiPuKaoSDguKrguKPguYnguLLguIcgVFJVRSBBY2NvdW50PC9idXR0b24+CiAgICAgICAgPGRpdiBjbGFzcz0iYWxlcnQiIGlkPSJ0cnVlLWFsZXJ0Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtYm94IiBpZD0idHJ1ZS1yZXN1bHQiPgogICAgICAgICAgPGJ1dHRvbiBjbGFzcz0icmVzLWNsb3NlIiBvbmNsaWNrPSJkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndHJ1ZS1yZXN1bHQnKS5zdHlsZS5kaXNwbGF5PSdub25lJyI+4pyVPC9idXR0b24+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJyZXMtcm93Ij48c3BhbiBjbGFzcz0icmVzLWsiPvCfk6cgRW1haWw8L3NwYW4+PHNwYW4gY2xhc3M9InJlcy12IiBpZD0ici10cnVlLWVtYWlsIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1yb3ciPjxzcGFuIGNsYXNzPSJyZXMtayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJyZXMtdiBtb25vIiBpZD0ici10cnVlLXV1aWQiPi0tPC9zcGFuPjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0icmVzLXJvdyI+PHNwYW4gY2xhc3M9InJlcy1rIj7wn5OFIOC4q+C4oeC4lOC4reC4suC4ouC4uDwvc3Bhbj48c3BhbiBjbGFzcz0icmVzLXYgZ3JlZW4iIGlkPSJyLXRydWUtZXhwIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InJlcy1saW5rIiBpZD0ici10cnVlLWxpbmsiPi0tPC9kaXY+CiAgICAgICAgICA8YnV0dG9uIGNsYXNzPSJjb3B5LWJ0biIgb25jbGljaz0iY29weUxpbmsoJ3ItdHJ1ZS1saW5rJyx0aGlzKSI+8J+TiyBDb3B5IFZMRVNTIExpbms8L2J1dHRvbj4KICAgICAgICAgIDxkaXYgaWQ9InRydWUtcXIiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tdG9wOjEycHg7Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CiAgICA8L2Rpdj4KCiAgICA8IS0tIOKUgOKUgCBGT1JNOiBTU0gg4pSA4pSAIC0tPgogICAgPGRpdiBpZD0iZm9ybS1zc2giIHN0eWxlPSJkaXNwbGF5Om5vbmUiPgogICAgICA8ZGl2IGNsYXNzPSJmb3JtLWJhY2siIG9uY2xpY2s9ImNsb3NlRm9ybSgpIj7igLkg4LiB4Lil4Lix4LiaPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9InNzaC1kYXJrLWZvcm0iPgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstaGRyIj7inpUg4LmA4Lie4Li04LmI4LihIFNTSCBVU0VSPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1maWVsZCI+CiAgICAgICAgICA8bGFiZWwgY2xhc3M9ImRhcmstbGFiZWwiPuC4iuC4t+C5iOC4reC4nOC4ueC5ieC5g+C4iuC5iTwvbGFiZWw+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9ImRhcmstaW5wdXQiIGlkPSJzc2gtdXNlciIgcGxhY2Vob2xkZXI9InVzZXJuYW1lIiBhdXRvY29tcGxldGU9Im9mZiIvPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstZmllbGQiPgogICAgICAgICAgPGxhYmVsIGNsYXNzPSJkYXJrLWxhYmVsIj7guKPguKvguLHguKrguJzguYjguLLguJk8L2xhYmVsPgogICAgICAgICAgPGlucHV0IGNsYXNzPSJkYXJrLWlucHV0IiBpZD0ic3NoLXBhc3MiIHBsYWNlaG9sZGVyPSJwYXNzd29yZCIgdHlwZT0icGFzc3dvcmQiIGF1dG9jb21wbGV0ZT0ib2ZmIi8+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0iZGFyay1maWVsZCI+CiAgICAgICAgICA8bGFiZWwgY2xhc3M9ImRhcmstbGFiZWwiPuC4iOC4s+C4meC4p+C4meC4p+C4seC4mTwvbGFiZWw+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9ImRhcmstaW5wdXQiIGlkPSJzc2gtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiLz4KICAgICAgICA8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWZpZWxkIj4KICAgICAgICAgIDxsYWJlbCBjbGFzcz0iZGFyay1sYWJlbCI+4Lil4Li04Lih4Li04LiV4LmE4Lit4Lie4Li1PC9sYWJlbD4KICAgICAgICAgIDxpbnB1dCBjbGFzcz0iZGFyay1pbnB1dCIgaWQ9InNzaC1pcCIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMiIvPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIj7wn4yQIOC5gOC4peC4t+C4reC4gSBJU1AgLyBPUEVSQVRPUjwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InBpY2stZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJwaWNrLW9wdCBhLWR0YWMiIGlkPSJwcm8tZHRhYyIgb25jbGljaz0icGlja1BybygnZHRhYycpIj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icGkiPvCfn6A8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRUQUMgR0FNSU5HPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBzIj5kbC5kaXIuZnJlZWZpcmVtb2JpbGUuY29tPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0icHJvLXRydWUiIG9uY2xpY2s9InBpY2tQcm8oJ3RydWUnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj7wn5S1PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBuIj5UUlVFIFRXSVRURVI8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmhlbHAueC5jb208L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzPSJkYXJrLWxibCI+8J+TsSDguYDguKXguLfguK3guIEgQVBQPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0icGljay1ncmlkIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IGEtbnB2IiBpZD0iYXBwLW5wdiIgb25jbGljaz0icGlja0FwcCgnbnB2JykiPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJwaSI+PGRpdiBzdHlsZT0id2lkdGg6MzhweDtoZWlnaHQ6MzhweDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMGQyYTNhO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjttYXJnaW46MCBhdXRvIC4xcmVtO2ZvbnQtZmFtaWx5Om1vbm9zcGFjZTtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi44NXJlbTtjb2xvcjojMDBjY2ZmO2xldHRlci1zcGFjaW5nOi0xcHg7Ym9yZGVyOjEuNXB4IHNvbGlkIHJnYmEoMCwyMDQsMjU1LC4zKSI+blY8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPk5wdiBUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPm5wdnQtc3NoOi8vPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InBpY2stb3B0IiBpZD0iYXBwLWRhcmsiIG9uY2xpY2s9InBpY2tBcHAoJ2RhcmsnKSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InBpIj48ZGl2IHN0eWxlPSJ3aWR0aDozOHB4O2hlaWdodDozOHB4O2JvcmRlci1yYWRpdXM6MTBweDtiYWNrZ3JvdW5kOiMxMTE7ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO21hcmdpbjowIGF1dG8gLjFyZW07Zm9udC1mYW1pbHk6c2Fucy1zZXJpZjtmb250LXdlaWdodDo5MDA7Zm9udC1zaXplOi42MnJlbTtjb2xvcjojZmZmO2xldHRlci1zcGFjaW5nOi41cHg7Ym9yZGVyOjEuNXB4IHNvbGlkICM0NDQiPkRBUks8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icG4iPkRhcmtUdW5uZWw8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzcz0icHMiPmRhcmt0dW5uZWw6Ly88L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgCgogICAgICAgIDwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImNidG4tc3NoIiBpZD0ic3NoLWJ0biIgb25jbGljaz0iY3JlYXRlU1NIKCkiPuKelSDguKrguKPguYnguLLguIcgVXNlcjwvYnV0dG9uPgogICAgICAgIDxkaXYgY2xhc3M9ImFsZXJ0IiBpZD0ic3NoLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJsaW5rLXJlc3VsdCIgaWQ9InNzaC1saW5rLXJlc3VsdCI+PC9kaXY+CiAgICAgIDwvZGl2PgoKICAgICAgPCEtLSBVc2VyIHRhYmxlIC0tPgogICAgICA8ZGl2IGNsYXNzPSJjYXJkIiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICAgIDxkaXYgY2xhc3M9ImRhcmstbGJsIiBzdHlsZT0ibWFyZ2luOjAiPvCfk4sg4Lij4Liy4Lii4LiK4Li34LmI4LitIFVTRVJTPC9kaXY+CiAgICAgICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJzc2gtc2VhcmNoIiBwbGFjZWhvbGRlcj0i4LiE4LmJ4LiZ4Lir4LiyLi4uIiBvbmlucHV0PSJmaWx0ZXJTU0hVc2Vycyh0aGlzLnZhbHVlKSIKICAgICAgICAgICAgc3R5bGU9IndpZHRoOjEyMHB4O21hcmdpbjowO2ZvbnQtc2l6ZToxMXB4O3BhZGRpbmc6NnB4IDEwcHgiPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InV0Ymwtd3JhcCI+CiAgICAgICAgICA8dGFibGUgY2xhc3M9InV0YmwiPgogICAgICAgICAgICA8dGhlYWQ+PHRyPjx0aD4jPC90aD48dGg+VVNFUk5BTUU8L3RoPjx0aD7guKvguKHguJTguK3guLLguKLguLg8L3RoPjx0aD7guKrguJbguLLguJnguLA8L3RoPjx0aD5BQ1RJT048L3RoPjwvdHI+PC90aGVhZD4KICAgICAgICAgICAgPHRib2R5IGlkPSJzc2gtdXNlci10Ym9keSI+PHRyPjx0ZCBjb2xzcGFuPSI1IiBzdHlsZT0idGV4dC1hbGlnbjpjZW50ZXI7cGFkZGluZzoyMHB4O2NvbG9yOnZhcigtLW11dGVkKSI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC90ZD48L3RyPjwvdGJvZHk+CiAgICAgICAgICA8L3RhYmxlPgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgoKICA8L2Rpdj48IS0tIC90YWItY3JlYXRlIC0tPgoKPCEtLSDilZDilZDilZDilZAgTUFOQUdFIOKVkOKVkOKVkOKVkCAtLT4KICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItbWFuYWdlIj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiPgogICAgICA8ZGl2IGNsYXNzPSJzZWMtaGRyIj4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW4tYm90dG9tOjAiPvCflKcg4LiI4Lix4LiU4LiB4Liy4Lij4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMIFZMRVNTPC9kaXY+CiAgICAgICAgPGJ1dHRvbiBjbGFzcz0iYnRuLXIiIG9uY2xpY2s9ImxvYWRVc2VycygpIj7ihrsg4LmC4Lir4Lil4LiUPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8aW5wdXQgY2xhc3M9InNib3giIGlkPSJ1c2VyLXNlYXJjaCIgcGxhY2Vob2xkZXI9IvCflI0gIOC4hOC5ieC4meC4q+C4siB1c2VybmFtZS4uLiIgb25pbnB1dD0iZmlsdGVyVXNlcnModGhpcy52YWx1ZSkiPgogICAgICA8ZGl2IGlkPSJ1c2VyLWxpc3QiPjxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4lOC4m+C4uOC5iOC4oeC5guC4q+C4peC4lOC5gOC4nuC4t+C5iOC4reC4lOC4tuC4h+C4guC5ieC4reC4oeC4ueC4pTwvZGl2PjwvZGl2PgogICAgPC9kaXY+CiAgPC9kaXY+CgogIDwhLS0g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAgLS0+CiAgPGRpdiBjbGFzcz0ic2VjIiBpZD0idGFiLW9ubGluZSI+CiAgICA8ZGl2IGNsYXNzPSJjYXJkIj4KICAgICAgPGRpdiBjbGFzcz0ic2VjLWhkciI+CiAgICAgICAgPGRpdiBjbGFzcz0iZnRpdGxlIiBzdHlsZT0ibWFyZ2luLWJvdHRvbTowIj7wn5+iIOC4ouC4ueC4quC5gOC4i+C4reC4o+C5jOC4reC4reC4meC5hOC4peC4meC5jOC4leC4reC4meC4meC4teC5iTwvZGl2PgogICAgICAgIDxidXR0b24gY2xhc3M9ImJ0bi1yIiBvbmNsaWNrPSJsb2FkT25saW5lKCkiPuKGuyDguKPguLXguYDguJ/guKPguIo8L2J1dHRvbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9Im9jciI+CiAgICAgICAgPGRpdiBjbGFzcz0ib3BpbGwiIGlkPSJvbmxpbmUtcGlsbCI+PHNwYW4gY2xhc3M9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJvbmxpbmUtY291bnQiPjA8L3NwYW4+IOC4reC4reC4meC5hOC4peC4meC5jDwvZGl2PgogICAgICAgIDxzcGFuIGNsYXNzPSJ1dCIgaWQ9Im9ubGluZS10aW1lIj4tLTwvc3Bhbj4KICAgICAgPC9kaXY+CiAgICAgIDxkaXYgaWQ9Im9ubGluZS1saXN0Ij48ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguJTguKPguLXguYDguJ/guKPguIrguYDguJ7guLfguYjguK3guJTguLnguJzguLnguYnguYPguIrguYnguK3guK3guJnguYTguKXguJnguYw8L2Rpdj48L2Rpdj4KICAgIDwvZGl2PgogIDwvZGl2PgoKICA8IS0tIOKVkOKVkOKVkOKVkCBCQU4g4pWQ4pWQ4pWQ4pWQIC0tPgogIDxkaXYgY2xhc3M9InNlYyIgaWQ9InRhYi1iYW4iPgogICAgPGRpdiBjbGFzcz0iY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9ImZ0aXRsZSI+8J+UkyDguJvguKXguJTguKXguYfguK3guIQgSVAgQmFuPC9kaXY+CiAgICAgIDxwIHN0eWxlPSJmb250LXNpemU6MTNweDtjb2xvcjojNjY2O21hcmdpbi1ib3R0b206MTJweCI+4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmM4LiX4Li14LmI4LmD4LiK4LmJIElQIOC5gOC4geC4tOC4mSBMaW1pdCDguIjguLDguJbguLnguIHguKXguYfguK3guITguIrguLHguYjguKfguITguKPguLLguKcgMSDguIrguLHguYjguKfguYLguKHguIc8YnI+4LiB4Lij4Lit4LiBIFVzZXJuYW1lIOC5gOC4nuC4t+C5iOC4reC4m+C4peC4lOC4peC5h+C4reC4hOC4l+C4seC4meC4l+C4tTwvcD4KICAgICAgPGRpdiBjbGFzcz0iZmciPjxkaXYgY2xhc3M9ImZsYmwiPvCfkaQgVVNFUk5BTUUg4LiX4Li14LmI4LmB4Lia4LiZPC9kaXY+CiAgICAgICAgPGlucHV0IGNsYXNzPSJmaSIgaWQ9ImJhbi11c2VyIiBwbGFjZWhvbGRlcj0i4LiB4Lij4Lit4LiBIHVzZXJuYW1lIOC4l+C4teC5iOC4leC5ieC4reC4h+C4geC4suC4o+C4m+C4peC4lOC4peC5h+C4reC4hCI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIHN0eWxlPSJiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCgxMzVkZWcsIzkyNDAwZSwjZjU5ZTBiKSIgb25jbGljaz0idW5iYW5Vc2VyKCkiPvCflJMg4Lib4Lil4LiU4Lil4LmH4Lit4LiEIElQIEJhbjwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9ImJhbi1hbGVydCI+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImNhcmQiIHN0eWxlPSJtYXJnaW4tdG9wOjRweCI+CiAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXI7bWFyZ2luLWJvdHRvbToxMnB4Ij4KICAgICAgICA8ZGl2IGNsYXNzPSJmdGl0bGUiIHN0eWxlPSJtYXJnaW46MCI+4o+x77iPIOC4o+C4suC4ouC4geC4suC4o+C4l+C4teC5iOC4luC4ueC4geC5geC4muC4meC4reC4ouC4ueC5iDwvZGl2PgogICAgICAgIDxidXR0b24gb25jbGljaz0ibG9hZEJhbm5lZCgpIiBzdHlsZT0iYmFja2dyb3VuZDpub25lO2JvcmRlcjoxcHggc29saWQgI2RkZDtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjRweCAxMnB4O2ZvbnQtc2l6ZToxMnB4O2N1cnNvcjpwb2ludGVyIj7ihrog4Lij4Li14LmA4Lif4Lij4LiKPC9idXR0b24+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGlkPSJiYW5uZWQtbGlzdCI+PGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+PC9kaXY+CiAgICA8L2Rpdj4KICA8L2Rpdj4KICAKCgogIDwhLS0gU1BFRUQgVEVTVCBUQUIgLS0+CiAgICA8ZGl2IGNsYXNzPSJzZWMiIGlkPSJ0YWItc3BlZWQiPgogICAgPHN0eWxlPgogICAgICAuc3QtY2FyZHtiYWNrZ3JvdW5kOiNmZmY7Ym9yZGVyLXJhZGl1czoyMHB4O3BhZGRpbmc6MjRweCAxNnB4O2JveC1zaGFkb3c6MCAycHggMTZweCByZ2JhKDAsMCwwLDAuMDgpO21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6MTFweDtsZXR0ZXItc3BhY2luZzozcHg7Y29sb3I6I2Y1OWUwYjt0ZXh0LWFsaWduOmNlbnRlcjttYXJnaW4tYm90dG9tOjIwcHg7fQogICAgICAuc3QtY2lyY2xlc3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWFyb3VuZDthbGlnbi1pdGVtczpjZW50ZXI7bWFyZ2luLWJvdHRvbToxNnB4O30KICAgICAgLnN0LWNpcmNsZS13cmFwe3RleHQtYWxpZ246Y2VudGVyO30KICAgICAgLnN0LWNpcmNsZXtwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDoxMDBweDtoZWlnaHQ6MTAwcHg7bWFyZ2luOjAgYXV0byA4cHg7fQogICAgICAuc3QtY2lyY2xlIHN2Z3t0cmFuc2Zvcm06cm90YXRlKC05MGRlZyk7fQogICAgICAuc3QtY2lyY2xlLWJne2ZpbGw6bm9uZTtzdHJva2U6I2YwZjBmMDtzdHJva2Utd2lkdGg6ODt9CiAgICAgIC5zdC1jaXJjbGUtZmlsbC1waW5ne2ZpbGw6bm9uZTtzdHJva2U6IzIyYzU1ZTtzdHJva2Utd2lkdGg6ODtzdHJva2UtbGluZWNhcDpyb3VuZDtzdHJva2UtZGFzaGFycmF5OjI4Mzt0cmFuc2l0aW9uOnN0cm9rZS1kYXNob2Zmc2V0IDAuOHMgZWFzZTt9CiAgICAgIC5zdC1jaXJjbGUtZmlsbC1kbHtmaWxsOm5vbmU7c3Ryb2tlOiMzYjgyZjY7c3Ryb2tlLXdpZHRoOjg7c3Ryb2tlLWxpbmVjYXA6cm91bmQ7c3Ryb2tlLWRhc2hhcnJheToyODM7dHJhbnNpdGlvbjpzdHJva2UtZGFzaG9mZnNldCAwLjhzIGVhc2U7fQogICAgICAuc3QtY2lyY2xlLWZpbGwtdWx7ZmlsbDpub25lO3N0cm9rZTojYTg1NWY3O3N0cm9rZS13aWR0aDo4O3N0cm9rZS1saW5lY2FwOnJvdW5kO3N0cm9rZS1kYXNoYXJyYXk6MjgzO3RyYW5zaXRpb246c3Ryb2tlLWRhc2hvZmZzZXQgMC44cyBlYXNlO30KICAgICAgLnN0LWNpcmNsZS1pbm5lcntwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2Rpc3BsYXk6ZmxleDtmbGV4LWRpcmVjdGlvbjpjb2x1bW47YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7fQogICAgICAuc3QtY2lyY2xlLXZhbHtmb250LXNpemU6MjBweDtmb250LXdlaWdodDo5MDA7Y29sb3I6IzFlMjkzYjtsaW5lLWhlaWdodDoxO30KICAgICAgLnN0LWNpcmNsZS11bml0e2ZvbnQtc2l6ZTo5cHg7Y29sb3I6Izk0YTNiODttYXJnaW4tdG9wOjJweDt9CiAgICAgIC5zdC1jaXJjbGUtbGFiZWx7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjlweDtsZXR0ZXItc3BhY2luZzoycHg7Y29sb3I6IzY0NzQ4Yjt9CiAgICAgIC5zdC1jaXJjbGUtbGFiZWwucGluZ3tjb2xvcjojMjJjNTVlO30KICAgICAgLnN0LWNpcmNsZS1sYWJlbC5kbHtjb2xvcjojM2I4MmY2O30KICAgICAgLnN0LWNpcmNsZS1sYWJlbC51bHtjb2xvcjojYTg1NWY3O30KICAgICAgLnN0LXN0YXR1c3t0ZXh0LWFsaWduOmNlbnRlcjtmb250LXNpemU6MTJweDtjb2xvcjojNjQ3NDhiO21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC1wcm9ne2hlaWdodDo0cHg7YmFja2dyb3VuZDojZjBmMGYwO2JvcmRlci1yYWRpdXM6OTlweDtvdmVyZmxvdzpoaWRkZW47bWFyZ2luLWJvdHRvbToxNnB4O30KICAgICAgLnN0LXByb2ctZmlsbHtoZWlnaHQ6MTAwJTt3aWR0aDowJTtiYWNrZ3JvdW5kOmxpbmVhci1ncmFkaWVudCg5MGRlZywjMjJjNTVlLCMzYjgyZjYpO2JvcmRlci1yYWRpdXM6OTlweDt0cmFuc2l0aW9uOndpZHRoIDAuM3MgZWFzZTt9CiAgICAgIC5zdC1idG57d2lkdGg6MTAwJTtwYWRkaW5nOjE2cHg7Ym9yZGVyLXJhZGl1czoxNHB4O2JvcmRlcjpub25lO2JhY2tncm91bmQ6bGluZWFyLWdyYWRpZW50KDEzNWRlZywjMTZhMzRhLCMyMmM1NWUpO2NvbG9yOiNmZmY7Zm9udC1mYW1pbHk6J09yYml0cm9uJyxtb25vc3BhY2U7Zm9udC1zaXplOjEzcHg7Zm9udC13ZWlnaHQ6NzAwO2xldHRlci1zcGFjaW5nOjJweDtjdXJzb3I6cG9pbnRlcjtib3gtc2hhZG93OjAgNHB4IDE2cHggcmdiYSgzNCwxOTcsOTQsMC40KTt0cmFuc2l0aW9uOmFsbCAwLjJzO21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC1idG46aG92ZXJ7dHJhbnNmb3JtOnRyYW5zbGF0ZVkoLTJweCk7Ym94LXNoYWRvdzowIDhweCAyNHB4IHJnYmEoMzQsMTk3LDk0LDAuNSk7fQogICAgICAuc3QtYnRuOmRpc2FibGVke29wYWNpdHk6MC41O2N1cnNvcjpub3QtYWxsb3dlZDt0cmFuc2Zvcm06bm9uZTt9CiAgICAgIC5zdC1yZXN1bHR7YmFja2dyb3VuZDojZjhmYWZjO2JvcmRlci1yYWRpdXM6MTRweDtwYWRkaW5nOjE2cHg7Ym9yZGVyOjFweCBzb2xpZCAjZTJlOGYwO30KICAgICAgLnN0LXJlc3VsdC10aXRsZXtmb250LWZhbWlseTonT3JiaXRyb24nLG1vbm9zcGFjZTtmb250LXNpemU6OXB4O2xldHRlci1zcGFjaW5nOjNweDtjb2xvcjojOTRhM2I4O21hcmdpbi1ib3R0b206MTJweDt9CiAgICAgIC5zdC1yZXN1bHQtZ3JpZHtkaXNwbGF5OmdyaWQ7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjFmciAxZnI7Z2FwOjEwcHg7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLWxhYmVse2ZvbnQtc2l6ZToxMHB4O2NvbG9yOiM5NGEzYjg7bWFyZ2luLWJvdHRvbToycHg7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLXZhbHtmb250LXNpemU6MTNweDtmb250LXdlaWdodDo3MDA7Y29sb3I6IzFlMjkzYjt9CiAgICAgIC5zdC1yZXN1bHQtaXRlbSAuc3QtcmktdmFsLmdyZWVue2NvbG9yOiMyMmM1NWU7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLXZhbC5ibHVle2NvbG9yOiMzYjgyZjY7fQogICAgICAuc3QtcmVzdWx0LWl0ZW0gLnN0LXJpLXZhbC5wdXJwbGV7Y29sb3I6I2E4NTVmNzt9CiAgICA8L3N0eWxlPgogICAgPGRpdiBjbGFzcz0ic3QtY2FyZCI+CiAgICAgIDxkaXYgY2xhc3M9InN0LXRpdGxlIj7imqEgVlBTIFNQRUVEIFRFU1Q8L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlcyI+CiAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXdyYXAiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjEwMCIgaGVpZ2h0PSIxMDAiPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1iZyIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1Ii8+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3QtY2lyY2xlLWZpbGwtcGluZyIgaWQ9ImMtcGluZyIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1IiBzdHJva2UtZGFzaG9mZnNldD0iMjgzIi8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtaW5uZXIiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS12YWwiIGlkPSJzdC1waW5nLXZhbCI+LS08L2Rpdj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtdW5pdCI+bXM8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1sYWJlbCBwaW5nIj5QSU5HPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXdyYXAiPgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlIj4KICAgICAgICAgICAgPHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgd2lkdGg9IjEwMCIgaGVpZ2h0PSIxMDAiPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1iZyIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1Ii8+CiAgICAgICAgICAgICAgPGNpcmNsZSBjbGFzcz0ic3QtY2lyY2xlLWZpbGwtZGwiIGlkPSJjLWRsIiBjeD0iNTAiIGN5PSI1MCIgcj0iNDUiIHN0cm9rZS1kYXNob2Zmc2V0PSIyODMiLz4KICAgICAgICAgICAgPC9zdmc+CiAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1pbm5lciI+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXZhbCIgaWQ9InN0LWRsLXZhbCI+LS08L2Rpdj4KICAgICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtdW5pdCI+TWJwczwvZGl2PgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLWxhYmVsIGRsIj5ET1dOTE9BRDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS13cmFwIj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZSI+CiAgICAgICAgICAgIDxzdmcgdmlld0JveD0iMCAwIDEwMCAxMDAiIHdpZHRoPSIxMDAiIGhlaWdodD0iMTAwIj4KICAgICAgICAgICAgICA8Y2lyY2xlIGNsYXNzPSJzdC1jaXJjbGUtYmciIGN4PSI1MCIgY3k9IjUwIiByPSI0NSIvPgogICAgICAgICAgICAgIDxjaXJjbGUgY2xhc3M9InN0LWNpcmNsZS1maWxsLXVsIiBpZD0iYy11bCIgY3g9IjUwIiBjeT0iNTAiIHI9IjQ1IiBzdHJva2UtZGFzaG9mZnNldD0iMjgzIi8+CiAgICAgICAgICAgIDwvc3ZnPgogICAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1jaXJjbGUtaW5uZXIiPgogICAgICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS12YWwiIGlkPSJzdC11bC12YWwiPi0tPC9kaXY+CiAgICAgICAgICAgICAgPGRpdiBjbGFzcz0ic3QtY2lyY2xlLXVuaXQiPk1icHM8L2Rpdj4KICAgICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LWNpcmNsZS1sYWJlbCB1bCI+VVBMT0FEPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdC1zdGF0dXMiIGlkPSJzdC1zdGF0dXMiPuC4geC4lOC4m+C4uOC5iOC4oeC5gOC4nuC4t+C5iOC4reC5gOC4o+C4tOC5iOC4oeC4l+C4lOC4quC4reC4mjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJzdC1wcm9nIj48ZGl2IGNsYXNzPSJzdC1wcm9nLWZpbGwiIGlkPSJzdC1wcm9nIj48L2Rpdj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0ic3QtYnRuIiBpZD0ic3QtYnRuIiBvbmNsaWNrPSJzdGFydE5ld1NwZWVkVGVzdCgpIj7ilrYgU1RBUlQgVEVTVDwvYnV0dG9uPgogICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQiPgogICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC10aXRsZSI+VEVTVCBSRVNVTFQ8L2Rpdj4KICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtZ3JpZCI+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCfjJAgU2VydmVyIElQPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIiBpZD0ic3QtaXAiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCfk40gTG9jYXRpb248L2Rpdj48ZGl2IGNsYXNzPSJzdC1yaS12YWwiIGlkPSJzdC1sb2MiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCfj5MgUGluZzwvZGl2PjxkaXYgY2xhc3M9InN0LXJpLXZhbCBncmVlbiIgaWQ9InN0LXItcGluZyI+LS08L2Rpdj48L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3M9InN0LXJlc3VsdC1pdGVtIj48ZGl2IGNsYXNzPSJzdC1yaS1sYWJlbCI+4qyH77iPIERvd25sb2FkPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIGJsdWUiIGlkPSJzdC1yLWRsIj4tLTwvZGl2PjwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0ic3QtcmVzdWx0LWl0ZW0iPjxkaXYgY2xhc3M9InN0LXJpLWxhYmVsIj7irIbvuI8gVXBsb2FkPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIHB1cnBsZSIgaWQ9InN0LXItdWwiPi0tPC9kaXY+PC9kaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzPSJzdC1yZXN1bHQtaXRlbSI+PGRpdiBjbGFzcz0ic3QtcmktbGFiZWwiPvCflZAgVGVzdGVkPC9kaXY+PGRpdiBjbGFzcz0ic3QtcmktdmFsIiBpZD0ic3Qtci10aW1lIj4tLTwvZGl2PjwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj4KICAgIDwvZGl2PgogICAgPHNjcmlwdD4KICAgIGFzeW5jIGZ1bmN0aW9uIHN0YXJ0TmV3U3BlZWRUZXN0KCkgewogICAgICBjb25zdCBidG4gPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtYnRuJyk7CiAgICAgIGJ0bi5kaXNhYmxlZCA9IHRydWU7CiAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfij7Mg4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIFZQUy4uLic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1zdGF0dXMnKS50ZXh0Q29udGVudCA9ICfguIHguLPguKXguLHguIfguJfguJTguKrguK3guJrguKrguJvguLXguJQgVlBTIOC4iOC4o+C4tOC4hy4uLic7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1wcm9nJykuc3R5bGUud2lkdGggPSAnMTAlJzsKICAgICAgWydjLXBpbmcnLCdjLWRsJywnYy11bCddLmZvckVhY2goaWQgPT4gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpLnN0eWxlLnN0cm9rZURhc2hvZmZzZXQgPSAnMjgzJyk7CiAgICAgIFsnc3QtcGluZy12YWwnLCdzdC1kbC12YWwnLCdzdC11bC12YWwnXS5mb3JFYWNoKGlkID0+IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudCA9ICcuLi4nKTsKCiAgICAgIC8vIGFuaW1hdGUgcHJvZ3Jlc3Mgd2hpbGUgd2FpdGluZwogICAgICBsZXQgcHJvZyA9IDEwOwogICAgICBjb25zdCBwcm9nSW50ID0gc2V0SW50ZXJ2YWwoKCkgPT4gewogICAgICAgIGlmKHByb2cgPCA5MCkgeyBwcm9nICs9IDI7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1wcm9nJykuc3R5bGUud2lkdGggPSBwcm9nICsgJyUnOyB9CiAgICAgIH0sIDEwMDApOwoKICAgICAgdHJ5IHsKICAgICAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goJy9hcGkvc3BlZWR0ZXN0Jyx7bWV0aG9kOidQT1NUJ30pLnRoZW4ocj0+ci5qc29uKCkpOwogICAgICAgIGNsZWFySW50ZXJ2YWwocHJvZ0ludCk7CiAgICAgICAgaWYoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yIHx8ICfguKXguYnguKHguYDguKvguKXguKcnKTsKCiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXBpbmctdmFsJykudGV4dENvbnRlbnQgPSBkLnBpbmc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LWRsLXZhbCcpLnRleHRDb250ZW50ID0gZC5kb3dubG9hZDsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtdWwtdmFsJykudGV4dENvbnRlbnQgPSBkLnVwbG9hZDsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtci1waW5nJykudGV4dENvbnRlbnQgPSBkLnBpbmcgKyAnIG1zJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3Qtci1kbCcpLnRleHRDb250ZW50ID0gZC5kb3dubG9hZCArICcgTWJwcyc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXItdWwnKS50ZXh0Q29udGVudCA9IGQudXBsb2FkICsgJyBNYnBzJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtaXAnKS50ZXh0Q29udGVudCA9IGQuaXAgfHwgJy0tJzsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3QtbG9jJykudGV4dENvbnRlbnQgPSBkLnNlcnZlciB8fCAnLS0nOwogICAgICAgIGNvbnN0IHQgPSBuZXcgRGF0ZShkLnRpbWVzdGFtcCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXItdGltZScpLnRleHRDb250ZW50ID0gdC50b1RpbWVTdHJpbmcoKS5zbGljZSgwLDgpOwoKICAgICAgICBzZXRDaXJjbGUoJ2MtcGluZycsIGQucGluZywgMjAwKTsKICAgICAgICBzZXRDaXJjbGUoJ2MtZGwnLCBkLmRvd25sb2FkLCAxMDAwKTsKICAgICAgICBzZXRDaXJjbGUoJ2MtdWwnLCBkLnVwbG9hZCwgMTAwMCk7CgogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzdC1wcm9nJykuc3R5bGUud2lkdGggPSAnMTAwJSc7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXN0YXR1cycpLnRleHRDb250ZW50ID0gJ+KchSDguJfguJTguKrguK3guJrguYDguKrguKPguYfguIjguKrguLTguYnguJknOwogICAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfilrYgU1RBUlQgVEVTVCc7CiAgICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIH0gY2F0Y2goZSkgewogICAgICAgIGNsZWFySW50ZXJ2YWwocHJvZ0ludCk7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3N0LXN0YXR1cycpLnRleHRDb250ZW50ID0gJ+KdjCAnICsgZS5tZXNzYWdlOwogICAgICAgIGJ0bi50ZXh0Q29udGVudCA9ICfilrYgU1RBUlQgVEVTVCc7CiAgICAgICAgYnRuLmRpc2FibGVkID0gZmFsc2U7CiAgICAgIH0KICAgIH0KICAgIGZ1bmN0aW9uIHNldENpcmNsZShpZCwgdmFsLCBtYXgpIHsKICAgICAgY29uc3QgcGN0ID0gTWF0aC5taW4odmFsL21heCwgMSk7CiAgICAgIGNvbnN0IG9mZnNldCA9IDI4MyAtICgyODMgKiBwY3QpOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCkuc3R5bGUuc3Ryb2tlRGFzaG9mZnNldCA9IG9mZnNldDsKICAgIH0KICAgIC8vIExvYWQgSVAgb24gaW5pdAogICAgZmV0Y2goJy9hcGkvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkudGhlbihkPT57fSkuY2F0Y2goKCk9Pnt9KTsKICAgIDwvc2NyaXB0PgogIDwvZGl2Pgo8L2Rpdj48IS0tIC93cmFwIC0tPgoKPCEtLSBNT0RBTCAtLT4KPGRpdiBjbGFzcz0ibW92ZXIiIGlkPSJtb2RhbCIgb25jbGljaz0iaWYoZXZlbnQudGFyZ2V0PT09dGhpcyljbSgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIiBpZD0ibXQiPuKame+4jyB1c2VyPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9Im1jbG9zZSIgb25jbGljaz0iY20oKSI+4pyVPC9idXR0b24+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImRncmlkIj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+RpCBFbWFpbDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdSI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk6EgUG9ydDwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkcCI+LS08L3NwYW4+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImRyIj48c3BhbiBjbGFzcz0iZGsiPvCfk4Ug4Lir4Lih4LiU4Lit4Liy4Lii4Li4PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9ImRlIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TpiBEYXRhIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRkIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+TiiBUcmFmZmljIOC5g+C4iuC5iTwvc3Bhbj48c3BhbiBjbGFzcz0iZHYiIGlkPSJkdHIiPi0tPC9zcGFuPjwvZGl2PgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5OxIElQIExpbWl0PC9zcGFuPjxzcGFuIGNsYXNzPSJkdiIgaWQ9ImRpIj4tLTwvc3Bhbj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iZHIiPjxzcGFuIGNsYXNzPSJkayI+8J+GlCBVVUlEPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBtb25vIiBpZD0iZHV1Ij4tLTwvc3Bhbj48L2Rpdj4KICAgIDwvZGl2PgogICAgPGRpdiBzdHlsZT0iZm9udC1zaXplOjEycHg7Y29sb3I6dmFyKC0tbXV0ZWQpO21hcmdpbi1ib3R0b206MTBweCI+4LmA4Lil4Li34Lit4LiB4LiB4Liy4Lij4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijPC9kaXY+CiAgICA8ZGl2IGNsYXNzPSJhZ3JpZCI+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3JlbmV3JykiPjxkaXYgY2xhc3M9ImFpIj7wn5SEPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC4leC5iOC4reC4reC4suC4ouC4uDwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guKPguLXguYDguIvguJXguIjguLLguIHguKfguLHguJnguJnguLXguYk8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignZXh0ZW5kJykiPjxkaXYgY2xhc3M9ImFpIj7wn5OFPC9kaXY+PGRpdiBjbGFzcz0iYW4iPuC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQ8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbignYWRkZGF0YScpIj48ZGl2IGNsYXNzPSJhaSI+8J+TpjwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guYDguJ7guLTguYjguKEgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4LihPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4iIG9uY2xpY2s9Im1BY3Rpb24oJ3NldGRhdGEnKSI+PGRpdiBjbGFzcz0iYWkiPuKalu+4jzwvZGl2PjxkaXYgY2xhc3M9ImFuIj7guJXguLHguYnguIcgRGF0YTwvZGl2PjxkaXYgY2xhc3M9ImFkIj7guIHguLPguKvguJnguJTguYPguKvguKHguYg8L2Rpdj48L2Rpdj4KICAgICAgPGRpdiBjbGFzcz0iYWJ0biIgb25jbGljaz0ibUFjdGlvbigncmVzZXQnKSI+PGRpdiBjbGFzcz0iYWkiPvCflIM8L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lij4Li14LmA4LiL4LiVIFRyYWZmaWM8L2Rpdj48ZGl2IGNsYXNzPSJhZCI+4LmA4LiE4Lil4Li14Lii4Lij4LmM4Lii4Lit4LiU4LmD4LiK4LmJPC9kaXY+PC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImFidG4gZGFuZ2VyIiBvbmNsaWNrPSJtQWN0aW9uKCdkZWxldGUnKSI+PGRpdiBjbGFzcz0iYWkiPvCfl5HvuI88L2Rpdj48ZGl2IGNsYXNzPSJhbiI+4Lil4Lia4Lii4Li54LiqPC9kaXY+PGRpdiBjbGFzcz0iYWQiPuC4peC4muC4luC4suC4p+C4ozwvZGl2PjwvZGl2PgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4leC5iOC4reC4reC4suC4ouC4uCAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1yZW5ldyI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCDigJQg4Lij4Li14LmA4LiL4LiV4LiI4Liy4LiB4Lin4Lix4LiZ4LiZ4Li14LmJPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJk8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1yZW5ldy1kYXlzIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIzMCIgbWluPSIxIj48L2Rpdj4KICAgICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9Im0tcmVuZXctYnRuIiBvbmNsaWNrPSJkb1JlbmV3VXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLWV4dGVuZCI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OFIOC5gOC4nuC4tOC5iOC4oeC4p+C4seC4mSDigJQg4LiV4LmI4Lit4LiI4Liy4LiB4Lin4Lix4LiZ4Lir4Lih4LiUPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJnguKfguLHguJnguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKE8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1leHRlbmQtZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWV4dGVuZC1idG4iIG9uY2xpY2s9ImRvRXh0ZW5kVXNlcigpIj7inIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LmA4Lie4Li04LmI4Lih4Lin4Lix4LiZPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LmA4Lie4Li04LmI4LihIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItYWRkZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7wn5OmIOC5gOC4nuC4tOC5iOC4oSBEYXRhIOKAlCDguYDguJXguLTguKEgR0Ig4LmA4Lie4Li04LmI4Lih4LiI4Liy4LiB4LiX4Li14LmI4Lih4Li14Lit4Lii4Li54LmIPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj7guIjguLPguJnguKfguJkgR0Ig4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LmA4Lie4Li04LmI4LihPC9kaXY+PGlucHV0IGNsYXNzPSJmaSIgaWQ9Im0tYWRkZGF0YS1nYiIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMTAiIG1pbj0iMSI+PC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWFkZGRhdGEtYnRuIiBvbmNsaWNrPSJkb0FkZERhdGEoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC5gOC4nuC4tOC5iOC4oSBEYXRhPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8IS0tIFNVQi1QQU5FTDog4LiV4Lix4LmJ4LiHIERhdGEgLS0+CiAgICA8ZGl2IGNsYXNzPSJtLXN1YiIgaWQ9Im1zdWItc2V0ZGF0YSI+CiAgICAgIDxkaXYgY2xhc3M9Im1zdWItbGJsIj7impbvuI8g4LiV4Lix4LmJ4LiHIERhdGEg4oCUIOC4geC4s+C4q+C4meC4lCBMaW1pdCDguYPguKvguKHguYggKDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQpPC9kaXY+CiAgICAgIDxkaXYgY2xhc3M9ImZnIj48ZGl2IGNsYXNzPSJmbGJsIj5EYXRhIExpbWl0IChHQikg4oCUIDAgPSDguYTguKHguYjguIjguLPguIHguLHguJQ8L2Rpdj48aW5wdXQgY2xhc3M9ImZpIiBpZD0ibS1zZXRkYXRhLWdiIiB0eXBlPSJudW1iZXIiIHZhbHVlPSIwIiBtaW49IjAiPjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1zZXRkYXRhLWJ0biIgb25jbGljaz0iZG9TZXREYXRhKCkiPuKchSDguKLguLfguJnguKLguLHguJnguJXguLHguYnguIcgRGF0YTwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4o+C4teC5gOC4i+C4lSBUcmFmZmljIC0tPgogICAgPGRpdiBjbGFzcz0ibS1zdWIiIGlkPSJtc3ViLXJlc2V0Ij4KICAgICAgPGRpdiBjbGFzcz0ibXN1Yi1sYmwiPvCflIMg4Lij4Li14LmA4LiL4LiVIFRyYWZmaWMg4oCUIOC5gOC4hOC4peC4teC4ouC4o+C5jOC4ouC4reC4lOC5g+C4iuC5ieC4l+C4seC5ieC4h+C4q+C4oeC4lDwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmb250LXNpemU6MTJweDtjb2xvcjp2YXIoLS1tdXRlZCk7bWFyZ2luLWJvdHRvbToxMnB4Ij7guIHguLLguKPguKPguLXguYDguIvguJUgVHJhZmZpYyDguIjguLDguYDguITguKXguLXguKLguKPguYzguKLguK3guJQgVXBsb2FkL0Rvd25sb2FkIOC4l+C4seC5ieC4h+C4q+C4oeC4lOC4guC4reC4h+C4ouC4ueC4quC4meC4teC5iTwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJjYnRuIiBpZD0ibS1yZXNldC1idG4iIG9uY2xpY2s9ImRvUmVzZXRUcmFmZmljKCkiPuKchSDguKLguLfguJnguKLguLHguJnguKPguLXguYDguIvguJUgVHJhZmZpYzwvYnV0dG9uPgogICAgPC9kaXY+CgogICAgPCEtLSBTVUItUEFORUw6IOC4peC4muC4ouC4ueC4qiAtLT4KICAgIDxkaXYgY2xhc3M9Im0tc3ViIiBpZD0ibXN1Yi1kZWxldGUiPgogICAgICA8ZGl2IGNsYXNzPSJtc3ViLWxibCIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPvCfl5HvuI8g4Lil4Lia4Lii4Li54LiqIOKAlCDguKXguJrguJbguLLguKfguKMg4LmE4Lih4LmI4Liq4Liy4Lih4Liy4Lij4LiW4LiB4Li54LmJ4LiE4Li34LiZ4LmE4LiU4LmJPC9kaXY+CiAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOnZhcigtLW11dGVkKTttYXJnaW4tYm90dG9tOjEycHgiPuC4ouC4ueC4qiA8YiBpZD0ibS1kZWwtbmFtZSIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPjwvYj4g4LiI4Liw4LiW4Li54LiB4Lil4Lia4Lit4Lit4LiB4LiI4Liy4LiB4Lij4Liw4Lia4Lia4LiW4Liy4Lin4LijPC9kaXY+CiAgICAgIDxidXR0b24gY2xhc3M9ImNidG4iIGlkPSJtLWRlbGV0ZS1idG4iIG9uY2xpY2s9ImRvRGVsZXRlVXNlcigpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCNkYzI2MjYsI2VmNDQ0NCkiPvCfl5HvuI8g4Lii4Li34LiZ4Lii4Lix4LiZ4Lil4Lia4Lii4Li54LiqPC9idXR0b24+CiAgICA8L2Rpdj4KCiAgICA8ZGl2IGNsYXNzPSJhbGVydCIgaWQ9Im1vZGFsLWFsZXJ0IiBzdHlsZT0ibWFyZ2luLXRvcDoxMHB4Ij48L2Rpdj4KICA8L2Rpdj4KPC9kaXY+Cgo8c2NyaXB0IHNyYz0iY29uZmlnLmpzIiBvbmVycm9yPSJ3aW5kb3cuQ0hBSVlBX0NPTkZJRz17fSI+PC9zY3JpcHQ+CjxzY3JpcHQ+Ci8vIOKVkOKVkOKVkOKVkCBDT05GSUcg4pWQ4pWQ4pWQ4pWQCmNvbnN0IENGRyA9ICh0eXBlb2Ygd2luZG93LkNIQUlZQV9DT05GSUcgIT09ICd1bmRlZmluZWQnKSA/IHdpbmRvdy5DSEFJWUFfQ09ORklHIDoge307CmNvbnN0IEhPU1QgPSBDRkcuaG9zdCB8fCBsb2NhdGlvbi5ob3N0bmFtZTsKY29uc3QgWFVJICA9ICcveHVpLWFwaSc7ICAvLyDguJzguYjguLLguJkgbmdpbnggcHJveHkgKGNvb2tpZSByZXdyaXRlIOC5guC4lOC4oiBuZ2lueCkKY29uc3QgQVBJICA9ICcvYXBpJzsgICAgICAgICAgICAgICAvLyBjaGFpeWEtc3NoLWFwaSAoU1NIIHVzZXJzIOC5gOC4l+C5iOC4suC4meC4seC5ieC4mSkKY29uc3QgU0VTU0lPTl9LRVkgPSAnY2hhaXlhX2F1dGgnOwoKLy8g4pSA4pSAIERpcmVjdCB4LXVpIEFQSSBoZWxwZXJzIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgApsZXQgX3h1aUNvb2tpZSA9IGZhbHNlOyBzZXRJbnRlcnZhbCgoKT0+e194dWlDb29raWU9ZmFsc2U7fSwgMzAwMDApOwphc3luYyBmdW5jdGlvbiB4dWlFbnN1cmVMb2dpbigpIHsKICBpZiAoX3h1aUNvb2tpZSkgcmV0dXJuIHRydWU7CiAgY29uc3QgX3MgPSAoKCkgPT4geyB0cnkgeyByZXR1cm4gSlNPTi5wYXJzZShzZXNzaW9uU3RvcmFnZS5nZXRJdGVtKFNFU1NJT05fS0VZKXx8J3t9Jyk7IH0gY2F0Y2goZSl7cmV0dXJue307fSB9KSgpOwogIGNvbnN0IGZvcm0gPSBuZXcgVVJMU2VhcmNoUGFyYW1zKHsgdXNlcm5hbWU6IF9zLnVzZXJ8fENGRy54dWlfdXNlcnx8JycsIHBhc3N3b3JkOiBfcy5wYXNzfHxDRkcueHVpX3Bhc3N8fCcnIH0pOwogIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChYVUkrJy9sb2dpbicsIHsKICAgIG1ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywKICAgIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi94LXd3dy1mb3JtLXVybGVuY29kZWQnfSwKICAgIGJvZHk6IGZvcm0udG9TdHJpbmcoKQogIH0pOwogIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICBfeHVpQ29va2llID0gISFkLnN1Y2Nlc3M7CiAgcmV0dXJuIF94dWlDb29raWU7Cn0KYXN5bmMgZnVuY3Rpb24geHVpR2V0KHBhdGgpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgbGV0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge2NyZWRlbnRpYWxzOidpbmNsdWRlJ30pOwogIHRyeSB7IGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsgaWYgKGQgJiYgIWQuc3VjY2VzcyAmJiBkLm1zZyAmJiBkLm1zZy5pbmNsdWRlcygnbG9naW4nKSkgeyBfeHVpQ29va2llPWZhbHNlOyBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOyByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHtjcmVkZW50aWFsczonaW5jbHVkZSd9KTsgcmV0dXJuIGF3YWl0IHIuanNvbigpOyB9IHJldHVybiBkOyB9IGNhdGNoKGUpIHsgX3h1aUNvb2tpZT1mYWxzZTsgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7Y3JlZGVudGlhbHM6J2luY2x1ZGUnfSk7IHRyeSB7IHJldHVybiBhd2FpdCByLmpzb24oKTsgfSBjYXRjaChlMikgeyB0aHJvdyBuZXcgRXJyb3IoJ+C5gOC4o+C4teC4ouC4gSB4LXVpIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOyB9IH0KfQphc3luYyBmdW5jdGlvbiB4dWlQb3N0KHBhdGgsIGJvZHkpIHsKICBpZiAoIV94dWlDb29raWUpIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgbGV0IHIgPSBhd2FpdCBmZXRjaChYVUkrcGF0aCwge21ldGhvZDonUE9TVCcsIGNyZWRlbnRpYWxzOidpbmNsdWRlJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwgYm9keTpKU09OLnN0cmluZ2lmeShib2R5KX0pOwogIHRyeSB7IGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsgaWYgKGQgJiYgIWQuc3VjY2VzcyAmJiBkLm1zZyAmJiBkLm1zZy5pbmNsdWRlcygnbG9naW4nKSkgeyBfeHVpQ29va2llPWZhbHNlOyBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOyByID0gYXdhaXQgZmV0Y2goWFVJK3BhdGgsIHttZXRob2Q6J1BPU1QnLCBjcmVkZW50aWFsczonaW5jbHVkZScsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnkoYm9keSl9KTsgcmV0dXJuIGF3YWl0IHIuanNvbigpOyB9IHJldHVybiBkOyB9IGNhdGNoKGUpIHsgX3h1aUNvb2tpZT1mYWxzZTsgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsgciA9IGF3YWl0IGZldGNoKFhVSStwYXRoLCB7bWV0aG9kOidQT1NUJywgY3JlZGVudGlhbHM6J2luY2x1ZGUnLCBoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LCBib2R5OkpTT04uc3RyaW5naWZ5KGJvZHkpfSk7IHRyeSB7IHJldHVybiBhd2FpdCByLmpzb24oKTsgfSBjYXRjaChlMikgeyB0aHJvdyBuZXcgRXJyb3IoJ+C5gOC4o+C4teC4ouC4gSB4LXVpIOC5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOyB9IH0KfQoKLy8gU2Vzc2lvbiBjaGVjawpjb25zdCBfcyA9ICgoKSA9PiB7IHRyeSB7IHJldHVybiBKU09OLnBhcnNlKHNlc3Npb25TdG9yYWdlLmdldEl0ZW0oU0VTU0lPTl9LRVkpfHwne30nKTsgfSBjYXRjaChlKXtyZXR1cm57fTt9IH0pKCk7CmlmICghX3MudXNlciB8fCAhX3MucGFzcyB8fCBEYXRlLm5vdygpID49IChfcy5leHB8fDApKSB7CiAgc2Vzc2lvblN0b3JhZ2UucmVtb3ZlSXRlbShTRVNTSU9OX0tFWSk7CiAgbG9jYXRpb24ucmVwbGFjZSgnaW5kZXguaHRtbCcpOwp9CgovLyBIZWFkZXIgZG9tYWluCmRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdoZHItZG9tYWluJykudGV4dENvbnRlbnQgPSAnJzsKCi8vIOKVkOKVkOKVkOKVkCBVVElMUyDilZDilZDilZDilZAKZnVuY3Rpb24gZm10Qnl0ZXMoYikgewogIGlmICghYiB8fCBiID09PSAwKSByZXR1cm4gJzAgQic7CiAgY29uc3QgayA9IDEwMjQsIHUgPSBbJ0InLCdLQicsJ01CJywnR0InLCdUQiddOwogIGNvbnN0IGkgPSBNYXRoLmZsb29yKE1hdGgubG9nKGIpL01hdGgubG9nKGspKTsKICByZXR1cm4gKGIvTWF0aC5wb3coayxpKSkudG9GaXhlZCgxKSsnICcrdVtpXTsKfQpmdW5jdGlvbiBmbXREYXRlKG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogIGNvbnN0IGQgPSBuZXcgRGF0ZShtcyk7CiAgcmV0dXJuIGQudG9Mb2NhbGVEYXRlU3RyaW5nKCd0aC1USCcse3llYXI6J251bWVyaWMnLG1vbnRoOidzaG9ydCcsZGF5OidudW1lcmljJ30pOwp9CmZ1bmN0aW9uIGRheXNMZWZ0KG1zKSB7CiAgaWYgKCFtcyB8fCBtcyA9PT0gMCkgcmV0dXJuIG51bGw7CiAgcmV0dXJuIE1hdGguY2VpbCgobXMgLSBEYXRlLm5vdygpKSAvIDg2NDAwMDAwKTsKfQpmdW5jdGlvbiBzZXRSaW5nKGlkLCBwY3QpIHsKICBjb25zdCBjaXJjID0gMTM4LjI7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKGVsKSBlbC5zdHlsZS5zdHJva2VEYXNob2Zmc2V0ID0gY2lyYyAtIChjaXJjICogTWF0aC5taW4ocGN0LDEwMCkgLyAxMDApOwp9CmZ1bmN0aW9uIHNldEJhcihpZCwgcGN0LCB3YXJuPWZhbHNlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLnN0eWxlLndpZHRoID0gTWF0aC5taW4ocGN0LDEwMCkgKyAnJSc7CiAgaWYgKHdhcm4gJiYgcGN0ID4gODUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNlZjQ0NDQsI2RjMjYyNiknOwogIGVsc2UgaWYgKHdhcm4gJiYgcGN0ID4gNjUpIGVsLnN0eWxlLmJhY2tncm91bmQgPSAnbGluZWFyLWdyYWRpZW50KDkwZGVnLCNmOTczMTYsI2ZiOTIzYyknOwp9CmZ1bmN0aW9uIHNob3dBbGVydChpZCwgbXNnLCB0eXBlKSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChpZCk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLmNsYXNzTmFtZSA9ICdhbGVydCAnK3R5cGU7CiAgZWwudGV4dENvbnRlbnQgPSBtc2c7CiAgZWwuc3R5bGUuZGlzcGxheSA9ICdibG9jayc7CiAgaWYgKHR5cGUgPT09ICdvaycpIHNldFRpbWVvdXQoKCk9PntlbC5zdHlsZS5kaXNwbGF5PSdub25lJzt9LCAzMDAwKTsKfQoKLy8g4pWQ4pWQ4pWQ4pWQIE5BViDilZDilZDilZDilZAKZnVuY3Rpb24gc3cobmFtZSwgZWwpIHsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcuc2VjJykuZm9yRWFjaChzPT5zLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCcubmF2LWl0ZW0nKS5mb3JFYWNoKG49Pm4uY2xhc3NMaXN0LnJlbW92ZSgnYWN0aXZlJykpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd0YWItJytuYW1lKS5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBlbC5jbGFzc0xpc3QuYWRkKCdhY3RpdmUnKTsKICBpZiAobmFtZT09PSdjcmVhdGUnKSBjbG9zZUZvcm0oKTsKICBpZiAobmFtZT09PSdkYXNoYm9hcmQnKSBsb2FkRGFzaCgpOwogIGlmIChuYW1lPT09J21hbmFnZScpIGxvYWRVc2VycygpOwogIGlmIChuYW1lPT09J29ubGluZScpIGxvYWRPbmxpbmUoKTsKICBpZiAobmFtZT09PSdiYW4nKSB7IGxvYWRCYW5uZWQoKTsgfQogIGlmIChuYW1lPT09J3NwZWVkJykgeyBzZXRHYXVnZSgwKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBsb2FkQmFubmVkKCkgewogIGNvbnN0IGVsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbm5lZC1saXN0Jyk7CiAgaWYgKCFlbCkgcmV0dXJuOwogIGVsLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIj7guIHguLPguKXguLHguIfguYLguKvguKXguJQuLi48L2Rpdj4nOwogIHRyeSB7CiAgICBjb25zdCBkID0gYXdhaXQgZmV0Y2goQVBJKycvYmFubmVkJykudGhlbihyPT5yLmpzb24oKSk7CiAgICBjb25zdCBsaXN0ID0gZC5iYW5uZWQgfHwgW107CiAgICBpZiAoIWxpc3QubGVuZ3RoKSB7IGVsLmlubmVySFRNTCA9ICc8ZGl2IHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtwYWRkaW5nOjIwcHg7Y29sb3I6IzIyYzU1ZSI+4pyFIOC5hOC4oeC5iOC4oeC4teC4o+C4suC4ouC4geC4suC4o+C4l+C4teC5iOC4luC4ueC4geC5geC4muC4mTwvZGl2Pic7IHJldHVybjsgfQogICAgZWwuaW5uZXJIVE1MID0gbGlzdC5tYXAoYiA9PiB7CiAgICAgIGNvbnN0IHJlbWFpbiA9IGIucmVtYWluIHx8IDA7CiAgICAgIGNvbnN0IHBjdCA9IE1hdGgubWluKDEwMCwgTWF0aC5yb3VuZCgoMzYwMC1yZW1haW4pLzM2MDAqMTAwKSk7CiAgICAgIHJldHVybiBgPGRpdiBzdHlsZT0iYmFja2dyb3VuZDojZmZmN2VkO2JvcmRlcjoxcHggc29saWQgI2ZlZDdhYTtib3JkZXItcmFkaXVzOjEycHg7cGFkZGluZzoxMnB4IDE0cHg7bWFyZ2luLWJvdHRvbTo4cHgiPgogICAgICAgIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtqdXN0aWZ5LWNvbnRlbnQ6c3BhY2UtYmV0d2VlbjthbGlnbi1pdGVtczpjZW50ZXIiPgogICAgICAgICAgPGRpdj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iZm9udC13ZWlnaHQ6NzAwO2NvbG9yOiM5MjQwMGUiPiR7Yi5lbWFpbHx8Yi51c2VyfHxiLnVzZXJuYW1lfHwndW5rbm93bid9PC9kaXY+CiAgICAgICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiNiNDUzMDkiPlBvcnQgJHtiLnBvcnR8fCctJ30gwrcg4LmA4LiB4Li04LiZIElQIExpbWl0PC9kaXY+CiAgICAgICAgICAgIDxkaXYgc3R5bGU9ImZvbnQtc2l6ZToxMnB4O2NvbG9yOiM4ODg7bWFyZ2luLXRvcDo0cHgiPuC4q+C4oeC4lOC5geC4muC4meC5g+C4mTogPHNwYW4gc3R5bGU9ImNvbG9yOiNmNTllMGI7Zm9udC13ZWlnaHQ6NzAwIj4ke01hdGguY2VpbChyZW1haW4vNjApfSDguJnguLLguJfguLU8L3NwYW4+PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxidXR0b24gb25jbGljaz0idW5iYW5EaXJlY3QoJyR7Yi5lbWFpbHx8Yi51c2VyfHxiLnVzZXJuYW1lfScpIiBzdHlsZT0iYmFja2dyb3VuZDpsaW5lYXItZ3JhZGllbnQoMTM1ZGVnLCM5MjQwMGUsI2Y1OWUwYik7Y29sb3I6I2ZmZjtib3JkZXI6bm9uZTtib3JkZXItcmFkaXVzOjhweDtwYWRkaW5nOjhweCAxNHB4O2ZvbnQtc2l6ZToxM3B4O2N1cnNvcjpwb2ludGVyIj7wn5STIOC4m+C4peC4lDwvYnV0dG9uPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDo0cHg7YmFja2dyb3VuZDojZmVlO2JvcmRlci1yYWRpdXM6OTlweDttYXJnaW4tdG9wOjhweDtvdmVyZmxvdzpoaWRkZW4iPgogICAgICAgICAgPGRpdiBzdHlsZT0iaGVpZ2h0OjEwMCU7d2lkdGg6JHtwY3R9JTtiYWNrZ3JvdW5kOiNmNTllMGI7Ym9yZGVyLXJhZGl1czo5OXB4Ij48L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+YDsKICAgIH0pLmpvaW4oJycpOwogIH0gY2F0Y2goZSkgeyBlbC5pbm5lckhUTUwgPSAnPGRpdiBzdHlsZT0iY29sb3I6cmVkIj4nK2UubWVzc2FnZSsnPC9kaXY+JzsgfQp9CmFzeW5jIGZ1bmN0aW9uIHVuYmFuRGlyZWN0KHVzZXJuYW1lKSB7CiAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VuYmFuJywge21ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJuYW1lfSl9KS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+KHtvazpmYWxzZX0pKTsKICBsb2FkQmFubmVkKCk7Cn0KYXN5bmMgZnVuY3Rpb24gdW5iYW5Vc2VyKCkgewogIGNvbnN0IHVzZXJuYW1lID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgpOwogIGNvbnN0IGFsID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi1hbGVydCcpOwogIGlmICghdXNlcm5hbWUpIHsgYWwudGV4dENvbnRlbnQ9J+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSB1c2VybmFtZSc7IGFsLmNsYXNzTmFtZT0nYWxlcnQgZXJyJzsgcmV0dXJuOyB9CiAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL3VuYmFuJywge21ldGhvZDonUE9TVCcsIGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sIGJvZHk6SlNPTi5zdHJpbmdpZnkoe3VzZXJuYW1lfSl9KS50aGVuKHI9PnIuanNvbigpKS5jYXRjaCgoKT0+KHtvazpmYWxzZX0pKTsKICBhbC50ZXh0Q29udGVudCA9IGQub2sgPyAn4pyFIOC4m+C4peC4lOC4peC5h+C4reC4hOC4quC4s+C5gOC4o+C5h+C4iCcgOiAn4p2MICcrKGQuZXJyb3J8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICBhbC5jbGFzc05hbWUgPSAnYWxlcnQgJysoZC5vaz8nb2snOidlcnInKTsKICBpZiAoZC5vaykgbG9hZEJhbm5lZCgpOwp9Cgphc3luYyBmdW5jdGlvbiBkZWJ1Z0JhbigpIHsKICBjb25zdCBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tZGVidWcnKTsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2Jhbm5lZCcpOwogICAgY29uc3QgdGV4dCA9IGF3YWl0IHIudGV4dCgpOwogICAgZWwudGV4dENvbnRlbnQgPSAnU3RhdHVzOicrci5zdGF0dXMrJyBCb2R5OicrdGV4dDsKICB9IGNhdGNoKGUpIHsKICAgIGVsLnRleHRDb250ZW50ID0gJ0Vycm9yOiAnK2UubWVzc2FnZTsKICB9Cn0KCi8vIOKUgOKUgCBGb3JtIG5hdiDilIDilIAKbGV0IF9jdXJGb3JtID0gbnVsbDsKZnVuY3Rpb24gb3BlbkZvcm0oaWQpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3JlYXRlLW1lbnUnKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIFsnYWlzJywndHJ1ZScsJ3NzaCddLmZvckVhY2goZiA9PiB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZm9ybS0nK2YpLnN0eWxlLmRpc3BsYXkgPSBmPT09aWQgPyAnYmxvY2snIDogJ25vbmUnOwogIH0pOwogIF9jdXJGb3JtID0gaWQ7CiAgaWYgKGlkPT09J3NzaCcpIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIHdpbmRvdy5zY3JvbGxUbygwLDApOwp9CmZ1bmN0aW9uIGNsb3NlRm9ybSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnY3JlYXRlLW1lbnUnKS5zdHlsZS5kaXNwbGF5ID0gJ2Jsb2NrJzsKICBbJ2FpcycsJ3RydWUnLCdzc2gnXS5mb3JFYWNoKGYgPT4gewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Zvcm0tJytmKS5zdHlsZS5kaXNwbGF5ID0gJ25vbmUnOwogIH0pOwogIF9jdXJGb3JtID0gbnVsbDsKfQoKbGV0IF93c1BvcnQgPSAnODAnOwpmdW5jdGlvbiB0b2dQb3J0KGJ0biwgcG9ydCkgewogIF93c1BvcnQgPSBwb3J0OwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd3czgwLWJ0bicpLmNsYXNzTGlzdC50b2dnbGUoJ2FjdGl2ZScsIHBvcnQ9PT0nODAnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnd3M0NDMtYnRuJykuY2xhc3NMaXN0LnRvZ2dsZSgnYWN0aXZlJywgcG9ydD09PSc0NDMnKTsKfQpmdW5jdGlvbiB0b2dHcm91cChidG4sIGNscykgewogIGJ0bi5jbG9zZXN0KCdkaXYnKS5xdWVyeVNlbGVjdG9yQWxsKGNscykuZm9yRWFjaChiPT5iLmNsYXNzTGlzdC5yZW1vdmUoJ2FjdGl2ZScpKTsKICBidG4uY2xhc3NMaXN0LmFkZCgnYWN0aXZlJyk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBYVUkgTE9HSU4gKGNvb2tpZSkg4pWQ4pWQ4pWQ4pWQCi8vIFtkdXBsaWNhdGUgcmVtb3ZlZF0KCi8vIOKVkOKVkOKVkOKVkCBEQVNIQk9BUkQg4pWQ4pWQ4pWQ4pWQCmFzeW5jIGZ1bmN0aW9uIGxvYWREYXNoKCkgewogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tcmVmcmVzaCcpOwogIGlmIChidG4pIGJ0bi50ZXh0Q29udGVudCA9ICfihrsgLi4uJzsKICBfeHVpQ29va2llID0gZmFsc2U7IC8vIGZvcmNlIHJlLWxvZ2luIOC5gOC4quC4oeC4rQoKICB0cnkgewogICAgLy8gU1NIIEFQSSBzdGF0dXMKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSkuY2F0Y2goKCk9Pm51bGwpOwogICAgaWYgKHN0KSB7CiAgICAgIHJlbmRlclNlcnZpY2VzKHN0LnNlcnZpY2VzIHx8IHt9KTsKICAgIH0KCiAgICAvLyBYVUkgc2VydmVyIHN0YXR1cwogICAgY29uc3Qgb2sgPSBhd2FpdCB4dWlFbnN1cmVMb2dpbigpOwogICAgaWYgKCFvaykgewogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9ImRvdCByZWQiPjwvc3Bhbj5Mb2dpbiDguYTguKHguYjguYTguJTguYknOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgneHVpLXBpbGwnKS5jbGFzc05hbWUgPSAnb3BpbGwgb2ZmJzsKICAgICAgcmV0dXJuOwogICAgfQogICAgY29uc3Qgc3YgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvc2VydmVyL3N0YXR1cycpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChzdiAmJiBzdi5zdWNjZXNzICYmIHN2Lm9iaikgewogICAgICBjb25zdCBvID0gc3Yub2JqOwogICAgICAvLyBDUFUKICAgICAgY29uc3QgY3B1ID0gTWF0aC5yb3VuZChvLmNwdSB8fCAwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1wY3QnKS50ZXh0Q29udGVudCA9IGNwdSArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NwdS1jb3JlcycpLnRleHRDb250ZW50ID0gKG8uY3B1Q29yZXMgfHwgby5sb2dpY2FsUHJvIHx8ICctLScpICsgJyBjb3Jlcyc7CiAgICAgIHNldFJpbmcoJ2NwdS1yaW5nJywgY3B1KTsgc2V0QmFyKCdjcHUtYmFyJywgY3B1LCB0cnVlKTsKCiAgICAgIC8vIFJBTQogICAgICBjb25zdCByYW1UID0gKChvLm1lbT8udG90YWx8fDApLzEwNzM3NDE4MjQpLCByYW1VID0gKChvLm1lbT8uY3VycmVudHx8MCkvMTA3Mzc0MTgyNCk7CiAgICAgIGNvbnN0IHJhbVAgPSByYW1UID4gMCA/IE1hdGgucm91bmQocmFtVS9yYW1UKjEwMCkgOiAwOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncmFtLXBjdCcpLnRleHRDb250ZW50ID0gcmFtUCArICclJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3JhbS1kZXRhaWwnKS50ZXh0Q29udGVudCA9IHJhbVUudG9GaXhlZCgxKSsnIC8gJytyYW1ULnRvRml4ZWQoMSkrJyBHQic7CiAgICAgIHNldFJpbmcoJ3JhbS1yaW5nJywgcmFtUCk7IHNldEJhcigncmFtLWJhcicsIHJhbVAsIHRydWUpOwoKICAgICAgLy8gRGlzawogICAgICBjb25zdCBkc2tUID0gKChvLmRpc2s/LnRvdGFsfHwwKS8xMDczNzQxODI0KSwgZHNrVSA9ICgoby5kaXNrPy5jdXJyZW50fHwwKS8xMDczNzQxODI0KTsKICAgICAgY29uc3QgZHNrUCA9IGRza1QgPiAwID8gTWF0aC5yb3VuZChkc2tVL2Rza1QqMTAwKSA6IDA7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaXNrLXBjdCcpLmlubmVySFRNTCA9IGRza1AgKyAnPHNwYW4+JTwvc3Bhbj4nOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGlzay1kZXRhaWwnKS50ZXh0Q29udGVudCA9IGRza1UudG9GaXhlZCgwKSsnIC8gJytkc2tULnRvRml4ZWQoMCkrJyBHQic7CiAgICAgIHNldEJhcignZGlzay1iYXInLCBkc2tQLCB0cnVlKTsKCiAgICAgIC8vIFVwdGltZQogICAgICBjb25zdCB1cCA9IG8udXB0aW1lIHx8IDA7CiAgICAgIGNvbnN0IHVkID0gTWF0aC5mbG9vcih1cC84NjQwMCksIHVoID0gTWF0aC5mbG9vcigodXAlODY0MDApLzM2MDApLCB1bSA9IE1hdGguZmxvb3IoKHVwJTM2MDApLzYwKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VwdGltZS12YWwnKS50ZXh0Q29udGVudCA9IHVkID4gMCA/IHVkKydkICcrdWgrJ2gnIDogdWgrJ2ggJyt1bSsnbSc7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1cHRpbWUtc3ViJykudGV4dENvbnRlbnQgPSB1ZCsn4Lin4Lix4LiZICcrdWgrJ+C4iuC4oS4gJyt1bSsn4LiZ4Liy4LiX4Li1JzsKICAgICAgY29uc3QgbG9hZHMgPSBvLmxvYWRzIHx8IFtdOwogICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbG9hZC1jaGlwcycpLmlubmVySFRNTCA9IGxvYWRzLm1hcCgobCxpKT0+CiAgICAgICAgYDxzcGFuIGNsYXNzPSJiZGciPiR7WycxbScsJzVtJywnMTVtJ11baV19OiAke2wudG9GaXhlZCgyKX08L3NwYW4+YCkuam9pbignJyk7CgogICAgICAvLyBOZXR3b3JrCiAgICAgIGlmIChvLm5ldElPKSB7CiAgICAgICAgY29uc3QgdXBfYiA9IG8ubmV0SU8udXB8fDAsIGRuX2IgPSBvLm5ldElPLmRvd258fDA7CiAgICAgICAgY29uc3QgdXBGbXQgPSBmbXRCeXRlcyh1cF9iKSwgZG5GbXQgPSBmbXRCeXRlcyhkbl9iKTsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwJykuaW5uZXJIVE1MID0gdXBGbXQucmVwbGFjZSgnICcsJzxzcGFuPiAnKSsnPC9zcGFuPic7CiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ25ldC1kbicpLmlubmVySFRNTCA9IGRuRm10LnJlcGxhY2UoJyAnLCc8c3Bhbj4gJykrJzwvc3Bhbj4nOwogICAgICB9CiAgICAgIGlmIChvLm5ldFRyYWZmaWMpIHsKICAgICAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbmV0LXVwLXRvdGFsJykudGV4dENvbnRlbnQgPSAndG90YWw6ICcrZm10Qnl0ZXMoby5uZXRUcmFmZmljLnNlbnR8fDApOwogICAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCduZXQtZG4tdG90YWwnKS50ZXh0Q29udGVudCA9ICd0b3RhbDogJytmbXRCeXRlcyhvLm5ldFRyYWZmaWMucmVjdnx8MCk7CiAgICAgIH0KCiAgICAgIC8vIFhVSSB2ZXJzaW9uCiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktdmVyJykudGV4dENvbnRlbnQgPSAoby54cmF5ICYmIG8ueHJheS52ZXJzaW9uKSA/IG8ueHJheS52ZXJzaW9uIDogKG8ueHJheVZlcnNpb24gfHwgJy0tJyk7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktcGlsbCcpLmlubmVySFRNTCA9ICc8c3BhbiBjbGFzcz0iZG90Ij48L3NwYW4+4Lit4Lit4LiZ4LmE4Lil4LiZ4LmMJzsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3h1aS1waWxsJykuY2xhc3NOYW1lID0gJ29waWxsJzsKICAgIH0KCiAgICAvLyBJbmJvdW5kcyBjb3VudAogICAgY29uc3QgaWJsID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKS5jYXRjaCgoKT0+bnVsbCk7CiAgICBpZiAoaWJsICYmIGlibC5zdWNjZXNzKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd4dWktaW5ib3VuZHMnKS50ZXh0Q29udGVudCA9IChpYmwub2JqfHxbXSkubGVuZ3RoOwogICAgfQoKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdsYXN0LXVwZGF0ZScpLnRleHRDb250ZW50ID0gJ+C4reC4seC4nuC5gOC4lOC4l+C4peC5iOC4suC4quC4uOC4lDogJyArIG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogIH0gY2F0Y2goZSkgewogICAgY29uc29sZS5lcnJvcihlKTsKICB9IGZpbmFsbHkgewogICAgaWYgKGJ0bikgYnRuLnRleHRDb250ZW50ID0gJ+KGuyDguKPguLXguYDguJ/guKPguIonOwogIH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIFNFUlZJQ0VTIOKVkOKVkOKVkOKVkApjb25zdCBTVkNfREVGID0gWwogIHsga2V5Oid4dWknLCAgICAgIGljb246J/Cfk6EnLCBuYW1lOid4LXVpIFBhbmVsJywgICAgICBwb3J0Oic6MjA1MycgfSwKICB7IGtleTonc3NoJywgICAgICBpY29uOifwn5CNJywgbmFtZTonU1NIIEFQSScsICAgICAgICAgIHBvcnQ6Jzo2Nzg5JyB9LAogIHsga2V5Oidkcm9wYmVhcicsIGljb246J/CfkLsnLCBuYW1lOidEcm9wYmVhciBTU0gnLCAgICAgcG9ydDonOjE0MyA6MTA5JyB9LAogIHsga2V5OidoYXByb3h5JywgIGljb246J/Cfm6HvuI8nLCBuYW1lOidIQVByb3h5JywgICAgICAgICAgcG9ydDonOjgwIDo0NDMnIH0sCiAgeyBrZXk6J25naW54JywgICAgaWNvbjon8J+MkCcsIG5hbWU6J05naW54IEw3JywgICAgICAgICBwb3J0Oic6ODg4MCcgfSwKICB7IGtleTonc3Nod3MnLCAgICBpY29uOifwn5SSJywgbmFtZTonbnB4cHJveHkgKFNTSC1XUyknLCBwb3J0Oic6ODA4MOKGkjoxNDMnIH0sCiAgeyBrZXk6J2JhZHZwbicsICAgaWNvbjon8J+OricsIG5hbWU6J0JhZFZQTiBVRFBHVycsICAgICBwb3J0Oic6NzMwMCcgfSwKICB7IGtleToneml2cG4nLCAgICBpY29uOifwn4yAJywgbmFtZTonWmlWUE4gKFVEUCknLCAgICAgIHBvcnQ6Jzo1NjY3JyB9LApdOwpmdW5jdGlvbiByZW5kZXJTZXJ2aWNlcyhtYXApIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSBTVkNfREVGLm1hcChzID0+IHsKICAgIGNvbnN0IHVwID0gbWFwW3Mua2V5XSA9PT0gdHJ1ZSB8fCBtYXBbcy5rZXldID09PSAnYWN0aXZlJzsKICAgIHJldHVybiBgPGRpdiBjbGFzcz0ic3ZjICR7dXA/Jyc6J2Rvd24nfSI+CiAgICAgIDxkaXYgY2xhc3M9InN2Yy1sIj48c3BhbiBjbGFzcz0iZGcgJHt1cD8nJzoncmVkJ30iPjwvc3Bhbj48c3Bhbj4ke3MuaWNvbn08L3NwYW4+CiAgICAgICAgPGRpdj48ZGl2IGNsYXNzPSJzdmMtbiI+JHtzLm5hbWV9PC9kaXY+PGRpdiBjbGFzcz0ic3ZjLXAiPiR7cy5wb3J0fTwvZGl2PjwvZGl2PgogICAgICA8L2Rpdj4KICAgICAgPHNwYW4gY2xhc3M9InJiZGcgJHt1cD8nJzonZG93bid9Ij4ke3VwPydSVU5OSU5HJzonRE9XTid9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQphc3luYyBmdW5jdGlvbiBsb2FkU2VydmljZXMoKSB7CiAgdHJ5IHsKICAgIGNvbnN0IHN0ID0gYXdhaXQgZmV0Y2goQVBJKycvc3RhdHVzJykudGhlbihyPT5yLmpzb24oKSk7CiAgICByZW5kZXJTZXJ2aWNlcyhzdC5zZXJ2aWNlcyB8fCB7fSk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3ZjLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyIgc3R5bGU9ImNvbG9yOiNlZjQ0NDQiPuC5gOC4iuC4t+C5iOC4reC4oeC4leC5iOC4rSBBUEkg4LmE4Lih4LmI4LmE4LiU4LmJPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggUElDS0VSIFNUQVRFIOKVkOKVkOKVkOKVkApjb25zdCBQUk9TID0gewogIGR0YWM6IHsKICAgIG5hbWU6ICdEVEFDIEdBTUlORycsCiAgICBwcm94eTogJzEwNC4xOC42My4xMjQ6ODAnLAogICAgcGF5bG9hZDogJ1BPU1QgLyBIVFRQLzEuMVtjcmxmXUhvc3Q6ZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbVtjcmxmXVgtT25saW5lLUhvc3Q6ZGwuZGlyLmZyZWVmaXJlbW9iaWxlLmNvbVtjcmxmXVgtRm9yd2FyZC1Ib3N0OmRsLmRpci5mcmVlZmlyZW1vYmlsZS5jb21bY3JsZl1Vc2VyLUFnZW50OiBbdWFdW2NybGZdQ29ubmVjdGlvbjoga2VlcC1hbGl2ZVtjcmxmXVtjcmxmXVtzcGxpdF1bY3JdUEFUQ0ggLyBIVFRQLzEuMVtjcmxmXUhvc3Q6IFtob3N0XVtjcmxmXVVwZ3JhZGU6IHdlYnNvY2tldFtjcmxmXUNvbm5lY3Rpb246IFVwZ3JhZGVbY3JsZl1YLU9ubGluZS1Ib3N0OiBbaG9zdF1bY3JsZl1bY3JsZl0nLAogICAgZGFya1Byb3h5OiAndHJ1ZXZpcGFubGluZS5nb2R2cG4uc2hvcCcsIGRhcmtQcm94eVBvcnQ6IDgwCiAgfSwKICB0cnVlOiB7CiAgICBuYW1lOiAnVFJVRSBUV0lUVEVSJywKICAgIHByb3h5OiAnMTA0LjE4LjM5LjI0OjgwJywKICAgIHBheWxvYWQ6ICdQT1NUIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OmhlbHAueC5jb21bY3JsZl1YLU9ubGluZS1Ib3N0OmhlbHAueC5jb21bY3JsZl1YLUZvcndhcmQtSG9zdDpoZWxwLnguY29tW2NybGZdVXNlci1BZ2VudDogW3VhXVtjcmxmXUNvbm5lY3Rpb246IGtlZXAtYWxpdmVbY3JsZl1bY3JsZl1bc3BsaXRdW2NyXVBBVENIIC8gSFRUUC8xLjFbY3JsZl1Ib3N0OiBbaG9zdF1bY3JsZl1VcGdyYWRlOiB3ZWJzb2NrZXRbY3JsZl1Db25uZWN0aW9uOiBVcGdyYWRlW2NybGZdWC1PbmxpbmUtSG9zdDogW2hvc3RdW2NybGZdW2NybGZdJywKICAgIGRhcmtQcm94eTogJ3RydWV2aXBhbmxpbmUuZ29kdnBuLnNob3AnLCBkYXJrUHJveHlQb3J0OiA4MAogIH0KfTsKY29uc3QgTlBWX0hPU1QgPSBIT1NULCBOUFZfUE9SVCA9IDgwOwpsZXQgX3NzaFBybyA9ICdkdGFjJywgX3NzaEFwcCA9ICducHYnLCBfc3NoUG9ydCA9ICc4MCc7CgpmdW5jdGlvbiBwaWNrUG9ydChwKSB7CiAgX3NzaFBvcnQgPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi04MCcpLmNsYXNzTmFtZSAgPSAncG9ydC1idG4nICsgKHA9PT0nODAnICA/ICcgYWN0aXZlLXA4MCcgIDogJycpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwYi00NDMnKS5jbGFzc05hbWUgPSAncG9ydC1idG4nICsgKHA9PT0nNDQzJyA/ICcgYWN0aXZlLXA0NDMnIDogJycpOwp9CmZ1bmN0aW9uIHBpY2tQcm8ocCkgewogIF9zc2hQcm8gPSBwOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdwcm8tZHRhYycpLmNsYXNzTmFtZSA9ICdwaWNrLW9wdCcgKyAocD09PSdkdGFjJyA/ICcgYS1kdGFjJyA6ICcnKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgncHJvLXRydWUnKS5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKHA9PT0ndHJ1ZScgPyAnIGEtdHJ1ZScgOiAnJyk7Cn0KZnVuY3Rpb24gcGlja0FwcChhKSB7CiAgX3NzaEFwcCA9IGE7CiAgWyducHYnLCdkYXJrJ10uZm9yRWFjaChmdW5jdGlvbihrKXsKICAgIHZhciBlbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdhcHAtJytrKTsKICAgIGlmKGVsKSBlbC5jbGFzc05hbWUgPSAncGljay1vcHQnICsgKGE9PT1rID8gJyBhLScrayA6ICcnKTsKICB9KTsKfQoKCgpmdW5jdGlvbiBidWlsZE5wdkxpbmsobmFtZSwgcGFzcywgcHJvKSB7CiAgY29uc3QgaiA9IHsKICAgIHNzaENvbmZpZ1R5cGU6J1NTSC1Qcm94eS1QYXlsb2FkJywgcmVtYXJrczpwcm8ubmFtZSsnLScrbmFtZSwKICAgIHNzaEhvc3Q6TlBWX0hPU1QsIHNzaFBvcnQ6TlBWX1BPUlQsCiAgICBzc2hVc2VybmFtZTpuYW1lLCBzc2hQYXNzd29yZDpwYXNzLAogICAgc25pOicnLCB0bHNWZXJzaW9uOidERUZBVUxUJywKICAgIGh0dHBQcm94eTpwcm8ucHJveHksIGF1dGhlbnRpY2F0ZVByb3h5OmZhbHNlLAogICAgcHJveHlVc2VybmFtZTonJywgcHJveHlQYXNzd29yZDonJywKICAgIHBheWxvYWQ6cHJvLnBheWxvYWQsCiAgICBkbnNNb2RlOidVRFAnLCBkbnNTZXJ2ZXI6JycsIG5hbWVzZXJ2ZXI6JycsIHB1YmxpY0tleTonJywKICAgIHVkcGd3UG9ydDo3MzAwLCB1ZHBnd1RyYW5zcGFyZW50RE5TOnRydWUKICB9OwogIHJldHVybiAnbnB2dC1zc2g6Ly8nICsgYnRvYSh1bmVzY2FwZShlbmNvZGVVUklDb21wb25lbnQoSlNPTi5zdHJpbmdpZnkoaikpKSk7Cn0KZnVuY3Rpb24gYnVpbGREYXJrTGluayhuYW1lLCBwYXNzLCBwcm8pIHsKICBjb25zdCBqID0gewogICAgdHlwZTogIlNTSCIsCiAgICBuYW1lOiBwcm8ubmFtZSArICctJyArIG5hbWUsCiAgICBzc2hUdW5uZWxDb25maWc6IHsKICAgICAgc3NoQ29uZmlnOiB7CiAgICAgICAgaG9zdDogSE9TVCwKICAgICAgICBwb3J0OiBwYXJzZUludChfc3NoUG9ydCkgfHwgODAsCiAgICAgICAgdXNlcm5hbWU6IG5hbWUsCiAgICAgICAgcGFzc3dvcmQ6IHBhc3MKICAgICAgfSwKICAgICAgaW5qZWN0Q29uZmlnOiB7CiAgICAgICAgbW9kZTogIlBST1hZIiwKICAgICAgICBwcm94eUhvc3Q6IChwcm8ucHJveHl8fCcnKS5zcGxpdCgnOicpWzBdLAogICAgICAgIHByb3h5UG9ydDogODAsCiAgICAgICAgcGF5bG9hZDogcHJvLnBheWxvYWQKICAgICAgfQogICAgfQogIH07CiAgcmV0dXJuICdkYXJrdHVubmVsOi8vJyArIGJ0b2EodW5lc2NhcGUoZW5jb2RlVVJJQ29tcG9uZW50KEpTT04uc3RyaW5naWZ5KGopKSkpOwp9CgovLyDilZDilZDilZDilZAgQ1JFQVRFIFNTSCDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gY3JlYXRlU1NIKCkgewogIGNvbnN0IHVzZXIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXInKS52YWx1ZS50cmltKCk7CiAgY29uc3QgcGFzcyA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcGFzcycpLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1kYXlzJykudmFsdWUpfHwzMDsKICBjb25zdCBpcGwgID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpID8gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1pcCcpLnZhbHVlIDogMil8fDI7CiAgaWYgKCF1c2VyKSByZXR1cm4gc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCfguIHguKPguLjguJPguLLguYPguKrguYggVXNlcm5hbWUnLCdlcnInKTsKICBpZiAoIXBhc3MpIHJldHVybiBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBQYXNzd29yZCcsJ2VycicpOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsKICBidG4uaW5uZXJIVE1MID0gJzxzcGFuIGNsYXNzPSJzcGluIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMzQsMTk3LDk0LC4zKTtib3JkZXItdG9wLWNvbG9yOiMyMmM1NWUiPjwvc3Bhbj7guIHguLPguKXguLHguIfguKrguKPguYnguLLguIcuLi4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBjb25zdCByZXNFbCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtbGluay1yZXN1bHQnKTsKICBpZiAocmVzRWwpIHJlc0VsLmNsYXNzTmFtZT0nbGluay1yZXN1bHQnOwogIHRyeSB7CiAgICBjb25zdCByID0gYXdhaXQgZmV0Y2goQVBJKycvY3JlYXRlX3NzaCcsIHsKICAgICAgbWV0aG9kOidQT1NUJywgaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTogSlNPTi5zdHJpbmdpZnkoe3VzZXIsIHBhc3N3b3JkOnBhc3MsIGRheXMsIGlwX2xpbWl0OmlwbH0pCiAgICB9KTsKICAgIGNvbnN0IGQgPSBhd2FpdCByLmpzb24oKTsKICAgIGlmICghZC5vaykgdGhyb3cgbmV3IEVycm9yKGQuZXJyb3IgfHwgJ+C4quC4o+C5ieC4suC4h+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwoKICAgIGNvbnN0IHBybyAgPSBQUk9TW19zc2hQcm9dIHx8IFBST1MuZHRhYzsKICAgIGNvbnN0IGxpbmsgPSBfc3NoQXBwPT09J25wdicgPyBidWlsZE5wdkxpbmsodXNlcixwYXNzLHBybykgOiBidWlsZERhcmtMaW5rKHVzZXIscGFzcyxwcm8pOwogICAgY29uc3QgaXNOcHYgPSBfc3NoQXBwPT09J25wdic7CiAgICBjb25zdCBscENscyA9IGlzTnB2ID8gJycgOiAnIGRhcmstbHAnOwogICAgY29uc3QgY0NscyAgPSBpc05wdiA/ICducHYnIDogJ2RhcmsnOwogICAgY29uc3QgYXBwTGFiZWwgPSBpc05wdiA/ICdOcHZ0JyA6ICdEYXJrVHVubmVsJzsKCiAgICBpZiAocmVzRWwpIHsKICAgICAgcmVzRWwuY2xhc3NOYW1lID0gJ2xpbmstcmVzdWx0IHNob3cnOwogICAgICBjb25zdCBzYWZlTGluayA9IGxpbmsucmVwbGFjZSgvXFwvZywnXFxcXCcpLnJlcGxhY2UoLycvZywiXFwnIik7CiAgICAgIHJlc0VsLmlubmVySFRNTCA9CiAgICAgICAgIjxkaXYgY2xhc3M9J2xpbmstcmVzdWx0LWhkcic+IiArCiAgICAgICAgICAiPHNwYW4gY2xhc3M9J2ltcC1iYWRnZSAiK2NDbHMrIic+IithcHBMYWJlbCsiPC9zcGFuPiIgKwogICAgICAgICAgIjxzcGFuIHN0eWxlPSdmb250LXNpemU6LjY1cmVtO2NvbG9yOnZhcigtLW11dGVkKSc+Iitwcm8ubmFtZSsiIFx4YjcgUG9ydCAiK19zc2hQb3J0KyI8L3NwYW4+IiArCiAgICAgICAgICAiPHNwYW4gc3R5bGU9J2ZvbnQtc2l6ZTouNjVyZW07Y29sb3I6IzIyYzU1ZTttYXJnaW4tbGVmdDphdXRvJz5cdTI3MDUgIit1c2VyKyI8L3NwYW4+IiArCiAgICAgICAgIjwvZGl2PiIgKwogICAgICAgICI8ZGl2IGNsYXNzPSdsaW5rLXByZXZpZXciK2xwQ2xzKyInPiIrbGluaysiPC9kaXY+IiArCiAgICAgICAgIjxidXR0b24gY2xhc3M9J2NvcHktbGluay1idG4gIitjQ2xzKyInIGlkPSdjb3B5LXNzaC1idG4nIG9uY2xpY2s9XCJjb3B5U1NITGluaygpXCI+IisKICAgICAgICAgICJcdWQ4M2RcdWRjY2IgQ29weSAiK2FwcExhYmVsKyIgTGluayIrCiAgICAgICAgIjwvYnV0dG9uPiI7CiAgICAgIHdpbmRvdy5fbGFzdFNTSExpbmsgPSBsaW5rOwogICAgICB3aW5kb3cuX2xhc3RTU0hBcHAgID0gY0NsczsKICAgICAgd2luZG93Ll9sYXN0U1NITGFiZWwgPSBhcHBMYWJlbDsKICAgIH0KCiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ+KchSDguKrguKPguYnguLLguIcgJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIIMK3IOC4q+C4oeC4lOC4reC4suC4ouC4uCAnK2QuZXhwLCdvaycpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyJykudmFsdWU9Jyc7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXBhc3MnKS52YWx1ZT0nJzsKICAgIGxvYWRTU0hUYWJsZUluRm9ybSgpOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1Mjc0YyAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgYnRuLmRpc2FibGVkPWZhbHNlOyBidG4uaW5uZXJIVE1MPSfinpUg4Liq4Lij4LmJ4Liy4LiHIFVzZXInOyB9Cn0KZnVuY3Rpb24gY29weVNTSExpbmsoKSB7CiAgY29uc3QgbGluayA9IHdpbmRvdy5fbGFzdFNTSExpbmt8fCcnOwogIGNvbnN0IGNDbHMgPSB3aW5kb3cuX2xhc3RTU0hBcHB8fCducHYnOwogIGNvbnN0IGxhYmVsID0gd2luZG93Ll9sYXN0U1NITGFiZWx8fCdMaW5rJzsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dChsaW5rKS50aGVuKGZ1bmN0aW9uKCl7CiAgICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2NvcHktc3NoLWJ0bicpOwogICAgaWYoYil7IGIudGV4dENvbnRlbnQ9J1x1MjcwNSDguITguLHguJTguKXguK3guIHguYHguKXguYnguKchJzsgc2V0VGltZW91dChmdW5jdGlvbigpe2IudGV4dENvbnRlbnQ9J1x1ZDgzZFx1ZGNjYiBDb3B5ICcrbGFiZWwrJyBMaW5rJzt9LDIwMDApOyB9CiAgfSkuY2F0Y2goZnVuY3Rpb24oKXsgcHJvbXB0KCdDb3B5IGxpbms6JyxsaW5rKTsgfSk7Cn0KCi8vIFNTSCB1c2VyIHRhYmxlCmxldCBfc3NoVGFibGVVc2VycyA9IFtdOwphc3luYyBmdW5jdGlvbiBsb2FkU1NIVGFibGVJbkZvcm0oKSB7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgX3NzaFRhYmxlVXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgcmVuZGVyU1NIVGFibGUoX3NzaFRhYmxlVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgY29uc3QgdGIgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItdGJvZHknKTsKICAgIGlmKHRiKSB0Yi5pbm5lckhUTUw9Jzx0cj48dGQgY29sc3Bhbj0iNSIgc3R5bGU9InRleHQtYWxpZ246Y2VudGVyO2NvbG9yOiNlZjQ0NDQ7cGFkZGluZzoxNnB4Ij7guYDguIrguLfguYjguK3guKHguJXguYjguK0gU1NIIEFQSSDguYTguKHguYjguYTguJTguYk8L3RkPjwvdHI+JzsKICB9Cn0KZnVuY3Rpb24gcmVuZGVyU1NIVGFibGUodXNlcnMpIHsKICBjb25zdCB0YiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci10Ym9keScpOwogIGlmICghdGIpIHJldHVybjsKICBpZiAoIXVzZXJzLmxlbmd0aCkgewogICAgdGIuaW5uZXJIVE1MPSc8dHI+PHRkIGNvbHNwYW49IjUiIHN0eWxlPSJ0ZXh0LWFsaWduOmNlbnRlcjtjb2xvcjp2YXIoLS1tdXRlZCk7cGFkZGluZzoyMHB4Ij7guYTguKHguYjguKHguLUgU1NIIHVzZXJzPC90ZD48L3RyPic7CiAgICByZXR1cm47CiAgfQogIGNvbnN0IG5vdyA9IG5ldyBEYXRlKCkudG9JU09TdHJpbmcoKS5zbGljZSgwLDEwKTsKICB0Yi5pbm5lckhUTUwgPSB1c2Vycy5tYXAoZnVuY3Rpb24odSxpKXsKICAgIGNvbnN0IGV4cGlyZWQgPSB1LmV4cCAmJiB1LmV4cCA8IG5vdzsKICAgIGNvbnN0IGFjdGl2ZSAgPSB1LmFjdGl2ZSAhPT0gZmFsc2UgJiYgIWV4cGlyZWQ7CiAgICBjb25zdCBkTGVmdCAgID0gdS5leHAgPyBNYXRoLmNlaWwoKG5ldyBEYXRlKHUuZXhwKS1EYXRlLm5vdygpKS84NjQwMDAwMCkgOiBudWxsOwogICAgY29uc3QgYmFkZ2UgICA9IGFjdGl2ZQogICAgICA/ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1nIj5BQ1RJVkU8L3NwYW4+JwogICAgICA6ICc8c3BhbiBjbGFzcz0iYmRnIGJkZy1yIj5FWFBJUkVEPC9zcGFuPic7CiAgICBjb25zdCBkVGFnID0gZExlZnQhPT1udWxsCiAgICAgID8gJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj4nKyhkTGVmdD4wP2RMZWZ0KydkJzon4Lir4Lih4LiUJykrJzwvc3Bhbj4nCiAgICAgIDogJzxzcGFuIGNsYXNzPSJkYXlzLWJhZGdlIj5cdTIyMWU8L3NwYW4+JzsKICAgIHJldHVybiAnPHRyPjx0ZCBzdHlsZT0iY29sb3I6dmFyKC0tbXV0ZWQpIj4nKyhpKzEpKyc8L3RkPicgKwogICAgICAnPHRkPjxiPicrdS51c2VyKyc8L2I+PC90ZD4nICsKICAgICAgJzx0ZCBzdHlsZT0iZm9udC1zaXplOjExcHg7Y29sb3I6JysoZXhwaXJlZD8nI2VmNDQ0NCc6J3ZhcigtLW11dGVkKScpKyciPicrCiAgICAgICAgKHUuZXhwfHwn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJzwvdGQ+JyArCiAgICAgICc8dGQ+JytiYWRnZSsnPC90ZD4nICsKICAgICAgJzx0ZD48ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7Z2FwOjRweDthbGlnbi1pdGVtczpjZW50ZXIiPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguJXguYjguK3guK3guLLguKLguLgiIG9uY2xpY2s9Im9wZW5TU0hSZW5ld01vZGFsKFwnJyt1LnVzZXIrJ1wnKSI+8J+UhDwvYnV0dG9uPicrCiAgICAgICAgJzxidXR0b24gY2xhc3M9ImJ0bi10YmwiIHRpdGxlPSLguKXguJoiIG9uY2xpY2s9ImRlbFNTSFVzZXIoXCcnK3UudXNlcisnXCcpIiBzdHlsZT0iYm9yZGVyLWNvbG9yOnJnYmEoMjM5LDY4LDY4LC4zKSI+8J+Xke+4jzwvYnV0dG9uPicrCiAgICAgICAgZFRhZysKICAgICAgJzwvZGl2PjwvdGQ+PC90cj4nOwogIH0pLmpvaW4oJycpOwp9CmZ1bmN0aW9uIGZpbHRlclNTSFVzZXJzKHEpIHsKICByZW5kZXJTU0hUYWJsZShfc3NoVGFibGVVc2Vycy5maWx0ZXIoZnVuY3Rpb24odSl7cmV0dXJuICh1LnVzZXJ8fCcnKS50b0xvd2VyQ2FzZSgpLmluY2x1ZGVzKHEudG9Mb3dlckNhc2UoKSk7fSkpOwp9Ci8vIFNTSCBSZW5ldyBNb2RhbApsZXQgX3JlbmV3U1NIVXNlciA9ICcnOwpmdW5jdGlvbiBvcGVuU1NIUmVuZXdNb2RhbCh1c2VyKSB7CiAgX3JlbmV3U1NIVXNlciA9IHVzZXI7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy11c2VybmFtZScpLnRleHRDb250ZW50ID0gdXNlcjsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXJlbmV3LWRheXMnKS52YWx1ZSA9ICczMCc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKfQpmdW5jdGlvbiBjbG9zZVNTSFJlbmV3TW9kYWwoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1tb2RhbCcpLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKTsKICBfcmVuZXdTU0hVc2VyID0gJyc7Cn0KYXN5bmMgZnVuY3Rpb24gZG9TU0hSZW5ldygpIHsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmICghZGF5c3x8ZGF5czw9MCkgcmV0dXJuOwogIGNvbnN0IGJ0biA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtcmVuZXctYnRuJyk7CiAgYnRuLmRpc2FibGVkID0gdHJ1ZTsgYnRuLnRleHRDb250ZW50ID0gJ+C4geC4s+C4peC4seC4h+C4leC5iOC4reC4reC4suC4ouC4uC4uLic7CiAgdHJ5IHsKICAgIGNvbnN0IHIgPSBhd2FpdCBmZXRjaChBUEkrJy9leHRlbmRfc3NoJyx7CiAgICAgIG1ldGhvZDonUE9TVCcsaGVhZGVyczp7J0NvbnRlbnQtVHlwZSc6J2FwcGxpY2F0aW9uL2pzb24nfSwKICAgICAgYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcjpfcmVuZXdTU0hVc2VyLGRheXN9KQogICAgfSkudGhlbihmdW5jdGlvbihyKXtyZXR1cm4gci5qc29uKCk7fSk7CiAgICBpZiAoIXIub2spIHRocm93IG5ldyBFcnJvcihyLmVycm9yfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ3NzaC1hbGVydCcsJ1x1MjcwNSDguJXguYjguK3guK3guLLguKLguLggJytfcmVuZXdTU0hVc2VyKycgKycrZGF5cysnIOC4p+C4seC4mSDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgY2xvc2VTU0hSZW5ld01vZGFsKCk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsKICAgIHNob3dBbGVydCgnc3NoLWFsZXJ0JywnXHUyNzRjICcrZS5tZXNzYWdlLCdlcnInKTsKICB9IGZpbmFsbHkgewogICAgYnRuLmRpc2FibGVkID0gZmFsc2U7IGJ0bi50ZXh0Q29udGVudCA9ICfinIUg4Lii4Li34LiZ4Lii4Lix4LiZ4LiV4LmI4Lit4Lit4Liy4Lii4Li4JzsKICB9Cn0KYXN5bmMgZnVuY3Rpb24gcmVuZXdTU0hVc2VyKHVzZXIpIHsgb3BlblNTSFJlbmV3TW9kYWwodXNlcik7IH0KYXN5bmMgZnVuY3Rpb24gZGVsU1NIVXNlcih1c2VyKSB7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiDguJbguLLguKfguKM/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgciA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHsKICAgICAgbWV0aG9kOidQT1NUJyxoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vanNvbid9LAogICAgICBib2R5OkpTT04uc3RyaW5naWZ5KHt1c2VyfSkKICAgIH0pLnRoZW4oZnVuY3Rpb24ocil7cmV0dXJuIHIuanNvbigpO30pOwogICAgaWYgKCFyLm9rKSB0aHJvdyBuZXcgRXJyb3Ioci5lcnJvcnx8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdzc2gtYWxlcnQnLCdcdTI3MDUg4Lil4LiaICcrdXNlcisnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBsb2FkU1NIVGFibGVJbkZvcm0oKTsKICB9IGNhdGNoKGUpIHsgYWxlcnQoJ1x1Mjc0YyAnK2UubWVzc2FnZSk7IH0KfQovLyDilZDilZDilZDilZAgQ1JFQVRFIFZMRVNTIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBnZW5VVUlEKCkgewogIHJldHVybiAneHh4eHh4eHgteHh4eC00eHh4LXl4eHgteHh4eHh4eHh4eHh4Jy5yZXBsYWNlKC9beHldL2csYz0+ewogICAgY29uc3Qgcj1NYXRoLnJhbmRvbSgpKjE2fDA7IHJldHVybiAoYz09PSd4Jz9yOihyJjB4M3wweDgpKS50b1N0cmluZygxNik7CiAgfSk7Cn0KYXN5bmMgZnVuY3Rpb24gY3JlYXRlVkxFU1MoY2FycmllcikgewogIGNvbnN0IGVtYWlsRWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChjYXJyaWVyKyctZW1haWwnKTsKICBjb25zdCBkYXlzRWwgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWRheXMnKTsKICBjb25zdCBpcEVsICAgID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWlwJyk7CiAgY29uc3QgZ2JFbCAgICA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1nYicpOwogIGNvbnN0IGVtYWlsICAgPSBlbWFpbEVsLnZhbHVlLnRyaW0oKTsKICBjb25zdCBkYXlzICAgID0gcGFyc2VJbnQoZGF5c0VsLnZhbHVlKXx8MzA7CiAgY29uc3QgaXBMaW1pdCA9IHBhcnNlSW50KGlwRWwudmFsdWUpfHwyOwogIGNvbnN0IGdiICAgICAgPSBwYXJzZUludChnYkVsLnZhbHVlKXx8MDsKICBpZiAoIWVtYWlsKSByZXR1cm4gc2hvd0FsZXJ0KGNhcnJpZXIrJy1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC5g+C4quC5iCBFbWFpbC9Vc2VybmFtZScsJ2VycicpOwoKICBjb25zdCBwb3J0ID0gMTgwODA7IC8vIGludGVybmFsIHgtdWkgaW5ib3VuZCBwb3J0ICh2OTog4Lir4Lil4Lix4LiHIE5naW54IEw3ICsgSEFQcm94eSkKICBjb25zdCBwdWJsaWNQb3J0ID0gODA7IC8vIEhBUHJveHkgcHVibGljIHBvcnQg4LiX4Li14LmIIGNsaWVudCDguJXguYnguK3guIfguJXguYjguK3guIjguKPguLTguIcKICBjb25zdCBzbmkgID0gY2Fycmllcj09PSdhaXMnID8gJ2NqLWViYi5zcGVlZHRlc3QubmV0JyA6ICd0cnVlLWludGVybmV0Lnpvb20ueHl6LnNlcnZpY2VzJzsKCiAgY29uc3QgYnRuID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWJ0bicpOwogIGJ0bi5kaXNhYmxlZD10cnVlOyBidG4uaW5uZXJIVE1MPSc8c3BhbiBjbGFzcz0ic3BpbiI+PC9zcGFuPuC4geC4s+C4peC4seC4h+C4quC4o+C5ieC4suC4hy4uLic7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoY2FycmllcisnLXJlc3VsdCcpLmNsYXNzTGlzdC5yZW1vdmUoJ3Nob3cnKTsKCiAgdHJ5IHsKICAgIGlmICghX3h1aUNvb2tpZSkgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIC8vIOC4q+C4siBpbmJvdW5kIGlkCiAgICBjb25zdCBsaXN0ID0gYXdhaXQgeHVpR2V0KCcvcGFuZWwvYXBpL2luYm91bmRzL2xpc3QnKTsKICAgIGNvbnN0IGliID0gKGxpc3Qub2JqfHxbXSkuZmluZCh4PT54LnBvcnQ9PT1wb3J0KTsKICAgIGlmICghaWIpIHRocm93IG5ldyBFcnJvcihg4LmE4Lih4LmI4Lie4LiaIGluYm91bmQgcG9ydCAke3BvcnR9IOKAlCDguKPguLHguJkgc2V0dXAg4LiB4LmI4Lit4LiZYCk7CgogICAgY29uc3QgdWlkID0gZ2VuVVVJRCgpOwogICAgY29uc3QgZXhwTXMgPSBkYXlzID4gMCA/IChEYXRlLm5vdygpICsgZGF5cyo4NjQwMDAwMCkgOiAwOwogICAgY29uc3QgdG90YWxCeXRlcyA9IGdiID4gMCA/IGdiKjEwNzM3NDE4MjQgOiAwOwoKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvYWRkQ2xpZW50JywgewogICAgICBpZDogaWIuaWQsCiAgICAgIHNldHRpbmdzOiBKU09OLnN0cmluZ2lmeSh7IGNsaWVudHM6W3sKICAgICAgICBpZDp1aWQsIGZsb3c6JycsIGVtYWlsLCBsaW1pdElwOmlwTGltaXQsCiAgICAgICAgdG90YWxHQjp0b3RhbEJ5dGVzLCBleHBpcnlUaW1lOmV4cE1zLCBlbmFibGU6dHJ1ZSwgdGdJZDonJywgc3ViSWQ6JycsIGNvbW1lbnQ6JycsIHJlc2V0OjAKICAgICAgfV19KQogICAgfSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZyB8fCAn4Liq4Lij4LmJ4Liy4LiH4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CgogICAgY29uc3QgbGlua05hbWUgPSBjYXJyaWVyPT09J2FpcycgPyAnQUlTLeC4geC4seC4meC4o+C4seC5iOC4py0nK2VtYWlsIDogJ1RSVUUtVkRPLScrZW1haWw7CiAgICBjb25zdCBsaW5rID0gY2Fycmllcj09PSdhaXMnID8gYHZsZXNzOi8vJHt1aWR9QCR7SE9TVH06JHtwdWJsaWNQb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7c25pfSMke2VuY29kZVVSSUNvbXBvbmVudChsaW5rTmFtZSl9YCA6IGB2bGVzczovLyR7dWlkfUAke3NuaX06JHtwdWJsaWNQb3J0fT90eXBlPXdzJnNlY3VyaXR5PW5vbmUmcGF0aD0lMkZ2bGVzcyZob3N0PSR7SE9TVH0jJHtlbmNvZGVVUklDb21wb25lbnQobGlua05hbWUpfWA7CgogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZW1haWwnKS50ZXh0Q29udGVudCA9IGVtYWlsOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctdXVpZCcpLnRleHRDb250ZW50ID0gdWlkOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctZXhwJykudGV4dENvbnRlbnQgPSBleHBNcyA+IDAgPyBmbXREYXRlKGV4cE1zKSA6ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3ItJytjYXJyaWVyKyctbGluaycpLnRleHRDb250ZW50ID0gbGluazsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1yZXN1bHQnKS5jbGFzc0xpc3QuYWRkKCdzaG93Jyk7CiAgICAvLyBHZW5lcmF0ZSBRUiBjb2RlCiAgICBjb25zdCBxckRpdiA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGNhcnJpZXIrJy1xcicpOwogICAgaWYgKHFyRGl2KSB7CiAgICAgIHFyRGl2LmlubmVySFRNTCA9ICcnOwogICAgICB0cnkgewogICAgICAgIG5ldyBRUkNvZGUocXJEaXYsIHsgdGV4dDogbGluaywgd2lkdGg6IDE4MCwgaGVpZ2h0OiAxODAsIGNvcnJlY3RMZXZlbDogUVJDb2RlLkNvcnJlY3RMZXZlbC5NIH0pOwogICAgICB9IGNhdGNoKHFyRXJyKSB7IHFyRGl2LmlubmVySFRNTCA9ICcnOyB9CiAgICB9CiAgICBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4pyFIOC4quC4o+C5ieC4suC4hyBWTEVTUyBBY2NvdW50IOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBlbWFpbEVsLnZhbHVlPScnOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoY2FycmllcisnLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBidG4uZGlzYWJsZWQ9ZmFsc2U7IGJ0bi5pbm5lckhUTUw9J+KaoSDguKrguKPguYnguLLguIcgJysoY2Fycmllcj09PSdhaXMnPydBSVMnOidUUlVFJykrJyBBY2NvdW50JzsgfQp9CgovLyDilZDilZDilZDilZAgTUFOQUdFIFVTRVJTIOKVkOKVkOKVkOKVkApsZXQgX2FsbFVzZXJzID0gW10sIF9jdXJVc2VyID0gbnVsbDsKYXN5bmMgZnVuY3Rpb24gbG9hZFVzZXJzKCkgewogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1c2VyLWxpc3QnKS5pbm5lckhUTUwgPSAnPGRpdiBjbGFzcz0ibG9hZGluZyI+4LiB4Liz4Lil4Lix4LiH4LmC4Lir4Lil4LiULi4uPC9kaXY+JzsKICB0cnkgewogICAgX3h1aUNvb2tpZSA9IGZhbHNlOwogICAgYXdhaXQgeHVpRW5zdXJlTG9naW4oKTsKICAgIGNvbnN0IGQgPSBhd2FpdCB4dWlHZXQoJy9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCcpOwogICAgaWYgKCFkLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihkLm1zZyB8fCAn4LmC4Lir4Lil4LiUIGluYm91bmRzIOC5hOC4oeC5iOC5hOC4lOC5iScpOwogICAgX2FsbFVzZXJzID0gW107CiAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgY29uc3Qgc2V0dGluZ3MgPSB0eXBlb2YgaWIuc2V0dGluZ3M9PT0nc3RyaW5nJyA/IEpTT04ucGFyc2UoaWIuc2V0dGluZ3MpIDogaWIuc2V0dGluZ3M7CiAgICAgIChzZXR0aW5ncy5jbGllbnRzfHxbXSkuZm9yRWFjaChjID0+IHsKICAgICAgICBjb25zdCBlbWFpbCA9IGMuZW1haWx8fGMuaWQ7CiAgICAgICAgY29uc3QgY3MgPSAoaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT1lbWFpbCl8fG51bGw7CiAgICAgICAgX2FsbFVzZXJzLnB1c2goewogICAgICAgICAgaWJJZDogaWIuaWQsIHBvcnQ6IGliLnBvcnQsIHByb3RvOiBpYi5wcm90b2NvbCwKICAgICAgICAgIGVtYWlsLCB1dWlkOiBjLmlkLAogICAgICAgICAgZXhwOiBjLmV4cGlyeVRpbWV8fDAsIHRvdGFsOiBjLnRvdGFsR0J8fDAsCiAgICAgICAgICB1cDogY3MgPyBjcy51cCA6IDAsIGRvd246IGNzID8gY3MuZG93biA6IDAsIGFsbFRpbWU6IGNzID8gKGNzLmFsbFRpbWV8fDApIDogMCwgbGltaXRJcDogYy5saW1pdElwfHwwCiAgICAgICAgfSk7CiAgICAgIH0pOwogICAgfSk7CiAgICByZW5kZXJVc2VycyhfYWxsVXNlcnMpOwogIH0gY2F0Y2goZSkgewogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9ICc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmZ1bmN0aW9uIHJlbmRlclVzZXJzKHVzZXJzKSB7CiAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5OtPC9kaXY+PHA+4LmE4Lih4LmI4Lie4Lia4Lii4Li54Liq4LmA4LiL4Lit4Lij4LmMPC9wPjwvZGl2Pic7IHJldHVybjsgfQogIGNvbnN0IG5vdyA9IERhdGUubm93KCk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1ID0+IHsKICAgIGNvbnN0IGRsID0gZGF5c0xlZnQodS5leHApOwogICAgbGV0IGJhZGdlLCBjbHM7CiAgICBpZiAoIXUuZXhwIHx8IHUuZXhwPT09MCkgeyBiYWRnZT0n4pyTIOC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCc7IGNscz0nb2snOyB9CiAgICBlbHNlIGlmIChkbCA8IDApICAgICAgICAgeyBiYWRnZT0n4Lir4Lih4LiU4Lit4Liy4Lii4Li4JzsgY2xzPSdleHAnOyB9CiAgICBlbHNlIGlmIChkbCA8PSAzKSAgICAgICAgeyBiYWRnZT0n4pqgICcrZGwrJ2QnOyBjbHM9J3Nvb24nOyB9CiAgICBlbHNlICAgICAgICAgICAgICAgICAgICAgeyBiYWRnZT0n4pyTICcrZGwrJ2QnOyBjbHM9J29rJzsgfQogICAgY29uc3QgYXZDbHMgPSBkbCA8IDAgPyAnYXYteCcgOiAnYXYtZyc7CiAgICByZXR1cm4gYDxkaXYgY2xhc3M9InVpdGVtIiBvbmNsaWNrPSJvcGVuVXNlcigke0pTT04uc3RyaW5naWZ5KHUpLnJlcGxhY2UoLyIvZywnJnF1b3Q7Jyl9KSI+CiAgICAgIDxkaXYgY2xhc3M9InVhdiAke2F2Q2xzfSI+JHsodS5lbWFpbHx8Jz8nKVswXS50b1VwcGVyQ2FzZSgpfTwvZGl2PgogICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgIDxkaXYgY2xhc3M9InVuIj4ke3UuZW1haWx9PC9kaXY+CiAgICAgICAgPGRpdiBjbGFzcz0idW0iPlBvcnQgJHt1LnBvcnR9IMK3ICR7Zm10Qnl0ZXMoKHUudXB8fDApKyh1LmRvd258fDApKyh1LmFsbFRpbWV8fDApKX0g4LmD4LiK4LmJPC9kaXY+CiAgICAgIDwvZGl2PgogICAgICA8c3BhbiBjbGFzcz0iYWJkZyAke2Nsc30iPiR7YmFkZ2V9PC9zcGFuPgogICAgPC9kaXY+YDsKICB9KS5qb2luKCcnKTsKfQpmdW5jdGlvbiBmaWx0ZXJVc2VycyhxKSB7CiAgcmVuZGVyVXNlcnMoX2FsbFVzZXJzLmZpbHRlcih1PT4odS5lbWFpbHx8JycpLnRvTG93ZXJDYXNlKCkuaW5jbHVkZXMocS50b0xvd2VyQ2FzZSgpKSkpOwp9CgovLyDilZDilZDilZDilZAgTU9EQUwgVVNFUiDilZDilZDilZDilZAKZnVuY3Rpb24gb3BlblVzZXIodSkgewogIGlmICh0eXBlb2YgdSA9PT0gJ3N0cmluZycpIHUgPSBKU09OLnBhcnNlKHUpOwogIF9jdXJVc2VyID0gdTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXQnKS50ZXh0Q29udGVudCA9ICfimpnvuI8gJyt1LmVtYWlsOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdScpLnRleHRDb250ZW50ID0gdS5lbWFpbDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHAnKS50ZXh0Q29udGVudCA9IHUucG9ydDsKICBjb25zdCBkbCA9IGRheXNMZWZ0KHUuZXhwKTsKICBjb25zdCBleHBUeHQgPSAhdS5leHB8fHUuZXhwPT09MCA/ICfguYTguKHguYjguIjguLPguIHguLHguJQnIDogZm10RGF0ZSh1LmV4cCk7CiAgY29uc3QgZGUgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGUnKTsKICBkZS50ZXh0Q29udGVudCA9IGV4cFR4dDsKICBkZS5jbGFzc05hbWUgPSAnZHYnICsgKGRsICE9PSBudWxsICYmIGRsIDwgMCA/ICcgcmVkJyA6ICcgZ3JlZW4nKTsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGQnKS50ZXh0Q29udGVudCA9IHUudG90YWwgPiAwID8gZm10Qnl0ZXModS50b3RhbCkgOiAn4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZHRyJykudGV4dENvbnRlbnQgPSBmbXRCeXRlcygodS51cHx8MCkrKHUuZG93bnx8MCkrKHUuYWxsVGltZXx8MCkpOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkaScpLnRleHRDb250ZW50ID0gdS5saW1pdElwIHx8ICfiiJ4nOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdkdXUnKS50ZXh0Q29udGVudCA9IHUudXVpZDsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwtYWxlcnQnKS5zdHlsZS5kaXNwbGF5PSdub25lJzsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QuYWRkKCdvcGVuJyk7Cn0KZnVuY3Rpb24gY20oKXsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbW9kYWwnKS5jbGFzc0xpc3QucmVtb3ZlKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7Cn0KCi8vIOKUgOKUgCBNT0RBTCA2LUFDVElPTiBTWVNURU0g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSACmNvbnN0IF9tU3VicyA9IFsncmVuZXcnLCdleHRlbmQnLCdhZGRkYXRhJywnc2V0ZGF0YScsJ3Jlc2V0JywnZGVsZXRlJ107CmZ1bmN0aW9uIG1BY3Rpb24oa2V5KSB7CiAgY29uc3QgZWwgPSBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2tleSk7CiAgY29uc3QgaXNPcGVuID0gZWwuY2xhc3NMaXN0LmNvbnRhaW5zKCdvcGVuJyk7CiAgX21TdWJzLmZvckVhY2goayA9PiBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbXN1Yi0nK2spLmNsYXNzTGlzdC5yZW1vdmUoJ29wZW4nKSk7CiAgZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCgnLmFidG4nKS5mb3JFYWNoKGIgPT4gYi5jbGFzc0xpc3QucmVtb3ZlKCdhY3RpdmUnKSk7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ21vZGFsLWFsZXJ0Jykuc3R5bGUuZGlzcGxheT0nbm9uZSc7CiAgaWYgKCFpc09wZW4pIHsKICAgIGVsLmNsYXNzTGlzdC5hZGQoJ29wZW4nKTsKICAgIGlmIChrZXk9PT0nZGVsZXRlJyAmJiBfY3VyVXNlcikgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZGVsLW5hbWUnKS50ZXh0Q29udGVudCA9IF9jdXJVc2VyLmVtYWlsOwogICAgc2V0VGltZW91dCgoKT0+ZWwuc2Nyb2xsSW50b1ZpZXcoe2JlaGF2aW9yOidzbW9vdGgnLGJsb2NrOiduZWFyZXN0J30pLDEwMCk7CiAgfQp9CmZ1bmN0aW9uIF9tQnRuTG9hZChpZCwgbG9hZGluZywgb3JpZ1RleHQpIHsKICBjb25zdCBiID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoaWQpOwogIGlmICghYikgcmV0dXJuOwogIGIuZGlzYWJsZWQgPSBsb2FkaW5nOwogIGlmIChsb2FkaW5nKSB7IGIuZGF0YXNldC5vcmlnID0gYi50ZXh0Q29udGVudDsgYi5pbm5lckhUTUwgPSAnPHNwYW4gY2xhc3M9InNwaW4iPjwvc3Bhbj4g4LiB4Liz4Lil4Lix4LiH4LiU4Liz4LmA4LiZ4Li04LiZ4LiB4Liy4LijLi4uJzsgfQogIGVsc2UgeyBiLnRleHRDb250ZW50ID0gYi5kYXRhc2V0Lm9yaWcgfHwgb3JpZ1RleHQgfHwgJ+C4lOC4s+C5gOC4meC4tOC4meC4geC4suC4oyc7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9SZW5ld1VzZXIoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGRheXMgPSBwYXJzZUludChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1yZW5ldy1kYXlzJykudmFsdWUpfHwwOwogIGlmIChkYXlzIDw9IDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiB4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZJywnZXJyJyk7CiAgX21CdG5Mb2FkKCdtLXJlbmV3LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBleHBNcyA9IERhdGUubm93KCkgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC4leC5iOC4reC4reC4suC4ouC4uOC4quC4s+C5gOC4o+C5h+C4iCAnK2RheXMrJyDguKfguLHguJkgKOC4o+C4teC5gOC4i+C4leC4iOC4suC4geC4p+C4seC4meC4meC4teC5iSknLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1yZW5ldy1idG4nLCBmYWxzZSk7IH0KfQoKYXN5bmMgZnVuY3Rpb24gZG9FeHRlbmRVc2VyKCkgewogIGlmICghX2N1clVzZXIpIHJldHVybjsKICBjb25zdCBkYXlzID0gcGFyc2VJbnQoZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ20tZXh0ZW5kLWRheXMnKS52YWx1ZSl8fDA7CiAgaWYgKGRheXMgPD0gMCkgcmV0dXJuIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfguIHguKPguLjguJPguLLguIHguKPguK3guIHguIjguLPguJnguKfguJnguKfguLHguJknLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCBiYXNlID0gKF9jdXJVc2VyLmV4cCAmJiBfY3VyVXNlci5leHAgPiBEYXRlLm5vdygpKSA/IF9jdXJVc2VyLmV4cCA6IERhdGUubm93KCk7CiAgICBjb25zdCBleHBNcyA9IGJhc2UgKyBkYXlzKjg2NDAwMDAwOwogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy91cGRhdGVDbGllbnQvJytfY3VyVXNlci51dWlkLCB7CiAgICAgIGlkOl9jdXJVc2VyLmliSWQsCiAgICAgIHNldHRpbmdzOkpTT04uc3RyaW5naWZ5KHtjbGllbnRzOlt7aWQ6X2N1clVzZXIudXVpZCxmbG93OicnLGVtYWlsOl9jdXJVc2VyLmVtYWlsLGxpbWl0SXA6X2N1clVzZXIubGltaXRJcCx0b3RhbEdCOl9jdXJVc2VyLnRvdGFsLGV4cGlyeVRpbWU6ZXhwTXMsZW5hYmxlOnRydWUsdGdJZDonJyxzdWJJZDonJyxjb21tZW50OicnLHJlc2V0OjB9XX0pCiAgICB9KTsKICAgIGlmICghcmVzLnN1Y2Nlc3MpIHRocm93IG5ldyBFcnJvcihyZXMubXNnfHwn4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4pyFIOC5gOC4nuC4tOC5iOC4oSAnK2RheXMrJyDguKfguLHguJkg4Liq4Liz4LmA4Lij4LmH4LiIICjguJXguYjguK3guIjguLLguIHguKfguLHguJnguKvguKHguJQpJywnb2snKTsKICAgIHNldFRpbWVvdXQoKCk9PnsgY20oKTsgbG9hZFVzZXJzKCk7IH0sIDE4MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tZXh0ZW5kLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb0FkZERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGFkZEdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1hZGRkYXRhLWdiJykudmFsdWUpfHwwOwogIGlmIChhZGRHYiA8PSAwKSByZXR1cm4gc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+C4geC4o+C4uOC4k+C4suC4geC4o+C4reC4gSBHQiDguJfguLXguYjguJXguYnguK3guIfguIHguLLguKPguYDguJ7guLTguYjguKEnLCdlcnInKTsKICBfbUJ0bkxvYWQoJ20tYWRkZGF0YS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgbmV3VG90YWwgPSAoX2N1clVzZXIudG90YWx8fDApICsgYWRkR2IqMTA3Mzc0MTgyNDsKICAgIGNvbnN0IHJlcyA9IGF3YWl0IHh1aVBvc3QoJy9wYW5lbC9hcGkvaW5ib3VuZHMvdXBkYXRlQ2xpZW50LycrX2N1clVzZXIudXVpZCwgewogICAgICBpZDpfY3VyVXNlci5pYklkLAogICAgICBzZXR0aW5nczpKU09OLnN0cmluZ2lmeSh7Y2xpZW50czpbe2lkOl9jdXJVc2VyLnV1aWQsZmxvdzonJyxlbWFpbDpfY3VyVXNlci5lbWFpbCxsaW1pdElwOl9jdXJVc2VyLmxpbWl0SXAsdG90YWxHQjpuZXdUb3RhbCxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LmA4Lie4Li04LmI4LihIERhdGEgKycrYWRkR2IrJyBHQiDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1hZGRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1NldERhdGEoKSB7CiAgaWYgKCFfY3VyVXNlcikgcmV0dXJuOwogIGNvbnN0IGdiID0gcGFyc2VGbG9hdChkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnbS1zZXRkYXRhLWdiJykudmFsdWUpOwogIGlmIChpc05hTihnYil8fGdiPDApIHJldHVybiBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LiB4Lij4Lit4LiBIEdCICgwID0g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUKScsJ2VycicpOwogIF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCB0b3RhbEJ5dGVzID0gZ2IgPiAwID8gZ2IqMTA3Mzc0MTgyNCA6IDA7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzL3VwZGF0ZUNsaWVudC8nK19jdXJVc2VyLnV1aWQsIHsKICAgICAgaWQ6X2N1clVzZXIuaWJJZCwKICAgICAgc2V0dGluZ3M6SlNPTi5zdHJpbmdpZnkoe2NsaWVudHM6W3tpZDpfY3VyVXNlci51dWlkLGZsb3c6JycsZW1haWw6X2N1clVzZXIuZW1haWwsbGltaXRJcDpfY3VyVXNlci5saW1pdElwLHRvdGFsR0I6dG90YWxCeXRlcyxleHBpcnlUaW1lOl9jdXJVc2VyLmV4cHx8MCxlbmFibGU6dHJ1ZSx0Z0lkOicnLHN1YklkOicnLGNvbW1lbnQ6JycscmVzZXQ6MH1dfSkKICAgIH0pOwogICAgaWYgKCFyZXMuc3VjY2VzcykgdGhyb3cgbmV3IEVycm9yKHJlcy5tc2d8fCfguYTguKHguYjguKrguLPguYDguKPguYfguIgnKTsKICAgIHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinIUg4LiV4Lix4LmJ4LiHIERhdGEgTGltaXQgJysoZ2I+MD9nYisnIEdCJzon4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUJykrJyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgfSwgMTgwMCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnbW9kYWwtYWxlcnQnLCfinYwgJytlLm1lc3NhZ2UsJ2VycicpOyB9CiAgZmluYWxseSB7IF9tQnRuTG9hZCgnbS1zZXRkYXRhLWJ0bicsIGZhbHNlKTsgfQp9Cgphc3luYyBmdW5jdGlvbiBkb1Jlc2V0VHJhZmZpYygpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLXJlc2V0LWJ0bicsIHRydWUpOwogIHRyeSB7CiAgICBjb25zdCByZXMgPSBhd2FpdCB4dWlQb3N0KCcvcGFuZWwvYXBpL2luYm91bmRzLycrX2N1clVzZXIuaWJJZCsnL3Jlc2V0Q2xpZW50VHJhZmZpYy8nK19jdXJVc2VyLmVtYWlsLCB7fSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKPguLXguYDguIvguJUgVHJhZmZpYyDguKrguLPguYDguKPguYfguIgnLCdvaycpOwogICAgc2V0VGltZW91dCgoKT0+eyBjbSgpOyBsb2FkVXNlcnMoKTsgbG9hZERhc2hib2FyZCAmJiBsb2FkRGFzaGJvYXJkKCk7IH0sIDE1MDApOwogIH0gY2F0Y2goZSkgeyBzaG93QWxlcnQoJ21vZGFsLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQogIGZpbmFsbHkgeyBfbUJ0bkxvYWQoJ20tcmVzZXQtYnRuJywgZmFsc2UpOyB9Cn0KCmFzeW5jIGZ1bmN0aW9uIGRvRGVsZXRlVXNlcigpIHsKICBpZiAoIV9jdXJVc2VyKSByZXR1cm47CiAgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCB0cnVlKTsKICB0cnkgewogICAgY29uc3QgcmVzID0gYXdhaXQgeHVpUG9zdCgnL3BhbmVsL2FwaS9pbmJvdW5kcy8nK19jdXJVc2VyLmliSWQrJy9kZWxDbGllbnQvJytfY3VyVXNlci51dWlkLCB7fSk7CiAgICBpZiAoIXJlcy5zdWNjZXNzKSB0aHJvdyBuZXcgRXJyb3IocmVzLm1zZ3x8J+C5hOC4oeC5iOC4quC4s+C5gOC4o+C5h+C4iCcpOwogICAgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KchSDguKXguJrguKLguLnguKogJytfY3VyVXNlci5lbWFpbCsnIOC4quC4s+C5gOC4o+C5h+C4iCcsJ29rJyk7CiAgICBzZXRUaW1lb3V0KCgpPT57IGNtKCk7IGxvYWRVc2VycygpOyB9LCAxMjAwKTsKICB9IGNhdGNoKGUpIHsgc2hvd0FsZXJ0KCdtb2RhbC1hbGVydCcsJ+KdjCAnK2UubWVzc2FnZSwnZXJyJyk7IH0KICBmaW5hbGx5IHsgX21CdG5Mb2FkKCdtLWRlbGV0ZS1idG4nLCBmYWxzZSk7IH0KfQoKLy8g4pWQ4pWQ4pWQ4pWQIE9OTElORSDilZDilZDilZDilZAKYXN5bmMgZnVuY3Rpb24gbG9hZE9ubGluZSgpIHsKICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIF94dWlDb29raWUgPSBmYWxzZTsKICAgIGF3YWl0IHh1aUVuc3VyZUxvZ2luKCk7CiAgICAvLyDguYLguKvguKXguJQgaW5ib3VuZHMg4LiW4LmJ4Liy4Lii4Lix4LiH4LmE4Lih4LmI4Lih4Li1CiAgICBpZiAoIV9hbGxVc2Vycy5sZW5ndGgpIHsKICAgICAgY29uc3QgZCA9IGF3YWl0IHh1aUdldCgnL3BhbmVsL2FwaS9pbmJvdW5kcy9saXN0JykuY2F0Y2goKCk9Pm51bGwpOwogICAgICBpZiAoZCAmJiBkLnN1Y2Nlc3MpIHsKICAgICAgICBfYWxsVXNlcnMgPSBbXTsKICAgICAgICAoZC5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAgIGNvbnN0IHNldHRpbmdzID0gdHlwZW9mIGliLnNldHRpbmdzPT09J3N0cmluZycgPyBKU09OLnBhcnNlKGliLnNldHRpbmdzKSA6IGliLnNldHRpbmdzOwogICAgICAgICAgKHNldHRpbmdzLmNsaWVudHN8fFtdKS5mb3JFYWNoKGMgPT4gewogICAgICAgICAgICBfYWxsVXNlcnMucHVzaCh7IGliSWQ6aWIuaWQsIHBvcnQ6aWIucG9ydCwgcHJvdG86aWIucHJvdG9jb2wsCiAgICAgICAgICAgICAgZW1haWw6Yy5lbWFpbHx8Yy5pZCwgdXVpZDpjLmlkLCBleHA6Yy5leHBpcnlUaW1lfHwwLAogICAgICAgICAgICAgIHRvdGFsOmMudG90YWxHQnx8MCwgdXA6KGliLmNsaWVudFN0YXRzfHxbXSkuZmluZCh4PT54LmVtYWlsPT09KGMuZW1haWx8fGMuaWQpKT8udXB8fDAsIGRvd246KGliLmNsaWVudFN0YXRzfHxbXSkuZmluZCh4PT54LmVtYWlsPT09KGMuZW1haWx8fGMuaWQpKT8uZG93bnx8MCwgYWxsVGltZTooaWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT0oYy5lbWFpbHx8Yy5pZCkpPy5hbGxUaW1lfHwwLCBsaW1pdElwOmMubGltaXRJcHx8MCB9KTsKICAgICAgICAgIH0pOwogICAgICAgIH0pOwogICAgICB9CiAgICB9CiAgICBsZXQgZW1haWxzID0gW107CiAgICBjb25zdCBub3cgPSBEYXRlLm5vdygpOwogICAgY29uc3QgZDIgPSBhd2FpdCB4dWlHZXQoIi9wYW5lbC9hcGkvaW5ib3VuZHMvbGlzdCIpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmIChkMiAmJiBkMi5zdWNjZXNzKSB7CiAgICAgIChkMi5vYmp8fFtdKS5mb3JFYWNoKGliID0+IHsKICAgICAgICAoaWIuY2xpZW50U3RhdHN8fFtdKS5mb3JFYWNoKGNzID0+IHsKICAgICAgICAgIGlmIChjcy5sYXN0T25saW5lICYmIChub3cgLSBjcy5sYXN0T25saW5lKSA8IDMwMDAwMCkgZW1haWxzLnB1c2goY3MuZW1haWwpOwogICAgICAgIH0pOwogICAgICB9KTsKICAgIH0KICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtY291bnQnKS50ZXh0Q29udGVudCA9IGVtYWlscy5sZW5ndGg7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLXRpbWUnKS50ZXh0Q29udGVudCA9IG5ldyBEYXRlKCkudG9Mb2NhbGVUaW1lU3RyaW5nKCd0aC1USCcpOwogICAgaWYgKCFlbWFpbHMubGVuZ3RoKSB7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ib2UiPjxkaXYgY2xhc3M9ImVpIj7wn5i0PC9kaXY+PHA+4LmE4Lih4LmI4Lih4Li14Lii4Li54Liq4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4LiV4Lit4LiZ4LiZ4Li14LmJPC9wPjwvZGl2Pic7CiAgICAgIHJldHVybjsKICAgIH0KICAgIGNvbnN0IHVNYXAgPSB7fTsKICAgIF9hbGxVc2Vycy5mb3JFYWNoKHU9PnsgdU1hcFt1LmVtYWlsXT11OyB9KTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdvbmxpbmUtbGlzdCcpLmlubmVySFRNTCA9IGVtYWlscy5tYXAoZW1haWw9PnsKICAgICAgY29uc3QgdSA9IHVNYXBbZW1haWxdOwogICAgICBjb25zdCBjcyA9IChkMiYmZDIub2JqfHxbXSkuZmxhdE1hcChpYj0+aWIuY2xpZW50U3RhdHN8fFtdKS5maW5kKHg9PnguZW1haWw9PT1lbWFpbCl8fG51bGw7CiAgICAgIGNvbnN0IGliT2JqID0gKGQyJiZkMi5vYmp8fFtdKS5maW5kKGliPT4oaWIuY2xpZW50U3RhdHN8fFtdKS5zb21lKHg9PnguZW1haWw9PT1lbWFpbCkpfHxudWxsOwogICAgICBjb25zdCB1c2VkR0IgPSBjcyA/ICgoY3MudXArY3MuZG93bisoY3MuYWxsVGltZXx8MCkpLzEwNzM3NDE4MjQpLnRvRml4ZWQoMikgOiAoaWJPYmogPyAoKGliT2JqLnVwK2liT2JqLmRvd24pLzEwNzM3NDE4MjQpLnRvRml4ZWQoMikgOiAwKTsKICAgICAgY29uc3QgdG90YWxHQiA9IGNzICYmIGNzLnRvdGFsPjAgPyAoY3MudG90YWwvMTA3Mzc0MTgyNCkudG9GaXhlZCgwKSA6IG51bGw7CiAgICAgIGNvbnN0IHBjdCA9ICh1ICYmIHUudG90YWw+MCkgPyBNYXRoLm1pbihNYXRoLnJvdW5kKCh1LnVwK3UuZG93bikvdS50b3RhbCoxMDApLDEwMCkgOiAwOwogICAgICBjb25zdCBiYXIgPSBwY3Q+ODU/IiNlZjQ0NDQiOnBjdD42NT8iI2Y5NzMxNiI6IiMyMmM1NWUiOwogICAgICBjb25zdCBleHBNcyA9IHUgPyB1LmV4cCA6IDA7CiAgICAgIGNvbnN0IGV4cFN0ciA9ICghZXhwTXN8fGV4cE1zPT09MCk/IuC5hOC4oeC5iOC4iOC4s+C4geC4seC4lCI6bmV3IERhdGUoZXhwTXMpLnRvTG9jYWxlRGF0ZVN0cmluZygidGgtVEgiLHt5ZWFyOiJudW1lcmljIixtb250aDoic2hvcnQiLGRheToibnVtZXJpYyJ9KTsKICAgICAgY29uc3QgZExlZnQgPSAoIWV4cE1zfHxleHBNcz09PTApP251bGw6TWF0aC5jZWlsKChleHBNcy1EYXRlLm5vdygpKS84NjQwMDAwMCk7CiAgICAgIGNvbnN0IGRUYWcgPSBkTGVmdD09PW51bGw/IuKIniI6ZExlZnQ+MD9kTGVmdCsiZCI6IuC4q+C4oeC4lOC5geC4peC5ieC4pyI7CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iIHN0eWxlPSJmbGV4LWRpcmVjdGlvbjpjb2x1bW47Z2FwOjhweDtwYWRkaW5nOjE0cHggMTZweCI+CiAgICAgICAgPGRpdiBzdHlsZT0iZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtnYXA6MTBweCI+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJwb3NpdGlvbjpyZWxhdGl2ZTt3aWR0aDoyMHB4O2hlaWdodDoyMHB4O2ZsZXgtc2hyaW5rOjAiPjxzcGFuIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDowO2JvcmRlci1yYWRpdXM6NTAlO2JhY2tncm91bmQ6IzIyYzU1ZTtvcGFjaXR5Oi40O2FuaW1hdGlvbjpwaW5nIDEuMnMgY3ViaWMtYmV6aWVyKDAsMCwuMiwxKSBpbmZpbml0ZSI+PC9zcGFuPjxzcGFuIHN0eWxlPSJwb3NpdGlvbjphYnNvbHV0ZTtpbnNldDozcHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojMjJjNTVlIj48L3NwYW4+PC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPjxkaXYgY2xhc3M9InVuIj4ke2VtYWlsfTwvZGl2PjxkaXYgY2xhc3M9InVtIj4ke3U/IlBvcnQgIit1LnBvcnQ6IlZMRVNTIn0gwrcg4Lit4Lit4LiZ4LmE4Lil4LiZ4LmM4Lit4Lii4Li54LmIPC9kaXY+PC9kaXY+CiAgICAgICAgICA8c3BhbiBjbGFzcz0iYWJkZyBvayI+T05MSU5FPC9zcGFuPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgc3R5bGU9ImJhY2tncm91bmQ6cmdiYSgwLDAsMCwuMDUpO2JvcmRlci1yYWRpdXM6MTBweDtwYWRkaW5nOjEwcHggMTJweCI+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Zm9udC1zaXplOjExcHg7Y29sb3I6IzY2NjttYXJnaW4tYm90dG9tOjVweCI+CiAgICAgICAgICAgIDxzcGFuPvCfk4ogJHt1c2VkR0J9IEdCICR7dG90YWxHQj8iLyAiK3RvdGFsR0IrIiBHQiI6Ii8g4LmE4Lih4LmI4LiI4Liz4LiB4Lix4LiUIn08L3NwYW4+CiAgICAgICAgICAgIDxzcGFuIHN0eWxlPSJjb2xvcjoke2Jhcn07Zm9udC13ZWlnaHQ6NjAwIj4ke3RvdGFsR0I/cGN0KyIlIjoiIn08L3NwYW4+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDxkaXYgc3R5bGU9ImhlaWdodDo2cHg7YmFja2dyb3VuZDpyZ2JhKDAsMCwwLC4xKTtib3JkZXItcmFkaXVzOjk5cHg7b3ZlcmZsb3c6aGlkZGVuIj4KICAgICAgICAgICAgPGRpdiBzdHlsZT0iaGVpZ2h0OjEwMCU7d2lkdGg6JHt0b3RhbEdCP3BjdDoxMDB9JTtiYWNrZ3JvdW5kOiR7YmFyfTtib3JkZXItcmFkaXVzOjk5cHgiPjwvZGl2PgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8ZGl2IHN0eWxlPSJkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47Zm9udC1zaXplOjExcHg7Y29sb3I6Izg4ODttYXJnaW4tdG9wOjZweCI+CiAgICAgICAgICAgIDxzcGFuPvCfk4UgJHtleHBTdHJ9PC9zcGFuPgogICAgICAgICAgICA8c3BhbiBzdHlsZT0iYmFja2dyb3VuZDpyZ2JhKDM0LDE5Nyw5NCwuMTIpO2NvbG9yOiMxNmEzNGE7cGFkZGluZzoxcHggOHB4O2JvcmRlci1yYWRpdXM6OTlweCI+JHtkVGFnfTwvc3Bhbj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICA8L2Rpdj5gOwogICAgfSkuam9pbignJyk7CiAgfSBjYXRjaChlKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnb25saW5lLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciIHN0eWxlPSJjb2xvcjojZWY0NDQ0Ij4nK2UubWVzc2FnZSsnPC9kaXY+JzsKICB9Cn0KCi8vIOKVkOKVkOKVkOKVkCBTU0ggVVNFUlMgKGJhbiB0YWIpIOKVkOKVkOKVkOKVkAphc3luYyBmdW5jdGlvbiBsb2FkU1NIVXNlcnMoKSB7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9ImxvYWRpbmciPuC4geC4s+C4peC4seC4h+C5guC4q+C4peC4lC4uLjwvZGl2Pic7CiAgdHJ5IHsKICAgIGNvbnN0IGQgPSBhd2FpdCBmZXRjaChBUEkrJy91c2VycycpLnRoZW4ocj0+ci5qc29uKCkpOwogICAgY29uc3QgdXNlcnMgPSBkLnVzZXJzIHx8IFtdOwogICAgaWYgKCF1c2Vycy5sZW5ndGgpIHsgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NzaC11c2VyLWxpc3QnKS5pbm5lckhUTUw9JzxkaXYgY2xhc3M9Im9lIj48ZGl2IGNsYXNzPSJlaSI+8J+TrTwvZGl2PjxwPuC5hOC4oeC5iOC4oeC4tSBTU0ggdXNlcnM8L3A+PC9kaXY+JzsgcmV0dXJuOyB9CiAgICBjb25zdCBub3cgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkuc2xpY2UoMCwxMCk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3NoLXVzZXItbGlzdCcpLmlubmVySFRNTCA9IHVzZXJzLm1hcCh1PT57CiAgICAgIGNvbnN0IGV4cCA9IHUuZXhwIHx8ICfguYTguKHguYjguIjguLPguIHguLHguJQnOwogICAgICBjb25zdCBhY3RpdmUgPSB1LmFjdGl2ZSAhPT0gZmFsc2U7CiAgICAgIHJldHVybiBgPGRpdiBjbGFzcz0idWl0ZW0iPgogICAgICAgIDxkaXYgY2xhc3M9InVhdiAke2FjdGl2ZT8nYXYtZyc6J2F2LXgnfSI+JHt1LnVzZXJbMF0udG9VcHBlckNhc2UoKX08L2Rpdj4KICAgICAgICA8ZGl2IHN0eWxlPSJmbGV4OjEiPgogICAgICAgICAgPGRpdiBjbGFzcz0idW4iPiR7dS51c2VyfTwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzcz0idW0iPuC4q+C4oeC4lOC4reC4suC4ouC4uDogJHtleHB9PC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgICAgPHNwYW4gY2xhc3M9ImFiZGcgJHthY3RpdmU/J29rJzonZXhwJ30iPiR7YWN0aXZlPydBY3RpdmUnOidFeHBpcmVkJ308L3NwYW4+CiAgICAgIDwvZGl2PmA7CiAgICB9KS5qb2luKCcnKTsKICB9IGNhdGNoKGUpIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzc2gtdXNlci1saXN0JykuaW5uZXJIVE1MPSc8ZGl2IGNsYXNzPSJsb2FkaW5nIiBzdHlsZT0iY29sb3I6I2VmNDQ0NCI+JytlLm1lc3NhZ2UrJzwvZGl2Pic7CiAgfQp9CmFzeW5jIGZ1bmN0aW9uIGRlbGV0ZVNTSCgpIHsKICBjb25zdCB1c2VyID0gZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2Jhbi11c2VyJykudmFsdWUudHJpbSgpOwogIGlmICghdXNlcikgcmV0dXJuIHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4LiB4Lij4Li44LiT4Liy4LmD4Liq4LmIIFVzZXJuYW1lJywnZXJyJyk7CiAgaWYgKCFjb25maXJtKCfguKXguJogU1NIIHVzZXIgIicrdXNlcisnIiA/JykpIHJldHVybjsKICB0cnkgewogICAgY29uc3QgZCA9IGF3YWl0IGZldGNoKEFQSSsnL2RlbGV0ZV9zc2gnLHttZXRob2Q6J1BPU1QnLGhlYWRlcnM6eydDb250ZW50LVR5cGUnOidhcHBsaWNhdGlvbi9qc29uJ30sYm9keTpKU09OLnN0cmluZ2lmeSh7dXNlcn0pfSkudGhlbihyPT5yLmpzb24oKSk7CiAgICBpZiAoIWQub2spIHRocm93IG5ldyBFcnJvcihkLmVycm9yfHwn4Lil4Lia4LmE4Lih4LmI4Liq4Liz4LmA4Lij4LmH4LiIJyk7CiAgICBzaG93QWxlcnQoJ2Jhbi1hbGVydCcsJ+KchSDguKXguJogJyt1c2VyKycg4Liq4Liz4LmA4Lij4LmH4LiIJywnb2snKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdiYW4tdXNlcicpLnZhbHVlPScnOwogICAgbG9hZFNTSFVzZXJzKCk7CiAgfSBjYXRjaChlKSB7IHNob3dBbGVydCgnYmFuLWFsZXJ0Jywn4p2MICcrZS5tZXNzYWdlLCdlcnInKTsgfQp9CgovLyDilZDilZDilZDilZAgQ09QWSDilZDilZDilZDilZAKZnVuY3Rpb24gY29weUxpbmsoaWQsIGJ0bikgewogIGNvbnN0IHR4dCA9IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKGlkKS50ZXh0Q29udGVudDsKICBuYXZpZ2F0b3IuY2xpcGJvYXJkLndyaXRlVGV4dCh0eHQpLnRoZW4oKCk9PnsKICAgIGNvbnN0IG9yaWcgPSBidG4udGV4dENvbnRlbnQ7CiAgICBidG4udGV4dENvbnRlbnQ9J+KchSBDb3BpZWQhJzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9J3JnYmEoMzQsMTk3LDk0LC4xNSknOwogICAgc2V0VGltZW91dCgoKT0+eyBidG4udGV4dENvbnRlbnQ9b3JpZzsgYnRuLnN0eWxlLmJhY2tncm91bmQ9Jyc7IH0sIDIwMDApOwogIH0pLmNhdGNoKCgpPT57IHByb21wdCgnQ29weSBsaW5rOicsIHR4dCk7IH0pOwp9CgovLyDilZDilZDilZDilZAgTE9HT1VUIOKVkOKVkOKVkOKVkApmdW5jdGlvbiBkb0xvZ291dCgpIHsKICBzZXNzaW9uU3RvcmFnZS5yZW1vdmVJdGVtKFNFU1NJT05fS0VZKTsKICBsb2NhdGlvbi5yZXBsYWNlKCdpbmRleC5odG1sJyk7Cn0KCi8vIOKVkOKVkOKVkOKVkCBJTklUIOKVkOKVkOKVkOKVkAoKLy8g4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQ4pWQCi8vICBTUEVFRCBURVNUCi8vIOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkOKVkApsZXQgX3NwZWVkUnVubmluZz1mYWxzZTsKZnVuY3Rpb24gc2V0R2F1Z2UobWJwcywgbWF4TWJwcz0yMDApIHsKICBjb25zdCBlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZ2F1Z2UtZmlsbCcpOwogIGNvbnN0IHZhbEVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdnYXVnZS12YWwnKTsKICBjb25zdCB1bml0RWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2dhdWdlLXVuaXQnKTsKICBpZiAoIWVsKSByZXR1cm47CiAgY29uc3QgcGN0PU1hdGgubWluKG1icHMvbWF4TWJwcywxKTsKICBlbC5zdHlsZS5zdHJva2VEYXNob2Zmc2V0PSgyMjAtKDIyMCpwY3QpKS50b0ZpeGVkKDIpOwogIGNvbnN0IHI9TWF0aC5yb3VuZChwY3Q8MC41PzA6MjU1KihwY3QtMC41KSoyKTsKICBjb25zdCBnPU1hdGgucm91bmQocGN0PDAuNT8yNTU6MjU1KigxLShwY3QtMC41KSoyKSk7CiAgZWwuc2V0QXR0cmlidXRlKCdzdHJva2UnLGByZ2IoJHtyfSwke2d9LDUwKWApOwogIHZhbEVsLnRleHRDb250ZW50PW1icHM+PTE/bWJwcy50b0ZpeGVkKDEpOihtYnBzKjEwMDApLnRvRml4ZWQoMCk7CiAgdW5pdEVsLnRleHRDb250ZW50PW1icHM+PTE/J01icHMnOidLYnBzJzsKfQpmdW5jdGlvbiBzZXRQcm9ncmVzcyhwY3QpIHsKICBjb25zdCBlbD1kb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtcHJvZy1maWxsJyk7CiAgaWYgKGVsKSBlbC5zdHlsZS53aWR0aD1NYXRoLm1pbihwY3QsMTAwKSsnJSc7Cn0KYXN5bmMgZnVuY3Rpb24gbWVhc3VyZVBpbmcoKSB7CiAgY29uc3QgcGluZ3M9W107CiAgZm9yIChsZXQgaT0wO2k8NTtpKyspIHsKICAgIGNvbnN0IHQwPXBlcmZvcm1hbmNlLm5vdygpOwogICAgdHJ5e2F3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycse21ldGhvZDonSEVBRCcsY2FjaGU6J25vLXN0b3JlJ30pO30KICAgIGNhdGNoKGUpe3RyeXthd2FpdCBmZXRjaCgnLycse21ldGhvZDonSEVBRCcsY2FjaGU6J25vLXN0b3JlJ30pO31jYXRjaChlZSl7fX0KICAgIHBpbmdzLnB1c2gocGVyZm9ybWFuY2Uubm93KCktdDApOwogICAgYXdhaXQgbmV3IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkpOwogIH0KICBwaW5ncy5zb3J0KChhLGIpPT5hLWIpOwogIGNvbnN0IHBpbmc9cGluZ3NbTWF0aC5mbG9vcihwaW5ncy5sZW5ndGgvMildOwogIGNvbnN0IGppdHRlcj1waW5nc1twaW5ncy5sZW5ndGgtMV0tcGluZ3NbMF07CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BpbmctdmFsJykudGV4dENvbnRlbnQ9cGluZy50b0ZpeGVkKDApKycgbXMnOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdqaXR0ZXItdmFsJykudGV4dENvbnRlbnQ9aml0dGVyLnRvRml4ZWQoMCkrJyBtcyc7CiAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2xvc3MtdmFsJykudGV4dENvbnRlbnQ9JzAlJzsKICBjb25zdCBwaW5nRWw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3BpbmctdmFsJyk7CiAgcGluZ0VsLmNsYXNzTmFtZT0nc3BlZWQtcGluZy12YWwnKyhwaW5nPDgwPycnOnBpbmc8MjAwPycgd2Fybic6JyBiYWQnKTsKICByZXR1cm4ge3Bpbmcsaml0dGVyfTsKfQphc3luYyBmdW5jdGlvbiBzdGFydFNwZWVkVGVzdCh0eXBlKSB7CiAgaWYgKF9zcGVlZFJ1bm5pbmcpIHJldHVybjsKICBfc3BlZWRSdW5uaW5nPXRydWU7CiAgY29uc3QgYnRuRGw9ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2J0bi1kbCcpOwogIGNvbnN0IGJ0blVsPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdidG4tdWwnKTsKICBidG5EbC5kaXNhYmxlZD10cnVlOyBidG5VbC5kaXNhYmxlZD10cnVlOwogIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4LiB4Liz4Lil4Lix4LiH4Lin4Lix4LiUIFBpbmcuLi4nOwogIHNldFByb2dyZXNzKDApOyBzZXRHYXVnZSgwKTsKICB0cnl7CiAgICBjb25zdCBpbmZvPWF3YWl0IGZldGNoKEFQSSsnL3N0YXR1cycpLnRoZW4ocj0+ci5qc29uKCkpLmNhdGNoKCgpPT5udWxsKTsKICAgIGlmKGluZm8mJmluZm8uaG9zdCkgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Zwcy1pcCcpLnRleHRDb250ZW50PWluZm8uaG9zdDsKICAgIGVsc2UgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3Zwcy1pcCcpLnRleHRDb250ZW50PWxvY2F0aW9uLmhvc3RuYW1lOwogIH1jYXRjaChlKXt9CiAgdHJ5e2F3YWl0IG1lYXN1cmVQaW5nKCk7fWNhdGNoKGUpe30KICBzZXRQcm9ncmVzcygxMCk7CiAgaWYgKHR5cGU9PT0nZG93bmxvYWQnKSB7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnc3BlZWQtc3RhdHVzJykudGV4dENvbnRlbnQ9J+C4geC4s+C4peC4seC4h+C4l+C4lOC4quC4reC4miBEb3dubG9hZC4uLic7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtdmFsJykudGV4dENvbnRlbnQ9Jy4uLic7CiAgICBjb25zdCBtYnBzPWF3YWl0IHJ1bkRvd25sb2FkVGVzdCgocCxjdXIpPT57CiAgICAgIHNldFByb2dyZXNzKDEwK3AqMC44KTsgc2V0R2F1Z2UoY3VyKTsKICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKGN1ci8yMDAqMTAwLDEwMCkrJyUnOwogICAgfSk7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgnZGwtdmFsJykudGV4dENvbnRlbnQ9bWJwcy50b0ZpeGVkKDEpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ2RsLWJhcicpLnN0eWxlLndpZHRoPU1hdGgubWluKG1icHMvMjAwKjEwMCwxMDApKyclJzsKICAgIHNldEdhdWdlKG1icHMpOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3NwZWVkLXN0YXR1cycpLnRleHRDb250ZW50PSfinIUgRG93bmxvYWQ6ICcrbWJwcy50b0ZpeGVkKDEpKycgTWJwcyc7CiAgfSBlbHNlIHsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4LiB4Liz4Lil4Lix4LiH4LiX4LiU4Liq4Lit4LiaIFVwbG9hZC4uLic7CiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZCgndWwtdmFsJykudGV4dENvbnRlbnQ9Jy4uLic7CiAgICBjb25zdCBtYnBzPWF3YWl0IHJ1blVwbG9hZFRlc3QoKHAsY3VyKT0+ewogICAgICBzZXRQcm9ncmVzcygxMCtwKjAuOCk7IHNldEdhdWdlKGN1cik7CiAgICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC1iYXInKS5zdHlsZS53aWR0aD1NYXRoLm1pbihjdXIvMjAwKjEwMCwxMDApKyclJzsKICAgIH0pOwogICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoJ3VsLXZhbCcpLnRleHRDb250ZW50PW1icHMudG9GaXhlZCgxKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCd1bC1iYXInKS5zdHlsZS53aWR0aD1NYXRoLm1pbihtYnBzLzIwMCoxMDAsMTAwKSsnJSc7CiAgICBzZXRHYXVnZShtYnBzKTsKICAgIGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdzcGVlZC1zdGF0dXMnKS50ZXh0Q29udGVudD0n4pyFIFVwbG9hZDogJyttYnBzLnRvRml4ZWQoMSkrJyBNYnBzJzsKICB9CiAgc2V0UHJvZ3Jlc3MoMTAwKTsKICBzZXRUaW1lb3V0KCgpPT5zZXRQcm9ncmVzcygwKSwxNTAwKTsKICBidG5EbC5kaXNhYmxlZD1mYWxzZTsgYnRuVWwuZGlzYWJsZWQ9ZmFsc2U7CiAgX3NwZWVkUnVubmluZz1mYWxzZTsKfQphc3luYyBmdW5jdGlvbiBydW5Eb3dubG9hZFRlc3Qob25Qcm9ncmVzcykgewogIGNvbnN0IERVUkFUSU9OX01TPTgwMDA7CiAgbGV0IHRvdGFsQnl0ZXM9MDsKICBjb25zdCB0MD1wZXJmb3JtYW5jZS5ub3coKTsKICBsZXQgZG9uZT1mYWxzZTsKICBzZXRUaW1lb3V0KCgpPT57ZG9uZT10cnVlO30sRFVSQVRJT05fTVMpOwogIGNvbnN0IENIVU5LPTEqMTAyNCoxMDI0OwogIGNvbnN0IHJ1bj1hc3luYygpPT57CiAgICB3aGlsZSghZG9uZSl7CiAgICAgIHRyeXsKICAgICAgICBjb25zdCB1cmw9J2h0dHBzOi8vc3BlZWQuY2xvdWRmbGFyZS5jb20vX19kb3duP2J5dGVzPScrQ0hVTks7CiAgICAgICAgY29uc3Qgcj1hd2FpdCBmZXRjaCh1cmwse2NhY2hlOiduby1zdG9yZSd9KS5jYXRjaChhc3luYygpPT5mZXRjaChBUEkrJy9zdGF0dXMnLHtjYWNoZTonbm8tc3RvcmUnfSkpOwogICAgICAgIGNvbnN0IGJ1Zj1hd2FpdCByLmFycmF5QnVmZmVyKCk7CiAgICAgICAgaWYoZG9uZSkgYnJlYWs7CiAgICAgICAgdG90YWxCeXRlcys9YnVmLmJ5dGVMZW5ndGg7CiAgICAgICAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgICAgICAgY29uc3QgbWJwcz0odG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwogICAgICAgIG9uUHJvZ3Jlc3MoTWF0aC5taW4oZWxhcHNlZC9EVVJBVElPTl9NUyoxMDAsOTkpLG1icHMpOwogICAgICB9Y2F0Y2goZSl7YXdhaXQgbmV3IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkpO30KICAgIH0KICB9OwogIGF3YWl0IFByb21pc2UuYWxsKFtydW4oKSxydW4oKSxydW4oKSxydW4oKV0pOwogIGNvbnN0IGVsYXBzZWQ9KHBlcmZvcm1hbmNlLm5vdygpLXQwKS8xMDAwOwogIHJldHVybiAodG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwp9CmFzeW5jIGZ1bmN0aW9uIHJ1blVwbG9hZFRlc3Qob25Qcm9ncmVzcykgewogIGNvbnN0IERVUkFUSU9OX01TPTgwMDA7CiAgbGV0IHRvdGFsQnl0ZXM9MDsKICBjb25zdCB0MD1wZXJmb3JtYW5jZS5ub3coKTsKICBsZXQgZG9uZT1mYWxzZTsKICBzZXRUaW1lb3V0KCgpPT57ZG9uZT10cnVlO30sRFVSQVRJT05fTVMpOwogIGNvbnN0IENIVU5LPTUxMioxMDI0OwogIGNvbnN0IGRhdGE9bmV3IFVpbnQ4QXJyYXkoQ0hVTkspOwogIGNyeXB0by5nZXRSYW5kb21WYWx1ZXMoZGF0YSk7CiAgY29uc3QgYmxvYj1uZXcgQmxvYihbZGF0YV0pOwogIGNvbnN0IHJ1bj1hc3luYygpPT57CiAgICB3aGlsZSghZG9uZSl7CiAgICAgIHRyeXsKICAgICAgICBhd2FpdCBmZXRjaCgnaHR0cHM6Ly9zcGVlZC5jbG91ZGZsYXJlLmNvbS9fX3VwJyx7bWV0aG9kOidQT1NUJyxib2R5OmJsb2J9KS5jYXRjaCgoKT0+CiAgICAgICAgICBmZXRjaChBUEkrJy9zdGF0dXMnLHttZXRob2Q6J1BPU1QnLGJvZHk6YmxvYixoZWFkZXJzOnsnQ29udGVudC1UeXBlJzonYXBwbGljYXRpb24vb2N0ZXQtc3RyZWFtJ319KS5jYXRjaCgoKT0+KHtvazpmYWxzZX0pKQogICAgICAgICk7CiAgICAgICAgaWYoZG9uZSkgYnJlYWs7CiAgICAgICAgdG90YWxCeXRlcys9Q0hVTks7CiAgICAgICAgY29uc3QgZWxhcHNlZD0ocGVyZm9ybWFuY2Uubm93KCktdDApLzEwMDA7CiAgICAgICAgY29uc3QgbWJwcz0odG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwogICAgICAgIG9uUHJvZ3Jlc3MoTWF0aC5taW4oZWxhcHNlZC9EVVJBVElPTl9NUyoxMDAsOTkpLG1icHMpOwogICAgICB9Y2F0Y2goZSl7YXdhaXQgbmV3IFByb21pc2Uocj0+c2V0VGltZW91dChyLDEwMCkpO30KICAgIH0KICB9OwogIGF3YWl0IFByb21pc2UuYWxsKFtydW4oKSxydW4oKSxydW4oKV0pOwogIGNvbnN0IGVsYXBzZWQ9KHBlcmZvcm1hbmNlLm5vdygpLXQwKS8xMDAwOwogIHJldHVybiAodG90YWxCeXRlcyo4KS8oZWxhcHNlZCoxZTYpOwp9CgovLyBzdygpIOC5gOC4nuC4tOC5iOC4oSBzcGVlZCB0YWIgc3VwcG9ydAoKbG9hZERhc2goKTsKbG9hZFNlcnZpY2VzKCk7CnNldEludGVydmFsKGxvYWREYXNoLCAzMDAwMCk7Cjwvc2NyaXB0PgoKPCEtLSBTU0ggUkVORVcgTU9EQUwgLS0+CjxkaXYgY2xhc3M9Im1vdmVyIiBpZD0ic3NoLXJlbmV3LW1vZGFsIiBvbmNsaWNrPSJpZihldmVudC50YXJnZXQ9PT10aGlzKWNsb3NlU1NIUmVuZXdNb2RhbCgpIj4KICA8ZGl2IGNsYXNzPSJtb2RhbCI+CiAgICA8ZGl2IGNsYXNzPSJtaGRyIj4KICAgICAgPGRpdiBjbGFzcz0ibXRpdGxlIj7wn5SEIOC4leC5iOC4reC4reC4suC4ouC4uCBTU0ggVXNlcjwvZGl2PgogICAgICA8YnV0dG9uIGNsYXNzPSJtY2xvc2UiIG9uY2xpY2s9ImNsb3NlU1NIUmVuZXdNb2RhbCgpIj7inJU8L2J1dHRvbj4KICAgIDwvZGl2PgogICAgPGRpdiBjbGFzcz0iZGdyaWQiPgogICAgICA8ZGl2IGNsYXNzPSJkciI+PHNwYW4gY2xhc3M9ImRrIj7wn5GkIFVzZXJuYW1lPC9zcGFuPjxzcGFuIGNsYXNzPSJkdiBncmVlbiIgaWQ9InNzaC1yZW5ldy11c2VybmFtZSI+LS08L3NwYW4+PC9kaXY+CiAgICA8L2Rpdj4KICAgIDxkaXYgY2xhc3M9ImZnIiBzdHlsZT0ibWFyZ2luLXRvcDoxNHB4Ij4KICAgICAgPGRpdiBjbGFzcz0iZmxibCI+4LiI4Liz4LiZ4Lin4LiZ4Lin4Lix4LiZ4LiX4Li14LmI4LiV4LmJ4Lit4LiH4LiB4Liy4Lij4LiV4LmI4Lit4Lit4Liy4Lii4Li4PC9kaXY+CiAgICAgIDxpbnB1dCBjbGFzcz0iZmkiIGlkPSJzc2gtcmVuZXctZGF5cyIgdHlwZT0ibnVtYmVyIiB2YWx1ZT0iMzAiIG1pbj0iMSIgcGxhY2Vob2xkZXI9IjMwIj4KICAgIDwvZGl2PgogICAgPGJ1dHRvbiBjbGFzcz0iY2J0biIgaWQ9InNzaC1yZW5ldy1idG4iIG9uY2xpY2s9ImRvU1NIUmVuZXcoKSI+4pyFIOC4ouC4t+C4meC4ouC4seC4meC4leC5iOC4reC4reC4suC4ouC4uDwvYnV0dG9uPgogIDwvZGl2Pgo8L2Rpdj4KCgo8c2NyaXB0PgovLyBGaXJlZmxpZXMgeDYwIOKAkyBpbnNpZGUgY2FyZHMgKGFic29sdXRlLCDguYTguKHguYjguYPguIrguYggZml4ZWQpCjwvYm9keT4KPC9odG1sPgo=
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
# รอให้ dropbear ขึ้นจริงสูงสุด 15 วินาที แทนที่จะรอ 2 วินาทีตายตัว (กัน false-negative)
for _i in $(seq 1 5); do
  systemctl is-active --quiet dropbear && break
  sleep 3
done

for svc in nginx haproxy x-ui dropbear chaiya-npxproxy chaiya-ssh-api chaiya-badvpn zivpn; do
  if systemctl is-active --quiet "$svc"; then
    ok "$svc ✅"
  else
    warn "$svc ⚠️"
    journalctl -u "$svc" -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
    systemctl status "$svc" --no-pager -l 2>/dev/null | sed -n '1,8p' | sed 's/^/    /' || true
  fi
done

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   CHAIYA VPN PANEL v9 - ติดตั้งสำเร็จ! 🚀  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
if [[ $USE_PANEL_SSL -eq 1 ]]; then
  echo -e "  🌐 Dashboard   : ${CYAN}${BOLD}https://${PANEL_DOMAIN}${NC} ${GREEN}(ไม่โชว์พอร์ต)${NC}"
  echo -e "              สำรอง: https://${DOMAIN}:${DASHBOARD_PORT}"
  echo -e "  🔒 SSL         : ${GREEN}✅ HTTPS พร้อม${NC}"
elif [[ $USE_SSL -eq 1 ]]; then
  echo -e "  🌐 Dashboard   : ${CYAN}${BOLD}https://${DOMAIN}:${DASHBOARD_PORT}${NC}"
  echo -e "              ${YELLOW}(ยังเข้าแบบไม่โชว์พอร์ตไม่ได้ — เพิ่ม DNS A record ${PANEL_DOMAIN} ชี้มา IP นี้ แล้วรันสคริปต์ใหม่)${NC}"
  echo -e "  🔒 SSL         : ${GREEN}✅ HTTPS พร้อม${NC}"
else
  echo -e "  🌐 Dashboard   : ${YELLOW}http://${DOMAIN}:${DASHBOARD_PORT} (ยังไม่มี SSL)${NC}"
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
echo ""
echo -e "${CYAN}${BOLD}  ── โครงสร้างระบบทั้งหมด ──────────────────────${NC}"
echo -e "  🐻 Dropbear       : ${CYAN}port 143, 109${NC}"
echo -e "  🎮 BadVPN UDPGW   : ${CYAN}port 7300 (127.0.0.1)${NC}"
echo -e "  📡 SSH-WS         : ${CYAN}HAProxy:80 → Nginx:${NGINX_L7_PORT} → npxproxy:${NPXPROXY_PORT} → Dropbear:143${NC}"
echo -e "  📡 VLESS-WS       : ${CYAN}HAProxy:80 → Nginx:${NGINX_L7_PORT} → Xray:${XRAY_VLESS_WS_PORT} (path /vless)${NC}"
if [[ $USE_SSL -eq 1 ]]; then
  echo -e "  🔒 SSH-TLS        : ${CYAN}HAProxy:443 → Xray:${XRAY_VLESS_TLS_PORT} → fallback → SSH:22${NC}"
  echo -e "  🔒 VLESS-TCP-TLS  : ${CYAN}HAProxy:443 → Xray:${XRAY_VLESS_TLS_PORT}${NC}"
else
  echo -e "  🔒 Port 443       : ${YELLOW}ยังไม่มี SSL — VLESS-TLS/SSH-TLS ยังไม่พร้อม${NC}"
fi
echo -e "  🌀 ZiVPN (UDP)    : ${CYAN}port ${ZIVPN_PORT}${NC} (password = 3x-ui password)"
if systemctl is-active --quiet chaiya-udp-custom 2>/dev/null; then
  echo -e "  🌐 UDP Custom     : ${GREEN}port ${UDPCUSTOM_PORT} — ทำงานอยู่${NC}"
else
  echo -e "  🌐 UDP Custom     : ${YELLOW}port ${UDPCUSTOM_PORT} — service/DNAT พร้อมแล้ว แต่ยังไม่มี binary${NC}"
  echo -e "                  ${YELLOW}นำ binary ที่ไว้ใจไปวางที่ /usr/local/bin/udp-custom แล้วรัน:${NC}"
  echo -e "                  ${CYAN}systemctl enable --now chaiya-udp-custom${NC}"
fi
echo -e "  🔀 UDP DNAT       : ${CYAN}6000-6499,6501-19999/udp → ${ZIVPN_PORT} | catch-all/udp → ${UDPCUSTOM_PORT}${NC}"
echo ""
echo -e "  💡 พิมพ์ ${CYAN}menu${NC} เพื่อดูรายละเอียด"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════${NC}"
