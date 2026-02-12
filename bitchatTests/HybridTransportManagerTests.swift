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
    func testSendPrivateFallsBackToMeshWhenMessageIDIsEmptyForWiFiPath() {
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

        XCTAssertEqual(route, .mesh)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 1)
    }

    @MainActor
    func testSendPrivateFallsBackToMeshWhenContentExceedsMaxMessageLengthForWiFiPath() {
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

        XCTAssertEqual(route, .mesh)
        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 1)
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
