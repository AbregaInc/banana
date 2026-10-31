#!/bin/zsh
# Release build of the prototype for the Mac. Run without -quiet: Xcode 27 prints a fake error with it.
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null && \
xcodebuild -project P1List.xcodeproj -scheme P1List -configuration Release -destination 'platform=macOS' -derivedDataPath build-mac build 2>&1 | grep -E "error:|warning:.*Sources|BUILD (SUCCEEDED|FAILED)"
