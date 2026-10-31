#!/usr/bin/env python3
"""Print exact-revision source settings for a reviewed release. Never deploys."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repository', required=True, help='Public GitHub repository HTTPS URL')
parser.add_argument('--revision', default='HEAD', help='Reviewed local commit; defaults to HEAD')
args = parser.parse_args()
url = urlparse(args.repository)
if (any(c.isspace() for c in args.repository) or url.scheme != 'https' or url.netloc != 'github.com' or url.query or url.fragment
        or not re.fullmatch(r'/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/?', url.path)):
    parser.error('use an HTTPS GitHub owner/repository URL, without credentials or query parameters')
if subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain']):
    parser.error('release source must be committed and clean before generating a deployed-version offer')
revision = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--verify', args.revision + '^{commit}'], text=True).strip()
if not re.fullmatch(r'[a-f0-9]{40}', revision):
    parser.error('expected a full Git commit identifier')
print(json.dumps({'SOURCE_REVISION': revision,
                  'SOURCE_ARCHIVE_URL': args.repository.rstrip('/').removesuffix('.git') + '/archive/' + revision + '.tar.gz'}, indent=2))
