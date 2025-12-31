#!/bin/bash

# --- PRE-INSTALLATION ---
apt-get update -qq && apt-get install iptables-persistent jq vnstat curl wget sudo -y -qq

# Path Konfigurasi
CONFIG_DIR="/etc/zivpn"
CONFIG_FILE="$CONFIG_DIR/config.json"
META_FILE="$CONFIG_DIR/accounts_meta.json"
TG_CONF="$CONFIG_DIR/telegram.conf"
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

# Variabel Statis
GITHUB_URL="https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh"
CONFIG_FILE="$CONFIG_FILE"
META_FILE="$META_FILE"
SERVICE_NAME="zivpn.service"

# Warna
C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; P='\e[1;35m'; B='\e[1;34m'; NC='\e[0m'

# --- FUNGSI CORE ---
send_tg() {
    if [ ! -z "\$TG_BOT_TOKEN" ] && [ ! -z "\$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot\$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="\$TG_CHAT_ID" -d parse_mode="HTML" --data-urlencode text="\$1" >/dev/null
    fi
}

sync_accounts() {
    local all_pass=\$(jq -r '.auth.config[]' "\$CONFIG_FILE" 2>/dev/null)
    for pass in \$all_pass; do
        [ -z "\$pass" ] || [ "\$pass" == "null" ] && continue
        local exists=\$(jq -r --arg u "\$pass" '.accounts[] | select(.user==\$u) | .user' "\$META_FILE" 2>/dev/null)
        if [ -z "\$exists" ]; then
            jq --arg u "\$pass" --arg e "2099-12-31" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
        fi
    done
}

auto_remove_expired() {
    local today=\$(date +%s)
    local changed=false
    while read -r acc; do
        [ -z "\$acc" ] && continue
        local user=\$(echo "\$acc" | jq -r '.user')
        local exp=\$(echo "\$acc" | jq -r '.expired')
        local exp_ts=\$(date -d "\$exp" +%s 2>/dev/null)
        if [ \$? -eq 0 ] && [ "\$today" -ge "\$exp_ts" ]; then
            jq --arg u "\$user" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"
            jq --arg u "\$user" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
            send_tg "<b>⚠️ EXPIRED:</b> Akun <code>\$user</code> telah dihapus otomatis."
            changed=true
        fi
    done < <(jq -c '.accounts[]' "\$META_FILE" 2>/dev/null)
    [ "\$changed" = true ] && systemctl restart "\$SERVICE_NAME" >/dev/null 2>&1
}

# --- FUNGSI INTERFACE ---
convert_bw() {
    local bytes=\$1
    if [ "\$bytes" -gt 1073741824 ]; then
        awk -v b="\$bytes" 'BEGIN {printf "%.2f GiB", b/1024/1024/1024}'
    else
        awk -v b="\$bytes" 'BEGIN {printf "%.2f MiB", b/1024/1024}'
    fi
}

system_status() {
    clear
    local OS_NAME=\$(grep -P '^PRETTY_NAME' /etc/os-release | cut -d'"' -f2)
    local CPU_USAGE=\$(top -bn1 | grep "Cpu(s)" | awk '{print \$2 + \$4}')
    local MEM_TOTAL=\$(free -h | awk '/Mem:/ {print \$2}')
    local MEM_USED=\$(free -h | awk '/Mem:/ {print \$3}')
    local DISK_USED=\$(df -h / | awk '/\// {print \$3}' | tail -n 1)
    local UPTIME=\$(uptime -p | sed 's/up //')

    echo -e "\${C}┏━━━━━━━━━━━━━\${Y} SYSTEM INFORMATION \${C}━━━━━━━━━━━━━┓\${NC}"
    printf " \${C}┃\${NC} %-15s : %-23s \${C}┃\${NC}\n" "OS" "\$OS_NAME"
    printf " \${C}┃\${NC} %-15s : %-23s \${C}┃\${NC}\n" "Uptime" "\$UPTIME"
    printf " \${C}┃\${NC} %-15s : %-23s \${C}┃\${NC}\n" "CPU Load" "\$CPU_USAGE %"
    printf " \${C}┃\${NC} %-15s : %-23s \${C}┃\${NC}\n" "RAM" "\$MEM_USED / \$MEM_TOTAL"
    printf " \${C}┃\${NC} %-15s : %-23s \${C}┃\${NC}\n" "Disk Used" "\$DISK_USED"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
    echo ""
    read -rp " Tekan [Enter] untuk kembali..."
}

draw_header() {
    clear
    VPS_IP=\$(curl -s ifconfig.me)
    NET_IFACE=\$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    BW_JSON=\$(vnstat -i "\$NET_IFACE" --json 2>/dev/null)
    T_D=\$(date +%-d); T_M=\$(date +%-m); T_Y=\$(date +%Y)
    BW_D_RAW=\$(echo "\$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .rx // 0" 2>/dev/null)
    BW_U_RAW=\$(echo "\$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .tx // 0" 2>/dev/null)
    
    echo -e "\${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\${NC}"
    echo -e "\${C}┃\${NC} \${P}⚡\${NC} \${Y}ZIVPN FINAL PANEL\${NC}      \${C}┃\${NC} \${B}IP:\${NC} \${G}\$VPS_IP\${NC}"
    echo -e "\${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫\${NC}"
    echo -e "\${C}┃\${NC} \${B}Traffic Hari Ini:\${NC} \${G}↓\$(convert_bw "\${BW_D_RAW:-0}")\${NC} | \${R}↑\$(convert_bw "\${BW_U_RAW:-0}")\${NC}"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
}

# --- LOOP MENU ---
case "\$1" in
    cron) sync_accounts; auto_remove_expired ;;
    *)
    while true; do
        sync_accounts; auto_remove_expired; draw_header
        echo -e "  \${C}[\${Y}01\${C}]\${NC} Tambah Akun Baru      \${C}[\${Y}05\${C}]\${NC} Status System"
        echo -e "  \${C}[\${Y}02\${C}]\${NC} Hapus Akun            \${C}[\${Y}06\${C}]\${NC} Backup Akun (.json)"
        echo -e "  \${C}[\${Y}03\${C}]\${NC} Lihat Daftar Akun     \${C}[\${Y}07\${C}]\${NC} \${P}Settings Telegram\${NC}"
        echo -e "  \${C}[\${Y}04\${C}]\${NC} Restart Service       \${C}[\${Y}08\${C}]\${NC} Update Script"
        echo -e "  \${C}[\${Y}00\${C}]\${NC} Keluar"
        echo -e "\${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
        echo -ne "  \${B}Pilih menu\${NC} [01-08]: " && read choice

        case \$choice in
            1|01) read -rp "  User: " n; read -rp "  Hari: " d; exp=\$(date -d "+\$d days" +%Y-%m-%d); jq --arg u "\$n" '.auth.config += [\$u]' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$n" --arg e "\$exp" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME" 2>/dev/null; send_tg "✅ Baru: \$n (Exp: \$exp)"; echo -e "\${G}Berhasil!\${NC}"; sleep 1 ;;
            2|02) read -rp "  User dihapus: " d; jq --arg u "\$d" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"; jq --arg u "\$d" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo -e "\${R}Dihapus.\${NC}"; sleep 1 ;;
            3|03) clear; printf "\${Y}%-18s %-12s %-10s\${NC}\n" "USER" "EXP" "STATUS"; echo "---------------------------------------"; jq -r '.accounts[] | "\(.user) \(.expired)"' "\$META_FILE" | while read -r u e; do t=\$(date +%s); x=\$(date -d "\$e" +%s); s="Aktif"; [ "\$t" -ge "\$x" ] && s="Exp"; printf "%-18s %-12s %-10s\n" "\$u" "\$e" "\$s"; done; read -rp "Enter..." ;;
            4|04) systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo "Restarted."; sleep 1 ;;
            5|05) system_status ;;
            6|06) if [ -z "\$TG_BOT_TOKEN" ]; then echo -e "\${R}Lakukan Menu 07 Terlebih Dahulu!\${NC}"; sleep 2; else cp "\$CONFIG_FILE" /tmp/c.json; curl -s -F chat_id="\$TG_CHAT_ID" -F document=@/tmp/c.json https://api.telegram.org/bot\$TG_BOT_TOKEN/sendDocument > /dev/null; echo "Backup dikirim ke Telegram!"; sleep 1; fi ;;
            7|07) clear; echo -e "\${C}Setup Telegram Bot\${NC}"; echo -ne "Token: " && read NEW_TOKEN; echo -ne "Chat ID: " && read NEW_ID; echo "TG_BOT_TOKEN=\"\$NEW_TOKEN\"" > "$TG_CONF"; echo "TG_CHAT_ID=\"\$NEW_ID\"" >> "$TG_CONF"; source "$TG_CONF"; echo "Tersimpan!"; sleep 1 ;;
            8|08) wget -q -O /tmp/z.sh "\$GITHUB_URL" && mv /tmp/z.sh "\$MANAGER_SCRIPT" && chmod +x "\$MANAGER_SCRIPT" && echo "Update Selesai!"; exit 0 ;;
            0|00) exit 0 ;;
        esac
    done
    ;;
esac
EOF

# --- FINALISASI SYSTEM ---
chmod +x "$MANAGER_SCRIPT"
echo "sudo bash $MANAGER_SCRIPT" > "$SHORTCUT"
chmod +x "$SHORTCUT"

# Cron Job (Setiap jam 00:00)
(crontab -l 2>/dev/null | grep -v "$MANAGER_SCRIPT cron") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * $MANAGER_SCRIPT cron") | crontab -

# Kernel Tuning (UDP Optimization)
cat <<EOF > /etc/sysctl.d/99-zivpn.conf
net.ipv4.ip_forward = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
sysctl --system > /dev/null

clear
echo -e "${GREEN}✅ ZIVPN MANAGER V13 SELESAI DIINSTALL!${NC}"
echo -e "Gunakan perintah ${YELLOW}'menu'${NC} untuk mengelola."
