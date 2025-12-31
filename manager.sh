#!/bin/bash

# --- 1. PRE-INSTALLATION ---
apt-get update -qq && apt-get install jq vnstat curl wget sudo lsb-release zip unzip net-tools cron iptables-persistent -y -qq

# Simpan rule firewall yang sudah ada (sesuai request V63)
netfilter-persistent save >/dev/null 2>&1

# --- 2. CONFIG SETUP ---
CONFIG_DIR="/etc/zivpn"
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
TG_CONF="/etc/zivpn/telegram.conf"
TWEAK_FILE="/etc/sysctl.d/99-zivpn-turbo.conf"
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/menu"

mkdir -p "$CONFIG_DIR"
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":"0.0.0.0:5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"

# --- 3. SCRIPT MANAGER UTAMA ---
cat <<'EOF' > "/usr/local/bin/zivpn-manager.sh"
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"
TG_CONF="/etc/zivpn/telegram.conf"; [ -f "$TG_CONF" ] && source "$TG_CONF"
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
TWEAK_FILE="/etc/sysctl.d/99-zivpn-turbo.conf"
SERVICE_NAME="zivpn.service"

C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

send_notif() {
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d parse_mode="html" -d text="$1" >/dev/null 2>&1 &
    fi
}

# --- SMART AUTO-SYNC (JANTUNG OTOMATISASI) ---
sync_all() {
    # 1. Pastikan Config 0.0.0.0
    local CUR_L=$(jq -r '.listen' "$CONFIG_FILE")
    if [[ "$CUR_L" != "0.0.0.0:"* ]]; then
        local PORT=$(echo "$CUR_L" | grep -oE '[0-9]+$'); [ -z "$PORT" ] && PORT="5667"
        jq --arg p "0.0.0.0:$PORT" '.listen = $p' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
        local FORCE_RESTART=true
    fi

    # 2. Hapus User Expired
    local today=$(date +%s); local meta_changed=false
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user'); local exp=$(echo "$acc" | jq -r '.expired')
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            send_notif "🚫 <b>EXPIRED</b>: <code>$user</code>"
            meta_changed=true
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)

    # 3. DETEKSI PERBEDAAN (Meta vs Config)
    # Ambil list user dari Meta (Source of Truth)
    local USERS_META=$(jq -c '.accounts[].user' "$META_FILE" | sort | jq -s '.')
    # Ambil list user dari Config (Current State)
    local USERS_CONF=$(jq -c '.auth.config' "$CONFIG_FILE" | jq -r '.[]' | sort | jq -s '.')

    # Jika beda, atau ada user expired, atau force restart -> UPDATE & RESTART
    if [ "$USERS_META" != "$USERS_CONF" ] || [ "$meta_changed" = true ] || [ "$FORCE_RESTART" = true ]; then
        # Tulis ulang config.json dengan data user yang benar dari Meta
        jq --argjson u "$USERS_META" '.auth.config = $u' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
        
        # Restart Service
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
        
        # Jika dipanggil via cron, log perbaikan (opsional)
        if [ "$1" == "cron_check" ]; then echo "$(date): Auto-Repaired Auth" >> /var/log/zivpn-autorepair.log; fi
    fi
}

# --- CRON HANDLER ---
if [ "$1" == "cron" ]; then
    sync_all "cron_check"
    exit 0
fi

# TWEAK & UI Functions
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

draw_header() {
    clear
    local IP=$(curl -s ifconfig.me || echo "No IP"); local UP=$(uptime -p | sed 's/up //')
    local RAM_U=$(free -h | awk '/Mem:/ {print $3}'); local CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')"%"
    
    local CUR_PORT=$(jq -r '.listen' "$CONFIG_FILE" | cut -d':' -f2)
    local BIND_STAT=$(netstat -tulpn | grep ":$CUR_PORT " | grep -v ":::" | awk '{print $4}')
    [[ ! -z "$BIND_STAT" ]] && PORT_STATUS="${G}Running ($CUR_PORT)${NC}" || PORT_STATUS="${R}Service Down${NC}"

    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    local BW_JSON=$(vnstat -i "$IF" --json 2>/dev/null)
    local T_D=$(date +%-d); local T_M=$(date +%-m); local T_Y=$(date +%Y)
    local RX=$(echo "$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .rx // 0" 2>/dev/null)
    local TX=$(echo "$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .tx // 0" 2>/dev/null)
    local BW_STR="↓$(awk -v b="$RX" 'BEGIN {printf "%.2f", b/1024/1024}') MB | ↑$(awk -v b="$TX" 'BEGIN {printf "%.2f", b/1024/1024}') MB"

    echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${C}┃${NC}        ${Y}ZIVPN AUTO-HEALING V65${NC}          ${C}┃${NC}"
    echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "IP Address" "$IP"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Uptime" "$UP"
    printf " ${C}┃${NC} %-12s : %-37s ${C}┃${NC}\n" "Service Port" "$PORT_STATUS"
    if [ -f "$TWEAK_FILE" ]; then 
        printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Turbo Tweak" "[ON] Active"
    else 
        printf " ${C}┃${NC} %-12s : ${R}%-26s${NC} ${C}┃${NC}\n" "Turbo Tweak" "[OFF] Default"
    fi
    printf " ${C}┃${NC} %-12s : ${Y}%-26s${NC} ${C}┃${NC}\n" "Daily BW" "$BW_STR"
    echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
}

while true; do
    # Jalankan Sync setiap buka menu (Double check)
    sync_all; draw_header
    echo -e "  ${C}[${Y}01${C}]${NC} Tambah Akun           ${C}[${Y}05${C}]${NC} Backup ZIP"
    echo -e "  ${C}[${Y}02${C}]${NC} Hapus Akun            ${C}[${Y}06${C}]${NC} Restore ZIP"
    echo -e "  ${C}[${Y}03${C}]${NC} Daftar Akun           ${C}[${Y}07${C}]${NC} Telegram Settings"
    echo -e "  ${C}[${Y}04${C}]${NC} Restart Service       ${C}[${Y}08${C}]${NC} Turbo Tweaks"
    echo -e "  ${C}[${Y}09${C}]${NC} Update Script         ${C}[${Y}00${C}]${NC} Keluar"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "  ${B}Pilih Menu${NC}: " && read choice
    case $choice in
        1|01) 
            echo -ne "  User: " && read n; [ -z "$n" ] && continue
            echo -ne "  Hari: " && read d; [[ ! "$d" =~ ^[0-9]+$ ]] && continue
            exp=$(date -d "+$d days" +%Y-%m-%d)
            jq --arg u "$n" --arg e "$exp" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            sync_all; send_notif "✅ <b>NEW USER</b>%0AUser: <code>$n</code>%0AExp: $exp"
            echo -e "  ${G}Sukses: User $n Aktif.${NC}"; sleep 2 ;;
        2|02) 
            mapfile -t LIST < <(jq -r '.accounts[].user' "$META_FILE")
            [ ${#LIST[@]} -eq 0 ] && { echo -e "  ${R}Kosong.${NC}"; sleep 1; continue; }
            i=1; for u in "${LIST[@]}"; do echo "  $i. $u"; ((i++)); done
            echo -ne "  No: " && read idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#LIST[@]}" ]; then
                target=${LIST[$((idx-1))]}
                jq --arg u "$target" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
                sync_all; send_notif "❌ <b>DELETED</b>: $target"
                echo -e "  ${G}Dihapus: $target${NC}"; sleep 2
            else echo -e "  ${R}Batal.${NC}"; sleep 1; fi ;;
        3|03) 
            printf "  %-15s %-12s\n" "USER" "EXPIRED"
            jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE" | while read -r u e; do printf "  %-15s %-12s\n" "$u" "$e"; done
            read -rp "  Enter..." ;;
        4|04) systemctl restart "$SERVICE_NAME"; echo -e " ${G}DONE!${NC}"; sleep 1 ;;
        5|05) 
            ZIP="/tmp/zivpn_backup.zip"; zip -j "$ZIP" "$CONFIG_FILE" "$META_FILE" >/dev/null
            [ -n "$TG_BOT_TOKEN" ] && curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$ZIP" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" >/dev/null
            rm -f "$ZIP"; echo -e " ${G}Selesai.${NC}"; sleep 2 ;;
        6|06) 
            [ -z "$TG_BOT_TOKEN" ] && { echo "Set Telegram dulu."; sleep 1; continue; }
            JSON=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?limit=100")
            FID=$(echo "$JSON" | jq -r '.result | reverse | .[] | select(.message.document != null) | .message.document.file_id' | head -n 1)
            FPATH=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getFile?file_id=$FID" | jq -r '.result.file_path')
            wget -q -O /tmp/r.zip "https://api.telegram.org/file/bot$TG_BOT_TOKEN/$FPATH"
            [ -s /tmp/r.zip ] && unzip -o /tmp/r.zip -d /etc/zivpn/ && systemctl restart "$SERVICE_NAME" && echo -e " ${G}Sukses!${NC}" || echo -e " ${R}Gagal!${NC}"
            rm -f /tmp/r.zip; sleep 2 ;;
        7|07)
            echo -e " 1. Cek\n 2. Ubah"; read o
            if [ "$o" == "2" ]; then
                echo -ne " Token: " && read NT; echo -ne " ID: " && read NI
                echo "TG_BOT_TOKEN=\"$NT\"" > "$TG_CONF"; echo "TG_CHAT_ID=\"$NI\"" >> "$TG_CONF"
            else source "$TG_CONF"; echo " Token: $TG_BOT_TOKEN"; fi; read -rp " Enter..." ;;
        8|08)
            echo -e " 1. Enable Turbo\n 2. Disable Turbo"; read tw
            [ "$tw" == "1" ] && manage_tweaks "on"; [ "$tw" == "2" ] && manage_tweaks "off"; sleep 2 ;;
        9|09) wget -q -O /tmp/z.sh "https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh" && mv /tmp/z.sh "$MANAGER_PATH" && chmod +x "$MANAGER_PATH" && exit 0 ;;
        0|00) exit 0 ;;
    esac
done
EOF

chmod +x "/usr/local/bin/zivpn-manager.sh"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT" && chmod +x "$SHORTCUT"

# --- INSTALL CRON PER MENIT (AUTO-HEALING) ---
# Cron ini akan mengecek database setiap 1 menit.
# Jika ada user yang terdaftar tapi tidak bisa login (Auth Wrong),
# script otomatis memperbaikinya saat menit berganti.
(crontab -l 2>/dev/null | grep -v "zivpn-manager.sh") | crontab -
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/zivpn-manager.sh cron") | crontab -
(crontab -l 2>/dev/null; echo "@reboot /usr/local/bin/zivpn-manager.sh cron") | crontab -

clear
echo -e "${G}✅ V65 FULLY AUTOMATIC INSTALLED!${NC}"
echo -e "Sistem Auto-Healing aktif setiap 1 menit."
echo -e "Masalah 'Auth Wrong' akan diperbaiki sendiri oleh sistem secara otomatis."
