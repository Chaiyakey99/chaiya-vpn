#!/bin/bash
DB="/etc/chaiya/vless.db"
DOMAIN_FILE="/etc/chaiya/domain.conf"
BAN_FILE="/etc/chaiya/banned.db"
IP_LOG="/etc/chaiya/iplog.db"
LIMIT_FILE="/etc/chaiya/datalimit.conf"
CONFIG="/usr/local/etc/xray/confs/00_base.json"
MAX_IP=2
BAN_HOURS=24
R1='\033[38;2;255;0;85m'
R2='\033[38;2;255;102;0m'
R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'
R5='\033[38;2;0;204;255m'
R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'
YE='\033[38;2;255;238;0m'
WH='\033[1;37m'
GR='\033[38;2;0;255;68m'
RD='\033[38;2;255;0;85m'
RS='\033[0m'
mkdir -p /etc/chaiya
touch "$DB" "$BAN_FILE" "$IP_LOG" "$LIMIT_FILE"
load_domain() { [[ -f "$DOMAIN_FILE" ]] && DOMAIN=$(cat "$DOMAIN_FILE") || DOMAIN=""; }
format_bytes() {
  local B=$1
  if [[ "$B" -ge 1073741824 ]]; then echo "$(echo "scale=2; $B/1073741824" |
bc) GB"
  elif [[ "$B" -ge 1048576 ]]; then echo "$(echo "scale=2; $B/1048576" | bc)
MB"
  else echo "${B} B"; fi
}
add_uuid_to_xray() {
  local UUID="$1" NAME="$2" PORT="$3" DAYS="$4" DATA_GB="$5"
  python3 -c "
import urllib.request, json, http.cookiejar
from datetime import datetime, timedelta
cfg = json.load(open('/etc/chaiya/xui.conf'))
BASE = cfg['host']+':'+cfg['port']+cfg['path'].rstrip('/')
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))data = json.dumps({'username':cfg['username'],'password':cfg['password']}).encode()
opener.open(urllib.request.Request(BASE+'/login',data=data,headers={'Content-Type':'application/json'}))
inbound_id = cfg['inbound_id_8880'] if '$PORT'=='8880' else cfg['inbound_id_8080']
exp_ms = int((datetime.now()+timedelta(days=int('$DAYS'))).timestamp()*1000)
client_data = {
    'id': inbound_id,
    'settings': json.dumps({'clients':[{
        'id':'$UUID',
        'email':'$NAME',
        'enable':True,
        'flow':'',
        'expiryTime': exp_ms,
        'totalGB': int('$DATA_GB') * 1073741824,
        'limitIp': 2
    }]})
}
req = urllib.request.Request(BASE+'/panel/api/inbounds/addClient',data=json.dumps(client_data).encode(),headers={'Content-Type':'application/json'})
res = opener.open(req)
r = json.loads(res.read())
print('OK' if r.get('success') else 'FAIL:'+r.get('msg',''))
" && printf "${GR}✅  เพิ่ม user สำเร็จ${RS}\n" || printf "${RD}❌  ไม่สำเร็จ${RS}\n"
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
  printf "${R1}  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░${RS}\n"
  printf "${R2}  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗${RS}\n"
  printf "${R3}  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ ${RS}\n"
  printf "${R4}  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║${RS}\n"
  printf "${R5}  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║${RS}\n"
  printf "${R6}  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝${RS}\n"
  printf "\n"
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
  local ONLINE_USERS=$(ss -tn state established 2>/dev/null | grep ":8080" |
wc -l)
  row() {
    local txt="$1"
    local vis=$(echo "$txt" | sed 's/\x1b\[[0-9;]*m//g')
    local pad=$((44 - ${#vis}))
    [[ $pad -lt 0 ]] && pad=0
    printf "${R2}  ||${RS} %s%${pad}s ${YE}||${RS}\n" "$txt" ""
  }
  printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}🔥 V2RAY PRO MAX${RS}")"
  [[ -n "$DOMAIN" ]] && row "$(printf "${PU}🌐 Domain : ${WH}${DOMAIN}${RS}")" || row "$(printf "${PU}⚠️  Domain : ${RD}ยังไม่มีโดเมน${RS}")"
  row "$(printf "${PU}🌍 IP      : ${WH}${MY_IP}${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}💻 OS      : ${WH}${OS_VER}${RS}")"
  row "$(printf "${PU}⏱️  Uptime  : ${WH}${UPTIME_STR}${RS}")"
  row "$(printf "${PU}🖥️  CPU     : ${WH}${CPU_CORES} Core  ${GR}[${CPU_PCT}%%]${RS}")"
  row "$(printf "${PU}🧠 RAM     : ${WH}${RAM_USED} / ${RAM_TOTAL} GB${RS}")"  row "$(printf "${PU}💾 Disk    : ${WH}${DISK_USED} / ${DISK_TOTAL}${RS}")"
  row "$(printf "${PU}📡 Load    : ${WH}${LOAD_AVG}${RS}")"
  row "$(printf "${PU}👥 Users   : ${WH}${TOTAL_USERS} accounts | ${ONLINE_USERS} online${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}1.  ${WH}ติดตั้ง/อัพเดต Xray${RS}")"
  row "$(printf "${PU}2.  ${WH}ตั้งค่าโดเมน + SSL อัตโนมัติ${RS}")"
  row "$(printf "${PU}3.  ${WH}สร้าง VLESS${RS}")"
  row "$(printf "${PU}4.  ${WH}ลบบัญชีหมดอายุ${RS}")"
  row "$(printf "${PU}5.  ${WH}ดูบัญชี${RS}")"
  row "$(printf "${PU}6.  ${WH}ดู User Online Realtime${RS}")"
  row "$(printf "${PU}7.  ${WH}รีสตาร์ท Xray${RS}")"
  row "$(printf "${PU}8.  ${WH}จัดการ Process CPU สูง${RS}")"
  row "$(printf "${PU}9.  ${WH}เช็คความเร็ว VPS${RS}")"
  row "$(printf "${PU}10. ${WH}จัดการ Port (เปิด/ปิด)${RS}")"
  row "$(printf "${PU}11. ${WH}ปลดแบน IP / จัดการ User${RS}")"
  row "$(printf "${PU}12. ${WH}บล็อก IP ต่างประเทศอัตโนมัติ${RS}")"
  row "$(printf "${PU}13. ${WH}สแกน Bug Host (SNI)${RS}")"
  row "$(printf "${PU}14. ${WH}ลบ User${RS}")"
  row "$(printf "${PU}15. ${WH}ตั้งค่ารีบูตอัตโนมัติ${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}0.  ${WH}ออก${RS}")"
  printf "${YE}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"
}
while true; do
  menu; read -r opt; printf "${RS}\n"
  case $opt in
  1)
    clear
    printf "${YE}================================\n${RS}"
    printf "${PU}  ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ${RS}\n"
    printf "${YE}================================\n${RS}"
    read -rp "ตั้งชื่อผู้ใช้ X-UI: " XUI_USER
    [[ -z "$XUI_USER" ]] && { printf "${RD}❌  ไม่ได้ใส่ชื่อ${RS}\n"; read -rp "กด Enter..."; continue; }
    read -rsp "ตั้งรหัสผ่าน X-UI: " XUI_PASS; echo ""
    [[ -z "$XUI_PASS" ]] && { printf "${RD}❌  ไม่ได้ใส่รหัสผ่าน${RS}\n"; read -rp "กด Enter..."; continue; }
    printf "\n${WH}กำลังติดตั้ง 3x-ui...${RS}\n"
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
    printf "\n${WH}กำลังตั้งค่าระบบ...${RS}\n"
    if python3 /usr/local/bin/chaiya-setup-xui "$XUI_USER" "$XUI_PASS"; then
      printf "${GR}✅  ติดตั้งและตั้งค่าเสร็จแล้ว!${RS}\n"
      printf "${PU}X-UI Panel : ${WH}http://$(hostname -I | awk '{print $1}'):2053${RS}\n"
      printf "${PU}กด 3 เพื่อสร้าง VLESS ได้เลยครับ${RS}\n"
    else
      printf "${RD}❌  ติดตั้งไม่สำเร็จ ลองใหม่ครับ${RS}\n"
    fi
    read -rp "กด Enter...";;
  2)
    clear
    printf "${WH}IP: $(hostname -I | awk '{print $1}')${RS}\n"
    read -rp "ใส่โดเมน: " INPUT_DOMAIN
    [[ -z "$INPUT_DOMAIN" ]] && { printf "${RD}❌  ไม่ได้ใส่โดเมน${RS}\n"; read -rp "กด Enter..."; continue; }
    apt update -y && apt install -y nginx certbot python3-certbot-nginx
    cat > /etc/nginx/sites-available/chaiya << NGX
server {
    listen 80;
    server_name ${INPUT_DOMAIN};
    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location / { return 200 'OK'; add_header Content-Type text/plain; }
}
NGX
    ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx
    certbot --nginx -d "$INPUT_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
    if [[ $? -eq 0 ]]; then
      echo "$INPUT_DOMAIN" > "$DOMAIN_FILE"
      printf "${GR}✅  SSL สำเร็จ!${RS}\n"
      (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -
    else
      printf "${RD}❌  SSL ไม่สำเร็จ เช็ค DNS ด้วย${RS}\n"
    fi
    read -rp "กด Enter...";;
  3)
    load_domain; clear
    printf "${YE}================================${RS}\n"
    printf "${PU}  สร้าง VLESS${RS}\n"
    printf "${YE}================================${RS}\n"
    read -rp "ชื่อลูกค้า: " NAME
    [[ ! "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] && { printf "${RD}❌  ใช้ได้เฉพาะ a-z
0-9 _ -${RS}\n"; read -rp "กด Enter..."; continue; }
    read -rp "วันใช้งาน (วัน): " d
    [[ ! "$d" =~ ^[0-9]+$ ]] && { printf "${RD}❌  ใส่ตัวเลขเท่านั้น${RS}\n";
read -rp "กด Enter..."; continue; }
    EXP=$(date -d "+$d days" +"%Y-%m-%d")
    read -rp "Data (GB): " DATA_GB
    [[ ! "$DATA_GB" =~ ^[0-9]+$ ]] && { printf "${RD}❌  ใส่ตัวเลขเท่านั้น${RS}\n"; read -rp "กด Enter..."; continue; }
    printf "\n${PU}เลือก Port:${RS}\n  1. 8880\n  2. 8080\n"
    read -rp "เลือก: " POPT
    [[ "$POPT" == "1" ]] && PORT_LINK=8880 || PORT_LINK=8080
    printf "\n${PU}เลือก SNI:${RS}\n  1. google.com\n  2. x.com\n  3. cj-ebb.speedtest.net\n"
    read -rp "เลือก: " SNIOPT
    case $SNIOPT in 1) SNI="google.com";; 2) SNI="x.com";; *) SNI="cj-ebb.speedtest.net";; esac
    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "$UUID $EXP $NAME" >> "$DB"
    sed -i "/^$UUID /d" "$LIMIT_FILE"; echo "$UUID $DATA_GB" >> "$LIMIT_FILE"    [[ -n "$DOMAIN" ]] && HOST="$DOMAIN" || HOST=$(hostname -I | awk '{print
$1}')
    add_uuid_to_xray "$UUID" "$NAME" "$PORT_LINK" "$d" "$DATA_GB"
    LINK="vless://${UUID}@${HOST}:${PORT_LINK}?type=ws&host=${SNI}&path=/ws&security=none&sni=${SNI}#ChaiyaVPN-${NAME}"
    clear
    printf "${YE}================================${RS}\n"
    printf "${GR}✅  สร้าง VLESS สำเร็จ${RS}\n"
    printf "${YE}================================${RS}\n"
    printf "${PU}ชื่อ    :${RS} ${WH}${NAME}${RS}\n"
    printf "${PU}UUID    :${RS} ${WH}${UUID}${RS}\n"
    printf "${PU}Host    :${RS} ${WH}${HOST}${RS}\n"
    printf "${PU}SNI     :${RS} ${WH}${SNI}${RS}\n"
    printf "${PU}Port    :${RS} ${WH}${PORT_LINK}${RS}\n"
    printf "${PU}Data    :${RS} ${WH}${DATA_GB} GB${RS}\n"
    printf "${PU}หมดอายุ :${RS} ${WH}${EXP}${RS}\n\n"
    python3 /usr/local/bin/chaiya-gen-page "$UUID" "$NAME" "$LINK" "$EXP" "$DATA_GB" 2>/dev/null
    CONFIG_URL=""
    if [[ -n "$DOMAIN" ]]; then
      CONFIG_URL="https://${DOMAIN}/config/${NAME}.html"
    else
      CONFIG_URL="http://$(hostname -I | awk '{print $1}')/config/${NAME}.html"
    fi
    printf "${PU}🌐 ลิงก์ดาวน์โหลด Config:${RS}\n${WH}${CONFIG_URL}${RS}\n"
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
    printf "${GR}✅  ลบ ${REMOVED} บัญชี${RS}\n"; read -rp "กด Enter...";;
  5)
    clear
    python3 /usr/local/bin/chaiya-show-accounts
    read -rp "กด Enter...";;
  6)
    bash /usr/local/bin/chaiya-online
    ;;
  7)
    systemctl is-active --quiet xray && systemctl restart xray && printf "${GR}✅  รีสตาร์ทสำเร็จ${RS}\n" || { systemctl start xray && printf "${GR}✅  เริ่มสำเร็จ${RS}\n"; }
    read -rp "กด Enter...";;
  8)
    bash /usr/local/bin/chaiya-cpukiller
    ;;
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
         [[ ! "$PNUM" =~ ^[0-9]+(/(tcp|udp))?$ ]] && { printf "${RD}❌  รูปแบบผิด${RS}\n"; read -rp "กด Enter..."; continue; }
         command -v ufw &>/dev/null || apt install -y ufw
         ufw status | grep -q "active" || { ufw --force enable; ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; }
         ufw allow "$PNUM"; printf "${GR}✅  เปิด $PNUM แล้ว${RS}\n"; read -rp "กด Enter...";;
      2) read -rp "Port: " PNUM
         [[ ! "$PNUM" =~ ^[0-9]+(/(tcp|udp))?$ ]] && { printf "${RD}❌  รูปแบบผิด${RS}\n"; read -rp "กด Enter..."; continue; }
         [[ "${PNUM%%/*}" == "22" ]] && { printf "${RD}⛔  ปิด Port 22 ไม่ได้${RS}\n"; read -rp "กด Enter..."; continue; }
         ufw delete allow "$PNUM"; printf "${GR}✅  ปิด $PNUM แล้ว${RS}\n"; read -rp "กด Enter...";;
      3) ufw status numbered; ss -tlnpu | awk 'NR>1{print $1,$4,$6}' | column -t; read -rp "กด Enter...";;
      0) break;;
      esac
    done;;
  11)
    python3 /usr/local/bin/chaiya-manage-user
    ;;
  12)
    bash /usr/local/bin/chaiya-autoblock
    ;;
  13)
    bash /usr/local/bin/chaiya-bughost
    ;;
  14)
    python3 /usr/local/bin/chaiya-delete-user
    ;;
  15)
    bash /usr/local/bin/chaiya-reboot-menu
    ;;
  0) printf "${PU}👋 ออก${RS}\n"; exit 0;;
  *) printf "${RD}❌  ไม่ถูกต้อง${RS}\n"; sleep 1;;
  esac
done
root@Chaiyavps-127:/home/chaiya#
