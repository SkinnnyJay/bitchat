import XCTest
@testable import bitchat

final class WiFiDirectCapabilityNegotiatorTests: XCTestCase {
    func testDiscoveryInfoIncludesVersionAndCapabilities() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let info = negotiator.discoveryInfo()

        XCTAssertEqual(info["v"], String(WiFiDirectCapabilityNegotiator.currentProtocolVersion))
        XCTAssertNotNil(info["caps"])
        XCTAssertTrue(info["caps"]?.contains("pm") == true)
    }

    func testPeerWithoutMetadataIsCompatible() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: nil))
    }

    func testPeerWithDifferentVersionIsIncompatible() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: ["v": "2", "caps": "pm,ack"]))
    }

    func testPeerWithoutRequiredCapabilityIsIncompatible() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: ["v": "1", "caps": "emoji"]))
    }

    func testPeerWithRequiredCapabilityIsCompatible() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: ["v": "1", "caps": "pm"]))
    }

    func testPeerWithMalformedVersionIsIncompatible() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: ["v": "one", "caps": "pm,ack"]))
    }

    func testParseCapabilitiesNormalizesAndDeduplicates() {
        let parsed = WiFiDirectCapabilityNegotiator.parseCapabilities(" PM,ack,pm , ACK ")
        XCTAssertEqual(parsed, ["pm", "ack"])
    }

    func testInvitationContextRoundTripsDiscoveryInfo() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let context = negotiator.invitationContextData()
        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["v"], "1")
        XCTAssertEqual(parsed?["caps"], "ack,pm")
    }

    func testParseDiscoveryInfoReturnsNilForMalformedContext() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let malformed = Data("not-json".utf8)
        XCTAssertNil(negotiator.parseDiscoveryInfo(from: malformed))
    }

    func testIsPeerCompatibleWithInvitationContext() {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let context = negotiator.invitationContextData()
        let parsed = negotiator.parseDiscoveryInfo(from: context)
        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }

    func testParseDiscoveryInfoSupportsNumericVersionField() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["v": 1, "caps": "pm,ack"]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["v"], "1")
        XCTAssertEqual(parsed?["caps"], "pm,ack")
        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }
}
