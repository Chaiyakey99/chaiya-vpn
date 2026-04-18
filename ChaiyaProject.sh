#!/bin/bash
# ============================================================
#  CHAIYA V2RAY PRO MAX
#  ติดตั้งครั้งเดียว พร้อมใช้งาน 100% ทุกเมนู
#  เมนู 1-18 ทำงานได้จริงทั้งหมด ไม่มีเมนูหลอก
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

# ── ตรวจสอบและติดตั้ง dependencies เบื้องต้น ────────────────
_bootstrap_pkgs=()
command -v curl  &>/dev/null || _bootstrap_pkgs+=(curl)
command -v wget  &>/dev/null || _bootstrap_pkgs+=(wget)
command -v gawk  &>/dev/null || _bootstrap_pkgs+=(gawk)

if [[ ${#_bootstrap_pkgs[@]} -gt 0 ]]; then
  echo "⏳ ติดตั้ง ${_bootstrap_pkgs[*]} ก่อนเริ่ม..."
  apt-get update -y -qq 2>/dev/null || true
  apt-get install -y -qq "${_bootstrap_pkgs[@]}" 2>/dev/null || true
  # ตรวจสอบว่าติดตั้งสำเร็จ
  for _pkg in "${_bootstrap_pkgs[@]}"; do
    if ! command -v "$_pkg" &>/dev/null; then
      echo "❌ ติดตั้ง $_pkg ไม่สำเร็จ — กรุณาติดตั้งด้วยตนเอง: apt-get install $_pkg"
      exit 1
    fi
  done
  echo "✅ ติดตั้ง dependencies สำเร็จ"
fi

# ── สีและ style ──────────────────────────────────────────────
R1=$'\033[1;38;2;77;255;176m'
R2=$'\033[1;38;2;128;255;221m'
R3=$'\033[1;38;2;255;230;128m'
R4=$'\033[1;38;2;77;255;176m'
R5=$'\033[1;38;2;128;255;221m'
R6=$'\033[1;38;2;184;160;255m'
PU=$'\033[1;38;2;184;160;255m'
YE=$'\033[1;38;2;255;230;128m'
WH=$'\033[1;38;2;200;221;208m'
GR=$'\033[1;38;2;77;255;176m'
RD=$'\033[1;38;2;255;107;138m'
CY=$'\033[1;38;2;128;255;221m'
MG=$'\033[1;38;2;184;160;255m'
OR=$'\033[1;38;2;255;179;71m'
RS=$'\033[0m'
BLD=$'\033[1m'

echo -e "${R2}🔥 กำลังติดตั้ง CHAIYA V2RAY PRO MAX...${RS}"

# ── Pre-flight: หยุด service ที่อาจชน port สำคัญ ─────────────
echo -e "${YE}⏳ ตรวจสอบ port conflicts...${RS}"
# หยุด apache2/lighttpd ที่มักชน port 80/443
for svc in apache2 lighttpd; do
  if systemctl is-active "$svc" &>/dev/null; then
    echo -e "  ${OR}⚠ หยุด $svc (ชน port 80/443)${RS}"
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  fi
done
# รอให้ port 80 ว่าง (nginx เก่าอาจยังรันอยู่)
systemctl stop nginx 2>/dev/null || true
sleep 1
# แจ้งเตือนถ้ายังมี process ค้างอยู่บน port สำคัญ
for _chk_port in 80 81 143 109 6789; do
  _proc=$(ss -tlnp 2>/dev/null | grep ":${_chk_port} " | grep -oP '(?<=users:\(\(")[^"]+' | head -1)
  [[ -n "$_proc" ]] && echo -e "  ${RD}⚠ port ${_chk_port} ถูกใช้โดย: ${_proc}${RS}" || true
done
echo -e "  ${GR}✅ ตรวจสอบ port เสร็จ${RS}"
# ── ล็อค / ล้าง dpkg ─────────────────────────────────────────
systemctl stop unattended-upgrades 2>/dev/null || true
pkill -f needrestart 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

apt-get update -y -qq
apt-get install -y -qq curl wget python3 bc qrencode ufw nginx \
  certbot python3-certbot-nginx python3-pip fail2ban sqlite3 \
  jq openssl net-tools screen iptables-persistent netfilter-persistent expect 2>/dev/null || true

pip3 install bcrypt --break-system-packages -q 2>/dev/null || true

# ── หยุด service เก่า ────────────────────────────────────────
for svc in apache2 xray; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done
rm -f /etc/systemd/system/xray.service /usr/local/bin/xray
rm -rf /usr/local/etc/xray /var/log/xray
systemctl daemon-reload 2>/dev/null || true

# ── สร้าง directories / files ────────────────────────────────
mkdir -p /etc/chaiya /var/www/chaiya/config /var/log/nginx \
         /etc/chaiya/sshws-users /etc/chaiya/vless-users
touch /etc/chaiya/vless.db /etc/chaiya/banned.db \
      /etc/chaiya/iplog.db /etc/chaiya/datalimit.conf \
      /etc/chaiya/iplimit_ban.json

echo "{}" > /etc/chaiya/iplimit_ban.json 2>/dev/null || true

# ── ตรวจจับ IP สาธารณะ ──────────────────────────────────────
MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
     || curl -s --max-time 5 api.ipify.org 2>/dev/null \
     || hostname -I | awk '{print $1}')

# ══════════════════════════════════════════════════════════════
#  PORT MAP (ล็อคไว้ตายตัว — ห้ามเปลี่ยนโดยไม่แก้สคริปต์)
#  22   → OpenSSH (SSH ปกติ)
#  80   → ws-stunnel (HTTP-CONNECT tunnel → Dropbear:143)
#  81   → nginx dashboard + proxy → API:6789 (internal)
#  109  → Dropbear SSH port 2
#  143  → Dropbear SSH port 1
#  443  → nginx SSL (SSH-WS-SSL self-signed + Dashboard HTTPS)
#  2053 → 3x-ui panel
#  6789 → chaiya-sshws-api (127.0.0.1 เท่านั้น — ห้าม expose)
#  7300 → badvpn-udpgw (127.0.0.1 เท่านั้น)
#  8080 → xui VMess inbound
#  8880 → xui VLESS inbound
# ══════════════════════════════════════════════════════════════

# ══════════════════════════════════════════════════════════════
#  PORT LOCKDOWN — ล็อค port ตายตัว ห้ามแก้ไข
#  port ที่อนุญาต (TCP inbound เท่านั้น):
#    22   → OpenSSH (admin)
#    80   → ws-stunnel HTTP-CONNECT tunnel
#    81   → Dashboard web UI
#    109  → Dropbear SSH port 2
#    143  → Dropbear SSH port 1
#    443  → SSH-WS-SSL (self-signed) + Dashboard HTTPS
#    2053 → xui alt port
#    2082 → xui alt port
#    8080 → xui VMess
#    8880 → xui VLESS
#  port ที่บล็อกถาวร (ห้ามเข้าจาก internet):
#    6789 → chaiya-sshws-api (localhost only)
#    7300 → badvpn-udpgw (localhost only)
# ══════════════════════════════════════════════════════════════

ALLOWED_PORTS=(22 80 81 109 143 443 2053 2082 8080 8880)

# ── UFW reset และตั้งค่าใหม่ทั้งหมด ──────────────────────────
ufw --force reset 2>/dev/null || true
ufw default deny incoming 2>/dev/null || true
ufw default deny forward 2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true

# เปิดเฉพาะ port ที่กำหนด
for p in "${ALLOWED_PORTS[@]}"; do
  ufw allow "$p"/tcp comment "CHAIYA_LOCKED" 2>/dev/null || true
done

# บล็อก port ภายในที่ต้องไม่ expose
ufw deny 6789/tcp comment "CHAIYA_INTERNAL" 2>/dev/null || true
ufw deny 7300/tcp comment "CHAIYA_INTERNAL" 2>/dev/null || true
ufw deny 7300/udp comment "CHAIYA_INTERNAL" 2>/dev/null || true

ufw --force enable 2>/dev/null || true

# ── iptables กำแพงชั้นที่ 2 — DROP ทุก port ที่ไม่อยู่ในลิสต์ ─
# flush rules เก่าของ CHAIYA ออกก่อน
iptables -D INPUT -j CHAIYA_BLOCK 2>/dev/null || true
iptables -F CHAIYA_BLOCK 2>/dev/null || true
iptables -X CHAIYA_BLOCK 2>/dev/null || true

iptables -N CHAIYA_BLOCK 2>/dev/null || true
# อนุญาต loopback
iptables -A CHAIYA_BLOCK -i lo -j RETURN
# อนุญาต established connections
iptables -A CHAIYA_BLOCK -m state --state ESTABLISHED,RELATED -j RETURN
# อนุญาตเฉพาะ port ที่กำหนด
for p in "${ALLOWED_PORTS[@]}"; do
  iptables -A CHAIYA_BLOCK -p tcp --dport "$p" -j RETURN
done
# DROP port ภายใน
iptables -A CHAIYA_BLOCK -p tcp --dport 6789 -j DROP
iptables -A CHAIYA_BLOCK -p tcp --dport 7300 -j DROP
iptables -A CHAIYA_BLOCK -p udp --dport 7300 -j DROP
# แทรก chain เข้า INPUT
iptables -I INPUT 1 -j CHAIYA_BLOCK 2>/dev/null || true

# บันทึก iptables ให้คงอยู่หลัง reboot — ลองทั้งสองวิธี
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save 2>/dev/null || true
fi
# fallback: iptables-persistent (Debian-style)
if [[ -d /etc/iptables ]]; then
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

echo "✅ Port lockdown เสร็จ — เปิดเฉพาะ: ${ALLOWED_PORTS[*]}"

# ══════════════════════════════════════════════════════════════
#  installer ไม่ถามอะไร — ทุกอย่างทำผ่านเมนู 1
#  แค่เตรียม helper functions ไว้ใช้ใน menu
# ══════════════════════════════════════════════════════════════
# สร้าง placeholder ถ้ายังไม่มี credential
[[ ! -f /etc/chaiya/xui-user.conf ]] && echo "admin" > /etc/chaiya/xui-user.conf
[[ ! -f /etc/chaiya/xui-pass.conf ]] && echo "admin" > /etc/chaiya/xui-pass.conf
[[ ! -f /etc/chaiya/xui-port.conf ]] && echo "2053" > /etc/chaiya/xui-port.conf
chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
#  nginx config
# ══════════════════════════════════════════════════════════════
# ── สร้าง Self-Signed SSL Certificate สำหรับ port 443 ──────────
echo -e "${YE}⏳ สร้าง SSL certificate (self-signed)...${RS}"
mkdir -p /etc/chaiya/ssl
if [[ ! -f /etc/chaiya/ssl/chaiya.crt ]] || [[ ! -f /etc/chaiya/ssl/chaiya.key ]]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/chaiya/ssl/chaiya.key \
    -out    /etc/chaiya/ssl/chaiya.crt \
    -subj "/C=TH/ST=Bangkok/L=Bangkok/O=ChaiyaVPN/CN=chaiya-vpn" \
    2>/dev/null
  chmod 600 /etc/chaiya/ssl/chaiya.key
  echo -e "  ${GR}✅ สร้าง SSL certificate สำเร็จ (10 ปี)${RS}"
else
  echo -e "  ${GR}✅ SSL certificate มีอยู่แล้ว${RS}"
fi

cat > /etc/nginx/sites-available/chaiya << 'NGINXEOF'
# ── Port 81: Web Panel (Dashboard + config download)
server {
    listen 81;
    server_name _;
    root /var/www/chaiya;
    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
        default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache";
    }
    location /sshws/ {
        alias /var/www/chaiya/;
        index sshws.html;
        try_files $uri $uri/ =404;
    }
    location /sshws-api/ {
        proxy_pass http://127.0.0.1:6789/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Token $http_x_token;
        proxy_set_header X-Auth-Token $http_x_auth_token;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,DELETE,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,X-Token,X-Auth-Token" always;
    }
    location /xui-traffic/ {
        proxy_pass http://127.0.0.1:2053/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Cookie $http_cookie;
        proxy_read_timeout 30s;
    }
}

# ── Port 443: SSH-WS-SSL (Self-Signed) + Dashboard HTTPS ────────
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/chaiya/ssl/chaiya.crt;
    ssl_certificate_key /etc/chaiya/ssl/chaiya.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # ── SSH WebSocket SSL — path /ssh/ → Dropbear:143 ────────────
    location /ssh/ {
        proxy_pass          http://127.0.0.1:143;
        proxy_http_version  1.1;
        proxy_set_header    Upgrade    $http_upgrade;
        proxy_set_header    Connection "upgrade";
        proxy_set_header    Host       $host;
        proxy_set_header    X-Real-IP  $remote_addr;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        proxy_buffering     off;
        tcp_nodelay         on;
    }

    # ── Dashboard + API (HTTPS) ───────────────────────────────────
    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
        default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache";
    }
    location /sshws/ {
        alias /var/www/chaiya/;
        index sshws.html;
        try_files $uri $uri/ =404;
    }
    location /sshws-api/ {
        proxy_pass http://127.0.0.1:6789/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Token $http_x_token;
        proxy_set_header X-Auth-Token $http_x_auth_token;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,DELETE,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,X-Token,X-Auth-Token" always;
    }
    location /xui-traffic/ {
        proxy_pass http://127.0.0.1:2053/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Cookie $http_cookie;
        proxy_read_timeout 30s;
    }
    location / { return 200 'Chaiya VPN OK'; add_header Content-Type text/plain; }
}
# หมายเหตุ: port 80 ถูกจัดการโดย ws-stunnel (HTTP CONNECT tunnel)
NGINXEOF

ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya
rm -f /etc/nginx/sites-enabled/default

# ── ล้าง port 80 ออกจาก nginx config ทุก path (Ubuntu 20/22/24) ──
# 1. nginx.conf หลัก
sed -i '/listen 80/d' /etc/nginx/nginx.conf 2>/dev/null || true
# 2. conf.d
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
for _f in /etc/nginx/conf.d/*.conf; do
  [[ -f "$_f" ]] && sed -i '/listen 80/d' "$_f" 2>/dev/null || true
done
# 3. sites-available อื่นที่อาจมี listen 80 (ยกเว้น chaiya ของเรา)
for _f in /etc/nginx/sites-enabled/*; do
  [[ "$_f" == *"chaiya"* ]] && continue
  [[ -f "$_f" ]] && grep -q "listen 80" "$_f" 2>/dev/null && {
    echo "  ⚠ ลบ nginx config ที่ชน port 80: $_f"
    rm -f "$_f"
  } || true
done
# 4. ตรวจ port 80 ยังถูกใช้ไหม (นอกจาก ws-stunnel)
_p80_proc=$(ss -tlnp 2>/dev/null | grep ":80 " | grep -v "ws-stunnel\|python" | grep -oP '(?<=users:\(\(")[^"]+' | head -1)
[[ -n "$_p80_proc" ]] && {
  echo "  ⚠ kill process แย่ง port 80: $_p80_proc"
  fuser -k 80/tcp 2>/dev/null || true
  sleep 1
} || true

# ── auto-install nginx ถ้าหายไป ──────────────────────────────
_ensure_nginx() {
  if ! command -v nginx &>/dev/null; then
    printf "${OR}⚠ nginx หายไป — กำลังติดตั้งใหม่...${RS}\n"
    apt-get install -y -qq nginx 2>/dev/null || true
    systemctl enable nginx 2>/dev/null || true
    systemctl start nginx 2>/dev/null || true
  fi
}

_ensure_nginx
# ── Start nginx พร้อม fallback ───────────────────────────────
systemctl enable nginx 2>/dev/null || true
if nginx -t 2>/dev/null; then
  systemctl restart nginx 2>/dev/null || true
  sleep 1
  if systemctl is-active --quiet nginx; then
    echo "✅ nginx เริ่มทำงานแล้ว"
  else
    echo "⚠ nginx start ไม่ได้ — ลอง force start..."
    pkill -f nginx 2>/dev/null || true
    sleep 1
    nginx 2>/dev/null || true
    sleep 1
    systemctl is-active --quiet nginx && echo "✅ nginx OK" || echo "❌ nginx ยังไม่ทำงาน — ตรวจสอบ: journalctl -u nginx -n 20"
  fi
else
  echo "❌ nginx config error:"
  nginx -t
fi

# ── [FIX] badvpn ใช้ systemd service แทน rc.local ────────────
# rc.local ไม่ reliable บน Ubuntu 20.04+ หลายเครื่อง
# ลบ entry เก่าใน rc.local ถ้ามี
sed -i '/badvpn-udpgw/d' /etc/rc.local 2>/dev/null || true


# ── ติดตั้ง Dropbear ─────────────────────────────────────────
apt-get install -y -qq dropbear 2>/dev/null || true

# ── [FIX] Generate Dropbear host keys ก่อน start service ──────
# เครื่องใหม่มักไม่มี host keys → dropbear fail เงียบๆ
mkdir -p /etc/dropbear
if [[ ! -f /etc/dropbear/dropbear_rsa_host_key ]]; then
  dropbearkey -t rsa     -f /etc/dropbear/dropbear_rsa_host_key    2>/dev/null || true
  echo "✅ Generated RSA host key"
fi
if [[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]]; then
  dropbearkey -t ecdsa   -f /etc/dropbear/dropbear_ecdsa_host_key  2>/dev/null || true
  echo "✅ Generated ECDSA host key"
fi
if [[ ! -f /etc/dropbear/dropbear_ed25519_host_key ]]; then
  dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true
  echo "✅ Generated ED25519 host key"
fi

# config Dropbear: port 143 (primary), 109 (secondary)
# ใช้ override แทน sed เพื่อรองรับทุก Ubuntu version
mkdir -p /etc/systemd/system/dropbear.service.d
cat > /etc/systemd/system/dropbear.service.d/override.conf << 'DBEOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -F -p 143 -p 109 -W 65536
DBEOF

# fallback: แก้ /etc/default/dropbear ด้วย (ถ้า init-style)
if [[ -f /etc/default/dropbear ]]; then
  # ปิด NO_START
  sed -i 's/^NO_START=.*/NO_START=0/' /etc/default/dropbear 2>/dev/null || true
  # force DROPBEAR_PORT=143 ไม่ว่าค่าเดิมจะเป็นอะไร
  if grep -q '^DROPBEAR_PORT=' /etc/default/dropbear 2>/dev/null; then
    sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=143/' /etc/default/dropbear
  else
    echo 'DROPBEAR_PORT=143' >> /etc/default/dropbear
  fi
  # force DROPBEAR_EXTRA_ARGS=-p 109
  if grep -q '^DROPBEAR_EXTRA_ARGS=' /etc/default/dropbear 2>/dev/null; then
    sed -i 's/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-p 109"/' /etc/default/dropbear
  else
    echo 'DROPBEAR_EXTRA_ARGS="-p 109"' >> /etc/default/dropbear
  fi
fi

# เพิ่ม /bin/false และ /usr/sbin/nologin เข้า shells
grep -q '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
grep -q '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

systemctl daemon-reload 2>/dev/null || true
systemctl enable dropbear 2>/dev/null || true
systemctl restart dropbear 2>/dev/null || true
sleep 2
# ตรวจสอบว่า dropbear ขึ้นจริง
if ! systemctl is-active --quiet dropbear 2>/dev/null; then
  echo "⚠️  dropbear ยังไม่ขึ้น — ลอง start ด้วย fallback..."
  systemctl stop dropbear 2>/dev/null || true
  pkill -f dropbear 2>/dev/null || true
  sleep 1
  /usr/sbin/dropbear -p 143 -p 109 -W 65536 2>/dev/null || true
fi

# ── badvpn-udpgw — ดาวน์โหลดพร้อม fallback หลาย source ──────
# ตรวจสอบ binary ด้วยการรัน --help จริง (ไม่ hardcode SHA256 เพราะ binary อัพเดทได้)
_verify_badvpn() {
  [[ -f /usr/bin/badvpn-udpgw ]] || return 1
  # ทดสอบว่ารันได้จริง (เป็น ELF binary ที่ valid)
  if ! /usr/bin/badvpn-udpgw --help 2>&1 | grep -qi "udpgw\|listen\|client\|usage" ; then
    echo "❌ badvpn-udpgw binary ไม่ valid — ลบทิ้ง"
    rm -f /usr/bin/badvpn-udpgw
    return 1
  fi
  return 0
}

if [[ ! -f /usr/bin/badvpn-udpgw ]] || [[ ! -x /usr/bin/badvpn-udpgw ]] || ! _verify_badvpn; then
  echo "⏳ ดาวน์โหลด badvpn-udpgw..."
  _badvpn_ok=0
  # source หลัก
  wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
    "https://raw.githubusercontent.com/NevermoreSSH/Blueblue/main/newudpgw" 2>/dev/null \
    && chmod +x /usr/bin/badvpn-udpgw && _verify_badvpn && _badvpn_ok=1 || { rm -f /usr/bin/badvpn-udpgw; true; }
  # fallback source 1
  if [[ $_badvpn_ok -eq 0 ]]; then
    wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
      "https://raw.githubusercontent.com/bagaswastu/badvpn/master/udpgw/badvpn-udpgw" 2>/dev/null \
      && chmod +x /usr/bin/badvpn-udpgw && _verify_badvpn && _badvpn_ok=1 || { rm -f /usr/bin/badvpn-udpgw; true; }
  fi
  # fallback source 2 — apt package (ปลอดภัยที่สุด)
  if [[ $_badvpn_ok -eq 0 ]]; then
    apt-get install -y -qq badvpn 2>/dev/null && _badvpn_ok=1 || true
    [[ $_badvpn_ok -eq 1 ]] && ln -sf "$(command -v badvpn-udpgw 2>/dev/null)" /usr/bin/badvpn-udpgw 2>/dev/null || true
  fi
  if [[ $_badvpn_ok -eq 1 ]]; then
    echo "✅ badvpn-udpgw ติดตั้งสำเร็จ"
  else
    echo "⚠️  badvpn-udpgw ดาวน์โหลดไม่สำเร็จ — UDP/game อาจไม่ทำงาน"
  fi
fi

# ── [FIX] ใช้ systemd service สำหรับ badvpn แทน screen ────────
# systemd ทำให้ auto-restart และ start หลัง reboot ได้แน่นอน
cat > /etc/systemd/system/chaiya-badvpn.service << 'BADVPNEOF'
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
BADVPNEOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable chaiya-badvpn 2>/dev/null || true
pkill -f badvpn 2>/dev/null || true
sleep 1
systemctl start chaiya-badvpn 2>/dev/null || \
  screen -dmS badvpn7300 badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500 2>/dev/null || true
echo "✅ badvpn-udpgw เริ่มทำงานแล้ว (port 7300)"

# ── ws-stunnel Python3 (รับ HTTP payload → Dropbear) ─────────
cat > /usr/local/bin/ws-stunnel << 'WSPYEOF'
#!/usr/bin/python3
import socket, threading, select, sys, time, collections

LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 80
PASS = ''
BUFLEN = 4096 * 4
TIMEOUT = 60
DEFAULT_HOST = '127.0.0.1:143'
RESPONSE = b'HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n'

# ── Rate limit / connection cap ─────────────────────────────
MAX_CONN_PER_IP = 20    # สูงสุดต่อ IP เดียวกัน
MAX_CONN_TOTAL  = 500   # สูงสุดทั้งระบบ
_ip_counts      = collections.defaultdict(int)   # IP → จำนวน conn ปัจจุบัน
_ip_lock        = threading.Lock()

class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.running = False
        self.host = host
        self.port = port
        self.threads = []
        self.threadsLock = threading.Lock()
        self.logLock = threading.Lock()

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
                ip = addr[0]
                with _ip_lock:
                    total = sum(_ip_counts.values())
                    if total >= MAX_CONN_TOTAL or _ip_counts[ip] >= MAX_CONN_PER_IP:
                        try:
                            c.send(b'HTTP/1.1 429 Too Many Requests\r\n\r\n')
                            c.close()
                        except Exception:
                            pass
                        continue
                    _ip_counts[ip] += 1
                conn = ConnectionHandler(c, self, addr)
                conn.start()
                self.addConn(conn)
        finally:
            self.running = False
            self.soc.close()

    def printLog(self, log):
        self.logLock.acquire()
        print(log)
        self.logLock.release()

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
        self.clientClosed = False
        self.targetClosed = True
        self.client = socClient
        self.client_buffer = b''
        self.server = server
        self.log = 'Connection: ' + str(addr)
        self.client_ip = addr[0]   # เก็บ IP เพื่อลด counter เมื่อปิด

    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except:
            pass
        finally:
            self.clientClosed = True
        try:
            if not self.targetClosed:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except:
            pass
        finally:
            self.targetClosed = True
        # ลด counter IP เมื่อ connection ปิด
        with _ip_lock:
            if _ip_counts[self.client_ip] > 0:
                _ip_counts[self.client_ip] -= 1
            if _ip_counts[self.client_ip] == 0:
                del _ip_counts[self.client_ip]

    def run(self):
        try:
            self.client_buffer = self.client.recv(BUFLEN)
            hostPort = self.findHeader(self.client_buffer, 'X-Real-Host')
            if hostPort == '':
                hostPort = DEFAULT_HOST
            split = self.findHeader(self.client_buffer, 'X-Split')
            if split != '':
                self.client.recv(BUFLEN)
            if hostPort != '':
                passwd = self.findHeader(self.client_buffer, 'X-Pass')
                if len(PASS) != 0 and passwd == PASS:
                    self.method_CONNECT(hostPort)
                elif len(PASS) != 0 and passwd != PASS:
                    self.client.send(b'HTTP/1.1 400 WrongPass!\r\n\r\n')
                elif hostPort.startswith('127.0.0.1') or hostPort.startswith('localhost'):
                    # [FIX] security: อนุญาตเฉพาะ port 143, 109 (Dropbear) เท่านั้น
                    # ป้องกัน client ส่ง X-Real-Host: 127.0.0.1:22 หรือ 127.0.0.1:6789
                    ALLOWED_LOCAL_PORTS = {143, 109}
                    try:
                        _hp_port = int(hostPort.split(':')[1]) if ':' in hostPort else 143
                    except (ValueError, IndexError):
                        _hp_port = -1
                    if _hp_port in ALLOWED_LOCAL_PORTS:
                        self.method_CONNECT(hostPort)
                    else:
                        self.client.send(b'HTTP/1.1 403 Forbidden!\r\n\r\n')
                else:
                    self.client.send(b'HTTP/1.1 403 Forbidden!\r\n\r\n')
            else:
                self.client.send(b'HTTP/1.1 400 NoXRealHost!\r\n\r\n')
        except Exception as e:
            print('Error:', e)
        finally:
            self.close()
            self.server.removeConn(self)

    def findHeader(self, head, header):
        if isinstance(head, bytes):
            head = head.decode('utf-8', errors='replace')
        aux = head.find(header + ': ')
        if aux == -1:
            return ''
        aux = head.find(':', aux)
        head = head[aux+2:]
        aux = head.find('\r\n')
        if aux == -1:
            return ''
        return head[:aux]

    def connect_target(self, host):
        i = host.find(':')
        if i != -1:
            port = int(host[i+1:])
            host = host[:i]
        else:
            port = 143
        (soc_family, soc_type, proto, _, address) = socket.getaddrinfo(host, port)[0]
        self.target = socket.socket(soc_family, soc_type, proto)
        self.targetClosed = False
        self.target.connect(address)

    def method_CONNECT(self, path):
        self.log += ' - CONNECT ' + path
        self.connect_target(path)
        self.client.sendall(RESPONSE)
        self.client_buffer = b''
        self.server.printLog(self.log)
        self.doCONNECT()

    def doCONNECT(self):
        socs = [self.client, self.target]
        count = 0
        error = False
        while True:
            count += 1
            (recv, _, err) = select.select(socs, [], socs, 3)
            if err:
                error = True
            if recv:
                for in_ in recv:
                    try:
                        data = in_.recv(BUFLEN)
                        if data:
                            if in_ is self.target:
                                self.client.send(data)
                            else:
                                while data:
                                    byte = self.target.send(data)
                                    data = data[byte:]
                            count = 0
                        else:
                            break
                    except:
                        error = True
                        break
            if count == TIMEOUT:
                error = True
            if error:
                break

def main():
    print("WS-Stunnel starting on port", LISTENING_PORT)
    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()
    while True:
        try:
            time.sleep(2)
        except KeyboardInterrupt:
            server.close()
            break

if __name__ == '__main__':
    main()
WSPYEOF
chmod +x /usr/local/bin/ws-stunnel

# ── chaiya-sshws systemd (ใช้ ws-stunnel Python3) ─────────────
cat > /etc/systemd/system/chaiya-sshws.service << 'WSEOF'
[Unit]
Description=WS-Stunnel SSH Tunnel port 80 -> Dropbear
After=network.target dropbear.service
Before=nginx.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-stunnel
Restart=always
RestartSec=3
# ป้องกัน port 80 ถูกชน: kill process อื่นบน port 80 ก่อน start
ExecStartPre=/bin/sh -c 'fuser -k 80/tcp 2>/dev/null || true'
[Install]
WantedBy=multi-user.target
WSEOF

mkdir -p /etc/chaiya
cat > /etc/chaiya/sshws.conf << 'CONFEOF'
SSH_PORT=22
WS_PORT=80
DROPBEAR_PORT=143
DROPBEAR_PORT2=109
USE_DROPBEAR=1
ENABLED=1
UDPGW_PORT=7300
CONFEOF

systemctl daemon-reload
systemctl enable chaiya-sshws
systemctl restart chaiya-sshws
# รอให้ ws-stunnel ขึ้น port 80 จริง (สูงสุด 15 วิ)
for _wsi in $(seq 1 8); do
  ss -tlnp 2>/dev/null | grep -q ":80 " && break || true
  sleep 2
done
if ss -tlnp 2>/dev/null | grep -q ":80 "; then
  echo "✅ ws-stunnel ขึ้น port 80 แล้ว"
else
  echo "⚠ ws-stunnel ยังไม่ขึ้น port 80 — ลอง fallback..."
  pkill -f ws-stunnel 2>/dev/null || true
  sleep 1
  nohup python3 /usr/local/bin/ws-stunnel >> /var/log/chaiya-sshws.log 2>&1 &
  sleep 3
fi

# ── ติดตั้ง HTML Dashboard อัตโนมัติ ─────────────────────────
mkdir -p /var/www/chaiya

# [FIX] สร้าง token ก่อนเขียน HTML — ป้องกัน %%BAKED_TOKEN%% ค้างใน HTML
SSHWS_TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')
if [[ -z "$SSHWS_TOKEN" ]]; then
  SSHWS_TOKEN=$(python3 -c "import hashlib,os; print(hashlib.sha256(os.urandom(32)).hexdigest()[:32])")
  echo "$SSHWS_TOKEN" > /etc/chaiya/sshws-token.conf
  chmod 600 /etc/chaiya/sshws-token.conf
fi

cat > /var/www/chaiya/sshws.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>🚀 CHAIYA SSH MANAGER</title>
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@400;500;600;700&family=Share+Tech+Mono&family=Exo+2:wght@300;400;600;800&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:#0a0d14;--bg2:#0f1520;--bg3:#141c2e;--panel:#111827;
    --border:#1e2d45;--border2:#243552;
    --green:#4dffa0;--cyan:#80ffdd;--purple:#b8a0ff;
    --yellow:#ffe680;--red:#ff6b8a;--orange:#ffb347;
    --text:#c8ddd0;--muted:#7a9aaa;
    --rgb1:#a78bfa;--rgb2:#818cf8;--rgb3:#67e8f9;
    --rgb4:#6ee7b7;--rgb5:#93c5fd;--rgb6:#c4b5fd;
  }
  *{margin:0;padding:0;box-sizing:border-box;}
  body{font-family:'Exo 2',sans-serif;background:var(--bg);color:var(--text);min-height:100vh;overflow-x:hidden;}
  body::before{content:'';position:fixed;inset:0;background-image:linear-gradient(rgba(77,255,160,.03) 1px,transparent 1px),linear-gradient(90deg,rgba(77,255,160,.03) 1px,transparent 1px);background-size:40px 40px;pointer-events:none;z-index:0;}
  body::after{content:'';position:fixed;inset:0;background:repeating-linear-gradient(0deg,transparent,transparent 2px,rgba(0,0,0,.05) 2px,rgba(0,0,0,.05) 4px);pointer-events:none;z-index:0;}

  .rgb-text{background:linear-gradient(90deg,var(--rgb1),var(--rgb2),var(--rgb3),var(--rgb4),var(--rgb5),var(--rgb6),var(--rgb1));background-size:300%;-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;animation:rgbshift 8s ease-in-out infinite;}
  @keyframes rgbshift{0%{background-position:0%}50%{background-position:150%}100%{background-position:300%}}

  .wrap{position:relative;z-index:1;max-width:960px;margin:0 auto;padding:0 14px 48px;}

  /* ─ Header ─ */
  header{text-align:center;padding:24px 0 16px;}
  .logo-icon{font-size:2.2rem;display:block;animation:pulse-icon 2s ease-in-out infinite;}
  @keyframes pulse-icon{0%,100%{filter:drop-shadow(0 0 8px var(--green))}50%{filter:drop-shadow(0 0 18px var(--cyan));transform:scale(1.06)}}
  .logo-title{font-family:'Rajdhani',sans-serif;font-weight:700;font-size:1.9rem;letter-spacing:4px;margin-top:4px;}
  .logo-sub{font-family:'Share Tech Mono',monospace;font-size:.65rem;color:var(--muted);letter-spacing:6px;text-transform:uppercase;margin-top:2px;}
  .server-info{display:inline-flex;align-items:center;gap:6px;background:var(--panel);border:1px solid var(--border);border-radius:20px;padding:3px 14px;font-family:'Share Tech Mono',monospace;font-size:.68rem;color:var(--muted);margin-top:8px;}
  .sdot{width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 8px var(--green);animation:blink 1.4s infinite;}
  @keyframes blink{0%,100%{opacity:1}50%{opacity:.3}}

  /* ─ Stats ─ */
  .stats{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin:16px 0;}
  @media(max-width:540px){.stats{grid-template-columns:1fr 1fr;}}
  .stat{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:14px 12px;position:relative;overflow:hidden;transition:transform .2s;}
  .stat:hover{transform:translateY(-2px);}
  .stat::before{content:'';position:absolute;top:0;left:0;right:0;height:2px;border-radius:10px 10px 0 0;}
  .stat.g::before{background:linear-gradient(90deg,var(--green),transparent);}
  .stat.c::before{background:linear-gradient(90deg,var(--cyan),transparent);}
  .stat.p::before{background:linear-gradient(90deg,var(--purple),transparent);}
  .stat.y::before{background:linear-gradient(90deg,var(--yellow),transparent);}
  .stat.r::before{background:linear-gradient(90deg,var(--red),transparent);}
  .stat.o::before{background:linear-gradient(90deg,var(--orange),transparent);}
  .stat-num{font-family:'Share Tech Mono',monospace;font-size:1.8rem;font-weight:bold;line-height:1;}
  .stat.g .stat-num{color:var(--green)}.stat.c .stat-num{color:var(--cyan)}
  .stat.p .stat-num{color:var(--purple)}.stat.y .stat-num{color:var(--yellow)}
  .stat.r .stat-num{color:var(--red)}.stat.o .stat-num{color:var(--orange)}
  .stat-lbl{font-family:'Share Tech Mono',monospace;font-size:.62rem;color:var(--muted);letter-spacing:1px;text-transform:uppercase;margin-top:4px;}
  .stat-ico{font-size:1.2rem;margin-bottom:6px;}

  /* ─ Tabs ─ */
  .tabs{display:flex;gap:5px;flex-wrap:wrap;justify-content:center;margin:14px 0 18px;}
  .tab{display:flex;align-items:center;gap:5px;padding:7px 14px;border-radius:7px;border:1px solid var(--border);background:var(--panel);color:var(--muted);font-family:'Rajdhani',sans-serif;font-weight:600;font-size:.85rem;letter-spacing:1px;cursor:pointer;transition:all .2s;white-space:nowrap;}
  .tab:hover{border-color:var(--cyan);color:var(--cyan);background:rgba(128,255,221,.06);}
  .tab.active{background:rgba(128,255,221,.1);border-color:var(--cyan);color:var(--cyan);box-shadow:0 0 10px rgba(128,255,221,.18);}

  /* ─ Pages ─ */
  .page{display:none;} .page.active{display:block;}

  /* ─ Card ─ */
  .card{background:var(--panel);border:1px solid var(--border);border-radius:11px;margin-bottom:14px;overflow:hidden;}
  .card-head{display:flex;align-items:center;justify-content:space-between;padding:11px 15px;border-bottom:1px solid var(--border);background:var(--bg3);}
  .card-title{font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.85rem;letter-spacing:2px;text-transform:uppercase;display:flex;align-items:center;gap:7px;color:var(--cyan);}
  .rgb-label{background:linear-gradient(90deg,var(--rgb1),var(--rgb2),var(--rgb3),var(--rgb4),var(--rgb5),var(--rgb6),var(--rgb1));background-size:300%;-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;animation:rgbshift 8s ease-in-out infinite;}
  .card-body{padding:14px;}

  /* ─ Service rows ─ */
  .svc-list{display:flex;flex-direction:column;gap:7px;}
  .svc-row{display:flex;align-items:center;gap:11px;padding:9px 13px;background:var(--bg2);border:1px solid var(--border);border-radius:7px;transition:border-color .2s;}
  .svc-row:hover{border-color:var(--border2);}
  .svc-ico{font-size:1.2rem;flex-shrink:0;}
  .svc-info{flex:1;min-width:0;}
  .svc-name{font-family:'Rajdhani',sans-serif;font-weight:600;font-size:.9rem;}
  .svc-desc{font-family:'Share Tech Mono',monospace;font-size:.62rem;color:var(--muted);}
  .svc-badge{display:flex;align-items:center;gap:4px;font-family:'Share Tech Mono',monospace;font-size:.62rem;padding:3px 9px;border-radius:20px;white-space:nowrap;}
  .svc-badge.on{background:rgba(77,255,160,.1);color:var(--green);border:1px solid rgba(77,255,160,.3);}
  .svc-badge.off{background:rgba(255,107,138,.1);color:var(--red);border:1px solid rgba(255,107,138,.3);}
  .svc-badge .bd{width:5px;height:5px;border-radius:50%;flex-shrink:0;}
  .svc-badge.on .bd{background:var(--green);box-shadow:0 0 5px var(--green);animation:blink 1.4s infinite;}
  .svc-badge.off .bd{background:var(--red);}

  /* ─ Conn bars ─ */
  .bar-wrap{margin-bottom:10px;}
  .bar-lbl{display:flex;justify-content:space-between;font-family:'Share Tech Mono',monospace;font-size:.65rem;color:var(--muted);margin-bottom:3px;}
  .bar{height:5px;background:var(--bg2);border-radius:3px;overflow:hidden;}
  .bar-fill{height:100%;border-radius:3px;background:linear-gradient(90deg,var(--green),var(--cyan));box-shadow:0 0 6px rgba(77,255,160,.4);transition:width .8s ease;}

  /* ─ Config box ─ */
  .cfg-box{background:var(--bg);border:1px solid var(--border);border-radius:7px;padding:12px;}
  .cfg-row{display:flex;justify-content:space-between;align-items:center;padding:6px 0;border-bottom:1px solid rgba(30,45,69,.5);font-family:'Share Tech Mono',monospace;font-size:.72rem;}
  .cfg-row:last-child{border:none;}
  .cfg-k{color:var(--muted);}
  .cfg-v{color:var(--yellow);text-align:right;word-break:break-all;max-width:60%;}

  /* ─ Forms ─ */
  .form-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;}
  @media(max-width:500px){.form-grid{grid-template-columns:1fr;}}
  .form-g{display:flex;flex-direction:column;gap:4px;}
  .form-g label{font-family:'Rajdhani',sans-serif;font-weight:600;font-size:.72rem;letter-spacing:1.5px;text-transform:uppercase;color:var(--muted);}
  input,select{background:var(--bg2);border:1px solid var(--border);border-radius:6px;padding:7px 11px;color:var(--text);font-family:'Share Tech Mono',monospace;font-size:.8rem;outline:none;transition:border-color .2s,box-shadow .2s;width:100%;}
  input:focus,select:focus{border-color:var(--cyan);box-shadow:0 0 0 2px rgba(128,255,221,.1);}
  select option{background:var(--bg2);}
  .full{grid-column:1/-1;}
  .inp-row{display:flex;gap:6px;}
  .inp-row input{flex:1;}

  /* ─ Buttons ─ */
  .btn-row{display:flex;gap:7px;flex-wrap:wrap;margin-top:10px;}
  .btn{display:inline-flex;align-items:center;gap:5px;padding:7px 16px;border-radius:6px;border:1px solid transparent;font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.82rem;letter-spacing:1px;cursor:pointer;transition:all .2s;white-space:nowrap;}
  .btn:hover{opacity:.85;transform:translateY(-1px);}
  .btn:active{transform:scale(.97);}
  .btn-c{background:rgba(128,255,221,.1);border-color:var(--cyan);color:var(--cyan);}
  .btn-g{background:rgba(77,255,160,.1);border-color:var(--green);color:var(--green);}
  .btn-r{background:rgba(255,107,138,.1);border-color:var(--red);color:var(--red);}
  .btn-y{background:rgba(255,230,128,.1);border-color:var(--yellow);color:var(--yellow);}
  .btn-p{background:rgba(184,160,255,.1);border-color:var(--purple);color:var(--purple);}
  .btn-sm{padding:4px 10px;font-size:.72rem;}

  /* ─ Table ─ */
  .tbl-wrap{overflow-x:auto;}
  table{width:100%;border-collapse:collapse;font-size:.8rem;}
  th{font-family:'Rajdhani',sans-serif;font-weight:700;letter-spacing:2px;text-transform:uppercase;font-size:.68rem;color:var(--cyan);padding:8px 11px;border-bottom:1px solid var(--border);text-align:left;background:var(--bg3);}
  td{padding:8px 11px;border-bottom:1px solid rgba(30,45,69,.5);font-family:'Share Tech Mono',monospace;font-size:.72rem;vertical-align:middle;}
  tr:hover td{background:rgba(255,255,255,.02);}
  .bdg{display:inline-block;padding:2px 8px;border-radius:10px;font-size:.6rem;font-family:'Share Tech Mono',monospace;letter-spacing:1px;}
  .bdg-g{background:rgba(77,255,160,.12);color:var(--green);border:1px solid rgba(77,255,160,.3);}
  .bdg-r{background:rgba(255,107,138,.12);color:var(--red);border:1px solid rgba(255,107,138,.3);}
  .bdg-y{background:rgba(255,230,128,.12);color:var(--yellow);border:1px solid rgba(255,230,128,.3);}
  .bdg-p{background:rgba(184,160,255,.12);color:var(--purple);border:1px solid rgba(184,160,255,.3);}

  /* ─ Log ─ */
  .log-box{background:var(--bg);border:1px solid var(--border);border-radius:7px;padding:11px 13px;font-family:'Share Tech Mono',monospace;font-size:.68rem;line-height:1.85;max-height:230px;overflow-y:auto;color:var(--muted);}
  .log-box::-webkit-scrollbar{width:4px;}
  .log-box::-webkit-scrollbar-thumb{background:var(--border2);border-radius:4px;}
  .log-ok{color:var(--green)}.log-err{color:var(--red)}.log-con{color:var(--cyan)}.log-w{color:var(--orange)}

  /* ─ Modal ─ */
  .modal-bg{display:none;position:fixed;inset:0;z-index:100;background:rgba(10,13,20,.85);backdrop-filter:blur(4px);align-items:center;justify-content:center;padding:14px;}
  .modal-bg.open{display:flex;}
  .modal{background:var(--panel);border:1px solid var(--border2);border-radius:13px;width:100%;max-width:460px;animation:mIn .22s ease;}
  @keyframes mIn{from{opacity:0;transform:scale(.92) translateY(18px)}to{opacity:1;transform:none}}
  .modal-head{display:flex;justify-content:space-between;align-items:center;padding:13px 15px;border-bottom:1px solid var(--border);font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;letter-spacing:2px;color:var(--cyan);}
  .modal-x{background:none;border:none;color:var(--muted);-webkit-text-fill-color:var(--muted);font-size:1rem;cursor:pointer;padding:2px 6px;border-radius:4px;}
  .modal-x:hover{color:var(--red);-webkit-text-fill-color:var(--red);}
  .modal-body{padding:14px;}

  /* ─ Toast ─ */
  #toast{position:fixed;bottom:22px;left:50%;transform:translateX(-50%) translateY(70px);background:var(--panel);border:1px solid var(--cyan);border-radius:7px;padding:8px 18px;font-family:'Share Tech Mono',monospace;font-size:.75rem;color:var(--cyan);box-shadow:0 0 16px rgba(128,255,221,.2);transition:transform .28s ease;z-index:999;white-space:nowrap;}
  #toast.show{transform:translateX(-50%) translateY(0);}
  #toast.err{border-color:var(--red);color:var(--red);}

  /* ─ Svc ctrl row ─ */
  .svc-ctrl{display:flex;align-items:center;justify-content:space-between;}

  /* ─ Alert ─ */
  .alert{padding:7px 11px;border-radius:6px;margin-bottom:8px;font-size:.8rem;display:none;}
  .alert.show{display:block;}
  .alert-ok{background:rgba(0,255,96,.1);border:1px solid rgba(0,255,96,.25);color:var(--green);}
  .alert-err{background:rgba(255,0,64,.1);border:1px solid rgba(255,0,64,.25);color:var(--red);}

  /* ─ Spin ─ */
  .spin{display:inline-block;width:13px;height:13px;border:2px solid rgba(255,255,255,.15);border-top-color:var(--cyan);border-radius:50%;animation:spin .6s linear infinite;vertical-align:middle;margin-right:4px;}
  @keyframes spin{to{transform:rotate(360deg)}}

  /* ─ App selector (NapsternetV / DarkTunnel) ─ */
  .sel-lbl{font-size:.68rem;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted);margin:.75rem 0 .4rem;display:flex;align-items:center;gap:.3rem;}
  .pick-grid{display:grid;grid-template-columns:1fr 1fr;gap:.5rem;margin-bottom:.3rem;}
  .pick-opt{padding:.6rem .4rem;border-radius:.65rem;border:1.5px solid var(--border);background:var(--bg2);cursor:pointer;text-align:center;user-select:none;transition:all .2s;}
  .pick-opt .pi{font-size:1.15rem;margin-bottom:.15rem;}.pick-opt .pn{font-size:.75rem;font-weight:700;}.pick-opt .ps{font-size:.6rem;color:var(--muted);margin-top:.08rem;}
  .pick-opt.a-dtac{border-color:#ff6600;background:rgba(255,102,0,.1);box-shadow:0 0 10px rgba(255,102,0,.18);}
  .pick-opt.a-true{border-color:#00ccff;background:rgba(0,204,255,.1);box-shadow:0 0 10px rgba(0,204,255,.18);}
  .pick-opt.a-npv{border-color:#00ccff;background:rgba(0,204,255,.1);box-shadow:0 0 10px rgba(0,204,255,.18);}
  .pick-opt.a-dark{border-color:#9933ff;background:rgba(153,51,255,.1);box-shadow:0 0 10px rgba(153,51,255,.2);}
  .c-dtac{color:#ff8833;}.c-true{color:#00ccff;}.c-npv{color:#00ccff;}.c-dark{color:#cc66ff;}

  /* ─ Import link block ─ */
  .imp-result{display:none;margin-top:.8rem;animation:fadeUp .3s ease;}
  .imp-result.show{display:block;}
  @keyframes fadeUp{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
  .imp-badge{font-size:.65rem;font-weight:700;letter-spacing:1.5px;padding:.16rem .5rem;border-radius:99px;}
  .imp-badge.npv{background:rgba(0,180,255,.15);color:#00ccff;border:1px solid rgba(0,180,255,.3);}
  .imp-badge.dark{background:rgba(153,51,255,.15);color:#cc66ff;border:1px solid rgba(153,51,255,.3);}
  .link-preview{background:#06060e;border-radius:.5rem;padding:.5rem .7rem;font-family:monospace;font-size:.56rem;color:#00aadd;word-break:break-all;line-height:1.6;margin:.4rem 0;max-height:50px;overflow:hidden;position:relative;border:1px solid rgba(0,150,255,.15);}
  .link-preview.dark-lp{border-color:rgba(153,51,255,.22);color:#aa55ff;}
  .link-preview::after{content:'';position:absolute;bottom:0;left:0;right:0;height:14px;background:linear-gradient(transparent,#06060e);}
  .copy-link-btn{width:100%;padding:.5rem;border-radius:.45rem;font-size:.8rem;font-weight:700;cursor:pointer;transition:all .2s;font-family:inherit;border:1px solid;}
  .copy-link-btn.npv{background:rgba(0,180,255,.08);border-color:rgba(0,180,255,.28);color:#00ccff;}
  .copy-link-btn.dark{background:rgba(153,51,255,.08);border-color:rgba(153,51,255,.28);color:#cc66ff;}
  .copy-link-btn:hover{opacity:.78;}

  /* ─ Traf chart (bar style) ─ */
  .traf-total{font-size:1rem;font-weight:900;color:#00e8ff;font-family:monospace;text-shadow:0 0 10px #00e8ff88}
  .traf-summary{display:flex;justify-content:space-between;margin-bottom:.65rem}
  .traf-summary-item .ts-lbl{font-size:.58rem;color:var(--muted);font-family:monospace;letter-spacing:1px;text-transform:uppercase}
  .traf-summary-item .ts-val{font-size:1rem;font-weight:700}
  .traf-summary-item.up .ts-val{color:#00e8ff;text-shadow:0 0 12px rgba(0,232,255,.4)}
  .traf-summary-item.dn .ts-val{color:var(--teal);text-shadow:0 0 12px rgba(79,209,197,.4);text-align:right}
  .chart-wrap{width:100%;height:90px;position:relative;overflow:hidden}
  .chart-wrap canvas{width:100%!important;height:100%!important;display:block}
  .chart-time{display:flex;justify-content:space-between;font-size:.5rem;color:rgba(0,180,220,.45);font-family:monospace;margin-top:3px;padding:0 2px}

  @media(max-width:500px){.stats{grid-template-columns:1fr 1fr}}

  /* RGB Ambient Orbs */
  .rgb-orb{position:fixed;border-radius:50%;filter:blur(90px);opacity:.11;pointer-events:none;z-index:0;}
  .rgb-orb.o1{width:360px;height:360px;background:radial-gradient(circle,#ff006e,transparent 70%);top:-100px;left:-80px;animation:orb1 14s ease-in-out infinite;}
  .rgb-orb.o2{width:320px;height:320px;background:radial-gradient(circle,#00dcff,transparent 70%);top:35%;right:-90px;animation:orb2 18s ease-in-out infinite;}
  .rgb-orb.o3{width:280px;height:280px;background:radial-gradient(circle,#b400ff,transparent 70%);bottom:8%;left:5%;animation:orb3 16s ease-in-out infinite;}
  .rgb-orb.o4{width:240px;height:240px;background:radial-gradient(circle,#00ff88,transparent 70%);bottom:22%;right:3%;animation:orb4 20s ease-in-out infinite;}
  @keyframes orb1{0%,100%{transform:translate(0,0) scale(1);}50%{transform:translate(40px,-30px) scale(1.1);}}
  @keyframes orb2{0%,100%{transform:translate(0,0) scale(1);}50%{transform:translate(-35px,25px) scale(1.07);}}
  @keyframes orb3{0%,100%{transform:translate(0,0) scale(1);}50%{transform:translate(25px,-40px) scale(.93);}}
  @keyframes orb4{0%,100%{transform:translate(0,0) scale(1);}50%{transform:translate(-20px,30px) scale(1.06);}}

  /* Shooting Stars Canvas */
  #stars-canvas{position:fixed;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:0;}

  /* Bandwidth Level Badge */
  .bw-level{display:inline-flex;align-items:center;gap:4px;font-family:'Share Tech Mono',monospace;font-size:.6rem;padding:2px 9px;border-radius:12px;margin-left:6px;font-weight:700;letter-spacing:1px;transition:all .5s;vertical-align:middle;}
  .bw-level.lv-normal{background:rgba(77,255,160,.12);color:#4dffa0;border:1px solid rgba(77,255,160,.3);}
  .bw-level.lv-medium{background:rgba(255,230,128,.12);color:#ffe680;border:1px solid rgba(255,230,128,.35);}
  .bw-level.lv-high{background:rgba(255,107,138,.15);color:#ff6b8a;border:1px solid rgba(255,107,138,.4);animation:bw-pulse .85s ease-in-out infinite;}
  @keyframes bw-pulse{0%,100%{box-shadow:0 0 0 0 rgba(255,107,138,0);}50%{box-shadow:0 0 10px 2px rgba(255,107,138,.35);}}

  /* RGB card border shimmer */
  .card{position:relative;}
  .card::after{content:'';position:absolute;inset:-1px;border-radius:12px;background:linear-gradient(135deg,rgba(128,255,221,.07),rgba(184,160,255,.07),rgba(77,255,160,.07));-webkit-mask:linear-gradient(#fff 0 0) content-box,linear-gradient(#fff 0 0);-webkit-mask-composite:xor;mask-composite:exclude;pointer-events:none;z-index:2;transition:opacity .3s;}
  .card:hover::after{opacity:2.5;}

  /* Header RGB scan line */
  header{position:relative;}
  header::after{content:'';position:absolute;left:0;right:0;height:2px;bottom:-1px;background:linear-gradient(90deg,transparent 0%,#80ffdd 30%,#b8a0ff 60%,#4dffa0 85%,transparent 100%);background-size:300% 100%;animation:hdr-scan 3.5s linear infinite;opacity:.55;border-radius:2px;}
  @keyframes hdr-scan{0%{background-position:0% 0}100%{background-position:300% 0}}
</style>
</head>
<body>
<canvas id="stars-canvas"></canvas>
<div class="rgb-orb o1"></div>
<div class="rgb-orb o2"></div>
<div class="rgb-orb o3"></div>
<div class="rgb-orb o4"></div>
<div class="wrap">

<!-- Header -->
<header>
  <span class="logo-icon">🚀</span>
  <div class="logo-title rgb-text">CHAIYA SSH MANAGER</div>
  <div class="logo-sub">V2RAY PRO MAX · DASHBOARD</div>
  <div class="server-info">
    <span class="sdot"></span>
    <span id="server-ip" style="min-height:1em">กำลังโหลด...</span>
    &nbsp;·&nbsp;
    <span id="clock-txt">--:--:--</span>
  </div>
</header>

<!-- Stats -->
<div class="stats">
  <div class="stat c"><div class="stat-ico">👤</div><div class="stat-num" id="stat-users">-</div><div class="stat-lbl">Total Users</div></div>
  <div class="stat g"><div class="stat-ico">🟢</div><div class="stat-num" id="stat-online">-</div><div class="stat-lbl">Online</div></div>
  <div class="stat p"><div class="stat-ico">🔗</div><div class="stat-num" id="stat-conns">-</div><div class="stat-lbl">Connections</div></div>
  <div class="stat r"><div class="stat-ico">🔒</div><div class="stat-num" id="stat-banned">0</div><div class="stat-lbl">Banned</div></div>
  <div class="stat y"><div class="stat-ico">⚡</div><div class="stat-num" id="stat-vless">-</div><div class="stat-lbl">VLESS</div></div>
  <div class="stat o"><div class="stat-ico">📡</div><div class="stat-num" id="stat-port">80</div><div class="stat-lbl">WS Port</div></div>
</div>

<!-- Tabs -->
<div class="tabs">
  <div class="tab active" onclick="showTab('dashboard',this)">📊 Dashboard</div>
  <div class="tab" onclick="showTab('users',this)">👤 Users</div>
  <div class="tab" onclick="showTab('online',this)">🌐 Online</div>
  <div class="tab" onclick="showTab('banned',this)">🔒 Banned</div>
  <div class="tab" onclick="showTab('backup',this)">💾 Backup</div>
  <div class="tab" onclick="showTab('services',this)">⚙️ Services</div>
</div>

<!-- ═══ DASHBOARD ═══ -->
<div id="page-dashboard" class="page active">
  <div class="card">
    <div class="card-head">
      <div class="card-title">📊 <span class="rgb-label">สถานะ Services</span></div>
      <button class="btn btn-c btn-sm" onclick="loadDashboard()">🔄 Refresh</button>
    </div>
    <div class="card-body">
      <div class="svc-list">
        <div class="svc-row"><span class="svc-ico">🚇</span><div class="svc-info"><div class="svc-name">chaiya-sshws</div><div class="svc-desc">SSH WebSocket Proxy · Port 80</div></div><div id="svc-sshws" class="svc-badge off"><span class="bd"></span>...</div></div>
        <div class="svc-row"><span class="svc-ico">🐻</span><div class="svc-info"><div class="svc-name">Dropbear SSH</div><div class="svc-desc">SSH Daemon · Port 143 / 109</div></div><div id="svc-dropbear" class="svc-badge off"><span class="bd"></span>...</div></div>
        <div class="svc-row"><span class="svc-ico">🌐</span><div class="svc-info"><div class="svc-name">nginx</div><div class="svc-desc">Web Server · Port 81 / 443</div></div><div id="svc-nginx" class="svc-badge off"><span class="bd"></span>...</div></div>
        <div class="svc-row"><span class="svc-ico">🎮</span><div class="svc-info"><div class="svc-name">badvpn-udpgw</div><div class="svc-desc">UDP Gateway · 127.0.0.1:7300</div></div><div id="svc-badvpn" class="svc-badge off"><span class="bd"></span>...</div></div>
        <div class="svc-row"><span class="svc-ico">🔌</span><div class="svc-info"><div class="svc-name">Port 80 Tunnel</div><div class="svc-desc">HTTP-CONNECT ws-stunnel</div></div><div id="svc-tunnel" class="svc-badge off"><span class="bd"></span>...</div></div>
        <div class="svc-row"><span class="svc-ico">🔒</span><div class="svc-info"><div class="svc-name">Port 443 SSH-WS-SSL</div><div class="svc-desc">WebSocket SSL · Self-Signed</div></div><div id="svc-ssl443" class="svc-badge off"><span class="bd"></span>...</div></div>
      </div>
      <div class="btn-row">
        <button class="btn btn-g" onclick="svcAction('restart')">🔄 Restart All</button>
        <button class="btn btn-r" onclick="svcAction('stop')">⏹ Stop</button>
        <button class="btn btn-c" onclick="svcAction('start')">▶️ Start</button>
        <button class="btn btn-p" onclick="restartUdpgw()">🎮 UDP</button>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="card-title">🌍 <span class="rgb-label">Server Info</span></div></div>
    <div class="card-body cfg-box" id="conn-info">
      <div class="cfg-row"><span class="cfg-k">🌍 Host</span><span class="cfg-v" id="server-ip-info">กำลังโหลด...</span></div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="card-title">🔗 <span class="rgb-label">Connections per Port</span></div></div>
    <div class="card-body" id="conn-bars-wrap">
      <div class="bar-wrap"><div class="bar-lbl"><span>Port 80 (WS Tunnel)</span><span style="display:flex;align-items:center;gap:4px"><span id="b80">0</span><span id="bl80" class="bw-level lv-normal">NORMAL</span></span></div><div class="bar"><div class="bar-fill" id="bf80" style="width:0%"></div></div></div>
      <div class="bar-wrap"><div class="bar-lbl"><span>Port 143 (Dropbear #1)</span><span style="display:flex;align-items:center;gap:4px"><span id="b143">0</span><span id="bl143" class="bw-level lv-normal">NORMAL</span></span></div><div class="bar"><div class="bar-fill" id="bf143" style="width:0%"></div></div></div>
      <div class="bar-wrap"><div class="bar-lbl"><span>Port 109 (Dropbear #2)</span><span style="display:flex;align-items:center;gap:4px"><span id="b109">0</span><span id="bl109" class="bw-level lv-normal">NORMAL</span></span></div><div class="bar"><div class="bar-fill" id="bf109" style="width:0%"></div></div></div>
      <div class="bar-wrap"><div class="bar-lbl"><span>Port 22 (OpenSSH)</span><span style="display:flex;align-items:center;gap:4px"><span id="b22">0</span><span id="bl22" class="bw-level lv-normal">NORMAL</span></span></div><div class="bar"><div class="bar-fill" id="bf22" style="width:0%"></div></div></div>
    </div>
  </div>

</div>

<!-- ═══ USERS ═══ -->
<div id="page-users" class="page">
  <div class="card">
    <div class="card-head"><div class="card-title">➕ <span class="rgb-label">เพิ่ม SSH User</span></div></div>
    <div class="card-body">
      <div id="alert-create" class="alert"></div>
      <div class="form-grid">
        <div class="form-g"><label>ชื่อผู้ใช้</label><input type="text" id="new-user" placeholder="username" oninput="clearCreateLink()"></div>
        <div class="form-g"><label>รหัสผ่าน</label><input type="password" id="new-pass" placeholder="password" oninput="clearCreateLink()"></div>
        <div class="form-g"><label>จำนวนวัน</label><input type="number" id="new-exp" value="30" min="1"></div>
        <div class="form-g"><label>ลิมิตไอพี</label><input type="number" id="new-iplimit" value="2" min="1"></div>
      </div>
      <div class="sel-lbl">🌐 เลือก ISP / Operator</div>
      <div class="pick-grid">
        <div id="cu-pro-dtac" class="pick-opt a-dtac" onclick="cuSelPro('dtac')"><div class="pi">🟠</div><div class="pn c-dtac">DTAC GAMING</div><div class="ps">dl.dir.freefiremobile.com</div></div>
        <div id="cu-pro-true" class="pick-opt" onclick="cuSelPro('true')"><div class="pi">🔵</div><div class="pn c-true">TRUE TWITTER</div><div class="ps">help.x.com</div></div>
      </div>
      <div class="sel-lbl">📱 เลือก App</div>
      <div class="pick-grid">
        <div id="cu-app-npv" class="pick-opt a-npv" onclick="cuSelApp('npv')"><div class="pi" style="width:38px;height:38px;border-radius:10px;background:#0d2a3a;display:flex;align-items:center;justify-content:center;margin:0 auto .18rem;font-family:monospace;font-weight:900;font-size:.85rem;color:#00ccff;letter-spacing:-1px;border:1.5px solid #00ccff44">nV</div><div class="pn c-npv">Npv Tunnel</div><div class="ps">npvt-ssh://</div></div>
        <div id="cu-app-dark" class="pick-opt" onclick="cuSelApp('dark')"><div class="pi" style="width:38px;height:38px;border-radius:10px;background:#111;display:flex;align-items:center;justify-content:center;margin:0 auto .18rem;font-family:sans-serif;font-weight:900;font-size:.62rem;color:#fff;letter-spacing:.5px;border:1.5px solid #444">DARK</div><div class="pn c-dark">DarkTunnel</div><div class="ps">darktunnel://</div></div>
      </div>
      <div class="btn-row" style="margin-top:.6rem">
        <button class="btn btn-g" onclick="createUserAndLink()">➕ สร้าง User</button>
      </div>
      <div class="imp-result" id="cu-link-result"></div>
    </div>
  </div>
  <div class="card">
    <div class="card-head">
      <div class="card-title">📋 <span class="rgb-label">รายชื่อ Users</span></div>
      <div class="inp-row" style="max-width:180px">
        <input type="text" id="search-u" placeholder="ค้นหา..." oninput="filterUsers()" style="padding:4px 9px;font-size:.72rem">
      </div>
    </div>
    <div class="card-body" style="padding:0">
      <div class="tbl-wrap">
        <table>
          <thead><tr><th>#</th><th>Username</th><th>หมดอายุ</th><th>สถานะ</th><th>Action</th></tr></thead>
          <tbody id="user-tbody"><tr><td colspan="5" style="text-align:center;color:var(--muted);padding:2rem">กำลังโหลด...</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>
</div>

<!-- ═══ ONLINE ═══ -->
<div id="page-online" class="page">
  <div class="card">
    <div class="card-head">
      <div class="card-title">👤 <span class="rgb-label">Online Users</span></div>
      <button class="btn btn-c btn-sm" onclick="loadOnline()">🔄 Refresh</button>
    </div>
    <div class="card-body" id="online-list"><div style="text-align:center;color:var(--muted);padding:2rem">กำลังโหลด...</div></div>
  </div>
  <div class="card">
    <div class="card-head">
      <div class="card-title">📶 <span class="rgb-label">Bandwidth</span></div>
      <span class="traf-total" id="traf-total">— MB</span>
    </div>
    <div class="card-body">
      <div class="traf-summary">
        <div class="traf-summary-item up">
          <div class="ts-lbl">UPLOAD</div>
          <div class="ts-val" id="traf-up">—</div>
        </div>
        <div class="traf-summary-item dn">
          <div class="ts-lbl">DOWNLOAD</div>
          <div class="ts-val" id="traf-dn">—</div>
        </div>
      </div>
      <div class="chart-wrap"><canvas id="traf-canvas"></canvas></div>
      <div class="chart-time" id="traf-time-labels"></div>
      <div id="traf-upd" style="text-align:right;font-size:.62rem;color:rgba(0,180,220,.3);margin-top:.3rem;font-family:monospace"></div>
    </div>
  </div>
</div>

<!-- ═══ BANNED ═══ -->
<div id="page-banned" class="page">
  <div class="card">
    <div class="card-head">
      <div class="card-title">🔒 <span class="rgb-label">Banned IPs / Users</span></div>
      <button class="btn btn-c btn-sm" onclick="loadBanned()">🔄 Refresh</button>
    </div>
    <div class="card-body" id="banned-list"><div style="text-align:center;color:var(--muted);padding:2rem">กำลังโหลด...</div></div>
  </div>
</div>

<!-- ═══ BACKUP ═══ -->
<div id="page-backup" class="page">
  <div class="card">
    <div class="card-head"><div class="card-title">💾 <span class="rgb-label">Backup Users</span></div></div>
    <div class="card-body">
      <p style="font-size:.82rem;color:var(--muted);margin-bottom:.8rem">Export ข้อมูล users เป็น JSON</p>
      <button class="btn btn-g" onclick="backupUsers()">⬇️ Download Backup</button>
    </div>
  </div>
  <div class="card">
    <div class="card-head"><div class="card-title">📥 <span class="rgb-label">Import Users</span></div></div>
    <div class="card-body">
      <div id="alert-import" class="alert"></div>
      <div class="form-g" style="margin-bottom:.8rem"><label>เลือกไฟล์ JSON</label><input type="file" id="import-file" accept=".json" style="color:var(--text)"></div>
      <button class="btn btn-p" onclick="importUsers()">⬆️ Import Users</button>
      <div id="import-result" style="margin-top:.8rem;font-size:.82rem;display:none"></div>
    </div>
  </div>
</div>

<!-- ═══ SERVICES ═══ -->
<div id="page-services" class="page">
  <div class="card">
    <div class="card-head"><div class="card-title">⚙️ <span class="rgb-label">Service Control</span></div></div>
    <div class="card-body">
      <div class="svc-list">
        <div class="svc-row svc-ctrl"><div style="display:flex;gap:.6rem;align-items:center"><span class="svc-ico">🚇</span><div><div class="svc-desc">chaiya-sshws</div><div id="s2-sshws" class="svc-name" style="font-size:.82rem">-</div></div></div><div class="btn-row" style="margin:0"><button class="btn btn-g btn-sm" onclick="svc1('chaiya-sshws','start')">▶</button><button class="btn btn-r btn-sm" onclick="svc1('chaiya-sshws','stop')">⏹</button><button class="btn btn-c btn-sm" onclick="svc1('chaiya-sshws','restart')">🔄</button></div></div>
        <div class="svc-row svc-ctrl"><div style="display:flex;gap:.6rem;align-items:center"><span class="svc-ico">🐻</span><div><div class="svc-desc">Dropbear SSH :143/:109</div><div id="s2-dropbear" class="svc-name" style="font-size:.82rem">-</div></div></div><div class="btn-row" style="margin:0"><button class="btn btn-g btn-sm" onclick="svc1('dropbear','start')">▶</button><button class="btn btn-r btn-sm" onclick="svc1('dropbear','stop')">⏹</button><button class="btn btn-c btn-sm" onclick="svc1('dropbear','restart')">🔄</button></div></div>
        <div class="svc-row svc-ctrl"><div style="display:flex;gap:.6rem;align-items:center"><span class="svc-ico">🌐</span><div><div class="svc-desc">nginx :80/:81/:443</div><div id="s2-nginx" class="svc-name" style="font-size:.82rem">-</div></div></div><div class="btn-row" style="margin:0"><button class="btn btn-g btn-sm" onclick="svc1('nginx','start')">▶</button><button class="btn btn-r btn-sm" onclick="svc1('nginx','stop')">⏹</button><button class="btn btn-c btn-sm" onclick="svc1('nginx','restart')">🔄</button></div></div>
        <div class="svc-row svc-ctrl"><div style="display:flex;gap:.6rem;align-items:center"><span class="svc-ico">🎮</span><div><div class="svc-desc">badvpn-udpgw :7300</div><div id="s2-badvpn" class="svc-name" style="font-size:.82rem">-</div></div></div><div class="btn-row" style="margin:0"><button class="btn btn-g btn-sm" onclick="restartUdpgw()">🔄 Restart</button></div></div>
      </div>
      <div class="btn-row" style="margin-top:12px">
        <button class="btn btn-g" onclick="svcAction('start')">▶️ Start All</button>
        <button class="btn btn-r" onclick="svcAction('stop')">⏹ Stop All</button>
        <button class="btn btn-c" onclick="svcAction('restart')">🔄 Restart All</button>
      </div>
    </div>
  </div>
</div>

</div><!-- /wrap -->

<!-- Modals -->
<div id="modal-renew" class="modal-bg">
  <div class="modal">
    <div class="modal-head"><span class="rgb-label">🔄 ต่ออายุ User</span> <button class="modal-x" onclick="closeModal('modal-renew')">✕</button></div>
    <div class="modal-body">
      <input type="hidden" id="renew-username">
      <div class="form-grid">
        <div class="form-g"><label>Username</label><input type="text" id="renew-show" disabled></div>
        <div class="form-g"><label>เพิ่มวัน</label><input type="number" id="renew-days" value="30" min="1"></div>
      </div>
      <div class="btn-row">
        <button class="btn btn-g" onclick="doRenew()">✅ ต่ออายุ</button>
        <button class="btn btn-r" onclick="closeModal('modal-renew')">ยกเลิก</button>
      </div>
    </div>
  </div>
</div>
<div id="modal-del" class="modal-bg">
  <div class="modal">
    <div class="modal-head"><span class="rgb-label">🗑️ ยืนยันลบ</span> <button class="modal-x" onclick="closeModal('modal-del')">✕</button></div>
    <div class="modal-body">
      <p style="margin:.5rem 0 1rem;color:var(--muted)">ต้องการลบ <strong id="del-username" style="color:var(--red)"></strong>?</p>
      <div class="btn-row">
        <button class="btn btn-r" onclick="doDelete()">🗑️ ลบเลย</button>
        <button class="btn btn-c" onclick="closeModal('modal-del')">ยกเลิก</button>
      </div>
    </div>
  </div>
</div>

<div id="toast"></div>

<script>
// ══════════════════════════════════════════════
// Token / API
// ══════════════════════════════════════════════
const _baked = '%%BAKED_TOKEN%%';
// sanitize: เก็บเฉพาะ hex chars [0-9a-f] ป้องกัน non-ASCII ใน headers
function _cleanToken(t) {
  if (!t) return '';
  // ลอง hex เท่านั้นก่อน (openssl rand -hex 16 ให้ hex เสมอ)
  const hex = t.replace(/[^0-9a-zA-Z_\-]/g, '').trim();
  return hex;
}
let TOKEN = _cleanToken(
  new URLSearchParams(location.search).get('token')
  || (_baked && !_baked.startsWith('%%') ? _baked : '')
  || document.cookie.match(/token=([^;]+)/)?.[1] || ''
);

let _tokenPromise = null;
async function ensureToken() {
  if (TOKEN) return TOKEN;
  // TOKEN ควรได้จาก _baked หรือ ?token= URL เท่านั้น
  // ไม่ auto-fetch /api/token เพราะต้องใช้ master password
  console.warn('No token found — use ?token=<token> in URL or re-open from dashboard link');
  return null;
}

// sanitize token — เก็บเฉพาะ printable ASCII (hex token จาก openssl rand -hex 16)
function _safeToken(t) {
  if (!t) return '';
  // กรองเอาเฉพาะ ASCII printable ป้องกัน non ISO-8859-1 error
  return t.replace(/[^ -~]/g, '').trim();
}

async function api(method, path, body=null) {
  const rawTok = await ensureToken();
  const tok = _safeToken(rawTok);

  const headers = {'Content-Type': 'application/json'};

  if (tok) {
    // X-Token: custom header — ไม่มีข้อจำกัด encoding
    headers['X-Token'] = tok;
    headers['X-Auth-Token'] = tok;
    // Authorization header: ต้องเป็น ISO-8859-1 เท่านั้น
    // ตรวจสอบก่อนใส่ — ถ้ามี non-ASCII ข้าม
    const isAsciiOnly = /^[\x20-\x7E]*$/.test('Bearer ' + tok);
    if (isAsciiOnly) {
      headers['Authorization'] = 'Bearer ' + tok;
    }
  }

  const opts = {method, headers};
  if (body !== null) opts.body = JSON.stringify(body);

  // เพิ่ม token ใน query string เป็น fallback สุดท้าย
  const url = '/sshws-api' + path + (tok ? (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(tok) : '');

  try {
    const r = await fetch(url, opts);
    if (!r.ok && r.status === 401) {
      toast('Token ไม่ถูกต้อง', false);
      return {error: 'unauthorized'};
    }
    const ct = r.headers.get('content-type') || '';
    if (ct.includes('application/json')) return await r.json();
    const text = await r.text();
    try { return JSON.parse(text); } catch(e) { return {error: 'invalid json', raw: text.slice(0,200)}; }
  } catch(e) {
    console.error('API error:', path, e.message);
    return {error: e.message};
  }
}

// ══════════════════════════════════════════════
// Clock
// ══════════════════════════════════════════════
function updateClock() {
  document.getElementById('clock-txt').textContent =
    new Date().toLocaleTimeString('th-TH',{hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false});
}
setInterval(updateClock, 1000);

// ══════════════════════════════════════════════
// Toast / Alert
// ══════════════════════════════════════════════
let _toastT;
function toast(msg, ok=true) {
  try {
    const t = document.getElementById('toast');
    if (!t) return;
    t.textContent = (ok ? '✅ ' : '❌ ') + msg;
    t.className = 'show' + (ok ? '' : ' err');
    clearTimeout(_toastT);
    _toastT = setTimeout(() => { if(t) t.classList.remove('show'); }, 2800);
  } catch(e) { console.log('toast:', msg); }
}
// alias
function showToast(msg, ok=true) { toast(msg, ok); }
function showAlert(id, msg, ok=true) {
  const el = document.getElementById(id);
  el.textContent = (ok ? '✅ ' : '❌ ') + msg;
  el.className = 'alert show ' + (ok ? 'alert-ok' : 'alert-err');
  setTimeout(() => el.classList.remove('show'), 4000);
}

// ══════════════════════════════════════════════
// UI helpers
// ══════════════════════════════════════════════
function showTab(name, btn) {
  if (name !== 'online' && _trafAnimReq) { cancelAnimationFrame(_trafAnimReq); _trafAnimReq = null; }
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.getElementById('page-'+name).classList.add('active');
  btn.classList.add('active');
  if (name==='dashboard') loadDashboard();
  else if (name==='users')    loadUsers();
  else if (name==='online')   loadOnline();
  else if (name==='banned')   loadBanned();
  else if (name==='services') loadServices();
}
function openModal(id)  { document.getElementById(id).classList.add('open'); }
function closeModal(id) { document.getElementById(id).classList.remove('open'); }
document.querySelectorAll('.modal-bg').forEach(el =>
  el.addEventListener('click', e => { if(e.target===el) el.classList.remove('open'); }));

function svcBadge(active) {
  return '<span class="bd"></span>' + (active ? 'RUNNING' : 'STOPPED');
}
function setSvcBadge(id, active) {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = 'svc-badge ' + (active ? 'on' : 'off');
  el.innerHTML = svcBadge(active);
}

// ══════════════════════════════════════════════
// Dashboard
// ══════════════════════════════════════════════
let _serverHost = '';

async function loadDashboard() {
  const s = await api('GET', '/api/status');
  if (!s.error) {
    const sv = s.services || {};
    ['sshws','dropbear','nginx','badvpn','tunnel','ssl443'].forEach(k => {
      setSvcBadge('svc-'+k, sv[k]);
    });
    // รองรับ field name หลายรูปแบบที่ API อาจส่งมา
    const conns  = s.connections  ?? s.conn_total  ?? s.total_connections ?? '-';
    const online = s.online_count ?? s.online       ?? s.online_users     ?? '-';
    const users  = s.total_users  ?? s.user_count   ?? s.users_count      ?? '-';
    const setText = (id, val) => { const el = document.getElementById(id); if(el) el.textContent = val; };
    setText('stat-conns',  conns);
    setText('stat-online', online);
    setText('stat-users',  users);
    setText('stat-vless',  s.vless_count ?? '-');
    // conn bars
    const ports = {
      '80':  s.conn_80  ?? s.connections_80  ?? 0,
      '143': s.conn_143 ?? s.connections_143 ?? 0,
      '109': s.conn_109 ?? s.connections_109 ?? 0,
      '22':  s.conn_22  ?? s.connections_22  ?? 0
    };
    const max = Math.max(...Object.values(ports), 1);
    const _bwLevel = (v, mx) => {
      const pct = v / mx;
      if (pct >= 0.7)  return ['lv-high',   '🔴 HIGH'];
      if (pct >= 0.35) return ['lv-medium', '🟡 MED'];
      return ['lv-normal', '🟢 NORMAL'];
    };
    Object.entries(ports).forEach(([p, v]) => {
      const bn = document.getElementById('b'+p);
      const bf = document.getElementById('bf'+p);
      const bl = document.getElementById('bl'+p);
      if (bn) bn.textContent = v;
      if (bf) bf.style.width = Math.round(v/max*100)+'%';
      if (bl) { const [cls,lbl] = _bwLevel(v, max); bl.className='bw-level '+cls; bl.textContent=lbl; }
    });
  } else {
    console.warn('Dashboard status error:', s.error);
  }
  const info = await api('GET', '/api/info');
  if (!info.error) {
    _serverHost = info.host || location.hostname;
    const setText = (id, val) => { const el = document.getElementById(id); if(el) el.textContent = val; };
    setText('server-ip',  _serverHost);
    setText('stat-port',  info.ws_port || '80');
    const host     = info.host        || location.hostname;
    const wsPort   = info.ws_port     || '80';
    const dbPort   = info.dropbear_port  || '143';
    const dbPort2  = info.dropbear_port2 || '109';
    const udpgwP   = info.udpgw_port  || '7300';
    const connInfo = document.getElementById('conn-info');
    if (connInfo) connInfo.innerHTML = `
      <div class="cfg-row"><span class="cfg-k">🌍 Host</span><span class="cfg-v">${host}</span></div>
      <div class="cfg-row"><span class="cfg-k">🔌 WS Port</span><span class="cfg-v">${wsPort}</span></div>
      <div class="cfg-row"><span class="cfg-k">🐻 Dropbear</span><span class="cfg-v">${dbPort} / ${dbPort2}</span></div>
      <div class="cfg-row"><span class="cfg-k">🎮 UDPGW</span><span class="cfg-v">127.0.0.1:${udpgwP}</span></div>
      <div class="cfg-row"><span class="cfg-k">📡 Payload</span><span class="cfg-v" style="font-size:.58rem">GET / HTTP/1.1 · Host:${host} · Upgrade:websocket</span></div>`;
  } else {
    // Fallback: ดึง host จาก URL
    _serverHost = location.hostname;
    const si = document.getElementById('server-ip');
    if (si) si.textContent = _serverHost;
  }
}

async function svcAction(action) {
  toast('กำลัง '+action+'...');
  const r = await api('POST', '/api/service', {action});
  toast(r.result || r.error, !r.error);
  setTimeout(loadDashboard, 1500);
  setTimeout(loadServices, 1500);
}

async function svc1(svc, action) {
  const r = await api('POST', '/api/service1', {service:svc, action});
  toast(r.result || r.error, r.ok);
  setTimeout(loadServices, 1200);
  setTimeout(loadDashboard, 1200);
}

async function restartUdpgw() {
  const r = await api('POST', '/api/udpgw', {action:'restart'});
  toast(r.result || r.error, r.ok);
  setTimeout(loadDashboard, 1500);
}

async function genToken() {
  const r = await api('POST', '/api/token/regenerate', {});
  if (r.ok && r.token) {
    TOKEN = r.token;
    toast('\u2705 Token \u0e43\u0e2b\u0e21\u0e48\u0e2a\u0e33\u0e40\u0e23\u0e47\u0e08 \u0e01\u0e33\u0e25\u0e31\u0e07 reload...');
    setTimeout(() => {
      const u = new URL(location.href);
      u.searchParams.set('token', r.token);
      location.replace(u.toString());
    }, 1200);
  } else {
    toast('\u274c \u0e2a\u0e23\u0e49\u0e32\u0e07 Token \u0e25\u0e49\u0e21\u0e40\u0e2b\u0e25\u0e27: ' + (r.error || 'unknown'), false);
  }
}

// ══════════════════════════════════════════════
// App Selector / Import Link
// ══════════════════════════════════════════════
const PROS = {
  dtac: {name:'DTAC GAMING', proxy:'104.18.63.124:80',
    payload:'CONNECT /  HTTP/1.1 [crlf]Host: dl.dir.freefiremobile.com [crlf][crlf]PATCH / HTTP/1.1[crlf]Host:[host][crlf]Upgrade:User-Agent: [ua][crlf][crlf]',
    darkProxy:'104.18.63.124', darkProxyPort:80},
  true: {name:'TRUE TWITTER', proxy:'104.18.39.24:80',
    payload:'POST / HTTP/1.1[crlf]Host: help.x.com[crlf]User-Agent: [ua][crlf][crlf][split][cr]PATCH / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
    darkProxy:'104.18.39.24', darkProxyPort:80}
};
const NPV_HOST=location.hostname, NPV_PORT=80;
let _curPro='dtac', _curApp='npv';

function selPro(p) {
  _curPro = p;
  document.getElementById('cu-pro-dtac').className='pick-opt'+(p==='dtac'?' a-dtac':'');
  document.getElementById('cu-pro-true').className='pick-opt'+(p==='true'?' a-true':'');
}
function selApp(a) {
  _curApp = a;
  document.getElementById('cu-app-npv').className='pick-opt'+(a==='npv'?' a-npv':'');
  document.getElementById('cu-app-dark').className='pick-opt'+(a==='dark'?' a-dark':'');
}

function buildNpvLink(name, pass, pro) {
  const j={sshConfigType:'SSH-Proxy-Payload',remarks:pro.name+'-'+name,sshHost:NPV_HOST,sshPort:NPV_PORT,sshUsername:name,sshPassword:pass,sni:'',tlsVersion:'DEFAULT',httpProxy:pro.proxy,authenticateProxy:false,proxyUsername:'',proxyPassword:'',payload:pro.payload,dnsTTMode:'UDP',dnsServer:'',nameserver:'',publicKey:'',udpgwPort:7300,udpgwTransparentDNS:true};
  return 'npvt-ssh://'+btoa(unescape(encodeURIComponent(JSON.stringify(j))));
}
function buildDarkLink(name, pass, pro) {
  const j = {
    type: 'SSH',
    name: pro.name + '-' + name,
    sshTunnelConfig: {
      sshConfig: {
        host: NPV_HOST,
        port: NPV_PORT,
        username: name,
        password: pass
      },
      injectConfig: {
        mode: 'PROXY',
        proxyHost: pro.darkProxy || '',
        proxyPort: pro.darkProxyPort || 80,
        payload: pro.payload || ''
      }
    }
  };
  return 'darktunnel://' + btoa(unescape(encodeURIComponent(JSON.stringify(j))));
}
function copyToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => toast('📋 คัดลอกแล้ว!')).catch(() => { _copyFallback(text); });
  } else { _copyFallback(text); }
}
function _copyFallback(text) {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0;';
  document.body.appendChild(ta);
  ta.focus(); ta.select();
  try { document.execCommand('copy'); toast('📋 คัดลอกแล้ว!'); }
  catch(e) { toast('❌ คัดลอกไม่ได้', false); }
  document.body.removeChild(ta);
}

async function genImportLink() {
  const r = await api('GET', '/api/users');
  if (r.error || !r.users || !r.users.length) { toast('ไม่มี users', false); return; }
  const u = r.users[0];
  const pro = PROS[_curPro] || PROS.dtac;
  const link = _curApp==='npv' ? buildNpvLink(u.user, u.pass||'', pro) : buildDarkLink(u.user, u.pass||'', pro);
  const isNpv = _curApp==='npv';
  window._impLink = link;
  document.getElementById('cu-link-result').className='imp-result show';
  document.getElementById('cu-link-result').innerHTML=`
    <div style="display:flex;align-items:center;gap:.4rem;margin-bottom:.4rem">
      <span class="imp-badge ${_curApp}">${isNpv?'Npv Tunnel':'DarkTunnel'}</span>
      <span style="font-size:.65rem;color:var(--muted)">${pro.name} · ${u.user}</span>
    </div>
    <div class="link-preview ${isNpv?'':'dark-lp'}">${link}</div>
    <button class="copy-link-btn ${_curApp}" onclick="copyToClipboard(window._impLink)">📋 คัดลอก Link</button>`;
}

// ══════════════════════════════════════════════
// Users
// ══════════════════════════════════════════════
let _allUsers = [];

async function loadUsers() {
  const r = await api('GET', '/api/users');
  if (r.error || !r.users) {
    document.getElementById('user-tbody').innerHTML=`<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:2rem">${r.error||'ไม่มีข้อมูล'}</td></tr>`;
    return;
  }
  _allUsers = r.users;
  renderUserTable(_allUsers);
  document.getElementById('stat-users').textContent = _allUsers.length;
}

function renderUserTable(users) {
  const today = new Date().toISOString().split('T')[0];
  document.getElementById('user-tbody').innerHTML = users.map((u,i) => {
    const expired = u.exp && u.exp < today;
    const badge = u.active && !expired ? '<span class="bdg bdg-g">ACTIVE</span>'
      : expired ? '<span class="bdg bdg-r">EXPIRED</span>'
      : '<span class="bdg bdg-y">INACTIVE</span>';
    let _daysLeft = '∞', _dColor = 'var(--green)', _dTitle = 'ไม่จำกัด';
    if (u.exp) {
      const _diff = Math.ceil((new Date(u.exp) - new Date(today)) / 86400000);
      if (_diff > 3) { _daysLeft = _diff+'d'; _dColor = 'var(--green)'; _dTitle = 'คงเหลือ '+_diff+' วัน'; }
      else if (_diff > 0) { _daysLeft = _diff+'d'; _dColor = 'var(--yellow,#f5c518)'; _dTitle = 'คงเหลือ '+_diff+' วัน (ใกล้หมด!)'; }
      else if (_diff === 0) { _daysLeft = 'วันนี้'; _dColor = 'var(--orange,#ff8c00)'; _dTitle = 'หมดอายุวันนี้!'; }
      else { _daysLeft = 'หมด'; _dColor = 'var(--red)'; _dTitle = 'หมดอายุแล้ว '+Math.abs(_diff)+' วัน'; }
    }
    return `<tr><td>${i+1}</td><td><b>${u.user}</b></td><td style="color:${expired?'var(--red)':'var(--green)'}">${u.exp||'N/A'}</td><td>${badge}</td>
      <td><div style="display:flex;gap:4px">
        <button class="btn btn-c btn-sm" onclick="openRenew('${u.user}')">🔄</button>
        <button class="btn btn-r btn-sm" onclick="confirmDel('${u.user}')">🗑️</button>
        <button class="btn btn-y btn-sm" title="${_dTitle}" onclick="showDaysLeft('${u.user}',${JSON.stringify(u.exp||'')},${JSON.stringify(_dTitle)})" style="font-size:.7rem;font-weight:700;min-width:44px;padding:2px 4px;color:${_dColor};border-color:${_dColor}">${_daysLeft}</button>
      </div></td></tr>`;
  }).join('') || `<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:2rem">ยังไม่มี Users</td></tr>`;
}

function filterUsers() {
  const q = document.getElementById('search-u').value.toLowerCase();
  renderUserTable(_allUsers.filter(u => u.user.toLowerCase().includes(q)));
}

let _cuPro='dtac', _cuApp='npv';
function cuSelPro(p) {
  _cuPro=p;
  document.getElementById('cu-pro-dtac').className='pick-opt'+(p==='dtac'?' a-dtac':'');
  document.getElementById('cu-pro-true').className='pick-opt'+(p==='true'?' a-true':'');
  clearCreateLink();
}
function cuSelApp(a) {
  _cuApp=a;
  document.getElementById('cu-app-npv').className='pick-opt'+(a==='npv'?' a-npv':'');
  document.getElementById('cu-app-dark').className='pick-opt'+(a==='dark'?' a-dark':'');
  clearCreateLink();
}
function clearCreateLink() {
  const el=document.getElementById('cu-link-result');
  if(el){el.className='imp-result';el.innerHTML='';}
}
async function createUserAndLink() {
  const user=document.getElementById('new-user').value.trim();
  const pass=document.getElementById('new-pass').value.trim();
  const exp=parseInt(document.getElementById('new-exp').value||30);
  const ipl=parseInt(document.getElementById('new-iplimit').value||2);
  if(!user||!pass) return showAlert('alert-create','กรอก username/password ด้วย',false);
  showAlert('alert-create','⏳ กำลังสร้าง...', true);
  const r=await api('POST','/api/create',{user,pass,exp_days:exp,ip_limit:ipl});
  if(!r.ok){showAlert('alert-create',r.error||'ล้มเหลว',false);return;}
  showAlert('alert-create',`✅ สร้าง ${user} สำเร็จ`, true);
  loadUsers();
  const pro=PROS[_cuPro]||PROS.dtac;
  const link=_cuApp==='npv'?buildNpvLink(user,pass,pro):buildDarkLink(user,pass,pro);
  const isNpv=_cuApp==='npv';
  window._cuLink = link;
  const el=document.getElementById('cu-link-result');
  el.className='imp-result show';
  el.innerHTML=`
    <div style='display:flex;align-items:center;gap:.4rem;margin:.7rem 0 .3rem'>
      <span class='imp-badge ${_cuApp}'>${isNpv?'Npv Tunnel':'DarkTunnel'}</span>
      <span style='font-size:.65rem;color:var(--muted)'>${pro.name} · ${user}</span>
    </div>
    <div class='link-preview ${isNpv?'':'dark-lp'}'>${link}</div>
    <button class='copy-link-btn ${_cuApp}' onclick='copyToClipboard(window._cuLink)'>📋 คัดลอกลิงค์ใส่แอพ</button>
  `;
}

function openRenew(u) {
  document.getElementById('renew-username').value=u;
  document.getElementById('renew-show').value=u;
  openModal('modal-renew');
}
async function doRenew() {
  const u=document.getElementById('renew-username').value;
  const d=parseInt(document.getElementById('renew-days').value||30);
  const r=await api('POST','/api/renew',{user:u,days:d});
  toast(r.ok?`ต่ออายุ ${u} +${d} วัน`:(r.error||'ล้มเหลว'), r.ok);
  closeModal('modal-renew'); if(r.ok) loadUsers();
}

function confirmDel(u) {
  document.getElementById('del-username').textContent=u;
  document.getElementById('del-username').dataset.u=u;
  openModal('modal-del');
}
async function doDelete() {
  const u=document.getElementById('del-username').dataset.u;
  const r=await api('POST','/api/delete',{user:u});
  toast(r.ok?`ลบ ${u} สำเร็จ`:(r.error||'ล้มเหลว'), r.ok);
  closeModal('modal-del'); if(r.ok) loadUsers();
}

async function kickUser(u) {
  const r=await api('POST','/api/kick',{user:u});
  toast(r.ok?`Kick ${u} แล้ว`:(r.error||'ล้มเหลว'), r.ok);
}

function showDaysLeft(username, expDate, msg) {
  const _icon = msg.includes('หมดอายุแล้ว') ? '🔴'
    : msg.includes('ใกล้หมด') || msg.includes('วันนี้') ? '🟡' : '🟢';
  toast(`${_icon} ${username}: ${msg}`, !msg.includes('หมดอายุแล้ว'));
}


// ══════════════════════════════════════════════
// Online
// ══════════════════════════════════════════════
const _traf={labels:[],total:[],prev:[],next:null,lerpT0:null,maxPts:30};
const LERP_MS=600;
const _lerp=(a,b,t)=>a+(b-a)*t;
const _fmtBytes=(b)=>{if(b<1024)return b+' B';if(b<1048576)return (b/1024).toFixed(1)+' KB';if(b<1073741824)return (b/1048576).toFixed(2)+' MB';return (b/1073741824).toFixed(3)+' GB';};

async function loadOnline() {
  const r=await api('GET','/api/online');
  const el=document.getElementById('online-list');
  const now=new Date().toLocaleTimeString('th-TH');
  if(r.error||!r.connections){el.innerHTML=`<div style="text-align:center;color:var(--muted);padding:2rem">${r.error||'ไม่มีข้อมูล'}</div>`;return;}
  if(!r.connections.length){el.innerHTML=`<div style="text-align:center;color:var(--muted);padding:2rem">ไม่มี Online ขณะนี้<br><span style="font-size:.68rem;opacity:.4">อัพเดท ${now}</span></div>`;return;}
  const ur=await api('GET','/api/users'); const uMap={};
  if(!ur.error&&ur.users) ur.users.forEach(u=>{uMap[u.user]=u;});
  el.innerHTML=`<div style="font-size:.68rem;color:var(--muted);text-align:right;margin-bottom:.4rem">🟢 ${r.connections.length} คน · ${now}</div>`+
    `<div style="display:flex;flex-direction:column;gap:.35rem">`+
    r.connections.map((c)=>{
      const un=c.user||''; const u=uMap[un]||{}; const _un=un||'—';
      const exp=u.exp&&u.exp<new Date().toISOString().split('T')[0];
      return `<div style="display:flex;align-items:center;gap:.65rem;background:var(--bg2);border-radius:.55rem;padding:.5rem .75rem;border:1px solid rgba(77,255,160,.08)">
        <span style="width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 7px var(--green);flex-shrink:0;animation:blink 1.4s infinite"></span>
        <span style="font-weight:700;font-size:.85rem;flex:1">${_un}</span>
        <span style="font-size:.65rem;color:var(--muted);font-family:monospace">${c.remote||''}</span>
        ${u.exp?`<span style="font-size:.68rem;color:${exp?'var(--red)':'rgba(0,220,100,.5)'}">${exp?'หมดอายุ':u.exp}</span>`:''}
        <span class="bdg bdg-g" style="font-size:.62rem">:${c.port||'—'}</span>
      </div>`;
    }).join('')+`</div>`;
  if(!_trafAnimReq) _trafLoop(); _updateTraf();
}

function _trafLoop() {
  // div-based bar chart — no animation frame loop needed
  // rendering happens directly in _drawTraf on data update
}

// ── canvas bar chart renderer ──────────────────────────
let _trafAnimReq = null;
let _trafCurrent = [];   // ค่าที่กำลังแสดงอยู่ (lerp target)
let _trafDisplayed = []; // ค่าที่ animate ไปแล้ว
const _LERP_SPEED = 0.12; // 0-1 ยิ่งต่ำยิ่ง smooth

function _drawTraf(pts) {
  if (!pts || pts.length < 1) return;
  const MAX = 20; // จำนวนแท่งสูงสุด
  _trafCurrent = pts.slice(-MAX);
  // init displayed ถ้ายังไม่มี
  if (_trafDisplayed.length !== _trafCurrent.length) {
    _trafDisplayed = _trafCurrent.map(() => 0);
  }
  // เริ่ม animation loop ถ้ายังไม่รัน
  if (!_trafAnimReq) _trafAnimFrame();
  // อัพเดท time labels
  const lblEl = document.getElementById('traf-time-labels');
  if (lblEl && _traf.labels.length) {
    const sl = _traf.labels.slice(-MAX);
    const step = Math.max(1, Math.floor(sl.length / 4));
    const idxs = [];
    for (let i = 0; i < sl.length; i += step) idxs.push(i);
    if (idxs[idxs.length-1] !== sl.length-1) idxs.push(sl.length-1);
    lblEl.innerHTML = idxs.map(i => `<span>${sl[i]||''}</span>`).join('');
  }
}

function _trafAnimFrame() {
  const cv = document.getElementById('traf-canvas');
  if (!cv) { _trafAnimReq = null; return; }

  // lerp displayed → current
  let allDone = true;
  for (let i = 0; i < _trafCurrent.length; i++) {
    const target = _trafCurrent[i] || 0;
    const cur = _trafDisplayed[i] || 0;
    const next = _lerp(cur, target, _LERP_SPEED);
    _trafDisplayed[i] = next;
    if (Math.abs(next - target) > target * 0.002 + 1) allDone = false;
  }

  // วาด
  const dpr = window.devicePixelRatio || 1;
  const W = cv.parentElement.offsetWidth || 300;
  const H = cv.parentElement.offsetHeight || 90;
  cv.width = W * dpr; cv.height = H * dpr;
  cv.style.width = W + 'px'; cv.style.height = H + 'px';
  const ctx = cv.getContext('2d');
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, W, H);

  const pts = _trafDisplayed;
  const n = pts.length;
  if (n < 1) { _trafAnimReq = allDone ? null : requestAnimationFrame(_trafAnimFrame); return; }

  // scale — ใช้ค่า current จริง (ไม่ใช่ displayed) เพื่อกัน bar เกิน
  const mx = Math.max(..._trafCurrent) || 1;
  const PAD_T = 6, PAD_B = 2, PAD_LR = 2;
  const gW = W - PAD_LR * 2;
  const gH = H - PAD_T - PAD_B;
  const barW = Math.max(3, Math.floor((gW - (n-1)*5) / n / 2));
  const gap = n > 1 ? (gW - barW * n) / (n - 1) : 0;

  pts.forEach((v, i) => {
    const ratio = Math.min(1, (v || 0) / mx);
    const bH = Math.max(2, ratio * gH);
    const x = PAD_LR + i * (barW + gap);
    const y = PAD_T + gH - bH;

    // gradient fill
    const grad = ctx.createLinearGradient(0, y, 0, y + bH);
    grad.addColorStop(0, 'rgba(0,232,255,0.9)');
    grad.addColorStop(1, 'rgba(0,180,220,0.15)');
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.roundRect(x, y, barW, bH, [3, 3, 0, 0]);
    ctx.fill();

    // glow top edge
    ctx.save();
    ctx.shadowColor = '#00e8ff';
    ctx.shadowBlur = 8;
    ctx.fillStyle = 'rgba(0,232,255,0.95)';
    ctx.fillRect(x, y, barW, 2);
    ctx.restore();
  });

  _trafAnimReq = allDone ? null : requestAnimationFrame(_trafAnimFrame);
}

async function _updateTraf() {
  const r=await api('GET','/api/status'); if(r.error)return;
  const rx=(r.rx_bytes||r.traffic?.rx_bytes||0);
  const tx=(r.tx_bytes||r.traffic?.tx_bytes||0);
  const total=rx+tx;
  const now=new Date().toLocaleTimeString('th-TH',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
  _traf.labels.push(now); _traf.total.push(total);
  if(_traf.labels.length>_traf.maxPts){_traf.labels.shift();_traf.total.shift();}
  const elUp=document.getElementById('traf-up'); if(elUp) elUp.textContent=_fmtBytes(tx);
  const elDn=document.getElementById('traf-dn'); if(elDn) elDn.textContent=_fmtBytes(rx);
  const el=document.getElementById('traf-total'); if(el) el.textContent=_fmtBytes(total);
  const u=document.getElementById('traf-upd'); if(u) u.textContent='อัพเดท '+now;
  if(_traf.total.length>=1) _drawTraf(_traf.total);
}

// ══════════════════════════════════════════════
// Banned
// ══════════════════════════════════════════════
async function loadBanned() {
  const r=await api('GET','/api/bans'); const el=document.getElementById('banned-list');
  if(r.error){el.innerHTML=`<div style="text-align:center;color:var(--muted);padding:2rem">${r.error}</div>`;return;}
  const bans=r.bans||{}; const keys=Object.keys(bans);
  let count=keys.length; document.getElementById('stat-banned').textContent=count;
  if(!keys.length){el.innerHTML=`<div style="text-align:center;color:var(--muted);padding:2rem">ไม่มี IP ที่ถูกแบน ✅</div>`;return;}
  const _esc=s=>String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
  el.innerHTML=`<div class="tbl-wrap"><table><thead><tr><th>User/IP</th><th>เหตุผล</th><th>หมดแบน</th><th></th></tr></thead><tbody>`+
    keys.map(k=>{const b=bans[k];
      const safeK=_esc(k), safeUser=_esc(b.user||k), safeIp=_esc(b.ip||( b.ips?b.ips.join(', '):k)), safeReason=_esc(b.reason||'IP limit'), safeUntil=_esc(b.until||'12h');
      const safeKAttr=encodeURIComponent(k), safeNameAttr=encodeURIComponent(b.name||b.user||'');
      return `<tr><td><b>${safeUser}</b><br><span style="color:var(--muted);font-size:.68rem">${safeIp}</span></td><td><span class="bdg bdg-r">${safeReason}</span></td><td style="font-size:.72rem">${safeUntil}</td><td><button class="btn btn-g btn-sm" onclick="unban(decodeURIComponent('${safeKAttr}'),decodeURIComponent('${safeNameAttr}'))">&#x1f513;</button></td></tr>`;
    }).join('')+`</tbody></table></div>`;
}

async function unban(uid, name) {
  const r=await api('POST','/api/unban',{uid,name});
  toast(r.ok?'ปลดแบนสำเร็จ':(r.error||'ล้มเหลว'), r.ok);
  if(r.ok) loadBanned();
}

// ══════════════════════════════════════════════
// Services
// ══════════════════════════════════════════════
async function loadServices() {
  const s=await api('GET','/api/status'); if(s.error)return;
  const sv=s.services||{};
  ['sshws','dropbear','nginx','badvpn'].forEach(k=>{
    setSvcBadge('svc-'+k, sv[k]);
    const el=document.getElementById('s2-'+k);
    if(el) el.innerHTML=(sv[k]?'<span class="bdg bdg-g">RUNNING</span>':'<span class="bdg bdg-r">STOPPED</span>');
  });
}

// ══════════════════════════════════════════════
// Backup / Import
// ══════════════════════════════════════════════
async function backupUsers() {
  const r=await api('GET','/api/users'); if(r.error||!r.users) return toast('backup ล้มเหลว',false);
  const blob=new Blob([JSON.stringify({users:r.users,backup_date:new Date().toISOString()},null,2)],{type:'application/json'});
  const a=document.createElement('a'); a.href=URL.createObjectURL(blob);
  a.download=`chaiya-backup-${new Date().toISOString().split('T')[0]}.json`; a.click();
  toast('Backup สำเร็จ!');
}

async function importUsers() {
  const file=document.getElementById('import-file').files[0];
  if(!file) return showAlert('alert-import','กรุณาเลือกไฟล์',false);
  try {
    const data=JSON.parse(await file.text());
    const users=data.users||(Array.isArray(data)?data:null);
    if(!users) return showAlert('alert-import','รูปแบบไม่ถูกต้อง',false);
    const r=await api('POST','/api/import',{users});
    if(r.error) return showAlert('alert-import',r.error,false);
    showAlert('alert-import',`Import สำเร็จ: สร้าง ${r.created?.length||0} / อัพเดท ${r.updated?.length||0}`);
    document.getElementById('import-result').style.display='block';
    document.getElementById('import-result').innerHTML=`<span style="color:var(--green)">สร้างใหม่: ${(r.created||[]).join(', ')||'-'}</span><br><span style="color:var(--yellow)">อัพเดท: ${(r.updated||[]).join(', ')||'-'}</span>`;
    loadUsers();
  } catch(e){showAlert('alert-import','ไฟล์ JSON ไม่ถูกต้อง',false);}
}

// ══════════════════════════════════════════════
// Init + Auto-refresh
// ══════════════════════════════════════════════
document.addEventListener('DOMContentLoaded', async () => {
  updateClock();
  await ensureToken();
  loadDashboard();
  initStars();
});
setInterval(()=>{ const a=document.querySelector('.page.active')?.id; if(a==='page-dashboard') loadDashboard(); }, 15000);
setInterval(()=>{ const a=document.querySelector('.page.active')?.id; if(a==='page-online'){loadOnline();_updateTraf();} }, 5000);

// ══════════════════════════════════════════════
// Shooting Stars — ช้า สวย เห็นชัด
// ══════════════════════════════════════════════
function initStars(){
  const cv=document.getElementById('stars-canvas');
  if(!cv) return;
  const ctx=cv.getContext('2d');
  let W,H;
  function resize(){W=cv.width=window.innerWidth;H=cv.height=window.innerHeight;}
  resize(); window.addEventListener('resize',resize);

  // ดาวพื้นหลัง 180 ดวง กระพริบช้าๆ
  const bgStars=Array.from({length:180},()=>({
    x:Math.random()*window.innerWidth,
    y:Math.random()*window.innerHeight,
    r:Math.random()*1.6+0.4,
    phase:Math.random()*Math.PI*2,
    speed:Math.random()*0.35+0.15,
    baseA:Math.random()*0.45+0.35
  }));

  const meteors=[];
  const PALETTE=[
    {r:255,g:255,b:255},
    {r:128,g:255,b:221},
    {r:184,g:160,b:255},
    {r:77,g:255,b:160},
    {r:255,g:230,b:128},
  ];

  function spawn(){
    const col=PALETTE[Math.floor(Math.random()*PALETTE.length)];
    const spd=Math.random()*3+2;   // ช้า: 2–5 px/frame
    const ang=Math.PI/5+(Math.random()-0.5)*0.12;
    meteors.push({
      x:Math.random()*W*1.2-W*0.1,
      y:Math.random()*H*0.38-20,
      vx:Math.cos(ang)*spd,
      vy:Math.sin(ang)*spd,
      len:Math.random()*150+90,
      col,
      life:1.0,
      decay:Math.random()*0.004+0.003,  // จางช้า — อยู่นาน
      width:Math.random()*1.2+1.2
    });
  }

  spawn(); spawn();
  // spawn ทุก 2–5 วิ
  (function go(){ spawn(); setTimeout(go, Math.random()*3000+2000); })();

  function draw(ts){
    ctx.clearRect(0,0,W,H);

    // วาดดาวพื้นหลัง
    bgStars.forEach(s=>{
      const a=s.baseA*(0.55+0.45*Math.sin(ts*0.001*s.speed+s.phase));
      ctx.save();
      ctx.globalAlpha=a;
      ctx.beginPath(); ctx.arc(s.x,s.y,s.r,0,Math.PI*2);
      ctx.fillStyle='#ffffff';
      if(s.r>1.3){ctx.shadowColor='#80ffdd';ctx.shadowBlur=5;}
      ctx.fill(); ctx.restore();
    });

    // วาดดาวตก
    for(let i=meteors.length-1;i>=0;i--){
      const m=meteors[i];
      const {r,g,b}=m.col;
      const dist=Math.hypot(m.vx,m.vy)||1;
      const nx=m.vx/dist, ny=m.vy/dist;
      const tx=m.x-nx*m.len, ty=m.y-ny*m.len;
      ctx.save();

      // หางหลัก
      const gr=ctx.createLinearGradient(tx,ty,m.x,m.y);
      gr.addColorStop(0,  `rgba(${r},${g},${b},0)`);
      gr.addColorStop(0.5,`rgba(${r},${g},${b},${(m.life*0.4).toFixed(2)})`);
      gr.addColorStop(1,  `rgba(${r},${g},${b},${m.life.toFixed(2)})`);
      ctx.strokeStyle=gr; ctx.lineWidth=m.width;
      ctx.shadowColor=`rgb(${r},${g},${b})`; ctx.shadowBlur=14;
      ctx.beginPath(); ctx.moveTo(tx,ty); ctx.lineTo(m.x,m.y); ctx.stroke();

      // glow ชั้นนอก
      const gr2=ctx.createLinearGradient(tx,ty,m.x,m.y);
      gr2.addColorStop(0,`rgba(${r},${g},${b},0)`);
      gr2.addColorStop(1,`rgba(${r},${g},${b},${(m.life*0.12).toFixed(2)})`);
      ctx.strokeStyle=gr2; ctx.lineWidth=m.width*5; ctx.shadowBlur=28;
      ctx.beginPath(); ctx.moveTo(tx,ty); ctx.lineTo(m.x,m.y); ctx.stroke();

      // หัวดาว
      ctx.globalAlpha=m.life;
      ctx.beginPath(); ctx.arc(m.x,m.y,m.width*1.6,0,Math.PI*2);
      ctx.fillStyle='#ffffff';
      ctx.shadowColor=`rgb(${r},${g},${b})`; ctx.shadowBlur=22;
      ctx.fill();

      // แสงจ้าหัว
      ctx.beginPath(); ctx.arc(m.x,m.y,m.width*3.5,0,Math.PI*2);
      ctx.fillStyle=`rgba(${r},${g},${b},${(m.life*0.2).toFixed(2)})`;
      ctx.shadowBlur=0; ctx.fill();

      ctx.restore();
      m.x+=m.vx; m.y+=m.vy; m.life-=m.decay;
      if(m.life<=0||m.x>W+200||m.y>H+200) meteors.splice(i,1);
    }
    requestAnimationFrame(draw);
  }
  requestAnimationFrame(draw);
}
</script>

</body>
</html>
HTMLEOF

# ── ฝัง token ทันทีหลังสร้าง sshws.html ──────────────────
_SSHWS_TOK_EARLY=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]' || echo "")
if [[ -n "$_SSHWS_TOK_EARLY" ]]; then
  sed -i "s|%%BAKED_TOKEN%%|${_SSHWS_TOK_EARLY}|g" /var/www/chaiya/sshws.html 2>/dev/null || true
  echo "✅ Token ฝังใน sshws.html ทันที: ${_SSHWS_TOK_EARLY}"
fi

# ── ตั้ง permissions ──────────────────────────────────────────
chmod 644 /var/www/chaiya/sshws.html
chown -R www-data:www-data /var/www/chaiya 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
#  chaiya-sshws-api  (Python HTTP API :6789)
# ══════════════════════════════════════════════════════════════
cat > /usr/local/bin/chaiya-sshws-api << 'PYEOF'
#!/usr/bin/env python3
"""
Chaiya SSH-WS HTTP API — port 6789
รองรับ Dropbear user management + badvpn-udpgw
ทุก endpoint เชื่อมกับ HTML dashboard ครบ 100%
"""
import http.server, json, subprocess, os, sys, urllib.parse, hmac, hashlib, time, signal

PORT       = 6789
HOST       = "127.0.0.1"
TOKEN_FILE = "/etc/chaiya/sshws-token.conf"
BAN_FILE   = "/etc/chaiya/iplimit_ban.json"
USERS_DIR  = "/etc/chaiya/sshws-users"
CONF_FILE  = "/etc/chaiya/sshws.conf"
LOG_FILE   = "/var/log/chaiya-sshws.log"

os.makedirs(USERS_DIR, exist_ok=True)

def get_token():
    if os.path.exists(TOKEN_FILE):
        t = open(TOKEN_FILE).read().strip()
        if t: return t
    tok = hashlib.sha256(os.urandom(32)).hexdigest()[:32]
    with open(TOKEN_FILE, "w") as f: f.write(tok)
    return tok

TOKEN = get_token()

def run(cmd, timeout=15):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip(), r.returncode
    except Exception as e:
        return str(e), 1

def load_conf():
    d = {"SSH_PORT":"22","WS_PORT":"80","DROPBEAR_PORT":"143",
         "DROPBEAR_PORT2":"109","USE_DROPBEAR":"1","ENABLED":"1","UDPGW_PORT":"7300"}
    if os.path.exists(CONF_FILE):
        for line in open(CONF_FILE):
            if "=" in line and not line.startswith("#"):
                k,v = line.strip().split("=",1); d[k]=v
    return d

def save_conf(d):
    with open(CONF_FILE,"w") as f:
        for k,v in d.items(): f.write(f"{k}={v}\n")

def load_bans():
    try: return json.load(open(BAN_FILE))
    except: return {}

def save_bans(b):
    json.dump(b, open(BAN_FILE,"w"), indent=2, ensure_ascii=False)

import re as _re_user
def validate_username(u):
    """อนุญาตเฉพาะ a-z0-9 _ - และความยาว 1-32 — ป้องกัน command injection"""
    return bool(u and _re_user.match(r'^[a-z0-9_-]{1,32}$', u))

def _fetch_xui_traffic_map():
    """ดึง traffic ทั้งหมดจาก x-ui — dict {email: (used_gb, limit_gb)}
    วิธี 1: อ่านจาก clientStats ใน /inbounds/list (รวดเร็ว)
    วิธี 2: per-email /getClientTrafficByEmail/{email} (fallback สำหรับ x-ui version ใหม่)
    """
    import urllib.request as _ureq, urllib.parse as _up, http.cookiejar as _cj
    traffic_map = {}
    try:
        xp  = open("/etc/chaiya/xui-port.conf").read().strip() if os.path.exists("/etc/chaiya/xui-port.conf") else "2053"
        xu  = open("/etc/chaiya/xui-user.conf").read().strip() if os.path.exists("/etc/chaiya/xui-user.conf") else "admin"
        xpw = open("/etc/chaiya/xui-pass.conf").read().strip() if os.path.exists("/etc/chaiya/xui-pass.conf") else ""
        xbp = open("/etc/chaiya/xui-basepath.conf").read().strip().rstrip("/") if os.path.exists("/etc/chaiya/xui-basepath.conf") else ""
        for _proto in ("https", "http"):
            try:
                _base = f"{_proto}://127.0.0.1:{xp}{xbp}"
                cj = _cj.CookieJar()
                import ssl as _ssl; _ctx = _ssl.create_default_context(); _ctx.check_hostname = False; _ctx.verify_mode = _ssl.CERT_NONE; opener = _ureq.build_opener(_ureq.HTTPCookieProcessor(cj), _ureq.HTTPSHandler(context=_ctx))
                login_data = _up.urlencode({"username": xu, "password": xpw}).encode()
                req = _ureq.Request(f"{_base}/login", data=login_data)
                req.add_header("Content-Type", "application/x-www-form-urlencoded")
                if '"success":true' not in opener.open(req, timeout=5).read().decode():
                    continue

                # ดึง inbound list — ใช้สำหรับ limit (totalGB) และ clientStats
                tresp = opener.open(_ureq.Request(f"{_base}/panel/api/inbounds/list"), timeout=8)
                tdata = json.loads(tresp.read().decode())
                if not tdata.get("success"):
                    continue

                # รวบรวม email ทั้งหมดและ limit จาก settings.clients[]
                all_emails   = {}  # email -> limit_gb
                for ib in tdata.get("obj", []):
                    try:
                        for cl in json.loads(ib.get("settings","{}")).get("clients",[]):
                            _em = cl.get("email","").lower()
                            if _em:
                                all_emails[_em] = round(float(cl.get("totalGB", 0) or 0) / (1024**3), 2)
                    except Exception:
                        pass
                    # วิธี 1: อ่าน traffic จาก clientStats (x-ui เก่า/กลาง)
                    for cs in ib.get("clientStats") or []:
                        _em = cs.get("email","").lower()
                        if not _em:
                            continue
                        _ub = (cs.get("down", 0) or 0) + (cs.get("up", 0) or 0)
                        _lgb = all_emails.get(_em, 0)
                        traffic_map[_em] = (round(_ub / (1024**3), 2), _lgb)

                # วิธี 2: fallback per-email สำหรับ email ที่ยังไม่มี traffic (clientStats ว่าง)
                for _em, _lgb in all_emails.items():
                    if _em not in traffic_map or traffic_map[_em][0] == 0.0:
                        try:
                            er = opener.open(
                                _ureq.Request(f"{_base}/panel/api/inbounds/getClientTrafficByEmail/{_em}"),
                                timeout=5
                            )
                            ed = json.loads(er.read().decode())
                            if ed.get("success") and ed.get("obj"):
                                obj = ed["obj"]
                                _ub2 = (obj.get("down",0) or 0) + (obj.get("up",0) or 0)
                                if _ub2 > 0 or _em not in traffic_map:
                                    traffic_map[_em] = (round(_ub2/(1024**3), 2), _lgb)
                        except Exception:
                            pass

                return traffic_map  # สำเร็จ
            except Exception:
                continue
    except Exception:
        pass
    return traffic_map

def list_users():
    db = os.path.join(USERS_DIR, "users.db")
    result = []
    if not os.path.exists(db): return result
    import subprocess as sp
    from datetime import datetime

    # ดึง traffic จาก x-ui ครั้งเดียว แล้วแชร์ทุก user
    xui_traffic = _fetch_xui_traffic_map()
    # อ่าน datalimit.conf เป็น fallback
    dl_conf = {}
    if os.path.exists("/etc/chaiya/datalimit.conf"):
        for dl_line in open("/etc/chaiya/datalimit.conf"):
            dl_parts = dl_line.strip().split()
            if len(dl_parts) >= 2:
                try: dl_conf[dl_parts[0].lower()] = float(dl_parts[1])
                except: pass

    for line in open(db):
        parts = line.strip().split()
        if len(parts) >= 3:
            user, days, exp = parts[0], parts[1], parts[2]
            data_gb  = int(parts[3]) if len(parts) > 3 else 0
            ip_limit = int(parts[4]) if len(parts) > 4 else 2
            active = sp.run(f"id {user}", shell=True, capture_output=True).returncode == 0
            try:
                exp_dt = datetime.strptime(exp, "%Y-%m-%d")
                is_exp = exp_dt < datetime.now()
            except:
                is_exp = False

            # ── ดึง used_gb จาก x-ui (email = "chaiya-<user>" หรือ "<user>") ──
            used_gb = 0.0
            xui_limit = 0.0
            for email_key in (f"chaiya-{user}".lower(), user.lower()):
                if email_key in xui_traffic:
                    used_gb, xui_limit = xui_traffic[email_key]
                    break

            # ถ้า x-ui ไม่มีข้อมูล fallback ไปที่ iptables tracker
            if used_gb == 0.0:
                data_file = f"/etc/chaiya/data-used/{user}.json"
                try:
                    if os.path.exists(data_file):
                        state = json.loads(open(data_file).read())
                        used_gb = round(state.get("total", 0) / (1024**3), 2)
                except:
                    pass

            # limit: ใช้จาก x-ui ก่อน → datalimit.conf → users.db
            if xui_limit > 0:
                data_gb = xui_limit
            elif data_gb == 0 and user.lower() in dl_conf:
                data_gb = dl_conf[user.lower()]

            pct = 0.0
            if data_gb > 0:
                pct = round(min(100.0, (used_gb / data_gb) * 100), 1)

            result.append({
                "user": user, "days": int(days), "exp": exp,
                "active": active and not is_exp,
                "data_gb": data_gb,
                "used_gb": used_gb,
                "pct": pct,
                "ip_limit": ip_limit
            })
    return result

def get_connections():
    """นับ active connections แยกตาม port"""
    cfg = load_conf()
    port_map = {
        "80":  cfg.get("WS_PORT","80"),
        "143": cfg.get("DROPBEAR_PORT","143"),
        "109": cfg.get("DROPBEAR_PORT2","109"),
        "22":  "22"
    }
    counts = {}
    total = 0
    for label, p in port_map.items():
        out, _ = run(f"ss -tn state established 2>/dev/null | grep -c ':{p} ' || echo 0")
        try:
            n = int(out.strip())
        except:
            n = 0
        counts[label] = n
        total += n
    counts["total"] = total
    return counts

def get_online_connections():
    """ดึง list ของ active connections พร้อม remote IP และ username"""
    import re
    cfg = load_conf()
    ports = [cfg.get("WS_PORT","80"), cfg.get("DROPBEAR_PORT","143"), cfg.get("DROPBEAR_PORT2","109"), "22"]
    conns = []
    seen = set()
    # map IP -> username จาก who
    user_ip_map = {}
    who_out, _ = run("who 2>/dev/null || echo ''")
    for wline in who_out.splitlines():
        m_ip = re.search(r'\(([0-9a-fA-F.:]+)\)', wline)
        if m_ip:
            wparts = wline.split()
            if wparts: user_ip_map.setdefault(m_ip.group(1), wparts[0])
    for port in ports:
        out, _ = run(f"ss -tnp state established 2>/dev/null | grep ':{port}[^0-9]'")
        for line in out.splitlines():
            parts = line.split()
            peer = parts[4] if len(parts) >= 5 else ""
            if not re.match(r'^[\d\.\[\]:]+:\d+$', peer): continue
            ip = peer.rsplit(":", 1)[0].strip("[]")
            if not ip or ip in seen: continue
            seen.add(ip)
            username = user_ip_map.get(ip, "")
            if not username:
                pid_m = re.search(r'pid=(\d+)', line)
                if pid_m:
                    u_out, _ = run(f"ps -o user= -p {pid_m.group(1)} 2>/dev/null")
                    username = u_out.strip()
            conns.append({"remote": ip, "user": username, "state": "ESTAB", "port": port})
    return conns

def _safe_net_stat(col):
    try:
        total = 0
        for l in open("/proc/net/dev").readlines()[2:]:
            l = l.replace(":", ": ")
            parts = l.split()
            if not parts or parts[0] in ("lo", "lo:"): continue
            try: total += int(parts[col])
            except: pass
        return total
    except: return 0

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _cors_origin(self):
        """อนุญาตเฉพาะ request จาก localhost / IP เครื่องตัวเอง"""
        origin = self.headers.get("Origin", "")
        # อนุญาต: ไม่มี Origin (direct call), หรือ origin เป็น localhost/127.x/::1
        import re as _re3
        if not origin or _re3.match(r'^https?://(localhost|127\.|0\.0\.0\.0|\[::1\])', origin):
            return origin or "*"
        # origin อื่น: ให้ null เพื่อบล็อก browser cross-origin
        return "null"

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", self._cors_origin())
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type,X-Token,X-Auth-Token")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", self._cors_origin())
        self.send_header("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization,Content-Type,X-Token,X-Auth-Token")
        self.end_headers()

    def auth(self):
        # อ่าน token จากไฟล์ทุกครั้ง เพื่อให้ regenerate มีผลทันทีโดยไม่ต้อง restart
        try:
            live_tok = open(TOKEN_FILE).read().strip()
        except Exception:
            live_tok = TOKEN
        if not live_tok:
            live_tok = TOKEN
        # 1. Authorization: Bearer <token>
        t = self.headers.get("Authorization","").replace("Bearer ","").strip()
        if t and hmac.compare_digest(t, live_tok):
            return True
        # 2. X-Token header (custom — ไม่มี ISO-8859-1 restriction จาก browser)
        t2 = self.headers.get("X-Token","").strip()
        if t2 and hmac.compare_digest(t2, live_tok):
            return True
        # 3. X-Auth-Token header
        t3 = self.headers.get("X-Auth-Token","").strip()
        if t3 and hmac.compare_digest(t3, live_tok):
            return True
        # 4. query string ?token=xxx (fallback สุดท้าย)
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        t4 = qs.get("token", [""])[0].strip()
        if t4 and hmac.compare_digest(t4, live_tok):
            return True
        return False

    def read_body(self):
        n = int(self.headers.get("Content-Length",0))
        return json.loads(self.rfile.read(n)) if n else {}

    def do_GET(self):
        p = urllib.parse.urlparse(self.path).path.rstrip("/")

        # ── /api/token — ต้องยืนยัน master password ก่อน (ไม่ public) ──
        if p == "/api/token":
            import re as _re2
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            master = qs.get("master", [""])[0].strip()
            # อ่าน master password จาก /etc/chaiya/xui-pass.conf (ใช้ซ้ำกับ xui)
            try:
                stored = open("/etc/chaiya/xui-pass.conf").read().strip()
            except Exception:
                stored = ""
            if not stored or not master or not hmac.compare_digest(master, stored):
                return self.send_json(401, {"error": "unauthorized"})
            try:
                live_tok = open(TOKEN_FILE).read().strip() or TOKEN
            except Exception:
                live_tok = TOKEN
            return self.send_json(200, {"token": live_tok})

        if not self.auth(): return self.send_json(401, {"error":"unauthorized"})

        if p == "/api/status":
            cfg = load_conf()
            ws_on,  _ = run("systemctl is-active chaiya-sshws")
            db_on,  _ = run("systemctl is-active dropbear")
            ng_on,  _ = run("systemctl is-active nginx")
            udpgw_on, _ = run("pgrep -f badvpn-udpgw")
            tunnel_on, _ = run("pgrep -f ws-stunnel")
            started_raw, _ = run("systemctl show chaiya-sshws --property=ActiveEnterTimestamp --value 2>/dev/null || echo ''")
            started = started_raw.strip() or "N/A"
            conns = get_connections()
            users_list = list_users()          # คืน list โดยตรง
            total_users = len(users_list)
            online_list = get_online_connections()  # คืน list โดยตรง
            online_count = len(online_list)
            return self.send_json(200, {
                "enabled":         int(cfg.get("ENABLED","1")),
                "connections":     conns.get("total", 0),
                "conn_80":         conns.get("80", 0),
                "conn_143":        conns.get("143", 0),
                "conn_109":        conns.get("109", 0),
                "conn_22":         conns.get("22", 0),
                "online_count":    online_count,
                "total_users":     total_users,
                "rx_bytes": _safe_net_stat(1),
                "tx_bytes": _safe_net_stat(9),
                "vless_count": 0,
                "services": {
                    "sshws":    ws_on.strip()   == "active",
                    "dropbear": db_on.strip()   == "active",
                    "nginx":    ng_on.strip()   == "active",
                    "badvpn":   bool(udpgw_on.strip()),
                    "tunnel":   bool(tunnel_on.strip()),
                    "ssl443":   (ng_on.strip() == "active") and os.path.exists("/etc/chaiya/ssl/chaiya.crt"),
                    "started":  started
                }
            })

        elif p == "/api/users":
            # HTML expect {"users":[...]}
            return self.send_json(200, {"users": list_users()})

        elif p == "/api/online":
            # HTML expect {"connections":[...]}
            return self.send_json(200, {"connections": get_online_connections()})

        elif p in ("/api/bans", "/api/banned"):
            # HTML เรียก /api/bans
            return self.send_json(200, {"bans": load_bans()})

        elif p == "/api/logs":
            out, _ = run(f"tail -n 80 {LOG_FILE} 2>/dev/null || echo ''")
            return self.send_json(200, {"lines": out.splitlines()})

        elif p == "/api/info":
            cfg = load_conf()
            ip_cache = "/etc/chaiya/my_ip.conf"
            my_ip = ""
            try:
                if os.path.exists(ip_cache): my_ip = open(ip_cache).read().strip()
            except: pass
            if not my_ip:
                my_ip, _ = run("curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'")
                my_ip = my_ip.strip()
                if my_ip:
                    try: open(ip_cache, "w").write(my_ip)
                    except: pass
            domain = ""
            if os.path.exists("/etc/chaiya/domain.conf"):
                domain = open("/etc/chaiya/domain.conf").read().strip()
            host = domain or my_ip
            proto = "https" if os.path.exists(f"/etc/letsencrypt/live/{host}/fullchain.pem") else "http"
            return self.send_json(200, {
                "host": host,
                "proto": proto,
                "ws_port": int(cfg.get("WS_PORT","80")),
                "dropbear_port": int(cfg.get("DROPBEAR_PORT","143")),
                "dropbear_port2": int(cfg.get("DROPBEAR_PORT2","109")),
                "udpgw_port": int(cfg.get("UDPGW_PORT","7300")),
                "payload": "CONNECT /  HTTP/1.1\r\nHost: [host]\r\n\r\n",
                "payload2": "GET / HTTP/1.1\r\nHost: [host]\r\nUpgrade: websocket\r\n\r\n"
            })

        elif p.startswith("/api/vless-traffic/"):
            # ── Realtime traffic ของ VLESS user จาก 3x-ui ──────────
            # path: /api/vless-traffic/{email}
            email = p[len("/api/vless-traffic/"):]
            if not email:
                return self.send_json(400, {"error":"email required"})
            try:
                import urllib.request as _ureq, http.cookiejar as _cj, urllib.parse as _up
                xp  = open("/etc/chaiya/xui-port.conf").read().strip()  if os.path.exists("/etc/chaiya/xui-port.conf")  else "2053"
                xu  = open("/etc/chaiya/xui-user.conf").read().strip()  if os.path.exists("/etc/chaiya/xui-user.conf")  else "admin"
                xpw = open("/etc/chaiya/xui-pass.conf").read().strip()  if os.path.exists("/etc/chaiya/xui-pass.conf")  else ""
                xbp = open("/etc/chaiya/xui-basepath.conf").read().strip().rstrip("/") if os.path.exists("/etc/chaiya/xui-basepath.conf") else ""

                for _proto in ("https", "http"):
                    try:
                        _base = f"{_proto}://127.0.0.1:{xp}{xbp}"
                        cj = _cj.CookieJar()
                        import ssl as _ssl; _ctx = _ssl.create_default_context(); _ctx.check_hostname = False; _ctx.verify_mode = _ssl.CERT_NONE; opener = _ureq.build_opener(_ureq.HTTPCookieProcessor(cj), _ureq.HTTPSHandler(context=_ctx))
                        # login
                        login_data = _up.urlencode({"username": xu, "password": xpw}).encode()
                        req = _ureq.Request(f"{_base}/login", data=login_data)
                        req.add_header("Content-Type", "application/x-www-form-urlencoded")
                        lr = opener.open(req, timeout=5).read().decode()
                        if '"success":true' not in lr:
                            continue

                        # ── วิธีที่ 1: getClientTrafficByEmail (รองรับทุก x-ui version) ──
                        used_down = used_up = 0
                        limit_gb  = 0
                        found     = False
                        try:
                            er = opener.open(
                                _ureq.Request(f"{_base}/panel/api/inbounds/getClientTrafficByEmail/{email}"),
                                timeout=5
                            )
                            ed = json.loads(er.read().decode())
                            if ed.get("success") and ed.get("obj"):
                                obj = ed["obj"]
                                used_down = obj.get("down", 0) or 0
                                used_up   = obj.get("up",   0) or 0
                                found = True
                        except Exception:
                            pass

                        # ── วิธีที่ 2: fallback อ่านจาก clientStats ใน inbounds/list ──
                        if not found:
                            tresp = opener.open(_ureq.Request(f"{_base}/panel/api/inbounds/list"), timeout=8)
                            tdata = json.loads(tresp.read().decode())
                            if tdata.get("success"):
                                for ib in tdata.get("obj", []):
                                    for cs in ib.get("clientStats") or []:
                                        if cs.get("email","").lower() == email.lower():
                                            used_down = cs.get("down", 0) or 0
                                            used_up   = cs.get("up",   0) or 0
                                            found = True
                                            break
                                    if found:
                                        break

                        # ── อ่าน totalGB (limit) จาก inbounds/list settings.clients[] ──
                        try:
                            if not found or limit_gb == 0:
                                tresp2 = opener.open(_ureq.Request(f"{_base}/panel/api/inbounds/list"), timeout=8)
                                tdata2 = json.loads(tresp2.read().decode())
                            else:
                                # reuse tdata ถ้า fallback ใช้อยู่แล้ว
                                tdata2 = tdata if 'tdata' in dir() else {}
                            for ib in tdata2.get("obj", []):
                                for cl in json.loads(ib.get("settings","{}")).get("clients",[]):
                                    if cl.get("email","").lower() == email.lower():
                                        limit_gb = round(float(cl.get("totalGB", 0) or 0) / (1024**3), 2)
                                        break
                                if limit_gb > 0:
                                    break
                        except Exception:
                            pass

                        # ── Fallback limit: datalimit.conf ──
                        if limit_gb == 0 and os.path.exists("/etc/chaiya/datalimit.conf"):
                            for dl_line in open("/etc/chaiya/datalimit.conf"):
                                dl_parts = dl_line.strip().split()
                                if len(dl_parts) >= 2 and dl_parts[0].lower() == email.lower():
                                    try: limit_gb = float(dl_parts[1])
                                    except: pass
                                    break

                        used_bytes = used_down + used_up
                        used_gb    = round(used_bytes / (1024**3), 2)
                        pct        = min(100, round(used_gb / limit_gb * 100, 1)) if limit_gb >= 1.0 else 0

                        # ── Auto-enforce: disable client เมื่อใช้ครบ limit ──
                        if limit_gb >= 1.0 and used_gb >= limit_gb:
                            try:
                                td = tdata2 if 'tdata2' in dir() else {}
                                for ib2 in td.get("obj", []):
                                    ib_id = ib2.get("id")
                                    settings_obj = json.loads(ib2.get("settings","{}"))
                                    for cl in settings_obj.get("clients",[]):
                                        if cl.get("email","").lower() == email.lower():
                                            if cl.get("enable", True):
                                                cl["enable"] = False
                                                disable_data = json.dumps({
                                                    "id": ib_id,
                                                    "settings": json.dumps({"clients":[cl]})
                                                }).encode()
                                                dreq = _ureq.Request(
                                                    f"{_base}/panel/api/inbounds/updateClient/{cl.get('id',email)}",
                                                    data=disable_data
                                                )
                                                dreq.add_header("Content-Type","application/json")
                                                opener.open(dreq, timeout=5)
                                            break
                            except Exception:
                                pass

                        return self.send_json(200, {
                            "ok":         True,
                            "email":      email,
                            "used_gb":    used_gb,
                            "limit_gb":   limit_gb,
                            "pct":        pct,
                            "down_gb":    round(used_down / (1024**3), 2),
                            "up_gb":      round(used_up   / (1024**3), 2),
                            "over_limit": limit_gb >= 1.0 and used_gb >= limit_gb
                        })
                    except Exception:
                        continue
                return self.send_json(200, {"ok": False, "used_gb": 0, "limit_gb": 0, "pct": 0})
            except Exception as ex:
                return self.send_json(500, {"error": str(ex)})

        else:
            return self.send_json(404, {"error":"not_found"})

    def do_POST(self):
        if not self.auth(): return self.send_json(401, {"error":"unauthorized"})
        p = urllib.parse.urlparse(self.path).path.rstrip("/")
        body = self.read_body()

        # ── Service control all ──
        if p == "/api/service":
            action = body.get("action","")
            if action == "start":
                run("systemctl start chaiya-sshws")
                run("systemctl start dropbear")
                cfg = load_conf(); cfg["ENABLED"]="1"; save_conf(cfg)
                return self.send_json(200, {"ok":True, "result":"started"})
            elif action == "stop":
                run("systemctl stop chaiya-sshws")
                cfg = load_conf(); cfg["ENABLED"]="0"; save_conf(cfg)
                return self.send_json(200, {"ok":True, "result":"stopped"})
            elif action == "restart":
                run("systemctl restart chaiya-sshws")
                run("systemctl restart dropbear")
                run("systemctl restart nginx")
                return self.send_json(200, {"ok":True, "result":"restarted"})
            else:
                return self.send_json(400, {"error":"unknown action"})

        # ── Service control single (HTML เรียก /api/service1) ──
        elif p == "/api/service1":
            svc    = body.get("service","").strip()
            action = body.get("action","").strip()
            allowed = ["chaiya-sshws","dropbear","nginx","chaiya-sshws-api"]
            if svc not in allowed:
                return self.send_json(400, {"error":f"service not allowed: {svc}"})
            if action not in ("start","stop","restart"):
                return self.send_json(400, {"error":"action must be start/stop/restart"})
            out, rc = run(f"systemctl {action} {svc}")
            return self.send_json(200, {"ok": rc==0, "result": f"{action} {svc}"})

        elif p == "/api/start":
            run("systemctl start chaiya-sshws")
            run("systemctl start dropbear")
            cfg = load_conf(); cfg["ENABLED"]="1"; save_conf(cfg)
            return self.send_json(200, {"ok":True, "result":"started"})

        elif p == "/api/stop":
            run("systemctl stop chaiya-sshws")
            cfg = load_conf(); cfg["ENABLED"]="0"; save_conf(cfg)
            return self.send_json(200, {"ok":True, "result":"stopped"})

        # ── badvpn-udpgw control (HTML เรียก /api/udpgw) ──
        elif p == "/api/udpgw":
            action = body.get("action","restart")
            run("pkill -f badvpn-udpgw 2>/dev/null || true")
            import time as _time; _time.sleep(1)
            run("screen -dmS badvpn7300 badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 500")
            return self.send_json(200, {"ok":True, "result":"udpgw restarted"})

        # ── Config update ──
        elif p == "/api/config":
            cfg = load_conf()
            cfg["WS_PORT"]        = str(body.get("ws_port", 80))
            cfg["SSH_PORT"]       = str(body.get("ssh_port", 22))
            cfg["DROPBEAR_PORT"]  = str(body.get("dropbear_port", 143))
            cfg["DROPBEAR_PORT2"] = str(body.get("dropbear_port2", 109))
            cfg["UDPGW_PORT"]     = str(body.get("udpgw_port", 7300))
            cfg["USE_DROPBEAR"]   = str(body.get("use_dropbear", 1))
            save_conf(cfg)
            # อัพเดต Dropbear config
            dp  = cfg["DROPBEAR_PORT"]
            dp2 = cfg["DROPBEAR_PORT2"]
            run(f"sed -i 's/DROPBEAR_PORT=.*/DROPBEAR_PORT={dp}/' /etc/default/dropbear")
            run(f"sed -i 's/DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS=\"-p {dp2}\"/' /etc/default/dropbear")
            run("systemctl daemon-reload")
            if cfg.get("ENABLED","1") == "1":
                run("systemctl restart chaiya-sshws")
                run("systemctl restart dropbear")
            return self.send_json(200, {"ok":True, "result":"config_saved"})

        # ── สร้าง user SSH (Dropbear ใช้ system user เหมือน OpenSSH) ──
        elif p == "/api/users":
            user    = body.get("user","").strip()
            pw      = body.get("password","").strip()
            days    = int(body.get("days", 30))
            data_gb = int(body.get("data_gb", 0))
            if not user or not pw:
                return self.send_json(400, {"error":"user and password required"})
            if not validate_username(user):
                return self.send_json(400, {"error":"username: a-z0-9_- only, max 32 chars"})
            exp, _ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
            exp = exp.strip()
            # สร้าง system user shell=/bin/false (ใช้ได้กับทั้ง SSH+Dropbear)
            run(f"userdel -f {user} 2>/dev/null; useradd -M -s /bin/false -e {exp} {user}")
            run(f"printf '%s:%s\n' '{user}' '{pw}' | chpasswd")
            run(f"chage -E {exp} {user}")
            db = os.path.join(USERS_DIR, "users.db")
            with open(db, "a") as f: f.write(f"{user} {days} {exp} {data_gb}\n")
            # อัพเดท tracker ทันทีเพื่อสร้าง iptables rule สำหรับ user ใหม่
            run("python3 /usr/local/bin/chaiya-data-tracker 2>/dev/null &")
            return self.send_json(200, {"ok":True, "result":f"user_created:{user}"})

        # ── ต่ออายุ user ──
        elif p == "/api/renew":
            user    = body.get("user","").strip()
            days    = int(body.get("days", 30))
            data_gb = int(body.get("data_gb", 0))
            if not user: return self.send_json(400, {"error":"user required"})
            if not validate_username(user): return self.send_json(400, {"error":"invalid username"})
            exp, _ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
            exp = exp.strip()
            run(f"chage -E {exp} {user}")
            db = os.path.join(USERS_DIR, "users.db")
            lines = []
            if os.path.exists(db):
                for line in open(db):
                    p2 = line.strip().split()
                    if p2 and p2[0] == user:
                        lines.append(f"{user} {days} {exp} {data_gb}\n")
                    else:
                        lines.append(line)
            else:
                lines.append(f"{user} {days} {exp} {data_gb}\n")
            with open(db,"w") as f: f.writelines(lines)
            return self.send_json(200, {"ok":True, "result":f"renewed:{user} exp:{exp}"})

        # ── unban user ──
        elif p == "/api/unban":
            uid  = body.get("uid","")
            name = body.get("name","").strip()
            bans = load_bans()
            if uid in bans: del bans[uid]
            save_bans(bans)
            if name and validate_username(name):
                run(f"usermod -e '' {name} 2>/dev/null || true")
            return self.send_json(200, {"ok":True})

        # ── import users (batch) ──
        elif p == "/api/import":
            users_data = body.get("users", body) if isinstance(body, dict) else body
            if not isinstance(users_data, list):
                return self.send_json(400, {"error":"expected list of users"})
            created = []; updated = []; failed = []
            db = os.path.join(USERS_DIR, "users.db")
            existing = {}
            if os.path.exists(db):
                for line in open(db):
                    parts = line.strip().split()
                    if parts: existing[parts[0]] = line
            new_lines = dict(existing)
            import subprocess as sp
            for u in users_data:
                user    = str(u.get("user","")).strip()
                pw      = str(u.get("password","")).strip()
                days    = int(u.get("days", 30))
                data_gb = int(u.get("data_gb", 0))
                exp     = str(u.get("exp","")).strip()
                if not user: failed.append("(empty)"); continue
                if not validate_username(user): failed.append(f"{user}:invalid_username"); continue
                try:
                    if not exp:
                        exp_out, _ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
                        exp = exp_out.strip()
                    user_exists = sp.run(f"id {user}", shell=True, capture_output=True).returncode == 0
                    if not user_exists:
                        run(f"useradd -M -s /bin/false -e {exp} {user}")
                        created.append(user)
                    else:
                        updated.append(user)
                    if pw: run(f"printf '%s:%s\n' '{user}' '{pw}' | chpasswd")
                    run(f"chage -E {exp} {user}")
                    new_lines[user] = f"{user} {days} {exp} {data_gb}\n"
                except Exception as e:
                    failed.append(f"{user}:{e}")
            with open(db,"w") as f: f.writelines(new_lines.values())
            run("python3 /usr/local/bin/chaiya-data-tracker 2>/dev/null &")
            return self.send_json(200, {
                "ok": True,
                "created": created, "updated": updated, "failed": failed,
                "total": len(created)+len(updated)
            })

        # ── kill connection ของ user ──
        elif p == "/api/kick":
            user = body.get("user","").strip()
            if not user: return self.send_json(400, {"error":"user required"})
            if not validate_username(user): return self.send_json(400, {"error":"invalid username"})
            run(f"pkill -u {user} -9 2>/dev/null || true")
            return self.send_json(200, {"ok":True, "result":f"kicked:{user}"})

        elif p == "/api/create":
            user     = body.get("user","").strip()
            pw       = body.get("pass","").strip()
            days     = int(body.get("exp_days", body.get("days", 30)))
            data_gb  = int(body.get("data_gb", 0))
            ip_limit = int(body.get("ip_limit", 2))
            if not user or not pw:
                return self.send_json(400, {"error":"user and password required"})
            if not validate_username(user):
                return self.send_json(400, {"error":"username: a-z0-9_- only, max 32 chars"})
            exp, _ = run(f"date -d '+{days} days' +'%Y-%m-%d'")
            exp = exp.strip()
            run(f"userdel -f {user} 2>/dev/null; useradd -M -s /bin/false -e {exp} {user}")
            run(f"printf '%s:%s\n' '{user}' '{pw}' | chpasswd")
            run(f"chage -E {exp} {user}")
            db = os.path.join(USERS_DIR, "users.db")
            with open(db, "a") as f: f.write(f"{user} {days} {exp} {data_gb} {ip_limit}\n")
            run("python3 /usr/local/bin/chaiya-data-tracker 2>/dev/null &")
            return self.send_json(200, {"ok":True, "result":f"user_created:{user}"})
        elif p == "/api/delete":
            user = body.get("user","").strip()
            if not user:
                return self.send_json(400, {"error":"user required"})
            if not validate_username(user):
                return self.send_json(400, {"error":"invalid username"})
            run(f"userdel -f {user} 2>/dev/null")
            run(f"pkill -u {user} -9 2>/dev/null || true")
            db = os.path.join(USERS_DIR, "users.db")
            if os.path.exists(db):
                lines = [l for l in open(db) if not l.startswith(user+" ")]
                with open(db,"w") as f: f.writelines(lines)
            return self.send_json(200, {"ok":True, "result":f"user_deleted:{user}"})

        # ── Token regenerate ──
        elif p == "/api/token/regenerate":
            import secrets, re as _re
            new_tok = secrets.token_hex(16)
            # บันทึกลงไฟล์ — auth() อ่านจากไฟล์ทุก request จึงมีผลทันที
            with open(TOKEN_FILE, "w") as f: f.write(new_tok)
            # ฝัง token ใหม่เข้า sshws.html (แทนที่ _baked) เพื่อ refresh page
            html_path = "/var/www/chaiya/sshws.html"
            try:
                with open(html_path, "r", errors="replace") as f: h = f.read()
                h2 = _re.sub(r"(const _baked\s*=\s*')[^']*(')", r"\g<1>" + new_tok + r"\g<2>", h)
                with open(html_path, "w") as f: f.write(h2)
            except Exception: pass
            return self.send_json(200, {"ok": True, "token": new_tok})

        else:
            return self.send_json(404, {"error":"not_found"})

    def do_DELETE(self):
        if not self.auth(): return self.send_json(401, {"error":"unauthorized"})
        p = urllib.parse.urlparse(self.path).path.rstrip("/").split("/")
        if len(p) == 4 and p[2] == "users":
            user = p[3]
            if not validate_username(user):
                return self.send_json(400, {"error":"invalid username"})
            run(f"userdel -f {user} 2>/dev/null")
            run(f"pkill -u {user} -9 2>/dev/null || true")
            db = os.path.join(USERS_DIR, "users.db")
            if os.path.exists(db):
                lines = [l for l in open(db) if not l.startswith(user+" ")]
                with open(db,"w") as f: f.writelines(lines)
            return self.send_json(200, {"ok":True, "result":f"user_deleted:{user}"})
        return self.send_json(404, {"error":"not_found"})

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "install":
        unit = """[Unit]
Description=Chaiya SSH-WS API
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/chaiya-sshws-api
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
"""
        with open("/etc/systemd/system/chaiya-sshws-api.service","w") as f: f.write(unit)
        os.system("systemctl daemon-reload && systemctl enable chaiya-sshws-api && systemctl restart chaiya-sshws-api")
        print(f"✅ API installed | Token: {TOKEN}")
        sys.exit(0)
    import socketserver
    class _ThreadedAPI(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True
    server = _ThreadedAPI((HOST, PORT), Handler)
    print(f"SSH-WS API :{PORT} | Token: {TOKEN}")
    server.serve_forever()
PYEOF

chmod +x /usr/local/bin/chaiya-sshws-api

python3 /usr/local/bin/chaiya-sshws-api install || true
# รอให้ API ขึ้น port 6789 จริง (สูงสุด 15 วิ)
_api_up=0
for _ai in $(seq 1 8); do
  if ss -tlnp 2>/dev/null | grep -q ":6789 "; then
    _api_up=1; break
  fi
  sleep 2
done
if [[ $_api_up -eq 0 ]]; then
  echo "⚠ chaiya-sshws-api ยังไม่ขึ้น — ลอง nohup fallback..."
  pkill -f chaiya-sshws-api 2>/dev/null || true
  sleep 1
  nohup python3 /usr/local/bin/chaiya-sshws-api >> /var/log/chaiya-sshws-api.log 2>&1 &
  sleep 3
  ss -tlnp 2>/dev/null | grep -q ":6789 " \
    && echo "✅ chaiya-sshws-api ขึ้น port 6789 แล้ว" \
    || echo "❌ chaiya-sshws-api start ไม่ได้ — ดู: cat /var/log/chaiya-sshws-api.log"
else
  echo "✅ chaiya-sshws-api ขึ้น port 6789 แล้ว"
fi

# ══════════════════════════════════════════════════════════════
#  chaiya-data-tracker  (iptables byte accounting — ทุก 60 วิ)
#  นับ traffic จริงจาก kernel สำหรับแต่ละ SSH user
#  บันทึกสะสมลง /etc/chaiya/data-used/<user>.json
# ══════════════════════════════════════════════════════════════
mkdir -p /etc/chaiya/data-used

cat > /usr/local/bin/chaiya-data-tracker << 'TRACKEREOF'
#!/usr/bin/env python3
"""
Chaiya SSH Data Tracker — IP-based iptables byte accounting
นับ bytes ต่อ remote IP ที่ connect อยู่ แล้วผูกกับ SSH user
เหตุผล: Dropbear รันเป็น root → uid-owner ใช้ไม่ได้
วิธี: สร้าง iptables rule นับ bytes ต่อ src IP (INPUT) + dst IP (OUTPUT)
"""
import subprocess, os, json, re
from pathlib import Path

USERS_DB   = "/etc/chaiya/sshws-users/users.db"
DATA_DIR   = "/etc/chaiya/data-used"
CHAIN_IN   = "CHAIYA_IN"
CHAIN_OUT  = "CHAIYA_OUT"
PORTS      = ["80", "143", "109", "22"]

os.makedirs(DATA_DIR, exist_ok=True)

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=15)
        return r.stdout.strip(), r.returncode
    except Exception as e:
        return str(e), 1

def get_users():
    if not os.path.exists(USERS_DB): return []
    import re as _re_u
    return [l.strip().split()[0] for l in open(USERS_DB)
            if l.strip() and _re_u.match(r'^[a-z0-9_-]{1,32}$', l.strip().split()[0])]

def ensure_chains():
    for chain, hook, flag in [(CHAIN_IN,"INPUT","-I INPUT 1"), (CHAIN_OUT,"OUTPUT","-I OUTPUT 1")]:
        _, rc = run(f"iptables -L {chain} -n 2>/dev/null")
        if rc != 0:
            run(f"iptables -N {chain}")
        run(f"iptables -C {hook} -j {chain} 2>/dev/null || iptables {flag} -j {chain}")
    # ลบ chain เก่า CHAIYA_ACCT ถ้ายังเหลืออยู่
    run("iptables -D INPUT  -j CHAIYA_ACCT 2>/dev/null || true")
    run("iptables -D OUTPUT -j CHAIYA_ACCT 2>/dev/null || true")
    run("iptables -F CHAIYA_ACCT 2>/dev/null || true")
    run("iptables -X CHAIYA_ACCT 2>/dev/null || true")

def get_active_ips():
    """ดึง remote IP ที่ connect อยู่บน SSH/Dropbear/WS ports"""
    ips = set()
    port_pat = "|".join(f":{p}[^0-9]" for p in PORTS)
    out, _ = run(f"ss -tn state established 2>/dev/null")
    for line in out.splitlines():
        # ss columns: State Recv-Q Send-Q Local:Port Peer:Port
        parts = line.split()
        if len(parts) < 5: continue
        local = parts[3]
        peer  = parts[4]
        # ตรวจว่า local port ตรงกับ port ที่สนใจ
        lport = local.rsplit(":",1)[-1]
        if lport not in PORTS: continue
        ip = peer.rsplit(":",1)[0].strip("[]")
        if ip and ip != "127.0.0.1" and re.match(r'^[\d\.]+$', ip):
            ips.add(ip)
    return ips

def get_user_ips(user):
    """ดึง IP ที่ผูกกับ user จาก auth.log"""
    ips = set()
    for log in ["/var/log/auth.log", "/var/log/syslog"]:
        if not os.path.exists(log): continue
        out, _ = run(f"grep 'session opened.*{user}\\|Accepted.*{user}' {log} 2>/dev/null | tail -50")
        for line in out.splitlines():
            m = re.search(r'from ([\d\.]+)', line)
            if m: ips.add(m.group(1))
    # fallback: ถ้าไม่มีใน log ให้ใช้ IP ที่ active อยู่ทั้งหมด (single-user server)
    if not ips:
        ips = get_active_ips()
    return ips

def ensure_ip_rules(ip):
    """สร้าง rule นับ bytes สำหรับ IP นี้ใน INPUT และ OUTPUT"""
    for chain, flag in [(CHAIN_IN, f"-s {ip}"), (CHAIN_OUT, f"-d {ip}")]:
        out, _ = run(f"iptables -L {chain} -v -n 2>/dev/null")
        if ip not in out:
            run(f"iptables -A {chain} {flag} -j RETURN")

def read_bytes_for_ip(ip):
    """อ่าน bytes รวม IN+OUT สำหรับ IP นี้"""
    total = 0
    for chain, flag in [(CHAIN_IN, f"-s {ip}"), (CHAIN_OUT, f"-d {ip}")]:
        out, _ = run(f"iptables -L {chain} -v -n -x 2>/dev/null")
        for line in out.splitlines():
            if ip in line:
                cols = line.split()
                if len(cols) >= 2:
                    try: total += int(cols[1])
                    except: pass
    return total

def save_accumulated(user, current_bytes):
    f_path = os.path.join(DATA_DIR, f"{user}.json")
    try:
        state = json.loads(Path(f_path).read_text()) if os.path.exists(f_path) else {}
    except:
        state = {}
    saved        = state.get("saved", 0)
    last_reading = state.get("last_reading", 0)
    if current_bytes < last_reading:
        saved += last_reading
    total = saved + current_bytes
    Path(f_path).write_text(json.dumps({
        "saved": saved, "last_reading": current_bytes, "total": total
    }))
    return total

ensure_chains()
users = get_users()
active_ips = get_active_ips()

# สร้าง rule สำหรับ IP ที่ active อยู่
for ip in active_ips:
    ensure_ip_rules(ip)

for user in users:
    user_ips = get_user_ips(user)
    total_bytes = 0
    for ip in user_ips:
        ensure_ip_rules(ip)
        total_bytes += read_bytes_for_ip(ip)
    total = save_accumulated(user, total_bytes)
    total_gb = round(total / (1024**3), 3)
    print(f"✔ {user}: {total_gb:.3f} GB ({total:,} bytes) IPs={user_ips}")

print(f"✔ Tracked {len(users)} users | Active IPs: {active_ips}")
TRACKEREOF

chmod +x /usr/local/bin/chaiya-data-tracker

# ── systemd service (oneshot) ─────────────────────────────────
cat > /etc/systemd/system/chaiya-data-tracker.service << 'TRACKERSVCEOF'
[Unit]
Description=Chaiya SSH Data Usage Tracker
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/chaiya-data-tracker
StandardOutput=journal
StandardError=journal
TRACKERSVCEOF

# ── systemd timer (ทุก 60 วิ) ─────────────────────────────────
cat > /etc/systemd/system/chaiya-data-tracker.timer << 'TRACKERTIMEREOF'
[Unit]
Description=Chaiya Data Tracker — run every 60 seconds
After=network.target

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
TRACKERTIMEREOF

systemctl daemon-reload
systemctl enable --now chaiya-data-tracker.timer 2>/dev/null || true

# รัน tracker ครั้งแรกทันที เพื่อสร้าง iptables rules
python3 /usr/local/bin/chaiya-data-tracker 2>/dev/null || true

echo "✅ chaiya-data-tracker ติดตั้งแล้ว (อัพเดทอัตโนมัติทุก 60 วิ)"

# ── SSHWS token (อ่านจาก file ที่สร้างไว้แล้วตั้งแต่ก่อน HTML) ──
# [FIX] ไม่สร้างซ้ำ — token ถูกสร้างและบันทึกก่อนเขียน sshws.html แล้ว
SSHWS_TOKEN=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')

SSHWS_HOST=""
# ตรวจ domain ก่อนใช้
SSHWS_HOST=""
if [[ -f /etc/chaiya/domain.conf ]]; then
  _d=$(cat /etc/chaiya/domain.conf 2>/dev/null | tr -d '[:space:]')
  getent hosts "$_d" &>/dev/null && SSHWS_HOST="$_d" || SSHWS_HOST=""
fi
[[ -z "$SSHWS_HOST" ]] && SSHWS_HOST="$MY_IP"
SSHWS_PROTO="http"
[[ -f /etc/letsencrypt/live/$(cat /etc/chaiya/domain.conf 2>/dev/null)/fullchain.pem ]] && SSHWS_PROTO="https"

# ── chaiya-iplimit ────────────────────────────────────────────
cat > /usr/local/bin/chaiya-iplimit << 'LIMITEOF'
#!/usr/bin/env python3
"""
Chaiya IP Limit — ban SSH/Dropbear users ที่ login >2 IPs พร้อมกัน (12h ban)
ตรวจจาก auth.log (OpenSSH) + ss connections (Dropbear port 143/109)
"""
import json, subprocess, os, re
from datetime import datetime, timedelta

BAN     = "/etc/chaiya/iplimit_ban.json"
LIMIT   = 2
BAN_HRS = 12
LOGS    = ["/var/log/auth.log", "/var/log/syslog"]

def load_bans():
    try: return json.load(open(BAN))
    except: return {}

def save_bans(b): json.dump(b, open(BAN,"w"), indent=2, ensure_ascii=False)

def get_users():
    db = "/etc/chaiya/sshws-users/users.db"
    if not os.path.exists(db): return []
    import re as _re_u
    return [l.strip().split()[0] for l in open(db)
            if l.strip() and _re_u.match(r'^[a-z0-9_-]{1,32}$', l.strip().split()[0])]

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ""

now  = datetime.now()
bans = load_bans()

import re as _re_iplimit

# ── unban ที่หมดเวลา ──
for uid in list(bans.keys()):
    try:
        until = datetime.fromisoformat(bans[uid]["until"])
        if now >= until:
            name = bans[uid]["name"]
            if name and _re_iplimit.match(r'^[a-z0-9_-]{1,32}$', name):
                run(f"usermod -e '' {name} 2>/dev/null || true")
            print(f"🔓 Unban: {name}")
            del bans[uid]
    except: pass

users = get_users()
for user in users:
    if any(b["name"]==user for b in bans.values()): continue
    ips = set()

    # ตรวจจาก auth.log (OpenSSH login)
    for log_f in LOGS:
        if not os.path.exists(log_f): continue
        try:
            out = run(f"grep 'Accepted.*{user}' {log_f} 2>/dev/null | tail -200")
            for line in out.splitlines():
                m = re.search(r'from (\S+) port', line)
                if m: ips.add(m.group(1))
        except: pass

    # ตรวจจาก ss (Dropbear active connections port 143/109)
    # [FIX] ต้องกรองเฉพาะ connection ที่ผูกกับ user นี้จาก auth.log
    # ห้ามนับ IP ของ user อื่นที่ connect อยู่พร้อมกัน
    # วิธี: cross-reference IP จาก auth.log กับ active connections เท่านั้น
    try:
        out = run(f"ss -tnp state established 2>/dev/null | grep -E ':143 |:109 '")
        active_ips = set()
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 5:
                remote = parts[4].rsplit(":",1)[0].strip("[]")
                if remote:
                    active_ips.add(remote)
        # เอาเฉพาะ IP ที่มีทั้งใน auth.log (ของ user นี้) AND active connection
        # ถ้า auth.log ว่างเปล่า (เช่น Dropbear ไม่ log) ใช้ active IPs
        if ips:
            # มีข้อมูลจาก auth.log → intersect กับ active IPs
            ips = ips & active_ips if active_ips else ips
        else:
            # ไม่มีข้อมูลจาก auth.log → fallback ใช้ active IPs
            # แต่ต้องตรวจว่า user นี้ login อยู่จริงจาก who/w
            who_out = run(f"who | grep '^{user} ' 2>/dev/null")
            if who_out:
                ips = active_ips
    except: pass

    if len(ips) > LIMIT:
        until = now + timedelta(hours=BAN_HRS)
        run(f"usermod -e 1 {user} 2>/dev/null || true")
        run(f"pkill -u {user} -9 2>/dev/null || true")
        uid2 = f"{user}_{int(now.timestamp())}"
        bans[uid2] = {"name":user,"until":until.isoformat(),"ips":list(ips)}
        print(f"🔨 Ban: {user} ({len(ips)} IPs) until {until.strftime('%Y-%m-%d %H:%M')}")

save_bans(bans)
print(f"✔ iplimit check done | banned: {len(bans)}")
LIMITEOF
chmod +x /usr/local/bin/chaiya-iplimit 2>/dev/null || true

(crontab -l 2>/dev/null || true) | grep -v chaiya-iplimit | { cat; echo "*/5 * * * * python3 /usr/local/bin/chaiya-iplimit >> /var/log/chaiya-iplimit.log 2>&1"; } | crontab -

# ── chaiya-datalimit: ตัด VLESS user เมื่อใช้ data ครบ GB ─────
cat > /usr/local/bin/chaiya-datalimit << 'DATALIMITEOF'
#!/usr/bin/env python3
"""
Chaiya Data Limit Enforcer — ตรวจการใช้ data จาก 3x-ui แล้ว disable client เมื่อครบ limit
รันทุก 5 นาทีผ่าน cron
"""
import json, subprocess, os, sys
import urllib.request as _ureq, http.cookiejar as _cj, urllib.parse as _up

DATALIMIT_CONF = "/etc/chaiya/datalimit.conf"
XUI_PORT_F = "/etc/chaiya/xui-port.conf"
XUI_USER_F = "/etc/chaiya/xui-user.conf"
XUI_PASS_F = "/etc/chaiya/xui-pass.conf"
XUI_BP_F   = "/etc/chaiya/xui-basepath.conf"
LOG_F      = "/var/log/chaiya-datalimit.log"

def log(msg):
    from datetime import datetime
    line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line)
    try:
        with open(LOG_F, "a") as f: f.write(line + "\n")
    except: pass

def run(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except: return ""

# โหลด data limit ที่ตั้งไว้
limits = {}
if os.path.exists(DATALIMIT_CONF):
    for line in open(DATALIMIT_CONF):
        parts = line.strip().split()
        if len(parts) >= 2:
            try:
                limits[parts[0].lower()] = float(parts[1])
            except: pass

if not limits:
    log("ไม่มี data limit ใน datalimit.conf — ออก")
    sys.exit(0)

# อ่าน xui config
xp  = open(XUI_PORT_F).read().strip() if os.path.exists(XUI_PORT_F) else "2053"
xu  = open(XUI_USER_F).read().strip() if os.path.exists(XUI_USER_F) else "admin"
xpw = open(XUI_PASS_F).read().strip() if os.path.exists(XUI_PASS_F) else ""
xbp = open(XUI_BP_F).read().strip().rstrip("/") if os.path.exists(XUI_BP_F) else ""

for _proto in ("https", "http"):
    try:
        _base = f"{_proto}://127.0.0.1:{xp}{xbp}"
        cj = _cj.CookieJar()
        import ssl as _ssl; _ctx = _ssl.create_default_context(); _ctx.check_hostname = False; _ctx.verify_mode = _ssl.CERT_NONE; opener = _ureq.build_opener(_ureq.HTTPCookieProcessor(cj), _ureq.HTTPSHandler(context=_ctx))
        # login
        login_data = _up.urlencode({"username": xu, "password": xpw}).encode()
        req = _ureq.Request(f"{_base}/login", data=login_data)
        req.add_header("Content-Type","application/x-www-form-urlencoded")
        resp = opener.open(req, timeout=5)
        if '"success":true' not in resp.read().decode():
            continue
        # ดึง inbound list
        treq  = _ureq.Request(f"{_base}/panel/api/inbounds/list")
        tdata = json.loads(opener.open(treq, timeout=8).read().decode())
        if not tdata.get("success"):
            continue

        for ib in tdata.get("obj", []):
            ib_id = ib.get("id")
            # [FIX] อ่าน totalGB จาก settings.clients[] — หน่วย GB จริงๆ
            _cl_totalgb = {}
            try:
                for cl in json.loads(ib.get("settings","{}")).get("clients",[]):
                    _em = cl.get("email","").lower()
                    if _em:
                        _cl_totalgb[_em] = round(float(cl.get("totalGB", 0) or 0) / (1024**3), 2)
            except Exception:
                pass
            for cs in ib.get("clientStats") or []:
                email     = cs.get("email","").lower()
                # [FIX] ใช้ limit จาก datalimit.conf ก่อน ถ้าไม่มีให้ fallback ไป totalGB ใน xui
                # เดิม: ถ้า email ไม่อยู่ใน limits และ tgb <= 0 → skip ทั้งที่ xui set quota ไว้แล้ว
                tgb = _cl_totalgb.get(email, 0)
                limit_gb = limits.get(email, tgb)
                if limit_gb <= 0:
                    continue
                used_bytes = cs.get("down",0) + cs.get("up",0)
                used_gb    = used_bytes / (1024**3)
                if limit_gb >= 1.0 and used_gb >= limit_gb:
                    log(f"⚠ {email}: ใช้ {used_gb:.2f} GB / {limit_gb} GB — กำลัง disable...")
                    try:
                        settings_obj = json.loads(ib.get("settings","{}"))
                        for cl in settings_obj.get("clients",[]):
                            if cl.get("email","").lower() == email:
                                if cl.get("enable", True):
                                    cl["enable"] = False
                                    cl_id = cl.get("id", email)
                                    disable_data = json.dumps({
                                        "id": ib_id,
                                        "settings": json.dumps({"clients":[cl]})
                                    }).encode()
                                    dreq = _ureq.Request(
                                        f"{_base}/panel/api/inbounds/updateClient/{cl_id}",
                                        data=disable_data
                                    )
                                    dreq.add_header("Content-Type","application/json")
                                    dres = opener.open(dreq, timeout=5).read().decode()
                                    if '"success":true' in dres:
                                        log(f"✅ Disabled {email} เรียบร้อย")
                                    else:
                                        log(f"❌ Disable ไม่สำเร็จ: {dres[:100]}")
                                else:
                                    log(f"  {email} ถูก disable ไปแล้ว — ข้าม")
                    except Exception as e:
                        log(f"❌ Error disabling {email}: {e}")
        # ทำสำเร็จแล้ว ไม่ต้อง loop proto ต่อ
        break
    except Exception as ex:
        log(f"❌ xui connect error ({_proto}): {ex}")
        continue

log("✔ data limit check done")
DATALIMITEOF

chmod +x /usr/local/bin/chaiya-datalimit 2>/dev/null || true
(crontab -l 2>/dev/null || true) | grep -v chaiya-datalimit | { cat; echo "*/5 * * * * python3 /usr/local/bin/chaiya-datalimit >> /var/log/chaiya-datalimit.log 2>&1"; } | crontab -
echo "✅ chaiya-datalimit enforcer ติดตั้งเรียบร้อย"

# ── [FIX] ตั้งค่า logrotate สำหรับ log ทั้งหมด ────────────────
# ป้องกัน disk full จาก log ที่เพิ่มขึ้นเรื่อยๆ
cat > /etc/logrotate.d/chaiya << 'LOGEOF'
/var/log/chaiya-iplimit.log
/var/log/chaiya-datalimit.log
/var/log/chaiya-sshws.log
/var/log/chaiya-cpu-guard.log
/var/log/chaiya-xui-install.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    size 10M
}
LOGEOF
echo "✅ logrotate ตั้งค่าแล้ว (rotate ทุกวัน เก็บ 7 วัน max 10MB)"

# ══════════════════════════════════════════════════════════════
#  สร้าง sshws.html  (base64 decode + แทน token)
# ══════════════════════════════════════════════════════════════
_SSHWS_TOK=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]' || echo "N/A")
_SSHWS_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
# ตรวจ domain ว่า resolve ได้จริงบนเครื่องนี้ก่อนใช้
_SSHWS_HOST="$_SSHWS_IP"
if [[ -f /etc/chaiya/domain.conf ]]; then
  _dom_tmp=$(cat /etc/chaiya/domain.conf 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$_dom_tmp" ]] && getent hosts "$_dom_tmp" &>/dev/null; then
    _SSHWS_HOST="$_dom_tmp"
  fi
fi
_SSHWS_PROTO="http"
[[ -f "/etc/letsencrypt/live/${_SSHWS_HOST}/fullchain.pem" ]] && _SSHWS_PROTO="https"

# ── ฝัง token/host/proto ลง sshws.html ตอน install ──────────
sed -i "s|%%BAKED_TOKEN%%|${_SSHWS_TOK}|g"  /var/www/chaiya/sshws.html 2>/dev/null || true
sed -i "s|%%TOKEN%%|${_SSHWS_TOK}|g"        /var/www/chaiya/sshws.html 2>/dev/null || true
sed -i "s|%%HOST%%|${_SSHWS_HOST}|g"        /var/www/chaiya/sshws.html 2>/dev/null || true
sed -i "s|%%PROTO%%|${_SSHWS_PROTO}|g"      /var/www/chaiya/sshws.html 2>/dev/null || true
echo "✅ Token ฝังใน sshws.html แล้ว: ${_SSHWS_TOK}"

echo "✅ sshws.html สร้างพร้อมใช้งาน"

# ══════════════════════════════════════════════════════════════
#  chaiya  MAIN MENU SCRIPT  (เขียนตรงไม่ใช้ base64)
# ══════════════════════════════════════════════════════════════
cat > /usr/local/bin/menu << 'CHAIYAEOF'
#!/bin/bash
# CHAIYA V2RAY PRO MAX
CHAIYA_VERSION="v35"
CHAIYA_BUILD_DATE="$(date +%Y-%m-%d 2>/dev/null || echo 'unknown')"

DB="/etc/chaiya/vless.db"
DOMAIN_FILE="/etc/chaiya/domain.conf"
BAN_FILE="/etc/chaiya/banned.db"
IP_LOG="/etc/chaiya/iplog.db"
VLESS_DIR="/etc/chaiya/vless-users"
XUI_COOKIE="/etc/chaiya/xui-cookie.jar"
XUI_PORT_FILE="/etc/chaiya/xui-port.conf"
XUI_USER_FILE="/etc/chaiya/xui-user.conf"
XUI_PASS_FILE="/etc/chaiya/xui-pass.conf"
LICENSE_FILE="/etc/chaiya/license.key"
LICENSE_SERVER="http://license.godvpn.shop:7070"

mkdir -p "$VLESS_DIR"

# ── สี Cyber Mint ─────────────────────────────────────────────
R1=$'\033[1;38;2;77;255;176m'
R2=$'\033[1;38;2;128;255;221m'
R3=$'\033[1;38;2;255;230;128m'
R4=$'\033[1;38;2;77;255;176m'
R5=$'\033[1;38;2;128;255;221m'
R6=$'\033[1;38;2;184;160;255m'
PU=$'\033[1;38;2;184;160;255m'
YE=$'\033[1;38;2;255;230;128m'
WH=$'\033[1;38;2;200;221;208m'
GR=$'\033[1;38;2;77;255;176m'
RD=$'\033[1;38;2;255;107;138m'
CY=$'\033[1;38;2;128;255;221m'
MG=$'\033[1;38;2;184;160;255m'
OR=$'\033[1;38;2;255;179;71m'
RS=$'\033[0m'
BLD=$'\033[1m'


# ── auto-install nginx ถ้าหายไป ──────────────────────────────
_ensure_nginx() {
  if ! command -v nginx &>/dev/null; then
    printf "${OR}⚠ nginx หายไป — กำลังติดตั้งใหม่...${RS}\n"
    apt-get install -y -qq nginx 2>/dev/null || true
    systemctl enable nginx 2>/dev/null || true
    systemctl start nginx 2>/dev/null || true
  fi
}

# ── helper ────────────────────────────────────────────────────
get_info() {
  # [FIX] cache IP ไว้ใน file — ไม่ต้อง curl ทุกครั้งที่เปิดเมนู (ช้า 1-5 วิ)
  # รีเฟรช cache ทุก 5 นาที
  local _ip_cache="/etc/chaiya/my-ip.cache"
  local _ip_age=999
  if [[ -f "$_ip_cache" ]]; then
    _ip_age=$(( $(date +%s) - $(date -r "$_ip_cache" +%s 2>/dev/null || echo 0) ))
  fi
  if [[ ! -f "$_ip_cache" || $_ip_age -gt 300 ]]; then
    MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
         || curl -s --max-time 5 api.ipify.org 2>/dev/null \
         || hostname -I | awk '{print $1}')
    echo "$MY_IP" > "$_ip_cache" 2>/dev/null || true
  else
    MY_IP=$(cat "$_ip_cache")
  fi
  [[ -f "$DOMAIN_FILE" ]] && HOST=$(cat "$DOMAIN_FILE") || HOST=""
  CPU=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%d", $2+$4}' 2>/dev/null || echo "0")
  RAM_USED=$(free -m | awk '/Mem:/{printf "%.1f", $3/1024}')
  RAM_TOTAL=$(free -m | awk '/Mem:/{printf "%.1f", $2/1024}')
  USERS=$(ss -tn state established 2>/dev/null | grep -c ':80\|:143\|:109' || echo "0")
}

show_logo() {
  printf "${R1}  ██████╗██╗  ██╗ █████╗ ██╗██╗   ██╗ █████╗ ${RS}\n"
  printf "${R2}  ██╔════╝██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══██╗${RS}\n"
  printf "${R3}  ██║     ███████║███████║██║ ╚████╔╝ ███████║${RS}\n"
  printf "${R4}  ██║     ██╔══██║██╔══██║██║  ╚██╔╝  ██╔══██║${RS}\n"
  printf "${R5}  ╚██████╗██║  ██║██║  ██║██║   ██║   ██║  ██║${RS}\n"
  printf "${R6}   ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝${RS}\n"
}

# ── rainbow neon aura สำหรับข้อความเมนู ─────────────────────
# ไล่สี 19 ระดับ: แดง→ส้ม→เหลือง→เขียว→ฟ้า→น้ำเงิน→ม่วง→ชมพู
_RB() {
  local idx=$1 text=$2
  local -a COLS=(
    $'\033[1;38;2;255;0;100m'    # 0  deep pink
    $'\033[1;38;2;255;0;180m'    # 1  hot pink
    $'\033[1;38;2;255;60;0m'     # 2  red-orange
    $'\033[1;38;2;255;120;0m'    # 3  orange
    $'\033[1;38;2;255;200;0m'    # 4  amber
    $'\033[1;38;2;200;255;0m'    # 5  yellow-green
    $'\033[1;38;2;0;255;80m'     # 6  neon green
    $'\033[1;38;2;0;255;180m'    # 7  spring green
    $'\033[1;38;2;0;255;255m'    # 8  neon cyan
    $'\033[1;38;2;0;200;255m'    # 9  sky blue
    $'\033[1;38;2;0;120;255m'    # 10 blue
    $'\033[1;38;2;80;0;255m'     # 11 indigo
    $'\033[1;38;2;160;0;255m'    # 12 violet
    $'\033[1;38;2;220;0;255m'    # 13 purple
    $'\033[1;38;2;255;0;200m'    # 14 magenta
    $'\033[1;38;2;255;0;120m'    # 15 pink
    $'\033[1;38;2;255;80;0m'     # 16 orange-red
    $'\033[1;38;2;255;220;0m'    # 17 gold
    $'\033[1;38;2;0;255;120m'    # 18 mint
  )
  local c="${COLS[$((idx % 19))]}"
  printf "${c}${text}${RS}"
}

# ── License Check ─────────────────────────────────────────────
check_license() {
  local key expiry plan owner status msg
  local MY_IP; MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

  # ── วนลูปจนกว่าจะได้ key ที่ถูกต้อง ──────────────────────
  while true; do
    key=$(cat "$LICENSE_FILE" 2>/dev/null | tr -d '[:space:]')

    # ถ้าไม่มี key → ขอ key
    if [[ -z "$key" ]]; then
      clear
      printf "\n${R1}  ██████╗██╗  ██╗ █████╗ ██╗██╗   ██╗ █████╗ ${RS}\n"
      printf "${R2}  ██╔════╝██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══██╗${RS}\n"
      printf "${R3}  ██║     ███████║███████║██║ ╚████╔╝ ███████║${RS}\n"
      printf "${R4}  ██║     ██╔══██║██╔══██║██║  ╚██╔╝  ██╔══██║${RS}\n"
      printf "${R5}  ╚██████╗██║  ██║██║  ██║██║   ██║   ██║  ██║${RS}\n"
      printf "${R6}   ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝${RS}\n"
      printf "\n${PU}╔══════════════════════════════════════════════════════╗${RS}\n"
      printf "${PU}║${RS}  🔑 ${WH}กรุณาใส่ License Key เพื่อใช้งาน${RS}               ${PU}║${RS}\n"
      printf "${PU}╠══════════════════════════════════════════════════════╣${RS}\n"
      printf "${PU}║${RS}                                                      ${PU}║${RS}\n"
      printf "${PU}║${RS}  ${R3}🛒 ติดต่อเช่า/ซื้อ:${RS}                               ${PU}║${RS}\n"
      printf "${PU}║${RS}                                                      ${PU}║${RS}\n"
      printf "${PU}║${RS}  ${R1}󰈌 ${WH}Facebook :${RS}  ${R2}Chaiya Ungrattanakon${RS}            ${PU}║${RS}\n"
      printf "${PU}║${RS}  ${R5}  ${WH}Line ID  :${RS}  ${CY}0636432940${RS}                       ${PU}║${RS}\n"
      printf "${PU}║${RS}                                                      ${PU}║${RS}\n"
      printf "${PU}╚══════════════════════════════════════════════════════╝${RS}\n\n"
      read -rp "$(printf "  ${WH}License Key: ${RS}")" key
      key=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
      if [[ -z "$key" ]]; then
        printf "\n  ${RD}✗ ไม่มี Key — ออกจากโปรแกรม${RS}\n\n"
        exit 1
      fi
    fi

    # เช็ค key กับ server
    local resp
    resp=$(curl -s --max-time 8 "${LICENSE_SERVER}/api/check?key=${key}&ip=${MY_IP}" 2>/dev/null)
    status=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','error'))" 2>/dev/null || echo "error")

    if [[ "$status" == "ok" ]]; then
      # บันทึก key
      echo "$key" > "$LICENSE_FILE"
      chmod 600 "$LICENSE_FILE"
      expiry=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('expiry','?'))" 2>/dev/null || echo "?")
      plan=$(echo "$resp"   | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('plan','?'))" 2>/dev/null || echo "?")
      owner=$(echo "$resp"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('owner',''))" 2>/dev/null || echo "")
      # บันทึก cache สำหรับ offline fallback
      echo "{\"status\":\"ok\",\"expiry\":\"$expiry\",\"plan\":\"$plan\",\"owner\":\"$owner\",\"cached_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
        > /etc/chaiya/license-cache.json 2>/dev/null || true
      export LIC_KEY="$key" LIC_EXPIRY="$expiry" LIC_PLAN="$plan" LIC_OWNER="$owner"
      return 0
    fi

    msg=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('msg',d.get('detail','')))" 2>/dev/null || echo "")

    # [FIX] ตรวจ hard-fail ก่อนเสมอ — ห้ามหลุดไป offline fallback
    # ip_limit/key_disabled มาจาก server ตอบจริง ไม่ใช่ network error
    if [[ "$msg" == "ip_limit" || "$msg" == "key_disabled" || "$msg" == "key_expired" ]]; then
      : # ปล่อยผ่านไปแสดงข้อความ error ด้านล่าง — ห้าม fallback
    # Offline fallback — ใช้ cache ถ้าเช็คไม่ได้ภายใน 24 ชั่วโมง (network จริงๆ ล้มเหลว)
    elif [[ -z "$resp" || "$status" == "error" ]] && [[ "$msg" != "invalid_key" ]]; then
      local cache_f="/etc/chaiya/license-cache.json"
      if [[ -f "$cache_f" ]]; then
        local cached_status cached_at
        cached_status=$(python3 -c "import json; d=json.load(open('$cache_f')); print(d.get('status',''))" 2>/dev/null)
        cached_at=$(python3 -c "import json; d=json.load(open('$cache_f')); print(d.get('cached_at',''))" 2>/dev/null)
        # ถ้า cache ไม่เกิน 24 ชั่วโมง ผ่านได้
        local age_hours
        age_hours=$(python3 -c "
from datetime import datetime
try:
  t=datetime.strptime('$cached_at','%Y-%m-%dT%H:%M:%SZ')
  print(int((datetime.utcnow()-t).total_seconds()/3600))
except: print(999)
" 2>/dev/null || echo "999")
        if [[ "$cached_status" == "ok" && "$age_hours" -lt 24 ]]; then
          expiry=$(python3 -c "import json; d=json.load(open('$cache_f')); print(d.get('expiry','?'))" 2>/dev/null)
          plan=$(python3 -c   "import json; d=json.load(open('$cache_f')); print(d.get('plan','?'))" 2>/dev/null)
          owner=$(python3 -c  "import json; d=json.load(open('$cache_f')); print(d.get('owner',''))" 2>/dev/null)
          export LIC_KEY="$key" LIC_EXPIRY="$expiry" LIC_PLAN="$plan" LIC_OWNER="$owner" LIC_OFFLINE=1
          return 0
        fi
      fi
    fi

    # Key ไม่ผ่าน → แสดงข้อความแล้ว ให้ใส่ใหม่ (ไม่ exit)
    clear
    printf "\n${RD}╔══════════════════════════════════════════════════╗${RS}\n"
    printf "${RD}║${RS}  ❌ ${WH}LICENSE ไม่ถูกต้องหรือหมดอายุ${RS}               ${RD}║${RS}\n"
    printf "${RD}╠══════════════════════════════════════════════════╣${RS}\n"
    case "$msg" in
      invalid_key)   printf "${RD}║${RS}  🔑 Key ไม่ถูกต้อง — ตรวจสอบอีกครั้ง           ${RD}║${RS}\n" ;;
      key_expired)   printf "${RD}║${RS}  📅 Key หมดอายุแล้ว — ต่ออายุที่ร้านค้า        ${RD}║${RS}\n" ;;
      key_disabled)  printf "${RD}║${RS}  ⏸  Key ถูกระงับ — ติดต่อ Admin               ${RD}║${RS}\n" ;;
      ip_limit)      printf "${RD}║${RS}  🌍 Key นี้ผูกกับ VPS อื่นแล้ว                 ${RD}║${RS}\n" ;;
      *)             printf "${RD}║${RS}  🌐 ไม่สามารถเชื่อมต่อ License Server ได้     ${RD}║${RS}\n" ;;
    esac
    printf "${RD}╠══════════════════════════════════════════════════╣${RS}\n"
    printf "${RD}║${RS}  ${R3}🛒 ติดต่อเช่า/ซื้อ:${RS}                             ${RD}║${RS}\n"
    printf "${RD}║${RS}  ${R1}󰈌 ${WH}Facebook :${RS}  ${R2}Chaiya Ungrattanakon${RS}          ${RD}║${RS}\n"
    printf "${RD}║${RS}  ${R5}  ${WH}Line ID  :${RS}  ${CY}0636432940${RS}                     ${RD}║${RS}\n"
    printf "${RD}╚══════════════════════════════════════════════════╝${RS}\n\n"

    # ลบ key file ที่ผิด เพื่อให้วนกลับไปถามใหม่
    rm -f "$LICENSE_FILE" 2>/dev/null

    # ถ้า key หมดอายุ / ถูก disable → ไม่มีทางแก้โดยพิมพ์ key เดิม → exit
    if [[ "$msg" == "key_expired" || "$msg" == "key_disabled" ]]; then
      exit 1
    fi
    # ip_limit → อาจเกิดจาก VPS เปลี่ยน IP (reboot/NAT) → ให้ retry ได้
    if [[ "$msg" == "ip_limit" ]]; then
      printf "\n  ${YE}ถ้า VPS นี้เพิ่ง reboot หรือเปลี่ยน IP ให้กด Enter เพื่อลองใหม่${RS}\n"
      printf "  ${YE}หรือกด Ctrl+C เพื่อออก${RS}\n"
      read -rp "" _dummy
      rm -f "$LICENSE_FILE" 2>/dev/null
      continue
    fi

    # invalid_key หรือ network error → ให้ใส่ key ใหม่ได้เลย (loop ต่อ)
    printf "  ${YE}กรุณาใส่ Key ใหม่ หรือกด Ctrl+C เพื่อออก${RS}\n\n"
    read -rp "$(printf "  ${WH}License Key: ${RS}")" key
    key=$(echo "$key" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
    if [[ -z "$key" ]]; then
      printf "\n  ${RD}✗ ไม่มี Key — ออกจากโปรแกรม${RS}\n\n"
      exit 1
    fi
    # เขียน key ใหม่ลงไฟล์ก่อน loop รอบหน้าจะอ่าน
    echo "$key" > "$LICENSE_FILE"
    chmod 600 "$LICENSE_FILE"
  done
}

show_menu() {
  get_info
  clear
  show_logo
  printf "\n"
  printf "${R1}╭──────────────────────────────────────────────╮${RS}\n"
  printf "${R2}│${RS} 🔥 ${R2}V2RAY PRO MAX${RS}\n"
  if [[ -n "$HOST" ]]; then
    printf "${R3}│${RS} 🌐 ${CY}Domain : %s${RS}\n" "$HOST"
  else
    printf "${R3}│${RS} ⚠️  ${YE}ยังไม่มีโดเมน${RS}\n"
  fi
  printf "${R4}│${RS} 🌍 ${CY}IP     : %s${RS}\n" "$MY_IP"
  # ── แสดง License info ───────────────────────────────────────
  local _lic_color="$GR"
  local _lic_icon="🔑"
  [[ "${LIC_OFFLINE:-0}" == "1" ]] && _lic_color="$OR" && _lic_icon="⚠️ "
  local _lic_exp="${LIC_EXPIRY:-?}"
  [[ "$_lic_exp" == "unlimited" || -z "$_lic_exp" ]] && _lic_exp="∞ ไม่จำกัด"
  printf "${R4}│${RS} ${_lic_icon} ${_lic_color}License: ${WH}%s${RS} ${PU}[%s]${RS}\n" \
    "${LIC_OWNER:-unknown}" "${LIC_PLAN:-?}"
  printf "${R4}│${RS}    ${CY}หมดอายุ: %s${RS}\n" "$_lic_exp"
  printf "${R4}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R5}│${RS} 💻 CPU:${CY}%s%%%s${RS} 🧠RAM:${YE}%s/%sGB${RS} 👥:${PU}%s${RS}\n" "$CPU" "" "$RAM_USED" "$RAM_TOTAL" "$USERS"
  printf "${R5}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R6}│${RS}  $(_RB 0  "1. ")$(_RB 1  " ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ")\n"
  printf "${R6}│${RS}  $(_RB 2  "2. ")$(_RB 3  " ตั้งค่าโดเมน + SSL อัตโนมัติ")\n"
  printf "${PU}│${RS}  $(_RB 4  "3. ")$(_RB 5  " สร้าง VLESS (IP/โดเมน+port+SNI)")\n"
  printf "${PU}│${RS}  $(_RB 6  "4. ")$(_RB 7  " ลบบัญชีหมดอายุ")\n"
  printf "${MG}│${RS}  $(_RB 8  "5. ")$(_RB 9  " ดูบัญชี")\n"
  printf "${MG}│${RS}  $(_RB 10 "6. ")$(_RB 11 " ดู User Online Realtime")\n"
  printf "${CY}│${RS}  $(_RB 12 "7. ")$(_RB 13 " รีสตาร์ท 3x-ui")\n"
  printf "${CY}│${RS}  $(_RB 14 "8. ")$(_RB 15 " จัดการ Process CPU สูง")\n"
  printf "${R5}│${RS}  $(_RB 16 "9. ")$(_RB 17 " เช็คความเร็ว VPS")\n"
  printf "${R4}│${RS}  $(_RB 18 "10.")$(_RB 0  " จัดการ Port (เปิด/ปิด)")\n"
  printf "${R4}│${RS}  $(_RB 2  "11.")$(_RB 3  " ปลดแบน IP / จัดการ User")\n"
  printf "${R3}│${RS}  $(_RB 4  "12.")$(_RB 5  " บล็อก IP ต่างประเทศ")\n"
  printf "${R3}│${RS}  $(_RB 6  "13.")$(_RB 7  " สแกน Bug Host (SNI)")\n"
  printf "${R2}│${RS}  $(_RB 8  "14.")$(_RB 9  " ลบ User")\n"
  printf "${R2}│${RS}  $(_RB 10 "15.")$(_RB 11 " ตั้งค่ารีบูตอัตโนมัติ")\n"
  printf "${R1}├──────────────────────────────────────────────┤${RS}\n"
  printf "${R2}│${RS}  $(_RB 12 "16.")$(_RB 13 " อัพเดทสคริปต์/ถอนการติดตั้ง")\n"
  printf "${R3}│${RS}  $(_RB 14 "17.")$(_RB 15 " เคลียร์ CPU อัตโนมัติ")\n"
  printf "${R4}│${RS}  $(_RB 16 "18.")$(_RB 17 " SSH WebSocket")\n"
  printf "${R5}│${RS}  $(_RB 18 "0. ")$(_RB 0  " ออก")\n"
  printf "${R6}╰──────────────────────────────────────────────╯${RS}\n"
  printf "\n${MG}เลือก >> ${RS}"
}

# ── helper: x-ui API ─────────────────────────────────────────
xui_port() { cat "$XUI_PORT_FILE" 2>/dev/null || echo "2053"; }
xui_user() { cat "$XUI_USER_FILE" 2>/dev/null || echo "admin"; }
xui_pass() { cat "$XUI_PASS_FILE" 2>/dev/null || echo "admin"; }

# เช็คจริงว่า x-ui ใช้ https หรือ http — ไม่เดาจาก domain file
xui_proto() {
  local p; p=$(xui_port)
  if curl -sk --max-time 3 "https://127.0.0.1:${p}/" &>/dev/null; then
    echo "https"
  else
    echo "http"
  fi
}

xui_login() {
  local p u pw bp
  p=$(xui_port); u=$(xui_user); pw=$(xui_pass)
  # อ่าน basepath จาก db โดยตรงก่อนเสมอ — ป้องกัน conf เก่าหรือว่าง
  local _db_bp
  _db_bp=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$_db_bp" && "$_db_bp" != "/" ]]; then
    bp="$_db_bp"
    echo "$bp" > /etc/chaiya/xui-basepath.conf
  else
    bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | tr -d '[:space:]')
  fi
  # normalize trailing slash: "/abc/" → "/abc", "/" → ""(root), "" → ""
  if [[ "$bp" == "/" || -z "$bp" ]]; then
    bp=""
  else
    bp=$(echo "$bp" | sed 's|/$||')
  fi
  local _cookie="/etc/chaiya/xui-cookie.jar"
  rm -f "$_cookie"

  local _r _url
  # [FIX] ลอง root path ก่อนเสมอ เพราะ 3x-ui ใหม่ webBasePath="/" = ไม่มี prefix
  # ลำดับ: http root → https root → http+bp → https+bp
  local _tries=(
    "http://127.0.0.1:${p}/login"
    "https://127.0.0.1:${p}/login"
    "http://127.0.0.1:${p}${bp}/login"
    "https://127.0.0.1:${p}${bp}/login"
  )
  # dedup กรณี bp ว่าง (root ซ้ำ)
  local _seen=()
  for _url in "${_tries[@]}"; do
    local _dup=0
    for _s in "${_seen[@]}"; do [[ "$_s" == "$_url" ]] && _dup=1; done
    [[ "$_dup" == "1" ]] && continue
    _seen+=("$_url")

    _r=$(curl -sk -c "$_cookie" \
      -X POST "$_url" \
      -d "username=${u}&password=${pw}" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --max-time 10 2>/dev/null)
    if echo "$_r" | grep -q '"success":true'; then
      [[ -n "$XUI_COOKIE" ]] && cp "$_cookie" "$XUI_COOKIE" 2>/dev/null || true
      return 0
    fi
    rm -f "$_cookie"
  done
  return 1
}

xui_api() {
  local method="$1" endpoint="$2" data="${3:-}"
  local p bp _r
  p=$(xui_port)
  bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | tr -d '[:space:]')
  [[ "$bp" == "/" || -z "$bp" ]] && bp="" || bp=$(echo "$bp" | sed 's|/$||')
  local _cookie="/etc/chaiya/xui-cookie.jar"

  # login ถ้าไม่มี cookie
  if [[ ! -f "$_cookie" ]]; then
    xui_login 2>/dev/null || true
  fi

  # ตรวจ proto
  local _proto="http"
  curl -sk --max-time 3 "https://127.0.0.1:${p}/" &>/dev/null && _proto="https"

  _call_api() {
    local _pr="$1"
    if [[ -n "$data" ]]; then
      curl -sk -b "$_cookie" -X "$method" \
        "${_pr}://127.0.0.1:${p}${bp}${endpoint}" \
        -H "Content-Type: application/json" -d "$data" --max-time 15 2>/dev/null
    else
      curl -sk -b "$_cookie" -X "$method" \
        "${_pr}://127.0.0.1:${p}${bp}${endpoint}" --max-time 15 2>/dev/null
    fi
  }

  _r=$(_call_api "$_proto")

  # [FIX] session หมด หรือ response ว่าง → login ใหม่แล้วลองซ้ำ
  if echo "$_r" | grep -qi 'unauthorized\|please login' || [[ -z "$_r" ]]; then
    rm -f "$_cookie"
    xui_login 2>/dev/null || true
    _r=$(_call_api "$_proto")
  fi

  # ถ้ายังไม่มี success → ลอง proto อีกตัว (http↔https)
  if ! echo "$_r" | grep -q '"success"'; then
    local _proto2="https"; [[ "$_proto" == "https" ]] && _proto2="http"
    _r2=$(_call_api "$_proto2")
    # ถ้า proto อีกตัวดีกว่าให้ใช้
    if echo "$_r2" | grep -q '"success"'; then
      _r="$_r2"
    fi
  fi

  echo "$_r"
}

# ── สร้างไฟล์ HTML สำหรับ VLESS user (RGB Wave UI v15) ───────
gen_vless_html() {
  local uname="$1" link="$2" uuid="$3" host_val="$4" port_val="$5" sni_val="$6" exp="$7" data_gb="${8:-0}" email="${9:-$1}"
  local outfile="/var/www/chaiya/config/${uname}.html"
  python3 << PYEOF
import os

u       = """$uname"""
em      = """$email"""
lnk     = """$link"""
ex      = """$exp"""
dg      = """$data_gb"""
dg_num  = 0 if dg.strip() in ("0", "") else int(dg.strip())
dg_txt  = "Unlimited" if dg_num == 0 else str(dg_num) + " GB"
outfile = """$outfile"""

# อ่าน token สำหรับเรียก API
tok = ""
tok_f = "/etc/chaiya/sshws-token.conf"
if os.path.exists(tok_f):
    tok = open(tok_f).read().strip()

# escape สำหรับ JS string
lnk_js = lnk.replace("\\\\", "\\\\\\\\").replace('"', '\\\\"').replace("\\n", "")

# คำนวณ % เริ่มต้น (0 เสมอ จะ update จาก JS realtime)
bar_pct   = 0
bar_label = "กำลังโหลด..."

# สี progress bar default
def bar_color(pct):
    if pct < 50:  return "#00ff80"
    if pct < 80:  return "#ffcc00"
    return "#ff4060"

bc = bar_color(bar_pct)

html = """<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA VPN \u2014 """ + u + """</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d0d0d;font-family:'Segoe UI',sans-serif;min-height:100vh;
     display:flex;align-items:center;justify-content:center;padding:20px}
.wrap{width:100%;max-width:420px}

@keyframes rgbTxt{
  0%{color:#ff0080}16%{color:#ff8000}33%{color:#ffee00}
  50%{color:#00ff80}66%{color:#00d4ff}83%{color:#b400ff}100%{color:#ff0080}}
@keyframes rgbLine{
  0%{background:linear-gradient(90deg,#ff0080,#ff8000)}
  25%{background:linear-gradient(90deg,#ffee00,#00ff80)}
  50%{background:linear-gradient(90deg,#00d4ff,#b400ff)}
  75%{background:linear-gradient(90deg,#ff0080,#ff8000)}
  100%{background:linear-gradient(90deg,#ffee00,#00ff80)}}
@keyframes rgbBorder{
  0%{border-color:#ff0080}16%{border-color:#ff8000}33%{border-color:#ffee00}
  50%{border-color:#00ff80}66%{border-color:#00d4ff}83%{border-color:#b400ff}100%{border-color:#ff0080}}

/* ── RGB Breathing สำหรับปุ่ม Copy (จาง→เข้ม วนสี) ── */
@keyframes rgbBreath{
  0%  {background:rgba(255,0,128,0.4);  box-shadow:0 0 8px rgba(255,0,128,0.3)}
  16% {background:rgba(255,128,0,0.7);  box-shadow:0 0 16px rgba(255,128,0,0.6)}
  33% {background:rgba(255,238,0,0.4);  box-shadow:0 0 8px rgba(255,238,0,0.3)}
  50% {background:rgba(0,255,128,0.7);  box-shadow:0 0 16px rgba(0,255,128,0.6)}
  66% {background:rgba(0,212,255,0.4);  box-shadow:0 0 8px rgba(0,212,255,0.3)}
  83% {background:rgba(180,0,255,0.7);  box-shadow:0 0 16px rgba(180,0,255,0.6)}
  100%{background:rgba(255,0,128,0.4);  box-shadow:0 0 8px rgba(255,0,128,0.3)}}
@keyframes rgbBreathBorder{
  0%  {border-color:rgba(255,0,128,0.6)}
  16% {border-color:rgba(255,128,0,1)}
  33% {border-color:rgba(255,238,0,0.6)}
  50% {border-color:rgba(0,255,128,1)}
  66% {border-color:rgba(0,212,255,0.6)}
  83% {border-color:rgba(180,0,255,1)}
  100%{border-color:rgba(255,0,128,0.6)}}

@keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.2)}}
@keyframes charWave{
  0%,100%{color:#ff0080}16%{color:#ff8000}33%{color:#ffee00}
  50%{color:#00ff80}66%{color:#00d4ff}83%{color:#b400ff}}
@keyframes barFill{from{width:0}to{width:var(--bar-target,0%)}}
@keyframes rgbSlide{0%{background-position:0% 50%}50%{background-position:100% 50%}100%{background-position:0% 50%}}

.header{text-align:center;padding:22px 0 12px}
.fire{font-size:34px;display:inline-block;animation:pulse 1.8s ease-in-out infinite}
.title{font-size:22px;font-weight:800;letter-spacing:6px;margin-top:4px;
       animation:rgbTxt 3s linear infinite}
.username{margin-top:6px;font-size:14px;color:#5a8aaa}
.username span{color:#00cfff;font-weight:600}
.line{height:2px;border-radius:2px;margin:10px 0 16px;animation:rgbLine 3s linear infinite}

.row{display:flex;align-items:center;justify-content:space-between;
     padding:11px 4px;border-bottom:1px solid #1a1a2a}
.row:last-of-type{border-bottom:none}
.row-left{display:flex;align-items:center;gap:10px}
.ico{font-size:18px}
.lbl{font-size:13px;font-weight:500;letter-spacing:1px;animation:rgbTxt 3s linear infinite}
.row:nth-child(1) .lbl{animation-delay:0s}
.row:nth-child(2) .lbl{animation-delay:.5s}
.row:nth-child(3) .lbl{animation-delay:1s}
.row-right{font-size:13px;color:#c0d0e0;text-align:right}

/* ── Data bar ── */
.data-wrap{padding:11px 4px 14px;border-bottom:1px solid #1a1a2a}
.data-top{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px}
.data-label{font-size:13px;font-weight:500;letter-spacing:1px;animation:rgbTxt 3s linear infinite;animation-delay:.5s}
.data-txt{font-size:12px;color:#c0d0e0}
.bar-track{background:#1e1e2e;border-radius:99px;height:10px;overflow:hidden;position:relative}
.bar-fill{height:100%;border-radius:99px;background:#00ff80;transition:width 1s ease}
.bar-rgb{background:linear-gradient(270deg,#ff0080,#ff4000,#ffcc00,#00ff80,#00d4ff,#8000ff,#ff0080);
          background-size:300% 300%;animation:rgbSlide 3s ease infinite;
          box-shadow:0 0 10px #00d4ff44,0 0 20px #8000ff22}
.bar-pct{text-align:right;font-size:10px;color:#6060a0;margin-top:4px}

.link-box{background:#111118;border-radius:10px;border:1.5px solid #333;
          padding:12px 14px;margin:16px 0 14px;
          animation:rgbBorder 3s linear infinite;
          word-break:break-all;font-family:monospace;font-size:11.5px;line-height:1.7}
.link-char{display:inline;animation:charWave 3s linear infinite}

/* ── Copy button: breathing RGB ── */
.btn-copy{width:100%;padding:15px;border:2px solid rgba(255,0,128,0.8);
          border-radius:12px;font-size:15px;font-weight:700;letter-spacing:1px;
          cursor:pointer;color:#fff;margin-bottom:10px;
          animation:rgbBreath 4s ease-in-out infinite,
                   rgbBreathBorder 4s ease-in-out infinite;
          transition:transform .1s,opacity .1s}
.btn-copy:active{transform:scale(.97);opacity:.85}

.btn-qr{width:100%;padding:14px;border-radius:12px;border:1.5px solid #333;
        background:transparent;color:#ffd700;font-size:14px;font-weight:600;
        cursor:pointer;letter-spacing:1px;transition:transform .1s;
        animation:rgbBorder 3s linear infinite;animation-delay:1.5s}
.btn-qr:active{transform:scale(.97)}
#qrbox{display:none;margin-top:14px;text-align:center;
       background:#fff;padding:14px;border-radius:12px}

/* ── หมายเหตุ ── */
.notice{margin-top:14px;padding:10px 14px;border-radius:10px;
        background:#1a0a00;border:1px solid #ff6600;
        font-size:12px;color:#ffa040;line-height:1.6;text-align:center}
.notice b{color:#ffcc00}

.toast{position:fixed;bottom:32px;left:50%;transform:translateX(-50%);
       background:#00ff80;color:#000;padding:11px 28px;border-radius:22px;
       font-weight:700;font-size:13px;opacity:0;transition:opacity .3s;
       pointer-events:none;z-index:999}
.toast.show{opacity:1}
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <div class="fire">\U0001f525</div>
    <div class="title">CHAIYA VPN</div>
    <div class="username">\U0001f464 <span>""" + u + """</span></div>
  </div>
  <div class="line"></div>

  <div class="row">
    <div class="row-left"><span class="ico">\U0001f4c5</span><span class="lbl">\u0e2b\u0e21\u0e14\u0e2d\u0e32\u0e22\u0e38</span></div>
    <div class="row-right">""" + ex + """</div>
  </div>

  <!-- Data bar — realtime polling จาก x-ui ทุก 10 วิ -->
  <div class="data-wrap">
    <div class="data-top">
      <div class="row-left"><span class="ico">\U0001f4ca</span><span class="data-label">Data</span></div>
      <div class="data-txt" id="data-txt">\u0e01\u0e33\u0e25\u0e31\u0e07\u0e42\u0e2b\u0e25\u0e14...</div>
    </div>
    <div class="bar-track">
      <div class="bar-fill" id="bar-fill" style="width:0%;transition:width 1s ease"></div>
    </div>
    <div class="bar-pct" id="bar-pct" style="color:#6060a0">-</div>
  </div>

  <div class="row">
    <div class="row-left"><span class="ico">\U0001f310</span><span class="lbl">Protocol</span></div>
    <div class="row-right">VLESS WS</div>
  </div>

  <div class="link-box" id="vlink-box"></div>
  <button class="btn-copy" onclick="copyLink()">\U0001f4cb&nbsp; Copy Link</button>
  <button class="btn-qr"   onclick="toggleQR()">\U0001f4f1&nbsp; \u0e41\u0e2a\u0e14\u0e07 QR Code</button>
  <div id="qrbox"></div>

  <div class="notice">
    \u26a0\ufe0f <b>\u0e2b\u0e21\u0e32\u0e22\u0e40\u0e2b\u0e15\u0e38</b> \u2014
    1 \u0e44\u0e1f\u0e25\u0e4c\u0e19\u0e35\u0e49\u0e43\u0e0a\u0e49\u0e44\u0e14\u0e49\u0e2a\u0e39\u0e07\u0e2a\u0e38\u0e14 <b>2 \u0e40\u0e04\u0e23\u0e37\u0e48\u0e2d\u0e07\u0e40\u0e17\u0e48\u0e32\u0e19\u0e31\u0e49\u0e19</b><br>
    \u0e2b\u0e32\u0e01\u0e40\u0e0a\u0e37\u0e48\u0e2d\u0e21\u0e15\u0e48\u0e2d\u0e40\u0e01\u0e34\u0e19 2 IP \u0e08\u0e30\u0e16\u0e39\u0e01\u0e41\u0e1a\u0e19\u0e2d\u0e31\u0e15\u0e42\u0e19\u0e21\u0e31\u0e15\u0e34 12 \u0e0a\u0e31\u0e48\u0e27\u0e42\u0e21\u0e07
  </div>
</div>
<div class="toast" id="toast">\u2714 Copied!</div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<script>
var vlessLink = \"""" + lnk_js + """\";
var VLESS_EMAIL = \"""" + em + """\";
var API_TOKEN   = \"""" + tok + """\";
var DATA_LIMIT_GB = """ + str(dg_num) + """;

// ── Render link chars ─────────────────────────────────────────
(function(){
  var box=document.getElementById("vlink-box"), html="";
  for(var i=0;i<vlessLink.length;i++){
    var ch=vlessLink[i];
    if(ch==="<")ch="&lt;";
    else if(ch===">")ch="&gt;";
    else if(ch==="&")ch="&amp;";
    var d=(-(i*0.04)).toFixed(2);
    html+='<span class="link-char" style="animation-delay:'+d+'s">'+ch+'</span>';
  }
  box.innerHTML=html;
})();

// ── Copy & QR ─────────────────────────────────────────────────
function copyLink(){
  if(navigator.clipboard){navigator.clipboard.writeText(vlessLink).then(showToast).catch(function(){var ta=document.createElement("textarea");ta.value=vlessLink;document.body.appendChild(ta);ta.select();document.execCommand("copy");document.body.removeChild(ta);showToast();});}
  else{var ta=document.createElement("textarea");ta.value=vlessLink;
    document.body.appendChild(ta);ta.select();document.execCommand("copy");
    document.body.removeChild(ta);showToast();}
}
function showToast(){
  var el=document.getElementById("toast");
  el.classList.add("show");
  setTimeout(function(){el.classList.remove("show");},2000);
}
var qrDone=false;
function toggleQR(){
  var b=document.getElementById("qrbox");
  if(b.style.display==="block"){b.style.display="none";return;}
  b.style.display="block";
  if(!qrDone){new QRCode(b,{text:vlessLink,width:250,height:250,
    colorDark:"#000",colorLight:"#fff",correctLevel:QRCode.CorrectLevel.M});
    qrDone=true;}
}

// ── Realtime Traffic Polling ──────────────────────────────────
function barColor(pct){
  if(pct<50) return "#00ff80";
  if(pct<80) return "#ffcc00";
  return "#ff4060";
}

async function fetchTraffic(){
  if(!API_TOKEN || API_TOKEN==="N/A") return;
  try{
    var r = await fetch('/sshws-api/api/vless-traffic/'+encodeURIComponent(VLESS_EMAIL),{
      headers:{'Authorization':'Bearer '+API_TOKEN}
    });
    if(!r.ok) return;
    var d = await r.json();
    if(!d.ok) return;

    var usedGb  = d.used_gb  || 0;
    // ใช้ limit จาก API ก่อน ถ้า 0 ให้ fallback ใช้ค่าที่ฝังไว้ใน HTML
    var limGb   = (d.limit_gb && d.limit_gb >= 1) ? d.limit_gb : (DATA_LIMIT_GB >= 1 ? DATA_LIMIT_GB : 0);
    // คำนวณ pct ใหม่ถ้า limit มาจาก fallback
    var pct     = (limGb >= 1) ? Math.min(100, Math.round(usedGb / limGb * 100 * 10) / 10) : (d.pct || 0);
    var barEl   = document.getElementById('bar-fill');
    var txtEl   = document.getElementById('data-txt');
    var pctEl   = document.getElementById('bar-pct');

    var downGb = d.down_gb || 0;
    var upGb   = d.up_gb   || 0;

    if(limGb >= 1){
      // มี limit — แสดง used/limit + ↓↑ แยก + bar
      if(pct >= 100 || d.over_limit){
        txtEl.textContent = '\u26a0\ufe0f Data หมดแล้ว! ' + usedGb.toFixed(2) + ' / ' + limGb + ' GB  \u2193'+downGb.toFixed(2)+' \u2191'+upGb.toFixed(2)+' GB';
        txtEl.style.color = '#ff4060';
        pctEl.textContent = '100% — หมด';
        pctEl.style.color = '#ff4060';
        if(!fetchTraffic._kicked){
          fetchTraffic._kicked = true;
          fetch('/sshws-api/api/kick',{
            method:'POST',
            headers:{'Authorization':'Bearer '+API_TOKEN,'Content-Type':'application/json'},
            body: JSON.stringify({user: VLESS_EMAIL.split('-')[0] || VLESS_EMAIL})
          }).catch(function(){});
        }
      } else {
        txtEl.textContent = usedGb.toFixed(2) + ' / ' + limGb + ' GB  \u2193'+downGb.toFixed(2)+' \u2191'+upGb.toFixed(2)+' GB';
        txtEl.style.color = '';
        fetchTraffic._kicked = false;
      }
      var bc = barColor(pct);
      barEl.classList.remove('bar-rgb');
      barEl.style.background = 'linear-gradient(90deg,'+bc+','+bc+'88)';
      barEl.style.boxShadow  = '0 0 8px '+bc+'66';
      barEl.style.width      = pct+'%';
      pctEl.textContent      = pct+'%';
      pctEl.style.color      = bc+'aa';
    } else {
      // ไม่จำกัด — แสดง ↓↑ เสมอ
      txtEl.textContent = '\u2193 '+downGb.toFixed(2)+' GB  \u2191 '+upGb.toFixed(2)+' GB';
      txtEl.style.color = '';
      barEl.style.width      = '100%';
      barEl.style.background = '';
      barEl.style.boxShadow  = '';
      barEl.classList.add('bar-rgb');
      pctEl.textContent      = '\u221e ไม่จำกัด';
      pctEl.style.color      = '#00ff8088';
    }
  } catch(e){}
}

// โหลดครั้งแรก + polling ทุก 10 วิ
fetchTraffic();
setInterval(fetchTraffic, 10000);
</script>
</body></html>"""

os.makedirs(os.path.dirname(outfile), exist_ok=True)
with open(outfile, 'w', encoding='utf-8') as f:
    f.write(html)
print("OK:" + outfile)
PYEOF
  printf "${GR}✔ สร้างไฟล์ HTML: %s${RS}\n" "$outfile"
}

# ══════════════════════════════════════════════════════════════
# เมนู 1 — ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ (v11 full rewrite)
# ══════════════════════════════════════════════════════════════

# ── RGB Progress Bar ──────────────────────────────────────────
rgb_bar() {
  local pct="$1" label="${2:-}" width=40
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  # คำนวณสี RGB ตาม % (แดง→ส้ม→เหลือง→เขียว→ฟ้า→ม่วง)
  local r g b
  if   (( pct < 20 )); then r=255; g=$(( pct*12 )); b=85
  elif (( pct < 40 )); then r=255; g=$(( 240+(pct-20)*2 )); b=0
  elif (( pct < 60 )); then r=$(( 255-(pct-40)*10 )); g=255; b=0
  elif (( pct < 80 )); then r=0; g=255; b=$(( (pct-60)*12 ))
  else                      r=$(( (pct-80)*12 )); g=$(( 255-(pct-80)*10 )); b=255
  fi
  local bar_color="\033[38;2;${r};${g};${b}m"
  local bar_fill; bar_fill=$(printf '%0.s█' $(seq 1 $filled) 2>/dev/null || printf '█%.0s' $(seq 1 $filled))
  local bar_empty; bar_empty=$(printf '%0.s░' $(seq 1 $empty) 2>/dev/null || printf '░%.0s' $(seq 1 $empty))
  printf "  ${bar_color}[%s%s]${RS} ${WH}%3d%%${RS} ${YE}%s${RS}\n" \
    "$bar_fill" "$bar_empty" "$pct" "$label"
}

# ── ฟังก์ชัน detect webBasePath จาก sqlite3 ──────────────────
# อ่านจาก db โดยตรง ไม่เดา ไม่สร้างเอง
# รับ arg $1 = จำนวน retry (default 3) เผื่อ db ยัง lock
detect_xui_basepath() {
  # อ่าน webBasePath จาก db โดยตรง — installer generate random ให้เอง
  # ไม่แตะ ไม่แก้ แค่อ่าน
  local db_path="/etc/x-ui/x-ui.db"
  local max_try="${1:-3}"
  if ! command -v sqlite3 &>/dev/null; then echo ""; return; fi
  if [[ ! -f "$db_path" ]];            then echo ""; return; fi
  local bp=""
  for _dbtry in $(seq 1 "$max_try"); do
    bp=$(sqlite3 "$db_path" \
      "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;" \
      2>/dev/null | tr -d '[:space:]')
    [[ -n "$bp" ]] && echo "$bp" && return
    sleep 1
  done
  echo ""
}

detect_xui_secret() { :; }  # ไม่ใช้แล้ว

detect_xui_port() {
  local db_path="/etc/x-ui/x-ui.db"
  local _p=""
  if command -v sqlite3 &>/dev/null && [[ -f "$db_path" ]]; then
    _p=$(sqlite3 "$db_path" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')
  fi
  [[ -z "$_p" ]] && _p=$(ss -tlnp 2>/dev/null | grep x-ui | grep -oP ':\K[0-9]+' | head -1)
  [[ -z "$_p" ]] && _p="2053"
  echo "$_p"
}

menu_1() {
  clear
  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

  printf "${R1}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  ☠️  ${R2}${BLD}ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ${RS}           ${R1}│${RS}\n"
  printf "${R1}└──────────────────────────────────────────────────┘${RS}\n\n"

  # [FIX] ตรวจและติดตั้ง sqlite3 ก่อนใช้งาน — จำเป็นสำหรับอ่าน/เขียน x-ui.db
  if ! command -v sqlite3 &>/dev/null; then
    printf "  ${YE}⏳ ติดตั้ง sqlite3...${RS}\n"
    apt-get install -y -qq sqlite3 2>/dev/null || apt-get install -y sqlite3 2>/dev/null || true
    if ! command -v sqlite3 &>/dev/null; then
      printf "  ${RD}✗ ติดตั้ง sqlite3 ไม่สำเร็จ — ตรวจ apt แล้วลองใหม่${RS}\n"
      read -rp "  Enter..."; return
    fi
    printf "  ${GR}✔ ติดตั้ง sqlite3 สำเร็จ${RS}\n\n"
  fi

  # ── ถ้า x-ui รันอยู่แล้ว ให้ลบออกอัตโนมัติก่อน ─────────────
  if systemctl is-active --quiet x-ui 2>/dev/null; then
    printf "  ${YE}⚙ พบ x-ui รันอยู่ — กำลังลบออกและติดตั้งใหม่...${RS}\n"
    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true
    rm -f /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui /usr/local/bin/x-ui
    rm -rf /etc/x-ui
    systemctl daemon-reload 2>/dev/null || true
    printf "  ${GR}✔ ลบ x-ui เก่าเรียบร้อย${RS}\n\n"
  fi

  # ── ถาม Username / Password ──────────────────────────────────
  read -rp "$(printf "  ${YE}Username admin: ${RS}")" _u
  [[ -z "$_u" ]] && _u="admin"

  local _pw _pw2
  while true; do
    read -rsp "$(printf "  ${YE}Password admin (ห้ามว่าง): ${RS}")" _pw; echo ""
    [[ -n "$_pw" ]] && break
    printf "  ${RD}✗ Password ห้ามว่าง${RS}\n"
  done
  read -rsp "$(printf "  ${YE}ยืนยัน Password: ${RS}")" _pw2; echo ""
  if [[ "$_pw" != "$_pw2" ]]; then
    printf "\n  ${RD}✗ Password ไม่ตรงกัน — ยกเลิก${RS}\n"
    read -rp "  Enter..."; return
  fi

  mkdir -p /etc/chaiya
  echo "$_u"  > /etc/chaiya/xui-user.conf
  echo "$_pw" > /etc/chaiya/xui-pass.conf
  chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf
  printf "\n"

  # ════════════════════════════════════════════════════════════
  # Progress bar เดียว ครอบทุกขั้นตอน (install → port → API → inbound)
  # ════════════════════════════════════════════════════════════

  # ════════════════════════════════════════════════════════════
  # ROOT CAUSE จากการทดสอบ:
  # 1. installer version ใหม่ start x-ui ที่ port random ไม่ใช่ 2053
  # 2. basepath ที่ installer สร้างไม่ตรงกับที่เราสร้าง → login ผิด path
  # 3. เราต้องอ่าน port + basepath จาก db หลัง install แล้วค่อย set ทับ
  # แนวทางใหม่: install → stop → อ่าน db → set ทุกอย่างทับ → start
  # ════════════════════════════════════════════════════════════

  local _xui_db="/etc/x-ui/x-ui.db"
  local _panel_port="2053"  # target port ที่เราต้องการ

  # ── 10% ดาวน์โหลด install script ──
  rgb_bar 10 "ดาวน์โหลด install script..."
  local _xui_sh; _xui_sh=$(mktemp /tmp/xui-XXXXX.sh)
  if ! curl -Ls "https://raw.githubusercontent.com/MHSanaei/3x-ui/v2.8.11/install.sh" \
       -o "$_xui_sh" 2>/dev/null || [[ ! -s "$_xui_sh" ]]; then
    printf "  ${RD}✗ ดาวน์โหลด install script ล้มเหลว${RS}\n"
    read -rp "  Enter..."; return
  fi

  # ── 15% รัน installer ──────────────────────────────────────────
  # [FIX v2] ไม่ใช้ pipe คงที่ "y\n2053\n2\n\n80\n" อีกต่อไป
  # เพราะ installer เวอร์ชันใหม่เปลี่ยนลำดับ/จำนวนคำถามได้
  # วิธีใหม่: ใช้ expect ถ้ามี หรือ timeout-based stdin feeding
  rgb_bar 15 "กำลังติดตั้ง 3x-ui (อาจใช้ 1-3 นาที)..."
  if command -v expect &>/dev/null; then
    expect -c "
      set timeout 180
      spawn bash $_xui_sh v2.8.11
      expect {
        -re {(?i)(confirm|proceed|install|continue).*\[y/n\]} { send \"y\r\"; exp_continue }
        -re {(?i)port.*panel}                                  { send \"2053\r\"; exp_continue }
        -re {(?i)(domain|ip|option 2)}                         { send \"2\r\"; exp_continue }
        -re {(?i)(basepath|web.*path|enter.*path)}             { send \"\r\"; exp_continue }
        -re {(?i)(http.*port|port.*80|challenge)}              { send \"80\r\"; exp_continue }
        eof
      }
    " >> /var/log/chaiya-xui-install.log 2>&1 || true
  else
    # fallback: ป้อน input ครอบคลุมมากขึ้น (y + port + ตัวเลือก IP + enter + port 80)
    # ส่ง y เพิ่มพิเศษ 3 ตัว และ enter เพิ่มเผื่อคำถามเพิ่มขึ้น
    printf "y\ny\n2053\n2\n\n80\ny\n\n\n" | bash "$_xui_sh" v2.8.11 >> /var/log/chaiya-xui-install.log 2>&1 || true
  fi
  rm -f "$_xui_sh"

  # ── 25% รอให้ installer เสร็จ + x-ui ขึ้นจริง ──────────────────
  # installer start x-ui เองตอนสุดท้าย บน port ที่ installer กำหนด
  # รอ db มีอยู่ + x-ui process ขึ้น = install เสร็จ 100%
  rgb_bar 25 "รอ installer เสร็จสมบูรณ์..."
  local _install_ok=0
  printf "  ${YE}⏳ รอ x-ui ขึ้น (สูงสุด 120s)...${RS}\n"
  for _i in $(seq 1 60); do
    # เช็ค db มีก่อน แล้วค่อยเช็ค process
    if [[ -f "$_xui_db" ]] && pgrep -x x-ui &>/dev/null; then
      # รออีก 3s ให้ x-ui write db เสร็จ
      sleep 3
      _install_ok=1; break
    fi
    sleep 2
  done

  if [[ "$_install_ok" == "0" ]]; then
    printf "  ${RD}✗ install ล้มเหลว — ดู: tail -50 /var/log/chaiya-xui-install.log${RS}\n"
    read -rp "  Enter..."; return
  fi
  printf "  ${GR}✔ installer เสร็จสมบูรณ์${RS}\n"

  # ── 35% stop x-ui อย่างปลอดภัย ────────────────────────────────
  # หยุดหลัง install สมบูรณ์ → db พร้อม 100% → ปลอดภัยที่จะแก้
  rgb_bar 35 "หยุด x-ui เพื่อ overwrite config..."
  systemctl stop x-ui 2>/dev/null || true
  pkill -9 x-ui 2>/dev/null || true  # kill ให้แน่ใจ
  for _si in $(seq 1 15); do
    pgrep -x x-ui &>/dev/null || break
    sleep 1
  done
  sleep 2  # รอ sqlite3 flush ให้เสร็จ

  if [[ ! -f "$_xui_db" ]]; then
    printf "  ${RD}✗ ไม่พบ x-ui.db — ดู: tail -50 /var/log/chaiya-xui-install.log${RS}\n"
    read -rp "  Enter..."; return
  fi

  # ── 40% อ่าน webBasePath จาก db ──────────────────────────────
  rgb_bar 40 "อ่าน webBasePath จาก db..."
  local _basepath _xui_real_port
  _basepath=$(detect_xui_basepath 5)
  _xui_real_port=$(detect_xui_port)

  # installer generate random basepath เอง — แค่อ่านมาใช้ ไม่แก้ไข
  if [[ -n "$_basepath" ]]; then
    printf "  ${GR}✔ webBasePath: ${WH}%s${RS}\n" "$_basepath"
    printf "  ${GR}✔ Panel URL: ${WH}http://%s:%s%s/${RS}\n" "$MY_IP" "$_xui_real_port" "$_basepath"
  else
    _basepath="/"
    printf "  ${YE}⚠ ไม่พบ webBasePath ใน db — ใช้ /${RS}\n"
  fi
  echo "$_basepath" > /etc/chaiya/xui-basepath.conf
  echo "$_xui_real_port" > /etc/chaiya/xui-port.conf

  # ── 50% overwrite credential + port ลง db โดยตรง ────────────────
  # ทำขณะ x-ui หยุด = ปลอดภัย 100% ไม่มี race condition
  rgb_bar 50 "Set credential + port ลง db..."

  # hash password ด้วย bcrypt
  local _pw_hash=""
  _pw_hash=$(python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(rounds=10)).decode())
" "$_pw" 2>/dev/null || true)

  if [[ -n "$_pw_hash" ]]; then
    sqlite3 "$_xui_db" \
      "UPDATE users SET username='${_u}', password='${_pw_hash}' WHERE id=1;" 2>/dev/null || true
    printf "  ${GR}✔ Set username/password (bcrypt) ลง db สำเร็จ${RS}\n"
  fi

  # [FIX] ใช้ x-ui CLI ตั้ง credential เสมอ (ทำคู่กับ sqlite3)
  # เพราะ x-ui version ใหม่อาจใช้ bcrypt format ต่างกัน หรือ overwrite db ตอน start
  /usr/local/x-ui/x-ui setting -username "$_u" -password "$_pw" \
    >> /var/log/chaiya-xui-install.log 2>&1 || true
  printf "  ${GR}✔ Set credential ผ่าน x-ui CLI สำเร็จ${RS}\n"

  # [FIX] 3x-ui version ใหม่ installer set port ให้แล้ว — ไม่ต้อง overwrite
  # แค่อัพเดต xui-port.conf ให้ตรงกับที่ installer ตั้ง
  printf "  ${GR}✔ Port: ${WH}%s${RS} (จาก installer)\n" "$_xui_real_port"

  # verify
  local _db_user
  _db_user=$(sqlite3 "$_xui_db" "SELECT username FROM users WHERE id=1;" 2>/dev/null)
  [[ -z "$_db_user" ]] && _db_user="(ใช้ CLI)" || true
  printf "  ${CY}→ db verify: port=%s user=%s${RS}\n" "$_xui_real_port" "$_db_user"

  # ── 60% start x-ui พร้อม config ใหม่ ───────────────────────────
  rgb_bar 60 "Start x-ui พร้อม config ใหม่..."
  systemctl start x-ui 2>/dev/null || true

  # [FIX] รอ x-ui init db เสร็จก่อน (x-ui version ใหม่ทำ migration ตอน start แรก)
  # แล้ว re-set credential ทันทีด้วย CLI เพื่อป้องกัน overwrite
  sleep 8
  /usr/local/x-ui/x-ui setting -username "$_u" -password "$_pw" \
    >> /var/log/chaiya-xui-install.log 2>&1 || true
  sqlite3 "$_xui_db" \
    "INSERT OR REPLACE INTO settings(key,value) VALUES('webPort','2053');" 2>/dev/null || true
  printf "  ${GR}✔ Re-confirm credential หลัง x-ui init เสร็จ${RS}\n"

  # รอ x-ui ขึ้นที่ port 2053 (ที่เรา set ลง db แล้ว)
  local _bp_trim; _bp_trim=$(echo "$_basepath" | sed 's|/$||')
  local _ok=0
  printf "  ${YE}⏳ รอ x-ui ขึ้นที่ port 2053 (สูงสุด 60s)...${RS}\n"
  for _i in $(seq 1 30); do
    if curl -s  --max-time 3 "http://127.0.0.1:2053${_bp_trim}/"  &>/dev/null ||
       curl -sk --max-time 3 "https://127.0.0.1:2053${_bp_trim}/" &>/dev/null ||
       curl -s  --max-time 3 "http://127.0.0.1:2053/"             &>/dev/null ||
       curl -sk --max-time 3 "https://127.0.0.1:2053/"            &>/dev/null; then
      _ok=1; break
    fi
    sleep 2
  done

  if [[ "$_ok" == "0" ]]; then
    printf "  ${RD}✗ x-ui ไม่ขึ้นที่ port 2053 — ตรวจ: systemctl status x-ui${RS}\n"
    # debug: แสดง port ที่ x-ui ฟังจริง
    local _actual_port
    _actual_port=$(ss -tlnp 2>/dev/null | grep x-ui | grep -oP ':\K[0-9]+' | head -1)
    [[ -n "$_actual_port" ]] && printf "  ${YE}→ x-ui กำลังฟัง port: %s${RS}\n" "$_actual_port"
    read -rp "  Enter..."; return
  fi
  printf "  ${GR}✔ x-ui ขึ้นสำเร็จที่ port 2053${RS}\n"

  # ── 80% login API ────────────────────────────────────────────────
  rgb_bar 80 "Login API..."
  local _login_ok=0

  # debug: แสดงข้อมูลที่จะใช้ login
  printf "  ${CY}→ Login: user=%s port=%s basepath=%s${RS}\n" "$_u" "2053" "$_basepath"

  for _ltry in 1 2 3 4 5; do
    if xui_login 2>/dev/null; then
      _login_ok=1
      printf "  ${GR}✔ Login API สำเร็จ (ครั้งที่ %s)${RS}\n" "$_ltry"
      break
    fi
    printf "  ${YE}⚠ Login ครั้งที่ %s ล้มเหลว${RS}\n" "$_ltry"

    # [FIX] ทุกครั้งที่ login ล้มเหลว: stop → reset credential (CLI+db) → start ใหม่
    systemctl stop x-ui 2>/dev/null || true
    sleep 3

    # อ่าน basepath จาก db อีกครั้ง เผื่อ x-ui reset ค่า
    local _bp_recheck
    _bp_recheck=$(detect_xui_basepath 3)
    if [[ -n "$_bp_recheck" && "$_bp_recheck" != "$_basepath" ]]; then
      printf "  ${YE}⚠ basepath เปลี่ยน: %s → %s${RS}\n" "$_basepath" "$_bp_recheck"
      _basepath="$_bp_recheck"
      echo "$_basepath" > /etc/chaiya/xui-basepath.conf
      _bp_trim=$(echo "$_basepath" | sed 's|/$||')
    fi

    # [FIX] ใช้ x-ui CLI เป็นหลัก (ถูกต้องที่สุด — ไม่ต้องสนใจ bcrypt format)
    /usr/local/x-ui/x-ui setting -username "$_u" -password "$_pw" \
      >> /var/log/chaiya-xui-install.log 2>&1 || true
    # เขียน sqlite3 ด้วยเพื่อ double confirm port + bcrypt hash
    sqlite3 "$_xui_db" \
      "INSERT OR REPLACE INTO settings(key,value) VALUES('webPort','2053');" 2>/dev/null || true
    if [[ -n "$_pw_hash" ]]; then
      sqlite3 "$_xui_db" \
        "UPDATE users SET username='${_u}', password='${_pw_hash}' WHERE id=1;" 2>/dev/null || true
    fi
    printf "  ${YE}⚠ Re-set credential (CLI + db) ครั้งที่ %s${RS}\n" "$_ltry"

    systemctl start x-ui 2>/dev/null || true
    # [FIX] รอให้ x-ui init db เสร็จก่อน login — เพิ่มจาก 5s เป็น 10s
    sleep 10
  done

  # ── 85–95% สร้าง inbounds ──
  local _inbounds=(
    "8080:CHAIYA-AIS-8080:cj-ebb.speedtest.net"
    "8880:CHAIYA-TRUE-8880:true-internet.zoom.xyz.services"
  )
  local _ib_n=0 _ib_results=()
  for _item in "${_inbounds[@]}"; do
    (( _ib_n++ )) || true
    local _ibport; _ibport=$(echo "$_item" | cut -d: -f1)
    local _ibremark; _ibremark=$(echo "$_item" | cut -d: -f2)
    local _ibsni; _ibsni=$(echo "$_item" | cut -d: -f3-)
    local _ibuid; _ibuid=$(cat /proc/sys/kernel/random/uuid)

    rgb_bar $(( 85 + _ib_n * 5 )) "สร้าง inbound port ${_ibport}..."

    # 3x-ui v2+ ต้องการ settings/streamSettings/sniffing เป็น JSON string (ไม่ใช่ object)
    # แต่บาง version ต้องการ object — ลอง string ก่อน (ตรงกับ source code ของ 3x-ui)
    local _payload
    _payload=$(python3 -c "
import json, sys
uid, remark, port, sni = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
settings_obj = {
  'clients': [{'id': uid, 'flow': '', 'email': 'chaiya-' + remark,
               'limitIp': 0, 'totalGB': 0, 'expiryTime': 0,
               'enable': True, 'comment': '', 'reset': 0}],
  'decryption': 'none'
}
stream_obj = {
  'network': 'ws',
  'security': 'none',
  'wsSettings': {'path': '/vless', 'headers': {'Host': sni}}
}
sniff_obj = {'enabled': True, 'destOverride': ['http', 'tls']}
# 3x-ui API /inbounds/add ต้องการ string ทั้ง 3 fields
payload = {
  'remark':         remark,
  'enable':         True,
  'listen':         '',
  'port':           port,
  'protocol':       'vless',
  'settings':       json.dumps(settings_obj),
  'streamSettings': json.dumps(stream_obj),
  'sniffing':       json.dumps(sniff_obj),
  'tag':            'inbound-' + str(port),
}
print(json.dumps(payload))
" "$_ibuid" "$_ibremark" "$_ibport" "$_ibsni")

    # retry สร้าง inbound สูงสุด 3 ครั้ง
    local _res _created=0
    for _try in 1 2 3; do
      _res=$(xui_api POST "/panel/api/inbounds/add" "$_payload" 2>/dev/null)
      if echo "$_res" | grep -q '"success":true'; then
        _created=1; break
      fi
      # ถ้า port ซ้ำอยู่แล้ว ถือว่าสำเร็จ
      if echo "$_res" | grep -qi "already\|duplicate\|exist"; then
        _created=2; break
      fi
      # login ใหม่แล้วลองอีกครั้ง
      xui_login 2>/dev/null || true
      sleep 3
    done

    ufw allow "${_ibport}"/tcp >> /dev/null 2>&1 || true

    if [[ "$_created" == "1" ]]; then
      _ib_results+=("${GR}✔ Port ${_ibport} (${_ibremark}) — สร้างสำเร็จ${RS}")
    elif [[ "$_created" == "2" ]]; then
      _ib_results+=("${CY}ℹ Port ${_ibport} (${_ibremark}) — มีอยู่แล้ว${RS}")
    else
      # แสดง response จริงเพื่อ debug
      local _err_msg; _err_msg=$(echo "$_res" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('msg','unknown'))" 2>/dev/null || echo "no response")
      _ib_results+=("${RD}✗ Port ${_ibport} — ${_err_msg}${RS}")
    fi
  done

  rgb_bar 100 "เสร็จสมบูรณ์!"
  printf "\n"

  # ════════════════════════════════════════════════════════════
  # สรุปผล
  # ════════════════════════════════════════════════════════════
  local _proto; _proto=$(xui_proto)
  local _host_display="$MY_IP"
  if [[ -f "$DOMAIN_FILE" ]]; then
    local _d_chk; _d_chk=$(cat "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$_d_chk" ]] && getent hosts "$_d_chk" &>/dev/null && _host_display="$_d_chk"
  fi

  # อ่าน basepath และ port จริงจาก db (installer set ให้แล้ว)
  local _final_bp; _final_bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | tr -d '[:space:]')
  local _final_port; _final_port=$(cat /etc/chaiya/xui-port.conf 2>/dev/null | tr -d '[:space:]')
  [[ -z "$_final_bp"   ]] && _final_bp="/"
  [[ -z "$_final_port" ]] && _final_port="2053"

  # normalize: "/" → ไม่ต่อ path, "/abc..." → ต่อตรงๆ
  local _bp_url; [[ "$_final_bp" == "/" ]] && _bp_url="" || _bp_url="$_final_bp"

  local _panel_url="${_proto}://${_host_display}:${_final_port}${_bp_url}/"
  local _api_url="${_proto}://${_host_display}:${_final_port}${_bp_url}/panel/api"

  printf "${R1}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R1}│${RS}  🌐 Panel  : ${WH}%s${RS}\n" "$_panel_url"
  printf "${R1}│${RS}  🔗 API    : ${WH}%s${RS}\n" "$_api_url"
  printf "${R1}│${RS}  👤 User   : ${WH}%s${RS}  🔑 Pass: ${WH}%s${RS}\n" "$_u" "$_pw"
  printf "${R1}├──────────────────────────────────────────────────┤${RS}\n"
  for _r in "${_ib_results[@]}"; do
    printf "${R1}│${RS}  $(printf "${_r}")\n"
  done
  [[ "$_login_ok" == "0" ]] && printf "${R1}│${RS}  ${YE}⚠ Login API ไม่สำเร็จ — ลอง login panel เอง${RS}\n"
  printf "${R1}└──────────────────────────────────────────────────┘${RS}\n\n"
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 2 — ตั้งค่าโดเมน + SSL
# ══════════════════════════════════════════════════════════════
menu_2() {
  clear
  printf "${R3}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R3}║${RS}  🔐 ${WH}ตั้งค่าโดเมน + SSL อัตโนมัติ${RS}  ${R3}[เมนู 2]${RS}        ${R3}║${RS}\n"
  printf "${R3}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  local _cur_domain _cur_wsport
  _cur_domain=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "ยังไม่ตั้งค่า")
  _cur_wsport=$(cat /etc/chaiya/wsport.conf 2>/dev/null || echo "2083")
  printf "${CY}┌─[ ค่าปัจจุบัน ]────────────────────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  🌐 โดเมน  : ${YE}%-41s${CY}│${RS}\n" "$_cur_domain"
  printf "${CY}│${RS}  🔌 WS Port: ${YE}%-41s${CY}│${RS}\n" "$_cur_wsport"
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  printf "${WH}📌 ใส่โดเมนที่ต้องการ (DNS ต้องชี้มาที่ VPS นี้แล้ว)${RS}\n"
  printf "${YE}   ตัวอย่าง: vpn.example.com${RS}\n\n"

  local domain
  read -rp "$(printf "${YE}กรอกโดเมน: ${RS}")" domain
  [[ -z "$domain" ]] && { printf "${YE}↩ ยกเลิก${RS}\n"; read -rp "Enter..."; return; }

  # ── เลือก WS Port ─────────────────────────────────────────
  printf "\n${YE}┌─[ เลือก Port WebSocket SSH tunnel ]────────────────────┐${RS}\n"
  printf "${YE}│${RS}  ${OR}⚠  ห้ามใช้: 80 81 109 143 443 2053 8080 8880${RS}        ${YE}│${RS}\n"
  printf "${YE}├────────────────────────────────────────────────────────┤${RS}\n"
  printf "${YE}│${RS}  ${GR}1.${RS}  Port ${WH}2083${RS} — Cloudflare SSL ✅ แนะนำ              ${YE}│${RS}\n"
  printf "${YE}│${RS}  ${GR}2.${RS}  Port ${WH}2087${RS} — Cloudflare SSL ✅                    ${YE}│${RS}\n"
  printf "${YE}│${RS}  ${GR}3.${RS}  Port ${WH}2096${RS} — Cloudflare SSL ✅                    ${YE}│${RS}\n"
  printf "${YE}│${RS}  ${GR}4.${RS}  Port ${WH}8443${RS} — HTTPS alt                            ${YE}│${RS}\n"
  printf "${YE}│${RS}  ${GR}5.${RS}  กรอก port เอง                                      ${YE}│${RS}\n"
  printf "${YE}└────────────────────────────────────────────────────────┘${RS}\n"
  read -rp "$(printf "${YE}เลือก [1-5, default=1]: ${RS}")" _wsp_choice

  local _wsport _blocked="22 80 81 109 143 443 2053 2082 7300 8080 8880"
  case "${_wsp_choice:-1}" in
    1) _wsport=2083 ;;
    2) _wsport=2087 ;;
    3) _wsport=2096 ;;
    4) _wsport=8443 ;;
    5)
      while true; do
        read -rp "$(printf "${YE}กรอก port (1024-65535): ${RS}")" _wsport
        if [[ ! "$_wsport" =~ ^[0-9]+$ ]] || (( _wsport < 1024 || _wsport > 65535 )); then
          printf "${RD}❌ port ไม่ถูกต้อง${RS}\n"; continue
        fi
        if echo "$_blocked" | grep -qw "$_wsport"; then
          printf "${RD}❌ port %s ถูกใช้โดย service อื่นอยู่แล้ว${RS}\n" "$_wsport"; continue
        fi
        break
      done ;;
    *) _wsport=2083 ;;
  esac

  echo "$domain"  > "$DOMAIN_FILE"
  echo "$_wsport" > /etc/chaiya/wsport.conf
  ufw allow "$_wsport"/tcp 2>/dev/null || true
  ufw allow 443/tcp        2>/dev/null || true
  apt-get install -y certbot dnsutils -qq 2>/dev/null || true

  # ── [0/4] ตรวจ DNS ก่อน — ถ้าไม่ชี้มา IP นี้จะล้มแน่ ──────
  printf "\n${YE}⏳ [0/4] ตรวจสอบ DNS...${RS}\n"
  local _my_ip; _my_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  local _dns_ip; _dns_ip=$(dig +short "$domain" 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  printf "  IP เซิร์ฟเวอร์ : ${WH}%s${RS}\n" "$_my_ip"
  printf "  DNS ของ %s : ${WH}%s${RS}\n" "$domain" "${_dns_ip:-ไม่พบ}"
  if [[ -z "$_dns_ip" ]]; then
    printf "${RD}❌ DNS ไม่พบ A record — ตั้ง A record ชี้มาที่ %s ก่อน แล้วรอ 5-30 นาที${RS}\n" "$_my_ip"
    read -rp "$(printf "${YE}กด Enter ย้อนกลับ...${RS}")"; return
  fi
  if [[ "$_dns_ip" != "$_my_ip" ]]; then
    printf "${RD}❌ DNS ชี้ไปที่ %s ≠ IP เซิร์ฟเวอร์ %s${RS}\n" "$_dns_ip" "$_my_ip"
    read -rp "$(printf "${OR}ลองต่อไปถึงแม้ DNS ไม่ตรง? [y/N]: ${RS}")" _force
    [[ "${_force,,}" != "y" ]] && return
  else
    printf "  ${GR}✅ DNS ถูกต้อง${RS}\n"
  fi

  # ── [1/4] เตรียม nginx รับ ACME challenge ───────────────────
  printf "\n${YE}⏳ [1/4] เตรียม webroot สำหรับ certbot...${RS}\n"
  mkdir -p /var/www/html/.well-known/acme-challenge
  local _stopped_svcs=()
  for _svc in chaiya-sshws apache2 lighttpd; do
    if systemctl is-active --quiet "$_svc" 2>/dev/null; then
      systemctl stop "$_svc" 2>/dev/null || true
      _stopped_svcs+=("$_svc")
      printf "  ${OR}⏹ หยุด %s ชั่วคราว${RS}\n" "$_svc"
    fi
  done
  fuser -k 80/tcp 2>/dev/null || true; sleep 1
  cat > /etc/nginx/conf.d/acme-temp.conf << 'ACMEEOF'
server {
    listen 80;
    server_name _;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 444; }
}
ACMEEOF
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  sleep 1
  printf "  ${GR}✅ nginx พร้อมรับ ACME challenge บน port 80${RS}\n"

  # ── [2/4] ขอ SSL certificate (webroot) ──────────────────────
  printf "\n${YE}⏳ [2/4] ขอ SSL certificate (certbot webroot)...${RS}\n"
  certbot certonly --webroot \
    -w /var/www/html \
    -d "$domain" \
    --non-interactive --agree-tos \
    -m "admin@${domain}" 2>&1
  rm -f /etc/nginx/conf.d/acme-temp.conf 2>/dev/null || true
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  for _s in "${_stopped_svcs[@]}"; do
    systemctl start "$_s" 2>/dev/null || true
    printf "  ${GR}▶ เริ่ม %s กลับแล้ว${RS}\n" "$_s"
  done

  local _cert_ok=false
  [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && _cert_ok=true

  if $_cert_ok; then
    printf "${GR}  ✅ SSL certificate สำเร็จ!${RS}\n"

    # ── [3/4] ตั้งค่า nginx (SSL + WS tunnel + Dashboard) ──
    printf "\n${YE}⏳ [3/4] ตั้งค่า nginx...${RS}\n"
    mkdir -p /var/www/html

    cat > /etc/nginx/sites-available/chaiya-ssl << SSLEOF
# ── Port 81: Dashboard (HTTP fallback — ใช้ได้เสมอ)
server {
    listen 81;
    server_name _;
    root /var/www/chaiya;

    location /config/ {
        alias /var/www/chaiya/config/;
        try_files \$uri =404;
        default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache";
    }
    location /sshws/ {
        alias /var/www/chaiya/;
        index sshws.html;
        try_files \$uri \$uri/ =404;
    }
    location /sshws-api/ {
        proxy_pass http://127.0.0.1:6789/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 60s;
    }
    location /xui-traffic/ {
        proxy_pass http://127.0.0.1:2053/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Cookie \$http_cookie;
        proxy_read_timeout 30s;
    }
    location / { return 200 'Chaiya Panel OK'; add_header Content-Type text/plain; }
}

# ── Port 443: HTTPS — Dashboard + API
server {
    listen 443 ssl;
    server_name ${domain};
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location /sshws/ {
        alias /var/www/chaiya/;
        index sshws.html;
        try_files \$uri \$uri/ =404;
    }
    location /config/ {
        alias /var/www/chaiya/config/;
        try_files \$uri =404;
        default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache";
    }
    location /sshws-api/ {
        proxy_pass http://127.0.0.1:6789/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }
    location /xui-traffic/ {
        proxy_pass http://127.0.0.1:2053/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Cookie \$http_cookie;
        proxy_read_timeout 30s;
    }
    location / { return 200 'Chaiya HTTPS OK'; add_header Content-Type text/plain; }
}

# ── Port _wsport: WSS SSH Tunnel (websocat / ws-stunnel)
server {
    listen ${_wsport} ssl;
    server_name ${domain};
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # รับ WebSocket แล้วส่งต่อไป Dropbear port 143
    location / {
        proxy_pass http://127.0.0.1:143;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
SSLEOF

    # ลบ config เก่าที่อาจชน
    rm -f /etc/nginx/sites-enabled/chaiya \
          /etc/nginx/sites-enabled/chaiya-sshws \
          /etc/nginx/sites-enabled/default 2>/dev/null || true
    ln -sf /etc/nginx/sites-available/chaiya-ssl /etc/nginx/sites-enabled/chaiya-ssl

    _ensure_nginx


    if nginx -t 2>/dev/null; then
      printf "  ${GR}✅ nginx config OK${RS}\n"
    else
      printf "  ${RD}❌ nginx config error:${RS}\n"
      nginx -t
    fi

    # UFW เปิด port ที่เพิ่ม
    ufw allow 443/tcp  2>/dev/null || true
    ufw allow "${_wsport}"/tcp 2>/dev/null || true

    # ── อัพเดท token URL ใน sshws.html ให้ใช้ https ──────────
    local _tok; _tok=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')
    if [[ -f /var/www/chaiya/sshws.html && -n "$_tok" ]]; then
      # แทน BASE_URL ใน JS ที่ dashboard ใช้เรียก API
      sed -i "s|http://[^/']*/sshws-api/|https://${domain}/sshws-api/|g" \
        /var/www/chaiya/sshws.html 2>/dev/null || true
    fi

    # ── cron auto-renew (nginx renew — ไม่ต้อง standalone) ───
    (crontab -l 2>/dev/null || true) | grep -v 'certbot-renew' | \
      { cat; echo "0 3 * * * certbot renew --quiet --nginx --deploy-hook 'systemctl reload nginx' 2>/dev/null # certbot-renew"; } \
      | crontab -

    # ── [3x-ui] ยัด SSL cert เข้า x-ui ─────────────────────
    printf "\n${YE}⏳ ยัด SSL cert เข้า 3x-ui...${RS}\n"
    local _cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local _key_path="/etc/letsencrypt/live/${domain}/privkey.pem"
    local _xui_db="/etc/x-ui/x-ui.db"
    local _xui_cert_ok=false

    # ── วิธีที่ 1: sqlite3 โดยตรง (เชื่อถือได้ที่สุด ไม่ขึ้นกับ API/login) ──
    if [[ -f "$_xui_db" ]] && command -v sqlite3 &>/dev/null; then
      sqlite3 "$_xui_db" \
        "INSERT OR REPLACE INTO settings(key,value) VALUES('webCertFile','${_cert_path}');
         INSERT OR REPLACE INTO settings(key,value) VALUES('webKeyFile','${_key_path}');
         INSERT OR REPLACE INTO settings(key,value) VALUES('webPublicKeyFile','${_cert_path}');
         INSERT OR REPLACE INTO settings(key,value) VALUES('webPrivateKeyFile','${_key_path}');" \
        2>/dev/null && _xui_cert_ok=true
    fi

    # ── วิธีที่ 2: API fallback (กรณี db ยังไม่พร้อม) ──────────
    if ! $_xui_cert_ok; then
      local _xui_cert_payload _xui_cert_res
      # รอ x-ui พร้อมก่อน (สูงสุด 30 วินาที)
      local _wait=0
      while (( _wait < 15 )); do
        curl -sk --max-time 2 "http://127.0.0.1:$(xui_port)/" &>/dev/null && break
        curl -sk --max-time 2 "https://127.0.0.1:$(xui_port)/" &>/dev/null && break
        sleep 2; (( _wait++ )) || true
      done
      xui_login 2>/dev/null || true
      _xui_cert_payload=$(python3 -c "
import json
print(json.dumps({
  'webCertFile': '${_cert_path}',
  'webKeyFile':  '${_key_path}'
}))
")
      _xui_cert_res=$(xui_api POST "/panel/api/setting/update" "$_xui_cert_payload" 2>/dev/null)
      echo "$_xui_cert_res" | grep -q '"success":true' && _xui_cert_ok=true
    fi

    if $_xui_cert_ok; then
      printf "  ${GR}✅ ยัด cert เข้า x-ui สำเร็จ${RS}\n"
      printf "  ${YE}⏳ restart x-ui เพื่อโหลด cert...${RS}\n"
      systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || true
      sleep 3
      local _xui_port; _xui_port=$(xui_port)
      if curl -sk --max-time 5 "https://127.0.0.1:${_xui_port}/" 2>/dev/null | grep -q '.'; then
        printf "  ${GR}✅ x-ui ตอบ HTTPS ได้แล้ว!${RS}\n"
        printf "  ${CY}🔗 x-ui panel: https://%s:%s%s/${RS}\n" \
          "$domain" "$_xui_port" "$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | sed 's|/$||')"
      else
        printf "  ${OR}⚠ x-ui กำลังโหลด cert — เข้าได้ที่: https://%s:%s${RS}\n" \
          "$domain" "$_xui_port"
      fi
    else
      printf "  ${OR}⚠ ยัด cert ไม่สำเร็จ — ใส่เองได้ที่ x-ui panel → Panel Settings → SSL${RS}\n"
      printf "  ${WH}  Cert: %s${RS}\n" "$_cert_path"
      printf "  ${WH}  Key : %s${RS}\n" "$_key_path"
    fi

  else
    printf "${RD}  ❌ SSL ไม่สำเร็จ — ตรวจสอบ:${RS}\n"
    printf "  ${YE}1. DNS ของ ${WH}%s${YE} ชี้มาที่ IP นี้แล้วหรือยัง?${RS}\n" "$domain"
    printf "  ${YE}2. port 80 ถูก firewall บล็อกอยู่ไหม?${RS}\n"
    printf "  ${YE}3. log: ${WH}/var/log/letsencrypt/letsencrypt.log${RS}\n"
  fi

  # ── [4/4] restart ทุก service ที่หยุดไปกลับมาทั้งหมด ──────
  printf "\n${YE}⏳ [4/4] เริ่ม services กลับ...${RS}\n"
  for _s in "${_stopped_svcs[@]}"; do
    systemctl start "$_s" 2>/dev/null \
      && printf "  ${GR}✅ %s${RS}\n" "$_s" \
      || printf "  ${RD}❌ %s (start ไม่สำเร็จ)${RS}\n" "$_s"
  done
  # reload nginx หลัง restart ทุกตัวแล้ว
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true

  if $_cert_ok; then
    local _tok; _tok=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')
    local _xp2; _xp2=$(xui_port)
    local _bp2; _bp2=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | sed 's|/$||')
    local _xui_proto; _xui_proto=$(xui_proto)
    printf "\n${GR}╔══════════════════════════════════════════════════════╗${RS}\n"
    printf "${GR}║${RS}  ✅ ${WH}SSL + WebSocket พร้อมใช้งาน!${RS}                  ${GR}║${RS}\n"
    printf "${GR}╠══════════════════════════════════════════════════════╣${RS}\n"
    printf "${GR}║${RS}  🌐 Dashboard : ${CY}https://%s/sshws/sshws.html${RS}\n" "$domain"
    printf "${GR}║${RS}  🔑 Token URL : ${CY}https://%s/sshws/sshws.html?token=%s${RS}\n" "$domain" "$_tok"
    printf "${GR}║${RS}  🔌 WS Tunnel : ${YE}wss://%s:%s/${RS}\n" "$domain" "$_wsport"
    printf "${GR}║${RS}  📡 API (HTTPS): ${YE}https://%s/sshws-api/${RS}\n" "$domain"
    printf "${GR}║${RS}  🔒 SSL cert  : /etc/letsencrypt/live/%s/\n" "$domain"
    printf "${GR}║${RS}  🔄 Auto renew: cron 03:00 (nginx renew อัตโนมัติ)\n"
    printf "${GR}╠══════════════════════════════════════════════════════╣${RS}\n"
    printf "${GR}║${RS}  🖥️  X-UI Panel: ${CY}%s://%s:%s%s/${RS}\n" "$_xui_proto" "$domain" "$_xp2" "$_bp2"
    if [[ "$_xui_proto" == "http" ]]; then
      printf "${GR}║${RS}  ${OR}⚠ x-ui ยังไม่ได้ใช้ HTTPS — ยัด cert ด้วยตัวเอง${RS}\n"
      printf "${GR}║${RS}  ${OR}  x-ui panel → Panel Settings → SSL Certificate${RS}\n"
    fi
    printf "${GR}╚══════════════════════════════════════════════════════╝${RS}\n\n"
  fi
  read -rp "Enter ย้อนกลับ..."
}

menu_3() {
  clear
  printf "${R4}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R4}│${RS}  🌈 ${BLD}สร้าง VLESS User (IP Limit + Auto Ban)${RS}      ${R4}│${RS}\n"
  printf "${R4}└──────────────────────────────────────────────────┘${RS}\n\n"

  MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  if [[ -f "$DOMAIN_FILE" ]]; then
    AUTO_HOST=$(cat "$DOMAIN_FILE")
    printf "  ${GR}✔ โดเมน: ${WH}%s${RS}\n" "$AUTO_HOST"
  else
    AUTO_HOST="$MY_IP"
    printf "  ${YE}⚠ ไม่มีโดเมน — ใช้ IP: ${WH}%s${RS}\n" "$MY_IP"
  fi
  printf "\n"

  # ── รับ input ─────────────────────────────────────────────
  rgb_bar 5 "รอ input..."; printf "\n\n"

  read -rp "$(printf "  ${YE}👤 ชื่อ User: ${RS}")" UNAME
  [[ -z "$UNAME" ]] && { printf "  ${YE}ยกเลิก${RS}\n"; read -rp "  Enter..."; return; }

  read -rp "$(printf "  ${YE}📅 จำนวนวัน (default 30): ${RS}")" DAYS
  [[ -z "$DAYS" || ! "$DAYS" =~ ^[0-9]+$ ]] && DAYS=30

  read -rp "$(printf "  ${YE}📦 Data limit GB (0=ไม่จำกัด): ${RS}")" DATA_GB
  [[ -z "$DATA_GB" || ! "$DATA_GB" =~ ^[0-9]+$ ]] && DATA_GB=0

  read -rp "$(printf "  ${YE}🔒 IP limit (default 2): ${RS}")" IP_LIMIT
  [[ -z "$IP_LIMIT" || ! "$IP_LIMIT" =~ ^[0-9]+$ ]] && IP_LIMIT=2

  printf "\n  ${WH}🔌 เลือก Inbound (VMess WS):${RS}\n"
  printf "  ${R2}1.${RS} Port ${WH}8080${RS} — AIS  | SNI: ${YE}cj-ebb.speedtest.net${RS}\n"
  printf "  ${R3}2.${RS} Port ${WH}8880${RS} — TRUE | SNI: ${YE}true-internet.zoom.xyz.services${RS}\n"
  printf "  ${R4}3.${RS} ทั้งสอง port (สร้าง 2 user)\n"
  printf "  ${CY}4.${RS} กรอก port + SNI เอง\n"
  read -rp "$(printf "  ${YE}เลือก: ${RS}")" port_choice

  # สร้าง array of "port:sni" ที่จะสร้าง
  declare -a _PORT_SNI_LIST=()
  case $port_choice in
    1) _PORT_SNI_LIST=("8080:cj-ebb.speedtest.net") ;;
    2) _PORT_SNI_LIST=("8880:true-internet.zoom.xyz.services") ;;
    3) _PORT_SNI_LIST=("8080:cj-ebb.speedtest.net" "8880:true-internet.zoom.xyz.services") ;;
    4) read -rp "$(printf "  ${YE}Port: ${RS}")" _cp
       read -rp "$(printf "  ${YE}SNI: ${RS}")" _cs
       _PORT_SNI_LIST=("${_cp}:${_cs}") ;;
    *) _PORT_SNI_LIST=("8080:cj-ebb.speedtest.net") ;;
  esac

  EXP=$(date -d "+${DAYS} days" +"%Y-%m-%d")
  local EXP_MS=$(( $(date -d "$EXP" +%s) * 1000 ))
  local SEC="none"

  rgb_bar 20 "ตรวจสอบ 3x-ui API..."; printf "\n\n"

  # [FIX] force fresh login ทุกครั้งก่อนเรียก API — ป้องกัน stale cookie
  rm -f /etc/chaiya/xui-cookie.jar
  if ! xui_login 2>/dev/null; then
    printf "${RD}❌ login x-ui ไม่สำเร็จ — ตรวจสอบ port/user/pass ด้วย: cat /etc/chaiya/xui-*.conf${RS}\n"
    read -rp "  Enter ย้อนกลับ..."; return
  fi

  # ── ตรวจว่า inbound port มีอยู่แล้วหรือยัง ────────────────
  local _inbound_list
  _inbound_list=$(xui_api GET "/panel/api/inbounds/list" 2>/dev/null)
  # ถ้า inbound list ว่าง/ไม่ success ให้แจ้งเตือนแต่ไม่หยุด (อาจไม่มี inbound เลยก็ได้)
  if ! echo "$_inbound_list" | grep -q '"success":true'; then
    printf "  ${YE}⚠ ดึง inbound list ไม่ได้ — จะสร้าง inbound ใหม่ทั้งหมด${RS}\n"
    _inbound_list='{"success":true,"obj":[]}'
  fi

  local _created_count=0
  local _step=0
  local _total=${#_PORT_SNI_LIST[@]}
  declare -a _RESULTS=()

  for _ps in "${_PORT_SNI_LIST[@]}"; do
    (( _step++ )) || true
    local _vport; _vport=$(echo "$_ps" | cut -d: -f1)
    local _sni;   _sni=$(echo "$_ps"   | cut -d: -f2-)
    local _pct=$(( 25 + _step * 30 / _total ))
    local UUID; UUID=$(cat /proc/sys/kernel/random/uuid)

    rgb_bar "$_pct" "สร้าง VLESS client port ${_vport}..."; printf "\n\n"

    # ค้นหา inbound_id ที่ port ตรง (VMess สร้างใน menu_1)
    local _inbound_id
    _inbound_id=$(echo "$_inbound_list" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    if x['port'] == int('${_vport}'):
      print(x['id']); sys.exit()
except: pass
print('')
" 2>/dev/null)

    local API_RESULT=""
    if [[ -n "$_inbound_id" ]]; then
      # เพิ่ม client เข้า inbound เดิม — settings ต้องเป็น JSON string
      # totalGB รับค่าเป็น GB ตรงๆ ตาม 3x-ui model.go (Total traffic limit in GB)
      local _client_payload
      _client_payload=$(python3 -c "
import json, sys
client = {
  'id': sys.argv[1],
  'flow': '',
  'email': sys.argv[2],
  'limitIp': int(sys.argv[3]),
  'totalGB': int(sys.argv[4]) * (1024**3),
  'expiryTime': int(sys.argv[5]),
  'enable': True,
  'tgId': '',
  'subId': '',
  'comment': '',
  'reset': 0
}
payload = {
  'id': int(sys.argv[6]),
  'settings': json.dumps({'clients': [client]})
}
print(json.dumps(payload))
" "$UUID" "$UNAME" "$IP_LIMIT" "$DATA_GB" "$EXP_MS" "$_inbound_id")
      API_RESULT=$(xui_api POST "/panel/api/inbounds/addClient" "$_client_payload" 2>/dev/null)
      # [FIX] ถ้า fail → fresh login แล้ว retry
      if ! echo "$API_RESULT" | grep -q '"success":true'; then
        rm -f /etc/chaiya/xui-cookie.jar
        xui_login 2>/dev/null || true
        API_RESULT=$(xui_api POST "/panel/api/inbounds/addClient" "$_client_payload" 2>/dev/null)
      fi
    else
      # ไม่มี inbound — สร้างใหม่พร้อม client
      # totalGB รับค่าเป็น GB ตรงๆ ตาม 3x-ui model.go (Total traffic limit in GB)
      local _vless_payload
      _vless_payload=$(python3 -c "
import json, sys
settings = json.dumps({
  'clients': [{
    'id': sys.argv[1],
    'flow': '',
    'email': sys.argv[2],
    'limitIp': int(sys.argv[3]),
    'totalGB': int(sys.argv[4]) * (1024**3),
    'expiryTime': int(sys.argv[5]),
    'enable': True,
    'tgId': '',
    'subId': '',
    'comment': '',
    'reset': 0
  }],
  'decryption': 'none'
})
stream = json.dumps({
  'network': 'ws',
  'security': sys.argv[6],
  'wsSettings': {'path': '/vless', 'headers': {'Host': sys.argv[7]}}
})
sniff = json.dumps({'enabled': True, 'destOverride': ['http','tls']})
payload = {
  'remark': 'CHAIYA-' + sys.argv[2],
  'enable': True,
  'listen': '',
  'port': int(sys.argv[8]),
  'protocol': 'vless',
  'settings': settings,
  'streamSettings': stream,
  'sniffing': sniff
}
print(json.dumps(payload))
" "$UUID" "$UNAME" "$IP_LIMIT" "$DATA_GB" "$EXP_MS" "$SEC" "$_sni" "$_vport")
      API_RESULT=$(xui_api POST "/panel/api/inbounds/add" "$_vless_payload" 2>/dev/null)
      # [FIX] ถ้า fail → fresh login แล้ว retry
      if ! echo "$API_RESULT" | grep -q '"success":true'; then
        rm -f /etc/chaiya/xui-cookie.jar
        xui_login 2>/dev/null || true
        API_RESULT=$(xui_api POST "/panel/api/inbounds/add" "$_vless_payload" 2>/dev/null)
      fi
      ufw allow "${_vport}"/tcp 2>/dev/null || true
    fi

    # สร้าง link
    local VLESS_LINK
    # [FIX] security ต้องใช้ค่าจาก SEC ("none" หรือ "tls") ไม่ใช่ว่าง
    VLESS_LINK="vless://${UUID}@${AUTO_HOST}:${_vport}?path=%2Fvless&security=${SEC}&encryption=none&host=${_sni}&type=ws#CHAIYA-${UNAME}-${_vport}"

    # บันทึก DB
    echo "$UNAME $DAYS $EXP $DATA_GB $UUID $_vport $_sni $AUTO_HOST" >> "$DB"

    # ── บันทึก data limit ลง datalimit.conf สำหรับ API fallback ──
    if [[ "$DATA_GB" -gt 0 ]]; then
      local _dl_conf="/etc/chaiya/datalimit.conf"
      sed -i "/^${UNAME} /d" "$_dl_conf" 2>/dev/null || true
      echo "${UNAME} ${DATA_GB}" >> "$_dl_conf"
    fi

    # ── บันทึก IP limit ลง iplimit.conf ──
    local _ipl_conf="/etc/chaiya/iplimit.conf"
    sed -i "/^${UNAME}=/d" "$_ipl_conf" 2>/dev/null || true
    echo "${UNAME}=${IP_LIMIT}:720" >> "$_ipl_conf"

    # เก็บผลสำหรับแสดง
    _RESULTS+=("$_vport|$_sni|$UUID|$VLESS_LINK|$API_RESULT")
    (( _created_count++ )) || true
  done

  # ── สร้างไฟล์ HTML (port แรกในรายการ) ───────────────────────
  if [[ ${#_RESULTS[@]} -gt 0 ]]; then
    local _first="${_RESULTS[0]}"
    local _fp; _fp=$(echo "$_first" | cut -d'|' -f1)
    local _fs; _fs=$(echo "$_first" | cut -d'|' -f2)
    local _fu; _fu=$(echo "$_first" | cut -d'|' -f3)
    local _fl; _fl=$(echo "$_first" | cut -d'|' -f4)
    gen_vless_html "$UNAME" "$_fl" "$_fu" "$AUTO_HOST" "$_fp" "$_fs" "$EXP" "$DATA_GB" "$UNAME"
  fi

  rgb_bar 100 "สร้าง User สำเร็จ! ✔"; printf "\n\n"

  # ── แสดงผลสรุป ───────────────────────────────────────────────
  printf "${R4}┌──────────────────────────────────────────────────┐${RS}\n"
  printf "${R4}│${RS}  ${GR}✅ สร้าง VLESS User สำเร็จ!${RS}                    ${R4}│${RS}\n"
  printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"
  printf "${R4}│${RS}  ${GR}User    :${RS} ${WH}%-38s${R4}│${RS}\n" "$UNAME"
  printf "${R4}│${RS}  ${GR}Host    :${RS} ${WH}%-38s${R4}│${RS}\n" "$AUTO_HOST"
  printf "${R4}│${RS}  ${GR}หมดอายุ :${RS} ${WH}%-38s${R4}│${RS}\n" "$EXP"
  printf "${R4}│${RS}  ${GR}Data    :${RS} ${WH}%-38s${R4}│${RS}\n" "${DATA_GB} GB (0=ไม่จำกัด)"
  printf "${R4}│${RS}  ${YE}IP Limit:${RS} ${WH}2 IP / แบน ${RD}12 ชั่วโมง${RS}              ${R4}│${RS}\n"
  printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"

  for _r in "${_RESULTS[@]}"; do
    local _p; _p=$(echo "$_r" | cut -d'|' -f1)
    local _s; _s=$(echo "$_r" | cut -d'|' -f2)
    local _u; _u=$(echo "$_r" | cut -d'|' -f3)
    local _ar; _ar=$(echo "$_r" | cut -d'|' -f5)
    local _st
    if echo "$_ar" | grep -q '"success":true'; then
      _st="${CY}✔ เพิ่ม client สำเร็จ${RS}"
    else
      local _err; _err=$(echo "$_ar" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('msg','no response'))" 2>/dev/null || echo "ไม่ได้รับ response")
      _st="${RD}✗ ${_err}${RS}"
    fi
    printf "${R4}│${RS}  ${CY}Port %-5s${RS} SNI: %s\n" "$_p" "$_s"
    printf "${R4}│${RS}  UUID: ${CY}%s${RS}\n" "$_u"
    printf "${R4}│${RS}  Status: %b\n" "$_st"
    printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"
  done

  # ลิงค์ x-ui panel
  local _xp; _xp=$(xui_port)
  local _bp; _bp=$(cat /etc/chaiya/xui-basepath.conf 2>/dev/null | sed 's|/$||')
  local _proto; _proto=$(xui_proto)
  local _panel_host; _panel_host="$MY_IP"
  if [[ -f "$DOMAIN_FILE" ]]; then
    local _ph; _ph=$(cat "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]')
    getent hosts "$_ph" &>/dev/null && _panel_host="$_ph" || true
  fi

  printf "${R4}│${RS}  ${YE}🔗 X-UI Panel:${RS}\n"
  printf "${R4}│${RS}  ${WH}%s://%s:%s%s/${RS}\n" "$_proto" "$_panel_host" "$_xp" "$_bp"
  printf "${R4}├──────────────────────────────────────────────────┤${RS}\n"
  local _cfg_host; _cfg_host="$MY_IP"
  if [[ -f "$DOMAIN_FILE" ]]; then
    local _ch; _ch=$(cat "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]')
    getent hosts "$_ch" &>/dev/null && _cfg_host="$_ch" || true
  fi
  printf "${R4}│${RS}  ${CY}📥 Config HTML:${RS}\n"
  printf "${R4}│${RS}  ${WH}http://%s:81/config/%s.html${RS}\n" "$_cfg_host" "$UNAME"
  printf "${R4}└──────────────────────────────────────────────────┘${RS}\n\n"

  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 4 — ลบบัญชีหมดอายุ
# ══════════════════════════════════════════════════════════════
menu_4() {
  clear
  printf "${R5}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R5}║${RS}  🗑️  ${R2}ลบบัญชีหมดอายุ${RS}  ${R5}[เมนู 4]${RS}                       ${R5}║${RS}\n"
  printf "${R5}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  NOW=$(date +%s)
  COUNT=0
  declare -a EXPIRED_LIST=()

  # ── สแกนหาบัญชีหมดอายุก่อน ──────────────────────────────
  if [[ -f "$DB" && -s "$DB" ]]; then
    while IFS=' ' read -r user days exp rest; do
      [[ -z "$user" ]] && continue
      EXP_TS=$(date -d "$exp" +%s 2>/dev/null || echo 0)
      if (( EXP_TS < NOW )); then
        DIFF=$(( (NOW - EXP_TS) / 86400 ))
        EXPIRED_LIST+=("$user|$exp|${DIFF} วันที่แล้ว")
      fi
    done < "$DB"
  fi

  if [[ ${#EXPIRED_LIST[@]} -eq 0 ]]; then
    printf "${GR}╔══════════════════════════════════════════════╗${RS}\n"
    printf "${GR}║${RS}  ✅  ไม่มีบัญชีหมดอายุในระบบ                 ${GR}║${RS}\n"
    printf "${GR}╚══════════════════════════════════════════════╝${RS}\n\n"
    read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"; return
  fi

  # ── แสดงตารางบัญชีหมดอายุ ────────────────────────────────
  printf "${RD}┌──────────────────────────────────────────────────────┐${RS}\n"
  printf "${RD}│${RS}  ${WH}%-3s  %-18s  %-12s  %-14s${RD}│${RS}\n" "ลำดับ" "Username" "วันหมดอายุ" "หมดมาแล้ว"
  printf "${RD}├──────────────────────────────────────────────────────┤${RS}\n"
  local i=0
  for entry in "${EXPIRED_LIST[@]}"; do
    (( i++ )) || true
    IFS='|' read -r eu eexp ediff <<< "$entry"
    printf "${RD}│${RS}  ${YE}%-3d${RS}  ${WH}%-18s${RS}  ${RD}%-12s${RS}  ${OR}%-14s${RS}${RD}│${RS}\n" "$i" "$eu" "$eexp" "$ediff"
  done
  printf "${RD}├──────────────────────────────────────────────────────┤${RS}\n"
  printf "${RD}│${RS}  ${YE}พบบัญชีหมดอายุ: %-3d รายการ${RS}                        ${RD}│${RS}\n" "${#EXPIRED_LIST[@]}"
  printf "${RD}└──────────────────────────────────────────────────────┘${RS}\n\n"

  printf "${YE}⚠️  ยืนยันลบบัญชีหมดอายุทั้งหมด? (y/N): ${RS}"
  read -r confirm
  [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { printf "${YE}↩ ยกเลิก${RS}\n\n"; read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"; return; }

  printf "\n${R2}┌──────────────────────────────────────────────────────┐${RS}\n"
  printf "${R2}│${RS}  ⚙️  ${WH}กำลังลบบัญชี...${RS}                                ${R2}│${RS}\n"
  printf "${R2}├──────────────────────────────────────────────────────┤${RS}\n"

  for entry in "${EXPIRED_LIST[@]}"; do
    IFS='|' read -r eu eexp ediff <<< "$entry"
    sed -i "/^${eu} /d" "$DB" 2>/dev/null || true
    userdel -f "$eu" 2>/dev/null || true
    xui_api POST "/panel/api/client/delByEmail/${eu}" "" > /dev/null 2>&1 || true
    rm -f "/var/www/chaiya/config/${eu}.html" 2>/dev/null || true
    printf "${R2}│${RS}  ${RD}🗑  %-20s${RS} → ${GR}ลบแล้ว${RS}                   ${R2}│${RS}\n" "$eu"
    (( COUNT++ )) || true
  done

  printf "${R2}├──────────────────────────────────────────────────────┤${RS}\n"
  printf "${R2}│${RS}  ${GR}✅ ลบสำเร็จทั้งหมด: ${WH}%-3d${GR} รายการ${RS}                   ${R2}│${RS}\n" "$COUNT"
  printf "${R2}└──────────────────────────────────────────────────────┘${RS}\n\n"
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 5 — ดูบัญชี (ดึงจาก 3x-ui API)
# ══════════════════════════════════════════════════════════════
menu_5() {
  clear
  printf "${R6}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R6}║${RS}  📋 ${PU}ดูบัญชีทั้งหมด${RS}  ${R6}[เมนู 5]${RS}                        ${R6}║${RS}\n"
  printf "${R6}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  printf "${YE}⏳ กำลังดึงข้อมูลจาก 3x-ui API...${RS}\n\n"
  local api_data
  api_data=$(xui_api GET "/panel/api/inbounds/list" 2>/dev/null)

  if echo "$api_data" | grep -q '"success":true'; then
    # ── ดึงข้อมูลและแสดงตาราง ──────────────────────────────
    local total active_cnt off_cnt
    total=$(echo "$api_data" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  obj=d.get('obj',[])
  total=0
  for x in obj:
    try:
      s=json.loads(x.get('settings','{}'))
      total+=len(s.get('clients',[]))
    except: pass
  print(total)
except: print(0)
" 2>/dev/null)

    printf "${CY}┌──────┬────────────────────┬───────┬──────────┬──────────────┬──────────┬────────────┐${RS}\n"
    printf "${CY}│${RS} ${WH}%-4s${RS} ${CY}│${RS} ${WH}%-18s${RS} ${CY}│${RS} ${WH}%-5s${RS} ${CY}│${RS} ${WH}%-8s${RS} ${CY}│${RS} ${WH}%-12s${RS} ${CY}│${RS} ${WH}%-8s${RS} ${CY}│${RS} ${WH}%-10s${RS} ${CY}│${RS}\n" \
      "No." "Email/User" "Port" "Protocol" "Data Limit" "หมดอายุ" "สถานะ"
    printf "${CY}├──────┼────────────────────┼───────┼──────────┼──────────────┼──────────┼────────────┤${RS}\n"

    echo "$api_data" | python3 -c "
import sys, json
from datetime import datetime, timezone

try:
  d = json.load(sys.stdin)
  now_ms = int(datetime.now().timestamp() * 1000)
  idx = 0
  for x in d.get('obj', []):
    port    = x.get('port', '-')
    proto   = x.get('protocol', '-')[:8]
    enable  = x.get('enable', True)
    try:
      s = json.loads(x.get('settings', '{}'))
      clients = s.get('clients', [])
    except:
      clients = []
    for c in clients:
      idx += 1
      email    = c.get('email', c.get('id', '-'))[:18]
      # totalGB เก็บเป็น GB โดยตรง
      total_gb = float(c.get('totalGB', 0) or 0)
      exp_ms   = c.get('expiryTime', 0)
      active   = c.get('enable', True) and enable

      if total_gb == 0:
        data_str = 'Unlimited'
      else:
        data_str = f'{total_gb:.1f} GB'

      if exp_ms == 0:
        exp_str = 'ไม่จำกัด'
        status  = 'ACTIVE' if active else 'OFF'
        sta_col = $'\033[1;38;2;0;255;80m' if active else $'\033[1;38;2;255;0;80m'
      else:
        exp_dt  = datetime.fromtimestamp(exp_ms/1000)
        exp_str = exp_dt.strftime('%Y-%m-%d')
        if exp_ms < now_ms:
          status  = 'EXPIRED'
          sta_col = $'\033[1;38;2;255;0;80m'
        elif not active:
          status  = 'OFF'
          sta_col = $'\033[1;38;2;255;140;0m'
        else:
          status  = 'ACTIVE'
          sta_col = $'\033[1;38;2;0;255;80m'

      CY  = $'\033[1;38;2;0;255;220m'
      WH  = $'\033[1;38;2;255;255;255m'
      YE  = $'\033[1;38;2;255;230;0m'
      OR  = $'\033[1;38;2;255;140;0m'
      RS  = $'\033[0m'
      print(f'{CY}│{RS} {YE}{idx:<4}{RS} {CY}│{RS} {WH}{email:<18}{RS} {CY}│{RS} {YE}{port:<5}{RS} {CY}│{RS} {WH}{proto:<8}{RS} {CY}│{RS} {OR}{data_str:<12}{RS} {CY}│{RS} {WH}{exp_str:<8}{RS} {CY}│{RS} {sta_col}{status:<10}{RS} {CY}│{RS}')
except Exception as e:
  print(f'  Error: {e}')
" 2>/dev/null

    printf "${CY}├──────┴────────────────────┴───────┴──────────┴──────────────┴──────────┴────────────┤${RS}\n"
    printf "${CY}│${RS}  ${GR}👥 รวม User ทั้งหมด: ${WH}%-5s${RS}  ${YE}(ดึงข้อมูลจริงจาก 3x-ui API)${RS}                        ${CY}│${RS}\n" "$total"
    printf "${CY}└───────────────────────────────────────────────────────────────────────────────────────┘${RS}\n\n"

  else
    # ── fallback: ใช้ local DB ───────────────────────────────
    printf "${OR}⚠️  ไม่สามารถเชื่อมต่อ API — ใช้ข้อมูลจาก Local DB${RS}\n\n"

    if [[ ! -f "$DB" || ! -s "$DB" ]]; then
      printf "${RD}┌──────────────────────────────────────┐${RS}\n"
      printf "${RD}│${RS}  ❌ ไม่มีข้อมูลบัญชีในระบบ             ${RD}│${RS}\n"
      printf "${RD}└──────────────────────────────────────┘${RS}\n\n"
    else
      NOW=$(date +%s)
      printf "${OR}┌──────┬──────────────────────┬────────────┬──────────┬────────────┐${RS}\n"
      printf "${OR}│${RS} ${WH}%-4s${RS} ${OR}│${RS} ${WH}%-20s${RS} ${OR}│${RS} ${WH}%-10s${RS} ${OR}│${RS} ${WH}%-8s${RS} ${OR}│${RS} ${WH}%-10s${RS} ${OR}│${RS}\n" \
        "No." "Username" "หมดอายุ" "Data GB" "สถานะ"
      printf "${OR}├──────┼──────────────────────┼────────────┼──────────┼────────────┤${RS}\n"
      local n=0
      while IFS=' ' read -r user days exp quota uuid port sni rest; do
        [[ -z "$user" ]] && continue
        (( n++ )) || true
        EXP_TS=$(date -d "$exp" +%s 2>/dev/null || echo 0)
        if (( EXP_TS < NOW )); then
          SC="$RD"; ST="EXPIRED"
        else
          SC="$GR"; ST="ACTIVE"
        fi
        DQ="${quota:-∞}"
        [[ "$quota" == "0" ]] && DQ="Unlimited"
        printf "${OR}│${RS} ${YE}%-4d${RS} ${OR}│${RS} ${WH}%-20s${RS} ${OR}│${RS} ${SC}%-10s${RS} ${OR}│${RS} ${OR}%-8s${RS} ${OR}│${RS} ${SC}%-10s${RS} ${OR}│${RS}\n" \
          "$n" "$user" "$exp" "$DQ" "$ST"
      done < "$DB"
      printf "${OR}├──────┴──────────────────────┴────────────┴──────────┴────────────┤${RS}\n"
      printf "${OR}│${RS}  ${GR}รวม: ${WH}%d${GR} บัญชี${RS}  ${YE}(Local DB)${RS}                                    ${OR}│${RS}\n" "$n"
      printf "${OR}└─────────────────────────────────────────────────────────────────┘${RS}\n\n"
    fi
  fi
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 6 — User Online Realtime
# ══════════════════════════════════════════════════════════════
menu_6() {
  trap 'printf "\n${YE}↩ กลับเมนูหลัก...${RS}\n"; sleep 1; trap - INT; return' INT
  while true; do
    clear
    local _ts; _ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf "${PU}╔══════════════════════════════════════════════════════╗${RS}\n"
    printf "${PU}║${RS}  🟢 ${GR}User Online Realtime${RS}  ${YE}%s${RS}   ${PU}║${RS}\n" "$_ts"
    printf "${PU}║${RS}  ${OR}Ctrl+C เพื่อออก${RS}                                      ${PU}║${RS}\n"
    printf "${PU}╚══════════════════════════════════════════════════════╝${RS}\n\n"

    # ── SSH Online (port 22) ───────────────────────────────
    printf "${CY}┌─[ 🔐 SSH Online ]──────────────────────────────────────┐${RS}\n"
    printf "${CY}│${RS} ${WH}%-4s  %-22s  %-20s  %-8s${RS} ${CY}│${RS}\n" "No." "User" "IP" "Port"
    printf "${CY}├────────────────────────────────────────────────────────┤${RS}\n"
    local ssh_count=0
    while IFS= read -r addr; do
      [[ -z "$addr" ]] && continue
      local ip pt user
      ip=$(echo "$addr" | rev | cut -d: -f2- | rev)
      pt=$(echo "$addr" | rev | cut -d: -f1 | rev)
      user=$(who 2>/dev/null | awk -v ip="$ip" '$0~ip{print $1}' | head -1)
      (( ssh_count++ )) || true
      printf "${CY}│${RS} ${YE}%-4d${RS}  ${GR}%-22s${RS}  ${WH}%-20s${RS}  ${OR}%-8s${RS} ${CY}│${RS}\n" \
        "$ssh_count" "${user:--}" "$ip" "$pt"
    done < <(ss -tnpc state established 2>/dev/null | grep ':22 ' | awk '{print $5}' | sort -u)
    if (( ssh_count == 0 )); then
      printf "${CY}│${RS}  ${OR}ไม่มี SSH connection ขณะนี้${RS}                          ${CY}│${RS}\n"
    fi
    printf "${CY}│${RS}  ${GR}SSH Online: ${WH}${ssh_count}${GR} connection(s)${RS}                         ${CY}│${RS}\n"
    printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

    # ── VLESS Online (ดึงจาก x-ui API) ───────────────────
    printf "${R4}┌─[ 🌐 VLESS Online (3x-ui) ]────────────────────────────┐${RS}\n"
    printf "${R4}│${RS} ${WH}%-4s  %-30s${RS}                        ${R4}│${RS}\n" "No." "Email / User"
    printf "${R4}├────────────────────────────────────────────────────────┤${RS}\n"
    local xui_online vless_count=0
    xui_online=$(xui_api GET "/panel/api/inbounds/onlines" 2>/dev/null)
    if echo "$xui_online" | grep -q '"success":true'; then
      while IFS= read -r uline; do
        [[ -z "$uline" ]] && continue
        (( vless_count++ )) || true
        printf "${R4}│${RS} ${YE}%-4d${RS}  ${GR}%-30s${RS}                        ${R4}│${RS}\n" "$vless_count" "$uline"
      done < <(echo "$xui_online" | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  for x in d.get('obj',[]):
    print(str(x))
except: pass
" 2>/dev/null)
    fi
    if (( vless_count == 0 )); then
      printf "${R4}│${RS}  ${OR}ไม่มี VLESS user online ขณะนี้${RS}                      ${R4}│${RS}\n"
    fi
    printf "${R4}│${RS}  ${GR}VLESS Online: ${WH}${vless_count}${GR} user(s)${RS}                             ${R4}│${RS}\n"
    printf "${R4}└────────────────────────────────────────────────────────┘${RS}\n\n"

    # ── System Snapshot ───────────────────────────────────
    local cpu ram_used ram_total load_avg
    cpu=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%d", $2+$4}' 2>/dev/null || echo "0")
    ram_used=$(free -m | awk '/Mem:/{printf "%.0f", $3}')
    ram_total=$(free -m | awk '/Mem:/{printf "%.0f", $2}')
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)

    printf "${R5}┌─[ 💻 System Snapshot ]─────────────────────────────────┐${RS}\n"
    printf "${R5}│${RS}  🔥 CPU: ${YE}%s%%${RS}   🧠 RAM: ${YE}%s/%s MB${RS}   ⚡ Load: ${YE}%s${RS}\n" \
      "$cpu" "$ram_used" "$ram_total" "$load_avg"
    printf "${R5}│${RS}  🔄 รีเฟรชทุก 3 วินาที  │  ${OR}Ctrl+C ออก${RS}                ${R5}│${RS}\n"
    printf "${R5}└────────────────────────────────────────────────────────┘${RS}\n"

    sleep 3
  done
  trap - INT
}

# ══════════════════════════════════════════════════════════════
# เมนู 7 — รีสตาร์ท 3x-ui
# ══════════════════════════════════════════════════════════════
menu_7() {
  clear
  printf "${CY}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${CY}║${RS}  🔄 ${WH}รีสตาร์ท 3x-ui${RS}  ${CY}[เมนู 7]${RS}                        ${CY}║${RS}\n"
  printf "${CY}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── สถานะก่อน restart ────────────────────────────────────
  local before_status
  before_status=$(systemctl is-active x-ui 2>/dev/null || echo "unknown")
  printf "${YE}┌─[ ก่อน Restart ]───────────────────────────────────────┐${RS}\n"
  printf "${YE}│${RS}  สถานะ: "
  [[ "$before_status" == "active" ]] && printf "${GR}%-10s${RS}" "RUNNING" || printf "${RD}%-10s${RS}" "$before_status"
  printf "                                          ${YE}│${RS}\n"
  printf "${YE}└────────────────────────────────────────────────────────┘${RS}\n\n"

  printf "${OR}⚙️  กำลัง restart x-ui...${RS}\n\n"
  systemctl restart x-ui 2>/dev/null
  sleep 2

  # ── สถานะหลัง restart ────────────────────────────────────
  local after_status pid mem uptime_svc
  after_status=$(systemctl is-active x-ui 2>/dev/null || echo "failed")
  pid=$(systemctl show x-ui --property=MainPID --value 2>/dev/null | tr -d '\n')
  mem=$(systemctl show x-ui --property=MemoryCurrent --value 2>/dev/null | awk '{printf "%.1f MB", $1/1048576}' 2>/dev/null || echo "N/A")
  uptime_svc=$(systemctl show x-ui --property=ActiveEnterTimestamp --value 2>/dev/null || echo "N/A")

  printf "${CY}┌─[ ✅ หลัง Restart ]────────────────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  %-14s : " "สถานะ"
  if [[ "$after_status" == "active" ]]; then
    printf "${GR}%-20s${RS}" "🟢 RUNNING"
  else
    printf "${RD}%-20s${RS}" "🔴 $after_status"
  fi
  printf "                  ${CY}│${RS}\n"
  printf "${CY}│${RS}  %-14s : ${WH}%-30s${RS}         ${CY}│${RS}\n" "PID" "${pid:-N/A}"
  printf "${CY}│${RS}  %-14s : ${WH}%-30s${RS}         ${CY}│${RS}\n" "Memory" "$mem"
  printf "${CY}│${RS}  %-14s : ${YE}%-40s${RS} ${CY}│${RS}\n" "Started at" "${uptime_svc:-N/A}"
  printf "${CY}├────────────────────────────────────────────────────────┤${RS}\n"
  printf "${CY}│${RS}  ${WH}Service Log (5 บรรทัดล่าสุด):${RS}                          ${CY}│${RS}\n"
  printf "${CY}│${RS}\n"
  journalctl -u x-ui --no-pager -n 5 2>/dev/null | while IFS= read -r line; do
    printf "${CY}│${RS}  ${OR}%.70s${RS}\n" "$line"
  done
  printf "${CY}│${RS}\n"
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  if [[ "$after_status" == "active" ]]; then
    printf "${GR}✅ 3x-ui รีสตาร์ทสำเร็จ!${RS}\n\n"
  else
    printf "${RD}❌ 3x-ui ไม่สามารถ restart ได้ — ตรวจสอบ log ด้านบน${RS}\n\n"
  fi
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 8 — จัดการ Process CPU สูง
# ══════════════════════════════════════════════════════════════
menu_8() {
  clear
  printf "${GR}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${GR}║${RS}  ⚡ ${WH}จัดการ Process CPU สูง${RS}  ${GR}[เมนู 8]${RS}                ${GR}║${RS}\n"
  printf "${GR}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── System Overview ───────────────────────────────────────
  local cpu_total ram_used ram_total load_avg uptime_str
  cpu_total=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f", $2+$4}' 2>/dev/null || echo "0")
  ram_used=$(free -m | awk '/Mem:/{printf "%.0f", $3}')
  ram_total=$(free -m | awk '/Mem:/{printf "%.0f", $2}')
  load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)
  uptime_str=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | tr -d ',')

  printf "${YE}┌─[ 💻 System Overview ]─────────────────────────────────┐${RS}\n"
  printf "${YE}│${RS}  🔥 CPU รวม  : ${OR}%-8s%%${RS}   ⚡ Load avg: ${WH}%s${RS}\n" "$cpu_total" "$load_avg"
  printf "${YE}│${RS}  🧠 RAM ใช้  : ${OR}%-8s MB${RS}  💾 ทั้งหมด : ${WH}%s MB${RS}\n" "$ram_used" "$ram_total"
  printf "${YE}│${RS}  ⏱️  Uptime   : ${WH}%s${RS}\n" "$uptime_str"
  printf "${YE}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── Top 15 Process ────────────────────────────────────────
  printf "${R2}┌──────┬────────┬────────┬────────┬──────────────────────────┐${RS}\n"
  printf "${R2}│${RS} ${WH}%-4s${RS} ${R2}│${RS} ${WH}%-6s${RS} ${R2}│${RS} ${WH}%-6s${RS} ${R2}│${RS} ${WH}%-6s${RS} ${R2}│${RS} ${WH}%-24s${RS} ${R2}│${RS}\n" \
    "PID" "CPU%" "MEM%" "MEM_MB" "Command"
  printf "${R2}├──────┼────────┼────────┼────────┼──────────────────────────┤${RS}\n"

  local rank=0
  while IFS= read -r line; do
    (( rank++ )) || true
    local pid cpu mem rss cmd
    pid=$(echo "$line" | awk '{print $2}')
    cpu=$(echo "$line" | awk '{print $3}')
    mem=$(echo "$line" | awk '{print $4}')
    rss=$(echo "$line" | awk '{printf "%.0f", $6/1024}')
    cmd=$(echo "$line" | awk '{print $11}' | sed 's|.*/||')

    # สีตาม CPU%
    local cpu_int; cpu_int=$(echo "$cpu" | cut -d. -f1)
    local CC
    (( cpu_int >= 80 )) && CC="$RD" || { (( cpu_int >= 40 )) && CC="$OR" || CC="$GR"; }

    printf "${R2}│${RS} ${YE}%-4s${RS} ${R2}│${RS} ${CC}%-6s${RS} ${R2}│${RS} ${WH}%-6s${RS} ${R2}│${RS} ${WH}%-6s${RS} ${R2}│${RS} ${WH}%-24s${RS} ${R2}│${RS}\n" \
      "$pid" "$cpu" "$mem" "${rss}MB" "${cmd:0:24}"
  done < <(ps aux --sort=-%cpu | tail -n +2 | head -15)

  printf "${R2}├──────┴────────┴────────┴────────┴──────────────────────────┤${RS}\n"
  printf "${R2}│${RS}  ${OR}🔴 ≥80%%${RS}  ${YE}🟡 40-79%%${RS}  ${GR}🟢 <40%%${RS}                              ${R2}│${RS}\n"
  printf "${R2}└──────────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── Kill process ─────────────────────────────────────────
  printf "${WH}กรอก PID ที่จะ kill (Enter = ข้าม): ${RS}"
  read -rp "" PID
  if [[ -n "$PID" && "$PID" =~ ^[0-9]+$ ]]; then
    local proc_name
    proc_name=$(ps -p "$PID" -o comm= 2>/dev/null || echo "unknown")
    printf "\n${YE}⚠️  ยืนยัน kill PID ${WH}%s${YE} (%s)? (y/N): ${RS}" "$PID" "$proc_name"
    read -r cf
    if [[ "$cf" == "y" || "$cf" == "Y" ]]; then
      kill -9 "$PID" 2>/dev/null && \
        printf "${GR}✅ kill PID %s (%s) สำเร็จ${RS}\n\n" "$PID" "$proc_name" || \
        printf "${RD}❌ ไม่สามารถ kill PID %s${RS}\n\n" "$PID"
    else
      printf "${YE}↩ ยกเลิก${RS}\n\n"
    fi
  fi
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 9 — เช็คความเร็ว VPS
# ══════════════════════════════════════════════════════════════
menu_9() {
  clear
  printf "${YE}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${YE}║${RS}  🚀 ${WH}เช็คความเร็ว VPS${RS}  ${YE}[เมนู 9]${RS}                       ${YE}║${RS}\n"
  printf "${YE}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── ข้อมูล Server ─────────────────────────────────────────
  local my_ip cpu_cores ram_gb disk_free os_ver
  my_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  cpu_cores=$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo 2>/dev/null || echo "N/A")
  ram_gb=$(free -m | awk '/Mem:/{printf "%.1f GB", $2/1024}')
  disk_free=$(df -h / | awk 'NR==2{print $4" free / "$2" total"}')
  os_ver=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -r)

  printf "${CY}┌─[ 🖥️  Server Info ]────────────────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  🌍 IP       : ${WH}%-38s${RS} ${CY}│${RS}\n" "$my_ip"
  printf "${CY}│${RS}  💻 CPU Core : ${WH}%-38s${RS} ${CY}│${RS}\n" "$cpu_cores cores"
  printf "${CY}│${RS}  🧠 RAM      : ${WH}%-38s${RS} ${CY}│${RS}\n" "$ram_gb"
  printf "${CY}│${RS}  💾 Disk     : ${WH}%-38s${RS} ${CY}│${RS}\n" "$disk_free"
  printf "${CY}│${RS}  🐧 OS       : ${WH}%-38s${RS} ${CY}│${RS}\n" "$os_ver"
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── Speed Test ───────────────────────────────────────────
  printf "${R4}┌─[ 🌐 Network Speed Test ]──────────────────────────────┐${RS}\n"
  printf "${R4}│${RS}  ${YE}⏳ กำลังทดสอบความเร็ว — กรุณารอ...${RS}                  ${R4}│${RS}\n"
  printf "${R4}└────────────────────────────────────────────────────────┘${RS}\n\n"

  if command -v speedtest-cli &>/dev/null; then
    local st_out
    st_out=$(speedtest-cli --simple 2>/dev/null)
    local ping_val dl_val ul_val
    ping_val=$(echo "$st_out" | grep -i ping  | awk '{print $2" "$3}')
    dl_val=$(echo "$st_out"  | grep -i download | awk '{print $2" "$3}')
    ul_val=$(echo "$st_out"  | grep -i upload   | awk '{print $2" "$3}')

    printf "${GR}┌─[ 📊 ผลทดสอบความเร็ว (speedtest-cli) ]───────────────┐${RS}\n"
    printf "${GR}│${RS}  📡 Ping     : ${WH}%-38s${RS} ${GR}│${RS}\n" "${ping_val:-N/A}"
    printf "${GR}│${RS}  ⬇️  Download : ${CY}%-38s${RS} ${GR}│${RS}\n" "${dl_val:-N/A}"
    printf "${GR}│${RS}  ⬆️  Upload   : ${R2}%-38s${RS} ${GR}│${RS}\n" "${ul_val:-N/A}"
    printf "${GR}└────────────────────────────────────────────────────────┘${RS}\n\n"
  else
    printf "${YE}⏳ ติดตั้ง speedtest-cli...${RS}\n"
    pip3 install speedtest-cli --break-system-packages -q 2>/dev/null || \
      apt-get install -y speedtest-cli -qq 2>/dev/null || true

    if command -v speedtest-cli &>/dev/null; then
      local st_out
      st_out=$(speedtest-cli --simple 2>/dev/null)
      local ping_val dl_val ul_val
      ping_val=$(echo "$st_out" | grep -i ping    | awk '{print $2" "$3}')
      dl_val=$(echo "$st_out"   | grep -i download | awk '{print $2" "$3}')
      ul_val=$(echo "$st_out"   | grep -i upload   | awk '{print $2" "$3}')

      printf "${GR}┌─[ 📊 ผลทดสอบความเร็ว ]────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  📡 Ping     : ${WH}%-38s${RS} ${GR}│${RS}\n" "${ping_val:-N/A}"
      printf "${GR}│${RS}  ⬇️  Download : ${CY}%-38s${RS} ${GR}│${RS}\n" "${dl_val:-N/A}"
      printf "${GR}│${RS}  ⬆️  Upload   : ${R2}%-38s${RS} ${GR}│${RS}\n" "${ul_val:-N/A}"
      printf "${GR}└────────────────────────────────────────────────────────┘${RS}\n\n"
    else
      # fallback curl test
      printf "${OR}┌─[ 📊 ผลทดสอบ (curl fallback) ]────────────────────────┐${RS}\n"
      printf "${OR}│${RS}  ${YE}ทดสอบ Download จาก speedtest server...${RS}              ${OR}│${RS}\n"
      local dl_speed dl_mbps
      dl_speed=$(curl -o /dev/null -s -w "%{speed_download}" \
        "http://speedtest.ftp.otenet.gr/files/test10Mb.db" 2>/dev/null || echo "0")
      dl_mbps=$(echo "$dl_speed" | awk '{printf "%.2f Mbps", $1*8/1048576}')
      printf "${OR}│${RS}  ⬇️  Download : ${CY}%-38s${RS} ${OR}│${RS}\n" "$dl_mbps"
      printf "${OR}│${RS}  ${YE}(speedtest-cli ไม่สามารถติดตั้งได้)${RS}                ${OR}│${RS}\n"
      printf "${OR}└────────────────────────────────────────────────────────┘${RS}\n\n"
    fi
  fi

  # ── Ping latency ─────────────────────────────────────────
  printf "${R5}┌─[ 📶 Ping Latency ]────────────────────────────────────┐${RS}\n"
  for host in "8.8.8.8 Google DNS" "1.1.1.1 Cloudflare" "cj-ebb.speedtest.net AIS-SNI"; do
    local h label result
    h=$(echo "$host" | awk '{print $1}')
    label=$(echo "$host" | awk '{print $2}')
    result=$(ping -c 2 -W 2 "$h" 2>/dev/null | tail -1 | awk -F'/' '{print $5" ms"}' || echo "timeout")
    printf "${R5}│${RS}  📍 %-22s : ${WH}%-20s${RS}      ${R5}│${RS}\n" "$label ($h)" "$result"
  done
  printf "${R5}└────────────────────────────────────────────────────────┘${RS}\n\n"

  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 10 — จัดการ Port
# ══════════════════════════════════════════════════════════════
menu_10() {
  clear
  printf "${R2}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R2}║${RS}  🔌 ${WH}สถานะ Port${RS}  ${R2}[เมนู 10]${RS}                           ${R2}║${RS}\n"
  printf "${R2}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── Port ที่กำหนดตายตัว ───────────────────────────────────
  printf "${YE}┌─[ 🔒 Port ที่ล็อคไว้ (ห้ามแก้ไข) ]───────────────────┐${RS}\n"
  printf "${YE}│${RS}  ${WH}%-6s  %-30s${RS}              ${YE}│${RS}\n" "Port" "หน้าที่"
  printf "${YE}├────────────────────────────────────────────────────────┤${RS}\n"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "22"   "OpenSSH (Admin)"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "80"   "WS-Stunnel HTTP-CONNECT Tunnel"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "81"   "Dashboard Web UI"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "109"  "Dropbear SSH Port 2"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "143"  "Dropbear SSH Port 1"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "443"  "HTTPS / SSL"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "2053" "xui Alt Port"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "2082" "xui Alt Port"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "8080" "xui VMess Inbound"
  printf "${YE}│${RS}  ${GR}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "8880" "xui VLESS Inbound"
  printf "${YE}├────────────────────────────────────────────────────────┤${RS}\n"
  printf "${YE}│${RS}  ${RD}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "6789" "🔒 Internal Only (chaiya-sshws-api)"
  printf "${YE}│${RS}  ${RD}%-6s${RS}  ${WH}%-40s${RS} ${YE}│${RS}\n" "7300" "🔒 Internal Only (badvpn-udpgw)"
  printf "${YE}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── สถานะ Listening จริง ─────────────────────────────────
  printf "${CY}┌─[ 📡 Port ที่ Listening อยู่จริง ]────────────────────┐${RS}\n"
  printf "${CY}│${RS} ${WH}%-6s  %-20s  %-14s${RS}                  ${CY}│${RS}\n" "Port" "Address" "Service"
  printf "${CY}├────────────────────────────────────────────────────────┤${RS}\n"
  ss -tlnp 2>/dev/null | tail -n +2 | sort -t: -k2 -n | while IFS= read -r line; do
    local addr port svc
    addr=$(echo "$line" | awk '{print $4}')
    port=$(echo "$addr" | rev | cut -d: -f1 | rev)
    svc=$(echo "$line" | grep -oP '"\K[^"]+(?=")' | head -1 || echo "-")
    printf "${CY}│${RS}  ${GR}%-6s${RS}  ${YE}%-20s${RS}  ${OR}%-14s${RS}                  ${CY}│${RS}\n" \
      "$port" "$addr" "${svc:0:14}"
  done
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  printf "${RD}  ⚠️  Port ถูกล็อคตายตัว — ไม่สามารถเปิด/ปิดได้${RS}\n\n"
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 11 — ปลดแบน IP / จัดการ User
# ══════════════════════════════════════════════════════════════
menu_11() {
  clear
  printf "${R3}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R3}║${RS}  🛡️  ${WH}ปลดแบน IP / จัดการ User${RS}  ${R3}[เมนู 11]${RS}            ${R3}║${RS}\n"
  printf "${R3}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── แสดง IP ที่แบนอยู่ปัจจุบัน ───────────────────────────
  local ban_count=0
  printf "${RD}┌─[ 🔒 IP ที่ถูกแบนอยู่ขณะนี้ ]─────────────────────────┐${RS}\n"
  printf "${RD}│${RS} ${WH}%-4s  %-20s  %-30s${RS} ${RD}│${RS}\n" "No." "IP Address" "Source"
  printf "${RD}├────────────────────────────────────────────────────────┤${RS}\n"
  while IFS= read -r line; do
    local bip
    bip=$(echo "$line" | awk '{print $4}')
    [[ -z "$bip" || "$bip" == "0.0.0.0/0" ]] && continue
    (( ban_count++ )) || true
    printf "${RD}│${RS}  ${YE}%-4d${RS}  ${WH}%-20s${RS}  ${OR}%-30s${RS} ${RD}│${RS}\n" "$ban_count" "$bip" "iptables DROP"
  done < <(iptables -L INPUT -n 2>/dev/null | grep DROP)
  if [[ -f "$BAN_FILE" && -s "$BAN_FILE" ]]; then
    while IFS= read -r bip; do
      [[ -z "$bip" ]] && continue
      (( ban_count++ )) || true
      printf "${RD}│${RS}  ${YE}%-4d${RS}  ${WH}%-20s${RS}  ${OR}%-30s${RS} ${RD}│${RS}\n" "$ban_count" "$bip" "ban.db"
    done < "$BAN_FILE"
  fi
  (( ban_count == 0 )) && printf "${RD}│${RS}  ${GR}✅ ไม่มี IP ที่แบนอยู่${RS}                                ${RD}│${RS}\n"
  printf "${RD}│${RS}  ${WH}รวม: ${YE}%d${WH} IP ที่แบน${RS}                                   ${RD}│${RS}\n" "$ban_count"
  printf "${RD}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── เมนูย่อย ─────────────────────────────────────────────
  printf "${R3}┌─[ เลือกการดำเนินการ ]──────────────────────────────────┐${RS}\n"
  printf "${R3}│${RS}  ${GR}1.${RS}  🔓 ปลดแบน IP                                       ${R3}│${RS}\n"
  printf "${R3}│${RS}  ${RD}2.${RS}  🔒 แบน IP เพิ่ม                                     ${R3}│${RS}\n"
  printf "${R3}│${RS}  ${CY}3.${RS}  🔄 รีเซ็ต Traffic VLESS User (ผ่าน API)             ${R3}│${RS}\n"
  printf "${R3}│${RS}  ${PU}4.${RS}  📦 Backup x-ui Users → ไฟล์ JSON                   ${R3}│${RS}\n"
  printf "${R3}│${RS}  ${R5}5.${RS}  📥 Import x-ui Users จากไฟล์ JSON                  ${R3}│${RS}\n"
  printf "${R3}│${RS}  ${YE}0.${RS}  ↩ ย้อนกลับ                                          ${R3}│${RS}\n"
  printf "${R3}└────────────────────────────────────────────────────────┘${RS}\n"
  read -rp "$(printf "\n${YE}เลือก: ${RS}")" sub

  case $sub in
    1)
      read -rp "$(printf "${YE}กรอก IP ที่จะปลดแบน: ${RS}")" IP
      [[ -z "$IP" ]] && { printf "${YE}↩ ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
      iptables -D INPUT -s "$IP" -j DROP 2>/dev/null || true
      sed -i "/${IP}/d" "$BAN_FILE" 2>/dev/null || true
      printf "\n${GR}┌─────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  🔓 ปลดแบน ${WH}%-20s${GR} สำเร็จ!  ${GR}│${RS}\n" "$IP"
      printf "${GR}└─────────────────────────────────────┘${RS}\n\n" ;;
    2)
      read -rp "$(printf "${YE}กรอก IP ที่จะแบน: ${RS}")" IP
      [[ -z "$IP" ]] && { printf "${YE}↩ ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
      printf "${YE}⚠️  ยืนยันแบน IP %s? (y/N): ${RS}" "$IP"
      read -r cf
      if [[ "$cf" == "y" || "$cf" == "Y" ]]; then
        iptables -I INPUT -s "$IP" -j DROP 2>/dev/null
        echo "$IP" >> "$BAN_FILE"
        printf "\n${RD}┌─────────────────────────────────────┐${RS}\n"
        printf "${RD}│${RS}  🔒 แบน ${WH}%-20s${RD} สำเร็จ!     ${RD}│${RS}\n" "$IP"
        printf "${RD}└─────────────────────────────────────┘${RS}\n\n"
      else
        printf "${YE}↩ ยกเลิก${RS}\n\n"
      fi ;;
    3)
      read -rp "$(printf "${YE}Email/username VLESS ที่จะรีเซ็ต traffic: ${RS}")" EMAIL
      [[ -z "$EMAIL" ]] && { printf "${YE}↩ ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
      printf "${YE}⏳ กำลังรีเซ็ต traffic...${RS}\n"
      local result
      result=$(xui_api POST "/panel/api/client/resetClientTraffic/${EMAIL}" "" 2>/dev/null)
      if echo "$result" | grep -q '"success":true'; then
        printf "\n${GR}┌─────────────────────────────────────────┐${RS}\n"
        printf "${GR}│${RS}  ✅ รีเซ็ต traffic ${WH}%-16s${GR} สำเร็จ! ${GR}│${RS}\n" "$EMAIL"
        printf "${GR}└─────────────────────────────────────────┘${RS}\n\n"
      else
        printf "\n${RD}❌ ไม่สำเร็จ — ตรวจสอบ email/username ให้ถูกต้อง${RS}\n\n"
      fi ;;

    4)
      # ── Backup x-ui users → JSON ──────────────────────────────
      printf "\n${PU}⏳ กำลัง backup x-ui users...${RS}\n"
      xui_login 2>/dev/null || { printf "${RD}❌ login x-ui ไม่สำเร็จ${RS}\n"; read -rp "Enter..."; return; }
      local _inbounds _backup_file _ts
      _ts=$(date +%Y%m%d_%H%M%S)
      _backup_file="/etc/chaiya/xui-backup-${_ts}.json"
      _inbounds=$(xui_api GET "/panel/api/inbounds/list" 2>/dev/null)
      if ! echo "$_inbounds" | grep -q '"success":true'; then
        printf "${RD}❌ ดึงข้อมูล inbounds ไม่สำเร็จ${RS}\n"; read -rp "Enter..."; return
      fi
      # extract clients จากทุก inbound
      echo "$_inbounds" | python3 -c "
import sys, json
data = json.load(sys.stdin)
result = []
for ib in data.get('obj', []):
    try:
        settings = json.loads(ib.get('settings','{}'))
        clients = settings.get('clients', [])
        for c in clients:
            c['_inbound_remark'] = ib.get('remark','')
            c['_inbound_port']   = ib.get('port',0)
            c['_protocol']       = ib.get('protocol','')
            result.append(c)
    except: pass
print(json.dumps(result, ensure_ascii=False, indent=2))
" > "$_backup_file" 2>/dev/null
      local _count
      _count=$(python3 -c "import json,sys; d=json.load(open('$_backup_file')); print(len(d))" 2>/dev/null || echo "0")
      printf "\n${GR}┌──────────────────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  📦 Backup สำเร็จ! ${YE}%s${WH} users${RS}                        ${GR}│${RS}\n" "$_count"
      printf "${GR}│${RS}  📁 ไฟล์: ${WH}%-40s${GR}│${RS}\n" "$_backup_file"
      printf "${GR}└──────────────────────────────────────────────────┘${RS}\n"
      printf "\n${CY}ดูไฟล์: cat %s${RS}\n\n" "$_backup_file" ;;

    5)
      # ── Import x-ui users จาก JSON ───────────────────────────
      printf "\n${R5}📥 Import x-ui Users จาก JSON${RS}\n\n"
      # แสดงไฟล์ backup ที่มีอยู่
      local _files=()
      while IFS= read -r f; do _files+=("$f"); done < <(ls /etc/chaiya/xui-backup-*.json 2>/dev/null | sort -r)
      if [[ ${#_files[@]} -gt 0 ]]; then
        printf "${CY}ไฟล์ backup ที่มีอยู่:${RS}\n"
        local i=1
        for f in "${_files[@]}"; do
          local cnt; cnt=$(python3 -c "import json; d=json.load(open('$f')); print(len(d))" 2>/dev/null || echo "?")
          printf "  ${YE}%d.${RS} ${WH}%s${RS} (${GR}%s users${RS})\n" "$i" "$(basename "$f")" "$cnt"
          (( i++ )) || true
        done
        printf "\n"
      fi
      read -rp "$(printf "${YE}กรอก path ไฟล์ JSON (หรือ Enter เพื่อยกเลิก): ${RS}")" _jpath
      [[ -z "$_jpath" ]] && { printf "${YE}↩ ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
      # รองรับ shortcut: กรอกแค่เลข → ใช้จากรายการ
      if [[ "$_jpath" =~ ^[0-9]+$ ]] && [[ "${_files[$((${_jpath}-1))]}" ]]; then
        _jpath="${_files[$((${_jpath}-1))]}"
      fi
      [[ ! -f "$_jpath" ]] && { printf "${RD}❌ ไม่พบไฟล์ %s${RS}\n" "$_jpath"; read -rp "Enter..."; return; }

      xui_login 2>/dev/null || { printf "${RD}❌ login x-ui ไม่สำเร็จ${RS}\n"; read -rp "Enter..."; return; }

      # ดึง inbound list เพื่อหา inbound_id
      local _iblist
      _iblist=$(xui_api GET "/panel/api/inbounds/list" 2>/dev/null)
      if ! echo "$_iblist" | grep -q '"success":true'; then
        printf "${RD}❌ ดึง inbound list ไม่สำเร็จ${RS}\n"; read -rp "Enter..."; return
      fi

      local _ok=0 _skip=0 _fail=0
      printf "\n${YE}⏳ กำลัง import...${RS}\n"

      # วน import ทีละ user
      local _total
      _total=$(python3 -c "import json; d=json.load(open('$_jpath')); print(len(d))" 2>/dev/null || echo 0)
      for (( _idx=0; _idx<_total; _idx++ )); do
        local _user_json _email _proto _port _iid _payload _res
        _user_json=$(python3 -c "
import json, sys
d = json.load(open('$_jpath'))
u = d[$_idx]
print(json.dumps(u))
" 2>/dev/null)
        _email=$(echo "$_user_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('email',''))" 2>/dev/null)
        _proto=$(echo "$_user_json"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('_protocol','vless'))" 2>/dev/null)
        _port=$(echo "$_user_json"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('_inbound_port',0))" 2>/dev/null)

        # หา inbound_id ที่ตรง protocol + port
        _iid=$(echo "$_iblist" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for ib in data.get('obj', []):
    if ib.get('protocol','') == '$_proto' and ib.get('port',0) == $_port:
        print(ib['id']); sys.exit(0)
# fallback: หาแค่ protocol ตรง
for ib in data.get('obj', []):
    if ib.get('protocol','') == '$_proto':
        print(ib['id']); sys.exit(0)
print('')
" 2>/dev/null)

        if [[ -z "$_iid" ]]; then
          printf "  ${YE}⚠️  skip %-20s (ไม่พบ inbound %s:%s)${RS}\n" "$_email" "$_proto" "$_port"
          (( _skip++ )); continue
        fi

        # สร้าง payload เฉพาะ fields ที่ต้องการ
        _payload=$(echo "$_user_json" | python3 -c "
import json, sys
u = json.load(sys.stdin)
# ลบ internal fields
for k in ['_inbound_remark','_inbound_port','_protocol']: u.pop(k, None)
client_payload = {'id': '$_iid', 'settings': json.dumps({'clients': [u]})}
print(json.dumps(client_payload))
" 2>/dev/null)

        _res=$(xui_api POST "/panel/api/inbounds/addClient" "$_payload" 2>/dev/null)
        if echo "$_res" | grep -q '"success":true'; then
          printf "  ${GR}✅ %-25s${RS}\n" "$_email"
          (( _ok++ )) || true
        else
          printf "  ${RD}❌ %-25s (อาจมีอยู่แล้ว)${RS}\n" "$_email"
          (( _fail++ )) || true
        fi
      done

      printf "\n${GR}┌──────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  ✅ Import สำเร็จ : ${YE}%-4s${RS} users          ${GR}│${RS}\n" "$_ok"
      printf "${GR}│${RS}  ⚠️  ข้าม (ไม่มี inbound) : ${YE}%-4s${RS}        ${GR}│${RS}\n" "$_skip"
      printf "${GR}│${RS}  ❌ ล้มเหลว : ${YE}%-4s${RS} (มีอยู่แล้ว?)      ${GR}│${RS}\n" "$_fail"
      printf "${GR}└──────────────────────────────────────┘${RS}\n\n" ;;
  esac
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 12 — บล็อก IP ต่างประเทศ
# ══════════════════════════════════════════════════════════════
menu_12() {
  clear
  printf "${R4}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R4}║${RS}  🌍 ${WH}บล็อก IP ต่างประเทศ${RS}  ${R4}[เมนู 12]${RS}                  ${R4}║${RS}\n"
  printf "${R4}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── แสดงสถานะ rules ปัจจุบัน ─────────────────────────────
  local rule_count
  rule_count=$(iptables -L INPUT -n 2>/dev/null | grep -c DROP || echo "0")

  printf "${CY}┌─[ 📊 สถานะ Firewall ปัจจุบัน ]────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  🛡️  iptables DROP rules  : ${WH}%-6s${RS}                        ${CY}│${RS}\n" "$rule_count"
  printf "${CY}│${RS}  🔒 UFW Status            : ${WH}%-20s${RS}              ${CY}│${RS}\n" "$(ufw status 2>/dev/null | head -1 | awk '{print $2}')"
  printf "${CY}│${RS}\n"
  printf "${CY}│${RS}  ${YE}Rule ล่าสุด (5 อันดับแรก):${RS}                            ${CY}│${RS}\n"
  iptables -L INPUT -n 2>/dev/null | grep -E "DROP|ACCEPT" | head -5 | while IFS= read -r r; do
    printf "${CY}│${RS}    ${OR}%.60s${RS}\n" "$r"
  done
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── เมนูย่อย ─────────────────────────────────────────────
  printf "${R4}┌─[ เลือกการดำเนินการ ]──────────────────────────────────┐${RS}\n"
  printf "${R4}│${RS}  ${GR}1.${RS}  🔒 บล็อก IP นอก TH/SG/MY/HK (Whitelist LAN)      ${R4}│${RS}\n"
  printf "${R4}│${RS}  ${YE}2.${RS}  📋 ดู Rules ทั้งหมด                                ${R4}│${RS}\n"
  printf "${R4}│${RS}  ${RD}3.${RS}  🗑️  ยกเลิกบล็อกทั้งหมด (Flush INPUT rules)        ${R4}│${RS}\n"
  printf "${R4}│${RS}  ${WH}0.${RS}  ↩ ย้อนกลับ                                         ${R4}│${RS}\n"
  printf "${R4}└────────────────────────────────────────────────────────┘${RS}\n"
  read -rp "$(printf "\n${YE}เลือก: ${RS}")" sub

  case $sub in
    1)
      printf "\n${OR}⚠️  การดำเนินการนี้จะบล็อก IP นอก Whitelist${RS}\n"
      printf "${YE}ยืนยัน? (y/N): ${RS}"
      read -r c
      [[ "$c" != "y" && "$c" != "Y" ]] && { printf "${YE}↩ ยกเลิก${RS}\n\n"; read -rp "Enter..."; return; }
      printf "\n${YE}⏳ กำลังตั้งค่า Whitelist...${RS}\n\n"
      iptables -I INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
      printf "${GR}  ✅ ESTABLISHED,RELATED → ACCEPT${RS}\n"
      for net in "127.0.0.0/8 Loopback" "10.0.0.0/8 Private-A" "192.168.0.0/16 Private-C" "172.16.0.0/12 Private-B"; do
        local cidr label
        cidr=$(echo "$net" | awk '{print $1}')
        label=$(echo "$net" | awk '{print $2}')
        iptables -I INPUT -s "$cidr" -j ACCEPT 2>/dev/null
        printf "${GR}  ✅ %-18s → ACCEPT (%s)${RS}\n" "$cidr" "$label"
      done
      printf "\n${GR}┌────────────────────────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  ✅ ตั้งค่า Whitelist LAN สำเร็จ                      ${GR}│${RS}\n"
      printf "${GR}│${RS}  ${YE}💡 ต้องเพิ่ม IP range ISP (ipset) เองเพิ่มเติม${RS}       ${GR}│${RS}\n"
      printf "${GR}└────────────────────────────────────────────────────────┘${RS}\n\n" ;;
    2)
      printf "\n${CY}┌─[ 📋 iptables INPUT Rules ทั้งหมด ]───────────────────┐${RS}\n"
      local rn=0
      iptables -L INPUT -n --line-numbers 2>/dev/null | while IFS= read -r r; do
        printf "${CY}│${RS}  ${OR}%.65s${RS}\n" "$r"
      done
      printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n" ;;
    3)
      printf "\n${RD}⚠️  ยืนยันล้าง INPUT rules ทั้งหมด? (y/N): ${RS}"
      read -r c
      if [[ "$c" == "y" || "$c" == "Y" ]]; then
        iptables -F INPUT 2>/dev/null
        printf "\n${GR}┌───────────────────────────────────┐${RS}\n"
        printf "${GR}│${RS}  ✅ ล้าง INPUT rules สำเร็จ       ${GR}│${RS}\n"
        printf "${GR}└───────────────────────────────────┘${RS}\n\n"
      else
        printf "${YE}↩ ยกเลิก${RS}\n\n"
      fi ;;
  esac
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 13 — สแกน Bug Host (SNI)
# ══════════════════════════════════════════════════════════════
menu_13() {
  clear
  printf "${R5}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R5}║${RS}  🔍 ${WH}สแกน Bug Host (SNI)${RS}  ${R5}[เมนู 13]${RS}                  ${R5}║${RS}\n"
  printf "${R5}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  printf "${CY}┌─[ 📡 SNI ยอดนิยม ]─────────────────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  ${GR}1.${RS}  cj-ebb.speedtest.net          ${YE}(AIS)${RS}             ${CY}│${RS}\n"
  printf "${CY}│${RS}  ${GR}2.${RS}  speedtest.net                  ${YE}(ทั่วไป)${RS}          ${CY}│${RS}\n"
  printf "${CY}│${RS}  ${GR}3.${RS}  true-internet.zoom.xyz.services ${YE}(TRUE)${RS}           ${CY}│${RS}\n"
  printf "${CY}│${RS}  ${GR}4.${RS}  กรอก SNI เอง                                       ${CY}│${RS}\n"
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n"
  read -rp "$(printf "\n${YE}เลือก (หรือกรอก SNI โดยตรง): ${RS}")" sel

  case $sel in
    1) TARGET="cj-ebb.speedtest.net" ;;
    2) TARGET="speedtest.net" ;;
    3) TARGET="true-internet.zoom.xyz.services" ;;
    4) read -rp "$(printf "${YE}กรอก SNI: ${RS}")" TARGET ;;
    *) TARGET="$sel" ;;
  esac
  [[ -z "$TARGET" ]] && { printf "${YE}↩ ยกเลิก${RS}\n\n"; read -rp "Enter..."; return; }

  clear
  printf "${R5}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R5}║${RS}  🔍 ${WH}ผลสแกน: ${CY}%-37s${R5}║${RS}\n" "$TARGET"
  printf "${R5}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── HTTP Headers ─────────────────────────────────────────
  printf "${YE}┌─[ 🌐 HTTP Headers ]────────────────────────────────────┐${RS}\n"
  local http_out
  http_out=$(curl -sI --max-time 3 "http://${TARGET}" 2>/dev/null | head -10)
  if [[ -n "$http_out" ]]; then
    echo "$http_out" | while IFS= read -r line; do
      printf "${YE}│${RS}  ${WH}%.60s${RS}\n" "$line"
    done
  else
    printf "${YE}│${RS}  ${RD}⚠️  ไม่ตอบสนอง HTTP${RS}\n"
  fi
  local http_code
  http_code=$(curl -sI --max-time 3 -o /dev/null -w "%{http_code}" "http://${TARGET}" 2>/dev/null || echo "000")
  printf "${YE}│${RS}  ${GR}HTTP Status Code: ${WH}%s${RS}\n" "$http_code"
  printf "${YE}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── TLS/SNI ──────────────────────────────────────────────
  printf "${CY}┌─[ 🔒 TLS / SNI Info ]──────────────────────────────────┐${RS}\n"
  local tls_out
  tls_out=$(echo | openssl s_client -connect "${TARGET}:443" -servername "$TARGET" 2>/dev/null \
    | grep -E "subject|issuer|SSL-Session|Protocol|Cipher" | head -8)
  if [[ -n "$tls_out" ]]; then
    echo "$tls_out" | while IFS= read -r line; do
      printf "${CY}│${RS}  ${WH}%.62s${RS}\n" "$line"
    done
  else
    printf "${CY}│${RS}  ${OR}⚠️  ไม่มี TLS / ไม่ตอบสนอง port 443${RS}\n"
  fi
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── WebSocket Test ────────────────────────────────────────
  printf "${GR}┌─[ 🔌 WebSocket Test ]──────────────────────────────────┐${RS}\n"
  local ws_out ws_code
  ws_out=$(curl -sI --max-time 5 \
    -H "Upgrade: websocket" \
    -H "Connection: Upgrade" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Host: ${TARGET}" \
    "http://${TARGET}" 2>/dev/null | head -5)
  ws_code=$(echo "$ws_out" | grep "HTTP" | awk '{print $2}')
  if echo "$ws_out" | grep -qiE "101|Upgrade|websocket"; then
    printf "${GR}│${RS}  ${GR}✅ รองรับ WebSocket!${RS}\n"
    printf "${GR}│${RS}  ${WH}Status: %s${RS}\n" "${ws_code:-ไม่ทราบ}"
  else
    printf "${GR}│${RS}  ${OR}⚠️  ไม่รองรับ WebSocket โดยตรง${RS}\n"
    printf "${GR}│${RS}  ${WH}Status: %s${RS}\n" "${ws_code:-ไม่ตอบสนอง}"
  fi
  printf "${GR}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── Ping Latency ─────────────────────────────────────────
  printf "${R2}┌─[ 📶 Ping Latency (5 ครั้ง) ]─────────────────────────┐${RS}\n"
  local ping_out ping_avg ping_loss
  # [FIX] ลด ping count และ timeout เพื่อไม่ให้รอนานถ้า host ไม่ตอบ
  ping_out=$(ping -c 3 -W 2 "$TARGET" 2>/dev/null)
  if [[ -n "$ping_out" ]]; then
    ping_avg=$(echo "$ping_out" | tail -1 | awk -F'/' '{printf "%.2f ms", $5}' 2>/dev/null || echo "N/A")
    ping_loss=$(echo "$ping_out" | grep -oP '\d+(?=% packet loss)' || echo "100")
    printf "${R2}│${RS}  📍 Host      : ${WH}%s${RS}\n" "$TARGET"
    printf "${R2}│${RS}  📊 Avg Ping  : ${GR}%s${RS}\n" "$ping_avg"
    printf "${R2}│${RS}  📉 Packet Loss: "
    (( ping_loss > 0 )) && printf "${RD}%s%%${RS}\n" "$ping_loss" || printf "${GR}%s%%${RS}\n" "$ping_loss"
    echo "$ping_out" | grep -E "bytes from|time=" | head -5 | while IFS= read -r line; do
      printf "${R2}│${RS}    ${OR}%.62s${RS}\n" "$line"
    done
  else
    printf "${R2}│${RS}  ${RD}❌ Ping ไม่ได้ — อาจถูกบล็อก ICMP${RS}\n"
  fi
  printf "${R2}└────────────────────────────────────────────────────────┘${RS}\n\n"

  printf "${GR}✅ สแกน ${WH}%s${GR} เสร็จสมบูรณ์${RS}\n\n" "$TARGET"
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 14 — ลบ User
# ══════════════════════════════════════════════════════════════
menu_14() {
  clear
  printf "${R6}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${R6}║${RS}  🗑️  ${WH}ลบ User${RS}  ${R6}[เมนู 14]${RS}                              ${R6}║${RS}\n"
  printf "${R6}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  if [[ ! -f "$DB" || ! -s "$DB" ]]; then
    printf "${YE}┌──────────────────────────────────────┐${RS}\n"
    printf "${YE}│${RS}  ℹ️  ไม่มีบัญชีในระบบ                 ${YE}│${RS}\n"
    printf "${YE}└──────────────────────────────────────┘${RS}\n\n"
    read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"; return
  fi

  # ── แสดงตารางรายชื่อ user ─────────────────────────────────
  local NOW; NOW=$(date +%s)
  printf "${CY}┌──────┬──────────────────────┬────────────┬──────────┬────────────┐${RS}\n"
  printf "${CY}│${RS} ${WH}%-4s${RS} ${CY}│${RS} ${WH}%-20s${RS} ${CY}│${RS} ${WH}%-10s${RS} ${CY}│${RS} ${WH}%-8s${RS} ${CY}│${RS} ${WH}%-10s${RS} ${CY}│${RS}\n" \
    "No." "Username" "หมดอายุ" "Data GB" "สถานะ"
  printf "${CY}├──────┼──────────────────────┼────────────┼──────────┼────────────┤${RS}\n"

  local n=0
  declare -a USER_LIST=()
  while IFS=' ' read -r user days exp quota rest; do
    [[ -z "$user" ]] && continue
    (( n++ )) || true
    USER_LIST+=("$user")
    local EXP_TS; EXP_TS=$(date -d "$exp" +%s 2>/dev/null || echo 0)
    local SC ST
    (( EXP_TS < NOW )) && SC="$RD" && ST="EXPIRED" || SC="$GR" && ST="ACTIVE"
    local DQ="${quota:-∞}"; [[ "$quota" == "0" ]] && DQ="Unlimited"
    printf "${CY}│${RS} ${YE}%-4d${RS} ${CY}│${RS} ${WH}%-20s${RS} ${CY}│${RS} ${SC}%-10s${RS} ${CY}│${RS} ${OR}%-8s${RS} ${CY}│${RS} ${SC}%-10s${RS} ${CY}│${RS}\n" \
      "$n" "$user" "$exp" "$DQ" "$ST"
  done < "$DB"

  printf "${CY}├──────┴──────────────────────┴────────────┴──────────┴────────────┤${RS}\n"
  printf "${CY}│${RS}  ${WH}รวม: ${YE}%d${WH} บัญชี${RS}                                             ${CY}│${RS}\n" "$n"
  printf "${CY}└─────────────────────────────────────────────────────────────────┘${RS}\n\n"

  read -rp "$(printf "${YE}กรอกชื่อ User ที่จะลบ (Enter = ยกเลิก): ${RS}")" UNAME
  [[ -z "$UNAME" ]] && { printf "${YE}↩ ยกเลิก${RS}\n\n"; read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"; return; }

  if grep -q "^${UNAME} " "$DB"; then
    printf "\n${OR}⚠️  ยืนยันลบ User ${WH}%s${OR}? การดำเนินการนี้ไม่สามารถย้อนกลับได้ (y/N): ${RS}" "$UNAME"
    read -r cf
    if [[ "$cf" == "y" || "$cf" == "Y" ]]; then
      printf "\n${R2}⏳ กำลังลบ...${RS}\n"
      sed -i "/^${UNAME} /d" "$DB" 2>/dev/null || true
      userdel -f "$UNAME" 2>/dev/null || true
      xui_api POST "/panel/api/client/delByEmail/${UNAME}" "" > /dev/null 2>&1 || true
      rm -f "/var/www/chaiya/config/${UNAME}.html" 2>/dev/null || true

      printf "\n${GR}┌────────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  ✅ ลบ User ${WH}%-20s${GR} สำเร็จ! ${GR}│${RS}\n" "$UNAME"
      printf "${GR}│${RS}  ${YE}• ลบออกจาก Local DB แล้ว${RS}              ${GR}│${RS}\n"
      printf "${GR}│${RS}  ${YE}• ส่ง API ลบจาก 3x-ui แล้ว${RS}           ${GR}│${RS}\n"
      printf "${GR}│${RS}  ${YE}• ลบไฟล์ config HTML แล้ว${RS}             ${GR}│${RS}\n"
      printf "${GR}└────────────────────────────────────────┘${RS}\n\n"
    else
      printf "${YE}↩ ยกเลิก${RS}\n\n"
    fi
  else
    printf "\n${RD}┌────────────────────────────────────────┐${RS}\n"
    printf "${RD}│${RS}  ❌ ไม่พบ User ${WH}%-18s${RD} ในระบบ ${RD}│${RS}\n" "$UNAME"
    printf "${RD}└────────────────────────────────────────┘${RS}\n\n"
  fi
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 15 — ตั้งค่ารีบูตอัตโนมัติ
# ══════════════════════════════════════════════════════════════
menu_15() {
  clear
  printf "${PU}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${PU}║${RS}  ⏰ ${WH}ตั้งค่ารีบูตอัตโนมัติ${RS}  ${PU}[เมนู 15]${RS}                ${PU}║${RS}\n"
  printf "${PU}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── สถานะ crontab ปัจจุบัน ───────────────────────────────
  local current_reboot uptime_str last_boot
  current_reboot=$(crontab -l 2>/dev/null | grep "chaiya-reboot" || echo "")
  uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | cut -d, -f1)
  last_boot=$(who -b 2>/dev/null | awk '{print $3, $4}' || uptime | awk '{print $3}')

  printf "${CY}┌─[ 📊 สถานะปัจจุบัน ]───────────────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  ⏱️  Uptime      : ${WH}%-36s${RS} ${CY}│${RS}\n" "$uptime_str"
  printf "${CY}│${RS}  🕐 Last Boot   : ${WH}%-36s${RS} ${CY}│${RS}\n" "$last_boot"
  if [[ -n "$current_reboot" ]]; then
    printf "${CY}│${RS}  ⏰ Auto Reboot : ${GR}%-36s${RS} ${CY}│${RS}\n" "เปิดอยู่"
    printf "${CY}│${RS}  📋 Schedule   : ${YE}%-36s${RS} ${CY}│${RS}\n" "$current_reboot"
  else
    printf "${CY}│${RS}  ⏰ Auto Reboot : ${OR}%-36s${RS} ${CY}│${RS}\n" "ปิดอยู่"
  fi
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── เมนูย่อย ─────────────────────────────────────────────
  printf "${PU}┌─[ เลือกการดำเนินการ ]──────────────────────────────────┐${RS}\n"
  printf "${PU}│${RS}  ${GR}1.${RS}  ⏰ รีบูตตามเวลาที่กำหนดเอง (ทุกวัน)              ${PU}│${RS}\n"
  printf "${PU}│${RS}  ${YE}2.${RS}  📅 รีบูตทุกวันอาทิตย์ เวลา 03:00 น.              ${PU}│${RS}\n"
  printf "${PU}│${RS}  ${RD}3.${RS}  ❌ ยกเลิกรีบูตอัตโนมัติ                          ${PU}│${RS}\n"
  printf "${PU}│${RS}  ${CY}4.${RS}  📋 ดู Crontab ทั้งหมด                             ${PU}│${RS}\n"
  printf "${PU}│${RS}  ${WH}0.${RS}  ↩ ย้อนกลับ                                         ${PU}│${RS}\n"
  printf "${PU}└────────────────────────────────────────────────────────┘${RS}\n"
  read -rp "$(printf "\n${YE}เลือก: ${RS}")" sub

  case $sub in
    1)
      read -rp "$(printf "${YE}กรอกเวลา (เช่น 04:00): ${RS}")" T
      [[ -z "$T" ]] && { printf "${YE}↩ ยกเลิก${RS}\n"; read -rp "Enter..."; return; }
      local H M
      H=$(echo "$T" | cut -d: -f1); M=$(echo "$T" | cut -d: -f2)
      (crontab -l 2>/dev/null | grep -v "chaiya-reboot"; echo "$M $H * * * /sbin/reboot # chaiya-reboot") | crontab -
      printf "\n${GR}┌────────────────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  ✅ ตั้งค่า Auto Reboot ทุกวัน เวลา ${WH}%-10s${GR}  ${GR}│${RS}\n" "$T"
      printf "${GR}│${RS}  📋 Cron: ${YE}%s %s * * * /sbin/reboot${RS}         ${GR}│${RS}\n" "$M" "$H"
      printf "${GR}└────────────────────────────────────────────────┘${RS}\n\n" ;;
    2)
      (crontab -l 2>/dev/null | grep -v "chaiya-reboot"; echo "0 3 * * 0 /sbin/reboot # chaiya-reboot") | crontab -
      printf "\n${GR}┌────────────────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  ✅ ตั้งค่า Auto Reboot ทุกวันอาทิตย์ 03:00 น.${GR}│${RS}\n"
      printf "${GR}│${RS}  📋 Cron: ${YE}0 3 * * 0 /sbin/reboot${RS}           ${GR}│${RS}\n"
      printf "${GR}└────────────────────────────────────────────────┘${RS}\n\n" ;;
    3)
      crontab -l 2>/dev/null | grep -v "chaiya-reboot" | crontab -
      printf "\n${YE}┌────────────────────────────────────────────────┐${RS}\n"
      printf "${YE}│${RS}  ✅ ยกเลิก Auto Reboot สำเร็จ                   ${YE}│${RS}\n"
      printf "${YE}└────────────────────────────────────────────────┘${RS}\n\n" ;;
    4)
      printf "\n${CY}┌─[ 📋 Crontab ทั้งหมด ]─────────────────────────────────┐${RS}\n"
      local ctab; ctab=$(crontab -l 2>/dev/null)
      if [[ -n "$ctab" ]]; then
        echo "$ctab" | while IFS= read -r line; do
          printf "${CY}│${RS}  ${WH}%.60s${RS}\n" "$line"
        done
      else
        printf "${CY}│${RS}  ${OR}ไม่มี crontab${RS}\n"
      fi
      printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n" ;;
  esac
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 16 — อัพเดทสคริปต์ / ถอนการติดตั้ง
# ══════════════════════════════════════════════════════════════
menu_16() {
  clear
  local REPO_URL="https://raw.githubusercontent.com/Chaiyakey99/chaiya-vpn/main/ChaiyaProject.sh"
  local INSTALL_CMD="bash <(curl -Ls \"${REPO_URL}\")"

  printf "${MG}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${MG}║${RS}  🔄 ${WH}อัพเดทสคริปต์ / ถอนการติดตั้ง${RS}  ${MG}[เมนู 16]${RS}       ${MG}║${RS}\n"
  printf "${MG}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── เวอร์ชันปัจจุบัน ──────────────────────────────────────────
  local cur_ver cur_date cur_md5
  cur_ver="${CHAIYA_VERSION:-unknown}"
  cur_date=$(date -r /usr/local/bin/menu '+%Y-%m-%d %H:%M' 2>/dev/null || echo "ไม่ทราบ")
  cur_md5=$(md5sum /usr/local/bin/menu 2>/dev/null | cut -c1-8 || echo "?")

  printf "${CY}┌─[ ℹ️  ข้อมูลสคริปต์ปัจจุบัน ]─────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  🏷️  Version  : ${YE}%s${RS}\n" "$cur_ver"
  printf "${CY}│${RS}  📦 Checksum : ${YE}%s${RS}\n" "$cur_md5"
  printf "${CY}│${RS}  📅 ติดตั้ง  : ${YE}%s${RS}\n" "$cur_date"
  printf "${CY}│${RS}  🔗 GitHub   : ${WH}Chaiyakey99/chaiya-vpn${RS}\n"
  printf "${CY}│${RS}  📂 ไฟล์หลัก : ${WH}/usr/local/bin/menu${RS}\n"
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  printf "${MG}  1.${RS}  🔄  อัพเดทสคริปต์จาก GitHub\n"
  printf "${RD}  2.${RS}  🗑️   ถอนการติดตั้ง CHAIYA ทั้งหมด\n"
  printf "${WH}  0.${RS}  ↩   ย้อนกลับ\n\n"

  read -rp "$(printf "${YE}เลือก: ${RS}")" _sub16
  case $_sub16 in

    1)
      clear
      printf "${MG}╔══════════════════════════════════════════════════════╗${RS}\n"
      printf "${MG}║${RS}  🔄 ${WH}กำลังอัพเดทสคริปต์จาก GitHub...${RS}              ${MG}║${RS}\n"
      printf "${MG}╚══════════════════════════════════════════════════════╝${RS}\n\n"

      printf "${YE}⏳ ดึงสคริปต์เวอร์ชันล่าสุด...${RS}\n\n"

      # ดาวน์โหลดลง tmp ก่อน ตรวจสอบ แล้วรันจากไฟล์ที่ดาวน์โหลดมาโดยตรง
      local tmp_script="/tmp/chaiya_update_$$.sh"
      if curl -Ls "$REPO_URL" -o "$tmp_script" 2>/dev/null && [[ -s "$tmp_script" ]]; then
        local new_md5
        new_md5=$(md5sum "$tmp_script" | cut -c1-8)
        local new_lines
        new_lines=$(wc -l < "$tmp_script")
        printf "${GR}✅ ดาวน์โหลดสำเร็จ${RS}\n"
        printf "   Checksum ใหม่ : ${YE}%s${RS}\n" "$new_md5"
        printf "   ขนาด          : ${YE}%s บรรทัด${RS}\n\n" "$new_lines"
        if [[ "$cur_md5" == "$new_md5" ]]; then
          printf "${GR}✅ สคริปต์เป็นเวอร์ชันล่าสุดแล้ว ไม่จำเป็นต้องอัพเดท${RS}\n"
          rm -f "$tmp_script"
          sleep 2; menu_16; return
        fi
        printf "${OR}⚠️  ยืนยันอัพเดท? (y/N): ${RS}"
        read -r _cf
        if [[ "$_cf" == "y" || "$_cf" == "Y" ]]; then
          printf "\n${CY}🚀 กำลังรันสคริปต์อัพเดท...${RS}\n\n"
          chmod +x "$tmp_script"
          # exec แทนที่ process ปัจจุบันด้วย script ใหม่ — session SSH ไม่หลุด
          # หมายเหตุ: บรรทัดหลัง exec ไม่ถูกรันเลย (ไม่ต้องมี rm)
          exec bash "$tmp_script"
        else
          rm -f "$tmp_script"
          printf "${YE}↩ ยกเลิก${RS}\n"
          sleep 1; menu_16
        fi
      else
        rm -f "$tmp_script" 2>/dev/null
        printf "${RD}❌ ดาวน์โหลดล้มเหลว — ตรวจสอบอินเตอร์เน็ต${RS}\n"
        sleep 2; menu_16
      fi
      ;;

    2)
      clear
      printf "${RD}╔══════════════════════════════════════════════════════╗${RS}\n"
      printf "${RD}║${RS}  🗑️  ${WH}ถอนการติดตั้ง CHAIYA ทั้งหมด${RS}                   ${RD}║${RS}\n"
      printf "${RD}╚══════════════════════════════════════════════════════╝${RS}\n\n"

      printf "${RD}⚠️  การดำเนินการนี้จะลบทุกอย่างที่ติดตั้งโดย CHAIYA:${RS}\n"
      printf "   • services: chaiya-sshws-api, chaiya-sshws, chaiya-iplimit\n"
      printf "   • x-ui panel + inbounds ทั้งหมด\n"
      printf "   • ไฟล์ /etc/chaiya/, /var/www/chaiya/\n"
      printf "   • nginx config ของ chaiya\n"
      printf "   • SSH users ที่สร้างผ่านเมนู\n\n"

      printf "${RD}พิมพ์ CONFIRM เพื่อยืนยัน (หรือ Enter ยกเลิก): ${RS}"
      read -r _confirm
      if [[ "$_confirm" != "CONFIRM" ]]; then
        printf "${YE}↩ ยกเลิก${RS}\n"
        sleep 1; menu_16; return
      fi

      printf "\n${RD}🗑️  กำลังถอนการติดตั้ง...${RS}\n\n"

      # หยุดและลบ services
      for svc in chaiya-sshws-api chaiya-sshws chaiya-iplimit x-ui; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        printf "  ${GR}✅ หยุด + ลบ service: %s${RS}\n" "$svc"
      done
      systemctl daemon-reload 2>/dev/null || true

      # ลบ SSH users ที่สร้างจาก chaiya
      local DB="/etc/chaiya/sshws-users/users.db"
      if [[ -f "$DB" ]]; then
        while read -r _u _rest; do
          [[ -z "$_u" ]] && continue
          pkill -u "$_u" -9 2>/dev/null || true
          userdel -f "$_u" 2>/dev/null || true
          printf "  ${GR}✅ ลบ SSH user: %s${RS}\n" "$_u"
        done < "$DB"
      fi

      # ลบ x-ui
      rm -rf /usr/local/x-ui /usr/local/bin/x-ui 2>/dev/null || true

      # [FIX] ลบ binaries และ services ที่ขาดไป
      # หยุด dropbear และ badvpn ที่ uninstall เก่าไม่ได้ลบ
      for svc in dropbear chaiya-badvpn; do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
        printf "  ${GR}✅ หยุด + ลบ service: %s${RS}\n" "$svc"
      done
      # ลบ dropbear override config
      rm -rf /etc/systemd/system/dropbear.service.d 2>/dev/null || true
      # kill badvpn ที่อาจรันผ่าน screen
      pkill -f badvpn 2>/dev/null || true

      # ลบไฟล์ chaiya ทั้งหมด
      rm -rf /etc/chaiya /var/www/chaiya 2>/dev/null || true
      rm -f /usr/local/bin/menu \
            /usr/local/bin/chaiya-datalimit \
            /usr/local/bin/chaiya-sshws-api \
            /usr/local/bin/ws-stunnel \
            /usr/local/bin/chaiya-iplimit \
            /usr/local/bin/chaiya-data-tracker \
            /usr/local/bin/chaiya-cpu-guard 2>/dev/null || true

      # ลบ systemd timer ของ data-tracker
      systemctl stop chaiya-data-tracker.timer 2>/dev/null || true
      systemctl disable chaiya-data-tracker.timer 2>/dev/null || true
      rm -f /etc/systemd/system/chaiya-data-tracker.service \
            /etc/systemd/system/chaiya-data-tracker.timer 2>/dev/null || true

      # ลบ log files
      rm -f /var/log/chaiya-iplimit.log \
            /var/log/chaiya-datalimit.log \
            /var/log/chaiya-sshws.log \
            /var/log/chaiya-cpu-guard.log \
            /var/log/chaiya-xui-install.log 2>/dev/null || true

      systemctl daemon-reload 2>/dev/null || true

      # ลบ nginx config chaiya ทุก variant
      rm -f /etc/nginx/sites-enabled/chaiya \
            /etc/nginx/sites-available/chaiya \
            /etc/nginx/sites-enabled/chaiya-ssl \
            /etc/nginx/sites-available/chaiya-ssl \
            /etc/nginx/sites-enabled/chaiya-sshws \
            /etc/nginx/sites-available/chaiya-sshws \
            /etc/nginx/conf.d/ws.conf 2>/dev/null || true
      # เปิด default nginx กลับ
      ln -sf /etc/nginx/sites-available/default \
             /etc/nginx/sites-enabled/default 2>/dev/null || true
      _ensure_nginx

      nginx -t 2>/dev/null && nginx -s reload 2>/dev/null || true

      # ลบ crontab entries ทั้งหมดของ chaiya
      (crontab -l 2>/dev/null || true) \
        | grep -v "chaiya\|badvpn" \
        | crontab - 2>/dev/null || true

      # ลบ alias ใน .bashrc
      sed -i '/CHAIYA menu alias/,+2d' /root/.bashrc 2>/dev/null || true

      # [FIX] ลบ CHAIYA_BLOCK iptables chain ก่อน reset UFW
      iptables -D INPUT -j CHAIYA_BLOCK 2>/dev/null || true
      iptables -D INPUT -j CHAIYA_IN    2>/dev/null || true
      iptables -D OUTPUT -j CHAIYA_OUT  2>/dev/null || true
      iptables -F CHAIYA_BLOCK 2>/dev/null || true
      iptables -F CHAIYA_IN    2>/dev/null || true
      iptables -F CHAIYA_OUT   2>/dev/null || true
      iptables -X CHAIYA_BLOCK 2>/dev/null || true
      iptables -X CHAIYA_IN    2>/dev/null || true
      iptables -X CHAIYA_OUT   2>/dev/null || true
      rm -f /etc/iptables/rules.v4 2>/dev/null || true

      # reset UFW กลับ default
      ufw --force reset 2>/dev/null || true
      ufw default allow incoming 2>/dev/null || true
      ufw allow 22/tcp 2>/dev/null || true
      ufw --force enable 2>/dev/null || true

      printf "\n${GR}╔══════════════════════════════════════════════════════╗${RS}\n"
      printf "${GR}║${RS}  ✅ ถอนการติดตั้ง CHAIYA เสร็จสมบูรณ์              ${GR}║${RS}\n"
      printf "${GR}║${RS}  Server พร้อมติดตั้งใหม่ได้ทันที                    ${GR}║${RS}\n"
      printf "${GR}╚══════════════════════════════════════════════════════╝${RS}\n\n"
      exit 0
      ;;

    0) return ;;
    *) menu_16 ;;
  esac
}


# ══════════════════════════════════════════════════════════════
# เมนู 17 — เคลียร์ CPU อัตโนมัติ
# ══════════════════════════════════════════════════════════════
menu_17() {
  clear
  printf "${YE}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${YE}║${RS}  🧹 ${WH}เคลียร์ CPU อัตโนมัติ${RS}  ${YE}[เมนู 17]${RS}                ${YE}║${RS}\n"
  printf "${YE}╚══════════════════════════════════════════════════════╝${RS}\n\n"

  # ── สถานะ CPU Guard ──────────────────────────────────────
  local guard_active cpu_now load_avg
  guard_active=$(crontab -l 2>/dev/null | grep -c "chaiya-cpu" || echo "0")
  cpu_now=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.1f", $2+$4}' 2>/dev/null || echo "0")
  load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs)

  printf "${CY}┌─[ 📊 สถานะ CPU Guard ปัจจุบัน ]───────────────────────┐${RS}\n"
  printf "${CY}│${RS}  🔥 CPU ขณะนี้    : ${WH}%-8s%%${RS}                           ${CY}│${RS}\n" "$cpu_now"
  printf "${CY}│${RS}  ⚡ Load Average  : ${WH}%-30s${RS}             ${CY}│${RS}\n" "$load_avg"
  if (( guard_active > 0 )); then
    printf "${CY}│${RS}  🛡️  CPU Guard     : ${GR}%-20s${RS}                       ${CY}│${RS}\n" "🟢 เปิดอยู่"
    local guard_cron
    guard_cron=$(crontab -l 2>/dev/null | grep "chaiya-cpu" | head -1)
    printf "${CY}│${RS}  📋 Cron Schedule : ${YE}%-40s${RS} ${CY}│${RS}\n" "$guard_cron"
  else
    printf "${CY}│${RS}  🛡️  CPU Guard     : ${OR}%-20s${RS}                       ${CY}│${RS}\n" "🔴 ปิดอยู่"
  fi
  printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── Top Process ตอนนี้ ────────────────────────────────────
  printf "${R2}┌─[ 🔥 Top 5 Process CPU สูงสุดขณะนี้ ]────────────────┐${RS}\n"
  printf "${R2}│${RS} ${WH}%-8s  %-6s  %-6s  %-22s${RS} ${R2}│${RS}\n" "PID" "CPU%" "MEM%" "Command"
  printf "${R2}├────────────────────────────────────────────────────────┤${RS}\n"
  ps aux --sort=-%cpu | tail -n +2 | head -5 | while IFS= read -r line; do
    local pid cpu mem cmd
    pid=$(echo "$line" | awk '{print $2}')
    cpu=$(echo "$line" | awk '{print $3}')
    mem=$(echo "$line" | awk '{print $4}')
    cmd=$(echo "$line" | awk '{print $11}' | sed 's|.*/||' | cut -c1-22)
    local cpu_int; cpu_int=$(echo "$cpu" | cut -d. -f1)
    local CC
    (( cpu_int >= 80 )) && CC="$RD" || { (( cpu_int >= 40 )) && CC="$OR" || CC="$GR"; }
    printf "${R2}│${RS}  ${YE}%-8s${RS}  ${CC}%-6s${RS}  ${WH}%-6s${RS}  ${WH}%-22s${RS} ${R2}│${RS}\n" "$pid" "$cpu" "$mem" "$cmd"
  done
  printf "${R2}└────────────────────────────────────────────────────────┘${RS}\n\n"

  # ── เมนูย่อย ─────────────────────────────────────────────
  printf "${YE}┌─[ เลือกการดำเนินการ ]──────────────────────────────────┐${RS}\n"
  printf "${YE}│${RS}  ${GR}1.${RS}  🟢 เปิด CPU Guard (kill process CPU>80%% ทุก 5 นาที) ${YE}│${RS}\n"
  printf "${YE}│${RS}  ${RD}2.${RS}  🔴 ปิด CPU Guard                                    ${YE}│${RS}\n"
  printf "${YE}│${RS}  ${CY}3.${RS}  📋 ดู Log CPU Guard (20 บรรทัดล่าสุด)               ${YE}│${RS}\n"
  printf "${YE}│${RS}  ${WH}0.${RS}  ↩ ย้อนกลับ                                           ${YE}│${RS}\n"
  printf "${YE}└────────────────────────────────────────────────────────┘${RS}\n"
  read -rp "$(printf "\n${YE}เลือก: ${RS}")" sub

  case $sub in
    1)
      cat > /usr/local/bin/chaiya-cpu-guard << 'CPUEOF'
#!/bin/bash
ps -eo pid,pcpu,comm --sort=-pcpu | tail -n +2 | head -20 | while read pid cpu cmd; do
  INT=${cpu%.*}
  (( INT > 80 )) || continue
  [[ "$cmd" =~ sshd|nginx|chaiya|python|systemd|x-ui ]] && continue
  kill -9 "$pid" 2>/dev/null
  echo "$(date) killed $pid ($cmd) cpu=$cpu%" >> /var/log/chaiya-cpu-guard.log
done
CPUEOF
      chmod +x /usr/local/bin/chaiya-cpu-guard
      (crontab -l 2>/dev/null | grep -v "chaiya-cpu"; echo "*/5 * * * * /usr/local/bin/chaiya-cpu-guard # chaiya-cpu") | crontab -
      printf "\n${GR}┌────────────────────────────────────────────────────────┐${RS}\n"
      printf "${GR}│${RS}  ✅ เปิด CPU Guard สำเร็จ!                             ${GR}│${RS}\n"
      printf "${GR}│${RS}  📋 จะ kill process ที่ CPU > 80%% ทุก 5 นาที           ${GR}│${RS}\n"
      printf "${GR}│${RS}  🛡️  ยกเว้น: sshd, nginx, chaiya, python, systemd, x-ui ${GR}│${RS}\n"
      printf "${GR}└────────────────────────────────────────────────────────┘${RS}\n\n" ;;
    2)
      crontab -l 2>/dev/null | grep -v "chaiya-cpu" | crontab -
      printf "\n${YE}┌──────────────────────────────────────┐${RS}\n"
      printf "${YE}│${RS}  ✅ ปิด CPU Guard สำเร็จ             ${YE}│${RS}\n"
      printf "${YE}└──────────────────────────────────────┘${RS}\n\n" ;;
    3)
      printf "\n${CY}┌─[ 📋 CPU Guard Log (20 บรรทัดล่าสุด) ]────────────────┐${RS}\n"
      if [[ -f /var/log/chaiya-cpu-guard.log && -s /var/log/chaiya-cpu-guard.log ]]; then
        tail -20 /var/log/chaiya-cpu-guard.log | while IFS= read -r line; do
          printf "${CY}│${RS}  ${OR}%.62s${RS}\n" "$line"
        done
        local log_size; log_size=$(wc -l < /var/log/chaiya-cpu-guard.log)
        printf "${CY}├────────────────────────────────────────────────────────┤${RS}\n"
        printf "${CY}│${RS}  ${WH}Log size: ${YE}%s${WH} บรรทัด${RS}                                ${CY}│${RS}\n" "$log_size"
      else
        printf "${CY}│${RS}  ${OR}ยังไม่มี Log — CPU Guard ยังไม่เคย kill process${RS}      ${CY}│${RS}\n"
      fi
      printf "${CY}└────────────────────────────────────────────────────────┘${RS}\n\n" ;;
  esac
  read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"
}

# ══════════════════════════════════════════════════════════════
# เมนู 18 — SSH WebSocket Manager (websocat + nginx + systemd)
# ══════════════════════════════════════════════════════════════

# ── helper: ติดตั้ง websocat binary ─────────────────────────
_m18_install_websocat() {
  if command -v websocat &>/dev/null; then
    printf "${GR}✅ websocat มีอยู่แล้ว: $(command -v websocat)${RS}\n"
    return 0
  fi
  printf "${OR}⏳ กำลังติดตั้ง websocat...${RS}\n"
  local ARCH; ARCH=$(uname -m)
  local URL
  case "$ARCH" in
    x86_64)  URL="https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl" ;;
    aarch64) URL="https://github.com/vi/websocat/releases/latest/download/websocat.aarch64-unknown-linux-musl" ;;
    armv7l)  URL="https://github.com/vi/websocat/releases/latest/download/websocat.arm-unknown-linux-musleabihf" ;;
    *)
      printf "${RD}❌ ไม่รองรับ architecture: %s${RS}\n" "$ARCH"
      return 1 ;;
  esac
  if wget -q --show-progress -O /usr/local/bin/websocat "$URL" 2>/dev/null; then
    chmod +x /usr/local/bin/websocat
    printf "${GR}✅ ติดตั้ง websocat สำเร็จ ($(websocat --version 2>/dev/null || echo 'OK'))${RS}\n"
    return 0
  else
    printf "${RD}❌ ดาวน์โหลด websocat ล้มเหลว กรุณาตรวจสอบ internet${RS}\n"
    return 1
  fi
}

# ── helper: สร้าง nginx WebSocket server block port 80 ──────
_m18_setup_nginx_ws() {
  # อ่าน port จาก config (ตั้งค่าในเมนู 2 หรือ default 80)
  local _wsport; _wsport=$(cat /etc/chaiya/wsport.conf 2>/dev/null || echo "2083")
  local _domain; _domain=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "")
  local _cert_ok=false
  [[ -n "$_domain" && -f "/etc/letsencrypt/live/${_domain}/fullchain.pem" ]] && _cert_ok=true

  printf "${YE}  → WS Port: ${WH}%s${RS} | ${YE}SSL: ${WH}%s${RS}\n" "$_wsport" "$($_cert_ok && echo 'YES (wss://)' || echo 'NO (ws://)')"

  # ลบ config เดิมที่อาจชนกัน
  rm -f /etc/nginx/sites-enabled/chaiya \
        /etc/nginx/sites-enabled/chaiya-ssl \
        /etc/nginx/sites-enabled/chaiya-sshws 2>/dev/null || true

  # UFW เปิด port
  ufw allow "$_wsport"/tcp 2>/dev/null || true

  if $_cert_ok; then
    # ── กรณีมี SSL cert: เมนู 2 จัดการ config แล้ว ──────────
    # เพิ่มแค่ upstream block ถ้ายังไม่มี แล้ว reload
    ln -sf /etc/nginx/sites-available/chaiya-ssl \
           /etc/nginx/sites-enabled/chaiya-ssl 2>/dev/null || true
    printf "${GR}  → ใช้ nginx config จากเมนู 2 (SSL) แล้ว reload${RS}\n"
  else
    # ── กรณีไม่มี SSL: สร้าง nginx dashboard port 81 เท่านั้น ──
    # port 80 สงวนไว้สำหรับ ws-stunnel (Python tunnel)
    # ลบ ws.conf เก่าที่อาจ listen 80 อยู่
    rm -f /etc/nginx/conf.d/ws.conf 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/chaiya-sshws 2>/dev/null || true

    cat > /etc/nginx/sites-available/chaiya-sshws << 'NGINXWS'
# Chaiya dashboard — port 81 เท่านั้น (port 80 = Python HTTP-CONNECT tunnel)
server {
    listen 81;
    server_name _;
    root /var/www/chaiya;

    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
        default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache";
    }
    location /sshws/ {
        alias /var/www/chaiya/;
        index sshws.html;
        try_files $uri $uri/ =404;
    }
    location /sshws-api/ {
        proxy_pass http://127.0.0.1:6789/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
    location / {
        return 200 'Chaiya Panel OK';
        add_header Content-Type text/plain;
    }
}
NGINXWS
    ln -sf /etc/nginx/sites-available/chaiya-sshws \
           /etc/nginx/sites-enabled/chaiya-sshws
  fi

  _ensure_nginx


  if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null \
      && printf "${GR}✅ nginx WebSocket block port ${_wsport} พร้อมแล้ว${RS}\n" \
      || systemctl restart nginx 2>/dev/null
  else
    printf "${RD}❌ nginx config error — ตรวจสอบ: nginx -t${RS}\n"
    nginx -t
  fi
}

# ── helper: สร้าง systemd service chaiya-sshws (Python HTTP-CONNECT) ──
_m18_setup_systemd() {
  # ตรวจสอบว่า ws-stunnel มีอยู่
  if [[ ! -f /usr/local/bin/ws-stunnel ]]; then
    printf "${RD}❌ ไม่พบ /usr/local/bin/ws-stunnel — รันสคริปต์ติดตั้งใหม่${RS}\n"
    return 1
  fi

  cat > /etc/systemd/system/chaiya-sshws.service << 'SVCEOF'
[Unit]
Description=Chaiya SSH HTTP-CONNECT Tunnel port 80 -> Dropbear
After=network.target dropbear.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-stunnel
Restart=always
RestartSec=3
StandardOutput=append:/var/log/chaiya-sshws.log
StandardError=append:/var/log/chaiya-sshws.log

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable chaiya-sshws 2>/dev/null
  systemctl restart chaiya-sshws 2>/dev/null

  # รอ port 80 ขึ้น (max 8 วินาที)
  local waited=0
  while ! ss -tlnp 2>/dev/null | grep -q ':80 ' && (( waited < 8 )); do
    sleep 1; (( waited++ )) || true
  done

  if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    printf "${GR}✅ chaiya-sshws ทำงานแล้ว — port 80 พร้อม${RS}\n"
  elif systemctl is-active --quiet chaiya-sshws; then
    printf "${YE}⚠️  service active แต่ port 80 ยังไม่ปรากฏ — รอสักครู่${RS}\n"
  else
    printf "${RD}❌ chaiya-sshws ยังไม่ active${RS}\n"
    printf "${OR}   ดู log: journalctl -u chaiya-sshws -n 20${RS}\n"
  fi

  # ── ตรวจและ restart dropbear ด้วย ──────────────────────────
  if systemctl is-enabled --quiet dropbear 2>/dev/null; then
    systemctl restart dropbear 2>/dev/null \
      && printf "${GR}✅ dropbear restart แล้ว${RS}\n" \
      || printf "${YE}⚠️  dropbear restart ล้มเหลว (อาจไม่ได้ติดตั้ง)${RS}\n"
  fi
}

# ── helper: สร้าง SSH user พร้อม expire + /bin/false shell ──
_m18_add_ssh_user() {
  local DB="/etc/chaiya/sshws-users/users.db"
  mkdir -p /etc/chaiya/sshws-users

  read -rp "$(printf "${YE}ชื่อ User: ${RS}")"    _u
  read -rsp "$(printf "${YE}Password : ${RS}")"   _p; echo ""
  read -rp "$(printf "${YE}วันหมดอายุ (วัน, default=30): ${RS}")" _d
  [[ -z "$_d" ]] && _d=30

  # ── IP Limit ──────────────────────────────────────────────────
  read -rp "$(printf "${YE}IP Limit (default=2): ${RS}")" _iplimit
  [[ -z "$_iplimit" ]] && _iplimit=2

  [[ -z "$_u" || -z "$_p" ]] && { printf "${RD}❌ ต้องกรอก user และ password${RS}\n"; return 1; }

  # ── เลือก Port ────────────────────────────────────────────────
  printf "\n${CY}┌─[ เลือก Port ]──────────────────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  ${GR}1.${RS}  Port ${WH}80${RS}  — WS HTTP  (ไม่มี SSL)               ${CY}│${RS}\n"
  printf "${CY}│${RS}  ${GR}2.${RS}  Port ${WH}443${RS} — WSS HTTPS (SSL self-signed) 🔒      ${CY}│${RS}\n"
  printf "${CY}└──────────────────────────────────────────────────────┘${RS}\n"
  read -rp "$(printf "${YE}เลือก [1-2, default=1]: ${RS}")" _port_choice
  local _ssh_port=80 _ssh_proto="ws" _ssh_path="/"
  case "${_port_choice:-1}" in
    2) _ssh_port=443; _ssh_proto="wss"; _ssh_path="/ssh/" ;;
    *) _ssh_port=80;  _ssh_proto="ws";  _ssh_path="/" ;;
  esac

  local _exp; _exp=$(date -d "+${_d} days" +%Y-%m-%d 2>/dev/null \
                  || date -v+${_d}d +%Y-%m-%d 2>/dev/null || echo "")
  [[ -z "$_exp" ]] && { printf "${RD}❌ คำนวณวันหมดอายุล้มเหลว${RS}\n"; return 1; }

  # ลบ user เก่าถ้ามี แล้วสร้างใหม่
  userdel -f "$_u" 2>/dev/null || true
  if useradd -M -s /bin/false -e "$_exp" "$_u" 2>/dev/null; then
    echo "${_u}:${_p}" | chpasswd 2>/dev/null
    chage -E "$_exp" "$_u" 2>/dev/null || true
    # บันทึกลง DB
    sed -i "/^${_u} /d" "$DB" 2>/dev/null || true
    echo "$_u $_d $_exp 0 $_iplimit" >> "$DB"

    printf "\n${GR}┌──────────────────────────────────────────────┐${RS}\n"
    printf "${GR}│${RS}  ✅ สร้าง SSH User สำเร็จ!                    ${GR}│${RS}\n"
    printf "${GR}│${RS}  ${YE}User   : ${WH}%-34s${GR}│${RS}\n" "$_u"
    printf "${GR}│${RS}  ${YE}Expire : ${WH}%-34s${GR}│${RS}\n" "$_exp"
    printf "${GR}│${RS}  ${YE}Port   : ${WH}%-34s${GR}│${RS}\n" "$_ssh_port"
    printf "${GR}│${RS}  ${YE}Shell  : ${WH}/bin/false (tunnel only)         ${GR}│${RS}\n"
    printf "${GR}└──────────────────────────────────────────────┘${RS}\n"

    # ── สร้าง HTML เฉพาะเมื่อเลือก port 443 ─────────────────────
    if [[ "$_ssh_port" == "443" ]]; then
      local _host; _host=$(cat /etc/chaiya/domain.conf 2>/dev/null | tr -d '[:space:]')
      [[ -z "$_host" ]] && _host=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '"'"'{print $1}'"'"')
      local _outfile="/var/www/chaiya/config/ssh-${_u}.html"
      mkdir -p /var/www/chaiya/config

      python3 << PYEOF2
import os
u       = """$_u"""
pw      = """$_p"""
ex      = """$_exp"""
host    = """$_host"""
iplimit = """$_iplimit"""
outfile = """$_outfile"""

tok = ""
tok_f = "/etc/chaiya/sshws-token.conf"
if os.path.exists(tok_f):
    tok = open(tok_f).read().strip()

copy_text = f"""Host/IP   : {host}
Port      : 443
Username  : {u}
Password  : {pw}
Expire    : {ex}
IP Limit  : {iplimit}
Path      : /ssh/
Protocol  : SSH-WS-SSL (TLS)"""

html = """<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA VPN — """ + u + """ (SSH-WS-SSL)</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d0d0d;font-family:'Segoe UI',sans-serif;min-height:100vh;
     display:flex;align-items:center;justify-content:center;padding:20px}
.wrap{width:100%;max-width:420px}
@keyframes rgbTxt{
  0%{color:#ff0080}16%{color:#ff8000}33%{color:#ffee00}
  50%{color:#00ff80}66%{color:#00d4ff}83%{color:#b400ff}100%{color:#ff0080}}
@keyframes rgbLine{
  0%{background:linear-gradient(90deg,#ff0080,#ff8000)}
  25%{background:linear-gradient(90deg,#ffee00,#00ff80)}
  50%{background:linear-gradient(90deg,#00d4ff,#b400ff)}
  75%{background:linear-gradient(90deg,#ff0080,#ff8000)}
  100%{background:linear-gradient(90deg,#ffee00,#00ff80)}}
@keyframes rgbBorder{
  0%{border-color:#ff0080}16%{border-color:#ff8000}33%{border-color:#ffee00}
  50%{border-color:#00ff80}66%{border-color:#00d4ff}83%{border-color:#b400ff}100%{border-color:#ff0080}}
@keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.2)}}
@keyframes rgbBreath{
  0%{background:rgba(255,0,128,0.4);box-shadow:0 0 8px rgba(255,0,128,0.3)}
  50%{background:rgba(0,255,128,0.7);box-shadow:0 0 16px rgba(0,255,128,0.6)}
  100%{background:rgba(255,0,128,0.4);box-shadow:0 0 8px rgba(255,0,128,0.3)}}
@keyframes rgbBreathBorder{
  0%{border-color:rgba(255,0,128,0.6)}50%{border-color:rgba(0,255,128,1)}
  100%{border-color:rgba(255,0,128,0.6)}}
.header{text-align:center;padding:22px 0 12px}
.fire{font-size:34px;display:inline-block;animation:pulse 1.8s ease-in-out infinite}
.title{font-size:22px;font-weight:800;letter-spacing:6px;margin-top:4px;animation:rgbTxt 3s linear infinite}
.subtitle{margin-top:4px;font-size:11px;color:#5a8aaa;letter-spacing:2px}
.username{margin-top:6px;font-size:14px;color:#5a8aaa}
.username span{color:#00cfff;font-weight:600}
.line{height:2px;border-radius:2px;margin:10px 0 16px;animation:rgbLine 3s linear infinite}
.row{display:flex;align-items:center;justify-content:space-between;
     padding:11px 4px;border-bottom:1px solid #1a1a2a}
.row:last-of-type{border-bottom:none}
.row-left{display:flex;align-items:center;gap:10px}
.ico{font-size:18px}
.lbl{font-size:13px;font-weight:500;letter-spacing:1px;animation:rgbTxt 3s linear infinite}
.row-right{font-size:13px;color:#c0d0e0;text-align:right;word-break:break-all}
.row-right.pass{font-family:monospace;letter-spacing:2px;color:#00ff80}
.ssl-badge{display:inline-block;background:#00ff8022;border:1px solid #00ff8066;
           color:#00ff80;font-size:10px;padding:2px 8px;border-radius:99px;margin-left:6px}
.btn-copy{width:100%;padding:15px;border:2px solid rgba(255,0,128,0.8);
          border-radius:12px;font-size:15px;font-weight:700;letter-spacing:1px;
          cursor:pointer;color:#fff;margin-top:16px;
          animation:rgbBreath 4s ease-in-out infinite,rgbBreathBorder 4s ease-in-out infinite;
          transition:transform .1s,opacity .1s}
.btn-copy:active{transform:scale(.97);opacity:.85}
.notice{margin-top:14px;padding:10px 14px;border-radius:10px;
        background:#001a00;border:1px solid #00ff4066;
        font-size:12px;color:#00cc66;line-height:1.6;text-align:center}
.notice b{color:#00ff80}
.toast{position:fixed;bottom:32px;left:50%;transform:translateX(-50%);
       background:#00ff80;color:#000;padding:11px 28px;border-radius:22px;
       font-weight:700;font-size:13px;opacity:0;transition:opacity .3s;
       pointer-events:none;z-index:999}
.toast.show{opacity:1}
</style>
</head>
<body>
<div class="wrap">
  <div class="header">
    <div class="fire">🔥</div>
    <div class="title">CHAIYA VPN</div>
    <div class="subtitle">SSH · WS · SSL</div>
    <div class="username">👤 <span>""" + u + """</span></div>
  </div>
  <div class="line"></div>

  <div class="row">
    <div class="row-left"><span class="ico">🌐</span><span class="lbl">Host/IP</span></div>
    <div class="row-right">""" + host + """</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">🔌</span><span class="lbl">Port</span></div>
    <div class="row-right">443 <span class="ssl-badge">🔒 SSL</span></div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">👤</span><span class="lbl">Username</span></div>
    <div class="row-right">""" + u + """</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">🔑</span><span class="lbl">Password</span></div>
    <div class="row-right pass">""" + pw + """</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">📅</span><span class="lbl">หมดอายุ</span></div>
    <div class="row-right">""" + ex + """</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">📱</span><span class="lbl">IP Limit</span></div>
    <div class="row-right">""" + iplimit + """ IP</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">📡</span><span class="lbl">Protocol</span></div>
    <div class="row-right">SSH · WS · SSL</div>
  </div>
  <div class="row">
    <div class="row-left"><span class="ico">📂</span><span class="lbl">Path</span></div>
    <div class="row-right">/ssh/</div>
  </div>

  <button class="btn-copy" onclick="copyAll()">📋&nbsp; Copy ข้อมูลทั้งหมด</button>

  <div class="notice">
    🔒 <b>SSL Self-Signed</b> — ใช้งานได้ปกติ<br>
    ตั้งค่าแอพ: TLS=เปิด · Skip Verify=เปิด · Path=/ssh/
  </div>
</div>
<div class="toast" id="toast">✔ Copied!</div>
<script>
var _copyText = """ + repr(copy_text) + """;
function copyAll(){
  if(navigator.clipboard){
    navigator.clipboard.writeText(_copyText).then(showToast).catch(fb);
  } else { fb(); }
}
function fb(){
  var ta=document.createElement('textarea');
  ta.value=_copyText;document.body.appendChild(ta);
  ta.select();document.execCommand('copy');
  document.body.removeChild(ta);showToast();
}
function showToast(){
  var el=document.getElementById('toast');
  el.classList.add('show');
  setTimeout(function(){el.classList.remove('show');},2000);
}
</script>
</body></html>"""

os.makedirs(os.path.dirname(outfile), exist_ok=True)
with open(outfile, 'w', encoding='utf-8') as f:
    f.write(html)
print("OK:" + outfile)
PYEOF2

      if [[ $? -eq 0 ]]; then
        local _cfg_host; _cfg_host=$(cat /etc/chaiya/domain.conf 2>/dev/null | tr -d '[:space:]')
        [[ -z "$_cfg_host" ]] && _cfg_host=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
        printf "${CY}│${RS}  ${GR}🌐 HTML Config:${RS}
"
        printf "${CY}│${RS}  ${WH}http://%s:81/config/ssh-%s.html${RS}\n" "$_cfg_host" "$_u"
      fi
    fi
  else
    printf "${RD}❌ useradd ล้มเหลว${RS}\n"; return 1
  fi
}

# ── helper: แสดง config สำหรับแอพ ────────────────────────────
_m18_show_appconfig() {
  local _h; [[ -f "$DOMAIN_FILE" ]] && _h=$(cat "$DOMAIN_FILE") || _h=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  local _wsport; _wsport=$(cat /etc/chaiya/wsport.conf 2>/dev/null || echo "2083")
  local _proto="ws"
  [[ -f "/etc/letsencrypt/live/${_h}/fullchain.pem" ]] && _proto="wss"

  printf "\n${CY}╔══════════════════════════════════════════════════════╗${RS}\n"
  printf "${CY}║${RS}  📱 ${WH}Config สำหรับแอพ SSH WebSocket${RS}                 ${CY}║${RS}\n"
  printf "${CY}╠══════════════════════════════════════════════════════╣${RS}\n"
  printf "${CY}║${RS}  ${YE}Host    ${WH}: %-38s${CY}║${RS}\n" "$_h"
  printf "${CY}║${RS}  ${YE}Port    ${WH}: %-38s${CY}║${RS}\n" "$_wsport"
  printf "${CY}║${RS}  ${YE}Mode    ${WH}: %-38s${CY}║${RS}\n" "WebSocket (${_proto^^})"
  printf "${CY}║${RS}  ${YE}Path    ${WH}: /                                        ${CY}║${RS}\n"
  printf "${CY}╠══════════════════════════════════════════════════════╣${RS}\n"
  printf "${CY}║${RS}  ${OR}── Payload Templates ────────────────────────────${CY}║${RS}\n"
  printf "${CY}║${RS}  ${WH}HTTP Injector / NetMod:${RS}                          ${CY}║${RS}\n"
  printf "${CY}║${RS}    ${GR}GET / HTTP/1.1[crlf]${RS}                           ${CY}║${RS}\n"
  printf "${CY}║${RS}    ${GR}Host: %s[crlf]${RS}                      ${CY}║${RS}\n" "$_h"
  printf "${CY}║${RS}    ${GR}Upgrade: websocket[crlf][crlf]${RS}                 ${CY}║${RS}\n"
  printf "${CY}╠══════════════════════════════════════════════════════╣${RS}\n"
  printf "${CY}║${RS}  ${WH}NapsternetV / KPN Tunnel:${RS}                        ${CY}║${RS}\n"
  printf "${CY}║${RS}    ${GR}%s://%s:%s/  → SSH${RS}\n" "$_proto" "$_h" "$_wsport"
  printf "${CY}╠══════════════════════════════════════════════════════╣${RS}\n"
  printf "${CY}║${RS}  ${YE}UDPGW   ${WH}: 127.0.0.1:7300 (game/UDP)              ${CY}║${RS}\n"
  printf "${CY}║${RS}  ${YE}SSL     ${WH}: %-38s${CY}║${RS}\n" "$([[ "$_proto" == "wss" ]] && echo "✅ เปิด (wss://)" || echo "❌ ปิด (ws://) — ใช้เมนู 2")"
  printf "${CY}╚══════════════════════════════════════════════════════╝${RS}\n\n"
}

# ── helper: แสดงสถานะ service ────────────────────────────────
_m18_status() {
  local WS_ST DB_ST UDPGW_ST NGINX_ST
  WS_ST=$(systemctl is-active chaiya-sshws 2>/dev/null || echo "inactive")
  DB_ST=$(systemctl is-active dropbear 2>/dev/null || echo "inactive")
  UDPGW_ST=$(pgrep -f badvpn-udpgw &>/dev/null && echo "active" || echo "inactive")
  NGINX_ST=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
  local CONNS; CONNS=$(ss -tn state established 2>/dev/null | grep -cE ':80 |:22 |:143 |:109 ' || echo "0")
  local STARTED; STARTED=$(systemctl show chaiya-sshws --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2 || echo "N/A")

  _sc() { [[ "$1" == "active" ]] && printf "${GR}✅ RUNNING${RS}" || printf "${RD}❌ STOPPED${RS}"; }

  printf "\n${R1}╔══════════════════════════════════════════════════════════╗${RS}\n"
  printf "${R1}║${RS}  🚇 chaiya-sshws : $(_sc "$WS_ST")                            ${R1}║${RS}\n"
  printf "${R1}║${RS}  🌐 nginx        : $(_sc "$NGINX_ST")                            ${R1}║${RS}\n"
  printf "${R1}║${RS}  🐻 dropbear     : $(_sc "$DB_ST")                            ${R1}║${RS}\n"
  printf "${R1}║${RS}  🎮 badvpn-udpgw : $(_sc "$UDPGW_ST")                            ${R1}║${RS}\n"
  printf "${R1}╠══════════════════════════════════════════════════════════╣${RS}\n"
  printf "${R1}║${RS}  👥 Active connections: ${YE}%s${RS} (port 80/22/143/109)            ${R1}║${RS}\n" "$CONNS"
  printf "${R1}║${RS}  ⏱  Service started  : ${WH}%s${RS}\n" "$STARTED"
  printf "${R1}╚══════════════════════════════════════════════════════════╝${RS}\n"
}

# ── helper: แสดง user list ───────────────────────────────────
_m18_list_users() {
  local DB="/etc/chaiya/sshws-users/users.db"
  printf "\n${CY}┌─[ 👥 SSH WebSocket Users ]──────────────────────────────┐${RS}\n"
  printf "${CY}│${RS}  ${YE}%-16s %-12s %-12s %-8s${RS} ${CY}│${RS}\n" "Username" "Expire" "สถานะ" "Shell"
  printf "${CY}├─────────────────────────────────────────────────────────┤${RS}\n"
  if [[ -f "$DB" && -s "$DB" ]]; then
    local n=0
    while read -r _u _d _exp _rest; do
      [[ -z "$_u" ]] && continue
      local _active="❌ ไม่มี"
      id "$_u" &>/dev/null && _active="${GR}✅ มี${RS}" || _active="${RD}❌ ไม่มี${RS}"
      local _sh; _sh=$(getent passwd "$_u" 2>/dev/null | cut -d: -f7 || echo "N/A")
      local _exp_color="$GR"
      if [[ -n "$_exp" ]]; then
        local _today; _today=$(date +%Y-%m-%d)
        [[ "$_exp" < "$_today" ]] && _exp_color="$RD"
      fi
      printf "${CY}│${RS}  ${WH}%-16s${RS} ${_exp_color}%-12s${RS} %s        ${WH}%-8s${RS} ${CY}│${RS}\n" \
        "$_u" "${_exp:-N/A}" "$_active" "$_sh"
      (( n++ )) || true
    done < "$DB"
    printf "${CY}├─────────────────────────────────────────────────────────┤${RS}\n"
    printf "${CY}│${RS}  รวม: ${YE}%d${WH} บัญชี${RS}                                          ${CY}│${RS}\n" "$n"
  else
    printf "${CY}│${RS}  ${OR}ยังไม่มี SSH user — เพิ่มผ่านข้อ 4${RS}                  ${CY}│${RS}\n"
  fi
  printf "${CY}└─────────────────────────────────────────────────────────┘${RS}\n\n"
}

# ── helper: ลบ SSH user ──────────────────────────────────────
_m18_del_ssh_user() {
  local DB="/etc/chaiya/sshws-users/users.db"
  _m18_list_users
  read -rp "$(printf "${YE}ชื่อ User ที่จะลบ (Enter = ยกเลิก): ${RS}")" _du
  [[ -z "$_du" ]] && { printf "${YE}↩ ยกเลิก${RS}\n"; return; }
  printf "${OR}⚠️  ยืนยันลบ ${WH}%s${OR}? (y/N): ${RS}" "$_du"
  read -r _cf
  if [[ "$_cf" == "y" || "$_cf" == "Y" ]]; then
    pkill -u "$_du" -9 2>/dev/null || true
    userdel -f "$_du" 2>/dev/null || true
    sed -i "/^${_du} /d" "$DB" 2>/dev/null || true
    printf "${GR}✅ ลบ User %s สำเร็จ${RS}\n" "$_du"
  else
    printf "${YE}↩ ยกเลิก${RS}\n"
  fi
}

# ── Main menu_18 ─────────────────────────────────────────────
menu_18() {
  clear
  # ── ดึง IP จริงของเครื่องนี้ ──────────────────────────────
  local _MY_IP; _MY_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null     || curl -s --max-time 5 api.ipify.org 2>/dev/null     || hostname -I | awk '{print $1}')

  # ── ตรวจสอบโดเมน: ใช้เฉพาะถ้า resolve ได้และ cert มีจริง ──
  local _H="$_MY_IP"
  if [[ -f "$DOMAIN_FILE" ]]; then
    local _dom; _dom=$(cat "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$_dom" ]]; then
      # ตรวจว่า domain resolve ได้จริงบนเครื่องนี้
      local _dom_ip; _dom_ip=$(getent hosts "$_dom" 2>/dev/null | awk '{print $1}' | head -1)
      if [[ -n "$_dom_ip" ]]; then
        _H="$_dom"
      else
        # domain resolve ไม่ได้ — ใช้ IP แทน ไม่อ่าน domain ผิด
        _H="$_MY_IP"
      fi
    fi
  fi

  local _TOK; _TOK=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')
  [[ -z "$_TOK" ]] && { _TOK=$(openssl rand -hex 16); echo "$_TOK" > /etc/chaiya/sshws-token.conf; }
  local _CERT_OK=false
  [[ -f "/etc/letsencrypt/live/${_H}/fullchain.pem" ]] && _CERT_OK=true
  local _PROTO; $_CERT_OK && _PROTO="wss" || _PROTO="ws"
  local _WSPORT; _WSPORT=$(cat /etc/chaiya/wsport.conf 2>/dev/null || echo "80")
  local _WSST; _WSST=$(systemctl is-active chaiya-sshws 2>/dev/null || echo "inactive")
  local _DBST;  _DBST=$(systemctl is-active dropbear    2>/dev/null || echo "inactive")
  local _NGST;  _NGST=$(systemctl is-active nginx       2>/dev/null || echo "inactive")
  local _UDPST; pgrep -f badvpn-udpgw &>/dev/null && _UDPST="active" || _UDPST="inactive"
  _sc18() { [[ "$1" == "active" ]] && printf "${GR}● RUNNING${RS}" || printf "${RD}○ STOPPED${RS}"; }

  # ── สร้าง URL สำหรับ Web Dashboard ──────────────────────────
  local _DASH_URL="http://${_H}:81/sshws/sshws.html"
  local _DASH_URL_TOK="http://${_H}:81/sshws/sshws.html?token=${_TOK}"
  $_CERT_OK && _DASH_URL="https://${_H}/sshws/sshws.html"     || true
  $_CERT_OK && _DASH_URL_TOK="https://${_H}/sshws/sshws.html?token=${_TOK}" || true

  # ── แสดงหน้าหลัก menu_18 ─────────────────────────────────────
  _show_menu18_main() {
    clear
    printf "\n${R1}╔══════════════════════════════════════════════════════════╗${RS}\n"
    printf "${R1}║${RS}  🚇 ${WH}SSH WebSocket Manager${RS}  ${R1}[เมนู 18]${RS}                  ${R1}║${RS}\n"
    printf "${R1}╠══════════════════════════════════════════════════════════╣${RS}\n"
    printf "${R1}║${RS}  ${YE}Host  ${WH}: %-49s${R1}║${RS}\n" "$_H"
    printf "${R1}║${RS}  ${YE}Port  ${WH}: %-10s  ${YE}Proto ${WH}: %-30s${R1}║${RS}\n" "$_WSPORT" "${_PROTO^^}"
    printf "${R1}╠══════════════════════════════════════════════════════════╣${RS}\n"
    printf "${R1}║${RS}  🌐 ${YE}Web Dashboard (เปิดในมือถือ/เบราว์เซอร์):${RS}          ${R1}║${RS}\n"
    printf "${R1}║${RS}  ${CY}  %-56s${R1}║${RS}\n" "$_DASH_URL"
    printf "${R1}║${RS}  ${GR}  (พร้อม Token):${RS}                                      ${R1}║${RS}\n"
    printf "${R1}║${RS}  ${MG}  %-56s${R1}║${RS}\n" "$_DASH_URL_TOK"
    printf "${R1}╠══════════════════════════════════════════════════════════╣${RS}\n"
    printf "${R1}║${RS}  🚇 chaiya-sshws : $(_sc18 "$_WSST")    🐻 dropbear : $(_sc18 "$_DBST")        ${R1}║${RS}\n"
    printf "${R1}║${RS}  🌐 nginx        : $(_sc18 "$_NGST")    🎮 badvpn   : $(_sc18 "$_UDPST")        ${R1}║${RS}\n"
    printf "${R1}╠══════════════════════════════════════════════════════════╣${RS}\n"
    printf "${R1}║${RS}  ${MG} 9.${RS}  🔑  เปลี่ยน Token ใหม่                          ${R1}║${RS}\n"
    printf "${R1}║${RS}  ${WH}99.${RS}  🔧  ซ่อมบำรุง / แอดมิน  ${RD}[ต้องใส่รหัส]${RS}         ${R1}║${RS}\n"
    printf "${R1}║${RS}  ${WH} 0.${RS}  ↩  ย้อนกลับ                                      ${R1}║${RS}\n"
    printf "${R1}╚══════════════════════════════════════════════════════════╝${RS}\n"
  }

  _show_menu18_main
  read -rp "$(printf "\n${YE}เลือก: ${RS}")" _sub18

  case $_sub18 in

    1)
      # ── Restart ทุก service (admin only) ─────────────────────
      menu_18 ;;

    2) menu_18 ;;
    3) menu_18 ;;
    4) menu_18 ;;
    5) menu_18 ;;
    6) menu_18 ;;
    7) menu_18 ;;
    8) menu_18 ;;

    9)
      # ── เปลี่ยน Token ใหม่ ────────────────────────────────────
      local _NEWTOK; _NEWTOK=$(openssl rand -hex 16)
      echo "$_NEWTOK" > /etc/chaiya/sshws-token.conf
      # ฝัง token ใหม่เข้า HTML ทันที
      python3 << PYEOF 2>/dev/null || true
import re
path='/var/www/chaiya/sshws.html'
tok='${_NEWTOK}'
try:
  with open(path,'r',errors='replace') as f: h=f.read()
  h2=re.sub(r"(const _baked\s*=\s*')[^']*(')",r"\g<1>"+tok+r"\g<2>",h)
  with open(path,'w') as f: f.write(h2)
except: pass
PYEOF
      # reopen nginx เพื่อให้ token ใหม่ใช้งานได้ทันที
      _TOK="$_NEWTOK"
      local _NEW_URL_TOK
      $_CERT_OK && _NEW_URL_TOK="https://${_H}/sshws/sshws.html?token=${_NEWTOK}"                || _NEW_URL_TOK="http://${_H}:81/sshws/sshws.html?token=${_NEWTOK}"
      clear
      printf "\n${GR}╔══════════════════════════════════════════════════════════╗${RS}\n"
      printf "${GR}║${RS}  🔑 ${WH}เปลี่ยน Token ใหม่สำเร็จ!${RS}                          ${GR}║${RS}\n"
      printf "${GR}╠══════════════════════════════════════════════════════════╣${RS}\n"
      printf "${GR}║${RS}  ${YE}Token ใหม่:${RS}                                           ${GR}║${RS}\n"
      printf "${GR}║${RS}  ${CY}  %-56s${GR}║${RS}\n" "$_NEWTOK"
      printf "${GR}╠══════════════════════════════════════════════════════════╣${RS}\n"
      printf "${GR}║${RS}  ${YE}URL พร้อม Token (ใช้งานได้ทันที):${RS}                    ${GR}║${RS}\n"
      printf "${GR}║${RS}  ${MG}  %-56s${GR}║${RS}\n" "$_NEW_URL_TOK"
      printf "${GR}╚══════════════════════════════════════════════════════════╝${RS}\n\n"
      printf "${WH}💡 คัดลอก URL ด้านบนแล้วเปิดในเบราว์เซอร์ได้เลย${RS}\n\n"
      read -rp "$(printf "${YE}Enter ย้อนกลับ...${RS}")"; menu_18 ;;

    10) menu_18 ;;

    11) menu_18 ;;

    99)
      # ── ซ่อมบำรุง / แอดมิน (ต้องใส่รหัส) ────────────────────
      clear
      printf "\n${R1}╔══════════════════════════════════════════════════════════╗${RS}\n"
      printf "${R1}║${RS}  🔧 ${WH}ซ่อมบำรุง / แอดมิน${RS}                                ${R1}║${RS}\n"
      printf "${R1}╚══════════════════════════════════════════════════════════╝${RS}\n\n"
      read -rsp "$(printf "${YE}🔐 รหัสผ่าน: ${RS}")" _adm_pass
      printf "\n"
      if [[ "$_adm_pass" != "Chaiya" ]]; then
        printf "${RD}❌ รหัสผ่านไม่ถูกต้อง${RS}\n\n"
        sleep 1; menu_18; return
      fi
      # ── แสดงเมนูแอดมินเต็ม ────────────────────────────────────
      while true; do
        clear
        printf "\n${MG}╔══════════════════════════════════════════════════════════╗${RS}\n"
        printf "${MG}║${RS}  🔧 ${WH}ซ่อมบำรุง / แอดมิน${RS}  ${YE}[รหัสผ่านถูกต้อง ✅]${RS}         ${MG}║${RS}\n"
        printf "${MG}╠══════════════════════════════════════════════════════════╣${RS}\n"
        printf "${MG}║${RS}  ${GR} 1.${RS}  ▶  เริ่ม / Restart Services ทั้งหมด              ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${RD} 2.${RS}  ■  หยุด SSH WebSocket (chaiya-sshws)             ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${YE} 3.${RS}  👁  ดูสถานะ + Connections ละเอียด               ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${CY} 4.${RS}  ➕  เพิ่ม SSH User                               ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${CY} 5.${RS}  📋  ดูรายชื่อ SSH Users ทั้งหมด                 ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${RD} 6.${RS}  🗑️   ลบ SSH User                                 ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${PU} 7.${RS}  📱  ดู Config สำหรับแอพ                          ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${OR} 8.${RS}  📋  ดู Log (30 บรรทัดล่าสุด)                    ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${WH}10.${RS}  🔄  ติดตั้ง / ซ่อมแซม ws-stunnel + nginx        ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${CY}11.${RS}  🌐  แสดงลิงค์เข้า Web Dashboard                 ${MG}║${RS}\n"
        printf "${MG}║${RS}  ${WH} 0.${RS}  ↩  ออกจากโหมดแอดมิน                             ${MG}║${RS}\n"
        printf "${MG}╚══════════════════════════════════════════════════════════╝${RS}\n"
        read -rp "$(printf "\n${YE}เลือก: ${RS}")" _adm_opt
        case $_adm_opt in
          1)
            clear
            printf "${GR}⏳ กำลัง restart...${RS}\n\n"
            for _svc in dropbear chaiya-sshws nginx chaiya-badvpn; do
              systemctl restart "$_svc" 2>/dev/null                 && printf "  ${GR}✅ %-22s OK${RS}\n" "$_svc"                 || printf "  ${RD}❌ %-22s fail${RS}\n" "$_svc"
            done
            sleep 2
            ss -tlnp 2>/dev/null | grep -q ':80 '               && printf "\n  ${GR}✅ Port 80 OK${RS}\n"               || printf "\n  ${RD}⚠️  Port 80 ยังไม่ขึ้น${RS}\n"
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          2)
            printf "\n${OR}ยืนยันหยุด chaiya-sshws? (y/N): ${RS}"
            read -r _c2
            [[ "$_c2" == "y" || "$_c2" == "Y" ]]               && systemctl stop chaiya-sshws 2>/dev/null && printf "${GR}✅ หยุดแล้ว${RS}\n"               || printf "${YE}↩ ยกเลิก${RS}\n"
            sleep 1 ;;
          3)
            clear
            _m18_status
            local _c80; _c80=$(ss -tn state established 2>/dev/null | grep -c ':80 ' || echo 0)
            local _c143; _c143=$(ss -tn state established 2>/dev/null | grep -c ':143 ' || echo 0)
            printf "\n${CY}Port 80: ${YE}$_c80${RS}  ${CY}Port 143: ${YE}$_c143${RS}\n\n"
            systemctl status chaiya-sshws --no-pager -n 5 2>/dev/null || true
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          4)
            clear; _m18_add_ssh_user
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          5)
            clear; _m18_list_users
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          6)
            clear; _m18_del_ssh_user
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          7)
            clear; _m18_show_appconfig
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          8)
            clear
            local _lf="/var/log/chaiya-sshws.log"
            [[ -f "$_lf" ]] && tail -30 "$_lf" || journalctl -u chaiya-sshws -n 30 --no-pager 2>/dev/null || true
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          10)
            clear
            printf "${OR}⚠️  จะ restart nginx + chaiya-sshws ยืนยัน? (y/N): ${RS}"
            read -r _c10
            if [[ "$_c10" == "y" || "$_c10" == "Y" ]]; then
              [[ -f /usr/local/bin/ws-stunnel ]] && _m18_setup_systemd && _m18_setup_nginx_ws                 || printf "${RD}❌ ไม่พบ ws-stunnel${RS}\n"
            fi
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          11)
            clear
            printf "${CY}URL: ${WH}$_DASH_URL${RS}\n"
            printf "${MG}Token URL: ${WH}$_DASH_URL_TOK${RS}\n\n"
            read -rp "$(printf "${YE}Enter...${RS}")" ;;
          0) break ;;
          *) ;;
        esac
      done
      menu_18 ;;

    0) return ;;
    *) menu_18 ;;
  esac
}

# ══════════════════════════════════════════════════════════════
# Main Loop
# ══════════════════════════════════════════════════════════════

# ── ตรวจ License ก่อนเริ่ม ──────────────────────────────────
check_license

# ── นับรอบสำหรับ recheck license ทุก 6 ชั่วโมง ──────────────
_LIC_LAST_CHECK=$(date +%s)

while true; do
  # recheck license ทุก 6 ชั่วโมง (21600 วินาที)
  _NOW=$(date +%s)
  if (( _NOW - _LIC_LAST_CHECK > 21600 )); then
    check_license
    _LIC_LAST_CHECK=$_NOW
  fi
  show_menu
  read -r opt
  case $opt in
    1)  menu_1  ;;
    2)  menu_2  ;;
    3)  menu_3  ;;
    4)  menu_4  ;;
    5)  menu_5  ;;
    6)  menu_6  ;;
    7)  menu_7  ;;
    8)  menu_8  ;;
    9)  menu_9  ;;
    10) menu_10 ;;
    11) menu_11 ;;
    12) menu_12 ;;
    13) menu_13 ;;
    14) menu_14 ;;
    15) menu_15 ;;
    16) menu_16 ;;
    17) menu_17 ;;
    18) menu_18 ;;
    0)  clear; exit 0 ;;
  esac
done
CHAIYAEOF
chmod +x /usr/local/bin/menu

# ══════════════════════════════════════════════════════════════
#  Auto-launch: เปิดเมนู chaiya ทุกครั้งที่ root login
# ══════════════════════════════════════════════════════════════
BASHRC_BLOCK='
# ── CHAIYA menu alias ─────────────────────────────────────────
alias menu="/usr/local/bin/menu"'

# เขียนลง /root/.bashrc (ถ้ายังไม่มี)
if ! grep -q "CHAIYA menu alias" /root/.bashrc 2>/dev/null; then
  echo "$BASHRC_BLOCK" >> /root/.bashrc
  echo "✅ ตั้ง alias menu สำเร็จ"
fi

# ── สรุปผลการติดตั้ง ─────────────────────────────────────────


# ======================================================================
#  [FIX] DASHBOARD SELF-HEALING — รันหลัง install เพื่อให้แน่ใจ 100%
# ======================================================================

echo -e "\n\033[1;36m[FIX] กำลังตรวจสอบและซ่อม Dashboard...\033[0m"

# 1. สร้าง token ถ้าว่าง
_FIX_TOK=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')
if [[ -z "$_FIX_TOK" ]]; then
  _FIX_TOK=$(openssl rand -hex 16)
  echo "$_FIX_TOK" > /etc/chaiya/sshws-token.conf
  echo "  ✅ สร้าง token ใหม่: $_FIX_TOK"
fi

# 2. ฝัง token เข้า HTML
_FIX_HTML="/var/www/chaiya/sshws.html"
if [[ -f "$_FIX_HTML" ]]; then
  sed -i "s|%%BAKED_TOKEN%%|${_FIX_TOK}|g" "$_FIX_HTML" 2>/dev/null || true
  sed -i "s|%%TOKEN%%|${_FIX_TOK}|g"       "$_FIX_HTML" 2>/dev/null || true
  python3 << PYREPLACE
import re
path, tok = "$_FIX_HTML", "$_FIX_TOK"
with open(path, 'r', errors='replace') as f: html = f.read()
html2 = re.sub(r"(const _baked\s*=\s*')[^']*(')", r"\g<1>" + tok + r"\g<2>", html)
if html2 != html:
    with open(path, 'w') as f: f.write(html2)
    print("  ✅ _baked token อัพเดตแล้ว: " + tok[:8] + "...")
else:
    print("  ✅ Token ใน HTML ถูกต้อง")
PYREPLACE
fi

# 3. สร้าง users.db ถ้าไม่มี
mkdir -p /etc/chaiya/sshws-users
[[ ! -f /etc/chaiya/sshws-users/users.db ]] && touch /etc/chaiya/sshws-users/users.db && echo "  ✅ สร้าง users.db"

# 4. ตรวจ chaiya-sshws-api — ถ้าไม่รันให้ start ใหม่
_fix_api_up=0
for _try in 1 2 3; do
  if ss -tlnp 2>/dev/null | grep -q ":6789 "; then
    _fix_api_up=1; break
  fi
  systemctl start chaiya-sshws-api 2>/dev/null || true
  sleep 2
done
if [[ $_fix_api_up -eq 0 ]]; then
  pkill -f chaiya-sshws-api 2>/dev/null || true
  sleep 1
  nohup python3 /usr/local/bin/chaiya-sshws-api >> /var/log/chaiya-sshws-api.log 2>&1 &
  sleep 3
  ss -tlnp 2>/dev/null | grep -q ":6789 " \
    && echo "  ✅ chaiya-sshws-api start สำเร็จ" \
    || echo "  ❌ start ไม่สำเร็จ — ดู: cat /var/log/chaiya-sshws-api.log"
else
  echo "  ✅ chaiya-sshws-api ทำงานอยู่บน port 6789"
fi

# 5. ตรวจ nginx config — ถ้าขาด sshws-api block ให้เขียนใหม่ (ใช้ config เดียวกับชุดแรก — headers ครบ)
if ! grep -q "sshws-api" /etc/nginx/sites-available/chaiya 2>/dev/null; then
  echo "  ⚠ nginx config ขาด sshws-api — เขียนใหม่"
  cat > /etc/nginx/sites-available/chaiya << 'NGINXEOF'
# ── Port 81: Web Panel (Dashboard + config download)
server {
    listen 81;
    server_name _;
    root /var/www/chaiya;
    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
        default_type text/html;
        add_header Content-Type "text/html; charset=UTF-8";
        add_header Cache-Control "no-cache";
    }
    location /sshws/ {
        alias /var/www/chaiya/;
        index sshws.html;
        try_files $uri $uri/ =404;
    }
    location /sshws-api/ {
        proxy_pass http://127.0.0.1:6789/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Token $http_x_token;
        proxy_set_header X-Auth-Token $http_x_auth_token;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
        add_header Access-Control-Allow-Origin "$http_origin" always;
        add_header Access-Control-Allow-Methods "GET,POST,DELETE,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization,Content-Type,X-Token,X-Auth-Token" always;
    }
    # xui-traffic: proxy ไปยัง 3x-ui local API (realtime traffic)
    location /xui-traffic/ {
        proxy_pass http://127.0.0.1:2053/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Cookie $http_cookie;
        proxy_read_timeout 30s;
    }
}
# หมายเหตุ: port 80 ถูกจัดการโดย ws-stunnel (HTTP CONNECT tunnel)
NGINXEOF
  ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya 2>/dev/null || true
fi
if nginx -t 2>/dev/null; then
  systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  sleep 1
  systemctl is-active --quiet nginx     && echo "  ✅ nginx reload/restart สำเร็จ"     || { echo "  ⚠ nginx ไม่ active — พยายาม start ใหม่..."; nginx 2>/dev/null || true; }
else
  echo "  ❌ nginx config error — ตรวจ: nginx -t"
  nginx -t
fi

# 6. ทดสอบ API จริง (ใช้ /api/status พร้อม token แทน /api/token public)
sleep 1
_fix_tok=$(cat /etc/chaiya/sshws-token.conf 2>/dev/null | tr -d '[:space:]')
_api_test=$(curl -s --max-time 5 -H "X-Token: ${_fix_tok}" "http://127.0.0.1:6789/api/status" 2>/dev/null)
if echo "$_api_test" | grep -q '"connections"'; then
  echo "  ✅ API ตอบสนองถูกต้อง"
else
  echo "  ❌ API ไม่ตอบสนอง: $_api_test"
fi

# 7. แสดง Dashboard URL
_FIX_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
echo ""
echo "  🌐 Dashboard URL:"
echo "     http://${_FIX_IP}:81/sshws/sshws.html?token=${_FIX_TOK}"
echo ""

echo ""
echo "╭══════════════════════════════════════════════════════════╮"
echo "║  ✅ CHAIYA V2RAY PRO MAX ติดตั้งเสร็จ!              ║"
echo "║                                                          ║"
echo "║  🚇 HTTP-CONNECT tunnel : port 80  (NetMod/Injector/KPN) ║"
echo "║  🐻 Dropbear SSH        : port 143, 109                  ║"
echo "║  🎮 badvpn-udpgw        : port 7300 (UDP/game)           ║"
echo "║  🌐 Dashboard           : http://[IP]:81/sshws/          ║"
echo "║                                                          ║"
echo "║  ⌨️  พิมพ์ menu เพื่อเปิดเมนู Chaiya                    ║"
echo "╰══════════════════════════════════════════════════════════╯"
echo ""

