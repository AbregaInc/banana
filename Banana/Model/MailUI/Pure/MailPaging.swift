#if !BANANA_PUBLIC
import Foundation

/// Continuous scrolling (MAIL-ENGINE 4.4, 9.4): when a list asks for more, and what its last
/// row says. Pure, so every threshold is a test that hands it numbers.
///
/// A list is a **window**: the rows from a boundary (the newest mail, or an older key) down,
/// at most `cap` of them. Scrolling toward its end asks for more — a step more rows while the
/// window is below the cap, then the window slides older: the rows far above the screen are
/// let go and as many older ones come in below. Scrolling back toward the top of a slid window
/// slides it newer the same way. Where the device holds no more, the source's edge is asked
/// (`askGmail`), once per answer. Each request starts while about one screen of rows is still
/// to come, so nobody reaches a wall or a button.
enum MailPaging {

    /// The least lead, in rows, whatever the screen: a phone in landscape shows few rows, and a
    /// fling covers many. It is also the lead for the keyboard, which has no screen to count.
    static let minimumLead = 30

    /// How many rows before the end a request starts: one screen, and never less than
    /// `minimumLead`.
    static func lead(screenRows: Int) -> Int { max(screenRows, minimumLead) }

    /// Where the source's edge stands for this window.
    enum Edge: Equatable, Sendable {
        /// Not asked since the last answer.
        case idle
        /// Asked, and no answer yet.
        case asked
        /// The last answer was a failure: only Retry asks again.
        case failed
    }

    struct State: Equatable, Sendable {
        /// The first and last rows on screen, as indices into the window. When the keyboard moved
        /// the cursor last, both are the cursor's row.
        var firstVisible: Int
        var lastVisible: Int
        /// How many rows one screen shows; 0 when not known (a keyboard, a test).
        var screenRows: Int
        /// Rows the window holds.
        var loaded: Int
        /// Rows the newest reading holds, and the limit asked for.
        var reading: Int
        var limit: Int
        /// A request has been made and its reading has not come.
        var inFlight: Bool
        /// The source has more beyond the window's last row: on the device or at its edge.
        var hasMore: Bool
        /// The window starts below the newest mail.
        var isSlid: Bool
        var edge: Edge
        var cap: Int = MailTuning.listCap
        var step: Int = MailTuning.listStep
    }

    enum Request: Equatable, Sendable {
        case none
        /// Observe the same window with a larger limit.
        case grow(limit: Int)
        /// Let go of the rows above this index and fill the window below.
        case slideOlder(keepingFrom: Int)
        /// Bring back the rows above the window.
        case slideNewer
        /// The device has given all it holds here; ask the source's edge for more.
        case askEdge
    }

    static func decide(_ state: State) -> Request {
        guard !state.inFlight, state.loaded > 0 else { return .none }
        let lead = lead(screenRows: state.screenRows)
        if state.isSlid, state.firstVisible <= lead { return .slideNewer }
        let left = state.loaded - 1 - state.lastVisible
        guard left <= lead, state.hasMore else { return .none }
        // A reading shorter than its limit is everything the device holds below this boundary:
        // the rest is at the edge.
        if state.reading < state.limit { return state.edge == .idle ? .askEdge : .none }
        if state.limit < state.cap { return .grow(limit: min(state.cap, state.limit + state.step)) }
        // Keep half a window above the screen, so a turn back up finds rows there and the
        // window does not slide back and forth around one place.
        let keep = state.firstVisible - state.cap / 2
        return keep > 0 ? .slideOlder(keepingFrom: keep) : .none
    }

    /// What the row after the last one says.
    enum Status: Equatable, Sendable {
        /// Nothing: no rows, a place of his own drafts, or a list that never needed a second page.
        case hidden
        case loading
        /// The end of the list, once he has scrolled through pages to reach it.
        case end
        /// The last request failed: Retry.
        case failed
    }

    static func status(loaded: Int, hasMore: Bool, failed: Bool, hasPaged: Bool) -> Status {
        guard loaded > 0 else { return .hidden }
        if failed { return .failed }
        if hasMore { return .loading }
        return hasPaged ? .end : .hidden
    }
}

#endif
