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

    func testResolvePeerMatchesShortQueryAgainstFullNoiseIndexedPeer() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let shortID = PeerID(str: fullNoiseHex).toShort().bare
        let peer = BitchatPeer(
            peerID: PeerID(str: fullNoiseHex),
            noisePublicKey: Data(hexString: fullNoiseHex) ?? Data(),
            nickname: "noise-peer"
        )
        let peerIndex = [fullNoiseHex: peer]

        let resolved = UnifiedPeerService.resolvePeer(
            from: peerIndex,
            peerID: shortID
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

    func testResolveCachedFingerprintFallsBackToNormalizedKeyMatch() {
        let cache = ["mesh:abcdef0123456789": "fp-2"]

        let resolved = UnifiedPeerService.resolveCachedFingerprint(
            from: cache,
            peerID: "abcdef0123456789"
        )

        XCTAssertEqual(resolved, "fp-2")
    }

    func testResolveCachedFingerprintMatchesShortQueryAgainstFullNoiseCacheKey() {
        let fullNoiseHex = String(repeating: "cd", count: 32)
        let shortID = PeerID(str: fullNoiseHex).toShort().bare
        let cache = [fullNoiseHex: "fp-3"]

        let resolved = UnifiedPeerService.resolveCachedFingerprint(
            from: cache,
            peerID: shortID
        )

        XCTAssertEqual(resolved, "fp-3")
    }

    func testLookupKeysForGeoDMPeerIDDoNotIncludeBareMeshCandidate() {
        let keys = UnifiedPeerService.lookupKeys(for: "nostr_abcdef0123456789")

        XCTAssertEqual(keys, ["nostr_abcdef0123456789"])
    }

    func testLookupKeysForUppercaseGeoDMPeerIDKeepPrefixedVariantOnly() {
        let keys = UnifiedPeerService.lookupKeys(for: "NOSTR_ABCDEF0123456789")

        XCTAssertEqual(keys, ["NOSTR_ABCDEF0123456789", "nostr_abcdef0123456789"])
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

    func testBuildPeerIndexIncludesLookupVariantsForPrefixedMeshPeer() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "mesh:abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x55, count: 32),
            nickname: "prefixed"
        )

        let index = UnifiedPeerService.buildPeerIndex(from: [peer])

        XCTAssertEqual(index["mesh:abcdef0123456789"], peer)
        XCTAssertEqual(index["abcdef0123456789"], peer)
    }

    func testBuildPeerIndexPrefersFirstPeerForEquivalentLookupKey() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let shortPeer = BitchatPeer(
            peerID: PeerID(str: PeerID(str: fullNoiseHex).toShort().bare),
            noisePublicKey: Data(repeating: 0x66, count: 32),
            nickname: "preferred"
        )
        let fullPeer = BitchatPeer(
            peerID: PeerID(str: fullNoiseHex),
            noisePublicKey: Data(hexString: fullNoiseHex) ?? Data(),
            nickname: "fallback"
        )

        let index = UnifiedPeerService.buildPeerIndex(from: [shortPeer, fullPeer])
        let shortID = PeerID(str: fullNoiseHex).toShort().bare

        XCTAssertEqual(index[shortID], shortPeer)
    }

    func testBuildConnectedPeerLookupKeysIncludesEquivalentVariants() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let lookup = UnifiedPeerService.buildConnectedPeerLookupKeys(from: [fullNoiseHex])

        XCTAssertTrue(lookup.contains(fullNoiseHex))
        XCTAssertTrue(lookup.contains(PeerID(str: fullNoiseHex).toShort().bare))
    }

    func testIsPeerOnlineMatchesEquivalentShortToFullNoiseIdentifier() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let connected = Set([fullNoiseHex])
        let lookup = UnifiedPeerService.buildConnectedPeerLookupKeys(from: connected)
        let shortID = PeerID(str: fullNoiseHex).toShort().bare

        XCTAssertTrue(
            UnifiedPeerService.isPeerOnline(
                shortID,
                connectedPeerIDs: connected,
                connectedPeerLookupKeys: lookup
            )
        )
    }

    func testIsPeerOnlineKeepsGeoDMPrefixIsolation() {
        let connected = Set(["abcdef0123456789"])
        let lookup = UnifiedPeerService.buildConnectedPeerLookupKeys(from: connected)

        XCTAssertFalse(
            UnifiedPeerService.isPeerOnline(
                "nostr_abcdef0123456789",
                connectedPeerIDs: connected,
                connectedPeerLookupKeys: lookup
            )
        )
    }

    func testShouldIncludeFavoriteAsOfflinePeerRejectsEquivalentExistingPeer() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let shortID = PeerID(str: fullNoiseHex).toShort().bare
        let existingPeer = BitchatPeer(
            peerID: PeerID(str: shortID),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "alice",
            isConnected: true,
            isReachable: true
        )
        let favoriteNoise = Data(hexString: fullNoiseHex) ?? Data()

        let shouldInclude = UnifiedPeerService.shouldIncludeFavoriteAsOfflinePeer(
            favoriteNoiseKey: favoriteNoise,
            favoriteNickname: "alice",
            existingPeers: [existingPeer],
            addedPeerIDs: []
        )

        XCTAssertFalse(shouldInclude)
    }

    func testShouldIncludeFavoriteAsOfflinePeerAllowsDistinctFavorite() {
        let existingPeer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "alice",
            isConnected: true,
            isReachable: true
        )
        let favoriteNoise = Data(repeating: 0x33, count: 32)

        let shouldInclude = UnifiedPeerService.shouldIncludeFavoriteAsOfflinePeer(
            favoriteNoiseKey: favoriteNoise,
            favoriteNickname: "bob",
            existingPeers: [existingPeer],
            addedPeerIDs: []
        )

        XCTAssertTrue(shouldInclude)
    }

    func testPeerIDLookupMatchesNicknameCaseInsensitivelyAndTrimmed() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x44, count: 32),
            nickname: "Alice"
        )
        let peers = [peer]

        let resolved = UnifiedPeerService.peerID(for: "  alice  ", in: peers)

        XCTAssertEqual(resolved, "abcdef0123456789")
    }

    func testPeerIDLookupReturnsNilForBlankNickname() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x55, count: 32),
            nickname: "Alice"
        )

        XCTAssertNil(UnifiedPeerService.peerID(for: "   ", in: [peer]))
    }

    func testFingerprintFromPeerRejectsNon32ByteNoiseKey() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 8),
            nickname: "short-key"
        )

        XCTAssertNil(UnifiedPeerService.fingerprintFromPeer(peer))
    }

    func testFingerprintFromPeerAccepts32ByteNoiseKey() {
        let key = Data(repeating: 0x22, count: 32)
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: key,
            nickname: "valid-key"
        )

        XCTAssertEqual(UnifiedPeerService.fingerprintFromPeer(peer), key.sha256Fingerprint())
    }

    func testResolvedNoisePublicKeyPrefersSnapshotNoiseKeyWhenValid() {
        let snapshotKey = Data(repeating: 0x33, count: 32)
        let peerIDNoise = String(repeating: "ab", count: 32)
        let snapshot = TransportPeerSnapshot(
            peerID: PeerID(str: peerIDNoise),
            nickname: "peer",
            isConnected: true,
            noisePublicKey: snapshotKey,
            lastSeen: Date()
        )

        XCTAssertEqual(UnifiedPeerService.resolvedNoisePublicKey(for: snapshot), snapshotKey)
    }

    func testResolvedNoisePublicKeyFallsBackToPeerIDNoiseKey() {
        let peerIDNoise = String(repeating: "cd", count: 32)
        let snapshot = TransportPeerSnapshot(
            peerID: PeerID(str: peerIDNoise),
            nickname: "peer",
            isConnected: true,
            noisePublicKey: nil,
            lastSeen: Date()
        )

        XCTAssertEqual(
            UnifiedPeerService.resolvedNoisePublicKey(for: snapshot),
            Data(hexString: peerIDNoise)
        )
    }

    func testResolvedNoisePublicKeyRejectsInvalidLengths() {
        let snapshot = TransportPeerSnapshot(
            peerID: PeerID(str: "abcdef0123456789"),
            nickname: "peer",
            isConnected: true,
            noisePublicKey: Data(repeating: 0x11, count: 8),
            lastSeen: Date()
        )

        XCTAssertNil(UnifiedPeerService.resolvedNoisePublicKey(for: snapshot))
    }
}
