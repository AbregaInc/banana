import AppKit
import CoreGraphics
import Foundation
import ImageIO

// Minimal compile seam matching AppSettings.swift; the full settings object pulls in the app graph.
enum WatchAudioQuality: String, Codable {
    case original
    case medium
    case low
}

private struct Timing {
    var wallMilliseconds: Double
    var cpuMilliseconds: Double
}

private func processCPUSeconds() -> Double {
    var value = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
    return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
}

private func measureOnce(_ operation: () -> Int) -> Timing {
    let wallStart = ProcessInfo.processInfo.systemUptime
    let cpuStart = processCPUSeconds()
    let checksum = operation()
    precondition(checksum > 0, "The optimizer removed or invalidated the workload")
    return Timing(
        wallMilliseconds: (ProcessInfo.processInfo.systemUptime - wallStart) * 1_000,
        cpuMilliseconds: (processCPUSeconds() - cpuStart) * 1_000)
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func measure(iterations: Int = 7, _ operation: () -> Int) -> Timing {
    _ = operation()
    var timings: [Timing] = []
    timings.reserveCapacity(iterations)
    for _ in 0..<iterations {
        timings.append(measureOnce(operation))
    }
    return Timing(
        wallMilliseconds: median(timings.map(\.wallMilliseconds)),
        cpuMilliseconds: median(timings.map(\.cpuMilliseconds)))
}

private func makeArtworkData(pixelSize: Int = 3_000) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: pixelSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemOrange.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.setFillColor(NSColor.systemIndigo.cgColor)
    for index in 0..<24 {
        let side = CGFloat(pixelSize) / 5
        let origin = CGFloat(index) * CGFloat(pixelSize) / 24
        context.fillEllipse(in: CGRect(x: origin - side / 2, y: origin - side / 3,
                                       width: side, height: side))
    }
    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

private func downsample(_ data: Data, maximumPixelSize: Int) -> CGImage {
    let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary)!
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)!
}

private func imageBytes(_ image: CGImage) -> Int {
    image.bytesPerRow * image.height
}

private struct ArtworkResult {
    var timing: Timing
    var cacheBytes: Int
    var decodeCount: Int
}

private struct ArtworkCache {
    private struct Entry {
        var image: CGImage
        var pixelSize: Int
        var cost: Int
    }

    private let byteLimit: Int
    private var entries: [Int: Entry] = [:]
    private var oldestToNewest: [Int] = []
    private(set) var totalBytes = 0
    private(set) var decodeCount = 0

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    mutating func request(cover: Int, data: Data, pixelSize: Int) -> CGImage {
        if let entry = entries[cover], entry.pixelSize >= pixelSize {
            touch(cover)
            return entry.image
        }
        if let replaced = entries.removeValue(forKey: cover) {
            totalBytes -= replaced.cost
            oldestToNewest.removeAll { $0 == cover }
        }
        let image = downsample(data, maximumPixelSize: pixelSize)
        let cost = imageBytes(image)
        entries[cover] = Entry(image: image, pixelSize: pixelSize, cost: cost)
        oldestToNewest.append(cover)
        totalBytes += cost
        decodeCount += 1
        while totalBytes > byteLimit, let oldest = oldestToNewest.first {
            oldestToNewest.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                totalBytes -= evicted.cost
            }
        }
        return image
    }

    private mutating func touch(_ cover: Int) {
        oldestToNewest.removeAll { $0 == cover }
        oldestToNewest.append(cover)
    }
}

private func artworkSession(
    data: Data,
    browsedCovers: Int,
    openedCovers: Int,
    adaptive: Bool
) -> ArtworkResult {
    func execute() -> (checksum: Int, cacheBytes: Int, decodeCount: Int) {
        var cache = ArtworkCache(byteLimit: 40 * 1_024 * 1_024)
        var checksum = 0
        for cover in 0..<browsedCovers {
            let image = cache.request(
                cover: cover,
                data: data,
                pixelSize: adaptive ? 192 : 1_000)
            checksum += image.width
        }
        for cover in 0..<min(openedCovers, browsedCovers) {
            if adaptive {
                checksum += cache.request(cover: cover, data: data, pixelSize: 512).width
            }
            checksum += cache.request(cover: cover, data: data, pixelSize: 1_000).width
        }
        return (checksum, cache.totalBytes, cache.decodeCount)
    }
    let representative = execute()
    let timing = measure(iterations: 5) { execute().checksum }
    return ArtworkResult(
        timing: timing,
        cacheBytes: representative.cacheBytes,
        decodeCount: representative.decodeCount)
}

private func ratio(_ candidate: Double, _ baseline: Double) -> String {
    String(format: "%.2f×", candidate / max(baseline, 0.000_001))
}

private func bytes(_ value: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
}

private func printTiming(_ baseline: Timing, _ candidate: Timing) {
    print(String(
        format: "  baseline  wall %8.2f ms  cpu %8.2f ms",
        baseline.wallMilliseconds, baseline.cpuMilliseconds))
    print(String(
        format: "  candidate wall %8.2f ms  cpu %8.2f ms  (cpu %@)",
        candidate.wallMilliseconds, candidate.cpuMilliseconds,
        ratio(candidate.cpuMilliseconds, baseline.cpuMilliseconds)))
}

private func runArtworkComparison() {
    let data = makeArtworkData()
    let scenarios = [
        (title: "scan 40 shows, open 1", browsed: 40, opened: 1),
        (title: "browse 5 shows, open 3", browsed: 5, opened: 3),
    ]
    for (index, scenario) in scenarios.enumerated() {
        if index > 0 { print("") }
        print("ARTWORK / \(scenario.title), 52 pt rows @3×, 40 MB memory limit")
        let baseline = artworkSession(
            data: data,
            browsedCovers: scenario.browsed,
            openedCovers: scenario.opened,
            adaptive: false)
        let candidate = artworkSession(
            data: data,
            browsedCovers: scenario.browsed,
            openedCovers: scenario.opened,
            adaptive: true)
        precondition(candidate.cacheBytes <= 40 * 1_024 * 1_024)
        printTiming(baseline.timing, candidate.timing)
        print("  decodes: \(baseline.decodeCount) → \(candidate.decodeCount)")
        print("  resident decoded pixels: \(bytes(baseline.cacheBytes)) → \(bytes(candidate.cacheBytes))")
        print("  disk: \(scenario.browsed) original files × \(bytes(data.count)); no size variants in either")
    }
}

private struct WorkoutProducts: Equatable {
    var signalCounts: [String: Int]
    var route: [RoutePoint]
    var heartRateSeries: [HRPoint]
    var healthHeartRates: [FitnessSample]
    var healthLocations: [FitnessSample]
}

private func makeWorkoutFixture(duration: Int = 3_600) -> FitnessSession {
    let ticks = duration * 25
    var samples: [FitnessSample] = []
    samples.reserveCapacity(ticks * 2 + duration * 3 + duration / 5)
    for tick in 0..<ticks {
        let t = Double(tick) / 25
        let wave = sin(t / 7)
        samples.append(FitnessSample(
            t: t, kind: .accel,
            v1: wave, v2: cos(t / 11), v3: 1 + sin(t / 5) * 0.08))
        samples.append(FitnessSample(
            t: t, kind: .gyro,
            v1: sin(t / 3) * 0.5, v2: cos(t / 4) * 0.4, v3: sin(t / 6) * 0.3))
        if tick % 25 == 0 {
            let second = Double(tick / 25)
            samples.append(FitnessSample(
                t: t, kind: .heartRate, v1: 132 + sin(second / 30) * 18))
            samples.append(FitnessSample(
                t: t, kind: .energy, v1: second * 0.16))
            samples.append(FitnessSample(
                t: t, kind: .distance, v1: second * 2.8))
        }
        if tick % 125 == 0 {
            samples.append(FitnessSample(
                t: t, kind: .location,
                v1: 40.7128 + t / 1_000_000,
                v2: -74.0060 + sin(t / 300) / 10_000,
                v3: 2.8))
        }
    }
    let start = Date(timeIntervalSince1970: 1_750_000_000)
    return FitnessSession(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        start: start,
        end: start.addingTimeInterval(Double(duration)),
        activity: "Running",
        avgHeartRate: 132,
        totalEnergy: Double(duration) * 0.16,
        totalDistance: Double(duration) * 2.8,
        samples: samples)
}

private func baselineWorkoutProducts(_ session: FitnessSession) -> WorkoutProducts {
    let summary = FitnessSessionSummary(session: session)
    let healthHeartRates = session.samples.filter { $0.kind == .heartRate }
    let healthLocations = session.samples.filter { $0.kind == .location }
    return WorkoutProducts(
        signalCounts: summary.signalCounts,
        route: summary.route,
        heartRateSeries: summary.heartRateSeries,
        healthHeartRates: healthHeartRates,
        healthLocations: healthLocations)
}

private func onePassWorkoutProducts(_ session: FitnessSession) -> WorkoutProducts {
    var counts: [String: Int] = [:]
    var locations: [FitnessSample] = []
    var heartRates: [FitnessSample] = []
    for sample in session.samples {
        counts[sample.kind.rawValue, default: 0] += 1
        if sample.kind == .heartRate {
            heartRates.append(sample)
        } else if sample.kind == .location {
            locations.append(sample)
        }
    }
    let routeStep = max(1, locations.count / 40)
    let route: [RoutePoint] = locations.enumerated().compactMap { index, sample in
        guard index % routeStep == 0, let lon = sample.v2 else { return nil }
        return RoutePoint(lat: sample.v1, lon: lon)
    }
    let heartRateStep = max(1, heartRates.count / 120)
    let heartRateSeries: [HRPoint] = heartRates.enumerated().compactMap { index, sample in
        index % heartRateStep == 0 ? HRPoint(t: sample.t, bpm: sample.v1) : nil
    }
    return WorkoutProducts(
        signalCounts: counts,
        route: route,
        heartRateSeries: heartRateSeries,
        healthHeartRates: heartRates,
        healthLocations: locations)
}

private func workoutChecksum(_ products: WorkoutProducts) -> Int {
    products.signalCounts.values.reduce(0, +)
        + products.route.count
        + products.heartRateSeries.count
        + products.healthHeartRates.count
        + products.healthLocations.count
}

private func runWorkoutComparison() {
    let session = makeWorkoutFixture()
    let baselineProducts = baselineWorkoutProducts(session)
    let candidateProducts = onePassWorkoutProducts(session)
    precondition(
        candidateProducts == baselineProducts,
        "RED: one-pass workout processing must preserve every derived product")

    let baseline = measure {
        workoutChecksum(baselineWorkoutProducts(session))
    }
    let candidate = measure {
        workoutChecksum(onePassWorkoutProducts(session))
    }

    print("WORKOUT / one-hour 25 Hz accel + 25 Hz gyro capture")
    print("  raw samples: \(session.samples.count.formatted())")
    printTiming(baseline, candidate)
}

private struct PodcastSettingsRecord: Codable, Equatable {
    var id: UUID
    var direction: PlayDirection
    var speed: Double
    var downloadRule: DownloadRule
    var syncToWatch: Bool
    var watchAudioQuality: WatchAudioQuality?
}

private func makePodcastFixture() -> [Podcast] {
    var podcasts: [Podcast] = []
    podcasts.reserveCapacity(20)
    let summary = String(repeating: "A product-shaped episode summary with links and credits. ", count: 12)
    for showIndex in 0..<20 {
        let episodeCount = showIndex == 0 ? 1_200 : 250
        let episodes = (0..<episodeCount).map { episodeIndex in
            Episode(
                id: "show-\(showIndex)-episode-\(episodeIndex)",
                title: "Episode \(episodeIndex): A representative title",
                audioURL: URL(string: "https://cdn.example.com/\(showIndex)/\(episodeIndex).mp3")!,
                pubDate: Date(timeIntervalSince1970: 1_750_000_000 - Double(episodeIndex * 86_400)),
                duration: 3_600,
                season: episodeIndex / 20,
                episodeNumber: episodeIndex,
                summary: summary,
                transcriptURL: episodeIndex.isMultiple(of: 3)
                    ? URL(string: "https://cdn.example.com/\(showIndex)/\(episodeIndex).vtt")
                    : nil)
        }
        var podcast = Podcast(
            id: UUID(),
            feedURL: URL(string: "https://feeds.example.com/show-\(showIndex).xml")!,
            title: "Representative Show \(showIndex)",
            author: "Author \(showIndex)",
            artworkURL: URL(string: "https://images.example.com/show-\(showIndex).jpg"),
            direction: showIndex.isMultiple(of: 2) ? .newestFirst : .oldestFirst,
            speed: showIndex.isMultiple(of: 3) ? 1.25 : 1,
            downloadRule: showIndex.isMultiple(of: 4) ? .latest(3) : .off,
            syncToWatch: showIndex.isMultiple(of: 5),
            episodes: episodes)
        podcast.watchAudioQuality = showIndex.isMultiple(of: 5) ? .low : nil
        podcast.currentEpisodeID = episodes[episodeCount / 3].id
        podcast.positions[podcast.currentEpisodeID!] = 1_234
        podcast.completed = Set(episodes.prefix(episodeCount / 4).map(\.id))
        podcast.lastPlayedAt = Date(timeIntervalSince1970: 1_749_950_000)
        podcasts.append(podcast)
    }
    return podcasts
}

private func settingsRecords(_ podcasts: [Podcast]) -> [PodcastSettingsRecord] {
    podcasts.map {
        PodcastSettingsRecord(
            id: $0.id,
            direction: $0.direction,
            speed: $0.speed,
            downloadRule: $0.downloadRule,
            syncToWatch: $0.syncToWatch,
            watchAudioQuality: $0.watchAudioQuality)
    }
}

private func settingsChecksum(_ records: [PodcastSettingsRecord]) -> Int {
    records.reduce(0) {
        $0 + Int($1.speed * 100) + $1.downloadRule.count
            + ($1.syncToWatch ? 1 : 0)
            + ($1.watchAudioQuality == nil ? 0 : 1)
    }
}

private func runPodcastPersistenceComparison() {
    let podcasts = makePodcastFixture()
    let candidateRecords = settingsRecords(podcasts)
    precondition(
        zip(podcasts, candidateRecords).allSatisfy { podcast, record in
            record.id == podcast.id
                && record.direction == podcast.direction
                && record.speed == podcast.speed
                && record.downloadRule == podcast.downloadRule
                && record.syncToWatch == podcast.syncToWatch
                && record.watchAudioQuality == podcast.watchAudioQuality
        },
        "Compact podcast settings must preserve every user-visible policy")

    let encoder = JSONEncoder()
    let fullData = try! encoder.encode(podcasts)
    let settingsData = try! encoder.encode(candidateRecords)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banana-performance-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fullURL = directory.appendingPathComponent("podcasts.json")
    let settingsURL = directory.appendingPathComponent("podcast-settings.json")

    let baseline = measure(iterations: 5) {
        let data = try! encoder.encode(podcasts)
        try! data.write(to: fullURL, options: .atomic)
        return data.count
    }
    let candidate = measure(iterations: 5) {
        let data = try! encoder.encode(candidateRecords)
        try! data.write(to: settingsURL, options: .atomic)
        return data.count
    }

    let decoded = try! JSONDecoder().decode([PodcastSettingsRecord].self, from: settingsData)
    precondition(decoded == candidateRecords)
    print("PODCAST SETTINGS / 20 shows, \(podcasts.reduce(0) { $0 + $1.episodes.count }.formatted()) episodes")
    printTiming(baseline, candidate)
    print("  bytes written per setting change: \(bytes(fullData.count)) → \(bytes(settingsData.count))")
    print("  compact file is additional durable state unless the catalogue schema is split")
    precondition(settingsChecksum(decoded) > 0)
}

private struct PreparedWake: Codable, Equatable {
    var podcastID: UUID
    var podcastTitle: String
    var artworkURL: URL?
    var speed: Double
    var lastPlayedAt: Date?
    var episode: Episode
    var resumePosition: Double
}

private func selectPreparedWake(
    podcasts: [Podcast],
    pool: [UUID]
) -> PreparedWake? {
    for id in pool {
        guard let podcast = podcasts.first(where: { $0.id == id }),
              let episode = podcast.nextEpisode(),
              !podcast.completed.contains(episode.id) else { continue }
        return PreparedWake(
            podcastID: podcast.id,
            podcastTitle: podcast.title,
            artworkURL: podcast.artworkURL,
            speed: podcast.speed,
            lastPlayedAt: podcast.lastPlayedAt,
            episode: episode,
            resumePosition: podcast.resumePosition(for: episode.id))
    }
    return nil
}

private func wakeChecksum(_ prepared: PreparedWake) -> Int {
    prepared.episode.id.utf8.count
        + prepared.podcastTitle.utf8.count
        + prepared.episode.audioURL.absoluteString.utf8.count
        + Int(prepared.speed * 100)
        + Int(prepared.resumePosition)
}

private func runColdWakeComparison() {
    let podcasts = makePodcastFixture()
    let pool = Array(podcasts.prefix(4).map(\.id))
    let expected = selectPreparedWake(podcasts: podcasts, pool: pool)!

    let encoder = JSONEncoder()
    let catalogueData = try! encoder.encode(podcasts)
    let preparedData = try! encoder.encode(expected)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banana-wake-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalogueURL = directory.appendingPathComponent("podcasts.json")
    let preparedURL = directory.appendingPathComponent("prepared-wake.json")
    try! catalogueData.write(to: catalogueURL, options: .atomic)
    try! preparedData.write(to: preparedURL, options: .atomic)

    let baseline = measure(iterations: 5) {
        let data = try! Data(contentsOf: catalogueURL)
        let decoded = try! JSONDecoder().decode([Podcast].self, from: data)
        return wakeChecksum(selectPreparedWake(podcasts: decoded, pool: pool)!)
    }
    let candidate = measure(iterations: 5) {
        let data = try! Data(contentsOf: preparedURL)
        let decoded = try! JSONDecoder().decode(PreparedWake.self, from: data)
        return wakeChecksum(decoded)
    }
    let decodedPrepared = try! JSONDecoder().decode(PreparedWake.self, from: preparedData)
    precondition(decodedPrepared == expected)

    print("COLD WAKE / background alarm selects from a four-show priority pool")
    printTiming(baseline, candidate)
    print("  launch read: \(bytes(catalogueData.count)) → \(bytes(preparedData.count))")
    print("  prepared state must be refreshed after pool, feed, progress, or speed changes")
}

private struct CloudCadenceResult {
    var name: String
    var requestedCommits: Int
    var medianStaleness: Int
    var p95Staleness: Int
    var maximumStaleness: Int
}

private func percentile(_ sortedValues: [Int], _ percentile: Double) -> Int {
    let index = Int((Double(sortedValues.count - 1) * percentile).rounded(.up))
    return sortedValues[index]
}

private func cloudCadence(
    name: String,
    periodicSeconds: Int?
) -> CloudCadenceResult {
    let sessionDuration = 3_600
    // The representative session starts in-app, locks after one minute, and finishes at one hour.
    // These are the existing start/background/finish commit points.
    var commits: Set<Int> = [0, 60, sessionDuration]
    if let periodicSeconds {
        for second in stride(from: periodicSeconds, through: sessionDuration, by: periodicSeconds) {
            commits.insert(second)
        }
    }
    let orderedCommits = commits.sorted()
    // The source keeps playing while another iCloud device starts. A normal pause-first handoff is
    // handled separately below because the pause itself adds an exact commit at the handoff time.
    let staleness = (61..<sessionDuration).map { handoff in
        handoff - orderedCommits.last(where: { $0 <= handoff })!
    }.sorted()
    return CloudCadenceResult(
        name: name,
        requestedCommits: orderedCommits.count,
        medianStaleness: percentile(staleness, 0.50),
        p95Staleness: percentile(staleness, 0.95),
        maximumStaleness: staleness.last!)
}

private func durationLabel(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    let remainder = seconds % 60
    return remainder == 0 ? "\(minutes)m" : "\(minutes)m\(remainder)s"
}

private func runCrossDeviceComparison() {
    let policies = [
        cloudCadence(name: "event-only (current)", periodicSeconds: nil),
        cloudCadence(name: "hybrid 30 s", periodicSeconds: 30),
        cloudCadence(name: "hybrid 2 min", periodicSeconds: 120),
        cloudCadence(name: "hybrid 5 min", periodicSeconds: 300),
    ]
    precondition(policies[0].maximumStaleness > policies[3].maximumStaleness)
    precondition(policies[1].maximumStaleness < policies[2].maximumStaleness)

    print("CROSS-DEVICE / one-hour locked-screen listen, target starts without pausing source")
    print("  policy                 cloud requests   p50 stale   p95 stale   max stale")
    for policy in policies {
        let name = policy.name.padding(
            toLength: 22,
            withPad: " ",
            startingAt: 0)
        print(
            "  \(name) "
                + String(format: "%3d / session", policy.requestedCommits)
                + "   \(durationLabel(policy.medianStaleness))"
                + "   \(durationLabel(policy.p95Staleness))"
                + "   \(durationLabel(policy.maximumStaleness))")
    }
    print("  pause-first handoff: 0s stale with the current event commit")
    print("  local crash safety remains a 30s disk checkpoint and requests no CloudKit radio")

    // The current phone→Watch order starts the Watch from its stored position, then asks the phone
    // to pause. That pause queues the newer position, but receiving it updates the Watch store, not
    // the AVAudioPlayer that is already running. Model that order independently of cloud cadence.
    let phoneLivePosition = 1_234
    let watchStoredPosition = 900
    let currentPhoneToWatchStart = watchStoredPosition
    let handshakeFirstStart = max(watchStoredPosition, phoneLivePosition)
    precondition(handshakeFirstStart == phoneLivePosition)
    print("\nPHONE → WATCH TAKEOVER / source at 1,234s, Watch last stored at 900s")
    print("  current start error: \(phoneLivePosition - currentPhoneToWatchStart)s")
    print("  live-position handshake error: \(phoneLivePosition - handshakeFirstStart)s")
    print("  this handoff uses WatchConnectivity; changing CloudKit cadence does not fix it")
}

@main
private enum PerformanceComparison {
    static func main() {
        let selections = Set(CommandLine.arguments.dropFirst())
        if selections.isEmpty || selections.contains("artwork") {
            runArtworkComparison()
        }
        if selections.isEmpty || selections.contains("workout") {
            if selections.isEmpty { print("") }
            runWorkoutComparison()
        }
        if selections.isEmpty || selections.contains("podcasts") {
            if selections.isEmpty { print("") }
            runPodcastPersistenceComparison()
        }
        if selections.isEmpty || selections.contains("wake") {
            if selections.isEmpty { print("") }
            runColdWakeComparison()
        }
        if selections.isEmpty || selections.contains("sync") {
            if selections.isEmpty { print("") }
            runCrossDeviceComparison()
        }
    }
}
