import SwiftUI
// Compile-only: the iOS 26 / macOS 26 rich-text pieces the composer would stand on.
@available(macOS 26.0, iOS 26.0, *)
struct ComposerFormats: AttributedTextFormattingDefinition {
    struct Scope: AttributeScope {
        let font: AttributeScopes.SwiftUIAttributes.FontAttribute
        let underlineStyle: AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
        let strikethroughStyle: AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute
        let link: AttributeScopes.FoundationAttributes.LinkAttribute
    }
    var body: some AttributedTextFormattingDefinition<Scope> { ValueConstraint(for: \.underlineStyle, values: [nil, .single], default: nil) }
}
@available(macOS 26.0, iOS 26.0, *)
struct Editor: View {
    @State var text = AttributedString("hello")
    @State var selection = AttributedTextSelection()
    @Environment(\.fontResolutionContext) var fonts
    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .attributedTextFormattingDefinition(ComposerFormats())
            .onChange(of: text) { _, new in
                for run in new.runs {
                    let resolved = (run.font ?? .body).resolve(in: fonts)
                    print(resolved.isBold, resolved.isItalic, run.underlineStyle != nil, run.strikethroughStyle != nil, run.link as Any)
                }
            }
    }
}
print("compiled")
