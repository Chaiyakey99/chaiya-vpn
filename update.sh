#!/bin/bash
cat > /opt/chaiya-ssh-api/app.py << 'APPEOF'
#!/usr/bin/env python3
"""Chaiya SSH API v5 — domain support, no port in links"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, subprocess, os, datetime, socket, threading, socketserver, hmac, uuid, sqlite3, base64

XUI_DB = '/etc/x-ui/x-ui.db'

def run_cmd(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
    return r.returncode == 0, r.stdout.strip(), r.stderr.strip()

def get_host():
    domain_f = '/etc/chaiya/domain.conf'
    ip_f = '/etc/chaiya/my_ip.conf'
    if os.path.exists(domain_f):
        return open(domain_f).read().strip()
    if os.path.exists(ip_f):
        return open(ip_f).read().strip()
    return ''

def get_xui_clients():
    try:
        con = sqlite3.connect(XUI_DB)
        row = con.execute("SELECT settings FROM inbounds WHERE port=8080").fetchone()
        con.close()
        if not row: return []
        return json.loads(row[0]).get('clients', [])
    except: return []

def add_xui_client(email, user_uuid=None):
    if user_uuid is None:
        user_uuid = str(uuid.uuid4())
    try:
        con = sqlite3.connect(XUI_DB)
        row = con.execute("SELECT id, settings FROM inbounds WHERE port=8080").fetchone()
        if not row: con.close(); return None
        inbound_id, settings_str = row
        settings = json.loads(settings_str)
        clients = [c for c in settings.get('clients', []) if c.get('email') != email]
        clients.append({'id': user_uuid, 'alterId': 0, 'email': email,
                        'limitIpCount': 2, 'totalGB': 0, 'expiryTime': 0,
                        'enable': True, 'tgId': '', 'subId': ''})
        settings['clients'] = clients
        con.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(settings), inbound_id))
        con.commit(); con.close()
        return user_uuid
    except: return None

def remove_xui_client(email):
    for port in (8080, 8880):
        try:
            con = sqlite3.connect(XUI_DB)
            row = con.execute("SELECT id, settings FROM inbounds WHERE port=?", (port,)).fetchone()
            if not row: con.close(); continue
            inbound_id, settings_str = row
            settings = json.loads(settings_str)
            settings['clients'] = [c for c in settings.get('clients', []) if c.get('email') != email]
            con.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(settings), inbound_id))
            con.commit(); con.close()
        except: pass
    subprocess.run("systemctl restart x-ui", shell=True, capture_output=True, timeout=15)

def build_npv_link(host, user_uuid, remark):
    # ใช้ domain + HTTPS port 443 (ไม่โชว์พอร์ต)
    ssh_config = {
        "server": host, "port": 443,
        "username": remark, "protocol": "ssh",
        "transport": "ws", "ws_path": "/",
        "tls": True, "remarks": remark
    }
    b64 = base64.b64encode(json.dumps(ssh_config).encode()).decode()
    return f"npvt-ssh://{b64}"

def get_connections():
    counts = {"total": 0}
    for port in ["80", "443", "143", "109", "22", "2095", "8080", "8880"]:
        out = subprocess.run(
            f"ss -tn state established 2>/dev/null | grep -c ':{port}[^0-9]' || echo 0",
            shell=True, capture_output=True, text=True).stdout.strip()
        try: c = int(out.split()[0]) if out.strip() else 0
        except: c = 0
        counts[port] = c
        counts["total"] += c
    return counts

def list_users():
    users = []
    xui_clients = {c['email']: c['id'] for c in get_xui_clients()}
    db_map = {}
    db_path = '/etc/chaiya/sshws-users/users.db'
    if os.path.exists(db_path):
        for line in open(db_path):
            parts = line.strip().split()
            if len(parts) >= 3:
                db_map[parts[0]] = {
                    'days':     int(parts[1]) if len(parts) > 1 else 30,
                    'exp':      parts[2]      if len(parts) > 2 else '',
                    'data_gb':  int(parts[3]) if len(parts) > 3 else 0,
                    'ip_limit': int(parts[4]) if len(parts) > 4 else 2,
                }
    try:
        with open('/etc/passwd') as f:
            for line in f:
                p = line.strip().split(':')
                if len(p) < 7: continue
                uid = int(p[2])
                if uid < 1000 or uid > 60000: continue
                if p[6] not in ['/bin/false', '/usr/sbin/nologin', '/bin/bash', '/bin/sh']: continue
                uname = p[0]
                u = {'user': uname, 'active': True, 'exp': None, 'uuid': None, 'ip_limit': 2, 'data_gb': 0}
                exp_f = f'/etc/chaiya/exp/{uname}'
                if os.path.exists(exp_f):
                    u['exp'] = open(exp_f).read().strip()
                if not u['exp'] and uname in db_map:
                    u['exp'] = db_map[uname]['exp']
                if uname in db_map:
                    u['ip_limit'] = db_map[uname]['ip_limit']
                    u['data_gb']  = db_map[uname]['data_gb']
                if u['exp']:
                    try:
                        exp_date = datetime.date.fromisoformat(u['exp'])
                        u['active'] = exp_date >= datetime.date.today()
                    except: pass
                u['uuid'] = xui_clients.get(uname)
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
                raw = self.rfile.read(length)
                return json.loads(raw)
            return {}
        except: return {}

    def do_GET(self):
        if self.path == '/api/status':
            xui_port_f = '/etc/chaiya/xui-port.conf'
            xui_port = open(xui_port_f).read().strip() if os.path.exists(xui_port_f) else '2053'
            _, svc_dropbear, _ = run_cmd("systemctl is-active dropbear")
            _, svc_nginx,    _ = run_cmd("systemctl is-active nginx")
            _, svc_xui,      _ = run_cmd("systemctl is-active x-ui")
            _, udp, _          = run_cmd("pgrep -x badvpn-udpgw")
            _, ws,  _          = run_cmd("pgrep -f ws-stunnel")
            conns = get_connections()
            users = list_users()
            respond(self, 200, {
                "ok": True,
                "connections": conns.get("total", 0),
                "conn_443": conns.get("443", 0),
                "conn_80":  conns.get("80", 0),
                "conn_143": conns.get("143", 0),
                "conn_109": conns.get("109", 0),
                "conn_22":  conns.get("22", 0),
                "online":   conns.get("total", 0),
                "online_count": conns.get("total", 0),
                "total_users": len(users),
                "services": {
                    "ssh":      True,
                    "dropbear": svc_dropbear.strip() == "active",
                    "nginx":    svc_nginx.strip()    == "active",
                    "badvpn":   bool(udp.strip()),
                    "sshws":    bool(ws.strip()),
                    "xui":      svc_xui.strip()      == "active",
                    "tunnel":   bool(ws.strip()),
                }
            })

        elif self.path == '/api/users':
            respond(self, 200, {"users": list_users()})

        elif self.path == '/api/info':
            xui_port_f = '/etc/chaiya/xui-port.conf'
            xui_port = open(xui_port_f).read().strip() if os.path.exists(xui_port_f) else '2053'
            domain_f = '/etc/chaiya/domain.conf'
            domain = open(domain_f).read().strip() if os.path.exists(domain_f) else ''
            respond(self, 200, {
                "host": get_host(),
                "domain": domain,
                "xui_port": int(xui_port),
                "dropbear_port": 143,
                "dropbear_port2": 109,
                "ws_port": 443,
                "udpgw_port": 7300,
            })

        else:
            respond(self, 404, {'error': 'Not found'})

    def do_POST(self):
        data = self.read_body()

        if self.path == '/api/verify':
            import hashlib
            pw = data.get("password", "")
            hashed = hashlib.sha256(pw.encode()).hexdigest()
            hash_f = '/etc/chaiya/panel-pass.hash'
            stored = ""
            try:
                stored = open(hash_f).read().strip()
            except: pass
            respond(self, 200, {"ok": bool(stored) and hashed == stored})

        elif self.path == '/api/create':
            import re as _re
            user     = data.get('user', '').strip()
            pw       = data.get('pass', '').strip()
            days     = int(data.get('exp_days', data.get('days', 30)))
            data_gb  = int(data.get('data_gb', 0))
            ip_limit = int(data.get('ip_limit', 2))
            if not user or not pw:
                return respond(self, 400, {'error': 'user/pass required'})
            if not _re.match(r'^[a-z0-9_-]{1,32}$', user):
                return respond(self, 400, {'error': 'username: a-z0-9_- เท่านั้น max 32 ตัว'})

            ok1, _, e1 = run_cmd(
                f"userdel -f {user} 2>/dev/null; "
                f"useradd -M -s /bin/false -e {(datetime.date.today() + datetime.timedelta(days=days)).isoformat()} {user}"
            )
            import subprocess as _sp
            _sp.run(['chpasswd'], input=f'{user}:{pw}\n', text=True, capture_output=True, timeout=10)
            exp = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
            run_cmd(f"chage -E {exp} {user}")

            os.makedirs('/etc/chaiya/exp', exist_ok=True)
            with open(f'/etc/chaiya/exp/{user}', 'w') as f:
                f.write(exp)

            os.makedirs('/etc/chaiya/sshws-users', exist_ok=True)
            db = '/etc/chaiya/sshws-users/users.db'
            existing_lines = []
            if os.path.exists(db):
                existing_lines = [l for l in open(db) if not l.strip().startswith(user + ' ')]
            with open(db, 'w') as f:
                f.writelines(existing_lines)
                f.write(f"{user} {days} {exp} {data_gb} {ip_limit}\n")

            user_uuid = add_xui_client(user)

            vless_uuid = None
            try:
                con = sqlite3.connect(XUI_DB)
                row = con.execute("SELECT id, settings FROM inbounds WHERE port=8880").fetchone()
                if row:
                    inbound_id, settings_str = row
                    settings = json.loads(settings_str)
                    clients = [c for c in settings.get('clients', []) if c.get('email') != user]
                    vless_uuid = str(uuid.uuid4())
                    clients.append({'id': vless_uuid, 'flow': '', 'email': user,
                                    'limitIpCount': ip_limit,
                                    'totalGB': data_gb * (1024**3) if data_gb else 0,
                                    'expiryTime': 0, 'enable': True, 'tgId': '', 'subId': ''})
                    settings['clients'] = clients
                    con.execute("UPDATE inbounds SET settings=? WHERE id=?",
                                (json.dumps(settings), inbound_id))
                    con.commit()
                con.close()
            except: pass

            run_cmd("systemctl restart x-ui 2>/dev/null || true")

            host = get_host()
            npv_link = build_npv_link(host, user_uuid, user) if host and user_uuid else None

            respond(self, 200, {
                'ok': True, 'user': user, 'exp': exp,
                'uuid': user_uuid, 'vless_uuid': vless_uuid,
                'ip_limit': ip_limit, 'data_gb': data_gb,
                'npv_link': npv_link
            })

        elif self.path == '/api/delete':
            user = data.get('user', '').strip()
            if not user:
                return respond(self, 400, {'error': 'user required'})
            run_cmd(f"userdel -f {user} 2>/dev/null")
            run_cmd(f"rm -f /etc/chaiya/exp/{user}")
            db = '/etc/chaiya/sshws-users/users.db'
            if os.path.exists(db):
                lines = [l for l in open(db) if not l.strip().startswith(user + ' ')]
                with open(db, 'w') as f: f.writelines(lines)
            remove_xui_client(user)
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

APPEOF

cat > /etc/nginx/sites-available/chaiya << 'NGINXEOF'
# HTTP → HTTPS redirect
server {
    listen 80;
    server_name adminchaiya.godvpn.shop;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0"; return 301 https://$host$request_uri; }
}

# HTTPS — Panel หลัก
server {
    listen 443 ssl http2;
    server_name adminchaiya.godvpn.shop;

    ssl_certificate     /etc/letsencrypt/live/adminchaiya.godvpn.shop/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/adminchaiya.godvpn.shop/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    root /opt/chaiya-panel;
    index index.html;

    location / {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
        try_files $uri $uri/ =404;
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }

    location /api/ {
        proxy_pass http://127.0.0.1:2095/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 30s;
        proxy_connect_timeout 5s;
        add_header Access-Control-Allow-Origin "*" always;
        add_header Access-Control-Allow-Methods "GET,POST,OPTIONS" always;
        add_header Access-Control-Allow-Headers "Content-Type" always;
    }

    location /xui-api/ {
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:2535/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Cookie $http_cookie;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
        proxy_connect_timeout 10s;
    }
}

server {
    listen 2053 ssl;
    server_name adminchaiya.godvpn.shop;
    ssl_certificate /etc/letsencrypt/live/adminchaiya.godvpn.shop/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/adminchaiya.godvpn.shop/privkey.pem;
    location / {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
        proxy_pass http://127.0.0.1:2535;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Cookie $http_cookie;
    }
}

NGINXEOF

cat > /opt/chaiya-panel/sshws.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="th">
<head>
<script src="config.js"></script>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA V2RAY PRO MAX — Dashboard</title>
<link href="https://fonts.googleapis.com/css2?family=Rajdhani:wght@600;700&family=Kanit:wght@300;400;600&family=Share+Tech+Mono&display=swap" rel="stylesheet">
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
/* ══════════════════════════════════════
   ROOT & RESET
══════════════════════════════════════ */
:root {
  --bg:        #f0f4f8;
  --surface:   #ffffff;
  --border:    #e2e8f0;
  --shadow:    0 2px 12px rgba(0,0,0,.08);
  --shadow-lg: 0 4px 24px rgba(0,0,0,.12);

  --ais:       #5a9e1c;
  --ais2:      #3d7a0e;
  --ais-light: #f0f9e8;
  --ais-bdr:   #c5e89a;

  --true:      #e01020;
  --true2:     #b8000e;
  --true-light:#fff0f0;
  --true-bdr:  #f8a0a8;

  --ssh:       #1a6fa8;
  --ssh2:      #0d5487;
  --ssh-light: #e8f4fc;
  --ssh-bdr:   #90caf0;

  --text:      #1a2332;
  --text2:     #4a6072;
  --text3:     #8099ac;
  --green:     #22c55e;
  --orange:    #f97316;
  --red:       #ef4444;
  --purple:    #8b5cf6;
}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{
  background:var(--bg);
  color:var(--text);
  font-family:'Kanit',sans-serif;
  font-weight:400;
  min-height:100vh;
  overflow-x:hidden;
}

/* ══════════════════════════════════════
   HEADER
══════════════════════════════════════ */
/* ══════════════════════════════════════
   HEADER — dark + RGB glow + snowflakes
══════════════════════════════════════ */
.site-header{
  text-align:center;
  padding:2.2rem 1.5rem 1.8rem;
  background:linear-gradient(175deg,#0a0f1a 0%,#0d1520 55%,#111820 100%);
  border-bottom:1px solid rgba(255,255,255,.06);
  position:relative;overflow:hidden;
}
/* RGB glow คลื่นรอบหัว */
.site-header::before{
  content:'';position:absolute;inset:0;
  background:
    radial-gradient(ellipse 60% 40% at 20% 50%,rgba(0,180,255,.07) 0%,transparent 70%),
    radial-gradient(ellipse 60% 40% at 80% 50%,rgba(180,0,255,.07) 0%,transparent 70%),
    radial-gradient(ellipse 80% 60% at 50% 120%,rgba(0,255,150,.06) 0%,transparent 65%);
  pointer-events:none;animation:hdrGlow 8s ease-in-out infinite alternate;
}
@keyframes hdrGlow{
  0%  {opacity:.7}
  50% {opacity:1}
  100%{opacity:.6}
}
/* canvas หิมะ */
#snow-canvas{position:absolute;inset:0;pointer-events:none;z-index:0}

.site-logo{
  font-family:'Share Tech Mono',monospace;
  font-size:.6rem;letter-spacing:.38em;
  color:rgba(160,220,255,.5);
  margin-bottom:.5rem;
  display:flex;align-items:center;justify-content:center;gap:.75rem;
  position:relative;z-index:2;
}
.site-logo::before,.site-logo::after{
  content:'';display:inline-block;height:1px;width:44px;
  background:linear-gradient(90deg,transparent,rgba(100,180,255,.35));
}
.site-logo::after{background:linear-gradient(90deg,rgba(100,180,255,.35),transparent)}

.site-title{
  font-family:'Rajdhani',sans-serif;font-size:2.45rem;font-weight:700;
  letter-spacing:.09em;color:#e8f4ff;
  position:relative;z-index:2;line-height:1.1;
  text-shadow:0 0 30px rgba(80,160,255,.2);
}
.site-title .rgb-word{
  background:linear-gradient(90deg,#7ee8fa,#80ff72,#7ee8fa);
  background-size:200% auto;
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;
  animation:rgbShift 4s linear infinite;
}
@keyframes rgbShift{to{background-position:200% center}}

.site-sub{
  font-size:.7rem;color:rgba(255,255,255,.3);margin-top:.4rem;
  font-family:'Share Tech Mono',monospace;letter-spacing:.07em;
  position:relative;z-index:2;
}
.site-sub .dot{margin:0 .4rem;color:rgba(130,200,255,.35)}

/* ══════════════════════════════════════
   TAB NAV — dark sticky
══════════════════════════════════════ */
.tab-nav{
  display:flex;
  background:#0e1825;
  border-bottom:1px solid rgba(255,255,255,.07);
  overflow-x:auto;-webkit-overflow-scrolling:touch;
  position:sticky;top:0;z-index:200;
}
.tab-nav::-webkit-scrollbar{display:none}
.tab-btn{
  flex:1;min-width:80px;padding:.8rem .5rem;
  border:none;background:transparent;
  font-family:'Kanit',sans-serif;font-size:.78rem;font-weight:600;
  color:rgba(255,255,255,.35);cursor:pointer;
  border-bottom:2px solid transparent;
  transition:all .22s;white-space:nowrap;
}
.tab-btn:hover{color:rgba(255,255,255,.65);background:rgba(255,255,255,.03)}
.tab-btn.active{
  color:#7ee8fa;border-bottom-color:#7ee8fa;
  background:rgba(126,232,250,.05);
  text-shadow:0 0 12px rgba(126,232,250,.4);
}

/* ══════════════════════════════════════
   RGB SECTION LABELS
══════════════════════════════════════ */
.section-label{
  display:flex;align-items:center;gap:.55rem;
  font-family:'Rajdhani',sans-serif;
  font-size:.9rem;font-weight:700;letter-spacing:.16em;text-transform:uppercase;
  padding:.2rem 0 .8rem;
  position:relative;
}
.section-label .lbl-text{
  background:linear-gradient(90deg,#7ee8fa,#a78bfa,#80ff72,#7ee8fa);
  background-size:300% auto;
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;
  animation:rgbShift 5s linear infinite;
}
.section-label::after{
  content:'';flex:1;height:1px;
  background:linear-gradient(90deg,rgba(126,232,250,.2),transparent);
  margin-left:.4rem;
}

/* ══════════════════════════════════════
   TAB NAV
══════════════════════════════════════ */
.tab-nav{
  display:flex;
  background:var(--surface);
  border-bottom:1px solid var(--border);
  overflow-x:auto;
  -webkit-overflow-scrolling:touch;
}
.tab-nav::-webkit-scrollbar{display:none}
.tab-btn{
  flex:1;min-width:80px;
  padding:.75rem .5rem;
  border:none;background:transparent;
  font-family:'Kanit',sans-serif;font-size:.8rem;font-weight:600;
  color:var(--text3);cursor:pointer;
  border-bottom:2px solid transparent;
  transition:all .2s;white-space:nowrap;
}
.tab-btn.active{color:var(--ais);border-bottom-color:var(--ais)}

/* ══════════════════════════════════════
   TAB PANELS
══════════════════════════════════════ */
.tab-panel{display:none}
.tab-panel.active{display:block}

/* ══════════════════════════════════════
   MAIN LAYOUT
══════════════════════════════════════ */
.main{max-width:520px;margin:0 auto;padding:1.4rem 1rem 4rem;display:flex;flex-direction:column;gap:1.2rem}

/* ══════════════════════════════════════
   SYSTEM STATS — WIDGETS
══════════════════════════════════════ */
.stats-grid{
  display:grid;
  grid-template-columns:1fr 1fr;
  gap:.8rem;
}
.stat-card{
  background:var(--surface);
  border-radius:16px;
  padding:1rem 1.1rem;
  border:1px solid var(--border);
  box-shadow:var(--shadow);
  position:relative;overflow:hidden;
}
.stat-card.wide{grid-column:span 2}
.stat-label{
  font-family:'Share Tech Mono',monospace;
  font-size:.65rem;letter-spacing:.1em;text-transform:uppercase;
  color:var(--text3);margin-bottom:.4rem;
  display:flex;align-items:center;gap:.4rem;
}
.stat-value{
  font-family:'Rajdhani',sans-serif;
  font-size:1.9rem;font-weight:700;line-height:1;
  color:var(--text);
}
.stat-unit{font-size:1rem;color:var(--text2);margin-left:.15rem}
.stat-sub{font-size:.72rem;color:var(--text3);margin-top:.3rem}

/* Ring gauge */
.ring-wrap{display:flex;align-items:center;gap:.9rem}
.ring-svg{flex-shrink:0}
.ring-track{fill:none;stroke:var(--border);stroke-width:6}
.ring-fill{fill:none;stroke-width:6;stroke-linecap:round;
  transition:stroke-dashoffset 1s cubic-bezier(.4,0,.2,1)}
.ring-info{flex:1}

/* Bar gauge */
.bar-gauge{
  height:8px;background:var(--border);border-radius:4px;
  margin-top:.6rem;overflow:hidden;
}
.bar-fill{
  height:100%;border-radius:4px;
  transition:width 1s cubic-bezier(.4,0,.2,1);
}

/* Online badge */
.online-badge{
  display:inline-flex;align-items:center;gap:.35rem;
  background:#f0fdf4;border:1px solid #86efac;
  color:#166534;padding:.25rem .7rem;border-radius:20px;
  font-size:.72rem;font-family:'Share Tech Mono',monospace;
}
.online-dot{width:7px;height:7px;border-radius:50%;background:var(--green);
  animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}

.refresh-btn{
  border:1px solid var(--border);background:var(--surface);
  border-radius:8px;padding:.3rem .7rem;
  font-size:.75rem;color:var(--text2);cursor:pointer;
  font-family:'Kanit',sans-serif;
  transition:all .2s;
}
.refresh-btn:hover{background:var(--bg);color:var(--text)}
.refresh-btn.spin svg{animation:spinR .6s linear infinite}
@keyframes spinR{to{transform:rotate(360deg)}}

/* uptime chip */
.chip{
  display:inline-block;
  background:#f8fafc;border:1px solid var(--border);
  border-radius:6px;padding:.15rem .5rem;
  font-family:'Share Tech Mono',monospace;font-size:.72rem;color:var(--text2);
}

/* ══════════════════════════════════════
   SECTION LABEL
══════════════════════════════════════ */
.section-label{
  display:flex;align-items:center;gap:.5rem;
  font-family:'Rajdhani',sans-serif;
  font-size:.9rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
  color:var(--text2);padding:.2rem 0 .7rem;
}

/* ══════════════════════════════════════
   CARD GROUP (buttons)
══════════════════════════════════════ */
.card-group{
  background:var(--surface);border-radius:18px;
  box-shadow:var(--shadow);overflow:hidden;
  border:1px solid var(--border);
}
.card-group .carrier-btn+.carrier-btn{border-top:1px solid var(--border)}

/* ══════════════════════════════════════
   CARRIER BUTTONS
══════════════════════════════════════ */
.carrier-btn{
  width:100%;border:none;background:var(--surface);
  padding:1rem 1.2rem;cursor:pointer;
  display:flex;align-items:center;gap:1rem;text-align:left;
  transition:background .15s;
}
.carrier-btn:hover{background:#f8fbff}
.carrier-btn:active{background:#f0f6ff}

.btn-logo{
  width:54px;height:54px;border-radius:13px;
  display:flex;align-items:center;justify-content:center;
  flex-shrink:0;overflow:hidden;
  border:1px solid var(--border);background:#f4f4f4;
}
.logo-ais{background:#fff;border-color:var(--ais-bdr)}
.logo-true{background:#c8040d;border-color:#e0000a}
.logo-ssh{background:#1565c0;border-color:#1976d2}

.btn-info{flex:1;min-width:0}
.btn-name{font-family:'Rajdhani',sans-serif;font-size:1.12rem;font-weight:700;letter-spacing:.04em;display:block;margin-bottom:.15rem}
.btn-ais  .btn-name{color:var(--ais)}
.btn-true .btn-name{color:var(--true)}
.btn-ssh  .btn-name{color:var(--ssh)}
.btn-desc{font-size:.74rem;font-weight:300;color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block}
.btn-true .btn-desc{color:var(--true)}
.btn-arrow{color:var(--text3);font-size:1.1rem;flex-shrink:0;transition:transform .18s}
.carrier-btn:hover .btn-arrow{transform:translateX(3px);color:var(--text2)}

/* ══════════════════════════════════════
   USER MANAGEMENT — search / list
══════════════════════════════════════ */
.mgmt-panel{
  background:var(--surface);border-radius:18px;
  border:1px solid var(--border);box-shadow:var(--shadow);
  overflow:hidden;
}
.mgmt-header{
  padding:.9rem 1.2rem;
  border-bottom:1px solid var(--border);
  display:flex;align-items:center;justify-content:space-between;
  gap:.8rem;
}
.mgmt-title{
  font-family:'Rajdhani',sans-serif;font-size:1rem;font-weight:700;
  letter-spacing:.06em;color:var(--text);display:flex;align-items:center;gap:.5rem;
}
.search-bar{
  display:flex;align-items:center;gap:.5rem;
  padding:.8rem 1.2rem;border-bottom:1px solid var(--border);
}
.search-bar input{
  flex:1;background:#f8fafc;border:1.5px solid var(--border);
  border-radius:10px;padding:.5rem .85rem;
  font-family:'Kanit',sans-serif;font-size:.88rem;
  outline:none;color:var(--text);transition:border-color .2s;
}
.search-bar input:focus{border-color:var(--ssh);background:#fff}

/* User row */
.user-list{max-height:400px;overflow-y:auto}
.user-list::-webkit-scrollbar{width:4px}
.user-list::-webkit-scrollbar-thumb{background:rgba(0,0,0,.1);border-radius:2px}

.user-row{-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;
  padding:.75rem 1.2rem;
  border-bottom:1px solid var(--border);
  display:flex;align-items:center;gap:.8rem;
  transition:background .15s;cursor:pointer;
}
.user-row:last-child{border-bottom:none}
.user-row:hover{background:#f8fafc}
.user-avatar{
  width:36px;height:36px;border-radius:10px;
  display:flex;align-items:center;justify-content:center;
  font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;
  flex-shrink:0;
}
.ua-ais{background:var(--ais-light);color:var(--ais2);border:1px solid var(--ais-bdr)}
.ua-true{background:var(--true-light);color:var(--true2);border:1px solid var(--true-bdr)}

.user-info{flex:1;min-width:0}
.user-name{font-weight:600;font-size:.88rem;color:var(--text);margin-bottom:.1rem}
.user-meta{font-size:.72rem;color:var(--text3);font-family:'Share Tech Mono',monospace}

.status-badge{
  font-size:.68rem;padding:.2rem .55rem;border-radius:20px;
  font-family:'Share Tech Mono',monospace;flex-shrink:0;
}
.status-ok{background:#f0fdf4;border:1px solid #86efac;color:#166534}
.status-exp{background:#fff7ed;border:1px solid #fed7aa;color:#92400e}
.status-dead{background:#fef2f2;border:1px solid #fca5a5;color:#991b1b}
.status-online{background:#eff6ff;border:1px solid #93c5fd;color:#1e40af}

/* empty state */
.empty-state{
  text-align:center;padding:2rem 1rem;
  color:var(--text3);font-size:.85rem;
}
.empty-state .ei{font-size:2rem;margin-bottom:.5rem}

/* loading row */
.loading-row{
  text-align:center;padding:1.5rem;
  color:var(--text3);font-size:.82rem;
  display:flex;align-items:center;justify-content:center;gap:.5rem;
}

/* ══════════════════════════════════════
   MODAL OVERLAY
══════════════════════════════════════ */
.modal-overlay{
  display:none;position:fixed;inset:0;z-index:1000;
  background:rgba(0,0,0,.4);backdrop-filter:blur(4px);
  align-items:flex-end;justify-content:center;padding:0;
}
.modal-overlay.open{display:flex}

.modal{
  width:100%;max-width:520px;
  background:var(--surface);
  border-radius:24px 24px 0 0;
  overflow:hidden;position:relative;
  animation:slideUp .28s cubic-bezier(.34,1.1,.64,1);
  max-height:92vh;display:flex;flex-direction:column;
}
@keyframes slideUp{from{transform:translateY(100%);opacity:.5}to{transform:translateY(0);opacity:1}}

.modal::before{content:'';display:block;width:40px;height:4px;border-radius:2px;background:rgba(0,0,0,.15);margin:10px auto 0;flex-shrink:0}

.modal-header{
  padding:.85rem 1.4rem .95rem;
  display:flex;align-items:center;justify-content:space-between;
  border-bottom:1px solid var(--border);flex-shrink:0;
}
.modal-title{
  font-family:'Rajdhani',sans-serif;font-size:1.05rem;font-weight:700;letter-spacing:.08em;
  display:flex;align-items:center;gap:.6rem;
}
.modal-ais  .modal-title{color:var(--ais2)}
.modal-true .modal-title{color:var(--true2)}
.modal-ssh  .modal-title{color:var(--ssh2)}
.modal-mgmt .modal-title{color:var(--ssh2)}

.modal-close{
  width:30px;height:30px;border-radius:50%;border:none;
  background:#f0f4f8;display:flex;align-items:center;justify-content:center;
  cursor:pointer;font-size:.85rem;color:var(--text2);transition:all .2s;
}
.modal-close:hover{background:#e2e8f0;color:var(--text)}

.modal-body{padding:1rem 1.4rem 1.6rem;overflow-y:auto;flex:1}
.modal-body::-webkit-scrollbar{width:4px}
.modal-body::-webkit-scrollbar-thumb{background:rgba(0,0,0,.1);border-radius:2px}

/* ══════════════════════════════════════
   FORM FIELDS
══════════════════════════════════════ */
.sni-badge{
  display:inline-block;font-family:'Share Tech Mono',monospace;
  font-size:.68rem;padding:.22rem .65rem;border-radius:20px;margin-bottom:.9rem;
}
.sni-badge.ais{background:var(--ais-light);border:1px solid var(--ais-bdr);color:var(--ais2)}
.sni-badge.true{background:var(--true-light);border:1px solid var(--true-bdr);color:var(--true2)}
.sni-badge.ssh{background:var(--ssh-light);border:1px solid var(--ssh-bdr);color:var(--ssh2)}

.fgrid{display:grid;grid-template-columns:1fr 1fr;gap:.6rem .8rem}
.fgrid .span2{grid-column:span 2}
.field{display:flex;flex-direction:column;gap:.3rem}

label{font-size:.67rem;font-family:'Share Tech Mono',monospace;letter-spacing:.1em;text-transform:uppercase;color:var(--text3)}
input,select{
  background:#f8fafc;border:1.5px solid var(--border);border-radius:10px;
  padding:.58rem .88rem;color:var(--text);
  font-family:'Kanit',sans-serif;font-size:.88rem;outline:none;
  transition:border-color .2s,box-shadow .2s;width:100%;
}
input:focus,select:focus{background:#fff}
input.ais-focus:focus{border-color:var(--ais);box-shadow:0 0 0 3px rgba(90,158,28,.1)}
input.true-focus:focus{border-color:var(--true);box-shadow:0 0 0 3px rgba(224,16,32,.09)}
input.ssh-focus:focus{border-color:var(--ssh);box-shadow:0 0 0 3px rgba(26,111,168,.1)}
input.mgmt-focus:focus{border-color:var(--purple);box-shadow:0 0 0 3px rgba(139,92,246,.1)}
select option{background:#fff}

.divider{height:1px;background:var(--border);margin:.8rem 0}

.submit-btn{
  width:100%;padding:.83rem;border:none;border-radius:12px;
  font-family:'Rajdhani',sans-serif;font-size:1.02rem;font-weight:700;letter-spacing:.1em;
  cursor:pointer;margin-top:.8rem;transition:all .2s;overflow:hidden;
}
.submit-btn:disabled{opacity:.5;cursor:not-allowed}
.submit-btn.ais-btn{background:linear-gradient(135deg,#4d8a15,var(--ais));color:#fff;box-shadow:0 4px 14px rgba(90,158,28,.3)}
.submit-btn.ais-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(90,158,28,.4);transform:translateY(-1px)}
.submit-btn.true-btn{background:linear-gradient(135deg,#c0030f,var(--true));color:#fff;box-shadow:0 4px 14px rgba(224,16,32,.26)}
.submit-btn.true-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(224,16,32,.36);transform:translateY(-1px)}
.submit-btn.ssh-btn{background:linear-gradient(135deg,#135d94,var(--ssh));color:#fff;box-shadow:0 4px 14px rgba(26,111,168,.26)}
.submit-btn.ssh-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(26,111,168,.36);transform:translateY(-1px)}
.submit-btn.mgmt-btn{background:linear-gradient(135deg,#6d28d9,var(--purple));color:#fff;box-shadow:0 4px 14px rgba(139,92,246,.26)}
.submit-btn.mgmt-btn:hover:not(:disabled){box-shadow:0 6px 22px rgba(139,92,246,.36);transform:translateY(-1px)}
.submit-btn.danger-btn{background:linear-gradient(135deg,#b91c1c,var(--red));color:#fff;box-shadow:0 4px 14px rgba(239,68,68,.22)}

.spinner{display:inline-block;width:14px;height:14px;border:2px solid rgba(255,255,255,.3);border-top-color:#fff;border-radius:50%;animation:spin .7s linear infinite;vertical-align:middle;margin-right:.4rem}
@keyframes spin{to{transform:rotate(360deg)}}

.alert{display:none;margin-top:.7rem;padding:.68rem .9rem;border-radius:10px;font-size:.8rem;line-height:1.6}
.alert.ok{background:#f0fdf4;border:1px solid #86efac;color:#166534}
.alert.err{background:#fef2f2;border:1px solid #fca5a5;color:#991b1b}
.alert.info{background:#eff6ff;border:1px solid #93c5fd;color:#1e40af}

/* ══════════════════════════════════════
   RESULT CARD
══════════════════════════════════════ */
.result-card{display:none;margin-top:1rem;border-radius:14px;overflow:hidden;border:1.5px solid var(--border);box-shadow:0 2px 10px rgba(0,0,0,.06)}
.result-card.show{display:block}
#ais-result.show{border-color:var(--ais-bdr)}
#true-result.show{border-color:var(--true-bdr)}
#ssh-result.show{border-color:var(--ssh-bdr)}

.result-header{padding:.65rem 1rem;font-family:'Share Tech Mono',monospace;font-size:.72rem;letter-spacing:.1em;display:flex;align-items:center;gap:.5rem;border-bottom:1px solid var(--border)}
.result-header .dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.result-header.ais-r{background:var(--ais-light);color:var(--ais2)}
.result-header.ais-r .dot{background:var(--ais);box-shadow:0 0 5px var(--ais)}
.result-header.true-r{background:var(--true-light);color:var(--true2)}
.result-header.true-r .dot{background:var(--true)}
.result-header.ssh-r{background:var(--ssh-light);color:var(--ssh2)}
.result-header.ssh-r .dot{background:var(--ssh)}

.result-body{padding:.85rem 1rem;background:#fafcfe}
.info-rows{margin-bottom:.8rem}
.info-row{display:flex;justify-content:space-between;align-items:center;padding:.32rem 0;border-bottom:1px solid var(--border);font-size:.8rem}
.info-row:last-child{border-bottom:none}
.info-key{color:var(--text3);font-size:.7rem;font-family:'Share Tech Mono',monospace;letter-spacing:.08em}
.info-val{color:var(--text);text-align:right;word-break:break-all;max-width:62%}
.info-val.pass{font-family:'Share Tech Mono',monospace;color:var(--green);font-weight:600}
.info-val.uuid{font-family:'Share Tech Mono',monospace;font-size:.62rem;color:var(--ssh)}

.link-box{background:#f0f4f8;border-radius:8px;padding:.6rem .8rem;font-family:'Share Tech Mono',monospace;font-size:.62rem;word-break:break-all;line-height:1.7;margin-bottom:.7rem;border:1px solid var(--border);color:var(--text2)}
.link-box.vless-link{border-left:3px solid var(--ais);color:var(--ais2)}
.link-box.npv-link{border-left:3px solid var(--ssh);color:var(--ssh2)}
.link-box.dark-link{border-left:3px solid #9333ea;color:#7e22ce}

.qr-wrap{display:flex;justify-content:center;margin:.6rem 0 .8rem}
.qr-inner{background:#fff;padding:10px;border-radius:10px;display:inline-block;border:1px solid var(--border)}

.copy-row{display:flex;gap:.5rem;flex-wrap:wrap}
.copy-btn{flex:1;min-width:120px;padding:.5rem .7rem;border-radius:9px;border:1.5px solid var(--border);background:#fff;font-family:'Rajdhani',sans-serif;font-size:.85rem;font-weight:700;letter-spacing:.06em;cursor:pointer;transition:all .2s;color:var(--text2)}
.copy-btn.vless{border-color:var(--ais-bdr);color:var(--ais2)}
.copy-btn.vless:hover{background:var(--ais-light)}
.copy-btn.npv{border-color:var(--ssh-bdr);color:var(--ssh2)}
.copy-btn.npv:hover{background:var(--ssh-light)}
.copy-btn.ssh-copy{border-color:var(--ssh-bdr);color:var(--ssh2)}
.copy-btn.ssh-copy:hover{background:var(--ssh-light)}
.copy-btn.copied{opacity:.6;pointer-events:none}

/* ══════════════════════════════════════
   PORT / APP TABS
══════════════════════════════════════ */
.port-tabs{display:flex;gap:.4rem;margin-bottom:.6rem}
.port-tab{flex:1;padding:.48rem;border-radius:9px;font-size:.8rem;cursor:pointer;border:1.5px solid var(--border);background:#f8fafc;color:var(--text2);font-family:'Rajdhani',sans-serif;font-weight:600;transition:all .2s}
.port-tab.active-ssh{border-color:var(--ssh);background:var(--ssh-light);color:var(--ssh2)}
.pro-tab{display:flex;align-items:center;justify-content:center;gap:.4rem;padding:.5rem .6rem}
#ssh-pro-dtac.active-ssh{border-color:var(--ssh);background:var(--ssh-light);color:var(--ssh2)}
#ssh-pro-true.active-ssh{border-color:var(--true);background:var(--true-light);color:var(--true2)}

/* ══════════════════════════════════════
   MGMT MODAL — action rows
══════════════════════════════════════ */
.action-grid{display:grid;grid-template-columns:1fr 1fr;gap:.6rem;margin-top:.8rem}
.action-card{
  background:#f8fafc;border:1.5px solid var(--border);border-radius:12px;
  padding:.85rem .9rem;cursor:pointer;transition:all .2s;text-align:center;
}
.action-card:hover{border-color:var(--ssh);background:var(--ssh-light)}
.action-card.selected{border-color:var(--purple);background:#f5f3ff}
.action-icon{font-size:1.4rem;margin-bottom:.3rem}
.action-name{font-family:'Rajdhani',sans-serif;font-size:.9rem;font-weight:700;color:var(--text)}
.action-desc{font-size:.7rem;color:var(--text3);margin-top:.15rem}

/* user detail panel */
.udetail{
  background:var(--bg);border-radius:12px;padding:.85rem 1rem;
  border:1px solid var(--border);margin-bottom:.9rem;
}
.udetail-row{display:flex;justify-content:space-between;padding:.28rem 0;border-bottom:1px solid var(--border);font-size:.8rem}
.udetail-row:last-child{border-bottom:none}
.dk{color:var(--text3);font-family:'Share Tech Mono',monospace;font-size:.68rem}
.dv{color:var(--text);font-weight:600}
.dv.exp{color:var(--orange)}
.dv.dead{color:var(--red)}
.dv.ok{color:var(--green)}
.dv.online{color:var(--ssh)}

/* ══════════════════════════════════════
   TOAST
══════════════════════════════════════ */
.toast{
  position:fixed;bottom:28px;left:50%;transform:translateX(-50%);
  background:var(--text);color:#fff;
  padding:.6rem 1.5rem;border-radius:24px;
  font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;
  opacity:0;pointer-events:none;z-index:9999;transition:opacity .25s;white-space:nowrap;
  box-shadow:0 4px 20px rgba(0,0,0,.25);
}
.toast.show{opacity:1}

/* ══════════════════════════════════════
   RESPONSIVE
══════════════════════════════════════ */
@media(max-width:600px){
  .fgrid{grid-template-columns:1fr}.fgrid .span2{grid-column:span 1}
  .action-grid{grid-template-columns:1fr 1fr}
  .modal{border-radius:20px 20px 0 0}
}

/* ══════════════════════════════════════
   SERVICE MONITOR
══════════════════════════════════════ */
.svc-grid{display:flex;flex-direction:column;gap:.42rem}
.svc-row{
  display:flex;align-items:center;gap:.65rem;
  border-radius:11px;padding:.52rem .85rem;
  border:1px solid var(--border);background:#f9fbfc;
  transition:all .15s;
}
.svc-row.up  {border-color:#86efac;background:#f0fdf4}
.svc-row.down{border-color:#fca5a5;background:#fef2f2}
.svc-row.warn{border-color:#fed7aa;background:#fffbf5}
.svc-dot{
  width:8px;height:8px;border-radius:50%;flex-shrink:0;
}
.svc-dot.up  {background:#22c55e;box-shadow:0 0 6px rgba(34,197,94,.55);animation:pulse 2s infinite}
.svc-dot.down{background:var(--red)}
.svc-dot.warn{background:var(--orange);animation:pulse 2s infinite}
.svc-icon{font-size:.9rem;flex-shrink:0}
.svc-name{font-family:"Share Tech Mono",monospace;font-size:.75rem;color:var(--text);flex:1;font-weight:600}
.svc-ports{font-family:"Share Tech Mono",monospace;font-size:.63rem;color:var(--text3)}
.svc-chip{
  font-family:"Share Tech Mono",monospace;font-size:.63rem;
  padding:.13rem .5rem;border-radius:20px;flex-shrink:0;font-weight:700;
}
.svc-chip.up  {background:#dcfce7;color:#166534;border:1px solid #86efac}
.svc-chip.down{background:#fee2e2;color:#991b1b;border:1px solid #fca5a5}
.svc-chip.warn{background:#fff7ed;color:#92400e;border:1px solid #fed7aa}
.svc-chip.checking{background:#f1f5f9;color:var(--text3);border:1px solid var(--border)}

/* ══════════════════════════════════════
   HEADER UPGRADE
══════════════════════════════════════ */
.site-header{
  text-align:center;
  padding:2rem 1.5rem 1.6rem;
  background:linear-gradient(160deg,#152515 0%,#0e1e2e 55%,#18182e 100%);
  border-bottom:1px solid rgba(255,255,255,.05);
  position:relative;overflow:hidden;
}
.site-header::before{
  content:"";position:absolute;top:-60px;left:50%;transform:translateX(-50%);
  width:380px;height:200px;
  background:radial-gradient(ellipse,rgba(80,160,20,.18) 0%,transparent 70%);
  pointer-events:none;
}
.site-logo{
  font-family:"Share Tech Mono",monospace;
  font-size:.6rem;letter-spacing:.35em;
  color:rgba(100,200,50,.65);
  margin-bottom:.45rem;
  display:flex;align-items:center;justify-content:center;gap:.7rem;
  position:relative;z-index:1;
}
.site-logo::before,.site-logo::after{
  content:"";display:inline-block;height:1px;width:42px;
  background:linear-gradient(90deg,transparent,rgba(100,200,50,.45));
}
.site-logo::after{background:linear-gradient(90deg,rgba(100,200,50,.45),transparent)}
.site-title{
  font-family:"Rajdhani",sans-serif;font-size:2.4rem;font-weight:700;letter-spacing:.08em;
  color:#eef6ff;position:relative;z-index:1;line-height:1.1;
}
.site-title span{color:#72d124;text-shadow:0 0 22px rgba(100,200,30,.4)}
.site-sub{
  font-size:.72rem;color:rgba(255,255,255,.35);margin-top:.4rem;
  font-family:"Share Tech Mono",monospace;letter-spacing:.07em;
  position:relative;z-index:1;
}
.site-sub .dot{margin:0 .4rem;color:rgba(110,200,50,.45)}

/* ══════════════════════════════════════
   TAB NAV UPGRADE
══════════════════════════════════════ */
.tab-nav{
  display:flex;
  background:#192333;
  border-bottom:1px solid rgba(255,255,255,.07);
  overflow-x:auto;-webkit-overflow-scrolling:touch;
  position:sticky;top:0;z-index:200;
}
.tab-nav::-webkit-scrollbar{display:none}
.tab-btn{
  flex:1;min-width:80px;
  padding:.78rem .5rem;
  border:none;background:transparent;
  font-family:"Kanit",sans-serif;font-size:.78rem;font-weight:600;
  color:rgba(255,255,255,.38);cursor:pointer;
  border-bottom:2px solid transparent;
  transition:all .2s;white-space:nowrap;
}
.tab-btn:hover{color:rgba(255,255,255,.65);background:rgba(255,255,255,.03)}
.tab-btn.active{color:#72d124;border-bottom-color:#72d124;background:rgba(114,209,36,.06)}

/* ══════════════════════════════════════
   STAT CARDS UPGRADE
══════════════════════════════════════ */
.stat-card{
  background:var(--surface);
  border-radius:18px;
  padding:1.1rem 1.15rem;
  border:1px solid var(--border);
  box-shadow:0 2px 14px rgba(0,0,0,.07);
  position:relative;overflow:hidden;transition:box-shadow .2s,transform .2s;
}
.stat-card:hover{box-shadow:0 6px 24px rgba(0,0,0,.11);transform:translateY(-1px)}
.stat-card::after{
  content:"";position:absolute;top:0;right:0;
  width:70px;height:70px;border-radius:0 18px 0 100%;
  background:linear-gradient(135deg,transparent,rgba(0,0,0,.025));
  pointer-events:none;
}

/* refresh btn upgrade */
.refresh-btn{
  border:1px solid var(--border);background:var(--surface);
  border-radius:9px;padding:.32rem .75rem;
  font-size:.74rem;color:var(--text2);cursor:pointer;
  font-family:"Kanit",sans-serif;
  transition:all .2s;display:inline-flex;align-items:center;gap:.3rem;
}
.refresh-btn:hover{background:#f0f4fa;color:var(--text);border-color:#b0bfd0}
.refresh-btn.spin svg{animation:spinR .6s linear infinite}

/* carrier button upgrade */
.carrier-btn{
  width:100%;border:none;background:var(--surface);
  padding:1.05rem 1.2rem;cursor:pointer;
  display:flex;align-items:center;gap:1rem;text-align:left;
  transition:background .15s,transform .1s;
}
.carrier-btn:hover{background:#f6f9ff;transform:none}
.carrier-btn:active{transform:scale(.99)}

/* section label upgrade */
.section-label{
  display:flex;align-items:center;gap:.5rem;
  font-family:"Rajdhani",sans-serif;
  font-size:.88rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;
  color:var(--text2);padding:.2rem 0 .75rem;
}

/* modal upgrade */
.modal{
  width:100%;max-width:520px;
  background:var(--surface);
  border-radius:26px 26px 0 0;
  overflow:hidden;position:relative;
  animation:slideUp .26s cubic-bezier(.34,1.1,.64,1);
  max-height:94vh;display:flex;flex-direction:column;
}
.modal::before{
  content:"";display:block;width:42px;height:4px;border-radius:2px;
  background:rgba(0,0,0,.12);margin:11px auto 0;flex-shrink:0;
}
.modal-body{padding:1.1rem 1.4rem 1.8rem;overflow-y:auto;flex:1}

/* submit button upgrade */
.submit-btn{
  width:100%;padding:.88rem;border:none;border-radius:13px;
  font-family:"Rajdhani",sans-serif;font-size:1.05rem;font-weight:700;letter-spacing:.1em;
  cursor:pointer;margin-top:.9rem;transition:all .2s;
  position:relative;overflow:hidden;
}
.submit-btn::after{
  content:"";position:absolute;inset:0;
  background:linear-gradient(180deg,rgba(255,255,255,.12),transparent);
  pointer-events:none;
}
.submit-btn.ais-btn{background:linear-gradient(135deg,#3d7a0e,#5aaa18);color:#fff;box-shadow:0 4px 16px rgba(77,154,14,.32)}
.submit-btn.ais-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(77,154,14,.45);transform:translateY(-1px)}
.submit-btn.true-btn{background:linear-gradient(135deg,#a6000c,#d81020);color:#fff;box-shadow:0 4px 16px rgba(216,14,28,.28)}
.submit-btn.true-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(216,14,28,.4);transform:translateY(-1px)}
.submit-btn.ssh-btn{background:linear-gradient(135deg,#0c4f84,#1668a8);color:#fff;box-shadow:0 4px 16px rgba(21,104,166,.28)}
.submit-btn.ssh-btn:hover:not(:disabled){box-shadow:0 6px 24px rgba(21,104,166,.4);transform:translateY(-1px)}
.submit-btn.mgmt-btn{background:linear-gradient(135deg,#5b21b6,#7c3aed);color:#fff;box-shadow:0 4px 16px rgba(124,58,237,.26)}
.submit-btn.danger-btn{background:linear-gradient(135deg,#991b1b,#dc2626);color:#fff;box-shadow:0 4px 16px rgba(220,38,38,.22)}

/* card group upgrade */
.card-group{
  background:var(--surface);border-radius:20px;
  box-shadow:0 2px 14px rgba(0,0,0,.07);overflow:hidden;
  border:1px solid var(--border);
}

/* online badge upgrade */
.online-badge{
  display:inline-flex;align-items:center;gap:.38rem;
  background:#f0fdf4;border:1px solid #86efac;
  color:#15803d;padding:.26rem .75rem;border-radius:20px;
  font-size:.7rem;font-family:"Share Tech Mono",monospace;font-weight:600;
}

/* toast upgrade */
.toast{
  position:fixed;bottom:30px;left:50%;transform:translateX(-50%) scale(.95);
  background:#1a2332;color:#fff;
  padding:.65rem 1.6rem;border-radius:26px;
  font-family:"Rajdhani",sans-serif;font-weight:700;font-size:.9rem;
  opacity:0;pointer-events:none;z-index:9999;
  transition:opacity .25s,transform .25s;white-space:nowrap;
  box-shadow:0 8px 24px rgba(0,0,0,.22);
}
.toast.show{opacity:1;transform:translateX(-50%) scale(1)}

/* mgmt panel upgrade */
.mgmt-panel{
  background:var(--surface);border-radius:20px;
  border:1px solid var(--border);box-shadow:0 2px 14px rgba(0,0,0,.07);
  overflow:hidden;
}

/* SNI badge upgrade */
.sni-badge{
  display:inline-flex;align-items:center;gap:.4rem;
  font-family:"Share Tech Mono",monospace;
  font-size:.68rem;padding:.25rem .75rem;border-radius:20px;margin-bottom:.95rem;
}
.sni-badge.ais{background:#edf7e3;border:1px solid #b5e08a;color:#316808}
.sni-badge.true{background:#fff0f0;border:1px solid #f5909a;color:#a6000c}
.sni-badge.ssh{background:#e6f3fc;border:1px solid #82c0ee;color:#0c4f84}

/* input upgrade */
input,select{
  background:#f6f9fc;border:1.5px solid #d8e2ee;border-radius:11px;
  padding:.6rem .9rem;color:var(--text);
  font-family:"Kanit",sans-serif;font-size:.88rem;outline:none;
  transition:border-color .2s,box-shadow .2s,background .2s;width:100%;
}
input:focus,select:focus{background:#fff}
input.ais-focus:focus{border-color:#4d9a0e;box-shadow:0 0 0 3px rgba(77,154,14,.1)}
input.true-focus:focus{border-color:#d80e1c;box-shadow:0 0 0 3px rgba(216,14,28,.09)}
input.ssh-focus:focus{border-color:#1568a6;box-shadow:0 0 0 3px rgba(21,104,166,.1)}
input.mgmt-focus:focus{border-color:#7c3aed;box-shadow:0 0 0 3px rgba(124,58,237,.1)}

/* link-box upgrade */
.link-box{
  background:#f0f5fb;border-radius:10px;padding:.7rem .9rem;
  font-family:"Share Tech Mono",monospace;font-size:.62rem;
  word-break:break-all;line-height:1.75;margin-bottom:.75rem;
  border:1px solid #dde3ec;color:var(--text2);
}
.link-box.vless-link{border-left:3px solid #4d9a0e;color:#316808}
.link-box.npv-link{border-left:3px solid #1568a6;color:#0c4f84}
.link-box.dark-link{border-left:3px solid #7c3aed;color:#5b21b6}

/* copy buttons upgrade */
.copy-btn{
  flex:1;min-width:110px;padding:.52rem .7rem;
  border-radius:10px;border:1.5px solid var(--border);
  background:#fff;font-family:"Rajdhani",sans-serif;font-size:.85rem;
  font-weight:700;letter-spacing:.06em;cursor:pointer;
  transition:all .18s;color:var(--text2);
}
.copy-btn.vless{border-color:#b5e08a;color:#316808}
.copy-btn.vless:hover{background:#edf7e3;border-color:#4d9a0e}
.copy-btn.npv{border-color:#82c0ee;color:#0c4f84}
.copy-btn.npv:hover{background:#e6f3fc;border-color:#1568a6}
.copy-btn.ssh-copy{border-color:#82c0ee;color:#0c4f84}
.copy-btn.ssh-copy:hover{background:#e6f3fc;border-color:#1568a6}

/* port tabs upgrade */
.port-tab{
  flex:1;padding:.5rem;border-radius:10px;font-size:.8rem;cursor:pointer;
  border:1.5px solid #d8e2ee;background:#f6f9fc;color:var(--text2);
  font-family:"Rajdhani",sans-serif;font-weight:600;transition:all .18s;
}
.port-tab.active-ssh{border-color:#1568a6;background:#e6f3fc;color:#0c4f84}

/* action card upgrade */
.action-card{
  background:#f6f9fc;border:1.5px solid #d8e2ee;border-radius:14px;
  padding:.9rem .9rem;cursor:pointer;transition:all .18s;text-align:center;
}
.action-card:hover{border-color:#1568a6;background:#e6f3fc;transform:translateY(-1px)}
.action-card.selected{border-color:#7c3aed;background:#f5f3ff;box-shadow:0 0 0 3px rgba(124,58,237,.08)}

/* result card upgrade */
.result-card{
  display:none;margin-top:1.1rem;border-radius:16px;overflow:hidden;
  border:1.5px solid var(--border);box-shadow:0 4px 16px rgba(0,0,0,.07);
}
.result-card.show{display:block}

/* bg upgrade */
:root { --bg: #ebeff6; }
.main{max-width:520px;margin:0 auto;padding:1.5rem 1rem 4rem;display:flex;flex-direction:column;gap:1.3rem}


/* ══════════════════════════════════════
   ONLINE USER ROWS — data bar style
══════════════════════════════════════ */
.online-user-row{
  padding:.85rem 1.2rem;border-bottom:1px solid var(--border);
  display:flex;align-items:flex-start;gap:.9rem;
  transition:background .15s;
}
.online-user-row:last-child{border-bottom:none}
.online-user-row:hover{background:#f6faff}
.online-avatar{
  width:40px;height:40px;border-radius:12px;
  display:flex;align-items:center;justify-content:center;
  font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.95rem;
  flex-shrink:0;border:1px solid;
}
.online-info{flex:1;min-width:0}
.online-name{
  display:flex;align-items:center;gap:.5rem;
  font-weight:600;font-size:.88rem;color:var(--text);margin-bottom:.35rem;
  flex-wrap:wrap;
}
.online-port-chip{
  font-family:'Share Tech Mono',monospace;font-size:.6rem;
  background:#eff6ff;border:1px solid #93c5fd;color:#1e40af;
  padding:.1rem .45rem;border-radius:20px;flex-shrink:0;
}
.online-data-row{display:flex;align-items:center;gap:.55rem;margin-bottom:.28rem}
.online-data-bar-wrap{
  flex:1;height:7px;background:#e8eef5;border-radius:4px;overflow:hidden;
}
.online-data-bar{
  height:100%;border-radius:4px;
  transition:width .8s cubic-bezier(.4,0,.2,1);
}
.online-data-label{
  font-family:'Share Tech Mono',monospace;font-size:.62rem;
  color:var(--text3);white-space:nowrap;flex-shrink:0;
}
.online-exp{font-size:.68rem;font-family:'Share Tech Mono',monospace;}
.online-exp.exp-ok  {color:#16a34a}
.online-exp.exp-warn{color:#ea6c10}
.online-exp.exp-dead{color:#dc2626}
.online-live-dot{
  width:10px;height:10px;border-radius:50%;flex-shrink:0;margin-top:4px;
  background:#22c55e;
  box-shadow:0 0 0 3px rgba(34,197,94,.2);
  animation:livePulse 1.8s ease-in-out infinite;
}
@keyframes livePulse{
  0%,100%{box-shadow:0 0 0 3px rgba(34,197,94,.2)}
  50%{box-shadow:0 0 0 6px rgba(34,197,94,.05)}
}

/* ══════════════════════════════════════
   RGB STAT CARD ACCENTS
══════════════════════════════════════ */
.stat-card{
  background:var(--surface);border-radius:18px;
  padding:1.1rem 1.15rem;border:1px solid var(--border);
  box-shadow:0 2px 14px rgba(0,0,0,.07);
  position:relative;overflow:hidden;
  transition:box-shadow .2s,transform .2s;
}
.stat-card:hover{
  box-shadow:0 6px 28px rgba(0,0,0,.11);
  transform:translateY(-1px);
}
/* เส้น RGB บนสุด card */
.stat-card::before{
  content:'';position:absolute;top:0;left:0;right:0;height:2px;
  background:linear-gradient(90deg,#7ee8fa,#a78bfa,#80ff72,#f9a8d4,#7ee8fa);
  background-size:300% auto;
  animation:rgbShift 6s linear infinite;
  opacity:0;transition:opacity .3s;
}
.stat-card:hover::before{opacity:1}

/* RGB glow ใน section label */
.section-label .lbl-text{font-size:.9rem;font-weight:700;letter-spacing:.16em}

/* ══════════════════════════════════════
   SNOWFLAKE CSS ANIMATION (fallback)
══════════════════════════════════════ */
@keyframes snowFall{
  0%  {transform:translateY(-20px) rotate(0deg);opacity:0}
  10% {opacity:.8}
  90% {opacity:.6}
  100%{transform:translateY(160px) rotate(360deg);opacity:0}
}

</style>
<script src="config.js"></script>
</head>
<body>

<!-- ─── HEADER ─── -->
<div class="site-header">
  <canvas id="snow-canvas"></canvas>
  <div class="site-logo">CHAIYA V2RAY PRO MAX</div>
  <div class="site-title">USER <span class="rgb-word">CREATOR</span></div>
  <div class="site-sub">สร้างบัญชี VLESS <span class="dot">·</span> SSH-WS ผ่านหน้าเว็บ <span class="dot">·</span> v8</div>
  <button onclick="doLogout()" style="position:absolute;top:1rem;right:1rem;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.12);color:rgba(255,255,255,.45);border-radius:8px;padding:.3rem .75rem;font-family:'Share Tech Mono',monospace;font-size:.62rem;cursor:pointer;z-index:10;transition:all .2s" onmouseover="this.style.color='rgba(248,113,113,.8)'" onmouseout="this.style.color='rgba(255,255,255,.45)'">⎋ ออกจากระบบ</button>
</div>

<!-- ─── TAB NAV ─── -->
<nav class="tab-nav">
  <button class="tab-btn active" onclick="switchTab('dash')">📊 แดชบอร์ด</button>
  <button class="tab-btn" onclick="switchTab('create')">➕ สร้างยูส</button>
  <button class="tab-btn" onclick="switchTab('manage')">🔧 จัดการยูส</button>
  <button class="tab-btn" onclick="switchTab('online')">🟢 ออนไลน์</button>
</nav>

<!-- ══════════════════════════════════════
     TAB: DASHBOARD
══════════════════════════════════════ -->
<div class="tab-panel active" id="tab-dash">
<div class="main">

  <!-- Refresh row -->
  <div style="display:flex;align-items:center;justify-content:space-between">
    <span style="font-family:'Rajdhani',sans-serif;font-weight:700;font-size:.9rem;color:var(--text2);letter-spacing:.1em">SYSTEM MONITOR</span>
    <button class="refresh-btn" id="refresh-btn" onclick="loadStats()">
      <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:4px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
      รีเฟรช
    </button>
  </div>

  <!-- Stats Grid -->
  <div class="stats-grid">

    <!-- CPU -->
    <div class="stat-card">
      <div class="stat-label">⚡ CPU Usage</div>
      <div class="ring-wrap">
        <svg class="ring-svg" width="64" height="64" viewBox="0 0 64 64">
          <circle class="ring-track" cx="32" cy="32" r="26"/>
          <circle class="ring-fill" id="cpu-ring" cx="32" cy="32" r="26"
            stroke="#5a9e1c"
            stroke-dasharray="163.4"
            stroke-dashoffset="163.4"
            transform="rotate(-90 32 32)"/>
        </svg>
        <div class="ring-info">
          <div class="stat-value" id="cpu-val">--<span class="stat-unit">%</span></div>
          <div class="stat-sub" id="cpu-cores">-- cores</div>
        </div>
      </div>
      <div class="bar-gauge"><div class="bar-fill" id="cpu-bar" style="width:0%;background:linear-gradient(90deg,#5a9e1c,#8dc63f)"></div></div>
    </div>

    <!-- RAM -->
    <div class="stat-card">
      <div class="stat-label">🧠 RAM Usage</div>
      <div class="ring-wrap">
        <svg class="ring-svg" width="64" height="64" viewBox="0 0 64 64">
          <circle class="ring-track" cx="32" cy="32" r="26"/>
          <circle class="ring-fill" id="ram-ring" cx="32" cy="32" r="26"
            stroke="#1a6fa8"
            stroke-dasharray="163.4"
            stroke-dashoffset="163.4"
            transform="rotate(-90 32 32)"/>
        </svg>
        <div class="ring-info">
          <div class="stat-value" id="ram-val">--<span class="stat-unit">%</span></div>
          <div class="stat-sub" id="ram-detail">-- / -- GB</div>
        </div>
      </div>
      <div class="bar-gauge"><div class="bar-fill" id="ram-bar" style="width:0%;background:linear-gradient(90deg,#1a6fa8,#40b0ff)"></div></div>
    </div>

    <!-- Disk -->
    <div class="stat-card">
      <div class="stat-label">💾 Disk Usage</div>
      <div class="stat-value" id="disk-val">--<span class="stat-unit">%</span></div>
      <div class="stat-sub" id="disk-detail">-- / -- GB</div>
      <div class="bar-gauge"><div class="bar-fill" id="disk-bar" style="width:0%;background:linear-gradient(90deg,#f97316,#fb923c)"></div></div>
    </div>

    <!-- Uptime -->
    <div class="stat-card">
      <div class="stat-label">⏱ Uptime</div>
      <div class="stat-value" style="font-size:1.3rem" id="uptime-val">--</div>
      <div class="stat-sub" id="uptime-sub">กำลังโหลด...</div>
      <div style="margin-top:.5rem" id="load-avg-chips"></div>
    </div>

    <!-- Network -->
    <div class="stat-card wide">
      <div class="stat-label" style="margin-bottom:.6rem">🌐 Network I/O</div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:.6rem">
        <div>
          <div style="font-size:.7rem;color:var(--text3);font-family:'Share Tech Mono',monospace">↑ Upload</div>
          <div class="stat-value" style="font-size:1.3rem" id="net-up">--</div>
          <div class="stat-sub" id="net-up-total">total: --</div>
        </div>
        <div>
          <div style="font-size:.7rem;color:var(--text3);font-family:'Share Tech Mono',monospace">↓ Download</div>
          <div class="stat-value" style="font-size:1.3rem" id="net-down">--</div>
          <div class="stat-sub" id="net-down-total">total: --</div>
        </div>
      </div>
    </div>

    <!-- x-ui status -->
    <div class="stat-card wide">
      <div class="stat-label" style="margin-bottom:.7rem">📡 x-ui Panel Status</div>
      <div style="display:flex;align-items:center;gap:.8rem;flex-wrap:wrap">
        <div id="xui-status-badge">
          <span class="chip">ตรวจสอบ...</span>
        </div>
        <div style="flex:1">
          <div style="font-size:.78rem;color:var(--text2)" id="xui-ver">เวอร์ชัน: --</div>
          <div style="font-size:.72rem;color:var(--text3);font-family:'Share Tech Mono',monospace" id="xui-traffic">Traffic inbounds: --</div>
        </div>
      </div>
    </div>


    <!-- Service Monitor -->
    <div class="stat-card wide" id="svc-card">
      <div class="stat-label" style="margin-bottom:.8rem;display:flex;align-items:center;justify-content:space-between;flex-wrap:nowrap">
        <span>🛠 SERVICE MONITOR</span>
        <button class="refresh-btn" id="svc-refresh-btn" onclick="loadServiceStatus()" style="padding:.2rem .65rem;font-size:.7rem">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
          เช็คสถานะ
        </button>
      </div>
      <div id="svc-list">
        <div class="loading-row" style="padding:.5rem 0"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--ssh)"></span>กำลังตรวจสอบ...</div>
      </div>
    </div>



  </div><!-- /stats-grid -->

  <div style="font-size:.72rem;color:var(--text3);text-align:center;font-family:'Share Tech Mono',monospace" id="last-update">อัพเดทล่าสุด: --</div>
</div>
</div>

<!-- ══════════════════════════════════════
     TAB: CREATE
══════════════════════════════════════ -->
<div class="tab-panel" id="tab-create">
<div class="main">
  <!-- VLESS Section -->
  <div>
    <div class="section-label"><span>📡</span><span class="lbl-text">ระบบ 3X-UI VLESS</span></div>
    <div class="card-group">
      <button class="carrier-btn btn-ais" onclick="openModal('ais')">
        <div class="btn-logo logo-ais">
          <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/4/4e/AIS_Logo.svg/200px-AIS_Logo.svg.png" alt="AIS" style="width:42px;height:42px;object-fit:contain" onerror="this.style.display='none';this.nextElementSibling.style.display='block'">
          <span style="display:none;color:#5a9e1c;font-family:'Rajdhani',sans-serif;font-weight:900;font-size:1.1rem">AIS</span>
        </div>
        <div class="btn-info">
          <span class="btn-name">AIS — กันรั่ว</span>
          <span class="btn-desc">VLESS · Port 8080 · WS · cj-ebb.speedtest.net</span>
        </div>
        <span class="btn-arrow">›</span>
      </button>
      <button class="carrier-btn btn-true" onclick="openModal('true')">
        <div class="btn-logo logo-true">
          <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/True_Corporation_Logo.svg/200px-True_Corporation_Logo.svg.png" alt="TRUE" style="width:44px;height:44px;object-fit:contain;filter:brightness(0) invert(1)" onerror="this.style.display='none';this.nextElementSibling.style.display='block'">
          <span style="display:none;color:#fff;font-family:Arial,sans-serif;font-weight:900;font-size:1rem">true</span>
        </div>
        <div class="btn-info">
          <span class="btn-name">TRUE — VDO</span>
          <span class="btn-desc">VLESS · Port 8880 · WS · true-internet.zoom.xyz.services</span>
        </div>
        <span class="btn-arrow">›</span>
      </button>
    </div>
  </div>
  <!-- SSH Section -->
  <div>
    <div class="section-label"><span>🔑</span><span class="lbl-text">ระบบ SSH WEBSOCKET</span></div>
    <div class="card-group">
      <button class="carrier-btn btn-ssh" onclick="openModal('ssh')">
        <div class="btn-logo logo-ssh">
          <svg width="30" height="30" viewBox="0 0 34 34" fill="none">
            <rect x="2" y="4" width="30" height="22" rx="4" fill="none" stroke="#90caf0" stroke-width="2"/>
            <rect x="2" y="4" width="30" height="6" rx="4" fill="rgba(255,255,255,.2)"/>
            <text x="6" y="20" font-family="monospace" font-weight="700" font-size="10" fill="#fff">SSH&gt;_</text>
            <line x1="10" y1="26" x2="10" y2="30" stroke="#90caf0" stroke-width="2"/>
            <line x1="24" y1="26" x2="24" y2="30" stroke="#90caf0" stroke-width="2"/>
            <line x1="6" y1="30" x2="28" y2="30" stroke="#90caf0" stroke-width="2"/>
          </svg>
        </div>
        <div class="btn-info">
          <span class="btn-name">SSH — WS Tunnel</span>
          <span class="btn-desc">SSH · Port 80 · Dropbear 143/109 · NpvTunnel / DarkTunnel</span>
        </div>
        <span class="btn-arrow">›</span>
      </button>
    </div>
  </div>
</div>
</div>

<!-- ══════════════════════════════════════
     TAB: MANAGE
══════════════════════════════════════ -->
<div class="tab-panel" id="tab-manage">
<div class="main">
  <div class="mgmt-panel">
    <div class="mgmt-header">
      <div class="mgmt-title">🔧 จัดการยูสเซอร์ VLESS</div>
      <button class="refresh-btn" onclick="loadUserList()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        โหลด
      </button>
    </div>
    <div class="search-bar">
      <input type="text" id="search-input" placeholder="🔍 ค้นหา username..." oninput="filterUsers(this.value)">
    </div>
    <div class="user-list" id="user-list">
      <div class="empty-state">
        <div class="ei">📋</div>
        <div>กดปุ่ม "โหลด" เพื่อดึงข้อมูลยูสเซอร์</div>
      </div>
    </div>
  </div>
</div>
</div>

<!-- ══════════════════════════════════════
     TAB: ONLINE
══════════════════════════════════════ -->
<div class="tab-panel" id="tab-online">
<div class="main">
  <div class="mgmt-panel">
    <div class="mgmt-header">
      <div class="mgmt-title">🟢 ยูสเซอร์ออนไลน์ตอนนี้</div>
      <button class="refresh-btn" id="online-refresh" onclick="loadOnlineUsers()">
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" style="vertical-align:middle;margin-right:3px"><path d="M23 4v6h-6"/><path d="M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>
        รีเฟรช
      </button>
    </div>
    <div style="padding:.7rem 1.2rem;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:.7rem">
      <span id="online-count-badge" class="online-badge"><span class="online-dot"></span><span id="online-count">0</span> ออนไลน์</span>
      <span style="font-size:.75rem;color:var(--text3)" id="online-time">--</span>
    </div>
    <div class="user-list" id="online-list">
      <div class="empty-state">
        <div class="ei">🟢</div>
        <div>กดรีเฟรชเพื่อดูยูสออนไลน์</div>
      </div>
    </div>
  </div>
</div>
</div>

<!-- ══════════════════════════════════════
     MODAL: AIS CREATE
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-ais">
  <div class="modal modal-ais">
    <div class="modal-header">
      <span class="modal-title">
        <img src="https://upload.wikimedia.org/wikipedia/commons/thumb/4/4e/AIS_Logo.svg/200px-AIS_Logo.svg.png" style="height:20px;width:auto;object-fit:contain" onerror="this.style.display='none'">
        AIS — กันรั่ว
      </span>
      <button class="modal-close" onclick="closeModal('ais')">✕</button>
    </div>
    <div class="modal-body">
      <div class="sni-badge ais">📡 Port 8080 · SNI: cj-ebb.speedtest.net · VLESS-WS</div>
      <div class="fgrid">
        <div class="field span2"><label>👤 Username</label><input type="text" id="ais-user" placeholder="chaiya01" class="ais-focus" oninput="syncField('ais-user','ais-email')"></div>
        <div class="field"><label>📅 วันใช้งาน</label><input type="number" id="ais-days" value="30" min="1" class="ais-focus"></div>
        <div class="field"><label>📦 Data (GB, 0=∞)</label><input type="number" id="ais-data" value="0" min="0" class="ais-focus"></div>
        <div class="field"><label>📱 IP Limit</label><input type="number" id="ais-iplimit" value="2" min="1" class="ais-focus"></div>
        <div class="field span2"><label>🌐 Email (Client ID)</label><input type="text" id="ais-email" placeholder="chaiya01" class="ais-focus"></div>
        <div class="field span2"><label>🔒 SNI (Host Header)</label><input type="text" id="ais-sni" value="cj-ebb.speedtest.net" class="ais-focus"></div>
      </div>
      <button class="submit-btn ais-btn" id="ais-submit" onclick="createVless('ais')">⚡ สร้าง AIS Account</button>
      <div class="alert" id="ais-alert"></div>
      <div class="result-card" id="ais-result">
        <div class="result-header ais-r"><span class="dot"></span>✅ สร้างสำเร็จ — AIS VLESS</div>
        <div class="result-body">
          <div class="info-rows" id="ais-info"></div>
          <div class="qr-wrap"><div class="qr-inner" id="ais-qr"></div></div>
          <div class="link-box vless-link" id="ais-vless-link"></div>
          <div class="copy-row">
            <button class="copy-btn vless" onclick="copyText('ais-vless-link','ais-copy-vless')" id="ais-copy-vless">⎘ VLESS Link</button>
            <button class="copy-btn npv" onclick="copyNpvDirect('ais')" id="ais-copy-npv">📥 NPV Import</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════
     MODAL: TRUE CREATE
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-true">
  <div class="modal modal-true">
    <div class="modal-header">
      <span class="modal-title">
        <span style="background:#c8040d;border-radius:5px;padding:1px 6px;font-size:.82rem;color:#fff;font-family:Arial,sans-serif;font-weight:900">true</span>
        TRUE — VDO
      </span>
      <button class="modal-close" onclick="closeModal('true')">✕</button>
    </div>
    <div class="modal-body">
      <div class="sni-badge true">📡 Port 8880 · SNI: true-internet.zoom.xyz.services · VLESS-WS</div>
      <div class="fgrid">
        <div class="field span2"><label>👤 Username</label><input type="text" id="true-user" placeholder="chaiya01" class="true-focus" oninput="syncField('true-user','true-email')"></div>
        <div class="field"><label>📅 วันใช้งาน</label><input type="number" id="true-days" value="30" min="1" class="true-focus"></div>
        <div class="field"><label>📦 Data (GB, 0=∞)</label><input type="number" id="true-data" value="0" min="0" class="true-focus"></div>
        <div class="field"><label>📱 IP Limit</label><input type="number" id="true-iplimit" value="2" min="1" class="true-focus"></div>
        <div class="field span2"><label>🌐 Email (Client ID)</label><input type="text" id="true-email" placeholder="chaiya01" class="true-focus"></div>
        <div class="field span2"><label>🔒 SNI (Host Header)</label><input type="text" id="true-sni" value="true-internet.zoom.xyz.services" class="true-focus"></div>
      </div>
      <button class="submit-btn true-btn" id="true-submit" onclick="createVless('true')">⚡ สร้าง TRUE Account</button>
      <div class="alert" id="true-alert"></div>
      <div class="result-card" id="true-result">
        <div class="result-header true-r"><span class="dot"></span>✅ สร้างสำเร็จ — TRUE VLESS</div>
        <div class="result-body">
          <div class="info-rows" id="true-info"></div>
          <div class="qr-wrap"><div class="qr-inner" id="true-qr"></div></div>
          <div class="link-box vless-link" id="true-vless-link"></div>
          <div class="copy-row">
            <button class="copy-btn vless" onclick="copyText('true-vless-link','true-copy-vless')" id="true-copy-vless">⎘ VLESS Link</button>
            <button class="copy-btn npv" onclick="copyNpvDirect('true')" id="true-copy-npv">📥 NPV Import</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════
     MODAL: SSH CREATE
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-ssh">
  <div class="modal modal-ssh">
    <div class="modal-header">
      <span class="modal-title">🔐 SSH WebSocket</span>
      <button class="modal-close" onclick="closeModal('ssh')">✕</button>
    </div>
    <div class="modal-body">
      <div class="sni-badge ssh">🔑 Dropbear 143/109 · WS Port 80 · NpvTunnel / DarkTunnel</div>
      <div class="field" style="margin-bottom:.8rem">
        <label>🔌 WS Port</label>
        <div class="port-tabs">
          <button class="port-tab active-ssh" id="ssh-tab-80" onclick="sshSelPort(80)">Port 80 — HTTP-WS</button>
          <button class="port-tab" id="ssh-tab-443" onclick="sshSelPort(443)">Port 443 — WSS 🔒</button>
        </div>
      </div>
      <div class="fgrid">
        <div class="field span2"><label>👤 Username</label><input type="text" id="ssh-user" placeholder="chaiya01" class="ssh-focus"></div>
        <div class="field"><label>🔑 Password</label><input type="text" id="ssh-pass" placeholder="pass1234" class="ssh-focus"></div>
        <div class="field"><label>📅 วันใช้งาน</label><input type="number" id="ssh-days" value="30" min="1" class="ssh-focus"></div>
        <div class="field"><label>📱 IP Limit</label><input type="number" id="ssh-iplimit" value="2" min="1" class="ssh-focus"></div>
        <div class="field span2" style="display:none" id="ssh-sni-field"><label>🌐 SNI / Host</label><input type="text" id="ssh-sni" placeholder="your-domain.com" class="ssh-focus"></div>
      </div>
      <div class="divider"></div>
      <div style="margin-bottom:.6rem">
        <label style="margin-bottom:.4rem;display:block">📱 แอพ Import Link</label>
        <div class="port-tabs">
          <button class="port-tab active-ssh" id="ssh-app-npv" onclick="sshSelApp('npv')">NpvTunnel</button>
          <button class="port-tab" id="ssh-app-dark" onclick="sshSelApp('dark')">DarkTunnel</button>
        </div>
      </div>
      <div style="margin-bottom:.8rem">
        <label style="margin-bottom:.4rem;display:block">🌐 Operator / Payload</label>
        <div class="port-tabs">
          <button class="port-tab active-ssh pro-tab" id="ssh-pro-dtac" onclick="sshSelPro('dtac')">DTAC GAMING</button>
          <button class="port-tab pro-tab" id="ssh-pro-true" onclick="sshSelPro('true')">TRUE TWITTER</button>
        </div>
      </div>
      <button class="submit-btn ssh-btn" id="ssh-submit" onclick="createSSH()">⚡ สร้าง SSH Account</button>
      <div class="alert" id="ssh-alert"></div>
      <div class="result-card" id="ssh-result">
        <div class="result-header ssh-r"><span class="dot"></span>✅ สร้างสำเร็จ — SSH WS</div>
        <div class="result-body">
          <div class="info-rows" id="ssh-info"></div>
          <div class="link-box npv-link" id="ssh-import-link" style="word-break:break-all"></div>
          <div class="copy-row">
            <button class="copy-btn ssh-copy" onclick="copyEl('ssh-import-link','ssh-copy-import')" id="ssh-copy-import">⎘ Copy Import Link</button>
            <button class="copy-btn ssh-copy" onclick="copySSHInfo()" id="ssh-copy-info">📋 ข้อมูล SSH</button>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- ══════════════════════════════════════
     MODAL: USER MANAGEMENT
══════════════════════════════════════ -->
<div class="modal-overlay" id="modal-mgmt">
  <div class="modal modal-mgmt">
    <div class="modal-header">
      <span class="modal-title" id="mgmt-modal-title">⚙️ จัดการยูส</span>
      <button class="modal-close" onclick="closeModal('mgmt')">✕</button>
    </div>
    <div class="modal-body">
      <!-- User Detail -->
      <div class="udetail" id="mgmt-user-detail"></div>

      <!-- Action Selector -->
      <label style="margin-bottom:.5rem;display:block">เลือกการดำเนินการ</label>
      <div class="action-grid">
        <div class="action-card" id="act-renew" onclick="selectAction('renew')">
          <div class="action-icon">🔄</div>
          <div class="action-name">ต่ออายุ</div>
          <div class="action-desc">รีเซตจากวันนี้</div>
        </div>
        <div class="action-card" id="act-adddays" onclick="selectAction('adddays')">
          <div class="action-icon">📅</div>
          <div class="action-name">เพิ่มวัน</div>
          <div class="action-desc">ต่อจากวันหมด</div>
        </div>
        <div class="action-card" id="act-adddata" onclick="selectAction('adddata')">
          <div class="action-icon">📦</div>
          <div class="action-name">เพิ่ม Data</div>
          <div class="action-desc">เติม GB เพิ่ม</div>
        </div>
        <div class="action-card" id="act-setdata" onclick="selectAction('setdata')">
          <div class="action-icon">⚖️</div>
          <div class="action-name">ตั้ง Data</div>
          <div class="action-desc">กำหนดใหม่</div>
        </div>
        <div class="action-card" id="act-resettraffic" onclick="selectAction('resettraffic')">
          <div class="action-icon">🔃</div>
          <div class="action-name">รีเซต Traffic</div>
          <div class="action-desc">เคลียร์ยอดใช้</div>
        </div>
        <div class="action-card" id="act-delete" onclick="selectAction('delete')">
          <div class="action-icon">🗑️</div>
          <div class="action-name">ลบยูส</div>
          <div class="action-desc">ลบถาวร</div>
        </div>
      </div>

      <!-- Action Detail Form -->
      <div id="action-form" style="margin-top:1rem;display:none">
        <div class="divider"></div>
        <!-- Renew -->
        <div id="form-renew" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>📅 วันใช้งานใหม่ (นับจากวันนี้)</label><input type="number" id="mgmt-renew-days" value="30" min="1" class="mgmt-focus"></div>
            <div class="field span2"><label>📦 Data Limit (GB, 0=∞)</label><input type="number" id="mgmt-renew-data" value="0" min="0" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('renew')">🔄 ต่ออายุยูสเซอร์</button>
        </div>
        <!-- Add Days -->
        <div id="form-adddays" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>📅 เพิ่มกี่วัน (ต่อจากวันหมดอายุเดิม)</label><input type="number" id="mgmt-adddays-val" value="30" min="1" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('adddays')">📅 เพิ่มวัน</button>
        </div>
        <!-- Add Data -->
        <div id="form-adddata" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>📦 เพิ่ม Data กี่ GB</label><input type="number" id="mgmt-adddata-val" value="10" min="1" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('adddata')">📦 เพิ่ม Data</button>
        </div>
        <!-- Set Data -->
        <div id="form-setdata" style="display:none">
          <div class="fgrid">
            <div class="field span2"><label>⚖️ ตั้ง Data ใหม่ (GB, 0=ไม่จำกัด)</label><input type="number" id="mgmt-setdata-val" value="30" min="0" class="mgmt-focus"></div>
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('setdata')">⚖️ ตั้ง Data</button>
        </div>
        <!-- Reset Traffic -->
        <div id="form-resettraffic" style="display:none">
          <div style="background:#fff7ed;border:1px solid #fed7aa;border-radius:10px;padding:.75rem .9rem;font-size:.82rem;color:#92400e;margin-bottom:.8rem">
            ⚠️ การรีเซต Traffic จะเคลียร์ยอดใช้งาน Up/Down ของยูสนี้ให้กลับเป็น 0
          </div>
          <button class="submit-btn mgmt-btn" onclick="doAction('resettraffic')">🔃 รีเซต Traffic</button>
        </div>
        <!-- Delete -->
        <div id="form-delete" style="display:none">
          <div style="background:#fef2f2;border:1px solid #fca5a5;border-radius:10px;padding:.75rem .9rem;font-size:.82rem;color:#991b1b;margin-bottom:.8rem">
            ⚠️ ยืนยันการลบยูสเซอร์นี้ถาวร ไม่สามารถกู้คืนได้
          </div>
          <button class="submit-btn danger-btn" onclick="doAction('delete')">🗑️ ยืนยันลบยูสเซอร์</button>
        </div>
      </div>

      <div class="alert" id="mgmt-alert"></div>
    </div>
  </div>
</div>

<!-- Toast -->
<div class="toast" id="toast"></div>

<script>
/* ══════════════════════════════════════
   CONFIG
══════════════════════════════════════ */

/* ══════════════════════════════════════
   SESSION GUARD — เช็ค login ก่อน
══════════════════════════════════════ */
(function(){
  const SESSION_KEY = 'chaiya_auth';
  const LOGIN_PAGE  = 'index.html';
  const saved = sessionStorage.getItem(SESSION_KEY);
  if (!saved) { window.location.replace(LOGIN_PAGE); return; }
  try {
    const s = JSON.parse(saved);
    // รองรับทั้ง token (ระบบใหม่) และ user/pass (ระบบเก่า)
    const valid = (s.token || (s.user && s.pass)) && Date.now() < s.exp;
    if (!valid) {
      sessionStorage.removeItem(SESSION_KEY);
      window.location.replace(LOGIN_PAGE);
    }
  } catch(e) {
    sessionStorage.removeItem(SESSION_KEY);
    window.location.replace(LOGIN_PAGE);
  }
})();

const CFG    = (typeof window.CHAIYA_CONFIG !== 'undefined') ? window.CHAIYA_CONFIG : {};
const HOST   = CFG.host       || location.hostname;
const XUI_API = '/xui-api';
const SSH_API = '/api';
const TOK    = CFG.ssh_token  || '';

const PROS = {
  dtac:{ name:'DTAC GAMING', proxy:'104.18.63.124:80',
    payload:'CONNECT /  HTTP/1.1 [crlf]Host: dl.dir.freefiremobile.com [crlf][crlf]PATCH / HTTP/1.1[crlf]Host:[host][crlf]Upgrade:User-Agent: [ua][crlf][crlf]',
    darkProxy:'104.18.63.124', darkProxyPort:80 },
  true:{ name:'TRUE TWITTER', proxy:'104.18.39.24:80',
    payload:'POST / HTTP/1.1[crlf]Host: help.x.com[crlf]User-Agent: [ua][crlf][crlf][split][cr]PATCH / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]',
    darkProxy:'104.18.39.24', darkProxyPort:80 }
};

let _sshPort=80, _sshApp='npv', _sshPro='dtac';
let _aisSaved=null, _trueSaved=null, _sshSaved=null;
let _xuiCookieSet=false;
let _allUsers=[], _filteredUsers=[];
let _mgmtUser=null, _mgmtInbound=null, _mgmtAction=null;

/* ══════════════════════════════════════
   TAB SWITCH
══════════════════════════════════════ */
function switchTab(tab) {
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-'+tab).classList.add('active');
  event.currentTarget.classList.add('active');
  if(tab==='dash') loadStats();
  if(tab==='online') loadOnlineUsers();
  if(tab==='manage') loadUserList();
}

/* ══════════════════════════════════════
   MODAL
══════════════════════════════════════ */
function openModal(id){document.getElementById('modal-'+id).classList.add('open');document.body.style.overflow='hidden'}
function closeModal(id){document.getElementById('modal-'+id).classList.remove('open');document.body.style.overflow=''}
document.querySelectorAll('.modal-overlay').forEach(el=>{ el.classList.remove('open');
  el.addEventListener('click',e=>{if(e.target===el){el.classList.remove('open');document.body.style.overflow=''}});
});

/* ══════════════════════════════════════
   UTILITY
══════════════════════════════════════ */
function syncField(s,d){document.getElementById(d).value=document.getElementById(s).value}
function val(id){return document.getElementById(id).value.trim()}
function setAlert(pre,msg,type){
  const el=document.getElementById(pre+'-alert');
  el.className='alert '+type; el.textContent=msg; el.style.display=msg?'block':'none';
}
function setLoading(id,on){
  const btn=document.getElementById(id+'-submit');
  if(!btn)return;
  btn.disabled=on;
  btn.innerHTML=on?'<span class="spinner"></span> กำลังดำเนินการ...'
    :(id==='ais'?'⚡ สร้าง AIS Account':id==='true'?'⚡ สร้าง TRUE Account':'⚡ สร้าง SSH Account');
}
function toast(msg,ok=true){
  const el=document.getElementById('toast');
  el.textContent=msg; el.style.background=ok?'#1a2332':'#ef4444';
  el.classList.add('show'); setTimeout(()=>el.classList.remove('show'),2400);
}
function genUUID(){
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,c=>{
    const r=Math.random()*16|0;return(c==='x'?r:(r&0x3|0x8)).toString(16);
  });
}
function fmtBytes(bytes){
  if(bytes===0)return'0 B';
  const k=1024,s=['B','KB','MB','GB','TB'];
  const i=Math.floor(Math.log(bytes)/Math.log(k));
  return(bytes/Math.pow(k,i)).toFixed(1)+' '+s[i];
}
function copyText(elId,btnId){copyToClipboard(document.getElementById(elId).textContent.trim(),btnId)}
function copyEl(elId,btnId){copyToClipboard(document.getElementById(elId).textContent.trim(),btnId)}
function copyToClipboard(text,btnId){
  const done=()=>{
    toast('📋 คัดลอกแล้ว!');
    if(btnId){const b=document.getElementById(btnId);if(b){const o=b.textContent;b.textContent='✓ Copied!';b.classList.add('copied');setTimeout(()=>{b.textContent=o;b.classList.remove('copied')},2000)}}
  };
  if(navigator.clipboard)navigator.clipboard.writeText(text).then(done).catch(()=>fbCopy(text,done));
  else fbCopy(text,done);
  function fbCopy(t,cb){const ta=document.createElement('textarea');ta.value=t;ta.style.cssText='position:fixed;top:0;left:0;opacity:0;';document.body.appendChild(ta);ta.focus();ta.select();try{document.execCommand('copy');cb()}catch(e){toast('❌ คัดลอกไม่ได้',false)}document.body.removeChild(ta)}
}

/* ══════════════════════════════════════
   x-ui API
══════════════════════════════════════ */
async function xuiLogin(){
  const SESSION_KEY = 'chaiya_auth';
  let user = 'poo', pass = 'poo';
  try {
    const s = JSON.parse(sessionStorage.getItem(SESSION_KEY)||'{}');
    if(s.user) user = s.user;
    if(s.pass) pass = s.pass;
  } catch(e){}
  const form=new URLSearchParams({username:user,password:pass});
  const r=await fetch(XUI_API+'/login',{method:'POST',credentials:'include',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:form.toString()});
  const d=await r.json(); _xuiCookieSet=!!d.success; return d.success;
}
async function xuiPost(path,payload){
  if(!_xuiCookieSet)await xuiLogin();
  const r=await fetch(XUI_API+path,{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
  return r.json();
}
async function xuiGet(path){
  if(!_xuiCookieSet)await xuiLogin();
  const r=await fetch(XUI_API+path,{credentials:'include'}); return r.json();
}
async function getInboundId(port){
  const d=await xuiGet('/panel/api/inbounds/list');
  if(!d.success)return null;
  const ib=(d.obj||[]).find(x=>x.port===port);
  return ib?ib.id:null;
}

/* ══════════════════════════════════════
   SYSTEM STATS
══════════════════════════════════════ */
function setRing(id,pct,color){
  const el=document.getElementById(id);
  if(!el)return;
  const circ=163.4;
  el.style.stroke=color||el.style.stroke;
  el.style.strokeDashoffset=circ-(circ*Math.min(pct,100)/100);
}
function setBar(id,pct){
  const el=document.getElementById(id);
  if(el)el.style.width=Math.min(pct,100)+'%';
}
function barColor(pct){return pct>85?'linear-gradient(90deg,#dc2626,#ef4444)':pct>65?'linear-gradient(90deg,#d97706,#f97316)':''}

async function loadStats(){
  const btn=document.getElementById('refresh-btn');
  if(btn)btn.classList.add('spin');
  try{
    /* ── 1. x-ui server status ── */
    const ok=await xuiLogin();
    if(!ok){setBadge(false,'Login ไม่สำเร็จ');return;}

    const sv=await xuiGet('/panel/api/server/status').catch(()=>null);
    if(sv&&sv.success&&sv.obj){
      const o=sv.obj;
      /* CPU */
      const cpuPct=Math.round((o.cpu||0));
      document.getElementById('cpu-val').innerHTML=`${cpuPct}<span class="stat-unit">%</span>`;
      document.getElementById('cpu-cores').textContent=(o.cpuCores||o.logicalPro||'--')+' cores';
      setRing('cpu-ring',cpuPct,'#5a9e1c');
      setBar('cpu-bar',cpuPct);
      const cb=document.getElementById('cpu-bar');
      if(cb){const c=barColor(cpuPct);if(c)cb.style.background=c;}

      /* RAM */
      const ramTotalG=((o.mem&&o.mem.total)||0)/1073741824;
      const ramUsedG=((o.mem&&o.mem.current)||0)/1073741824;
      const ramPct=ramTotalG>0?Math.round(ramUsedG/ramTotalG*100):0;
      document.getElementById('ram-val').innerHTML=`${ramPct}<span class="stat-unit">%</span>`;
      document.getElementById('ram-detail').textContent=ramUsedG.toFixed(1)+' / '+ramTotalG.toFixed(1)+' GB';
      setRing('ram-ring',ramPct,'#1a6fa8');
      setBar('ram-bar',ramPct);
      const rb=document.getElementById('ram-bar');
      if(rb){const c=barColor(ramPct);if(c)rb.style.background=c;}

      /* Disk */
      const diskTotalG=((o.disk&&o.disk.total)||0)/1073741824;
      const diskUsedG=((o.disk&&o.disk.current)||0)/1073741824;
      const diskPct=diskTotalG>0?Math.round(diskUsedG/diskTotalG*100):0;
      document.getElementById('disk-val').innerHTML=`${diskPct}<span class="stat-unit">%</span>`;
      document.getElementById('disk-detail').textContent=diskUsedG.toFixed(0)+' / '+diskTotalG.toFixed(0)+' GB';
      setBar('disk-bar',diskPct);
      const db=document.getElementById('disk-bar');
      if(db){const c=barColor(diskPct);if(c)db.style.background=c;}

      /* Uptime */
      const up=o.uptime||0;
      const d=Math.floor(up/86400),h=Math.floor((up%86400)/3600),m=Math.floor((up%3600)/60);
      document.getElementById('uptime-val').textContent=d>0?`${d}d ${h}h`:`${h}h ${m}m`;
      document.getElementById('uptime-sub').textContent=`${d} วัน ${h} ชม. ${m} นาที`;
      /* Load avg */
      const loads=o.loads||[];
      const chips=loads.map((l,i)=>['1m','5m','15m'][i]?`<span class="chip">${['1m','5m','15m'][i]}: ${l.toFixed(2)}</span>`:'').join(' ');
      document.getElementById('load-avg-chips').innerHTML=chips;

      /* Network */
      const ns=o.netIO||o.netTraffic||null;
      if(ns){
        document.getElementById('net-up').textContent=fmtBytes((ns.up||0))+'/s';
        document.getElementById('net-down').textContent=fmtBytes((ns.down||0))+'/s';
      }
      const nt=o.netTraffic||null;
      if(nt){
        document.getElementById('net-up-total').textContent='total: '+fmtBytes(nt.sent||0);
        document.getElementById('net-down-total').textContent='total: '+fmtBytes(nt.recv||0);
      }

      /* x-ui version */
      setBadge(true,'ออนไลน์');
      document.getElementById('xui-ver').textContent='เวอร์ชัน: '+(o.xrayVersion||'--');
    }

    /* ── 2. Inbound count ── */
    const ibl=await xuiGet('/panel/api/inbounds/list').catch(()=>null);
    if(ibl&&ibl.success){
      const cnt=(ibl.obj||[]).length;
      document.getElementById('xui-traffic').textContent=`Inbounds: ${cnt} รายการ`;
    }

    document.getElementById('last-update').textContent='อัพเดทล่าสุด: '+new Date().toLocaleTimeString('th-TH');
  }catch(e){
    setBadge(false,'Error: '+e.message);
  }finally{
    if(btn)btn.classList.remove('spin');
  }
}

function setBadge(ok,text){
  const el=document.getElementById('xui-status-badge');
  if(!el)return;
  el.innerHTML=ok
    ?`<span class="online-badge"><span class="online-dot"></span>${text}</span>`
    :`<span class="status-badge status-dead">⚠ ${text}</span>`;
}

/* ══════════════════════════════════════
   USER LIST
══════════════════════════════════════ */
async function loadUserList(){
  if(!_xuiCookieSet)await xuiLogin();
  const list=document.getElementById('user-list');
  list.innerHTML='<div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--ssh)"></span>กำลังโหลด...</div>';
  try{
    if(!_xuiCookieSet)await xuiLogin();
    const d=await xuiGet('/panel/api/inbounds/list');
    if(!d.success)throw new Error('โหลดไม่สำเร็จ');
    _allUsers=[];
    (d.obj||[]).forEach(ib=>{
      const settings=typeof ib.settings==='string'?JSON.parse(ib.settings):ib.settings;
      const statsMap={};
      (ib.clientStats||[]).forEach(s=>{ statsMap[s.email]=s; });
      (settings.clients||[]).forEach(c=>{
        const cs=statsMap[c.email||c.id]||null;
        _allUsers.push({
          inboundId:ib.id, inboundPort:ib.port, protocol:ib.protocol,
          email:c.email||c.id, uuid:c.id, expiryTime:c.expiryTime||0,
          totalGB:c.totalGB?(c.totalGB/1073741824):0, limitIp:c.limitIp||0,
          enable:c.enable!==false,
          upBytes:(cs?cs.up:0),
          downBytes:(cs?cs.down:0),
          upMB:((cs?cs.up:0)/1073741824).toFixed(2),
          downMB:((cs?cs.down:0)/1073741824).toFixed(2),
          _raw:c, _inbound:ib
        });
      });
    });
    _filteredUsers=[..._allUsers];

    renderUserList(_filteredUsers);
  }catch(e){
    list.innerHTML=`<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }
}

function renderUserList(users){
  const list=document.getElementById('user-list');
  if(!users.length){list.innerHTML='<div class="empty-state"><div class="ei">🔍</div><div>ไม่พบยูสเซอร์</div></div>';return;}
  const now=Date.now();
  list.innerHTML=users.map(u=>{
    const isAis=u.inboundPort===8080;
    const avatarClass=isAis?'ua-ais':'ua-true';
    const initial=(u.email||'?')[0].toUpperCase();
    let statusHtml='', expStr='';
    if(u.expiryTime===0){expStr='ไม่จำกัด';statusHtml='<span class="status-badge status-ok">✓ Active</span>'}
    else{
      const diff=u.expiryTime-now;
      const days=Math.ceil(diff/86400000);
      if(diff<0){expStr='หมดอายุแล้ว';statusHtml='<span class="status-badge status-dead">✗ Expired</span>'}
      else if(days<=3){expStr=`เหลือ ${days} วัน`;statusHtml=`<span class="status-badge status-exp">⚠ ${days}d</span>`}
      else{expStr=`${days} วัน`;statusHtml='<span class="status-badge status-ok">✓ Active</span>'}
    }
    return `<button type="button" class="user-row" data-email="${u.email}" style="width:100%;text-align:left;border:none;background:none;cursor:pointer;">
      <div class="user-avatar ${avatarClass}">${initial}</div>
      <div class="user-info">
        <div class="user-name">${u.email}</div>
        <div class="user-meta">Port ${u.inboundPort} · ${expStr}</div>
      </div>
      ${statusHtml}
    </button>`;
  }).join('');
}

document.getElementById('user-list').addEventListener('click',function(e){
  const row=e.target.closest('.user-row');
  if(row){const em=row.getAttribute('data-email');if(em)openMgmtModal(em);}
});

function filterUsers(q){
  const s=q.toLowerCase();
  _filteredUsers=_allUsers.filter(u=>(u.email||'').toLowerCase().includes(s));
  renderUserList(_filteredUsers);
}

/* ══════════════════════════════════════
   ONLINE USERS
══════════════════════════════════════ */
async function loadOnlineUsers(){
  const btn=document.getElementById('online-refresh');
  if(btn)btn.classList.add('spin');
  const list=document.getElementById('online-list');
  list.innerHTML='<div class="loading-row"><span class="spinner" style="border-color:rgba(0,0,0,.1);border-top-color:var(--green)"></span>กำลังโหลด...</div>';
  try{
    if(!_xuiCookieSet)await xuiLogin();
    // x-ui v2 online clients endpoint
    const d=await xuiGet('/panel/api/inbounds/list').catch(()=>null);
    let onlines=[];
    if(d&&d.success){
      const now=Date.now();
      const ONLINE_MS=3*60*1000;
      (d.obj||[]).forEach(ib=>{
        (ib.clientStats||[]).forEach(c=>{
          if(c.enable && c.lastOnline && (now-c.lastOnline)<ONLINE_MS){
            onlines.push(c.email);
          }
        });
      });
    }
    document.getElementById('online-count').textContent=onlines.length;
    document.getElementById('online-time').textContent='อัพเดท: '+new Date().toLocaleTimeString('th-TH');
    if(!onlines.length){
      list.innerHTML='<div class="empty-state"><div class="ei">😴</div><div>ไม่มียูสออนไลน์ตอนนี้</div></div>';
      return;
    }
    // โหลด user list ก่อนถ้ายังไม่มี
    if(!_allUsers.length){
      try{ await loadUserList(); }catch(e){}
    }
    const now2=Date.now();
    list.innerHTML=onlines.map(email=>{
      const u=_allUsers.find(x=>x.email===email)||null;
      const portLabel=u?`Port ${u.inboundPort}`:'VLESS';
      // คำนวณ data
      let dataBar='', dataLabel='ไม่จำกัด', dataPct=0, dataColor='#22c55e';
      if(u&&u.totalGB>0){
        const usedBytes=(u.upBytes||0)+(u.downBytes||0);
        const totalBytes=u.totalGB*1073741824;
        dataPct=Math.min(Math.round(usedBytes/totalBytes*100),100);
        const usedGB=(usedBytes/1073741824).toFixed(2);
        dataLabel=`${usedGB} / ${u.totalGB} GB`;
        dataColor=dataPct>85?'#ef4444':dataPct>60?'#f97316':'#22c55e';
      }
      // วันหมดอายุ
      let expLabel='ไม่จำกัด', expClass='exp-ok';
      if(u&&u.expiryTime>0){
        const diff=u.expiryTime-now2;
        const daysLeft=Math.ceil(diff/86400000);
        expLabel=new Date(u.expiryTime).toLocaleDateString('th-TH');
        expClass=diff<0?'exp-dead':daysLeft<=3?'exp-warn':'exp-ok';
        if(diff<0) expLabel='หมดอายุแล้ว';
        else expLabel=`${daysLeft}d — ${expLabel}`;
      }
      const isAis=u&&u.inboundPort===8080;
      const avatarBg=isAis?'#edf7e3':'#fff0f0';
      const avatarBd=isAis?'#b5e08a':'#f5909a';
      const avatarColor=isAis?'#316808':'#a6000c';
      return `<div class="online-user-row">
        <div class="online-avatar" style="background:${avatarBg};border-color:${avatarBd};color:${avatarColor}">${(email||'?')[0].toUpperCase()}</div>
        <div class="online-info">
          <div class="online-name">
            <span>${email}</span>
            <span class="online-port-chip">${portLabel}</span>
          </div>
          <div class="online-data-row">
            <div class="online-data-bar-wrap">
              <div class="online-data-bar" style="width:${u&&u.totalGB>0?dataPct:100}%;background:${u&&u.totalGB>0?dataColor:'#22c55e'};${u&&u.totalGB>0?'':'opacity:.35'}"></div>
            </div>
            <span class="online-data-label">${dataLabel}</span>
          </div>
          <div class="online-exp ${expClass}">📅 ${expLabel}</div>
        </div>
        <span class="online-live-dot"></span>
      </button>`;
    }).join('');
  }catch(e){
    list.innerHTML=`<div class="empty-state"><div class="ei">⚠️</div><div>${e.message}</div></div>`;
  }finally{
    if(btn)btn.classList.remove('spin');
  }
}

/* ══════════════════════════════════════
   USER MANAGEMENT MODAL
══════════════════════════════════════ */
function openMgmtModal(email){
  xuiLogin();
  const u=_allUsers.find(x=>x.email===email);

  _mgmtUser=u; _mgmtAction=null;
  document.getElementById('mgmt-modal-title').textContent='⚙️ '+email;

  // render detail
  const now=Date.now();
  let expStr='ไม่จำกัด', expClass='ok';
  if(u.expiryTime>0){
    const diff=u.expiryTime-now;
    expStr=new Date(u.expiryTime).toLocaleDateString('th-TH');
    expClass=diff<0?'dead':diff<259200000?'exp':'ok';
  }
  const dataStr=u.totalGB>0?u.totalGB+' GB':'ไม่จำกัด';
  document.getElementById('mgmt-user-detail').innerHTML=`
    <div class="udetail-row"><span class="dk">👤 Username</span><span class="dv">${u.email}</span></div>
    <div class="udetail-row"><span class="dk">🔌 Port</span><span class="dv">${u.inboundPort}</span></div>
    <div class="udetail-row"><span class="dk">📅 หมดอายุ</span><span class="dv ${expClass}">${expStr}</span></div>
    <div class="udetail-row"><span class="dk">📦 Data</span><span class="dv">${dataStr}</span></div>
    <div class="udetail-row"><span class="dk">📱 IP Limit</span><span class="dv">${u.limitIp||'ไม่จำกัด'}</span></div>
    <div class="udetail-row"><span class="dk">📊 Traffic ↑↓</span><span class="dv">${u.upMB} / ${u.downMB} MB</span></div>
    <div class="udetail-row"><span class="dk">🆔 UUID</span><span class="dv" style="font-family:'Share Tech Mono',monospace;font-size:.65rem;color:var(--ssh)">${u.uuid}</span></div>
  `;

  // reset action form
  document.getElementById('action-form').style.display='none';
  ['renew','adddays','adddata','setdata','resettraffic','delete'].forEach(a=>{
    document.getElementById('form-'+a).style.display='none';
    document.getElementById('act-'+a).classList.remove('selected');
  });
  setAlert('mgmt','','');
  openModal('mgmt');
}

function selectAction(action){
  _mgmtAction=action;
  ['renew','adddays','adddata','setdata','resettraffic','delete'].forEach(a=>{
    document.getElementById('form-'+a).style.display='none';
    document.getElementById('act-'+a).classList.remove('selected');
  });
  document.getElementById('act-'+action).classList.add('selected');
  document.getElementById('form-'+action).style.display='';
  document.getElementById('action-form').style.display='';
  setAlert('mgmt','','');
}

async function doAction(action){
  if(!_mgmtUser)return;
  const u=_mgmtUser;
  
  try{
    await xuiLogin();
    const ibData=await xuiGet('/panel/api/inbounds/list');
    if(!ibData.success)throw new Error('โหลด inbound ไม่สำเร็จ');
    const ib=(ibData.obj||[]).find(x=>x.id===u.inboundId);
    if(!ib)throw new Error('ไม่พบ inbound');
    const settings=typeof ib.settings==='string'?JSON.parse(ib.settings):ib.settings;
    const clients=settings.clients||[];
    const clientIdx=clients.findIndex(c=>c.id===u.uuid||c.email===u.email);
    if(clientIdx<0)throw new Error('ไม่พบ client ใน inbound');
    const client={...clients[clientIdx]};
    const now=Date.now();

    if(action==='renew'){
      const days=parseInt(val('mgmt-renew-days'))||30;
      const data=parseInt(val('mgmt-renew-data'))||0;
      client.expiryTime=now+days*86400000;
      client.totalGB=data>0?data*1073741824:0;
      client.enable=true;
    } else if(action==='adddays'){
      const days=parseInt(val('mgmt-adddays-val'))||30;
      const base=client.expiryTime>0?client.expiryTime:now;
      client.expiryTime=base+days*86400000;
      client.enable=true;
    } else if(action==='adddata'){
      const addGB=parseInt(val('mgmt-adddata-val'))||10;
      const curBytes=client.totalGB||0;
      client.totalGB=curBytes+(addGB*1073741824);
    } else if(action==='setdata'){
      const gb=parseInt(val('mgmt-setdata-val'))||0;
      client.totalGB=gb>0?gb*1073741824:0;
    } else if(action==='resettraffic'){
      const res=await xuiPost(`/panel/api/inbounds/${u.inboundId}/resetClientTraffic/${u.email}`,{});
      if(!res.success)throw new Error(res.msg||'รีเซตไม่สำเร็จ');
      setAlert('mgmt','✅ รีเซต Traffic สำเร็จ','ok');
      await loadUserList();
      return;
    } else if(action==='delete'){
      const res=await xuiPost(`/panel/api/inbounds/${u.inboundId}/delClient/${u.uuid}`,{});
      if(!res.success)throw new Error(res.msg||'ลบไม่สำเร็จ');
      setAlert('mgmt','✅ ลบยูสสำเร็จ','ok');
      setTimeout(()=>{closeModal('mgmt');loadUserList();},1500);
      return;
    }

    // update client
    const payload={id:parseInt(u.inboundId), settings:JSON.stringify({clients:[client]}), up:0, down:0, total:0, remark:'', enable:true, expiryTime:0, listen:'', port:u.inboundPort, protocol:u.protocol, sniffing:'{}'};
    const res=await xuiPost(`/panel/api/inbounds/updateClient/${u.uuid}`,payload);
    if(!res.success)throw new Error(res.msg||'อัพเดทไม่สำเร็จ');

    toast('✅ ดำเนินการสำเร็จ!',true);
    setTimeout(()=>{ loadUserList(); },1000);


  }catch(e){
    setAlert('mgmt','❌ '+e.message,'err');
  }
}

/* ══════════════════════════════════════
   VLESS CREATION
══════════════════════════════════════ */
const VLESS_CFG={
  ais:{port:8080,sniField:'ais-sni',defaultSNI:'cj-ebb.speedtest.net'},
  true:{port:8880,sniField:'true-sni',defaultSNI:'true-internet.zoom.xyz.services'}
};

async function createVless(carrier){
  const c=VLESS_CFG[carrier];
  const user=val(carrier+'-user');
  const days=parseInt(val(carrier+'-days'))||30;
  const dataGB=parseInt(val(carrier+'-data'))||0;
  const ipLimit=parseInt(val(carrier+'-iplimit'))||2;
  const email=val(carrier+'-email')||user;
  const sni=val(carrier+'-sni')||c.defaultSNI;
  if(!user)return setAlert(carrier,'❌ กรุณาใส่ Username','err');

  setLoading(carrier,true); setAlert(carrier,'','');
  try{
    const loginOk=await xuiLogin();
    if(!loginOk)throw new Error('Login x-ui ไม่สำเร็จ');
    const uuid=genUUID();
    const expMs=Date.now()+days*86400000;
    const totalBytes=dataGB>0?dataGB*1073741824:0;
    const inboundId=await getInboundId(c.port);
    let result;
    if(inboundId!==null){
      result=await xuiPost('/panel/api/inbounds/addClient',{id:inboundId,settings:JSON.stringify({clients:[{id:uuid,flow:'',email:email,limitIp:ipLimit,totalGB:totalBytes,expiryTime:expMs,enable:true,tgId:'',subId:'',comment:'',reset:0}]})});
    }else{
      result=await xuiPost('/panel/api/inbounds/add',{remark:`CHAIYA-${carrier.toUpperCase()}-${c.port}`,enable:true,listen:'',port:c.port,protocol:'vless',settings:JSON.stringify({clients:[{id:uuid,flow:'',email:email,limitIp:ipLimit,totalGB:totalBytes,expiryTime:expMs,enable:true,tgId:'',subId:'',comment:'',reset:0}],decryption:'none'}),streamSettings:JSON.stringify({network:'ws',security:'none',wsSettings:{path:'/vless',headers:{Host:sni}}}),sniffing:JSON.stringify({enabled:true,destOverride:['http','tls']}),tag:`inbound-${c.port}`});
    }
    if(!result.success)throw new Error(result.msg||'สร้างไม่สำเร็จ');
    const vlessLink=buildVlessLink(uuid,HOST,c.port,sni,email);
    const saved={user,email,uuid,days,expMs,dataGB,ipLimit,sni,port:c.port,vlessLink};
    if(carrier==='ais')_aisSaved=saved; else _trueSaved=saved;
    showVlessResult(carrier,saved);
    setAlert(carrier,`✅ สร้าง ${carrier.toUpperCase()} user "${user}" สำเร็จ!`,'ok');
  }catch(e){setAlert(carrier,'❌ '+e.message,'err');
  }finally{setLoading(carrier,false)}
}

function showVlessResult(carrier,d){
  const expDate=new Date(d.expMs).toLocaleDateString('th-TH');
  const dataStr=d.dataGB>0?d.dataGB+' GB':'ไม่จำกัด';
  document.getElementById(carrier+'-info').innerHTML=`
    <div class="info-row"><span class="info-key">👤 Username</span><span class="info-val">${d.user}</span></div>
    <div class="info-row"><span class="info-key">📅 หมดอายุ</span><span class="info-val">${expDate}</span></div>
    <div class="info-row"><span class="info-key">📦 Data</span><span class="info-val">${dataStr}</span></div>
    <div class="info-row"><span class="info-key">📱 IP Limit</span><span class="info-val">${d.ipLimit} IP</span></div>
    <div class="info-row"><span class="info-key">🔌 Port</span><span class="info-val">${d.port}</span></div>
    <div class="info-row"><span class="info-key">🌐 SNI</span><span class="info-val">${d.sni}</span></div>
    <div class="info-row"><span class="info-key">🆔 UUID</span><span class="info-val uuid">${d.uuid}</span></div>`;
  document.getElementById(carrier+'-vless-link').textContent=d.vlessLink;
  renderQR(carrier+'-qr',d.vlessLink);
  document.getElementById(carrier+'-result').classList.add('show');
  setTimeout(()=>document.getElementById(carrier+'-result').scrollIntoView({behavior:'smooth',block:'nearest'}),100);
}
function copyNpvDirect(carrier){
  const saved=carrier==='ais'?_aisSaved:_trueSaved;
  if(!saved)return toast('❌ สร้าง account ก่อน',false);
  copyToClipboard(buildNpvLink(saved.user,saved.pass,PROS.dtac,80),carrier+'-copy-npv');
}

/* ══════════════════════════════════════
   SSH SELECTORS
══════════════════════════════════════ */
function sshSelPort(port){
  _sshPort=port;
  ['80','443'].forEach(p=>{document.getElementById('ssh-tab-'+p).className='port-tab'+(String(port)===p?' active-ssh':'')});
  document.getElementById('ssh-sni-field').style.display=port===443?'':'none';
}
function sshSelApp(app){
  _sshApp=app;
  ['npv','dark'].forEach(a=>{document.getElementById('ssh-app-'+a).className='port-tab'+(app===a?' active-ssh':'')});
  const lb=document.getElementById('ssh-import-link');
  if(lb)lb.className='link-box '+(app==='npv'?'npv-link':'dark-link');
}
function sshSelPro(pro){
  _sshPro=pro;
  ['dtac','true'].forEach(p=>{document.getElementById('ssh-pro-'+p).className='port-tab pro-tab'+(pro===p?' active-ssh':'')});
}

/* ══════════════════════════════════════
   SSH CREATION
══════════════════════════════════════ */
async function createSSH(){
  const user=val('ssh-user'), pass=val('ssh-pass');
  const days=parseInt(val('ssh-days'))||30;
  const ipLimit=parseInt(val('ssh-iplimit'))||2;
  if(!user)return setAlert('ssh','❌ กรุณาใส่ Username','err');
  if(!pass)return setAlert('ssh','❌ กรุณาใส่ Password','err');
  setLoading('ssh',true); setAlert('ssh','','');
  try{
    const r=await fetch(SSH_API+'/create',{method:'POST',headers:{'Content-Type':'application/json','X-Token':TOK,'Authorization':'Bearer '+TOK},body:JSON.stringify({user,pass,exp_days:days,ip_limit:ipLimit,port:String(_sshPort)})});
    const d=await r.json();
    if(!d.ok&&!d.success)throw new Error(d.error||d.msg||'สร้างไม่สำเร็จ');
    const pro=PROS[_sshPro];
    const link=_sshApp==='npv'?buildNpvLink(user,pass,pro,_sshPort):buildDarkLink(user,pass,pro,_sshPort);
    const expDate=new Date(Date.now()+days*86400000).toLocaleDateString('th-TH');
    _sshSaved={user,pass,days,ipLimit,port:_sshPort,expDate,link};
    showSSHResult(_sshSaved);
    setAlert('ssh',`✅ สร้าง SSH user "${user}" สำเร็จ!`,'ok');
  }catch(e){setAlert('ssh','❌ '+e.message,'err');
  }finally{setLoading('ssh',false)}
}
function showSSHResult(d){
  const isNpv=_sshApp==='npv';
  document.getElementById('ssh-info').innerHTML=`
    <div class="info-row"><span class="info-key">👤 Username</span><span class="info-val">${d.user}</span></div>
    <div class="info-row"><span class="info-key">🔑 Password</span><span class="info-val pass">${d.pass}</span></div>
    <div class="info-row"><span class="info-key">🌐 Host</span><span class="info-val">${HOST}</span></div>
    <div class="info-row"><span class="info-key">🔌 WS Port</span><span class="info-val">${d.port}</span></div>
    <div class="info-row"><span class="info-key">🐻 Dropbear</span><span class="info-val">143, 109</span></div>
    <div class="info-row"><span class="info-key">📅 หมดอายุ</span><span class="info-val">${d.expDate}</span></div>
    <div class="info-row"><span class="info-key">📱 IP Limit</span><span class="info-val">${d.ipLimit} IP</span></div>
    <div class="info-row"><span class="info-key">📲 App</span><span class="info-val">${isNpv?'NpvTunnel':'DarkTunnel'}</span></div>`;
  const lb=document.getElementById('ssh-import-link');
  lb.textContent=d.link; lb.className='link-box '+(isNpv?'npv-link':'dark-link');
  document.getElementById('ssh-result').classList.add('show');
  setTimeout(()=>document.getElementById('ssh-result').scrollIntoView({behavior:'smooth',block:'nearest'}),100);
}
function copySSHInfo(){
  if(!_sshSaved)return toast('❌ สร้าง account ก่อน',false);
  const d=_sshSaved;
  const text=`Host/IP   : ${HOST}\nPort (WS) : ${d.port}\nDropbear  : 143, 109\nUsername  : ${d.user}\nPassword  : ${d.pass}\nExpire    : ${d.expDate}\nIP Limit  : ${d.ipLimit}\nUDP GW    : 127.0.0.1:7300\nPath (80) : /\nPath (443): /ssh/`;
  copyToClipboard(text,'ssh-copy-info');
}

/* ══════════════════════════════════════
   LINK BUILDERS
══════════════════════════════════════ */
function buildVlessLink(uuid,host,port,sni,email){
  return `vless://${uuid}@${host}:${port}?path=${encodeURIComponent('/vless')}&security=none&encryption=none&host=${encodeURIComponent(sni)}&type=ws#CHAIYA-${email}-${port}`;
}
function buildNpvLink(name,pass,pro,port){
  const j={sshConfigType:'SSH-Proxy-Payload',remarks:pro.name+'-'+name,sshHost:HOST,sshPort:port,sshUsername:name,sshPassword:pass,sni:'',tlsVersion:'DEFAULT',httpProxy:pro.proxy,authenticateProxy:false,proxyUsername:'',proxyPassword:'',payload:pro.payload,dnsTTMode:'UDP',dnsServer:'',nameserver:'',publicKey:'',udpgwPort:7300,udpgwTransparentDNS:true};
  return 'npvt-ssh://'+btoa(unescape(encodeURIComponent(JSON.stringify(j))));
}
function buildDarkLink(name,pass,pro,port){
  const j={type:'SSH',name:pro.name+'-'+name,sshTunnelConfig:{sshConfig:{host:HOST,port:port,username:name,password:pass},injectConfig:{mode:'PROXY',proxyHost:pro.darkProxy||'',proxyPort:pro.darkProxyPort||80,payload:pro.payload||''}}};
  return 'darktunnel://'+btoa(unescape(encodeURIComponent(JSON.stringify(j))));
}

/* QR */
function renderQR(elId,text){
  const el=document.getElementById(elId); el.innerHTML='';
  try{new QRCode(el,{text,width:176,height:176,colorDark:'#000',colorLight:'#fff',correctLevel:QRCode.CorrectLevel.M})}
  catch(e){el.textContent='QR Error'}
}

/* ══════════════════════════════════════
   AUTO LOAD on start
══════════════════════════════════════ */

/* ══════════════════════════════════════
   SERVICE MONITOR
══════════════════════════════════════ */
const SERVICES=[
  {name:'x-ui Panel',     icon:'📡', ports:[54321], type:'xui'},
  {name:'Python SSH API', icon:'🐍', ports:[6789],  path:SSH_API+'/api/status', type:'http'},
  {name:'Dropbear SSH',   icon:'🐻', ports:[143,109], type:'api', key:'dropbear'},
  {name:'nginx / WS',     icon:'🌐', ports:[80],    path:'/', type:'http'},
  {name:'badvpn UDP-GW',  icon:'🎮', ports:[7300],  type:'api', key:'badvpn'},
];

async function loadServiceStatus(){
  const btn=document.getElementById('svc-refresh-btn');
  if(btn)btn.classList.add('spin');
  const listEl=document.getElementById('svc-list');
  // แสดง placeholder ขณะโหลด
  listEl.innerHTML='<div class="svc-grid">'+SERVICES.map(s=>`
    <div class="svc-row">
      <span class="svc-dot" style="background:#d1d5db"></span>
      <span class="svc-icon">${s.icon}</span>
      <span class="svc-name">${s.name}</span>
      <span class="svc-ports">${s.ports.map(p=>':'+p).join(' ')}</span>
      <span class="svc-chip checking">...</span>
    </div>`).join('')+'</div>';

  const results=await Promise.all(SERVICES.map(s=>checkService(s)));
  listEl.innerHTML='<div class="svc-grid">'+results.map(r=>`
    <div class="svc-row ${r.state}">
      <span class="svc-dot ${r.state}"></span>
      <span class="svc-icon">${r.icon}</span>
      <span class="svc-name">${r.name}</span>
      <span class="svc-ports">${r.portStr}</span>
      <span class="svc-chip ${r.state}">${r.state==='up'?'RUNNING':r.state==='warn'?'WARN':'DOWN'}</span>
    </div>`).join('')+'</div>';

  if(btn)btn.classList.remove('spin');
}

async function checkService(s){
  const base={name:s.name,icon:s.icon,portStr:s.ports.map(p=>':'+p).join(' '),state:'down'};
  try{
    if(s.type==='xui'){
      const ok=_xuiCookieSet||(await xuiLogin());
      return {...base,state:ok?'up':'down'};
    }
    if(s.type==='http'&&s.path){
      const r=await Promise.race([
        fetch(s.path,{credentials:'include'}),
        new Promise((_,rej)=>setTimeout(()=>rej(),3500))
      ]);
      return {...base,state:r.ok||r.status<500?'up':'warn'};
    }
    // port: ใช้ no-cors fetch — ถ้าไม่ timeout แสดงว่า port เปิดอยู่
    if(s.type==='api'){
      try{
        const r=await fetch('/api/status');
        const d=await r.json();
        const up=d.services&&d.services[s.key];
        return {...base,state:up?'up':'down'};
      }catch{return base;}
    }
    if(s.type==='port'){
      const checks=await Promise.all(s.ports.map(async p=>{
        try{
          await Promise.race([
            fetch(`http://${HOST}:${p}/`,{method:'HEAD',mode:'no-cors'}),
            new Promise((_,rej)=>setTimeout(()=>rej(),2800))
          ]);
          return true;
        }catch{return false;}
      }));
      const up=checks.filter(Boolean).length;
      return {...base,state:up===s.ports.length?'up':up>0?'warn':'down'};
    }
  }catch(e){}
  return base;
}


/* ══════════════════════════════════════
   SNOWFLAKE CANVAS — เกล็ดแปดแฉก
══════════════════════════════════════ */
(function(){
  const canvas=document.getElementById('snow-canvas');
  if(!canvas)return;
  const ctx=canvas.getContext('2d');

  function resize(){
    canvas.width=canvas.offsetWidth;
    canvas.height=canvas.offsetHeight;
  }
  resize();
  window.addEventListener('resize',resize);

  const COLORS=['rgba(180,230,255,','rgba(200,255,220,','rgba(220,200,255,','rgba(255,200,240,'];
  const flakes=[];
  const COUNT=28;

  function randomFlake(){
    return{
      x:Math.random()*canvas.width,
      y:Math.random()*canvas.height-canvas.height,
      size:Math.random()*7+4,
      speed:Math.random()*.5+.25,
      drift:Math.random()*.4-.2,
      rot:Math.random()*Math.PI,
      rotSpeed:(Math.random()-.5)*.02,
      color:COLORS[Math.floor(Math.random()*COLORS.length)],
      opacity:Math.random()*.5+.3,
    };
  }
  for(let i=0;i<COUNT;i++){
    const f=randomFlake();
    f.y=Math.random()*canvas.height; // กระจายแรก
    flakes.push(f);
  }

  // วาดเกล็ด 8 แฉก
  function drawFlake(f){
    ctx.save();
    ctx.translate(f.x,f.y);
    ctx.rotate(f.rot);
    ctx.strokeStyle=f.color+f.opacity+')';
    ctx.lineWidth=1.2;
    ctx.lineCap='round';
    const s=f.size;
    // 4 เส้นหลัก (8 แฉก)
    for(let i=0;i<4;i++){
      ctx.save();
      ctx.rotate(i*Math.PI/4);
      ctx.beginPath();ctx.moveTo(0,-s);ctx.lineTo(0,s);ctx.stroke();
      // กิ่งก้าน
      const b=s*.45;
      ctx.beginPath();ctx.moveTo(-b,-s*.5);ctx.lineTo(0,-s*.5+b*.4);ctx.lineTo(b,-s*.5);ctx.stroke();
      ctx.restore();
    }
    // จุดกลาง
    ctx.beginPath();ctx.arc(0,0,1.4,0,Math.PI*2);
    ctx.fillStyle=f.color+Math.min(f.opacity+.2,1)+')';
    ctx.fill();
    ctx.restore();
  }

  function tick(){
    ctx.clearRect(0,0,canvas.width,canvas.height);
    flakes.forEach(f=>{
      f.y+=f.speed;
      f.x+=f.drift;
      f.rot+=f.rotSpeed;
      if(f.y>canvas.height+20){
        Object.assign(f,randomFlake());
        f.y=-10;
      }
      drawFlake(f);
    });
    requestAnimationFrame(tick);
  }
  tick();
})();

function doLogout(){
  sessionStorage.removeItem('chaiya_auth');
  window.location.replace('index.html');
}

window.addEventListener('load',()=>{
  loadStats();
  loadServiceStatus();
  // auto-refresh stats every 30s
  setInterval(()=>{
    if(document.getElementById('tab-dash').classList.contains('active')){loadStats();loadServiceStatus();}
  },30000);
});
</script>
</body>
</html>

HTMLEOF

systemctl restart chaiya-ssh-api nginx
echo "Update done"
