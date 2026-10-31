#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The menu bar item: plain AppKit, not SwiftUI's `MenuBarExtra`, which hung the app at launch.
///
/// Its text is refreshed on a 30 s timer and whenever today's agenda changes; clicking opens a
/// popover with `MenuBarAgendaPanel`. Shown unless "Next meeting in the menu bar" is turned off.
@MainActor
final class MenuBarAgendaItem: NSObject {
    static let shared = MenuBarAgendaItem()
    static let enabledKey = MenuBarAgendaSetting.key

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var timer: Timer?
    private var agendaObserver: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private weak var smart: SmartScheduleStore?

    func start(smart: SmartScheduleStore) {
        guard self.smart == nil else { return }
        self.smart = smart
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarAgendaPanel(smart: smart))
        agendaObserver = smart.$todayMeetings
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 3   // 10 %, so the system can coalesce this wakeup with others
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyEnabled() }
        }
        applyEnabled()
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private func applyEnabled() {
        if isEnabled, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(toggle(_:))
            item.button?.imagePosition = .imageLeading
            self.item = item
            refresh()
        } else if !isEnabled, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func refresh() {
        guard let button = item?.button, let smart else { return }
        let moment = MenuBarAgendaState.moment(in: smart.todayMeetings, at: Date())
        let symbol = moment?.kind == .now ? "calendar.badge.clock" : "calendar"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Banana calendar")
        let leaveBy = moment.flatMap { m in
            smart.commuteLegs.first { abs($0.start.timeIntervalSince(m.meeting.start)) < 60 }?.leaveBy
        }
        let text = MenuBarAgendaState.label(for: moment, leaveBy: leaveBy) ?? ""
        if button.title != text { button.title = text }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

/// The dropdown: what's on now, what's next with Join, and the rest of today. Most days this is
/// the whole reason to look at a calendar, so it should not require opening the app.
struct MenuBarAgendaPanel: View {
    @ObservedObject var smart: SmartScheduleStore
    /// False for the screenshot preview, whose sample day a real refresh would replace.
    var refreshesOnOpen = true
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let meetings = smart.todayMeetings.sorted { $0.start < $1.start }
            let moment = MenuBarAgendaState.moment(in: meetings, at: now)
            let later = meetings.filter { $0.start > now && $0 != moment?.meeting }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let moment {
                    headline(moment)
                } else {
                    Text(meetings.isEmpty ? "Nothing on your calendar today" : "No more meetings today")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if !later.isEmpty {
                    Divider()
                    Text("Later today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    // Free time between meetings, named — the answer to "can I fit this in?".
                    let shown = Array(later.prefix(8))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, meeting in
                        let previousEnd = index == 0
                            ? (moment.map { $0.meeting.end ?? $0.meeting.start } ?? now)
                            : (shown[index - 1].end ?? shown[index - 1].start)
                        if let gap = TodayText.freeGap(from: max(previousEnd, now), to: meeting.start) {
                            Label(gap, systemImage: "circle.dashed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        row(meeting)
                    }
                }
                Divider()
                // The booking link, copied from wherever the Mac is (⇧⌘L in the app).
                CopyBookingLinkButton(confirm: false)
                    .buttonStyle(.inline)
                HStack {
                    Button("Open Banana") { activateMainWindow() }
                    Spacer()
                    Text("⌃⌘J joins the next meeting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.inline)
            }
            .padding(DS.Space.l)
            .frame(width: 320)
        }
        .task { if refreshesOnOpen { await smart.refreshAgenda() } }
    }

    @ViewBuilder private func headline(_ moment: MenuBarAgendaState.Moment) -> some View {
        let meeting = moment.meeting
        VStack(alignment: .leading, spacing: 6) {
            Text(moment.kind == .now
                 ? "Now \u{00B7} \(MenuBarAgendaState.duration(moment.minutes)) left"
                 : "Next \u{00B7} in \(MenuBarAgendaState.duration(moment.minutes))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(moment.kind == .now ? DS.Palette.accent : .secondary)
            // The trip, when there is one: "Leave in 12 min", in travel blue with its mode.
            if moment.kind == .next,
               let leg = smart.commuteLegs.first(where: { abs($0.start.timeIntervalSince(meeting.start)) < 60 }),
               let lead = TodayText.upNextLead(start: meeting.start, leaveBy: leg.leaveBy) {
                Label("\(lead) \u{00B7} \(leg.detail?.summary ?? "\(leg.travelMinutes) min")",
                      systemImage: (leg.detail?.mode ?? smart.settings.transitMode).systemImage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(DS.Palette.travel)
                    .lineLimit(1)
            }
            Text(meeting.title)
                .font(.headline)
                .lineLimit(2)
            Text(timeRange(meeting))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let address = meeting.address, !address.isEmpty, meeting.joinURL == nil {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let url = meeting.joinURL {
                Button {
                    openURL(url)
                } label: {
                    Label(meeting.platform.map { "Join \($0.label)" } ?? "Join meeting",
                          systemImage: "video.fill")
                }
                .buttonStyle(.primaryPage)
            }
        }
    }

    private func row(_ meeting: MeetingInfo) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(meeting.start.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(meeting.title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(meeting.showsAsFree ? .secondary : .primary)
            Spacer(minLength: 4)
            if let url = meeting.joinURL {
                Button { openURL(url) } label: { Image(systemName: "video.fill") }
                    .iconButton()
                    .help("Join")
            }
        }
    }

    private func timeRange(_ meeting: MeetingInfo) -> String {
        let start = meeting.start.formatted(date: .omitted, time: .shortened)
        guard let end = meeting.end else { return start }
        return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// ⌃⌘J from any app: join the meeting in progress, or the next one within the hour.
///
/// A Carbon hot key rather than an event monitor: it needs no Accessibility permission and
/// fires only for this exact combination.
@MainActor
final class JoinMeetingHotKey {
    static let shared = JoinMeetingHotKey()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in JoinMeetingHotKey.joinNext() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x424E_4A4E), id: 1)   // "BNJN"
        RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(controlKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    static func joinNext() {
        let meetings = SmartScheduleStore.shared.todayMeetings
        guard let meeting = MenuBarAgendaState.joinable(in: meetings, at: Date()),
              let url = meeting.joinURL else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
#if DEBUG
/// `--menu-bar-preview`: the menu bar label and panel in an ordinary window, with sample
/// meetings, so both can be screenshotted — the real item can sit behind the notch.
struct MenuBarAgendaPreview: View {
    @ObservedObject var smart: SmartScheduleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                let moment = MenuBarAgendaState.moment(in: smart.todayMeetings, at: Date())
                let leaveBy = moment.flatMap { m in
                    smart.commuteLegs.first { abs($0.start.timeIntervalSince(m.meeting.start)) < 60 }?.leaveBy
                }
                Label(MenuBarAgendaState.label(for: moment, leaveBy: leaveBy) ?? "",
                      systemImage: moment?.kind == .now ? "calendar.badge.clock" : "calendar")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            MenuBarAgendaPanel(smart: smart, refreshesOnOpen: false)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(24)
        .frame(width: 420)
        .task {
            let now = Date()
            func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
            smart.injectTodayMeetingsForPreview([
                MeetingInfo(start: at(-20), end: at(12), coordinate: nil, address: nil, isVirtual: true,
                            title: "Weekly product sync", joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
                            platform: .meet),
                MeetingInfo(start: at(45), end: at(75), coordinate: nil, address: "500 Howard St",
                            isVirtual: false, title: "Client review"),
                MeetingInfo(start: at(120), end: at(150), coordinate: nil, address: nil, isVirtual: true,
                            title: "Interview: senior iOS engineer", joinURL: URL(string: "https://zoom.us/j/123"),
                            platform: .zoom),
                MeetingInfo(start: at(200), end: at(260), coordinate: nil, address: nil, isVirtual: false,
                            title: "Dinner", showsAsFree: true),
            ])
        }
    }
}
#endif
#endif
