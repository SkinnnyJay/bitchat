import XCTest
@testable import bitchat

final class BitchatMessageTests: XCTestCase {
    func testInitializerKeepsValidProvidedMessageID() {
        let message = BitchatMessage(
            id: "mid-valid-123",
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false
        )

        XCTAssertEqual(message.id, "mid-valid-123")
    }

    func testInitializerRegeneratesIDForInvalidProvidedMessageID() {
        let invalidID = "mid invalid whitespace"
        let message = BitchatMessage(
            id: invalidID,
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false
        )

        XCTAssertNotEqual(message.id, invalidID)
        XCTAssertNotNil(InputValidator.validateMessageID(message.id))
    }

    func testInitializerGeneratesValidIDWhenMissing() {
        let message = BitchatMessage(
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false
        )

        XCTAssertNotNil(InputValidator.validateMessageID(message.id))
    }

    func testBinaryDecodeDropsInvalidSenderPeerID() {
        let message = BitchatMessage(
            id: "mid-binary",
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "bob",
            senderPeerID: PeerID(str: "invalid peer id")
        )

        let payload = message.toBinaryPayload()
        let decoded = payload.flatMap(BitchatMessage.init)

        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.senderPeerID)
    }

    func testBinaryDecodeSanitizesSenderRecipientAndMentions() {
        let message = BitchatMessage(
            id: "mid-sanitize",
            sender: "   ",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "   ",
            senderPeerID: PeerID(str: "abcdef0123456789"),
            mentions: ["alice", "  ", "b\nob"]
        )

        let payload = message.toBinaryPayload()
        let decoded = payload.flatMap(BitchatMessage.init)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.sender, "unknown")
        XCTAssertNil(decoded?.recipientNickname)
        XCTAssertEqual(decoded?.mentions, ["alice", "bob"])
    }
}
