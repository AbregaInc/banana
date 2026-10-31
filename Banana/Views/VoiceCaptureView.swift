#if os(iOS)
import SwiftUI

/// The recording overlay — deliberately big and dumb, because you're using it while running with
/// the phone in a pocket or from a glance. One giant Stop target, a live level ring so you can tell
/// it's actually hearing you, and the timer. Whatever context was captured shows at the top so you
/// trust the note will remember where you were.
struct VoiceCaptureView: View {
    @ObservedObject var store = VoiceNoteStore.shared
    @ObservedObject var recorder = VoiceNoteStore.shared.recorder

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            if let ctx = capturedContext, let anchor = ctx.anchorLine {
                VStack(spacing: 6) {
                    Text("Recording a note about").font(.footnote).foregroundStyle(.secondary)
                    Text(anchor).font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                }
                .padding(.horizontal, DS.Space.xxl)
            } else {
                Text("Recording a note").font(.headline)
            }

            // A ring that pulses with your voice — proof it's listening.
            ZStack {
                Circle().stroke(DS.Palette.danger.opacity(DS.Tint.fill), lineWidth: 6).frame(width: 180, height: 180)
                Circle()
                    .stroke(DS.Palette.danger, lineWidth: 6)
                    .frame(width: 120 + CGFloat(recorder.level) * 90,
                           height: 120 + CGFloat(recorder.level) * 90)
                    .animation(.easeOut(duration: 0.08), value: recorder.level)
                Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(DS.Palette.danger)
            }

            Text(timeString(recorder.elapsed))
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())

            Spacer()

            Button(role: .destructive) { store.finishCapture() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.primaryPage)
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()   // don't let a swipe drop a live recording
    }

    /// The context of the in-flight note (pulled from the store's pending snapshot via the newest
    /// note isn't right — it's not saved yet — so read it off the recorder's live capture).
    private var capturedContext: VoiceNote.Context? { store.liveContext }

    private func timeString(_ s: TimeInterval) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}
#endif
