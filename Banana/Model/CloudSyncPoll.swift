import Foundation

/// Keeps every sync current while the app is open: once a minute, one small request asks iCloud
/// which zones changed (`CloudChangeCheck`), and only those are fetched. An idle minute is one
/// nearly empty round trip.
///
/// On the phone and iPad nothing here runs in the background: while playing in a pocket, progress
/// still only moves at pause and stop. What can't wait for the app to open — a meal the Mac found,
/// to ask about — comes by push, for its zone alone (`MealBacklogWake`). On the Mac it runs for as
/// long as the app does, window or not: started with the app's other duties (`BananaApp.wireUp`),
/// since a Mac app can be running with no window to start it from.
@MainActor
enum CloudSyncPoll {
    private static var timer: Timer?
    private static var checking = false
    /// Every sync has started (`BananaApp.wireUp`). Until then nothing is asked: the answer names
    /// a changed zone once, and one named before its sync existed was never fetched
    /// (`CloudPollRules`).
    private static var syncsStarted = false
    static let interval: TimeInterval = 60

    /// The syncs are up: ask now, if the poll is running.
    static func syncsHaveStarted() {
        syncsStarted = true
        guard timer != nil else { return }
        Task { await checkNow() }
    }

    /// Whether this process may talk to iCloud at all. An unsigned Mac build has no container
    /// entitlement, and CloudKit ends the process for making a container rather than failing:
    /// every such launch died here, a second in, since this poll was written. `--disable-icloud`
    /// is the preview routes' and the tests' own switch.
    static var isAllowed: Bool {
        AppCloud.mayUseCloud(arguments: ProcessInfo.processInfo.arguments, entitled: AppCloud.hasContainerEntitlement)
    }

    /// The app came to the front: check now, then every minute.
    static func resume() {
        guard isAllowed else { return }
        Task { await checkNow() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await checkNow() }
        }
    }

    /// The app went to the background.
    static func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// Asks what changed, and fetches only that.
    static func checkNow() async {
        guard CloudPollRules.mayAsk(allowed: isAllowed, syncsStarted: syncsStarted, checking: checking) else { return }
        checking = true
        defer { checking = false }
        let changed = await CloudChangeCheck.changedZones()
        if CloudControlsSync.shared.needsRefresh(changedZones: changed) { CloudControlsSync.shared.refresh() }
        if CloudControlsSync.meals.needsRefresh(changedZones: changed) { CloudControlsSync.meals.refresh() }
        if CloudWellnessSync.shared.needsRefresh(changedZones: changed) { CloudWellnessSync.shared.refresh() }
        if CloudFitnessSync.shared.needsRefresh(changedZones: changed) { CloudFitnessSync.shared.refresh() }
        if CloudProgressSync.shared.needsRefresh(changedZones: changed) {
            CloudProgressSync.shared.flushNow(reason: "poll")
        }
    }
}
