import Foundation
import UniformTypeIdentifiers
import CryptoKit
// 1. charsets by IANA name, no table of our own
for name in ["utf-8", "ISO-8859-1", "windows-1252", "iso-2022-jp", "Shift_JIS", "GB2312", "gbk", "big5", "koi8-r", "us-ascii", "utf-16", "iso-8859-15", "x-unknown"] {
    let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    if cf == kCFStringEncodingInvalidId { print("charset", name, "-> unknown"); continue }
    let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    print("charset", name, "->", enc)
}
let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
let cf = CFStringConvertIANACharSetNameToEncoding("iso-8859-1" as CFString)
print("decode latin1:", String(data: latin1, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) ?? "nil")
// 2. zlib through Foundation, no wrapper over compression_stream
let big = Data(String(repeating: "<td style=\"padding:0\">hello world</td>\n", count: 6500).utf8)
let t0 = DispatchTime.now().uptimeNanoseconds
let z = try! (big as NSData).compressed(using: .zlib) as Data
let t1 = DispatchTime.now().uptimeNanoseconds
var back = Data()
for _ in 0..<50 { back = try! (z as NSData).decompressed(using: .zlib) as Data }
let t2 = DispatchTime.now().uptimeNanoseconds
print("zlib via NSData:", big.count, "->", z.count, "bytes; deflate", Double(t1 - t0) / 1e6, "ms; inflate", Double(t2 - t1) / 1e6 / 50, "ms; round trip ok:", back == big)
// 3. UTType: MIME <-> extension <-> kind
for mime in ["application/pdf", "image/png", "text/calendar", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/zip", "application/x-nonsense"] {
    let t = UTType(mimeType: mime)
    print("mime", mime, "-> ext", t?.preferredFilenameExtension ?? "nil", "| image:", t?.conforms(to: .image) ?? false, "| desc:", t?.localizedDescription ?? "nil")
}
print("ext xlsx ->", UTType(filenameExtension: "xlsx")?.preferredMIMEType ?? "nil", "| ics ->", UTType(filenameExtension: "ics")?.preferredMIMEType ?? "nil")
print("sizes:", Int64(84_000).formatted(.byteCount(style: .file)), "|", Int64(1_200_000).formatted(.byteCount(style: .file)), "|", Int64(31_000_000).formatted(.byteCount(style: .file)))
// 4. IDN hosts through Foundation's URL
for s in ["https://аpple.com/login", "https://xn--pple-43d.com/login", "https://bücher.example/x", "https://example.com/"] {
    let u = URL(string: s); let c = URLComponents(string: s)
    print("url", s, "| URL.host:", u?.host() ?? "nil", "| encodedHost:", c?.encodedHost ?? "nil", "| host:", c?.host ?? "nil")
}
// 5. dates: RFC 3339 and RFC 5322
print("rfc3339:", (try? Date("2026-10-06T08:00:00Z", strategy: .iso8601)) as Any)
let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
for s in ["Mon, 05 Oct 2026 09:12:44 +0200", "Mon, 5 Oct 2026 09:12:44 -0700 (PDT)", "5 Oct 2026 09:12 GMT", "Mon, 05 Oct 2026 09:12:44 GMT"] {
    print("rfc5322 DateFormatter:", s, "->", df.date(from: s) as Any)
}
// 6. mailto parsing through URLComponents
let m = URLComponents(string: "mailto:unsubscribe@list.example.com?subject=unsubscribe&body=please%20stop")!
print("mailto path:", m.path, "| items:", m.queryItems ?? [])
// 7. SHA-256
print("sha256:", SHA256.hash(data: Data("https://example.com/a.png".utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
