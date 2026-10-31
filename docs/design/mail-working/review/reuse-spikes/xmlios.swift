import Foundation
import libxml2
import UniformTypeIdentifiers
import Compression
func parse(_ bytes: [UInt8]) -> Int32 {
    let doc = bytes.withUnsafeBufferPointer { b in b.withMemoryRebound(to: CChar.self) {
        htmlReadMemory($0.baseAddress, Int32($0.count), nil, "UTF-8", Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NONET.rawValue | HTML_PARSE_IGNORE_ENC.rawValue)) } }
    defer { if let doc { xmlFreeDoc(doc) } }
    return doc == nil ? 0 : 1
}
_ = UTType(mimeType: "application/pdf")
