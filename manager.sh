#!/bin/bash

# --- PRE-INSTALLATION ---
apt-get update -qq && apt-get install iptables-persistent jq vnstat curl wget sudo lsb-release -y -qq

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

# --- MENULIS SCRIPT MANAGER UTAMA ---
cat <<'EOF' > "/usr/local/bin/zivpn-manager.sh"
#!/bin/bash

# Environment for Cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Load Data Telegram
TG_CONF="/etc/zivpn/telegram.conf"
[ -f "$TG_CONF" ] && source "$TG_CONF"

# Path Konfigurasi
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"

# Warna Harmony V17
C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# --- FUNGSI AUTO-DELETE (STABLE CRON) ---
sync_and_clean() {
    local today=$(date +%s)
    local changed=false
    
    # Validasi JSON sebelum proses
    if ! jq empty "$CONFIG_FILE" 2>/dev/null || ! jq empty "$META_FILE" 2>/dev/null; then
        return
    fi

    # Sinkronisasi akun manual ke metadata
    local all_pass=$(jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null)
    for pass in $all_pass; do
        [ -z "$pass" ] || [ "$pass" == "null" ] && continue
        local exists=$(jq -r --arg u "$pass" '.accounts[] | select(.user==$u) | .user' "$META_FILE" 2>/dev/null)
        if [ -z "$exists" ]; then
            jq --arg u "$pass" --arg e "2099-12-31" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
        fi
    done

    # Cek Expired
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user')
        local exp=$(echo "$acc" | jq -r '.expired')
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            jq --arg u "$user" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)

    if [ "$changed" = true ]; then
        /usr/bin/systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
    fi
}

# --- UI COMPONENTS ---
draw_header() {
    clear
    local IP=$(curl -s ifconfig.me)
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    local BW=$(vnstat -i "$IF" --json 2>/dev/null)
    local T_D=$(date +%-d); local T_M=$(date +%-m); local T_Y=$(date +%Y)
    local RX=$(echo "$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .rx // 0" 2>/dev/null)
    local TX=$(echo "$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .tx // 0" 2>/dev/null)
    local BD=$(awk -v b="$RX" 'BEGIN {printf "%.2f MB", b/1024/1024}')
    local BU=$(awk -v b="$TX" 'BEGIN {printf "%.2f MB", b/1024/1024}')

    echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${C}┃${NC}      ${Y}ZIVPN HARMONY PANEL V30${NC}       ${C}┃${NC} ${B}IP:${NC} ${G}$IP${NC}"
    echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    echo -e "${C}┃${NC} ${B}Traffic:${NC} ${G}↓$BD${NC} | ${R}↑$BU${NC}"
    echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
}

# --- MAIN LOOP ---
case "$1" in
    cron) sync_and_clean; exit 0 ;;
    *)
    while true; do
        sync_and_clean; draw_header
        echo -e "  ${C}[${Y}01${C}]${NC} Tambah Akun           ${C}[${Y}06${C}]${NC} Backup Telegram"
        echo -e "  ${C}[${Y}02${C}]${NC} Hapus Akun            ${C}[${Y}07${C}]${NC} Restore Telegram"
        echo -e "  ${C}[${Y}03${C}]${NC} Lihat Daftar Akun     ${C}[${Y}08${C}]${NC} Settings Telegram"
        echo -e "  ${C}[${Y}04${C}]${NC} Restart Service       ${C}[${Y}09${C}]${NC} Update Script"
        echo -e "  ${C}[${Y}05${C}]${NC} Status System         ${C}[${Y}00${C}]${NC} Keluar"
        echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -ne "  ${B}Pilih Menu${NC}: " && read choice
        case $choice in
            1|01) 
                echo -e "\n${C}┏━━━━━━━━━━━━━━━${Y} TAMBAH AKUN ${C}━━━━━━━━━━━━━━━┓${NC}"
                echo -ne "  User: " && read n; echo -ne "  Hari: " && read d
                exp=$(date -d "+$d days" +%Y-%m-%d)
                jq --arg u "$n" '.auth.config += [$u]' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
                jq --arg u "$n" --arg e "$exp" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
                systemctl restart "$SERVICE_NAME"; echo -e "  ${G}Sukses! Exp: $exp${NC}"; sleep 2 ;;
            2|02) 
                clear; echo -e "${C}┏━━━━━━━━━━━━━━${Y} HAPUS AKUN ${C}━━━━━━━━━━━━━━┓${NC}"
                mapfile -t LIST < <(jq -r '.auth.config[]' "$CONFIG_FILE")
                i=1; for u in "${LIST[@]}"; do printf " ${C}┃${NC}  ${Y}[%02d]${NC} %-34s ${C}┃${NC}\n" "$i" "$u"; ((i++)); done
                echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
                echo -ne "  Nomor: " && read idx; target=${LIST[$((idx-1))]}
                if [ ! -z "$target" ]; then
                    jq --arg u "$target" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
                    jq --arg u "$target" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
                    systemctl restart "$SERVICE_NAME"; echo -e "  ${R}Dihapus!${NC}"; sleep 1
                fi ;;
            3|03) 
                clear; echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
                printf " ${C}┃${NC}  ${Y}NO  %-18s %-12s${NC}      ${C}┃${NC}\n" "USER" "EXPIRED"
                echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
                i=1; while read -r u e; do printf " ${C}┃${NC}  ${G}%02d${NC}  %-18s %-12s      ${C}┃${NC}\n" "$i" "$u" "$e"; ((i++)); done < <(jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE")
                echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"; read -rp " Enter..." ;;
            5|05) 
                clear; UP=$(uptime -p); RU=$(free -h | awk '/Mem:/ {print $3}'); RT=$(free -h | awk '/Mem:/ {print $2}')
                echo -e "${C}┏━━━━━━━━━━━━━${Y} SYSTEM INFORMATION ${C}━━━━━━━━━━━━━┓${NC}"
                printf " ${C}┃${NC} %-15s : ${G}%-23s${NC} ${C}┃${NC}\n" "Uptime" "$UP"
                printf " ${C}┃${NC} %-15s : ${G}%-23s${NC} ${C}┃${NC}\n" "RAM" "$RU / $RT"
                printf " ${C}┃${NC} %-15s : ${G}%-23s${NC} ${C}┃${NC}\n" "OS" "$(lsb_release -ds 2>/dev/null || echo 'Linux')"
                echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"; read -rp " Enter..." ;;
            6|06) 
                if [ -z "$TG_BOT_TOKEN" ]; then echo "Setup Telegram Dulu!"; sleep 1; else
                cp "$CONFIG_FILE" /tmp/config.json
                curl -s -F chat_id="$TG_CHAT_ID" -F document=@/tmp/config.json "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" > /dev/null
                echo "Backup Sent!"; rm -f /tmp/config.json; sleep 1; fi ;;
            7|07) 
                clear; echo -e "${C}┏━━━━━━━━━━━━━${Y} RESTORE VIA TELEGRAM ${C}━━━━━━━━━━━━┓${NC}"
                if [ -z "$TG_BOT_TOKEN" ]; then echo "Setup Dulu!"; sleep 1; else
                UPD=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?limit=100")
                FID=$(echo "$UPD" | jq -r '.result[] | select(.message.document.file_name=="config.json") | .message.document.file_id' | tail -n 1)
                if [ ! -z "$FID" ] && [ "$FID" != "null" ]; then
                    FPATH=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getFile?file_id=$FID" | jq -r '.result.file_path')
                    wget -q -O "$CONFIG_FILE" "https://api.telegram.org/file/bot$TG_BOT_TOKEN/$FPATH"
                    systemctl restart "$SERVICE_NAME"; echo -e "  ${G}Restore Sukses!${NC}"
                else echo -e "  ${R}File config.json tidak ditemukan!${NC}"; fi; fi
                echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"; sleep 2 ;;
            8|08) 
                clear; echo -e "${C}┏━━━━━━━━━━━━━${Y} SETTINGS TELEGRAM ${C}━━━━━━━━━━━━┓${NC}"
                echo -ne "  Token: " && read NT; echo -ne "  Chat ID: " && read NI
                echo "TG_BOT_TOKEN=\"$NT\"" > "$TG_CONF"; echo "TG_CHAT_ID=\"$NI\"" >> "$TG_CONF"
                echo -e "  ${G}Tersimpan!${NC}"; sleep 1 ;;
            9|09) wget -q -O /tmp/z.sh "https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh" && mv /tmp/z.sh "$MANAGER_PATH" && chmod +x "$MANAGER_PATH"; exit 0 ;;
            0|00) exit 0 ;;
        esac
    done ;;
esac
EOF

# --- CRONTAB & FINAL SETUP ---
chmod +x "/usr/local/bin/zivpn-manager.sh"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT" && chmod +x "$SHORTCUT"
(crontab -l 2>/dev/null | grep -v "zivpn-manager.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/zivpn-manager.sh cron") | crontab -

clear
echo -e "${G}✅ V30 PLATINUM INSTALLED!${NC}"
echo -e "Fitur Auto-Delete, Restore-Fix, dan UI-Perfection sudah aktif."
