import SwiftUI
#if os(iOS)
import UIKit
#endif

/// "Find meal photos automatically", where it starts, and whether to ask — a `Section` for a Form
/// or List. One synced setting with the same controls on the iPhone, iPad and Mac
/// (docs/design/ADAPTIVE-LAYOUT.md, rule 5). Every device with full Photos access looks
/// (`MealPhotoScanner`) — the Mac most, on power — and the line under the switch says how it's
/// going here and which other devices are looking.
struct MealPhotoScanSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var scanner = MealPhotoScanner.shared
    @ObservedObject private var reports = MealPhotoScanReports.shared
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @Environment(\.openURL) private var openURL

    private var onHub: Bool { DeviceRole.current.isHub }
    private var isMac: Bool { DeviceRole.current == .mac }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Toggle(isOn: Binding(
                    get: { settings.mealPhotoScanEnabled },
                    // Turning it on asks for Photos access straight away (the scanner hears it).
                    set: { settings.setMealPhotoScan($0) }
                )) {
                    Label("Find meal photos automatically", systemImage: "photo.on.rectangle.angled")
                }
                .formControls()
                statusLines
            }
            if settings.mealPhotoScanEnabled {
                DatePicker(selection: since, in: ...Date(), displayedComponents: .date) {
                    Label("Starting from", systemImage: "calendar")
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Toggle(isOn: Binding(
                        get: { settings.mealPhotoAskEnabled },
                        set: { on in
                            settings.mealPhotoAskEnabled = on
                            #if os(iOS)
                            if on, onHub { Task { await MealPhotoNotifications.requestPermissionIfUndecided() } }
                            #endif
                        }
                    )) {
                        Label("Ask about new meal photos", systemImage: "bell.badge")
                    }
                    .formControls()
                    if !onHub {
                        Text("Notifications on your iPhone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Meal photos")
        } footer: {
            Text(isMac
                 ? "Photos of food and drinks taken since the start date become meals to log, each asking what it was. The Mac does most of the looking, on power; with iCloud Photos it sees your iPhone\u{2019}s photos too."
                 : "Photos of food and drinks taken since the start date become meals to log, each asking what it was. Screenshots are skipped. While your Mac keeps up, this \(onHub ? "iPhone" : "iPad") looks only at recent photos.")
        }
        .onAppear { scanner.refreshAccess() }
        #if os(iOS)
        // Photos access changes in Settings, outside the app.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scanner.refreshAccess() }
        }
        #endif
    }

    /// "Checked 5 min ago · 3 meals found" for this device, then "Also looking: Mac, 2 min ago" —
    /// redrawn each minute while on screen, so the times stay true.
    @ViewBuilder private var statusLines: some View {
        if settings.mealPhotoScanEnabled {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    if let line = MealPhotoScanStatusText.line(enabled: true, report: scanner.report, isMac: isMac,
                                                               checking: scanner.isChecking, now: context.date) {
                        Text(line)
                    }
                    if let others = MealPhotoScanStatusText.others(reports.all, except: MealInboxStore.installID,
                                                                   now: context.date) {
                        Text(others)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if scanner.access == .denied || scanner.access == .limited, let url = settingsURL {
                Button(isMac ? "Open Privacy Settings" : "Open Settings") { openURL(url) }
                    // Only the button, not the whole row with the switch in it.
                    .buttonStyle(.inline)
            }
        }
    }

    private var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")
        #endif
    }

    /// "Starting from": a day, kept as its start.
    private var since: Binding<Date> {
        Binding(
            get: { settings.mealPhotoScan.effectiveSince() },
            set: { settings.mealPhotoScanSince = Calendar.current.startOfDay(for: $0) }
        )
    }
}
