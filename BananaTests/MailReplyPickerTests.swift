#if !BANANA_PUBLIC
import XCTest

/// The picker only offers what the email itself asks and names.
final class MailReplyPickerTests: XCTestCase {
    private func raw(_ object: [String: Any]) -> String {
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return String(decoding: try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]]), as: UTF8.self)
    }
    private let email = "Hi! Do you want me to cancel the apple crate pickup as well? We can do Tuesday or Thursday for the swap."

    func testGroundedQuestionsAndOptionsSurvive() throws {
        let picker = try MailReplyPicker.parse(raw(["reply": "needed", "questions": [
            ["question": "Cancel the apple crate pickup too?", "control": "yes_no", "options": [String](),
             "quote": "Do you want me to cancel the apple crate pickup as well?"],
            ["question": "Which day for the swap?", "control": "pick_one", "options": ["Tuesday", "Thursday", "Friday"],
             "quote": "We can do Tuesday or Thursday for the swap."],
        ]]), selectedText: email)
        XCTAssertEqual(picker.reply, .needed)
        XCTAssertEqual(picker.questions.map(\.control), [.yesNo, .pickOne])
        XCTAssertEqual(picker.questions[1].options, ["Tuesday", "Thursday"])  // Friday is not in the email
    }

    func testInventedQuoteIsDroppedAndThinPickBecomesText() throws {
        let picker = try MailReplyPicker.parse(raw(["reply": "needed", "questions": [
            ["question": "Accept the internship?", "control": "yes_no", "options": [String](), "quote": "Do you want to accept the internship?"],
            ["question": "Which day?", "control": "pick_one", "options": ["Tuesday", "Monday"], "quote": "We can do Tuesday or Thursday for the swap."],
        ]]), selectedText: email)
        XCTAssertEqual(picker.questions.count, 1)
        XCTAssertEqual(picker.questions[0].control, .text)
        XCTAssertEqual(picker.questions[0].options, [])
    }

    func testNoReplyHasNoQuestionsAndAnswersBecomeAnInstruction() throws {
        let picker = try MailReplyPicker.parse(raw(["reply": "none", "questions": [
            ["question": "x", "control": "yes_no", "options": [String](), "quote": "Hi!"]]]), selectedText: email)
        XCTAssertEqual(picker, .init(reply: .none, questions: []))
        let q = MailReplyPicker.Question(question: "Cancel the pickup too?", control: .yesNo, options: [], quote: "x")
        XCTAssertEqual(MailReplyPicker.instruction([(q, "Yes")]), "Write my reply. My answers: Cancel the pickup too? → Yes")
        XCTAssertThrowsError(try MailReplyPicker.parse("not json", selectedText: email))
    }
}
#endif
