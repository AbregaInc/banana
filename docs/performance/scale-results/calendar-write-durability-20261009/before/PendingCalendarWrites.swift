import Foundation
import os

/// Events the user has created that are not yet confirmed present on a calendar.
///
/// Creating an event used to mean waiting: the write goes to EventKit or across the network to
/// Google, then a 300 ms debounce, then a full recompute that re-reads the calendar. Until all of
/// that lands, the grid looks exactly as it did before, so the event you just typed appears to
/// have gone nowhere.
///
/// Two things follow from holding the write here instead. The event can be drawn immediately, as
/// itself, marked as still syncing. And when a write fails — no network, revoked access, the app
/// killed halfway — what the user typed is not lost with it, because this is a durable record of
/// their intent rather than a transient in-flight task. That is the half worth having: optimistic
/// rendering is a nicety, and not silently dropping someone's event is not.
struct PendingCalendarWrite: Codable, Identifiable, Sendable {
    typealias State = PendingWriteState

    var id: UUID = UUID()
    var input: CalendarEventInput
    var calendarID: String?
    var createdAt: Date
    var state: State = .writing
    /// Set once the calendar has accepted the write; this is what a later read is matched against.
    var remoteID: String?
    var lastError: String?
    var attempts: Int = 0

    var isFailed: Bool { state == .failed }
}

@MainActor
final class PendingCalendarWriteStore: ObservableObject {
    @Published private(set) var pending: [PendingCalendarWrite] = []

    private let log = Logger(subsystem: "com.boris.banana", category: "pending-events")
    private let url: URL
    /// Set when the stored file could not be read AND could not be copied aside. Saving would
    /// then destroy the only copy of whatever was in there, so we refuse to save at all.
    private var mustRefuseSaves = false

    static var inFlightGraceInterval: TimeInterval { PendingCalendarWriteRules.inFlightGraceInterval }

    init(directory: URL = AppSupport.directory, now: Date = Date()) {
        self.url = directory.appendingPathComponent("pending-calendar-writes.json")
        load(now: now)
    }

    private func load(now: Date) {
        switch SnapshotLoader.load(from: url, as: [PendingCalendarWrite].self) {
        case .empty:
            pending = []
        case .loaded(let stored):
            // Anything still claiming to be in flight cannot be: this process just started, so
            // nothing is writing. Present them as failures so they can be retried rather than
            // sitting as placeholders nothing will ever resolve.
            pending = stored.map { entry in
                let recoveredState = PendingCalendarWriteRules.stateAfterRelaunch(
                    state: entry.state, createdAt: entry.createdAt, now: now)
                guard recoveredState != entry.state else { return entry }
                var recovered = entry
                recovered.state = recoveredState
                recovered.lastError = "Interrupted before it finished saving."
                return recovered
            }
            if !pending.isEmpty {
                log.notice("[pending-events] restored \(self.pending.count, privacy: .public) unconfirmed event(s)")
            }
        case .corrupt(let error, let quarantinedTo):
            pending = []
            if let quarantinedTo {
                log.error("""
                    [pending-events] could not decode \(self.url.lastPathComponent, privacy: .public) \
                    (\(String(describing: error), privacy: .public)); original preserved at \
                    \(quarantinedTo.lastPathComponent, privacy: .public)
                    """)
            } else {
                // The copy failed too, so the bytes at `url` are the only ones left. Do not write.
                mustRefuseSaves = true
                log.error("[pending-events] unreadable and could not be quarantined; refusing to save over it")
            }
        }
    }

    private func save() {
        guard !mustRefuseSaves else { return }
        do {
            try JSONEncoder().encode(pending).write(to: url, options: .atomic)
        } catch {
            log.error("[pending-events] save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lifecycle of one write

    func enqueue(input: CalendarEventInput, calendarID: String?, now: Date = Date()) -> UUID {
        let entry = PendingCalendarWrite(input: input, calendarID: calendarID, createdAt: now)
        pending.append(entry)
        save()
        log.notice("[pending-events] enqueued; count=\(self.pending.count, privacy: .public)")
        return entry.id
    }

    func markWritten(_ id: UUID, remoteID: String?) {
        update(id) {
            $0.state = .awaitingReadBack
            $0.remoteID = remoteID
            $0.lastError = nil
        }
    }

    func markFailed(_ id: UUID, error: Error) {
        log.notice("[pending-events] write failed: \(error.localizedDescription, privacy: .public)")
        update(id) {
            $0.state = .failed
            $0.lastError = error.localizedDescription
            $0.attempts += 1
        }
    }

    func markRetrying(_ id: UUID, now: Date = Date()) {
        update(id) {
            $0.state = .writing
            $0.createdAt = now
            $0.lastError = nil
        }
    }

    /// Give up on one entry. The only route by which a pending event legitimately disappears
    /// without reaching a calendar, and it is always the user's decision, never a timeout's.
    func discard(_ id: UUID) {
        pending.removeAll { $0.id == id }
        save()
    }

    func entry(_ id: UUID) -> PendingCalendarWrite? { pending.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout PendingCalendarWrite) -> Void) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        change(&pending[index])
        save()
    }

    // MARK: - Retiring confirmed writes

    /// Drop placeholders whose real event has now been read back from a calendar.
    ///
    /// Matching prefers the identifier the calendar handed back. The fallback compares title and
    /// start instant, for providers that do not return a usable id — deliberately strict, because
    /// retiring a placeholder that has NOT actually arrived would make a lost event look like a
    /// saved one, which is the failure this whole type exists to prevent.
    ///
    /// Takes plain identifiers rather than occurrences so the rule is pure and can be tested
    /// without the timeline's dependency graph; the occurrence-shaped wrapper lives alongside it.
    func reconcile(confirmedRemoteIDs: Set<String>, confirmedSignatures: Set<String>,
                   now: Date = Date()) {
        guard !pending.isEmpty else { return }
        let before = pending.count
        // Drop placeholders that have waited too long to be confirmed. The write was accepted, so
        // there is nothing to recover; what is left is a block nobody can delete because it is not
        // an event. Logged because it means a read-back never matched, which is worth knowing.
        pending.removeAll { entry in
            let expired = PendingCalendarWriteRules.hasOutlivedReadBack(
                state: entry.state, createdAt: entry.createdAt, now: now)
            if expired {
                log.notice("[pending-events] giving up on \(entry.input.title, privacy: .public): never seen on a calendar read")
            }
            return expired
        }
        pending.removeAll { entry in
            PendingCalendarWriteRules.shouldRetire(
                state: entry.state,
                remoteID: entry.remoteID,
                signature: Self.signature(title: entry.input.title, start: entry.input.start),
                confirmedRemoteIDs: confirmedRemoteIDs,
                confirmedSignatures: confirmedSignatures)
        }
        if pending.count != before { save() }
    }

    static func signature(title: String, start: Date) -> String {
        PendingCalendarWriteRules.signature(title: title, start: start)
    }
}
