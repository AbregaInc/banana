import XCTest

/// Measurement harness for the "are we overdrawing the stroke signature" investigation (see
/// `WorkoutMotionSection.MotionSignatureCard`'s `maxSignaturePoints` doc comment and
/// `HandPathScene`'s file doc comment). Drives a real `XCUIApplication` drag over each 3D view —
/// `Chart3D` (the signature) and `Canvas` (the hand path) — while `FrameProbe` (`FrameProbe.swift`,
/// `--frame-probe`) reports measured on-screen fps/hitch counts into the playback journal, so the
/// two rendering approaches can be compared like-for-like on the SAME real recording instead of
/// guessed at. Same `--workout-detail latest-swim` route and `XCTSkip`-if-absent pattern as
/// `WorkoutDetailScrollUITest` — this needs a real local pool swim to run against, and reports
/// nothing false-positive on a checkout that doesn't have one.
///
/// This test does not assert on the fps numbers themselves — a Simulator's frame delivery is not
/// the owner's real iPhone, and the honest comparison is the numbers this test's run leaves in the
/// journal, read back and reported by hand (see the investigation this accompanies). Its job is
/// only to reliably produce a sustained, real interactive drag over each view so a human (or a
/// later, calibrated assertion) has real numbers to look at.
final class MotionRenderFrameProbeUITest: XCTestCase {
    override func setUpWithError() throws {
        try Self.seedRealSwimFixtureIfAvailable()
    }

    /// `xcodebuild test` reinstalls the app fresh for every invocation — that wipes whatever a
    /// prior Bash-level `simctl install` seeded into the OLD container, and the freshly assigned
    /// container id isn't knowable until after install. `setUpWithError` runs after Xcode's own
    /// install phase but before this test's `app.launch()`, so seeding here lands before
    /// `FitnessStore.init()` ever reads `summaries.json`, instead of racing it. Finds the just-
    /// installed container the same way a human would from a shell — `xcrun simctl get_app_container
    /// booted com.boris.banana data` — rather than guessing at it from environment variables or
    /// directory timestamps, both of which proved unreliable here: this process is an ordinary,
    /// unsandboxed macOS process (not a sandboxed iOS app), so shelling out to `simctl` and reading
    /// its stdout works exactly like it does from Terminal.
    ///
    /// Copies the real, host-machine swim fixture the investigation this test supports was
    /// measured against (`BFCCD614…`, 72 laps) — read-only from the owner's actual Fitness
    /// directory, written only into the Simulator's own isolated container, never anywhere under
    /// the host's real `~/Library/Application Support`. Silently does nothing if that fixture
    /// isn't present on this machine (nothing here fabricates data) or if the container can't be
    /// located — `waitForExistence`'s `XCTSkip` in each test method is what turns that into a
    /// clean skip rather than a false failure.
    private static func seedRealSwimFixtureIfAvailable() throws {
        // `FileManager.homeDirectoryForCurrentUser` is unavailable in the iOS SDK this test
        // target compiles against, even though this process actually runs as an ordinary macOS
        // process on the host Mac (see this method's doc comment) — `NSHomeDirectory()` is the
        // portable equivalent and resolves to the same real path here.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let sourceSummaries = home.appendingPathComponent("Library/Application Support/Fitness/summaries.json")
        let sourceSample = home.appendingPathComponent(
            "Library/Application Support/Fitness/BFCCD614-3E26-4BA3-870A-B88CFDBCC931.samples")
        guard FileManager.default.fileExists(atPath: sourceSummaries.path),
              FileManager.default.fileExists(atPath: sourceSample.path),
              let container = containerPath() else { return }

        let fitnessDir = container.appendingPathComponent("Library/Application Support/Fitness")
        try FileManager.default.createDirectory(at: fitnessDir, withIntermediateDirectories: true)
        let destSample = fitnessDir.appendingPathComponent(sourceSample.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destSample.path) {
            try FileManager.default.copyItem(at: sourceSample, to: destSample)
        }

        // Only this one workout's summary — matches `WorkoutDetailScrollUITest`'s own
        // `latest-swim` fixture requirement without pulling in the owner's entire history.
        let data = try Data(contentsOf: sourceSummaries)
        guard let all = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let entry = all.first(where: { ($0["id"] as? String)?.uppercased().hasPrefix("BFCCD614") == true })
        else { return }
        let filtered = try JSONSerialization.data(withJSONObject: [entry])
        try filtered.write(to: fitnessDir.appendingPathComponent("summaries.json"), options: .atomic)
    }

    /// Finds this app's simulator data container the same way `xcrun simctl get_app_container`
    /// does internally, without shelling out to it — `Foundation.Process` is unavailable on the
    /// iOS SDK this test target builds against (this file is compiled for iOS even though it
    /// happens to run as a plain macOS process), so a subprocess isn't an option here even though
    /// this process could otherwise run one. Instead: every simulator app container carries a
    /// `.com.apple.mobile_container_manager.metadata.plist` naming its bundle id
    /// (`MCMMetadataIdentifier`) — reading that plist is ordinary file I/O, legal on any SDK.
    /// Scans every booted-or-not simulator device rather than requiring a specific one (multiple
    /// simulators can have this app installed); if more than one match exists, the most recently
    /// modified one is the one this run just installed into.
    private static func containerPath() -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let devicesDir = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        guard let devices = try? FileManager.default.contentsOfDirectory(at: devicesDir, includingPropertiesForKeys: nil) else { return nil }

        var best: (url: URL, modified: Date)?
        for device in devices {
            let appsDir = device.appendingPathComponent("data/Containers/Data/Application")
            guard let containers = try? FileManager.default.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil) else { continue }
            for container in containers {
                let metadataURL = container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
                guard let plistData = try? Data(contentsOf: metadataURL),
                      let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                      plist["MCMMetadataIdentifier"] as? String == "com.boris.banana" else { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: container.path)
                let stamp = (attrs?[.modificationDate] as? Date) ?? .distantPast
                if best == nil || stamp > best!.modified {
                    best = (container, stamp)
                }
            }
        }
        return best?.url
    }

    func testSignatureChart3DFrameProbeDuringDrag() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workout-detail", "latest-swim", "--motion-mode", "signature",
                                "--frame-probe", "-onboardingCompleted", "YES"]
        let launchStart = Date()
        app.withoutSpaceSync()
        app.launch()

        let inlineChart = app.otherElements["workout.motionSignatureChart"]
        guard inlineChart.waitForExistence(timeout: 20) else {
            throw XCTSkip("No local pool swim with detected cycles on this Simulator/account — nothing to drag against.")
        }
        // Wall-clock time from `app.launch()` to the signature chart existing in the accessibility
        // tree — the same "time to interactive" the owner experiences, cold (no disk cache yet for
        // this workout) on this test's first run against a freshly seeded container, warm (a disk
        // cache the app itself just wrote) on any run after. Printed, not asserted: a Simulator run
        // isn't the owner's iPhone, so this is read by hand alongside the other measurements rather
        // than gated on here.
        print("MOTION_TIMING signature time_to_interactive_ms=\(Int(Date().timeIntervalSince(launchStart) * 1000))")
        // The inline iOS card renders a FIXED pose (see `MotionSignatureCard.signature`'s doc
        // comment) — tapping opens the sheet where `$pose` is actually draggable.
        inlineChart.tap()

        let expandedChart = app.otherElements["workout.motionSignatureChart"]
        guard expandedChart.waitForExistence(timeout: 5) else {
            throw XCTSkip("expanded 3D acceleration signature sheet did not appear")
        }
        drag(over: expandedChart, in: app, seconds: 5)
    }

    func testHandPathCanvasFrameProbeDuringDrag() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--workout-detail", "latest-swim", "--motion-mode", "handpath",
                                "--frame-probe", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let inlineCanvas = app.otherElements["workout.handPathCanvas"]
        guard inlineCanvas.waitForExistence(timeout: 20) else {
            throw XCTSkip("No local pool swim with a hand path on this Simulator/account — nothing to drag against.")
        }
        inlineCanvas.tap()

        let expandedCanvas = app.otherElements["workout.handPathCanvas.expanded"]
        guard expandedCanvas.waitForExistence(timeout: 5) else {
            throw XCTSkip("expanded hand path sheet did not appear")
        }
        drag(over: expandedCanvas, in: app, seconds: 5)
    }

    /// Several short back-and-forth drags rather than one long one — `press(forDuration:
    /// thenDragTo:)` synthesizes a bounded sequence of touch-move events per call
    /// (`WorkoutDetailScrollUITest` establishes this technique for this codebase); chaining several
    /// keeps the pose/camera changing continuously for the full duration instead of one gesture
    /// followed by a static hold.
    private func drag(over element: XCUIElement, in app: XCUIApplication, seconds: TimeInterval) {
        let frame = element.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let deadline = Date().addingTimeInterval(seconds)
        var goRight = true
        while Date() < deadline {
            let dx: CGFloat = goRight ? 90 : -90
            let start = origin.withOffset(CGVector(dx: frame.midX - dx / 2, dy: frame.midY))
            let end = origin.withOffset(CGVector(dx: frame.midX + dx / 2, dy: frame.midY))
            start.press(forDuration: 0.05, thenDragTo: end)
            goRight.toggle()
        }
    }
}
