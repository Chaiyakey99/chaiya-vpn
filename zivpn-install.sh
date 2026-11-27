#!/bin/bash
# ZiVPN UDP + แผงควบคุม (Control Panel) - ติดตั้งครั้งเดียวจบ ไม่ถามอะไร
# ใช้: sudo bash zivpn-install.sh      (รันซ้ำได้ ข้อมูลยูสเดิมไม่หาย)
set -e
export DEBIAN_FRONTEND=noninteractive
[ "$(id -u)" = "0" ] || { echo "ต้องรันด้วย root: sudo bash $0"; exit 1; }
[ "$(uname -m)" = "x86_64" ] || { echo "รองรับเฉพาะ x86_64 (amd64) เท่านั้น"; exit 1; }
P=/opt/zivpn-panel
DOMAIN=$(printf "%s" "${DOMAIN:-}" | tr -cd 'A-Za-z0-9.-')   # ตัวเลือก: sudo DOMAIN=vpn.example.com bash zivpn-install.sh
BIN_URL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64"

echo "[1/7] ติดตั้งแพ็กเกจที่จำเป็น"
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y python3 python3-flask python3-waitress conntrack iptables curl wget openssl ca-certificates >/dev/null

echo "[2/7] ติดตั้ง zivpn"
systemctl stop zivpn 2>/dev/null || true
if [ ! -x /usr/local/bin/zivpn ]; then
  wget -q -O /usr/local/bin/zivpn.tmp "$BIN_URL" || { echo "ดาวน์โหลด zivpn ไม่สำเร็จ (ตรวจอินเทอร์เน็ตของเซิร์ฟเวอร์)"; rm -f /usr/local/bin/zivpn.tmp; exit 1; }
  [ "$(stat -c %s /usr/local/bin/zivpn.tmp)" -gt 1000000 ] || { echo "ไฟล์ zivpn ที่โหลดมาผิดปกติ"; rm -f /usr/local/bin/zivpn.tmp; exit 1; }
  mv -f /usr/local/bin/zivpn.tmp /usr/local/bin/zivpn
  chmod +x /usr/local/bin/zivpn
fi
mkdir -p /etc/zivpn
if [ ! -f /etc/zivpn/zivpn.crt ] || [ ! -f /etc/zivpn/zivpn.key ]; then
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=zivpn" -keyout /etc/zivpn/zivpn.key -out /etc/zivpn/zivpn.crt >/dev/null 2>&1
fi
modprobe nf_conntrack 2>/dev/null || true
cat > /etc/sysctl.d/99-zivpn.conf <<'EOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.netfilter.nf_conntrack_acct=1
EOF
sysctl -p /etc/sysctl.d/99-zivpn.conf >/dev/null 2>&1 || true

# รหัสผ่านเริ่มต้นของ zivpn ตายตัวเป็น admin (ไม่ถามตอนติดตั้ง)
cat > /etc/zivpn/config.json <<'EOF'
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "auth": {
    "mode": "passwords",
    "config": ["admin"]
  }
}
EOF
cat > /etc/systemd/system/zivpn.service <<'EOF'
[Unit]
Description=zivpn VPN Server
After=network.target zivpn-fw.service zivpn-panel.service

[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

echo "[3/7] ตั้งค่าไฟร์วอลล์ (UDP 6000-19999 -> 5667)"
cat > /usr/local/sbin/zivpn-fw.sh <<'EOF'
#!/bin/bash
IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
R="-p udp --dport 6000:19999 -j DNAT --to-destination :5667"
iptables -t nat -C PREROUTING -i "$IF" $R 2>/dev/null || iptables -t nat -A PREROUTING -i "$IF" $R
EOF
chmod +x /usr/local/sbin/zivpn-fw.sh
cat > /etc/systemd/system/zivpn-fw.service <<'EOF'
[Unit]
Description=zivpn NAT rule
After=network-online.target
Wants=network-online.target
Before=zivpn.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zivpn-fw.sh

[Install]
WantedBy=multi-user.target
EOF
if command -v ufw >/dev/null 2>&1; then
  ufw allow 6000:19999/udp >/dev/null 2>&1 || true
  ufw allow 5667/udp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ufw allow 8088/tcp >/dev/null 2>&1 || true
fi
systemctl daemon-reload
systemctl enable --now zivpn-fw >/dev/null 2>&1
systemctl enable zivpn >/dev/null 2>&1
systemctl restart zivpn
sleep 2
systemctl is-active --quiet zivpn || { echo "zivpn ไม่ขึ้น:"; journalctl -u zivpn -n 8 --no-pager; exit 1; }

echo "[4/7] ติดตั้งแผงควบคุม"
mkdir -p "$P/backup"
cd "$P"
if [ ! -f secret ]; then head -c 32 /dev/urandom | base64 -w0 > secret; fi
chmod 600 secret
if [ -f app.py ]; then cp -f app.py app.py.prev; fi
if [ -f panel.db ]; then cp -f panel.db panel.db.pre-install; fi
cat > app.py.new <<'PYEOF'
import os, re, sys, csv, io, json, time, glob, html, shutil, sqlite3, secrets, threading, subprocess, traceback
from contextlib import closing
from datetime import datetime, timedelta, timezone
from flask import Flask, request, redirect, session, jsonify, Response, send_file, abort
from werkzeug.security import generate_password_hash, check_password_hash

D = '/opt/zivpn-panel'; DB = D + '/panel.db'; CFG = '/etc/zivpn/config.json'; FMT = '%Y-%m-%d %H:%M'
GB = 1024 ** 3; SESS_TTL = 40; KICK_SECS = 120; POLL = 3
app = Flask(__name__)
auth_app = Flask('auth')
app.secret_key = open(D + '/secret').read().strip()
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE='Lax',
                  PERMANENT_SESSION_LIFETIME=timedelta(days=7), MAX_CONTENT_LENGTH=2 * 1024 * 1024)
lock = threading.RLock(); fails = {}; G = {'cpu': 0.0, 'rx': 0.0, 'tx': 0.0}
FL = {}; KICKED = {}; BASE = {'ok': False}; RS = {'t': 0}

def db():
    c = sqlite3.connect(DB, timeout=10); c.row_factory = sqlite3.Row; return c

def init():
    with closing(db()) as c:
        c.execute("create table if not exists users(id integer primary key, name text unique, pw text unique, exp text default '', enabled int default 1)")
        for col, ddl in (('note', "text default ''"), ('created', "text default ''"), ('quota', 'integer default 0'),
                         ('used', 'integer default 0'), ('devs', 'integer default 0')):
            try: c.execute('alter table users add column %s %s' % (col, ddl))
            except sqlite3.OperationalError: pass
        c.execute("create table if not exists kv(k text primary key, v text)")
        c.execute("create table if not exists samples(ts integer primary key, online int, cpu real, rx real, tx real)")
        c.execute("create table if not exists audit(id integer primary key, ts text, actor text, action text, detail text)")
        c.execute("create table if not exists sess(uid integer, ip text, first integer, last integer, primary key(uid, ip))")
        c.commit()

def kget(k, d=''):
    with closing(db()) as c:
        r = c.execute('select v from kv where k=?', (k,)).fetchone()
    return r['v'] if r else d

def kset(k, v):
    with closing(db()) as c:
        c.execute('insert or replace into kv values(?,?)', (k, str(v))); c.commit()

def now():
    try: h = float(kget('tz', '7'))
    except ValueError: h = 7
    return datetime.now(timezone(timedelta(hours=h))).replace(tzinfo=None)

def nows(): return now().strftime(FMT)

def audit(action, detail=''):
    with closing(db()) as c:
        c.execute('insert into audit(ts,actor,action,detail) values(?,?,?,?)', (nows(), 'admin', action, detail))
        c.execute('delete from audit where id <= (select max(id) from audit) - 500'); c.commit()

def elog():
    try: open(D + '/err.log', 'a').write(time.strftime('%F %T ') + traceback.format_exc()[-600:] + '\n')
    except Exception: pass

def clean(s, n=32): return re.sub(r'[^A-Za-z0-9_.#!-]', '', s or '')[:n]

def qparse(v):
    try: return max(0, int(float(v or 0) * GB))
    except (ValueError, TypeError): return 0

def dparse(v):
    try: return max(0, min(100, int(v or 0)))
    except (ValueError, TypeError): return 0

def fexp(v):
    v = (v or '').strip().replace('T', ' ')
    if not v: return ''
    try: return datetime.strptime(v[:16], FMT).strftime(FMT)
    except ValueError: raise ValueError('รูปแบบวันหมดอายุไม่ถูกต้อง')

def renew_exp(exp, d):
    base = now()
    if exp: base = max(base, datetime.strptime(exp, FMT))
    return (base + timedelta(days=d)).strftime(FMT)

def status_of(r, n):
    if not r['enabled']: return 'off'
    if r['exp'] and r['exp'] <= n: return 'exp'
    if r['quota'] and (r['used'] or 0) >= r['quota']: return 'full'
    return 'on'

def is_active(r, n): return status_of(r, n) == 'on'

def oc_map(c):
    t = int(time.time())
    return {r['uid']: r['n'] for r in c.execute('select uid, count(*) n from sess where last>? group by uid', (t - SESS_TTL,))}

def urow(r, n, warn, oc=0):
    left = None
    if r['exp']: left = (datetime.strptime(r['exp'], FMT) - now()).total_seconds() / 86400
    st = status_of(r, n)
    return dict(id=r['id'], name=r['name'], pw=r['pw'], exp=r['exp'], enabled=bool(r['enabled']),
                note=r['note'] or '', created=r['created'] or '', quota=r['quota'] or 0, used=r['used'] or 0,
                devs=r['devs'] or 0, oc=oc, status=st, left=None if left is None else round(left, 2),
                soon=bool(st == 'on' and left is not None and left <= warn))

def sh(*a):
    return subprocess.run(list(a), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def init_fw():
    sh('iptables', '-N', 'ZIKICK'); sh('iptables', '-F', 'ZIKICK')
    if subprocess.run(['iptables', '-C', 'INPUT', '-j', 'ZIKICK'], capture_output=True).returncode != 0:
        sh('iptables', '-I', 'INPUT', '1', '-j', 'ZIKICK')
    sh('sysctl', '-w', 'net.netfilter.nf_conntrack_acct=1')

CT = re.compile(r'src=(\S+) dst=\S+ sport=(\d+) dport=(\d+)(?: packets=\d+ bytes=(\d+))?.*?src=\S+ dst=\S+ sport=(\d+) dport=\d+(?: packets=\d+ bytes=(\d+))?')

def ct_flows():
    try: out = subprocess.run(['conntrack', '-L', '-p', 'udp'], capture_output=True, text=True, timeout=15).stdout
    except Exception: return None
    res = []
    for l in out.splitlines():
        m = CT.search(l)
        if not m or m.group(5) != '5667': continue
        res.append(((m.group(1), m.group(2), m.group(3)), int(m.group(4) or 0) + int(m.group(6) or 0)))
    return res

def poll():
    global FL
    flows = ct_flows()
    if flows is None: return
    t = int(time.time()); new = {}; ipd = {}; ips = set()
    for key, b in flows:
        prev = FL.get(key)
        if not BASE['ok']: d = 0
        elif prev is None: d = b
        elif b >= prev: d = b - prev
        else: d = b
        new[key] = b; ips.add(key[0]); ipd[key[0]] = ipd.get(key[0], 0) + d
    FL = new; BASE['ok'] = True
    with closing(db()) as c:
        m = {r['ip']: r['uid'] for r in c.execute('select ip, uid, max(last) from sess group by ip')}
        for ip, d in ipd.items():
            uid = m.get(ip)
            if uid is None or d <= 0: continue
            c.execute('update sess set last=? where uid=? and ip=?', (t, uid, ip))
            c.execute('update users set used=used+? where id=?', (d, uid))
        c.execute('delete from sess where last<?', (t - 86400,))
        c.commit()

def restart_zivpn():
    if time.time() - RS['t'] < 60: return
    RS['t'] = time.time(); sh('systemctl', 'restart', 'zivpn')

def kick(ip, why, uid):
    with lock:
        if ip in KICKED: return
        t = int(time.time()); n = nows(); shared = False
        with closing(db()) as c:
            for o in c.execute('select s.uid from sess s where s.ip=? and s.last>? and s.uid!=?', (ip, t - SESS_TTL, uid)).fetchall():
                r = c.execute('select * from users where id=?', (o['uid'],)).fetchone()
                if r and is_active(r, n): shared = True
        if shared:
            KICKED[ip] = (time.time() + KICK_SECS, False); restart_zivpn()
        else:
            sh('iptables', '-I', 'ZIKICK', '-s', ip, '-p', 'udp', '-j', 'DROP')
            sh('conntrack', '-D', '-s', ip, '-p', 'udp')
            KICKED[ip] = (time.time() + KICK_SECS, True)
        audit('kick', '%s %s%s' % (ip, why, ' (shared-ip restart)' if shared else ''))

def unkick():
    with lock:
        for ip, (exp, ruled) in list(KICKED.items()):
            if time.time() > exp:
                if ruled: sh('iptables', '-D', 'ZIKICK', '-s', ip, '-p', 'udp', '-j', 'DROP')
                KICKED.pop(ip, None)

def enforce():
    n = nows(); t = int(time.time())
    with closing(db()) as c:
        users = {r['id']: r for r in c.execute('select * from users').fetchall()}
        sess = c.execute('select uid, ip, first from sess where last>?', (t - SESS_TTL,)).fetchall()
    byu = {}
    for s in sess: byu.setdefault(s['uid'], []).append(s)
    for uid, rows in byu.items():
        r = users.get(uid)
        if r is None or not is_active(r, n):
            for s in rows: kick(s['ip'], 'inactive' if r else 'deleted', uid)
        elif r['devs'] and len(rows) > r['devs']:
            for s in sorted(rows, key=lambda x: -x['first'])[:len(rows) - r['devs']]: kick(s['ip'], 'devices', uid)

def sync():
    try: enforce()
    except Exception: elog()

def poller():
    init_fw()
    while True:
        try: poll(); enforce(); unkick()
        except Exception: elog()
        time.sleep(POLL)

@auth_app.route('/auth', methods=['POST'])
def hy_auth():
    j = request.get_json(force=True, silent=True) or {}
    addr = str(j.get('addr', '')); pw = str(j.get('auth', ''))
    ip = addr.rsplit(':', 1)[0].strip('[]'); t = int(time.time()); n = nows()
    with closing(db()) as c:
        r = c.execute('select * from users where pw=?', (pw,)).fetchone()
        if not r or not is_active(r, n): return jsonify(ok=False)
        if r['devs']:
            act = {x['ip'] for x in c.execute('select ip from sess where uid=? and last>?', (r['id'], t - SESS_TTL))}
            if ip not in act and len(act) >= r['devs']: return jsonify(ok=False)
        c.execute('insert or replace into sess(uid,ip,first,last) values(?,?,coalesce((select first from sess where uid=? and ip=?),?),?)',
                  (r['id'], ip, r['id'], ip, t, t))
        c.commit()
    return jsonify(ok=True, id=r['name'])

def backup_db(tag=None):
    os.makedirs(D + '/backup', exist_ok=True)
    tag = tag or datetime.now().strftime('%Y%m%d-%H%M%S')
    dst = D + '/backup/db-%s.sqlite' % tag
    s = db(); d = sqlite3.connect(dst); s.backup(d); d.close(); s.close()
    for f in sorted(glob.glob(D + '/backup/db-*.sqlite'))[:-14]: os.remove(f)
    return dst

def read_cpu():
    v = list(map(int, open('/proc/stat').readline().split()[1:])); return sum(v), v[3] + v[4]

def read_net():
    rx = tx = 0
    for l in open('/proc/net/dev').readlines()[2:]:
        n, d = l.split(':', 1); n = n.strip()
        if n == 'lo' or n.startswith(('docker', 'veth', 'br-')): continue
        p = d.split(); rx += int(p[0]); tx += int(p[8])
    return rx, tx

def sampler():
    pc = read_cpu(); pn = read_net(); pt = time.time(); lastdb = ''
    while True:
        time.sleep(30)
        try:
            c = read_cpu(); n = read_net(); t = time.time()
            dt = max(t - pt, 1); dtot = c[0] - pc[0]; didle = c[1] - pc[1]
            G['cpu'] = round(100 * (dtot - didle) / dtot, 1) if dtot > 0 else 0
            G['rx'] = max(n[0] - pn[0], 0) / dt; G['tx'] = max(n[1] - pn[1], 0) / dt
            pc, pn, pt = c, n, t
            with closing(db()) as x:
                oc = x.execute('select count(distinct ip) from sess where last>?', (int(t) - SESS_TTL,)).fetchone()[0]
                x.execute('insert or replace into samples values(?,?,?,?,?)', (int(t), oc, G['cpu'], G['rx'], G['tx']))
                x.execute('delete from samples where ts<?', (int(t) - 172800,)); x.commit()
            day = datetime.now().strftime('%Y%m%d')
            if day != lastdb: backup_db(day); lastdb = day
        except Exception: elog()

def csrf():
    if 'csrf' not in session: session['csrf'] = secrets.token_hex(16)
    return session['csrf']

@app.before_request
def guard():
    p = request.path
    if p == '/login': return
    if not session.get('ok'):
        if p.startswith('/api/'): return jsonify(error='unauthorized'), 401
        return redirect('/login')
    if request.method == 'POST' and request.headers.get('X-CSRF') != session.get('csrf'):
        return jsonify(error='csrf'), 403

def J(): return request.get_json(force=True, silent=True) or {}

@app.route('/login', methods=['GET', 'POST'])
def login():
    ip = request.remote_addr or ''; err = ''
    if ip == '127.0.0.1': ip = (request.headers.get('X-Forwarded-For') or ip).split(',')[0].strip()
    f = fails.get(ip, (0, 0))
    if request.method == 'POST':
        if f[0] >= 5 and time.time() - f[1] < 300: err = 'ลองผิดหลายครั้ง กรุณารอ 5 นาที'
        else:
            h = kget('admin')
            if request.form.get('u') == 'admin' and h and check_password_hash(h, request.form.get('p', '')):
                session.clear(); session.permanent = True; session['ok'] = 1; csrf(); fails.pop(ip, None)
                return redirect('/')
            fails[ip] = (f[0] + 1 if time.time() - f[1] < 300 else 1, time.time()); err = 'ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง'
    return Response(LOGIN.replace('__ERR__', html.escape(err)).replace('__BRAND__', html.escape(kget('brand', 'ZiVPN Panel'))), mimetype='text/html')

@app.route('/logout')
def logout():
    session.clear(); return redirect('/login')

@app.route('/')
def index():
    return Response(PAGE.replace('__CSRF__', csrf()).replace('__BRAND__', html.escape(kget('brand', 'ZiVPN Panel'))), mimetype='text/html')

@app.route('/api/stats')
def stats():
    n = nows(); warn = int(float(kget('warn', '3'))); t = int(time.time())
    with closing(db()) as c:
        rows = c.execute('select * from users').fetchall()
        smp = c.execute('select * from samples order by ts desc limit 120').fetchall()[::-1]
        oc = oc_map(c)
        on_ip = c.execute('select count(distinct ip) from sess where last>?', (t - SESS_TTL,)).fetchone()[0]
        on_us = c.execute('select count(distinct uid) from sess where last>?', (t - SESS_TTL,)).fetchone()[0]
    us = [urow(r, n, warn, oc.get(r['id'], 0)) for r in rows]
    mem = {}
    for l in open('/proc/meminfo'):
        k, v = l.split(':'); mem[k] = int(v.split()[0]) * 1024
    du = shutil.disk_usage('/'); rx, tx = read_net()
    svc = subprocess.run(['systemctl', 'is-active', 'zivpn'], capture_output=True, text=True).stdout.strip()
    soon = sorted([u for u in us if u['soon']], key=lambda u: u['left'])[:8]
    return jsonify(
        counts=dict(total=len(us), active=sum(u['status'] == 'on' for u in us),
                    expired=sum(u['status'] in ('exp', 'full') for u in us),
                    disabled=sum(u['status'] == 'off' for u in us), soon=len([u for u in us if u['soon']])),
        online=on_ip, users_online=on_us, used_total=sum(u['used'] for u in us), svc=svc,
        cpu=G['cpu'], rx=G['rx'], tx=G['tx'], rx_tot=rx, tx_tot=tx,
        mem=dict(total=mem['MemTotal'], used=mem['MemTotal'] - mem['MemAvailable']),
        disk=dict(total=du.total, used=du.used), uptime=float(open('/proc/uptime').read().split()[0]),
        load=list(os.getloadavg()), soon=[dict(name=u['name'], left=u['left']) for u in soon],
        series=[dict(o=r['online'], rx=r['rx'], tx=r['tx']) for r in smp])

@app.route('/api/users', methods=['GET', 'POST'])
def users_api():
    if request.method == 'GET':
        n = nows(); warn = int(float(kget('warn', '3')))
        with closing(db()) as c:
            rows = c.execute('select * from users order by id desc').fetchall(); oc = oc_map(c)
        return jsonify(users=[urow(r, n, warn, oc.get(r['id'], 0)) for r in rows], host=kget('host', '') or request.host.split(':')[0], now=n)
    j = J(); name = clean(j.get('name')); pw = clean(j.get('pw')) or secrets.token_hex(4)
    if not name: return jsonify(error='ใส่ชื่อยูส (A-Z a-z 0-9 _ . -)'), 400
    try: days = int(j.get('days') or 0)
    except (ValueError, TypeError): days = 0
    exp = (now() + timedelta(days=days)).strftime(FMT) if days > 0 else ''
    try:
        with closing(db()) as c:
            c.execute('insert into users(name,pw,exp,note,created,quota,devs) values(?,?,?,?,?,?,?)',
                      (name, pw, exp, (j.get('note') or '')[:120], nows(), qparse(j.get('quota')), dparse(j.get('devs')))); c.commit()
    except sqlite3.IntegrityError: return jsonify(error='ชื่อหรือรหัสผ่านซ้ำ'), 409
    audit('create', name); return jsonify(ok=True)

@app.route('/api/users/bulk_create', methods=['POST'])
def bulk_create():
    j = J(); prefix = clean(j.get('prefix'), 12) or 'user'
    try: cnt = max(1, min(200, int(j.get('count') or 1)))
    except (ValueError, TypeError): cnt = 1
    try: days = int(j.get('days') or 0)
    except (ValueError, TypeError): days = 0
    exp = (now() + timedelta(days=days)).strftime(FMT) if days > 0 else ''
    q = qparse(j.get('quota')); dv = dparse(j.get('devs'))
    made = []
    with closing(db()) as c:
        k = 1
        for _ in range(cnt):
            while True:
                name = '%s%03d' % (prefix, k); k += 1
                if not c.execute('select 1 from users where name=?', (name,)).fetchone(): break
            pw = secrets.token_hex(4)
            while c.execute('select 1 from users where pw=?', (pw,)).fetchone(): pw = secrets.token_hex(4)
            c.execute('insert into users(name,pw,exp,note,created,quota,devs) values(?,?,?,?,?,?,?)',
                      (name, pw, exp, (j.get('note') or '')[:120], nows(), q, dv))
            made.append(dict(name=name, pw=pw, exp=exp))
        c.commit()
    audit('bulk-create', '%s x%d' % (prefix, len(made))); return jsonify(ok=True, made=made)

@app.route('/api/users/<int:i>', methods=['POST'])
def user_edit(i):
    j = J()
    with closing(db()) as c:
        r = c.execute('select * from users where id=?', (i,)).fetchone()
        if not r: return jsonify(error='ไม่พบยูส'), 404
        name = clean(j.get('name', r['name'])) or r['name']; pw = clean(j.get('pw', r['pw'])) or r['pw']
        try: exp = fexp(j['exp']) if 'exp' in j else r['exp']
        except ValueError as e: return jsonify(error=str(e)), 400
        note = (j.get('note', r['note']) or '')[:120]
        quota = qparse(j['quota']) if 'quota' in j else r['quota']
        devs = dparse(j['devs']) if 'devs' in j else r['devs']
        try:
            c.execute('update users set name=?,pw=?,exp=?,note=?,quota=?,devs=? where id=?', (name, pw, exp, note, quota, devs, i)); c.commit()
        except sqlite3.IntegrityError: return jsonify(error='ชื่อหรือรหัสผ่านซ้ำ'), 409
    audit('edit', name); sync(); return jsonify(ok=True)

@app.route('/api/users/<int:i>/<a>', methods=['POST'])
def user_act(i, a):
    j = J()
    with closing(db()) as c:
        r = c.execute('select * from users where id=?', (i,)).fetchone()
        if not r: return jsonify(error='ไม่พบยูส'), 404
        if a == 'del':
            c.execute('delete from users where id=?', (i,))
        elif a == 'tog': c.execute('update users set enabled=1-enabled where id=?', (i,))
        elif a == 'reset': c.execute('update users set used=0 where id=?', (i,))
        elif a == 'renew':
            try: d = int(j.get('days') or 30)
            except (ValueError, TypeError): d = 30
            c.execute('update users set exp=? where id=?', (renew_exp(r['exp'], d), i))
        else: return jsonify(error='bad action'), 400
        c.commit()
    audit(a, r['name']); sync(); return jsonify(ok=True)

@app.route('/api/bulk', methods=['POST'])
def bulk():
    j = J(); a = j.get('action')
    ids = [int(x) for x in (j.get('ids') or []) if str(x).isdigit()]
    if not ids: return jsonify(error='ไม่ได้เลือกยูส'), 400
    q = ','.join('?' * len(ids))
    with closing(db()) as c:
        if a == 'delete': c.execute('delete from users where id in (%s)' % q, ids)
        elif a in ('enable', 'disable'): c.execute('update users set enabled=? where id in (%s)' % q, [1 if a == 'enable' else 0] + ids)
        elif a == 'reset': c.execute('update users set used=0 where id in (%s)' % q, ids)
        elif a == 'renew':
            try: d = int(j.get('days') or 30)
            except (ValueError, TypeError): d = 30
            for r in c.execute('select id,exp from users where id in (%s)' % q, ids).fetchall():
                c.execute('update users set exp=? where id=?', (renew_exp(r['exp'], d), r['id']))
        else: return jsonify(error='bad action'), 400
        c.commit()
    audit('bulk-' + a, str(len(ids))); sync(); return jsonify(ok=True)

@app.route('/api/online')
def online_api():
    t = int(time.time())
    with closing(db()) as c:
        rows = c.execute('select u.name n, s.ip ip, s.last l from sess s join users u on u.id=s.uid where s.last>? order by u.name, s.last desc', (t - SESS_TTL,)).fetchall()
    g = {}
    for r in rows: g.setdefault(r['n'], []).append(dict(ip=r['ip'], ago=t - r['l']))
    return jsonify(users=[dict(name=k, list=v) for k, v in g.items()], ips=len({r['ip'] for r in rows}))

@app.route('/api/logs')
def logs_api():
    out = subprocess.run(['journalctl', '-u', 'zivpn', '-n', '200', '--no-pager', '-o', 'short-iso'], capture_output=True, text=True).stdout
    return jsonify(text=out)

@app.route('/api/audit')
def audit_api():
    with closing(db()) as c: rows = c.execute('select ts,action,detail from audit order by id desc limit 200').fetchall()
    return jsonify(list=[dict(r) for r in rows])

@app.route('/api/service/restart', methods=['POST'])
def svc_restart():
    subprocess.run(['systemctl', 'restart', 'zivpn']); time.sleep(2)
    st = subprocess.run(['systemctl', 'is-active', 'zivpn'], capture_output=True, text=True).stdout.strip()
    audit('restart', st); return jsonify(ok=st == 'active', status=st)

@app.route('/api/settings', methods=['GET', 'POST'])
def settings():
    if request.method == 'POST':
        j = J(); brand = (j.get('brand') or 'ZiVPN Panel').strip()[:40]
        host = re.sub(r'[^A-Za-z0-9.:-]', '', j.get('host') or '')[:100]
        try: warn = max(0, min(60, int(j.get('warn', 3))))
        except (ValueError, TypeError): warn = 3
        try: tzv = max(-12, min(14, float(j.get('tz', 7))))
        except (ValueError, TypeError): tzv = 7
        for k, v in (('brand', brand), ('host', host), ('warn', warn), ('tz', tzv)): kset(k, v)
        audit('settings'); return jsonify(ok=True)
    return jsonify(brand=kget('brand', 'ZiVPN Panel'), host=kget('host', ''), warn=int(float(kget('warn', '3'))), tz=float(kget('tz', '7')))

@app.route('/api/password', methods=['POST'])
def chpw():
    j = J(); h = kget('admin')
    if not h or not check_password_hash(h, j.get('cur', '')): return jsonify(error='รหัสผ่านปัจจุบันไม่ถูกต้อง'), 400
    n = j.get('new', '')
    if len(n) < 8: return jsonify(error='รหัสใหม่ต้องยาวอย่างน้อย 8 ตัวอักษร'), 400
    kset('admin', generate_password_hash(n)); audit('password'); return jsonify(ok=True)

@app.route('/api/backups', methods=['GET', 'POST'])
def backups():
    if request.method == 'POST': backup_db(); audit('backup')
    fs = sorted(glob.glob(D + '/backup/db-*.sqlite'), reverse=True)
    return jsonify(list=[dict(name=os.path.basename(f), size=os.path.getsize(f)) for f in fs])

@app.route('/backup/db/<name>')
def dl(name):
    if not re.fullmatch(r'db-[0-9-]+\.sqlite', name): abort(404)
    p = D + '/backup/' + name
    if not os.path.exists(p): abort(404)
    return send_file(p, as_attachment=True)

@app.route('/backup/users.json')
def exp_json():
    with closing(db()) as c: rows = c.execute('select name,pw,exp,enabled,note,quota,devs from users order by id').fetchall()
    return Response(json.dumps({'users': [dict(r) for r in rows]}, ensure_ascii=False, indent=1), mimetype='application/json',
                    headers={'Content-Disposition': 'attachment; filename=zivpn-users.json'})

@app.route('/backup/users.csv')
def exp_csv():
    with closing(db()) as c: rows = c.execute('select name,pw,exp,enabled,note,quota,devs from users order by id').fetchall()
    o = io.StringIO(); w = csv.writer(o); w.writerow(['name', 'password', 'expire', 'enabled', 'note', 'quota_bytes', 'devices'])
    sf = lambda s: ("'" + s) if s and s[0] in '=+-@' else s
    for r in rows: w.writerow([sf(r['name']), sf(r['pw']), r['exp'], r['enabled'], sf(r['note'] or ''), r['quota'], r['devs']])
    return Response('\ufeff' + o.getvalue(), mimetype='text/csv', headers={'Content-Disposition': 'attachment; filename=zivpn-users.csv'})

@app.route('/api/import', methods=['POST'])
def imp():
    j = J(); add = 0
    with closing(db()) as c:
        for u in (j.get('users') or [])[:5000]:
            try:
                name = clean(u.get('name')); pw = clean(u.get('pw'))
                if not name or not pw: continue
                c.execute('insert into users(name,pw,exp,enabled,note,created,quota,devs) values(?,?,?,?,?,?,?,?)',
                          (name, pw, fexp(u.get('exp')), 1 if u.get('enabled', True) else 0, (u.get('note') or '')[:120], nows(),
                           max(0, int(u.get('quota') or 0)), dparse(u.get('devs')))); add += 1
            except (sqlite3.IntegrityError, ValueError, AttributeError, TypeError): continue
        c.commit()
    audit('import', str(add)); return jsonify(ok=True, added=add)

LOGIN = r"""<!doctype html><html lang=th><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>__BRAND__</title>
<style>*{box-sizing:border-box}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:radial-gradient(1200px 600px at 50% -10%,#16315c,#0b0f14);color:#e8eef5;font:15px/1.5 'Sarabun','Noto Sans Thai',system-ui,sans-serif;padding:20px}
.c{width:100%;max-width:380px;background:#121820;border:1px solid #232d3a;border-radius:18px;padding:28px;box-shadow:0 20px 60px #0008}
.lg{width:46px;height:46px;border-radius:14px;background:linear-gradient(135deg,#3b82f6,#22d3ee);margin-bottom:14px}
h1{margin:0 0 4px;font-size:22px}p{margin:0 0 18px;color:#8696a8}label{font-size:12px;color:#8696a8}
input{width:100%;background:#18202a;border:1px solid #232d3a;color:#e8eef5;padding:12px;border-radius:10px;font:inherit;margin:4px 0 12px}
button{width:100%;padding:12px;border:0;border-radius:10px;background:#3b82f6;color:#fff;font:inherit;font-weight:600;cursor:pointer}.e{color:#f87171;min-height:22px;margin-top:10px;font-size:13px}</style></head>
<body><form class=c method=post><div class=lg></div><h1>__BRAND__</h1><p>เข้าสู่ระบบผู้ดูแล</p>
<label>ชื่อผู้ใช้</label><input name=u value=admin autocomplete=username><label>รหัสผ่าน</label><input name=p type=password autofocus autocomplete=current-password>
<button>เข้าสู่ระบบ</button><div class=e>__ERR__</div></form></body></html>"""

PAGE = r"""<!doctype html><html lang=th data-theme=dark><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover"><title>__BRAND__</title>
<style>
:root{--bg:#0b0f14;--cd:#121820;--cd2:#18202a;--bd:#232d3a;--tx:#e8eef5;--mu:#8696a8;--ac:#3b82f6;--ok:#22c55e;--bad:#ef4444;--wn:#f59e0b;--r:14px}
[data-theme=light]{--bg:#f3f5f9;--cd:#fff;--cd2:#f3f6fa;--bd:#e2e8f0;--tx:#0f172a;--mu:#64748b}
*{box-sizing:border-box}html,body{margin:0}[hidden]{display:none!important}
body{background:var(--bg);color:var(--tx);font:14px/1.5 'Sarabun','Noto Sans Thai',system-ui,-apple-system,sans-serif;-webkit-tap-highlight-color:transparent}
.nav{position:fixed;left:0;right:0;bottom:0;z-index:20;display:flex;background:var(--cd);border-top:1px solid var(--bd);padding:6px 6px calc(6px + env(safe-area-inset-bottom))}
.nav .logo{display:none}
.nav a{flex:1;display:flex;flex-direction:column;align-items:center;gap:2px;padding:6px 2px;border-radius:10px;color:var(--mu);text-decoration:none;font-size:11px}
.nav a svg{width:22px;height:22px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.nav a.on{color:var(--ac);background:color-mix(in srgb,var(--ac) 13%,transparent)}
main{padding:14px 14px 100px;max-width:1200px;margin:0 auto}
.top{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px;padding-top:env(safe-area-inset-top)}
.top h1{font-size:20px;margin:0}.top div{display:flex;align-items:center}
.pill{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:99px;background:var(--cd);border:1px solid var(--bd);font-size:12px;color:var(--mu)}
.pill i{width:8px;height:8px;border-radius:50%;background:var(--mu)}.pill.ok i{background:var(--ok)}.pill.bad i{background:var(--bad)}
.ic{background:var(--cd);border:1px solid var(--bd);color:var(--tx);width:34px;height:34px;border-radius:10px;font-size:15px;cursor:pointer;margin-left:8px}
.card{background:var(--cd);border:1px solid var(--bd);border-radius:var(--r);padding:14px}
.grid4{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-bottom:10px}
.grid2{display:grid;grid-template-columns:1fr;gap:10px;margin-bottom:10px}
.k{color:var(--mu);font-size:12px}.v{font-size:28px;font-weight:700;line-height:1.2;margin-top:2px}
.v.ok{color:var(--ok)}.v.ac{color:var(--ac)}.v.bad{color:var(--bad)}
.h{font-weight:600;margin-bottom:8px;display:flex;justify-content:space-between;align-items:baseline}.h small{color:var(--mu);font-weight:400;font-size:12px}
.ch{position:relative;height:110px}.ch svg{width:100%;height:100%;display:block}.ch .mx{position:absolute;top:0;right:2px;font-size:11px;color:var(--mu)}
.bar{height:8px;background:var(--cd2);border-radius:9px;overflow:hidden;margin:4px 0 12px}.bar i{display:block;height:100%;width:0;background:var(--ac);border-radius:9px;transition:width .4s}
.row{display:flex;justify-content:space-between;gap:8px;font-size:13px;padding:5px 0}.row span:first-child{color:var(--mu)}
.lgd{display:flex;gap:14px;font-size:12px;color:var(--mu);margin-top:6px}.lgd b{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:5px;vertical-align:-1px}
input,select{width:100%;background:var(--cd2);border:1px solid var(--bd);color:var(--tx);padding:10px 12px;border-radius:10px;font:inherit;outline:0}
input:focus{border-color:var(--ac)}label{display:block;font-size:12px;color:var(--mu);margin:10px 0 4px}
.btn{background:var(--cd2);border:1px solid var(--bd);color:var(--tx);padding:7px 12px;border-radius:9px;font:inherit;cursor:pointer;text-decoration:none;display:inline-block}
.btn.pri{background:var(--ac);border-color:var(--ac);color:#fff}.btn.dg{color:var(--bad)}.btn:active{transform:scale(.97)}
.tools{display:flex;flex-direction:column;gap:8px;margin-bottom:10px}
.seg{display:flex;gap:6px;overflow-x:auto;padding-bottom:2px}.seg button{white-space:nowrap;background:var(--cd);border:1px solid var(--bd);color:var(--mu);padding:6px 12px;border-radius:99px;font:inherit;cursor:pointer}
.seg button.on{background:var(--ac);border-color:var(--ac);color:#fff}
#ulist{display:grid;gap:10px}
.u .ut{display:flex;align-items:center;gap:8px;margin-bottom:8px}.u .ut b{font-size:15px;word-break:break-all}
.sp{flex:1}.ck input{width:18px;height:18px;margin:0;accent-color:var(--ac)}
.bd{font-size:11px;padding:2px 9px;border-radius:99px;margin-left:4px}.bd.ok{background:#22c55e22;color:var(--ok)}.bd.bad{background:#ef444422;color:var(--bad)}.bd.mut{background:var(--cd2);color:var(--mu)}.bd.warn{background:#f59e0b22;color:var(--wn)}
.kv{display:flex;justify-content:space-between;gap:10px;font-size:13px;padding:3px 0}.kv span:first-child{color:var(--mu);flex:none}.kv span:last-child,.kv code{text-align:right;word-break:break-all}
code{font-family:ui-monospace,Menlo,Consolas,monospace;background:var(--cd2);padding:1px 7px;border-radius:6px}
.acts{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
#bulk{position:sticky;top:0;z-index:10;display:flex;flex-wrap:wrap;gap:6px;align-items:center;background:var(--cd);border:1px solid var(--ac);border-radius:12px;padding:8px 10px;margin-bottom:10px}
.fab{position:fixed;right:16px;bottom:calc(78px + env(safe-area-inset-bottom));width:54px;height:54px;border-radius:50%;border:0;background:var(--ac);color:#fff;font-size:28px;box-shadow:0 8px 24px #3b82f666;cursor:pointer;z-index:15}
#ov{position:fixed;inset:0;background:#000a;display:none;align-items:flex-end;justify-content:center;z-index:50}#ov.on{display:flex}
.md{background:var(--cd);width:100%;max-width:480px;border-radius:18px 18px 0 0;padding:18px;max-height:92vh;overflow:auto;border:1px solid var(--bd)}.md h3{margin:0 0 6px}
.gp{display:flex;gap:6px}.gp .btn{flex:none}.chips{display:flex;gap:6px;flex-wrap:wrap;margin-top:6px}.two{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.md .acts{justify-content:flex-end;margin-top:16px}.md textarea{width:100%;height:150px;background:var(--cd2);color:var(--tx);border:1px solid var(--bd);border-radius:10px;padding:10px;font:12px ui-monospace,monospace}
#toast{position:fixed;left:50%;top:14px;transform:translate(-50%,-80px);background:#16a34a;color:#fff;padding:10px 18px;border-radius:12px;z-index:60;transition:transform .25s;max-width:90vw;font-size:13px}
#toast.on{transform:translate(-50%,0)}#toast.er{background:#dc2626}
pre{margin:0;white-space:pre-wrap;word-break:break-all;font:11.5px/1.5 ui-monospace,Menlo,monospace;max-height:62vh;overflow:auto;background:var(--cd2);padding:10px;border-radius:10px}
table{width:100%;border-collapse:collapse;font-size:13px}td,th{padding:7px 6px;border-bottom:1px solid var(--bd);text-align:left;vertical-align:top}th{color:var(--mu);font-weight:500}
.sec{margin-bottom:10px}.sec h2{font-size:15px;margin:0 0 6px}.mu{color:var(--mu);font-size:12px}
.og{padding:8px 0;border-bottom:1px solid var(--bd)}.og:last-child{border-bottom:0}
@media(min-width:900px){
.nav{top:0;bottom:auto;right:auto;width:224px;flex-direction:column;border-top:0;border-right:1px solid var(--bd);padding:18px 12px}
.nav .logo{display:flex;align-items:center;gap:10px;font-size:16px;font-weight:700;padding:6px 10px 20px}.nav .logo i{width:30px;height:30px;border-radius:9px;background:linear-gradient(135deg,#3b82f6,#22d3ee)}
.nav a{flex:none;flex-direction:row;gap:10px;padding:10px 12px;font-size:14px}
main{margin:0 0 0 224px;max-width:none;padding:22px 28px 40px}.grid4{grid-template-columns:repeat(4,1fr)}.grid2{grid-template-columns:1fr 1fr}
.tools{flex-direction:row;align-items:center}.tools input{max-width:340px}#ulist{grid-template-columns:1fr 1fr}.fab{bottom:24px;right:28px}
#ov{align-items:center}.md{border-radius:18px}}
</style></head><body>
<nav class=nav><div class=logo><i></i>__BRAND__</div>
<a href=#dash data-p=dash><svg viewBox="0 0 24 24"><rect x=3 y=3 width=7 height=9 rx=1.5 /><rect x=14 y=3 width=7 height=5 rx=1.5 /><rect x=14 y=12 width=7 height=9 rx=1.5 /><rect x=3 y=16 width=7 height=5 rx=1.5 /></svg><span>แดชบอร์ด</span></a>
<a href=#users data-p=users><svg viewBox="0 0 24 24"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx=9 cy=7 r=4 /><path d="M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75"/></svg><span>ยูส</span></a>
<a href=#online data-p=online><svg viewBox="0 0 24 24"><path d="M5 12.55a11 11 0 0 1 14.08 0M1.42 9a16 16 0 0 1 21.16 0M8.53 16.11a6 6 0 0 1 6.95 0"/><circle cx=12 cy=20 r=1 /></svg><span>ออนไลน์</span></a>
<a href=#logs data-p=logs><svg viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h10"/></svg><span>บันทึก</span></a>
<a href=#settings data-p=settings><svg viewBox="0 0 24 24"><path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/></svg><span>ตั้งค่า</span></a></nav>
<main>
<header class=top><h1 id=ttl></h1><div><span id=svc class=pill><i></i>zivpn</span><button class=ic id=th title=ธีม>◐</button></div></header>

<section id=p-dash>
<div class=grid4>
<div class=card><div class=k>ยูสทั้งหมด</div><div class=v id=s-total>–</div></div>
<div class=card><div class=k>ใช้งานได้</div><div class="v ok" id=s-act>–</div></div>
<div class=card><div class=k>หมดอายุ·โควตาหมด / ปิด</div><div class="v bad" id=s-exp>–</div></div>
<div class=card><div class=k>ออนไลน์ (เครื่อง)</div><div class="v ac" id=s-on>–</div></div></div>
<div class=grid2>
<div class=card><div class=h>เครื่องออนไลน์ <small>ย้อนหลัง ~1 ชม.</small></div><div class=ch id=ch-on></div></div>
<div class=card><div class=h>ทราฟฟิกเครือข่าย <small id=t-net></small></div><div class=ch id=ch-net></div><div class=lgd><span><b style=background:#22c55e></b>ดาวน์โหลด</span><span><b style=background:#f59e0b></b>อัปโหลด</span></div></div></div>
<div class=grid2>
<div class=card><div class=h>ทรัพยากรเซิร์ฟเวอร์ <small id=t-up></small></div>
<div class=row><span>CPU</span><span id=t-cpu></span></div><div class=bar><i id=b-cpu></i></div>
<div class=row><span>RAM</span><span id=t-ram></span></div><div class=bar><i id=b-ram></i></div>
<div class=row><span>ดิสก์</span><span id=t-dsk></span></div><div class=bar><i id=b-dsk></i></div>
<div class=row><span>Load</span><span id=t-ld></span></div><div class=row><span>ข้อมูลที่ยูสใช้รวม</span><span id=t-used></span></div><div class=row><span>ทราฟฟิกรวมตั้งแต่บูต</span><span id=t-tot></span></div></div>
<div class=card><div class=h>ใกล้หมดอายุ <small id=t-soonn></small></div><div id=soonl></div></div></div>
</section>

<section id=p-users hidden>
<div class=tools><input id=q placeholder="ค้นหา ชื่อ / รหัสผ่าน / โน้ต" autocomplete=off><div class=seg id=flt></div></div>
<div id=bulk hidden><b>เลือก <span id=bn>0</span></b><span class=sp></span>
<button class=btn data-b=renew>+30 วัน</button><button class=btn data-b=reset>รีเซ็ต GB</button><button class=btn data-b=enable>เปิด</button><button class=btn data-b=disable>ปิด</button><button class="btn dg" data-b=delete>ลบ</button><button class=btn data-b=clear>ยกเลิก</button></div>
<div id=ulist></div><button class=fab id=add>+</button>
</section>

<section id=p-online hidden><div class=card><div class=h>ผู้ใช้ที่ออนไลน์ <small id=on-n></small></div><div id=onl></div>
<p class=mu>1 IP นับเป็น 1 เครื่อง ถือว่าออนไลน์เมื่อมีทราฟฟิกในช่วง 40 วินาทีล่าสุด</p></div></section>

<section id=p-logs hidden><div class=seg style=margin-bottom:10px><button id=lt-log class=on>zivpn log</button><button id=lt-aud>ประวัติผู้ดูแล</button></div>
<div class=card><div id=logbox></div></div></section>

<section id=p-settings hidden>
<div class="card sec"><h2>ทั่วไป</h2>
<label>ชื่อพาเนล</label><input id=st-brand maxlength=40>
<label>โดเมน/IP ที่แสดงให้ลูกค้า (เว้นว่าง = ใช้ที่อยู่ปัจจุบัน)</label><input id=st-host placeholder="vpn.example.com">
<label>เตือนใกล้หมดอายุ (วัน)</label><input id=st-warn type=number min=0 max=60>
<label>เขตเวลา (ชั่วโมงจาก UTC, ไทย = 7)</label><input id=st-tz type=number step=0.5>
<div class=acts><button class="btn pri" id=st-save>บันทึก</button></div></div>
<div class="card sec"><h2>เปลี่ยนรหัสผ่านผู้ดูแล</h2>
<label>รหัสผ่านปัจจุบัน</label><input id=pw-cur type=password autocomplete=current-password>
<label>รหัสผ่านใหม่ (อย่างน้อย 8 ตัว)</label><input id=pw-new type=password autocomplete=new-password>
<div class=acts><button class="btn pri" id=pw-save>เปลี่ยนรหัส</button></div></div>
<div class="card sec"><h2>สำรอง / นำเข้าข้อมูล</h2>
<div class=acts style=margin-top:0><button class=btn id=bk-now>สำรองตอนนี้</button><a class=btn href=/backup/users.json>ส่งออก JSON</a><a class=btn href=/backup/users.csv>ส่งออก CSV</a>
<label class=btn style=margin:0>นำเข้า JSON<input id=imp type=file accept=.json hidden></label></div>
<div id=bklist style=margin-top:10px></div><p class=mu>ระบบสำรองฐานข้อมูลอัตโนมัติวันละครั้ง เก็บย้อนหลัง 14 วัน</p></div>
<div class="card sec"><h2>ระบบ</h2><p class=mu>รีสตาร์ท zivpn จะตัดการเชื่อมต่อทุกคน 2-3 วินาที แล้วไคลเอนต์จะต่อกลับเอง</p>
<div class=acts style=margin-top:0><button class="btn dg" id=svc-rs>รีสตาร์ท zivpn</button><a class=btn href=/logout>ออกจากระบบ</a></div></div>
</section>
</main>
<div id=ov></div><div id=toast></div>
<script>
const CSRF='__CSRF__',BR=document.title,$=s=>document.querySelector(s),GBN=1073741824;
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function api(p,b){const o={method:b!==undefined?'POST':'GET',headers:{'X-CSRF':CSRF,'Content-Type':'application/json'}};if(b!==undefined)o.body=JSON.stringify(b);
 const r=await fetch(p,o);let j={};try{j=await r.json()}catch(e){}if(r.status===401){location='/login';throw new Error('หมดเวลา')}if(!r.ok)throw new Error(j.error||('HTTP '+r.status));return j}
function toast(m,e){const t=$('#toast');t.textContent=m;t.className='on'+(e?' er':'');clearTimeout(toast.t);toast.t=setTimeout(()=>t.className='',2800)}
const fmtB=n=>{n=+n||0;const u=['B','KB','MB','GB','TB'];let i=0;while(n>=1024&&i<4){n/=1024;i++}return n.toFixed(i?(i>=3?2:1):0)+' '+u[i]};
const fr=n=>fmtB(n)+'/s';
const fd=s=>{s=Math.floor(s);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return (d?d+' วัน ':'')+h+' ชม. '+m+' น.'};
function copy(t){const f=t=>{const a=document.createElement('textarea');a.value=t;a.style.cssText='position:fixed;opacity:0';document.body.appendChild(a);a.select();try{document.execCommand('copy');toast('คัดลอกแล้ว')}catch(e){toast('คัดลอกไม่ได้',1)}a.remove()};
 if(navigator.clipboard&&window.isSecureContext)navigator.clipboard.writeText(t).then(()=>toast('คัดลอกแล้ว'),()=>f(t));else f(t)}
function openM(h){const o=$('#ov');o.innerHTML='<div class=md>'+h+'</div>';o.classList.add('on')}
function closeM(){const o=$('#ov');o.classList.remove('on');o.innerHTML=''}
$('#ov').addEventListener('click',e=>{if(e.target.id==='ov')closeM()});
try{document.documentElement.dataset.theme=localStorage.getItem('th')||'dark'}catch(e){}
$('#th').onclick=()=>{const n=document.documentElement.dataset.theme==='dark'?'light':'dark';document.documentElement.dataset.theme=n;try{localStorage.setItem('th',n)}catch(e){}};
function chart(sel,series,fmt){const W=300,H=100,P=4,el=$(sel);const mx=Math.max(1,...series.flatMap(s=>s.v));
 const paths=series.map(s=>{const n=s.v.length;if(n<2)return'';const pts=s.v.map((y,i)=>[P+i*(W-2*P)/(n-1),H-P-(y/mx)*(H-2*P)]);
 const d='M'+pts.map(p=>p[0].toFixed(1)+','+p[1].toFixed(1)).join('L');
 return '<path d="'+d+'" fill="none" stroke="'+s.c+'" stroke-width="1.8" vector-effect="non-scaling-stroke"/>'+(s.fill?'<path d="'+d+'L'+(W-P)+','+(H-P)+'L'+P+','+(H-P)+'Z" fill="'+s.c+'" opacity=".15"/>':'')}).join('');
 el.innerHTML='<svg viewBox="0 0 '+W+' '+H+'" preserveAspectRatio="none">'+paths+'</svg><span class=mx>'+fmt(mx)+'</span>'}

const PAGES=['dash','users','online','logs','settings'],TITLES={dash:'แดชบอร์ด',users:'จัดการยูส',online:'ออนไลน์',logs:'บันทึก',settings:'ตั้งค่า'};
let cur='dash',U=[],HOST='',NOW='',F='all',Q='',SEL=new Set(),LT='log';
function route(){let p=(location.hash||'#dash').slice(1);if(!PAGES.includes(p))p='dash';cur=p;
 PAGES.forEach(x=>$('#p-'+x).hidden=x!==p);document.querySelectorAll('.nav a').forEach(a=>a.classList.toggle('on',a.dataset.p===p));$('#ttl').textContent=TITLES[p];load()}
async function load(){try{if(cur==='dash')await loadDash();else if(cur==='users')await loadUsers();else if(cur==='online')await loadOnline();else if(cur==='logs')await loadLogs();else await loadSettings()}catch(e){toast(e.message,1)}}
window.addEventListener('hashchange',route);
setInterval(()=>{if(!document.hidden&&(cur==='dash'||cur==='online'))load();else if(!document.hidden&&cur==='users'&&!$('#ov').classList.contains('on'))loadUsers().catch(()=>{})},5000);

async function loadDash(){const s=await api('/api/stats');
 $('#s-total').textContent=s.counts.total;$('#s-act').textContent=s.counts.active;$('#s-exp').textContent=s.counts.expired+' / '+s.counts.disabled;$('#s-on').textContent=s.online;
 const sv=$('#svc');sv.className='pill '+(s.svc==='active'?'ok':'bad');sv.innerHTML='<i></i>zivpn '+(s.svc==='active'?'ทำงาน':esc(s.svc));
 const pc=(a,b)=>Math.min(100,a/b*100);
 $('#b-cpu').style.width=s.cpu+'%';$('#t-cpu').textContent=s.cpu+'%';
 $('#b-ram').style.width=pc(s.mem.used,s.mem.total)+'%';$('#t-ram').textContent=fmtB(s.mem.used)+' / '+fmtB(s.mem.total);
 $('#b-dsk').style.width=pc(s.disk.used,s.disk.total)+'%';$('#t-dsk').textContent=fmtB(s.disk.used)+' / '+fmtB(s.disk.total);
 $('#t-ld').textContent=s.load.map(x=>x.toFixed(2)).join('  ');$('#t-up').textContent='อัปไทม์ '+fd(s.uptime);$('#t-used').textContent=fmtB(s.used_total);
 $('#t-tot').textContent='↓ '+fmtB(s.rx_tot)+'  ↑ '+fmtB(s.tx_tot);$('#t-net').textContent='↓ '+fr(s.rx)+'  ↑ '+fr(s.tx);
 chart('#ch-on',[{v:s.series.map(x=>x.o),c:'#3b82f6',fill:1}],v=>Math.round(v)+' เครื่อง');
 chart('#ch-net',[{v:s.series.map(x=>x.rx),c:'#22c55e'},{v:s.series.map(x=>x.tx),c:'#f59e0b'}],fr);
 $('#t-soonn').textContent=s.counts.soon?s.counts.soon+' ราย':'';
 $('#soonl').innerHTML=s.soon.length?s.soon.map(u=>'<div class=row><span style="color:var(--tx)">'+esc(u.name)+'</span><span>'+(u.left<1?'< 1 วัน':'เหลือ '+Math.ceil(u.left)+' วัน')+'</span></div>').join(''):'<p class=mu>ไม่มียูสที่ใกล้หมดอายุ</p>'}

function badge(u){const m={on:['ใช้งานได้','ok'],exp:['หมดอายุ','bad'],full:['โควตาหมด','bad'],off:['ปิดอยู่','mut']}[u.status];return '<span class="bd '+m[1]+'">'+m[0]+'</span>'+(u.soon?'<span class="bd warn">ใกล้หมด</span>':'')}
function leftTxt(u){if(!u.exp)return 'ไม่จำกัด';const d=u.left;if(d<0)return 'หมดแล้ว '+Math.ceil(-d)+' วัน';if(d<1)return 'เหลือ '+Math.max(1,Math.round(d*24))+' ชม.';return 'เหลือ '+Math.ceil(d)+' วัน'}
const info=u=>BR+'\nServer: '+HOST+'\nPassword: '+u.pw+'\nExpire: '+(u.exp||'ไม่จำกัด')+'\nData: '+(u.quota?fmtB(u.quota):'ไม่จำกัด')+'\nDevices: '+(u.devs||'ไม่จำกัด');
function card(u){const q=u.quota?Math.min(100,u.used/u.quota*100):0;
 return '<div class="card u" data-id="'+u.id+'"><div class=ut><label class=ck style=margin:0><input type=checkbox data-a=sel '+(SEL.has(u.id)?'checked':'')+'></label><b>'+esc(u.name)+'</b><span class=sp></span>'+badge(u)+'</div>'
 +'<div class=kv><span>รหัสผ่าน</span><code>'+esc(u.pw)+'</code></div><div class=kv><span>หมดอายุ</span><span>'+esc(u.exp||'ไม่จำกัด')+' · '+leftTxt(u)+'</span></div>'
 +'<div class=kv><span>ข้อมูล</span><span>'+fmtB(u.used)+' / '+(u.quota?fmtB(u.quota):'ไม่จำกัด')+'</span></div>'
 +(u.quota?'<div class=bar style="margin:2px 0 8px"><i style="width:'+q+'%;background:'+(q>=90?'var(--bad)':'var(--ac)')+'"></i></div>':'')
 +'<div class=kv><span>เครื่อง</span><span>'+u.oc+' / '+(u.devs||'ไม่จำกัด')+(u.oc?' · <b style=color:var(--ok)>ออนไลน์</b>':'')+'</span></div>'
 +(u.note?'<div class=kv><span>โน้ต</span><span>'+esc(u.note)+'</span></div>':'')
 +'<div class=acts><button class=btn data-a=copy>คัดลอก</button><button class=btn data-a=edit>แก้ไข</button><button class=btn data-a=renew>+30 วัน</button><button class=btn data-a=reset>รีเซ็ต GB</button><button class=btn data-a=tog>'+(u.enabled?'ปิด':'เปิด')+'</button><button class="btn dg" data-a=del>ลบ</button></div></div>'}
function filt(){const q=Q.toLowerCase();return U.filter(u=>{if(F==='on'&&u.status!=='on')return false;if(F==='exp'&&u.status!=='exp'&&u.status!=='full')return false;if(F==='off'&&u.status!=='off')return false;if(F==='soon'&&!u.soon)return false;if(F==='live'&&!u.oc)return false;return !q||(u.name+' '+u.pw+' '+u.note).toLowerCase().includes(q)})}
function renderUsers(){
 const c={all:U.length,live:U.filter(u=>u.oc).length,on:U.filter(u=>u.status==='on').length,soon:U.filter(u=>u.soon).length,exp:U.filter(u=>u.status==='exp'||u.status==='full').length,off:U.filter(u=>u.status==='off').length};
 $('#flt').innerHTML=[['all','ทั้งหมด'],['live','ออนไลน์'],['on','ใช้งานได้'],['soon','ใกล้หมด'],['exp','หมด/เต็ม'],['off','ปิดอยู่']].map(x=>'<button data-f='+x[0]+' class="'+(F===x[0]?'on':'')+'">'+x[1]+' '+c[x[0]]+'</button>').join('');
 const l=filt();$('#ulist').innerHTML=l.length?l.map(card).join(''):'<div class=card><p class=mu style=margin:0>ไม่พบยูส</p></div>';bulkbar()}
function bulkbar(){const n=SEL.size;$('#bulk').hidden=!n;$('#bn').textContent=n}
async function loadUsers(){const r=await api('/api/users');U=r.users;HOST=r.host;NOW=r.now;const ids=new Set(U.map(u=>u.id));SEL=new Set([...SEL].filter(x=>ids.has(x)));renderUsers()}
$('#q').addEventListener('input',e=>{Q=e.target.value;renderUsers()});
$('#flt').addEventListener('click',e=>{const b=e.target.closest('button[data-f]');if(b){F=b.dataset.f;renderUsers()}});
$('#ulist').addEventListener('change',e=>{if(e.target.dataset.a==='sel'){const id=+e.target.closest('.u').dataset.id;e.target.checked?SEL.add(id):SEL.delete(id);bulkbar()}});
$('#ulist').addEventListener('click',async e=>{const b=e.target.closest('button[data-a]');if(!b)return;
 const id=+b.closest('.u').dataset.id,u=U.find(x=>x.id===id),a=b.dataset.a;
 try{if(a==='copy')copy(info(u));else if(a==='edit')editU(u);
 else if(a==='del'){if(confirm('ลบยูส '+u.name+' ?')){await api('/api/users/'+id+'/del',{});toast('ลบแล้ว');await loadUsers()}}
 else if(a==='reset'){if(confirm('รีเซ็ตข้อมูลที่ใช้ของ '+u.name+' เป็น 0 ?')){await api('/api/users/'+id+'/reset',{});toast('รีเซ็ตแล้ว');await loadUsers()}}
 else{await api('/api/users/'+id+'/'+a,{days:30});toast('สำเร็จ');await loadUsers()}}catch(x){toast(x.message,1)}});
$('#bulk').addEventListener('click',async e=>{const b=e.target.closest('button[data-b]');if(!b)return;const a=b.dataset.b;if(a==='clear'){SEL.clear();renderUsers();return}
 if(a==='delete'&&!confirm('ลบ '+SEL.size+' ยูสที่เลือก ?'))return;
 try{await api('/api/bulk',{ids:[...SEL],action:a,days:30});SEL.clear();toast('สำเร็จ');await loadUsers()}catch(x){toast(x.message,1)}});
const p2=n=>String(n).padStart(2,'0');
const toLocal=d=>d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate())+'T'+p2(d.getHours())+':'+p2(d.getMinutes());
function addDays(val,d){const n=new Date(NOW.replace(' ','T'));let b=val?new Date(val):n;if(b<n)b=n;b=new Date(b);b.setDate(b.getDate()+d);return toLocal(b)}
function editU(u){openM('<h3>แก้ไข '+esc(u.name)+'</h3><label>ชื่อยูส</label><input id=e-name value="'+esc(u.name)+'" maxlength=32>'
 +'<label>รหัสผ่าน</label><div class=gp><input id=e-pw value="'+esc(u.pw)+'" maxlength=32><button class=btn type=button id=e-gen>สุ่ม</button></div>'
 +'<label>หมดอายุ (เว้นว่าง = ไม่จำกัด)</label><input id=e-exp type=datetime-local value="'+esc((u.exp||'').replace(' ','T'))+'">'
 +'<div class=chips><button class=btn data-d=7>+7 วัน</button><button class=btn data-d=30>+30 วัน</button><button class=btn data-d=90>+90 วัน</button><button class=btn data-d=0>ไม่จำกัด</button></div>'
 +'<div class=two><div><label>โควตา GB (0 = ไม่จำกัด)</label><input id=e-q type=number min=0 step=any value="'+(u.quota?+(u.quota/GBN).toFixed(2):'')+'"></div><div><label>จำนวนเครื่อง (0 = ไม่จำกัด)</label><input id=e-dv type=number min=0 max=100 value="'+(u.devs||'')+'"></div></div>'
 +'<label>โน้ต</label><input id=e-note maxlength=120 value="'+esc(u.note)+'">'
 +'<div class=acts><button class=btn id=e-x>ยกเลิก</button><button class="btn pri" id=e-ok>บันทึก</button></div>');
 $('#e-gen').onclick=()=>{$('#e-pw').value=Array.from(crypto.getRandomValues(new Uint8Array(4)),x=>p2(x.toString(16))).join('')};
 document.querySelectorAll('.chips [data-d]').forEach(b=>b.onclick=()=>{const d=+b.dataset.d;$('#e-exp').value=d?addDays($('#e-exp').value,d):''});
 $('#e-x').onclick=closeM;
 $('#e-ok').onclick=async()=>{try{await api('/api/users/'+u.id,{name:$('#e-name').value,pw:$('#e-pw').value,exp:$('#e-exp').value,note:$('#e-note').value,quota:$('#e-q').value,devs:$('#e-dv').value});closeM();toast('บันทึกแล้ว');await loadUsers()}catch(x){toast(x.message,1)}}}
$('#add').onclick=()=>{openM('<h3>สร้างยูส</h3><div class=seg style="margin:8px 0"><button id=m1 class=on>ทีละคน</button><button id=m2>หลายคน</button></div><div id=cf></div>'
 +'<div class=acts><button class=btn id=c-x>ยกเลิก</button><button class="btn pri" id=c-ok>สร้าง</button></div>');
 let mode=1;const ex='<label>จำนวนวัน (เว้นว่าง = ไม่จำกัด)</label><input id=c-days type=number min=0><div class=two><div><label>โควตา GB (เว้นว่าง = ไม่จำกัด)</label><input id=c-q type=number min=0 step=any></div><div><label>จำนวนเครื่อง (เว้นว่าง = ไม่จำกัด)</label><input id=c-dv type=number min=0 max=100></div></div><label>โน้ต</label><input id=c-note maxlength=120>';
 const form=()=>{$('#cf').innerHTML=mode===1?'<label>ชื่อยูส</label><input id=c-name maxlength=32><label>รหัสผ่าน (เว้นว่าง = สุ่ม)</label><input id=c-pw maxlength=32>'+ex
 :'<label>คำนำหน้าชื่อ</label><input id=c-pre value=user maxlength=12><label>จำนวน (สูงสุด 200)</label><input id=c-cnt type=number value=10 min=1 max=200>'+ex;
 $('#m1').className=mode===1?'on':'';$('#m2').className=mode===2?'on':''};form();
 $('#m1').onclick=()=>{mode=1;form()};$('#m2').onclick=()=>{mode=2;form()};$('#c-x').onclick=closeM;
 $('#c-ok').onclick=async()=>{try{const ob={days:$('#c-days').value,quota:$('#c-q').value,devs:$('#c-dv').value,note:$('#c-note').value};
 if(mode===1){await api('/api/users',Object.assign({name:$('#c-name').value,pw:$('#c-pw').value},ob));closeM();toast('สร้างแล้ว')}
 else{const r=await api('/api/users/bulk_create',Object.assign({prefix:$('#c-pre').value,count:$('#c-cnt').value},ob));
  const t=r.made.map(m=>m.name+'  '+m.pw).join('\n');openM('<h3>สร้าง '+r.made.length+' ยูสแล้ว</h3><p class=mu>Server: '+esc(HOST)+'<br>รูปแบบ: ชื่อ  รหัสผ่าน</p><textarea readonly id=bt>'+esc(t)+'</textarea><div class=acts><button class=btn id=b-cp>คัดลอก</button><button class="btn pri" id=b-ok>ปิด</button></div>');
  $('#b-cp').onclick=()=>copy(t);$('#b-ok').onclick=closeM}
 await loadUsers()}catch(x){toast(x.message,1)}}};

async function loadOnline(){const r=await api('/api/online');$('#on-n').textContent=r.ips+' เครื่อง · '+r.users.length+' ยูส';
 $('#onl').innerHTML=r.users.length?r.users.map(u=>'<div class=og><b>'+esc(u.name)+'</b> <span class="bd ok">'+u.list.length+' เครื่อง</span>'+u.list.map(x=>'<div class=kv><code>'+esc(x.ip)+'</code><span>'+(x.ago<6?'ตอนนี้':x.ago+' วิที่แล้ว')+'</span></div>').join('')+'</div>').join(''):'<p class=mu>ไม่มีผู้เชื่อมต่อ</p>'}
async function loadLogs(){$('#lt-log').className=LT==='log'?'on':'';$('#lt-aud').className=LT==='aud'?'on':'';
 if(LT==='log'){const r=await api('/api/logs');$('#logbox').innerHTML='<pre id=pre></pre>';$('#pre').textContent=r.text||'(ไม่มี log)';$('#pre').scrollTop=1e9}
 else{const r=await api('/api/audit');$('#logbox').innerHTML=r.list.length?'<table><tr><th>เวลา</th><th>การกระทำ</th><th>รายละเอียด</th></tr>'+r.list.map(x=>'<tr><td>'+esc(x.ts)+'</td><td>'+esc(x.action)+'</td><td>'+esc(x.detail)+'</td></tr>').join('')+'</table>':'<p class=mu>ยังไม่มีประวัติ</p>'}}
$('#lt-log').onclick=()=>{LT='log';load()};$('#lt-aud').onclick=()=>{LT='aud';load()};
async function loadSettings(){const s=await api('/api/settings');$('#st-brand').value=s.brand;$('#st-host').value=s.host;$('#st-warn').value=s.warn;$('#st-tz').value=s.tz;
 const b=await api('/api/backups');$('#bklist').innerHTML=b.list.length?b.list.map(x=>'<div class=row><a href="/backup/db/'+esc(x.name)+'" style=color:var(--ac)>'+esc(x.name)+'</a><span>'+fmtB(x.size)+'</span></div>').join(''):'<p class=mu>ยังไม่มีไฟล์สำรอง</p>'}
$('#st-save').onclick=async()=>{try{await api('/api/settings',{brand:$('#st-brand').value,host:$('#st-host').value,warn:$('#st-warn').value,tz:$('#st-tz').value});toast('บันทึกแล้ว (ชื่อพาเนลมีผลเมื่อรีเฟรช)')}catch(x){toast(x.message,1)}};
$('#pw-save').onclick=async()=>{try{await api('/api/password',{cur:$('#pw-cur').value,new:$('#pw-new').value});$('#pw-cur').value=$('#pw-new').value='';toast('เปลี่ยนรหัสผ่านแล้ว')}catch(x){toast(x.message,1)}};
$('#bk-now').onclick=async()=>{try{await api('/api/backups',{});toast('สำรองแล้ว');loadSettings()}catch(x){toast(x.message,1)}};
$('#svc-rs').onclick=async()=>{if(!confirm('รีสตาร์ท zivpn ?'))return;try{const r=await api('/api/service/restart',{});toast(r.ok?'รีสตาร์ทสำเร็จ':'สถานะ: '+r.status,!r.ok)}catch(x){toast(x.message,1)}};
$('#imp').onchange=async e=>{const f=e.target.files[0];if(!f)return;try{const r=await api('/api/import',JSON.parse(await f.text()));toast('นำเข้า '+r.added+' รายการ')}catch(x){toast(x.message,1)}e.target.value=''};
route();
</script></body></html>"""

def run_auth():
    try:
        from waitress import serve
        serve(auth_app, host='127.0.0.1', port=8080, threads=8)
    except ImportError:
        auth_app.run(host='127.0.0.1', port=8080, threaded=True)

if __name__ == '__main__':
    init()
    if len(sys.argv) > 2 and sys.argv[1] == 'setpw':
        kset('admin', generate_password_hash(sys.argv[2])); sys.exit()
    threading.Thread(target=run_auth, daemon=True).start()
    threading.Thread(target=sampler, daemon=True).start()
    threading.Thread(target=poller, daemon=True).start()
    try:
        from waitress import serve
        serve(app, host=os.environ.get('PANEL_HOST', '0.0.0.0'), port=8088, threads=4)
    except ImportError:
        app.run(host=os.environ.get('PANEL_HOST', '0.0.0.0'), port=8088)
PYEOF
if ! python3 -m py_compile app.py.new; then
  rm -f app.py.new
  echo "โค้ดพาเนลคอมไพล์ไม่ผ่าน - ยกเลิก (zivpn ยังใช้งานได้ด้วยรหัส admin)"
  exit 1
fi
mv -f app.py.new app.py

# รหัสผ่านแอดมินของพาเนล: สุ่มให้ครั้งแรกเท่านั้น (รันซ้ำจะไม่เปลี่ยน)
HAS=$(python3 - <<'EOF'
import sqlite3
try:
    c = sqlite3.connect('/opt/zivpn-panel/panel.db')
    print(c.execute("select count(*) from kv where k='admin'").fetchone()[0])
except Exception:
    print(0)
EOF
)
NEWPW=""
if [ "$HAS" = "0" ]; then
  NEWPW=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 12)
  python3 app.py setpw "$NEWPW"
  printf 'user: admin\npass: %s\n' "$NEWPW" > /root/zivpn-panel-login.txt
  chmod 600 /root/zivpn-panel-login.txt
fi
chmod 600 panel.db 2>/dev/null || true

echo "[5/7] เริ่มแผงควบคุมและเชื่อม zivpn"
cat > /etc/systemd/system/zivpn-panel.service <<'EOF'
[Unit]
Description=ZiVPN Panel
After=network.target

[Service]
WorkingDirectory=/opt/zivpn-panel
ExecStart=/usr/bin/python3 /opt/zivpn-panel/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
rm -f /etc/systemd/system/zivpn-panel.service.d/bind.conf
systemctl daemon-reload
systemctl enable zivpn-panel >/dev/null 2>&1
systemctl restart zivpn-panel
OKA=0
for i in $(seq 1 20); do
  if curl -s -m 2 -X POST -H 'Content-Type: application/json' -d '{"addr":"1.1.1.1:1","auth":"__probe__","tx":0}' http://127.0.0.1:8080/auth | grep -q '"ok"'; then OKA=1; break; fi
  sleep 1
done
MODE="http"
if [ "$OKA" = "1" ]; then
  python3 - <<'EOF' || MODE="passwords"
import json, subprocess, time, sys
p = '/etc/zivpn/config.json'; U = 'http://127.0.0.1:8080/auth'
base = json.load(open(p)); base.pop('auth', None)
for a in ({"type": "http", "http": {"url": U}}, {"mode": "http", "type": "http", "http": {"url": U}}):
    c = dict(base); c['auth'] = a
    json.dump(c, open(p, 'w'), indent=2)
    subprocess.run(['systemctl', 'restart', 'zivpn']); time.sleep(2)
    if subprocess.run(['systemctl', 'is-active', '--quiet', 'zivpn']).returncode == 0:
        sys.exit(0)
base['auth'] = {"mode": "passwords", "config": ["admin"]}
json.dump(base, open(p, 'w'), indent=2)
subprocess.run(['systemctl', 'restart', 'zivpn'])
sys.exit(1)
EOF
else
  MODE="passwords"
fi

echo "[6/7] ซ่อนพอร์ต 8088 (reverse proxy ที่พอร์ต 80/443)"
PROXY=0
if [ -n "$DOMAIN" ]; then PAT=':(80|443)$'; else PAT=':80$'; fi
BUSY=$(ss -ltnp 2>/dev/null | awk -v p="$PAT" '$4 ~ p && $0 !~ /caddy/' | wc -l)
if [ "$BUSY" != "0" ]; then
  echo "!! พอร์ต 80/443 ถูกโปรแกรมอื่นใช้อยู่ - ข้ามขั้นนี้ (พาเนลยังเปิดที่พอร์ต 8088)"
elif apt-get install -y caddy >/dev/null 2>&1; then
  if [ -n "$DOMAIN" ]; then SITE="$DOMAIN"; else SITE=":80"; fi
  printf '%s {\n    reverse_proxy 127.0.0.1:8088\n}\n' "$SITE" > /etc/caddy/Caddyfile
  if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy
    sleep 2
    CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: ${DOMAIN:-localhost}" http://127.0.0.1/login || true)
    case "$CODE" in 200|301|302|308) PROXY=1 ;; esac
  fi
  [ "$PROXY" = "1" ] || echo "!! reverse proxy ไม่ทำงาน - ข้ามขั้นนี้ (พาเนลยังเปิดที่พอร์ต 8088)"
else
  echo "!! ติดตั้ง caddy ไม่สำเร็จ - ข้ามขั้นนี้ (พาเนลยังเปิดที่พอร์ต 8088)"
fi
if [ "$PROXY" = "1" ]; then
  mkdir -p /etc/systemd/system/zivpn-panel.service.d
  printf '[Service]\nEnvironment=PANEL_HOST=127.0.0.1\n' > /etc/systemd/system/zivpn-panel.service.d/bind.conf
  systemctl daemon-reload
  systemctl restart zivpn-panel
  if command -v ufw >/dev/null 2>&1; then ufw delete allow 8088/tcp >/dev/null 2>&1 || true; fi
fi

echo "[7/7] ตรวจสอบระบบ"
sleep 1
IP=$(curl -s -4 -m 5 https://api.ipify.org 2>/dev/null || true)
[ -n "$IP" ] || IP=$(hostname -I | awk '{print $1}')
HTTPC=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8088/login || true)
echo "----------------------------------------"
echo "zivpn : $(systemctl is-active zivpn)"
echo "panel : $(systemctl is-active zivpn-panel)  (login page HTTP $HTTPC)  proxy: $([ "$PROXY" = "1" ] && echo เปิด || echo ปิด)"
if [ "$MODE" = "http" ]; then
  echo "auth  : ใช้ยูสจากแผงควบคุม (รหัส admin เริ่มต้นของ zivpn ถูกปิดแล้ว)"
else
  echo "!! เชื่อม auth ไม่สำเร็จ zivpn ยังใช้รหัส admin อยู่ - ส่งผลนี้ให้ผู้พัฒนาตรวจ"
fi
echo "----------------------------------------"
if [ "$PROXY" = "1" ]; then
  if [ -n "$DOMAIN" ]; then URL="https://$DOMAIN"; else URL="http://$IP"; fi
else
  URL="http://$IP:8088"
fi
echo "เปิดแผงควบคุม: $URL"
echo "ผู้ใช้        : admin"
if [ -n "$NEWPW" ]; then
  echo "รหัสผ่าน      : $NEWPW   (บันทึกไว้ที่ /root/zivpn-panel-login.txt)"
else
  echo "รหัสผ่าน      : ใช้รหัสเดิม (ลืมรหัส: cd $P && python3 app.py setpw 'รหัสใหม่' && systemctl restart zivpn-panel)"
fi
