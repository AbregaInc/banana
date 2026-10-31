#!/bin/bash
# Check unreleased modules, Apple-silicon-only Mac apps, and required Watch slices.
#
#   tools/check-release.sh <path to .xcarchive, .app or .ipa folder>
#
# Unreleased modules (Mail first) are compiled only with BANANA_UNRELEASED (Config/Base.xcconfig):
# Debug and the author's own installs. An archive for TestFlight or the App Store must have none
# of their code: a feature in the binary that review can't see is a rejection (App Review 2.5.19),
# and Gmail's scopes in the app would put it under Google's yearly security assessment.
#
# Looks through every executable in the bundle for the words ModuleStore marks such a build with,
# and for Gmail's API and scopes. Exits 1, naming the file, when any is there.
set -e
target="${1:?usage: $0 <.xcarchive | .app | folder>}"
[ -e "$target" ] || { echo "No such path: $target"; exit 2; }

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
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")
  binary="$app/Contents/MacOS/$executable"
  architectures=$(xcrun lipo -archs "$binary")
  if [ "$architectures" != "arm64" ]; then
    echo "Not for Apple: Mac app must contain only arm64, found $architectures in $binary"
    exit 1
  fi
done < <(find "$target" -type d \( -name '*.app' -o -name '*.appex' \) -print0)

# What only an unreleased build carries.
patterns='banana-unreleased-modules-built-in
gmail.googleapis.com
https://www.googleapis.com/auth/gmail
https://mail.google.com/'

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
  echo "Not for Apple: this build has unreleased modules in it. Archive without BANANA_UNRELEASED=YES."
  exit 1
fi
echo "OK: no unreleased module in $checked executable(s) under $target"
