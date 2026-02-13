import XCTest
@testable import bitchat

final class ChatViewModelIdentityParsingTests: XCTestCase {
    func testDecodeNoisePublicKeyFromBareHex() {
        let fullNoise = String(repeating: "ab", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: fullNoise)

        XCTAssertEqual(decoded?.count, 32)
        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }

    func testDecodeNoisePublicKeyFromPrefixedNoiseHex() {
        let fullNoise = String(repeating: "cd", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: "noise:\(fullNoise)")

        XCTAssertEqual(decoded?.count, 32)
        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }

    func testDecodeNoisePublicKeyFromPrefixedMeshHex() {
        let fullNoise = String(repeating: "ef", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: "mesh:\(fullNoise)")

        XCTAssertEqual(decoded?.count, 32)
        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }

    func testDecodeNoisePublicKeyRejectsShortRoutingPeerIDs() {
        XCTAssertNil(ChatViewModel.decodeNoisePublicKey(from: "abcdef0123456789"))
    }

    func testDecodeNoisePublicKeyTrimsWhitespace() {
        let fullNoise = String(repeating: "ab", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: "  \(fullNoise)  ")

        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }

    func testValidatedNoisePublicKeyAcceptsOnly32ByteKeys() {
        let validKey = Data(repeating: 0x11, count: 32)
        let invalidKey = Data(repeating: 0x22, count: 8)

        XCTAssertEqual(ChatViewModel.validatedNoisePublicKey(validKey), validKey)
        XCTAssertNil(ChatViewModel.validatedNoisePublicKey(invalidKey))
        XCTAssertNil(ChatViewModel.validatedNoisePublicKey(nil))
    }

    func testResolvedFavoriteNotificationPeerIDPrefersResolvedPeerVariant() {
        let resolvedPeer = BitchatPeer(
            peerID: PeerID(str: "mesh:abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "peer"
        )

        let resolved = ChatViewModel.resolvedFavoriteNotificationPeerID(
            from: "abcdef0123456789",
            resolvedPeer: resolvedPeer
        )

        XCTAssertEqual(resolved?.id, "mesh:abcdef0123456789")
    }

    func testResolvedFavoriteNotificationPeerIDRejectsInvalidInput() {
        let resolved = ChatViewModel.resolvedFavoriteNotificationPeerID(
            from: "   ",
            resolvedPeer: nil
        )

        XCTAssertNil(resolved)
    }

    func testResolvedFavoriteNotificationNoisePublicKeyUsesResolvedPeerIDDecode() {
        let fullNoise = String(repeating: "ab", count: 32)
        let resolvedPeer = BitchatPeer(
            peerID: PeerID(str: "noise:\(fullNoise)"),
            noisePublicKey: Data(),
            nickname: "peer"
        )

        let resolved = ChatViewModel.resolvedFavoriteNotificationNoisePublicKey(
            from: "abcdef0123456789",
            resolvedPeer: resolvedPeer
        )

        XCTAssertEqual(resolved?.hexEncodedString(), fullNoise)
    }

    func testResolvedFavoriteNotificationNoisePublicKeyFallsBackToValidatedPeerKey() {
        let expected = Data(repeating: 0x22, count: 32)
        let resolvedPeer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: expected,
            nickname: "peer"
        )

        let resolved = ChatViewModel.resolvedFavoriteNotificationNoisePublicKey(
            from: "abcdef0123456789",
            resolvedPeer: resolvedPeer
        )

        XCTAssertEqual(resolved, expected)
    }

    func testFavoriteNicknameForPersistencePrefersSanitizedNickname() {
        XCTAssertEqual(
            ChatViewModel.favoriteNicknameForPersistence(
                preferredNickname: "alice",
                fallbackNickname: "fallback"
            ),
            "alice"
        )
    }

    func testFavoriteNicknameForPersistenceFallsBackWhenPreferredInvalid() {
        XCTAssertEqual(
            ChatViewModel.favoriteNicknameForPersistence(
                preferredNickname: "   ",
                fallbackNickname: "fallback"
            ),
            "fallback"
        )
    }

    func testFavoriteNicknameForPersistenceDefaultsToUserWhenBothInvalid() {
        XCTAssertEqual(
            ChatViewModel.favoriteNicknameForPersistence(
                preferredNickname: "   ",
                fallbackNickname: "   "
            ),
            "user"
        )
    }

    func testSanitizedFavoriteNotificationSenderNicknameFallsBackToUser() {
        XCTAssertEqual(ChatViewModel.sanitizedFavoriteNotificationSenderNickname("   "), "user")
    }

    func testSanitizedFavoriteNotificationNostrPubkeyAcceptsValidNpubAndRejectsBlank() {
        let npub = try? Bech32.encode(hrp: "npub", data: Data(repeating: 0x11, count: 32))
        XCTAssertEqual(
            ChatViewModel.sanitizedFavoriteNotificationNostrPubkey("  \(npub ?? "")  "),
            npub
        )
        XCTAssertNil(ChatViewModel.sanitizedFavoriteNotificationNostrPubkey("   "))
        XCTAssertNil(ChatViewModel.sanitizedFavoriteNotificationNostrPubkey("npub123"))
    }

    func testCanonicalNostrPubkeyHexAcceptsAndLowercasesHexInput() {
        let uppercaseHex = String(repeating: "AB", count: 32)

        let canonical = ChatViewModel.canonicalNostrPubkeyHex(uppercaseHex)

        XCTAssertEqual(canonical, String(repeating: "ab", count: 32))
    }

    func testCanonicalNostrPubkeyHexDecodesNpubInput() {
        let hex = String(repeating: "11", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let canonical = ChatViewModel.canonicalNostrPubkeyHex(npub ?? "")

        XCTAssertEqual(canonical, hex)
        XCTAssertEqual(ChatViewModel.canonicalNostrPubkeyHex(npub?.uppercased() ?? ""), hex)
    }

    func testCanonicalNostrPubkeyHexRejectsInvalidInput() {
        XCTAssertNil(ChatViewModel.canonicalNostrPubkeyHex("npub123"))
        XCTAssertNil(ChatViewModel.canonicalNostrPubkeyHex(String(repeating: "zz", count: 32)))
    }

    func testFavoriteNotificationStateParsesFavoriteFormats() {
        XCTAssertEqual(ChatViewModel.favoriteNotificationState(from: "[FAVORITED]:npub..."), true)
        XCTAssertEqual(ChatViewModel.favoriteNotificationState(from: "FAVORITED"), true)
    }

    func testFavoriteNotificationStateParsesUnfavoriteFormats() {
        XCTAssertEqual(ChatViewModel.favoriteNotificationState(from: "[UNFAVORITED]:npub..."), false)
        XCTAssertEqual(ChatViewModel.favoriteNotificationState(from: "UNFAVORITED"), false)
    }

    func testFavoriteNotificationStateRejectsUnknownContent() {
        XCTAssertNil(ChatViewModel.favoriteNotificationState(from: "hello"))
    }

    func testResolveFavoriteNotificationSourcePrefersMeshWhenNoiseKeyAvailable() {
        let source = ChatViewModel.resolveFavoriteNotificationSource(
            content: "[FAVORITED]:npub...",
            actualSenderNoiseKey: Data(repeating: 0x11, count: 32),
            senderPubkey: String(repeating: "ab", count: 32)
        )

        XCTAssertEqual(source, .mesh(noiseKeyHex: String(repeating: "11", count: 32)))
    }

    func testResolveFavoriteNotificationSourceFallsBackToNostrPubkey() {
        let hex = String(repeating: "ab", count: 32)

        let source = ChatViewModel.resolveFavoriteNotificationSource(
            content: "[UNFAVORITED]:npub...",
            actualSenderNoiseKey: nil,
            senderPubkey: hex.uppercased()
        )

        XCTAssertEqual(source, .nostr(nostrPubkeyHex: hex))
    }

    func testResolveFavoriteNotificationSourceRejectsNonNotificationContent() {
        let source = ChatViewModel.resolveFavoriteNotificationSource(
            content: "hello",
            actualSenderNoiseKey: Data(repeating: 0x11, count: 32),
            senderPubkey: String(repeating: "ab", count: 32)
        )

        XCTAssertNil(source)
    }

    func testGeohashConversationKeyUsesCanonicalNostrPubkey() {
        let hex = String(repeating: "ab", count: 32)

        let key = ChatViewModel.geohashConversationKey(for: hex.uppercased())

        XCTAssertEqual(key, "nostr_" + String(hex.prefix(TransportConfig.nostrConvKeyPrefixLength)))
    }

    func testGeohashConversationKeyAcceptsNpubInput() {
        let hex = String(repeating: "11", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let key = ChatViewModel.geohashConversationKey(for: npub?.uppercased() ?? "")

        XCTAssertEqual(key, "nostr_" + String(hex.prefix(TransportConfig.nostrConvKeyPrefixLength)))
    }

    func testGeohashShortMappingKeyRejectsInvalidInput() {
        XCTAssertNil(ChatViewModel.geohashShortMappingKey(for: "invalid"))
    }

    func testGeohashShortMappingKeyAcceptsNpubInput() {
        let hex = String(repeating: "22", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let key = ChatViewModel.geohashShortMappingKey(for: npub?.uppercased() ?? "")

        XCTAssertEqual(key, "nostr:" + String(hex.prefix(TransportConfig.nostrShortKeyDisplayLength)))
    }

    func testNostrDisplaySuffixUsesCanonicalizedNostrKeyWhenAvailable() {
        let hex = String(repeating: "ab", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let suffix = ChatViewModel.nostrDisplaySuffix(from: npub?.uppercased() ?? "")

        XCTAssertEqual(suffix, String(hex.suffix(4)))
    }

    func testNostrDisplaySuffixFallsBackToRawInputWhenInvalid() {
        XCTAssertEqual(ChatViewModel.nostrDisplaySuffix(from: "xyz"), "xyz")
    }

    func testNostrConversationPeerIDPrefersValidatedNoiseKey() {
        let noiseKey = Data(repeating: 0x22, count: 32)

        let conversationPeerID = ChatViewModel.nostrConversationPeerID(
            actualSenderNoiseKey: noiseKey,
            senderPubkey: "invalid"
        )

        XCTAssertEqual(conversationPeerID, noiseKey.hexEncodedString())
    }

    func testNostrConversationPeerIDFallsBackToCanonicalNostrKey() {
        let hex = String(repeating: "ab", count: 32)

        let conversationPeerID = ChatViewModel.nostrConversationPeerID(
            actualSenderNoiseKey: nil,
            senderPubkey: hex.uppercased()
        )

        XCTAssertEqual(
            conversationPeerID,
            "nostr_" + String(hex.prefix(TransportConfig.nostrConvKeyPrefixLength))
        )
    }

    func testNostrConversationPeerIDRejectsInvalidFallbackSenderPubkey() {
        XCTAssertNil(
            ChatViewModel.nostrConversationPeerID(
                actualSenderNoiseKey: nil,
                senderPubkey: "invalid"
            )
        )
    }

    func testValidatedMessageIDFromPayloadDataAcceptsCanonicalValue() {
        let messageID = "msg_123"

        let validated = ChatViewModel.validatedMessageID(from: Data(messageID.utf8))

        XCTAssertEqual(validated, messageID)
    }

    func testValidatedMessageIDFromPayloadDataRejectsInvalidValue() {
        XCTAssertNil(ChatViewModel.validatedMessageID(from: Data("  msg ".utf8)))
        XCTAssertNil(ChatViewModel.validatedMessageID(from: Data([0xFF, 0xFE])))
    }

    func testMatchesNostrSenderPubkeyAcceptsStoredCanonicalHex() {
        let senderHex = String(repeating: "ab", count: 32)
        XCTAssertTrue(
            ChatViewModel.matchesNostrSenderPubkey(
                storedNostrKey: senderHex.uppercased(),
                senderCanonicalHex: senderHex
            )
        )
    }

    func testMatchesNostrSenderPubkeyAcceptsStoredNpub() {
        let senderHex = String(repeating: "11", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: senderHex) ?? Data())

        XCTAssertTrue(
            ChatViewModel.matchesNostrSenderPubkey(
                storedNostrKey: npub,
                senderCanonicalHex: senderHex
            )
        )
    }

    func testMatchesNostrSenderPubkeyRejectsInvalidOrMismatchedValues() {
        let senderHex = String(repeating: "ab", count: 32)
        let otherHex = String(repeating: "cd", count: 32)

        XCTAssertFalse(
            ChatViewModel.matchesNostrSenderPubkey(
                storedNostrKey: "npub123",
                senderCanonicalHex: senderHex
            )
        )
        XCTAssertFalse(
            ChatViewModel.matchesNostrSenderPubkey(
                storedNostrKey: otherHex,
                senderCanonicalHex: senderHex
            )
        )
    }

    func testIsRecipientForLocalPeerAcceptsNilRecipientForBroadcastCompatibility() {
        XCTAssertTrue(
            ChatViewModel.isRecipientForLocalPeer(
                nil,
                localPeerID: "abcdef0123456789"
            )
        )
    }

    func testIsRecipientForLocalPeerMatchesEquivalentRecipientID() {
        let localPeerID = "mesh:abcdef0123456789"
        let recipientIDData = Data(hexString: "abcdef0123456789")

        XCTAssertTrue(
            ChatViewModel.isRecipientForLocalPeer(
                recipientIDData,
                localPeerID: localPeerID
            )
        )
    }

    func testIsRecipientForLocalPeerRejectsInvalidRecipientLengthOrMismatch() {
        XCTAssertFalse(
            ChatViewModel.isRecipientForLocalPeer(
                Data(repeating: 0x11, count: 4),
                localPeerID: "abcdef0123456789"
            )
        )
        XCTAssertFalse(
            ChatViewModel.isRecipientForLocalPeer(
                Data(hexString: "0011223344556677"),
                localPeerID: "abcdef0123456789"
            )
        )
    }

    func testNormalizedNostrSenderRateKeyUsesMappedCanonicalHex() {
        let hex = String(repeating: "ab", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let normalized = ChatViewModel.normalizedNostrSenderRateKey(
            senderPeerID: "nostr_0011",
            mappedFullKey: npub
        )

        XCTAssertEqual(normalized, "nostr:\(hex)")
    }

    func testNormalizedNostrSenderRateKeyFallsBackToBareSenderIDWhenUnmapped() {
        let normalized = ChatViewModel.normalizedNostrSenderRateKey(
            senderPeerID: "nostr_abcdef0123456789",
            mappedFullKey: nil
        )

        XCTAssertEqual(normalized, "nostr:abcdef0123456789")
    }

    func testNormalizedNostrSenderRateKeyLowercasesInvalidUncanonicalizedSource() {
        let normalized = ChatViewModel.normalizedNostrSenderRateKey(
            senderPeerID: "nostr:ABC_DEF",
            mappedFullKey: nil
        )

        XCTAssertEqual(normalized, "nostr:abc_def")
    }

    func testResolvedBlockedNostrPubkeyPrefersCanonicalMappedValue() {
        let hex = String(repeating: "ab", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let resolved = ChatViewModel.resolvedBlockedNostrPubkey(
            senderPeerID: "nostr_\(String(hex.prefix(16)))",
            nostrKeyMapping: ["nostr_\(String(hex.prefix(16)))": npub ?? ""]
        )

        XCTAssertEqual(resolved, hex)
    }

    func testResolvedBlockedNostrPubkeyFallsBackToSenderPeerIDCanonicalization() {
        let hex = String(repeating: "11", count: 32)

        let resolved = ChatViewModel.resolvedBlockedNostrPubkey(
            senderPeerID: "nostr:\(hex.uppercased())",
            nostrKeyMapping: [:]
        )

        XCTAssertEqual(resolved, hex)
    }

    func testResolvedBlockedNostrPubkeyRejectsUnknownOrInvalidSenderIdentifiers() {
        XCTAssertNil(
            ChatViewModel.resolvedBlockedNostrPubkey(
                senderPeerID: "mesh:abcdef0123456789",
                nostrKeyMapping: [:]
            )
        )
        XCTAssertNil(
            ChatViewModel.resolvedBlockedNostrPubkey(
                senderPeerID: "nostr_abcdef0123456789",
                nostrKeyMapping: [:]
            )
        )
    }
}
