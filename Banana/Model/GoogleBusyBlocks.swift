import Foundation

/// Busy-block writing through Google's API, rather than through Apple Calendar's CalDAV mirror of
/// it.
///
/// **Ownership survives.** A block written to a Google calendar through CalDAV comes back with
///    its `url` stripped, which is how Banana loses track of a block it wrote — the marker test
///    fails, the block is ingested as a real meeting, and write-back writes another one on top.
///    That is the "I deleted it and it came back, twice as long" report. Google's
///    `extendedProperties.private` is app-private key/value data that no sync layer rewrites, and
///    it is queryable server-side, so a block can always be found again.
enum GoogleBusyBlocks {
    /// The key under which a block's app item id is stored. Stored on this calendar copy; Google may redact it from shared private events.
    static let itemIDKey = "bananaItemID"
    /// Which build wrote it, so the beta cannot delete the production app's blocks or vice versa.
    static let variantKey = "bananaVariant"

    /// The legacy mirror identity, shared by the writer and display reconciliation.
    static func mirrorID(title: String, start: Date, end: Date) -> String {
        let fingerprint = [title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                           String(start.timeIntervalSinceReferenceDate.bitPattern),
                           String(end.timeIntervalSinceReferenceDate.bitPattern)].joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in fingerprint.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return "mirror-\(String(hash, radix: 16))"
    }

    /// The request body for creating or updating one block.
    ///
    /// `transparency: opaque` is the entire point — a block that does not mark you busy protects
    /// nothing. `visibility: private` keeps the title off shared views of the calendar; anyone the
    /// calendar is shared with sees a busy interval rather than what it is for.
    ///
    /// `isAllDay`: the copy of a day blocked all day — dates, not times, so it reads as an
    /// all-day Busy event; the other form is cleared (null) so a PATCH can't leave both.
    static func body(title: String,
                     start: Date,
                     end: Date,
                     timeZoneID: String,
                     appItemID: String,
                     variant: String,
                     isAllDay: Bool = false) -> [String: Any] {
        [
            "summary": title,
            "start": isAllDay
                ? ["date": GoogleCalendarDates.dateString(start), "dateTime": NSNull()] as [String: Any]
                : ["dateTime": rfc3339(start), "timeZone": timeZoneID] as [String: Any],
            "end": isAllDay
                ? ["date": GoogleCalendarDates.dateString(end), "dateTime": NSNull()] as [String: Any]
                : ["dateTime": rfc3339(end), "timeZone": timeZoneID] as [String: Any],
            "transparency": "opaque",
            "visibility": "private",
            // Deliberately empty: a busy block is scaffolding, and a reminder storm across eight
            // calendars is what made people turn the feature off.
            "reminders": ["useDefault": false, "overrides": []],
            "extendedProperties": ["private": [itemIDKey: appItemID, variantKey: variant]],
        ]
    }

    /// What a block says, in the terms Google keeps it: the title, and the times at the
    /// precision they are written (whole seconds; dates for an all-day copy). Two devices that want
    /// the same block produce the same content, and a block read back from Google produces the
    /// content it was written with — so "already says this" is a string comparison, never a
    /// comparison of a sub-second `Date` with the second Google stored.
    static func content(title: String, start: Date, end: Date, isAllDay: Bool) -> String {
        let span = isAllDay
            ? [GoogleCalendarDates.dateString(start), GoogleCalendarDates.dateString(end)]
            : [String(wholeSecond(start)), String(wholeSecond(end))]
        // Surrounding whitespace is not a difference worth a write, whichever side keeps it.
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([title, isAllDay ? "day" : "time"] + span).joined(separator: "\u{1F}")
    }

    /// The second a time is written as. The writer drops the fraction the same way.
    static func wholeSecond(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970))
    }

    /// The `privateExtendedProperty` filter that finds this app's blocks server-side.
    ///
    /// Google matches these as `key=value` strings. Filtering on the server rather than listing a
    /// window and sifting locally is what makes recovery cheap: one request returns exactly the
    /// blocks this build wrote, however many unrelated events share the calendar.
    static func ownershipFilter(variant: String) -> String {
        "\(variantKey)=\(variant)"
    }

    static func itemFilter(appItemID: String) -> String {
        "\(itemIDKey)=\(appItemID)"
    }

    /// Reads the app item id back off an event's private properties, or nil when the event is not
    /// one of ours.
    static func appItemID(fromPrivateProperties properties: [String: String]?,
                          variant: String) -> String? {
        guard let properties,
              properties[variantKey] == variant,
              let id = properties[itemIDKey],
              !id.isEmpty
        else { return nil }
        return id
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Whole seconds, dropped the way `content` drops them, so what is written reads back equal.
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(wholeSecond(date))))
    }
}
