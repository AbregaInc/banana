import SwiftUI
import Combine

// MARK: - Metrics

enum RowMetrics {
    #if os(macOS)
    static let height: CGFloat = 32      // single-line Mac row
    #else
    static let height: CGFloat = 64      // compact iPhone row
    #endif
}

// MARK: - Counters (the app's RenderStats, as plain static counters)

/// `RenderStats` in Banana is a lock-guarded dictionary incremented at the top of suspect bodies.
/// These are the same idea with the four numbers this prototype needs. Main thread only.
enum Counters {
    /// Evaluations of the view that owns the list (SwiftUI hosts: the host view's `body`; native
    /// hosts: the representable's `body` and every `updateUIView` / `updateNSView`).
    static var container = 0
    static var update = 0
    /// Row view bodies (`MailRow.body`), and the cursor/probe leaf (`MarkBackground.body`).
    static var rowBody = 0
    static var markBody = 0
    static var perRow: [Int: Int] = [:]

    struct Snap: Codable {
        var container: Int
        var update: Int
        var rowBody: Int
        var markBody: Int
        var distinctRows: Int
        var maxPerRow: Int
    }

    static func noteRow(_ id: Int) {
        rowBody += 1
        perRow[id, default: 0] += 1
    }

    static func snap() -> Snap {
        Snap(container: container, update: update, rowBody: rowBody, markBody: markBody,
             distinctRows: perRow.count, maxPerRow: perRow.values.max() ?? 0)
    }
}

extension Counters.Snap {
    func minus(_ o: Counters.Snap) -> [String: Int] {
        ["container": container - o.container, "update": update - o.update,
         "rowBody": rowBody - o.rowBody, "markBody": markBody - o.markBody]
    }
}

// MARK: - The marked row's SwiftUI-reported frame

/// What the marked row says about where it is: written by an `onGeometryChange` that exists only
/// on the one row whose mark has `probed` set. Read by the display link, never by a view.
enum Probe {
    static var id: Int?
    static var y: CGFloat?
    static func report(_ id: Int, _ y: CGFloat) { self.id = id; self.y = y }
    static func gone(_ id: Int) { if self.id == id { self.id = nil; self.y = nil } }
    static func reset() { id = nil; y = nil }
    static func y(for id: Int?) -> CGFloat? { (id != nil && self.id == id) ? y : nil }
}

// MARK: - Swipe log (UI test only)

final class SwipeLog: ObservableObject {
    static let shared = SwipeLog()
    @Published var leading = 0
    @Published var trailing = 0
    @Published var last = ""
    func record(leading isLeading: Bool, _ action: String, row: Int) {
        if isLeading { leading += 1 } else { trailing += 1 }
        last = "\(action)#\(row)"
    }
}

// MARK: - The leaf observable

/// One small observable per row: the design's `MailRowMark`. `hasCursor` is the keyboard cursor;
/// `probed` marks the one row the measurement follows. Moving the cursor flips two of these and
/// nothing the list reads.
@MainActor
final class RowMark: ObservableObject {
    @Published var hasCursor = false
    @Published var probed = false
}

// MARK: - The model (lives outside the view tree)

/// What is stamped when the view tree is about to be discarded: the key of the first row on screen and
/// the whole points scrolled into it (the design's "first key, whole-point offset"). Not an absolute
/// offset: a collection view's list layout estimates the height of rows it has not drawn, so an absolute
/// offset means different rows before and after the tree is rebuilt.
struct RestoreStamp: Equatable {
    var id: Int
    var points: CGFloat
}

struct Anchor {
    var id: Int
    /// How far into the row's height the viewport's top edge is, 0 ..< 1.
    var frac: CGFloat
}

@MainActor
final class InboxModel: ObservableObject {
    static let windowSize = 400
    /// The window re-centres when the cursor is this close to either edge...
    static let recentreMargin = 100
    /// ...so that the cursor sits this far from the window's top.
    static let recentreTo = 200

    /// The only thing a list host observes.
    @Published private(set) var rows: [Conversation] = []

    /// The whole mailbox, newest first, as ids. Sorted ascending by id (new mail is negative).
    private(set) var mailbox: [Int]
    private(set) var windowStart = 0
    private(set) var cursorGlobal = 0
    private(set) var probedID: Int?
    private var marks: [Int: RowMark] = [:]
    private(set) var slides = 0

    weak var bridge: HostBridge?
    /// State that must survive the view tree being discarded (the design's `MailSession`).
    var restore: RestoreStamp?

    init() {
        mailbox = Array(0..<Fixture.count)
        rows = windowRows(start: 0)
        mark(for: 0).hasCursor = true
    }

    func mark(for id: Int) -> RowMark {
        if let m = marks[id] { return m }
        let m = RowMark()
        marks[id] = m
        return m
    }

    private func windowRows(start: Int) -> [Conversation] {
        let end = min(start + Self.windowSize, mailbox.count)
        return mailbox[start..<end].map(Fixture.conversation)
    }

    /// Position of an id in the whole mailbox (binary search; ids ascend).
    func globalIndex(ofID id: Int) -> Int? {
        var lo = 0, hi = mailbox.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if mailbox[mid] == id { return mid }
            if mailbox[mid] < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// The row-based offset (rows of the fixed height) a stamp stands for in the current window.
    func virtualOffset(of stamp: RestoreStamp) -> CGFloat? {
        windowIndex(ofID: stamp.id).map { CGFloat($0) * RowMetrics.height + stamp.points }
    }

    func windowIndex(ofID id: Int) -> Int? {
        guard let g = globalIndex(ofID: id) else { return nil }
        let w = g - windowStart
        return (0..<rows.count).contains(w) ? w : nil
    }

    var cursorID: Int { mailbox[cursorGlobal] }
    var cursorWindowIndex: Int { cursorGlobal - windowStart }

    // MARK: Publishing a window change

    private func publish(start: Int) {
        let anchor = bridge?.captureAnchor(rows: rows)
        windowStart = start
        rows = windowRows(start: start)          // @Published: native hosts apply here, synchronously
        bridge?.restoreAnchor(anchor)
    }

    // MARK: Inputs

    /// Resets the window, cursor, probe and marks to the start of the mailbox.
    func reset() {
        for m in marks.values { m.hasCursor = false; m.probed = false }
        probedID = nil
        cursorGlobal = 0
        mark(for: mailbox[0]).hasCursor = true
        publish(start: 0)
    }

    /// New mail: `n` rows at the top of the mailbox. Only changes the visible rows when the window
    /// is at the top of the mailbox (T9: otherwise arrivals wait outside the window, in the chip).
    func prepend(_ n: Int) {
        let minID = mailbox[0]
        mailbox.insert(contentsOf: Array((minID - n)..<minID), at: 0)
        cursorGlobal += n
        if windowStart == 0 { publish(start: 0) } else { windowStart += n }
    }

    /// Moves the cursor `d` rows. Returns the number of rows the window's start moved by (0 when it
    /// did not re-centre).
    @discardableResult
    func moveCursor(by d: Int) -> Int {
        let g = min(max(cursorGlobal + d, 0), mailbox.count - 1)
        guard g != cursorGlobal else { return 0 }
        let old = mark(for: mailbox[cursorGlobal]), new = mark(for: mailbox[g])
        old.hasCursor = false
        new.hasCursor = true
        if probedID != nil {                      // the cursor row is the probed row
            old.probed = false
            new.probed = true
            probedID = mailbox[g]
        }
        cursorGlobal = g
        return recentreIfNeeded()
    }

    private func recentreIfNeeded() -> Int {
        let idx = cursorGlobal - windowStart
        var newStart = windowStart
        if idx > Self.windowSize - Self.recentreMargin, windowStart + Self.windowSize < mailbox.count {
            newStart = min(cursorGlobal - Self.recentreTo, mailbox.count - Self.windowSize)
        } else if idx < Self.recentreMargin, windowStart > 0 {
            newStart = max(0, cursorGlobal - Self.recentreTo)
        }
        guard newStart != windowStart else { return 0 }
        let shift = newStart - windowStart
        slides += 1
        publish(start: newStart)
        return shift
    }

    func setProbe(id: Int?) {
        if let p = probedID { mark(for: p).probed = false }
        probedID = id
        if let id { mark(for: id).probed = true }
        Probe.reset()
    }
}

// MARK: - What a host has to offer the driver

/// The seam between the scenarios and a list host. Every host implements it with the best honest
/// means it has; the scenarios never know which host they are driving.
@MainActor
protocol HostBridge: AnyObject {
    var viewportHeight: CGFloat { get }
    /// Where the host believes the content is scrolled to, in points from the top of the first row.
    /// SwiftUI hosts track what they last asked for (a SwiftUI scroll view cannot be read back
    /// synchronously); native hosts read the scroll view.
    var knownOffset: CGFloat { get }
    /// Absolute, non-animated, immediate as the host can make it.
    func scroll(toOffset y: CGFloat)
    /// Taken immediately before the model publishes a new window, and given back immediately after.
    func captureAnchor(rows: [Conversation]) -> Anchor?
    func restoreAnchor(_ anchor: Anchor?)
    /// Stamped when the view tree is about to be discarded.
    func stamp() -> RestoreStamp?
    /// UIKit/AppKit's own answer to "where on screen is the row at this window index" (window
    /// coordinates, y down, nil if not realised). A cross-check on the SwiftUI probe.
    func groundTruthY(windowIndex: Int) -> CGFloat?
    /// The real underlying scroll view's offset from the top of the first row, if there is one to read.
    func groundTruthOffset() -> CGFloat?
    var rowCount: Int { get }
    func debugString() -> String
    /// True when the host can only be asked to put a whole row at the top (an id binding).
    var wholeRowScroll: Bool { get }
    /// The scroll position was changed by something other than this host's own API (a drag).
    func handScrolled()
    func reveal(windowIndex: Int, direction: Int) -> CGFloat
}

extension HostBridge {
    func debugString() -> String { "" }
    var wholeRowScroll: Bool { false }
    func handScrolled() {}

    /// T4: show the cursor row whole, with one more row beyond it in the direction of travel.
    /// Returns the points the content moved by (positive = scrolled toward later rows).
    func reveal(windowIndex: Int, direction: Int) -> CGFloat {
        let cur = knownOffset
        guard let t = Reveal.target(current: cur, viewport: viewportHeight, rowCount: rowCount,
                                    windowIndex: windowIndex, direction: direction, wholeRows: wholeRowScroll) else { return 0 }
        scroll(toOffset: t)
        return t - cur
    }
}

enum Reveal {
    /// The offset that shows the cursor row whole plus one row beyond it, or nil when it already does.
    static func target(current cur: CGFloat, viewport: CGFloat, rowCount: Int, windowIndex: Int,
                       direction: Int, wholeRows: Bool) -> CGFloat? {
        let h = RowMetrics.height
        let total = CGFloat(rowCount) * h
        let top = CGFloat(windowIndex) * h, bottom = top + h
        var t = cur
        if direction >= 0 {
            t = max(t, min(bottom + h, total) - viewport)
            t = min(t, top)
        } else {
            t = min(t, max(top - h, 0))
            t = max(t, bottom - viewport)
        }
        if wholeRows, t > cur { t = (t / h).rounded(.up) * h }
        t = min(max(t, 0), max(0, total - viewport))
        return abs(t - cur) > 0.001 ? t : nil
    }
}
