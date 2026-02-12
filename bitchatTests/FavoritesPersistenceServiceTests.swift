import XCTest
@testable import bitchat

final class FavoritesPersistenceServiceTests: XCTestCase {
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
