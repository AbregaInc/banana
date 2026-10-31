import XCTest

/// The App Store listing's own rules, read from the files that carry it (`tools/app-store`):
/// Apple's field limits, a keyword field that doesn't spend itself on words the name and
/// subtitle already hold, a screenshot set for every device the app runs on, and a Mac capture
/// that can't touch the data of the Banana installed on the Mac.
final class StoreListingTests: XCTestCase {
    private static let tool = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/app-store")

    private func field(_ name: String) throws -> String {
        try String(contentsOf: Self.tool.appendingPathComponent("metadata/en-US/\(name).txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.tool.appendingPathComponent("manifest.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Lowercased words, a plural counted as its singular ("Podcasts" is "podcast").
    private func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map { word in
            word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : String(word)
        })
    }

    func testTheFieldsFitApplesLimits() throws {
        XCTAssertLessThanOrEqual(try field("name").count, 30)
        XCTAssertLessThanOrEqual(try field("subtitle").count, 30)
        XCTAssertLessThanOrEqual(try field("promotional_text").count, 170)
        XCTAssertLessThanOrEqual(try field("description").count, 4000)
        // The keyword field is counted in bytes.
        XCTAssertLessThanOrEqual(try field("keywords").utf8.count, 100)
    }

    func testIndexedFieldsCoverTheCalendarAndOptionalModules() throws {
        // The website tagline can lead the subtitle; searchable module names still need
        // coverage across the fields Apple indexes, without duplicating subtitle words.
        let indexed = words(try field("name") + " " + field("subtitle") + " " + field("keywords"))
        XCTAssertTrue(indexed.isSuperset(of: ["calendar", "podcast", "fitness", "food", "sleep", "note"]), "\(indexed)")
    }

    func testNoKeywordRepeatsAWordOfTheNameOrSubtitle() throws {
        // Apple indexes the name and subtitle already: a repeat buys nothing and costs room.
        let indexed = words(try field("name")).union(words(try field("subtitle")))
        let keywords = try field("keywords").split(separator: ",").map(String.init)
        XCTAssertFalse(keywords.isEmpty)
        for keyword in keywords {
            XCTAssertTrue(words(keyword).isDisjoint(with: indexed), "\(keyword) is already in the name or subtitle")
        }
        XCTAssertEqual(Set(keywords).count, keywords.count, "a keyword is listed twice")
    }

    func testTheListingPromisesNothingTheAppNoLongerHas() throws {
        // Switched off or removed on 8 Oct 2026: guided workout plans, Re-plan, Plan's List, the
        // bedside clock and the workout flyover. The copy and the captions are read, and so are
        // the scenes: one that opens a retired screen photographs what nobody can reach.
        let retired = ["guided plan", "strength or stretch", "form guide", "re-plan", "replan",
                       "bedside", "standby", "flyover", "workout plan"]
        var text = try ["description", "promotional_text", "whats_new", "subtitle", "keywords"]
            .map(field).joined(separator: "\n")
        let manifest = try manifest()
        for platform in ["iphone", "ipad", "watch", "mac"] {
            for scene in try XCTUnwrap(manifest["\(platform)_scenes"] as? [[String: Any]]) {
                let id = scene["id"] as? String ?? "?"
                text += "\n" + ["headline", "subhead", "eyebrow"].compactMap { scene[$0] as? String }.joined(separator: "\n")
                let route = scene["route"] as? [String] ?? []
                XCTAssertFalse(id.contains("guided"), "\(platform) \(id)")
                // `--workouts-route plan` opened guided plans; `--today` a screen with no way in.
                if let at = route.firstIndex(of: "--workouts-route"), at + 1 < route.count {
                    XCTAssertFalse(["plan", "guided-plans"].contains(route[at + 1]), "\(platform) \(id) opens guided plans")
                }
                XCTAssertFalse(route.contains("--today"), "\(platform) \(id) opens the retired Today screen")
                if let at = route.firstIndex(of: "-planMode"), at + 1 < route.count {
                    XCTAssertTrue(["day", "week"].contains(route[at + 1]), "\(platform) \(id): Plan is Day and Week")
                }
            }
        }
        let lowered = text.lowercased()
        for words in retired {
            XCTAssertFalse(lowered.contains(words), "the listing still says \u{201C}\(words)\u{201D}")
        }
    }

    func testTheDescriptionSaysBananaGivesNoMedicalAdvice() throws {
        // Sleep, heart rate, supplements and medication are shown, not interpreted.
        XCTAssertTrue(try field("description").contains("does not give medical advice"))
    }

    func testEveryDeviceTheAppRunsOnHasAScreenshotSet() throws {
        let manifest = try manifest()
        let capture = try XCTUnwrap(manifest["capture"] as? [String: Any])
        for (platform, size) in [("iphone", [1320, 2868]), ("ipad", [2064, 2752]), ("watch", [416, 496]), ("mac", [2880, 1800])] {
            let scenes = try XCTUnwrap(manifest["\(platform)_scenes"] as? [[String: Any]], "no \(platform) set")
            XCTAssertTrue((1...10).contains(scenes.count), "\(platform): \(scenes.count) screenshots, Apple takes one to ten")
            let ids = scenes.compactMap { $0["id"] as? String }
            XCTAssertEqual(Set(ids).count, scenes.count, "\(platform): two scenes share a file name")
            XCTAssertEqual(capture["\(platform)_size"] as? [Int], size, "\(platform): not the size Apple asks for")
        }
    }

    func testTheMacCaptureRunsTheBetaNeverTheDailyApp() throws {
        // The daily app's own target, built unsigned, has the installed app's identity and its
        // files in ~/Library/Application Support. Beta keeps its own (`AppSupport.directory`).
        let generator = try String(contentsOf: Self.tool.appendingPathComponent("generate.py"), encoding: .utf8)
        XCTAssertTrue(generator.contains(#""-scheme", "BananaMacBeta""#))
        XCTAssertFalse(generator.contains(#""-scheme", "BananaMac","#))
        XCTAssertFalse(generator.contains("CODE_SIGNING_ALLOWED=NO"))
    }
}
