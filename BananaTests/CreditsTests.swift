import XCTest

/// Settings credits everything `NOTICE.md` lists, and nothing it doesn't.
final class CreditsTests: XCTestCase {
    func testSettingsAndTheNoticesFileListTheSameSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let notice = try String(contentsOf: root.appendingPathComponent("NOTICE.md"), encoding: .utf8)
        let links = try NSRegularExpression(pattern: #"\]\((https?://[^)\s]+)\)"#)
        let listed = Set(links.matches(in: notice, range: NSRange(notice.startIndex..., in: notice)).map {
            String(notice[Range($0.range(at: 1), in: notice)!])
        })
        let credited = Set(Credits.groups.flatMap(\.entries).map(\.url.absoluteString))
        XCTAssertFalse(listed.isEmpty)
        XCTAssertEqual(listed.subtracting(credited), [], "in NOTICE.md, not in Settings")
        XCTAssertEqual(credited.subtracting(listed), [], "in Settings, not in NOTICE.md")
    }

    /// Apple Weather is the one forecast source: the Open-Meteo fallback stays out.
    func testNoSourceAsksOpenMeteo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["Banana", "Shared", "BananaMac"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            for case let file as URL in files! where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8).lowercased()
                XCTAssertFalse(text.contains("open-meteo") || text.contains("openmeteo"), file.lastPathComponent)
            }
        }
    }
}
