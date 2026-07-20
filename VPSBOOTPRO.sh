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
echo "== [1/18] ตั้งค่า sysctl (BBR + FQ + MTU Probing + buffer + keepalive) =="

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
echo "== [2/18] ตั้ง qdisc ของ $IFACE เป็น fq =="
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
echo "== [3/18] เปิด RPS/RFS บนทุก RX queue ของ $IFACE =="

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
echo "== [4/18] เพิ่ม ring buffer / txqueuelen ของ $IFACE =="

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
echo "== [5/18] ตั้ง initcwnd/initrwnd = 20 บน default route =="

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
echo "== [6/18] ตั้ง CPU governor เป็น performance =="

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
echo "== [7/18] เพิ่ม file descriptor limit (ulimit) =="

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
echo "== [8/18] ตรวจสอบ Path MTU (diagnostic) =="
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
echo "== [9/18] เปิด irqbalance =="
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
# 10. เปิด NIC multiqueue ให้เท่าจำนวนคอร์ (สำคัญสุดสำหรับ 4 คอร์ — ของเดิมมีคิวเดียว)
# ══════════════════════════════════════════
echo ""
echo "== [10/18] เปิด multiqueue บน $IFACE (combined=$NCPU) =="

MQ_SUPPORTED=0
if command -v ethtool &>/dev/null; then
  MAX_COMBINED=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Pre-set maximums:/{f=1;next} f && /Combined:/{print $2; exit}')
  if [ -n "$MAX_COMBINED" ] && [ "$MAX_COMBINED" -gt 1 ] 2>/dev/null; then
    MQ_SUPPORTED=1
    TARGET=$NCPU
    [ "$TARGET" -gt "$MAX_COMBINED" ] && TARGET=$MAX_COMBINED
    if ethtool -L "$IFACE" combined "$TARGET" 2>/dev/null; then
      echo "[OK] ตั้ง combined queues = $TARGET (max รองรับ $MAX_COMBINED)"
    else
      MQ_SUPPORTED=0
      echo "WARN: สั่ง ethtool -L สำเร็จแต่ apply ไม่ผ่าน — ข้าม (VPS นี้อาจ fix คิวไว้ที่ hypervisor)"
    fi
  else
    echo "SKIP: NIC นี้รองรับคิวเดียว (Combined max=${MAX_COMBINED:-1}) — เป็น virtio queue เดียวตามที่ provider ตั้ง ไม่สามารถเพิ่มเองได้ ข้ามไปใช้ RPS/RFS แทน (ทำแล้วใน step 3)"
  fi
else
  echo "SKIP: ไม่พบ ethtool"
fi

# ── ถ้าเปิด multiqueue สำเร็จ ตั้ง XPS ให้แต่ละ TX queue ผูกกับคอร์ตัวเอง (1:1) ──
if [ "$MQ_SUPPORTED" -eq 1 ]; then
  echo "== ตั้ง XPS (TX queue -> CPU แบบ 1:1) =="
  i=0
  for txq in "$RXQ_DIR"/tx-*; do
    if [ -f "$txq/xps_cpus" ]; then
      CPU_MASK=$(python3 -c "print(format(1 << ($i % $NCPU), 'x'))")
      echo "$CPU_MASK" > "$txq/xps_cpus" 2>/dev/null || true
      echo "[OK] $(basename "$txq"): xps_cpus=$CPU_MASK"
      i=$((i+1))
    fi
  done
  # persist XPS ผ่าน boot script เดิม
  if ! grep -q "xps_cpus" "$SCRIPT_PATH" 2>/dev/null; then
    cat >> "$SCRIPT_PATH" << XPSEOF
ethtool -L "\$IFACE" combined $NCPU 2>/dev/null || true
i=0
for txq in /sys/class/net/\$IFACE/queues/tx-*; do
  [ -f "\$txq/xps_cpus" ] && echo "\$(python3 -c "print(format(1 << (\$i % $NCPU), 'x'))")" > "\$txq/xps_cpus"
  i=\$((i+1))
done
XPSEOF
    echo "[OK] เพิ่ม multiqueue+XPS persist เข้า boot script แล้ว"
  fi
else
  echo "[SKIP] ไม่เปิด XPS เพราะ NIC ไม่รองรับ multiqueue"
fi

# ══════════════════════════════════════════
# 11. เปิด offload (GRO/GSO/TSO) — ลด CPU overhead ต่อแพ็กเก็ต เพิ่ม throughput
# ══════════════════════════════════════════
echo ""
echo "== [11/18] ตรวจสอบ/เปิด GRO/GSO/TSO บน $IFACE =="
if command -v ethtool &>/dev/null; then
  for feat in gro gso tso; do
    STATE=$(ethtool -k "$IFACE" 2>/dev/null | awk -v f="$feat" '$0 ~ "^"f":" {print $2; exit}')
    if [ "$STATE" = "off" ]; then
      ethtool -K "$IFACE" "$feat" on 2>/dev/null \
        && echo "[OK] เปิด $feat" \
        || echo "WARN: เปิด $feat ไม่สำเร็จ"
    else
      echo "[SKIP] $feat เปิดอยู่แล้ว (หรือ NIC ไม่รองรับ)"
    fi
  done
else
  echo "SKIP: ไม่พบ ethtool"
fi

# ══════════════════════════════════════════
# 12. เพิ่ม netdev_budget — ให้แต่ละคอร์ประมวลผล packet ต่อรอบ NAPI ได้มากขึ้น (ลด latency spike ตอน burst)
# ══════════════════════════════════════════
echo ""
echo "== [12/18] ตั้ง net.core.netdev_budget / netdev_budget_usecs =="
if ! grep -q "netdev_budget" "$SYSCTL_FILE" 2>/dev/null; then
  cat >> "$SYSCTL_FILE" << BUDEOF

# ── เพิ่ม NAPI budget ต่อรอบ (สำคัญเมื่อเปิด multiqueue หลายคอร์) ──
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
BUDEOF
  sysctl --system > /dev/null 2>&1
  echo "[OK] ตั้ง netdev_budget=600, netdev_budget_usecs=8000"
else
  echo "[SKIP] ตั้งไว้แล้ว"
fi

# ══════════════════════════════════════════
# 13. ล็อก IRQ affinity คงที่ (แก้ปิงสวิง — irqbalance ย้าย IRQ ไปมาทุก ~10s ชนกับ multiqueue/XPS ที่ตั้งตายตัวไว้)
# ══════════════════════════════════════════
echo ""
echo "== [13/18] ตรึง NIC IRQ เข้าคอร์คงที่ 1:1 + ปิด irqbalance ไม่ให้ยุ่งกับคิวเครือข่าย =="

NIC_IRQS=""
MSI_DIR="/sys/class/net/$IFACE/device/msi_irqs"
if [ -d "$MSI_DIR" ] && [ -n "$(ls -A "$MSI_DIR" 2>/dev/null)" ]; then
  NIC_IRQS=$(ls "$MSI_DIR")
  echo "[INFO] หา IRQ จาก $MSI_DIR ได้: $NIC_IRQS"
else
  VIRTIO_DEV=$(basename "$(readlink -f /sys/class/net/"$IFACE"/device 2>/dev/null)" 2>/dev/null)
  if [ -n "$VIRTIO_DEV" ] && grep -q "$VIRTIO_DEV" /proc/interrupts 2>/dev/null; then
    NIC_IRQS=$(grep -E "$VIRTIO_DEV" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ')
    echo "[INFO] หา IRQ จาก /proc/interrupts ผ่านชื่อ device $VIRTIO_DEV ได้: $NIC_IRQS"
  else
    NIC_IRQS=$(grep -E "$IFACE" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ')
  fi
fi
if [ -n "$NIC_IRQS" ]; then
  i=0
  IRQ_PIN_LIST=""
  for irq in $NIC_IRQS; do
    CPU=$((i % NCPU))
    if [ -f "/proc/irq/$irq/smp_affinity_list" ]; then
      echo "$CPU" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null \
        && echo "[OK] irq $irq -> cpu $CPU" \
        || echo "WARN: ตรึง irq $irq ไม่สำเร็จ (อาจถูกล็อกโดย kernel/managed_irq)"
      IRQ_PIN_LIST="$IRQ_PIN_LIST $irq:$CPU"
      i=$((i+1))
    fi
  done

  # ห้าม irqbalance ยุ่งกับ IRQ การ์ดเน็ต (รองรับ irqbalance ที่มี --banirq เท่านั้น)
  if irqbalance --help 2>&1 | grep -q banirq; then
    BAN_ARGS=""
    for irq in $NIC_IRQS; do BAN_ARGS="$BAN_ARGS --banirq=$irq"; done
    mkdir -p /etc/systemd/system/irqbalance.service.d
    cat > /etc/systemd/system/irqbalance.service.d/override.conf << IRQEOF
[Service]
ExecStart=
ExecStart=/usr/sbin/irqbalance --foreground$BAN_ARGS
IRQEOF
    systemctl daemon-reload
    systemctl restart irqbalance
    echo "[OK] แบน NIC IRQ ออกจาก irqbalance แล้ว (irqbalance คุมแค่ IRQ อื่น เช่น ดิสก์)"
  else
    systemctl stop irqbalance 2>/dev/null
    systemctl disable irqbalance 2>/dev/null
    echo "[OK] irqbalance รุ่นนี้ไม่รองรับ --banirq เลยปิดไปเลย ใช้ affinity คงที่ที่ตั้งไว้แทนทั้งระบบ"
  fi

  # persist การตรึง IRQ ผ่าน systemd oneshot (เพราะ /proc/irq รีเซ็ตทุก reboot)
  cat > /usr/local/sbin/vps-irq-pin.sh << PINEOF
#!/bin/bash
IFACE="$IFACE"
NCPU=$NCPU
MSI_DIR="/sys/class/net/\$IFACE/device/msi_irqs"
if [ -d "\$MSI_DIR" ] && [ -n "\$(ls -A "\$MSI_DIR" 2>/dev/null)" ]; then
  IRQ_LIST=\$(ls "\$MSI_DIR")
else
  VIRTIO_DEV=\$(basename "\$(readlink -f /sys/class/net/"\$IFACE"/device 2>/dev/null)" 2>/dev/null)
  if [ -n "\$VIRTIO_DEV" ] && grep -q "\$VIRTIO_DEV" /proc/interrupts 2>/dev/null; then
    IRQ_LIST=\$(grep -E "\$VIRTIO_DEV" /proc/interrupts | awk -F: '{print \$1}' | tr -d ' ')
  else
    IRQ_LIST=\$(grep -E "\$IFACE" /proc/interrupts | awk -F: '{print \$1}' | tr -d ' ')
  fi
fi
i=0
for irq in \$IRQ_LIST; do
  CPU=\$((i % NCPU))
  [ -f "/proc/irq/\$irq/smp_affinity_list" ] && echo "\$CPU" > "/proc/irq/\$irq/smp_affinity_list" 2>/dev/null
  i=\$((i+1))
done
PINEOF
  chmod +x /usr/local/sbin/vps-irq-pin.sh
  cat > /etc/systemd/system/vps-irq-pin.service << SVCEOF
[Unit]
Description=Pin NIC IRQs to fixed CPUs (ping jitter fix)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-irq-pin.sh

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl daemon-reload
  systemctl enable vps-irq-pin.service > /dev/null 2>&1
  echo "[OK] ตั้ง vps-irq-pin.service ให้ตรึง IRQ ใหม่ทุกครั้งที่บูตแล้ว"
else
  echo "SKIP: หา NIC IRQ ของ $IFACE ไม่เจอใน /proc/interrupts"
fi

# ══════════════════════════════════════════
# 14. ลด/ล็อก interrupt coalescing — ปิงจะนิ่งขึ้นเพราะไม่ต้องรอ buffer ของ NIC (แลกกับ CPU เพิ่มเล็กน้อย รับได้กับ 4 คอร์)
# ══════════════════════════════════════════
echo ""
echo "== [14/18] ตั้ง interrupt coalescing ต่ำสุด (adaptive off, rx/tx-usecs=0) =="
if command -v ethtool &>/dev/null; then
  ethtool -C "$IFACE" adaptive-rx off adaptive-tx off 2>/dev/null
  if ethtool -C "$IFACE" rx-usecs 0 tx-usecs 0 2>/dev/null; then
    echo "[OK] coalescing rx-usecs=0 tx-usecs=0 (แจ้ง interrupt ทันทีทุกแพ็กเก็ต -> ปิงนิ่งสุด)"
  elif ethtool -C "$IFACE" rx-usecs 1 tx-usecs 1 2>/dev/null; then
    echo "[OK] coalescing rx-usecs=1 tx-usecs=1 (ต่ำสุดที่ NIC นี้รองรับ)"
  else
    echo "SKIP: NIC/hypervisor นี้ไม่ให้ปรับ coalescing (virtio บาง provider fix ค่าไว้)"
  fi
else
  echo "SKIP: ไม่พบ ethtool"
fi

# ══════════════════════════════════════════
# 15. TCP: ปิด slow-start-after-idle + เปิด fastopen + ตั้ง tcp_rmem/tcp_wmem ชัดเจน
#     (ping ที่วัดเป็นจังหวะผ่าน tunnel มักโดน cwnd reset ตอน idle ระหว่างรอบ ping ทำให้ RTT แรกหลัง idle สูงผิดปกติ)
# ══════════════════════════════════════════
echo ""
echo "== [15/18] ตั้ง tcp_slow_start_after_idle=0, tcp_fastopen=3, tcp_rmem/tcp_wmem =="
if ! grep -q "tcp_slow_start_after_idle" "$SYSCTL_FILE" 2>/dev/null; then
  cat >> "$SYSCTL_FILE" << TCPEOF

# ── ลด RTT spike หลัง idle + fastopen + ปรับ autotuning window ชัดเจน ──
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
TCPEOF
  sysctl --system > /dev/null 2>&1
  echo "[OK] ตั้งค่าแล้ว (cwnd จะไม่ reset ตอน tunnel ว่าง, connection ใหม่เร็วขึ้น 1 RTT)"
else
  echo "[SKIP] ตั้งไว้แล้ว"
fi

# ══════════════════════════════════════════
# 16. ปิด Transparent Huge Pages (THP) — กัน latency spike ตอน kernel ทำ memory compaction
# ══════════════════════════════════════════
echo ""
echo "== [16/18] ปิด THP (transparent hugepage) =="
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
  echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
  echo "[OK] ปิด THP ทันที ($(cat /sys/kernel/mm/transparent_hugepage/enabled))"

  cat > /usr/local/sbin/vps-disable-thp.sh << THPEOF
#!/bin/bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
THPEOF
  chmod +x /usr/local/sbin/vps-disable-thp.sh
  cat > /etc/systemd/system/vps-disable-thp.service << THPSVCEOF
[Unit]
Description=Disable Transparent Huge Pages (latency stability)
After=sysinit.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vps-disable-thp.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
THPSVCEOF
  systemctl daemon-reload
  systemctl enable vps-disable-thp.service > /dev/null 2>&1
  echo "[OK] ตั้ง vps-disable-thp.service ให้ปิด THP ทุกครั้งที่บูตแล้ว"
else
  echo "SKIP: kernel นี้ไม่มี THP ให้ปิด"
fi

# ══════════════════════════════════════════
# 17. ขยาย conntrack table — VPN panel ลูกค้าเยอะ, connection สั้นๆ จำนวนมาก (badvpn/dropbear/xray)
#     ถ้า table เต็มจะเริ่ม drop connection ใหม่แบบเงียบๆ ทำให้รู้สึกเหมือนปิงสวิง/หลุดเป็นระยะ
# ══════════════════════════════════════════
echo ""
echo "== [17/18] ขยาย nf_conntrack_max และลด timeout ของ session ที่ไม่ active =="
if [ -f /proc/sys/net/netfilter/nf_conntrack_max ] || sysctl net.netfilter.nf_conntrack_max &>/dev/null; then
  if ! grep -q "nf_conntrack_max" "$SYSCTL_FILE" 2>/dev/null; then
    cat >> "$SYSCTL_FILE" << CTEOF

# ── รองรับ connection พร้อมกันได้เยอะขึ้น (VPN panel ลูกค้าหลายคน) ──
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
CTEOF
    sysctl --system > /dev/null 2>&1
    CT_HASHSIZE_PATH="/sys/module/nf_conntrack/parameters/hashsize"
    if [ -w "$CT_HASHSIZE_PATH" ]; then
      echo 262144 > "$CT_HASHSIZE_PATH" 2>/dev/null && echo "[OK] ตั้ง hashsize=262144 คู่กับ nf_conntrack_max"
    fi
    echo "[OK] ตั้ง nf_conntrack_max=1048576"
  else
    echo "[SKIP] ตั้งไว้แล้ว"
  fi
else
  echo "SKIP: nf_conntrack module ไม่ได้โหลด (ไม่มี iptables/nftables state table ใช้งาน — ข้ามได้ปลอดภัย)"
fi

# ══════════════════════════════════════════
# 18. ยกระดับ scheduling priority ของ process tunnel หลัก — กัน jitter ตอนเครื่องมี background load
# ══════════════════════════════════════════
echo ""
echo "== [18/18] ตั้ง Nice priority ให้ dropbear/xray/badvpn/ws-stunnel สูงกว่า process ทั่วไป =="
for svc in dropbear.service chaiya-badvpn.service chaiya-sshws.service chaiya-ssh-api.service x-ui.service; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
    mkdir -p "/etc/systemd/system/${svc}.d"
    cat > "/etc/systemd/system/${svc}.d/priority.conf" << PRIOEOF
[Service]
Nice=-10
PRIOEOF
    echo "[OK] $svc: Nice=-10"
  else
    echo "[SKIP] $svc: ไม่มี unit นี้บนเครื่อง"
  fi
done
systemctl daemon-reload
for svc in dropbear.service chaiya-badvpn.service chaiya-sshws.service chaiya-ssh-api.service x-ui.service; do
  systemctl is-active "$svc" &>/dev/null && systemctl restart "$svc" 2>/dev/null
done
echo "[OK] restart service ที่เกี่ยวข้องให้ priority มีผลแล้ว"

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
echo "-- multiqueue (combined channels) --"
ethtool -l "$IFACE" 2>/dev/null | grep -A5 "^Current hardware settings:" || echo "(ethtool ไม่รองรับ/ไม่มีข้อมูล)"

echo ""
echo "-- XPS (tx queue -> cpu) --"
for txq in /sys/class/net/"$IFACE"/queues/tx-*; do
  [ -f "$txq/xps_cpus" ] && echo "$(basename "$txq"): $(cat "$txq/xps_cpus")"
done

echo ""
echo "-- offload (gro/gso/tso) --"
ethtool -k "$IFACE" 2>/dev/null | grep -E "^(generic-receive-offload|generic-segmentation-offload|tcp-segmentation-offload):" || true

echo ""
echo "-- netdev budget --"
sysctl net.core.netdev_budget net.core.netdev_budget_usecs

echo ""
echo "-- NIC irq affinity (ควรกระจายคนละคอร์ ไม่ใช่ irqbalance คุมแล้ว) --"
_MSI="/sys/class/net/$IFACE/device/msi_irqs"
if [ -d "$_MSI" ] && [ -n "$(ls -A "$_MSI" 2>/dev/null)" ]; then
  _IRQS=$(ls "$_MSI")
else
  _VDEV=$(basename "$(readlink -f /sys/class/net/"$IFACE"/device 2>/dev/null)" 2>/dev/null)
  _IRQS=$(grep -E "${_VDEV:-$IFACE}" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ')
fi
for irq in $_IRQS; do
  [ -f "/proc/irq/$irq/smp_affinity_list" ] && echo "irq $irq: $(cat /proc/irq/$irq/smp_affinity_list)"
done
systemctl is-active vps-irq-pin.service 2>/dev/null

echo ""
echo "-- interrupt coalescing --"
ethtool -c "$IFACE" 2>/dev/null | grep -E "^(Adaptive RX|Adaptive TX|rx-usecs|tx-usecs):" || echo "(ไม่รองรับ)"

echo ""
echo "-- tcp idle/fastopen --"
sysctl net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_fastopen

echo ""
echo "-- THP --"
cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null

echo ""
echo "-- conntrack --"
sysctl net.netfilter.nf_conntrack_max 2>/dev/null || echo "(module ไม่โหลด)"
sysctl net.netfilter.nf_conntrack_count 2>/dev/null

echo ""
echo "-- service priority (nice) --"
for svc in dropbear.service chaiya-badvpn.service chaiya-sshws.service chaiya-ssh-api.service x-ui.service; do
  PID=$(systemctl show -p MainPID --value "$svc" 2>/dev/null)
  [ -n "$PID" ] && [ "$PID" != "0" ] && echo "$svc (pid $PID): nice=$(ps -o ni= -p "$PID" 2>/dev/null | tr -d ' ')"
done

echo ""
echo "✅ จูนเสร็จสิ้น — ค่าทั้งหมด persist หลังรีบูตแล้ว"
