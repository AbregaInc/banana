import XCTest

/// Pictures of every route and state Mail has, on the phone and on the iPad in both orientations,
/// to be looked at: the fastest way to see a screen that is wrong. No assertions beyond "it came
/// up"; the journeys are in the other `Mail…UITest` classes.
final class MailSmokeUITest: MailUITestCase {

    private var orientations: [Bool] { isPad ? [false, true] : [false] }

    func testThePlaces() {
        for landscape in orientations {
            launch(landscape: landscape)
            snap("inbox")
            element(MailID.list).swipeUp()
            snap("inbox-scrolled")
            for place in ["Starred", "Done", "Drafts", "Scheduled"] {
                show(place: place)
                Thread.sleep(forTimeInterval: 0.6)
                snap("place-\(place.lowercased())")
            }
            show(place: "Inbox")
            Thread.sleep(forTimeInterval: 0.4)
            snap("inbox-back")
            app.terminate()
        }
    }

    func testConversations() {
        for landscape in orientations {
            for key in ["q3", "forty", "long", "rtl", "attachments", "attachments-many", "plain-chain", "no-subject", "emoji"] {
                launch(open: key, landscape: landscape)
                XCTAssertTrue(element(MailID.conversation).waitForExistence(timeout: 10), key)
                Thread.sleep(forTimeInterval: 0.5)
                snap("open-\(key)")
                if key == "forty" || key == "long" {
                    app.swipeUp(); app.swipeUp(); app.swipeUp()
                    snap("open-\(key)-scrolled")
                }
                app.terminate()
            }
        }
    }

    // Keep all twenty states and both iPad orientations, with a separate time budget per journey.
    func testTheWritingStates() {
        writingStates(["reply", "reply-all", "forward", "new", "cc"])
    }

    func testWritingIdentityAndScheduleStates() {
        writingStates(["from", "new-signature", "picker", "drafts", "scheduled"])
    }

    func testWritingAttachmentStates() {
        writingStates(["scheduled-place", "late", "attach", "attach-over", "format"])
    }

    func testWritingCompletionStates() {
        writingStates(["format-attach", "sent-format", "done", "sent", "draft"])
    }

    private func writingStates(_ states: [String]) {
        for landscape in orientations {
            for state in states {
                launch(open: "q3", state: state, landscape: landscape)
                let ready: XCUIElement
                switch state {
                case "picker": ready = element(MailID.timePickerField)
                case "scheduled", "late": ready = element(MailID.scheduledBanner)
                case "draft": ready = element(MailID.draftMarker)
                case "done", "sent", "sent-format": ready = undoButton
                case "drafts", "scheduled-place": ready = element(MailID.list)
                case "attach", "format-attach": ready = element(MailID.attachmentChip("logo-mark.png"))
                case "attach-over": ready = element(MailID.attachmentsNotice)
                default: ready = body
                }
                XCTAssertTrue(ready.waitForExistence(timeout: 10), "writing state: \(state)")
                if state == "drafts" || state == "scheduled-place" {
                    XCTAssertTrue(waitUntil(timeout: 10) {
                        self.headerCount() == (state == "drafts" ? 3 : 2)
                    }, "the requested place must finish loading")
                }
                snap("state-\(state)")
                app.terminate()
            }
        }
    }

    func testTextSizes() {
        for landscape in orientations {
            for (tag, category) in [("xxxl", "UICTContentSizeCategoryAccessibilityXXXL"), ("xs", "UICTContentSizeCategoryXS")] {
                launch(landscape: landscape, extra: ["-UIPreferredContentSizeCategoryName", category])
                snap("size-\(tag)-inbox")
                app.terminate()
                launch(open: "q3", state: "reply", landscape: landscape,
                       extra: ["-UIPreferredContentSizeCategoryName", category])
                Thread.sleep(forTimeInterval: 1.2)
                snap("size-\(tag)-reply")
                app.terminate()
                launch(open: "q3", state: "picker", landscape: landscape,
                       extra: ["-UIPreferredContentSizeCategoryName", category])
                Thread.sleep(forTimeInterval: 1.2)
                snap("size-\(tag)-picker")
                app.terminate()
            }
        }
    }
}
