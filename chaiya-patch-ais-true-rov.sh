#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# chaiya-patch-ais-true-rov.sh
# รวมแพตช์: DTAC GAMING -> AIS-NOPRO/64-128K (สีเขียว)
#           AIS-กันรั่ว  -> TRUE-Rov (roglobal.com) + sync ค่า x-ui inbound 8080
#
# ใช้งาน:
#   ./chaiya-patch-ais-true-rov.sh [path-to-sshws.html] [path-to-x-ui.db]
#
# ค่า default:
#   HTML_PATH = /opt/chaiya-panel/sshws.html
#   DB_PATH   = /etc/x-ui/x-ui.db
#
# สคริปต์นี้รันซ้ำได้ (idempotent) — ถ้าแพตช์ไหนถูกใช้ไปแล้วจะข้ามอัตโนมัติ
# ══════════════════════════════════════════════════════════════════

set -e

HTML_PATH="${1:-/opt/chaiya-panel/sshws.html}"
DB_PATH="${2:-/etc/x-ui/x-ui.db}"

if [ ! -f "$HTML_PATH" ]; then
  echo "ERROR: ไม่พบไฟล์ $HTML_PATH"
  exit 1
fi

echo "== Target HTML: $HTML_PATH"
echo "== Target DB:   $DB_PATH"

cp "$HTML_PATH" "${HTML_PATH}.bak.$(date +%Y%m%d%H%M%S)"
echo "== backup HTML แล้ว"

python3 << PYEOF
path = "$HTML_PATH"
with open(path, "r", encoding="utf-8") as f:
    html = f.read()

changed = []
skipped = []

def apply(label, old, new):
    global html
    if new in html:
        skipped.append(label + " (มีอยู่แล้ว)")
        return
    if old not in html:
        skipped.append(label + " (ไม่พบ pattern เดิม - ข้าม)")
        return
    html = html.replace(old, new)
    changed.append(label)

# ── PATCH 1: DTAC GAMING -> AIS-NOPRO/64-128K ──
apply(
    "การ์ดแสดงผล DTAC->AIS-NOPRO",
    '<div class="pn">DTAC GAMING</div>\n            <div class="ps">dl.dir.freefiremobile.com</div>',
    '<div class="pn">AIS-NOPRO/64-128K</div>\n            <div class="ps">search.ais.co.th</div>'
)

apply(
    "object PROS.dtac -> AIS-NOPRO/64-128K",
    """    name: 'DTAC GAMING',
    proxy: '104.18.63.124:80',
    payload: 'POST / HTTP/1.1[crlf]Host:dl.dir.freefiremobile.com[crlf]X-Online-Host:dl.dir.freefiremobile.com[crlf]X-Forward-Host:dl.dir.freefiremobile.com[crlf]User-Agent: [ua][crlf]Connection: keep-alive[crlf][crlf][split][cr]PATCH / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf]X-Online-Host: [host][crlf][crlf]',""",
    """    name: 'AIS-NOPRO/64-128K',
    proxy: 'search.ais.co.th:80',
    payload: 'POST /cdn-cgi/speculation HTTP/1.1[crlf]Host: search.ais.co.th[crlf]User-Agent: [ua][crlf][crlf][split][cr]PATCH /ssh HTTP/1.1[crlf]Host: [host][crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]',"""
)

apply(
    "สี CSS a-dtac ส้ม -> เขียว (border/bg)",
    '.pick-opt.a-dtac{border-color:#ff6600;background:rgba(255,102,0,.1);box-shadow:0 0 10px rgba(255,102,0,.15);}',
    '.pick-opt.a-dtac{border-color:#00cc44;background:rgba(0,204,68,.1);box-shadow:0 0 10px rgba(0,204,68,.15);}'
)

apply(
    "สี CSS a-dtac ส้ม -> เขียว (text)",
    '.pick-opt.a-dtac .pn{color:#ff8833;}',
    '.pick-opt.a-dtac .pn{color:#33dd66;}'
)

apply(
    "icon 🟠 -> 🟢 สำหรับการ์ด AIS-NOPRO",
    '<div class="pi">🟠</div>\n            <div class="pn">AIS-NOPRO/64-128K</div>',
    '<div class="pi">🟢</div>\n            <div class="pn">AIS-NOPRO/64-128K</div>'
)

# ── PATCH 2: AIS – กันรั่ว -> TRUE – Rov ──
apply(
    "selector card: AIS-กันรั่ว -> TRUE-Rov",
    '<div class="sel-name ais">AIS – กันรั่ว</div>\n          <div class="sel-sub">VLESS · Port 8080 · WS · cj-ebb.speedtest.net</div>',
    '<div class="sel-name ais">TRUE – Rov</div>\n          <div class="sel-sub">VLESS · Port 8080 · WS · www.roglobal.com</div>'
)

apply(
    "form title/sub: AIS-กันรั่ว -> TRUE-Rov",
    '<div class="form-title ais">AIS – กันรั่ว</div>\n            <div class="form-sub">VLESS · Port 8080 · SNI: cj-ebb.speedtest.net</div>',
    '<div class="form-title ais">TRUE – Rov</div>\n            <div class="form-sub">VLESS · Port 8080 · SNI: www.roglobal.com</div>'
)

apply(
    "icon: AIS logo -> ROV badge",
    '<div class="sel-logo sel-ais"><img src="https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/AIS_logo.svg/200px-AIS_logo.svg.png" onerror="this.style.display=\\'none\\';this.nextSibling.style.display=\\'flex\\'" style="width:56px;height:56px;object-fit:contain"><span style="display:none;font-size:1.4rem;width:56px;height:56px;align-items:center;justify-content:center;font-weight:700;color:#3d7a0e">AIS</span></div>',
    '<div class="sel-logo sel-ais" style="background:#e30613"><span style="font-size:1rem;font-weight:900;color:#fff">ROV</span></div>'
)

apply(
    "js sni const: cj-ebb -> roglobal",
    "const sni  = carrier==='ais' ? 'cj-ebb.speedtest.net' : 'zoomvdoconnect.cloudzerovps.online';",
    "const sni  = carrier==='ais' ? 'www.roglobal.com' : 'zoomvdoconnect.cloudzerovps.online';"
)

apply(
    "js linkName/link format: ใช้ SNI connect เหมือน TRUE VDO",
    "const linkName = carrier==='ais' ? 'AIS-กันรั่ว-'+email : 'TRUE-VDO-'+email;\\n    const link = carrier==='ais' ? \`vless://\${uid}@\${HOST}:\${port}?type=ws&security=none&path=%2Fvless&host=\${sni}#\${encodeURIComponent(linkName)}\` : \`vless://\${uid}@\${sni}:\${port}?type=ws&security=none&path=%2Fvless&host=\${HOST}#\${encodeURIComponent(linkName)}\`;",
    "const linkName = carrier==='ais' ? 'TRUE-Rov-'+email : 'TRUE-VDO-'+email;\\n    const link = \`vless://\${uid}@\${sni}:\${port}?type=ws&security=none&path=%2Fvless&host=\${HOST}#\${encodeURIComponent(linkName)}\`;"
)

with open(path, "w", encoding="utf-8") as f:
    f.write(html)

print("---- เปลี่ยนแล้ว ----")
for c in changed:
    print(" [OK]", c)
print("---- ข้าม ----")
for s in skipped:
    print(" [SKIP]", s)
PYEOF

echo ""
echo "== ตรวจสอบผล HTML =="
grep -n "AIS-NOPRO\|search.ais.co.th\|TRUE – Rov\|roglobal.com" "$HTML_PATH" || true

# ── PATCH 3: x-ui inbound port 8080 -> TRUE-Rov / roglobal.com ──
if [ ! -f "$DB_PATH" ]; then
  echo "ERROR: ไม่พบ x-ui.db ที่ $DB_PATH — ข้ามส่วน x-ui"
  exit 0
fi

cp "$DB_PATH" "${DB_PATH}.bak.$(date +%Y%m%d%H%M%S)"
echo "== backup x-ui.db แล้ว"

python3 << PYEOF
import sqlite3, json

conn = sqlite3.connect("$DB_PATH")
cur = conn.cursor()

cur.execute("SELECT id, remark, stream_settings FROM inbounds WHERE port=8080")
row = cur.fetchone()

if not row:
    print("[SKIP] ไม่พบ inbound port 8080")
else:
    ib_id, remark, ss_raw = row
    ss = json.loads(ss_raw)
    host = ss.get("wsSettings", {}).get("host", "")

    if host == "www.roglobal.com":
        print("[SKIP] inbound 8080 อัปเดตแล้ว (host = www.roglobal.com)")
    else:
        ss["wsSettings"]["host"] = "www.roglobal.com"
        new_ss = json.dumps(ss, indent=2)
        cur.execute(
            "UPDATE inbounds SET remark=?, stream_settings=? WHERE id=?",
            ("TRUE-Rov", new_ss, ib_id)
        )
        conn.commit()
        print(f"[OK] inbound id {ib_id}: remark -> TRUE-Rov, host -> www.roglobal.com")

conn.close()
PYEOF

echo "== restart x-ui =="
x-ui restart

echo ""
echo "== ตรวจสอบผล x-ui =="
sqlite3 "$DB_PATH" "SELECT id, port, remark, stream_settings FROM inbounds WHERE port=8080;"

echo ""
echo "✅ เสร็จสิ้น"
