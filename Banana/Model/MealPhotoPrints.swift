import CoreGraphics
import Foundation
import Vision

/// Vision feature prints of meal photos: a few hundred numbers each that say what a photo looks
/// like, so a new meal's photos can be compared with the photos of meals already logged
/// (`RepeatPhotoMeal`, docs/design/MEAL-LEARNING.md §4).
///
/// Each device makes its own from its copy of the photo (`MealPhotoStore`), when one is first
/// needed, and keeps it only here — Application Support/MealPhotoPrints, one small file per photo,
/// left out of backups. Never synced: any device can make one again from the photo. A print only
/// compares with prints of the same request revision, so the revision is in each file's name and
/// a new one makes them again rather than comparing across.
actor MealPhotoPrints {
    static let shared = MealPhotoPrints()

    /// Pinned rather than the OS default: `RepeatPhotoMeal.threshold` was measured on this
    /// revision's distances (768 numbers of length 1), and another revision's are on another scale.
    static let revision = VNGenerateImageFeaturePrintRequestRevision2

    let directory: URL
    /// Prints read or made since launch.
    private var memory: [UUID: [Float]] = [:]
    /// Photos here that Vision gave no print for, since launch: not tried again on every estimate.
    private var unreadable: Set<UUID> = []

    init(directory: URL = AppSupport.directory.appendingPathComponent("MealPhotoPrints", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    nonisolated func url(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).r\(Self.revision).print")
    }

    /// The print of each photo (id → its file in `MealPhotoStore`), made where there isn't one yet.
    /// A photo not on this device (still syncing) or that Vision can't read is left out.
    func prints(_ photos: [UUID: URL]) -> [UUID: [Float]] {
        var out: [UUID: [Float]] = [:]
        for (id, file) in photos {
            if let known = memory[id] ?? stored(id) {
                memory[id] = known
                out[id] = known
                continue
            }
            guard !unreadable.contains(id), let data = try? Data(contentsOf: file) else { continue }
            guard let image = MealPhotoImage.downscaled(data, maxPixels: MealPhotoImage.keptPixels),
                  let print = Self.make(image) else {
                unreadable.insert(id)
                continue
            }
            store(print, id)
            out[id] = print
        }
        return out
    }

    /// Drops prints of photos no meal refers to any more, and any of another revision.
    func prune(keeping referenced: Set<UUID>) {
        memory = memory.filter { referenced.contains($0.key) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files {
            let parts = name.split(separator: ".")
            let id = parts.first.flatMap { UUID(uuidString: String($0)) }
            let current = parts.count == 3 && parts[1] == "r\(Self.revision)" && parts[2] == "print"
            if let id, current, referenced.contains(id) { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Files

    /// The print kept for a photo: its numbers as 32-bit floats, nothing else.
    func stored(_ id: UUID) -> [Float]? {
        guard let data = try? Data(contentsOf: url(id)), !data.isEmpty,
              data.count % MemoryLayout<Float>.size == 0 else { return nil }
        var print = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = print.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return print.allSatisfy(\.isFinite) ? print : nil
    }

    func store(_ print: [Float], _ id: UUID) {
        memory[id] = print
        let data = print.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url(id), options: .atomic)
    }

    // MARK: - Vision

    /// A photo's print, or nil when Vision gives none (the Simulator may not).
    static func make(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let print = floats(observation)
        return print.isEmpty ? nil : print
    }

    /// The observation's numbers as floats, whichever type Vision gave them in.
    static func floats(_ observation: VNFeaturePrintObservation) -> [Float] {
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            var out = [Float](repeating: 0, count: count)
            _ = out.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
            return out
        case .double:
            var out = [Double](repeating: 0, count: count)
            _ = out.withUnsafeMutableBytes { observation.data.copyBytes(to: $0) }
            return out.map { Float($0) }
        default:
            return []
        }
    }
}
