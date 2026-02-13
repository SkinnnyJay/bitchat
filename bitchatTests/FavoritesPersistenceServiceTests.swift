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

    func testSanitizedNostrPublicKeyAcceptsValidNpubAndRejectsBlankValues() {
        let npub = try? Bech32.encode(hrp: "npub", data: Data(repeating: 0x11, count: 32))
        XCTAssertEqual(
            FavoritesPersistenceService.sanitizedNostrPublicKey("  \(npub ?? "")  "),
            npub
        )
        XCTAssertEqual(
            FavoritesPersistenceService.sanitizedNostrPublicKey(npub?.uppercased()),
            npub
        )
        XCTAssertNil(FavoritesPersistenceService.sanitizedNostrPublicKey("   "))
    }

    func testSanitizedNostrPublicKeyAcceptsAndLowercasesHexValues() {
        let uppercaseHex = String(repeating: "AB", count: 32)

        XCTAssertEqual(
            FavoritesPersistenceService.sanitizedNostrPublicKey(uppercaseHex),
            String(repeating: "ab", count: 32)
        )
    }

    func testSanitizedNostrPublicKeyRejectsMalformedValues() {
        XCTAssertNil(FavoritesPersistenceService.sanitizedNostrPublicKey("npub123"))
        XCTAssertNil(FavoritesPersistenceService.sanitizedNostrPublicKey(String(repeating: "zz", count: 32)))
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

    func testShouldPersistCleanedRelationshipsDetectsSanitizedValueChanges() {
        let decoded = [
            FavoritesPersistenceService.FavoriteRelationship(
                peerNoisePublicKey: Data(repeating: 0x11, count: 32),
                peerNostrPublicKey: "   ",
                peerNickname: "alice",
                isFavorite: true,
                theyFavoritedUs: false,
                favoritedAt: Date(timeIntervalSince1970: 1),
                lastUpdated: Date(timeIntervalSince1970: 2)
            )
        ]
        let cleaned = [
            FavoritesPersistenceService.FavoriteRelationship(
                peerNoisePublicKey: Data(repeating: 0x11, count: 32),
                peerNostrPublicKey: nil,
                peerNickname: "alice",
                isFavorite: true,
                theyFavoritedUs: false,
                favoritedAt: Date(timeIntervalSince1970: 1),
                lastUpdated: Date(timeIntervalSince1970: 2)
            )
        ]

        XCTAssertTrue(
            FavoritesPersistenceService.shouldPersistCleanedRelationships(
                decoded: decoded,
                cleaned: cleaned
            )
        )
    }

    func testShouldPersistCleanedRelationshipsReturnsFalseWhenUnchanged() {
        let relationships = [
            FavoritesPersistenceService.FavoriteRelationship(
                peerNoisePublicKey: Data(repeating: 0x11, count: 32),
                peerNostrPublicKey: nil,
                peerNickname: "alice",
                isFavorite: true,
                theyFavoritedUs: false,
                favoritedAt: Date(timeIntervalSince1970: 1),
                lastUpdated: Date(timeIntervalSince1970: 2)
            )
        ]

        XCTAssertFalse(
            FavoritesPersistenceService.shouldPersistCleanedRelationships(
                decoded: relationships,
                cleaned: relationships
            )
        )
    }

    func testShouldPreferFavoriteRelationshipPrefersMutualState() {
        let baseDate = Date(timeIntervalSince1970: 10)
        let existing = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 0x11, count: 32),
            peerNostrPublicKey: nil,
            peerNickname: "alice",
            isFavorite: true,
            theyFavoritedUs: false,
            favoritedAt: baseDate,
            lastUpdated: baseDate
        )
        let candidate = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 0x11, count: 32),
            peerNostrPublicKey: nil,
            peerNickname: "alice",
            isFavorite: true,
            theyFavoritedUs: true,
            favoritedAt: baseDate,
            lastUpdated: baseDate
        )

        XCTAssertTrue(FavoritesPersistenceService.shouldPreferFavoriteRelationship(candidate, over: existing))
    }

    func testShouldPreferFavoriteRelationshipPrefersEntryWithNostrKeyWhenStateEqual() {
        let baseDate = Date(timeIntervalSince1970: 10)
        let existing = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 0x11, count: 32),
            peerNostrPublicKey: nil,
            peerNickname: "alice",
            isFavorite: true,
            theyFavoritedUs: false,
            favoritedAt: baseDate,
            lastUpdated: baseDate
        )
        let candidate = FavoritesPersistenceService.FavoriteRelationship(
            peerNoisePublicKey: Data(repeating: 0x11, count: 32),
            peerNostrPublicKey: String(repeating: "ab", count: 32),
            peerNickname: "alice",
            isFavorite: true,
            theyFavoritedUs: false,
            favoritedAt: baseDate,
            lastUpdated: baseDate
        )

        XCTAssertTrue(FavoritesPersistenceService.shouldPreferFavoriteRelationship(candidate, over: existing))
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
