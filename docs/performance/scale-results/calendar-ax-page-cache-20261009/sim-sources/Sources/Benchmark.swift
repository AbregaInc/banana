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
            event.text = "Event \(item.id)"
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
          let rows = store.config.feed == "full" ? store.byDay.values.flatMap { $0 } : store.window(date)
          items = rows.map { item in
            var event = KVKCalendar.Event(ID: item.id)
            event.start = item.start
            event.end = item.end
            event.title = TextEvent(timeline: "Event \(item.id)")
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
    let config = Configuration()
    var candidate: UIViewController!
    var store: FixtureStore!
    var samples: [[String: Any]] = []
    let status = UILabel()
    var running = false
    var page = 0
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
    func run() async {
        guard !running else { return }; running = true
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
        let report: [String: Any] = [
            "schemaVersion": 4, "timeZone": store.calendar.timeZone.identifier, "candidate": config.candidate, "mode": config.mode, "feed": config.feed,
            "days": config.days, "eventsPerDay": config.density, "retainedEvents": config.days * config.density,
            "optimizations": ["renderer": Optimizations().renderer, "ablation": Optimizations().disabled],
            "fixtureGenerationMS": fixtureMS, "samples": primary, "experiments": samples, "verticalScrollFound": scroll != nil,
            "screen": ["width": view.bounds.width, "height": view.bounds.height,
                       "scale": view.window?.screen.scale ?? UIScreen.main.scale,
                       "maximumFramesPerSecond": view.window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond],
            "deviceModel": UIDevice.current.model,
            "thermalStateAtCompletion": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerModeAtCompletion": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "voiceOverRunningAtCompletion": UIAccessibility.isVoiceOverRunning,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Synchronous API + layout + CATransaction.flush work; programmatic paging/offsets, NOT input-to-visible or full frame delivery",
            "acceptance": "unmeasured", "missing": ["display delivery", "input latency", "interactive feature parity", "AppKit integration"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(config.value("--output", "result.json"))
        try! data.write(to: output, options: .atomic)
        status.text = "Benchmark complete: \(config.candidate) · \(config.mode) · \(config.days * config.density) events"
        status.accessibilityIdentifier = "benchmark.complete"
    }
}
