import Foundation

/// The Banana service's address and calls (docs/design/ACCOUNTS.md), with no state of its own:
/// what `BananaAccount` and `Telemetry` send and read. Pure, for tests.
enum BananaService {
    /// The service's host, from the private config (`BANANA_SERVICE_HOST`). Nil in anyone's own
    /// build and the Beta: then nothing that needs the service runs.
    static let host: String? = configured("BananaServiceHost")
    /// The web OAuth client the service trades Google sign-in codes with
    /// (`BANANA_GOOGLE_SERVER_CLIENT`). Without it Google hands the app no code for the service.
    static let googleServerClientID: String? = configured("BananaGoogleServerClient").map(fullClientID)

    /// Google's full client id, whether the setting holds the part before
    /// ".apps.googleusercontent.com" or the whole id. Build 59 doubled the ending on a whole id, so
    /// Google gave no code for the service and every "Sign in again" did nothing (19 Oct 2026).
    static func fullClientID(_ value: String) -> String {
        let ending = ".apps.googleusercontent.com"
        return value.hasSuffix(ending) ? value : value + ending
    }

    /// Whether this build has an account to offer: a service and a client to sign in to it with.
    static var isAvailable: Bool { host != nil && googleServerClientID != nil }

    static func configured(_ key: String, in bundle: Bundle = .main) -> String? {
        guard let value = (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    // MARK: - What goes back and forth

    struct Device: Codable, Equatable {
        var id: String
        /// iphone, ipad or mac.
        var platform: String
        /// The push token in hex, once iOS or macOS has given one.
        var push: String?
        /// development for builds installed directly, production for TestFlight and the App Store.
        var pushEnv: String
        var bundle: String
    }

    struct Account: Codable, Equatable {
        struct Google: Codable, Equatable, Hashable {
            var email: String
            /// ok, or refused: Google took back the service's access and it needs a new sign-in.
            var status: String
            var watching: Int
            /// The service holds working Google access of its own for this account (from a sign-in
            /// with a code), so it can read events and send alerts itself. False after a sign-in by
            /// identity token: the person signs in once more. Nil from a service that doesn't say.
            var access: Bool?
        }
        var id: String
        var google: [Google]
        var devices: Int
        /// The move off iCloud (docs/design/DATA-PLATFORM.md §3 seeding rule 2, §8): the types the
        /// account's iPhone has seeded, when it has an iPhone active in the last 30 days.
        var seeded: [String]? = nil
        /// Whether that iPhone exists: false when the service says `"seeded": null`; nil when it
        /// says nothing (a service from before the move).
        var hasIPhone: Bool? = nil
        /// `purge` once every device active in 30 days has seeded and flipped and the account
        /// allows it; `keep` otherwise.
        var icloud: String? = nil
        /// Every device active in 30 days has flipped. Nil from a service that doesn't say.
        var flipped: Bool? = nil

        private enum CodingKeys: String, CodingKey { case id, google, devices, seeded, icloud, flipped }

        init(id: String, google: [Google], devices: Int, seeded: [String]? = nil, hasIPhone: Bool? = nil,
             icloud: String? = nil, flipped: Bool? = nil) {
            self.id = id
            self.google = google
            self.devices = devices
            self.seeded = seeded
            self.hasIPhone = hasIPhone ?? seeded.map { _ in true }
            self.icloud = icloud
            self.flipped = flipped
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            google = try c.decode([Google].self, forKey: .google)
            devices = try c.decode(Int.self, forKey: .devices)
            seeded = try c.decodeIfPresent([String].self, forKey: .seeded)
            hasIPhone = c.contains(.seeded) ? seeded != nil : nil
            icloud = try c.decodeIfPresent(String.self, forKey: .icloud)
            flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(google, forKey: .google)
            try c.encode(devices, forKey: .devices)
            if let hasIPhone { if hasIPhone { try c.encode(seeded ?? [], forKey: .seeded) } else { try c.encodeNil(forKey: .seeded) } }
            try c.encodeIfPresent(icloud, forKey: .icloud)
            try c.encodeIfPresent(flipped, forKey: .flipped)
        }
    }

    struct SignInAnswer: Decodable {
        /// Only when signing in made a new session.
        var session: String?
        var account: Account
    }

    /// A calendar watch a device opened at Google for the service (`/v1/google/channels`).
    struct Channel: Codable, Equatable {
        var id: String
        var email: String
        var calendarId: String
        var resourceId: String?
        /// pending (asked for, not yet opened at Google), live, failed.
        var status: String
        /// Milliseconds since 1970, when Google ends it.
        var expiresAt: Double?
    }

    struct ChannelsAnswer: Decodable { var channels: [Channel] }

    /// What the device needs to open a watch at Google: the channel's id and secret, the address
    /// Google calls, and how long to ask for.
    struct OpenedChannel: Decodable, Equatable {
        var id: String
        var token: String
        var address: String
        var ttlSeconds: Int
    }

    enum Call {
        /// A Google sign-in's one-time code: signs in, or links it to the signed-in account.
        case signIn(code: String, device: Device)
        /// Google's identity token for a connected account: signs in, or links it, with no sign-in
        /// sheet.
        case identity(idToken: String, device: Device)
        case account
        /// Deleting needs a fresh Google sign-in's one-time code: a session alone never deletes.
        case deleteAccount(code: String)
        case device(Device)
        /// The watches devices opened for this account.
        case channels
        /// A new watch for one calendar: the service answers with the channel to open at Google.
        case openChannel(email: String, calendarID: String)
        /// Google's answer for a watch this device opened.
        case confirmChannel(id: String, resourceID: String, expiration: Date)
        /// A watch closed at Google, or no longer wanted.
        case closeChannel(id: String)
        /// A Google account disconnected in Banana.
        case unlink(email: String)
        /// The lead times and time zone the service words its event alerts with.
        case alertSettings(leads: [Int], timeZone: String)
        /// The alert ids this device holds as its own local notifications, and what it rings for.
        case heldAlerts(device: String, report: HeldReport)
        /// An alert dismissed or opened on this device.
        case clearAlert(id: String, device: String)
        /// The day's usage counts (`TelemetryBatch`).
        case usage(Data)
        /// Crash, hang and performance reports (`DiagnosticReports`), anonymous.
        case diagnostics(Data)
        /// The data platform's one sync call (docs/design/DATA-PLATFORM.md §4), its body made by
        /// `SyncRequest.body()`.
        case sync(Data)
        /// A blob by its SHA-256: PUT (the body streamed from a file), GET or HEAD.
        case blob(method: String, sha256: String)
        /// When this device's seed was acknowledged, when it stopped writing iCloud, and the types it
        /// has seeded. What is nil is left as the service has it.
        case syncState(device: String, seededAt: Date?, flippedAt: Date?, seeded: [String]?)
        /// The Health consent (docs/design/DATA-PLATFORM.md §7): given, with the version of the words
        /// agreed to and the device it was given on, or withdrawn.
        case healthConsent(granted: Bool, version: String, device: String)
        /// The booking link (docs/design/BOOKING.md §12): the handle, the link, the handles to
        /// suggest when there is none, the account's name and zone, and the types the service sees.
        case booking
        /// Takes (or changes to) a handle. The zone is the device's: the default type's, fixed when
        /// the handle is made.
        case claimHandle(handle: String, timeZone: String?)
        /// The bookings still ahead.
        case upcomingBookings
    }

    /// `GET /v1/booking` (`Service/src/booking/api.js`).
    struct BookingState: Codable, Equatable, Sendable {
        struct TypeLink: Codable, Equatable, Sendable {
            var slug: String
            var title: String
            var active: Bool
            var link: URL
        }
        var handle: String?
        var link: URL?
        var suggested: [String]
        var name: String?
        var timeZone: String?
        var types: [TypeLink]

        init(handle: String? = nil, link: URL? = nil, suggested: [String] = [], name: String? = nil,
             timeZone: String? = nil, types: [TypeLink] = []) {
            self.handle = handle
            self.link = link
            self.suggested = suggested
            self.name = name
            self.timeZone = timeZone
            self.types = types
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            handle = try c.decodeIfPresent(String.self, forKey: .handle)
            link = try c.decodeIfPresent(URL.self, forKey: .link)
            suggested = try c.decodeIfPresent([String].self, forKey: .suggested) ?? []
            name = try c.decodeIfPresent(String.self, forKey: .name)
            timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
            types = try c.decodeIfPresent([TypeLink].self, forKey: .types) ?? []
        }

        /// The booking site's address, from a link the service made: `https://book.bananatheapp.com`.
        var site: String? {
            guard let link, var parts = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return nil }
            parts.path = ""
            parts.query = nil
            return parts.string
        }
    }

    /// `PUT /v1/booking`'s answer.
    struct ClaimedHandle: Codable, Equatable, Sendable {
        var handle: String
        var link: URL
    }

    /// What `PUT /v1/booking` says of a handle it didn't take: 400 invalid, reserved or zone; 409
    /// taken. Nil when the answer was something else (the service down): try again later.
    static func handleRefusal(status: Int, data: Data) -> BookingHandle.Problem? {
        switch (status, failure(in: data)) {
        case (409, _): return .taken
        case (400, "reserved"): return .reserved
        case (400, "zone"): return nil   // the zone, not the handle: `zoneRefused`
        case (400, _): return .invalid
        default: return nil
        }
    }

    /// `PUT /v1/booking` refused the zone sent with the handle (400 `zone`): sent again without it.
    static func zoneRefused(status: Int, data: Data) -> Bool {
        status == 400 && failure(in: data) == "zone"
    }

    /// `GET /v1/booking/upcoming`.
    struct UpcomingBookings: Codable, Equatable, Sendable {
        struct Booking: Codable, Equatable, Sendable, Identifiable {
            struct Guest: Codable, Equatable, Sendable {
                var name: String?
                var email: String?
                var phone: String?
            }
            struct Place: Codable, Equatable, Sendable {
                var kind: String
                var detail: String?
            }
            var id: String
            var title: String
            var start: Date
            var end: Date
            /// pending or confirmed.
            var status: String
            var invited: Bool
            var guest: Guest
            var place: Place?
        }
        var bookings: [Booking]

        static func decode(_ data: Data) throws -> UpcomingBookings {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let text = try decoder.singleValueContainer().decode(String.self)
                let withFraction = ISO8601DateFormatter()
                withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO date: \(text)"))
            }
            return try decoder.decode(UpcomingBookings.self, from: data)
        }
    }

    static func request(_ call: Call, host: String, session: String?) -> URLRequest {
        let (method, path, body): (String, String, Data?) = {
            let encode = { (value: [String: Any]) in try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
            switch call {
            case .signIn(let code, let device):
                return ("POST", "/v1/google", encode(["code": code, "device": deviceJSON(device)]))
            case .identity(let idToken, let device):
                return ("POST", "/v1/google/identity", encode(["idToken": idToken, "device": deviceJSON(device)]))
            case .account:
                return ("GET", "/v1/account", nil)
            case .channels:
                return ("GET", "/v1/google/channels", nil)
            case .openChannel(let email, let calendarID):
                return ("POST", "/v1/google/channels", encode(["email": email.lowercased(), "calendarId": calendarID]))
            case .confirmChannel(let id, let resourceID, let expiration):
                return ("PUT", "/v1/google/channels/\(id)", encode(["resourceId": resourceID,
                                                                    "expiration": Int64(expiration.timeIntervalSince1970 * 1000)]))
            case .closeChannel(let id):
                return ("DELETE", "/v1/google/channels/\(id)", nil)
            case .deleteAccount(let code):
                return ("DELETE", "/v1/account", encode(["code": code]))
            case .device(let device):
                var json = deviceJSON(device)
                json["id"] = nil
                return ("PUT", "/v1/devices/\(device.id)", encode(json))
            case .unlink(let email):
                return ("DELETE", "/v1/google", encode(["email": email.lowercased()]))
            case .alertSettings(let leads, let timeZone):
                return ("PUT", "/v1/account/alerts", encode(["leads": leads, "timeZone": timeZone]))
            case .heldAlerts(let device, let report):
                var body: [String: Any] = ["device": device, "ids": report.ids, "quiet": report.quiet]
                if let calendars = report.calendars { body["calendars"] = calendars }
                return ("PUT", "/v1/alerts/held", encode(body))
            case .clearAlert(let id, let device):
                return ("POST", "/v1/alerts/clear", encode(["id": id, "device": device]))
            case .usage(let batch):
                return ("POST", "/v1/usage", batch)
            case .diagnostics(let batch):
                return ("POST", "/v1/diagnostics", batch)
            case .sync(let body):
                return ("POST", "/v2/sync", body)
            case .blob(let method, let sha256):
                return (method, "/v2/blobs/\(sha256)", nil)
            case .syncState(let device, let seededAt, let flippedAt, let seeded):
                var body: [String: Any] = [:]
                if let seededAt { body["seededAt"] = Int64(seededAt.timeIntervalSince1970 * 1000) }
                if let flippedAt { body["flippedAt"] = Int64(flippedAt.timeIntervalSince1970 * 1000) }
                if let seeded { body["seeded"] = Array(Set(seeded)).sorted() }
                return ("PUT", "/v2/devices/\(device)/sync-state", encode(body))
            case .healthConsent(let granted, let version, let device):
                return granted ? ("PUT", "/v2/consents/health", encode(["version": version, "device": device]))
                               : ("DELETE", "/v2/consents/health", nil)
            case .booking:
                return ("GET", "/v1/booking", nil)
            case .claimHandle(let handle, let timeZone):
                var body: [String: Any] = ["handle": handle]
                if let timeZone { body["timeZone"] = timeZone }
                return ("PUT", "/v1/booking", encode(body))
            case .upcomingBookings:
                return ("GET", "/v1/booking/upcoming", nil)
            }
        }()
        #if DEBUG
        // The end-to-end check (tools/e2e-sync.sh) names a local service with its scheme,
        // "http://127.0.0.1:8787". Release builds only ever speak https.
        let base = host.hasPrefix("http://") ? host : "https://\(host)"
        #else
        let base = "https://\(host)"
        #endif
        var request = URLRequest(url: URL(string: "\(base)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let session { request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func deviceJSON(_ device: Device) -> [String: Any] {
        var json: [String: Any] = ["id": device.id, "platform": device.platform, "pushEnv": device.pushEnv,
                                   "bundle": device.bundle]
        json["push"] = device.push ?? NSNull()
        return json
    }

    /// The service's word for what went wrong (`{"error": "other_account"}`), if it said one.
    static func failure(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
    }

    // MARK: - Pushes

    /// A silent push from the service saying the account's data changed on another device:
    /// `{"b": {"k": "sync"}}` (docs/design/DATA-PLATFORM.md §4).
    static func isSyncPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["b"] as? [String: Any])?["k"] as? String == "sync"
    }

    /// A visible push about a booking made, moved or cancelled (`pushHost` in
    /// `Service/src/booking/book.js`): `{"aps": {"alert": …, "thread-id": "booking"}, "b": {"k": "booking"}}`.
    static func isBookingPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["b"] as? [AnyHashable: Any])?["k"] as? String == "booking"
    }

    /// What a booking push points at: the event (`cal`, `event`, as event alerts name them), its
    /// start (`start`: milliseconds or an ISO string), and whether it was cancelled (`cancelled:
    /// true`, or `status`/`kind` "cancelled"). Every part may be missing.
    struct BookingPushTarget: Equatable, Sendable {
        var calendarID: String?
        var eventID: String?
        var start: Date?
        var cancelled = false
    }

    static func bookingTarget(_ userInfo: [AnyHashable: Any]) -> BookingPushTarget? {
        guard let b = userInfo["b"] as? [AnyHashable: Any], b["k"] as? String == "booking" else { return nil }
        let text = { (key: String) in (b[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var start: Date?
        if let ms = b["start"] as? NSNumber, !(b["start"] is Bool) {
            start = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        } else if let iso = text("start") {
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            start = withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        }
        let cancelled = b["cancelled"] as? Bool == true || text("status") == "cancelled" || text("kind") == "cancelled"
        return BookingPushTarget(calendarID: text("cal"), eventID: text("event"), start: start, cancelled: cancelled)
    }

    /// A silent push from the service saying a Google calendar changed: `{"b": {"k": "calendar"}}`.
    static func isCalendarPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["b"] as? [String: Any])?["k"] as? String == "calendar"
    }

    /// The shared id of a planned local alert (docs/design/EVENT-ALERTS.md): the plan's
    /// `<infoID>#<lead>` becomes the service's `calendarId|eventId|lead`. An event that isn't
    /// Google's keeps the plan's own id.
    static func alertID(planItemID: String) -> String {
        guard let hash = planItemID.lastIndex(of: "#") else { return planItemID }
        let infoID = String(planItemID[..<hash]), lead = String(planItemID[planItemID.index(after: hash)...])
        guard let route = GoogleCalendarIDs.rawEventRoute(from: infoID) else { return planItemID }
        return "\(route.calendarID)|\(route.eventID)|\(lead)"
    }

    /// The calendar and event of a shared alert id.
    static func alertRoute(of id: String) -> (calendarID: String, eventID: String)? {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The alert an `alert-clear` push from the service names: `{"b": {"k": "alert-clear", "id": …}}`.
    static func alertClearID(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let b = userInfo["b"] as? [AnyHashable: Any], b["k"] as? String == "alert-clear" else { return nil }
        return b["id"] as? String
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// What to do with the watches so every wanted calendar has one that won't end within a day:
    /// the calendars to open a watch for, and the watches to close (unwanted, or a spare where a
    /// calendar has two). A calendar getting a new watch keeps its old one until the new is open;
    /// its old ones are in `replaced`. Pending watches are another device's, mid-open: left alone.
    static func watchPlan(wanted: [String: [String]], channels: [Channel], now: Date,
                          renewWithin: TimeInterval = 24 * 60 * 60)
        -> (open: [(email: String, calendarID: String)], close: [Channel], replaced: [String: [Channel]]) {
        let cutoff = (now.timeIntervalSince1970 + renewWithin) * 1000
        let key = { (email: String, id: String) in "\(email.lowercased())\n\(id)" }
        let wantedKeys = Set(wanted.flatMap { email, ids in ids.map { key(email, $0) } })
        let live = channels.filter { $0.status == "live" && $0.resourceId != nil }
        let byKey = Dictionary(grouping: live, by: { key($0.email, $0.calendarId) })
        var open: [(String, String)] = [], close: [Channel] = [], replaced: [String: [Channel]] = [:]
        for (email, ids) in wanted.sorted(by: { $0.key < $1.key }) {
            for id in ids {
                let k = key(email, id)
                let mine = (byKey[k] ?? []).sorted { ($0.expiresAt ?? 0) > ($1.expiresAt ?? 0) }
                if let best = mine.first, (best.expiresAt ?? 0) > cutoff {
                    close += mine.dropFirst()
                } else {
                    open.append((email.lowercased(), id))
                    if !mine.isEmpty { replaced[k] = mine }
                }
            }
        }
        close += live.filter { !wantedKeys.contains(key($0.email, $0.calendarId)) }
        return (open.map { (email: $0.0, calendarID: $0.1) }, close, replaced)
    }

    /// The Google accounts connected in the app that the Banana account doesn't have yet, by
    /// lowercased email: what to sign in or link by identity token. Not signed in, every one.
    static func accountsToLink(connected: [String], linked: Set<String>, signedIn: Bool) -> [String] {
        let linked = Set(linked.map { $0.lowercased() })
        return connected.map { $0.lowercased() }.filter { !signedIn || !linked.contains($0) }
    }

    /// The connected Google accounts the service has no Google access of its own for: each needs
    /// one more sign-in (with a code) in the app, and the app asks for it where a signed-out
    /// account is already shown. By lowercased email. Nothing from a service that doesn't say.
    static func accountsToSignInAgain(connected: [String], account: Account?) -> Set<String> {
        guard let account else { return [] }
        let without = Set(account.google.filter { $0.access == false }.map { $0.email.lowercased() })
        return Set(connected.map { $0.lowercased() }).intersection(without)
    }

    /// Whether a Google calendar change reaches this device as it happens: the service can push to
    /// it (its token is registered), and at least one of the account's Google accounts has a live
    /// watch at Google. Otherwise the two-minute ask is what finds changes.
    static func updatesAreInstant(pushRegistered: Bool, account: Account?) -> Bool {
        pushRegistered && (account?.google.contains { $0.status == "ok" && $0.watching > 0 } ?? false)
    }

    /// The calendars to watch per Google account, keyed by lowercased email: every calendar the
    /// device reads (not hidden in Google), less the ones set not to count (`excluded` holds their
    /// info ids, as Settings keeps them). The same calendars are the ones its event alerts come from.
    static func watchLists(calendars: [(account: String, id: String, hidden: Bool)], excluded: Set<String>) -> [String: [String]] {
        var lists: [String: [String]] = [:]
        for calendar in calendars where !calendar.hidden
            && !excluded.contains(calendar.id) && !excluded.contains(GoogleCalendarIDs.calendarInfoID(calendar.id)) {
            lists[calendar.account.lowercased(), default: []].append(calendar.id)
        }
        return lists.mapValues { Array(Set($0)).sorted() }
    }

    /// What a device tells the service with its held alerts (docs/design/EVENT-ALERTS.md): the ids
    /// it holds, the calendars it rings for (nil until its calendar list is whole: then the service
    /// sends it nothing) and the events it was told to skip (`calendarId|eventId`).
    struct HeldReport: Equatable {
        var ids: [String]
        var calendars: [String]?
        var quiet: [String]

        init(ids: [String], calendars: [String]?, quiet: [String]) {
            self.ids = Array(Set(ids)).sorted()
            self.calendars = calendars.map { Array(Set($0)).sorted() }
            self.quiet = Array(Set(quiet)).sorted().prefix(500).map { $0 }
        }
    }

    /// `calendarId|eventId` of a Google event's info id, as alert ids begin; nil for another kind.
    static func alertEvent(infoID: String) -> String? {
        GoogleCalendarIDs.rawEventRoute(from: infoID).map { "\($0.calendarID)|\($0.eventID)" }
    }
}
