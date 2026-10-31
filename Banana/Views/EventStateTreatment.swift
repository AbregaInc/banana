import SwiftUI

/// How an event's invitation state reads on the grid, at any block size and without a badge:
///
/// - **Tentative** ("maybe"): diagonal stripes over the usual fill.
/// - **Not answered yet**: an outline with almost no fill — present, but not yet committed.
/// - **Everyone else declined**: a warning glyph before the title; it is probably off.
/// - **On several calendars**: a small dot per calendar at the leading edge, instead of the
///   duplicate copies that used to stack side by side. One calendar: its fill says which, and
///   nothing more (no stripes: DESIGN-SYSTEM.md, the standard).
///
/// Free events keep their own dashed treatment (`freeBlockTreatment`); declined events never
/// reach the timeline.
enum EventStateStyle {
    static func fillOpacity(_ occurrence: Occurrence) -> Double {
        if occurrence.showsAsFree { return DS.Event.quietFill }
        if occurrence.meeting?.myResponse == .needsAction { return DS.Event.quietFill }
        return DS.Event.fill
    }

    /// The block's own calendar first, then each merged calendar that has a colour.
    static func ribbonColors(_ occurrence: Occurrence, tint: Color, colors: [String: String]) -> [Color] {
        guard occurrence.behavior == .event, let others = occurrence.meeting?.alsoOnCalendarIDs,
              !others.isEmpty else { return [tint] }
        return [tint] + others.compactMap { colors[$0].map(calendarTint) }
    }

    /// Extra leading room the calendars' dots take: none for one calendar.
    static func ribbonInset(_ ribbons: [Color]) -> CGFloat { ribbons.count > 1 ? DS.Event.calendarDot + DS.Space.xs : 0 }
}

extension View {
    func eventStateTreatment(_ meeting: MeetingInfo?, tint: Color, cornerRadius: CGFloat = 4) -> some View {
        eventReplyTreatment(tentative: meeting?.myResponse == .tentative,
                            needsAction: meeting?.myResponse == .needsAction,
                            tint: tint, cornerRadius: cornerRadius)
    }
}
