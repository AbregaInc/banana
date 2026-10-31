#if os(iOS)
import SwiftUI
import UIKit

final class CalendarMovePressRecognizer: UILongPressGestureRecognizer {
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        let allowed = super.canBePrevented(by: preventingGestureRecognizer)
        (view as? CalendarDayCollectionView)?.auditMove(
            "preventedBy \(type(of: preventingGestureRecognizer)) state=\(preventingGestureRecognizer.state.rawValue) allowed=\(allowed)")
        return allowed
    }
}

/// Geometry is supplied by the same calendar rules as the reference renderer. Only cells
/// intersecting UIKit's requested viewport instantiate their SwiftUI event content.
struct CalendarViewportItem {
    let id: String
    let frame: CGRect
    var zIndex: Int = 0
    var retainsActiveGesture = false
    var allowsHitTesting = true
    var move: CalendarViewportMove? = nil
    let content: () -> AnyView

    /// One overnight occurrence can have cells in multiple visible day columns.
    /// Namespace viewport tracking only; callbacks still act on the original occurrence.
    func namespaced(_ day: String) -> Self {
        let prefix = day + "|"
        return Self(id: prefix + id, frame: frame, zIndex: zIndex,
                    retainsActiveGesture: retainsActiveGesture, allowsHitTesting: allowsHitTesting,
                    move: move.map {
                        CalendarViewportMove(id: prefix + $0.id, columnWidth: $0.columnWidth,
                                             changed: $0.changed, ended: $0.ended, cancelled: $0.cancelled)
                    }, content: content)
    }

    /// Match the reference column's clipping without relaying out a partially visible title.
    func clipped(to column: CGRect) -> Self? {
        let clippedFrame = frame.intersection(column)
        guard !clippedFrame.isNull, !clippedFrame.isEmpty else { return nil }
        guard clippedFrame != frame else { return self }
        return Self(id: id, frame: clippedFrame, zIndex: zIndex,
                    retainsActiveGesture: retainsActiveGesture, allowsHitTesting: allowsHitTesting,
                    move: move) {
            AnyView(content()
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX - clippedFrame.minX, y: frame.minY - clippedFrame.minY)
                .frame(width: clippedFrame.width, height: clippedFrame.height, alignment: .topLeading)
                .clipped())
        }
    }
}

struct CalendarViewportMove {
    let id: String
    let columnWidth: CGFloat
    let changed: (CGSize) -> Void
    /// True when committing or asking about recurrence schedules a model/UI publication.
    let ended: (CGSize) -> Bool
    let cancelled: () -> Void
}

private final class CalendarFixedFrameCell: UICollectionViewCell {
    private static let preservesHostingContent: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-preserve-cell-host")
        #else
        false
        #endif
    }()
    override func preferredLayoutAttributesFitting(
        _ attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes { attributes }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Controlled ablation: UIKit can update a compatible content view in place.
        // Clearing the configuration explicitly replaces it. Keep production unchanged
        // until frame, interaction/state identity and retained-memory checks pass.
        if !Self.preservesHostingContent { contentConfiguration = nil }
    }
}

private final class CalendarDayCollectionLayout: UICollectionViewLayout {
    var attributes: [UICollectionViewLayoutAttributes] = []
    var height: CGFloat = 0
    var contentWidth: CGFloat?
    var activeItem: Int?

    override var collectionViewContentSize: CGSize {
        CGSize(width: contentWidth ?? collectionView?.bounds.width ?? 0, height: height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.indexPath.item == activeItem || $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }
}

/// This is the scroll view itself, not a full-day collection nested inside another scroll.
/// UIKit therefore sees the actual viewport and can recycle offscreen event cells.
final class CalendarDayCollectionView: UICollectionView, UICollectionViewDataSource {
    private static let viewportAuditEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-viewport-audit")
        #else
        false
        #endif
    }()
    private static let auditEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-native-move-audit")
        #else
        false
        #endif
    }()
    private var moveAudit: [String] = []
    private var droppedAuditEvents = 0

    func auditMove(_ message: @autoclosure () -> String) {
        guard Self.auditEnabled else { return }
        if moveAudit.count < 128 { moveAudit.append(message()) }
        else { droppedAuditEvents += 1 }
    }

    override var accessibilityValue: String? {
        get {
            if Self.viewportAuditEnabled {
                var payload: [String: Any] = ["x": contentOffset.x, "y": contentOffset.y,
                    "width": bounds.width, "height": bounds.height,
                    "contentWidth": contentSize.width, "contentHeight": contentSize.height,
                    "gutterX": frozenGutter?.frame.minX ?? 0,
                    "visibleCells": visibleCells.count, "descriptors": items.count,
                    "visibleIDs": indexPathsForVisibleItems.filter { items.indices.contains($0.item) }
                        .sorted().map { items[$0.item].id }]
                #if DEBUG
                payload["columnSelection"] = columnSelectionAudit?()
                #endif
                return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            return Self.auditEnabled ? "nativeMoves=\(Self.nativeMovementEnabled);localFeedback=\(Self.localMovementFeedbackEnabled);dropped=\(droppedAuditEvents);" + moveAudit.joined(separator: ";")
                : super.accessibilityValue
        }
        set { super.accessibilityValue = newValue }
    }
    static let nativeMovementEnabled: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-swiftui-day-move")
        #else
        true
        #endif
    }()
    static let simultaneousMovementEnabled: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-move-exclusive")
        #else
        true
        #endif
    }()
    static let localMovementFeedbackEnabled: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--calendar-parent-move-feedback")
        #else
        true
        #endif
    }()
    private let calendarLayout = CalendarDayCollectionLayout()
    private var items: [CalendarViewportItem] = []
    private var environment = EnvironmentValues()
    weak var calendarBackground: UIView?
    weak var frozenGutter: UIView?
    var gutterWidth: CGFloat = 0
    #if DEBUG
    var columnSelectionAudit: (() -> String)?
    #endif

    func updatePinnedGutter() {
        guard let frozenGutter else { return }
        frozenGutter.frame = CGRect(x: contentOffset.x, y: 0, width: gutterWidth, height: calendarLayout.height)
        bringSubviewToFront(frozenGutter)
    }
    private var previewID: String?
    private var previewOffset = CGSize.zero
    private var previewFinishing = false
    private weak var previewCell: UICollectionViewCell?

    private static let prefetchesCells: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--calendar-prefetch-cells")
        #else
        false
        #endif
    }()

    init() {
        super.init(frame: .zero, collectionViewLayout: calendarLayout)
        register(CalendarFixedFrameCell.self, forCellWithReuseIdentifier: "event")
        dataSource = self
        // Experiment: UIKit cell prefetching prepares cells ahead of display. Off in production
        // until matched frame, memory and reverse-scroll evidence says otherwise.
        isPrefetchingEnabled = Self.prefetchesCells
        selfSizingInvalidation = .disabled
        accessibilityIdentifier = "calendar.nativeDay.viewport"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func moveTarget(at point: CGPoint) -> CalendarViewportMove? {
        guard frozenGutter?.frame.contains(point) != true else { return nil }
        // Match paint order, ignoring the noninteractive current-time line/travel decoration.
        // This uses prepared rectangles, never lane allocation or text layout at touch time.
        let target = items.last { $0.move != nil && $0.frame.contains(point) }?.move
        auditMove("hit \(point) -> \(target?.id ?? "none") of \(items.count)")
        return target
    }

    func containsMoveTarget(_ id: String) -> Bool {
        items.contains { $0.move?.id == id }
    }

    func beginMovePreview(_ target: CalendarViewportMove) {
        cancelMovePreview()
        previewID = target.id
        calendarLayout.activeItem = items.firstIndex { $0.id == target.id }
        calendarLayout.invalidateLayout()
        bindMovePreview()
    }

    func updateMovePreview(_ target: CalendarViewportMove, translation: CGSize) {
        guard previewID == target.id else { return }
        previewOffset = CGSize(width: (translation.width / max(1, target.columnWidth)).rounded() * target.columnWidth,
                               height: translation.height)
        applyMovePreview()
    }

    func finishMovePreview() { previewFinishing = true }

    func cancelMovePreview() {
        previewCell?.transform = .identity
        previewCell?.alpha = 1
        previewCell?.layer.shadowOpacity = 0
        previewCell?.layer.zPosition = 0
        previewCell = nil
        previewID = nil
        calendarLayout.activeItem = nil
        calendarLayout.invalidateLayout()
        previewOffset = .zero
        previewFinishing = false
    }

    private func bindMovePreview() {
        guard let previewID, let index = items.firstIndex(where: { $0.id == previewID }) else { return }
        previewCell = cellForItem(at: IndexPath(item: index, section: 0))
        applyMovePreview()
    }

    private func applyMovePreview() {
        // Pointer updates change only this cell's compositor transform. No SwiftUI parent
        // publication, lane allocation, text layout or snapshot replacement on the move path.
        previewCell?.transform = CGAffineTransform(translationX: previewOffset.width, y: previewOffset.height)
        previewCell?.alpha = 0.75
        previewCell?.layer.zPosition = 1
        previewCell?.layer.shadowColor = UIColor.black.cgColor
        previewCell?.layer.shadowOpacity = 0.25
        previewCell?.layer.shadowRadius = 6
        previewCell?.layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    func apply(_ next: [CalendarViewportItem], height: CGFloat, width: CGFloat? = nil,
               environment: EnvironmentValues, preservesActiveGesture: Bool) {
        if previewFinishing || (previewID != nil && !next.contains(where: { $0.id == previewID })) {
            cancelMovePreview()
        }
        let membershipChanged = items.map(\.id) != next.map(\.id)
        items = next
        self.environment = environment
        calendarLayout.height = height
        calendarLayout.contentWidth = width
        calendarLayout.activeItem = next.firstIndex { $0.id == previewID || $0.retainsActiveGesture }
        calendarLayout.attributes = next.enumerated().map { index, item in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = item.frame
            attributes.zIndex = item.zIndex
            attributes.alpha = item.retainsActiveGesture ? 0.75 : 1
            return attributes
        }
        calendarLayout.invalidateLayout()
        if membershipChanged {
            reloadData()
        } else if !preservesActiveGesture && previewID == nil {
            // Preserve the hosting subtree that owns an in-flight event drag. Its native
            // frame still follows the drag; the latest semantic content is applied on release.
            for path in indexPathsForVisibleItems {
                if let cell = cellForItem(at: path) { configure(cell, at: path) }
            }
        }
        calendarBackground?.frame = CGRect(x: 0, y: 0, width: width ?? bounds.width, height: height)
        updatePinnedGutter()
        for path in indexPathsForVisibleItems {
            guard items.indices.contains(path.item), let cell = cellForItem(at: path) else { continue }
            cell.layer.shadowColor = UIColor.black.cgColor
            cell.layer.shadowOpacity = items[path.item].retainsActiveGesture ? 0.25 : 0
            cell.layer.shadowRadius = 6
            cell.layer.shadowOffset = CGSize(width: 0, height: 3)
        }
        bindMovePreview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let calendarBackground {
            calendarBackground.frame = CGRect(x: 0, y: 0, width: calendarLayout.collectionViewContentSize.width, height: calendarLayout.height)
            sendSubviewToBack(calendarBackground)
        }
        bindMovePreview()
        updatePinnedGutter()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = dequeueReusableCell(withReuseIdentifier: "event", for: indexPath)
        configure(cell, at: indexPath)
        return cell
    }

    func configure(_ cell: UICollectionViewCell, at path: IndexPath) {
        guard items.indices.contains(path.item) else { return }
        let item = items[path.item]
        if previewCell === cell { previewCell = nil }
        cell.transform = .identity
        cell.alpha = item.retainsActiveGesture ? 0.75 : 1
        cell.layer.shadowOpacity = item.retainsActiveGesture ? 0.25 : 0
        cell.layer.zPosition = CGFloat(item.zIndex)
        let environment = environment
        cell.contentConfiguration = UIHostingConfiguration {
            item.content()
                .environment(\.self, environment)
                .environment(\.calendarNativeCell, true)
                .id(item.id)
        }.margins(.all, 0).minSize(width: 0, height: 0)
        cell.backgroundColor = .clear
        cell.isUserInteractionEnabled = item.allowsHitTesting
        cell.clipsToBounds = false
        cell.contentView.clipsToBounds = false
        if item.id == previewID {
            previewCell = cell
            applyMovePreview()
        }
    }
}
#endif
