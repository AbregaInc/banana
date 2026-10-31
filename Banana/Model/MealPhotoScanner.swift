#if os(iOS) || os(macOS)
#if os(iOS)
import BackgroundTasks
import UIKit
#else
import AppKit
import IOKit.ps
#endif
import Combine
import Foundation
import Photos
import Vision

/// "Find meal photos automatically": each device with full Photos access looks through new photos
/// for food and drinks and turns each meal it finds into a backlog item that asks what it was
/// (docs/design/MEAL-BACKLOG.md, "Scanner").
///
/// The Mac does most of it: it's on power, so it looks every 15 minutes while it runs and whenever
/// the library changes (20 s after the last change, since iCloud delivers photos in bursts). The
/// iPhone and iPad look when the app comes to the front (at most every 10 minutes), when the
/// library changes while it's in front, and in a `BGAppRefreshTask` about hourly — and while a Mac
/// keeps up, only at the last day and a half (`MealPhotoScanShare`). Nothing else on iOS: this app
/// plays podcasts in the background, and background CPU is what iOS has killed it for before.
///
/// Two devices finding the same photo make the same meal (`MealPhotoIdentity`), and a photo any
/// device already made into a meal is skipped everywhere (`MealPhotoLedger`). Only the iPhone asks
/// about new meals with a notification.
@MainActor
final class MealPhotoScanner: NSObject, ObservableObject {
    static let shared = MealPhotoScanner()
    static let taskID = "com.boris.banana.meals.scan"

    /// Coming to the front starts a pass at most this often.
    static let activeThrottle: TimeInterval = 10 * 60
    /// Library changes arrive in bursts — iCloud catching up, a burst shot — so a pass waits this
    /// long after the last one.
    static let changeDebounce: Duration = .seconds(20)
    /// The earliest iOS may run the next background pass. A floor, not a promise. Hourly while the
    /// iPhone has to look for itself; a rare safety net while a Mac keeps up and pushes bring its
    /// finds (`MealBacklogWake`).
    static let backgroundInterval: TimeInterval = 3_600
    static let backgroundIntervalWithMac: TimeInterval = 4 * 3_600
    /// The most photos one pass classifies; the rest wait for the next. The first pass goes back two
    /// weeks, which can be a thousand photos — far more than a background window allows.
    static let foregroundCap = 300
    static let backgroundCap = 120
    /// A background pass starts no new photo after this long: iOS gives an app refresh about 30 s,
    /// and what was found still has to be saved and asked about.
    static let backgroundBudget: TimeInterval = 20
    /// How often the Mac looks, besides library changes.
    static let macInterval: TimeInterval = 15 * 60

    static var isMac: Bool { DeviceRole.current == .mac }
    static var deviceName: String {
        switch DeviceRole.current {
        case .phone: "iPhone"
        case .pad: "iPad"
        case .mac: "Mac"
        }
    }

    @Published private(set) var isChecking = false
    @Published private(set) var state = MealPhotoScanState()
    @Published private(set) var access: MealPhotoAccess = .notAsked

    private var inForeground = false
    /// The setting as last acted on, so a change to "Ask" alone doesn't start a pass.
    private var lastPrefs: MealPhotoScanPrefs?
    private var observingLibrary = false
    private var asking = false
    /// A library change asked for a pass while one was running.
    private var passAgain = false
    private var pendingPass: Task<Void, Never>?
    private var foregroundPass: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var moduleWatch: AnyCancellable?

    /// The setting as the scanner obeys it: off while Food is switched off (Settings › Modules),
    /// whatever the switch says, so no photo is looked at for a module the person hid. The
    /// setting itself is kept, and turning Food back on picks up where it was.
    private static var prefs: MealPhotoScanPrefs {
        var prefs = MealPhotoScanPrefs.current
        if !ModuleStore.shared.includes(.food) { prefs.enabled = false }
        return prefs
    }
    private var macTimer: Timer?
    private let stateURL = AppSupport.directory.appendingPathComponent("meal-photo-scan.json")

    /// Made at launch on every device, so nothing here asks Photos anything: `access` is read when
    /// the scanner acts, and when the setting is on screen.
    private override init() {
        super.init()
        if let data = try? Data(contentsOf: stateURL),
           let stored = try? JSONDecoder().decode(MealPhotoScanState.self, from: data) {
            state = stored
        }
    }

    // MARK: - Launch

    /// Call once from app launch, before launch finishes: registers the background task (every
    /// device, so a launch for it never finds no handler; the work checks it's the phone) and
    /// starts following the app to the front and back.
    static func register() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in await shared.run(task) }
        }
        #endif
        shared.start()
    }

    private func start() {
        #if DEBUG && os(iOS)
        // Screenshot routes render the real screen without starting production services.
        guard !VisualAuditRoute.matches() else { return }
        #endif
        let center = NotificationCenter.default
        // Turned on or off here or on another device. A turn later, so a change adopted from
        // iCloud has landed in full (the start date is assigned before the switch).
        // Food switched on or off is the scan turned on or off.
        moduleWatch = ModuleStore.shared.$choice.dropFirst().removeDuplicates().sink { _ in
            Task { @MainActor in MealPhotoScanner.shared.settingsChanged() }
        }
        observers = [
            center.addObserver(forName: AppSettings.mealPhotoScanDidChange, object: nil, queue: .main) { _ in
                Task { @MainActor in MealPhotoScanner.shared.settingsChanged() }
            },
        ]
        #if os(iOS)
        observers += [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MealPhotoScanner.shared.appBecameActive() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MealPhotoScanner.shared.appEnteredBackground() }
            },
        ]
        #else
        // The Mac looks whether or not Banana is the app in front: it's on power, and a Mac app
        // keeps running. Coming to the front only asks for Photos access if it's never been asked.
        inForeground = true
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MealPhotoScanner.shared.appBecameActive() }
        })
        macTimer = Timer.scheduledTimer(withTimeInterval: Self.macInterval, repeats: true) { _ in
            Task { @MainActor in
                // On battery, in Low Power Mode or hot, only new photos start a look.
                guard MealPhotoScanPace.timerLooks(Self.power) else { return }
                await MealPhotoScanner.shared.activate(reason: "timer", force: false)
            }
        }
        appBecameActive()
        #endif
    }

    /// Whether looking may happen right now: on iOS only with the app in front (outside a
    /// background task), on the Mac always.
    private var mayLook: Bool {
        #if os(iOS)
        inForeground && UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    /// What the device is running on, for how eagerly to look (`MealPhotoScanPace`).
    static var power: MealPhotoScanPace.Power {
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical { return .hot }
        if info.isLowPowerModeEnabled { return .lowPower }
        #if os(macOS)
        let sources = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        if let type = IOPSGetProvidingPowerSourceType(sources)?.takeUnretainedValue() as String?,
           type != kIOPMACPowerKey {
            return .battery
        }
        return .mains
        #else
        return .battery
        #endif
    }

    /// Whether a permission prompt can be shown now: someone is looking at Banana.
    private var canAsk: Bool {
        #if os(iOS)
        inForeground
        #else
        NSApp.isActive
        #endif
    }

    // MARK: - Front and back

    private func appBecameActive() {
        inForeground = true
        pendingPass?.cancel()
        // A moment after coming to the front, not on it: a cold launch has its first frame to draw.
        pendingPass = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.activate(reason: "active", force: false)
        }
    }

    #if os(iOS)
    private func appEnteredBackground() {
        inForeground = false
        pendingPass?.cancel()
        pendingPass = nil
        foregroundPass?.cancel()   // saves what it found so far, then stops
        passAgain = false
        stopObservingLibrary()
        schedule()
    }
    #endif

    private func settingsChanged() {
        let prefs = Self.prefs
        let before = lastPrefs
        lastPrefs = prefs
        guard prefs.enabled != before?.enabled || prefs.since != before?.since else { return }
        guard prefs.enabled else {
            pendingPass?.cancel()
            foregroundPass?.cancel()
            stopObservingLibrary()
            #if os(iOS)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
            #endif
            publishStatus(prefs)
            return
        }
        guard inForeground else {
            // Turned on from another device while the phone is in a pocket: the background task
            // looks when iOS allows; access is asked for the next time the app is open.
            refreshAccess()
            publishStatus(prefs)
            #if os(iOS)
            schedule()
            #endif
            return
        }
        // Turned on (or its start moved) with the phone in hand: ask for access, look now.
        Task { await activate(reason: "setting changed", force: true) }
    }

    /// In front: ask for Photos access if it's never been asked, follow library changes, and run a
    /// pass unless one ran in the last 10 minutes (`force` skips that).
    private func activate(reason: String, force: Bool) async {
        let prefs = Self.prefs
        lastPrefs = prefs
        guard prefs.enabled, inForeground else {
            if !prefs.enabled { stopObservingLibrary() }
            publishStatus(prefs)
            return
        }
        if !asking, canAsk {
            asking = true
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            // Just turned on with the phone in hand: the questions need notifications — asked
            // after Photos, not on top of it. Only the iPhone asks about meals.
            #if os(iOS)
            if force, prefs.ask, DeviceRole.current.isHub { await MealPhotoNotifications.requestPermissionIfUndecided() }
            #endif
            asking = false
        }
        refreshAccess()
        publishStatus(prefs)
        guard access == .full, inForeground else {
            stopObservingLibrary()
            return
        }
        startObservingLibrary()
        // A backfill that stopped part way (the app went to the back), or a start date nothing has
        // looked from yet, goes straight away.
        let due = force || state.remaining > 0 || state.countingFrom != prefs.effectiveSince()
            || state.lastCheck.map { Date().timeIntervalSince($0) >= Self.activeThrottle } ?? true
        if due { startForegroundPass(reason: reason) }
    }

    private func startForegroundPass(reason: String) {
        guard inForeground else { return }
        guard foregroundPass == nil, !isChecking else {
            passAgain = true
            return
        }
        foregroundPass = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.passAgain = false
                let outcome = await self.pass(background: false, reason: reason)
                // In front, a backfill goes on in batches of `foregroundCap`, each saved as it ends —
                // as long as each batch gets somewhere (offline, every photo can fail to load).
                if !outcome.stopped, outcome.classified > 0, self.state.remaining > 0 { self.passAgain = true }
            } while self.passAgain && self.inForeground && !Task.isCancelled
            self.foregroundPass = nil
        }
    }

    // MARK: - Library changes

    private func startObservingLibrary() {
        guard !observingLibrary else { return }
        observingLibrary = true
        PHPhotoLibrary.shared().register(self)
    }

    private func stopObservingLibrary() {
        guard observingLibrary else { return }
        observingLibrary = false
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    private func libraryChanged() {
        // Also checked at the time: a change can be delivered after the app has left the front,
        // and nothing may scan in background audio time.
        guard mayLook else { return }
        #if os(macOS)
        guard let wait = MealPhotoScanPace.afterChange(Self.power) else { return }
        let debounce: Duration = .seconds(wait)
        #else
        let debounce = Self.changeDebounce
        #endif
        pendingPass?.cancel()
        pendingPass = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self, self.mayLook else { return }
            self.startForegroundPass(reason: "library changed")
        }
    }

    // MARK: - Background

    #if os(iOS)
    /// Ask iOS for the next background window: on leaving the front and after every background
    /// run, while the setting is on and there's a library to look through.
    func schedule() {
        guard Self.prefs.enabled, Self.currentAccess() == .full else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        let macCovers = MealBacklogWake.pushReady && MealPhotoScanShare.macKeepingUp(
            MealPhotoScanReports.shared.all, except: MealInboxStore.installID)
        request.earliestBeginDate = Date().addingTimeInterval(macCovers ? Self.backgroundIntervalWithMac : Self.backgroundInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.sync.notice("meal photos: background scan scheduled")
        } catch {
            // Swallowing this is how a background task silently never runs.
            Log.sync.error("meal photos: submit FAILED — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func run(_ task: BGAppRefreshTask) async {
        // Chain the next window first, so a run cut short still leaves one on the books.
        schedule()
        let work = Task { @MainActor () -> Outcome in
            // First what other devices found — cheap, and it may be all there is to do.
            await MealBacklogWake.catchUp(reason: "background task")
            // A Mac keeping up has looked already (its finds just arrived); in Low Power Mode or
            // hot, looking waits for the app to be open.
            let macCovers = MealPhotoScanShare.macKeepingUp(MealPhotoScanReports.shared.all,
                                                            except: MealInboxStore.installID)
            guard !macCovers, Self.power == .battery else { return Outcome() }
            return await self.pass(background: true, reason: "background")
        }
        task.expirationHandler = { work.cancel() }
        let outcome = await work.value
        // Meals found while the app is in front are in the backlog on screen; asking is for now,
        // and only on the iPhone.
        if !inForeground, UIApplication.shared.applicationState != .active {
            await MealPhotoNotifications.askAboutNew()
        }
        task.setTaskCompleted(success: !outcome.stopped)
    }
    #endif

    // MARK: - A pass

    struct Outcome {
        var newItems: [MealInboxItem] = []
        /// Photos classified: 0 when the pass didn't run, or got nowhere.
        var classified = 0
        /// Cancelled or out of time before it got through everything.
        var stopped = false
    }

    private func pass(background: Bool, reason: String) async -> Outcome {
        let prefs = Self.prefs
        guard prefs.enabled, !isChecking else { return Outcome() }
        refreshAccess()
        guard access == .full else {
            publishStatus(prefs)
            return Outcome()
        }
        isChecking = true
        defer { isChecking = false }

        let startedAt = Date()
        let since = prefs.effectiveSince(now: startedAt)
        // On battery while a Mac keeps up, only recent photos; the Mac does the rest.
        let recentOnly = !Self.isMac && MealPhotoScanShare.macKeepingUp(
            MealPhotoScanReports.shared.all, except: MealInboxStore.installID, now: startedAt)
        let from = MealPhotoScanShare.windowStart(own: state.windowStart(since: since), onBattery: !Self.isMac,
                                                  macKeepingUp: recentOnly, now: startedAt)
        self.recentOnly = recentOnly
        let skipping = state.skipping.union(MealInboxStore.shared.knownAssetIDs)
        let cap = background ? Self.backgroundCap : Self.foregroundCap
        let deadline = background ? startedAt.addingTimeInterval(Self.backgroundBudget) : nil

        // The library read, the classifying and the image work, off the main actor and at utility
        // priority. Detached, so it doesn't inherit the main actor; cancelling this pass cancels it.
        let worker = Task.detached(priority: .utility) {
            await MealPhotoLibraryReader.read(from: from, skipping: skipping, cap: cap, deadline: deadline,
                                              background: background)
        }
        let read = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }

        // Another device may have found some of these already (the same iCloud Photos library):
        // those are its meals, skipped here. The rest are named by their cloud key, so a device
        // finding them at the same moment makes the same meal, not a second one.
        let inbox = MealInboxStore.shared
        let known = inbox.knownCloudKeys
        let fresh = read.food.filter { photo in
            guard let key = photo.ref.cloudKey else { return true }
            return !known.contains(key) && !MealPhotoLedger.shared.contains(key)
        }
        // Whatever was found is kept, even from a pass cut short — offered, not edited: another
        // device may have made the same meal, and anything done to it there wins.
        for photo in fresh { MealPhotoStore.shared.save(photo.jpeg, id: photo.ref.id, offer: photo.ref.cloudKey != nil) }
        let refs = fresh.map(\.ref)
        let groups = MealPhotoGrouping.group(refs, takenAt: { $0.takenAt })
        var newItems: [MealInboxItem] = []
        for decision in MealPhotoScanMerge.plan(groups: groups, existing: inbox.items) {
            switch decision {
            case .join(let id, let photos):
                inbox.addPhotos(photos, to: id)
            case .new(let photos):
                let eatenAt = photos.compactMap(\.takenAt).min() ?? startedAt
                newItems.append(MealInboxItem(id: MealPhotoIdentity.mealID(photos: photos) ?? UUID(), eatenAt: eatenAt,
                                              photos: photos, state: .awaitingNote, origin: .scanned))
            }
        }
        inbox.add(newItems, offer: true)
        MealPhotoLedger.shared.record(refs)
        MealPhotoLedger.shared.prune(before: since)

        var foodTaken: [String: Date] = [:]
        for photo in read.food {
            if let asset = photo.ref.assetID, let taken = photo.ref.takenAt { foodTaken[asset] = taken }
        }
        let stopped = read.stopped || Task.isCancelled
        state.record(MealPhotoScanState.Pass(
            startedAt: startedAt, classified: read.classified, food: foodTaken, newMeals: newItems.count,
            remaining: read.remaining, complete: !stopped && read.remaining == 0), since: since)
        saveState()
        publishStatus(prefs)
        PlaybackDiagnostics.shared.log(
            "meal photos: \(background ? "background" : "foreground") pass",
            "\(reason); classified \(read.classified.count), food \(read.food.count) (\(read.food.count - fresh.count) already found elsewhere), "
                + "new meals \(newItems.count), \(read.remaining) left\(stopped ? ", stopped early" : "")\(recentOnly ? ", recent only" : "")")
        return Outcome(newItems: newItems, classified: read.classified.count, stopped: stopped)
    }

    // MARK: - State and status

    private func saveState() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? HealthFileProtection.write(data, to: stateURL)
    }

    /// Whether the last pass looked at recent photos only (a Mac keeping up).
    private var recentOnly = false

    /// This device's status for the setting on every device; none while it's off, so turning it
    /// back on doesn't show how it went last time.
    private func publishStatus(_ prefs: MealPhotoScanPrefs) {
        MealPhotoScanReports.shared.publish(prefs.enabled ? report(for: prefs) : nil)
    }

    /// The report for this device's own settings row (the same one other devices read).
    var report: MealPhotoScanReport { report(for: MealPhotoScanPrefs.current) }

    /// How it's going under the current start date: a pass under another one (before the setting
    /// was last turned on, or the date moved) says nothing about this one.
    private func report(for prefs: MealPhotoScanPrefs) -> MealPhotoScanReport {
        let since = prefs.effectiveSince()
        let current = state.countingFrom == since
        return MealPhotoScanReport(access: access, checkedAt: current ? state.lastCheck : nil,
                                   found: state.meals(countingFrom: since), remaining: current ? state.remaining : 0,
                                   device: Self.deviceName,
                                   completedAt: current && state.coveredFrom == since ? state.lastPass : nil,
                                   recentOnly: recentOnly,
                                   onPower: Self.isMac ? Self.power == .mains : nil)
    }

    /// Re-reads Photos access: it changes in Settings, outside the app.
    func refreshAccess() {
        let now = Self.currentAccess()
        if now != access { access = now }
    }

    static func currentAccess() -> MealPhotoAccess {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #if os(iOS)
        if status == .limited { return .limited }
        #endif
        switch status {
        case .authorized: return .full
        case .denied, .restricted: return .denied
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }
}

extension MealPhotoScanner: PHPhotoLibraryChangeObserver {
    /// Delivered on a Photos queue.
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in MealPhotoScanner.shared.libraryChanged() }
    }
}

// MARK: - Reading the library

/// The part of a pass that touches Photos and Vision. Runs off the main actor, one photo at a
/// time, checking between photos whether it should stop.
enum MealPhotoLibraryReader {
    struct Found {
        var ref: MealPhotoRef
        var jpeg: Data
    }

    struct Read {
        /// Classified, food or not: library id → taken.
        var classified: [String: Date] = [:]
        var food: [Found] = []
        var remaining = 0
        var stopped = false
    }

    /// The small copy Vision classifies.
    static let classifySize = CGSize(width: 512, height: 512)

    /// `deadline`: start no photo after it. `background`: a background task's pass, which asks
    /// Vision to go easy.
    static func read(from start: Date, skipping: Set<String>, cap: Int, deadline: Date?,
                     background: Bool) async -> Read {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        #if os(iOS)
        // This library's photos, not the albums people share with you (the Mac's default).
        options.includeAssetSourceTypes = [.typeUserLibrary]
        #endif
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var byID: [String: PHAsset] = [:]
        var assets: [MealPhotoAsset] = []
        fetched.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
            assets.append(MealPhotoAsset(id: asset.localIdentifier, createdAt: asset.creationDate,
                                         isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
        }
        let plan = MealPhotoScanSelection.select(assets, skipping: skipping, from: start, cap: cap)
        var read = Read(remaining: plan.remaining)
        for (index, id) in plan.ids.enumerated() {
            if Task.isCancelled || deadline.map({ Date() >= $0 }) == true {
                read.remaining += plan.ids.count - index
                read.stopped = true
                break
            }
            guard let asset = byID[id], let taken = asset.creationDate else { continue }
            // Not readable right now (offline, iCloud slow): left unseen, so a later pass tries again.
            guard let labels = await labels(for: asset, background: background) else { continue }
            guard MealPhotoClassifier.isMeal(labels: labels) else {
                read.classified[id] = taken
                continue
            }
            guard let data = await imageData(for: asset),
                  let prepared = MealPhotoImage.prepare(data) else { continue }
            read.classified[id] = taken
            let depth = await depth(of: prepared, asset: asset)
            read.food.append(Found(ref: MealPhotoRef(takenAt: taken, assetID: id, depth: depth), jpeg: prepared.jpeg))
        }
        // The same photo on every device: its cloud key, and ids made from it.
        let keys = cloudKeys(for: read.food.compactMap(\.ref.assetID))
        for index in read.food.indices {
            guard let asset = read.food[index].ref.assetID, let key = keys[asset] else { continue }
            read.food[index].ref.cloudKey = key
            read.food[index].ref.id = MealPhotoIdentity.photoID(key: key)
        }
        return read
    }

    /// Library ids → cloud keys (`MealPhotoIdentity.key`), for those Photos can name across devices.
    static func cloudKeys(for localIDs: [String]) -> [String: String] {
        guard !localIDs.isEmpty else { return [:] }
        var keys: [String: String] = [:]
        for (local, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIDs) {
            guard case .success(let cloud) = result else { continue }
            let text: String
            if #available(iOS 27, macOS 27, *) { text = cloud.archivalStringValue } else { text = cloud.stringValue }
            keys[local] = MealPhotoIdentity.key(cloudIdentifier: text)
        }
        return keys
    }

    /// Vision's labels for a small copy of the photo, or nil when it can't be had.
    static func labels(for asset: PHAsset, background: Bool) async -> [(String, Float)]? {
        guard let (image, orientation) = await smallImage(for: asset) else { return nil }
        let request = VNClassifyImageRequest()
        // The labels and thresholds in `MealPhotoClassifier` were measured against revision 2.
        if VNClassifyImageRequest.supportedRevisions.contains(VNClassifyImageRequestRevision2) {
            request.revision = VNClassifyImageRequestRevision2
        }
        request.preferBackgroundProcessing = background
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        } catch {
            return nil
        }
        // A classifier that ran gives a confidence for every label it knows. None at all means it
        // didn't run (the Simulator, for one, answers with nothing) — not that nothing is there.
        guard let results = request.results, !results.isEmpty else { return nil }
        return results.map { ($0.identifier, $0.confidence) }
    }

    private static func smallImage(for asset: PHAsset) async -> (CGImage, CGImagePropertyOrientation)? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.version = .current
        let manager = PHImageManager.default()
        let request = PhotoRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(CGImage, CGImagePropertyOrientation)?, Never>) in
                let id = manager.requestImage(for: asset, targetSize: classifySize, contentMode: .aspectFit,
                                              options: options) { image, info in
                    // High-quality delivery calls once, but a degraded frame is never what we want.
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    guard request.finish() else { return }
                    #if os(iOS)
                    guard let image, let cgImage = image.cgImage else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (cgImage, CGImagePropertyOrientation(image.imageOrientation)))
                    #else
                    // The Mac's Photos hands the image upright.
                    guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (cgImage, .up))
                    #endif
                }
                request.started(id)
            }
        } onCancel: {
            request.cancel(with: manager)
        }
    }

    /// What a photo's depth measured. A Portrait photo's edited version may have left its depth
    /// map behind; then the original, which has it.
    static func depth(of prepared: MealPhotoImage.Prepared, asset: PHAsset) async -> PhotoDepth? {
        guard !prepared.carriesDepth, asset.mediaSubtypes.contains(.photoDepthEffect),
              let original = await imageData(for: asset, version: .original) else { return prepared.depth }
        return MealPhotoDepth.measure(photo: original)
    }

    /// A picked Portrait photo's depth from its original in the library, when the picker handed
    /// over a version without it and Banana may read the library. Nil otherwise.
    static func originalDepth(localIdentifier: String) async -> PhotoDepth? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        #if os(iOS)
        guard status == .authorized || status == .limited else { return nil }
        #else
        guard status == .authorized else { return nil }
        #endif
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject,
              asset.mediaSubtypes.contains(.photoDepthEffect),
              let original = await imageData(for: asset, version: .original) else { return nil }
        return MealPhotoDepth.measure(photo: original)
    }

    /// The photo itself — as edited unless asked for the original — for the copy Banana keeps.
    /// `network`: fetch it from iCloud when it isn't on this device.
    static func imageData(for asset: PHAsset, version: PHImageRequestOptionsVersion = .current,
                          network: Bool = true) async -> Data? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = network
        options.version = version
        let manager = PHImageManager.default()
        let request = PhotoRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                let id = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                    guard request.finish() else { return }
                    continuation.resume(returning: data)
                }
                request.started(id)
            }
        } onCancel: {
            request.cancel(with: manager)
        }
    }
}

/// One Photos request: resumes its continuation once, and can be cancelled from another thread.
private final class PhotoRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID?
    private var cancelled = false
    private var finished = false

    func started(_ id: PHImageRequestID) {
        lock.lock()
        self.id = id
        let cancelNow = cancelled && !finished
        lock.unlock()
        if cancelNow { PHImageManager.default().cancelImageRequest(id) }
    }

    /// True the first time only.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }

    func cancel(with manager: PHImageManager) {
        lock.lock()
        cancelled = true
        let id = finished ? nil : self.id
        lock.unlock()
        // A cancelled request calls its handler (nil, PHImageCancelledKey), which resumes.
        if let id { manager.cancelImageRequest(id) }
    }
}

#if os(iOS)
private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
#endif
