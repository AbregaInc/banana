#!/bin/bash
# Check unreleased modules, the modules a build leaves out, Apple-silicon-only Mac apps, and
# required Watch slices.
#
#   tools/check-release.sh <path to .xcarchive, .app or .ipa folder>
#
# Local assistant is never distributed. Stable (TestFlight and the direct download) never carries
# Email; gated Email ships only in the dedicated direct Beta app. Check both
# their copied resources and their native implementation markers before exporting.
# Archives made in Xcode run this check from local-feature-resources.sh too.
set -e
target="${1:?usage: $0 <.xcarchive | .app | folder>}"
[ -e "$target" ] || { echo "No such path: $target"; exit 2; }

# Email distribution requires the Beta identity and the Beta feed. TestFlight is Stable.
# Never infer eligibility from a command-line allow flag or a public app's saved preference.
email_allowed=0
primary_apps=()
while IFS= read -r -d '' app; do primary_apps+=("$app"); done < <(find "$target" -type d -name '*.app' -prune -print0)
if [ "${#primary_apps[@]}" -eq 1 ]; then
  info="${primary_apps[0]}/Info.plist"
  [ -f "$info" ] || info="${primary_apps[0]}/Contents/Info.plist"
  channel=$(/usr/libexec/PlistBuddy -c 'Print :BananaReleaseChannel' "$info" 2>/dev/null || true)
  bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null || true)
  primary=$(/usr/libexec/PlistBuddy -c 'Print :BananaPrimaryBundleIdentifier' "$info" 2>/dev/null || true)
  if [ -n "$primary" ]; then
    feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info" 2>/dev/null || true)
    if [ "$channel" = beta ] && [ "$bundle" = "$primary.beta" ] && [ "$feed" = 'https://bananatheapp.com/updates/mac-beta/appcast.xml' ]; then email_allowed=1; fi
  fi
fi

# Runtime bundles, JS entry points and build markers must never reach distribution.
while IFS= read -r -d '' resource; do
  echo "Not for Apple: local-only feature resource in $resource"
  exit 1
done < <(find "$target" \( -name 'PiRuntime' -o -name 'pi-agent.js' -o -name 'pi-bootstrap.js' -o -name 'pi-local-model.json' -o -name 'pi-runtime-manifest.json' -o -name 'pi-inference-worker.py' \) -print0)

while IFS= read -r -d '' marker; do
  if [ "$email_allowed" -ne 1 ] || grep -qv '^EMAIL$' "$marker"; then
    echo "Not for distribution: unexpected local feature marker"; exit 1
  fi
done < <(find "$target" -name banana-local-features.txt -print0)

# Reproducible builds: Core ML's compiler writes a model's user-defined metadata in a different
# order on every build, so a model with more than one entry makes every build differ. Keep such
# provenance beside the model (docs/publication/voice-model-provenance.json does).
while IFS= read -r -d '' metadata; do
  entries=$(python3 -c 'import json,sys; print(max([len(m.get("userDefinedMetadata") or {}) for m in json.load(open(sys.argv[1]))] or [0]))' "$metadata")
  if [ "$entries" -gt 1 ]; then
    echo "Not reproducible: $entries user-defined metadata entries in ${metadata%/metadata.json}; at most one."
    exit 1
  fi
done < <(find "$target" -path '*.mlmodelc/metadata.json' -print0)

# Check nested apps and extensions before export. A global arm64 override also affects
# Watch targets, which still need arm64_32 when supporting watchOS versions before 27.
# Native Mac applications are Apple-silicon-only, including with command-line overrides.
while IFS= read -r -d '' app; do
  flat_info="$app/Info.plist"
  if [ -f "$flat_info" ]; then
    platform=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$flat_info" 2>/dev/null || true)
    if [ "$platform" = "WatchOS" ]; then
      executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$flat_info")
      architectures=$(xcrun lipo -archs "$app/$executable")
      minimum=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$flat_info")
      required="arm64"
      if [ "${minimum%%.*}" -lt 27 ]; then required="$required arm64_32"; fi
      for architecture in $required; do
        case " $architectures " in
          *" $architecture "*) ;;
          *) echo "Not for Apple: Watch bundle requires $architecture, found $architectures in $app"; exit 1 ;;
        esac
      done
    fi
  fi
  info="$app/Contents/Info.plist"
  [ -f "$info" ] || continue   # iOS and Watch apps have a flat bundle layout.
  # Sparkle's upstream updater helper is universal; the first-party Mac app stays arm64.
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
  case "$bundle_id" in org.sparkle-project.Sparkle.Updater) continue ;; esac
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")
  binary="$app/Contents/MacOS/$executable"
  architectures=$(xcrun lipo -archs "$binary")
  if [ "$architectures" != "arm64" ]; then
    echo "Not for Apple: Mac app must contain only arm64, found $architectures in $binary"
    exit 1
  fi
done < <(find "$target" -type d \( -name '*.app' -o -name '*.appex' \) -print0)

# What only an unreleased build carries.
patterns='banana-local-ai-built-in
AppleRuntimeHost
AssistantStore'
if [ "$email_allowed" -ne 1 ]; then
patterns="$patterns
banana-unreleased-modules-built-in
gmail.googleapis.com
https://www.googleapis.com/auth/gmail
https://www.googleapis.com/auth/contacts
https://mail.google.com/"
fi

found=0
checked=0
# Every Mach-O file in the bundle: the app, its dylibs, the Watch app, the widgets.
while IFS= read -r -d '' file; do
  file "$file" | grep -q "Mach-O" || continue
  checked=$((checked + 1))
  echo "$patterns" | while IFS= read -r words; do
    [ -n "$words" ] || continue
    if LC_ALL=C grep -a -q -F "$words" "$file"; then
      echo "UNRELEASED: \"$words\" in $file"
      exit 1
    fi
  done || found=1
done < <(find "$target" -type f \( -perm -u+x -o -name "*.dylib" \) -print0 2>/dev/null)

if [ "$checked" -eq 0 ]; then
  echo "No executables found under $target"
  exit 2
fi
if [ "$found" -ne 0 ]; then
  echo "Not for Apple: this build has unreleased modules in it. Exclude local AI; Email ships only in the dedicated direct Beta identity and feed."
  exit 1
fi
echo "OK: no unreleased module in $checked executable(s) under $target"

# The modules the app's BananaModules leaves out: none of their code, frameworks, entitlements,
# Info.plist keys, background modes, task identifiers, URL schemes or embedded targets
# (Config/Modules.json). The App Store app leaves out every module but those
# BANANA_APP_STORE_MODULES lists; Stable leaves out Email.
python3 "$(dirname "$0")/modules/modules.py" check "$target"
