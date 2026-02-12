import XCTest
@testable import bitchat

final class AnnouncementPacketTests: XCTestCase {
    func testEncodeDecodeRoundTripsWithValidNickname() throws {
        let packet = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32)
        )

        let encoded = try XCTUnwrap(packet.encode())
        let decoded = try XCTUnwrap(AnnouncementPacket.decode(from: encoded))

        XCTAssertEqual(decoded.nickname, "alice")
        XCTAssertEqual(decoded.noisePublicKey, packet.noisePublicKey)
        XCTAssertEqual(decoded.signingPublicKey, packet.signingPublicKey)
    }

    func testDecodeRejectsInvalidNickname() throws {
        let encoded = try encodedAnnouncementData(
            nickname: "   ",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32)
        )

        XCTAssertNil(AnnouncementPacket.decode(from: encoded))
    }

    func testEncodeRejectsInvalidNickname() {
        let packet = AnnouncementPacket(
            nickname: "   ",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32)
        )

        XCTAssertNil(packet.encode())
    }

    func testDecodeSkipsUnknownTLVs() throws {
        var encoded = try encodedAnnouncementData(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32)
        )
        encoded.append(0x7E) // unknown type
        encoded.append(0x02) // length
        encoded.append(Data([0xAA, 0xBB]))

        let decoded = try XCTUnwrap(AnnouncementPacket.decode(from: encoded))
        XCTAssertEqual(decoded.nickname, "alice")
    }

    func testDecodeRejectsTrailingTruncatedTLVHeader() throws {
        var encoded = try encodedAnnouncementData(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 32)
        )
        encoded.append(0x7E) // trailing type byte without length/value
        XCTAssertNil(AnnouncementPacket.decode(from: encoded))
    }

    func testEncodeRejectsInvalidNoiseOrSigningKeyLengths() {
        let invalidNoise = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 31),
            signingPublicKey: Data(repeating: 0x22, count: 32)
        )
        XCTAssertNil(invalidNoise.encode())

        let invalidSigning = AnnouncementPacket(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 33)
        )
        XCTAssertNil(invalidSigning.encode())
    }

    func testDecodeRejectsInvalidNoiseOrSigningKeyLengths() throws {
        let invalidNoise = try encodedAnnouncementData(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 31),
            signingPublicKey: Data(repeating: 0x22, count: 32)
        )
        XCTAssertNil(AnnouncementPacket.decode(from: invalidNoise))

        let invalidSigning = try encodedAnnouncementData(
            nickname: "alice",
            noisePublicKey: Data(repeating: 0x11, count: 32),
            signingPublicKey: Data(repeating: 0x22, count: 31)
        )
        XCTAssertNil(AnnouncementPacket.decode(from: invalidSigning))
    }

    private func encodedAnnouncementData(
        nickname: String,
        noisePublicKey: Data,
        signingPublicKey: Data
    ) throws -> Data {
        var data = Data()
        let nicknameData = try XCTUnwrap(nickname.data(using: .utf8))

        XCTAssertLessThanOrEqual(nicknameData.count, 255)
        XCTAssertLessThanOrEqual(noisePublicKey.count, 255)
        XCTAssertLessThanOrEqual(signingPublicKey.count, 255)

        data.append(0x01)
        data.append(UInt8(nicknameData.count))
        data.append(nicknameData)

        data.append(0x02)
        data.append(UInt8(noisePublicKey.count))
        data.append(noisePublicKey)

        data.append(0x03)
        data.append(UInt8(signingPublicKey.count))
        data.append(signingPublicKey)
        return data
    }
}
