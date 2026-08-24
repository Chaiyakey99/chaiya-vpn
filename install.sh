#!/bin/bash
# ============================================================
# UDPPRO - ตัวติดตั้งอัตโนมัติ
# วิธีใช้: วางโฟลเดอร์นี้ทั้งหมดไว้ที่ VPS แล้วรัน:
#   sudo bash install.sh
# หลังติดตั้งเสร็จ เปิดเว็บ http://VPS_IP:PORT/setup แล้วกรอก License Key ที่ได้รับ
# ============================================================
set -e

PANEL_DIR="/opt/udppro"
SERVICE_NAME="udppro"
PANEL_PORT="${PANEL_PORT:-8899}"
REPO_URL="https://github.com/Chaiyakey99/chaiya-vpn.git"

echo ">> ติดตั้ง UDPPRO ที่ $PANEL_DIR"

# ถ้ารันแบบ one-liner (bash <(curl ...)) จะมีแค่ไฟล์ install.sh ไฟล์เดียว
# ในโฟลเดอร์ปัจจุบัน ไม่มี requirements.txt/app.py ให้ copy
# กรณีนี้ต้อง clone repo ทั้งหมดมาไว้ในโฟลเดอร์ชั่วคราวก่อน
SRC_DIR="$(pwd)"
if [ ! -f "$SRC_DIR/requirements.txt" ]; then
  echo ">> ไม่พบไฟล์โปรเจกต์ในโฟลเดอร์ปัจจุบัน กำลังดาวน์โหลดจาก GitHub"
  apt-get install -y -qq git >/dev/null 2>&1 || true
  TMP_CLONE_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_CLONE_DIR"' EXIT
  git clone --depth 1 "$REPO_URL" "$TMP_CLONE_DIR"
  SRC_DIR="$TMP_CLONE_DIR"
fi

mkdir -p "$PANEL_DIR"
cp -r "$SRC_DIR"/* "$PANEL_DIR/"
cd "$PANEL_DIR"

echo ">> สร้าง Python venv"
apt-get install -y -qq python3-venv >/dev/null 2>&1 || true
python3 -m venv venv
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q -r requirements.txt

echo ">> สุ่มรหัสผ่าน admin และ secret เฉพาะเครื่องนี้"
# สุ่มใหม่ทุกครั้งที่ลูกค้ารัน install.sh -- แต่ละเครื่องลูกค้าจะไม่ซ้ำกัน
# และไม่ซ้ำกับรหัส admin ของเครื่องผู้ขายเองด้วย
ADMIN_PW=$(python3 -c "import secrets; print(secrets.token_hex(8))")
PANEL_SECRET_VAL=$(python3 -c "import secrets; print(secrets.token_hex(24))")

# ค่านี้ผู้ขายเป็นคนกำหนดไว้ล่วงหน้า เหมือนกันทุกเครื่องที่แพ็กออกไป
LICENSE_SERVER_URL_VAL="https://adminchaiya-udp.cloudzerovps.online"
LICENSE_HMAC_SECRET_VAL="9411b3a184b4553187c329317e8385d87392f99af61fdb23754292843215ffb2"

echo ">> สร้างและติดตั้ง systemd service"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SERVICE_EOF
[Unit]
Description=UDPPRO
After=network.target

[Service]
Type=simple
WorkingDirectory=${PANEL_DIR}
Environment=LICENSE_SERVER_URL=${LICENSE_SERVER_URL_VAL}
Environment=LICENSE_HMAC_SECRET=${LICENSE_HMAC_SECRET_VAL}
Environment=ADMIN_USER=admin
Environment=ADMIN_PASSWORD=${ADMIN_PW}
Environment=PANEL_SECRET=${PANEL_SECRET_VAL}
Environment=PORT=${PANEL_PORT}
ExecStart=${PANEL_DIR}/venv/bin/python3 ${PANEL_DIR}/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE_EOF
chmod 600 "/etc/systemd/system/${SERVICE_NAME}.service"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

sleep 2
systemctl status "$SERVICE_NAME" --no-pager || true

IP=$(curl -s ifconfig.me || echo "YOUR_VPS_IP")

# เก็บรหัสผ่านไว้ให้ดูย้อนหลังได้ (root อ่านได้เท่านั้น)
CRED_FILE="/root/udppro-credentials.txt"
cat > "$CRED_FILE" << CREDEOF
UDPPRO - ข้อมูลเข้าสู่ระบบ (สร้างอัตโนมัติตอนติดตั้ง)
================================================
URL:      http://${IP}:${PANEL_PORT}
Username: admin
Password: ${ADMIN_PW}
================================================
เก็บไฟล์นี้ไว้ให้ดี ห้ามลบ (อยู่ที่ ${CRED_FILE})
CREDEOF
chmod 600 "$CRED_FILE"

echo ""
echo "=================================================="
echo "  ติดตั้งเสร็จแล้ว!"
echo ""
echo "  ขั้นที่ 1: เปิดเว็บนี้เพื่อกรอก License Key ก่อน"
echo "  http://${IP}:${PANEL_PORT}/setup"
echo ""
echo "  ขั้นที่ 2: หลัง activate แล้ว เข้าสู่ระบบด้วย"
echo "  Username: admin"
echo "  Password: ${ADMIN_PW}"
echo ""
echo "  (รหัสผ่านนี้ถูกบันทึกไว้ที่ ${CRED_FILE} แล้ว)"
echo "=================================================="
