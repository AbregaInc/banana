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
            env={**os.environ,'PYTHONPATH':str(root),'PI_WORKER_TEST_MARKER':str(marker),'BANANA_WORKER_TOKEN':'t'*64}
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

class WorkerSecretTests(unittest.TestCase):
    def testOnlyBananaIsAnsweredAndTheAnswerProvesTheWorker(self):
        import hashlib,hmac,socket,urllib.request,urllib.error
        worker=pathlib.Path(__file__).resolve().parents[2]/'Banana/Pi/Resources/pi-inference-worker.py'
        with socket.socket() as s:
            s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        with tempfile.TemporaryDirectory(prefix='pi-worker-secret-') as tmp:
            root=pathlib.Path(tmp);package=root/'locals';package.mkdir();(package/'__init__.py').write_text('')
            (package/'server.py').write_text(f'''from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200);self.send_header("Content-Length","2");self.end_headers();self.wfile.write(b"{{}}")
    def log_message(self,*a):pass
ThreadingHTTPServer(("127.0.0.1",{port}),H).serve_forever()
''')
            token='k'*64
            env={**os.environ,'PYTHONPATH':str(root),'BANANA_WORKER_TOKEN':token}
            child=subprocess.Popen([sys.executable,str(worker),str(os.getpid())],env=env)
            try:
                url=f'http://127.0.0.1:{port}/v1/models'
                deadline=time.monotonic()+5
                while True:
                    try:urllib.request.urlopen(urllib.request.Request(url,headers={'X-Banana-Token':token}),timeout=1);break
                    except Exception:
                        if time.monotonic()>deadline:raise
                        time.sleep(.05)
                with self.assertRaises(urllib.error.HTTPError) as refused:urllib.request.urlopen(url,timeout=2)
                self.assertEqual(refused.exception.code,403)
                self.assertIsNone(refused.exception.headers.get('X-Banana-Worker'),'no proof to a stranger')
                answer=urllib.request.urlopen(urllib.request.Request(url,headers={'X-Banana-Token':token}),timeout=2)
                self.assertEqual(answer.headers.get('X-Banana-Worker'),hmac.new(token.encode(),b'banana-worker',hashlib.sha256).hexdigest())
            finally:
                child.terminate();child.wait(timeout=3)

    def testNoSecretNoWorker(self):
        worker=pathlib.Path(__file__).resolve().parents[2]/'Banana/Pi/Resources/pi-inference-worker.py'
        env={k:v for k,v in os.environ.items() if k!='BANANA_WORKER_TOKEN'}
        self.assertNotEqual(subprocess.run([sys.executable,str(worker),str(os.getpid())],env=env,capture_output=True).returncode,0)

if __name__=='__main__':unittest.main()
