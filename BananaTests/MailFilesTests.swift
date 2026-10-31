import XCTest

/// The one door for files (MAIL-ENGINE 11.2): a temporary file, an atomic move, the protection
/// class after the move, the quarantine before anything can reach the file — and, for the
/// precious tier, the sync that makes the file survive a power cut.
///
/// What goes wrong here goes wrong silently: a stored attachment that was never given its class,
/// or one that a program on the Mac can run without Gatekeeper's check, or one that is empty
/// after a crash though a durably committed row names it, looks exactly like one that was done
/// right. The Simulator does not enforce protection classes and may not report them, so the
/// tests watch the *calls* (`MailFileAttributes`) and, at the moment of each, what the
/// filesystem looked like — which is the one thing a class set too early or too late, or a sync
/// that was made after the move instead of before it, could not hide. Reading the real classes
/// off a device is the owner's first device run (D18).
///
/// File work is off the main thread (invariant 10), so every call here is made from a background
/// queue, as the engine makes them.
final class MailFilesTests: MailStoreTestCase {

    private func directory() throws -> URL {
        let root = try makeRoot()
        let folder = root.appendingPathComponent("Attachments.noindex", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func entries(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Installing

    func testAFileIsGivenItsProtectionClassAfterItsMoveNeverBefore() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-1234.pdf")
        let recorder = MailAttributeRecorder()
        let temporary = try await offMain { try MailFiles.createTemporary(beside: destination, attributes: recorder.attributes) }
        try Data("bytes".utf8).write(to: temporary)

        // At the instant the class is set: the file is at its final name and the temporary one is gone.
        let seen = MailTestList<[Bool]>()
        recorder.onEvent = { event in
            guard event.hasPrefix("protect") else { return }
            seen.add([FileManager.default.fileExists(atPath: destination.path),
                      FileManager.default.fileExists(atPath: temporary.path)])
        }
        try await offMain {
            try MailFiles.install(temporary: temporary, at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
        }

        XCTAssertEqual(recorder.events, ["protect aa-1234.pdf complete"])
        XCTAssertEqual(seen.all.count, 1)
        XCTAssertEqual(seen.all.first?[0], true, "the class was set before the file was in place")
        XCTAssertEqual(seen.all.first?[1], false, "the class was set on the temporary file, which does not keep it")
        XCTAssertEqual(try contents(destination), "bytes")
    }

    func testTheQuarantineIsSetOnTheTemporaryFileBeforeTheMoveSoTheFileIsNeverThereWithoutIt() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-5678.command")
        let recorder = MailAttributeRecorder()
        let temporary = try await offMain { try MailFiles.createTemporary(beside: destination, attributes: recorder.attributes) }

        let atQuarantine = MailTestList<[Bool]>()
        recorder.onEvent = { event in
            guard event.hasPrefix("quarantine") else { return }
            atQuarantine.add([FileManager.default.fileExists(atPath: destination.path),
                              FileManager.default.fileExists(atPath: temporary.path)])
        }
        try await offMain {
            try MailFiles.install(temporary: temporary, at: destination, protection: .complete, quarantine: MailQuarantine(origin: URL(string: "mailto:someone@example.com")), durability: .atomic, attributes: recorder.attributes)
        }

        XCTAssertEqual(recorder.events.map { $0.split(separator: " ").first.map(String.init) ?? "" },
                       ["quarantine", "protect"], "quarantine, then the move, then the class")
        XCTAssertEqual(atQuarantine.all.first?[0], false, "nothing was at the final name yet")
        XCTAssertEqual(atQuarantine.all.first?[1], true, "the quarantine was set on the file waiting to be moved")
    }

    func testNoQuarantineIsSetWhenNoneIsAsked() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("first-page.json")
        let recorder = MailAttributeRecorder()
        try await offMain {
            try MailFiles.install(Data("{}".utf8), at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
        }
        XCTAssertEqual(recorder.events, ["protect first-page.json complete"])
    }

    func testInstallingOverAnExistingFileReplacesItWholeAndLeavesNoTemporaryFile() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("first-page.json")
        try Data("old".utf8).write(to: destination)
        let recorder = MailAttributeRecorder()

        try await offMain {
            try MailFiles.install(Data("new, and longer than the old one".utf8), at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
        }
        XCTAssertEqual(try contents(destination), "new, and longer than the old one")
        XCTAssertEqual(try entries(folder), ["first-page.json"], "no temporary file is left beside it")
    }

    func testTheTemporaryFileIsBesideItsDestinationUnderAHiddenNameAndNothingIsCreatedByAskingForOne() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-1.bin")
        let url = MailFiles.temporaryURL(beside: destination)
        XCTAssertEqual(url.deletingLastPathComponent().path, folder.path, "same directory, so the move is a rename")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("."), "hidden")
        XCTAssertNotEqual(url, MailFiles.temporaryURL(beside: destination), "never the same name twice")
        XCTAssertEqual(try entries(folder), [])

        let made = try await offMain { try MailFiles.createTemporary(beside: destination) }
        XCTAssertTrue(exists(made))
        XCTAssertEqual(made.deletingLastPathComponent().path, folder.path)
    }

    func testATemporaryFileIsRecognisedByNameSoAnOrphanCanBeSweptAndNothingElseIs() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-1.bin")
        let made = try await offMain { try MailFiles.createTemporary(beside: destination) }
        XCTAssertTrue(MailFiles.isTemporaryName(made.lastPathComponent))
        XCTAssertTrue(MailFiles.isTemporaryName(MailFiles.temporaryURL(beside: destination).lastPathComponent))
        for name in ["aa-1.bin", "first-page.json", ".DS_Store", ".mail-nothing", "x.partial", "a.pdf.partial"] {
            XCTAssertFalse(MailFiles.isTemporaryName(name), name)
        }
        XCTAssertEqual(MailFiles.temporaryPrefix, ".mail-")
        XCTAssertEqual(MailFiles.temporarySuffix, ".partial")
    }

    func testCreatingATemporaryFileWhereThereIsNoDirectoryThrowsTheStepAndTheSystemsNumber() async throws {
        let missing = try directory().appendingPathComponent("no-such-directory/aa-1.bin")
        do {
            _ = try await offMain { try MailFiles.createTemporary(beside: missing) }
            XCTFail("a temporary file was made in a directory that is not there")
        } catch let error as MailFileError {
            XCTAssertEqual(error, .failed(.create, code: Int(ENOENT)), "the number is open(2)'s own, not a later call's")
        }
    }

    func testWhenTheQuarantineCannotBeSetNothingIsInstalledAndTheTemporaryFileIsRemoved() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-2.bin")
        let recorder = MailAttributeRecorder()
        let temporary = try await offMain { try MailFiles.createTemporary(beside: destination, attributes: recorder.attributes) }
        recorder.failing = ["quarantine"]

        do {
            try await offMain {
                try MailFiles.install(temporary: temporary, at: destination, protection: .complete, quarantine: MailQuarantine(), durability: .atomic, attributes: recorder.attributes)
            }
            XCTFail("installed without the quarantine that was asked for")
        } catch {}
        XCTAssertEqual(try entries(folder), [], "an attachment that was not quarantined is not left to be opened")
    }

    func testWhenTheClassCannotBeSetTheInstalledFileIsRemovedAgain() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-3.bin")
        let recorder = MailAttributeRecorder()
        recorder.failing = ["protect"]

        do {
            try await offMain {
                try MailFiles.install(Data("x".utf8), at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
            }
            XCTFail("installed without the class that was asked for")
        } catch {}
        XCTAssertEqual(try entries(folder), [], "a file that is not as protected as it was promised to be is not kept")
    }

    func testWhenTheClassCannotBeSetOverAnExistingFileTheOldOneIsGoneToo() async throws {
        // Said in the doc comment and pinned here, so that nobody installs over a file that
        // matters and expects to keep it when this throws.
        let folder = try directory()
        let destination = folder.appendingPathComponent("first-page.json")
        try Data("the old one".utf8).write(to: destination)
        let recorder = MailAttributeRecorder()
        recorder.failing = ["protect"]
        do {
            try await offMain {
                try MailFiles.install(Data("the new one".utf8), at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
            }
            XCTFail()
        } catch {}
        XCTAssertEqual(try entries(folder), [])
    }

    func testWhenTheMoveFailsTheTemporaryFileIsRemovedAndTheErrorNamesTheStepOnly() async throws {
        let folder = try directory()
        // The destination's directory does not exist, so the rename cannot happen.
        let destination = folder.appendingPathComponent("missing-directory/secret-name.pdf")
        let recorder = MailAttributeRecorder()
        let temporary = try await offMain {
            try MailFiles.createTemporary(beside: folder.appendingPathComponent("anything"), attributes: recorder.attributes)
        }

        do {
            try await offMain {
                try MailFiles.install(temporary: temporary, at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
            }
            XCTFail("a move to a directory that is not there succeeded")
        } catch let error as MailFileError {
            guard case .failed(let step, _) = error else { return XCTFail() }
            XCTAssertEqual(step, .move)
            XCTAssertFalse(String(describing: error).contains("secret-name"), "an error carries no file name (invariant 21)")
            XCTAssertFalse(error.localizedDescription.contains("secret-name"))
        }
        XCTAssertEqual(try entries(folder), [], "the temporary file was cleaned up")
        XCTAssertEqual(recorder.events, [], "and no class was set on anything")
    }

    func testDataIsWrittenToATemporaryFileAndInstalledWhole() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-4.bin")
        let big = Data(repeating: 0xAB, count: 300_000)
        try await offMain {
            try MailFiles.install(big, at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: MailAttributeRecorder().attributes)
        }
        XCTAssertEqual(try Data(contentsOf: destination), big)
        XCTAssertEqual(try entries(folder), ["aa-4.bin"])
    }

    func testTheRealAttributeCallsWorkOnThisHostForAFileAndADirectory() async throws {
        // The live closures, once, so that what the recorder stood in for is known to run: backup
        // exclusion is read back; the class is whatever the host allows, and is not read back.
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-5.bin")
        try await offMain { try MailFiles.install(Data("x".utf8), at: destination, protection: .complete, quarantine: nil, durability: .atomic) }   // live
        XCTAssertEqual(try contents(destination), "x")

        try await offMain { try MailFileAttributes.live.excludeFromBackup(folder) }
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        // On iOS the quarantine closure is a no-op and must not throw.
        #if !os(macOS)
        try await offMain { try MailFileAttributes.live.quarantine(destination, MailQuarantine()) }
        #endif
    }

    // MARK: - Durability

    func testASyncedFileHasItsBytesSyncedBeforeTheMoveAndItsDirectoryAfterItAndThenItsClass() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-6.pdf")
        let recorder = MailAttributeRecorder()

        // What the filesystem looks like at each sync: the first before the move, the second after.
        let at = MailTestList<String>()
        recorder.onEvent = { event in
            guard event.hasPrefix("sync") else { return }
            at.add("\(event): destination \(FileManager.default.fileExists(atPath: destination.path) ? "there" : "not there"), "
                   + "\((try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter(MailFiles.isTemporaryName).count) ?? -1) temporary")
        }
        try await offMain {
            try MailFiles.install(Data("a draft's attachment".utf8), at: destination, protection: .completeUntilFirstUserAuthentication, quarantine: MailQuarantine(), durability: .synced, attributes: recorder.attributes)
        }

        let kinds = recorder.events.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(kinds, ["quarantine", "sync", "sync", "protect"],
                       "the attributes that travel with the file, its bytes, then — after the move — its name, then its class")
        XCTAssertEqual(recorder.events[1].hasPrefix("sync .mail-"), true, "the temporary file's bytes")
        XCTAssertEqual(recorder.events[2], "sync Attachments.noindex", "the directory the name is in")
        XCTAssertEqual(at.all[0].contains("destination not there, 1 temporary"), true, at.all[0])
        XCTAssertEqual(at.all[1].contains("destination there, 0 temporary"), true, at.all[1])
        XCTAssertEqual(try contents(destination), "a draft's attachment")
    }

    func testAnAtomicFileIsNotSyncedSoTheDisposableTierCostsWhatItAlwaysDid() async throws {
        let folder = try directory()
        let recorder = MailAttributeRecorder()
        try await offMain {
            try MailFiles.install(Data("x".utf8), at: folder.appendingPathComponent("aa-7.bin"), protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
            try MailFiles.install(Data("y".utf8), at: folder.appendingPathComponent("aa-8.bin"), protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
        }
        XCTAssertFalse(recorder.events.contains { $0.hasPrefix("sync") }, "\(recorder.events)")
    }

    func testWhenTheBytesCannotBeSyncedNothingIsInstalledAndTheTemporaryFileIsRemoved() async throws {
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-9.pdf")
        let recorder = MailAttributeRecorder()
        recorder.failing = ["sync"]
        do {
            try await offMain {
                try MailFiles.install(Data("x".utf8), at: destination, protection: .complete, quarantine: nil, durability: .synced, attributes: recorder.attributes)
            }
            XCTFail("installed a file whose bytes could not be made durable")
        } catch {}
        XCTAssertEqual(try entries(folder), [])
        XCTAssertFalse(recorder.events.contains { $0.hasPrefix("protect") }, "the move was never made")
    }

    func testAStreamedFileIsSyncedToo() async throws {
        // A caller that streams into `createTemporary` and then installs gets the same: its own
        // handle need not be synced, the door does it.
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-10.pdf")
        let recorder = MailAttributeRecorder()
        let temporary = try await offMain { try MailFiles.createTemporary(beside: destination, attributes: recorder.attributes) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: Data(repeating: 7, count: 100_000))
        try handle.close()
        try await offMain {
            try MailFiles.install(temporary: temporary, at: destination, protection: .complete, quarantine: nil, durability: .synced, attributes: recorder.attributes)
        }
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("sync") }.count, 2)
        XCTAssertEqual(try Data(contentsOf: destination).count, 100_000)
    }

    func testTheRealSyncWorksOnThisHostForAFileAndForADirectory() async throws {
        // `F_FULLFSYNC` where it is allowed and `fsync` where it is not: neither may throw here.
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-11.pdf")
        try await offMain {
            try MailFiles.install(Data("durable".utf8), at: destination, protection: .complete, quarantine: nil, durability: .synced)
        }
        XCTAssertEqual(try contents(destination), "durable")
        try await offMain { try MailFileAttributes.live.synchronize(folder) }

        do {
            try await offMain { try MailFileAttributes.live.synchronize(folder.appendingPathComponent("not-there")) }
            XCTFail("syncing a file that is not there succeeded")
        } catch let error as MailFileError {
            XCTAssertEqual(error, .failed(.sync, code: Int(ENOENT)))
        }
    }

    // MARK: - Invariant 10: not on the main thread

    func testEveryDoorToFileWorkAsksWhetherItIsOnTheMainThreadFirst() async throws {
        // A trap cannot be asserted on, so the recorder stands in for the real check
        // (`dispatchPrecondition` and a look at the thread) and is shown to be asked, on the
        // main thread, by each way in. Run from the main thread, as the test is.
        let folder = try directory()
        let destination = folder.appendingPathComponent("aa-12.bin")
        let recorder = MailAttributeRecorder()

        _ = try await MainActor.run { try MailDirectories(root: folder.appendingPathComponent("tree"), attributes: recorder.attributes) }
        XCTAssertEqual(recorder.offMainCheckedOnMain, [true], "MailDirectories.init")

        let temporary = try await MainActor.run { try MailFiles.createTemporary(beside: destination, attributes: recorder.attributes) }
        XCTAssertEqual(recorder.offMainCheckedOnMain.count, 2, "createTemporary")

        try await MainActor.run {
            try MailFiles.install(temporary: temporary, at: destination, protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
        }
        XCTAssertEqual(recorder.offMainCheckedOnMain.count, 3, "install(temporary:)")

        try await MainActor.run {
            try MailFiles.install(Data("x".utf8), at: folder.appendingPathComponent("aa-13.bin"), protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
        }
        XCTAssertGreaterThanOrEqual(recorder.offMainCheckedOnMain.count, 4, "install(_ data:)")
        XCTAssertTrue(recorder.offMainCheckedOnMain.allSatisfy { $0 })

        // And from a background queue it is asked and is not on main.
        let before = recorder.offMainCheckedOnMain.count
        try await offMain {
            try MailFiles.install(Data("y".utf8), at: folder.appendingPathComponent("aa-14.bin"), protection: .complete, quarantine: nil, durability: .atomic, attributes: recorder.attributes)
        }
        XCTAssertTrue(recorder.offMainCheckedOnMain.dropFirst(before).allSatisfy { !$0 })
        XCTAssertGreaterThan(recorder.offMainCheckedOnMain.count, before)
    }

    // MARK: - Errors

    func testAFileErrorSaysTheStepAndTheNumberAndNothingElse() {
        let error = MailFileError.failed(.protect, code: 513)
        XCTAssertEqual(String(describing: error), "MailFileError.protect(513)")
        XCTAssertEqual(String(describing: MailFileError.failed(.sync, code: 5)), "MailFileError.sync(5)")
    }
}
