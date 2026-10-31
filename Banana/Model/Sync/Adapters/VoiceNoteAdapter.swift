import Foundation

/// What the voice-note adapter needs of `VoiceNoteStore`.
@MainActor
protocol VoiceNoteSyncSource: AnyObject {
    var syncNotes: [VoiceNote] { get }
    /// The note's recording on this device, if it has one.
    func syncAudioFile(_ note: VoiceNote) -> URL?
    /// Another device's version, through the store's rule (the later `syncDate` stands); false
    /// when the store's copy stands.
    func applySyncedNote(_ note: VoiceNote) -> Bool
    /// The recording that came down, for the note it belongs to.
    func storeSyncedAudio(_ id: UUID, file: URL)
    func removeSyncedNotes(_ ids: [UUID])
}

/// `notes.voiceNote`: one record per note, the store's `VoiceNote`, plus its recording as the
/// blob field `audio` (eager). Seeds at the note's own `syncDate`; the later one stands, as today.
enum VoiceNoteAdapter {
    static let type = "notes.voiceNote"
    static let audioField = "audio"

    @MainActor
    static func adapter(_ source: VoiceNoteSyncSource) -> BoundAdapter {
        BoundAdapter("voice notes", [binding(source)])
    }

    @MainActor
    static func binding(_ source: VoiceNoteSyncSource) -> SyncBinding {
        weak var weakSource = source
        func items(_ notes: [VoiceNote]) -> [String: any Encodable & Sendable] {
            guard let source = weakSource else { return [:] }
            var found: [String: any Encodable & Sendable] = [:]
            for note in notes { found[note.id.uuidString] = item(note, audio: source.syncAudioFile(note)) }
            return found
        }
        func note(_ id: String) -> VoiceNote? { weakSource?.syncNotes.first { $0.id.uuidString == id } }
        var binding = SyncBinding(
            type: type,
            snapshot: { items(weakSource?.syncNotes ?? []) },
            items: { ids in items((weakSource?.syncNotes ?? []).filter { ids.contains($0.id.uuidString) }) },
            apply: { records in
                var results: [String: SyncApplied] = [:]
                for record in records {
                    guard let source = weakSource, let incoming = try? decode(record.fields),
                          incoming.id.uuidString == record.id else { results[record.id] = .taken; continue }
                    if source.applySyncedNote(incoming) {
                        results[record.id] = .taken
                    } else if let own = note(record.id), own != incoming {
                        results[record.id] = .keptOwn
                    } else {
                        results[record.id] = .taken
                    }
                }
                return results
            },
            remove: { ids in weakSource?.removeSyncedNotes(ids.compactMap(UUID.init(uuidString:))) })
        binding.seedClock = { note($0)?.syncDate }
        binding.blobFile = { id, field in
            guard field == audioField, let note = note(id) else { return nil }
            return weakSource?.syncAudioFile(note)
        }
        binding.storeBlob = { id, field, file in
            guard field == audioField, let uuid = UUID(uuidString: id) else { return }
            weakSource?.storeSyncedAudio(uuid, file: file)
        }
        return binding
    }

    static func item(_ note: VoiceNote, audio: URL?) -> PreparedItem {
        let carried = Carried(note)
        return PreparedItem {
            guard case .object(var fields) = try CanonicalJSON.value(of: carried.value) else {
                throw CanonicalJSON.NotAnObject()
            }
            fields[audioField] = nil
            if let audio, let reference = BlobFiles.reference(audio) { fields[audioField] = reference.value }
            return .object(fields)
        }
    }

    static func decode(_ fields: [String: JSONValue]) throws -> VoiceNote {
        var plain = fields
        plain[audioField] = nil
        return try SyncShape.fields.decode(VoiceNote.self, from: plain)
    }
}
