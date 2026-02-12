import XCTest
@testable import bitchat

final class InputValidatorTests: XCTestCase {
    func testValidateMessageIDAcceptsCanonicalID() {
        let messageID = "8D6FCD5D-2A1F-4A5C-8EB2-2EFA9FD941A0"
        XCTAssertEqual(InputValidator.validateMessageID(messageID), messageID)
    }

    func testValidateMessageIDRejectsEmptyOrWhitespaceOnly() {
        XCTAssertNil(InputValidator.validateMessageID(""))
        XCTAssertNil(InputValidator.validateMessageID("   "))
    }

    func testValidateMessageIDRejectsIDsNeedingTrim() {
        XCTAssertNil(InputValidator.validateMessageID("  mid-trim  "))
    }

    func testValidateMessageIDRejectsOversizedIDs() {
        let oversized = String(repeating: "m", count: InputValidator.Limits.maxMessageIDLength + 1)
        XCTAssertNil(InputValidator.validateMessageID(oversized))
    }

    func testValidateMessageIDRejectsControlCharacters() {
        XCTAssertNil(InputValidator.validateMessageID("mid-\n-control"))
    }

    func testValidateMessageIDRejectsInvisibleCharacters() {
        XCTAssertNil(InputValidator.validateMessageID("mid-\u{200B}-invisible"))
    }
}
