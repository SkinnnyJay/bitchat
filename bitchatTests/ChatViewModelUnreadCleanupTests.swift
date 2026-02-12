import XCTest
@testable import bitchat

final class ChatViewModelUnreadCleanupTests: XCTestCase {
    private func sampleMessage(senderPeerID: String?) -> BitchatMessage {
        BitchatMessage(
            id: UUID().uuidString,
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: "bob",
            senderPeerID: senderPeerID,
            mentions: nil
        )
    }

    func testHasPrivateMessagesReturnsTrueForDirectKeyHit() {
        let message = sampleMessage(senderPeerID: "abcdef0123456789")
        let chats = ["abcdef0123456789": [message]]

        XCTAssertTrue(ChatViewModel.hasPrivateMessages(in: chats, for: "abcdef0123456789"))
    }

    func testHasPrivateMessagesReturnsTrueForEquivalentPrefixedIdentifier() {
        let message = sampleMessage(senderPeerID: "abcdef0123456789")
        let chats = ["mesh:abcdef0123456789": [message]]

        XCTAssertTrue(ChatViewModel.hasPrivateMessages(in: chats, for: "abcdef0123456789"))
        XCTAssertTrue(ChatViewModel.hasPrivateMessages(in: chats, for: "mesh:abcdef0123456789"))
    }

    func testHasPrivateMessagesReturnsTrueForFullNoiseAndShortEquivalence() {
        let fullNoiseID = String(repeating: "ab", count: 32)
        let shortID = PeerID(str: fullNoiseID).toShort().bare
        let message = sampleMessage(senderPeerID: fullNoiseID)
        let chats = [fullNoiseID: [message]]

        XCTAssertTrue(ChatViewModel.hasPrivateMessages(in: chats, for: shortID))
    }

    func testHasPrivateMessagesReturnsFalseForUnknownOrEmptyThreads() {
        let message = sampleMessage(senderPeerID: "abcdef0123456789")
        let chats = [
            "abcdef0123456789": [message],
            "mesh:0011223344556677": []
        ]

        XCTAssertFalse(ChatViewModel.hasPrivateMessages(in: chats, for: "0011223344556677"))
        XCTAssertFalse(ChatViewModel.hasPrivateMessages(in: chats, for: ""))
    }

    func testHasPrivateMessagesDoesNotCrossResolveGeoDMPeerIDToBareMeshID() {
        let message = sampleMessage(senderPeerID: "abcdef0123456789")
        let chats = ["abcdef0123456789": [message]]

        XCTAssertFalse(ChatViewModel.hasPrivateMessages(in: chats, for: "nostr_abcdef0123456789"))
    }

    func testHasPrivateMessagesFindsGeoDMThreadCaseInsensitively() {
        let message = sampleMessage(senderPeerID: "nostr_abcdef0123456789")
        let chats = ["nostr_abcdef0123456789": [message]]

        XCTAssertTrue(ChatViewModel.hasPrivateMessages(in: chats, for: "NOSTR_ABCDEF0123456789"))
    }
}
