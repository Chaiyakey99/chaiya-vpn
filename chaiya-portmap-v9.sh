#!/bin/bash
# ============================================================
#   CHAIYA VPN — PORT ARCHITECTURE v9 (HAProxy + Nginx + Xray + ZiVPN + UDP Custom)
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-portmap-v9.sh
#
#   สถาปัตยกรรมใหม่ตามแผน:
#   TCP:80  -> HAProxy -> Nginx:8880 -> [npxproxy:8080->SSH:22] หรือ [Xray:18080 VLESS-WS]
#   TCP:443 -> HAProxy -> Xray:24443 (TLS terminate) -> Valid VLESS / fallback SSH:22
#   UDP     -> DNAT 6000-6499,6501-19999 -> ZiVPN:5667 | catch-all 1-65535 -> UDP Custom:36712
# ============================================================

[[ $EUID -ne 0 ]] && { echo "ต้องรันด้วย root (sudo)"; exit 1; }

if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$0" == "bash" ]] || [[ "$0" == "-bash" ]] || [[ ! -f "$0" ]]; then
  _SELF=$(mktemp /tmp/chaiya-portmap-XXXXX.sh)
  if [[ -r "$0" ]] && cat "$0" > "$_SELF" 2>/dev/null && [[ $(wc -c < "$_SELF") -gt 5000 ]]; then
    chmod +x "$_SELF"; exec bash "$_SELF" "$@"
  fi
  if [[ ! -t 0 ]] && cat > "$_SELF" 2>/dev/null && [[ $(wc -c < "$_SELF") -gt 5000 ]]; then
    chmod +x "$_SELF"; exec bash "$_SELF" "$@"
  fi
  echo "[ERR] บันทึกไฟล์ไม่สำเร็จ — ดาวน์โหลดไฟล์แล้วรันตรง ๆ"; rm -f "$_SELF"; exit 1
fi

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

# ── PORT MAP ────────────────────────────────────────────────
HAPROXY_80=80
HAPROXY_443=443
NGINX_WS_PORT=8880          # nginx (internal, 127.0.0.1) — HAProxy:80 backend
NPXPROXY_PORT=8080          # ws->tcp proxy for SSH (internal, 127.0.0.1) -> sshd:22
SSHD_PORT=22
XRAY_VLESS_WS_PORT=18080    # xray VLESS-WS no-TLS (internal, 127.0.0.1) -> nginx backend
XRAY_VLESS_TLS_PORT=24443   # xray VLESS-TCP-TLS terminate (internal, 127.0.0.1) -> HAProxy:443 backend
ZIVPN_PORT=5667
UDPCUSTOM_PORT=36712
XUI_NGINX_PORT=2503         # keep existing x-ui panel proxy port untouched

CONF_DIR=/etc/chaiya
mkdir -p "$CONF_DIR"
BACKUP_DIR=/etc/chaiya/backup-$(date +%Y%m%d%H%M%S)
mkdir -p "$BACKUP_DIR"

# ── DOMAIN / CERT ───────────────────────────────────────────
if [[ -f "$CONF_DIR/domain.conf" ]]; then
  DOMAIN=$(cat "$CONF_DIR/domain.conf")
elif [[ -n "$CHAIYA_DOMAIN" ]]; then
  DOMAIN="$CHAIYA_DOMAIN"
else
  read -rp "โดเมนที่ชี้มา VPS นี้ (ใช้ออกใบรับรอง TLS สำหรับ Xray:443): " DOMAIN
fi
[[ -z "$DOMAIN" ]] && err "ต้องระบุโดเมน"
echo "$DOMAIN" > "$CONF_DIR/domain.conf"

WS_PATH_SSH="/chaiya-ssh-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c6)"
WS_PATH_VLESS="/chaiya-vls-$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c6)"
FAKE_SNI="scontent.xx.fbcdn.net"

info "โดเมน: $DOMAIN | SSH-WS path: $WS_PATH_SSH | VLESS-WS path: $WS_PATH_VLESS"

# ── BACKUP EXISTING CONFIGS ─────────────────────────────────
info "สำรองไฟล์ config เดิม..."
for f in /etc/nginx/sites-available/chaiya /etc/nginx/conf.d/chaiya.conf /etc/haproxy/haproxy.cfg /etc/zivpn/config.json /etc/udp/config.json; do
  [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/" 2>/dev/null
done
ok "สำรองไว้ที่ $BACKUP_DIR"

# ── PACKAGES ─────────────────────────────────────────────────
info "ติดตั้งแพ็กเกจที่จำเป็น..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq haproxy nginx python3 python3-pip curl wget unzip jq sqlite3 iptables-persistent openssl lsof >/dev/null 2>&1 \
  || apt-get install -y haproxy nginx python3 curl wget unzip jq sqlite3 iptables-persistent openssl lsof
DEBIAN_FRONTEND=noninteractive timeout 120 apt-get install -y -qq certbot >/dev/null 2>&1 || true
ok "แพ็กเกจพร้อม"

# ── STOP CONFLICTING SERVICES & FREE PORTS ──────────────────
info "หยุดบริการเดิมที่อาจชนพอร์ต..."
for _svc in haproxy nginx chaiya-npxproxy chaiya-sshws zivpn udp-custom dropbear chaiya-ws-stunnel; do
  systemctl stop "$_svc" 2>/dev/null || true
done
_REQUIRED_PORTS=(80 443 $NGINX_WS_PORT $NPXPROXY_PORT $XRAY_VLESS_WS_PORT $XRAY_VLESS_TLS_PORT $ZIVPN_PORT $UDPCUSTOM_PORT)
for _port in "${_REQUIRED_PORTS[@]}"; do
  _pids=$(lsof -ti tcp:$_port 2>/dev/null; lsof -ti udp:$_port 2>/dev/null)
  for _pid in $_pids; do
    _pname=$(ps -p "$_pid" -o comm= 2>/dev/null)
    [[ "$_pname" == "sshd" ]] && continue
    warn "Port $_port ถูกใช้โดย $_pname (PID $_pid) — kill"
    kill -9 "$_pid" 2>/dev/null || true
  done
done
ok "พอร์ตว่างพร้อมใช้"

# ============================================================
# 1) NPXPROXY — WS -> TCP proxy สำหรับ SSH (127.0.0.1:8080 -> 127.0.0.1:22)
# ============================================================
info "ติดตั้ง npxproxy (SSH over WebSocket, no TLS, port 80 chain)..."
mkdir -p /etc/chaiya/npxproxy
cat > /etc/chaiya/npxproxy/npxproxy.py << PYEOF
#!/usr/bin/env python3
import socket, threading, select, sys

LISTEN_ADDR = ('127.0.0.1', ${NPXPROXY_PORT})
TARGET_ADDR = ('127.0.0.1', ${SSHD_PORT})
RESPONSE = b'HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n'
BUFLEN = 65536

def relay(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r: break
            if a in r:
                data = a.recv(BUFLEN)
                if not data: break
                b.sendall(data)
            if b in r:
                data = b.recv(BUFLEN)
                if not data: break
                a.sendall(data)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try: s.close()
            except Exception: pass

def handle(client):
    try:
        client.recv(BUFLEN)  # consume the WS/HTTP upgrade request from client
        client.sendall(RESPONSE)
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream.connect(TARGET_ADDR)
        relay(client, upstream)
    except Exception:
        try: client.close()
        except Exception: pass

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN_ADDR)
    srv.listen(200)
    print(f'[npxproxy] listening {LISTEN_ADDR} -> {TARGET_ADDR}')
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()

if __name__ == '__main__':
    main()
PYEOF
chmod +x /etc/chaiya/npxproxy/npxproxy.py

cat > /etc/systemd/system/chaiya-npxproxy.service << EOF
[Unit]
Description=Chaiya npxproxy (WS->TCP for SSH, port 80 chain)
After=network.target sshd.service

[Service]
ExecStart=/usr/bin/python3 /etc/chaiya/npxproxy/npxproxy.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chaiya-npxproxy >/dev/null 2>&1
systemctl restart chaiya-npxproxy
sleep 1
systemctl is-active --quiet chaiya-npxproxy && ok "npxproxy พร้อม (127.0.0.1:$NPXPROXY_PORT -> sshd:$SSHD_PORT)" || warn "npxproxy ไม่ start — journalctl -u chaiya-npxproxy"

# ============================================================
# 2) XRAY (ผ่าน x-ui) — เพิ่ม inbound VLESS-WS:18080 และ VLESS-TCP-TLS:24443 (fallback SSH:22)
# ============================================================
info "ตั้งค่า Xray inbounds ผ่าน x-ui (VLESS-WS:$XRAY_VLESS_WS_PORT, VLESS-TLS:$XRAY_VLESS_TLS_PORT)..."

XUI_DB=$(find / -maxdepth 4 -name "x-ui.db" 2>/dev/null | head -1)
if [[ -z "$XUI_DB" ]]; then
  warn "ไม่พบ x-ui.db — ข้ามการเพิ่ม inbound อัตโนมัติ ต้องเพิ่ม VLESS inbound เองผ่านหน้าเว็บ x-ui"
else
  # ออกใบรับรองถ้ายังไม่มี (standalone, ต้อง stop nginx/haproxy ชั่วคราว)
  if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    info "ออก TLS cert ให้ $DOMAIN (standalone, ปลดพอร์ต 80 ชั่วคราว)..."
    systemctl stop nginx haproxy 2>/dev/null || true
    certbot certonly --standalone --non-interactive --agree-tos -m "admin@$DOMAIN" -d "$DOMAIN" 2>/dev/null \
      || warn "ออกใบรับรองไม่สำเร็จ — ตรวจสอบว่าโดเมนชี้มา VPS นี้แล้ว และพอร์ต 80 เปิดจาก internet"
  fi
  CERT_FULLCHAIN="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  CERT_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

  cp -a "$XUI_DB" "$BACKUP_DIR/x-ui.db.bak" 2>/dev/null

  export XUI_DB DOMAIN CERT_FULLCHAIN CERT_KEY WS_PATH_SSH WS_PATH_VLESS XRAY_VLESS_WS_PORT XRAY_VLESS_TLS_PORT SSHD_PORT
  python3 - << 'XRAYPY'
import sqlite3, json, uuid, os

db = os.environ['XUI_DB']
domain = os.environ['DOMAIN']
cert = os.environ['CERT_FULLCHAIN']
key = os.environ['CERT_KEY']
ws_vless = os.environ['WS_PATH_VLESS']
port_ws = int(os.environ['XRAY_VLESS_WS_PORT'])
port_tls = int(os.environ['XRAY_VLESS_TLS_PORT'])
ssh_fallback_port = int(os.environ['SSHD_PORT'])

con = sqlite3.connect(db)
cur = con.cursor()
existing = [r[0] for r in cur.execute("SELECT port FROM inbounds").fetchall()]

def add_inbound(port, remark, settings, stream, tag):
    if port in existing:
        print(f'[SKIP] port {port} มี inbound อยู่แล้ว')
        return
    cur.execute(
        "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) "
        "VALUES (1,0,0,0,?,1,0,?,?,?,?,?,?,?)",
        (remark, "127.0.0.1", port, "vless", settings, stream, tag,
         json.dumps({"enabled": True, "destOverride": ["http", "tls"]}))
    )
    print(f'[OK] เพิ่ม inbound {remark} port {port}')

client_uuid_ws = str(uuid.uuid4())
settings_ws = json.dumps({
    "clients": [{"id": client_uuid_ws, "email": "chaiya-vless-ws", "flow": ""}],
    "decryption": "none"
})
stream_ws = json.dumps({
    "network": "ws",
    "security": "none",
    "wsSettings": {"path": ws_vless, "headers": {}}
})
add_inbound(port_ws, "CHAIYA-VLESS-WS-80", settings_ws, stream_ws, "chaiya-vless-ws")

client_uuid_tls = str(uuid.uuid4())
settings_tls = json.dumps({
    "clients": [{"id": client_uuid_tls, "email": "chaiya-vless-tls", "flow": ""}],
    "decryption": "none",
    "fallbacks": [{"dest": ssh_fallback_port}]
})
stream_tls = json.dumps({
    "network": "tcp",
    "security": "tls",
    "tlsSettings": {
        "certificates": [{"certificateFile": cert, "keyFile": key}],
        "rejectUnknownSni": False
    }
})
add_inbound(port_tls, "CHAIYA-VLESS-TLS-443", settings_tls, stream_tls, "chaiya-vless-tls")

con.commit()
con.close()

with open('/etc/chaiya/vless-clients.json', 'w') as f:
    json.dump({
        "vless_ws_uuid": client_uuid_ws,
        "vless_ws_path": ws_vless,
        "vless_tls_uuid": client_uuid_tls,
        "domain": domain
    }, f, indent=2)
print('[OK] บันทึก UUID ลง /etc/chaiya/vless-clients.json')
XRAYPY

  systemctl restart x-ui 2>/dev/null || true
  sleep 2
  ok "Xray inbounds ตั้งค่าเสร็จ (ดู UUID ที่ /etc/chaiya/vless-clients.json)"
fi

# ============================================================
# 3) NGINX — :8880 (WS front สำหรับ port 80 chain), คง :$XUI_NGINX_PORT (x-ui panel) เดิมไว้
# ============================================================
info "ตั้งค่า Nginx (127.0.0.1:$NGINX_WS_PORT)..."
rm -f /etc/nginx/sites-enabled/chaiya-ws 2>/dev/null
cat > /etc/nginx/sites-available/chaiya-ws << EOF
server {
    listen 127.0.0.1:${NGINX_WS_PORT};
    server_name _;

    location ${WS_PATH_SSH} {
        proxy_pass http://127.0.0.1:${NPXPROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location ${WS_PATH_VLESS} {
        proxy_pass http://127.0.0.1:${XRAY_VLESS_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / {
        proxy_pass http://127.0.0.1:${NPXPROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
ln -sf /etc/nginx/sites-available/chaiya-ws /etc/nginx/sites-enabled/chaiya-ws
nginx -t >/tmp/nginx-test.log 2>&1 && ok "Nginx config ผ่าน" || { warn "Nginx config ผิดพลาด:"; cat /tmp/nginx-test.log; }
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
sleep 1
systemctl is-active --quiet nginx && ok "Nginx พร้อม" || warn "Nginx ไม่ start — journalctl -u nginx"

# ============================================================
# 4) HAPROXY — :80 -> nginx:8880, :443 -> xray:24443 (TCP passthrough ทั้งคู่)
# ============================================================
info "ตั้งค่า HAProxy (:80 -> nginx:$NGINX_WS_PORT, :443 -> xray:$XRAY_VLESS_TLS_PORT)..."
cat > /etc/haproxy/haproxy.cfg << EOF
global
    log /dev/log local0
    maxconn 20000
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  3600s
    timeout server  3600s

frontend ft_port80
    bind *:${HAPROXY_80}
    default_backend bk_nginx_ws

backend bk_nginx_ws
    server nginx_ws 127.0.0.1:${NGINX_WS_PORT} check

frontend ft_port443
    bind *:${HAPROXY_443}
    default_backend bk_xray_tls

backend bk_xray_tls
    server xray_tls 127.0.0.1:${XRAY_VLESS_TLS_PORT} check
EOF
haproxy -c -f /etc/haproxy/haproxy.cfg >/tmp/haproxy-test.log 2>&1 && ok "HAProxy config ผ่าน" || { err "HAProxy config ผิดพลาด: $(cat /tmp/haproxy-test.log)"; }
systemctl enable haproxy >/dev/null 2>&1
systemctl restart haproxy
sleep 1
systemctl is-active --quiet haproxy && ok "HAProxy พร้อม" || warn "HAProxy ไม่ start — journalctl -u haproxy"

# ============================================================
# 5) ZiVPN — UDP :5667
# ============================================================
info "ติดตั้ง ZiVPN (UDP :$ZIVPN_PORT)..."
mkdir -p /etc/zivpn
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then ZVURL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"
elif [[ "$ARCH" == "aarch64" ]]; then ZVURL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-arm64"
else err "ZiVPN ไม่รองรับ arch $ARCH"; fi

wget -q --timeout=20 -O /usr/local/bin/zivpn "$ZVURL" && chmod +x /usr/local/bin/zivpn \
  || warn "ดาวน์โหลด ZiVPN binary ไม่สำเร็จ — ตรวจสอบการเชื่อมต่อ internet ของ VPS"

if [[ ! -f /etc/zivpn/zivpn.crt ]]; then
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/C=TH/ST=Bangkok/L=Bangkok/O=ChaiyaVPN/OU=ChaiyaVPN/CN=$DOMAIN" \
    -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt >/dev/null 2>&1
fi

read -rp "ตั้งรหัสผ่านสำหรับ ZiVPN (Enter = ใช้ค่า 'chaiya'): " ZIVPN_PASS
ZIVPN_PASS=${ZIVPN_PASS:-chaiya}
cat > /etc/zivpn/config.json << EOF
{
  "listen": ":${ZIVPN_PORT}",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": ["${ZIVPN_PASS}"]
  }
}
EOF

cat > /etc/systemd/system/zivpn.service << 'EOF'
[Unit]
Description=Chaiya ZiVPN UDP Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable zivpn >/dev/null 2>&1
systemctl restart zivpn
sleep 1
systemctl is-active --quiet zivpn && ok "ZiVPN พร้อม (UDP :$ZIVPN_PORT, password: $ZIVPN_PASS)" || warn "ZiVPN ไม่ start — journalctl -u zivpn"

# ============================================================
# 6) UDP Custom — UDP :36712 (catch-all)
# ============================================================
info "ติดตั้ง UDP Custom (UDP :$UDPCUSTOM_PORT)..."
mkdir -p /etc/udp
wget -q --timeout=20 -O /etc/udp/udp-custom "https://github.com/Rerechan02/UDP/raw/main/bin/udp-custom-linux-amd64" \
  && chmod +x /etc/udp/udp-custom \
  || warn "ดาวน์โหลด UDP Custom binary ไม่สำเร็จ — ตรวจสอบการเชื่อมต่อ internet ของ VPS"

cat > /etc/udp/config.json << EOF
{
  "listen": ":${UDPCUSTOM_PORT}",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": {
    "mode": "passwords"
  }
}
EOF

cat > /etc/systemd/system/udp-custom.service << 'EOF'
[Unit]
Description=Chaiya UDP Custom Server

[Service]
User=root
Type=simple
ExecStart=/etc/udp/udp-custom server
WorkingDirectory=/etc/udp/
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable udp-custom >/dev/null 2>&1
systemctl restart udp-custom
sleep 1
systemctl is-active --quiet udp-custom && ok "UDP Custom พร้อม (UDP :$UDPCUSTOM_PORT)" || warn "UDP Custom ไม่ start — journalctl -u udp-custom"

# ============================================================
# 7) iptables DNAT — ตามช่วงพอร์ต UDP ในแผน
# ============================================================
info "ตั้งค่า iptables DNAT (UDP)..."
IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
[[ -z "$IFACE" ]] && IFACE=eth0

# ล้างกฎ DNAT chaiya เก่า (comment tag) ก่อนใส่ใหม่ กันซ้ำเวลารันสคริปต์ซ้ำ
iptables-save 2>/dev/null | grep -v "CHAIYA-UDP-DNAT" | iptables-restore 2>/dev/null || true

iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6000:6499 -m comment --comment CHAIYA-UDP-DNAT -j DNAT --to-destination :${ZIVPN_PORT}
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 6501:19999 -m comment --comment CHAIYA-UDP-DNAT -j DNAT --to-destination :${ZIVPN_PORT}
iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 1:65535 -m comment --comment CHAIYA-UDP-DNAT -j DNAT --to-destination :${UDPCUSTOM_PORT}

for _p in ${ZIVPN_PORT} ${UDPCUSTOM_PORT}; do
  iptables -C INPUT -p udp --dport "$_p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$_p" -j ACCEPT
done
iptables -C INPUT -p udp --dport 1:65535 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 1:65535 -j ACCEPT
for _p in 80 443; do
  iptables -C INPUT -p tcp --dport "$_p" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$_p" -j ACCEPT
done

netfilter-persistent save >/dev/null 2>&1 || (iptables-save > /etc/iptables/rules.v4 2>/dev/null)
ok "iptables DNAT ตั้งค่าเสร็จ (interface: $IFACE)"

# ============================================================
# STATUS CHECK
# ============================================================
echo ""
echo -e "${BOLD}=== สถานะปัจจุบัน ===${NC}"
check_svc() { systemctl is-active --quiet "$1" && echo -e "  ${GREEN}✓${NC} $2" || echo -e "  ${RED}✗${NC} $2 (systemctl status $1)"; }
check_svc haproxy       "HAProxy (:80, :443)"
check_svc nginx         "Nginx (:$NGINX_WS_PORT)"
check_svc chaiya-npxproxy "npxproxy — SSH WS NONE TLS :80 (path $WS_PATH_SSH)"
check_svc x-ui          "x-ui / Xray — VLESS WS NONE TLS :80 (path $WS_PATH_VLESS) / VLESS+SSH fallback TLS :443"
check_svc zivpn         "ZiVPN — UDP :$ZIVPN_PORT (รับช่วง 6000-6499, 6501-19999)"
check_svc udp-custom    "UDP Custom — UDP :$UDPCUSTOM_PORT (catch-all)"

echo ""
echo -e "${CYAN}โดเมน:${NC} $DOMAIN"
echo -e "${CYAN}SSH-WS path (port 80):${NC}    $WS_PATH_SSH"
echo -e "${CYAN}VLESS-WS path (port 80):${NC}  $WS_PATH_VLESS"
echo -e "${CYAN}VLESS/SSH-fallback TLS SNI แนะนำ (port 443):${NC} $FAKE_SNI"
echo -e "${CYAN}UUID/ค่า client:${NC} cat /etc/chaiya/vless-clients.json"
echo -e "${CYAN}ZiVPN password:${NC} $ZIVPN_PASS"
echo ""
ok "ติดตั้งเสร็จสมบูรณ์"
