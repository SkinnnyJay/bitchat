import XCTest
@testable import bitchat

final class ChatViewModelIdentityParsingTests: XCTestCase {
    func testDecodeNoisePublicKeyFromBareHex() {
        let fullNoise = String(repeating: "ab", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: fullNoise)

        XCTAssertEqual(decoded?.count, 32)
        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }

    func testDecodeNoisePublicKeyFromPrefixedNoiseHex() {
        let fullNoise = String(repeating: "cd", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: "noise:\(fullNoise)")

        XCTAssertEqual(decoded?.count, 32)
        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }

    func testDecodeNoisePublicKeyFromPrefixedMeshHex() {
        let fullNoise = String(repeating: "ef", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: "mesh:\(fullNoise)")

        XCTAssertEqual(decoded?.count, 32)
        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }

    func testDecodeNoisePublicKeyRejectsShortRoutingPeerIDs() {
        XCTAssertNil(ChatViewModel.decodeNoisePublicKey(from: "abcdef0123456789"))
    }

    func testDecodeNoisePublicKeyTrimsWhitespace() {
        let fullNoise = String(repeating: "ab", count: 32)

        let decoded = ChatViewModel.decodeNoisePublicKey(from: "  \(fullNoise)  ")

        XCTAssertEqual(decoded?.hexEncodedString(), fullNoise)
    }
}
