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

/// A picture in a message. It takes room only when it is being loaded or is here: a remote picture whose
/// address the resolver will not give (`MailImageSource`) shows nothing, or, if it is a link with a label,
/// the label. While one loads, a placeholder with its description fills exactly the box the picture will
/// fill (the size its sender declared, scaled to the text column and never past it, a small picture at
/// its own size), so nothing moves when it arrives. A picture that cannot be loaded goes away.
struct MailPictureView: View {
    let picture: MailPicture
    @Environment(\.mailPictureContext) private var context
    @Environment(\.displayScale) private var displayScale
    private enum Phase { case loading, shown(CGImage), failed }
    @State private var phase = Phase.loading

    /// Width over height. A sender that gave no width gets a box 280 pt wide at most, 16:9 unless it gave both sides.
    private var ratio: CGFloat {
        if let w = picture.width, let h = picture.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 16.0 / 9.0
    }

    /// Where a remote picture may be loaded from; nil for a picture of the message's own parts.
    private var proxied: URL? {
        if case .remote(let original) = picture.source { return MailImageSource.url(for: original, account: context.account) }
        return nil
    }

    private var loadable: Bool {
        if case .cid = picture.source { return true }
        return proxied != nil
    }

    var body: some View {
        if !loadable {
            fallback
        } else if case .failed = phase {
            fallback
        } else {
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
    }

    /// Nothing, or the link's label.
    @ViewBuilder private var fallback: some View {
        if let label = picture.label, let link = MailBodyHTML.safeLink(picture.link) {
            Link(label, destination: link).font(.body).frame(maxWidth: .infinity, alignment: .leading)
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
            if case .shown(let image) = phase {
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
        var image: CGImage?
        switch picture.source {
        case .cid(let id):
            image = await MailPictureLoader.shared.image(key: "cid:\(context.account):\(id)", maxPixel: maxPixel) { await context.part(id) }
        case .remote:
            // Only through the resolver; never under the sender's own address.
            guard let proxied else { phase = .failed; return }
            image = await MailPictureLoader.shared.image(key: proxied.absoluteString, maxPixel: maxPixel) {
                try? await URLSession.shared.data(from: proxied).0
            }
        }
        phase = image.map { .shown($0) } ?? .failed
    }
}

#endif
