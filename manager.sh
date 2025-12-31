#!/bin/bash

# --- 1. PRE-INSTALLATION ---
apt-get update -qq && apt-get install iptables iptables-persistent jq vnstat curl wget sudo lsb-release zip unzip net-tools tcpdump -y -qq

# Config IP Forwarding
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/00-zivpn-core.conf
sysctl -p /etc/sysctl.d/00-zivpn-core.conf >/dev/null 2>&1

# FORCE FLUSH IPTABLES (NUCLEAR OPTION)
# Kita hapus semua aturan lama yang mungkin nyangkut
apply_iptables_reset() {
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    
    # 1. Set Default Policy to ACCEPT (Sementara untuk testing)
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    # 2. Flush All Rules
    iptables -F
    iptables -t nat -F
    iptables -X
    
    # 3. Allow Port 5667 Explicitly
    iptables -A INPUT -p udp --dport 5667 -j ACCEPT
    iptables -A INPUT -p tcp --dport 5667 -j ACCEPT
    
    # 4. NAT Masquerade
    iptables -t nat -A POSTROUTING -o "$IF" -j MASQUERADE
    
    netfilter-persistent save >/dev/null 2>&1
}
apply_iptables_reset

# Path Setup
CONFIG_DIR="/etc/zivpn"; CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"; TG_CONF="/etc/zivpn/telegram.conf"
TWEAK_FILE="/etc/sysctl.d/99-zivpn-turbo.conf"
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"; SHORTCUT="/usr/local/bin/menu"

mkdir -p "$CONFIG_DIR"
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":"0.0.0.0:5667"}' > "$CONFIG_FILE"
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

# FUNGSI NOTIF
send_notif() {
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d parse_mode="html" -d text="$1" >/dev/null 2>&1 &
    fi
}

# SYNC & WATCHDOG
sync_all() {
    # Force Listen 0.0.0.0
    local CURRENT_LISTEN=$(jq -r '.listen' "$CONFIG_FILE")
    if [[ "$CURRENT_LISTEN" != "0.0.0.0:5667" ]]; then
        jq '.listen = "0.0.0.0:5667"' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
    fi
    
    # Watchdog Firewall
    iptables -C INPUT -p udp --dport 5667 -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport 5667 -j ACCEPT

    local today=$(date +%s); local changed=false
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user'); local exp=$(echo "$acc" | jq -r '.expired')
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            send_notif "🚫 <b>EXPIRED</b>: <code>$user</code>"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)

    local USERS_FROM_META=$(jq -c '[.accounts[].user]' "$META_FILE")
    jq --argjson u "$USERS_FROM_META" '.auth.config = $u' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
    
    [ "$changed" = true ] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
}

# MANAJEMEN TWEAK
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
    
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    local BW_JSON=$(vnstat -i "$IF" --json 2>/dev/null)
    local T_D=$(date +%-d); local T_M=$(date +%-m); local T_Y=$(date +%Y)
    local RX=$(echo "$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .rx // 0" 2>/dev/null)
    local TX=$(echo "$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .tx // 0" 2>/dev/null)
    local BW_STR="↓$(awk -v b="$RX" 'BEGIN {printf "%.2f", b/1024/1024}') MB | ↑$(awk -v b="$TX" 'BEGIN {printf "%.2f", b/1024/1024}') MB"
    
    local BIND_STAT=$(netstat -tulpn | grep 5667 | awk '{print $4}')
    [[ "$BIND_STAT" == "0.0.0.0:5667" ]] && PORT_STATUS="${G}IPv4 OK${NC}" || PORT_STATUS="${R}Checking...${NC}"

    echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${C}┃${NC}        ${Y}ZIVPN PACKET SNIFFER V53${NC}         ${C}┃${NC}"
    echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "IP Address" "$IP"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Uptime" "$UP"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Port 5667" "$PORT_STATUS"
    if [ -f "$TWEAK_FILE" ]; then 
        printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Turbo Tweak" "[ON] Active"
    else 
        printf " ${C}┃${NC} %-12s : ${R}%-26s${NC} ${C}┃${NC}\n" "Turbo Tweak" "[OFF] Default"
    fi
    printf " ${C}┃${NC} %-12s : ${Y}%-26s${NC} ${C}┃${NC}\n" "Daily BW" "$BW_STR"
    echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
}

while true; do
    sync_all; draw_header
    echo -e "  ${C}[${Y}01${C}]${NC} Tambah Akun           ${C}[${Y}06${C}]${NC} Restore ZIP"
    echo -e "  ${C}[${Y}02${C}]${NC} Hapus Akun            ${C}[${Y}07${C}]${NC} Telegram Settings"
    echo -e "  ${C}[${Y}03${C}]${NC} Daftar Akun           ${C}[${Y}08${C}]${NC} Turbo Tweaks"
    echo -e "  ${C}[${Y}04${C}]${NC} Restart Service       ${C}[${Y}09${C}]${NC} Update Script"
    echo -e "  ${C}[${Y}05${C}]${NC} Backup ZIP            ${C}[${Y}10${C}]${NC} Cek & Monitor Trafik"
    echo -e "  ${C}[${Y}00${C}]${NC} Keluar"
    echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "  ${B}Pilih Menu${NC}: " && read choice
    case $choice in
        1|01) 
            echo -ne "  User: " && read n; [ -z "$n" ] && continue
            echo -ne "  Hari: " && read d; [[ ! "$d" =~ ^[0-9]+$ ]] && continue
            exp=$(date -d "+$d days" +%Y-%m-%d)
            jq --arg u "$n" --arg e "$exp" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            sync_all; systemctl restart "$SERVICE_NAME"
            send_notif "✅ <b>NEW USER</b>%0AUser: <code>$n</code>%0AExp: $exp"
            echo -e "  ${G}Sukses: User $n Aktif.${NC}"; sleep 2 ;;
        2|02) 
            mapfile -t LIST < <(jq -r '.accounts[].user' "$META_FILE")
            i=1; for u in "${LIST[@]}"; do echo "  $i. $u"; ((i++)); done
            echo -ne "  No: " && read idx
            if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#LIST[@]}" ]; then
                target=${LIST[$((idx-1))]}
                jq --arg u "$target" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
                sync_all; systemctl restart "$SERVICE_NAME"
                send_notif "❌ <b>DELETED</b>: $target"
                echo -e "  ${G}Dihapus: $target${NC}"; sleep 2
            else echo -e "  ${R}Batal.${NC}"; sleep 1; fi ;;
        3|03) 
            printf "  %-15s %-12s\n" "USER" "EXPIRED"
            jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE" | while read -r u e; do printf "  %-15s %-12s\n" "$u" "$e"; done
            read -rp "  Enter..." ;;
        4|04) systemctl restart "$SERVICE_NAME"; echo -e " ${G}DONE!${NC}"; sleep 1 ;;
        5|05) 
            ZIP="/tmp/zivpn_backup.zip"; zip -j "$ZIP" "$CONFIG_FILE" "$META_FILE" >/dev/null
            curl -s -F chat_id="$TG_CHAT_ID" -F document=@"$ZIP" "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" >/dev/null
            rm -f "$ZIP"; echo -e " ${G}Sent!${NC}"; sleep 2 ;;
        6|06) 
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
        10|10)
            echo -e "\n  ${Y}=== LIVE TRAFFIC MONITOR ===${NC}"
            echo -e "  Script akan memantau paket data di Port 5667 selama 15 detik."
            echo -e "  ${G}SILAKAN COBA CONNECT DARI HP SEKARANG!${NC}"
            echo -e "  -------------------------------------------------"
            # TCPDUMP Monitoring
            timeout 15 tcpdump -i any udp port 5667 -n -v
            echo -e "  -------------------------------------------------"
            echo -e "  ${B}ANALISIS:${NC}"
            echo -e "  1. Jika layar ${R}KOSONG${NC} (tidak ada teks muncul):"
            echo -e "     Berarti Firewall VPS (AWS/Aliyun/GCP) memblokir port 5667."
            echo -e "     -> Buka website provider VPS Anda, cari 'Security Group', Allow UDP 5667."
            echo -e "  2. Jika ada teks ${G}muncul${NC} tapi tetap disconnect:"
            echo -e "     Berarti paket masuk, tapi Config/Password di HP salah."
            read -rp "  Tekan Enter untuk kembali..." ;;
        0|00) exit 0 ;;
    esac
done
EOF

chmod +x "/usr/local/bin/zivpn-manager.sh"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT" && chmod +x "$SHORTCUT"
(crontab -l 2>/dev/null | grep -v "zivpn-manager.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/zivpn-manager.sh cron") | crontab -

clear
echo -e "${G}✅ V53 PACKET SNIFFER INSTALLED!${NC}"
echo -e "Gunakan ${Y}Menu 10${NC} untuk melihat apakah sinyal dari HP sampai ke VPS atau tidak."
