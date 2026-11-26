import Foundation

// Both repositories read the same committed database. The reference source is taken from git.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-replay-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: dir) }
let db = dir.appendingPathComponent("notes.sqlite")
let legacy = dir.appendingPathComponent("notes.json")
do {
    let writer = try NoteRepository(url: db, legacyURL: legacy)
    for start in stride(from: 0, to: 90_000, by: 500) {
        let notes = (start..<start+500).map { i in
            VoiceNote(createdAt: Date(timeIntervalSince1970: Double(i)), archivedAt: i.isMultiple(of: 5) ? Date() : nil,
                      audioFilename: "", transcript: i.isMultiple(of: 17) ? "needle planning" : "ordinary planning",
                      context: i == 1 ? .init(episodeTitle: "Café oldest") : nil, status: .transcribed)
        }
        try writer.upsert(notes)
    }
}

struct Work {
    let name: String, query: String
    let limit: Int, offset: Int
    let counted: Bool
}
let work = [
    Work(name: "assistant six", query: "needle", limit: 6, offset: 0, counted: false),
    Work(name: "recent plus one", query: "", limit: 11, offset: 0, counted: false),
    Work(name: "first hundred", query: "needle", limit: 100, offset: 0, counted: false),
    Work(name: "Notes full page", query: "needle", limit: 100, offset: 0, counted: true),
    Work(name: "Notes missing", query: "absent", limit: 100, offset: 0, counted: true),
    Work(name: "Notes rare context", query: "CAFÉ", limit: 100, offset: 0, counted: true),
    Work(name: "Notes last page", query: "needle", limit: 100, offset: 4200, counted: true),
    Work(name: "Notes beyond end", query: "needle", limit: 100, offset: 9000, counted: true)
]
var samples = [[String: Any]]()
for (index, item) in work.enumerated() {
    var base: ReferenceRepository?
    var next: NoteRepository?
    for trial in 0..<9 {
        // Start and finish with fresh SQLite connections. The operating system cache stays warm.
        if trial == 0 || trial == 8 {
            base = try ReferenceRepository(url: db, legacyURL: legacy)
            next = try NoteRepository(url: db, legacyURL: legacy)
        }
        var results = [[VoiceNote]](), totals = [Int](), times = [String: Double]()
        for reference in (index + trial).isMultiple(of: 2) ? [true, false] : [false, true] {
            let start = ProcessInfo.processInfo.systemUptime
            let rows: [VoiceNote], total: Int
            if reference {
                let page = try base!.page(search: item.query, archived: false, offset: item.offset, limit: item.counted ? item.limit : 100)
                rows = Array(page.rows.prefix(item.limit))
                total = item.counted ? page.total : rows.count
            } else if item.counted {
                let page = try next!.page(search: item.query, archived: false, offset: item.offset, limit: item.limit)
                rows = page.rows
                total = page.total
            } else {
                rows = try await next!.searchResults(item.query, limit: item.limit)
                total = rows.count
            }
            times[reference ? "baseMS" : "candidateMS"] = (ProcessInfo.processInfo.systemUptime - start) * 1000
            results.append(rows)
            totals.append(total)
        }
        precondition(results[0] == results[1] && totals[0] == totals[1], item.name)
        samples.append(["case": item.name, "trial": trial, "rows": results[0].count, "total": totals[0],
                        "freshConnection": trial == 0 || trial == 8, "times": times])
    }
}
let report: [String: Any] = ["notes": 90_000, "samples": samples, "scope": "Mac repository, SQLite connections reopened on trials 0 and 8; warm OS file cache"]
let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .withoutOverwriting)
