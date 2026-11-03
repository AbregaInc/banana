#!/usr/bin/env python3
"""Hold the shared runtime cache lock through building, pruning and copying into an app."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys

lock = Path.home() / 'Library/Caches/Banana Pi build/.pi-runtime.lock'
lock.parent.mkdir(parents=True, exist_ok=True)
with lock.open('a') as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    environment = dict(os.environ, BANANA_RUNTIME_CACHE_LOCKED='1')
    sys.exit(subprocess.call(sys.argv[1:], env=environment))
