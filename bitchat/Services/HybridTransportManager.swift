import Foundation

struct WiFiDirectRoutingPolicy {
    let preferredPayloadBytes: Int

    init(preferredPayloadBytes: Int = TransportConfig.wifiDirectPreferredPayloadBytes) {
        self.preferredPayloadBytes = max(1, preferredPayloadBytes)
    }

    func shouldUseWiFi(
        payloadBytes: Int,
        recipientPeerID: String,
        wifiAvailable: Bool,
        wifiPeerIDs: Set<String>
    ) -> Bool {
        guard wifiAvailable else { return false }
        guard payloadBytes >= preferredPayloadBytes else { return false }
        return wifiPeerIDs.contains(recipientPeerID)
    }
}

enum HybridOutboundRoute: Equatable {
    case mesh
    case wifiDirect
}

enum WiFiDirectEnvelopeVersion {
    static let current = 1
}

enum WiFiDirectAckType: String, Codable, Equatable {
    case delivered
    case read
}

struct WiFiDirectPrivateEnvelope: Codable, Equatable {
    let version: Int
    let messageType: String
    let senderPeerID: String
    let recipientPeerID: String
    let recipientNickname: String
    let messageID: String
    let content: String
    let createdAtMs: UInt64

    init(
        senderPeerID: String,
        recipientPeerID: String,
        recipientNickname: String,
        messageID: String,
        content: String
    ) {
        self.version = WiFiDirectEnvelopeVersion.current
        self.messageType = "private"
        self.senderPeerID = senderPeerID
        self.recipientPeerID = recipientPeerID
        self.recipientNickname = recipientNickname
        self.messageID = messageID
        self.content = content
        self.createdAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

struct WiFiDirectAckEnvelope: Codable, Equatable {
    let version: Int
    let messageType: String
    let ackType: WiFiDirectAckType
    let senderPeerID: String
    let recipientPeerID: String
    let messageID: String
    let senderNickname: String?
    let createdAtMs: UInt64

    init(
        ackType: WiFiDirectAckType,
        senderPeerID: String,
        recipientPeerID: String,
        messageID: String,
        senderNickname: String? = nil
    ) {
        self.version = WiFiDirectEnvelopeVersion.current
        self.messageType = "ack"
        self.ackType = ackType
        self.senderPeerID = senderPeerID
        self.recipientPeerID = recipientPeerID
        self.messageID = messageID
        self.senderNickname = senderNickname
        self.createdAtMs = UInt64(Date().timeIntervalSince1970 * 1000)
    }
}

protocol HybridTransportManagerDelegate: AnyObject {
    func hybridTransportManager(_ manager: HybridTransportManager, didReceivePrivateEnvelope envelope: WiFiDirectPrivateEnvelope)
    func hybridTransportManager(_ manager: HybridTransportManager, didUpdateWiFiPeers peers: [String])
}

@MainActor
final class HybridTransportManager {
    private let meshTransport: Transport
    private let wifiTransport: WiFiDirectTransport
    private let wifiRoutingPolicy: WiFiDirectRoutingPolicy

    weak var delegate: HybridTransportManagerDelegate?

    init(
        meshTransport: Transport,
        wifiTransport: WiFiDirectTransport? = nil,
        wifiRoutingPolicy: WiFiDirectRoutingPolicy = WiFiDirectRoutingPolicy()
    ) {
        self.meshTransport = meshTransport
        self.wifiTransport = wifiTransport ?? WiFiDirectTransport(localPeerID: meshTransport.myPeerID.id)
        self.wifiRoutingPolicy = wifiRoutingPolicy
        self.wifiTransport.delegate = self
    }

    func start() {
        meshTransport.startServices()
        wifiTransport.startDiscovery()
    }

    func stop() {
        wifiTransport.stopDiscovery()
        meshTransport.stopServices()
    }

    @discardableResult
    func sendPrivate(
        _ content: String,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String
    ) -> HybridOutboundRoute {
        let recipientID = peerID.id
        let shouldUseWiFi = wifiRoutingPolicy.shouldUseWiFi(
            payloadBytes: content.utf8.count,
            recipientPeerID: recipientID,
            wifiAvailable: wifiTransport.isAvailable,
            wifiPeerIDs: Set(wifiTransport.currentPeers)
        )

        if shouldUseWiFi {
            let envelope = WiFiDirectPrivateEnvelope(
                senderPeerID: meshTransport.myPeerID.id,
                recipientPeerID: recipientID,
                recipientNickname: recipientNickname,
                messageID: messageID,
                content: content
            )
            if let data = try? JSONEncoder().encode(envelope),
               (try? wifiTransport.send(data, to: recipientID)) != nil {
                return .wifiDirect
            }
        }

        meshTransport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        return .mesh
    }
}

extension HybridTransportManager: WiFiDirectTransportDelegate {
    nonisolated func wifiTransportDidUpdatePeers(_ peers: [String]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.hybridTransportManager(self, didUpdateWiFiPeers: peers)
        }
    }

    nonisolated func wifiTransportDidReceive(_ data: Data, from peerID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let envelope = try? JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: data),
                  envelope.messageType == "private",
                  envelope.recipientPeerID == self.meshTransport.myPeerID.id else {
                return
            }
            self.delegate?.hybridTransportManager(self, didReceivePrivateEnvelope: envelope)
        }
    }

    nonisolated func wifiTransportDidChangeAvailability(_ isAvailable: Bool) {}
}
