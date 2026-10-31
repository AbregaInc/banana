import CoreGraphics

/// How tall an event is drawn on a calendar grid.
///
/// Its own minutes, stretched to a readable minimum when it's shorter — but never down over the
/// next block beneath it. A 15-minute blocker straight before a 90-minute swim was stretched to the
/// minimum when zoomed out and covered the top of the swim, while every other event stayed end to
/// end. Pure, so the rule is tested (`CalendarBlockHeightTests`).
enum CalendarBlockHeight {
    /// - Parameters:
    ///   - natural: the event's own height at this zoom (its minutes).
    ///   - minimum: the height a title needs.
    ///   - roomBelow: from the top of this block to the top of the next block beneath it, nil when
    ///     nothing is beneath it.
    static func height(natural: CGFloat, minimum: CGFloat, roomBelow: CGFloat?) -> CGFloat {
        let readable = max(natural, minimum)
        guard let roomBelow else { return readable }
        // Never shorter than its own minutes, even if something overlaps it in time.
        return max(natural, min(readable, roomBelow))
    }
}
