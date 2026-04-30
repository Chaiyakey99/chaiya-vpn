#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL - INSTALLER
#   Usage: bash install.sh
#   Repo : https://github.com/YOUR_USERNAME/chaiya-panel
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

# ── CONFIG — แก้ตรงนี้ก่อน push ขึ้น GitHub ──────────────
GITHUB_USER="Chaiyakey99"
GITHUB_REPO="chaiya-vpn"
GITHUB_BRANCH="main"
RAW="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
# ─────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
dl()   { curl -fsSL "$1" -o "$2" || err "ดาวน์โหลดล้มเหลว: $1"; }

echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
  ██████╗██╗  ██╗ █████╗ ██╗██╗   ██╗ █████╗
 ██╔════╝██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══██╗
 ██║     ███████║███████║██║ ╚████╔╝ ███████║
 ╚██████╗██║  ██║██║  ██║██║   ██║   ██║  ██║
  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝
         CHAIYA VPN PANEL INSTALLER
BANNER
echo -e "${NC}"

[[ $EUID -ne 0 ]] && err "รันด้วย root เท่านั้น"

# ── INPUT ──────────────────────────────────────────────────
read -rp "$(echo -e "${CYAN}")โดเมน (เช่น panel.example.com): $(echo -e "${NC}")" DOMAIN
read -rp "$(echo -e "${CYAN}")XUI Username [admin]: $(echo -e "${NC}")" XUI_USER
read -rp "$(echo -e "${CYAN}")XUI Password [admin]: $(echo -e "${NC}")" XUI_PASS
read -rsp "$(echo -e "${CYAN}")Dashboard Password: $(echo -e "${NC}")" DASH_PASS
echo ""

[[ -z "$DOMAIN" ]]    && err "ต้องระบุโดเมน"
[[ -z "$XUI_USER" ]]  && XUI_USER="admin"
[[ -z "$XUI_PASS" ]]  && XUI_PASS="admin"
[[ -z "$DASH_PASS" ]] && DASH_PASS="admin"

REAL_XUI_PORT=54321
XUI_DB=/etc/x-ui/x-ui.db

# ── INSTALL DEPS ───────────────────────────────────────────
info "ติดตั้ง dependencies..."
apt-get update -qq
apt-get install -y -qq \
    nginx certbot python3 python3-pip \
    dropbear curl wget sqlite3 \
    || err "ติดตั้ง deps ไม่สำเร็จ"
pip3 install bcrypt --break-system-packages -q 2>/dev/null || \
    pip3 install bcrypt -q 2>/dev/null || true
ok "Dependencies พร้อม"

# ── BADVPN BINARY ──────────────────────────────────────────
# Ubuntu 22/24 ไม่มี badvpn ใน apt — โหลด binary โดยตรง
info "ติดตั้ง BadVPN..."
if [[ ! -x /usr/bin/badvpn-udpgw ]]; then
    wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
        "https://raw.githubusercontent.com/NevermoreSSH/Blueblue/main/newudpgw" 2>/dev/null && \
        chmod +x /usr/bin/badvpn-udpgw || rm -f /usr/bin/badvpn-udpgw
    if [[ ! -f /usr/bin/badvpn-udpgw ]]; then
        wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
            "https://raw.githubusercontent.com/bagaswastu/badvpn/master/udpgw/badvpn-udpgw" 2>/dev/null && \
            chmod +x /usr/bin/badvpn-udpgw || true
    fi
fi
[[ -x /usr/bin/badvpn-udpgw ]] && ok "BadVPN binary พร้อม" || warn "BadVPN ข้ามไป (ไม่มี binary)"

# ── INSTALL X-UI ───────────────────────────────────────────
info "ติดตั้ง x-ui..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<< $'\n'
sleep 3

info "ตั้งค่า x-ui..."
for i in {1..10}; do [[ -f "$XUI_DB" ]] && break; sleep 2; done

PW_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw('${XUI_PASS}'.encode(), bcrypt.gensalt()).decode())")
sqlite3 "$XUI_DB" "UPDATE users SET username='${XUI_USER}', password='${PW_HASH}' WHERE id=1;" 2>/dev/null || true
sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings(key,value) VALUES('webPort','${REAL_XUI_PORT}'),('webBasePath','/');" 2>/dev/null || true
systemctl restart x-ui
ok "x-ui พร้อม"

# ── DROPBEAR ───────────────────────────────────────────────
info "ตั้งค่า Dropbear..."
_DB_BIN=""
for _p in /usr/sbin/dropbear /usr/bin/dropbear; do
    [[ -x "$_p" ]] && _DB_BIN="$_p" && break
done

if [[ -z "$_DB_BIN" ]]; then
    warn "ไม่พบ dropbear binary"
else
    mkdir -p /etc/dropbear
    [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]   && dropbearkey -t rsa   -f /etc/dropbear/dropbear_rsa_host_key -s 2048 2>/dev/null || true
    [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]] && dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key 2>/dev/null || true

    for PORT in 143 109; do
cat > /etc/systemd/system/dropbear-${PORT}.service << EOF
[Unit]
Description=Dropbear SSH port ${PORT}
After=network.target
[Service]
ExecStart=$_DB_BIN -F -p ${PORT} -r /etc/dropbear/dropbear_rsa_host_key -r /etc/dropbear/dropbear_ecdsa_host_key
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    done

    systemctl daemon-reload
    systemctl enable --now dropbear-143 dropbear-109
    ok "Dropbear พร้อม (port 143, 109)"
fi

# ── BADVPN SERVICE ─────────────────────────────────────────
if [[ -x /usr/bin/badvpn-udpgw ]]; then
    info "เปิด BadVPN service..."
    dl "${RAW}/services/chaiya-badvpn.service" /etc/systemd/system/chaiya-badvpn.service
    systemctl daemon-reload
    systemctl enable --now chaiya-badvpn
    ok "BadVPN พร้อม (port 7300)"
fi

# ── WS-STUNNEL ─────────────────────────────────────────────
info "ติดตั้ง WS-Stunnel..."
dl "${RAW}/bin/ws-stunnel" /usr/local/bin/ws-stunnel
chmod +x /usr/local/bin/ws-stunnel

dl "${RAW}/services/chaiya-sshws.service" /etc/systemd/system/chaiya-sshws.service
systemctl daemon-reload
systemctl enable --now chaiya-sshws
ok "WS-Stunnel พร้อม"

# ── SSH API ────────────────────────────────────────────────
info "ติดตั้ง SSH API..."
mkdir -p /opt/chaiya-ssh-api
dl "${RAW}/api/app.py" /opt/chaiya-ssh-api/app.py
chmod +x /opt/chaiya-ssh-api/app.py

dl "${RAW}/services/chaiya-ssh-api.service" /etc/systemd/system/chaiya-ssh-api.service
systemctl daemon-reload
systemctl enable --now chaiya-ssh-api
ok "SSH API พร้อม"

# ── PANEL ──────────────────────────────────────────────────
info "ติดตั้ง Panel..."
mkdir -p /opt/chaiya-panel /etc/chaiya/exp

dl "${RAW}/panel/index.html"  /opt/chaiya-panel/index.html
dl "${RAW}/panel/sshws.html"  /opt/chaiya-panel/sshws.html

cat > /opt/chaiya-panel/config.js << CFGEOF
window.CHAIYA_CONFIG = {
  host:"${DOMAIN}",
  xui_user:"${XUI_USER}",
  xui_pass:"${XUI_PASS}",
  dashboard_url:"sshws.html"
};
CFGEOF

mkdir -p /etc/chaiya
echo "${XUI_USER}"       > /etc/chaiya/xui-user.conf
echo "${XUI_PASS}"       > /etc/chaiya/xui-pass.conf
echo "${REAL_XUI_PORT}"  > /etc/chaiya/xui-port.conf
echo "${DASH_PASS}"      > /etc/chaiya/dash-pass.conf
chmod 600 /etc/chaiya/*.conf
ok "Panel พร้อม"

# ── SSL CERT ───────────────────────────────────────────────
info "ขอ SSL cert..."
systemctl stop nginx 2>/dev/null || true
systemctl stop chaiya-sshws 2>/dev/null || true

certbot certonly --standalone -d "${DOMAIN}" \
    --non-interactive --agree-tos -m "admin@${DOMAIN}" 2>&1 || true

USE_SSL=0
[[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] && USE_SSL=1
systemctl start chaiya-sshws 2>/dev/null || true

# ── NGINX ──────────────────────────────────────────────────
info "ตั้งค่า nginx..."
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
mkdir -p /etc/nginx/conf.d

if [[ $USE_SSL -eq 1 ]]; then
    dl "${RAW}/nginx/chaiya.conf" /etc/nginx/conf.d/chaiya.conf
    sed -i "s|DOMAIN_PLACEHOLDER|${DOMAIN}|g"      /etc/nginx/conf.d/chaiya.conf
    sed -i "s|PORT_PLACEHOLDER|${REAL_XUI_PORT}|g" /etc/nginx/conf.d/chaiya.conf
else
    info "ไม่มี SSL — ใช้ config แบบ plain"
    cat > /etc/nginx/conf.d/chaiya.conf << NGEOF
server {
    listen 443;
    root /opt/chaiya-panel;
    index index.html;
    location / { try_files \$uri \$uri/ =404; add_header Cache-Control "no-store"; }
    location /api/ { proxy_pass http://127.0.0.1:6789/api/; proxy_http_version 1.1; proxy_set_header Host \$host; }
    location /xui-api/ { proxy_pass http://127.0.0.1:${REAL_XUI_PORT}/; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_cookie_path / /; }
}
server {
    listen 2503;
    location / { proxy_pass http://127.0.0.1:${REAL_XUI_PORT}; proxy_http_version 1.1; proxy_set_header Host \$host; }
}
NGEOF
fi

nginx -t && systemctl enable --now nginx
ok "nginx พร้อม"

# ── MENU ───────────────────────────────────────────────────
info "ติดตั้ง menu..."
dl "${RAW}/bin/menu" /usr/local/bin/menu
chmod +x /usr/local/bin/menu
ln -sf /usr/local/bin/menu /usr/local/bin/chaiya
grep -q 'chaiya' /root/.bashrc || echo 'alias menu="/usr/local/bin/chaiya"' >> /root/.bashrc
ok "Menu พร้อม"

# ── UFW ────────────────────────────────────────────────────
info "ตั้งค่า firewall..."
ufw allow 22/tcp   2>/dev/null || true
ufw allow 80/tcp   2>/dev/null || true
ufw allow 109/tcp  2>/dev/null || true
ufw allow 143/tcp  2>/dev/null || true
ufw allow 443/tcp  2>/dev/null || true
ufw allow 2503/tcp 2>/dev/null || true
ufw allow 7300/udp 2>/dev/null || true
ufw allow 8080/tcp 2>/dev/null || true
ufw allow 8880/tcp 2>/dev/null || true
ufw deny  6789/tcp  2>/dev/null || true
ufw deny  54321/tcp 2>/dev/null || true
ufw --force enable
ok "Firewall พร้อม"

# ── FINAL CHECK ────────────────────────────────────────────
echo ""
info "ตรวจสอบ services..."
for svc in nginx x-ui dropbear-143 dropbear-109 chaiya-sshws chaiya-ssh-api chaiya-badvpn; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "$svc ✅"
    else
        warn "$svc ⚠️"
    fi
done

# ── DONE ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ติดตั้งเสร็จสมบูรณ์!${NC}"
if [[ $USE_SSL -eq 1 ]]; then
    echo -e "${CYAN}  Panel : https://${DOMAIN}${NC}"
    echo -e "${CYAN}  X-UI  : https://${DOMAIN}:2503${NC}"
else
    echo -e "${YELLOW}  Panel : http://${DOMAIN}:443 (ไม่มี SSL)${NC}"
    echo -e "${YELLOW}  X-UI  : http://${DOMAIN}:2503${NC}"
fi
echo -e "${YELLOW}  User  : ${XUI_USER} / ${XUI_PASS}${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════${NC}"
echo ""
