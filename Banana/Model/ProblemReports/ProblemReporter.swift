import Foundation
#if os(iOS)
import UIKit
#endif

/// Where problem reports are made and sent from (docs/design/PROBLEM-REPORTS.md).
///
/// Automatic reports (a storm, high CPU, a power or memory spike, a hang, a MetricKit diagnostic)
/// go only while Share usage is on, at most `ProblemReportAllowance.perDay` of a kind a day. A
/// person's own report (Report a problem, 👎 on an answer) goes because they pressed Send.
///
/// What fires calls in on the main actor and returns at once: the log is read, scrubbed and
/// written to the outbox on the outbox's own actor, and sent from there.
@MainActor
final class ProblemReporter {
    static let shared = ProblemReporter()

    let outbox = ProblemReportOutbox(folder: AppSupport.directory.appendingPathComponent("problem-reports", isDirectory: true))
    private var started = false

    /// Whether automatic reports go: Share usage is on in the official app.
    var automatic: Bool { Telemetry.shared.enabled }

    static func start() {
        let reporter = shared
        guard !reporter.started else { return }
        reporter.started = true
        HangDetector.shared.onHang = { seconds, stack in
            Task { @MainActor in ProblemReporter.shared.hang(seconds: seconds, stack: stack) }
        }
        HangDetector.shared.install { ProblemReporter.shared.automatic }
        DiagnosticReports.onDiagnostics = { reports in ProblemReporter.shared.metricKit(reports) }
        reporter.flush()
    }

    // MARK: - Automatic

    /// A detector fired. `numbers` are its readings; `signature` what groups like spikes.
    func spike(_ detector: ProblemReport.Detector, signature: String?, numbers: [String: ProblemReport.Value],
               stack: String? = nil, extra: [ProblemReport.Attachment] = []) {
        guard automatic else { return }
        let page = Self.page
        let device = Self.device
        let outbox = outbox
        Task.detached(priority: .utility) {
            guard await outbox.allow(detector.rawValue) else { return }
            var report = ProblemReport(kind: .spike, detector: detector, signature: signature, page: page, numbers: numbers)
            report.attachments = extra
            if let log = await Self.scrubbedLog() { report.attachments.append(log) }
            if let stack, let file = ProblemReport.Attachment.text(.stack, stack) { report.attachments.append(file) }
            await outbox.add(report, device: device)
            await MainActor.run { ProblemReporter.shared.flush() }
        }
    }

    private func hang(seconds: Double, stack: String?) {
        spike(.hang, signature: stack.flatMap(MainThreadSampler.signature(of:)),
              numbers: ["seconds": .number((seconds * 10).rounded() / 10)], stack: stack)
    }

    /// MetricKit delivered diagnostics (a day late, or at the launch after a crash): each with
    /// the log as it stands, which then holds the run that ended.
    func metricKit(_ reports: [DiagnosticReports.Report]) {
        for report in reports {
            let detector: ProblemReport.Detector
            switch report.kind {
            case "crash": detector = .metricKitCrash
            case "hang": detector = .metricKitHang
            case "cpu": detector = .metricKitCPU
            case "disk": detector = .metricKitDisk
            default: continue
            }
            let payload = ProblemReport.Attachment.Name.metricKit.most >= report.payload.count
                ? [ProblemReport.Attachment(name: .metricKit, type: "application/json", data: report.payload)] : []
            spike(detector, signature: report.signature, numbers: [:], extra: payload)
        }
    }

    // MARK: - The person's own

    /// Report a problem: sent because they pressed Send, whatever Share usage says.
    func send(_ report: ProblemReport) {
        let device = Self.device
        let outbox = outbox
        Task.detached(priority: .userInitiated) {
            var report = report
            if !report.attachments.contains(where: { $0.name == .log }), let log = await Self.scrubbedLog() {
                report.attachments.append(log)
            }
            await outbox.add(report, device: device)
            await MainActor.run { ProblemReporter.shared.flush() }
        }
    }

    /// 👍 or 👎 on an answer, as a count: nothing of the conversation goes with it.
    func rate(_ rating: ProblemReport.Rating) {
        guard automatic else { return }
        let report = ProblemReport(kind: .rating, rating: rating, page: AppSection.assistant.rawValue)
        let device = Self.device
        let outbox = outbox
        Task.detached(priority: .utility) {
            await outbox.add(report, device: device)
            await MainActor.run { ProblemReporter.shared.flush() }
        }
    }

    // MARK: - Sending

    /// Sends what waits. On launch, on coming forward and after each new report.
    func flush() {
        guard let host = BananaService.host else { return }
        let automatic = automatic
        let outbox = outbox
        Task.detached(priority: .utility) {
            await outbox.send(host: host, transport: Self.transport, automatic: automatic)
        }
    }

    /// Share usage turned off: the automatic reports waiting are thrown away.
    func turnedOff() {
        let outbox = outbox
        Task.detached(priority: .utility) { await outbox.discard(automaticOnly: true) }
    }

    nonisolated static let transport: ProblemReportOutbox.Transport = { request in
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    // MARK: - What a report says about the copy

    nonisolated static func scrubbedLog() async -> ProblemReport.Attachment? {
        let lines = ReportScrubber.scrub(lines: await PlaybackDiagnostics.shared.tail(200))
        return ProblemReport.Attachment.text(.log, lines.joined(separator: "\n"))
    }

    /// The section in front.
    static var page: String {
        #if os(macOS)
        MacNavigator.shared.section.rawValue
        #else
        ShellNavigation.shared.state.tab.rawValue
        #endif
    }

    static var device: ProblemReport.Device {
        ProblemReport.Device(platform: Telemetry.platform, channel: Telemetry.channel,
                             variant: AppVariant.current == .beta ? "beta" : "stable",
                             version: Telemetry.version, os: DiagnosticReports.osVersion, model: model)
    }

    nonisolated static var model: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #elseif os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
        #else
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }
}
