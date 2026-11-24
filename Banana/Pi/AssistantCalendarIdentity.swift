import Foundation
import CryptoKit

/// A durable event save keeps its draft identity through a calendar retry.
/// The original Pi property keys remain compatible with events already created by older clients.
/// Google accepts client-generated base32hex event IDs; UUID hex is a valid subset.
enum AssistantCalendarIdentity {
    static let operationKey = "bananaPiOperation"
    static let fingerprintKey = "bananaPiFingerprint"

    static func attach(to body: inout [String: Any], operation: UUID) throws -> [String: String] {
        let id = operation.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        body["id"] = id
        let canonical = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
        let fingerprint = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let receipt = [operationKey: operation.uuidString.lowercased(), fingerprintKey: fingerprint]
        body["extendedProperties"] = ["private": receipt]
        return receipt
    }

    static func matches(_ properties: [String: String]?, receipt: [String: String]) -> Bool {
        guard let properties, let operation = receipt[operationKey], !operation.isEmpty,
              let fingerprint = receipt[fingerprintKey], !fingerprint.isEmpty else { return false }
        return properties[operationKey] == operation && properties[fingerprintKey] == fingerprint
    }
}

/// Relative days are evaluated at execution, not when a conversation was created.
enum AssistantLocalDay {
    static func calendar(_ zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    static func key(_ date: Date, calendar: Calendar = calendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func date(_ text: String, calendar: Calendar = calendar()) throws -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              key(date, calendar: calendar) == text else {
            throw AssistantFailure(message: "Use a valid date in YYYY-MM-DD format.")
        }
        return date
    }


    static func key(_ requested: String, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let offsets = ["today": 0, "tomorrow": 1, "tmrw": 1, "yesterday": -1]
        guard let offset = offsets[requested.lowercased()],
              let day = calendar.date(byAdding: .day, value: offset, to: now) else { return requested }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}
