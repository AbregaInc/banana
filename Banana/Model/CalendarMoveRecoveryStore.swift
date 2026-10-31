import Foundation
import Combine

/// Visible ownership of pending moves. Disk access belongs to the journal actor; provider
/// work is injected so the commit/prepare/send/ack sequence can be tested without a calendar.
@MainActor
final class CalendarMoveRecoveryStore: ObservableObject {
    @Published private(set) var pending: [CalendarMoveIntent] = []
    @Published private(set) var active: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var unsaved: Set<UUID> = []
    @Published private(set) var loadError: String?
    private let journal: CalendarMoveJournal
    private let initial: Task<[CalendarMoveIntent], Error>
    private var loaded = false
    private var activeEvents: Set<String> = []

    init(directory: URL) {
        let journal = CalendarMoveJournal(directory: directory)
        self.journal = journal
        initial = Task { try await journal.pending() }
        Task { [weak self] in try? await self?.load() }
    }

    func load() async throws {
        guard !loaded else { return }
        do {
            let restored = try await initial.value
            guard !loaded else { return }
            pending = restored
            loaded = true
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    /// Returns only after success or a retained failure, preserving the existing caller's
    /// error/rollback presentation. The recovery list remains after that alert is dismissed.
    func perform(_ requested: CalendarMoveIntent,
                 prepare: (CalendarMoveIntent) async throws -> CalendarMoveIntent.PreparedMove,
                 apply: (CalendarMoveIntent.PreparedMove) async throws -> Void) async -> String? {
        guard !active.contains(requested.id), activeEvents.insert(requested.eventID).inserted else {
            return "A move for this event is already in progress."
        }
        active.insert(requested.id)
        defer { active.remove(requested.id); activeEvents.remove(requested.eventID) }
        var intent = requested
        do {
            try await load()
            if pending.contains(where: { $0.eventID == intent.eventID && $0.id != intent.id }) {
                return "Resolve the pending move for this event before moving it again."
            }
            // Keep the in-memory draft on a local storage failure and label it unsaved.
            // Never invoke the provider before the durable enqueue succeeds.
            if !pending.contains(where: { $0.id == intent.id }) { pending.append(intent) }
            unsaved.insert(intent.id)
            try await journal.enqueue(intent)
            unsaved.remove(intent.id)
            errors[intent.id] = nil
            if intent.prepared == nil {
                let target = try await prepare(intent)
                intent = try await journal.prepare(intent.id, mutation: target)
                if let index = pending.firstIndex(where: { $0.id == intent.id }) { pending[index] = intent }
            }
            try await apply(intent.prepared!)
            try await journal.acknowledge(intent.id)
            pending.removeAll { $0.id == intent.id }
            errors[intent.id] = nil
            return nil
        } catch {
            if !pending.contains(where: { $0.id == intent.id }) {
                pending.append(intent)
                unsaved.insert(intent.id)
            }
            let message = unsaved.contains(intent.id)
                ? "This move could not be saved locally. Keep the app open and retry. \(error.localizedDescription)"
                : "This move is kept for retry. \(error.localizedDescription)"
            errors[intent.id] = message
            return message
        }
    }

    func discard(_ id: UUID) async {
        guard !active.contains(id), let intent = pending.first(where: { $0.id == id }),
              activeEvents.insert(intent.eventID).inserted else { return }
        active.insert(id)
        defer { active.remove(id); activeEvents.remove(intent.eventID) }
        do {
            try await journal.acknowledge(id)
            pending.removeAll { $0.id == id }
            errors[id] = nil
            unsaved.remove(id)
        } catch { errors[id] = error.localizedDescription }
    }
}
