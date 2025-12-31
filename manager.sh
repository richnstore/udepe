#!/bin/bash

# --- KONFIGURASI PATH ---
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
MANAGER_SCRIPT="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/zivpn"
LOG_FILE="/var/log/zivpn-expired.log"

# --- CONFIG TELEGRAM ---
TG_BOT_TOKEN="6506568094:AAFXpDoZs3lb0tqGGToUMI7pyYQ-_vSY5F8"
TG_CHAT_ID="6132013792"

# 1. Inisialisasi File (Jika belum ada atau kosong)
mkdir -p /etc/zivpn
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"
touch "$LOG_FILE"

# 2. Menulis Script Manager Utama
cat <<'EOF' > "$MANAGER_SCRIPT"
#!/bin/bash

# Load Variables
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
    # Ambil semua pass dari config.json, pastikan meta.json punya data expirednya
    mapfile -t all_pass < <(jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null)
    for pass in "${all_pass[@]}"; do
        [ -z "$pass" ] && continue
        exists=$(jq -r --arg u "$pass" '.accounts[] | select(.user==$u) | .user' "$META_FILE" 2>/dev/null)
        if [ -z "$exists" ]; then
            jq --arg u "$pass" --arg e "2099-12-31" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
        fi
    done
}

auto_remove_expired() {
    today=$(date +%s)
    changed=false
    
    # Baca akun satu per satu untuk menghindari Fatal Error pada 'date'
    while read -r acc; do
        [ -z "$acc" ] && continue
        user=$(echo "$acc" | jq -r '.user')
        exp=$(echo "$acc" | jq -r '.expired')
        
        # Cek validitas format tanggal
        exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ]; then
            if [ "$today" -ge "$exp_ts" ]; then
                # Eksekusi Hapus
                jq --arg u "$user" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
                jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
                
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Terhapus: $user" >> "$LOG_FILE"
                send_tg "<b>⚠️ AKUN EXPIRED TERHAPUS</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>$user</code>%0A<b>Tgl Exp:</b> <code>$exp</code>%0A━━━━━━━━━━━━━━"
                changed=true
            fi
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)

    [ "$changed" = true ] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
}

list_accounts() {
    clear
    echo "===================================="
    echo "       DAFTAR AKUN ZIVPN"
    echo "===================================="
    printf "%-18s %-12s %-10s\n" "USER" "EXP" "STATUS"
    echo "------------------------------------"
    today=$(date +%s)
    while read -r line; do
        [ -z "$line" ] && continue
        u=$(echo "$line" | cut -d' ' -f1)
        e=$(echo "$line" | cut -d' ' -f2)
        exp_ts=$(date -d "$e" +%s 2>/dev/null)
        status="Aktif"
        [ "$today" -ge "$exp_ts" ] && status="Expired"
        printf "%-18s %-12s %-10s\n" "$u" "$e" "$status"
    done < <(jq -r '.accounts[] | "\(.user) \(.expired)"' "$META_FILE" 2>/dev/null)
    echo "===================================="
    read -rp "Tekan Enter..." enter
}

add_account() {
    read -rp "Password/User: " new_user
    [ -z "$new_user" ] && return
    read -rp "Masa Aktif (Hari): " days
    [[ ! "$days" =~ ^[0-9]+$ ]] && days=30
    exp_date=$(date -d "+$days days" +%Y-%m-%d)
    
    jq --arg u "$new_user" '.auth.config += [$u]' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
    jq --arg u "$new_user" --arg e "$exp_date" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
    
    systemctl restart "$SERVICE_NAME"
    send_tg "<b>✅ AKUN BARU</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>$new_user</code>%0A<b>Exp:</b> <code>$exp_date</code>%0A━━━━━━━━━━━━━━"
    echo "Berhasil ditambahkan."
    sleep 2
}

delete_account() {
    read -rp "User yang ingin dihapus: " del_user
    [ -z "$del_user" ] && return
    jq --arg u "$del_user" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "$CONFIG_FILE"
    jq --arg u "$del_user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "$META_FILE"
    systemctl restart "$SERVICE_NAME"
    echo "User $del_user dihapus."
    sleep 2
}

# LOGIKA EKSEKUSI
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
            echo "================================"
            echo "   ZIVPN UDP MANAGER"
            echo "================================"
            echo "1. Lihat Akun"
            echo "2. Tambah Akun"
            echo "3. Hapus Akun"
            echo "4. Lihat Log"
            echo "0. Keluar"
            echo "================================"
            read -rp "Pilih: " opt
            case $opt in
                1) list_accounts ;;
                2) add_account ;;
                3) delete_account ;;
                4) [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" || echo "Belum ada log."; read -rp "Enter..." ;;
                0) exit 0 ;;
                *) continue ;;
            esac
        done
        ;;
esac
EOF

# 3. Shortcut & Permission
chmod +x "$MANAGER_SCRIPT"
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
echo "    ZIVPN MANAGER BERHASIL DI INSTALL"
echo "=========================================="
echo " Auto Expired : Aktif (Tiap 00:00)"
echo " Command      : zivpn"
echo "=========================================="
