# Simulator services

Install [simslim](https://github.com/MobAI-App/simslim) 0.14.0:

```sh
brew tap mobai-app/tap
brew install mobai-app/tap/simslim
simslim --version
```

`tools/ui-tests.sh` and Simulator unit preflight runs use `slim.json` by default.
The profile disables wallpaper posters, Family/Screen Time and MDM. It retains
Banana's system integrations, including Apple Intelligence, iCloud/keychain,
push, StoreKit, Calendar/Contacts/Mail, Health, Photos, Files/Spotlight, widgets
and Live Activities. The CLI version is checked before changing anything;
review profiles and feature requirements when upgrading it.

Preparation takes the existing simulator and derived-data locks, verifies the
exact profile, repairs drift, boots without opening Simulator, and checks the
required features with `doctor`. A matching booted simulator is not rebooted.
Version, profile, pre/post state and doctor results accompany each run. Failure
stops the test command. It never starts a fleet watcher, creates a simulator,
erases app data, or changes other devices.

```sh
# The existing workflow prepares and verifies its selected phone or iPad.
tools/ui-tests.sh phone MailReaderUITest
BANANA_SIM_MODE=stock tools/ui-tests.sh pad MailReaderUITest
# Prepare one simulator and optionally run a command under its lock.
tools/simulator-run.sh phone slim private/my-run -- true
tools/simulator-run.sh phone stock private/my-stock-run -- true
```

Evidence directories must be new. UI evidence defaults to
`.build/simulator-runs/`; `SIMULATOR_EVIDENCE` selects a retained directory.
Preflight stores it under that run's output. The optional `SIMULATOR_UDID`
override selects an existing device while keeping the phone/pad test lock.
Physical-device runs do not invoke simslim. Parallel UI workers use stock mode:
Xcode's disposable clones do not inherit slimming, and this workflow does not
mutate all simulators through a global watcher.

`tools/performance-regression.py run` always restores and verifies `stock.json`
after compilation and before measurement, independent of `BANANA_SIM_MODE`.
Existing budgets, reference environments and cases remain unchanged. This is
important because slimming persists across boots and across worktrees. Use
stock mode for system onboarding, Family/MDM or wallpaper-specific checks too.

For a controlled comparison, first build the ordinary optimized component app
with `.build/sim` and run the persistent stock gate. Then reuse that exact app:

```sh
. tools/config.sh
tools/agents/xcode-lock.sh -l build -l sim-phone -d .build/sim \
  python3 tools/performance-regression.py run --device "$BANANA_SIM_PHONE" \
    --derived-data .build/sim --out private/stock-components
# A failed gate is retained and investigated, not replaced by the comparison.
tools/agents/xcode-lock.sh -l build -l sim-phone -d .build/sim \
  python3 tools/simulators/benchmark.py --device "$BANANA_SIM_PHONE" \
    --app .build/sim/Build/Products/Release-iphonesimulator/Banana.app \
    --out private/service-comparison
```

The comparison runs all eight unchanged workloads in stock then slim mode,
using the same binary and a new boot for each mode. It records three simulator-tree `phys_footprint` samples
after equal idle periods, case wall times, raw component timings, app RSS,
checksums and host monitoring. Its final state is slim. Every failure remains;
a lower simulator footprint does not establish faster compilation, lower app
RSS, a passing component gate, or physical-device UI performance. Exit status is 1 when component/host checks or comparison regressions fail.
Repeat with `--order slim,stock` on a quiet host before claiming a stable timing improvement.

The [recorded initial comparison](../../docs/performance/simslim/README.md) observes
a 21% simulator-footprint reduction with this conservative profile; its limitations
and the still-failing historical app-memory gate are retained.
