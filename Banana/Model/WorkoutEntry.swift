import Foundation

/// One workout, pairing the Apple Health record with our detailed recording (if the same
/// session). Either may be nil — external workouts have only Health; a just-recorded one
/// may briefly have only our summary before Health syncs.
struct WorkoutEntry: Identifiable, Hashable {
    let health: HealthWorkout?
    let summary: FitnessSessionSummary?

    var id: String { health.map { "h-\($0.id)" } ?? summary.map { "s-\($0.id)" } ?? "none" }

    /// Whether a stored route id (`id` at the time it was saved) still names this entry. A
    /// workout first seen as our summary ("s-…") gets its Health half later and its `id` becomes
    /// "h-…"; either half still finds it.
    func matches(routeID: String) -> Bool {
        routeID == id
            || summary.map { routeID == "s-\($0.id)" } == true
            || health.map { routeID == "h-\($0.id)" } == true
    }
    var start: Date { health?.start ?? summary?.start ?? .distantPast }
    var activity: String { health?.activity ?? summary?.activity ?? "Workout" }
    /// The workout's time as shown: Apple Health's (which leaves pauses out), or the recording's
    /// own with its pauses left out.
    var duration: TimeInterval { health?.duration ?? summary?.activeDuration ?? 0 }
    var distanceMeters: Double? { health?.distanceMeters ?? summary?.totalDistance }

    /// Two records this close in start time are one workout (the Watch summary and its
    /// HealthKit copy). Shared with the review coordinator so both agree on what "same" means.
    static let matchTolerance: TimeInterval = 90

    /// One workout = one entry. Everything within the same ~90s window collapses to a single
    /// bucket, so our detailed summary + its Apple Health record — and any duplicate HKWorkout
    /// a trim/rewrite may have left behind — show as ONE row. Newest first.
    ///
    /// This used to be copied per screen (Fitness, Rhythm, the Mac list), each with its own
    /// tolerance and ordering; the phone and the Mac disagreed on counts as a result.
    ///
    /// - Parameter hiddenHealthIDs: Health workouts the owner asked Banana to hide (see
    ///   `HealthKitStore.hide`) — dropped before pairing so a hidden row can never resurface on
    ///   any screen that merges through here. `HealthKitStore.workouts` already excludes these
    ///   at the source, so passing it is defense-in-depth rather than the only guard.
    ///   - ownBundleID: Banana's own bundle — its copies are preferred when several apps wrote
    ///     the same workout (see `WorkoutSourcePreference`).
    static func merge(summaries: [FitnessSessionSummary], health: [HealthWorkout],
                      hiddenHealthIDs: Set<UUID> = [],
                      ownBundleID: String? = Bundle.main.bundleIdentifier) -> [WorkoutEntry] {
        let health = hiddenHealthIDs.isEmpty ? health : health.filter { !hiddenHealthIDs.contains($0.id) }
        var buckets: [WorkoutEntry] = []
        var indicesByTimeBucket: [Int: [Int]] = [:]
        func timeBucket(_ date: Date) -> Int {
            Int(floor(date.timeIntervalSinceReferenceDate / matchTolerance))
        }
        func bucket(near date: Date) -> Int? {
            let key = timeBucket(date)
            return ((key - 1)...(key + 1))
                .flatMap { indicesByTimeBucket[$0] ?? [] }
                .filter { abs(buckets[$0].start.timeIntervalSince(date)) < matchTolerance }
                .min { abs(buckets[$0].start.timeIntervalSince(date))
                     < abs(buckets[$1].start.timeIntervalSince(date)) }
        }
        func append(_ entry: WorkoutEntry) {
            let index = buckets.count
            buckets.append(entry)
            indicesByTimeBucket[timeBucket(entry.start), default: []].append(index)
        }
        // Summaries first — they carry the map/detail and anchor each bucket.
        for summary in summaries where bucket(near: summary.start) == nil {
            append(WorkoutEntry(health: nil, summary: summary))
        }
        for workout in health {
            if let i = bucket(near: workout.start) {
                // Several apps' copies of one workout land here (WHOOP, Strava, a second save).
                // Keep the one from the device that measured it, not whichever arrived first —
                // WHOOP's copy, for one, has no distance.
                if let current = buckets[i].health,
                   !WorkoutSourcePreference.prefers(workout, over: current, ownBundleID: ownBundleID) {
                    continue
                }
                buckets[i] = WorkoutEntry(health: workout, summary: buckets[i].summary)
            } else {
                append(WorkoutEntry(health: workout, summary: nil))
            }
        }
        return buckets.sorted { $0.start > $1.start }
    }
}

extension WorkoutEntry {
    /// Which detail screen shows a workout.
    enum Detail: Equatable {
        /// The wide detail: the Mac's, and an iPad's at full width.
        case wide
        /// The phone's detail.
        case compact
        /// Its numbers from Apple Health: there is nothing else to show.
        case healthOnly
    }

    /// A workout Banana recorded opens in the layout's own detail. One that's only in Health
    /// opens too, everywhere: on the Mac its row went nowhere.
    func detail(wide: Bool) -> Detail {
        summary == nil ? .healthOnly : (wide ? .wide : .compact)
    }

    /// What a deleted workout is hidden by while its Undo is offered (`WorkoutRemoval`): its
    /// Banana record's id, which stays the same when Health's half arrives and `id` changes.
    var removalID: String { "workout:" + (summary?.id.uuidString ?? id) }

    /// Entries, less any deleted a moment ago.
    static func visible(_ entries: [WorkoutEntry], hiding hidden: Set<String>) -> [WorkoutEntry] {
        hidden.isEmpty ? entries : entries.filter { !hidden.contains($0.removalID) }
    }
}

