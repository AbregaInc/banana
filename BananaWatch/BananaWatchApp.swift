import SwiftUI
import WidgetKit
import AppIntents
import WatchKit

@main
struct BananaWatchApp: App {
    @WKApplicationDelegateAdaptor(WorkoutRecoveryDelegate.self) private var appDelegate
    @StateObject private var recorder = WorkoutRecorder.shared
    @StateObject private var episodes = WatchEpisodeStore.shared
    @StateObject private var audio = WatchAudioPlayer.shared
    @StateObject private var downloader = WatchDownloadManager.shared
    @StateObject private var remote = WatchPhoneRemote.shared
    @StateObject private var workoutPlans = WatchWorkoutPlanStore.shared

    init() {
        HealthFileProtection.protectApplicationPreferences()
        let recovered = DiagnosticJournal.shared.startProcessSession(attributes: [
            "app": "BananaWatch",
            "version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        ])
        WatchSyncManager.shared.activate()
        if !recovered.isEmpty {
            WatchSyncManager.shared.queueDiagnosticSnapshot(
                reason: "recovered_incomplete_operation")
        }
        // Nudge the system to (re)index our App Shortcut so "Record Voice Note" shows up for the
        // Action Button, and force the watch-face complication to re-render — a placed complication
        // caches its last drawing (the old blank one), so a fixed extension won't repaint on its own.
        //
        // Once per installed build, not per launch: the complication is static and the shortcut
        // set doesn't change at runtime, so repeating this XPC work on every cold start (including
        // background relaunches for finished downloads) bought nothing.
        //
        // The stamp is the binary's own modification time, NOT CFBundleVersion — the project pins
        // versions ("1"/"1.0" forever on a sideloaded build), so a version-keyed stamp would mean
        // "once per install" and a future shortcut/complication fix would silently never apply.
        let mtime = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]) }?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let stamp = String(Int(mtime))
        if UserDefaults.standard.string(forKey: "launchReloadStamp") != stamp {
            BananaShortcuts.updateAppShortcutParameters()
            WidgetCenter.shared.reloadAllTimelines()
            UserDefaults.standard.set(stamp, forKey: "launchReloadStamp")
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(recorder)
                .environmentObject(episodes)
                .environmentObject(audio)
                .environmentObject(downloader)
                .environmentObject(remote)
                .environmentObject(workoutPlans)
        }
        .backgroundTask(.urlSession(WatchDownloadManager.sessionIdentifier)) {
            await WatchDownloadManager.shared.awaitBackgroundEvents()
        }
    }
}
