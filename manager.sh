#!/bin/bash

# --- PRE-INSTALLATION ---
apt-get update -qq && apt-get install iptables-persistent jq vnstat curl wget sudo -y -qq

# Path Konfigurasi
CONFIG_DIR="/etc/zivpn"
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
TG_CONF="/etc/zivpn/telegram.conf"
MANAGER_SCRIPT="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/menu"

mkdir -p "$CONFIG_DIR"
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"
[ ! -f "$TG_CONF" ] && touch "$TG_CONF"

# --- MENULIS SCRIPT MANAGER ---
cat <<EOF > "$MANAGER_SCRIPT"
#!/bin/bash

# Load Telegram Data
[ -f "$TG_CONF" ] && source "$TG_CONF"

# Path Konfigurasi
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
TG_CONF="/etc/zivpn/telegram.conf"
SERVICE_NAME="zivpn.service"
GITHUB_URL="https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh"

# Warna Harmony V17
C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# --- FUNGSI HAPUS AKUN (DENGAN NOMOR) ---
delete_account() {
    clear
    echo -e "\${C}┏━━━━━━━━━━━━━━\${Y} HAPUS AKUN ZIVPN \${C}━━━━━━━━━━━━━━┓\${NC}"
    
    # Ambil daftar user
    mapfile -t USER_LIST < <(jq -r '.auth.config[]' "\$CONFIG_FILE")
    
    if [ \${#USER_LIST[@]} -eq 0 ]; then
        printf " \${C}┃\${NC} \${R}%-40s\${NC} \${C}┃\${NC}\n" "Tidak ada akun yang terdaftar."
        echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
        sleep 2; return
    fi

    # Tampilkan daftar dengan nomor
    index=1
    for user in "\${USER_LIST[@]}"; do
        printf " \${C}┃\${NC}  \${Y}[%02d]\${NC} %-34s \${C}┃\${NC}\n" "\$index" "\$user"
        ((index++))
    done
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
    
    echo -ne "  \${B}Pilih Nomor User yang akan dihapus\${NC}: " && read user_idx
    
    # Validasi input nomor
    if [[ ! "\$user_idx" =~ ^[0-9]+\$ ]] || [ "\$user_idx" -lt 1 ] || [ "\$user_idx" -ge "\$index" ]; then
        echo -e "  \${R}❌ Nomor tidak valid!\${NC}"
        sleep 1; return
    fi

    # Ambil nama user berdasarkan index (array mulai dari 0)
    target_user=\${USER_LIST[\$((user_idx-1))]}

    # Proses Hapus
    jq --arg u "\$target_user" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"
    jq --arg u "\$target_user" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
    
    systemctl restart "\$SERVICE_NAME" 2>/dev/null
    echo -e "  \${G}✅ Akun [\$target_user] Berhasil Dihapus!\${NC}"
    sleep 2
}

# --- FUNGSI STATUS SYSTEM ---
show_system_status() {
    clear
    local UPTIME=\$(uptime -p | sed 's/up //')
    local RAM_USED=\$(free -h | awk '/Mem:/ {print \$3}')
    local RAM_TOTAL=\$(free -h | awk '/Mem:/ {print \$2}')
    local DISK_USED=\$(df -h / | awk '/\// {print \$3}' | tail -n 1)
    local CPU_LOAD=\$(top -bn1 | grep "Cpu(s)" | awk '{print \$2 + \$4}')"%"

    echo -e "\${C}┏━━━━━━━━━━━━━\${Y} SYSTEM INFORMATION \${C}━━━━━━━━━━━━━┓\${NC}"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "Uptime" "\$UPTIME"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "CPU Load" "\$CPU_LOAD"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "Memory" "\$RAM_USED / \$RAM_TOTAL"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "Disk Used" "\$DISK_USED"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
    echo ""
    read -rp " Tekan [Enter] untuk kembali..."
}

# --- FUNGSI CORE ---
draw_header() {
    clear
    VPS_IP=\$(curl -s ifconfig.me)
    NET_IFACE=\$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    BW_JSON=\$(vnstat -i "\$NET_IFACE" --json 2>/dev/null)
    T_D=\$(date +%-d); T_M=\$(date +%-m); T_Y=\$(date +%Y)
    BW_D_RAW=\$(echo "\$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .rx // 0" 2>/dev/null)
    BW_U_RAW=\$(echo "\$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .tx // 0" 2>/dev/null)
    BW_D=\$(awk -v b="\$BW_D_RAW" 'BEGIN {printf "%.2f MB", b/1024/1024}')
    BW_U=\$(awk -v b="\$BW_U_RAW" 'BEGIN {printf "%.2f MB", b/1024/1024}')

    echo -e "\${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\${NC}"
    echo -e "\${C}┃\${NC}      \${Y}ZIVPN HARMONY PANEL V21\${NC}       \${C}┃\${NC} \${B}IP:\${NC} \${G}\$VPS_IP\${NC}"
    echo -e "\${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫\${NC}"
    echo -e "\${C}┃\${NC} \${B}Traffic Hari Ini:\${NC} \${G}↓\$BW_D\${NC} | \${R}↑\$BW_U\${NC}"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
}

# --- LOOP MENU ---
while true; do
    draw_header
    echo -e "  \${C}[\${Y}01\${C}]\${NC} Tambah Akun           \${C}[\${Y}06\${C}]\${NC} Backup Telegram"
    echo -e "  \${C}[\${Y}02\${C}]\${NC} Hapus Akun            \${C}[\${Y}07\${C}]\${NC} Restore Telegram"
    echo -e "  \${C}[\${Y}03\${C}]\${NC} Lihat Daftar Akun     \${C}[\${Y}08\${C}]\${NC} Settings Telegram"
    echo -e "  \${C}[\${Y}04\${C}]\${NC} Restart Service       \${C}[\${Y}09\${C}]\${NC} Update Script"
    echo -e "  \${C}[\${Y}05\${C}]\${NC} Status System         \${C}[\${Y}00\${C}]\${NC} Keluar"
    echo -e "\${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
    echo -ne "  \${B}Pilih menu\${NC}: " && read choice

    case \$choice in
        1|01) read -rp "  User: " n; read -rp "  Hari: " d; exp=\$(date -d "+\$d days" +%Y-%m-%d); jq --arg u "\$n" '.auth.config += [\$u]' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$n" --arg e "\$exp" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo -e "\${G}Berhasil!\${NC}"; sleep 1 ;;
        2|02) delete_account ;;
        3|03) clear; printf "\${Y}%-18s %-12s\${NC}\n" "USER" "EXPIRED"; echo "------------------------------"; jq -r '.accounts[] | "\(.user) \(.expired)"' "\$META_FILE" | while read -r u e; do printf "%-18s %-12s\n" "\$u" "\$e"; done; read -rp "Enter..." ;;
        4|04) systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo "Restarted."; sleep 1 ;;
        5|05) show_system_status ;;
        6|06) if [ -z "\$TG_BOT_TOKEN" ]; then echo "Setup Telegram Dulu!"; sleep 2; else cp "\$CONFIG_FILE" /tmp/c.json; curl -s -F chat_id="\$TG_CHAT_ID" -F document=@/tmp/c.json https://api.telegram.org/bot\$TG_BOT_TOKEN/sendDocument > /dev/null; echo "Backup Sent!"; sleep 1; fi ;;
        7|07) restore_telegram ;;
        8|08) clear; echo -ne "Token: " && read NT; echo -ne "ID: " && read NI; echo "TG_BOT_TOKEN=\"\$NT\"" > "\$TG_CONF"; echo "TG_CHAT_ID=\"\$NI\"" >> "\$TG_CONF"; source "\$TG_CONF"; echo "Saved!"; sleep 1 ;;
        9|09) wget -q -O /tmp/z.sh "\$GITHUB_URL" && mv /tmp/z.sh "/usr/local/bin/zivpn-manager.sh" && chmod +x "/usr/local/bin/zivpn-manager.sh" && echo "Success!"; sleep 1; exit 0 ;;
        0|00) exit 0 ;;
    esac
done
EOF

# --- FINALISASI ---
chmod +x "$MANAGER_SCRIPT"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT"
chmod +x "$SHORTCUT"

clear
echo -e "${GREEN}✅ UPDATE V21: FITUR HAPUS DENGAN NOMOR SELESAI!${NC}"
echo -e "Ketik ${YELLOW}'menu'${NC} lalu pilih 02 untuk mencoba."
