#if !BANANA_PUBLIC
import SwiftUI

/// Mail, as a section of the app: up to four columns side by side — control, list, reading pane,
/// details — as many as the width allows, with the open conversation full width over them.
///
/// Ordinary launches use the disk-backed Gmail source. Explicit test routes retain sample data.
/// Startup and account consent are shared across windows; failures preserve saved data.
///
/// It observes one thing, `MailNavigation`, which changes when a conversation opens or closes,
/// a place is chosen or a column is toggled, and never when the cursor moves (MAIL-UX 3.11). The
/// session behind it is held by the app, so where he is survives the iOS tree being thrown away
/// in the background and the Mac's sidebar leaving Mail and coming back.
struct MailSection: View {
    @ObservedObject private var application = MailApplication.shared
    /// The wide shell: Mail's place menu, the field and "…" are its one toolbar.
    @Environment(\.wideShell) private var wideShell

    var body: some View {
        let _ = RenderStats.note("MailSection")
        Group {
            if let session = application.session {
                VStack(spacing: 0) {
                    #if os(iOS)
                    if wideShell { MailWideTopRow(session: session) }
                    #endif
                    if let source = session.source as? MailLiveSource {
                        MailConnectionBar(source: source, session: session)
                    }
                    MailScreen(session: session)
                }
            } else {
                VStack(spacing: DS.Space.s) {
                    if application.failed {
                        Text("Mail couldn’t open its saved data.").font(.headline)
                        Text("Your saved data has been kept. Retry to open Mail.")
                            .foregroundStyle(.secondary)
                        Button("Retry") { application.start() }
                    } else { ProgressView("Opening Mail…") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { application.start() }
        #if os(macOS)
        .toolbar {
            if wideShell, let session = application.session {
                ToolbarItem(placement: .navigation) { MailPlaceTitleMenu(session: session) }
                ToolbarItem(placement: .primaryAction) { MailActionsMenu(session: session) }
            }
        }
        #endif
    }
}

/// Asking for an account's mail, or adding one: shared by the accounts menu at the top of Mail
/// and the place menu of the bottom-bar shell's title, so either shows what is happening.
@MainActor
final class MailAccountActions: ObservableObject {
    static let shared = MailAccountActions()
    @Published var busy = false
    @Published var failed = false

    func allow(_ account: String, source: MailLiveSource) {
        busy = true; failed = false
        Task {
            let result = await source.requestPermission(account: account)
            failed = result != .granted && result != .cancelled
            busy = false
        }
    }

    func add(source: MailLiveSource) {
        busy = true; failed = false
        Task {
            await GoogleCalendarService.shared.connect()
            source.checkNow(); busy = false
        }
    }
}

/// Each account, what it can do, and adding one: the items of an accounts menu.
struct MailAccountsMenuItems: View {
    let source: MailLiveSource
    let accounts: [MailAccount]

    var body: some View {
        ForEach(accounts, id: \.id) { account in
            Section(account.id) {
                if account.state != .connected {
                    Button("Allow Mail") { MailAccountActions.shared.allow(account.id, source: source) }
                } else {
                    Text(source.permitsAccountChanges(account.id) ? "Connected" : "Read only")
                    if let text = MailConnectionBar.healthText(account.health) { Text(text) }
                }
            }
        }
        Button("Add account") { MailAccountActions.shared.add(source: source) }
        Button("Check mail") { source.checkNow() }
    }
}

private struct MailConnectionBar: View {
    let source: MailLiveSource
    let session: MailSession
    @State private var accounts: [MailAccount] = []
    @State private var observation: MailObservation?
    @ObservedObject private var actions = MailAccountActions.shared
    /// The new shells have the accounts in the title's menu: no row of their own.
    @Environment(\.bottomBarShell) private var bottomBarShellOnly
    @Environment(\.wideShell) private var wideShell
    private var bottomBarShell: Bool { bottomBarShellOnly || wideShell }
    var body: some View {
        // In the shells it takes no room of its own: each notice brings its own margin, and with
        // nothing to say there is nothing here at all (no padding, no gap).
        VStack(alignment: .leading, spacing: bottomBarShell ? 0 : 8) {
            if !bottomBarShell {
                HStack {
                    Spacer()
                    Menu {
                        MailAccountsMenuItems(source: source, accounts: accounts)
                    } label: {
                        Label(accounts.isEmpty ? "Connect Mail" : "Accounts", systemImage: "person.crop.circle")
                    }
                    .disabled(actions.busy)
                    .accessibilityIdentifier("mail.accounts")
                }
            }
            Group {
                MailRefusalNotice(source: source, status: source.status)
                MailRemovalNotice(source: source, status: source.status)
                MailDraftNotice(session: session, status: source.status)
                if actions.busy { ProgressView() }
                if actions.failed { Text("Mail access wasn’t granted. Try Allow Mail again.").font(.caption) }
            }
            .padding(.vertical, bottomBarShell ? DS.Space.xs : 0)
        }
        .padding(.horizontal).padding(.vertical, bottomBarShell ? 0 : 8)
        .onAppear { observation = source.observeAccounts { accounts = $0 } }
        .onDisappear { observation?.cancel(); observation = nil }
    }

    static func healthText(_ health: MailSyncHealth) -> String? {
        switch health {
        case .live: return nil
        case .firstSync, .catchingUp: return "Downloading and syncing mail…"
        case .checking: return "Checking saved mail against Gmail…"
        case .offline: return "Sync couldn’t finish · retrying automatically"
        case .limited(let date): return "Google limit · retry after " + date.formatted(date: .omitted, time: .shortened)
        case .bytesSpent(let date): return "Download budget reached · resumes " + date.formatted(date: .abbreviated, time: .shortened)
        case .apiDisabled: return "Gmail API is disabled for this Google project"
        case .notAllowedByAdmin: return "Gmail access is blocked by your organization"
        case .wrongAccount: return "Google returned a different account · reconnect required"
        }
    }
}

/// Observes delivery status without invalidating the mail columns.
private struct MailRefusalNotice: View {
    let source: MailLiveSource
    @ObservedObject var status: MailStatus
    @State private var showsFailures = false

    var body: some View {
        Group {
            if !status.value.refused.isEmpty {
                Button {
                    showsFailures = true
                } label: {
                    Label("Some changes couldn’t reach Gmail · Review", systemImage: "exclamationmark.circle")
                }
                .accessibilityIdentifier("mail.delivery.review")
            }
        }
        .sheet(isPresented: $showsFailures) {
            MailRefusalSheet(source: source, status: status)
        }
    }
}

private struct MailRefusalSheet: View {
    let source: MailLiveSource
    @ObservedObject var status: MailStatus
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [MailRefusedChange] = []
    @State private var after: MailReceipt?
    @State private var previous: [MailReceipt?] = []
    @State private var hasMore = false
    @State private var loading = true
    @State private var failed = false
    @State private var revision = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if case .cannotSave = status.value.store {
                    Text("Mail couldn’t save the retry. The failed change has been kept.")
                        .foregroundStyle(.secondary).padding(.horizontal)
                }
                if case .unavailable = status.value.store {
                    Text("Mail needs to reopen its saved data before continuing.")
                        .foregroundStyle(.secondary).padding(.horizontal)
                    Button("Check mail") { source.checkNow() }
                }
                if loading { ProgressView("Loading saved changes…") }
                if failed {
                    Text("Saved changes couldn’t be read. Your changes have been kept.")
                    Button("Try again") { revision += 1 }
                } else if rows.isEmpty && !loading {
                    ContentUnavailableView("No failed changes on this page", systemImage: "checkmark.circle")
                } else {
                    List(rows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            Text((row.isUndo ? "Undo · " : "") + title(row.change)).font(.headline)
                            Text(row.account.isEmpty ? "Multiple accounts" : row.account).font(.caption)
                            Text("\(row.count) conversation(s): " + MailToastText.reason(for: row.failure))
                                .foregroundStyle(.secondary)
                            Button("Retry") {
                                loading = true
                                Task { await source.retryAndWait(row.receipt); revision += 1 }
                            }
                                .disabled(loading)
                                .accessibilityIdentifier("mail.delivery.retry.\(row.id)")
                        }
                        .padding(.vertical, 4)
                    }
                }
                HStack {
                    Button("Previous") {
                        after = previous.removeLast(); revision += 1
                    }.disabled(previous.isEmpty || loading)
                    Spacer()
                    Button("Next") {
                        previous.append(after); after = rows.last?.receipt; revision += 1
                    }.disabled(!hasMore || loading)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Changes needing attention")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: revision) {
                loading = true; failed = false
                do {
                    let page = try await source.refusedChanges(after: after)
                    guard !Task.isCancelled else { return }
                    rows = Array(page.prefix(50)); hasMore = page.count > 50
                    loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    failed = true; loading = false
                }
            }
            .onChange(of: status.value.refused) { _, _ in revision += 1 }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func title(_ change: MailChange) -> String {
        switch change {
        case .done: return "Archive"
        case .notDone: return "Move to Inbox"
        case .trash: return "Move to Trash"
        case .restore: return "Restore from Trash"
        case .spam: return "Mark as spam"
        case .notSpam: return "Mark as not spam"
        case .read(let value): return value ? "Mark as read" : "Mark as unread"
        case .star(let value): return value ? "Star" : "Remove star"
        case .important(let value): return value ? "Mark as important" : "Remove importance"
        case .mute(let value): return value ? "Mute" : "Unmute"
        case .label: return "Change labels"
        case .move: return "Move"
        case .snooze: return "Snooze"
        case .unsnooze: return "Unsnooze"
        }
    }
}

/// Measures the room it has, chooses the columns for it (`MailArrangement`), and puts the open
/// conversation over them. The width is read here and nowhere else.
private struct MailScreen: View {
    let session: MailSession
    @ObservedObject private var navigation: MailNavigation
    /// The shells have the places in the title's menu: no control column beside the list.
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell

    /// The conversation whose Details are open as a sheet.
    @State private var detailsSheet: MailReaderModel?

    init(session: MailSession) {
        self.session = session
        _navigation = ObservedObject(wrappedValue: session.navigation)
    }

    var body: some View {
        GeometryReader { proxy in
            // The bottom-bar layout keeps its two columns: Details are its sheet.
            let arrangement = MailArrangement.choose(width: proxy.size.width,
                                                     wantsPane: navigation.showsPane,
                                                     wantsDetails: navigation.showsDetails && !bottomBarShell,
                                                     controlColumn: !(bottomBarShell || wideShell))
            ZStack {
                MailColumns(session: session, arrangement: arrangement, scope: navigation.scope)
                    .accessibilityHidden(navigation.reader != nil)
                // Over the columns, not instead of them: the list keeps its place underneath.
                if let reader = navigation.reader {
                    MailConversationScreen(session: session, reader: reader,
                                           inlineComposer: !arrangement.isCompact)
                        .id(reader.id)
                        .background(Color.mailBackground)
                }
            }
            .environment(\.mailSession, session)
            .onChange(of: arrangement.showsPane, initial: true) { _, shows in
                session.setPaneVisible(shows)
            }
            // "…" › Details and a tap on a sender, wherever they were asked from: one rule
            // (`MailArrangement.detailsPlacement`) says the column or a sheet.
            .onChange(of: navigation.detailsAsks) { _, _ in
                let placement = arrangement.detailsPlacement(besidePage: !bottomBarShell,
                                                             readerFullWidth: navigation.reader != nil)
                switch placement {
                case .column:
                    if navigation.detailsAskToggles { session.toggleDetails() }
                    else if !navigation.showsDetails { session.toggleDetails() }
                case .sheet:
                    detailsSheet = navigation.reader ?? session.pane.reader
                }
            }
            .sheet(isPresented: sheetBinding(for: arrangement)) {
                if let composer = navigation.composer {
                    MailComposerSheet(session: session, model: composer)
                }
            }
        }
        .background(Color.mailBackground)
        .sheet(isPresented: Binding(get: { detailsSheet != nil }, set: { if !$0 { detailsSheet = nil } })) {
            if let reader = detailsSheet { MailDetailsSheet(reader: reader) }
        }
        .onAppear {
            session.enter()
            session.finishLaunch()
        }
        .onDisappear { session.leave() }
    }

    /// A composer is a sheet where there is nowhere to write it in: a reply at a phone's width, and
    /// a new message where there is no pane to hold it. Closing the sheet by any means keeps the
    /// draft (6.3.8).
    private func sheetBinding(for arrangement: MailArrangement) -> Binding<Bool> {
        let needsSheet: Bool
        if let composer = navigation.composer {
            needsSheet = composer.host == nil ? !arrangement.showsPane : arrangement.isCompact
        } else {
            needsSheet = false
        }
        return Binding(get: { needsSheet }, set: { shown in
            if !shown { session.closeComposer() }
        })
    }
}

/// The note, then the columns the arrangement has, each beside the next with a hairline between.
private struct MailColumns: View {
    let session: MailSession
    let arrangement: MailArrangement
    let scope: MailScope
    @Environment(\.bottomBarShell) private var bottomBarShell
    @Environment(\.wideShell) private var wideShell

    var body: some View {
        VStack(spacing: 0) {
            // The approved shells go straight from the status bar to "Inbox ⌄": the sample note is
            // the standalone page's.
            if session.isSample && !bottomBarShell && !wideShell { MailSampleNote(); MailDivider(axis: .horizontal) }
            // An upright iPad: one top row over the list and the reader, as the approved image has.
            #if os(iOS)
            if bottomBarShell && arrangement.showsPane { MailShellTopRow(session: session) }
            #endif
            HStack(spacing: 0) {
                if arrangement.showsControl {
                    MailControlColumn(session: session, places: session.places, navigation: session.navigation)
                        .frame(width: MailArrangement.controlWidth)
                    MailDivider(axis: .vertical)
                }
                listColumn
                if arrangement.showsPane {
                    MailDivider(axis: .vertical)
                    MailReadingPane(session: session, pane: session.pane, navigation: session.navigation,
                                    arrangement: arrangement)
                        .frame(maxWidth: .infinity)
                    if arrangement.showsDetails {
                        MailDivider(axis: .vertical)
                        MailDetailsColumn(pane: session.pane)
                            .frame(width: MailArrangement.detailsWidth)
                    }
                }
            }
        }
    }

    /// A fixed column beside a pane, and the rest of the room when it stands alone.
    @ViewBuilder private var listColumn: some View {
        let column = MailListColumn(session: session, arrangement: arrangement, scope: scope)
        if arrangement.showsPane {
            column.frame(width: MailArrangement.listWidth)
        } else {
            column.frame(maxWidth: .infinity)
        }
    }
}

/// The line that says whose mail this is: across the top of every column, in every width.
private struct MailSampleNote: View {
    var body: some View {
        Text("Sample mail \u{2014} not connected to Gmail yet. Changes reset when Banana relaunches, except scheduled messages.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(MailID.sampleNote)
    }
}

/// A hairline between two columns, or under a header.
struct MailDivider: View {
    let axis: Axis

    var body: some View {
        switch axis {
        case .horizontal: DS.Palette.separator.frame(height: 1)
        case .vertical: DS.Palette.separator.frame(width: 1)
        }
    }
}

extension Color {
    static var mailBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

#endif
