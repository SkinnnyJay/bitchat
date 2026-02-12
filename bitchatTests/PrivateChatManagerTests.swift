import XCTest
import Combine
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

    func testMarkAsReadSkipsInvalidSenderPeerID() {
        let manager = PrivateChatManager()
        manager.meshService = MockTransportForPrivateChatManager()
        let invalidPeerID = "invalid peer id"
        manager.privateChats[invalidPeerID] = [
            BitchatMessage(
                id: "mid-invalid-sender",
                sender: "peer",
                content: "hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                senderPeerID: PeerID(str: invalidPeerID)
            )
        ]

        manager.markAsRead(from: invalidPeerID)

        XCTAssertTrue(manager.sentReadReceipts.isEmpty)
    }

    func testMarkAsReadSkipsInvalidMessageID() {
        let manager = PrivateChatManager()
        let transport = MockTransportForPrivateChatManager()
        manager.meshService = transport
        let senderPeerID = "abcdef0123456789"
        manager.privateChats[senderPeerID] = [
            BitchatMessage(
                id: "invalid message id",
                sender: "peer",
                content: "hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                senderPeerID: PeerID(str: senderPeerID)
            )
        ]

        manager.markAsRead(from: senderPeerID)

        XCTAssertTrue(manager.sentReadReceipts.isEmpty)
        XCTAssertTrue(transport.sentReadReceipts.isEmpty)
    }

    func testMarkAsReadSanitizesReaderNicknameToFallbackUser() {
        let manager = PrivateChatManager()
        let transport = MockTransportForPrivateChatManager()
        transport.nickname = "\n"
        manager.meshService = transport
        let senderPeerID = "abcdef0123456789"
        manager.privateChats[senderPeerID] = [
            BitchatMessage(
                id: "mid-reader-nickname",
                sender: "peer",
                content: "hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                senderPeerID: PeerID(str: senderPeerID)
            )
        ]

        manager.markAsRead(from: senderPeerID)

        XCTAssertEqual(transport.sentReadReceipts.count, 1)
        XCTAssertEqual(transport.sentReadReceipts.first?.originalMessageID, "mid-reader-nickname")
        XCTAssertEqual(transport.sentReadReceipts.first?.readerNickname, "user")
    }

    func testMarkAsReadMatchesEquivalentSenderPeerIDVariants() {
        let manager = PrivateChatManager()
        let transport = MockTransportForPrivateChatManager()
        manager.meshService = transport

        let noiseKey = Data(repeating: 0x11, count: 32)
        let fullNoiseID = noiseKey.hexEncodedString()
        let shortPeerID = PeerID(publicKey: noiseKey).id
        manager.privateChats[shortPeerID] = [
            BitchatMessage(
                id: "mid-equivalent-id",
                sender: "peer",
                content: "hello",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                senderPeerID: PeerID(str: fullNoiseID)
            )
        ]

        manager.markAsRead(from: shortPeerID)

        XCTAssertEqual(transport.sentReadReceipts.count, 1)
        XCTAssertEqual(transport.sentReadReceipts.first?.originalMessageID, "mid-equivalent-id")
    }
}

private final class MockTransportForPrivateChatManager: Transport {
    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> { Just([]).eraseToAnyPublisher() }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    var myPeerID: PeerID = PeerID(str: "0123456789abcdef")
    var nickname: String = "tester"
    var myNickname: String { nickname }
    func setNickname(_ nickname: String) { self.nickname = nickname }

    func startServices() {}
    func stopServices() {}
    func emergencyDisconnectAll() {}

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    func isPeerReachable(_ peerID: PeerID) -> Bool { false }
    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID: String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) {}
    func getNoiseService() -> NoiseEncryptionService { NoiseEncryptionService(keychain: MockKeychain()) }

    func sendMessage(_ content: String, mentions: [String]) {}
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {}

    var sentReadReceipts: [ReadReceipt] = []
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        sentReadReceipts.append(receipt)
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendBroadcastAnnounce() {}
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}
}
