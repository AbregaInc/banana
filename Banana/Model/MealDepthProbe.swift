#if os(iOS) || os(macOS)
import Foundation
import Photos

/// `--depth-probe`: what the depth in the newest library photos that have some measures, on a real
/// device — one "🔬 depth" line per photo in playback.log. Changes nothing. Whether a Portrait
/// photo's depth is in metres or only relative, whether its edited version keeps it, how its lens
/// is described: only real files can say, and this is how they're checked
/// (docs/design/MEAL-LEARNING.md §8). Runs in Release builds too.
enum MealDepthProbe {
    /// Photos with depth to report on, and how many of the newest to look through for them.
    static let wanted = 20
    static let looked = 200

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--depth-probe") else { return }
        Task.detached(priority: .utility) { await run() }
    }

    private static func log(_ text: String) { PlaybackDiagnostics.shared.log("🔬 depth", text) }

    private static func run() async {
        try? await Task.sleep(for: .seconds(8))   // after launch has settled
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #if os(iOS)
        let readable = status == .authorized || status == .limited
        #else
        let readable = status == .authorized
        #endif
        guard readable else {
            log("no Photos access (status \(status.rawValue)): nothing to look at")
            return
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = looked
        #if os(iOS)
        options.includeAssetSourceTypes = [.typeUserLibrary]
        #endif
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        log("looking through the newest \(assets.count) photos for \(wanted) with depth")
        var found = 0, portraits = 0
        for index in 0..<assets.count {
            if found >= wanted || Task.isCancelled { break }
            let asset = assets.object(at: index)
            let portrait = asset.mediaSubtypes.contains(.photoDepthEffect)
            if portrait { portraits += 1 }
            // Portrait photos come from iCloud when they must; any other is read only when it's here.
            guard let current = await MealPhotoLibraryReader.imageData(for: asset, network: portrait) else {
                if portrait { log("\(when(asset)) Portrait: couldn't read the photo") }
                continue
            }
            var version = "as edited"
            var map = MealPhotoDepth.read(from: current)
            if map == nil, portrait, let original = await MealPhotoLibraryReader.imageData(for: asset, version: .original) {
                version = "original (the edited one has none)"
                map = MealPhotoDepth.read(from: original)
            }
            guard let map else {
                if portrait {
                    found += 1
                    log("\(when(asset)) Portrait: no depth map in either version")
                }
                continue
            }
            found += 1
            log("\(when(asset)) \(portrait ? "Portrait" : "photo"), \(version): \(MealPhotoDepth.summary(map)) \u{2014} \(outcome(map))")
        }
        log("done: \(found) with depth, \(portraits) Portrait, among the newest \(assets.count)")
    }

    /// The measurement, or why there's none — and for a relative map, what it would say if its
    /// numbers were metres, to see how far from real sizes it is.
    static func outcome(_ map: MealPhotoDepth.DepthMap) -> String {
        let attempt = MealPhotoDepth.attempt(map)
        guard !map.isAbsolute else { return attempt.note }
        var asMetres = map
        asMetres.isAbsolute = true
        return "\(attempt.note) (taken as metres: \(MealPhotoDepth.attempt(asMetres).note))"
    }

    private static func when(_ asset: PHAsset) -> String {
        asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "undated"
    }
}
#endif
