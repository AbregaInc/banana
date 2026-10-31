#if DEBUG
import Foundation

/// `--verify-download <url>` — start a real download through the real DownloadManager, and narrate
/// it. `--verify-download-check <url>` re-launches and reports whether the file arrived.
///
/// The claim being tested is the whole reason for a background session: a download must survive the
/// app being suspended or killed outright. The old `.default` session died with the process, so an
/// episode you queued and then pocketed the phone on simply never arrived — and an episode you don't
/// have is an episode you stream, which is what stalled and stopped the audio this morning.
///
/// So the test is not "does a download work". It's "does a download survive being killed".
enum DownloadVerification {

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--verify-download"), i + 1 < args.count,
           let url = URL(string: args[i + 1]) {
            Task { @MainActor in await start(url) }
        }
        if let i = args.firstIndex(of: "--verify-download-check"), i + 1 < args.count,
           let url = URL(string: args[i + 1]) {
            Task { @MainActor in await check(url) }
        }
        if let i = args.firstIndex(of: "--verify-peer-provider"), i + 1 < args.count {
            let file = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in await runPeerProvider(file: file) }
        }
        if let i = args.firstIndex(of: "--verify-peer-client"), i + 1 < args.count,
           let url = URL(string: args[i + 1]) {
            Task { @MainActor in await runPeerClient(sourceURL: url) }
        }
    }

    /// A stable synthetic episode so both launches agree on the identity.
    private static func episode(_ url: URL) -> Episode {
        Episode(id: "verify-download-episode", title: "Background Download Test",
                audioURL: url, pubDate: Date(), duration: 1049)
    }
    private static var podcast: Podcast {
        var p = Podcast(feedURL: URL(string: "https://example.com/feed")!, title: "Verification Feed")
        p.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!   // stable across launches
        return p
    }

    private static func peerEpisode(_ url: URL) -> Episode {
        Episode(
            id: "verify-peer-episode",
            title: "LAN Cache Verification",
            audioURL: url,
            pubDate: Date(),
            duration: 60
        )
    }

    /// Run on one device with a local audio fixture. Pair it with `--verify-peer-client` on the
    /// other device, passing any identical URL (an intentionally invalid URL proves no web fetch
    /// could have produced the received file).
    @MainActor
    private static func runPeerProvider(file: URL) async {
        let downloads = WakeCoordinator.shared.downloads
        guard FileManager.default.fileExists(atPath: file.path),
              downloads.debugRegisterDownload(
                episodeID: "verify-peer-episode",
                file: file
              ) != nil else {
            print("[peer] ❌ provider fixture unavailable: \(file.path)")
            return
        }
        downloads.startPeerSharing()
        print("[peer] PROVIDER READY — leave this process running")
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)) }
    }

    @MainActor
    private static func runPeerClient(sourceURL: URL) async {
        let downloads = WakeCoordinator.shared.downloads
        downloads.delete("verify-peer-episode")
        downloads.download(peerEpisode(sourceURL), podcast: podcast, allowCellular: true)
        print("[peer] client requesting synthetic episode for \(sourceURL.absoluteString)")
        for tick in 0..<12 {
            try? await Task.sleep(for: .seconds(1))
            if let local = downloads.localURL(for: "verify-peer-episode") {
                let size = ((try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.intValue ?? 0
                print("[peer] ✅ RECEIVED LOCAL FILE in \(tick + 1)s (\(size) bytes)")
                return
            }
        }
        print("[peer] ❌ NO LOCAL FILE — inspect peer audio diagnostics for discovery/auth/fallback")
    }

    @MainActor
    private static func start(_ url: URL) async {
        let downloads = WakeCoordinator.shared.downloads
        let ep = episode(url)
        print("[dl] starting background download of \(url.absoluteString)")
        downloads.download(ep, podcast: podcast, allowCellular: true)

        for tick in 0..<40 {
            try? await Task.sleep(for: .seconds(1))
            let state = downloads.state(ep.id)
            let local = downloads.localURL(for: ep.id)
            print("[dl] \(tick)s  state=\(describe(state))  file=\(local?.lastPathComponent ?? "—")")
            if case .downloaded = state { print("[dl] DONE in-process"); return }
        }
        print("[dl] still running — kill the app now and re-launch with --verify-download-check")
    }

    /// The real question: after the process was killed mid-transfer, did the system finish the job
    /// and hand us the file on relaunch?
    @MainActor
    private static func check(_ url: URL) async {
        let downloads = WakeCoordinator.shared.downloads
        let ep = episode(url)
        print("[dl] === relaunched. did the download survive being killed? ===")
        for tick in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            let state = downloads.state(ep.id)
            if let local = downloads.localURL(for: ep.id) {
                let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0
                print("[dl] ✅ SURVIVED — file present after \(tick)s: \(local.lastPathComponent) (\(size) bytes)")
                return
            }
            print("[dl] \(tick)s  state=\(describe(state))  (no file yet)")
        }
        print("[dl] ❌ NOT DELIVERED — the download did not survive")
    }

    private static func describe(_ s: DownloadManager.State) -> String {
        switch s {
        case .none: return "none"
        case .waitingForWiFi: return "waiting for Wi-Fi (system holding it)"
        case .downloading(let f): return String(format: "downloading %.0f%%", f * 100)
        case .downloaded: return "downloaded"
        case .failed: return "failed"
        }
    }
}
#endif
