import Foundation

@main struct Tests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CalendarMoveJournalTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        func intent(_ number: Int, id: UUID = UUID()) -> CalendarMoveIntent {
            CalendarMoveIntent(id: id, eventID: "provider-event-\(number)", title: "Review \(number)",
                               originalStart: Date(timeIntervalSince1970: 1_800_000_000),
                               originalEnd: Date(timeIntervalSince1970: 1_800_003_600),
                               destination: Date(timeIntervalSince1970: 1_800_007_200),
                               scope: number.isMultiple(of: 2) ? .occurrence : .series,
                               createdAt: Date(timeIntervalSince1970: Double(number)))
        }
        let journal = CalendarMoveJournal(directory: root)
        check(try await journal.pending().isEmpty, "new journal")
        let first = intent(0)
        try await journal.enqueue(first)
        try await journal.enqueue(first)
        check(try await journal.pending() == [first], "idempotent enqueue")
        let relaunched = CalendarMoveJournal(directory: root)
        check(try await relaunched.pending() == [first], "intent survives relaunch")
        do { try await relaunched.enqueue(intent(1, id: first.id)); fatalError("overwrote intent") }
        catch CalendarMoveJournal.JournalError.conflictingIntent { checks += 1 }
        check(try await relaunched.pending() == [first], "collision preserves old intent")
        let target = CalendarMoveIntent.PreparedMove(
            accountEmail: "fixture@example.invalid", calendarID: "calendar-a", eventID: "series-master",
            expectedETag: "version-1", destinationStart: first.destination,
            destinationEnd: first.destination.addingTimeInterval(3600), isAllDay: false,
            timeZoneID: "America/New_York", notifyGuests: false)
        check(target.reconcile(start: target.destinationStart, end: target.destinationEnd,
                               etag: "version-after-write") == .alreadyApplied, "lost response reconciles")
        check(target.reconcile(start: first.originalStart, end: first.originalEnd!,
                               etag: target.expectedETag) == .sendIfUnchanged, "unchanged target may send")
        check(target.reconcile(start: first.originalStart, end: first.originalEnd!,
                               etag: "another-client") == .conflict, "concurrent edit not overwritten")
        check(target.reconcile(start: first.originalStart, end: first.originalEnd!,
                               etag: nil) == .conflict, "unknown version cannot overwrite")
        check(target.reconcile(start: target.destinationStart,
                               end: target.destinationEnd.addingTimeInterval(60),
                               etag: "another-client") == .conflict, "partial match is not success")
        let prepared = try await relaunched.prepare(first.id, mutation: target)
        check(prepared.prepared == target, "prepared target attached")
        check(try await CalendarMoveJournal(directory: root).pending() == [prepared], "target survives relaunch")
        check(try await relaunched.prepare(first.id, mutation: target) == prepared, "preparation idempotent")
        let changedTarget = CalendarMoveIntent.PreparedMove(
            accountEmail: target.accountEmail, calendarID: target.calendarID, eventID: target.eventID,
            expectedETag: "version-2", destinationStart: target.destinationStart,
            destinationEnd: target.destinationEnd, isAllDay: false, timeZoneID: nil, notifyGuests: false)
        do { _ = try await relaunched.prepare(first.id, mutation: changedTarget); fatalError("replaced dispatched target") }
        catch CalendarMoveJournal.JournalError.conflictingIntent { checks += 1 }
        check(try await relaunched.pending() == [prepared], "old target retained on conflict")
        try await relaunched.acknowledge(first.id)
        try await relaunched.acknowledge(first.id)
        check(try await CalendarMoveJournal(directory: root).pending().isEmpty, "ack persists")

        // Concurrent callers serialize through the actor and never replace one another.
        let batch = (1...100).map { intent($0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for entry in batch { group.addTask { try await journal.enqueue(entry) } }
            try await group.waitForAll()
        }
        check(try await journal.pending() == batch, "concurrent enqueue and ordering")
        check(try await CalendarMoveJournal(directory: root).pending() == batch, "batch relaunch")

        // Malformed and identity-mismatched bytes remain intact, including on acknowledge.
        let file = root.appendingPathComponent("pending-calendar-moves/\(first.id.uuidString).json")
        let corrupt = Data("incomplete record".utf8)
        try corrupt.write(to: file)
        do { _ = try await journal.pending(); fatalError("ignored corruption") }
        catch CalendarMoveJournal.JournalError.malformedRecord { checks += 1 }
        do { try await journal.acknowledge(first.id); fatalError("deleted corruption") }
        catch CalendarMoveJournal.JournalError.malformedRecord { checks += 1 }
        check(try Data(contentsOf: file) == corrupt, "corrupt bytes preserved")
        try JSONEncoder().encode(intent(9)).write(to: file)
        do { try await journal.enqueue(first); fatalError("overwrote wrong identity") }
        catch CalendarMoveJournal.JournalError.malformedRecord { checks += 1 }
        try FileManager.default.removeItem(at: file)

        // An unavailable storage location must fail before any caller may start a write.
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocked)
        do { try await CalendarMoveJournal(directory: blocked).enqueue(first); fatalError("accepted unwritten intent") }
        catch { checks += 1 }

        // Record all samples. These are journal costs, not input-to-visible measurements.
        var samples: [Double] = []
        for n in 101...200 {
            let start = ContinuousClock.now
            try await journal.enqueue(intent(n))
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.attoseconds) / 1e15 + Double(duration.seconds) * 1000)
        }
        check(try await journal.pending().count == 200, "timed writes retained")
        let report: [String: Any] = ["checks": checks, "samplesMS": samples,
                                   "maxMS": samples.max()!, "scope": "atomic journal writes; not UI latency"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("Passed \(checks) checks; write max \(samples.max()!) ms")
    }
}
