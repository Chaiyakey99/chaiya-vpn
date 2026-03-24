#!/bin/bash
# ============================================================
#   CHAIYA V2RAY PRO MAX - FULL INSTALLER v4 (fixed)
#   Repacked from reviewed payloads with installer fixes
# ============================================================

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "กรุณารันสคริปต์นี้ด้วย root หรือ sudo"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "🔥 กำลังติดตั้ง CHAIYA V2RAY PRO MAX v4 (fixed)..."
apt update -y -qq
apt install -y \
  curl wget python3 bc qrencode ufw nginx certbot python3-certbot-nginx \
  python3-pip fail2ban cron sqlite3 iputils-ping ca-certificates

systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true
rm -f /etc/systemd/system/xray.service /usr/local/bin/xray /usr/local/bin/chaiya-reload-users
rm -rf /usr/local/etc/xray /var/log/xray
systemctl daemon-reload 2>/dev/null || true
mkdir -p /etc/chaiya /var/www/chaiya/config
touch /etc/chaiya/vless.db /etc/chaiya/banned.db /etc/chaiya/iplog.db /etc/chaiya/datalimit.conf

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8080/tcp
ufw allow 8880/tcp
ufw allow 2053/tcp
ufw --force enable

pip3 install py3xui --break-system-packages -q 2>/dev/null || true

cat > /etc/nginx/sites-available/chaiya <<'NGINX_CONF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/chaiya;

    location /config/ {
        alias /var/www/chaiya/config/;
        try_files $uri =404;
    }

    location /ws {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_set_header Host $host;
    }

    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINX_CONF

ln -sf /etc/nginx/sites-available/chaiya /etc/nginx/sites-enabled/chaiya
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable nginx && systemctl restart nginx
systemctl enable cron 2>/dev/null || true
systemctl restart cron 2>/dev/null || true

echo "✅ ติดตั้ง chaiya-autoblock..."
cat > /usr/local/bin/chaiya-autoblock <<'EOF_CHAIYA_AUTOBLOCK'
#!/bin/bash
R1='\033[38;2;255;0;85m'; R2='\033[38;2;255;102;0m'; R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'; R5='\033[38;2;0;204;255m'; R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'; YE='\033[38;2;255;238;0m'; WH='\033[1;37m'
GR='\033[38;2;0;255;68m'; RD='\033[38;2;255;0;85m'; RS='\033[0m'
row(){ local txt="$1" vis=$(echo "$1"|sed 's/\x1b\[[0-9;]*m//g') pad=$((44-${#vis})); [[ $pad -lt 0 ]] && pad=0; printf "${R2}  ||${RS} %s%${pad}s ${R2}||${RS}\n" "$txt" ""; }
logo(){ printf "${R1}  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░${RS}\n"; printf "${R2}  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗${RS}\n"; printf "${R3}  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ ${RS}\n"; printf "${R4}  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║${RS}\n"; printf "${R5}  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║${RS}\n"; printf "${R6}  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝${RS}\n\n"; }
get_status(){ systemctl is-active --quiet fail2ban && echo "on" || echo "off"; }
get_banned(){ fail2ban-client status 2>/dev/null|grep -oP 'Jail list:\s*\K.*'|tr ',' '\n'|while read j; do j=$(echo "$j"|xargs); [[ -z "$j" ]] && continue; fail2ban-client status "$j" 2>/dev/null|grep "Currently banned"|awk '{print $NF}'; done|awk '{s+=$1} END {print s+0}'; }
while true; do
  clear; logo
  STATUS=$(get_status); BANNED=$(get_banned); TODAY=$(grep "Ban " /var/log/fail2ban.log 2>/dev/null|grep "$(date +%Y-%m-%d)"|wc -l)
  [[ "$STATUS" == "on" ]] && BADGE="${GR}● เปิดทำงาน${RS}" || BADGE="\033[0;37m○ ปิดทำงาน\033[0m"
  printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}🛡️  บล็อก IP ต่างประเทศอัตโนมัติ${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}📡 สถานะ : ${RS}${BADGE}")"; row "$(printf "${PU}🔒 IP บล็อก : ${RD}${BANNED} IP${RS}")"; row "$(printf "${PU}⚡ วันนี้ : ${YE}${TODAY} IP${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}1.  ${GR}เปิดใช้งานบล็อก IP อัตโนมัติ${RS}")"; row "$(printf "${PU}2.  ${RD}ปิดใช้งานบล็อก IP อัตโนมัติ${RS}")"; row "$(printf "${PU}3.  ${WH}แสดง IP ที่บล็อก${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"; row "$(printf "${PU}0.  ${WH}กลับ${RS}")"
  printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"; read -r opt; printf "${RS}\n"
  case $opt in
  1) command -v fail2ban-client &>/dev/null || apt install -y fail2ban; systemctl enable fail2ban && systemctl restart fail2ban; printf "  ${GR}✅ เปิดแล้ว${RS}\n"; read -rp "  กด Enter...";;
  2) systemctl stop fail2ban; systemctl disable fail2ban; printf "  ${RD}✅ ปิดแล้ว${RS}\n"; read -rp "  กด Enter...";;
  3) clear; logo
     printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
     row "$(printf "${PU}🔴 IP ที่บล็อก เรียงจากยิงเยอะสุด${RS}")"
     printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
     fail2ban-client status 2>/dev/null|grep -oP 'Jail list:\s*\K.*'|tr ',' '\n'|while read j; do j=$(echo "$j"|xargs); [[ -z "$j" ]]&&continue; fail2ban-client status "$j" 2>/dev/null|grep "Banned IP list"|sed 's/.*Banned IP list://';done|tr ' ' '\n'|grep -v '^$'|sort|uniq -c|sort -rn|head -20|while read count ip; do [[ -z "$ip" ]]&&continue; [[ $count -gt 500 ]]&&C="${RD}"||([[ $count -gt 100 ]]&&C="${YE}"||C="\033[0;37m"); printf "${R6}  ||${RS} ${C}%-18s${RS} ${WH}%s ครั้ง${RS}\n" "$ip" "$count"; done
     printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n"; read -rp "  กด Enter...";;
  0) break;;
  *) printf "  ${RD}❌${RS}\n"; sleep 1;;
  esac
done

EOF_CHAIYA_AUTOBLOCK
chmod +x /usr/local/bin/chaiya-autoblock

echo "✅ ติดตั้ง chaiya-bughost..."
cat > /usr/local/bin/chaiya-bughost <<'EOF_CHAIYA_BUGHOST'
#!/bin/bash
R1='\033[38;2;255;0;85m'; R2='\033[38;2;255;102;0m'; R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'; R5='\033[38;2;0;204;255m'; R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'; YE='\033[38;2;255;238;0m'; WH='\033[1;37m'
GR='\033[38;2;0;255;68m'; RD='\033[38;2;255;0;85m'; CY='\033[38;2;0;204;255m'; RS='\033[0m'
BHC="/etc/chaiya/bughost.conf"; SPC="/etc/chaiya/scanport.conf"; touch "$BHC" "$SPC"
get_bh(){ [[ -f "$BHC" ]]&&cat "$BHC"||echo "cj-ebb.speedtest.net"; }
get_ports(){ [[ -f "$SPC" ]]&&cat "$SPC"||echo "80 8080"; }
row(){ local txt="$1" vis=$(echo "$1"|sed 's/\x1b\[[0-9;]*m//g') pad=$((44-${#vis})); [[ $pad -lt 0 ]]&&pad=0; printf "${R2}  ||${RS} %s%${pad}s ${R2}||${RS}\n" "$txt" ""; }
logo(){ printf "${R1}  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░${RS}\n"; printf "${R2}  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗${RS}\n"; printf "${R3}  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ ${RS}\n"; printf "${R4}  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║${RS}\n"; printf "${R5}  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║${RS}\n"; printf "${R6}  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝${RS}\n\n"; }

scan_bh(){
  local BH=$(get_bh); local PORTS=$(get_ports)
  clear; logo; printf "  ${WH}กำลังสแกน...${RS}\n\n"
  HOSTS=("$BH" "google.com" "x.com" "fast.com" "speedtest.net" "www.speedtest.net" "cj-ebb.speedtest.net" "facebook.com" "instagram.com" "youtube.com" "cloudflare.com" "apple.com" "microsoft.com")
  declare -a FH FP FPG
  for host in "${HOSTS[@]}"; do
    PING_MS=$(ping -c 1 -W 1 "$host" 2>/dev/null|grep -oP 'time=\K[0-9.]+'|head -1)
    [[ -z "$PING_MS" ]]&&continue; OPEN=""
    for port in $PORTS; do timeout 1 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null&&OPEN="$OPEN[$port] "; done
    [[ -z "$OPEN" ]]&&continue; FH+=("$host"); FP+=("$OPEN"); FPG+=("$PING_MS")
  done
  clear; logo
  printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}✅ Bug Host ที่ปิงติดและพอร์ตเปิด${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  printf "${R3}  ||${RS}  ${YE}%-4s %-22s %-12s %s${RS}    ${R3}||${RS}\n" "No." "Host" "Port" "Ping"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  if [[ ${#FH[@]} -eq 0 ]]; then row "$(printf "${RD}❌ ไม่พบ Bug Host${RS}")";
  else
    for i in "${!FH[@]}"; do
      ms_int=${FPG[$i]%.*}
      [[ $ms_int -lt 20 ]]&&PC="${GR}"||([[ $ms_int -lt 80 ]]&&PC="${YE}"||PC="${RD}")
      printf "${R6}  ||${RS}  ${YE}%-4s${RS} ${WH}%-22s${RS} ${CY}%-12s${RS} ${PC}%sms${RS}    ${R6}||${RS}\n" "$((i+1))." "${FH[$i]:0:20}" "${FP[$i]}" "${FPG[$i]}"
    done
  fi
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${WH}ใส่เลขเพื่อบันทึก Bug Host หลัก หรือ Enter กลับ${RS}")"
  printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"; read -r sel; printf "${RS}\n"
  if [[ "$sel" =~ ^[0-9]+$ ]]&&[[ "$sel" -ge 1 ]]&&[[ "$sel" -le "${#FH[@]}" ]]; then
    echo "${FH[$((sel-1))]}" > "$BHC"; printf "  ${GR}✅ บันทึก Bug Host: ${YE}${FH[$((sel-1))]}${RS}\n"; read -rp "  กด Enter..."
  fi
}

while true; do
  clear; logo; BH=$(get_bh); PORTS=$(get_ports); PB=""; for p in $PORTS; do PB="${PB}[${p}] "; done
  printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}🔍 สแกน Bug Host (SNI/Host Header)${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}🌐 Bug Host : ${YE}${BH}${RS}")"; row "$(printf "${PU}🔌 Port     : ${CY}${PB}${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}1.  ${WH}ใส่ Bug Host ตั้งต้น${RS}")"; row "$(printf "${PU}2.  ${WH}เลือก Port สแกน${RS}")"; row "$(printf "${PU}3.  ${GR}สแกนและแสดงผล${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"; row "$(printf "${PU}0.  ${WH}กลับ${RS}")"
  printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"; read -r opt; printf "${RS}\n"
  case $opt in
  1) read -rp "  Bug Host: " NB; [[ -n "$NB" ]]&&{ echo "$NB">"$BHC"; printf "  ${GR}✅ บันทึกแล้ว${RS}\n"; }; read -rp "  กด Enter...";;
  2) printf "  1.Port 80\n  2.Port 8080\n  3.ทั้งคู่\n"; printf "  ${PU}เลือก >> ${WH}"; read -r p; printf "${RS}\n"
     case $p in 1) echo "80">"$SPC";; 2) echo "8080">"$SPC";; 3) echo "80 8080">"$SPC";; esac
     printf "  ${GR}✅ บันทึกแล้ว${RS}\n"; read -rp "  กด Enter...";;
  3) scan_bh;;
  0) break;;
  *) printf "  ${RD}❌${RS}\n"; sleep 1;;
  esac
done

EOF_CHAIYA_BUGHOST
chmod +x /usr/local/bin/chaiya-bughost

echo "✅ ติดตั้ง chaiya-cpukiller..."
cat > /usr/local/bin/chaiya-cpukiller <<'EOF_CHAIYA_CPUKILLER'
#!/bin/bash
R1='\033[38;2;255;0;85m'; R2='\033[38;2;255;102;0m'; R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'; R5='\033[38;2;0;204;255m'; R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'; YE='\033[38;2;255;238;0m'; WH='\033[1;37m'
GR='\033[38;2;0;255;68m'; RD='\033[38;2;255;0;85m'; RS='\033[0m'
THRESHOLD_CONF="/etc/chaiya/cpu_threshold.conf"; AUTOKILL_CONF="/etc/chaiya/autokill.conf"
WHITELIST="xray nginx x-ui fail2ban sshd systemd kernel python3"
touch "$THRESHOLD_CONF" "$AUTOKILL_CONF"
get_threshold() { [[ -f "$THRESHOLD_CONF" ]] && cat "$THRESHOLD_CONF" || echo "80"; }
get_autokill() { [[ -f "$AUTOKILL_CONF" ]] && cat "$AUTOKILL_CONF" || echo "off"; }
is_whitelisted() { local p="$1"; for w in $WHITELIST; do echo "$p"|grep -qi "$w" && return 0; done; return 1; }
show_logo() {
  printf "${R1}  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░${RS}\n"
  printf "${R2}  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗${RS}\n"
  printf "${R3}  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ ${RS}\n"
  printf "${R4}  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║${RS}\n"
  printf "${R5}  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║${RS}\n"
  printf "${R6}  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝${RS}\n\n"
}
row() {
  local txt="$1"; local vis=$(echo "$txt"|sed 's/\x1b\[[0-9;]*m//g'); local pad=$((44-${#vis}))
  [[ $pad -lt 0 ]] && pad=0; printf "${R2}  ||${RS} %s%${pad}s ${R2}||${RS}\n" "$txt" ""
}
cpu_bar() {
  local PCT=$1; local W=10; local F=$(( PCT * W / 100 ))
  [[ $F -gt $W ]] && F=$W; local E=$(( W - F ))
  if [[ $PCT -ge 80 ]]; then C="${RD}"; elif [[ $PCT -ge 50 ]]; then C="${YE}"; else C="${GR}"; fi
  printf "${C}%s${RS}%s" "$(printf '█%.0s' $(seq 1 $F 2>/dev/null))" "$(printf '░%.0s' $(seq 1 $E 2>/dev/null))"
}
setup_autokill_cron() {
  local T=$(get_threshold); local WL=$(echo "$WHITELIST"|tr ' ' '|')
  CRON_SCRIPT="/usr/local/bin/chaiya-autokill-cron"
  printf '#!/bin/bash\nTHRESHOLD=%s\nps aux --no-headers | awk '"'"'{print $2, $3, $11}'"'"' | sort -k2 -rn | while read pid cpu proc; do\n  cpu_int=${cpu%%.*}\n  [[ $cpu_int -lt $THRESHOLD ]] && continue\n  echo "$proc" | grep -qiE "%s" && continue\n  kill -9 "$pid" 2>/dev/null && echo "$(date): Killed PID $pid ($proc)" >> /var/log/chaiya-autokill.log\ndone\n' "$T" "$WL" > "$CRON_SCRIPT"
  chmod +x "$CRON_SCRIPT"
  (crontab -l 2>/dev/null|grep -v "chaiya-autokill-cron"; echo "* * * * * $CRON_SCRIPT")|crontab -
}
while true; do
  clear; show_logo
  THRESHOLD=$(get_threshold); AUTOKILL=$(get_autokill)
  CPU_CORES=$(nproc); CPU_PCT=$(top -bn1|grep "Cpu(s)"|awk '{print 100-$8}'|cut -d. -f1 2>/dev/null||echo "0")
  RAM_USED=$(free -m|awk '/Mem:/{printf "%.1f",$3/1024}'); RAM_TOTAL=$(free -m|awk '/Mem:/{printf "%.1f",$2/1024}')
  [[ "$AUTOKILL" == "on" ]] && BADGE="${GR}● เปิดทำงาน${RS}" || BADGE="\033[0;37m○ ปิดทำงาน\033[0m"
  printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}⚡ จัดการ Process กิน CPU สูง${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}🖥️  CPU : ${WH}${CPU_CORES} Core${RS}  $(cpu_bar $CPU_PCT) ${WH}${CPU_PCT}%%${RS}")"
  row "$(printf "${PU}🧠 RAM : ${WH}${RAM_USED}/${RAM_TOTAL} GB${RS}")"
  row "$(printf "${PU}🛡️  Auto Kill   : ${RS}${BADGE}")"
  row "$(printf "${PU}⚠️  Threshold   : ${YE}${THRESHOLD}%% CPU${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  printf "${R3}  ||${RS}  ${YE}%-8s %-18s %-8s %s${RS}   ${R3}||${RS}\n" "PID" "Process" "CPU%" "สถานะ"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  ps aux --no-headers|awk '{print $2,$3,$11}'|sort -k2 -rn|head -6|while read -r pid cpu proc; do
    ci=${cpu%.*}; ps="${proc##*/}"; ps="${ps:0:16}"
    if [[ $ci -ge 80 ]]; then ST="${RD}🔴 อันตราย${RS}"; PC="${RD}"
    elif [[ $ci -ge 50 ]]; then ST="${YE}🟡 สูง${RS}"; PC="${YE}"
    else ST="${GR}🟢 ปกติ${RS}"; PC="${GR}"; fi
    printf "${R6}  ||${RS}  ${WH}%-8s${RS} ${PC}%-18s${RS} $(cpu_bar $ci) ${PC}%-6s${RS} %s  ${R6}||${RS}\n" "$pid" "$ps" "${cpu}%" "$ST"
  done
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}1.  ${GR}เปิด Auto Kill Process${RS}")"
  row "$(printf "${PU}2.  ${RD}ปิด Auto Kill Process${RS}")"
  row "$(printf "${PU}3.  ${WH}ตั้ง Threshold CPU%% (ปัจจุบัน ${THRESHOLD}%%)${RS}")"
  row "$(printf "${PU}4.  ${RD}ฆ่า Process เกิน Threshold ทันที${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}0.  ${WH}กลับเมนูหลัก${RS}")"
  printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"; read -r opt; printf "${RS}\n"
  case $opt in
  1) echo "on" > "$AUTOKILL_CONF"; setup_autokill_cron
     printf "  ${GR}✅ เปิด Auto Kill แล้ว${RS}\n"; read -rp "  กด Enter...";;
  2) echo "off" > "$AUTOKILL_CONF"; crontab -l 2>/dev/null|grep -v "chaiya-autokill-cron"|crontab -
     printf "  ${RD}✅ ปิด Auto Kill แล้ว${RS}\n"; read -rp "  กด Enter...";;
  3) read -rp "  ตั้ง Threshold CPU% (1-99): " NEW_T
     if [[ "$NEW_T" =~ ^[0-9]+$ ]] && [[ "$NEW_T" -ge 1 ]] && [[ "$NEW_T" -le 99 ]]; then
       echo "$NEW_T" > "$THRESHOLD_CONF"; [[ "$(get_autokill)" == "on" ]] && setup_autokill_cron
       printf "  ${GR}✅ ตั้ง Threshold ${NEW_T}%% แล้ว${RS}\n"
     else printf "  ${RD}❌ ใส่ตัวเลข 1-99 เท่านั้น${RS}\n"; fi
     read -rp "  กด Enter...";;
  4) THRESHOLD=$(get_threshold); printf "  ${RD}💀 กำลังฆ่า Process ที่เกิน ${THRESHOLD}%%...${RS}\n"; KILLED=0
     ps aux --no-headers|awk '{print $2,$3,$11}'|sort -k2 -rn|while read pid cpu proc; do
       ci=${cpu%.*}; [[ $ci -lt $THRESHOLD ]] && continue
       is_whitelisted "$proc" && continue
       kill -9 "$pid" 2>/dev/null && printf "  ${RD}💀 ฆ่า PID $pid ($proc)${RS}\n"
     done
     printf "  ${GR}✅ เสร็จแล้ว${RS}\n"; read -rp "  กด Enter...";;
  0) break;;
  *) printf "  ${RD}❌ ไม่ถูกต้อง${RS}\n"; sleep 1;;
  esac
done

EOF_CHAIYA_CPUKILLER
chmod +x /usr/local/bin/chaiya-cpukiller

echo "✅ ติดตั้ง chaiya-delete-user..."
cat > /usr/local/bin/chaiya-delete-user <<'EOF_CHAIYA_DELETE_USER'
#!/usr/bin/env python3
import json, os, urllib.request, http.cookiejar
from datetime import datetime

PU="\033[38;2;204;68;255m"; YE="\033[38;2;255;238;0m"; WH="\033[1;37m"
GR="\033[38;2;0;255;68m"; RD="\033[38;2;255;0;85m"; CY="\033[38;2;0;204;255m"
R1="\033[38;2;255;0;85m"; R3="\033[38;2;255;238;0m"; R6="\033[38;2;204;68;255m"
RS="\033[0m"

def xui_login():
    cfg=json.load(open("/etc/chaiya/xui.conf"))
    BASE=cfg["host"]+":"+cfg["port"]+cfg["path"].rstrip("/")
    jar=http.cookiejar.CookieJar()
    opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    data=json.dumps({"username":cfg["username"],"password":cfg["password"]}).encode()
    opener.open(urllib.request.Request(BASE+"/login",data=data,headers={"Content-Type":"application/json"}))
    return opener,BASE

def get_clients(opener,BASE):
    res=opener.open(BASE+"/panel/api/inbounds/list")
    inbounds=json.loads(res.read())["obj"]
    clients=[]
    for inbound in inbounds:
        settings=json.loads(inbound["settings"])
        cs_map={cs["email"]:cs for cs in (inbound.get("clientStats") or [])}
        for client in settings.get("clients",[]):
            email=client.get("email","") or ""
            if not email: continue
            uid=client.get("id",""); cs=cs_map.get(email,{})
            exp=client.get("expiryTime",0) or 0; total=cs.get("total",0) or 0
            if exp>0:
                days=(datetime.fromtimestamp(exp/1000)-datetime.now()).days
                exp_str=f"{RD}❌ หมดอายุ{RS}" if days<0 else f"{GR}✅ {days} วัน{RS}"
            else: exp_str=f"{WH}-{RS}"
            clients.append({"email":email,"id":uid,"inbound_id":inbound["id"],"exp_str":exp_str,"total":total})
    return clients

def delete_client(opener,BASE,inbound_id,uid):
    req=urllib.request.Request(f"{BASE}/panel/api/inbounds/{inbound_id}/delClient/{uid}",
        method="POST",headers={"Content-Type":"application/json"})
    try:
        res=opener.open(req); r=json.loads(res.read()); return r.get("success",False)
    except: return False

def main():
    try: opener,BASE=xui_login(); clients=get_clients(opener,BASE)
    except Exception as e: print(f"{RD}❌ {e}{RS}"); return
    W=44
    while True:
        os.system("clear")
        print(f"\n{R1}  \u2554{'═'*W}\u2557{RS}")
        print(f"{R1}  \u2551{RS}  {PU}🗑️  ลบ User (ใส่เลขคั่นด้วย , เช่น 1,3,5){RS}  {R1}\u2551{RS}")
        print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
        print(f"{R3}  \u2551{RS}  {YE}{'No.':<5}{'ชื่อ':<14}{'หมดอายุ':<18}{'Data':>6}{RS}  {R3}\u2551{RS}")
        print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
        for i,c in enumerate(clients,1):
            name=c["email"][:12]; total=c["total"]; data_str=f"{total}GB" if total>0 else "-"
            exp=c["exp_str"]
            ev=exp.replace(PU,"").replace(YE,"").replace(WH,"").replace(GR,"").replace(RD,"").replace(CY,"").replace(RS,"")
            pad=18-len(ev)
            print(f"{R6}  \u2551{RS}  {PU}{i:<5}{RS}{WH}{name:<14}{RS}{exp}{' '*max(0,pad)}{CY}{data_str:>6}{RS}  {R6}\u2551{RS}")
        print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
        print(f"{R3}  \u2551{RS}  {WH}0. กลับเมนูหลัก{RS}{'':>22}{R3}  \u2551{RS}")
        print(f"{R6}  \u255a{'═'*W}\u255d{RS}")
        sel=input(f"\n  {PU}เลือกหมายเลข >> {WH}").strip(); print(RS,end="")
        if sel=="0": break
        try:
            nums=[int(x.strip()) for x in sel.split(",") if x.strip()]
            selected=[clients[n-1] for n in nums if 1<=n<=len(clients)]
        except: print(f"{RD}❌ ใส่ตัวเลขไม่ถูกต้อง{RS}"); input("กด Enter..."); continue
        if not selected: print(f"{RD}❌ ไม่มีรายการที่เลือก{RS}"); input("กด Enter..."); continue
        names=", ".join([c["email"] for c in selected])
        print(f"\n  {R1}\u2554{'═'*W}\u2557{RS}")
        print(f"  {R1}\u2551{RS}  {RD}⚠️  ยืนยันลบ {len(selected)} รายการ?{RS}{'':>14}{R1}  \u2551{RS}")
        print(f"  {R1}\u2551{RS}  {WH}{names[:42]}{RS}{'':>{max(0,42-len(names[:42]))}}{R1}  \u2551{RS}")
        print(f"  {R6}\u255a{'═'*W}\u255d{RS}")
        confirm=input(f"\n  {PU}ยืนยัน (y/n) >> {WH}").strip().lower(); print(RS,end="")
        if confirm!="y": print(f"{YE}ยกเลิกครับ{RS}"); input("กด Enter..."); continue
        removed=0
        for c in selected:
            ok=delete_client(opener,BASE,c["inbound_id"],c["id"])
            if ok:
                for db in ["/etc/chaiya/vless.db","/etc/chaiya/iplog.db","/etc/chaiya/datalimit.conf"]:
                    if os.path.exists(db):
                        lines=[l for l in open(db).readlines() if c["id"] not in l]
                        open(db,"w").writelines(lines)
                page=f"/var/www/chaiya/config/{c['email']}.html"
                if os.path.exists(page): os.remove(page)
                print(f"  {GR}✅ ลบ {c['email']} แล้ว{RS}"); removed+=1
            else: print(f"  {RD}❌ ลบ {c['email']} ไม่สำเร็จ{RS}")
        clients=get_clients(opener,BASE)
        print(f"\n  {GR}✅ ลบทั้งหมด {removed} รายการ{RS}"); input("กด Enter...")

main()

EOF_CHAIYA_DELETE_USER
chmod +x /usr/local/bin/chaiya-delete-user

echo "✅ ติดตั้ง chaiya-gen-page..."
cat > /usr/local/bin/chaiya-gen-page <<'EOF_CHAIYA_GEN_PAGE'
#!/usr/bin/env python3
import sys, os
UUID,NAME,LINK,EXP,DATA_GB=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4],sys.argv[5]
html="".join([
"<!DOCTYPE html><html lang=\"th\"><head>",
"<meta charset=\"UTF-8\">",
"<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">",
f"<title>ChaiyaVPN - {NAME}</title>",
"<style>*{margin:0;padding:0;box-sizing:border-box}",
"body{background:#0a0a0a;color:#fff;font-family:Courier New,monospace;min-height:100vh;display:flex;justify-content:center;align-items:center;padding:20px}",
".card{background:#0d0d0d;border:1px solid #2a2a2a;border-radius:12px;width:100%;max-width:480px;overflow:hidden;box-shadow:0 0 40px rgba(180,0,255,.15)}",
".header{background:#111;padding:20px;text-align:center;border-bottom:2px solid #ffe000}",
".logo{color:#dd44ff;text-shadow:0 0 10px #aa00ff;font-size:22px;font-weight:bold;letter-spacing:3px}",
".name{color:#ffe000;font-size:16px;margin-top:6px}",
".body{padding:20px}",
".info-row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #1e1e1e;font-size:14px}",
".info-key{color:#dd44ff}.info-val{color:#fff}",
".link-box{background:#111;border:1px solid #333;border-radius:8px;padding:12px;margin:16px 0;word-break:break-all;font-size:11px;color:#aaa;line-height:1.6}",
".btn{display:block;width:100%;padding:14px;border:none;border-radius:8px;font-size:15px;cursor:pointer;margin-bottom:10px;font-weight:bold}",
".btn-copy{background:linear-gradient(135deg,#cc44ff,#9900cc);color:#fff}",
".btn-qr{background:#1a1a1a;color:#ffe000;border:1px solid #ffe000}",
".qr-container{display:none;text-align:center;padding:16px;background:#fff;border-radius:8px;margin-top:10px}",
".toast{display:none;position:fixed;bottom:30px;left:50%;transform:translateX(-50%);background:#44ff88;color:#000;padding:12px 24px;border-radius:20px;font-weight:bold}",
"</style></head><body>",
"<div class=\"card\"><div class=\"header\">",
"<div class=\"logo\">🔥 CHAIYA VPN</div>",
f"<div class=\"name\">👤 {NAME}</div>",
"</div><div class=\"body\">",
f"<div class=\"info-row\"><span class=\"info-key\">📅 หมดอายุ</span><span class=\"info-val\">{EXP}</span></div>",
f"<div class=\"info-row\"><span class=\"info-key\">📊 Data</span><span class=\"info-val\">{DATA_GB} GB</span></div>",
"<div class=\"info-row\"><span class=\"info-key\">🌐 Protocol</span><span class=\"info-val\">VLESS WS</span></div>",
f"<div class=\"link-box\" id=\"linkbox\">{LINK}</div>",
"<button class=\"btn btn-copy\" onclick=\"copyLink()\">📋 Copy Link</button>",
"<button class=\"btn btn-qr\" onclick=\"toggleQR()\">📱 แสดง QR Code</button>",
f"<div class=\"qr-container\" id=\"qrbox\"><img src=\"https://api.qrserver.com/v1/create-qr-code/?size=250x250&data={LINK}\" width=\"250\" height=\"250\"></div>",
"</div></div>",
"<div class=\"toast\" id=\"toast\">✅ Copy แล้ว!</div>",
"<script>",
"function copyLink(){navigator.clipboard.writeText(document.getElementById('linkbox').innerText).then(()=>{const t=document.getElementById('toast');t.style.display='block';setTimeout(()=>t.style.display='none',2000);})}",
"function toggleQR(){const q=document.getElementById('qrbox');q.style.display=q.style.display==='block'?'none':'block';}",
"</script></body></html>"
])
os.makedirs("/var/www/chaiya/config",exist_ok=True)
with open(f"/var/www/chaiya/config/{NAME}.html","w") as f: f.write(html)
print("OK")

EOF_CHAIYA_GEN_PAGE
chmod +x /usr/local/bin/chaiya-gen-page

echo "✅ ติดตั้ง chaiya..."
cat > /usr/local/bin/chaiya <<'EOF_CHAIYA'
#!/bin/bash
DB="/etc/chaiya/vless.db"
DOMAIN_FILE="/etc/chaiya/domain.conf"
BAN_FILE="/etc/chaiya/banned.db"
IP_LOG="/etc/chaiya/iplog.db"
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
touch "$DB" "$BAN_FILE" "$IP_LOG"

load_domain() { [[ -f "$DOMAIN_FILE" ]] && DOMAIN=$(cat "$DOMAIN_FILE") || DOMAIN=""; }

add_uuid_to_xray() {
  local UUID="$1" NAME="$2" PORT="$3" DAYS="$4" DATA_GB="$5"
  python3 -c "
import urllib.request, json, http.cookiejar
from datetime import datetime, timedelta
cfg=json.load(open('/etc/chaiya/xui.conf'))
BASE=cfg['host']+':'+cfg['port']+cfg['path'].rstrip('/')
jar=http.cookiejar.CookieJar()
opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
data=json.dumps({'username':cfg['username'],'password':cfg['password']}).encode()
opener.open(urllib.request.Request(BASE+'/login',data=data,headers={'Content-Type':'application/json'}))
inbound_id=cfg['inbound_id_8880'] if '$PORT'=='8880' else cfg['inbound_id_8080']
exp_ms=int((datetime.now()+timedelta(days=int('$DAYS'))).timestamp()*1000)
client_data={'id':inbound_id,'settings':json.dumps({'clients':[{'id':'$UUID','email':'$NAME','enable':True,'flow':'','expiryTime':exp_ms,'totalGB':int('$DATA_GB'),'limitIp':2}]})}
req=urllib.request.Request(BASE+'/panel/api/inbounds/addClient',data=json.dumps(client_data).encode(),headers={'Content-Type':'application/json'})
res=opener.open(req)
r=json.loads(res.read())
print('OK' if r.get('success') else 'FAIL')
" && printf "${GR}✅ เพิ่ม user สำเร็จ${RS}\n" || printf "${RD}❌ ไม่สำเร็จ${RS}\n"
}

row() {
  local txt="$1"
  local vis=$(echo "$txt" | sed 's/\x1b\[[0-9;]*m//g')
  local pad=$((44 - ${#vis}))
  [[ $pad -lt 0 ]] && pad=0
  printf "${R2}  ||${RS} %s%${pad}s ${R2}||${RS}\n" "$txt" ""
}

menu() {
  load_domain; clear
  printf "${R1}  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░${RS}\n"
  printf "${R2}  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗${RS}\n"
  printf "${R3}  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ ${RS}\n"
  printf "${R4}  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║${RS}\n"
  printf "${R5}  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║${RS}\n"
  printf "${R6}  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝${RS}\n\n"
  local MY_IP=$(hostname -I | awk '{print $1}')
  local CPU_PCT=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}' | cut -d. -f1 2>/dev/null || echo "?")
  local RAM_USED=$(free -m | awk '/Mem:/{printf "%.1f", $3/1024}')
  local RAM_TOTAL=$(free -m | awk '/Mem:/{printf "%.1f", $2/1024}')
  local TOTAL_USERS=$(wc -l < "$DB" 2>/dev/null || echo 0)
  printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}🔥 V2RAY PRO MAX${RS}")"
  [[ -n "$DOMAIN" ]] && row "$(printf "${PU}🌐 Domain : ${WH}${DOMAIN}${RS}")" || row "$(printf "${PU}⚠️  Domain : ${RD}ยังไม่มีโดเมน${RS}")"
  row "$(printf "${PU}🌍 IP      : ${WH}${MY_IP}${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}💻 CPU: ${WH}${CPU_PCT}%%  🧠 RAM: ${RAM_USED}/${RAM_TOTAL} GB  👥 Users: ${TOTAL_USERS}${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${R1}1.  ${WH}ติดตั้ง 3x-ui + ตั้งค่าอัตโนมัติ${RS}")"
  row "$(printf "${R2}2.  ${WH}ตั้งค่าโดเมน + SSL อัตโนมัติ${RS}")"
  row "$(printf "${R3}3.  ${WH}สร้าง VLESS${RS}")"
  row "$(printf "${R4}4.  ${WH}ลบบัญชีหมดอายุ${RS}")"
  row "$(printf "${R5}5.  ${WH}ดูบัญชี${RS}")"
  row "$(printf "${R6}6.  ${WH}ดู User Online Realtime${RS}")"
  row "$(printf "${R1}7.  ${WH}รีสตาร์ท 3x-ui${RS}")"
  row "$(printf "${R2}8.  ${WH}จัดการ Process CPU สูง${RS}")"
  row "$(printf "${R3}9.  ${WH}เช็คความเร็ว VPS${RS}")"
  row "$(printf "${R4}10. ${WH}จัดการ Port (เปิด/ปิด)${RS}")"
  row "$(printf "${R5}11. ${WH}ปลดแบน IP / จัดการ User${RS}")"
  row "$(printf "${R6}12. ${WH}บล็อก IP ต่างประเทศ${RS}")"
  row "$(printf "${R1}13. ${WH}สแกน Bug Host (SNI)${RS}")"
  row "$(printf "${R2}14. ${WH}ลบ User${RS}")"
  row "$(printf "${R3}15. ${WH}ตั้งค่ารีบูตอัตโนมัติ${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}0.  ${WH}ออก${RS}")"
  printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"
}

while true; do
  menu; read -r opt; printf "${RS}\n"
  case $opt in
  1)
    clear
    read -rp "ตั้งชื่อผู้ใช้ X-UI: " XUI_USER
    [[ -z "$XUI_USER" ]] && { printf "${RD}❌ ไม่ได้ใส่ชื่อ${RS}\n"; read -rp "กด Enter..."; continue; }
    read -rsp "ตั้งรหัสผ่าน X-UI: " XUI_PASS; echo ""
    [[ -z "$XUI_PASS" ]] && { printf "${RD}❌ ไม่ได้ใส่รหัสผ่าน${RS}\n"; read -rp "กด Enter..."; continue; }
    printf "\n${WH}กำลังติดตั้ง 3x-ui...${RS}\n"
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh)
    printf "\n${WH}กำลังตั้งค่าระบบ...${RS}\n"
    if python3 /usr/local/bin/chaiya-setup-xui "$XUI_USER" "$XUI_PASS"; then
      printf "${GR}✅ ติดตั้งเสร็จแล้ว!${RS}\n"
      printf "${PU}X-UI Panel : ${WH}http://$(hostname -I | awk '{print $1}'):2053${RS}\n"
    else
      printf "${RD}❌ ติดตั้งไม่สำเร็จ ลองใหม่ครับ${RS}\n"
    fi
    read -rp "กด Enter...";;
  2)
    clear
    printf "${WH}IP: $(hostname -I | awk '{print $1}')${RS}\n"
    read -rp "ใส่โดเมน: " INPUT_DOMAIN
    [[ -z "$INPUT_DOMAIN" ]] && { printf "${RD}❌ ไม่ได้ใส่โดเมน${RS}\n"; read -rp "กด Enter..."; continue; }
    apt install -y certbot python3-certbot-nginx -qq
    python3 -c "
t=open('/etc/nginx/sites-available/chaiya').read()
open('/etc/nginx/sites-available/chaiya','w').write(t.replace('server_name _;','server_name $INPUT_DOMAIN;'))
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
    [[ -n "$DOMAIN" ]] && HOST="$DOMAIN" || HOST=$(hostname -I | awk '{print $1}')
    add_uuid_to_xray "$UUID" "$NAME" "$PORT_LINK" "$d" "$DATA_GB"
    LINK="vless://${UUID}@${HOST}:${PORT_LINK}?type=ws&host=${SNI}&path=/ws&security=none&sni=${SNI}#ChaiyaVPN-${NAME}"
    python3 /usr/local/bin/chaiya-gen-page "$UUID" "$NAME" "$LINK" "$EXP" "$DATA_GB" 2>/dev/null
    if [[ -n "$DOMAIN" ]]; then CONFIG_URL="https://${DOMAIN}/config/${NAME}.html"
    else CONFIG_URL="http://$(hostname -I | awk '{print $1}')/config/${NAME}.html"; fi
    clear
    printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
    printf "${R2}  ║  ${GR}✅ สร้าง VLESS สำเร็จ${RS}                     ${R2}║${RS}\n"
    printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n"
    printf "${PU}ชื่อ    :${RS} ${WH}${NAME}${RS}\n"
    printf "${PU}Host    :${RS} ${WH}${HOST}${RS}\n"
    printf "${PU}SNI     :${RS} ${WH}${SNI}${RS}\n"
    printf "${PU}Port    :${RS} ${WH}${PORT_LINK}${RS}\n"
    printf "${PU}Data    :${RS} ${WH}${DATA_GB} GB${RS}\n"
    printf "${PU}หมดอายุ :${RS} ${WH}${EXP}${RS}\n\n"
    printf "${PU}🌐 ลิงก์ดาวน์โหลด Config:${RS}\n${WH}${CONFIG_URL}${RS}\n"
    printf "${R3}  ════════════════════════════════════════════${RS}\n"
    read -rp "กด Enter...";;
  4)
    TODAY=$(date +"%Y-%m-%d"); REMOVED=0; TMPFILE=$(mktemp)
    while read -r u e n; do
      if [[ "$e" < "$TODAY" ]]; then
        printf "${RD}ลบ: $n (หมดอายุ $e)${RS}\n"
        python3 -c "
import urllib.request, json, http.cookiejar
try:
    cfg=json.load(open('/etc/chaiya/xui.conf'))
    BASE=cfg['host']+':'+cfg['port']+cfg['path'].rstrip('/')
    jar=http.cookiejar.CookieJar()
    opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    data=json.dumps({'username':cfg['username'],'password':cfg['password']}).encode()
    opener.open(urllib.request.Request(BASE+'/login',data=data,headers={'Content-Type':'application/json'}))
    res=opener.open(BASE+'/panel/api/inbounds/list')
    for inbound in json.loads(res.read())['obj']:
        for client in json.loads(inbound['settings']).get('clients',[]):
            if client.get('email')=='$n':
                uid=client.get('id','')
                req=urllib.request.Request(BASE+f'/panel/api/inbounds/{inbound[chr(34)]}/delClient/{uid}',method='POST',headers={'Content-Type':'application/json'})
                opener.open(req)
except: pass
" 2>/dev/null
        ((REMOVED++))
      else echo "$u $e $n" >> "$TMPFILE"; fi
    done < "$DB"
    mv "$TMPFILE" "$DB"
    printf "${GR}✅ ลบ ${REMOVED} บัญชี${RS}\n"; read -rp "กด Enter...";;
  5) clear; python3 /usr/local/bin/chaiya-show-accounts; read -rp "กด Enter...";;
  6) bash /usr/local/bin/chaiya-online;;
  7) x-ui restart && printf "${GR}✅ รีสตาร์ท 3x-ui สำเร็จ${RS}\n" || printf "${RD}❌ ไม่สำเร็จ${RS}\n"; read -rp "กด Enter...";;
  8) bash /usr/local/bin/chaiya-cpukiller;;
  9) command -v speedtest-cli &>/dev/null || apt install -y speedtest-cli; speedtest-cli --simple; read -rp "กด Enter...";;
  10)
    while true; do
      clear
      printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
      printf "${R2}  ║  ${PU}จัดการ Port${RS}                               ${R2}║${RS}\n"
      printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
      printf "${R2}  ||${RS}  ${PU}1. เปิด  2. ปิด  3. ดูทั้งหมด  0. กลับ${RS}  ${R2}||${RS}\n"
      printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n"
      read -rp "เลือก: " popt
      case $popt in
      1) read -rp "Port: " PNUM
         [[ ! "$PNUM" =~ ^[0-9]+(/(tcp|udp))?$ ]] && { printf "${RD}❌ รูปแบบผิด${RS}\n"; read -rp "กด Enter..."; continue; }
         ufw allow "$PNUM"; printf "${GR}✅ เปิด $PNUM แล้ว${RS}\n"; read -rp "กด Enter...";;
      2) read -rp "Port: " PNUM
         [[ ! "$PNUM" =~ ^[0-9]+(/(tcp|udp))?$ ]] && { printf "${RD}❌ รูปแบบผิด${RS}\n"; read -rp "กด Enter..."; continue; }
         [[ "${PNUM%%/*}" == "22" ]] && { printf "${RD}⛔ ปิด Port 22 ไม่ได้${RS}\n"; read -rp "กด Enter..."; continue; }
         ufw delete allow "$PNUM"; printf "${GR}✅ ปิด $PNUM แล้ว${RS}\n"; read -rp "กด Enter...";;
      3) ufw status numbered; read -rp "กด Enter...";;
      0) break;;
      esac
    done;;
  11) python3 /usr/local/bin/chaiya-manage-user;;
  12) bash /usr/local/bin/chaiya-autoblock;;
  13) bash /usr/local/bin/chaiya-bughost;;
  14) python3 /usr/local/bin/chaiya-delete-user;;
  15) bash /usr/local/bin/chaiya-reboot-menu;;
  0) printf "${PU}👋 ออก${RS}\n"; exit 0;;
  *) printf "${RD}❌ ไม่ถูกต้อง${RS}\n"; sleep 1;;
  esac
done

EOF_CHAIYA
chmod +x /usr/local/bin/chaiya

echo "✅ ติดตั้ง chaiya-manage-user..."
cat > /usr/local/bin/chaiya-manage-user <<'EOF_CHAIYA_MANAGE_USER'
#!/usr/bin/env python3
import json, os, urllib.request, http.cookiejar
from datetime import datetime

PU="\033[38;2;204;68;255m"; YE="\033[38;2;255;238;0m"; WH="\033[1;37m"
GR="\033[38;2;0;255;68m"; RD="\033[38;2;255;0;85m"; CY="\033[38;2;0;204;255m"
R1="\033[38;2;255;0;85m"; R3="\033[38;2;255;238;0m"; R6="\033[38;2;204;68;255m"
RS="\033[0m"

def xui_login():
    cfg=json.load(open("/etc/chaiya/xui.conf"))
    BASE=cfg["host"]+":"+cfg["port"]+cfg["path"].rstrip("/")
    jar=http.cookiejar.CookieJar()
    opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    data=json.dumps({"username":cfg["username"],"password":cfg["password"]}).encode()
    opener.open(urllib.request.Request(BASE+"/login",data=data,headers={"Content-Type":"application/json"}))
    return opener,BASE

def get_clients(opener,BASE):
    res=opener.open(BASE+"/panel/api/inbounds/list")
    inbounds=json.loads(res.read())["obj"]
    clients=[]
    for inbound in inbounds:
        settings=json.loads(inbound["settings"])
        cs_map={cs["email"]:cs for cs in (inbound.get("clientStats") or [])}
        for client in settings.get("clients",[]):
            email=client.get("email","") or ""
            if not email: continue
            uid=client.get("id",""); enabled=client.get("enable",True)
            cs=cs_map.get(email,{}); exp=client.get("expiryTime",0) or 0; total=cs.get("total",0) or 0
            if exp>0:
                days=(datetime.fromtimestamp(exp/1000)-datetime.now()).days
                exp_str=f"{RD}❌ หมดอายุ{RS}" if days<0 else f"{GR}✅ {days} วัน{RS}"
            else: exp_str=f"{WH}-{RS}"
            clients.append({"email":email,"id":uid,"inbound_id":inbound["id"],"enabled":enabled,"exp_str":exp_str,"total":total})
    return clients

def toggle_client(opener,BASE,inbound_id,uid,enable):
    res=opener.open(BASE+"/panel/api/inbounds/list")
    inbounds=json.loads(res.read())["obj"]
    for inbound in inbounds:
        if inbound["id"]!=inbound_id: continue
        settings=json.loads(inbound["settings"])
        for client in settings.get("clients",[]):
            if client.get("id")==uid: client["enable"]=enable; break
        update_data={"id":inbound_id,"settings":json.dumps({"clients":[c for c in settings["clients"] if c.get("id")==uid]})}
        req=urllib.request.Request(BASE+f"/panel/api/inbounds/updateClient/{uid}",
            data=json.dumps(update_data).encode(),headers={"Content-Type":"application/json"})
        try:
            res2=opener.open(req); r=json.loads(res2.read()); return r.get("success",False)
        except: return False
    return False

def main():
    try: opener,BASE=xui_login(); clients=get_clients(opener,BASE)
    except Exception as e: print(f"{RD}❌ {e}{RS}"); return
    W=44
    while True:
        os.system("clear")
        print(f"\n{R1}  \u2554{'═'*W}\u2557{RS}")
        print(f"{R1}  \u2551{RS}  {PU}👥 ปลดแบน IP / จัดการ User (เปิด/ปิด){RS}  {R1}\u2551{RS}")
        print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
        print(f"{R3}  \u2551{RS}  {YE}{'No.':<5}{'ชื่อ':<14}{'สถานะ':<14}{'หมดอายุ':<14}{'Data'}{RS}  {R3}\u2551{RS}")
        print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
        for i,c in enumerate(clients,1):
            name=c["email"][:12]; total=c["total"]; data_str=f"{total}GB" if total>0 else "-"
            exp=c["exp_str"]
            badge=f"{GR}● เปิด{RS}" if c["enabled"] else f"{RD}● ปิด{RS}"
            bv="● เปิด" if c["enabled"] else "● ปิด"
            ev=exp.replace(PU,"").replace(YE,"").replace(WH,"").replace(GR,"").replace(RD,"").replace(CY,"").replace(RS,"")
            bp=14-len(bv); ep=14-len(ev)
            print(f"{R6}  \u2551{RS}  {PU}{i:<5}{RS}{WH}{name:<14}{RS}{badge}{' '*max(0,bp)}{exp}{' '*max(0,ep)}{CY}{data_str}{RS}  {R6}\u2551{RS}")
        print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
        print(f"{R3}  \u2551{RS}  {WH}ใส่เลขเพื่อสลับ เปิด↔ปิด เช่น 1,3,5{RS}  {R3}\u2551{RS}")
        print(f"{R3}  \u2551{RS}  {PU}0.  {WH}กลับเมนูหลัก{RS}{'':>20}{R3}  \u2551{RS}")
        print(f"{R6}  \u255a{'═'*W}\u255d{RS}\n")
        sel=input(f"  {PU}เลือกหมายเลข >> {WH}").strip(); print(RS,end="")
        if sel=="0": break
        try:
            nums=[int(x.strip()) for x in sel.split(",") if x.strip()]
            selected=[clients[n-1] for n in nums if 1<=n<=len(clients)]
        except: print(f"{RD}❌ ใส่ตัวเลขไม่ถูกต้อง{RS}"); input("กด Enter..."); continue
        for c in selected:
            new_state=not c["enabled"]
            ok=toggle_client(opener,BASE,c["inbound_id"],c["id"],new_state)
            state_str=f"{GR}เปิด{RS}" if new_state else f"{RD}ปิด{RS}"
            if ok: print(f"  {GR}✅ {c['email']} → {state_str}{RS}"); c["enabled"]=new_state
            else: print(f"  {RD}❌ {c['email']} ไม่สำเร็จ{RS}")
        clients=get_clients(opener,BASE); input(f"\n  กด Enter...")

main()

EOF_CHAIYA_MANAGE_USER
chmod +x /usr/local/bin/chaiya-manage-user

echo "✅ ติดตั้ง chaiya-online..."
cat > /usr/local/bin/chaiya-online <<'EOF_CHAIYA_ONLINE'
#!/bin/bash
R1='\033[38;2;255;0;85m'; R2='\033[38;2;255;102;0m'; R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'; R5='\033[38;2;0;204;255m'; R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'; YE='\033[38;2;255;238;0m'; WH='\033[1;37m'
GR='\033[38;2;0;255;68m'; RD='\033[38;2;255;0;85m'; RS='\033[0m'

show_logo() {
  printf "${R1}  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░${RS}\n"
  printf "${R2}  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗${RS}\n"
  printf "${R3}  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ ${RS}\n"
  printf "${R4}  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║${RS}\n"
  printf "${R5}  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║${RS}\n"
  printf "${R6}  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝${RS}\n\n"
}

show_online() {
  clear; show_logo; NOW=$(date '+%H:%M:%S')
  RESULT=$(python3 -c "
import urllib.request,json,http.cookiejar
from datetime import datetime
try:
    cfg=json.load(open('/etc/chaiya/xui.conf'))
    BASE=cfg['host']+':'+cfg['port']+cfg['path'].rstrip('/')
    jar=http.cookiejar.CookieJar()
    opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    data=json.dumps({'username':cfg['username'],'password':cfg['password']}).encode()
    opener.open(urllib.request.Request(BASE+'/login',data=data,headers={'Content-Type':'application/json'}))
    res=opener.open(BASE+'/panel/api/inbounds/list')
    inbounds=json.loads(res.read())['obj']
    online=[]
    for inbound in inbounds:
        port=inbound['port']
        settings=json.loads(inbound['settings'])
        cs_map={cs['email']:cs for cs in (inbound.get('clientStats') or [])}
        for client in settings.get('clients',[]):
            email=client.get('email','') or ''
            if not email: continue
            cs=cs_map.get(email,{})
            last_online=cs.get('lastOnline',0) or 0
            if last_online<=0: continue
            now_ts=datetime.now().timestamp()*1000
            diff_sec=int((now_ts-last_online)/1000)
            if diff_sec>300: continue
            t=f'{diff_sec} วิ' if diff_sec<60 else f'{diff_sec//60} นาที'
            online.append(f'{email}|-|{port}|{t}ที่แล้ว')
    print('\n'.join(online))
except Exception as e: print(f'ERROR:{e}')
")
  printf "${R1}  ╔══════════════════════════════════════════════╗${RS}\n"
  printf "${R1}  ║${RS}  ${PU}🟢 ผู้ใช้ Online แบบ Realtime${RS}                 ${R1}║${RS}\n"
  printf "${R3}  ║${RS}  ${YE}%-12s %-20s %-8s %s${RS}  ${R3}║${RS}\n" "ชื่อ" "IP ที่ต่อ" "Port" "เวลาต่อ"
  printf "${R3}  ╠══════════════════════════════════════════════╣${RS}\n"
  COUNT=0
  if [[ -z "$RESULT" ]] || echo "$RESULT" | grep -q "^ERROR"; then
    printf "${R3}  ║${RS}  ${RD}❌ ไม่สามารถดึงข้อมูลได้${RS}                       ${R3}║${RS}\n"
  else
    while IFS='|' read -r name ip port tstr; do
      [[ -z "$name" ]] && continue
      printf "${R6}  ║${RS}  ${GR}●${RS} ${PU}%-11s${RS} ${R5}%-20s${RS} ${YE}[%-4s]${RS} ${WH}%-18s${RS} ${R6}║${RS}\n" \
        "$name" "$ip" "$port" "$tstr"
      ((COUNT++))
    done <<< "$RESULT"
    [[ $COUNT -eq 0 ]] && printf "${R3}  ║${RS}  ${WH}ไม่มีผู้ใช้ Online ขณะนี้${RS}                    ${R3}║${RS}\n"
  fi
  printf "${R3}  ╠══════════════════════════════════════════════╣${RS}\n"
  printf "${R3}  ║${RS}  ${GR}● Online: ${COUNT} คน${RS}  ${WH}อัพเดต: ${NOW}${RS}  ${WH}r=รีเฟรช|q=ออก${RS}   ${R3}║${RS}\n"
  printf "${R6}  ╚══════════════════════════════════════════════╝${RS}\n"
}

while true; do
  show_online
  printf "\n  ${PU}กด r รีเฟรช | กด q ออก >> ${WH}"
  read -r -t 10 key; printf "${RS}\n"
  case "$key" in q|Q) break;; *) continue;; esac
done

EOF_CHAIYA_ONLINE
chmod +x /usr/local/bin/chaiya-online

echo "✅ ติดตั้ง chaiya-reboot-menu..."
cat > /usr/local/bin/chaiya-reboot-menu <<'EOF_CHAIYA_REBOOT_MENU'
#!/bin/bash
R1='\033[38;2;255;0;85m'; R2='\033[38;2;255;102;0m'; R3='\033[38;2;255;238;0m'
R4='\033[38;2;0;255;68m'; R5='\033[38;2;0;204;255m'; R6='\033[38;2;204;68;255m'
PU='\033[38;2;204;68;255m'; YE='\033[38;2;255;238;0m'; WH='\033[1;37m'
GR='\033[38;2;0;255;68m'; RD='\033[38;2;255;0;85m'; RS='\033[0m'
RC="/etc/chaiya/reboot.conf"; touch "$RC"
get_st(){ crontab -l 2>/dev/null|grep -q "chaiya-reboot"&&echo "on"||echo "off"; }
get_t(){ [[ -f "$RC" ]]&&cat "$RC"||echo "04:00"; }
next_rb(){ local T=$(get_t) H=$(echo $(get_t)|cut -d: -f1) M=$(echo $(get_t)|cut -d: -f2) NH=$(date +%H) NM=$(date +%M); [[ "$NH" -lt "$H" ]]||{ [[ "$NH" -eq "$H" ]]&&[[ "$NM" -lt "$M" ]]; }&&echo "วันนี้ ${T}"||echo "พรุ่งนี้ ${T}"; }
row(){ local txt="$1" vis=$(echo "$1"|sed 's/\x1b\[[0-9;]*m//g') pad=$((44-${#vis})); [[ $pad -lt 0 ]]&&pad=0; printf "${R2}  ||${RS} %s%${pad}s ${R2}||${RS}\n" "$txt" ""; }
logo(){ printf "${R1}  ░█████╗░██╗░░██╗░█████╗░██╗██╗░░░██╗░█████╗░${RS}\n"; printf "${R2}  ██╔══██╗██║░░██║██╔══██╗██║╚██╗░██╔╝██╔══██╗${RS}\n"; printf "${R3}  ██║░░╚═╝███████║███████║██║░╚████╔╝░███████║ ${RS}\n"; printf "${R4}  ██║░░██╗██╔══██║██╔══██║██║░░╚██╔╝░░██╔══██║${RS}\n"; printf "${R5}  ╚█████╔╝██║░░██║██║░░██║██║░░░██║░░░██║░░██║${RS}\n"; printf "${R6}  ░╚════╝░╚═╝░░╚═╝╚═╝░░╚═╝╚═╝░░░╚═╝░░░╚═╝░░╚═╝${RS}\n\n"; }
while true; do
  clear; logo; ST=$(get_st); RT=$(get_t); NX=$(next_rb)
  [[ "$ST" == "on" ]]&&BADGE="${GR}● เปิดทำงาน${RS}"||BADGE="\033[0;37m○ ปิดทำงาน\033[0m"
  printf "${R1}  ╔════════════════════════════════════════════╗${RS}\n"
  row "$(printf "${PU}🔄 ตั้งค่ารีบูตเซิร์ฟเวอร์อัตโนมัติ${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}⏰ เวลารีบูต  : ${YE}${RT}${RS}")"; row "$(printf "${PU}📡 สถานะ     : ${RS}${BADGE}")"; row "$(printf "${PU}🕐 ครั้งถัดไป: ${WH}${NX}${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"
  row "$(printf "${PU}1.  ${WH}ตั้งเวลารีบูต (HH:MM)${RS}")"; row "$(printf "${PU}2.  ${GR}เปิดใช้งานรีบูตอัตโนมัติ${RS}")"; row "$(printf "${PU}3.  ${RD}ปิดใช้งานรีบูตอัตโนมัติ${RS}")"
  printf "${R3}  ╠════════════════════════════════════════════╣${RS}\n"; row "$(printf "${PU}0.  ${WH}กลับ${RS}")"
  printf "${R6}  ╚════════════════════════════════════════════╝${RS}\n\n"
  printf "  ${PU}เลือก >> ${WH}"; read -r opt; printf "${RS}\n"
  case $opt in
  1) read -rp "  เวลา (HH:MM): " NT
     [[ "$NT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]&&{ echo "$NT">"$RC"; printf "  ${GR}✅ ตั้งเวลา ${NT} แล้ว${RS}\n"; [[ "$(get_st)" == "on" ]]&&{ H=$(echo "$NT"|cut -d: -f1); M=$(echo "$NT"|cut -d: -f2); (crontab -l 2>/dev/null|grep -v "chaiya-reboot"; echo "$M $H * * * /sbin/reboot # chaiya-reboot")|crontab -; }; }||printf "  ${RD}❌ รูปแบบผิด HH:MM${RS}\n"; read -rp "  กด Enter...";;
  2) T=$(get_t); H=$(echo "$T"|cut -d: -f1); M=$(echo "$T"|cut -d: -f2); (crontab -l 2>/dev/null|grep -v "chaiya-reboot"; echo "$M $H * * * /sbin/reboot # chaiya-reboot")|crontab -; printf "  ${GR}✅ เปิดรีบูต ${T} ทุกวัน${RS}\n"; read -rp "  กด Enter...";;
  3) crontab -l 2>/dev/null|grep -v "chaiya-reboot"|crontab -; printf "  ${RD}✅ ปิดแล้ว${RS}\n"; read -rp "  กด Enter...";;
  0) break;;
  *) printf "  ${RD}❌${RS}\n"; sleep 1;;
  esac
done

EOF_CHAIYA_REBOOT_MENU
chmod +x /usr/local/bin/chaiya-reboot-menu

echo "✅ ติดตั้ง chaiya-setup-xui..."
cat > /usr/local/bin/chaiya-setup-xui <<'EOF_CHAIYA_SETUP_XUI'
#!/usr/bin/env python3
import sys, subprocess, json, time, re, os
import urllib.request, urllib.error, http.cookiejar, ssl

USER = sys.argv[1]
PASS = sys.argv[2]

def sql_escape(value: str) -> str:
    return value.replace("'", "''")

# อัพเดต username/password ใน database โดยตรง
try:
    import bcrypt
    hashed = bcrypt.hashpw(PASS.encode(), bcrypt.gensalt()).decode()
except:
    # ถ้าไม่มี bcrypt ใช้ x-ui setting แทน
    subprocess.run(['pip3','install','bcrypt','--break-system-packages','-q'], capture_output=True)
    try:
        import bcrypt
        hashed = bcrypt.hashpw(PASS.encode(), bcrypt.gensalt()).decode()
    except:
        hashed = None

if hashed:
    sql_user = sql_escape(USER)
    sql_hash = sql_escape(hashed)
    db_update = subprocess.run(
        ['sqlite3','/etc/x-ui/x-ui.db',
         f"UPDATE users SET username='{sql_user}', password='{sql_hash}' WHERE id=1;"],
        capture_output=True,
        text=True
    )
    if db_update.returncode == 0:
        print("✅ อัพเดต credentials ใน DB แล้ว")
    else:
        subprocess.run(['x-ui','setting','-username',USER,'-password',PASS,'-port','2053'], capture_output=True)
else:
    subprocess.run(['x-ui','setting','-username',USER,'-password',PASS,'-port','2053'], capture_output=True)

# ตั้ง port
subprocess.run(['x-ui','setting','-port','2053'], capture_output=True)
time.sleep(2)
subprocess.run(['x-ui','restart'], capture_output=True)

print("รอ x-ui พร้อม...")
time.sleep(15)

# ดึง settings
result = subprocess.run(['x-ui','settings'], capture_output=True, text=True)
path = "/"
port = "2053"
use_ssl = False
for line in result.stdout.split("\n"):
    line_clean = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
    if 'webBasePath' in line_clean:
        p = line_clean.split(":",1)[1].strip()
        if p: path = p
    if line_clean.startswith('port:'):
        pt = line_clean.split(":",1)[1].strip()
        if pt.isdigit(): port = pt
    if line_clean.startswith('Access URL:') and 'https' in line_clean:
        use_ssl = True

scheme = "https" if use_ssl else "http"
BASE = f"{scheme}://127.0.0.1:{port}{path.rstrip('/')}"
print(f"BASE: {BASE}")

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def make_opener():
    jar = http.cookiejar.CookieJar()
    if use_ssl:
        return urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(jar),
            urllib.request.HTTPSHandler(context=ctx)
        )
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

data = json.dumps({"username":USER,"password":PASS}).encode()
login_ok = False
opener = None

for attempt in range(15):
    try:
        opener = make_opener()
        res = opener.open(
            urllib.request.Request(f"{BASE}/login",data=data,headers={"Content-Type":"application/json"}),
            timeout=8
        )
        r = json.loads(res.read())
        if r.get('success'):
            login_ok = True
            print(f"✅ login OK")
            break
        else:
            print(f"retry {attempt+1}: {r.get('msg','')}")
    except Exception as e:
        print(f"retry {attempt+1}: {e}")
    time.sleep(3)

if not login_ok:
    print("ERROR: login failed")
    sys.exit(1)

def create_inbound(port_num, remark):
    inbound = {
        "enable": True,"remark": remark,"listen": "","port": port_num,
        "protocol": "vless",
        "settings": json.dumps({"clients":[],"decryption":"none"}),
        "streamSettings": json.dumps({"network":"ws","wsSettings":{"path":"/ws"}}),
        "sniffing": json.dumps({"enabled":False,"destOverride":[]})
    }
    req = urllib.request.Request(f"{BASE}/panel/api/inbounds/add",
        data=json.dumps(inbound).encode(),headers={"Content-Type":"application/json"})
    try:
        res = opener.open(req)
        return json.loads(res.read())
    except Exception as e:
        return {"success":False,"msg":str(e)}

create_inbound(8080,"ChaiyaVPN-8080")
create_inbound(8880,"ChaiyaVPN-8880")

res = opener.open(f"{BASE}/panel/api/inbounds/list")
inbounds = json.loads(res.read())["obj"]
id_8080 = next((i["id"] for i in inbounds if i["port"]==8080),None)
id_8880 = next((i["id"] for i in inbounds if i["port"]==8880),None)

cfg = {
    "host": f"{scheme}://127.0.0.1",
    "port": port, "path": path,
    "username": USER, "password": PASS,
    "inbound_id_8080": id_8080, "inbound_id_8880": id_8880
}
os.makedirs("/etc/chaiya",exist_ok=True)
with open("/etc/chaiya/xui.conf","w") as f:
    json.dump(cfg,f,indent=2)
print("OK")

EOF_CHAIYA_SETUP_XUI
chmod +x /usr/local/bin/chaiya-setup-xui

echo "✅ ติดตั้ง chaiya-show-accounts..."
cat > /usr/local/bin/chaiya-show-accounts <<'EOF_CHAIYA_SHOW_ACCOUNTS'
#!/usr/bin/env python3
import json, os, urllib.request, http.cookiejar
from datetime import datetime

PU="\033[38;2;204;68;255m"; YE="\033[38;2;255;238;0m"; WH="\033[1;37m"
GR="\033[38;2;0;255;68m"; RD="\033[38;2;255;0;85m"; CY="\033[38;2;0;204;255m"
R1="\033[38;2;255;0;85m"; R3="\033[38;2;255;238;0m"; R6="\033[38;2;204;68;255m"
RS="\033[0m"

def fmt(b):
    b=int(b) if b else 0
    if b>=1073741824: return f"{b/1073741824:.1f}GB"
    elif b>=1048576: return f"{b/1048576:.1f}MB"
    elif b>=1024: return f"{b/1024:.1f}KB"
    return f"{b}B"

def bar(u,t,w=8):
    if t<=0: return GR+"░"*w+RS
    p=min(u/t,1.0); f=int(p*w)
    c=RD if p>=0.8 else YE if p>=0.5 else GR
    return c+"█"*f+RS+"░"*(w-f)

try:
    cfg=json.load(open("/etc/chaiya/xui.conf"))
    BASE=cfg["host"]+":"+cfg["port"]+cfg["path"].rstrip("/")
    jar=http.cookiejar.CookieJar()
    opener=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    data=json.dumps({"username":cfg["username"],"password":cfg["password"]}).encode()
    opener.open(urllib.request.Request(BASE+"/login",data=data,headers={"Content-Type":"application/json"}))
    res=opener.open(BASE+"/panel/api/inbounds/list")
    inbounds=json.loads(res.read())["obj"]
except Exception as e:
    print(f"{RD}❌ X-UI Error: {e}{RS}"); exit(1)

today=datetime.now()
DB="/etc/chaiya/vless.db"; LIMIT_FILE="/etc/chaiya/datalimit.conf"
db_data={}
if os.path.exists(DB):
    for line in open(DB):
        p=line.strip().split()
        if len(p)>=3: db_data[p[0]]={"exp":p[1],"name":p[2]}
limit_data={}
if os.path.exists(LIMIT_FILE):
    for line in open(LIMIT_FILE):
        p=line.strip().split()
        if len(p)>=2: limit_data[p[0]]=int(p[1])

W=56; total_acc=online_cnt=expired_cnt=0
print(f"\n{R1}  \u2554{'═'*W}\u2557{RS}")
print(f"{R1}  \u2551{RS}{PU}{'🔥 บัญชีทั้งหมด':^{W}}{RS}{R1}\u2551{RS}")
print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
print(f"{R3}  \u2551{RS} {YE}{'ชื่อ':<12}{'หมดอายุ':<12}{'ใช้แล้ว':<10}{'คงเหลือ/รวม':<22}{'Port'}{RS}  {R3}\u2551{RS}")
print(f"{R3}  \u2560{'═'*W}\u2563{RS}")

for inbound in inbounds:
    settings=json.loads(inbound["settings"]); port=inbound["port"]
    cs_map={cs["email"]:cs for cs in (inbound.get("clientStats") or [])}
    for client in settings.get("clients",[]):
        uid=client.get("id",""); name=(client.get("email","") or "-")[:10]; total_acc+=1
        info=db_data.get(uid,{}); exp_str=info.get("exp","-")
        if exp_str!="-":
            try:
                days=(datetime.strptime(exp_str,"%Y-%m-%d")-today).days
                if days<0: exp_label=f"{RD}❌หมด{RS}"; expired_cnt+=1
                else: exp_label=f"{GR}✅{days}วัน{RS}"
            except: exp_label=exp_str
        else: exp_label=f"{WH}-{RS}"
        cs=cs_map.get(client.get("email",""),{})
        used=(cs.get("up",0) or 0)+(cs.get("down",0) or 0)
        last_online=cs.get("lastOnline",0) or 0
        is_online=last_online>0 and (today.timestamp()*1000-last_online)<300000
        lgb=limit_data.get(uid,limit_data.get("DEFAULT",30))
        lb=lgb*1073741824; remain=max(0,lb-used)
        b=bar(used,lb); data_str=f"{b}{WH}{fmt(remain)}/{lgb}G{RS}"
        dot=f"{GR}●{RS}" if is_online else f"{WH}○{RS}"
        if is_online: online_cnt+=1
        ev=exp_label.replace(PU,"").replace(YE,"").replace(WH,"").replace(GR,"").replace(RD,"").replace(CY,"").replace(RS,"")
        ep=12-len(ev)
        print(f"{R6}  \u2551{RS} {dot}{PU}{name:<11}{RS}{exp_label}{' '*max(0,ep)}{WH}{fmt(used):<10}{RS}{data_str:<30}{YE}{port}{RS}  {R6}\u2551{RS}")

print(f"{R3}  \u2560{'═'*W}\u2563{RS}")
s=f"รวม {total_acc} | {GR}●{RS}Online {online_cnt} | ○Offline {total_acc-online_cnt} | {RD}❌{RS}หมด {expired_cnt}"
print(f"{R3}  \u2551{RS} {s}")
print(f"{R6}  \u255a{'═'*W}\u255d{RS}")

EOF_CHAIYA_SHOW_ACCOUNTS
chmod +x /usr/local/bin/chaiya-show-accounts

(crontab -l 2>/dev/null | grep -v "scan_and_enforce"; echo "*/5 * * * * /usr/local/bin/chaiya scan_and_enforce 2>/dev/null") | crontab -

echo ""
echo "======================================"
echo "✅ ติดตั้ง CHAIYA V2RAY PRO MAX v4 เสร็จแล้ว!"
echo "👉 พิมพ์: chaiya เพื่อเปิดเมนู"
echo "🔥 กดเมนู 1 เพื่อติดตั้ง 3x-ui ก่อนครับ"
echo "======================================"
