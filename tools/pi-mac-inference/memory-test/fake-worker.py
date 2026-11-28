#!/usr/bin/python3
"""Model-free loopback fixture for VerifyMemoryGuard. No access to application data."""
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import sys
import time

folder = Path(sys.argv[sys.argv.index('--model') + 1])
token = os.environ.pop('BANANA_WORKER_TOKEN').encode()
proof = hmac.new(token, b'banana-worker', hashlib.sha256).hexdigest()
signal.signal(signal.SIGTERM, signal.SIG_IGN)
(folder / 'pid').write_text(str(os.getpid()))
(folder / 'cache-argument').write_text(sys.argv[sys.argv.index('--cache-gb') + 1])
if (folder / 'hold-load').exists():
    time.sleep(20)


class Handler(BaseHTTPRequestHandler):
    def respond(self, value):
        if not hmac.compare_digest(self.headers.get('X-Banana-Token', '').encode(), token):
            self.send_error(403)
            return
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('X-Banana-Worker', proof)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.respond({'data': [{'id': 'locals/test'}]})

    def do_POST(self):
        marker = folder / 'request'
        if not marker.exists():
            marker.touch()
            time.sleep(20)
        self.respond({'choices': [{'finish_reason': 'stop', 'message': {
            'role': 'assistant', 'content': 'fixture answer'}}]})


ThreadingHTTPServer(('127.0.0.1', int(sys.argv[sys.argv.index('--port') + 1])), Handler).serve_forever()
