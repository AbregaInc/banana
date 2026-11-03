import XCTest

/// Run with BananaPi / PiDevelopment: no preview, fake-model or onboarding overrides.
#if PI_DEVELOPMENT
final class PiLaunchUITest: XCTestCase {
    /// Home is the fixed app, as in Main; the agent is reached through it, never instead of it.
    func testNormalColdLaunchReachesTheFixedAppWithoutCloudSetup() {
        let app = XCUIApplication()
        app.launch()
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["assistant.input"].firstMatch.exists, app.debugDescription)
        XCTAssertFalse(app.otherElements["returning-user-check"].exists)
        XCTAssertFalse(app.buttons["onboarding.continue"].exists)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.otherElements["returning-user-check"].exists)
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription)
    }
}

/// The agent as an input method: words in the + sheet become the app's own editor, and the
/// saved thing lands on its page; a question in Review opens its answer.
final class AgentInputUITest: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--assistant-test-navigation", "--assistant-reset", "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        return app
    }
    private func type(_ text: String, in app: XCUIApplication) {
        let input = app.descendants(matching: .any)["agent.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15), app.debugDescription)
        input.tap(); input.typeText(text)
        let send = app.buttons["agent.send"]
        XCTAssertTrue(waitUntil(timeout: 15) { send.isEnabled }, app.debugDescription)
        send.tap()
    }
    private func openAdd(in app: XCUIApplication) {
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 25), app.debugDescription)
        add.tap()
    }

    func testWordsInTheAddSheetBecomeAMealOnItsPage() {
        let app = launch()
        openAdd(in: app)
        type("Make a meal with 2 eggs and 1 banana", in: app)
        let save = app.buttons["assistant.workspace.saveMeal"]
        XCTAssertTrue(save.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(save.label, "Save", "In the sheet's toolbar; the tap is the approval")
        if !save.isHittable { app.swipeUp() }
        save.tap()
        // Check the durable result. XCTest can wait for an animation notification long enough
        // after the tap that the temporary Undo toast has already expired.
        XCTAssertTrue(waitUntil(timeout: 10) { !app.descendants(matching: .any)["agent.input"].firstMatch.exists }, app.debugDescription)
        let meal = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                                                    "nutrition.meal", "Pi UI breakfast")).firstMatch
        XCTAssertTrue(meal.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testDiscardingAnAgentDraftKeepsTheAddSheet() {
        let app = launch()
        openAdd(in: app)
        type("Create Pi UI Lunch tomorrow at 13:00 for 30 minutes", in: app)
        let title = app.textFields["event.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(title.value as? String, "Pi UI Lunch")
        app.buttons["assistant.workspace.dismiss"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !title.exists }, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["agent.input"].firstMatch.exists, app.debugDescription)
    }

    func testNutritionsLineHandsItsWordsToTheAddSheet() throws {
        // The line is the wide Nutrition page's (iPad, Mac); a phone's Food page has none, and
        // its + is the one way in.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "no Nutrition line on a phone")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--assistant-test-navigation", "--assistant-reset", "--disable-icloud",
                               "-onboardingCompleted", "YES", "--tab", "nutrition"]
        app.launch()
        let line = app.textFields["nutrition.phrase"]
        XCTAssertTrue(line.waitForExistence(timeout: 25), app.debugDescription)
        line.tap(); line.typeText("Make a meal with 2 eggs and 1 banana\n")
        // The + sheet opens already working on the words: the meal draft, no second step.
        XCTAssertTrue(app.buttons["assistant.workspace.saveMeal"].waitForExistence(timeout: 20), app.debugDescription)
    }

    func testTypingAVideoLinkKeepsItsMeetingPathUntilSubmitted() {
        let app = launch()
        openAdd(in: app)
        type("Create Pi UI Lunch tomorrow at 13:00 for 30 minutes", in: app)
        let location = app.textFields["event.location"]
        XCTAssertTrue(location.waitForExistence(timeout: 20), app.debugDescription)
        location.tap()
        location.typeText("https://")
        XCTAssertEqual(location.value as? String, "https://")
        location.typeText("meet.google.com/abc-defg-hij")
        XCTAssertEqual(location.value as? String, "https://meet.google.com/abc-defg-hij")
        location.typeText("\n")
        XCTAssertTrue(app.descendants(matching: .any)["event.videoLink"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { (location.value as? String) == "Location or room" || (location.value as? String) == "" })
    }

    func testAnEventDraftWithoutACalendarOffersToConnectOnItsCalendarRow() {
        let app = launch()
        openAdd(in: app)
        type("Create Pi UI Lunch tomorrow at 13:00 for 30 minutes", in: app)
        XCTAssertTrue(app.textFields["event.title"].waitForExistence(timeout: 20), app.debugDescription)
        // Checked, not tapped: tests never open a real Google sign-in.
        XCTAssertTrue(app.descendants(matching: .any)["event.calendar.connect"].firstMatch.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["event.save"].isEnabled)
        XCTAssertFalse(app.buttons["plan.calendar.connect"].exists, "Plan doesn't lead with setup")
    }

    func testAQuestionInReviewOpensItsAnswer() {
        let app = launch()
        let review = app.buttons["page.review"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 25), app.debugDescription)
        review.tap()
        type("Search Banana for yogurt", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["agent.answer"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.workspace.result.meal:")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
    }
}
#endif

final class AssistantUITest: XCTestCase {
    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--assistant-test", "--ui-preview", "--disable-icloud", "-onboardingCompleted", "YES"]
        if reset { app.launchArguments.append("--assistant-reset") }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        return app
    }
    private func capture(_ name: String, in app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func send(_ text: String, in app: XCUIApplication) {
        let input = app.descendants(matching: .any)["assistant.input"].firstMatch
        input.tap(); input.typeText(text)
        let button = app.buttons["assistant.send"]
        XCTAssertTrue(waitUntil(timeout: 15) { button.isEnabled }, app.debugDescription)
        button.tap()
    }
    /// Sample data sits in its own submenu of the options menu.
    private func openSampleData(in app: XCUIApplication) {
        app.buttons["assistant.options"].tap()
        let menu = app.buttons["Sample data"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
    }
    func testConversationSurvivesRelaunchAndSelection() {
        let app = launch()
        send("Hello Pi", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: Hello Pi"].waitForExistence(timeout: 15), app.debugDescription)
        app.terminate()
        _ = launch(reset: false)
        XCTAssertTrue(app.staticTexts["Local reply: Hello Pi"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Local reply: Hello Pi").count, 1)
        app.buttons["assistant.new"].tap()
        XCTAssertTrue(waitUntil { !app.staticTexts["Local reply: Hello Pi"].exists })
        send("Another conversation", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: Another conversation"].waitForExistence(timeout: 15))
        app.buttons["assistant.conversations"].tap()
        let original = app.buttons["assistant.conversation.1"]
        XCTAssertTrue(original.waitForExistence(timeout: 5)); original.tap()
        XCTAssertTrue(app.staticTexts["Local reply: Hello Pi"].waitForExistence(timeout: 10))
    }
    #if !PI_DEVELOPMENT
    // Main reaches the assistant from … › Assistant; in Pi it is the + and Review (AgentInputUITest).
    func testAssistantOpensThroughTheAppShell() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--assistant-test-navigation", "--assistant-reset", "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 25), app.debugDescription)
        more.tap()
        let assistant = app.buttons["page.more.assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 5), app.debugDescription)
        assistant.tap()
        let input = app.descendants(matching: .any)["assistant.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 25), app.debugDescription)
        send("Through the app shell", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: Through the app shell"].waitForExistence(timeout: 15), app.debugDescription)
    }
    #endif
    func testNoteToolDoesNotRepeatAfterReopen() {
        let app = launch()
        send("Save note: Check Pi durability", in: app)
        XCTAssertTrue(app.staticTexts["Saved your note."].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitUntil { app.staticTexts["assistant.test.notes"].label == "1 saved note" })
        app.terminate()
        _ = launch(reset: false)
        XCTAssertTrue(app.staticTexts["Saved your note."].waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil { app.staticTexts["assistant.test.notes"].label == "1 saved note" })
    }
    func testStopAfterBackgroundAndForeground() {
        let app = launch()
        send("Wait", in: app)
        XCTAssertTrue(app.buttons["assistant.stop"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(timeout: 8) { app.state != .runningForeground })
        app.activate()
        XCTAssertTrue(app.buttons["assistant.stop"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["assistant.stop"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !app.buttons["assistant.stop"].exists }, app.debugDescription)
        send("Hello again", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: Hello again"].waitForExistence(timeout: 15), app.debugDescription)
    }
    func testClearingHistoryPreservesCreatedNotes() {
        let app = launch()
        send("Save note: Keep this note", in: app)
        XCTAssertTrue(app.staticTexts["Saved your note."].waitForExistence(timeout: 15))
        app.buttons["assistant.options"].tap()
        app.buttons["Delete all conversations…"].tap()
        let confirmation = app.buttons["Delete conversations"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !app.staticTexts["Saved your note."].exists })
        XCTAssertEqual(app.staticTexts["assistant.test.notes"].label, "1 saved note")
        send("A fresh start", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: A fresh start"].waitForExistence(timeout: 15))
    }
    func testInFlightConversationSurvivesProcessExit() {
        let app = launch()
        send("Wait", in: app)
        XCTAssertTrue(app.buttons["assistant.stop"].waitForExistence(timeout: 15))
        app.terminate()
        _ = launch(reset: false)
        XCTAssertTrue(app.buttons["assistant.stop"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["assistant.stop"].tap()
        XCTAssertTrue(waitUntil(timeout: 15) { !app.buttons["assistant.stop"].exists })
        send("Recovered after relaunch", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: Recovered after relaunch"].waitForExistence(timeout: 15), app.debugDescription)
    }
    func testContextSummaryAllowsFurtherMessages() {
        let app = launch()
        send("First message", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: First message"].waitForExistence(timeout: 15))
        app.buttons["assistant.options"].tap()
        app.buttons["Summarize context"].tap()
        XCTAssertTrue(app.staticTexts["Summarized earlier context"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(waitUntil(timeout: 15) { !app.buttons["assistant.stop"].exists })
        send("After summary", in: app)
        XCTAssertTrue(app.staticTexts["Local reply: After summary"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func testNutritionWorkspaceUpdatesAndRestores() {
        let app = launch()
        send("Show my protein this month", in: app)
        let chart = app.descendants(matching: .any)["assistant.nutrition.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(waitUntil { !app.buttons["assistant.stop"].exists })
        send("Only weekdays", in: app)
        XCTAssertTrue(waitUntil { !app.buttons["assistant.stop"].exists })
        let weekdays = app.switches["assistant.nutrition.weekdays"]
        XCTAssertTrue(weekdays.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(weekdays.value as? String, "1", app.debugDescription)
        app.switches["assistant.nutrition.compare"].tap()
        XCTAssertTrue(waitUntil { app.switches["assistant.nutrition.compare"].value as? String == "1" })
        app.terminate()
        _ = launch(reset: false)
        XCTAssertTrue(chart.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.switches["assistant.nutrition.weekdays"].value as? String, "1")
        XCTAssertEqual(app.switches["assistant.nutrition.compare"].value as? String, "1")
        app.buttons["assistant.new"].tap()
        XCTAssertTrue(waitUntil { !chart.exists })
    }

    func testNutritionShortcutOpensWithoutAnInferenceTurn() {
        let app = launch()
        let shortcut = app.buttons["Show my protein this month"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 10), app.debugDescription)
        shortcut.tap()
        XCTAssertTrue(app.descendants(matching: .any)["assistant.nutrition.chart"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["assistant.stop"].exists)
        XCTAssertFalse(app.staticTexts["Updated your nutrition view."].exists)
    }

    #if PI_DEVELOPMENT
    func testSampleHistoryLoadsOnceAndCanBeRemoved() {
        let app = launch()
        app.buttons["Show my protein this month"].tap()
        let count = app.staticTexts["assistant.test.meals"]
        XCTAssertTrue(count.waitForExistence(timeout: 15), app.debugDescription)
        let before = count.label
        openSampleData(in: app)
        app.buttons["Load sample meal history"].tap()   // submenu items keep labels, not identifiers
        let badge = app.staticTexts["assistant.samples.badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), app.debugDescription)
        let loaded = count.label
        XCTAssertNotEqual(loaded, before)
        openSampleData(in: app)
        app.buttons["Load sample meal history"].tap()   // submenu items keep labels, not identifiers
        XCTAssertEqual(count.label, loaded)
        app.buttons["assistant.new"].tap()
        let explore = app.buttons["assistant.samples.explore"]
        XCTAssertTrue(explore.waitForExistence(timeout: 10), app.debugDescription)
        explore.tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(count.label, loaded)
        openSampleData(in: app)
        app.buttons["Remove sample meals…"].tap()
        app.buttons["Remove sample meals"].tap()
        XCTAssertTrue(waitUntil { !badge.exists && count.label == before }, app.debugDescription)
    }
    #endif

    func testNutritionMealCopyOpensExistingReviewEditor() {
        let app = launch()
        send("Show my protein this month", in: app)
        let copy = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.nutrition.copy.")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 20), app.debugDescription)
        let count = app.staticTexts["assistant.test.meals"]
        let initial = Int(count.label.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThan(initial, 0, app.debugDescription)
        copy.tap()
        let save = app.buttons["assistant.workspace.saveMeal"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["assistant.nutrition.review"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)
        let dismiss = app.buttons["assistant.copy.dismiss"]
        if !dismiss.isHittable { app.swipeUp() }
        dismiss.tap()
        XCTAssertTrue(waitUntil { !save.exists })
        XCTAssertEqual(count.label, "\(initial) logged meals")
        if !copy.isHittable { app.swipeDown() }
        copy.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.debugDescription)
        // In the workspace, "Approve and save" is the approval: no separate review switch.
        XCTAssertFalse(app.switches["foodText.confirmed"].exists, app.debugDescription)
        XCTAssertTrue(waitUntil { save.isEnabled }, app.debugDescription)
        if !save.isHittable { app.swipeUp() }
        capture("Inline meal copy", in: app)
        save.tap()
        XCTAssertTrue(waitUntil { !save.exists }, app.debugDescription)
        XCTAssertTrue(waitUntil { count.label == "\(initial + 1) logged meals" }, app.debugDescription)
        app.terminate()
        _ = launch(reset: false)
        XCTAssertTrue(count.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(count.label, "\(initial + 1) logged meals")
    }
    func testNewMealDraftIsInlineAndRestores() {
        let app = launch()
        send("Make a meal with 2 eggs and 1 banana", in: app)
        let editor = app.textFields["foodText.mealName"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["foodText.total"].firstMatch.exists, app.debugDescription)
        XCTAssertEqual(app.buttons["assistant.workspace.saveMeal"].label, "Approve and save", app.debugDescription)
        XCTAssertFalse(app.switches["foodText.confirmed"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["assistant.workspace.reviewMeal"].exists)
        XCTAssertEqual(app.sheets.count, 0, app.debugDescription)
        app.terminate()
        _ = launch(reset: false)
        XCTAssertTrue(editor.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.textFields["foodText.mealName"].exists, app.debugDescription)
        app.buttons["assistant.workspace.dismiss"].tap()
        XCTAssertTrue(waitUntil { !editor.exists }, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].firstMatch.exists)
    }

    func testNewMealDraftSaveAppearsInExistingNutritionStore() {
        let app = launch()
        app.buttons["Show my protein this month"].tap()
        let count = app.staticTexts["assistant.test.meals"]
        XCTAssertTrue(count.waitForExistence(timeout: 15), app.debugDescription)
        let initial = Int(count.label.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThan(initial, 0)
        send("Make a meal with 2 eggs and 1 banana", in: app)
        let name = app.textFields["foodText.mealName"]
        XCTAssertTrue(name.waitForExistence(timeout: 15), app.debugDescription)
        name.tap()
        // This field is trailing-aligned; place the caret after the seeded name.
        name.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5)).tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count))
        name.typeText("Inline breakfast")
        XCTAssertEqual(name.value as? String, "Inline breakfast")
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        let save = app.buttons["assistant.workspace.saveMeal"]
        XCTAssertTrue(save.exists, app.debugDescription)
        XCTAssertEqual(save.label, "Approve and save", "The tap is the person's approval")
        XCTAssertTrue(waitUntil { save.isEnabled }, app.debugDescription)
        if !save.isHittable { app.swipeUp() }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inline meal editor"; screenshot.lifetime = .keepAlways; add(screenshot)
        save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["assistant.workspace.savedMeal"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(save.exists, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].firstMatch.exists, "Saving must keep the assistant open")
        if !app.buttons["assistant.workspace.dismiss"].isHittable { app.swipeDown() }
        app.buttons["assistant.workspace.dismiss"].tap()
        XCTAssertTrue(count.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(count.label, "\(initial + 1) logged meals")
    }

    func testNewEventDraftIsInlineAndRestores() {
        let app = launch()
        send("Create Pi UI Lunch tomorrow at 13:00 for 30 minutes", in: app)
        let title = app.textFields["event.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(title.value as? String, "Pi UI Lunch")
        XCTAssertFalse(app.buttons["assistant.workspace.reviewEvent"].exists)
        XCTAssertEqual(app.sheets.count, 0, app.debugDescription)
        app.terminate()
        _ = launch(reset: false)
        XCTAssertTrue(title.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(title.value as? String, "Pi UI Lunch")
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Pi UI Lunch".count))
        title.typeText("Inline lunch")
        XCTAssertEqual(title.value as? String, "Inline lunch")
        title.typeText("\n")
        XCTAssertTrue(waitUntil { !app.keyboards.firstMatch.exists }, app.debugDescription)
        let save = app.buttons["event.save"]
        XCTAssertTrue(save.exists, app.debugDescription)
        XCTAssertFalse(save.isEnabled, "No writable calendar is connected in this isolated test")
        let details = app.staticTexts["assistant.workspace.eventDetails"]
        XCTAssertTrue(details.exists, app.debugDescription)
        if !details.isHittable { app.swipeUp() }
        details.tap()
        XCTAssertTrue(app.descendants(matching: .any)["event.notes"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        details.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inline event editor"; screenshot.lifetime = .keepAlways; add(screenshot)
        let dismiss = app.buttons["assistant.workspace.dismiss"]
        if !dismiss.isHittable { app.swipeDown() }
        dismiss.tap()
        XCTAssertTrue(waitUntil { !title.exists }, app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].firstMatch.exists)
    }

    #if !PI_DEVELOPMENT
    // Main reaches the assistant from … › Assistant; in Pi it is the + and Review (AgentInputUITest).
    func testGlobalMealSearchLinksThroughNormalAppShell() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "--assistant-test-navigation", "--assistant-reset", "--disable-icloud", "-onboardingCompleted", "YES"]
        app.launch()
        let more = app.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 25), app.debugDescription)
        more.tap()
        let assistant = app.buttons["page.more.assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 5), app.debugDescription)
        assistant.tap()
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        send("Search Banana for yogurt", in: app)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.workspace.result.meal:")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any)["assistant.workspace.searchDetail"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["assistant.input"].firstMatch.exists)
        capture("Inline search details", in: app)
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistant.workspace.openResult.meal:")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), app.debugDescription)
        open.tap()
        XCTAssertTrue(waitUntil(timeout: 15) {
            app.descendants(matching: .any)["nutrition.phrase"].firstMatch.exists
                || app.buttons["wellness.textMeal"].exists
                || (app.navigationBars["Nutrition"].exists && app.buttons["nutrition.meal"].firstMatch.exists)
        }, app.debugDescription)
    }
    #endif
}
