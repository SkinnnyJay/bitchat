import XCTest
@testable import bitchat

final class UnifiedPeerServiceLookupTests: XCTestCase {
    func testLookupKeysIncludePrefixedBareAndLowercasedVariants() {
        let keys = UnifiedPeerService.lookupKeys(for: "mesh:ABCDEF0123456789")

        XCTAssertTrue(keys.contains("mesh:ABCDEF0123456789"))
        XCTAssertTrue(keys.contains("mesh:abcdef0123456789"))
        XCTAssertTrue(keys.contains("ABCDEF0123456789"))
        XCTAssertTrue(keys.contains("abcdef0123456789"))
    }

    func testResolvePeerMatchesPrefixedQueryAgainstBareIndexKey() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "alice"
        )
        let peerIndex = ["abcdef0123456789": peer]

        let resolved = UnifiedPeerService.resolvePeer(
            from: peerIndex,
            peerID: "mesh:abcdef0123456789"
        )

        XCTAssertEqual(resolved, peer)
    }

    func testResolveCachedFingerprintMatchesEquivalentIdentifierVariants() {
        let cache = ["abcdef0123456789": "fp-1"]

        let resolved = UnifiedPeerService.resolveCachedFingerprint(
            from: cache,
            peerID: "mesh:ABCDEF0123456789"
        )

        XCTAssertEqual(resolved, "fp-1")
    }

    func testLookupKeysForGeoDMPeerIDDoNotIncludeBareMeshCandidate() {
        let keys = UnifiedPeerService.lookupKeys(for: "nostr_abcdef0123456789")

        XCTAssertEqual(keys, ["nostr_abcdef0123456789"])
    }

    func testResolvePeerDoesNotCrossResolveGeoDMIntoBareMeshID() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x33, count: 32),
            nickname: "bob"
        )
        let peerIndex = ["abcdef0123456789": peer]

        let resolved = UnifiedPeerService.resolvePeer(
            from: peerIndex,
            peerID: "nostr_abcdef0123456789"
        )

        XCTAssertNil(resolved)
    }

    func testResolvePeerFindsExactGeoDMKeyCaseInsensitively() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "nostr_abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x44, count: 32),
            nickname: "carol"
        )
        let peerIndex = ["nostr_abcdef0123456789": peer]

        let resolved = UnifiedPeerService.resolvePeer(
            from: peerIndex,
            peerID: "NOSTR_ABCDEF0123456789"
        )

        XCTAssertEqual(resolved, peer)
    }
}
