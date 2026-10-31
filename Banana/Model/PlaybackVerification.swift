#if DEBUG
import Foundation
import AVFoundation

/// `--verify-stall <url>` — play a *streamed* episode and narrate what the player does when the
/// stream dies underneath it.
///
/// This is the walk, reproduced on a desk: a podcast streaming over a link that goes away and
/// comes back. The interesting question is not whether it stalls — it will — but whether playback
/// is still dead five minutes later. Run it, kill the HTTP server serving the URL mid-playback,
/// bring the server back, and read the transcript: `stalled → recovery attempt N → recovered`
/// means a walk through a tunnel costs you a few seconds instead of the rest of the episode.
enum PlaybackVerification {

    static func runIfRequested() {
        if ProcessInfo.processInfo.arguments.contains("--verify-stall") { Task { @MainActor in await run() } }
        if ProcessInfo.processInfo.arguments.contains("--verify-seek") { Task { @MainActor in await seekTest() } }
    }

    /// `--verify-seek <local audio path>` — play, jump far ahead, and log the playhead. Before the
    /// fix the reported time bounced back to the old position for seconds; after, it lands and holds.
    @MainActor
    private static func seekTest() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--verify-seek"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        let player = PlayerController()
        let ep = Episode(id: "seek-test", title: "Seek Test", audioURL: url, pubDate: Date(), duration: 1049)
        var pod = Podcast(feedURL: url, title: "Seek Feed"); pod.episodes = [ep]
        player.play(ep, in: pod)
        try? await Task.sleep(for: .seconds(2))
        say("=== seek test: jumping 30s → 800s ===")
        player.seek(to: 800)
        for tick in 0..<20 {
            try? await Task.sleep(for: .milliseconds(250))
            say("[\(Double(tick) * 0.25)s] playhead=\(String(format: "%.1f", player.currentTime))")
        }
        say("=== done — playhead must reach ~800 and never fall back below it ===")
    }

    @MainActor
    private static func run() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--verify-stall"), i + 1 < args.count,
              let url = URL(string: args[i + 1]) else {
            say("usage: --verify-stall <http url to an audio file>")
            return
        }

        say("=== stall/recovery verification ===")
        say("stream: \(url.absoluteString)")
        PlaybackDiagnostics.shared.clear()

        let player = PlayerController()
        let episode = Episode(id: "verify-stall-episode",
                              title: "Stall Verification",
                              audioURL: url,
                              pubDate: Date(),
                              duration: 300)
        var podcast = Podcast(feedURL: url, title: "Verification Feed")
        podcast.episodes = [episode]

        player.play(episode, in: podcast, autoSleepEligible: false)

        // Narrate once a second for three minutes: long enough to kill the server, watch the
        // stall, restart it, and see whether we come back on our own.
        var lastTime = -1.0
        var stalledSince: Int?
        for tick in 0..<180 {
            try? await Task.sleep(for: .seconds(1))
            let t = player.currentTime
            let status = player.debugSummary
            let moving = t > lastTime + 0.05
            if !moving && player.isPlaying {
                if stalledSince == nil { stalledSince = tick }
            } else if moving, let since = stalledSince {
                say("[\(tick)s] RECOVERED after \(tick - since)s of silence — \(status)")
                stalledSince = nil
            }
            if tick % 5 == 0 || !moving {
                say("[\(tick)s] \(moving ? "playing" : "SILENT ") \(status)")
            }
            lastTime = t
        }

        say("")
        say("=== playback journal ===")
        say(PlaybackDiagnostics.shared.read())
        say("=== done ===")
    }

    /// stdout for the console, and a file the host can pull out of the simulator container.
    private static func say(_ line: String) {
        print(line)
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("verify.log")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
