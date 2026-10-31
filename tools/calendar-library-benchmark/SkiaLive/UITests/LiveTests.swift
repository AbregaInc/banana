import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
final class LiveTests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(macOS)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settingsURL = root.appendingPathComponent(".build/calendar-live-20261009/test-input.json")
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: String]
        app = XCUIApplication(url: URL(fileURLWithPath: settings["app"]!))
        app.launchArguments = ["--fixture", "varied-v1", "--mode", "week", "--days", "365", "--density", settings["density"]!,
            "--seed", settings["seed"]!, "--log", settings["log"]!]
        app.launch()
        #else
        app = XCUIApplication(bundleIdentifier: "com.boris.banana.calendar-metal-review")
        XCTAssertNotEqual(app.state, .notRunning, "Launch the isolated fixture before testing")
        app.activate()
        #endif
        XCTAssertTrue(app.buttons["live.next"].waitForExistence(timeout: 10))
        waitReady()
    }
    func label(_ element: XCUIElement) -> String {
        #if os(macOS)
        return element.value as? String ?? element.label
        #else
        return element.label
        #endif
    }
    func waitReady() {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            return !self.label(self.app.staticTexts["live.date"]).contains("Preparing")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
    func press(_ identifier: String) {
        #if os(macOS)
        app.buttons[identifier].click()
        #else
        app.buttons[identifier].tap()
        #endif
    }
    func testScrollPagingAndEviction() {
        let original = label(app.staticTexts["live.date"])
        let timeline = app.scrollViews["live.timeline"]
        XCTAssertTrue(timeline.exists)
        for _ in 0..<6 {
            #if os(macOS)
            timeline.scroll(byDeltaX: 0, deltaY: -400)
            timeline.scroll(byDeltaX: 0, deltaY: 400)
            #else
            timeline.swipeUp(); timeline.swipeDown()
            #endif
        }
        for _ in 0..<3 {
            press("live.next"); waitReady()
            XCTAssertNotEqual(label(app.staticTexts["live.date"]), original)
        }
        press("live.clear"); waitReady()
        for _ in 0..<3 { press("live.previous"); waitReady() }
        XCTAssertEqual(label(app.staticTexts["live.date"]), original)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Metal-calendar-after-scroll-pages-eviction"; attachment.lifetime = .keepAlways; add(attachment)
    }
    #if os(iOS)
    private func timelinePixels(_ name: String) -> Data {
        let shot = app.scrollViews["live.timeline"].screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let source = shot.image.cgImage!
        // Exclude only the trailing scroll-indicator band. Canonical zero-filled
        // RGBA storage avoids PNG metadata and uninitialized row-padding differences.
        let width = source.width - 36, height = source.height
        var bytes = Data(count: width*height*4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: height))
        }
        return bytes
    }
    func testPixelsAfterPagingAndEviction() {
        // A fresh process starts at offset zero; this scenario does not inherit
        // gesture-dependent final offsets from the separate scrolling scenario.
        let initial = timelinePixels("initial-page")
        press("live.next"); waitReady()
        XCTAssertNotEqual(timelinePixels("next-page"), initial, "The content must change, not just the heading")
        press("live.previous"); waitReady()
        XCTAssertEqual(timelinePixels("restored-page"), initial)
        press("live.clear"); waitReady()
        XCTAssertEqual(timelinePixels("after-eviction"), initial)
    }
    #endif
}
