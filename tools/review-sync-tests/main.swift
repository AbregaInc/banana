import Foundation

@main struct Checks {
    @MainActor static func main() throws {
        var checks = 0
        func check(_ ok: @autoclosure () -> Bool, _ message: String) {
            guard ok() else { print("FAIL: " + message); exit(1) }
            checks += 1
        }
        let end = Date(timeIntervalSinceReferenceDate: 814310821.492354)
        let now = end.addingTimeInterval(60)
        let name = "banana-review-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(end.timeIntervalSince1970, forKey: "workoutReview.lastSeenEnd")
        let rounded = Date(timeIntervalSince1970: defaults.double(forKey: "workoutReview.lastSeenEnd"))
        check(end > rounded, "fixture must reproduce legacy timestamp round-down")
        var workout = HealthWorkout()
        workout.start = end.addingTimeInterval(-15)
        workout.end = end
        workout.duration = 15
        for _ in 0..<3 {
            let review = WorkoutReviewCoordinator(defaults: defaults)
            check(review.check(summaries: [], healthWorkouts: [workout], now: now) == nil,
                  "legacy watermark must suppress the same workout on repeated opens")
        }
        workout.end = end.addingTimeInterval(30)
        let review = WorkoutReviewCoordinator(defaults: defaults)
        check(review.check(summaries: [], healthWorkouts: [workout], now: now)?.health?.id == workout.id,
              "a genuinely newer workout still opens")
        check(defaults.object(forKey: "workoutReview.lastSeenEnd") is Date,
              "new watermarks retain NSDate precision")
        review.pending = nil
        check(review.check(summaries: [], healthWorkouts: [workout], now: now) == nil,
              "dismissal must not reoffer the same workout")
        let reopened = WorkoutReviewCoordinator(defaults: defaults)
        check(reopened.check(summaries: [], healthWorkouts: [workout], now: now) == nil,
              "the dismissal survives rebuilding the coordinator")
        check(reopened.lastSeenEnd == workout.end, "persisted end time retains exact precision")
        var summary = FitnessSessionSummary(session: FitnessSession(id: UUID(), start: workout.start,
            end: workout.end, activity: "Other", samples: []))
        summary.end = workout.end
        check(reopened.check(summaries: [summary], healthWorkouts: [workout], now: now) == nil,
              "a late Watch summary does not reopen a reviewed Health workout")

        var note = VoiceNote(createdAt: end, updatedAt: end, audioFilename: "fixture.m4a")
        // Exercise the real canonical encoder/decoder, not a rounded test double.
        let echo = try CanonicalJSON.decode(VoiceNote.self, from: CanonicalJSON.value(of: note))
        check(note.syncDate > echo.syncDate, "fixture must reproduce the old kept-own clock decision")
        check(!note.isNewerForSync(than: echo), "canonical echo must be accepted without uploading again")
        check(!echo.isNewerForSync(than: note), "equal wire timestamps are symmetric")
        note.updatedAt = end.addingTimeInterval(0.01)
        check(note.isNewerForSync(than: echo), "a real newer local edit must still win")
        check(!echo.isNewerForSync(than: note), "a newer incoming edit must be accepted")
        print("Passed \(checks) workout-review and canonical-note clock checks.")
    }
}
