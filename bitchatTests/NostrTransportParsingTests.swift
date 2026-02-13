import XCTest
@testable import bitchat

final class NostrTransportParsingTests: XCTestCase {
    func testCanonicalRecipientHexAcceptsHexAndLowercases() {
        let uppercaseHex = String(repeating: "AB", count: 32)

        let canonical = NostrTransport.canonicalRecipientHex(from: uppercaseHex)

        XCTAssertEqual(canonical, String(repeating: "ab", count: 32))
    }

    func testCanonicalRecipientHexDecodesNpubCaseInsensitively() {
        let hex = String(repeating: "11", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let canonicalLower = NostrTransport.canonicalRecipientHex(from: npub ?? "")
        let canonicalUpper = NostrTransport.canonicalRecipientHex(from: npub?.uppercased() ?? "")

        XCTAssertEqual(canonicalLower, hex)
        XCTAssertEqual(canonicalUpper, hex)
    }

    func testCanonicalRecipientNpubConvertsHexToNpub() {
        let hex = String(repeating: "22", count: 32)

        let npub = NostrTransport.canonicalRecipientNpub(from: hex)
        let decodedHex = npub.flatMap(NostrTransport.canonicalRecipientHex(from:))

        XCTAssertEqual(decodedHex, hex)
    }

    func testCanonicalRecipientNpubAcceptsAndNormalizesNpubInput() {
        let hex = String(repeating: "33", count: 32)
        let npub = try? Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())

        let canonical = NostrTransport.canonicalRecipientNpub(from: npub?.uppercased() ?? "")
        let decodedHex = canonical.flatMap(NostrTransport.canonicalRecipientHex(from:))

        XCTAssertEqual(decodedHex, hex)
    }

    func testCanonicalRecipientHelpersRejectMalformedInput() {
        XCTAssertNil(NostrTransport.canonicalRecipientHex(from: "npub123"))
        XCTAssertNil(NostrTransport.canonicalRecipientHex(from: String(repeating: "zz", count: 32)))
        XCTAssertNil(NostrTransport.canonicalRecipientNpub(from: "npub123"))
        XCTAssertNil(NostrTransport.canonicalRecipientNpub(from: "abc"))
    }
}
