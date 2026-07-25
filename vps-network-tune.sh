#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# setup-server.sh
# รวม vps-network-tune.sh + chaiya-panel-update.sh เป็นไฟล์เดียว
# รันตามลำดับ: 1) จูนเครือข่าย  2) อัปเดต ChaiyaProject panel
#              3) แพตช์ AIS-NOPRO/TRUE-Rov (DTAC->AIS-NOPRO, AIS-กันรั่ว->TRUE-Rov)
#
# แต่ละ section รันในซับเชลล์แยกกัน — ถ้า section ไหนพัง อีก section
# ยังรันต่อได้ตามปกติ ไม่กระทบกัน (ไม่ได้ merge state/ตัวแปรร่วมกัน)
#
# ใช้งาน:
#   sudo ./setup-server.sh
#
# รันซ้ำได้ (idempotent) — ทั้งสอง section เช็คสถานะก่อนแก้ทุกจุด
# ══════════════════════════════════════════════════════════════════

set -u

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: ต้องรันด้วย root (sudo)"
  exit 1
fi

RESULTS=()

echo "╔════════════════════════════════════════╗"
echo "║  1/2  Network Tuning                    ║"
echo "╚════════════════════════════════════════╝"
if (
set -e

echo "════════════════════════════════════════"
echo "  VPS Network Tuning"
echo "════════════════════════════════════════"

# ── ตรวจจับ interface หลักอัตโนมัติ ──
IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -z "$IFACE" ]; then
  echo "ERROR: หา default network interface ไม่เจอ"
  exit 1
fi
echo "== Interface: $IFACE"

# ── ตรวจจับจำนวน CPU ──
NCPU=$(nproc)
echo "== CPU cores: $NCPU"

# คำนวณ hex mask สำหรับ RPS (ครบทุกคอร์ เช่น 4 core -> f, 8 core -> ff)
RPS_MASK=$(python3 -c "print(format((1 << $NCPU) - 1, 'x'))")
echo "== RPS CPU mask: $RPS_MASK"

# ══════════════════════════════════════════
# 1. TCP / Qdisc tuning ผ่าน sysctl
# ══════════════════════════════════════════
echo ""
echo "== [1/9] ตั้งค่า sysctl (BBR + FQ + MTU Probing + buffer + keepalive) =="

SYSCTL_FILE="/etc/sysctl.d/99-vps-network-tune.conf"
cp -f "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

cat > "$SYSCTL_FILE" << 'SYSEOF'
# vps-network-tune.sh — BBR + FQ + MTU Probing profile (v3)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 4096
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 1
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192

# ── TCP buffer เพิ่ม throughput ดึงข้อมูลผ่าน SSH/WS tunnel ──
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.tcp_rmem = 4096 4194304 67108864
net.ipv4.tcp_wmem = 4096 4194304 67108864
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# ── ลด latency ที่แฝงมาจาก buffering (สำคัญกับ ping ผ่าน tunnel) ──
net.ipv4.tcp_notsent_lowat = 131072

# ── เชื่อมต่อใหม่/ปิดถี่แบบ SSH/WS multiplex ──
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 4

# ── file descriptor / connection tracking headroom ──
fs.file-max = 2097152
net.ipv4.ip_local_port_range = 1024 65535
SYSEOF

sysctl --system > /dev/null 2>&1
echo "[OK] sysctl applied"
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_mtu_probing net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.ipv4.tcp_notsent_lowat net.ipv4.tcp_tw_reuse

# ══════════════════════════════════════════
# 2. เปลี่ยน qdisc ของ interface เป็น fq ทันที (ไม่ต้องรอรีบูต)
# ══════════════════════════════════════════
echo ""
echo "== [2/9] ตั้ง qdisc ของ $IFACE เป็น fq =="
CURRENT_QDISC=$(tc qdisc show dev "$IFACE" | head -1 | awk '{print $2}')
if [ "$CURRENT_QDISC" = "fq" ]; then
  echo "[SKIP] qdisc เป็น fq อยู่แล้ว"
else
  tc qdisc replace dev "$IFACE" root fq
  echo "[OK] เปลี่ยน qdisc เป็น fq แล้ว"
fi

# ══════════════════════════════════════════
# 3. เปิด RPS/RFS กระจายงานเครือข่ายทุกคอร์
# ══════════════════════════════════════════
echo ""
echo "== [3/9] เปิด RPS/RFS บนทุก RX queue ของ $IFACE =="

RXQ_DIR="/sys/class/net/$IFACE/queues"
if [ ! -d "$RXQ_DIR" ]; then
  echo "WARN: ไม่พบ $RXQ_DIR — ข้าม RPS/RFS"
else
  for rx in "$RXQ_DIR"/rx-*; do
    if [ -f "$rx/rps_cpus" ]; then
      echo "$RPS_MASK" > "$rx/rps_cpus"
      echo "32768" > "$rx/rps_flow_cnt" 2>/dev/null || true
      echo "[OK] $(basename "$rx"): rps_cpus=$RPS_MASK"
    fi
  done
fi

# ── สร้าง systemd service ให้ RPS/RFS ทำงานหลังรีบูต (ค่าใน /sys ไม่ persist) ──
SERVICE_FILE="/etc/systemd/system/vps-rps-tune.service"
SCRIPT_PATH="/usr/local/sbin/vps-rps-apply.sh"

cat > "$SCRIPT_PATH" << SCRIPTEOF
#!/bin/bash
IFACE="$IFACE"
RPS_MASK="$RPS_MASK"
for rx in /sys/class/net/\$IFACE/queues/rx-*; do
  [ -f "\$rx/rps_cpus" ] && echo "\$RPS_MASK" > "\$rx/rps_cpus"
  [ -f "\$rx/rps_flow_cnt" ] && echo "32768" > "\$rx/rps_flow_cnt"
done
tc qdisc replace dev "\$IFACE" root fq 2>/dev/null || true
SCRIPTEOF
chmod +x "$SCRIPT_PATH"

cat > "$SERVICE_FILE" << 'UNITEOF'
[Unit]
Description=Apply RPS/RFS and qdisc tuning after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-rps-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable vps-rps-tune.service > /dev/null 2>&1
systemctl restart vps-rps-tune.service
echo "[OK] vps-rps-tune.service ติดตั้งและ enable แล้ว (ทำงานทุกครั้งหลังรีบูต)"

# ══════════════════════════════════════════
# 4. เพิ่ม NIC ring buffer + txqueuelen ลด packet drop ตอน burst traffic
# ══════════════════════════════════════════
echo ""
echo "== [4/9] เพิ่ม ring buffer / txqueuelen ของ $IFACE =="

if command -v ethtool &>/dev/null; then
  MAX_RX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^RX:/{print $2; exit}')
  MAX_TX=$(ethtool -g "$IFACE" 2>/dev/null | awk '/^TX:/{print $2; exit}')
  if [ -n "$MAX_RX" ] && [ "$MAX_RX" != "n/a" ]; then
    ethtool -G "$IFACE" rx "$MAX_RX" tx "${MAX_TX:-$MAX_RX}" 2>/dev/null \
      && echo "[OK] ตั้ง ring buffer rx=$MAX_RX tx=${MAX_TX:-$MAX_RX}" \
      || echo "WARN: NIC นี้ (มักเป็น virtio บน VPS) ไม่รองรับปรับ ring buffer — ข้าม"
  else
    echo "SKIP: ethtool อ่านค่า ring buffer ไม่ได้ (ปกติสำหรับ virtio-net บน VPS) — ข้าม"
  fi
else
  echo "SKIP: ไม่พบ ethtool (apt install ethtool เพื่อเปิดใช้ขั้นตอนนี้)"
fi

ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null \
  && echo "[OK] ตั้ง txqueuelen=10000" \
  || echo "WARN: ตั้ง txqueuelen ไม่สำเร็จ"

# persist ผ่าน boot script เดิม
if ! grep -q "txqueuelen" "$SCRIPT_PATH" 2>/dev/null; then
  cat >> "$SCRIPT_PATH" << 'TXQEOF'
ip link set dev "$IFACE" txqueuelen 10000 2>/dev/null || true
TXQEOF
  echo "[OK] เพิ่ม txqueuelen persist เข้า boot script แล้ว"
fi

# ══════════════════════════════════════════
# 5. เพิ่ม initcwnd/initrwnd บน default route (เริ่มส่งข้อมูลเร็วขึ้นตอน connection ใหม่)
# ══════════════════════════════════════════
echo ""
echo "== [5/9] ตั้ง initcwnd/initrwnd = 20 บน default route =="

DEFAULT_ROUTE_LINE=$(ip route show default | head -1)
if [ -z "$DEFAULT_ROUTE_LINE" ]; then
  echo "WARN: ไม่พบ default route — ข้าม"
elif echo "$DEFAULT_ROUTE_LINE" | grep -q "initcwnd 20"; then
  echo "[SKIP] initcwnd ตั้งไว้แล้ว"
else
  # ดึงเฉพาะ "default via X dev Y" ตัดพารามิเตอร์เก่า (initcwnd/initrwnd ถ้ามี) ออกก่อน
  BASE_ROUTE=$(echo "$DEFAULT_ROUTE_LINE" | sed -E 's/ initcwnd [0-9]+//; s/ initrwnd [0-9]+//')
  if ip route change $BASE_ROUTE initcwnd 20 initrwnd 20 2>/dev/null; then
    echo "[OK] initcwnd/initrwnd = 20 ตั้งแล้ว"
  else
    echo "WARN: ตั้ง initcwnd ไม่สำเร็จ (ไม่กระทบระบบหลัก ข้ามได้)"
  fi
fi

# persist ผ่าน systemd service เดิม (เพิ่มคำสั่งเข้าไปใน vps-rps-apply.sh)
if ! grep -q "initcwnd" "$SCRIPT_PATH" 2>/dev/null; then
  cat >> "$SCRIPT_PATH" << 'ROUTEEOF'
_dr=$(ip route show default | head -1 | sed -E 's/ initcwnd [0-9]+//; s/ initrwnd [0-9]+//')
[ -n "$_dr" ] && ip route change $_dr initcwnd 20 initrwnd 20 2>/dev/null || true
ROUTEEOF
  echo "[OK] เพิ่ม initcwnd persist เข้า boot script แล้ว"
fi

# ══════════════════════════════════════════
# 6. ตั้ง CPU governor เป็น performance (กัน CPU throttle ตอนโหลดพุ่ง)
# ══════════════════════════════════════════
echo ""
echo "== [6/9] ตั้ง CPU governor เป็น performance =="

GOV_DIR="/sys/devices/system/cpu/cpu0/cpufreq"
if [ -f "$GOV_DIR/scaling_governor" ]; then
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "performance" > "$gov" 2>/dev/null || true
  done
  echo "[OK] ตั้ง governor เป็น performance ทุกคอร์"

  # persist ผ่าน systemd (VPS มักเป็น KVM ไม่มี cpufreq governor ให้ตั้ง — ข้ามได้ถ้า WARN)
  cat > /etc/systemd/system/vps-cpu-governor.service << 'GOVEOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $g 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GOVEOF
  systemctl daemon-reload
  systemctl enable vps-cpu-governor.service > /dev/null 2>&1
  echo "[OK] ตั้ง persist governor หลังรีบูตแล้ว"
else
  echo "SKIP: VPS นี้ไม่มี cpufreq governor ให้ตั้ง (ปกติสำหรับ KVM/virtio) — ข้ามได้ ไม่กระทบผลลัพธ์"
fi

# ══════════════════════════════════════════
# 7. เพิ่ม file descriptor limit รองรับ SSH/WS multiplex เปิดหลาย connection
# ══════════════════════════════════════════
echo ""
echo "== [7/9] เพิ่ม file descriptor limit (ulimit) =="

LIMITS_FILE="/etc/security/limits.d/99-vps-network-tune.conf"
cat > "$LIMITS_FILE" << 'LIMEOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMEOF
echo "[OK] ตั้ง nofile=1048576 ใน $LIMITS_FILE"

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-nofile.conf << 'SYSDEOF'
[Manager]
DefaultLimitNOFILE=1048576
SYSDEOF
systemctl daemon-reexec 2>/dev/null || true
echo "[OK] ตั้ง DefaultLimitNOFILE ระดับ systemd แล้ว (มีผลเต็มที่หลัง reboot หรือ daemon-reexec)"

# ══════════════════════════════════════════
# 8. เช็ค Path MTU จริง (diagnostic เท่านั้น — ไม่แก้ MTU ให้อัตโนมัติ)
# ══════════════════════════════════════════
echo ""
echo "== [8/9] ตรวจสอบ Path MTU (diagnostic) =="
CURRENT_MTU=$(cat /sys/class/net/"$IFACE"/mtu 2>/dev/null || echo "?")
echo "MTU ปัจจุบันของ $IFACE: $CURRENT_MTU"
GW=$(ip route show default | awk '/default/ {print $3; exit}')
if [ -n "$GW" ] && command -v ping &>/dev/null; then
  if ping -M do -s 1472 -c 2 -W 2 "$GW" &>/dev/null; then
    echo "[OK] MTU 1500 ไป gateway ผ่านปกติ ไม่มี fragmentation"
  else
    echo "WARN: ping ขนาด 1472 bytes (MTU 1500) ไป gateway ไม่ผ่าน — อาจมี PMTU ต่ำกว่า 1500 ในเส้นทาง"
    echo "      แนะนำเช็คเพิ่มด้วย: tracepath <ปลายทางจริงที่ผู้ใช้เชื่อมต่อ>"
  fi
else
  echo "SKIP: หา default gateway ไม่เจอ หรือไม่มีคำสั่ง ping"
fi
# ══════════════════════════════════════════
# 9. IRQ Balance
# ══════════════════════════════════════════
echo ""
echo "== [9/9] เปิด irqbalance =="
if command -v irqbalance &>/dev/null; then
  echo "[SKIP] irqbalance ติดตั้งอยู่แล้ว"
else
  apt-get install -y irqbalance -q > /dev/null 2>&1
  echo "[OK] ติดตั้ง irqbalance แล้ว"
fi
systemctl enable irqbalance > /dev/null 2>&1
systemctl restart irqbalance
echo "[OK] irqbalance active"

# ══════════════════════════════════════════
# ตรวจสอบผลลัพธ์
# ══════════════════════════════════════════
echo ""
echo "════════════════════════════════════════"
echo "  ตรวจสอบผล"
echo "════════════════════════════════════════"
echo "-- sysctl --"
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle net.core.netdev_max_backlog net.ipv4.tcp_fastopen net.ipv4.tcp_ecn net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.rmem_max net.core.wmem_max net.ipv4.tcp_notsent_lowat net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time

echo ""
echo "-- default route (initcwnd/initrwnd) --"
ip route show default

echo ""
echo "-- qdisc ($IFACE) --"
tc qdisc show dev "$IFACE"

echo ""
echo "-- txqueuelen ($IFACE) --"
ip -d link show "$IFACE" | grep -o "qlen [0-9]*" || true

echo ""
echo "-- RPS cpus ($IFACE) --"
for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
  [ -f "$rx/rps_cpus" ] && echo "$(basename "$rx"): $(cat "$rx/rps_cpus")"
done

echo ""
echo "-- CPU governor --"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "(ไม่มี cpufreq บน VPS นี้)"

echo ""
echo "-- file descriptor limit --"
ulimit -n

echo ""
echo "-- services --"
systemctl is-active vps-rps-tune.service irqbalance vps-cpu-governor.service 2>/dev/null || systemctl is-active vps-rps-tune.service irqbalance

echo ""
echo "✅ จูนเสร็จสิ้น — ค่าทั้งหมด persist หลังรีบูตแล้ว"

); then
  RESULTS+=("✅ network-tune")
else
  RC1=$?
  RESULTS+=("❌ network-tune (exit $RC1)")
fi

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  2/3  ChaiyaProject Panel Update        ║"
echo "╚════════════════════════════════════════╝"
if (
set -e

echo "════════════════════════════════════════"
echo "  ChaiyaProject Panel Update"
echo "════════════════════════════════════════"

# ── หาไฟล์ frontend/backend อัตโนมัติ ──
FRONTEND=$(find /opt -iname "sshws.html" 2>/dev/null | grep -v '\.bak' | head -1)
if [ -z "$FRONTEND" ]; then
  echo "ERROR: หาไฟล์ sshws.html ไม่เจอใต้ /opt — ระบุ path เองด้วยการแก้ตัวแปร FRONTEND ในสคริปต์"
  exit 1
fi
echo "== Frontend: $FRONTEND"

BACKEND=""
for f in $(find /opt -iname "*.py" 2>/dev/null | grep -v '\.bak'); do
  if grep -q "def do_POST" "$f" 2>/dev/null && grep -q "create_ssh" "$f" 2>/dev/null; then
    BACKEND="$f"
    break
  fi
done
if [ -z "$BACKEND" ]; then
  echo "ERROR: หาไฟล์ backend (chaiya-ssh-api) ไม่เจอใต้ /opt — ระบุ path เองด้วยการแก้ตัวแปร BACKEND ในสคริปต์"
  exit 1
fi
echo "== Backend: $BACKEND"

SSH_SERVICE=$(systemctl list-units --type=service --all 2>/dev/null | grep -o '[a-z0-9_-]*ssh-api[a-z0-9_-]*\.service' | head -1)
SSH_SERVICE="${SSH_SERVICE:-chaiya-ssh-api.service}"
echo "== SSH API service: $SSH_SERVICE"

TS=$(date +%Y%m%d%H%M%S)
cp -f "$FRONTEND" "${FRONTEND}.bak.${TS}"
cp -f "$BACKEND" "${BACKEND}.bak.${TS}"
echo "[OK] สำรองไฟล์ก่อนแก้แล้ว (.bak.${TS})"

FRONTEND="$FRONTEND" BACKEND="$BACKEND" python3 << 'PYEOF'
import os
FRONTEND = os.environ["FRONTEND"]
BACKEND = os.environ["BACKEND"]

def load(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def save(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

changed_front = False
changed_back = False

# ══════════════════════════════════════════
# FRONTEND — sshws.html
# ══════════════════════════════════════════
h = load(FRONTEND)

# ── [1] VLESS: ปุ่ม "ดูคอนฟิก" ในโมดัล user ──
marker1 = "function buildConfigView(u)"
if marker1 in h:
    print("[SKIP] 1) ปุ่มดูคอนฟิก VLESS — แพตช์แล้ว")
else:
    anchor_btn = '<div class="abtn danger" onclick="mAction(\'delete\')"><div class="ai">🗑️</div><div class="an">ลบยูส</div><div class="ad">ลบถาวร</div></div>'
    new_btn = '<div class="abtn" onclick="mAction(\'config\')"><div class="ai">🔗</div><div class="an">ดูคอนฟิก</div><div class="ad">Link/QR เดิม</div></div>\n      ' + anchor_btn
    assert anchor_btn in h, "[1] ไม่พบปุ่ม delete anchor — โครงสร้าง sshws.html ไม่ตรง ต้องเช็ค manual"
    h = h.replace(anchor_btn, new_btn, 1)

    anchor_div = '<div class="m-sub" id="msub-delete">'
    new_div = '''<div class="m-sub" id="msub-config">
      <div class="link-result show" style="margin-top:10px">
        <div class="link-result-hdr">
          <span style="font-size:.65rem;color:var(--muted)" id="mcfg-meta"></span>
        </div>
        <div class="link-preview" id="mcfg-link"></div>
        <button class="copy-link-btn" onclick="copyConfigLink()">📋 Copy Link</button>
        <div id="mcfg-qr" style="margin-top:10px;display:flex;justify-content:center"></div>
      </div>
    </div>
    ''' + anchor_div
    assert anchor_div in h, "[1] ไม่พบ msub-delete anchor"
    h = h.replace(anchor_div, new_div, 1)

    old_arr = "const _mSubs = ['renew','extend','adddata','setdata','reset','delete'];"
    new_arr = "const _mSubs = ['renew','extend','adddata','setdata','reset','delete','config'];"
    assert old_arr in h, "[1] ไม่พบ _mSubs array"
    h = h.replace(old_arr, new_arr, 1)

    old_open_end = "document.getElementById('modal-alert').style.display='none';\n  document.getElementById('modal').classList.add('open');\n}"
    new_open_end = '''document.getElementById('modal-alert').style.display='none';
  buildConfigView(u);
  document.getElementById('modal').classList.add('open');
}
function buildConfigView(u) {
  let link = '';
  if (u.proto === 'vless') {
    const sni = u.port === 8080 ? 'www.roglobal.com' : 'zoomvdoconnect.cloudzerovps.online';
    link = `vless://${u.uuid}@${sni}:${u.port}?type=ws&security=none&path=%2Fvless&host=${HOST}#${encodeURIComponent(u.email)}`;
  } else {
    document.getElementById('mcfg-meta').textContent = 'ไม่รองรับ protocol นี้';
    document.getElementById('mcfg-link').textContent = '';
    document.getElementById('mcfg-qr').innerHTML = '';
    return;
  }
  document.getElementById('mcfg-meta').textContent = u.proto.toUpperCase() + ' · Port ' + u.port;
  document.getElementById('mcfg-link').textContent = link;
  const qrDiv = document.getElementById('mcfg-qr');
  qrDiv.innerHTML = '';
  try { new QRCode(qrDiv, { text: link, width: 160, height: 160, correctLevel: QRCode.CorrectLevel.M }); } catch(e) {}
}
function copyConfigLink() {
  const link = document.getElementById('mcfg-link').textContent;
  if (!link) return;
  navigator.clipboard.writeText(link).then(()=>showAlert('modal-alert','✅  คัดลอกแล้ว','ok'));
}'''
    assert old_open_end in h, "[1] ไม่พบ openUser() closing block"
    h = h.replace(old_open_end, new_open_end, 1)
    print("[OK] 1) เพิ่มปุ่มดูคอนฟิก VLESS แล้ว")
    changed_front = True

# ── [2] CSS จุดออนไลน์/ออฟไลน์ ──
marker2 = "ssh-dot-pulse"
if marker2 in h:
    print("[SKIP] 2) CSS จุดออนไลน์/ออฟไลน์ — แพตช์แล้ว")
else:
    css = '''
  .stat-dot{width:7px;height:7px;border-radius:50%;display:inline-block;margin-right:5px;vertical-align:middle}
  .stat-dot.on{background:#22c55e;animation:ssh-dot-pulse 1.4s ease-in-out infinite}
  .stat-dot.off{background:#ef4444}
  @keyframes ssh-dot-pulse{
    0%,100%{opacity:1;box-shadow:0 0 0 0 rgba(34,197,94,.55)}
    50%{opacity:.55;box-shadow:0 0 0 5px rgba(34,197,94,0)}
  }
  .conn-lbl{font-size:10.5px;font-weight:600}
  .conn-lbl.on{color:#22c55e}
  .conn-lbl.off{color:#ef4444}
'''
    assert "</style>" in h, "[2] ไม่พบ </style>"
    h = h.replace("</style>", css + "</style>", 1)
    print("[OK] 2) เพิ่ม CSS จุดออนไลน์/ออฟไลน์ แล้ว")
    changed_front = True

# ── [3] SSH: ส่ง carrier/app ตอนสร้าง user ──
marker3 = "carrier:_sshPro, app:_sshApp"
if marker3 in h:
    print("[SKIP] 3) ส่ง carrier/app ตอนสร้าง SSH — แพตช์แล้ว")
else:
    old3 = "body: JSON.stringify({user, password:pass, days, ip_limit:ipl})"
    new3 = "body: JSON.stringify({user, password:pass, days, ip_limit:ipl, carrier:_sshPro, app:_sshApp})"
    assert old3 in h, "[3] ไม่พบ createSSH fetch body"
    h = h.replace(old3, new3, 1)
    print("[OK] 3) ส่ง carrier/app ตอนสร้าง SSH แล้ว")
    changed_front = True

# ── [4] SSH: ปุ่มดูคอนฟิก + สถานะออนไลน์ในตาราง ──
marker4 = "function showSSHConfig("
if marker4 in h:
    print("[SKIP] 4) ปุ่มดูคอนฟิก + สถานะออนไลน์ SSH — แพตช์แล้ว")
else:
    old4 = '''        '<button class="btn-tbl" title="ต่ออายุ" onclick="openSSHRenewModal(\\''+u.user+'\\')">🔄</button>'+
        '<button class="btn-tbl" title="ลบ" onclick="delSSHUser(\\''+u.user+'\\')" style="border-color:rgba(239,68,68,.3)">🗑️</button>'+'''
    new4 = '''        '<button class="btn-tbl" title="ต่ออายุ" onclick="openSSHRenewModal(\\''+u.user+'\\')">🔄</button>'+
        (u.password ? '<button class="btn-tbl" title="ดูคอนฟิก" onclick="showSSHConfig(\\''+u.user+'\\',\\''+(u.password||'')+'\\',\\''+(u.carrier||'')+'\\',\\''+(u.app||'')+'\\')">🔗</button>' : '')+
        '<button class="btn-tbl" title="ลบ" onclick="delSSHUser(\\''+u.user+'\\')" style="border-color:rgba(239,68,68,.3)">🗑️</button>'+'''
    assert old4 in h, "[4] ไม่พบ renderSSHTable button block"
    h = h.replace(old4, new4, 1)

    old_badge = '''    const badge   = active
      ? '<span class="bdg bdg-g">ACTIVE</span>'
      : '<span class="bdg bdg-r">EXPIRED</span>';'''
    new_badge = '''    const badge   = active
      ? '<span class="bdg bdg-g">ACTIVE</span>'
      : '<span class="bdg bdg-r">EXPIRED</span>';
    const isOnline = _sshOnlineSet.has(u.user);
    const connBadge = isOnline
      ? '<div style="margin-top:3px"><span class="stat-dot on"></span><span class="conn-lbl on">ออนไลน์</span></div>'
      : '<div style="margin-top:3px"><span class="stat-dot off"></span><span class="conn-lbl off">ออฟไลน์</span></div>';'''
    assert old_badge in h, "[4] ไม่พบ badge block"
    h = h.replace(old_badge, new_badge, 1)

    old_td = "'<td>'+badge+'</td>' +"
    new_td = "'<td>'+badge+connBadge+'</td>' +"
    assert old_td in h, "[4] ไม่พบ td badge"
    h = h.replace(old_td, new_td, 1)

    old_load = '''let _sshTableUsers = [];
async function loadSSHTableInForm() {
  try {
    const d = await fetch(API+'/users').then(r=>r.json());
    _sshTableUsers = d.users || [];
    renderSSHTable(_sshTableUsers);
  } catch(e) {
    const tb = document.getElementById('ssh-user-tbody');
    if(tb) tb.innerHTML='<tr><td colspan="5" style="text-align:center;color:#ef4444;padding:16px">เชื่อมต่อ SSH API ไม่ได้</td></tr>';
  }
}'''
    new_load = '''let _sshTableUsers = [];
let _sshOnlineSet = new Set();
let _sshPollStarted = false;
async function loadSSHTableInForm() {
  try {
    const d = await fetch(API+'/users').then(r=>r.json());
    _sshTableUsers = d.users || [];
    await refreshSSHOnlineStatus();
    renderSSHTable(_sshTableUsers);
    if (!_sshPollStarted) {
      _sshPollStarted = true;
      setInterval(async () => {
        await refreshSSHOnlineStatus();
        renderSSHTable(_sshTableUsers);
      }, 10000);
    }
  } catch(e) {
    const tb = document.getElementById('ssh-user-tbody');
    if(tb) tb.innerHTML='<tr><td colspan="5" style="text-align:center;color:#ef4444;padding:16px">เชื่อมต่อ SSH API ไม่ได้</td></tr>';
  }
}
async function refreshSSHOnlineStatus() {
  try {
    const d = await fetch(API+'/online_ssh').then(r=>r.json());
    _sshOnlineSet = new Set((d.online||[]).map(x => (typeof x === 'string' ? x : (x.user||x.username||''))));
  } catch(e) { /* เก็บค่าเดิมถ้าดึงไม่ได้ */ }
}'''
    assert old_load in h, "[4] ไม่พบ loadSSHTableInForm เดิม"
    h = h.replace(old_load, new_load, 1)

    old_filter_anchor = "function filterSSHUsers(q) {"
    new_showconfig = '''function showSSHConfig(user, password, carrier, appType) {
  const pro = PROS[carrier] || PROS.dtac;
  const link = appType === 'npv' ? buildNpvLink(user, password, pro) : buildDarkLink(user, password, pro);
  const isNpv = appType === 'npv';
  const cCls = isNpv ? 'npv' : 'dark';
  const appLabel = isNpv ? 'Npvt' : 'DarkTunnel';
  let ov = document.getElementById('ssh-cfg-overlay');
  if (!ov) {
    ov = document.createElement('div');
    ov.id = 'ssh-cfg-overlay';
    ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:9999;display:flex;align-items:center;justify-content:center;padding:20px';
    ov.onclick = function(e){ if (e.target===ov) ov.remove(); };
    document.body.appendChild(ov);
  }
  ov.innerHTML =
    "<div style='background:var(--card,#1a1a2e);border-radius:16px;padding:20px;max-width:360px;width:100%;max-height:85vh;overflow-y:auto' onclick='event.stopPropagation()'>" +
      "<div style='display:flex;justify-content:space-between;align-items:center;margin-bottom:12px'>" +
        "<b>🔗 " + user + "</b>" +
        "<span style='cursor:pointer;font-size:20px;color:var(--muted)' onclick=\\"document.getElementById('ssh-cfg-overlay').remove()\\">✕</span>" +
      "</div>" +
      "<div class='link-result show'>" +
        "<div class='link-result-hdr'>" +
          "<span class='imp-badge " + cCls + "'>" + appLabel + "</span>" +
          "<span style='font-size:.65rem;color:var(--muted)'>" + (pro.name||carrier) + "</span>" +
        "</div>" +
        "<div class='link-preview" + (isNpv?'':' dark-lp') + "'>" + link + "</div>" +
        "<button class='copy-link-btn " + cCls + "' onclick=\\"navigator.clipboard.writeText(document.getElementById('ssh-cfg-link').textContent).then(()=>showAlert && showAlert('ssh-alert','✅ คัดลอกแล้ว','ok'))\\" id='ssh-cfg-copybtn'>📋 Copy " + appLabel + " Link</button>" +
        "<div id='ssh-cfg-qr' style='margin-top:12px;display:flex;justify-content:center'></div>" +
      "</div>" +
    "</div>";
  const linkPreview = ov.querySelector('.link-preview');
  linkPreview.id = 'ssh-cfg-link';
  const logoDiv = document.getElementById('ssh-cfg-qr');
  logoDiv.innerHTML = isNpv
    ? '<div style="width:64px;height:64px;border-radius:16px;background:#0d2a3a;display:flex;align-items:center;justify-content:center;font-family:monospace;font-weight:900;font-size:1.4rem;color:#00ccff;letter-spacing:-1px;border:2px solid rgba(0,204,255,.3)">nV</div>'
    : '<div style="width:64px;height:64px;border-radius:16px;background:#111;display:flex;align-items:center;justify-content:center;font-family:sans-serif;font-weight:900;font-size:1rem;color:#fff;letter-spacing:.5px;border:2px solid #444">DARK</div>';
}
function filterSSHUsers(q) {'''
    assert old_filter_anchor in h, "[4] ไม่พบ filterSSHUsers anchor"
    h = h.replace(old_filter_anchor, new_showconfig, 1)

    print("[OK] 4) ปุ่มดูคอนฟิก + สถานะออนไลน์ SSH แล้ว")
    changed_front = True

# ── [5] SNI domain replace ──
old_sni = "true-internet.zoom.xyz.services"
new_sni = "zoomvdoconnect.cloudzerovps.online"
sni_count = h.count(old_sni)
if sni_count == 0:
    print("[SKIP] 5) SNI domain — ไม่เจอค่าเก่า (แทนที่แล้ว หรือเซิร์ฟเวอร์นี้ไม่ได้ใช้ค่านี้)")
else:
    h = h.replace(old_sni, new_sni)
    print(f"[OK] 5) เปลี่ยน SNI domain แล้ว ({sni_count} จุด)")
    changed_front = True

if changed_front:
    save(FRONTEND, h)
else:
    print("[INFO] frontend ไม่มีอะไรต้องแก้เพิ่ม")

# ══════════════════════════════════════════
# BACKEND — chaiya-ssh-api
# ══════════════════════════════════════════
b = load(BACKEND)

# ── [6] helper + creds storage + create_ssh/delete_ssh/api_users ──
marker6 = "CREDS_FILE = "
if marker6 in b:
    print("[SKIP] 6) SSH creds storage backend — แพตช์แล้ว")
else:
    anchor = "def respond(handler, code, data):"
    assert anchor in b, "[6] ไม่พบ anchor 'def respond'"
    helpers = '''CREDS_FILE = '/etc/chaiya/ssh_creds.json'
def load_ssh_creds():
    try:
        with open(CREDS_FILE, 'r') as f:
            return json.load(f)
    except: return {}
def save_ssh_creds(creds):
    os.makedirs('/etc/chaiya', exist_ok=True)
    with open(CREDS_FILE, 'w') as f:
        json.dump(creds, f)
    os.chmod(CREDS_FILE, 0o600)

'''
    b = b.replace(anchor, helpers + anchor, 1)

    old_users_route = "elif self.path == '/api/users':\n            respond(self, 200, {'users': list_ssh_users()})"
    new_users_route = '''elif self.path == '/api/users':
            _creds = load_ssh_creds()
            _users = list_ssh_users()
            for _u in _users:
                _uname = _u.get('user') or _u.get('username') or _u.get('name')
                if _uname and _uname in _creds:
                    _c = _creds[_uname]
                    if isinstance(_c, dict):
                        _u['password'] = _c.get('password', '')
                        _u['carrier'] = _c.get('carrier', '')
                        _u['app'] = _c.get('app', '')
                    else:
                        _u['password'] = _c
            respond(self, 200, {'users': _users})'''
    assert old_users_route in b, "[6] ไม่พบ route /api/users เดิม"
    b = b.replace(old_users_route, new_users_route, 1)

    old_create = '''            run_cmd(f"chage -E {exp_date} {user}")
            with open(f'/etc/chaiya/exp/{user}', 'w') as f:
                f.write(exp_date)
            respond(self, 200, {'ok': True, 'user': user, 'exp': exp_date, 'days': days})'''
    new_create = '''            run_cmd(f"chage -E {exp_date} {user}")
            with open(f'/etc/chaiya/exp/{user}', 'w') as f:
                f.write(exp_date)
            carrier = data.get('carrier', '').strip()
            app_type = data.get('app', '').strip()
            _creds = load_ssh_creds()
            _creds[user] = {'password': passwd, 'carrier': carrier, 'app': app_type}
            save_ssh_creds(_creds)
            respond(self, 200, {'ok': True, 'user': user, 'exp': exp_date, 'days': days})'''
    assert old_create in b, "[6] ไม่พบ block create_ssh เดิม"
    b = b.replace(old_create, new_create, 1)

    old_delete = '''            run_cmd(f"userdel -f {user} 2>/dev/null || true")
            try: os.remove(f'/etc/chaiya/exp/{user}')
            except: pass
            respond(self, 200, {'ok': True, 'user': user})'''
    new_delete = '''            run_cmd(f"userdel -f {user} 2>/dev/null || true")
            try: os.remove(f'/etc/chaiya/exp/{user}')
            except: pass
            _creds = load_ssh_creds()
            _creds.pop(user, None)
            save_ssh_creds(_creds)
            respond(self, 200, {'ok': True, 'user': user})'''
    assert old_delete in b, "[6] ไม่พบ block delete_ssh เดิม"
    b = b.replace(old_delete, new_delete, 1)

    print("[OK] 6) SSH creds storage backend แล้ว")
    changed_back = True

# ── [7] get_online_ssh_users แบบ journalctl (ทับของเดิมทั้งฟังก์ชัน) ──
marker7 = "Password auth succeeded for"
if marker7 in b:
    print("[SKIP] 7) get_online_ssh_users แบบ journalctl — แพตช์แล้ว")
else:
    lines = b.split("\n")
    start = None
    end = None
    for i, ln in enumerate(lines):
        if ln.startswith("def get_online_ssh_users("):
            start = i
        elif start is not None and ln.startswith("def get_banned_users("):
            end = i
            break
    assert start is not None and end is not None, "[7] หาขอบเขตฟังก์ชัน get_online_ssh_users เดิมไม่เจอ"

    new_func_lines = '''def get_online_ssh_users():
    """ดึง SSH users ที่ online จริง — parse จาก dropbear log (auth succeeded / exit)
    เพราะ dropbear รันแบบ tunnel-only ไม่ setuid ไปเป็น user เลยเช็คจาก process uid ไม่ได้"""
    online = []
    try:
        users_map = {}
        for u in list_ssh_users():
            users_map[u['user']] = u
        if not users_map:
            return []

        _, pid_out, _ = run_cmd("pgrep -x dropbear 2>/dev/null || true")
        live_pids = set(pid_out.strip().split()) if pid_out.strip() else set()
        if not live_pids:
            return []

        _, log_out, _ = run_cmd(
            "journalctl -u dropbear --no-pager -n 4000 2>/dev/null"
        )
        if not log_out.strip():
            _, log_out, _ = run_cmd(
                "grep dropbear /var/log/syslog 2>/dev/null | tail -4000 || true"
            )

        import re as _re
        pid_user = {}
        for line in log_out.split(chr(10)):
            m = _re.search(r"dropbear\[(\d+)\]: Password auth succeeded for '([^']+)'", line)
            if m:
                pid_user[m.group(1)] = m.group(2)
                continue
            m2 = _re.search(r"dropbear\[(\d+)\]: Exit \(([^)]+)\)", line)
            if m2:
                pid_user.pop(m2.group(1), None)

        seen = set()
        for pid, uname in pid_user.items():
            if pid in live_pids and uname in users_map and uname not in seen:
                seen.add(uname)
                online.append(users_map[uname].copy())

        return online
    except Exception:
        return []

'''.split("\n")

    new_lines = lines[:start] + new_func_lines + lines[end:]
    b = "\n".join(new_lines)
    print("[OK] 7) get_online_ssh_users แบบ journalctl แล้ว")
    changed_back = True

if changed_back:
    save(BACKEND, b)
else:
    print("[INFO] backend ไม่มีอะไรต้องแก้เพิ่ม")

print("DONE")
PYEOF

RC=$?
if [ $RC -ne 0 ]; then
  echo ""
  echo "❌ แพตช์ล้มเหลว — ไฟล์ยังไม่ถูกแก้ (assert ป้องกันการเขียนครึ่งๆ กลางๆ)"
  echo "   โครงสร้างไฟล์บนเครื่องนี้อาจต่างจากต้นแบบ ต้องเช็ค manual"
  exit 1
fi

systemctl restart "$SSH_SERVICE" 2>/dev/null && echo "[OK] restart $SSH_SERVICE แล้ว" \
  || echo "WARN: restart $SSH_SERVICE ไม่สำเร็จ — เช็คชื่อ service ด้วย systemctl list-units | grep ssh-api"

echo ""
echo "════════════════════════════════════════"
echo "✅ อัปเดตเสร็จสิ้น"
echo "════════════════════════════════════════"
echo "หมายเหตุ: ปุ่มดูคอนฟิก SSH จะใช้ได้เฉพาะ user ที่สร้างใหม่หลังจากนี้เท่านั้น"

); then
  RESULTS+=("✅ panel-update")
else
  RC2=$?
  RESULTS+=("❌ panel-update (exit $RC2)")
fi

echo ""
echo "╔════════════════════════════════════════╗"
echo "║  3/3  AIS-NOPRO / TRUE-Rov Patch        ║"
echo "╚════════════════════════════════════════╝"
if (
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

import re

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

def apply_regex(label, pattern, repl_func, already_ok_check):
    """ใช้ regex เพื่อทนทานต่อค่า else-branch ที่ต่างกันในแต่ละเซิร์ฟเวอร์
    (เช่น zoomvdoconnect.cloudzerovps.online บนบางเครื่อง vs
    true-internet.zoom.xyz.services บนอีกเครื่อง)"""
    global html
    if already_ok_check(html):
        skipped.append(label + " (มีอยู่แล้ว)")
        return
    m = re.search(pattern, html)
    if not m:
        skipped.append(label + " (ไม่พบ pattern เดิม - ข้าม)")
        return
    html = re.sub(pattern, repl_func, html, count=1)
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

apply_regex(
    "js sni const: cj-ebb -> roglobal (regex, ไม่สนใจค่า else-branch)",
    r"const sni\s*=\s*carrier==='ais'\s*\?\s*'cj-ebb\.speedtest\.net'\s*:\s*'([^']+)';",
    lambda m: "const sni  = carrier==='ais' ? 'www.roglobal.com' : '" + m.group(1) + "';",
    lambda h: re.search(r"const sni\s*=\s*carrier==='ais'\s*\?\s*'www\.roglobal\.com'", h) is not None
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

); then
  RESULTS+=("✅ ais-true-rov-patch")
else
  RC3=$?
  RESULTS+=("❌ ais-true-rov-patch (exit $RC3)")
fi

echo ""
echo "════════════════════════════════════════"
echo "  สรุปผล"
echo "════════════════════════════════════════"
for r in "${RESULTS[@]}"; do
  echo "  $r"
done

for r in "${RESULTS[@]}"; do
  [[ "$r" == ❌* ]] && exit 1
done
exit 0
