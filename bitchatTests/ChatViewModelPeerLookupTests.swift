import XCTest
@testable import bitchat

final class ChatViewModelPeerLookupTests: XCTestCase {
    func testResolvePeerReturnsDirectMatch() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x11, count: 32),
            nickname: "alice"
        )
        let index = ["abcdef0123456789": peer]

        let resolved = ChatViewModel.resolvePeer(from: index, peerID: "abcdef0123456789")

        XCTAssertEqual(resolved, peer)
    }

    func testResolvePeerMatchesPrefixedShortQueryToBareIndexKey() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x22, count: 32),
            nickname: "bob"
        )
        let index = ["abcdef0123456789": peer]

        let resolved = ChatViewModel.resolvePeer(from: index, peerID: "mesh:abcdef0123456789")

        XCTAssertEqual(resolved, peer)
    }

    func testResolvePeerMatchesCaseVariantHexKey() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x33, count: 32),
            nickname: "carol"
        )
        let index = ["ABCDEF0123456789": peer]

        let resolved = ChatViewModel.resolvePeer(from: index, peerID: "abcdef0123456789")

        XCTAssertEqual(resolved, peer)
    }

    func testResolvePeerReturnsNilForEmptyOrUnknownIdentifier() {
        let peer = BitchatPeer(
            peerID: PeerID(str: "abcdef0123456789"),
            noisePublicKey: Data(repeating: 0x44, count: 32),
            nickname: "dave"
        )
        let index = ["abcdef0123456789": peer]

        XCTAssertNil(ChatViewModel.resolvePeer(from: index, peerID: ""))
        XCTAssertNil(ChatViewModel.resolvePeer(from: index, peerID: "unknown-peer"))
    }
}
