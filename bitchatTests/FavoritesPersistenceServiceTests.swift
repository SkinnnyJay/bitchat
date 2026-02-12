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
}
