#if os(iOS)
// AlarmKit AppIntents — the Lock Screen stop button.

import AppIntents
import AlarmKit

/// Runs when the user taps **Stop** on the alarm — including from the Lock Screen
/// with the app not open. A `LiveActivityIntent` runs in the app's process
/// (background-launching it if needed), so it can start the wake audio without
/// foregrounding the app.
struct WakeStopIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Alarm & Wake"
    static let description = IntentDescription("Stops the alarm and starts your wake podcast or music.")

    @Parameter(title: "Alarm ID") var alarmID: String

    init() {}
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        Log.wake.notice("WakeStopIntent: Stop for alarm \(alarmID, privacy: .public)")
        if let uuid = UUID(uuidString: alarmID) {
            try? AlarmManager.shared.stop(id: uuid)
        }
        await WakeCoordinator.shared.startWake(reason: "stopIntent")
        return .result()
    }
}

/// Secondary alarm button: just open the app (the on-open path then starts the wake).
struct WakeOpenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Banana"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        Log.wake.notice("WakeOpenIntent: Open")
        return .result()
    }
}
#endif
