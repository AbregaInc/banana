#if os(macOS)
import EventKit
import UserNotifications
import Photos
#if BANANA_MODULE_PODCASTS
import MusicKit
#endif

extension MacPermissionGuide {
    func show(onboarding: OnboardingStore, selected: SystemSettingsLink? = nil) {
        var entries: [MacPermissionEntry] = [
            MacPermissionEntry(id: .reminders, title: "Reminders", symbol: "checklist", read: {
                let status = EKEventStore.authorizationStatus(for: .reminder)
                if onboarding.remindersStatus != status { onboarding.refreshEventKitAuthorization() }
                if OccurrenceStore.shared.remindersAuthorized != (status == .fullAccess) {
                    Task { await OccurrenceStore.shared.syncRemindersAuthorization() }
                }
                switch status {
                case .fullAccess: return .allowed
                case .notDetermined: return .requestable
                case .restricted: return .restricted
                default: return .settings
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
        if selected == .music {
            entries.append(MacPermissionEntry(id: .music, title: "Media & Apple Music", symbol: "music.note", read: {
                let status = MusicAuthorization.currentStatus
                let music = WakeCoordinator.shared.music
                if music.authorization != status { Task { await music.syncAuthorization() } }
                return switch status {
                case .authorized: .allowed
                case .notDetermined: .requestable
                case .restricted: .restricted
                default: .settings
                }
            }, request: { _ = await MusicAuthorization.request() }))
        }
        #endif
        #if BANANA_MODULE_FOOD
        if selected == .photos {
            entries.append(MacPermissionEntry(id: .photos, title: "Photos", symbol: "photo", read: {
                MealPhotoScanner.shared.refreshAccess()
                return switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
                case .authorized: .allowed
                case .notDetermined: .requestable
                case .restricted: .restricted
                default: .settings
                }
            }, request: { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }))
        }
        #endif
        show(entries: entries, selected: selected)
    }
}
#endif
