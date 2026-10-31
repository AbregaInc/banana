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
    def test_capacity_matrix_retains_all_requested_volumes_and_repeats(self):
        matrix = runner.cases('foreground', [1, 5, 25, 75], 3, 'tile-prefetch-async-two')
        self.assertEqual(len(matrix), 12)
        self.assertEqual(len({name for name, _, _ in matrix}), 12)
        self.assertEqual({variant for _, _, variant in matrix}, {'tile-prefetch-async-two'})
        for density in [1, 5, 25, 75]:
            self.assertEqual(sum(value == density for _, value, _ in matrix), 3)

    def test_matrix_retains_three_alternating_trials_at_both_densities(self):
        matrix = runner.cases()
        self.assertEqual(len(matrix), 18)
        self.assertEqual(len({name for name, _, _ in matrix}), 18)
        self.assertEqual([v for _, _, v in matrix[:3]],
                         list(reversed([v for _, _, v in matrix[6:9]])))
        self.assertEqual({d for _, d, _ in matrix}, {100, 300})
        focused = runner.cases('accessibility-cache')
        self.assertEqual(len(focused), 12)
        self.assertEqual([v for _, _, v in focused[:2]],
                         list(reversed([v for _, _, v in focused[4:6]])))

        lazy = runner.cases('accessibility-lazy')
        self.assertEqual(len(lazy), 12)
        self.assertEqual({v for _, _, v in lazy}, {'tile-prefetch-ax-cache', 'tile-prefetch-ax-lazy'})
        native_text = runner.cases('native-text')
        self.assertEqual(len(native_text), 12)
        self.assertEqual({v for _, _, v in native_text}, {'tile-prefetch-budgeted', 'tile-prefetch-native-text'})
        queue = runner.cases('queue')
        self.assertEqual(len(queue), 18)
        self.assertEqual({v for _, _, v in queue},
                         {'tile-prefetch-budgeted', 'tile-prefetch-queue-one', 'tile-prefetch-queue-two'})
        self.assertEqual([v for _, _, v in queue[:3]], list(reversed([v for _, _, v in queue[6:9]])))

    def test_cooperative_queue_matrix_keeps_alternating_controls(self):
        matrix = runner.cases('queue-cancel')
        self.assertEqual(len(matrix), 12)
        self.assertEqual(len({name for name, _, _ in matrix}), 12)
        self.assertEqual({density for _, density, _ in matrix}, {100, 300})
        self.assertEqual({variant for _, _, variant in matrix},
                         {'tile-prefetch-queue-two', 'tile-prefetch-queue-two-cancel'})
        self.assertEqual([v for _, _, v in matrix[:2]],
                         list(reversed([v for _, _, v in matrix[4:6]])))

    def test_foreground_matrix_preserves_matched_controls(self):
        matrix = runner.cases('foreground')
        self.assertEqual(len(matrix), 18)
        self.assertEqual(len({name for name, _, _ in matrix}), 18)
        self.assertEqual({density for _, density, _ in matrix}, {100, 300})
        self.assertEqual({variant for _, _, variant in matrix},
            {'tile-prefetch-budgeted', 'tile-prefetch-async-one', 'tile-prefetch-async-two'})
        self.assertEqual([v for _, _, v in matrix[:3]], list(reversed([v for _, _, v in matrix[6:9]])))

    def test_foreground_accessibility_changes_only_accessibility_policy(self):
        matrix = runner.cases('foreground-accessibility')
        self.assertEqual(len(matrix), 12)
        self.assertEqual({density for _, density, _ in matrix}, {100, 300})
        self.assertEqual({variant for _, _, variant in matrix},
            {'tile-prefetch-async-two', 'tile-prefetch-async-lazy'})
        self.assertEqual([v for _, _, v in matrix[:2]], list(reversed([v for _, _, v in matrix[4:6]])))

    def test_native_surface_matrix_preserves_controls_and_densities(self):
        matrix = runner.cases('foreground-surface')
        self.assertEqual(len(matrix), 12)
        self.assertEqual({density for _, density, _ in matrix}, {100, 300})
        self.assertEqual({variant for _, _, variant in matrix},
            {'tile-prefetch-async-two', 'tile-prefetch-async-surface'})
        self.assertEqual([v for _, _, v in matrix[:2]], list(reversed([v for _, _, v in matrix[4:6]])))

    def test_surface_accessibility_matrix_keeps_storage_fixed(self):
        matrix = runner.cases('foreground-surface-accessibility')
        self.assertEqual(len(matrix), 12)
        self.assertEqual(len({name for name, _, _ in matrix}), 12)
        self.assertEqual({density for _, density, _ in matrix}, {100, 300})
        self.assertEqual({variant for _, _, variant in matrix},
            {'tile-prefetch-async-surface', 'tile-prefetch-async-surface-lazy'})
        self.assertEqual([v for _, _, v in matrix[:2]], list(reversed([v for _, _, v in matrix[4:6]])))

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
