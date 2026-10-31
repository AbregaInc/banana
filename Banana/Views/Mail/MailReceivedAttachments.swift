#if !BANANA_PUBLIC
import SwiftUI
import QuickLook

/// The attachments under a message in a conversation (MAIL-UX 6.2.9): a chip for each with a
/// symbol for what it is, its name, its size and what it is called by the system. Tapping one
/// opens it for a look with the system's Quick Look, and nothing else: Banana never opens an
/// attachment in another app, and never previews a program. Press and hold (right-click) offers the
/// system's share, which is where saving is.
///
/// More than six: the first five and "+7 more".
struct MailReceivedAttachments: View {
    /// How many are shown before "+N more", when there are more than `limit`.
    private static let limit = 6
    private static let shownBeforeMore = 5

    let files: [MailAttachmentDisplay]
    @ObservedObject var opener: MailAttachmentOpener
    @State private var showsAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            MailFlowLayout(spacing: DS.Space.xs) {
                ForEach(shown) { file in
                    MailReceivedAttachmentChip(file: file, isWaiting: opener.waiting == file.id) {
                        opener.open(file)
                    }
                }
                if hidden > 0 {
                    Button("+\(hidden) more") { showsAll = true }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, DS.Space.xs)
                }
            }
            if let notice = opener.notice {
                Text(notice).font(.caption).foregroundStyle(DS.Palette.warning)
            }
        }
    }

    private var shown: [MailAttachmentDisplay] {
        files.count > Self.limit && !showsAll ? Array(files.prefix(Self.shownBeforeMore)) : files
    }

    private var hidden: Int { files.count - shown.count }
}

/// One attachment of a message.
private struct MailReceivedAttachmentChip: View {
    let file: MailAttachmentDisplay
    let isWaiting: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: DS.Space.s) {
                Image(systemName: file.symbol)
                    .foregroundStyle(file.isProgram ? DS.Palette.warning : .secondary)
                    .frame(width: DS.Mail.glyphSlot)
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(file.sizeText + " \u{00B7} " + file.kindText)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let note = file.note {
                        Text(note)
                            .font(.caption).foregroundStyle(DS.Palette.warning)
                            .accessibilityIdentifier(MailID.attachmentNote)
                    }
                }
                if isWaiting {
                    ProgressView().controlSize(.mini)
                } else if file.localFile == nil, !file.isProgram {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .background(Color.primary.opacity(DS.Tint.soft), in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let url = file.localFile, !file.isProgram { ShareLink(item: url) }
        }
        .accessibilityLabel("\(file.name), \(file.sizeText), \(file.kindText)")
        .accessibilityIdentifier(MailID.receivedAttachment(file.name))
    }
}

/// Quick Look for the attachments of the open conversation: one place for all of its messages.
struct MailAttachmentPreviewHost: ViewModifier {
    @ObservedObject var opener: MailAttachmentOpener

    func body(content: Content) -> some View {
        content.quickLookPreview($opener.preview)
    }
}

#endif
