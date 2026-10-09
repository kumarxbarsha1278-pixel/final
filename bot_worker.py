#!/usr/bin/env python3
"""
Standalone Telegram bot — run ONE instance via systemd.
Uses polling with auto-restart on crash.
"""
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lightning_vps_fast import init_db, bot, log


def main():
    init_db()
    log.info("🤖 Bot worker starting...")
    while True:
        try:
            bot.polling(
                non_stop=True,
                interval=0,
                timeout=20,
                long_polling_timeout=20,
                allowed_updates=['message', 'callback_query'],
            )
        except Exception as e:
            log.error(f"Bot crash: {e} — restart 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
