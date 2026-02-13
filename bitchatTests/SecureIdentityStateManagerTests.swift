import XCTest
@testable import bitchat

final class SecureIdentityStateManagerTests: XCTestCase {
    func testSanitizedClaimedNicknameKeepsValidValue() {
        XCTAssertEqual(SecureIdentityStateManager.sanitizedClaimedNickname("alice"), "alice")
    }

    func testSanitizedClaimedNicknameFallsBackToUserForInvalidValue() {
        XCTAssertEqual(SecureIdentityStateManager.sanitizedClaimedNickname("   "), "user")
    }

    func testUpdatedNicknameIndexMovesFingerprintBetweenNicknames() {
        let fingerprint = "fp123"
        let index: [String: Set<String>] = [
            "old": [fingerprint]
        ]

        let updated = SecureIdentityStateManager.updatedNicknameIndex(
            index,
            fingerprint: fingerprint,
            oldNickname: "old",
            newNickname: "new"
        )

        XCTAssertFalse(updated["old"]?.contains(fingerprint) ?? false)
        XCTAssertTrue(updated["new"]?.contains(fingerprint) ?? false)
    }

    func testUpdatedNicknameIndexKeepsExistingNicknameWhenUnchanged() {
        let fingerprint = "fp123"
        let index: [String: Set<String>] = [
            "same": [fingerprint]
        ]

        let updated = SecureIdentityStateManager.updatedNicknameIndex(
            index,
            fingerprint: fingerprint,
            oldNickname: "same",
            newNickname: "same"
        )

        XCTAssertEqual(updated["same"], [fingerprint])
    }
}
