#!/bin/bash
# ============================================================
#   SSH-WS MANAGER v1.0
#   Ubuntu 24.04 | Port 80 Only | Username/Password Auth
#   Features: User CRUD, Data Quota, Multi-login Ban, Unban
# ============================================================

DB="/etc/ssh-ws/users.db"
LOG="/var/log/ssh-ws-monitor.log"
WEBSOCKIFY_PORT=80
SSH_PORT=22
BAN_DURATION=43200  # 12 hours in seconds
MAX_CONNECTIONS=2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================
# INSTALL / SETUP
# ============================================================

install_dependencies() {
    echo -e "${CYAN}[*] กำลังติดตั้ง dependencies...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get install -y -qq curl wget python3 python3-pip sqlite3 ufw iptables net-tools procps 2>/dev/null
    pip3 install websockify --break-system-packages -q 2>/dev/null
    echo -e "${GREEN}[✓] ติดตั้งสำเร็จ${NC}"
}

setup_database() {
    mkdir -p /etc/ssh-ws
    sqlite3 "$DB" "
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        expire_date TEXT NOT NULL,
        data_limit_mb INTEGER NOT NULL,
        data_used_mb REAL DEFAULT 0,
        max_conn INTEGER DEFAULT $MAX_CONNECTIONS,
        status TEXT DEFAULT 'active',
        ban_until INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now','localtime'))
    );
    CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL,
        pid INTEGER,
        ip TEXT,
        connected_at TEXT DEFAULT (datetime('now','localtime'))
    );
    "
    chmod 600 "$DB"
}

setup_websockify_service() {
    cat > /etc/systemd/system/ssh-ws.service <<EOF
[Unit]
Description=SSH over WebSocket (Port 80)
After=network.target

[Service]
ExecStart=/usr/local/bin/websockify 0.0.0.0:$WEBSOCKIFY_PORT localhost:$SSH_PORT --web=/dev/null
Restart=always
RestartSec=3
User=root
StandardOutput=append:$LOG
StandardError=append:$LOG

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ssh-ws
    systemctl restart ssh-ws
}

setup_monitor_service() {
    cat > /usr/local/bin/ssh-ws-monitor <<'MONITOR'
#!/bin/bash
DB="/etc/ssh-ws/users.db"
MAX_CONNECTIONS=2
BAN_DURATION=43200

while true; do
    # Auto-unban expired bans
    NOW=$(date +%s)
    sqlite3 "$DB" "UPDATE users SET status='active', ban_until=0
                   WHERE status='banned' AND ban_until > 0 AND ban_until <= $NOW;"

    # Check active SSH connections per user
    declare -A user_conn
    while IFS= read -r line; do
        user=$(echo "$line" | awk '{print $1}')
        [[ -z "$user" ]] && continue
        user_conn["$user"]=$(( ${user_conn["$user"]:-0} + 1 ))
    done < <(who | awk '{print $1}')

    for user in "${!user_conn[@]}"; do
        count=${user_conn[$user]}
        limit=$(sqlite3 "$DB" "SELECT max_conn FROM users WHERE username='$user' AND status='active';" 2>/dev/null)
        [[ -z "$limit" ]] && continue
        if [[ "$count" -gt "$limit" ]]; then
            ban_until=$(( NOW + BAN_DURATION ))
            sqlite3 "$DB" "UPDATE users SET status='banned', ban_until=$ban_until WHERE username='$user';"
            pkill -u "$user" -9 2>/dev/null
            echo "[$(date)] BANNED: $user (connections: $count > $limit)" >> /var/log/ssh-ws-monitor.log
        fi
    done

    # Check expired accounts
    TODAY=$(date +%Y-%m-%d)
    sqlite3 "$DB" "SELECT username FROM users WHERE status='active' AND expire_date < '$TODAY';" | while read -r user; do
        pkill -u "$user" -9 2>/dev/null
        sqlite3 "$DB" "UPDATE users SET status='expired' WHERE username='$user';"
    done

    # Check data quota
    sqlite3 "$DB" "SELECT username FROM users WHERE status='active' AND data_used_mb >= data_limit_mb;" | while read -r user; do
        pkill -u "$user" -9 2>/dev/null
        sqlite3 "$DB" "UPDATE users SET status='quota_exceeded' WHERE username='$user';"
    done

    sleep 10
done
MONITOR

    chmod +x /usr/local/bin/ssh-ws-monitor

    cat > /etc/systemd/system/ssh-ws-monitor.service <<EOF
[Unit]
Description=SSH-WS Connection Monitor
After=network.target

[Service]
ExecStart=/usr/local/bin/ssh-ws-monitor
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ssh-ws-monitor
    systemctl restart ssh-ws-monitor
}

setup_ufw() {
    ufw allow $WEBSOCKIFY_PORT/tcp 2>/dev/null
    ufw allow $SSH_PORT/tcp 2>/dev/null
    echo "y" | ufw enable 2>/dev/null
}

full_install() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║     SSH-WS MANAGER — INSTALLATION    ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    install_dependencies
    setup_database
    setup_websockify_service
    setup_monitor_service
    setup_ufw
    echo -e "\n${GREEN}${BOLD}[✓] ติดตั้ง SSH-WS Manager สำเร็จแล้ว!${NC}"
    echo -e "${DIM}  websockify รันที่ port $WEBSOCKIFY_PORT → SSH port $SSH_PORT${NC}"
    echo -e "${DIM}  Monitor service ทำงานอัตโนมัติ${NC}\n"
    read -p "กด Enter เพื่อไปยังเมนูหลัก..."
    main_menu
}

# ============================================================
# UI HELPERS
# ============================================================

draw_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║          SSH-WS MANAGER  •  PORT 80             ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    local STATUS=$(systemctl is-active ssh-ws 2>/dev/null)
    if [[ "$STATUS" == "active" ]]; then
        echo -e "  ${GREEN}● WebSocket Service: RUNNING${NC}  ${DIM}|  Port: $WEBSOCKIFY_PORT → SSH :$SSH_PORT${NC}"
    else
        echo -e "  ${RED}● WebSocket Service: STOPPED${NC}"
    fi
    local TOTAL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo 0)
    local ACTIVE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE status='active';" 2>/dev/null || echo 0)
    local BANNED=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE status='banned';" 2>/dev/null || echo 0)
    echo -e "  ${DIM}Users: ${WHITE}$TOTAL total${DIM} | ${GREEN}$ACTIVE active${DIM} | ${RED}$BANNED banned${NC}\n"
}

press_enter() {
    echo -e "\n${DIM}  กด Enter เพื่อกลับเมนูหลัก...${NC}"
    read -r
}

confirm() {
    local msg="$1"
    echo -ne "${YELLOW}  $msg [y/N]: ${NC}"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ============================================================
# USER MANAGEMENT
# ============================================================

create_user() {
    draw_header
    echo -e "${WHITE}${BOLD}  [ สร้างบัญชีผู้ใช้ใหม่ ]${NC}\n"

    echo -ne "  ชื่อผู้ใช้ (username): "
    read -r username
    [[ -z "$username" ]] && echo -e "${RED}  ✗ ไม่ได้ใส่ชื่อผู้ใช้${NC}" && press_enter && return

    # Check duplicate
    EXISTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='$username';")
    [[ "$EXISTS" -gt 0 ]] && echo -e "${RED}  ✗ ชื่อผู้ใช้นี้มีอยู่แล้ว${NC}" && press_enter && return

    echo -ne "  รหัสผ่าน (password): "
    read -rs password
    echo
    [[ -z "$password" ]] && echo -e "${RED}  ✗ ไม่ได้ใส่รหัสผ่าน${NC}" && press_enter && return

    echo -ne "  จำนวนวันใช้งาน (เช่น 30): "
    read -r days
    [[ ! "$days" =~ ^[0-9]+$ ]] && echo -e "${RED}  ✗ จำนวนวันไม่ถูกต้อง${NC}" && press_enter && return

    echo -ne "  ขีดจำกัดข้อมูล MB (เช่น 10240 = 10GB): "
    read -r data_mb
    [[ ! "$data_mb" =~ ^[0-9]+$ ]] && echo -e "${RED}  ✗ ข้อมูลไม่ถูกต้อง${NC}" && press_enter && return

    echo -ne "  จำนวนการเชื่อมต่อสูงสุด (default: $MAX_CONNECTIONS): "
    read -r max_conn
    [[ ! "$max_conn" =~ ^[0-9]+$ ]] && max_conn=$MAX_CONNECTIONS

    EXPIRE=$(date -d "+${days} days" +%Y-%m-%d)

    # Create system user
    useradd -M -s /bin/false "$username" 2>/dev/null
    echo "$username:$password" | chpasswd

    # Save to DB
    sqlite3 "$DB" "INSERT INTO users (username, password, expire_date, data_limit_mb, max_conn)
                   VALUES ('$username', '$password', '$EXPIRE', $data_mb, $max_conn);"

    echo -e "\n  ${GREEN}${BOLD}✓ สร้างบัญชีสำเร็จ!${NC}"
    echo -e "  ${DIM}┌─────────────────────────────────────┐${NC}"
    echo -e "  ${DIM}│${NC}  ชื่อผู้ใช้  : ${WHITE}${BOLD}$username${NC}"
    echo -e "  ${DIM}│${NC}  รหัสผ่าน   : ${WHITE}${BOLD}$password${NC}"
    echo -e "  ${DIM}│${NC}  หมดอายุ    : ${YELLOW}$EXPIRE${NC}"
    echo -e "  ${DIM}│${NC}  ข้อมูล     : ${CYAN}${data_mb} MB${NC}"
    echo -e "  ${DIM}│${NC}  Max Conn   : ${CYAN}$max_conn${NC}"
    echo -e "  ${DIM}└─────────────────────────────────────┘${NC}"

    # Show connection info
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    echo -e "\n  ${CYAN}${BOLD}ข้อมูลการเชื่อมต่อ:${NC}"
    echo -e "  ${DIM}Host: ${WHITE}$SERVER_IP${NC}"
    echo -e "  ${DIM}Port: ${WHITE}$WEBSOCKIFY_PORT${NC}"
    echo -e "  ${DIM}User: ${WHITE}$username${NC}  Pass: ${WHITE}$password${NC}"

    press_enter
}

list_users() {
    draw_header
    echo -e "${WHITE}${BOLD}  [ รายการผู้ใช้ทั้งหมด ]${NC}\n"

    local rows
    rows=$(sqlite3 "$DB" "SELECT username, expire_date, data_used_mb, data_limit_mb, max_conn, status, ban_until
                          FROM users ORDER BY created_at DESC;" 2>/dev/null)

    if [[ -z "$rows" ]]; then
        echo -e "  ${DIM}ยังไม่มีผู้ใช้งาน${NC}"
        press_enter
        return
    fi

    printf "  ${BOLD}%-18s %-12s %-18s %-8s %-12s${NC}\n" "USERNAME" "EXPIRE" "DATA USED/LIMIT" "CONN" "STATUS"
    echo -e "  ${DIM}$(printf '%.0s─' {1..70})${NC}"

    NOW=$(date +%s)
    while IFS='|' read -r user expire used limit conn status ban_until; do
        data_display="${used}/${limit} MB"
        case "$status" in
            active)
                expire_days=$(( ( $(date -d "$expire" +%s) - NOW ) / 86400 ))
                if [[ $expire_days -le 3 ]]; then
                    STATUS_COLOR="${YELLOW}active(${expire_days}d)${NC}"
                else
                    STATUS_COLOR="${GREEN}active${NC}"
                fi
                ;;
            banned)
                remain=$(( (ban_until - NOW) / 3600 ))
                STATUS_COLOR="${RED}BANNED(${remain}h)${NC}"
                ;;
            expired)   STATUS_COLOR="${MAGENTA}expired${NC}" ;;
            quota_exceeded) STATUS_COLOR="${YELLOW}quota!${NC}" ;;
            *)         STATUS_COLOR="${DIM}$status${NC}" ;;
        esac
        printf "  %-18s %-12s %-18s %-8s " "$user" "$expire" "$data_display" "$conn"
        echo -e "$STATUS_COLOR"
    done <<< "$rows"

    press_enter
}

# ============================================================
# BAN MANAGEMENT
# ============================================================

list_banned() {
    draw_header
    echo -e "${WHITE}${BOLD}  [ ผู้ใช้ที่ถูกแบน ]${NC}\n"

    NOW=$(date +%s)
    local rows
    rows=$(sqlite3 "$DB" "SELECT username, ban_until FROM users WHERE status='banned' ORDER BY ban_until;" 2>/dev/null)

    if [[ -z "$rows" ]]; then
        echo -e "  ${GREEN}  ไม่มีผู้ใช้ที่ถูกแบนอยู่ในขณะนี้${NC}"
        press_enter
        return
    fi

    echo -e "  ${BOLD}  #   USERNAME             แบนหมดอายุ              เหลืออีก${NC}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..60})${NC}"

    local i=1
    while IFS='|' read -r user ban_until; do
        local expire_str remain
        expire_str=$(date -d "@$ban_until" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
        remain_sec=$(( ban_until - NOW ))
        if [[ $remain_sec -gt 0 ]]; then
            remain_h=$(( remain_sec / 3600 ))
            remain_m=$(( (remain_sec % 3600) / 60 ))
            remain="${remain_h}h ${remain_m}m"
        else
            remain="หมดอายุแล้ว"
        fi
        printf "  ${RED}%-4s${NC} %-20s %-24s ${YELLOW}%s${NC}\n" "$i" "$user" "$expire_str" "$remain"
        i=$(( i + 1 ))
    done <<< "$rows"

    echo -e "\n  ${CYAN}ต้องการปลดแบน?${NC}"
    echo -e "  ${DIM}[A] ปลดแบนทุกคน  [ใส่ชื่อ] ปลดแบนเฉพาะคน  [Enter] ยกเลิก${NC}"
    echo -ne "  > "
    read -r choice

    if [[ "$choice" == "A" || "$choice" == "a" ]]; then
        sqlite3 "$DB" "UPDATE users SET status='active', ban_until=0 WHERE status='banned';"
        echo -e "  ${GREEN}✓ ปลดแบนทุกคนแล้ว${NC}"
    elif [[ -n "$choice" ]]; then
        EXISTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM users WHERE username='$choice' AND status='banned';")
        if [[ "$EXISTS" -gt 0 ]]; then
            sqlite3 "$DB" "UPDATE users SET status='active', ban_until=0 WHERE username='$choice';"
            echo -e "  ${GREEN}✓ ปลดแบน '$choice' แล้ว${NC}"
        else
            echo -e "  ${RED}✗ ไม่พบผู้ใช้นี้ในรายการแบน${NC}"
        fi
    fi

    press_enter
}

unban_user() {
    draw_header
    echo -e "${WHITE}${BOLD}  [ ปลดแบนผู้ใช้ ]${NC}\n"

    echo -ne "  ชื่อผู้ใช้ที่ต้องการปลดแบน: "
    read -r username
    [[ -z "$username" ]] && press_enter && return

    STATUS=$(sqlite3 "$DB" "SELECT status FROM users WHERE username='$username';" 2>/dev/null)
    if [[ -z "$STATUS" ]]; then
        echo -e "  ${RED}✗ ไม่พบผู้ใช้ '$username'${NC}"
    elif [[ "$STATUS" != "banned" ]]; then
        echo -e "  ${YELLOW}  ผู้ใช้นี้ไม่ได้ถูกแบน (สถานะ: $STATUS)${NC}"
    else
        sqlite3 "$DB" "UPDATE users SET status='active', ban_until=0 WHERE username='$username';"
        echo -e "  ${GREEN}✓ ปลดแบน '$username' สำเร็จ${NC}"
    fi
    press_enter
}

# ============================================================
# RENEW / EXTEND
# ============================================================

renew_user() {
    draw_header
    echo -e "${WHITE}${BOLD}  [ ต่ออายุ / เพิ่มข้อมูล ]${NC}\n"

    echo -ne "  ชื่อผู้ใช้: "
    read -r username
    [[ -z "$username" ]] && press_enter && return

    local row
    row=$(sqlite3 "$DB" "SELECT expire_date, data_limit_mb, data_used_mb, status FROM users WHERE username='$username';" 2>/dev/null)
    if [[ -z "$row" ]]; then
        echo -e "  ${RED}✗ ไม่พบผู้ใช้ '$username'${NC}"
        press_enter
        return
    fi

    IFS='|' read -r expire data_limit data_used status <<< "$row"
    echo -e "  ${DIM}สถานะปัจจุบัน:${NC}"
    echo -e "  หมดอายุ   : ${YELLOW}$expire${NC}"
    echo -e "  ข้อมูล    : ${CYAN}${data_used}/${data_limit} MB${NC}"
    echo -e "  สถานะ     : $status\n"

    echo -ne "  เพิ่มจำนวนวัน (0 = ไม่เปลี่ยน): "
    read -r add_days

    echo -ne "  เพิ่ม Data MB (0 = ไม่เปลี่ยน): "
    read -r add_data

    local new_expire="$expire"
    local new_limit="$data_limit"

    if [[ "$add_days" =~ ^[0-9]+$ && "$add_days" -gt 0 ]]; then
        # If already expired, extend from today
        TODAY=$(date +%Y-%m-%d)
        if [[ "$expire" < "$TODAY" ]]; then
            new_expire=$(date -d "+${add_days} days" +%Y-%m-%d)
        else
            new_expire=$(date -d "$expire +${add_days} days" +%Y-%m-%d)
        fi
    fi

    if [[ "$add_data" =~ ^[0-9]+$ && "$add_data" -gt 0 ]]; then
        new_limit=$(( data_limit + add_data ))
    fi

    sqlite3 "$DB" "UPDATE users SET expire_date='$new_expire', data_limit_mb=$new_limit,
                   status='active', ban_until=0 WHERE username='$username';"

    echo -e "\n  ${GREEN}✓ อัปเดตสำเร็จ!${NC}"
    echo -e "  หมดอายุใหม่ : ${YELLOW}$new_expire${NC}"
    echo -e "  ข้อมูลใหม่  : ${CYAN}${new_limit} MB${NC}"
    press_enter
}

# ============================================================
# DELETE USER
# ============================================================

delete_user() {
    draw_header
    echo -e "${WHITE}${BOLD}  [ ลบบัญชีผู้ใช้ ]${NC}\n"

    echo -ne "  ชื่อผู้ใช้ที่ต้องการลบ: "
    read -r username
    [[ -z "$username" ]] && press_enter && return

    local row
    row=$(sqlite3 "$DB" "SELECT username, expire_date, status FROM users WHERE username='$username';" 2>/dev/null)
    if [[ -z "$row" ]]; then
        echo -e "  ${RED}✗ ไม่พบผู้ใช้ '$username'${NC}"
        press_enter
        return
    fi

    echo -e "  ${YELLOW}พบผู้ใช้: $username${NC}"
    if confirm "ยืนยันการลบบัญชี '$username'?"; then
        pkill -u "$username" -9 2>/dev/null
        userdel "$username" 2>/dev/null
        sqlite3 "$DB" "DELETE FROM users WHERE username='$username';
                       DELETE FROM sessions WHERE username='$username';"
        echo -e "  ${GREEN}✓ ลบบัญชี '$username' สำเร็จแล้ว${NC}"
    else
        echo -e "  ${DIM}ยกเลิกการลบ${NC}"
    fi
    press_enter
}

# ============================================================
# SERVICE CONTROL
# ============================================================

service_status() {
    draw_header
    echo -e "${WHITE}${BOLD}  [ สถานะ Services ]${NC}\n"

    for svc in ssh-ws ssh-ws-monitor; do
        STATUS=$(systemctl is-active "$svc" 2>/dev/null)
        if [[ "$STATUS" == "active" ]]; then
            echo -e "  ${GREEN}●${NC} $svc : ${GREEN}RUNNING${NC}"
        else
            echo -e "  ${RED}●${NC} $svc : ${RED}STOPPED${NC}"
        fi
    done

    echo -e "\n  ${DIM}Active SSH connections:${NC}"
    who | awk '{print "  " $1 " from " $5 " at " $3 " " $4}' | head -20
    if [[ -z "$(who)" ]]; then
        echo -e "  ${DIM}ไม่มี active connections${NC}"
    fi

    echo -e "\n  ${DIM}[R] Restart services  [Enter] กลับ${NC}"
    echo -ne "  > "
    read -r choice
    if [[ "$choice" == "R" || "$choice" == "r" ]]; then
        systemctl restart ssh-ws ssh-ws-monitor
        echo -e "  ${GREEN}✓ Restart แล้ว${NC}"
        sleep 1
    fi
}

# ============================================================
# MAIN MENU
# ============================================================

main_menu() {
    while true; do
        draw_header
        echo -e "  ${BOLD}${WHITE}เมนูหลัก${NC}\n"
        echo -e "  ${CYAN}${BOLD}── จัดการผู้ใช้ ─────────────────────${NC}"
        echo -e "  ${WHITE}[1]${NC}  สร้างบัญชีผู้ใช้ใหม่"
        echo -e "  ${WHITE}[2]${NC}  ดูรายการผู้ใช้ทั้งหมด"
        echo -e "  ${WHITE}[3]${NC}  ต่ออายุ / เพิ่ม Data"
        echo -e "  ${WHITE}[4]${NC}  ลบบัญชีผู้ใช้"
        echo -e ""
        echo -e "  ${RED}${BOLD}── ระบบแบน ──────────────────────────${NC}"
        echo -e "  ${WHITE}[5]${NC}  ดูผู้ใช้ที่ถูกแบน + ปลดแบน"
        echo -e "  ${WHITE}[6]${NC}  ปลดแบนผู้ใช้ (พิมพ์ชื่อ)"
        echo -e ""
        echo -e "  ${BLUE}${BOLD}── ระบบ ──────────────────────────────${NC}"
        echo -e "  ${WHITE}[7]${NC}  สถานะ Services"
        echo -e "  ${WHITE}[0]${NC}  ออกจากโปรแกรม"
        echo -e ""
        echo -ne "  ${YELLOW}เลือก: ${NC}"
        read -r choice

        case "$choice" in
            1) create_user ;;
            2) list_users ;;
            3) renew_user ;;
            4) delete_user ;;
            5) list_banned ;;
            6) unban_user ;;
            7) service_status ;;
            0) echo -e "\n  ${DIM}Bye!${NC}\n"; exit 0 ;;
            *) echo -e "  ${RED}✗ ตัวเลือกไม่ถูกต้อง${NC}"; sleep 1 ;;
        esac
    done
}

# ============================================================
# ENTRYPOINT
# ============================================================

# Check root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}✗ ต้องรันด้วย root (sudo bash $0)${NC}"
    exit 1
fi

# First run check
if [[ ! -f "$DB" ]]; then
    echo -e "${YELLOW}[!] ตรวจพบการรันครั้งแรก — จะเริ่มติดตั้ง...${NC}"
    sleep 1
    full_install
else
    main_menu
fi
