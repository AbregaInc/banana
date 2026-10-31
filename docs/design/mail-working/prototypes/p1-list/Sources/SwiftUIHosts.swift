import SwiftUI

/// How a SwiftUI host is asked to hold position. Each is a different, still-idiomatic answer to
/// "the rows changed above the viewport: keep what is on screen where it is".
enum Variant: String {
    /// `ScrollPosition` as `@State`; `scrollTo(y:)` in the same transaction as the data change.
    case positionY
    /// `ScrollPosition` as `@State`; `scrollTo(id:anchor:)`, the anchor carrying the fraction of a row.
    case positionID
    /// `ScrollViewReader`; `scrollTo(id, anchor: fraction)` called from `.onChange` of the rows.
    case reader
    /// Same, called synchronously right after the model publishes (before SwiftUI has seen the rows).
    case readerNow
    /// Same, one runloop turn later.
    case readerAsync
    /// Nothing: whatever the host does by itself (navigation through the reader's proxy).
    case none
    /// `.defaultScrollAnchor(.bottom, for: .sizeChanges)`.
    case anchor
    /// `.scrollPosition(id:)` with a tracked top id in `@State` (and `scrollTargetLayout` on the lazy stack);
    /// programmatic scrolling, including fractions of a row, through the reader's proxy.
    case id
    /// `.scrollPosition(id:)` whose binding is a plain reference (no state, so nothing re-evaluates when
    /// the top row changes); programmatic scrolling through the reader's proxy.
    case idBox
}

struct ScrollInfo: Equatable, Sendable {
    var offset: CGFloat
    var viewport: CGFloat
    var content: CGFloat
}

/// The bridge for `List` and `LazyVStack`: a SwiftUI scroll view cannot be asked where it is, so it
/// tracks what it last asked for, reports what `onScrollGeometryChange` last saw (for the record),
/// and holds the two handles SwiftUI gives (the reader's proxy, the position binding).
@MainActor
final class SwiftUIBridge: ObservableObject, HostBridge {
    let variant: Variant
    weak var model: InboxModel?
    var proxy: ScrollViewProxy?
    var setPosition: ((CGFloat) -> Void)?
    var setPositionID: ((Int, CGFloat) -> Void)?
    var setTopID: ((Int) -> Void)?
    var pending: Anchor?
    /// The top row id SwiftUI writes through the `idBox` binding. Plain storage: writing it invalidates nothing.
    var trackedID: Int?

    var reported = ScrollInfo(offset: 0, viewport: 0, content: 0)
    private(set) var asked: CGFloat
    private var askedAt: CFTimeInterval = 0
    /// What the host last asked for (the app knows where it put the list, and SwiftUI has not reported it yet),
    /// unless the person has scrolled by hand since: then what `onScrollGeometryChange` last reported.
    var wholeRowScroll: Bool { variant == .id }
    private var scrolledByHand = false
    func handScrolled() { scrolledByHand = true }
    var knownOffset: CGFloat {
        (!scrolledByHand || CACurrentMediaTime() - askedAt < 0.06 || reported.viewport == 0) ? asked : reported.offset
    }
    var rowCount: Int { model?.rows.count ?? 0 }
    static var lastViewport: CGFloat = 700
    var viewportHeight: CGFloat { reported.viewport > 0 ? reported.viewport : Self.lastViewport }

    /// `scrollTo(id:anchor:)` lines the anchor point of the row up with the *same unit point of the
    /// viewport*, not with the viewport's top edge. Putting a row's top `points` above the top edge
    /// therefore takes y = -points / (viewport - row height). (Assuming y = points / row height, as
    /// the first version of this prototype did, misplaces the row by most of a screen.)
    func anchor(points: CGFloat) -> UnitPoint {
        guard points > 0.001 else { return .top }
        return UnitPoint(x: 0, y: -points / max(viewportHeight - RowMetrics.height, 1))
    }

    init(variant: Variant, model: InboxModel) {
        self.variant = variant
        self.model = model
        self.asked = model.restore.flatMap(model.virtualOffset(of:)) ?? 0
        self.trackedID = model.restore?.id
    }

    // MARK: HostBridge

    func scroll(toOffset y: CGFloat) {
        asked = y
        askedAt = CACurrentMediaTime()
        scrolledByHand = false
        guard let model else { return }
        let h = RowMetrics.height
        switch variant {
        case .positionY:
            setPosition?(y)
        case .positionID:
            let idx = min(max(Int(floor(y / h)), 0), model.rows.count - 1)
            setPositionID?(model.rows[idx].id, y - CGFloat(idx) * h)
        case .id:
            // The binding is the position: whole rows. A scroll that stops mid-row goes through the proxy.
            let idx = min(max(Int(floor(y / h)), 0), model.rows.count - 1)
            let into = y - CGFloat(idx) * h
            if into < 0.5 { setTopID?(model.rows[idx].id) }
            else if h - into < 0.5, idx + 1 < model.rows.count { setTopID?(model.rows[idx + 1].id) }
            else { proxy?.scrollTo(model.rows[idx].id, anchor: anchor(points: into)) }
        case .reader, .readerNow, .readerAsync, .none, .anchor, .idBox:
            let idx = min(max(Int(floor(y / h)), 0), model.rows.count - 1)
            proxy?.scrollTo(model.rows[idx].id, anchor: anchor(points: y - CGFloat(idx) * h))
        }
    }

    /// Keep-the-cursor-visible, the way a SwiftUI author writes it: the row beyond the cursor goes to the
    /// bottom edge (or the row before it to the top edge) with `scrollTo(id, anchor: .bottom / .top)`. Same
    /// target offset as every other host; only the reader variants (the proxy) do it this way.
    func reveal(windowIndex: Int, direction: Int) -> CGFloat {
        guard let model, [.reader, .readerNow, .readerAsync, .none, .anchor, .idBox].contains(variant) else {
            let cur = knownOffset
            guard let t = Reveal.target(current: cur, viewport: viewportHeight, rowCount: rowCount, windowIndex: windowIndex,
                                        direction: direction, wholeRows: wholeRowScroll) else { return 0 }
            scroll(toOffset: t)
            return t - cur
        }
        let cur = knownOffset
        guard let t = Reveal.target(current: cur, viewport: viewportHeight, rowCount: rowCount, windowIndex: windowIndex,
                                    direction: direction, wholeRows: false) else { return 0 }
        asked = t
        askedAt = CACurrentMediaTime()
        scrolledByHand = false
        if direction >= 0 {
            proxy?.scrollTo(model.rows[min(windowIndex + 1, model.rows.count - 1)].id, anchor: .bottom)
        } else {
            proxy?.scrollTo(model.rows[max(windowIndex - 1, 0)].id, anchor: .top)
        }
        return t - cur
    }

    func captureAnchor(rows: [Conversation]) -> Anchor? {
        guard !rows.isEmpty else { return nil }
        let h = RowMetrics.height
        let k = knownOffset
        let idx = min(max(Int(floor(k / h)), 0), rows.count - 1)
        return Anchor(id: rows[idx].id, frac: (k - CGFloat(idx) * h) / h)
    }

    func restoreAnchor(_ anchor: Anchor?) {
        guard let anchor, let model, let idx = model.windowIndex(ofID: anchor.id) else { return }
        let h = RowMetrics.height
        let y = CGFloat(idx) * h + anchor.frac * h
        switch variant {
        case .none, .anchor, .id, .idBox:
            break                                   // the host's own business
        case .positionY:
            asked = y
            setPosition?(y)
        case .positionID:
            asked = y
            setPositionID?(anchor.id, anchor.frac * h)
        case .readerNow:
            asked = y
            proxy?.scrollTo(anchor.id, anchor: self.anchor(points: anchor.frac * h))
        case .readerAsync:
            asked = y
            let a = anchor
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.proxy?.scrollTo(a.id, anchor: self.anchor(points: a.frac * h))
            }
        case .reader:
            asked = y
            pending = anchor                        // flushed from .onChange, i.e. during SwiftUI's update
        }
    }

    /// The `ScrollPosition` a freshly built host starts from: the restored offset, in the variant's own terms.
    func initialPosition() -> ScrollPosition {
        guard let model, let stamp = model.restore, let off = model.virtualOffset(of: stamp) else { return ScrollPosition(y: 0) }
        switch variant {
        case .positionID: return ScrollPosition(id: stamp.id, anchor: anchor(points: stamp.points))
        default: return ScrollPosition(y: off)
        }
    }

    /// Called from the host's `.onAppear`: hands over the SwiftUI handles, and for the reader variants
    /// performs the restore (the only way they have: after the first layout).
    func install(proxy: ScrollViewProxy, setPosition: @escaping (CGFloat) -> Void,
                 setPositionID: @escaping (Int, CGFloat) -> Void, setTopID: @escaping (Int) -> Void) {
        self.proxy = proxy
        self.setPosition = setPosition
        self.setPositionID = setPositionID
        self.setTopID = setTopID
        model?.bridge = self
        if let stamp = model?.restore, [.reader, .readerNow, .readerAsync, .none, .anchor, .idBox, .id].contains(variant) {
            proxy.scrollTo(stamp.id, anchor: anchor(points: stamp.points))
        }
    }

    func flushPending() {
        guard let a = pending else { return }
        pending = nil
        proxy?.scrollTo(a.id, anchor: anchor(points: a.frac * RowMetrics.height))
    }

    /// What a SwiftUI host can read about where it is: the offset `onScrollGeometryChange` last reported,
    /// turned into (row, points) with the app's own model of the rows (every row `RowMetrics.height`).
    func stamp() -> RestoreStamp? {
        guard let rows = model?.rows, !rows.isEmpty else { return nil }
        let h = RowMetrics.height
        let off = reported.viewport > 0 ? reported.offset : asked
        let idx = min(max(Int(floor(off / h)), 0), rows.count - 1)
        return RestoreStamp(id: rows[idx].id, points: (off - CGFloat(idx) * h).rounded())
    }

    func groundTruthY(windowIndex: Int) -> CGFloat? {
        #if os(iOS)
        return Introspect.cellY(windowIndex: windowIndex)
        #else
        return Introspect.rowY(windowIndex: windowIndex)
        #endif
    }

    func groundTruthOffset() -> CGFloat? { Introspect.scrollView().map { Introspect.offset($0) } }
}

// MARK: - Shared modifiers

private struct HoldPosition: ViewModifier {
    let variant: Variant
    let bridge: SwiftUIBridge
    @Binding var position: ScrollPosition
    @Binding var topID: Int?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch variant {
        case .positionY, .positionID:
            content.scrollPosition($position)
        case .anchor:
            content
                .defaultScrollAnchor(.top, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        case .id:
            content.scrollPosition(id: $topID, anchor: .top)
        case .idBox:
            content.scrollPosition(id: Binding<Int?>(get: { bridge.trackedID }, set: { bridge.trackedID = $0 }), anchor: .top)
        case .reader, .readerNow, .readerAsync, .none:
            content
        }
    }
}

private struct ReportScroll: ViewModifier {
    let bridge: SwiftUIBridge
    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: ScrollInfo.self, of: { g in
            ScrollInfo(offset: g.contentOffset.y + g.contentInsets.top,
                       viewport: g.containerSize.height,
                       content: g.contentSize.height)
        }, action: { _, new in bridge.reported = new; SwiftUIBridge.lastViewport = new.viewport })
    }
}

private struct RowKey: Equatable { var first: Int?; var last: Int? }

// MARK: - List

struct ListHost: View {
    @ObservedObject var model: InboxModel
    let variant: Variant
    @StateObject private var bridge: SwiftUIBridge
    @State private var position: ScrollPosition
    @State private var topID: Int?

    init(model: InboxModel, variant: Variant) {
        self.model = model
        self.variant = variant
        let b = SwiftUIBridge(variant: variant, model: model)
        _bridge = StateObject(wrappedValue: b)
        _position = State(initialValue: b.initialPosition())
        if variant == .id, let stamp = model.restore { _topID = State(initialValue: stamp.id) }
    }

    var body: some View {
        let _ = Counters.container += 1
        ScrollViewReader { proxy in
            List(model.rows) { conv in
                MailRow(conv: conv, mark: model.mark(for: conv.id))
                    .equatable()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { SwipeLog.shared.record(leading: false, "Done", row: conv.id) } label: { Label("Done", systemImage: "checkmark") }.tint(.green)
                        Button { SwipeLog.shared.record(leading: false, "Trash", row: conv.id) } label: { Label("Trash", systemImage: "trash") }.tint(.red)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { SwipeLog.shared.record(leading: true, "Snooze", row: conv.id) } label: { Label("Snooze", systemImage: "clock") }.tint(.orange)
                        Button { SwipeLog.shared.record(leading: true, "Unread", row: conv.id) } label: { Label("Unread", systemImage: "envelope.badge") }.tint(.blue)
                    }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, RowMetrics.height)
            .modifier(HoldPosition(variant: variant, bridge: bridge, position: $position, topID: $topID))
            .modifier(ReportScroll(bridge: bridge))
            .onChange(of: RowKey(first: model.rows.first?.id, last: model.rows.last?.id)) { _, _ in bridge.flushPending() }
            .onAppear {
                bridge.install(proxy: proxy,
                               setPosition: { y in var p = position; p.scrollTo(y: y); position = p },
                               setPositionID: { id, pts in var p = position; p.scrollTo(id: id, anchor: bridge.anchor(points: pts)); position = p },
                               setTopID: { topID = $0 })
            }
        }
    }
}

// MARK: - LazyVStack

struct LazyHost: View {
    @ObservedObject var model: InboxModel
    let variant: Variant
    let diySwipe: Bool
    @StateObject private var bridge: SwiftUIBridge
    @State private var position: ScrollPosition
    @State private var topID: Int?

    init(model: InboxModel, variant: Variant, diySwipe: Bool) {
        self.model = model
        self.variant = variant
        self.diySwipe = diySwipe
        let b = SwiftUIBridge(variant: variant, model: model)
        _bridge = StateObject(wrappedValue: b)
        _position = State(initialValue: b.initialPosition())
        if variant == .id, let stamp = model.restore { _topID = State(initialValue: stamp.id) }
    }

    var body: some View {
        let _ = Counters.container += 1
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { conv in
                        MailRow(conv: conv, mark: model.mark(for: conv.id))
                            .equatable()
                            .modifier(DIYSwipe(enabled: diySwipe, simultaneous: LaunchArgs.current.diySimultaneous, id: conv.id))
                    }
                }
                .scrollTargetLayout(isEnabled: variant == .id || variant == .idBox)
            }
            .modifier(HoldPosition(variant: variant, bridge: bridge, position: $position, topID: $topID))
            .modifier(ReportScroll(bridge: bridge))
            .onChange(of: RowKey(first: model.rows.first?.id, last: model.rows.last?.id)) { _, _ in bridge.flushPending() }
            .onAppear {
                bridge.install(proxy: proxy,
                               setPosition: { y in var p = position; p.scrollTo(y: y); position = p },
                               setPositionID: { id, pts in var p = position; p.scrollTo(id: id, anchor: bridge.anchor(points: pts)); position = p },
                               setTopID: { topID = $0 })
            }
        }
    }
}

/// `LazyVStack` has no `.swipeActions`. A swipe there is a drag gesture on the row, which is what
/// the UI test checks against scrolling. Never applied in measured runs.
private struct DIYSwipe: ViewModifier {
    let enabled: Bool
    let simultaneous: Bool
    let id: Int

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24).onEnded { v in
            guard abs(v.translation.width) > 120, abs(v.translation.width) > abs(v.translation.height) * 2 else { return }
            SwipeLog.shared.record(leading: v.translation.width > 0, v.translation.width > 0 ? "Snooze" : "Done", row: id)
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled && simultaneous { content.simultaneousGesture(swipe) }
        else if enabled { content.gesture(swipe) }
        else { content }
    }
}
