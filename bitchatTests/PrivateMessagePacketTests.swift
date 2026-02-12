import XCTest
@testable import bitchat

final class PrivateMessagePacketTests: XCTestCase {
    func testEncodeDecodeRoundTripsWithCanonicalMessageID() throws {
        let packet = PrivateMessagePacket(messageID: "mid-1234", content: "hello")
        let encoded = try XCTUnwrap(packet.encode())
        let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: encoded))

        XCTAssertEqual(decoded.messageID, "mid-1234")
        XCTAssertEqual(decoded.content, "hello")
    }

    func testEncodeRejectsMessageIDWithSurroundingWhitespace() {
        let packet = PrivateMessagePacket(messageID: "  bad-id  ", content: "hello")
        XCTAssertNil(packet.encode())
    }

    func testEncodeRejectsMessageIDExceedingLengthLimit() {
        let oversized = String(repeating: "m", count: InputValidator.Limits.maxMessageIDLength + 1)
        let packet = PrivateMessagePacket(messageID: oversized, content: "hello")
        XCTAssertNil(packet.encode())
    }

    func testDecodeRejectsMessageIDWithSurroundingWhitespace() throws {
        let data = try encodedPacketData(messageID: "  bad-id  ", content: "hello")
        XCTAssertNil(PrivateMessagePacket.decode(from: data))
    }

    func testDecodeRejectsMessageIDExceedingLengthLimit() throws {
        let oversized = String(repeating: "m", count: InputValidator.Limits.maxMessageIDLength + 1)
        let data = try encodedPacketData(messageID: oversized, content: "hello")
        XCTAssertNil(PrivateMessagePacket.decode(from: data))
    }

    func testDecodeSkipsUnknownTLVs() throws {
        var data = try encodedPacketData(messageID: "mid-unknown", content: "hello")
        data.append(0x7F) // unknown type
        data.append(0x03) // length
        data.append(Data([0x41, 0x42, 0x43]))

        let decoded = try XCTUnwrap(PrivateMessagePacket.decode(from: data))
        XCTAssertEqual(decoded.messageID, "mid-unknown")
        XCTAssertEqual(decoded.content, "hello")
    }

    func testDecodeRejectsTrailingTruncatedTLVHeader() throws {
        var data = try encodedPacketData(messageID: "mid-1", content: "hello")
        data.append(0x7F) // trailing type byte without length/value
        XCTAssertNil(PrivateMessagePacket.decode(from: data))
    }

    private func encodedPacketData(messageID: String, content: String) throws -> Data {
        var data = Data()
        let messageIDData = try XCTUnwrap(messageID.data(using: .utf8))
        let contentData = try XCTUnwrap(content.data(using: .utf8))
        XCTAssertLessThanOrEqual(messageIDData.count, 255)
        XCTAssertLessThanOrEqual(contentData.count, 255)

        data.append(0x00) // messageID TLV type
        data.append(UInt8(messageIDData.count))
        data.append(messageIDData)
        data.append(0x01) // content TLV type
        data.append(UInt8(contentData.count))
        data.append(contentData)
        return data
    }
}
