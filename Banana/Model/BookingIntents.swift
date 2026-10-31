import AppIntents
import Foundation

/// The booking link from Siri, Spotlight and Shortcuts (docs/design/BOOKING.md §12, "The host"), on
/// iPhone, iPad and Mac. With no handle yet, the suggested one is taken as the link is handed over,
/// as the calendar's Share button does.
struct CopyBookingLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy My Booking Link"
    static var description = IntentDescription("Copies the link people use to book a time with you.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let url = try await BookingLinkIntentSupport.link()
        BookingCenter.copy(url.absoluteString)
        BookingCenter.shared.shared(url)
        return .result(value: url, dialog: "Copied \(BookingHandle.display(url)).")
    }
}

/// The link as a value, for a shortcut to hand to Share, Messages or Mail.
struct ShareBookingLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Share My Booking Link"
    static var description = IntentDescription("Your booking link, to send to someone.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        let url = try await BookingLinkIntentSupport.link()
        BookingCenter.shared.shared(url)
        return .result(value: url, dialog: "\(BookingHandle.display(url))")
    }
}

enum BookingLinkIntentSupport {
    struct NoLink: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource { "Connect Google Calendar in Banana first." }
    }

    /// The link, asking the service first when this device has never heard it.
    @MainActor
    static func link() async throws -> URL {
        let center = BookingCenter.shared
        if center.shareURL == nil { await center.refresh() }
        guard center.isAvailable, let url = center.shareURL else { throw NoLink() }
        return url
    }
}

#if os(macOS)
/// The Mac's ready-made shortcuts (the iPhone's are `BananaPhoneShortcuts`).
struct BananaMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CopyBookingLinkIntent(),
            phrases: ["Copy my \(.applicationName) booking link", "Copy my booking link in \(.applicationName)"],
            shortTitle: "Copy Booking Link",
            systemImageName: "link")
        AppShortcut(
            intent: ShareBookingLinkIntent(),
            phrases: ["Share my \(.applicationName) booking link", "Share my booking link in \(.applicationName)"],
            shortTitle: "Share Booking Link",
            systemImageName: "square.and.arrow.up")
    }
}
#endif
