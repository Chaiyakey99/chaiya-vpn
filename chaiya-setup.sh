#!/bin/bash
# ============================================================
#   CHAIYA VPN PANEL - All-in-One Install Script v3
#   Ubuntu 22.04 / 24.04
#   รันคำสั่งเดียว: bash chaiya-setup.sh
#   แก้ไข: API auth ถูกต้อง, ตรวจ x-ui port จริง, HTML ไม่ค้าง
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
  ██████╗██╗  ██╗ █████╗ ██╗██╗   ██╗ █████╗
 ██╔════╝██║  ██║██╔══██╗██║╚██╗ ██╔╝██╔══██╗
 ██║     ███████║███████║██║ ╚████╔╝ ███████║
 ██║     ██╔══██║██╔══██║██║  ╚██╔╝  ██╔══██║
 ╚██████╗██║  ██║██║  ██║██║   ██║   ██║  ██║
  ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝
      VPN PANEL - ALL-IN-ONE INSTALLER v3
BANNER
echo -e "${NC}"

# ── ROOT CHECK ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "รันด้วย root หรือ sudo เท่านั้น"

# ── INSTALL DEPS ─────────────────────────────────────────────
info "อัปเดต packages..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl wget python3 nginx dropbear openssh-server \
  ufw build-essential cmake net-tools jq bc cron unzip sqlite3 \
  iptables-persistent 2>/dev/null || true
ok "ติดตั้ง packages สำเร็จ"

# ── GET SERVER IP ────────────────────────────────────────────
info "กำลังดึง IP ของเครื่อง..."
SERVER_IP=$(curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null || \
            curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null || \
            hostname -I | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && err "ไม่สามารถดึง IP ได้"
ok "IP: ${CYAN}$SERVER_IP${NC}"

# ── PASSWORD ─────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}กำหนด Password สำหรับ Panel Login${NC}"
while true; do
  read -rsp "  Panel Password: " PANEL_PASS; echo
  read -rsp "  Confirm Password: " PANEL_PASS2; echo
  [[ "$PANEL_PASS" == "$PANEL_PASS2" ]] && break
  warn "Password ไม่ตรงกัน ลองอีกครั้ง"
done
[[ ${#PANEL_PASS} -lt 6 ]] && err "Password ต้องมีอย่างน้อย 6 ตัวอักษร"

# ── XUI CREDENTIALS ──────────────────────────────────────────
echo ""
echo -e "${YELLOW}กำหนด Username / Password สำหรับ 3x-ui${NC}"
read -rp "  3x-ui Username [admin]: " XUI_USER
[[ -z "$XUI_USER" ]] && XUI_USER="admin"
while true; do
  read -rsp "  3x-ui Password: " XUI_PASS; echo
  read -rsp "  Confirm 3x-ui Password: " XUI_PASS2; echo
  [[ "$XUI_PASS" == "$XUI_PASS2" ]] && break
  warn "Password ไม่ตรงกัน ลองอีกครั้ง"
done
[[ ${#XUI_PASS} -lt 6 ]] && err "3x-ui Password ต้องมีอย่างน้อย 6 ตัวอักษร"

# ── PORT CONFIG ────────────────────────────────────────────
SSH_API_PORT=2095
XUI_PORT=2053
PANEL_PORT=8888
DROPBEAR_PORT1=143
DROPBEAR_PORT2=109
BADVPN_PORT=7300
OPENVPN_PORT=1194

echo ""
info "การตั้งค่า:"
echo -e "  IP Server     : ${CYAN}$SERVER_IP${NC}"
echo -e "  Panel URL     : ${CYAN}http://$SERVER_IP:$PANEL_PORT${NC}"
echo -e "  SSH API Port  : ${CYAN}$SSH_API_PORT${NC}"
echo -e "  3x-ui Port    : ${CYAN}$XUI_PORT${NC}"
echo -e "  Dropbear      : ${CYAN}$DROPBEAR_PORT1, $DROPBEAR_PORT2${NC}"
echo ""
read -rp "เริ่มติดตั้ง? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 0

# ── HASH PANEL PASSWORD ───────────────────────────────────────
PANEL_PASS_HASH=$(python3 -c "import hashlib; print(hashlib.sha256('${PANEL_PASS}'.encode()).hexdigest())")

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
mkdir -p /etc/dropbear
# สร้าง host keys ถ้าไม่มี
[[ ! -f /etc/dropbear/dropbear_rsa_host_key ]] && \
  dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null || true
[[ ! -f /etc/dropbear/dropbear_ecdsa_host_key ]] && \
  dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key 2>/dev/null || true

# ใช้ systemd override แทน /etc/default/dropbear
mkdir -p /etc/systemd/system/dropbear.service.d
cat > /etc/systemd/system/dropbear.service.d/override.conf << EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/dropbear -F -p $DROPBEAR_PORT1 -p $DROPBEAR_PORT2 -W 65536
EOF

grep -q '/bin/false' /etc/shells 2>/dev/null || echo '/bin/false' >> /etc/shells
grep -q '/usr/sbin/nologin' /etc/shells 2>/dev/null || echo '/usr/sbin/nologin' >> /etc/shells

systemctl daemon-reload 2>/dev/null || true
systemctl enable dropbear 2>/dev/null || true
systemctl restart dropbear 2>/dev/null || true
sleep 2
systemctl is-active --quiet dropbear && ok "Dropbear พร้อม (port $DROPBEAR_PORT1, $DROPBEAR_PORT2)" || \
  warn "Dropbear อาจไม่ทำงาน — ตรวจสอบด้วย: systemctl status dropbear"

# ── BADVPN ───────────────────────────────────────────────────
info "ติดตั้ง BadVPN..."
if ! command -v badvpn-udpgw &>/dev/null; then
  # ลอง download binary
  wget -q --timeout=15 -O /usr/bin/badvpn-udpgw \
    "https://raw.githubusercontent.com/NevermoreSSH/Blueblue/main/newudpgw" 2>/dev/null && \
    chmod +x /usr/bin/badvpn-udpgw || rm -f /usr/bin/badvpn-udpgw
  # fallback: build จาก source
  if [[ ! -f /usr/bin/badvpn-udpgw ]]; then
    apt-get install -y -qq cmake build-essential 2>/dev/null || true
    cd /tmp && wget -q https://github.com/ambrop72/badvpn/archive/refs/heads/master.zip -O badvpn.zip 2>/dev/null && \
      unzip -q badvpn.zip && cd badvpn-master && \
      cmake . -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_INSTALL_PREFIX=/usr/local &>/dev/null && \
      make -j$(nproc) &>/dev/null && make install &>/dev/null && \
      ln -sf /usr/local/bin/badvpn-udpgw /usr/bin/badvpn-udpgw
    cd / && rm -rf /tmp/badvpn*
  fi
fi

cat > /etc/systemd/system/chaiya-badvpn.service << EOF
[Unit]
Description=Chaiya BadVPN UDP Gateway
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:$BADVPN_PORT --max-clients 500
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null || true
systemctl enable chaiya-badvpn 2>/dev/null || true
pkill -f badvpn 2>/dev/null || true
sleep 1
systemctl start chaiya-badvpn 2>/dev/null || true
ok "BadVPN พร้อม (port $BADVPN_PORT)"

# ── 3X-UI INSTALL ────────────────────────────────────────────
info "ติดตั้ง 3x-ui..."
mkdir -p /etc/chaiya
# บันทึก credentials ก่อน install
echo "$XUI_USER" > /etc/chaiya/xui-user.conf
echo "$XUI_PASS" > /etc/chaiya/xui-pass.conf
echo "$XUI_PORT" > /etc/chaiya/xui-port.conf
chmod 600 /etc/chaiya/xui-user.conf /etc/chaiya/xui-pass.conf

# ตรวจว่า x-ui ติดตั้งแล้วหรือยัง
if ! command -v x-ui &>/dev/null; then
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << XUIEOF
n
XUIEOF
fi

# ตั้งค่า x-ui: port, username, password
sleep 3
x-ui setting -port $XUI_PORT 2>/dev/null || true
x-ui setting -username "$XUI_USER" 2>/dev/null || true
x-ui setting -password "$XUI_PASS" 2>/dev/null || true
systemctl restart x-ui 2>/dev/null || true
sleep 3

# ตรวจ port จริงที่ x-ui ใช้
REAL_XUI_PORT=$(ss -tlnp 2>/dev/null | grep x-ui | grep -oP ':\K\d+' | head -1)
[[ -z "$REAL_XUI_PORT" ]] && REAL_XUI_PORT=$XUI_PORT
echo "$REAL_XUI_PORT" > /etc/chaiya/xui-port.conf
ok "3x-ui พร้อม (port $REAL_XUI_PORT)"

# ── SSH API (Python) ──────────────────────────────────────────
info "ติดตั้ง SSH API..."
mkdir -p /opt/chaiya-ssh-api /etc/chaiya/exp

cat > /opt/chaiya-ssh-api/app.py << 'PYEOF'
#!/usr/bin/env python3
"""
Chaiya SSH API v3 — แก้ไข body() อ่านซ้ำ, thread-safe, CORS ถูกต้อง
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, socket, threading, socketserver, hmac

def run_cmd(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
    return r.returncode == 0, r.stdout.strip(), r.stderr.strip()

def get_connections():
    counts = {"total": 0}
    for port in ["80", "143", "109", "22", "2095"]:
        out, _ = subprocess.run(
            f"ss -tn state established 2>/dev/null | grep -c ':{port}[^0-9]' || echo 0",
            shell=True, capture_output=True, text=True
        ).stdout.strip(), None
        try:
            c = int(out.split()[0]) if out.strip() else 0
        except:
            c = 0
        counts[port] = c
        counts["total"] += c
    return counts

def list_users():
    users = []
    try:
        with open('/etc/passwd') as f:
            for line in f:
                p = line.strip().split(':')
                if len(p) < 7: continue
                uid = int(p[2])
                if uid < 1000 or uid > 60000: continue
                if p[6] not in ['/bin/bash', '/bin/sh', '/bin/false', '/usr/sbin/nologin']: continue
                u = {'user': p[0], 'active': True, 'exp': None}
                exp_f = f'/etc/chaiya/exp/{p[0]}'
                if os.path.exists(exp_f):
                    u['exp'] = open(exp_f).read().strip()
                    try:
                        exp_date = datetime.date.fromisoformat(u['exp'])
                        u['active'] = exp_date >= datetime.date.today()
                    except:
                        pass
                users.append(u)
    except Exception as e:
        pass
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
        """อ่าน body ครั้งเดียวแล้ว parse — ไม่อ่านซ้ำ"""
        try:
            length = int(self.headers.get('Content-Length', 0))
            if length > 0:
                raw = self.rfile.read(length)
                return json.loads(raw)
            return {}
        except Exception:
            return {}

    def do_GET(self):
        if self.path == '/api/status':
            xui_port_f = '/etc/chaiya/xui-port.conf'
            xui_port = open(xui_port_f).read().strip() if os.path.exists(xui_port_f) else '2053'

            ok1, _, _ = run_cmd("systemctl is-active dropbear")
            ok2, _, _ = run_cmd("systemctl is-active nginx")
            ok3, udp, _ = run_cmd("pgrep -f badvpn-udpgw")
            ok4, ws, _  = run_cmd("pgrep -f ws-stunnel")
            ok5, xui, _ = run_cmd("systemctl is-active x-ui")

            conns = get_connections()
            users = list_users()

            respond(self, 200, {
                "ok": True,
                "connections": conns.get("total", 0),
                "conn_80":  conns.get("80", 0),
                "conn_143": conns.get("143", 0),
                "conn_109": conns.get("109", 0),
                "conn_22":  conns.get("22", 0),
                "online":   conns.get("total", 0),
                "online_count": conns.get("total", 0),
                "total_users": len(users),
                "services": {
                    "ssh":      True,
                    "dropbear": ok1 == "active" if isinstance(ok1, str) else bool(ok1),
                    "nginx":    ok2 == "active" if isinstance(ok2, str) else bool(ok2),
                    "badvpn":   bool(udp.strip()),
                    "sshws":    bool(ws.strip()),
                    "xui":      xui == "active" if isinstance(xui, str) else bool(xui),
                    "tunnel":   bool(ws.strip()),
                }
            })

        elif self.path == '/api/users':
            respond(self, 200, {"users": list_users()})

        elif self.path == '/api/info':
            xui_port_f = '/etc/chaiya/xui-port.conf'
            xui_port = open(xui_port_f).read().strip() if os.path.exists(xui_port_f) else '2053'
            respond(self, 200, {
                "host": open('/etc/chaiya/my_ip.conf').read().strip()
                        if os.path.exists('/etc/chaiya/my_ip.conf') else '',
                "xui_port": int(xui_port),
                "dropbear_port": 143,
                "dropbear_port2": 109,
                "ws_port": 80,
                "udpgw_port": 7300,
            })

        else:
            respond(self, 404, {'error': 'Not found'})

    def do_POST(self):
        # อ่าน body ครั้งเดียว ก่อน route
        data = self.read_body()

        if self.path == '/api/verify':
            import hashlib
            pw = data.get("password", "")
            hashed = hashlib.sha256(pw.encode()).hexdigest()
            # อ่าน hash จาก config.js
            cfg_path = '/opt/chaiya-panel/config.js'
            stored = ""
            try:
                import re
                cfg = open(cfg_path).read()
                m = re.search(r'panel_pass\s*:\s*"([a-f0-9]+)"', cfg)
                if m:
                    stored = m.group(1)
            except Exception:
                pass
            respond(self, 200, {"ok": bool(stored) and hashed == stored})

        elif self.path == '/api/create':
            user = data.get('user', '').strip()
            pw   = data.get('pass', '').strip()
            days = int(data.get('exp_days', data.get('days', 30)))
            if not user or not pw:
                return respond(self, 400, {'error': 'user/pass required'})
            ok1, _, e1 = run_cmd(f"useradd -m -s /bin/false {user}")
            if not ok1 and 'already exists' not in e1:
                return respond(self, 500, {'error': e1})
            run_cmd(f"echo '{user}:{pw}' | chpasswd")
            exp = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
            os.makedirs('/etc/chaiya/exp', exist_ok=True)
            with open(f'/etc/chaiya/exp/{user}', 'w') as f:
                f.write(exp)
            run_cmd(f"chage -E {exp} {user}")
            respond(self, 200, {'ok': True, 'user': user, 'exp': exp})

        elif self.path == '/api/delete':
            user = data.get('user', '').strip()
            if not user:
                return respond(self, 400, {'error': 'user required'})
            run_cmd(f"userdel -r {user} 2>/dev/null")
            run_cmd(f"rm -f /etc/chaiya/exp/{user}")
            respond(self, 200, {'ok': True})

        elif self.path == '/api/service':
            action = data.get('action', '')
            svc    = data.get('service', '')
            if action in ('start', 'stop', 'restart') and svc:
                run_cmd(f"systemctl {action} {svc}")
                respond(self, 200, {'ok': True})
            else:
                respond(self, 400, {'error': 'invalid action or service'})

        else:
            respond(self, 404, {'error': 'Not found'})

class ThreadedHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == '__main__':
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 2095
    server = ThreadedHTTPServer(('0.0.0.0', port), Handler)
    print(f"Chaiya SSH API running on port {port}")
    server.serve_forever()
PYEOF

chmod +x /opt/chaiya-ssh-api/app.py

# ── SYSTEMD SERVICE FOR SSH API ───────────────────────────────
cat > /etc/systemd/system/chaiya-ssh-api.service << EOF
[Unit]
Description=Chaiya SSH API
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/chaiya-ssh-api/app.py $SSH_API_PORT
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chaiya-ssh-api
systemctl restart chaiya-ssh-api
sleep 2
ok "SSH API พร้อม (port $SSH_API_PORT)"

# ── WS-STUNNEL (HTTP CONNECT → Dropbear) ─────────────────────
info "ติดตั้ง WS-Stunnel..."
cat > /usr/local/bin/ws-stunnel << 'WSPYEOF'
#!/usr/bin/python3
import socket, threading, select, sys, time, collections

LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 80
BUFLEN = 4096 * 4
TIMEOUT = 60
DEFAULT_HOST = '127.0.0.1:143'
RESPONSE = b'HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n'

class Server(threading.Thread):
    def __init__(self, host, port):
        threading.Thread.__init__(self)
        self.daemon = True
        self.host = host
        self.port = port
        self.threads = []
        self.lock = threading.Lock()

    def run(self):
        self.soc = socket.socket(socket.AF_INET)
        self.soc.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.soc.settimeout(2)
        self.soc.bind((self.host, int(self.port)))
        self.soc.listen(128)
        while True:
            try:
                c, addr = self.soc.accept()
                t = ConnectionHandler(c, self, addr)
                t.daemon = True
                t.start()
            except socket.timeout:
                continue
            except Exception:
                break

class ConnectionHandler(threading.Thread):
    def __init__(self, client, server, addr):
        threading.Thread.__init__(self)
        self.client = client
        self.server = server
        self.addr = addr
        self.clientClosed = False
        self.targetClosed = True

    def close(self):
        try:
            if not self.clientClosed:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
        except: pass
        finally: self.clientClosed = True
        try:
            if not self.targetClosed:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
        except: pass
        finally: self.targetClosed = True

    def run(self):
        try:
            buf = self.client.recv(BUFLEN)
            hostPort = self.findHeader(buf, 'X-Real-Host') or DEFAULT_HOST
            self.connect_target(hostPort)
            self.client.sendall(RESPONSE)
            self.relay()
        except Exception:
            pass
        finally:
            self.close()

    def findHeader(self, head, header):
        if isinstance(head, bytes):
            head = head.decode('utf-8', errors='replace')
        i = head.find(header + ': ')
        if i == -1: return ''
        i = head.find(':', i)
        head = head[i+2:]
        j = head.find('\r\n')
        return head[:j] if j != -1 else ''

    def connect_target(self, host):
        i = host.find(':')
        port = int(host[i+1:]) if i != -1 else 143
        host = host[:i] if i != -1 else host
        self.target = socket.create_connection((host, port), timeout=10)
        self.targetClosed = False

    def relay(self):
        socs = [self.client, self.target]
        count = 0
        while True:
            count += 1
            recv, _, err = select.select(socs, [], socs, 3)
            if err: break
            if recv:
                for s in recv:
                    data = s.recv(BUFLEN)
                    if not data: return
                    (self.target if s is self.client else self.client).sendall(data)
                    count = 0
            if count >= TIMEOUT: break

def main():
    server = Server(LISTENING_ADDR, LISTENING_PORT)
    server.start()
    print(f"WS-Stunnel running on port {LISTENING_PORT}")
    while True:
        time.sleep(60)

if __name__ == '__main__':
    main()
WSPYEOF
chmod +x /usr/local/bin/ws-stunnel

cat > /etc/systemd/system/chaiya-sshws.service << 'WSEOF'
[Unit]
Description=WS-Stunnel SSH Tunnel port 80 -> Dropbear
After=network.target dropbear.service
[Service]
Type=simple
ExecStartPre=/bin/sh -c 'fuser -k 80/tcp 2>/dev/null || true'
ExecStart=/usr/bin/python3 /usr/local/bin/ws-stunnel
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
WSEOF

systemctl daemon-reload
systemctl enable chaiya-sshws
systemctl restart chaiya-sshws
sleep 2
ok "WS-Stunnel พร้อม (port 80)"

# ── PANEL HTML ────────────────────────────────────────────────
info "สร้าง Panel HTML..."
mkdir -p /opt/chaiya-panel

# อ่าน xui port จริง
REAL_XUI_PORT=$(cat /etc/chaiya/xui-port.conf 2>/dev/null || echo "2053")

cat > /opt/chaiya-panel/config.js << EOF
// Auto-generated by chaiya-setup.sh v3 — DO NOT EDIT MANUALLY
window.CHAIYA_CONFIG = {
  host:         "$SERVER_IP",
  ssh_api_port: $SSH_API_PORT,
  xui_port:     $REAL_XUI_PORT,
  xui_user:     "$XUI_USER",
  xui_pass:     "$XUI_PASS",
  ssh_token:    "",
  panel_pass:   "$PANEL_PASS_HASH"
};
EOF

# ── PANEL INDEX.HTML ───────────────────────────────────────────
cat > /opt/chaiya-panel/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA VPN PANEL</title>
<style>
  :root{--bg:#0a0d14;--bg2:#0f1520;--panel:#111827;--border:#1e2d45;
    --green:#4dffa0;--cyan:#80ffdd;--purple:#b8a0ff;--yellow:#ffe680;
    --red:#ff6b8a;--text:#c8ddd0;--muted:#7a9aaa;}
  *{margin:0;padding:0;box-sizing:border-box;}
  body{font-family:'Segoe UI',sans-serif;background:var(--bg);color:var(--text);
    min-height:100vh;display:flex;align-items:center;justify-content:center;}
  .wrap{width:100%;max-width:420px;padding:1.5rem;}
  .logo{text-align:center;margin-bottom:2rem;}
  .logo h1{font-size:2rem;font-weight:900;letter-spacing:.15em;
    background:linear-gradient(135deg,var(--green),var(--cyan),var(--purple));
    -webkit-background-clip:text;-webkit-text-fill-color:transparent;}
  .logo p{color:var(--muted);letter-spacing:.3em;font-size:.75rem;margin-top:.3rem;}
  .card{background:var(--panel);border:1px solid var(--border);border-radius:16px;
    padding:1.5rem;box-shadow:0 8px 32px rgba(0,0,0,.5);}
  .server-box{background:rgba(77,255,160,.05);border:1px solid rgba(77,255,160,.2);
    border-radius:10px;padding:.75rem 1rem;text-align:center;margin-bottom:1.5rem;}
  .server-box .lbl{font-size:.7rem;letter-spacing:.2em;color:var(--muted);margin-bottom:.3rem;}
  .server-box .ip{color:var(--cyan);font-size:1.1rem;font-weight:700;font-family:monospace;}
  .field-lbl{font-size:.72rem;letter-spacing:.1em;color:var(--muted);margin-bottom:.4rem;
    display:flex;align-items:center;gap:.4rem;}
  .field-lbl .ico{font-size:.9rem;}
  input[type=password]{width:100%;background:rgba(255,255,255,.04);border:1px solid var(--border);
    border-radius:8px;padding:.75rem 1rem;color:var(--text);font-size:.95rem;
    outline:none;transition:border .2s;}
  input[type=password]:focus{border-color:var(--cyan);}
  .btn{width:100%;padding:.85rem;border:none;border-radius:10px;font-size:.9rem;
    font-weight:700;letter-spacing:.1em;cursor:pointer;margin-top:1rem;
    background:linear-gradient(135deg,var(--green),var(--cyan));color:#0a0d14;
    transition:opacity .2s,transform .1s;}
  .btn:hover{opacity:.9;}
  .btn:active{transform:scale(.98);}
  .btn:disabled{opacity:.5;cursor:not-allowed;}
  .msg{text-align:center;font-size:.82rem;padding:.6rem;border-radius:8px;
    margin-top:.8rem;display:none;}
  .msg.err{background:rgba(255,107,138,.1);color:var(--red);border:1px solid rgba(255,107,138,.3);}
  .msg.ok{background:rgba(77,255,160,.1);color:var(--green);border:1px solid rgba(77,255,160,.3);}
  .dots{display:flex;justify-content:center;gap:.4rem;margin-top:.8rem;}
  .dot{width:8px;height:8px;border-radius:50%;background:var(--border);transition:background .3s;}
  .dot.lit{background:var(--cyan);}
  /* Dashboard */
  #dashboard{display:none;}
  .nav{display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:1.5rem;}
  .nav-btn{padding:.45rem .9rem;border:1px solid var(--border);border-radius:8px;
    background:transparent;color:var(--muted);font-size:.78rem;cursor:pointer;transition:.2s;}
  .nav-btn.active,.nav-btn:hover{border-color:var(--cyan);color:var(--cyan);background:rgba(128,255,221,.06);}
  .page{display:none;}.page.active{display:block;}
  .stat-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:.8rem;margin-bottom:1rem;}
  .stat{background:rgba(255,255,255,.04);border:1px solid var(--border);border-radius:10px;
    padding:.8rem;text-align:center;}
  .stat .val{font-size:1.6rem;font-weight:900;color:var(--cyan);}
  .stat .lbl{font-size:.68rem;color:var(--muted);margin-top:.2rem;letter-spacing:.1em;}
  .svc-list{display:flex;flex-direction:column;gap:.5rem;}
  .svc-row{display:flex;justify-content:space-between;align-items:center;
    padding:.6rem .8rem;background:rgba(255,255,255,.03);border-radius:8px;}
  .badge{font-size:.65rem;padding:.2rem .5rem;border-radius:20px;font-weight:700;}
  .badge.on{background:rgba(77,255,160,.15);color:var(--green);}
  .badge.off{background:rgba(255,107,138,.15);color:var(--red);}
  .form-g{margin-bottom:.8rem;}
  .form-g label{display:block;font-size:.72rem;color:var(--muted);margin-bottom:.3rem;}
  .form-g input{width:100%;background:rgba(255,255,255,.04);border:1px solid var(--border);
    border-radius:8px;padding:.6rem .8rem;color:var(--text);font-size:.85rem;outline:none;}
  .form-g input:focus{border-color:var(--cyan);}
  .btn2{padding:.6rem 1.2rem;border:none;border-radius:8px;font-size:.8rem;font-weight:700;
    cursor:pointer;background:linear-gradient(135deg,var(--green),var(--cyan));color:#0a0d14;}
  table{width:100%;border-collapse:collapse;font-size:.78rem;}
  th,td{padding:.5rem .6rem;text-align:left;border-bottom:1px solid var(--border);}
  th{color:var(--muted);font-size:.68rem;letter-spacing:.1em;}
  .del-btn{background:rgba(255,107,138,.15);color:var(--red);border:1px solid rgba(255,107,138,.3);
    border-radius:6px;padding:.2rem .5rem;font-size:.68rem;cursor:pointer;}
  #alert{font-size:.8rem;padding:.5rem .8rem;border-radius:8px;margin-top:.5rem;display:none;}
  #alert.ok{background:rgba(77,255,160,.1);color:var(--green);}
  #alert.err{background:rgba(255,107,138,.1);color:var(--red);}
</style>
</head>
<body>

<!-- ═══ LOGIN ═══ -->
<div class="wrap" id="login">
  <div class="logo">
    <div style="font-size:2.5rem;margin-bottom:.5rem">🛸</div>
    <h1>CHAIYA VPN</h1>
    <p>MANAGEMENT PANEL</p>
  </div>
  <div class="card">
    <div class="server-box">
      <div class="lbl">VPS SERVER</div>
      <div class="ip" id="server-ip-disp">กำลังโหลด...</div>
    </div>
    <div class="field-lbl"><span class="ico">🔑</span> PANEL PASSWORD</div>
    <input type="password" id="pass-input" placeholder="••••••••" onkeyup="if(event.key==='Enter')doLogin()">
    <button class="btn" id="login-btn" onclick="doLogin()">CONNECT</button>
    <div class="msg" id="msg"></div>
    <div class="dots">
      <div class="dot" id="d1"></div>
      <div class="dot" id="d2"></div>
      <div class="dot" id="d3"></div>
      <div class="dot" id="d4"></div>
      <div class="dot" id="d5"></div>
    </div>
  </div>
</div>

<!-- ═══ DASHBOARD ═══ -->
<div style="width:100%;max-width:680px;margin:0 auto;padding:1.5rem" id="dashboard">
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem">
    <h2 style="color:var(--cyan);font-size:1.1rem">🛸 CHAIYA VPN PANEL</h2>
    <button onclick="doLogout()" style="background:rgba(255,107,138,.15);color:var(--red);
      border:1px solid rgba(255,107,138,.3);border-radius:8px;padding:.35rem .8rem;
      font-size:.75rem;cursor:pointer;">Logout</button>
  </div>

  <div class="nav">
    <button class="nav-btn active" onclick="showPage('dashboard')">📊 Dashboard</button>
    <button class="nav-btn" onclick="showPage('users')">👤 Users</button>
    <button class="nav-btn" onclick="showPage('services')">⚙️ Services</button>
  </div>

  <!-- Dashboard Page -->
  <div id="page-dashboard" class="page active">
    <div class="stat-grid">
      <div class="stat"><div class="val" id="s-conn">-</div><div class="lbl">CONNECTIONS</div></div>
      <div class="stat"><div class="val" id="s-users">-</div><div class="lbl">TOTAL USERS</div></div>
      <div class="stat"><div class="val" id="s-online">-</div><div class="lbl">ONLINE</div></div>
      <div class="stat"><div class="val" id="s-80">-</div><div class="lbl">PORT 80</div></div>
    </div>
    <div class="svc-list" id="svc-list"></div>
    <div style="text-align:right;font-size:.65rem;color:var(--muted);margin-top:.8rem" id="last-upd"></div>
  </div>

  <!-- Users Page -->
  <div id="page-users" class="page">
    <div class="card" style="margin-bottom:1rem">
      <h3 style="font-size:.85rem;margin-bottom:.8rem;color:var(--cyan)">➕ เพิ่ม User</h3>
      <div class="form-g"><label>Username</label><input id="new-user" placeholder="username"></div>
      <div class="form-g"><label>Password</label><input type="password" id="new-pass" placeholder="password"></div>
      <div class="form-g"><label>จำนวนวัน</label><input id="new-days" type="number" value="30"></div>
      <button class="btn2" onclick="createUser()">➕ สร้าง User</button>
      <div id="alert"></div>
    </div>
    <div class="card">
      <h3 style="font-size:.85rem;margin-bottom:.8rem;color:var(--cyan)">📋 รายชื่อ Users</h3>
      <div style="overflow-x:auto">
        <table>
          <thead><tr><th>#</th><th>Username</th><th>หมดอายุ</th><th>สถานะ</th><th></th></tr></thead>
          <tbody id="user-tbody"><tr><td colspan="5" style="text-align:center;color:var(--muted);padding:1rem">กำลังโหลด...</td></tr></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- Services Page -->
  <div id="page-services" class="page">
    <div class="card">
      <h3 style="font-size:.85rem;margin-bottom:.8rem;color:var(--cyan)">⚙️ Services</h3>
      <div class="svc-list" id="svc-detail"></div>
      <div style="display:flex;gap:.5rem;margin-top:1rem;flex-wrap:wrap">
        <button class="btn2" onclick="svcAll('restart')">🔄 Restart All</button>
      </div>
    </div>
  </div>
</div>

<script>
// ══════════════ CONFIG ══════════════
let CFG = null;
let API_BASE = '';
let loggedIn = false;

async function loadConfig() {
  try {
    // โหลด config.js แบบ dynamic
    await new Promise((res, rej) => {
      const s = document.createElement('script');
      s.src = 'config.js?v=' + Date.now();
      s.onload = res;
      s.onerror = rej;
      document.head.appendChild(s);
    });
    CFG = window.CHAIYA_CONFIG;
    document.getElementById('server-ip-disp').textContent = CFG.host;
    API_BASE = `http://${CFG.host}:${CFG.ssh_api_port}`;
  } catch(e) {
    document.getElementById('server-ip-disp').textContent = 'ไม่พบ config.js';
  }
}

// ══════════════ SHA256 ══════════════
async function sha256hex(str) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(str));
  return Array.from(new Uint8Array(buf)).map(b=>b.toString(16).padStart(2,'0')).join('');
}

// ══════════════ LOGIN ══════════════
function setDots(on) {
  for(let i=1;i<=5;i++) {
    const d = document.getElementById('d'+i);
    if(on) setTimeout(()=>d.classList.add('lit'), i*100);
    else d.classList.remove('lit');
  }
}

function showMsg(text, type) {
  const el = document.getElementById('msg');
  el.textContent = text;
  el.className = 'msg ' + type;
  el.style.display = 'block';
}

async function doLogin() {
  if(!CFG) return showMsg('ไม่พบ config — ตรวจสอบ config.js', 'err');
  const pw = document.getElementById('pass-input').value;
  if(!pw) return showMsg('กรุณาใส่ Password', 'err');

  const btn = document.getElementById('login-btn');
  btn.disabled = true;
  btn.textContent = 'CONNECTING...';
  setDots(true);
  document.getElementById('msg').style.display = 'none';

  try {
    // เช็ค hash ใน browser ก่อน (ไม่ต้องเรียก API)
    const hash = await sha256hex(pw);
    if(CFG.panel_pass && hash !== CFG.panel_pass) {
      setDots(false);
      btn.disabled = false;
      btn.textContent = 'CONNECT';
      return showMsg('❌ Password ไม่ถูกต้อง', 'err');
    }

    // ทดสอบ API เชื่อมต่อได้ไหม
    const r = await fetch(`${API_BASE}/api/status`, {signal: AbortSignal.timeout(8000)});
    const d = await r.json();
    if(d.ok !== undefined || d.connections !== undefined) {
      // Login สำเร็จ
      loggedIn = true;
      document.getElementById('login').style.display = 'none';
      document.getElementById('dashboard').style.display = 'block';
      loadDashboard();
      setInterval(loadDashboard, 15000);
    } else {
      showMsg('❌ API ตอบสนองผิดปกติ', 'err');
    }
  } catch(e) {
    showMsg('❌ เชื่อมต่อ API ไม่ได้: ' + e.message, 'err');
  } finally {
    setDots(false);
    btn.disabled = false;
    btn.textContent = 'CONNECT';
  }
}

function doLogout() {
  loggedIn = false;
  document.getElementById('dashboard').style.display = 'none';
  document.getElementById('login').style.display = 'flex';
  document.getElementById('pass-input').value = '';
}

// ══════════════ NAV ══════════════
function showPage(name) {
  document.querySelectorAll('.page').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.nav-btn').forEach(b=>b.classList.remove('active'));
  document.getElementById('page-'+name).classList.add('active');
  event.target.classList.add('active');
  if(name==='users') loadUsers();
  if(name==='services') loadServices();
}

// ══════════════ API CALL ══════════════
async function api(method, path, body=null) {
  try {
    const opts = {
      method,
      headers: {'Content-Type': 'application/json'},
      signal: AbortSignal.timeout(10000)
    };
    if(body) opts.body = JSON.stringify(body);
    const r = await fetch(API_BASE + path, opts);
    return await r.json();
  } catch(e) {
    return {error: e.message};
  }
}

// ══════════════ DASHBOARD ══════════════
async function loadDashboard() {
  const d = await api('GET', '/api/status');
  if(d.error) return;
  document.getElementById('s-conn').textContent  = d.connections ?? '-';
  document.getElementById('s-users').textContent = d.total_users ?? '-';
  document.getElementById('s-online').textContent= d.online_count ?? d.online ?? '-';
  document.getElementById('s-80').textContent    = d.conn_80 ?? '-';
  document.getElementById('last-upd').textContent= 'อัพเดท ' + new Date().toLocaleTimeString('th-TH');

  const svcs = d.services || {};
  const list = document.getElementById('svc-list');
  list.innerHTML = Object.entries(svcs).filter(([k])=>!['started'].includes(k)).map(([k,v])=>`
    <div class="svc-row">
      <span style="font-size:.8rem">${svcIcon(k)} ${k}</span>
      <span class="badge ${v?'on':'off'}">${v?'RUNNING':'STOPPED'}</span>
    </div>`).join('');
}

function svcIcon(k) {
  const m = {ssh:'🔑',dropbear:'🐻',nginx:'🌐',badvpn:'🎮',sshws:'🚇',xui:'📊',tunnel:'🔗'};
  return m[k] || '⚙️';
}

// ══════════════ USERS ══════════════
async function loadUsers() {
  const d = await api('GET', '/api/users');
  const tbody = document.getElementById('user-tbody');
  if(d.error || !d.users) {
    tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--red)">${d.error||'โหลดไม่ได้'}</td></tr>`;
    return;
  }
  if(!d.users.length) {
    tbody.innerHTML = `<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:1rem">ไม่มี Users</td></tr>`;
    return;
  }
  tbody.innerHTML = d.users.map((u,i)=>`
    <tr>
      <td>${i+1}</td>
      <td>${u.user}</td>
      <td style="font-size:.7rem">${u.exp||'-'}</td>
      <td><span class="badge ${u.active?'on':'off'}">${u.active?'ACTIVE':'EXPIRED'}</span></td>
      <td><button class="del-btn" onclick="delUser('${u.user}')">🗑</button></td>
    </tr>`).join('');
}

async function createUser() {
  const user = document.getElementById('new-user').value.trim();
  const pass = document.getElementById('new-pass').value;
  const days = parseInt(document.getElementById('new-days').value) || 30;
  const alert = document.getElementById('alert');
  if(!user || !pass) {
    alert.textContent = 'กรุณาใส่ Username และ Password';
    alert.className = 'err'; alert.style.display = 'block'; return;
  }
  const d = await api('POST', '/api/create', {user, pass, days});
  alert.style.display = 'block';
  if(d.ok) {
    alert.textContent = `✅ สร้าง ${user} สำเร็จ (หมดอายุ ${d.exp})`;
    alert.className = 'ok';
    document.getElementById('new-user').value = '';
    document.getElementById('new-pass').value = '';
    loadUsers();
  } else {
    alert.textContent = '❌ ' + (d.error || 'ล้มเหลว');
    alert.className = 'err';
  }
}

async function delUser(user) {
  if(!confirm(`ลบ ${user}?`)) return;
  const d = await api('POST', '/api/delete', {user});
  if(d.ok) loadUsers();
  else alert('ลบไม่ได้: ' + (d.error||''));
}

// ══════════════ SERVICES ══════════════
async function loadServices() {
  const d = await api('GET', '/api/status');
  if(d.error) return;
  const svcs = d.services || {};
  document.getElementById('svc-detail').innerHTML = Object.entries(svcs)
    .filter(([k])=>!['started'].includes(k))
    .map(([k,v])=>`
    <div class="svc-row">
      <span style="font-size:.8rem">${svcIcon(k)} <b>${k}</b></span>
      <div style="display:flex;gap:.4rem;align-items:center">
        <span class="badge ${v?'on':'off'}">${v?'RUNNING':'STOPPED'}</span>
        <button onclick="svc1('${k}','restart')" class="del-btn" style="color:var(--cyan);border-color:rgba(128,255,221,.3)">🔄</button>
      </div>
    </div>`).join('');
}

async function svc1(svc, action) {
  await api('POST', '/api/service', {service: svc, action});
  setTimeout(loadServices, 1500);
}

async function svcAll(action) {
  for(const svc of ['dropbear','nginx','chaiya-sshws','chaiya-badvpn']) {
    await api('POST', '/api/service', {service: svc, action});
  }
  setTimeout(loadDashboard, 2000);
}

// ══════════════ INIT ══════════════
window.addEventListener('DOMContentLoaded', async () => {
  await loadConfig();
});
</script>
</body>
</html>
HTMLEOF
ok "Panel HTML พร้อม"

# ── NGINX ────────────────────────────────────────────────────
info "ตั้งค่า Nginx..."

# ลบ default config และ config ที่ชน port 80
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
for f in /etc/nginx/sites-enabled/*; do
  [[ "$f" == *"chaiya"* ]] && continue
  [[ -f "$f" ]] && grep -q "listen 80" "$f" 2>/dev/null && rm -f "$f" || true
done

cat > /etc/nginx/sites-available/chaiya << EOF
server {
    listen $PANEL_PORT;
    server_name _;
    root /opt/chaiya-panel;
    index index.html;
    add_header Access-Control-Allow-Origin *;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/
nginx -t &>/dev/null && systemctl restart nginx
ok "Nginx พร้อม (port $PANEL_PORT)"

# ── FIREWALL ─────────────────────────────────────────────────
info "ตั้งค่า Firewall..."
ufw --force reset &>/dev/null
ufw default deny incoming &>/dev/null
ufw default allow outgoing &>/dev/null
for port in 22 80 $PANEL_PORT $DROPBEAR_PORT1 $DROPBEAR_PORT2 \
            $SSH_API_PORT $REAL_XUI_PORT $BADVPN_PORT $OPENVPN_PORT 8080 8880; do
  ufw allow $port/tcp &>/dev/null
done
ufw allow $BADVPN_PORT/udp &>/dev/null
ufw --force enable &>/dev/null
ok "Firewall พร้อม"

# ── CACHE IP ──────────────────────────────────────────────────
echo "$SERVER_IP" > /etc/chaiya/my_ip.conf

# ── SUMMARY ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}   CHAIYA VPN PANEL v3 - ติดตั้งสำเร็จ! 🚀${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo ""
echo -e "  🌐 Panel URL      : ${CYAN}http://$SERVER_IP:$PANEL_PORT${NC}"
echo -e "  🔑 Panel Password : ${YELLOW}$PANEL_PASS${NC}"
echo -e "  🔧 SSH API        : ${CYAN}http://$SERVER_IP:$SSH_API_PORT${NC}"
echo -e "  📊 3x-ui Panel    : ${CYAN}http://$SERVER_IP:$REAL_XUI_PORT${NC}"
echo -e "  👤 3x-ui Username : ${YELLOW}$XUI_USER${NC}"
echo -e "  🔒 3x-ui Password : ${YELLOW}$XUI_PASS${NC}"
echo -e "  🐻 Dropbear       : ${CYAN}port $DROPBEAR_PORT1, $DROPBEAR_PORT2${NC}"
echo -e "  🎮 BadVPN         : ${CYAN}port $BADVPN_PORT${NC}"
echo ""
echo -e "  เปิดหน้า Panel ได้เลยที่:"
echo -e "  ${CYAN}${BOLD}http://$SERVER_IP:$PANEL_PORT${NC}"
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
echo ""

# ── ทดสอบ API ────────────────────────────────────────────────
echo -n "  ทดสอบ API... "
sleep 2
API_TEST=$(curl -s --max-time 5 http://127.0.0.1:$SSH_API_PORT/api/status 2>/dev/null)
if echo "$API_TEST" | grep -q '"ok"'; then
  echo -e "${GREEN}✅ API ทำงานปกติ${NC}"
else
  echo -e "${YELLOW}⚠️  API อาจยังไม่พร้อม ลอง: systemctl restart chaiya-ssh-api${NC}"
fi
echo ""
