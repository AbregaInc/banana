import Foundation

/// What an episode's bytes alone can tell us: where its MP3 frames are, and where an ad server
/// spliced one recording into another.
///
/// Nothing here needs a transcript or a model, and that is not a stylistic preference. The Watch
/// has no speech framework and plays only files transferred to it, and a first streamed listen has
/// no transcript yet. A detector that needs either can never run in the two places skipping most
/// has to work, so the byte-level stages carry those cases on their own.
///
/// Ported from the measured research scanner (`scratchpad/podskip/live/seam_scan_truncated.py`,
/// with `scratchpad/podskip/seamscan/mp3header.py` for the header bit layout). That scanner is the
/// code that produced the "0 false positives across 6 shows, ~14 h; 14/14 slots correct" figure in
/// `SHIP-SPEC.md`, so its behaviour is reproduced rather than improved on: same MPEG-1 Layer III
/// restriction, same byte-at-a-time resynchronisation, same "stop when a whole frame no longer
/// fits" rule that makes a truncated stream safe to scan.
enum PodcastAudioSeams {

    // MARK: - Frame headers

    /// One MPEG-1 Layer III frame header.
    ///
    /// Only MPEG-1 Layer III is recognised. `parse_header` in the research scanner returns None
    /// for everything else, and widening the parser here would run the seam rule over an encoding
    /// class nobody measured. Every episode in the research set is MPEG-1 Layer III 128 kbit/s
    /// 44.1 kHz (one is 320 kbit/s). A file this parser cannot read yields no frames and therefore
    /// no spans, which is the failure the whole feature is allowed to have.
    struct FrameHeader: Sendable, Equatable {
        enum ChannelMode: UInt8, Sendable, Equatable {
            case stereo = 0
            case jointStereo = 1
            case dualChannel = 2
            case mono = 3
        }

        var bitrateKilobitsPerSecond: Int
        var sampleRate: Int
        var channelMode: ChannelMode
        /// The padding bit: this frame carries one extra byte so the average bitrate comes out
        /// exact even though the per-frame byte count cannot be fractional.
        var isPadded: Bool

        /// MPEG-1 Layer III bitrates in kbit/s by table index. Index 0 means "free format" (the
        /// rate is not in the stream at all) and index 15 is reserved; both are rejected rather
        /// than guessed at, because a wrong frame length desynchronises everything after it.
        static let bitrateTable = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]

        /// MPEG-1 sample rates by table index; index 3 is reserved.
        static let sampleRateTable = [44100, 48000, 32000, 0]

        static func parse(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> FrameHeader? {
            // Eleven sync bits, then version 11 (MPEG-1) and layer 01 (Layer III).
            guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }
            guard (b1 >> 3) & 0x3 == 0x3 else { return nil }
            guard (b1 >> 1) & 0x3 == 0x1 else { return nil }

            let bitrate = bitrateTable[Int((b2 >> 4) & 0xF)]
            let sampleRate = sampleRateTable[Int((b2 >> 2) & 0x3)]
            guard bitrate > 0, sampleRate > 0 else { return nil }
            guard let mode = ChannelMode(rawValue: (b3 >> 6) & 0x3) else { return nil }

            return FrameHeader(bitrateKilobitsPerSecond: bitrate,
                               sampleRate: sampleRate,
                               channelMode: mode,
                               isPadded: (b2 >> 1) & 0x1 == 1)
        }

        /// Frame length in bytes, header included. The integer division is deliberate and matches
        /// the reference implementation: the fraction it discards is exactly what the padding bit
        /// pays back over successive frames.
        var byteLength: Int {
            (144 * bitrateKilobitsPerSecond * 1000) / sampleRate + (isPadded ? 1 : 0)
        }

        /// Every MPEG-1 Layer III frame carries 1152 samples, so its duration depends only on the
        /// sample rate: 26.12 ms at 44.1 kHz. That is the "about 26 ms" the seam rule talks about
        /// — a one-frame blip, not a measured acoustic interval.
        var duration: Double { 1152.0 / Double(sampleRate) }
    }

    /// The encoder settings a frame declares. Consecutive frames are grouped by this, which is the
    /// comparison the research scanner made frame to frame.
    struct EncoderSettings: Sendable, Equatable {
        var bitrateKilobitsPerSecond: Int
        var sampleRate: Int
        var channelMode: FrameHeader.ChannelMode
    }

    /// A maximal run of consecutive frames sharing one set of encoder settings.
    struct EncoderRun: Sendable, Equatable {
        var settings: EncoderSettings
        /// Offset of the run's first frame, relative to the start of the buffer that was scanned.
        var startByteOffset: Int
        /// Seconds from the start of audio (i.e. from the end of the ID3 tag).
        var startTime: Double
        var frameCount: Int
        var duration: Double
        /// How many bytes had been skipped looking for sync when this run began. Two runs with the
        /// same value have no corrupt gap between them, so the accumulated time between them is
        /// real rather than an artefact of skipped audio.
        var resyncByteCountAtStart: Int

        var endTime: Double { startTime + duration }
    }

    // MARK: - Scanning

    /// Everything one pass over the bytes learned.
    ///
    /// Deliberately small. A 34 MB episode is roughly 82 000 frames, and holding one record per
    /// frame would cost more than the audio buffer being scanned. Only the run boundaries survive,
    /// because the seam rule is the only thing that needs frame-level structure and a seam is a run
    /// boundary by definition.
    struct FrameScan: Sendable, Equatable {

        /// Which arithmetic produced the times in this scan, so a caller can say so rather than
        /// assume. Constant bitrate makes byte offset and time interchangeable; anything else does
        /// not, and pretending otherwise is how a span ends up in the wrong place.
        enum TimingPath: String, Sendable {
            /// Every frame declared the same bitrate and sample rate. Offset ↔ time is arithmetic.
            case constantBitrate
            /// The bitrate or sample rate changed part-way through, so times are the sum of real
            /// frame durations and offsets are resolved against recorded anchors.
            case accumulatedFrameDurations
        }

        struct ByteTime: Sendable, Equatable {
            var byteOffset: Int
            var time: Double
        }

        /// Where audio begins: past any ID3v2 tag at the head of the file.
        var audioStartOffset: Int
        /// Size of the buffer handed in — which for a streamed episode is a prefix, not the file.
        var byteCount: Int
        /// Where the walk stopped. Less than `byteCount` whenever the buffer ends mid-frame.
        var scannedByteCount: Int
        var frameCount: Int
        /// End time of the last complete frame.
        var duration: Double
        var firstFrame: FrameHeader?
        var runs: [EncoderRun]
        /// Bytes skipped one at a time looking for the next sync word. Zero on every real episode
        /// in the research set, because the walk starts exactly at the end of the ID3 tag.
        var resyncByteCount: Int
        /// True when the walk stopped because the remaining bytes were less than a whole frame.
        /// The expected state for a stream still arriving, and not an error.
        var endedOnIncompleteFrame: Bool
        var timingPath: TimingPath
        /// Empty on the constant-bitrate path. On the variable path, one anchor per frame from the
        /// first frame that changed the rate onwards — frames before that point are still uniform,
        /// so they need no anchors and a whole-file index is never built for a file that does not
        /// need one.
        var byteTimeAnchors: [ByteTime]

        var isConstantBitrate: Bool { timingPath == .constantBitrate }

        /// Seconds from the start of audio for a byte offset in the scanned buffer.
        ///
        /// On the constant-bitrate path this extrapolates happily past the bytes actually scanned,
        /// which is the point: a streamed episode is scanned as a small prefix and still has to
        /// place offsets that live 30 MB further on. On the variable path it does not, and returns
        /// nil instead, because past the last anchor there is nothing but a guess.
        func seconds(atByteOffset offset: Int) -> Double? {
            guard offset >= audioStartOffset, let first = firstFrame else { return nil }
            let uniformBytesPerSecond = Double(first.bitrateKilobitsPerSecond * 1000) / 8.0
            guard uniformBytesPerSecond > 0 else { return nil }

            switch timingPath {
            case .constantBitrate:
                return Double(offset - audioStartOffset) / uniformBytesPerSecond

            case .accumulatedFrameDurations:
                guard let firstAnchor = byteTimeAnchors.first else { return nil }
                if offset < firstAnchor.byteOffset {
                    // Still inside the uniform prefix that came before the first rate change.
                    return Double(offset - audioStartOffset) / uniformBytesPerSecond
                }
                guard offset < scannedByteCount else { return nil }
                var low = 0
                var high = byteTimeAnchors.count - 1
                var best = 0
                while low <= high {
                    let mid = (low + high) / 2
                    if byteTimeAnchors[mid].byteOffset <= offset {
                        best = mid
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }
                // The start of the frame the byte falls in. Sub-frame precision would be invented:
                // a frame is the smallest thing an MP3 has a time for.
                return byteTimeAnchors[best].time
            }
        }
    }

    /// Walk the frames in `data`, which may be a prefix of an episode rather than a whole file.
    ///
    /// Safe on a truncated stream by construction: a frame is only counted once its whole length
    /// is present, and no read ever goes past `data.count`.
    static func scan(_ data: Data) -> FrameScan {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in scan(raw) }
    }

    private static func scan(_ bytes: UnsafeRawBufferPointer) -> FrameScan {
        let count = bytes.count
        let audioStart = audioStartOffset(bytes)

        var position = audioStart
        var time = 0.0
        var frameCount = 0
        var resyncByteCount = 0
        var runs: [EncoderRun] = []
        var firstFrame: FrameHeader?
        var isUniform = true
        var anchors: [FrameScan.ByteTime] = []
        var endedOnIncompleteFrame = false

        while position + 4 <= count {
            guard let header = FrameHeader.parse(bytes[position],
                                                 bytes[position + 1],
                                                 bytes[position + 2],
                                                 bytes[position + 3]) else {
                // No sync here. Slide one byte, exactly as the reference scanner does.
                position += 1
                resyncByteCount += 1
                continue
            }
            let length = header.byteLength
            guard length > 4 else {
                position += 1
                resyncByteCount += 1
                continue
            }
            if position + length > count {
                // The buffer ends mid-frame. Expected on a stream still arriving; never read on.
                endedOnIncompleteFrame = true
                break
            }

            if let first = firstFrame {
                if header.bitrateKilobitsPerSecond != first.bitrateKilobitsPerSecond
                    || header.sampleRate != first.sampleRate {
                    isUniform = false
                }
            } else {
                firstFrame = header
            }
            if !isUniform {
                anchors.append(FrameScan.ByteTime(byteOffset: position, time: time))
            }

            let settings = EncoderSettings(bitrateKilobitsPerSecond: header.bitrateKilobitsPerSecond,
                                           sampleRate: header.sampleRate,
                                           channelMode: header.channelMode)
            if var current = runs.last, current.settings == settings {
                current.frameCount += 1
                current.duration += header.duration
                runs[runs.count - 1] = current
            } else {
                runs.append(EncoderRun(settings: settings,
                                       startByteOffset: position,
                                       startTime: time,
                                       frameCount: 1,
                                       duration: header.duration,
                                       resyncByteCountAtStart: resyncByteCount))
            }

            frameCount += 1
            time += header.duration
            position += length
        }

        return FrameScan(audioStartOffset: audioStart,
                         byteCount: count,
                         scannedByteCount: position,
                         frameCount: frameCount,
                         duration: time,
                         firstFrame: firstFrame,
                         runs: runs,
                         resyncByteCount: resyncByteCount,
                         endedOnIncompleteFrame: endedOnIncompleteFrame,
                         timingPath: isUniform ? .constantBitrate : .accumulatedFrameDurations,
                         byteTimeAnchors: isUniform ? [] : anchors)
    }

    /// Where audio starts: past an ID3v2 tag if there is one, otherwise at zero.
    ///
    /// The size field is four synchsafe bytes (seven bits each, so the tag length can never
    /// contain a false sync word). A tag claiming to run past the buffer is clamped rather than
    /// trusted, which on a short prefix simply means no frames are found.
    private static func audioStartOffset(_ bytes: UnsafeRawBufferPointer) -> Int {
        let count = bytes.count
        guard count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return 0 }
        var size = 0
        for index in 6..<10 { size = (size << 7) | Int(bytes[index] & 0x7F) }
        let footer = (bytes[5] & 0x10) != 0 ? 10 : 0
        return min(10 + size + footer, count)
    }

    // MARK: - The encoder-seam rule

    /// Nominal length of a stitched advertising slot.
    ///
    /// Measured, not assumed, and measured twice by methods that share no code. Walking the frames
    /// of the research captures gives slots of 1151 or 1153 frames of 1152 samples at 44.1 kHz;
    /// converting the ad server's own declared byte ranges gives the same two numbers to four
    /// decimal places. 1152 frames is 30.0913 s, the 30.09 s `SHIP-SPEC.md` records.
    ///
    /// The ±1 frame spread is a real difference in slot length — the server declares slots that
    /// are genuinely 1151 and 1153 frames long — not clock error between the two methods, which
    /// agree to well under a millisecond. It is also independent of bitrate: a 320 kbit/s episode
    /// in the same set has slots of the same 1151 and 1153 frames, because frame duration depends
    /// only on the sample rate.
    static let standardSpotSeconds = 30.09

    /// How far from `standardSpotSeconds` a block may sit and still be called a spot.
    ///
    /// 0.03 s, from `SHIP-SPEC.md` ("30.09 s within 0.03"). One frame at 44.1 kHz is 0.0261 s, so
    /// this admits the ±1 frame that slots genuinely vary by and almost nothing else. It is a
    /// bound on real slot lengths, not slack bought to absorb a measurement artefact; there is no
    /// artefact left to absorb. Widening it would start admitting blocks nobody measured, and the
    /// whole stage exists because this pairing scored no false positives.
    static let spotToleranceSeconds = 0.03

    /// How long the mode blip at a seam may be and still count as "brief".
    ///
    /// `SHIP-SPEC.md` says the change "reverts within a frame or two". Every seam in the research
    /// captures is exactly one frame — a single stereo frame between two joint-stereo runs, 26 ms
    /// — so two frames is the stated ceiling rather than an observed one.
    static let maximumSeamMarkerFrames = 2

    /// How far into an episode the seam rule has to be able to look.
    ///
    /// `SHIP-SPEC.md`: every seam measured sat in the first 82 seconds, and no show in the library
    /// showed a later one. Mid-roll insertion is explicitly out of scope for v1 for want of any
    /// measured example, so this is the window the evidence covers plus a little room, not a claim
    /// that no ad exists later.
    static let seamSearchSeconds = 90.0

    /// How many bytes of an episode have to be in hand before the seam rule can see everything it
    /// was measured seeing.
    ///
    /// A function of bitrate, never a constant. Two episodes of the same show in the research set
    /// are 128 and 320 kbit/s, so a byte count that covers 90 seconds of one covers 36 of the
    /// other. The ID3 tag has to be added on top for the same reason — measured tags in the set
    /// run from 220 bytes to 317 628, so there is no safe upper bound to fold into a constant. A
    /// caller with no headers can read both from a small first read: the tag length from its own
    /// bytes, the bitrate from the first frame after it.
    static func minimumPrefixByteCount(bitsPerSecond: Int,
                                       audioStartByte: Int,
                                       seconds: Double = PodcastAudioSeams.seamSearchSeconds) -> Int {
        guard bitsPerSecond > 0, seconds > 0 else { return max(0, audioStartByte) }
        let bytesPerSecond = Double(bitsPerSecond) / 8.0
        // One spot of slack past the window: the closing marker of a block is what makes the block
        // a span, and a prefix that stops one frame short of it produces nothing at all.
        let slack = bytesPerSecond * standardSpotSeconds
        return max(0, audioStartByte) + Int((bytesPerSecond * seconds + slack).rounded(.up))
    }

    /// The same sizing, taken from a scan of a first small read rather than from declared headers.
    /// Nil when that read was too short to contain a whole frame, which is the caller's signal to
    /// fetch more before trying to size anything.
    static func minimumPrefixByteCount(for scan: FrameScan,
                                       seconds: Double = PodcastAudioSeams.seamSearchSeconds) -> Int? {
        guard let first = scan.firstFrame else { return nil }
        return minimumPrefixByteCount(bitsPerSecond: first.bitrateKilobitsPerSecond * 1000,
                                      audioStartByte: scan.audioStartOffset,
                                      seconds: seconds)
    }

    /// A brief encoder-mode change that reverted: the join between two separately encoded pieces
    /// of audio, visible in the frame headers because the encoder settled differently for a frame.
    struct SeamMarker: Sendable, Equatable {
        /// Offset of the marker's first frame. The marker frame belongs to the block that follows
        /// it, which is how the ad server's own byte ranges are laid out: a declared slot begins
        /// at the marker and ends one byte before the next.
        var byteOffset: Int
        var time: Double
        var frameCount: Int
        var settings: EncoderSettings
        /// The settings on both sides, which are the same or this would not be a marker.
        var surroundingSettings: EncoderSettings
        var resyncByteCountAtStart: Int
    }

    /// Every brief, reverting encoder-mode change in a scan.
    ///
    /// A run only counts if the runs on *both* sides exist and match each other, so the leading
    /// frame of a file is never a marker even when it stands alone: the first frame of every
    /// episode measured is a lone stereo frame ahead of a joint-stereo body, and treating it as a
    /// seam would put a marker at time zero that nothing corroborates.
    static func seamMarkers(in scan: FrameScan) -> [SeamMarker] {
        guard scan.runs.count >= 3 else { return [] }
        var markers: [SeamMarker] = []
        for index in 1..<(scan.runs.count - 1) {
            let run = scan.runs[index]
            let before = scan.runs[index - 1]
            let after = scan.runs[index + 1]
            guard run.frameCount <= maximumSeamMarkerFrames else { continue }
            guard before.settings == after.settings else { continue }
            // A bitrate wobble that happens to revert is not what was measured; the seam is a
            // channel-mode change, so require the mode itself to be what differs.
            guard run.settings.channelMode != before.settings.channelMode else { continue }
            markers.append(SeamMarker(byteOffset: run.startByteOffset,
                                      time: run.startTime,
                                      frameCount: run.frameCount,
                                      settings: run.settings,
                                      surroundingSettings: before.settings,
                                      resyncByteCountAtStart: run.resyncByteCountAtStart))
        }
        return markers
    }

    /// Ad slots found by the seam rule.
    ///
    /// Both halves are required and neither ships alone: a block only becomes a span when it is
    /// bounded by two brief reverting mode changes *and* it is a standard spot long. The revert on
    /// its own marks every join the stitcher made, including joins onto real content; the duration
    /// on its own would fire on any 30-second stretch of an episode. Together they measured zero
    /// false positives, and that pairing is the thing being shipped.
    ///
    /// The research also checked that every seam sat inside a silence gap. That needs decoded PCM,
    /// the one input this stage exists to avoid, so it is not applied here — which makes the rule
    /// shipped slightly looser than the rule measured. That gap was then closed directly: the two
    /// conditions above were swept over 23.1 hours of whole files, every episode end to end rather
    /// than the first 90 seconds. The five shows without stitched ads produced no markers at all —
    /// not merely no spans, but not one instance of the revert pattern in nearly 20 hours — and
    /// every Get Sleepy episode produced exactly its three markers and two spans. Nothing anywhere
    /// produced a marker past 90 seconds. So the silence corroboration is not carrying the result,
    /// and neither is the search window; the revert-plus-duration pairing is.
    ///
    /// One thing the research had and this does not: it worked from a whole file, so a block whose
    /// closing marker has not arrived yet simply produces nothing here until it does.
    static func spans(in scan: FrameScan) -> [SkipSpan] {
        let markers = seamMarkers(in: scan)
        guard markers.count >= 2 else { return [] }
        var spans: [SkipSpan] = []
        for index in 0..<(markers.count - 1) {
            let start = markers[index]
            let end = markers[index + 1]
            // A resync between the two means bytes were skipped without contributing time, so the
            // block's measured length is not the block's real length. Nothing about it is
            // trustworthy enough to cut on.
            guard start.resyncByteCountAtStart == end.resyncByteCountAtStart else { continue }
            let length = end.time - start.time
            guard abs(length - standardSpotSeconds) <= spotToleranceSeconds else { continue }
            spans.append(SkipSpan(start: start.time,
                                  end: end.time,
                                  kind: .adPod,
                                  source: .encoderSeam,
                                  confidence: .automatic,
                                  sponsor: nil))
        }
        return spans
    }

    /// Convenience for the streaming path: scan a prefix and return whatever it can defend.
    static func spans(in data: Data) -> [SkipSpan] {
        spans(in: scan(data))
    }
}
