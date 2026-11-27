import importlib.util
import sys
import unittest
from pathlib import Path

camera = Path(__file__).resolve().parents[1] / "physical-stress-tests"
sys.path.insert(0, str(camera))
try:
    import numpy as np
    import scipy.fft
except ImportError:
    np = None


@unittest.skipIf(np is None, "recording analysis requires NumPy and SciPy")
class CalendarPresentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("calendar_presentation", camera / "calendar-presentation.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_registration_preserves_finger_direction_in_either_orientation(self):
        rng = np.random.default_rng(4)
        for height, width in [(48, 120), (120, 48)]:
            reference = rng.integers(0, 256, (height, width), dtype=np.uint8)
            for delta in [0, -9, 12]:
                with self.subTest(width=width, delta=delta):
                    moved = np.roll(reference, delta, axis=1)
                    shift, score, margin = self.module.translation(reference, moved)
                    self.assertEqual(shift, delta)
                    self.assertGreater(score, 0.95)
                    self.assertGreater(margin, 0.08)

    def test_repeating_columns_do_not_establish_a_unique_visible_shift(self):
        stripes = np.tile([0, 0, 255, 255, 255, 0], (36, 30)).astype(np.uint8)
        _, _, margin = self.module.translation(stripes, np.roll(stripes, 6, axis=1))
        self.assertLess(margin, 0.08)


if __name__ == "__main__":
    unittest.main()
