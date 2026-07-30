#!/bin/bash
# ตรวจสอบว่าโดเมน AIS ตัวไหน proxied ผ่าน Cloudflare (orange cloud)
DOMAINS=(
  "ais.co.th"
  "www.ais.co.th"
  "ais.th"
  "www.ais.th"
  "channel.ais.th"
  "my.ais.co.th"
  "shop.ais.co.th"
  "store.ais.co.th"
  "m.ais.co.th"
  "es.ais.co.th"
  "aiscallcenter.ais.co.th"
  "ws-adv.ais.co.th"
)

echo "== ตรวจสอบ Cloudflare Orange Cloud สำหรับโดเมน AIS =="
printf "%-30s %-18s %-10s\n" "DOMAIN" "IP" "CF?"
echo "--------------------------------------------------------------"

for d in "${DOMAINS[@]}"; do
  ip=$(dig +short "$d" A | tail -n1)
  if [ -z "$ip" ]; then
    printf "%-30s %-18s %-10s\n" "$d" "N/A" "no-resolve"
    continue
  fi
  # เช็คว่า IP อยู่ใน Cloudflare range ไหม โดยเทียบกับ /24 ที่รู้จัก (104.16-31, 172.64-71, 162.158-159, 188.114, 190.93, 197.234, 198.41)
  cf="no"
  case "$ip" in
    104.1[6-9].*|104.2[0-9].*|104.3[0-1].*) cf="yes" ;;
    172.6[4-9].*|172.7[0-1].*) cf="yes" ;;
    162.15[8-9].*) cf="yes" ;;
    188.114.*) cf="yes" ;;
    190.93.*) cf="yes" ;;
    197.234.*) cf="yes" ;;
    198.41.*) cf="yes" ;;
  esac
  # เทียบซ้ำด้วย whois org (แม่นกว่า)
  org=$(whois "$ip" 2>/dev/null | grep -im1 "orgname\|netname\|descr" | head -n1)
  printf "%-30s %-18s %-10s | %s\n" "$d" "$ip" "$cf" "$org"
done
