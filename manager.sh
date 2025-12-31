#!/bin/bash

clear
echo "=========================================="
echo "      ZIVPN MANAGER INSTALLER    "
echo "    BY RICH NARENDRA X GEMINI AI    "
echo "=========================================="
echo ""

# URL GitHub kamu untuk Update
GITHUB_RAW_URL="https://raw.githubusercontent.com/username/repo/main/zivpn-manager.sh"

# Input Telegram (Looping jika kosong)
while true; do
    read -p " 🔑 Masukkan Token Bot Telegram: " TG_BOT_TOKEN
    [ ! -z "$TG_BOT_TOKEN" ] && break
    echo " ❌ Token wajib diisi!"
done

while true; do
    read -p " 🆔 Masukkan Chat ID Telegram: " TG_CHAT_ID
    [ ! -z "$TG_CHAT_ID" ] && break
    echo " ❌ Chat ID wajib diisi!"
done

echo ""
echo "[-] Mengonfigurasi Sistem & Kernel..."

# --- TAMBAHAN: IP FORWARD & IPTABLES PERSISTENT ---
# Install tool penyimpan iptables
sudo apt-get update
sudo apt-get install iptables-persistent -y

# Aktifkan IP Forwarding secara permanen
if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
fi
sudo sysctl -p

# Simpan aturan yang saat ini aktif ke dalam file konfigurasi
sudo netfilter-persistent save

# --- KONFIGURASI PATH ---
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
MANAGER_SCRIPT="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/menu"
LOG_FILE="/var/log/zivpn-expired.log"

# 1. Inisialisasi Database
mkdir -p /etc/zivpn
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"
touch "$LOG_FILE"

# 2. Menulis Script Manager
cat <<EOF > "$MANAGER_SCRIPT"
#!/bin/bash

# Variabel disuntikkan dari installer
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
GITHUB_URL="$GITHUB_RAW_URL"

CONFIG_FILE="$CONFIG_FILE"
META_FILE="$META_FILE"
SERVICE_NAME="$SERVICE_NAME"
LOG_FILE="$LOG_FILE"

# --- FUNGSI HELPER ---
convert_bw() {
    local bytes=\$1
    if [ "\$bytes" -gt 1073741824 ]; then
        awk -v b="\$bytes" 'BEGIN {printf "%.2f GiB", b/1024/1024/1024}'
    else
        awk -v b="\$bytes" 'BEGIN {printf "%.2f MiB", b/1024/1024}'
    fi
}

send_tg() {
    local MSG=\$1
    curl -s -X POST "https://api.telegram.org/bot\$TG_BOT_TOKEN/sendMessage" \\
        -d chat_id="\$TG_CHAT_ID" -d parse_mode="HTML" --data-urlencode text="\$MSG" >/dev/null
}

sync_accounts() {
    local all_pass=\$(jq -r '.auth.config[]' "\$CONFIG_FILE" 2>/dev/null)
    for pass in \$all_pass; do
        [ -z "\$pass" ] || [ "\$pass" == "null" ] && continue
        local exists=\$(jq -r --arg u "\$pass" '.accounts[] | select(.user==\$u) | .user' "\$META_FILE" 2>/dev/null)
        if [ -z "\$exists" ]; then
            jq --arg u "\$pass" --arg e "2099-12-31" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
        fi
    done
}

auto_remove_expired() {
    local today=\$(date +%s)
    local changed=false
    while read -r acc; do
        [ -z "\$acc" ] && continue
        local user=\$(echo "\$acc" | jq -r '.user')
        local exp=\$(echo "\$acc" | jq -r '.expired')
        local exp_ts=\$(date -d "\$exp" +%s 2>/dev/null)
        if [ \$? -eq 0 ] && [ "\$today" -ge "\$exp_ts" ]; then
            jq --arg u "\$user" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/cfg.tmp && mv /tmp/cfg.tmp "\$CONFIG_FILE"
            jq --arg u "\$user" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/meta.tmp && mv /tmp/meta.tmp "\$META_FILE"
            echo "\$(date '+%Y-%m-%d %H:%M:%S') - Expired: \$user" >> "\$LOG_FILE"
            send_tg "<b>⚠️ AKUN EXPIRED TERHAPUS</b>%0A━━━━━━━━━━━━━━%0A<b>User:</b> <code>\$user</code>%0A━━━━━━━━━━━━━━"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "\$META_FILE" 2>/dev/null)
    [ "\$changed" = true ] && systemctl restart "\$SERVICE_NAME" >/dev/null 2>&1
}

restore_accounts() {
    clear
    echo "=== RESTORE AKUN ZIVPN ==="
    echo "1) Restore dari Backup Lokal"
    echo "2) Restore via Telegram"
    echo "0) Kembali"
    read -rp " Pilih: " rest_opt
    case \$rest_opt in
        1)
            if [ -f "/etc/zivpn/backup_config.json" ]; then
                cp /etc/zivpn/backup_config.json "\$CONFIG_FILE"
                cp /etc/zivpn/backup_meta.json "\$META_FILE"
                systemctl restart "\$SERVICE_NAME"
                echo "✅ Restore Lokal Berhasil!"; sleep 2
            fi ;;
        2)
            echo "Menghubungi Bot Telegram..."
            UPDATES=\$(curl -s "https://api.telegram.org/bot\$TG_BOT_TOKEN/getUpdates")
            FILE_ID=\$(echo "\$UPDATES" | jq -r '.result | map(select(.message.document != null)) | last | .message.document.file_id // empty')
            FILE_NAME=\$(echo "\$UPDATES" | jq -r '.result | map(select(.message.document != null)) | last | .message.document.file_name // empty')
            if [ ! -z "\$FILE_ID" ] && [ "\$FILE_ID" != "null" ]; then
                FILE_PATH=\$(curl -s "https://api.telegram.org/bot\$TG_BOT_TOKEN/getFile?file_id=\$FILE_ID" | jq -r '.result.file_path')
                curl -s -o "/tmp/\$FILE_NAME" "https://api.telegram.org/file/bot\$TG_BOT_TOKEN/\$FILE_PATH"
                [[ "\$FILE_NAME" == *"config.json"* ]] && cp "/tmp/\$FILE_NAME" "\$CONFIG_FILE"
                [[ "\$FILE_NAME" == *"meta.json"* ]] && cp "/tmp/\$FILE_NAME" "\$META_FILE"
                systemctl restart "\$SERVICE_NAME"
                echo "✅ Restore \$FILE_NAME Berhasil!"; sleep 2
            fi ;;
    esac
}

update_script() {
    echo "Checking updates..."
    wget -q -O /tmp/zivpn-new.sh "\$GITHUB_URL"
    if [ \$? -eq 0 ]; then
        sed -i "s|TG_BOT_TOKEN=.*|TG_BOT_TOKEN=\"\$TG_BOT_TOKEN\"|g" /tmp/zivpn-new.sh
        sed -i "s|TG_CHAT_ID=.*|TG_CHAT_ID=\"\$TG_CHAT_ID\"|g" /tmp/zivpn-new.sh
        mv /tmp/zivpn-new.sh "$MANAGER_SCRIPT"
        chmod +x "$MANAGER_SCRIPT"
        echo "✅ Update Success!"; sleep 1
        exit 0
    fi
}

# --- MENU UTAMA ---
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
            
            VPS_IP=\$(curl -s ifconfig.me || echo "Error")
            ISP_NAME=\$(curl -s https://ipinfo.io/org | cut -d' ' -f2- || echo "Error")
            NET_IFACE=\$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
            
            BW_JSON=\$(vnstat -i "\$NET_IFACE" --json 2>/dev/null)
            T_Y=\$(date +%Y); T_M=\$(date +%-m); T_D=\$(date +%-d)
            BW_D_RAW=\$(echo "\$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .rx // 0" 2>/dev/null)
            BW_U_RAW=\$(echo "\$BW_JSON" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == \$T_Y and .date.month == \$T_M and .date.day == \$T_D) | .tx // 0" 2>/dev/null)
            BW_D=\$(convert_bw "\${BW_D_RAW:-0}")
            BW_U=\$(convert_bw "\${BW_U_RAW:-0}")

            echo "================================================"
            echo "           ZIVPN UDP ACCOUNT MANAGER"
            echo "================================================"
            echo " IP VPS       : \${VPS_IP}"
            echo " ISP          : \${ISP_NAME}"
            echo " Hari Ini     : ↓ \$BW_D | ↑ \$BW_U"
            echo "================================================"
            echo " 1) Lihat Semua Akun"
            echo " 2) Tambah Akun Baru"
            echo " 3) Hapus Akun"
            echo " 4) Restart Layanan"
            echo " 5) Status System VPS"
            echo " 6) Backup Ke Telegram"
            echo " 7) Restore Akun (Lokal/Telegram)"
            echo " 8) Update Script (GitHub)"
            echo " 0) Keluar"
            echo "================================================"
            read -rp " Pilih Menu: " choice

            case \$choice in
                1) clear; printf "%-18s %-12s %-10s\n" "USER" "EXP" "STATUS"; echo "------------------------------------"; jq -r '.accounts[] | "\(.user) \(.expired)"' "\$META_FILE" | while read -r u e; do t=\$(date +%s); x=\$(date -d "\$e" +%s); s="Aktif"; [ "\$t" -ge "\$x" ] && s="Expired"; printf "%-18s %-12s %-10s\n" "\$u" "\$e" "\$s"; done; read -rp "Enter..." ;;
                2) read -rp "User: " n; read -rp "Hari: " d; [[ ! "\$d" =~ ^[0-9]+$ ]] && d=30; exp=\$(date -d "+\$d days" +%Y-%m-%d); jq --arg u "\$n" '.auth.config += [\$u]' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$n" --arg e "\$exp" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME"; send_tg "✅ <b>AKUN BARU</b>%0AUser: <code>\$n</code>%0AExp: <code>\$exp</code>";;
                3) read -rp "User: " d; jq --arg u "\$d" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$d" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME"; echo "Dihapus."; sleep 1 ;;
                4) systemctl restart "\$SERVICE_NAME"; echo "Restarted."; sleep 1 ;;
                5) clear; uptime; free -h; df -h /; read -rp "Enter..." ;;
                6) cp "\$CONFIG_FILE" /etc/zivpn/backup_config.json; cp "\$META_FILE" /etc/zivpn/backup_meta.json; curl -s -F chat_id="\$TG_CHAT_ID" -F document=@/etc/zivpn/backup_config.json https://api.telegram.org/bot\$TG_BOT_TOKEN/sendDocument > /dev/null; curl -s -F chat_id="\$TG_CHAT_ID" -F document=@/etc/zivpn/backup_meta.json https://api.telegram.org/bot\$TG_BOT_TOKEN/sendDocument > /dev/null; echo "Backup terkirim!"; sleep 1 ;;
                7) restore_accounts ;;
                8) update_script ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac
EOF

# 3. Finalize
chmod +x "$MANAGER_SCRIPT"
echo "sudo bash $MANAGER_SCRIPT" > "$SHORTCUT"
chmod +x "$SHORTCUT"

# 4. Cron Job
(crontab -l 2>/dev/null | grep -v "$MANAGER_SCRIPT cron") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * $MANAGER_SCRIPT cron") | crontab -

clear
echo "✅ Instalasi Berhasil! Ketik 'menu' sekarang."
