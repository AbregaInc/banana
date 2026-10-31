import CoreTransferable
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Settings › Booking (docs/design/BOOKING.md §7, §12), the same page on iPhone, iPad and Mac:
/// the link, with Copy and Share; the handle, suggested from the Google name and taken with one
/// "Use"; and the booking types, each switched on or off in its row and edited on tap. Every
/// change shows at once and syncs behind (`BookingTypeStore`, `BookingCenter`).
struct BookingSettingsView: View {
    @ObservedObject private var center = BookingCenter.shared
    @ObservedObject private var store = BookingTypeStore.shared
    @ObservedObject private var account = BananaAccount.shared
    @State private var draft = ""
    @State private var editing: Target?
    @State private var copied = false
    @FocusState private var handleFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(iOS)
    @State private var shareAnchor = ShareAnchor()
    #endif

    enum Target: Hashable, Identifiable {
        case type(String), new
        var id: String { if case .type(let id) = self { id } else { "new" } }
    }

    var body: some View {
        Form {
            linkSection
            typesSection
        }
        .settingsFormStyle()
        .navigationTitle("Booking")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $editing) { target in
            switch target {
            case .type(let id): BookingTypeEditor(id: id)
            case .new: BookingTypeEditor(id: nil)
            }
        }
        .onAppear {
            store.openedBooking()
            draft = center.handle ?? center.suggestion ?? ""
            #if DEBUG
            // `--booking-preview --booking-editor`: the first type's editor, for its screenshot.
            if center.isPreview, ProcessInfo.processInfo.arguments.contains("--booking-editor"), editing == nil,
               let first = store.types.first {
                editing = .type(first.id)
            }
            #endif
        }
        .task { await center.refresh() }
        // What the service decided (or a suggestion that arrived) shows, unless it's being typed.
        // A refused handle stays in the field, with why under it.
        .onChange(of: center.handle) { _, handle in
            if !handleFocused, center.refusal == nil { draft = handle ?? center.suggestion ?? "" }
        }
        .onChange(of: center.state.suggested) { _, _ in
            if !handleFocused, center.handle == nil, center.refusal == nil { draft = center.suggestion ?? "" }
        }
    }

    // MARK: - The link

    private var typed: String { BookingHandle.normalised(draft) }
    /// "Use" shows while what's in the field isn't the handle.
    private var showsUse: Bool { !typed.isEmpty && typed != center.handle }

    @ViewBuilder private var linkSection: some View {
        Section {
            if !center.isAvailable {
                Button("Connect Google Calendar") { Task { await GoogleCalendarService.shared.connect() } }
                    .accessibilityIdentifier("booking.connect")
            } else {
                handleRow
                if let link = center.link, !showsUse {
                    shareRow(link)
                }
            }
        } header: {
            Text("Your link")
        } footer: {
            if let refusal = center.refusal, refusal.handle == typed {
                Text(Self.words(for: refusal.problem))
                    .foregroundStyle(DS.Palette.danger)
                    .accessibilityIdentifier("booking.handleProblem")
            }
        }
    }

    /// The site, then the name: one line, or at the largest text sizes the site as a line of its
    /// own above the field.
    @ViewBuilder private var handleRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                // One line, never broken inside the address.
                Text(center.sitePrefix)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: DS.Space.s) { handleField; useButton }
            }
        } else {
            HStack(spacing: 0) {
                Text(center.sitePrefix)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                handleField
                useButton
            }
        }
    }

    private var handleField: some View {
        TextField("you", text: $draft)
            .focused($handleFocused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.asciiCapable)
            #endif
            .submitLabel(.done)
            .onSubmit(use)
            .accessibilityLabel("Link name")
            .accessibilityIdentifier("booking.handle")
    }

    @ViewBuilder private var useButton: some View {
        if showsUse {
            Button("Use", action: use)
                .buttonStyle(.primarySmall)
                .accessibilityIdentifier("booking.use")
        }
    }

    /// Copy and Share, side by side; one above the other at the largest text sizes.
    private func shareRow(_ link: URL) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: DS.Space.s)) : AnyLayout(HStackLayout(spacing: DS.Space.m))
        return layout {
            Button {
                center.copyLink(confirm: false)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("booking.copy")
            #if os(iOS)
            Button { shareAnchor.share(link) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .background(ShareAnchorView(anchor: shareAnchor))
            .accessibilityIdentifier("booking.shareLink")
            #else
            ShareLink(item: link) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .accessibilityIdentifier("booking.shareLink")
            #endif
        }
    }

    private func use() {
        if center.claim(draft) {
            draft = typed
            handleFocused = false
        }
    }

    static func words(for problem: BookingHandle.Problem) -> String {
        switch problem {
        case .taken: "Taken"
        case .reserved: "Reserved"
        case .invalid: "3–30 letters, numbers or dashes"
        }
    }

    // MARK: - Types

    private var typesSection: some View {
        Section("Types") {
            ForEach(store.types) { entry in
                HStack(spacing: DS.Space.m) {
                    Button { editing = .type(entry.id) } label: {
                        HStack(spacing: DS.Space.s) {
                            Text(entry.type.title.isEmpty ? "Untitled" : entry.type.title)
                                .foregroundStyle(entry.type.active ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: DS.Space.s)
                            Text(DS.duration(minutes: Double(entry.type.minutes)))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit")
                    .accessibilityIdentifier("booking.type.\(entry.type.slug)")
                    Toggle(isOn: Binding(get: { entry.type.active },
                                         set: { on in store.update(entry.id) { $0.active = on } })) {
                        Text(entry.type.title)
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("booking.type.\(entry.type.slug).active")
                }
            }
            Button { editing = .new } label: {
                Label("Add type", systemImage: "plus")
            }
            .accessibilityIdentifier("booking.addType")
        }
    }
}

// MARK: - The type editor

/// One booking type, every change saved as it's made. A new type is made when it has a title, its
/// link from that title; the link then stays, whatever the title becomes.
struct BookingTypeEditor: View {
    @ObservedObject private var store = BookingTypeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var id: String?
    @State private var draft: BookingType
    @State private var showsHours = false
    @State private var showsMore = false
    @FocusState private var titleFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(id: String?) {
        _id = State(initialValue: id)
        let existing = id.flatMap { BookingTypeStore.shared.entry($0)?.type }
        var fresh = BookingType.standard(zone: BookingTypeStore.shared.types.first?.type.timeZone ?? BookingType.deviceZone())
        fresh.title = ""
        _draft = State(initialValue: existing ?? fresh)
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $draft.title)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit(makeIfNew)
                    .accessibilityIdentifier("booking.editor.title")
                Toggle("Bookable", isOn: $draft.active)
                    .accessibilityIdentifier("booking.editor.active")
            }
            lengthSection
            hoursSection
            BookingPlacesSection(type: $draft)
            moreSection
            if let id, store.types.count > 1 {
                Section {
                    Button("Delete type", role: .destructive) { delete(id) }
                        .accessibilityIdentifier("booking.editor.delete")
                }
            }
        }
        .editingFormStyle()
        .navigationTitle(id == nil ? "New type" : draft.title.isEmpty ? "Type" : draft.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { if id == nil { titleFocused = true } }
        .onChange(of: draft) { _, changed in
            guard let id else { return }
            store.update(id) { $0 = changed }
        }
        .onDisappear(perform: makeIfNew)
    }

    private func makeIfNew() {
        guard id == nil, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft.title = draft.title.trimmingCharacters(in: .whitespaces)
        id = store.add(draft)
        if let made = id.flatMap(store.entry) { draft = made.type }
    }

    private func delete(_ id: String) {
        guard let entry = store.entry(id) else { return }
        store.remove(id)
        dismiss()
        Task {
            await ToastCenter.shared.offerUndo("Deleted \u{201C}\(entry.type.title)\u{201D}") {
                await MainActor.run { BookingTypeStore.shared.restore(entry) }
                return nil
            }
        }
    }

    // MARK: Length

    private var lengthSection: some View {
        Section("Length") {
            // One tap each, side by side; a menu at the largest text sizes, where five don't fit.
            let picker = Picker("Length", selection: Binding(
                get: { BookingType.lengths.contains(draft.minutes) ? draft.minutes : 0 },
                set: { draft.minutes = $0 == 0 ? (BookingType.lengths.contains(draft.minutes) ? 90 : draft.minutes) : $0 })) {
                ForEach(BookingType.lengths, id: \.self) { Text(DS.duration(minutes: Double($0))).tag($0) }
                Text("Other").tag(0)
            }
            .accessibilityIdentifier("booking.editor.length")
            if typeSize.isAccessibilitySize {
                picker.pickerStyle(.menu).labelsHidden()   // the section says "Length"
            } else {
                picker.pickerStyle(.segmented).labelsHidden()
            }
            if !BookingType.lengths.contains(draft.minutes) {
                Stepper(DS.duration(minutes: Double(draft.minutes)), value: $draft.minutes, in: 5...480, step: 5)
            }
        }
    }

    // MARK: Hours

    private var hoursSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsHours) {
                ForEach(BookingText.weekdayOrder(), id: \.self) { day in
                    BookingDayHours(day: day, spans: $draft.hours[day], fallback: fallbackSpans(for: day))
                }
            } label: {
                LabeledContent("Hours", value: BookingText.hoursSummary(draft.hours))
            }
            .accessibilityIdentifier("booking.editor.hours")
        }
    }

    /// A day switched on takes the hours most other days have.
    private func fallbackSpans(for day: Int) -> [BookingSpan] {
        let open = draft.hours.filter { !$0.isEmpty }
        let counts = Dictionary(open.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value < $1.value }?.key ?? [BookingSpan(start: 540, end: 1020)]
    }

    // MARK: More

    private var moreSection: some View {
        Section {
            DisclosureGroup("More", isExpanded: $showsMore) {
                Picker("Notice", selection: $draft.notice) {
                    ForEach(BookingText.notices, id: \.self) { Text(BookingText.notice($0)).tag($0) }
                    if !BookingText.notices.contains(draft.notice) { Text(BookingText.notice(draft.notice)).tag(draft.notice) }
                }
                Picker("Up to", selection: $draft.horizonDays) {
                    ForEach(BookingText.horizons, id: \.self) { Text(BookingText.horizon($0)).tag($0) }
                    if !BookingText.horizons.contains(draft.horizonDays) { Text(BookingText.horizon(draft.horizonDays)).tag(draft.horizonDays) }
                }
                Picker("Gap before", selection: $draft.bufferBefore) {
                    ForEach(BookingText.buffers, id: \.self) { Text(BookingText.buffer($0)).tag($0) }
                }
                Picker("Gap after", selection: $draft.bufferAfter) {
                    ForEach(BookingText.buffers, id: \.self) { Text(BookingText.buffer($0)).tag($0) }
                }
                Picker("Per day", selection: $draft.perDay) {
                    Text("Any").tag(Int?.none)
                    ForEach(1...8, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                NavigationLink {
                    BookingZonePicker(selection: $draft.timeZone)
                } label: {
                    LabeledContent("Time zone", value: BookingText.city(draft.timeZone))
                }
            }
            .accessibilityIdentifier("booking.editor.more")
        }
    }
}

/// One weekday's hours: on or off, its spans, and another span.
private struct BookingDayHours: View {
    let day: Int
    @Binding var spans: [BookingSpan]
    let fallback: [BookingSpan]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Toggle(Calendar.current.weekdaySymbols[day], isOn: Binding(
            get: { !spans.isEmpty },
            set: { spans = $0 ? fallback : [] }))
            .accessibilityIdentifier("booking.editor.day.\(day)")
        ForEach(spans.indices, id: \.self) { index in
            // From – To on one line; at the largest text sizes, one under the other.
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s))
                : AnyLayout(HStackLayout(spacing: DS.Space.s))
            layout {
                // Read safely: a span taken away can still be asked for while the row goes.
                ClockPicker(title: "From", minutes: Binding(
                    get: { spans.indices.contains(index) ? spans[index].start : 0 },
                    set: { if spans.indices.contains(index) { spans[index].start = min($0, spans[index].end - 5) } }))
                if !typeSize.isAccessibilitySize { Text("–").foregroundStyle(.secondary) }
                ClockPicker(title: "To", minutes: Binding(
                    get: { spans.indices.contains(index) ? spans[index].end : 0 },
                    set: { if spans.indices.contains(index) { spans[index].end = max($0, spans[index].start + 5) } }))
                if !typeSize.isAccessibilitySize { Spacer(minLength: DS.Space.s) }
                if spans.count > 1 {
                    Button { spans.remove(at: index) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove these hours")
                } else {
                    Button { addSpan() } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("More hours on \(Calendar.current.weekdaySymbols[day])")
                }
            }
            .padding(.leading, DS.Space.l)
        }
    }

    /// Another span after the last, an hour long, if the day has room.
    private func addSpan() {
        let last = spans.last?.end ?? 540
        let start = min(last + 60, 1380)
        guard start + 60 <= 1440 else { return }
        spans.append(BookingSpan(start: start, end: start + 60))
    }
}

/// A clock time with no label of its own, in five-minute steps (`TimeField`'s pickers).
private struct ClockPicker: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        #if os(macOS)
        DatePicker(title, selection: FiveMinuteGrid.binding(ClockTime.binding($minutes)), displayedComponents: .hourAndMinute)
            .labelsHidden()
        #else
        FiveMinuteTimeWheel(selection: ClockTime.binding($minutes), mode: .hourAndMinuteOnly, style: .compact)
            .fixedSize()
            .accessibilityLabel(title)
        #endif
    }
}

// MARK: - Places

/// Where a type's meetings happen: Google Meet, Zoom (its link pasted once), a phone call (who
/// calls whom, and the number when they call), in person (the address), or another link.
private struct BookingPlacesSection: View {
    @Binding var type: BookingType

    var body: some View {
        Section("Places") {
            toggle("Google Meet", .meet, made: BookingPlace(kind: .meet))
            toggle("Zoom", .zoom, made: BookingPlace(kind: .zoom, url: ""))
            if let zoom = type.place(.zoom) {
                linkField("Zoom link", zoom, kind: .zoom)
            }
            toggle("Phone", .phoneHostCalls, made: BookingPlace(kind: .phoneHostCalls))
            if let phone = type.place(.phoneHostCalls) {
                Picker("Phone", selection: Binding(
                    get: { phone.kind },
                    set: { kind in type.set(kind, to: BookingPlace(kind: kind, phone: phone.phone)) })) {
                    Text("I call them").tag(BookingPlace.Kind.phoneHostCalls)
                    Text("They call me").tag(BookingPlace.Kind.phoneGuestCalls)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("booking.editor.phoneWho")
                if phone.kind == .phoneGuestCalls {
                    TextField("Your number", text: Binding(
                        get: { phone.phone ?? "" },
                        set: { type.set(.phoneGuestCalls, to: BookingPlace(kind: .phoneGuestCalls, phone: $0)) }))
                        .textContentType(.telephoneNumber)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        #endif
                }
            }
            toggle("In person", .inPerson, made: BookingPlace(kind: .inPerson, address: ""))
            if let place = type.place(.inPerson) {
                TextField("Address", text: Binding(
                    get: { place.address ?? "" },
                    set: { type.set(.inPerson, to: BookingPlace(kind: .inPerson, address: $0)) }), axis: .vertical)
                    .textContentType(.fullStreetAddress)
            }
            toggle("Other link", .link, made: BookingPlace(kind: .link, url: ""))
            if let link = type.place(.link) {
                linkField("Link", link, kind: .link)
            }
        }
    }

    /// A place on or off. The last one stays on: a type needs somewhere to meet.
    private func toggle(_ title: String, _ kind: BookingPlace.Kind, made: BookingPlace) -> some View {
        let on = type.place(kind) != nil
        return Toggle(title, isOn: Binding(get: { on }, set: { type.set(kind, to: $0 ? made : nil) }))
            .disabled(on && type.locations.count == 1)
            .accessibilityIdentifier("booking.editor.place.\(kind.placeID)")
    }

    /// A pasted link, with the system's Paste beside it while it's empty.
    @ViewBuilder private func linkField(_ title: String, _ place: BookingPlace, kind: BookingPlace.Kind) -> some View {
        let text = place.url ?? ""
        HStack(spacing: DS.Space.s) {
            TextField(title, text: Binding(get: { text }, set: { type.set(kind, to: BookingPlace(kind: kind, url: $0)) }))
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .foregroundStyle(text.isEmpty || BookingPlace.httpsURL(text) != nil ? Color.primary : DS.Palette.danger)
            if text.isEmpty {
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { @MainActor in type.set(kind, to: BookingPlace(kind: kind, url: first.trimmingCharacters(in: .whitespacesAndNewlines))) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
            }
        }
    }
}

// MARK: - Time zone

/// Every zone, by city. A type's zone is fixed once set: it doesn't follow the host's travel.
private struct BookingZonePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let zones: [String] = (TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") } + ["UTC"])
        .sorted { BookingText.city($0) < BookingText.city($1) }

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = query.isEmpty ? Self.zones : Self.zones.filter {
            $0.lowercased().contains(query) || BookingText.city($0).lowercased().contains(query)
        }
        List(shown, id: \.self) { zone in
            Button {
                selection = zone
                dismiss()
            } label: {
                HStack {
                    Text(BookingText.city(zone)).foregroundStyle(.primary)
                    Spacer()
                    if zone == selection { Image(systemName: "checkmark").foregroundStyle(DS.Palette.accent) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .searchable(text: $search)
        .navigationTitle("Time zone")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Words

/// How a type's settings read on screen.
enum BookingText {
    static let notices = [0, 60, 120, 240, 720, 1440, 2880, 10_080]
    static let horizons = [7, 14, 30, 60, 90]
    static let buffers = [0, 5, 10, 15, 30, 60]

    static func notice(_ minutes: Int) -> String {
        switch minutes {
        case 0: "None"
        case 10_080: "1 week"
        case let m where m % 1440 == 0: m == 1440 ? "1 day" : "\(m / 1440) days"
        default: DS.duration(minutes: Double(minutes))
        }
    }

    static func horizon(_ days: Int) -> String {
        switch days {
        case 7: "1 week"
        case 14: "2 weeks"
        default: "\(days) days"
        }
    }

    static func buffer(_ minutes: Int) -> String { minutes == 0 ? "None" : DS.duration(minutes: Double(minutes)) }

    /// "New York" for America/New_York.
    static func city(_ zone: String) -> String {
        (zone.split(separator: "/").last.map(String.init) ?? zone).replacingOccurrences(of: "_", with: " ")
    }

    /// Weekdays from the locale's first, Sunday = 0.
    static func weekdayOrder(_ calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
    }

    /// "Mon–Fri, 9 AM–5 PM": the days that share the most common hours, then any others; "Off"
    /// with none.
    static func hoursSummary(_ hours: [[BookingSpan]], calendar: Calendar = .current) -> String {
        let open = weekdayOrder(calendar).filter { !hours[$0].isEmpty }
        guard let first = open.first else { return "Off" }
        let symbols = calendar.shortWeekdaySymbols
        let same = open.allSatisfy { hours[$0] == hours[first] }
        let days: String = {
            let positions = open.compactMap { weekdayOrder(calendar).firstIndex(of: $0) }
            let consecutive = positions.count > 2 && positions.last! - positions.first! == positions.count - 1
            if consecutive { return "\(symbols[open.first!])–\(symbols[open.last!])" }
            return open.map { symbols[$0] }.joined(separator: ", ")
        }()
        guard same else { return days }
        let spans = hours[first].map { span in
            TimeRangeText.compact(ClockTime.date(minutes: span.start, calendar: calendar),
                                  ClockTime.date(minutes: min(span.end, 1439), calendar: calendar), calendar: calendar)
        }
        return "\(days), \(spans.joined(separator: ", "))"
    }
}

// MARK: - Sharing the link

/// The booking link as the Mac's share menu takes it: the suggestion is claimed when a service
/// asks for the link (the menu gives no other word that it was shared), so a host with no handle
/// yet shares and takes the suggested one in the same click.
struct BookingLinkItem: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        // Never waits on the main actor: the share sheet may ask for the item from the main thread
        // (an iPad's popover did, and hung). The claim is sent, not awaited.
        ProxyRepresentation(exporting: { (item: BookingLinkItem) -> URL in
            Task { @MainActor in BookingCenter.shared.shared(item.url) }
            return item.url
        })
    }
}

/// "Share booking link" where the calendar is (the Plan's top bar on iPhone and iPad, the Mac's
/// calendar toolbar): one tap to the share sheet, then the person and Send.
struct BookingShareButton: View {
    @ObservedObject private var center = BookingCenter.shared
    @ObservedObject private var account = BananaAccount.shared
    #if os(iOS)
    @State private var anchor: ShareAnchor = {
        let anchor = ShareAnchor()
        anchor.identifier = "booking.share"
        return anchor
    }()
    #endif

    var body: some View {
        if center.isAvailable, let url = center.shareURL {
            #if os(iOS)
            // The system's share sheet, anchored to this button: a toolbar ShareLink's popover sat
            // at the top middle of an iPad, cut off (iPadOS 26). The tap takes the suggestion too.
            Button {
                // The link shown is the link sent; the suggestion is taken once the share went.
                anchor.share(url) { center.shared(url) }
            } label: {
                Label("Share booking link", systemImage: "square.and.arrow.up")
            }
            .background(ShareAnchorView(anchor: anchor))
            .accessibilityIdentifier("booking.share")
            #else
            ShareLink(item: BookingLinkItem(url: url), subject: Text("Book a time"),
                      preview: SharePreview("Book a time")) {
                Label("Share booking link", systemImage: "square.and.arrow.up")
            }
            .help("Share booking link (\u{21E7}\u{2318}L copies it)")
            .accessibilityIdentifier("booking.share")
            #endif
        }
    }
}

#if os(iOS)
/// Where the share sheet points from: the button, by its place on the screen. (A view behind a
/// toolbar item isn't in a window on iPadOS 26, so the frame is what's kept.)
@MainActor
final class ShareAnchor {
    var frame: CGRect = .zero

    func share(_ url: URL, completed: @escaping @MainActor () -> Void = {}) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows) + scenes.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first, var top = window.rootViewController else { return }
        while let shown = top.presentedViewController { top = shown }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, done, _, _ in
            guard done else { return }
            Task { @MainActor in completed() }
        }
        if let popover = sheet.popoverPresentationController {
            if let item = identifier.flatMap({ Self.barItem($0, in: window) }) {
                // A toolbar item is a bar button of the system's: the popover points at it.
                popover.sourceItem = item
            } else {
                popover.sourceView = window
                popover.sourceRect = frame == .zero
                    ? CGRect(x: window.bounds.maxX - 60, y: window.safeAreaInsets.top + 20, width: 1, height: 1)
                    : window.convert(frame, from: nil)
            }
        }
        top.present(sheet, animated: true)
    }

    /// The accessibility id of the toolbar item this shares from, when it is one.
    var identifier: String?

    /// The bar button with this accessibility id in any navigation bar of the window.
    private static func barItem(_ id: String, in view: UIView) -> UIBarButtonItem? {
        if let bar = view as? UINavigationBar {
            for navigationItem in bar.items ?? [] {
                let items = (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
                    + navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
                    + navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
                    + navigationItem.centerItemGroups.flatMap(\.barButtonItems)
                if let match = items.first(where: { $0.accessibilityIdentifier == id }) { return match }
            }
        }
        for child in view.subviews { if let match = barItem(id, in: child) { return match } }
        return nil
    }
}

private struct ShareAnchorView: View {
    let anchor: ShareAnchor

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { anchor.frame = $0 }
    }
}
#endif

/// "Copy booking link", for menus and the share-availability sheet.
struct CopyBookingLinkButton: View {
    @ObservedObject private var center = BookingCenter.shared
    @ObservedObject private var account = BananaAccount.shared
    var confirm = true
    @State private var copied = false

    var body: some View {
        if center.isAvailable, center.shareURL != nil {
            Button {
                center.copyLink(confirm: confirm)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy booking link", systemImage: copied ? "checkmark" : "link")
            }
            .accessibilityIdentifier("booking.copyLink")
        }
    }
}
