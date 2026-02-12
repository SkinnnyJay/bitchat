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
}
