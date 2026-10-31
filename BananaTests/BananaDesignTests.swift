import SwiftUI
import XCTest

final class BananaDesignTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: hour, minute: minute))!
    }

    func testTheDayPartIsSaidOnceAndZeroMinutesAreDropped() {
        XCTAssertEqual(TimeRangeText.compact(at(9), at(10), calendar: calendar, locale: us), "9–10 AM")
        XCTAssertEqual(TimeRangeText.compact(at(9), at(10, 30), calendar: calendar, locale: us), "9–10:30 AM")
        XCTAssertEqual(TimeRangeText.compact(at(13), at(14), calendar: calendar, locale: us), "1–2 PM")
    }

    func testRangesAcrossNoonNameBothHalves() {
        XCTAssertEqual(TimeRangeText.compact(at(11, 30), at(12, 15), calendar: calendar, locale: us), "11:30 AM–12:15 PM")
        XCTAssertEqual(TimeRangeText.compact(at(12), at(13), calendar: calendar, locale: us), "12–1 PM")
    }

    func testASingleTimeAndAnEmptyRange() {
        XCTAssertEqual(TimeRangeText.time(at(0), calendar: calendar, locale: us), "12 AM")
        XCTAssertEqual(TimeRangeText.compact(at(9, 5), nil, calendar: calendar, locale: us), "9:05 AM")
        XCTAssertEqual(TimeRangeText.compact(at(9), at(9), calendar: calendar, locale: us), "9 AM")
    }

    func testTwentyFourHourLocales() {
        XCTAssertEqual(TimeRangeText.compact(at(9), at(10, 30), calendar: calendar, locale: de), "09:00–10:30")
    }

    func testClockConventionsStayCorrectAcrossLocalesAndInvalidation() {
        for _ in 0..<3 {
            for name in ["en_US", "de_DE", "fr_FR", "ar_EG", "ja_JP", "en_GB", "zh_CN", "ko_KR"] {
                let locale = Locale(identifier: name)
                let expected12Hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
                XCTAssertEqual(TimeRangeText.uses12Hour(locale), expected12Hour, name)
                if expected12Hour {
                    let formatter = DateFormatter()
                    formatter.locale = locale
                    XCTAssertTrue(TimeRangeText.time(at(9), calendar: calendar, locale: locale).hasSuffix(formatter.amSymbol))
                    XCTAssertTrue(TimeRangeText.time(at(15), calendar: calendar, locale: locale).hasSuffix(formatter.pmSymbol))
                }
            }
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        }
    }

    func testKeyCombosSplitIntoOneCapPerKey() {
        XCTAssertEqual(KeyCombo.keys("⌃⌘J"), ["⌃", "⌘", "J"])
        XCTAssertEqual(KeyCombo.keys("E then Y / N / M"), ["E", "then", "Y", "/", "N", "/", "M"])
        XCTAssertEqual(KeyCombo.keys("Esc"), ["Esc"])
    }
}

final class CalendarColorTests: XCTestCase {
    func testHexParses() {
        let red = CalendarColor.hsb(hex: "#FF0000")!
        XCTAssertEqual(red.hue, 0, accuracy: 0.001)
        XCTAssertEqual(red.saturation, 1, accuracy: 0.001)
        XCTAssertEqual(red.brightness, 1, accuracy: 0.001)
        XCTAssertNil(CalendarColor.hsb(hex: "blue"))
        XCTAssertNil(CalendarColor.hsb(hex: nil))
    }

    func testEveryCalendarLandsInOneBandAndKeepsItsHue() {
        // Google's own spread: pastel lavender, neon banana, dark graphite-ish blue, tomato.
        for hex in ["#7986CB", "#F6BF26", "#3F51B5", "#D50000", "#33B679"] {
            let source = CalendarColor.hsb(hex: hex)!
            for dark in [true, false] {
                let c = CalendarColor.normalized(source, dark: dark)
                XCTAssertEqual(c.hue, source.hue, accuracy: 0.0001, hex)
                XCTAssertTrue((0.4...0.8).contains(c.saturation), "\(hex) saturation \(c.saturation)")
                if dark { XCTAssertEqual(c.brightness, 0.9, accuracy: 0.001) }
                else { XCTAssertTrue((0.55...0.72).contains(c.brightness), "\(hex) brightness \(c.brightness)") }
            }
        }
    }

    func testGreysStayGrey() {
        let graphite = CalendarColor.hsb(hex: "#616161")!
        XCTAssertLessThan(CalendarColor.normalized(graphite, dark: true).saturation, 0.08)
    }
}

final class ClockOnlyTests: XCTestCase {
    func testNoLeadingZeroAndNoDayPart() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        let t = c.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 14, minute: 43))!
        XCTAssertEqual(TimeRangeText.clockOnly(t, calendar: c, locale: Locale(identifier: "en_US")), "2:43")
        XCTAssertEqual(TimeRangeText.clockOnly(t, calendar: c, locale: Locale(identifier: "de_DE")), "14:43")
    }
}

/// A missing number must read as missing, not as a measured zero.
final class PlaceholderTests: XCTestCase {
    func testPlaceholderIsADashNotZero() {
        XCTAssertEqual(DS.placeholder, "\u{2014}")
        XCTAssertNotEqual(DS.placeholder, "0")
    }

    /// The accent is the system's (a Mac's chosen accent, the system blue on a phone), so no
    /// app or Mac asset catalog may carry an AccentColor that would override it.
    func testTheAccentIsTheSystems() {
        XCTAssertEqual(DS.Palette.accent, Color.accentColor)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for catalog in ["Banana/Assets.xcassets", "BananaMac/Assets.xcassets"] {
            let asset = root.appendingPathComponent(catalog).appendingPathComponent("AccentColor.colorset")
            XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path), catalog)
        }
    }

    func testEveryStatusHasItsOwnColour() {
        let colours = [ConnectionStatus.ok, .working, .attention, .off].map { "\($0.color)" }
        XCTAssertEqual(Set(colours).count, colours.count)
    }
}

/// Formatters already append their unit; the stat splits it off to draw it smaller.
final class StatValueSplitTests: XCTestCase {
    func testTheTrailingWordIsTheUnit() {
        XCTAssertTrue(StatValue.split("150 W") == ("150", "W"))
        XCTAssertTrue(StatValue.split("6:12 /km") == ("6:12", "/km"))
        XCTAssertTrue(StatValue.split("5.21 km") == ("5.21", "km"))
    }

    func testNoUnitStaysWhole() {
        XCTAssertTrue(StatValue.split("1:02:03") == ("1:02:03", nil))
        XCTAssertTrue(StatValue.split("78%") == ("78%", nil))
        XCTAssertTrue(StatValue.split("Zone 4") == ("Zone 4", nil), "a word first is not a number and a unit")
    }

    func testADashIsNoValue() {
        XCTAssertTrue(StatValue.split("—") == (nil, nil))
        XCTAssertTrue(StatValue.split("–") == (nil, nil))
    }
}

/// The player takes its colour from the show's artwork.
final class ImageAverageTests: XCTestCase {
    private func image(_ pixels: [(UInt8, UInt8, UInt8)]) -> CGImage {
        var bytes: [UInt8] = pixels.flatMap { [$0.0, $0.1, $0.2, 255] }
        let context = CGContext(data: &bytes, width: pixels.count, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4 * pixels.count, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testASolidImageIsItsOwnColour() {
        XCTAssertEqual(ImageAverage.hex(of: image([(255, 0, 0), (255, 0, 0)])), "#FF0000")
    }

    func testTwoColoursAverage() {
        let hex = ImageAverage.hex(of: image([(0, 0, 0), (255, 255, 255)]))
        // Somewhere in the middle grey, whatever the resampler's rounding.
        let value = Int(hex!.dropFirst().prefix(2), radix: 16)!
        XCTAssertTrue((100...155).contains(value), "got \(hex!)")
    }
}
