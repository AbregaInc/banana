#if !BANANA_PUBLIC
#if os(macOS)
import SwiftUI
import AppKit
import Combine

/// The inbox list on the Mac: an `NSTableView` hosting SwiftUI rows at a fixed height — the table
/// prototype P1 built to the same rules as the iOS host (docs/design/mail-working/prototypes/
/// p1-list/). Its Mac scenarios have not been run: they need a visible window and the owner's say.
///
/// Like the iOS host, the rows are not an input of this view: the coordinator observes the triage
/// model's feed and applies each publication in the same turn, so a key press re-evaluates
/// nothing here. Keys do not come through the table at all; the app's key monitor takes them
/// (`MailKeyDispatch`). A double click opens (the single click's action has already placed the
/// cursor).
struct MailListHost: NSViewRepresentable {
    let session: MailSession
    let style: MailRowStyle
    /// A click opens the conversation full width; false, with a reading pane to show it in, it
    /// only places the cursor, and a double click opens.
    let opensOnTap: Bool

    func makeCoordinator() -> MailListCoordinator {
        MailListCoordinator(session: session, style: style, opensOnTap: opensOnTap)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.opensOnTap = opensOnTap
        context.coordinator.setStyle(style)
    }
}

/// One SwiftUI row per cell, reused: the hosting view is made once per cell and only has its
/// root replaced when the cell is reused.
final class MailHostingCell: NSTableCellView {
    private var hosting: NSHostingView<EquatableView<MailRowView>>?

    func set(_ row: MailRowView) {
        let content = EquatableView(content: row)
        if let hosting {
            hosting.rootView = content
        } else {
            let made = NSHostingView(rootView: content)
            made.sizingOptions = []
            made.autoresizingMask = [.width, .height]
            made.frame = bounds
            addSubview(made)
            hosting = made
        }
    }
}

@MainActor
final class MailListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()

    private let session: MailSession
    private var style: MailRowStyle
    var opensOnTap: Bool
    private let table = NSTableView()
    private var order: [MailConversationID] = []
    private var rows: [MailConversationID: MailRow] = [:]
    private var displays: [MailConversationID: MailRowDisplay] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    /// The window the rows were last applied for (`MailListShown.windowBefore`).
    private var shownWindow: MailOrderKey?
    /// The status row after the last conversation, made once (`MailListStatusRow`).
    private lazy var statusCell: NSView = {
        let session = self.session
        let view = NSHostingView(rootView: MailListStatusRow(feed: session.feed) { session.retryPaging() })
        view.sizingOptions = []
        view.identifier = Self.statusID
        return view
    }()
    private var pendingViewport: MailViewport?
    private var viewportDeliveryScheduled = false
    private static let cellID = NSUserInterfaceItemIdentifier("mail.row")
    private static let statusID = NSUserInterfaceItemIdentifier("mail.status")

    init(session: MailSession, style: MailRowStyle, opensOnTap: Bool) {
        self.session = session
        self.style = style
        self.opensOnTap = opensOnTap
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = style.height
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        shownWindow = session.feed.shown.windowBefore
        load(session.feed.shown.rows)
        table.reloadData()
        session.feed.$shown.dropFirst().sink { [weak self] shown in
            self?.show(shown)
        }.store(in: &subscriptions)
        session.hostCommands.sink { [weak self] command in
            switch command {
            case .reveal(let id, let beyond): self?.reveal(id, beyond: beyond)
            case .scrollToTop: self?.scrollToTop()
            }
        }.store(in: &subscriptions)

        // A host built for a list that has a cursor (a return to Mail) opens at it.
        if let cursor = session.model.cursor {
            DispatchQueue.main.async { [weak self] in self?.reveal(cursor, beyond: nil) }
        }
    }

    // MARK: Rows

    /// Takes the rows in and says which of the ones already here changed.
    @discardableResult
    private func load(_ shown: [MailRow]) -> Set<MailConversationID> {
        var seen = Set<MailConversationID>()
        var newOrder: [MailConversationID] = []
        var changed = Set<MailConversationID>()
        for row in shown where seen.insert(row.id).inserted {
            newOrder.append(row.id)
            if rows[row.id] != row {
                if rows[row.id] != nil { changed.insert(row.id) }
                rows[row.id] = row
                displays[row.id] = MailRowDisplay(row, now: session.now)
            }
        }
        // Table updates below are non-animated; removed rows need no retained display cache.
        for id in order where !seen.contains(id) {
            rows.removeValue(forKey: id)
            displays.removeValue(forKey: id)
        }
        order = newOrder
        return changed
    }

    private func apply(_ shown: [MailRow]) {
        let old = order
        let changed = load(shown)
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in order.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        table.beginUpdates()
        table.removeRows(at: removals, withAnimation: [])
        table.insertRows(at: insertions, withAnimation: [])
        table.endUpdates()
        let stale = IndexSet(order.enumerated().filter { changed.contains($0.element) }.map(\.offset))
        if !stale.isEmpty { table.reloadData(forRowIndexes: stale, columnIndexes: IndexSet(integer: 0)) }
    }

    /// A publication of the feed. When the window has slid, rows came and went far above or
    /// below the visible ones: the first row in view is put back exactly where it was, so
    /// nothing he is looking at moves (`MailPaging`). Rows are one height, so this is exact.
    private func show(_ shown: MailListShown) {
        guard shown.windowBefore != shownWindow else { return apply(shown.rows) }
        shownWindow = shown.windowBefore
        let visible = table.visibleRect
        let range = table.rows(in: visible)
        let anchor = order.indices.contains(range.location)
            ? (id: order[range.location], fromTop: table.rect(ofRow: range.location).minY - visible.minY) : nil
        apply(shown.rows)
        guard let anchor, let row = order.firstIndex(of: anchor.id) else { return }
        let y = table.rect(ofRow: row).minY - anchor.fromTop
        if abs(y - visible.minY) > 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func setStyle(_ new: MailRowStyle) {
        guard new != style else { return }
        style = new
        table.rowHeight = new.height
        table.reloadData()
    }

    // MARK: Data source and delegate

    /// The conversations, and the status row after them.
    func numberOfRows(in tableView: NSTableView) -> Int { order.count + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if row == order.count { return statusCell }
        guard order.indices.contains(row), let display = displays[order[row]] else { return nil }
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? MailHostingCell) ?? {
            let made = MailHostingCell()
            made.identifier = Self.cellID
            return made
        }()
        let id = order[row]
        cell.set(MailRowView(id: id, display: display, style: style, height: style.height,
                             mark: session.marks.mark(for: id)))
        return cell
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard order.indices.contains(row) else { return }
        if opensOnTap { session.open(order[row]) } else { session.select(order[row]) }
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard order.indices.contains(row) else { return }
        session.open(order[row])
    }

    // MARK: Scrolling

    @objc private func clipBoundsChanged(_ notification: Notification) {
        let visible = table.visibleRect
        let range = table.rows(in: visible)
        guard range.length > 0, order.indices.contains(range.location),
              let row = rows[order[range.location]] else { return }
        pendingViewport = MailViewport(firstRow: row.id, key: row.key,
                                       offset: Int((table.rect(ofRow: range.location).minY - visible.minY).rounded()),
                                       rowsOnScreen: min(range.length, order.count - range.location))
        guard !viewportDeliveryScheduled else { return }
        viewportDeliveryScheduled = true
        let scope = session.scope
        // A bounds notification may arrive during table updates. Coalesce and leave that
        // update before requesting more rows; only visible geometry is inspected above.
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
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Shows the row whole, and one more beyond it in the direction of travel when there is one;
    /// not an inch more. The row beyond is asked for first so the row itself has the last word.
    private func reveal(_ id: MailConversationID, beyond: MailDirection?) {
        guard let row = order.firstIndex(of: id) else { return }
        if let beyond {
            let next = row + (beyond == .older ? 1 : -1)
            if order.indices.contains(next) { table.scrollRowToVisible(next) }
        }
        table.scrollRowToVisible(row)
    }
}
#endif

#endif
