#if !BANANA_PUBLIC
import SwiftUI

/// What the body's editor admits: bold, italic, underline and a link, and nothing else, so that
/// pasting is filtered by the same rule as typing (MAIL-UX 6.3.4). Colours, backgrounds,
/// strikethrough, spacing, alignment, line height and pictures are dropped as they come in; a font
/// of any family or size becomes the body font, bold or italic if it was; a link that is not
/// `http`, `https` or `mailto` is dropped. What is sent is made from what is left
/// (`MailBodyHTML`), which has no place for the rest either.
struct MailBodyFormatting: AttributedTextFormattingDefinition {
    typealias Scope = AttributeScopes.SwiftUIAttributes

    var body: some AttributedTextFormattingDefinition<Scope> {
        MailFontConstraint()
        MailLinkConstraint()
        ValueConstraint(for: \.foregroundColor, values: [], default: nil)
        ValueConstraint(for: \.backgroundColor, values: [], default: nil)
        ValueConstraint(for: \.strikethroughStyle, values: [], default: nil)
        ValueConstraint(for: \.kern, values: [], default: nil)
        ValueConstraint(for: \.tracking, values: [], default: nil)
        ValueConstraint(for: \.baselineOffset, values: [], default: nil)
        ValueConstraint(for: \.alignment, values: [], default: nil)
        ValueConstraint(for: \.lineHeight, values: [], default: nil)
        ValueConstraint(for: \.adaptiveImageGlyph, values: [], default: nil)
    }
}

/// Any font is the body font, bold and italic kept.
struct MailFontConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.SwiftUIAttributes
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.FontAttribute

    func constrain(_ container: inout Attributes) {
        guard let font = container.font else { return }
        let traits = font.resolve(in: MailRichText.fonts)
        container.font = traits.isBold || traits.isItalic ? Font.body.bold(traits.isBold).italic(traits.isItalic) : nil
    }
}

/// A link is `http`, `https` or `mailto`.
struct MailLinkConstraint: AttributedTextValueConstraint {
    typealias Scope = AttributeScopes.SwiftUIAttributes
    typealias AttributeKey = AttributeScopes.FoundationAttributes.LinkAttribute

    func constrain(_ container: inout Attributes) {
        guard let link = container.link, MailBodyHTML.safeLink(link) == nil else { return }
        container.link = nil
    }
}

#endif
