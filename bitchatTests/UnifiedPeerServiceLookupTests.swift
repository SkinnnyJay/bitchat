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

    func testShouldSortPeerPrioritizesConnectedThenReachable() {
        let connected = BitchatPeer(
            peerID: PeerID(str: "aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer",
            isConnected: true,
            isReachable: true
        )
        let reachable = BitchatPeer(
            peerID: PeerID(str: "bbbbbbbbbbbbbbbb"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "peer",
            isConnected: false,
            isReachable: true
        )

        XCTAssertTrue(UnifiedPeerService.shouldSortPeer(connected, reachable))
        XCTAssertFalse(UnifiedPeerService.shouldSortPeer(reachable, connected))
    }

    func testShouldSortPeerUsesDeterministicPeerIDTieBreaker() {
        let first = BitchatPeer(
            peerID: PeerID(str: "aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "same",
            isConnected: false,
            isReachable: false
        )
        let second = BitchatPeer(
            peerID: PeerID(str: "bbbbbbbbbbbbbbbb"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "same",
            isConnected: false,
            isReachable: false
        )

        XCTAssertTrue(UnifiedPeerService.shouldSortPeer(first, second))
        XCTAssertFalse(UnifiedPeerService.shouldSortPeer(second, first))
    }

    func testShouldSortPeerComparesDisplayNamesCaseInsensitively() {
        let alpha = BitchatPeer(
            peerID: PeerID(str: "aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "Alice",
            isConnected: false,
            isReachable: false
        )
        let beta = BitchatPeer(
            peerID: PeerID(str: "bbbbbbbbbbbbbbbb"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "bob",
            isConnected: false,
            isReachable: false
        )

        XCTAssertTrue(UnifiedPeerService.shouldSortPeer(alpha, beta))
        XCTAssertFalse(UnifiedPeerService.shouldSortPeer(beta, alpha))
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

    func testResolvePeerFallbackIsDeterministicAcrossEquivalentMatches() {
        let first = BitchatPeer(
            peerID: PeerID(str: "aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "first"
        )
        let second = BitchatPeer(
            peerID: PeerID(str: "mesh:aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "second"
        )
        let index = [
            "key-first": first,
            "key-second": second
        ]

        let resolved = UnifiedPeerService.resolvePeer(from: index, peerID: "name:aaaaaaaaaaaaaaaa")

        XCTAssertEqual(resolved?.peerID.id, "aaaaaaaaaaaaaaaa")
    }

    func testResolvePeerFallbackPrefersConnectedEquivalentPeer() {
        let disconnected = BitchatPeer(
            peerID: PeerID(str: "aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "offline",
            isConnected: false,
            isReachable: false
        )
        let connected = BitchatPeer(
            peerID: PeerID(str: "mesh:aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "online",
            isConnected: true,
            isReachable: true
        )
        let index = [
            "k1": disconnected,
            "k2": connected
        ]

        let resolved = UnifiedPeerService.resolvePeer(from: index, peerID: "name:aaaaaaaaaaaaaaaa")

        XCTAssertEqual(resolved?.peerID.id, connected.peerID.id)
    }

    func testResolveCachedFingerprintMatchesEquivalentIdentifierVariants() {
        let fingerprint = String(repeating: "a1", count: 32)
        let cache = ["abcdef0123456789": fingerprint]

        let resolved = UnifiedPeerService.resolveCachedFingerprint(
            from: cache,
            peerID: "mesh:ABCDEF0123456789"
        )

        XCTAssertEqual(resolved, fingerprint)
    }

    func testCanonicalFingerprintNormalizesCaseAndWhitespace() {
        let raw = "  " + String(repeating: "Ab", count: 32) + "  "

        let canonical = UnifiedPeerService.canonicalFingerprint(raw)

        XCTAssertEqual(canonical, String(repeating: "ab", count: 32))
    }

    func testCanonicalFingerprintRejectsInvalidLengthOrNonHex() {
        XCTAssertNil(UnifiedPeerService.canonicalFingerprint("abc"))
        XCTAssertNil(UnifiedPeerService.canonicalFingerprint(String(repeating: "zz", count: 32)))
    }

    func testResolveCachedFingerprintFallsBackToNormalizedKeyMatch() {
        let fingerprint = String(repeating: "b2", count: 32)
        let cache = ["mesh:abcdef0123456789": fingerprint]

        let resolved = UnifiedPeerService.resolveCachedFingerprint(
            from: cache,
            peerID: "abcdef0123456789"
        )

        XCTAssertEqual(resolved, fingerprint)
    }

    func testResolveCachedFingerprintFallbackUsesDeterministicKeyOrdering() {
        let first = String(repeating: "c3", count: 32)
        let second = String(repeating: "d4", count: 32)
        let cache = [
            "mesh:abcdef0123456789": second,
            "abcdef0123456789": first
        ]

        let resolved = UnifiedPeerService.resolveCachedFingerprint(
            from: cache,
            peerID: "name:abcdef0123456789"
        )

        XCTAssertEqual(resolved, first)
    }

    func testResolveCachedFingerprintMatchesShortQueryAgainstFullNoiseCacheKey() {
        let fullNoiseHex = String(repeating: "cd", count: 32)
        let shortID = PeerID(str: fullNoiseHex).toShort().bare
        let fingerprint = String(repeating: "c3", count: 32)
        let cache = [fullNoiseHex: fingerprint]

        let resolved = UnifiedPeerService.resolveCachedFingerprint(
            from: cache,
            peerID: shortID
        )

        XCTAssertEqual(resolved, fingerprint)
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

    func testBuildPeerIndexIncludesFullNoiseLookupForShortPeer() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let shortID = PeerID(str: fullNoiseHex).toShort().bare
        let peer = BitchatPeer(
            peerID: PeerID(str: shortID),
            noisePublicKey: Data(hexString: fullNoiseHex) ?? Data(),
            nickname: "noise-backed"
        )

        let index = UnifiedPeerService.buildPeerIndex(from: [peer])

        XCTAssertEqual(index[fullNoiseHex], peer)
        XCTAssertEqual(index[shortID], peer)
    }

    func testBuildPeerIndexKeepsGeoPrefixIsolation() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "nostr_abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x77, count: 32),
            nickname: "geo"
        )

        let index = UnifiedPeerService.buildPeerIndex(from: [peer])

        XCTAssertEqual(index["nostr_abcdef0123456789"], peer)
        XCTAssertNil(index["abcdef0123456789"])
    }

    func testBuildPeerIndexDoesNotAddFullNoiseAliasesForGeoPrefixedPeers() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let peer = BitchatPeer(
            peerID: PeerID(str: "nostr_abcdef0123456789"),
            noisePublicKey: Data(hexString: fullNoiseHex) ?? Data(),
            nickname: "geo"
        )

        let index = UnifiedPeerService.buildPeerIndex(from: [peer])

        XCTAssertNil(index[fullNoiseHex])
        XCTAssertNil(index[PeerID(str: fullNoiseHex).toShort().bare])
    }

    func testBuildPeerIndexPrefersHigherPriorityPeerForEquivalentLookupKey() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let shortPeer = BitchatPeer(
            peerID: PeerID(str: PeerID(str: fullNoiseHex).toShort().bare),
            noisePublicKey: Data(repeating: 0x66, count: 32),
            nickname: "preferred",
            isConnected: false,
            isReachable: false
        )
        let fullPeer = BitchatPeer(
            peerID: PeerID(str: fullNoiseHex),
            noisePublicKey: Data(hexString: fullNoiseHex) ?? Data(),
            nickname: "fallback",
            isConnected: true,
            isReachable: true
        )

        let index = UnifiedPeerService.buildPeerIndex(from: [shortPeer, fullPeer])
        let shortID = PeerID(str: fullNoiseHex).toShort().bare

        XCTAssertEqual(index[shortID], fullPeer)
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

    func testIsPeerOnlineMatchesUppercasePrefixedMeshQuery() {
        let connected = Set(["mesh:abcdef0123456789"])
        let lookup = UnifiedPeerService.buildConnectedPeerLookupKeys(from: connected)

        XCTAssertTrue(
            UnifiedPeerService.isPeerOnline(
                "MESH:ABCDEF0123456789",
                connectedPeerIDs: connected,
                connectedPeerLookupKeys: lookup
            )
        )
    }

    func testMeshDedupKeyUsesNormalizedIdentity() {
        XCTAssertEqual(
            UnifiedPeerService.meshDedupKey(for: PeerID(str: "mesh:ABCDEF0123456789")),
            "abcdef0123456789"
        )
    }

    func testShouldPreferMeshPeerPrefersConnectedPeer() {
        let existing = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer",
            isConnected: false,
            isReachable: true
        )
        let candidate = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer",
            isConnected: true,
            isReachable: true
        )

        XCTAssertTrue(UnifiedPeerService.shouldPreferMeshPeer(candidate, over: existing))
    }

    func testShouldPreferMeshPeerPrefersValidNoiseKeyWhenConnectivityEqual() {
        let existing = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 8),
            nickname: "peer",
            isConnected: false,
            isReachable: false
        )
        let candidate = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "peer",
            isConnected: false,
            isReachable: false
        )

        XCTAssertTrue(UnifiedPeerService.shouldPreferMeshPeer(candidate, over: existing))
    }

    func testShouldPreferMeshPeerPrefersMoreRecentPeerWhenOtherSignalsEqual() {
        let existing = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer",
            lastSeen: Date(timeIntervalSince1970: 10),
            isConnected: false,
            isReachable: false
        )
        let candidate = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer",
            lastSeen: Date(timeIntervalSince1970: 20),
            isConnected: false,
            isReachable: false
        )

        XCTAssertTrue(UnifiedPeerService.shouldPreferMeshPeer(candidate, over: existing))
    }

    func testShouldPreferMeshPeerUsesPeerIDAsDeterministicTieBreaker() {
        let existing = BitchatPeer(
            peerID: PeerID(str: "bbbbbbbbbbbbbbbb"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer",
            lastSeen: Date(timeIntervalSince1970: 20),
            isConnected: false,
            isReachable: false
        )
        let candidate = BitchatPeer(
            peerID: PeerID(str: "aaaaaaaaaaaaaaaa"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer",
            lastSeen: Date(timeIntervalSince1970: 20),
            isConnected: false,
            isReachable: false
        )

        XCTAssertTrue(UnifiedPeerService.shouldPreferMeshPeer(candidate, over: existing))
    }

    func testDeduplicateMeshPeersKeepsPreferredPeerForEquivalentKey() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let shortID = PeerID(str: fullNoiseHex).toShort().bare
        let connectedPeer = BitchatPeer(
            peerID: PeerID(str: shortID),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "connected",
            isConnected: true,
            isReachable: true
        )
        let disconnectedEquivalent = BitchatPeer(
            peerID: PeerID(str: fullNoiseHex),
            noisePublicKey: Data(hexString: fullNoiseHex) ?? Data(),
            nickname: "disconnected",
            isConnected: false,
            isReachable: true
        )

        let deduped = UnifiedPeerService.deduplicateMeshPeers([disconnectedEquivalent, connectedPeer])

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first, connectedPeer)
    }

    func testDeduplicateMeshPeersKeepsGeoPrefixDistinctFromMeshID() {
        let meshPeer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "mesh"
        )
        let geoPeer = BitchatPeer(
            peerID: PeerID(str: "nostr_abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "geo"
        )

        let deduped = UnifiedPeerService.deduplicateMeshPeers([meshPeer, geoPeer])

        XCTAssertEqual(deduped.count, 2)
        XCTAssertTrue(deduped.contains(meshPeer))
        XCTAssertTrue(deduped.contains(geoPeer))
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

    func testShouldIncludeFavoriteAsOfflinePeerRejectsInvalidNoiseKeyLength() {
        let shouldInclude = UnifiedPeerService.shouldIncludeFavoriteAsOfflinePeer(
            favoriteNoiseKey: Data(repeating: 0x11, count: 8),
            favoriteNickname: "alice",
            existingPeers: [],
            addedPeerIDs: []
        )

        XCTAssertFalse(shouldInclude)
    }

    func testShouldIncludeFavoriteAsOfflinePeerUsesSanitizedNicknameComparison() {
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
            favoriteNickname: "   alice   ",
            existingPeers: [existingPeer],
            addedPeerIDs: []
        )

        XCTAssertFalse(shouldInclude)
    }

    func testSanitizedPeerNicknameFallsBackToUserForInvalidInput() {
        XCTAssertEqual(UnifiedPeerService.sanitizedPeerNickname("   "), "user")
    }

    func testSanitizedPeerNicknameKeepsValidNickname() {
        XCTAssertEqual(UnifiedPeerService.sanitizedPeerNickname("alice"), "alice")
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

    func testPeerIDLookupPrefersConnectedPeerWhenNicknamesDuplicate() {
        let connected = BitchatPeer(
            peerID: PeerID(str: "1111111111111111"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "alice",
            isConnected: true,
            isReachable: true
        )
        let offline = BitchatPeer(
            peerID: PeerID(str: "2222222222222222"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "alice",
            isConnected: false,
            isReachable: false
        )

        let resolved = UnifiedPeerService.peerID(for: "alice", in: [offline, connected])

        XCTAssertEqual(resolved, connected.peerID.id)
    }

    func testBestPeerForNicknameMatchFallsBackToMostRecentWhenPriorityEqual() {
        let older = BitchatPeer(
            peerID: PeerID(str: "3333333333333333"),
            noisePublicKey: Data(repeating: 0x33, count: 32),
            nickname: "alice",
            lastSeen: Date(timeIntervalSince1970: 10),
            isConnected: false,
            isReachable: false
        )
        let newer = BitchatPeer(
            peerID: PeerID(str: "4444444444444444"),
            noisePublicKey: Data(repeating: 0x44, count: 32),
            nickname: "alice",
            lastSeen: Date(timeIntervalSince1970: 20),
            isConnected: false,
            isReachable: false
        )

        let best = UnifiedPeerService.bestPeerForNicknameMatch([older, newer])

        XCTAssertEqual(best, newer)
    }

    func testBestPeerForNicknameMatchReturnsNilForEmptyInput() {
        XCTAssertNil(UnifiedPeerService.bestPeerForNicknameMatch([]))
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

    func testCacheFingerprintStoresVariantAndNormalizedKeys() {
        var cache: [String: String] = [:]

        let fingerprint = String(repeating: "d4", count: 32)
        UnifiedPeerService.cacheFingerprint(
            fingerprint,
            for: "mesh:ABCDEF0123456789",
            in: &cache
        )

        XCTAssertEqual(cache["mesh:ABCDEF0123456789"], fingerprint)
        XCTAssertEqual(cache["mesh:abcdef0123456789"], fingerprint)
        XCTAssertEqual(cache["abcdef0123456789"], fingerprint)
    }

    func testCacheFingerprintKeepsGeoPrefixIsolation() {
        var cache: [String: String] = [:]

        let fingerprint = String(repeating: "e5", count: 32)
        UnifiedPeerService.cacheFingerprint(
            fingerprint,
            for: "nostr_abcdef0123456789",
            in: &cache
        )

        XCTAssertEqual(cache["nostr_abcdef0123456789"], fingerprint)
        XCTAssertNil(cache["abcdef0123456789"])
    }

    func testCacheFingerprintCappedEvictsOldestKeysWhenCapExceeded() {
        var cache: [String: String] = [:]
        var order: [String] = []

        let fpA = String(repeating: "f6", count: 32)
        let fpB = String(repeating: "07", count: 32)
        let fpC = String(repeating: "18", count: 32)
        UnifiedPeerService.cacheFingerprint(fpA, for: "peera", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint(fpB, for: "peerb", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint(fpC, for: "peerc", in: &cache, order: &order, cap: 2)

        XCTAssertEqual(order, ["peerb", "peerc"])
        XCTAssertNil(cache["peera"])
        XCTAssertEqual(cache["peerb"], fpB)
        XCTAssertEqual(cache["peerc"], fpC)
    }

    func testCacheFingerprintCappedRefreshesExistingKeyRecency() {
        var cache: [String: String] = [:]
        var order: [String] = []

        let fpA = String(repeating: "29", count: 32)
        let fpB = String(repeating: "3a", count: 32)
        let fpA2 = String(repeating: "4b", count: 32)
        UnifiedPeerService.cacheFingerprint(fpA, for: "peera", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint(fpB, for: "peerb", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint(fpA2, for: "peera", in: &cache, order: &order, cap: 2)

        XCTAssertEqual(order, ["peerb", "peera"])
        XCTAssertEqual(cache["peera"], fpA2)
    }

    func testCacheFingerprintIgnoresInvalidFingerprintValues() {
        var cache: [String: String] = [:]

        UnifiedPeerService.cacheFingerprint("invalid", for: "mesh:abcdef0123456789", in: &cache)

        XCTAssertTrue(cache.isEmpty)
    }

    func testFingerprintCacheReferenceIDsIncludePeerAndNoiseAliases() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let shortPeer = BitchatPeer(
            peerID: PeerID(str: PeerID(str: fullNoiseHex).toShort().bare),
            noisePublicKey: Data(hexString: fullNoiseHex) ?? Data(),
            nickname: "short"
        )
        let geoPeer = BitchatPeer(
            peerID: PeerID(str: "nostr_abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "geo"
        )

        let references = UnifiedPeerService.fingerprintCacheReferenceIDs(from: [shortPeer, geoPeer])

        XCTAssertTrue(references.contains(shortPeer.peerID.id))
        XCTAssertTrue(references.contains(fullNoiseHex))
        XCTAssertTrue(references.contains(geoPeer.peerID.id))
        XCTAssertFalse(references.contains(geoPeer.noisePublicKey.hexEncodedString()))
    }

    func testPruneFingerprintCacheRemovesKeysOutsideReferenceSet() {
        var cache: [String: String] = [
            "peera": String(repeating: "5c", count: 32),
            "peerb": String(repeating: "6d", count: 32)
        ]
        var order = ["peera", "peerb"]

        UnifiedPeerService.pruneFingerprintCache(
            &cache,
            order: &order,
            referenceIDs: ["peera"],
            cap: 10
        )

        XCTAssertEqual(cache, ["peera": String(repeating: "5c", count: 32)])
        XCTAssertEqual(order, ["peera"])
    }

    func testPruneFingerprintCacheHonorsCapAfterFiltering() {
        var cache: [String: String] = [
            "peera": String(repeating: "7e", count: 32),
            "peerb": String(repeating: "8f", count: 32),
            "peerc": String(repeating: "90", count: 32)
        ]
        var order = ["peera", "peerb", "peerc"]

        UnifiedPeerService.pruneFingerprintCache(
            &cache,
            order: &order,
            referenceIDs: ["peera", "peerb", "peerc"],
            cap: 2
        )

        XCTAssertEqual(order, ["peerb", "peerc"])
        XCTAssertNil(cache["peera"])
    }

    func testDeduplicatedOrderKeepingMostRecentRemovesOlderDuplicates() {
        let order = ["peera", "peerb", "peera", "peerc", "peerb"]

        let deduped = UnifiedPeerService.deduplicatedOrderKeepingMostRecent(order)

        XCTAssertEqual(deduped, ["peera", "peerc", "peerb"])
    }

    func testPruneFingerprintCacheDeduplicatesOrderEntries() {
        var cache: [String: String] = [
            "peera": String(repeating: "11", count: 32),
            "peerb": String(repeating: "22", count: 32),
            "peerc": String(repeating: "33", count: 32)
        ]
        var order = ["peera", "peerb", "peera", "peerc"]

        UnifiedPeerService.pruneFingerprintCache(
            &cache,
            order: &order,
            referenceIDs: ["peera", "peerb", "peerc"],
            cap: 10
        )

        XCTAssertEqual(order, ["peerb", "peera", "peerc"])
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

    func testResolvedNoisePublicKeyFallsBackThroughUppercasePrefixedNoiseID() {
        let peerIDNoise = String(repeating: "ef", count: 32)
        let snapshot = TransportPeerSnapshot(
            peerID: PeerID(str: "NOISE:\(peerIDNoise)"),
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

    func testShouldIncludeMeshSnapshotRejectsLocalPeerID() {
        let localPeerID = PeerID(str: "abcdef0123456789")
        let snapshot = TransportPeerSnapshot(
            peerID: localPeerID,
            nickname: "self",
            isConnected: true,
            noisePublicKey: nil,
            lastSeen: Date()
        )

        XCTAssertFalse(UnifiedPeerService.shouldIncludeMeshSnapshot(snapshot, localPeerID: localPeerID))
    }

    func testShouldIncludeMeshSnapshotRejectsEquivalentLocalPeerIDVariant() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let localPeerID = PeerID(str: fullNoiseHex).toShort()
        let snapshot = TransportPeerSnapshot(
            peerID: PeerID(str: fullNoiseHex),
            nickname: "self-variant",
            isConnected: true,
            noisePublicKey: Data(hexString: fullNoiseHex),
            lastSeen: Date()
        )

        XCTAssertFalse(UnifiedPeerService.shouldIncludeMeshSnapshot(snapshot, localPeerID: localPeerID))
    }

    func testShouldIncludeMeshSnapshotRejectsInvalidPeerID() {
        let localPeerID = PeerID(str: "abcdef0123456789")
        let snapshot = TransportPeerSnapshot(
            peerID: PeerID(str: "invalid peer id"),
            nickname: "invalid",
            isConnected: true,
            noisePublicKey: nil,
            lastSeen: Date()
        )

        XCTAssertFalse(UnifiedPeerService.shouldIncludeMeshSnapshot(snapshot, localPeerID: localPeerID))
    }

    func testShouldIncludeMeshSnapshotAcceptsValidRemotePeerID() {
        let localPeerID = PeerID(str: "abcdef0123456789")
        let snapshot = TransportPeerSnapshot(
            peerID: PeerID(str: "0011223344556677"),
            nickname: "remote",
            isConnected: true,
            noisePublicKey: nil,
            lastSeen: Date()
        )

        XCTAssertTrue(UnifiedPeerService.shouldIncludeMeshSnapshot(snapshot, localPeerID: localPeerID))
    }

    func testResolveFingerprintFromMeshChecksLookupKeyVariants() {
        let fingerprint = String(repeating: "a0", count: 32)
        let lookup: [String: String] = ["abcdef0123456789": fingerprint]

        let resolved = UnifiedPeerService.resolveFingerprintFromMesh(
            for: "mesh:ABCDEF0123456789"
        ) { candidate in
            lookup[candidate.id]
        }

        XCTAssertEqual(resolved, fingerprint)
    }

    func testResolveFingerprintFromMeshReturnsNilWhenNoVariantMatches() {
        let resolved = UnifiedPeerService.resolveFingerprintFromMesh(
            for: "mesh:abcdef0123456789"
        ) { _ in
            nil
        }

        XCTAssertNil(resolved)
    }

    func testResolveFingerprintFromMeshKeepsGeoPrefixIsolation() {
        let resolved = UnifiedPeerService.resolveFingerprintFromMesh(
            for: "nostr_abcdef0123456789"
        ) { candidate in
            candidate.id == "abcdef0123456789" ? String(repeating: "b1", count: 32) : nil
        }

        XCTAssertNil(resolved)
    }
}
