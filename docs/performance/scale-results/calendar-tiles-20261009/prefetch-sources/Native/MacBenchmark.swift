import AppKit
import QuartzCore

@MainActor
final class MacCalendarController: NSViewController {
    let model: PrototypeModel
    let scroll = NSScrollView()
    let surface = CalendarSurface(frame: .zero)
    let document = TimelineDocument(frame: .zero)
    let heading = NSTextField(labelWithString: "Calendar prototype")
    private var observer: NSObjectProtocol?
    init(store: FixtureStore) { model = PrototypeModel(store: store); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic prototype") }
    override func loadView() {
        view = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 850))
        view.wantsLayer = true
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        surface.wantsLayer = true
        scroll.documentView = document; document.addSubview(surface)
        scroll.contentView.postsBoundsChangedNotifications = true
        view.addSubview(scroll); view.addSubview(heading)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let controls = NSStackView(views: [
            NSButton(title: "Previous", target: self, action: #selector(previous)),
            NSButton(title: "Today", target: self, action: #selector(today)),
            NSButton(title: "Next", target: self, action: #selector(next)),
            NSButton(title: "Clear cache", target: self, action: #selector(clearCache))])
        controls.frame = CGRect(x: 12, y: 8, width: 370, height: 30)
        controls.autoresizingMask = [.maxYMargin]
        view.addSubview(controls)
        surface.onSelect = { [weak self] key in self?.heading.stringValue = "Selected event \(key)" }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.surface.update(viewport: self.scroll.contentView.bounds) }
        }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        heading.frame = CGRect(x: 400, y: 12, width: max(1, view.bounds.width - 412), height: 24)
        scroll.frame = CGRect(x: 0, y: 44, width: view.bounds.width, height: max(1, view.bounds.height - 44))
        document.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: CalendarSurface.timelineHeight)
        surface.update(viewport: scroll.contentView.bounds)
    }
    func move(to date: Date) {
        model.move(to: date)
        heading.stringValue = date.formatted(date: .abbreviated, time: .omitted)
        surface.install(model.layouts, viewport: scroll.contentView.bounds)
        model.preloadAdjacent()
        surface.preloadText(store: model.store, date: model.date, dayCount: model.dayCount)
    }
    @objc func previous() { move(to: model.store.calendar.date(byAdding: .day, value: -model.dayCount, to: model.date)!) }
    @objc func next() { move(to: model.store.calendar.date(byAdding: .day, value: model.dayCount, to: model.date)!) }
    @objc func today() { move(to: model.store.anchor) }
    @objc func clearCache() { model.memoryPressure(); surface.evictSpareViews(); move(to: model.date) }
    func counts() -> [String: Any] {
        let viewport = scroll.contentView.bounds
        let actual = Set(surface.presentations.filter { $0.value.intersects(viewport) }.keys)
        return ["attachedEventViews": surface.active.count, "intersectingEventViews": surface.active.values.filter { $0.frame.intersects(viewport) }.count,
                "prefetchedTileBuilds": surface.tiles.prefetchedBuilds, "tileContentsPresent": surface.tiles.contentsPresent, "tileBuilds": surface.tiles.builds, "tilePreparationMS": surface.tiles.preparationMS, "tileCacheBytes": surface.tiles.cache.bytes, "tileCacheCount": surface.tiles.cache.count, "activeTiles": surface.tiles.activeCount, "activeTileBytes": surface.tiles.activeBytes,
                "gridInvalidations": surface.gridInvalidations, "gridDrawMS": surface.gridDrawMS, "eventDrawMS": surface.eventDrawMS, "gridDrawCount": surface.gridDrawCount, "eventDrawCount": surface.eventDrawCount,
                "accessibilityCreatedElements": surface.accessibilityCreatedElements, "accessibilityWorkMS": surface.accessibilityWorkMS,
                "visiblePresentations": actual.count, "textBuilds": surface.textBuilds, "prefetchedTextBuilds": surface.prefetchedTextBuilds, "peakResidentBytes": peakResidentBytes(),
                "drawCoverageMatches": surface.optimizations.renderer == "cells" || actual.isSubset(of: surface.drawnIDs),
                "visibleIDsMatch": actual == surface.expectedVisibleIDs(viewport) && !actual.isEmpty,
                "requestedDatePresent": model.date == model.layouts.first?.date,
                "rasterBuilds": surface.rasterBuilds, "prefetchedRasterBuilds": surface.prefetchedRasterBuilds,
                "rasterContentsPresent": surface.rasterContentsPresent, "rasterCacheBytes": surface.rasterCache.bytes, "rasterCachedPages": surface.rasterCache.count,
                "rasterPreparationMS": surface.rasterPreparationMS,
                "cachedDays": model.cache.count, "geometryBuilds": model.geometryBuilds,
                "prefetchBuilds": model.prefetchBuilds, "createdCells": surface.createdCells,
                "viewportReconciliations": surface.reconciliations]
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@main
@MainActor
final class MacBenchmark: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: MacCalendarController!
    let config = Configuration()
    var samples: [[String: Any]] = []
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 60, y: 80, width: 1200, height: 850), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Calendar Renderer Prototype — Isolated Fixtures"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await run() }
    }
    func timed(_ phase: String, _ action: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        action()
        let afterAction = ProcessInfo.processInfo.systemUptime
        controller.view.layoutSubtreeIfNeeded()
        let afterLayout = ProcessInfo.processInfo.systemUptime
        window.displayIfNeeded()
        let afterDisplay = ProcessInfo.processInfo.systemUptime
        CATransaction.flush()
        let afterFlush = ProcessInfo.processInfo.systemUptime
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        var sample: [String: Any] = ["phase": phase, "milliseconds": ms, "actionMS": (afterAction - start) * 1000, "layoutMS": (afterLayout - afterAction) * 1000, "displayMS": (afterDisplay - afterLayout) * 1000, "flushMS": (afterFlush - afterDisplay) * 1000]
        sample.merge(controller.counts(), uniquingKeysWith: { _, b in b }); samples.append(sample)
    }
    func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }
    func run() async {
        let began = ProcessInfo.processInfo.systemUptime
        let store = FixtureStore(config)
        let fixtureMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        timed("coldMount") {
            controller = MacCalendarController(store: store)
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            controller.move(to: store.anchor)
        }
        if config.args.contains("--interactive") || !config.args.contains("--output") { return }
        await settle(); timed("settledLayout") {}
        for index in 0..<12 {
            let offset = index.isMultiple(of: 2) ? controller.model.dayCount : 0
            timed("page") { controller.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!) }
            await settle(); timed("settledLayout") {}
        }
        for step in 0..<120 {
            let fraction = Double(step < 60 ? step : 119 - step) / 59
            timed("scrollOffset") {
                let clip = controller.scroll.contentView
                clip.scroll(to: CGPoint(x: 0, y: max(0, CalendarSurface.timelineHeight - clip.bounds.height) * fraction))
                controller.scroll.reflectScrolledClipView(clip)
                controller.surface.update(viewport: clip.bounds)
            }
            try? await Task.sleep(nanoseconds: 8_333_333)
        }
        let primary = samples
        samples = []
        for offset in [8, 9, 10, 11, 12, 13] {
            timed("uncachedPage") {
                controller.model.memoryPressure()
                controller.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!)
            }
            await settle()
        }
        timed("memoryPressurePage") { controller.clearCache() }
        for width in [800.0, 1400.0, 1000.0] {
            timed("resize") { window.setContentSize(CGSize(width: width, height: 850)) }
        }
        let report: [String: Any] = ["schemaVersion": 4, "candidate": "native", "mode": config.mode, "feed": "bounded",
            "days": config.days, "eventsPerDay": config.density, "retainedEvents": config.days * config.density,
            "optimizations": ["renderer": controller.surface.optimizations.renderer, "ablation": controller.surface.optimizations.disabled],
            "fixtureGenerationMS": fixtureMS, "samples": primary, "experiments": samples,
            "verticalScrollFound": true, "screen": ["width": 1200, "height": 850],
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "timeZone": store.calendar.timeZone.identifier,
            "scope": "AppKit synchronous API/layout/displayIfNeeded/flush; not input-to-visible or compositor delivery",
            "acceptance": "unmeasured", "missing": ["input latency", "display delivery", "feature parity"]]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: config.value("--output", "/tmp/native-calendar-result.json")), options: .atomic)
        NSApp.terminate(nil)
    }
    static func main() {
        let app = NSApplication.shared
        let delegate = MacBenchmark()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Calendar Renderer Prototype")
        let quit = NSMenuItem(title: "Quit Calendar Renderer Prototype", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        applicationMenu.addItem(quit); applicationItem.submenu = applicationMenu; menu.addItem(applicationItem)
        app.mainMenu = menu
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
