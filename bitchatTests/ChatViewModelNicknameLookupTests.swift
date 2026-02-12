import XCTest
@testable import bitchat

final class ChatViewModelNicknameLookupTests: XCTestCase {
    func testShouldResolveNicknameLookupForHexPeerIDs() {
        XCTAssertTrue(ChatViewModel.shouldResolveNicknameLookup(for: "abcdef0123456789"))
    }

    func testShouldResolveNicknameLookupForPrefixedPeerIDs() {
        XCTAssertTrue(ChatViewModel.shouldResolveNicknameLookup(for: "mesh:abcdef0123456789"))
        XCTAssertTrue(ChatViewModel.shouldResolveNicknameLookup(for: "noise:\(String(repeating: "ab", count: 32))"))
    }

    func testShouldResolveNicknameLookupRejectsPlainNicknames() {
        XCTAssertFalse(ChatViewModel.shouldResolveNicknameLookup(for: "alice"))
        XCTAssertFalse(ChatViewModel.shouldResolveNicknameLookup(for: "bob-123"))
    }

    func testShouldResolveNicknameLookupRejectsBlankInput() {
        XCTAssertFalse(ChatViewModel.shouldResolveNicknameLookup(for: "   "))
    }
}
