#if !BANANA_PUBLIC
import Foundation

/// What every member of `MailSource` answers until a source builds it.
///
/// Mail is built a package at a time, and both the engine and the in-memory source have to
/// compile at every commit along the way. Without this file each of them would carry its own
/// stub for every member it has not reached — fifty-odd members, twice, in files later
/// packages then have to edit to take the stubs out again. With it, **a source builds a member
/// by declaring it, in a file of its own, and holds no stubs at all**: Swift picks the
/// source's declaration over the default here, and nothing already written is touched.
///
/// Every default is the quiet answer, the one a screen already has to draw: nothing listed,
/// nothing on this device, nothing sent. None of them pretends: a change answers with a
/// receipt that counts nothing, and no split is reported as saved.
///
/// And every default says it was reached (`MailNotYet`), because a quiet answer is also how a
/// forgotten member would look — and how a member looks whose source declared it with a
/// slightly different signature, which Swift accepts as an overload and never calls. Two
/// things turn that into a failure someone sees: the tests run one probe that calls every
/// member (`MailSourceProbe`, in the tests) against both sources and assert that none of
/// these was reached; and the app sets `onReach`, so a default reached on a device stops the
/// debugger or leaves a line in the journal instead of passing as an empty screen.
///
/// The values are the table "Until it is built" in MAIL-ENGINE 13.3.
@MainActor enum MailNotYet {

    /// The defaults that have been reached since the last `reset()`, by `#function` name —
    /// `"activate()"`, `"observeList(_:limit:_:)"`, `"accounts"`. The two `discard`s share a
    /// `#function`, so each adds what it discards: `"discard(_:) receipt"`,
    /// `"discard(_:) draft"`.
    private(set) static var reachedNames: Set<String> = []

    /// The one status object every default `status` returns. Shared, so that a screen holding
    /// it and a test reading it see one object; reset with everything else.
    static let status = MailStatus(emptyStatus)

    /// The one badge object every default `badges` returns.
    static let badges = MailBadges(emptyBadges)

    /// Called each time a default is reached, with its name. Nil here, because this folder may
    /// name nothing outside itself; the app sets it where it builds the engine — an
    /// `assertionFailure` in a debug build, one journal line in a release one. `reset()` leaves
    /// it alone: whoever set it clears it.
    static var onReach: ((String) -> Void)?

    static func reached(_ name: String) {
        reachedNames.insert(name)
        onReach?(name)
    }

    /// Forgets what was reached and puts the two shared objects back as they began. A test
    /// calls it first, so what an earlier test reached is not counted against it.
    static func reset() {
        reachedNames = []
        status.value = emptyStatus
        badges.value = emptyBadges
    }

    /// Online, with nothing opened and nothing to report: no store has been touched, which is
    /// exactly true of a source that has not built its status.
    static var emptyStatus: MailStatusValue {
        MailStatusValue(isOnline: true, lastChecked: nil, unreachableSince: nil, slowedSince: nil,
                        asked: nil, waitingChanges: 0, waitingSince: nil, waitingMessages: 0,
                        refused: [], downloads: [], store: .notOpened, questions: [])
    }

    static var emptyBadges: MailBadgeCounts {
        MailBadgeCounts(unreadInFirstSplit: 0, needsAnswer: 0)
    }

    /// What a change answers when nothing was changed: no sequence, nothing counted.
    static var emptyReceipt: MailReceipt {
        MailReceipt(sequence: 0, count: 0)
    }
}

extension MailSource {

    // MARK: - Life

    func activate() {
        MailNotYet.reached(#function)
    }

    func setVisible(_ visible: Bool) {
        MailNotYet.reached(#function)
    }

    // MARK: - Reads

    var accounts: [MailAccount] {
        MailNotYet.reached(#function)
        return []
    }

    var syncLimit: MailSyncLimit {
        MailNotYet.reached(#function)
        return .standard
    }

    func setSyncLimit(_ limit: MailSyncLimit) {
        MailNotYet.reached(#function)
    }

    func conversationsBeyond(_ limit: MailSyncLimit) async -> Int {
        MailNotYet.reached(#function)
        return 0
    }

    /// An observation that is never built delivers nothing, not even a first value: a screen
    /// waiting on it shows what it shows before the first reading, which is the honest state.
    func observeAccounts(_ onChange: @escaping @MainActor ([MailAccount]) -> Void) -> MailObservation {
        MailNotYet.reached(#function)
        return MailObservation {}
    }

    func observePlaces(_ onChange: @escaping @MainActor (MailPlaces) -> Void) -> MailObservation {
        MailNotYet.reached(#function)
        return MailObservation {}
    }

    func cachedFirstPage(_ scope: MailScope) -> MailListSnapshot? {
        MailNotYet.reached(#function)
        return nil
    }

    func observeList(_ scope: MailScope, limit: Int,
                     _ onChange: @escaping @MainActor (MailListSnapshot) -> Void) -> MailObservation {
        MailNotYet.reached(#function)
        return MailObservation {}
    }

    func observeConversation(
        _ id: MailConversationID,
        _ onChange: @escaping @MainActor (MailConversation?) -> Void
    ) -> MailObservation {
        MailNotYet.reached(#function)
        return MailObservation {}
    }

    func conversation(_ id: MailConversationID) async -> MailConversation? {
        MailNotYet.reached(#function)
        return nil
    }

    func body(_ id: MailMessageID) async -> MailBody {
        MailNotYet.reached(#function)
        return .notOnDevice
    }

    func resource(_ url: URL, for message: MailMessageID,
                  presentation: MailPresentation) async -> MailResource? {
        MailNotYet.reached(#function)
        return nil
    }

    func suggestions(for text: String) async -> [MailSuggestion] {
        MailNotYet.reached(#function)
        return []
    }

    func people(matching text: String, limit: Int) async -> [MailPerson] {
        MailNotYet.reached(#function)
        return []
    }

    func queryTokens(_ text: String) -> [MailQueryToken] {
        MailNotYet.reached(#function)
        return []
    }

    /// Refused, not opened: until the link rules exist nothing in mail may open a link, and a
    /// default that opened one would be the single unsafe answer in this file.
    func decideLink(_ url: URL, in message: MailMessageID) async -> MailLinkDecision {
        MailNotYet.reached(#function)
        return .refuse
    }

    func draft(_ id: MailDraftID) async -> MailDraft? {
        MailNotYet.reached(#function)
        return nil
    }

    var status: MailStatus {
        MailNotYet.reached(#function)
        return MailNotYet.status
    }

    var badges: MailBadges {
        MailNotYet.reached(#function)
        return MailNotYet.badges
    }

    func attachmentProgress(_ id: MailAttachmentID) -> MailProgress {
        MailNotYet.reached(#function)
        return MailProgress()
    }

    func storageUsed() async -> MailStorage {
        MailNotYet.reached(#function)
        return MailStorage(bodies: 0, attachments: 0, search: 0, index: 0)
    }

    // MARK: - Changes to conversations

    /// A receipt that counts nothing, which is what a screen is already told when there was
    /// nothing to change: it shows no toast and offers no undo.
    @discardableResult func apply(_ change: MailChange, to target: MailTarget) -> MailReceipt {
        MailNotYet.reached(#function)
        return MailNotYet.emptyReceipt
    }

    @discardableResult func undo(_ receipt: MailReceipt) -> MailReceipt {
        MailNotYet.reached(#function)
        return MailNotYet.emptyReceipt
    }

    func retry(_ receipt: MailReceipt) {
        MailNotYet.reached(#function)
    }

    func discard(_ receipt: MailReceipt) {
        MailNotYet.reached(#function + " receipt")
    }

    // MARK: - Drafts and sending

    /// A draft that exists only as this value: its id is new, and it is saved nowhere, so
    /// `draft(_:)` will not find it and `save` does nothing with it.
    func newDraft(_ kind: MailDraftKind) async -> MailDraft {
        MailNotYet.reached(#function)
        let account: String
        switch kind {
        case .new(let chosen):
            account = chosen ?? ""
        case .reply(let message), .replyAll(let message), .forward(let message):
            account = message.account
        case .toAddress:
            account = ""
        }
        let id = MailDraftID(raw: UUID().uuidString)
        return MailDraft(
            id: id,
            conversation: MailConversationID(account: account, thread: "local:" + id.raw),
            account: account,
            isReply: false,
            isForward: false,
            from: MailIdentity(account: account, address: account, name: nil,
                               isDefault: true, hasSignature: false),
            to: [], cc: [], bcc: [],
            subject: "",
            body: MailText(blocks: []),
            signature: nil,
            quote: nil,
            attachments: [],
            format: .banana,
            schedule: nil,
            remindIfNoReply: nil,
            delivery: nil,
            encodedBytes: 0,
            editedAt: Date())
    }

    func save(_ draft: MailDraft) {
        MailNotYet.reached(#function)
    }

    func addAttachment(_ file: URL, to draft: MailDraftID) async -> MailDraftAttachment? {
        MailNotYet.reached(#function)
        return nil
    }

    func removeAttachment(_ id: String, from draft: MailDraftID) {
        MailNotYet.reached(#function)
    }

    func rewriteAsText(_ draft: MailDraftID) async -> MailDraft? {
        MailNotYet.reached(#function)
        return nil
    }

    func quoteAsText(in draft: MailDraftID) async -> MailDraft? {
        MailNotYet.reached(#function)
        return nil
    }

    func changeIdentity(of draft: MailDraftID, to address: String) async -> MailDraft? {
        MailNotYet.reached(#function)
        return nil
    }

    func resource(_ url: URL, forDraft draft: MailDraftID,
                  presentation: MailPresentation) async -> MailResource? {
        MailNotYet.reached(#function)
        return nil
    }

    @discardableResult func discard(_ draft: MailDraftID) -> MailReceipt {
        MailNotYet.reached(#function + " draft")
        return MailNotYet.emptyReceipt
    }

    @discardableResult func send(_ draft: MailDraftID, _ options: MailSendOptions) -> MailReceipt {
        MailNotYet.reached(#function)
        return MailNotYet.emptyReceipt
    }

    /// False means "it has left", which is the answer that never lets a screen promise an
    /// undo this source cannot keep. It is said of a send that never happened, and that is
    /// safe only because the default `send` answers with a count of 0, for which a screen
    /// shows nothing and so offers nothing to cancel.
    func cancelSend(_ draft: MailDraftID) async -> Bool {
        MailNotYet.reached(#function)
        return false
    }

    func retrySend(_ draft: MailDraftID) {
        MailNotYet.reached(#function)
    }

    var hasUnfinishedSends: Bool {
        MailNotYet.reached(#function)
        return false
    }

    func finishSends(within limit: TimeInterval) async {
        MailNotYet.reached(#function)
    }

    // MARK: - Questions

    func answer(_ question: MailQuestion.ID, _ choice: MailChoice) {
        MailNotYet.reached(#function)
    }

    // MARK: - Fetching

    func checkNow() {
        MailNotYet.reached(#function)
    }

    func askGmail(_ scope: MailScope) {
        MailNotYet.reached(#function)
    }

    func wants(_ ids: [MailConversationID]) {
        MailNotYet.reached(#function)
    }

    func fetchBody(_ id: MailMessageID) {
        MailNotYet.reached(#function)
    }

    func fetchAttachment(_ id: MailAttachmentID) {
        MailNotYet.reached(#function)
    }

    func showPictures(in id: MailMessageID, always grant: MailPictureGrant?) {
        MailNotYet.reached(#function)
    }

    func pictureRules() async -> [MailPictureRule] {
        MailNotYet.reached(#function)
        return []
    }

    func removePictureRule(_ rule: MailPictureRule) {
        MailNotYet.reached(#function)
    }

    // MARK: - Accounts, splits, labels

    func setWantsMail(_ on: Bool, account: String) {
        MailNotYet.reached(#function)
    }

    func requestPermission(account: String) async -> MailPermissionResult {
        MailNotYet.reached(#function)
        return .failed
    }

    func forgetPermission(account: String) {
        MailNotYet.reached(#function)
    }

    /// Every split is reported as not saved, because none was. (An empty answer would mean
    /// "all saved", which is the one thing that is certainly false.)
    @discardableResult func saveSplits(_ splits: [MailSplit]) -> [String] {
        MailNotYet.reached(#function)
        return splits.map(\.id)
    }

    /// A label with a device-made id, which the contract says stays valid in every call for
    /// the life of the process — so a screen that makes a label and at once applies it has
    /// something to apply.
    func createLabel(named name: String, account: String) -> MailLabelRef {
        MailNotYet.reached(#function)
        return MailLabelRef(id: "local:" + name, name: name, colorHex: nil)
    }

    func unsubscribe(_ id: MailConversationID) async -> MailUnsubscribeResult {
        MailNotYet.reached(#function)
        return .unavailable
    }

    func removeDownloadedMail(account: String?) async {
        MailNotYet.reached(#function)
    }

    func reconsiderKeptMail(account: String) {
        MailNotYet.reached(#function)
    }

    // MARK: - What the engine has to say unasked

    func observeEvents(_ onEvent: @escaping @MainActor (MailEvent) -> Void) -> MailObservation {
        MailNotYet.reached(#function)
        return MailObservation {}
    }
}

#endif
