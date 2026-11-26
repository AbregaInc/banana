import AVFoundation
import XCTest

final class TranscriptionCancellationTests: XCTestCase {
    private actor Workers {
        var active = 0
        var peak = 0
        func enter() { active += 1; peak = max(peak, active) }
        func leave() { active -= 1 }
    }

    func testOverlappingJobsUseOneModelAndCancelledWaitersNeverStartIt() async throws {
        let slot = TranscriptionSlot()
        let workers = Workers()
        let (entered, started) = AsyncStream<Void>.makeStream()
        let (hold, release) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await slot.perform {
                await workers.enter()
                started.yield(())
                for await _ in hold { break }
                await workers.leave()
            }
        }
        for await _ in entered { break }
        let waiting = Task {
            try await slot.perform { XCTFail("Cancelled job entered the model") }
        }
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancellation was lost") } catch is CancellationError {}
        let others = (0..<4).map { _ in
            Task {
                try await slot.perform {
                    await workers.enter()
                    try await Task.sleep(for: .milliseconds(10))
                    await workers.leave()
                }
            }
        }
        release.yield(())
        try await first.value
        for job in others { try await job.value }
        let peak = await workers.peak
        XCTAssertEqual(peak, 1)
    }

    func testCancelledDecodeDoesNoFileWorkAndTheAudioCanBeRetried() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("input.caf")
        let destination = folder.appendingPathComponent("output.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = buffer.frameCapacity
            for _ in 0..<60 { try file.write(from: buffer) }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try AudioSegmentWriter.write(from: source, startSeconds: 0, seconds: 60, to: destination)
        }
        do { try await cancelled.value; XCTFail("Expired work decoded audio") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try AudioSegmentWriter.write(from: source, startSeconds: 0, seconds: 60, to: destination)
        XCTAssertEqual(try AVAudioFile(forReading: destination).length, 960_000)
    }
}
