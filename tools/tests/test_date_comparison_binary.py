"""Exercise the release guard against real SDK-linked and compatibility-linked Mach-O code."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DateComparisonBinaryTests(unittest.TestCase):
    def test_release_rejects_sdk_operators_and_accepts_shared_comparisons(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Probe.app"
            contents = app / "Contents"
            binary = contents / "MacOS/Probe"
            binary.parent.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Probe", "CFBundleIdentifier": "org.example.date-probe",
                "BananaModules": "", "BananaReleaseChannel": "appstore"}))
            source = root / "main.swift"
            source.write_text("import Foundation\nprint(Date() >= Date.distantPast, Date() <= Date.distantFuture)\n")
            def compile(sources):
                subprocess.run([str(ROOT / "tools/agents/xcode-lock.sh"), "xcrun", "swiftc", "-O",
                                "-target", "arm64-apple-macos26.0", *map(str, sources), "-o", str(binary)],
                               check=True, capture_output=True, text=True, timeout=120)
            def check():
                return subprocess.run([str(ROOT / "tools/check-release.sh"), str(app)],
                                      capture_output=True, text=True, timeout=60)
            compile([source])
            rejected = check()
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("runtime-unsafe Foundation Date", rejected.stdout)
            compile([ROOT / "Shared/DateComparisonCompatibility.swift", source])
            accepted = check()
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            self.assertEqual(subprocess.check_output([str(binary)], text=True).strip(), "true true")
