import XCTest
@testable import Payghaam

@MainActor
final class AnonymousTrackingTests: XCTestCase {

    func testAnonymousIdGeneratedAndPersisted() {
        let anonId1 = Payghaam.shared.getAnonymousId()
        XCTAssertFalse(anonId1.isEmpty, "Anonymous ID should not be empty")

        // Should return same anonymousId on subsequent calls
        let anonId2 = Payghaam.shared.getAnonymousId()
        XCTAssertEqual(anonId1, anonId2)
    }

    func testLogoutRotatesAnonymousId() {
        let anonIdBefore = Payghaam.shared.getAnonymousId()
        Payghaam.shared.logout()
        let anonIdAfter = Payghaam.shared.getAnonymousId()

        XCTAssertFalse(anonIdAfter.isEmpty)
        XCTAssertNotEqual(anonIdBefore, anonIdAfter, "Logout must rotate anonymousId")
    }

    func testPersistBridgeConfigSetsAnonymousAndLanguage() {
        Payghaam.shared.persistBridgeConfig(
            apiKey: "ek_client_bridge_test",
            baseUrl: "http://localhost:3000",
            externalId: "bridge_user_1",
            anonymousId: "custom_anon_id_123",
            language: "ar"
        )

        XCTAssertEqual(Payghaam.shared.getAnonymousId(), "custom_anon_id_123")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "payghaam_language"), "ar")
    }
}
