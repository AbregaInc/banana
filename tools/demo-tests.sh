#!/bin/zsh
# Reproducible demo checks; call serially, after reserving the canonical simulator.
set -eu
cd "$(dirname "$0")/.."
mode="${1:-models}"
device="${2:-phone}"
case "$mode" in models|ui) ;; *) echo "usage: $0 [models|ui] [phone|pad]"; exit 2;; esac
case "$device" in
  phone) demo_udid=6DFFC0F9-AA09-41C8-B868-FB0D9CC28255;;
  pad) demo_udid=43EFC551-5368-4F79-9E52-E3DB87A72F48;;
  *) echo "usage: $0 [models|ui] [phone|pad]"; exit 2;;
esac
out="${DEMO_RESULTS:-$HOME/Library/Logs/Banana/DemoTests/$(date +%Y%m%d-%H%M%S)-$mode-$device}"
mkdir -p "$out"
xcrun simctl list devices available > "$out/simulators.txt"
top -l 1 -n 0 | rg PhysMem > "$out/memory.txt"
sysctl vm.swapusage >> "$out/memory.txt"
cat "$out/memory.txt"
# A booted simulator belongs to its current user. Do not erase or silently claim it.
if xcrun simctl list devices booted | rg -q "$demo_udid"; then
  echo "Canonical simulator is already booted; arrange release before running these checks."
  exit 2
fi
# New process group lets the deadline terminate children as well as the parent script.
python3 - "$mode" "$device" "$demo_udid" "$out" <<'PY'
import os, signal, subprocess, sys
mode, device, udid, out = sys.argv[1:]
if mode == 'ui':
    command = ['tools/ui-tests.sh', device, 'DemoModeUITest', 'ModuleAvailabilityUITest', 'NotesAdaptiveUITest/testWrittenNoteUsesSharedTextEditorAndSaves']
else:
    command = ['xcodebuild', 'test', '-scheme', 'BananaModelTests', '-configuration', 'Debug',
        '-destination', f'platform=iOS Simulator,id={udid}', '-derivedDataPath', '.build/sim',
        'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', '-jobs', '2',
        '-only-testing:BananaTests/DemoWorkspaceTests', '-resultBundlePath', out + '/models.xcresult',
        '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '60',
        '-maximum-test-execution-time-allowance', '120']
env = dict(os.environ, WORKERS='1', BUILD_JOBS='2', LOG=out + '/ui.log')
with open(out + '/driver.log', 'w') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    try:
        code = process.wait(timeout=1500)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        code = 124
    finally:
        subprocess.run(['xcrun', 'simctl', 'shutdown', udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f'Demo checks exit {code}; evidence: {out}')
sys.exit(code)
PY
