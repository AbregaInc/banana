import Foundation
import CoreText

/// Offscreen pixel equivalence on the actual device, separate from touch/display timing.
@MainActor
enum RasterConcurrencyProbe {
    static func run(store: FixtureStore, width: CGFloat, scale: CGFloat) async -> [String: Any] {
        let model = PrototypeModel(store: store)
        let black = CGColor(gray: 0, alpha: 1)
        var style = RasterPage.Style(
            text: .init(font: CTFontCreateUIFontForLanguage(.system, 12, nil)!, color: black),
            hours: .init(font: CTFontCreateUIFontForLanguage(.system, 11, nil)!, color: black),
            background: CGColor(gray: 1, alpha: 1), separator: CGColor(gray: 0.5, alpha: 1),
            event: CGColor(red: 0, green: 0, blue: 1, alpha: 0.15))
        style.pixelBuffer = Optimizations().tilePixelBuffer
        style.nativeText = Optimizations().tileNativeText
        var referenceStyle = style
        referenceStyle.batchEventFills = false
        referenceStyle.pixelBuffer = false
        referenceStyle.nativeText = false
        let pages = (0..<3).map { index in
            model.resolve(to: store.calendar.date(byAdding: .day, value: index * 5, to: store.anchor)!)
        }
        var references: [Data] = []
        for days in pages {
            for tile in 0..<4 {
                let page = RasterPage.render(days: days, width: width, height: 1920,
                    gutter: 48, scale: scale, style: referenceStyle,
                    region: CGRect(x: 0, y: CGFloat(tile * 256), width: width, height: 256))!
                references.append(page.image.dataProvider!.data! as Data)
            }
        }
        let candidateStyle = style, expected = references
        let failures = await withTaskGroup(of: [Int].self, returning: [Int].self) { group in
            for worker in 0..<2 {
                group.addTask {
                    let memo = candidateStyle.textMemo(reusing: 48)
                    var failures: [Int] = []
                    for iteration in 0..<48 {
                        let index = (iteration + worker * 5) % expected.count
                        let matches = autoreleasepool {
                            guard let page = RasterPage.render(days: pages[index / 4], width: width,
                                height: 1920, gutter: 48, scale: scale, style: candidateStyle,
                                region: CGRect(x: 0, y: CGFloat((index % 4) * 256), width: width, height: 256), textMemo: memo) else { return false }
                            return page.image.dataProvider!.data! as Data == expected[index]
                        }
                        if !matches { failures.append(worker * 48 + iteration) }
                    }
                    if candidateStyle.memoText && (memo?.hits ?? 0) == 0 { failures.append(-1-worker) }
                    return failures
                }
            }
            var failures: [Int] = []
            for await values in group { failures.append(contentsOf: values) }
            return failures.sorted()
        }
        return ["status": failures.isEmpty ? "passed" : "failed", "checks": 96,
                "failures": failures, "fixture": store.fixtureSummary,
                "timeZone": store.calendar.timeZone.identifier, "width": width, "scale": scale,
                "batchEventFills": style.batchEventFills, "memoRasterText": style.memoText, "pixelBuffer": style.pixelBuffer,
                "nativeText": style.nativeText,
                "scope": "Physical-device offscreen concurrent pixel correctness; not UI/frame/input latency"]
    }
}
