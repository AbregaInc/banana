import UIKit
import EventKit
import CalendarKit
import KVKCalendar

// Isolated renderer benchmark. No account, provider, production store or write-back access.
// Measures synchronous API/layout/flush work, NOT input-to-visible or display delivery.
@MainActor
final class CKController: DayViewController {
    let store: FixtureStore
    init(store: FixtureStore) { self.store = store; super.init(nibName: nil, bundle: nil); calendar = store.calendar }
    required init?(coder: NSCoder) { fatalError("Programmatic benchmark") }
    override func eventsForDate(_ date: Date) -> [EventDescriptor] {
        store.day(date).map { item in
            let event = CalendarKit.Event()
            event.dateInterval = DateInterval(start: item.start, end: item.end)
            event.text = item.title ?? "Event \(item.id)"
            if item.title != nil { event.color = UIColor(cgColor: FixturePalette.colors[item.calendarIndex]) }
            event.userInfo = item.id
            return event
        }
    }
}

@MainActor
final class KVKController: UIViewController, CalendarDataSource {
    let store: FixtureStore
    var date: Date
    var widget: KVKCalendarView!
    var items: [KVKCalendar.Event] = []
    init(store: FixtureStore) { self.store = store; date = store.anchor; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic benchmark") }
    override func viewDidLoad() {
        super.viewDidLoad()
        var style = Style()
        style.calendar = store.calendar
        style.timezone = store.calendar.timeZone
        style.defaultType = store.config.mode == "week" ? .week : .day
        style.week.daysInOneWeek = 5
        widget = KVKCalendarView(frame: view.bounds, date: date, style: style, years: 4)
        widget.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        widget.dataSource = self
        view.addSubview(widget)
    }
    func refresh() {
        if store.config.feed != "full" || items.isEmpty {
          let hidden = store.config.hiddenCalendars
          let rows = store.config.feed == "full" ? store.byDay.values.flatMap { $0 }.filter { !hidden.contains($0.calendarIndex) } : store.window(date)
          items = rows.map { item in
            var event = KVKCalendar.Event(ID: item.id)
            event.start = item.start
            event.end = item.end
            event.title = TextEvent(timeline: item.title ?? "Event \(item.id)")
            if item.title != nil { event.color = KVKCalendar.Event.Color(UIColor(cgColor: FixturePalette.colors[item.calendarIndex])) }
            return event
          }
        }
        widget.reloadData()
    }
    func move(to date: Date) {
        self.date = date
        // Bounded feed is app-side adaptation, not a library modification; account for its cost.
        widget.scrollTo(date, animated: false)
        refresh()
    }
    func eventsForCalendar(systemEvents: [EKEvent]) -> [KVKCalendar.Event] { items }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Benchmark", sessionRole: session.role)
        configuration.delegateClass = BenchmarkSceneDelegate.self
        return configuration
    }
}

final class BenchmarkSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = BenchmarkController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

@MainActor
final class BenchmarkController: UIViewController {
    let config = CalendarFixtureConfiguration()
    var candidate: UIViewController!
    var store: FixtureStore!
    var samples: [[String: Any]] = []
    let status = UILabel()
    var running = false
    var page = 0
    var lifecycleEvents: [[String: Any]] = []
    var lifecycleStart = 0.0
    @objc func recordLifecycle(_ notification: Notification) {
        lifecycleEvents.append(["notification": notification.name.rawValue,
            "elapsedMS": (ProcessInfo.processInfo.systemUptime - lifecycleStart) * 1000])
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = "Preparing isolated calendar benchmark"
        status.accessibilityIdentifier = "benchmark.status"
        status.numberOfLines = 2
        view.addSubview(status)
        Task { await run() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        status.frame = CGRect(x: 12, y: view.safeAreaInsets.top, width: view.bounds.width - 24, height: 52)
        candidate?.view.frame = CGRect(x: 0, y: view.safeAreaInsets.top + 56, width: view.bounds.width,
                                      height: max(1, view.bounds.height - view.safeAreaInsets.top - 56))
    }
    func timed(_ phase: String, _ action: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        action()
        view.layoutIfNeeded()
        if config.args.contains("--exercise-accessibility"), let native = candidate as? NativeController {
            native.exerciseAccessibility()
        }
        CATransaction.flush()
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var sample: [String: Any] = ["phase": phase, "milliseconds": elapsed]
        sample.merge(counts(), uniquingKeysWith: { _, b in b })
        samples.append(sample)
    }
    func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
    func counts() -> [String: Any] {
        guard let candidate else { return [:] }
        let all = descendants(candidate.view)
        let events = all.filter {
            $0 is NativeEventCell || $0 is CalendarKit.EventView || String(reflecting: type(of: $0)) == "KVKCalendar.EventView"
        }
        let visible = events.filter { event in
            guard !event.isHidden && !event.bounds.isEmpty else { return false }
            var rect = event.convert(event.bounds, to: view).intersection(view.bounds)
            var ancestor = event.superview
            while let parent = ancestor {
                if parent.isHidden { return false }
                if parent.clipsToBounds { rect = rect.intersection(parent.convert(parent.bounds, to: view)) }
                ancestor = parent.superview
            }
            return !rect.isNull && !rect.isEmpty
        }
        var result: [String: Any] = ["attachedViews": all.count, "attachedEventViews": events.count, "intersectingEventViews": visible.count]
        if let kvk = candidate as? KVKController {
            let expected = store.calendar.startOfDay(for: kvk.date)
            result["requestedDatePresent"] = events.compactMap { $0 as? EventViewGeneral }.contains {
                !$0.bounds.isEmpty && store.calendar.isDate($0.event.start, inSameDayAs: expected)
            }
        }
        if let native = candidate as? NativeController { result.merge(native.validation(), uniquingKeysWith: { _, b in b }) }
        return result
    }
    func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }
    func move(_ delta: Int) {
        page += delta
        let date = store.calendar.date(byAdding: .day, value: page, to: store.anchor)!
        if let ck = candidate as? CKController { ck.move(to: date) }
        if let kvk = candidate as? KVKController { kvk.move(to: date) }
        if let native = candidate as? NativeController { native.move(to: date) }
    }
    func foregroundTimed(_ phase: String, date: Date, clearCache: Bool = false) async -> [String: Any] {
        let native = candidate as! NativeController
        let workers = Optimizations().tileForegroundWorkers
        let began = ProcessInfo.processInfo.systemUptime
        if clearCache { native.memoryPressure() }
        let clearMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let beforeBuilds = native.surface.tiles.builds
        let moveStart = ProcessInfo.processInfo.systemUptime
        let completed: Bool
        if workers == 0 { native.move(to: date); completed = true }
        else { completed = await native.movePrepared(to: date, workers: workers) }
        let moveMS = (ProcessInfo.processInfo.systemUptime - moveStart) * 1000
        let flushStart = ProcessInfo.processInfo.systemUptime
        view.layoutIfNeeded()
        if config.args.contains("--exercise-accessibility") { native.exerciseAccessibility() }
        CATransaction.flush()
        let flushMS = (ProcessInfo.processInfo.systemUptime - flushStart) * 1000
        let responseMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        var sections = [clearMS, flushMS]
        if workers == 0 { sections.append(moveMS) }
        else if let last = native.asyncNavigationSamples.last {
            sections += [last["modelMS"] as? Double ?? -1, last["installMS"] as? Double ?? -1,
                         last["tileMainSectionsMS"] as? Double ?? -1]
        }
        var sample: [String: Any] = ["phase": phase, "workers": workers,
            "responseMS": responseMS, "mainSectionsMS": sections, "measuredMainMS": sections.reduce(0, +),
            "maxMainSectionMS": sections.max() ?? 0, "completed": completed,
            "requestedDateMatches": native.model.date == store.calendar.startOfDay(for: date),
            "unexpectedSyncTileBuilds": workers == 0 ? 0 : native.surface.tiles.builds - beforeBuilds]
        if workers > 0 { sample["installDetailsMS"] = native.asyncNavigationSamples.last?["installDetailsMS"] }
        sample.merge(counts(), uniquingKeysWith: { _, b in b })
        return sample
    }

    func run() async {
        guard !running else { return }; running = true
        // Automated rendering must remain visible; restore normal idle behavior on every return.
        let application = UIApplication.shared
        let previousIdleTimer = application.isIdleTimerDisabled
        application.isIdleTimerDisabled = true
        defer { application.isIdleTimerDisabled = previousIdleTimer }
        let foregroundWaitStart = ProcessInfo.processInfo.systemUptime
        while application.applicationState != .active &&
              ProcessInfo.processInfo.systemUptime - foregroundWaitStart < 10 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard application.applicationState == .active else {
            status.text = "Benchmark unmeasured: foreground activation timed out"
            return
        }
        lifecycleStart = ProcessInfo.processInfo.systemUptime
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(recordLifecycle(_:)), name: name, object: nil)
        }
        defer { NotificationCenter.default.removeObserver(self) }
        precondition(["ck", "kvk", "native"].contains(config.candidate))
        precondition(config.days >= 30 && config.days <= 3650 && config.density >= 1 && config.density <= 1000)
        if config.value("--check", "") == "accessibility" {
            let report = AccessibilityProbe.run(config)
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(config.value("--output", "accessibility-check.json"))
            try! data.write(to: output, options: .atomic)
            status.text = "Accessibility checks: \(report["status"]!)"
            status.accessibilityIdentifier = "benchmark.complete"
            return
        }
        let began = ProcessInfo.processInfo.systemUptime
        store = FixtureStore(config)
        let fixtureMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        if config.value("--check", "") == "raster-pixels" {
            let report = await RasterConcurrencyProbe.run(store: store, width: view.bounds.width,
                scale: view.window?.screen.scale ?? UIScreen.main.scale)
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(config.value("--output", "raster-pixels.json"))
            try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
            status.text = "Raster pixels: \(report["status"]!)"
            status.accessibilityIdentifier = "benchmark.complete"
            return
        }
        timed("coldMount") {
            switch config.candidate {
            case "ck": candidate = CKController(store: store)
            case "kvk": candidate = KVKController(store: store)
            default: candidate = NativeController(store: store)
            }
            addChild(candidate)
            view.addSubview(candidate.view)
            candidate.didMove(toParent: self)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if let ck = candidate as? CKController { ck.move(to: store.anchor) }
            if let kvk = candidate as? KVKController { kvk.move(to: store.anchor) }
            if let native = candidate as? NativeController { native.move(to: store.anchor) }
        }
        await settle()
        if config.value("--check", "") == "navigation" {
            precondition(config.candidate == "native")
            let report = await NavigationProbe.run(candidate as! NativeController)
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(config.value("--output", "navigation-check.json"))
            try! data.write(to: output, options: .atomic)
            status.text = "Navigation checks: \(report["status"]!)"
            status.accessibilityIdentifier = "benchmark.complete"
            return
        }
        if config.args.contains("--interactive") {
            precondition(config.candidate == "native", "Interactive touch checks target the native prototype")
            status.text = "\(config.fixture) · \(config.calendarCount) calendars · \(config.density) avg/day"
            status.accessibilityIdentifier = "benchmark.interactive.ready"
            return
        }
        timed("settledLayout") {}
        for index in 0..<12 {
            timed("page") { move(index.isMultiple(of: 2) ? (config.mode == "week" ? 5 : 1) : (config.mode == "week" ? -5 : -1)) }
            await settle()
            timed("settledLayout") {}
        }
        let scrolls = descendants(candidate.view).compactMap { $0 as? UIScrollView }
            .filter { $0.contentSize.height > $0.bounds.height + 200 && $0.bounds.height > 100 }
        let scroll = scrolls.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        if let scroll {
            for step in 0..<120 {
                let fraction = Double(step < 60 ? step : 119 - step) / 59
                timed("scrollOffset") {
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                        y: max(0, scroll.contentSize.height - scroll.bounds.height) * fraction), animated: false)
                }
                try? await Task.sleep(nanoseconds: 8_333_333)
            }
        }
        let primaryElapsedMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let primary = samples
        samples = []
        if let native = candidate as? NativeController {
            for offset in [8, 9, 10, 11, 12, 13] {
                timed("uncachedPage") {
                    native.memoryPressure()
                    native.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!)
                }
                await settle()
            }
            timed("memoryPressurePage") { native.memoryPressure(); native.move(to: native.model.date) }
            let originalFrame = native.view.frame
            for factor in [0.7, 1.0, 0.85] {
                timed("resize") {
                    native.view.frame.size.width = originalFrame.width * factor
                    native.view.setNeedsLayout()
                    native.view.layoutIfNeeded()
                }
            }
            native.view.frame = originalFrame
        }
        let recoveryElapsedMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let recoveryExperiments = samples
        samples = []
        let navigationStress = ProcessInfo.processInfo.arguments.contains("--navigation-stress")
        if navigationStress, let native = candidate as? NativeController {
            page = store.calendar.dateComponents([.day], from: store.anchor, to: native.model.date).day!
            await settle()
            let stride = config.mode == "week" ? 5 : 1
            for (phase, delta, delay) in [("forwardPage", stride, UInt64(250_000_000)),
                                          ("returnPage", -stride, UInt64(250_000_000)),
                                          ("rapidForwardPage", stride, UInt64(32_000_000)),
                                          ("rapidReturnPage", -stride, UInt64(32_000_000))] {
                for _ in 0..<12 {
                    timed(phase) { move(delta) }
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        let navigationElapsedMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let navigationExperiments = samples
        let foregroundNavigation = config.args.contains("--foreground-navigation")
        var foregroundExperiments: [[String: Any]] = []
        if foregroundNavigation {
            precondition(config.candidate == "native" && Optimizations().renderer == "tiles")
            var offset = 30
            func date(_ offset: Int) -> Date { store.calendar.date(byAdding: .day, value: offset, to: store.anchor)! }
            foregroundExperiments.append(await foregroundTimed("foregroundColdPage", date: date(offset), clearCache: true))
            await settle()
            for index in 0..<12 {
                offset += index.isMultiple(of: 2) ? 5 : -5
                foregroundExperiments.append(await foregroundTimed("foregroundWarmPage", date: date(offset)))
                await settle()
            }
            for index in 0..<6 {
                offset = 100 + index * 5
                foregroundExperiments.append(await foregroundTimed("foregroundUncachedPage", date: date(offset), clearCache: true))
                await settle()
            }
            foregroundExperiments.append(await foregroundTimed("foregroundMemoryPressurePage", date: date(offset), clearCache: true))
            await settle()
            for (phase, delta, delay) in [("foregroundForwardPage", 5, UInt64(250_000_000)),
                                          ("foregroundReturnPage", -5, UInt64(250_000_000)),
                                          ("foregroundRapidForwardPage", 5, UInt64(32_000_000)),
                                          ("foregroundRapidReturnPage", -5, UInt64(32_000_000))] {
                for _ in 0..<12 {
                    offset += delta
                    foregroundExperiments.append(await foregroundTimed(phase, date: date(offset)))
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        let workloadElapsedMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let metadataStart = ProcessInfo.processInfo.systemUptime
        let fixtureMetadata = store.fixtureSummary
        let metadataMS = (ProcessInfo.processInfo.systemUptime - metadataStart) * 1000
        let report: [String: Any] = [
            "foregroundProtocol": ["version": 1, "idleTimerDisabledDuringRun": true,
                "activationWaitMS": (lifecycleStart - foregroundWaitStart) * 1000,
                "activeAtCompletion": application.applicationState == .active, "transitions": lifecycleEvents],
            "collectionDiagnostics": ["throughPrimaryMS": primaryElapsedMS,
                "throughRecoveryMS": recoveryElapsedMS, "throughNavigationMS": navigationElapsedMS,
                "workloadMS": workloadElapsedMS, "fixtureMetadataMS": metadataMS],
            "schemaVersion": 7, "fixture": fixtureMetadata, "batchEventFills": config.args.contains("--batch-event-fills"), "memoRasterText": config.args.contains("--memo-raster-text"), "timeZone": store.calendar.timeZone.identifier, "candidate": config.candidate, "mode": config.mode, "feed": config.feed,
            "days": config.days, "eventsPerDay": config.density, "retainedEvents": config.days * config.density,
            "optimizations": ["renderer": Optimizations().renderer, "ablation": Optimizations().disabled],
            "fixtureGenerationMS": fixtureMS, "samples": primary, "experiments": recoveryExperiments, "verticalScrollFound": scroll != nil,
            "navigationStress": navigationStress, "navigationExperiments": navigationExperiments,
            "foregroundNavigation": foregroundNavigation, "foregroundExperiments": foregroundExperiments,
            "accessibilityClient": config.args.contains("--exercise-accessibility") ? "all" : "none",
            "screen": ["width": view.bounds.width, "height": view.bounds.height,
                       "scale": view.window?.screen.scale ?? UIScreen.main.scale,
                       "maximumFramesPerSecond": view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond],
            "deviceModel": UIDevice.current.model,
            "thermalStateAtCompletion": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerModeAtCompletion": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "voiceOverRunningAtCompletion": UIAccessibility.isVoiceOverRunning,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Primary: synchronous API/layout/flush. Foreground: request-to-publication and measured main sections. Programmatic input; NOT input-to-visible or display delivery",
            "acceptance": "unmeasured", "missing": ["display delivery", "input latency", "interactive feature parity", "AppKit integration"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(config.value("--output", "result.json"))
        try! data.write(to: output, options: .atomic)
        status.text = "Benchmark complete: \(config.candidate) · \(config.mode) · \(config.days * config.density) events"
        status.accessibilityIdentifier = "benchmark.complete"
    }
}
