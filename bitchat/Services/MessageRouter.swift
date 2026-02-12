import BitLogger
import Foundation

/// Routes messages between BLE and Nostr transports
@MainActor
final class MessageRouter {
    private let mesh: Transport
    private let nostr: NostrTransport
    private let routingPolicy: TransportRoutingPolicy
    private let wifiRoutingPolicy: WiFiDirectRoutingPolicy
    private let wifiTransport: WiFiDirectTransport?
    private var outbox: [PeerID: [(content: String, nickname: String, messageID: String)]] = [:] // peerID -> queued messages

    init(
        mesh: Transport,
        nostr: NostrTransport,
        routingPolicy: TransportRoutingPolicy = TransportRoutingPolicy(),
        wifiRoutingPolicy: WiFiDirectRoutingPolicy = WiFiDirectRoutingPolicy(),
        wifiTransport: WiFiDirectTransport? = nil
    ) {
        self.mesh = mesh
        self.nostr = nostr
        self.routingPolicy = routingPolicy
        self.wifiRoutingPolicy = wifiRoutingPolicy
        self.wifiTransport = wifiTransport ?? WiFiDirectTransport(localPeerID: mesh.myPeerID.id)
        self.nostr.senderPeerID = mesh.myPeerID
        self.wifiTransport?.delegate = self
        self.wifiTransport?.startDiscovery()

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        NotificationCenter.default.addObserver(
            forName: .favoriteStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peerID = PeerID(publicKey: data)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
                let peerID = PeerID(publicKey: newKey)
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
        }
    }

    deinit {
        wifiTransport?.stopDiscovery()
    }

    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        let reachableMesh = mesh.isPeerReachable(peerID)
        if reachableMesh, routePrivateViaWiFiIfPreferred(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID) {
            return
        }
        let nostrAvailable = canSendViaNostr(peerID: peerID)
        let context = TransportRoutingPolicy.Context(
            payloadBytes: content.utf8.count,
            meshReachable: reachableMesh,
            nostrAvailable: nostrAvailable
        )

        switch routingPolicy.routePrivateMessage(context) {
        case .mesh?:
            SecureLogger.debug("Routing PM via mesh (reachable) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            // BLEService will initiate a handshake if needed and queue the message
            mesh.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        case .nostr?:
            SecureLogger.debug("Routing PM via Nostr to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            nostr.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        case nil:
            // Queue for later (when mesh connects or Nostr mapping appears)
            if outbox[peerID] == nil { outbox[peerID] = [] }
            outbox[peerID]?.append((content, recipientNickname, messageID))
            SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no mesh, no Nostr mapping) id=\(messageID.prefix(8))…", category: .session)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        // Prefer mesh for reachable peers; BLE will queue if handshake is needed
        if mesh.isPeerReachable(peerID) {
            SecureLogger.debug("Routing READ ack via mesh (reachable) to \(peerID.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            mesh.sendReadReceipt(receipt, to: peerID)
        } else {
            SecureLogger.debug("Routing READ ack via Nostr to \(peerID.id.prefix(8))… id=\(receipt.originalMessageID.prefix(8))…", category: .session)
            nostr.sendReadReceipt(receipt, to: peerID)
        }
    }

    func sendDeliveryAck(_ messageID: String, to peerID: PeerID) {
        if mesh.isPeerReachable(peerID) {
            SecureLogger.debug("Routing DELIVERED ack via mesh (reachable) to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            mesh.sendDeliveryAck(for: messageID, to: peerID)
        } else {
            nostr.sendDeliveryAck(for: messageID, to: peerID)
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        // Route via mesh when connected; else use Nostr
        if mesh.isPeerConnected(peerID) {
            mesh.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        } else {
            nostr.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
        }
    }

    // MARK: - Outbox Management
    private func canSendViaNostr(peerID: PeerID) -> Bool {
        // Two forms are supported:
        // - 64-hex Noise public key (32 bytes)
        // - 16-hex short peer ID (derived from Noise pubkey)
        if let noiseKey = peerID.noiseKey {
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey),
               fav.peerNostrPublicKey != nil {
                return true
            }
        } else if peerID.isShort {
            if let fav = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: peerID),
               fav.peerNostrPublicKey != nil {
                return true
            }
        }
        return false
    }

    func flushOutbox(for peerID: PeerID) {
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)
        var remaining: [(content: String, nickname: String, messageID: String)] = []
        // Re-evaluate route for each message as transport availability may have changed.
        for (content, nickname, messageID) in queued {
            let reachableMesh = mesh.isPeerReachable(peerID)
            if reachableMesh,
               routePrivateViaWiFiIfPreferred(content, to: peerID, recipientNickname: nickname, messageID: messageID) {
                continue
            }
            let context = TransportRoutingPolicy.Context(
                payloadBytes: content.utf8.count,
                meshReachable: reachableMesh,
                nostrAvailable: canSendViaNostr(peerID: peerID)
            )

            switch routingPolicy.routePrivateMessage(context) {
            case .mesh?:
                SecureLogger.debug("Outbox -> mesh for \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
                mesh.sendPrivateMessage(content, to: peerID, recipientNickname: nickname, messageID: messageID)
            case .nostr?:
                SecureLogger.debug("Outbox -> Nostr for \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
                nostr.sendPrivateMessage(content, to: peerID, recipientNickname: nickname, messageID: messageID)
            case nil:
                // Keep unsent items queued
                remaining.append((content, nickname, messageID))
            }
        }
        // Persist only items we could not send
        if remaining.isEmpty {
            outbox.removeValue(forKey: peerID)
        } else {
            outbox[peerID] = remaining
        }
    }

    private func routePrivateViaWiFiIfPreferred(
        _ content: String,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String
    ) -> Bool {
        guard let wifiTransport else { return false }
        let shouldUseWiFi = wifiRoutingPolicy.shouldUseWiFi(
            payloadBytes: content.utf8.count,
            recipientPeerID: peerID.id,
            wifiAvailable: wifiTransport.isAvailable,
            wifiPeerIDs: Set(wifiTransport.currentPeers)
        )
        guard shouldUseWiFi else { return false }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: mesh.myPeerID.id,
            recipientPeerID: peerID.id,
            recipientNickname: recipientNickname,
            messageID: messageID,
            content: content
        )
        guard let payload = try? JSONEncoder().encode(envelope) else { return false }

        do {
            try wifiTransport.send(payload, to: peerID.id)
            SecureLogger.debug("Routing PM via WiFi Direct to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            return true
        } catch {
            SecureLogger.debug("WiFi Direct PM route failed for \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…, falling back", category: .session)
            return false
        }
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }
}

extension MessageRouter: WiFiDirectTransportDelegate {
    func wifiTransportDidUpdatePeers(_ peers: [String]) {
        SecureLogger.debug("WiFi Direct peers updated count=\(peers.count)", category: .session)
    }

    func wifiTransportDidReceive(_ data: Data, from peerID: String) {
        guard let envelope = try? JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: data),
              envelope.messageType == "private",
              envelope.recipientPeerID == mesh.myPeerID.id else {
            return
        }

        NotificationCenter.default.post(
            name: .wifiDirectPrivateEnvelopeReceived,
            object: nil,
            userInfo: [WiFiDirectNotificationUserInfoKey.envelope: envelope]
        )
    }

    func wifiTransportDidChangeAvailability(_ isAvailable: Bool) {
        SecureLogger.debug("WiFi Direct availability changed available=\(isAvailable)", category: .session)
    }
}
