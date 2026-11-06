#!/usr/bin/env python3
"""Check the direct download, feed and artifact before deploying Mac download links."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate(site, channel="stable"):
    route = "mac-beta" if channel == "beta" else "mac"
    home = (site / 'index.html').read_text()
    metadata = site / f'updates/{route}/release.json'
    if not metadata.exists() and (channel == 'beta' or 'href="/download/mac"' not in home):
        return None
    release = json.loads(metadata.read_text())
    assert release.get('notarized') is True and release.get('testOnly') is False, 'Not a notarized production release'
    assert release.get('channel', 'stable') == channel
    assert re.fullmatch(r'https://github\.com/AbregaInc/banana/releases/download/' + route + r'-v[0-9.]+-[0-9]+/Banana\.dmg', release['url']), 'Expected an explicit Mac release asset'
    assert re.fullmatch(r'[a-f0-9]{64}', release['sha256']), 'Invalid checksum'
    assert isinstance(release['bytes'], int) and release['bytes'] > 0
    enclosure = ET.parse(site / f'updates/{route}/appcast.xml').find('./channel/item/enclosure')
    assert enclosure is not None
    assert enclosure.get('url') == release['url']
    assert enclosure.get(SPARKLE + 'version') == release['version']
    assert int(enclosure.get('length')) == release['bytes']
    assert len(base64.b64decode(enclosure.get(SPARKLE + 'edSignature'), validate=True)) == 64
    lines = [line.split() for line in (site / '_redirects').read_text().splitlines() if line.strip() and not line.startswith('#')]
    matching = [line for line in lines if line[0] == '/download/' + route]
    assert matching == [['/download/' + route, release['url'], '302']], 'Download redirect does not match release'
    return release


def verify_hosted(release):
    digest = hashlib.sha256(); length = 0
    with urllib.request.urlopen(release['url'], timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk); length += len(chunk)
    assert digest.hexdigest() == release['sha256'] and length == release['bytes'], 'Hosted installer differs from verified release'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('site', type=Path)
    parser.add_argument('--hosted', action='store_true')
    args = parser.parse_args()
    release = validate(args.site)
    beta = validate(args.site, 'beta')
    if beta and args.hosted:
        verify_hosted(beta)
    if release and args.hosted:
        try:
            verify_hosted(release)
        except urllib.error.HTTPError as error:
            raise SystemExit(f"Mac installer is not publicly downloadable (HTTP {error.code}). Keep the site unpublished until the verified GitHub release is public.")
    print('Mac release check passed' if release else 'No direct Mac download configured')
