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
    private let outboxPerPeerCap: Int
    private let inboundWiFiPayloadMaxBytes: Int
    private let inboundWiFiDedupMaxCount: Int
    private let inboundWiFiDedupMaxAgeSeconds: TimeInterval
    private var favoriteStatusObserver: NSObjectProtocol?
    private var inboundWiFiDedupByKey: [String: Date] = [:]
    private var inboundWiFiDedupOrder: [String] = []
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
        self.outboxPerPeerCap = TransportConfig.messageRouterOutboxPerPeerCap
        self.inboundWiFiPayloadMaxBytes = TransportConfig.messageRouterInboundWiFiPayloadMaxBytes
        self.inboundWiFiDedupMaxCount = TransportConfig.messageRouterInboundWiFiDedupMaxCount
        self.inboundWiFiDedupMaxAgeSeconds = TransportConfig.messageRouterInboundWiFiDedupMaxAgeSeconds
        self.nostr.senderPeerID = mesh.myPeerID
        self.wifiTransport?.delegate = self
        self.wifiTransport?.startDiscovery()

        // Observe favorites changes to learn Nostr mapping and flush queued messages
        favoriteStatusObserver = NotificationCenter.default.addObserver(
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
        if let favoriteStatusObserver {
            NotificationCenter.default.removeObserver(favoriteStatusObserver)
        }
        wifiTransport?.stopDiscovery()
    }

    func sendPrivate(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        if routePrivateViaWiFiIfPreferred(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID) {
            return
        }
        let reachableMesh = mesh.isPeerReachable(peerID)
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
            if let count = outbox[peerID]?.count, count > outboxPerPeerCap {
                let overflow = count - outboxPerPeerCap
                outbox[peerID]?.removeFirst(overflow)
                SecureLogger.debug("Trimmed outbox for \(peerID.id.prefix(8))… by \(overflow) entries to cap \(outboxPerPeerCap)", category: .session)
            }
            SecureLogger.debug("Queued PM for \(peerID.id.prefix(8))… (no mesh, no Nostr mapping) id=\(messageID.prefix(8))…", category: .session)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        if routeAckViaWiFiIfAvailable(
            ackType: .read,
            messageID: receipt.originalMessageID,
            to: peerID,
            senderNickname: receipt.readerNickname
        ) {
            return
        }
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
        if routeAckViaWiFiIfAvailable(
            ackType: .delivered,
            messageID: messageID,
            to: peerID,
            senderNickname: nil
        ) {
            return
        }
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
            if routePrivateViaWiFiIfPreferred(content, to: peerID, recipientNickname: nickname, messageID: messageID) {
                continue
            }
            let reachableMesh = mesh.isPeerReachable(peerID)
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
        if let capabilities = wifiTransport.peerCapabilities(peerID: peerID.id),
           !capabilities.contains("pm") {
            return false
        }

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

    private func routeAckViaWiFiIfAvailable(
        ackType: WiFiDirectAckType,
        messageID: String,
        to peerID: PeerID,
        senderNickname: String?
    ) -> Bool {
        guard let wifiTransport else { return false }
        guard wifiTransport.isAvailable else { return false }
        guard Set(wifiTransport.currentPeers).contains(peerID.id) else { return false }
        if let capabilities = wifiTransport.peerCapabilities(peerID: peerID.id),
           !capabilities.contains("ack") {
            return false
        }

        let envelope = WiFiDirectAckEnvelope(
            ackType: ackType,
            senderPeerID: mesh.myPeerID.id,
            recipientPeerID: peerID.id,
            messageID: messageID,
            senderNickname: senderNickname
        )
        guard let payload = try? JSONEncoder().encode(envelope) else { return false }

        do {
            try wifiTransport.send(payload, to: peerID.id)
            SecureLogger.debug("Routing \(ackType.rawValue.uppercased()) ack via WiFi Direct to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            return true
        } catch {
            SecureLogger.debug("WiFi Direct \(ackType.rawValue.uppercased()) ack route failed for \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…, falling back", category: .session)
            return false
        }
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }

    func queuedMessageCount(for peerID: PeerID) -> Int {
        outbox[peerID]?.count ?? 0
    }

    private func shouldAcceptInboundWiFiEnvelope(dedupKey: String) -> Bool {
        let now = Date()
        cleanupInboundWiFiDedup(now: now)
        if inboundWiFiDedupByKey[dedupKey] != nil {
            return false
        }
        inboundWiFiDedupByKey[dedupKey] = now
        inboundWiFiDedupOrder.append(dedupKey)
        if inboundWiFiDedupOrder.count > inboundWiFiDedupMaxCount {
            let overflow = inboundWiFiDedupOrder.count - inboundWiFiDedupMaxCount
            for _ in 0..<overflow {
                let oldest = inboundWiFiDedupOrder.removeFirst()
                inboundWiFiDedupByKey.removeValue(forKey: oldest)
            }
        }
        return true
    }

    private func cleanupInboundWiFiDedup(now: Date) {
        let cutoff = now.addingTimeInterval(-inboundWiFiDedupMaxAgeSeconds)
        while let first = inboundWiFiDedupOrder.first,
              let timestamp = inboundWiFiDedupByKey[first],
              timestamp < cutoff {
            inboundWiFiDedupOrder.removeFirst()
            inboundWiFiDedupByKey.removeValue(forKey: first)
        }
    }
}

extension MessageRouter: WiFiDirectTransportDelegate {
    nonisolated func wifiTransportDidUpdatePeers(_ peers: [String]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            SecureLogger.debug("WiFi Direct peers updated count=\(peers.count)", category: .session)
            self.flushAllOutbox()
        }
    }

    nonisolated func wifiTransportDidReceive(_ data: Data, from peerID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard data.count <= self.inboundWiFiPayloadMaxBytes else {
                SecureLogger.debug("Dropped oversized WiFi payload from \(peerID.prefix(8))… bytes=\(data.count)", category: .session)
                return
            }
            if let envelope = try? JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: data),
               envelope.messageType == "private",
               envelope.version == WiFiDirectEnvelopeVersion.current,
               envelope.senderPeerID == peerID,
               envelope.recipientPeerID == self.mesh.myPeerID.id,
               !envelope.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               envelope.content.utf8.count <= InputValidator.Limits.maxMessageLength {
                let dedupKey = "pm:\(envelope.senderPeerID):\(envelope.messageID)"
                guard self.shouldAcceptInboundWiFiEnvelope(dedupKey: dedupKey) else { return }
                NotificationCenter.default.post(
                    name: .wifiDirectPrivateEnvelopeReceived,
                    object: nil,
                    userInfo: [WiFiDirectNotificationUserInfoKey.envelope: envelope]
                )
                return
            }

            if let envelope = try? JSONDecoder().decode(WiFiDirectAckEnvelope.self, from: data),
               envelope.messageType == "ack",
               envelope.version == WiFiDirectEnvelopeVersion.current,
               envelope.senderPeerID == peerID,
               envelope.recipientPeerID == self.mesh.myPeerID.id,
               !envelope.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let dedupKey = "ack:\(envelope.ackType.rawValue):\(envelope.senderPeerID):\(envelope.messageID)"
                guard self.shouldAcceptInboundWiFiEnvelope(dedupKey: dedupKey) else { return }
                NotificationCenter.default.post(
                    name: .wifiDirectAckEnvelopeReceived,
                    object: nil,
                    userInfo: [WiFiDirectNotificationUserInfoKey.ackEnvelope: envelope]
                )
            }
        }
    }

    nonisolated func wifiTransportDidChangeAvailability(_ isAvailable: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            SecureLogger.debug("WiFi Direct availability changed available=\(isAvailable)", category: .session)
            if isAvailable {
                self.flushAllOutbox()
            }
        }
    }
}
