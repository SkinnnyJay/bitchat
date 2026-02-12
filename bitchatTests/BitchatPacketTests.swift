import XCTest
@testable import bitchat

final class BitchatPacketTests: XCTestCase {
    func testConvenienceInitUsesShortSenderIDForFullNoiseInput() {
        let noiseKey = Data(repeating: 0x11, count: 32)
        let fullNoiseID = PeerID(hexData: noiseKey)
        let expectedShort = PeerID(publicKey: noiseKey).id

        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 3,
            senderID: fullNoiseID,
            payload: Data("hello".utf8)
        )

        XCTAssertEqual(packet.senderID.hexEncodedString(), expectedShort)
    }

    func testConvenienceInitDropsInvalidSenderIDToEmptyData() {
        let invalidSenderID = PeerID(str: "invalid peer id")

        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 3,
            senderID: invalidSenderID,
            payload: Data("hello".utf8)
        )

        XCTAssertTrue(packet.senderID.isEmpty)
    }

    func testConvenienceInitAcceptsPrefixedShortSenderID() {
        let prefixedShort = PeerID(str: "mesh:abcdef0123456789")

        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 3,
            senderID: prefixedShort,
            payload: Data("hello".utf8)
        )

        XCTAssertEqual(packet.senderID.hexEncodedString(), "abcdef0123456789")
    }

    func testConvenienceInitAcceptsPrefixedFullNoiseSenderIDByDerivingShort() {
        let noiseKey = Data(repeating: 0x2A, count: 32)
        let prefixedFullNoise = PeerID(str: "mesh:\(noiseKey.hexEncodedString())")
        let expectedShort = PeerID(publicKey: noiseKey).bare

        let packet = BitchatPacket(
            type: MessageType.message.rawValue,
            ttl: 3,
            senderID: prefixedFullNoise,
            payload: Data("hello".utf8)
        )

        XCTAssertEqual(packet.senderID.hexEncodedString(), expectedShort)
    }
}
