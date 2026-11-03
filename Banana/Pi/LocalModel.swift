#if os(macOS) && PI_DEVELOPMENT
import Foundation

/// Banana Pi's model files on the Mac, kept by the app itself: nothing to install or set up.
///
/// The pinned files (`pi-local-model.json`: repo, revision, each file's size and SHA-256) are
/// fetched from Hugging Face into Application Support on first launch and checked. The app's own
/// Python and Locals (Contents/Resources/PiRuntime) run them (`MacLocalInference`). Until they
/// are ready, Pi uses Apple's on-device model. There is nothing to press: the only sign of it is
/// the line in Settings › Assistant (`statusLine`). See docs/design/PI-LOCAL-MODEL.md.
@MainActor
final class LocalModel: ObservableObject {
    static let shared = LocalModel()

    enum State: Equatable {
        case missing
        case downloading(received: Int64, total: Int64)
        case verifying
        case ready
        case failed(String)
    }

    typealias Manifest = PinnedModelFiles.Manifest

    @Published private(set) var state: State = .missing
    let manifest: Manifest?
    private var started = false

    private init() {
        manifest = Bundle.main.url(forResource: "pi-local-model", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    /// Called at launch: if the files are here and checked, the model is ready; otherwise they
    /// are fetched in the background. Safe to call again.
    func start() {
        guard !started, let manifest else { return }
        started = true
        // A few file sizes and a stamp: answered now, so Pi's first start already knows.
        if PinnedModelFiles.isChecked(manifest, in: PinnedModelFiles.folder(for: manifest)) { state = .ready; return }
        Task { await prepare(manifest) }
    }

    /// "Qwen3.5 4B · on this Mac", "Getting Qwen3.5 4B · 1.2 of 3.1 GB", or what's wrong.
    var statusLine: String {
        let name = manifest?.name ?? "Local model"
        switch state {
        case .missing: return "Apple Intelligence · on this Mac"
        case .downloading(let received, let total):
            let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000_000) }
            return "Getting \(name) · \(gb(received)) of \(gb(total)) GB"
        case .verifying: return "Checking \(name)…"
        case .ready: return "\(name) · on this Mac"
        case .failed(let reason): return "\(name) couldn’t be set up: \(reason)"
        }
    }

    // MARK: - The files

    private func prepare(_ manifest: Manifest) async {
        let folder = PinnedModelFiles.folder(for: manifest)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if PinnedModelFiles.isChecked(manifest, in: folder) { state = .ready; return }
            try await download(manifest, into: folder)
            state = .verifying
            try await PinnedModelFiles.verify(manifest, in: folder)
            try PinnedModelFiles.stamp(manifest, in: folder)
            state = .ready
        } catch is CancellationError {
            state = .missing
        } catch {
            state = .failed(error.localizedDescription)
            // Passing trouble (no network, a sleep mid-download) is tried again later, quietly.
            Task {
                try? await Task.sleep(for: .seconds(300))
                started = false
                start()
            }
        }
    }

    private func download(_ manifest: Manifest, into folder: URL) async throws {
        let total = manifest.totalBytes
        var done: Int64 = manifest.files.reduce(0) { sum, entry in
            PinnedModelFiles.size(of: folder.appendingPathComponent(entry.key)) == entry.value.bytes ? sum + entry.value.bytes : sum
        }
        state = .downloading(received: done, total: total)
        for (name, file) in manifest.files.sorted(by: { $0.value.bytes < $1.value.bytes }) {
            let target = folder.appendingPathComponent(name)
            guard PinnedModelFiles.size(of: target) != file.bytes else { continue }
            guard let url = URL(string: "https://huggingface.co/\(manifest.repo)/resolve/\(manifest.revision)/\(name)") else { continue }
            let base = done
            let progress = DownloadProgress { [weak self] received in
                Task { @MainActor in self?.state = .downloading(received: base + received, total: total) }
            }
            let (temporary, response) = try await URLSession.shared.download(from: url, delegate: progress)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw PinnedModelFailure("Hugging Face answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(name)")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            done += file.bytes
            state = .downloading(received: done, total: total)
        }
    }

}

/// Reports a download's bytes as they arrive.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
#endif
