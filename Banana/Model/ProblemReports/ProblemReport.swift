import Foundation

/// One problem report as it waits on the device and goes to the service (`POST /v1/reports`,
/// `Service/src/reports.js`, docs/design/PROBLEM-REPORTS.md): a spike the watchdog caught, a
/// MetricKit diagnostic with the log around it, Report a problem, or a rating on an answer.
/// Pure, for tests: no app state is read here.
struct ProblemReport: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case problem, spike, rating }

    /// What caught a spike. The words are the service's allow-list.
    enum Detector: String, Codable, Sendable, CaseIterable {
        case storm, cpu, power, memory, hang
        case metricKitCrash = "metrickit-crash", metricKitHang = "metrickit-hang"
        case metricKitCPU = "metrickit-cpu", metricKitDisk = "metrickit-disk"
    }

    enum Rating: String, Codable, Sendable { case up, down }

    /// A reading or a fact: a number, a yes/no, a short word, or a list of ids.
    enum Value: Codable, Equatable, Sendable {
        case number(Double), flag(Bool), text(String), list([String])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .flag(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .text(v) }
            else { self = .list(try c.decode([String].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .number(let v): try c.encode(v)
            case .flag(let v): try c.encode(v)
            case .text(let v): try c.encode(v)
            case .list(let v): try c.encode(v)
            }
        }

        var json: Any {
            switch self {
            case .number(let v): return v
            case .flag(let v): return v
            case .text(let v): return v
            case .list(let v): return v
            }
        }
    }

    /// A file that goes with the report. The names and types are the service's allow-list.
    struct Attachment: Codable, Equatable, Sendable {
        enum Name: String, Codable, Sendable, CaseIterable {
            case screenshot, log, stack, mailHTML = "mail-html", mailPrepared = "mail-prepared", mailPlain = "mail-plain", ai, metricKit = "metrickit"

            /// The most the service takes, decoded (`ATTACHMENTS` in reports.js).
            var most: Int {
                switch self {
                case .screenshot: 3 * 1024 * 1024
                case .log, .stack, .metricKit: 256 * 1024
                case .mailHTML, .mailPrepared, .mailPlain: 2560 * 1024
                case .ai: 512 * 1024
                }
            }
        }
        var name: Name
        var type: String
        var data: Data

        static func text(_ name: Name, _ text: String, type: String = "text/plain") -> Attachment? {
            let data = Data(text.utf8)
            guard !data.isEmpty else { return nil }
            // A text too long keeps its end: the newest lines of a log, the last part of a stack.
            return Attachment(name: name, type: type, data: data.count <= name.most ? data : Data(data.suffix(name.most)))
        }

        static func json(_ name: Name, _ value: some Encodable) -> Attachment? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value), !data.isEmpty, data.count <= name.most else { return nil }
            return Attachment(name: name, type: "application/json", data: data)
        }
    }

    /// Which copy of the app sent it.
    struct Device: Codable, Equatable, Sendable {
        /// iphone, ipad or mac.
        var platform: String
        /// appstore, testflight or dev.
        var channel: String
        /// stable or beta.
        var variant: String
        /// "1.0 (84)".
        var version: String
        /// "27.1".
        var os: String
        /// The model identifier: "iPhone18,1", "Mac16,10".
        var model: String
    }

    var id: String = UUID().uuidString
    var createdAt = Date()
    var kind: Kind
    var detector: Detector? = nil
    var signature: String? = nil
    var rating: Rating? = nil
    /// The section in front (`AppSection.rawValue`), or "other".
    var page: String
    var note: String? = nil
    var numbers: [String: Value] = [:]
    var context: [String: Value] = [:]
    var attachments: [Attachment] = []

    static let pages: Set<String> = ["plan", "mail", "workouts", "sleep", "trends", "nutrition", "notes", "routines",
                                     "library", "review", "assistant", "settings", "other"]

    /// The request body the service takes: the report, which copy sent it, and each file in base64.
    func body(device: Device) -> Data? {
        var json: [String: Any] = [
            "id": id, "kind": kind.rawValue, "page": Self.pages.contains(page) ? page : "other",
            "platform": device.platform, "channel": device.channel, "variant": device.variant,
            "version": device.version, "os": device.os, "device": String(device.model.prefix(80)),
            "numbers": numbers.mapValues(\.json), "context": context.mapValues(\.json),
        ]
        if let detector { json["detector"] = detector.rawValue }
        if let signature { json["signature"] = String(signature.prefix(300)) }
        if let rating { json["rating"] = rating.rawValue }
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { json["note"] = String(note.prefix(4000)) }
        if !attachments.isEmpty {
            json["attachments"] = attachments.map { ["name": $0.name.rawValue, "type": $0.type, "data": $0.data.base64EncodedString()] }
        }
        return try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// The bytes the report holds, for the outbox's bound.
    var size: Int { attachments.reduce(0) { $0 + $1.data.count } + (note?.utf8.count ?? 0) + 512 }
}

/// How many automatic reports of a kind go in a day: a storm that fires every 15 seconds is one
/// report, not four thousand. Kept by the outbox; pure, for tests.
struct ProblemReportAllowance: Codable, Equatable, Sendable {
    /// Per detector per day. A person's own reports are not counted here.
    static let perDay = 3
    /// Day key ("2026-11-08") → detector → how many went.
    private(set) var sent: [String: [String: Int]] = [:]

    /// Whether one more of `key` may go today; counts it when it may.
    mutating func take(_ key: String, now: Date, calendar: Calendar = .current, limit: Int = perDay) -> Bool {
        let day = Self.day(now, calendar: calendar)
        // Only today's counts are kept: yesterday's are nothing to anyone.
        if sent.keys.contains(where: { $0 != day }) { sent = sent.filter { $0.key == day } }
        let count = sent[day]?[key] ?? 0
        guard count < limit else { return false }
        sent[day, default: [:]][key] = count + 1
        return true
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
