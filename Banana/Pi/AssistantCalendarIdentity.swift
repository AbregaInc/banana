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
    static func key(_ requested: String, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let offsets = ["today": 0, "tomorrow": 1, "tmrw": 1, "yesterday": -1]
        let word = requested.lowercased().trimmingCharacters(in: .whitespaces)
        // A weekday name is its next occurrence (today included); "next Friday" is the one after that week.
        let weekday = word.hasPrefix("next ") ? String(word.dropFirst(5)) : word
        let resolved: Date?
        if let offset = offsets[word] {
            resolved = calendar.date(byAdding: .day, value: offset, to: now)
        } else if let index = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].firstIndex(of: weekday),
                  let next = (0..<7).lazy.compactMap({ calendar.date(byAdding: .day, value: $0, to: now) })
                    .first(where: { calendar.component(.weekday, from: $0) == index + 1 }) {
            resolved = word.hasPrefix("next ") && calendar.isDate(next, equalTo: now, toGranularity: .weekOfYear)
                ? calendar.date(byAdding: .day, value: 7, to: next) : next
        } else { resolved = nil }
        guard let day = resolved else { return requested }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}
