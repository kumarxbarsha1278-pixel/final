import os

# ═══ 8-CORE TUNING (Port 5000 ONLY) ═══
workers = 4
worker_class = "gthread"
threads = 8
bind = "0.0.0.0:5000"
timeout = 60
graceful_timeout = 30
keepalive = 5
max_requests = 20000
max_requests_jitter = 2000
preload_app = True
worker_tmp_dir = "/dev/shm"
accesslog = "/root/lightning/gunicorn-access.log"
errorlog = "/root/lightning/gunicorn-error.log"
loglevel = "warning"
proc_name = "lightning-api"
backlog = 2048

os.environ["GUNICORN_WORKER"] = "1"


def when_ready(server):
    server.log.info("⚡ Lightning API ready on 5000 (4×8 = 32 concurrent)")


def on_exit(server):
    server.log.info("API shutting down")
