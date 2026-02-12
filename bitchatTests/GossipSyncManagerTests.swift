import Foundation
import XCTest
@testable import bitchat

final class GossipSyncManagerTests: XCTestCase {
    func testCanonicalRoutingIDHexNormalizesPrefixedShortPeerID() {
        XCTAssertEqual(
            GossipSyncManager.canonicalRoutingIDHex(for: PeerID(str: "mesh:abcdef0123456789")),
            "abcdef0123456789"
        )
    }

    func testCanonicalRoutingIDHexTrimsWhitespaceBeforeNormalization() {
        XCTAssertEqual(
            GossipSyncManager.canonicalRoutingIDHex(for: PeerID(str: "  mesh:abcdef0123456789  ")),
            "abcdef0123456789"
        )
    }

    func testCanonicalRoutingIDHexDerivesShortFromFullNoisePeerID() {
        let fullNoisePeerID = PeerID(str: String(repeating: "ab", count: 32))
        let expectedShort = fullNoisePeerID.toShort().bare

        XCTAssertEqual(
            GossipSyncManager.canonicalRoutingIDHex(for: fullNoisePeerID),
            expectedShort
        )
    }

    func testInitialSyncToPeerUsesCanonicalSenderAndRecipientRoutingIDs() {
        let manager = GossipSyncManager(myPeerID: "mesh:abcdef0123456789")
        let delegate = RecordingDelegate()
        let sendExpectation = expectation(description: "initial sync sent")
        delegate.onSend = { _ in sendExpectation.fulfill() }
        manager.delegate = delegate

        manager.scheduleInitialSyncToPeer("mesh:1122334455667788", delaySeconds: 0.0)

        wait(for: [sendExpectation], timeout: 2.0)

        XCTAssertEqual(delegate.lastPacket?.senderID.hexEncodedString(), "abcdef0123456789")
        XCTAssertEqual(delegate.lastPacket?.recipientID?.hexEncodedString(), "1122334455667788")
    }

    func testRemoveAnnouncementForEquivalentFullNoisePeerIDRemovesStoredShortSenderEntry() {
        let fullNoiseID = String(repeating: "ab", count: 32)
        let shortSenderID = PeerID(str: fullNoiseID).toShort().bare

        let manager = GossipSyncManager(myPeerID: "0102030405060708")
        let delegate = RecordingDelegate()
        let noAnnouncementExpectation = expectation(description: "no announce sent after removal")
        noAnnouncementExpectation.isInverted = true
        delegate.onSend = { packet in
            if packet.type == MessageType.announce.rawValue {
                noAnnouncementExpectation.fulfill()
            }
        }
        manager.delegate = delegate

        let announcePacket = BitchatPacket(
            type: MessageType.announce.rawValue,
            senderID: Data(hexString: shortSenderID) ?? Data(),
            recipientID: nil,
            timestamp: 1234,
            payload: Data([0x01]),
            signature: nil,
            ttl: 1
        )

        manager.onPublicPacketSeen(announcePacket)
        manager.removeAnnouncementForPeer(PeerID(str: "noise:\(fullNoiseID)"))
        manager.handleRequestSync(
            from: "1122334455667788",
            request: RequestSyncPacket(p: 1, m: 1, data: Data())
        )

        wait(for: [noAnnouncementExpectation], timeout: 0.2)
    }

    func testConcurrentPacketIntakeAndSyncRequest() {
        let manager = GossipSyncManager(myPeerID: "0102030405060708")
        let delegate = RecordingDelegate()
        let sendExpectation = expectation(description: "sync request sent")
        delegate.onSend = { _ in sendExpectation.fulfill() }
        manager.delegate = delegate

        let iterations = 200
        let group = DispatchGroup()

        for i in 0..<iterations {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let packet = BitchatPacket(
                    type: MessageType.message.rawValue,
                    senderID: Data(hexString: "1122334455667788") ?? Data(),
                    recipientID: nil,
                    timestamp: 1_000_000 + UInt64(i),
                    payload: Data([UInt8(truncatingIfNeeded: i)]),
                    signature: nil,
                    ttl: 1
                )
                manager.onPublicPacketSeen(packet)
                Thread.sleep(forTimeInterval: 0.001)
                group.leave()
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.002) {
            manager.scheduleInitialSyncToPeer("FFFFFFFFFFFFFFFF", delaySeconds: 0.0)
        }

        group.wait()
        wait(for: [sendExpectation], timeout: 2.0)

        guard let lastPacket = delegate.lastPacket else {
            XCTFail("Expected sync packet to be sent")
            return
        }

        XCTAssertEqual(lastPacket.type, MessageType.requestSync.rawValue)
        XCTAssertNotNil(RequestSyncPacket.decode(from: lastPacket.payload))
    }
}

private final class RecordingDelegate: GossipSyncManager.Delegate {
    var onSend: ((BitchatPacket) -> Void)?
    private(set) var lastPacket: BitchatPacket?
    private(set) var sentPackets: [BitchatPacket] = []
    private let lock = NSLock()

    func sendPacket(_ packet: BitchatPacket) {
        lock.lock()
        lastPacket = packet
        sentPackets.append(packet)
        lock.unlock()
        onSend?(packet)
    }

    func sendPacket(to peerID: PeerID, packet: BitchatPacket) {
        sendPacket(packet)
    }

    func signPacketForBroadcast(_ packet: BitchatPacket) -> BitchatPacket {
        packet
    }
}
