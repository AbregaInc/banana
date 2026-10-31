import Foundation
import Darwin
import Combine
#if os(iOS)
import UIKit
#endif

/// Catches the app burning CPU — and names the view that's doing it.
///
/// iOS killed the app mid-walk for using 100% CPU over 48 seconds (a background audio app gets 80%
/// over 60). The sampled stack was SwiftUI re-evaluating view bodies with the screen off, but a
/// stackshot can't say *which* view, and the loop doesn't reproduce in the simulator with a copy of
/// the library — it needs the real calendar, the real weather, the real watch. So rather than guess
/// a third time: measure our own CPU from inside the process, and when it goes somewhere it has no
/// business being, print a league table of which view bodies ran and how often.
///
/// `RenderStats.note(_:)` is called at the top of the suspect view bodies. It's a dictionary
/// increment — nothing next to a SwiftUI body evaluation.
enum RenderStats {
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var lifetimeCounts: [String: Int] = [:]
    private static let lock = NSLock()

    static func note(_ view: String) {
        lock.lock()
        counts[view, default: 0] += 1
        lifetimeCounts[view, default: 0] += 1
        lock.unlock()
    }

    static func count(_ view: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[view, default: 0]
    }

    static func lifetimeCount(_ view: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return lifetimeCounts[view, default: 0]
    }

    static func lifetimeSnapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return lifetimeCounts
    }

    /// Counts since the last call, highest first, and reset.
    static func drain() -> [(view: String, count: Int)] {
        lock.lock()
        let snapshot = counts
        counts.removeAll(keepingCapacity: true)
        lock.unlock()
        return snapshot.sorted { $0.value > $1.value }.map { (view: $0.key, count: $0.value) }
    }
}

/// Names expensive work for the minute-level power rollup.
///
/// Tokens are refcount-free and safe across suspension: an operation remains listed as active
/// until its matching `end`. Completed durations are drained into the next rollup. Signpost wraps
/// this automatically, so Instruments intervals and the persistent journal share the same names.
enum PowerTrace {
    struct Token {
        fileprivate let id: UUID
        fileprivate let name: String
        fileprivate let started: Date
    }

    nonisolated(unsafe) private static var active: [UUID: (name: String, started: Date)] = [:]
    nonisolated(unsafe) private static var completed: [String: (count: Int, seconds: Double)] = [:]
    private static let lock = NSLock()

    static func begin(_ name: String) -> Token {
        let token = Token(id: UUID(), name: name, started: Date())
        lock.lock()
        active[token.id] = (name, token.started)
        lock.unlock()
        return token
    }

    static func end(_ token: Token) {
        let elapsed = max(0, Date().timeIntervalSince(token.started))
        lock.lock()
        active[token.id] = nil
        var total = completed[token.name] ?? (0, 0)
        total.count += 1
        total.seconds += elapsed
        completed[token.name] = total
        lock.unlock()
    }

    /// Active work plus work completed since the previous minute rollup.
    static func drainSummary() -> String {
        lock.lock()
        let now = Date()
        let activeSnapshot = Dictionary(grouping: active.values, by: \.name)
            .map { name, values in
                let longest = values.map { now.timeIntervalSince($0.started) }.max() ?? 0
                return "\(name)×\(values.count)@\(Int(longest))s"
            }
            .sorted()
        let completedSnapshot = completed
            .map { name, value in "\(name)×\(value.count)/\(Int(value.seconds * 1000))ms" }
            .sorted()
        completed.removeAll(keepingCapacity: true)
        lock.unlock()
        let running = activeSnapshot.isEmpty ? "none" : activeSnapshot.joined(separator: ",")
        let done = completedSnapshot.isEmpty ? "none" : completedSnapshot.joined(separator: ",")
        return "active=[\(running)] done=[\(done)]"
    }
}

enum PerfWatchdog {
    /// iOS kills a background audio app at 80% over 60s. Complain well before that, while there's
    /// still something to see.
    private static let alarmingCPU = 25.0
    /// A source publishing faster than this is a bug, not activity.
    ///
    /// Verified: nothing puts a periodic timer on the four counted stores, and the only burst
    /// source (EventKit change coalescing on a calendar sync) fires a few events and stops. So the
    /// legitimate *sustained* rate is effectively zero, with rare bursts under ~1.5/s. 15/s was
    /// timid — it sat far above the runaway's neighbours and would have sailed past a "mild" 3–5/s
    /// storm that still burns real CPU over a long ride. The cost of catching a legitimate burst is
    /// one log line (which prints its own rate, so 2/s and 100/s are never confused); the cost of
    /// missing a slow storm is another dead ride. That asymmetry says: trip just above legitimate.
    private static let stormRate = 2.0

    nonisolated(unsafe) private static var timer: Timer?
    nonisolated(unsafe) private static var sinks: [AnyCancellable] = []
    nonisolated(unsafe) private static var lateSinksRegistered = false
    nonisolated(unsafe) private static var lastCPU: TimeInterval = 0
    nonisolated(unsafe) private static var lastWall: Date = .distantPast
    nonisolated(unsafe) private static var latestCPUPercent = 0.0
    nonisolated(unsafe) private static var latestActivity = "none"
    nonisolated(unsafe) private static var powerCPUSum = 0.0
    nonisolated(unsafe) private static var powerCPUMax = 0.0
    nonisolated(unsafe) private static var powerSampleCount = 0
    nonisolated(unsafe) private static var lastPowerRollupAt = Date()
    nonisolated(unsafe) private static var lastKernel = kernelCounters()

    /// Most recent process sample for the playback heartbeat. Reading this does no
    /// measurement work; the watchdog timer has already paid for the sample.
    static func latestSample() -> (cpuPercent: Double, activity: String) {
        (latestCPUPercent, latestActivity)
    }

    @MainActor
    static func start() {
        guard timer == nil else { return }

        // TodayView re-rendered 154×/second on a bike ride and iOS killed the app for it. Three
        // things can invalidate TodayView without touching RootView — which is exactly the
        // signature in the log — and a body count alone can't tell them apart:
        //   • its own `timeAnchors` @State (the weather-stripe preference loop),
        //   • the WeatherStore republishing,
        //   • the OccurrenceStore republishing.
        // Count all three. Whichever is running at ~150/s IS the loop; no more theorising.
        var s: [AnyCancellable] = [
            OccurrenceStore.shared.objectWillChange.sink { _ in RenderStats.note("occurrences↻") },
            WeatherStore.shared.objectWillChange.sink { _ in RenderStats.note("weather↻") },
            RoutineStore.shared.objectWillChange.sink { _ in RenderStats.note("routines↻") },
            // 09-02 00:22: RootView stormed at 6/s for two minutes after launch with none of the
            // counters above moving; the source was the FitnessStore series backfill publishing
            // per field. Count it so the next fitness-driven storm names itself.
            FitnessStore.shared.objectWillChange.sink { _ in RenderStats.note("fitness↻") },
        ]
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        // A live Watch workout was running when it died — the one condition a test rig with no
        // paired Watch can never have. If the Watch link is what's spinning the phone, this counter
        // says so, and no more theorising is required.
        s.append(PhoneConnectivity.shared.objectWillChange.sink { _ in RenderStats.note("watch↻") })
        // 07-16 00:49: RootView stormed at 5/s with NONE of the counters above moving — the
        // republisher wasn't instrumented, so the log named the symptom but not the cause.
        // Count everything RootView itself observes; the next storm names its source.
        s.append(WakeCoordinator.shared.library.objectWillChange.sink { _ in RenderStats.note("library↻") })
        s.append(WakeCoordinator.shared.music.objectWillChange.sink { _ in RenderStats.note("music↻") })
        s.append(WakeCoordinator.shared.downloads.objectWillChange.sink { _ in RenderStats.note("downloads↻") })
        #endif
        // On both platforms: MacRootView observes the player and the backup too, and without these
        // a Mac storm was logged as the view and not the store publishing into it. The player is
        // already built by `BananaApp`'s own properties by now; the backup's init is a few defaults.
        s.append(WakeCoordinator.shared.player.objectWillChange.sink { _ in RenderStats.note("player↻") })
        s.append(CloudBackup.shared.objectWillChange.sink { _ in RenderStats.note("backup↻") })
        // What the Nutrition and shell views observe, none of which had a sink: a storm through
        // one of them was logged as the view, not the store publishing into it. All four exist by
        // now — `ActionBadges.start()` has just run, and building it touched WellnessStore,
        // MealInboxStore and OccurrenceStore, whose init builds ToastCenter — so naming them
        // constructs nothing earlier than it already is.
        s.append(ActionBadges.shared.objectWillChange.sink { _ in RenderStats.note("badges↻") })
        s.append(WellnessStore.shared.objectWillChange.sink { _ in RenderStats.note("wellness↻") })
        s.append(MealInboxStore.shared.objectWillChange.sink { _ in RenderStats.note("mealInbox↻") })
        s.append(ToastCenter.shared.objectWillChange.sink { _ in RenderStats.note("toasts↻") })
        s.append(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        ).sink { _ in
            Task { @MainActor in
                PlaybackDiagnostics.shared.log(
                    "🌡 THERMAL → \(thermalName(ProcessInfo.processInfo.thermalState))",
                    thermalContext())
            }
        })
        sinks = s
        lastCPU = processCPUSeconds()
        let now = Date()
        lastWall = now
        // Static stored properties are initialized lazily. Seed the power baseline here so the
        // first rollup covers the same real minute as its CPU samples instead of initializing
        // these counters only when that first rollup is emitted.
        powerCPUSum = 0
        powerCPUMax = 0
        powerSampleCount = 0
        lastPowerRollupAt = now
        lastKernel = kernelCounters()
        scheduleNextSample()
    }

    /// AlarmStore, SmartScheduleStore, OnboardingStore and AppSettings are not singletons — unlike
    /// the WakeCoordinator.shared spokes (library/player/music/downloads), they exist only as
    /// `@StateObject`s owned by `BananaApp`. `start()` runs from `App.init()`, a static context
    /// with no access to those instance properties, so it cannot wire their sinks up front.
    ///
    /// NOT YET CALLED. The intended call site is `BananaApp.wireUp()` — by then all four are
    /// constructed (StateObject default values are assigned before `init()`'s body runs) — but
    /// that file is outside this pass's scope, so this hook exists without a caller for now.
    /// Wiring it (one line: `PerfWatchdog.registerLateSinks(alarms: store, smart: smart,
    /// onboarding: onboarding, settings: settings)` near the top of `wireUp()`) closes the blind
    /// spot that let AlarmStore's same-value `isAlerting` republishes (09-01 WeekView storm) go
    /// uncounted.
    @MainActor
    static func registerLateSinks(alarms: AlarmStore, smart: SmartScheduleStore,
                                   onboarding: OnboardingStore, settings: AppSettings) {
        // `wireUp()` runs from each root view's `.task`: a window reopened on the Mac would count
        // every publish of these twice, and the storm threshold would halve.
        guard !lateSinksRegistered else { return }
        lateSinksRegistered = true
        sinks.append(alarms.objectWillChange.sink { _ in RenderStats.note("alarms↻") })
        sinks.append(smart.objectWillChange.sink { _ in RenderStats.note("smart↻") })
        sinks.append(onboarding.objectWillChange.sink { _ in RenderStats.note("onboarding↻") })
        sinks.append(settings.objectWillChange.sink { _ in RenderStats.note("settings↻") })
        // The two that nothing builds before first use, so `start()` could not name them without
        // building them. By here the iOS shell holds ShellNavigation (RootView observes it from
        // its first render; the Mac never builds it until a section that uses it opens, so it is
        // left alone there), and SyncProgress exists once the meal engine has started, which is
        // what first reports into it — a build with no iCloud never has, and has nothing to count.
        #if os(iOS)
        sinks.append(ShellNavigation.shared.objectWillChange.sink { _ in RenderStats.note("shell↻") })
        #endif
        if CloudControlsSync.meals.isRunning {
            sinks.append(SyncProgress.shared.objectWillChange.sink { _ in RenderStats.note("sync↻") })
        }
    }

    @MainActor
    private static func tick() {
        timer = nil
        defer { scheduleNextSample() }
        let cpu = processCPUSeconds()
        let now = Date()
        let elapsed = now.timeIntervalSince(lastWall)
        guard elapsed > 0.5 else { return }

        let percent = (cpu - lastCPU) / elapsed * 100
        lastCPU = cpu
        lastWall = now

        let counts = RenderStats.drain()
        latestCPUPercent = percent
        latestActivity = counts.prefix(4)
            .map { "\($0.view)×\($0.count)" }
            .joined(separator: ",")
        if latestActivity.isEmpty { latestActivity = "none" }
        powerCPUSum += percent
        powerCPUMax = max(powerCPUMax, percent)
        powerSampleCount += 1
        if now.timeIntervalSince(lastPowerRollupAt) >= 60 {
            // `tick` is driven by a main-run-loop Timer (see start), so this is already executing
            // on the main actor; make that fact explicit for the subsystem snapshots below.
            MainActor.assumeIsolated { logPowerRollup(now: now) }
        }

        if ProcessInfo.processInfo.arguments.contains("--perf-trace") {
            let all = counts.prefix(6).map { "\($0.view)×\($0.count)" }.joined(separator: " ")
            PlaybackDiagnostics.shared.log("perf \(Int(percent))%",
                                           "over \(Int(elapsed))s — \(all.isEmpty ? "no bodies" : all)")
        }

        // A STORM is a source firing far faster than anything legitimate — the bike-ride runaway was
        // ~154/second; a normal window is a handful. Crucially this is detected from the source's
        // OWN publish rate, not from CPU or renders: gating the off-screen UI stopped the storm from
        // rendering (and so from burning a core), which also stopped it from tripping a CPU alarm.
        // If we only watched CPU we'd have blinded ourselves to the very thing we're hunting. The
        // store `objectWillChange` sinks fire whether or not any view draws, so this catches the
        // publisher in the act even while the timeline is gated and the screen is off.
        let perSecond = { (n: Int) in Double(n) / max(elapsed, 0.001) }
        let storming = counts.filter { perSecond($0.count) >= stormRate }
        if !storming.isEmpty {
            // Name the CAUSE, not the symptom. A runaway store republish (↻) and the view it
            // re-renders both cross the threshold together, and the view often edges ahead by a
            // few counts — but the view is downstream. Prefer a publisher source so the log points
            // at the root; fall back to the fastest thing if only views are storming.
            let isSource = { (name: String) in name.hasSuffix("↻") || name == "anchorWrite" }
            let storm = storming.first(where: { isSource($0.view) }) ?? storming[0]
            let rate = Int(perSecond(storm.count))
            let others = counts.prefix(6).map { "\($0.view)×\($0.count)" }.joined(separator: " ")
            PlaybackDiagnostics.shared.log("🌀 STORM: \(storm.view) at \(rate)/s",
                                           "cpu=\(Int(percent))% over \(Int(elapsed))s — \(others)")
            DiagnosticJournal.shared.record(
                operation: "process.resourceAnomaly",
                name: "publisher_storm",
                attributes: DiagnosticJournal.resourceAttributes().merging([
                    "source": storm.view,
                    "rate_per_second": String(rate),
                    "cpu_percent": String(format: "%.1f", percent),
                    "window_seconds": String(Int(elapsed)),
                ]) { _, new in new })
            return
        }

        guard percent >= alarmingCPU else { return }

        let worst = counts.prefix(5).map { "\($0.view)×\($0.count)" }.joined(separator: " ")
        PlaybackDiagnostics.shared.log("🔥 HIGH CPU \(Int(percent))%",
                                       "over \(Int(elapsed))s — \(worst.isEmpty ? "(none counted)" : worst)")
        DiagnosticJournal.shared.record(
            operation: "process.resourceAnomaly",
            name: "high_cpu",
            attributes: DiagnosticJournal.resourceAttributes().merging([
                "cpu_percent": String(format: "%.1f", percent),
                "window_seconds": String(Int(elapsed)),
                "activity": worst,
            ]) { _, new in new })
    }

    /// Diagnostics must not become the battery problem they are diagnosing. A five-second
    /// forever-timer wakes a background audio app 720 times/hour even when the screen is off and
    /// nothing is wrong. Sample quickly only when explicitly tracing, otherwise adapt to context.
    @MainActor
    private static func scheduleNextSample() {
        let interval: TimeInterval
        if ProcessInfo.processInfo.arguments.contains("--perf-trace") {
            interval = 5
        } else {
            #if os(iOS)
            if AppVisibility.shared.isActive {
                interval = 15
            } else if WakeCoordinator.shared.player.isPlaying {
                interval = 30
            } else {
                interval = 60
            }
            #else
            interval = 20
            #endif
        }
        let next = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { tick() }
        }
        next.tolerance = min(5, interval * 0.2)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private struct KernelCounters {
        var interruptWakeups: UInt64 = 0
        var idleWakeups: UInt64 = 0
        var timerWakeups: UInt64 = 0
        var syscalls: UInt64 = 0
        var contextSwitches: UInt64 = 0
    }

    private static func kernelCounters() -> KernelCounters {
        var result = KernelCounters()

        var power = task_power_info_data_t()
        var powerCount = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
        let powerResult = withUnsafeMutablePointer(to: &power) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(powerCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &powerCount)
            }
        }
        if powerResult == KERN_SUCCESS {
            result.interruptWakeups = power.task_interrupt_wakeups
            result.idleWakeups = power.task_platform_idle_wakeups
            result.timerWakeups = power.task_timer_wakeups_bin_1 + power.task_timer_wakeups_bin_2
        }

        var events = task_events_info_data_t()
        var eventCount = mach_msg_type_number_t(
            MemoryLayout<task_events_info_data_t>.size / MemoryLayout<natural_t>.size)
        let eventResult = withUnsafeMutablePointer(to: &events) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(eventCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &eventCount)
            }
        }
        if eventResult == KERN_SUCCESS {
            result.syscalls = UInt64(max(0, events.syscalls_mach))
                + UInt64(max(0, events.syscalls_unix))
            result.contextSwitches = UInt64(max(0, events.csw))
        }
        return result
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    @MainActor
    private static func thermalContext() -> String {
        #if os(iOS)
        return "\(batterySummary()) net=\(networkSummary()) cpu=\(String(format: "%.1f", latestCPUPercent))%"
        #else
        return "platform=macOS cpu=\(String(format: "%.1f", latestCPUPercent))%"
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func batterySummary() -> String {
        let device = UIDevice.current
        let state: String
        switch device.batteryState {
        case .unknown: state = "unknown"
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        @unknown default: state = "unknown"
        }
        let percent = device.batteryLevel >= 0 ? "\(Int(device.batteryLevel * 100))%" : "unknown"
        return "battery=\(percent)/\(state)"
    }

    @MainActor
    private static func networkSummary() -> String {
        let network = NetworkMonitor.shared
        if !network.isOnline { return "offline" }
        if network.isConstrained { return "constrained" }
        return network.isExpensive ? "expensive" : "normal"
    }
    #endif

    @MainActor
    private static func logPowerRollup(now: Date) {
        let seconds = max(1, now.timeIntervalSince(lastPowerRollupAt))
        let average = powerCPUSum / Double(max(1, powerSampleCount))
        let kernel = kernelCounters()
        let wakeups = delta(kernel.interruptWakeups, lastKernel.interruptWakeups)
            + delta(kernel.idleWakeups, lastKernel.idleWakeups)
            + delta(kernel.timerWakeups, lastKernel.timerWakeups)
        let syscalls = delta(kernel.syscalls, lastKernel.syscalls)
        let switches = delta(kernel.contextSwitches, lastKernel.contextSwitches)
        let thermal = thermalName(ProcessInfo.processInfo.thermalState)

        #if os(iOS)
        let graph = WakeCoordinator.shared
        let play = graph.player.isPlaying
            ? "playing@\(String(format: "%.2f", graph.player.speed))x"
            : (graph.player.hasCurrent ? "paused" : "idle")
        let context = "scene=\(AppVisibility.shared.isActive ? "foreground" : "background") "
            + "audio=\(play) downloads=\(graph.downloads.powerSummary) "
            + "transcribe=\(TranscriptCoordinator.shared.powerSummary) "
            + "watchTx=\(PhoneConnectivity.shared.episodesInFlight) "
            + "\(batterySummary()) net=\(networkSummary())"
        #else
        let context = "platform=macOS"
        #endif

        PlaybackDiagnostics.shared.log(
            "⚡ POWER \(Int(seconds))s",
            String(format: "cpu=%.1f%% avg/%.1f%% max mem=%.0fMB wakeups=%llu syscalls=%llu csw=%llu thermal=%@ lowPower=%@ %@ %@ activity=%@",
                   average, powerCPUMax, MemoryLog.footprintMB(), wakeups, syscalls, switches,
                   thermal, ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no",
                   context, PowerTrace.drainSummary(), latestActivity))

        powerCPUSum = 0
        powerCPUMax = 0
        powerSampleCount = 0
        lastPowerRollupAt = now
        lastKernel = kernel
    }

    /// Total CPU seconds this process has used (user + system), across all threads.
    private static func processCPUSeconds() -> TimeInterval {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return lastCPU }
        let user = TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1_000_000
        let sys = TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1_000_000

        // task_thread_times_info only counts *live* threads. Add the terminated ones so a thread
        // that spun and exited still shows up in the total.
        var basic = task_basic_info()
        var bcount = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<natural_t>.size)
        let berr = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bcount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), $0, &bcount)
            }
        }
        guard berr == KERN_SUCCESS else { return user + sys }
        let deadUser = TimeInterval(basic.user_time.seconds) + TimeInterval(basic.user_time.microseconds) / 1_000_000
        let deadSys = TimeInterval(basic.system_time.seconds) + TimeInterval(basic.system_time.microseconds) / 1_000_000
        return user + sys + deadUser + deadSys
    }
}
