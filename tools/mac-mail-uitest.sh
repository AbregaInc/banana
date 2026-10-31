#!/bin/bash
# Runs the Mac's Mail UI suite (BananaMacUITests) on THIS Mac's real screen, with real key presses,
# clicks and window drags. It takes over the keyboard and mouse for about 16 minutes.
#
#   tools/mac-mail-uitest.sh                  the whole suite
#   tools/mac-mail-uitest.sh MailTriageKeysTests [MailSendKeysTests ...]   only those classes
#   tools/mac-mail-uitest.sh --check          only the checks below; starts nothing
#
# What it checks first, so that it never stops at a prompt nobody is there to answer:
#   - Banana Beta is not running (the tests launch the same app, same bundle identifier, same data
#     folder). It will not quit it for you.
#   - the screen is unlocked,
#   - macOS's Automation Mode is enabled without a password (the first UI test of a session asks for one).
#
# What it leaves alone: the installed /Applications/Banana Beta.app is never started or changed. The
# test app is a Debug build in .build/macuitest-dd, launched with --ui-audit --disable-icloud
# --mac-section mail --mail --mail-fresh: no production graph, so no calendar sync and no write-back
# (BananaApp.swift's Mac branch for --ui-audit; the iOS-only VisualAuditRoute is not what protects a
# Mac launch). The app does write three Mail preferences (pane, details, format bar) and the window's
# saved frame into the Beta's preferences; this script puts those back afterwards.
set -u
cd "$(dirname "$0")/.."

BETA_DOMAIN="com.boris.banana.mac.beta"
CASES=60
MINUTES=16

check_only=0
classes=()
for argument in "$@"; do
  if [ "$argument" = "--check" ]; then check_only=1; else classes+=("$argument"); fi
done

refuse() { echo; echo "NOT STARTING: $1"; shift; for line in "$@"; do echo "  $line"; done; echo; exit 2; }

# 1. Banana Beta must not be running.
if pgrep -x "Banana Beta" >/dev/null 2>&1 || pgrep -f "Banana Beta.app/Contents/MacOS/" >/dev/null 2>&1; then
  refuse '"Banana Beta" is running.' \
    "The tests launch the same app (same bundle identifier, same data folder) and would attach to it" \
    "or fight it. Quit it (Cmd-Q in Banana Beta) and run this again. This script does not quit it."
fi

# 2. The screen must be unlocked.
if ioreg -n Root -d1 -l 2>/dev/null | grep -q '"IOConsoleLocked" = Yes'; then
  refuse "the screen is locked." \
    "Nothing can be clicked, typed into or photographed on a locked screen. Unlock the Mac, leave it" \
    "awake, and run this again."
fi

# 3. Automation Mode must be on without a password.
automation="$(automationmodetool 2>&1 || true)"
if echo "$automation" | grep -qi "disabled"; then
  refuse "Automation Mode is disabled, and macOS would ask for your password in the middle of the run." \
    "Once, in a Terminal, run:" \
    "    automationmodetool enable-automationmode-without-authentication" \
    "(it asks for your password; if it says Developer mode is off, first: sudo DevToolsSecurity -enable)." \
    "Then run this script again. Current state: $(echo "$automation" | head -1)"
fi

if [ "$check_only" = 1 ]; then echo "Checks passed: Banana Beta is not running, the screen is unlocked, Automation Mode is on."; exit 0; fi

# The warning, and Return.
cat <<EOF

================================================================================================
  MAC MAIL UI TESTS: THIS TAKES OVER YOUR KEYBOARD AND MOUSE FOR ABOUT $MINUTES MINUTES.

  $CASES cases will launch a test copy of Banana Beta on this screen and press keys, click, drag and
  resize its window. Do not type, click, or use this Mac until it says it is finished: a key you press
  goes into the test, and a key the test presses goes to whatever is in front.
  Before the tests start: a build (no screen use), then a 5-second countdown.
  If macOS asks "BananaMacUITests-Runner wants to control this computer", allow it.
  Stop at any time with Ctrl-C in this window.
================================================================================================

EOF
read -r -p "Press Return to begin (Ctrl-C to cancel): " _

stamp="$(date +%Y%m%d-%H%M%S)"
out="$PWD/.build/macuitest-results/$stamp"
mkdir -p "$out"
echo "Results will be in: $out"

# Preferences the app writes: remember them, put them back at the end however it ends.
defaults export "$BETA_DOMAIN" "$out/prefs-before.plist" >/dev/null 2>&1 || : > "$out/prefs-before.plist"
restore_prefs() {
  python3 - "$BETA_DOMAIN" "$out/prefs-before.plist" <<'PY'
import plistlib, subprocess, sys
domain, before_path = sys.argv[1], sys.argv[2]
def load(data):
    try: return plistlib.loads(data)
    except Exception: return {}
before = load(open(before_path, "rb").read())
now = load(subprocess.run(["defaults", "export", domain, "-"], capture_output=True).stdout)
touched = lambda key: key in ("mailShowsPane", "mailShowsDetails", "mailFormatBarShown") or key.startswith("NSWindow Frame")
for key in sorted(set(now) | set(before)):
    if not touched(key) or now.get(key) == before.get(key): continue
    if key in before:
        value = before[key]
        flag = "-bool" if isinstance(value, bool) else "-string"
        subprocess.run(["defaults", "write", domain, key, flag, str(value).lower() if isinstance(value, bool) else str(value)])
        print("restored", key)
    else:
        subprocess.run(["defaults", "delete", domain, key]); print("removed", key)
PY
}
trap 'restore_prefs; exit 130' INT TERM

echo "Building for testing (no screen use)..."
xcodegen generate >/dev/null || { echo "xcodegen failed"; exit 1; }
if ! xcodebuild build-for-testing -project Banana.xcodeproj -scheme BananaMacBetaUITests \
     -derivedDataPath .build/macuitest-dd > "$out/build.log" 2>&1; then
  echo "Build failed: see $out/build.log"; grep -E "error:" "$out/build.log" | head; exit 1
fi
echo "Build succeeded."

# The build took a while: re-check that nothing changed.
if pgrep -x "Banana Beta" >/dev/null 2>&1; then refuse '"Banana Beta" was started while the build ran. Quit it and run again.'; fi

echo "Starting in 5 seconds. Hands off."
for i in 5 4 3 2 1; do printf '%s ' "$i"; sleep 1; done; echo

only=()
for class in "${classes[@]+"${classes[@]}"}"; do only+=("-only-testing:BananaMacUITests/$class"); done

# caffeinate: the display must not sleep under the test.
caffeinate -dimsu xcodebuild test-without-building -project Banana.xcodeproj -scheme BananaMacBetaUITests \
  -derivedDataPath .build/macuitest-dd -destination 'platform=macOS' -parallel-testing-enabled NO \
  -resultBundlePath "$out/result.xcresult" "${only[@]+"${only[@]}"}" > "$out/test.log" 2>&1
status=$?

echo "Finished. Putting the Beta's preferences back..."
restore_prefs | tee "$out/prefs-restored.txt"

# Screenshots and the summary.
mkdir -p "$out/attachments"
xcrun xcresulttool export attachments --path "$out/result.xcresult" --output-path "$out/attachments" >/dev/null 2>&1 || true
summary="$(xcrun xcresulttool get test-results summary --path "$out/result.xcresult" --compact 2>/dev/null || true)"
echo "$summary" > "$out/summary.json"
python3 - "$out" <<'PY'
import json, os, sys
out = sys.argv[1]
try: s = json.load(open(os.path.join(out, "summary.json")))
except Exception: s = {}
get = lambda k: s.get(k, "?")
print()
print("RESULT:  passed %s   failed %s   skipped %s   (of %s)   overall: %s" % (
    get("passedTests"), get("failedTests"), get("skippedTests"), get("totalTestCount"), get("result")))
for failure in s.get("testFailures", []):
    print("  FAILED  %s: %s" % (failure.get("testName", "?"), failure.get("failureText", "")[:200]))
shots = 0
for root, _, files in os.walk(os.path.join(out, "attachments")):
    shots += sum(1 for f in files if f.lower().endswith((".png", ".jpg", ".jpeg", ".heic")))
print("Screenshots (the app's own window only): %d in %s/attachments" % (shots, out))
print("Result bundle: %s/result.xcresult   (open it in Xcode for the failure details and window hierarchies)" % out)
print("Log: %s/test.log" % out)
PY
echo "You can use the Mac again."
exit $status
