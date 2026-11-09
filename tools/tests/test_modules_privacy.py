"""The App Store app's privacy manifest declares only what its modules collect: modules.py derives
it from the full one (Config/Modules.json "privacy"), the derived file is current, and the release
check refuses an app whose bundled manifest still declares a left-out module's data."""
import contextlib
import importlib.util
import io
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("modules", ROOT / "tools/modules/modules.py")
modules = importlib.util.module_from_spec(spec); spec.loader.exec_module(modules)
T = "NSPrivacyCollectedDataType"


def full_manifest():
    return plistlib.loads((ROOT / modules.PRIVACY_MANIFEST[0]).read_bytes())


def types(manifest):
    return {e[T]: e[T + "Purposes"] for e in manifest["NSPrivacyCollectedDataTypes"]}


class PrivacyManifestTests(unittest.TestCase):
    def test_calendar_only_app_drops_the_modules_data_types(self):
        derived = types(modules.derive_privacy(full_manifest(), set()))
        for gone in ("Health", "Fitness", "PhotosorVideos", "AudioData", "SearchHistory"):
            self.assertNotIn(T + gone, derived)
        for kept in ("PreciseLocation", "Contacts", "EmailAddress", "OtherUserContent", "CrashData"):
            self.assertIn(T + kept, derived)
        self.assertEqual(derived[T + "ProductInteraction"], [T + "PurposeAnalytics"])

    def test_a_type_stays_while_any_module_collecting_it_is_carried(self):
        derived = types(modules.derive_privacy(full_manifest(), {"food"}))
        self.assertIn(T + "Health", derived)
        self.assertNotIn(T + "Fitness", derived)

    def test_full_app_keeps_everything(self):
        self.assertEqual(modules.derive_privacy(full_manifest(), set(modules.MODULES)), full_manifest())

    def test_generated_app_store_manifest_is_current(self):
        have = modules.carried(modules.xcconfig("BANANA_APP_STORE_MODULES"))
        expected = plistlib.dumps(modules.derive_privacy(full_manifest(), have), sort_keys=True)
        self.assertEqual((ROOT / modules.PRIVACY_MANIFEST[1]).read_bytes(), expected,
                         "run tools/modules/modules.py generate")

    def check_app(self, manifest):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Banana.app"; app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"BananaModules": "", "CFBundleExecutable": "Banana"}))
            (app / "Banana").write_bytes(b"not a binary")
            (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(manifest))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                return modules.check(app), output.getvalue()

    def test_release_check_refuses_the_full_manifest_in_a_calendar_only_app(self):
        status, output = self.check_app(full_manifest())
        self.assertEqual(status, 1)
        self.assertIn("privacy manifest data type " + T + "Health", output)
        self.assertIn("privacy manifest purpose " + T + "PurposeAppFunctionality", output)

    def test_release_check_accepts_the_derived_manifest(self):
        status, output = self.check_app(modules.derive_privacy(full_manifest(), set()))
        self.assertEqual(status, 0, output)

    def resources_after_build_phase(self, configuration):
        """tools/local-feature-resources.sh, run as the app's last build phase on a bundle that
        holds the full manifest, as Copy Bundle Resources leaves it."""
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Banana.app"; app.mkdir()
            (app / "PrivacyInfo.xcprivacy").write_bytes((ROOT / modules.PRIVACY_MANIFEST[0]).read_bytes())
            env = {**os.environ, "CONFIGURATION": configuration, "SRCROOT": str(ROOT), "ACTION": "build",
                   "TARGET_BUILD_DIR": directory, "UNLOCALIZED_RESOURCES_FOLDER_PATH": "Banana.app"}
            subprocess.run([str(ROOT / "tools/local-feature-resources.sh")], env=env, check=True, capture_output=True)
            return plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())

    def test_app_store_build_bundles_the_derived_manifest(self):
        self.assertEqual(self.resources_after_build_phase("AppStore"),
                         plistlib.loads((ROOT / modules.PRIVACY_MANIFEST[1]).read_bytes()))
        self.assertEqual(self.resources_after_build_phase("TestFlight"), full_manifest())


if __name__ == "__main__":
    unittest.main()
