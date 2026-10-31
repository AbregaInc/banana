#if DEBUG && os(macOS)
import AppKit
import Darwin
import SwiftUI

/// Headless visual verification for the real Mac cue editor.
///
/// Run the Debug app with:
///   --snapshot-routine-editor /tmp/banana-routine-editor.png
///
/// The app presents the same `RoutineEditorView` used by the sheet at the sheet's exact
/// 500×620 pt size, captures the real AppKit window backing store, writes a PNG, then
/// terminates. This catches intrinsic-width and clipping regressions that a successful
/// Swift compile cannot. It intentionally does not use `ImageRenderer`: AppKit-backed
/// controls inside a navigation hierarchy can render blank through that parallel path.
@MainActor
struct MacRoutineEditorSnapshotHarness: View {
    @EnvironmentObject private var routines: RoutineStore
    @EnvironmentObject private var library: PodcastLibrary
    @EnvironmentObject private var smart: SmartScheduleStore

    let outputURL: URL
    @State private var didCapture = false
    @State private var showingEditor = false

    private var sample: Routine {
        Routine(
            name: "Sleep",
            icon: "moon.zzz.fill",
            color: .indigo,
            triggerKind: .manual,
            autonomy: .manual,
            sourceLabel: "Get Sleepy: Sleep meditation and stories",
            musicItem: MusicWakeItem(
                kind: .playlist,
                id: "snapshot",
                title: "Get Sleepy: Sleep meditation and stories",
                subtitle: nil
            ),
            sleepTimerMinutes: 45,
            group: .evening
        )
    }

    private var editor: some View {
        RoutineEditorView(draft: sample, isNew: false)
            .environmentObject(routines)
            .environmentObject(library)
            .environmentObject(smart)
            .frame(width: 500, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)
    }

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .frame(minWidth: 900, minHeight: 700)
            .sheet(isPresented: $showingEditor) {
                editor
            }
            .onAppear {
                showingEditor = true
            }
            .task {
                guard !didCapture else { return }
                didCapture = true
                // Capture the actual presented hierarchy after SwiftUI and AppKit have both
                // completed layout. Select the attached sheet, not its parent app window.
                try? await Task.sleep(for: .milliseconds(1_000))
                guard let window = NSApp.windows.first(where: {
                          $0.isVisible && $0.sheetParent != nil
                      }) ?? NSApp.keyWindow,
                      let contentView = window.contentView,
                      // Navigation titles and toolbar buttons live in AppKit's frame view,
                      // outside `contentView`. Capturing only the latter made a correct sheet
                      // look as though its title and button labels were clipped.
                      let view = contentView.superview ?? window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    fputs("routine editor snapshot failed\n", stderr)
                    NSApp.terminate(nil)
                    return
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    fputs("routine editor snapshot encoding failed\n", stderr)
                    NSApp.terminate(nil)
                    return
                }
                do {
                    try png.write(to: outputURL, options: .atomic)
                    fputs("routine editor snapshot: \(outputURL.path)\n", stderr)
                } catch {
                    fputs("routine editor snapshot write failed: \(error)\n", stderr)
                }
                // This process exists solely to produce the requested artifact. A sheet can
                // defer normal application termination while its presentation transaction is
                // active, so exit only after the atomic PNG write has completed.
                exit(EXIT_SUCCESS)
            }
    }
}
#endif
