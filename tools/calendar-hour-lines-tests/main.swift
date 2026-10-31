import SwiftUI
import AppKit

@main
struct CalendarHourLineChecks {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/calendar-hour-lines")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0
        for width in [172.0, 215.5, 900.0] {
            for scale in [1.0, 2.0, 3.0] {
                for dark in [false, true] {
                    var captures: [CGImage] = []
                    for canvas in [false, true] {
                        let content = CalendarHourLines(hourHeight: 58,
                            hourColor: .primary.opacity(0.09), halfHourColor: .primary.opacity(0.035), usesCanvas: canvas)
                            .frame(width: width, height: 1392).clipped()
                            .background(dark ? Color.black : Color.white)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = scale
                        guard let image = renderer.cgImage else { fatalError("No rendered grid pixels") }
                        captures.append(image)
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        try bitmap.representation(using: .png, properties: [:])!.write(to:
                            output.appendingPathComponent("grid-\(width)-\(scale)-\(dark)-\(canvas).png"))
                    }
                    let first = captures[0], second = captures[1]
                    guard first.width == second.width && first.height == second.height &&
                          first.dataProvider!.data! as Data == second.dataProvider!.data! as Data else {
                        fatalError("Grid pixels differ: width \(width), scale \(scale), dark \(dark)")
                    }
                    checks += 1
                }
            }
        }
        try JSONSerialization.data(withJSONObject: ["checks": checks, "scope": "Offscreen decorative-grid pixel equivalence; not UI latency"], options: .prettyPrinted)
            .write(to: output.appendingPathComponent("checks.json"))
        print("PASS: \(checks) exact grid image comparisons")
    }
}
