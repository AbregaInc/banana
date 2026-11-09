import XCTest

/// App Review 2.5.4 (Nov 2026): the two background modes Apple questioned are real features and
/// stay declared: "audio" is the podcast player, "location" is "Record where I listen", which keeps
/// recording after Banana leaves the screen (ListenRouteRecorder never lets iOS pause it).
final class BackgroundModesTests: XCTestCase {
    private func modes(_ plist: String) throws -> [String] {
        let root = SourceTree.root
        let data = try Data(contentsOf: root.appendingPathComponent(plist))
        let dict = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(dict["UIBackgroundModes"] as? [String])
    }

    func testBothPhoneAppsDeclareAudioAndLocation() throws {
        for plist in ["Banana/Info.plist", "Banana/InfoBeta.plist"] {
            let declared = try modes(plist)
            XCTAssertTrue(declared.contains("location"), plist)
            XCTAssertTrue(declared.contains("audio"), plist)
        }
    }
}

