import UIKit

@MainActor
final class NativeController: UIViewController, UIScrollViewDelegate {
    let model: PrototypeModel
    let scroll = UIScrollView()
    let surface = CalendarSurface(frame: .zero)
    let document = TimelineDocument(frame: .zero)
    let heading = UILabel()
    #if !targetEnvironment(macCatalyst)
    private var presentationLink: UIUpdateLink?
    #endif
    private var interactiveControls: InteractiveControls?
    private var navigationTask: Task<Void, Never>?
    private var navigationGeneration = 0
    private(set) var requestedDate: Date?
    private var asyncWorkers: Int { Int(model.store.config.value("--async-workers", String(surface.optimizations.tileForegroundWorkers))) ?? 0 }
    private(set) var asyncNavigationSamples: [[String: Any]] = []
    private var accessibilitySnapshot: [(key: String, frame: CGRect, enabled: Bool)]?
    private var accessibilityEnumerationMS = 0.0
    init(store: FixtureStore) { model = PrototypeModel(store: store); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Programmatic prototype") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scroll.delegate = self
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(document); document.addSubview(surface)
        view.addSubview(scroll)
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.textAlignment = .center
        view.addSubview(heading)
        scroll.accessibilityIdentifier = "benchmark.timeline"
        #if !targetEnvironment(macCatalyst)
        if model.store.config.args.contains("--presentation-policy") {
            let policy = model.store.config.value("--presentation-policy", "system")
            precondition(["system", "immediate", "prefer120"].contains(policy))
            // Native update preferences only. No continuous ticks or custom event
            // dispatch; immediate presentation is a request, never proof of delivery.
            let link = UIUpdateLink(view: scroll) { _, _ in }
            link.requiresContinuousUpdates = false
            link.wantsImmediatePresentation = policy == "immediate"
            if policy == "prefer120" {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            }
            link.isEnabled = true
            presentationLink = link
        }
        #endif
        if model.store.config.args.contains("--interactive") {
            let controls = InteractiveControls(heading: heading,
                previous: { [weak self] in self?.moveInteractive(-1) },
                next: { [weak self] in self?.moveInteractive(1) },
                clear: { [weak self] in self?.memoryPressure() })
            interactiveControls = controls
            view.addSubview(controls)
        }
        surface.onSelect = { [weak self] key in self?.heading.text = "Selected event \(key)" }
        NotificationCenter.default.addObserver(self, selector: #selector(memoryPressure), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let headerHeight: CGFloat = interactiveControls == nil ? 40 : 44
        if let interactiveControls {
            interactiveControls.frame = CGRect(x: 4, y: 0, width: view.bounds.width - 8, height: headerHeight)
        } else {
            heading.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 40)
        }
        scroll.frame = CGRect(x: 0, y: headerHeight, width: view.bounds.width, height: max(1, view.bounds.height - headerHeight))
        document.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: CalendarSurface.timelineHeight)
        scroll.contentSize = document.bounds.size
        surface.update(viewport: scroll.bounds)
    }
    func moveInteractive(_ direction: Int) {
        guard let date = model.store.calendar.date(byAdding: .day,
            value: direction * model.dayCount, to: requestedDate ?? model.date) else { return }
        if asyncWorkers == 0 { move(to: date); return }
        requestedDate = date
        navigationGeneration &+= 1
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.movePrepared(to: date, workers: self.asyncWorkers)
        }
    }
    func move(to date: Date) {
        navigationGeneration &+= 1; navigationTask?.cancel(); requestedDate = nil
        model.move(to: date)
        heading.text = date.formatted(date: .abbreviated, time: .omitted)
        surface.install(model.layouts, viewport: scroll.bounds)
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
            let viewport = scroll.bounds, width = scroll.bounds.width
            let scale = view.window?.screen.scale ?? 1
            guard let prepared = await surface.prepareTiles(layouts, viewport: viewport, workers: workers) else { return false }
            guard !Task.isCancelled, navigationGeneration == token else { return false }
            // Resizing or scrolling during preparation must not publish a band for old bounds.
            if scroll.bounds != viewport || scroll.bounds.width != width || (view.window?.screen.scale ?? 1) != scale { continue }
            let installStart = ProcessInfo.processInfo.systemUptime
            model.move(to: date, prepared: layouts)
            let modelCommitted = ProcessInfo.processInfo.systemUptime
            surface.install(layouts, viewport: viewport, prepared: prepared)
            let surfaceInstalled = ProcessInfo.processInfo.systemUptime
            heading.text = model.date.formatted(date: .abbreviated, time: .omitted)
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
    func scrollViewDidScroll(_ scrollView: UIScrollView) { surface.update(viewport: scroll.bounds) }
    @objc func memoryPressure() {
        navigationGeneration &+= 1; navigationTask?.cancel(); requestedDate = nil
        model.memoryPressure(); surface.evictSpareViews()
    }
    func exerciseAccessibility() {
        let began = DispatchTime.now().uptimeNanoseconds
        let elements: [UIAccessibilityElement]
        if let published = surface.accessibilityElements as? [UIAccessibilityElement] {
            elements = published
        } else {
            elements = (0..<max(0, surface.accessibilityElementCount())).compactMap {
                surface.accessibilityElement(at: $0) as? UIAccessibilityElement
            }
        }
        accessibilitySnapshot = elements.map {
            (String(($0.accessibilityLabel ?? "").dropFirst(6)), $0.accessibilityFrameInContainerSpace,
             $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button))
        }
        accessibilityEnumerationMS += Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    }
    func validation() -> [String: Any] {
        let expected = surface.expectedVisibleIDs(scroll.bounds)
        let actual = Set(surface.presentations.filter { $0.value.intersects(scroll.bounds) }.keys)
        let accessibleMatches = accessibilitySnapshot.map { snapshot in
            snapshot.map { $0.key } == surface.presentations.keys.sorted()
                && snapshot.allSatisfy { $0.enabled && surface.presentations[$0.key] == $0.frame }
        } ?? false
        return ["prefetchedTileBuilds": surface.tiles.prefetchedBuilds, "tileContentsPresent": surface.tiles.contentsPresent, "tileBuilds": surface.tiles.builds, "tilePreparationMS": surface.tiles.preparationMS, "tileCacheBytes": surface.tiles.cache.bytes, "tileCacheCount": surface.tiles.cache.count, "activeTiles": surface.tiles.activeCount, "activeTileBytes": surface.tiles.activeBytes,
                "gridInvalidations": surface.gridInvalidations, "gridDrawMS": surface.gridDrawMS, "eventDrawMS": surface.eventDrawMS, "gridDrawCount": surface.gridDrawCount, "eventDrawCount": surface.eventDrawCount,
                "accessibilityCreatedElements": surface.accessibilityCreatedElements, "accessibilityWorkMS": surface.accessibilityWorkMS,
                "accessibilityEnumerationMS": accessibilityEnumerationMS, "accessibilityEnumeratedIDsMatch": accessibleMatches,
                "accessibilityCachedPages": surface.accessibilityCachedPages, "accessibilityCachedElements": surface.accessibilityCachedElements, "accessibilityPageHits": surface.accessibilityPageHits,
                "accessibilityElementQueries": surface.accessibilityElementQueries, "accessibilityMaterializedElements": surface.accessibilityMaterializedElements,
                "visiblePresentations": actual.count, "textBuilds": surface.textBuilds, "prefetchedTextBuilds": surface.prefetchedTextBuilds, "peakResidentBytes": peakResidentBytes(), "physicalFootprintBytes": physicalFootprintBytes(),
                "drawCoverageMatches": surface.optimizations.renderer == "cells" || actual.isSubset(of: surface.drawnIDs),
                "visibleIDsMatch": expected == actual,
                "expectedVisibleEventCount": expected.count, "actualVisibleEventCount": actual.count,
                "requestedDatePresent": model.date == model.layouts.first?.date,
                "rasterBuilds": surface.rasterBuilds, "prefetchedRasterBuilds": surface.prefetchedRasterBuilds,
                "rasterContentsPresent": surface.rasterContentsPresent, "rasterCacheBytes": surface.rasterCache.bytes, "rasterCachedPages": surface.rasterCache.count,
                "rasterPreparationMS": surface.rasterPreparationMS,
                "cachedDays": model.cache.count, "geometryBuilds": model.geometryBuilds,
                "prefetchBuilds": model.prefetchBuilds, "createdCells": surface.createdCells,
                "viewportReconciliations": surface.reconciliations, "surfaceDrawPasses": surface.surfaceDrawPasses,
                "surfaceLayerUpdates": surface.surfaceLayerUpdates]
    }
}
