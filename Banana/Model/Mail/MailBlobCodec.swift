#if !BANANA_PUBLIC
import Foundation
import Compression

/// Versioned zlib envelope with a bounded decoded length. Corrupt cache data must
/// not cause an unbounded Foundation decompression allocation.
enum MailBlobCodec {
    enum Failure: Error { case tooLarge, corrupt }
    static let maximumBytes = 16 * 1024 * 1024
    private static let magic: [UInt8] = [77, 66, 90, 49] // MBZ1

    static func encode(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let size = UInt32(data.count)
        var result = Data(magic + [UInt8(size >> 24), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        guard !data.isEmpty else { return result }
        var output = [UInt8](repeating: 0, count: data.count + data.count / 8 + 64)
        let written = data.withUnsafeBytes { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw Failure.corrupt }
        result.append(contentsOf: output.prefix(written))
        return result
    }

    static func decode(_ data: Data) throws -> Data {
        guard data.count >= 8, data.count <= maximumBytes + maximumBytes / 8 + 72,
              Array(data.prefix(4)) == magic else { throw Failure.corrupt }
        let length = data.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumBytes) else { throw Failure.tooLarge }
        if length == 0 {
            guard data.count == 8 else { throw Failure.corrupt }
            return Data()
        }
        guard data.count > 8 else { throw Failure.corrupt }
        // One extra byte distinguishes exact output from a truncated decode into a full buffer.
        var output = [UInt8](repeating: 0, count: Int(length) + 1)
        let written = data.withUnsafeBytes { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 8), source.count - 8, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == Int(length) else { throw Failure.corrupt }
        return Data(output.prefix(written))
    }
}

#endif
