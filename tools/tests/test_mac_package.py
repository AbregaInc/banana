import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('mac_package', Path(__file__).parents[1] / 'check-mac-package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class MacPackageTests(unittest.TestCase):
    def test_development_certificate_is_rejected_despite_valid_signature(self):
        allowed = {hashlib.sha256(b'distribution certificate').digest()}
        with self.assertRaisesRegex(ValueError, 'not authorized'):
            package.check_signer('Privacy.bundle', b'development certificate', allowed, True)
        package.check_signer('App.app', b'distribution certificate', allowed)

    def test_unsigned_code_is_rejected_but_unsigned_resources_are_permitted(self):
        with self.assertRaisesRegex(ValueError, 'not authorized'):
            package.check_signer('Helper', None, set())
        package.check_signer('Privacy.bundle', None, set(), True)

    def test_resource_classification_checks_contents_not_just_bundle_suffix(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / 'Probe.bundle'
            contents = bundle / 'Contents'
            contents.mkdir(parents=True)
            info = contents / 'Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.example.resource'}))
            self.assertTrue(package.resource_only(bundle))
            binary = contents / 'hidden-code'
            binary.write_bytes(bytes.fromhex('cffaedfe') + b'fixture')
            self.assertFalse(package.resource_only(bundle))
            binary.unlink()
            info.write_bytes(plistlib.dumps({'CFBundleExecutable': 'Missing'}))
            self.assertFalse(package.resource_only(bundle))


if __name__ == '__main__':
    unittest.main()
