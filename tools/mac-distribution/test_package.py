import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('package', Path(__file__).with_name('package.py'))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class FeedTests(unittest.TestCase):
    def write(self, root, **overrides):
        values = dict(url='https://example.org/releases/2/Banana.dmg', version='2',
                      short_version='1.0', signature=base64.b64encode(bytes(64)).decode(),
                      length=123, notes='Fix <calendar> & picker')
        values.update(overrides)
        path = Path(root) / 'appcast.xml'
        package.write_feed(path, **values)
        return ET.parse(path)

    def test_signed_enclosure_and_escaped_notes(self):
        with tempfile.TemporaryDirectory() as root:
            xml = self.write(root)
            item = xml.find('./channel/item')
            self.assertEqual(item.findtext('description'), 'Fix <calendar> & picker')
            self.assertEqual(item.find('enclosure').get('length'), '123')
            self.assertEqual(item.find('enclosure').get('{'+package.SPARKLE+'}version'), '2')
            self.assertEqual(item.findtext('{'+package.SPARKLE+'}minimumSystemVersion'), '26.0')

    def test_beta_feed_is_named_separately(self):
        with tempfile.TemporaryDirectory() as root:
            xml = self.write(root, app_name='Banana Beta')
            self.assertEqual(xml.findtext('./channel/title'), 'Banana Beta updates')
            self.assertTrue(xml.findtext('./channel/item/title').startswith('Banana Beta '))

    def test_bad_metadata_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            for value in [dict(version='two'), dict(signature='invalid'), dict(url='file:///tmp/app')]:
                with self.subTest(value=value), self.assertRaises(ValueError):
                    self.write(root, **value)


if __name__ == '__main__':
    unittest.main()

class DiskImageLayoutTests(unittest.TestCase):
    def test_layout_uses_the_actual_beta_icon_and_app_name(self):
        import plistlib, runpy
        with tempfile.TemporaryDirectory() as path:
            app = Path(path) / 'Banana Beta.app'
            (app / 'Contents/Resources').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIconFile':'AppIconBeta'}))
            settings = runpy.run_path(str(Path(__file__).with_name('dmg-settings.py')),
                init_globals={'defines':{'app':str(app),'background':str(Path(path)/'background.png')}})
            self.assertTrue(settings['icon'].endswith('AppIconBeta.icns'))
            self.assertIn('Banana Beta.app',settings['icon_locations'])
