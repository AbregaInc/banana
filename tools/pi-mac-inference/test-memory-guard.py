#!/usr/bin/env python3
"""Exercise the Mac worker lifecycle with synthetic data, no model or memory pressure induced."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile

here = Path(__file__).resolve().parent
pi = here.parents[1] / 'Banana/Pi'
with tempfile.TemporaryDirectory(prefix='banana-memory-test-') as tmp:
    root = Path(tmp)
    binary = root / 'VerifyMacWorker'
    subprocess.run(['swiftc', '-D', 'BANANA_AI', '-D', 'DEBUG', *[pi / f'{name}.swift' for name in
        ('MacInferenceMemory', 'MacLocalInference', 'LocalInferenceTransport', 'AssistantFailure', 'PinnedModelFiles')],
        here / 'memory-test/Verification.swift', '-o', binary], check=True)
    shutil.copy(pi / 'Resources/pi-inference-worker.py', root)
    worker = root / 'fake-worker'
    shutil.copy(here / 'memory-test/fake-worker.py', worker)
    worker.chmod(0o700)
    for name in ('model.safetensors.index.json', 'model.safetensors'):
        (root / name).write_text('{}')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    profile = dict(python=str(worker), modelDirectory=str(root), modelId='test', serverModel='locals/test',
                   name='Fixture', revision='fixture', port=port, contextWindow=4096, maxTokens=128, thinkingLevel='off')
    config = root / 'profile.json'
    config.write_text(json.dumps(profile))
    try:
        manifest = json.loads((pi / 'Resources/pi-local-model.json').read_text())
        profile['promptCacheGiB'] = manifest['profile']['promptCacheGiB']
        config.write_text(json.dumps(profile))
        subprocess.run([binary, '--assistant-inference-configuration', config], check=True,
                       env={**os.environ, 'TEST_DIRECTORY': tmp, 'EXPECTED_PROMPT_CACHE': '0.25'}, timeout=30)
    finally:
        # A crashed verifier must not leave the fake child running. Recheck its unique
        # temporary executable path before signalling a PID that might already be reused.
        if (root / 'pid').exists():
            pid = int((root / 'pid').read_text())
            command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True)
            if str(worker) in command.stdout:
                os.kill(pid, signal.SIGKILL)
