import Foundation

/// When an unconfirmed event may stop being shown, and what an interrupted write becomes.
///
/// Split from the store for the reason the other policy files in this target are: these two rules
/// decide whether an event the user typed survives or vanishes, they are pure functions of their
/// inputs, and the store around them drags in EventKit and the whole timeline graph. Kept here,
/// they are tested directly.
enum PendingWriteState: String, Codable, Sendable {
    /// The write is in flight right now.
    case writing
    /// The calendar accepted it; waiting for it to come back on a read so the placeholder can be
    /// retired in favour of the real thing.
    case awaitingReadBack
    /// It did not get written. Kept, visible, and retryable — never discarded on its own.
    case failed
}

enum PendingCalendarWriteRules {
    /// How long a placeholder may wait to be confirmed by a calendar read before it is dropped.
    ///
    /// A write the calendar ACCEPTED still has to be seen coming back before the placeholder can
    /// retire in favour of the real event. Usually that is the next recompute, seconds later. If
    /// it never happens — the event was deleted before the first read, or its identity came back
    /// in a shape reconciliation cannot match — the placeholder used to wait forever, and a
    /// forever-waiting placeholder is drawn on the calendar as a block that cannot be deleted,
    /// because it is not an event at all. Giving up is right: the write succeeded, so the worst
    /// case is that a real event is briefly drawn by whatever read finds it.
    static let readBackGraceInterval: TimeInterval = 5 * 60

    /// Whether a placeholder has waited too long to be confirmed and should simply be dropped.
    static func hasOutlivedReadBack(state: PendingWriteState,
                                    createdAt: Date,
                                    now: Date) -> Bool {
        state == .awaitingReadBack && now.timeIntervalSince(createdAt) > readBackGraceInterval
    }

    /// Title and start to the minute. Seconds are dropped because a provider may normalise them,
    /// and a minute is finer than any two events a person creates by hand at the same time.
    static func signature(title: String, start: Date) -> String {
        let minute = (start.timeIntervalSinceReferenceDate / 60).rounded(.down)
        return "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(minute)"
    }

    /// Whether a placeholder has been confirmed by a calendar read and may stop being drawn.
    ///
    /// Only a write the calendar has already accepted is eligible. One still in flight that
    /// happens to resemble an existing event is not evidence that THIS one landed, and a failed
    /// one is never retired by a read at all — the whole point of keeping it is that nothing on a
    /// calendar corresponds to it.
    ///
    /// The identifier is preferred; the title-and-minute signature is the fallback for providers
    /// that return no usable id. Both are deliberately strict: retiring a placeholder whose event
    /// never arrived turns a lost event into one that merely looks saved, which is the single
    /// failure this design exists to prevent.
    static func shouldRetire(state: PendingWriteState,
                             remoteID: String?,
                             signature: String,
                             confirmedRemoteIDs: Set<String>,
                             confirmedSignatures: Set<String>) -> Bool {
        guard state == .awaitingReadBack else { return false }
        if let remoteID { return confirmedRemoteIDs.contains(remoteID) }
        return confirmedSignatures.contains(signature)
    }

    /// What a stored entry should become when the app starts again.
    ///
    /// Nothing can still be writing in a process that has only just launched, so an entry claiming
    /// to be in flight is the residue of a kill. Returning it as a failure is what makes the
    /// event recoverable: it becomes something with a retry button rather than a placeholder that
    /// spins forever. Age cannot prove an operation is alive in this newly constructed store.
    static func stateAfterRelaunch(state: PendingWriteState) -> PendingWriteState {
        state == .writing ? .failed : state
    }
}
