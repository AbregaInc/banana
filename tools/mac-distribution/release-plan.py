#!/usr/bin/env python3
"""Reserve a release identity locally from a clean commit and existing release numbers.

Does not build, tag, publish, or delete anything. Run one release at a time.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REPO = 'AbregaInc/banana'


def run(*args):
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def clean_commit():
    if run('git', 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Release from a clean committed checkout; preserve unfinished work in this workspace')
    return run('git', 'rev-parse', 'HEAD')


def make_plan(version, current_build, tags, commit, channel="stable", uploaded=(), at_least=None):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Use a three-part user version, such as 1.0.1')
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Expected a full source commit')
    builds = [int(current_build)]
    for tag in tags:
        match = re.fullmatch(r'mac(?:-beta)?-v[0-9.]+-(\d+)', tag)
        if match:
            builds.append(int(match[1]))
    # A build uploaded to App Store Connect without a Mac tag (an App Review fix, the App Store
    # app) has its number taken too. A chosen higher number skips free ones (reserved elsewhere).
    builds += [int(b) for b in uploaded]
    build = max(builds) + 1
    if at_least is not None:
        if int(at_least) < build:
            raise ValueError(f'Build {at_least} is taken; the next free build is {build}')
        build = int(at_least)
    build = str(build)
    if channel not in ('stable', 'beta'): raise ValueError('Unknown release channel')
    tag = f"mac{'-beta' if channel == 'beta' else ''}-v{version}-{build}"
    return {'shortVersion': version, 'version': build, 'sourceCommit': commit,
            'tag': tag, 'baseURL': f'https://github.com/{REPO}/releases/download/{tag}'}


def validate_plan(plan, commit):
    expected = make_plan(plan['shortVersion'], int(plan['version']) - 1, [], commit, plan.get('channel', 'stable'))
    for key, value in expected.items():
        if plan.get(key) != value:
            raise ValueError('Release plan differs from the source checkout or version identity: ' + key)
    if int(plan['version']) < 1:
        raise ValueError('Build must be positive')


def asc_uploaded_builds():
    """Build numbers App Store Connect already has, when its key is configured; none otherwise."""
    if not os.environ.get('ASC_KEY_ID'):
        return []
    import importlib.util
    spec = importlib.util.spec_from_file_location('asc_builds', ROOT / 'tools' / 'asc-builds.py')
    asc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(asc)
    data = asc.get('/v1/builds?sort=-uploadedDate&limit=50&fields[builds]=version')
    return [b['attributes']['version'] for b in data.get('data', []) if b['attributes']['version'].isdigit()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version')
    parser.add_argument('--channel', choices=['stable', 'beta'], default='stable')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--check', type=Path)
    parser.add_argument('--build', help='use this build if it is free (skipping lower free numbers)')
    args = parser.parse_args()
    commit = clean_commit()
    if args.check:
        plan = json.loads(args.check.read_text())
        validate_plan(plan, commit)
        print(plan['sourceCommit'], plan['shortVersion'], plan['version'])
        return
    if not args.version or not args.out:
        parser.error('--version and --out are required to prepare a release')
    pages = json.loads(run('gh', 'api', '--paginate', '--slurp', f'repos/{REPO}/releases?per_page=100'))
    tags = [release['tag_name'] for page in pages for release in page]
    tags += run('git', 'tag', '--list', 'mac*v*').splitlines()
    current = re.search(r'CURRENT_PROJECT_VERSION:\s*"(\d+)"', (ROOT / 'project.yml').read_text())
    plan = make_plan(args.version, current.group(1), tags, commit, args.channel,
                     uploaded=asc_uploaded_builds(), at_least=args.build)
    plan['channel'] = args.channel
    plan['preparedAt'] = datetime.now(timezone.utc).isoformat()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open('x') as output:
        output.write(json.dumps(plan, indent=2) + '\n')
    print(plan['tag'] + ' from ' + commit[:12])


if __name__ == '__main__':
    main()
