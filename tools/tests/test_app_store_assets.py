import importlib.util
import tempfile
import unittest
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("store_validator", ROOT/"tools/app-store/validate.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class AppStoreMediaTests(unittest.TestCase):
    def check_image(self, mode, *, transparency=None, size=(1320, 2868)):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"capture.png"
            image = Image.new(mode, size)
            options = {} if transparency is None else {"transparency":transparency}
            image.save(path, **options)
            return validator.validate_images(Path(directory), (1320, 2868), 1, 10)

    def test_rgb_screenshot_is_accepted(self):
        self.assertEqual(self.check_image("RGB"), [])

    def test_even_opaque_rgba_is_rejected(self):
        self.assertTrue(self.check_image("RGBA"))

    def test_rgb_png_transparency_is_rejected(self):
        self.assertTrue(self.check_image("RGB", transparency=(0, 0, 0)))

    def test_wrong_dimensions_are_rejected(self):
        self.assertTrue(self.check_image("RGB", size=(660,1434)))

    def test_keyword_limit_counts_utf8_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in validator.LIMITS: (root/name).write_text("Banana")
            (root/"keywords.txt").write_text("é"*51)
            self.assertTrue(any("102 exceeds limit 100" in e for e in validator.validate_metadata(root)))


if __name__ == "__main__": unittest.main()
