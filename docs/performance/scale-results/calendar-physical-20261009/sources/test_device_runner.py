import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('device_runner', Path(__file__).with_name('run-device.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class DeviceRunnerTests(unittest.TestCase):
    def test_matrix_retains_three_alternating_trials_at_both_densities(self):
        matrix = runner.cases()
        self.assertEqual(len(matrix), 18)
        self.assertEqual(len({name for name, _, _ in matrix}), 18)
        self.assertEqual([v for _, _, v in matrix[:3]],
                         list(reversed([v for _, _, v in matrix[6:9]])))
        self.assertEqual({d for _, d, _ in matrix}, {100, 300})

    def run_fixture(self, replies):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Benchmark.app'
            app.mkdir()
            (app / 'Benchmark').write_bytes(b'fixture binary')
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.boris.banana.calendar-library-benchmark',
                'CFBundleExecutable': 'Benchmark'}))
            out = root / 'results'
            with patch('sys.argv', ['run-device.py', '--device', 'fixture', '--app', str(app), '--out', str(out)]), \
                 patch.object(runner.subprocess, 'check_output', return_value='fixture\n'), \
                 patch.object(runner.subprocess, 'run', side_effect=replies), patch('builtins.print'):
                code = runner.main()
            return code, json.loads((out / 'summary.json').read_text())

    def test_install_failure_keeps_all_scenarios_unmeasured(self):
        code, rows = self.run_fixture([subprocess.CompletedProcess([], 1, '', 'Install failed')])
        self.assertEqual(code, 1)
        self.assertEqual(len(rows), 18)
        self.assertTrue(all(row['status'] == 'blocked-install' for row in rows))

    def test_interruption_keeps_current_and_remaining_scenarios(self):
        code, rows = self.run_fixture([subprocess.CompletedProcess([], 0, '', ''), KeyboardInterrupt()])
        self.assertEqual(code, 2)
        self.assertEqual(len(rows), 18)
        self.assertEqual(rows[0]['status'], 'interrupted-unmeasured')
        self.assertTrue(all(row['status'] == 'unmeasured-not-started' for row in rows[1:]))

    def test_repeated_launch_failures_retain_unmeasured_coverage(self):
        replies = [subprocess.CompletedProcess([], 0, '', '')]
        replies += [subprocess.CompletedProcess([], 1, '', 'Locked')] * 3
        code, rows = self.run_fixture(replies)
        self.assertEqual(code, 1)
        self.assertTrue(all(row['status'] == 'failed-or-timeout' for row in rows[:3]))
        self.assertTrue(all(row['status'] == 'blocked-repeated-launch-failure' for row in rows[3:]))


if __name__ == '__main__':
    unittest.main()
