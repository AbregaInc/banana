import XCTest

@MainActor
final class PendingCalendarWriteStoreTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private var input: CalendarEventInput {
        CalendarEventInput(title: "Durable draft", start: now, end: now.addingTimeInterval(1800),
            isAllDay: false, location: "Test room", notes: "Keep this draft", url: nil,
            availability: .busy, alertMinutesBefore: 10)
    }

    func testFailedLocalEnqueueDoesNotAcknowledgeOrPublishIntent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A regular file cannot contain a pending-write file. This faults the actual disk write.
        let notDirectory = root.appendingPathComponent("not-a-directory")
        try Data("preserve me".utf8).write(to: notDirectory)
        let store = PendingCalendarWriteStore(directory: notDirectory, now: now)
        XCTAssertThrowsError(try store.enqueue(input: input, calendarID: "test-calendar", now: now))
        XCTAssertTrue(store.pending.isEmpty, "A nondurable intent must remain in the composer")
        XCTAssertEqual(try Data(contentsOf: notDirectory), Data("preserve me".utf8))
    }

    func testImmediateRelaunchMakesInterruptedWriteRetryable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = PendingCalendarWriteStore(directory: root, now: now)
        let id = try first.enqueue(input: input, calendarID: "test-calendar", now: now)
        let relaunched = PendingCalendarWriteStore(directory: root, now: now.addingTimeInterval(1))
        let restored = try XCTUnwrap(relaunched.entry(id))
        XCTAssertEqual(restored.state, .failed)
        XCTAssertEqual(restored.input.title, input.title)
        XCTAssertEqual(restored.input.notes, input.notes)
        XCTAssertEqual(restored.calendarID, "test-calendar")
    }

    func testEnqueueComponentCostAtRetainedBacklogSizes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var results: [[String: Any]] = []
        for count in [0, 10, 100, 1000] {
            let seed = (0..<count).map { _ in
                PendingCalendarWrite(input: input, calendarID: "test-calendar", createdAt: now,
                                     state: .failed, lastError: "Offline")
            }
            let data = try JSONEncoder().encode(seed)
            var samples: [Double] = []
            for trial in 0..<7 {
                let directory = root.appendingPathComponent("\(count)-\(trial)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("pending-calendar-writes.json")
                try data.write(to: file, options: .atomic)
                let store = PendingCalendarWriteStore(directory: directory, now: now)
                let began = DispatchTime.now().uptimeNanoseconds
                let id = try store.enqueue(input: input, calendarID: "test-calendar", now: now)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
                let disk = try JSONDecoder().decode([PendingCalendarWrite].self, from: Data(contentsOf: file))
                XCTAssertEqual(disk.count, count + 1)
                XCTAssertTrue(disk.contains { $0.id == id && $0.input.notes == input.notes })
            }
            results.append(["pendingCount": count, "samplesMS": samples,
                            "medianMS": samples.sorted()[3], "maxMS": samples.max()!])
        }
        let json = try JSONSerialization.data(withJSONObject: [
            "scope": "Synchronous durable enqueue component; not input-to-visible latency",
            "cases": results], options: [.sortedKeys, .prettyPrinted])
        let evidence = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        evidence.name = "pending-calendar-enqueue-component"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
