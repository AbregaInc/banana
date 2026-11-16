import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SimulatorWorkflowTests(unittest.TestCase):
    def run_workflow(self, *, mode='slim', drift=False, doctor_failure=False, version='0.14.0'):
        if not shutil.which('zsh'):
            self.skipTest('zsh is required for the simulator shell workflow')
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            calls = folder / 'calls'
            binary = folder / 'simslim'
            binary.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
with open(os.environ['CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1] == '--version': print('simslim '+os.environ['VERSION']);sys.exit()
print('{}')
if sys.argv[1] == 'verify' and os.environ['DRIFT']=='1':
 p=Path(os.environ['CALLS']+'.drift')
 if not p.exists(): p.touch();sys.exit(1)
if sys.argv[1] == 'doctor' and os.environ['DOCTOR_FAILURE']=='1':sys.exit(1)
''')
            binary.chmod(0o755)
            xcrun = folder / 'xcrun'
            xcrun.write_text('#!/bin/sh\nprintf \'xcrun\\n\' >> "$CALLS"\n')
            xcrun.chmod(0o755)
            evidence = folder / 'evidence'
            env = dict(os.environ, PATH=str(folder)+':'+os.environ['PATH'], CALLS=str(calls), VERSION=version,
                       DRIFT=str(int(drift)), DOCTOR_FAILURE=str(int(doctor_failure)),
                       BANANA_LOCK_DIR=str(folder/'locks'), BANANA_LOCKS_HELD='sim-phone', SIMULATOR_UDID='fixture-device')
            result = subprocess.run([str(ROOT/'tools/simulator-run.sh'), 'phone', mode, str(evidence), '--',
                                     '/bin/sh', '-c', 'echo COMMAND >> "$CALLS"'], env=env, capture_output=True, text=True)
            return result.returncode, calls.read_text() if calls.exists() else '', list(evidence.glob('*'))

    def test_matching_profile_does_not_reboot_and_runs_command(self):
        rc, calls, evidence = self.run_workflow()
        self.assertEqual(rc, 0)
        self.assertNotIn('["on",', calls)
        self.assertIn('COMMAND', calls)
        self.assertIn('verify.json', [p.name for p in evidence])

    def test_drift_is_repaired_before_verification_and_doctor(self):
        rc, calls, _ = self.run_workflow(drift=True)
        self.assertEqual(rc, 0)
        self.assertLess(calls.index('["on",'), calls.index('["doctor",'))
        self.assertEqual(calls.count('["verify",'), 2)

    def test_broken_required_feature_stops_the_test_command(self):
        rc, calls, _ = self.run_workflow(doctor_failure=True)
        self.assertNotEqual(rc, 0)
        self.assertNotIn('COMMAND', calls)

    def test_stock_mode_uses_the_stock_profile(self):
        rc, calls, _ = self.run_workflow(mode='stock', drift=True)
        self.assertEqual(rc, 0)
        self.assertIn('tools/simulators/stock.json', calls)

    def test_unreviewed_version_stops_before_mutating(self):
        rc, calls, _ = self.run_workflow(version='0.15.0')
        self.assertNotEqual(rc, 0)
        self.assertNotIn('["on",', calls)
        self.assertNotIn('COMMAND', calls)

    def test_profile_preserves_banana_features(self):
        profile = json.loads((ROOT/'tools/simulators/slim.json').read_text())
        self.assertTrue(set(['siri', 'icloud', 'store', 'pim', 'web', 'health', 'photos', 'search', 'other']).issubset(profile['except']))
        self.assertTrue(set(['com.apple.chronod', 'com.apple.liveactivitiesd', 'com.apple.navd']).issubset(profile['keep']))

    def test_invalid_mode_stops_before_mutating(self):
        rc, calls, _ = self.run_workflow(mode='unknown')
        self.assertNotEqual(rc, 0)
        self.assertNotIn('["on",', calls)
        self.assertNotIn('COMMAND', calls)


if __name__ == '__main__':
    unittest.main()
