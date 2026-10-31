#if !BANANA_PUBLIC
#if DEBUG || MAIL_FIXTURES
import Foundation

/// The sample mailbox: forty conversations, drawn from the set MAIL-UX 13.2 names, so a later
/// package that needs one finds it here under the same key (`q3`, `forty`, `rtl`…). The key is the
/// thread id, so `--mail-open q3` and the accessibility identifier `mail.list.row.q3` agree.
///
/// **Not Gmail's mailbox.** MAIL-UX 13.2 says the engine's package C0 defines the mailbox once, at
/// Gmail's level, and builds both sources from it. That is not built yet, so this is the same
/// conversations written at the screens' level: the rows and the conversations the contract hands
/// them. When C0 lands this file is what it replaces.
///
/// What is left out of 13.2's table: the conversations whose point is a state of the device that
/// this slice draws nothing for (`failed-send`, `draft-reply`, `unseen-reply`, `headers-only`,
/// `program`, the outbox, drafts and Done ones). A sample conversation without the state that
/// makes it interesting would only mislead.
///
/// **Now** is fixed: Monday 5 October 2026, 9:41 AM in the machine's time zone, so "9:12 AM" and
/// "Yesterday" never drift and a screenshot taken tomorrow is the same picture.
enum MailFixtureConversations {

    nonisolated static let account = "noor@plan.example"
    /// The second account, and the second "send as" address of the first (MAIL-UX 6.3.3: From is
    /// shown only when there is more than one identity to choose).
    nonisolated static let secondAccount = "noor@work.example"
    nonisolated static let alias = "hello@plan.example"

    // MARK: The clock

    nonisolated static var calendar: Calendar { .current }

    nonisolated static var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9, minute: 41)) ?? Date()
    }

    /// `day` days from today (negative is the past), at a time of day.
    nonisolated static func date(day: Int, _ hour: Int, _ minute: Int) -> Date {
        let today = calendar.startOfDay(for: now)
        let that = calendar.date(byAdding: .day, value: day, to: today) ?? today
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: that) ?? that
    }

    // MARK: People

    nonisolated static let me = MailPerson(name: "Noor", address: account, isMe: true, isKnown: true,
                                           fromTheirMail: false)
    nonisolated static let sam = person("Sam Lee", "sam@lee.example", known: true)
    nonisolated static let jane = person("Jane Park", "jane@parkdesign.example", known: true)
    nonisolated static let ana = person("Ana Ruiz", "ana@northwind.example")
    nonisolated static let tom = person("Tom Okafor", "tom@northwind.example")
    nonisolated static let mei = person("Mei Chen", "mei@northwind.example")
    nonisolated static let stripe = person("Stripe", "receipts@stripe.example")
    nonisolated static let github = person("GitHub", "notifications@github.example")
    nonisolated static let dispatch = person("Dispatch", "editor@dispatch.example")
    nonisolated static let linear = person("Linear", "notifications@linear.example")
    nonisolated static let airline = person("Meridian Air", "bookings@meridianair.example")
    nonisolated static let dentist = person("Dr. Alvarez's office", "front-desk@alvarezdental.example")
    /// A sender with no name: the row shows the address.
    nonisolated static let noName = MailPerson(name: nil, address: "no-reply@accounts.example.com",
                                               isMe: false, isKnown: false, fromTheirMail: false)
    /// His own address as a stranger's name: the engine withholds the name (MAIL-UX 6.2.3), so the
    /// row shows the address that actually sent it.
    nonisolated static let lookalike = MailPerson(name: nil, address: "billing@z0-support.example",
                                                  isMe: false, isKnown: false, fromTheirMail: false)
    nonisolated static let dana = person("דנה כהן", "dana@cohen.example")
    nonisolated static let leila = person("ليلى حداد", "leila@haddad.example")
    nonisolated static let replyDesk = person("Support desk", "desk@help.example")

    nonisolated private static func person(_ name: String, _ address: String, known: Bool = false) -> MailPerson {
        MailPerson(name: name, address: address, isMe: false, isKnown: known, fromTheirMail: false)
    }

    nonisolated static let invoices = MailLabelRef(id: "Label_1", name: "Invoices", colorHex: "#0B8043")

    // MARK: Shapes

    /// One message. A body line starting with ">" is a quote (one level per ">"); "• " is a list
    /// item; anything else is a paragraph.
    struct Message {
        var from: MailPerson
        var to: [MailPerson] = [MailFixtureConversations.me]
        var day = 0
        var hour: Int
        var minute: Int
        var unread = false
        var body: [String]
        var files: [(name: String, bytes: Int)] = []
        /// For a file that is not what its name says: its name, and the extension of what it is.
        var actually: [String: String] = [:]
        var replyTo: [MailPerson] = []
        /// Which of his addresses it was sent to; the account's own when nil. A reply is from the
        /// identity the message was sent to.
        var deliveredTo: String?
    }

    struct Sample {
        var key: String
        var subject: String
        var messages: [Message]
        var starred = false
        var important = true
        var labels: [MailLabelRef] = []
        var invite: MailInvite?
        var unsubscribe: MailUnsubscribe?
        /// A designed message in the real mailbox, shown here as text.
        var designed = false
    }

    static func stress(days: Int) -> [Sample] {
        (0..<(days * 2_000)).map { i in
            Sample(key: "stress-\(i)", subject: "Stress email \(i)", messages: [
                Message(from: sam, day: -(i / 2_000), hour: (i % 2_000) / 84,
                        minute: i % 60, unread: i.isMultiple(of: 3),
                        body: ["Deterministic stress message \(i). Project status and next steps."])
            ], starred: i.isMultiple(of: 19))
        }
    }

    // MARK: The mailbox

    /// Newest first is not promised: the source sorts by key.
    nonisolated static func threads() -> [Sample] {
        var all: [Sample] = []
        all += today()
        all += yesterday()
        all += thisWeek()
        all += earlier()
        return all
    }

    nonisolated private static func today() -> [Sample] {
        [
            Sample(key: "q3", subject: "Q3 numbers before Thursday", messages: [
                Message(from: sam, to: [me, jane], day: -3, hour: 16, minute: 20,
                        body: ["Jane, Noor, the Q3 revenue tab is nearly final.",
                               "Can you both look at the churn assumptions before Thursday? I changed the cohort cut-off from 90 to 120 days.",
                               "Spreadsheet attached, and a screenshot of the chart that moved the most."],
                        files: [("Q3-revenue.xlsx", 412_000), ("churn-chart.png", 188_000)]),
                Message(from: jane, to: [sam, me], day: -1, hour: 18, minute: 5,
                        body: ["Looks right to me except the EMEA line: the March refund is in twice.",
                               "> Can you both look at the churn assumptions before Thursday?"]),
                Message(from: sam, to: [jane, me], hour: 9, minute: 12, unread: true,
                        body: ["Good catch, Jane. Fixed, and the total moves by 1.8%.",
                               "Can you look at the revenue tab before the 11 o'clock? I would like to send it to Northwind straight after.",
                               "> Looks right to me except the EMEA line: the March refund is in twice."])
            ], starred: true, labels: [invoices]),
            Sample(key: "invite", subject: "Invitation: Design review", messages: [
                Message(from: jane, hour: 8, minute: 40, unread: true,
                        body: ["Jane Park invited you to a design review.",
                               "When: Tuesday 6 October, 9:00 to 9:45 AM",
                               "Where: Meet, link in the calendar event",
                               "Bring the two onboarding options you liked best."])
            ], invite: MailInvite(method: .request, uid: "design-review-1@parkdesign.example")),
            Sample(key: "receipt", subject: "Your receipt from Stripe", messages: [
                Message(from: stripe, hour: 8, minute: 15, unread: true,
                        body: ["Receipt from Stripe, payment to Abrega Inc.",
                               "Amount paid: $49.00",
                               "Date paid: 5 October 2026",
                               "Payment method: Visa ending 4242"])
            ], important: false, labels: [invoices]),
            Sample(key: "me-newest", subject: "Contract draft", messages: [
                Message(from: ana, day: -1, hour: 16, minute: 10,
                        body: ["Redlines attached, two questions on section 4.",
                               "Is the 30-day termination window what you wanted, and should the data clause name the region?"],
                        files: [("Contract-v3-redlines.pdf", 830_000)]),
                Message(from: me, to: [ana], hour: 8, minute: 2,
                        body: ["Thanks Ana. Thirty days is right, and yes, please name the EU region.",
                               "I will sign this week once that is in."])
            ], important: true),
            plainChain(),
            Sample(key: "vip-1", subject: "Kickoff agenda", messages: [
                Message(from: ana, hour: 7, minute: 5, unread: true,
                        body: ["Agenda for the kickoff on Thursday:",
                               "• Goals for the quarter",
                               "• What changed since the pilot",
                               "• Who owns the data migration",
                               "Anything you want added?"], deliveredTo: alias)
            ]),
            Sample(key: "newsletter", subject: "Dispatch no. 212: the week in review", messages: [
                Message(from: dispatch, hour: 6, minute: 50, unread: true,
                        body: ["The week in review: three stories worth your coffee.",
                               "1. A small team rewrote its billing system in a month, and what it cost them.",
                               "2. Why every dashboard you build gets ignored by Friday.",
                               "3. The quiet return of plain text email.",
                               "You are receiving this because you subscribed at dispatch.example."])
            ], important: false, unsubscribe: .oneClick(host: "dispatch.example"), designed: true),
            Sample(key: "standup", subject: "Standup notes: Monday", messages: [
                Message(from: tom, hour: 6, minute: 10,
                        body: ["Notes from standup:",
                               "\u{2022} The pilot numbers are in",
                               "\u{2022} The migration owner is still open",
                               "\u{2022} The demo moved to Thursday"])
            ], important: false),
        ]
    }

    nonisolated private static func yesterday() -> [Sample] {
        let day = -1
        var out: [Sample] = [
            Sample(key: "no-name", subject: "Your sign-in code is 481 220", messages: [
                Message(from: noName, day: day, hour: 19, minute: 44, unread: true,
                        body: ["Your sign-in code is 481 220.",
                               "It expires in ten minutes. If you did not ask for it, you can ignore this message."])
            ], important: false),
            Sample(key: "vip-2", subject: "Re: Pilot numbers", messages: [
                Message(from: tom, day: day, hour: 16, minute: 20,
                        body: ["The pilot numbers are in. Activation is up nine points on the cohort that saw the new checklist.",
                               "I will walk through the sheet on Thursday."])
            ]),
            Sample(key: "linear", subject: "Noor, 3 issues are waiting on you", messages: [
                Message(from: linear, day: day, hour: 11, minute: 12,
                        body: ["Three issues are assigned to you and have not moved this week:",
                               "• ENG-412 Retry the webhook on a 502",
                               "• ENG-431 Empty state for the invoices page",
                               "• ENG-440 Typo in the onboarding email"])
            ], important: false),
            Sample(key: "flight", subject: "Your trip to Lisbon: check-in opens tomorrow", messages: [
                Message(from: airline, day: day, hour: 9, minute: 30,
                        body: ["Check-in for flight MA 118 to Lisbon opens tomorrow at 7:05 PM.",
                               "Departure: Thursday 8 October, 6:40 AM",
                               "Your booking reference is KQ4T9R."])
            ], starred: true, important: false),
        ]
        // Eight notifications from one sender on one day: what multi-select is for.
        let pulls = ["Add retry to the webhook sender", "Fix empty invoice state", "Bump SwiftSoup",
                     "Rename the weekly digest job", "Remove dead feature flag", "Tighten the sync backoff",
                     "Add tests for the cursor", "Update the release notes"]
        for (index, title) in pulls.enumerated() {
            out.append(Sample(key: "github-\(index + 1)", subject: "[abrega/app] \(title) (#\(1_040 + index))", messages: [
                Message(from: github, day: day, hour: 14 + index / 2, minute: 5 + (index % 2) * 30, unread: index >= 5,
                        body: ["Sam Lee requested your review on this pull request.",
                               "\(title). Small change, two files, tests included.",
                               "Reply to this email directly or view it on GitHub."])
            ], important: false))
        }
        return out
    }

    nonisolated private static func thisWeek() -> [Sample] {
        [
            Sample(key: "emoji", subject: "\u{1F389}\u{1F389}\u{1F389}", messages: [
                Message(from: mei, day: -2, hour: 18, minute: 2, unread: true,
                        body: ["We signed the lease!"])
            ]),
            Sample(key: "lunch", subject: "Lunch Thursday?", messages: [
                Message(from: sam, day: -2, hour: 12, minute: 15,
                        body: ["Are you free for lunch on Thursday, after the Northwind call?",
                               "There is a ramen place two blocks from their office."]),
                Message(from: me, to: [sam], day: -2, hour: 12, minute: 40,
                        body: ["Yes. 12:30?"])
            ]),
            Sample(key: "rtl", subject: "שלום מדנה", messages: [
                Message(from: dana, day: -3, hour: 10, minute: 8,
                        body: ["שלום בוריס, אשמח לקבוע שיחה השבוע כדי לעבור על ההצעה.",
                               "תודה מראש, דנה"]),
                Message(from: leila, to: [me, dana], day: -3, hour: 14, minute: 31,
                        body: ["مرحبا بوريس، يسعدني أن أنضم إلى المكالمة.",
                               "هل يناسبكم يوم الخميس؟"])
            ]),
            forty(),
            Sample(key: "attachments", subject: "Signed documents and the logo pack", messages: [
                // Older than the rest, so the conversation sorts where it did. A text file, a CSV, and
                // an "invoice.pdf" that is really a picture: shown as what it is.
                Message(from: jane, day: -5, hour: 10, minute: 5,
                        body: ["The dashboard export and my notes from the call, before the signed copy.",
                               "The invoice is the scan the vendor sent, so it may not be what it says."],
                        files: [("dashboard-export.csv", 6_400), ("meeting-notes.txt", 1_900),
                                ("invoice-2026.pdf", 52_000)],
                        actually: ["invoice-2026.pdf": "png"]),
                Message(from: jane, day: -4, hour: 15, minute: 50,
                        body: ["Signed copy attached, plus the logo pack.",
                               "The zip is large; it is also in the shared folder."],
                        files: [("Services-agreement-signed.pdf", 2_400_000), ("logo-mark.png", 800_000),
                                ("brand-assets.zip", 48_000_000)])
            ]),
            Sample(key: "attachments-many", subject: "Receipts for the offsite", messages: [
                Message(from: tom, day: -5, hour: 9, minute: 14, unread: true,
                        body: ["All twelve receipts from the offsite, as promised."],
                        files: (1...12).map { ("receipt-\($0).pdf", 90_000 + $0 * 7_000) })
            ], important: false),
        ]
    }

    nonisolated private static func earlier() -> [Sample] {
        [
            longThread(),
            Sample(key: "big-image", subject: "The new onboarding hero", messages: [
                Message(from: jane, day: -6, hour: 11, minute: 25,
                        body: ["Here is the hero image for the new onboarding. It is large, so it is inline rather than attached.",
                               "[image: onboarding-hero.png]",
                               "I would love a second pair of eyes on the crop."])
            ], designed: true),
            Sample(key: "reply-to", subject: "Question about your invoice", messages: [
                Message(from: replyDesk, day: -7, hour: 13, minute: 3,
                        body: ["Thanks for getting in touch. Please send any follow-up to our billing team.",
                               "Replies to this message go to billing@help.example, not to the desk."],
                        replyTo: [person("Billing", "billing@help.example")])
            ], important: false),
            Sample(key: "vip-3", subject: "Re: Data migration owner", messages: [
                Message(from: mei, day: -8, hour: 17, minute: 40,
                        body: ["I can take the migration if Tom takes the customer comms.",
                               "Does that split work for you?"])
            ]),
            Sample(key: "three-newsletters", subject: "Your weekly reading", messages: [
                Message(from: dispatch, day: -9, hour: 7, minute: 0, unread: true,
                        body: ["Monday: the case for boring technology."]),
                Message(from: dispatch, day: -9, hour: 7, minute: 1, unread: true,
                        body: ["Tuesday: how a three-person team ships weekly."]),
                Message(from: dispatch, day: -9, hour: 7, minute: 2, unread: true,
                        body: ["Wednesday: the spreadsheet that runs a company."])
            ], important: false, unsubscribe: .oneClick(host: "dispatch.example"), designed: true),
            Sample(key: "lookalike", subject: "Action required: confirm your account", messages: [
                Message(from: lookalike, day: -10, hour: 4, minute: 11,
                        body: ["Dear noor@plan.example, please confirm your account to avoid interruption.",
                               "This sender's name reads like your own address, so Mail shows the address it really came from."])
            ], important: false),
            Sample(key: "no-subject", subject: "", messages: [
                Message(from: sam, day: -11, hour: 22, minute: 30,
                        body: ["Sent from my phone. Call me when you land."])
            ]),
            Sample(key: "dentist", subject: "Appointment reminder: Thursday 15 October", messages: [
                Message(from: dentist, day: -12, hour: 8, minute: 0,
                        body: ["This is a reminder of your cleaning on Thursday 15 October at 3:30 PM.",
                               "Reply C to confirm or call us to change it."])
            ], important: false),
            Sample(key: "digest", subject: "Your September digest", messages: [
                Message(from: linear, day: -14, hour: 6, minute: 30,
                        body: ["You closed 31 issues in September, up from 24 in August.",
                               "Your longest streak was eleven days."])
            ], important: false),
            Sample(key: "taxes", subject: "Estimated tax payment due 15 October", messages: [
                Message(from: person("Ledger", "hello@ledger.example"), day: -16, hour: 7, minute: 30,
                        body: ["Your third-quarter estimated payment is due on 15 October.",
                               "We worked it out from your invoices so far: $4,820."])
            ], important: false),
            Sample(key: "parking", subject: "Parking permit renewal", messages: [
                Message(from: noName, day: -20, hour: 10, minute: 0,
                        body: ["Your permit expires on 31 October. Renew online to keep your spot."])
            ], important: false),
            Sample(key: "photos", subject: "Photos from the offsite", messages: [
                Message(from: tom, day: -24, hour: 19, minute: 44,
                        body: ["Dropped the photos in the shared album. The one of Mei on the ferry is my favourite."],
                        deliveredTo: secondAccount)
            ], important: false),
            Sample(key: "hiring", subject: "Re: Senior engineer shortlist", messages: [
                Message(from: ana, day: -40, hour: 15, minute: 12,
                        body: ["Three names for the final round. I put my notes in the doc.",
                               "• Priya N., strongest on systems",
                               "• Marcus T., strongest with customers",
                               "• Lin W., strongest on product sense"]),
                Message(from: me, to: [ana], day: -39, hour: 9, minute: 2,
                        body: ["Thanks. Let's do Priya and Lin first."])
            ]),
            Sample(key: "intro", subject: "Intro: Noor and Dewey", messages: [
                Message(from: sam, to: [me, person("Dewey Marsh", "dewey@marsh.example")],
                        day: -300, hour: 12, minute: 0,
                        body: ["Noor, meet Dewey. Dewey, meet Noor. You two should talk about hiring pipelines."])
            ], important: false),
        ]
    }

    // MARK: The big ones

    /// Six plain messages between two people, quotes nested five deep.
    nonisolated private static func plainChain() -> Sample {
        let lines = [
            "Can we move the Northwind kickoff to Thursday?",
            "Thursday works. Morning or afternoon?",
            "Morning, ideally before 11.",
            "10:15 then. I will send the invite.",
            "Perfect. Should I bring the pilot numbers?",
            "Yes please, and the updated churn sheet."
        ]
        var messages: [Message] = []
        for (index, line) in lines.enumerated() {
            let mine = index % 2 == 1
            var body = [line]
            // Each reply quotes everything before it, one level deeper for each step back, to five.
            for back in 1...max(1, min(index, 5)) where index >= back {
                body.append(String(repeating: ">", count: back) + " " + lines[index - back])
            }
            messages.append(Message(from: mine ? me : tom, to: mine ? [tom] : [me], hour: 6 + index / 2,
                                    minute: 5 + (index % 2) * 20 + index, body: body))
        }
        return Sample(key: "plain-chain", subject: "Northwind kickoff", messages: messages)
    }

    /// Forty messages between nine people, the last three unread.
    nonisolated private static func forty() -> Sample {
        let others = [sam, jane, ana, tom, mei, person("Priya Nair", "priya@northwind.example"),
                      person("Marcus Tran", "marcus@northwind.example"),
                      person("Lin Wu", "lin@northwind.example")]
        let remarks = [
            "I think the second option reads better on a small screen.",
            "Agreed, but the first has the clearer call to action.",
            "Can we test both with the pilot group next week?",
            "Fine by me. Who builds the variants?",
            "I can do it by Wednesday if the copy is final.",
            "The copy is final except the subject line.",
            "Let's keep the subject short, under forty characters.",
            "One more thing: legal wants the footer changed.",
            "Which footer? The old one is still in the template.",
            "The one with the unsubscribe link at the top.",
        ]
        var messages: [Message] = []
        for index in 0..<40 {
            let sender = index % 5 == 4 ? me : others[index % others.count]
            let reader = index % 5 == 4 ? [others[index % others.count]] : [me]
            messages.append(Message(from: sender, to: reader, day: -4 + index / 14, hour: 9 + (index % 14) / 2,
                                    minute: (index % 2) * 30 + 3, unread: index >= 37,
                                    body: [remarks[index % remarks.count]]))
        }
        return Sample(key: "forty", subject: "Re: Re: Re: Email variants for the pilot", messages: messages)
    }

    /// Twelve recipients with long names, a 300-character subject, a body of about 30,000
    /// characters: for truncation, and the day the reader cuts a long body.
    nonisolated private static func longThread() -> Sample {
        let recipients = (1...12).map {
            person("Alexandria-Wilhelmina Featherstonehaugh-Montgomery the \($0)th", "long\($0)@names.example")
        }
        let subject = String(repeating: "A very long subject line that goes on and on about nothing in particular. ", count: 4)
            .trimmingCharacters(in: .whitespaces)
        let paragraph = "This paragraph is here to make the message long enough to need cutting. It says very little at great length, "
            + "the way a status update sometimes does when nobody has the time to shorten it. Every sentence repeats the one before, "
            + "with small changes, so that scrolling is the only way to know nothing was missed. "
        let paragraphs = (1...48).map { "\($0). " + paragraph + paragraph }
        return Sample(key: "long", subject: String(subject.prefix(300)), messages: [
            Message(from: sam, to: [me] + recipients, day: -6, hour: 20, minute: 1, body: paragraphs)
        ])
    }
}
#endif

#endif
