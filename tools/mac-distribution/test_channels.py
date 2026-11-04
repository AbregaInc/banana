import unittest
from channels import channel_config, validate_identity
from pathlib import Path
import plistlib

class ChannelTests(unittest.TestCase):
    def info(self, channel):
        return {'BananaReleaseChannel':channel, 'CFBundleIdentifier':'org.example.banana'+('.beta' if channel=='beta' else ''),
                'SUFeedURL':'https://bananatheapp.com/'+channel_config(channel)['updates']+'/appcast.xml'}

    def test_cross_channel_feed_and_bundle_are_rejected(self):
        for channel in ['stable','beta']:
            correct=self.info(channel)
            validate_identity(correct,channel)
            other=self.info('beta' if channel=='stable' else 'stable')
            for key in ['SUFeedURL','CFBundleIdentifier','BananaReleaseChannel']:
                with self.subTest(channel=channel,key=key), self.assertRaises(ValueError):
                    validate_identity({**correct,key:other[key]},channel)
        with self.assertRaises(ValueError): channel_config('dev')

    def test_beta_migration_moves_only_beta_root_and_own_preferences(self):
        root=Path(__file__).resolve().parents[2]
        manifest=plistlib.loads((root/'BananaMac/Beta/container-migration.plist').read_bytes())
        self.assertEqual(manifest['Move'],['${ApplicationSupport}/Banana Beta','${Library}/Preferences/${BundleId}.plist'])
        ent=plistlib.loads((root/'BananaMac/BananaMacBetaDirect.entitlements').read_bytes())
        self.assertEqual(ent['com.apple.developer.icloud-container-identifiers'],['$(BANANA_ICLOUD_CONTAINER_BETA)'])
        self.assertNotIn('$(BANANA_ICLOUD_CONTAINER)',str(ent))
        self.assertEqual(ent['com.apple.developer.ubiquity-kvstore-identifier'],'$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)')

    def test_staging_beta_preserves_stable_download_and_feed(self):
        import tempfile, json, hashlib, io, runpy, sys
        from unittest.mock import patch
        root=Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as path:
            base=Path(path); site=base/'site'; release=base/'release'; out=base/'review'
            (site/'updates/mac').mkdir(parents=True); release.mkdir()
            (site/'updates/mac/appcast.xml').write_text('stable feed')
            (site/'_redirects').write_text('/download/mac https://example.com/stable.dmg 302\n')
            payload=b'fixture installer'
            url='https://github.com/example/repo/releases/download/mac-beta-v1.0.3-91/Banana.dmg'
            (release/'release.json').write_text(json.dumps(dict(testOnly=False,notarized=True,channel='beta',
                bundleIdentifier='org.example.banana.beta',url=url,sha256=hashlib.sha256(payload).hexdigest(),bytes=len(payload))))
            (release/'appcast.xml').write_text('<rss><channel><item><enclosure url="'+url+'"/></item></channel></rss>')
            with patch.object(sys,'argv',['stage-site.py','--release',str(release),'--site',str(site),'--out',str(out)]), \
                 patch('urllib.request.urlopen',return_value=io.BytesIO(payload)):
                runpy.run_path(str(root/'stage-site.py'),run_name='__main__')
            self.assertEqual((out/'updates/mac/appcast.xml').read_text(),'stable feed')
            self.assertTrue((out/'updates/mac-beta/appcast.xml').exists())
            redirects=(out/'_redirects').read_text()
            self.assertIn('/download/mac https://example.com/stable.dmg 302',redirects)
            self.assertIn('/download/mac-beta '+url+' 302',redirects)
