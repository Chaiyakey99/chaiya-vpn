#!/bin/bash
# ดึง subdomain ทั้งหมดของ AIS จาก crt.sh แล้วเช็คว่าตัวไหนเปิด Cloudflare (orange cloud)

DOMAINS_ROOT=("ais.co.th" "ais.th")
TMP_LIST="/tmp/ais_subs.txt"
> "$TMP_LIST"

echo "== ดึงรายชื่อ subdomain จาก crt.sh =="
for root in "${DOMAINS_ROOT[@]}"; do
  curl -s "https://crt.sh/?q=%25.${root}&output=json" \
    | tr ',' '\n' | grep -o '"name_value":"[^"]*"' \
    | sed 's/"name_value":"//;s/"//' \
    | sed 's/\\n/\n/g' \
    | grep -v '\*' >> "$TMP_LIST"
done

sort -u "$TMP_LIST" -o "$TMP_LIST"
COUNT=$(wc -l < "$TMP_LIST")
echo "พบทั้งหมด $COUNT subdomain"
echo ""

echo "== ตรวจสอบ Cloudflare Orange Cloud =="
printf "%-45s %-18s %-6s %s\n" "DOMAIN" "IP" "CF?" "ORG"
echo "--------------------------------------------------------------------------------------"

while read -r d; do
  [ -z "$d" ] && continue
  ip=$(dig +short "$d" A | tail -n1)
  if [ -z "$ip" ]; then
    continue
  fi
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
  if [ "$cf" = "yes" ]; then
    org=$(whois "$ip" 2>/dev/null | grep -im1 "orgname\|netname" | head -n1 | tr -s ' ')
    printf "%-45s %-18s %-6s %s\n" "$d" "$ip" "$cf" "$org"
  fi
done < "$TMP_LIST"

echo ""
echo "รายชื่อ subdomain ทั้งหมด (รวมที่ไม่ผ่าน CF) อยู่ที่: $TMP_LIST"
