"""Run only the local inference server; release GPU memory if Banana exits/crashes.

Banana gives this process a secret for this launch (BANANA_WORKER_TOKEN). A request without it is
refused, so no other program or web page on this Mac can use the worker; every answer to a request
with it carries a proof made from it (X-Banana-Worker), so Banana knows it is talking to the worker
it started, not to another program that took the port first.
"""
import hashlib
import hmac
import http.server
import os
import runpy
import signal
import sys
import threading

parent = int(sys.argv.pop(1))
token = os.environ.pop("BANANA_WORKER_TOKEN", "").encode()
if len(token) < 32:
    sys.exit("pi-inference-worker: no launch secret")
proof = hmac.new(token, b"banana-worker", hashlib.sha256).hexdigest()

_parse_request = http.server.BaseHTTPRequestHandler.parse_request
_end_headers = http.server.BaseHTTPRequestHandler.end_headers


def parse_request(self):
    self.banana_ok = False
    if not _parse_request(self):
        return False
    given = (self.headers.get("X-Banana-Token") or "").encode()
    if not hmac.compare_digest(given, token):
        self.send_error(403, "Forbidden")
        return False
    self.banana_ok = True
    return True


def end_headers(self):
    if getattr(self, "banana_ok", False):
        self.send_header("X-Banana-Worker", proof)
    _end_headers(self)


http.server.BaseHTTPRequestHandler.parse_request = parse_request
http.server.BaseHTTPRequestHandler.end_headers = end_headers


def watch_parent():
    wait = threading.Event()
    while not wait.wait(1):
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGTERM)
            # A busy native kernel may defer Python's signal handler. The parent can
            # no longer consume an answer or finish cleanup on our behalf.
            wait.wait(2)
            os._exit(0)

threading.Thread(target=watch_parent, daemon=True).start()
runpy.run_module("locals.server", run_name="__main__")
