import Foundation
import GRDB

// Runs on a copied fixture database. Measures SQL fetches only, not decoding/UI.
@main struct StatementCacheProbe {
    static func main() throws {
        let args = CommandLine.arguments
        precondition(args.count == 5, "database cached|uncached output samples")
        let cached = args[2] == "cached"
        precondition(cached || args[2] == "uncached")
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA cache_size=-4096") }
        let database = try DatabaseQueue(path: args[1], configuration: configuration)
        let snapshots = try database.read { try String.fetchAll($0, sql: "SELECT id FROM episodeSnapshots ORDER BY id") }
        precondition(!snapshots.isEmpty)
        var checks = 0
        for newest in [true, false] {
            for reverse in [true, false] {
                let order = "date \(newest ? "DESC" : "ASC"), ordinal \(reverse ? "DESC" : "ASC")"
                for snapshot in snapshots.prefix(10) {
                    for offset in [0, 3, 19] {
                        try database.read { db in
                            let sql = "SELECT payload FROM episodes WHERE snapshot = ? ORDER BY \(order) LIMIT ? OFFSET ?"
                            let arguments: StatementArguments = [snapshot, 3, offset]
                            let expected = try Data.fetchAll(db, sql: sql, arguments: arguments)
                            let actual = try Data.fetchAll(db, SQLRequest<Data>(sql: sql, arguments: arguments, cached: cached))
                            precondition(expected == actual, "Cached bindings/order changed rows")
                            checks += 1
                        }
                    }
                }
            }
        }
        database.releaseMemory()
        var samples: [[String: Any]] = []
        for limit in [1, 3] {
            for trial in 0..<Int(args[4])! {
                database.releaseMemory()
                for state in ["released", "warm"] {
                    let began = ProcessInfo.processInfo.systemUptime
                    var bytes = 0
                    for snapshot in snapshots {
                        bytes += try database.read { db in
                            try Data.fetchAll(db, SQLRequest<Data>(sql: "SELECT payload FROM episodes WHERE snapshot = ? ORDER BY date DESC, ordinal DESC LIMIT ? OFFSET ?",
                                arguments: [snapshot, limit, 0], cached: cached)).reduce(0) { $0 + $1.count }
                        }
                    }
                    samples.append(["limit": limit, "trial": trial, "state": state, "bytes": bytes,
                                    "milliseconds": (ProcessInfo.processInfo.systemUptime - began) * 1000])
                }
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["scope": "SQL fetch only; no JSON decoding or UI. releaseMemory clears SQLite/statement caches, not OS file cache.",
            "cached": cached, "snapshots": snapshots.count, "checks": checks, "samples": samples,
            "peakRSSBytes": usage.ru_maxrss, "status": "passed-correctness"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    }
}
