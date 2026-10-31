import XCTest

/// The two byte-level ad detectors: the MP3 encoder-seam scanner and the ad server's own header.
///
/// The fixtures are of two kinds. MP3 byte sequences are synthesised in code, because the property
/// under test is frame geometry and a hand-built stream states the expected frame count, mode
/// layout and truncation point exactly, where a real episode would only imply them. The ad-server
/// headers are pasted verbatim from the research captures, because the thing under test *is* a
/// third party's undocumented wire format and paraphrasing it would test the paraphrase.
final class PodcastSkipDetectionTests: XCTestCase {

    // MARK: - Synthetic MP3 construction

    /// Seconds per MPEG-1 Layer III frame at 44.1 kHz: 1152 samples, 26.12 ms. Every duration in
    /// these tests is a whole number of these, because every slot in the research captures was.
    private static let frameSeconds = 1152.0 / 44100.0

    private enum Mode: UInt8 {
        case stereo = 0
        case jointStereo = 1
        case mono = 3
    }

    /// One MPEG-1 Layer III frame: a real four-byte header followed by silence-shaped filler.
    /// The filler is zeroes so it can never be mistaken for a sync word during resynchronisation.
    private func frame(mode: Mode, bitrateKilobits: Int = 128, sampleRate: Int = 44100) -> Data {
        let bitrateIndex = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
            .firstIndex(of: bitrateKilobits)!
        let sampleRateIndex = [44100, 48000, 32000].firstIndex(of: sampleRate)!
        var bytes: [UInt8] = [
            0xFF,                                                        // sync
            0xFB,                                                        // sync, MPEG-1, Layer III
            UInt8(bitrateIndex << 4 | sampleRateIndex << 2),             // bitrate, rate, no padding
            mode.rawValue << 6                                           // channel mode
        ]
        let length = (144 * bitrateKilobits * 1000) / sampleRate
        bytes.append(contentsOf: [UInt8](repeating: 0, count: length - 4))
        return Data(bytes)
    }

    private func frames(_ count: Int, mode: Mode, bitrateKilobits: Int = 128) -> Data {
        var data = Data()
        let one = frame(mode: mode, bitrateKilobits: bitrateKilobits)
        for _ in 0..<count { data.append(one) }
        return data
    }

    /// An ID3v2 tag of a chosen payload size. Real tags in the research set run from 220 bytes to
    /// 317 628, and move between releases of the same content, so the length is always a parameter.
    private func id3Tag(payloadSize: Int) -> Data {
        var bytes: [UInt8] = [0x49, 0x44, 0x33, 0x04, 0x00, 0x00]   // "ID3", v2.4, no flags
        for shift in stride(from: 21, through: 0, by: -7) {
            bytes.append(UInt8((payloadSize >> shift) & 0x7F))       // synchsafe length
        }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: payloadSize))
        return Data(bytes)
    }

    /// A stream with two brief mode blips `framesBetween` frames apart, measured marker start to
    /// marker start — the span the seam rule is looking for.
    private func streamWithSeams(framesBetween: Int,
                                 markerFrames: Int = 1,
                                 lead: Int = 100,
                                 trail: Int = 100) -> Data {
        var data = frames(lead, mode: .jointStereo)
        data.append(frames(markerFrames, mode: .stereo))
        data.append(frames(framesBetween - markerFrames, mode: .jointStereo))
        data.append(frames(markerFrames, mode: .stereo))
        data.append(frames(trail, mode: .jointStereo))
        return data
    }

    // MARK: - Frame scanning

    func testWalksFramesAndReportsConstantBitrate() {
        let scan = PodcastAudioSeams.scan(frames(500, mode: .jointStereo))
        XCTAssertEqual(scan.audioStartOffset, 0)
        XCTAssertEqual(scan.frameCount, 500)
        XCTAssertEqual(scan.duration, 500 * Self.frameSeconds, accuracy: 1e-9)
        XCTAssertTrue(scan.isConstantBitrate)
        XCTAssertEqual(scan.timingPath, .constantBitrate)
        XCTAssertEqual(scan.resyncByteCount, 0)
        XCTAssertFalse(scan.endedOnIncompleteFrame)
        XCTAssertEqual(scan.runs.count, 1)
        XCTAssertEqual(scan.firstFrame?.bitrateKilobitsPerSecond, 128)
        XCTAssertEqual(scan.firstFrame?.sampleRate, 44100)
        XCTAssertEqual(scan.firstFrame?.byteLength, 417)
    }

    func testSkipsID3TagToFindWhereAudioBegins() {
        var data = id3Tag(payloadSize: 5000)
        data.append(frames(20, mode: .jointStereo))
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(scan.audioStartOffset, 5010)
        XCTAssertEqual(scan.frameCount, 20)
        XCTAssertEqual(scan.resyncByteCount, 0, "the walk should start exactly at the tag end")
    }

    func testID3TagLongerThanTheBytesInHandYieldsNothingRatherThanReadingOn() {
        // A streamed prefix can easily be shorter than a 317 KB artwork tag.
        var data = id3Tag(payloadSize: 300_000)
        data = data.prefix(4096)
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(scan.audioStartOffset, 4096)
        XCTAssertEqual(scan.frameCount, 0)
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty)
    }

    func testTruncatedFinalFrameIsIgnoredAndNothingIsReadPastTheBuffer() {
        var data = frames(300, mode: .jointStereo)
        data.append(frame(mode: .jointStereo).prefix(200))    // half a frame, as a stream arrives
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(scan.frameCount, 300, "a partial frame is not a frame")
        XCTAssertTrue(scan.endedOnIncompleteFrame)
        XCTAssertEqual(scan.scannedByteCount, 300 * 417)
        XCTAssertLessThan(scan.scannedByteCount, scan.byteCount)
        XCTAssertEqual(scan.duration, 300 * Self.frameSeconds, accuracy: 1e-9)
    }

    func testAFrameHeaderInTheLastThreeBytesCannotBeRead() {
        var data = frames(10, mode: .jointStereo)
        data.append(contentsOf: [0xFF, 0xFB, 0x90])           // a header cut off mid-way
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(scan.frameCount, 10)
    }

    func testNonMP3BlobProducesNoFramesAndNoSpans() {
        let text = Data("this is not an mp3, it is a paragraph of text repeated many times. ".utf8)
        var data = Data()
        for _ in 0..<200 { data.append(text) }
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(scan.frameCount, 0)
        XCTAssertNil(scan.firstFrame)
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty)
        XCTAssertNil(scan.seconds(atByteOffset: 100))
    }

    func testBytesThatSyncButDeclareAnUnsupportedLayoutAreRejected() {
        // 0xFF 0xFF passes the sync check but says Layer I, and a free-format or reserved bitrate
        // index has no length we could walk with. Sliding one byte at a time is the only safe
        // response, and it must terminate.
        let data = Data([UInt8](repeating: 0xFF, count: 10_000))
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(scan.frameCount, 0)
        XCTAssertEqual(scan.resyncByteCount, 10_000 - 3)
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty)
    }

    func testEmptyInputIsSafe() {
        let scan = PodcastAudioSeams.scan(Data())
        XCTAssertEqual(scan.frameCount, 0)
        XCTAssertEqual(scan.audioStartOffset, 0)
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty)
    }

    func testDataSliceWithANonZeroStartIndexIsScannedCorrectly() {
        var data = Data([0xAA, 0xBB, 0xCC])
        data.append(frames(50, mode: .jointStereo))
        let slice = data.dropFirst(3)
        XCTAssertNotEqual(slice.startIndex, 0, "the slice must actually be offset for this to test anything")
        let scan = PodcastAudioSeams.scan(slice)
        XCTAssertEqual(scan.frameCount, 50)
        XCTAssertEqual(scan.resyncByteCount, 0)
    }

    // MARK: - Timing paths

    func testConstantBitrateConvertsOffsetsArithmetically() {
        var data = id3Tag(payloadSize: 1000)
        data.append(frames(400, mode: .jointStereo))
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(scan.timingPath, .constantBitrate)
        // 128 kbit/s is 16 000 bytes of audio per second, by definition and not by measurement.
        XCTAssertEqual(scan.seconds(atByteOffset: 1010 + 16_000)!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(scan.seconds(atByteOffset: 1010)!, 0.0, accuracy: 1e-9)
        XCTAssertNil(scan.seconds(atByteOffset: 1009), "before audio starts there is no time")
        // Extrapolation past the bytes in hand is the point on this path: a streamed episode is
        // scanned as a small prefix and still has to place offsets much further into the file.
        XCTAssertEqual(scan.seconds(atByteOffset: 1010 + 16_000_000)!, 1000.0, accuracy: 1e-6)
    }

    func testVariableBitrateAccumulatesRealFrameDurationsInsteadOfAssuming() {
        var data = frames(10, mode: .jointStereo, bitrateKilobits: 128)   // 417 bytes each
        data.append(frames(10, mode: .jointStereo, bitrateKilobits: 192)) // 626 bytes each
        let scan = PodcastAudioSeams.scan(data)

        XCTAssertFalse(scan.isConstantBitrate)
        XCTAssertEqual(scan.timingPath, .accumulatedFrameDurations)
        XCTAssertEqual(scan.frameCount, 20)
        XCTAssertEqual(scan.duration, 20 * Self.frameSeconds, accuracy: 1e-9)

        // Anchors begin at the frame that changed the rate, not at the start of the file: the
        // frames before it are still uniform and need no index.
        XCTAssertEqual(scan.byteTimeAnchors.count, 10)
        XCTAssertEqual(scan.byteTimeAnchors.first?.byteOffset, 10 * 417)

        let changeOffset = 10 * 417
        let accumulated = scan.seconds(atByteOffset: changeOffset)!
        XCTAssertEqual(accumulated, 10 * Self.frameSeconds, accuracy: 1e-9)
        // Had it assumed the first frame's bitrate held, it would have said something else.
        XCTAssertNotEqual(accumulated, Double(changeOffset) / 16_000.0, accuracy: 1e-6)

        XCTAssertEqual(scan.seconds(atByteOffset: changeOffset + 626)!,
                       11 * Self.frameSeconds, accuracy: 1e-9)
        // Mid-frame resolves to that frame's start. A frame is the smallest thing an MP3 has a
        // time for and interpolating inside one would be inventing precision.
        XCTAssertEqual(scan.seconds(atByteOffset: changeOffset + 300)!,
                       10 * Self.frameSeconds, accuracy: 1e-9)
        // Past the bytes actually seen there is nothing but a guess, so it declines.
        XCTAssertNil(scan.seconds(atByteOffset: scan.scannedByteCount + 1))
    }

    // MARK: - The seam rule

    func testSeamAtTheMeasuredSpotLengthProducesAnAdPodSpan() throws {
        let spans = PodcastAudioSeams.spans(in: streamWithSeams(framesBetween: 1152))
        XCTAssertEqual(spans.count, 1)
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.kind, .adPod)
        XCTAssertEqual(span.source, .encoderSeam)
        XCTAssertEqual(span.confidence, .automatic)
        XCTAssertNil(span.sponsor)
        XCTAssertEqual(span.start, 100 * Self.frameSeconds, accuracy: 1e-9)
        XCTAssertEqual(span.duration, 1152 * Self.frameSeconds, accuracy: 1e-9)
        XCTAssertEqual(span.duration, 30.0931, accuracy: 0.0001)
    }

    func testTheMeasuredSpotLengthsAllFireAndTheNextFrameEitherSideDoesNot() {
        // Every slot in the research captures is 1151 or 1153 frames; 1152 is the midpoint the
        // 30.09 s figure names. One frame outside that band is not a slot anybody measured.
        for framesBetween in [1151, 1152, 1153] {
            let spans = PodcastAudioSeams.spans(in: streamWithSeams(framesBetween: framesBetween))
            XCTAssertEqual(spans.count, 1, "\(framesBetween) frames is a measured spot length")
        }
        for framesBetween in [1150, 1154] {
            let spans = PodcastAudioSeams.spans(in: streamWithSeams(framesBetween: framesBetween))
            XCTAssertTrue(spans.isEmpty, "\(framesBetween) frames is outside the measured band")
        }
    }

    func testSeamThatRevertsButIsTheWrongDurationProducesNoSpan() {
        // The revert on its own marks every join the stitcher made, including joins onto real
        // content. Without the duration half it would cut 28 seconds of the episode.
        let spans = PodcastAudioSeams.spans(in: streamWithSeams(framesBetween: 1100))
        XCTAssertTrue(spans.isEmpty)

        // And the markers really are there — it is the second half of the rule that declined.
        let scan = PodcastAudioSeams.scan(streamWithSeams(framesBetween: 1100))
        XCTAssertEqual(PodcastAudioSeams.seamMarkers(in: scan).count, 2)
    }

    func testStandardSpotLengthWithoutASeamProducesNoSpan() {
        // The duration half on its own would fire on any 30-second stretch of any episode.
        let scan = PodcastAudioSeams.scan(frames(3000, mode: .jointStereo))
        XCTAssertTrue(PodcastAudioSeams.seamMarkers(in: scan).isEmpty)
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty)
    }

    func testModeChangeThatNeverRevertsIsNotASeam() {
        var data = frames(100, mode: .jointStereo)
        data.append(frames(1152, mode: .stereo))
        data.append(frames(100, mode: .mono))
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertTrue(PodcastAudioSeams.seamMarkers(in: scan).isEmpty)
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty)
    }

    func testModeRunLongerThanAFrameOrTwoIsNotASeamMarker() {
        XCTAssertEqual(PodcastAudioSeams.maximumSeamMarkerFrames, 2)
        let twoFrames = streamWithSeams(framesBetween: 1152, markerFrames: 2)
        XCTAssertEqual(PodcastAudioSeams.spans(in: twoFrames).count, 1)
        let threeFrames = streamWithSeams(framesBetween: 1152, markerFrames: 3)
        XCTAssertTrue(PodcastAudioSeams.spans(in: threeFrames).isEmpty)
    }

    func testLoneOpeningFrameInADifferentModeIsNotASeamMarker() {
        // Every episode measured begins with a single stereo frame ahead of a joint-stereo body.
        // Nothing stands before it to prove it reverted, so it must not put a marker at time zero.
        var data = frames(1, mode: .stereo)
        data.append(frames(1152, mode: .jointStereo))
        data.append(frames(1, mode: .stereo))
        data.append(frames(100, mode: .jointStereo))
        let scan = PodcastAudioSeams.scan(data)
        XCTAssertEqual(PodcastAudioSeams.seamMarkers(in: scan).count, 1)
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty)
    }

    func testThreeSeamsProduceTwoAdjacentSpansAsTheAdServerLaidThemOut() {
        var data = frames(812, mode: .jointStereo)          // the fixed 21.21 s promo block
        data.append(frames(1, mode: .stereo))
        data.append(frames(1150, mode: .jointStereo))       // 1151 frames marker to marker
        data.append(frames(1, mode: .stereo))
        data.append(frames(1152, mode: .jointStereo))       // 1153 frames marker to marker
        data.append(frames(1, mode: .stereo))
        data.append(frames(500, mode: .jointStereo))
        let spans = PodcastAudioSeams.spans(in: data)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 812 * Self.frameSeconds, accuracy: 1e-9)
        XCTAssertEqual(spans[0].end, spans[1].start, accuracy: 1e-9, "declared slots are contiguous")
        XCTAssertEqual(spans[0].duration, 1151 * Self.frameSeconds, accuracy: 1e-9)
        XCTAssertEqual(spans[1].duration, 1153 * Self.frameSeconds, accuracy: 1e-9)
        // The 21.21 s block before the first marker is not bounded by two seams and is not a span.
        XCTAssertEqual(spans[0].start, 21.2114, accuracy: 0.001)
    }

    func testSpanIsStillFoundWhenTheStreamIsCutOffMidFrameAfterTheSecondSeam() {
        let full = streamWithSeams(framesBetween: 1152)
        // 1253 frames reaches the end of the closing marker; one more proves it reverted; 200
        // bytes of a further frame is what a stream in flight looks like.
        let truncated = full.prefix(1254 * 417 + 200)
        let scan = PodcastAudioSeams.scan(truncated)
        XCTAssertTrue(scan.endedOnIncompleteFrame)
        XCTAssertEqual(PodcastAudioSeams.spans(in: scan).count, 1)
    }

    func testSeamWhoseRevertHasNotArrivedYetIsNotYetASeam() {
        let full = streamWithSeams(framesBetween: 1152)
        let truncated = full.prefix(1253 * 417)   // stops exactly at the end of the closing marker
        XCTAssertTrue(PodcastAudioSeams.spans(in: truncated).isEmpty,
                      "a mode change with nothing after it has not been shown to revert")
    }

    func testTruncationBeforeTheSecondSeamProducesNoSpan() {
        let full = streamWithSeams(framesBetween: 1152)
        XCTAssertTrue(PodcastAudioSeams.spans(in: full.prefix(600 * 417)).isEmpty)
    }

    func testCorruptGapBetweenTwoSeamsDisqualifiesTheBlock() {
        // Bytes skipped hunting for sync carry no time with them, so the block's measured length
        // is not its real length. Nothing about it is trustworthy enough to cut on.
        let full = streamWithSeams(framesBetween: 1152)
        let markerEnd = 101 * 417
        var corrupted = Data(full.prefix(markerEnd))
        corrupted.append(contentsOf: [UInt8](repeating: 0x11, count: 5))
        corrupted.append(full.suffix(from: full.startIndex + markerEnd))

        let scan = PodcastAudioSeams.scan(corrupted)
        XCTAssertEqual(scan.resyncByteCount, 5)
        XCTAssertEqual(PodcastAudioSeams.seamMarkers(in: scan).count, 2, "both markers survive")
        XCTAssertTrue(PodcastAudioSeams.spans(in: scan).isEmpty, "but the block between them does not")
    }

    // MARK: - Sizing a streamed prefix

    func testMinimumPrefixScalesWithBitrateAndCoversTheMeasuredSeamWindow() {
        // Two real episodes of the same show: 128 kbit/s after a 317 628-byte tag, and 320 kbit/s
        // after a 319 350-byte one. A constant byte count sized for the first under-fetches the
        // second by well over a minute of audio.
        let low = PodcastAudioSeams.minimumPrefixByteCount(bitsPerSecond: 128_000,
                                                          audioStartByte: 317_628)
        let high = PodcastAudioSeams.minimumPrefixByteCount(bitsPerSecond: 320_000,
                                                            audioStartByte: 319_350)
        XCTAssertGreaterThanOrEqual(Double(low - 317_628) / 16_000.0, 90.0)
        XCTAssertGreaterThanOrEqual(Double(high - 319_350) / 40_000.0, 90.0)
        XCTAssertEqual(Double(high - 319_350) / Double(low - 317_628), 2.5, accuracy: 0.001)
        // The live capture found all three seams in a 1.7 MB prefix at this bitrate. This asks for
        // more, which is the safe direction to be wrong in.
        XCTAssertGreaterThan(low, 1_700_000)
    }

    func testMinimumPrefixCanBeSizedFromAFirstSmallReadAlone() throws {
        var data = id3Tag(payloadSize: 1000)
        data.append(frames(20, mode: .jointStereo, bitrateKilobits: 320))
        let scan = PodcastAudioSeams.scan(data)
        let sized = try XCTUnwrap(PodcastAudioSeams.minimumPrefixByteCount(for: scan))
        XCTAssertEqual(sized,
                       PodcastAudioSeams.minimumPrefixByteCount(bitsPerSecond: 320_000,
                                                                audioStartByte: 1010))
        // Nothing to read the bitrate from yet means no answer, rather than a guessed one.
        XCTAssertNil(PodcastAudioSeams.minimumPrefixByteCount(for: PodcastAudioSeams.scan(Data())))
    }

    // MARK: - Ad-server headers, verbatim from the research captures

    /// `scratchpad/podskip/live/head_headers.txt`. Two ads with creative GUIDs behind a promo.
    private let headSleepy = "#657008#pre#1#317628##false#true,6fdb70c0-806f-11f1-b898-77fed515a894#1138078#pre#2#657009#2816ce1c-a6fb-11f1-b30a-1fee2391db35#true#true,7dcf1252-809e-11f1-a510-e3c0878e9f16#1619984#pre#3#1138079#8af725b4-81e3-11f1-bc66-9f8bbaae1417#true#true@eb20bace-a144-11f1-b3db-db5934dce09d#128000#317628"

    /// `scratchpad/podskip/dupetest/headers_C.txt`. Same episode, later download: slot 3 is a real
    /// 30.1191 s ad with no creative GUID at all.
    private let dupeC = "#658142#pre#1#318762##false#true,6fdb70c0-806f-11f1-b898-77fed515a894#1139212#pre#2#658143#2816ce1c-a6fb-11f1-b30a-1fee2391db35#true#true,#1621118#pre#3#1139213##true#true@3c232d8c-a143-11f1-b354-5379f7ac2c6e#128000#318762"

    /// `scratchpad/podskip/dupetest/h_ep2.txt`. 320 kbit/s, and it is slot 2 that has no GUID.
    private let dupeEp2 = "#1167805#pre#1#319350##false#true,#2372571#pre#2#1167806##true#true,372a772e-9859-11f1-b87a-63beb922b866#3575247#pre#3#2372572#1bc247a0-9bec-11f1-a9b6-9f16758f1c48#true#true@32742e24-9fce-11f1-b7d7-635450354b27#320000#319350"

    /// `scratchpad/podskip/dupetest/h_ep3.txt`. A short third slot: 16.93 s, not 30.
    private let dupeEp3 = "#658500#pre#1#319120##false#true,6fdb70c0-806f-11f1-b898-77fed515a894#1139570#pre#2#658501#2816ce1c-a6fb-11f1-b30a-1fee2391db35#true#true,#1410406#pre#3#1139571##true#true@b2885948-9fcc-11f1-b03d-478821a1d293#128000#319120"

    func testParsesARealPayloadIntoAPromoAndTwoAds() throws {
        let layout = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: headSleepy))
        XCTAssertEqual(layout.bitsPerSecond, 128_000)
        XCTAssertEqual(layout.audioStartByte, 317_628)
        XCTAssertEqual(layout.episodeGUID, "eb20bace-a144-11f1-b3db-db5934dce09d")
        XCTAssertEqual(layout.slots.count, 3)
        XCTAssertEqual(layout.slots.map(\.position), ["pre", "pre", "pre"])
        XCTAssertEqual(layout.slots.map(\.index), [1, 2, 3])

        let spans = layout.spans
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans.map(\.kind), [.networkPromo, .adPod, .adPod])
        XCTAssertEqual(Set(spans.map(\.source)), [.declaredByHost])
        XCTAssertEqual(Set(spans.map(\.confidence)), [.automatic])

        XCTAssertEqual(spans[0].start, 0.0, accuracy: 1e-6)
        XCTAssertEqual(spans[0].end, 21.2113125, accuracy: 1e-6)
        XCTAssertEqual(spans[1].start, 21.2113125, accuracy: 1e-6)
        XCTAssertEqual(spans[1].end, 51.2781875, accuracy: 1e-6)
        XCTAssertEqual(spans[2].start, 51.2781875, accuracy: 1e-6)
        XCTAssertEqual(spans[2].end, 81.3973125, accuracy: 1e-6)
        XCTAssertEqual(layout.adSpans.count, 2)
    }

    func testDeclaredAdBoundariesReproduceTheAcousticSeamTimes() throws {
        // Cross-check between the two independent detectors on the same download. The frame walk
        // over `live/truncated_85s.mp3` puts its seams at 21.211 s, 51.278 s and 81.398 s; the
        // server's byte ranges say the same to well under a millisecond, and every slot is a whole
        // number of frames. Neither number was fitted to the other.
        let layout = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: headSleepy))
        let spans = layout.spans
        XCTAssertEqual(spans[1].start, 21.211, accuracy: 0.001)
        XCTAssertEqual(spans[2].start, 51.278, accuracy: 0.001)
        XCTAssertEqual(spans[2].end, 81.398, accuracy: 0.001)
        for span in spans {
            let frames = span.duration / Self.frameSeconds
            XCTAssertEqual(frames, frames.rounded(), accuracy: 0.01,
                           "a declared slot should be a whole number of MP3 frames")
        }
        XCTAssertEqual(spans[1].duration / Self.frameSeconds, 1151, accuracy: 0.01)
        XCTAssertEqual(spans[2].duration / Self.frameSeconds, 1153, accuracy: 0.01)
    }

    func testAnAdWithNoCreativeGUIDIsStillAnAd() throws {
        // The discriminator is the server's own flag, not the presence of a GUID. Keying on the
        // GUID would hand back this 30.1191 s ad labelled as the network's fixed promo.
        let layout = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: dupeC))
        XCTAssertNil(layout.slots[2].creativeGUID)
        XCTAssertTrue(layout.slots[2].isInserted)
        XCTAssertEqual(layout.spans.map(\.kind), [.networkPromo, .adPod, .adPod])
        XCTAssertEqual(layout.spans[2].duration, 30.119125, accuracy: 1e-6)

        // Same in the middle slot of a different episode, so it is not an artefact of position.
        let ep2 = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: dupeEp2))
        XCTAssertNil(ep2.slots[1].creativeGUID)
        XCTAssertEqual(ep2.spans.map(\.kind), [.networkPromo, .adPod, .adPod])
    }

    func testTimingUsesTheDeclaredBitrateRatherThanAnyCarriedOverConstant() throws {
        // The same show at 320 kbit/s. Read the bitrate from the wrong episode and every boundary
        // lands 2.5x out.
        let layout = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: dupeEp2))
        XCTAssertEqual(layout.bitsPerSecond, 320_000)
        XCTAssertEqual(layout.bytesPerSecond, 40_000)
        let spans = layout.spans
        XCTAssertEqual(spans[0].end, 21.21140, accuracy: 1e-5)
        XCTAssertEqual(spans[1].end, 51.33055, accuracy: 1e-5)
        XCTAssertEqual(spans[2].end, 81.39745, accuracy: 1e-5)
        // Bitrate changes the byte offsets, not the slot lengths: frame duration depends only on
        // the sample rate, so the spots are the same 1153 and 1151 frames as at 128 kbit/s.
        XCTAssertEqual(spans[1].duration / Self.frameSeconds, 1153, accuracy: 0.01)
        XCTAssertEqual(spans[2].duration / Self.frameSeconds, 1151, accuracy: 0.01)
    }

    func testAudioStartIsReadPerEpisodeAndNotAssumed() throws {
        // The same underlying content, two downloads, two different ID3 tag lengths.
        let a = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: headSleepy))
        let b = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: dupeC))
        XCTAssertEqual(a.audioStartByte, 317_628)
        XCTAssertEqual(b.audioStartByte, 318_762)
        XCTAssertNotEqual(a.audioStartByte, b.audioStartByte)
        // Both still start their first slot at time zero, because each is measured from its own.
        XCTAssertEqual(a.spans[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(b.spans[0].start, 0.0, accuracy: 1e-9)
    }

    func testAShortDeclaredSlotIsHonouredRatherThanRoundedToASpot() throws {
        // 16.93 s. The seam rule would decline this one for not being a spot length; the server
        // states it outright, which is why the two stages both exist.
        let layout = try XCTUnwrap(PodcastAdServerHeaders.layout(fromHeaderValue: dupeEp3))
        XCTAssertEqual(layout.spans.count, 3)
        XCTAssertEqual(layout.spans[2].duration, 16.92725, accuracy: 1e-6)
        XCTAssertEqual(layout.spans[2].kind, .adPod)
    }

    func testDeclaredLayoutAndTheFileItselfCorroborateEachOther() throws {
        var data = id3Tag(payloadSize: 1000)
        data.append(frames(50, mode: .jointStereo, bitrateKilobits: 128))
        let scan = PodcastAudioSeams.scan(data)
        let matching = try XCTUnwrap(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#2009#pre#1#1010##false#true@guid-a#128000#1010"))
        XCTAssertEqual(matching.agrees(with: scan), true)

        // A header describing a different download of the episode disagrees rather than silently
        // placing spans against bytes it does not describe.
        let stale = try XCTUnwrap(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#3009#pre#1#2010##false#true@guid-a#128000#2010"))
        XCTAssertEqual(stale.agrees(with: scan), false)

        // Too few bytes to compare is not the same as a disagreement.
        XCTAssertNil(matching.agrees(with: PodcastAudioSeams.scan(Data())))
    }

    // MARK: - Ad-server headers: everything that must yield nothing

    func testUnexpectedFieldCountYieldsNoSpans() {
        // One extra field in the middle segment. If the meaning of one field has moved, the
        // meaning of its neighbours probably has too, so the whole header goes, not the segment.
        let extra = "#657008#pre#1#317628##false#true,6fdb70c0#1138078#pre#2#657009#flight#extra#true#true,7dcf1252#1619984#pre#3#1138079#flight#true#true@guid#128000#317628"
        XCTAssertNil(PodcastAdServerHeaders.layout(fromHeaderValue: extra))
        XCTAssertTrue(PodcastAdServerHeaders.spans(fromHeaders: ["x-megaphone-payload-2": extra]).isEmpty)

        let missing = "#657008#pre#1#317628##false@guid#128000#317628"
        XCTAssertNil(PodcastAdServerHeaders.layout(fromHeaderValue: missing))
    }

    func testMissingOrDuplicatedTrailerYieldsNoSpans() {
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#317628##false#true"))
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#317628##false#true@guid#128000"))
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#317628##false#true@guid#128000#317628@guid#128000#317628"))
    }

    func testHeaderThatDoesNotParseAtAllYieldsNoSpans() {
        for value in ["", "   ", "not a payload at all", "@", "@#!#", ",,,@guid#128000#0"] {
            XCTAssertNil(PodcastAdServerHeaders.layout(fromHeaderValue: value), "\(value)")
        }
    }

    func testNonNumericOrNegativeFieldsYieldNoSpans() {
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#abc#pre#1#317628##false#true@guid#128000#317628"))
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#-5##false#true@guid#128000#317628"),
                     "a negative offset would run a span backwards out of the episode")
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#317628##false#true@guid#0#317628"),
                     "a zero bitrate has no time in it")
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#317628##yes#true@guid#128000#317628"),
                     "a boolean field we cannot read is a field whose meaning we have lost")
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008##1#317628##false#true@guid#128000#317628"),
                     "an empty position token says nothing about where the slot sits")
    }

    func testIncoherentByteRangesYieldNoSpans() {
        // End before start: the fields are second and fifth, so reading them the natural way round
        // is exactly the mistake this rejects.
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#317628#pre#1#657008##false#true@guid#128000#317628"))
        // A slot beginning before audio does.
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#1000##false#true@guid#128000#317628"))
        // Overlapping slots are not the simple partition the byte arithmetic assumes.
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#1#317628##false#true,#900000#pre#2#500000##true#true@guid#128000#317628"))
        // Out-of-order indices.
        XCTAssertNil(PodcastAdServerHeaders.layout(
            fromHeaderValue: "#657008#pre#2#317628##false#true,#900000#pre#1#657009##true#true@guid#128000#317628"))
    }

    func testHeaderLookupIgnoresCaseAndAbsenceYieldsNoSpans() {
        XCTAssertEqual(PodcastAdServerHeaders.spans(fromHeaders: ["X-Megaphone-Payload-2": headSleepy]).count, 3)
        XCTAssertTrue(PodcastAdServerHeaders.spans(fromHeaders: [:]).isEmpty)
        // The earlier single-payload form is deliberately not read: it omits slots and never says
        // where audio starts.
        XCTAssertTrue(PodcastAdServerHeaders.spans(fromHeaders: [
            "x-megaphone-payload": "7dcf1252#1619985,6fdb70c0#1138079@eb20bace"
        ]).isEmpty)
    }

    func testReadsTheHeaderOffARealResponse() {
        let response = HTTPURLResponse(
            url: URL(string: "https://dcs-spotify.megaphone.fm/SGP5592287278.mp3")!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["content-type": "audio/mpeg", "x-megaphone-payload-2": headSleepy]
        )!
        XCTAssertEqual(PodcastAdServerHeaders.spans(from: response).count, 3)
        XCTAssertEqual(PodcastAdServerHeaders.layout(from: response)?.bitsPerSecond, 128_000)
    }
}
