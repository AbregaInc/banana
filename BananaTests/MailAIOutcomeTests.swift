#if !BANANA_PUBLIC
import XCTest
import GRDB

/// The composer's view of an assistant outcome: the picker's answers, what is shown, the overnight
/// record and the 👍 / 👎 report.
final class MailAIOutcomeTests: XCTestCase {
    private let picker = MailReplyPicker.Picker(reply: .needed, questions: [
        .init(question: "Cancel the pickup too?", control: .yesNo, options: [], quote: "Do you want me to cancel?"),
        .init(question: "Which day for the swap?", control: .pickOne, options: ["Tuesday", "Thursday"], quote: "Tuesday or Thursday"),
        .init(question: "Which crates?", control: .pickMany, options: ["Apples", "Pears", "Plums"], quote: "apples, pears or plums"),
    ])

    func testAnswersBecomeTheNextInstructionInTheEmailsOrder() {
        var form = MailPickerForm(picker)
        XCTAssertFalse(form.canWrite)
        form.choose("Yes", at: 0)
        form.choose("Plums", at: 2)
        form.choose("Apples", at: 2)
        XCTAssertEqual(form.instruction(), "Write my reply. My answers: Cancel the pickup too? → Yes; Which crates? → Apples, Plums")
        form.choose("Yes", at: 0) // tapping the chosen one clears it
        form.choose("Tuesday", at: 1)
        form.choose("Thursday", at: 1) // pick one replaces
        form.other = "  Ask about the invoice  "
        XCTAssertEqual(form.instruction(),
                       "Write my reply. My answers: Which day for the swap? → Thursday; Which crates? → Apples, Plums; Ask about the invoice")
        XCTAssertEqual(form.summary(), "Which day for the swap? → Thursday\nWhich crates? → Apples, Plums\nAsk about the invoice")
    }

    func testFreeAnswerAloneAndTypedControls() {
        let typed = MailReplyPicker.Picker(reply: .needed, questions: [
            .init(question: "How many units?", control: .amount, options: [], quote: "How many?"),
            .init(question: "When can you come?", control: .dateTime, options: [], quote: "When?"),
            .init(question: "Which address?", control: .text, options: [], quote: "Where?"),
        ])
        var form = MailPickerForm(typed)
        form.other = "Say thanks"
        XCTAssertTrue(form.canWrite)
        XCTAssertEqual(form.instruction(), "Write my reply. Say thanks")
        form.other = ""
        form.texts[0] = " 20 "
        form.texts[2] = "   "
        form.dates[1] = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(form.instruction(formatDate: { _ in "Friday 3 pm" }),
                       "Write my reply. My answers: How many units? → 20; When can you come? → Friday 3 pm")
        XCTAssertEqual(form.options(0), [])
        XCTAssertLessThanOrEqual(MailPickerForm(typed).instruction().count, 1000)
    }

    func testDisplayStateForEachOutcome() {
        XCTAssertEqual(MailAIDisplay(.draft("Hi")), .draft("Hi"))
        XCTAssertTrue(MailAIDisplay(.draft("Hi")).isDraft)
        XCTAssertEqual(MailAIDisplay(.questions(picker)), .picker(picker))
        XCTAssertEqual(MailAIDisplay(.note("They already paid.")), .line("They already paid."))
        XCTAssertEqual(MailAIDisplay(.noReply("A shipping notice.")), .line("A shipping notice."))
        XCTAssertEqual(MailAIDisplay(.noReply("  ")), .line(MailAIDisplay.noReplyDefault))
        XCTAssertFalse(MailAIDisplay(.note("x")).isDraft)
    }

    func testStoredOutcomeRoundTripsEveryKind() throws {
        for outcome in [MailAIOutcome.questions(picker), .note("n"), .noReply("r"), .draft("d")] {
            let run = MailAIRun(outcome: outcome, model: "m", thinking: .low, tools: ["read_thread": 2])
            let data = try XCTUnwrap(MailAIStoredOutcome(run, anchor: "a1").data)
            let back = try XCTUnwrap(MailAIStoredOutcome.decode(data))
            XCTAssertEqual(back.anchor, "a1")
            XCTAssertEqual(back.run, run)
        }
    }

    func testOvernightOutcomeTableMigratesAndRoundTripsAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-ai-outcome-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let (directories, stores, store) = try await Task.detached {
            let directories = try MailDirectories(root: root)
            let stores = try MailStores.open(directories, migrations: MailSlices.migrations())
            return (directories, stores, try MailIntentStore(directories: directories))
        }.value
        let thread = MailConversationID(account: "a@example.com", thread: "t1")
        let run = MailAIRun(outcome: .questions(picker), model: "m", thinking: .low, tools: ["check_reply": 1])
        let payload = try XCTUnwrap(MailAIStoredOutcome(run, anchor: "m2").data)
        // The gated insert holds: no such inbound message in the index, nothing is kept.
        let gated = try await store.insertOvernightOutcome(payload, scope: "s", conversation: thread,
            anchor: MailMessageID(account: thread.account, message: "m2"), rfcID: "<m2@plan.example>", stores: stores, isEnabled: { true })
        XCTAssertFalse(gated)
        let none = try await store.overnightOutcome(scope: "s", conversation: thread)
        XCTAssertNil(none)
        try await store.recordOvernightOutcome(payload, scope: "s", conversation: thread, anchor: "m2")
        let reopened = try await Task.detached { try MailIntentStore(directories: directories) }.value
        let found = try await reopened.overnightOutcome(scope: "s", conversation: thread)
        XCTAssertEqual(found?.anchor, "m2")
        XCTAssertEqual(found.flatMap { MailAIStoredOutcome.decode($0.payload) }?.run, run)
        let otherScope = try await reopened.overnightOutcome(scope: "other", conversation: thread)
        XCTAssertNil(otherScope)
        try await reopened.clearOvernightOutcome(scope: "s", conversation: thread)
        let cleared = try await reopened.overnightOutcome(scope: "s", conversation: thread)
        XCTAssertNil(cleared)
    }

    func testFeedbackCarriesTheOutcomeAndFactsNeverTheEmail() throws {
        let email = "Do you want me to cancel the apple crate pickup as well? Account 4471."
        let run = MailAIRun(outcome: .draft("Yes, please cancel it."), model: "qwen-mail", thinking: .low,
                            tools: ["read_thread": 1, "check_reply": 2])
        let feedback = MailAIFeedback(run: run, instruction: "Say yes", answers: nil, overnight: true)

        let rating = feedback.rating(.up)
        XCTAssertEqual(rating.kind, .rating)
        XCTAssertEqual(rating.page, "mail")
        XCTAssertNil(rating.note)
        XCTAssertTrue(rating.attachments.isEmpty, "the service refuses a rating with content")
        XCTAssertEqual(rating.context["tools"], .number(3))
        XCTAssertEqual(rating.context["model"], .text("qwen-mail"))
        XCTAssertEqual(rating.context["overnight"], .flag(true))

        let report = feedback.report(note: "  too formal ")
        XCTAssertEqual(report.kind, .problem)
        XCTAssertEqual(report.note, "too formal")
        XCTAssertEqual(report.context["rating"], .text("down"))
        let attachment = try XCTUnwrap(report.attachments.first)
        XCTAssertEqual(attachment.name, .ai)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: attachment.data) as? [String: Any])
        XCTAssertEqual(json["outcome"] as? String, "draft")
        XCTAssertEqual(json["text"] as? String, "Yes, please cancel it.")
        XCTAssertEqual(json["instruction"] as? String, "Say yes")
        XCTAssertEqual(json["thinking"] as? String, "low")
        XCTAssertEqual(json["tools"] as? [String: Int], ["read_thread": 1, "check_reply": 2])
        let body = String(decoding: try XCTUnwrap(report.body(device: .init(platform: "mac", channel: "dev", variant: "beta",
            version: "1", os: "26", model: "Mac"))), as: UTF8.self)
        XCTAssertFalse(body.contains("4471"))
        XCTAssertFalse(String(decoding: attachment.data, as: UTF8.self).contains(email))
        XCTAssertNil(feedback.report(note: " ").note)

        var form = MailPickerForm(picker)
        form.choose("No", at: 0)
        let asked = MailAIFeedback(run: MailAIRun(outcome: .questions(picker), model: nil, thinking: .off),
                                   instruction: nil, answers: form.summary()).payload
        XCTAssertEqual(asked.outcome, "questions")
        XCTAssertEqual(asked.questions, picker.questions.map(\.question))
        XCTAssertEqual(asked.answers, "Cancel the pickup too? → No")
        XCTAssertNil(asked.instruction)
    }
}
#endif
