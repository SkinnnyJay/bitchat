import XCTest
@testable import bitchat

final class PrivateChatManagerTests: XCTestCase {
    func testMarkReadReceiptSentStoresValidatedMessageID() {
        let manager = PrivateChatManager()

        manager.markReadReceiptSent("mid-valid-001")

        XCTAssertTrue(manager.sentReadReceipts.contains("mid-valid-001"))
    }

    func testMarkReadReceiptSentRejectsInvalidMessageID() {
        let manager = PrivateChatManager()

        manager.markReadReceiptSent("mid invalid whitespace")

        XCTAssertTrue(manager.sentReadReceipts.isEmpty)
    }

    func testMarkReadReceiptSentCapsTrackedIDs() {
        let manager = PrivateChatManager()
        let cap = TransportConfig.uiSentReadReceiptsCap

        for index in 0..<(cap + 2) {
            manager.markReadReceiptSent("mid-\(index)")
        }

        XCTAssertEqual(manager.sentReadReceipts.count, cap)
        XCTAssertFalse(manager.sentReadReceipts.contains("mid-0"))
        XCTAssertTrue(manager.sentReadReceipts.contains("mid-\(cap + 1)"))
    }
}
