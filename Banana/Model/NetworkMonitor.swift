import Foundation
import Network

/// Is the phone on cellular right now?
///
/// Episode downloads are large (50–150 MB each, and "Download all older" is many of them). Automatic,
/// rule-driven downloads wait for Wi-Fi; a download you explicitly tap can use cellular, but only
/// after you've been told it will.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// True when the only path out is cellular (or the system flags the link as expensive —
    /// which also covers a personal hotspot).
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false   // Low Data Mode
    @Published private(set) var isOnline = true

    /// Called when Wi-Fi comes back, so anything parked can start.
    var onWiFiAvailable: (() -> Void)?

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasExpensive = self.isExpensive
                self.isOnline = path.status == .satisfied
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
                if wasExpensive && !self.isExpensive && self.isOnline {
                    self.onWiFiAvailable?()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.boris.banana.network"))
    }

    /// Cheap network: on Wi-Fi (or wired), and not in Low Data Mode.
    var isCheap: Bool { isOnline && !isExpensive && !isConstrained }
}
