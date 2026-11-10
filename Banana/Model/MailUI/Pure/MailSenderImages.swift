#if !BANANA_PUBLIC
import Foundation
import ImageIO

/// A sender's picture, as Banana Cloud found it (MAIL-UX "Sender images"): the face's monogram is
/// drawn at once and stays when there is none; a picture, when one comes, is laid over it.
///
/// The device never asks Gravatar, a brand or Google: it asks the service which picture each
/// address has (`lookup`, many at once) and fetches the bytes of an id it does not hold yet
/// (`bytes`). An id is the hash of the bytes, so a file once held is right for good.
///
/// - Many rows asking at once make one request: asks within `gather` of each other go together,
///   at most 50 addresses, and two asks for one address share one answer.
/// - What the service said is kept, so the next launch asks nothing it already knows: a picture
///   for `knownFor`, "none" for `noneFor`. A "still looking" is asked again shortly, twice at most.
/// - Bytes are kept on disk, the least recently shown first to go past `diskLimit`; decoded
///   pictures are kept by `MailPictureLoader` (memory) and in `memory` for a row's first frame.
actor MailSenderImages {
    enum Answer: Equatable, Sendable { case image(String), none, pending }

    struct Service: Sendable {
        /// The service's answer for these addresses (lower-cased), one per address it knew.
        var lookup: @Sendable ([String]) async throws -> [String: Answer]
        /// The bytes of an image id; nil when the service has none.
        var bytes: @Sendable (String) async throws -> Data?
    }

    struct Known: Codable, Equatable {
        var image: String?
        var at: Date
    }

    static let gather: Duration = .milliseconds(40)
    static let mostPerAsk = 50
    static let knownFor: TimeInterval = 3 * 86_400
    static let noneFor: TimeInterval = 86_400
    static let failedFor: TimeInterval = 600
    static let pendingRetries = 2

    private let directory: URL
    private let service: Service
    private let now: @Sendable () -> Date
    private let diskLimit: Int
    private let pendingDelay: Duration
    private var known: [String: Known] = [:]
    private var failedAt: [String: Date] = [:]
    private var loaded = false
    private var waiting: [String: [CheckedContinuation<String?, Never>]] = [:]
    private var queued: [String] = []
    private var flushing = false
    private var downloads: [String: Task<Data?, Never>] = [:]
    private var saveScheduled = false

    /// Decoded pictures by "address#px", read synchronously by a row for its first frame, so a row
    /// scrolled back into view shows its picture without a monogram flash. Thread-safe (NSCache).
    nonisolated static let memory: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    init(directory: URL, service: Service, diskLimit: Int = 24 * 1024 * 1024, pendingDelay: Duration = .seconds(5),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.service = service
        self.diskLimit = diskLimit
        self.pendingDelay = pendingDelay
        self.now = now
    }

    nonisolated static func key(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The picture already decoded for this address at this size, without waiting.
    nonisolated static func cached(_ address: String, px: Int) -> CGImage? {
        memory.object(forKey: "\(key(address))#\(px)" as NSString)
    }

    /// The picture for an address, at most `px` on its long side; nil to keep the monogram.
    func image(for address: String, px: Int) async -> CGImage? {
        let address = Self.key(address)
        guard address.contains("@") else { return nil }
        if let hit = Self.cached(address, px: px) { return hit }
        guard let id = await imageID(for: address), !Task.isCancelled,
              let bytes = await data(for: id), !Task.isCancelled else { return nil }
        // The bytes are in hand before the decoder's two slots are taken: a download never holds one.
        let image = await MailPictureLoader.shared.image(key: "sender-\(id)", maxPixel: px) { bytes }
        if let image { Self.memory.setObject(image, forKey: "\(address)#\(px)" as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }

    // MARK: - Which picture

    /// The image id the service gave this address, asking it when what is kept is stale.
    func imageID(for address: String) async -> String? {
        loadIfNeeded()
        if let entry = known[address], fresh(entry) { return entry.image }
        if let failed = failedAt[address], now().timeIntervalSince(failed) < Self.failedFor { return known[address]?.image }
        return await withCheckedContinuation { continuation in
            let first = waiting[address] == nil
            waiting[address, default: []].append(continuation)
            if first { queued.append(address) }
            startFlush()
        }
    }

    private func fresh(_ entry: Known) -> Bool {
        now().timeIntervalSince(entry.at) < (entry.image == nil ? Self.noneFor : Self.knownFor)
    }

    private func startFlush() {
        guard !flushing else { return }
        flushing = true
        Task { await flush() }
    }

    /// Sends what was queued, `mostPerAsk` at a time, until nothing is.
    private func flush() async {
        try? await Task.sleep(for: Self.gather)
        while !queued.isEmpty {
            let batch = Array(queued.prefix(Self.mostPerAsk))
            queued.removeFirst(batch.count)
            await ask(batch, retriesLeft: Self.pendingRetries)
        }
        flushing = false
    }

    private func ask(_ batch: [String], retriesLeft: Int) async {
        let answers: [String: Answer]
        do { answers = try await service.lookup(batch) }
        catch {
            for address in batch { failedAt[address] = now(); settle(address, known[address]?.image) }
            return
        }
        var pending: [String] = []
        for address in batch {
            switch answers[address] {
            case .image(let id)?: known[address] = Known(image: id, at: now()); settle(address, id)
            case .none?: known[address] = Known(image: nil, at: now()); settle(address, nil)
            case .pending?: pending.append(address)
            case nil: failedAt[address] = now(); settle(address, known[address]?.image)
            }
        }
        scheduleSave()
        guard !pending.isEmpty else { return }
        guard retriesLeft > 0 else {
            for address in pending { failedAt[address] = now(); settle(address, known[address]?.image) }
            return
        }
        // Still being found: asked again shortly, without holding up the next batch.
        Task {
            try? await Task.sleep(for: self.pendingDelay)
            await self.ask(pending, retriesLeft: retriesLeft - 1)
        }
    }

    private func settle(_ address: String, _ id: String?) {
        for continuation in waiting.removeValue(forKey: address) ?? [] { continuation.resume(returning: id) }
    }

    // MARK: - The bytes, on disk

    func data(for id: String) async -> Data? {
        guard id.count == 64, id.allSatisfy(\.isHexDigit) else { return nil }
        let file = directory.appendingPathComponent(id)
        if let data = try? Data(contentsOf: file) {
            try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: file.path)
            return data
        }
        if let running = downloads[id] { return await running.value }
        let service = self.service
        let task = Task<Data?, Never> { try? await service.bytes(id) }
        downloads[id] = task
        let data = await task.value
        downloads[id] = nil
        if let data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            trimDisk()
        }
        return data
    }

    /// Keeps the folder under `diskLimit`, removing the files shown longest ago.
    func trimDisk() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.filter { $0.lastPathComponent.count == 64 }.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > diskLimit else { return }
        entries.sort { $0.1 < $1.1 }
        for (url, _, size) in entries where total > diskLimit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    // MARK: - What the service said, kept

    private var indexFile: URL { directory.appendingPathComponent("index.json") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: indexFile),
              let saved = try? JSONDecoder().decode([String: Known].self, from: data) else { return }
        known = saved.merging(known) { _, mine in mine }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.save()
        }
    }

    func save() {
        saveScheduled = false
        // What has gone stale is dropped rather than kept.
        let kept = known.filter { fresh($0.value) }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexFile, options: .atomic)
    }

    /// For tests: what is kept for an address.
    func knownEntry(_ address: String) -> Known? { loadIfNeeded(); return known[Self.key(address)] }
}

#endif
