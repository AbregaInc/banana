import Foundation

/// Where problem reports wait until the service has them: one file per report in a folder of
/// Application Support, so a report made offline, or the moment before a crash, still goes on a
/// later launch. An actor: nothing here runs on the main thread.
///
/// Bounded: at most `mostWaiting` reports and `mostBytes` in all. When it is full the oldest
/// automatic report makes room first; a person's own report is the last to go.
actor ProblemReportOutbox {
    /// Sends one request and says what the service answered; nil when it couldn't be reached.
    typealias Transport = @Sendable (URLRequest) async -> Int?

    static let mostWaiting = 30
    static let mostBytes = 40 * 1024 * 1024

    let folder: URL
    private let allowanceURL: URL
    private var allowance: ProblemReportAllowance
    private var sending = false
    /// After a failure the next try waits; a new report or the app coming forward tries again sooner.
    private var retryAfter: Date = .distantPast
    private var failures = 0

    init(folder: URL) {
        self.folder = folder
        allowanceURL = folder.appendingPathComponent("allowance.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        allowance = (try? Data(contentsOf: allowanceURL)).flatMap { try? JSONDecoder().decode(ProblemReportAllowance.self, from: $0) } ?? ProblemReportAllowance()
    }

    // MARK: - Allowance

    /// Whether one more automatic report of this kind may go today. Counted when it may.
    func allow(_ key: String, now: Date = Date(), limit: Int = ProblemReportAllowance.perDay) -> Bool {
        let allowed = allowance.take(key, now: now, limit: limit)
        if allowed, let data = try? JSONEncoder().encode(allowance) { try? data.write(to: allowanceURL, options: .atomic) }
        return allowed
    }

    // MARK: - Waiting

    private struct Waiting: Codable {
        var report: ProblemReport
        var device: ProblemReport.Device
    }

    private func file(_ id: String) -> URL { folder.appendingPathComponent("report-\(id).json") }

    /// The waiting reports' files, oldest first.
    private func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])) ?? []
        return names.filter { $0.lastPathComponent.hasPrefix("report-") && $0.pathExtension == "json" }
            .sorted { (created($0), $0.lastPathComponent) < (created($1), $1.lastPathComponent) }
    }

    private func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func load(_ url: URL) -> Waiting? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Waiting.self, from: $0) }
    }

    /// The ids waiting, oldest first.
    func waiting() -> [String] {
        files().compactMap { load($0)?.report.id }
    }

    /// Keeps a report until the service has it, making room if the outbox is full.
    func add(_ report: ProblemReport, device: ProblemReport.Device) {
        guard let data = try? JSONEncoder().encode(Waiting(report: report, device: device)) else { return }
        try? data.write(to: file(report.id), options: .atomic)
        trim()
        retryAfter = .distantPast
    }

    /// Over the bound: automatic reports go first, oldest first, then the oldest of the rest.
    private func trim() {
        var all = files().compactMap { url -> (URL, ProblemReport.Kind, Int)? in
            guard let waiting = load(url) else { try? FileManager.default.removeItem(at: url); return nil }
            return (url, waiting.report.kind, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        func over() -> Bool { all.count > Self.mostWaiting || all.reduce(0) { $0 + $1.2 } > Self.mostBytes }
        while over(), !all.isEmpty {
            let index = all.firstIndex { $0.1 != .problem } ?? 0
            try? FileManager.default.removeItem(at: all[index].0)
            all.remove(at: index)
        }
    }

    /// Everything waiting is thrown away (Share usage turned off takes the automatic ones only).
    func discard(automaticOnly: Bool) {
        for url in files() {
            if automaticOnly, load(url)?.report.kind == .problem { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Sending

    /// Sends what waits, oldest first, and forgets what the service took or refused as not ours.
    /// Stops at the first one that couldn't go (offline, the service busy): it waits for the next
    /// try, which backs off from a minute up to an hour.
    @discardableResult
    func send(host: String, transport: @escaping Transport, now: Date = Date(), automatic: Bool) -> Task<Int, Never>? {
        guard !sending, now >= retryAfter else { return nil }
        sending = true
        return Task { await drain(host: host, transport: transport, now: now, automatic: automatic) }
    }

    private func drain(host: String, transport: Transport, now: Date, automatic: Bool) async -> Int {
        defer { sending = false }
        var sent = 0
        for url in files() {
            guard let waiting = load(url) else { try? FileManager.default.removeItem(at: url); continue }
            // Share usage off: automatic reports wait (and are thrown away when it's turned off),
            // what the person sent goes.
            if waiting.report.kind != .problem, !automatic { continue }
            guard let body = waiting.report.body(device: waiting.device) else { try? FileManager.default.removeItem(at: url); continue }
            let status = await transport(Self.request(body: body, host: host))
            switch status {
            case 204?, 200?, 400?, 413?:
                // Taken, or refused as not ours: either way it shouldn't be sent again.
                try? FileManager.default.removeItem(at: url)
                sent += 1
                failures = 0
            default:
                failures += 1
                retryAfter = now.addingTimeInterval(min(3600, 60 * pow(2, Double(failures - 1))))
                return sent
            }
        }
        return sent
    }

    /// The request for one report: anonymous, never with the account's session.
    static func request(body: Data, host: String) -> URLRequest {
        var request = BananaService.request(.problemReport(body), host: host, session: nil)
        request.timeoutInterval = 60
        return request
    }
}
