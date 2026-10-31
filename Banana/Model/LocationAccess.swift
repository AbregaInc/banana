import Combine
import CoreLocation

/// The one place that knows whether Banana may use the person's location, and the one place
/// that asks.
///
/// It never reads the permission by calling into the system on the main thread. That read is a
/// call to another process, and `OnboardingStore` made it while the app was still building its
/// first screen: when the location service was slow to answer, Banana sat on a blank screen until
/// it did (over four minutes in the Simulator after a restart, 9 Oct 2026). The system tells a
/// location manager its standing by itself, when the manager is made and whenever the answer
/// changes; this waits for that.
@MainActor
final class LocationAccess: NSObject, ObservableObject {
    static let shared = LocationAccess()

    /// `.notDetermined` until the system has spoken; `standing` says which of the two it is.
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    @Published private(set) var standing: LocationUse.Standing = .unknown

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private override init() {
        super.init()
        manager.delegate = self
    }

    /// Show the system's question. Only ever called from something the person pressed.
    func ask() {
        manager.requestWhenInUseAuthorization()
    }

    /// Ask the system again where things stand, off the main thread, for the moments the answer
    /// may have changed without word of it arriving: just after its question was answered, and
    /// on coming back to the front. (In one Simulator run the answer was given and no callback
    /// came; the page that had asked sat on "Asking…".) The read is a call to another process,
    /// which is why it is never made on the main thread.
    func recheck() {
        nonisolated(unsafe) let manager = manager
        Task.detached(priority: .userInitiated) {
            let status = manager.authorizationStatus
            await MainActor.run { LocationAccess.shared.heard(status) }
        }
    }

    /// The standing once the system has reported it, or `.unknown` if it hasn't within `patience`
    /// seconds: a caller in the background goes without sooner than hold anything up.
    func settled(patience: Double = 5) async -> LocationUse.Standing {
        guard standing == .unknown else { return standing }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(patience))
                self?.release()
            }
        }
        return standing
    }

    private func release() {
        let continuations = waiting
        waiting = []
        continuations.forEach { $0.resume() }
    }

    static func standing(for status: CLAuthorizationStatus) -> LocationUse.Standing {
        switch status {
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .refused
        case .authorizedAlways, .authorizedWhenInUse: return .allowed
        @unknown default: return .notAsked
        }
    }

    private func heard(_ status: CLAuthorizationStatus) {
        if self.status != status { self.status = status }
        let standing = Self.standing(for: status)
        if self.standing != standing { self.standing = standing }
        release()
    }
}

extension LocationAccess: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read here, where the system has just delivered it, never on demand.
        let status = manager.authorizationStatus
        Task { @MainActor in self.heard(status) }
    }
}
