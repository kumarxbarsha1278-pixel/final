cat > /root/lightning/deploy.sh << 'DEPLOY_EOF'
#!/bin/bash
##############################################################################
# ⚡ LIGHTNING VPS — 8-Core Auto Deploy (5000-Only)
# APK sirf port 5000 ko hit karega — Nginx bypass, direct Gunicorn
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

[ "$EUID" -eq 0 ] || err "Root se run karo: sudo bash deploy.sh"
CORES=$(nproc)
info "CPU cores: $CORES"

# ═══════════════════════════════════════════════════════════════════
# 1. System packages
# ═══════════════════════════════════════════════════════════════════
info "System packages install..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 python3-pip python3-venv \
    redis-server curl wget git \
    ufw sqlite3 zstd \
    > /dev/null 2>&1
log "Packages ready"

# ═══════════════════════════════════════════════════════════════════
# 2. Python venv
# ═══════════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════════
# 3. Main app file (lightning_vps_fast.py)
# ═══════════════════════════════════════════════════════════════════
info "Main app file..."

cat > "$INSTALL_DIR/lightning_vps_fast.py" << 'PYEOF'
#!/usr/bin/env python3
"""
⚡ LIGHTNING VPS — 8-CORE (Port 5000 Only)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Multi-worker safe | Redis cache | Write-safe SQLite
"""

import os, re, sys, queue, sqlite3, threading, time, random, string
import logging, shutil, atexit, signal, json
from logging.handlers import RotatingFileHandler
from datetime import datetime, timedelta, timezone

import telebot
from flask import Flask, request, jsonify
from flask_cors import CORS
import requests

# ═══ CONFIG ═══
KEY_BOT_TOKEN = "8823908635:AAGZN9cD6feaNAuhF1WwepeZ7Vg1IIQSKGg"
DD_BOT_TOKEN  = "8650600804:AAFw-AuiLMtbUUHIbqwdPzVeOG8s11yfdA8"
OWNER_ID = 6321758394
API_SECRET = "RAGEBITE_SECRET_2026_CHANGE_ME"

BYPASS_PACKAGES = set()

_DEFAULT_APPS = {
    "com.ragebite.app":   {"name": "RageBite",  "prefix": "RAGEBITE", "default_rate": 10, "default_slots": 4},
    "com.ragebite.one":   {"name": "Lightning", "prefix": "LIGHTNING","default_rate": 10, "default_slots": 4},
    "com.ragebite.two":   {"name": "XSilent",   "prefix": "XSILENT",  "default_rate": 10, "default_slots": 4},
    "com.ragebite.three": {"name": "VIP Mods",  "prefix": "VIPMODS",  "default_rate": 10, "default_slots": 4},
    "com.ragebite.four":  {"name": "Ninja",     "prefix": "NINJA",    "default_rate": 10, "default_slots": 4},
    "com.ragebite.five":  {"name": "XSilent2",  "prefix": "XSILENT2", "default_rate": 10, "default_slots": 3},
}

MAX_KEY_DEVICES = 20
MAX_BULK = 100
MAX_APPS = 100
MIN_ATTACK_TIME = 10
MAX_ATTACK_TIME = 300

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_NAME = os.path.join(BASE_DIR, 'lightning.db')
LOG_FILE = os.path.join(BASE_DIR, 'lightning.log')
BACKUP_DIR = os.path.join(BASE_DIR, 'backups')

IST = timezone(timedelta(hours=5, minutes=30))
STATUS_ACTIVE = "ACTIVE"
STATUS_DELETED = "DELETED"
STATUS_DISABLED = "DISABLED"

# ═══ LOGGING ═══
def setup_logging():
    os.makedirs(BACKUP_DIR, exist_ok=True)
    logger = logging.getLogger("lightning")
    if logger.handlers: return logger
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter('%(asctime)s | PID:%(process)d | %(levelname)s | %(message)s')
    try:
        fh = RotatingFileHandler(LOG_FILE, maxBytes=20*1024*1024, backupCount=5, encoding='utf-8')
        fh.setFormatter(fmt)
        logger.addHandler(fh)
    except Exception: pass
    ch = logging.StreamHandler(sys.stdout)
    ch.setFormatter(fmt)
    logger.addHandler(ch)
    return logger

log = setup_logging()

# ═══ REDIS ═══
try:
    import redis
    redis_client = redis.Redis(host='127.0.0.1', port=6379, db=0,
                               decode_responses=True,
                               socket_connect_timeout=2,
                               socket_timeout=2,
                               max_connections=100)
    redis_client.ping()
    REDIS_OK = True
    log.info("✅ Redis connected")
except Exception as e:
    REDIS_OK = False
    redis_client = None
    log.warning(f"⚠️ Redis unavailable: {e}")

def cache_get(key):
    if not REDIS_OK: return None
    try:
        v = redis_client.get(key)
        return json.loads(v) if v else None
    except Exception: return None

def cache_set(key, value, ttl=600):
    if not REDIS_OK: return
    try: redis_client.setex(key, ttl, json.dumps(value))
    except Exception: pass

def cache_del(key):
    if not REDIS_OK: return
    try: redis_client.delete(key)
    except Exception: pass

# ═══ DB ═══
_thread_local = threading.local()
db_write_lock = threading.RLock()
_cache_lock = threading.RLock()

def get_conn():
    conn = getattr(_thread_local, 'conn', None)
    if conn is None:
        conn = sqlite3.connect(DB_NAME, check_same_thread=False, timeout=60)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        conn.execute("PRAGMA busy_timeout=60000")
        conn.execute("PRAGMA cache_size=-256000")
        conn.execute("PRAGMA temp_store=MEMORY")
        conn.execute("PRAGMA mmap_size=536870912")
        conn.execute("PRAGMA wal_autocheckpoint=1000")
        conn.execute("PRAGMA foreign_keys=ON")
        _thread_local.conn = conn
    return conn

def close_conn():
    conn = getattr(_thread_local, 'conn', None)
    if conn:
        try: conn.close()
        except Exception: pass
        _thread_local.conn = None

# ═══ APP CACHE ═══
_apps_cache = {}
_name_to_pkg_cache = {}

def reload_apps_cache():
    global _apps_cache, _name_to_pkg_cache
    conn = get_conn(); c = conn.cursor()
    c.execute("SELECT package, name, prefix, default_rate, default_slots FROM apps ORDER BY name")
    rows = c.fetchall()
    new_apps, new_names = {}, {}
    for pkg, name, prefix, rate, slots in rows:
        new_apps[pkg] = {"name": name, "prefix": prefix,
                         "default_rate": float(rate), "default_slots": int(slots)}
        new_names[name.lower().replace(" ", "")] = pkg
    with _cache_lock:
        _apps_cache = new_apps
        _name_to_pkg_cache = new_names

def APP_IDS():
    with _cache_lock: return list(_apps_cache.keys())

def resolve_app(name_or_pkg):
    if not name_or_pkg: return None
    s = str(name_or_pkg).strip().lower()
    if not s: return None
    with _cache_lock:
        if s in _apps_cache: return s
        key = s.replace(" ", "").replace("_", "").replace("-", "")
        if key in _name_to_pkg_cache: return _name_to_pkg_cache[key]
        candidates = [s]
        if s.endswith('.apk'): candidates += [s[:-4] + '.app', s[:-4]]
        elif s.endswith('.app'): candidates += [s[:-4] + '.apk', s[:-4]]
        else: candidates += [s + '.app', s + '.apk']
        extra = [c[4:] if c.startswith('com.') else 'com.' + c for c in candidates]
        candidates.extend(extra)
        for c in candidates:
            if c in _apps_cache: return c
    return None

def app_display(pkg):
    with _cache_lock: return _apps_cache.get(pkg, {}).get("name", "?")

def app_prefix(pkg):
    with _cache_lock: return _apps_cache.get(pkg, {}).get("prefix", "KEY")

def _app_default_rate(pkg):
    with _cache_lock: return _apps_cache.get(pkg, {}).get("default_rate", 10.0)

def _app_default_slots(pkg):
    with _cache_lock: return _apps_cache.get(pkg, {}).get("default_slots", 4)

def fmt_rate(rate):
    if rate is None: return "0"
    try: rate = float(rate)
    except (TypeError, ValueError): return "0"
    return str(int(rate)) if rate == int(rate) else f"{rate:g}"

# ═══ SETTINGS ═══
_settings_local = {}
_settings_lock = threading.RLock()

def get_setting(key, default=""):
    cached = cache_get(f"setting:{key}")
    if cached is not None: return cached
    with _settings_lock:
        if key in _settings_local: return _settings_local[key]
    conn = get_conn(); c = conn.cursor()
    c.execute("SELECT value FROM settings WHERE key=?", (key,))
    row = c.fetchone()
    val = row[0] if row else default
    with _settings_lock: _settings_local[key] = val
    cache_set(f"setting:{key}", val, 600)
    return val

def set_setting(key, value):
    conn = get_conn(); c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, str(value)))
    conn.commit()
    with _settings_lock: _settings_local[key] = str(value)
    cache_set(f"setting:{key}", str(value), 600)

def get_app_rate(pkg):
    val = get_setting(f"rate:{pkg}", None)
    if val is not None:
        try: return float(val)
        except (TypeError, ValueError): pass
    return _app_default_rate(pkg)

def set_app_rate(pkg, coins): set_setting(f"rate:{pkg}", str(coins))

def get_app_slots(pkg):
    val = get_setting(f"slots:{pkg}", None)
    if val is not None:
        try: return max(1, int(val))
        except (TypeError, ValueError): pass
    return _app_default_slots(pkg)

def set_app_slots(pkg, count):
    count = max(1, min(50, int(count)))
    conn = get_conn(); c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (f"slots:{pkg}", str(count)))
    c.execute('''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                 time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0
                 WHERE app_id=? AND slot_id > ? AND is_active=1''', (pkg, count))
    c.execute("DELETE FROM slots WHERE app_id=? AND slot_id > ?", (pkg, count))
    c.execute("SELECT slot_id FROM slots WHERE app_id=? ORDER BY slot_id", (pkg,))
    existing = {r[0] for r in c.fetchall()}
    for i in range(1, count + 1):
        if i not in existing:
            c.execute("INSERT OR IGNORE INTO slots (app_id, slot_id, is_active) VALUES (?, ?, 0)", (pkg, i))
    conn.commit()
    with _settings_lock: _settings_local[f"slots:{pkg}"] = str(count)
    cache_set(f"setting:slots:{pkg}", str(count), 600)
    return count

def app_slots(pkg): return get_app_slots(pkg)

def calc_price(dur, rate, dev=1, cnt=1):
    return max(1, int(round(rate * (dur / 3600.0) * dev * cnt)))

def parse_duration(s):
    if not s: return None, None
    s = str(s).strip().lower()
    m = re.match(r'^(\d+)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$', s)
    if not m: return None, None
    n = int(m.group(1)); u = m.group(2)
    if u.startswith('m'): sec = n * 60; d = f"{n} min"
    elif u.startswith('h'): sec = n * 3600; d = f"{n} hr"
    else: sec = n * 86400; d = f"{n} day" + ("s" if n != 1 else "")
    if sec < 60 or sec > 3650 * 86400: return None, None
    return sec, d

def fmt_remaining(sec):
    if sec <= 0: return "Expired"
    d = sec // 86400; h = (sec % 86400) // 3600
    m = (sec % 3600) // 60; s = sec % 60
    p = []
    if d: p.append(f"{d}d")
    if h: p.append(f"{h}h")
    if m: p.append(f"{m}m")
    if s and not d: p.append(f"{s}s")
    return " ".join(p) if p else "0s"

def progress_bar(busy, total, w=10):
    if total <= 0: return "░" * w
    f = max(0, min(w, int(round((busy / total) * w))))
    return "█" * f + "░" * (w - f)

def now_ist_str(): return datetime.now(IST).strftime('%Y-%m-%d %H:%M:%S')

# ═══ VALIDATE ═══
def validate_package(pkg):
    if not pkg or len(pkg) < 3 or len(pkg) > 100: return False
    return bool(re.match(r'^[a-z][a-z0-9._]*$', pkg))

def validate_prefix(px):
    if not px or len(px) < 2 or len(px) > 16: return False
    return bool(re.match(r'^[A-Z][A-Z0-9]*$', px))

# ═══ APP CRUD ═══
def add_app_to_db(pkg, name, px, rate=10.0, slots=4):
    conn = get_conn(); c = conn.cursor()
    c.execute("BEGIN IMMEDIATE")
    c.execute("INSERT INTO apps (package, name, prefix, default_rate, default_slots, created_at) VALUES (?, ?, ?, ?, ?, ?)",
              (pkg, name, px, float(rate), int(slots), now_ist_str()))
    set_setting(f"rate:{pkg}", str(rate))
    set_setting(f"slots:{pkg}", str(slots))
    for i in range(1, int(slots) + 1):
        c.execute("INSERT OR IGNORE INTO slots (app_id, slot_id, is_active) VALUES (?, ?, 0)", (pkg, i))
    conn.commit()
    reload_apps_cache()

def remove_app_from_db(pkg):
    conn = get_conn(); c = conn.cursor()
    c.execute("BEGIN IMMEDIATE")
    c.execute("DELETE FROM key_devices WHERE key IN (SELECT key FROM keys WHERE app_id=?)", (pkg,))
    c.execute("DELETE FROM keys WHERE app_id=?", (pkg,))
    c.execute("DELETE FROM slots WHERE app_id=?", (pkg,))
    c.execute("DELETE FROM admins WHERE app_id=?", (pkg,))
    c.execute("DELETE FROM resellers WHERE app_id=?", (pkg,))
    c.execute("DELETE FROM settings WHERE key=? OR key=?", (f"rate:{pkg}", f"slots:{pkg}"))
    c.execute("DELETE FROM apps WHERE package=?", (pkg,))
    conn.commit()
    cache_del(f"setting:rate:{pkg}")
    cache_del(f"setting:slots:{pkg}")
    reload_apps_cache()

def list_all_apps():
    with _cache_lock: return [(pkg, dict(info)) for pkg, info in _apps_cache.items()]

def app_list_str():
    return " · ".join(info["name"] for _, info in list_all_apps())

# ═══ DB INIT ═══
def init_db():
    conn = get_conn(); c = conn.cursor()

    c.execute('''CREATE TABLE IF NOT EXISTS apps (
        package TEXT PRIMARY KEY, name TEXT NOT NULL, prefix TEXT NOT NULL,
        default_rate REAL DEFAULT 10, default_slots INTEGER DEFAULT 4, created_at TEXT)''')

    c.execute('''CREATE TABLE IF NOT EXISTS keys (
        key TEXT PRIMARY KEY, device_id TEXT, expiry TEXT, status TEXT DEFAULT 'ACTIVE',
        slot_count INTEGER DEFAULT 4, max_devices INTEGER DEFAULT 1, app_id TEXT,
        generated_by TEXT, created_at TEXT)''')

    c.execute('''CREATE TABLE IF NOT EXISTS key_devices (
        key TEXT, device_id TEXT, bound_at TEXT, PRIMARY KEY (key, device_id))''')

    c.execute('''CREATE TABLE IF NOT EXISTS slots (
        app_id TEXT, slot_id INTEGER, key TEXT, device_id TEXT, ip TEXT, port TEXT,
        time_sec INTEGER, start_time TEXT, end_time TEXT, is_active INTEGER DEFAULT 0,
        PRIMARY KEY (app_id, slot_id))''')

    c.execute('''CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)''')

    c.execute('''CREATE TABLE IF NOT EXISTS admins (
        telegram_id TEXT, app_id TEXT, added_at TEXT, PRIMARY KEY (telegram_id, app_id))''')

    c.execute('''CREATE TABLE IF NOT EXISTS resellers (
        telegram_id TEXT, app_id TEXT, balance INTEGER DEFAULT 0, added_at TEXT,
        PRIMARY KEY (telegram_id, app_id))''')

    c.execute('''CREATE TABLE IF NOT EXISTS admin_perms (
        telegram_id TEXT PRIMARY KEY, can_add_admin INTEGER DEFAULT 0)''')

    for idx in [
        "CREATE INDEX IF NOT EXISTS idx_keys_app ON keys(app_id)",
        "CREATE INDEX IF NOT EXISTS idx_keys_status ON keys(status)",
        "CREATE INDEX IF NOT EXISTS idx_keys_expiry ON keys(expiry)",
        "CREATE INDEX IF NOT EXISTS idx_keys_gen ON keys(generated_by)",
        "CREATE INDEX IF NOT EXISTS idx_keys_app_expiry ON keys(app_id, expiry)",
        "CREATE INDEX IF NOT EXISTS idx_slots_active ON slots(app_id, is_active)",
        "CREATE INDEX IF NOT EXISTS idx_slots_key ON slots(key)",
        "CREATE INDEX IF NOT EXISTS idx_key_devices_key ON key_devices(key)",
        "CREATE INDEX IF NOT EXISTS idx_admins_app ON admins(app_id)",
        "CREATE INDEX IF NOT EXISTS idx_resellers_app ON resellers(app_id)",
    ]: c.execute(idx)

    c.execute("PRAGMA table_info(keys)")
    if 'max_devices' not in [r[1] for r in c.fetchall()]:
        try: c.execute("ALTER TABLE keys ADD COLUMN max_devices INTEGER DEFAULT 1")
        except sqlite3.OperationalError: pass

    c.execute("INSERT OR IGNORE INTO settings (key, value) VALUES ('maintenance', 'off')")
    c.execute("INSERT OR IGNORE INTO settings (key, value) VALUES ('maintenance_started_at', '')")

    c.execute("SELECT COUNT(*) FROM apps")
    if c.fetchone()[0] == 0:
        for pkg, info in _DEFAULT_APPS.items():
            c.execute("INSERT OR IGNORE INTO apps (package, name, prefix, default_rate, default_slots, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                      (pkg, info["name"], info["prefix"], float(info.get("default_rate", 10)),
                       int(info.get("default_slots", 4)), now_ist_str()))

    c.execute("SELECT package, default_rate, default_slots FROM apps")
    for pkg, rate, slots in c.fetchall():
        c.execute("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)", (f"rate:{pkg}", str(rate)))
        c.execute("INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)", (f"slots:{pkg}", str(slots)))

    conn.commit()
    reload_apps_cache()
    for pkg in APP_IDS():
        set_app_slots(pkg, get_app_slots(pkg))
    log.info(f"✅ DB ready: {DB_NAME}")

# ═══ MAINTENANCE ═══
def get_maintenance(): return get_setting('maintenance', 'off')

def extend_all_keys(sec, app_id=None, gen_by=None):
    conn = get_conn(); c = conn.cursor()
    q = "UPDATE keys SET expiry = datetime(expiry, ?) WHERE status=? AND expiry > datetime('now')"
    p = [f"+{sec} seconds", STATUS_ACTIVE]
    if app_id: q += " AND app_id=?"; p.append(app_id)
    if gen_by: q += " AND generated_by=?"; p.append(str(gen_by))
    c.execute(q, p); n = c.rowcount; conn.commit()
    return n

def extend_active_slots(sec):
    conn = get_conn(); c = conn.cursor()
    c.execute("UPDATE slots SET end_time = datetime(end_time, ?) WHERE is_active=1", (f"+{sec} seconds",))
    conn.commit()

def set_maintenance(value):
    old = get_maintenance()
    if value == "on" and old != "on":
        set_setting('maintenance_started_at', now_ist_str())
        set_setting('maintenance', 'on')
        return None
    elif value == "off" and old == "on":
        st = get_setting('maintenance_started_at', '')
        frozen = 0
        if st:
            try:
                frozen = int((datetime.now() - datetime.strptime(st, '%Y-%m-%d %H:%M:%S')).total_seconds())
            except (ValueError, TypeError): frozen = 0
        if frozen > 0:
            extend_all_keys(frozen); extend_active_slots(frozen)
        set_setting('maintenance_started_at', '')
        set_setting('maintenance', 'off')
        return frozen
    set_setting('maintenance', value)
    return None

# ═══ ADMIN ═══
def add_admin(tid, app_id):
    conn = get_conn(); c = conn.cursor()
    c.execute('INSERT OR IGNORE INTO admins (telegram_id, app_id, added_at) VALUES (?, ?, ?)',
              (str(tid), app_id, now_ist_str()))
    conn.commit()

def remove_admin(tid):
    conn = get_conn(); c = conn.cursor()
    c.execute('DELETE FROM admin_perms WHERE telegram_id=?', (str(tid),))
    c.execute('DELETE FROM admins WHERE telegram_id=?', (str(tid),))
    conn.commit()

def get_admin_app(tid):
    conn = get_conn(); c = conn.cursor()
    c.execute('SELECT app_id FROM admins WHERE telegram_id=? LIMIT 1', (str(tid),))
    r = c.fetchone()
    return r[0] if r else None

def is_admin(tid): return get_admin_app(tid) is not None

def list_admins():
    conn = get_conn(); c = conn.cursor()
    c.execute('SELECT telegram_id, app_id FROM admins ORDER BY app_id')
    return c.fetchall()

def can_admin_add_admin(tid):
    conn = get_conn(); c = conn.cursor()
    c.execute("SELECT can_add_admin FROM admin_perms WHERE telegram_id=?", (str(tid),))
    r = c.fetchone()
    return bool(r and r[0] == 1)

def set_admin_add_permission(tid, val):
    conn = get_conn(); c = conn.cursor()
    c.execute("INSERT OR REPLACE INTO admin_perms (telegram_id, can_add_admin) VALUES (?, ?)",
              (str(tid), 1 if val else 0))
    conn.commit()

# ═══ RESELLER ═══
def add_reseller(tid, app_id, bal=0):
    conn = get_conn(); c = conn.cursor()
    c.execute('INSERT OR IGNORE INTO resellers (telegram_id, app_id, balance, added_at) VALUES (?, ?, ?, ?)',
              (str(tid), app_id, bal, now_ist_str()))
    conn.commit()

def remove_reseller(tid):
    conn = get_conn(); c = conn.cursor()
    c.execute('DELETE FROM resellers WHERE telegram_id=?', (str(tid),))
    conn.commit()

def get_reseller_app(tid):
    conn = get_conn(); c = conn.cursor()
    c.execute('SELECT app_id, balance FROM resellers WHERE telegram_id=? LIMIT 1', (str(tid),))
    r = c.fetchone()
    return r if r else (None, 0)

def is_reseller(tid): return get_reseller_app(tid)[0] is not None

def get_reseller_balance(tid, app_id):
    conn = get_conn(); c = conn.cursor()
    c.execute('SELECT balance FROM resellers WHERE telegram_id=? AND app_id=?', (str(tid), app_id))
    r = c.fetchone()
    return r[0] if r else 0

def add_reseller_balance(tid, app_id, amt):
    conn = get_conn(); c = conn.cursor()
    c.execute('UPDATE resellers SET balance = balance + ? WHERE telegram_id=? AND app_id=?',
              (amt, str(tid), app_id))
    conn.commit()
    return get_reseller_balance(tid, app_id)

def deduct_reseller_balance(tid, app_id, amt):
    conn = get_conn(); c = conn.cursor()
    c.execute('UPDATE resellers SET balance = balance - ? WHERE telegram_id=? AND app_id=? AND balance >= ?',
              (amt, str(tid), app_id, amt))
    conn.commit()
    if c.rowcount == 0:
        return False, get_reseller_balance(tid, app_id)
    return True, get_reseller_balance(tid, app_id)

def list_resellers(app_id):
    conn = get_conn(); c = conn.cursor()
    c.execute('SELECT telegram_id, balance FROM resellers WHERE app_id=? ORDER BY telegram_id', (app_id,))
    return c.fetchall()

# ═══ KEYS ═══
def generate_key(dur, app_id, gen_by, slot_count=None, max_dev=1):
    if slot_count is None: slot_count = get_app_slots(app_id)
    slot_count = max(1, min(get_app_slots(app_id), int(slot_count)))
    max_dev = max(1, min(MAX_KEY_DEVICES, int(max_dev)))
    px = app_prefix(app_id)
    if not px or px == "KEY": raise ValueError(f"Bad app: {app_id}")
    body = ''.join(random.choices(string.ascii_uppercase + string.digits, k=12))
    key = f"{px}-{body}"
    expiry = (datetime.now() + timedelta(seconds=dur)).strftime('%Y-%m-%d %H:%M:%S')
    conn = get_conn(); c = conn.cursor()
    c.execute('''INSERT INTO keys (key, device_id, expiry, status, slot_count, max_devices, app_id, generated_by, created_at)
                 VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?)''',
              (key, expiry, STATUS_ACTIVE, slot_count, max_dev, app_id, str(gen_by), now_ist_str()))
    conn.commit()
    return key, expiry, slot_count

def delete_key_soft(key):
    conn = get_conn(); c = conn.cursor()
    c.execute('UPDATE keys SET status = ? WHERE key = ?', (STATUS_DELETED, key))
    conn.commit()

def list_keys(app_id=None, gen_by=None, limit=20, inc_del=False):
    conn = get_conn(); c = conn.cursor()
    q = 'SELECT key, status, expiry, max_devices FROM keys WHERE 1=1'
    p = []
    if not inc_del: q += " AND status != ?"; p.append(STATUS_DELETED)
    if app_id: q += ' AND app_id=?'; p.append(app_id)
    if gen_by: q += ' AND generated_by=?'; p.append(str(gen_by))
    q += ' ORDER BY created_at DESC LIMIT ?'; p.append(limit)
    c.execute(q, p)
    return c.fetchall()

def get_key_info(key):
    conn = get_conn(); c = conn.cursor()
    c.execute('SELECT app_id, generated_by, expiry, status FROM keys WHERE key=?', (key,))
    return c.fetchone()

def verify_key_with_device(key, dev_id, app_id):
    with db_write_lock:
        conn = get_conn(); c = conn.cursor()
        c.execute('SELECT expiry, status, device_id, app_id, max_devices FROM keys WHERE key = ?', (key,))
        row = c.fetchone()
        if not row: return None, "NOT_FOUND", False
        expiry_str, status, existing_dev, key_app, max_dev = row
        if not key_app: return None, "INVALID_KEY_APP", False
        if key_app != app_id: return None, "WRONG_APP", False
        exp_prefix = app_prefix(app_id)
        if not exp_prefix or exp_prefix == "KEY": return None, "UNKNOWN_APP", False
        if not key.startswith(exp_prefix + "-"): return None, "PREFIX_MISMATCH", False
        if status == STATUS_DELETED: return None, "DELETED", False
        if status == STATUS_DISABLED: return None, "DISABLED", False
        try: expiry = datetime.strptime(expiry_str, '%Y-%m-%d %H:%M:%S')
        except (ValueError, TypeError): return None, "INVALID_EXPIRY", False
        if expiry < datetime.now():
            c.execute('DELETE FROM key_devices WHERE key=?', (key,))
            c.execute('DELETE FROM keys WHERE key=?', (key,))
            c.execute('''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                         time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0 WHERE key=?''', (key,))
            conn.commit()
            return None, "EXPIRED", False
        max_dev = max_dev or 1
        c.execute('SELECT COUNT(*) FROM key_devices WHERE key=?', (key,))
        dev_count = c.fetchone()[0]
        if dev_count == 0:
            c.execute('INSERT OR IGNORE INTO key_devices (key, device_id, bound_at) VALUES (?, ?, ?)',
                      (key, dev_id, now_ist_str()))
            c.execute('UPDATE keys SET device_id = ? WHERE key = ?', (dev_id, key))
            conn.commit()
            return int(expiry.timestamp() * 1000), "VALID", True
        c.execute('SELECT 1 FROM key_devices WHERE key=? AND device_id=?', (key, dev_id))
        if c.fetchone(): return int(expiry.timestamp() * 1000), "VALID", True
        if dev_count >= max_dev: return None, "DEVICE_LIMIT_REACHED", False
        c.execute('INSERT OR IGNORE INTO key_devices (key, device_id, bound_at) VALUES (?, ?, ?)',
                  (key, dev_id, now_ist_str()))
        conn.commit()
        return int(expiry.timestamp() * 1000), "VALID", True

def reset_key(key):
    with db_write_lock:
        conn = get_conn(); c = conn.cursor()
        c.execute('SELECT expiry FROM keys WHERE key=?', (key,))
        row = c.fetchone()
        if not row: return False
        try: expiry = datetime.strptime(row[0], '%Y-%m-%d %H:%M:%S')
        except (ValueError, TypeError): return False
        if expiry < datetime.now(): return False
        c.execute('UPDATE keys SET device_id=NULL WHERE key=?', (key,))
        c.execute('DELETE FROM key_devices WHERE key=?', (key,))
        c.execute('''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                     time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0 WHERE key=?''', (key,))
        conn.commit()
        return True

# ═══ SLOTS ═══
def allot_slot(dev_id, key, ip, port, time_sec, app_id):
    with db_write_lock:
        conn = get_conn(); c = conn.cursor()
        c.execute('SELECT slot_count FROM keys WHERE key = ?', (key,))
        row = c.fetchone()
        total_app = get_app_slots(app_id)
        key_slots = row[0] if (row and row[0]) else total_app
        key_slots = max(1, min(key_slots, total_app))
        c.execute('SELECT COUNT(*) FROM slots WHERE app_id=? AND key=? AND is_active=1', (app_id, key))
        if c.fetchone()[0] >= key_slots: return None, "KEY_SLOTS_FULL"
        c.execute('SELECT slot_id FROM slots WHERE app_id=? AND device_id=? AND is_active=1', (app_id, dev_id))
        if c.fetchone(): return None, "ALREADY_ACTIVE"
        c.execute('SELECT slot_id FROM slots WHERE app_id=? AND is_active=0 ORDER BY slot_id LIMIT 1', (app_id,))
        sr = c.fetchone()
        if not sr: return None, "APP_POOL_FULL"
        sid = sr[0]
        now = datetime.now(); end = now + timedelta(seconds=time_sec)
        c.execute('''UPDATE slots SET key=?, device_id=?, ip=?, port=?, time_sec=?, start_time=?, end_time=?, is_active=1
                     WHERE app_id=? AND slot_id=?''',
                  (key, dev_id, ip, port, time_sec,
                   now.strftime('%Y-%m-%d %H:%M:%S'), end.strftime('%Y-%m-%d %H:%M:%S'),
                   app_id, sid))
        conn.commit()
        return sid, "OK"

def count_busy_slots(app_id):
    conn = get_conn(); c = conn.cursor()
    c.execute('SELECT COUNT(*) FROM slots WHERE app_id=? AND is_active=1', (app_id,))
    return c.fetchone()[0]

def get_all_slots(app_id=None):
    conn = get_conn(); c = conn.cursor()
    if app_id:
        c.execute('SELECT slot_id, key, device_id, ip, port, time_sec, start_time, end_time, is_active FROM slots WHERE app_id=? ORDER BY slot_id', (app_id,))
    else:
        c.execute('SELECT app_id, slot_id, key, device_id, ip, port, time_sec, start_time, end_time, is_active FROM slots ORDER BY app_id, slot_id')
    return c.fetchall()

# ═══ RATE LIMIT ═══
def check_rate_limit(ident, max_req=60, window=60):
    if not ident: return True
    if not REDIS_OK:
        now = time.time()
        k = f"_rl_{ident}"
        lst = getattr(_thread_local, k, [])
        lst = [t for t in lst if now - t < window]
        if len(lst) >= max_req:
            setattr(_thread_local, k, lst)
            return False
        lst.append(now)
        setattr(_thread_local, k, lst)
        return True
    try:
        rkey = f"rl:{ident}"
        now_ts = time.time()
        pipe = redis_client.pipeline()
        pipe.zremrangebyscore(rkey, 0, now_ts - window)
        pipe.zadd(rkey, {str(now_ts): now_ts})
        pipe.zcard(rkey)
        pipe.expire(rkey, window)
        res = pipe.execute()
        return res[2] <= max_req
    except Exception: return True

# ═══ ASYNC DD ═══
_dd_queue = queue.Queue(maxsize=5000)

def _dd_worker(wid):
    url = f"https://api.telegram.org/bot{DD_BOT_TOKEN}/sendMessage"
    sess = requests.Session()
    adapter = requests.adapters.HTTPAdapter(pool_connections=10, pool_maxsize=20)
    sess.mount('https://', adapter)
    while True:
        try:
            text = _dd_queue.get()
            if text is None: break
            for attempt in range(3):
                try:
                    r = sess.post(url, json={"chat_id": OWNER_ID, "text": text}, timeout=10)
                    if r.ok and r.json().get("ok"): break
                except Exception as e:
                    log.error(f"DD W{wid} err: {e}")
                time.sleep(1.5)
            _dd_queue.task_done()
        except Exception as e:
            log.error(f"DD W{wid} fatal: {e}")
            time.sleep(2)

def notify_owner_dd(text):
    try: _dd_queue.put_nowait(text)
    except queue.Full: log.warning("DD queue full")

# ═══ STATS ═══
def get_db_stats():
    conn = get_conn(); c = conn.cursor()
    st = {}
    for pkg in APP_IDS():
        c.execute("SELECT COUNT(*), SUM(CASE WHEN status='ACTIVE' THEN 1 ELSE 0 END) FROM keys WHERE app_id=?", (pkg,))
        kt, ka = c.fetchone(); ka = ka or 0; kt = kt or 0
        c.execute("SELECT COUNT(*) FROM admins WHERE app_id=?", (pkg,)); ad = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM resellers WHERE app_id=?", (pkg,)); rs = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM slots WHERE app_id=? AND is_active=1", (pkg,)); bs = c.fetchone()[0]
        st[pkg] = {"name": app_display(pkg), "keys_total": kt, "keys_active": ka,
                   "admins": ad, "resellers": rs, "slots_total": get_app_slots(pkg),
                   "slots_busy": bs, "rate": get_app_rate(pkg)}
    return st

def get_all_keys_owner(app_id=None, gen_by=None):
    conn = get_conn(); c = conn.cursor()
    q = 'SELECT key, app_id, generated_by, status, expiry, max_devices, created_at FROM keys WHERE 1=1'
    p = []
    if app_id: q += ' AND app_id=?'; p.append(app_id)
    if gen_by: q += ' AND generated_by=?'; p.append(str(gen_by))
    q += ' ORDER BY created_at DESC LIMIT 100'
    c.execute(q, p)
    return c.fetchall()

def get_all_admins_grouped():
    conn = get_conn(); c = conn.cursor()
    c.execute('''SELECT a.telegram_id, a.app_id, COALESCE(p.can_add_admin, 0)
                 FROM admins a LEFT JOIN admin_perms p ON a.telegram_id = p.telegram_id
                 ORDER BY a.app_id, a.telegram_id''')
    return c.fetchall()

# ═══ FLASK API ═══
app = Flask(__name__)
CORS(app)

def check_auth(): return request.headers.get('X-API-KEY') == API_SECRET

def resolve_request_app(key, client_pkg):
    if not key: return None, "NO_KEY"
    if not client_pkg: return None, "NO_PACKAGE"
    cr = resolve_app(client_pkg)
    if not cr: return None, "UNKNOWN_PACKAGE"
    conn = get_conn(); c = conn.cursor()
    c.execute('''SELECT k.app_id, a.prefix FROM keys k JOIN apps a ON k.app_id = a.package WHERE k.key = ?''', (key,))
    row = c.fetchone()
    if not row: return None, "KEY_NOT_FOUND"
    key_app, exp_prefix = row
    if cr != key_app: return None, "WRONG_APP"
    if not key.startswith(exp_prefix + "-"): return None, "PREFIX_MISMATCH"
    return key_app, "OK"

def build_slots_response(app_id):
    if not app_id or app_id not in APP_IDS():
        return {"slots": [], "active": 0, "free": 0, "max": 0, "error": "UnknownPackage"}
    rows = get_all_slots(app_id)
    total = app_slots(app_id)
    now = datetime.now()
    slots = []
    for r in rows:
        sid, key, dev, ip, port, ts, st, et, ia = r
        if ia and et:
            try: rem = int((datetime.strptime(et, '%Y-%m-%d %H:%M:%S') - now).total_seconds())
            except (ValueError, TypeError): rem = 0
            slots.append({"slot": sid, "status": "BUSY", "remaining": max(0, rem)})
        else:
            slots.append({"slot": sid, "status": "FREE", "remaining": 0})
    active = sum(1 for s in slots if s["status"] == "BUSY")
    return {"app": app_display(app_id), "package": app_id, "slots": slots,
            "active": active, "free": total - active, "max": total}

@app.route('/api/health')
def api_health(): return jsonify({"status": "OK", "time": now_ist_str(), "pid": os.getpid()})

@app.route('/api/verify', methods=['POST'])
def api_verify():
    if not check_auth(): return jsonify({"error": "Unauthorized"}), 401
    if get_maintenance() == "on": return jsonify({"status": "INVALID", "reason": "MAINTENANCE"})
    d = request.json or {}
    key = (d.get('key') or '').upper().strip()
    dev = (d.get('device_id') or '').strip()
    pkg = (d.get('package') or '').strip()
    if not dev: return jsonify({"status": "INVALID", "reason": "NoDeviceID"})
    if not key: return jsonify({"status": "INVALID", "reason": "NoKey"})
    if not pkg: return jsonify({"status": "INVALID", "reason": "NoPackage"})
    pid, r = resolve_request_app(key, pkg)
    if pid is None: return jsonify({"status": "INVALID", "reason": r})
    exp, st, _ = verify_key_with_device(key, dev, pid)
    if st == "VALID": return jsonify({"status": "VALID", "expiry": exp})
    return jsonify({"status": "INVALID", "reason": st})

@app.route('/api/slots', methods=['GET', 'POST'])
@app.route('/api/slots/status', methods=['GET', 'POST'])
def api_slots():
    if get_maintenance() == "on": return jsonify({"maintenance": True, "status": "MAINTENANCE"})
    if request.method == 'POST':
        d = request.json or {}
        pkg = (d.get('package') or '').strip()
    else:
        pkg = (request.args.get('package') or '').strip()
    if not pkg:
        return jsonify({"slots": [], "active": 0, "free": 0, "max": 0, "error": "PackageRequired"}), 400
    aid = resolve_app(pkg)
    if not aid:
        return jsonify({"slots": [], "active": 0, "free": 0, "max": 0, "error": "UnknownPackage"}), 404
    return jsonify(build_slots_response(aid))

@app.route('/api/dd', methods=['POST'])
def api_dd():
    if not check_auth(): return jsonify({"status": "ERROR", "reason": "Unauthorized"}), 401
    if get_maintenance() == "on": return jsonify({"status": "ERROR", "reason": "MAINTENANCE"})
    cip = request.remote_addr or "unknown"
    if not check_rate_limit(cip): return jsonify({"status": "ERROR", "reason": "RateLimit"})
    d = request.json or {}
    dev = (d.get('device_id') or '').strip()
    key = (d.get('key') or '').upper().strip()
    ip = (d.get('ip') or '').strip()
    port = str(d.get('port') or '').strip()
    try: time_sec = int(d.get('time', 0))
    except (TypeError, ValueError): return jsonify({"status": "ERROR", "reason": "InvalidTime"})
    pkg = (d.get('package') or '').strip()
    if not dev: return jsonify({"status": "ERROR", "reason": "NoDeviceID"})
    if not key: return jsonify({"status": "ERROR", "reason": "NoKey"})
    if not ip or not port: return jsonify({"status": "ERROR", "reason": "MissingIPPort"})
    if time_sec < MIN_ATTACK_TIME or time_sec > MAX_ATTACK_TIME: return jsonify({"status": "ERROR", "reason": "InvalidTime"})
    if not pkg: return jsonify({"status": "ERROR", "reason": "NoPackage"})
    pid, r = resolve_request_app(key, pkg)
    if pid is None: return jsonify({"status": "ERROR", "reason": r})
    exp, st, _ = verify_key_with_device(key, dev, pid)
    if st != "VALID": return jsonify({"status": "ERROR", "reason": st})
    sid, sst = allot_slot(dev, key, ip, port, time_sec, pid)
    if sst == "ALREADY_ACTIVE": return jsonify({"status": "ERROR", "reason": "AlreadyActive"})
    if sst == "KEY_SLOTS_FULL": return jsonify({"status": "ERROR", "reason": "KeySlotsFull"})
    if sst == "APP_POOL_FULL" or sid is None: return jsonify({"status": "ERROR", "reason": "AllSlotsFull"})
    an = app_display(pid); total = app_slots(pid); busy = count_busy_slots(pid)
    details = (f"⚡ ATTACK REQUEST\n━━━━━━━━━━━━━━━━━━━━\n"
               f"🔑 Key: {key}\n📱 App: {an}\n🎯 Target: {ip}:{port}\n"
               f"⏱ Duration: {time_sec}s\n📌 Slot: {sid}/{total}\n"
               f"👤 Device: {dev[:16]}...\n🕐 {now_ist_str()}")
    notify_owner_dd(details)
    notify_owner_dd(f"/bgmi {ip} {port} {time_sec} {an}")
    log.info(f"✅ Attack: {ip}:{port} | Slot {sid} | {an} | {key}")
    end = datetime.now() + timedelta(seconds=time_sec)
    return jsonify({"status": "SLOT_ALLOTTED", "slot": sid, "app": an, "package": pid,
                    "ip": ip, "port": port, "time": time_sec,
                    "end_time": end.strftime('%H:%M:%S'),
                    "total_slots": total, "active_slots": busy, "free_slots": total - busy})

# ═══ BOT ═══
bot = telebot.TeleBot(KEY_BOT_TOKEN, threaded=True, num_threads=8)

def is_owner(uid): return str(uid) == str(OWNER_ID)

def get_role(uid):
    if is_owner(uid): return "owner"
    if is_admin(uid): return "admin"
    if is_reseller(uid): return "reseller"
    return "none"

@bot.message_handler(commands=['start'])
def cmd_start(message):
    uid = message.from_user.id
    role = get_role(uid)
    if role == "owner":
        mnt = "🔴 ON" if get_maintenance() == 'on' else "🟢 OFF"
        bot.reply_to(message, f"""⚡ LIGHTNING VPS · OWNER
👑 Welcome Boss!
🌐 Maintenance: {mnt}
📱 Apps ({len(APP_IDS())}): {app_list_str()}

🆕 APP: /addapp /delapp /apps
👑 ADMIN: /addadmn /removeadmin /adminlist
🔑 KEY: /genkey /bulkkeys /delkey /resetkey /extendkeys /listkeys
📊 SLOTS: /setslots /setrate /slotinfo
🛒 RESELLER: /addreseller /addbalance /resellerlist /dbstats
🔧 /maintenance on|off

⏱ 5m 30m 1h 2h 12h 1d 7d 30d
👥 1-{MAX_KEY_DEVICES}""")
    elif role == "admin":
        aa = get_admin_app(uid)
        bot.reply_to(message, f"⚡ ADMIN · {app_display(aa)}\n💰 {fmt_rate(get_app_rate(aa))}/hr | 📊 {get_app_slots(aa)} slots\n\n/genkey /bulkkeys /listkeys /slotinfo /delkey /resetkey")
    elif role == "reseller":
        ra, bal = get_reseller_app(uid)
        bot.reply_to(message, f"⚡ RESELLER · {app_display(ra)}\n💰 Balance: {bal}\n\n/genkey /bulkkeys /balance")
    else:
        bot.reply_to(message, "❌ Access denied.")

def _gen_reply(message, aid, dur, disp, dev, slots=None, count=1, bulk=False):
    uid = message.from_user.id
    unl = is_owner(uid) or is_admin(uid)
    rate = get_app_rate(aid)
    need = calc_price(dur, rate, dev, count)
    if not unl:
        if rate <= 0: bot.reply_to(message, "❌ Rate set nahi"); return
        bal = get_reseller_balance(uid, aid)
        if bal < need:
            bot.reply_to(message, f"❌ Need {need}, Have {bal}"); return
    nb = None
    if not unl and need > 0:
        ok, nb = deduct_reseller_balance(uid, aid, need)
        if not ok: bot.reply_to(message, f"❌ Deduct fail: {nb}"); return
    keys = []
    try:
        for _ in range(count):
            keys.append(generate_key(dur, aid, uid, slots, dev))
    except Exception as e:
        if not unl and need > 0: add_reseller_balance(uid, aid, need)
        bot.reply_to(message, f"❌ {e}"); return
    an = app_display(aid)
    if bulk:
        h = f"⚡ {count} KEYS · {an}\n⏱ {disp} · 👥 {dev}dev\n"
        if not unl: h += f"💰 -{need}\n"
        h += "\n" + "\n".join(f"`{k}`" for k, _, _ in keys)
        bot.reply_to(message, h, parse_mode='Markdown')
    else:
        k, exp, _ = keys[0]
        t = f"⚡ KEY\n`{k}`\n📱 {an}\n⏱ {disp}\n👥 {dev}dev\n📅 {exp}"
        if not unl: t += f"\n💰 -{need}"
        bot.reply_to(message, t, parse_mode='Markdown')

@bot.message_handler(commands=['genkey'])
def cmd_genkey(message):
    uid = message.from_user.id; c = message.text.split()
    if is_owner(uid):
        if len(c) < 3: bot.reply_to(message, f"❌ /genkey <time> <app> [dev]\n{app_list_str()}"); return
        ds, dd = parse_duration(c[1])
        if not ds: bot.reply_to(message, "❌ Bad time"); return
        aid = resolve_app(c[2])
        if not aid: bot.reply_to(message, "❌ Bad app"); return
        dev = 1
        if len(c) > 3:
            try: dev = int(c[3])
            except ValueError: bot.reply_to(message, "❌ Bad dev"); return
            if dev < 1 or dev > MAX_KEY_DEVICES: bot.reply_to(message, f"❌ 1-{MAX_KEY_DEVICES}"); return
        _gen_reply(message, aid, ds, dd, dev); return
    ma = get_admin_app(uid) or get_reseller_app(uid)[0]
    if not ma: bot.reply_to(message, "❌ Not authorized"); return
    if len(c) < 2: bot.reply_to(message, "❌ /genkey <time> [dev]"); return
    ds, dd = parse_duration(c[1])
    if not ds: bot.reply_to(message, "❌ Bad time"); return
    dev = 1
    if len(c) > 2:
        try: dev = int(c[2])
        except ValueError: bot.reply_to(message, "❌ Bad dev"); return
        if dev < 1 or dev > MAX_KEY_DEVICES: bot.reply_to(message, f"❌ 1-{MAX_KEY_DEVICES}"); return
    _gen_reply(message, ma, ds, dd, dev)

@bot.message_handler(commands=['bulkkeys'])
def cmd_bulkkeys(message):
    uid = message.from_user.id; c = message.text.split()
    if is_owner(uid):
        if len(c) < 4: bot.reply_to(message, "❌ /bulkkeys <count> <time> <app>"); return
        try: cnt = int(c[1])
        except ValueError: bot.reply_to(message, "❌ Bad count"); return
        if cnt < 1 or cnt > MAX_BULK: bot.reply_to(message, f"❌ 1-{MAX_BULK}"); return
        ds, dd = parse_duration(c[2])
        if not ds: bot.reply_to(message, "❌ Bad time"); return
        aid = resolve_app(c[3])
        if not aid: bot.reply_to(message, "❌ Bad app"); return
        _gen_reply(message, aid, ds, dd, 1, count=cnt, bulk=True); return
    ma = get_admin_app(uid) or get_reseller_app(uid)[0]
    if not ma: bot.reply_to(message, "❌ Not authorized"); return
    if len(c) < 3: bot.reply_to(message, "❌ /bulkkeys <count> <time>"); return
    try: cnt = int(c[1])
    except ValueError: bot.reply_to(message, "❌ Bad count"); return
    if cnt < 1 or cnt > MAX_BULK: bot.reply_to(message, f"❌ 1-{MAX_BULK}"); return
    ds, dd = parse_duration(c[2])
    if not ds: bot.reply_to(message, "❌ Bad time"); return
    _gen_reply(message, ma, ds, dd, 1, count=cnt, bulk=True)

@bot.message_handler(commands=['listkeys', 'keyslist'])
def cmd_listkeys(message):
    uid = message.from_user.id; c = message.text.split()
    if is_owner(uid):
        aid = resolve_app(c[1]) if len(c) > 1 else None
        rows = list_keys(aid)
    else:
        aid = get_admin_app(uid) or get_reseller_app(uid)[0]
        if not aid: bot.reply_to(message, "❌ Not authorized"); return
        rows = list_keys(aid, gen_by=uid if is_reseller(uid) else None)
    if not rows: bot.reply_to(message, "ℹ️ No keys"); return
    r = "🔑 KEYS\n\n"
    for k in rows[:15]: r += f"`{k[0]}`\n  {k[1]} · {k[2]} · {k[3]}dev\n\n"
    bot.reply_to(message, r, parse_mode='Markdown')

@bot.message_handler(commands=['delkey'])
def cmd_delkey(message):
    uid = message.from_user.id; c = message.text.split()
    if len(c) != 2: bot.reply_to(message, "❌ /delkey <key>"); return
    key = c[1].upper(); info = get_key_info(key)
    if not info: bot.reply_to(message, "❌ Not found"); return
    ka, kg = info[0], info[1]
    ok = is_owner(uid) or get_admin_app(uid) == ka
    if not ok:
        ra, _ = get_reseller_app(uid)
        if ra == ka and kg == str(uid): ok = True
    if not ok: bot.reply_to(message, "❌ Denied"); return
    delete_key_soft(key)
    bot.reply_to(message, f"✅ Deleted {key}")

@bot.message_handler(commands=['resetkey'])
def cmd_resetkey(message):
    uid = message.from_user.id; c = message.text.split()
    if len(c) != 2: bot.reply_to(message, "❌ /resetkey <key>"); return
    key = c[1].upper(); info = get_key_info(key)
    if not info: bot.reply_to(message, "❌ Not found"); return
    ka, kg = info[0], info[1]
    ok = is_owner(uid) or get_admin_app(uid) == ka
    if not ok:
        ra, _ = get_reseller_app(uid)
        if ra == ka and kg == str(uid): ok = True
    if not ok: bot.reply_to(message, "❌ Denied"); return
    if reset_key(key): bot.reply_to(message, f"✅ Reset {key}")
    else: bot.reply_to(message, "❌ Failed")

@bot.message_handler(commands=['slotinfo'])
def cmd_slotinfo(message):
    uid = message.from_user.id
    if is_owner(uid):
        r = "📊 SLOTS\n\n"
        for pkg in APP_IDS():
            b = count_busy_slots(pkg); t = app_slots(pkg)
            r += f"📱 {app_display(pkg)}\n   {progress_bar(b, t)} {b}/{t}\n   💰 {fmt_rate(get_app_rate(pkg))}/hr\n\n"
        bot.reply_to(message, r); return
    aa = get_admin_app(uid)
    if not aa: bot.reply_to(message, "❌ Admin only"); return
    b = count_busy_slots(aa); t = app_slots(aa)
    bot.reply_to(message, f"📊 {app_display(aa)}\n{progress_bar(b, t)} {b}/{t}")

@bot.message_handler(commands=['maintenance'])
def cmd_maintenance(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌ Owner only"); return
    c = message.text.split(); cur = get_maintenance()
    if len(c) < 2: bot.reply_to(message, f"🔧 {'ON' if cur == 'on' else 'OFF'}"); return
    a = c[1].lower()
    if a == "on": set_maintenance("on"); bot.reply_to(message, "🔧 ON")
    elif a == "off":
        f = set_maintenance("off")
        e = f"\n⏱ {fmt_remaining(f)}" if f else ""
        bot.reply_to(message, f"✅ OFF{e}")
    else: bot.reply_to(message, "❌ on|off")

@bot.message_handler(commands=['addapp'])
def cmd_addapp(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌ Owner"); return
    c = message.text.split()
    if len(c) < 4: bot.reply_to(message, "❌ /addapp <pkg> <name> <prefix> [rate] [slots]"); return
    pkg, name, px = c[1].lower(), c[2], c[3].upper()
    if not validate_package(pkg): bot.reply_to(message, "❌ Bad pkg"); return
    if not validate_prefix(px): bot.reply_to(message, "❌ Bad prefix"); return
    if pkg in APP_IDS(): bot.reply_to(message, "❌ Exists"); return
    rate, slots = 10.0, 4
    if len(c) > 4:
        try: rate = float(c[4])
        except ValueError: bot.reply_to(message, "❌ Bad rate"); return
    if len(c) > 5:
        try: slots = int(c[5])
        except ValueError: bot.reply_to(message, "❌ Bad slots"); return
    try: add_app_to_db(pkg, name, px, rate, slots)
    except Exception as e: bot.reply_to(message, f"❌ {e}"); return
    bot.reply_to(message, f"✅ Added {name}")

@bot.message_handler(commands=['delapp'])
def cmd_delapp(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌ Owner"); return
    c = message.text.split()
    if len(c) != 2: bot.reply_to(message, "❌ /delapp <app>"); return
    pkg = resolve_app(c[1])
    if not pkg: bot.reply_to(message, "❌ Not found"); return
    remove_app_from_db(pkg)
    bot.reply_to(message, f"✅ Deleted {pkg}")

@bot.message_handler(commands=['apps'])
def cmd_apps(message):
    uid = message.from_user.id
    if not is_owner(uid) and not is_admin(uid): bot.reply_to(message, "❌"); return
    r = "📱 APPS\n\n"
    for pkg, info in list_all_apps():
        r += f"{info['name']} · `{pkg}` · `{info['prefix']}`\n💰 {fmt_rate(get_app_rate(pkg))}/hr · 📊 {get_app_slots(pkg)}\n\n"
    bot.reply_to(message, r, parse_mode='Markdown')

@bot.message_handler(commands=['addadmn', 'addadmin'])
def cmd_add_admin(message):
    uid = message.from_user.id; is_o = is_owner(uid)
    if not is_o:
        if not is_admin(uid): bot.reply_to(message, "❌"); return
        if not can_admin_add_admin(uid): bot.reply_to(message, "❌ No perm"); return
    c = message.text.split()
    if is_o:
        if len(c) != 3: bot.reply_to(message, "❌ /addadmn <id> <app>"); return
        tid, aid = c[1], resolve_app(c[2])
        if not aid: bot.reply_to(message, "❌ Bad app"); return
    else:
        if len(c) != 2: bot.reply_to(message, "❌ /addadmn <id>"); return
        tid, aid = c[1], get_admin_app(uid)
    add_admin(tid, aid)
    bot.reply_to(message, f"✅ Admin added {tid} → {app_display(aid)}")

@bot.message_handler(commands=['removeadmin'])
def cmd_remove_admin(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌"); return
    c = message.text.split()
    if len(c) != 2: bot.reply_to(message, "❌ /removeadmin <id>"); return
    remove_admin(c[1]); bot.reply_to(message, f"✅ Removed {c[1]}")

@bot.message_handler(commands=['adminlist'])
def cmd_admin_list(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌"); return
    ad = list_admins()
    if not ad: bot.reply_to(message, "ℹ️ None"); return
    r = "👑 ADMINS\n\n"
    for tid, aid in ad: r += f"`{tid}` → {app_display(aid)}\n"
    bot.reply_to(message, r, parse_mode='Markdown')

@bot.message_handler(commands=['allowadminadd'])
def cmd_allow_admin_add(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌"); return
    c = message.text.split()
    if len(c) != 2: bot.reply_to(message, "❌ /allowadminadd <id>"); return
    set_admin_add_permission(c[1], True); bot.reply_to(message, f"✅ Allowed {c[1]}")

@bot.message_handler(commands=['revokeadminadd'])
def cmd_revoke_admin_add(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌"); return
    c = message.text.split()
    if len(c) != 2: bot.reply_to(message, "❌ /revokeadminadd <id>"); return
    set_admin_add_permission(c[1], False); bot.reply_to(message, f"✅ Revoked {c[1]}")

@bot.message_handler(commands=['setrate', 'setprice'])
def cmd_setrate(message):
    uid = message.from_user.id; aa = get_admin_app(uid); is_o = is_owner(uid)
    if not is_o and not aa: bot.reply_to(message, "❌"); return
    c = message.text.split()
    if is_o:
        if len(c) != 3: bot.reply_to(message, "❌ /setrate <app> <coins>"); return
        aid = resolve_app(c[1])
        if not aid: bot.reply_to(message, "❌ Bad app"); return
        try: coins = float(c[2])
        except ValueError: bot.reply_to(message, "❌ Bad rate"); return
    else:
        if len(c) != 2: bot.reply_to(message, "❌ /setrate <coins>"); return
        aid = aa
        try: coins = float(c[1])
        except ValueError: bot.reply_to(message, "❌ Bad rate"); return
    set_app_rate(aid, coins)
    bot.reply_to(message, f"✅ {app_display(aid)} → {fmt_rate(coins)}/hr")

@bot.message_handler(commands=['setslots'])
def cmd_setslots(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌"); return
    c = message.text.split()
    if len(c) != 3: bot.reply_to(message, "❌ /setslots <app> <count>"); return
    aid = resolve_app(c[1])
    if not aid: bot.reply_to(message, "❌ Bad app"); return
    try: cnt = int(c[2])
    except ValueError: bot.reply_to(message, "❌ Bad count"); return
    n = set_app_slots(aid, cnt)
    bot.reply_to(message, f"✅ {app_display(aid)} → {n} slots")

@bot.message_handler(commands=['extendkeys'])
def cmd_extendkeys(message):
    uid = message.from_user.id; is_o = is_owner(uid); aa = get_admin_app(uid)
    if not is_o and not aa: bot.reply_to(message, "❌"); return
    c = message.text.split()
    if is_o:
        if len(c) < 2: bot.reply_to(message, "❌ /extendkeys <time> [app] [admin]"); return
        ds, dd = parse_duration(c[1])
        if not ds: bot.reply_to(message, "❌ Bad time"); return
        aid = resolve_app(c[2]) if len(c) > 2 else None
        adf = c[3] if len(c) > 3 else None
    else:
        if len(c) < 2: bot.reply_to(message, "❌ /extendkeys <time> [admin]"); return
        ds, dd = parse_duration(c[1])
        if not ds: bot.reply_to(message, "❌ Bad time"); return
        aid, adf = aa, (c[2] if len(c) > 2 else None)
    n = extend_all_keys(ds, aid, adf)
    bot.reply_to(message, f"✅ Extended {n} keys by {dd}")

@bot.message_handler(commands=['addreseller'])
def cmd_add_reseller(message):
    uid = message.from_user.id; aa = get_admin_app(uid)
    if not aa and not is_owner(uid): bot.reply_to(message, "❌"); return
    c = message.text.split()
    if len(c) != 3: bot.reply_to(message, "❌ /addreseller <id> <coins>"); return
    try: rid, coins = c[1], int(c[2])
    except ValueError: bot.reply_to(message, "❌ Bad"); return
    aid = aa if aa else APP_IDS()[0]
    add_reseller(rid, aid, coins)
    bot.reply_to(message, f"✅ Reseller {rid} → {app_display(aid)}")

@bot.message_handler(commands=['removereseller'])
def cmd_remove_reseller(message):
    uid = message.from_user.id
    if not is_admin(uid) and not is_owner(uid): bot.reply_to(message, "❌"); return
    c = message.text.split()
    if len(c) != 2: bot.reply_to(message, "❌ /removereseller <id>"); return
    remove_reseller(c[1]); bot.reply_to(message, f"✅ Removed {c[1]}")

@bot.message_handler(commands=['resellerlist'])
def cmd_reseller_list(message):
    uid = message.from_user.id; aa = get_admin_app(uid)
    if not aa and not is_owner(uid): bot.reply_to(message, "❌"); return
    aid = aa if aa else APP_IDS()[0]
    rows = list_resellers(aid)
    if not rows: bot.reply_to(message, "ℹ️ None"); return
    r = f"🛒 RESELLERS · {app_display(aid)}\n\n"
    for tid, bal in rows: r += f"`{tid}` · 💰 `{bal}`\n"
    bot.reply_to(message, r, parse_mode='Markdown')

@bot.message_handler(commands=['addbalance'])
def cmd_add_balance(message):
    uid = message.from_user.id; aa = get_admin_app(uid); is_o = is_owner(uid)
    if not aa and not is_o: bot.reply_to(message, "❌"); return
    c = message.text.split()
    if is_o:
        if len(c) != 4: bot.reply_to(message, "❌ /addbalance <rid> <amt> <app>"); return
        try: rid, amt = c[1], int(c[2])
        except ValueError: bot.reply_to(message, "❌ Bad"); return
        aid = resolve_app(c[3])
        if not aid: bot.reply_to(message, "❌ Bad app"); return
    else:
        if len(c) != 3: bot.reply_to(message, "❌ /addbalance <rid> <amt>"); return
        try: rid, amt = c[1], int(c[2])
        except ValueError: bot.reply_to(message, "❌ Bad"); return
        aid = aa
    nb = add_reseller_balance(rid, aid, amt)
    bot.reply_to(message, f"✅ {rid} +{amt} → {nb}")

@bot.message_handler(commands=['removebalance'])
def cmd_remove_balance(message):
    uid = message.from_user.id; aa = get_admin_app(uid); is_o = is_owner(uid)
    if not aa and not is_o: bot.reply_to(message, "❌"); return
    c = message.text.split()
    if is_o:
        if len(c) != 4: bot.reply_to(message, "❌ /removebalance <rid> <amt> <app>"); return
        try: rid, amt = c[1], int(c[2])
        except ValueError: bot.reply_to(message, "❌ Bad"); return
        aid = resolve_app(c[3])
        if not aid: bot.reply_to(message, "❌ Bad app"); return
    else:
        if len(c) != 3: bot.reply_to(message, "❌ /removebalance <rid> <amt>"); return
        try: rid, amt = c[1], int(c[2])
        except ValueError: bot.reply_to(message, "❌ Bad"); return
        aid = aa
    ok, nb = deduct_reseller_balance(rid, aid, amt)
    if not ok: bot.reply_to(message, f"❌ Insufficient: {nb}"); return
    bot.reply_to(message, f"✅ {rid} -{amt} → {nb}")

@bot.message_handler(commands=['balance'])
def cmd_balance(message):
    uid = message.from_user.id
    ra, bal = get_reseller_app(uid)
    if not ra: bot.reply_to(message, "❌ Reseller only"); return
    bot.reply_to(message, f"💰 {app_display(ra)}\nBalance: {bal}\nRate: {fmt_rate(get_app_rate(ra))}/hr")

@bot.message_handler(commands=['dbstats'])
def cmd_dbstats(message):
    if not is_owner(message.from_user.id): bot.reply_to(message, "❌"); return
    s = get_db_stats()
    r = "📈 STATS\n\n"
    tk = ta = tad = trs = ts = tb = 0
    for pkg, x in s.items():
        r += f"📱 {x['name']}\n   🔑 {x['keys_active']}/{x['keys_total']}\n   👤 {x['admins']} · 🛒 {x['resellers']}\n   {progress_bar(x['slots_busy'], x['slots_total'])} {x['slots_busy']}/{x['slots_total']}\n\n"
        tk += x['keys_total']; ta += x['keys_active']; tad += x['admins']
        trs += x['resellers']; ts += x['slots_total']; tb += x['slots_busy']
    r += f"━━━━━━━━━━━━━\n🔑 {ta}/{tk} · 👤 {tad} · 🛒 {trs} · 📊 {tb}/{ts}"
    bot.reply_to(message, r)

# ═══ BACKGROUND ═══
def auto_release_loop():
    while True:
        try:
            if get_maintenance() == "on": time.sleep(2); continue
            conn = get_conn(); c = conn.cursor()
            now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            c.execute('''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                         time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0
                         WHERE is_active=1 AND end_time <= ?''', (now_str,))
            c.execute("SELECT key FROM keys WHERE expiry <= ? AND status=?", (now_str, STATUS_ACTIVE))
            exp = [r[0] for r in c.fetchall()]
            if exp:
                ph = ','.join('?' * len(exp))
                c.execute(f"DELETE FROM key_devices WHERE key IN ({ph})", exp)
                c.execute(f"DELETE FROM keys WHERE key IN ({ph})", exp)
                c.execute(f'''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                             time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0
                             WHERE key IN ({ph})''', exp)
            conn.commit()
        except Exception as e: log.error(f"auto_release: {e}")
        time.sleep(1)

def backup_loop():
    while True:
        try:
            if os.path.exists(DB_NAME):
                ts = datetime.now().strftime('%Y%m%d_%H%M%S')
                dst = os.path.join(BACKUP_DIR, f"lightning_{ts}.db")
                shutil.copy2(DB_NAME, dst)
                files = sorted([f for f in os.listdir(BACKUP_DIR) if f.startswith('lightning_')])
                for old in files[:-7]:
                    try: os.remove(os.path.join(BACKUP_DIR, old))
                    except OSError: pass
        except Exception as e: log.error(f"backup: {e}")
        time.sleep(86400)

def main():
    init_db()
    log.info("=" * 60)
    log.info(f"⚡ LIGHTNING VPS — Port 5000 (PID {os.getpid()})")
    log.info("=" * 60)

    # Background threads only in non-gunicorn (dev) mode
    if not os.environ.get("GUNICORN_WORKER"):
        threading.Thread(target=_dd_worker, args=(0,), daemon=True).start()
        threading.Thread(target=auto_release_loop, daemon=True).start()
        threading.Thread(target=backup_loop, daemon=True).start()

if __name__ == '__main__':
    main()
PYEOF

chmod +x "$INSTALL_DIR/lightning_vps_fast.py"
log "Main app created"

# ═══════════════════════════════════════════════════════════════════
# 4. Gunicorn config (5000-only, 8-core tuned)
# ═══════════════════════════════════════════════════════════════════
info "Gunicorn config..."

cat > "$INSTALL_DIR/gunicorn_conf.py" << 'GUNEOF'
import os

# ═══ 8-CORE TUNING (Port 5000 ONLY) ═══
# 4 workers × 8 threads = 32 concurrent on port 5000
workers = 4
worker_class = "gthread"
threads = 8
bind = "0.0.0.0:5000"          # ← APK yahan hit karega
timeout = 60
graceful_timeout = 30
keepalive = 5
max_requests = 20000
max_requests_jitter = 2000
preload_app = True              # ← shared memory, faster startup
worker_tmp_dir = "/dev/shm"
accesslog = "/root/lightning/gunicorn-access.log"
errorlog = "/root/lightning/gunicorn-error.log"
loglevel = "warning"
proc_name = "lightning-api"
backlog = 2048                  # ← 5000 port pe zyada requests handle
os.environ["GUNICORN_WORKER"] = "1"

def when_ready(server):
    server.log.info("⚡ Lightning API ready on 5000 (4×8 = 32 concurrent)")

def on_exit(server):
    server.log.info("API shutting down")
GUNEOF

log "Gunicorn config ready"

# ═══════════════════════════════════════════════════════════════════
# 5. Release worker
# ═══════════════════════════════════════════════════════════════════
info "Release worker..."

cat > "$INSTALL_DIR/release_worker.py" << 'RWEOF'
#!/usr/bin/env python3
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lightning_vps_fast import init_db, get_conn, log, get_maintenance
from datetime import datetime

def main():
    init_db()
    log.info("🔄 Release worker started")
    while True:
        try:
            if get_maintenance() == "on":
                time.sleep(2); continue
            conn = get_conn(); c = conn.cursor()
            now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            c.execute('''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                         time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0
                         WHERE is_active=1 AND end_time <= ?''', (now_str,))
            c.execute("SELECT key FROM keys WHERE expiry <= ? AND status='ACTIVE'", (now_str,))
            exp = [r[0] for r in c.fetchall()]
            if exp:
                ph = ','.join('?' * len(exp))
                c.execute(f"DELETE FROM key_devices WHERE key IN ({ph})", exp)
                c.execute(f"DELETE FROM keys WHERE key IN ({ph})", exp)
                c.execute(f'''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                             time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0
                             WHERE key IN ({ph})''', exp)
                log.info(f"🗑️ Cleaned {len(exp)} keys")
            conn.commit()
        except Exception as e:
            log.error(f"release: {e}")
        time.sleep(0.5)

if __name__ == "__main__":
    main()
RWEOF

chmod +x "$INSTALL_DIR/release_worker.py"
log "Release worker ready"

# ═══════════════════════════════════════════════════════════════════
# 6. Bot worker
# ═══════════════════════════════════════════════════════════════════
info "Bot worker..."

cat > "$INSTALL_DIR/bot_worker.py" << 'BWEOF'
#!/usr/bin/env python3
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lightning_vps_fast import init_db, bot, log

def main():
    init_db()
    log.info("🤖 Bot worker starting...")
    while True:
        try:
            bot.polling(non_stop=True, interval=0, timeout=20,
                        long_polling_timeout=20,
                        allowed_updates=['message', 'callback_query'])
        except Exception as e:
            log.error(f"Bot crash: {e} — restart 5s")
            time.sleep(5)

if __name__ == "__main__":
    main()
BWEOF

chmod +x "$INSTALL_DIR/bot_worker.py"
log "Bot worker ready"

# ═══════════════════════════════════════════════════════════════════
# 7. Systemd services
# ═══════════════════════════════════════════════════════════════════
info "Systemd services..."

# API service — port 5000 ONLY
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

# ═══════════════════════════════════════════════════════════════════
# 8. Redis
# ═══════════════════════════════════════════════════════════════════
info "Redis..."
systemctl enable redis-server > /dev/null 2>&1
systemctl restart redis-server
sleep 1
log "Redis running"

# ═══════════════════════════════════════════════════════════════════
# 9. Init DB
# ═══════════════════════════════════════════════════════════════════
info "DB init..."
cd "$INSTALL_DIR"
source venv/bin/activate
GUNICORN_WORKER=1 python3 -c "from lightning_vps_fast import init_db; init_db()" 2>&1 | tail -3
log "DB ready"

# ═══════════════════════════════════════════════════════════════════
# 10. Start services
# ═══════════════════════════════════════════════════════════════════
info "Starting services..."
systemctl enable lightning-api lightning-release lightning-bot > /dev/null 2>&1
systemctl start lightning-api
sleep 2
systemctl start lightning-release
systemctl start lightning-bot
sleep 3
log "Services started"

# ═══════════════════════════════════════════════════════════════════
# 11. Firewall — allow 5000
# ═══════════════════════════════════════════════════════════════════
info "Firewall..."
ufw --force enable > /dev/null 2>&1
ufw allow 22/tcp > /dev/null 2>&1
ufw allow 5000/tcp > /dev/null 2>&1    # ← APK ke liye
log "Firewall: 22, 5000 allowed"

# ═══════════════════════════════════════════════════════════════════
# 12. Health check
# ═══════════════════════════════════════════════════════════════════
sleep 2
HEALTH=$(curl -s http://localhost:5000/api/health || echo "FAIL")

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         ✅  DEPLOYMENT COMPLETE (Port 5000)              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  📊 Status:"
systemctl is-active lightning-api && echo "    ✅ API :5000 (4 workers × 8 threads = 32 concurrent)" || echo "    ❌ API"
systemctl is-active lightning-release && echo "    ✅ Release Worker" || echo "    ❌ Release Worker"
systemctl is-active lightning-bot && echo "    ✅ Telegram Bot" || echo "    ❌ Telegram Bot"
systemctl is-active redis-server && echo "    ✅ Redis" || echo "    ❌ Redis"
echo ""
echo "  🌐 API Endpoint (APK yahan bhejega):"
echo "     http://$(hostname -I | awk '{print $1}'):5000"
echo ""
echo "  📁 Install:    $INSTALL_DIR"
echo "  📝 Logs:       $INSTALL_DIR/lightning.log"
echo "  💾 Backups:    $INSTALL_DIR/backups/"
echo ""
echo "  🔧 Useful commands:"
echo "    systemctl status lightning-api         # check API"
echo "    systemctl restart lightning-api        # restart API"
echo "    systemctl restart lightning-bot        # restart bot"
echo "    journalctl -u lightning-api -f         # live API logs"
echo "    tail -f $INSTALL_DIR/lightning.log    # app logs"
echo ""
echo "  🧪 Test:"
echo "    curl http://localhost:5000/api/health"
echo ""
echo "  📱 APK Config:"
echo "    Base URL: http://$(hostname -I | awk '{print $1}'):5000"
echo "    Header:   X-API-KEY: RAGEBITE_SECRET_2026_CHANGE_ME"
echo ""

DEPLOY_EOF

chmod +x /root/lightning/deploy.sh
