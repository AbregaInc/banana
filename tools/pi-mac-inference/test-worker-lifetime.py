#!/usr/bin/env python3
"""Test the bundled worker's crash cleanup with a tiny fake server, no model/MLX/GPU."""
import os,pathlib,signal,subprocess,sys,tempfile,time,unittest

class WorkerLifetimeTests(unittest.TestCase):
    def testParentCrashTerminatesWorker(self):
        worker=pathlib.Path(__file__).resolve().parents[2]/'Banana/Pi/Resources/pi-inference-worker.py'
        with tempfile.TemporaryDirectory(prefix='pi-worker-lifetime-') as tmp:
            root=pathlib.Path(tmp);package=root/'locals';package.mkdir();(package/'__init__.py').write_text('')
            marker=root/'state'
            (package/'server.py').write_text('''import os,signal,sys,time,pathlib
marker=pathlib.Path(os.environ['PI_WORKER_TEST_MARKER'])
def stop(*_):
    marker.write_text('stopped')
    sys.exit(0)
signal.signal(signal.SIGTERM,stop)
marker.write_text('ready')
while True:time.sleep(.05)
''')
            parent_code='''import os,subprocess,sys
child=subprocess.Popen([sys.executable,sys.argv[1],str(os.getpid())])
print(child.pid,flush=True)
sys.stdin.read()
'''
            env={**os.environ,'PYTHONPATH':str(root),'PI_WORKER_TEST_MARKER':str(marker)}
            parent=subprocess.Popen([sys.executable,'-c',parent_code,str(worker)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
            child=None
            try:
                child=int(parent.stdout.readline())
                deadline=time.monotonic()+5
                while time.monotonic()<deadline and not marker.exists():time.sleep(.02)
                self.assertTrue(marker.exists(),'Fake server did not start')
                self.assertEqual(marker.read_text(),'ready')
                parent.kill();parent.wait(timeout=3)
                deadline=time.monotonic()+5
                while time.monotonic()<deadline and marker.read_text()!='stopped':time.sleep(.02)
                self.assertEqual(marker.read_text(),'stopped','Worker survived its parent crash')
            finally:
                if parent.poll() is None:parent.kill();parent.wait(timeout=3)
                if child:
                    try:os.kill(child,signal.SIGTERM)
                    except ProcessLookupError:pass
                parent.stdout.close();parent.stderr.close();parent.stdin.close()

if __name__=='__main__':unittest.main()
