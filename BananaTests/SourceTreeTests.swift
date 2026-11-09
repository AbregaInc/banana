import XCTest

/// Sources are compiled with their paths mapped (`/^src`, for the shared compilation cache), so a
/// test that finds a file from `#filePath` reads a path that doesn't exist. SourceTree.root is the
/// one way to the tree; `#filePath` stays fine as a failure location (`file: StaticString`).
final class SourceTreeTests: XCTestCase {
    func testOnlySourceTreeTurnsFilePathIntoAPath() throws {
        let folder = SourceTree.root.appendingPathComponent("BananaTests")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        let pattern = try NSRegularExpression(pattern: #"URL\(\s*fileURLWithPath:\s*#file(Path)?\b"#)
        var offenders: [String] = []
        for name in files where name != "SourceTree.swift" && name != "SourceTreeTests.swift" {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { offenders.append(name) }
        }
        XCTAssertEqual(offenders, [], "use SourceTree.root instead of #filePath")
    }
}
