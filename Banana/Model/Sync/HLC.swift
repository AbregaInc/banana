import Foundation

/// A hybrid logical clock (docs/design/DATA-PLATFORM.md §3, "The clock"):
/// `"<13-digit ms>.<4-hex counter>.<device id>"`, which orders correctly as text. One per field.
struct HLC: Hashable, Comparable, Sendable, CustomStringConvertible {
    let ms: Int64
    let counter: Int
    let device: String

    static let counterLimit = 0xFFFF

    init(ms: Int64, counter: Int = 0, device: String) {
        self.ms = max(0, min(ms, 9_999_999_999_999))
        self.counter = max(0, min(counter, Self.counterLimit))
        self.device = device
    }

    init?(_ text: String) {
        let parts = text.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 13, parts[1].count == 4,
              let ms = Int64(parts[0]), let counter = Int(parts[1], radix: 16) else { return nil }
        self.ms = ms
        self.counter = counter
        self.device = String(parts[2])
    }

    var text: String {
        let msText = String(ms)
        let counterText = String(counter, radix: 16)
        return String(repeating: "0", count: max(0, 13 - msText.count)) + msText + "."
            + String(repeating: "0", count: max(0, 4 - counterText.count)) + counterText + "." + device
    }

    var description: String { text }

    /// By text, as the service compares them.
    static func < (lhs: HLC, rhs: HLC) -> Bool { lhs.text < rhs.text }

    /// Time and counter only: which clock is later, whoever issued it.
    fileprivate func isBefore(_ other: HLC) -> Bool {
        (ms, counter) < (other.ms, other.counter)
    }

    /// A seed at a fixed low time (§3 seeding rule 5): the hub's settings at 1, a spoke's at 0,
    /// and an offer at 0 (`ControlChangeReporter.offered`). Any real edit beats them.
    static func fixed(_ ms: Int64, device: String) -> HLC { HLC(ms: ms, counter: 0, device: device) }
}

/// The device's clock state, kept in the mirror's meta row: what it last issued, the highest clock
/// it has seen, and its offset from the service's time.
struct HLCState: Codable, Equatable, Sendable {
    var lastIssued: String?
    var maxSeen: String?
    /// The highest clock that came from the service (pulled or acknowledged): how far down a
    /// clock that ran fast may be brought (`lower`).
    var maxFromService: String?
    /// Milliseconds to add to this device's time to get the service's.
    var offset: Int64 = 0
}

/// Issues and observes clocks for one device (§3). Not thread-safe on its own: `SpaceSync` owns it.
struct HLCClock: Sendable {
    let device: String
    private(set) var state: HLCState

    /// How far this device's clock may drift from the service's before the offset is relearned.
    static let offsetTolerance: Int64 = 30_000

    init(device: String, state: HLCState = HLCState()) {
        self.device = device
        self.state = state
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }

    /// A new clock, later than anything issued or seen: `ms = max(physical + offset, lastIssued,
    /// maxSeen)`; the counter goes up when `ms` doesn't move.
    mutating func issue(now: Date) -> HLC {
        let physical = Self.ms(now) + state.offset
        let floor = [state.lastIssued, state.maxSeen].compactMap { $0.flatMap(HLC.init) }
            .max { $0.isBefore($1) }
        var ms = physical, counter = 0
        if let floor, floor.ms >= physical {
            ms = floor.ms
            counter = floor.counter + 1
            if counter > HLC.counterLimit { ms += 1; counter = 0 }
        }
        let clock = HLC(ms: ms, counter: counter, device: device)
        state.lastIssued = clock.text
        return clock
    }

    /// A clock seeded, pulled or acknowledged: the next one issued comes after it.
    mutating func observe(_ text: String, fromService: Bool = false) {
        guard let seen = HLC(text) else { return }
        if fromService, state.maxFromService.flatMap(HLC.init).map({ $0.isBefore(seen) }) ?? true {
            state.maxFromService = seen.text
        }
        if let current = state.maxSeen.flatMap(HLC.init), !current.isBefore(seen) { return }
        state.maxSeen = seen.text
    }

    /// A clock this device made past `mostMs` (the service's now + 5 min), stamped again: its
    /// physical time (the clock less the offset in force when it was made, `offsetAtIssue`) plus
    /// the offset known now. The edit keeps its real time, told honestly, so an edit made elsewhere
    /// in between still wins. Nil for a clock within reach, or another device's. A clock still out
    /// of reach after that (it came from a fast clock's floor, not its own time) takes this
    /// device's corrected now.
    func restamped(_ text: String, offsetAtIssue: Int64, mostMs: Int64, now: Date) -> String? {
        guard let clock = HLC(text), clock.device == device, clock.ms > mostMs else { return nil }
        var ms = clock.ms - offsetAtIssue + state.offset
        if ms > mostMs { ms = Self.ms(now) + state.offset }
        return HLC(ms: ms, counter: clock.counter, device: device).text
    }

    /// The service refused clocks as more than five minutes ahead of its time (§3): this device's
    /// clock ran fast. What it last issued and has seen, where past `mostMs`, comes down to the
    /// highest clock from the service: the one place monotonicity is given up, so its next clocks
    /// are honest ones.
    mutating func lower(mostMs: Int64) {
        if let issued = state.lastIssued.flatMap(HLC.init), issued.ms > mostMs { state.lastIssued = state.maxFromService }
        if let seen = state.maxSeen.flatMap(HLC.init), seen.ms > mostMs { state.maxSeen = state.maxFromService }
    }

    /// The latest time a seed may carry: an item's own time past the service's now + 5 min would
    /// be refused, so it seeds at the corrected now instead.
    func seedMs(_ date: Date, now: Date) -> Int64 {
        let corrected = Self.ms(now) + state.offset
        let ms = Self.ms(date)
        return ms > corrected + Self.mostAhead ? corrected : ms
    }

    /// How far ahead of the service's time a clock may be (the service refuses more).
    static let mostAhead: Int64 = 5 * 60 * 1000

    /// The service's time from an answer (§3, "Offset"): `serverNow` came back in an answer to a
    /// request sent at `sent` and answered at `received` (this device's time). The offset is
    /// relearned whenever the estimate is more than 30 s off.
    mutating func learn(serverNow: Int64, sent: Date, received: Date) {
        let sentMs = Self.ms(sent), receivedMs = Self.ms(received)
        let halfTrip = max(0, receivedMs - sentMs) / 2
        let serverAtReceipt = serverNow + halfTrip
        let estimate = serverAtReceipt - receivedMs
        if abs(estimate - state.offset) > Self.offsetTolerance {
            state.offset = estimate
        }
    }
}
