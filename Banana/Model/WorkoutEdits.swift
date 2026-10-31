import Foundation

/// A Revert asked for on a device that doesn't hold the workout's original recording. Any of
/// your devices that does hold it carries it out, and the restored workout syncs back. It names
/// the edit it means (`editedAt`), so a workout trimmed again afterwards is left alone.
struct WorkoutRevertRequest: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var sessionID: UUID
    var editedAt: Date
    var askedAt: Date

    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    func isLive(at now: Date) -> Bool { now.timeIntervalSince(askedAt) < Self.lifetime }
}

/// The rules of a trimmed (or corrected) workout across devices. Pure, for tests.
///
/// One workout, the same on every device: a trim or a revert made anywhere changes it
/// everywhere, Apple Health included, and Revert is offered wherever the workout is shown.
/// - The summary carries a `SessionEdit` while it stands edited: that is what offers Revert.
/// - A device that holds the original recording when an edited copy arrives keeps it, so it can
///   revert by itself. One that doesn't asks (`WorkoutRevertRequest`).
/// - Apple Health is the phone's. Whenever the recording the phone holds is replaced — by its own
///   trim or revert, or one that arrives from another device — it rewrites its Health copy.
enum WorkoutEdits {
    /// Whether two copies of a workout are the same recording: the same span, the same number of
    /// samples, the same pool. Derived series and marks don't count.
    static func sameRecording(_ a: FitnessSessionSummary, _ b: FitnessSessionSummary) -> Bool {
        abs(a.start.timeIntervalSince(b.start)) < 1
            && abs((a.end ?? a.start).timeIntervalSince(b.end ?? b.start)) < 1
            && a.sampleCount == b.sampleCount
            && a.poolLengthMeters == b.poolLengthMeters
    }

    /// What a device does about the original recording when a copy of the workout arrives from
    /// another device.
    enum Keeping: Equatable {
        case nothing
        /// The copy is an edit and this device holds the recording it was made from: keep that
        /// as the original before the edited one replaces it.
        case keepOriginal
        /// The copy is the original again (reverted elsewhere): the kept one has done its job.
        case dropOriginal
        /// The copy has lost its mark though it isn't the original (it came through a build that
        /// doesn't know the mark) and this device still holds the original: mark it again.
        case markEdited
    }

    /// - Parameters:
    ///   - local: this device's copy before the arriving one, if it has the workout.
    ///   - original: the original this device has kept for the workout, if any.
    ///   - replacesRecording: whether the arriving copy brings its recording (it replaces the
    ///     local file) and a local file is there to be replaced.
    static func keeping(local: FitnessSessionSummary?, incoming: FitnessSessionSummary,
                        original: FitnessSessionSummary?, replacesRecording: Bool) -> Keeping {
        if let original {
            guard incoming.edit == nil else { return .nothing }
            return sameRecording(original, incoming) ? .dropOriginal : .markEdited
        }
        guard let edit = incoming.edit, let local, replacesRecording,
              local.edit == nil, edit.describes(local) else { return .nothing }
        return .keepOriginal
    }

    /// The phone: whether Apple Health's copy has to follow a copy that arrived. Only when it
    /// brought a recording that isn't the one the phone had: a new workout isn't an edit, and a
    /// summary alone can't be written to Health.
    static func healthMustFollow(local: FitnessSessionSummary?, incoming: FitnessSessionSummary,
                                 recordingArrived: Bool) -> Bool {
        guard let local, recordingArrived else { return false }
        return !sameRecording(local, incoming)
    }

    // MARK: Health copies waiting to be rewritten

    /// The span Apple Health's copy has now, for a workout whose recording changed.
    struct Span: Codable, Equatable, Sendable {
        var start: Date
        var end: Date
    }

    /// One more change noted. The first span noted for a workout stays: it is what Health still
    /// holds until the rewrite goes through, however many times the workout changes meanwhile.
    static func noting(_ span: Span, for id: UUID, in pending: [String: Span]) -> [String: Span] {
        var pending = pending
        if pending[id.uuidString] == nil { pending[id.uuidString] = span }
        return pending
    }

    // MARK: Revert asked for on another device

    /// Whether this device carries out a Revert asked for elsewhere: it holds the original, and
    /// the workout still stands as the very edit the request named.
    static func shouldRevert(_ request: WorkoutRevertRequest, summary: FitnessSessionSummary?,
                             hasOriginal: Bool, now: Date) -> Bool {
        guard request.isLive(at: now), hasOriginal, let edit = summary?.edit else { return false }
        return edit.editedAt == request.editedAt
    }

    /// The list with one more: old ones dropped, one request per workout.
    static func adding(_ request: WorkoutRevertRequest, to list: [WorkoutRevertRequest],
                       now: Date) -> [WorkoutRevertRequest] {
        var kept = list.filter { $0.isLive(at: now) && $0.sessionID != request.sessionID }
        kept.append(request)
        return Array(kept.suffix(20))
    }
}
