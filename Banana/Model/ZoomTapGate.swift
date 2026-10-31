import Foundation

/// Taps on the calendar grids that belong to a pinch, not to the event under the finger.
///
/// The pinch shares its touches with each event's button, so a zoom that began on an event —
/// and whose finger lifted over it — opened the event, or for a task ticked it off. Taps are
/// refused from the moment a pinch begins until its last finger is up and a moment has passed:
/// the second finger often lingers and lifts over an event after the pinch itself has ended.
/// Pure, so the timing is tested (`ZoomTapGateTests`).
struct ZoomTapGate {
    /// How long after the last finger lifts before a tap counts again.
    static let settle: TimeInterval = 0.4
    /// A gate whose lift was never reported opens on its own this long after the pinch last moved.
    static let limit: TimeInterval = 3

    private var zooming = false
    private var lastChange: Date = .distantPast
    private var liftedAt: Date?

    mutating func pinchChanged(at now: Date = Date()) {
        zooming = true
        lastChange = now
    }

    mutating func fingersLifted(at now: Date = Date()) {
        guard zooming else { return }
        zooming = false
        liftedAt = now
    }

    func allowsTap(at now: Date = Date()) -> Bool {
        if zooming { return now.timeIntervalSince(lastChange) > Self.limit }
        guard let liftedAt else { return true }
        return now.timeIntervalSince(liftedAt) >= Self.settle
    }
}

/// The one gate the Day and Week grids share.
@MainActor
enum GridZoom {
    static var gate = ZoomTapGate()
}
