#!/bin/bash
# ============================================================
#  CHAIYA SSH WEB — แผงจัดการ SSH แยกอิสระ (ไม่พึ่ง 3x-ui)
#  Dropbear 143/109 + WS :80 + BadVPN 7300 + เว็บแผง https :443
#  ใช้: [DOMAIN=sub.example.com] [ADMIN_USER=admin] [ADMIN_PASS=xxx] bash chaiya-ssh-web.sh
#  ผูก Cloudflare อัตโนมัติ (ถ้ามี): CF_TOKEN= CF_ROOT=example.com CF_SUB=ssh1
# ============================================================
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
[[ $EUID -eq 0 ]] || { echo "[ERR] ต้องรันด้วย root"; exit 1; }
ok(){ echo -e "\033[0;32m[OK]\033[0m $1"; }
info(){ echo -e "\033[0;36m[INFO]\033[0m $1"; }

APP=/opt/chaiya-ssh-web; CONF=/etc/chaiya-ssh
KEEP_ADMIN=0; [[ -f /etc/chaiya-ssh/admin.json && -z "$ADMIN_PASS" ]] && KEEP_ADMIN=1
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)}"
IP=$(curl -s4 --max-time 10 ifconfig.me)

# ── BACKUP อัตโนมัติ ─────────────────────────────────────────
if [[ -d $APP || -d $CONF ]]; then
  tar czf /root/chaiya-ssh-web-backup-$(date +%Y%m%d-%H%M%S).tgz $APP $CONF 2>/dev/null && ok "backup แล้วที่ /root"
fi

# ── CLOUDFLARE SUBDOMAIN (ถ้าตั้งค่า) ────────────────────────
if [[ -n "$CF_TOKEN" && -n "$CF_ROOT" && -n "$CF_SUB" ]]; then
  ZONE=$(curl -s -H "Authorization: Bearer $CF_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=$CF_ROOT" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'][0]['id'])")
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
    -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$CF_SUB.$CF_ROOT\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":false}" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print('[CF] OK' if d['success'] else d['errors'])"
  DOMAIN="$CF_SUB.$CF_ROOT"; sleep 5
fi

# ── PACKAGES ─────────────────────────────────────────────────
info "ติดตั้งแพ็กเกจ..."
apt-get update -qq
apt-get install -y -qq nginx dropbear openssl curl python3 certbot badvpn >/dev/null 2>&1 \
  || apt-get install -y -qq nginx dropbear openssl curl python3 certbot >/dev/null 2>&1
mkdir -p $APP/www $CONF
grep -q '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells
echo "${DOMAIN:-$IP}" > $CONF/host; echo "$IP" > $CONF/ip
[[ -f $CONF/users.json ]] || echo '{}' > $CONF/users.json

# ── DROPBEAR ─────────────────────────────────────────────────
DB=$(command -v dropbear)
systemctl stop dropbear 2>/dev/null
cat > /etc/systemd/system/dropbear.service << EOF
[Unit]
Description=Dropbear SSH
After=network.target
[Service]
ExecStart=$DB -F -R -p 143 -p 109
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# ── BADVPN ───────────────────────────────────────────────────
BV=$(command -v badvpn-udpgw)
if [[ -n "$BV" ]]; then
cat > /etc/systemd/system/chaiya-badvpn.service << EOF
[Unit]
Description=BadVPN UDPGW
After=network.target
[Service]
ExecStart=$BV --listen-addr 127.0.0.1:7300 --max-clients 500
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
fi

# ── WS (port 80 -> Dropbear 143) ─────────────────────────────
cat > /usr/local/bin/chaiya-ws << 'WSPY'
#!/usr/bin/python3
import asyncio
T = ('127.0.0.1', 143)
async def pipe(r, w):
    try:
        while True:
            d = await r.read(65536)
            if not d: break
            w.write(d); await w.drain()
    except Exception: pass
    finally:
        try: w.close()
        except Exception: pass
async def h(r, w):
    try:
        await asyncio.wait_for(r.read(8192), 15)
        w.write(b'HTTP/1.1 101 Switching Protocols\r\nContent-Length: 104857600000\r\n\r\n')
        await w.drain()
        tr, tw = await asyncio.open_connection(*T)
    except Exception:
        w.close(); return
    await asyncio.gather(pipe(r, tw), pipe(tr, w))
async def main():
    s = await asyncio.start_server(h, '0.0.0.0', 80)
    await s.serve_forever()
asyncio.run(main())
WSPY
chmod +x /usr/local/bin/chaiya-ws
cat > /etc/systemd/system/chaiya-ws.service << 'EOF'
[Unit]
Description=Chaiya WS 80 -> Dropbear 143
After=network.target dropbear.service
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/chaiya-ws
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

# ── ADMIN (เก็บเป็น hash) ────────────────────────────────────
if [[ $KEEP_ADMIN -eq 0 ]]; then
ADMIN_USER="$ADMIN_USER" ADMIN_PASS="$ADMIN_PASS" python3 - << 'PY'
import os, json, hashlib, secrets
s = secrets.token_bytes(16)
h = hashlib.pbkdf2_hmac('sha256', os.environ['ADMIN_PASS'].encode(), s, 200000).hex()
json.dump({'user': os.environ['ADMIN_USER'], 'salt': s.hex(), 'hash': h}, open('/etc/chaiya-ssh/admin.json', 'w'))
PY
chmod 600 $CONF/admin.json
fi

# ── API (127.0.0.1:6790) ─────────────────────────────────────
cat > $APP/app.py << 'PYAPP'
#!/usr/bin/python3
import json, os, re, subprocess, secrets, hashlib, hmac, time, threading, datetime, pwd, shutil
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

D = '/etc/chaiya-ssh'; DBF = D + '/users.json'; ADM = D + '/admin.json'
LOCK = threading.Lock(); TOK = {}; FAIL = {}
NAME = re.compile(r'^[a-z_][a-z0-9_-]{2,30}$')

def load():
    try: return json.load(open(DBF))
    except Exception: return {}
def save(d):
    json.dump(d, open(DBF + '.tmp', 'w')); os.replace(DBF + '.tmp', DBF)
def sh(*a, inp=None):
    return subprocess.run(a, input=inp, capture_output=True, text=True, timeout=15).returncode == 0
def expired(e):
    return datetime.date.fromisoformat(e) < datetime.date.today()

def sessions():
    s = {}
    try:
        r = subprocess.run(['journalctl', '-u', 'dropbear', '--no-pager', '-o', 'short', '-n', '5000'],
                           capture_output=True, text=True, timeout=15).stdout
        for m in re.finditer(r"dropbear\[(\d+)\]: Password auth succeeded for '([^']+)'", r):
            pid = int(m.group(1))
            try:
                if open('/proc/%d/comm' % pid).read().strip() == 'dropbear':
                    s.setdefault(m.group(2), []).append(pid)
            except Exception: pass
        r = subprocess.run(['ps', '-eo', 'pid,user:32,comm', '--no-headers'],
                           capture_output=True, text=True, timeout=10).stdout
        for l in r.splitlines():
            p = l.split()
            if len(p) == 3 and p[2] == 'sshd' and p[1] != 'root':
                s.setdefault(p[1], []).append(int(p[0]))
    except Exception: pass
    return s

def cpu():
    def r():
        v = list(map(int, open('/proc/stat').readline().split()[1:])); return sum(v), v[3] + v[4]
    a, b = r(); time.sleep(.3); c, d = r()
    return round(100 * (1 - (d - b) / max(c - a, 1)), 1)

def status():
    m = {l.split(':')[0]: int(l.split()[1]) for l in open('/proc/meminfo')}
    du = shutil.disk_usage('/')
    return {'cpu': cpu(), 'ram': round(100 * (1 - m['MemAvailable'] / m['MemTotal']), 1),
            'disk': round(100 * du.used / du.total, 1), 'load': round(os.getloadavg()[0], 2),
            'up': int(float(open('/proc/uptime').read().split()[0]) // 3600),
            'host': open(D + '/host').read().strip()}

def reaper():
    while True:
        time.sleep(300)
        try:
            with LOCK:
                ss = sessions()
                for u, v in load().items():
                    if expired(v['exp']):
                        sh('usermod', '-L', u)
                        for pid in ss.get(u, []):
                            try: os.kill(pid, 9)
                            except Exception: pass
        except Exception: pass

import urllib.request, urllib.error, ipaddress
CFF = D + '/cf.json'
SUB = re.compile(r'^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$')
ROOT = re.compile(r'^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$')
def cfconf():
    try: return json.load(open(CFF))
    except Exception: return None
def cf(method, path, body=None, token=None):
    req = urllib.request.Request('https://api.cloudflare.com/client/v4' + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': 'Bearer ' + (token or cfconf()['token']), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as r: return json.load(r)
    except urllib.error.HTTPError as e:
        try: return json.load(e)
        except Exception: return {'success': False, 'errors': [{'message': 'HTTP %d' % e.code}]}
    except Exception as e:
        return {'success': False, 'errors': [{'message': str(e)}]}
def cferr(r): return (r.get('errors') or [{}])[0].get('message', 'error')
def zid(tk, root):
    try: return cf('GET', '/zones?name=' + root, token=tk)['result'][0]['id']
    except Exception: return None
def myip():
    try: return open(D + '/ip').read().strip()
    except Exception: return ''

class H(BaseHTTPRequestHandler):
    def log_message(s, *a): pass
    def out(s, c, d):
        b = json.dumps(d).encode()
        s.send_response(c); s.send_header('Content-Type', 'application/json')
        s.send_header('Content-Length', str(len(b))); s.end_headers(); s.wfile.write(b)
    def authed(s):
        e = TOK.get(s.headers.get('X-Token', ''))
        return bool(e and e > time.time())
    def body(s):
        try: return json.loads(s.rfile.read(min(int(s.headers.get('Content-Length', 0)), 4096)) or b'{}')
        except Exception: return {}

    def do_GET(s):
        if not s.authed(): return s.out(401, {'error': 'unauthorized'})
        if s.path == '/api/status': return s.out(200, status())
        if s.path == '/api/cf':
            c = cfconf()
            if not c: return s.out(200, {'configured': False})
            z = zid(c['token'], c['root'])
            if not z: return s.out(200, {'configured': True, 'root': c['root'], 'records': [], 'ip': myip(), 'error': 'เข้าถึงโซนไม่ได้ (token หมดอายุหรือสิทธิ์ไม่พอ)'})
            r = cf('GET', '/zones/%s/dns_records?type=A&per_page=100' % z)
            recs = [{'id': x['id'], 'name': x['name'], 'ip': x['content'], 'proxied': x['proxied']} for x in r.get('result') or []]
            return s.out(200, {'configured': True, 'root': c['root'], 'records': recs, 'ip': myip()})
        if s.path == '/api/users':
            ss = sessions(); res = []
            for u, v in sorted(load().items()):
                left = (datetime.date.fromisoformat(v['exp']) - datetime.date.today()).days
                res.append({'user': u, 'exp': v['exp'], 'left': left, 'active': left >= 0, 'online': len(ss.get(u, []))})
            return s.out(200, {'users': res})
        s.out(404, {'error': 'not found'})

    def do_POST(s):
        d = s.body()
        if s.path == '/api/login':
            ip = s.headers.get('X-Real-IP', s.client_address[0])
            n, until = FAIL.get(ip, (0, 0))
            if n >= 5 and until > time.time(): return s.out(429, {'error': 'ลองใหม่ใน 5 นาที'})
            a = json.load(open(ADM))
            h = hashlib.pbkdf2_hmac('sha256', str(d.get('password', '')).encode(), bytes.fromhex(a['salt']), 200000).hex()
            if hmac.compare_digest(str(d.get('username', '')).encode(), a['user'].encode()) and hmac.compare_digest(h.encode(), a['hash'].encode()):
                FAIL.pop(ip, None); t = secrets.token_hex(24); TOK[t] = time.time() + 43200
                return s.out(200, {'token': t})
            FAIL[ip] = (n + 1, time.time() + 300)
            return s.out(401, {'error': 'ชื่อหรือรหัสผ่านไม่ถูกต้อง'})
        if not s.authed(): return s.out(401, {'error': 'unauthorized'})
        if s.path == '/api/cf_save':
            root = str(d.get('root', '')).strip().lower(); tk = str(d.get('token', '')).strip()
            if not ROOT.match(root) or len(tk) < 20 or re.search(r'\s', tk): return s.out(400, {'error': 'โดเมนหรือ token ไม่ถูกต้อง'})
            if not zid(tk, root): return s.out(400, {'error': 'ใช้ token นี้กับโดเมนนี้ไม่ได้ (เช็กสิทธิ์ Zone:DNS:Edit)'})
            fd = os.open(CFF, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as f: json.dump({'token': tk, 'root': root}, f)
            return s.out(200, {'ok': True})
        if s.path in ('/api/cf_add', '/api/cf_del', '/api/cf_clear'):
            c = cfconf()
            if not c: return s.out(400, {'error': 'ยังไม่ได้ตั้งค่า Cloudflare'})
            if s.path == '/api/cf_clear':
                try: os.remove(CFF)
                except Exception: pass
                return s.out(200, {'ok': True})
            z = zid(c['token'], c['root'])
            if not z: return s.out(400, {'error': 'เข้าถึงโซนไม่ได้'})
            if s.path == '/api/cf_add':
                sub = str(d.get('sub', '')).strip().lower(); ip = str(d.get('ip', '')).strip() or myip()
                try: ipaddress.IPv4Address(ip)
                except Exception: return s.out(400, {'error': 'IP ไม่ถูกต้อง'})
                if not SUB.match(sub): return s.out(400, {'error': 'ชื่อซับโดเมนไม่ถูกต้อง (a-z 0-9 -)'})
                r = cf('POST', '/zones/%s/dns_records' % z, {'type': 'A', 'name': sub + '.' + c['root'], 'content': ip, 'ttl': 1, 'proxied': bool(d.get('proxied', False))})
                if not r.get('success'): return s.out(400, {'error': cferr(r)})
                return s.out(200, {'ok': True, 'name': sub + '.' + c['root']})
            rid = str(d.get('id', ''))
            if not re.match(r'^[0-9a-f]{32}$', rid): return s.out(400, {'error': 'id ไม่ถูกต้อง'})
            r = cf('DELETE', '/zones/%s/dns_records/%s' % (z, rid))
            return s.out(200, {'ok': True}) if r.get('success') else s.out(400, {'error': cferr(r)})
        u = str(d.get('user', '')).strip()
        with LOCK:
            db = load()
            if s.path == '/api/create':
                p = str(d.get('password', '')); days = int(d.get('days', 30))
                if not NAME.match(u) or not 4 <= len(p) <= 64 or re.search(r'[:\s]', p) or not 1 <= days <= 3650:
                    return s.out(400, {'error': 'ข้อมูลไม่ถูกต้อง (ชื่อ a-z0-9_- 3-31 ตัว / รหัส 4-64 ตัว ห้ามเว้นวรรค)'})
                try: pwd.getpwnam(u); return s.out(409, {'error': 'ชื่อนี้มีอยู่แล้ว'})
                except KeyError: pass
                if not (sh('useradd', '-M', '-s', '/bin/false', u) and sh('chpasswd', inp='%s:%s\n' % (u, p))):
                    return s.out(500, {'error': 'สร้างผู้ใช้ไม่สำเร็จ'})
                exp = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
                sh('chage', '-E', exp, u); db[u] = {'exp': exp}; save(db)
                return s.out(200, {'ok': True, 'user': u, 'exp': exp})
            if u not in db: return s.out(404, {'error': 'ไม่พบผู้ใช้ในแผง'})
            if s.path == '/api/delete':
                for pid in sessions().get(u, []):
                    try: os.kill(pid, 9)
                    except Exception: pass
                sh('userdel', '-f', u); db.pop(u); save(db); return s.out(200, {'ok': True})
            if s.path == '/api/extend':
                days = int(d.get('days', 30))
                if not 1 <= days <= 3650: return s.out(400, {'error': 'จำนวนวันไม่ถูกต้อง'})
                old = datetime.date.fromisoformat(db[u]['exp'])
                exp = (max(old, datetime.date.today()) + datetime.timedelta(days=days)).isoformat()
                sh('chage', '-E', exp, u); sh('usermod', '-U', u); db[u]['exp'] = exp; save(db)
                return s.out(200, {'ok': True, 'exp': exp})
            if s.path == '/api/passwd':
                p = str(d.get('password', ''))
                if not 4 <= len(p) <= 64 or re.search(r'[:\s]', p): return s.out(400, {'error': 'รหัสผ่านไม่ถูกต้อง'})
                sh('chpasswd', inp='%s:%s\n' % (u, p)); return s.out(200, {'ok': True})
        s.out(404, {'error': 'not found'})

threading.Thread(target=reaper, daemon=True).start()
ThreadingHTTPServer(('127.0.0.1', 6790), H).serve_forever()
PYAPP

cat > /etc/systemd/system/chaiya-ssh-web.service << EOF
[Unit]
Description=Chaiya SSH Web API
After=network.target
[Service]
ExecStart=/usr/bin/python3 $APP/app.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# ── หน้าเว็บ ─────────────────────────────────────────────────
cat > $APP/www/index.html << 'HTML'
<!DOCTYPE html>
<html lang="th"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Chaiya SSH</title>
<style>
:root{--bg:#0f1220;--cd:#181c30;--tx:#e8ebf7;--mu:#8a91b4;--ac:#5b8cff;--ok:#2ecc8f;--bad:#ff5d6c;--ln:#262b47}
*{box-sizing:border-box}
body{margin:0 auto;max-width:760px;padding:12px;background:var(--bg);color:var(--tx);font:15px system-ui,sans-serif}
.card{background:var(--cd);border:1px solid var(--ln);border-radius:14px;padding:14px;margin:10px 0}
h1{font-size:18px;margin:6px 0}h2{font-size:14px;color:var(--mu);margin:0 0 8px}
input,button{font:inherit;border-radius:10px;border:1px solid var(--ln);background:#0f1325;color:var(--tx);padding:10px;width:100%}
button{background:var(--ac);border:0;color:#fff;font-weight:600;cursor:pointer}
button.s{background:#262b47;width:auto;padding:6px 10px;font-size:13px}button.d{background:var(--bad)}
.g{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;text-align:center}
.g b{display:block;font-size:18px}.mu{color:var(--mu);font-size:12px}
.f{display:grid;grid-template-columns:1fr 1fr 90px;gap:8px}.f button{grid-column:1/-1}
.row{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:10px 0;border-top:1px solid var(--ln)}
.row:first-child{border-top:0}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--mu);margin-right:6px}
.f2{display:grid;gap:8px}.on{background:var(--ok)}.off{color:var(--bad)}.hide{display:none}.ac{display:flex;gap:6px}
</style></head><body>
<div id="lg" class="card"><h1>Chaiya SSH</h1>
<input id="u" placeholder="ชื่อผู้ดูแล" autocomplete="username"><br><br>
<input id="p" type="password" placeholder="รหัสผ่าน" autocomplete="current-password"><br><br>
<button id="in">เข้าสู่ระบบ</button><p id="er" class="off"></p></div>
<div id="ap" class="hide">
<div class="card"><div class="g" id="st"></div></div>
<div class="card"><h2>สร้างผู้ใช้ SSH</h2><div class="f">
<input id="nu" placeholder="username"><input id="np" placeholder="password"><input id="nd" type="number" value="30" min="1">
<button id="cr">สร้าง</button></div><p id="rs" class="mu"></p></div>
<div class="card"><h2>ผู้ใช้ทั้งหมด</h2><div id="ls"></div></div>
<div class="card"><h2>ซับโดเมน (Cloudflare)</h2><div id="cf"></div></div>
<button class="s" id="out">ออกจากระบบ</button></div>
<script>
const $=s=>document.querySelector(s);let T=sessionStorage.getItem('t')||'';
const esc=s=>String(s).replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
async function api(p,b){
 const r=await fetch('/api/'+p,{method:b?'POST':'GET',headers:{'Content-Type':'application/json','X-Token':T},body:b?JSON.stringify(b):undefined});
 const j=await r.json().catch(()=>({}));
 if(r.status===401&&p!=='login'){lo();throw new Error('หมดเวลา')}
 if(!r.ok)throw new Error(j.error||r.status);return j}
function lo(){T='';sessionStorage.removeItem('t');$('#ap').classList.add('hide');$('#lg').classList.remove('hide')}
async function load(){
 const [s,u]=await Promise.all([api('status'),api('users')]);
 $('#st').innerHTML=[['CPU',s.cpu+'%'],['RAM',s.ram+'%'],['DISK',s.disk+'%'],['UP',s.up+'h']].map(x=>'<div><b>'+x[1]+'</b><span class="mu">'+x[0]+'</span></div>').join('');
 window.HOST=s.host;
 $('#ls').innerHTML=u.users.map(x=>'<div class="row"><div><span class="dot '+(x.online?'on':'')+'"></span><b>'+esc(x.user)+'</b> <span class="mu">'+(x.online?x.online+' online':'')+'</span><br><span class="mu">หมด '+esc(x.exp)+' ('+(x.active?'เหลือ '+x.left+' วัน':'<span class=off>หมดอายุ</span>')+')</span></div><div class="ac"><button class="s" data-a="ext" data-u="'+esc(x.user)+'">ต่อ</button><button class="s" data-a="pw" data-u="'+esc(x.user)+'">รหัส</button><button class="s d" data-a="del" data-u="'+esc(x.user)+'">ลบ</button></div></div>').join('')||'<p class="mu">ยังไม่มีผู้ใช้</p>'}
async function act(p,b){try{await api(p,b);await load()}catch(e){alert(e.message)}}
async function enter(){$('#lg').classList.add('hide');$('#ap').classList.remove('hide');try{await load();await loadcf()}catch(e){}}
$('#in').onclick=async()=>{try{const j=await api('login',{username:$('#u').value,password:$('#p').value});T=j.token;sessionStorage.setItem('t',T);enter()}catch(e){$('#er').textContent=e.message}};
async function loadcf(){
 const c=await api('cf');let h='';
 if(!c.configured)h='<div class="f2"><input id="cft" placeholder="Cloudflare API Token (Zone:DNS:Edit)"><input id="cfr" placeholder="โดเมนหลัก เช่น example.com"><button data-a="cs">บันทึก</button></div>';
 else h='<div class="f2"><input id="cfn" placeholder="ชื่อซับ เช่น ssh1"><input id="cfi" placeholder="IP (ว่าง = '+esc(c.ip||'เครื่องนี้')+')"><button data-a="ca">เพิ่ม .'+esc(c.root)+'</button></div>'
 +(c.error?'<p class="off">'+esc(c.error)+'</p>':'')
 +c.records.map(x=>'<div class="row"><div><b>'+esc(x.name)+'</b><br><span class="mu">'+esc(x.ip)+(x.proxied?' · proxied':'')+'</span></div><button class="s d" data-a="cd" data-i="'+esc(x.id)+'" data-n="'+esc(x.name)+'">ลบ</button></div>').join('')
 +'<p><button class="s" data-a="cc">ลบ token ออกจากเครื่อง</button></p>';
 $('#cf').innerHTML=h}
$('#cf').onclick=async e=>{const b=e.target.closest('button');if(!b)return;const a=b.dataset.a;
 try{
  if(a==='cs')await api('cf_save',{token:$('#cft').value.trim(),root:$('#cfr').value.trim()});
  else if(a==='ca')await api('cf_add',{sub:$('#cfn').value.trim(),ip:$('#cfi').value.trim()});
  else if(a==='cd'){if(!confirm('ลบ '+b.dataset.n+' ?'))return;await api('cf_del',{id:b.dataset.i})}
  else if(a==='cc'){if(!confirm('ลบ token ออกจากเครื่อง?'))return;await api('cf_clear',{})}
  await loadcf()}catch(er){alert(er.message)}};
$('#out').onclick=lo;
$('#cr').onclick=async()=>{try{const b={user:$('#nu').value.trim(),password:$('#np').value,days:+$('#nd').value};const j=await api('create',b);
 $('#rs').textContent='สร้างแล้ว: '+window.HOST+':143@'+j.user+':'+b.password+' (หมด '+j.exp+')';$('#nu').value=$('#np').value='';await load()}catch(e){$('#rs').textContent=e.message}};
$('#ls').onclick=async e=>{const b=e.target.closest('button');if(!b)return;const u=b.dataset.u,a=b.dataset.a;
 if(a==='del'){if(confirm('ลบ '+u+' ?'))await act('delete',{user:u})}
 else if(a==='ext'){const d=prompt('ต่อกี่วัน?','30');if(d)await act('extend',{user:u,days:+d})}
 else if(a==='pw'){const p=prompt('รหัสผ่านใหม่');if(p)await act('passwd',{user:u,password:p})}};
if(T)enter();
</script></body></html>
HTML

# ── SSL + NGINX ──────────────────────────────────────────────
SSL=/etc/ssl/chaiya-ssh; mkdir -p $SSL
openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj "/CN=${DOMAIN:-$IP}" -keyout $SSL/key.pem -out $SSL/cert.pem 2>/dev/null
CRT=$SSL/cert.pem; KEY=$SSL/key.pem
if [[ -n "$DOMAIN" ]]; then
  systemctl stop nginx chaiya-ws 2>/dev/null
  if certbot certonly --standalone -d "$DOMAIN" --register-unsafely-without-email --agree-tos -n -q; then
    CRT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem; KEY=/etc/letsencrypt/live/$DOMAIN/privkey.pem
    mkdir -p /etc/letsencrypt/renewal-hooks/{pre,post}
    printf '#!/bin/sh\nsystemctl stop chaiya-ws\n' > /etc/letsencrypt/renewal-hooks/pre/chaiya-ssh
    printf '#!/bin/sh\nsystemctl start chaiya-ws\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/post/chaiya-ssh
    chmod +x /etc/letsencrypt/renewal-hooks/{pre,post}/chaiya-ssh
    ok "SSL Let's Encrypt พร้อม"
  else
    echo "[WARN] ขอ SSL ไม่ได้ (เช็ก DNS ชี้ $IP แล้วหรือยัง) — ใช้ self-signed ไปก่อน"
  fi
fi
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/conf.d/chaiya-ssh.conf << EOF
server {
  listen 443 ssl;
  server_name _;
  ssl_certificate $CRT;
  ssl_certificate_key $KEY;
  root $APP/www;
  index index.html;
  add_header X-Frame-Options DENY;
  location /api/ {
    proxy_pass http://127.0.0.1:6790;
    proxy_set_header X-Real-IP \$remote_addr;
  }
}
EOF
nginx -t >/dev/null 2>&1 || { echo "[ERR] nginx config ผิด"; nginx -t; exit 1; }

# ── FIREWALL (เฉพาะถ้า ufw เปิดอยู่) ─────────────────────────
if command -v ufw >/dev/null && ufw status | grep -q active; then
  for p in 22 80 109 143 443; do ufw allow $p/tcp >/dev/null; done
fi

# ── START ────────────────────────────────────────────────────
systemctl daemon-reload
for s in dropbear chaiya-badvpn chaiya-ssh-web nginx chaiya-ws; do
  [[ -f /etc/systemd/system/$s.service || $s == nginx ]] || continue
  systemctl enable $s >/dev/null 2>&1; systemctl restart $s
  systemctl is-active --quiet $s && ok "$s" || echo "[WARN] $s ไม่ทำงาน: journalctl -u $s -n 20"
done

echo
echo "=========================================="
echo " เว็บแผง : https://${DOMAIN:-$IP}"
[[ $KEEP_ADMIN -eq 1 ]] && echo " Admin   : (ใช้รหัสเดิม)" || echo " Admin   : $ADMIN_USER / $ADMIN_PASS"
echo " SSH     : 143, 109 (Dropbear) | WS : 80 | UDPGW : 7300"
echo "=========================================="
