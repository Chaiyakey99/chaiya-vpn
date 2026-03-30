#!/bin/bash
# ============================================================
#  chaiya_uninstall.sh — ล้างทุกอย่างที่ Chaiya ติดตั้ง
#  คืนค่าเครื่องให้ใกล้เคียงสถานะก่อนติดตั้ง
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

check_root() {
  [[ $EUID -ne 0 ]] && echo -e "${RED}[ERROR] กรุณารันด้วย root${NC}" && exit 1
}

confirm() {
  echo -e "${RED}${BOLD}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  ⚠  CHAIYA UNINSTALL — ลบทุกอย่างที่ติดตั้ง    ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "${YELLOW}สิ่งที่จะถูกลบ:${NC}"
  echo "  • Chaiya scripts และ binaries ทั้งหมด"
  echo "  • x-ui / xray และ config"
  echo "  • nginx (และ config)"
  echo "  • websocat"
  echo "  • dropbear (ถ้าติดตั้ง)"
  echo "  • fail2ban (ถ้าติดตั้ง)"
  echo "  • /etc/chaiya/ ทั้งโฟลเดอร์"
  echo "  • /var/www/chaiya/ ทั้งโฟลเดอร์"
  echo "  • systemd services ของ chaiya ทั้งหมด"
  echo "  • cron jobs ของ chaiya ทั้งหมด"
  echo "  • ufw rules ที่เพิ่มโดย chaiya"
  echo ""
  echo -e "${GREEN}สิ่งที่จะไม่ถูกลบ:${NC}"
  echo "  • python3, curl, wget, git (system tools)"
  echo "  • SSH port 22 (ยังเข้าได้อยู่)"
  echo "  • ufw (ตัว firewall เอง)"
  echo "  • user accounts ของระบบ (root ฯลฯ)"
  echo ""
  read -rp "$(echo -e ${RED})พิมพ์ YES เพื่อยืนยัน หรือ Enter เพื่อยกเลิก: $(echo -e ${NC})" ans
  [[ "$ans" != "YES" ]] && echo "ยกเลิกแล้วครับ" && exit 0
}

step() { echo -e "\n${CYAN}[*]${NC} $1"; }
ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
skip() { echo -e "  ${YELLOW}—${NC} $1 (ไม่พบ ข้ามไป)"; }

# ── 1. หยุด services ────────────────────────────────────────
stop_services() {
  step "หยุด services ทั้งหมด..."
  local svcs=(
    chaiya-sshws chaiya-sshws-api chaiya-dropbear
    chaiya-iplimit ws-ssh x-ui xray nginx fail2ban dropbear
  )
  for svc in "${svcs[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl stop "$svc" 2>/dev/null
      ok "stop $svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      systemctl disable "$svc" 2>/dev/null
    fi
  done
}

# ── 2. ลบ systemd unit files ────────────────────────────────
remove_systemd() {
  step "ลบ systemd unit files..."
  local units=(
    /etc/systemd/system/chaiya-sshws.service
    /etc/systemd/system/chaiya-sshws-api.service
    /etc/systemd/system/chaiya-dropbear.service
    /etc/systemd/system/chaiya-iplimit.service
    /etc/systemd/system/ws-ssh.service
    /etc/systemd/system/x-ui.service
    /etc/systemd/system/xray.service
  )
  for f in "${units[@]}"; do
    if [[ -f "$f" ]]; then rm -f "$f"; ok "ลบ $f"; else skip "$f"; fi
  done
  systemctl daemon-reload
  ok "daemon-reload"
}

# ── 3. ลบ packages ──────────────────────────────────────────
remove_packages() {
  step "ถอน packages..."
  local pkgs=(nginx dropbear fail2ban)
  for pkg in "${pkgs[@]}"; do
    if dpkg -l "$pkg" &>/dev/null; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" 2>/dev/null
      ok "purge $pkg"
    else
      skip "$pkg"
    fi
  done
  apt-get autoremove -y -qq 2>/dev/null
  ok "autoremove"
}

# ── 4. ลบ x-ui / xray ──────────────────────────────────────
remove_xui() {
  step "ลบ x-ui และ xray..."
  # x-ui uninstall script
  if command -v x-ui &>/dev/null; then
    x-ui uninstall 2>/dev/null || true
    ok "x-ui uninstall"
  else
    skip "x-ui"
  fi
  # ลบไฟล์ที่เหลือ
  local xui_paths=(
    /usr/local/x-ui
    /usr/local/bin/x-ui
    /etc/x-ui
    /var/log/x-ui
    /usr/local/bin/xray
    /usr/local/etc/xray
    /var/log/xray
    /etc/systemd/system/x-ui.service
    /etc/systemd/system/xray.service
  )
  for p in "${xui_paths[@]}"; do
    if [[ -e "$p" ]]; then rm -rf "$p"; ok "ลบ $p"; fi
  done
}

# ── 5. ลบ websocat ──────────────────────────────────────────
remove_websocat() {
  step "ลบ websocat..."
  if [[ -f /usr/local/bin/websocat ]]; then
    rm -f /usr/local/bin/websocat
    ok "ลบ websocat"
  else
    skip "websocat"
  fi
}

# ── 6. ลบ chaiya binaries ───────────────────────────────────
remove_binaries() {
  step "ลบ chaiya scripts และ binaries..."
  local bins=(
    chaiya chaiya-sshws chaiya-sshws-api chaiya-sshws-nginx-setup
    chaiya-setup-xui chaiya-gen-page chaiya-show-accounts
    chaiya-user-manager chaiya-manage-user chaiya-delete-user
    chaiya-online chaiya-autoblock chaiya-bughost chaiya-cpukiller
    chaiya-reboot-menu chaiya-iplimit chaiya-datalimit chaiya-splash
    chaiya-autokill-cron
  )
  for bin in "${bins[@]}"; do
    local p="/usr/local/bin/$bin"
    if [[ -f "$p" ]]; then rm -f "$p"; ok "ลบ $p"; else skip "$bin"; fi
  done
}

# ── 7. ลบ config และ data directories ──────────────────────
remove_dirs() {
  step "ลบ directories..."
  local dirs=(
    /etc/chaiya
    /var/www/chaiya
    /var/log/chaiya-sshws.log
    /var/log/chaiya-iplimit.log
    /var/log/chaiya-datalimit.log
    /var/log/chaiya-autokill.log
  )
  for d in "${dirs[@]}"; do
    if [[ -e "$d" ]]; then rm -rf "$d"; ok "ลบ $d"; else skip "$d"; fi
  done
}

# ── 8. ล้าง cron jobs ───────────────────────────────────────
remove_crons() {
  step "ล้าง cron jobs ของ chaiya..."
  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -v "chaiya" > "$tmp" || true
  crontab "$tmp" 2>/dev/null
  rm -f "$tmp"
  ok "ล้าง crontab แล้ว"
}

# ── 9. ล้าง nginx config ─────────────────────────────────────
remove_nginx_config() {
  step "ล้าง nginx config..."
  rm -f /etc/nginx/sites-available/chaiya
  rm -f /etc/nginx/sites-enabled/chaiya
  # restore default ถ้ามี
  if [[ -f /etc/nginx/sites-available/default ]]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null
  fi
  ok "ล้าง nginx config"
}

# ── 10. ล้าง UFW rules ──────────────────────────────────────
remove_ufw() {
  step "ล้าง UFW rules ของ chaiya (พอร์ต 80, 81, 443, 2053, 2082, 6789, 8080, 8880, 8090)..."
  local ports=(80 81 443 2053 2082 2222 6789 8080 8090 8880)
  for p in "${ports[@]}"; do
    ufw delete allow "$p/tcp" 2>/dev/null && ok "ลบ rule $p/tcp" || true
  done
  # port 22 ยังคงไว้ให้ SSH เข้าได้
  ufw allow 22/tcp 2>/dev/null
  ok "คง port 22 ไว้"
}

# ── 11. ลบ swap ที่สร้างเพิ่ม (ถ้ามี) ─────────────────────
remove_swap() {
  step "ตรวจ swap file..."
  if [[ -f /swapfile ]]; then
    swapoff /swapfile 2>/dev/null
    rm -f /swapfile
    # ลบออกจาก /etc/fstab
    sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null
    ok "ลบ swapfile"
  else
    skip "swapfile"
  fi
}

# ── 12. ล้าง pip packages ────────────────────────────────────
remove_pip() {
  step "ลบ pip packages ที่ chaiya ติดตั้ง..."
  pip3 uninstall -y bcrypt 2>/dev/null && ok "uninstall bcrypt" || skip "bcrypt"
}

# ── 13. สรุปผล ───────────────────────────────────────────────
summary() {
  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  ✅  ล้างเสร็จแล้ว!                             ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  ${CYAN}สถานะ:${NC}"
  echo "  • SSH port 22 : ยังใช้ได้ปกติ"
  echo "  • ufw         : ยังทำงานอยู่ (เฉพาะ port 22)"
  echo "  • python3     : ยังอยู่"
  echo "  • curl/wget   : ยังอยู่"
  echo ""
  echo -e "  ${YELLOW}แนะนำ:${NC} reboot เครื่องสักครั้งให้ทุกอย่าง clean"
  echo ""
  read -rp "  Reboot เลยไหม? (y/n): " rb
  [[ "$rb" == "y" || "$rb" == "Y" ]] && reboot
}

# ── Main ─────────────────────────────────────────────────────
check_root
confirm
stop_services
remove_systemd
remove_packages
remove_xui
remove_websocat
remove_binaries
remove_dirs
remove_crons
remove_nginx_config
remove_ufw
remove_swap
remove_pip
summary
