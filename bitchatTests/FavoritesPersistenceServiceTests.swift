import XCTest
@testable import bitchat

final class FavoritesPersistenceServiceTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        FavoritesPersistenceService.shared.clearAllFavorites()
    }

    @MainActor
    override func tearDown() {
        FavoritesPersistenceService.shared.clearAllFavorites()
        super.tearDown()
    }

    func testIsValidFavoriteNoisePublicKeyRequires32Bytes() {
        XCTAssertTrue(FavoritesPersistenceService.isValidFavoriteNoisePublicKey(Data(repeating: 0x11, count: 32)))
        XCTAssertFalse(FavoritesPersistenceService.isValidFavoriteNoisePublicKey(Data(repeating: 0x11, count: 8)))
    }

    func testSanitizedPeerNicknameKeepsValidValue() {
        XCTAssertEqual(FavoritesPersistenceService.sanitizedPeerNickname("alice"), "alice")
    }

    func testSanitizedPeerNicknameFallsBackToUserForInvalidValue() {
        XCTAssertEqual(FavoritesPersistenceService.sanitizedPeerNickname("   "), "user")
    }

    func testSanitizedPeerNicknameFallsBackToUserForNilValue() {
        XCTAssertEqual(FavoritesPersistenceService.sanitizedPeerNickname(nil), "user")
    }

    func testSanitizedNostrPublicKeyTrimsAndRejectsBlankValues() {
        XCTAssertEqual(
            FavoritesPersistenceService.sanitizedNostrPublicKey("  npub123  "),
            "npub123"
        )
        XCTAssertNil(FavoritesPersistenceService.sanitizedNostrPublicKey("   "))
    }

    func testSanitizedFavoriteRelationshipRejectsInvalidNoiseKeyLength() {
        let relationship = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 0x11, count: 8),
            peerNostrPublicKey: "npub123",
            peerNickname: "alice",
            isFavorite: true,
            theyFavoritedUs: false,
            favoritedAt: Date(),
            lastUpdated: Date()
        )

        XCTAssertNil(FavoritesPersistenceService.sanitizedFavoriteRelationship(relationship))
    }

    func testSanitizedFavoriteRelationshipCleansNicknameAndNostrKey() {
        let relationship = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 0x11, count: 32),
            peerNostrPublicKey: "   ",
            peerNickname: "   ",
            isFavorite: true,
            theyFavoritedUs: false,
            favoritedAt: Date(),
            lastUpdated: Date()
        )

        let sanitized = FavoritesPersistenceService.sanitizedFavoriteRelationship(relationship)

        XCTAssertEqual(sanitized?.peerNickname, "user")
        XCTAssertNil(sanitized?.peerNostrPublicKey)
    }

    @MainActor
    func testGetFavoriteStatusForPeerIDAcceptsFullNoisePeerID() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let noiseKey = Data(hexString: fullNoiseHex) ?? Data()
        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "alice"
        )

        let resolved = FavoritesPersistenceService.shared.getFavoriteStatus(
            forPeerID: PeerID(str: fullNoiseHex)
        )

        XCTAssertEqual(resolved?.peerNickname, "alice")
    }

    @MainActor
    func testGetFavoriteStatusForPeerIDAcceptsPrefixedShortPeerID() {
        let fullNoiseHex = String(repeating: "ab", count: 32)
        let noiseKey = Data(hexString: fullNoiseHex) ?? Data()
        FavoritesPersistenceService.shared.addFavorite(
            peerNoisePublicKey: noiseKey,
            peerNickname: "alice"
        )

        let resolved = FavoritesPersistenceService.shared.getFavoriteStatus(
            forPeerID: PeerID(str: "mesh:\(PeerID(str: fullNoiseHex).toShort().bare)")
        )

        XCTAssertEqual(resolved?.peerNickname, "alice")
    }
}
