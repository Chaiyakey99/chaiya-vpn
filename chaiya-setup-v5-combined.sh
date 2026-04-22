#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL v5 + PATCH (Combined — ALL-IN-ONE)
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-setup-v5-combined.sh
#   แก้ทุกปัญหา:
#   - nginx ไม่ชนกัน
#   - dashboard auto-login ทุกครั้งที่โหลด
#   - ชื่อ inbound: AIS-กันรั่ว (port 8080) / TRUE-VDO (port 8880)
#   - ชื่อ config ลูกค้า: AIS-กันรั่ว-{user} / TRUE-VDO-{user}
#   - หน้าออนไลน์: VLESS + SSH + data bar + วันหมดอายุ
#   - ปุ่ม reset traffic / ลบยูส: safe JSON
# ============================================================

# ── SELF-SAVE GUARD ──────────────────────────────────────────
if [[ "$0" == /dev/fd/* ]] || [[ "$0" == /proc/self/fd/* ]] || [[ "$0" == "bash" ]] || [[ "$0" == "-bash" ]] || [[ ! -f "$0" ]]; then
  _SELF=$(mktemp /tmp/chaiya-setup-XXXXX.sh)
  echo "[INFO] บันทึก script ลงไฟล์: $_SELF"
  if [[ -r "$0" ]] && cat "$0" > "$_SELF" 2>/dev/null && [[ $(wc -c < "$_SELF") -gt 10000 ]]; then
    chmod +x "$_SELF"; exec bash "$_SELF" "$@"
  fi
  if [[ ! -t 0 ]] && cat > "$_SELF" 2>/dev/null && [[ $(wc -c < "$_SELF") -gt 10000 ]]; then
    chmod +x "$_SELF"; exec bash "$_SELF" "$@"
  fi
  echo "[ERR] ไม่สามารถบันทึก script ได้ — กรุณาดาวน์โหลดไฟล์แล้วรันตรงๆ"
  rm -f "$_SELF"; exit 1
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
# 8080  xui VLESS-WS inbound (AIS-กันรั่ว)
# 8880  xui VLESS-WS inbound (TRUE-VDO)
# 6789  chaiya-ssh-api (127.0.0.1 เท่านั้น)

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

# ── CLEANUP ──────────────────────────────────────────────────
info "ล้างข้อมูลเก่า..."
for _svc in chaiya-sshws chaiya-ssh-api chaiya-badvpn nginx x-ui dropbear; do
  systemctl stop "$_svc"    2>/dev/null || true
  systemctl disable "$_svc" 2>/dev/null || true
done
pkill -f ws-stunnel 2>/dev/null || true
pkill -f badvpn-udpgw 2>/dev/null || true
pkill -f chaiya-ssh-api 2>/dev/null || true
pkill -f 'app.py' 2>/dev/null || true
pkill -9 -x nginx 2>/dev/null || true
sleep 2
rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/chaiya /etc/nginx/sites-available/chaiya-tmp
[[ -f /etc/nginx/sites-available/default ]] && \
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
rm -f /etc/systemd/system/chaiya-sshws.service
rm -f /etc/systemd/system/chaiya-ssh-api.service
rm -f /etc/systemd/system/chaiya-badvpn.service
rm -f /etc/systemd/system/dropbear.service.d/override.conf
systemctl daemon-reload
rm -rf /etc/chaiya /opt/chaiya-panel /opt/chaiya-ssh-api
rm -f /usr/local/bin/ws-stunnel /usr/local/bin/menu
if [[ -f /etc/x-ui/x-ui.db ]]; then
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds;" 2>/dev/null || true
  sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings;" 2>/dev/null || true
fi
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
systemctl is-active --quiet dropbear && ok "Dropbear พร้อม (port $DROPBEAR_PORT1, $DROPBEAR_PORT2)" || warn "Dropbear อาจไม่ทำงาน"

# ── BADVPN ───────────────────────────────────────────────────
info "ติดตั้ง BadVPN..."
if [[ ! -f /usr/bin/badvpn-udpgw ]] || [[ ! -x /usr/bin/badvpn-udpgw ]]; then
  wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
    "https://raw.githubusercontent.com/NevermoreSSH/Blueblue/main/newudpgw" 2>/dev/null && \
    chmod +x /usr/bin/badvpn-udpgw || rm -f /usr/bin/badvpn-udpgw
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

# ── WS-STUNNEL ───────────────────────────────────────────────
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
        self.running = False; self.host = host; self.port = port
        self.threads = []; self.threadsLock = threading.Lock()
    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2); self.soc.bind((self.host, int(self.port)))
        self.soc.listen(128); self.running = True
        try:
            while self.running:
                try:
                    c, addr = self.soc.accept(); c.setblocking(1)
                except socket.timeout: continue
                conn = ConnectionHandler(c, self, addr); conn.start(); self.addConn(conn)
        finally:
            self.running = False; self.soc.close()
    def addConn(self, conn):
        try:
            self.threadsLock.acquire()
            if self.running: self.threads.append(conn)
        finally: self.threadsLock.release()
    def removeConn(self, conn):
        try:
            self.threadsLock.acquire(); self.threads.remove(conn)
        finally: self.threadsLock.release()
    def close(self):
        try:
            self.running = False; self.threadsLock.acquire()
            threads = list(self.threads)
            for c in threads: c.close()
        finally: self.threadsLock.release()

class ConnectionHandler(threading.Thread):
    def __init__(self, socClient, server, addr):
        threading.Thread.__init__(self)
        self.client = socClient; self.client_buffer = b''
        self.server = server; self.addr = addr; self.daemon = True
    def run(self):
        try:
            self.client.settimeout(TIMEOUT)
            self.client_buffer = self.client.recv(BUFLEN)
            hostPort = DEFAULT_HOST
            try:
                for line in self.client_buffer.decode(errors='ignore').split('\r\n'):
                    if line.lower().startswith('x-real-host:') or line.lower().startswith('host:'):
                        hostPort = line.split(':',1)[1].strip(); break
            except: pass
            host = hostPort.split(':')[0]
            port = int(hostPort.split(':')[1]) if ':' in hostPort else 143
            self.client.send(RESPONSE); self._tunnel(host, port)
        except: pass
        finally: self.server.removeConn(self)
    def _tunnel(self, host, port):
        try:
            soc = socket.socket(socket.AF_INET); soc.settimeout(TIMEOUT); soc.connect((host, port))
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
    srv = Server(LISTENING_ADDR, LISTENING_PORT); srv.start()
    try:
        while True: time.sleep(60)
    except KeyboardInterrupt: srv.close()

if __name__ == '__main__': main()
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
  ok "3x-ui credentials ตั้งค่าแล้ว"
fi
systemctl start x-ui
sleep 5

REAL_XUI_PORT="$XUI_PORT"
for _i in $(seq 1 15); do
  _p=$(ss -tlnp 2>/dev/null | grep x-ui | grep -oP ':\K\d+' | head -1)
  [[ -n "$_p" ]] && REAL_XUI_PORT="$_p"
  curl -s --max-time 2 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${REAL_XUI_PORT}/" 2>/dev/null | grep -q "^[123]" && break
  sleep 2
done
echo "$REAL_XUI_PORT" > /etc/chaiya/xui-port.conf
ok "3x-ui พร้อม (port $REAL_XUI_PORT)"

# ── สร้าง inbounds ใน x-ui ───────────────────────────────────
info "สร้าง VLESS inbounds (AIS-กันรั่ว / TRUE-VDO)..."
XUI_COOKIE=$(mktemp)
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

    # ── ชื่อ remark ใหม่: AIS-กันรั่ว / TRUE-VDO ──────────────
    inbounds = [
        (8080, 'AIS-กันรั่ว',  'cj-ebb.speedtest.net',           'vless', 'inbound-8080'),
        (8880, 'TRUE-VDO',      'true-internet.zoom.xyz.services', 'vless', 'inbound-8880'),
    ]

    for port, remark, host, proto, tag in inbounds:
        if port in existing:
            # อัพเดต remark ถ้ามีอยู่แล้วแต่ชื่อเก่า
            con.execute("UPDATE inbounds SET remark=? WHERE port=?", (remark, port))
            print(f'[OK] อัพเดต remark port {port} → {remark}')
            continue
        uid = str(uuid.uuid4())
        # ── email default ใช้ชื่อ remark + -default ──────────
        default_email = remark.lower().replace(' ', '-').replace('ั', '').replace('ว', 'v').replace('ร', 'r') + '-default'
        settings = json.dumps({'clients': [{'id': uid, 'flow': '', 'email': default_email,
                                            'limitIp': 2, 'totalGB': 0, 'expiryTime': 0,
                                            'enable': True}], 'decryption': 'none'})
        stream   = json.dumps({'network': 'ws', 'security': 'none',
                               'wsSettings': {'path': '/vless', 'headers': {'Host': host}}})
        sniffing = json.dumps({'enabled': True, 'destOverride': ['http', 'tls']})
        con.execute(
            "INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing) VALUES (1,0,0,0,?,1,0,'',?,?,?,?,?,?)",
            (remark, port, proto, settings, stream, tag, sniffing)
        )
        print(f'[OK] สร้าง {remark} (port {port})')
    con.commit()
    con.close()
except Exception as e:
    print(f'[WARN] {e}')
PYEOF

rm -f "$XUI_COOKIE"
systemctl restart x-ui 2>/dev/null || true
sleep 2
ok "Inbounds พร้อม (AIS-กันรั่ว port 8080 / TRUE-VDO port 8880)"

# ── SSH API (Python) ──────────────────────────────────────────
info "ติดตั้ง SSH API..."
mkdir -p /opt/chaiya-ssh-api

cat > /opt/chaiya-ssh-api/app.py << 'PYEOF'
#!/usr/bin/env python3
"""Chaiya SSH API v5 — /api/status /api/users /api/online_ssh /api/banned /api/unban"""
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
    counts = {}; total = 0
    for port in ['80', '443', '143', '109', '22']:
        try:
            r = subprocess.run(
                f"ss -tn state established 2>/dev/null | awk '{{print $4}}' | grep -c ':{port}$' || echo 0",
                shell=True, capture_output=True, text=True)
            c = int(r.stdout.strip().split()[0]) if r.stdout.strip() else 0
        except: c = 0
        counts[port] = c; total += c
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
    """ดึง SSH users ที่กำลัง connected จริงๆ"""
    online = []
    try:
        _, db_procs, _ = run_cmd("ps aux 2>/dev/null | grep -v grep | grep 'dropbear\\|sshd:' | awk '{print $1}' | sort -u || true")
        users_map = {u['user']: u for u in list_ssh_users()}
        if db_procs:
            seen = set()
            for uname in db_procs.split('\n'):
                uname = uname.strip()
                if uname and uname in users_map and uname != 'root' and uname not in seen:
                    seen.add(uname)
                    online.append(users_map[uname].copy())
    except: pass
    return online

def get_banned_users():
    """ดึง VLESS clients ที่ถูก disable (= IP เกิน limit) จาก x-ui DB"""
    banned = []
    now_ts = int(time.time() * 1000)
    try:
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
                            banned.append({
                                'user':      c.get('email') or c.get('id', '?'),
                                'type':      'vless',
                                'port':      port,
                                'ibId':      ib_id,
                                'uuid':      c.get('id', ''),
                                'banTime':   now_ts,
                                'unbanTime': now_ts + 3600000
                            })
                except: pass
    except: pass
    return banned

def respond(handler, code, data):
    body = json.dumps(data, ensure_ascii=False).encode('utf-8')
    handler.send_response(code)
    handler.send_header('Content-Type', 'application/json; charset=utf-8')
    handler.send_header('Content-Length', len(body))
    handler.send_header('Access-Control-Allow-Origin', '*')
    handler.send_header('Access-Control-Allow-Methods', 'GET,POST,DELETE,OPTIONS')
    handler.send_header('Access-Control-Allow-Headers', 'Content-Type,Authorization')
    handler.end_headers()
    handler.wfile.write(body)

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET,POST,DELETE,OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type,Authorization')
        self.end_headers()

    def read_body(self):
        try:
            length = int(self.headers.get('Content-Length', 0))
            if length > 0: return json.loads(self.rfile.read(length))
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
                'conn_443': conns.get('443', 0), 'conn_80': conns.get('80', 0),
                'conn_143': conns.get('143', 0), 'conn_109': conns.get('109', 0),
                'conn_22':  conns.get('22', 0),
                'online': conns.get('total', 0), 'online_count': conns.get('total', 0),
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
            respond(self, 200, {'ok': True, 'users': list_ssh_users()})

        elif self.path == '/api/online_ssh':
            online = get_online_ssh_users()
            respond(self, 200, {'ok': True, 'online': online, 'count': len(online)})

        elif self.path == '/api/banned':
            banned = get_banned_users()
            respond(self, 200, {'ok': True, 'banned': banned, 'count': len(banned)})

        elif self.path == '/api/info':
            xui_port = open('/etc/chaiya/xui-port.conf').read().strip() if os.path.exists('/etc/chaiya/xui-port.conf') else '2053'
            respond(self, 200, {
                'host': get_host(), 'xui_port': int(xui_port),
                'dropbear_port': 143, 'dropbear_port2': 109, 'udpgw_port': 7300,
            })
        else:
            respond(self, 404, {'ok': False, 'error': 'not found'})

    def do_POST(self):
        data = self.read_body()

        if self.path == '/api/create_ssh':
            user = data.get('user', '').strip()
            days = int(data.get('days', 30))
            passwd = data.get('password', '').strip()
            if not user or not passwd:
                return respond(self, 400, {'ok': False, 'error': 'user and password required'})
            ok1, _, _ = run_cmd(f"id {user} 2>/dev/null")
            if not ok1: run_cmd(f"useradd -M -s /bin/false {user}")
            run_cmd(f"echo '{user}:{passwd}' | chpasswd")
            exp_date = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
            run_cmd(f"chage -E {exp_date} {user}")
            with open(f'/etc/chaiya/exp/{user}', 'w') as f: f.write(exp_date)
            respond(self, 200, {'ok': True, 'user': user, 'exp': exp_date, 'days': days})

        elif self.path == '/api/delete_ssh':
            user = data.get('user', '').strip()
            if not user: return respond(self, 400, {'ok': False, 'error': 'user required'})
            run_cmd(f"userdel -f {user} 2>/dev/null || true")
            try: os.remove(f'/etc/chaiya/exp/{user}')
            except: pass
            respond(self, 200, {'ok': True, 'user': user})

        elif self.path == '/api/extend_ssh':
            user = data.get('user', '').strip()
            days = int(data.get('days', 30))
            if not user: return respond(self, 400, {'ok': False, 'error': 'user required'})
            exp_f = f'/etc/chaiya/exp/{user}'
            if os.path.exists(exp_f):
                try:
                    old = datetime.date.fromisoformat(open(exp_f).read().strip())
                    new_exp = max(old, datetime.date.today()) + datetime.timedelta(days=days)
                except: new_exp = datetime.date.today() + datetime.timedelta(days=days)
            else: new_exp = datetime.date.today() + datetime.timedelta(days=days)
            run_cmd(f"chage -E {new_exp.isoformat()} {user}")
            with open(exp_f, 'w') as f: f.write(new_exp.isoformat())
            respond(self, 200, {'ok': True, 'user': user, 'exp': new_exp.isoformat()})

        elif self.path == '/api/unban':
            user = data.get('user', '').strip()
            if not user: return respond(self, 400, {'ok': False, 'error': 'user required'})
            actions = []
            run_cmd(f"iptables -D INPUT -m string --string '{user}' --algo bm -j DROP 2>/dev/null || true")
            if os.path.exists(XUI_DB):
                try:
                    con = sqlite3.connect(XUI_DB)
                    rows = con.execute("SELECT id, settings FROM inbounds WHERE enable=1").fetchall()
                    for ib_id, settings_str in rows:
                        try:
                            settings = json.loads(settings_str); changed = False
                            for c in settings.get('clients', []):
                                if (c.get('email') == user or c.get('id') == user) and not c.get('enable', True):
                                    c['enable'] = True; changed = True
                            if changed:
                                con.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(settings), ib_id))
                                actions.append(f'enabled vless client {user}')
                        except: pass
                    con.commit(); con.close()
                except: pass
            if actions: run_cmd("systemctl reload x-ui 2>/dev/null || systemctl restart x-ui 2>/dev/null || true")
            respond(self, 200, {'ok': True, 'user': user, 'actions': actions})

        else:
            respond(self, 404, {'ok': False, 'error': 'not found'})

    def do_DELETE(self):
        # รองรับ DELETE /api/user/:id (สำหรับ frontend patch)
        respond(self, 200, {'ok': True, 'message': 'use POST /api/delete_ssh instead'})

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 6789), Handler)
    print('[chaiya-ssh-api] Listening on 127.0.0.1:6789 (v5)')
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

# ── NGINX ─────────────────────────────────────────────────────
info "ติดตั้ง Nginx ใหม่..."
systemctl stop nginx 2>/dev/null || true; pkill -9 -x nginx 2>/dev/null || true
apt-get purge -y nginx nginx-common nginx-full nginx-core nginx-extras 2>/dev/null || true
rm -rf /etc/nginx /var/log/nginx /var/lib/nginx
apt-get install -y nginx
ok "ติดตั้ง Nginx ใหม่สำเร็จ"

info "ตั้งค่า Nginx..."
rm -f /etc/nginx/sites-enabled/*
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
        add_header Access-Control-Allow-Methods "GET,POST,DELETE,OPTIONS" always;
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
        add_header Access-Control-Allow-Methods "GET,POST,DELETE,OPTIONS" always;
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
nginx -t && systemctl restart nginx && ok "Nginx พร้อม" || warn "Nginx มีปัญหา — ตรวจ: nginx -t"
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
  panel_url:    "${_PANEL_URL}",
  use_ssl:      ${USE_SSL},
  xui_user:     "${XUI_USER}",
  xui_pass:     "${XUI_PASS}"
};
EOF

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
echo -e "  AIS-กันรั่ว : ${C}8080 /vless${N}"
echo -e "  TRUE-VDO    : ${C}8880 /vless${N}"
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

# ══════════════════════════════════════════════════════════════
#   STEP: สร้าง sshws.html (Dashboard)
#   - ชื่อ: AIS-กันรั่ว / TRUE-VDO
#   - หน้าออนไลน์: VLESS + SSH + data bar + expiry
#   - ปุ่ม reset/delete: safe JSON
# ══════════════════════════════════════════════════════════════
info "สร้าง Dashboard HTML..."

cp /opt/chaiya-panel/sshws.html /opt/chaiya-panel/sshws.html.bak 2>/dev/null || true

# ── เขียน HTML ใหม่ด้วย python (เพื่อหลีกเลี่ยง heredoc truncation) ──
python3 << 'HTML_PYEOF'
import base64, os

# อ่าน base64 HTML เดิมจากสคริปต์ (ถ้ามี) หรือสร้างใหม่จาก patch
HTML_B64 = "PCFET0NUWVBFIGh0bWw+CjxodG1sIGxhbmc9InRoIj4KPGhlYWQ+CjxtZXRhIGNoYXJzZXQ9IlVURi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xLjAiPgo8dGl0bGU+Q0hBSVlBIFYyUkFZIFBSTyBNQVg8L3RpdGxlPgo8bGluayBocmVmPSJodHRwczovL2ZvbnRzLmdvb2dsZWFwaXMuY29tL2NzczI/ZmFtaWx5PU9yYml0cm9uOndnaHRANDAwOzcwMDs5MDAmZmFtaWx5PVNhcmFidW46d2dodEAzMDA7NDAwOzYwMCZkaXNwbGF5PXN3YXAiIHJlbD0ic3R5bGVzaGVldCI+Cgo8IS0tIFNUWUxFUyArIEpTIGpzb24gc2FmZXBhdGNoIGluamVjdGVkIGlubGluZSBiZWxvdyAtLT4KPHNjcmlwdCBzcmM9ImNvbmZpZy5qcyIgb25lcnJvcj0id2luZG93LkNIQUlZQV9DT05GSUc9e30iPjwvc2NyaXB0Pgo8L2hlYWQ+"

# decode แล้วเขียนไฟล์ base
try:
    raw = base64.b64decode(HTML_B64 + "==")
    # ถ้า decode ได้ n/a ให้ข้าม (placeholder only)
except:
    pass

# ใช้ HTML ที่ถูก inject patch ตรงๆ
PANEL_DIR = "/opt/chaiya-panel"
HTML_FILE = os.path.join(PANEL_DIR, "sshws.html")

# อ่าน sshws.html เดิมถ้ามี (จาก bak)
BAK = HTML_FILE + ".bak"
src = ""
if os.path.exists(BAK):
    with open(BAK, "r", encoding="utf-8") as f:
        src = f.read()
elif os.path.exists(HTML_FILE):
    with open(HTML_FILE, "r", encoding="utf-8") as f:
        src = f.read()

if not src:
    print("[INFO] ไม่พบ HTML เดิม — จะสร้างเฉพาะ patch block")

# ── PATCH BLOCK ──────────────────────────────────────────────
# รวม:
# 1. แก้ชื่อ config (AIS-กันรั่ว / TRUE-VDO)
# 2. safe fetch JSON (ป้องกัน Unexpected end of JSON)
# 3. หน้าออนไลน์ใหม่ดึงจาก x-ui จริง + data bar + expiry
PATCH = '''<!-- CHAIYA_V5_PATCH -->
<style>
@keyframes ocBlink{0%,100%{opacity:1}50%{opacity:.3}}
@keyframes toastIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
@keyframes toastOut{from{opacity:1}to{opacity:0;transform:translateY(10px)}}
</style>
<script>
// ================================================================
//  CHAIYA V5 PATCH — ชื่อ AIS-กันรั่ว/TRUE-VDO + Safe JSON + Online
// ================================================================
(function(){
"use strict";

// ── 1. Safe fetch wrapper ──────────────────────────────────────
const _oFetch = window.fetch;
window.fetch = async function(...args){
  const res = await _oFetch.apply(this, args);
  const cloned = res.clone();
  const origJson = res.json.bind(res);
  res.json = async function(){
    try{ return await origJson(); }
    catch{
      try{ const t=await cloned.text(); if(!t||!t.trim())return{ok:res.ok,success:res.ok}; return{ok:res.ok,success:res.ok,raw:t}; }
      catch{ return{ok:res.ok,success:res.ok}; }
    }
  };
  return res;
};

// Toast
function toast(msg,type){
  let b=document.getElementById("cv5-toast");
  if(!b){b=document.createElement("div");b.id="cv5-toast";
    b.style.cssText="position:fixed;bottom:20px;left:50%;transform:translateX(-50%);z-index:99999;display:flex;flex-direction:column;gap:8px;pointer-events:none;min-width:260px;";
    document.body.appendChild(b);}
  const t=document.createElement("div");
  t.style.cssText="background:"+(type==="ok"?"#16a34a":"#dc2626")+";color:#fff;padding:11px 18px;border-radius:12px;font-size:14px;font-weight:700;text-align:center;box-shadow:0 4px 20px rgba(0,0,0,.3);animation:toastIn .3s ease;pointer-events:auto;";
  t.textContent=(type==="ok"?"✅ ":"❌ ")+msg;
  b.appendChild(t);
  setTimeout(()=>{t.style.animation="toastOut .3s ease forwards";setTimeout(()=>t.remove(),300);},3000);
}

// ── 2. ชื่อ config: AIS-กันรั่ว-{user} / TRUE-VDO-{user} ────────
window.chaiyaConfigName = function(email, port){
  const p = parseInt(port)||0;
  return (p===8880||p===443||p===80) ? "TRUE-VDO-"+email : "AIS-กันรั่ว-"+email;
};

// Override generate functions
["generateFileName","getConfigName","buildFileName","makeConfigName"].forEach(fn=>{
  if(typeof window[fn]==="function"&&!window[fn]._cv5){
    const orig=window[fn];
    window[fn]=function(u,p,...r){
      const res=orig.call(this,u,p,...r);
      if(typeof res==="string"){
        return res.replace(/^chaiya-default-?/i,"AIS-กันรั่ว-")
                  .replace(/^chaiya-/i,"AIS-กันรั่ว-")
                  .replace(/^true-/i,"TRUE-VDO-")
                  .replace(/^default-/i,"AIS-กันรั่ว-");
      }
      return res;
    };
    window[fn]._cv5=true;
  }
});

// Scan & replace text nodes
function patchNames(){
  const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);
  const ns=[]; let n;
  while((n=w.nextNode()))ns.push(n);
  ns.forEach(nd=>{
    let t=nd.textContent,ch=false;
    t=t.replace(/\bchaiya-default\b/g,()=>{ch=true;return"AIS-กันรั่ว";});
    t=t.replace(/\bchaiya-([A-Za-z0-9_]+)\b/g,(_,u)=>{ch=true;return"AIS-กันรั่ว-"+u;});
    t=t.replace(/\btrue-([A-Za-z0-9_]+)\b/gi,(_,u)=>{ch=true;return"TRUE-VDO-"+u;});
    if(ch)nd.textContent=t;
  });
}

// ── 3. หน้าออนไลน์: VLESS จาก x-ui + SSH จาก API ───────────────
function bytesH(b){
  if(!b||b===0)return"0 B";
  const u=["B","KB","MB","GB","TB"];
  const i=Math.floor(Math.log(b)/Math.log(1024));
  return(b/Math.pow(1024,i)).toFixed(1)+" "+u[i];
}
function expiryInfo(ms){
  if(!ms||ms===0)return{str:"ไม่จำกัด",cls:"ok"};
  const diff=ms-Date.now();
  const days=Math.ceil(diff/86400000);
  if(days<=0)return{str:"หมดอายุ",cls:"exp"};
  if(days<=3)return{str:days+"d",cls:"warn"};
  const d=new Date(ms);
  return{str:d.getDate()+"/"+(d.getMonth()+1)+"/"+(d.getFullYear()+543),cls:"ok"};
}

// patch loadOnline ที่มีใน sshws.html เดิม
const _origLoadOnline = window.loadOnline;
window.loadOnline = async function(){
  const loadEl  = document.getElementById("online-loading");
  const vlessEl = document.getElementById("online-vless-section");
  const sshEl   = document.getElementById("online-ssh-section");
  const emptyEl = document.getElementById("online-empty");
  const countEl = document.getElementById("online-count");
  const timeEl  = document.getElementById("online-time");

  if(loadEl){loadEl.innerHTML="<div class='loading'>กำลังโหลด...</div>";loadEl.style.display="block";}
  if(vlessEl)vlessEl.style.display="none";
  if(sshEl)sshEl.style.display="none";
  if(emptyEl)emptyEl.style.display="none";

  try{
    // login x-ui ถ้ายังไม่ได้
    if(typeof xuiLogin==="function"&&!window._xuiOk) await xuiLogin();

    // ── VLESS online จาก x-ui /panel/api/inbounds/onlines ──────
    let vlessOnline=[];
    try{
      const od = await fetch("/xui-api/panel/api/inbounds/onlines",{credentials:"include",cache:"no-store"});
      const odj = await od.json();
      vlessOnline = (odj&&odj.obj)?odj.obj:[];
    }catch{}

    // ── ดึง inbound list เพื่อหา traffic/expiry แต่ละ user ────
    let userMap={};
    try{
      const il = await fetch("/xui-api/panel/api/inbounds/list",{credentials:"include",cache:"no-store"});
      const ilj = await il.json();
      (ilj.obj||[]).forEach(ib=>{
        const s=typeof ib.settings==="string"?JSON.parse(ib.settings):ib.settings;
        (s.clients||[]).forEach(c=>{
          userMap[c.email||c.id]={
            email: c.email||c.id,
            port:  ib.port,
            up:    ib.up||0,
            down:  ib.down||0,
            total: c.totalGB||0,
            exp:   c.expiryTime||0,
            uuid:  c.id
          };
        });
      });
    }catch{}

    // ── SSH online ──────────────────────────────────────────────
    let sshOnline=[];
    try{
      const sr = await fetch("/api/online_ssh",{cache:"no-store"});
      const sj = await sr.json();
      sshOnline = (sj&&sj.online)?sj.online:[];
    }catch{}

    const total = vlessOnline.length + sshOnline.length;
    if(countEl)countEl.textContent=total;
    if(timeEl)timeEl.textContent="อัพเดต: "+new Date().toLocaleTimeString("th-TH");
    if(loadEl)loadEl.style.display="none";

    if(total===0){
      if(emptyEl)emptyEl.style.display="block";
      return;
    }

    // ── render VLESS cards ──────────────────────────────────────
    if(vlessOnline.length>0&&vlessEl){
      vlessEl.style.display="block";
      const listEl=document.getElementById("online-vless-list");
      if(listEl){
        listEl.innerHTML=vlessOnline.map(email=>{
          const u=userMap[email]||{};
          const used=(u.up||0)+(u.down||0);
          const lim=u.total||0;
          const pct=lim>0?Math.min(100,Math.round(used/lim*100)):-1;
          const barW=pct<0?0:pct;
          const barColor=pct>80?"#ef4444":pct>60?"#f97316":"var(--ac)";
          const exp=expiryInfo(u.exp||0);
          const configName=window.chaiyaConfigName?window.chaiyaConfigName(email,u.port||8080):email;
          const expStyle=exp.cls==="exp"?"color:#ef4444;font-weight:700":exp.cls==="warn"?"color:#f97316;font-weight:600":"color:#22c55e";
          return `<div class="uitем" style="flex-direction:column;align-items:stretch;gap:6px;cursor:default">
            <div style="display:flex;align-items:center;gap:10px">
              <div class="uav av-g" style="flex-shrink:0"><span style="font-size:9px;font-family:'Orbitron',monospace;font-weight:700">VL</span></div>
              <div style="flex:1;min-width:0">
                <div class="un">${configName}</div>
                <div class="um">Port ${u.port||"?"} · <span style="${expStyle}">📅 ${exp.str}</span></div>
              </div>
              <span class="abdg ok" style="font-size:9px">ONLINE</span>
            </div>
            <div style="padding-left:46px">
              <div style="display:flex;justify-content:space-between;font-size:10px;color:var(--muted);margin-bottom:3px">
                <span>📊 ${bytesH(used)}</span>
                <span>${pct<0?"ไม่จำกัด":pct+"%"}</span>
              </div>
              <div class="pb" style="height:5px;border-radius:3px">
                <div class="pf" style="width:${barW}%;background:${barColor};border-radius:3px;transition:width .8s ease"></div>
              </div>
            </div>
          </div>`;
        }).join("");
      }
    }

    // ── render SSH cards ────────────────────────────────────────
    if(sshOnline.length>0&&sshEl){
      sshEl.style.display="block";
      const listEl=document.getElementById("online-ssh-list");
      if(listEl){
        listEl.innerHTML=sshOnline.map(u=>{
          const exp=u.exp||"ไม่จำกัด";
          return `<div class="uitем" style="cursor:default">
            <div class="uav" style="background:rgba(59,130,246,0.15);color:#3b82f6;border:1px solid rgba(59,130,246,.2);flex-shrink:0">
              <span style="font-size:9px;font-family:'Orbitron',monospace;font-weight:700">SSH</span>
            </div>
            <div style="flex:1">
              <div class="un">${u.user}</div>
              <div class="um">Port 80/143 · 📅 ${exp}</div>
            </div>
            <span class="abdg ok" style="font-size:9px">ONLINE</span>
          </div>`;
        }).join("");
      }
    }
  }catch(e){
    if(loadEl){loadEl.innerHTML="<div class='loading' style='color:#ef4444'>"+e.message+"</div>";loadEl.style.display="block";}
  }
};

// ── 4. MutationObserver: patch เมื่อ DOM เปลี่ยน ────────────────
const obs=new MutationObserver(()=>{patchNames();});
function init(){
  setTimeout(()=>{
    patchNames();
    obs.observe(document.body,{childList:true,subtree:true});
    // ถ้าเปิดหน้าออนไลน์อยู่ → load ทันที
    const ot=document.getElementById("tab-online");
    if(ot&&ot.classList.contains("active"))window.loadOnline();
  },800);
}
if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",init);
else init();

})();
</script>
<!-- /CHAIYA_V5_PATCH -->'''

# inject ก่อน </body>
if src:
    idx = src.rfind("</body>")
    if idx == -1:
        out = src + "\n" + PATCH
    else:
        out = src[:idx] + "\n" + PATCH + "\n" + src[idx:]
    with open(HTML_FILE, "w", encoding="utf-8") as f:
        f.write(out)
    print("[OK] inject CHAIYA_V5_PATCH สำเร็จ")
else:
    # สร้าง placeholder HTML
    with open(HTML_FILE, "w", encoding="utf-8") as f:
        f.write("<!DOCTYPE html><html><head><meta charset='UTF-8'></head><body>" + PATCH + "</body></html>")
    print("[WARN] สร้าง placeholder HTML + patch")

HTML_PYEOF

ok "Dashboard HTML พร้อม"

# ── RESTART SERVICES ─────────────────────────────────────────
info "Restart services..."
systemctl restart chaiya-ssh-api
sleep 2
systemctl is-active --quiet chaiya-ssh-api && ok "chaiya-ssh-api ✅" || warn "chaiya-ssh-api ⚠️"

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
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   CHAIYA VPN PANEL v5 - ติดตั้งสำเร็จ! 🚀      ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
if [[ $USE_SSL -eq 1 ]]; then
  echo -e "  🌐 Panel URL   : ${CYAN}${BOLD}https://${DOMAIN}${NC}"
  echo -e "  🔒 SSL         : ${GREEN}✅ HTTPS พร้อม${NC}"
else
  echo -e "  🌐 Panel URL   : ${YELLOW}http://${DOMAIN}:81 (ยังไม่มี SSL)${NC}"
  echo -e "  🔒 SSL         : ${YELLOW}⚠️  รัน: certbot certonly --standalone -d ${DOMAIN}${NC}"
fi
echo -e "  👤 3x-ui User  : ${YELLOW}${XUI_USER}${NC}"
echo -e "  🔒 3x-ui Pass  : ${YELLOW}${XUI_PASS}${NC}"
echo -e "  🖥  3x-ui Panel : ${CYAN}${BOLD}https://${DOMAIN}/xui-api/panel/${NC}"
echo -e "  🐻 Dropbear    : ${CYAN}port 143, 109${NC}"
echo -e "  🌐 WS-Tunnel   : ${CYAN}port 80 → Dropbear:143${NC}"
echo -e "  🎮 BadVPN UDPGW: ${CYAN}port 7300${NC}"
echo -e "  📡 AIS-กันรั่ว : ${CYAN}port 8080 /vless${NC}"
echo -e "  📡 TRUE-VDO    : ${CYAN}port 8880 /vless${NC}"
echo ""
echo -e "  💡 พิมพ์ ${CYAN}menu${NC} เพื่อดูรายละเอียด"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
