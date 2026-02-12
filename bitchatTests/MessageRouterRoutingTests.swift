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

        func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
        func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
        func sendBroadcastAnnounce() {}
        func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}
    }

    private final class MockWiFiBackend: WiFiDirectTransportBackend {
        weak var owner: WiFiDirectTransport?
        var isAvailable = true
        var sendError: Error?
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

        func setPeers(_ peers: [String]) {
            owner?.didUpdatePeers(peers)
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
}
