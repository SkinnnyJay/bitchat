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
}
