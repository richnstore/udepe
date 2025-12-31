#!/bin/bash

# --- PRE-INSTALLATION & DIRECTORY CHECK ---
apt-get update -qq && apt-get install iptables-persistent jq vnstat curl wget sudo -y -qq
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

# Load Data
[ -f "$TG_CONF" ] && source "$TG_CONF"
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"

# Warna Harmony V17
C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# --- FUNGSI AUTO-DELETE EXPIRED (CRON) ---
sync_and_clean() {
    local today=\$(date +%s)
    local changed=false
    # Sync meta data with config.json
    local all_pass=\$(jq -r '.auth.config[]' "\$CONFIG_FILE" 2>/dev/null)
    for pass in \$all_pass; do
        [ -z "\$pass" ] || [ "\$pass" == "null" ] && continue
        local exists=\$(jq -r --arg u "\$pass" '.accounts[] | select(.user==\$u) | .user' "\$META_FILE" 2>/dev/null)
        if [ -z "\$exists" ]; then
            jq --arg u "\$pass" --arg e "2099-12-31" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"
        fi
    done
    # Remove Expired
    while read -r acc; do
        [ -z "\$acc" ] && continue
        local user=\$(echo "\$acc" | jq -r '.user')
        local exp=\$(echo "\$acc" | jq -r '.expired')
        local exp_ts=\$(date -d "\$exp" +%s 2>/dev/null)
        if [ \$? -eq 0 ] && [ "\$today" -ge "\$exp_ts" ]; then
            jq --arg u "\$user" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"
            jq --arg u "\$user" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "\$META_FILE" 2>/dev/null)
    [ "\$changed" = true ] && systemctl restart "\$SERVICE_NAME" >/dev/null 2>&1
}

# --- FUNGSI RESTORE (FIXED & BOXED) ---
restore_telegram() {
    clear
    echo -e "\${C}┏━━━━━━━━━━━━━\${Y} RESTORE VIA TELEGRAM \${C}━━━━━━━━━━━━┓\${NC}"
    if [ -z "\$TG_BOT_TOKEN" ]; then
        printf " \${C}┃\${NC} \${R}%-40s\${NC} \${C}┃\${NC}\n" "Error: Setup Telegram Dulu (08)!"
        echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
        sleep 2; return
    fi
    printf " \${C}┃\${NC} \${Y}%-40s\${NC} \${C}┃\${NC}\n" "Mencari file di Telegram..."
    local UPD=\$(curl -s "https://api.telegram.org/bot\$TG_BOT_TOKEN/getUpdates?limit=100")
    local FID=\$(echo "\$UPD" | jq -r '.result[] | select(.message.document.file_name=="config.json") | .message.document.file_id' | tail -n 1)
    if [ -z "\$FID" ] || [ "\$FID" == "null" ]; then
        printf " \${C}┃\${NC} \${R}%-40s\${NC} \${C}┃\${NC}\n" "File 'config.json' Tidak Ditemukan!"
        echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
        read -rp " Tekan Enter..." ; return
    fi
    local FPATH=\$(curl -s "https://api.telegram.org/bot\$TG_BOT_TOKEN/getFile?file_id=\$FID" | jq -r '.result.file_path')
    wget -q -O "\$CONFIG_FILE" "https://api.telegram.org/file/bot\$TG_BOT_TOKEN/\$FPATH"
    systemctl restart "\$SERVICE_NAME" 2>/dev/null
    printf " \${C}┃\${NC} \${G}%-40s\${NC} \${C}┃\${NC}\n" "Restore Berhasil!"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
    sleep 2
}

# --- FUNGSI HAPUS (BOXED) ---
delete_account() {
    clear
    echo -e "\${C}┏━━━━━━━━━━━━━━\${Y} HAPUS AKUN ZIVPN \${C}━━━━━━━━━━━━━━┓\${NC}"
    mapfile -t LIST < <(jq -r '.auth.config[]' "\$CONFIG_FILE")
    if [ \${#LIST[@]} -eq 0 ]; then
        printf " \${C}┃\${NC} \${R}%-40s\${NC} \${C}┃\${NC}\n" "Tidak ada akun terdaftar."
        echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
        sleep 2; return
    fi
    index=1
    for u in "\${LIST[@]}"; do
        printf " \${C}┃\${NC}  \${Y}[%02d]\${NC} %-34s \${C}┃\${NC}\n" "\$index" "\$u"
        ((index++))
    done
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
    echo -ne "  \${B}Pilih Nomor\${NC}: " && read idx
    if [[ ! "\$idx" =~ ^[0-9]+\$ ]] || [ "\$idx" -lt 1 ] || [ "\$idx" -ge "\$index" ]; then
        echo -e "  \${R}Invalid!\${NC}"; sleep 1; return
    fi
    target=\${LIST[\$((idx-1))]}
    jq --arg u "\$target" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"
    jq --arg u "\$target" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"
    systemctl restart "\$SERVICE_NAME" 2>/dev/null
    echo -e "  \${G}Dihapus!\${NC}"; sleep 2
}

# --- FUNGSI STATUS (BOXED) ---
show_system() {
    clear
    local U=\$(uptime -p | sed 's/up //'); local R_U=\$(free -h | awk '/Mem:/ {print \$3}'); local R_T=\$(free -h | awk '/Mem:/ {print \$2}')
    local D=\$(df -h / | awk '/\// {print \$3}' | tail -n 1); local C_L=\$(top -bn1 | grep "Cpu(s)" | awk '{print \$2 + \$4}')"%"
    echo -e "\${C}┏━━━━━━━━━━━━━\${Y} SYSTEM INFORMATION \${C}━━━━━━━━━━━━━┓\${NC}"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "Uptime" "\$U"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "CPU Load" "\$C_L"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "Memory" "\$R_U / \$R_T"
    printf " \${C}┃\${NC} %-15s : \${G}%-23s\${NC} \${C}┃\${NC}\n" "Disk Used" "\$D"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
    read -rp " Enter..."
}

# --- HEADER ---
draw_header() {
    clear
    local IP=\$(curl -s ifconfig.me); local IF=\$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    local BW=\$(vnstat -i "\$IF" --json 2>/dev/null); local T_D=\$(date +%-d); local T_M=\$(date +%-m); local T_Y=\$(date +%Y)
    local RX=\$(echo "\$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .rx // 0" 2>/dev/null)
    local TX=\$(echo "\$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .tx // 0" 2>/dev/null)
    local BD=\$(awk -v b="\$RX" 'BEGIN {printf "%.2f MB", b/1024/1024}'); local BU=\$(awk -v b="\$TX" 'BEGIN {printf "%.2f MB", b/1024/1024}')
    echo -e "\${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\${NC}"
    echo -e "\${C}┃\${NC}      \${Y}ZIVPN HARMONY PANEL V24\${NC}       \${C}┃\${NC} \${B}IP:\${NC} \${G}\$IP\${NC}"
    echo -e "\${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫\${NC}"
    echo -e "\${C}┃\${NC} \${B}Traffic:\${NC} \${G}↓\$BD\${NC} | \${R}↑\$BU\${NC}"
    echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"
}

# --- MAIN LOOP ---
if [ "\$1" == "cron" ]; then sync_and_clean; exit 0; fi
while true; do
    sync_and_clean; draw_header
    echo -e "  \${C}[\${Y}01\${C}]\${NC} Tambah Akun           \${C}[\${Y}06\${C}]\${NC} Backup Telegram"
    echo -e "  \${C}[\${Y}02\${C}]\${NC} Hapus Akun            \${C}[\${Y}07\${C}]\${NC} Restore Telegram"
    echo -e "  \${C}[\${Y}03\${C}]\${NC} Lihat Daftar Akun     \${C}[\${Y}08\${C}]\${NC} Settings Telegram"
    echo -e "  \${C}[\${Y}04\${C}]\${NC} Restart Service       \${C}[\${Y}09\${C}]\${NC} Update Script"
    echo -e "  \${C}[\${Y}05\${C}]\${NC} Status System         \${C}[\${Y}00\${C}]\${NC} Keluar"
    echo -e "\${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"
    echo -ne "  \${B}Pilih\${NC}: " && read ch
    case \$ch in
        1|01) read -rp "  User: " n; read -rp "  Hari: " d; exp=\$(date -d "+\$d days" +%Y-%m-%d); jq --arg u "\$n" '.auth.config += [\$u]' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$n" --arg e "\$exp" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo -e "\${G}Sukses!\${NC}"; sleep 1 ;;
        2|02) delete_account ;;
        3|03) clear; printf "\${Y}%-18s %-12s\${NC}\n" "USER" "EXPIRED"; jq -r '.accounts[] | "\(.user) \(.expired)"' "\$META_FILE"; read -rp "Enter..." ;;
        4|04) systemctl restart "\$SERVICE_NAME" 2>/dev/null; echo "Restarted."; sleep 1 ;;
        5|05) show_system ;;
        6|06) if [ -z "\$TG_BOT_TOKEN" ]; then echo "Setup Dulu!"; sleep 1; else cp "\$CONFIG_FILE" /tmp/c.json; curl -s -F chat_id="\$TG_CHAT_ID" -F document=@/tmp/c.json https://api.telegram.org/bot\$TG_BOT_TOKEN/sendDocument > /dev/null; echo "Backup Terkirim!"; sleep 1; fi ;;
        7|07) restore_telegram ;;
        8|08) clear; echo -e "\${C}┏━━━━━━━━━━━━━\${Y} SETTINGS TELEGRAM \${C}━━━━━━━━━━━━┓\${NC}"; echo -ne "  Token: " && read NT; echo -ne "  ID: " && read NI; echo "TG_BOT_TOKEN=\"\$NT\"" > "\$TG_CONF"; echo "TG_CHAT_ID=\"\$NI\"" >> "\$TG_CONF"; echo -e " \${G}Saved!\${NC}"; echo -e "\${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\${NC}"; sleep 1 ;;
        9|09) wget -q -O /tmp/z.sh "https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh" && mv /tmp/z.sh "\$MANAGER_SCRIPT" && chmod +x "\$MANAGER_SCRIPT"; exit 0 ;;
        0|00) exit 0 ;;
    esac
done
EOF

# --- FINALISASI & CRONTAB SETUP ---
chmod +x "$MANAGER_SCRIPT"
echo "sudo bash $MANAGER_SCRIPT" > "$SHORTCUT" && chmod +x "$SHORTCUT"
(crontab -l 2>/dev/null | grep -v "$MANAGER_SCRIPT") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * $MANAGER_SCRIPT cron") | crontab -

clear
echo -e "${GREEN}✅ ZIVPN MANAGER V24 FINAL MASTERPIECE!${NC}"
echo -e "Ketik ${YELLOW}'menu'${NC} untuk menjalankan."
