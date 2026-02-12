import BitLogger
import Foundation

/// Routes messages between BLE and Nostr transports
@MainActor
final class MessageRouter {
    private struct QueuedPrivateMessage {
        let content: String
        let recipientNickname: String
        let messageID: String
        let enqueuedAt: Date
    }

    private let mesh: Transport
    private let nostr: NostrTransport
    private let routingPolicy: TransportRoutingPolicy
    private let wifiRoutingPolicy: WiFiDirectRoutingPolicy
    private let wifiTransport: WiFiDirectTransport?
    private let outboxPerPeerCap: Int
    private let outboxMaxAgeSeconds: TimeInterval
    private let inboundWiFiPayloadMaxBytes: Int
    private let inboundWiFiDedupMaxCount: Int
    private let inboundWiFiDedupMaxAgeSeconds: TimeInterval
    private let inboundWiFiTimestampMaxAgeSeconds: TimeInterval
    private let inboundWiFiTimestampFutureSkewSeconds: TimeInterval
    private let inboundWiFiSenderRateWindowSeconds: TimeInterval
    private let inboundWiFiSenderRateMaxEvents: Int
    private let inboundWiFiSenderRateMaxTrackedSenders: Int
    private let nowProvider: () -> Date
    private var favoriteStatusObserver: NSObjectProtocol?
    private var inboundWiFiDedupByKey: [String: Date] = [:]
    private var inboundWiFiDedupOrder: [String] = []
    private var inboundWiFiSenderEventTimestamps: [String: [Date]] = [:]
    private var outbox: [PeerID: [QueuedPrivateMessage]] = [:] // peerID -> queued messages

    init(
        mesh: Transport,
        nostr: NostrTransport,
        routingPolicy: TransportRoutingPolicy = TransportRoutingPolicy(),
        wifiRoutingPolicy: WiFiDirectRoutingPolicy = WiFiDirectRoutingPolicy(),
        wifiTransport: WiFiDirectTransport? = nil,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.mesh = mesh
        self.nostr = nostr
        self.routingPolicy = routingPolicy
        self.wifiRoutingPolicy = wifiRoutingPolicy
        self.wifiTransport = wifiTransport ?? WiFiDirectTransport(localPeerID: mesh.myPeerID.id)
        self.outboxPerPeerCap = TransportConfig.messageRouterOutboxPerPeerCap
        self.outboxMaxAgeSeconds = TransportConfig.messageRouterOutboxMessageMaxAgeSeconds
        self.inboundWiFiPayloadMaxBytes = TransportConfig.messageRouterInboundWiFiPayloadMaxBytes
        self.inboundWiFiDedupMaxCount = TransportConfig.messageRouterInboundWiFiDedupMaxCount
        self.inboundWiFiDedupMaxAgeSeconds = TransportConfig.messageRouterInboundWiFiDedupMaxAgeSeconds
        self.inboundWiFiTimestampMaxAgeSeconds = TransportConfig.messageRouterInboundWiFiTimestampMaxAgeSeconds
        self.inboundWiFiTimestampFutureSkewSeconds = TransportConfig.messageRouterInboundWiFiTimestampFutureSkewSeconds
        self.inboundWiFiSenderRateWindowSeconds = TransportConfig.messageRouterInboundWiFiSenderRateWindowSeconds
        self.inboundWiFiSenderRateMaxEvents = TransportConfig.messageRouterInboundWiFiSenderRateMaxEvents
        self.inboundWiFiSenderRateMaxTrackedSenders = TransportConfig.messageRouterInboundWiFiSenderRateMaxTrackedSenders
        self.nowProvider = nowProvider
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
            var handledSpecificPeer = false
            if let data = note.userInfo?["peerPublicKey"] as? Data {
                let peerID = PeerID(publicKey: data)
                handledSpecificPeer = true
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            // Handle key updates
            if let newKey = note.userInfo?["peerPublicKey"] as? Data,
               let _ = note.userInfo?["isKeyUpdate"] as? Bool {
                let peerID = PeerID(publicKey: newKey)
                handledSpecificPeer = true
                Task { @MainActor in
                    self.flushOutbox(for: peerID)
                }
            }
            if !handledSpecificPeer {
                Task { @MainActor in
                    self.flushAllOutbox()
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
        if routePrivateViaWiFi(
            content,
            to: peerID,
            recipientNickname: recipientNickname,
            messageID: messageID,
            requirePolicyThreshold: true
        ) {
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
            if routePrivateViaWiFi(
                content,
                to: peerID,
                recipientNickname: recipientNickname,
                messageID: messageID,
                requirePolicyThreshold: false
            ) {
                return
            }
            // Queue for later (when mesh connects or Nostr mapping appears)
            pruneExpiredOutboxMessages(for: peerID)
            if outbox[peerID] == nil { outbox[peerID] = [] }
            outbox[peerID]?.removeAll { $0.messageID == messageID }
            outbox[peerID]?.append(
                QueuedPrivateMessage(
                    content: content,
                    recipientNickname: recipientNickname,
                    messageID: messageID,
                    enqueuedAt: nowProvider()
                )
            )
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
        if sendFavoriteNotificationViaWiFiIfAvailable(to: peerID, isFavorite: isFavorite) {
            return
        }
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
        pruneExpiredOutboxMessages(for: peerID)
        guard let queued = outbox[peerID], !queued.isEmpty else { return }
        SecureLogger.debug("Flushing outbox for \(peerID.id.prefix(8))… count=\(queued.count)", category: .session)
        var remaining: [QueuedPrivateMessage] = []
        // Re-evaluate route for each message as transport availability may have changed.
        for message in queued {
            if nowProvider().timeIntervalSince(message.enqueuedAt) > outboxMaxAgeSeconds {
                continue
            }
            let content = message.content
            let nickname = message.recipientNickname
            let messageID = message.messageID
            if routePrivateViaWiFi(
                content,
                to: peerID,
                recipientNickname: nickname,
                messageID: messageID,
                requirePolicyThreshold: true
            ) {
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
                if routePrivateViaWiFi(
                    content,
                    to: peerID,
                    recipientNickname: nickname,
                    messageID: messageID,
                    requirePolicyThreshold: false
                ) {
                    continue
                }
                // Keep unsent items queued
                remaining.append(message)
            }
        }
        // Persist only items we could not send
        if remaining.isEmpty {
            outbox.removeValue(forKey: peerID)
        } else {
            outbox[peerID] = remaining
        }
    }

    private func routePrivateViaWiFi(
        _ content: String,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String,
        requirePolicyThreshold: Bool
    ) -> Bool {
        guard let wifiTransport else { return false }
        guard let targetPeerID = resolveWiFiPeerIdentifier(
            for: peerID,
            wifiTransport: wifiTransport,
            requiredCapability: "pm"
        ) else { return false }
        if requirePolicyThreshold {
            let shouldUseWiFi = wifiRoutingPolicy.shouldUseWiFi(
                payloadBytes: content.utf8.count,
                recipientPeerID: targetPeerID,
                wifiAvailable: wifiTransport.isAvailable,
                wifiPeerIDs: Set(wifiTransport.currentPeers)
            )
            guard shouldUseWiFi else { return false }
        }

        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: mesh.myPeerID.id,
            recipientPeerID: targetPeerID,
            recipientNickname: recipientNickname,
            messageID: messageID,
            content: content
        )
        guard let payload = try? JSONEncoder().encode(envelope) else { return false }

        do {
            try wifiTransport.send(payload, to: targetPeerID)
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
        guard let targetPeerID = resolveWiFiPeerIdentifier(
            for: peerID,
            wifiTransport: wifiTransport,
            requiredCapability: "ack"
        ) else { return false }

        let envelope = WiFiDirectAckEnvelope(
            ackType: ackType,
            senderPeerID: mesh.myPeerID.id,
            recipientPeerID: targetPeerID,
            messageID: messageID,
            senderNickname: senderNickname
        )
        guard let payload = try? JSONEncoder().encode(envelope) else { return false }

        do {
            try wifiTransport.send(payload, to: targetPeerID)
            SecureLogger.debug("Routing \(ackType.rawValue.uppercased()) ack via WiFi Direct to \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…", category: .session)
            return true
        } catch {
            SecureLogger.debug("WiFi Direct \(ackType.rawValue.uppercased()) ack route failed for \(peerID.id.prefix(8))… id=\(messageID.prefix(8))…, falling back", category: .session)
            return false
        }
    }

    private func sendFavoriteNotificationViaWiFiIfAvailable(to peerID: PeerID, isFavorite: Bool) -> Bool {
        guard let wifiTransport else { return false }
        guard let targetPeerID = resolveWiFiPeerIdentifier(
            for: peerID,
            wifiTransport: wifiTransport,
            requiredCapability: "pm"
        ) else { return false }

        let recipientNickname = mesh.peerNickname(peerID: peerID) ?? "user"
        let content = favoriteNotificationPayloadContent(isFavorite: isFavorite)
        let envelope = WiFiDirectPrivateEnvelope(
            senderPeerID: mesh.myPeerID.id,
            recipientPeerID: targetPeerID,
            recipientNickname: recipientNickname,
            messageID: UUID().uuidString,
            content: content
        )
        guard let payload = try? JSONEncoder().encode(envelope) else { return false }

        do {
            try wifiTransport.send(payload, to: targetPeerID)
            SecureLogger.debug("Routing FAVORITE(\(isFavorite)) via WiFi Direct to \(peerID.id.prefix(8))…", category: .session)
            return true
        } catch {
            SecureLogger.debug("WiFi Direct favorite route failed for \(peerID.id.prefix(8))…, falling back", category: .session)
            return false
        }
    }

    private func favoriteNotificationPayloadContent(isFavorite: Bool) -> String {
        let base = isFavorite ? "[FAVORITED]" : "[UNFAVORITED]"
        if let identity = try? NostrIdentityBridge.getCurrentNostrIdentity() {
            return "\(base):\(identity.npub)"
        }
        return base
    }

    private func resolveWiFiPeerIdentifier(
        for peerID: PeerID,
        wifiTransport: WiFiDirectTransport,
        requiredCapability: String
    ) -> String? {
        guard wifiTransport.isAvailable else { return nil }
        let availablePeerIDs = Set(wifiTransport.currentPeers)
        for candidate in wifiPeerIDCandidates(for: peerID) where availablePeerIDs.contains(candidate) {
            if let capabilities = wifiTransport.peerCapabilities(peerID: candidate),
               !capabilities.contains(requiredCapability) {
                continue
            }
            return candidate
        }
        return nil
    }

    private func wifiPeerIDCandidates(for peerID: PeerID) -> [String] {
        var candidates: [String] = [peerID.id]
        let short = peerID.toShort().id
        if short != peerID.id {
            candidates.append(short)
        }
        if let noiseKey = peerID.noiseKey {
            let full = noiseKey.hexEncodedString()
            if full != peerID.id && !candidates.contains(full) {
                candidates.append(full)
            }
        }
        return candidates
    }

    private func senderMatchesTransportPeerID(claimedSenderID: String, transportPeerID: String) -> Bool {
        let claimed = PeerID(str: claimedSenderID)
        let observed = PeerID(str: transportPeerID)
        if claimed.id == observed.id {
            return true
        }
        return claimed.toShort().id == observed.toShort().id
    }

    private func normalizedWiFiIdentityKey(_ peerID: String) -> String {
        PeerID(str: peerID).toShort().id
    }

    private func recipientMatchesLocalPeerID(_ claimedRecipientID: String) -> Bool {
        let claimed = PeerID(str: claimedRecipientID)
        let local = mesh.myPeerID
        if claimed.id == local.id {
            return true
        }
        return claimed.toShort().id == local.toShort().id
    }

    func flushAllOutbox() {
        for key in Array(outbox.keys) { flushOutbox(for: key) }
    }

    func queuedMessageCount(for peerID: PeerID) -> Int {
        outbox[peerID]?.count ?? 0
    }

    private func pruneExpiredOutboxMessages(for peerID: PeerID) {
        guard var queued = outbox[peerID], !queued.isEmpty else { return }
        let now = nowProvider()
        let originalCount = queued.count
        queued.removeAll { now.timeIntervalSince($0.enqueuedAt) > outboxMaxAgeSeconds }
        if queued.isEmpty {
            outbox.removeValue(forKey: peerID)
        } else {
            outbox[peerID] = queued
        }
        let removed = originalCount - queued.count
        if removed > 0 {
            SecureLogger.debug("Pruned \(removed) expired queued PM(s) for \(peerID.id.prefix(8))…", category: .session)
        }
    }

    private func shouldAcceptInboundWiFiEnvelope(dedupKey: String) -> Bool {
        let now = nowProvider()
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

    private func isInboundWiFiTimestampAcceptable(_ createdAtMs: UInt64) -> Bool {
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000)
        let now = nowProvider()
        if createdAt > now.addingTimeInterval(inboundWiFiTimestampFutureSkewSeconds) {
            return false
        }
        if createdAt < now.addingTimeInterval(-inboundWiFiTimestampMaxAgeSeconds) {
            return false
        }
        return true
    }

    private func allowInboundWiFiEvent(from senderID: String) -> Bool {
        let normalizedSenderID = normalizedWiFiIdentityKey(senderID)
        let now = nowProvider()
        cleanupInboundWiFiSenderRate(now: now)
        if inboundWiFiSenderEventTimestamps[normalizedSenderID] == nil,
           inboundWiFiSenderEventTimestamps.count >= inboundWiFiSenderRateMaxTrackedSenders {
            return false
        }
        let cutoff = now.addingTimeInterval(-inboundWiFiSenderRateWindowSeconds)
        var events = inboundWiFiSenderEventTimestamps[normalizedSenderID] ?? []
        events.removeAll { $0 < cutoff }
        if events.count >= inboundWiFiSenderRateMaxEvents {
            inboundWiFiSenderEventTimestamps[normalizedSenderID] = events
            return false
        }
        events.append(now)
        inboundWiFiSenderEventTimestamps[normalizedSenderID] = events
        return true
    }

    private func cleanupInboundWiFiSenderRate(now: Date) {
        let cutoff = now.addingTimeInterval(-inboundWiFiSenderRateWindowSeconds)
        guard !inboundWiFiSenderEventTimestamps.isEmpty else { return }
        let senders = Array(inboundWiFiSenderEventTimestamps.keys)
        for sender in senders {
            guard let events = inboundWiFiSenderEventTimestamps[sender] else { continue }
            let filtered = events.filter { $0 >= cutoff }
            if filtered.isEmpty {
                inboundWiFiSenderEventTimestamps.removeValue(forKey: sender)
            } else if filtered.count != events.count {
                inboundWiFiSenderEventTimestamps[sender] = filtered
            }
        }
    }
}

extension MessageRouter: WiFiDirectTransportDelegate {
    nonisolated func wifiTransportDidUpdatePeers(_ peers: [String]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            SecureLogger.debug("WiFi Direct peers updated count=\(peers.count)", category: .session)
            if !peers.isEmpty {
                self.flushAllOutbox()
            }
        }
    }

    nonisolated func wifiTransportDidReceive(_ data: Data, from peerID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard data.count <= self.inboundWiFiPayloadMaxBytes else {
                SecureLogger.debug("Dropped oversized WiFi payload from \(peerID.prefix(8))… bytes=\(data.count)", category: .session)
                return
            }
            guard self.allowInboundWiFiEvent(from: peerID) else {
                SecureLogger.debug("Dropped rate-limited WiFi payload from \(peerID.prefix(8))…", category: .session)
                return
            }
            if let envelope = try? JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: data),
               envelope.messageType == "private",
               envelope.version == WiFiDirectEnvelopeVersion.current,
               self.senderMatchesTransportPeerID(claimedSenderID: envelope.senderPeerID, transportPeerID: peerID),
               self.recipientMatchesLocalPeerID(envelope.recipientPeerID),
               !envelope.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               self.isInboundWiFiTimestampAcceptable(envelope.createdAtMs),
               envelope.content.utf8.count <= InputValidator.Limits.maxMessageLength {
                let dedupKey = "pm:\(self.normalizedWiFiIdentityKey(envelope.senderPeerID)):\(envelope.messageID)"
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
               self.senderMatchesTransportPeerID(claimedSenderID: envelope.senderPeerID, transportPeerID: peerID),
               self.recipientMatchesLocalPeerID(envelope.recipientPeerID),
               self.isInboundWiFiTimestampAcceptable(envelope.createdAtMs),
               !envelope.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let dedupKey = "ack:\(envelope.ackType.rawValue):\(self.normalizedWiFiIdentityKey(envelope.senderPeerID)):\(envelope.messageID)"
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
