import AppKit
import QuartzCore

@MainActor
final class MacCalendarController: NSViewController {
    let model: PrototypeModel
    let scroll = NSScrollView()
    let surface = CalendarSurface(frame: .zero)
    let document = TimelineDocument(frame: .zero)
    let heading = NSTextField(labelWithString: "Calendar prototype")
    private var navigationTask: Task<Void, Never>?
    private var navigationGeneration = 0
    private var requestedDate: Date?
    private(set) var asyncNavigationSamples: [[String: Any]] = []
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
            NSButton(title: "Clear cache", target: self, action: #selector(clearCacheFromControls))])
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
        navigationGeneration &+= 1; navigationTask?.cancel(); requestedDate = nil
        model.move(to: date)
        heading.stringValue = date.formatted(date: .abbreviated, time: .omitted)
        surface.install(model.layouts, viewport: scroll.contentView.bounds)
        model.preloadAdjacent()
        surface.preloadText(store: model.store, date: model.date, dayCount: model.dayCount)
    }
    /// Old heading/pixels/accessibility remain coherent while a new page is prepared.
    /// These timings end at API publication, not at physical display delivery.
    func movePrepared(to date: Date, workers: Int) async -> Bool {
        guard !Task.isCancelled else { return false }
        precondition((1...2).contains(workers))
        navigationGeneration &+= 1
        let token = navigationGeneration
        defer { if navigationGeneration == token { requestedDate = nil } }
        let began = ProcessInfo.processInfo.systemUptime
        let layouts = model.resolve(to: date)
        let modelMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        while !Task.isCancelled && navigationGeneration == token {
            let viewport = scroll.contentView.bounds, width = scroll.contentView.bounds.width
            let scale = view.window?.backingScaleFactor ?? 1
            guard let prepared = await surface.prepareTiles(layouts, viewport: viewport, workers: workers) else { return false }
            guard !Task.isCancelled, navigationGeneration == token else { return false }
            // Resizing or scrolling during preparation must not publish a band for old bounds.
            if scroll.contentView.bounds != viewport || scroll.contentView.bounds.width != width || (view.window?.backingScaleFactor ?? 1) != scale { continue }
            let installStart = ProcessInfo.processInfo.systemUptime
            model.move(to: date, prepared: layouts)
            let modelCommitted = ProcessInfo.processInfo.systemUptime
            surface.install(layouts, viewport: viewport, prepared: prepared)
            let surfaceInstalled = ProcessInfo.processInfo.systemUptime
            heading.stringValue = model.date.formatted(date: .abbreviated, time: .omitted)
            requestedDate = nil
            let headingUpdated = ProcessInfo.processInfo.systemUptime
            model.preloadAdjacent()
            let geometryScheduled = ProcessInfo.processInfo.systemUptime
            surface.preloadText(store: model.store, date: model.date, dayCount: model.dayCount)
            let tilesScheduled = ProcessInfo.processInfo.systemUptime
            let installMS = (tilesScheduled - installStart) * 1000
            asyncNavigationSamples.append(["workers": workers, "totalMS": (ProcessInfo.processInfo.systemUptime - began) * 1000,
                "modelMS": modelMS, "installMS": installMS,
                "installDetailsMS": ["modelCommit": (modelCommitted - installStart) * 1000,
                    "surfaceInstall": (surfaceInstalled - modelCommitted) * 1000,
                    "heading": (headingUpdated - surfaceInstalled) * 1000,
                    "geometryPreload": (geometryScheduled - headingUpdated) * 1000,
                    "tilePreload": (tilesScheduled - geometryScheduled) * 1000],
                "tileMainSectionsMS": surface.tiles.foregroundDispatchMS + surface.tiles.foregroundCompletionMS,
                "date": model.date.timeIntervalSinceReferenceDate, "tileBuilds": surface.tiles.builds,
                "foregroundBuilds": surface.tiles.foregroundBuilds])
            // Interactive diagnostic retention is bounded independently of calendar history.
            if asyncNavigationSamples.count > 128 { asyncNavigationSamples.removeFirst(asyncNavigationSamples.count - 128) }
            return true
        }
        return false
    }
    private func moveInteractive(to date: Date) {
        let workers = surface.optimizations.tileForegroundWorkers
        if workers == 0 { move(to: date); return }
        requestedDate = date; navigationGeneration &+= 1; navigationTask?.cancel()
        navigationTask = Task { [weak self] in _ = await self?.movePrepared(to: date, workers: workers) }
    }
    @objc func previous() { moveInteractive(to: model.store.calendar.date(byAdding: .day, value: -model.dayCount, to: requestedDate ?? model.date)!) }
    @objc func next() { moveInteractive(to: model.store.calendar.date(byAdding: .day, value: model.dayCount, to: requestedDate ?? model.date)!) }
    @objc func today() { moveInteractive(to: model.store.anchor) }
    func memoryPressure() {
        navigationGeneration &+= 1; navigationTask?.cancel(); requestedDate = nil
        model.memoryPressure(); surface.evictSpareViews()
    }
    @objc func clearCache() { memoryPressure(); move(to: model.date) }
    @objc func clearCacheFromControls() {
        if model.store.config.args.contains("--async-cache-recovery") {
            memoryPressure()
            moveInteractive(to: model.date)
        } else { clearCache() }
    }
    /// Controlled cache-recovery component ablation; UI delivery is measured separately.
    func benchmarkInteractiveRecovery() async -> [String: Any] {
        var samples: [[String: Any]] = []
        for index in 0..<21 {
            try? await Task.sleep(nanoseconds: 80_000_000)
            let date = model.date, beforeBuilds = surface.tiles.builds
            let beforeSamples = asyncNavigationSamples.count
            let began = ProcessInfo.processInfo.systemUptime
            clearCacheFromControls()
            let actionEnd = ProcessInfo.processInfo.systemUptime
            let deadline = began + 3
            while requestedDate != nil && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            let flushStart = ProcessInfo.processInfo.systemUptime
            view.window?.displayIfNeeded(); CATransaction.flush()
            let end = ProcessInfo.processInfo.systemUptime
            let asynchronous = model.store.config.args.contains("--async-cache-recovery")
            let navigation = asynchronous && asyncNavigationSamples.count > beforeSamples ? asyncNavigationSamples.last : nil
            let actionMS = (actionEnd - began) * 1000, flushMS = (end - flushStart) * 1000
            var sections = [actionMS, flushMS]
            if let navigation {
                sections += [navigation["modelMS"] as! Double, navigation["installMS"] as! Double,
                             navigation["tileMainSectionsMS"] as! Double]
            }
            let coverage = counts()
            samples.append(["index": index, "responseMS": (end - began) * 1000,
                "actionMS": actionMS, "flushMS": flushMS, "mainSectionsMS": sections,
                "completed": requestedDate == nil && model.date == date,
                "visibleIDsMatch": coverage["visibleIDsMatch"] as? Bool ?? false,
                "drawCoverageMatches": coverage["drawCoverageMatches"] as? Bool ?? false,
                "unexpectedSyncTileBuilds": asynchronous ? surface.tiles.builds - beforeBuilds : 0,
                "asyncSamplePresent": !asynchronous || navigation != nil,
                "peakResidentBytes": peakResidentBytes(), "physicalFootprintBytes": physicalFootprintBytes()])
        }
        return ["scope": "Cache eviction through API flush; includes awaited preparation; not input-to-visible or frame timing",
            "eventsPerDay": model.store.config.density,
            "asyncRecoveryRequested": model.store.config.args.contains("--async-cache-recovery"),
            "foregroundDispatchRequested": model.store.config.args.contains("--foreground-dispatch"),
            "nativeTextRequested": surface.optimizations.tileNativeText,
            "samples": samples]
    }

    func checkInteractiveRecovery() async -> [String: Any] {
        var checks = 0, failures: [String] = []
        let asynchronous = model.store.config.args.contains("--async-cache-recovery")
        func check(_ value: Bool, _ message: String) { checks += 1; if !value { failures.append(message) } }
        func date(_ offset: Int) -> Date { model.store.calendar.date(byAdding: .day, value: offset, to: model.store.anchor)! }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return condition()
        }
        check(surface.optimizations.tileForegroundWorkers == 2, "Recovery probe requires two workers")
        for trial in 0..<3 {
            let initial = date(trial * 30)
            move(to: initial)
            let headingBefore = heading.stringValue, boundsBefore = scroll.contentView.bounds
            let buildsBefore = surface.tiles.builds
            clearCacheFromControls()
            check(model.date == initial && heading.stringValue == headingBefore &&
                  scroll.contentView.bounds == boundsBefore && surface.tiles.contentsPresent,
                  "Recovery immediately changed date, viewport, or visible pixels")
            let started = asynchronous ? await wait { self.surface.tiles.isPreparingForeground } : true
            check(started, "Async recovery did not start")
            let completed = await wait { self.requestedDate == nil }
            check(completed && model.date == initial && counts()["drawCoverageMatches"] as? Bool == true &&
                  (!asynchronous || surface.tiles.builds == buildsBefore), "Recovery failed or rendered synchronously")
            clearCacheFromControls(); next()
            let advanced = await wait { self.requestedDate == nil }
            check(advanced && model.date == date(trial * 30 + model.dayCount), "Navigation during recovery lost intent")
            let beforeCancel = model.date
            clearCacheFromControls(); memoryPressure()
            try? await Task.sleep(nanoseconds: 50_000_000)
            check(model.date == beforeCancel && requestedDate == nil && surface.tiles.contentsPresent,
                  "Cancelled recovery changed presentation")
            next()
            let recovered = await wait { self.requestedDate == nil }
            check(recovered && model.date == date(trial * 30 + model.dayCount * 2) &&
                  counts()["drawCoverageMatches"] as? Bool == true, "Navigation after recovery cancellation failed")
        }
        return ["status": failures.isEmpty ? "passed" : "failed", "checks": checks, "failures": failures,
                "eventsPerDay": model.store.config.density, "asyncRecoveryRequested": asynchronous,
                "scope": "Native controller cache-recovery correctness, not input/display timing"]
    }

    /// Same supersession/eviction oracle as the UIKit controller, on native AppKit.
    func checkNavigation() async -> [String: Any] {
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append(message) }
        }
        func date(_ offset: Int) -> Date {
            model.store.calendar.date(byAdding: .day, value: offset, to: model.store.anchor)!
        }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return condition()
        }
        check(surface.optimizations.tileForegroundWorkers == 2, "Probe requires two foreground workers")
        for trial in 0..<10 {
            let start = trial * 10
            move(to: date(start)); memoryPressure()
            next()
            let started = await wait { self.surface.tiles.isPreparingForeground }
            check(started, "Foreground preparation did not start in trial \(trial)")
            check(model.date == date(start), "Pending work changed the published model")
            next()
            await Task.yield()
            next()
            let completed = await wait { self.requestedDate == nil }
            check(completed && model.date == date(start + model.dayCount * 3),
                  "Rapid supersession lost navigation intent in trial \(trial)")
            let state = counts()
            check(state["visibleIDsMatch"] as? Bool == true && state["drawCoverageMatches"] as? Bool == true,
                  "Rapid supersession published stale pixels")
        }
        move(to: date(0)); memoryPressure(); next()
        let started = await wait { self.surface.tiles.isPreparingForeground }
        check(started, "Eviction race did not start")
        memoryPressure()
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(model.date == date(0) && requestedDate == nil, "Evicted request published after cancellation")
        next()
        let recovered = await wait { self.requestedDate == nil }
        check(recovered && model.date == date(model.dayCount), "Navigation did not recover after eviction")
        return ["status": failures.isEmpty ? "passed" : "failed", "checks": checks, "failures": failures,
                "scope": "AppKit controller cancellation/supersession correctness, not UI latency",
                "eventsPerDay": model.store.config.density]
    }
    func counts() -> [String: Any] {
        let viewport = scroll.contentView.bounds
        let actual = Set(surface.presentations.filter { $0.value.intersects(viewport) }.keys)
        return ["attachedEventViews": surface.active.count, "intersectingEventViews": surface.active.values.filter { $0.frame.intersects(viewport) }.count,
                "prefetchedTileBuilds": surface.tiles.prefetchedBuilds, "tileContentsPresent": surface.tiles.contentsPresent, "tileBuilds": surface.tiles.builds, "tilePreparationMS": surface.tiles.preparationMS, "tileCacheBytes": surface.tiles.cache.bytes, "tileCacheCount": surface.tiles.cache.count, "activeTiles": surface.tiles.activeCount, "activeTileBytes": surface.tiles.activeBytes,
                "gridInvalidations": surface.gridInvalidations, "gridDrawMS": surface.gridDrawMS, "eventDrawMS": surface.eventDrawMS, "gridDrawCount": surface.gridDrawCount, "eventDrawCount": surface.eventDrawCount,
                "accessibilityCreatedElements": surface.accessibilityCreatedElements, "accessibilityWorkMS": surface.accessibilityWorkMS,
                "accessibilityCachedPages": surface.accessibilityCachedPages, "accessibilityCachedElements": surface.accessibilityCachedElements, "accessibilityPageHits": surface.accessibilityPageHits,
                "accessibilityElementQueries": surface.accessibilityElementQueries, "accessibilityMaterializedElements": surface.accessibilityMaterializedElements,
                "visiblePresentations": actual.count, "textBuilds": surface.textBuilds, "prefetchedTextBuilds": surface.prefetchedTextBuilds, "peakResidentBytes": peakResidentBytes(), "physicalFootprintBytes": physicalFootprintBytes(),
                "drawCoverageMatches": surface.optimizations.renderer == "cells" || actual.isSubset(of: surface.drawnIDs),
                "visibleIDsMatch": actual == surface.expectedVisibleIDs(viewport),
                "expectedVisibleEventCount": surface.expectedVisibleIDs(viewport).count, "actualVisibleEventCount": actual.count,
                "requestedDatePresent": model.date == model.layouts.first?.date,
                "rasterBuilds": surface.rasterBuilds, "prefetchedRasterBuilds": surface.prefetchedRasterBuilds,
                "rasterContentsPresent": surface.rasterContentsPresent, "rasterCacheBytes": surface.rasterCache.bytes, "rasterCachedPages": surface.rasterCache.count,
                "rasterPreparationMS": surface.rasterPreparationMS,
                "cachedDays": model.cache.count, "geometryBuilds": model.geometryBuilds,
                "prefetchBuilds": model.prefetchBuilds, "createdCells": surface.createdCells,
                "viewportReconciliations": surface.reconciliations, "surfaceDrawPasses": surface.surfaceDrawPasses,
                "surfaceLayerUpdates": surface.surfaceLayerUpdates]
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@main
@MainActor
final class MacBenchmark: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: MacCalendarController!
    let config = CalendarFixtureConfiguration()
    var samples: [[String: Any]] = []
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 60, y: 80, width: 1200, height: 850), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Calendar Renderer Prototype — Isolated Fixtures"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await run() }
    }
    func foregroundTimed(_ phase: String, date: Date, clearCache: Bool = false, workersOverride: Int? = nil) async -> [String: Any] {
        let native = controller!
        let workers = workersOverride ?? Optimizations().tileForegroundWorkers
        precondition((0...2).contains(workers))
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
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
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
            "requestedDateMatches": native.model.date == native.model.store.calendar.startOfDay(for: date),
            "unexpectedSyncTileBuilds": workers == 0 ? 0 : native.surface.tiles.builds - beforeBuilds]
        if workers > 0 { sample["installDetailsMS"] = native.asyncNavigationSamples.last?["installDetailsMS"] }
        sample.merge(controller.counts(), uniquingKeysWith: { _, b in b })
        return sample
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
        if config.value("--check", "") == "mount" {
            let started = ProcessInfo.processInfo.systemUptime
            controller = MacCalendarController(store: store)
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            let setupMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
            // A fresh controller/cache; the same full visible band must finish before
            // this probe records completion. Fixture generation remains separately reported.
            let workers = Int(config.value("--mount-workers", "2"))!
            var result = await foregroundTimed("processColdMount", date: store.anchor, workersOverride: workers)
            result["setupMS"] = setupMS
            result["responseMS"] = (result["responseMS"] as! Double) + setupMS
            var sections = result["mainSectionsMS"] as! [Double]
            sections.insert(setupMS, at: 0)
            result["mainSectionsMS"] = sections
            result["measuredMainMS"] = sections.reduce(0, +)
            result["maxMainSectionMS"] = sections.max()!
            result["fixtureMS"] = fixtureMS
            result["eventsPerDay"] = config.density
            result["ablation"] = config.value("--ablation", "none")
            result["scope"] = "Fresh-process controller mount through API flush; excludes fixture generation; not launch-to-visible or frame timing"
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: config.value("--output", "/tmp/mac-calendar-mount.json")))
            NSApp.terminate(nil)
            return
        }
        timed("coldMount") {
            controller = MacCalendarController(store: store)
            window.contentViewController = controller
            controller.view.layoutSubtreeIfNeeded()
            controller.move(to: store.anchor)
        }
        if config.value("--check", "") == "recovery-benchmark" {
            let result = await controller.benchmarkInteractiveRecovery()
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: config.value("--output", "/tmp/mac-calendar-recovery-benchmark.json")))
            NSApp.terminate(nil)
            return
        }
        if config.value("--check", "") == "interactive-recovery" {
            let result = await controller.checkInteractiveRecovery()
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: config.value("--output", "/tmp/mac-calendar-recovery.json")))
            NSApp.terminate(nil)
            return
        }
        if config.value("--check", "") == "navigation" {
            let result = await controller.checkNavigation()
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: config.value("--output", "/tmp/mac-calendar-navigation.json")))
            NSApp.terminate(nil)
            return
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
        let recoveryExperiments = samples
        samples = []
        let navigationStress = config.args.contains("--navigation-stress")
        if navigationStress {
            var offset = store.calendar.dateComponents([.day], from: store.anchor, to: controller.model.date).day!
            await settle()
            let stride = controller.model.dayCount
            for (phase, delta, delay) in [("forwardPage", stride, UInt64(250_000_000)),
                                          ("returnPage", -stride, UInt64(250_000_000)),
                                          ("rapidForwardPage", stride, UInt64(32_000_000)),
                                          ("rapidReturnPage", -stride, UInt64(32_000_000))] {
                for _ in 0..<12 {
                    offset += delta
                    timed(phase) { controller.move(to: store.calendar.date(byAdding: .day, value: offset, to: store.anchor)!) }
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        let navigationExperiments = samples
        let foregroundNavigation = config.args.contains("--foreground-navigation")
        var foregroundExperiments: [[String: Any]] = []
        if foregroundNavigation {
            precondition(Optimizations().renderer == "tiles")
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
        let report: [String: Any] = ["schemaVersion": 7, "timeZone": store.calendar.timeZone.identifier, "fixture": store.fixtureSummary, "batchEventFills": config.args.contains("--batch-event-fills"), "memoRasterText": config.args.contains("--memo-raster-text"), "candidate": "native", "mode": config.mode, "feed": "bounded",
            "days": config.days, "eventsPerDay": config.density, "retainedEvents": config.days * config.density,
            "optimizations": ["renderer": controller.surface.optimizations.renderer, "ablation": controller.surface.optimizations.disabled],
            "fixtureGenerationMS": fixtureMS, "samples": primary, "experiments": recoveryExperiments,
            "navigationStress": navigationStress, "navigationExperiments": navigationExperiments,
            "foregroundNavigation": foregroundNavigation, "foregroundExperiments": foregroundExperiments,
            "navigationViewportWidth": controller.scroll.contentView.bounds.width,
            "verticalScrollFound": true, "screen": ["width": controller.view.bounds.width,
                "height": controller.view.bounds.height, "scale": window.backingScaleFactor,
                "maximumFramesPerSecond": window.screen?.maximumFramesPerSecond ?? 0],
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Primary: AppKit synchronous API/layout/display/flush. Foreground: request-to-publication and main sections; not input-to-visible or compositor delivery",
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
