import Foundation

/// When Banana may use where the person is.
///
/// The rule is one line: something Banana does by itself (a forecast as the plan loads) never
/// shows the system's location question. It appeared a second after a new person first saw the
/// app, before they had asked for weather or anything else. The question is shown from a button
/// the person pressed: the Location row of the setup list, "Use current location", or a feature
/// they switched on. Until then the day is shown without weather.
enum LocationUse {
    /// What the system has said so far.
    enum Standing: Equatable {
        /// Not heard from the system yet this launch.
        case unknown
        case notAsked
        case allowed
        /// Refused, or restricted on this device: only the Settings app can change it.
        case refused
    }

    enum Step: Equatable {
        case fetch
        /// Go without. Never "ask".
        case nothing
    }

    /// What a need Banana has on its own may do.
    static func unprompted(_ standing: Standing) -> Step {
        standing == .allowed ? .fetch : .nothing
    }
}
