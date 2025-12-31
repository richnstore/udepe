#!/bin/bash

# --- 1. PRE-INSTALLATION & DEPENDENCIES ---
# Install paket wajib
apt-get update -qq && apt-get install jq vnstat curl wget sudo lsb-release zip unzip net-tools cron iptables-persistent netfilter-persistent -y -qq

# --- 2. FIREWALL PERSISTENCE (CRITICAL FIX) ---
# Simpan rule yang ada saat ini (dari script lain)
netfilter-persistent save >/dev/null 2>&1
# Wajib: Aktifkan service agar rule dimuat saat reboot
systemctl enable netfilter-persistent >/dev/null 2>&1
systemctl start netfilter-persistent >/dev/null 2>&1

# --- 3. CONFIG SETUP ---
CONFIG_DIR="/etc/zivpn"
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
TG_CONF="/etc/zivpn/telegram.conf"
TWEAK_FILE="/etc/sysctl.d/99-zivpn-turbo.conf"
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/menu"

mkdir -p "$CONFIG_DIR"
# Buat file default jika hilang
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":"0.0.0.0:5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"

# --- 4. SCRIPT MANAGER UTAMA ---
cat <<'EOF' > "/usr/local/bin/zivpn-manager.sh"
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"
TG_CONF="/etc/zivpn/telegram.conf"; [ -f "$TG_CONF" ] && source "$TG_CONF"
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
TWEAK_FILE="/etc/sysctl.d/99-zivpn-turbo.conf"
SERVICE_NAME="zivpn.service"

# Warna UI
C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# Helper: Tunggu Enter
wait_enter() {
    echo -e ""
    read -rp "  Tekan Enter untuk kembali..."
}

# Fungsi Notifikasi Telegram
send_notif() {
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d parse_mode="html" -d text="$1" >/dev/null 2>&1 &
    fi
}

# --- SMART AUTO-SYNC (BACKGROUND PROCESS) ---
sync_all() {
    {
        # 1. Force Listen 0.0.0.0 (Agar bisa connect)
        local CUR_L=$(jq -r '.listen // "0.0.0.0:5667"' "$CONFIG_FILE")
        if [[ "$CUR_L" != "0.0.0.0:"* ]]; then
            local PORT=$(echo "$CUR_L" | grep -oE '[0-9]+$'); [ -z "$PORT" ] && PORT="5667"
            jq --arg p "0.0.0.0:$PORT" '.listen = $p' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
            local FORCE_RESTART=true
        fi

        # 2. Hapus User Expired (Dengan validasi tanggal)
        local today=$(date +%s); local meta_changed=false
        while read -r acc; do
            [ -z "$acc" ] && continue
            local user=$(echo "$acc" | jq -r '.user'); local exp=$(echo "$acc" | jq -r '.expired')
            
            # Validasi tanggal agar tidak error
            local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
            if [ -n "$exp_ts" ] && [ "$today" -ge "$exp_ts" ]; then
                jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
                send_notif "🚫 <b>EXPIRED</b>: <code>$user</code>"
                meta_changed=true
            fi
        done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)

        # 3. Sync Meta -> Config (Fix Auth Wrong)
        local USERS_META=$(jq -c '.accounts[].user' "$META_FILE" | sort | jq -s '.')
        local USERS_CONF=$(jq -c '.auth.config' "$CONFIG_FILE" | jq -r '.[]' | sort | jq -s '.')

        # Hanya restart jika ada perubahan data
        if [ "$USERS_META" != "$USERS_CONF" ] || [ "$meta_changed" = true ] || [ "$FORCE_RESTART" = true ]; then
            jq --argjson u "$USERS_META" '.auth.config = $u' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
            systemctl restart "$SERVICE_NAME"
        fi
    } >/dev/null 2>&1
}

# Handler untuk Cronjob
if [ "$1" == "cron" ]; then sync_all; exit 0; fi

# Fungsi Turbo Tweak (Kernel Only)
manage_tweaks() {
    if [ "$1" == "on" ]; then
        cat <<EOT > "$TWEAK_FILE"
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 2000
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOT
        sysctl -p "$TWEAK_FILE" >/dev/null 2>&1; echo -e "  ${G}TURBO: ON${NC}"
    else
        rm -f "$TWEAK_FILE"
        sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1
        echo -e "  ${R}TURBO: OFF${NC}"
    fi
}

# Tampilan Menu Utama
draw_header() {
    clear
    local IP=$(curl -s ifconfig.me || echo "No IP"); local UP=$(uptime -p | sed 's/up //')
    
    # Cek Port Service
    local CUR_PORT=$(jq -r '.listen' "$CONFIG_FILE" 2>/dev/null | cut -d':' -f2)
    local BIND_STAT=$(netstat -tulpn | grep ":$CUR_PORT " | grep -v ":::" | awk '{print $4}')
    [[ ! -z "$BIND_STAT" ]] && PORT_STATUS="${G}Running ($CUR_PORT)${NC}" || PORT_STATUS="${R}Service Down${NC}"
    
    # Cek Bandwidth (Error Suppressed)
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    # Init database vnstat jika corrupt/hilang
    if [ ! -f "/var/lib/vnstat/$IF" ]; then vnstat --create -i "$IF" >/dev/null 2>&1; fi
    
    local BW_JSON=$(vnstat -i "$IF" --json 2>/dev/null)
    local RX=0; local TX=0
    if [ -n "$BW_JSON" ]; then
        local T_D=$(date +%-d); local T_M=$(date +%-m); local T_Y=$(date +%Y)
        RX=$(echo "$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .rx // 0" 2>/dev/null)
        TX=$(echo "$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .tx // 0" 2>/dev/null)
    fi
    # Pastikan variabel tidak kosong
    [[ -z "$RX" || "$RX" == "null" ]] && RX=0
    [[ -z "$TX" || "$TX" == "null" ]] && TX=0
    
    local BW_STR="↓$(awk -v b="$RX" 'BEGIN {printf "%.2f", b/1024/1024}') MB | ↑$(awk -v b="$TX" 'BEGIN {printf "%.2f", b/1024/1024}') MB"
    if [ -f "$TWEAK_FILE" ]; then TWEAK_STAT="${G}ON${NC}"; else TWEAK_STAT="${R}OFF${NC}"; fi

    echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${C}┃${NC}       ${Y}ZIVPN MANAGER V73 (PERFECT)${NC}        ${C}┃${NC}"
    echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    printf "${C}┃${NC} %-12s : %-26s ${C}┃${NC}\n" "IP Address" "$IP"
    printf "${C}┃${NC} %-12s : %-37s ${C}┃${NC}\n" "Service Port" "$PORT_STATUS"
    printf "${C}┃${NC} %-12s : %-37s ${C}┃${NC}\n" "Turbo Tweak" "$TWEAK_STAT"
    printf "${C}┃${NC} %-12s : ${Y}%-26s${NC} ${C}┃${NC}\n" "Daily BW" "$BW_STR"
    echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
}

while true; do
    sync_all; draw_header
    echo -e "  ${C}[${Y}01${C}]${NC} Tambah Akun           ${C}[${Y}05${C}]${NC} Backup ZIP"
    echo -e "  ${C}[${Y}02${C}]${NC} Hapus Akun            ${C}[${Y}06${C}]${NC} Restore ZIP"
    echo -e "  ${C}[${Y}03${C}]${NC} Daftar Akun           ${C}[${Y}07${C}]${NC} Telegram Settings"
    echo -e "  ${C}[${Y}04${C}]${NC} Restart Service       ${C}[${Y}08${C}]${NC} Turbo Tweaks"
    echo -e "  ${C}[${Y}09${C}]${NC} Update Script         ${C}[${Y}00${C}]${NC} Keluar"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "  ${B}Pilih Menu${NC}: " && read -r choice
    case $choice in
        1|01) 
            echo -ne "  User: " && read -r n
            if [ -z "$n" ]; then echo -e "  ${R}Batal: User kosong!${NC}"; wait_enter; continue; fi
            echo -ne "  Hari: " && read -r d
            if [[ ! "$d" =~ ^[0-9]+$ ]]; then echo -e "  ${R}Batal: Hari harus angka!${NC}"; wait_enter; continue; fi
            exp=$(date -d "+$d days" +%Y-%m-%d)
            jq --arg u "$n" --arg e "$exp" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            sync_all; send_notif "✅ <b>NEW USER</b>%0AUser: <code>$n</code>%0AExp: $exp"
            echo -e "  ${G}Sukses: User $n Aktif.${NC}"; wait_enter ;;
        2|02) 
            mapfile -t LIST < <(jq -r '.accounts[].user' "$META_FILE")
            if [ ${#LIST[@]} -eq 0 ]; then echo -e "  ${R}Tidak ada user.${NC}"; wait_enter; continue; fi
            echo -e "  ${Y}=== HAPUS USER ===${NC}"
            i=1; for u in "${LIST[@]}"; do echo "  $i. $u"; ((i++)); done
            echo -ne "  Pilih No (Enter=Batal): " && read -r idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#LIST[@]}" ]; then
                target=${LIST[$((idx-1))]}
                jq --arg u "$target" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
                sync_all; send_notif "❌ <b>DELETED</b>: $target"
                echo -e "  ${G}Sukses: $target dihapus.${NC}";
            else echo -e "  ${Y}Dibatalkan.${NC}"; fi; wait_enter ;;
        3|03) 
            echo -e "\n  ${Y}=== DAFTAR AKUN ZIVPN ===${NC}"
            printf "  ${B}%-4s %-16s %-12s${NC}\n" "NO" "USERNAME" "EXPIRED"
            echo "  ------------------------------------"
            i=1
            while IFS=$'\t' read -r user exp; do
                printf "  ${C}%-4s ${NC}%-16s ${Y}%-12s${NC}\n" "$i" "$user" "$exp"
                ((i++))
            done < <(jq -r '.accounts[] | "\(.user)\t\(.expired)"' "$META_FILE")
            echo "  ------------------------------------"
            wait_enter ;;
        4|04) 
            echo -ne "  Restarting..."; systemctl restart "$SERVICE_NAME"; echo -e " ${G}OK!${NC}"; wait_enter ;;
        5|05) 
            if [ -z "$TG_BOT_TOKEN" ]; then echo -e "  ${R}Set Telegram dulu!${NC}"; wait_enter; continue; fi
            echo -ne "  Backup..."; ZIP="/tmp/zivpn_backup.zip"
            zip -j "$ZIP" "$CONFIG_FILE" "$META_FILE" >/dev/null
            curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$ZIP" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" >/dev/null
            rm -f "$ZIP"; echo -e " ${G}Terkirim!${NC}"; wait_enter ;;
        6|06) 
            if [ -z "$TG_BOT_TOKEN" ]; then echo -e "  ${R}Set Telegram dulu!${NC}"; wait_enter; continue; fi
            echo -e "  ${Y}Cek backup...${NC}"
            JSON=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?limit=100")
            FID=$(echo "$JSON" | jq -r '.result | reverse | .[] | select(.message.document != null) | .message.document.file_id' | head -n 1)
            if [ -z "$FID" ] || [ "$FID" == "null" ]; then echo -e "  ${R}ZIP tidak ditemukan.${NC}"; else
                FPATH=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getFile?file_id=$FID" | jq -r '.result.file_path')
                wget -q -O /tmp/restore.zip "https://api.telegram.org/file/bot$TG_BOT_TOKEN/$FPATH"
                [ -s /tmp/restore.zip ] && unzip -o /tmp/restore.zip -d /etc/zivpn/ >/dev/null && echo -e "  ${G}Restore Sukses!${NC}" || echo -e "  ${R}Gagal.${NC}"
                rm -f /tmp/r.zip
            fi; wait_enter ;;
        7|07)
            while true; do
                clear; echo -e "${C}=== TELEGRAM ===${NC}"
                echo -e "  Token: ${TG_BOT_TOKEN:-Belum Diset}"
                echo -e "  ID   : ${TG_CHAT_ID:-Belum Diset}"
                echo -e "  1. Ubah | 0. Kembali"
                echo -ne "  Pilih: " && read -r o
                case $o in
                    1) echo -ne "  Token: " && read -r NT; echo -ne "  ID: " && read -r NI; 
                       echo "TG_BOT_TOKEN=\"$NT\"" > "$TG_CONF"; echo "TG_CHAT_ID=\"$NI\"" >> "$TG_CONF"; source "$TG_CONF"; break ;;
                    0) break ;;
                esac
            done ;;
        8|08)
            echo -e "  1. ON  (Optimized)\n  2. OFF (Default)"
            echo -ne "  Pilih: " && read -r tw
            [ "$tw" == "1" ] && manage_tweaks "on"; [ "$tw" == "2" ] && manage_tweaks "off"; wait_enter ;;
        9|09)
            echo -e "  ${Y}Sedang mengecek update...${NC}"
            wget -q -O /tmp/z.sh "https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh"
            if [ -s /tmp/z.sh ]; then
                mv /tmp/z.sh "$MANAGER_PATH" && chmod +x "$MANAGER_PATH"
                echo -e "  ${G}Berhasil diupdate! Script akan restart...${NC}"
                sleep 2; exit 0
            else
                echo -e "  ${R}Gagal download update!${NC}"
                wait_enter
            fi ;;
        0|00) exit 0 ;;
        *) echo -e "  ${R}Salah.${NC}"; sleep 1 ;;
    esac
done
EOF

chmod +x "/usr/local/bin/zivpn-manager.sh"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT" && chmod +x "$SHORTCUT"

# INSTALL CRON AUTO-HEALING & PERSISTENCE
(crontab -l 2>/dev/null | grep -v "zivpn-manager.sh") | crontab -
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/zivpn-manager.sh cron") | crontab -
(crontab -l 2>/dev/null; echo "@reboot /usr/local/bin/zivpn-manager.sh cron") | crontab -

clear
echo -e "${G}✅ V73 PERFECTED INSTALLED!${NC}"
echo -e "Fitur firewall persistence telah diaktifkan."
