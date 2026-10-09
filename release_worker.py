#!/usr/bin/env python3
"""
Standalone auto-release worker — run ONE instance via systemd.
Expires keys and frees slots every 500ms.
"""
import sys
import os
import time
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lightning_vps_fast import (
    init_db, get_conn, log, get_maintenance, STATUS_ACTIVE
)


def main():
    init_db()
    log.info("🔄 Release worker started")
    while True:
        try:
            if get_maintenance() == "on":
                time.sleep(2)
                continue

            conn = get_conn()
            c = conn.cursor()
            now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

            # Bulk free expired slots
            c.execute('''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                         time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0
                         WHERE is_active=1 AND end_time <= ?''', (now_str,))

            # Bulk delete expired keys
            c.execute("SELECT key FROM keys WHERE expiry <= ? AND status=?",
                      (now_str, STATUS_ACTIVE))
            expired = [r[0] for r in c.fetchall()]
            if expired:
                ph = ','.join('?' * len(expired))
                c.execute(f"DELETE FROM key_devices WHERE key IN ({ph})", expired)
                c.execute(f"DELETE FROM keys WHERE key IN ({ph})", expired)
                c.execute(
                    f'''UPDATE slots SET key=NULL, device_id=NULL, ip=NULL, port=NULL,
                        time_sec=NULL, start_time=NULL, end_time=NULL, is_active=0
                        WHERE key IN ({ph})''', expired
                )
                log.info(f"🗑️ Cleaned {len(expired)} expired keys")

            conn.commit()
        except Exception as e:
            log.error(f"release: {e}")
        time.sleep(0.5)


if __name__ == "__main__":
    main()
