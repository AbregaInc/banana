#if os(iOS)
import Foundation
import MetricKit

/// MetricKit → the playback journal.
///
/// The background-CPU kills that stopped playback were diagnosed by hand: pull crash reports over
/// devicectl, read the `cpu_resource_fatal` .ips, correlate with playback.log. MetricKit delivers
/// the same evidence to the app itself — daily CPU/battery rollups and, critically, diagnostic
/// payloads for CPU-exception kills, hangs, and crashes. Writing them into the journal means the
/// day after a bad ride, the log *leads* with the verdict instead of hiding it in Settings.
///
/// Registration is cheap (one subscriber object); payloads arrive at most daily (metrics) or on
/// next launch after an incident (diagnostics). This is the cheapest wattage instrument we have.
final class Metrics: NSObject, MXMetricManagerSubscriber {
    static let shared = Metrics()

    static func start() {
        MXMetricManager.shared.add(shared)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            var parts: [String] = []
            if let cpu = payload.cpuMetrics {
                parts.append("cpu=\(Int(cpu.cumulativeCPUTime.converted(to: .seconds).value))s")
            }
            if let exits = payload.applicationExitMetrics {
                let bg = exits.backgroundExitData
                // The kill counter. Anything non-zero here is the exact event that stops playback.
                if bg.cumulativeCPUResourceLimitExitCount > 0 {
                    parts.append("⚠️ CPU-LIMIT KILLS=\(bg.cumulativeCPUResourceLimitExitCount)")
                    DiagnosticJournal.shared.record(
                        operation: "process.diagnostic",
                        name: "background_cpu_limit_exit",
                        attributes: [
                            "count": String(bg.cumulativeCPUResourceLimitExitCount),
                            "payload_end": payload.timeStampEnd.ISO8601Format(),
                        ])
                }
                if bg.cumulativeMemoryResourceLimitExitCount > 0 {
                    parts.append("mem-limit kills=\(bg.cumulativeMemoryResourceLimitExitCount)")
                    DiagnosticJournal.shared.record(
                        operation: "process.diagnostic",
                        name: "background_memory_limit_exit",
                        attributes: [
                            "count": String(bg.cumulativeMemoryResourceLimitExitCount),
                            "payload_end": payload.timeStampEnd.ISO8601Format(),
                        ])
                }
                if bg.cumulativeSuspendedWithLockedFileExitCount > 0 {
                    parts.append("locked-file exits=\(bg.cumulativeSuspendedWithLockedFileExitCount)")
                }
            }
            let day = payload.timeStampEnd.formatted(.dateTime.month().day())
            PlaybackDiagnostics.shared.log("📊 MetricKit \(day)",
                                           parts.isEmpty ? "no notable metrics" : parts.joined(separator: " "))
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for d in payload.cpuExceptionDiagnostics ?? [] {
                PlaybackDiagnostics.shared.log(
                    "📊 CPU EXCEPTION (the background-kill class)",
                    "cpuTime=\(Int(d.totalCPUTime.converted(to: .seconds).value))s over \(Int(d.totalSampledTime.converted(to: .seconds).value))s sampled")
                DiagnosticJournal.shared.record(
                    operation: "process.diagnostic",
                    name: "cpu_exception",
                    attributes: [
                        "cpu_seconds": String(Int(d.totalCPUTime.converted(to: .seconds).value)),
                        "sampled_seconds": String(Int(d.totalSampledTime.converted(to: .seconds).value)),
                    ])
            }
            for d in payload.hangDiagnostics ?? [] {
                PlaybackDiagnostics.shared.log(
                    "📊 HANG diagnostic",
                    "mainThread blocked \(Int(d.hangDuration.converted(to: .milliseconds).value))ms")
                DiagnosticJournal.shared.record(
                    operation: "process.diagnostic",
                    name: "main_thread_hang",
                    attributes: [
                        "duration_ms": String(Int(d.hangDuration.converted(to: .milliseconds).value)),
                    ])
            }
            for d in payload.crashDiagnostics ?? [] {
                // Every field we can get: "reason unknown" (07-15) left a real crash undiagnosable.
                var parts: [String] = []
                if let r = d.terminationReason { parts.append(r) }
                if let e = d.exceptionType { parts.append("exceptionType=\(e)") }
                if let s = d.signal { parts.append("signal=\(s)") }
                if let c = d.exceptionCode { parts.append("code=\(c)") }
                // The call stack, which is the only field that says WHERE. Without it a crash
                // report gives a signal number and a timestamp and leaves you correlating against
                // the playback log to guess at the frame — which is exactly how the skip-recheck
                // seek storm stayed invisible through several crashes. Written to its own file per
                // crash rather than inlined: the tree is tens of KB and would swamp both journals.
                if let tree = d.callStackTree.jsonRepresentation() as Data? {
                    let name = "crash-\(Int(Date().timeIntervalSince1970)).json"
                    let url = AppSupport.directory.appendingPathComponent(name)
                    try? tree.write(to: url, options: .atomic)
                    parts.append("stack=\(name)")
                    Self.pruneCrashStacks()
                }
                PlaybackDiagnostics.shared.log(
                    "📊 CRASH diagnostic",
                    parts.isEmpty ? "reason unknown" : parts.joined(separator: " "))
                DiagnosticJournal.shared.record(
                    operation: "process.diagnostic",
                    name: "crash",
                    attributes: [
                        "termination_reason": d.terminationReason ?? "unknown",
                        "exception_type": d.exceptionType
                            .map { String(describing: $0) } ?? "unknown",
                        "signal": d.signal
                            .map { String(describing: $0) } ?? "unknown",
                        "exception_code": d.exceptionCode
                            .map { String(describing: $0) } ?? "unknown",
                    ])
            }
        }
    }

    /// Keep the newest few crash stacks and drop the rest. A crash loop could otherwise write one
    /// file per relaunch, and this directory holds the app's real data.
    private static func pruneCrashStacks(keeping limit: Int = 5) {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(at: AppSupport.directory,
                                                    includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let stacks = all.filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
        for stale in stacks.dropFirst(limit) { try? fm.removeItem(at: stale) }
    }
}
#endif
