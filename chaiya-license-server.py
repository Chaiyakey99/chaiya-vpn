#!/usr/bin/env python3
"""
╔══════════════════════════════════════════════════════════════╗
║   CHAIYA LICENSE SERVER  v1.0                               ║
║   จัดการ License key สำหรับ ChaiyaProject                   ║
║   รัน: python3 chaiya-license-server.py                     ║
║   Port: 7070  (เปลี่ยนได้ใน CONFIG ด้านล่าง)               ║
╚══════════════════════════════════════════════════════════════╝
"""

# ══════════════════════════════════════════════════════════════
#  ติดตั้ง dependencies (ครั้งแรกครั้งเดียว)
#  pip3 install flask --break-system-packages
# ══════════════════════════════════════════════════════════════

import json, os, secrets, hashlib, hmac
from datetime import datetime, timedelta
from functools import wraps
from flask import Flask, request, jsonify, render_template_string, redirect, url_for, session

# ════════════ CONFIG ════════════
PORT         = 7070
DB_FILE      = "/etc/chaiya/license.json"
ADMIN_USER   = "chaiya_admin"          # เปลี่ยนได้
ADMIN_PASS   = "Ch@iya_S3cr3t_2025"   # เปลี่ยนก่อนใช้จริง!
SECRET_KEY   = secrets.token_hex(32)  # session secret
MAX_IP_BIND  = 1                       # 1 key = 1 VPS IP
# ════════════════════════════════

app = Flask(__name__)
app.secret_key = SECRET_KEY
os.makedirs(os.path.dirname(DB_FILE), exist_ok=True)

# ══════════════════════════════════════════════════════════════
#  DB helpers
# ══════════════════════════════════════════════════════════════
def load_db():
    if not os.path.exists(DB_FILE):
        return {}
    try:
        return json.load(open(DB_FILE))
    except:
        return {}

def save_db(db):
    with open(DB_FILE, 'w') as f:
        json.dump(db, f, indent=2, ensure_ascii=False)

def now_str():
    return datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")

def exp_str(days):
    return (datetime.utcnow() + timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

def is_expired(key_data):
    if not key_data.get("expiry"):
        return False
    try:
        return datetime.utcnow() > datetime.strptime(key_data["expiry"], "%Y-%m-%d %H:%M:%S")
    except:
        return False

def gen_key():
    """สร้าง key รูปแบบ CHAIYA-XXXX-XXXX-XXXX-XXXX"""
    parts = [secrets.token_hex(2).upper() for _ in range(4)]
    return "CHAIYA-" + "-".join(parts)

# ══════════════════════════════════════════════════════════════
#  Admin auth
# ══════════════════════════════════════════════════════════════
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("admin"):
            return redirect("/admin/login")
        return f(*args, **kwargs)
    return decorated

# ══════════════════════════════════════════════════════════════
#  PUBLIC API — เรียกจาก chaiya script
# ══════════════════════════════════════════════════════════════

@app.route("/api/check")
def api_check():
    """
    GET /api/check?key=CHAIYA-XXXX&ip=1.2.3.4
    ตอบกลับ: {"status":"ok","expiry":"...","plan":"..."} หรือ {"status":"error","msg":"..."}
    """
    key = request.args.get("key","").strip().upper()
    ip  = request.args.get("ip","").strip()

    if not key:
        return jsonify({"status":"error","msg":"no_key"}), 400

    db = load_db()
    if key not in db:
        return jsonify({"status":"error","msg":"invalid_key"}), 403

    kd = db[key]

    # ตรวจ disabled
    if kd.get("disabled"):
        return jsonify({"status":"error","msg":"key_disabled"}), 403

    # ตรวจหมดอายุ
    if is_expired(kd):
        return jsonify({"status":"error","msg":"key_expired","expiry":kd.get("expiry")}), 403

    # IP binding — ถ้ายังไม่มี IP ผูก → ผูก IP แรกที่ใช้
    bound_ips = kd.get("bound_ips", [])
    if ip and ip not in bound_ips:
        if len(bound_ips) >= MAX_IP_BIND:
            return jsonify({
                "status": "error",
                "msg": "ip_limit",
                "detail": f"key นี้ผูกกับ IP: {', '.join(bound_ips)} แล้ว"
            }), 403
        bound_ips.append(ip)
        kd["bound_ips"] = bound_ips

    # บันทึก last seen
    kd["last_seen"] = now_str()
    kd["last_ip"]   = ip
    kd.setdefault("check_count", 0)
    kd["check_count"] += 1
    db[key] = kd
    save_db(db)

    return jsonify({
        "status":  "ok",
        "expiry":  kd.get("expiry","unlimited"),
        "plan":    kd.get("plan","standard"),
        "note":    kd.get("note",""),
        "owner":   kd.get("owner","")
    })

@app.route("/api/info")
def api_info():
    """ข้อมูล key โดยไม่ check IP binding (สำหรับแสดงใน menu)"""
    key = request.args.get("key","").strip().upper()
    if not key:
        return jsonify({"status":"error"}), 400
    db = load_db()
    kd = db.get(key,{})
    if not kd:
        return jsonify({"status":"error","msg":"invalid_key"}), 403
    return jsonify({
        "status":  "ok" if not kd.get("disabled") and not is_expired(kd) else "error",
        "expiry":  kd.get("expiry","unlimited"),
        "plan":    kd.get("plan","standard"),
        "owner":   kd.get("owner",""),
        "note":    kd.get("note",""),
        "bound_ips": kd.get("bound_ips",[])
    })

# ══════════════════════════════════════════════════════════════
#  ADMIN API (JSON) — ใช้ header X-Admin-Token
# ══════════════════════════════════════════════════════════════

def check_admin_token():
    tok = request.headers.get("X-Admin-Token","")
    return hmac.compare_digest(tok, ADMIN_PASS)

@app.route("/api/admin/keys", methods=["GET"])
def admin_list_keys():
    if not check_admin_token(): return jsonify({"error":"unauthorized"}), 401
    db = load_db()
    result = []
    for k,v in db.items():
        result.append({
            "key": k,
            "owner": v.get("owner",""),
            "plan": v.get("plan","standard"),
            "expiry": v.get("expiry","unlimited"),
            "disabled": v.get("disabled", False),
            "expired": is_expired(v),
            "bound_ips": v.get("bound_ips",[]),
            "last_seen": v.get("last_seen","never"),
            "check_count": v.get("check_count",0)
        })
    return jsonify(result)

@app.route("/api/admin/create", methods=["POST"])
def admin_create():
    if not check_admin_token(): return jsonify({"error":"unauthorized"}), 401
    data  = request.json or {}
    days  = int(data.get("days", 30))
    owner = data.get("owner","")
    plan  = data.get("plan","standard")
    note  = data.get("note","")
    key   = gen_key()
    db    = load_db()
    db[key] = {
        "owner":       owner,
        "plan":        plan,
        "note":        note,
        "created":     now_str(),
        "expiry":      exp_str(days) if days > 0 else "",
        "disabled":    False,
        "bound_ips":   [],
        "last_seen":   "never",
        "check_count": 0
    }
    save_db(db)
    return jsonify({"ok": True, "key": key, "expiry": db[key]["expiry"]})

@app.route("/api/admin/revoke", methods=["POST"])
def admin_revoke():
    if not check_admin_token(): return jsonify({"error":"unauthorized"}), 401
    key = (request.json or {}).get("key","").upper()
    db  = load_db()
    if key not in db: return jsonify({"error":"not_found"}), 404
    db[key]["disabled"] = True
    save_db(db)
    return jsonify({"ok": True})

@app.route("/api/admin/enable", methods=["POST"])
def admin_enable():
    if not check_admin_token(): return jsonify({"error":"unauthorized"}), 401
    key = (request.json or {}).get("key","").upper()
    db  = load_db()
    if key not in db: return jsonify({"error":"not_found"}), 404
    db[key]["disabled"] = False
    save_db(db)
    return jsonify({"ok": True})

@app.route("/api/admin/renew", methods=["POST"])
def admin_renew():
    if not check_admin_token(): return jsonify({"error":"unauthorized"}), 401
    data = request.json or {}
    key  = data.get("key","").upper()
    days = int(data.get("days", 30))
    db   = load_db()
    if key not in db: return jsonify({"error":"not_found"}), 404
    db[key]["expiry"]   = exp_str(days)
    db[key]["disabled"] = False
    save_db(db)
    return jsonify({"ok": True, "expiry": db[key]["expiry"]})

@app.route("/api/admin/reset_ip", methods=["POST"])
def admin_reset_ip():
    if not check_admin_token(): return jsonify({"error":"unauthorized"}), 401
    key = (request.json or {}).get("key","").upper()
    db  = load_db()
    if key not in db: return jsonify({"error":"not_found"}), 404
    db[key]["bound_ips"] = []
    save_db(db)
    return jsonify({"ok": True})

@app.route("/api/admin/delete", methods=["POST"])
def admin_delete():
    if not check_admin_token(): return jsonify({"error":"unauthorized"}), 401
    key = (request.json or {}).get("key","").upper()
    db  = load_db()
    if key not in db: return jsonify({"error":"not_found"}), 404
    del db[key]
    save_db(db)
    return jsonify({"ok": True})

# ══════════════════════════════════════════════════════════════
#  ADMIN WEB DASHBOARD
# ══════════════════════════════════════════════════════════════

ADMIN_HTML = r"""<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>CHAIYA License Manager</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Noto+Sans+Thai:wght@300;500;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#080810;--card:#0e0e1c;--border:#1e1e3a;
  --accent:#b400ff;--accent2:#00d4ff;--green:#00ff88;
  --red:#ff3060;--yellow:#ffcc00;--orange:#ff8800;
  --text:#e0e0ff;--muted:#5a5a8a;
}
body{background:var(--bg);color:var(--text);font-family:'Space Mono',monospace;min-height:100vh}
/* grid noise bg */
body::before{content:'';position:fixed;inset:0;
  background-image:repeating-linear-gradient(0deg,transparent,transparent 39px,#ffffff04 39px,#ffffff04 40px),
                   repeating-linear-gradient(90deg,transparent,transparent 39px,#ffffff04 39px,#ffffff04 40px);
  pointer-events:none;z-index:0}

.wrap{position:relative;z-index:1;max-width:1200px;margin:0 auto;padding:24px 16px}

/* header */
.header{display:flex;align-items:center;gap:16px;margin-bottom:32px;padding-bottom:20px;
        border-bottom:1px solid var(--border)}
.logo-txt{font-size:1.4rem;font-weight:700;letter-spacing:4px}
.logo-txt span{background:linear-gradient(135deg,var(--accent),var(--accent2));
               -webkit-background-clip:text;-webkit-text-fill-color:transparent}
.logo-sub{font-size:.7rem;color:var(--muted);letter-spacing:2px;margin-top:2px}
.logout-btn{margin-left:auto;padding:.4rem 1rem;background:transparent;border:1px solid var(--border);
            color:var(--muted);border-radius:6px;cursor:pointer;font-family:inherit;font-size:.75rem;
            transition:.2s}
.logout-btn:hover{border-color:var(--red);color:var(--red)}

/* stats row */
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:28px}
.stat{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:16px;text-align:center}
.stat-num{font-size:2rem;font-weight:700;line-height:1}
.stat-lbl{font-size:.65rem;color:var(--muted);letter-spacing:2px;margin-top:6px;font-family:'Noto Sans Thai',sans-serif}
.c-green{color:var(--green)} .c-red{color:var(--red)} .c-yellow{color:var(--yellow)} .c-purple{color:var(--accent)}

/* create form */
.create-card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:20px;margin-bottom:24px}
.create-card h3{font-size:.8rem;letter-spacing:3px;color:var(--accent2);margin-bottom:16px}
.form-row{display:flex;flex-wrap:wrap;gap:10px;align-items:flex-end}
.form-group{display:flex;flex-direction:column;gap:5px}
.form-group label{font-size:.65rem;color:var(--muted);letter-spacing:1px}
.form-group input,.form-group select{
  background:#13132a;border:1px solid var(--border);color:var(--text);
  padding:.5rem .75rem;border-radius:7px;font-family:inherit;font-size:.8rem;
  outline:none;transition:.2s;width:100%}
.form-group input:focus,.form-group select:focus{border-color:var(--accent)}
.fg-sm{min-width:100px} .fg-md{min-width:160px} .fg-lg{flex:1;min-width:200px}

/* buttons */
.btn{padding:.5rem 1.2rem;border-radius:7px;font-family:inherit;font-size:.78rem;
     font-weight:700;cursor:pointer;border:none;transition:.15s;letter-spacing:.5px}
.btn-purple{background:linear-gradient(135deg,var(--accent),#7700cc);color:#fff}
.btn-purple:hover{opacity:.85}
.btn-green{background:transparent;border:1px solid var(--green);color:var(--green)}
.btn-green:hover{background:var(--green);color:#000}
.btn-red{background:transparent;border:1px solid var(--red);color:var(--red)}
.btn-red:hover{background:var(--red);color:#fff}
.btn-blue{background:transparent;border:1px solid var(--accent2);color:var(--accent2)}
.btn-blue:hover{background:var(--accent2);color:#000}
.btn-yellow{background:transparent;border:1px solid var(--yellow);color:var(--yellow)}
.btn-yellow:hover{background:var(--yellow);color:#000}
.btn-sm{padding:.3rem .7rem;font-size:.7rem}

/* table */
.table-card{background:var(--card);border:1px solid var(--border);border-radius:12px;overflow:hidden}
.table-header{display:flex;align-items:center;justify-content:space-between;padding:16px 20px;
              border-bottom:1px solid var(--border)}
.table-header h3{font-size:.8rem;letter-spacing:3px;color:var(--accent2)}
.search-box{background:#13132a;border:1px solid var(--border);color:var(--text);
            padding:.4rem .75rem;border-radius:7px;font-family:inherit;font-size:.78rem;
            outline:none;width:200px}
.search-box:focus{border-color:var(--accent)}
.table-wrap{overflow-x:auto}
table{width:100%;border-collapse:collapse}
th{padding:10px 14px;font-size:.65rem;letter-spacing:2px;color:var(--muted);
   border-bottom:1px solid var(--border);text-align:left;white-space:nowrap}
td{padding:10px 14px;font-size:.75rem;border-bottom:1px solid #111128;vertical-align:middle}
tr:last-child td{border-bottom:none}
tr:hover td{background:#0f0f22}

/* badges */
.badge{padding:.2rem .6rem;border-radius:20px;font-size:.65rem;font-weight:700;letter-spacing:.5px}
.badge-ok{background:#00ff8820;color:var(--green);border:1px solid #00ff8840}
.badge-err{background:#ff306020;color:var(--red);border:1px solid #ff306040}
.badge-warn{background:#ffcc0020;color:var(--yellow);border:1px solid #ffcc0040}
.badge-purple{background:#b400ff20;color:var(--accent);border:1px solid #b400ff40}

/* key display */
.key-txt{font-family:'Space Mono',monospace;font-size:.72rem;letter-spacing:1px;
         color:var(--accent2);cursor:pointer;user-select:all}
.key-txt:hover{color:#fff}

/* action buttons row */
.act-row{display:flex;gap:5px;flex-wrap:wrap}

/* modal */
.modal-bg{display:none;position:fixed;inset:0;background:#00000088;z-index:100;
          align-items:center;justify-content:center}
.modal-bg.open{display:flex}
.modal{background:var(--card);border:1px solid var(--border);border-radius:14px;
       padding:28px;min-width:340px;max-width:480px;width:100%;position:relative}
.modal h3{font-size:.85rem;letter-spacing:3px;color:var(--accent);margin-bottom:20px}
.modal-close{position:absolute;top:14px;right:16px;background:none;border:none;
             color:var(--muted);cursor:pointer;font-size:1.1rem}
.modal .form-group{margin-bottom:12px}
.modal .form-group input{width:100%}
.modal .btn-row{display:flex;gap:8px;margin-top:20px}

/* new key result */
.new-key-box{background:#0a0a1a;border:1px solid var(--accent);border-radius:10px;
             padding:16px;margin-top:14px;display:none}
.new-key-val{font-size:1rem;font-weight:700;color:var(--green);letter-spacing:2px;
             word-break:break-all;cursor:pointer}
.new-key-val:hover{color:#fff}

/* toast */
.toast{position:fixed;bottom:24px;right:24px;padding:12px 22px;border-radius:10px;
       font-size:.8rem;font-weight:700;z-index:999;opacity:0;transition:opacity .3s;
       pointer-events:none}
.toast.show{opacity:1}
.toast-ok{background:var(--green);color:#000}
.toast-err{background:var(--red);color:#fff}

/* login page */
.login-wrap{display:flex;align-items:center;justify-content:center;min-height:100vh}
.login-card{background:var(--card);border:1px solid var(--border);border-radius:16px;
            padding:40px;width:100%;max-width:360px;text-align:center}
.login-card h2{font-size:1rem;letter-spacing:4px;color:var(--accent);margin-bottom:8px}
.login-card p{font-size:.7rem;color:var(--muted);margin-bottom:28px}
.login-card .form-group{text-align:left;margin-bottom:14px}
.login-card input{width:100%}
.login-card .btn{width:100%;padding:.7rem;font-size:.85rem}
.err-msg{color:var(--red);font-size:.75rem;margin-bottom:12px}

/* expire colors */
.exp-soon{color:var(--orange)}
.exp-ok{color:var(--green)}
.exp-dead{color:var(--red)}

@media(max-width:600px){
  .form-row{flex-direction:column}
  .fg-sm,.fg-md,.fg-lg{width:100%}
  .search-box{width:100%}
  .table-header{flex-direction:column;gap:10px;align-items:flex-start}
}
</style>
</head>
<body>
{% if not logged_in %}
<div class="login-wrap">
  <div class="login-card">
    <h2>🔐 CHAIYA</h2>
    <p>LICENSE MANAGER</p>
    {% if error %}<div class="err-msg">❌ {{ error }}</div>{% endif %}
    <form method="POST" action="/admin/login">
      <div class="form-group"><label>USERNAME</label><input name="username" type="text" autocomplete="off"></div>
      <div class="form-group"><label>PASSWORD</label><input name="password" type="password"></div>
      <button class="btn btn-purple" type="submit">เข้าสู่ระบบ</button>
    </form>
  </div>
</div>
{% else %}
<div class="wrap">
  <!-- Header -->
  <div class="header">
    <div>
      <div class="logo-txt">🔑 <span>CHAIYA</span> LICENSE</div>
      <div class="logo-sub">KEY MANAGEMENT SYSTEM v1.0</div>
    </div>
    <button class="logout-btn" onclick="location='/admin/logout'">LOGOUT</button>
  </div>

  <!-- Stats -->
  <div class="stats" id="stats-row">
    <div class="stat"><div class="stat-num c-purple" id="s-total">-</div><div class="stat-lbl">TOTAL KEYS</div></div>
    <div class="stat"><div class="stat-num c-green"  id="s-active">-</div><div class="stat-lbl">ACTIVE</div></div>
    <div class="stat"><div class="stat-num c-red"    id="s-expired">-</div><div class="stat-lbl">EXPIRED</div></div>
    <div class="stat"><div class="stat-num c-yellow" id="s-disabled">-</div><div class="stat-lbl">DISABLED</div></div>
  </div>

  <!-- Create Key -->
  <div class="create-card">
    <h3>✨ สร้าง KEY ใหม่</h3>
    <div class="form-row">
      <div class="form-group fg-md"><label>ชื่อลูกค้า / Owner</label>
        <input id="c-owner" type="text" placeholder="เช่น สมชาย VPS#1"></div>
      <div class="form-group fg-sm"><label>จำนวนวัน</label>
        <input id="c-days" type="number" value="30" min="1"></div>
      <div class="form-group fg-sm"><label>Plan</label>
        <select id="c-plan">
          <option value="standard">Standard</option>
          <option value="pro">Pro</option>
          <option value="unlimited">Unlimited</option>
        </select>
      </div>
      <div class="form-group fg-lg"><label>หมายเหตุ (ไม่บังคับ)</label>
        <input id="c-note" type="text" placeholder="เช่น ชำระผ่าน PromptPay"></div>
      <div class="form-group" style="justify-content:flex-end">
        <button class="btn btn-purple" onclick="createKey()">✨ สร้าง KEY</button>
      </div>
    </div>
    <div class="new-key-box" id="new-key-box">
      <div style="font-size:.65rem;color:var(--muted);margin-bottom:8px;letter-spacing:2px">KEY ใหม่ (คลิกเพื่อคัดลอก)</div>
      <div class="new-key-val" id="new-key-val" onclick="copyText(this.textContent)"></div>
      <div style="font-size:.65rem;color:var(--muted);margin-top:6px" id="new-key-exp"></div>
    </div>
  </div>

  <!-- Keys Table -->
  <div class="table-card">
    <div class="table-header">
      <h3>🗂️ KEYS ทั้งหมด</h3>
      <input class="search-box" id="search" placeholder="🔍 ค้นหา..." oninput="filterTable()">
    </div>
    <div class="table-wrap">
      <table id="keys-table">
        <thead>
          <tr>
            <th>KEY</th><th>OWNER</th><th>PLAN</th><th>EXPIRY</th>
            <th>STATUS</th><th>IP BOUND</th><th>LAST SEEN</th><th>CHECKS</th><th>ACTIONS</th>
          </tr>
        </thead>
        <tbody id="keys-body">
          <tr><td colspan="9" style="text-align:center;color:var(--muted);padding:2rem">กำลังโหลด...</td></tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<!-- Modal: Renew -->
<div class="modal-bg" id="modal-renew">
  <div class="modal">
    <button class="modal-close" onclick="closeModal('modal-renew')">✕</button>
    <h3>🔄 ต่ออายุ KEY</h3>
    <input type="hidden" id="renew-key">
    <div class="form-group"><label>KEY</label><input id="renew-key-show" disabled></div>
    <div class="form-group"><label>เพิ่มจากวันนี้ (วัน)</label><input id="renew-days" type="number" value="30" min="1"></div>
    <div class="btn-row">
      <button class="btn btn-green" onclick="doRenew()">✅ ต่ออายุ</button>
      <button class="btn btn-red" onclick="closeModal('modal-renew')">ยกเลิก</button>
    </div>
  </div>
</div>

<!-- Modal: Confirm delete -->
<div class="modal-bg" id="modal-del">
  <div class="modal">
    <button class="modal-close" onclick="closeModal('modal-del')">✕</button>
    <h3 style="color:var(--red)">🗑️ ยืนยันลบ KEY</h3>
    <p style="color:var(--muted);font-size:.8rem;margin-bottom:16px">KEY นี้จะถูกลบถาวร ไม่สามารถกู้คืนได้</p>
    <div class="form-group"><label>KEY</label><input id="del-key-show" disabled></div>
    <input type="hidden" id="del-key">
    <div class="btn-row">
      <button class="btn btn-red" onclick="doDelete()">🗑️ ลบเลย</button>
      <button class="btn btn-blue" onclick="closeModal('modal-del')">ยกเลิก</button>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
const ADMIN_PASS = "{{ admin_pass }}";

async function api(method, path, body=null){
  const opts={method,headers:{"Content-Type":"application/json","X-Admin-Token":ADMIN_PASS}};
  if(body) opts.body=JSON.stringify(body);
  const r = await fetch(path,opts);
  return r.json();
}

function toast(msg,ok=true){
  const el=document.getElementById("toast");
  el.textContent=msg; el.className="toast "+(ok?"toast-ok":"toast-err");
  el.classList.add("show");
  setTimeout(()=>el.classList.remove("show"),3000);
}

function copyText(t){
  navigator.clipboard?.writeText(t).then(()=>toast("📋 คัดลอกแล้ว!"));
}

function openModal(id){document.getElementById(id).classList.add("open")}
function closeModal(id){document.getElementById(id).classList.remove("open")}

function daysLeft(exp){
  if(!exp || exp==="unlimited") return Infinity;
  const d=(new Date(exp+" UTC")-new Date())/(1000*86400);
  return Math.round(d);
}

function expBadge(exp, disabled, expired_flag){
  if(disabled) return '<span class="badge badge-warn">⏸ DISABLED</span>';
  if(!exp || exp==="unlimited") return '<span class="badge badge-purple">∞ UNLIMITED</span>';
  const d=daysLeft(exp);
  if(d<0 || expired_flag) return '<span class="badge badge-err">✗ EXPIRED</span>';
  if(d<=7) return `<span class="badge badge-warn">⚠ ${d}d left</span>`;
  return `<span class="badge badge-ok">✓ ${d}d left</span>`;
}

function expColor(exp){
  if(!exp||exp==="unlimited") return "exp-ok";
  const d=daysLeft(exp);
  if(d<0) return "exp-dead";
  if(d<=7) return "exp-soon";
  return "exp-ok";
}

let allKeys=[];
async function loadKeys(){
  const data = await api("GET","/api/admin/keys");
  allKeys = data;
  // stats
  const total=data.length;
  const active=data.filter(k=>!k.disabled&&!k.expired).length;
  const expired=data.filter(k=>k.expired).length;
  const disabled=data.filter(k=>k.disabled).length;
  document.getElementById("s-total").textContent=total;
  document.getElementById("s-active").textContent=active;
  document.getElementById("s-expired").textContent=expired;
  document.getElementById("s-disabled").textContent=disabled;
  renderTable(data);
}

function renderTable(data){
  const tbody=document.getElementById("keys-body");
  if(!data.length){
    tbody.innerHTML='<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:2rem">ยังไม่มี KEY</td></tr>';
    return;
  }
  tbody.innerHTML=data.map(k=>`
    <tr>
      <td><span class="key-txt" onclick="copyText('${k.key}')" title="คลิกคัดลอก">${k.key}</span></td>
      <td>${k.owner||'<span style="color:var(--muted)">-</span>'}</td>
      <td><span class="badge badge-purple">${k.plan.toUpperCase()}</span></td>
      <td class="${expColor(k.expiry)}" style="font-size:.7rem;white-space:nowrap">${k.expiry||'∞'}</td>
      <td>${expBadge(k.expiry,k.disabled,k.expired)}</td>
      <td style="font-size:.7rem;color:var(--accent2)">${k.bound_ips.length?k.bound_ips.join('<br>'):'<span style="color:var(--muted)">ยังไม่ผูก</span>'}</td>
      <td style="font-size:.65rem;color:var(--muted);white-space:nowrap">${k.last_seen||'never'}</td>
      <td style="color:var(--muted)">${k.check_count}</td>
      <td>
        <div class="act-row">
          <button class="btn btn-yellow btn-sm" onclick="openRenew('${k.key}')">🔄</button>
          ${k.disabled
            ? `<button class="btn btn-green btn-sm" onclick="enableKey('${k.key}')">▶</button>`
            : `<button class="btn btn-red btn-sm" onclick="revokeKey('${k.key}')">⏸</button>`}
          <button class="btn btn-blue btn-sm" onclick="resetIp('${k.key}')" title="Reset IP binding">📍</button>
          <button class="btn btn-red btn-sm" onclick="openDel('${k.key}')" title="ลบถาวร">🗑️</button>
        </div>
      </td>
    </tr>`).join("");
}

function filterTable(){
  const q=document.getElementById("search").value.toLowerCase();
  const filtered=allKeys.filter(k=>
    k.key.toLowerCase().includes(q)||
    (k.owner||"").toLowerCase().includes(q)||
    (k.plan||"").toLowerCase().includes(q)||
    k.bound_ips.some(ip=>ip.includes(q))
  );
  renderTable(filtered);
}

async function createKey(){
  const owner=document.getElementById("c-owner").value.trim();
  const days=parseInt(document.getElementById("c-days").value)||30;
  const plan=document.getElementById("c-plan").value;
  const note=document.getElementById("c-note").value.trim();
  const r=await api("POST","/api/admin/create",{owner,days,plan,note});
  if(r.ok){
    document.getElementById("new-key-val").textContent=r.key;
    document.getElementById("new-key-exp").textContent="หมดอายุ: "+r.expiry+" (UTC)";
    document.getElementById("new-key-box").style.display="block";
    toast("✅ สร้าง KEY สำเร็จ!");
    loadKeys();
  } else { toast("❌ เกิดข้อผิดพลาด",false); }
}

function openRenew(key){
  document.getElementById("renew-key").value=key;
  document.getElementById("renew-key-show").value=key;
  openModal("modal-renew");
}
async function doRenew(){
  const key=document.getElementById("renew-key").value;
  const days=parseInt(document.getElementById("renew-days").value)||30;
  const r=await api("POST","/api/admin/renew",{key,days});
  if(r.ok){ toast("✅ ต่ออายุสำเร็จ! หมดอายุ: "+r.expiry); closeModal("modal-renew"); loadKeys(); }
  else { toast("❌ ล้มเหลว",false); }
}

async function revokeKey(key){
  if(!confirm("⏸ ปิดใช้งาน KEY นี้?")) return;
  const r=await api("POST","/api/admin/revoke",{key});
  r.ok ? (toast("⏸ ปิดใช้งานแล้ว",true), loadKeys()) : toast("❌ ล้มเหลว",false);
}

async function enableKey(key){
  const r=await api("POST","/api/admin/enable",{key});
  r.ok ? (toast("▶ เปิดใช้งานแล้ว"), loadKeys()) : toast("❌ ล้มเหลว",false);
}

async function resetIp(key){
  if(!confirm("📍 รีเซ็ต IP binding ของ KEY นี้?\nลูกค้าจะสามารถผูก VPS ใหม่ได้")) return;
  const r=await api("POST","/api/admin/reset_ip",{key});
  r.ok ? (toast("📍 Reset IP สำเร็จ"), loadKeys()) : toast("❌ ล้มเหลว",false);
}

function openDel(key){
  document.getElementById("del-key").value=key;
  document.getElementById("del-key-show").value=key;
  openModal("modal-del");
}
async function doDelete(){
  const key=document.getElementById("del-key").value;
  const r=await api("POST","/api/admin/delete",{key});
  if(r.ok){ toast("🗑️ ลบ KEY สำเร็จ"); closeModal("modal-del"); loadKeys(); }
  else { toast("❌ ล้มเหลว",false); }
}

// auto-refresh ทุก 30 วิ
loadKeys();
setInterval(loadKeys, 30000);
</script>
{% endif %}
</body>
</html>"""

@app.route("/admin/login", methods=["GET","POST"])
def admin_login():
    if request.method == "POST":
        u = request.form.get("username","")
        p = request.form.get("password","")
        if u == ADMIN_USER and hmac.compare_digest(p, ADMIN_PASS):
            session["admin"] = True
            return redirect("/admin")
        return render_template_string(ADMIN_HTML, logged_in=False, error="รหัสผ่านไม่ถูกต้อง", admin_pass=ADMIN_PASS)
    return render_template_string(ADMIN_HTML, logged_in=False, error=None, admin_pass=ADMIN_PASS)

@app.route("/admin/logout")
def admin_logout():
    session.clear()
    return redirect("/admin/login")

@app.route("/admin")
@login_required
def admin_dashboard():
    return render_template_string(ADMIN_HTML, logged_in=True, admin_pass=ADMIN_PASS)

@app.route("/")
def index():
    return redirect("/admin")

# ══════════════════════════════════════════════════════════════
#  Systemd service installer
# ══════════════════════════════════════════════════════════════
SYSTEMD_UNIT = f"""[Unit]
Description=Chaiya License Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 {os.path.abspath(__file__)}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "install-service":
        with open("/etc/systemd/system/chaiya-license.service","w") as f:
            f.write(SYSTEMD_UNIT)
        os.system("systemctl daemon-reload")
        os.system("systemctl enable chaiya-license")
        os.system("systemctl restart chaiya-license")
        print("✅ ติดตั้ง chaiya-license.service สำเร็จ")
        sys.exit(0)

    print(f"""
╔══════════════════════════════════════════════════╗
║  CHAIYA LICENSE SERVER กำลังเริ่มต้น...         ║
║  Dashboard : http://[IP]:{PORT}/admin            ║
║  Admin     : {ADMIN_USER}                     ║
║  Port      : {PORT}                              ║
╚══════════════════════════════════════════════════╝
""")
    app.run(host="0.0.0.0", port=PORT, debug=False)
