import XCTest

/// Selection must survive iPad rotation, with creation actions reachable in both arrangements.
final class NotesAdaptiveUITest: XCTestCase {
    private var app: XCUIApplication!
    private let second = "99A5F6E1-9D7D-4D98-A8EA-610EF6E13B02"
    private let archived = "99A5F6E1-9D7D-4D98-A8EA-610EF6E13B03"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--tab", "notes", "--notes", "--modules", "notes", "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        if app.alerts.firstMatch.waitForExistence(timeout: 2),
           app.alerts.buttons["Don’t Allow"].exists {
            app.alerts.buttons["Don’t Allow"].tap()
        }
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSelectionAndCreationActionsAdapt() {
        let row = element("notes.row.\(second)")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        let detail = element("notes.detail.\(second)")
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let more = app.buttons["notes.more"]
        XCTAssertTrue(more.isHittable)
        more.tap()
        XCTAssertTrue(app.buttons["notes.edit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.dismissNativeMenu(item: app.buttons["notes.edit"]))
        XCTAssertFalse(app.navigationBars["Edit note"].exists)
        shot("notes-portrait-detail")

        if UIDevice.current.userInterfaceIdiom == .pad {
            let add = app.buttons["notes.add"]
            XCTAssertTrue(add.isHittable)
            add.tap()
            XCTAssertTrue(app.buttons["notes.write"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["notes.capture"].exists)
            XCTAssertTrue(app.dismissNativeMenu(item: app.buttons["notes.write"]))
            XCUIDevice.shared.orientation = .landscapeLeft
            let landscape = NSPredicate { _, _ in
                self.app.frame.width > self.app.frame.height && detail.exists
            }
            expectation(for: landscape, evaluatedWith: app)
            waitForExpectations(timeout: 10)
            XCTAssertTrue(waitUntil { row.isHittable }, app.debugDescription)
            XCTAssertTrue(waitUntil { self.app.buttons["notes.add"].isHittable }, app.debugDescription)
            shot("notes-landscape-detail")
        } else {
            app.navigationBars.buttons["BackButton"].firstMatch.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            let add = app.buttons["notes.add"]
            XCTAssertTrue(add.isHittable)
            add.tap()
            XCTAssertTrue(app.buttons["notes.write"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["notes.capture"].exists)
            shot("notes-phone-list")
        }
    }

    func testWrittenNoteUsesSharedTextEditorAndSaves() {
        let add = app.buttons["notes.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 20)); add.tap()
        let write = app.buttons["notes.write"]
        XCTAssertTrue(write.waitForExistence(timeout: 5)); write.tap()
        let editor = app.textViews["notes.composer"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText("Shared editor regression note")
        app.buttons["Save"].tap()
        XCTAssertTrue(waitUntil { !editor.exists })
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Shared editor regression note")).firstMatch.waitForExistence(timeout: 5))
    }

    func testArchivedSearchSelectionSurvivesRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad selection regression") }
        let search = app.textFields["filters.notes.query"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        search.typeText("Done: moved")
        let row = element("notes.row.\(archived)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(element("notes.detail.\(archived)").waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let preserved = NSPredicate { _, _ in
            self.app.frame.width > self.app.frame.height && self.element("notes.detail.\(self.archived)").exists
        }
        expectation(for: preserved, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        shot("notes-archived-landscape")
    }
}
