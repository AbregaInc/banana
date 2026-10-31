import Foundation
#if os(iOS)
import Combine
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// "What did you eat at 12:40?" — one notification per new meal, answered without opening the app:
/// type what it was, use the photo alone, or say it wasn't a meal. Only the iPhone asks, about
/// meals found anywhere: its own background pass (`MealPhotoScanner`) or the Mac's, arriving by a
/// push or a background fetch (`MealBacklogWake`). A meal is asked about once, and not at all if
/// it was already on screen in the app's backlog.
///
/// The notification's identifier is the backlog item's id, so answering the meal anywhere — in the
/// app, or on the Mac, arriving by sync — takes its notification away.
@MainActor
enum MealPhotoNotifications {
    nonisolated static let category = NotificationRoute.mealPhotoCategory

    enum Action {
        static let answer = "MEAL_PHOTO_ANSWER"
        static let photoOnly = "MEAL_PHOTO_PHOTO_ONLY"
        static let notAMeal = "MEAL_PHOTO_NOT_A_MEAL"
    }

    /// The backlog item a notification asks about, in its `userInfo`.
    nonisolated static let itemKey = "mealInboxItemID"

    /// Called after a notification leaves a meal ready to estimate (words, or "Use photo only"), so
    /// the estimating can start: wire `MealBacklogProcessor` here.
    static var onAnswered: (() -> Void)?

    private static var inboxWatch: AnyCancellable?
    private static var moduleWatch: AnyCancellable?
    private static var seenWatch: NSObjectProtocol?

    /// Call once from app launch, before launch finishes: the delegate has to be in place for a
    /// launch made to deliver an answer.
    ///
    /// This is the app's only notification delegate. It acts on `MEAL_PHOTO` answers, and shows
    /// Taken's reminders while the app is in front (`willPresent`); everything else arriving then
    /// stays unshown, as before there was a delegate.
    static func register() {
        UNUserNotificationCenter.current().delegate = MealPhotoNotificationDelegate.shared
        // Added to whatever categories exist rather than replacing them: setting categories
        // replaces the app's whole set.
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var categories = existing.filter { $0.identifier != category }
            categories.insert(makeCategory())
            UNUserNotificationCenter.current().setNotificationCategories(categories)
        }
        guard DeviceRole.current.isHub else { return }
        // A turn later: the backlog loads its file on first use, and launch has a frame to draw.
        Task { @MainActor in watchBacklog() }
        // What's on screen in the backlog has been seen: never asked about afterwards.
        seenWatch = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                markAsked(MealInboxStore.shared.items.filter { $0.state == .awaitingNote }.map(\.id))
            }
        }
    }

    private nonisolated static func makeCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: category,
            actions: [
                UNTextInputNotificationAction(
                    identifier: Action.answer, title: "What was it?", options: [],
                    textInputButtonTitle: "Add", textInputPlaceholder: "Chicken caesar and a beer"),
                UNNotificationAction(identifier: Action.photoOnly, title: "Use photo only", options: []),
                UNNotificationAction(identifier: Action.notAMeal, title: "Not a meal", options: [.destructive]),
            ],
            intentIdentifiers: [], options: [])
    }

    // MARK: - Asking

    private static let askedKey = "mealPhotos.asked"

    /// Meals already asked about, or already seen in the app — by id, with when.
    private static var asked: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: askedKey) as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: askedKey) }
    }

    private static func markAsked(_ ids: [UUID], now: Date = Date()) {
        guard !ids.isEmpty else { return }
        var record = asked.filter { now.timeIntervalSince($0.value) < MealPhotoNotificationPolicy.rememberAsked }
        for id in ids { record[id.uuidString] = now }
        asked = record
    }

    /// Asks about meals waiting for words that haven't been asked about — after a background pass
    /// here, or after a push or background fetch brought in meals the Mac found. With the app in
    /// front there's nothing to ask: the backlog on screen shows them, and they count as seen.
    static func askAboutNew(now: Date = Date()) async {
        guard DeviceRole.current.isHub else { return }
        let waiting = MealInboxStore.shared.items
        if UIApplication.shared.applicationState == .active {
            markAsked(waiting.filter { $0.state == .awaitingNote }.map(\.id), now: now)
            return
        }
        let already = Set(asked.keys.compactMap(UUID.init(uuidString:)))
        let asking = MealPhotoNotificationPolicy.toAsk(waiting, asked: already, now: now)
        guard !asking.isEmpty else { return }
        await post(asking, now: now)
        markAsked(asking.map(\.id), now: now)
    }

    /// One notification per new meal worth asking about (`MealPhotoNotificationPolicy`), when "Ask
    /// about new meal photos" is on and notifications are allowed. Never asks for permission: that
    /// belongs to a moment the person is looking.
    static func post(_ items: [MealInboxItem], now: Date = Date()) async {
        let asking = MealPhotoNotificationPolicy.worthAsking(items, now: now)
        guard !asking.isEmpty, MealPhotoScanPrefs.current.ask, ModuleStore.shared.includes(.food) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        for item in asking {
            let content = UNMutableNotificationContent()
            content.title = MealPhotoNotificationText.title(eatenAt: item.eatenAt, now: now)
            content.body = MealPhotoNotificationText.body(photoCount: item.photos.count)
            content.categoryIdentifier = category
            content.threadIdentifier = category
            content.userInfo = [itemKey: item.id.uuidString]
            // No sound: a question that can wait, not an alert.
            if let attachment = thumbnail(for: item) { content.attachments = [attachment] }
            do {
                try await center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
            } catch {
                Log.sync.error("meal photos: notification failed — \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The meal's first photo, small, in a file the system takes for the notification.
    private static func thumbnail(for item: MealInboxItem) -> UNNotificationAttachment? {
        guard let photo = item.photos.first, let data = MealPhotoStore.shared.data(photo.id),
              let image = MealPhotoImage.downscaled(data, maxPixels: 600),
              let jpeg = MealPhotoImage.jpeg(image) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meal-\(item.id.uuidString).jpg")
        do {
            try jpeg.write(to: url, options: .atomic)
            return try UNNotificationAttachment(
                identifier: "photo", url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: UTType.jpeg.identifier])
        } catch {
            return nil
        }
    }

    // MARK: - Answers

    /// A response to one of ours: into the backlog. False when it isn't ours.
    @discardableResult
    static func handle(_ response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        guard content.categoryIdentifier == category else { return false }
        guard let raw = content.userInfo[itemKey] as? String, let id = UUID(uuidString: raw) else { return true }
        let inbox = MealInboxStore.shared
        switch response.actionIdentifier {
        case Action.answer:
            let words = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            inbox.answer(id, note: words)
            onAnswered?()
        case Action.photoOnly:
            inbox.usePhotoOnly(id)
            onAnswered?()
        case Action.notAMeal:
            inbox.dismiss(id)
        default:
            // Tapped: the app opens, and the backlog shows the meal.
            break
        }
        return true
    }

    // MARK: - Tidying up

    /// Keeps the notification center to meals still waiting for words: one answered or dismissed —
    /// here or on another device — loses its notification.
    private static func watchBacklog() {
        inboxWatch = MealInboxStore.shared.$items
            .map { Set($0.filter { $0.state == .awaitingNote }.map(\.id)) }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { waiting in
                Task { await removeAnswered(keeping: waiting) }
            }
        // Food switched off: its questions leave the notification center too.
        moduleWatch = ModuleStore.shared.$choice
            .map { $0.includes(.food) }
            .removeDuplicates()
            .filter { !$0 }
            .sink { _ in Task { await removeAnswered(keeping: []) } }
    }

    private static func removeAnswered(keeping waiting: Set<UUID>) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let stale = delivered
            .filter { $0.request.content.categoryIdentifier == category }
            .map(\.request.identifier)
            .filter { UUID(uuidString: $0).map { !waiting.contains($0) } ?? true }
        guard !stale.isEmpty else { return }
        NotificationWrites.removeDelivered(stale)
    }

    /// Asks for notification permission when it's never been asked — for turning the scan on with
    /// the phone in hand, where the question makes sense.
    static func requestPermissionIfUndecided() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = await NotificationService.requestAuthorization()
    }
}

/// The app's `UNUserNotificationCenterDelegate`. Hands meal-photo answers to the backlog and
/// otherwise does what iOS does with no delegate.
final class MealPhotoNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MealPhotoNotificationDelegate()

    /// Shown while Banana is in front, and what an answer does: `NotificationRoute`, the rule the
    /// Mac's delegate follows too.
    private static func route(_ notification: UNNotification) -> NotificationRoute {
        let request = notification.request
        return NotificationRoute.of(identifier: request.identifier, category: request.content.categoryIdentifier,
                                    userInfo: request.content.userInfo)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.route(notification).showsInFront ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        switch Self.route(response.notification).action(response.actionIdentifier) {
        case .eventAlert:
            // Dismissed, opened, accepted or declined here clears it everywhere.
            Task { @MainActor in
                await EventAlerts.handle(response)
                completionHandler()
            }
            return
        case .openBooking:
            Task { @MainActor in
                BookingPushes.opened(response.notification)
                completionHandler()
            }
            return
        case .markDoseTaken, .openTakenList:
            // "Taken" marks the dose, a tap opens the Taken list.
            Task { @MainActor in
                await DoseReminders.handle(response)
                completionHandler()
            }
            return
        case .mealPhoto, .nothing:
            break
        }
        guard response.notification.request.content.categoryIdentifier == MealPhotoNotifications.category else {
            completionHandler()
            return
        }
        Task { @MainActor in
            MealPhotoNotifications.handle(response)
            // After the answer is saved: iOS may suspend the app as soon as this is called.
            completionHandler()
        }
    }
}
#else
/// Only the iPhone asks about meal photos.
@MainActor
enum MealPhotoNotifications {
    static var onAnswered: (() -> Void)?
    static func register() {}
}
#endif
