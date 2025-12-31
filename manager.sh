#!/bin/bash

# --- PRE-INSTALLATION & TWEAKS ---
apt-get update -qq && apt-get install iptables iptables-persistent jq vnstat curl wget sudo lsb-release -y -qq

# 1. Apply Kernel Tweaks (BBR & TCP Optimization)
cat <<EOF > /etc/sysctl.d/99-zivpn.conf
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-zivpn.conf >/dev/null 2>&1

# 2. Apply IPTables (NAT & Forwarding)
apply_iptables() {
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    iptables -F
    iptables -t nat -F
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$IF" -j MASQUERADE
    iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o "$IF" -j MASQUERADE
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -j ACCEPT
    # Simpan agar permanen (iptables-persistent)
    netfilter-persistent save >/dev/null 2>&1
    netfilter-persistent reload >/dev/null 2>&1
}
apply_iptables

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

# --- MENULIS SCRIPT MANAGER UTAMA ---
cat <<'EOF' > "/usr/local/bin/zivpn-manager.sh"
#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TG_CONF="/etc/zivpn/telegram.conf"
[ -f "$TG_CONF" ] && source "$TG_CONF"
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"

C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# Sinkronisasi & Pembersihan
sync_and_clean() {
    # Re-apply IPTables jika hilang
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if ! iptables -t nat -C POSTROUTING -o "$IF" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IF" -j MASQUERADE
        iptables -A FORWARD -j ACCEPT
    fi

    local today=$(date +%s); local changed=false
    local all_pass=$(jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null)
    for pass in $all_pass; do
        [ -z "$pass" ] || [ "$pass" == "null" ] && continue
        local exists=$(jq -r --arg u "$pass" '.accounts[] | select(.user==$u) | .user' "$META_FILE" 2>/dev/null)
        [ -z "$exists" ] && jq --arg u "$pass" --arg e "2099-12-31" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
    done
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user'); local exp=$(echo "$acc" | jq -r '.expired')
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            jq --arg u "$user" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)
    [ "$changed" = true ] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
}

draw_header() {
    clear
    local IP=$(curl -s ifconfig.me); local UP=$(uptime -p | sed 's/up //')
    local RAM_U=$(free -h | awk '/Mem:/ {print $3}'); local RAM_T=$(free -h | awk '/Mem:/ {print $2}')
    local CPU=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')"%"
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    local BW=$(vnstat -i "$IF" --json 2>/dev/null); local T_D=$(date +%-d); local T_M=$(date +%-m); local T_Y=$(date +%Y)
    local RX=$(echo "$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .rx // 0" 2>/dev/null)
    local TX=$(echo "$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .tx // 0" 2>/dev/null)
    local BD=$(awk -v b="$RX" 'BEGIN {printf "%.2f MB", b/1024/1024}')
    local BU=$(awk -v b="$TX" 'BEGIN {printf "%.2f MB", b/1024/1024}')

    echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${C}┃${NC}      ${Y}ZIVPN HARMONY DASHBOARD V35${NC}     ${C}┃${NC}"
    echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "IP Address" "$IP"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Uptime" "$UP"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "CPU Load" "$CPU"
    printf " ${C}┃${NC} %-12s : ${G}%-26s${NC} ${C}┃${NC}\n" "Ram Usage" "$RAM_U / $RAM_T"
    printf " ${C}┃${NC} %-12s : ${G}↓$BD${NC} | ${R}↑$BU${NC} %-11s ${C}┃${NC}\n" "Traffic" ""
    echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
}

case "$1" in
    cron) sync_and_clean; exit 0 ;;
    *)
    while true; do
        sync_and_clean; draw_header
        echo -e "  ${C}[${Y}01${C}]${NC} Tambah Akun           ${C}[${Y}05${C}]${NC} Backup Telegram"
        echo -e "  ${C}[${Y}02${C}]${NC} Hapus Akun            ${C}[${Y}06${C}]${NC} Restore Telegram"
        echo -e "  ${C}[${Y}03${C}]${NC} Lihat Daftar Akun     ${C}[${Y}07${C}]${NC} Settings Telegram"
        echo -e "  ${C}[${Y}04${C}]${NC} Restart Service       ${C}[${Y}08${C}]${NC} Update Script"
        echo -e "  ${C}[${Y}00${C}]${NC} Keluar"
        echo -e "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -ne "  ${B}Pilih Menu${NC}: " && read choice
        case $choice in
            1|01) 
                echo -e "\n${C}┏━━━━━━━━━━━━━━━${Y} TAMBAH AKUN ${C}━━━━━━━━━━━━━━━┓${NC}"
                echo -ne "  User: " && read n; echo -ne "  Hari: " && read d
                exp=$(date -d "+$d days" +%Y-%m-%d)
                jq --arg u "$n" '.auth.config += [$u]' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
                jq --arg u "$n" --arg e "$exp" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
                systemctl restart "$SERVICE_NAME"; sleep 2 ;;
            2|02) 
                clear; echo -e "${C}┏━━━━━━━━━━━━━━${Y} HAPUS AKUN ${C}━━━━━━━━━━━━━━┓${NC}"
                mapfile -t LIST < <(jq -r '.auth.config[]' "$CONFIG_FILE")
                i=1; for u in "${LIST[@]}"; do printf " ${C}┃${NC}  ${Y}[%02d]${NC} %-34s ${C}┃${NC}\n" "$i" "$u"; ((i++)); done
                echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
                echo -ne "  No: " && read idx; target=${LIST[$((idx-1))]}
                [ ! -z "$target" ] && jq --arg u "$target" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE" && jq --arg u "$target" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE" && systemctl restart "$SERVICE_NAME" ;;
            3|03) 
                clear; echo -e "${C}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
                printf " ${C}┃${NC}  ${Y}NO  %-18s %-12s${NC}      ${C}┃${NC}\n" "USER" "EXPIRED"
                echo -e "${C}┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫${NC}"
                i=1; while read -r u e; do printf " ${C}┃${NC}  ${G}%02d${NC}  %-18s %-12s      ${C}┃${NC}\n" "$i" "$u" "$e"; ((i++)); done < <(jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE")
                echo -e "${C}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"; read -rp " Enter..." ;;
            4|04) systemctl restart "$SERVICE_NAME"; sleep 1 ;;
            5|05) cp "$CONFIG_FILE" /tmp/config.json; curl -s -F chat_id="$TG_CHAT_ID" -F document=@/tmp/config.json "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument"; sleep 1 ;;
            6|06) 
                UPD=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?limit=100")
                FID=$(echo "$UPD" | jq -r '.result[] | select(.message.document.file_name=="config.json") | .message.document.file_id' | tail -n 1)
                [ ! -z "$FID" ] && FPATH=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getFile?file_id=$FID" | jq -r '.result.file_path') && wget -q -O "$CONFIG_FILE" "https://api.telegram.org/file/bot$TG_BOT_TOKEN/$FPATH" && systemctl restart "$SERVICE_NAME" ;;
            7|07) echo -ne "Token: " && read NT; echo -ne "ID: " && read NI; echo "TG_BOT_TOKEN=\"$NT\"" > "$TG_CONF"; echo "TG_CHAT_ID=\"$NI\"" >> "$TG_CONF"; sleep 1 ;;
            8|08) wget -q -O /tmp/z.sh "https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh" && mv /tmp/z.sh "/usr/local/bin/zivpn-manager.sh" && chmod +x "/usr/local/bin/zivpn-manager.sh"; exit 0 ;;
            0|00) exit 0 ;;
        esac
    done ;;
esac
EOF

# --- FINALISASI ---
chmod +x "/usr/local/bin/zivpn-manager.sh"
echo "sudo bash /usr/local/bin/zivpn-manager.sh" > "$SHORTCUT" && chmod +x "$SHORTCUT"
(crontab -l 2>/dev/null | grep -v "zivpn-manager.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/zivpn-manager.sh cron") | crontab -

clear
echo -e "${G}✅ V35 IMMORTAL VERSION INSTALLED!${NC}"
echo -e "IPTables sudah dikunci secara permanen dengan iptables-persistent."

# Tampilkan status iptables singkat
echo -e "\n${Y}Current IPTables NAT:${NC}"
iptables -t nat -L POSTROUTING -n --line-number | grep MASQUERADE
