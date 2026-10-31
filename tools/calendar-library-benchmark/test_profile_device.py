import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('profile_device', Path(__file__).with_name('profile-device.py'))
profiler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiler)


class RecordingTempCleanupTests(unittest.TestCase):
    def make(self, folder, name, size, age_seconds):
        path = folder / name
        path.write_bytes(b'x' * size)
        stamp = time.time() - age_seconds
        os.utime(path, (stamp, stamp))
        return path

    def test_removes_only_this_recordings_ktrace_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            old = self.make(folder, 'instrumentsOLD.ktrace', 10, age_seconds=600)
            new = self.make(folder, 'instrumentsNEW.ktrace', 20, age_seconds=5)
            other = self.make(folder, 'notes.txt', 5, age_seconds=5)
            result = profiler.remove_recording_temps(folder, time.time() - 60, busy=lambda: False)
            self.assertEqual(result, {'removed': [{'name': 'instrumentsNEW.ktrace', 'bytes': 20}], 'bytes': 20})
            self.assertFalse(new.exists())
            self.assertTrue(old.exists())
            self.assertTrue(other.exists())

    def test_leaves_everything_while_another_recorder_runs(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            new = self.make(folder, 'instrumentsNEW.ktrace', 20, age_seconds=5)
            result = profiler.remove_recording_temps(folder, time.time() - 60, busy=lambda: True)
            self.assertEqual(result, {'skipped': 'another xctrace is running'})
            self.assertTrue(new.exists())

    def test_reports_nothing_when_the_recorder_left_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = profiler.remove_recording_temps(Path(tmp), time.time() - 60, busy=lambda: False)
            self.assertEqual(result, {'removed': [], 'bytes': 0})


if __name__ == '__main__':
    unittest.main()
