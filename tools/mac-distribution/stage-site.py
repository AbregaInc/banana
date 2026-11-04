#!/usr/bin/env python3
"""Prepare website download routing after a versioned release asset is online.

Writes to a review directory only. It does not publish GitHub assets or deploy the site.
"""
from channels import channel_config
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--release', type=Path, required=True)
p.add_argument('--site', type=Path, default=Path('LandingPage/site'))
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
release = json.loads((a.release / 'release.json').read_text())
if release['testOnly'] or not release.get('notarized'):
    p.error('A test installer cannot be staged for the public website')
channel = release.get('channel', 'stable')
config = channel_config(channel)
if release.get('bundleIdentifier', '').endswith('.beta') != (channel == 'beta'):
    p.error('Release channel and bundle identity differ')
url = urllib.parse.urlparse(release['url'])
if url.scheme != 'https' or url.hostname != 'github.com' or '/releases/download/' not in url.path:
    p.error('Expected an explicit HTTPS GitHub Releases asset URL')
feed = ET.parse(a.release / 'appcast.xml')
enclosure = feed.find('./channel/item/enclosure')
if enclosure is None or enclosure.get('url') != release['url']:
    p.error('Appcast and download metadata do not agree')
# Never expose a button until the actual public asset is available and matches.
digest = hashlib.sha256()
length = 0
with urllib.request.urlopen(release['url'], timeout=60) as response:
    while chunk := response.read(1024 * 1024):
        digest.update(chunk)
        length += len(chunk)
if digest.hexdigest() != release['sha256'] or length != release['bytes']:
    p.error('Hosted asset does not match the verified installer')
if a.out.exists():
    p.error('Choose a new review directory; existing work is preserved')
shutil.copytree(a.site, a.out)
updates = a.out / config['updates']
updates.mkdir(parents=True, exist_ok=True)
shutil.copyfile(a.release / 'appcast.xml', updates / 'appcast.xml')
public_metadata = {key: value for key, value in release.items() if key != 'bundleIdentifier'}
(updates / 'release.json').write_text(json.dumps(public_metadata, indent=2) + '\n')
redirects = a.out / '_redirects'
lines = redirects.read_text().splitlines() if redirects.exists() else []
lines = [line for line in lines if not line.split() or line.split()[0] != config['download']]
lines.append(config['download'] + ' ' + release['url'] + ' 302')
redirects.write_text('\n'.join(lines) + '\n')
headers = a.out / '_headers'
text = headers.read_text() if headers.exists() else ''
feed_path = '/' + config['updates'] + '/appcast.xml'
if feed_path not in text:
    text += f'\n{feed_path}\n  Cache-Control: no-cache\n{config["download"]}\n  Cache-Control: no-cache\n'
headers.write_text(text)
print(f'Staged download redirect and update feed in {a.out}. Review before deployment.')
