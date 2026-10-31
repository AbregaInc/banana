#!/bin/zsh
# Release build of the prototype for the "Mail iPhone" simulator, then install. Run without -quiet.
cd "$(dirname "$0")/.."
UDID=E5232BE0-8F82-4E85-A03B-5CA7160571E2
xcodegen generate >/dev/null && \
xcodebuild -project P1List.xcodeproj -scheme P1List -configuration Release -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build-ios build 2>&1 | grep -E "error:|warning:.*Sources|BUILD (SUCCEEDED|FAILED)"
xcrun simctl install $UDID build-ios/Build/Products/Release-iphonesimulator/P1List.app && echo installed
