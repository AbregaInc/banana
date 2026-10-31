import Foundation
let d = Data([0xfb, 0xff, 0xfe, 0x01])
if #available(macOS 26.4, iOS 26.4, *) {
    let s = d.base64EncodedString(options: [.base64URLAlphabet, .omitPaddingCharacter])
    print("encode:", s)
    print("decode:", Data(base64Encoded: s, options: [.base64URLAlphabet, .omitPaddingCharacter]).map { Array($0) } as Any)
} else { print("older OS") }
// the 6-line fallback every Gmail client writes
func decodeURL(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t.append("=") }
    return Data(base64Encoded: t, options: .ignoreUnknownCharacters)
}
print("fallback:", decodeURL("-__-AQ").map { Array($0) } as Any)
