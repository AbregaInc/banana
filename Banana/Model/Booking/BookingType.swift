import Foundation

/// A booking type (docs/design/BOOKING.md §4, §12): what a guest can book on the host's link, as the
/// `plan.bookingType` record the service reads (`Service/src/booking/types.js`). The record's
/// fields are this struct's keys, and their names and units are the service's:
///
/// | Field | Unit |
/// |---|---|
/// | `title`, `slug` | text; the slug is `[a-z0-9-]{1,40}`, unique among the person's types, fixed once made |
/// | `minutes` | the length, 5–480 |
/// | `hours` | 7 lists, index 0 = Sunday, of `[startMinute, endMinute]` on the type's wall clock |
/// | `timeZone` | an IANA name, fixed once set (it doesn't follow travel) |
/// | `step` | minutes between start times; absent = the length if it divides 60, else 15 |
/// | `bufferBefore`, `bufferAfter` | minutes, 0–240 |
/// | `notice` | minutes from now, 0–43 200 |
/// | `horizonDays` | 1–90 |
/// | `perDay` | bookings a day at most, absent = no limit |
/// | `locations` | `[{id, kind, url?, phone?, address?}]`, the first is the default |
/// | `calendar` | `{email, id}`, absent = the primary calendar of the oldest Google link |
/// | `active`, `order` | on or off; where it sits on the profile |
///
/// Decoding is tolerant: a field missing (or one a newer build wrote that this one can't read)
/// takes the service's default, as the service does.
struct BookingType: Codable, Equatable, Sendable {
    var title: String
    var slug: String
    var minutes: Int
    var hours: [[BookingSpan]]
    var timeZone: String
    var step: Int?
    var bufferBefore: Int
    var bufferAfter: Int
    var notice: Int
    var horizonDays: Int
    var perDay: Int?
    var locations: [BookingPlace]
    var calendar: BookingCalendar?
    var active: Bool
    var order: Int

    /// The service's default type (`defaultType` in types.js): Meeting, 30 minutes, Mon–Fri 9–5
    /// in `zone`, Google Meet, four hours' notice, 30 days ahead.
    static func standard(zone: String) -> BookingType {
        BookingType(title: "Meeting", slug: "meeting", minutes: 30, hours: weekdays9to5, timeZone: zone,
                    step: nil, bufferBefore: 0, bufferAfter: 0, notice: 240, horizonDays: 30, perDay: nil,
                    locations: [BookingPlace(kind: .meet)], calendar: nil, active: true, order: 0)
    }

    /// Mon–Fri, 09:00–17:00.
    static let weekdays9to5: [[BookingSpan]] = (0..<7).map { $0 == 0 || $0 == 6 ? [] : [BookingSpan(start: 540, end: 1020)] }

    /// The lengths offered as one tap; anything else is "Custom".
    static let lengths = [15, 30, 45, 60]

    /// The device's zone as the service takes it: an IANA name with a "/", or UTC.
    static func deviceZone(_ zone: TimeZone = .current) -> String {
        let id = zone.identifier
        return id.contains("/") || id == "UTC" ? id : "UTC"
    }

    init(title: String, slug: String, minutes: Int, hours: [[BookingSpan]], timeZone: String, step: Int?,
         bufferBefore: Int, bufferAfter: Int, notice: Int, horizonDays: Int, perDay: Int?,
         locations: [BookingPlace], calendar: BookingCalendar?, active: Bool, order: Int) {
        self.title = title
        self.slug = slug
        self.minutes = minutes
        self.hours = hours
        self.timeZone = timeZone
        self.step = step
        self.bufferBefore = bufferBefore
        self.bufferAfter = bufferAfter
        self.notice = notice
        self.horizonDays = horizonDays
        self.perDay = perDay
        self.locations = locations
        self.calendar = calendar
        self.active = active
        self.order = order
    }

    private enum CodingKeys: String, CodingKey {
        case title, slug, minutes, hours, timeZone, step, bufferBefore, bufferAfter, notice, horizonDays, perDay
        case locations, calendar, active, order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BookingType.standard(zone: "UTC")
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        title = value(.title, d.title)
        slug = value(.slug, d.slug)
        minutes = value(.minutes, d.minutes)
        let hours: [[BookingSpan]] = value(.hours, d.hours)
        self.hours = hours.count == 7 ? hours : d.hours
        timeZone = value(.timeZone, d.timeZone)
        step = try? c.decodeIfPresent(Int.self, forKey: .step)
        bufferBefore = value(.bufferBefore, 0)
        bufferAfter = value(.bufferAfter, 0)
        notice = value(.notice, d.notice)
        horizonDays = value(.horizonDays, d.horizonDays)
        perDay = try? c.decodeIfPresent(Int.self, forKey: .perDay)
        let places: [LossyPlace] = value(.locations, [])
        let known = places.compactMap(\.place)
        locations = known.isEmpty ? d.locations : known
        calendar = try? c.decodeIfPresent(BookingCalendar.self, forKey: .calendar)
        active = value(.active, true)
        order = value(.order, 0)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(slug, forKey: .slug)
        try c.encode(minutes, forKey: .minutes)
        try c.encode(hours, forKey: .hours)
        try c.encode(timeZone, forKey: .timeZone)
        try c.encodeIfPresent(step, forKey: .step)
        try c.encode(bufferBefore, forKey: .bufferBefore)
        try c.encode(bufferAfter, forKey: .bufferAfter)
        try c.encode(notice, forKey: .notice)
        try c.encode(horizonDays, forKey: .horizonDays)
        try c.encodeIfPresent(perDay, forKey: .perDay)
        try c.encode(locations, forKey: .locations)
        try c.encodeIfPresent(calendar, forKey: .calendar)
        try c.encode(active, forKey: .active)
        try c.encode(order, forKey: .order)
    }

    /// A place a newer build wrote that this one doesn't know is left out, not the whole type.
    private struct LossyPlace: Decodable {
        let place: BookingPlace?
        init(from decoder: Decoder) throws { place = try? BookingPlace(from: decoder) }
    }

    // MARK: - Reading and changing

    /// The weekdays with hours, Sunday = 0.
    var openDays: [Int] { (0..<7).filter { !hours[$0].isEmpty } }

    /// One place of a kind, if the type offers it. The two phone kinds are one place.
    func place(_ kind: BookingPlace.Kind) -> BookingPlace? {
        locations.first { $0.kind == kind || ($0.kind.isPhone && kind.isPhone) }
    }

    /// Adds or replaces the place of its kind (a phone place replaces the other phone kind), or
    /// takes it away (nil). The first place stays first.
    mutating func set(_ kind: BookingPlace.Kind, to place: BookingPlace?) {
        let index = locations.firstIndex { $0.kind == kind || ($0.kind.isPhone && kind.isPhone) }
        switch (index, place) {
        case let (index?, place?): locations[index] = place
        case let (index?, nil): locations.remove(at: index)
        case let (nil, place?): locations.append(place)
        case (nil, nil): break
        }
    }

    /// The places as the service will take them: a Zoom or other link must be https, a "they call
    /// me" number and an address must be there (types.js `placeOf`); the rest it drops.
    var usablePlaces: [BookingPlace] { locations.filter(\.isUsable) }
}

/// One span of hours on a weekday, as the service writes it: `[startMinute, endMinute]`.
struct BookingSpan: Codable, Hashable, Sendable {
    var start: Int
    var end: Int

    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        start = try c.decode(Int.self)
        end = try c.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(start)
        try c.encode(end)
    }

    /// The service keeps a span only when it is inside the day and has some length.
    var isValid: Bool { start >= 0 && end <= 1440 && start < end }
}

/// Where a booked meeting happens (CONTRACT.md "A place a type offers").
struct BookingPlace: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case meet, zoom
        case phoneHostCalls = "phone_host_calls"
        case phoneGuestCalls = "phone_guest_calls"
        case inPerson = "in_person"
        case link

        var isPhone: Bool { self == .phoneHostCalls || self == .phoneGuestCalls }

        /// The place's id: one place per kind, the two phone kinds sharing one.
        var placeID: String {
            switch self {
            case .meet: "meet"
            case .zoom: "zoom"
            case .phoneHostCalls, .phoneGuestCalls: "phone"
            case .inPerson: "in_person"
            case .link: "link"
            }
        }
    }

    var id: String
    var kind: Kind
    var url: String?
    var phone: String?
    var address: String?

    init(kind: Kind, url: String? = nil, phone: String? = nil, address: String? = nil) {
        id = kind.placeID
        self.kind = kind
        self.url = url
        self.phone = phone
        self.address = address
    }

    private enum CodingKeys: String, CodingKey { case id, kind, url, phone, address }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? kind.placeID
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        phone = try? c.decodeIfPresent(String.self, forKey: .phone)
        address = try? c.decodeIfPresent(String.self, forKey: .address)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        // Only what the kind uses: a Zoom link left behind on a phone place would go to the guest.
        switch kind {
        case .zoom, .link: try c.encodeIfPresent(url, forKey: .url)
        case .phoneGuestCalls: try c.encodeIfPresent(phone, forKey: .phone)
        case .inPerson: try c.encodeIfPresent(address, forKey: .address)
        case .meet, .phoneHostCalls: break
        }
    }

    /// Whether the service keeps it (types.js `placeOf`).
    var isUsable: Bool {
        switch kind {
        case .meet, .phoneHostCalls: return true
        case .zoom, .link: return BookingPlace.httpsURL(url) != nil
        case .phoneGuestCalls: return !(phone ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .inPerson: return !(address ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// A pasted link as the service keeps it: https, 500 characters at most.
    static func httpsURL(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.count <= 500,
              let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// Whether a pasted link is a Zoom meeting link.
    static func isZoom(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "zoom.us" || host.hasSuffix(".zoom.us")
    }
}

/// The calendar a type's events go on.
struct BookingCalendar: Codable, Equatable, Sendable {
    var email: String?
    var id: String
}

// MARK: - Slugs

enum BookingSlug {
    /// A slug made from a title, unique among `taken`: "Intro call" → `intro-call`, then
    /// `intro-call-2`. An empty one is `meeting`.
    static func make(from title: String, taken: Set<String>) -> String {
        let plain = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var slug = ""
        var dash = false
        for scalar in plain.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if dash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                dash = false
            } else {
                dash = true
            }
        }
        slug = String(slug.prefix(36)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "meeting" }
        guard taken.contains(slug) else { return slug }
        var n = 2
        while taken.contains("\(slug)-\(n)") { n += 1 }
        return "\(slug)-\(n)"
    }
}
