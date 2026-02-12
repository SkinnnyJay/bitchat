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
            originalSender: " \n ",
            isPrivate: true,
            recipientNickname: "   ",
            senderPeerID: PeerID(str: "abcdef0123456789"),
            mentions: ["alice", "  ", "b\nob"]
        )

        let payload = message.toBinaryPayload()
        let decoded = payload.flatMap(BitchatMessage.init)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.sender, "unknown")
        XCTAssertNil(decoded?.originalSender)
        XCTAssertNil(decoded?.recipientNickname)
        XCTAssertEqual(decoded?.mentions, ["alice", "bob"])
    }

    func testBinaryDecodeRejectsInvalidMessageID() {
        var payload = Data()
        payload.append(0) // flags
        payload.append(contentsOf: Array(repeating: UInt8(0), count: 8)) // timestamp

        let invalidID = "invalid id"
        payload.append(UInt8(invalidID.utf8.count))
        payload.append(contentsOf: invalidID.utf8)

        let sender = "alice"
        payload.append(UInt8(sender.utf8.count))
        payload.append(contentsOf: sender.utf8)

        let content = "hello"
        let contentLength = UInt16(content.utf8.count)
        payload.append(UInt8((contentLength >> 8) & 0xFF))
        payload.append(UInt8(contentLength & 0xFF))
        payload.append(contentsOf: content.utf8)

        XCTAssertNil(BitchatMessage(payload))
    }

    func testBinaryEncodingRejectsOversizedContent() {
        let oversizedContent = String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        let message = BitchatMessage(
            id: "mid-oversized-encode",
            sender: "alice",
            content: oversizedContent,
            timestamp: Date(),
            isRelay: false
        )

        XCTAssertNil(message.toBinaryPayload())
    }

    func testBinaryDecodeRejectsOversizedContent() {
        let oversizedContent = String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        var payload = Data()
        payload.append(0) // flags
        payload.append(contentsOf: Array(repeating: UInt8(0), count: 8)) // timestamp

        let id = "mid-oversized-decode"
        payload.append(UInt8(id.utf8.count))
        payload.append(contentsOf: id.utf8)

        let sender = "alice"
        payload.append(UInt8(sender.utf8.count))
        payload.append(contentsOf: sender.utf8)

        let contentLength = UInt16(oversizedContent.utf8.count)
        payload.append(UInt8((contentLength >> 8) & 0xFF))
        payload.append(UInt8(contentLength & 0xFF))
        payload.append(contentsOf: oversizedContent.utf8)

        XCTAssertNil(BitchatMessage(payload))
    }

    func testCodableDecodeRejectsInvalidMessageID() {
        let raw: [String: Any] = [
            "id": "invalid message id",
            "sender": "alice",
            "content": "hello",
            "timestamp": Date().timeIntervalSinceReferenceDate,
            "isRelay": false,
            "isPrivate": false
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw, options: [])

        XCTAssertThrowsError(try JSONDecoder().decode(BitchatMessage.self, from: data))
    }

    func testCodableDecodeSanitizesOptionalFields() {
        let raw: [String: Any] = [
            "id": "mid-codable-sanitize",
            "sender": "   ",
            "content": "hello",
            "timestamp": Date().timeIntervalSinceReferenceDate,
            "isRelay": false,
            "originalSender": "\n",
            "isPrivate": true,
            "recipientNickname": "   ",
            "senderPeerID": "invalid peer id",
            "mentions": ["alice", "  ", "b\nob"]
        ]
        let data = try! JSONSerialization.data(withJSONObject: raw, options: [])

        let decoded = try? JSONDecoder().decode(BitchatMessage.self, from: data)

        XCTAssertEqual(decoded?.sender, "unknown")
        XCTAssertNil(decoded?.originalSender)
        XCTAssertNil(decoded?.recipientNickname)
        XCTAssertNil(decoded?.senderPeerID)
        XCTAssertEqual(decoded?.mentions, ["alice", "bob"])
    }

    func testCodableEncodeOmitsInvalidSenderPeerID() throws {
        let message = BitchatMessage(
            id: "mid-codable-encode",
            sender: "alice",
            content: "hello",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            senderPeerID: PeerID(str: "invalid peer id")
        )

        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertNil(json?["senderPeerID"])
    }

    func testCodableEncodeRejectsOversizedContent() {
        let oversizedContent = String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        let message = BitchatMessage(
            id: "mid-codable-oversized",
            sender: "alice",
            content: oversizedContent,
            timestamp: Date(),
            isRelay: false
        )

        XCTAssertThrowsError(try JSONEncoder().encode(message))
    }
}
