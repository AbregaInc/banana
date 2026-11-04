import base64
import json
from pathlib import Path
import tempfile
import unittest
import mac_release


class MacReleaseTests(unittest.TestCase):
    def make_site(self, root):
        site = Path(root); updates = site / 'updates/mac'; updates.mkdir(parents=True)
        (site / 'index.html').write_text('<a href="/download/mac">Download for Mac</a>')
        release = dict(version='86', url='https://github.com/AbregaInc/banana/releases/download/mac-v1.0-86/Banana.dmg',
                       bytes=123, sha256='a'*64, notarized=True, testOnly=False)
        (updates / 'release.json').write_text(json.dumps(release))
        (site / '_redirects').write_text('/download/mac '+release['url']+' 302\n')
        signature = base64.b64encode(bytes(64)).decode()
        (updates / 'appcast.xml').write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><enclosure url="{release["url"]}" length="123" sparkle:version="86" sparkle:edSignature="{signature}" /></item></channel></rss>')
        return site

    def test_consistent_release(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(mac_release.validate(self.make_site(root))['version'], '86')

    def test_rejects_test_unnotarized_and_floating_release(self):
        for change in [dict(testOnly=True), dict(notarized=False), dict(url='https://github.com/AbregaInc/banana/releases/latest/download/Banana.dmg')]:
            with tempfile.TemporaryDirectory() as root:
                site = self.make_site(root); path = site/'updates/mac/release.json'
                data = json.loads(path.read_text()); data.update(change); path.write_text(json.dumps(data))
                with self.assertRaises(AssertionError): mac_release.validate(site)

    def test_wrong_or_duplicate_redirect_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            site = self.make_site(root); path=site/'_redirects'; path.write_text(path.read_text()*2)
            with self.assertRaises(AssertionError): mac_release.validate(site)

    def test_feed_must_match_release(self):
        with tempfile.TemporaryDirectory() as root:
            site=self.make_site(root); path=site/'updates/mac/appcast.xml';path.write_text(path.read_text().replace('length="123"','length="124"'))
            with self.assertRaises(AssertionError): mac_release.validate(site)


if __name__ == '__main__': unittest.main()
