#if DEBUG
import Foundation
import SwiftUI

/// `--verify-cpu --cpu-audio <path>` — play a real episode from the real library, with the real UI
/// up, so the host can measure what this process actually costs per second of playback.
///
/// iOS killed the app on a walk for burning 100% CPU over 48 seconds (a background audio app is
/// allowed 80% over 60). The sampled stack was SwiftUI/AttributeGraph re-evaluating view bodies
/// with the screen off and nobody looking. The suspect is the 1 Hz playback tick: it calls
/// `library.updateProgress`, which writes into `@Published var podcasts` — a 1,211-episode
/// catalogue — so all nine views observing the library re-run their bodies once a second, forever.
///
/// I have already been wrong about this bug twice by reasoning instead of measuring, and once by
/// measuring the wrong thing (foreground, empty library). So: real catalogue, real view tree, real
/// playback, and a number.
enum CPUVerification {

    static func runIfRequested() {
        // `--perf-selftest` — burn a core on purpose. If PerfWatchdog doesn't catch THIS, its
        // silence on the phone would mean nothing, and I'd be trusting a broken instrument.
        if ProcessInfo.processInfo.arguments.contains("--perf-selftest") {
            Thread.detachNewThread {
                let until = Date().addingTimeInterval(12)
                var x = 0.0
                while Date() < until { x += sqrt(Double.random(in: 1...2)) }
                print("[cpu] selftest burn done (\(x))")
            }
        }
        guard ProcessInfo.processInfo.arguments.contains("--verify-cpu") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))   // let the real UI come up first
            start()
        }
    }

    @MainActor
    private static func start() {
        let library = WakeCoordinator.shared.library
        let player = WakeCoordinator.shared.player
        let downloads = WakeCoordinator.shared.downloads

        guard let podcast = library.podcasts.max(by: { $0.episodeCount < $1.episodeCount }),
              let episode = podcast.episodes.first else {
            print("[cpu] EMPTY LIBRARY — seed podcasts.json into the container first")
            return
        }
        let total = library.podcasts.reduce(0) { $0 + $1.episodeCount }
        print("[cpu] library: \(library.podcasts.count) podcasts, \(total) episodes")

        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--cpu-audio"), i + 1 < args.count {
            let src = URL(fileURLWithPath: args[i + 1])
            if downloads.debugRegisterDownload(episodeID: episode.id, file: src) != nil {
                print("[cpu] registered a local file for \"\(episode.title)\"")
            }
        }
        player.play(episode, in: podcast)
        print("[cpu] PLAYING — measure the process now")
    }
}
#endif
