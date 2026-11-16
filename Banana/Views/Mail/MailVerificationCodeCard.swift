#if !BANANA_PUBLIC
import SwiftUI

/// The same one-click action above the newest message, in the phone, pane and Mac reader.
struct MailVerificationCodeCard: View {
    let code: MailVerificationCode
    @State private var copied = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) {
                summary
                Spacer(minLength: DS.Space.s)
                copyButton
            }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                summary
                copyButton
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(DS.Tint.wash), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mail.verification")
        .onChange(of: code) { copied = false }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Verification code").font(.subheadline).foregroundStyle(.secondary)
            Text(code.value).font(.title2.monospaced().weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .accessibilityLabel(code.value.map(String.init).joined(separator: " "))
                .accessibilityIdentifier("mail.verification.value")
        }
    }

    private var copyButton: some View {
        Button {
            copied = MailClipboard.copy(code.value)
            if !copied { ToastCenter.shared.notify("Couldn’t copy code") }
        } label: {
            Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: DS.Row.minHeight)
                .contentTransition(.identity)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
        }
        .buttonStyle(.secondarySmall)
        .accessibilityIdentifier("mail.verification.copy")
    }
}
#endif
