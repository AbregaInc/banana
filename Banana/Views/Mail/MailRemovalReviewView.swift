#if !BANANA_PUBLIC
import SwiftUI

struct MailRemovalNotice: View {
    let source: MailLiveSource
    @ObservedObject var status: MailStatus
    @State private var selected: Selection?
    private struct Selection: Identifiable { let id: String }
    var body: some View {
        ForEach(status.value.questions) { question in
            if case .removalHeld(let account, let count) = question.kind {
                Button {
                    selected = Selection(id: account)
                } label: {
                    Label("\(count) messages no longer in Gmail · Review", systemImage: "tray.and.arrow.down")
                }
                .accessibilityIdentifier("mail.removal.review")
            }
        }
        .sheet(item: $selected) { selection in
            MailRemovalReviewView(source: source, account: selection.id)
        }
    }
}

private struct MailRemovalReviewView: View {
    let source: MailLiveSource
    let account: String
    @Environment(\.dismiss) private var dismiss
    @State private var review: MailRemovalReview?
    @State private var page = MailRemovalReviewPage(rows: [], next: nil)
    @State private var after: String?
    @State private var previous: [String?] = []
    @State private var revision = 0
    @State private var loading = true
    @State private var saving = false
    @State private var failed = false
    @State private var selected: MailRemovalReviewRow?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(account).font(.subheadline).foregroundStyle(.secondary)
                Text("Gmail reports these messages were deleted. They are still kept here until you choose.")
                if let review {
                    Text("\(review.count) messages in this review").font(.headline)
                    if review.choice != nil {
                        Text("Your choice is saved. Retry to finish applying it.").foregroundStyle(.secondary)
                    }
                }
                if loading { ProgressView("Preparing review…") }
                if failed {
                    Text(review?.choice == nil ? "The review or choice couldn’t be saved. Your mail has been kept." : "Your saved choice couldn’t finish. You can retry it.")
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        if let choice = review?.choice { apply(choice) }
                        else { revision += 1 }
                    }
                }
                List(page.rows) { row in
                    Button { selected = row } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.subject.isEmpty ? "No subject" : row.subject).foregroundStyle(.primary)
                            if !row.sender.isEmpty { Text(row.sender).font(.caption).foregroundStyle(.secondary) }
                            if let date = row.date { Text(date, format: .dateTime.year().month().day()).font(.caption) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(row.conversation == nil)
                }
                .accessibilityIdentifier("mail.removal.rows")
                .disabled(loading || saving)
                HStack {
                    Button("Previous") { after = previous.removeLast(); revision += 1 }
                        .disabled(previous.isEmpty || loading || saving)
                    Spacer()
                    Button("Next") { previous.append(after); after = page.next; revision += 1 }
                        .disabled(page.next == nil || loading || saving)
                }
                if let review, review.choice == nil {
                    ViewThatFits(in: .horizontal) {
                        HStack { choices }
                        VStack(alignment: .leading, spacing: 10) { choices }
                    }
                    .disabled(loading || saving || review.count == 0)
                } else if let choice = review?.choice, !failed {
                    Button("Finish saved choice") { apply(choice) }.disabled(saving)
                }
                if saving { ProgressView("Saving your choice…") }
            }
            .padding()
            .navigationTitle("Review removed mail")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(saving).accessibilityIdentifier("mail.removal.close") } }
            .task(id: revision) {
                loading = true; failed = false
                do {
                    let value: MailRemovalReview
                    if let review { value = review }
                    else { value = try await source.beginRemovalReview(account: account) }
                    guard !Task.isCancelled else { await source.discardRemovalReview(value.id); return }
                    review = value
                    let result = try await source.removalReviewPage(value.id, after: after)
                    guard !Task.isCancelled else { return }
                    page = result; loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true; loading = false
                }
            }
            .sheet(item: $selected) { row in
                if let id = row.conversation { MailRemovalPreview(source: source, id: id) }
            }
            .onDisappear {
                if selected == nil, let id = review?.id { Task { await source.discardRemovalReview(id) } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }
    private var choices: some View {
        Group {
            Button("Keep on this device") { apply(.keepHere) }
                .accessibilityIdentifier("mail.removal.keep")
            Button("Remove from this device", role: .destructive) { apply(.remove) }
                .accessibilityIdentifier("mail.removal.remove")
        }
    }
    private func apply(_ choice: MailChoice) {
        guard let review, !saving else { return }
        saving = true; failed = false
        Task {
            do {
                try await source.applyRemovalAnswer(review.id, choice: choice)
                saving = false; dismiss()
            } catch {
                self.review = (try? await source.removalReviewInfo(review.id)) ?? review
                saving = false; failed = true
            }
        }
    }
}

/// Reuses the existing cached message cards without composing or triage actions.
private struct MailRemovalPreview: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reader: MailReaderModel
    init(source: MailLiveSource, id: MailConversationID) {
        _reader = StateObject(wrappedValue: MailReaderModel(id: id, source: source))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                    if reader.isLoading { ProgressView("Opening saved mail…") }
                    Text(reader.title).font(.headline)
                    ForEach(reader.messages) { message in
                        MailMessageCard(message: message, text: reader.bodies[message.id], opener: reader.opener,
                            load: { reader.fetchBody(message.id) })
                    }
                }.padding()
            }
            .navigationTitle("Saved message")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("mail.removal.preview.close") } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 500)
        #endif
    }
}

#endif
