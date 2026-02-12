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
}
