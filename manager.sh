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

# Warna Harmony
C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# --- FUNGSI RESTORE TELEGRAM ---
restore_telegram() {
    clear
    echo -e "\${C}┏━━━━━━━━━━━━━\${Y} RESTORE VIA TELEGRAM \${C}━━━━━━━━━━━━┓\${NC}"
    if [ -z "\$TG_BOT_TOKEN" ]; then
        echo -e "  \${R}❌ Error: Setup Telegram dulu di menu 08!\${NC}"
        sleep 2; return
    fi

    echo -e "  \${Y}[-]\${NC} Mencari file backup di Bot Anda..."
    
    FILE_DATA=\$(curl -s "https://api.telegram.org/bot\$TG_BOT_TOKEN/getUpdates")
    FILE_ID=\$(echo "\$FILE_DATA" | jq -r '.result | reverse | .[] | select(.message.document.file_name=="config.json") | .message.document.file_id' | head -n 1)

    if [ -z "\$FILE_ID" ] || [ "\$FILE_ID" == "null" ]; then
        echo -e "  \${R}❌ Tidak ditemukan file 'config.json'.\${NC}"
        echo -e "  Pastikan Anda pernah Backup (Menu 06)."
        sleep 3; return
    fi

    FILE_PATH=\$(curl -s "https://api.telegram.org/bot\$TG_BOT_TOKEN/getFile?file_id=\$FILE_ID" | jq -r '.result.file_path')
    
    echo -e "  \${G}[+]\${NC} File ditemukan! Sedang mengunduh..."
    wget -q -O "\$CONFIG_FILE" "https://api.telegram.org/file/bot\$TG_BOT_TOKEN/\$FILE_PATH"

    if [ \$? -eq 0 ]; then
        systemctl restart "\$SERVICE_NAME" 2>/dev/null
        echo -e "  \${G}✅ Restore Berhasil! Akun telah dipulihkan.\${NC}"
    else
        echo -e "  \${R}❌ Gagal mengunduh file.\${NC}"
    fi
    sleep 2
}

# --- FUNGSI CORE ---
send_tg() {
    if [ ! -z "\$TG_BOT_TOKEN" ]; then
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
            send_tg "<b>⚠️ EXPIRED:</b> Akun <code>\$user</code> dihapus otomatis."
            changed=true
        fi
    done < <(jq -c '.accounts[]' "\$META_FILE" 2>/dev/null)
    [ "\$changed" = true ] && systemctl restart "\$SERVICE_NAME" >/dev/null 2>&1
}

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
    echo -e "\${C}┃\${NC}      \${Y}ZIVPN HARMONY PANEL V17\${NC}       \${C}┃\${NC} \${B}IP:\${NC} \${G}\$VPS_IP\${NC}"
    echo -e "\${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫\${NC}"
    echo -e "\${C}┃\${NC} \${B}Traffic Hari Ini:\${NC} \${G}↓\$BW_D\${NC} | \${R}↑\$BW_U\${NC}"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
}

# --- LOOP MENU ---
case "\$1" in
    cron) sync_accounts; auto_remove_expired ;;
    *)
    while true; do
        sync_accounts; auto_remove_expired; draw_header
        echo -e "  \${C}[\${Y}01\${C}]\${NC} Tambah Akun           \${C}[\${Y}06\${C}]\${NC} Backup Telegram"
        echo -e "  \${C}[\${Y}02\${C}]\${NC} Hapus Akun            \${C}[\${Y}07\${C}]\${NC} Restore Telegram"
        echo -e "  \${C}[\${Y}03\${C}]\${NC} Lihat Daftar Akun     \${C}[\${Y}08\${C}]\${NC} Settings Telegram"
        echo -e "  \${C}[\${Y}04\${C}]\${NC} Restart Service       \${C}[\${Y}09\${C}]\${NC} Update Script"
        echo -e "  \${C}[\${Y}05\${C}]\${NC} Status System         \${C}[\${Y}00\${C}]\${NC} Keluar"
        echo -e "\${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
        echo -ne "  \${B}Pilih menu\${NC}: " && read choice

        case \$choice in
            1|01) read -rp "  User: " n; read -rp "  Hari: " d; exp=\$(date -d "+\$d days" +%Y-%m-%d); jq --arg u "\$n" '.auth.config += [\$u]' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$n" --arg e "\$exp" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME" 2>/dev/null; send_tg "✅ Baru: \$n (Exp: \$exp)"; echo -e "\${G}Berhasil!\${NC}"; sleep 1 ;;
            2|02) read -rp "  User dihapus: " d; jq --arg u "\$d" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"; jq --arg u "\$d" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo -e "\${R}Dihapus.\${NC}"; sleep 1 ;;
            3|03) clear; printf "\${Y}%-18s %-12s\${NC}\n" "USER" "EXPIRED"; echo "------------------------------"; jq -r '.accounts[] | "\(.user) \(.expired)"' "\$META_FILE" | while read -r u e; do printf "%-18s %-12s\n" "\$u" "\$e"; done; read -rp "Enter..." ;;
            4|04) systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo "Restarted."; sleep 1 ;;
            5|05) clear; uptime; free -h; df -h /; read -rp "Enter..." ;;
            6|06) if [ -z "\$TG_BOT_TOKEN" ]; then echo "Setup Telegram Dulu!"; sleep 2; else cp "\$CONFIG_FILE" /tmp/c.json; curl -s -F chat_id="\$TG_CHAT_ID" -F document=@/tmp/c.json https://api.telegram.org/bot\$TG_BOT_TOKEN/sendDocument > /dev/null; echo "Backup Sent!"; sleep 1; fi ;;
            7|07) restore_telegram ;;
            8|08) clear; echo -e "\${C}Setup Telegram Bot\${NC}"; echo -ne "Token: " && read NT; echo -ne "ID: " && read NI; echo "TG_BOT_TOKEN=\"\$NT\"" > "\$TG_CONF"; echo "TG_CHAT_ID=\"\$NI\"" >> "\$TG_CONF"; source "\$TG_CONF"; echo "Saved!"; sleep 1 ;;
            9|09) wget -q -O /tmp/z.sh "\$GITHUB_URL" && mv /tmp/z.sh "/usr/local/bin/zivpn-manager.sh" && chmod +x "/usr/local/bin/zivpn-manager.sh" && echo "Success!"; sleep 1; exit 0 ;;
            0|00) exit 0 ;;
        esac
    done
    ;;
esac
EOF

# --- FINALISASI ---
chmod +x "$MANAGER_SCRIPT"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT"
chmod +x "$SHORTCUT"

clear
echo -e "${GREEN}✅ ZIVPN MANAGER V17 (COLOR SYNC) SELESAI!${NC}"
echo -e "Ketik ${YELLOW}'menu'${NC} untuk memulai."
