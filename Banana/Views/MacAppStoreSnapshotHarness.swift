#if DEBUG && os(macOS)
import AppKit
import Darwin
import SwiftUI

/// Captures the real Mac window backing store without relying on `screencapture`.
///
/// This keeps App Store generation deterministic even while the login session is locked:
/// AppKit lays out the shipping view hierarchy, then the harness writes its backing store
/// directly and exits.
@MainActor
struct MacAppStoreSnapshotHarness: View {
    let outputURL: URL
    @State private var didCapture = false

    var body: some View {
        MacRootView()
            .frame(minWidth: 1120, minHeight: 780)
            .task {
                guard !didCapture else { return }
                didCapture = true
                try? await Task.sleep(for: .milliseconds(1_500))

                guard let window = NSApp.keyWindow ?? NSApp.windows.first,
                      let contentView = window.contentView,
                      let view = contentView.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    fputs("App Store snapshot failed: no renderable Mac window\n", stderr)
                    exit(EXIT_FAILURE)
                }

                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    fputs("App Store snapshot failed: PNG encoding\n", stderr)
                    exit(EXIT_FAILURE)
                }

                do {
                    try FileManager.default.createDirectory(
                        at: outputURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try png.write(to: outputURL, options: .atomic)
                    fputs("App Store snapshot: \(outputURL.path)\n", stderr)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("App Store snapshot failed: \(error)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            }
    }
}
#endif
