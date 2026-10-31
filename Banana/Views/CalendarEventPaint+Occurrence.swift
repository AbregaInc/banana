import SwiftUI

extension CalendarEventPaint {
    /// Resolve app semantics before rendering. Rebuilding this value from the current snapshot
    /// carries edits and provider/write state into both renderers without an ID-only cache.
    init(occurrence: Occurrence, tint: Color, ribbons: [Color], startText: String,
         timeRange: String, returnCaption: String?) {
        self.init(title: occurrence.title, start: occurrence.start, startText: startText,
                  timeRange: timeRange, icon: occurrence.icon)
        isTask = occurrence.behavior == .task
        isEvent = occurrence.behavior == .event
        isMoment = occurrence.behavior == .cue || occurrence.behavior == .alarm
        hasScheduledTime = occurrence.hasScheduledTime
        completed = occurrence.completed
        skipped = occurrence.skipped
        othersDeclined = occurrence.meeting?.othersAllDeclined == true
        showsAsFree = occurrence.showsAsFree
        tentative = occurrence.meeting?.myResponse == .tentative
        needsAction = occurrence.meeting?.myResponse == .needsAction
        self.tint = tint
        self.ribbons = ribbons
        fillOpacity = EventStateStyle.fillOpacity(occurrence)
        self.returnCaption = returnCaption
        if let meeting = occurrence.meeting {
            if meeting.isVirtual { location = meeting.platform?.label ?? "Video call" }
            else if let address = meeting.address, !address.isEmpty { location = address }
        }
    }
}
