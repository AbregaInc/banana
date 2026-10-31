#if os(iOS)
import SwiftUI
import UIKit
import Combine

// MARK: - SwiftUI side

/// The wrapper SwiftUI sees. Its body, and every `updateUIView`, counts as the container
/// re-evaluating; neither runs when the rows change (the coordinator observes the model itself),
/// when the cursor moves, or when the list scrolls.
struct NativeHostView: View {
    let model: InboxModel
    var body: some View {
        let _ = Counters.container += 1
        NativeHost(model: model)
    }
}

private struct NativeHost: UIViewRepresentable {
    let model: InboxModel

    func makeCoordinator() -> NativeList { NativeList(model: model) }

    func makeUIView(context: Context) -> UICollectionView {
        let list = context.coordinator
        model.bridge = list
        return list.collectionView
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        Counters.container += 1
        Counters.update += 1
    }
}

// MARK: - The collection view

/// Applies the restored offset in the first layout pass that has a size and content, so the first
/// frame it draws is already at the restored position (never a frame at the top first).
final class RestoringCollectionView: UICollectionView {
    /// Runs once, in the first layout pass that has a size and content, and may move the offset.
    var pendingRestore: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        if let restore = pendingRestore, bounds.height > 0, contentSize.height > 0 {
            pendingRestore = nil
            restore()
            super.layoutSubviews()
        }
    }
}

/// Fixed row height: the cell answers the self-sizing pass without measuring its SwiftUI content.
final class FixedHeightCell: UICollectionViewListCell {
    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let a = attrs.copy() as! UICollectionViewLayoutAttributes
        a.size.height = RowMetrics.height
        return a
    }
}

@MainActor
final class NativeList: NSObject, HostBridge, UICollectionViewDelegate {
    private let model: InboxModel
    let collectionView: RestoringCollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, Int>!
    private var sink: AnyCancellable?

    init(model: InboxModel) {
        self.model = model

        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        config.leadingSwipeActionsConfigurationProvider = { ip in
            NativeList.swipe(["Snooze": "clock", "Unread": "envelope.badge"], order: RowActions.leading, leading: true, ip: ip)
        }
        config.trailingSwipeActionsConfigurationProvider = { ip in
            NativeList.swipe(["Done": "checkmark", "Trash": "trash"], order: RowActions.trailing, leading: false, ip: ip)
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = RestoringCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.selfSizingInvalidation = .disabled
        super.init()
        collectionView.delegate = self

        let registration = UICollectionView.CellRegistration<FixedHeightCell, Int> { [model] cell, _, id in
            cell.contentConfiguration = UIHostingConfiguration {
                MailRow(conv: Fixture.conversation(id), mark: model.mark(for: id)).equatable()
            }
            .margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: registration, for: ip, item: id)
        }
        apply(ids: model.rows.map(\.id))
        if let stamp = model.restore {
            collectionView.pendingRestore = { [unowned self] in
                if let ip = dataSource.indexPath(for: stamp.id) { place(item: ip.item, into: stamp.points) }
            }
        }
        // `@Published` hands over the new value before it is stored: applying here is synchronous with
        // the model's publish, which is what lets `restoreAnchor` (called right after) fix the offset
        // before any frame is drawn.
        sink = model.$rows.dropFirst().sink { [weak self] rows in self?.apply(ids: rows.map(\.id)) }
    }

    private static func swipe(_ images: [String: String], order: [String], leading: Bool, ip: IndexPath) -> UISwipeActionsConfiguration {
        let actions = order.map { name -> UIContextualAction in
            let a = UIContextualAction(style: .normal, title: name) { _, _, done in
                SwipeLog.shared.record(leading: leading, name, row: ip.item)
                done(true)
            }
            a.image = UIImage(systemName: images[name] ?? "circle")
            return a
        }
        let c = UISwipeActionsConfiguration(actions: actions)
        c.performsFirstActionWithFullSwipe = true
        return c
    }

    private func apply(ids: [Int]) {
        var snap = NSDiffableDataSourceSnapshot<Int, Int>()
        snap.appendSections([0])
        snap.appendItems(ids)
        dataSource.apply(snap, animatingDifferences: false)
    }

    // MARK: HostBridge
    //
    // Positions are row-keyed ("row i, p points into it"), never absolute offsets: the list layout
    // estimates the height of rows it has not drawn (52 pt here, against the 64 pt every drawn row
    // reports), so the same absolute offset names different rows before and after rows are realised.

    private var H: CGFloat { RowMetrics.height }
    private var inset: CGFloat { collectionView.adjustedContentInset.top }
    var rowCount: Int { dataSource.snapshot().numberOfItems }
    var viewportHeight: CGFloat {
        collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
    }

    /// The row at the top edge of the viewport, and how many points of it are above the edge.
    private func topRow() -> (item: Int, id: Int, into: CGFloat, height: CGFloat)? {
        let y = Introspect.offset(collectionView)           // content y of the viewport's top edge
        var ip = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: y + 0.5))
        if ip == nil { ip = collectionView.indexPathsForVisibleItems.min() }
        guard let ip, let id = dataSource.itemIdentifier(for: ip),
              let f = collectionView.layoutAttributesForItem(at: ip)?.frame else { return nil }
        return (ip.item, id, y - f.minY, f.height)
    }

    /// Row-based offset: the same arithmetic the SwiftUI hosts use (row index x fixed height + points in).
    var knownOffset: CGFloat {
        guard let t = topRow() else { return 0 }
        return CGFloat(t.item) * H + t.into
    }

    /// Puts `item`'s top `into` points above the viewport's top edge. Re-asserted once after a layout pass:
    /// realising rows between the old and new position replaces estimates with real heights.
    private func place(item: Int, into: CGFloat) {
        let ip = IndexPath(item: min(max(item, 0), max(rowCount - 1, 0)), section: 0)
        for _ in 0..<3 {
            guard let f = collectionView.layoutAttributesForItem(at: ip)?.frame else { return }
            let target = f.minY + into - inset
            if abs(collectionView.contentOffset.y - target) < 0.25 { return }
            collectionView.contentOffset = CGPoint(x: 0, y: target)
            collectionView.layoutIfNeeded()
        }
    }

    func scroll(toOffset y: CGFloat) {
        let idx = min(max(Int(floor(y / H)), 0), max(rowCount - 1, 0))
        place(item: idx, into: y - CGFloat(idx) * H)
    }

    func captureAnchor(rows: [Conversation]) -> Anchor? {
        guard let t = topRow() else { return nil }
        return Anchor(id: t.id, frac: t.into / t.height)
    }

    func restoreAnchor(_ anchor: Anchor?) {
        guard let anchor, let ip = dataSource.indexPath(for: anchor.id),
              let f = collectionView.layoutAttributesForItem(at: ip)?.frame else { return }
        place(item: ip.item, into: anchor.frac * f.height)
    }

    func stamp() -> RestoreStamp? {
        guard let t = topRow() else { return nil }
        return RestoreStamp(id: t.id, points: t.into.rounded())
    }

    func groundTruthY(windowIndex: Int) -> CGFloat? { Introspect.cellY(windowIndex: windowIndex) }
    func groundTruthOffset() -> CGFloat? { Introspect.offset(collectionView) }

    func debugString() -> String {
        let f = { (i: Int) -> String in
            self.collectionView.layoutAttributesForItem(at: IndexPath(item: i, section: 0)).map { "\(i):y=\($0.frame.minY),h=\($0.frame.height)" } ?? "\(i):nil"
        }
        return "contentH=\(collectionView.contentSize.height) offset=\(collectionView.contentOffset.y) knownVirtual=\(knownOffset) items=[\([0, 1, 2, 49, 50, 51, 137, 399].map(f).joined(separator: " "))] visible=\(collectionView.indexPathsForVisibleItems.map(\.item).min() ?? -1)...\(collectionView.indexPathsForVisibleItems.map(\.item).max() ?? -1) cells=\(collectionView.visibleCells.count) bounds=\(collectionView.bounds) inset=\(collectionView.adjustedContentInset)"
    }
}
#endif
