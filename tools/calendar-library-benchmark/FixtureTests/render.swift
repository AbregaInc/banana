import Foundation
import CoreText

@main
struct FixtureRenderChecks {
    @MainActor static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8))!
        let events = (0..<12).map { index in
            Fixture(id: "color-\(index)", start: date.addingTimeInterval(Double(index * 7200)),
                end: date.addingTimeInterval(Double(index * 7200 + 3600)),
                title: "Calendar \(index) — title", calendarIndex: index)
        }
        let day = DayGeometry(date: date, calendar: calendar, events: events)
        let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)
        let text = PreparedText.Style(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black)
        let style = RasterPage.Style(text: text, hours: text, background: white,
            separator: black, event: CGColor(gray: 0.5, alpha: 1))
        let page = RasterPage.render(days: [day], width: 400, height: 1920, gutter: 48, scale: 1, style: style)!
        let image = page.image
        let bytes = image.dataProvider!.data! as Data
        // Independent swatches use CGContext directly, including its color-space
        // conversion and alpha compositing. RGB arithmetic would incorrectly assume
        // the palette and bitmap share a color space.
        let reference = CGContext(data: nil, width: 12, height: 1, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        reference.setFillColor(white); reference.fill(CGRect(x: 0, y: 0, width: 12, height: 1))
        for index in 0..<12 {
            reference.setFillColor(FixturePalette.fills[index])
            reference.fill(CGRect(x: index, y: 0, width: 1, height: 1))
        }
        let expected = reference.makeImage()!.dataProvider!.data! as Data
        var distinct = Set<[UInt8]>()
        for index in 0..<12 {
            let color = Array(expected[index * 4..<index * 4 + 4])
            distinct.insert(color)
            // Interior, away from labels, grid and rounded edges.
            let y = index * 160 + 50
            for x in 100..<300 {
                let offset = y * image.bytesPerRow + x * 4
                precondition((0..<4).allSatisfy { bytes[offset + $0] == color[$0] },
                    "Calendar \(index) painted the wrong color at \(x),\(y)")
            }
        }
        precondition(distinct.count == 12, "Calendar colors collapsed")
        precondition(page.ids.count == 12, "Renderer omitted events")
        print("Passed 2,400 independent interior pixel checks for 12 distinct calendar colors")
    }
}
