import Foundation
@preconcurrency import AVFoundation

/// Re-encodes a podcast episode to low-bitrate mono AAC for the Apple Watch copy,
/// shrinking the phone→watch transfer and watch storage. Speech is fine at 32–48 kbps.
enum AudioTranscoder {
    /// AVFoundation's reader/writer pipeline is deliberately confined to one serial queue, but
    /// the framework types have not adopted `Sendable`. Keeping the whole pipeline in one
    /// unchecked box documents that confinement and prevents individual non-Sendable objects
    /// from escaping into the callback closure.
    private final class Transfer: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let readerOutput: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput

        init(
            reader: AVAssetReader,
            writer: AVAssetWriter,
            readerOutput: AVAssetReaderTrackOutput,
            writerInput: AVAssetWriterInput
        ) {
            self.reader = reader
            self.writer = writer
            self.readerOutput = readerOutput
            self.writerInput = writerInput
        }
    }

    /// Transcode `input` to `output` (.m4a, mono AAC at `bitrate`). Returns true on success.
    static func transcode(_ input: URL, to output: URL, bitrate: Int, sampleRate: Double) async -> Bool {
        let asset = AVURLAsset(url: input)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return false }
        try? FileManager.default.removeItem(at: output)

        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(outputURL: output, fileType: .m4a) else { return false }

        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(readerOutput) else { return false }
        reader.add(readerOutput)

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,           // mono
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: bitrate,
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { return false }
        writer.add(writerInput)

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let transfer = Transfer(
            reader: reader,
            writer: writer,
            readerOutput: readerOutput,
            writerInput: writerInput)
        let queue = DispatchQueue(label: "com.boris.banana.transcode")
        return await withCheckedContinuation { continuation in
            transfer.writerInput.requestMediaDataWhenReady(on: queue) {
                while transfer.writerInput.isReadyForMoreMediaData {
                    if let buffer = transfer.readerOutput.copyNextSampleBuffer() {
                        if !transfer.writerInput.append(buffer) {
                            transfer.reader.cancelReading()
                            transfer.writer.cancelWriting()
                            continuation.resume(returning: false)
                            return
                        }
                    } else {
                        transfer.writerInput.markAsFinished()
                        transfer.writer.finishWriting {
                            continuation.resume(returning:
                                transfer.writer.status == .completed
                                && transfer.reader.status == .completed)
                        }
                        return
                    }
                }
            }
        }
    }
}
