import Foundation

// MARK: - BitChat-over-Nostr Adapter

struct NostrEmbeddedBitChat {
    /// Build a `bitchat1:` base64url-encoded BitChat packet carrying a private message for Nostr DMs.
    static func encodePMForNostr(content: String, messageID: String, recipientPeerID: String, senderPeerID: String) -> String? {
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return nil }
        guard let recipientIDHex = normalizeRoutingPeerIDHex(recipientPeerID) else { return nil }
        guard let senderIDHex = normalizeRoutingPeerIDHex(senderPeerID) else { return nil }
        guard let senderData = Data(hexString: senderIDHex), senderData.count == 8 else { return nil }
        // TLV-encode the private message
        let pm = PrivateMessagePacket(messageID: safeMessageID, content: content)
        guard let tlv = pm.encode() else { return nil }

        // Prefix with NoisePayloadType
        var payload = Data([NoisePayloadType.privateMessage.rawValue])
        payload.append(tlv)

        guard let recipientData = Data(hexString: recipientIDHex), recipientData.count == 8 else { return nil }

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: senderData,
            recipientID: recipientData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` base64url-encoded BitChat packet carrying a delivery/read ack for Nostr DMs.
    static func encodeAckForNostr(type: NoisePayloadType, messageID: String, recipientPeerID: String, senderPeerID: String) -> String? {
        guard type == .delivered || type == .readReceipt else { return nil }
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return nil }
        guard let recipientIDHex = normalizeRoutingPeerIDHex(recipientPeerID) else { return nil }
        guard let senderIDHex = normalizeRoutingPeerIDHex(senderPeerID) else { return nil }
        guard let senderData = Data(hexString: senderIDHex), senderData.count == 8 else { return nil }

        var payload = Data([type.rawValue])
        payload.append(Data(safeMessageID.utf8))

        guard let recipientData = Data(hexString: recipientIDHex), recipientData.count == 8 else { return nil }

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: senderData,
            recipientID: recipientData,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` ACK (delivered/read) without an embedded recipient peer ID (geohash DMs).
    static func encodeAckForNostrNoRecipient(type: NoisePayloadType, messageID: String, senderPeerID: String) -> String? {
        guard type == .delivered || type == .readReceipt else { return nil }
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return nil }
        guard let senderIDHex = normalizeRoutingPeerIDHex(senderPeerID) else { return nil }
        guard let senderData = Data(hexString: senderIDHex), senderData.count == 8 else { return nil }

        var payload = Data([type.rawValue])
        payload.append(Data(safeMessageID.utf8))

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: senderData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    /// Build a `bitchat1:` payload without an embedded recipient peer ID (used for geohash DMs).
    static func encodePMForNostrNoRecipient(content: String, messageID: String, senderPeerID: String) -> String? {
        guard let safeMessageID = InputValidator.validateMessageID(messageID) else { return nil }
        guard let senderIDHex = normalizeRoutingPeerIDHex(senderPeerID) else { return nil }
        guard let senderData = Data(hexString: senderIDHex), senderData.count == 8 else { return nil }
        let pm = PrivateMessagePacket(messageID: safeMessageID, content: content)
        guard let tlv = pm.encode() else { return nil }

        var payload = Data([NoisePayloadType.privateMessage.rawValue])
        payload.append(tlv)

        let packet = BitchatPacket(
            type: MessageType.noiseEncrypted.rawValue,
            senderID: senderData,
            recipientID: nil,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            payload: payload,
            signature: nil,
            ttl: 7
        )

        guard let data = packet.toBinaryData() else { return nil }
        return "bitchat1:" + base64URLEncode(data)
    }

    private static func normalizeRoutingPeerIDHex(_ rawPeerID: String) -> String? {
        let trimmed = rawPeerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let canonical = PeerID(str: trimmed).toShort()
        guard canonical.isValid else { return nil }
        guard let data = Data(hexString: canonical.bare), data.count == 8 else { return nil }
        return canonical.bare.lowercased()
    }

    /// Base64url encode without padding
    private static func base64URLEncode(_ data: Data) -> String {
        let b64 = data.base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
