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

    func testEncodeAckForNostrNoRecipientRejectsInvalidMessageID() {
        let result = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
            type: .delivered,
            messageID: "mid with-space",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNil(result)
    }

    func testEncodePMForNostrNoRecipientRejectsInvalidSenderPeerID() {
        let result = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(
            content: "hello",
            messageID: "mid-norecipient",
            senderPeerID: "peerabc000000000"
        )

        XCTAssertNil(result)
    }

    func testEncodePMForNostrNoRecipientReturnsPrefixedPayloadForValidInput() {
        let result = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(
            content: "hello",
            messageID: "mid-norecipient",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("bitchat1:") == true)
    }

    func testEncodePMForNostrAcceptsFullNoisePeerIDsByNormalizingToShortIDs() {
        let noiseRecipient = String(repeating: "a1", count: 32)
        let noiseSender = String(repeating: "b2", count: 32)
        let result = NostrEmbeddedBitChat.encodePMForNostr(
            content: "hello",
            messageID: "mid-noise-peers",
            recipientPeerID: noiseRecipient,
            senderPeerID: noiseSender
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("bitchat1:") == true)

        let decoded = decodeEmbeddedPacket(result)
        let expectedRecipient = PeerID(publicKey: Data(hexString: noiseRecipient)!).id
        let expectedSender = PeerID(publicKey: Data(hexString: noiseSender)!).id
        XCTAssertEqual(decoded?.recipientID?.hexEncodedString(), expectedRecipient)
        XCTAssertEqual(decoded?.senderID.hexEncodedString(), expectedSender)
    }

    func testEncodePMForNostrAcceptsPrefixedFullNoisePeerIDs() {
        let noiseRecipient = "mesh:" + String(repeating: "a1", count: 32)
        let noiseSender = "noise:" + String(repeating: "b2", count: 32)
        let result = NostrEmbeddedBitChat.encodePMForNostr(
            content: "hello",
            messageID: "mid-prefixed-noise-peers",
            recipientPeerID: noiseRecipient,
            senderPeerID: noiseSender
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("bitchat1:") == true)
    }

    func testEncodeAckForNostrAcceptsPrefixedShortPeerIDs() {
        let recipient = "mesh:abcdef0123456789"
        let sender = "mesh:0123456789abcdef"
        let result = NostrEmbeddedBitChat.encodeAckForNostr(
            type: .delivered,
            messageID: "mid-prefixed-peer",
            recipientPeerID: recipient,
            senderPeerID: sender
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("bitchat1:") == true)
        let decoded = decodeEmbeddedPacket(result)
        XCTAssertEqual(decoded?.recipientID?.hexEncodedString(), PeerID(str: recipient).toShort().bare)
        XCTAssertEqual(decoded?.senderID.hexEncodedString(), PeerID(str: sender).toShort().bare)
    }

    func testEncodeAckForNostrNoRecipientAcceptsFullNoiseSenderPeerID() {
        let noiseSender = String(repeating: "c3", count: 32)
        let result = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
            type: .readReceipt,
            messageID: "mid-noise-sender",
            senderPeerID: noiseSender
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("bitchat1:") == true)
        let decoded = decodeEmbeddedPacket(result)
        XCTAssertEqual(decoded?.recipientID, nil)
        XCTAssertEqual(decoded?.senderID.hexEncodedString(), PeerID(publicKey: Data(hexString: noiseSender)!).id)
    }

    func testEncodeAckForNostrNoRecipientRejectsNonRoutableSenderPeerID() {
        let result = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(
            type: .delivered,
            messageID: "mid-invalid-sender",
            senderPeerID: "peer_sender"
        )

        XCTAssertNil(result)
    }

    func testEncodePMForNostrRejectsNonRoutableInternalPeerIDs() {
        let result = NostrEmbeddedBitChat.encodePMForNostr(
            content: "hello",
            messageID: "mid-internal-peer",
            recipientPeerID: "peer_recipient",
            senderPeerID: "peer_sender"
        )

        XCTAssertNil(result)
    }

    func testEncodePMForNostrRejectsPrefixedGeoChatPeerIDsWithNonRoutableLength() {
        let result = NostrEmbeddedBitChat.encodePMForNostr(
            content: "hello",
            messageID: "mid-geochat-short",
            recipientPeerID: "nostr:abcdef01",
            senderPeerID: "0123456789abcdef"
        )

        XCTAssertNil(result)
    }

    func testEncodeAckForNostrAcceptsUppercaseHexPeerIDs() {
        let uppercaseRecipient = "ABCDEF0123456789"
        let uppercaseSender = "0123456789ABCDEF"
        let result = NostrEmbeddedBitChat.encodeAckForNostr(
            type: .delivered,
            messageID: "mid-uppercase-hex",
            recipientPeerID: uppercaseRecipient,
            senderPeerID: uppercaseSender
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.hasPrefix("bitchat1:") == true)
        let decoded = decodeEmbeddedPacket(result)
        XCTAssertEqual(decoded?.recipientID?.hexEncodedString(), uppercaseRecipient.lowercased())
        XCTAssertEqual(decoded?.senderID.hexEncodedString(), uppercaseSender.lowercased())
    }

    private func decodeEmbeddedPacket(_ encoded: String?) -> BitchatPacket? {
        guard let encoded, encoded.hasPrefix("bitchat1:") else { return nil }
        let payload = String(encoded.dropFirst("bitchat1:".count))
        guard let packetData = base64URLDecode(payload) else { return nil }
        return BitchatPacket.from(packetData)
    }

    private func base64URLDecode(_ value: String) -> Data? {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = normalized.count % 4
        if padding > 0 {
            normalized.append(String(repeating: "=", count: 4 - padding))
        }
        return Data(base64Encoded: normalized)
    }
}
