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
}
