import Foundation

/// Features that are built and switched off: every way in is hidden on every device, and the
/// code and any data already saved stay, so one can come back by changing its line here.
enum Features {
    /// Guided plans — the workout builder, a plan's exercises, the set-by-set coach, and the
    /// Watch's guided workout. Off since 8 Oct 2026: seventeen exercises drawn as stick figures
    /// from hand-typed poses, a builder that returns the same plan for the same answers, and a
    /// finished session that was saved and shown nowhere. It had been used once.
    static let guidedPlans = false
}
