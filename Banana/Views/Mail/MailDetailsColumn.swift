#if !BANANA_PUBLIC
import SwiftUI

/// The details column: plain facts about the conversation in the pane — who is in it, when, how
/// many messages, what was attached. A heading and tidy rows, because this is where enrichment
/// (the calendar, a contact's history, a plan) will go; what it draws now it is handed, prepared
/// (`MailConversationFacts`).
struct MailDetailsColumn: View {
    @ObservedObject var pane: MailPaneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, DS.Space.l)
                .frame(height: DS.Mail.header)
            MailDivider(axis: .horizontal)
            if let reader = pane.reader {
                MailDetailsContent(reader: reader)
                    .id(reader.id)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(MailID.details)
    }
}

private struct MailDetailsContent: View {
    @ObservedObject var reader: MailReaderModel

    var body: some View {
        ScrollView {
            if let facts = reader.facts {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    MailDetailSection("People \u{00B7} \(facts.participants.count)") {
                        ForEach(facts.participants) { person in
                            MailParticipantRow(person: person)
                        }
                    }
                    MailDetailSection("Messages") {
                        MailFactRow("Count", facts.messageLine)
                        if let first = facts.firstText { MailFactRow("First", first) }
                        if let last = facts.lastText, facts.messageCount > 1 { MailFactRow("Latest", last) }
                    }
                    if !facts.attachments.isEmpty {
                        MailDetailSection("Attachments \u{00B7} \(facts.attachments.count)") {
                            ForEach(facts.attachments) { attachment in
                                Label("\(attachment.name) \u{00B7} \(attachment.sizeText)",
                                      systemImage: "paperclip")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    if !facts.labels.isEmpty || facts.isInvitation {
                        MailDetailSection("Marked") {
                            if facts.isInvitation { MailFactRow("Invitation", "Yes") }
                            if !facts.labels.isEmpty { MailFactRow("Labels", facts.labels.joined(separator: ", ")) }
                        }
                    }
                }
                .padding(DS.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// One group of facts under a small tracked heading, as the app's other panels head theirs.
private struct MailDetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title.uppercased())
                .font(DS.Typeface.eyebrow)
                .tracking(DS.Typeface.eyebrowTracking)
                .foregroundStyle(.tertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailParticipantRow: View {
    let person: MailConversationFacts.Participant

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            Text(person.isMe ? "Me" : (person.name ?? person.address))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if person.isMe || person.name != nil {
                Text(person.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if person.wrote > 0 {
                Text(person.wrote == 1 ? "Wrote 1 message" : "Wrote \(person.wrote) messages")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailFactRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.hair) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
