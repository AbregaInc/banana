import XCTest

/// The rule that carries a request for the caret to a field that may not exist yet
/// (`MailCaretChase`): ask, look whether it took, ask again. On the Mac the first assignment made in
/// the update that creates the field is dropped, so a reply opened by R left the list the first
/// responder and the keys typed after it were thrown away (K12). Pure: the loop's three questions
/// and its pause are handed in, and the test's pause is instant.
@MainActor
final class MailCaretChaseTests: XCTestCase {

    /// A field that takes the caret on the `takesOn`th ask and not before, as a view that is laid
    /// out some frames after it was asked for does.
    private final class Field {
        let takesOn: Int
        var asks = 0
        var there = false
        var told = 0
        var pauses = 0
        init(takesOn: Int) { self.takesOn = takesOn }
    }

    private func chase(_ field: Field, wanted: @escaping () -> Bool = { true }) async -> Int {
        await MailCaretChase.run(
            isWanted: wanted,
            isThere: { field.there },
            ask: {
                field.asks += 1
                if field.asks >= field.takesOn { field.there = true }
            },
            landed: { field.told += 1 },
            pause: { field.pauses += 1 })
    }

    func testItAsksAgainUntilTheFieldHasTheCaret() async {
        let field = Field(takesOn: 3)
        let asks = await chase(field)
        XCTAssertEqual(asks, 3, "the first two asks found nothing to focus")
        XCTAssertTrue(field.there)
        XCTAssertEqual(field.told, 1, "and the request is told once that the caret is in its field")
        XCTAssertEqual(field.pauses, 4, "a pause before the first look, and one after every ask")
    }

    func testTheFirstLookComesAfterAPauseAndAFieldThatTookItAtOnceIsNotAskedAgain() async {
        let field = Field(takesOn: 0)
        field.there = true                                 // the assignment made with the update took
        var wanted = true
        let asks = await MailCaretChase.run(
            isWanted: { wanted }, isThere: { field.there }, ask: { field.asks += 1 },
            landed: { field.told += 1; wanted = false },
            pause: { field.pauses += 1 })
        XCTAssertEqual(asks, 0, "nothing to ask")
        XCTAssertEqual(field.asks, 0)
        XCTAssertEqual(field.pauses, 1, "it looked once, a turn after the request")
        XCTAssertEqual(field.told, 1, "a caret already in the field answers the request, which waits for it")
    }

    func testItStopsWhenTheModelHasHadItsCaretWithoutTheLook() async {
        // The caret landed through the focus state's own change, which tells the model; the loop
        // is not wanted any more and does not tell it again.
        let field = Field(takesOn: 1)
        let asks = await chase(field, wanted: { !field.there })
        XCTAssertEqual(asks, 1)
        XCTAssertEqual(field.told, 0)
    }

    func testItDoesNothingForARequestThatIsNotWanted() async {
        let field = Field(takesOn: 1)
        let asks = await chase(field, wanted: { false })
        XCTAssertEqual(asks, 0)
        XCTAssertEqual(field.asks, 0)
        XCTAssertEqual(field.told, 0)
    }

    func testItStopsWhenTheViewAndSoTheRequestIsGone() async {
        let field = Field(takesOn: 100)
        var looks = 0
        let asks = await chase(field, wanted: { looks += 1; return looks <= 4 })
        XCTAssertEqual(asks, 4, "the composer was closed after the fourth ask")
        XCTAssertFalse(field.there)
    }

    func testAFieldThatNeverComesIsAskedForALimitedNumberOfTimes() async {
        let field = Field(takesOn: Int.max)
        let asks = await chase(field)
        XCTAssertEqual(asks, MailCaretChase.attempts)
        XCTAssertEqual(field.told, 0)
        XCTAssertFalse(field.there)
    }

    func testASlowFirstLayoutCostsAsksAndNotTheCaret() async {
        // The number of asks is a count, not a time: however many frames the first layout takes,
        // short of the limit, the caret lands.
        let field = Field(takesOn: MailCaretChase.attempts - 1)
        let asks = await chase(field)
        XCTAssertEqual(asks, MailCaretChase.attempts - 1)
        XCTAssertTrue(field.there)
        XCTAssertEqual(field.told, 1)
    }

    func testTheLimitIsAboutTheSecondTheTypeAheadWaits() {
        let frames = Double(MailCaretChase.attempts) * 0.016
        XCTAssertGreaterThanOrEqual(frames, MailComposerModel.caretWithin * 0.9)
    }
}
