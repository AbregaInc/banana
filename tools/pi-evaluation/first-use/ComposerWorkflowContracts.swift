import Foundation

@main
enum ComposerWorkflowContracts {
    typealias Lookup = MailDraftWorkflow.Lookup
    typealias Evidence = MailDraftWorkflow.Evidence

    struct Scenario {
        let name: String
        let task: String
        var quoted = ""
        var selectedID: String?
        var workingDraft = ""
        var extraRecipient = false
        var readDenied = false
        var mayRequestMissingAttachment = true
        var expectedReads: [Lookup] = []
        var returned: [Evidence] = []
        var history: [Evidence]?
        var historyReads = 0
        var expectedHistoryText: String?
        var steps: [[String: Any]]
        var expected: String?
    }

    static func step(_ action: String, _ value: String, _ citations: [[String: String]] = []) -> [String: Any] {
        ["action": action, "value": value, "citations": citations]
    }

    @MainActor
    static func main() async throws {
        let fee = "The registration fee is $35."
        let attachment = Evidence(id: "native-file", kind: "attachment", source: "Fee schedule",
                                  text: fee, coverage: "Extracted attachment excerpt")
        let earlier = Evidence(id: "native-message", kind: "relatedMessage", source: "Travel voucher",
                               text: "The travel voucher is BLUE.", coverage: "Cached message")
        let supportedSource: [String: Any] = ["status": "answered", "answerQuote": earlier.text]
        let verified: [String: Any] = ["sourceAnswersQuestion":"supported", "replyFollowsFromSource":"supported", "quote": earlier.text]
        var differentItem = verified
        differentItem["sourceAnswersQuestion"] = "unsupported"
        var unsupportedQuote = verified
        unsupportedQuote["quote"] = "This is an invented passage."
        let quote = [["id": "S1", "quote": fee]]
        let history = Evidence(id: "native-prior", kind: "selectedMessage", source: "Outgoing · Owner · prior",
                               text: "The fee is $35.", coverage: "Cached message")
        let priorSize = Evidence(id: "native-size", kind: "selectedMessage", source: "Owner", text: "The sleeve is 125 mm.", coverage: "Cached message")
        let priceAndSize = Evidence(id: "native-sheet", kind: "attachment", source: "Sheet", text: "Price $6. Sleeve 125 mm.", coverage: "Extracted excerpt")
        let senderRequest = "My permit is in the dispatch office. Could you check with the clerk?"
        let ownerRequest = Evidence(id: "owner-note", kind: "selectedMessage", source: "Outgoing · Prior note",
                                    text: senderRequest, coverage: "Cached message")
        let courtesy = "I can't wait to see everyone at the gathering."
        let recovered = Evidence(id: "native-other-thread", kind: "selectedMessage", source: "Outgoing · Voucher · Owner · prior",
                                 text: "The travel voucher is BLUE.", coverage: "Cached message", recoveredThreadMessage: true)
        let cases = [
            Scenario(name: "earlier mail from another thread must answer a bare reply", task: "Write my reply.", quoted: "What colour is the voucher?",
                     selectedID: "anchor", history: [recovered], historyReads: 1,
                     steps: [step("draft", "The voucher is blue.", [["id":"S1","quote":"The travel voucher is BLUE."]]), ["status":"missing","answerQuote":""]]),
            Scenario(name: "the owner's answers are not rechecked against earlier mail", task: "Write my reply. My answers: What colour is the voucher? → Blue",
                     quoted: "What colour is the voucher?", selectedID: "anchor", history: [recovered], historyReads: 1,
                     steps: [step("draft", "The voucher is blue.")], expected: "The voucher is blue."),
            Scenario(name: "a reply cannot simply echo the correspondent’s own request",
                     task: "Write my reply.", quoted: senderRequest, selectedID: "anchor",
                     steps: [step("draft", senderRequest)]),
            Scenario(name: "sender attribution is separate from their own message",
                     task: "Write my reply.", quoted: "sender@example.test wrote:\n" + senderRequest, selectedID: "anchor",
                     steps: [step("draft", senderRequest)]),
            Scenario(name: "ordinary reciprocal courtesy remains available",
                     task: "Write my reply.", quoted: courtesy, selectedID: "anchor",
                     steps: [step("draft", courtesy)], expected: courtesy),
            Scenario(name: "an actual earlier owner message supports shared wording",
                     task: "Write my reply.", quoted: senderRequest, selectedID: "anchor", history: [ownerRequest], historyReads: 1,
                     steps: [step("draft", senderRequest)], expected: senderRequest),
            Scenario(name: "explicit owner dictation retains the requested words",
                     task: "Write these exact words: " + senderRequest, quoted: senderRequest, selectedID: "anchor",
                     steps: [step("draft", senderRequest)], expected: senderRequest),
            Scenario(name: "existing owner-authored working text remains editable",
                     task: "Write my reply.", quoted: senderRequest, selectedID: "anchor", workingDraft: senderRequest,
                     steps: [step("draft", senderRequest)], expected: senderRequest),
            Scenario(name: "a visible earlier size may be converted", task: "Write my reply.", quoted: "How long is the sleeve?", selectedID: "anchor",
                     history: [priorSize], historyReads: 1, steps: [step("draft","The sleeve is 12.5 cm.")], expected: "The sleeve is 12.5 cm."),
            Scenario(name: "an additional file read still needs a cited measurement", task: "Write my reply.", quoted: "What size is the sleeve?", selectedID: "anchor",
                     expectedReads: [.attachments], returned: [priceAndSize], history: [priorSize], historyReads: 1,
                     steps: [step("read_attachments",""), step("draft","The sleeve is 12.5 cm.", [["id":"S2","quote":"Price $6."]])]),
            Scenario(name: "other source kinds cannot enter optional quantity support", task: "Write my reply.", quoted: "What size is the sleeve?", selectedID: "anchor",
                     history: [priceAndSize], historyReads: 1, steps: [step("draft","The sleeve is 12.5 cm.")]),
            Scenario(name: "an invented size cannot enter a reply", task: "Write my reply.", quoted: "How long is the sleeve?", selectedID: "anchor",
                     history: [priorSize], historyReads: 1, steps: [step("draft","The sleeve is 10 cm.")]),
            Scenario(name: "a file must cite the exact measurement", task: "Read the attached file and answer.", selectedID: "anchor",
                     expectedReads: [.attachments], returned: [priceAndSize],
                     steps: [step("draft","The sleeve is 12.5 cm.", [["id":"S1","quote":"Price $6."]])]),
            Scenario(name: "a verified file measurement can be converted", task: "Read the attached file and answer.", selectedID: "anchor",
                     expectedReads: [.attachments], returned: [priceAndSize],
                     steps: [step("draft","The sleeve is 12.5 cm.", [["id":"S1","quote":"Sleeve 125 mm."]])], expected: "The sleeve is 12.5 cm."),
            Scenario(name: "ordinary reply uses scoped prior fact", task: "Write my reply.", quoted: "What was the fee?", selectedID: "anchor",
                     history: [history], historyReads: 1, expectedHistoryText: "Outgoing · Owner · prior",
                     steps: [step("draft", "The fee is $35.", [["id":"S1", "quote":"The fee is $35."]])], expected: "The fee is $35."),
            Scenario(name: "inline answer needs no optional history citation", task: "Write my reply.", quoted: "The colour is violet. Can you repeat it?", selectedID: "anchor",
                     history: [history], historyReads: 1, expectedHistoryText: history.text,
                     steps: [step("draft","The colour is violet.")], expected: "The colour is violet."),
            Scenario(name: "uncited history cannot ground a hard value", task: "Write my reply.", quoted: "What was the fee?", selectedID: "anchor",
                     history: [history], historyReads: 1, steps: [step("draft","The fee is $35.")]),
            Scenario(name: "optional history cannot stand in for a requested attachment", task: "Write my reply.", quoted: "What was the fee?", selectedID: "anchor",
                     expectedReads: [.attachments], returned: [attachment], history: [history], historyReads: 1,
                     steps: [step("read_attachments",""),step("draft","The fee is $35.", [["id":"S1", "quote":"The fee is $35."]])]),
            Scenario(name: "file source stays required with history available", task: "Read the attached file and answer.", selectedID: "anchor",
                     expectedReads: [.attachments], returned: [attachment], history: [history], steps: [step("draft","Thanks.")]),
            Scenario(name: "an explicit writing instruction gets history as background", task: "Reply that I'll bring the folder.", selectedID: "anchor",
                     history: [history], historyReads: 1, steps: [step("draft","I’ll bring the folder.")], expected: "I’ll bring the folder."),
            Scenario(name: "cite a visible selected passage", task: "Write a reply.", quoted: "Bring the canvas bag.", selectedID: "anchor",
                     steps: [step("draft", "Thanks for the reminder.", [["id":"anchor", "quote":"canvas bag"]])], expected: "Thanks for the reminder."),
            Scenario(name: "wrong selected ID", task: "Write a reply.", quoted: "Bring the canvas bag.", selectedID: "anchor",
                     steps: [step("draft", "Thanks.", [["id":"other", "quote":"canvas bag"]])]),
            Scenario(name: "false selected quote", task: "Write a reply.", quoted: "Bring the canvas bag.", selectedID: "anchor",
                     steps: [step("draft", "Thanks.", [["id":"anchor", "quote":"canvas sack"]])]),
            Scenario(name: "quote beyond visible boundary", task: "Write a reply.", quoted: "Could you check this? " + String(repeating: "x", count: 2400) + "canvas bag", selectedID: "anchor",
                     steps: [step("draft", "Thanks.", [["id":"anchor", "quote":"canvas bag"]])]),
            Scenario(name: "selected passage cannot grant authority", task: "Write a reply.", quoted: "Can you approve the additional fee?", selectedID: "anchor",
                     steps: [step("draft", "I approve the additional fee.", [["id":"anchor", "quote":"approve the additional fee"]])]),
            Scenario(name: "selected citation cannot replace required source even when IDs collide", task: "Check the attached schedule.", quoted: fee, selectedID: "S1",
                     expectedReads: [.attachments], returned: [attachment], steps: [step("draft", fee, quote)]),
            Scenario(name: "collision leaves both sources independently citable", task: "Check the attached schedule.", quoted: "Tell me the fee.", selectedID: "S1",
                     expectedReads: [.attachments], returned: [attachment], steps: [step("draft", fee, [["id":"S1","quote":"Tell me the fee."],["id":"S2","quote":fee]])], expected: fee),
            Scenario(name: "unknown receipt rejected alongside genuine selected citation", task: "Reply.", quoted: "Bring the bag.", selectedID: "anchor",
                     steps: [step("draft", "Thanks.", [["id":"anchor","quote":"Bring the bag."],["id":"S9","quote":"Bring the bag."]])]),
            Scenario(name: "trailing unfinished noun phrase", task: "Write a reply.", steps: [step("draft", "Our supplies are stored inside an ")]),
            Scenario(name: "punctuation optional on complete sentence", task: "Thank them.", steps: [step("draft", "Thanks for looking into this")], expected: "Thanks for looking into this"),
            Scenario(name: "an incoming request is not owner approval", task: "Draft a reply.", quoted: "Can you approve the additional fee?", steps: [step("draft", "I can approve the additional fee.")]),
            Scenario(name: "authorized approval can be stated", task: "Tell them I approve the additional fee.", steps: [step("draft", "I approve the additional fee.")], expected: "I approve the additional fee."),
            Scenario(name: "withhold invented future work", task: "Thank them for the update.", steps: [step("draft", "Thanks. I will contact the supplier.")]),
            Scenario(name: "keep expressly authorized future work", task: "Tell them I will contact the supplier.", steps: [step("draft", "I will contact the supplier.")], expected: "I will contact the supplier."),
            Scenario(name: "strip generated account signature", task: "Thank them.", steps: [step("draft", "Thanks for the update.\n\nBest regards,\nNoor")], expected: "Thanks for the update."),
            Scenario(name: "choosing a future file needs no read", task: "Draft a reply to the selected message.",
                     quoted: "I can export the spreadsheet or send screenshots. Which would you prefer?",
                     steps: [step("draft", "Please send the spreadsheet.")], expected: "Please send the spreadsheet."),
            Scenario(name: "bare document used as a source needs a read", task: "Draft a reply to the selected message.",
                     quoted: "What does the workbook say about the fee?", expectedReads: [.attachments], steps: []),
            Scenario(name: "one call to edit", task: "Make this warmer.", steps: [step("draft", "Thanks for your help!")], expected: "Thanks for your help!"),
            Scenario(name: "acknowledgment needs no file read", task: "Thank them for the attached report.",
                     steps: [step("draft", "Thank you for sharing the report.")], expected: "Thank you for sharing the report."),
            Scenario(name: "generic reply resolves selected attachment", task: "Draft a reply to the selected message.",
                     quoted: "Can you tell me the fee from the attached schedule?", expectedReads: [.attachments], returned: [attachment],
                     steps: [step("draft", fee, quote)], expected: fee),
            Scenario(name: "missing file cannot produce a draft", task: "Read the attachment and tell them the fee.", expectedReads: [.attachments], steps: []),
            Scenario(name: "wrong source cannot stand in for a file", task: "Use the attached schedule.", expectedReads: [.attachments], returned: [earlier], steps: []),
            Scenario(name: "invented receipt rejected", task: "Read the attachment and tell them the fee.", expectedReads: [.attachments],
                     returned: [attachment], steps: [step("draft", fee, [["id": "S1", "quote": "the rate is $70"]])]),
            Scenario(name: "unsupported price rejected even with genuine citation", task: "Read the attached schedule.", expectedReads: [.attachments],
                     returned: [attachment], steps: [step("draft", "The registration fee is $80.", quote)]),
            Scenario(name: "related source cannot be skipped", task: "Check the earlier email and answer the question.",
                     steps: [step("draft", "Your voucher is BLUE.")]),
            Scenario(name: "quoted title reads directly", task: "Check the earlier email “Travel voucher” for its code.",
                     expectedReads: [.titledMail("Travel voucher")], returned: [earlier],
                     steps: [step("draft", "The travel voucher is BLUE.", [["id":"S1", "quote":"The travel voucher is BLUE."]]), supportedSource, verified],
                     expected: "The travel voucher is BLUE."),
            Scenario(name: "implicit historical topic", task: "Draft a reply to the selected message.",
                     quoted: "Can you check the earlier message about the travel voucher?", expectedReads: [.related("travel voucher")], returned: [earlier],
                     steps: [step("search_mail", "travel voucher"), step("draft", "The travel voucher is BLUE.", [["id":"S1", "quote":"The travel voucher is BLUE."]]), supportedSource, verified],
                     expected: "The travel voucher is BLUE."),
            Scenario(name: "cannot verify a draft from an unanswered source", task: "Check the earlier email “Travel voucher” for its code.",
                     expectedReads: [.titledMail("Travel voucher")], returned: [earlier],
                     steps: [step("draft", earlier.text, [["id":"S1","quote":earlier.text]]), ["status":"missing","answerQuote":""]]),
            Scenario(name: "independent answer must quote the source", task: "Check the earlier email “Travel voucher” for its code.",
                     expectedReads: [.titledMail("Travel voucher")], returned: [earlier],
                     steps: [step("draft", earlier.text, [["id":"S1","quote":earlier.text]]), ["status":"answered","answerQuote":"absent"]]),
            Scenario(name: "related fact on another item is withheld", task: "Check the earlier email “Travel voucher” for the rail voucher.",
                     quoted: "Do you have the rail voucher code?", expectedReads: [.titledMail("Travel voucher")], returned: [earlier],
                     steps: [step("draft", earlier.text, [["id":"S1","quote":earlier.text]]), supportedSource, differentItem]),
            Scenario(name: "invalid independent verification is withheld", task: "Check the earlier email “Travel voucher” for its code.",
                     expectedReads: [.titledMail("Travel voucher")], returned: [earlier],
                     steps: [step("draft", earlier.text, [["id":"S1","quote":earlier.text]]), supportedSource, ["answer":"supported"]]),
            Scenario(name: "independent verification needs a real quote", task: "Check the earlier email “Travel voucher” for its code.",
                     expectedReads: [.titledMail("Travel voucher")], returned: [earlier],
                     steps: [step("draft", earlier.text, [["id":"S1","quote":earlier.text]]), supportedSource, unsupportedQuote]),
            Scenario(name: "calendar availability needs a capability", task: "Write my reply.", quoted: "Could you check your availability for the pickup?", steps: []),
            Scenario(name: "overlap check needs calendar evidence", task: "Reply.", quoted: "Would the tour conflict with anything on your schedule tomorrow?", steps: []),
            Scenario(name: "calendar clear question needs a lookup", task: "Write my reply.", quoted: "Is your calendar open for our review?", steps: []),
            Scenario(name: "specific time asks for real availability", task: "Write my reply.", quoted: "Are you free on Friday to meet?", steps: []),
            Scenario(name: "time first in owner availability question", task: "Draft a reply.", quoted: "Is Thursday afternoon still free on your schedule?", steps: []),
            Scenario(name: "a calendar question cannot authorize booking", task: "Write my reply.", quoted: "Is Tuesday, 6 May, from 14:00 to 14:30 clear on your calendar? Please don’t book it yet.", steps: []),
            Scenario(name: "the correspondent reports their own free slot", task: "Reply.", quoted: "Thursday is open on my calendar.",
                     steps: [step("draft", "Thanks for the update.")], expected: "Thanks for the update."),
            Scenario(name: "owner states availability without a lookup", task: "Tell them I am free for the pickup.", quoted: "Can you check your calendar?",
                     steps: [step("draft", "I am free for the pickup.")], expected: "I am free for the pickup."),
            Scenario(name: "acknowledging scheduling update needs no lookup", task: "Write my reply.", quoted: "The tour is on my calendar.",
                     steps: [step("draft", "Thanks for the update.")], expected: "Thanks for the update."),
            Scenario(name: "use the revised file on this message", task: "Write my reply.", quoted: "Please use the corrected document on this message. What is the fee?", expectedReads: [.attachments], returned: [attachment], steps: [step("draft", fee, quote)], expected: fee),
            Scenario(name: "literal earlier same-thread attachment", task: "Write my reply.", quoted: "Could you check the spreadsheet earlier in this conversation? What is the fee?", expectedReads: [.earlierThreadAttachments],
                     returned: [Evidence(id: "prior-file", kind: "earlierThreadAttachment", source: "Fee sheet", text:fee, coverage:"Earlier file")], steps: [step("draft", fee, quote)], expected: fee),
            Scenario(name: "selected file cannot stand in for the earlier one", task: "Write my reply.", quoted: "Check the sheet earlier in this thread. What is the fee?", expectedReads: [.earlierThreadAttachments], returned: [attachment], steps: []),
            Scenario(name: "uniquely named separate message from correspondent", task: "Write my reply.", quoted: "Could you check the earlier mail titled “Travel voucher”? What is the voucher?", expectedReads: [.titledMail("Travel voucher")], returned:[earlier],
                     steps: [step("draft", earlier.text, [["id":"S1","quote":earlier.text]]), supportedSource, verified], expected: earlier.text),
            Scenario(name: "a prior file and separate named message both need receipts", task: "Answer the sender's question.", quoted: "Check the sheet earlier in this thread and the earlier email titled “Travel voucher”. What is the fee?",
                     expectedReads: [.earlierThreadAttachments, .titledMail("Travel voucher")], returned: [Evidence(id:"prior-file",kind:"earlierThreadAttachment", source:"Fee sheet",text:fee,coverage:"Earlier file"),earlier],
                     steps: [step("draft", fee, [["id":"S1","quote":fee]])]),
            Scenario(name: "reject three required sources before advancing", task: "Write my reply.", quoted: "Compare the revised file on this message with the sheet earlier in this thread and the email titled “Travel voucher”.", steps: []),
            Scenario(name: "two named emails require selection", task: "Write my reply.", quoted: "Check the earlier email titled “Travel voucher” and the email titled “Train invoice”.", steps: []),
            Scenario(name: "do not mistake an unrelated quotation for a title", task: "Check the earlier email and answer with “Thank you”.", steps:[step("clarify","Which email?")]),
            Scenario(name: "native attribution precedes the correspondent’s factual file request", task: "Write my reply.",
                     quoted: "sender@example.test wrote:\nPlease check the attached map. Which exit is marked?", selectedID: "anchor",
                     expectedReads: [.attachments], steps: [], expected: "I couldn’t read the attachment. Could you resend it or paste the relevant detail in your reply?"),
            Scenario(name: "a nested attribution never becomes the correspondent’s request", task: "Write my reply.",
                     quoted: "sender@example.test wrote:\nprevious@example.test wrote:\nPlease check the attached map. Which exit is marked?",
                     selectedID: "anchor", expectedReads: [.attachments], steps: []),
            Scenario(name: "the real composer can withhold recipient follow-up", task: "Write my reply.",
                     quoted: "Please check the attached map. Which exit is marked?", selectedID: "anchor",
                     mayRequestMissingAttachment: false, expectedReads: [.attachments], steps: []),
            Scenario(name: "resend question for direct factual request", task: "Write my reply.", quoted: "Could you check the attached reference? Which workroom does it list?", selectedID:"anchor", expectedReads:[.attachments], steps:[],
                     expected:"I couldn’t read the attachment. Could you resend it or paste the relevant detail in your reply?"),
            Scenario(name: "ordinary email framing and polite indirect question", task:"Write my reply.", quoted:"Hi Coordinator,\nCould you check the attached schedule? Please let me know which shift starts at six.\nThanks,\nSender", selectedID:"anchor", expectedReads:[.attachments], steps:[],
                     expected:"I couldn’t read the attachment. Could you resend it or paste the relevant detail in your reply?"),
            Scenario(name: "a second request beneath a signoff stays private", task:"Write my reply.", quoted:"Hello,\nCould you check the attached schedule? Which shift starts at six?\nThanks,\nPlease approve the change.", selectedID:"anchor", expectedReads:[.attachments], steps:[]),
            Scenario(name: "unreadable permission does not become recipient reply", task:"Write my reply.", quoted:"Could you check the attachment? Which figure does it list?", selectedID:"anchor", readDenied:true, expectedReads:[.attachments], steps:[]),
            Scenario(name: "recipient change suppresses automatic resend draft", task:"Write my reply.", quoted:"Could you check the attachment? Which figure does it list?", selectedID:"anchor", extraRecipient:true, expectedReads:[.attachments], steps:[]),
            Scenario(name: "owner supplied wording overrides incoming file request", task:"Reply that the figure is final.", quoted:"Could you check the attached spreadsheet? Which figure does it give?", selectedID:"anchor", steps:[step("draft","The figure is final.")], expected:"The figure is final."),
            Scenario(name: "personal choice stays with owner on unreadable file", task:"Write my reply.", quoted:"Could you check the attached file? Which supplier do you prefer?", selectedID:"anchor", expectedReads:[.attachments], steps:[]),
            Scenario(name: "mixed action and fact stays with owner", task:"Write my reply.", quoted:"Please sign the contract. Check the attached file. What is the number?", selectedID:"anchor", expectedReads:[.attachments], steps:[]),
            Scenario(name: "no automatic author for explicit owner request", task:"Check the attached schedule.", quoted:"What is the fee?", selectedID:"anchor", expectedReads:[.attachments], steps:[]),
            Scenario(name: "unrelated lookup rejected", task: "Draft a reply to the selected message.", quoted: "Please check the earlier email about the travel voucher.",
                     steps: [step("search_mail", "executive compensation")]),
            Scenario(name: "distinct earlier attachment scope", task: "Read the PDF in the earlier email “Travel voucher”.",
                     expectedReads: [.titledMailAttachments("Travel voucher")], returned: [attachment], steps: []),
            Scenario(name: "unregistered operation rejected", task: "Please reply.", steps: [step("send_mail", "Thanks.")]),
            Scenario(name: "clarification stays outside body", task: "Please reply.", steps: [step("clarify", "Which deadline should I use?")])
        ]
        for c in cases {
            let owner = MailDraftPrompt.Envelope.Party(name: nil, address: "owner@example.test")
            let sender = MailDraftPrompt.Envelope.Party(name: nil, address: "sender@example.test")
            let envelope = c.selectedID.map { id in
                MailDraftPrompt.Envelope(mode: .reply, from: owner, to: [sender], cc: c.extraRecipient ? [owner] : [], selectedMessage:
                    .init(account: "account", threadID: "thread", messageID: id, direction: .incoming, from: sender, to: [owner], cc: []))
            }
            let req = try MailDraftPrompt.request(instruction: c.task, subject: "", quotedEmail: c.quoted, workingDraft: c.workingDraft, envelope: envelope)
            var reads: [Lookup] = []
            var historyReads = 0
            var calls = 0
            var body: String?
            do {
                body = try await MailDraftWorkflow.write(request: req, suppliedText: c.task + "\n" + c.quoted, read: {
                    reads.append($0)
                    if c.readDenied { throw MailDraftWorkflow.NeedsInput(message: "Email access is unavailable.") }
                    return c.returned
                }, recentHistory: c.history.map { rows in
                    { historyReads += 1; return rows }
                }, mayRequestMissingAttachment: c.mayRequestMissingAttachment, generate: { request in
                    if let marker = c.expectedHistoryText {
                        let messages = request["messages"] as! [[String: String]]
                        precondition(messages.last?["text"]?.contains(marker) == true, c.name)
                    }
                    precondition(request["responseSchema"] != nil && calls < c.steps.count, c.name)
                    if c.steps[calls]["action"] == nil {
                        precondition(request["temperature"] as? Double == 0 && request["maxTokens"] as? Int == 200, c.name)
                        let messages = request["messages"] as! [[String:String]]
                        let input = try JSONSerialization.jsonObject(with: Data(messages[0]["text"]!.utf8)) as! [String:Any]
                        if c.steps[calls]["status"] != nil {
                            precondition(Set(input.keys) == ["ownerTask","question","passages"], c.name)
                            precondition(input["question"] as? String == c.quoted && !(input["passages"] as! [String]).isEmpty, c.name)
                        } else {
                            precondition(Set(input.keys) == ["ownerTask","subject","selectedMessage","proposedReply","sources"], c.name)
                            precondition(input["selectedMessage"] as? String == c.quoted && !(input["sources"] as! [[String:Any]]).isEmpty, c.name)
                        }
                    }
                    let bytes = try JSONSerialization.data(withJSONObject: c.steps[calls])
                    calls += 1
                    let message = ["content": [["type": "text", "text": String(decoding: bytes, as: UTF8.self)]]]
                    return String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
                })
            } catch is MailDraftWorkflow.NeedsInput {}
            precondition(body == c.expected && reads == c.expectedReads && calls == c.steps.count && historyReads == c.historyReads, c.name)
        }
        print("\(cases.count) composer workflow contracts passed")
    }
}
