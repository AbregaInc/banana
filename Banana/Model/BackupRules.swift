import Foundation

/// The rules of the iCloud backup that can be stated without iCloud. Pure, for tests.
enum BackupRules {
    // MARK: What a backup carries of the app's settings

    /// Settings keys that belong to one installation and are no use, or actively wrong, on
    /// another: AlarmKit ids name alarms in one phone's daemon, a sync engine's saved state
    /// belongs to one local database, a playback-alive breadcrumb from the old phone reads as a
    /// crash on the new one.
    static let operationalKeys: Set<String> = [
        "cloudBackupHash", "cloudBackupDate", "cloudBackupNeeded", "cloudBackupInitialRestoreOfferShown",
        "playbackAlive", "playbackAliveAt", "playbackAlivePodcastID",
        "playbackAliveEpisodeID", "playbackAlivePosition",
        "continuedTranscriptionJobs", "transcribeFailCounts", "launchReloadStamp",
        "slotAlarmIDs", "smartAlarmIDs", "wakeAlarmTimes", "lastAlertAt", "consumedAlertAt",
        "alarmAuthWasAuthorized", "calendarLastFullPassAt",
        "cloudProgressParked", "cloudProgressByEpisodeRead.v1", "cloudNotesUseCloudKitIndex",
        "healthRemovalRequestsHandled.v1", "anchoredTiming.rungAt",
        "workoutHealthFollow.pending.v1", "fitness.editMarksMigrated",
    ]

    /// Every sync engine keeps its state under one of these. Only the podcast-progress engine's
    /// two keys were listed, so the settings, workout, nutrition and controls engines' state rode
    /// along in a backup and was written over a restoring device's own.
    static let operationalPrefixes = ["ckSyncEngine.", "mealsPush.", "fitnessCloud."]

    static func isOperational(_ key: String) -> Bool {
        operationalKeys.contains(key) || operationalPrefixes.contains { key.hasPrefix($0) }
    }

    /// The settings a backup holds.
    static func portable(_ domain: [String: Any]) -> [String: Any] {
        domain.filter { !isOperational($0.key) }
    }

    /// The settings after a restore: the backup's, and this installation's own operational state
    /// left exactly as it was. (A restore replaced the whole set, so that state was either the
    /// other device's or gone.) Onboarding done here stays done.
    static func restored(from backup: [String: Any], over current: [String: Any]) -> [String: Any] {
        var result = portable(backup)
        for (key, value) in current where isOperational(key) { result[key] = value }
        if current["onboardingCompleted"] as? Bool == true { result["onboardingCompleted"] = true }
        return result
    }

    // MARK: What the Settings row says

    /// The status line when nothing has happened this session: when it was last backed up. It
    /// read "Not backed up yet" after every launch, however recent the backup.
    static func restingStatus(lastBackup: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let lastBackup else { return "Not backed up yet" }
        let time = lastBackup.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(lastBackup, inSameDayAs: now) { return "Backed up today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(lastBackup, inSameDayAs: yesterday) {
            return "Backed up yesterday at \(time)"
        }
        return "Backed up \(lastBackup.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }

    /// Where a backup came from, in words for the restore question. The older container's was
    /// called "Quarters migration", the app's name before it was Banana.
    static func sourceName(_ source: String?) -> String {
        guard let source else { return "iCloud" }
        return source.replacingOccurrences(of: "Quarters migration", with: "earlier Banana")
    }
}
