import SwiftUI
import XCTest

/// The Human Interface Guidelines rules the design system holds for every screen (HIG,
/// Accessibility and Typography): text that can be read, controls VoiceOver can name.
final class HIGRulesTests: XCTestCase {

    // MARK: - Contrast

    private func environment(_ scheme: ColorScheme) -> EnvironmentValues {
        var values = EnvironmentValues()
        values.colorScheme = scheme
        return values
    }

    private func luminance(_ c: Color.Resolved) -> Double {
        func channel(_ v: Float) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }

    private func contrast(_ a: Color.Resolved, _ b: Color.Resolved) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `b` laid over `a` at `alpha`, as a block's fill sits on the page.
    private func over(_ a: Color.Resolved, _ b: Color.Resolved, _ alpha: Float) -> Color.Resolved {
        Color.Resolved(red: a.red * (1 - alpha) + b.red * alpha,
                       green: a.green * (1 - alpha) + b.green * alpha,
                       blue: a.blue * (1 - alpha) + b.blue * alpha)
    }

    private func srgb(_ hex: UInt32) -> Color.Resolved {
        Color.Resolved(red: Float((hex >> 16) & 0xFF) / 255, green: Float((hex >> 8) & 0xFF) / 255,
                       blue: Float(hex & 0xFF) / 255)
    }

    /// The pages small quiet text sits on: white, the grouped grey and a Mac window in light;
    /// black, the elevated greys and a Mac window in dark.
    private let pages: [ColorScheme: [UInt32]] = [
        .light: [0xFFFFFF, 0xF2F2F7, 0xF5F5F5],
        .dark: [0x000000, 0x1C1C1E, 0x1E1E1E, 0x2C2C2E],
    ]

    func testQuietTextIsReadableOnEveryPage() {
        for (scheme, backgrounds) in pages {
            let text = DS.Palette.quietText.resolve(in: environment(scheme))
            for page in backgrounds {
                XCTAssertGreaterThanOrEqual(contrast(text, srgb(page)), 4.5, "\(scheme) on #\(String(page, radix: 16))")
            }
        }
    }

    /// The system's tertiary label, which hour labels and eyebrows used, is not: the reason the
    /// role exists.
    func testTheSystemsTertiaryLabelWasNotReadable() {
        let tertiary = Color(uiColor: .tertiaryLabel).resolve(in: environment(.light))
        XCTAssertLessThan(contrast(over(srgb(0xFFFFFF), tertiary, tertiary.opacity), srgb(0xFFFFFF)), 4.5)
    }

    /// A block's words on its own fill, for every colour a calendar can have.
    func testBlockInkIsReadableOnItsFillForEveryCalendarColour() {
        for scheme in [ColorScheme.light, .dark] {
            let env = environment(scheme)
            let page = scheme == .light ? srgb(0xFFFFFF) : srgb(0x000000)
            var worst = Double.infinity
            for hue in stride(from: 0, to: 360, by: 6) {
                for saturation in [0.0, 0.3, 0.6, 1.0] {
                    for brightness in [0.3, 0.6, 1.0] {
                        let source = UIColor(hue: CGFloat(hue) / 360, saturation: saturation, brightness: brightness, alpha: 1)
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        source.getRed(&r, green: &g, blue: &b, alpha: &a)
                        let hex = String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
                        guard let tint = CalendarColor.color(hex: hex) else { return XCTFail(hex) }
                        let fill = over(page, tint.resolve(in: env), Float(DS.Event.fill))
                        let ink = DS.Event.ink(tint).resolve(in: env)
                        worst = min(worst, contrast(ink, fill))
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(worst, 4.5, "\(scheme)")
        }
    }

    // MARK: - Type

    func testNoTextIsSmallerThanThePlatformAllows() {
        XCTAssertEqual(DS.Typeface.minimumSize, 11)
        for size in DynamicTypeSize.allCases {
            XCTAssertGreaterThanOrEqual(DS.Typeface.Size.meta(size), DS.Typeface.minimumSize, "\(size)")
            XCTAssertGreaterThanOrEqual(DS.Typeface.Size.title(size), DS.Typeface.minimumSize, "\(size)")
        }
    }

    func testTheGridGrowsWithDynamicTypeUpToItsLimit() {
        XCTAssertGreaterThan(DS.Typeface.Size.title(.xxLarge), DS.Typeface.Size.title(.large))
        XCTAssertEqual(DS.Typeface.Size.title(.accessibility5), DS.Typeface.Size.title(DS.Typeface.gridLargest))
    }

    // MARK: - Sources

    private func swiftSources() throws -> [(path: String, lines: [String])] {
        let root = SourceTree.root
        var found: [(String, [String])] = []
        for folder in ["Banana", "Shared", "BananaWidget"] {
            let base = root.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                found.append((url.path.replacingOccurrences(of: root.path + "/", with: ""), text.components(separatedBy: "\n")))
            }
        }
        XCTAssertGreaterThan(found.count, 100, "the sources were not found under \(root.path)")
        return found
    }

    /// Every switch says what it switches, even where the row shows the words beside it:
    /// VoiceOver reads the switch's own label (HIG, Accessibility).
    func testEverySwitchHasALabel() throws {
        for (path, lines) in try swiftSources() {
            for (i, line) in lines.enumerated() where line.contains("Toggle(\"\",") {
                XCTFail("\(path):\(i + 1) a switch with no label")
            }
        }
    }

    /// Words are never in the system's tertiary colour, which is under 2:1 on white: quiet words
    /// are `DS.Palette.quietText`. Glyphs that only decorate (a chevron) and a field's
    /// placeholder may stay tertiary.
    func testNoWordsInTheTertiaryColour() throws {
        for (path, lines) in try swiftSources() {
            for (i, line) in lines.enumerated() where line.contains(".tertiary)") && line.contains("foregroundStyle") {
                let window = lines[max(0, i - 3)...i].joined(separator: "\n")
                if window.contains("Image(") || window.contains("placeholder") { continue }
                XCTFail("\(path):\(i + 1) words in the tertiary colour")
            }
        }
    }

    /// No text drawn below the Mac's 10-point floor anywhere, and nothing names a size the
    /// design system's roles already give (`DS.Typeface.small`).
    func testNoFixedSizeBelowTheFloor() throws {
        let pattern = try NSRegularExpression(pattern: #"\.system\(size: ?([0-9]+(\.[0-9]+)?)[,)]"#)
        for (path, lines) in try swiftSources() {
            for (i, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                for match in pattern.matches(in: line, range: range) {
                    guard let r = Range(match.range(at: 1), in: line), let size = Double(line[r]) else { continue }
                    XCTAssertGreaterThanOrEqual(size, 10, "\(path):\(i + 1)")
                }
            }
        }
    }

    /// A sheet that confirms nothing closes with the system's Close (`SheetClose`), never a lone
    /// Done (HIG, Sheets); a sheet that saves confirms with the prominent button
    /// (`.sheetConfirm()`, HIG, Toolbars).
    func testSheetsCloseWithCloseAndConfirmProminently() throws {
        for (path, lines) in try swiftSources() where !path.hasSuffix("SheetChrome.swift") {
            for (i, line) in lines.enumerated() where line.contains("placement: .confirmationAction") {
                let item = lines[i...min(lines.count - 1, i + 6)].joined(separator: "\n")
                // A Done that isn't the prominent confirming button only closes the sheet, however
                // it closes it (`dismiss()`, a flag, the caller's close): that is SheetClose's job.
                if item.contains("Button(\"Done\")"), !item.contains(".sheetConfirm()") {
                    XCTFail("\(path):\(i + 1) a Done that only closes the sheet: use SheetClose")
                } else if !item.contains("Button(\"Done\")"), !item.contains(".sheetConfirm()") {
                    XCTFail("\(path):\(i + 1) a sheet's confirming button without .sheetConfirm()")
                }
            }
        }
    }
}
