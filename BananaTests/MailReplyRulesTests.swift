import XCTest

/// Who a reply goes to and what it is called (MAIL-UX 6.3.3, MAIL-ENGINE 7.2): to the sender, or to
/// everyone but him; "Re:" once; and his own address never among the people.
final class MailReplyRulesTests: XCTestCase {

    private let me = MailPerson(name: "Noor", address: "noor@plan.example", isMe: true, isKnown: true,
                                fromTheirMail: false)
    private let sam = MailPerson(name: "Sam Lee", address: "sam@lee.example", isMe: false, isKnown: true,
                                 fromTheirMail: false)
    private let jane = MailPerson(name: "Jane Park", address: "jane@parkdesign.example", isMe: false,
                                  isKnown: true, fromTheirMail: false)
    private let ana = MailPerson(name: "Ana Ruiz", address: "ana@northwind.example", isMe: false,
                                 isKnown: false, fromTheirMail: false)
    private let desk = MailPerson(name: "Support desk", address: "desk@help.example", isMe: false,
                                  isKnown: false, fromTheirMail: false)

    private func message(from: MailPerson, to: [MailPerson], cc: [MailPerson] = [],
                         replyTo: [MailPerson] = []) -> MailMessage {
        MailMessage(id: MailMessageID(account: "noor@plan.example", message: "t~1"), from: from, to: to, cc: cc,
                    bcc: [], replyTo: replyTo, deliveredTo: nil, listName: nil, date: Date(), isUnread: false,
                    isMine: from.isMe, firstLine: "", body: .text, attachments: [], delivery: nil, draft: nil)
    }

    private func recipients(_ kind: MailDraftKind, _ original: MailMessage,
                            mine: Set<String> = ["noor@plan.example"]) -> MailReplyRules.Recipients {
        MailReplyRules.recipients(for: kind, original: original, myAddresses: mine)
    }

    private let anyMessage = MailMessageID(account: "noor@plan.example", message: "t~1")

    private func addresses(_ people: [MailPerson]) -> [String] { people.map(\.address) }

    // MARK: Who it goes to

    func testAReplyGoesToTheSenderAlone() {
        let original = message(from: sam, to: [me, jane], cc: [ana])
        let result = recipients(.reply(to: anyMessage), original)
        XCTAssertEqual(addresses(result.to), ["sam@lee.example"])
        XCTAssertEqual(result.cc, [])
    }

    func testAReplyGoesToWhereTheSenderAskedForRepliesWhenTheyAskedForSomewhere() {
        let original = message(from: sam, to: [me], replyTo: [desk])
        XCTAssertEqual(addresses(recipients(.reply(to: anyMessage), original).to), ["desk@help.example"])
    }

    func testAReplyToWhatHeWroteGoesToThoseHeWroteItTo() {
        let original = message(from: me, to: [sam, jane])
        XCTAssertEqual(addresses(recipients(.reply(to: anyMessage), original).to),
                       ["sam@lee.example", "jane@parkdesign.example"],
                       "answering himself would be writing to himself")
    }

    func testReplyToAllAddsTheOthersAndNeverHisOwnAddress() {
        let original = message(from: sam, to: [jane, me], cc: [ana, me])
        let result = recipients(.replyAll(to: anyMessage), original)
        XCTAssertEqual(addresses(result.to), ["sam@lee.example", "jane@parkdesign.example"])
        XCTAssertEqual(addresses(result.cc), ["ana@northwind.example"], "a Cc stays a Cc")
        XCTAssertFalse((result.to + result.cc).contains { $0.isMe || $0.address == "noor@plan.example" })
    }

    func testHisOwnAddressIsLeftOutHoweverItIsWritten() {
        // Another of his addresses, in another case, on a person who is not marked as him.
        let other = MailPerson(name: nil, address: "Noor@Work.example", isMe: false, isKnown: false,
                               fromTheirMail: false)
        let original = message(from: sam, to: [other, jane])
        let result = recipients(.replyAll(to: anyMessage), original, mine: ["noor@plan.example", "noor@work.example"])
        XCTAssertEqual(addresses(result.to), ["sam@lee.example", "jane@parkdesign.example"])
    }

    func testAMessageFromAnotherOfHisAddressesIsAnsweredAsHisOwn() {
        let alias = MailPerson(name: "Noor", address: "noor@work.example", isMe: false, isKnown: false,
                               fromTheirMail: false)
        let original = message(from: alias, to: [sam])
        let result = recipients(.reply(to: anyMessage), original, mine: ["noor@plan.example", "noor@work.example"])
        XCTAssertEqual(addresses(result.to), ["sam@lee.example"])
    }

    func testNobodyIsInTheResultTwiceInToOrInCc() {
        let loud = MailPerson(name: "SAM", address: "SAM@lee.example", isMe: false, isKnown: false,
                              fromTheirMail: false)
        let original = message(from: sam, to: [loud, jane, jane], cc: [sam, ana, ana])
        let result = recipients(.replyAll(to: anyMessage), original)
        XCTAssertEqual(addresses(result.to), ["sam@lee.example", "jane@parkdesign.example"])
        XCTAssertEqual(addresses(result.cc), ["ana@northwind.example"],
                       "the person who is in To is not also in Cc")
    }

    func testAMessageToHimselfAloneHasNobodyToReplyToAllOf() {
        let original = message(from: me, to: [me])
        let result = recipients(.replyAll(to: anyMessage), original)
        XCTAssertEqual(result.to, [])
        XCTAssertEqual(result.cc, [])
    }

    func testAForwardAndANewMessageGoToNobodyYet() {
        let original = message(from: sam, to: [me, jane])
        XCTAssertEqual(recipients(.forward(anyMessage), original), MailReplyRules.Recipients(to: [], cc: []))
        XCTAssertEqual(recipients(.new(account: nil), original), MailReplyRules.Recipients(to: [], cc: []))
    }

    // MARK: What it is called

    func testTheSubjectHasReOnceAndNeverStacked() {
        let reply = MailDraftKind.reply(to: anyMessage)
        XCTAssertEqual(MailReplyRules.subject(for: reply, original: "Q3 numbers"), "Re: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: reply, original: "Re: Q3 numbers"), "Re: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: reply, original: "Re: Re: Q3 numbers"), "Re: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: reply, original: "RE: re:  Q3 numbers"), "Re: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: reply, original: "re:Q3 numbers"), "Re: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: .replyAll(to: anyMessage), original: "Re: Q3 numbers"),
                       "Re: Q3 numbers")
    }

    func testAReplyToNothingSaidIsJustRe() {
        XCTAssertEqual(MailReplyRules.subject(for: .reply(to: anyMessage), original: ""), "Re:")
        XCTAssertEqual(MailReplyRules.subject(for: .reply(to: anyMessage), original: "  Re:  "), "Re:")
    }

    func testAForwardHasFwdOnceWhateverItWasSpelledAs() {
        let forward = MailDraftKind.forward(anyMessage)
        XCTAssertEqual(MailReplyRules.subject(for: forward, original: "Q3 numbers"), "Fwd: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: forward, original: "Fwd: Q3 numbers"), "Fwd: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: forward, original: "FW: Fwd: Q3 numbers"), "Fwd: Q3 numbers")
    }

    func testEachKeepsTheOtherKindsPrefixBecauseThatIsWhatTheSubjectSays() {
        XCTAssertEqual(MailReplyRules.subject(for: .forward(anyMessage), original: "Re: Q3 numbers"),
                       "Fwd: Re: Q3 numbers")
        XCTAssertEqual(MailReplyRules.subject(for: .reply(to: anyMessage), original: "Fwd: Q3 numbers"),
                       "Re: Fwd: Q3 numbers")
    }

    func testANewMessageHasNoSubjectAndAMailtoLinkHasTheOneItAsked() {
        XCTAssertEqual(MailReplyRules.subject(for: .new(account: nil), original: "ignored"), "")
        XCTAssertEqual(MailReplyRules.subject(for: .toAddress(["a@b.example"], subject: "Hello"),
                                              original: "ignored"), "Hello")
        XCTAssertEqual(MailReplyRules.subject(for: .toAddress(["a@b.example"], subject: nil),
                                              original: "ignored"), "")
    }

    // MARK: What it answers

    func testAReplyAnswersTheNewestMessage() {
        let first = message(from: sam, to: [me])
        var second = message(from: jane, to: [me, sam])
        second = MailMessage(id: MailMessageID(account: "noor@plan.example", message: "t~2"), from: second.from,
                             to: second.to, cc: [], bcc: [], replyTo: [], deliveredTo: nil, listName: nil,
                             date: Date(), isUnread: false, isMine: false, firstLine: "", body: .text,
                             attachments: [], delivery: nil, draft: nil)
        let id = MailConversationID(account: "noor@plan.example", thread: "t")
        let conversation = MailConversation(
            id: id, subject: "Q3", labels: [], inInbox: true, isStarred: false, isImportant: false,
            isMuted: false, snoozedUntil: nil, system: nil, messages: [first, second], invite: nil,
            unsubscribe: nil, draft: nil, newestIsMine: false, appliedThrough: 0)
        XCTAssertEqual(MailReplyRules.original(in: conversation)?.id.message, "t~2")
        let empty = MailConversation(
            id: id, subject: "", labels: [], inInbox: true, isStarred: false, isImportant: false,
            isMuted: false, snoozedUntil: nil, system: nil, messages: [], invite: nil, unsubscribe: nil,
            draft: nil, newestIsMine: false, appliedThrough: 0)
        XCTAssertNil(MailReplyRules.original(in: empty))
    }
}
