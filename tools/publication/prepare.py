#!/usr/bin/env python3
"""Prepare a private whole-source candidate; never publish or rewrite source history.

Preserves original sources/evidence. Omits generated submission material, internal
raw captures/logs, and the unapproved blog draft. Retains benchmark narratives,
the article's matched comparison, baselines, fixtures and all application code.
The output is a review candidate, not an automatic publication approval.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
COMPARISONS = {
    'docs/performance/scale-results/calendar-native-day-20261010/preparation-comparison.json',
    'docs/performance/scale-results/calendar-native-week-20261010/preparation-comparison.json',
}


def omission(path):
    if path.startswith(('AppStore/Generated/', 'docs/blog/calendar-renderer/drafts/')):
        return 'Generated submission material or unapproved local editorial draft; retained privately'
    if path.startswith(('Mockups/', 'LandingPage/assets/screenshots/')) and Path(path).suffix.lower() in {'.png', '.jpg', '.jpeg', '.webp', '.mp4', '.heic'}:
        return 'Historical raw mockup/marketing capture; source mockups and published website assets retained'
    if path.startswith('docs/performance/scale-results/'):
        if path.endswith('.md') or path in COMPARISONS:
            return None
        return 'Raw experimental artifact retained privately; public run narratives and selected numeric evidence retained'
    if path.startswith('docs/') and Path(path).suffix.lower() in {
        '.log', '.png', '.jpg', '.jpeg', '.webp', '.mp4', '.gz', '.pdf', '.heic'
    }:
        return 'Internal raw capture/log; retained privately, not required application source'
    return None


def normalize_text(text):
    # Display normalization only. Do not alter measurements, sample arrays,
    # thresholds, hashes, fixture identities, failure states or library versions.
    text = re.sub(r'/Users/[^/\s"\x27]+/', '/Users/developer/', text)
    return re.sub(r'\b00008[0-9A-F]{3}-[0-9A-F]{16}\b', '<physical-device-id>', text)


def normalize_comparison(data):
    rows = json.loads(data)
    for row in rows:
        device = row.get('identity', {}).get('device', {})
        for key in ['udid', 'name', 'dataPath', 'logPath', 'lastUsedAt', 'dataPathSize', 'logPathSize']:
            device.pop(key, None)
    return (json.dumps(rows, indent=2) + '\n').encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--refresh', action='store_true', help='Refresh an existing private candidate, preserving unchanged files/builds')
    args = parser.parse_args()
    out = args.output.expanduser().resolve()
    if out == ROOT or ROOT in out.parents or (out.exists() and not args.refresh):
        parser.error('output must be new and outside the source repository')
    if out.exists() and (not (out / 'PUBLICATION-PROVENANCE.json').is_file()
                         or json.loads((out / 'PUBLICATION-PROVENANCE.json').read_text()).get('status') != 'private-review-candidate'):
        parser.error('refresh requires a recognized private candidate')
    out.mkdir(parents=True, mode=0o700, exist_ok=args.refresh)
    os.chmod(out, 0o700)
    paths = sorted(set(p for p in subprocess.check_output(
        ['git', '-C', str(ROOT), 'ls-files', '--cached', '--others', '--exclude-standard', '-z']
    ).decode().split('\0') if p))
    included, omitted = [], []
    for path in paths:
        source = ROOT / path
        components = [source, *list(source.parents)[:len(Path(path).parts) - 1]]
        if any(p.is_symlink() for p in components) or not source.is_file():
            raise ValueError('Missing or symlinked input requires review: ' + path)
        data = source.read_bytes()
        original_hash = hashlib.sha256(data).hexdigest()
        reason = omission(path)
        if reason:
            omitted.append({'path': path, 'sha256': hashlib.sha256(data).hexdigest(), 'reason': reason})
            # Remove only a derived candidate copy whose private source still
            # exists. The original workspace/history and raw evidence stay put.
            previous = out / path
            if args.refresh and previous.is_file():
                previous.unlink()
            continue
        normalized = False
        if path.startswith('docs/') and b'\0' not in data:
            text = data.decode('utf-8')
            new = normalize_text(text).encode('utf-8')
            normalized = new != data
            data = new
        if path in COMPARISONS:
            data = normalize_comparison(data)
            normalized = data != source.read_bytes()
        target = out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or target.read_bytes() != data:
            target.write_bytes(data)
        target.chmod(source.stat().st_mode & 0o777)
        included.append({'path': path, 'sha256': hashlib.sha256(data).hexdigest(),
                         'originalSHA256': original_hash,
                         'normalizedDisplayMetadata': normalized})
    manifest = {
        'status': 'private-review-candidate', 'publicationApproved': False,
        'sourceRevision': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']).decode().strip(),
        'includesUncommittedChanges': bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain'])),
        'originalHistoryPreserved': True, 'included': included, 'omitted': omitted,
        'note': 'Omissions are archival artifacts, not application modules. No failed-run narrative, budget, baseline or retained measurement has been changed to obtain a pass. Review residual metadata/media and rights before publication.',
    }
    (out / 'PUBLICATION-PROVENANCE.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'included': len(included), 'omittedArchivalArtifacts': len(omitted),
                      'output': str(out), 'publicationApproved': False}, indent=2))


if __name__ == '__main__':
    main()
