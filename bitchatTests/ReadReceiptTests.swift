import XCTest
@testable import bitchat

final class ReadReceiptTests: XCTestCase {
    func testInitializerSanitizesFields() {
        let noiseKey = String(repeating: "ab", count: 32)
        let expectedReaderID = PeerID(str: noiseKey).toShort().id

        let receipt = ReadReceipt(
            originalMessageID: "invalid id",
            readerID: noiseKey,
            readerNickname: "   "
        )

        XCTAssertNotEqual(receipt.originalMessageID, "invalid id")
        XCTAssertNotNil(InputValidator.validateMessageID(receipt.originalMessageID))
        XCTAssertEqual(receipt.readerID, expectedReaderID)
        XCTAssertEqual(receipt.readerNickname, "user")
    }

    func testCodableDecodeRejectsInvalidReaderID() throws {
        let raw: [String: Any] = [
            "originalMessageID": "mid-reader-invalid",
            "receiptID": "receipt-valid",
            "readerID": "invalid id",
            "readerNickname": "alice",
            "timestamp": Date().timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: raw, options: [])

        XCTAssertThrowsError(try JSONDecoder().decode(ReadReceipt.self, from: data))
    }

    func testCodableDecodeRejectsInvalidMessageID() throws {
        let raw: [String: Any] = [
            "originalMessageID": "invalid message id",
            "receiptID": "receipt-valid",
            "readerID": "abcdef0123456789",
            "readerNickname": "alice",
            "timestamp": Date().timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: raw, options: [])

        XCTAssertThrowsError(try JSONDecoder().decode(ReadReceipt.self, from: data))
    }

    func testCodableEncodeRejectsInvalidReaderID() {
        let receipt = ReadReceipt(
            originalMessageID: "mid-encode-invalid-reader",
            readerID: "invalid id",
            readerNickname: "alice"
        )

        XCTAssertThrowsError(try JSONEncoder().encode(receipt))
    }

    func testCodableRoundTripPreservesCanonicalValues() throws {
        let receipt = ReadReceipt(
            originalMessageID: "mid-roundtrip",
            readerID: "abcdef0123456789",
            readerNickname: "alice"
        )

        let encoded = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(ReadReceipt.self, from: encoded)

        XCTAssertEqual(decoded.originalMessageID, "mid-roundtrip")
        XCTAssertEqual(decoded.readerID, "abcdef0123456789")
        XCTAssertEqual(decoded.readerNickname, "alice")
    }

    func testBinaryRoundTripSupportsCanonicalMessageIDs() {
        let receipt = ReadReceipt(
            originalMessageID: "mid-binary-roundtrip",
            readerID: "abcdef0123456789",
            readerNickname: "alice"
        )

        let data = receipt.toBinaryData()
        let decoded = ReadReceipt.fromBinaryData(data)

        XCTAssertEqual(decoded?.originalMessageID, "mid-binary-roundtrip")
        XCTAssertEqual(decoded?.readerID, "abcdef0123456789")
        XCTAssertEqual(decoded?.readerNickname, "alice")
    }

    func testBinaryEncodingReturnsEmptyDataForInvalidReaderID() {
        let receipt = ReadReceipt(
            originalMessageID: "mid-binary-invalid-reader",
            readerID: "invalid id",
            readerNickname: "alice"
        )

        XCTAssertTrue(receipt.toBinaryData().isEmpty)
    }

    func testBinaryDecodeSupportsLegacyUUIDFormat() {
        let originalMessageID = UUID().uuidString
        let receiptID = UUID().uuidString
        let readerID = "abcdef0123456789"
        let nickname = "alice"
        let timestamp = Date()

        var data = Data()
        data.appendUUID(originalMessageID)
        data.appendUUID(receiptID)
        data.append(Data(hexString: readerID)!)
        data.appendDate(timestamp)
        data.appendString(nickname)

        let decoded = ReadReceipt.fromBinaryData(data)

        XCTAssertEqual(decoded?.originalMessageID, originalMessageID.uppercased())
        XCTAssertEqual(decoded?.receiptID, receiptID.uppercased())
        XCTAssertEqual(decoded?.readerID, readerID)
        XCTAssertEqual(decoded?.readerNickname, nickname)
    }

    func testBinaryDecodeRejectsInvalidV1MessageID() {
        var data = Data()
        data.append(0x01) // version
        data.appendString("invalid message id", maxLength: 255)
        data.appendString("receipt-valid", maxLength: 255)
        data.append(Data(hexString: "abcdef0123456789")!)
        data.appendDate(Date())
        data.appendString("alice", maxLength: 255)

        XCTAssertNil(ReadReceipt.fromBinaryData(data))
    }
}
