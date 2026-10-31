import SwiftUI

/// Start a routine now: play what it plays. The same button wherever a routine is shown — its
/// row in Routines, and its sheet on the plan — on the phone, the iPad and the Mac. (The only
/// one was on the retired Today screen, so nothing could be started by hand.)
struct RoutineStartButton: View {
    let routine: Routine
    /// The ▶ on a row. Otherwise a labelled row saying what it plays.
    var compact = false
    var onStart: (() -> Void)? = nil
    @EnvironmentObject private var library: PodcastLibrary
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var music: MusicController

    var body: some View {
        let summary = RoutineStart.summary(of: routine, library: library)
        if compact {
            // A routine with nothing to play has no button: its row already says "Not set".
            if summary != nil {
                Button(action: start) {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .iconButton()
                .tint(DS.Palette.accent)
                .accessibilityLabel("Start \(routine.name)")
                .help(summary ?? "")
            }
        } else if let summary {
            Button(action: start) {
                Label {
                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        Text("Start now")
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                } icon: {
                    Image(systemName: "play.fill")
                }
            }
            .accessibilityIdentifier("cueSheet.start")
        } else {
            Label(RoutineWording.nothingToPlay, systemImage: "speaker.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func start() {
        RoutineStart.start(routine, library: library, player: player, music: music)
        ToastCenter.shared.notify("Started \(routine.name)")
        onStart?()
    }
}
