import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Reads the local incident journal, automatically received Watch snapshots, and the specialized
/// playback log without requiring Xcode or a tethered device.
struct PlaybackLogView: View {
    @State private var visibleText = ""
    @State private var visibleLineCount = 0
    @State private var fullText = ""
    @State private var totalLineCount = 0
    @State private var loading = true
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if loading {
                    ProgressView("Loading log…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if visibleText.isEmpty {
                    Text("(nothing logged yet)")
                        .foregroundStyle(.secondary)
                } else {
                    if totalLineCount > visibleLineCount {
                        Text("Showing the latest \(visibleLineCount) of \(totalLineCount) lines. Copy includes the full log.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                    // One bounded text layout and one selection context. Rendering hundreds of
                    // independently selectable Text nodes made this screen slow on every device.
                    Text(visibleText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)   // the interesting lines are the last ones
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(copied ? "Copied" : "Copy") {
                    #if os(iOS)
                    UIPasteboard.general.string = fullText
                    #else
                    Clipboard.copy(fullText)
                    #endif
                    copied = true
                }
                .disabled(loading || fullText.isEmpty)
                Menu {
                    ShareLink(item: fullText) {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                    }
                    .disabled(loading || fullText.isEmpty)
                    Button("Clear", role: .destructive) {
                        PlaybackDiagnostics.shared.clear()
                        DiagnosticJournal.shared.clearEvents()
                        visibleText = ""
                        visibleLineCount = 0
                        fullText = ""
                        totalLineCount = 0
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        loading = true
        async let playbackSnapshot = PlaybackDiagnostics.shared.snapshot()
        async let diagnosticText = Task.detached(priority: .utility) {
            DiagnosticJournal.shared.readExportText()
        }.value
        let playback = await playbackSnapshot
        let diagnostics = await diagnosticText
        let combined = """
        \(diagnostics)

        # Playback journal
        \(playback.fullText)
        """
        let lines = combined.split(
            separator: "\n",
            omittingEmptySubsequences: false).map(String.init)
        let visible = Array(lines.suffix(350))
        visibleText = visible.joined(separator: "\n")
        visibleLineCount = visible.count
        fullText = combined
        totalLineCount = lines.count
        loading = false
    }
}
