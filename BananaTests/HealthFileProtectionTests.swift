import XCTest

final class HealthFileProtectionTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HealthFiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func excluded(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    func testAtomicReplacementKeepsBackupExclusionAndContents() throws {
        let file = try root().appendingPathComponent("health.json")
        for value in ["first", "replacement", "after restart"] {
            try HealthFileProtection.write(Data(value.utf8), to: file)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), value)
            XCTAssertTrue(try excluded(file))
        }
        let staging = try HealthFileProtection.stagingDirectory(beside: file)
        XCTAssertTrue(try excluded(staging))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testFailedReplacementPreservesDestinationAndCleansStage() throws {
        let root = try root()
        let destination = root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: original)
        XCTAssertThrowsError(try HealthFileProtection.write(Data("replacement".utf8), to: destination))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("HealthStaging").path).isEmpty)
    }

    func testExistingHealthFilesAndQuarantinesAreProtectedWithoutChangingData() throws {
        let root = try root()
        let names = ["health.json", "wellness.json", "night-motion.json", "wellness.corrupt-old.json"]
        for name in names { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let personal = root.appendingPathComponent("notes.json")
        try Data("personal".utf8).write(to: personal)
        HealthFileProtection.protectLegacyFiles(in: root)
        for name in names {
            let file = root.appendingPathComponent(name)
            XCTAssertTrue(try excluded(file))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), name)
        }
        XCTAssertFalse(try excluded(personal))
    }

    func testPreferencesDirectoryStaysExcludedAcrossSystemStyleAtomicReplacements() throws {
        let library = try root()
        try HealthFileProtection.protectPreferences(in: library)
        try HealthFileProtection.protectPreferences(in: library) // Existing preferences are the normal launch path.
        let directory = library.appendingPathComponent("Preferences")
        let file = directory.appendingPathComponent("example.plist")
        for value in ["old", "new"] {
            try Data(value.utf8).write(to: file, options: .atomic)
            XCTAssertTrue(try excluded(directory), "Directory policy covers replacement inodes")
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), value)
        }
    }

    func testQuarantinePreservesBackupExclusion() throws {
        let file = try root().appendingPathComponent("wellness.json")
        try HealthFileProtection.write(Data("unreadable".utf8), to: file)
        let copy = try XCTUnwrap(SnapshotLoader.quarantine(fileAt: file))
        XCTAssertTrue(try excluded(copy))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: file))
    }
}
