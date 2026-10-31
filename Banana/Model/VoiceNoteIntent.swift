#if os(iOS)
import AppIntents

/// iPhone-side twin of the Watch's Record Voice Note intent.
///
/// The Apple Watch Ultra Action Button can only be bound to a *Shortcut* (a workflow), not a raw
/// App Shortcut — and Shortcuts are authored on the iPhone, where a watch-only action never appears.
/// So the watch intent alone was un-bindable: you could run it from the watch Shortcuts app but not
/// assign it to the button. Declaring the same-named intent here makes "Record Voice Note" show up in
/// the iPhone Shortcuts app under Banana, so you can build a Shortcut around it and point the Action
/// Button at that. It shares the type name (and thus the App Intents identifier) with the watch intent
/// so Shortcuts can treat them as one action across the paired apps.
struct RecordVoiceNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Voice Note"
    static var description = IntentDescription("Start or stop a Banana voice note. Ideal on the Action Button.")

    // Bring the app forward so the recording UI (and the first-run mic prompt) can show.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = VoiceNoteStore.shared
        if store.isRecording {
            store.finishCapture()
        } else if store.justEndedByInterruption {
            // Asking Siri to stop takes the audio first, which already ended the note; this is
            // that stop, not a request for a new note.
        } else {
            store.beginCapture()
        }
        return .result()
    }
}

/// Surfaces the intents as ready-made App Shortcuts in the iPhone Shortcuts app, and as
/// Siri phrases. Every phrase must contain `\(.applicationName)` — Siri requires the app
/// name to disambiguate, and a phrase without it is silently dropped.
///
/// This is the layer that makes Banana controllable by voice on hardware Apple Intelligence
/// will not run on (see BananaIntents.swift).
struct BananaPhoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordVoiceNoteIntent(),
            phrases: ["Record a note in \(.applicationName)", "New \(.applicationName) note"],
            shortTitle: "Record Voice Note",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: WhatsNextIntent(),
            phrases: ["What's next in \(.applicationName)", "\(.applicationName) what's next"],
            shortTitle: "What's Next",
            systemImageName: "arrow.right.circle.fill")
        AppShortcut(
            intent: DaySummaryIntent(),
            phrases: ["What's on in \(.applicationName)", "\(.applicationName) my day"],
            shortTitle: "What's On",
            systemImageName: "sun.max.fill")
        AppShortcut(
            intent: CreateTaskIntent(),
            phrases: ["Add a task to \(.applicationName)", "New \(.applicationName) task"],
            shortTitle: "Add Task",
            systemImageName: "checklist")
        AppShortcut(
            intent: StartRoutineIntent(),
            phrases: ["Start a routine in \(.applicationName)", "Start \(\.$routine) in \(.applicationName)"],
            shortTitle: "Start Routine",
            systemImageName: "play.circle.fill")
        AppShortcut(
            intent: CompleteTaskIntent(),
            phrases: ["Complete a task in \(.applicationName)", "Tick off a \(.applicationName) task"],
            shortTitle: "Complete Task",
            systemImageName: "checkmark.circle.fill")
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
