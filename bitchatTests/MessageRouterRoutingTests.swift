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
        private(set) var sentFavoriteNotifications: [(peerID: PeerID, isFavorite: Bool)] = []

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
        func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
            sentFavoriteNotifications.append((peerID, isFavorite))
        }
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
        func resetState() {}

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
    func testRoutesPrivateMessageViaWiFiWithInvalidRecipientNicknameSanitized() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 16),
            wifiTransport: wifi
        )

        let invalidNickname = String(repeating: "y", count: InputValidator.Limits.maxNicknameLength + 10)
        router.sendPrivate(
            String(repeating: "a", count: 64),
            to: recipient,
            recipientNickname: invalidNickname,
            messageID: "msg-invalid-recipient-nick"
        )

        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientNickname, "user")
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
    func testDropsPrivateMessageWhenContentExceedsLimit() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1),
            wifiTransport: wifi
        )

        let oversized = String(repeating: "x", count: InputValidator.Limits.maxMessageLength + 1)
        router.sendPrivate(oversized, to: recipient, recipientNickname: "peer", messageID: "msg-oversized-outbound")

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
    }

    @MainActor
    func testSanitizesRecipientNicknameWhenRoutingViaMesh() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1),
            wifiTransport: wifi
        )

        let invalidNickname = String(repeating: "n", count: InputValidator.Limits.maxNicknameLength + 10)
        router.sendPrivate("hello", to: recipient, recipientNickname: invalidNickname, messageID: "mid-mesh-nick-sanitize")

        XCTAssertEqual(mesh.sentPrivateMessages.count, 1)
        XCTAssertEqual(mesh.sentPrivateMessages[0].nickname, "user")
    }

    @MainActor
    func testDropsPrivateMessageWhenMessageIDExceedsLimit() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1),
            wifiTransport: wifi
        )

        let oversizedMessageID = String(repeating: "m", count: InputValidator.Limits.maxMessageIDLength + 1)
        router.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: oversizedMessageID)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
    }

    @MainActor
    func testDropsPrivateMessageWhenMessageIDHasSurroundingWhitespace() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1),
            wifiTransport: wifi
        )

        let whitespaceMessageID = "  mid-surrounding-space  "
        router.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: whitespaceMessageID)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
    }

    @MainActor
    func testDropsPrivateMessageWithInvalidMessageIDWhenNoRouteAvailable() {
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
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 1),
            wifiTransport: wifi
        )

        let invalidMessageID = "  bad-id  "
        router.sendPrivate("hello", to: recipient, recipientNickname: "peer", messageID: invalidMessageID)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentPrivateMessages.count, 0)
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
    }

    @MainActor
    func testRoutesViaWiFiBelowThresholdWhenNoOtherRouteExists() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = true
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 10_000), // force below-threshold
            wifiTransport: wifi
        )

        router.sendPrivate("small", to: recipient, recipientNickname: "peer", messageID: "msg-small-wifi-fallback")

        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
    }

    @MainActor
    func testRoutesViaWiFiUsingShortDerivedPeerIDForNoiseKeyRecipient() throws {
        let noiseKey = Data(repeating: 0x42, count: 32)
        let recipientFull = PeerID(hexData: noiseKey)
        let recipientShort = PeerID(publicKey: noiseKey)
        let mesh = MockTransport()
        mesh.setReachable(recipientFull, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = true
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipientShort.id])
        backend.setCapabilities(["pm", "ack"], for: recipientShort.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("noise-key-recipient", to: recipientFull, recipientNickname: "peer", messageID: "msg-noise-full")

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientPeerID, recipientShort.id)
        XCTAssertEqual(backend.sentPayloads[0].1, recipientShort.id)
    }

    @MainActor
    func testRoutesViaWiFiUsingBarePeerIDFromPrefixedRecipientID() throws {
        let recipientBare = "peerabc000000000"
        let recipientPrefixed = PeerID(str: "mesh:\(recipientBare)")
        let mesh = MockTransport()
        mesh.setReachable(recipientPrefixed, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = true
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipientBare])
        backend.setCapabilities(["pm", "ack"], for: recipientBare)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("prefixed recipient", to: recipientPrefixed, recipientNickname: "peer", messageID: "msg-prefixed-peer")

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientPeerID, recipientBare)
        XCTAssertEqual(backend.sentPayloads[0].1, recipientBare)
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
    func testDeduplicatesIncomingWiFiPrivateEnvelopeAcrossFullAndShortSenderIDs() throws {
        let noiseKey = Data(repeating: 0x33, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "dedups across full/short sender IDs")
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

        let envelopeFull = WiFiDirectPrivateEnvelope(
            senderPeerID: senderFull.id,
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-cross-id-private",
            content: "hello"
        )
        let envelopeShort = WiFiDirectPrivateEnvelope(
            senderPeerID: senderShort.id,
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "mid-cross-id-private",
            content: "hello"
        )
        backend.simulateIncoming(try JSONEncoder().encode(envelopeFull), from: senderShort.id)
        backend.simulateIncoming(try JSONEncoder().encode(envelopeShort), from: senderFull.id)

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
    func testAcceptsPrivateEnvelopeWhenSenderUsesFullNoiseIDAndTransportUsesShortID() throws {
        let noiseKey = Data(repeating: 0x7A, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "accepts sender full-id over short transport identity")
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: senderFull.id,
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "msg-sender-full-private",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: senderShort.id)

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testAcceptsPrivateEnvelopeWhenSenderUsesShortIDAndTransportUsesFullNoiseID() throws {
        let noiseKey = Data(repeating: 0x5B, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "accepts sender short-id over full transport identity")
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: senderShort.id,
            recipientPeerID: mesh.myPeerID.id,
            recipientNickname: "self",
            messageID: "msg-sender-short-private",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: senderFull.id)

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testAcceptsPrivateEnvelopeWhenRecipientUsesFullNoiseIDAndLocalUsesShortID() throws {
        let localNoise = Data(repeating: 0x19, count: 32)
        let localShort = PeerID(publicKey: localNoise)
        let localFull = PeerID(hexData: localNoise)

        let mesh = MockTransport()
        mesh.myPeerID = localShort
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "accepts recipient full-id with local short-id")
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: "peer-1",
            recipientPeerID: localFull.id,
            recipientNickname: "self",
            messageID: "msg-recipient-full-private",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 1.0)
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
    func testFavoriteStatusWithFalseKeyUpdateFlagDoesNotMigrateOutbox() {
        let oldKey = Data(repeating: 0x71, count: 32)
        let newKey = Data(repeating: 0x72, count: 32)
        let oldPeer = PeerID(publicKey: oldKey)
        let newPeer = PeerID(publicKey: newKey)

        let mesh = MockTransport()
        mesh.setReachable(oldPeer, isReachable: false)
        mesh.setReachable(newPeer, isReachable: false)
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

        router.sendPrivate("queued-for-old", to: oldPeer, recipientNickname: "peer", messageID: "mid-old-key-false-update")
        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 1)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), 0)

        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": newKey,
                "oldPeerPublicKey": oldKey,
                "isKeyUpdate": false
            ]
        )

        let expect = expectation(description: "non-key-update notification settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 1)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), 0)
        XCTAssertEqual(backend.sentPayloads.count, 0)
    }

    @MainActor
    func testFavoriteKeyUpdateMigratesOutboxFromOldToNewPeerIDAndFlushes() {
        let oldKey = Data(repeating: 0x11, count: 32)
        let newKey = Data(repeating: 0x22, count: 32)
        let oldPeer = PeerID(publicKey: oldKey)
        let newPeer = PeerID(publicKey: newKey)

        let mesh = MockTransport()
        mesh.setReachable(oldPeer, isReachable: false)
        mesh.setReachable(newPeer, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setCapabilities(["pm", "ack"], for: newPeer.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("queued-for-old", to: oldPeer, recipientNickname: "peer", messageID: "mid-old-key")
        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 1)

        backend.isAvailable = true
        backend.setPeers([newPeer.id])

        let expect = expectation(description: "outbox migrated and flushed on key update")
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": newKey,
                "oldPeerPublicKey": oldKey,
                "isKeyUpdate": true
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 0)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), 0)
        XCTAssertEqual(backend.sentPayloads.count, 1)
    }

    @MainActor
    func testFavoriteKeyUpdateSkipsMigrationForExpiredQueuedMessages() {
        let oldKey = Data(repeating: 0x41, count: 32)
        let newKey = Data(repeating: 0x42, count: 32)
        let oldPeer = PeerID(publicKey: oldKey)
        let newPeer = PeerID(publicKey: newKey)

        let mesh = MockTransport()
        mesh.setReachable(oldPeer, isReachable: false)
        mesh.setReachable(newPeer, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setCapabilities(["pm", "ack"], for: newPeer.id)

        var now = Date()
        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi,
            nowProvider: { now }
        )

        router.sendPrivate("queued-expiring", to: oldPeer, recipientNickname: "peer", messageID: "mid-old-expire")
        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 1)
        now = now.addingTimeInterval(TransportConfig.messageRouterOutboxMessageMaxAgeSeconds + 1)

        backend.isAvailable = true
        backend.setPeers([newPeer.id])

        let expect = expectation(description: "expired queue skipped during key update migration")
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": newKey,
                "oldPeerPublicKey": oldKey,
                "isKeyUpdate": true
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 0)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), 0)
        XCTAssertEqual(backend.sentPayloads.count, 0)
    }

    @MainActor
    func testFavoriteKeyUpdateMigrationRespectsOutboxCap() {
        let oldKey = Data(repeating: 0x51, count: 32)
        let newKey = Data(repeating: 0x52, count: 32)
        let oldPeer = PeerID(publicKey: oldKey)
        let newPeer = PeerID(publicKey: newKey)

        let mesh = MockTransport()
        mesh.setReachable(oldPeer, isReachable: false)
        mesh.setReachable(newPeer, isReachable: false)
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

        let cap = TransportConfig.messageRouterOutboxPerPeerCap
        for idx in 0..<(cap + 10) {
            router.sendPrivate("old-\(idx)", to: oldPeer, recipientNickname: "peer", messageID: "mid-old-cap-\(idx)")
        }
        for idx in 0..<(cap + 10) {
            router.sendPrivate("new-\(idx)", to: newPeer, recipientNickname: "peer", messageID: "mid-new-cap-\(idx)")
        }

        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), cap)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), cap)

        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": newKey,
                "oldPeerPublicKey": oldKey,
                "isKeyUpdate": true
            ]
        )

        let expect = expectation(description: "migration cap enforcement settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 0)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), cap)
    }

    @MainActor
    func testFavoriteKeyUpdateMigrationPrefersExistingDestinationMessageOnDuplicateID() throws {
        let oldKey = Data(repeating: 0x61, count: 32)
        let newKey = Data(repeating: 0x62, count: 32)
        let oldPeer = PeerID(publicKey: oldKey)
        let newPeer = PeerID(publicKey: newKey)

        let mesh = MockTransport()
        mesh.setReachable(oldPeer, isReachable: false)
        mesh.setReachable(newPeer, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setCapabilities(["pm", "ack"], for: newPeer.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("old-content", to: oldPeer, recipientNickname: "peer", messageID: "mid-dup-migrate")
        router.sendPrivate("new-content", to: newPeer, recipientNickname: "peer", messageID: "mid-dup-migrate")
        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 1)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), 1)

        backend.isAvailable = true
        backend.setPeers([newPeer.id])

        let expect = expectation(description: "migration duplicate resolution settles")
        NotificationCenter.default.post(
            name: .favoriteStatusChanged,
            object: nil,
            userInfo: [
                "peerPublicKey": newKey,
                "oldPeerPublicKey": oldKey,
                "isKeyUpdate": true
            ]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: oldPeer), 0)
        XCTAssertEqual(router.queuedMessageCount(for: newPeer), 0)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.messageID, "mid-dup-migrate")
        XCTAssertEqual(envelope.content, "new-content")
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
    func testQueuedMessageCountPrunesExpiredOutboxMessages() {
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

        router.sendPrivate("queued", to: recipient, recipientNickname: "peer", messageID: "mid-expired-count")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 1)

        now = now.addingTimeInterval(TransportConfig.messageRouterOutboxMessageMaxAgeSeconds + 1)
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
    }

    @MainActor
    func testFlushOutboxUsesWiFiFallbackBelowThresholdWhenNoOtherRouteExists() {
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
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 10_000), // force below-threshold
            wifiTransport: wifi
        )

        router.sendPrivate("tiny", to: recipient, recipientNickname: "peer", messageID: "mid-small-queued")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 1)

        backend.setCapabilities(["pm", "ack"], for: recipient.id)
        backend.setPeers([recipient.id])
        backend.simulateAvailability(true)

        let expect = expectation(description: "queued tiny message flushed by WiFi fallback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: recipient), 0)
        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentPrivateMessages.isEmpty)
    }

    @MainActor
    func testOutboxDeduplicatesQueuedMessageIDsPerPeer() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("old-content", to: recipient, recipientNickname: "peer", messageID: "mid-dup")
        router.sendPrivate("new-content", to: recipient, recipientNickname: "peer", messageID: "mid-dup")
        XCTAssertEqual(router.queuedMessageCount(for: recipient), 1)

        let expect = expectation(description: "deduped message flushed once")
        backend.setPeers([recipient.id])
        backend.simulateAvailability(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.messageID, "mid-dup")
        XCTAssertEqual(envelope.content, "new-content")
    }

    @MainActor
    func testOutboxNormalizesFullAndShortPeerIDsToSingleQueue() {
        let noiseKey = Data(repeating: 0x31, count: 32)
        let recipientFull = PeerID(hexData: noiseKey)
        let recipientShort = PeerID(publicKey: noiseKey)
        let mesh = MockTransport()
        mesh.setReachable(recipientFull, isReachable: false)
        mesh.setReachable(recipientShort, isReachable: false)
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

        router.sendPrivate("full-id-queued", to: recipientFull, recipientNickname: "peer", messageID: "mid-full")
        XCTAssertEqual(router.queuedMessageCount(for: recipientFull), 1)
        XCTAssertEqual(router.queuedMessageCount(for: recipientShort), 1)

        router.sendPrivate("short-id-queued", to: recipientShort, recipientNickname: "peer", messageID: "mid-short")
        XCTAssertEqual(router.queuedMessageCount(for: recipientFull), 2)
        XCTAssertEqual(router.queuedMessageCount(for: recipientShort), 2)
    }

    @MainActor
    func testFlushOutboxWithShortPeerIDSendsMessagesQueuedByFullPeerID() {
        let noiseKey = Data(repeating: 0x2B, count: 32)
        let recipientFull = PeerID(hexData: noiseKey)
        let recipientShort = PeerID(publicKey: noiseKey)
        let mesh = MockTransport()
        mesh.setReachable(recipientFull, isReachable: false)
        mesh.setReachable(recipientShort, isReachable: false)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setCapabilities(["pm", "ack"], for: recipientShort.id)

        let router = MessageRouter(
            mesh: mesh,
            nostr: nostr,
            routingPolicy: TransportRoutingPolicy(nostrPreferredPayloadBytes: 8_192),
            wifiRoutingPolicy: WiFiDirectRoutingPolicy(preferredPayloadBytes: 8),
            wifiTransport: wifi
        )

        router.sendPrivate("queued-by-full", to: recipientFull, recipientNickname: "peer", messageID: "mid-full-queue")
        XCTAssertEqual(router.queuedMessageCount(for: recipientShort), 1)

        backend.setPeers([recipientShort.id])
        backend.simulateAvailability(true)

        let expect = expectation(description: "full-id queued message flushed via short-id route")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(router.queuedMessageCount(for: recipientFull), 0)
        XCTAssertEqual(backend.sentPayloads.count, 1)
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
        XCTAssertEqual(envelope.senderNickname, "me")
        XCTAssertTrue(mesh.sentReadReceipts.isEmpty)
    }

    @MainActor
    func testRoutesReadReceiptViaWiFiWithInvalidNicknameSanitized() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        let invalidNickname = String(repeating: "x", count: InputValidator.Limits.maxNicknameLength + 10)
        let receipt = ReadReceipt(originalMessageID: "mid-read-2", readerID: mesh.myPeerID.id, readerNickname: invalidNickname)
        router.sendReadReceipt(receipt, to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectAckEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.ackType, .read)
        XCTAssertEqual(envelope.messageID, "mid-read-2")
        XCTAssertNil(envelope.senderNickname)
    }

    @MainActor
    func testDropsReadReceiptWhenMessageIDExceedsLimit() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        let oversizedMessageID = String(repeating: "r", count: InputValidator.Limits.maxMessageIDLength + 1)
        let receipt = ReadReceipt(originalMessageID: oversizedMessageID, readerID: mesh.myPeerID.id, readerNickname: "me")
        router.sendReadReceipt(receipt, to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentReadReceipts.count, 0)
    }

    @MainActor
    func testDropsReadReceiptWhenMessageIDIsEmpty() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        let receipt = ReadReceipt(originalMessageID: "   ", readerID: mesh.myPeerID.id, readerNickname: "me")
        router.sendReadReceipt(receipt, to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentReadReceipts.count, 0)
    }

    @MainActor
    func testRoutesDeliveryAckViaWiFiWhenPeerIsAvailable() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setNickname("sender-nick")
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
        XCTAssertEqual(envelope.senderNickname, "sender-nick")
        XCTAssertTrue(mesh.sentDeliveryAcks.isEmpty)
    }

    @MainActor
    func testRoutesDeliveryAckViaWiFiUsingShortDerivedPeerIDForNoiseKeyRecipient() throws {
        let noiseKey = Data(repeating: 0x24, count: 32)
        let recipientFull = PeerID(hexData: noiseKey)
        let recipientShort = PeerID(publicKey: noiseKey)
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipientShort.id])
        backend.setCapabilities(["pm", "ack"], for: recipientShort.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendDeliveryAck("mid-delivered-noise-full", to: recipientFull)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectAckEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientPeerID, recipientShort.id)
        XCTAssertEqual(backend.sentPayloads[0].1, recipientShort.id)
        XCTAssertTrue(mesh.sentDeliveryAcks.isEmpty)
    }

    @MainActor
    func testRoutesDeliveryAckViaWiFiUsingBarePeerIDFromPrefixedRecipientID() throws {
        let recipientBare = "peerabc000000000"
        let recipientPrefixed = PeerID(str: "mesh:\(recipientBare)")
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipientBare])
        backend.setCapabilities(["pm", "ack"], for: recipientBare)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendDeliveryAck("mid-delivered-prefixed", to: recipientPrefixed)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectAckEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientPeerID, recipientBare)
        XCTAssertEqual(backend.sentPayloads[0].1, recipientBare)
        XCTAssertTrue(mesh.sentDeliveryAcks.isEmpty)
    }

    @MainActor
    func testRoutesDeliveryAckViaWiFiWhenCapabilitiesAreUnknown() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendDeliveryAck("mid-delivered-unknown-caps", to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentDeliveryAcks.isEmpty)
    }

    @MainActor
    func testDropsDeliveryAckWhenMessageIDIsEmpty() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendDeliveryAck("   ", to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentDeliveryAcks.count, 0)
    }

    @MainActor
    func testDropsDeliveryAckWhenMessageIDExceedsLimit() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        let oversizedMessageID = String(repeating: "d", count: InputValidator.Limits.maxMessageIDLength + 1)
        router.sendDeliveryAck(oversizedMessageID, to: recipient)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentDeliveryAcks.count, 0)
    }

    @MainActor
    func testRoutesFavoriteNotificationViaWiFiWhenPeerIsAvailable() throws {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: false)
        mesh.setPeerNickname("peer", for: recipient)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["pm", "ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendFavoriteNotification(to: recipient, isFavorite: true)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertTrue(mesh.sentFavoriteNotifications.isEmpty)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertTrue(envelope.content.hasPrefix("[FAVORITED]"))
    }

    @MainActor
    func testFallsBackToMeshFavoriteNotificationWhenWiFiUnavailable() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        backend.isAvailable = false
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendFavoriteNotification(to: recipient, isFavorite: false)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentFavoriteNotifications.count, 1)
        XCTAssertEqual(mesh.sentFavoriteNotifications[0].peerID, recipient)
        XCTAssertFalse(mesh.sentFavoriteNotifications[0].isFavorite)
    }

    @MainActor
    func testRoutesFavoriteNotificationUsingShortDerivedPeerIDForNoiseKeyRecipient() throws {
        let noiseKey = Data(repeating: 0x52, count: 32)
        let recipientFull = PeerID(hexData: noiseKey)
        let recipientShort = PeerID(publicKey: noiseKey)
        let mesh = MockTransport()
        mesh.setPeerNickname("peer", for: recipientFull)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipientShort.id])
        backend.setCapabilities(["pm", "ack"], for: recipientShort.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendFavoriteNotification(to: recipientFull, isFavorite: true)

        XCTAssertEqual(backend.sentPayloads.count, 1)
        let envelope = try JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: backend.sentPayloads[0].0)
        XCTAssertEqual(envelope.recipientPeerID, recipientShort.id)
        XCTAssertTrue(envelope.content.hasPrefix("[FAVORITED]"))
    }

    @MainActor
    func testFallsBackFromWiFiFavoriteNotificationWhenPeerLacksPMCapability() {
        let recipient = PeerID(str: "peerabc000000000")
        let mesh = MockTransport()
        mesh.setReachable(recipient, isReachable: true)
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        backend.setPeers([recipient.id])
        backend.setCapabilities(["ack"], for: recipient.id)

        let router = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)
        router.sendFavoriteNotification(to: recipient, isFavorite: true)

        XCTAssertEqual(backend.sentPayloads.count, 0)
        XCTAssertEqual(mesh.sentFavoriteNotifications.count, 1)
        XCTAssertEqual(mesh.sentFavoriteNotifications[0].peerID, recipient)
        XCTAssertTrue(mesh.sentFavoriteNotifications[0].isFavorite)
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
    func testAcceptsAckEnvelopeWhenSenderUsesFullNoiseIDAndTransportUsesShortID() throws {
        let noiseKey = Data(repeating: 0x3C, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "accepts ack sender full-id over short transport identity")
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectAckEnvelope(
            ackType: .delivered,
            senderPeerID: senderFull.id,
            recipientPeerID: mesh.myPeerID.id,
            messageID: "mid-sender-full-ack",
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: senderShort.id)

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testAcceptsAckEnvelopeWhenSenderUsesShortIDAndTransportUsesFullNoiseID() throws {
        let noiseKey = Data(repeating: 0x6D, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "accepts ack sender short-id over full transport identity")
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let envelope = WiFiDirectAckEnvelope(
            ackType: .read,
            senderPeerID: senderShort.id,
            recipientPeerID: mesh.myPeerID.id,
            messageID: "mid-sender-short-ack",
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: senderFull.id)

        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testAcceptsAckEnvelopeWhenRecipientUsesFullNoiseIDAndLocalUsesShortID() throws {
        let localNoise = Data(repeating: 0x2A, count: 32)
        let localShort = PeerID(publicKey: localNoise)
        let localFull = PeerID(hexData: localNoise)

        let mesh = MockTransport()
        mesh.myPeerID = localShort
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "accepts ack recipient full-id with local short-id")
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
            recipientPeerID: localFull.id,
            messageID: "mid-recipient-full-ack",
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 1.0)
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
    func testDeduplicatesIncomingWiFiAckEnvelopeAcrossFullAndShortSenderIDs() throws {
        let noiseKey = Data(repeating: 0x77, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "ack dedups across full/short sender IDs")
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

        let envelopeFull = WiFiDirectAckEnvelope(
            ackType: .read,
            senderPeerID: senderFull.id,
            recipientPeerID: mesh.myPeerID.id,
            messageID: "mid-cross-id-ack",
            senderNickname: "peer"
        )
        let envelopeShort = WiFiDirectAckEnvelope(
            ackType: .read,
            senderPeerID: senderShort.id,
            recipientPeerID: mesh.myPeerID.id,
            messageID: "mid-cross-id-ack",
            senderNickname: "peer"
        )
        backend.simulateIncoming(try JSONEncoder().encode(envelopeFull), from: senderShort.id)
        backend.simulateIncoming(try JSONEncoder().encode(envelopeShort), from: senderFull.id)

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
    func testIgnoresIncomingWiFiPrivateEnvelopeWithStaleTimestamp() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi, nowProvider: { fixedNow })

        let expect = expectation(description: "should not receive stale private envelope")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let staleMs = UInt64(
            fixedNow
                .addingTimeInterval(-(TransportConfig.messageRouterInboundWiFiTimestampMaxAgeSeconds + 1))
                .timeIntervalSince1970 * 1000
        )
        let payloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": "peer-1",
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-stale-private",
            "content": "hello",
            "createdAtMs": staleMs
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
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
    func testIgnoresIncomingWiFiPrivateEnvelopeWithOversizedMessageID() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive private notification with oversized message id")
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
            messageID: String(repeating: "p", count: InputValidator.Limits.maxMessageIDLength + 1),
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testIgnoresIncomingWiFiAckEnvelopeWithOversizedMessageID() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive ack with oversized message id")
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
            messageID: String(repeating: "a", count: InputValidator.Limits.maxMessageIDLength + 1),
            senderNickname: "peer"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testIgnoresIncomingWiFiPrivateEnvelopeWithSurroundingWhitespaceMessageID() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi)

        let expect = expectation(description: "should not receive private notification with surrounding whitespace message id")
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
            messageID: "  mid-surrounding-space  ",
            content: "hello"
        )
        let payload = try JSONEncoder().encode(envelope)
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testIgnoresIncomingWiFiAckEnvelopeWithFutureTimestamp() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi, nowProvider: { fixedNow })

        let expect = expectation(description: "should not receive future ack envelope")
        expect.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            expect.fulfill()
        }

        let futureMs = UInt64(
            fixedNow
                .addingTimeInterval(TransportConfig.messageRouterInboundWiFiTimestampFutureSkewSeconds + 1)
                .timeIntervalSince1970 * 1000
        )
        let payloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "ack",
            "ackType": "read",
            "senderPeerID": "peer-1",
            "recipientPeerID": mesh.myPeerID.id,
            "messageID": "mid-future-ack",
            "senderNickname": "peer",
            "createdAtMs": futureMs
        ]
        let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
        backend.simulateIncoming(payload, from: "peer-1")

        wait(for: [expect], timeout: 0.2)
        NotificationCenter.default.removeObserver(token)
    }

    @MainActor
    func testRateLimitsInboundWiFiEventsPerSenderWithinWindow() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi, nowProvider: { fixedNow })

        var receivedCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            receivedCount += 1
        }

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

        let expect = expectation(description: "rate-limited notifications settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)

        XCTAssertEqual(receivedCount, maxEvents)
    }

    @MainActor
    func testInboundWiFiRateLimitResetsAfterWindowExpires() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        var now = Date()

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi, nowProvider: { now })

        var receivedCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            receivedCount += 1
        }

        let maxEvents = TransportConfig.messageRouterInboundWiFiSenderRateMaxEvents
        for idx in 0..<maxEvents {
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "private",
                "senderPeerID": "peer-rate-reset",
                "recipientPeerID": mesh.myPeerID.id,
                "recipientNickname": "self",
                "messageID": "mid-rate-reset-\(idx)",
                "content": "hello",
                "createdAtMs": UInt64(now.timeIntervalSince1970 * 1000)
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: "peer-rate-reset")
        }

        // This one should be rate-limited.
        let blockedPayload: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": "peer-rate-reset",
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-rate-reset-blocked",
            "content": "hello",
            "createdAtMs": UInt64(now.timeIntervalSince1970 * 1000)
        ]
        let blockedData = try JSONSerialization.data(withJSONObject: blockedPayload, options: [])
        backend.simulateIncoming(blockedData, from: "peer-rate-reset")

        now = now.addingTimeInterval(TransportConfig.messageRouterInboundWiFiSenderRateWindowSeconds + 1)

        // After the window expires this should pass.
        let allowedPayload: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": "peer-rate-reset",
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-rate-reset-allowed",
            "content": "hello",
            "createdAtMs": UInt64(now.timeIntervalSince1970 * 1000)
        ]
        let allowedData = try JSONSerialization.data(withJSONObject: allowedPayload, options: [])
        backend.simulateIncoming(allowedData, from: "peer-rate-reset")

        let expect = expectation(description: "rate-limit reset notifications settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)

        XCTAssertEqual(receivedCount, maxEvents + 1)
    }

    @MainActor
    func testRateLimitsInboundWiFiAckEventsPerSenderWithinWindow() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi, nowProvider: { fixedNow })

        var receivedCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectAckEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            receivedCount += 1
        }

        let maxEvents = TransportConfig.messageRouterInboundWiFiSenderRateMaxEvents
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<(maxEvents + 3) {
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "ack",
                "ackType": "read",
                "senderPeerID": "peer-rate-ack",
                "recipientPeerID": mesh.myPeerID.id,
                "messageID": "mid-rate-ack-\(idx)",
                "senderNickname": "peer",
                "createdAtMs": createdAtMs
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: "peer-rate-ack")
        }

        let expect = expectation(description: "ack rate-limited notifications settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)

        XCTAssertEqual(receivedCount, maxEvents)
    }

    @MainActor
    func testInboundWiFiRateLimitTreatsFullAndShortSenderIDsAsSameSender() throws {
        let noiseKey = Data(repeating: 0x6A, count: 32)
        let senderFull = PeerID(hexData: noiseKey)
        let senderShort = PeerID(publicKey: noiseKey)

        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi, nowProvider: { fixedNow })

        var receivedCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            receivedCount += 1
        }

        let maxEvents = TransportConfig.messageRouterInboundWiFiSenderRateMaxEvents
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<(maxEvents + 2) {
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

        let expect = expectation(description: "cross-id sender rate limit settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)

        XCTAssertEqual(receivedCount, maxEvents)
    }

    @MainActor
    func testInboundWiFiRateLimiterCapsTrackedSenderBuckets() throws {
        let mesh = MockTransport()
        let nostr = NostrTransport(keychain: MockKeychain())
        let backend = MockWiFiBackend(localPeerID: mesh.myPeerID.id)
        let wifi = WiFiDirectTransport(localPeerID: mesh.myPeerID.id, backend: backend)
        let fixedNow = Date()

        _ = MessageRouter(mesh: mesh, nostr: nostr, wifiTransport: wifi, nowProvider: { fixedNow })

        var receivedCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            queue: .main
        ) { _ in
            receivedCount += 1
        }

        let senderCap = TransportConfig.messageRouterInboundWiFiSenderRateMaxTrackedSenders
        let createdAtMs = UInt64(fixedNow.timeIntervalSince1970 * 1000)
        for idx in 0..<senderCap {
            let sender = "peer-bucket-\(idx)"
            let payloadObject: [String: Any] = [
                "version": WiFiDirectEnvelopeVersion.current,
                "messageType": "private",
                "senderPeerID": sender,
                "recipientPeerID": mesh.myPeerID.id,
                "recipientNickname": "self",
                "messageID": "mid-bucket-\(idx)",
                "content": "hello",
                "createdAtMs": createdAtMs
            ]
            let payload = try JSONSerialization.data(withJSONObject: payloadObject, options: [])
            backend.simulateIncoming(payload, from: sender)
        }

        // New sender beyond cap should be dropped.
        let overflowSender = "peer-bucket-overflow"
        let overflowPayloadObject: [String: Any] = [
            "version": WiFiDirectEnvelopeVersion.current,
            "messageType": "private",
            "senderPeerID": overflowSender,
            "recipientPeerID": mesh.myPeerID.id,
            "recipientNickname": "self",
            "messageID": "mid-bucket-overflow",
            "content": "hello",
            "createdAtMs": createdAtMs
        ]
        let overflowPayload = try JSONSerialization.data(withJSONObject: overflowPayloadObject, options: [])
        backend.simulateIncoming(overflowPayload, from: overflowSender)

        let expect = expectation(description: "sender bucket cap notifications settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)
        NotificationCenter.default.removeObserver(token)

        XCTAssertEqual(receivedCount, senderCap)
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
