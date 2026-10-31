import EventKit
import Foundation
import UserNotifications
#if os(iOS)
import UIKit
import WatchConnectivity
#endif

/// How this copy is set up, for the day's usage counts (`Telemetry.Signal.Setup`): how many
/// calendars and accounts, which permissions, how much of each thing is in use. Each fact is its
/// own count, in ranges. Signed-in batches are also retained against the account; health/food
/// inventory is excluded.
@MainActor
enum TelemetryState {
    static func signals(now: Date = Date()) async -> [Telemetry.Signal] {
        typealias S = Telemetry.Signal
        let google = GoogleCalendarService.shared
        var out: [S] = [
            .setup(.googleAccounts, count: google.accounts.count),
            .setup(.calendars, count: google.calendars.count),
            .setup(.busyBlocks, CalendarWriteBack.shared.enabled ? .on : .off),
            .setup(.reminders, permission(EKEventStore.authorizationStatus(for: .reminder))),
            .setup(.location, location(LocationAccess.shared.standing)),
            .setup(.appleIntelligence, Intelligence.current.deviceAvailable ? .on : .off),
            .setup(.routines, count: RoutineStore.shared.routines.filter(\.enabled).count),
            .setup(.podcasts, count: WakeCoordinator.shared.library.podcasts.count),
            .setup(.notes, count: VoiceNoteStore.shared.notes.count),
        ]
        // Which modules are on: what people choose to have Banana look after.
        let modules = ModuleStore.shared.choice
        out += [
            .setup(.allModules, modules.isEverything ? .on : .off),
            .setup(.workoutsModule, modules.includes(.workouts) ? .on : .off),
            .setup(.foodModule, modules.includes(.food) ? .on : .off),
            .setup(.notesModule, modules.includes(.notes) ? .on : .off),
            .setup(.podcastsModule, modules.includes(.podcasts) ? .on : .off),
        ]
        // Asked of the notification service, which can take its time (a minute, once, in the
        // Simulator): two seconds, or the fact is left out today.
        if let answer = await notifications() { out.append(.setup(.notifications, answer)) }
        out += [S.setup(.os, code: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)),
                S.setup(.region, code: Locale.current.region?.identifier ?? ""),
                S.setup(.language, code: Locale.current.language.languageCode?.identifier ?? "")].compactMap { $0 }
        #if os(iOS)
        if WCSession.isSupported(), WCSession.default.activationState == .activated {
            out.append(.setup(.watch, WCSession.default.isPaired ? .paired : .none))
        }
        out.append(.setup(.textSize, textSize(UIApplication.shared.preferredContentSizeCategory)))
        out.append(.setup(.appearance, UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light))
        #endif
        return out
    }

    private static func permission(_ status: EKAuthorizationStatus) -> Telemetry.Signal.Answer {
        switch status {
        case .notDetermined: .notAsked
        case .fullAccess, .authorized: .granted
        default: .denied
        }
    }

    private static func notifications() async -> Telemetry.Signal.Answer? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let once = Once()
        return await withCheckedContinuation { (finished: CheckedContinuation<Telemetry.Signal.Answer?, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                guard once.first() else { return }
                switch settings.authorizationStatus {
                case .notDetermined: finished.resume(returning: .notAsked)
                case .denied: finished.resume(returning: .denied)
                default: finished.resume(returning: .granted)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if once.first() { finished.resume(returning: nil) }
            }
        }
    }

    private static func location(_ standing: LocationUse.Standing) -> Telemetry.Signal.Answer {
        switch standing {
        case .allowed: .granted
        case .refused: .denied
        case .notAsked, .unknown: .notAsked
        }
    }

    #if os(iOS)
    private static func textSize(_ size: UIContentSizeCategory) -> Telemetry.Signal.Answer {
        if size.isAccessibilityCategory { return .accessibility }
        if size == .large { return .standard }
        return size < .large ? .smaller : .larger
    }
    #endif
}
