import Foundation
import os
import os.signpost
#if canImport(Darwin)
import Darwin
#endif

/// The portable part of an OpenTelemetry/W3C trace context.
///
/// Banana does not need a tracing backend to benefit from the standard model. These identifiers
/// are small enough to travel in WatchConnectivity metadata, iCloud records, and local peer
/// messages, allowing work performed by several devices to be reconstructed as one trace.
public struct DiagnosticTraceContext: Codable, Equatable, Hashable, Sendable {
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let traceFlags: String

    public init() {
        traceID = Self.randomHex(length: 32)
        spanID = Self.randomHex(length: 16)
        parentSpanID = nil
        traceFlags = "01"
    }

    private init(traceID: String, spanID: String, parentSpanID: String?, traceFlags: String) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.traceFlags = traceFlags
    }

    /// W3C `traceparent`: version-trace-id-parent-id-flags.
    public var traceparent: String {
        "00-\(traceID)-\(spanID)-\(traceFlags)"
    }

    public init?(traceparent: String) {
        let fields = traceparent.lowercased().split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 4,
              fields[0] == "00",
              Self.isValidHex(String(fields[1]), length: 32, rejectingAllZero: true),
              Self.isValidHex(String(fields[2]), length: 16, rejectingAllZero: true),
              Self.isValidHex(String(fields[3]), length: 2, rejectingAllZero: false)
        else { return nil }
        traceID = String(fields[1])
        spanID = String(fields[2])
        parentSpanID = nil
        traceFlags = String(fields[3])
    }

    public func child() -> DiagnosticTraceContext {
        DiagnosticTraceContext(
            traceID: traceID,
            spanID: Self.randomHex(length: 16),
            parentSpanID: spanID,
            traceFlags: traceFlags)
    }

    private static func randomHex(length: Int) -> String {
        var result = ""
        result.reserveCapacity(length)
        while result.count < length {
            result += UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return String(result.prefix(length))
    }

    private static func isValidHex(
        _ value: String,
        length: Int,
        rejectingAllZero: Bool
    ) -> Bool {
        guard value.count == length,
              value.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
              })
        else { return false }
        return !rejectingAllZero || value.contains { $0 != "0" }
    }
}

public struct DiagnosticSpan: Codable, Equatable, Hashable, Sendable {
    public let operation: String
    public let context: DiagnosticTraceContext
    public let startedAt: Date

    public init(operation: String, context: DiagnosticTraceContext, startedAt: Date) {
        self.operation = operation
        self.context = context
        self.startedAt = startedAt
    }
}

public enum DiagnosticSpanStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public enum DiagnosticEventKind: String, Codable, Sendable {
    case processLaunched
    case spanStarted
    case checkpoint
    case spanEnded
    case recoveredIncomplete
    case event
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let eventID: UUID
    public let processSessionID: UUID
    public let wallTime: Date
    public let monotonicNanoseconds: UInt64
    public let platform: String
    public let operation: String
    public let kind: DiagnosticEventKind
    public let context: DiagnosticTraceContext?
    public let status: DiagnosticSpanStatus?
    public let name: String?
    public let attributes: [String: String]

    public init(
        schemaVersion: Int = Self.schemaVersion,
        eventID: UUID = UUID(),
        processSessionID: UUID,
        wallTime: Date,
        monotonicNanoseconds: UInt64,
        platform: String,
        operation: String,
        kind: DiagnosticEventKind,
        context: DiagnosticTraceContext? = nil,
        status: DiagnosticSpanStatus? = nil,
        name: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.processSessionID = processSessionID
        self.wallTime = wallTime
        self.monotonicNanoseconds = monotonicNanoseconds
        self.platform = platform
        self.operation = operation
        self.kind = kind
        self.context = context
        self.status = status
        self.name = name
        self.attributes = attributes
    }
}

public struct DiagnosticRecoveredOperation: Equatable, Sendable {
    public let span: DiagnosticSpan
    public let previousProcessSessionID: UUID
    public let lastCheckpointAt: Date
    public let lastCheckpoint: String?
    public let attributes: [String: String]
}

/// A bounded, crash-safe trace journal.
///
/// Only operation transitions and deliberately sparse checkpoints are persisted. An active-span
/// sidecar is atomically rewritten at those same points, so a process that disappears without
/// running cleanup leaves an explicit unfinished operation for the next launch. There is no timer,
/// network exporter, or per-sample logging.
public final class DiagnosticJournal: @unchecked Sendable {
    public static let shared = DiagnosticJournal()

    private struct ActiveSpanRecord: Codable {
        var span: DiagnosticSpan
        var processSessionID: UUID
        var lastCheckpointAt: Date
        var lastCheckpoint: String?
        var attributes: [String: String]
    }

    private static let logger = Logger(
        subsystem: "com.boris.banana",
        category: "diagnostics")
    private static let signpostLog = OSLog(
        subsystem: "com.boris.banana",
        category: "diagnostics")

    public let directory: URL
    public let journalURL: URL
    public let processSessionID: UUID

    private let activeURL: URL
    private let peersDirectory: URL
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var active: [String: ActiveSpanRecord] = [:]
    private var signpostIDs: [String: OSSignpostID] = [:]
    private var processStarted = false

    public convenience init() {
        self.init(directory: Self.defaultDirectory())
    }

    public init(
        directory: URL,
        maxBytes: Int = 512 * 1024,
        processSessionID: UUID = UUID(),
        now: @escaping @Sendable () -> Date = Date.init,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.directory = directory
        journalURL = directory.appendingPathComponent("events.ndjson")
        activeURL = directory.appendingPathComponent("active-spans.json")
        peersDirectory = directory.appendingPathComponent("Peers", isDirectory: true)
        self.maxBytes = max(1_024, maxBytes)
        self.processSessionID = processSessionID
        self.now = now
        self.uptime = uptime

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        prepareDirectory(directory)
        prepareDirectory(peersDirectory)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        }
        active = loadActiveRecords()
    }

    /// Records launch and converts spans left by an older process into explicit incidents.
    @discardableResult
    public func startProcessSession(
        attributes: [String: String] = [:]
    ) -> [DiagnosticRecoveredOperation] {
        lock.lock()
        defer { lock.unlock() }
        guard !processStarted else { return [] }
        processStarted = true

        let launchedAt = now()
        var recovered: [DiagnosticRecoveredOperation] = []
        let staleRecords = active.filter {
            $0.value.processSessionID != processSessionID
        }
        for (spanID, record) in staleRecords {
            recovered.append(DiagnosticRecoveredOperation(
                span: record.span,
                previousProcessSessionID: record.processSessionID,
                lastCheckpointAt: record.lastCheckpointAt,
                lastCheckpoint: record.lastCheckpoint,
                attributes: record.attributes))
            var incidentAttributes = record.attributes
            incidentAttributes["previous_process_session_id"] =
                record.processSessionID.uuidString.lowercased()
            incidentAttributes["last_checkpoint_at"] =
                Self.iso8601(record.lastCheckpointAt)
            incidentAttributes["age_seconds"] =
                String(Int(max(0, launchedAt.timeIntervalSince(record.lastCheckpointAt))))
            if let checkpoint = record.lastCheckpoint {
                incidentAttributes["last_checkpoint"] = checkpoint
            }
            emitLocked(
                operation: record.span.operation,
                kind: .recoveredIncomplete,
                context: record.span.context,
                status: .failed,
                name: "previous_process_ended_without_terminal_event",
                attributes: resourceEnriched(incidentAttributes),
                at: launchedAt)
            active[spanID] = nil
        }
        saveActiveRecordsLocked()
        emitLocked(
            operation: "process",
            kind: .processLaunched,
            name: "launch",
            attributes: resourceEnriched(attributes),
            at: launchedAt)
        return recovered.sorted { $0.lastCheckpointAt < $1.lastCheckpointAt }
    }

    @discardableResult
    public func startSpan(
        _ operation: String,
        parent: DiagnosticTraceContext? = nil,
        attributes: [String: String] = [:]
    ) -> DiagnosticSpan {
        let at = now()
        let context = parent?.child() ?? DiagnosticTraceContext()
        let span = DiagnosticSpan(operation: operation, context: context, startedAt: at)
        let cleanAttributes = Self.sanitized(attributes)

        lock.lock()
        active[context.spanID] = ActiveSpanRecord(
            span: span,
            processSessionID: processSessionID,
            lastCheckpointAt: at,
            lastCheckpoint: "started",
            attributes: cleanAttributes)
        saveActiveRecordsLocked()
        let signpostID = OSSignpostID(log: Self.signpostLog)
        signpostIDs[context.spanID] = signpostID
        emitLocked(
            operation: operation,
            kind: .spanStarted,
            context: context,
            name: "started",
            attributes: resourceEnriched(cleanAttributes),
            at: at)
        lock.unlock()

        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "DiagnosticOperation",
            signpostID: signpostID,
            "operation=%{public}@ trace=%{public}@",
            operation as NSString,
            context.traceID as NSString)
        return span
    }

    public func checkpoint(
        _ span: DiagnosticSpan,
        _ name: String,
        attributes: [String: String] = [:]
    ) {
        let at = now()
        lock.lock()
        guard var record = active[span.context.spanID] else {
            lock.unlock()
            return
        }
        let cleanAttributes = Self.sanitized(attributes)
        record.lastCheckpointAt = at
        record.lastCheckpoint = Self.limited(name, to: 160)
        record.attributes.merge(cleanAttributes) { _, new in new }
        active[span.context.spanID] = record
        saveActiveRecordsLocked()
        let signpostID = signpostIDs[span.context.spanID]
        emitLocked(
            operation: span.operation,
            kind: .checkpoint,
            context: span.context,
            name: name,
            attributes: resourceEnriched(cleanAttributes),
            at: at)
        lock.unlock()

        if let signpostID {
            os_signpost(
                .event,
                log: Self.signpostLog,
                name: "DiagnosticCheckpoint",
                signpostID: signpostID,
                "operation=%{public}@ checkpoint=%{public}@",
                span.operation as NSString,
                name as NSString)
        }
    }

    public func finish(
        _ span: DiagnosticSpan,
        status: DiagnosticSpanStatus,
        reason: String,
        attributes: [String: String] = [:]
    ) {
        let at = now()
        var finalAttributes = Self.sanitized(attributes)
        finalAttributes["duration_ms"] =
            String(Int(max(0, at.timeIntervalSince(span.startedAt)) * 1_000))

        lock.lock()
        let existed = active.removeValue(forKey: span.context.spanID) != nil
        saveActiveRecordsLocked()
        let signpostID = signpostIDs.removeValue(forKey: span.context.spanID)
        if existed {
            emitLocked(
                operation: span.operation,
                kind: .spanEnded,
                context: span.context,
                status: status,
                name: reason,
                attributes: finalAttributes,
                at: at)
        }
        lock.unlock()

        if let signpostID {
            os_signpost(
                .end,
                log: Self.signpostLog,
                name: "DiagnosticOperation",
                signpostID: signpostID,
                "operation=%{public}@ status=%{public}@ reason=%{public}@",
                span.operation as NSString,
                status.rawValue as NSString,
                reason as NSString)
        }
    }

    /// A correlated point event that does not need crash-recovery state of its own.
    public func record(
        operation: String,
        parent: DiagnosticTraceContext? = nil,
        name: String,
        attributes: [String: String] = [:]
    ) {
        lock.lock()
        emitLocked(
            operation: operation,
            kind: .event,
            context: parent,
            name: name,
            attributes: Self.sanitized(attributes),
            at: now())
        lock.unlock()
    }

    public func readEvents() -> [DiagnosticEvent] {
        lock.lock()
        let data = (try? Data(contentsOf: journalURL)) ?? Data()
        lock.unlock()
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(DiagnosticEvent.self, from: Data($0))
        }
    }

    public func readExportText(additionalFiles: [URL] = []) -> String {
        lock.lock()
        let local = (try? String(contentsOf: journalURL, encoding: .utf8)) ?? ""
        let peers = ((try? FileManager.default.contentsOfDirectory(
            at: peersDirectory,
            includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> (String, String)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (url.lastPathComponent, text)
            }
        lock.unlock()

        var sections = ["# Banana diagnostics — local\n\(local)"]
        sections += peers.map { "# Peer diagnostics — \($0.0)\n\($0.1)" }
        sections += additionalFiles.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "# Additional log — \(url.lastPathComponent)\n\(text)"
        }
        return sections.joined(separator: "\n")
    }

    public func exportSnapshot(additionalFiles: [URL] = []) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("banana-diagnostics-\(UUID().uuidString.lowercased()).txt")
        guard let data = readExportText(additionalFiles: additionalFiles).data(using: .utf8),
              (try? data.write(to: url, options: .atomic)) != nil
        else { return nil }
        return url
    }

    /// Stores a Watch or peer-device snapshot beside the local journal, bounded by count and size.
    public func ingestPeerSnapshot(fileURL: URL, source: String) throws {
        var data = try Data(contentsOf: fileURL)
        if data.count > maxBytes {
            data = Data(data.suffix(maxBytes))
            if let newline = data.firstIndex(of: 0x0A) {
                data = Data(data[data.index(after: newline)...])
            }
        }
        let safeSource = source.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let destination = peersDirectory.appendingPathComponent(
            "\(String(safeSource))-\(Int(now().timeIntervalSince1970))-\(UUID().uuidString.lowercased()).ndjson")

        lock.lock()
        defer { lock.unlock() }
        try data.write(to: destination, options: .atomic)
        let peerFiles = ((try? FileManager.default.contentsOfDirectory(
            at: peersDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return left > right
            }
        for stale in peerFiles.dropFirst(10) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Clears historical events without erasing the recovery markers of operations in progress.
    public func clearEvents() {
        lock.lock()
        try? Data().write(to: journalURL, options: .atomic)
        for peer in (try? FileManager.default.contentsOfDirectory(
            at: peersDirectory,
            includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: peer)
        }
        lock.unlock()
    }

    public static func resourceAttributes() -> [String: String] {
        var attributes: [String: String] = [
            "thermal_state": thermalStateName(ProcessInfo.processInfo.thermalState),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled ? "true" : "false",
        ]
        if let bytes = residentMemoryBytes() {
            attributes["memory_bytes"] = String(bytes)
        }
        return attributes
    }

    private func emitLocked(
        operation: String,
        kind: DiagnosticEventKind,
        context: DiagnosticTraceContext? = nil,
        status: DiagnosticSpanStatus? = nil,
        name: String? = nil,
        attributes: [String: String],
        at: Date
    ) {
        let event = DiagnosticEvent(
            processSessionID: processSessionID,
            wallTime: at,
            monotonicNanoseconds: UInt64(max(0, uptime()) * 1_000_000_000),
            platform: Self.platformName,
            operation: Self.limited(operation, to: 120),
            kind: kind,
            context: context,
            status: status,
            name: name.map { Self.limited($0, to: 160) },
            attributes: Self.sanitized(attributes))
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        appendLocked(line)
        Self.logger.notice(
            "\(event.operation, privacy: .public) \(kind.rawValue, privacy: .public) \(event.name ?? "", privacy: .public) trace=\(context?.traceID ?? "-", privacy: .public)")
    }

    private func appendLocked(_ data: Data) {
        if let handle = try? FileHandle(forWritingTo: journalURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: journalURL)
        }
        guard let size = try? FileManager.default.attributesOfItem(
            atPath: journalURL.path)[.size] as? Int,
              size > maxBytes,
              let contents = try? Data(contentsOf: journalURL)
        else { return }
        let tail = contents.suffix(maxBytes / 2)
        let start = tail.firstIndex(of: 0x0A).map { tail.index(after: $0) } ?? tail.startIndex
        try? Data(tail[start...]).write(to: journalURL, options: .atomic)
    }

    private func loadActiveRecords() -> [String: ActiveSpanRecord] {
        guard let data = try? Data(contentsOf: activeURL),
              let records = try? decoder.decode([String: ActiveSpanRecord].self, from: data)
        else { return [:] }
        return records
    }

    private func saveActiveRecordsLocked() {
        guard let data = try? encoder.encode(active) else { return }
        try? data.write(to: activeURL, options: .atomic)
    }

    private func resourceEnriched(_ attributes: [String: String]) -> [String: String] {
        var result = Self.resourceAttributes()
        result.merge(Self.sanitized(attributes)) { _, new in new }
        return result
    }

    private func prepareDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
        #if os(iOS) || os(watchOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        #endif
    }

    private static func defaultDirectory() -> URL {
        // `.documentDirectory` is the user's protected ~/Documents on macOS. The diagnostic
        // journal starts on every launch and must never request access to a personal folder just
        // to write internal telemetry.
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let app = Bundle.main.bundleIdentifier ?? "Banana"
        return root.appendingPathComponent(app, isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private static func sanitized(_ attributes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }).prefix(40) {
            result[limited(key, to: 80)] = limited(value, to: 512)
        }
        return result
    }

    private static func limited(_ value: String, to count: Int) -> String {
        value.count <= count ? value : String(value.prefix(count))
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static var platformName: String {
        #if os(watchOS)
        "watchOS"
        #elseif os(iOS)
        "iOS"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown"
        #endif
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func residentMemoryBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
        #else
        return nil
        #endif
    }
}
