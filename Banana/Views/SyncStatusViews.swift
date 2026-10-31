import SwiftUI

/// "Getting your workouts and Health data from iCloud… 312 so far" — at the top of a page whose
/// data hasn't finished its first download on this device, so an empty page never reads as
/// "there's nothing". Nothing at all once a first download has finished.
struct SyncWaitingNote: View {
    let domain: SyncDomain
    @ObservedObject private var sync = SyncProgress.shared

    var body: some View {
        let activity = sync[domain]
        if let line = activity.waitingLine(domain) {
            HStack(spacing: DS.Space.s) {
                if activity.error == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.icloud").foregroundStyle(.secondary)
                }
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            // On the page, not a drawn bar: the toolbar above is the system's.
            .background(DS.Palette.page)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sync.waiting.\(domain.rawValue)")
        }
    }
}

extension View {
    /// A `SyncWaitingNote` above this page while its data is still arriving.
    func syncWaitingNote(_ domain: SyncDomain) -> some View {
        safeAreaInset(edge: .top, spacing: 0) { SyncWaitingNote(domain: domain) }
    }
}

/// Each kind of data's sync, for Settings › iCloud: downloading and how much so far, up to date
/// as of when, or what went wrong.
struct SyncStatusSection: View {
    @ObservedObject private var sync = SyncProgress.shared

    var body: some View {
        Section {
            ForEach(SyncDomain.allCases, id: \.self) { domain in
                LabeledContent(domain.title, value: sync[domain].statusLine())
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("A new device downloads everything once, which can take a few minutes for years of workouts; after that only changes move.")
        }
    }
}
