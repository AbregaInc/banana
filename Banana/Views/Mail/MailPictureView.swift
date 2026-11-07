#if !BANANA_PUBLIC
import SwiftUI

private struct MailPictureContextKey: EnvironmentKey {
    static let defaultValue = MailPictureContext()
}

extension EnvironmentValues {
    var mailPictureContext: MailPictureContext {
        get { self[MailPictureContextKey.self] }
        set { self[MailPictureContextKey.self] = newValue }
    }
}

/// A picture in a message: the size its sender declared, scaled to the text column and never past it
/// (a small picture keeps its own size), a placeholder with its description in exactly that box until the
/// picture is here, and the picture fitted inside the same box, so nothing moves when it arrives.
struct MailPictureView: View {
    let picture: MailPicture
    @Environment(\.mailPictureContext) private var context
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    /// Width over height. A sender that gave no width gets a box 280 pt wide at most, 16:9 unless it gave both sides.
    private var ratio: CGFloat {
        if let w = picture.width, let h = picture.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 16.0 / 9.0
    }

    var body: some View {
        let content = sized
            .accessibilityLabel(picture.alt.isEmpty ? "Picture" : picture.alt)
            .accessibilityAddTraits(.isImage)
            .task(id: picture) { await load() }
        if let link = MailBodyHTML.safeLink(picture.link) {
            Link(destination: link) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    /// Both sides declared: that shape, no wider than declared. Only a height: a strip of that height (a logo,
    /// a divider). Otherwise a wide box, with the width if it was given.
    @ViewBuilder private var sized: some View {
        if picture.width == nil, let height = picture.height, height > 0 {
            box.frame(height: CGFloat(height)).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            box.frame(maxWidth: picture.width.map { CGFloat($0) } ?? 280)
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var box: some View {
        ZStack(alignment: .leading) {
            if let image {
                Image(decorative: image, scale: displayScale).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous).fill(Color.primary.opacity(0.06))
                if !picture.alt.isEmpty {
                    Text(picture.alt).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).padding(DS.Space.s)
                }
            }
        }
    }

    private func load() async {
        let maxPixel = Int(min(CGFloat(picture.width ?? 1_000), 1_000) * displayScale)
        let context = context
        switch picture.source {
        case .cid(let id):
            image = await MailPictureLoader.shared.image(key: "cid:\(context.account):\(id)", maxPixel: maxPixel) { await context.part(id) }
        case .remote(let original):
            // Nil (no proxy yet): the placeholder stays. A picture is never fetched under its sender's address.
            guard let proxied = MailImageSource.url(for: original, account: context.account) else { return }
            image = await MailPictureLoader.shared.image(key: proxied.absoluteString, maxPixel: maxPixel) {
                try? await URLSession.shared.data(from: proxied).0
            }
        }
    }
}

#endif
