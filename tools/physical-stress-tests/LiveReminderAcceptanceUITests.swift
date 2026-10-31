import XCTest

/// Explicitly selected checks against the installed main app and the owner's real sync.
/// Creates only the uniquely labeled QA note below; no fixture accounts or calendar invites.
/// Opt in with TEST_RUNNER_BANANA_LIVE_REMINDER_ACCEPTANCE=1 and select methods explicitly.
final class LiveReminderAcceptanceUITests: XCTestCase {
    private let marker = "Banana release QA e54dc76a"
    private var edited: String { marker + " updated on iPad" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANANA_LIVE_REMINDER_ACCEPTANCE"] == "1",
                          "Real-data note checks require explicit opt-in and ordered device selection")
    }

    private func notes(_ app: XCUIApplication) {
        app.activate()
        XCTAssertFalse(app.textViews["notes.composer"].exists,
                       "Leave an existing user draft untouched")
        let tab = app.buttons["Notes"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15), app.debugDescription)
        tab.tap()
    }

    private func evidence(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }

    func testCreateAndRelaunchNote() {
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana")
        notes(app)
        XCTAssertFalse(app.staticTexts[marker].firstMatch.exists,
                       "Do not create a second QA note on a retry")
        let add = app.buttons["notes.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        let write = app.buttons["notes.write"].firstMatch
        XCTAssertTrue(write.waitForExistence(timeout: 5)); write.tap()
        let editor = app.textViews["notes.composer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String ?? "").isEmpty,
                      "Never replace an existing draft")
        editor.tap(); editor.typeText(marker)
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[marker].firstMatch.waitForExistence(timeout: 15))
        app.terminate(); app.launch()
        notes(app)
        XCTAssertTrue(app.staticTexts[marker].firstMatch.waitForExistence(timeout: 20),
                      "The saved note survives process relaunch")
        evidence(app, "live-note-after-relaunch")
    }

    func testPadReceivesAndEditsSameNote() {
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana")
        notes(app)
        let row = app.staticTexts[marker].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "Wait for the real cross-device import, without seeding data")
        row.tap()
        let more = app.buttons["notes.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        let edit = app.buttons["notes.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let editor = app.textViews["notes.composer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, marker)
        editor.tap(); editor.typeText(" updated on iPad")
        app.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[edited].firstMatch.waitForExistence(timeout: 20))
        evidence(app, "pad-live-note-edited")
    }

    func testPhoneReceivesEditedNote() {
        let app = XCUIApplication(bundleIdentifier: "com.boris.banana")
        notes(app)
        XCTAssertTrue(app.staticTexts[edited].firstMatch.waitForExistence(timeout: 60))
        evidence(app, "phone-live-note-round-trip")
    }
}
