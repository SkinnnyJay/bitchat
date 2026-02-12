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

        UnifiedPeerService.cacheFingerprint(
            "fp-test",
            for: "mesh:ABCDEF0123456789",
            in: &cache
        )

        XCTAssertEqual(cache["mesh:ABCDEF0123456789"], "fp-test")
        XCTAssertEqual(cache["mesh:abcdef0123456789"], "fp-test")
        XCTAssertEqual(cache["abcdef0123456789"], "fp-test")
    }

    func testCacheFingerprintKeepsGeoPrefixIsolation() {
        var cache: [String: String] = [:]

        UnifiedPeerService.cacheFingerprint(
            "fp-geo",
            for: "nostr_abcdef0123456789",
            in: &cache
        )

        XCTAssertEqual(cache["nostr_abcdef0123456789"], "fp-geo")
        XCTAssertNil(cache["abcdef0123456789"])
    }

    func testCacheFingerprintCappedEvictsOldestKeysWhenCapExceeded() {
        var cache: [String: String] = [:]
        var order: [String] = []

        UnifiedPeerService.cacheFingerprint("fp-a", for: "peera", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint("fp-b", for: "peerb", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint("fp-c", for: "peerc", in: &cache, order: &order, cap: 2)

        XCTAssertEqual(order, ["peerb", "peerc"])
        XCTAssertNil(cache["peera"])
        XCTAssertEqual(cache["peerb"], "fp-b")
        XCTAssertEqual(cache["peerc"], "fp-c")
    }

    func testCacheFingerprintCappedRefreshesExistingKeyRecency() {
        var cache: [String: String] = [:]
        var order: [String] = []

        UnifiedPeerService.cacheFingerprint("fp-a", for: "peera", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint("fp-b", for: "peerb", in: &cache, order: &order, cap: 2)
        UnifiedPeerService.cacheFingerprint("fp-a2", for: "peera", in: &cache, order: &order, cap: 2)

        XCTAssertEqual(order, ["peerb", "peera"])
        XCTAssertEqual(cache["peera"], "fp-a2")
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
            "peera": "fp-a",
            "peerb": "fp-b"
        ]
        var order = ["peera", "peerb"]

        UnifiedPeerService.pruneFingerprintCache(
            &cache,
            order: &order,
            referenceIDs: ["peera"],
            cap: 10
        )

        XCTAssertEqual(cache, ["peera": "fp-a"])
        XCTAssertEqual(order, ["peera"])
    }

    func testPruneFingerprintCacheHonorsCapAfterFiltering() {
        var cache: [String: String] = [
            "peera": "fp-a",
            "peerb": "fp-b",
            "peerc": "fp-c"
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

    func testResolveFingerprintFromMeshChecksLookupKeyVariants() {
        let lookup: [String: String] = ["abcdef0123456789": "fp-lookup"]

        let resolved = UnifiedPeerService.resolveFingerprintFromMesh(
            for: "mesh:ABCDEF0123456789"
        ) { candidate in
            lookup[candidate.id]
        }

        XCTAssertEqual(resolved, "fp-lookup")
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
            candidate.id == "abcdef0123456789" ? "fp-bare" : nil
        }

        XCTAssertNil(resolved)
    }
}
