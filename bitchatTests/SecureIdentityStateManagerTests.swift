import XCTest
@testable import bitchat

final class SecureIdentityStateManagerTests: XCTestCase {
    func testSanitizedClaimedNicknameKeepsValidValue() {
        XCTAssertEqual(SecureIdentityStateManager.sanitizedClaimedNickname("alice"), "alice")
    }

    func testSanitizedClaimedNicknameFallsBackToUserForInvalidValue() {
        XCTAssertEqual(SecureIdentityStateManager.sanitizedClaimedNickname("   "), "user")
    }

    func testSanitizedClaimedNicknameFallsBackToUserForNilValue() {
        XCTAssertEqual(SecureIdentityStateManager.sanitizedClaimedNickname(nil), "user")
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

    func testUpdatedNicknameIndexAddsFingerprintWhenNoOldNickname() {
        let fingerprint = "fp123"

        let updated = SecureIdentityStateManager.updatedNicknameIndex(
            [:],
            fingerprint: fingerprint,
            oldNickname: nil,
            newNickname: "new"
        )

        XCTAssertEqual(updated["new"], [fingerprint])
    }

    func testCanonicalNostrPubkeyTrimsLowercasesAndValidatesLength() {
        let uppercase = String(repeating: "AB", count: 32)

        let canonical = SecureIdentityStateManager.canonicalNostrPubkey("  \(uppercase)  ")

        XCTAssertEqual(canonical, String(repeating: "ab", count: 32))
    }

    func testCanonicalNostrPubkeyDecodesNpubInput() {
        let hex = String(repeating: "11", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let canonical = SecureIdentityStateManager.canonicalNostrPubkey(npub ?? "")

        XCTAssertEqual(canonical, hex)
    }

    func testCanonicalNostrPubkeyRejectsInvalidInput() {
        XCTAssertNil(SecureIdentityStateManager.canonicalNostrPubkey("abc"))
        XCTAssertNil(SecureIdentityStateManager.canonicalNostrPubkey(String(repeating: "zz", count: 32)))
        XCTAssertNil(SecureIdentityStateManager.canonicalNostrPubkey("npub123"))
    }

    func testApplyingFavoriteMutationSanitizesClaimedNicknameAndUpdatesFavorite() {
        let existing = SocialIdentity(
            fingerprint: "fp1",
            localPetname: nil,
            claimedNickname: "   ",
            trustLevel: .unknown,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )

        let updated = SecureIdentityStateManager.applyingFavoriteMutation(
            existingIdentity: existing,
            fingerprint: "fp1",
            isFavorite: true
        )

        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(updated.claimedNickname, "user")
    }

    func testApplyingBlockedMutationClearsFavoriteWhenBlocking() {
        let existing = SocialIdentity(
            fingerprint: "fp1",
            localPetname: nil,
            claimedNickname: "alice",
            trustLevel: .unknown,
            isFavorite: true,
            isBlocked: false,
            notes: nil
        )

        let updated = SecureIdentityStateManager.applyingBlockedMutation(
            existingIdentity: existing,
            fingerprint: "fp1",
            isBlocked: true
        )

        XCTAssertTrue(updated.isBlocked)
        XCTAssertFalse(updated.isFavorite)
    }

    func testApplyingNostrBlockReportsChangesOnlyWhenSetMutates() {
        let key = String(repeating: "ab", count: 32)

        let added = SecureIdentityStateManager.applyingNostrBlock([], key: key, isBlocked: true)
        XCTAssertTrue(added.changed)
        XCTAssertTrue(added.updated.contains(key))

        let addedAgain = SecureIdentityStateManager.applyingNostrBlock(added.updated, key: key, isBlocked: true)
        XCTAssertFalse(addedAgain.changed)

        let removed = SecureIdentityStateManager.applyingNostrBlock(added.updated, key: key, isBlocked: false)
        XCTAssertTrue(removed.changed)
        XCTAssertFalse(removed.updated.contains(key))
    }

    func testBuildNicknameIndexGroupsFingerprintsByClaimedNickname() {
        let socialIdentities: [String: SocialIdentity] = [
            "fp1": SocialIdentity(
                fingerprint: "fp1",
                localPetname: nil,
                claimedNickname: "alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            ),
            "fp2": SocialIdentity(
                fingerprint: "fp2",
                localPetname: nil,
                claimedNickname: "alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        ]

        let index = SecureIdentityStateManager.buildNicknameIndex(from: socialIdentities)

        XCTAssertEqual(index["alice"], Set(["fp1", "fp2"]))
    }

    func testSanitizedIdentityCacheNormalizesSocialNicknamesAndBlockedNostrKeys() {
        let rawNostrKey = String(repeating: "AB", count: 32)
        var cache = IdentityCache()
        cache.socialIdentities = [
            "fp1": SocialIdentity(
                fingerprint: "fp1",
                localPetname: nil,
                claimedNickname: "   ",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        ]
        cache.blockedNostrPubkeys = [rawNostrKey, "bad-key"]

        let sanitized = SecureIdentityStateManager.sanitizedIdentityCache(cache)

        XCTAssertEqual(sanitized.socialIdentities["fp1"]?.claimedNickname, "user")
        XCTAssertEqual(sanitized.nicknameIndex["user"], Set(["fp1"]))
        XCTAssertEqual(sanitized.blockedNostrPubkeys, [String(repeating: "ab", count: 32)])
    }

    func testSanitizedIdentityCacheUsesDictionaryKeyAsCanonicalFingerprint() {
        var cache = IdentityCache()
        cache.socialIdentities = [
            "fp1": SocialIdentity(
                fingerprint: "other",
                localPetname: nil,
                claimedNickname: "alice",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        ]

        let sanitized = SecureIdentityStateManager.sanitizedIdentityCache(cache)

        XCTAssertEqual(sanitized.socialIdentities["fp1"]?.fingerprint, "fp1")
    }
}
