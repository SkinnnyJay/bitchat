import XCTest
@testable import bitchat

final class NostrKeyNormalizerTests: XCTestCase {
    func testCanonicalHexAcceptsHexAndLowercases() {
        let uppercaseHex = String(repeating: "AB", count: 32)

        let canonical = NostrKeyNormalizer.canonicalHex(uppercaseHex)

        XCTAssertEqual(canonical, String(repeating: "ab", count: 32))
    }

    func testCanonicalHexDecodesNpubCaseInsensitively() {
        let hex = String(repeating: "11", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let canonical = NostrKeyNormalizer.canonicalHex(npub?.uppercased())

        XCTAssertEqual(canonical, hex)
    }

    func testCanonicalNpubConvertsHexToNpubAndBack() {
        let hex = String(repeating: "22", count: 32)

        let npub = NostrKeyNormalizer.canonicalNpub(hex)
        let decoded = NostrKeyNormalizer.canonicalHex(npub)

        XCTAssertEqual(decoded, hex)
    }

    func testCanonicalHelpersRejectMalformedInput() {
        XCTAssertNil(NostrKeyNormalizer.canonicalHex("npub123"))
        XCTAssertNil(NostrKeyNormalizer.canonicalHex(String(repeating: "zz", count: 32)))
        XCTAssertNil(NostrKeyNormalizer.canonicalNpub("abc"))
        XCTAssertNil(NostrKeyNormalizer.canonicalHex(nil))
    }
}
