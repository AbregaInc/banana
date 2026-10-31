#if !BANANA_PUBLIC
#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// The inbox list on iPhone and iPad: a `UICollectionView` list layout hosting SwiftUI rows at a
/// fixed height — the host prototype P1 measured and chose (docs/design/mail-working/prototypes/
/// p1-list/RESULTS.md). SwiftUI's own `List` failed every positional test.
///
/// What the host requires, and keeps to: a position is a row and points, never an offset (rows are
/// self-sized from an estimate until drawn); the system's swipe actions, never a drag gesture on a
/// row; and nothing in a hosted row reads its own geometry to decide anything about scrolling.
///
/// The rows are not an input of this view. The coordinator observes the triage model's feed
/// itself and applies each publication in the same turn, so a key or a tap re-evaluates nothing
/// here (the container's body and `updateUIView` run when the *style* changes, and no other time).
struct MailListHost: UIViewRepresentable {
    let session: MailSession
    let style: MailRowStyle
    /// A tap opens the conversation full width; false, with a reading pane to show it in, it only
    /// places the cursor.
    let opensOnTap: Bool

    func makeCoordinator() -> MailListCoordinator {
        MailListCoordinator(session: session, style: style, opensOnTap: opensOnTap)
    }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.collectionView
    }

    func updateUIView(_ uiView: UICollectionView, context: Context) {
        context.coordinator.opensOnTap = opensOnTap
        context.coordinator.setStyle(style)
    }
}

/// Runs a piece of work in the first layout pass that has a size and content, so the first frame
/// is already at the restored position and never a frame at the top first.
final class MailRestoringCollectionView: UICollectionView {
    var pendingRestore: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        if let restore = pendingRestore, bounds.height > 0, contentSize.height > 0 {
            pendingRestore = nil
            // Twice: the first pass scrolls by the layout's estimates for rows not yet drawn, and
            // lands short of a row deep in the list (found on an iPad after the tree was rebuilt
            // in the background); the second uses the frames the first pass drew.
            restore()
            super.layoutSubviews()
            restore()
            super.layoutSubviews()
        }
    }
}

/// The cell answers the self-sizing pass without measuring its SwiftUI content.
final class MailFixedHeightCell: UICollectionViewListCell {
    var fixedHeight: CGFloat = DS.Mail.oneLineRow

    override func preferredLayoutAttributesFitting(
        _ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        guard let copy = attributes.copy() as? UICollectionViewLayoutAttributes else { return attributes }
        copy.size.height = fixedHeight
        return copy
    }
}

/// A way to reach the coordinator from closures made before it exists.
@MainActor
private final class MailSwipeSource {
    weak var coordinator: MailListCoordinator?
}

@MainActor
final class MailListCoordinator: NSObject, UICollectionViewDelegate {
    let collectionView: MailRestoringCollectionView

    private let session: MailSession
    private var style: MailRowStyle
    /// `style.height` at the text size in force: worked out when the style or the text size
    /// changes (`setStyle`, `textSizeChanged`) and only read when a cell is configured, which is
    /// on the scroll path of a list that is meant to measure nothing.
    private var rowHeight: CGFloat
    var opensOnTap: Bool
    private var dataSource: UICollectionViewDiffableDataSource<Int, MailConversationID>!
    private var rows: [MailConversationID: MailRow] = [:]
    private var displays: [MailConversationID: MailRowDisplay] = [:]
    private var order: [MailConversationID] = []
    private var snapshotGeneration: UInt64 = 0
    private var retiredRows: [MailConversationID: UInt64] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingViewport: MailViewport?
    private var viewportDeliveryScheduled = false

    init(session: MailSession, style: MailRowStyle, opensOnTap: Bool) {
        self.session = session
        self.style = style
        rowHeight = style.height
        self.opensOnTap = opensOnTap

        // The swipe providers are needed to make the layout, and the layout to make the view,
        // before there is a `self` to ask: they ask the coordinator through this.
        let swipes = MailSwipeSource()
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        config.leadingSwipeActionsConfigurationProvider = { path in swipes.coordinator?.leadingSwipes(at: path) }
        config.trailingSwipeActionsConfigurationProvider = { path in swipes.coordinator?.trailingSwipes(at: path) }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = MailRestoringCollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.selfSizingInvalidation = .disabled
        super.init()
        swipes.coordinator = self
        collectionView.delegate = self

        let registration = UICollectionView.CellRegistration<MailFixedHeightCell, MailConversationID> {
            [unowned self] cell, _, id in
            cell.fixedHeight = self.rowHeight
            guard let display = self.displays[id] else { return }
            let view = MailRowView(id: id, display: display, style: self.style, height: self.rowHeight,
                                   mark: self.session.marks.mark(for: id))
            cell.contentConfiguration = UIHostingConfiguration { view.equatable() }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource<Int, MailConversationID>(
            collectionView: collectionView) { view, path, id in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
        }

        apply(session.feed.shown.rows, animated: false)
        // `@Published` hands over the new value before it is stored: applying here is synchronous
        // with the model's publish, which is what keeps a row's removal and the cursor's move in
        // one turn (prototype P1).
        session.feed.$shown.dropFirst().sink { [weak self] shown in
            self?.apply(shown.rows, animated: true)
        }.store(in: &subscriptions)
        session.hostCommands.sink { [weak self] command in
            switch command {
            case .reveal(let id, let beyond): self?.reveal(id, beyond: beyond)
            case .scrollToTop: self?.scrollToTop()
            }
        }.store(in: &subscriptions)

        // A host built for a list that has a cursor (a return to Mail, a rebuilt tree) opens at it.
        if let cursor = session.model.cursor {
            collectionView.pendingRestore = { [weak self] in self?.reveal(cursor, beyond: nil) }
        }
        // The rows' height follows the text size (`MailRowStyle.height`): when it changes under a
        // running app, every cell is made again at the new height.
        NotificationCenter.default.addObserver(self, selector: #selector(textSizeChanged),
                                               name: UIContentSizeCategory.didChangeNotification, object: nil)
    }

    @objc private func textSizeChanged() {
        rowHeight = style.height
        redrawRows()
    }

    // MARK: Rows

    private func apply(_ shown: [MailRow], animated: Bool) {
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        var seen = Set<MailConversationID>()
        var newOrder: [MailConversationID] = []
        var changed: [MailConversationID] = []
        for row in shown where seen.insert(row.id).inserted {
            retiredRows.removeValue(forKey: row.id)
            newOrder.append(row.id)
            if rows[row.id] != row {
                if rows[row.id] != nil { changed.append(row.id) }
                rows[row.id] = row
                displays[row.id] = MailRowDisplay(row, now: session.now)
            }
        }
        let retiring = order.filter { !seen.contains($0) }
        for id in retiring { retiredRows[id] = generation }
        let removed = order.count > newOrder.count
        order = newOrder
        var snapshot = NSDiffableDataSourceSnapshot<Int, MailConversationID>()
        snapshot.appendSections([0])
        snapshot.appendItems(newOrder)
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: animated && removed) { [weak self] in
            guard let self else { return }
            // Outgoing cells can still request their display during the transition. A row
            // reinserted (and perhaps removed again) belongs to a later snapshot, so an older
            // completion must not evict it. Release each transition independently of new input.
            for id in retiring where self.retiredRows[id] == generation {
                self.rows.removeValue(forKey: id)
                self.displays.removeValue(forKey: id)
                self.retiredRows.removeValue(forKey: id)
            }
        }
    }

    func setStyle(_ new: MailRowStyle) {
        guard new != style else { return }
        style = new
        rowHeight = new.height
        redrawRows()
    }

    /// Every row made again, at the style's height as it is now.
    private func redrawRows() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visible = collectionView.indexPathsForVisibleItems.filter {
            (collectionView.layoutAttributesForItem(at: $0)?.frame.maxY ?? -.infinity) > top
        }
        guard let path = visible.min(), let id = dataSource.itemIdentifier(for: path),
              let row = rows[id], let frame = collectionView.layoutAttributesForItem(at: path)?.frame else { return }
        pendingViewport = MailViewport(firstRow: id, key: row.key, offset: Int((frame.minY - top).rounded()))
        guard !viewportDeliveryScheduled else { return }
        viewportDeliveryScheduled = true
        let scope = session.scope
        // Layout can report scrolling while applying a snapshot. Deliver the latest position
        // after that pass, so requesting another page cannot reenter collection layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportDeliveryScheduled = false
            guard let viewport = self.pendingViewport else { return }
            self.pendingViewport = nil
            guard self.session.scope == scope, self.session.model.viewport != viewport else { return }
            self.session.send(.scrolled(viewport))
        }
    }

    private func scrollToTop() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    /// Scrolls as far as needed to show the row whole, and one more row beyond it in the
    /// direction of travel when there is one (MAIL-UX T4); not an inch more.
    private func reveal(_ id: MailConversationID, beyond: MailDirection?) {
        guard let path = dataSource.indexPath(for: id) else { return }
        var paths = [path]
        if let beyond {
            let next = IndexPath(item: path.item + (beyond == .older ? 1 : -1), section: 0)
            if next.item >= 0, next.item < order.count { paths.append(next) }
        }
        let frames = paths.compactMap { collectionView.layoutAttributesForItem(at: $0)?.frame }
        guard var wanted = frames.first else { return }
        for frame in frames.dropFirst() { wanted = wanted.union(frame) }

        let inset = collectionView.adjustedContentInset
        let offset = collectionView.contentOffset.y
        let top = offset + inset.top
        let bottom = offset + collectionView.bounds.height - inset.bottom
        var target = offset
        if wanted.minY < top {
            target = wanted.minY - inset.top
        } else if wanted.maxY > bottom {
            target = wanted.maxY - collectionView.bounds.height + inset.bottom
        }
        let lowest = -inset.top
        let highest = max(lowest, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        target = min(max(target, lowest), highest)
        if abs(target - offset) > 0.5 {
            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
    }

    // MARK: Touch

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
        if opensOnTap { session.open(id) } else { session.select(id) }
    }

    /// Done from the trailing edge; a full swipe is Done. It is declared destructive and tinted
    /// `success`, so the row does not snap back before it leaves (MAIL-UX 5.3).
    ///
    /// The swiped row is made the cursor first: on touch the cursor is the row last touched (T2),
    /// and a disposing action settles the cursor on the target's neighbour and shows it (T16).
    /// Acting on a row far from an unseen cursor settled the cursor on itself, at the top, and the
    /// list jumped there from under the thumb.
    fileprivate func trailingSwipes(at path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: path) else { return nil }
        let done = UIContextualAction(style: .destructive, title: "Done") { [weak self] _, _, finished in
            self?.session.send(.place(id))
            self?.session.act(.done, on: id)
            finished(true)
        }
        done.image = UIImage(systemName: "checkmark")
        done.backgroundColor = UIColor(DS.Palette.success)
        let configuration = UISwipeActionsConfiguration(actions: [done])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    /// Read or unread, and star, from the leading edge. They mark and nothing moves.
    fileprivate func leadingSwipes(at path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: path), let row = rows[id] else { return nil }
        let reading = UIContextualAction(style: .normal, title: row.isUnread ? "Read" : "Unread") {
            [weak self] _, _, finished in
            self?.session.act(.toggleRead, on: id)
            finished(true)
        }
        reading.image = UIImage(systemName: row.isUnread ? "envelope.open" : "envelope.badge")
        reading.backgroundColor = UIColor(DS.Palette.info)
        let star = UIContextualAction(style: .normal, title: row.isStarred ? "Unstar" : "Star") {
            [weak self] _, _, finished in
            self?.session.act(.toggleStar, on: id)
            finished(true)
        }
        star.image = UIImage(systemName: row.isStarred ? "star.slash" : "star")
        star.backgroundColor = UIColor(DS.Palette.accent)
        let configuration = UISwipeActionsConfiguration(actions: [reading, star])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}
#endif

#endif
