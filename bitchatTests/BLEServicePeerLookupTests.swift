import XCTest
@testable import bitchat

final class BLEServicePeerLookupTests: XCTestCase {
    func testPeerLookupKeysIncludeBareShortForPrefixedShortPeerID() {
        let keys = BLEService.peerLookupKeys(for: PeerID(str: "mesh:abcdef0123456789"))

        XCTAssertTrue(keys.contains("mesh:abcdef0123456789"))
        XCTAssertTrue(keys.contains("abcdef0123456789"))
    }

    func testPeerLookupKeysIncludeDerivedShortForFullNoisePeerID() {
        let fullNoisePeerID = PeerID(str: String(repeating: "ab", count: 32))
        let expectedShort = fullNoisePeerID.toShort().bare

        let keys = BLEService.peerLookupKeys(for: fullNoisePeerID)

        XCTAssertTrue(keys.contains(fullNoisePeerID.id))
        XCTAssertTrue(keys.contains(expectedShort))
    }

    func testPeerLookupKeysTrimAndDedupeCandidates() {
        let keys = BLEService.peerLookupKeys(for: PeerID(str: "  mesh:abcdef0123456789  "))

        XCTAssertEqual(keys.filter { $0 == "mesh:abcdef0123456789" }.count, 1)
        XCTAssertEqual(keys.filter { $0 == "abcdef0123456789" }.count, 1)
    }

    func testCanonicalRoutingPeerIDNormalizesPrefixedShortToBareHex() {
        let canonical = BLEService.canonicalRoutingPeerID(for: PeerID(str: "mesh:abcdef0123456789"))

        XCTAssertEqual(canonical, PeerID(str: "abcdef0123456789"))
    }

    func testCanonicalRoutingPeerIDDerivesShortFromFullNoiseID() {
        let fullNoiseID = PeerID(str: String(repeating: "ab", count: 32))
        let canonical = BLEService.canonicalRoutingPeerID(for: fullNoiseID)

        XCTAssertEqual(canonical, PeerID(str: fullNoiseID.toShort().bare))
    }

    func testCanonicalRoutingPeerIDRejectsNonRoutablePeerID() {
        XCTAssertNil(BLEService.canonicalRoutingPeerID(for: PeerID(str: "peer-not-routable")))
    }
}
