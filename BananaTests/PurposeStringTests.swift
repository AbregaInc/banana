import XCTest

/// Every protected resource the iPhone app's code asks for has its purpose string in the app's
/// Info.plist (`project.yml`). Without one, iOS ignores the request or kills the app at the first
/// use, and App Store Connect refuses the build (ITMS-90683). Build 52's upload was refused for
/// `NSMotionUsageDescription`: "Learn from my trips" had asked for Motion and Always location
/// since it was written, and neither string was there.
final class PurposeStringTests: XCTestCase {
    /// How an API is written in source, and the Info.plist key asking for it needs.
    private static let needs: [(marker: String, key: String)] = [
        ("CMMotionActivityManager(", "NSMotionUsageDescription"),
        ("CMPedometer(", "NSMotionUsageDescription"),
        ("requestAlwaysAuthorization(", "NSLocationAlwaysAndWhenInUseUsageDescription"),
        ("requestWhenInUseAuthorization(", "NSLocationWhenInUseUsageDescription"),
        ("CNContactStore(", "NSContactsUsageDescription"),
        ("PHPhotoLibrary.requestAuthorization", "NSPhotoLibraryUsageDescription"),
        ("SFSpeechRecognizer.requestAuthorization", "NSSpeechRecognitionUsageDescription"),
        ("AVCaptureDevice.requestAccess", "NSCameraUsageDescription"),
        ("NWBrowser(", "NSLocalNetworkUsageDescription"),
    ]

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// The keys the iPhone app's sources call for: `Banana/` and `Shared/` are what it compiles.
    private func keysTheSourcesNeed() throws -> [String: String] {
        var needed: [String: String] = [:]   // key → the first file that needs it
        for folder in ["Banana", "Shared"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder),
                                                       includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for need in Self.needs where needed[need.key] == nil && source.contains(need.marker) {
                    needed[need.key] = file.lastPathComponent
                }
            }
        }
        return needed
    }

    /// One target's block of `project.yml`: from its `  Name:` line to the next target's.
    private func target(_ name: String) throws -> String {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let targets = try XCTUnwrap(project.range(of: "\ntargets:\n"), "project.yml has no targets")
        let rest = project[targets.upperBound...]
        let start = try XCTUnwrap(rest.range(of: "  \(name):\n"), "no target \(name)")
        let body = rest[start.upperBound...]
        let end = body.range(of: #"\n  [A-Za-z]+:\n"#, options: .regularExpression)?.lowerBound ?? body.endIndex
        return String(body[..<end])
    }

    func testTheSourcesAreReadAndTripLearningIsAmongThem() throws {
        let needed = try keysTheSourcesNeed()
        XCTAssertEqual(needed["NSMotionUsageDescription"], "TripLearningService.swift")
        XCTAssertNotNil(needed["NSLocationAlwaysAndWhenInUseUsageDescription"])
        XCTAssertNotNil(needed["NSLocationWhenInUseUsageDescription"])
    }

    func testTheiPhoneAppDeclaresEveryPurposeItsCodeAsksFor() throws {
        let needed = try keysTheSourcesNeed()
        for name in ["Banana", "BananaBeta"] {
            let plist = try target(name)
            XCTAssertTrue(plist.contains("PRODUCT_BUNDLE_IDENTIFIER"), "\(name) isn't an app target's block")
            for (key, file) in needed.sorted(by: { $0.key < $1.key }) {
                XCTAssertTrue(plist.contains("        \(key): \""),
                              "\(name) has no \(key), which \(file) needs")
            }
        }
    }
}
