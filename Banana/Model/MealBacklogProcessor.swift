import Combine
import CoreGraphics
import Foundation
#if os(iOS)
import UIKit
#endif

/// Estimates backlog meals that are ready (`MealInboxItem.State.ready`) and belong to this device
/// (`MealBacklogRouting`), two at a time, and hands each estimate to the store for review.
@MainActor
final class MealBacklogProcessor: ObservableObject {
    static let shared = MealBacklogProcessor()

    /// Meals being estimated on this device right now, for their rows' spinners.
    @Published private(set) var working: Set<UUID> = []

    /// At most this many photos go to the model per meal: enough to see a table, not so many the
    /// request runs out of room.
    static let maxPhotos = 4
    private static let concurrent = 2

    private let inbox: MealInboxStore
    private let photos: MealPhotoStore
    private weak var wellness: WellnessStore?
    private var photoWatch: AnyCancellable?
    private var recheck: Timer?

    init(inbox: MealInboxStore = .shared, photos: MealPhotoStore = .shared) {
        self.inbox = inbox
        self.photos = photos
    }

    /// The meals being estimated, noted on disk while the model works: if estimating one takes the
    /// app down, the next launch marks it failed instead of trying it again — and again, at every
    /// launch after. Cleared when iOS stops the app for its own reasons (`suspending`): a meal
    /// paused in the background didn't crash anything.
    private let inFlightURL = AppSupport.directory.appendingPathComponent("meal-estimate-in-flight")
    private var statusTimer: Timer?
    private var backgroundObserver: NSObjectProtocol?
    /// Meals this device has left to the Mac, so it says so once each.
    private var leftToMac: Set<UUID> = []

    func start(wellness: WellnessStore) {
        guard self.wellness == nil else { return kick() }
        self.wellness = wellness
        let raw = (try? String(contentsOf: inFlightURL, encoding: .utf8)) ?? ""
        for id in raw.split(whereSeparator: \.isNewline).compactMap({ UUID(uuidString: String($0)) }) {
            guard let item = inbox.item(id) else { continue }
            inbox.fail(id, "Estimating this one made Banana quit. Try again, or enter it by hand.", forNote: item.note)
            PlaybackDiagnostics.shared.log("🍽 estimate", "the last one took the app down; marked it failed")
        }
        try? FileManager.default.removeItem(at: inFlightURL)
        redoOutdatedEstimates()
        publishStatus()
        // Every device says what it can estimate at launch; it's the Mac's that matters — the
        // others leave meals to it while it's on and on power — so only the Mac keeps saying it.
        if MealBacklogRouting.repeatsStatus(on: DeviceRole.current) {
            statusTimer = Timer.scheduledTimer(withTimeInterval: MealEstimators.refresh, repeats: true) { _ in
                Task { @MainActor in MealBacklogProcessor.shared.publishStatus() }
            }
        }
        #if os(iOS)
        // Leaving with meals still waiting: estimate them on the next charge.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MealEstimateCatchUp.scheduleIfNeeded() }
        }
        #endif
        inbox.onChange = { [weak self] in self?.kick() }
        // A photo from another device may land after the meal that needs it.
        photoWatch = photos.$version.dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.kick() }
        kick()
    }

    /// Meals still waiting for review that an older estimator made are estimated again, once.
    /// Only on the iPhone: it's where an older build could otherwise pick them up again, and once
    /// it has this build every device does.
    private func redoOutdatedEstimates() {
        let key = "mealEstimates.redone.v\(GroundedFoodEstimate.version)"
        guard DeviceRole.current.isHub, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let outdated = MealBacklogRouting.outdatedProposals(inbox.items, version: GroundedFoodEstimate.version)
        for id in outdated { inbox.retry(id) }
        if !outdated.isEmpty {
            PlaybackDiagnostics.shared.log("🍽 estimate", "estimating \(outdated.count) waiting meals again with estimator \(GroundedFoodEstimate.version)")
        }
    }

    /// Starts once; after that just looks for work.
    func startIfNeeded(wellness: WellnessStore) {
        if self.wellness == nil { start(wellness: wellness) } else { kick() }
    }

    var here: MealBacklogRouting.Here {
        let availability = Intelligence.current
        var canReadPhotos = false
        if #available(iOS 27, macOS 27, visionOS 27, watchOS 27, *) {
            canReadPhotos = Intelligence.route(.vision, given: availability) != .none
        }
        return .init(installID: MealInboxStore.installID, isHub: DeviceRole.current.isHub,
                     canReadPhotos: canReadPhotos,
                     canReadText: Intelligence.route(.knowledge, given: availability) != .none,
                     isMac: DeviceRole.current == .mac, onPower: MealPhotoScanner.power == .mains)
    }

    /// What this device can estimate, for the others (`MealEstimators`).
    func publishStatus() {
        let here = here
        let device: String
        switch DeviceRole.current {
        case .phone: device = "iPhone"
        case .pad: device = "iPad"
        case .mac: device = "Mac"
        }
        MealEstimators.shared.publish(MealEstimatorStatus(device: device, canReadPhotos: here.canReadPhotos,
                                                          canReadText: here.canReadText, onPower: here.onPower,
                                                          at: Date()))
    }

    /// Meals this device is estimating or will now: for the progress the system shows.
    var pendingHere: Set<UUID> {
        let here = here
        let estimators = MealEstimators.shared.all
        let next = inbox.items.filter {
            MealBacklogRouting.shouldEstimate($0, here: here, macTakes: MealBacklogRouting.macTakes(
                $0, estimators: estimators, except: here.installID))
        }.map(\.id)
        return working.union(next)
    }

    /// Something this device can estimate is waiting, whoever's turn it is now.
    var hasWorkHere: Bool {
        let here = here
        return inbox.items.contains { $0.state == .ready && MealBacklogRouting.canEstimate($0, here: here) }
    }

    /// iOS is about to stop the app (its background time ran out): a meal cut off now didn't
    /// crash anything, so the next launch mustn't say it did. It's estimated again after.
    func suspending() {
        try? FileManager.default.removeItem(at: inFlightURL)
    }

    private func noteInFlight() {
        if working.isEmpty {
            try? FileManager.default.removeItem(at: inFlightURL)
        } else {
            try? HealthFileProtection.write(Data(working.map(\.uuidString).joined(separator: "\n").utf8), to: inFlightURL)
        }
    }

    /// Looks for meals to estimate. Cheap; call whenever anything changes.
    func kick() {
        guard wellness != nil else { return }
        let here = here
        let estimators = MealEstimators.shared.all
        var waiting = false
        var startedForSomeoneHere = false
        for item in inbox.items.sorted(by: { $0.createdAt < $1.createdAt }) where item.state == .ready {
            guard !working.contains(item.id) else { continue }
            let macTakes = MealBacklogRouting.macTakes(item, estimators: estimators, except: here.installID)
            guard MealBacklogRouting.shouldEstimate(item, here: here, macTakes: macTakes) else {
                if macTakes, !leftToMac.contains(item.id) {
                    leftToMac.insert(item.id)
                    PlaybackDiagnostics.shared.log("🍽 estimate", "left to the Mac (on power) for up to 2 min")
                }
                // Readied on another device: may become ours after the handoff.
                if MealBacklogRouting.canEstimate(item, here: here) { waiting = true }
                continue
            }
            guard working.count < Self.concurrent else { waiting = true; break }
            working.insert(item.id)
            if item.readiedBy == here.installID,
               let at = item.readiedAt, Date().timeIntervalSince(at) < Self.personRecently {
                startedForSomeoneHere = true
            }
            Task { await self.estimate(item) }
        }
        scheduleRecheck(waiting)
        #if os(iOS)
        // Someone here just asked for these (a note, Use photo only, Try again): keep going once
        // they leave the app, with the system's progress bar, instead of stopping after ~30 s.
        if startedForSomeoneHere, #available(iOS 26, *) {
            ContinuedMealEstimates.startIfNeeded(meals: pendingHere.count)
        }
        #endif
    }

    /// A meal readied on this device this recently was readied by the person using it.
    private static let personRecently: TimeInterval = 10 * 60

    private func scheduleRecheck(_ needed: Bool) {
        guard needed else {
            recheck?.invalidate()
            recheck = nil
            return
        }
        guard recheck == nil else { return }
        recheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.recheck = nil
                self?.kick()
            }
        }
    }

    /// The logged meal this meal's photos show again (`RepeatPhotoMeal`), proposed with its
    /// numbers; nil when none is close enough, or this device can't make prints of the photos.
    /// The prints are made off the main actor, once per photo (`MealPhotoPrints`).
    private func repeatFromPhotos(_ item: MealInboxItem, wellness: WellnessStore) async -> MealProposal? {
        guard let new = await prints(of: item) else { return nil }
        let candidates = await candidates(wellness)
        guard let found = RepeatPhotoMeal.match(new, candidates: candidates),
              RepeatPhotoMeal.wordsAgree(item.note, with: found.meal) else {
            if let near = RepeatPhotoMeal.nearest(new, among: candidates) {
                PlaybackDiagnostics.shared.log("🍽 estimate", "photo: nearest logged meal \(String(format: "%.3f", near.distance)) "
                                                + "(a match is under \(RepeatPhotoMeal.threshold)), estimating it")
            }
            return nil
        }
        PlaybackDiagnostics.shared.log("🍽 estimate", "photo looks like \"\(found.meal.name)\" of "
                                        + "\(found.meal.date.formatted(date: .abbreviated, time: .shortened)), distance "
                                        + "\(String(format: "%.3f", found.distance)): its numbers, no model")
        return RepeatPhotoMeal.proposal(copying: found.meal)
    }

    /// The words of the logged meal these photos look like (`RepeatPhotoMeal.suggestion`), to fill
    /// "What was this?" with — the same breakfast again is one tap on Add. Nil when none is close
    /// enough or the prints can't be made here.
    func suggestedWords(for item: MealInboxItem) async -> String? {
        guard let wellness, let new = await prints(of: item) else { return nil }
        return await suggestedWords(new, wellness: wellness)
    }

    /// The same, for photos not yet in the backlog (being added): made from their files' bytes.
    func suggestedWords(forPhotos jpegs: [Data]) async -> String? {
        guard let wellness, !jpegs.isEmpty else { return nil }
        let new = await Task.detached(priority: .userInitiated) {
            jpegs.compactMap { data in
                MealPhotoImage.downscaled(data, maxPixels: MealPhotoImage.keptPixels).flatMap(MealPhotoPrints.make)
            }
        }.value
        guard new.count == jpegs.count else { return nil }
        return await suggestedWords(new, wellness: wellness)
    }

    private func suggestedWords(_ new: [[Float]], wellness: WellnessStore) async -> String? {
        RepeatPhotoMeal.suggestion(new, candidates: await candidates(wellness))
    }

    /// A meal's photos as prints, all or none: when Vision gives nothing for one of them, nil.
    private func prints(of item: MealInboxItem) async -> [[Float]]? {
        let made = await MealPhotoPrints.shared.prints(files(item.photos.map(\.id)))
        let new = item.photos.compactMap { made[$0.id] }
        return !new.isEmpty && new.count == item.photos.count ? new : nil
    }

    /// The logged meals a photo can be matched with, with the prints of their photos.
    private func candidates(_ wellness: WellnessStore) async -> [(meal: MealEntry, prints: [[Float]])] {
        let meals = wellness.meals.filter { RepeatPhotoMeal.isCandidate($0, now: Date()) }
        guard !meals.isEmpty else { return [] }
        let prints = await MealPhotoPrints.shared.prints(files(meals.flatMap(\.photoIDs)))
        return meals.map { (meal: $0, prints: $0.photoIDs.compactMap { prints[$0] }) }
    }

    private func files(_ ids: [UUID]) -> [UUID: URL] {
        Dictionary(ids.map { ($0, photos.url($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// What the estimate is told besides the photos and words (docs/design/MEAL-LEARNING.md).
    private func context(for item: MealInboxItem, wellness: WellnessStore) -> GroundedFoodEstimate.Context {
        GroundedFoodEstimate.Context(
            usualNames: UsualFoods.names(at: item.eatenAt, meals: wellness.meals, myFoods: MyFoodsStore.shared.foods),
            measurements: MealPhotoDepth.lines(item.photos.compactMap(\.depth)),
            portionFactor: LearnedPortions.lookup(wellness.meals, category: { FoodDatabase.food(id: $0)?.category })
        )
    }

    private func estimate(_ item: MealInboxItem) async {
        #if os(iOS)
        // A reply from a notification wakes the app in the background: ask for the time to finish.
        // When it runs out iOS stops the app, and a task not ended by then gets it killed: end it,
        // and say the meal was paused, not a crash.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "meal estimate") { [weak self] in
            self?.suspending()
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            background = .invalid
        }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        #endif
        defer {
            working.remove(item.id)
            noteInFlight()
            kick()
        }
        guard let wellness else { return }
        let note = item.note

        // Said the same way as a meal already logged: the numbers already checked.
        if !item.trimmedNote.isEmpty, let past = RepeatMeal.match(note, in: wellness.meals) {
            let items = past.items.map { old -> MealItem in
                var copy = old
                copy.id = UUID()
                return copy
            }
            let name = past.name.isEmpty ? GroundedFoodEstimate.mealName("", items: items) : past.name
            let estimate = MealEstimate(estimator: GroundedFoodEstimate.version, from: .repeatedWords,
                                        foods: items.map { EstimatedFood($0, amount: .repeated) })
            inbox.propose(item.id, MealProposal(name: name, items: items, warnings: ["Same as your \(past.date.formatted(.dateTime.weekday(.wide).month().day())) meal"],
                                                estimator: GroundedFoodEstimate.version, estimate: estimate),
                          forNote: note)
            return
        }

        var images: [CGImage] = []
        for photo in item.photos.prefix(Self.maxPhotos) {
            // Not here yet (still syncing from the device that took it): try again when it lands.
            guard let image = photos.image(photo.id) else { return }
            images.append(image)
        }

        noteInFlight()
        // Looks like a meal already logged: its checked numbers, unless told it isn't that one.
        if item.hasPhotos, !item.notTheSame, let proposal = await repeatFromPhotos(item, wellness: wellness) {
            inbox.propose(item.id, proposal, forNote: note)
            return
        }
        let outcome = await GroundedFoodEstimate.meal(images: images, note: note, eatenAt: item.eatenAt,
                                                      learned: wellness.learnedLookup(), myFoods: MyFoodsStore.shared.foods,
                                                      context: context(for: item, wellness: wellness))
        switch outcome {
        case .proposal(let proposal):
            inbox.propose(item.id, proposal, forNote: note)
        case .failed(let reason, _), .unavailable(let reason):
            inbox.fail(item.id, reason, forNote: note)
            Telemetry.shared.record(.failure(.mealEstimate))
        }
        PlaybackDiagnostics.shared.log("🍽 estimate", "\(item.photos.count) photo(s), \(note.isEmpty ? "no words" : "with words") → \(String(describing: outcome).prefix(80))")
    }
}
