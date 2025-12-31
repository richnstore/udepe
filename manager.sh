#!/bin/bash

# --- KONFIGURASI PATH ---
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
MANAGER_SCRIPT="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/menu"
LOG_FILE="/var/log/zivpn-expired.log"

# --- CONFIG TELEGRAM ---
TG_BOT_TOKEN="6506568094:AAFXpDoZs3lb0tqGGToUMI7pyYQ-_vSY5F8"
TG_CHAT_ID="6132013792"

# 1. Inisialisasi Database
mkdir -p /etc/zivpn
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"
touch "$LOG_FILE"

# 2. Menulis Script Manager
cat <<'EOF' > "$MANAGER_SCRIPT"
#!/bin/bash

CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
TG_BOT_TOKEN="6506568094:AAFXpDoZs3lb0tqGGToUMI7pyYQ-_vSY5F8"
TG_CHAT_ID="6132013792"
LOG_FILE="/var/log/zivpn-expired.log"

# --- FUNGSI HELPER ---
send_tg() {
    local MSG=$1
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d parse_mode="HTML" --data-urlencode text="$MSG" >/dev/null
}

sync_accounts() {
    local all_pass=$(jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null)
    for pass in $all_pass; do
        [ -z "$pass" ] || [ "$pass" == "null" ] && continue
        local exists=$(jq -r --arg u "$pass" '.accounts[] | select(.user==$u) | .user' "$META_FILE" 2>/dev/null)
        if [ -z "$exists" ]; then
            jq --arg u "$pass" --arg e "2099-12-31" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
        fi
    done
}

auto_remove_expired() {
    local today=$(date +%s)
    local changed=false
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user')
        local exp=$(echo "$acc" | jq -r '.expired')
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            jq --arg u "$user" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Expired: $user" >> "$LOG_FILE"
            send_tg "<b>⚠️ AKUN EXPIRED TERHAPUS</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>$user</code>%0A━━━━━━━━━━━━━━"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)
    [ "$changed" = true ] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
}

# --- FUNGSI MENU ---
list_accounts() {
    clear
    echo "=== DAFTAR AKUN ZIVPN ==="
    local today=$(date +%s)
    printf "%-18s %-12s %-10s\n" "USER/PASS" "EXP" "STATUS"
    echo "----------------------------------------------"
    jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE" 2>/dev/null | while read -r u e; do
        local exp_ts=$(date -d "$e" +%s 2>/dev/null)
        local status="Aktif"
        [ "$today" -ge "$exp_ts" ] && status="Expired"
        printf "%-18s %-12s %-10s\n" "$u" "$e" "$status"
    done
    read -rp "Enter..." enter
}

add_account() {
    read -rp "Password Baru: " new_pass
    [ -z "$new_pass" ] && return
    read -rp "Masa Aktif (Hari): " days
    [[ ! "$days" =~ ^[0-9]+$ ]] && days=30
    local exp_date=$(date -d "+$days days" +%Y-%m-%d)
    jq --arg u "$new_pass" '.auth.config += [$u]' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
    jq --arg u "$new_pass" --arg e "$exp_date" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
    systemctl restart "$SERVICE_NAME"
    send_tg "<b>✅ AKUN BARU DIBUAT</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>$new_pass</code>%0A<b>Exp:</b> <code>$exp_date</code>%0A━━━━━━━━━━━━━━"
    echo "Sukses."
    sleep 1
}

delete_account() {
    read -rp "Password yang akan dihapus: " del_pass
    jq --arg u "$del_pass" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
    jq --arg u "$del_pass" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
    systemctl restart "$SERVICE_NAME"
    echo "Terhapus."
    sleep 1
}

vps_status() {
    clear
    echo "=== STATUS VPS ==="
    echo "Uptime     : $(uptime -p)"
    echo "CPU Usage  : $(top -bn1 | grep Cpu | awk '{print $2 + $4 "%"}')"
    echo "RAM Usage  : $(free -h | awk '/Mem:/ {print $3 " / " $2}')"
    echo "Disk Usage : $(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
    echo "=================="
    read -rp "Enter..." enter
}

# --- MENU UTAMA ---
case "$1" in
    cron)
        sync_accounts
        auto_remove_expired
        ;;
    *)
        while true; do
            clear
            sync_accounts
            auto_remove_expired
            
            # Statistik Header
            VPS_IP=$(curl -s ifconfig.me || echo "Error")
            ISP_NAME=$(curl -s https://ipinfo.io/org | cut -d' ' -f2- || echo "Error")
            NET_IFACE=$(ip route | awk '/default/ {print $5}' | head -n1)
            
            # Bandwidth (Membutuhkan vnstat)
            BW_D_RAW=$(vnstat -i "$NET_IFACE" --json 2>/dev/null | jq -r '.interfaces[0].traffic.day[-1].rx' 2>/dev/null || echo "0")
            BW_U_RAW=$(vnstat -i "$NET_IFACE" --json 2>/dev/null | jq -r '.interfaces[0].traffic.day[-1].tx' 2>/dev/null || echo "0")
            BW_D=$(awk -v b=$BW_D_RAW 'BEGIN {printf "%.2f MB", b/1024/1024}')
            BW_U=$(awk -v b=$BW_U_RAW 'BEGIN {printf "%.2f MB", b/1024/1024}')

            echo "===================================="
            echo "     ZIVPN UDP ACCOUNT MANAGER"
            echo "===================================="
            echo " IP VPS       : ${VPS_IP}"
            echo " ISP          : ${ISP_NAME}"
            echo " Daily BW     : D $BW_D | U $BW_U"
            echo "===================================="
            echo " 1) Lihat Semua Akun"
            echo " 2) Tambah Akun Baru"
            echo " 3) Hapus Akun"
            echo " 4) Restart Layanan"
            echo " 5) Status System VPS"
            echo " 6) Backup & Kirim Telegram"
            echo " 0) Keluar"
            echo "===================================="
            read -rp " Pilih Menu: " choice

            case $choice in
                1) list_accounts ;;
                2) add_account ;;
                3) delete_account ;;
                4) systemctl restart "$SERVICE_NAME"; echo "Restarted."; sleep 1 ;;
                5) vps_status ;;
                6) 
                   cp "$CONFIG_FILE" /tmp/backup_config.json
                   cp "$META_FILE" /tmp/backup_meta.json
                   curl -s -F chat_id="$TG_CHAT_ID" -F document=@/tmp/backup_config.json https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument > /dev/null
                   curl -s -F chat_id="$TG_CHAT_ID" -F document=@/tmp/backup_meta.json https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument > /dev/null
                   echo "Backup terkirim ke Telegram."; sleep 2 ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac
EOF

# 3. Create Shortcut & Permission
chmod +x "$MANAGER_SCRIPT"
rm -f /usr/local/bin/zivpn
cat <<EOF > "$SHORTCUT"
#!/bin/bash
sudo bash $MANAGER_SCRIPT
EOF
chmod +x "$SHORTCUT"

# 4. Set Cron Jam 00:00
(crontab -l 2>/dev/null | grep -v "$MANAGER_SCRIPT cron") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * $MANAGER_SCRIPT cron") | crontab -

clear
echo "=========================================="
echo "   ZIVPN MANAGER BERHASIL DIINSTAL  "
echo "=========================================="
echo " Ketik 'menu' untuk membuka manager."
echo " Auto Expired aktif setiap jam 00:00."
echo "=========================================="
