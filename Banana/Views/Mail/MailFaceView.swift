#if !BANANA_PUBLIC
import SwiftUI

/// A person's face in Mail: the monogram at once, and their picture laid over it when Banana Cloud
/// has one (MAIL-UX "Sender images"). The size never changes, so neither does the row.
///
/// The picture is asked for while the face is on screen (`task`, cancelled when it scrolls away),
/// off the main thread; one already decoded is there on the first frame.
struct MailFaceView: View {
    let face: MailFace
    let size: CGFloat
    @Environment(\.displayScale) private var scale
    @State private var picture: CGImage?
    @State private var shownFor = ""
    @State private var permissionGeneration: UInt64 = 0

    private var px: Int { Int((size * scale).rounded(.up)) }

    var body: some View {
        // A row reused for another person never shows the last one's picture.
        let ready = (shownFor == face.address ? picture : nil)
            ?? (face.address.isEmpty ? nil : MailSenderImages.cached(face.address, px: px))
        Monogram(initial: face.initial, hue: face.hue, size: size)
            .overlay {
                if let ready {
                    Image(decorative: ready, scale: scale)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .background(Color.white)
                        .clipShape(Circle())
                        .transition(.opacity)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: MailSenderImages.permissionsChanged)) { _ in
                permissionGeneration &+= 1
            }
            .task(id: TaskKey(address: face.address, px: px, generation: permissionGeneration)) {
                guard !face.address.isEmpty else { return }
                if permissionGeneration == 0, MailSenderImages.cached(face.address, px: px) != nil { return }
                let address = face.address
                let got = await MailSenderImages.shared.image(for: address, px: px)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    shownFor = address
                    picture = got
                }
            }
    }

    private struct TaskKey: Equatable { var address: String; var px: Int; var generation: UInt64 }
}

#endif
