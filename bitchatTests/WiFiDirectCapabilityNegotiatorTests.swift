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

    func testParseCapabilitiesDropsInvalidTokens() {
        let parsed = WiFiDirectCapabilityNegotiator.parseCapabilities("pm,ack,../bad,emoji🙂,relay")
        XCTAssertEqual(parsed, ["pm", "ack", "relay"])
    }

    func testParseCapabilitiesDropsOversizedTokens() {
        let oversized = String(repeating: "a", count: 64)
        let parsed = WiFiDirectCapabilityNegotiator.parseCapabilities("pm,\(oversized),ack")
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

    func testPeerMustContainAllRequiredCapabilitiesWhenMultipleRequired() {
        let negotiator = WiFiDirectCapabilityNegotiator(requiredCapabilities: ["pm", "ack"])

        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: ["v": "1", "caps": "pm"]))
        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: ["v": "1", "caps": "pm,ack"]))
    }

    func testDiscoveryInfoUsesConfiguredVersionAndCapabilities() {
        let negotiator = WiFiDirectCapabilityNegotiator(
            protocolVersion: 7,
            defaultCapabilities: ["pm", "relay"]
        )

        let info = negotiator.discoveryInfo()

        XCTAssertEqual(info["v"], "7")
        XCTAssertEqual(info["caps"], "pm,relay")
    }

    func testParseDiscoveryInfoIgnoresUnknownFields() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["v": 1, "caps": "pm,ack", "junk": "value"]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["v"], "1")
        XCTAssertEqual(parsed?["caps"], "pm,ack")
        XCTAssertNil(parsed?["junk"])
    }

    func testParseDiscoveryInfoDropsOversizedCapabilitiesValue() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let oversizedCaps = String(repeating: "p", count: 1024)
        let raw: [String: Any] = ["v": 1, "caps": oversizedCaps]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["v"], "1")
        XCTAssertNil(parsed?["caps"])
        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }

    func testParseDiscoveryInfoReturnsNilWhenOnlyUnknownFieldsPresent() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["junk": "value"]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        XCTAssertNil(negotiator.parseDiscoveryInfo(from: context))
    }

    func testParseDiscoveryInfoTrimsVersionAndCapabilitiesValues() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["v": " 1 ", "caps": " pm,ack "]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["v"], "1")
        XCTAssertEqual(parsed?["caps"], "pm,ack")
        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }
}
