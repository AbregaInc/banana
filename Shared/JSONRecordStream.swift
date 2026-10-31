import Foundation

/// A top-level JSON array of objects, one record at a time. Decoders validate each object;
/// this scanner validates separators, the outer array and end-of-file. Migration callers put
/// the entire traversal in a transaction, so a malformed tail cannot commit a partial import.
enum JSONRecordStream {
    static func forEach(at url: URL, _ consume: (Data) throws -> Void) throws {
        guard let stream = InputStream(url: url) else { throw CocoaError(.fileReadUnknown) }
        stream.open()
        defer { stream.close() }
        enum State { case start, first, next, record, separator, done }
        var state = State.start
        var record = Data()
        var depth = 0
        var quoted = false
        var escaped = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            for byte in buffer.prefix(count) {
                let whitespace = byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
                switch state {
                case .start:
                    if whitespace { continue }
                    guard byte == 0x5b else { throw InvalidArray() }
                    state = .first
                case .first, .next:
                    if whitespace { continue }
                    if byte == 0x5d, state == .first { state = .done; continue }
                    guard byte == 0x7b else { throw InvalidArray() }
                    record = Data([byte]); depth = 1; quoted = false; escaped = false
                    state = .record
                case .record:
                    record.append(byte)
                    if quoted {
                        if escaped { escaped = false }
                        else if byte == 0x5c { escaped = true }
                        else if byte == 0x22 { quoted = false }
                    } else {
                        if byte == 0x22 { quoted = true }
                        else if byte == 0x7b || byte == 0x5b { depth += 1 }
                        else if byte == 0x7d || byte == 0x5d { depth -= 1 }
                    }
                    if depth == 0 {
                        try autoreleasepool { try consume(record) }
                        record.removeAll(keepingCapacity: false)
                        state = .separator
                    }
                case .separator:
                    if whitespace { continue }
                    if byte == 0x2c { state = .next }
                    else if byte == 0x5d { state = .done }
                    else { throw InvalidArray() }
                case .done:
                    guard whitespace else { throw InvalidArray() }
                }
            }
        }
        guard state == .done else { throw InvalidArray() }
    }

    struct InvalidArray: LocalizedError {
        var errorDescription: String? { "The saved JSON array is incomplete or invalid. Its original file has been preserved." }
    }
}
