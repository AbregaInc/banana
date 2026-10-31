#if !BANANA_PUBLIC
import SwiftUI

/// The files on a message he is writing: a chip for each, with its name, its size and a way to
/// take it off, and under them how many and how big, or why the last one was not added
/// (MAIL-UX 6.3.5). Tapping a chip opens the file for a look with the system's Quick Look.
///
/// It observes the composer's files and nothing else, so a file added re-evaluates this row and
/// not the composer, the list or the reading pane.
struct MailAttachmentChips: View {
    let session: MailSession
    let model: MailComposerModel
    @ObservedObject var files: MailComposerFiles

    var body: some View {
        if !files.isEmpty || files.notice != nil {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if !files.isEmpty {
                    MailFlowLayout(spacing: DS.Space.xs) {
                        ForEach(files.shown) { attachment in
                            MailAttachmentChip(
                                attachment: attachment,
                                look: { files.look(at: attachment.id) },
                                remove: { session.removeAttachment(attachment.id, from: model) })
                        }
                        ForEach(files.pending) { waiting in
                            // The name at once, before the file has been read.
                            Text(waiting.name)
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Space.s)
                                .padding(.vertical, DS.Space.hair)
                                .background(Color.primary.opacity(DS.Tint.subtle), in: Capsule())
                        }
                    }
                    // So that each chip keeps its own identifier under this one.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(MailID.attachments)
                }
                if let summary = files.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(files.isOver ? DS.Palette.danger : .secondary)
                        .accessibilityIdentifier(MailID.attachmentsSummary)
                }
                if let notice = files.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(DS.Palette.danger)
                        .accessibilityIdentifier(MailID.attachmentsNotice)
                }
            }
        }
    }
}

/// One file: a symbol for what it is, its name (cut in the middle, where a name's end is its
/// extension), its size, and ×.
private struct MailAttachmentChip: View {
    let attachment: MailDraftAttachmentDisplay
    let look: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Button(action: look) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: attachment.symbol)
                        .font(.caption)
                        .foregroundStyle(attachment.isProgram ? DS.Palette.warning : .secondary)
                    Text(attachment.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(attachment.sizeText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(attachment.name), \(attachment.sizeText)")
            .accessibilityHint("Opens it for a look")
            .accessibilityIdentifier(MailID.attachmentChip(attachment.name))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
            .accessibilityIdentifier(MailID.attachmentRemove(attachment.name))
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.hair)
        .background(Color.primary.opacity(DS.Tint.soft), in: Capsule())
    }
}

#endif
