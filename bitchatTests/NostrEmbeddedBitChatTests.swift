import XCTest
@testable import bitchat

final class NostrEmbeddedBitChatTests: XCTestCase {
    func testEncodePMForNostrRejectsInvalidMessageID() {
        let result = NostrEmbeddedBitChat.encodePMForNostr(
            content: "hello",
            messageID: "mid with-space",
            recipientPeerID: "abcdef0123456789",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNil(result)
    }

    func testEncodePMForNostrRejectsOversizedContentForPacketEnvelope() {
        let oversized = String(repeating: "x", count: 300)
        let result = NostrEmbeddedBitChat.encodePMForNostr(
            content: oversized,
            messageID: "mid-oversized",
            recipientPeerID: "abcdef0123456789",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNil(result)
    }

    func testEncodeAckForNostrRejectsUnsupportedAckTypes() {
        let result = NostrEmbeddedBitChat.encodeAckForNostr(
            type: .privateMessage,
            messageID: "mid-ack-unsupported",
            recipientPeerID: "abcdef0123456789",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNil(result)
    }

    func testEncodeAckForNostrReturnsPrefixedPayloadForValidInput() {
        let result = NostrEmbeddedBitChat.encodeAckForNostr(
            type: .delivered,
            messageID: "mid-ack-valid",
            recipientPeerID: "abcdef0123456789",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("bitchat1:") == true)
    }

    func testEncodeAckForNostrRejectsNonHexRecipientPeerID() {
        let result = NostrEmbeddedBitChat.encodeAckForNostr(
            type: .delivered,
            messageID: "mid-ack-valid",
            recipientPeerID: "peerabc000000000",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNil(result)
    }
}
