import XCTest
@testable import bitchat

final class FingerprintNormalizerTests: XCTestCase {
    func testCanonicalNormalizesCaseAndWhitespace() {
        let uppercase = String(repeating: "AB", count: 32)

        let canonical = FingerprintNormalizer.canonical("  \(uppercase)  ")

        XCTAssertEqual(canonical, String(repeating: "ab", count: 32))
    }

    func testCanonicalRejectsInvalidValues() {
        XCTAssertNil(FingerprintNormalizer.canonical(nil))
        XCTAssertNil(FingerprintNormalizer.canonical("abc"))
        XCTAssertNil(FingerprintNormalizer.canonical(String(repeating: "zz", count: 32)))
    }
}
