import XCTest
@testable import Payghaam

@MainActor
final class TagDebounceSimulatorTests: XCTestCase {

    func testTagDebounceAndFlushEndToEnd() async throws {
        let config = PayghaamConfig(
            appId: "cmqy0h7a8000xfcypq66nw18d",
            apiKey: "ek_client_simulator_test_key_456",
            baseUrl: "http://127.0.0.1:4000"
        )
        
        // 1. Identify/create the user first so the backend subscriber record exists
        try await ApiClient.identify(config: config, externalId: "sim_ios_user_e2e")
        
        // Configure bridge session
        Payghaam.shared.persistBridgeConfig(
            apiKey: "ek_client_simulator_test_key_456",
            baseUrl: "http://127.0.0.1:4000",
            externalId: "sim_ios_user_e2e"
        )
        
        // 2. Spam 4 tags in rapid burst (50ms interval)
        try await Payghaam.shared.addTags(["ios_tag_1": "alpha"])
        try await Payghaam.shared.addTags(["ios_tag_2": "beta"])
        try await Payghaam.shared.addTags(["ios_tag_3": "gamma"])
        try await Payghaam.shared.addTags(["final_tier": "diamond"])
        
        // 3. Explicitly flush debouncer
        await Payghaam.shared.flushTags()
        
        // Give the async network queue and worker a moment to process
        try await Task.sleep(nanoseconds: 800_000_000)
        
        XCTAssertTrue(Payghaam.shared.isInitialized)
    }

    func testAutomaticTimerDebounce() async throws {
        let config = PayghaamConfig(
            appId: "cmqy0h7a8000xfcypq66nw18d",
            apiKey: "ek_client_simulator_test_key_456",
            baseUrl: "http://127.0.0.1:4000"
        )
        
        // Identify first
        try await ApiClient.identify(config: config, externalId: "sim_ios_timer_user")
        
        Payghaam.shared.persistBridgeConfig(
            apiKey: "ek_client_simulator_test_key_456",
            baseUrl: "http://127.0.0.1:4000",
            externalId: "sim_ios_timer_user"
        )
        
        // Set tags without manual flush to test the 300ms timer
        try await Payghaam.shared.addTags(["auto_flushed_key": "timer_success", "score": 99])
        
        // Wait 800ms for the 300ms debounce timer + worker ingestion
        try await Task.sleep(nanoseconds: 800_000_000)
        
        XCTAssertTrue(Payghaam.shared.isInitialized)
    }

    func testLiveActivityUpdateTokenRegistration() async throws {
        let config = PayghaamConfig(
            appId: "cmqy0h7a8000xfcypq66nw18d",
            apiKey: "ek_client_simulator_test_key_456",
            baseUrl: "http://127.0.0.1:4000"
        )
        
        try await ApiClient.identify(config: config, externalId: "sim_ios_live_act_user")
        
        Payghaam.shared.persistBridgeConfig(
            apiKey: "ek_client_simulator_test_key_456",
            baseUrl: "http://127.0.0.1:4000",
            externalId: "sim_ios_live_act_user"
        )
        
        let accepted = await Payghaam.shared.registerLiveActivityUpdateToken(
            activityId: "sim_delivery_order_99",
            token: "apns_live_sim_tok_1234567890abcdef",
            attributesType: "DeliveryStatusAttributes"
        )
        
        XCTAssertTrue(accepted, "Expected Live Activity token registration to succeed")
    }
}
