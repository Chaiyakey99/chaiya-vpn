#!/bin/bash

echo "🚀 CHAIYA VPN PRO MAX INSTALLER"

ลบของเก่า

rm -rf /usr/local/bin/chaiya*

URL GitHub

BASE_URL="https://raw.githubusercontent.com/Chaiyakey99/chaiya-vpn/main"

รายชื่อไฟล์

FILES=(
chaiya
chaiya-autoban.sh
chaiya-autoblock
chaiya-autokill-cron
chaiya-bughost
chaiya-cpukiller
chaiya-data.sh
chaiya-delete-user
chaiya-gen-page
chaiya-manage-user
chaiya-online
chaiya-reboot-menu
chaiya-setup-xui
chaiya-show-accounts
)

echo "📥 Downloading files..."

เช็ค wget

if ! command -v wget &> /dev/null; then
apt update -y
apt install -y wget
fi

ดาวน์โหลดไฟล์

for file in "${FILES[@]}"; do
echo "⬇️ $file"
wget -q "$BASE_URL/$file" -O "/usr/local/bin/$file"
done

ตั้ง permission

chmod +x /usr/local/bin/chaiya*

echo ""
echo "✅ ติดตั้งสำเร็จ!"
echo "👉 ใช้งานพิมพ์: chaiya"
