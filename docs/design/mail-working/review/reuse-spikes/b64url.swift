import Foundation
// Does this SDK's Foundation have a URL-safe base64 alphabet option?
let d = Data([0xfb, 0xff, 0xfe, 0x01])
print(d.base64EncodedString(options: [.base64URLAlphabet, .omitPaddingCharacter]))
