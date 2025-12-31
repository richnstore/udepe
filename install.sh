#!/bin/bash

echo "===================================="
echo "   ZIVPN FULL AUTO INSTALLER"
echo "   Repo: richnstore/udepe"
echo "===================================="

# ==============================
# STEP 1: INSTALL UDP ZIVPN
# ==============================
echo "🚀 Menginstall UDP ZIVPN..."
bash <(curl -fsSL https://raw.githubusercontent.com/powermx/zivpn/main/ziv2.sh)
# ==============================
# STEP 2: CEK & INSTALL DEPENDENCY
# ==============================
echo ""
echo "🔍 Mengecek dependency..."

missing=0
for pkg in jq curl vnstat; do
    if ! command -v $pkg >/dev/null 2>&1; then
        echo "❌ $pkg belum terinstall"
        missing=1
    else
        echo "✅ $pkg sudah ada"
    fi
done

if [ "$missing" -eq 1 ]; then
    echo ""
    echo "🔧 Menginstall dependency..."
    apt update
    apt install -y jq curl vnstat
    systemctl enable vnstat
    systemctl start vnstat
else
    echo ""
    echo "✅ Semua dependency sudah lengkap"
fi

# ==============================
# STEP 3: INSTALL MANAGER (DARI REPO KAMU)
# ==============================
echo ""
echo "🚀 Menginstall ZIVPN Manager..."

wget -O /tmp/zivpn-manager.sh https://raw.githubusercontent.com/richnstore/udepe/main/manager.sh
chmod +x /tmp/zivpn-manager.sh
bash /tmp/zivpn-manager.sh

# ==============================
# STEP 4: AUTO OPEN MANAGER
# ==============================
echo ""
echo "===================================="
echo "✅ SEMUA INSTALASI SELESAI!"
echo "✅ Membuka ZIVPN Manager..."
echo "===================================="
sleep 2
zivpn
