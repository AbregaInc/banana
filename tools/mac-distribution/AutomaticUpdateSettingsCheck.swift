import Foundation
import Sparkle

/// Exercises the pinned Sparkle settings implementation without opening the app,
/// contacting a feed, or touching the installed app's preferences.
@main
struct AutomaticUpdateSettingsCheck {
    @MainActor static func main() throws {
        let path = CommandLine.arguments[1]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var info = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let domain = "org.example.banana.updater-check." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain + ".app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        info["CFBundleIdentifier"] = domain
        info["SUDefaultsDomain"] = domain
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = Bundle(url: root)!
        let settings = SPUUpdaterSettings(hostBundle: bundle)
        precondition(settings.automaticallyChecksForUpdates)
        precondition(settings.automaticallyDownloadsUpdates)
        precondition(settings.updateCheckInterval == 21600)
        precondition(!settings.sendsSystemProfile)
        settings.automaticallyDownloadsUpdates = false
        settings.automaticallyChecksForUpdates = false
        let reopened = SPUUpdaterSettings(hostBundle: bundle)
        precondition(!reopened.automaticallyChecksForUpdates, "A saved opt-out must survive reopening")
        precondition(!reopened.automaticallyDownloadsUpdates)
        reopened.automaticallyChecksForUpdates = true
        reopened.automaticallyDownloadsUpdates = true
        let enabled = SPUUpdaterSettings(hostBundle: bundle)
        precondition(enabled.automaticallyChecksForUpdates && enabled.automaticallyDownloadsUpdates)
        print("PASS: automatic defaults, six-hour interval, saved opt-out and re-enable; no system profiling")
    }
}
