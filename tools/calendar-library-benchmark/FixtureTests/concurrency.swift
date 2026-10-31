import Foundation

@main
struct DevicePixelProbeChecks {
    @MainActor static func main() async throws {
        let config = CalendarFixtureConfiguration()
        let report = await RasterConcurrencyProbe.run(store: FixtureStore(config), width: 393, scale: 3)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: config.value("--output", "/tmp/calendar-raster-pixels.json")))
        print("Concurrent pixel probe: \(report["status"]!), \(report["checks"]!) checks")
        if report["status"] as? String != "passed" { exit(1) }
    }
}
