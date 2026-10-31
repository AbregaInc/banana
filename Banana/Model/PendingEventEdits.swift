import Foundation

/// An edit sent to Google and not yet read back: what the event should look like now.
struct PendingEventEdit: Equatable {
    /// The event's info id (`Occurrence.externalEventID`).
    let eventID: String
    var title: String
    var start: Date
    var end: Date
    var location: String
}

/// Edits drawn before Google confirms them.
///
/// Saving an event used to mean a spinner in the editor until the write and a re-read were done;
/// now the editor closes at once and the event is drawn as edited, marked as still saving, until
/// the next read shows the real thing (or the save fails and it goes back). In memory only: an
/// edit that never lands leaves the event as it is in Google — the safe side.
@MainActor
final class PendingEventEditStore {
    private(set) var edits: [String: PendingEventEdit] = [:]

    func begin(_ edit: PendingEventEdit) { edits[edit.eventID] = edit }
    func end(_ eventID: String) { edits[eventID] = nil }

    /// Identity of the set, so a change in it republishes the timeline.
    var signature: String {
        edits.keys.sorted().joined(separator: ",")
    }

    func applied(to occurrences: [Occurrence]) -> [Occurrence] {
        Self.apply(edits, to: occurrences)
    }

    static func apply(_ edits: [String: PendingEventEdit], to occurrences: [Occurrence]) -> [Occurrence] {
        guard !edits.isEmpty else { return occurrences }
        return occurrences.map { occurrence in
            guard let id = occurrence.externalEventID, let edit = edits[id] else { return occurrence }
            var edited = occurrence
            edited.title = edit.title
            edited.start = edit.start
            edited.end = edit.end
            edited.syncState = .syncing
            if var meeting = edited.meeting {
                meeting.title = edit.title
                meeting.start = edit.start
                meeting.end = edit.end
                meeting.address = edit.location.isEmpty ? nil : edit.location
                edited.meeting = meeting
            }
            return edited
        }
    }
}
