#!/bin/bash
##############################################################################
# ⚡ LIGHTNING VPS — One-Command Installer
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/kumarxbarsha1278-pixel/final/main/install.sh)
##############################################################################

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

REPO_URL="https://github.com/kumarxbarsha1278-pixel/final.git"
REPO_BRANCH="main"
INSTALL_DIR="/root/lightning"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║      ⚡ LIGHTNING VPS — AUTO INSTALLER                  ║"
echo "║      Repo: kumarxbarsha1278-pixel/final                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

[ "$EUID" -eq 0 ] || err "Root se run karo: sudo bash install.sh"

info "System packages install..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    redis-server curl wget git \
    ufw sqlite3 zstd \
    > /dev/null 2>&1
log "Packages ready"

info "Repo clone ho raha hai..."
if [ -d "$INSTALL_DIR/.git" ]; then
    warn "Already cloned — updating..."
    cd "$INSTALL_DIR"
    git pull origin "$REPO_BRANCH" || warn "Pull failed (continuing)"
else
    rm -rf "$INSTALL_DIR"
    git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
log "Repo ready at $INSTALL_DIR"

if [ ! -f "$INSTALL_DIR/deploy.sh" ]; then
    err "deploy.sh repo me nahi mila!"
fi
chmod +x "$INSTALL_DIR/deploy.sh"

info "Deploy script chal raha hai (2 minute)..."
echo ""
bash "$INSTALL_DIR/deploy.sh"

info "Auto-update service setup..."
cat > /etc/systemd/system/lightning-autoupdate.service << 'EOF'
[Unit]
Description=Lightning Auto Git Update
After=network.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/root/lightning
ExecStart=/root/lightning/update.sh
EOF

cat > /etc/systemd/system/lightning-autoupdate.timer << 'EOF'
[Unit]
Description=Lightning Auto Update Timer
Requires=lightning-autoupdate.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=lightning-autoupdate.service

[Install]
WantedBy=timers.target
EOF

cat > "$INSTALL_DIR/update.sh" << 'EOF'
#!/bin/bash
cd /root/lightning
BEFORE=$(git rev-parse HEAD)
git pull --quiet origin main 2>/dev/null
AFTER=$(git rev-parse HEAD)
if [ "$BEFORE" != "$AFTER" ]; then
    echo "🔄 Update detected — restarting services..."
    systemctl restart lightning-api lightning-bot lightning-release
fi
EOF

chmod +x "$INSTALL_DIR/update.sh"
systemctl daemon-reload
systemctl enable --now lightning-autoupdate.timer > /dev/null 2>&1
log "Auto-update enabled"

sleep 3

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║              ✅  ALL DONE! 🎉                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  📊 Services:"
systemctl is-active lightning-api > /dev/null && echo "    ✅ API :5000" || echo "    ❌ API"
systemctl is-active lightning-release > /dev/null && echo "    ✅ Release Worker" || echo "    ❌ Release"
systemctl is-active lightning-bot > /dev/null && echo "    ✅ Telegram Bot" || echo "    ❌ Bot"
systemctl is-active redis-server > /dev/null && echo "    ✅ Redis" || echo "    ❌ Redis"
echo ""
echo "  🌐 APK Endpoint: http://$(hostname -I | awk '{print $1}'):5000"
echo "  📱 API Key:      RAGEBITE_SECRET_2026_CHANGE_ME"
echo ""
echo "  🔧 Commands:"
echo "     systemctl status lightning-api"
echo "     systemctl restart lightning-api lightning-bot lightning-release"
echo "     tail -f /root/lightning/lightning.log"
echo ""
echo "  🧪 Test: curl http://localhost:5000/api/health"
echo ""
