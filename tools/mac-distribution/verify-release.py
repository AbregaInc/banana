#!/usr/bin/env python3
"""Verify direct-release identity, capability coverage, and update configuration."""
import argparse
import fnmatch
import plistlib
from pathlib import Path
import subprocess


def validate(info, entitlements, profile):
    team = info['BananaTeamID']
    identifier = info['CFBundleIdentifier']
    app_id = team + '.' + identifier
    allowed = profile['Entitlements']
    assert profile.get('ProvisionsAllDevices') is True, 'Not a Developer ID distribution profile'
    assert team in profile['TeamIdentifier'], 'Signing team mismatch'
    assert entitlements['com.apple.application-identifier'] == app_id, 'Application identity mismatch'
    assert entitlements['com.apple.developer.team-identifier'] == team, 'Entitlement team mismatch'
    for key, expected in {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.network.client': True,
        'com.apple.security.network.server': True,
        'com.apple.developer.weatherkit': True,
        'com.apple.developer.usernotifications.time-sensitive': True,
        'com.apple.developer.aps-environment': 'production',
        'com.apple.developer.icloud-container-environment': 'Production',
    }.items():
        assert entitlements.get(key) == expected, 'Missing or wrong capability: ' + key
    assert app_id in entitlements['keychain-access-groups'], 'Primary keychain group missing'
    assert info['BananaCloudContainer'] in entitlements['com.apple.developer.icloud-container-identifiers']
    assert 'CloudKit' in entitlements['com.apple.developer.icloud-services']
    # Security sandbox permissions do not need a provisioning-profile grant.
    for key, value in entitlements.items():
        if key.startswith('com.apple.security.'):
            continue
        assert key in allowed, 'Capability absent from profile: ' + key
        grant = allowed[key]
        if isinstance(value, list):
            assert all(any(fnmatch.fnmatchcase(str(v), str(g)) for g in grant) for v in value), key
        elif isinstance(value, str) and isinstance(grant, str):
            assert fnmatch.fnmatchcase(value, grant), key
        else:
            assert value == grant, key
    assert info.get('SUFeedURL') == 'https://bananatheapp.com/updates/mac/appcast.xml'
    assert info.get('SUPublicEDKey'), 'Missing update public key'
    assert info.get('SUEnableAutomaticChecks') and info.get('SUAutomaticallyUpdate')
    assert 'com.apple.security.cs.disable-library-validation' not in entitlements
    assert 'com.apple.security.get-task-allow' not in entitlements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    app = args.app
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    entitlements = plistlib.loads(subprocess.run(
        ['codesign', '-d', '--entitlements', ':-', str(app)], capture_output=True, check=True).stdout)
    profile = plistlib.loads(subprocess.run(
        ['security', 'cms', '-D', '-i', str(app / 'Contents/embedded.provisionprofile')],
        capture_output=True, check=True).stdout)
    validate(info, entitlements, profile)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True, check=True)
    assert (app / 'Contents/Resources/container-migration.plist').is_file(), 'Missing native migration manifest'
    print('PASS: Developer ID profile, app identity, sandbox, keychain group, production cloud/push, WeatherKit, updater and migration manifest')


if __name__ == '__main__':
    main()
