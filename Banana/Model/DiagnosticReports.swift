import Foundation
import MetricKit

/// Crash, hang and performance reports from MetricKit, sent to the Banana service with nothing that
/// says whose they are (docs/design/DIAGNOSTICS.md). Apple shares these with developers only for
/// people who opted in to it; this copy sends reports only after Share usage is enabled,
/// on the iPhone, iPad and Mac alike. The journal's own reading of them stays in `Metrics` (iOS).
///
/// Reports wait in a small outbox file until the service has them, so one that arrives offline,
/// or the moment before a crash, still goes on a later launch.
@MainActor
final class DiagnosticReports: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticReports()
    private var started = false
    private var sending = false

    static func start() {
        guard !shared.started else { return }
        shared.started = true
        MXMetricManager.shared.add(shared)
        shared.send()
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap(Self.reports(from:))
        Task { @MainActor in self.add(reports) }
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let reports = payloads.map { Report(kind: "metrics", signature: nil, payload: $0.jsonRepresentation()) }
        Task { @MainActor in self.add(reports) }
    }

    /// One report as it waits and is sent: MetricKit's own JSON for one diagnostic or one day.
    struct Report: Codable, Equatable {
        var kind: String
        var signature: String?
        var payload: Data
    }

    nonisolated static func reports(from payload: MXDiagnosticPayload) -> [Report] {
        var out: [Report] = []
        for d in payload.crashDiagnostics ?? [] {
            let signature = [d.exceptionType.map { "type \($0)" }, d.signal.map { "signal \($0)" },
                             d.exceptionCode.map { "code \($0)" }, d.terminationReason]
                .compactMap { $0 }.joined(separator: " · ")
            out.append(Report(kind: "crash", signature: signature.isEmpty ? nil : String(signature.prefix(200)),
                              payload: d.jsonRepresentation()))
        }
        for d in payload.hangDiagnostics ?? [] {
            out.append(Report(kind: "hang", signature: nil, payload: d.jsonRepresentation()))
        }
        for d in payload.cpuExceptionDiagnostics ?? [] {
            out.append(Report(kind: "cpu", signature: nil, payload: d.jsonRepresentation()))
        }
        for d in payload.diskWriteExceptionDiagnostics ?? [] {
            out.append(Report(kind: "disk", signature: nil, payload: d.jsonRepresentation()))
        }
        return out
    }

    // MARK: - The outbox

    /// At most this many wait: a crash loop writes one per launch, and the oldest matter least.
    nonisolated static let mostWaiting = 20
    /// MetricKit's JSON larger than this is dropped (the service takes 64 KB).
    nonisolated static let mostPayload = 60_000

    private var outbox: URL { AppSupport.directory.appendingPathComponent("diagnostics-outbox.json") }

    private func waiting() -> [Report] {
        (try? Data(contentsOf: outbox)).flatMap { try? JSONDecoder().decode([Report].self, from: $0) } ?? []
    }

    private func keep(_ reports: [Report]) {
        if reports.isEmpty { try? FileManager.default.removeItem(at: outbox); return }
        if let data = try? JSONEncoder().encode(reports) { try? data.write(to: outbox, options: .atomic) }
    }

    private func add(_ reports: [Report]) {
        guard Telemetry.shared.enabled else { return }
        keep(Self.trimmed(waiting() + reports))
        send()
    }

    nonisolated static func trimmed(_ reports: [Report]) -> [Report] {
        Array(reports.filter { $0.payload.count <= mostPayload }.suffix(mostWaiting))
    }

    /// Sends what waits, ten at a time, if this copy shares usage; forgets what the service took.
    func send() {
        guard Telemetry.shared.enabled, !sending, let host = BananaService.host else { return }
        let batch = Array(waiting().prefix(10))
        guard !batch.isEmpty, let body = Self.body(batch, platform: Telemetry.platform, channel: Telemetry.channel,
                                                   version: Telemetry.version, os: Self.osVersion) else { return }
        // Never with the account's session: nothing ties a report to a person.
        let request = BananaService.request(.diagnostics(body), host: host, session: nil)
        sending = true
        Task {
            let status = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            sending = false
            // Taken (204), or refused as not ours (400, 413): either way it shouldn't be sent again.
            guard let status, [204, 400, 413].contains(status) else { return }
            var left = waiting()
            for report in batch { if let i = left.firstIndex(of: report) { left.remove(at: i) } }
            keep(left)
            if status == 204, !left.isEmpty { send() }
        }
    }

    /// Turned off: what's waiting is thrown away.
    func turnedOff() { keep([]) }

    /// The batch the service takes: which build, and each report's own JSON.
    nonisolated static func body(_ reports: [Report], platform: String, channel: String, version: String, os: String) -> Data? {
        let items: [[String: Any]] = reports.compactMap { report in
            guard let payload = try? JSONSerialization.jsonObject(with: report.payload) as? [String: Any] else { return nil }
            var item: [String: Any] = ["kind": report.kind, "payload": payload]
            if let signature = report.signature { item["signature"] = signature }
            return item
        }
        guard !items.isEmpty else { return nil }
        let batch: [String: Any] = ["platform": platform, "channel": channel, "version": version, "os": os, "reports": items]
        return try? JSONSerialization.data(withJSONObject: batch, options: [.sortedKeys])
    }

    nonisolated static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
