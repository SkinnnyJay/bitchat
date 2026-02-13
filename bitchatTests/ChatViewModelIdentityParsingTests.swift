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

    func testSanitizedFavoriteNotificationNostrPubkeyTrimsAndRejectsBlank() {
        XCTAssertEqual(
            ChatViewModel.sanitizedFavoriteNotificationNostrPubkey("  npub123  "),
            "npub123"
        )
        XCTAssertNil(ChatViewModel.sanitizedFavoriteNotificationNostrPubkey("   "))
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
    }

    func testCanonicalNostrPubkeyHexRejectsInvalidInput() {
        XCTAssertNil(ChatViewModel.canonicalNostrPubkeyHex("npub123"))
        XCTAssertNil(ChatViewModel.canonicalNostrPubkeyHex(String(repeating: "zz", count: 32)))
    }
}
