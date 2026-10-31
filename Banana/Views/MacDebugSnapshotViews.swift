#if DEBUG && os(macOS)
import SwiftUI

/// Named views the headless snapshot harness can render:
/// `--snapshot-app-store <out.png> --snapshot-view <name>`. It draws into an offscreen window,
/// so it works with the screen locked — the only way to check a Mac view nobody is looking at.
enum MacDebugSnapshotViews {
    @MainActor
    static func view(named name: String, smart: SmartScheduleStore) -> AnyView? {
        switch name {
        case "menu-bar": return AnyView(MenuBarAgendaPreview(smart: smart))
        case "command-menu": return AnyView(MacCommandMenu().padding(40))
        case "shortcuts": return AnyView(MacShortcutsSheet())
        case "availability": return AnyView(AvailabilitySheet())
        case "availability-panel": return AnyView(MacAvailabilityPanel().frame(width: 320))
        case "inspector":
            let start = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date()
            var meeting = MeetingInfo(start: start, end: start.addingTimeInterval(45 * 60), coordinate: nil,
                                      address: nil, isVirtual: true,
                                      title: "Quarterly planning review with product and design",
                                      joinURL: URL(string: "https://meet.google.com/abc-defg-hij"), platform: .meet)
            meeting.myResponse = .needsAction
            return AnyView(HStack(spacing: 0) {
                Color(nsColor: .textBackgroundColor)
                Divider()
                MacEventInspectorView(meeting: meeting).frame(width: 350)
            })
        case "inspector-travel":
            // With `--ui-audit --travel-sample`: an in-person event whose place is a guess.
            let swim = smart.todayMeetings.first { $0.title == "Lap Swim" }
                ?? MeetingInfo(start: Date().addingTimeInterval(3 * 3600), coordinate: nil,
                               address: "Chelsea", isVirtual: false, title: "Lap Swim")
            return AnyView(HStack(spacing: 0) {
                Color(nsColor: .textBackgroundColor)
                Divider()
                MacEventInspectorView(meeting: swim).frame(width: 350)
            })
        case "meal-editor":
            // With `--ui-audit`: the review sheet the Mac's "What did you eat?" and a meal click open.
            let meal = WellnessStore.shared.meals.first { $0.items.count > 1 }
                ?? MealEntry(items: [MealItem(name: "Eggs", serving: "2 large", macros: .init(calories: 156))])
            return AnyView(FoodTextCaptureView(editing: meal).frame(width: 520, height: 640))
        case "supplement-editor":
            let supplement = WellnessStore.shared.supplements.first
                ?? SupplementSchedule(name: "Vitamin D", dose: "1 capsule", hour: 8, minute: 0)
            return AnyView(MacSupplementEditor(supplement: supplement, onDelete: {}).frame(width: 520, height: 640))
        case "place-picker":
            return AnyView(PlacePickerView(locationText: "Chelsea", context: "Lap Swim at 7:45 PM"))
        case "calendar-picker":
            return AnyView(ScrollView { WriteBackCalendarPicker().padding(24) }
                .frame(width: 420, height: 520)
                .environmentObject(smart)
                .task {
                    // After the picker's own refresh on appear, which finds no calendars here.
                    try? await Task.sleep(for: .milliseconds(300))
                    CalendarWriteBack.shared.injectPreviewCalendars([
                        .init(id: "a", title: "Sam", sourceTitle: "bo@zeta.example"),
                        .init(id: "b", title: "Work", sourceTitle: "bo@zeta.example"),
                        .init(id: "c", title: "Sam", sourceTitle: "bo@acme.example"),
                        .init(id: "d", title: "Family", sourceTitle: "bo@acme.example", isOwner: false),
                    ])
                    smart.injectPreviewCalendarColors(["a": "#4285F4", "b": "#0B8043", "c": "#F4511E", "d": "#8E24AA"])
                })
        case "player":
            return AnyView(MacPlayerPreviewHost().frame(width: 480, height: 720))
        case "workout-charts":
            return AnyView(MacChartsPreviewHost().frame(width: 720, height: 900))
        case "mail":
            // The sample mail at the harness's width, which chooses its columns. `--mail-open`,
            // `--mail-cursor`, `--mail-place`, `--mail-pane off` and `--mail-state done`
            // (MailSession+App) pick the state.
            return AnyView(MailSection().toastHost())
        case "undo-toast":
            ToastCenter.shared.showPreview("Deleted \u{201C}Client review\u{201D}")
            return AnyView(ToastView())
        default: return nil
        }
    }
}
/// The full player on a sample episode, no audio.
private struct MacPlayerPreviewHost: View {
    @EnvironmentObject private var library: PodcastLibrary
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        NowPlayingView()
            .task {
                library.injectSampleForPreview()
                if let podcast = library.podcasts.first, let episode = podcast.ordered().first {
                    player.loadForPreview(episode, in: podcast)
                }
            }
    }
}

/// The detail charts (heart rate, zones, speed…) for the sample ride.
private struct MacChartsPreviewHost: View {
    @State private var workout: FitnessSessionSummary?

    var body: some View {
        ScrollView {
            if let workout {
                WorkoutChartsSection(workout: workout, cursorT: .constant(nil))
                    .padding(24)
            }
        }
        .task {
            await FitnessStore.shared.whenLoaded()
            FitnessStore.shared.injectSampleForPreview()
            workout = FitnessStore.shared.summaries.first
        }
    }
}
#endif
