import Foundation

/// Whether Mail's outgoing store held work to send when the engine last looked: a send, an
/// edited draft, a queued action or a sender-policy change. A launch reads this from the
/// defaults, opens nothing, and starts Mail's engine only when it is set, so what was queued
/// before the app was closed goes out without Mail being opened. The engine sets it whenever
/// delivery is woken and writes what the store says after each delivery pass. A pass that never
/// finished leaves it set, and the next launch finishes the work.
enum MailOutgoingMirror {
    static let key = "mailOutgoingWork"

    static func isSet(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func record(_ waiting: Bool, in defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: key) != waiting else { return }
        defaults.set(waiting, forKey: key)
    }
}
