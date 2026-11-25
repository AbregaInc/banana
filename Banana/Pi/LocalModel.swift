#if BANANA_AI
#if os(macOS)
import Foundation

/// Banana Pi's model files on the Mac, kept by the app itself: nothing to install or set up.
///
/// A signed catalog chooses a compatible model. The bundled pin is the offline default.
/// The app stages replacements beside the active model and adopts them on the next launch.
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
    private(set) var manifest: Manifest?
    private(set) var modelDirectory: URL?
    private let bundled: Manifest?
    private var started = false
    private var restoration: Task<Void, Never>?

    private init() {
        bundled = Bundle.main.url(forResource: "pi-local-model", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        manifest = bundled
    }

    func start() {
        guard !started else { return }
        started = true
        #if PI_DEVELOPMENT
        let host: String? = nil
        #else
        let host = BananaService.host
        #endif
        let channel = AppModule.isBetaBuild ? "beta" : "production"
        let folder = AppSupport.directory.appendingPathComponent("ModelCatalog-\(channel)", isDirectory: true)
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
        let memory = ProcessInfo.processInfo.physicalMemory
        let bundled = self.bundled
        let restore = Task {
            let saved = await Task.detached(priority: .utility) {
                ModelCatalog.file(named: "last-ready.json", in: folder)
                    .flatMap { ModelCatalog.verify($0, channel: channel) }
                    .flatMap { listing in
                        listing.models.first { entry in
                            entry.supports(build: build, memory: memory)
                                && Self.catalogInstall(entry.pin, bundled: bundled).checked
                        }?.pin
                    }
            }.value
            if state != .ready {
                if let saved {
                    manifest = saved
                    modelDirectory = Self.catalogInstall(saved, bundled: bundled).folder
                    state = .ready
                } else if let bundled, PinnedModelFiles.isChecked(bundled, in: PinnedModelFiles.folder(for: bundled)) {
                    manifest = bundled
                    modelDirectory = PinnedModelFiles.folder(for: bundled)
                    state = .ready
                }
            }
        }
        restoration = restore
        Task {
            await restore.value
            if let host, let (catalog, signed) = await ModelCatalog.refresh(host: host, channel: channel, in: folder) {
                let match = await Task.detached(priority: .utility) {
                    catalog.models.first(where: {
                        $0.supports(build: build, memory: memory) && Self.canInstall($0.pin, bundled: bundled)
                    })?.pin
                }.value
                guard let candidate = match else { return }
                let install = Self.catalogInstall(candidate, bundled: bundled)
                if await prepare(candidate, in: install.folder, allowLegacy: install.isBundled) {
                    await Task.detached(priority: .utility) {
                        try? ModelCatalog.save(signed, as: "last-ready.json", in: folder)
                    }.value
                }
            } else if state != .ready, let bundled {
                await prepare(bundled, in: PinnedModelFiles.folder(for: bundled), allowLegacy: true)
            }
        }
    }

    /// Wait for the existing local pin only. Assistant never waits for the catalog or weights.
    func waitForRestoredModel() async {
        start()
        await restoration?.value
    }

    nonisolated private static func catalogInstall(_ manifest: Manifest, bundled: Manifest?) -> (folder: URL, isBundled: Bool, checked: Bool) {
        let isBundled = manifest.verificationStamp == bundled?.verificationStamp
        let folder = isBundled ? PinnedModelFiles.folder(for: manifest) : PinnedModelFiles.catalogFolder(for: manifest)
        return (folder, isBundled, PinnedModelFiles.isChecked(manifest, in: folder, allowLegacy: isBundled))
    }

    nonisolated private static func canInstall(_ manifest: Manifest, bundled: Manifest?) -> Bool {
        let (folder, _, checked) = catalogInstall(manifest, bundled: bundled)
        if checked { return true }
        let remaining = manifest.files.reduce(Int64(0)) { sum, entry in
            let size = PinnedModelFiles.size(of: folder.appendingPathComponent(entry.key))
            return sum + (size == entry.value.bytes ? 0 : entry.value.bytes)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let available = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return false }
        return available >= remaining + (1 << 30)
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

    @discardableResult
    private func prepare(_ candidate: Manifest, in folder: URL, allowLegacy: Bool) async -> Bool {
        let isReplacement = state == .ready
        if !isReplacement {
            manifest = candidate
            modelDirectory = folder
        }
        let report: @MainActor @Sendable (State) -> Void = { [weak self] state in
            if !isReplacement { self?.state = state }
        }
        do {
            if !PinnedModelFiles.isChecked(candidate, in: folder, allowLegacy: allowLegacy) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await download(candidate, into: folder, report: report)
                report(.verifying)
                try await PinnedModelFiles.verify(candidate, in: folder)
                try PinnedModelFiles.stamp(candidate, in: folder)
            }
            report(.ready)
            return true
        } catch is CancellationError {
            report(.missing)
        } catch {
            report(.failed(error.localizedDescription))
            Task {
                try? await Task.sleep(for: .seconds(300))
                self.started = false
                self.start()
            }
        }
        return false
    }

    private func download(_ manifest: Manifest, into folder: URL, report: @escaping @MainActor @Sendable (State) -> Void) async throws {
        let total = manifest.totalBytes
        var done: Int64 = manifest.files.reduce(0) { sum, entry in
            PinnedModelFiles.size(of: folder.appendingPathComponent(entry.key)) == entry.value.bytes ? sum + entry.value.bytes : sum
        }
        report(.downloading(received: done, total: total))
        for (name, file) in manifest.files.sorted(by: { $0.value.bytes < $1.value.bytes }) {
            let target = folder.appendingPathComponent(name)
            guard PinnedModelFiles.size(of: target) != file.bytes else { continue }
            guard let url = URL(string: "https://huggingface.co/\(manifest.repo)/resolve/\(manifest.revision)/\(name)") else { continue }
            let base = done
            let progress = DownloadProgress { received in
                Task { @MainActor in report(.downloading(received: base + received, total: total)) }
            }
            let (temporary, response) = try await URLSession.shared.download(from: url, delegate: progress)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw PinnedModelFailure("Hugging Face answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(name)")
            }
            guard PinnedModelFiles.size(of: temporary) == file.bytes else {
                throw PinnedModelFailure("\(name) is incomplete")
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temporary, to: target)
            done += file.bytes
            report(.downloading(received: done, total: total))
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

#endif
