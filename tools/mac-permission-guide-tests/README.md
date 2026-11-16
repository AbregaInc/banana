# Mac permission guide checks

`python3 tools/mac-permission-guide-tests/run.py --out NEW_DIRECTORY` compiles the
actual guide and checks adjacent placement, small-screen fallback, secondary
screens, coordinate conversion, permission action routing, and deduplicated status
publication. It renders the actual view without opening a window or System Settings.

Build and run results and source hashes are retained. These checks do not establish
visible window following, system permission prompts, keyboard/accessibility
interaction, or physical frame/input performance. Run those on an idle test desktop.

## Native Settings checks

`BananaMacReleaseUITests/PermissionGuideTests.swift` drives the actual app, native
Reminders consent, Settings recovery, real window movement, native Quit & Reopen
and the effective grant through XCTest. Run it in a disposable Tart
guest or dedicated idle test account, never the owner's active desktop. The account
must have `~/.config/banana/mac-release-test-account`, an unlocked Aqua session and
XCTest Automation Mode configured without authentication.

Build the app with a development profile authorizing that test Mac and the real
sandbox entitlements. Build the independent `BananaMacReleaseUITests` runner into
`.build/mac-check` using `build-for-testing`. Transfer those signed products and the
`.xctestrun` together into the guest; do not re-sign them. In a copy of the runner
configuration, expand `__TESTROOT__` to the guest products directory and set
`EnvironmentVariables.BANANA_PERMISSION_APP` on the UI-test target to the guest's
`Banana.app` path. Preserve the other Xcode substitutions.

Start with fresh app state and Reminders consent for that candidate identity in the
guest. Retain existing state before resetting it; these tests deliberately deny a
native permission. Then run in the guest:

```sh
xcodebuild test-without-building -xctestrun /path/to/permissions.xctestrun \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:BananaMacReleaseUITests/PermissionGuideTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 \
  -resultBundlePath /path/to/new-result.xcresult
```

The test retains screen and accessibility-tree attachments. Failed runs stay as
evidence and are read before another run. This development-signed functional check
does not replace exact-release launch validation or physical performance testing.

On macOS 27.2, XCTest can misidentify desktop widgets as notification banners and
fail in its automatic swipe handler. Disable desktop widgets in the disposable
guest before the run, saving its original preferences. Retain that failure and
its screen/tree evidence; do not interpret it as an app failure or weaken the test.
