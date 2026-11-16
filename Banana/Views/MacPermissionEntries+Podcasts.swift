#if os(macOS) && BANANA_MODULE_PODCASTS
import MusicKit

extension MacPermissionGuide {
    func musicPermissionEntry() -> MacPermissionEntry {
        MacPermissionEntry(id: .music, title: "Media & Apple Music", symbol: "music.note", read: {
            let status = MusicAuthorization.currentStatus
            let music = WakeCoordinator.shared.music
            if music.authorization != status { Task { await music.syncAuthorization() } }
            return switch status {
            case .authorized: .allowed
            case .notDetermined: .requestable
            case .restricted: .restricted
            default: .settings
            }
        }, request: { _ = await MusicAuthorization.request() })
    }
}
#endif
