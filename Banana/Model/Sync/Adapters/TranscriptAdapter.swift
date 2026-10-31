import Foundation

/// What the transcript adapter needs of `TranscriptStore`.
@MainActor
protocol TranscriptSyncSource: AnyObject {
    /// Every finished transcript here: its source, by episode id (an index, so no transcript is
    /// read to list them).
    var syncTranscripts: [String: Transcript.Source] { get }
    /// The transcript's file here (its JSON).
    func syncTranscriptFile(_ episodeID: String) -> URL
    /// Where the packed copies that go up are kept.
    var syncBlobDirectory: URL { get }
    /// Another device's transcript came down, packed (`unpack`): the store reads it off the main
    /// actor and keeps the better one. `file` is gone once this returns, so copy it.
    func storeSyncedTranscript(_ episodeID: String, packed file: URL)
}

/// `podcast.transcript`: one record per episode, `{source, body}`, the body being the transcript
/// packed with LZFSE as a blob (lazy: it comes down the first time the episode's transcript is
/// wanted, `SpaceSync.ensureBlob`). Today's rule holds: the higher `source.qualityRank` wins.
/// - A transcript of a lower rank than this device's isn't taken: this device's goes up instead
///   (`keptOwn`), so the better one reaches everyone.
/// - One of the same rank is taken as the record, and this device keeps its own text (as alike).
/// - One of a higher rank is taken; its text replaces this one's when it comes down.
/// Transcripts are worked out, not made by a person: they're never deleted in the space.
enum TranscriptAdapter {
    static let type = "podcast.transcript"
    static let bodyField = "body"

    private struct Fields: Codable {
        var source: Transcript.Source
    }

    @MainActor
    static func adapter(_ source: TranscriptSyncSource) -> BoundAdapter {
        BoundAdapter("transcripts", [binding(source)])
    }

    @MainActor
    static func binding(_ source: TranscriptSyncSource) -> SyncBinding {
        weak var weakSource = source
        func items(_ ids: [String]) -> [String: any Encodable & Sendable] {
            guard let source = weakSource else { return [:] }
            let index = source.syncTranscripts
            let blobs = source.syncBlobDirectory
            var found: [String: any Encodable & Sendable] = [:]
            for id in ids {
                guard let kind = index[id] else { continue }
                let file = source.syncTranscriptFile(id)
                found[id] = PreparedItem {
                    var fields: [String: JSONValue] = ["source": .string(kind.rawValue)]
                    if let packed = packed(file, episodeID: id, in: blobs),
                       let reference = BlobFiles.reference(packed, ext: "lzfse") {
                        fields[bodyField] = reference.value
                    }
                    return .object(fields)
                }
            }
            return found
        }
        var binding = SyncBinding(
            type: type,
            snapshot: { items(Array((weakSource?.syncTranscripts ?? [:]).keys)) },
            items: { ids in items(Array(ids)) },
            apply: { records in
                var results: [String: SyncApplied] = [:]
                let index = weakSource?.syncTranscripts ?? [:]
                for record in records {
                    guard let incoming = try? SyncShape.fields.decode(Fields.self, from: record.fields) else {
                        results[record.id] = .taken
                        continue
                    }
                    if let own = index[record.id], own.qualityRank > incoming.source.qualityRank {
                        results[record.id] = .keptOwn
                    } else {
                        results[record.id] = .taken   // its text comes down when it's wanted
                    }
                }
                return results
            },
            remove: { _ in })
        binding.blobFile = { id, field in
            // Asked on the main actor: only a packed copy already made (encoding the record, off
            // the main actor, makes it); none yet holds back just this field.
            guard field == bodyField, let source = weakSource, source.syncTranscripts[id] != nil else { return nil }
            return packedIfMade(source.syncTranscriptFile(id), episodeID: id, in: source.syncBlobDirectory)
        }
        binding.storeBlob = { id, field, file in
            guard field == bodyField else { return }
            weakSource?.storeSyncedTranscript(id, packed: file)
        }
        return binding
    }

    /// The transcript's JSON packed with LZFSE, made once per version of the file and kept, so
    /// the bytes (and the hash) are the same each time they're asked for.
    nonisolated static func packed(_ json: URL, episodeID: String, in directory: URL) -> URL? {
        if let made = packedIfMade(json, episodeID: episodeID, in: directory) { return made }
        let out = packedURL(episodeID, in: directory)
        guard let data = try? Data(contentsOf: json),
              let compressed = try? (data as NSData).compressed(using: .lzfse) as Data else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? compressed.write(to: out, options: .atomic)) != nil else { return nil }
        return out
    }

    /// The packed copy of the transcript as it is now, if it was made; nothing is read or packed.
    nonisolated static func packedIfMade(_ json: URL, episodeID: String, in directory: URL) -> URL? {
        guard let modified = (try? json.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        let out = packedURL(episodeID, in: directory)
        guard let made = (try? out.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              made >= modified else { return nil }
        return out
    }

    nonisolated static func packedURL(_ episodeID: String, in directory: URL) -> URL {
        directory.appendingPathComponent(BlobFiles.sha256(of: Data(episodeID.utf8))).appendingPathExtension("lzfse")
    }

    nonisolated static func unpack(_ file: URL) -> Transcript? {
        guard let compressed = try? Data(contentsOf: file),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }
}
