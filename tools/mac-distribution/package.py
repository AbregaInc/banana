#!/usr/bin/env python3
"""Package an exported app, sign its update, and write a Sparkle appcast.

Release mode requires Developer ID, hardened runtime, notarization and Gatekeeper.
Test mode only accepts the isolated installer-test app. --notarize-test signs and
notarizes it with Developer ID; plain --test is only an ad-hoc development artifact.
"""
from channels import channel_config, validate_identity
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def write_feed(path, *, url, version, short_version, signature, length, notes, app_name="Banana"):
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version):
        raise ValueError('Build version must be numeric')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Expected an Ed25519 signature')
    if urllib.parse.urlparse(url).scheme not in ('http', 'https'):
        raise ValueError('Expected an HTTP(S) download URL')
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = app_name + ' updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'{app_name} {short_version} ({version})'
    ET.SubElement(item, 'description').text = notes
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '26.0'
    ET.SubElement(item, 'enclosure', {
        'url': url, 'length': str(length), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}version': version,
        f'{{{SPARKLE}}}shortVersionString': short_version,
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(rss)
    path.write_bytes(ET.tostring(rss, encoding='utf-8', xml_declaration=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--channel', choices=['stable', 'beta'], default='stable')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--sparkle-bin', type=Path, required=True)
    parser.add_argument('--key-file', type=Path)
    parser.add_argument('--key-account', default='banana-direct')
    parser.add_argument('--test', action='store_true')
    parser.add_argument('--notarize-test', action='store_true', help='Developer ID sign and notarize the isolated rehearsal')
    parser.add_argument('--test-version', help='Numeric build number for the isolated test')
    parser.add_argument('--notary-key', default=os.getenv('ASC_KEY_PATH'))
    parser.add_argument('--notary-key-id', default=os.getenv('ASC_KEY_ID'))
    parser.add_argument('--notary-issuer', default=os.getenv('ASC_ISSUER_ID'))
    parser.add_argument('--notary-profile', default=os.getenv('BANANA_NOTARY_PROFILE'))
    parser.add_argument('--identity', default=os.getenv('BANANA_DEVELOPER_ID_IDENTITY'))
    parser.add_argument('--notes', default='Local installer and update rehearsal.')
    args = parser.parse_args()
    notary_auth = (['--key', args.notary_key, '--key-id', args.notary_key_id, '--issuer', args.notary_issuer]
                   if all([args.notary_key, args.notary_key_id, args.notary_issuer])
                   else ['--keychain-profile', args.notary_profile] if args.notary_profile else [])
    if args.notarize_test and (not args.test or not args.identity or not notary_auth):
        parser.error('--notarize-test requires --test, --identity and --notary-profile')
    notarize = not args.test or args.notarize_test
    source = args.app.resolve()
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if args.test:
        if info['CFBundleIdentifier'] != 'org.banana.installer-test':
            parser.error('Test packaging only accepts the isolated installer-test bundle')
    else:
        if not re.fullmatch(r'[0-9a-f]{40}', info.get('BananaSourceCommit', '')):
            parser.error('Production app must carry its clean source commit; build using a release plan')
        config = validate_identity(info, args.channel)
        expected_base = f"https://github.com/AbregaInc/banana/releases/download/{config['tag']}{info['CFBundleShortVersionString']}-{info['CFBundleVersion']}"
        if args.base_url.rstrip('/') != expected_base:
            parser.error('Download URL must match the app version and build number')
        if args.test_version or info['CFBundleIdentifier'] == 'org.banana.installer-test':
            parser.error('Test app/version cannot be released')
        if not args.base_url.startswith('https://') or not notary_auth or not args.identity:
            parser.error('Release requires HTTPS, Developer ID identity and a notary keychain profile')
        run('python3', ROOT / 'tools/mac-distribution/verify-release.py', source)
        run('codesign', '--verify', '--deep', '--strict', source)
        details = run('codesign', '-dv', '--verbose=4', source, capture_output=True).stderr.decode()
        if 'Authority=Developer ID Application:' not in details or 'runtime' not in details:
            parser.error('Export with Developer ID and hardened runtime first')
        if not (source / 'Contents/embedded.provisionprofile').is_file():
            parser.error('Missing Developer ID provisioning profile for cloud capabilities')
    if args.key_file:
        seed = base64.b64decode(args.key_file.expanduser().read_bytes(), validate=True)
        if len(seed) != 32:
            parser.error('Key files must contain a base64-encoded 32-byte Ed25519 seed')
        der = bytes.fromhex('302e020100300506032b657004220420') + seed
        public = run('openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER',
                     input=der, capture_output=True).stdout[-32:]
        signing_public = base64.b64encode(public).decode()
    else:
        signing_public = run(args.sparkle_bin / 'generate_keys', '--account', args.key_account,
                             '-p', capture_output=True).stdout.decode().strip()
    if signing_public != info.get('SUPublicEDKey'):
        parser.error('Signing key does not match the public key embedded in this app')
    version = args.test_version or info['CFBundleVersion']
    if not re.fullmatch(r'[1-9][0-9]*', version):
        parser.error('Build version must be a positive integer')
    short = info['CFBundleShortVersionString']
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    dmg = out / ('Banana-Installer-Test-' + version + '.dmg' if args.test else 'Banana-Beta.dmg' if args.channel == 'beta' else 'Banana.dmg')
    if dmg.exists():
        parser.error('Refusing to overwrite an existing versioned installer')
    with tempfile.TemporaryDirectory(prefix='banana-dmg-') as tmp:
        stage = Path(tmp) / 'stage'
        stage.mkdir()
        app = stage / source.name
        run('ditto', source, app)
        if args.test_version:
            p = app / 'Contents/Info.plist'
            d = plistlib.loads(p.read_bytes())
            d['CFBundleVersion'] = version
            p.write_bytes(plistlib.dumps(d))
            # No nested code was modified; re-sign only the outer test bundle.
            run('codesign', '--force', '--sign', '-', '--options', 'runtime',
                '--entitlements', ROOT / 'BananaMac/InstallerTest.entitlements', app)
        if args.notarize_test:
            framework = app / 'Contents/Frameworks/Sparkle.framework'
            binary_root = framework / 'Versions/B'
            for component in ['XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc',
                              'Autoupdate', 'Updater.app']:
                run('codesign', '--force', '--sign', args.identity, '--options', 'runtime',
                    '--timestamp', '--preserve-metadata=entitlements', binary_root / component)
            run('codesign', '--force', '--sign', args.identity, '--options', 'runtime',
                '--timestamp', framework)
            entitlements = plistlib.loads((ROOT / 'BananaMac/InstallerTest.entitlements').read_bytes())
            entitlements.pop('com.apple.security.cs.disable-library-validation', None)
            entitlements_file = Path(tmp) / 'Test.entitlements'
            entitlements_file.write_bytes(plistlib.dumps(entitlements))
            run('codesign', '--force', '--sign', args.identity, '--options', 'runtime',
                '--timestamp', '--entitlements', entitlements_file, app)
            run('codesign', '--verify', '--deep', '--strict', app)
        if notarize:
            # Staple the app before putting it inside the disk image.
            archive = Path(tmp) / 'Banana.zip'
            run('ditto', '-c', '-k', '--keepParent', app, archive)
            run('xcrun', 'notarytool', 'submit', archive, *notary_auth, '--wait')
            run('xcrun', 'stapler', 'staple', app)
            run('xcrun', 'stapler', 'validate', app)
            run('spctl', '--assess', '--type', 'execute', '--verbose', app)
        (stage / 'Applications').symlink_to('/Applications')
        (stage / 'Read Me.txt').write_text(
            'Drag the app to Applications, then open it.\n' +
            ('LOCAL TEST ONLY. Separate app and data from Banana.\n'
             'Install this build, then use Banana Installer Test > Check for Updates for the next build.\n'
             if args.test else f'Updates are available from {"Banana Beta" if args.channel == "beta" else "Banana"} > Check for Updates.\n'))
        if args.test:
            run('hdiutil', 'create', '-volname', 'Banana Installer Test',
                '-srcfolder', stage, '-format', 'UDZO', dmg)
        else:
            # Writes Finder metadata directly; no AppleScript or desktop interaction.
            run('uv', 'tool', 'run', '--from', 'dmgbuild==1.6.7', 'dmgbuild',
                '-s', ROOT / 'tools/mac-distribution/dmg-settings.py',
                '-D', 'app=' + str(app),
                '-D', 'background=' + str(ROOT / 'tools/mac-distribution/artwork/background.png'),
                'Banana Beta' if args.channel == 'beta' else 'Banana', dmg)
    if notarize:
        run('codesign', '--sign', args.identity, '--timestamp', dmg)
        run('xcrun', 'notarytool', 'submit', dmg, *notary_auth, '--wait')
        run('xcrun', 'stapler', 'staple', dmg)
        run('xcrun', 'stapler', 'validate', dmg)
        run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)
    sign = [args.sparkle_bin / 'sign_update']
    sign += ['--ed-key-file', args.key_file] if args.key_file else ['--account', args.key_account]
    signature = run(*sign, '-p', dmg, capture_output=True).stdout.decode().strip()
    run(*sign, '--verify', dmg, signature)
    url = args.base_url.rstrip('/') + '/' + urllib.parse.quote(dmg.name)
    write_feed(out / 'appcast.xml', url=url, version=version, short_version=short,
               signature=signature, length=dmg.stat().st_size, notes=args.notes,
               app_name="Banana Beta" if args.channel == "beta" else "Banana")
    digest = hashlib.file_digest(dmg.open('rb'), 'sha256').hexdigest()
    (out / (dmg.name + '.sha256')).write_text(f'{digest}  {dmg.name}\n')
    (out / 'release.json').write_text(json.dumps({
        'version': version, 'shortVersion': short, 'url': url, 'sha256': digest,
        'bytes': dmg.stat().st_size, 'testOnly': args.test, 'notarized': notarize,
        'bundleIdentifier': info['CFBundleIdentifier'], 'channel': args.channel,
        'sourceCommit': info.get('BananaSourceCommit'),
    }, indent=2) + '\n')
    print(dmg)


if __name__ == '__main__':
    main()
