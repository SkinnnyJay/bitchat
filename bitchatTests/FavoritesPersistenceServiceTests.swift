import XCTest
@testable import bitchat

final class FavoritesPersistenceServiceTests: XCTestCase {
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
}
