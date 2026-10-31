import XCTest

final class DemoWorkspaceTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_792_929_600)
    private var fixture: DemoWorkspace { DemoFixtures.review(now: anchor, timeZone: TimeZone(identifier: "America/New_York")!) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(DemoRepository.directoryName)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testFixturesAreDeterministicAndUseProductionMealScaling() throws {
        let first = fixture, second = fixture
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
        try first.validate()
        let item = try XCTUnwrap(first.meals.first?.items.first)
        XCTAssertEqual(item.withGrams(500).macros.calories, item.macros.calories * 2)
        XCTAssertTrue(first.notes.allSatisfy { $0.audioFilename.isEmpty && $0.reminderID == nil })
    }

    func testEditsRelaunchAndResetNeverTouchASiblingPersonalStore() async throws {
        let dir = try directory(), personal = dir.deletingLastPathComponent().appendingPathComponent("wellness.json")
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("personal-record-must-survive".utf8); try sentinel.write(to: personal)
        let repository = try DemoRepository(directory: dir, initial: fixture)
        let initial = try await repository.open()
        var event = initial.events[0]; event.title = "Edited sample"
        _ = try await repository.apply(.saveEvent(event))
        _ = try await repository.apply(.completeTask(initial.tasks[0].id, true))
        _ = try await repository.apply(.saveDraft("note", "Unfinished demo draft"))
        let reopened = try DemoRepository(directory: dir, initial: fixture)
        let saved = try await reopened.open()
        XCTAssertEqual(saved.events.first(where: { $0.id == event.id })?.title, "Edited sample")
        XCTAssertTrue(saved.tasks[0].completed)
        XCTAssertEqual(saved.drafts["note"], "Unfinished demo draft")
        let reset = try await reopened.reset()
        XCTAssertEqual(reset.events[0].title, initial.events[0].title)
        XCTAssertTrue(reset.drafts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: personal), sentinel)
    }

    func testReadOnlyAvailabilityCannotBeChangedEvenThroughTheRepository() async throws {
        let repository = try DemoRepository(directory: directory(), initial: fixture)
        let original = try await repository.open()
        var busy = try XCTUnwrap(original.events.first(where: { $0.calendarID == "shared" }))
        for command in [DemoCommand.deleteEvent(busy.id), .moveEvent(busy.id, anchor)] {
            do { _ = try await repository.apply(command); XCTFail("A read-only calendar was changed") }
            catch { XCTAssertEqual(error as? DemoFailure, .readOnlyCalendar) }
        }
        busy.calendarID = "personal"
        do { _ = try await repository.apply(.saveEvent(busy)); XCTFail("Moving an availability-only event must not reveal/edit it") }
        catch { XCTAssertEqual(error as? DemoFailure, .readOnlyCalendar) }
        let after = try await repository.open()
        XCTAssertEqual(after.events, original.events)
    }

    func testFailedWriteDoesNotPublishSuccessAndRetryIsIdempotent() async throws {
        final class Disk: @unchecked Sendable {
            let lock = NSLock(); var bytes: Data?; var fails = false
            func read() -> Data? { lock.lock(); defer { lock.unlock() }; return bytes }
            func write(_ value: Data) throws {
                lock.lock(); defer { lock.unlock() }
                if fails { throw CocoaError(.fileWriteOutOfSpace) }
                bytes = value
            }
            func fail(_ value: Bool) { lock.lock(); fails = value; lock.unlock() }
        }
        let disk = Disk(), io = DemoFileIO(read: { _ in disk.read() }, write: { bytes, _ in try disk.write(bytes) })
        let repository = try DemoRepository(directory: directory(), initial: fixture, io: io)
        let initial = try await repository.open()
        var event = initial.events[0]; event.title = "Retry me"
        disk.fail(true)
        do { _ = try await repository.apply(.saveEvent(event)); XCTFail("A failed disk write was acknowledged") } catch {}
        let afterFailure = try await repository.open()
        XCTAssertEqual(afterFailure.events, initial.events)
        disk.fail(false)
        _ = try await repository.apply(.saveEvent(event)); _ = try await repository.apply(.saveEvent(event))
        let afterRetry = try await repository.open()
        XCTAssertEqual(afterRetry.events.filter { $0.id == event.id }.count, 1)
        XCTAssertEqual(afterRetry.events.first(where: { $0.id == event.id })?.title, "Retry me")
    }

    func testCorruptSnapshotIsPreservedUntilExplicitReset() async throws {
        let dir = try directory(); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("workspace.json"), corrupt = Data("not-json".utf8)
        try corrupt.write(to: file)
        let repository = try DemoRepository(directory: dir, initial: fixture)
        do { _ = try await repository.open(); XCTFail("Corruption must not silently seed over saved data") }
        catch { XCTAssertEqual(error as? DemoFailure, .unreadable) }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        let reset = try await repository.reset(); XCTAssertFalse(reset.events.isEmpty)
    }

    func testMealTimeRepeatAndNoteArchiveSurviveRelaunch() async throws {
        let dir = try directory(), repository = try DemoRepository(directory: dir, initial: fixture)
        let initial = try await repository.open(); var meal = initial.meals[0]
        meal.date = anchor.addingTimeInterval(-3600)
        _ = try await repository.apply(.saveMeal(meal))
        let newID = UUID()
        _ = try await repository.apply(.repeatMeal(meal.id, anchor, newID))
        _ = try await repository.apply(.repeatMeal(meal.id, anchor, newID))
        _ = try await repository.apply(.archiveNote(initial.notes[0].id, true))
        let reopened = try DemoRepository(directory: dir, initial: fixture), saved = try await reopened.open()
        XCTAssertEqual(saved.meals.first(where: { $0.id == meal.id })?.date, meal.date)
        XCTAssertEqual(saved.meals.filter { $0.id == newID }.count, 1)
        XCTAssertEqual(saved.meals.first(where: { $0.id == newID })?.items, meal.items)
        XCTAssertNotNil(saved.notes.first(where: { $0.id == initial.notes[0].id })?.archivedAt)
    }

    func testRecurrenceUsesCalendarDaysAcrossDSTAndVisibilityPersists() async throws {
        let cal = fixture.calendar
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9))!
        let event = DemoEvent(id: UUID(), calendarID: "personal", title: "Daily", start: start, end: start.addingTimeInterval(3600), recurrence: .daily)
        let nextDay = cal.date(byAdding: .day, value: 1, to: start)!
        let next = try XCTUnwrap(event.occurrence(on: nextDay, calendar: cal))
        XCTAssertEqual(cal.component(.hour, from: next.start), 9)
        XCTAssertEqual(next.end.timeIntervalSince(next.start), 3600)
        XCTAssertEqual(next.start.timeIntervalSince(start), 25 * 3600)
        let repository = try DemoRepository(directory: directory(), initial: fixture)
        let state = try await repository.apply(.calendarVisible("work", false))
        XCTAssertFalse(state.events(on: state.anchor).contains(where: { $0.calendarID == "work" }))
        XCTAssertTrue(state.events.contains(where: { $0.calendarID == "work" }))
    }

    func testVersionedScenarioCanBeSerializedReplayedAndRetriedWithoutDuplicates() async throws {
        let dir = try directory(), original = fixture
        var event = original.events[0]; event.title = "Scenario meeting"
        let repeatID = DemoFixtures.id(900)
        let scenario = DemoScenario(name: "plan-food-notes", clock: anchor, timeZone: original.timeZone, commands: [
            .saveEvent(event), .completeTask(original.tasks[0].id, true),
            .repeatMeal(original.meals[0].id, anchor, repeatID), .archiveNote(original.notes[0].id, true),
        ])
        let bytes = try JSONEncoder().encode(scenario)
        let decoded = try JSONDecoder().decode(DemoScenario.self, from: bytes)
        let first = try await DemoScenarioRunner.replay(decoded, in: dir)
        let second = try await DemoScenarioRunner.replay(decoded, in: dir)
        XCTAssertEqual(first.completedCommands, 4)
        XCTAssertEqual(second.workspace.events.filter { $0.title == "Scenario meeting" }.count, 1)
        XCTAssertEqual(second.workspace.meals.filter { $0.id == repeatID }.count, 1)
        XCTAssertTrue(second.workspace.tasks[0].completed)
        XCTAssertNotNil(second.workspace.notes.first(where: { $0.id == original.notes[0].id })?.archivedAt)
        var unsupported = decoded; unsupported.version = 99
        do { _ = try await DemoScenarioRunner.replay(unsupported, in: dir); XCTFail("Unsupported scenario was executed") }
        catch { XCTAssertEqual(error as? DemoFailure, .invalidData) }
    }

    func testOvernightAndLongRecurringEventsContinueIntoTheNextDay() throws {
        var workspace = fixture
        let calendar = workspace.calendar, day = calendar.startOfDay(for: workspace.anchor)
        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        workspace.events = [DemoEvent(id: UUID(), calendarID: "personal", title: "Overnight", start: start, end: start.addingTimeInterval(7200))]
        XCTAssertEqual(workspace.events(on: day).count, 1)
        XCTAssertEqual(workspace.events(on: tomorrow).count, 1)
        let twoDays = calendar.date(byAdding: .day, value: 2, to: day)!
        XCTAssertTrue(workspace.events(on: twoDays).isEmpty)
        workspace.events[0].recurrence = .daily
        XCTAssertEqual(workspace.events(on: tomorrow).count, 2, "Yesterday's continuation and today's new occurrence are distinct")
    }

    func testDemoStorageRejectsPersonalLocationsAndSymbolicLinks() throws {
        let dir = try directory(), parent = dir.deletingLastPathComponent(), outside = parent.appendingPathComponent("personal")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        do { _ = try DemoRepository(directory: outside, initial: fixture); XCTFail("A non-demo directory was accepted") }
        catch { XCTAssertEqual(error as? DemoFailure, .unsafeDirectory) }
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: outside)
        do { _ = try DemoRepository(directory: dir, initial: fixture); XCTFail("A symbolic link was accepted") }
        catch { XCTAssertEqual(error as? DemoFailure, .unsafeDirectory) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("workspace.json").path))
    }
}
