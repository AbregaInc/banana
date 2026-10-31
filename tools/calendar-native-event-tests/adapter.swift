import SwiftUI
import CoreText

@main struct AdapterChecks {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(!FileManager.default.fileExists(atPath: output.path), "Preserve evidence")
        var checks = 0
        func check(_ value: Bool, _ reason: String) { checks += 1; precondition(value, reason) }
        var environment = EnvironmentValues()
        environment.displayScale = 2
        let cache = CalendarArtworkRasterCache(rendering: .nativeCoreText)
        for desktop in [false, true] {
            for rtl in [false, true] {
                environment.layoutDirection = rtl ? .rightToLeft : .leftToRight
                for height: CGFloat in [16, 40, 100] {
                    var paint = CalendarEventPaint(title: "Sensitive appointment title",
                        start: Date(timeIntervalSince1970: 0), startText: "12:34", timeRange: "12:34–13:45", icon: "calendar")
                    paint.returnCaption = "Travel home — 23 min"
                    paint.location = "Private address"
                    let size = CGSize(width: 180, height: height)
                    environment.redactionReasons = []
                    let plain = try cache.image(paint: paint, size: size, desktop: desktop,
                        showsIcon: true, environment: environment)
                    let request = CalendarNativeEventAdapter.request(paint: paint, size: size,
                        paintHeight: height, desktop: desktop, showsIcon: true, environment: environment)
                    check(!request.redacted, "Ordinary event redacted")
                    check(request.subtitleIcon != nil || desktop && height < 34, "Return-home symbol missing")
                    for reason: RedactionReasons in [.placeholder, .privacy] {
                        environment.redactionReasons = reason
                        environment.textCase = .uppercase
                        let hidden = CalendarNativeEventAdapter.request(paint: paint, size: size,
                            paintHeight: height, desktop: desktop, showsIcon: true, environment: environment)
                        check(hidden.redacted && hidden.title.value.string.isEmpty, "Title crossed redaction boundary")
                        check(hidden.subtitle?.value.string.isEmpty != false && hidden.location?.value.string.isEmpty != false,
                            "Metadata crossed redaction boundary")
                        check(hidden.icon == nil && hidden.warning == nil && hidden.subtitleIcon == nil, "Redacted symbol exposed")
                        let redacted = try cache.image(paint: paint, size: size, desktop: desktop,
                            showsIcon: true, environment: environment)
                        check(redacted.dataProvider!.data! != plain.dataProvider!.data!, "Redaction reused ordinary cached pixels")
                        var changed = paint
                        changed.title = "Different much longer confidential title 👩‍💻"
                        changed.location = nil; changed.returnCaption = nil
                        changed.startText = "01:23"; changed.timeRange = "01:23–23:45"
                        let other = try cache.image(paint: changed, size: size, desktop: desktop,
                            showsIcon: true, environment: environment)
                        check(other.dataProvider!.data! == redacted.dataProvider!.data!, "Redacted pixels reveal content or length")
                    }
                    environment.redactionReasons = []; environment.textCase = nil
                    let restored = try cache.image(paint: paint, size: size, desktop: desktop,
                        showsIcon: true, environment: environment)
                    check(restored.dataProvider!.data! == plain.dataProvider!.data!, "Unredaction did not restore event")
                }
            }
        }
        environment.redactionReasons = []
        var moment = CalendarEventPaint(title: "Wind down", start: Date(timeIntervalSince1970: 0),
            startText: "9:00 PM", timeRange: "9:00 PM", icon: "moon.fill")
        moment.isMoment = true
        for height: CGFloat in [16, 24, 39] {
            let request = CalendarNativeEventAdapter.request(paint: moment, size: CGSize(width: 180, height: height),
                paintHeight: height, desktop: false, showsIcon: true, environment: environment)
            check(request.title.value.string.hasPrefix("9:00 PM"), "Compact mobile moment lost its visible time")
            check(request.title.value.string.contains("Wind down"), "Compact mobile moment lost its title")
        }
        moment.hasScheduledTime = false
        let untimed = CalendarNativeEventAdapter.request(paint: moment, size: CGSize(width: 180, height: 24),
            paintHeight: 24, desktop: false, showsIcon: true, environment: environment)
        check(!untimed.title.value.string.contains("9:00 PM"), "Untimed routine gained an invented time")
        try JSONSerialization.data(withJSONObject: ["checks": checks, "status": "pass",
            "scope": "Actual native adapter/cache redaction and caption symbols. Not parent-cell accessibility, device UI or performance acceptance."], options: [.prettyPrinted])
            .write(to: output)
        print("PASS: \(checks) production adapter/cache checks")
    }
}
