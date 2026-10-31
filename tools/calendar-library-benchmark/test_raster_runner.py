import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('raster_runner', Path(__file__).with_name('test-device-raster.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RasterRunnerTests(unittest.TestCase):
    def run_case(self, responses):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Probe.app'; app.mkdir()
            (app / 'Probe').write_bytes(b'fixture binary')
            (app / 'Info.plist').write_bytes(plistlib.dumps(dict(
                CFBundleIdentifier='com.boris.banana.calendar-library-benchmark',
                CFBundleExecutable='Probe', CalendarBenchmarkFixtures=['varied-v1'])))
            out = root / 'results'
            with patch('sys.argv', ['probe', '--device', 'fixture', '--app', str(app), '--out', str(out)]), \
                 patch.object(runner.subprocess, 'run', side_effect=responses), \
                 patch.object(runner.time, 'sleep'), patch('builtins.print'):
                code = runner.main()
            return code, json.loads((out / 'status.json').read_text())

    def test_install_failure_preserves_all_cases(self):
        code, report = self.run_case([subprocess.CompletedProcess([], 1, '', 'install failed')])
        self.assertEqual(code, 1)
        self.assertEqual(len(report['cases']), 8)
        self.assertTrue(all(c['status'] == 'unmeasured-not-started' for c in report['cases']))

    def test_locked_launch_is_not_a_pass(self):
        code, report = self.run_case([subprocess.CompletedProcess([], 0, '', ''),
                                      subprocess.CompletedProcess([], 1, '', 'locked')])
        self.assertEqual(code, 1)
        self.assertEqual(report['cases'][0]['status'], 'unmeasured-incomplete')
        self.assertTrue(all(c['status'] == 'unmeasured-not-started' for c in report['cases'][1:]))

    def test_wrong_density_cannot_pass_with_correct_pixels(self):
        def response(command, **_):
            if 'copy' in command:
                destination = Path(command[command.index('--destination') + 1])
                destination.write_text(json.dumps(dict(status='passed', checks=96, failures=[],
                    pixelBuffer=False, batchEventFills=False,
                    fixture=dict(profile='varied-v1', seed='20261009', calendarCount=12,
                                 hiddenCalendars=[], retainedEvents=365, meanDailyEvents=1))))
            return subprocess.CompletedProcess(command, 0, '', '')
        code, report = self.run_case(response)
        self.assertEqual(code, 1)
        self.assertEqual(report['cases'][0]['status'], 'failed')
        self.assertEqual(len(report['cases']), 8)


if __name__ == '__main__':
    unittest.main()
