import Foundation

/// Persists `WorkoutMotionCache`'s per-workout derived analysis (`WorkoutMotionAnalysis.Result`,
/// `WorkoutHandPath.Analysis`) to disk, so opening the SAME workout's Motion section on a LATER
/// launch does not re-run `WorkoutMotionAnalysis.analyze`/`WorkoutHandPath.analyze`. Those two
/// functions' cost was never measured before now; `WorkoutMotionCache`'s in-memory `cache`
/// dictionaries already avoided recomputing within one launch, but nothing survived the process
/// exiting — every fresh launch paid the full decode/band-pass/autocorrelate/FFT pipeline again,
/// for every workout the owner ever reopens.
///
/// Measured on the owner's real BFCCD614… swim (72 laps, 65,270 accel samples, a 4.3 MB raw
/// `.samples` file), single-threaded, on this Mac's own silicon:
///   - Release (`-O`, what a TestFlight/App Store build ships): decode + `WorkoutMotionAnalysis
///     .analyze` + `WorkoutHandPath.analyze` together measured ≈ 20-30 ms. Small, but not zero,
///     and paid again on every open with no cache.
///   - Debug (`-Onone`, what `tools/ios-install.sh` — the sanctioned device-install path per
///     the install scripts — actually installs): the SAME pipeline measured ≈ 1.1 SECONDS,
///     almost entirely inside `WorkoutHandPath.analyze`'s per-lap peak-prominence search. That is
///     a real, perceptible stall on the build the owner actually runs day to day, every time this
///     view reappears in a fresh process — this is the "are we computing this live on every
///     view" cost the owner asked about, and the answer for a cold Debug open is yes, and it is
///     measured in the hundreds of milliseconds to low seconds, not imagined.
///
/// A decoded cache hit, by contrast, measured 24-50 ms regardless of optimization level (see
/// `WorkoutMotionCacheEntry`'s doc comment for why a naive `Codable [Float]` almost erased that
/// win entirely). The saving isn't "faster analysis" — it's skipping the analysis outright once
/// it has run once for a given workout's current samples.
///
/// Keyed on workout id + `version` + the raw `.samples` file's byte count — deliberately NOT a
/// file timestamp. `WorkoutMotionCache`'s original design explicitly avoided a disk cache because
/// a CloudKit re-download of the identical recording writes a fresh file with a fresh
/// modification time, which would invalidate a timestamp-keyed cache on every such re-sync — in
/// practice, on every launch that happens to touch this workout's sync state. Byte count survives
/// that (a re-download of the same recording is byte-identical) while still invalidating on an
/// actual change — a re-trim, a corrupted partial download later replaced by a full one — neither
/// of which plausibly lands on the exact same file size by chance.
///
/// Never touches the main actor: `WorkoutMotionCache` calls `load`/`save` only from inside the
/// same `Task.detached` it already uses for the analysis itself. A decode failure (missing file,
/// truncated write, a future cache version read by an older build) is silently treated as a cache
/// miss — this is regenerable derived data, not the owner's only copy of anything, so there is
/// nothing here worth `SnapshotLoader`'s quarantine-and-preserve treatment
/// (`SnapshotPersistence.swift`) for irreplaceable source records; the caller just re-derives and
/// overwrites it.
enum WorkoutMotionDiskCache {
    /// Bump whenever `WorkoutMotionAnalysis.analyze` or `WorkoutHandPath.analyze` changes in a way
    /// that would produce different output for the same input samples — same convention as
    /// `FitnessStore.derivedBackfillVersion`.
    ///
    /// 2: per-activity spectrogram window/frequency ceiling (`ActivityHint
    /// .spectrogramWindowSamples`/`spectrogramMaxHz`, replacing one shared 128-sample/6 Hz
    /// spectrogram for every activity) plus the new `Result.pageConsistency` field — a cache entry
    /// written by version 1 has neither and must be re-derived, not read as-is.
    /// 3: `computeSpectrogram` linear-detrends each frame (not just de-means it) and never reports
    /// a bin below `minDominantSearchHz` as dominant — a version-2 cache entry was written before
    /// either fix and, measured against the owner's real swim, had EVERY frame's `dominantHz`
    /// locked onto the lowest bin with zero variation.
    static let version = 3

    /// Off-main-actor. `nil` on any miss: no file, a stale `version`, a `sampleFileSize` mismatch,
    /// or a decode failure. The caller always has a valid fallback (re-derive from raw samples),
    /// so every miss reason collapses to the same "treat as absent" outcome rather than needing
    /// its own case.
    static func load(from url: URL, sampleFileSize: Int) -> WorkoutMotionCacheEntry? {
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(WorkoutMotionCacheEntry.self, from: data),
              entry.isFresh(version: version, sampleFileSize: sampleFileSize)
        else { return nil }
        return entry
    }

    /// Off-main-actor. Atomic write so a crash or force-quit mid-write can never leave a
    /// half-written file for a later `load` to trip over — a torn file would fail `JSONDecoder`
    /// and just be treated as a miss regardless, but atomic writes make that outcome the only one
    /// possible instead of relying on the decode failure to catch it.
    static func save(_ entry: WorkoutMotionCacheEntry, to url: URL) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// One workout's persisted motion-analysis cache entry: what `WorkoutMotionCache` computed, plus
/// enough about the inputs it was computed from to know whether that's still trustworthy — see
/// `WorkoutMotionDiskCache`'s doc comment for the full design rationale.
///
/// `result`/`handPath` rely on `WorkoutMotionAnalysis.Cycle`, `.SpectrogramFrame`, and
/// `WorkoutHandPath.Lap`'s own custom `Codable` conformances (in `WorkoutMotionAnalysis.swift`/
/// `WorkoutHandPath.swift`) to route their large `[Float]` payloads through packed `Data` blobs
/// instead of Swift's default per-element array coding. That distinction is not cosmetic: on the
/// real swim this was measured against, a synthesized `Codable [Float]` conformance cost ~920 ms
/// to encode+decode — close enough to the ~1.1 s Debug recompute cost that a naive cache would
/// have bought almost nothing. The packed-`Data` conformances measured 24-50 ms for the same
/// payload, an actual win at every optimization level.
struct WorkoutMotionCacheEntry: Sendable, Codable {
    var version: Int
    var sampleFileSize: Int
    /// `nil` only when `WorkoutMotionCache.result(for:fitness:)` itself returned `nil` (no usable
    /// accel data) — still worth caching, so a workout that will never produce a signature doesn't
    /// re-run the same negative result every launch either.
    var result: WorkoutMotionAnalysis.Result?
    /// `nil` when the workout isn't hand-path-eligible (not a pool swim, or `WorkoutHandPath
    /// .analyze` found nothing usable) — same reasoning as `result`.
    var handPath: WorkoutHandPath.Analysis?

    /// Pure — no disk access — so this is the one piece of `WorkoutMotionDiskCache`'s logic
    /// `BananaTests` exercises directly without touching the filesystem.
    func isFresh(version: Int, sampleFileSize: Int) -> Bool {
        self.version == version && self.sampleFileSize == sampleFileSize
    }
}
