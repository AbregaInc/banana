#!/bin/bash
# Real native UI actions against the isolated running stress preview, not the user's Beta.
# User authorization to drive the desktop is required. This script never changes Automation Mode.
set -euo pipefail
cd "$(dirname "$0")/.."
automation_state="$(automationmodetool 2>&1 || true)"
if DevToolsSecurity -status 2>&1 | grep -qi disabled; then
  echo 'UNMEASURED: macOS Developer Mode is disabled; native XCTest needs debugger authorization.' >&2
  exit 2
fi
if printf '%s' "$automation_state" | grep -qi disabled && ! printf '%s' "$automation_state" | grep -q 'DOES NOT REQUIRE'; then
  echo 'UNMEASURED: macOS Automation Mode is disabled and requires user authentication.' >&2
  exit 2
fi
out=".build/native-ui-performance/uitests-$(date +%Y%m%d-%H%M%S)"
mkdir "$out"
xcodegen generate > "$out/generate.log"
xcodebuild build-for-testing -project Banana.xcodeproj -scheme BananaNativePerformanceUITests \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/native-ui-test-dd ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  > "$out/build.log" 2>&1
# Bound runner-startup hangs as well as test execution. Retain the log/result on failure.
python3 - "$out" "$@" <<'PYTEST'
import os, signal, subprocess, sys
from pathlib import Path
out = Path(sys.argv[1])
if required_idle := os.environ.get('BANANA_NATIVE_REQUIRE_IDLE_SECONDS'):
    import re
    raw = subprocess.check_output(['ioreg', '-r', '-c', 'IOHIDSystem', '-d', '1'], text=True)
    match = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', raw)
    idle_seconds = int(match.group(1)) / 1e9 if match else 0
    (out / 'idle-before-tests.txt').write_text(f'{idle_seconds:.3f} seconds; required {required_idle}\n')
    if idle_seconds < float(required_idle):
        raise SystemExit('Mac recently active; native test build retained, visible interaction deferred')
command = ['xcodebuild', 'test-without-building', '-project', 'Banana.xcodeproj',
           '-scheme', 'BananaNativePerformanceUITests', '-configuration', 'Release',
           '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', '.build/native-ui-test-dd',
           '-resultBundlePath', str(out / 'ui.xcresult'), '-parallel-testing-enabled', 'NO',
           '-collect-test-diagnostics', 'never']
if len(sys.argv) == 2:
    command.append('-only-testing:BananaNativePerformanceUITests/NativeInteractionTests')
for test in sys.argv[2:]:
    if not test.startswith(('NativeInteractionTests/', 'CalendarPrototypeInteractionTests/',
                            'CalendarLargeEventIntegrationTests/')):
        raise SystemExit('Optional filters must name a test in NativeInteractionTests, CalendarPrototypeInteractionTests or CalendarLargeEventIntegrationTests')
    command.append('-only-testing:BananaNativePerformanceUITests/' + test)
with (out / 'test.log').open('w') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = process.wait(timeout=300)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGINT)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
        (out / 'blocked.txt').write_text('UNMEASURED: native XCTest exceeded 300 seconds; inspect retained runner logs.\n')
        code = 2
raise SystemExit(code)
PYTEST
printf 'Functional native interaction results: %s/ui.xcresult\n' "$out"
printf 'Run tools/native-ui-trace.py alongside these interactions for commit-work measurements.\n'
