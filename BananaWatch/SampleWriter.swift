import Foundation
import Compression

/// Streams recorded samples to a file on disk during a workout so memory stays
/// flat regardless of session length (25 Hz motion produces a lot of samples).
/// Output is the compact **binary** record format (33 B/sample vs ~80 for JSON);
/// on finish it's LZFSE-compressed for a small, fast, low-power transfer to the
/// phone. Timestamps are captured at append time so they reflect the sensor firing.
final class SampleWriter {
    let url: URL
    private let handle: FileHandle
    private let start: Date
    private let queue = DispatchQueue(label: "com.boris.banana.samplewriter")
    private var closed = false
    private var _count = 0

    init?(sessionID: UUID, start: Date, resuming: Bool = false, directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        url = dir.appendingPathComponent("session-\(sessionID.uuidString).bin")

        // Recovery must append, never recreate (and truncate) the earlier recording.
        if resuming {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        } else {
            guard !FileManager.default.fileExists(atPath: url.path),
                  FileManager.default.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        if resuming {
            do {
                let bytes = try h.seekToEnd()
                let completeBytes = bytes - bytes % UInt64(FitnessSample.recordSize)
                // A partially written final record is not decodable; every complete record stays.
                if completeBytes != bytes { try h.truncate(atOffset: completeBytes) }
                try h.seek(toOffset: completeBytes)
                _count = Int(completeBytes / UInt64(FitnessSample.recordSize))
            } catch {
                try? h.close()
                return nil
            }
        }
        handle = h
        self.start = start
    }

    /// Samples buffered in memory, flushed in batches.
    ///
    /// Device motion runs at 25 Hz and appends TWO samples per callback, so this is called ~50×/sec
    /// for the whole workout. Writing each 33-byte sample straight to the FileHandle meant ~180,000
    /// syscalls per hour on a watch, on battery, keeping the storage controller out of idle.
    private var buffer = Data()
    private static let flushThreshold = 8 * 1024   // ~248 samples

    /// Timestamp captured here (accurate to the sensor callback); the encode +
    /// write happens on a serial queue off the caller's thread.
    func append(_ kind: FitnessSample.Kind, v1: Double, v2: Double? = nil, v3: Double? = nil) {
        let sample = FitnessSample(t: Date().timeIntervalSince(start), kind: kind, v1: v1, v2: v2, v3: v3)
        queue.async { [self] in
            guard !closed else { return }
            FitnessSample.appendBinary(sample, to: &buffer)   // 33 bytes, no temporary Array/Data
            _count += 1
            if buffer.count >= Self.flushThreshold { flushLocked() }
        }
    }

    /// Must be called on `queue`.
    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            flushLocked()          // don't lose the tail of the workout
            try? handle.close()
            closed = true
        }
    }

    /// Chunk size for streaming compression: keeps peak memory flat (a few KB)
    /// regardless of session length, instead of holding the whole raw file and
    /// its compressed copy in memory at once at the moment a workout ends.
    private static let compressChunkSize = 64 * 1024

    /// LZFSE-compress the raw binary into a sibling file for transfer, and delete the
    /// raw. Returns the compressed URL (or the raw as a fallback). Call after `close()`.
    ///
    /// Streams the raw file through `Compression.OutputFilter` in fixed-size chunks
    /// rather than loading the whole raw file (and a whole second compressed copy)
    /// into memory at once — a multi-hour workout's raw `.bin` can be tens of MB.
    /// The output is the same single LZFSE stream the phone already decompresses
    /// via `NSData.decompressed(using:)`, just produced incrementally.
    ///
    /// The compressed output is written to a temporary sibling and only moved to
    /// the real `.lz` path (and the raw deleted) on full success, so a mid-stream
    /// failure (e.g. ENOSPC) never leaves a partial file at a path anything else
    /// looks for, and never leaves an orphaned temp file behind either.
    func compressedForTransfer() -> URL? {
        queue.sync {
            guard closed, let inHandle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? inHandle.close() }

            let out = url.deletingPathExtension().appendingPathExtension("lz")
            let tempURL = out.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: tempURL)   // stale leftover from a prior failed attempt

            guard FileManager.default.createFile(atPath: tempURL.path, contents: nil),
                  let outHandle = try? FileHandle(forWritingTo: tempURL) else {
                try? FileManager.default.removeItem(at: tempURL)
                return url
            }

            var streamError: Error?
            guard let filter = try? OutputFilter(.compress, using: .lzfse, writingTo: { chunk in
                guard let chunk, !chunk.isEmpty else { return }
                do {
                    try outHandle.write(contentsOf: chunk)
                } catch {
                    streamError = error
                }
            }) else {
                try? outHandle.close()
                try? FileManager.default.removeItem(at: tempURL)
                return url
            }

            do {
                while streamError == nil {
                    guard let chunk = try inHandle.read(upToCount: Self.compressChunkSize), !chunk.isEmpty else { break }
                    try filter.write(chunk)
                }
                if streamError == nil { try filter.finalize() }
            } catch {
                streamError = error
            }
            try? outHandle.close()

            guard streamError == nil else {
                try? FileManager.default.removeItem(at: tempURL)
                return url
            }

            try? FileManager.default.removeItem(at: out)   // match the old .atomic write's implicit overwrite
            guard (try? FileManager.default.moveItem(at: tempURL, to: out)) != nil else {
                try? FileManager.default.removeItem(at: tempURL)
                return url
            }
            try? FileManager.default.removeItem(at: url)
            return out
        }
    }

    /// Total samples written (safe to read after `close()`).
    var count: Int { queue.sync { _count } }
}
