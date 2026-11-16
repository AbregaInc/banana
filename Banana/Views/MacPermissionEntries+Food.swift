#if os(macOS) && BANANA_MODULE_FOOD
import Photos

extension MacPermissionGuide {
    func photoPermissionEntry() -> MacPermissionEntry {
        MacPermissionEntry(id: .photos, title: "Photos", symbol: "photo", read: {
            MealPhotoScanner.shared.refreshAccess()
            return switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
            case .authorized: .allowed
            case .notDetermined: .requestable
            case .restricted: .restricted
            default: .settings
            }
        }, request: { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) })
    }
}
#endif
