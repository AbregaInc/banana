#!/usr/bin/env python3
"""Build and open an isolated, optimized native Mac stress preview."""
import argparse
import datetime
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--days', type=int, default=30)
parser.add_argument('--built-app', type=Path, help='Use the explicitly supplied already-built stress-review app')
parser.add_argument('--calendar-observation-audit', action='store_true', help='Isolated visible-palette invalidation probe')
parser.add_argument('--calendar-observation-fix', action='store_true', help='Compatibility flag; narrow visible-input invalidation is now the default')
parser.add_argument('--calendar-observation-control', action='store_true', help='Reproduce the previous stale-palette behavior for comparison')
parser.add_argument('--calendar-local-hover', action='store_true', help='Experimental column-local hover observation')
parser.add_argument('--calendar-reuse-columns', action='store_true', help='Experimental stable time-grid column slots')
parser.add_argument('--calendar-grid', choices=['shapes', 'canvas'], default='shapes',
                    help='Explicit native calendar grid ablation; production default remains shapes')
parser.add_argument('--profile', choices=['legacy', 'mail-calendar'], default='legacy',
                    help='mail-calendar: 180k mail, 36.5k events, 5k notes, 20k episodes; legacy preserves regression workload')
args = parser.parse_args()
if not 1 <= args.days <= 365:
    parser.error('days must be in 1...365')
out = ROOT / '.build/mac-stress-previews' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
out.mkdir(parents=True)
bundle_id = 'com.boris.banana.mac.stressreview'
if args.built_app:
    source = args.built_app.resolve()
else:
    dd = ROOT / '.build/macuitest-dd'
    with (out / 'build.log').open('w') as log:
        subprocess.run(['xcodebuild', '-project', 'Banana.xcodeproj', '-scheme', 'BananaMacBeta',
                        '-configuration', 'Release', '-destination', 'platform=macOS,arch=arm64',
                        '-derivedDataPath', str(dd), 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
                        'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG',
                        f'PRODUCT_BUNDLE_IDENTIFIER={bundle_id}', 'CODE_SIGNING_ALLOWED=NO', '-quiet', 'build'],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    source = dd / 'Build/Products/Release/Banana Beta.app'
with (source / 'Contents/Info.plist').open('rb') as f:
    info = plistlib.load(f)
if info['CFBundleIdentifier'] != bundle_id:
    parser.error('requires a dedicated stress-review build, never a production/Beta bundle')
app = out / 'Banana Stress Review.app'
shutil.copytree(source, app, symlinks=True)
info['CFBundleDisplayName'] = 'Banana Stress Review'
info['CFBundleName'] = 'Banana Stress Review'
# A fixture app must not register the normal app's sign-in/deep-link handlers.
info.pop('CFBundleURLTypes', None)
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump(info, f)
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
workload = []
if args.profile == 'mail-calendar':
    workload = ['--stress-mail-days', '90', '--stress-event-days', '365', '--stress-notes', '5000',
                '--stress-podcasts', '100', '--stress-episodes-per-show', '200']
if args.calendar_observation_audit: workload.append('--calendar-observation-audit')
if args.calendar_observation_fix: workload.append('--calendar-observation-fix')
if args.calendar_observation_control: workload.append('--calendar-observation-control')
if args.calendar_local_hover: workload.append('--calendar-local-hover')
if args.calendar_reuse_columns: workload.append('--calendar-reuse-columns')
if args.calendar_grid == 'canvas': workload.append('--calendar-canvas-grid')
subprocess.run(['open', '-n', str(app), '--stdout', str(out / 'app.log'), '--stderr', str(out / 'app-errors.log'),
                '--args', '--ui-audit', '--stress-days', str(args.days), '--stress-measure',
                '--disable-icloud', '--mail-fresh', '--mac-section', 'plan', '-onboardingCompleted', 'YES',
                '-planMode', 'week'] + workload, check=True)
print(f'Preview: {app}')
print(f'Logs: {out}')
print('Wait for Stress ready. The log identifies the isolated data and model-report directory.')
