import importlib.util
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "physical-stress-tests"))
from presentation_clock import current_sequence


class PresentationClockTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("ffmpeg"), "needs ffmpeg")
    def test_mail_ocr_preserves_a_recordings_nonzero_stream_start(self):
        script = Path(__file__).resolve().parents[1] / "physical-stress-tests/mail-presentation.py"
        spec = importlib.util.spec_from_file_location("mail_presentation", script)
        mail = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mail)
        with tempfile.TemporaryDirectory() as folder:
            movie = Path(folder) / "latched.mov"
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi",
                            "-i", "color=size=160x120:rate=10:duration=0.5", "-c:v", "mpeg4",
                            "-output_ts_offset", "2", movie], check=True)
            with patch.object(mail, "capture", return_value=b"Section 1 Section 2"):
                frames = mail.readable_frames(movie, "", 1.9, 2.15)
        self.assertEqual([frame["recordingSeconds"] for frame in frames], [2.0])

    def test_previous_process_last_screen_can_precede_the_calibration(self):
        self.assertEqual(current_sequence([(7, 0), (0, 4), (1, 5), (2, 6), (3, 7), (7, 8)]),
                         {0: 4, 1: 5, 2: 6, 3: 7, 7: 8})

    def test_insufficient_transitions_cannot_align_the_recording(self):
        self.assertEqual(current_sequence([(0, 2), (1, 3), (3, 4), (5, 5)]), {})

    def test_two_complete_sequences_are_ambiguous(self):
        with self.assertRaises(ValueError):
            current_sequence([(code, timestamp) for timestamp, code in enumerate([0, 1, 2, 3] * 2)])


if __name__ == "__main__":
    unittest.main()
