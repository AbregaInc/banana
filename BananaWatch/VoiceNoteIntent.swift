import AppIntents

/// Record a voice note from the Apple Watch Ultra's Action Button.
///
/// Bind it in Settings → Action Button → Shortcut → Banana → Record Voice Note. A press starts the
/// recording (pausing whatever's playing), the next press stops it — the same toggle the on-screen
/// button uses — so on a run you never look at the watch: press, talk, press.
struct RecordVoiceNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Voice Note"
    static var description = IntentDescription("Start or stop a Banana voice note. Ideal on the Action Button.")

    // Bring the app forward so the recording UI (and the mic authorization, first time) can show.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchVoiceRecorder.shared.toggle()
        return .result()
    }
}

/// Surfaces the intent to the system so it appears in the Action Button's Shortcut picker.
struct BananaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordVoiceNoteIntent(),
            phrases: ["Record a note in \(.applicationName)", "New \(.applicationName) note"],
            shortTitle: "Record Voice Note",
            systemImageName: "mic.fill")
    }
}
