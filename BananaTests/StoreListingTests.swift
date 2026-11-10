import XCTest

/// The App Store listing's own rules, read from the files that carry it (`tools/app-store`):
/// Apple's field limits, a keyword field that doesn't spend itself on words the name and
/// subtitle already hold, a screenshot set for every device the app runs on, and a Mac capture
/// that can't touch the data of the Banana installed on the Mac.
final class StoreListingTests: XCTestCase {
    private static let tool = SourceTree.root
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
        // The website tagline can lead the subtitle; the calendar and the name of every module
        // the listed app can turn on still need coverage across the fields Apple indexes,
        // without duplicating subtitle words. The names come from the modules themselves, so a
        // renamed or added module is a listing to update, not a test to edit.
        let indexed = words(try field("name") + " " + field("subtitle") + " " + field("keywords"))
        // This listing is Stable's: every module but Email, which follows its own switch.
        let listed = try ModuleSettings.modules("BANANA_ALL_MODULES")
        XCTAssertFalse(listed.isEmpty)
        var wanted: Set<String> = ["calendar"]
        for module in listed { wanted.formUnion(words(module.rawValue)) }
        XCTAssertTrue(indexed.isSuperset(of: wanted), "missing \(wanted.subtracting(indexed).sorted()) in \(indexed.sorted())")
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
        // And the App Store app's own listing and set.
        text += "\n" + (try ["description", "promotional_text", "whats_new", "subtitle", "keywords"]
            .map(appStoreField).joined(separator: "\n"))
        for platform in ["iphone", "ipad", "mac"] {
            for scene in try flavour()["\(platform)_scenes"] as? [[String: Any]] ?? [] {
                text += "\n" + ["headline", "subhead", "eyebrow"].compactMap { scene[$0] as? String }.joined(separator: "\n")
                XCTAssertFalse((scene["route"] as? [String] ?? []).contains("--today"), "\(platform): the retired Today screen")
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
        // Apple's sizes for each device held its usual way up; a set captured on its side
        // (`<platform>_orientation` is landscape_left or landscape_right, which the generator
        // rotates the device to) is the same size turned, long side first.
        for (platform, size) in [("iphone", [1320, 2868]), ("ipad", [2064, 2752]), ("watch", [416, 496]), ("mac", [2880, 1800])] {
            let scenes = try XCTUnwrap(manifest["\(platform)_scenes"] as? [[String: Any]], "no \(platform) set")
            XCTAssertTrue((1...10).contains(scenes.count), "\(platform): \(scenes.count) screenshots, Apple takes one to ten")
            let ids = scenes.compactMap { $0["id"] as? String }
            XCTAssertEqual(Set(ids).count, scenes.count, "\(platform): two scenes share a file name")
            let orientation = capture["\(platform)_orientation"] as? String ?? "portrait"
            XCTAssertTrue(["portrait", "landscape_left", "landscape_right"].contains(orientation), "\(platform): \(orientation)")
            let expected = orientation.hasPrefix("landscape") ? [size.max()!, size.min()!] : size
            XCTAssertEqual(capture["\(platform)_size"] as? [Int], expected, "\(platform): not the size Apple asks for")
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

    // MARK: - The App Store app's own listing (calendar-only)

    private func appStoreField(_ name: String) throws -> String {
        try String(contentsOf: Self.tool.appendingPathComponent("metadata/calendar-only/en-US/\(name).txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The listing for the App Store configuration describes the modules it carries
    /// (BANANA_APP_STORE_MODULES) and no other: no module it leaves out is named or searched for.
    func testTheAppStoreListingNamesOnlyWhatItsBuildCarries() throws {
        XCTAssertLessThanOrEqual(try appStoreField("name").count, 30)
        XCTAssertLessThanOrEqual(try appStoreField("subtitle").count, 30)
        XCTAssertLessThanOrEqual(try appStoreField("promotional_text").count, 170)
        XCTAssertLessThanOrEqual(try appStoreField("description").count, 4000)
        XCTAssertLessThanOrEqual(try appStoreField("keywords").utf8.count, 100)
        let carried = Set(try ModuleSettings.modules("BANANA_APP_STORE_MODULES"))
        let listing = words(try ["name", "subtitle", "keywords", "promotional_text", "description", "whats_new"]
            .map(appStoreField).joined(separator: " "))
        XCTAssertTrue(listing.contains("calendar"))
        for module in AppModule.allCases where !carried.contains(module) {
            XCTAssertFalse(listing.contains(words(module.rawValue).first ?? module.rawValue), "\(module) is left out of this build")
        }
        let indexed = words(try appStoreField("name")).union(words(try appStoreField("subtitle")))
        for keyword in try appStoreField("keywords").split(separator: ",") {
            XCTAssertTrue(words(String(keyword)).isDisjoint(with: indexed), "\(keyword) is already in the name or subtitle")
        }
        let keywords = try appStoreField("keywords").split(separator: ",").map(String.init)
        XCTAssertEqual(Set(keywords).count, keywords.count, "a keyword is listed twice")
        for url in ["support_url", "marketing_url", "privacy_url"] {
            XCTAssertTrue(try appStoreField(url).hasPrefix("https://"), url)
        }
    }

    // MARK: - The App Store app's screenshots (flavours/calendar-only.json)

    private func flavour() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.tool.appendingPathComponent("flavours/calendar-only.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The module a capture route opens, for the routes that open one (RootView's DEBUG routes).
    private static let moduleRoutes: [String: AppModule] = [
        "--wellness": .food, "--nutrition-week": .food, "--food-search": .food, "--my-foods": .food,
        "--energy-balance": .food, "--scan-correct-preview": .food, "--meal-backlog": .food,
        "--library": .podcasts, "--library-detail": .podcasts, "--listenmap": .podcasts,
        "--transcript-demo": .podcasts, "--now-playing": .podcasts, "--sample-episode": .podcasts,
        "--notes": .notes, "--voicenote-demo": .notes,
        "--workout": .workouts, "--dummy-health": .workouts, "--sleep": .workouts, "--trends": .workouts,
        "--trend": .workouts, "--workouts-route": .workouts, "--workout-review": .workouts, "--trim": .workouts,
        "--mail": .email, "--mail-fresh": .email,
    ]

    /// Its build is made with exactly the App Store app's modules, and the generator refuses a
    /// build that carries any other set (`check_modules`), so no capture can show a module.
    func testTheAppStoreSetIsCapturedFromABuildWithItsModules() throws {
        let flavour = try flavour()
        XCTAssertEqual(flavour["modules_setting"] as? String, "BANANA_APP_STORE_MODULES")
        let xcconfig = try String(contentsOf: SourceTree.root.appendingPathComponent(try XCTUnwrap(flavour["xcconfig"] as? String)),
                                  encoding: .utf8)
        XCTAssertTrue(xcconfig.contains("BANANA_MODULES[sdk=iphonesimulator*] = $(BANANA_APP_STORE_MODULES)"))
        XCTAssertTrue(xcconfig.contains("BANANA_MODULES[sdk=macosx*] = $(BANANA_APP_STORE_MODULES)"))
        let generator = try String(contentsOf: Self.tool.appendingPathComponent("generate.py"), encoding: .utf8)
        XCTAssertTrue(generator.contains("check_modules(manifest, app / \"Info.plist\")"))
        XCTAssertTrue(generator.contains("check_modules(manifest, app / \"Contents/Info.plist\")"))
    }

    /// Every scene opens a screen the App Store app has, says nothing about a module it leaves
    /// out, and there is a set for each device it runs on and none for one it doesn't.
    func testTheAppStoreSetShowsOnlyWhatItsBuildCarries() throws {
        let flavour = try flavour()
        let carried = Set(try ModuleSettings.modules("BANANA_APP_STORE_MODULES"))
        // The Watch app serves only Workouts and Podcasts: without either it is left out.
        let hasWatch = !carried.isDisjoint(with: [.workouts, .podcasts])
        XCTAssertEqual(flavour["watch_scenes"] != nil, hasWatch, "a Watch set only with a Watch app")
        let left = AppModule.allCases.filter { !carried.contains($0) }
        let leftWords = Set(left.flatMap { words($0.rawValue).union(words($0.title)) })
            .subtracting(["and"])
        for platform in ["iphone", "ipad", "mac"] {
            let scenes = try XCTUnwrap(flavour["\(platform)_scenes"] as? [[String: Any]], "no \(platform) set")
            XCTAssertTrue((1...10).contains(scenes.count), "\(platform): Apple takes one to ten")
            let ids = scenes.compactMap { $0["id"] as? String }
            XCTAssertEqual(Set(ids).count, scenes.count, "\(platform): two scenes share a file name")
            for scene in scenes {
                let id = scene["id"] as? String ?? "?"
                let route = scene["route"] as? [String] ?? []
                for argument in route {
                    if let module = Self.moduleRoutes[argument] {
                        XCTAssertTrue(carried.contains(module), "\(platform) \(id) opens \(module), which this build leaves out")
                    }
                }
                // The tab (`--tab`) or the Mac's sidebar section (`section`) it opens.
                let tab = route.firstIndex(of: "--tab").flatMap { route.indices.contains($0 + 1) ? route[$0 + 1] : nil }
                for name in [tab, scene["section"] as? String].compactMap({ $0 }) {
                    let section = try XCTUnwrap(AppSection(rawValue: name), "\(platform) \(id): no section \(name)")
                    XCTAssertTrue(section.module.map(carried.contains) ?? true, "\(platform) \(id) opens \(section)")
                }
                if let at = route.firstIndex(of: "-planMode"), at + 1 < route.count {
                    XCTAssertTrue(["day", "week"].contains(route[at + 1]), "\(platform) \(id): Plan is Day and Week")
                }
                let caption = words(["headline", "subhead", "eyebrow"].compactMap { scene[$0] as? String }.joined(separator: " "))
                XCTAssertTrue(caption.isDisjoint(with: leftWords), "\(platform) \(id) names \(caption.intersection(leftWords).sorted())")
                // Guideline 5.2.5: a forecast in a screenshot shows Apple Weather's mark, which
                // sits under the week, so the forecast opens scrolled to it.
                if route.contains("--weather-detail") || route.contains("--open-weather") {
                    XCTAssertTrue(route.contains("--scroll-bottom"), "\(platform) \(id): the forecast without Apple Weather's mark")
                }
            }
        }
    }

    /// The App Store app asks for location only while in use (the forecast, travel time): trip
    /// learning, with Always location and Motion, is a feature it leaves out (Config/Modules.json),
    /// so its derived Info.plists have neither usage string. Beta and Stable keep it.
    /// The App Store app is a Google Calendar client alone: Booking (the link, its types, its
    /// pushes) is a feature it leaves out, with markers check-release refuses. Beta and Stable keep it.
    func testTheAppStoreAppLeavesBookingOut() throws {
        let settings = try ModuleSettings.read()
        XCTAssertTrue(try XCTUnwrap(settings["BANANA_ALL_MODULES"]).contains("BANANA_FEATURE_BOOKING"))
        XCTAssertFalse(try XCTUnwrap(settings["BANANA_APP_STORE_MODULES"]).contains("BANANA_FEATURE_BOOKING"))
        let map = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            SourceTree.root.appendingPathComponent("Config/Modules.json"))) as? [String: Any])
        let booking = try XCTUnwrap((map["features"] as? [String: Any])?["booking"] as? [String: Any])
        XCTAssertEqual(booking["condition"] as? String, "BANANA_FEATURE_BOOKING")
        XCTAssertFalse((booking["markers"] as? [String] ?? []).isEmpty)
    }

    func testTheAppStoreAppLeavesTripLearningOut() throws {
        let settings = try ModuleSettings.read()
        XCTAssertTrue(try XCTUnwrap(settings["BANANA_ALL_MODULES"]).contains("BANANA_FEATURE_TRIP_LEARNING"))
        XCTAssertFalse(try XCTUnwrap(settings["BANANA_APP_STORE_MODULES"]).contains("BANANA_FEATURE_TRIP_LEARNING"))
        for name in ["Banana-AppStore-Info.plist", "BananaMac-AppStore-Info.plist"] {
            let url = SourceTree.root.appendingPathComponent("Config/Generated/\(name)")
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            XCTAssertNil(plist["NSLocationAlwaysAndWhenInUseUsageDescription"], name)
            XCTAssertNil(plist["NSMotionUsageDescription"], name)
            XCTAssertNotNil(plist["NSLocationWhenInUseUsageDescription"], "\(name): the forecast and travel time still need it")
        }
        let notes = try appStoreField("review_notes")
        XCTAssertFalse(notes.contains("Learn from my trips"), "the review notes describe a feature the build leaves out")
    }
}
