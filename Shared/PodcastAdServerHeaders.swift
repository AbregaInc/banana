import Foundation

/// The ad server's own account of where it put the ads.
///
/// This is the strongest signal in the whole feature and the cheapest: the host stitched the
/// episode together and then wrote down the byte ranges it used, in a response header, on the
/// request that fetches the audio. Nothing has to be inferred from the audio at all. `SHIP-SPEC.md`
/// calls the error here "zero by construction; the server states it".
///
/// It is also somebody else's undocumented private header, which can change without notice and
/// owes us nothing. So the parser is built to fail closed: every field it does not recognise, every
/// count it does not expect, every ordering that does not make sense throws away the *whole*
/// header rather than the offending piece. A partly understood layout is not a layout — if the
/// meaning of one field has moved, the meaning of its neighbours probably has too, and a span
/// derived from a misread field would cut real audio out of an episode.
///
/// Derived from five real captures in `scratchpad/podskip/`: `live/head_headers.txt`,
/// `dupetest/headers_B.txt`, `dupetest/headers_C.txt`, `dupetest/h_ep2.txt`, `dupetest/h_ep3.txt`.
enum PodcastAdServerHeaders {

    /// The only header understood.
    ///
    /// There is also a plain `x-megaphone-payload`, an earlier form carrying `<guid>#<endByte>`
    /// pairs. It is deliberately unused: it lists only the slots that had a creative GUID and only
    /// their end offsets, so in three of the five captures it omits a real ad slot entirely and in
    /// none of them does it say where audio starts. Reconstructing spans from it would mean
    /// guessing, and guessing is the one thing this stage never does.
    ///
    /// A future `-3` is not read as if it were a `-2`. A new version number is the server saying
    /// the layout changed.
    static let headerName = "x-megaphone-payload-2"

    /// One stitched segment as the server describes it.
    struct Slot: Sendable, Equatable {
        /// 1-based, in the order the server lists them.
        var index: Int
        /// `pre` in every capture. Kept as the server's own token rather than an enum of the one
        /// value seen: `SHIP-SPEC.md` is explicit that the data model must not assume pre-roll
        /// only, even though no mid-roll heuristic ships until one is measured.
        var position: String
        /// First byte of the segment, absolute in the file.
        var startByte: Int
        /// Last byte of the segment, inclusive. The next segment starts at `endByte + 1`.
        var endByte: Int
        /// The creative the server put here, when it names one. Frequently absent even on a real
        /// ad — see `isInserted`.
        var creativeGUID: String?
        var flightGUID: String?
        /// The server's own "this segment is stitched-in advertising" flag.
        ///
        /// This, not the presence of a creative GUID, is the discriminator. In all five captures
        /// it is false on exactly one segment — the first, a 21.2113 s block identical across
        /// every download of every episode, which is the network's fixed promo — and true on every
        /// segment whose length matches a measured ad spot. The creative GUID cannot do the job:
        /// three of the captures have a slot with no GUID at all that is plainly an ad (30.1191 s,
        /// flagged true, sitting between two other ads), so keying on the GUID would hand back a
        /// real ad labelled as the network promo.
        var isInserted: Bool
        /// A second boolean the server sends. It is true in all five captures with no counter-
        /// example, so its meaning is unknown and nothing is gated on it. Carried so a later
        /// capture that shows it false can be recognised rather than silently absorbed.
        var isTracked: Bool

        /// Byte length of the segment. Inclusive of both ends, which is why the +1 is here.
        var byteLength: Int { endByte - startByte + 1 }
    }

    /// The whole declaration: where audio starts, how fast it plays, and what was stitched in.
    struct Layout: Sendable, Equatable {
        var episodeGUID: String
        /// Bits per second, from the server's own trailer. Read, never assumed: two episodes of
        /// the same show in the research set are 128 000 and 320 000, so a bitrate carried over
        /// from another episode would put every span in the wrong place by a factor of 2.5.
        var bitsPerSecond: Int
        /// Where audio begins, i.e. the length of the ID3 tag the server prepended. Also read
        /// rather than assumed: it moves between releases of the same content (317 628 vs 318 762
        /// bytes in the captures) and ranges from 220 bytes to 317 628 across the set.
        var audioStartByte: Int
        var slots: [Slot]

        var bytesPerSecond: Double { Double(bitsPerSecond) / 8.0 }

        /// Seconds from the start of audio for an absolute byte offset in the file.
        ///
        /// Constant bitrate within one file is what makes this arithmetic rather than a search.
        /// That holds for every capture, and it is the server's own claim: it declares a single
        /// bitrate for the file it just assembled.
        func seconds(atByteOffset offset: Int) -> Double? {
            guard offset >= audioStartByte, bytesPerSecond > 0 else { return nil }
            return Double(offset - audioStartByte) / bytesPerSecond
        }

        /// Every declared segment as a span.
        ///
        /// The first segment is the network's fixed promo and the rest are dynamically inserted
        /// ads, so they get different kinds: the learning loop retires a detector on a show, and
        /// the promo and the ads are different enough that a listener who wants one kept may well
        /// want the other gone. Both are `.declaredByHost` and both are automatic, because the
        /// provenance is the same in both cases — the server drew these boundaries itself.
        var spans: [SkipSpan] {
            slots.compactMap { slot in
                guard let start = seconds(atByteOffset: slot.startByte),
                      let end = seconds(atByteOffset: slot.endByte + 1),
                      end > start else { return nil }
                return SkipSpan(start: start,
                                end: end,
                                kind: slot.isInserted ? .adPod : .networkPromo,
                                source: .declaredByHost,
                                confidence: .automatic,
                                sponsor: nil)
            }
        }

        /// Only the dynamically inserted ads, for a caller that wants the promo left alone.
        var adSpans: [SkipSpan] { spans.filter { $0.kind == .adPod } }

        /// Whether the server's declaration and the file's own bytes tell the same story.
        ///
        /// Two entirely independent routes to the same two numbers: the server states where audio
        /// starts and how fast it plays, and an ID3v2 tag length plus a frame header say the same
        /// thing from the bytes. In the captures they match exactly, byte for byte and bit for bit.
        /// Nil when the scan saw no whole frame — a prefix shorter than the ID3 tag corroborates
        /// nothing either way, which is not the same as disagreeing.
        ///
        /// This is a check to report, not a gate. A disagreement means one of the two is describing
        /// different audio — a stale header against a re-downloaded file, most likely — and the
        /// caller is better placed than this parser to decide which it has.
        func agrees(with scan: PodcastAudioSeams.FrameScan) -> Bool? {
            guard let first = scan.firstFrame else { return nil }
            return scan.audioStartOffset == audioStartByte
                && first.bitrateKilobitsPerSecond * 1000 == bitsPerSecond
        }
    }

    // MARK: - Parsing

    /// Parse the layout out of one header value, or return nil.
    ///
    /// The shape, from the captures:
    ///
    ///     <creative>#<endByte>#<position>#<index>#<startByte>#<flight>#<inserted>#<tracked>,
    ///     …more segments…
    ///     @<episodeGUID>#<bitsPerSecond>#<audioStartByte>
    ///
    /// Note the field order: the segment's *end* comes second and its *start* comes fifth. Getting
    /// those the natural way round would silently produce spans running backwards through the
    /// episode, so the order is asserted by the field count and the start < end check rather than
    /// trusted.
    static func layout(fromHeaderValue value: String) -> Layout? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Exactly one trailer. Zero means the header is truncated; more than one means it is not
        // the shape we know.
        let halves = trimmed.components(separatedBy: "@")
        guard halves.count == 2 else { return nil }

        let trailer = halves[1].components(separatedBy: "#")
        guard trailer.count == 3 else { return nil }
        let episodeGUID = trailer[0]
        guard !episodeGUID.isEmpty,
              let bitsPerSecond = positiveInt(trailer[1]),
              let audioStartByte = nonNegativeInt(trailer[2]) else { return nil }

        let segments = halves[0].components(separatedBy: ",")
        guard !segments.isEmpty else { return nil }

        var slots: [Slot] = []
        for segment in segments {
            let fields = segment.components(separatedBy: "#")
            // Eight, always. A different count is a different layout, and a layout we do not know
            // is a layout we do not act on.
            guard fields.count == 8 else { return nil }
            guard let endByte = nonNegativeInt(fields[1]),
                  let index = positiveInt(fields[3]),
                  let startByte = nonNegativeInt(fields[4]),
                  let isInserted = boolean(fields[6]),
                  let isTracked = boolean(fields[7]) else { return nil }
            let position = fields[2]
            guard !position.isEmpty else { return nil }
            guard startByte >= audioStartByte, endByte >= startByte else { return nil }

            // Ordered, contiguous or at least non-overlapping, and numbered upwards. Every capture
            // is exactly contiguous. Anything else means the segments are not the simple partition
            // of the head of the file that the byte arithmetic below assumes.
            if let previous = slots.last {
                guard index > previous.index, startByte > previous.endByte else { return nil }
            }

            slots.append(Slot(index: index,
                              position: position,
                              startByte: startByte,
                              endByte: endByte,
                              creativeGUID: fields[0].isEmpty ? nil : fields[0],
                              flightGUID: fields[5].isEmpty ? nil : fields[5],
                              isInserted: isInserted,
                              isTracked: isTracked))
        }
        guard !slots.isEmpty else { return nil }

        return Layout(episodeGUID: episodeGUID,
                      bitsPerSecond: bitsPerSecond,
                      audioStartByte: audioStartByte,
                      slots: slots)
    }

    /// Parse from a header dictionary, matching the header name without regard to case, since HTTP
    /// header names are case-insensitive and different stacks hand them over differently.
    static func layout(fromHeaders headers: [String: String]) -> Layout? {
        guard let value = headers.first(where: {
            $0.key.caseInsensitiveCompare(headerName) == .orderedSame
        })?.value else { return nil }
        return layout(fromHeaderValue: value)
    }

    static func layout(from response: HTTPURLResponse) -> Layout? {
        guard let value = response.value(forHTTPHeaderField: headerName) else { return nil }
        return layout(fromHeaderValue: value)
    }

    /// Everything the server declared, as spans. Empty whenever anything at all was unfamiliar.
    static func spans(fromHeaders headers: [String: String]) -> [SkipSpan] {
        layout(fromHeaders: headers)?.spans ?? []
    }

    static func spans(from response: HTTPURLResponse) -> [SkipSpan] {
        layout(from: response)?.spans ?? []
    }

    // MARK: - Field readers

    /// Strict on purpose. `Int(_:)` already rejects "12abc", and rejecting the empty string and
    /// anything signed keeps a negative byte offset from ever reaching the arithmetic.
    private static func nonNegativeInt(_ field: String) -> Int? {
        guard !field.isEmpty, let value = Int(field), value >= 0 else { return nil }
        return value
    }

    private static func positiveInt(_ field: String) -> Int? {
        guard let value = nonNegativeInt(field), value > 0 else { return nil }
        return value
    }

    /// Only the two spellings the server actually sends. A field holding anything else is a field
    /// whose meaning we have lost, not a field to coerce into false.
    private static func boolean(_ field: String) -> Bool? {
        switch field {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
