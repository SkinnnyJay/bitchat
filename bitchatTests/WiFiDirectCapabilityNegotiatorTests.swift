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

    func testParseCapabilitiesCapsTokenCount() {
        let tokens = (0..<40).map { "cap\($0)" }
        let parsed = WiFiDirectCapabilityNegotiator.parseCapabilities(tokens.joined(separator: ","))
        XCTAssertEqual(parsed.count, 32)
        XCTAssertTrue(parsed.contains("cap0"))
        XCTAssertTrue(parsed.contains("cap31"))
        XCTAssertFalse(parsed.contains("cap32"))
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

    func testConfiguredProtocolVersionIsClampedToPositive() {
        let negotiator = WiFiDirectCapabilityNegotiator(protocolVersion: 0)
        let info = negotiator.discoveryInfo()

        XCTAssertEqual(info["v"], "1")
    }

    func testConfiguredCapabilitiesAreSanitizedAndIncludeRequiredSet() {
        let negotiator = WiFiDirectCapabilityNegotiator(
            requiredCapabilities: [" PM "],
            defaultCapabilities: [" ACK ", "bad token!", "relay"]
        )

        let info = negotiator.discoveryInfo()

        XCTAssertEqual(info["caps"], "ack,pm,relay")
    }

    func testConfiguredRequiredCapabilitiesAreSanitizedForCompatibilityChecks() {
        let negotiator = WiFiDirectCapabilityNegotiator(requiredCapabilities: [" PM "])

        XCTAssertTrue(negotiator.isPeerCompatible(discoveryInfo: ["v": "1", "caps": "pm"]))
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: ["v": "1", "caps": "ack"]))
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
        XCTAssertEqual(parsed?["caps"], "__invalid__")
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }

    func testParseDiscoveryInfoReturnsNilWhenOnlyUnknownFieldsPresent() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["junk": "value"]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        XCTAssertNil(negotiator.parseDiscoveryInfo(from: context))
    }

    func testParseDiscoveryInfoRejectsBooleanFields() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["v": true, "caps": false]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)
        XCTAssertEqual(parsed?["v"], "__invalid__")
        XCTAssertEqual(parsed?["caps"], "__invalid__")
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: parsed))
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

    func testParseDiscoveryInfoMarksOversizedVersionAsInvalid() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let oversizedVersion = String(repeating: "1", count: 32)
        let raw: [String: Any] = ["v": oversizedVersion, "caps": "pm,ack"]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["v"], "__invalid__")
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }

    func testParseDiscoveryInfoMarksEmptyCapabilitiesAsInvalid() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["v": 1, "caps": "   "]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["caps"], "__invalid__")
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }

    func testParseDiscoveryInfoMarksEmptyVersionAsInvalid() throws {
        let negotiator = WiFiDirectCapabilityNegotiator()
        let raw: [String: Any] = ["v": "   ", "caps": "pm,ack"]
        let context = try JSONSerialization.data(withJSONObject: raw, options: [])

        let parsed = negotiator.parseDiscoveryInfo(from: context)

        XCTAssertEqual(parsed?["v"], "__invalid__")
        XCTAssertFalse(negotiator.isPeerCompatible(discoveryInfo: parsed))
    }
}
