#!/bin/bash
# ══════════════════════════════════════════════════════════════════
# vps-network-tune.sh
# จูนเครือข่าย VPS: BBR + FQ + MTU Probing + RPS/RFS + IRQ Balance
# ตาม profile เดียวกับที่ใช้บน FirewallFalcon (เสถียร ผ่านการทดสอบแล้ว)
#
# ใช้งาน:
#   sudo ./vps-network-tune.sh
#
# รันซ้ำได้ (idempotent) — ตรวจสอบสถานะก่อนเปลี่ยนทุกจุด
# ══════════════════════════════════════════════════════════════════

set -e

if [ "$EUID" -ne 0 ]; then
  echo "ERROR: ต้องรันด้วย root (sudo)"
  exit 1
fi

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
echo "== [1/6] ตั้งค่า sysctl (BBR + FQ + MTU Probing + backlog) =="

SYSCTL_FILE="/etc/sysctl.d/99-vps-network-tune.conf"
cp -f "$SYSCTL_FILE" "${SYSCTL_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

cat > "$SYSCTL_FILE" << 'SYSEOF'
# vps-network-tune.sh — BBR + FQ + MTU Probing profile (v2)
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
SYSEOF

sysctl --system > /dev/null 2>&1
echo "[OK] sysctl applied"
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_mtu_probing net.core.netdev_max_backlog

# ══════════════════════════════════════════
# 2. เปลี่ยน qdisc ของ interface เป็น fq ทันที (ไม่ต้องรอรีบูต)
# ══════════════════════════════════════════
echo ""
echo "== [2/6] ตั้ง qdisc ของ $IFACE เป็น fq =="
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
echo "== [3/6] เปิด RPS/RFS บนทุก RX queue ของ $IFACE =="

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
# 5. เพิ่ม initcwnd/initrwnd บน default route (เริ่มส่งข้อมูลเร็วขึ้นตอน connection ใหม่)
# ══════════════════════════════════════════
echo ""
echo "== [4/6] ตั้ง initcwnd/initrwnd = 20 บน default route =="

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
# 6. เช็ค Path MTU จริง (diagnostic เท่านั้น — ไม่แก้ MTU ให้อัตโนมัติ)
# ══════════════════════════════════════════
echo ""
echo "== [5/6] ตรวจสอบ Path MTU (diagnostic) =="
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
# 7. IRQ Balance
# ══════════════════════════════════════════
echo ""
echo "== [6/6] เปิด irqbalance =="
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
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.ipv4.tcp_mtu_probing net.ipv4.tcp_slow_start_after_idle net.core.netdev_max_backlog net.ipv4.tcp_fastopen net.ipv4.tcp_ecn net.core.somaxconn net.ipv4.tcp_max_syn_backlog

echo ""
echo "-- default route (initcwnd/initrwnd) --"
ip route show default

echo ""
echo "-- qdisc ($IFACE) --"
tc qdisc show dev "$IFACE"

echo ""
echo "-- RPS cpus ($IFACE) --"
for rx in /sys/class/net/"$IFACE"/queues/rx-*; do
  [ -f "$rx/rps_cpus" ] && echo "$(basename "$rx"): $(cat "$rx/rps_cpus")"
done

echo ""
echo "-- services --"
systemctl is-active vps-rps-tune.service irqbalance

echo ""
echo "✅ จูนเสร็จสิ้น — ค่าทั้งหมด persist หลังรีบูตแล้ว"
