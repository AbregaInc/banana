// content_spike.swift — rough throughput numbers behind the "prepare HTML when a message is opened"
// and "stream-decode attachments" decisions in docs/design/MAIL-ENGINE.md.
//
// Build:  swiftc -O content_spike.swift -o content_spike      Run: ./content_spike
//
// Not a sanitiser: a byte-level tag walk of the same shape (find tags, read the name and the
// attributes, drop some elements, rewrite URL attributes, copy the rest), to size the work.

import Foundation
import Compression

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1_000_000 }
func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
func p95(_ xs: [Double]) -> Double { xs.sorted()[min(xs.count - 1, Int(Double(xs.count) * 0.95))] }

// A newsletter-shaped document: nested tables, inline styles, tracking pixel, images, links, a style block.
func newsletter(blocks: Int) -> [UInt8] {
    var s = "<html><head><meta charset=\"utf-8\"><style>.a{color:#333;font-family:Helvetica,Arial,sans-serif}.b{background:url(https://cdn.example.com/bg.png)}@media (max-width:600px){.c{width:100%!important}}</style><script>alert(1)</script></head><body bgcolor=\"#f4f4f4\">"
    s += "<img src=\"https://track.example.com/o/abc123.gif\" width=\"1\" height=\"1\" style=\"display:none\">"
    for i in 0..<blocks {
        s += "<table role=\"presentation\" width=\"600\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"margin:0 auto;background-color:#ffffff\"><tr><td class=\"a c\" style=\"padding:16px 24px;font-size:15px;line-height:22px;color:#222222\">"
        s += "<h2 style=\"margin:0 0 8px 0;font-size:20px\">Section \(i): quarterly numbers &amp; what changed</h2>"
        s += "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.</p>"
        s += "<a href=\"https://click.example.com/r/\(i)?u=9a8b7c&amp;utm_source=news\" style=\"color:#1a73e8;text-decoration:none\" onclick=\"track()\"><img src=\"https://cdn.example.com/img/\(i).jpg\" alt=\"Chart \(i)\" width=\"552\" style=\"display:block;border:0\"></a>"
        s += "<p style=\"color:#666\">Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. <img src=\"cid:part\(i)@mail\" width=\"24\" height=\"24\"> Excepteur sint occaecat cupidatat non proident.</p>"
        s += "</td></tr></table>"
    }
    s += "<blockquote type=\"cite\" class=\"gmail_quote\"><div>On Mon, 5 Oct 2026 someone wrote:</div><p>Earlier text quoted here, several lines of it, repeated in every reply of the thread.</p></blockquote></body></html>"
    return Array(s.utf8)
}

@inline(__always) func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
func equals(_ a: ArraySlice<UInt8>, _ lit: StaticString) -> Bool {
    guard a.count == lit.utf8CodeUnitCount else { return false }
    return lit.withUTF8Buffer { p in var i = 0; for b in a { if lower(b) != p[i] { return false }; i += 1 }; return true }
}

/// One pass: copy text; for each tag read name + attributes; drop <script>/<style>/<meta>/<link> elements,
/// drop on* attributes, rewrite src/href/background values (cid: → banana-mail://cid/…, https: → blocked or proxied).
func prepare(_ input: [UInt8]) -> (out: [UInt8], tags: Int, rewritten: Int) {
    var out: [UInt8] = []; out.reserveCapacity(input.count + input.count / 8)
    var i = 0, tags = 0, rewritten = 0
    let n = input.count
    var skipUntil: StaticString? = nil
    while i < n {
        guard input[i] == 0x3C /* < */ else {
            if skipUntil == nil { out.append(input[i]) }
            i += 1; continue
        }
        // tag
        var j = i + 1
        let closing = j < n && input[j] == 0x2F
        if closing { j += 1 }
        let nameStart = j
        while j < n, input[j] != 0x20, input[j] != 0x3E, input[j] != 0x2F, input[j] != 0x0A { j += 1 }
        let name = input[nameStart..<j]
        tags += 1
        if let skipping = skipUntil {
            if closing && equals(name, skipping) { skipUntil = nil }
            while j < n, input[j] != 0x3E { j += 1 }
            i = j + 1; continue
        }
        if !closing && (equals(name, "script") || equals(name, "style")) {
            skipUntil = equals(name, "script") ? "script" : "style"
            while j < n, input[j] != 0x3E { j += 1 }
            i = j + 1; continue
        }
        if equals(name, "meta") || equals(name, "link") || equals(name, "base") || equals(name, "iframe") || equals(name, "object") || equals(name, "form") {
            while j < n, input[j] != 0x3E { j += 1 }
            i = j + 1; continue
        }
        out.append(0x3C); if closing { out.append(0x2F) }
        for b in name { out.append(lower(b)) }
        // attributes
        while j < n, input[j] != 0x3E {
            while j < n, input[j] == 0x20 || input[j] == 0x0A || input[j] == 0x2F { j += 1 }
            if j >= n || input[j] == 0x3E { break }
            let aStart = j
            while j < n, input[j] != 0x3D, input[j] != 0x20, input[j] != 0x3E { j += 1 }
            let attr = input[aStart..<j]
            var value: ArraySlice<UInt8> = []
            if j < n, input[j] == 0x3D {
                j += 1
                if j < n, input[j] == 0x22 || input[j] == 0x27 {
                    let quote = input[j]; j += 1; let vStart = j
                    while j < n, input[j] != quote { j += 1 }
                    value = input[vStart..<j]; j += 1
                } else {
                    let vStart = j
                    while j < n, input[j] != 0x20, input[j] != 0x3E { j += 1 }
                    value = input[vStart..<j]
                }
            }
            if attr.count > 2, lower(attr[attr.startIndex]) == 0x6F, lower(attr[attr.startIndex + 1]) == 0x6E { continue }   // on*
            out.append(0x20); for b in attr { out.append(lower(b)) }
            out.append(0x3D); out.append(0x22)
            if equals(attr, "src") || equals(attr, "href") || equals(attr, "background") {
                rewritten += 1
                if value.starts(with: Array("cid:".utf8)) {
                    out.append(contentsOf: Array("banana-mail://cid/".utf8)); out.append(contentsOf: value.dropFirst(4))
                } else if equals(attr, "href") {
                    out.append(contentsOf: value)
                } else {
                    out.append(contentsOf: Array("banana-mail://remote/".utf8))
                    var h: UInt64 = 1469598103934665603
                    for b in value { h = (h ^ UInt64(b)) &* 1099511628211 }
                    out.append(contentsOf: Array(String(h, radix: 16).utf8))
                }
            } else {
                out.append(contentsOf: value)
            }
            out.append(0x22)
        }
        out.append(0x3E)
        i = j + 1
    }
    return (out, tags, rewritten)
}

func codec(_ input: [UInt8], _ algorithm: compression_algorithm, encode: Bool, capacity: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: capacity)
    let n = input.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            encode ? compression_encode_buffer(dst.baseAddress!, capacity, src.baseAddress!, input.count, nil, algorithm)
                   : compression_decode_buffer(dst.baseAddress!, capacity, src.baseAddress!, input.count, nil, algorithm)
        }
    }
    return Array(out.prefix(n))
}

for blocks in [8, 60, 250] {
    let html = newsletter(blocks: blocks)
    var times: [Double] = []; var result = prepare(html)
    for _ in 0..<200 { let a = now(); result = prepare(html); times.append(ms(a, now())) }
    print(String(format: "prepare pass: %6d bytes in, %6d out, %4d tags, %3d URLs rewritten — p50 %.3f ms p95 %.3f ms (%.0f MB/s)",
                 html.count, result.out.count, result.tags, result.rewritten, median(times), p95(times), Double(html.count) / 1_048_576 / (median(times) / 1000)))
    for (name, algorithm) in [("zlib", COMPRESSION_ZLIB), ("lzfse", COMPRESSION_LZFSE)] {
        var enc: [Double] = [], dec: [Double] = []; var packed: [UInt8] = []
        for _ in 0..<100 { let a = now(); packed = codec(html, algorithm, encode: true, capacity: html.count + 4096); enc.append(ms(a, now())) }
        for _ in 0..<100 { let a = now(); _ = codec(packed, algorithm, encode: false, capacity: html.count + 4096); dec.append(ms(a, now())) }
        print(String(format: "  %@: %d → %d bytes (%.1f×; synthetic markup, real mail differs) — compress p50 %.3f ms, decompress p50 %.3f ms", name, html.count, packed.count, Double(html.count) / Double(packed.count), median(enc), median(dec)))
    }
}

// Attachment bytes arrive as one JSON string of base64url. A 25 MB file is ~33.4 MB of text.
let raw = (0..<(25 * 1_048_576)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
let b64 = Data(raw).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
let b64Bytes = Array(b64.utf8)
var whole: [Double] = []
for _ in 0..<5 {
    let a = now()
    let std = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let d = Data(base64Encoded: std)!
    whole.append(ms(a, now())); precondition(d.count == raw.count)
}
print(String(format: "base64url, whole 25 MB in memory with Foundation (string + Data both alive: ~%d MB peak): p50 %.0f ms", (b64Bytes.count * 2 + raw.count) / 1_048_576, median(whole)))
// Streaming: 64 KB chunks through a table decoder into a fixed buffer (what a FileHandle write would take).
var table = [UInt8](repeating: 255, count: 256)
for (i, c) in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8).enumerated() { table[Int(c)] = UInt8(i) }
var stream: [Double] = []
for _ in 0..<5 {
    let a = now()
    var acc: UInt32 = 0, bits = 0, written = 0
    var chunk = [UInt8](repeating: 0, count: 49_152 + 8); var fill = 0
    var offset = 0
    while offset < b64Bytes.count {
        let end = min(offset + 65_536, b64Bytes.count)
        for k in offset..<end {
            let v = table[Int(b64Bytes[k])]
            if v == 255 { continue }
            acc = (acc << 6) | UInt32(v); bits += 6
            if bits >= 8 { bits -= 8; chunk[fill] = UInt8((acc >> UInt32(bits)) & 0xFF); fill += 1 }
        }
        written += fill; fill = 0   // here: FileHandle.write(chunk[0..<fill])
        offset = end
    }
    stream.append(ms(a, now())); precondition(written == raw.count)
}
print(String(format: "base64url, streamed in 64 KB chunks through a table decoder (64 KB peak): p50 %.0f ms (%.0f MB/s of decoded bytes)", median(stream), 25.0 / (median(stream) / 1000)))
