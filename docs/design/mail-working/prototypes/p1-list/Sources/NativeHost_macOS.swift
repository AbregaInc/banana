#if os(macOS)
import SwiftUI
import AppKit
import Combine

// MARK: - SwiftUI side

struct NativeHostView: View {
    let model: InboxModel
    var body: some View {
        let _ = Counters.container += 1
        NativeHost(model: model)
    }
}

private struct NativeHost: NSViewRepresentable {
    let model: InboxModel

    func makeCoordinator() -> NativeTable { NativeTable(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let t = context.coordinator
        model.bridge = t
        return t.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        Counters.container += 1
        Counters.update += 1
    }
}

// MARK: - The table

/// One SwiftUI row per cell, reused. The hosting view is created once per cell and only has its root
/// replaced when the cell is reused.
final class HostingCell: NSTableCellView {
    private var hosting: NSHostingView<EquatableView<MailRow>>?

    func set(_ row: MailRow) {
        let content = EquatableView(content: row)
        if let hosting {
            hosting.rootView = content
        } else {
            let h = NSHostingView(rootView: content)
            h.sizingOptions = []
            h.autoresizingMask = [.width, .height]
            h.frame = bounds
            addSubview(h)
            hosting = h
        }
    }
}

@MainActor
final class NativeTable: NSObject, NSTableViewDataSource, NSTableViewDelegate, HostBridge {
    private let model: InboxModel
    let scrollView = NSScrollView()
    private let table = NSTableView()
    private var rows: [Conversation]
    private var sink: AnyCancellable?
    private static let cellID = NSUserInterfaceItemIdentifier("row")

    init(model: InboxModel) {
        self.model = model
        self.rows = model.rows
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = RowMetrics.height
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        table.reloadData()
        if let stamp = model.restore, let idx = rows.firstIndex(where: { $0.id == stamp.id }) {
            // Applied before the first display: the clip view's bounds are set while the table is
            // still being built, not after a frame at the top.
            table.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: idx).minY + stamp.points))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        sink = model.$rows.dropFirst().sink { [weak self] new in self?.apply(new) }
    }

    private func apply(_ new: [Conversation]) {
        let diff = new.map(\.id).difference(from: rows.map(\.id))
        var removals = IndexSet(), insertions = IndexSet()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removals.insert(o)
            case .insert(let o, _, _): insertions.insert(o)
            }
        }
        rows = new
        table.beginUpdates()
        table.removeRows(at: removals, withAnimation: [])
        table.insertRows(at: insertions, withAnimation: [])
        table.endUpdates()
    }

    // MARK: Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? HostingCell) ?? {
            let c = HostingCell(); c.identifier = Self.cellID; return c
        }()
        let conv = rows[row]
        cell.set(MailRow(conv: conv, mark: model.mark(for: conv.id)))
        return cell
    }

    // MARK: HostBridge

    var rowCount: Int { rows.count }
    var viewportHeight: CGFloat { scrollView.contentView.bounds.height }
    var knownOffset: CGFloat { scrollView.contentView.bounds.origin.y }

    func scroll(toOffset y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func captureAnchor(rows: [Conversation]) -> Anchor? {
        let off = knownOffset
        let idx = table.row(at: NSPoint(x: 5, y: off + 0.5))
        guard idx >= 0, idx < self.rows.count else { return nil }
        let f = table.rect(ofRow: idx)
        return Anchor(id: self.rows[idx].id, frac: (off - f.minY) / f.height)
    }

    func restoreAnchor(_ anchor: Anchor?) {
        guard let anchor, let idx = rows.firstIndex(where: { $0.id == anchor.id }) else { return }
        let f = table.rect(ofRow: idx)
        let y = f.minY + anchor.frac * f.height
        if abs(y - knownOffset) > 0.001 { scroll(toOffset: y) }
    }

    func stamp() -> RestoreStamp? {
        guard let a = captureAnchor(rows: rows) else { return nil }
        return RestoreStamp(id: a.id, points: (a.frac * RowMetrics.height).rounded())
    }
    func groundTruthY(windowIndex: Int) -> CGFloat? { Introspect.rowY(windowIndex: windowIndex) }
    func groundTruthOffset() -> CGFloat? { knownOffset }
}
#endif
