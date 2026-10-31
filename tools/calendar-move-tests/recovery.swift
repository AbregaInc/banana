import Foundation

@main struct RecoveryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarMoveRecoveryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        enum Failure: Error { case offline }
        let intent = CalendarMoveIntent(eventID: "fixture", title: "Review", originalStart: Date(timeIntervalSince1970: 1000),
                                        originalEnd: Date(timeIntervalSince1970: 2000), destination: Date(timeIntervalSince1970: 3000),
                                        scope: .series)
        let target = CalendarMoveIntent.PreparedMove(accountEmail: "fixture@example.invalid", calendarID: "calendar",
            eventID: "master", expectedETag: "v1", destinationStart: intent.destination,
            destinationEnd: intent.destination.addingTimeInterval(1000), isAllDay: false, timeZoneID: "UTC", notifyGuests: false)
        let journal = CalendarMoveJournal(directory: root)
        let store = CalendarMoveRecoveryStore(directory: root)
        var prepared = 0, applied = 0
        let offline = await store.perform(intent, prepare: { value in
            check(try await journal.pending() == [value], "intent durable before provider read")
            prepared += 1
            throw Failure.offline
        }, apply: { _ in applied += 1 })
        check(offline != nil && prepared == 1 && applied == 0, "offline preparation not dispatched")
        check(store.pending == [intent] && store.unsaved.isEmpty, "offline intent retained")
        let relaunched = CalendarMoveRecoveryStore(directory: root)
        try await relaunched.load()
        check(relaunched.pending == [intent], "relaunch restores failed move")
        let lost = await relaunched.perform(intent, prepare: { _ in prepared += 1; return target }, apply: { value in
            let disk = try await journal.pending()
            check(disk.first?.prepared == value, "exact target durable before mutation")
            applied += 1
            throw Failure.offline // Provider may have accepted it before connection loss.
        })
        check(lost != nil && applied == 1, "uncertain outcome retained")
        let again = CalendarMoveRecoveryStore(directory: root)
        try await again.load()
        let saved = again.pending[0]
        check(saved.prepared == target, "prepared target survives process boundary")
        let completed = await again.perform(saved, prepare: { _ in fatalError("reprepared a dispatched target") }, apply: { value in
            check(value.reconcile(start: target.destinationStart, end: target.destinationEnd,
                                  etag: "v2") == .alreadyApplied, "lost response needs no second write")
            applied += 1
        })
        check(completed == nil && again.pending.isEmpty, "successful reconciliation retires intent")
        check(try await journal.pending().isEmpty, "acknowledgement durable")

        let blocked = root.appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        let unwritable = CalendarMoveRecoveryStore(directory: blocked)
        let localFailure = await unwritable.perform(intent, prepare: { _ in fatalError("provider called before local persistence") },
                                                   apply: { _ in fatalError("provider called before local persistence") })
        check(localFailure != nil && unwritable.pending == [intent], "local failure retains draft")
        check(unwritable.unsaved.contains(intent.id), "local failure labelled unsaved")

        // Retry cannot queue a second contradictory intent for the same event.
        _ = await again.perform(intent, prepare: { _ in throw Failure.offline }, apply: { _ in })
        let other = CalendarMoveIntent(eventID: intent.eventID, title: intent.title, originalStart: intent.originalStart,
            originalEnd: intent.originalEnd, destination: intent.destination.addingTimeInterval(60), scope: .series)
        let duplicate = await again.perform(other, prepare: { _ in fatalError("conflicting move sent") }, apply: { _ in })
        check(duplicate != nil && again.pending == [intent], "pending event blocks conflicting move")
        await again.discard(intent.id)
        let remaining = try await journal.pending()
        check(again.pending.isEmpty && remaining.isEmpty, "explicit discard durable")

        let report: [String: Any] = ["checks": checks, "providerPrepareCalls": prepared, "providerApplyCalls": applied,
                                   "scope": "injected provider lifecycle; no real account/network/UI"]
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Passed \(checks) recovery checks")
    }
}
