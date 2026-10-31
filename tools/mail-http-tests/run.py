#!/usr/bin/env python3
"""Run actual Mail Gmail transport sources without a GUI, real credentials or network."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', required=True, type=Path)
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=False)
target = out / 'Tests'
target.mkdir()
sources = ['Banana/Model/Mail/GmailReadWire.swift', 'Banana/Model/Mail/GmailWire.swift', 'Banana/Model/Mail/GmailAPI.swift',
           'Banana/Model/MailApp/GmailHTTP.swift', 'BananaTests/GmailHTTPTests.swift']
identities = {}
for name in sources:
    source = root / name
    shutil.copy2(source, target / source.name)
    identities[name] = hashlib.sha256(source.read_bytes()).hexdigest()
(out / 'source-sha256.json').write_text(json.dumps(identities, indent=2) + '\n')
(out / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MailHTTPChecks", platforms: [.macOS(.v14)],
    targets: [.testTarget(name: "MailHTTPChecks", path: "Tests",
        swiftSettings: [.swiftLanguageMode(.v5)])])
''')
command = ['swift', 'test', '--package-path', str(out), '-c', 'release', '--jobs', '2']
with (out / 'test.log').open('w') as log:
    result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
log = (out / 'test.log').read_text()
counts = [(int(a), int(b)) for a, b in re.findall(r'Executed (\d+) tests?, with (\d+) failures?', log)]
tests = max((a for a, _ in counts), default=0)
required = ['testDirectReadsNormalizeOmittedLabelsButHistoryKeepsThemUnknown', 'testMalformedReadLabelsCannotBecomeAnEmptySet', 'testMalformedListingContinuationCannotEndEnumeration', 'testMalformedHistoryChangesCannotBecomeAnEmptySuccess', 'testMissingLabelDirectoryIsNotAnEmptySuccess', 'testStructuredFailures', 'testBoundedResponses', 'testSearchRequestAndDecode', 'testNetworkGate', 'testExternalBodyPartUsesEscapedAttachmentRoute']
missing = [name for name in required if not re.search(r"Test Case .*" + name + r".* passed", log)]
passed = result.returncode == 0 and tests >= 16 and not missing and not any(b for _, b in counts)
passed = passed and not re.search(r'Test Case .* skipped', log)
(out / 'status.json').write_text(json.dumps({'command': command, 'exitCode': result.returncode,
    'tests': tests, 'missingRequiredTests': missing, 'status': 'pass' if passed else 'fail',
    'scope': 'Pure Gmail transport correctness; no live OAuth or UI acceptance'}, indent=2) + '\n')
print(f'Mail HTTP checks {"pass" if passed else "fail"} ({tests} tests); {out / "test.log"}')
raise SystemExit(0 if passed else 1)
