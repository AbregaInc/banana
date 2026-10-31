#if !BANANA_PUBLIC
import SwiftUI

/// The foot of a conversation (MAIL-UX 6.2.2, 6.3): the composer, when he is writing a reply in
/// it; the mark of a draft he has set aside, when he has one; or nothing.
///
/// It observes the session's navigation for the composer opening and closing, and for nothing
/// else: what he types is the composer's own (`MailComposerView` observes its model), so a
/// keystroke re-evaluates the card and not this slot, the conversation above it, or the list.
struct MailReplySlot: View {
    let session: MailSession
    @ObservedObject var navigation: MailNavigation
    let conversation: MailConversationID
    /// A draft he has begun here and left.
    let draft: MailDraftID?
    /// False at a phone's width, where the composer is a sheet and this holds nothing for it.
    let inline: Bool
    /// Scroll the conversation to the foot, where the card is.
    let reveal: () -> Void

    var body: some View {
        if let composer = navigation.composer {
            if composer.host == conversation, inline {
                MailComposerView(session: session, model: composer, frame: .card)
                    .id(ObjectIdentifier(composer))
                    .onAppear { DispatchQueue.main.async(execute: reveal) }
            }
        } else if let draft {
            MailDraftMarker(session: session, conversation: conversation, draft: draft)
        }
    }
}

/// What a draft leaves in its conversation when its composer is closed: that it is there, and the
/// way back to it. Closing never asks, so this is how he finds the draft again (6.3.8).
private struct MailDraftMarker: View {
    let session: MailSession
    let conversation: MailConversationID
    let draft: MailDraftID

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(DS.Palette.danger)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text("Draft")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Palette.danger)
                Text(conversation.thread.hasPrefix("local:")
                     ? "This message is kept until you send or discard it."
                     : "You began a reply here. It is kept until you send or discard it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Button("Continue") { session.begin(.continuing(draft)) }
                .accessibilityIdentifier(MailID.continueDraft)
            Button("Discard") { session.discardKept(draft) }
                .accessibilityIdentifier(MailID.discard)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.draftMarker)
    }
}

/// The composer at a phone's width, and a new message where there is no pane to hold it: a sheet
/// over the section. Closing it by any means keeps the draft, so there is no Cancel and no Done.
struct MailComposerSheet: View {
    let session: MailSession
    @ObservedObject var model: MailComposerModel

    var body: some View {
        ScrollView {
            MailComposerView(session: session, model: model, frame: .sheet)
                .padding(DS.Space.l)
        }
        // The section's toast is under this sheet, where a toast raised while writing — a file
        // taken off with its Undo, "Add someone to send to." — could not be seen or tapped. The
        // sheet shows the same toast over its own content.
        .toastHost()
        #if os(macOS)
        .frame(width: DS.Mail.composerSheetWidth, height: DS.Mail.composerSheetHeight)
        #else
        .presentationDetents([.large])
        #endif
    }
}

#endif
