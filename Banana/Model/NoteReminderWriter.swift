import EventKit
import Foundation

/// The asynchronous read/save boundary, shared by the live EventKit adapter and fault tests.
/// A local EventKit identifier can disappear after a full sync or differ on another device.
@MainActor
enum NoteReminderWriter {
    static func write(previousID: String?, marker: URL, title: String, notes: String,
                      stillCurrent: () -> Bool,
                      lookup: (String) -> EKReminder?,
                      fetch: () async -> [EKReminder]?,
                      create: () -> EKReminder?,
                      save: (EKReminder) throws -> String) async -> String? {
        let reminder: EKReminder
        if let previousID, let existing = lookup(previousID) {
            reminder = existing
        } else {
            guard let matches = await fetch(), stillCurrent() else { return nil }
            if let existing = matches.first(where: { $0.url == marker }) {
                reminder = existing
            } else if let previousID {
                // A complete successful fetch found neither the ID nor the stable marker.
                // Respect an external deletion; a failed fetch must remain pending instead.
                return previousID
            } else {
                guard let fresh = create() else { return nil }
                reminder = fresh
            }
        }
        guard stillCurrent() else { return nil }
        reminder.title = title
        reminder.notes = notes
        reminder.url = marker
        do { return try save(reminder) }
        catch { return nil }
    }
}
