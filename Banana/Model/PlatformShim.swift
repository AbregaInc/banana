#if os(macOS)
import AppKit
import SwiftUI

/// A thin bridge so the SHARED views compile on the Mac unmodified.
///
/// The alternative was a parallel Mac copy of the timeline, which is how two codebases start: the
/// scheduler changes on one platform and quietly doesn't on the other. Everything here is a
/// mapping, not a behaviour — the semantic colours iOS names after grouped table backgrounds have
/// direct AppKit equivalents, and a Mac simply has no navigation-bar title mode to set.
typealias UIImage = NSImage

extension Color {
    /// SwiftUI gives iOS an unlabelled `Color(UIColor)` but only `Color(nsColor:)` on the Mac.
    /// Adding the unlabelled form means `Color(.secondarySystemGroupedBackground)` reads the same
    /// in shared view code on both platforms.
    init(_ nsColor: NSColor) { self.init(nsColor: nsColor) }
}

extension NSColor {
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemGroupedBackground: NSColor { .underPageBackgroundColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var systemFill: NSColor { .quaternaryLabelColor }
    static var secondarySystemFill: NSColor { .quaternaryLabelColor }
    static var tertiarySystemFill: NSColor { .quaternaryLabelColor }
    static var systemGray4: NSColor { .separatorColor }
    static var systemGray5: NSColor { .separatorColor }
    static var systemGray6: NSColor { .underPageBackgroundColor }
    static var separator: NSColor { .separatorColor }
    static var opaqueSeparator: NSColor { .separatorColor }
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
}

/// `.insetGrouped` is the iOS name for what the Mac calls `.inset`. Same intent, so alias it rather
/// than fork the call site.
extension Image {
    /// So shared views can keep saying `Image(uiImage:)` — UIImage IS NSImage here.
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { .inset }
}

/// There is no navigation bar on a Mac, so this is a no-op that keeps the call sites shared.
enum NavigationBarTitleDisplayMode { case automatic, inline, large }

extension View {
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View { self }
}

/// Cross-platform clipboard, so shared views don't have to know which kit they're in.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
