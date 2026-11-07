import SwiftUI

/// The first run, led by Banana, the same on a phone, an iPad and a Mac (`OnboardingFlow`).
///
/// Each page is the artwork the owner accepted (output/imagegen/onboarding-v12, edited from the
/// welcome he called "better" on 3 Nov 2026) built natively: the mascot is a picture per page,
/// posed and looking where the art has it look; the band, the calendar cards, the sun and the
/// moon are drawn here; every word and control is text and a system control, so it reads,
/// scales and translates. The pictures sit in an `ArtCanvas`, which places them in the art's own
/// coordinates, so a page and its artwork can be laid side by side and compared.
///
/// What it teaches, one page each: connecting reads; which calendars show and which count as
/// busy (shared ones show but are not busy); Busy copies to Google only on a yes given in front
/// of the real plan's numbers; and a receipt. Nothing gates the app: every page can be skipped,
/// and finishing without copies is a success.
struct OnboardingView: View {
    @EnvironmentObject private var onboarding: OnboardingStore
    @ObservedObject private var google = GoogleCalendarService.shared
    @ObservedObject private var writeBack = CalendarWriteBack.shared
    @ObservedObject private var smart = SmartScheduleStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connecting = false
    @State private var problem: String?

    var body: some View {
        Group {
            switch onboarding.step {
            case .welcome: welcome
            case .modules: modules
            case .wake: dayQuestion(.wake)
            case .windDown: dayQuestion(.windDown)
            case .connect: connect
            case .calendars: calendars
            case .copies: copies
            case .done: done
            }
        }
        .transition(reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)))
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88), value: onboarding.step)
        .background(FirstRun.page.ignoresSafeArea())
        .tint(FirstRun.ink)
        .task {
            #if DEBUG
            if let step = Self.routedStep { onboarding.step = step }
            #endif
            await onboarding.refresh()
            // Back where it was, unless what that page needs has gone meanwhile.
            onboarding.step = OnboardingFlow.resume(onboarding.step, in: situation)
        }
        // An account that arrives by itself (signed in on another device) while the calendar
        // page is up: on, as after a sign-in here.
        .onChange(of: google.isConnected) { _, connected in
            if connected, onboarding.step == .connect, !connecting { writeBack.refreshCalendars() }
        }
        .onChange(of: onboarding.step, initial: true) { _, step in
            if let counted = Self.counted(step) { Telemetry.shared.record(.onboarding(counted, .shown)) }
            // Planned afresh each time the page comes up: the calendars page before it may have
            // changed what counts as busy.
            if step == .copies { Task { await onboarding.loadCopyPreview() } }
        }
    }

    /// The service counts the steps it knows (`Service/src/usage.js`); the pages added on
    /// 6 Nov 2026 report as the nearest of those, or not at all, until it learns their names.
    private static func counted(_ step: OnboardingStep) -> Telemetry.Signal.Step? {
        switch step {
        case .welcome: .welcome
        case .modules, .copies: nil
        case .wake: .wake
        case .windDown: .winddown
        case .connect: .calendar
        case .calendars: .otherCalendar
        case .done: .done
        }
    }

    private var situation: OnboardingFlow.Situation {
        OnboardingFlow.Situation(accounts: accountEmails.count,
                                 copiesSettled: writeBack.questionSettled,
                                 ownsWritableCalendar: Self.isSample || writeBack.writableCalendars.contains(where: \.isOwner))
    }

    // MARK: - Welcome

    private var welcome: some View {
        FirstRunPage(title: "Your day.\nA little lighter.", wordmark: true) {
            ArtCanvas(top: 400, bottom: 990) { art in
                WelcomeScene(art: art)
            }
        } actions: {
            Button("Build my day") { advance() }
                .buttonStyle(FirstRun.primary)
                .accessibilityIdentifier("onboarding.continue")
            DemoEntryButton(plainTitle: "Explore an example")
                .buttonStyle(.plain)
                .font(FirstRun.bodyFont)
                .foregroundStyle(FirstRun.ink)
            // Getting started is agreeing to them: the one place they're asked for.
            Text("By continuing you agree to the [Terms](\(Telemetry.termsURL.absoluteString)) and [Privacy Policy](\(Telemetry.privacyURL.absoluteString)).")
                .font(.footnote)
                .foregroundStyle(FirstRun.secondaryInk)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("onboarding.terms")
        }
    }

    // MARK: - What Banana looks after

    private var modules: some View {
        FirstRunPage(title: "What should Banana look after?", onBack: back, cornerOverlap: 44, titlePoints: 34) {
            ModuleChooser(choice: $onboarding.modules)
        } actions: {
            Button("Continue") {
                ModuleStore.shared.set(onboarding.modules)
                advance()
            }
            .buttonStyle(FirstRun.primary)
            .accessibilityIdentifier("onboarding.continue")
        } corner: {
            ArtCanvas(top: 200, bottom: 530) { art in ModulesScene(art: art) }
        }
    }

    // MARK: - The two questions

    private enum DayEnd { case wake, windDown }

    private func dayQuestion(_ end: DayEnd) -> some View {
        let minutes: WritableKeyPath<DayAnchors, Int> = end == .wake ? \.wakeMinutes : \.windDownMinutes
        let range = end == .wake ? DayAnchors.wakeRange : DayAnchors.windDownRange
        return FirstRunPage(title: end == .wake ? "When do you wake up?" : "When do you wind down?", onBack: back) {
            TimeChooser(minutes: Binding(get: { onboarding.anchors[keyPath: minutes] },
                                         set: { onboarding.anchors[keyPath: minutes] = $0 }),
                        range: range, track: end == .wake ? FirstRun.yellow : FirstRun.lilacTrack,
                        id: end == .wake ? "onboarding.wake.time" : "onboarding.windDown.time")
            ArtCanvas(top: end == .wake ? 790 : 760, bottom: end == .wake ? 1160 : 1240) { art in
                if end == .wake { SunriseScene(art: art) } else { MoonriseScene(art: art) }
            }
            Text(end == .wake ? "Adds a Wake routine to your plan." : "Adds a Wind down routine to your plan.")
                .font(FirstRun.bodyFont)
                .foregroundStyle(FirstRun.ink)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        } actions: {
            Button(end == .wake ? "That\u{2019}s my morning" : "That\u{2019}s my evening") {
                onboarding.applyAnchors()   // on the plan as soon as it is answered
                advance()
            }
            .buttonStyle(FirstRun.primary)
            .accessibilityIdentifier("onboarding.continue")
            Button("Skip") { skip() }
                .buttonStyle(FirstRun.quiet)
                .accessibilityIdentifier("onboarding.skip")
        }
    }

    // MARK: - Calendar

    private var connect: some View {
        let emails = accountEmails
        return FirstRunPage(title: "Bring in your calendars", onBack: back) {
            ArtCanvas(top: 420, bottom: 1000) { art in ConnectScene(art: art) }
            Text("Connecting only reads your calendars.")
                .font(FirstRun.bodyFont)
                .foregroundStyle(FirstRun.ink)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            if !emails.isEmpty {
                AccountRows(emails: emails, adding: connecting) { Task { await addAccount() } }
            }
        } actions: {
            if let problem { ProblemLine(text: problem, id: "onboarding.calendar.problem") }
            if emails.isEmpty {
                GoogleButton(working: connecting, cornerRadius: FirstRun.buttonRadius) { Task { await connectGoogle() } }
                Button("Not now") {
                    Telemetry.shared.record(.onboarding(.calendar, .skipped))
                    finish()
                }
                .buttonStyle(FirstRun.quiet)
                .accessibilityIdentifier("onboarding.notNow")
            } else {
                Button("Continue") { advance() }
                    .buttonStyle(FirstRun.primary)
                    .disabled(connecting)
                    .accessibilityIdentifier("onboarding.continue")
            }
        }
    }

    private var calendarRows: [CalendarChoice] {
        CalendarChoices.rows(Self.isSample ? Self.sampleCalendars : google.calendars, settings: smart.settings)
    }

    private var calendars: some View {
        let rows = calendarRows
        return FirstRunPage(title: "What makes you busy?", onBack: back) {
            ArtCanvas(top: 400, bottom: 960) { art in
                CalendarsScene(art: art,
                               busy: rows.first(where: \.busy)?.title ?? "Work",
                               notBusy: rows.first(where: { $0.shown && !$0.busy })?.title)
            }
            if rows.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
            CalendarChoiceList(rows: rows) { change in
                var settings = smart.settings
                change(&settings)
                smart.settings = settings
            }
        } actions: {
            Button("Continue") { advance() }
                .buttonStyle(FirstRun.primary)
                .accessibilityIdentifier("onboarding.continue")
        }
    }

    // MARK: - Busy copies

    private var copies: some View {
        let shown: BusyCopyPreview? = switch onboarding.copies {
        case .ready(let preview, _), .applying(let preview): preview
        default: nil
        }
        let applying = { if case .applying = onboarding.copies { true } else { false } }()
        return FirstRunPage(title: "Copy busy time?", onBack: back) {
            ArtCanvas(top: 280, bottom: 1000) { art in
                CopiesScene(art: art,
                            source: shown?.sources.first ?? "Personal",
                            destination: shown?.changing.first?.title ?? shown?.destinations.first?.title ?? "Work")
            }
            CopySummary(state: onboarding.copies) { Task { await onboarding.loadCopyPreview() } }
        } actions: {
            Button(Self.createTitle(shown)) {
                Task {
                    if await onboarding.turnOnCopies() {
                        Telemetry.shared.record(.onboarding(.otherCalendar, .continued))
                        advance()
                    }
                }
            }
            .buttonStyle(FirstRun.primary)
            .disabled(shown == nil || applying)
            .accessibilityIdentifier("onboarding.copies.create")
            Button("Keep viewing only") {
                onboarding.keepViewingOnly()
                advance()
            }
            .buttonStyle(FirstRun.quiet)
            .disabled(applying)
            .accessibilityIdentifier("onboarding.copies.keep")
        }
    }

    static func createTitle(_ preview: BusyCopyPreview?) -> String {
        guard let preview, preview.creates > 0 else { return "Turn on copies" }
        return preview.creates == 1 ? "Create 1 Busy event" : "Create \(preview.creates) Busy events"
    }

    // MARK: - Receipt

    private var done: some View {
        let receipt = OnboardingReceipt(
            choices: calendarRows,
            copies: onboarding.copiesAnswer ?? (writeBack.enabled ? .on(count: nil, to: []) : .off))
        return FirstRunPage(title: "Your day is ready") {
            ArtCanvas(top: 230, bottom: 880) { art in DoneScene(art: art) }
            ReceiptRows(receipt: receipt, copyProblem: writeBack.enabled ? writeBack.lastError : nil)
        } actions: {
            Button("Open my day") { finish() }
                .buttonStyle(FirstRun.primary)
                .accessibilityIdentifier("onboarding.open")
        }
    }

    // MARK: - Accounts

    private var accountEmails: [String] {
        Self.isSample ? ["noor@plan.example"] : google.accounts.map(\.email)
    }

    @MainActor
    private func connectGoogle() async {
        guard !connecting else { return }
        connecting = true
        problem = nil
        let connected = await onboarding.requestCalendar()
        connecting = false
        if connected {
            advance()
        } else {
            // Closing Google's page leaves no message, and needs none.
            problem = onboarding.calendarErrorMessage
        }
    }

    @MainActor
    private func addAccount() async {
        guard !connecting else { return }
        connecting = true
        problem = nil
        await google.connect()
        writeBack.refreshCalendars()
        connecting = false
        problem = google.lastError
    }

    // MARK: - Moving on

    private func advance() {
        if let counted = Self.counted(onboarding.step) { Telemetry.shared.record(.onboarding(counted, .continued)) }
        if let next = OnboardingFlow.next(after: onboarding.step, in: situation) {
            onboarding.step = next
        } else {
            finish()
        }
    }

    /// A day question passed over: its routine keeps the time it has.
    private func skip() {
        if let counted = Self.counted(onboarding.step) { Telemetry.shared.record(.onboarding(counted, .skipped)) }
        if let next = OnboardingFlow.next(after: onboarding.step, in: situation) { onboarding.step = next }
    }

    private func back() {
        if let previous = OnboardingFlow.previous(before: onboarding.step) { onboarding.step = previous }
    }

    /// Into the app, on the plan.
    private func finish() {
        Telemetry.shared.record(.onboarding(.done, .shown))
        onboarding.finish()
    }

    // MARK: - Routes and samples for pictures

    #if DEBUG
    /// `--onboarding-step <name>`: straight to one page, for a picture of it.
    static var routedStep: OnboardingStep? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--onboarding-step"), index + 1 < arguments.count else { return nil }
        return OnboardingStep(rawValue: arguments[index + 1])
    }
    #endif

    /// A simulator has no Google account: `--onboarding-sample` (Debug only) shows the calendar
    /// pages with one made-up account and three calendars, and the copies page with a sample
    /// plan (`CalendarWriteBack.samplePreview`).
    static var isSample: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--onboarding-sample")
        #else
        false
        #endif
    }

    static let sampleCalendars: [GoogleCalendar] = [
        GoogleCalendar(accountEmail: "noor@plan.example", id: "noor@plan.example", summary: "Work", summaryOverride: nil,
                       backgroundColor: "#8E62DE", accessRole: "owner", primary: true, hidden: nil, deleted: nil),
        GoogleCalendar(accountEmail: "noor@plan.example", id: "personal@group.calendar.google.com", summary: "Personal",
                       summaryOverride: nil, backgroundColor: "#52B188", accessRole: "owner", primary: nil, hidden: nil,
                       deleted: nil, dataOwner: "noor@plan.example"),
        GoogleCalendar(accountEmail: "noor@plan.example", id: "family@group.calendar.google.com", summary: "Family",
                       summaryOverride: nil, backgroundColor: "#FD6F5B", accessRole: "writer", primary: nil, hidden: nil,
                       deleted: nil, dataOwner: "sam@plan.example"),
    ]
}

// MARK: - Look

/// The first run's look, from the accepted artwork: ivory page, the website's ink, the brand's
/// yellow, and three pastel calendar colours. Dark appearance keeps the yellow and the pastels
/// and turns the page and the ink round.
enum FirstRun {
    /// The artwork is 1024 wide at a phone's width; `ArtCanvas` places pictures in those units.
    static let artWidth: CGFloat = 1024
    static let margin: CGFloat = DS.Space.xxl + DS.Space.xs
    static let buttonRadius: CGFloat = DS.Radius.panel
    static let columnWidth: CGFloat = 560

    static let page = adaptive(light: DS.Palette.Brand.ivory, dark: rgb(0x17151F))
    static let ink = adaptive(light: DS.Palette.Brand.night, dark: rgb(0xF6F1E6))
    static let secondaryInk = adaptive(light: rgb(0x6C687A), dark: rgb(0xB5B0C0))
    static let card = adaptive(light: rgb(0xFFFDF8), dark: rgb(0x262330))
    static let cardLine = adaptive(light: rgb(0xE9E3D6), dark: rgb(0x3A3646))
    static let grid = adaptive(light: rgb(0xEFEAE0), dark: rgb(0x332F3E))
    static let yellow = DS.Palette.Brand.yellow

    static let lilac = (fill: rgb(0xEDE4FE), dot: rgb(0x8E62DE), text: rgb(0x5B37C8), block: rgb(0xB6A2E6))
    static let mint = (fill: rgb(0xE5F4E8), dot: rgb(0x52B188), text: rgb(0x2E8A5E), block: rgb(0x6FBF9D))
    static let coral = (fill: rgb(0xFFE5DE), dot: rgb(0xFD6F5B), text: rgb(0xE5533F), block: rgb(0xF97F6B))
    static let lilacShape = rgb(0xC9B8EC)
    static let lilacTrack = rgb(0xC3B1EA)
    static let busyGrey = rgb(0xDADADF)

    static var primary: AppButtonStyle {
        AppButtonStyle(kind: .primary, size: .page, fill: ink, label: page, cornerRadius: buttonRadius)
    }
    static var quiet: QuietStyle { QuietStyle() }

    /// The quiet choice under the main button, in the page's ink (the art's), on a finger's target.
    struct QuietStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.frame(maxWidth: .infinity, minHeight: DS.Row.minHeight)
            }
            .buttonStyle(.borderless)
            .font(.body)
            .foregroundStyle(FirstRun.ink)
        }
    }

    static let bodyFont = Font.body
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).leading(.tight) }

    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    static func adaptive(light: Color, dark: Color) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}

// MARK: - A page

/// One page of the first run: Back, the headline, the picture and what to choose, and the
/// actions at the bottom (a phone) or under the column (an iPad or a Mac window).
struct FirstRunPage<Content: View, Actions: View, Corner: View>: View {
    let title: String
    var wordmark = false
    var onBack: (() -> Void)?
    /// Room kept at the headline's trailing edge for a picture beside it, as a share of the width.
    var titleTrailingRoom: CGFloat = 0
    /// How far a corner picture rises into the headline's last line.
    var cornerOverlap: CGFloat = 0
    /// The headline's size in points, before Dynamic Type (the art's are 40 to 46).
    var titlePoints: CGFloat = 42
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @ViewBuilder var corner: Corner
    @ScaledMetric(relativeTo: .largeTitle) private var titleScale: CGFloat = 1
    @Environment(\.horizontalSizeClass) private var widthClass

    private var roomy: Bool {
        #if os(macOS)
        true
        #else
        widthClass == .regular
        #endif
    }

    var body: some View {
        GeometryReader { window in
            let column = min(window.size.width, roomy ? FirstRun.columnWidth : window.size.width)
            let bleed = max(0, (window.size.width - column) / 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Spare height on a phone: a quarter above the page, the rest above the buttons.
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        header
                        if Corner.self != EmptyView.self {
                            VStack(spacing: 0) { corner }.padding(.top, -cornerOverlap)
                        }
                        VStack(alignment: .leading, spacing: DS.Space.l) { content }
                    }
                    if roomy {
                        // A window: the page and its buttons as one block in the middle.
                        actionStack.padding(.top, DS.Space.xxl)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: DS.Space.xl)
                        Spacer(minLength: 0)
                        Spacer(minLength: 0)
                        actionStack
                    }
                }
                .environment(\.firstRunBleed, bleed)
                .environment(\.firstRunFullBleed, !roomy)
                .padding(.horizontal, roomy ? 0 : FirstRun.margin)
                .frame(width: column)
                .padding(.bottom, DS.Space.s)
                .frame(maxWidth: .infinity, minHeight: window.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(FirstRun.page.ignoresSafeArea())
    }

    private var actionStack: some View {
        VStack(spacing: DS.Space.xs) { actions }
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(FirstRun.ink)
                        .frame(width: DS.Row.minHeight, height: DS.Row.minHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            } else if wordmark {
                Text(verbatim: "banana")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(FirstRun.ink)
                    .padding(.top, DS.Space.s)
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(height: DS.Space.l)
            }
            Text(title)
                .font(FirstRun.title(titlePoints * titleScale))
                .tracking(-0.6)
                .foregroundStyle(FirstRun.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, titleTrailingRoom)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

extension FirstRunPage where Corner == EmptyView {
    init(title: String, wordmark: Bool = false, onBack: (() -> Void)? = nil, titlePoints: CGFloat = 42,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, wordmark: wordmark, onBack: onBack, titlePoints: titlePoints,
                  content: content, actions: actions, corner: { EmptyView() })
    }
}

private struct FirstRunBleedKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct FirstRunFullBleedKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// How far the pictures' bands may run past the column on each side, in points.
    var firstRunBleed: CGFloat {
        get { self[FirstRunBleedKey.self] }
        set { self[FirstRunBleedKey.self] = newValue }
    }
    /// The canvas spans the whole screen (a phone), not a column.
    var firstRunFullBleed: Bool {
        get { self[FirstRunFullBleedKey.self] }
        set { self[FirstRunFullBleedKey.self] = newValue }
    }
}

/// Something that went wrong, said once over the buttons.
private struct ProblemLine: View {
    let text: String
    let id: String
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(DS.Palette.danger)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }
}

// MARK: - The time

/// The big time and the strip of half-hours under it. Each tick is a button; choosing an outer
/// one brings the strip round it, so any time in the range is a few taps away. VoiceOver adjusts
/// the time a quarter of an hour at a time.
private struct TimeChooser: View {
    @Binding var minutes: Int
    let range: ClosedRange<Int>
    let track: Color
    let id: String
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 80
    @ScaledMetric(relativeTo: .title2) private var periodSize: CGFloat = 24

    var body: some View {
        VStack(spacing: DS.Space.m) {
            clock
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(DayClock.label(minutes))
                .accessibilityIdentifier(id)
                .accessibilityAdjustableAction { direction in
                    let step = direction == .increment ? 15 : direction == .decrement ? -15 : 0
                    minutes = min(max(minutes + step, range.lowerBound), range.upperBound)
                }
            strip
        }
    }

    private var clock: some View {
        let parts = DayClock.parts(minutes)
        return HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
            Text(parts.time)
                .font(.system(size: clockSize, weight: .heavy, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            if let period = parts.period {
                Text(period).font(.system(size: periodSize, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(FirstRun.ink)
        .animation(.snappy(duration: 0.2), value: minutes)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var strip: some View {
        let ticks = TimeTicks.around(minutes, in: range)
        return ZStack {
            Capsule().fill(track).frame(height: 3).padding(.horizontal, -DS.Space.s)
            HStack(spacing: 0) {
                ForEach(ticks, id: \.self) { tick in
                    let chosen = tick == (minutes / TimeTicks.step) * TimeTicks.step
                    Button {
                        minutes = tick
                    } label: {
                        VStack(spacing: DS.Space.s) {
                            Circle()
                                .fill(chosen ? FirstRun.ink : track)
                                .frame(width: chosen ? 18 : 9, height: chosen ? 18 : 9)
                                .frame(height: 18)
                            Text(DayClock.parts(tick).time)
                                .font(chosen ? .callout.weight(.bold) : .callout)
                                .monospacedDigit()
                                .foregroundStyle(FirstRun.ink)
                        }
                        .frame(maxWidth: .infinity, minHeight: DS.Row.minHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(DayClock.label(tick))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("onboarding.time.\(tick)")
                }
            }
            .alignmentGuide(VerticalAlignment.center) { $0[VerticalAlignment.top] + 9 }
        }
        .animation(.snappy(duration: 0.2), value: ticks)
    }
}

/// A time of day as the person's clock writes it, split so the period can be set smaller.
enum DayClock {
    static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func label(_ minutes: Int) -> String { date(minutes).formatted(date: .omitted, time: .shortened) }

    /// An hour on its own, "2" or "3 PM" (or "14", "15" on a 24-hour clock).
    static func hour(_ hour: Int, withPeriod: Bool = false) -> String {
        let parts = parts(hour * 60)
        let time = parts.time.hasSuffix(":00") ? String(parts.time.dropLast(3)) : parts.time
        return withPeriod ? [time, parts.period].compactMap { $0 }.joined(separator: " ") : time
    }

    static func parts(_ minutes: Int) -> (time: String, period: String?) {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let full = formatter.string(from: date(minutes))
        let symbols = [formatter.amSymbol, formatter.pmSymbol].compactMap { $0 }
        for symbol in symbols where full.contains(symbol) {
            let time = full.replacingOccurrences(of: symbol, with: "").trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\u{202F}")))
            return (time, symbol)
        }
        return (full, nil)
    }
}

// MARK: - Lists

/// What Banana looks after: Plan always, then each module, then Everything.
private struct ModuleChooser: View {
    @Binding var choice: ModuleChoice
    @ObservedObject private var availableModules = ModuleStore.shared

    private struct Row {
        let module: AppModule
        let title: String
    }

    private let rows = [
        Row(module: .workouts, title: "Track workouts and sleep"),
        Row(module: .food, title: "Log your meals"),
        Row(module: .notes, title: "Keep notes"),
        Row(module: .podcasts, title: "Listen to podcasts"),
        Row(module: .email, title: "Email"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            line(title: "Plan your day", symbol: AppSection.plan.symbol,
                 colour: DS.Palette.Brand.yellow, glyph: DS.Palette.Brand.ink, on: true, fixed: true)
                .accessibilityElement(children: .combine)
                .accessibilityValue("Always on")
            ForEach(rows.filter { availableModules.selectable.contains($0.module) }, id: \.module) { row in
                let on = choice.includes(row.module)
                Button {
                    choice = choice.setting(row.module, on: !on)
                } label: {
                    line(title: row.module.statusLabel.map { "\(row.title) · \($0)" } ?? row.title,
                         symbol: row.module.symbol, colour: row.module.tint, on: on)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .disabled(!row.module.isAvailable)
                .accessibilityIdentifier("onboarding.module.\(row.module.rawValue)")
            }
            Button {
                choice = choice.isEverything ? .planOnly : .everything
            } label: {
                line(title: "Everything", symbol: "infinity",
                     colour: FirstRun.ink, glyph: FirstRun.page, on: choice.isEverything)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(choice.isEverything ? .isSelected : [])
            .accessibilityIdentifier("onboarding.module.everything")
        }
    }

    private func line(title: String, symbol: String, colour: Color, glyph: Color? = nil,
                      on: Bool, fixed: Bool = false) -> some View {
        HStack(spacing: DS.Space.l) {
            IconTile(systemImage: symbol, tint: colour, size: DS.Row.glyphTile, glyph: glyph)
            Text(title)
                .font(.title3)
                .foregroundStyle(FirstRun.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title)
                .foregroundStyle(FirstRun.ink)
                .opacity(fixed ? 0.85 : 1)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// The Google accounts that are in, each ticked, and a row that adds another.
private struct AccountRows: View {
    let emails: [String]
    let adding: Bool
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(emails, id: \.self) { email in
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DS.Palette.success)
                        .accessibilityHidden(true)
                    Text(email)
                        .font(.body)
                        .foregroundStyle(FirstRun.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: DS.Row.minHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(email), connected")
                Divider()
            }
            Button(action: add) {
                HStack(spacing: DS.Space.m) {
                    if adding { ProgressView().controlSize(.small) } else {
                        Image(systemName: "plus.circle").font(.title3).accessibilityHidden(true)
                    }
                    Text("Add another account").font(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(FirstRun.ink)
                .frame(minHeight: DS.Row.minHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(adding)
            .accessibilityIdentifier("onboarding.other.add")
        }
    }
}

/// Every calendar, with whether it shows and whether it makes the person busy: two system
/// switches under two column labels.
private struct CalendarChoiceList: View {
    let rows: [CalendarChoice]
    let change: ((inout SmartScheduleSettings) -> Void) -> Void
    @ScaledMetric(relativeTo: .body) private var column: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("Show").frame(width: column)
                Text("Busy").frame(width: column)
            }
            .font(.subheadline)
            .foregroundStyle(FirstRun.secondaryInk)
            .padding(.bottom, DS.Space.xs)
            .accessibilityHidden(true)
            Divider()
            ForEach(rows) { row in
                HStack(spacing: DS.Space.m) {
                    Circle()
                        .fill(row.colorHex.map { calendarTint($0) } ?? FirstRun.secondaryInk)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(row.title)
                        .font(.body)
                        .foregroundStyle(FirstRun.ink)
                        .lineLimit(1)
                    if !row.isOwner {
                        Text("Shared")
                            .font(.caption)
                            .foregroundStyle(FirstRun.secondaryInk)
                            .padding(.horizontal, DS.Space.s - 2)
                            .padding(.vertical, DS.Space.hair)
                            .background(Color.primary.opacity(DS.Tint.subtle), in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                    }
                    Spacer(minLength: DS.Space.s)
                    Toggle("Show \(row.title)", isOn: Binding(
                        get: { row.shown },
                        set: { on in change { CalendarChoices.setShown(on, for: row, in: &$0) } }))
                        .labelsHidden()
                        .frame(width: column)
                        .accessibilityIdentifier("onboarding.show.\(row.title)")
                    Toggle("\(row.title) makes you busy", isOn: Binding(
                        get: { row.busy },
                        set: { on in change { CalendarChoices.setBusy(on, for: row, in: &$0) } }))
                        .labelsHidden()
                        .frame(width: column)
                        .accessibilityIdentifier("onboarding.busy.\(row.title)")
                }
                .tint(FirstRun.ink)
                .frame(minHeight: 52)
                Divider()
            }
        }
    }
}

/// The consent's numbers, from the planner, and what is happening to them.
private struct CopySummary: View {
    let state: OnboardingStore.CopiesState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: DS.Space.xs) {
            switch state {
            case .idle, .loading:
                ProgressView().frame(minHeight: 56)
                    .accessibilityLabel("Working out what would be copied")
            case .ready(let preview, let updated):
                numbers(preview, updated: updated)
            case .applying(let preview):
                numbers(preview, updated: false)
            case .failed(let message):
                Text(message)
                    .font(.body)
                    .foregroundStyle(DS.Palette.danger)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("onboarding.copies.problem")
                Button("Retry", action: retry)
                    .buttonStyle(AppButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("onboarding.copies.retry")
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity)
        .background(FirstRun.card, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(FirstRun.cardLine))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.copies.summary")
    }

    @ViewBuilder private func numbers(_ preview: BusyCopyPreview, updated: Bool) -> some View {
        headline(preview)
        Text(detail(preview))
            .font(.subheadline)
            .foregroundStyle(FirstRun.secondaryInk)
            .multilineTextAlignment(.center)
        if updated {
            Text("Updated")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DS.Palette.Brand.night)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.hair)
                .background(FirstRun.yellow, in: Capsule())
                .accessibilityIdentifier("onboarding.copies.updated")
        }
    }

    private func headline(_ preview: BusyCopyPreview) -> some View {
        let names = preview.changing.map(\.title)
        let text = preview.creates == 0
            ? "Nothing to copy yet"
            : "\(preview.creates) Busy event\(preview.creates == 1 ? "" : "s") on \(OnboardingReceipt.line(names))"
        return Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(FirstRun.ink)
            .multilineTextAlignment(.center)
    }

    private func detail(_ preview: BusyCopyPreview) -> String {
        var parts = ["From \(OnboardingReceipt.line(preview.sources))"]
        if let start = preview.start, let end = preview.end {
            parts.append((start..<max(end, start)).formatted(.interval.month(.abbreviated).day()))
        }
        if preview.updates > 0 { parts.append("\(preview.updates) updated") }
        if preview.removals > 0 { parts.append("\(preview.removals) removed") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// The receipt: Shown, Busy and Copies, each one line.
private struct ReceiptRows: View {
    let receipt: OnboardingReceipt
    let copyProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            row("Shown", OnboardingReceipt.line(receipt.shown))
            Divider()
            row("Busy", OnboardingReceipt.line(receipt.busy))
            Divider()
            row("Copies", receipt.copiesLine)
            if let copyProblem {
                HStack(alignment: .firstTextBaseline) {
                    Text(copyProblem)
                        .font(.footnote)
                        .foregroundStyle(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.s)
                    Button("Retry") { OccurrenceStore.shared.requestRecompute(reason: "first run copy retry") }
                        .buttonStyle(AppButtonStyle(kind: .secondary, size: .small))
                        .accessibilityIdentifier("onboarding.copies.retry")
                }
                .padding(.vertical, DS.Space.s)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.l) {
            Text(label).foregroundStyle(FirstRun.secondaryInk)
            Spacer(minLength: DS.Space.s)
            Text(value)
                .foregroundStyle(FirstRun.ink)
                .multilineTextAlignment(.trailing)
        }
        .font(.body)
        .frame(minHeight: 50)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.receipt.\(label.lowercased())")
    }
}

// MARK: - The calendar's explanation

/// Why connect a Google calendar: a small day as the opener, a title, and three reasons of a
/// few words each. No paragraph and no small print: the day says what the paragraph did, and
/// which calendars keep each other busy is the next sheet's to say. The first run's second
/// step, and what the setup list shows for its Google Calendar row.
struct CalendarPrimer: View {
    var body: some View {
        DayPreview()
        Text("Start with your calendar")
            .font(.title.bold())
            .pageTitle()
            .accessibilityAddTraits(.isHeader)
        // The tiles take the colours of the day above them.
        ReasonCard(reasons: [
            Reason(symbol: "calendar.day.timeline.left", text: "Your meetings on one timeline",
                   tint: DS.Palette.Brand.blue),
            Reason(symbol: "calendar.badge.plus", text: "Changes here save to Google",
                   tint: DS.Palette.Brand.green),
            Reason(symbol: "arrow.triangle.2.circlepath", text: "Sync through Banana Cloud",
                   tint: DS.Palette.Brand.purple),
        ])
    }
}

/// A few hours of a plan, drawn with the plan's own blocks: the thing being offered, where a
/// calendar symbol in a circle used to be.
private struct DayPreview: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let hour: String
        let title: String
        let time: String
        let tint: Color
        var tall = false
    }

    private let entries = [
        Entry(hour: "9", title: "Team standup", time: "9\u{2013}9:30 AM", tint: DS.Palette.Brand.blue),
        Entry(hour: "10", title: "Design review", time: "10\u{2013}11:30 AM", tint: DS.Palette.Brand.purple, tall: true),
        Entry(hour: "12", title: "Lunch with Sam", time: "12:30\u{2013}1:15 PM", tint: DS.Palette.Brand.green),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "circle")
                    .foregroundStyle(DS.Palette.task)
                Text("Send the proposal")
                    .font(.footnote.weight(.medium))
                Text("due today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 30 + DS.Space.s)
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Text(entry.hour)
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title).font(.footnote.weight(.semibold))
                            Text(entry.time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, DS.Space.xs + 2)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: entry.tall ? 50 : 38, alignment: .top)
                    .background(entry.tint.opacity(DS.Event.fill))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.block, style: .continuous))
                }
            }
        }
        // Kept short: under the title bar of the setup list's sheet, the page still fits a phone
        // with its note in view.
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A sample day: a reminder due today, Team standup at 9, Design review at 10, Lunch with Sam at 12:30.")
    }
}
