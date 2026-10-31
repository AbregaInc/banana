import XCTest
import Vision

/// A routine moment on the calendar — the wake-up, wind down — shows its time, and a tap on it
/// says exactly when and why. It showed only its name, and a tap opened the routine's settings.
final class CueTimeUITest: XCTestCase {
    func testAMomentShowsItsTimeAndATapSaysWhen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--day", "-planMode", "day", "--reset-day-scroll-offset", "--disable-icloud", "--no-space-sync", "--ui-audit", "-onboardingCompleted", "YES"]
        app.withoutSpaceSync()
        app.launch()

        let cue = try revealCalendarButton("Wind", in: app)
        let image = cue.screenshot()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(data: image.pngRepresentation).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let compact = recognized.lowercased().replacingOccurrences(of: ":00", with: "").filter { $0.isLetter || $0.isNumber }
        XCTAssertTrue(compact.contains("9pm"), "Rendered moment must include its 9 PM time: \(recognized)")
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "Compact routine visibly includes its time"
        attachment.lifetime = .keepAlways
        add(attachment)
        cue.tap()

        let sheetTime = app.staticTexts["cueSheet.time"]
        XCTAssertTrue(sheetTime.waitForExistence(timeout: 3), "the tap opens the moment, with its time")
        XCTAssertTrue(sheetTime.label.contains(":"), sheetTime.label)
        XCTAssertTrue(app.buttons["Skip this one"].exists || app.buttons["Restore"].exists)
        app.buttons["Done"].tap()
    }
}
