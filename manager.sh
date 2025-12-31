#!/bin/bash

# --- PRE-INSTALLATION ---
apt-get update -qq && apt-get install iptables-persistent jq vnstat curl wget sudo -y -qq

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
[ ! -f "$TG_CONF" ] && touch "$TG_CONF"

# --- MENULIS SCRIPT MANAGER ---
cat <<'EOF' > "/usr/local/bin/zivpn-manager.sh"
#!/bin/bash

# Load Data Telegram
TG_CONF="/etc/zivpn/telegram.conf"
[ -f "$TG_CONF" ] && source "$TG_CONF"

# Path Konfigurasi
CONFIG_FILE="/etc/zivpn/config.json"
META_FILE="/etc/zivpn/accounts_meta.json"
SERVICE_NAME="zivpn.service"
MANAGER_PATH="/usr/local/bin/zivpn-manager.sh"

# Warna Harmony V17
C='\e[1;36m'; G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; B='\e[1;34m'; NC='\e[0m'

# --- FUNGSI AUTO-DELETE ---
sync_and_clean() {
    local today=$(date +%s)
    local changed=false
    local all_pass=$(jq -r '.auth.config[]' "$CONFIG_FILE" 2>/dev/null)
    for pass in $all_pass; do
        [ -z "$pass" ] || [ "$pass" == "null" ] && continue
        local exists=$(jq -r --arg u "$pass" '.accounts[] | select(.user==$u) | .user' "$META_FILE" 2>/dev/null)
        if [ -z "$exists" ]; then
            jq --arg u "$pass" --arg e "2099-12-31" '.accounts += [{"user":$u,"expired":$e}]' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
        fi
    done
    while read -r acc; do
        [ -z "$acc" ] && continue
        local user=$(echo "$acc" | jq -r '.user')
        local exp=$(echo "$acc" | jq -r '.expired')
        local exp_ts=$(date -d "$exp" +%s 2>/dev/null)
        if [ $? -eq 0 ] && [ "$today" -ge "$exp_ts" ]; then
            jq --arg u "$user" '.auth.config |= map(select(. != $u))' "$CONFIG_FILE" > /tmp/c.tmp && mv /tmp/c.tmp "$CONFIG_FILE"
            jq --arg u "$user" '.accounts |= map(select(.user != $u))' "$META_FILE" > /tmp/m.tmp && mv /tmp/m.tmp "$META_FILE"
            changed=true
        fi
    done < <(jq -c '.accounts[]' "$META_FILE" 2>/dev/null)
    [ "$changed" = true ] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1
}

# --- FUNGSI HEADER ---
draw_header() {
    clear
    local IP=$(curl -s ifconfig.me)
    local IF=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    local BW=$(vnstat -i "$IF" --json 2>/dev/null)
    local T_D=$(date +%-d); local T_M=$(date +%-m); local T_Y=$(date +%Y)
    local RX=$(echo "$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .rx // 0" 2>/dev/null)
    local TX=$(echo "$BW" | jq -r ".interfaces[0].traffic.day[] | select(.date.year == $T_Y and .date.month == $T_M and .date.day == $T_D) | .tx // 0" 2>/dev/null)
    local BD=$(awk -v b="$RX" 'BEGIN {printf "%.2f MB", b/1
