import plistlib
from pathlib import Path
import tempfile
import unittest
from preserve_symbols import preserve


class PreservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'candidate.xcarchive'
        self.app = self.archive / 'Products/Applications/Banana Beta.app'
        self.installed = self.root / 'Applications/Banana Beta.app'
        self.output = self.root / 'symbols'
        for app in (self.app, self.installed):
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Banana'}))
            (app / 'Contents/MacOS/Banana').write_text('installed-build')
        self.symbol = self.archive / 'dSYMs/Banana Beta.app.dSYM'
        self.symbol.mkdir(parents=True)
        (self.symbol / 'UUID').write_text('installed-build')

    @staticmethod
    def identity(path):
        return {(path / 'UUID' if path.is_dir() else path).read_text()}

    def run_preservation(self):
        return preserve(self.archive, self.installed.parent, self.output, self.identity)

    def test_matching_symbols_survive_archive_replacement_and_repeated_preservation(self):
        kept = self.run_preservation()
        self.assertEqual(self.identity(kept[0]), {'installed-build'})
        self.assertEqual(self.run_preservation(), kept)
        import shutil
        shutil.rmtree(self.archive)
        self.assertEqual(self.identity(kept[0]), {'installed-build'})

    def test_an_uninstalled_candidate_does_not_accumulate_symbols(self):
        (self.app / 'Contents/MacOS/Banana').write_text('different-build')
        self.assertEqual(self.run_preservation(), [])
        self.assertFalse(self.output.exists())

    def test_embedded_framework_and_helper_symbols_stay_with_the_installed_app(self):
        framework = self.symbol.parent / 'Framework.framework.dSYM'
        framework.mkdir()
        (framework / 'UUID').write_text('framework-build')
        kept = self.run_preservation()
        self.assertEqual({next(iter(self.identity(p))) for p in kept},
                         {'installed-build', 'framework-build'})

    def test_missing_or_wrong_symbols_stop_before_the_archive_is_replaced(self):
        (self.symbol / 'UUID').write_text('different-build')
        with self.assertRaisesRegex(RuntimeError, 'matching symbols are missing'):
            self.run_preservation()
        self.assertTrue(self.app.exists())


if __name__ == '__main__':
    unittest.main()
