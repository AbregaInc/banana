#if !BANANA_PUBLIC
import XCTest

/// Banana's side of the banana-mail Pi extension: the native tools pi-mail.js calls and the outcome it returns.
/// The extension's own loop behaviour (budgets, nudge, outcome mapping) is covered by
/// tools/pi-host-proof/runtime/mail-reply.test.mjs.
final class MailPiReplyTests: XCTestCase {
    private let email = "Hi,\nCan you confirm the room is Oak? We could also use Birch or Cedar.\nThanks"

    private func evidence(_ text: String, outgoing: Bool = false) -> MailDraftWorkflow.Evidence {
        .init(id: UUID().uuidString, kind: "selectedMessage", source: (outgoing ? "Outgoing" : "Incoming") + " · Room", text: text, coverage: "full")
    }

    private func tools(read: [MailDraftWorkflow.Evidence] = []) -> MailPiReply.Tools {
        .init(readThread: { read }, search: { _ in read }, attachments: { [] },
              checkReply: { body, passages in
                  try MailDraftPrompt.checkGrounding(in: body, suppliedText: self.email, authorInstruction: "Write my reply.",
                                                     optionalThreadPassages: passages)
              }, selectedText: email)
    }

    private func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments]), as: UTF8.self)
    }

    func testReadsAreCappedMarkOwnerAndBecomeCheckablePassages() async throws {
        let passages = MailPiReply.Passages()
        let many = (0..<10).map { evidence("Earlier note \($0): the deposit is $40.", outgoing: $0 == 0) }
        var seen: [String] = []
        var tools = tools(read: many)
        let grounding = tools.checkReply
        tools.checkReply = { body, passages in seen = passages; try grounding(body, passages) }
        var result = try await MailPiReply.handle(try call("check_reply", ["body": "The deposit is $40."]), tools: tools, passages: passages)
        XCTAssertEqual(result["ok"] as? Bool, false, "An amount the email doesn't state is refused")
        XCTAssertNotNil(result["problem"] as? String)
        XCTAssertTrue(seen.isEmpty)
        result = try await MailPiReply.handle(try call("read_thread", [:]), tools: tools, passages: passages)
        let records = try XCTUnwrap(result["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, MailPiReply.maxRecords)
        XCTAssertEqual(records.first?["from"] as? String, "owner")
        XCTAssertEqual(records.last?["from"] as? String, "correspondent")
        result = try await MailPiReply.handle(try call("check_reply", ["body": "Yes, the room is Oak."]), tools: tools, passages: passages)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(seen.count, MailPiReply.maxRecords, "What the model read is offered to the check")
    }

    func testSearchNeedsAShortLiteralQuery() async throws {
        let result = try await MailPiReply.handle(try call("search_mail", ["query": "x"]), tools: tools(), passages: .init())
        XCTAssertNotNil(result["error"])
    }

    func testReadFailureIsReturnedToTheModel() async throws {
        var failing = tools()
        failing.readThread = { throw MailDraftWorkflow.NeedsInput(message: "Finish entering the recipients before using earlier messages.") }
        let result = try await MailPiReply.handle(try call("read_thread", [:]), tools: failing, passages: .init())
        XCTAssertEqual(result["error"] as? String, "Finish entering the recipients before using earlier messages.")
    }

    func testPickerKeepsOnlyQuestionsAndOptionsFromTheEmail() async throws {
        let questions: [[String: Any]] = [
            ["question": "Is the room Oak?", "control": "pick_one", "options": ["Oak", "Birch", "Maple"], "quote": "Can you confirm the room is Oak?"],
            ["question": "What is the budget?", "control": "amount", "options": [], "quote": "What is your budget?"],
        ]
        let result = try await MailPiReply.handle(try call("check_picker", ["reply": "needed", "questions": questions]), tools: tools(), passages: .init())
        let picker = try XCTUnwrap(result["picker"] as? [String: Any])
        let kept = try XCTUnwrap(picker["questions"] as? [[String: Any]])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0]["options"] as? [String], ["Oak", "Birch"])
    }

    func testOutcomeDecoding() throws {
        XCTAssertEqual(try MailPiReply.decode(["body": "Yes."]), .draft("Yes."))
        XCTAssertEqual(try MailPiReply.decode(["noReply": true, "reason": "A notice."]), .noReply("A notice."))
        XCTAssertEqual(try MailPiReply.decode(["note": "Which day?"]), .note("Which day?"))
        XCTAssertEqual(try MailPiReply.decode(["questions": [["question": "Is it Oak?", "control": "yes_no", "options": [], "quote": "q"]], "reply": "needed"]),
                       .questions(.init(reply: .needed, questions: [.init(question: "Is it Oak?", control: .yesNo, options: [], quote: "q")])))
        XCTAssertThrowsError(try MailPiReply.decode(["error": "Too long."]))
    }
}
#endif
