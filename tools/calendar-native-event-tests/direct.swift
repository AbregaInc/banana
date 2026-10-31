import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct DirectChecks {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        precondition(!FileManager.default.fileExists(atPath: output.path), "Preserve evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var environment = EnvironmentValues(); environment.displayScale = 2
        func frozen(_ r: CalendarNativeEventRaster.Request) -> FrozenEventRaster.Request {
            func text(_ t: CalendarNativeEventRaster.Text) -> FrozenEventRaster.Text {
                .init(value: t.value, maximumLines: t.maximumLines)
            }
            return .init(size: r.size, scale: r.scale, tint: r.tint, ribbons: r.ribbons,
                fillOpacity: r.fillOpacity, opacity: r.opacity, title: text(r.title),
                subtitle: r.subtitle.map(text), location: r.location.map(text), icon: r.icon,
                warning: r.warning, desktop: r.desktop, rightToLeft: r.rightToLeft,
                free: r.free, tentative: r.tentative, needsAction: r.needsAction,
                textVisible: r.textVisible, centerSingleLine: r.centerSingleLine,
                strikeThrough: r.strikeThrough, redacted: r.redacted, subtitleIcon: r.subtitleIcon)
        }
        func drawCanvas(_ request: CalendarNativeEventRaster.Request, image: CGImage? = nil) -> CGImage {
            let content: AnyView
            if let image {
                content = AnyView(Image(decorative: image, scale: request.scale).resizable())
            } else { content = AnyView(CalendarNativeEventCanvas(request: request)) }
            let renderer = ImageRenderer(content: content.frame(width: request.size.width, height: request.size.height))
            renderer.scale = request.scale
            var result: CGImage?
            renderer.render(rasterizationScale: request.scale) { size, draw in
                let context = CGContext(data: nil, width: Int(ceil(size.width * request.scale)),
                    height: Int(ceil(size.height * request.scale)), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: request.scale, y: request.scale)
                draw(context); result = context.makeImage()
            }
            return result!
        }
        var rows: [[String: Any]] = []
        for size in [CGSize(width: 180, height: 100), CGSize(width: 1440, height: 120),
                     CGSize(width: 1440, height: 400), CGSize(width: 1440, height: 1440)] {
            for state in 0...4 {
                var paint = CalendarEventPaint(title: "A long event — 東京 👩‍💻",
                    start: Date(timeIntervalSince1970: 0), startText: "10:00", timeRange: "10:00–12:00", icon: "calendar")
                paint.showsAsFree = state == 1; paint.tentative = state == 2
                paint.needsAction = state == 3; paint.completed = state == 4
                if CommandLine.arguments.contains("--plain-title") { paint.title = "A long event with a plain title" }
                let request = CalendarNativeEventAdapter.request(paint: paint, size: size, paintHeight: size.height,
                    desktop: true, showsIcon: !CommandLine.arguments.contains("--no-symbols"), environment: environment)
                let bitmap = try FrozenEventRaster.render(frozen(request), maximumBytes: 64 * 1024 * 1024)
                let reference = CommandLine.arguments.contains("--composited-reference") ? drawCanvas(request, image: bitmap) : bitmap
                let start = DispatchTime.now().uptimeNanoseconds
                let candidate = drawCanvas(request)
                let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                precondition(reference.width == candidate.width && reference.height == candidate.height)
                // Compare active RGBA pixels independently of any row alignment padding.
                let a = reference.dataProvider!.data! as Data, b = candidate.dataProvider!.data! as Data
                var differences = 0, maximumDelta = 0
                var examples: [[String: Int]] = []
                for y in 0..<reference.height {
                    for x in 0..<reference.width*4 {
                        let delta = abs(Int(a[y*reference.bytesPerRow+x])-Int(b[y*candidate.bytesPerRow+x]))
                        if delta != 0 {
                            differences += 1; maximumDelta = max(maximumDelta, delta)
                            if examples.count < 12 { examples.append(["x":x/4,"y":y,"channel":x%4,"delta":delta]) }
                        }
                    }
                }
                let required = CalendarNativeEventCanvas.required(size: size, scale: 2, maximumImageBytes: 2*1024*1024)
                precondition(required == (reference.width * reference.height * 4 > 2*1024*1024))
                rows.append(["width":size.width,"height":size.height,"state":state,"directRequired":required,
                    "differentBytes":differences,"maximumDelta":maximumDelta,"captureMS":duration,"examples":examples])
                if differences != 0 {
                    let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("canvas-\(Int(size.width))-\(Int(size.height))-\(state).png") as CFURL,
                        UTType.png.identifier as CFString, 1, nil)!
                    CGImageDestinationAddImage(destination, candidate, nil); precondition(CGImageDestinationFinalize(destination))
                }
            }
        }
        let failures = rows.filter { ($0["differentBytes"] as! Int) != 0 }.count
        try JSONSerialization.data(withJSONObject:["cases":rows,"pixelFailures":failures,"arguments":CommandLine.arguments,
            "scope":"Frozen bitmap vs actual Canvas proxy, captured with ImageRenderer only in this test. Not live frame or backing-store memory acceptance."],options:[.prettyPrinted,.sortedKeys])
            .write(to:output.appendingPathComponent("results.json"))
        print("Direct drawing: \(rows.count) cases, \(failures) pixel failures")
        if failures > 0 { exit(1) }
    }
}
