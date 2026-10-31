import Foundation
import os.signpost

/// Named intervals for the handful of operations that matter to the energy story — recompute,
/// progress saves, backup passes. Instruments (os_signpost / Time Profiler / Energy Log) then
/// shows *which* operation a CPU spike belongs to instead of leaving it to inference.
///
/// Usage:
///     let sp = Signpost.begin("recompute")
///     defer { Signpost.end(sp) }
///
/// Near-zero cost when nothing is recording; safe to ship in release.
enum Signpost {
    static let log = OSLog(subsystem: "com.boris.banana", category: "perf")

    struct Token {
        let id: OSSignpostID
        let name: StaticString
        let power: PowerTrace.Token
    }

    static func begin(_ name: StaticString) -> Token {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Token(id: id, name: name, power: PowerTrace.begin(String(describing: name)))
    }

    static func end(_ token: Token) {
        os_signpost(.end, log: log, name: token.name, signpostID: token.id)
        PowerTrace.end(token.power)
    }
}
