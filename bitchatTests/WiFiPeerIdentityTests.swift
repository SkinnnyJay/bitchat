import XCTest
@testable import bitchat

final class WiFiPeerIdentityTests: XCTestCase {
    func testNormalizedKeyUsesShortFingerprintForFullNoiseKey() {
        let noiseKey = Data(repeating: 0x41, count: 32)
        let full = PeerID(hexData: noiseKey).id
        let short = PeerID(publicKey: noiseKey).id
        XCTAssertEqual(WiFiPeerIdentity.normalizedKey(full), short)
    }

    func testNormalizedKeyTrimsWhitespace() {
        XCTAssertEqual(
            WiFiPeerIdentity.normalizedKey("  peerabc000000000  "),
            "peerabc000000000"
        )
        XCTAssertEqual(WiFiPeerIdentity.normalizedKey("   "), "")
    }

    func testNormalizedKeyStripsPrefixFromCanonicalIdentity() {
        XCTAssertEqual(
            WiFiPeerIdentity.normalizedKey("mesh:peerabc000000000"),
            "peerabc000000000"
        )
        XCTAssertEqual(
            WiFiPeerIdentity.normalizedKey("name:   peerabc000000000   "),
            "peerabc000000000"
        )
    }

    func testNormalizedKeyConvertsPrefixedFullNoiseIDToShortFingerprint() {
        let noiseKey = Data(repeating: 0x44, count: 32)
        let fullNoise = noiseKey.hexEncodedString()
        let expectedShort = PeerID(publicKey: noiseKey).id

        XCTAssertEqual(
            WiFiPeerIdentity.normalizedKey("mesh:\(fullNoise)"),
            expectedShort
        )
    }

    func testNormalizedKeyLowercasesPrefixedShortHexValues() {
        XCTAssertEqual(
            WiFiPeerIdentity.normalizedKey("mesh:ABCDEF0123456789"),
            "abcdef0123456789"
        )
    }

    func testIsEquivalentMatchesFullAndShortNoiseIDs() {
        let noiseKey = Data(repeating: 0x22, count: 32)
        let full = PeerID(hexData: noiseKey).id
        let short = PeerID(publicKey: noiseKey).id
        XCTAssertTrue(WiFiPeerIdentity.isEquivalent(full, short))
        XCTAssertTrue(WiFiPeerIdentity.isEquivalent(short, full))
    }

    func testCandidateIDsIncludePrefixedBareAndShortVariants() {
        let prefixed = PeerID(str: "mesh:peerabc000000000")
        let candidates = WiFiPeerIdentity.candidateIDs(for: prefixed)
        XCTAssertTrue(candidates.contains("mesh:peerabc000000000"))
        XCTAssertTrue(candidates.contains("peerabc000000000"))
    }

    func testCandidateIDsTrimWhitespaceFromPrefixedBarePeerID() {
        let prefixed = PeerID(str: "mesh:   peerabc000000000   ")
        let candidates = WiFiPeerIdentity.candidateIDs(for: prefixed)
        XCTAssertTrue(candidates.contains("mesh:peerabc000000000"))
        XCTAssertTrue(candidates.contains("peerabc000000000"))
    }

    func testCandidateIDsDropBlankVariants() {
        let prefixedBlank = PeerID(str: "mesh:   ")
        let candidates = WiFiPeerIdentity.candidateIDs(for: prefixedBlank)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testCandidateIDsAreUnique() {
        let short = PeerID(str: "peerabc000000000")
        let candidates = WiFiPeerIdentity.candidateIDs(for: short)
        XCTAssertEqual(Set(candidates).count, candidates.count)
    }

    func testCandidateIDsForFullNoiseKeyIncludeFullAndShortForms() {
        let noiseKey = Data(repeating: 0x63, count: 32)
        let full = PeerID(hexData: noiseKey)
        let short = PeerID(publicKey: noiseKey)
        let candidates = WiFiPeerIdentity.candidateIDs(for: full)

        XCTAssertTrue(candidates.contains(full.id))
        XCTAssertTrue(candidates.contains(short.id))
    }

    func testIsEquivalentMatchesPrefixedAndBarePeerIDs() {
        XCTAssertTrue(WiFiPeerIdentity.isEquivalent("mesh:peerabc000000000", "peerabc000000000"))
        XCTAssertTrue(WiFiPeerIdentity.isEquivalent("name:peerabc000000000", "peerabc000000000"))
    }

    func testIsEquivalentTreatsHexPeerIDsCaseInsensitively() {
        XCTAssertTrue(WiFiPeerIdentity.isEquivalent("mesh:ABCDEF0123456789", "abcdef0123456789"))
        XCTAssertTrue(WiFiPeerIdentity.isEquivalent("ABCDEF0123456789", "abcdef0123456789"))
    }

    func testNormalizedKeyPreservesGeoDMPrefix() {
        XCTAssertEqual(
            WiFiPeerIdentity.normalizedKey("NOSTR_ABCDEF0123456789"),
            "nostr_abcdef0123456789"
        )
    }

    func testIsEquivalentDoesNotMixGeoDMPrefixWithBareMeshID() {
        XCTAssertFalse(WiFiPeerIdentity.isEquivalent("nostr_abcdef0123456789", "abcdef0123456789"))
    }

    func testIsEquivalentRejectsEmptyOrWhitespacePeerIDs() {
        XCTAssertFalse(WiFiPeerIdentity.isEquivalent("", "peerabc000000000"))
        XCTAssertFalse(WiFiPeerIdentity.isEquivalent("peerabc000000000", ""))
        XCTAssertFalse(WiFiPeerIdentity.isEquivalent("   ", "peerabc000000000"))
        XCTAssertFalse(WiFiPeerIdentity.isEquivalent("peerabc000000000", "   "))
    }

    func testNormalizedOutboxPeerIDUsesShortForFullNoiseKey() {
        let noiseKey = Data(repeating: 0x7F, count: 32)
        let full = PeerID(hexData: noiseKey)
        let normalized = WiFiPeerIdentity.normalizedOutboxPeerID(for: full)
        XCTAssertEqual(normalized, PeerID(publicKey: noiseKey))
    }

    func testNormalizedOutboxPeerIDStripsPrefixes() {
        let prefixed = PeerID(str: "mesh:peerabc000000000")
        let normalized = WiFiPeerIdentity.normalizedOutboxPeerID(for: prefixed)
        XCTAssertEqual(normalized, PeerID(str: "peerabc000000000"))
    }

    func testNormalizedOutboxPeerIDTrimsWhitespaceAfterPrefix() {
        let prefixed = PeerID(str: "mesh:   peerabc000000000   ")
        let normalized = WiFiPeerIdentity.normalizedOutboxPeerID(for: prefixed)
        XCTAssertEqual(normalized, PeerID(str: "peerabc000000000"))
    }

    func testNormalizedOutboxPeerIDTrimsWhitespaceForUnprefixedPeerID() {
        let unprefixed = PeerID(str: "   peerabc000000000   ")
        let normalized = WiFiPeerIdentity.normalizedOutboxPeerID(for: unprefixed)
        XCTAssertEqual(normalized, PeerID(str: "peerabc000000000"))
    }

    func testCandidateIDsForGeoDMPeerIDDoNotIncludeBareVariant() {
        let geoDM = PeerID(str: "nostr_abcdef0123456789")
        let candidates = WiFiPeerIdentity.candidateIDs(for: geoDM)

        XCTAssertEqual(candidates, ["nostr_abcdef0123456789"])
    }

    func testNormalizedOutboxPeerIDPreservesGeoDMPrefix() {
        let geoDM = PeerID(str: "nostr_abcdef0123456789")
        let normalized = WiFiPeerIdentity.normalizedOutboxPeerID(for: geoDM)

        XCTAssertEqual(normalized, geoDM)
    }

    func testLookupKeysIncludeMeshAndBareVariantsCaseInsensitively() {
        let keys = WiFiPeerIdentity.lookupKeys(for: "mesh:ABCDEF0123456789")

        XCTAssertTrue(keys.contains("mesh:ABCDEF0123456789"))
        XCTAssertTrue(keys.contains("mesh:abcdef0123456789"))
        XCTAssertTrue(keys.contains("ABCDEF0123456789"))
        XCTAssertTrue(keys.contains("abcdef0123456789"))
    }

    func testLookupKeysForGeoDMPeerIDPreservePrefixOnly() {
        let keys = WiFiPeerIdentity.lookupKeys(for: "NOSTR_ABCDEF0123456789")

        XCTAssertEqual(keys, ["NOSTR_ABCDEF0123456789", "nostr_abcdef0123456789"])
    }
}
