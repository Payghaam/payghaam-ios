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

    func testRemoveEmailAndSms() async throws {
        // Method availability check
        try await Payghaam.shared.removeEmail("user@example.com")
        try await Payghaam.shared.removeSms("+97412345678")
        try await Payghaam.shared.bridgeRemoveSubscription(type: .sms, token: "+97412345678")
    }

    func testRemoveAliasAndTagsAndOptInOut() async throws {
        XCTAssertEqual(Payghaam.shared.getExternalId(), "bridge_user_1")
        try await Payghaam.shared.removeAlias("crm_id")
        try await Payghaam.shared.removeAliases(["crm_id", "loyalty_id"])
        try await Payghaam.shared.removeTag("tier")
        try await Payghaam.shared.removeTags(["tier", "score"])
        try await Payghaam.shared.optOut()
        try await Payghaam.shared.optIn()
        try await Payghaam.shared.bridgeRemoveAlias("crm_id")
        try await Payghaam.shared.bridgeOptOut()
        try await Payghaam.shared.bridgeOptIn()
    }
}
