import XCTest
@testable import bitchat

final class BLEServicePeerLookupTests: XCTestCase {
    func testPeerLookupKeysIncludeBareShortForPrefixedShortPeerID() {
        let keys = BLEService.peerLookupKeys(for: PeerID(str: "mesh:abcdef0123456789"))

        XCTAssertTrue(keys.contains("mesh:abcdef0123456789"))
        XCTAssertTrue(keys.contains("abcdef0123456789"))
    }

    func testPeerLookupKeysIncludeLowercasedVariantsForUppercaseHexInput() {
        let keys = BLEService.peerLookupKeys(for: PeerID(str: "mesh:ABCDEF0123456789"))

        XCTAssertTrue(keys.contains("mesh:ABCDEF0123456789"))
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

    func testRoutingPeerIDDataNormalizesPrefixedShortToEightBytes() {
        let data = BLEService.routingPeerIDData(for: PeerID(str: "mesh:ABCDEF0123456789"))

        XCTAssertEqual(data?.count, 8)
        XCTAssertEqual(data?.hexEncodedString(), "abcdef0123456789")
    }

    func testRoutingPeerIDDataDerivesEightByteFingerprintFromFullNoisePeerID() {
        let fullNoiseID = PeerID(str: String(repeating: "ab", count: 32))
        let expected = fullNoiseID.toShort().bare

        let data = BLEService.routingPeerIDData(for: fullNoiseID)

        XCTAssertEqual(data?.count, 8)
        XCTAssertEqual(data?.hexEncodedString(), expected)
    }

    func testIsReachableReturnsTrueWhenAnyCandidateIsConnected() {
        let now = Date()
        let states: [(Bool, Bool, Date)] = [
            (false, false, now.addingTimeInterval(-10_000)),
            (true, false, now.addingTimeInterval(-10_000))
        ]

        XCTAssertTrue(BLEService.isReachable(candidateStates: states, meshAttached: false, now: now))
    }

    func testIsReachableRespectsRetentionForDisconnectedCandidatesWhenMeshAttached() {
        let now = Date()
        let verifiedFresh = now.addingTimeInterval(-(TransportConfig.bleReachabilityRetentionVerifiedSeconds - 1))
        let staleUnverified = now.addingTimeInterval(-(TransportConfig.bleReachabilityRetentionUnverifiedSeconds + 5))
        let states: [(Bool, Bool, Date)] = [
            (false, false, staleUnverified),
            (false, true, verifiedFresh)
        ]

        XCTAssertTrue(BLEService.isReachable(candidateStates: states, meshAttached: true, now: now))
    }

    func testIsReachableReturnsFalseForDisconnectedStaleCandidates() {
        let now = Date()
        let staleVerified = now.addingTimeInterval(-(TransportConfig.bleReachabilityRetentionVerifiedSeconds + 5))
        let staleUnverified = now.addingTimeInterval(-(TransportConfig.bleReachabilityRetentionUnverifiedSeconds + 5))
        let states: [(Bool, Bool, Date)] = [
            (false, false, staleUnverified),
            (false, true, staleVerified)
        ]

        XCTAssertFalse(BLEService.isReachable(candidateStates: states, meshAttached: true, now: now))
        XCTAssertFalse(BLEService.isReachable(candidateStates: states, meshAttached: false, now: now))
    }
}
