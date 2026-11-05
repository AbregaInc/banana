import XCTest

final class GoogleCredentialCutoverTests: XCTestCase {
    func testCutoverPreservesIdentityAndOtherAccountsWhileRemovingOnlyMigratedCredential() {
        let original = [GoogleAccountCredential(email: "noor@plan.example", refreshToken: "native-noor", grantedScopes: ["calendar"]),
                        GoogleAccountCredential(email: "other@plan.example", refreshToken: "native-other", grantedScopes: ["calendar"])]
        let retired = GoogleAccountStore.retiringDirectAccess(original, email: "Noor@plan.example")
        XCTAssertEqual(retired[0].id, original[0].id)
        XCTAssertEqual(retired[0].refreshToken, "")
        XCTAssertEqual(retired[0].cloudOnly, true)
        XCTAssertEqual(retired[1], original[1])
        XCTAssertEqual(GoogleAccountStore.retiringDirectAccess(retired, email: "noor@plan.example"), retired)
    }
    func testExistingCredentialDocumentsRemainReadableAndUnmigrated() throws {
        let data = Data(#"{"email":"noor@plan.example","refreshToken":"existing","grantedScopes":["calendar"]}"#.utf8)
        let credential = try JSONDecoder().decode(GoogleAccountCredential.self, from: data)
        XCTAssertNil(credential.cloudOnly)
        XCTAssertEqual(credential.refreshToken, "existing")
    }
    func testDeviceDeclaresProviderProtocolWithoutChangingLegacyRequestShape() throws {
        var device = BananaService.Device(id: "test-device", platform: "iphone", push: nil, pushEnv: "production", bundle: "app.example")
        let before = BananaService.request(.device(device), host: "service.example", session: "session")
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(before.httpBody)) as? [String: Any])
        XCTAssertNil(oldJSON["providerProtocol"])
        device.providerProtocol = 1
        let after = BananaService.request(.device(device), host: "service.example", session: "session")
        let newJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(after.httpBody)) as? [String: Any])
        XCTAssertEqual(newJSON["providerProtocol"] as? Int, 1)
    }
}
