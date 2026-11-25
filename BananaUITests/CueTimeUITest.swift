import CoreImage
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
        let png = image.pngRepresentation
        let recognized = try recognizedText(VNImageRequestHandler(data: png))
        var preview = recognized
        // Vision can read a small rendered 9 as 0 in the narrow element screenshot.
        // Check the same pixels at a larger scale before calling the time missing.
        if !containsNinePM(recognized), let ciImage = CIImage(data: png) {
            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 1.5, y: 1.5))
            if let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) {
                preview = try recognizedText(VNImageRequestHandler(cgImage: cgImage))
            }
        }
        XCTAssertTrue(containsNinePM(preview), "Rendered moment must include its 9 PM time: \(preview)")
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "Compact routine visibly includes its time"
        attachment.lifetime = .keepAlways
        add(attachment)
        cue.tap()

        let sheetTime = app.staticTexts["cueSheet.time"]
        XCTAssertTrue(sheetTime.waitForExistence(timeout: 3), "the tap opens the moment, with its time")
        XCTAssertTrue(sheetTime.label.contains(":"), sheetTime.label)
        XCTAssertTrue(app.buttons["Skip this one"].exists || app.buttons["Restore"].exists)
        app.buttons["sheet.close"].tap()
    }

    private func recognizedText(_ handler: VNImageRequestHandler) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func containsNinePM(_ recognized: String) -> Bool {
        recognized.lowercased().replacingOccurrences(of: ":00", with: "")
            .filter { $0.isLetter || $0.isNumber }.contains("9pm")
    }
}
