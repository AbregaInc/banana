import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('verify-release.py'))
release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)


class ReleaseEntitlementTests(unittest.TestCase):
    def fixtures(self):
        team = 'TESTTEAM'; bundle = 'org.example.banana'
        info = dict(BananaTeamID=team, CFBundleIdentifier=bundle, BananaCloudContainer='iCloud.org.example.banana',
                    SUFeedURL='https://bananatheapp.com/updates/mac/appcast.xml', SUPublicEDKey='fixture-public-key',
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True)
        ent = {'com.apple.application-identifier': team+'.'+bundle, 'com.apple.developer.team-identifier': team,
               'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True,
               'com.apple.security.network.server': True, 'com.apple.developer.weatherkit': True,
               'com.apple.developer.usernotifications.time-sensitive': True,
               'com.apple.developer.aps-environment': 'production',
               'com.apple.developer.icloud-container-environment': 'Production',
               'keychain-access-groups': [team+'.'+bundle],
               'com.apple.developer.icloud-container-identifiers': [info['BananaCloudContainer']],
               'com.apple.developer.icloud-services': ['CloudKit']}
        grants = copy.deepcopy(ent); grants['keychain-access-groups'] = [team+'.*']
        return info, ent, {'ProvisionsAllDevices': True, 'TeamIdentifier': [team], 'Entitlements': grants}

    def test_valid_profile_with_wildcard_keychain_grant(self):
        release.validate(*self.fixtures())

    def test_rejects_lost_capabilities_and_unsafe_identity(self):
        for key, value in [('com.apple.developer.weatherkit', False),
                           ('com.apple.developer.aps-environment', 'development'),
                           ('com.apple.developer.icloud-container-environment', 'Development'),
                           ('keychain-access-groups', ['TESTTEAM.different']),
                           ('com.apple.security.app-sandbox', False),
                           ('com.apple.security.cs.disable-library-validation', True)]:
            info, ent, profile = self.fixtures(); ent[key] = value
            with self.subTest(key=key), self.assertRaises(AssertionError): release.validate(info, ent, profile)

    def test_profile_cannot_omit_app_capability(self):
        info, ent, profile = self.fixtures()
        del profile['Entitlements']['com.apple.developer.weatherkit']
        with self.assertRaises(AssertionError): release.validate(info, ent, profile)

    def test_test_feed_cannot_be_released(self):
        info, ent, profile = self.fixtures(); info['SUFeedURL'] = 'http://example.test/appcast.xml'
        with self.assertRaises(AssertionError): release.validate(info, ent, profile)


if __name__ == '__main__': unittest.main()
