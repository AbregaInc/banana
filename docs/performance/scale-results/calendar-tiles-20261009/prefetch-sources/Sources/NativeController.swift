import UIKit

@MainActor
final class NativeController: UIViewController, UIScrollViewDelegate {
    let model: PrototypeModel
    let scroll = UIScrollView()
    let surface = CalendarSurface(frame: .zero)
    let document = TimelineDocument(frame: .zero)
    let heading = UILabel()
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
        surface.onSelect = { [weak self] key in self?.heading.text = "Selected event \(key)" }
        NotificationCenter.default.addObserver(self, selector: #selector(memoryPressure), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        heading.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 40)
        scroll.frame = CGRect(x: 0, y: 40, width: view.bounds.width, height: max(1, view.bounds.height - 40))
        document.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: CalendarSurface.timelineHeight)
        scroll.contentSize = document.bounds.size
        surface.update(viewport: scroll.bounds)
    }
    func move(to date: Date) {
        model.move(to: date)
        heading.text = date.formatted(date: .abbreviated, time: .omitted)
        surface.install(model.layouts, viewport: scroll.bounds)
        model.preloadAdjacent()
        surface.preloadText(store: model.store, date: model.date, dayCount: model.dayCount)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { surface.update(viewport: scroll.bounds) }
    @objc func memoryPressure() { model.memoryPressure(); surface.evictSpareViews() }
    func validation() -> [String: Any] {
        let expected = surface.expectedVisibleIDs(scroll.bounds)
        let actual = Set(surface.presentations.filter { $0.value.intersects(scroll.bounds) }.keys)
        return ["prefetchedTileBuilds": surface.tiles.prefetchedBuilds, "tileContentsPresent": surface.tiles.contentsPresent, "tileBuilds": surface.tiles.builds, "tilePreparationMS": surface.tiles.preparationMS, "tileCacheBytes": surface.tiles.cache.bytes, "tileCacheCount": surface.tiles.cache.count, "activeTiles": surface.tiles.activeCount, "activeTileBytes": surface.tiles.activeBytes,
                "gridInvalidations": surface.gridInvalidations, "gridDrawMS": surface.gridDrawMS, "eventDrawMS": surface.eventDrawMS, "gridDrawCount": surface.gridDrawCount, "eventDrawCount": surface.eventDrawCount,
                "accessibilityCreatedElements": surface.accessibilityCreatedElements, "accessibilityWorkMS": surface.accessibilityWorkMS,
                "visiblePresentations": actual.count, "textBuilds": surface.textBuilds, "prefetchedTextBuilds": surface.prefetchedTextBuilds, "peakResidentBytes": peakResidentBytes(),
                "drawCoverageMatches": surface.optimizations.renderer == "cells" || actual.isSubset(of: surface.drawnIDs),
                "visibleIDsMatch": expected == actual && !expected.isEmpty,
                "requestedDatePresent": model.date == model.layouts.first?.date,
                "rasterBuilds": surface.rasterBuilds, "prefetchedRasterBuilds": surface.prefetchedRasterBuilds,
                "rasterContentsPresent": surface.rasterContentsPresent, "rasterCacheBytes": surface.rasterCache.bytes, "rasterCachedPages": surface.rasterCache.count,
                "rasterPreparationMS": surface.rasterPreparationMS,
                "cachedDays": model.cache.count, "geometryBuilds": model.geometryBuilds,
                "prefetchBuilds": model.prefetchBuilds, "createdCells": surface.createdCells,
                "viewportReconciliations": surface.reconciliations]
    }
}
