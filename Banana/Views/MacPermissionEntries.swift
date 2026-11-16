#if os(macOS)
import EventKit
import UserNotifications

extension MacPermissionGuide {
    func show(onboarding: OnboardingStore, selected: SystemSettingsLink? = nil) {
        var entries: [MacPermissionEntry] = [
            MacPermissionEntry(id: .reminders, title: "Reminders", symbol: "checklist", read: {
                let status = EKEventStore.authorizationStatus(for: .reminder)
                if onboarding.remindersStatus != status { onboarding.refreshEventKitAuthorization() }
                if OccurrenceStore.shared.remindersAuthorized != (status == .fullAccess) {
                    Task { await OccurrenceStore.shared.syncRemindersAuthorization() }
                }
                if status == .restricted { return .restricted }
                // EventKit can still report notDetermined after a real denial.
                // Honor the same remembered refusal as the existing setup checklist.
                return switch onboarding.remindersState(authorized: status == .fullAccess) {
                case .done: .allowed
                case .todo: .requestable
                case .refused, .asked: .settings
                }
            }, request: {
                _ = await onboarding.requestReminders()
                await OccurrenceStore.shared.syncRemindersAuthorization()
            }),
            MacPermissionEntry(id: .location, title: "Location Services", symbol: "location", read: {
                guard LocationAccess.shared.standing != .unknown else { return .checking }
                if onboarding.locationGranted { return .allowed }
                if onboarding.locationStatus == .notDetermined { return .requestable }
                return onboarding.locationStatus == .restricted ? .restricted : .settings
            }, request: { onboarding.requestLocation() }),
            MacPermissionEntry(id: .notifications, title: "Notifications", symbol: "bell", read: {
                let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                if onboarding.notifStatus != status { onboarding.notifStatus = status }
                switch status {
                case .authorized, .provisional: return .allowed
                case .notDetermined: return .requestable
                default: return .settings
                }
            }, request: { _ = await NotificationService.requestAuthorization() })
        ]
        #if BANANA_MODULE_PODCASTS
        if selected == .music { entries.append(musicPermissionEntry()) }
        #endif
        #if BANANA_MODULE_FOOD
        if selected == .photos { entries.append(photoPermissionEntry()) }
        #endif
        show(entries: entries, selected: selected)
    }
}
#endif
