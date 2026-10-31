import Foundation
import GRDB

enum NoteProbe {
    static var phases: [[String: Any]] = []
    static var calls = 0
    static var matchMS = 0.0
    static var firstMatchMS = 0.0
    static func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let start = ProcessInfo.processInfo.systemUptime
        let value = try body()
        let ms = (ProcessInfo.processInfo.systemUptime-start)*1000
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        func cpu(_ u: rusage) -> Double { Double(u.ru_utime.tv_sec+u.ru_stime.tv_sec)*1000+Double(u.ru_utime.tv_usec+u.ru_stime.tv_usec)/1000 }
        phases.append(["name":name,"ms":ms,"processCPUMS":cpu(after)-cpu(before),
            "voluntarySwitches":after.ru_nvcsw-before.ru_nvcsw,"involuntarySwitches":after.ru_nivcsw-before.ru_nivcsw,
            "pageFaults":after.ru_majflt-before.ru_majflt])
        return value
    }
    static func contains(_ text: String, _ query: String) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        let answer = text.localizedCaseInsensitiveContains(query)
        let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
        if calls == 0 { firstMatchMS = elapsed }
        calls += 1; matchMS += elapsed
        return answer
    }
}
@main struct Probe {
    static func main() throws {
        let a = CommandLine.arguments
        precondition(a.count == 4)
        precondition(!FileManager.default.fileExists(atPath:a[2]))
        let url = URL(fileURLWithPath:a[1])
        let instrumented = a[3] != "original"
        precondition(["original","instrumented","prewarm"].contains(a[3]))
        if a[3] == "prewarm" {
            let found = NoteProbe.timed("localized-prewarm") { "Fixture needle note 100".localizedCaseInsensitiveContains("needle") }
            precondition(found)
        }
        var snapshots: [[String:Any]] = []
        if instrumented {
            let repo = try NoteProbe.timed("open") { try NoteRepository(url:url,legacyURL:url.deletingLastPathComponent().appendingPathComponent("absent.json")) }
            for i in 0..<7 {
                NoteProbe.calls=0;NoteProbe.matchMS=0;NoteProbe.firstMatchMS=0
                let page = try NoteProbe.timed("page-\(i)") { try repo.page(search:"needle",archived:false) }
                snapshots.append(["total":page.total,"ids":page.rows.map { $0.id.uuidString },"calls":NoteProbe.calls,"localizedMS":NoteProbe.matchMS,"firstLocalizedMS":NoteProbe.firstMatchMS])
            }
        } else {
            let repo = try NoteProbe.timed("open") { try OriginalNoteRepository(url:url,legacyURL:url.deletingLastPathComponent().appendingPathComponent("absent.json")) }
            for i in 0..<7 {
                let page = try NoteProbe.timed("page-\(i)") { try repo.page(search:"needle",archived:false) }
                snapshots.append(["total":page.total,"ids":page.rows.map { $0.id.uuidString }])
            }
        }
        let report: [String:Any] = ["policy":a[3],"phases":NoteProbe.phases,"snapshots":snapshots,
            "scope":"Copied stress database and real repository/model source; instrumentation copy separates count/fetch/decode/localized matching. Not app startup or UI latency."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:a[2]))
    }
}
