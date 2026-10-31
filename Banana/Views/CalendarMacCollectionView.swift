#if os(macOS)
import AppKit
import SwiftUI

private enum CalendarMacCellGraphPolicy {
    static let retainsGraph: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-stable-cell-graph")
        #else
        false
        #endif
    }()
}

/// The app supplies calendar geometry and existing action-bearing content. AppKit owns
/// the lifetime of event views; full-history data and provider writes stay outside this host.
struct CalendarMacViewportItem {
    let id: String
    let frame: CGRect
    var zIndex: Int = 0
    var allowsHitTesting = true
    let content: () -> AnyView
}

struct CalendarMacSlotAction {
    let title: String
    let perform: () -> Void
}

final class CalendarMacCollectionLayout: NSCollectionViewLayout {
    var attributes: [NSCollectionViewLayoutAttributes] = []
    var size: CGSize = .zero
    var activeIndex: Int?

    override var collectionViewContentSize: NSSize { size }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.indexPath?.item == activeIndex || $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }
}

private final class CalendarMacCellView: NSView {
    var acceptsInput = true
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsInput ? super.hitTest(point) : nil
    }
}

/// Discrete mouse wheels have no gesture phases, so AppKit's live-scroll end
/// notification alone does not cover them. Coalesce their persistence callback.
final class CalendarMacScrollView: NSScrollView {
    var onDiscreteScrollEnd: () -> Void = {}
    private var idleTimer: Timer?
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if event.phase.isEmpty && event.momentumPhase.isEmpty { scheduleDiscreteScrollEnd() }
    }
    func scheduleDiscreteScrollEnd() {
        let deadline = Date(timeIntervalSinceNow: 0.15)
        if let idleTimer { idleTimer.fireDate = deadline; return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.idleTimer = nil
            self.onDiscreteScrollEnd()
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stopScrollCallbacks() {
        idleTimer?.invalidate()
        idleTimer = nil
        onDiscreteScrollEnd = {}
    }
    deinit { idleTimer?.invalidate() }
}

private final class CalendarMacEventItem: NSCollectionViewItem {
    private var hosting: NSHostingView<AnyView>?
    override func loadView() { view = CalendarMacCellView(frame: .zero) }
    func setHitTesting(_ enabled: Bool) { (view as? CalendarMacCellView)?.acceptsInput = enabled }
    func setContent(_ content: AnyView) {
        if let hosting { hosting.rootView = content }
        else {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            view.addSubview(host)
            hosting = host
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        if !CalendarMacCellGraphPolicy.retainsGraph {
            hosting?.rootView = AnyView(EmptyView())
        }
    }
}

/// No nested SwiftUI ScrollView: the collection is the document view of the real
/// NSScrollView, so region queries describe the actual visible time range.
struct CalendarMacCollectionViewport: NSViewRepresentable {
    let items: [CalendarMacViewportItem]
    let contentSize: CGSize
    let background: AnyView
    let initialOffset: CGFloat?
    var activeID: String?
    let onOffset: (CGFloat) -> Void
    var onScrollEnd: () -> Void = {}
    var slotActions: (CGPoint) -> [CalendarMacSlotAction] = { _ in [] }
    @Environment(\.self) private var environment

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scroll }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(self, environment: environment)
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource {
        let scroll = CalendarMacScrollView()
        private let collection = NSCollectionView()
        private let layout = CalendarMacCollectionLayout()
        private let backgroundHost = NSHostingView(rootView: AnyView(EmptyView()))
        private var items: [CalendarMacViewportItem] = []
        private var environment = EnvironmentValues()
        private var observer: NSObjectProtocol?
        private var scrollEndObserver: NSObjectProtocol?
        private var slotMenuMonitor: Any?
        private var slotActions: (CGPoint) -> [CalendarMacSlotAction] = { _ in [] }
        private var onOffset: (CGFloat) -> Void = { _ in }
        private var onScrollEnd: () -> Void = {}
        private var initializedOffset = false
        private static let reuseID = NSUserInterfaceItemIdentifier("calendar.event")

        override init() {
            super.init()
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false
            scroll.setAccessibilityIdentifier("mac.week.timeGrid")
            collection.setAccessibilityIdentifier("mac.calendar.viewport")
            collection.collectionViewLayout = layout
            collection.dataSource = self
            collection.isSelectable = false
            collection.backgroundColors = [.clear]
            collection.register(CalendarMacEventItem.self, forItemWithIdentifier: Self.reuseID)
            backgroundHost.sizingOptions = []
            collection.backgroundView = backgroundHost
            collection.backgroundViewScrollsWithContent = true
            scroll.documentView = collection
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.onOffset(max(0, self.scroll.contentView.bounds.minY))
            }
            scrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main
            ) { [weak self] _ in self?.onScrollEnd() }
            scroll.onDiscreteScrollEnd = { [weak self] in self?.onScrollEnd() }
            slotMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                      let self else { return event }
                return self.handleSlotMenu(event)
            }
        }
        func stopObserving() {
            if let slotMenuMonitor { NSEvent.removeMonitor(slotMenuMonitor) }
            slotMenuMonitor = nil
            slotActions = { _ in [] }
            scroll.stopScrollCallbacks()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let scrollEndObserver { NotificationCenter.default.removeObserver(scrollEndObserver) }
            scrollEndObserver = nil
        }
        deinit {
            if let slotMenuMonitor { NSEvent.removeMonitor(slotMenuMonitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let scrollEndObserver { NotificationCenter.default.removeObserver(scrollEndObserver) }
        }

        func update(_ input: CalendarMacCollectionViewport, environment: EnvironmentValues) {
            let changedIDs = items.map(\.id) != input.items.map(\.id)
            items = input.items
            self.environment = environment
            onOffset = input.onOffset
            onScrollEnd = input.onScrollEnd
            slotActions = input.slotActions
            backgroundHost.rootView = AnyView(input.background.environment(\.self, environment))
            layout.size = input.contentSize
            layout.activeIndex = input.activeID.flatMap { id in items.firstIndex { $0.id.hasSuffix("|" + id) } }
            layout.attributes = items.enumerated().map { index, item in
                let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
                attributes.frame = item.frame
                attributes.zIndex = item.zIndex
                return attributes
            }
            collection.setFrameSize(input.contentSize)
            layout.invalidateLayout()
            if changedIDs { collection.reloadData() }
            else {
                for index in collection.indexPathsForVisibleItems() where items.indices.contains(index.item) {
                    let cell = collection.item(at: index) as? CalendarMacEventItem
                    cell?.setHitTesting(items[index.item].allowsHitTesting)
                    cell?.setContent(content(at: index.item))
                }
            }
            if !initializedOffset, let initialOffset = input.initialOffset, scroll.contentView.bounds.height > 0 {
                initializedOffset = true
                let y = min(max(0, initialOffset), max(0, input.contentSize.height - scroll.contentView.bounds.height))
                scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        private func handleSlotMenu(_ event: NSEvent) -> NSEvent? {
            guard let window = scroll.window, event.window === window,
                  let parent = collection.superview else { return event }
            let scrollPoint = scroll.convert(event.locationInWindow, from: nil)
            guard scroll.contentView.frame.contains(scrollPoint) else { return event }
            let hit = collection.hitTest(parent.convert(event.locationInWindow, from: nil))
            let isBackground = hit === backgroundHost || hit?.isDescendant(of: backgroundHost) == true
            guard isBackground else { return event }
            let actions = slotActions(collection.convert(event.locationInWindow, from: nil))
            guard !actions.isEmpty else { return event }
            let menu = NSMenu()
            for action in actions {
                let item = NSMenuItem(title: action.title, action: #selector(performSlotAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action
                menu.addItem(item)
            }
            // NSHostingView supplies its own accessibility children and hides an
            // attached native popup. Anchor to the real scroll view so menu actions
            // are available to accessibility clients as well as pointer input.
            NSMenu.popUpContextMenu(menu, with: event, for: scroll)
            return nil
        }
        @objc private func performSlotAction(_ sender: NSMenuItem) {
            (sender.representedObject as? CalendarMacSlotAction)?.perform()
        }
        private func content(at index: Int) -> AnyView {
            let content = items[index].content().environment(\.self, environment)
                .environment(\.calendarNativeCell, true)
            // Experimental: updating a stable graph must rebind every action and invalidate
            // event-local state. Keep occurrence identity/reset as the production control
            // until the reuse, gesture, prepared-artwork and memory checks establish parity.
            if CalendarMacCellGraphPolicy.retainsGraph { return AnyView(content) }
            return AnyView(content.id(items[index].id))
        }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: Self.reuseID, for: indexPath) as! CalendarMacEventItem
            item.setHitTesting(items[indexPath.item].allowsHitTesting)
            item.setContent(content(at: indexPath.item))
            return item
        }
    }
}
#endif
