import XCTest

final class NoteRepositoryTests: XCTestCase {
    private func make(_ values: [VoiceNote] = []) throws -> (NoteRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteRepositoryTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("notes.json")
        try JSONEncoder().encode(values).write(to: legacy)
        return (try NoteRepository(url: root.appendingPathComponent("notes.sqlite"), legacyURL: legacy), legacy)
    }

    func testReminderLinksOpenOnlyTheCorrectVariantAndRejectMalformedTargets() throws {
        let id = UUID()
        for beta in [false, true] {
            let url = NoteReminderLink.url(id, beta: beta)
            XCTAssertEqual(NoteReminderLink.noteID(url, beta: beta), id)
            XCTAssertNil(NoteReminderLink.noteID(url, beta: !beta))
            XCTAssertNil(NoteReminderLink.noteID(URL(string: url.absoluteString + "/extra")!, beta: beta))
            XCTAssertNil(NoteReminderLink.noteID(URL(string: url.absoluteString + "?action=delete")!, beta: beta))
        }
    }

    func testReminderIntentSurvivesReopenAndAcknowledgesAtomically() throws {
        let (store, legacy) = try make()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        let note = VoiceNote(audioFilename: "", transcript: "Saved first", status: .transcribed)
        try store.apply([note], enqueueReminders: true)
        let reopened = try NoteRepository(url: legacy.deletingLastPathComponent().appendingPathComponent("notes.sqlite"), legacyURL: legacy)
        XCTAssertEqual(try reopened.pendingReminders(), [note])
        XCTAssertEqual(try reopened.acknowledgeReminder(for: note, identifier: "ek-id")?.reminderID, "ek-id")
        XCTAssertTrue(try reopened.pendingReminders().isEmpty)
        XCTAssertEqual(try reopened.note(note.id)?.reminderID, "ek-id")
    }

    func testNewerEditKeepsReminderIntentAndDeletionCancelsIt() throws {
        let (store, legacy) = try make()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        let note = VoiceNote(audioFilename: "", transcript: "Before", status: .transcribed)
        try store.apply([note], enqueueReminders: true)
        var edited = note
        edited.transcript = "After"
        edited.updatedAt = note.syncDate.addingTimeInterval(1)
        try store.apply([edited], enqueueReminders: true)
        XCTAssertNil(try store.acknowledgeReminder(for: note, identifier: "old-ack"))
        XCTAssertEqual(try store.pendingReminders(), [edited])
        try store.remove(note.id)
        XCTAssertTrue(try store.pendingReminders().isEmpty)
        XCTAssertNil(try store.acknowledgeReminder(for: edited, identifier: "late-ack"))
    }

    func testRemoteImportsDoNotEnqueueAndFailedTransactionCreatesNoIntent() throws {
        let (store, legacy) = try make()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        let note = VoiceNote(audioFilename: "", transcript: "Remote", status: .transcribed)
        try store.apply([note])
        XCTAssertTrue(try store.pendingReminders().isEmpty)
        var invalid = VoiceNote(audioFilename: "", transcript: "Cannot encode", status: .transcribed)
        invalid.createdAt = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try store.apply([note, invalid], enqueueReminders: true))
        XCTAssertTrue(try store.pendingReminders().isEmpty, "Note and intent roll back together")
        XCTAssertNil(try store.note(invalid.id))
    }

    func testCanonicalEchoDoesNotLoseAnEditAtTheSameWireTimestamp() throws {
        let (store, legacy) = try make()
        defer { try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent()) }
        let stamp = Date(timeIntervalSinceReferenceDate: 814310821.492354)
        let note = VoiceNote(createdAt: stamp, updatedAt: stamp, audioFilename: "fixture.m4a", transcript: "before")
        XCTAssertTrue(try store.upsert([note]))
        var echo = try CanonicalJSON.decode(VoiceNote.self, from: CanonicalJSON.value(of: note))
        XCTAssertLessThan(echo.syncDate, note.syncDate, "fixture exercises canonical millisecond rounding")
        echo.transcript = "after"
        XCTAssertFalse(note.isNewerForSync(than: echo))
        XCTAssertTrue(try store.upsert([echo]), "accept the resolved edit at equal wire-clock precision")
        XCTAssertEqual(try store.note(note.id)?.transcript, "after")
        XCTAssertFalse(try store.upsert([echo]), "a repeated echo must not publish another change")
        var older = echo
        older.updatedAt = stamp.addingTimeInterval(-1)
        older.transcript = "stale"
        XCTAssertFalse(try store.upsert([older]), "a genuinely older edit still loses")
    }

    func testLiveDateAndMultipleTextPredicatesRunBeforePaging() throws {
        let today = Calendar.current.startOfDay(for: Date())
        let old = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        let notes = (0..<205).map { i in VoiceNote(createdAt: i == 0 ? old : today, audioFilename: "", transcript: i == 1 ? "physical" : "physical therapy", status: .transcribed) }
        let (store, _) = try make(notes)
        let filter = LiveFilter(scope: "notes", terms: [.init(field: "date", op: "in", value: "today"), .init(field: "text", op: "contains", value: "physical"), .init(field: "text", op: "contains", value: "therapy")])
        let page = try store.page(search: "", archived: false, filter: filter)
        XCTAssertEqual(page.total, 203)
        XCTAssertEqual(page.rows.count, 100)
        XCTAssertTrue(page.rows.allSatisfy { $0.createdAt == today && $0.transcript == "physical therapy" })
        XCTAssertEqual(try store.page(search: "", archived: false, offset: 200, filter: filter).rows.count, 3)
        let invalid = LiveFilter(scope: "notes", issues: ["Choose one date"])
        XCTAssertEqual(try store.page(search: "", archived: false, filter: invalid).total, 0)
    }

    func testMigrationPagingLocalizedSearchAndDurableEdits() throws {
        let notes = (0..<251).map { i in
            VoiceNote(createdAt: Date(timeIntervalSince1970: Double(i)), archivedAt: i % 5 == 0 ? Date() : nil,
                      audioFilename: "", transcript: "Café NEEDLE \(i)", status: .transcribed)
        }
        let (store, legacy) = try make(notes)
        let original = try Data(contentsOf: legacy)
        XCTAssertEqual(try store.count(), 251)
        let first = try store.page(search: "needle", archived: false)
        let second = try store.page(search: "needle", archived: false, offset: 100)
        XCTAssertEqual(first.total, 200)
        XCTAssertEqual(first.rows.count, 100)
        XCTAssertEqual(second.rows.count, 100)
        XCTAssertTrue(Set(first.rows.map(\.id)).isDisjoint(with: second.rows.map(\.id)))
        XCTAssertEqual(try store.page(search: "CAFÉ", archived: false).total, 200)
        XCTAssertFalse(try store.upsert([notes[1]]), "An identical sync record must not trigger a redraw")
        var edited = notes[1]
        edited.updatedAt = Date()
        edited.transcript = "Changed"
        XCTAssertTrue(try store.upsert([edited]))
        XCTAssertFalse(try store.upsert([notes[1]]), "An old remote record must not replace a newer edit")
        XCTAssertEqual(try store.page(search: "needle", archived: false).total, 199)
        let reopened = try NoteRepository(url: legacy.deletingLastPathComponent().appendingPathComponent("notes.sqlite"), legacyURL: legacy)
        XCTAssertEqual(try reopened.note(edited.id), edited)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertTrue(try reopened.remove(edited.id))
        XCTAssertNil(try reopened.note(edited.id))
    }

    func testMalformedMigrationRollsBackAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("notes.json")
        let database = root.appendingPathComponent("notes.sqlite")
        let note = VoiceNote(audioFilename: "", transcript: "Preserve me", status: .transcribed)
        var corrupt = Data("[".utf8)
        corrupt.append(try JSONEncoder().encode(note))
        corrupt.append(Data(", {broken]".utf8))
        try corrupt.write(to: legacy)
        XCTAssertThrowsError(try NoteRepository(url: database, legacyURL: legacy))
        XCTAssertEqual(try Data(contentsOf: legacy), corrupt)
        try JSONEncoder().encode([note]).write(to: legacy)
        let repaired = try NoteRepository(url: database, legacyURL: legacy)
        XCTAssertEqual(try repaired.count(), 1)
        XCTAssertEqual(try repaired.note(note.id), note)
    }

    func testContextSearchPendingAndMissingExcerptIndexes() throws {
        let note = VoiceNote(audioFilename: "", context: .init(episodeID: "ep", episodeTitle: "Topic", podcastTitle: "Show", timestamp: 10), status: .pendingTranscription)
        let (store, _) = try make([note])
        XCTAssertEqual(try store.page(search: "topic", archived: false).rows.map(\.id), [note.id])
        XCTAssertEqual(try store.ids(pending: true), [note.id])
        XCTAssertEqual(try store.ids(missingExcerptFor: "ep"), [note.id])
        var done = note
        done.status = .transcribed
        done.context?.transcriptExcerpt = "Ready"
        done.updatedAt = Date()
        try store.upsert([done])
        XCTAssertTrue(try store.ids(pending: true).isEmpty)
        XCTAssertTrue(try store.ids(missingExcerptFor: "ep").isEmpty)
    }

    func testSearchPrefilterMatchesFoundationForUnicodeAndControlCharacters() throws {
        let texts = ["ordinary NEEDLE", "Café", "Cafe\u{301}", "İstanbul", "ı", "I", "Straße", "STRASSE",
                     "Kelvin", "hello\nneedle", "before\0needle", "Æther", "a%b_c", "", "東京"]
        let notes = texts.map { VoiceNote(audioFilename: "", transcript: $0, status: .transcribed) }
        let (store, _) = try make(notes)
        for query in ["needle", "cafe", "CAFÉ", "i", "I", "STRASSE", "k", "ae", "%", "_", "\0", "京"] {
            let expected = Set(notes.filter { $0.transcript!.localizedCaseInsensitiveContains(query) }.map(\.id))
            XCTAssertEqual(Set(try store.page(search: query, archived: false).rows.map(\.id)), expected, query)
        }
    }

    func testTrailingIgnoredSearchCharacterDoesNotCrash() throws {
        let note = VoiceNote(audioFilename: "", transcript: "Café needle", status: .transcribed)
        let (store, _) = try make([note])
        XCTAssertEqual(try store.page(search: "needle\0", archived: false).rows.map(\.id), [note.id])
        XCTAssertTrue(try store.page(search: "missing\0", archived: false).rows.isEmpty)
        let cache = NoteQueryCache()
        XCTAssertEqual(cache.matching([note], search: "needle\0", archived: false).map(\.id), [note.id])
        XCTAssertTrue(cache.matching([note], search: "missing\0", archived: false).isEmpty)
    }
}
