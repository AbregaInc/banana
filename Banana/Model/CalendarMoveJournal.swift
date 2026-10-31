import Foundation

/// The user's absolute destination, retained independently of a view or provider request.
/// A recovered operation must be reconciled before retry: a lost response may follow a
/// successful remote write. In particular, never blindly replay a recurring-series shift.
struct CalendarMoveIntent: Codable, Equatable, Identifiable, Sendable {
    enum Scope: String, Codable, Sendable { case occurrence, series, following }
    let id: UUID
    let eventID: String
    let title: String
    let originalStart: Date
    let originalEnd: Date?
    let destination: Date
    let scope: Scope
    let createdAt: Date
    /// Persisted before dispatch. A retry compares this exact target/version instead of
    /// deriving another relative series shift from potentially changed provider data.
    var prepared: PreparedMove?

    struct PreparedMove: Codable, Equatable, Sendable {
        let accountEmail: String
        let calendarID: String
        let eventID: String
        let expectedETag: String
        let destinationStart: Date
        let destinationEnd: Date
        let isAllDay: Bool
        let timeZoneID: String?
        let notifyGuests: Bool

        enum Reconciliation: Equatable { case alreadyApplied, sendIfUnchanged, conflict }
        func reconcile(start: Date, end: Date, etag: String?) -> Reconciliation {
            if start == destinationStart && end == destinationEnd { return .alreadyApplied }
            return etag == expectedETag ? .sendIfUnchanged : .conflict
        }
    }

    init(id: UUID = UUID(), eventID: String, title: String, originalStart: Date,
         originalEnd: Date?, destination: Date, scope: Scope, createdAt: Date = Date()) {
        self.id = id
        self.eventID = eventID
        self.title = title
        self.originalStart = originalStart
        self.originalEnd = originalEnd
        self.destination = destination
        self.scope = scope
        self.createdAt = createdAt
        self.prepared = nil
    }
}

/// Foundation's atomic replacement, serialized off the main actor. One file per intent
/// makes enqueue/acknowledgement independent of total calendar history or outbox size.
/// No timeout, launch recovery or failed request removes an intent. Only explicit discard
/// or confirmed provider reconciliation may acknowledge it.
actor CalendarMoveJournal {
    enum JournalError: Error, LocalizedError {
        case conflictingIntent, malformedRecord(String)
        var errorDescription: String? {
            switch self {
            case .conflictingIntent: return "A different calendar move already uses this recovery identifier."
            case .malformedRecord(let name): return "Calendar move recovery could not read \(name). The original file has been preserved."
            }
        }
    }

    private let directory: URL
    init(directory: URL) {
        self.directory = directory.appendingPathComponent("pending-calendar-moves", isDirectory: true)
    }

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func read(_ file: URL) throws -> CalendarMoveIntent {
        let data = try Data(contentsOf: file)
        guard let intent = try? JSONDecoder().decode(CalendarMoveIntent.self, from: data),
              file.deletingPathExtension().lastPathComponent == intent.id.uuidString,
              !intent.eventID.isEmpty else {
            throw JournalError.malformedRecord(file.lastPathComponent)
        }
        return intent
    }

    /// Idempotent for exactly the same intent; never silently replaces another operation.
    func enqueue(_ intent: CalendarMoveIntent) throws {
        guard !intent.eventID.isEmpty else { throw JournalError.malformedRecord(intent.id.uuidString) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = url(intent.id)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try read(file) == intent else { throw JournalError.conflictingIntent }
            return
        }
        try JSONEncoder().encode(intent).write(to: file, options: .atomic)
    }

    /// The provider target is resolved once. Save it before issuing a network mutation.
    /// Repeating the same preparation is safe; replacing it after dispatch is forbidden.
    func prepare(_ id: UUID, mutation: CalendarMoveIntent.PreparedMove) throws -> CalendarMoveIntent {
        let file = url(id)
        var intent = try read(file)
        if let existing = intent.prepared {
            guard existing == mutation else { throw JournalError.conflictingIntent }
            return intent
        }
        intent.prepared = mutation
        try JSONEncoder().encode(intent).write(to: file, options: .atomic)
        return intent
    }

    func pending() throws -> [CalendarMoveIntent] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        // Atomic-write scratch files and unrelated files are not acknowledged operations.
        let entries = try files.filter { $0.pathExtension == "json" }.map(read)
        return entries.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
        }
    }

    /// Call only after confirmed success/reconciliation, or explicit user discard.
    /// A failed removal throws and leaves the intent available for recovery.
    func acknowledge(_ id: UUID) throws {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        _ = try read(file) // Refuse to erase corrupt/mismatched recovery records.
        try FileManager.default.removeItem(at: file)
    }
}
