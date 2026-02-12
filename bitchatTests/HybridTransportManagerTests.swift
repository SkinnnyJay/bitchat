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
        private var reachablePeers: Set<PeerID> = []

        private(set) var sentPrivateMessages: [(content: String, peerID: PeerID, nickname: String, messageID: String)] = []
        private(set) var startServicesCallCount = 0
        private(set) var stopServicesCallCount = 0

        func setReachable(_ peerID: PeerID, isReachable: Bool) {
            if isReachable {
                reachablePeers.insert(peerID)
            } else {
                reachablePeers.remove(peerID)
            }
        }

        func setNickname(_ nickname: String) {
            myNickname = nickname
        }

        func startServices() { startServicesCallCount += 1 }
        func stopServices() { stopServicesCallCount += 1 }
        func emergencyDisconnectAll() {}
        func isPeerConnected(_ peerID: PeerID) -> Bool { false }
        func isPeerReachable(_ peerID: PeerID) -> Bool { reachablePeers.contains(peerID) }
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
        private(set) var startDiscoveryCallCount = 0
        private(set) var stopDiscoveryCallCount = 0

        required init(localPeerID: String?) {}

        func startDiscovery() { startDiscoveryCallCount += 1 }
        func stopDiscovery() { stopDiscoveryCallCount += 1 }
        func resetState() {}

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
    func testSendPrivateRoutesViaWiFiWithInvalidRecipientNicknameSanitized() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let invalidNickname = String(repeating: "z", count: InputValidator.Limits.maxNicknameLength + 10)
        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: invalidNickname, messageID: "mid-invalid-recipient-nick")

        XCTAssertEqual(route, .wifiDirect)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientNickname, "user")
    }

    @MainActor
    func testStartAndStopLifecycleForwardedToMeshAndWiFiTransports() {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)

        manager.start()
        manager.start()
        manager.stop()
        manager.stop()

        XCTAssertEqual(mesh.startServicesCallCount, 1)
        XCTAssertEqual(mesh.stopServicesCallCount, 1)
        XCTAssertEqual(backend.startDiscoveryCallCount, 1)
        XCTAssertEqual(backend.stopDiscoveryCallCount, 1)
    }

    @MainActor
    func testDeinitStopsRunningHybridManager() {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        var manager: HybridTransportManager? = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)

        manager?.start()
        XCTAssertEqual(mesh.startServicesCallCount, 1)
        XCTAssertEqual(backend.startDiscoveryCallCount, 1)

        manager = nil

        XCTAssertEqual(mesh.stopServicesCallCount, 1)
        XCTAssertEqual(backend.stopDiscoveryCallCount, 1)
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
    func testSendPrivateSanitizesRecipientNicknameOnMeshFallback() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["ack"], for: recipient.id) // force mesh fallback

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let invalidNickname = String(repeating: "x", count: InputValidator.Limits.maxNicknameLength + 10)
        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: invalidNickname, messageID: "mid-mesh-sanitize")

        XCTAssertEqual(route, .mesh)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 1)
        XCTAssertEqual(mesh.sentPrivateMessages[0].nickname, "user")
    }

    @MainActor
    func testSendPrivateDropsWhenMessageIDIsEmptyForWiFiPath() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: "   ")

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateDropsWhenMessageIDExceedsLimitForWiFiPath() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let oversizedMessageID = String(repeating: "m", count: InputValidator.Limits.maxMessageIDLength + 1)
        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: oversizedMessageID)

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateDropsWhenMessageIDHasSurroundingWhitespaceForWiFiPath() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let whitespaceMessageID = "  mid-hybrid-space  "
        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: whitespaceMessageID)

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateDropsWhenMessageIDContainsInternalWhitespace() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: "mid with-space")

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateDropsInvalidMessageIDEvenWhenMeshReachable() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let route = manager.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: "  invalid  ")

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateDropsWhenRecipientPeerIDIsInvalid() {
        let invalidRecipient = PeerID(str: "invalid peer id with spaces")
        let mesh = MockTransport()
        mesh.setReachable(invalidRecipient, isReachable: true)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([invalidRecipient.id])
        backend.setCapabilities(["pm"], for: invalidRecipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let route = manager.sendPrivate("hello", to: invalidRecipient, recipientNickname: "peer", messageID: "mid-invalid-peer")

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateDropsWhenContentExceedsMaxMessageLengthForWiFiPath() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let oversized = String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        let route = manager.sendPrivate(oversized, to: recipient, recipientNickname: "peer", messageID: "mid-oversized")

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateDropsOversizedContentEvenWhenMeshReachable() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let oversized = String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        let route = manager.sendPrivate(oversized, to: recipient, recipientNickname: "peer", messageID: "mid-oversized-reachable")

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateFallsBackToWiFiWhenMeshUnreachableEvenBelowThreshold() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 10_000) // intentionally above message size
        )

        let route = manager.sendPrivate("tiny", to: recipient, recipientNickname: "peer", messageID: "mid-fallback-wifi")

        XCTAssertEqual(route, .wifiDirect)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
    }

    @MainActor
    func testSendPrivateRoutesPacketOversizedPayloadViaWiFiEvenBelowThreshold() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm"], for: recipient.id)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 10_000)
        )

        let oversizedForPacket = String(repeating: "x", count: TransportConfig.privateMessagePacketContentMaxBytes + 1)
        let route = manager.sendPrivate(oversizedForPacket, to: recipient, recipientNickname: "peer", messageID: "mid-packet-oversized")

        XCTAssertEqual(route, .wifiDirect)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
    }

    @MainActor
    func testSendPrivateDropsPacketOversizedPayloadWhenWiFiUnavailable() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 10_000)
        )

        let oversizedForPacket = String(repeating: "x", count: TransportConfig.privateMessagePacketContentMaxBytes + 1)
        let route = manager.sendPrivate(oversizedForPacket, to: recipient, recipientNickname: "peer", messageID: "mid-packet-oversized-drop")

        XCTAssertEqual(route, .dropped)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
    }

    @MainActor
    func testSendPrivateRoutesViaWiFiUsingBarePeerIDFromPrefixedRecipientID() throws {
        let recipientBare = "peerabc000000000"
        let recipientPrefixed = PeerID(str: "mesh:\(recipientBare)")
        let mesh = MockTransport()
        mesh.setReachable(recipientPrefixed, isReachable: false)
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipientBare])
        backend.setCapabilities(["pm"], for: recipientBare)

        let manager = HybridTransportManager(
            meshTransport: mesh,
            wifiTransport: wifi,
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1)
        )

        let route = manager.sendPrivate("hello", to: recipientPrefixed, recipientNickname: "peer", messageID: "mid-prefixed")

        XCTAssertEqual(route, .wifiDirect)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientPeerID, recipientBare)
        XCTAssertEqual(backend.sentPayloads[0].1, recipientBare)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
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
    func testRejectsInboundPrivateEnvelopeWithInvalidSenderID() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let invalidSenderID = "invalid peer id"
        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: invalidSenderID,
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-invalid-sender",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: invalidSenderID)

        let expect = expectation(description: "invalid sender envelope ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
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

    @MainActor
    func testDeduplicatesInboundPrivateEnvelopesAcrossFullAndShortSenderIDs() throws {
        let senderNoise = Data(repeating: 0x2F, count: 32)
        let senderFull = PeerID(hexData: senderNoise)
        let senderShort = PeerID(publicKey: senderNoise)

        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let envelopeFull = WiFiDirectPrivateEnvelope(
            senderPeerID: senderFull.id,
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-cross-dedup",
            content: "hello"
        )
        let envelopeShort = WiFiDirectPrivateEnvelope(
            senderPeerID: senderShort.id,
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-cross-dedup",
            content: "hello"
        )
        backend.simulateIncoming(try JSONEncoder().encode(envelopeFull), from: senderShort.id)
        backend.simulateIncoming(try JSONEncoder().encode(envelopeShort), from: senderFull.id)

        let expect = expectation(description: "cross-id duplicate envelopes settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, 1)
        XCTAssertEqual(delegate.receivedEnvelopes[0].messageID, "mid-cross-dedup")
    }

    @MainActor
    func testRateLimitsInboundPrivateEnvelopesPerSender() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi, nowProvider: { fixedNow })
        let delegate = MockDelegate()
        manager.delegate = delegate

        let maxEvents = TransportConfig.messageRouterInboundWiFiSenderRateMaxEvents
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<(maxEvents + 5) {
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "private",
                "senderPeerID": "peer-rate",
                "recipientPeerID": mesh.myPeerID.id,
                "recipientNickname": "self",
                "messageID": "mid-rate-\(idx)",
                "content": "hello",
                "createdAtMs": createdAtMs
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: "peer-rate")
        }

        let expect = expectation(description: "rate-limited hybrid envelopes settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, maxEvents)
    }

    @MainActor
    func testHybridRateLimitTreatsFullAndShortSenderIDsAsSameSender() throws {
        let noiseKey = Data(repeating: 0x55, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi, nowProvider: { fixedNow })
        let delegate = MockDelegate()
        manager.delegate = delegate

        let maxEvents = TransportConfig.messageRouterInboundWiFiSenderRateMaxEvents
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<(maxEvents + 3) {
            let useFull = idx % 2 == 0
            let claimedSender = useFull ? senderFull.id : senderShort.id
            let observedSender = useFull ? senderShort.id : senderFull.id
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "private",
                "senderPeerID": claimedSender,
                "recipientPeerID": mesh.myPeerID.id,
                "recipientNickname": "self",
                "messageID": "mid-rate-cross-\(idx)",
                "content": "hello",
                "createdAtMs": createdAtMs
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: observedSender)
        }

        let expect = expectation(description: "hybrid cross-id rate limit settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, maxEvents)
    }

    @MainActor
    func testHybridRateLimiterCapsTrackedSenderBuckets() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi, nowProvider: { fixedNow })
        let delegate = MockDelegate()
        manager.delegate = delegate

        let senderCap = TransportConfig.messageRouterInboundWiFiSenderRateMaxTrackedSenders
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<senderCap {
            let sender = "hybrid-sender-\(idx)"
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "private",
                "senderPeerID": sender,
                "recipientPeerID": mesh.myPeerID.id,
                "recipientNickname": "self",
                "messageID": "mid-hybrid-\(idx)",
                "content": "hello",
                "createdAtMs": createdAtMs
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: sender)
        }

        let overflowSender = "hybrid-sender-overflow"
        let overflowPayloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": overflowSender,
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-hybrid-overflow",
            "content": "hello",
            "createdAtMs": createdAtMs
        ]
        let overflowPayload = try JSONSerialization.data(withJSONObject: overflowPayloadObject, options: [])
        backend.simulateIncoming(overflowPayload, from: overflowSender)

        let expect = expectation(description: "hybrid sender-bucket cap settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, senderCap)
    }

    @MainActor
    func testHybridRateLimiterIgnoresBlankSenderIDsForBucketCap() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi, nowProvider: { fixedNow })
        let delegate = MockDelegate()
        manager.delegate = delegate

        let senderCap = TransportConfig.messageRouterInboundWiFiSenderRateMaxTrackedSenders
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<(senderCap - 1) {
            let sender = "hybrid-cap-\(idx)"
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "private",
                "senderPeerID": sender,
                "recipientPeerID": mesh.myPeerID.id,
                "recipientNickname": "self",
                "messageID": "mid-hybrid-cap-\(idx)",
                "content": "hello",
                "createdAtMs": createdAtMs
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: sender)
        }

        let blankPayloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": "   ",
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-hybrid-cap-blank",
            "content": "hello",
            "createdAtMs": createdAtMs
        ]
        let blankPayload = try JSONSerialization.data(withJSONObject: blankPayloadObject, options: [])
        backend.simulateIncoming(blankPayload, from: "   ")

        let finalSender = "hybrid-cap-final"
        let finalPayloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": finalSender,
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-hybrid-cap-final",
            "content": "hello",
            "createdAtMs": createdAtMs
        ]
        let finalPayload = try JSONSerialization.data(withJSONObject: finalPayloadObject, options: [])
        backend.simulateIncoming(finalPayload, from: finalSender)

        let expect = expectation(description: "blank sender does not consume hybrid sender bucket capacity")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, senderCap)
    }

    @MainActor
    func testHybridRateLimiterIgnoresInvalidSenderIDsForBucketCap() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi, nowProvider: { fixedNow })
        let delegate = MockDelegate()
        manager.delegate = delegate

        let senderCap = TransportConfig.messageRouterInboundWiFiSenderRateMaxTrackedSenders
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<(senderCap - 1) {
            let sender = "hybrid-invalid-cap-\(idx)"
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "private",
                "senderPeerID": sender,
                "recipientPeerID": mesh.myPeerID.id,
                "recipientNickname": "self",
                "messageID": "mid-hybrid-invalid-cap-\(idx)",
                "content": "hello",
                "createdAtMs": createdAtMs
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: sender)
        }

        let invalidSender = "invalid peer id"
        let invalidPayloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": invalidSender,
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-hybrid-invalid-sender",
            "content": "hello",
            "createdAtMs": createdAtMs
        ]
        let invalidPayload = try JSONSerialization.data(withJSONObject: invalidPayloadObject, options: [])
        backend.simulateIncoming(invalidPayload, from: invalidSender)

        let finalSender = "hybrid-invalid-cap-final"
        let finalPayloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": finalSender,
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-hybrid-invalid-cap-final",
            "content": "hello",
            "createdAtMs": createdAtMs
        ]
        let finalPayload = try JSONSerialization.data(withJSONObject: finalPayloadObject, options: [])
        backend.simulateIncoming(finalPayload, from: finalSender)

        let expect = expectation(description: "invalid sender does not consume hybrid sender bucket capacity")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receivedEnvelopes.count, senderCap)
    }

    @MainActor
    func testHybridRateLimiterRejectsOversizedSenderID() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi, nowProvider: { fixedNow })
        let delegate = MockDelegate()
        manager.delegate = delegate

        let oversizedSenderID = String(repeating: "a", count: TransportConfig.messageRouterInboundWiFiSenderIDMaxBytes + 1)
        let payloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": oversizedSenderID,
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-hybrid-oversized-sender",
            "content": "hello",
            "createdAtMs": UInt64(fixedNow.timeIntervalSince1970 * 1000)
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
        backend.simulateIncoming(payload, from: oversizedSenderID)

        let expect = expectation(description: "oversized sender dropped by hybrid rate limiter")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
    }

    @MainActor
    func testRejectsInboundPrivateEnvelopeWhenPayloadExceedsMaxBytes() {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let oversizedPayload = Data(repeating: 0x41, count: TransportConfig.messageRouterInboundWiFiPayloadMaxBytes + 1)
        backend.simulateIncoming(oversizedPayload, from: "peer-oversized")

        let expect = expectation(description: "oversized envelope should be ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
    }

    @MainActor
    func testRejectsInboundPrivateEnvelopeWhenMessageIDIsEmpty() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-empty-id",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "   ",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-empty-id")

        let expect = expectation(description: "empty-message-id envelope ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
    }

    @MainActor
    func testRejectsInboundPrivateEnvelopeWhenMessageIDExceedsLimit() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-long-id",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: String(repeating: "x", count: InputValidator.Limits.maxMessageIDLength + 1),
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-long-id")

        let expect = expectation(description: "oversized-message-id envelope ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
    }

    @MainActor
    func testRejectsInboundPrivateEnvelopeWhenMessageIDHasSurroundingWhitespace() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-space-id",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "  mid-space-id  ",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-space-id")

        let expect = expectation(description: "surrounding-whitespace message id ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
    }

    @MainActor
    func testRejectsInboundPrivateEnvelopeWhenContentExceedsMaxMessageLength() throws {
        let mesh = MockTransport()
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let manager = HybridTransportManager(meshTransport: mesh, wifiTransport: wifi)
        let delegate = MockDelegate()
        manager.delegate = delegate

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-long-content",
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-long-content",
            content: String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-long-content")

        let expect = expectation(description: "oversized-content envelope ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(delegate.receivedEnvelopes.isEmpty)
    }
}
