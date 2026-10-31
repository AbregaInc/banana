import SwiftUI

/// A video-meeting platform, recognised from a join URL's host. Codable so it can ride in the
/// `MeetingInfo` snapshot. `generic` = a video link we can open but couldn't brand.
enum MeetingPlatform: String, Codable, Hashable {
    case zoom, meet, teams, webex, calcom, whereby, gotomeeting, bluejeans, chime, ringcentral
    case jitsi, skype, discord, slack, around, eightByEight, hangouts, facetime, gong, generic

    /// Short label for the Join button ("Join Meet", "Join Teams", …).
    var label: String {
        switch self {
        case .zoom: return "Zoom";           case .meet: return "Meet"
        case .teams: return "Teams";         case .webex: return "Webex"
        case .calcom: return "Cal.com";      case .whereby: return "Whereby"
        case .gotomeeting: return "GoTo";    case .bluejeans: return "BlueJeans"
        case .chime: return "Chime";         case .ringcentral: return "RingCentral"
        case .jitsi: return "Jitsi";         case .skype: return "Skype"
        case .discord: return "Discord";     case .slack: return "Slack"
        case .around: return "Around";       case .eightByEight: return "8x8"
        case .hangouts: return "Hangouts";   case .facetime: return "FaceTime"
        case .gong: return "Gong";           case .generic: return "Video"
        }
    }

    /// Brand-ish tint for the big platforms; the rest fall back to the app accent.
    var tint: Color {
        switch self {
        case .zoom:  return Color(red: 0.15, green: 0.47, blue: 0.98)
        case .meet:  return Color(red: 0.00, green: 0.60, blue: 0.33)
        case .teams: return Color(red: 0.38, green: 0.40, blue: 0.65)
        case .webex: return Color(red: 0.00, green: 0.66, blue: 0.55)
        case .facetime: return .green
        default:     return .accentColor
        }
    }

    /// Classify a URL by host. Ordered so the specific hosts win.
    ///
    /// A host matches a domain exactly or as a subdomain. It used to also accept
    /// `h.contains(s)`, which made every other clause redundant and matched any host with the
    /// brand anywhere in it — including hosts that merely embed the string. Jitsi keeps an
    /// explicit substring test because self-hosted Jitsi genuinely has no fixed domain.
    static func classify(_ url: URL) -> MeetingPlatform {
        let h = (url.host ?? "").lowercased()
        for entry in hosts where entry.domains.contains(where: { h == $0 || h.hasSuffix("." + $0) })
            || entry.anywhere.map(h.contains) == true {
            return entry.platform
        }
        return .generic
    }

    /// Every host `classify` knows, in its order. Also what `mayNameAPlatform` looks for, so a
    /// platform added here is found in invite text too.
    private static let hosts: [(domains: [String], anywhere: String?, platform: MeetingPlatform)] = [
        (["zoom.us", "zoomgov.com"], nil, .zoom),
        (["meet.google.com"], nil, .meet),
        (["teams.microsoft.com", "teams.live.com"], nil, .teams),
        (["webex.com"], nil, .webex),
        (["cal.com"], nil, .calcom),
        (["whereby.com"], nil, .whereby),
        (["gotomeeting.com", "gotomeet.me", "goto.com"], nil, .gotomeeting),
        (["bluejeans.com"], nil, .bluejeans),
        (["chime.aws", "ch022.on.aws"], nil, .chime),
        (["ringcentral.com", "rcvideo.com"], nil, .ringcentral),
        (["meet.jit.si"], "jitsi", .jitsi),
        (["skype.com"], nil, .skype),
        (["discord.gg", "discord.com"], nil, .discord),
        (["slack.com"], nil, .slack),
        (["around.co"], nil, .around),
        (["8x8.vc", "8x8.com"], nil, .eightByEight),
        (["hangouts.google.com"], nil, .hangouts),
        (["facetime.apple.com"], nil, .facetime),
        (["gong.io", "join.gong.io"], nil, .gong),
    ]

    /// Whether `text` could hold a link `classify` brands: a branded host is spelled out in any
    /// link to it. False means no URL in the text can be anything but `.generic`.
    static func mayNameAPlatform(_ text: String) -> Bool {
        let lower = text.lowercased()
        return hostMarkers.contains { lower.contains($0) }
    }

    private static let hostMarkers: [String] = hosts.flatMap { $0.domains + ($0.anywhere.map { [$0] } ?? []) }
}

/// Finds the join link for a calendar event — the improvement that makes "Join" one tap. Scans
/// the location, the event's URL field, and the NOTES body (where Meet/Teams put the real link,
/// which the old location-only check missed). A known platform wins wherever it appears; a bare
/// URL sitting in the location field is taken as a generic video link.
enum MeetingLink {
    /// Every meeting is looked at again on every calendar read, and the link detector costs about
    /// 5 ms over a typical invite: 900 meetings held the main thread for over four seconds a
    /// read. An event's answer only changes when its text does, so it is kept.
    static func detect(location: String?, notes: String?, url: URL?) -> (platform: MeetingPlatform, url: URL)? {
        let key = DetectionKey(location: location, notes: notes, url: url?.absoluteString)
        if let known = memo.value(for: key) { return known.found }
        let found = scan(location: location, notes: notes, url: url)
        memo.store(Detection(found: found), for: key)
        return found
    }

    private static func scan(location: String?, notes: String?, url: URL?) -> (platform: MeetingPlatform, url: URL)? {
        // `location` is scanned again below (the bare-URL fallback); compute it once and reuse it
        // instead of re-running the detector over the same string a second time.
        let locationURLs = location.map(urls(in:)) ?? []
        var candidates: [URL] = locationURLs
        if let url { candidates.append(contentsOf: urls(in: url.absoluteString)) }
        // The notes are most of the text, so they're read only when they could change the answer:
        // a link already ranked best can't be beaten (ties go to the earlier one), and notes that
        // name no platform hold nothing that ranks at all.
        if let notes, candidates.map(joinRank).max() ?? 0 < Self.bestRank, MeetingPlatform.mayNameAPlatform(notes) {
            candidates.append(contentsOf: urls(in: notes))
        }

        // Rank, don't take-the-first.
        //
        // This used to be "first branded host with any path wins", and the order it saw was
        // document order in the notes. A meeting invite is full of other URLs on the very same
        // domain — the banner image at the top of the template, "Download Zoom", "Test your
        // audio" — and those routinely sit ABOVE the join link, so one of them won and the Join
        // button opened a picture. Ranking by how much a URL looks like something you can join,
        // with first-appearance only as the tie-break, fixes that whatever order the invite uses.
        var best: URL?
        var bestRank = 0
        for candidate in candidates {
            let rank = joinRank(candidate)
            // Strictly greater, so first appearance still wins a tie.
            if rank > bestRank {
                bestRank = rank
                best = candidate
            }
        }
        if let best { return (MeetingPlatform.classify(best), best) }

        // No branded platform: a location that is essentially just a URL (with a path) is still a link.
        if let location, let u = locationURLs.first, hasPath(u), !isAsset(u),
           (u.scheme == "http" || u.scheme == "https"),
           location.trimmingCharacters(in: .whitespacesAndNewlines).count < u.absoluteString.count + 24 {
            return (.generic, u)
        }
        return nil
    }

    /// How much a URL looks like a link you can actually join. 0 means never offer it.
    ///
    /// The ranking exists because "is this on a meeting platform's domain" was never enough to
    /// tell a join link from a logo.
    static func joinRank(_ url: URL) -> Int {
        let platform = MeetingPlatform.classify(url)
        guard platform != .generic else { return 0 }
        if isAsset(url) { return 0 }          // a picture is not a meeting
        if isUtilityPage(url) { return 1 }    // "Download", "Test your audio" — last resort only
        if hasJoinShapedPath(url, platform) { return bestRank }
        if hasPath(url) { return 3 }
        return 2                              // bare domain, e.g. "zoom.us" typed in the location
    }

    /// `joinRank` of a link shaped like a meeting's own join link — nothing ranks higher.
    static let bestRank = 4

    /// A file the invite renders, not a place you go. This is the specific thing that was being
    /// mistaken for a join link.
    static func isAsset(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "tif", "tiff",
            "css", "js", "woff", "woff2", "ttf", "otf", "pdf", "mp4", "mov"].contains(ext) { return true }
        let path = url.path.lowercased()
        return ["/static/", "/assets/", "/asset/", "/images/", "/image/", "/img/",
                "/media/", "/logo", "/icon", "/favicon"].contains { path.contains($0) }
    }

    /// Real pages on the platform that are not this meeting. Ranked above nothing, below anything
    /// joinable — better to open Zoom's download page than to offer no button at all, but only if
    /// there is genuinely nothing better in the invite.
    static func isUtilityPage(_ url: URL) -> Bool {
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        return ["download", "test", "support", "signin", "sign-in", "login", "pricing", "about",
                "privacy", "terms", "contact", "client", "docs", "help", "account", "profile",
                "feature", "features", "blog", "buy", "billing"].contains(first)
    }

    /// The shapes these platforms actually use for a meeting, where they are well-known enough to
    /// assert. Anything not listed falls through to the weaker "has a path" rank rather than being
    /// excluded — an unknown shape is a reason to rank lower, never a reason to drop a link.
    static func hasJoinShapedPath(_ url: URL, _ platform: MeetingPlatform) -> Bool {
        let path = url.path.lowercased()
        switch platform {
        case .zoom:
            // /j/<id> and /w/<id> are the standard joins, /s/<id> a personal link, /my/<name> a
            // vanity room, /wc/join/<id> the browser client.
            return path.hasPrefix("/j/") || path.hasPrefix("/w/") || path.hasPrefix("/s/")
                || path.hasPrefix("/my/") || path.contains("/wc/join")
        case .meet:
            // meet.google.com/abc-defg-hij
            return path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
                || path.hasPrefix("/lookup/")
        case .teams:
            return path.contains("/meetup-join") || path.contains("/meet/")
        case .webex:
            return path.contains("/meet/") || path.contains("/join/") || path.contains("j.php")
        case .chime:
            return path.contains("/join")
        case .gotomeeting, .bluejeans, .ringcentral, .whereby, .jitsi, .around, .eightByEight:
            // Path IS the room id for these; anything with a path is a room.
            return hasPath(url)
        default:
            return false
        }
    }

    static func hasPath(_ u: URL) -> Bool { let p = u.path; return !p.isEmpty && p != "/" }

    /// Constructing an NSDataDetector compiles the full link grammar and costs ~1ms; it is
    /// immutable and thread-safe after construction (an NSRegularExpression subclass), so a single
    /// cached instance is safe to share across every call, including off-main agenda recomputes.
    private static let linkDetector: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func urls(in text: String) -> [URL] {
        guard let d = linkDetector else { return [] }
        let ns = text as NSString
        return d.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap(\.url)
    }

    private struct DetectionKey: Hashable {
        let location: String?
        let notes: String?
        let url: String?
    }

    private struct Detection {
        let found: (platform: MeetingPlatform, url: URL)?
    }

    /// Read from whichever thread builds a calendar window.
    private static let memo = DetectionMemo<DetectionKey, Detection>(limit: 4_000)
}

/// A bounded, lock-guarded memo: emptied when it fills, which a calendar's worth of meetings
/// doesn't do in normal use.
final class DetectionMemo<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func value(for key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func store(_ value: Value, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if values.count >= limit { values.removeAll(keepingCapacity: true) }
        values[key] = value
    }
}
