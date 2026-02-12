import XCTest
import Combine
@testable import bitchat

final class MessageRouterRoutingTests: XCTestCase {
    private final class MockTransport: Transport {
        weak var delegate: BitchatDelegate?
        weak var peerEventsDelegate: TransportPeerEventsDelegate?

        var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
            Just([]).eraseToAnyPublisher()
        }

        func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

        var myPeerID = PeerID(str: "selfpeer00000000")
        var myNickname = "self"

        private var reachablePeers: Set<PeerID> = []
        private var connectedPeers: Set<PeerID> = []
        private var nicknameMap: [PeerID: String] = [:]
        private let noiseService = NoiseEncryptionService(keychain: MockKeychain())

        private(set) var sentPrivateMessages: [(content: String, peerID: PeerID, nickname: String, messageID: String)] = []
        private(set) var sentReadReceipts: [(receipt: ReadReceipt, peerID: PeerID)] = []
        private(set) var sentDeliveryAcks: [(messageID: String, peerID: PeerID)] = []

        func setReachable(_ peerID: PeerID, isReachable: Bool) {
            if isReachable {
                reachablePeers.insert(peerID)
                connectedPeers.insert(peerID)
            } else {
                reachablePeers.remove(peerID)
                connectedPeers.remove(peerID)
            }
        }

        func setNickname(_ nickname: String) {
            myNickname = nickname
        }

        func setPeerNickname(_ nickname: String, for peerID: PeerID) {
            nicknameMap[peerID] = nickname
        }

        func startServices() {}
        func stopServices() {}
        func emergencyDisconnectAll() {}

        func isPeerConnected(_ peerID: PeerID) -> Bool {
            connectedPeers.contains(peerID)
        }

        func isPeerReachable(_ peerID: PeerID) -> Bool {
            reachablePeers.contains(peerID)
        }

        func peerNickname(peerID: PeerID) -> String? {
            nicknameMap[peerID]
        }

        func getPeerNicknames() -> [PeerID : String] {
            nicknameMap
        }

        func getFingerprint(for peerID: PeerID) -> String? { nil }
        func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
        func triggerHandshake(with peerID: PeerID) {}
        func getNoiseService() -> NoiseEncryptionService { noiseService }

        func sendMessage(_ content: String, mentions: [String]) {}

        func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
            sentPrivateMessages.append((content, peerID, recipientNickname, messageID))
        }

        func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
            sentReadReceipts.append((receipt, peerID))
        }
        func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
        func sendBroadcastAnnounce() {}
        func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
            sentDeliveryAcks.append((messageID, peerID))
        }
    }

    private final class MockWiFiBackend: WiFiDirectTransportBackend {
        weak var owner: WiFiDirectTransport?
        var isAvailable = true
        var sendError: Error?
        var capabilitiesByPeerID: [String: Set<String>] = [:]
        private(set) var sentPayloads: [(Data, String?)] = []

        required init(localPeerID: String?) {}

        func startDiscovery() {}
        func stopDiscovery() {}

        func send(_ data: Data, to peerID: String?) throws {
            if let sendError {
                throw sendError
            }
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

        func simulateAvailability(_ available: Bool) {
            isAvailable = available
            owner?.didChangeAvailability(available)
        }

        func simulateIncoming(_ data: Data, from peerID: String) {
            owner?.didReceive(data, from: peerID)
        }
    }

    private enum SampleError: Error {
        case failed
    }

    @MainActor
    func testRoutesLargeReachablePrivateMessageViaWiFi() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 16),
            wifiTransport: wifi
        )

        router.sendPrivate(String(repeating: "a", count: 64), to: recipient, recipientNickname: "peer", messageID: "msg-1")

        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.messageID, "msg-1")
        XCTAssertEqual(envelope.recipientPeerID, recipient.id)
    }

    @MainActor
    func testRoutesViaWiFiWhenMeshIsUnreachableButWiFiPeerExists() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 16),
            wifiTransport: wifi
        )

        router.sendPrivate(String(repeating: "b", count: 64), to: recipient, recipientNickname: "peer", messageID: "msg-wifi-unreachable")

        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
    }

    @MainActor
    func testFallsBackToMeshWhenWiFiSendFails() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.sendError = SampleError.failed
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 16),
            wifiTransport: wifi
        )

        router.sendPrivate(String(repeating: "a", count: 64), to: recipient, recipientNickname: "peer", messageID: "msg-2")

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 1)
        XCTAssertEqual(mesh.sentPrivateMessages[0].messageID, "msg-2")
    }

    @MainActor
    func testFallsBackFromWiFiPrivateRouteWhenPeerLacksPMCapability() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["ack"], for: recipient.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 16),
            wifiTransport: wifi
        )

        router.sendPrivate(String(repeating: "a", count: 64), to: recipient, recipientNickname: "peer", messageID: "msg-no-pm-cap")

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 1)
        XCTAssertEqual(mesh.sentPrivateMessages[0].messageID, "msg-no-pm-cap")
    }

    @MainActor
    func testPostsNotificationWhenWiFiPrivateEnvelopeReceivedForLocalPeer() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "receives WiFi envelope notification")
        var receivedEnvelope: WiFiDirectPrivateEnvelope?
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { note in
            receivedEnvelope = note.userInfo?[WiFiDirectNotificationUserInfoKey.envelope] as? WiFiDirectPrivateEnvelope
            expect.fulfill()
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-1",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "msg-3",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(receivedEnvelope?.messageID, "msg-3")
        XCTAssertEqual(receivedEnvelope?.recipientPeerID, mesh.myPeerID.id)
    }

    @MainActor
    func testDeduplicatesIncomingWiFiPrivateEnvelopeByMessageIDAndSender() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "receives only one deduped private envelope")
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            count += 1
            if count == 1 {
                expect.fulfill()
            }
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-1",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "msg-dedup-private",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testDoesNotPostNotificationForEnvelopeTargetingDifferentPeer() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive notification")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-1",
            recipientPeerID: "not-self",
            recipientNickname: "other",
            messageID: "msg-4",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testDoesNotPostNotificationForPrivateEnvelopeSenderMismatch() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive sender-mismatch private notification")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "claimed-peer",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "msg-sender-mismatch-private",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "actual-peer")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testOutboxIsCappedPerPeerWhenNoRouteAvailable() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 16),
            wifiTransport: wifi
        )

        let cap = TransportConfig.messageRouterOutboxPerPeerCap
        for idx in 0..<(cap + 25) {
            router.sendPrivate("msg-\(idx)", to: recipient, recipientNickname: "peer", messageID: "mid-\(idx)")
        }

        XCTAssertEqual(router.queuedMessageCount(for: recipient), cap)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
    }

    @MainActor
    func testWiFiPeerUpdateFlushesQueuedOutboxMessages() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = true
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("queued message body", to: recipient, recipientNickname: "peer", messageID: "mid-queued-wifi")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 1)
        XCTAssertEqual(backend.sentPayloads.count, 0)

        let expect = expectation(description: "queued outbox flushed when WiFi peer appears")
        backend.setCapabilities(["pm", "ack"], for: recipient.id)
        backend.setPeers([recipient.id])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
        XCTAssertEqual(backend.sentPayloads.count, 1)
    }

    @MainActor
    func testWiFiAvailabilityChangeFlushesQueuedOutboxMessages() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("queued message body", to: recipient, recipientNickname: "peer", messageID: "mid-queued-wifi-availability")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 1)
        XCTAssertEqual(backend.sentPayloads.count, 0)

        backend.setCapabilities(["pm", "ack"], for: recipient.id)
        backend.setPeers([recipient.id])

        let expect = expectation(description: "queued outbox flushed when WiFi availability returns")
        backend.simulateAvailability(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
        XCTAssertEqual(backend.sentPayloads.count, 1)
    }

    @MainActor
    func testFavoriteStatusBroadcastFlushesOutboxWhenNoSpecificPeerProvided() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = true
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setCapabilities(["pm", "ack"], for: recipient.id)
        backend.setPeers([recipient.id])

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("queued message body", to: recipient, recipientNickname: "peer", messageID: "mid-fav-flush")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)

        // Force queued state by temporarily making WiFi unavailable.
        backend.isAvailable = false
        router.sendPrivate("queued message body 2", to: recipient, recipientNickname: "peer", messageID: "mid-fav-flush-2")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 1)

        backend.isAvailable = true
        let expect = expectation(description: "favorite status change triggers flushAll")
        NotificationCenter.default.post(name: .favoriteStatusChanged, object: nil, userInfo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
        XCTAssertEqual(backend.sentPayloads.count, 2)
    }

    @MainActor
    func testPrunesExpiredOutboxMessagesBeforeFlush() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        var now = Date()
        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi,
            nowProvider: { now }
        )

        router.sendPrivate("queued/expiring", to: recipient, recipientNickname: "peer", messageID: "mid-expire-1")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 1)

        now = now.addingTimeInterval(TransportConfig.messageRouterOutboxMessageMaxAgeSeconds + 1)
        router.flushOutbox(for: recipient)

        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
    }

    @MainActor
    func testRoutesReadReceiptViaWiFiWhenPeerIsAvailable() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        let receipt = ReadReceipt(originalMessageID: "mid-read-1", readerID: mesh.myPeerID.id, readerNickname: "me")
        router.sendReadReceipt(receipt, to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectAckEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.ackType, .read)
        XCTAssertEqual(envelope.messageID, "mid-read-1")
        XCTAssertTrue(mesh.sentReadReceipts.isEmpty)
    }

    @MainActor
    func testRoutesDeliveryAckViaWiFiWhenPeerIsAvailable() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendDeliveryAck("mid-delivered-1", to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectAckEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.ackType, .delivered)
        XCTAssertEqual(envelope.messageID, "mid-delivered-1")
        XCTAssertTrue(mesh.sentDeliveryAcks.isEmpty)
    }

    @MainActor
    func testPostsNotificationForIncomingWiFiAckEnvelope() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "receives WiFi ack envelope notification")
        var receivedEnvelope: WiFiDirectAckEnvelope?
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { note in
            receivedEnvelope = note.userInfo?[WiFiDirectNotificationUserInfoKey.ackEnvelope] as? WiFiDirectAckEnvelope
            expect.fulfill()
        }

        let envelope = WiFiDirectAckEnvelope(
            ackType: .read,
            senderPeerID: "peer-1",
            recipientPeerID: mesh.myPeerID.id,
            messageID: "mid-read-2",
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(receivedEnvelope?.messageID, "mid-read-2")
        XCTAssertEqual(receivedEnvelope?.ackType, .read)
    }

    @MainActor
    func testDoesNotPostNotificationForAckEnvelopeSenderMismatch() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive sender-mismatch ack notification")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectAckEnvelope(
            ackType: .delivered,
            senderPeerID: "claimed-peer",
            recipientPeerID: mesh.myPeerID.id,
            messageID: "mid-sender-mismatch-ack",
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "actual-peer")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testDeduplicatesIncomingWiFiAckEnvelopeByTypeSenderAndMessageID() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "receives only one deduped ack envelope")
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            count += 1
            if count == 1 {
                expect.fulfill()
            }
        }

        let envelope = WiFiDirectAckEnvelope(
            ackType: .delivered,
            senderPeerID: "peer-1",
            recipientPeerID: mesh.myPeerID.id,
            messageID: "mid-dedup-ack",
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testIgnoresOversizedIncomingWiFiPayload() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expectPrivate = expectation(description: "no oversized private notification")
        expectPrivate.isInverted = true
        let privateToken = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expectPrivate.fulfill()
        }

        let expectAck = expectation(description: "no oversized ack notification")
        expectAck.isInverted = true
        let ackToken = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expectAck.fulfill()
        }

        let oversizedData = Data(repeating: 0x41, count: TransportConfig.messageRouterInboundWiFiPayloadMaxBytes + 1)
        backend.simulateIncoming(oversizedData, from: "peer-1")

        wait(for: [expectPrivate, expectAck], timeout: 0.2)
        NotificationCenter.default.removeObserver(privateToken)
        NotificationCenter.default.removeObserver(ackToken)
    }

    @MainActor
    func testIgnoresIncomingWiFiPrivateEnvelopeWithOversizedContent() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive oversized-content private envelope")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-1",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-oversized-content",
            content: String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testIgnoresIncomingWiFiAckEnvelopeWithEmptyMessageID() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive ack with empty message id")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectAckEnvelope(
            ackType: .read,
            senderPeerID: "peer-1",
            recipientPeerID: mesh.myPeerID.id,
            messageID: "   ",
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testFallsBackFromWiFiReadReceiptWhenPeerLacksAckCapability() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        let receipt = ReadReceipt(originalMessageID: "mid-read-cap", readerID: mesh.myPeerID.id, readerNickname: "me")
        router.sendReadReceipt(receipt, to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentReadReceipts.count, 1)
        XCTAssertEqual(mesh.sentReadReceipts[0].receipt.originalMessageID, "mid-read-cap")
    }

    @MainActor
    func testIgnoresIncomingWiFiPrivateEnvelopeWithUnsupportedVersion() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive private notification")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let payloadObject: [String: Any] = [
            "version": 2,
            "messageType": "private",
            "senderPeerID": "peer-1",
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-v2-private",
            "content": "hello",
            "createdAtMs": 1_700_000_000_000 as UInt64
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testIgnoresIncomingWiFiAckEnvelopeWithUnsupportedVersion() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive ack notification")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let payloadObject: [String: Any] = [
            "version": 2,
            "messageType": "ack",
            "ackType": "read",
            "senderPeerID": "peer-1",
            "recipientPeerID": mesh.myPeerID.id,
            "messageID": "mid-v2-ack",
            "senderNickname": "peer",
            "createdAtMs": 1_700_000_000_000 as UInt64
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }
}
