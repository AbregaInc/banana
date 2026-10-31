import Foundation

/// How an unconfirmed write is drawn, and how a timeline read retires it.
///
/// Split from `PendingCalendarWrites.swift` so that file — the one holding the only copy of an
/// event the user typed — stays free of the timeline's dependency graph and can be tested on its
/// own, the way every other store in this target is.

extension PendingCalendarWrite {
    /// Draw this the way the real event will be drawn, so the grid does not shift when the
    /// placeholder is retired. Same shape, same read-only treatment; only `syncState` differs, and
    /// that is what the badge keys off.
    var optimisticOccurrence: Occurrence {
        Occurrence(
            id: "pending:\(id.uuidString)",
            seriesID: nil, slotID: nil,
            source: .external, behavior: .event,
            schedule: OccurrenceSchedule(mode: .fixed, moveable: false),
            // Never written back and never armed: this is a picture of a write in progress, not a
            // second source of truth that something downstream should act on.
            writePolicy: .none,
            title: input.title,
            icon: "calendar",
            tint: .gray,
            start: input.start,
            end: input.isAllDay ? input.end : input.end,
            hasScheduledTime: !input.isAllDay,
            // Carries a MeetingInfo even though no calendar holds it yet. Today and Tomorrow build
            // their lists from MeetingInfo rather than from occurrences, so an event without one
            // is silently dropped there — which is why a newly created event appeared at once on
            // the week grid and nowhere else. `eventID` stays nil: there is nothing to open, and
            // every opener already treats a missing id as nothing to do.
            meeting: MeetingInfo(
                start: input.start,
                end: input.end,
                coordinate: nil,
                address: input.location,
                isVirtual: false,
                title: input.title,
                eventID: nil,
                // The destination calendar, so the placeholder is drawn in the colour the real
                // event will have. Without it the colour lookup falls back to grey and every new
                // event visibly changed colour a second after it was created.
                calendarID: calendarID),
            syncState: state == .failed ? .failed : .syncing,
            pendingWriteID: id)
    }
}

extension PendingCalendarWriteStore {
    /// Placeholders for everything not yet confirmed on a calendar.
    var optimisticOccurrences: [Occurrence] { pending.map(\.optimisticOccurrence) }
}

extension PendingCalendarWriteStore {
    /// Retire placeholders confirmed by a timeline read.
    func reconcile(against occurrences: [Occurrence]) {
        let ids = Set(occurrences.compactMap(\.externalEventID))
        let signatures = Set(occurrences.filter { $0.source == .external }
            .map { PendingCalendarWriteStore.signature(title: $0.title, start: $0.start) })
        reconcile(confirmedRemoteIDs: ids, confirmedSignatures: signatures)
    }
}
