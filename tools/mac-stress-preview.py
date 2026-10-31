#!/usr/bin/env python3
"""Build and open an isolated, optimized native Mac stress preview."""
import argparse
import datetime
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--days', type=int, default=30)
parser.add_argument('--require-idle-before-open', type=float, help='Defer opening if Mac HID idle time is below this many seconds; rechecked after building')
parser.add_argument('--built-app', type=Path, help='Use the explicitly supplied already-built stress-review app')
parser.add_argument('--calendar-fixture', choices=['legacy', 'varied-v1'], default='legacy', help='Supplementary varied multi-calendar workload; legacy preserves original comparisons')
parser.add_argument('--calendar-events-per-day', type=int,
                    help='Supplementary varied-v1 capacity search density (1–1000); does not alter the regression workload')
parser.add_argument('--calendar-observation-audit', action='store_true', help='Isolated visible-palette invalidation probe')
parser.add_argument('--calendar-observation-fix', action='store_true', help='Compatibility flag; narrow visible-input invalidation is now the default')
parser.add_argument('--calendar-observation-control', action='store_true', help='Reproduce the previous stale-palette behavior for comparison')
parser.add_argument('--calendar-local-drag', action='store_true', help='Experimental event-local drag feedback')
parser.add_argument('--calendar-local-hover', action='store_true', help='Experimental column-local hover observation')
parser.add_argument('--calendar-cache-layout', action='store_true', help='Experimental prepared overlap layout (also supported on mobile)')
parser.add_argument('--calendar-prepared-artwork', action='store_true', help='Experimental bounded prepared event artwork; not enabled by default')
parser.add_argument('--calendar-artwork-profile', action='store_true', help='Record preparation counters after a ten-second clock probe; inspect Mac redraw coverage separately')
parser.add_argument('--calendar-reference-mac', action='store_true', help='DEBUG comparison: retain the original SwiftUI Calendar scroll host')
parser.add_argument('--calendar-stable-cell-graph', action='store_true', help='Experimental native cell graph reuse; requires state/action parity checks')
parser.add_argument('--calendar-recompute-layout', action='store_true', help='Ablation: recompute overlap layout during view evaluation')
parser.add_argument('--calendar-group-events', action='store_true', help='Compatibility flag; grouped event accessibility is now the default')
parser.add_argument('--calendar-reference-mac-event-accessibility', action='store_true', help='DEBUG comparison: original child event accessibility')
parser.add_argument('--calendar-fail-local-write', action='store_true', help='Isolated pending-event disk-write failure probe; prevents provider writes')
parser.add_argument('--calendar-reuse-columns', action='store_true', help='Experimental stable time-grid column slots')
parser.add_argument('--calendar-grid', choices=['shapes', 'canvas'], default='shapes',
                    help='Explicit native calendar grid ablation; production default remains shapes')
parser.add_argument('--profile', choices=['legacy', 'mail-calendar'], default='legacy',
                    help='mail-calendar: 180k mail, 36.5k events, 5k notes, 20k episodes; legacy preserves regression workload')
args = parser.parse_args()
if not 1 <= args.days <= 365:
    parser.error('days must be in 1...365')
if args.calendar_events_per_day is not None:
    if args.calendar_fixture != 'varied-v1':
        parser.error('--calendar-events-per-day requires --calendar-fixture varied-v1')
    if not 1 <= args.calendar_events_per_day <= 1000:
        parser.error('--calendar-events-per-day must be in 1...1000')
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
# Native copy-on-write clones keep every review binary without duplicating its backing
# storage on APFS. cp falls back to a regular copy on filesystems without clone support.
subprocess.run(['cp', '-cRp', str(source), str(app)], check=True)
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
if args.calendar_fixture == 'varied-v1': workload += ['--stress-calendar-fixture', 'varied-v1']
if args.calendar_events_per_day is not None:
    workload += ['--stress-events-per-day', str(args.calendar_events_per_day)]
if args.calendar_observation_audit: workload.append('--calendar-observation-audit')
if args.calendar_observation_fix: workload.append('--calendar-observation-fix')
if args.calendar_observation_control: workload.append('--calendar-observation-control')
if args.calendar_local_drag: workload.append('--calendar-local-drag')
if args.calendar_local_hover: workload.append('--calendar-local-hover')
if args.calendar_cache_layout: workload.append('--calendar-cache-layout')
if args.calendar_prepared_artwork: workload.append('--calendar-prepared-artwork')
if args.calendar_artwork_profile: workload += ['--calendar-artwork-profile', '--stress-idle-seconds', '10', '--plan']
if args.calendar_recompute_layout: workload.append('--calendar-recompute-layout')
if args.calendar_reference_mac: workload.append('--calendar-reference-mac')
if args.calendar_stable_cell_graph: workload.append('--calendar-stable-cell-graph')
if args.calendar_group_events: workload.append('--calendar-group-events')
if args.calendar_reference_mac_event_accessibility: workload.append('--calendar-reference-mac-event-accessibility')
if args.calendar_fail_local_write: workload.append('--calendar-fail-local-write')
if args.calendar_reuse_columns: workload.append('--calendar-reuse-columns')
if args.calendar_grid == 'canvas': workload.append('--calendar-canvas-grid')
if args.require_idle_before_open is not None:
    raw = subprocess.check_output(['ioreg', '-r', '-c', 'IOHIDSystem', '-d', '1'], text=True)
    match = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', raw)
    idle_seconds = int(match.group(1)) / 1e9 if match else 0
    if idle_seconds < args.require_idle_before_open:
        parser.error(f'Mac recently active ({idle_seconds:.1f}s idle); built preview retained at {app}, not opened')
subprocess.run(['open', '-n', '--env', 'STRESS_INITIAL_PLAN_MODE=week', str(app), '--stdout', str(out / 'app.log'), '--stderr', str(out / 'app-errors.log'),
                '--args', '--ui-audit', '--stress-days', str(args.days), '--stress-measure',
                '--disable-icloud', '--mail-fresh', '--mac-section', 'plan', '-onboardingCompleted', 'YES',
                ] + workload, check=True)
print(f'Preview: {app}')
print(f'Logs: {out}')
print('Wait for Stress ready. The log identifies the isolated data and model-report directory.')
