#!/bin/bash

# --- KONFIGURASI PATH ---
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
MANAGER_SCRIPT="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/menu"  # NAMA SHORTCUT DIGANTI JADI 'menu'
LOG_FILE="/var/log/zivpn-expired.log"

# --- CONFIG TELEGRAM ---
TG_BOT_TOKEN="6506568094:AAFXpDoZs3lb0tqGGToUMI7pyYQ-_vSY5F8"
TG_CHAT_ID="6132013792"

# 1. Perbaikan Struktur JSON (Reset jika file rusak/kosong)
mkdir -p /etc/zivpn
if [ ! -s "$CONFIG_FILE" ]; then
    echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
fi
if [ ! -s "$META_FILE" ]; then
    echo '{"accounts":[]}' > "$META_FILE"
fi
touch "$LOG_FILE"

# 2. Menulis Script Manager Utama
cat <<'EOF' > "$MANAGER_SCRIPT"
#!/bin/bash

CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
LOG_FILE="/var/log/zivpn-expired.log"
TG_BOT_TOKEN="6506568094:AAFXpDoZs3lb0tqGGToUMI7pyYQ-_vSY5F8"
TG_CHAT_ID="6132013792"

send_tg() {
    local MSG=$1
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$TG_CHAT_ID" -d parse_mode="HTML" --data-urlencode text="$MSG" >/dev/null
}

sync_accounts() {
    # Ambil pass dari config.json
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
    
    # Gunakan temporary file untuk membaca list agar tidak crash
    jq -c '.accounts[]' "$META_FILE" 2>/dev/null > /tmp/acc_list.txt
    
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user')
        local exp=$(echo "$acc" | jq -r '.expired')
        
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            # Hapus dari kedua file
            jq --arg u "$user" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
            
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Terhapus: $user" >> "$LOG_FILE"
            send_tg "<b>⚠️ AKUN EXPIRED TERHAPUS</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>$user</code>%0A━━━━━━━━━━━━━━"
            changed=true
        fi
    done < /tmp/acc_list.txt

    if [ "$changed" = true ]; then
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
    fi
}

list_accounts() {
    clear
    echo "===================================="
    echo "       DAFTAR AKUN ZIVPN"
    echo "===================================="
    printf "%-18s %-12s %-10s\n" "USER" "EXP" "STATUS"
    echo "------------------------------------"
    local today=$(date +%s)
    jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE" 2>/dev/null | while read -r u e; do
        local exp_ts=$(date -d "$e" +%s 2>/dev/null)
        local status="Aktif"
        [ "$today" -ge "$exp_ts" ] && status="Expired"
        printf "%-18s %-12s %-10s\n" "$u" "$e" "$status"
    done
    echo "===================================="
    read -rp "Tekan Enter..." enter
}

add_account() {
    read -rp "Password/User: " new_user
    [ -z "$new_user" ] && return
    read -rp "Masa Aktif (Hari): " days
    [[ ! "$days" =~ ^[0-9]+$ ]] && days=30
    local exp_date=$(date -d "+$days days" +%Y-%m-%d)
    
    jq --arg u "$new_user" '.auth.config += [$u]' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
    jq --arg u "$new_user" --arg e "$exp_date" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
    
    systemctl restart "$SERVICE_NAME"
    send_tg "<b>✅ AKUN BARU</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>$new_user</code>%0A<b>Exp:</b> <code>$exp_date</code>%0A━━━━━━━━━━━━━━"
    echo "Berhasil."
    sleep 2
}

case "$1" in
    cron)
        sync_accounts
        auto_remove_expired
        ;;
    *)
        while true; do
            clear
            echo "================================"
            echo "   ZIVPN UDP MANAGER"
            echo "================================"
            echo "1. Lihat Akun"
            echo "2. Tambah Akun"
            echo "3. Hapus Akun"
            echo "4. Cek Log"
            echo "0. Keluar"
            echo "================================"
            read -rp "Pilih: " opt
            case $opt in
                1) list_accounts ;;
                2) add_account ;;
                3) read -rp "User: " d; jq --arg u "$d" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"; jq --arg u "$d" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"; systemctl restart "$SERVICE_NAME";;
                4) tail -n 20 "$LOG_FILE"; read -rp "Enter..." ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac
EOF

# 3. Setting Shortcut (Gunakan perintah 'menu')
chmod +x "$MANAGER_SCRIPT"
rm -f /usr/local/bin/zivpn # Hapus shortcut lama yang bentrok
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
echo "    INSTALASI SELESAI    "
echo "=========================================="
echo " Shortcut Baru : menu"
echo " Auto Expired  : Aktif (00:00)"
echo "=========================================="
echo " Jalankan dengan mengetik: menu"
echo "=========================================="
