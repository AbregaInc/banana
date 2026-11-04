# Pi lifecycle integration on Apple platforms

The new `ApplePiSession` adapter controls runtime lifetime through the public `Harness` APIs. Pi's task scheduler, checkpoints, SQLite schema and recovery logic are unchanged. A durable sleeping task is an ordinary registered `defineTask` in a `defineExtension`.

## Adapter behavior

Activation opens Pi's existing `SqliteStorage`, publishes `harness.wake()` and calls `resume()`. `onWake` publishes later changes. A foreground timer delivers the next Pi deadline by calling `resume()`; it rechecks Pi's clock after an early or clamped timer. Host timers used only to release idle memory are declined, as Pi explicitly permits.

Deactivation stops foreground wake delivery, preserves the latest wake hint and awaits `harness.close()`. Pi stops admission, cancels/joins active invocations and closes storage. Activation/deactivation are serialized; repeated activation returns the same harness and rapid foreground/background requests cannot open overlapping writers through this adapter. Reopening creates a new harness against the same SQLite file and resumes Pi's persisted checkpoint.

The wake sidecar contains only Pi's `{ active, at? }` hint, written atomically. It is advisory metadata, not another task ledger. Every reopen reads SQLite and recomputes the hint through Pi. An `active` hint can remain while the closing invocation settles; it does not imply that a background process is executing. A future system background-task integration may use this hint, but this change does not register `BGTaskScheduler` jobs or promise an exact wake time.

## UIKit integration

In the standalone proof app's `lifecycle-live` mode, `sceneWillResignActive` requests a short UIKit background assertion. `sceneDidEnterBackground` awaits deactivation and then ends that assertion. `sceneDidBecomeActive` activates the session again. The expiration handler stops native resources; a later foreground can recreate the runtime against its original database. Forced expiration has not yet been exercised by the device check and is not claimed as verified behavior.

Apple controls background suspension and opportunities to run. Closing can be interrupted by process termination; the existing Pi recovery path remains responsible on the next open. See Apple's [background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time). This is recovery when the app receives CPU again, not continuous execution while suspended.

## Checks

Five new contracts run in actual JavaScriptCore with native SQLite:

1. Repeated activation shares one harness; repeated close is harmless.
2. Queued close/open joins old work before opening the next backend.
3. A failed wake publication closes the partially opened backend.
4. Closing cancels a pending native model request; reopening resumes the stored task checkpoint.
5. A foreground wake delivers a sleeping task at or after its real deadline.

The Mac fresh-process proof closes after the sleep checkpoint, exits, then starts a separate process against the same SQLite database. An explicitly controlled epoch clock advances to the persisted deadline. Only the delivery phase runs in the second process. This avoids claiming a real-time suspension result from a clock-controlled check.

The physical-device runner uses real UIKit transitions: launch the proof, wait for its persisted sleeping state, launch Settings to background it, verify a paused snapshot with zero Pi-owned databases/timers/model requests and no delivery, remain backgrounded past the deadline, then activate the proof again. It checks one arm phase and one delivery phase with the same task ID. It changes no Settings values. All waits are bounded and predicate-based; the real-time wait uses two timestamps from the device, so host/device clock skew does not affect it.

Mac and physical iPad pass all five lifecycle contracts and the controlled-clock fresh-process proof. The physical iPad also passes the real UIKit background/foreground check: its paused snapshot has zero Pi-owned resources and zero delivery calls; its foreground result has exactly one delivery. Evidence: [Mac contracts](pi-apple-host-results/mac-lifecycle-conformance.json), [Mac reopen](pi-apple-host-results/mac-lifecycle-reopen.json), [iPad contracts](pi-apple-host-results/ipad-lifecycle-conformance.json), [iPad reopen](pi-apple-host-results/ipad-lifecycle-reopen.json), [iPad paused state](pi-apple-host-results/ipad-lifecycle-paused.json), [iPad live result](pi-apple-host-results/ipad-lifecycle-live.json).

Phone live transitions and the five contracts passed before work was redirected to iPad. Its later fresh-process sequence exposed a task-name lookup error in the proof; that lookup was corrected to use the public task token's `definition.name`, and the full sequence was rerun successfully on iPad. No further phone operations were performed. Complete current results are in the [device report](PI-APPLE-HOST-DEVICE-RESULTS.md).

## Reproduce

From the repository root after generating the existing host bundle:

```sh
python3 tools/pi-host-proof/run-mac.py --mode lifecycle-conformance
python3 tools/pi-host-proof/run-mac.py --mode lifecycle-roundtrip
python3 tools/pi-host-proof/run-device.py DEVICE_UDID iphone --modes lifecycle-conformance lifecycle-first lifecycle-reopen
python3 tools/pi-host-proof/run-lifecycle-device.py DEVICE_UDID iphone
```

Use `ipad` as the tablet label and the device's explicit UDID. The last command briefly opens Settings and returns to the proof app; it only operates the separate Pi proof bundle. Production Banana UI, cross-device ownership/handoff, OS-scheduled background delivery and full expiration testing remain work. No production Banana stores, main/Beta installs or Apple submissions are involved.
