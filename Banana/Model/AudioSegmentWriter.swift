import AVFoundation

enum AudioSegmentWriter {
    /// Copy a time range into its own file, downmixed to 16k mono — what speech models want, and
    /// far smaller than 44.1k stereo float.
    static func write(from source: URL, startSeconds: Double, seconds: Double, to url: URL) throws {
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: url)
        let input = try AVAudioFile(forReading: source)
        let inFormat = input.processingFormat

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = try AVAudioFile(forWriting: url, settings: settings)

        // Convert to the file's PROCESSING format, not its on-disk format. `write(from:)` demands
        // Float32 non-interleaved buffers and encodes to 16-bit itself; handing it an Int16 buffer
        // throws an ObjC exception and kills the process.
        let outFormat = output.processingFormat
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "TranscriptionService", code: 1)
        }

        input.framePosition = AVAudioFramePosition(startSeconds * inFormat.sampleRate)
        var remaining = min(AVAudioFramePosition(seconds * inFormat.sampleRate),
                            input.length - input.framePosition)
        let step: AVAudioFrameCount = 16_384

        while remaining > 0 {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(step), remaining))
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { break }
            try input.read(into: inBuf, frameCount: frames)
            if inBuf.frameLength == 0 { break }
            remaining -= AVAudioFramePosition(inBuf.frameLength)

            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { break }
            var error: NSError?
            var supplied = false
            converter.convert(to: outBuf, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            if outBuf.frameLength > 0 { try output.write(from: outBuf) }
        }
    }
}
