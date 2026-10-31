import XCTest
import GRDB

final class MailLabelCatalogTests: XCTestCase {
    private func stores() async throws -> MailStores {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mail-labels-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try await Task.detached { try MailStores.open(MailDirectories(root: root), migrations: MailSlices.migrations()) }.value
    }
    static var systemLabels: [GmailLabel] {
        ["INBOX", "SENT", "DRAFT", "TRASH", "SPAM", "UNREAD", "STARRED"].map { GmailLabel(id: $0, name: $0, type: "system") }
    }
    func testDirectoryRenamesAndAbsencePreserveAccountScopedIDs() async throws {
        let stores = try await stores()
        let writer = MailWriter(stores: stores, sink: nil)
        _ = try await writer.transact { db in
            var changes = try MailLabelCatalog.replace([
                GmailLabel(id: "Label_7", name: "Work/Calls", type: "user", color: GmailLabelColor(backgroundColor: "#123456")),
                GmailLabel(id: "Label_8", name: "Banana/Snoozed", type: "user")
            ] + Self.systemLabels, account: "a@example.com", in: db)
            changes.formUnion(try MailLabelCatalog.replace([GmailLabel(id: "Label_7", name: "Personal", type: "user")] + Self.systemLabels, account: "b@example.com", in: db))
            return changes
        }
        let before = try await stores.index.read { try MailLabelCatalog.read(in: $0) }
        XCTAssertEqual(before.places["a@example.com"]?.map(\.ref.name), ["Work/Calls"])
        XCTAssertEqual(before.places["a@example.com"]?.first?.ref.colorHex, "#123456")
        XCTAssertEqual(before.places["b@example.com"]?.map(\.ref.name), ["Personal"])
        XCTAssertNotEqual(before.places["a@example.com"]?.first?.id, before.places["b@example.com"]?.first?.id)
        _ = try await writer.transact { try MailLabelCatalog.replace([GmailLabel(id: "Label_7", name: "Renamed", type: "user")] + Self.systemLabels, account: "a@example.com", in: $0) }
        let renamed = try await stores.index.read { try MailLabelCatalog.read(in: $0) }
        XCTAssertEqual(renamed.places["a@example.com"]?.first?.ref.name, "Renamed")
        XCTAssertEqual(Set(renamed.refs.keys), Set(before.refs.keys))
        _ = try await writer.transact { try MailLabelCatalog.replace(Self.systemLabels, account: "a@example.com", in: $0) }
        let removed = try await stores.index.read { try MailLabelCatalog.read(in: $0) }
        XCTAssertEqual(removed.places["a@example.com"]?.first?.ref.name, "Renamed", "Listing absence cannot remove a cached label")
        XCTAssertEqual(removed.places["b@example.com"]?.first?.ref.name, "Personal")
        let retained = try await stores.index.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM label") }
        XCTAssertEqual(retained, 17, "Metadata refresh must not delete IDs referenced by cached messages or intent")
    }
    func testMalformedDirectoryDoesNotEraseLastGoodReading() async throws {
        let stores = try await stores()
        let writer = MailWriter(stores: stores, sink: nil)
        _ = try await writer.transact { try MailLabelCatalog.replace([GmailLabel(id: "Label_1", name: "Kept", type: "user")] + Self.systemLabels, account: "a@example.com", in: $0) }
        do {
            _ = try await writer.transact { try MailLabelCatalog.replace([
                GmailLabel(id: "Label_2", name: "New", type: "user"), GmailLabel(id: "broken", type: "user")
            ] + Self.systemLabels, account: "a@example.com", in: $0) }
            XCTFail("Incomplete directory accepted")
        } catch { XCTAssertTrue(error is MailLabelCatalog.Failure) }
        let reading = try await stores.index.read { try MailLabelCatalog.read(in: $0) }
        XCTAssertEqual(reading.places["a@example.com"]?.map(\.ref.name), ["Kept"])
    }
    func testIncompleteDirectoryPreservesPriorNames() async throws {
        let stores = try await stores()
        let writer = MailWriter(stores: stores, sink: nil)
        _ = try await writer.transact { try MailLabelCatalog.replace(Self.systemLabels + [GmailLabel(id: "Label_1", name: "Kept", type: "user")], account: "a@example.com", in: $0) }
        for labels in [[], [GmailLabel(id: "Label_1", name: "Partial rename", type: "user")]] {
            do {
                _ = try await writer.transact { try MailLabelCatalog.replace(labels, account: "a@example.com", in: $0) }
                XCTFail("Incomplete response accepted")
            } catch { XCTAssertTrue(error is MailLabelCatalog.Failure) }
        }
        let reading = try await stores.index.read { try MailLabelCatalog.read(in: $0) }
        XCTAssertEqual(reading.places["a@example.com"]?.first?.ref.name, "Kept")
    }
    func testWrongAccountResponseCannotReplaceDirectory() async throws {
        let stores = try await stores()
        let api = GmailIntentDeliveryTests.Provider()
        await api.configure(account: "b@example.com")
        do {
            try await MailLabelCatalog.fetch(account: "a@example.com", api: api, token: "fixture", writer: MailWriter(stores: stores, sink: nil))
            XCTFail("Wrong account response accepted")
        } catch { XCTAssertTrue(error is MailLabelCatalog.Failure) }
        let reading = try await stores.index.read { try MailLabelCatalog.read(in: $0) }
        XCTAssertTrue(reading.places.isEmpty)
    }
}
