#!/bin/bash

# ============================================================
#   CHAIYA V2RAY PRO MAX - FULL INSTALLER v3
#   ใช้ python3 เขียนทุกไฟล์ หลีกเลี่ยง heredoc ซ้อนทั้งหมด
# ============================================================

echo "🔥 กำลังติดตั้ง CHAIYA V2RAY PRO MAX..."

# ติดตั้ง dependencies
apt update -y
apt install -y curl wget python3 bc qrencode ufw nginx certbot python3-certbot-nginx

# หยุด Apache ถ้ามี
systemctl stop apache2 2>/dev/null
systemctl disable apache2 2>/dev/null

# สร้าง directory
mkdir -p /etc/chaiya /var/log/xray /usr/local/etc/xray/confs

# touch ไฟล์ DB
touch /etc/chaiya/vless.db /etc/chaiya/banned.db /etc/chaiya/iplog.db /etc/chaiya/datalimit.conf

# ติดตั้ง Xray
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) @ latest

# ============================================================
# สร้างทุกไฟล์ด้วย python3 หลีกเลี่ยง heredoc ซ้อนทั้งหมด
# ============================================================
python3 << 'PYEOF'
import json, os, stat, shutil

# --- 1. Xray config ---
config = {
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "api": {"tag": "api", "services": ["HandlerService"]},
  "stats": {},
  "policy": {"system": {}},
  "routing": {
    "rules": [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"}]
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {"address": "127.0.0.1"},
      "tag": "api"
    },
    {
      "port": 8080,
      "protocol": "vless",
      "tag": "vless-in",
      "settings": {"clients": [], "decryption": "none"},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/ws"}}
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
with open("/usr/local/etc/xray/confs/00_base.json", "w") as f:
    json.dump(config, f, indent=2)
shutil.copy("/usr/local/etc/xray/confs/00_base.json", "/usr/local/etc/xray/config.json")
print("✅ Xray config OK")

# --- 2. Xray systemd service ---
svc = """[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray/confs
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
"""
with open("/etc/systemd/system/xray.service", "w") as f:
    f.write(svc)
print("✅ Xray service OK")

# --- 3. chaiya-reload-users script ---
reload = """#!/usr/bin/env python3
import json, subprocess, time, sys

time.sleep(5)

# รอจน xray API พร้อม สูงสุด 30 วินาที
for i in range(15):
    r = subprocess.run(
        ['/usr/local/bin/xray', 'api', 'statsquery', '--server=127.0.0.1:10085'],
        capture_output=True
    )
    if r.returncode == 0:
        break
    time.sleep(2)
else:
    sys.exit(0)

try:
    cfg = json.load(open('/usr/local/etc/xray/confs/00_base.json'))
    for inbound in cfg.get('inbounds', []):
        if inbound.get('protocol') == 'vless':
            for client in inbound['settings']['clients']:
                data = {
                    "inboundTag": "vless-in",
                    "user": {
                        "email": client['email'],
                        "level": 0,
                        "id": client['id']
                    }
                }
                with open('/tmp/chaiya_reload.json', 'w') as f:
                    json.dump(data, f)
                subprocess.run(
                    ['/usr/local/bin/xray', 'api', 'adu',
                     '--server=127.0.0.1:10085', '/tmp/chaiya_reload.json'],
                    capture_output=True
                )
except Exception as e:
    pass
"""
with open("/usr/local/bin/chaiya-reload-users", "w") as f:
    f.write(reload)
os.chmod("/usr/local/bin/chaiya-reload-users", 0o755)
print("✅ chaiya-reload-users OK")

# --- 4. อัพเดต xray service ให้รัน reload-users หลัง start ---
svc2 = """[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray/confs
ExecStartPost=/usr/local/bin/chaiya-reload-users
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
"""
with open("/etc/systemd/system/xray.service", "w") as f:
    f.write(svc2)
print("✅ Xray service with reload-users OK")

# --- 5. Nginx config สำหรับ HTTP ---
nginx_cfg = """server {
    listen 80 default_server;
    server_name _;
    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
"""
with open("/etc/nginx/sites-available/chaiya", "w") as f:
    f.write(nginx_cfg)
try:
    os.symlink("/etc/nginx/sites-available/chaiya", "/etc/nginx/sites-enabled/chaiya")
except FileExistsError:
    os.remove("/etc/nginx/sites-enabled/chaiya")
    os.symlink("/etc/nginx/sites-available/chaiya", "/etc/nginx/sites-enabled/chaiya")
try:
    os.remove("/etc/nginx/sites-enabled/default")
except:
    pass
print("✅ Nginx config OK")

print("✅ ไฟล์ทั้งหมด OK")
PYEOF

# ตั้งค่า UFW
ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8080/tcp
ufw allow 8880/tcp

# เปิด Nginx
systemctl enable nginx
nginx -t && systemctl restart nginx

# สร้าง chaiya script หลัก
python3 << 'PYEOF'
import os

script = r"""#!/bin/bash
DB="/etc/chaiya/vless.db"
DOMAIN_FILE="/etc/chaiya/domain.conf"
BAN_FILE="/etc/chaiya/banned.db"
IP_LOG="/etc/chaiya/iplog.db"
LIMIT_FILE="/etc/chaiya/datalimit.conf"
CONFIG="/usr/local/etc/xray/confs/00_base.json"
MAX_IP=2
BAN_HOURS=24
PU='\033[1;35m'
YE='\033[1;33m'
WH='\033[1;37m'
GR='\033[0;32m'
RD='\033[0;31m'
RS='\033[0m'
mkdir -p /etc/chaiya
touch "$DB" "$BAN_FILE" "$IP_LOG" "$LIMIT_FILE"

load_domain() { [[ -f "$DOMAIN_FILE" ]] && DOMAIN=$(cat "$DOMAIN_FILE") || DOMAIN=""; }

format_bytes() {
  local B=$1
  if [[ "$B" -ge 1073741824 ]]; then echo "$(echo "scale=2; $B/1073741824" | bc) GB"
  elif [[ "$B" -ge 1048576 ]]; then echo "$(echo "scale=2; $B/1048576" | bc) MB"
  else echo "${B} B"; fi
}

add_uuid_to_xray() {
  local UUID="$1" NAME="$2"
  python3 -c "
import json, shutil
path = '$CONFIG'
cfg = json.load(open(path))
for i in cfg.get('inbounds', []):
    if i.get('protocol') == 'vless':
        i['settings']['clients'].append({'id': '$UUID', 'email': '$NAME'})
json.dump(cfg, open(path, 'w'), indent=2)
shutil.copy(path, '/usr/local/etc/xray/config.json')
"
  python3 -c "
import json, subprocess
data = {'inboundTag':'vless-in','user':{'email':'$NAME','level':0,'id':'$UUID'}}
with open('/tmp/chaiya_add.json','w') as f: json.dump(data,f)
r = subprocess.run(['/usr/local/bin/xray','api','adu','--server=127.0.0.1:10085','/tmp/chaiya_add.json'],capture_output=True,text=True)
print(r.stdout.strip() if r.returncode==0 else 'restart')
" | grep -q "restart" && systemctl restart xray || printf "${GR}✅ เพิ่มผ่าน API สำเร็จ${RS}\n"
}

check_ip_limit() {
  local UUID="$1" CLIENT_IP="$2" NOW=$(date +%s)
  if grep -q "^$UUID " "$BAN_FILE"; then
    local BT=$(grep "^$UUID " "$BAN_FILE" | awk '{print $2}')
    if [[ "$NOW" -lt "$((BT + BAN_HOURS * 3600))" ]]; then return 1
    else sed -i "/^$UUID /d" "$BAN_FILE"; sed -i "/^$UUID /d" "$IP_LOG"; fi
  fi
  local CURR=$(grep "^$UUID " "$IP_LOG" | awk '{print $2}')
  echo "$CURR" | grep -q "^$CLIENT_IP$" && return 0
  local CNT=$(echo "$CURR" | grep -c . 2>/dev/null || echo 0)
  if [[ "$CNT" -ge "$MAX_IP" ]]; then
    echo "$UUID $NOW" >> "$BAN_FILE"
    while read -r ip; do
      [[ -n "$ip" ]] && ufw deny from "$ip" to any comment "chaiya-ban-$UUID" 2>/dev/null
    done <<< "$CURR"
    ufw deny from "$CLIENT_IP" to any comment "chaiya-ban-$UUID" 2>/dev/null
    return 1
  fi
  echo "$UUID $CLIENT_IP $(date '+%Y-%m-%d %H:%M:%S')" >> "$IP_LOG"
  return 0
}

scan_and_enforce() {
  [[ ! -f /var/log/xray/access.log ]] && return
  while read -r line; do
    local CIP=$(echo "$line" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
    local UUID=$(echo "$line" | grep -oP '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    [[ -z "$CIP" || -z "$UUID" ]] && continue
    check_ip_limit "$UUID" "$CIP"
  done < /var/log/xray/access.log
}
[[ "$1" == "scan_and_enforce" ]] && { scan_and_enforce; exit 0; }

menu() {
  load_domain; clear
  printf "${PU}"
  printf "  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░\n"
  printf "  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗\n"
  printf "  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ \n"
  printf "  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║\n"
  printf "  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║\n"
  printf "  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝\n"
  printf "${RS}\n"
  local MY_IP=$(hostname -I | awk '{print $1}')
  local OS_VER=$(lsb_release -d 2>/dev/null | awk -F: '{print $2}' | xargs || echo "Linux")
  local UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //' || echo "N/A")
  local CPU_CORES=$(nproc)
  local CPU_PCT=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1 2>/dev/null || echo "?")
  local RAM_USED=$(free -m | awk '/Mem:/{printf "%.1f", $3/1024}')
  local RAM_TOTAL=$(free -m | awk '/Mem:/{printf "%.1f", $2/1024}')
  local DISK_USED=$(df -h / | awk 'NR==2{print $3}')
  local DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
  local LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | xargs)
  local TOTAL_USERS=$(wc -l < "$DB" 2>/dev/null || echo 0)
  local ONLINE_USERS=$(ss -tn state established 2>/dev/null | grep ":8080" | wc -l)
  row() {
    local txt="$1"
    local vis=$(echo "$txt" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$((44 - ${#vis}))
    [[ $pad -lt 0 ]] && pad=0
    printf "${YE}  ||${RS} %s%${pad}s ${YE}||${RS}\n" "$txt" ""
  }
  printf "${YE}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}🔥 V2RAY PRO MAX${RS}")"
  [[ -n "$DOMAIN" ]] && row "$(printf "${PU}🌐 Domain : ${WH}${DOMAIN}${RS}")" || row "$(printf "${PU}⚠️  Domain : ${RD}ยังไม่มีโดเมน${RS}")"
  row "$(printf "${PU}🌍 IP      : ${WH}${MY_IP}${RS}")"
  printf "${YE}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}💻 OS      : ${WH}${OS_VER}${RS}")"
  row "$(printf "${PU}⏱️  Uptime  : ${WH}${UPTIME_STR}${RS}")"
  row "$(printf "${PU}🖥️  CPU     : ${WH}${CPU_CORES} Core  ${GR}[${CPU_PCT}%%]${RS}")"
  row "$(printf "${PU}🧠 RAM     : ${WH}${RAM_USED} / ${RAM_TOTAL} GB${RS}")"
  row "$(printf "${PU}💾 Disk    : ${WH}${DISK_USED} / ${DISK_TOTAL}${RS}")"
  row "$(printf "${PU}📡 Load    : ${WH}${LOAD_AVG}${RS}")"
  row "$(printf "${PU}👥 Users   : ${WH}${TOTAL_USERS} accounts | ${ONLINE_USERS} online${RS}")"
  printf "${YE}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}1.  ${WH}ติดตั้ง/อัพเดต Xray${RS}")"
  row "$(printf "${PU}2.  ${WH}ตั้งค่าโดเมน + SSL อัตโนมัติ${RS}")"
  row "$(printf "${PU}3.  ${WH}สร้าง VLESS${RS}")"
  row "$(printf "${PU}4.  ${WH}ลบบัญชีหมดอายุ${RS}")"
  row "$(printf "${PU}5.  ${WH}ดูบัญชี${RS}")"
  row "$(printf "${PU}6.  ${WH}ดู IP ออนไลน์${RS}")"
  row "$(printf "${PU}7.  ${WH}รีสตาร์ท Xray${RS}")"
  row "$(printf "${PU}8.  ${WH}เช็ค CPU / RAM / Disk${RS}")"
  row "$(printf "${PU}9.  ${WH}เช็คความเร็ว VPS${RS}")"
  row "$(printf "${PU}10. ${WH}จัดการ Port (เปิด/ปิด)${RS}")"
  row "$(printf "${PU}11. ${WH}จัดการแบน IP${RS}")"
  row "$(printf "${PU}12. ${WH}สแกน IP Limit ทันที${RS}")"
  row "$(printf "${PU}13. ${WH}ตั้งค่า Data Limit รายคน${RS}")"
  printf "${YE}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}0.  ${WH}ออก${RS}")"
  printf "${YE}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"
}

while true; do
  menu; read -r opt; printf "${RS}\n"
  case $opt in
  1)
    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) @ latest
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    printf "${GR}✅ ติดตั้ง Xray เสร็จแล้ว${RS}\n"
    read -rp "กด Enter...";;
  2)
    clear
    printf "${WH}IP: $(hostname -I | awk '{print $1}')${RS}\n"
    read -rp "ใส่โดเมน: " INPUT_DOMAIN
    [[ -z "$INPUT_DOMAIN" ]] && { printf "${RD}❌ ไม่ได้ใส่โดเมน${RS}\n"; read -rp "กด Enter..."; continue; }
    apt install -y nginx certbot python3-certbot-nginx
    python3 -c "
txt = open('/etc/nginx/sites-available/chaiya').read()
new = txt.replace('server_name _;', 'server_name $INPUT_DOMAIN;')
open('/etc/nginx/sites-available/chaiya','w').write(new)
"
    nginx -t && systemctl reload nginx
    certbot --nginx -d "$INPUT_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    if [[ $? -eq 0 ]]; then
      echo "$INPUT_DOMAIN" > "$DOMAIN_FILE"
      printf "${GR}✅ SSL สำเร็จ!${RS}\n"
      (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -
    else
      printf "${RD}❌ SSL ไม่สำเร็จ เช็ค DNS ด้วย${RS}\n"
    fi
    read -rp "กด Enter...";;
  3)
    load_domain; clear
    printf "${YE}================================${RS}\n"
    printf "${PU}  สร้าง VLESS${RS}\n"
    printf "${YE}================================${RS}\n"
    read -rp "ชื่อลูกค้า: " NAME
    [[ ! "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { printf "${RD}❌ ใช้ได้เฉพาะ a-z 0-9 _ -${RS}\n"; read -rp "กด Enter..."; continue; }
    read -rp "วันใช้งาน (วัน): " d
    [[ ! "$d" =~ ^[0-9]+$ ]] && { printf "${RD}❌ ใส่ตัวเลขเท่านั้น${RS}\n"; read -rp "กด Enter..."; continue; }
    EXP=$(date -d "+$d days" +"%Y-%m-%d")
    read -rp "Data (GB): " DATA_GB
    [[ ! "$DATA_GB" =~ ^[0-9]+$ ]] && { printf "${RD}❌ ใส่ตัวเลขเท่านั้น${RS}\n"; read -rp "กด Enter..."; continue; }
    printf "\n${PU}เลือก Port:${RS}\n  1. 8880\n  2. 8080\n"
    read -rp "เลือก: " POPT
    [[ "$POPT" == "1" ]] && PORT_LINK=8880 || PORT_LINK=8080
    printf "\n${PU}เลือก SNI:${RS}\n  1. google.com\n  2. x.com\n  3. cj-ebb.speedtest.net\n"
    read -rp "เลือก: " SNIOPT
    case $SNIOPT in 1) SNI="google.com";; 2) SNI="x.com";; *) SNI="cj-ebb.speedtest.net";; esac
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "$UUID $EXP $NAME" >> "$DB"
    sed -i "/^$UUID /d" "$LIMIT_FILE"; echo "$UUID $DATA_GB" >> "$LIMIT_FILE"
    [[ -n "$DOMAIN" ]] && HOST="$DOMAIN" || HOST=$(hostname -I | awk '{print $1}')
    add_uuid_to_xray "$UUID" "$NAME"
    LINK="vless://${UUID}@${HOST}:${PORT_LINK}?type=ws&host=${SNI}&path=/ws&security=none&sni=${SNI}#ChaiyaVPN-${NAME}"
    clear
    printf "${YE}================================${RS}\n"
    printf "${GR}✅ สร้าง VLESS สำเร็จ${RS}\n"
    printf "${YE}================================${RS}\n"
    printf "${PU}ชื่อ    :${RS} ${WH}${NAME}${RS}\n"
    printf "${PU}UUID    :${RS} ${WH}${UUID}${RS}\n"
    printf "${PU}Host    :${RS} ${WH}${HOST}${RS}\n"
    printf "${PU}SNI     :${RS} ${WH}${SNI}${RS}\n"
    printf "${PU}Port    :${RS} ${WH}${PORT_LINK}${RS}\n"
    printf "${PU}Data    :${RS} ${WH}${DATA_GB} GB${RS}\n"
    printf "${PU}หมดอายุ :${RS} ${WH}${EXP}${RS}\n\n"
    printf "${PU}Link:${RS}\n"
    echo "$LINK"
    printf "\n${PU}QR Code:${RS}\n"
    command -v qrencode &>/dev/null || apt install -y qrencode -qq
    qrencode -t ANSIUTF8 "$LINK"
    printf "${YE}================================${RS}\n"
    read -rp "กด Enter...";;
  4)
    TODAY=$(date +"%Y-%m-%d"); REMOVED=0; TMPFILE=$(mktemp)
    while read -r u e n; do
      if [[ "$e" < "$TODAY" ]]; then
        printf "${RD}ลบ: $n (หมดอายุ $e)${RS}\n"
        sed -i "/^$u /d" "$IP_LOG"
        sed -i "/^$u /d" "$BAN_FILE"
        sed -i "/^$u /d" "$LIMIT_FILE"
        python3 -c "
import json, shutil
path = '$CONFIG'
cfg = json.load(open(path))
for i in cfg.get('inbounds', []):
    if i.get('protocol') == 'vless':
        i['settings']['clients'] = [c for c in i['settings']['clients'] if c.get('email') != '$n']
json.dump(cfg, open(path, 'w'), indent=2)
shutil.copy(path, '/usr/local/etc/xray/config.json')
" 2>/dev/null
        ((REMOVED++))
      else
        echo "$u $e $n" >> "$TMPFILE"
      fi
    done < "$DB"
    mv "$TMPFILE" "$DB"
    systemctl restart xray 2>/dev/null
    printf "${GR}✅ ลบ ${REMOVED} บัญชี${RS}\n"; read -rp "กด Enter...";;
  5)
    clear; TODAY=$(date +"%Y-%m-%d")
    printf "${YE}%-15s %-16s %-12s %-10s %-10s${RS}\n" "ชื่อ" "IP" "หมดอายุ" "ใช้แล้ว" "คงเหลือ"
    printf "${YE}================================================================${RS}\n"
    while read -r UUID EXP NAME; do
      IPS=$(grep "^$UUID " "$IP_LOG" | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
      [[ -z "$IPS" ]] && IPS="-"
      [[ "$EXP" < "$TODAY" ]] && EL="X $EXP" || EL="OK $EXP"
      UB=0
      [[ -f /var/log/xray/access.log ]] && UB=$(grep "$UUID" /var/log/xray/access.log | awk '{sum+=$NF} END {print sum+0}')
      LG=$(grep "^$UUID " "$LIMIT_FILE" | awk '{print $2}'); [[ -z "$LG" ]] && LG=30
      RB=$(( LG*1073741824 - UB )); [[ $RB -lt 0 ]] && RB=0
      printf "%-15s %-16s %-12s %-10s %-10s\n" "$NAME" "$IPS" "$EL" "$(format_bytes $UB)" "$(format_bytes $RB)"
    done < "$DB"
    printf "${YE}================================================================${RS}\n"
    read -rp "กด Enter...";;
  6)
    clear
    printf "${PU}%-20s %-10s %s${RS}\n" "IP" "จำนวน" "ชื่อ"
    printf "${YE}================================================${RS}\n"
    if [[ -f /var/log/xray/access.log ]]; then
      grep "from " /var/log/xray/access.log | awk '{
        ip=$4; sub(/:.*/, "", ip)
        email=$NF
        count[ip]++
        user[ip]=email
      } END {
        for (ip in count)
          printf "%-20s %-10s %s\n", ip, count[ip], user[ip]
      }' | sort -k2 -rn
    else
      printf "${RD}❌ ไม่พบ log${RS}\n"
    fi
    printf "${YE}================================================${RS}\n"
    read -rp "กด Enter...";;
  7)
    systemctl is-active --quiet xray && systemctl restart xray && printf "${GR}✅ รีสตาร์ทสำเร็จ${RS}\n" || { systemctl start xray && printf "${GR}✅ เริ่มสำเร็จ${RS}\n"; }
    read -rp "กด Enter...";;
  8)
    printf "${PU}=== Uptime ===${RS}\n"; uptime
    printf "\n${PU}=== RAM ===${RS}\n"; free -h
    printf "\n${PU}=== Disk ===${RS}\n"; df -h /
    read -rp "กด Enter...";;
  9)
    command -v speedtest-cli &>/dev/null || apt install -y speedtest-cli
    speedtest-cli --simple; read -rp "กด Enter...";;
  10)
    while true; do
      clear
      printf "${YE}================================${RS}\n"
      printf "${PU}  จัดการ Port${RS}\n"
      printf "${YE}================================${RS}\n"
      printf "  1. เปิด Port\n  2. ปิด Port\n  3. ดูทั้งหมด\n  0. กลับ\n"
      read -rp "เลือก: " popt
      case $popt in
      1) read -rp "Port: " PNUM
         [[ ! "$PNUM" =~ ^[0-9]+(/(tcp|udp))?$ ]] && { printf "${RD}❌ รูปแบบผิด${RS}\n"; read -rp "กด Enter..."; continue; }
         ufw allow "$PNUM"; printf "${GR}✅ เปิด $PNUM แล้ว${RS}\n"; read -rp "กด Enter...";;
      2) read -rp "Port: " PNUM
         [[ ! "$PNUM" =~ ^[0-9]+(/(tcp|udp))?$ ]] && { printf "${RD}❌ รูปแบบผิด${RS}\n"; read -rp "กด Enter..."; continue; }
         [[ "${PNUM%%/*}" == "22" ]] && { printf "${RD}⛔ ปิด Port 22 ไม่ได้${RS}\n"; read -rp "กด Enter..."; continue; }
         ufw delete allow "$PNUM"; printf "${GR}✅ ปิด $PNUM แล้ว${RS}\n"; read -rp "กด Enter...";;
      3) ufw status numbered; ss -tlnpu | awk 'NR>1{print $1,$4,$6}' | column -t; read -rp "กด Enter...";;
      0) break;;
      esac
    done;;
  11)
    while true; do
      clear
      printf "${YE}================================${RS}\n"
      printf "${PU}  จัดการแบน IP${RS}\n"
      printf "${YE}================================${RS}\n"
      printf "  1. ดูรายการแบน\n  2. ปลดแบนรายคน\n  3. ปลดแบนทั้งหมด\n  0. กลับ\n"
      read -rp "เลือก: " bopt
      case $bopt in
      1)
        i=1
        while read -r UUID BT; do
          NAME=$(grep "^$UUID " "$DB" | awk '{print $3}')
          UNBAN=$(date -d "@$((BT+BAN_HOURS*3600))" '+%Y-%m-%d %H:%M')
          printf "$i. ${NAME:-ไม่ทราบ} | ปลดแบน: $UNBAN\n"; ((i++))
        done < "$BAN_FILE"
        read -rp "กด Enter...";;
      2)
        declare -A BM; i=1
        while read -r UUID BT; do
          NAME=$(grep "^$UUID " "$DB" | awk '{print $3}')
          printf "$i. ${NAME:-ไม่ทราบ} | $UUID\n"; BM[$i]="$UUID"; ((i++))
        done < "$BAN_FILE"
        [[ ${#BM[@]} -eq 0 ]] && { printf "${GR}✅ ไม่มีรายการแบน${RS}\n"; read -rp "กด Enter..."; continue; }
        read -rp "เลือกหมายเลข: " SEL; TU="${BM[$SEL]}"
        [[ -z "$TU" ]] && { printf "${RD}❌ ไม่ถูกต้อง${RS}\n"; read -rp "กด Enter..."; continue; }
        ufw status numbered 2>/dev/null | grep "chaiya-ban-$TU" | awk -F'[][]' '{print $2}' | sort -rn | while read -r rn; do ufw --force delete "$rn" 2>/dev/null; done
        sed -i "/^$TU /d" "$BAN_FILE"; sed -i "/^$TU /d" "$IP_LOG"
        printf "${GR}✅ ปลดแบนสำเร็จ${RS}\n"; read -rp "กด Enter...";;
      3)
        read -rp "ยืนยัน? (y/n): " C
        if [[ "$C" == "y" ]]; then
          ufw status numbered 2>/dev/null | grep "chaiya-ban" | awk -F'[][]' '{print $2}' | sort -rn | while read -r rn; do ufw --force delete "$rn" 2>/dev/null; done
          > "$BAN_FILE"; > "$IP_LOG"
          printf "${GR}✅ ปลดแบนทั้งหมด${RS}\n"
        fi
        read -rp "กด Enter...";;
      0) break;;
      esac
    done;;
  12)
    printf "${PU}สแกน...${RS}\n"; scan_and_enforce; printf "${GR}✅ เสร็จแล้ว${RS}\n"; read -rp "กด Enter...";;
  13)
    while true; do
      clear
      printf "${YE}================================${RS}\n"
      printf "${PU}  Data Limit${RS}\n"
      printf "${YE}================================${RS}\n"
      printf "  1. ตั้ง Default\n  2. ตั้งรายคน\n  3. ดูทั้งหมด\n  0. กลับ\n"
      read -rp "เลือก: " dl
      case $dl in
      1) read -rp "Default GB: " DGB
         [[ ! "$DGB" =~ ^[0-9]+$ ]] && { printf "${RD}❌${RS}\n"; read -rp "กด Enter..."; continue; }
         sed -i "/^DEFAULT /d" "$LIMIT_FILE"; echo "DEFAULT $DGB" >> "$LIMIT_FILE"
         printf "${GR}✅ ตั้ง ${DGB}GB แล้ว${RS}\n"; read -rp "กด Enter...";;
      2) awk '{print NR". "$3}' "$DB"
         read -rp "ชื่อ: " UNAME
         UT=$(grep " $UNAME$" "$DB" | awk '{print $1}')
         [[ -z "$UT" ]] && { printf "${RD}❌ ไม่พบ${RS}\n"; read -rp "กด Enter..."; continue; }
         read -rp "GB: " DGB
         sed -i "/^$UT /d" "$LIMIT_FILE"; echo "$UT $DGB" >> "$LIMIT_FILE"
         printf "${GR}✅ ตั้ง ${DGB}GB สำหรับ ${UNAME}${RS}\n"; read -rp "กด Enter...";;
      3) printf "DEFAULT: $(grep '^DEFAULT ' $LIMIT_FILE | awk '{print $2}' || echo 30) GB\n"
         while read -r UL LL; do
           [[ "$UL" == "DEFAULT" ]] && continue
           NL=$(grep "^$UL " "$DB" | awk '{print $3}')
           printf "${NL:-?} -> ${LL}GB\n"
         done < "$LIMIT_FILE"
         read -rp "กด Enter...";;
      0) break;;
      esac
    done;;
  0) printf "${PU}👋 ออก${RS}\n"; exit 0;;
  *) printf "${RD}❌ ไม่ถูกต้อง${RS}\n"; sleep 1;;
  esac
done
"""

with open("/usr/local/bin/chaiya", "w") as f:
    f.write(script)
os.chmod("/usr/local/bin/chaiya", 0o755)
print("✅ chaiya script OK")
PYEOF

# ตั้ง cron สแกน IP ทุก 5 นาที
(crontab -l 2>/dev/null | grep -v "scan_and_enforce"; echo "*/5 * * * * /usr/local/bin/chaiya scan_and_enforce 2>/dev/null") | crontab -

# เปิด xray
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# รอ xray พร้อม แล้วโหลด users
sleep 8
/usr/local/bin/chaiya-reload-users &

echo ""
echo "✅ ติดตั้ง CHAIYA V2RAY PRO MAX เสร็จแล้ว!"
echo "👉 พิมพ์: chaiya เพื่อเปิดเมนู"
