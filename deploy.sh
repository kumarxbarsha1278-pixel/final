#!/bin/bash
##############################################################################
# ⚡ LIGHTNING VPS — 8-Core Auto Deploy (Port 5000 ONLY)
##############################################################################
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[i]${NC} $1"; }

INSTALL_DIR="/root/lightning"
cd "$INSTALL_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║   ⚡ LIGHTNING VPS — 8-CORE (Port 5000 ONLY)            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

[ "$EUID" -eq 0 ] || err "Root chahiye"
CORES=$(nproc)
info "CPU cores: $CORES"

# ═══ 1. System packages ═══
info "System packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    redis-server curl wget git \
    ufw sqlite3 zstd > /dev/null 2>&1
log "Packages ready"

# ═══ 2. Python venv ═══
info "Python venv..."
python3 -m venv "$INSTALL_DIR/venv"
source "$INSTALL_DIR/venv/bin/activate"
pip install --quiet --upgrade pip wheel
pip install --quiet \
    pyTelegramBotAPI==4.14.0 \
    flask==3.0.0 \
    flask-cors==4.0.0 \
    requests==2.31.0 \
    gunicorn==21.2.0 \
    redis==5.0.1
log "Python packages installed"

# ═══ 3. Files already in repo, just verify ═══
for f in lightning_vps_fast.py gunicorn_conf.py release_worker.py bot_worker.py; do
    if [ ! -f "$INSTALL_DIR/$f" ]; then
        err "Missing file: $f (repo me upload karo)"
    fi
done
chmod +x "$INSTALL_DIR"/*.py
log "All files verified"

# ═══ 4. Systemd services ═══
info "Systemd services..."

cat > /etc/systemd/system/lightning-api.service << 'SVCEOF'
[Unit]
Description=Lightning API (Port 5000)
After=network.target redis-server.service
Wants=redis-server.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/lightning
Environment="GUNICORN_WORKER=1"
Environment="PYTHONUNBUFFERED=1"
ExecStart=/root/lightning/venv/bin/gunicorn -c /root/lightning/gunicorn_conf.py lightning_vps_fast:app
Restart=always
RestartSec=3
LimitNOFILE=65535
KillMode=mixed
TimeoutStopSec=20
StandardOutput=append:/root/lightning/api.out
StandardError=append:/root/lightning/api.err

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/lightning-release.service << 'SVCEOF'
[Unit]
Description=Lightning Auto-Release Worker
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/lightning
Environment="PYTHONUNBUFFERED=1"
ExecStart=/root/lightning/venv/bin/python3 /root/lightning/release_worker.py
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=append:/root/lightning/release.out
StandardError=append:/root/lightning/release.err

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/systemd/system/lightning-bot.service << 'SVCEOF'
[Unit]
Description=Lightning Telegram Bot
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/lightning
Environment="PYTHONUNBUFFERED=1"
ExecStart=/root/lightning/venv/bin/python3 /root/lightning/bot_worker.py
Restart=always
RestartSec=5
LimitNOFILE=65535
StandardOutput=append:/root/lightning/bot.out
StandardError=append:/root/lightning/bot.err

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
log "Services created"

# ═══ 5. Redis ═══
info "Redis..."
systemctl enable redis-server > /dev/null 2>&1
systemctl restart redis-server
sleep 1
log "Redis running"

# ═══ 6. Init DB ═══
info "DB init..."
cd "$INSTALL_DIR"
source venv/bin/activate
GUNICORN_WORKER=1 python3 -c "from lightning_vps_fast import init_db; init_db()" 2>&1 | tail -3
log "DB ready"

# ═══ 7. Start services ═══
info "Starting services..."
systemctl enable lightning-api lightning-release lightning-bot > /dev/null 2>&1
systemctl restart lightning-api
sleep 2
systemctl restart lightning-release
systemctl restart lightning-bot
sleep 3
log "Services started"

# ═══ 8. Firewall ═══
info "Firewall..."
ufw --force enable > /dev/null 2>&1
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 5000/tcp > /dev/null 2>&1
log "Firewall: 22, 5000"

# ═══ 9. Health ═══
sleep 2
curl -s http://localhost:5000/api/health > /dev/null && log "API health OK" || warn "API not responding yet"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         ✅  DEPLOYMENT COMPLETE (Port 5000)              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  🌐 APK: http://$(hostname -I | awk '{print $1}'):5000"
echo ""
