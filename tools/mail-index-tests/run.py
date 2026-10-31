#!/usr/bin/env python3
"""Compile actual Mail index/store sources with the project-pinned GRDB and run disk paging checks."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'tools'))
from performance_host import HostMonitor
pin = 'b83108d10f42680d78f23fe4d4d80fc88dab3212'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--grdb-checkout', type=Path)
parser.add_argument('--swiftsoup-checkout', type=Path)
parser.add_argument('--scratch-path', type=Path, help='Reuse disposable compiler products; do not share with a concurrent run')
args = parser.parse_args()
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=False)
target = out / 'Tests'
target.mkdir()
sources = sorted((root / 'Banana/Model/Mail').glob('*.swift')) + [root / "Banana/Model/LiveFilter.swift"]
sources += [root / 'BananaTests' / (name + '.swift') for name in ['MailReadBackoffTests', 'MailAccessLifecycleTests', 'GmailMailboxSyncTests', 'MailSyncFillTests', 'MailSyncCheckpointTests', 'MailRemovalCoordinatorTests', 'GmailVerificationSyncTests', 'MailVerificationIndexTests', 'GmailReconcileSyncTests', 'MailReconcileIndexTests', 'GmailHistorySyncTests', 'MailHistoryIndexTests', 'MailRemovalRulesTests', 'MailHistoryRulesTests', 'GmailWireTests', 'MailIndexSchemaTests', 'MailIndexReaderTests', 'MailIndexWriterTests', 'MailMessageImporterTests', 'MailMIMETests', 'MailBlobStoreTests', 'MailHTMLPreparerTests', 'GmailPageLoaderTests', 'MailLiveSourceTests', 'MailLocalSearchTests', 'MailLocalSearchReference', 'MailConversationReaderTests', 'GmailConversationLoaderTests', 'MailIntentStoreTests', 'OutboxRulesTests', 'GmailIntentDeliveryTests', 'MailActionCoordinatorTests', 'MailLabelCatalogTests']]
identities = {}
for source in sources:
    destination = target / source.name
    if destination.exists():
        raise SystemExit(f'Duplicate source filename: {source.name}')
    shutil.copy2(source, destination)
    identities[str(source.relative_to(root))] = hashlib.sha256(source.read_bytes()).hexdigest()
dependency = f'.package(url: "https://github.com/groue/GRDB.swift.git", revision: "{pin}")'
if args.grdb_checkout:
    checkout = args.grdb_checkout.resolve()
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    clean = subprocess.run(['git', '-C', str(checkout), 'diff', '--quiet', 'HEAD']).returncode == 0
    if revision != pin or not clean:
        raise SystemExit('Local GRDB must match the clean project-pinned revision')
    dependency = f'.package(path: {json.dumps(str(checkout))})'
soup_pin = '18b80329749eca5ea29fc50211dca5c7eff5bfec'
soup_dependency = f'.package(url: "https://github.com/scinfu/SwiftSoup.git", revision: "{soup_pin}")'
if args.swiftsoup_checkout:
    checkout = args.swiftsoup_checkout.resolve()
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    clean = subprocess.run(['git', '-C', str(checkout), 'diff', '--quiet', 'HEAD']).returncode == 0
    if revision != soup_pin or not clean:
        raise SystemExit('Local SwiftSoup must match the clean project-pinned revision')
    soup_dependency = f'.package(path: {json.dumps(str(checkout))})'
(out / 'source-sha256.json').write_text(json.dumps(identities, indent=2) + '\n')
(out / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MailIndexChecks", platforms: [.macOS(.v14)],
    dependencies: [DEPENDENCY, SOUP_DEPENDENCY],
    targets: [.testTarget(name: "MailIndexChecks", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), .product(name: "SwiftSoup", package: "SwiftSoup")],
        path: "Tests", swiftSettings: [.swiftLanguageMode(.v5)])])
'''.replace('SOUP_DEPENDENCY', soup_dependency).replace('DEPENDENCY', dependency))
command = ['swift', 'test', '--package-path', str(out), '-c', 'release', '--jobs', '2']
if args.scratch_path:
    command += ['--scratch-path', str(args.scratch_path.resolve())]
# Compilation is part of preparation, not a competing measurement workload.
# Keep it outside the monitor, then run exactly the built test bundle.
build_command = ['swift', 'build', '--build-tests', *command[2:]]
with (out / 'build.log').open('w') as log:
    build = subprocess.run(build_command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
if build.returncode:
    (out / 'status.json').write_text(json.dumps({'buildCommand': build_command,
        'exitCode': build.returncode, 'tests': 0, 'status': 'unmeasured',
        'reason': 'Test build failed'}, indent=2) + '\n')
    raise SystemExit(2)
command += ['--skip-build']
with (out / 'test.log').open('w') as log:
    environment = dict(os.environ, MAIL_RECONCILE_STATEMENTS_OUTPUT=str(out / "reconcile-statements.json"), MAIL_REMOVAL_REVIEW_BENCHMARK_OUTPUT=str(out / 'removal-review-benchmark.json'), MAIL_VERIFICATION_BENCHMARK_OUTPUT=str(out / 'verification-benchmark.json'), MAIL_RECONCILE_BENCHMARK_OUTPUT=str(out / 'reconcile-benchmark.json'), MAIL_HISTORY_INDEX_BENCHMARK_OUTPUT=str(out / 'history-index-benchmark.json'), MAIL_HISTORY_BENCHMARK_OUTPUT=str(out / 'history-benchmark.json'), MAIL_IMPORT_BENCHMARK_OUTPUT=str(out / 'import-benchmark.json'), MAIL_ACTION_BENCHMARK_OUTPUT=str(out / 'action-benchmark.json'), MAIL_SEARCH_BENCHMARK_OUTPUT=str(out / 'search-benchmark.json'), MAIL_INDEX_BENCHMARK_OUTPUT=str(out / 'benchmark.json'), MAIL_MIME_BENCHMARK_OUTPUT=str(out / 'mime-benchmark.json'), MAIL_HTML_BENCHMARK_OUTPUT=str(out / 'html-benchmark.json'))
    process = subprocess.Popen(command, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT)
    with HostMonitor(out / 'host.json', workload_pid=process.pid):
        exit_code = process.wait()
log = (out / 'test.log').read_text()
counts = [(int(a), int(b)) for a, b in re.findall(r'Executed (\d+) tests?, with (\d+) failures?', log)]
tests = max((a for a, _ in counts), default=0)
passed = exit_code == 0 and tests >= 237 and not any(b for _, b in counts)
passed = passed and not re.search(r'Test Case .* skipped', log)
(out / 'status.json').write_text(json.dumps({'buildCommand': build_command, 'command': command, 'exitCode': exit_code,
    'tests': tests, 'status': 'pass' if passed else 'fail', 'grdbRevision': pin, 'swiftSoupRevision': soup_pin,
    'scope': 'Real disk index correctness; not integrated UI or performance acceptance'}, indent=2) + '\n')
print(f'Mail index checks {"pass" if passed else "fail"} ({tests} tests); {out / "test.log"}')
raise SystemExit(0 if passed else 1)
