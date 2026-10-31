# Native XCTest startup investigation — October 9, 2026

Artifacts: `.build/xctest-unblock-20261009/`. All interrupted runs are retained.
This is test-infrastructure diagnosis, not a UI performance acceptance result.

## Reproduction and findings

- Developer Mode is enabled; Automation Mode can be enabled without authentication.
  No permission settings were changed in this investigation.
- A newly generated minimal macOS unit-test target and UI-test target each executed
  one test successfully. XCTest is not globally unable to start.
- The existing calendar runner repeated its pre-main `_dyld_start` hang and exceeded
  the bounded 120-second attempt (`calendar-native-retry`).
- A fresh calendar build with local ad-hoc signing, manual signing style and an empty
  development team completed the real scrolling, paging and eviction test. A second
  invocation using the generated project configuration also passed: one test, zero
  failures in each (`calendar-local-signing`, `calendar-configured-repeat`).
- Restoring development-certificate signing in that same directory reproduced a
  startup timeout (`calendar-certificate-control`). However, switching back to local
  signing and then using another fresh local directory also timed out. Therefore
  signing alone is **not established as a sufficient fix**. Both successful runs and
  subsequent failures remain evidence; do not report this as consistently repaired.
- Both earlier runner bundles passed on-disk signature verification. System logs also
  contain AMFI validation messages, but these alone do not establish the root cause.
- Other workspaces ran Xcode UI tests concurrently. An attempted idle-helper reset was
  explicitly skipped while another Xcode job was active. No unrelated job was stopped.

The first experiment changed the Mac calendar target to local signing; the final
configuration restores development signing with a distinct dedicated runner bundle
identifier. iOS and application signing are unchanged. Rebuild the runner before testing: `test-without-building` cannot update an
old runner's signature. An exclusive window opened at 19:00 EDT; restarting only the
current user's idle `testmanagerd` did **not** resolve the failure. The first trial
again timed out before test execution, so the second was not run
(`exclusive-recovery/finished.json`). LaunchServices spawned the runner process,
but Xcode remained blocked waiting for launch completion; the system log and
interrupted Xcode operation graph are retained in that directory.

A sequential comparison is queued in `paired-idle-probe/run.py`: rerun the previously
passing minimal UI runner, then the calendar runner, waiting for a 20-second idle
window before each. Each run is bounded, preserves its result bundle, and captures
a process list and runner sample if startup takes longer than 40 seconds.
Its `status.json` and `finished.json` distinguish pending work from verified passes.
The Simulator watcher waits for this diagnostic comparison to finish.

## Resource monitoring

The initial watcher stopped on a 10-second `ps` timeout. Its raw log is preserved.
The corrected watcher (`monitor-v2/watch.py`) records sampling failures, resets its
quiet-window counter, and continues instead of silently dying.

For up to three hours from its start, it requires 30 consecutive seconds with no
sampled Xcode/Swift/XCTest jobs, one-minute load below 7 on this 10-CPU Mac, at least
5 GiB free disk, and completion of the native investigation. It then creates its own
Simulator, runs the unchanged persistent component suite, and shuts down/deletes only
that Simulator. It never changes budgets or promotes a baseline. The suite retains
its own finer-grained host monitoring and may still reject a contended run.

Current state: `monitor-v2/status.json`; final outcome: `monitor-v2/finished.json`.
The Mac recovery wait is separately recorded in `exclusive-recovery/status.json`.
A background process being alive is not a test pass; inspect final result files.

Load averages reached hundreds while a sample still reported about 62% CPU idle.
Most runnable processes were descendants of the other workspace's Simulator.
These are contention/readiness signals, not proof of CPU saturation or the cause
of the Mac runner hang. The watcher deliberately waits conservatively.

## Sandbox initialization finding

The idle comparison reproduced a minimal UI-runner pass (one test, zero failures)
and calendar startup timeout. Unlike the earlier pre-dyld sample, the new calendar
sample reached `_libsecinit_appsandbox` and waited for an XPC response. Sampling
`secinitd` showed a serial queue named for the calendar runner's bundle identifier
inside `appsandboxContainerSync` → `displaySharingConsentPrompt` →
`CFUserNotificationReceiveResponse`. This establishes a pending container-sharing
consent response as the immediate blocker in this attempt, rather than calendar
layout/test execution. It does not establish the cause of every earlier timeout.

Evidence: `paired-idle-probe/calendar-ui/runner-58108-sample.txt`,
`paired-idle-probe/secinitd-sample.txt`, `paired-idle-probe/sandbox-init.log`.
Computer use refused access to UserNotificationCenter for safety reasons; no
alternative automation was used to interact with that dialog, no container was
removed, and no sandbox/security setting was disabled.

A separately generated `StandaloneCalendar` project runs the **same original
LiveTests.swift source** under the distinct local-only bundle identifier
`com.boris.banana.calendar-metal-review.macuitests.localprobe`. This isolates its
container rather than requesting access to the older runner's container. The
`standalone-comparison` script waits for other Xcode jobs, attempts a build/test and
a repeat, and records exact one-test/zero-failure verification for each.
Both isolated runs completed with one test passed and zero failures, as recorded
in `standalone-comparison/finished.json`. Signing
identity should remain stable for this container; do not switch it between local
and development-certificate identities as a routine recovery step.


Both isolated full calendar runs passed (one test, zero failures each). XCTest logs
still show the old UserNotificationCenter dialog interrupting event synthesis, so
its duration/frame measurements are not uncontaminated performance evidence.
The repeat is separately retained. A second sequential experiment,
`stable-signer-comparison`, tests the original project with a dedicated
`.macuitests.development` identifier and its original Apple Development signature.
This is the intended persistent configuration; it must not alternate signers.

Apple documents the association between code-signing identity and sandbox containers
in [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).
Our inference is that changing identities against the reused runner container
contributed to the consent request. The captured consent-wait stack is direct
local evidence; the precise initiating transition has not been proven.


## Verified recovery

`stable-signer-comparison/finished.json` records **two full calendar UI passes**
from the original project using the dedicated development-signed identity: the
build/test invocation and the subsequent test-without-building invocation each
executed one test with zero failures. The test source and scenario were unchanged.
The configuration change is in `SkiaLive/project.yml`; existing containers and
failed runs are preserved. This verifies a working runner route on this Mac,
not every native UI target or resilience across OS updates.

`measurements.json` archives 14 attempt status records, including failures and
both final passes, plus the unchanged test-source SHA-256. Raw logs, samples,
result bundles and frame logs remain under the artifact root above.

The old consent dialog still appears as an XCTest interruption in these runs.
Consequently, they are functional/startup results only; they do not establish
unobstructed UI interaction timing. The tool's restriction on the system dialog
was respected. The persistent component suite remains queued behind the resource
watcher; no Simulator performance pass is claimed.


## Resource watcher outcome and follow-up

The watcher found its quiet window at 19:44 EDT, ran the complete component suite,
and retained a failing verdict. It then shut down and deleted its own Simulator.
Failures were notes search and podcast-query tails, plus incomplete monitoring in
the one-day case; this was not a calendar-renderer test. The subsequent
[matched-binary and contention investigation](../query-failure-diagnosis-20261009/README.md)
reproduces the tail failures with the pre-change control, establishes Simulator
startup contention as a sufficient cause, and retains a full passing recovery suite.
