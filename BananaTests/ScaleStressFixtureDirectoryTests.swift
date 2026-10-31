import XCTest
@testable import Banana

final class ScaleStressFixtureDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-dir-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("store.sqlite"))
        return url
    }

    func testEachLaunchRemovesThePreviousLaunchesFoldersAndNothingElse() throws {
        let stale1 = try folder("ScaleStress-AAAA")
        let stale2 = try folder("ScaleStress-BBBB")
        let unrelated = try folder("SomethingElse")
        let plainFile = root.appendingPathComponent("ScaleStress-notes.txt")
        try Data("y".utf8).write(to: plainFile)

        let fresh = ScaleStressFixtureDirectory.make(in: root)

        XCTAssertTrue(fresh.lastPathComponent.hasPrefix(ScaleStressFixtureDirectory.prefix))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plainFile.path), "prefix match, not directory type, decides")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testSecondLaunchRemovesTheFirstLaunchesFolder() {
        let first = ScaleStressFixtureDirectory.make(in: root)
        let second = ScaleStressFixtureDirectory.make(in: root)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testRemoveStaleReportsWhatWent() throws {
        let stale = try folder("ScaleStress-CCCC")
        XCTAssertEqual(ScaleStressFixtureDirectory.removeStale(in: root), [stale])
        XCTAssertEqual(ScaleStressFixtureDirectory.removeStale(in: root), [])
    }
}
