import Foundation

/// Every calendar its own colour. Google picks colours per account, so calendars from different
/// accounts collide — bo@zeta.example and bo@dewey.example both "#9fe1e7", another person's two calendars
/// both grey — and Banana evens colours out to one brightness (`CalendarColor.normalized`), so two
/// Google colours of a similar hue (a blue and a light blue) look alike too. The rule: a calendar
/// keeps Google's colour unless one earlier keeps one like it (the same hue, or both grey); the
/// rest take the palette colours least like those in use. One you've chosen in Settings is kept as
/// chosen. The order is fixed — primary calendars first, then by account and name — so every
/// device colours the same calendar the same. Pure, for tests.
enum CalendarColorAssignment {
    struct Calendar: Equatable, Sendable {
        var id: String
        var googleHex: String?
        var isPrimary = false
        var account = ""
        var title = ""
    }

    /// Eighteen hues 20° apart — each told apart from its neighbours at a glance once evened out
    /// (`clash` is under 18°) — named for the picker.
    static let paletteNames = ["Red", "Vermilion", "Orange", "Amber", "Yellow", "Lime", "Green",
                               "Emerald", "Jade", "Teal", "Cyan", "Sky", "Blue", "Indigo", "Violet",
                               "Purple", "Magenta", "Rose"]
    static let palette: [String] = (0..<18).map { hex(hue: Double($0) / 18, saturation: 0.62, brightness: 0.86) }

    static func name(_ hex: String) -> String? {
        palette.firstIndex(of: hex.lowercased()).map { paletteNames[$0] }
    }

    /// "#rrggbb" for a colour given as hue, saturation and brightness, each 0…1.
    static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        let h = (hue - floor(hue)) * 6, i = Int(h) % 6, f = h - floor(h)
        let p = brightness * (1 - saturation), q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double) = [(brightness, t, p), (q, brightness, p), (p, brightness, t),
                                                  (p, q, brightness), (t, p, brightness), (brightness, p, q)][i]
        return String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Two colours read as one: both grey, or hues within about 18°.
    static func clash(_ a: String, _ b: String) -> Bool {
        guard let x = CalendarColor.hsb(hex: a), let y = CalendarColor.hsb(hex: b) else { return false }
        let greyX = x.saturation <= 0.08, greyY = y.saturation <= 0.08
        if greyX || greyY { return greyX && greyY }
        return hueDistance(x.hue, y.hue) < 0.05
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    /// Each calendar's colour, by id.
    static func assign(_ calendars: [Calendar], chosen: [String: String] = [:]) -> [String: String] {
        let ordered = calendars.sorted {
            ($0.isPrimary ? 0 : 1, $0.account, $0.title, $0.id) < ($1.isPrimary ? 0 : 1, $1.account, $1.title, $1.id)
        }
        var colours: [String: String] = [:]
        var inUse: [String] = []
        // What you chose comes first and stays: it's yours to clash if you want.
        for calendar in ordered {
            if let pick = chosen[calendar.id] {
                colours[calendar.id] = pick
                inUse.append(pick)
            }
        }
        // Then Google's colour for every calendar that can keep it — before any is given a new
        // one, so a new colour never pushes another calendar off its own…
        for calendar in ordered where colours[calendar.id] == nil {
            if let google = calendar.googleHex?.lowercased(), !inUse.contains(where: { clash($0, google) }) {
                colours[calendar.id] = google
                inUse.append(google)
            }
        }
        // …and the least alike of what's left for the rest.
        for calendar in ordered where colours[calendar.id] == nil {
            let colour = leastAlike(inUse) ?? calendar.googleHex?.lowercased() ?? palette[0]
            colours[calendar.id] = colour
            inUse.append(colour)
        }
        return colours
    }

    /// The palette colour furthest in hue from every colour in use — one that clashes with
    /// nothing if there is one, else the least alike of all; the first wins ties.
    static func leastAlike(_ inUse: [String]) -> String? {
        let hues = inUse.compactMap { CalendarColor.hsb(hex: $0) }.filter { $0.saturation > 0.08 }.map(\.hue)
        func distance(_ hex: String) -> Double {
            guard let hue = CalendarColor.hsb(hex: hex)?.hue else { return 0 }
            return hues.map { hueDistance($0, hue) }.min() ?? 1
        }
        let free = palette.filter { hex in !inUse.contains { clash($0, hex) } }
        let pool = free.isEmpty ? palette.filter { !inUse.contains($0) } : free
        return pool.max { distance($0) < distance($1) }
    }
}
