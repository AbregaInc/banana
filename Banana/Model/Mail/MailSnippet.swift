#if !BANANA_PUBLIC
import Foundation
import SwiftSoup

/// Gmail snippets stay provider-encoded on disk. Decode once at the bounded read
/// boundary, including old cached rows; never parse them as HTML or decode subjects.
enum MailSnippet {
    static func display(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return MailHeaderText.display((try? Entities.unescape(string: value, strict: true)) ?? value)
    }
}
#endif
