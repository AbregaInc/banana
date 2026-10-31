import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct Comparison {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Preserve existing evidence") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var environment = EnvironmentValues()
        environment.displayScale = 2
        let reference = CalendarArtworkRasterCache(byteLimit: 0, entryLimit: 0)
        let native = CalendarArtworkRasterCache(byteLimit: 0, entryLimit: 0, rendering: .nativeCoreText)
        let warmNative = CalendarArtworkRasterCache(byteLimit: 1024 * 1024, entryLimit: 2, rendering: .nativeCoreText)
        var reports: [[String: Any]] = []
        func save(_ image: CGImage, name: String) {
            let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL,
                UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        for desktop in [false, true] {
            for dark in [false, true] {
                environment.colorScheme = dark ? .dark : .light
                for state in 0...4 {
                    var paint = CalendarEventPaint(title: "Planning 👩‍💻 — 東京 with a longer title",
                        start: Date(timeIntervalSince1970: 0), startText: "10:30", timeRange: "10:30–11:30 AM", icon: "calendar")
                    paint.tint = .blue; paint.ribbons = [.blue, .red]
                    paint.location = "Meeting room — étage 2"
                    paint.showsAsFree = state == 1; paint.tentative = state == 2
                    paint.needsAction = state == 3; paint.completed = state == 4
                    paint.fillOpacity = state == 1 || state == 3 ? 0.08 : 0.2
                    let size = CGSize(width: 180, height: 100)
                    var samples: [String: [Double]] = ["reference": [], "native": []]
                    var pixels: [String: CGImage] = [:]
                    for iteration in 0..<12 {
                        for backend in iteration.isMultiple(of: 2) ? ["reference", "native"] : ["native", "reference"] {
                            let start = DispatchTime.now().uptimeNanoseconds
                            let image: CGImage
                            if backend == "native" {
                                image = try native.image(paint: paint, size: size, desktop: desktop,
                                    showsIcon: true, environment: environment)
                            } else {
                                image = try reference.image(paint: paint, size: size, desktop: desktop,
                                    showsIcon: true, environment: environment)
                            }
                            samples[backend]!.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                            pixels[backend] = image
                        }
                    }
                    let name = "\(desktop ? "desktop" : "mobile")-\(dark ? "dark" : "light")-\(state)"
                    let prepared = try warmNative.image(paint: paint, size: size, desktop: desktop,
                        showsIcon: true, environment: environment)
                    let started = DispatchTime.now().uptimeNanoseconds
                    let warm = try warmNative.image(paint: paint, size: size, desktop: desktop,
                        showsIcon: true, environment: environment)
                    let warmMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                    precondition(prepared === warm, "Warm lookup did not reuse the prepared image")
                    precondition(prepared.dataProvider!.data! == pixels["native"]!.dataProvider!.data!, "Native cache changed pixels")
                    warmNative.clear()
                    let evictionStart = DispatchTime.now().uptimeNanoseconds
                    let restored = try warmNative.image(paint: paint, size: size, desktop: desktop,
                        showsIcon: true, environment: environment)
                    let evictionMS = Double(DispatchTime.now().uptimeNanoseconds - evictionStart) / 1_000_000
                    precondition(prepared.dataProvider!.data! == restored.dataProvider!.data!, "Eviction changed pixels")
                    for (backend, image) in pixels { save(image, name: name + "-" + backend) }
                    reports.append(["case": name, "samplesMS": samples, "warmLookupMS": warmMS,
                        "evictionRenderMS": evictionMS, "retainedPixelBytes": warmNative.retainedBytes,
                        "exactPixelsEqual": pixels["native"]!.dataProvider!.data! == pixels["reference"]!.dataProvider!.data!])
                }
            }
        }
        let report: [String: Any] = ["results": reports,
            "scope": "Alternating uncached event preparation including adapter; first uses retained. Different artwork, not a parity pass or adoption decision. Cache eviction/memory/device frames remain unmeasured."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("comparison.json"))
        print("Recorded \(reports.count) adapter/reference cases and 480 uncached preparation samples")
    }
}
