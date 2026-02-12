import XCTest
import Combine
@testable import bitchat

final class HybridTransportManagerTests: XCTestCase {
    private final class MockTransport: Transport {
        weak var delegate: BitchatDelegate?
        weak var peerEventsDelegate: TransportPeerEventsDelegate?

        var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
            Just([]).eraseToAnyPublisher()
        }

        func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

        var myPeerID = PeerID(str: "selfpeer00000000")
        var myNickname = "self"
        private let noiseService = NoiseEncryptionService(keychain: MockKeychain())

        private(set) var sentPrivateMessages: [(content: String, peerID: PeerID, nickname: String, messageID: String)] = []

        func setNickname(_ nickname: String) {
            myNickname = nickname
        }

        func startServices() {}
        func stopServices() {}
        func emergencyDisconnectAll() {}
        func isPeerConnected(_ peerID: PeerID) -> Bool { false }
        func isPeerReachable(_ peerID: PeerID) -> Bool { false }
        func peerNickname(peerID: PeerID) -> String? { nil }
        func getPeerNicknames() -> [PeerID : String] { [:] }
        func getFingerprint(for peerID: PeerID) -> String? { nil }
        func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
        func triggerHandshake(with peerID: PeerID) {}
        func getNoiseService() -> NoiseEncryptionService { noiseService }
        func sendMessage(_ content: String, mentions: [String]) {}
        func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
            sentPrivateMessages.append((content, peerID, recipientNickname, messageID))
        }
        func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
        func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
        func sendBroadcastAnnounce() {}
        func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}
    }

    private final class MockWiFiBackend: WiFiDirectTransportBackend {
        weak var owner: WiFiDirectTransport?
        var isAvailable = true
        var capabilitiesByPeerID: [String: Set<String>] = [:]
        private(set) var sentPayloads: [(Data, String?)] = []

        required init(localPeerID: String?) {}

        func startDiscovery() {}
        func stopDiscovery() {}

        func send(_ data: Data, to peerID: String?) throws {
            sentPayloads.append((data, peerID))
        }

        func capabilities(for peerID: String) -> Set<String>? {
            capabilitiesByPeerID[peerID]
        }

        func setPeers(_ peers: [String]) {
            owner?.didUpdatePeers(peers)
        }

        func setCapabilities(_ capabilities: Set<String>, for peerID: String) {
            capabilitiesByPeerID[peerID] = capabilities
        }

        func simulateIncoming(_ data: Data, from peerID: String) {
            owner?.didReceive(data, from: peerID)
        }
    }

    private final class MockDelegate: HybridTransportManagerDelegate {
        var receivedEnvelopes: [WiFiDirectPrivateEnvelope] = []
        var peerUpdates: [[String]] = []

        func hybridTransportManager(_ manager: HybridTransportManager, didReceivePrivateEnvelope envelope: WiFiDirectPrivateEnvelope) {
            receivedEnvelopes.append(envelope)
        }

        func hybridTransportManager(_ manager: HybridTransportManager, didUpdateWiFiPeers peers: [String]) {
            peerUpdates.append(peers)
        }
    }

    @MainActor
    func testSendPrivateRoutesViaWiFiUsingShortDerivedIDForNoiseKeyRecipient() throws {
        let noiseKey = Data(repeating: 0x44, count: 32)
        let recipientFull = PeerID(hexData: noiseKey)
        let recipientShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipientShort.id])
        backend.setCapabilities(["pm"], for: recipientShort.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let route = manager.sendPrivate("hello", to: recipientFull, recipientNickname: "peer", messageID: "mid-1")

        XCTAssertEqual(route, .wifiDirect)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientPeerID, recipientShort.id)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
    }

    @MainActor
    func testSendPrivateFallsBackToMeshWhenWiFiCapabilityMissing() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["ack"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: "mid-2")

        XCTAssertEqual(route, .mesh)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 1)
        XCTAssertEqual(mesh.sentPrivateMessages[0].messageID, "mid-2")
    }

    @MainActor
    func testReceivesInboundPrivateEnvelopeWithNormalizedSenderAndRecipientIDs() throws {
        let localNoise = Data(repeating: 0x21, count: 32)
        let localShort = PeerID(publicKey: localNoise)
        let localFull = PeerID(hexData: localNoise)

        let senderNoise = Data(repeating: 0x22, count: 32)
        let senderShort = PeerID(publicKey: senderNoise)
        let senderFull = PeerID(hexData: senderNoise)

        let mesh = MockTransport()
        mesh.myPeerID = localShort

        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let expect = expectation(description: "normalized inbound envelope delivered to delegate")
        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: senderFull.id,
            recipientPeerID: localFull.id,
            recipientNickname: "self",
            messageID: "mid-3",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: senderShort.id)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, 1)
        XCTAssertEqual(delegate.receivedEnvelopes[0].messageID, "mid-3")
    }

    @MainActor
    func testRejectsInboundPrivateEnvelopeWithStaleTimestamp() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi, nowProvider: { fixedNow })
        let delegate = MockDelegate()
        manager.delegate = delegate

        let staleCreatedAt = UInt64(
            fixedNow
                .addingTimeInterval(-(TransportConfig.messageRouterInboundWiFiTimestampMaxAgeSeconds + 1))
                .timeIntervalSince1970 * 1000
        )
        let payloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": "peer-stale",
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-stale",
            "content": "hello",
            "createdAtMs": staleCreatedAt
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
        backend.simulateIncoming(payload, from: "peer-stale")

        let expect = expectation(description: "stale envelope should be ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
    }

    @MainActor
    func testDeduplicatesInboundPrivateEnvelopesBySenderAndMessageID() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-dup",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-dup",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-dup")
        backend.simulateIncoming(payload, from: "peer-dup")

        let expect = expectation(description: "duplicate envelopes settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, 1)
        XCTAssertEqual(delegate.receivedEnvelopes[0].messageID, "mid-dup")
    }
}
