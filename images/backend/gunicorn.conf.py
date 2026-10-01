import os

bind = "0.0.0.0:8000"
workers = int(os.environ.get("WEB_CONCURRENCY", "2"))
worker_class = "workers.UvicornWorker"
timeout = 120
graceful_timeout = 30
keepalive = 5
accesslog = "-"
errorlog = "-"
access_log_format = 'testy-access remote=%(h)s request="%(r)s" status=%(s)s bytes=%(b)s'
capture_output = True
forwarded_allow_ips = "*"
