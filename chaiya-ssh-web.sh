#!/bin/bash
# ============================================================
#  CHAIYA SSH WEB — แผงจัดการ SSH แยกอิสระ (ไม่พึ่ง 3x-ui)
#  Dropbear 143/109 + WS :80 + BadVPN 7300 + เว็บแผง https :443
#  ใช้: [DOMAIN=sub.example.com] [ADMIN_USER=admin] [ADMIN_PASS=xxx] bash chaiya-ssh-web.sh
#  ไม่ใส่ DOMAIN = สคริปต์จะถามโดเมนตอนติดตั้ง และตรวจว่าชี้มาที่ VPS นี้แล้วหรือยัง
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

# ── โดเมน: ถามตอนติดตั้ง + ตรวจว่าชี้มาที่ VPS นี้แล้ว ─────────
resolve4(){
  { curl -s --max-time 8 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$1&type=A" 2>/dev/null \
      | grep -oE '"data":"[0-9]+(\.[0-9]+){3}"' | cut -d'"' -f4
    getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}'; } | sort -u
}
ask_domain(){
  local d="${DOMAIN,,}" a got tty=0 re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  : </dev/tty 2>/dev/null && tty=1
  [[ -z "$IP" ]] && { echo "[WARN] หา IP ของ VPS ไม่ได้ ข้ามการตรวจโดเมน"; return 0; }
  while true; do
    if [[ -z "$d" ]]; then
      [[ $tty -eq 1 ]] || { DOMAIN=""; return 0; }
      echo
      read -r -p "กรุณาระบุโดเมนของท่าน (เช่น ssh.example.com, เว้นว่าง = ข้าม): " d </dev/tty
      d="${d,,}"; d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d// /}"
      [[ -z "$d" ]] && { DOMAIN=""; info "ข้าม — ใช้ IP $IP และใบรับรองแบบ self-signed"; return 0; }
    fi
    if [[ ! "$d" =~ $re ]]; then
      echo "[WARN] รูปแบบโดเมนไม่ถูกต้อง ตัวอย่าง: ssh.example.com"
      [[ $tty -eq 1 ]] || { DOMAIN=""; return 0; }
      d=""; continue
    fi
    got=$(resolve4 "$d")
    if grep -qx "$IP" <<< "$got"; then
      ok "โดเมน $d ชี้มาที่ VPS นี้ ($IP) แล้ว — สำเร็จ"; DOMAIN="$d"; return 0
    fi
    echo -e "\033[0;33m[WARN]\033[0m ยังไม่พบว่า $d ชี้มาที่ VPS นี้"
    [[ -n "$got" ]] && echo "       ตอนนี้ชี้ไปที่: $(echo $got)"
    echo "       กรุณาเพิ่มชื่อโดเมนและไอพี VPS ของท่านลงใน Cloudflare ก่อนครับ"
    echo "         Type: A   Name: $d   IPv4: $IP   Proxy: ปิด (เมฆสีเทา / DNS only)"
    [[ $tty -eq 1 ]] || { DOMAIN="$d"; return 0; }
    read -r -p "กด Enter เพื่อตรวจสอบอีกครั้ง | พิมพ์โดเมนใหม่ | พิมพ์ skip เพื่อข้าม: " a </dev/tty
    a="${a,,}"
    if [[ "$a" == skip ]]; then DOMAIN=""; info "ข้าม — ใช้ IP $IP และใบรับรองแบบ self-signed"; return 0
    elif [[ -n "$a" ]]; then a="${a#http://}"; a="${a#https://}"; d="${a%%/*}"; fi
  done
}
ask_domain

# ── PACKAGES ─────────────────────────────────────────────────
info "ติดตั้งแพ็กเกจ..."
apt-get update -qq
apt-get install -y -qq nginx dropbear openssl curl python3 certbot badvpn >/dev/null 2>&1 \
  || apt-get install -y -qq nginx dropbear openssl curl python3 certbot >/dev/null 2>&1
mkdir -p $APP/www $CONF
rm -f $CONF/cf.json   # ลบ token Cloudflare เก่า (ไม่ใช้แล้ว)
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
        if s.path == '/api/users':
            ss = sessions(); res = []
            for u, v in sorted(load().items()):
                left = (datetime.date.fromisoformat(v['exp']) - datetime.date.today()).days
                res.append({'user': u, 'exp': v['exp'], 'left': left, 'active': left >= 0, 'online': len(ss.get(u, [])), 'limit': v.get('limit', 0), 'over': bool(v.get('over')), 'quota': v.get('quota', 0), 'used': v.get('used', 0), 'qover': bool(v.get('qover')), 'seen': v.get('seen', 0)})
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
        u = str(d.get('user', '')).strip()
        with LOCK:
            db = load()
            if s.path == '/api/create':
                p = str(d.get('password', '')); days = int(d.get('days', 30)); lim = int(d.get('limit', 2)); gb = float(d.get('gb', 0))
                if not NAME.match(u) or not 4 <= len(p) <= 64 or re.search(r'[:\s]', p) or not 1 <= days <= 3650 or not 0 <= lim <= 50 or not 0 <= gb <= 100000:
                    return s.out(400, {'error': 'ข้อมูลไม่ถูกต้อง (ชื่อ a-z0-9_- 3-31 ตัว / รหัส 4-64 ตัว ห้ามเว้นวรรค / เครื่อง 0-50 / ดาต้า 0-100000 GB)'})
                try: pwd.getpwnam(u); return s.out(409, {'error': 'ชื่อนี้มีอยู่แล้ว'})
                except KeyError: pass
                if not (sh('useradd', '-M', '-s', '/bin/false', u) and sh('chpasswd', inp='%s:%s\n' % (u, p))):
                    return s.out(500, {'error': 'สร้างผู้ใช้ไม่สำเร็จ'})
                exp = (datetime.date.today() + datetime.timedelta(days=days)).isoformat()
                sh('chage', '-E', exp, u); db[u] = {'exp': exp, 'limit': lim, 'quota': int(gb * 1024 ** 3), 'used': 0}; save(db)
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
                sh('chage', '-E', exp, u); db[u]['exp'] = exp; save(db)
                if not (db[u].get('over') or db[u].get('qover')): sh('usermod', '-U', u)
                return s.out(200, {'ok': True, 'exp': exp})
            if s.path == '/api/passwd':
                p = str(d.get('password', ''))
                if not 4 <= len(p) <= 64 or re.search(r'[:\s]', p): return s.out(400, {'error': 'รหัสผ่านไม่ถูกต้อง'})
                sh('chpasswd', inp='%s:%s\n' % (u, p))
                if db[u].get('over') or db[u].get('qover') or expired(db[u]['exp']): sh('usermod', '-L', u)
                return s.out(200, {'ok': True})
            if s.path in ('/api/limit', '/api/unlock'):
                v = db[u]
                try:
                    lim = int(d.get('limit', v.get('limit', 0)))
                    gb = float(d['gb']) if 'gb' in d else None
                except Exception: return s.out(400, {'error': 'ข้อมูลไม่ถูกต้อง'})
                if not 0 <= lim <= 50 or (gb is not None and not 0 <= gb <= 100000):
                    return s.out(400, {'error': 'จำนวนเครื่อง 0-50 และดาต้า 0-100000 GB (0 = ไม่จำกัด)'})
                v['limit'] = lim
                if gb is not None: v['quota'] = int(gb * 1024 ** 3)
                if d.get('reset'): v['used'] = 0
                if s.path == '/api/unlock': v.pop('over', None)
                if v.get('qover') and (not v.get('quota') or v.get('used', 0) < v['quota']): v.pop('qover', None)
                locked = bool(v.get('over') or v.get('qover'))
                if not locked and not expired(v['exp']): sh('usermod', '-U', u)
                save(db); return s.out(200, {'ok': True, 'locked': locked})
        s.out(404, {'error': 'not found'})

LAST = {}; PMAP = {}
def conns():
    # {pid: ไบต์ขึ้น+ลง} ของซ็อกเก็ตฝั่งไคลเอนต์ที่ Dropbear (143/109) อ่านจากตัวนับของเคอร์เนล
    out = {}
    try:
        r = subprocess.run(['ss', '-tnip', 'state', 'established', '( sport = :143 or sport = :109 )'],
                           capture_output=True, text=True, timeout=10).stdout
    except Exception: return None
    pid = None
    for l in r.splitlines():
        if l[:1] not in (' ', '\t'):
            m = re.search(r'pid=(\d+)', l); pid = int(m.group(1)) if m else None
        elif pid:
            a = re.search(r'bytes_acked:(\d+)', l); b = re.search(r'bytes_received:(\d+)', l)
            out[pid] = out.get(pid, 0) + (int(a.group(1)) if a else 0) + (int(b.group(1)) if b else 0)
    return out

def monitor():
    # ทุก 10 วิ: สะสมดาต้าต่อยูส + บันทึกเวลาออนไลน์ล่าสุด + ระงับเมื่อเชื่อมต่อเกินจำนวน/ดาต้าครบ
    first = True
    while True:
        time.sleep(10)
        try:
            with LOCK:
                db = load(); ss = sessions(); cn = conns(); ch = False; now = int(time.time())
                if cn is not None:
                    for u, pids in ss.items():
                        for p in pids: PMAP[p] = u
                    if first:
                        LAST.clear(); LAST.update(cn); first = False
                    else:
                        for p, b in cn.items():
                            dlt = b - LAST.get(p, 0)
                            if dlt < 0: dlt = b
                            LAST[p] = b; u = PMAP.get(p)
                            if u in db and dlt:
                                db[u]['used'] = db[u].get('used', 0) + dlt; ch = True
                    for p in [p for p in LAST if p not in cn]: LAST.pop(p, None)
                    for p in [p for p in PMAP if p not in cn]: PMAP.pop(p, None)
                for u, v in db.items():
                    n = len(ss.get(u, []))
                    if n and now - v.get('seen', 0) > 60: v['seen'] = now; ch = True
                    hit = False
                    lim = int(v.get('limit', 0)); q = int(v.get('quota', 0))
                    if lim > 0 and n > lim and not v.get('over'): v['over'] = now; hit = True
                    if q > 0 and v.get('used', 0) >= q and not v.get('qover'): v['qover'] = now; hit = True
                    if hit:
                        sh('usermod', '-L', u); ch = True
                        for p in ss.get(u, []):
                            try: os.kill(p, 9)
                            except Exception: pass
                if ch: save(db)
        except Exception: pass

threading.Thread(target=reaper, daemon=True).start()
threading.Thread(target=monitor, daemon=True).start()
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
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0a1020">
<title>Chaiya SSH</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Thai:wght@400;500;600;700&display=swap" rel="stylesheet">
<style>
:root{--bg:#0a1020;--s1:#101a2e;--s2:#16233b;--ln:#223250;--tx:#e8eefc;--mu:#8a9bbd;--ac:#5b8cff;--ok:#34d399;--wn:#fbbf24;--bd:#fb7185;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:var(--bg);color:var(--tx);font:15px/1.5 "IBM Plex Sans Thai","Noto Sans Thai",system-ui,-apple-system,sans-serif;font-variant-numeric:tabular-nums}
button,input{font:inherit;color:inherit}
.hide{display:none!important}
:focus-visible{outline:2px solid var(--ac);outline-offset:2px}
.btn{white-space:nowrap;display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:44px;padding:0 20px;border:0;border-radius:10px;background:var(--ac);color:#fff;font-weight:600;cursor:pointer;transition:filter .15s}
.btn:hover{filter:brightness(1.12)}
.btn[disabled]{opacity:.65;cursor:default}
.btn.g{background:var(--s2);border:1px solid var(--ln);color:var(--tx)}
.btn.r{background:var(--bd);color:#2a0710}
.btn.sm{min-height:34px;padding:0 12px;font-size:13px;border-radius:8px}
.btn.busy::after{content:"";width:14px;height:14px;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:sp .7s linear infinite}
@keyframes sp{to{transform:rotate(360deg)}}
.inp{width:100%;min-height:46px;padding:0 14px;background:#0b1426;border:1px solid var(--ln);border-radius:10px}
.inp:focus{border-color:var(--ac);outline:0;box-shadow:0 0 0 3px #5b8cff33}
.inp::placeholder{color:#5d6e90}
.l{display:block;font-size:13px;color:var(--mu);margin:0 0 6px}
.fld{margin-bottom:14px}
.hint{font-size:12px;color:var(--mu);margin-top:5px}
.ig{display:flex;gap:8px}
.chips{display:flex;gap:6px;margin-top:8px}
.chips button{border:1px solid var(--ln);background:transparent;color:var(--mu);border-radius:999px;padding:3px 12px;font-size:12px;cursor:pointer}
.chips button:hover{color:var(--tx);border-color:var(--ac)}
.mu{color:var(--mu)}

/* ---------- login ---------- */
#lg{min-height:100vh;display:grid;grid-template-columns:1.1fr 1fr}
.brand{padding:48px;display:flex;flex-direction:column;justify-content:space-between;gap:40px;background:var(--s1);border-right:1px solid var(--ln)}
.logo{flex:none;white-space:nowrap;display:flex;align-items:center;gap:12px;font-weight:700;font-size:19px}
.mk{width:36px;height:36px;border-radius:10px;background:var(--ac);display:grid;place-items:center;font-size:14px;font-weight:700;color:#fff}
.brand h2{font-size:34px;line-height:1.3;margin:0 0 14px;font-weight:700;max-width:14em}
.brand p{margin:0;color:var(--mu);max-width:26em}
.ports{list-style:none;margin:0;padding:0;border:1px solid var(--ln);border-radius:14px;overflow:hidden}
.ports li{display:flex;align-items:baseline;gap:16px;padding:12px 16px;border-top:1px solid var(--ln)}
.ports li:first-child{border-top:0}
.ports b{width:56px;font-size:18px;color:var(--ac)}
.ports span{color:var(--mu);font-size:14px}
.fw{display:grid;place-items:center;padding:32px 20px}
.fb{width:100%;max-width:380px}
.fb h1{font-size:26px;margin:0 0 4px}
.fb>p{margin:0 0 26px;color:var(--mu)}
.mlogo{display:none;margin-bottom:32px}
.pw{position:relative}
.pw .inp{padding-right:72px}
.pw button{position:absolute;right:6px;top:6px;height:34px;padding:0 12px;border:0;border-radius:8px;background:transparent;color:var(--mu);cursor:pointer;font-size:13px}
.pw button:hover{color:var(--tx)}
.err{min-height:22px;margin:0 0 12px;color:var(--bd);font-size:14px}
#lf.shk{animation:shk .35s}
@keyframes shk{20%,60%{transform:translateX(-7px)}40%,80%{transform:translateX(7px)}}
@media(max-width:820px){#lg{grid-template-columns:1fr}.brand{display:none}.mlogo{display:flex}}

/* ---------- dashboard ---------- */
.top{position:sticky;top:0;z-index:5;background:#0a1020ea;backdrop-filter:blur(10px);border-bottom:1px solid var(--ln);padding-top:env(safe-area-inset-top)}
.tin{max-width:960px;margin:0 auto;padding:10px 16px;display:flex;align-items:center;gap:12px}
.hn{margin-left:auto;font-size:13px;color:var(--mu);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.wrap{max-width:960px;margin:0 auto;padding:20px 16px calc(60px + env(safe-area-inset-bottom))}
.pn{background:var(--s1);border:1px solid var(--ln);border-radius:16px;margin-bottom:16px;overflow:hidden}
.ph{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;padding:14px 18px;border-bottom:1px solid var(--ln)}
.ph h3{margin:0;font-size:16px}
.ph small{color:var(--mu);font-size:12px}
.pb{padding:18px}
.hl{display:grid;grid-template-columns:repeat(4,1fr);padding:22px 8px}
.gz{display:flex;flex-direction:column;align-items:center;text-align:center;gap:2px}
.rg{position:relative;width:76px;height:76px;margin-bottom:8px}
.rg svg{width:76px;height:76px}
.rv{position:absolute;inset:0;display:grid;place-items:center;font-weight:700;font-size:15px}
.rg.ld{border:6px solid var(--ln);border-radius:50%}
.rg.ld .rv{font-size:17px}
.gz b{font-size:14px}.gz span{font-size:12px;color:var(--mu)}
.sm4{display:grid;grid-template-columns:repeat(5,1fr);background:var(--s1);border:1px solid var(--ln);border-radius:16px;overflow:hidden;margin-bottom:16px}
.tl{display:flex;flex-direction:column;align-items:flex-start;gap:2px;padding:16px 18px;border:0;border-left:1px solid var(--ln);background:transparent;cursor:pointer;text-align:left;box-shadow:inset 0 -3px 0 transparent;transition:background .15s}
.tl:first-child{border-left:0}
.tl:hover{background:#16233b80}
.tl[aria-pressed=true]{background:var(--s2);box-shadow:inset 0 -3px 0 var(--ac)}
.tl .n{font-size:28px;font-weight:700;line-height:1.2}
.tl .t{font-size:13px;color:var(--mu)}
.n.o{color:var(--ok)}.n.w{color:var(--wn)}.n.x{color:var(--bd)}
.srch{max-width:220px;min-height:36px;font-size:14px}
.ur{display:grid;grid-template-columns:44px 1fr auto;gap:14px;align-items:center;padding:14px 18px;border-top:1px solid var(--ln)}
.av{position:relative;width:44px;height:44px;border-radius:12px;background:var(--s2);display:grid;place-items:center;font-weight:700;text-transform:uppercase}
.av.on::after{content:"";position:absolute;right:-3px;bottom:-3px;width:12px;height:12px;border-radius:50%;background:var(--ok);border:2px solid var(--s1)}
.nm{font-weight:600;word-break:break-all}
.bg{display:inline-block;font-size:12px;padding:1px 10px;border-radius:999px;margin-left:8px;font-weight:500;white-space:nowrap}
.b-ok{background:#34d3991f;color:var(--ok)}.b-wn{background:#fbbf241f;color:var(--wn)}.b-bd{background:#fb71851f;color:var(--bd)}
.sb{font-size:13px;color:var(--mu)}
.pr{height:4px;background:var(--ln);border-radius:4px;margin-top:8px;overflow:hidden;max-width:240px}
.pr i{display:block;height:100%;border-radius:4px}
.ua{display:flex;gap:6px}
.em{padding:40px 18px;text-align:center;color:var(--mu)}
.em b{display:block;color:var(--tx);font-size:16px;margin-bottom:4px}
.em .btn{margin-top:16px}
@media(max-width:700px){
 .hl{grid-template-columns:1fr 1fr;row-gap:22px}
 .sm4{grid-template-columns:1fr 1fr}.tl:nth-child(odd){border-left:0}.tl:nth-child(n+3){border-top:1px solid var(--ln)}.tl:nth-child(5){grid-column:1/-1}
 .ur{grid-template-columns:44px 1fr}.ua{grid-column:1/-1;display:grid;grid-template-columns:repeat(4,1fr)}.ua .btn{padding:0 4px}
 .srch{max-width:none;flex:1}
}

.av.lk{background:#fb71852b;color:var(--bd)}
@media(max-width:520px){.hn{display:none}}
.ck{display:flex;align-items:center;gap:10px;font-size:14px;margin:2px 0 14px;cursor:pointer}.ck input{width:18px;height:18px;accent-color:var(--ac)}
.dt{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--mu);margin-right:6px}.dt.on{background:var(--ok)}
/* ---------- modal + toast ---------- */
.ov{position:fixed;inset:0;z-index:50;background:#050a16b8;backdrop-filter:blur(4px);display:grid;place-items:center;padding:16px;animation:fi .15s}
.md{width:100%;max-width:420px;max-height:92vh;overflow:auto;background:var(--s1);border:1px solid var(--ln);border-radius:20px;box-shadow:0 24px 60px #0009;animation:pop .18s}
.mh{display:flex;gap:14px;padding:22px 22px 4px}
.ic{flex:none;width:40px;height:40px;border-radius:12px;display:grid;place-items:center;font-size:19px;font-weight:700}
.ic.i{background:#5b8cff26;color:var(--ac)}.ic.w{background:#fb71852b;color:var(--bd)}.ic.s{background:#34d3992b;color:var(--ok)}
.md h4{margin:0 0 2px;font-size:17px}
.md .m{margin:0;color:var(--mu);font-size:14px}
.mb{padding:16px 22px 0}
.fe{padding:0 22px;color:var(--bd);font-size:14px;min-height:0}
.fe:not(:empty){padding-top:4px}
.mf{display:flex;gap:10px;justify-content:flex-end;padding:18px 22px 22px}
.kv{display:grid;grid-template-columns:84px 1fr auto;align-items:center;gap:8px;padding:9px 0;border-top:1px solid var(--ln)}
.kv:first-child{border-top:0}
.kv span{color:var(--mu);font-size:13px}
.kv code{font:600 14px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
@keyframes fi{from{opacity:0}}
@keyframes pop{from{opacity:0;transform:scale(.96) translateY(8px)}}
@keyframes up{from{opacity:0;transform:translateY(24px)}}
@media(max-width:520px){.ov{align-items:end;padding:0}.md{max-width:none;border-radius:20px 20px 0 0;animation:up .22s}.mf .btn{flex:1}}
#tt{position:fixed;z-index:60;left:50%;transform:translateX(-50%);bottom:calc(16px + env(safe-area-inset-bottom));display:grid;gap:8px;width:min(92vw,400px);pointer-events:none}
.ts{pointer-events:auto;padding:12px 16px;background:var(--s2);border:1px solid var(--ln);border-left:4px solid var(--ac);border-radius:12px;box-shadow:0 10px 30px #0007;font-size:14px;animation:up .2s}
.ts.ok{border-left-color:var(--ok)}.ts.er{border-left-color:var(--bd)}
@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
</style></head><body>

<div id="lg">
 <aside class="brand">
  <div class="logo"><span class="mk">&gt;_</span>Chaiya SSH</div>
  <div>
   <h2>จัดการบัญชี SSH ทั้งหมดจากหน้าเดียว</h2>
   <p>สร้าง ต่ออายุ และตัดการเชื่อมต่อผู้ใช้ พร้อมดูสถานะเซิร์ฟเวอร์ตามเวลาจริง</p>
  </div>
  <ul class="ports">
   <li><b>80</b><span>WebSocket</span></li>
   <li><b>143</b><span>Dropbear SSH</span></li>
   <li><b>109</b><span>Dropbear SSH พอร์ตสำรอง</span></li>
   <li><b>7300</b><span>BadVPN UDPGW</span></li>
  </ul>
 </aside>
 <main class="fw"><div class="fb">
  <div class="logo mlogo"><span class="mk">&gt;_</span>Chaiya SSH</div>
  <h1>เข้าสู่ระบบ</h1><p>สำหรับผู้ดูแลระบบเท่านั้น</p>
  <form id="lf" autocomplete="on">
   <div class="fld"><label class="l" for="u">ชื่อผู้ดูแล</label><input class="inp" id="u" autocomplete="username" autocapitalize="none" required></div>
   <div class="fld"><label class="l" for="p">รหัสผ่าน</label><div class="pw"><input class="inp" id="p" type="password" autocomplete="current-password" required><button type="button" id="eye">แสดง</button></div></div>
   <div class="err" id="er" role="alert"></div>
   <button class="btn" id="in" style="width:100%">เข้าสู่ระบบ</button>
  </form>
 </div></main>
</div>

<div id="ap" class="hide">
 <header class="top"><div class="tin">
  <div class="logo"><span class="mk">&gt;_</span>Chaiya SSH</div>
  <span class="hn" id="hn"></span>
  <button class="btn g sm" id="out">ออกจากระบบ</button>
 </div></header>
 <div class="wrap">
  <section class="pn">
   <div class="ph"><h3>สถานะเซิร์ฟเวอร์</h3><small id="up"></small></div>
   <div class="hl" id="hl"></div>
  </section>
  <div class="sm4" id="st"></div>
  <section class="pn">
   <div class="ph"><div><h3>ผู้ใช้ SSH</h3><small id="tot"></small></div>
    <div style="display:flex;gap:8px;flex:1;justify-content:flex-end">
     <input class="inp srch" id="q" type="search" placeholder="ค้นหาชื่อผู้ใช้" aria-label="ค้นหาชื่อผู้ใช้">
     <button class="btn sm" data-a="new" id="nw">สร้างผู้ใช้</button>
    </div></div>
   <div id="ls"></div>
  </section>
 </div>
</div>
<div id="tt" aria-live="polite"></div>

<script>
const $=s=>document.querySelector(s);
let T=sessionStorage.getItem('t')||'',HOST='',USERS=[],F='all',TM=null;
const esc=s=>String(s).replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
const fmt=d=>new Date(d+'T00:00:00Z').toLocaleDateString('th-TH',{day:'numeric',month:'short',year:'2-digit',timeZone:'UTC'});
const rnd=n=>[...crypto.getRandomValues(new Uint8Array(n))].map(b=>'abcdefghjkmnpqrstuvwxyz23456789'[b%31]).join('');
async function copy(t){try{await navigator.clipboard.writeText(t)}catch(e){const a=document.createElement('textarea');a.value=t;document.body.appendChild(a);a.select();document.execCommand('copy');a.remove()}}
async function bz(b,fn){b.disabled=true;b.classList.add('busy');try{return await fn()}finally{b.disabled=false;b.classList.remove('busy')}}

function toast(m,k){const e=document.createElement('div');e.className='ts '+(k||'');e.textContent=m;$('#tt').appendChild(e);setTimeout(()=>e.remove(),k==='er'?5000:3200)}

/* กล่องโต้ตอบเดียวใช้ทั้งยืนยัน / กรอกข้อมูล / แสดงผล */
function ask(o){return new Promise(res=>{
 const prev=document.activeElement,ov=document.createElement('div');ov.className='ov';
 const fs=(o.fields||[]).map((x,i)=>x.type==='check'?'<label class="ck"><input type="checkbox" id="f'+i+'"> '+esc(x.label)+'</label>':'<div class="fld"><label class="l" for="f'+i+'">'+esc(x.label)+'</label><div class="ig"><input class="inp" id="f'+i+'" type="'+(x.type||'text')+'" value="'+esc(x.value==null?'':x.value)+'" placeholder="'+esc(x.ph||'')+'" autocomplete="off" autocapitalize="none"'+(x.type==='number'?' step="any"':'')+(x.min?' min="'+x.min+'"':'')+'>'+(x.gen?'<button type="button" class="btn g sm" data-gen style="min-height:46px">สุ่ม</button>':'')+'</div>'
  +(x.chips?'<div class="chips">'+x.chips.map(c=>'<button type="button" data-c="'+c+'">'+c+' '+(x.unit||'วัน')+'</button>').join('')+'</div>':'')
  +(x.hint?'<div class="hint">'+esc(x.hint)+'</div>':'')+'</div>').join('');
 const ic=o.ic||'i';
 ov.innerHTML='<form class="md" role="dialog" aria-modal="true" aria-labelledby="mt"><div class="mh"><div class="ic '+ic+'">'+({i:'i',w:'!',s:'✓'})[ic]+'</div><div><h4 id="mt">'+esc(o.title)+'</h4>'+(o.msg?'<p class="m">'+esc(o.msg)+'</p>':'')+'</div></div>'
  +((o.html||fs)?'<div class="mb">'+(o.html||'')+fs+'</div>':'')+'<div class="fe" role="alert"></div>'
  +'<div class="mf">'+(o.cancel===false?'':'<button type="button" class="btn g" data-x>'+esc(o.cancel||'ยกเลิก')+'</button>')+'<button class="btn'+(o.danger?' r':'')+'" data-ok>'+esc(o.ok||'ตกลง')+'</button></div></form>';
 document.body.appendChild(ov);
 const fe=ov.querySelector('.fe'),ok=ov.querySelector('[data-ok]');
 const done=v=>{document.removeEventListener('keydown',kd);ov.remove();if(prev&&prev.focus)prev.focus();res(v)};
 const kd=e=>{if(e.key==='Escape'&&o.cancel!==false)done(null)};
 document.addEventListener('keydown',kd);
 ov.onclick=e=>{
  if(e.target===ov&&o.cancel!==false)return done(null);
  if(e.target.closest('[data-x]'))return done(null);
  const g=e.target.closest('[data-gen]');if(g){const i=g.parentNode.querySelector('input');i.type='text';i.value=rnd(10);i.focus()}
  const c=e.target.closest('[data-c]');if(c)c.closest('.fld').querySelector('input').value=c.dataset.c;
  const cp=e.target.closest('[data-cp]');if(cp)copy(cp.dataset.cp).then(()=>toast('คัดลอกแล้ว','ok'))};
 ov.querySelector('form').onsubmit=async e=>{e.preventDefault();fe.textContent='';
  const v={};(o.fields||[]).forEach((x,i)=>{const el=ov.querySelector('#f'+i);v[x.k]=x.type==='check'?el.checked:el.value});
  try{const r=o.run?await bz(ok,()=>o.run(v)):true;done(r==null?true:r)}catch(er){fe.textContent=er.message}};
 const f1=ov.querySelector('input.inp');(f1||ok).focus()})}

async function api(p,b){
 let r;try{r=await fetch('/api/'+p,{method:b?'POST':'GET',headers:{'Content-Type':'application/json','X-Token':T},body:b?JSON.stringify(b):undefined})}
 catch(e){throw new Error('เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ ลองใหม่อีกครั้ง')}
 const j=await r.json().catch(()=>({}));
 if(r.status===401&&p!=='login'){lo('หมดเวลาเข้าสู่ระบบ กรุณาเข้าสู่ระบบใหม่');throw new Error('หมดเวลาเข้าสู่ระบบ')}
 if(!r.ok)throw new Error(j.error||('เกิดข้อผิดพลาด ('+r.status+')'));return j}
function lo(m){T='';sessionStorage.removeItem('t');clearInterval(TM);document.querySelectorAll('.ov').forEach(x=>x.remove());
 $('#ap').classList.add('hide');$('#lg').classList.remove('hide');if(m)toast(m,'er')}

/* ---------- สถานะ + สรุปยอด ---------- */
const ring=(v,lab,sub)=>{const c=v<60?'--ok':v<85?'--wn':'--bd';
 return '<div class="gz"><div class="rg"><svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="26" fill="none" stroke="var(--ln)" stroke-width="6"/><circle cx="32" cy="32" r="26" fill="none" stroke="var('+c+')" stroke-width="6" stroke-linecap="round" stroke-dasharray="'+(v*1.634).toFixed(1)+' 163.4" transform="rotate(-90 32 32)"/></svg><div class="rv">'+v+'%</div></div><b>'+lab+'</b><span>'+sub+'</span></div>'};
function health(s){
 const up=s.up>=24?Math.floor(s.up/24)+' วัน '+s.up%24+' ชม.':s.up+' ชม.';
 $('#hl').innerHTML=ring(s.cpu,'CPU','โปรเซสเซอร์')+ring(s.ram,'RAM','หน่วยความจำ')+ring(s.disk,'Disk','พื้นที่จัดเก็บ')
  +'<div class="gz"><div class="rg ld"><div class="rv">'+s.load+'</div></div><b>Load</b><span>เปิดมา '+up+'</span></div>';
 $('#up').textContent=s.host+' | อัปเดต '+new Date().toLocaleTimeString('th-TH');HOST=s.host;$('#hn').textContent=s.host}
const fb=n=>n>=1073741824?(n/1073741824).toFixed(n>=107374182400?0:1)+' GB':n>=1048576?Math.round(n/1048576)+' MB':Math.round(n/1024)+' KB';
const ago=t=>{if(!t)return 'ยังไม่เคยเชื่อมต่อ';const s=Math.max(0,Date.now()/1000-t);return s<90?'เมื่อสักครู่':s<3600?Math.round(s/60)+' นาทีที่แล้ว':s<86400?Math.round(s/3600)+' ชม.ที่แล้ว':Math.round(s/86400)+' วันที่แล้ว'};
const stt=x=>x.over?['b-bd','ล็อกอินเกินจำนวน']:x.qover?['b-bd','ดาต้าหมด']:!x.active?['b-bd','หมดอายุ']:x.left<=3?['b-wn','ใกล้หมด']:['b-ok','ใช้งานได้'];
function tiles(){
 const a=USERS,d=[['all',a.length,'ผู้ใช้ทั้งหมด',''],['on',a.filter(x=>x.online).length,'ออนไลน์ตอนนี้','o'],
  ['soon',a.filter(x=>x.active&&!x.over&&!x.qover&&x.left<=3).length,'ใกล้หมดอายุ (3 วัน)','w'],
  ['sus',a.filter(x=>x.over||x.qover).length,'ถูกระงับ','x'],['exp',a.filter(x=>!x.active).length,'หมดอายุแล้ว','x']];
 $('#st').innerHTML=d.map(x=>'<button class="tl" data-f="'+x[0]+'" aria-pressed="'+(F===x[0])+'"><span class="n '+x[3]+'">'+x[1]+'</span><span class="t">'+x[2]+'</span></button>').join('');
 $('#tot').textContent='ใช้ดาต้ารวม '+fb(a.reduce((s,x)=>s+(x.used||0),0))}
function list(){
 const q=$('#q').value.trim().toLowerCase();
 const a=USERS.filter(x=>(!q||x.user.includes(q))&&(F==='all'||(F==='on'&&x.online)||(F==='soon'&&x.active&&!x.over&&!x.qover&&x.left<=3)||(F==='sus'&&(x.over||x.qover))||(F==='exp'&&!x.active)));
 if(!USERS.length)return $('#ls').innerHTML='<div class="em"><b>ยังไม่มีผู้ใช้</b>สร้างผู้ใช้คนแรกเพื่อเริ่มแจกบัญชี SSH<br><button class="btn" data-a="new">สร้างผู้ใช้</button></div>';
 if(!a.length)return $('#ls').innerHTML='<div class="em"><b>ไม่พบผู้ใช้ที่ตรงเงื่อนไข</b>ลองเปลี่ยนคำค้นหาหรือตัวกรอง<br><button class="btn g" data-a="clr">ล้างตัวกรอง</button></div>';
 $('#ls').innerHTML=a.map(x=>{
  const k=stt(x),sus=x.over||x.qover,ok=x.active&&!sus,on=x.online&&!sus,u=esc(x.user);
  const pc=ok?Math.min(100,Math.max(4,x.left/30*100)):0,col=!ok?'--bd':x.left<=3?'--wn':'--ok';
  const dq=x.quota>0,dp=dq?Math.min(100,x.used/x.quota*100):0,dc=dp>=90?'--bd':dp>=70?'--wn':'--ok';
  const why=x.over&&x.qover?'เชื่อมต่อเกินจำนวนและดาต้าครบ':x.over?'เชื่อมต่อเกินจำนวน':'ดาต้าครบ';
  const st=sus?'<div class="sb" style="color:var(--bd)">ถูกระงับเพราะ'+why+' ตัดการเชื่อมต่อทั้งหมดแล้ว</div>'
   :'<div class="sb"><span class="dt'+(on?' on':'')+'"></span>'+(on?'ออนไลน์ '+x.online+(x.limit?'/'+x.limit:'')+' เครื่อง':'ออฟไลน์ ('+ago(x.seen)+')')+'</div>';
  const dd='<div class="sb">ดาต้า '+(dq?'ใช้ '+fb(x.used)+' จาก '+fb(x.quota)+' เหลือ '+fb(Math.max(0,x.quota-x.used)):'ใช้ไป '+fb(x.used)+' (ไม่จำกัด)')+'</div>';
  return '<div class="ur"><div class="av'+(on?' on':'')+(sus?' lk':'')+'">'+u.charAt(0)+'</div><div><div><span class="nm">'+u+'</span><span class="bg '+k[0]+'">'+k[1]+'</span></div>'
   +st+'<div class="sb">'+(x.active?'หมดอายุ '+fmt(x.exp)+' เหลือ '+x.left+' วัน':'หมดอายุเมื่อ '+fmt(x.exp))+'</div>'+dd
   +'<div class="pr"><i style="width:'+pc+'%;background:var('+col+')"></i></div>'
   +(dq?'<div class="pr" style="margin-top:4px"><i style="width:'+dp+'%;background:var('+dc+')"></i></div>':'')+'</div>'
   +'<div class="ua"><button class="btn g sm" data-a="ext" data-u="'+u+'">ต่ออายุ</button><button class="btn g sm" data-a="pw" data-u="'+u+'">รหัสผ่าน</button>'
   +'<button class="btn'+(sus?'':' g')+' sm" data-a="'+(x.over?'unl':'lim')+'" data-u="'+u+'">'+(x.over?'ปลดล็อก':x.qover?'เพิ่มดาต้า':'โควต้า')+'</button>'
   +'<button class="btn r sm" data-a="del" data-u="'+u+'">ลบ</button></div></div>'}).join('')}
async function load(){
 const r=await Promise.all([api('status'),api('users')]);health(r[0]);USERS=r[1].users;tiles();list()}

/* ---------- ผู้ใช้ ---------- */
function conn(r){
 const row=(l,v,c)=>'<div class="kv"><span>'+l+'</span><code>'+esc(v)+'</code>'+(c?'<button type="button" class="btn g sm" data-cp="'+esc(c)+'">คัดลอก</button>':'<i></i>')+'</div>';
 return ask({ic:'s',title:'สร้างผู้ใช้แล้ว',msg:'ส่งข้อมูลนี้ให้ผู้ใช้ รหัสผ่านจะไม่แสดงอีก',cancel:'ปิด',ok:'คัดลอกทั้งหมด',
  html:row('โฮสต์',HOST,HOST)+row('ผู้ใช้',r.user,r.user)+row('รหัสผ่าน',r.password,r.password)+row('พอร์ต SSH','143 / 109')+row('WebSocket','80')+row('UDPGW','7300')+row('จำกัดเครื่อง',r.limit?r.limit+' เครื่อง':'ไม่จำกัด')+row('จำกัดดาต้า',r.gb?r.gb+' GB':'ไม่จำกัด')+row('หมดอายุ',fmt(r.exp)),
  run:async()=>{await copy(HOST+':143@'+r.user+':'+r.password);toast('คัดลอกข้อมูลเชื่อมต่อแล้ว','ok');return true}})}
async function mk(){
 const r=await ask({title:'สร้างผู้ใช้ SSH',msg:'บัญชีนี้เชื่อมต่อได้ผ่านพอร์ต 143 และ 109',ok:'สร้างผู้ใช้',
  fields:[{k:'user',label:'ชื่อผู้ใช้',ph:'เช่น somchai01',hint:'a-z 0-9 _ - ความยาว 3-31 ตัว'},
   {k:'password',label:'รหัสผ่าน',gen:1,hint:'4-64 ตัว ห้ามเว้นวรรคและเครื่องหมาย :'},
   {k:'days',label:'จำนวนวันใช้งาน',type:'number',value:30,min:1,chips:[7,30,90]},
   {k:'limit',label:'จำกัดจำนวนเครื่องที่เชื่อมต่อพร้อมกัน',type:'number',value:2,min:1,chips:[1,2,3,5],unit:'เครื่อง',hint:'ถ้าเชื่อมต่อเกินจำนวนนี้ ระบบจะระงับบัญชีและตัดการเชื่อมต่อทั้งหมดทันที'},
   {k:'gb',label:'จำกัดดาต้า (GB)',type:'number',value:0,min:0,chips:[10,50,100],unit:'GB',hint:'0 = ไม่จำกัด เมื่อใช้ครบ ระบบจะระงับบัญชีและตัดการเชื่อมต่อทั้งหมด'}],
  run:async v=>{const j=await api('create',{user:v.user.trim(),password:v.password,days:+v.days,limit:+v.limit,gb:+v.gb||0});return{user:j.user,exp:j.exp,password:v.password,limit:+v.limit,gb:+v.gb||0}}});
 if(r&&r!==true){await load();conn(r)}}
async function ext(u){
 const r=await ask({title:'ต่ออายุ '+u,msg:'นับต่อจากวันหมดอายุเดิม หรือนับจากวันนี้ถ้าหมดอายุแล้ว',ok:'ต่ออายุ',
  fields:[{k:'days',label:'จำนวนวันที่เพิ่ม',type:'number',value:30,min:1,chips:[7,30,90]}],run:v=>api('extend',{user:u,days:+v.days})});
 if(r){toast('ต่ออายุ '+u+' แล้ว หมดอายุ '+fmt(r.exp),'ok');load()}}
async function pw(u){
 const r=await ask({title:'เปลี่ยนรหัสผ่าน '+u,msg:'ผู้ใช้ต้องใช้รหัสผ่านใหม่ในการเชื่อมต่อครั้งถัดไป',ok:'เปลี่ยนรหัสผ่าน',
  fields:[{k:'password',label:'รหัสผ่านใหม่',gen:1,hint:'4-64 ตัว ห้ามเว้นวรรคและเครื่องหมาย :'}],run:v=>api('passwd',{user:u,password:v.password})});
 if(r){toast('เปลี่ยนรหัสผ่านของ '+u+' แล้ว','ok');load()}}
async function del(u){
 const r=await ask({ic:'w',danger:1,title:'ลบผู้ใช้ '+u+'?',msg:'ลบถาวรและตัดการเชื่อมต่อที่ออนไลน์อยู่ทันที ย้อนกลับไม่ได้',ok:'ลบผู้ใช้',run:()=>api('delete',{user:u})});
 if(r){toast('ลบผู้ใช้ '+u+' แล้ว','ok');load()}}

async function lim(u,unl){
 const x=USERS.find(y=>y.user===u)||{},sus=x.over||x.qover;
 const r=await ask({ic:sus?'w':'i',title:(unl?'ปลดล็อก ':'โควต้าของ ')+u,
  msg:x.over?'บัญชีถูกระงับเพราะเชื่อมต่อเกินจำนวน ตั้งค่าแล้วกดปลดล็อกเพื่อใช้งานต่อ':x.qover?'ดาต้าครบแล้ว เพิ่มโควต้าหรือรีเซ็ตยอดที่ใช้เพื่อใช้งานต่อ':'ใช้ไปแล้ว '+fb(x.used||0)+' ตั้งได้ทั้งจำนวนเครื่องและดาต้า',
  ok:unl?'ปลดล็อก':'บันทึก',
  fields:[{k:'limit',label:'จำนวนเครื่องที่เชื่อมต่อพร้อมกันได้',type:'number',value:x.limit||0,min:0,chips:[1,2,3,5],unit:'เครื่อง',hint:'0 = ไม่จำกัด'},
   {k:'gb',label:'โควต้าดาต้า (GB)',type:'number',value:x.quota?+(x.quota/1073741824).toFixed(2):0,min:0,chips:[10,50,100],unit:'GB',hint:'0 = ไม่จำกัด'},
   {k:'reset',type:'check',label:'รีเซ็ตยอดที่ใช้แล้วเป็น 0'}],
  run:v=>api(unl?'unlock':'limit',{user:u,limit:+v.limit,gb:+v.gb,reset:v.reset})});
 if(r){toast(r.locked?'บันทึกแล้ว แต่บัญชียังถูกระงับ ต้องเพิ่มโควต้าหรือรีเซ็ตยอดด้วย':(unl?'ปลดล็อก '+u+' แล้ว':'บันทึกโควต้าของ '+u+' แล้ว'),r.locked?'er':'ok');load()}}
$('#ls').onclick=e=>{const b=e.target.closest('button');if(!b)return;const a=b.dataset.a,u=b.dataset.u;
 if(a==='new')mk();else if(a==='ext')ext(u);else if(a==='pw')pw(u);else if(a==='lim')lim(u);else if(a==='unl')lim(u,1);else if(a==='del')del(u);
 else if(a==='clr'){F='all';$('#q').value='';tiles();list()}};
$('#nw').onclick=mk;
$('#st').onclick=e=>{const b=e.target.closest('[data-f]');if(!b)return;F=b.dataset.f;tiles();list()};
$('#q').oninput=list;

/* ---------- เข้า/ออกระบบ ---------- */
async function enter(){
 $('#lg').classList.add('hide');$('#ap').classList.remove('hide');window.scrollTo(0,0);
 try{await load()}catch(e){if(T)toast(e.message,'er')}
 clearInterval(TM);TM=setInterval(()=>{if(T&&!document.hidden)load().catch(()=>{})},20000)}
$('#eye').onclick=()=>{const p=$('#p'),s=p.type==='password';p.type=s?'text':'password';$('#eye').textContent=s?'ซ่อน':'แสดง'};
$('#lf').onsubmit=async e=>{e.preventDefault();$('#er').textContent='';const b=$('#in');
 try{const j=await bz(b,()=>api('login',{username:$('#u').value,password:$('#p').value}));T=j.token;sessionStorage.setItem('t',T);$('#p').value='';enter()}
 catch(er){$('#er').textContent=er.message;const f=$('#lf');f.classList.remove('shk');void f.offsetWidth;f.classList.add('shk');$('#p').select()}};
$('#out').onclick=()=>{lo();toast('ออกจากระบบแล้ว')};
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
