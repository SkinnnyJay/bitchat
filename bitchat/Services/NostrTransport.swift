import BitLogger
import Foundation
import Combine

// Minimal Nostr transport conforming to Transport for offline sending
final class NostrTransport: Transport {
    // Provide BLE short peer ID for BitChat embedding
    var senderPeerID = PeerID(str: "")

    // Throttle READ receipts to avoid relay rate limits
    private struct QueuedRead {
        let receipt: ReadReceipt
        let peerID: PeerID
    }
    private var readQueue: [QueuedRead] = []
    private var isSendingReadAcks = false
    private let readAckInterval: TimeInterval = TransportConfig.nostrReadAckInterval
    private let readAckQueueCap: Int = TransportConfig.nostrReadAckQueueCap
    private let maxEmbeddedPayloadBytes: Int = TransportConfig.nostrEmbeddedPayloadMaxBytes
    private let keychain: KeychainManagerProtocol

    init(keychain: KeychainManagerProtocol) {
        self.keychain = keychain
    }

    // MARK: - Transport Protocol Conformance

    weak var delegate: BitchatDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?

    var peerSnapshotPublisher: AnyPublisher<[TransportPeerSnapshot], Never> {
        Just([]).eraseToAnyPublisher()
    }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { [] }

    var myPeerID: PeerID { senderPeerID }
    var myNickname: String { "" }
    func setNickname(_ nickname: String) { /* not used for Nostr */ }

    func startServices() { /* no-op */ }
    func stopServices() { /* no-op */ }
    func emergencyDisconnectAll() { /* no-op */ }

    func isPeerConnected(_ peerID: PeerID) -> Bool { false }
    func isPeerReachable(_ peerID: PeerID) -> Bool { false }
    func peerNickname(peerID: PeerID) -> String? { nil }
    func getPeerNicknames() -> [PeerID : String] { [:] }

    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) { /* no-op */ }
    
    // Nostr does not use Noise sessions here; return a cached placeholder to avoid reallocation
    private static var cachedNoiseService: NoiseEncryptionService?
    func getNoiseService() -> NoiseEncryptionService {
        if let noiseService = Self.cachedNoiseService {
            return noiseService
        }
        let noiseService = NoiseEncryptionService(keychain: keychain)
        Self.cachedNoiseService = noiseService
        return noiseService
    }

    // Public broadcast not supported over Nostr here
    func sendMessage(_ content: String, mentions: [String]) { /* no-op */ }

    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        guard peerID.isValid else { return }
        guard content.utf8.count <= InputValidator.Limits.maxMessageLength else { return }
        guard content.utf8.count <= maxEmbeddedPayloadBytes else { return }
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return }
        guard let senderRoutingPeerID = normalizedSenderPeerID() else { return }
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID) else { return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
            SecureLogger.debug("NostrTransport: preparing PM to \(recipientNpub.prefix(16))… for peerID \(peerID.id.prefix(8))… id=\(safeMessageID.prefix(8))…", category: .session)
            guard let recipientHex = decodeRecipientHex(fromNpub: recipientNpub) else { return }
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: safeMessageID, recipientPeerID: peerID.id, senderPeerID: senderRoutingPeerID.id) else {
                SecureLogger.error("NostrTransport: failed to embed PM packet", category: .session)
                return
            }
            guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
                SecureLogger.error("NostrTransport: failed to build Nostr event for PM", category: .session)
                return
            }
            SecureLogger.debug("NostrTransport: sending PM giftWrap id=\(event.id.prefix(16))…", category: .session)
            NostrRelayManager.shared.sendEvent(event)
        }
    }

    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        guard peerID.isValid else { return }
        guard let safeMessageID = InputValidator.validateMessageID(receipt.originalMessageID) else { return }
        let sanitizedReceipt = ReadReceipt(
            originalMessageID: safeMessageID,
            readerID: receipt.readerID,
            readerNickname: InputValidator.validateNickname(receipt.readerNickname) ?? "user"
        )
        if readQueue.contains(where: {
            $0.receipt.originalMessageID == safeMessageID &&
            WiFiPeerIdentity.isEquivalent($0.peerID.id, peerID.id)
        }) {
            return
        }
        if readQueue.count >= readAckQueueCap {
            let overflow = readQueue.count - readAckQueueCap + 1
            if overflow > 0 {
                readQueue.removeFirst(min(overflow, readQueue.count))
            }
        }
        // Enqueue and process with throttling to avoid relay rate limits
        readQueue.append(QueuedRead(receipt: sanitizedReceipt, peerID: peerID))
        processReadQueueIfNeeded()
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        guard peerID.isValid else { return }
        guard let senderRoutingPeerID = normalizedSenderPeerID() else { return }
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID) else { return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
            let content = isFavorite ? "[FAVORITED]:\(senderIdentity.npub)" : "[UNFAVORITED]:\(senderIdentity.npub)"
            SecureLogger.debug("NostrTransport: preparing FAVORITE(\(isFavorite)) to \(recipientNpub.prefix(16))…", category: .session)
            guard let recipientHex = decodeRecipientHex(fromNpub: recipientNpub) else { return }
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostr(content: content, messageID: UUID().uuidString, recipientPeerID: peerID.id, senderPeerID: senderRoutingPeerID.id) else {
                SecureLogger.error("NostrTransport: failed to embed favorite notification", category: .session)
                return
            }
            guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
                SecureLogger.error("NostrTransport: failed to build Nostr event for favorite notification", category: .session)
                return
            }
            SecureLogger.debug("NostrTransport: sending favorite giftWrap id=\(event.id.prefix(16))…", category: .session)
            NostrRelayManager.shared.sendEvent(event)
        }
    }

    func sendBroadcastAnnounce() { /* no-op for Nostr */ }
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {
        guard peerID.isValid else { return }
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return }
        guard let senderRoutingPeerID = normalizedSenderPeerID() else { return }
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: peerID) else { return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { return }
            SecureLogger.debug("NostrTransport: preparing DELIVERED ack for id=\(safeMessageID.prefix(8))… to \(recipientNpub.prefix(16))…", category: .session)
            guard let recipientHex = decodeRecipientHex(fromNpub: recipientNpub) else { return }
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .delivered, messageID: safeMessageID, recipientPeerID: peerID.id, senderPeerID: senderRoutingPeerID.id) else {
                SecureLogger.error("NostrTransport: failed to embed DELIVERED ack", category: .session)
                return
            }
            guard let event = try? NostrProtocol.createPrivateMessage(content: ack, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
                SecureLogger.error("NostrTransport: failed to build Nostr event for DELIVERED ack", category: .session)
                return
            }
            SecureLogger.debug("NostrTransport: sending DELIVERED ack giftWrap id=\(event.id.prefix(16))…", category: .session)
            NostrRelayManager.shared.sendEvent(event)
        }
    }
}

// MARK: - Geohash Helpers

extension NostrTransport {

    // MARK: Geohash ACK helpers
    func sendDeliveryAckGeohash(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        guard InputValidator.validateMessageID(messageID) != nil else { return }
        guard let canonicalRecipientHex = Self.canonicalRecipientHex(from: recipientHex) else { return }
        guard let senderRoutingPeerID = normalizedSenderPeerID() else { return }
        Task { @MainActor in
            SecureLogger.debug("GeoDM: send DELIVERED -> recip=\(canonicalRecipientHex.prefix(8))… mid=\(messageID.prefix(8))… from=\(identity.publicKeyHex.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .delivered, messageID: messageID, senderPeerID: senderRoutingPeerID.id) else { return }
            guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: canonicalRecipientHex, senderIdentity: identity) else { return }
            NostrRelayManager.registerPendingGiftWrap(id: event.id)
            NostrRelayManager.shared.sendEvent(event)
        }
    }

    func sendReadReceiptGeohash(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        guard InputValidator.validateMessageID(messageID) != nil else { return }
        guard let canonicalRecipientHex = Self.canonicalRecipientHex(from: recipientHex) else { return }
        guard let senderRoutingPeerID = normalizedSenderPeerID() else { return }
        Task { @MainActor in
            SecureLogger.debug("GeoDM: send READ -> recip=\(canonicalRecipientHex.prefix(8))… mid=\(messageID.prefix(8))… from=\(identity.publicKeyHex.prefix(8))…", category: .session)
            guard let embedded = NostrEmbeddedBitChat.encodeAckForNostrNoRecipient(type: .readReceipt, messageID: messageID, senderPeerID: senderRoutingPeerID.id) else { return }
            guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: canonicalRecipientHex, senderIdentity: identity) else { return }
            NostrRelayManager.registerPendingGiftWrap(id: event.id)
            NostrRelayManager.shared.sendEvent(event)
        }
    }

    // MARK: Geohash DMs (per-geohash identity)
    func sendPrivateMessageGeohash(content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String) {
        guard let canonicalRecipientHex = Self.canonicalRecipientHex(from: recipientHex) else { return }
        guard content.utf8.count <= InputValidator.Limits.maxMessageLength else { return }
        guard content.utf8.count <= maxEmbeddedPayloadBytes else { return }
        guard InputValidator.validateMessageID(messageID) != nil else { return }
        guard let senderRoutingPeerID = normalizedSenderPeerID() else { return }
        Task { @MainActor in
            SecureLogger.debug("GeoDM: send PM -> recip=\(canonicalRecipientHex.prefix(8))… mid=\(messageID.prefix(8))… from=\(identity.publicKeyHex.prefix(8))…", category: .session)
            // Build embedded BitChat packet without recipient peer ID
            guard let embedded = NostrEmbeddedBitChat.encodePMForNostrNoRecipient(content: content, messageID: messageID, senderPeerID: senderRoutingPeerID.id) else {
                SecureLogger.error("NostrTransport: failed to embed geohash PM packet", category: .session)
                return
            }
            guard let event = try? NostrProtocol.createPrivateMessage(content: embedded, recipientPubkey: canonicalRecipientHex, senderIdentity: identity) else {
                SecureLogger.error("NostrTransport: failed to build Nostr event for geohash PM", category: .session)
                return
            }
            SecureLogger.debug("NostrTransport: sending geohash PM giftWrap id=\(event.id.prefix(16))…", category: .session)
            NostrRelayManager.registerPendingGiftWrap(id: event.id)
            NostrRelayManager.shared.sendEvent(event)
        }
    }
}

// MARK: - Private Helpers

extension NostrTransport {
    static func canonicalRecipientHex(from recipientKey: String) -> String? {
        NostrKeyNormalizer.canonicalHex(recipientKey)
    }

    static func canonicalRecipientNpub(from recipientKey: String) -> String? {
        NostrKeyNormalizer.canonicalNpub(recipientKey)
    }

    private func processReadQueueIfNeeded() {
        guard !isSendingReadAcks else { return }
        guard !readQueue.isEmpty else { return }
        isSendingReadAcks = true
        sendNextReadAck()
    }

    private func sendNextReadAck() {
        guard !readQueue.isEmpty else { isSendingReadAcks = false; return }
        let item = readQueue.removeFirst()
        guard let senderRoutingPeerID = normalizedSenderPeerID() else {
            scheduleNextReadAck()
            return
        }
        Task { @MainActor in
            guard let recipientNpub = resolveRecipientNpub(for: item.peerID) else { scheduleNextReadAck(); return }
            guard let senderIdentity = try? NostrIdentityBridge.getCurrentNostrIdentity() else { scheduleNextReadAck(); return }
            SecureLogger.debug("NostrTransport: preparing READ ack for id=\(item.receipt.originalMessageID.prefix(8))… to \(recipientNpub.prefix(16))…", category: .session)
            guard let recipientHex = decodeRecipientHex(fromNpub: recipientNpub) else { scheduleNextReadAck(); return }
            guard let ack = NostrEmbeddedBitChat.encodeAckForNostr(type: .readReceipt, messageID: item.receipt.originalMessageID, recipientPeerID: item.peerID.id, senderPeerID: senderRoutingPeerID.id) else {
                SecureLogger.error("NostrTransport: failed to embed READ ack", category: .session)
                scheduleNextReadAck(); return
            }
            guard let event = try? NostrProtocol.createPrivateMessage(content: ack, recipientPubkey: recipientHex, senderIdentity: senderIdentity) else {
                SecureLogger.error("NostrTransport: failed to build Nostr event for READ ack", category: .session)
                scheduleNextReadAck(); return
            }
            SecureLogger.debug("NostrTransport: sending READ ack giftWrap id=\(event.id.prefix(16))…", category: .session)
            NostrRelayManager.shared.sendEvent(event)
            scheduleNextReadAck()
        }
    }

    private func scheduleNextReadAck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + readAckInterval) { [weak self] in
            guard let self = self else { return }
            self.isSendingReadAcks = false
            self.processReadQueueIfNeeded()
        }
    }

    private func decodeRecipientHex(fromNpub recipientNpub: String) -> String? {
        Self.canonicalRecipientHex(from: recipientNpub)
    }

    @MainActor
    private func resolveRecipientNpub(for peerID: PeerID) -> String? {
        for candidate in WiFiPeerIdentity.candidateIDs(for: peerID) {
            if let data = Data(hexString: candidate), data.count == 32,
               let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(for: data),
               let npub = favorite.peerNostrPublicKey,
               let canonicalNpub = Self.canonicalRecipientNpub(from: npub) {
                return canonicalNpub
            }

            if candidate.count == 16 {
                let shortPeerID = PeerID(str: candidate)
                guard shortPeerID.isValid else { continue }
                if let favorite = FavoritesPersistenceService.shared.getFavoriteStatus(forPeerID: shortPeerID),
                   let npub = favorite.peerNostrPublicKey,
                   let canonicalNpub = Self.canonicalRecipientNpub(from: npub) {
                    return canonicalNpub
                }
            }
        }
        return nil
    }

    private func normalizedSenderPeerID() -> PeerID? {
        let canonical = senderPeerID.toShort()
        return canonical.isShort ? canonical : nil
    }
}
