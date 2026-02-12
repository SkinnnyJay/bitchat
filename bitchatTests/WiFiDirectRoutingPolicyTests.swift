import XCTest
@testable import bitchat

final class WiFiDirectRoutingPolicyTests: XCTestCase {
    func testDisablesWiFiWhenUnavailable() {
        let policy = WiFiDirectRoutingPolicy(preferredPayloadBytes: 100)
        XCTAssertFalse(
            policy.shouldUseWiFi(
                payloadBytes: 10_000,
                recipientPeerID: "peer-a",
                wifiAvailable: false,
                wifiPeerIDs: ["peer-a"]
            )
        )
    }

    func testUsesWiFiWhenPayloadAboveThresholdAndPeerAvailable() {
        let policy = WiFiDirectRoutingPolicy(preferredPayloadBytes: 100)
        XCTAssertTrue(
            policy.shouldUseWiFi(
                payloadBytes: 150,
                recipientPeerID: "peer-a",
                wifiAvailable: true,
                wifiPeerIDs: ["peer-a", "peer-b"]
            )
        )
    }

    func testFallsBackWhenPeerNotOnWiFi() {
        let policy = WiFiDirectRoutingPolicy(preferredPayloadBytes: 100)
        XCTAssertFalse(
            policy.shouldUseWiFi(
                payloadBytes: 150,
                recipientPeerID: "peer-z",
                wifiAvailable: true,
                wifiPeerIDs: ["peer-a", "peer-b"]
            )
        )
    }

    func testFallsBackWhenPayloadBelowThreshold() {
        let policy = WiFiDirectRoutingPolicy(preferredPayloadBytes: 100)
        XCTAssertFalse(
            policy.shouldUseWiFi(
                payloadBytes: 99,
                recipientPeerID: "peer-a",
                wifiAvailable: true,
                wifiPeerIDs: ["peer-a"]
            )
        )
    }
}
