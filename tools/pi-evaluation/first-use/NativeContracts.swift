import Foundation

@main
enum NativeContracts {
    static func main() throws {
        func time(_ minutes: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(minutes * 60)) }
        func range(_ start: Int, _ end: Int) -> DateInterval { DateInterval(start: time(start), end: time(end)) }

        let free = AssistantFreeTime.slots(in: range(540, 1020),
            busy: [range(900, 1100), range(500, 600), range(660, 720), range(685, 780), range(600, 615), range(780, 800)],
            minimum: 45 * 60)
        precondition(free == [range(615, 660), range(800, 900)])
        precondition(AssistantFreeTime.slots(in: range(540, 600), busy: [range(500, 650)], minimum: 30 * 60).isEmpty)
        precondition(AssistantFreeTime.slots(in: range(540, 600), busy: [], minimum: 60 * 60) == [range(540, 600)])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 10))!
        let horizon = calendar.date(byAdding: .day, value: 30, to: date)!
        let days = try AssistantFreeTime.days(date: nil, period: "next7days", now: date,
                                             horizon: horizon, calendar: calendar)
        precondition(days.count == 7)
        let hours = try days.prefix(2).map { try AssistantFreeTime.time("09:00", day: $0, calendar: calendar) }
        precondition(hours[1].timeIntervalSince(hours[0]) == 23 * 3600)
        let week = try AssistantFreeTime.days(date: nil, period: "nextWeek", now: date,
                                             horizon: horizon, calendar: calendar)
        precondition(week.count == 7 && calendar.component(.weekday, from: week[0]) == 2)
        let thursday = AssistantFreeTime.weekday("thursday", after: date, calendar: calendar)
        precondition(thursday == week[3])
        do {
            _ = try AssistantFreeTime.time("02:30", day: days[1], calendar: calendar)
            preconditionFailure("A nonexistent local time entered an availability window")
        } catch AssistantFreeTime.InvalidWindow.time {}
        let first = AssistantFreeTime.absoluteTime("2026-11-25T15:00:00-05:00")
        let second = AssistantFreeTime.absoluteTime("2026-11-25T20:00:00Z")
        precondition(first != nil && first == second)
        precondition(AssistantFreeTime.absoluteTime("2026-02-30T15:00:00-05:00") == nil)
        precondition(AssistantFreeTime.absoluteTime("2026-11-25T24:10:00-05:00") == nil)
        precondition(AssistantFreeTime.absoluteTime("2026-11-25T15:00:00-00:00") == nil)
        let s = (MailCalendarReply.slot(in: "Are you free on Thursday, July 10, 2031, from 9:00 AM to 10:00 AM Paris time?"))!
        precondition(s.start == AssistantFreeTime.absoluteTime("2031-07-10T07:00:00Z"))
        precondition(s.end == AssistantFreeTime.absoluteTime("2031-07-10T08:00:00Z"))
        let t = (MailCalendarReply.slot(in: "Are you busy from 2031-07-10T09:00:00+02:00 to 2031-07-10T10:00:00+02:00?"))!
        precondition(t.start == s.start)
        precondition(t.end == s.end)
        for question in [
            "Are you free on Sunday, November 2, 2031, from 1:10 AM to 1:20 AM New York time?",
            "Are you available on Sunday, March 9, 2031, from 2:00 AM to 3:00 AM New York time?",
            "Are you free on Friday, July 10, 2031, from 9:00 AM to 10:00 AM UTC?",
            "Are you free on February 30, 2031, from 9:00 AM to 10:00 AM UTC?",
            "Are you free on July 10, 2031, from 9:00 AM to 10:00 AM CST?",
            "Are you free tomorrow?\n> Are you free on July 10, 2031, from 9:00 AM to 10:00 AM UTC?",
            "Are you free on July 10, 2031, from 9:00 AM to 10:00 AM UTC and can you book it?",
            "Are you free on July 10, 2031, from 11:00 AM to 10:00 AM UTC?"
        ] { precondition(MailCalendarReply.slot(in: question) == nil, question) }
        try MailDraftPrompt.checkLinks(in: "Use https://example.com/join.", suppliedText: "The link is https://example.com/join")
        do {
            try MailDraftPrompt.checkLinks(in: "Use https://join.example.com/join.", suppliedText: "I will send the link later.")
            preconditionFailure("An invented join link entered a draft")
        } catch is MailDraftPrompt.UnverifiedLink {}
        let confirmed = "Invoice P-104. Total USD 1,250.00, by 2026-11-25. Code: MAPLE. Link https://example.com/pay"
        let task = "Say I have reviewed the invoice."
        let accepted = ["P-104 is $1250.", "It is due Wednesday, November 25th, 2026.",
                        "It is due on 25 November.", "I’ve reviewed your invoice.", "Code is MAPLE.",
                        "Use https://example.com/pay.", "Please send the latest estimate."]
        for body in accepted {
            try MailDraftPrompt.checkGrounding(in: body, suppliedText: confirmed, authorInstruction: task)
        }
        try MailDraftPrompt.checkGrounding(in: "Total: 1.250,50 €.", suppliedText: "EUR 1,250.50", authorInstruction: "")
        let invented = ["It will cost $125.", "It costs EUR 1,250.", "The total is -$1250.", "Use P-140.", "The code is BIRCH.",
                        "Use order #98213.", "It is due November 26th.", "It is due Thursday.",
                        "It is due November 25, 2027.", "I have reviewed the contract.", "I sent the payment.",
                        "I checked your attachment.", "I've reviewed your invoice and I paid it."]
        for body in invented {
            do {
                try MailDraftPrompt.checkGrounding(in: body, suppliedText: confirmed, authorInstruction: task)
                preconditionFailure("Accepted unsupported claim: " + body)
            } catch is MailDraftPrompt.UnverifiedFact {}
        }
        do {
            try MailDraftPrompt.checkGrounding(in: "I sent the contract.", suppliedText: "I sent the contract.",
                                               authorInstruction: "Do not say I sent the contract.")
            preconditionFailure("An inbound or negated statement authorized an action")
        } catch is MailDraftPrompt.UnverifiedFact {}
        do {
            try MailDraftPrompt.checkGrounding(in: "See https://example.com/other", suppliedText: confirmed, authorInstruction: task)
            preconditionFailure("Accepted a URL outside supplied or cited evidence")
        } catch is MailDraftPrompt.UnverifiedLink {}
        print("Calendar, link, and grounded composer contracts passed")
    }
}
