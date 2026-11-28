#if !BANANA_PUBLIC
import XCTest

final class MailDraftOfferAuthorityTests: XCTestCase {
    private func check(_ body: String, task: String = "Write my reply.", reference: String = "") throws {
        try MailDraftPrompt.checkGrounding(in: body, suppliedText: task + "\n" + reference, authorInstruction: task)
    }

    func testWillingnessToPerformAConcreteActionRequiresCurrentOwnerAuthority() throws {
        let body = "I'd be happy to lead the walk."
        XCTAssertThrowsError(try check(body, reference: "Would you like to lead the walk?"))
        XCTAssertThrowsError(try check(body, reference: "Previously I said I will lead the walk."))
        XCTAssertThrowsError(try check(body, task: "Do not say I will lead the walk."))
        XCTAssertNoThrow(try check(body, task: "Tell them I will lead the walk."))
        XCTAssertThrowsError(try check("I will lead the walk.", task: "Say I am willing to lead the walk."))
    }

    func testConsentRemainsBoundToTheTargetAndConditions() throws {
        XCTAssertThrowsError(try check("I am willing to record the extended afternoon session at the warehouse.",
                                      task: "Say I am willing to record the extended afternoon session at the studio."))
        XCTAssertThrowsError(try check("I'd be glad to host the workshop.",
                                      task: "If a helper is confirmed, say I will host the workshop."))
        XCTAssertThrowsError(try check("If a guest is confirmed, I'd be glad to host the workshop.",
                                      task: "Say I will host the workshop if a helper is confirmed."))
        XCTAssertThrowsError(try check("I’d be happy to meet Dr. Vale.", task: "Say I will meet Dr. Reed."))
        XCTAssertThrowsError(try check("If a helper is confirmed, I’d be glad to host the workshop.",
                                      task: "If a helper is confirmed, and only after inspection, say I will host the workshop."))
        XCTAssertNoThrow(try check("If a helper is confirmed, I'd be glad to host the workshop.",
                                  task: "Say I will host the workshop if a helper is confirmed."))
    }

    func testGreetingsQuestionsAndDenialsDoNotVolunteerTheOwner() throws {
        for text in ["I'm glad to meet you.", "I’m delighted to meet you too.",
                     "I’m happy to confirm that the box is blue.", "I’d be happy to take a look. Please send the samples.",
                     "I'm happy to meet your formatting requirements.", "I am not willing to record the workshop.",
                     "Would you be willing to record the workshop?"] {
            XCTAssertNoThrow(try check(text, reference: "The box is blue."))
        }
    }
}
#endif
