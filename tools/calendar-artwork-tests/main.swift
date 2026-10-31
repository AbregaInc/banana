import SwiftUI
import AppKit

@main struct ArtworkOracle {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            FileHandle.standardError.write(Data("Refusing to overwrite artwork evidence\n".utf8))
            exit(2)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1791541800)
        let basic = CalendarEventPaint(title: "Design review with the entire team", start: start,
            startText: "9:10 AM", timeRange: "9:10–10:25 AM", icon: "calendar")
        var cases: [(String, CalendarEventPaint)] = [("event", basic)]
        func variant(_ name: String, _ edit: (inout CalendarEventPaint) -> Void) {
            var paint = basic; edit(&paint); cases.append((name, paint))
        }
        variant("task") { $0.isEvent = false; $0.isTask = true; $0.icon = "circle" }
        variant("completed-task") { $0.isTask = true; $0.isEvent = false; $0.completed = true }
        variant("skipped-cue") { $0.isEvent = false; $0.isMoment = true; $0.skipped = true; $0.icon = "moon" }
        variant("alarm") { $0.isEvent = false; $0.isMoment = true; $0.icon = "alarm" }
        variant("free") { $0.showsAsFree = true; $0.fillOpacity = DS.Event.quietFill }
        variant("tentative") { $0.tentative = true }
        variant("invited") { $0.needsAction = true; $0.fillOpacity = DS.Event.quietFill }
        variant("declined-others") { $0.othersDeclined = true }
        variant("ribbons") { $0.tint = .purple; $0.ribbons = [.purple, .green, .orange] }
        variant("return-location") { $0.returnCaption = "Home by 10:25 AM · 20 min"; $0.location = "123 Long Street, New York" }
        variant("video") { $0.location = "Video call" }
        variant("unicode") { $0.title = "設計レビュー 👩🏽‍💻 café العربية" }
        var failures: [[String: Any]] = [], timings: [[String: Any]] = []
        var checks = 0
        func bytes(_ image: CGImage) -> Data {
            var data = Data(count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        func save(_ image: CGImage, _ name: String) throws {
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
        }
        for desktop in [true, false] {
            for dark in [false, true] {
                for rtl in [false, true] {
                    for width in [28.0, 90.0, 180.0] {
                        for height in [8.0, 15.0, 19.0, 24.0, 34.0, 40.0, 64.0, 80.0] {
                            for (name, paint) in cases {
                                try autoreleasepool {
                                    let key = "\(desktop ? "desktop" : "mobile")-\(dark)-\(rtl)-\(Int(width))-\(Int(height))-\(name)"
                                    let began = ProcessInfo.processInfo.systemUptime
                                    let old = ImageRenderer(content: LegacyCalendarEventArtwork(paint: paint,
                                        height: height, layout: desktop ? .desktop : .mobile, showsIcon: width >= 100)
                                        .frame(width: width, height: height)
                                        .environment(\.colorScheme, dark ? .dark : .light)
                                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                                        .environment(\.locale, Locale(identifier: "en_US")))
                                    old.scale = 2
                                    guard let expected = old.cgImage else { fatalError("Missing reference \(key)") }
                                    let middle = ProcessInfo.processInfo.systemUptime
                                    let new = ImageRenderer(content: CalendarEventArtwork(paint: paint,
                                        height: height, layout: desktop ? .desktop : .mobile, showsIcon: width >= 100)
                                        .frame(width: width, height: height)
                                        .environment(\.colorScheme, dark ? .dark : .light)
                                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                                        .environment(\.locale, Locale(identifier: "en_US")))
                                    new.scale = 2
                                    guard let actual = new.cgImage else { fatalError("Missing candidate \(key)") }
                                    let ended = ProcessInfo.processInfo.systemUptime
                                    checks += 1
                                    timings.append(["case": key, "referenceMS": (middle-began)*1000, "candidateMS": (ended-middle)*1000])
                                    if expected.width != actual.width || expected.height != actual.height || bytes(expected) != bytes(actual) {
                                        failures.append(["case": key])
                                        try save(expected, "\(key)-reference.png")
                                        try save(actual, "\(key)-candidate.png")
                                    }
                                    if name == "ribbons", desktop, !dark, !rtl, width == 180, height == 80 {
                                        let preview = ImageRenderer(content: CalendarEventArtwork(paint: paint,
                                            height: height, layout: .desktop, showsIcon: true)
                                            .frame(width: width, height: height).background(Color.white)
                                            .environment(\.colorScheme, .light))
                                        preview.scale = 2
                                        if let image = preview.cgImage { try save(image, "sample.png") }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let report: [String: Any] = ["checks": checks, "failures": failures, "timings": timings,
            "scope": "Exact offscreen macOS SwiftUI pixels, desktop/mobile layout branches; not iOS pixels or UI performance. Fixed reference-then-candidate order is diagnostic only."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        print("\(failures.isEmpty ? "PASS" : "FAIL"): \(checks) artwork cases, \(failures.count) exact pixel failures")
        if !failures.isEmpty { exit(1) }
    }
}
