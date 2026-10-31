import EventKit
import XCTest

@MainActor
final class NoteReminderWriterTests: XCTestCase {
    func testAChangedDeviceIdentifierFindsTheSameCompletedReminder() async {
        let store = EKEventStore(), marker = URL(string: "banana://note/\(UUID())")!
        let existing = EKReminder(eventStore: store)
        existing.url = marker; existing.isCompleted = true
        var creates = 0, saves = 0
        let result = await NoteReminderWriter.write(previousID: "other-device-id", marker: marker,
            title: "Updated note", notes: "Body", stillCurrent: { true }, lookup: { _ in nil },
            fetch: { [existing] }, create: { creates += 1; return EKReminder(eventStore: store) },
            save: { item in
                XCTAssertTrue(item === existing)
                XCTAssertTrue(item.isCompleted, "an edit must not resurrect a completed reminder")
                saves += 1; return "this-device-id"
            })
        XCTAssertEqual(result, "this-device-id")
        XCTAssertEqual(creates, 0); XCTAssertEqual(saves, 1)
    }

    func testInterruptedSaveRetriesTheStableMarkerWithoutCreatingADuplicate() async {
        let store = EKEventStore(), marker = URL(string: "banana://note/\(UUID())")!
        var reminders: [EKReminder] = [], creates = 0, attempts = 0
        func attempt() async -> String? {
            await NoteReminderWriter.write(previousID: nil, marker: marker, title: "Note", notes: "",
                stillCurrent: { true }, lookup: { _ in nil }, fetch: { reminders },
                create: { creates += 1; return EKReminder(eventStore: store) }, save: { item in
                    attempts += 1
                    if reminders.isEmpty { reminders.append(item) }
                    if attempts == 1 { throw CocoaError(.fileWriteUnknown) } // saved, acknowledgement lost
                    return "saved-id"
                })
        }
        let interrupted = await attempt()
        XCTAssertNil(interrupted)
        let recovered = await attempt()
        XCTAssertEqual(recovered, "saved-id")
        XCTAssertEqual(creates, 1); XCTAssertEqual(reminders.count, 1)
    }

    func testFailedFetchAndConcurrentEditNeverAcknowledgeOrSaveStaleWork() async {
        let store = EKEventStore(), marker = URL(string: "banana://note/\(UUID())")!
        var current = true, saves = 0
        let failedFetch = await NoteReminderWriter.write(previousID: "old", marker: marker,
            title: "Note", notes: "", stillCurrent: { true }, lookup: { _ in nil }, fetch: { nil },
            create: { XCTFail("no creation on read failure"); return nil }, save: { _ in saves += 1; return "id" })
        XCTAssertNil(failedFetch)
        let changed = await NoteReminderWriter.write(previousID: nil, marker: marker,
            title: "Old edit", notes: "", stillCurrent: { current }, lookup: { _ in nil },
            fetch: { current = false; return [] }, create: { EKReminder(eventStore: store) },
            save: { _ in saves += 1; return "id" })
        XCTAssertNil(changed); XCTAssertEqual(saves, 0)
    }

    func testExternalDeletionIsRespectedOnlyAfterSuccessfulFetch() async {
        let result = await NoteReminderWriter.write(previousID: "deleted", marker: URL(string: "banana://note/a")!,
            title: "Note", notes: "", stillCurrent: { true }, lookup: { _ in nil }, fetch: { [] },
            create: { XCTFail("do not resurrect an externally deleted reminder"); return nil },
            save: { _ in XCTFail("do not save an externally deleted reminder"); return "id" })
        XCTAssertEqual(result, "deleted")
    }
}
