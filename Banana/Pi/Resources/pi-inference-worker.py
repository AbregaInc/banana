"""Run only the local inference server; release GPU memory if Banana exits/crashes."""
import os
import runpy
import signal
import sys
import threading

parent = int(sys.argv.pop(1))

def watch_parent():
    wait = threading.Event()
    while not wait.wait(1):
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGTERM)
            return

threading.Thread(target=watch_parent, daemon=True).start()
runpy.run_module("locals.server", run_name="__main__")
