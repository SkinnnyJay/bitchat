import XCTest
@testable import bitchat

final class WiFiPeerIdentityTests: XCTestCase {
    func testNormalizedKeyUsesShortFingerprintForFullNoiseKey() {
        let noiseKey = Data(repeating: 0x41, count: 32)
        let full = PeerID(hexData: noiseKey).id
        let short = PeerID(publicKey: noiseKey).id
        XCTAssertEqual(WiFiPeerIdentity.normalizedKey(full), short)
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

    func testCandidateIDsAreUnique() {
        let short = PeerID(str: "peerabc000000000")
        let candidates = WiFiPeerIdentity.candidateIDs(for: short)
        XCTAssertEqual(Set(candidates).count, candidates.count)
    }
}
