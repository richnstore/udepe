#!/bin/bash

clear
echo "=================================================="
echo "      ZIVPN MANAGER INSTALLER"
echo "    BY RICH NARENDRA X GEMINI AI"
echo "=================================================="
echo ""

# URL GitHub Raw milik Anda
GITHUB_RAW_URL="https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh"

# Input Telegram (Hanya diminta saat instalasi pertama)
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
echo "[-] Mengoptimalkan Sistem & Kernel..."

# 1. Install Dependencies
apt-get update && apt-get install iptables-persistent jq vnstat curl wget sudo -y

# 2. Kernel Tuning (UDP Optimization & IP Forwarding)
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
sed -i '/net.core.rmem/d' /etc/sysctl.conf
sed -i '/net.core.wmem/d' /etc/sysctl.conf
sed -i '/net.ipv4.udp/d' /etc/sysctl.conf

cat <<EOF >> /etc/sysctl.conf
net.ipv4.ip_forward = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_fastopen = 3
EOF
sysctl -p
netfilter-persistent save

# --- KONFIGURASI PATH ---
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
MANAGER_SCRIPT="/usr/local/bin/zivpn-manager.sh"
SHORTCUT="/usr/local/bin/menu"

# 3. Inisialisasi Database
mkdir -p /etc/zivpn
[ ! -s "$CONFIG_FILE" ] && echo '{"auth":{"config":[]}, "listen":":5667"}' > "$CONFIG_FILE"
[ ! -s "$META_FILE" ] && echo '{"accounts":[]}' > "$META_FILE"

# 4. MENULIS SCRIPT MANAGER UTAMA (Upload isi ini ke GitHub)
cat <<EOF > "$MANAGER_SCRIPT"
#!/bin/bash

# --- IDENTITAS BOT (JANGAN DIHAPUS, AKAN DIISI OTOMATIS OLEH UPDATE) ---
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
GITHUB_URL="$GITHUB_RAW_URL"

CONFIG_FILE="$CONFIG_FILE"
META_FILE="$META_FILE"
SERVICE_NAME="$SERVICE_NAME"
MANAGER_SCRIPT="/usr/local/bin/zivpn-manager.sh"

# --- FUNGSI ESTETIK STATUS ---
system_status() {
    clear
    local OS_NAME=\$(grep -P '^PRETTY_NAME' /etc/os-release | cut -d'"' -f2)
    local CPU_USAGE=\$(top -bn1 | grep "Cpu(s)" | awk '{print \$2 + \$4}')
    local MEM_TOTAL=\$(free -h | awk '/Mem:/ {print \$2}')
    local MEM_USED=\$(free -h | awk '/Mem:/ {print \$3}')
    local DISK_TOTAL=\$(df -h / | awk '/\// {print \$2}' | tail -n 1)
    local DISK_USED=\$(df -h / | awk '/\// {print \$3}' | tail -n 1)
    local UPTIME=\$(uptime -p | sed 's/up //')

    echo -e " \e[1;36m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    echo -e " \e[1;36m┃\e[0m \e[1;33m          SYSTEM VPS INFORMATION         \e[0m \e[1;36m┃\e[0m"
    echo -e " \e[1;36m┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫\e[0m"
    printf " \e[1;36m┃\e[0m  %-15s : %-23s \e[1;36m┃\e[0m\n" "OS" "\$OS_NAME"
    printf " \e[1;36m┃\e[0m  %-15s : %-23s \e[1;36m┃\e[0m\n" "Uptime" "\$UPTIME"
    printf " \e[1;36m┃\e[0m  %-15s : %-23s \e[1;36m┃\e[0m\n" "CPU Usage" "\$CPU_USAGE %"
    printf " \e[1;36m┃\e[0m  %-15s : %-23s \e[1;36m┃\e[0m\n" "RAM (U/T)" "\$MEM_USED / \$MEM_TOTAL"
    printf " \e[1;36m┃\e[0m  %-15s : %-23s \e[1;36m┃\e[0m\n" "Disk (U/T)" "\$DISK_USED / \$DISK_TOTAL"
    echo -e " \e[1;36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
    echo ""
    read -rp " Tekan [Enter] untuk kembali..."
}

# --- FUNGSI UPDATE SMART ---
update_script() {
    echo -e "Checking for updates..."
    wget -q -O /tmp/zivpn-new.sh "\$GITHUB_URL"
    if [ \$? -eq 0 ]; then
        # SUNTIKKAN TOKEN & ID LAMA KE FILE BARU
        sed -i "s|TG_BOT_TOKEN=\".*\"|TG_BOT_TOKEN=\"\$TG_BOT_TOKEN\"|g" /tmp/zivpn-new.sh
        sed -i "s|TG_CHAT_ID=\".*\"|TG_CHAT_ID=\"\$TG_CHAT_ID\"|g" /tmp/zivpn-new.sh
        
        mv /tmp/zivpn-new.sh "\$MANAGER_SCRIPT"
        chmod +x "\$MANAGER_SCRIPT"
        echo -e "✅ Update Berhasil!"
        sleep 1
        exit 0
    else
        echo -e "❌ Gagal update."; sleep 2
    fi
}

# --- FUNGSI PENUNJANG ---
send_tg() {
    curl -s -X POST "https://api.telegram.org/bot\$TG_BOT_TOKEN/sendMessage" -d chat_id="\$TG_CHAT_ID" -d parse_mode="HTML" --data-urlencode text="\$1" >/dev/null
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
            send_tg "<b>⚠️ EXPIRED:</b> <code>\$user</code> dihapus."
            changed=true
        fi
    done < <(jq -c '.accounts[]' "\$META_FILE" 2>/dev/null)
    [ "\$changed" = true ] && systemctl restart "\$SERVICE_NAME" >/dev/null 2>&1
}

# --- MENU UTAMA ---
case "\$1" in
    cron) sync_accounts; auto_remove_expired ;;
    *)
        while true; do
            clear
            sync_accounts; auto_remove_expired
            VPS_IP=\$(curl -s ifconfig.me)
            echo -e "\e[1;32m================================================\e[0m"
            echo -e "\e[1;33m           ZIVPN UDP ACCOUNT MANAGER            \e[0m"
            echo -e "\e[1;32m================================================\e[0m"
            echo -e " IP VPS       : \${VPS_IP}"
            echo -e "\e[1;32m================================================\e[0m"
            echo -e " 1) Lihat Akun       5) Status System"
            echo -e " 2) Tambah Akun      6) Backup Telegram"
            echo -e " 3) Hapus Akun       7) Restore Akun"
            echo -e " 4) Restart Layanan  8) \e[1;33mUpdate Script\e[0m"
            echo -e " 0) Keluar"
            echo -e "\e[1;32m================================================\e[0m"
            read -rp " Pilih Menu: " choice
            case \$choice in
                1) clear; printf "%-18s %-12s\n" "USER" "EXP"; echo "------------------------------"; jq -r '.accounts[] | "\(.user) \(.expired)"' "\$META_FILE" | while read -r u e; do printf "%-18s %-12s\n" "\$u" "\$e"; done; read -rp "Enter..." ;;
                2) read -rp "User: " n; read -rp "Hari: " d; exp=\$(date -d "+\$d days" +%Y-%m-%d); jq --arg u "\$n" '.auth.config += [\$u]' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$n" --arg e "\$exp" '.accounts += [{"user":\$u,"expired":\$e}]' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME"; send_tg "✅ Akun Baru: \$n (Exp: \$exp)";;
                3) read -rp "User: " d; jq --arg u "\$d" '.auth.config |= map(select(. != \$u))' "\$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "\$CONFIG_FILE"; jq --arg u "\$d" '.accounts |= map(select(.user != \$u))' "\$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "\$META_FILE"; systemctl restart "\$SERVICE_NAME"; echo "Dihapus."; sleep 1 ;;
                4) systemctl restart "\$SERVICE_NAME"; echo "Restarted."; sleep 1 ;;
                5) system_status ;;
                6) cp "\$CONFIG_FILE" /tmp/c.json; curl -s -F chat_id="\$TG_CHAT_ID" -F document=@/tmp/c.json https://api.telegram.org/bot\$TG_BOT_TOKEN/sendDocument > /dev/null; echo "Sent!"; sleep 1 ;;
                7) # Fungsi Restore ;;
                8) update_script ;;
                0) exit 0 ;;
            esac
        done
        ;;
esac
EOF

# 5. Finalize
chmod +x "$MANAGER_SCRIPT"
echo "sudo bash $MANAGER_SCRIPT" > "$SHORTCUT"
chmod +x "$SHORTCUT"

# 6. Setup Cron Job
(crontab -l 2>/dev/null | grep -v "$MANAGER_SCRIPT cron") | crontab -
(crontab -l 2>/dev/null; echo "0 0 * * * $MANAGER_SCRIPT cron") | crontab -

clear
echo "=================================================="
echo "      INSTALASI SELESAI "
echo "=================================================="
