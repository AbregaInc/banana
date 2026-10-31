import Foundation
if #available(macOS 26.4, iOS 26.4, *) {
    let s = Data([0xfb, 0xff, 0xfe, 0x01]).base64EncodedString(options: [.base64URLAlphabet, .omitPaddingCharacter])
    print("encode:", s)
    print("decode with .base64URLAlphabet:", Data(base64Encoded: s + "==", options: [.base64URLAlphabet]).map { Array($0) } as Any)
} else { print("this OS is older than 26.4: options unavailable at run time") }
