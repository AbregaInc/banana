import Foundation

struct MeetingInfo {
    var address: String?
    var searchDetails: String?
    var isAvailabilityOnly = false
}

struct Occurrence {
    let id: Int
    var title: String
    let start: Date
    var notes: String
    var location: String
    var participant: String
    var email: String
    var organizer: String
    var meeting: MeetingInfo?
}

final class OccurrenceStore {
    static let shared = OccurrenceStore()
    var occurrences: [Occurrence] = []
}

struct Query {
    let text: String
    let expected: [Int]
}

let now = Date(timeIntervalSince1970: 1_790_078_400)
let cases = [
    Query(text: "zircon", expected: [0]),
    Query(text: "handover", expected: [1]),
    Query(text: "atrium", expected: [2]),
    Query(text: "Haddad", expected: [3]),
    Query(text: "noor@plan.example", expected: [3]),
    Query(text: "opal", expected: [4]),
    Query(text: "project", expected: [5, 6, 7, 8, 9]),
    Query(text: "absentneedle", expected: [])
]

func fixture(_ multiplier: Int) -> [Occurrence] {
    // Beta's cached calendar rows are a size reference, not its loaded timeline.
    // Repeat a fixed profile at 4x. Use synthetic strings and no account identifiers.
    var rows = (0..<(3823 * multiplier)).map { index in
        let i = index % 3823
        return Occurrence(id: index, title: i < 3094 ? "Project \(i % 25)" : "",
                          start: now.addingTimeInterval(Double(index + 1) * 60),
                          notes: i < 173 ? String(repeating: "sample note ", count: 51) : "",
                          location: i < 222 ? "Sample address" : "",
                          participant: i < 771 ? "Sample guest" : "",
                          email: i < 771 ? "guest@plan.example" : "",
                          organizer: i < 3094 ? "Sample organizer" : "")
    }
    for i in 0..<5 { rows[i].title = "Review" }
    rows[0].title = "Zircon review"
    rows[1].notes += "handover"
    rows[2].location = "Atrium"
    rows[3].participant = "Noor Haddad"
    rows[3].email = "noor@plan.example"
    rows[4].organizer = "Opal"
    for i in rows.indices {
        let row = rows[i]
        let details = [row.notes, row.participant, row.email, row.organizer].filter { !$0.isEmpty }.joined(separator: "\n")
        rows[i].meeting = MeetingInfo(address: row.location.isEmpty ? nil : row.location,
                                      searchDetails: details.isEmpty ? nil : details)
    }
    return rows
}

var runs: [[String: Any]] = []
for scale in [1, 4] {
    OccurrenceStore.shared.occurrences = fixture(scale)
    var casesData: [[String: Any]] = []
    var samples = Array(repeating: [Double](), count: cases.count)
    var answers = Array(repeating: [Int](), count: cases.count)
    for trial in 0..<21 {
        for offset in cases.indices {
            let i = (offset + trial) % cases.count
            let start = ProcessInfo.processInfo.systemUptime
            let rows = Replay.matchingPlanOccurrences(cases[i].text, limit: 5, now: now)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let ids = rows.map(\.id)
            if trial == 0 { answers[i] = ids } else { precondition(ids == answers[i]) }
            samples[i].append(elapsed)
        }
    }
    for i in cases.indices {
        casesData.append(["query": cases[i].text, "expected": cases[i].expected,
                          "actual": answers[i], "ms": samples[i]])
    }
    runs.append(["rows": OccurrenceStore.shared.occurrences.count, "cases": casesData])
}
// Cross-field matches, title priority and availability redaction on the actual selector.
var controls = fixture(1)
controls[0].meeting?.searchDetails = "hiddenword"
controls[0].meeting?.isAvailabilityOnly = true
controls[1].meeting?.searchDetails = "Café, Zürich"
controls[2].title = "Zürich review"
let isolated = Array(controls.prefix(3))
for (query, expected) in [("hiddenword", []), ("zur", [2, 1]), ("rev caf", [1]), ("afé", [])] {
    let result = Replay.selectPlanOccurrences(query, in: isolated, limit: 5, now: now)
    precondition(result.map(\.id) == expected, "Unexpected calendar match for \(query)")
}
let data = try JSONSerialization.data(withJSONObject: runs)
FileHandle.standardOutput.write(data)
