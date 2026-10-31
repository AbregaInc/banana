#if !BANANA_PUBLIC
import SwiftUI

/// The signature (MAIL-UX 6.3.4): a block of its own under the text and above the quoted original,
/// set apart by a dashed line and its name, so it is seen to be a signature and not something he
/// typed. Editing the text cannot reach it. It has one control: off this message; and when he has
/// taken it off, the way to put it back.
struct MailSignatureBlock: View {
    @ObservedObject var model: MailComposerModel

    var body: some View {
        Group {
            if let part = model.signature {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.s) {
                        Label("Signature", systemImage: "signature")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { model.removeSignature() } label: {
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: DS.Mail.glyphSlot, height: DS.Mail.glyphSlot)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove signature")
                        .accessibilityIdentifier(MailID.composerSignatureRemove)
                        .help("Send this message without its signature")
                    }
                    if let text = part.text {
                        MailTextView(text: text)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, DS.Space.xs)
                .overlay(alignment: .top) { MailDashedLine() }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(MailID.composerSignature)
            } else if model.canPutSignatureBack {
                Button { model.putSignatureBack() } label: {
                    Label("Signature removed from this message \u{00B7} Put it back", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, DS.Space.xs)
                .accessibilityIdentifier(MailID.composerSignaturePutBack)
            }
        }
    }
}

/// A hairline of dashes, for the line a signature sits under.
private struct MailDashedLine: View {
    var body: some View {
        Rectangle()
            .stroke(DS.Palette.gridHour, style: StrokeStyle(lineWidth: 1, dash: [DS.Space.xs, DS.Space.xs]))
            .frame(height: 1)
    }
}

#endif
