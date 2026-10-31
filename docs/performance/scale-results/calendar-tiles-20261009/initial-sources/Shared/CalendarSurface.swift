import CoreText
#if os(iOS)
import UIKit
typealias PlatformView = UIView
#else
import AppKit
typealias PlatformView = NSView
#endif

@MainActor
final class TimelineDocument: PlatformView {
    #if !os(iOS)
    override var isFlipped: Bool { true }
    #endif
}

// Native scroll containers move this surface without recomputing event geometry.
// Views are retained through an overscan band; scroll ticks inside it perform no reconciliation.
@MainActor
final class CalendarSurface: PlatformView {
    static let timelineHeight: CGFloat = 1920
    static let gutter: CGFloat = 48
    let optimizations = Optimizations()
    var days: [DayGeometry] = []
    private(set) var presentations: [String: CGRect] = [:]
    private var textLines: [String: PreparedText] = [:]
    private var textAges: [String: Int] = [:]
    private var textClock = 0
    private var textGeneration = 0
    private var textWork: Task<[(String, PreparedText)], Never>?
    private let rasterLayer = CALayer()
    let rasterCache = RasterCache()
    let tiles = TileRenderer()
    private var rasterWork: Task<[(RasterKey, RasterPage)], Never>?
    private var currentRasterKey: RasterKey?
    private var currentRasterIDs = Set<String>()
    var rasterContentsPresent: Bool { rasterLayer.contents != nil }
    private(set) var rasterBuilds = 0
    private(set) var prefetchedRasterBuilds = 0
    private(set) var rasterPreparationMS: [Double] = []
    private(set) var prefetchedTextBuilds = 0
    private lazy var preparedTextStyle: PreparedText.Style = {
        #if os(iOS)
        let color = UIColor.label.resolvedColor(with: traitCollection).cgColor
        #else
        let color = NSColor.labelColor.cgColor
        #endif
        return PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: color)
    }()
    private(set) var drawnIDs = Set<String>()
    private(set) var textBuilds = 0
    private var gridView: CalendarGridView?
    private var gridDayCount = -1
    private(set) var gridInvalidations = 0
    var splitGridFrame: CGRect? { gridView?.frame }
    private(set) var gridDrawMS = 0.0
    private(set) var eventDrawMS = 0.0
    private(set) var gridDrawCount = 0
    private(set) var eventDrawCount = 0
    private var virtualElements: [NativeAccessibilityEvent] = []
    private var accessibilityByID: [String: NativeAccessibilityEvent] = [:]
    private(set) var accessibilityCreatedElements = 0
    private(set) var accessibilityWorkMS = 0.0
    private(set) var active: [String: NativeEventCell] = [:]
    private var pool: [NativeEventCell] = []
    private var covered = CGRect.null
    private var lastWidth: CGFloat = 0
    private(set) var reconciliations = 0
    private(set) var createdCells = 0
    private(set) var selectedID: String?
    var onSelect: ((String) -> Void)?
    #if !os(iOS)
    override var isFlipped: Bool { true }
    #endif

    func install(_ days: [DayGeometry], viewport: CGRect) {
        textGeneration += 1; textWork?.cancel(); rasterWork?.cancel()
        self.days = days
        drawnIDs.removeAll()
        covered = .null
        if optimizations.splitGrid { updateGrid(width: superview?.bounds.width ?? bounds.width) }
        #if os(iOS)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
        if days.isEmpty {
            presentations.removeAll()
            updateAccessibility()
            for cell in active.values { cell.removeFromSuperview() }
            active.removeAll()
            rasterLayer.contents = nil; currentRasterKey = nil; currentRasterIDs.removeAll()
            tiles.clear()
            return
        }
        update(viewport: viewport)
    }

    func frame(for item: EventPlacement, day: Int) -> CGRect {
        item.rect(day: day, dayCount: days.count, width: bounds.width, height: Self.timelineHeight, gutter: Self.gutter)
    }

    func expectedVisibleIDs(_ viewport: CGRect) -> Set<String> {
        // Independent brute-force oracle; used outside measured work, never by rendering.
        Set(days.enumerated().flatMap { day, geometry in
            geometry.placements.filter { frame(for: $0, day: day).intersects(viewport) }
                .map { "\(day):\($0.id)" }
        })
    }

    func update(viewport: CGRect) {
        let width = superview?.bounds.width ?? bounds.width
        guard !days.isEmpty, width > Self.gutter else { return }
        if optimizations.overscan && covered.contains(viewport), lastWidth == width { return }
        reconciliations += 1
        lastWidth = width
        covered = viewport.insetBy(dx: 0, dy: optimizations.overscan ? -160 : 0)
        let surfaceRect = optimizations.windowedSurface && optimizations.renderer != "raster" && optimizations.renderer != "tiles"
            ? CGRect(x: 0, y: covered.minY, width: width, height: covered.height)
            : CGRect(x: 0, y: 0, width: width, height: Self.timelineHeight)
        if frame != surfaceRect { frame = surfaceRect }
        if bounds != surfaceRect { bounds = surfaceRect }
        if optimizations.splitGrid { updateGrid(width: width) }
        let from = covered.minY / Self.timelineHeight
        let to = covered.maxY / Self.timelineHeight
        var wanted: [String: CGRect] = [:]
        for (day, geometry) in days.enumerated() {
            let entries = optimizations.indexed ? geometry.visible(from: from, to: to) : geometry.placements.filter { $0.end > from && $0.start < to }
            for event in entries {
                wanted["\(day):\(event.id)"] = frame(for: event, day: day)
            }
        }
        presentations = wanted
        if optimizations.renderer == "tiles" {
            updateAccessibility()
            #if os(iOS)
            if tiles.layer.superlayer == nil { layer.addSublayer(tiles.layer) }
            #else
            wantsLayer = true
            if tiles.layer.superlayer == nil { layer?.addSublayer(tiles.layer) }
            #endif
            let installed = tiles.install(days: days, width: width, height: Self.timelineHeight, gutter: Self.gutter,
                scale: rasterScale, viewport: covered, style: rasterStyle)
            drawnIDs = installed ? tiles.ids : []
            return
        }
        if optimizations.renderer == "raster" {
            updateAccessibility()
            installRasterIfNeeded()
            return
        }
        if optimizations.renderer == "canvas" {
            // Reuse prepared glyph runs across viewport updates; retain only this working set.
            if optimizations.textCache {
                textClock += 1
                for key in wanted.keys {
                    if textLines[key] == nil { textLines[key] = makeText(key) }
                    textAges[key] = textClock
                }
                trimTextCache()
            }
            updateAccessibility()
            #if os(iOS)
            setNeedsDisplay()
            #else
            needsDisplay = true
            #endif
            return
        }
        var retired: [NativeEventCell] = []
        for key in Array(active.keys) where wanted[key] == nil {
            let cell = active.removeValue(forKey: key)!
            if optimizations.reuse { retired.append(cell) }
            else { cell.removeFromSuperview() }
        }
        for (key, rect) in wanted {
            let cell: NativeEventCell
            if let existing = active[key] { cell = existing }
            else {
                if let reused = retired.popLast() ?? pool.popLast() { cell = reused }
                else { cell = NativeEventCell(frame: .zero); createdCells += 1 }
                cell.configure(key: key) { [weak self] in
                    self?.selectedID = key
                    self?.onSelect?(key)
                }
                active[key] = cell
                if cell.superview !== self { addSubview(cell) }
            }
            if cell.frame != rect { cell.frame = rect }
        }
        for cell in retired { cell.removeFromSuperview(); pool.append(cell) }
        // Bound spare view retention independently of how many dense pages were visited.
        if pool.count > 64 { pool.removeLast(pool.count - 64) }
    }

    func evictSpareViews() {
        textGeneration += 1; textWork?.cancel(); rasterWork?.cancel()
        pool.removeAll(); textLines.removeAll(); textAges.removeAll()
        // Keep the active presentation visible. A memory warning evicts speculative work,
        // not the user's current page; rebuild on the next install without a blank interval.
        rasterCache.clear(); currentRasterKey = nil
        tiles.evict()
        // Invalidate cached grid pixels for the recovery probe; the native view redraws them.
        if let gridView { gridView.invalidate(); gridInvalidations += 1 }
    }
    private func trimTextCache() {
        guard textLines.count > 4096 else { return }
        let oldest = textAges.keys.sorted { textAges[$0]! == textAges[$1]! ? $0 < $1 : textAges[$0]! < textAges[$1]! }
        for key in oldest.prefix(textLines.count - 4096) { textLines.removeValue(forKey: key); textAges.removeValue(forKey: key) }
    }
    private func makeText(_ key: String) -> PreparedText {
        textBuilds += 1
        return PreparedText("Event \(key)", style: preparedTextStyle)
    }
    func preloadText(store: FixtureStore, date: Date, dayCount: Int) {
        if optimizations.renderer == "raster" { preloadRaster(store: store, date: date, dayCount: dayCount); return }
        guard optimizations.renderer == "canvas", optimizations.textPreload else { return }
        var keys: [String] = []
        for direction in [dayCount, -dayCount] {
            for day in 0..<dayCount {
                let date = store.calendar.date(byAdding: .day, value: direction + day, to: date)!
                let next = store.calendar.date(byAdding: .day, value: 1, to: date)!
                let duration = next.timeIntervalSince(date)
                let from = max(0, covered.minY / Self.timelineHeight)
                let to = min(1, covered.maxY / Self.timelineHeight)
                // Match the destination's overscan band. Preparing invisible titles can evict
                // the active/next-page working set before input arrives at high density.
                let events = store.day(date).filter {
                    !optimizations.viewportTextPreload ||
                    $0.intersects(dayStart: date, duration: duration, from: from, to: to)
                }
                keys += events.map { "\(day):\($0.id)" }.filter { textLines[$0] == nil }
            }
        }
        let token = textGeneration
        let style = preparedTextStyle // Immutable CoreText font + CGColor, prepared on main.
        let work = Task.detached(priority: .utility) {
            var prepared: [(String, PreparedText)] = []
            for key in keys {
                guard !Task.isCancelled else { break }
                let line = PreparedText("Event \(key)", style: style)
                prepared.append((key, line))
            }
            return prepared
        }
        textWork = work
        Task { [weak self] in
            let prepared = await work.value
            guard let self, self.textGeneration == token, !work.isCancelled else { return }
            for (key, line) in prepared where self.textLines[key] == nil {
                self.textLines[key] = line; self.textAges[key] = self.textClock - 1
            }
            self.prefetchedTextBuilds += prepared.count
            self.trimTextCache()
        }
    }
    func select(at point: CGPoint) {
        if let key = presentations.keys.sorted().first(where: { presentations[$0]!.contains(point) }) {
            selectedID = key; onSelect?(key)
        }
    }
    private func updateAccessibility() {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { accessibilityWorkMS += Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        guard optimizations.accessibilityReuse else { rebuildAccessibility(); return }
        // Retain identity only while an event remains in the prepared viewport. Never
        // recycle an AX object for another event: assistive clients may still retain it.
        var membershipChanged = false
        for key in Array(accessibilityByID.keys) where presentations[key] == nil {
            accessibilityByID.removeValue(forKey: key)?.activate = nil
            membershipChanged = true
        }
        for (key, rect) in presentations {
            let element: NativeAccessibilityEvent
            if let existing = accessibilityByID[key] { element = existing }
            else {
                #if os(iOS)
                element = NativeAccessibilityEvent(accessibilityContainer: self)
                element.accessibilityLabel = "Event \(key)"
                element.accessibilityTraits = .button
                #else
                element = NativeAccessibilityEvent()
                element.owner = self
                element.setAccessibilityParent(self)
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel("Event \(key)")
                #endif
                element.activate = { [weak self] in self?.selectedID = key; self?.onSelect?(key) }
                accessibilityByID[key] = element
                accessibilityCreatedElements += 1
                membershipChanged = true
            }
            #if os(iOS)
            if element.accessibilityFrameInContainerSpace != rect { element.accessibilityFrameInContainerSpace = rect }
            #else
            if element.localFrame != rect {
                element.localFrame = rect
                element.setAccessibilityFrameInParentSpace(rect)
            }
            #endif
        }
        if membershipChanged {
            virtualElements = accessibilityByID.keys.sorted().map { accessibilityByID[$0]! }
            #if os(iOS)
            accessibilityElements = virtualElements
            #else
            setAccessibilityChildren(virtualElements)
            #endif
        }
    }
    private func rebuildAccessibility() {
        for element in virtualElements { element.activate = nil }
        accessibilityCreatedElements += presentations.count
        // Virtual accessibility children preserve event discoverability without one native view per event.
        #if os(iOS)
        virtualElements = presentations.keys.sorted().map { key in
            let element = NativeAccessibilityEvent(accessibilityContainer: self)
            element.activate = { [weak self] in self?.selectedID = key; self?.onSelect?(key) }
            element.accessibilityLabel = "Event \(key)"
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = presentations[key]!
            return element
        }
        accessibilityElements = virtualElements
        #else
        virtualElements = presentations.keys.sorted().map { key in
            let element = NativeAccessibilityEvent()
            element.activate = { [weak self] in self?.selectedID = key; self?.onSelect?(key) }
            element.owner = self
            element.localFrame = presentations[key]!
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("Event \(key)")
            element.setAccessibilityFrameInParentSpace(presentations[key]!)
            return element
        }
        setAccessibilityChildren(virtualElements)
        #endif
    }
    #if os(iOS)
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { select(at: touch.location(in: self)) }
    }
    #else
    override func mouseDown(with event: NSEvent) { select(at: convert(event.locationInWindow, from: nil)) }
    #endif

    private func updateGrid(width: CGFloat) {
        guard let document = superview, width > Self.gutter else { return }
        if gridView == nil {
            let grid = CalendarGridView(frame: CGRect(x: 0, y: 0, width: width, height: Self.timelineHeight))
            grid.paint = { [weak self] rect in self?.drawGrid(rect) }
            #if os(iOS)
            isOpaque = false; backgroundColor = .clear
            document.insertSubview(grid, belowSubview: self)
            #else
            grid.wantsLayer = true
            document.addSubview(grid, positioned: .below, relativeTo: self)
            #endif
            gridView = grid
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: Self.timelineHeight)
        if gridView!.frame != rect || gridDayCount != days.count {
            gridView!.frame = rect
            gridDayCount = days.count
            gridView!.invalidate(); gridInvalidations += 1
        }
    }
    // Both variants use exactly the same grid drawing implementation.
    func drawGrid(_ dirtyRect: CGRect) {
        let gridStart = DispatchTime.now().uptimeNanoseconds
        #if os(iOS)
        UIColor.systemBackground.setFill(); UIRectFill(dirtyRect)
        UIColor.separator.setStroke()
        let path = UIBezierPath()
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.secondaryLabel]
        #else
        NSColor.windowBackgroundColor.setFill(); dirtyRect.fill()
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        #endif
        for hour in 0...24 {
            let y = CGFloat(hour) * Self.timelineHeight / 24
            path.move(to: CGPoint(x: Self.gutter, y: y))
            path.addLineCompat(to: CGPoint(x: bounds.width, y: y))
            if hour < 24 { (String(format: "%02d:00", hour) as NSString).draw(at: CGPoint(x: 3, y: y + 2), withAttributes: attributes) }
        }
        for day in 0...days.count {
            let x = Self.gutter + CGFloat(day) * max(1, bounds.width - Self.gutter) / CGFloat(max(1, days.count))
            path.move(to: CGPoint(x: x, y: 0)); path.addLineCompat(to: CGPoint(x: x, y: Self.timelineHeight))
        }
        path.lineWidth = 0.5; path.stroke()
        gridDrawMS += Double(DispatchTime.now().uptimeNanoseconds - gridStart) / 1_000_000
        gridDrawCount += 1
    }
    override func draw(_ dirtyRect: CGRect) {
        if optimizations.renderer == "raster" || optimizations.renderer == "tiles" { return }
        // Transparent native backing is cleared by the framework. Explicit CGContext.clear
        // would erase the grid underneath when AppKit flattens the hierarchy for capture.
        if !optimizations.splitGrid { drawGrid(dirtyRect) }
        guard optimizations.renderer == "canvas" else { return }
        #if os(iOS)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let fill = UIColor.systemBlue.withAlphaComponent(0.15).cgColor
        #else
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let fill = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        #endif
        let eventStart = DispatchTime.now().uptimeNanoseconds
        defer { eventDrawMS += Double(DispatchTime.now().uptimeNanoseconds - eventStart) / 1_000_000; eventDrawCount += 1 }
        for (key, rect) in presentations where rect.intersects(dirtyRect) {
            drawnIDs.insert(key)
            context.setFillColor(fill)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(3, rect.width / 2), cornerHeight: min(3, rect.height / 2), transform: nil)); context.fillPath()
            // Clip exactly as an event cell does, including narrow overlap columns.
            context.saveGState(); context.clip(to: rect)
            context.textMatrix = .identity
            context.translateBy(x: rect.minX + 3, y: rect.minY + 14)
            context.scaleBy(x: 1, y: -1)
            let text = optimizations.textCache ? (textLines[key] ?? makeText(key)) : makeText(key)
            text.draw(in: context, maxWidth: optimizations.glyphCulling ? rect.width - 3 : nil)
            context.restoreGState()
        }
    }

    private var rasterScale: CGFloat {
        #if os(iOS)
        window?.screen.scale ?? 1
        #else
        window?.backingScaleFactor ?? 1
        #endif
    }
    private var rasterStyle: RasterPage.Style {
        #if os(iOS)
        let background = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor
        let separator = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        let secondary = UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor
        let event = UIColor.systemBlue.withAlphaComponent(0.15).cgColor
        #else
        let background = NSColor.windowBackgroundColor.cgColor
        let separator = NSColor.separatorColor.cgColor
        let secondary = NSColor.secondaryLabelColor.cgColor
        let event = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        #endif
        return RasterPage.Style(text: preparedTextStyle,
            hours: PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: secondary),
            background: background, separator: separator, event: event)
    }
    private func installRasterIfNeeded() {
        let key = RasterKey(dates: days.map(\.date), width: bounds.width, scale: rasterScale)
        if currentRasterKey == key {
            // install() clears coverage even for a same-date recovery/reselection.
            drawnIDs = currentRasterIDs
            return
        }
        let cached = optimizations.rasterCache ? rasterCache.get(key) : nil
        guard let page = cached ?? RasterPage.render(days: days, width: bounds.width,
            height: Self.timelineHeight, gutter: Self.gutter, scale: rasterScale, style: rasterStyle) else {
            drawnIDs.removeAll(); return
        }
        if cached == nil { rasterBuilds += 1; rasterPreparationMS.append(page.preparationMS) }
        if optimizations.rasterCache { rasterCache.put(page, for: key) }
        currentRasterKey = key; currentRasterIDs = page.ids; drawnIDs = page.ids
        #if os(iOS)
        if rasterLayer.superlayer == nil { layer.addSublayer(rasterLayer) }
        #else
        wantsLayer = true
        if rasterLayer.superlayer == nil { layer?.addSublayer(rasterLayer) }
        #endif
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rasterLayer.frame = bounds; rasterLayer.contentsScale = rasterScale
        rasterLayer.contents = page.image; rasterLayer.isOpaque = true
        CATransaction.commit()
    }
    private func preloadRaster(store: FixtureStore, date: Date, dayCount: Int) {
        guard optimizations.rasterPreload else { return }
        let width = bounds.width, scale = rasterScale, style = rasterStyle, calendar = store.calendar
        let inputs = [dayCount, -dayCount].compactMap { offset -> (RasterKey, [(Date, [Fixture])])? in
            let rows = (0..<dayCount).map { day -> (Date, [Fixture]) in
                let date = calendar.date(byAdding: .day, value: offset + day, to: date)!
                return (date, store.day(date))
            }
            let key = RasterKey(dates: rows.map(\.0), width: width, scale: scale)
            return rasterCache.get(key) == nil ? (key, rows) : nil
        }
        guard !inputs.isEmpty else { return }
        let token = textGeneration, height = Self.timelineHeight, gutter = Self.gutter
        let stream = optimizations.streamRasterPreload
        let work = Task.detached(priority: .utility) { [weak self] in
            var pages: [(RasterKey, RasterPage)] = []
            for (key, rows) in inputs {
                guard !Task.isCancelled else { break }
                let layouts = rows.map { DayGeometry(date: $0.0, calendar: calendar, events: $0.1, buildIndex: false) }
                if let page = autoreleasepool(invoking: { RasterPage.render(days: layouts, width: width,
                    height: height, gutter: gutter, scale: scale, style: style) }) {
                    guard !Task.isCancelled else { break }
                    if stream { await self?.receiveRaster(page, key: key, generation: token) }
                    else { pages.append((key, page)) }
                }
            }
            return pages
        }
        rasterWork = work
        Task { [weak self] in
            let prepared = await work.value
            guard let self, self.textGeneration == token, !work.isCancelled else { return }
            for (key, page) in prepared {
                self.receiveRaster(page, key: key, generation: token)
            }
        }
    }
    private func receiveRaster(_ page: RasterPage, key: RasterKey, generation: Int) {
        guard textGeneration == generation else { return }
        rasterCache.put(page, for: key)
        if let current = currentRasterKey { _ = rasterCache.get(current) }
        rasterPreparationMS.append(page.preparationMS)
        prefetchedRasterBuilds += 1
    }
}

#if os(iOS)
@MainActor
private final class NativeAccessibilityEvent: UIAccessibilityElement {
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { guard let activate else { return false }; activate(); return true }
}
private extension UIBezierPath { func addLineCompat(to point: CGPoint) { addLine(to: point) } }
@MainActor
final class NativeEventCell: UIControl {
    let title = UILabel()
    var activate: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        layer.cornerRadius = 3
        clipsToBounds = true
        title.font = .systemFont(ofSize: 12)
        title.textColor = .label
        addSubview(title)
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(selectEvent), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic prototype") }
    func configure(key: String, activate: @escaping () -> Void) {
        title.text = "Event \(key)"; accessibilityLabel = title.text
        accessibilityIdentifier = key; self.activate = activate
    }
    override func layoutSubviews() { super.layoutSubviews(); title.frame = CGRect(x: 3, y: 2, width: max(0, bounds.width - 6), height: min(18, bounds.height)) }
    @objc func selectEvent() { activate?() }
    override func accessibilityActivate() -> Bool { guard let activate else { return false }; activate(); return true }
}
#else
@MainActor
private final class NativeAccessibilityEvent: NSAccessibilityElement {
    var activate: (() -> Void)?
    weak var owner: NSView?
    var localFrame = CGRect.zero
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        return window.convertToScreen(owner.convert(localFrame, to: nil))
    }
    override func accessibilityPerformPress() -> Bool { guard let activate else { return false }; activate(); return true }
}
private extension NSBezierPath { func addLineCompat(to point: CGPoint) { line(to: point) } }
@MainActor
final class NativeEventCell: NSView {
    var title: NSAttributedString = NSAttributedString(string: "")
    var activate: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 3; layer?.masksToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("Programmatic prototype") }
    func configure(key: String, activate: @escaping () -> Void) {
        title = NSAttributedString(string: "Event \(key)", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
        setAccessibilityLabel(title.string); setAccessibilityIdentifier(key)
        self.activate = activate; needsDisplay = true
    }
    override func draw(_ dirtyRect: CGRect) { title.draw(in: CGRect(x: 3, y: 2, width: max(0, bounds.width - 6), height: min(18, bounds.height))) }
    override func mouseDown(with event: NSEvent) { activate?() }
    override func accessibilityPerformPress() -> Bool { guard let activate else { return false }; activate(); return true }
}
#endif
