#if !BANANA_PUBLIC
import Foundation

/// The one door for a remote picture's address. A picture in a message is never fetched from the
/// device's own network connection under the sender's URL: the sender would learn that the message was
/// read, and when, and from where. The address the device may load is the one this returns.
///
/// Until Banana Cloud's image proxy exists (it fetches and caches the picture when the message
/// arrives), this answers nil for everything: the picture shows its fixed-size placeholder and its
/// description, and the layout is already final.
enum MailImageSource {
    /// The address to load `original` from, or nil when it must not be loaded.
    static func url(for original: URL, account: String) -> URL? {
        nil
    }
}

#endif
