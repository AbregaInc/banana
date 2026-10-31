import Combine
import Foundation

/// Where Mail was, for a cold launch within the hour. Ids only: never a subject, an address or a
/// draft's text (MAIL-ENGINE 13.8). The slice's cut of the design's `MailShellState`, which also
/// holds the place, a composer and the scroll position; those arrive with the screens they are for.
struct MailShellState: Codable, Equatable {
    /// `MailConversationID.text` of the open conversation.
    var open: String?
}

/// Where the person is in the app: the tab, and what each tab has open.
///
/// It lives outside the view tree on purpose. On iOS the whole tree is replaced with black a
/// couple of seconds after backgrounding (`AppVisibility` — the guard against background CPU
/// kills), so anything a view held in `@State` went with it: open a note, switch to another app,
/// come back, and you were on Plan with the note gone. The Mac rebuilds a section's view every
/// time the sidebar leaves it, which lost the selected note the same way.
///
/// Held in memory it survives any rebuild. It is also written to UserDefaults so a process iOS
/// reclaimed in the background comes back in the same place — within `ShellState.restoreWindow`.
/// After that a launch opens on Plan: the next morning should start on the day, not on
/// whatever was open last night.
struct ShellState: Codable, Equatable {
    /// The same sections the Mac sidebar lists: a phone's tab bar shows five of them, an iPad's
    /// sidebar (or any regular-width window) all of them.
    typealias Tab = AppSection

    /// A screen on the Workouts stack.
    enum WorkoutsRoute: Codable, Hashable {
        /// A saved stack, cut off at the first screen that belongs to a feature that is switched
        /// off (`Features`): a place saved inside guided plans opens on what was under it.
        static func available(_ stack: [WorkoutsRoute], guidedPlans: Bool = Features.guidedPlans) -> [WorkoutsRoute] {
            guard !guidedPlans else { return stack }
            return Array(stack.prefix { route in
                switch route {
                case .guidedPlans, .plan, .coach: return false
                default: return true
                }
            })
        }

        /// A workout's detail, by `WorkoutEntry.id`.
        case workout(String)
        case guidedPlans
        case plan(UUID)
        /// The guided-workout coach; its progress lives in `GuidedSessionStore`.
        case coach(UUID)
        /// The Sleep page (`SleepView`).
        case sleep
        /// Every Health metric's trend (`TrendsView`), for a `TrendWindow` in days.
        case trends(window: Int)
        /// One metric's trend (`TrendDetailView`), by `MetricKind.trendID`.
        case trend(String, window: Int)
    }

    var tab: Tab = .plan
    /// The Workouts stack.
    var workouts: [WorkoutsRoute] = []
    /// The Notes stack — the open note.
    var notes: [UUID] = []
    /// The Library stack — the open podcast.
    var library: [UUID] = []
    /// Nutrition's Food / Taken switch, by its raw value.
    var nutritionSection: String?
    /// Nutrition's open "log food" sheet, by its raw value — so a half-typed meal is still open
    /// after a trip to another app.
    var nutritionCapture: String?
    /// The open note composer: "new", or the id of the note being edited. Kept so a half-written
    /// note is still open after a trip to another app.
    var noteComposer: String?
    /// The day Nutrition's Food tab is showing, when it isn't today.
    var nutritionDay: Date?
    /// Mail's open conversation. Written when the app goes to the background, never by a key or
    /// a tap: `ShellNavigation.state` is observed by the whole shell.
    var mail: MailShellState?
    /// When this was last written. Stamped on save, read on a cold launch.
    var savedAt: Date?

    init(tab: Tab = .plan, workouts: [WorkoutsRoute] = [], notes: [UUID] = [], library: [UUID] = [],
         nutritionSection: String? = nil, nutritionCapture: String? = nil, noteComposer: String? = nil,
         nutritionDay: Date? = nil, mail: MailShellState? = nil, savedAt: Date? = nil) {
        self.tab = tab
        self.workouts = workouts
        self.notes = notes
        self.library = library
        self.nutritionSection = nutritionSection
        self.nutritionCapture = nutritionCapture
        self.noteComposer = noteComposer
        self.nutritionDay = nutritionDay
        self.mail = mail
        self.savedAt = savedAt
    }

    /// Every field is optional on the way in, so a state saved before a field existed still
    /// restores instead of being thrown away whole.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tab = try c.decodeIfPresent(Tab.self, forKey: .tab) ?? .plan
        workouts = WorkoutsRoute.available((try? c.decodeIfPresent([WorkoutsRoute].self, forKey: .workouts)) ?? [])
        notes = try c.decodeIfPresent([UUID].self, forKey: .notes) ?? []
        library = try c.decodeIfPresent([UUID].self, forKey: .library) ?? []
        nutritionSection = try c.decodeIfPresent(String.self, forKey: .nutritionSection)
        nutritionCapture = try c.decodeIfPresent(String.self, forKey: .nutritionCapture)
        noteComposer = try c.decodeIfPresent(String.self, forKey: .noteComposer)
        nutritionDay = try c.decodeIfPresent(Date.self, forKey: .nutritionDay)
        mail = try? c.decodeIfPresent(MailShellState.self, forKey: .mail)
        savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt)
    }

    /// How long after leaving the app a cold launch still returns to where it was.
    static let restoreWindow: TimeInterval = 60 * 60

    /// What a cold launch should open with, given what was saved.
    static func restored(from data: Data?, now: Date = Date()) -> ShellState {
        guard let data,
              let saved = try? JSONDecoder().decode(ShellState.self, from: data),
              let savedAt = saved.savedAt,
              now.timeIntervalSince(savedAt) >= 0,
              now.timeIntervalSince(savedAt) <= restoreWindow
        else { return ShellState() }
        return saved
    }

    /// Drops stacked IDs that no longer resolve, so a restore never lands on "Podcast
    /// unavailable" for something deleted in the meantime — here or on another device.
    /// An empty `known` set means the store hasn't loaded yet, and the stack is kept as is.
    static func pruned(_ stack: [UUID], known: Set<UUID>) -> [UUID] {
        guard !known.isEmpty else { return stack }
        return stack.filter(known.contains)
    }
}

@MainActor
final class ShellNavigation: ObservableObject {
    static let shared = ShellNavigation()

    static let defaultsKey = "shellState"   // dot-free: see the dotted-AppStorage render storm

    @Published var state: ShellState {
        didSet { if state != oldValue { save() } }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        #if DEBUG
        // A launch told where to open — a preview route, a UI test — doesn't go back to where
        // the last one was. A sheet one test left open came back over the next test's screen,
        // for an hour, and the next test failed on whatever was underneath.
        if defaults === UserDefaults.standard, Self.isDirectedLaunch {
            self.state = ShellState()
            return
        }
        #endif
        self.state = ShellState.restored(from: defaults.data(forKey: Self.defaultsKey), now: now)
    }

    #if DEBUG
    /// Launched with one of Banana's own arguments (`--wellness`, `--week`, `--ui-audit`…) other
    /// than the one that asks for the restored state itself.
    static var isDirectedLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        return arguments.contains { $0.hasPrefix("--") } && !arguments.contains("--restore-state")
    }
    #endif

    /// Stamps and writes the current state. Called on every change and again on backgrounding,
    /// so `savedAt` is when the person left, not when they last tapped.
    func save(now: Date = Date()) {
        var stamped = state
        stamped.savedAt = now
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Text typed into a sheet and not yet saved, kept in memory so the background rebuild doesn't
/// throw it away. Not written to disk: a draft from yesterday isn't worth resurrecting.
@MainActor
enum Drafts {
    static var foodPhrase = ""
    /// The note composer's text, and which note it belongs to ("new" or a note id), so a draft
    /// only ever reopens in the composer it was typed into.
    static var note = ""
    static var noteFor = ""
}
