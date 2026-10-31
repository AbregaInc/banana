import Foundation
// A 25 MB attachment as Gmail returns it (base64url text), decoded in 64 KB pieces using only
// Foundation's decoder: translate '-' '_' in place, decode a multiple of four characters at a time.
let bytes = 25 * 1024 * 1024
var raw = Data(count: bytes); raw.withUnsafeMutableBytes { p in for i in stride(from: 0, to: bytes, by: 8) { p.storeBytes(of: UInt64(i) &* 0x9E3779B97F4A7C15, toByteOffset: i, as: UInt64.self) } }
var text = [UInt8](raw.base64EncodedString().utf8)
for i in text.indices { if text[i] == 43 { text[i] = 45 } else if text[i] == 47 { text[i] = 95 } }   // + / -> - _
while text.last == 61 { text.removeLast() }                                                           // Gmail omits padding
func load() -> String { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return String(format: "load %.0f %.0f %.0f", l[0], l[1], l[2]) }
var times: [Double] = []; var total = 0
for _ in 0..<7 {
    let a = DispatchTime.now().uptimeNanoseconds
    total = 0
    var chunk = [UInt8](repeating: 0, count: 65_536)
    var offset = 0
    while offset < text.count {
        let n = min(65_536, text.count - offset)
        for i in 0..<n { let c = text[offset + i]; chunk[i] = c == 45 ? 43 : (c == 95 ? 47 : c) }
        var slice = Data(chunk[0..<n])
        while slice.count % 4 != 0 { slice.append(61) }                // only the last piece
        guard let out = Data(base64Encoded: slice) else { fatalError("bad chunk") }
        total += out.count                                             // a FileHandle.write(out) goes here
        offset += n
    }
    times.append(Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6)
}
times.sort()
print(String(format: "25 MB base64url, 64 KB pieces through Foundation's decoder: p50 %.0f ms, min %.0f ms, decoded %d bytes (ok: %@) · %@", times[times.count / 2], times[0], total, total == bytes ? "yes" : "NO", load()))
