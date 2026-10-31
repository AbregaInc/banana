import Foundation
import Testing
@testable import PerformanceContracts

@Test func traceparentRoundTripsAndChildrenRetainTraceIdentity() throws {
    let root = DiagnosticTraceContext()
    let decoded = try #require(DiagnosticTraceContext(traceparent: root.traceparent))
    #expect(decoded.traceID == root.traceID)
    #expect(decoded.spanID == root.spanID)

    let child = decoded.child()
    #expect(child.traceID == root.traceID)
    #expect(child.parentSpanID == root.spanID)
    #expect(child.spanID != root.spanID)
}

@Test func malformedTraceparentsAreRejected() {
    #expect(DiagnosticTraceContext(traceparent: "not-a-trace") == nil)
    #expect(DiagnosticTraceContext(
        traceparent: "00-00000000000000000000000000000000-0000000000000000-01") == nil)
    #expect(DiagnosticTraceContext(
        traceparent: "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01-extra") == nil)
}

@Test func unfinishedSpanIsRecoveredByTheNextProcess() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstProcess = UUID()
    let secondProcess = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_000)

    let first = DiagnosticJournal(
        directory: directory,
        processSessionID: firstProcess,
        now: { startedAt },
        uptime: { 10 })
    _ = first.startProcessSession()
    let span = first.startSpan("workout.capture", attributes: ["session_id": "test"])
    first.checkpoint(span, "samples_persisted", attributes: ["sample_count": "42"])

    let relaunched = DiagnosticJournal(
        directory: directory,
        processSessionID: secondProcess,
        now: { startedAt.addingTimeInterval(60) },
        uptime: { 1 })
    let recovered = relaunched.startProcessSession()

    #expect(recovered.count == 1)
    #expect(recovered.first?.span.operation == "workout.capture")
    #expect(recovered.first?.previousProcessSessionID == firstProcess)
    #expect(recovered.first?.lastCheckpoint == "samples_persisted")
    #expect(recovered.first?.attributes["sample_count"] == "42")
    #expect(relaunched.readEvents().contains {
        $0.kind == .recoveredIncomplete
            && $0.context?.traceID == span.context.traceID
            && $0.name == "previous_process_ended_without_terminal_event"
    })
}

@Test func completedSpanDoesNotBecomeAnIncident() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = Date(timeIntervalSince1970: 2_000)

    let first = DiagnosticJournal(
        directory: directory,
        processSessionID: UUID(),
        now: { clock },
        uptime: { 10 })
    _ = first.startProcessSession()
    let span = first.startSpan("voiceNote.capture")
    first.finish(span, status: .succeeded, reason: "validated_audio")

    let second = DiagnosticJournal(
        directory: directory,
        processSessionID: UUID(),
        now: { clock.addingTimeInterval(30) },
        uptime: { 1 })
    #expect(second.startProcessSession().isEmpty)
}

@Test func journalRotationStaysBoundedAndKeepsValidEvents() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = DiagnosticJournal(
        directory: directory,
        maxBytes: 2_048,
        processSessionID: UUID(),
        now: { Date(timeIntervalSince1970: 3_000) },
        uptime: { 1 })
    _ = journal.startProcessSession()

    for index in 0..<100 {
        journal.record(
            operation: "rotation.test",
            name: "event-\(index)",
            attributes: ["payload": String(repeating: "x", count: 100)])
    }

    let size = (try? FileManager.default.attributesOfItem(
        atPath: journal.journalURL.path)[.size] as? Int) ?? .max
    #expect(size <= 2_048)
    #expect(!journal.readEvents().isEmpty)
}
