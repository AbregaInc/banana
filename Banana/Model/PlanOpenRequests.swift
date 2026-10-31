import Foundation

/// Something to show on the Plan, asked for from outside it (a booking push's tap). Kept until a
/// Plan takes it, so a launch made by the tap still gets there.
///
/// A Plan hears a request through `$pending`, which publishes in `willSet`: the value it is handed
/// is the new one, while `pending` still holds the old one. So a Plan takes the value it was handed,
/// on the main actor once the change has landed, with `take(_:)`: it gets it only while it is still
/// the one pending, so one Plan opens it and a later request isn't mistaken for it.
@MainActor
final class PlanOpenRequests: ObservableObject {
    static let shared = PlanOpenRequests()
    @Published var pending: BananaService.BookingPushTarget?

    /// True when `target` was still pending and is now this caller's to open.
    func take(_ target: BananaService.BookingPushTarget) -> Bool {
        guard pending == target else { return false }   // another Plan took it, or a newer one came
        pending = nil
        return true
    }
}
