#!/bin/bash

# --- 1. PRE-INSTALLATION & ESSENTIALS ---
apt-get update -qq && apt-get install iptables iptables-persistent jq vnstat curl wget sudo lsb-release zip unzip -y -qq

# HANYA IP FORWARDING (WAJIB UTK VPN) - Tweak Turbo dipindah ke Menu
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/00-zivpn-core.conf
sysctl -p /etc/sysctl.d/00-zivpn-core.conf >/dev/null 2>&1

# IPTables Persistence (NAT Masquerade)
apply_iptables_immortal() {
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    iptables -F && iptables -t nat -F
    iptables -t nat -A POSTROUTING -o "$IF" -j MASQUERADE
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -j ACCEPT
    netfilter-persistent save >/dev/null 2>&1
}
apply_iptables_immortal

# Path Setup
CONFIG_DIR="/etc/zivpn"; CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"; TG_CONF="/etc/zivpn/telegram.conf"
TWEAK_FILE="/etc/sysctl.d/99-zivpn-turbo.conf" # File Config Fitur Turbo
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"; SHORTCUT="/usr/local/bin/menu"

mkdir -p "$CONFIG_DIR"
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"

# --- 2. SCRIPT MANAGER UTAMA ---
cat <<'EOF' > "/usr/local/bin/zivpn-manager.sh"
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"
TG_CONF="/etc/zivpn/telegram.conf"; [ -f "$TG_CONF" ] && source "$TG_CONF"
CONFIG_FILE="/etc/zivpn/config.json"; META_FILE="/etc/zivpn/accounts_meta.json"
TWEAK_FILE="/etc/sysctl.d/99-zivpn-turbo.conf"
SERVICE_NAME="zivpn.service"

C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# SYNC & WATCHDOG
sync_all() {
    # Pastikan IP Forwarding Selalu Aktif (Core Requirement)
    [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ] && sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    
    # IPTables Watchdog
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    iptables -t nat -C POSTROUTING -o "$IF" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$IF" -j MASQUERADE
    
    # Auto-Delete Expired
    local today=$(date +%s); local changed=false
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user'); local exp=$(echo "$acc" | jq -r '.expired')
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)

    # Sync Meta -> Config
    local USERS_FROM_META=$(jq -c '[.accounts[].user]' "$META_FILE")
    jq --argjson u "$USERS_FROM_META" '.auth.config = $u' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
    
    [ "$changed" = true ] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
}

# FUNGSI MANAJEMEN TWEAK (ON/OFF)
manage_tweaks() {
    if [ "$1" == "on" ]; then
        cat <<EOT > "$TWEAK_FILE"
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.netdev_max_backlog = 2000
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOT
        sysctl -p "$TWEAK_FILE" >/dev/null 2>&1
        echo -e "  ${G}TURBO TWEAKS: ENABLED!${NC}"
    else
        rm -f "$TWEAK_FILE"
        # Revert to Defaults (Safe Values)
        sysctl -w net.core.rmem_max=212992 >/dev/null 2>&1
        sysctl -w net.core.wmem_max=212992 >/dev/null 2>&1
        sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
        echo -e "  ${R}TURBO TWEAKS: DISABLED (Default).${NC}"
    fi
}

draw_header() {
    clear
    local IP=$(curl -s ifconfig.me || echo "No IP"); local UP=$(uptime -p | sed 's/up //')
    local RAM_U=$(free -h | awk '/Mem:/ {print $3}'); local CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')"%"
    
    # Cek Status Tweak
    if [ -f "$TWEAK_FILE" ]; then 
        STATUS_TWEAK="${G}[ON] Active${NC}"
    else 
        STATUS_TWEAK="${R}[OFF] Default${NC}"
    fi

    echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${C}┃${NC}      ${Y}ZIVPN FEATURE CONTROL V48${NC}       ${C}┃${NC}"
    echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "IP Address" "$IP"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Uptime" "$UP"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "CPU | RAM" "$CPU | $RAM_U"
    printf " ${C}┃${NC} %-12s : %-37s ${C}┃${NC}\n" "Turbo Tweak" "$STATUS_TWEAK"
    echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
}

while true; do
    sync_all; draw_header
    echo -e "  ${C}[${Y}01${C}]${NC} Tambah Akun           ${C}[${Y}06${C}]${NC} Restore ZIP (Telegram)"
    echo -e "  ${C}[${Y}02${C}]${NC} Hapus Akun            ${C}[${Y}07${C}]${NC} Telegram Settings"
    echo -e "  ${C}[${Y}03${C}]${NC} Daftar Akun           ${C}[${Y}08${C}]${NC} Turbo Tweaks (ON/OFF)"
    echo -e "  ${C}[${Y}04${C}]${NC} Restart Service       ${C}[${Y}09${C}]${NC} Update Script"
    echo -e "  ${C}[${Y}05${C}]${NC} Backup ZIP (Telegram) ${C}[${Y}00${C}]${NC} Keluar"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "  ${B}Pilih Menu${NC}: " && read choice
    case $choice in
        1|01) 
            echo -ne "  User: " && read n
            if [ -z "$n" ]; then echo -e "  ${R}Error: Username kosong!${NC}"; sleep 1; continue; fi
            echo -ne "  Hari: " && read d
            if [ -z "$d" ] || ! [[ "$d" =~ ^[0-9]+$ ]]; then echo -e "  ${R}Error: Durasi salah!${NC}"; sleep 1; continue; fi
            
            exp=$(date -d "+$d days" +%Y-%m-%d)
            jq --arg u "$n" --arg e "$exp" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            sync_all; systemctl restart "$SERVICE_NAME"
            echo -e "  ${G}Sukses: User $n ditambahkan!${NC}"; sleep 2 ;;
        2|02) 
            mapfile -t LIST < <(jq -r '.accounts[].user' "$META_FILE")
            [ ${#LIST[@]} -eq 0 ] && { echo -e "  ${R}Tidak ada akun!${NC}"; sleep 2; continue; }
            i=1; for u in "${LIST[@]}"; do
                exp=$(jq -r --arg u "$u" '.accounts[] | select(.user==$u) | .expired' "$META_FILE")
                echo -e "  $i. $u ($exp)"; ((i++))
            done
            echo -ne "  Pilih No (Enter = Batal): " && read idx
            if [ -z "$idx" ]; then echo -e "  ${Y}Dibatalkan.${NC}"; sleep 1; continue; fi
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#LIST[@]}" ]; then echo -e "  ${R}Input Salah!${NC}"; sleep 1; continue; fi
            
            target=${LIST[$((idx-1))]}
            jq --arg u "$target" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            sync_all; systemctl restart "$SERVICE_NAME"
            echo -e "  ${G}Sukses: Akun $target dihapus!${NC}"; sleep 2 ;;
        3|03) 
            echo -e "\n  ${Y}DAFTAR AKUN ZIVPN:${NC}"
            printf "  %-15s %-12s\n" "USER" "EXPIRED"
            echo "  ----------------------------"
            jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE" | while read -r u e; do printf "  %-15s %-12s\n" "$u" "$e"; done
            echo "  ----------------------------"
            read -rp "  Tekan Enter..." ;;
        4|04) 
            echo -ne "  Restarting service..."; systemctl restart "$SERVICE_NAME"
            echo -e " ${G}DONE!${NC}"; sleep 1 ;;
        5|05) 
            if [ -z "$TG_BOT_TOKEN" ]; then echo -e "  ${R}Set Telegram Dulu (Menu 07)!${NC}"; sleep 2; continue; fi
            echo -ne "  Membuat ZIP..."; ZIP="/tmp/zivpn_backup.zip"
            zip -j "$ZIP" "$CONFIG_FILE" "$META_FILE" >/dev/null
            RES=$(curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$ZIP" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument")
            [[ "$RES" == *"ok\":true"* ]] && echo -e " ${G}Terkirim!${NC}" || echo -e " ${R}Gagal!${NC}"
            rm -f "$ZIP"; sleep 2 ;;
        6|06) 
            if [ -z "$TG_BOT_TOKEN" ]; then echo -e "  ${R}Set Telegram Dulu (Menu 07)!${NC}"; sleep 2; continue; fi
            echo -e "  ${Y}Mencari backup terbaru...${NC}"
            JSON_DATA=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?limit=100")
            FID=$(echo "$JSON_DATA" | jq -r '.result | reverse | .[] | select(.message.document != null) | .message.document.file_id' | head -n 1)
            if [ -z "$FID" ] || [ "$FID" == "null" ]; then echo -e "  ${R}File ZIP tidak ditemukan!${NC}"; else
                FPATH=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getFile?file_id=$FID" | jq -r '.result.file_path')
                wget -q -O /tmp/restore.zip "https://api.telegram.org/file/bot$TG_BOT_TOKEN/$FPATH"
                if [ -s /tmp/restore.zip ]; then
                    systemctl stop "$SERVICE_NAME"
                    unzip -o /tmp/restore.zip -d /etc/zivpn/ >/dev/null
                    sync_all; systemctl start "$SERVICE_NAME"
                    echo -e "  ${G}Restore Sukses!${NC}"; rm -f /tmp/restore.zip
                else echo -e "  ${R}Download Gagal!${NC}"; fi
            fi; sleep 2 ;;
        7|07)
            while true; do
                clear; echo -e "${C}=== TELEGRAM SETTINGS ===${NC}"
                echo -e " 1. Lihat Config\n 2. Ubah Token & ID\n 0. Kembali"
                echo -ne " Pilih: " && read topt
                case $topt in
                    1) echo -e "\n Token: ${TG_BOT_TOKEN}\n ID: ${TG_CHAT_ID}"; read -rp " Enter..." ;;
                    2) 
                        echo -ne " Token Baru: " && read NT; [ -z "$NT" ] && continue
                        echo -ne " ID Baru   : " && read NI; [ -z "$NI" ] && continue
                        echo "TG_BOT_TOKEN=\"$NT\"" > "$TG_CONF"; echo "TG_CHAT_ID=\"$NI\"" >> "$TG_CONF"
                        echo -e " ${G}Disimpan!${NC}"; sleep 1; break ;;
                    0) break ;;
                esac
            done ;;
        8|08)
            while true; do
                clear
                echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
                echo -e "${C}┃${NC}           ${Y}TURBO TWEAKS SETTING${NC}           ${C}┃${NC}"
                echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
                echo -e "  ${C}[${Y}1${C}]${NC} Enable Turbo (BBR, UDP Buffer, fq_codel)"
                echo -e "  ${C}[${Y}2${C}]${NC} Disable Turbo (Revert to Default)"
                echo -e "  ${C}[${Y}0${C}]${NC} Kembali"
                echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
                echo -ne "  ${B}Pilih${NC}: " && read tw_opt
                case $tw_opt in
                    1) manage_tweaks "on"; sleep 2; break ;;
                    2) manage_tweaks "off"; sleep 2; break ;;
                    0) break ;;
                    *) echo -e "  ${R}Invalid!${NC}"; sleep 1 ;;
                esac
            done ;;
        9|09) 
            echo -e "  ${Y}Updating...${NC}"
            wget -q -O /tmp/z.sh "https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh"
            if [ -f /tmp/z.sh ]; then mv /tmp/z.sh "$MANAGER_PATH" && chmod +x "$MANAGER_PATH"; echo -e "  ${G}Updated!${NC}"; sleep 2; exit 0; 
            else echo -e "  ${R}Failed!${NC}"; sleep 2; fi ;;
        0|00) exit 0 ;;
        *) echo -e "  ${R}Menu salah!${NC}"; sleep 1 ;;
    esac
done
EOF

# --- 3. FINAL SETUP ---
chmod +x "/usr/local/bin/zivpn-manager.sh"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT" && chmod +x "$SHORTCUT"
(crontab -l 2>/dev/null | grep -v "zivpn-manager.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/zivpn-manager.sh cron") | crontab -

clear
echo -e "${G}✅ V48 FEATURE CONTROL INSTALLED!${NC}"
echo -e "Menu 08 sekarang bisa digunakan untuk ON/OFF fitur Turbo Tweak."
