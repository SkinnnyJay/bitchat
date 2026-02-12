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
    private let inboundTimestampMaxAgeSeconds: TimeInterval
    private let inboundTimestampFutureSkewSeconds: TimeInterval
    private let inboundDedupMaxCount: Int
    private let inboundDedupMaxAgeSeconds: TimeInterval
    private let inboundPayloadMaxBytes: Int
    private let inboundSenderRateWindowSeconds: TimeInterval
    private let inboundSenderRateMaxEvents: Int
    private let inboundSenderRateMaxTrackedSenders: Int
    private let nowProvider: () -> Date
    private var inboundDedupByKey: [String: Date] = [:]
    private var inboundDedupOrder: [String] = []
    private var inboundSenderEventTimestamps: [String: [Date]] = [:]
    private var isRunning = false

    weak var delegate: HybridTransportManagerDelegate?

    init(
        meshTransport: Transport,
        wifiTransport: WiFiDirectTransport? = nil,
        wifiRoutingPolicy: WiFiDirectRoutingPolicy = WiFiDirectRoutingPolicy(),
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.meshTransport = meshTransport
        self.wifiTransport = wifiTransport ?? WiFiDirectTransport(localPeerID: meshTransport.myPeerID.id)
        self.wifiRoutingPolicy = wifiRoutingPolicy
        self.inboundTimestampMaxAgeSeconds = TransportConfig.messageRouterInboundWiFiTimestampMaxAgeSeconds
        self.inboundTimestampFutureSkewSeconds = TransportConfig.messageRouterInboundWiFiTimestampFutureSkewSeconds
        self.inboundDedupMaxCount = TransportConfig.messageRouterInboundWiFiDedupMaxCount
        self.inboundDedupMaxAgeSeconds = TransportConfig.messageRouterInboundWiFiDedupMaxAgeSeconds
        self.inboundPayloadMaxBytes = TransportConfig.messageRouterInboundWiFiPayloadMaxBytes
        self.inboundSenderRateWindowSeconds = TransportConfig.messageRouterInboundWiFiSenderRateWindowSeconds
        self.inboundSenderRateMaxEvents = TransportConfig.messageRouterInboundWiFiSenderRateMaxEvents
        self.inboundSenderRateMaxTrackedSenders = TransportConfig.messageRouterInboundWiFiSenderRateMaxTrackedSenders
        self.nowProvider = nowProvider
        self.wifiTransport.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        meshTransport.startServices()
        wifiTransport.startDiscovery()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        wifiTransport.stopDiscovery()
        meshTransport.stopServices()
    }

    deinit {
        stop()
    }

    @discardableResult
    func sendPrivate(
        _ content: String,
        to peerID: PeerID,
        recipientNickname: String,
        messageID: String
    ) -> HybridOutboundRoute {
        let canUseWiFiPayload = !messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && content.utf8.count <= InputValidator.Limits.maxMessageLength
        let recipientID = peerID.id
        let resolvedRecipientID = resolveWiFiPeerIdentifier(for: peerID, requiredCapability: "pm")
        let meshReachable = meshTransport.isPeerReachable(peerID)
        let shouldUseWiFi = wifiRoutingPolicy.shouldUseWiFi(
            payloadBytes: content.utf8.count,
            recipientPeerID: resolvedRecipientID ?? recipientID,
            wifiAvailable: wifiTransport.isAvailable,
            wifiPeerIDs: Set(wifiTransport.currentPeers)
        )
        let shouldFallbackToWiFi = !meshReachable && resolvedRecipientID != nil && canUseWiFiPayload

        if canUseWiFiPayload, (shouldUseWiFi || shouldFallbackToWiFi), let resolvedRecipientID {
            let safeRecipientNickname = InputValidator.validateNickname(recipientNickname) ?? "user"
            let envelope = WiFiDirectPrivateEnvelope(
                senderPeerID: meshTransport.myPeerID.id,
                recipientPeerID: resolvedRecipientID,
                recipientNickname: safeRecipientNickname,
                messageID: messageID,
                content: content
            )
            if let data = try? JSONEncoder().encode(envelope),
               (try? wifiTransport.send(data, to: resolvedRecipientID)) != nil {
                return .wifiDirect
            }
        }

        meshTransport.sendPrivateMessage(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
        return .mesh
    }

    private func resolveWiFiPeerIdentifier(for peerID: PeerID, requiredCapability: String) -> String? {
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
        WiFiPeerIdentity.candidateIDs(for: peerID)
    }

    private func senderMatchesTransportPeerID(claimedSenderID: String, transportPeerID: String) -> Bool {
        WiFiPeerIdentity.isEquivalent(claimedSenderID, transportPeerID)
    }

    private func recipientMatchesLocalPeerID(_ claimedRecipientID: String) -> Bool {
        WiFiPeerIdentity.isEquivalent(claimedRecipientID, meshTransport.myPeerID.id)
    }

    private func isInboundTimestampAcceptable(_ createdAtMs: UInt64) -> Bool {
        let createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000)
        let now = nowProvider()
        if createdAt > now.addingTimeInterval(inboundTimestampFutureSkewSeconds) {
            return false
        }
        if createdAt < now.addingTimeInterval(-inboundTimestampMaxAgeSeconds) {
            return false
        }
        return true
    }

    private func shouldAcceptInboundEnvelope(dedupKey: String) -> Bool {
        let now = nowProvider()
        cleanupInboundDedup(now: now)
        if inboundDedupByKey[dedupKey] != nil {
            return false
        }
        inboundDedupByKey[dedupKey] = now
        inboundDedupOrder.append(dedupKey)
        if inboundDedupOrder.count > inboundDedupMaxCount {
            let overflow = inboundDedupOrder.count - inboundDedupMaxCount
            for _ in 0..<overflow {
                let oldest = inboundDedupOrder.removeFirst()
                inboundDedupByKey.removeValue(forKey: oldest)
            }
        }
        return true
    }

    private func cleanupInboundDedup(now: Date) {
        let cutoff = now.addingTimeInterval(-inboundDedupMaxAgeSeconds)
        while let first = inboundDedupOrder.first,
              let timestamp = inboundDedupByKey[first],
              timestamp < cutoff {
            inboundDedupOrder.removeFirst()
            inboundDedupByKey.removeValue(forKey: first)
        }
    }

    private func normalizedIdentityKey(_ peerID: String) -> String {
        WiFiPeerIdentity.normalizedKey(peerID)
    }

    private func allowInboundEvent(from senderID: String) -> Bool {
        let normalizedSenderID = normalizedIdentityKey(senderID)
        let now = nowProvider()
        cleanupInboundSenderRate(now: now)
        if inboundSenderEventTimestamps[normalizedSenderID] == nil,
           inboundSenderEventTimestamps.count >= inboundSenderRateMaxTrackedSenders {
            return false
        }
        let cutoff = now.addingTimeInterval(-inboundSenderRateWindowSeconds)
        var events = inboundSenderEventTimestamps[normalizedSenderID] ?? []
        events.removeAll { $0 < cutoff }
        if events.count >= inboundSenderRateMaxEvents {
            inboundSenderEventTimestamps[normalizedSenderID] = events
            return false
        }
        events.append(now)
        inboundSenderEventTimestamps[normalizedSenderID] = events
        return true
    }

    private func cleanupInboundSenderRate(now: Date) {
        let cutoff = now.addingTimeInterval(-inboundSenderRateWindowSeconds)
        guard !inboundSenderEventTimestamps.isEmpty else { return }
        let senders = Array(inboundSenderEventTimestamps.keys)
        for sender in senders {
            guard let events = inboundSenderEventTimestamps[sender] else { continue }
            let filtered = events.filter { $0 >= cutoff }
            if filtered.isEmpty {
                inboundSenderEventTimestamps.removeValue(forKey: sender)
            } else if filtered.count != events.count {
                inboundSenderEventTimestamps[sender] = filtered
            }
        }
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
            guard data.count <= self.inboundPayloadMaxBytes else { return }
            guard self.allowInboundEvent(from: peerID) else { return }
            guard let envelope = try? JSONDecoder().decode(WiFiDirectPrivateEnvelope.self, from: data),
                  envelope.messageType == "private",
                  envelope.version == WiFiDirectEnvelopeVersion.current,
                  self.senderMatchesTransportPeerID(claimedSenderID: envelope.senderPeerID, transportPeerID: peerID),
                  self.recipientMatchesLocalPeerID(envelope.recipientPeerID),
                  self.isInboundTimestampAcceptable(envelope.createdAtMs),
                  !envelope.messageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  envelope.content.utf8.count <= InputValidator.Limits.maxMessageLength else {
                return
            }
            let dedupKey = "pm:\(self.normalizedIdentityKey(envelope.senderPeerID)):\(envelope.messageID)"
            guard self.shouldAcceptInboundEnvelope(dedupKey: dedupKey) else { return }
            self.delegate?.hybridTransportManager(self, didReceivePrivateEnvelope: envelope)
        }
    }

    nonisolated func wifiTransportDidChangeAvailability(_ isAvailable: Bool) {}
}
