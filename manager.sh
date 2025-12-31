#!/bin/bash
# ============================
# ZIVPN Manager Full + Telegram Backup
# Final Version (No Color)
# Shortcut: zivpn
# Author: Zee
# ============================

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

# 1. Persiapan Direktori & File
mkdir -p /etc/zivpn
[ ! -f "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
[ ! -f "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"
touch "$LOG_FILE"

# 2. Menulis Script Manager Utama
cat <<EOF > "$MANAGER_SCRIPT"
#!/bin/bash

CONFIG_FILE="$CONFIG_FILE"
META_FILE="$META_FILE"
SERVICE_NAME="$SERVICE_NAME"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
LOG_FILE="$LOG_FILE"

send_tg() {
    local MSG=\$1
    curl -s -X POST "https://api.telegram.org/bot\$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="\$TG_CHAT_ID" -d parse_mode="HTML" --data-urlencode text="\$MSG" >/dev/null
}

sync_accounts() {
    for pass in \$(jq -r ".auth.config[]" "\$CONFIG_FILE" 2>/dev/null); do
        exists=\$(jq -r --arg u "\$pass" ".accounts[] | select(.user==\\\$u) | .user" "\$META_FILE")
        if [ -z "\$exists" ]; then
            jq --arg user "\$pass" --arg exp "2099-12-31" '.accounts += [{"user":\$user,"expired":\$exp}]' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
        fi
    done
}

auto_remove_expired() {
    today=\$(date +%s)
    changed=false
    
    users_to_remove=\$(jq -r --arg today "\$today" '.accounts[] | select((.expired | strptime("%Y-%m-%d") | mktime) <= (\$today | tonumber)) | .user' "\$META_FILE" 2>/dev/null)

    for user in \$users_to_remove; do
        jq --arg u "\$user" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"
        jq --arg u "\$user" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
        
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - Terhapus otomatis: \$user" >> "\$LOG_FILE"
        send_tg "<b>⚠️ AKUN EXPIRED TERHAPUS (AUTO)</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>\$user</code>%0A<b>Waktu:</b> \$(date '+%H:%M:%S')%0A━━━━━━━━━━━━━━"
        changed=true
    done

    if [ "\$changed" = true ]; then
        systemctl restart "\$SERVICE_NAME" >/dev/null 2>&1
    fi
}

list_accounts() {
    clear
    echo "=== DAFTAR AKUN ZIVPN ==="
    today=\$(date +%s)
    printf "%-20s %-15s %-10s\n" "USER/PASS" "EXP DATE" "STATUS"
    echo "----------------------------------------------"
    jq -r '.accounts[] | "\(.user) \(.expired)"' "\$META_FILE" | while read -r u e; do
        exp_ts=\$(date -d "\$e" +%s 2>/dev/null)
        status="Aktif"
        [ "\$today" -ge "\$exp_ts" ] && status="Expired"
        printf "%-20s %-15s %-10s\n" "\$u" "\$e" "\$status"
    done
    read -rp "Tekan Enter untuk kembali..." enter
}

add_account() {
    read -rp "User/Password Baru: " new_pass
    [ -z "\$new_pass" ] && return
    
    exists=\$(jq -r --arg u "\$new_pass" ".auth.config[] | select(.==\\\$u)" "\$CONFIG_FILE")
    if [ ! -z "\$exists" ]; then
        echo "Error: User sudah ada!"
        sleep 2 && return
    fi

    read -rp "Masa Aktif (hari): " days
    [[ ! "\$days" =~ ^[0-9]+$ ]] && days=30
    exp_date=\$(date -d "+\$days days" +%Y-%m-%d)

    jq --arg pass "\$new_pass" '.auth.config += [\$pass]' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"
    jq --arg user "\$new_pass" --arg exp "\$exp_date" '.accounts += [{"user":\$user,"expired":\$exp}]' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"

    systemctl restart "\$SERVICE_NAME"
    
    MSG="<b>✅ AKUN BERHASIL DIBUAT</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>\$new_pass</code>%0A<b>Exp:</b> <code>\$exp_date</code>%0A━━━━━━━━━━━━━━"
    send_tg "\$MSG"
    echo "Akun \$new_pass berhasil ditambahkan!"
    sleep 2
}

delete_account() {
    read -rp "User yang ingin dihapus: " del_pass
    jq --arg u "\$del_pass" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"
    jq --arg u "\$del_pass" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
    systemctl restart "\$SERVICE_NAME"
    echo "Akun \$del_pass dihapus."
    sleep 2
}

case "\$1" in
    cron)
        sync_accounts
        auto_remove_expired
        ;;
    *)
        while true; do
            clear
            sync_accounts
            auto_remove_expired
            echo "===================================="
            echo "     ZIVPN UDP ACCOUNT MANAGER"
            echo "===================================="
            echo "1) Lihat Semua Akun"
            echo "2) Tambah Akun Baru"
            echo "3) Hapus Akun Manual"
            echo "4) Cek Log Expired"
            echo "0) Keluar"
            echo "===================================="
            read -rp "Pilih: " choice
            case \$choice in
                1) list_accounts ;;
                2) add_account ;;
                3) delete_account ;;
                4) tail -n 20 "\$LOG_FILE"; read -rp "Enter..." ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac
EOF

# 3. Membuat Shortcut Command
cat <<EOF > "$SHORTCUT"
#!/bin/bash
sudo bash $MANAGER_SCRIPT
EOF

chmod +x "$MANAGER_SCRIPT" "$SHORTCUT"

# 4. PASANG CRON JOB (Set ke 00:00)
(crontab -l 2>/dev/null | grep -v "$MANAGER_SCRIPT cron") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * $MANAGER_SCRIPT cron") | crontab -

clear
echo "=========================================="
echo "      INSTALASI SELESAI & AKTIF"
echo "=========================================="
echo " Auto Expired: SETIAP JAM 00:00"
echo " Log Expired : $LOG_FILE"
echo " Command     : zivpn"
echo "=========================================="
