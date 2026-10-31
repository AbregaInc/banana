import os

/// Unified-logging channels. These persist to the system log, so they can be read
/// in Console.app (filter by subsystem `com.boris.banana`) or via
/// `log show --predicate 'subsystem == "com.boris.banana"' --last 1h`
/// — even after an overnight run when the debugger is no longer attached.
enum Log {
    static let wake = Logger(subsystem: "com.boris.banana", category: "wake")
    static let sync = Logger(subsystem: "com.boris.banana", category: "sync")
    /// Travel block reservation: why a trip home was or was not reserved, and what happened to
    /// blocks already on the calendar. Diagnosing this from the grid alone is guesswork.
    static let travel = Logger(subsystem: "com.boris.banana", category: "travel")
    /// Calendar write-back: which blocks were wanted, which were removed, and which could not be
    /// proved ours. A blocker that outlives its meeting is invisible from the outside.
    static let writeBack = Logger(subsystem: "com.boris.banana", category: "writeback")
}
