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
