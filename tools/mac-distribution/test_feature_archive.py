"""Exercise the release guard on actual Mach-O fixtures, including nested identities."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class FeatureArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.root = pathlib.Path(cls.scratch.name)
        source = cls.root / 'fixture.c'
        source.write_text('const char *scope = "gmail.googleapis.com"; int main(void) { return scope[0]; }')
        cls.binary = cls.root / 'fixture'
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', str(source), '-o', str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def app(self, parent, channel='stable', bundle='org.example.banana', marker='EMAIL\n'):
        app = parent / 'Banana.app'
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps(dict(BananaReleaseChannel=channel, CFBundleIdentifier=bundle, BananaPrimaryBundleIdentifier='org.example.banana')))
        exe = app / 'Banana'
        exe.write_bytes(self.binary.read_bytes())
        exe.chmod(0o755)
        (app / 'banana-local-features.txt').write_text(marker)
        return app

    def check(self, target, allowed):
        result = subprocess.run(['bash', str(ROOT / 'tools/check-release.sh'), str(target)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, allowed, result.stdout + result.stderr)

    def test_email_requires_testflight_channel_and_primary_identity(self):
        for channel, bundle, allowed in [('testflight', 'org.example.banana', True),
                                         ('stable', 'org.example.banana', False),
                                         ('beta', 'org.example.banana.beta', False),
                                         ('testflight', 'org.example.banana.beta', False),
                                         ('dev', 'org.example.banana.dev', False)]:
            with self.subTest(channel=channel, bundle=bundle), tempfile.TemporaryDirectory() as path:
                self.check(self.app(pathlib.Path(path), channel, bundle), allowed)

    def test_missing_primary_identity_fails_closed(self):
        with tempfile.TemporaryDirectory() as path:
            app = self.app(pathlib.Path(path), 'testflight')
            info = app / 'Info.plist'
            values = plistlib.loads(info.read_bytes())
            del values['BananaPrimaryBundleIdentifier']
            info.write_bytes(plistlib.dumps(values))
            self.check(app, False)

    def test_nested_testflight_does_not_authorize_stable(self):
        with tempfile.TemporaryDirectory() as path:
            app = self.app(pathlib.Path(path))
            self.app(app / 'Nested', 'testflight', 'org.example.banana')
            self.check(app, False)

    def test_testflight_cannot_ship_ai(self):
        with tempfile.TemporaryDirectory() as path:
            self.check(self.app(pathlib.Path(path), 'testflight', 'org.example.banana', 'EMAIL\nAI\n'), False)

    def test_ambiguous_archive_fails_closed(self):
        with tempfile.TemporaryDirectory() as path:
            root = pathlib.Path(path)
            self.app(root / 'one', 'testflight', 'org.example.banana')
            self.app(root / 'two')
            self.check(root, False)
