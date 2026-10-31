import XCTest

final class JSONRecordStreamTests: XCTestCase {
    func testChunkBoundariesEscapesUnicodeAndMalformedTails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JSONRecordStream-\(UUID()).json")
        let records = [["text": String(repeating: "\"{}[]\\東京", count: 12_000)], ["text": "second"]]
        try JSONEncoder().encode(records).write(to: url)
        var decoded: [[String: String]] = []
        try JSONRecordStream.forEach(at: url) { decoded.append(try JSONDecoder().decode([String: String].self, from: $0)) }
        XCTAssertEqual(decoded, records)
        for invalid in ["[{},]", "[{}", "[{}]garbage", "{}", "[{},,{}]", "[null]"] {
            try Data(invalid.utf8).write(to: url)
            XCTAssertThrowsError(try JSONRecordStream.forEach(at: url) { _ = try JSONDecoder().decode([String: String].self, from: $0) }, invalid)
        }
    }
}
