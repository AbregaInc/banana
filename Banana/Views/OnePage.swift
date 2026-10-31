import SwiftUI

// The parts every page that asks for one thing is built from: the first run, a permission's
// explanation, the confirmation after a sign-in (DESIGN-SYSTEM.md, "Permissions" and "First run").
// One reading column, one main button pinned to the bottom, the quiet choice under it.

extension DS.Palette {
    /// The ground of a one-thing page: the grouped background, so a card reads on it.
    static var page: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    /// A card on that ground, for a shape `dsCard()` doesn't fit (it has its own radius).
    static var card: Color {
        #if os(macOS)
        Color.primary.opacity(DS.Tint.wash)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

/// The one main button of a page and the quiet choice under it are `AppButtonStyle`'s
/// (`Controls.swift`). These names are the page-sized ones.
typealias PrimaryCapsuleButtonStyle = AppButtonStyle

extension AppButtonStyle {
    init(fill: Color = DS.Palette.accent, label: Color = DS.Palette.onAccent, outline: Color? = nil) {
        self.init(kind: .primary, size: .page, fill: fill, label: label, outline: outline)
    }
}

extension PrimitiveButtonStyle where Self == AppButtonStyle {
    static var primaryCapsule: AppButtonStyle { .primaryPage }
}

/// A page that asks for one thing.
///
/// The content scrolls, so the largest text sizes fit; it keeps to `DS.Page.readingWidth` and sits
/// in the middle of anything wider (on an iPad the phone's layout ran edge to edge). The actions
/// stay at the bottom, where a thumb is.
struct OnePage<Content: View, Actions: View>: View {
    /// 0…1 for the bar at the top, or nil for none.
    var progress: Double?
    var onBack: (() -> Void)?
    /// On a whole iPad screen or a Mac window: the column and its actions as one block in the
    /// middle. Pinned to the bottom there, the button sat a foot below what it belonged to.
    var centred = false
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        if centred { centredBody } else { pinnedBody }
    }

    private var centredBody: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: DS.Space.xxl) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        content
                    }
                    .frame(maxWidth: DS.Page.readingWidth, alignment: .leading)
                    VStack(spacing: DS.Space.xs) {
                        actions
                    }
                    .frame(maxWidth: DS.Page.readingWidth)
                }
                // Its own height, then centred: without this the spare height of the screen is
                // handed to whatever inside can stretch (an event block's spine grew a foot tall).
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(DS.Palette.page)
    }

    private var pinnedBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                content
            }
            .frame(maxWidth: DS.Page.readingWidth, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.l)
            .padding(.bottom, DS.Space.xl)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: DS.Space.xs) {
                actions
            }
            .frame(maxWidth: DS.Page.readingWidth)
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.s)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.page)
        }
        .background(DS.Palette.page)
    }

    @ViewBuilder private var header: some View {
        if progress != nil || onBack != nil {
            HStack(spacing: DS.Space.s) {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.backward")
                            .font(.body.weight(.semibold))
                            .frame(width: DS.Row.minHeight, height: DS.Row.minHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                if let progress {
                    ProgressView(value: progress)
                        .tint(DS.Palette.accent)
                        .accessibilityLabel("Setup progress")
                    // Balances the chevron, so the bar is centred over the column.
                    if onBack != nil { Color.clear.frame(width: DS.Row.minHeight, height: DS.Row.minHeight) }
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: DS.Page.readingWidth)
            // The chevron's glyph, not its 44-point target, lines up with the column's edge.
            .padding(.horizontal, DS.Space.xl - (DS.Row.minHeight - 12) / 2)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.page)
        }
    }
}

/// Banana's mark, on its own tile.
struct BrandMark: View {
    var size: CGFloat = DS.Page.brandMark

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A page's big title: centred over the column, on as many lines as it needs. (Left-aligned
    /// over full-width cards and a centred button it looked sloppy: the author, 10 Oct 2026.)
    func pageTitle() -> some View {
        multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }
}

/// One of a page's two or three reasons: a symbol on a solid tile of its colour, and one line.
struct Reason: Identifiable {
    let symbol: String
    let text: String
    var tint: Color = DS.Palette.accent
    /// Only where white would not read on `tint` (`IconTile.glyph`).
    var glyph: Color?

    var id: String { text }
}

/// A page's reasons as one card with hairlines between them, each beside the same solid tile a
/// Settings row has (`IconTile`). They were bare outlines in the accent: thin, all one colour,
/// and easy to pass over. Before that, three boxes, one per paragraph.
struct ReasonCard: View {
    let reasons: [Reason]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(reasons.enumerated()), id: \.element.id) { index, reason in
                if index > 0 { Divider().padding(.leading, DS.Row.iconTile + DS.Space.m) }
                HStack(spacing: DS.Space.m) {
                    IconTile(systemImage: reason.symbol, tint: reason.tint, glyph: reason.glyph)
                    Text(reason.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                // A one-line reason is a 44-point row; the calendar's three two-line ones and the
                // note under them still fit above the buttons on a phone.
                .padding(.vertical, DS.Space.s)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.xs)
        .dsCard()
    }
}

/// "Continue with Google": Google's own mark on a white capsule, as its branding asks.
///
/// Not the sign-in package's button: that one is fixed at 40 points tall, under the 44-point
/// minimum, and takes no other shape. Google allows a button built from its mark as long as the
/// mark is unchanged, on white or near-black, with one of its own phrases.
struct GoogleButton: View {
    var working = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image("GoogleG").resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                }
                Text(working ? "Opening Google\u{2026}" : "Continue with Google")
            }
        }
        .buttonStyle(PrimaryCapsuleButtonStyle(
            fill: scheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.078) : .white,
            label: scheme == .dark ? Color(red: 0.89, green: 0.89, blue: 0.89) : Color(red: 0.12, green: 0.12, blue: 0.12),
            outline: scheme == .dark ? Color(red: 0.56, green: 0.57, blue: 0.56) : Color(red: 0.455, green: 0.467, blue: 0.459)))
        .disabled(working)
        .accessibilityIdentifier("google.continue")
    }
}
