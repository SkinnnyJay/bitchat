//
// BitchatMessage.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Represents a user-visible message in the BitChat system.
/// Handles both broadcast messages and private encrypted messages,
/// with support for mentions, replies, and delivery tracking.
/// - Note: This is the primary data model for chat messages
final class BitchatMessage: Codable {
    let id: String
    let sender: String
    let content: String
    let timestamp: Date
    let isRelay: Bool
    let originalSender: String?
    let isPrivate: Bool
    let recipientNickname: String?
    let senderPeerID: PeerID?
    let mentions: [String]?  // Array of mentioned nicknames
    var deliveryStatus: DeliveryStatus? // Delivery tracking
    
    // Cached formatted text (not included in Codable)
    private var _cachedFormattedText: [String: AttributedString] = [:]
    
    func getCachedFormattedText(isDark: Bool, isSelf: Bool) -> AttributedString? {
        return _cachedFormattedText["\(isDark)-\(isSelf)"]
    }
    
    func setCachedFormattedText(_ text: AttributedString, isDark: Bool, isSelf: Bool) {
        _cachedFormattedText["\(isDark)-\(isSelf)"] = text
    }
    
    // Codable implementation
    enum CodingKeys: String, CodingKey {
        case id, sender, content, timestamp, isRelay, originalSender
        case isPrivate, recipientNickname, senderPeerID, mentions, deliveryStatus
    }
    
    init(
        id: String? = nil,
        sender: String,
        content: String,
        timestamp: Date,
        isRelay: Bool,
        originalSender: String? = nil,
        isPrivate: Bool = false,
        recipientNickname: String? = nil,
        senderPeerID: PeerID? = nil,
        mentions: [String]? = nil,
        deliveryStatus: DeliveryStatus? = nil
    ) {
        if let id, let safeID = InputValidator.validateMessageID(id) {
            self.id = safeID
        } else {
            self.id = UUID().uuidString
        }
        self.sender = sender
        self.content = content
        self.timestamp = timestamp
        self.isRelay = isRelay
        self.originalSender = originalSender
        self.isPrivate = isPrivate
        self.recipientNickname = recipientNickname
        self.senderPeerID = senderPeerID
        self.mentions = mentions
        self.deliveryStatus = deliveryStatus ?? (isPrivate ? .sending : nil)
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawID = try container.decode(String.self, forKey: .id)
        guard let safeID = InputValidator.validateMessageID(rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid message ID"
            )
        }

        let rawSender = try container.decode(String.self, forKey: .sender)
        let safeSender = InputValidator.validateNickname(rawSender) ?? "unknown"

        let safeContent = try container.decode(String.self, forKey: .content)
        guard safeContent.utf8.count <= InputValidator.Limits.maxMessageLength else {
            throw DecodingError.dataCorruptedError(
                forKey: .content,
                in: container,
                debugDescription: "Message content exceeds max length"
            )
        }

        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let isRelay = try container.decode(Bool.self, forKey: .isRelay)
        let originalSenderRaw = try container.decodeIfPresent(String.self, forKey: .originalSender)
        let isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        let recipientNicknameRaw = try container.decodeIfPresent(String.self, forKey: .recipientNickname)
        let senderPeerIDRaw = try container.decodeIfPresent(PeerID.self, forKey: .senderPeerID)
        let mentionsRaw = try container.decodeIfPresent([String].self, forKey: .mentions)
        let deliveryStatus = try container.decodeIfPresent(DeliveryStatus.self, forKey: .deliveryStatus)

        self.id = safeID
        self.sender = safeSender
        self.content = safeContent
        self.timestamp = timestamp
        self.isRelay = isRelay
        self.originalSender = originalSenderRaw.flatMap(InputValidator.validateNickname)
        self.isPrivate = isPrivate
        self.recipientNickname = recipientNicknameRaw.flatMap(InputValidator.validateNickname)
        self.senderPeerID = senderPeerIDRaw?.isValid == true ? senderPeerIDRaw : nil
        self.mentions = mentionsRaw?
            .compactMap(InputValidator.validateNickname)
            .filter { !$0.isEmpty }
        self.deliveryStatus = deliveryStatus
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        guard let safeID = InputValidator.validateMessageID(id) else {
            throw EncodingError.invalidValue(
                id,
                EncodingError.Context(codingPath: [CodingKeys.id], debugDescription: "Invalid message ID")
            )
        }
        guard content.utf8.count <= InputValidator.Limits.maxMessageLength else {
            throw EncodingError.invalidValue(
                content,
                EncodingError.Context(codingPath: [CodingKeys.content], debugDescription: "Message content exceeds max length")
            )
        }

        try container.encode(safeID, forKey: .id)
        try container.encode(InputValidator.validateNickname(sender) ?? "unknown", forKey: .sender)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isRelay, forKey: .isRelay)
        try container.encodeIfPresent(originalSender.flatMap(InputValidator.validateNickname), forKey: .originalSender)
        try container.encode(isPrivate, forKey: .isPrivate)
        try container.encodeIfPresent(recipientNickname.flatMap(InputValidator.validateNickname), forKey: .recipientNickname)
        try container.encodeIfPresent(senderPeerID?.isValid == true ? senderPeerID : nil, forKey: .senderPeerID)
        let safeMentions = mentions?
            .compactMap(InputValidator.validateNickname)
            .filter { !$0.isEmpty }
        try container.encodeIfPresent(safeMentions?.isEmpty == true ? nil : safeMentions, forKey: .mentions)
        try container.encodeIfPresent(deliveryStatus, forKey: .deliveryStatus)
    }
}

// MARK: - Equatable Conformance

extension BitchatMessage: Equatable {
    static func == (lhs: BitchatMessage, rhs: BitchatMessage) -> Bool {
        return lhs.id == rhs.id &&
               lhs.sender == rhs.sender &&
               lhs.content == rhs.content &&
               lhs.timestamp == rhs.timestamp &&
               lhs.isRelay == rhs.isRelay &&
               lhs.originalSender == rhs.originalSender &&
               lhs.isPrivate == rhs.isPrivate &&
               lhs.recipientNickname == rhs.recipientNickname &&
               lhs.senderPeerID == rhs.senderPeerID &&
               lhs.mentions == rhs.mentions &&
               lhs.deliveryStatus == rhs.deliveryStatus
    }
}

// MARK: - Binary encoding

extension BitchatMessage {
    func toBinaryPayload() -> Data? {
        var data = Data()
        let safeSender = InputValidator.validateNickname(sender) ?? "unknown"
        let safeOriginalSender = originalSender.flatMap { InputValidator.validateNickname($0) }
        let safeRecipientNickname = recipientNickname.flatMap { InputValidator.validateNickname($0) }
        let safeSenderPeerID = senderPeerID?.isValid == true ? senderPeerID : nil
        let safeMentions = mentions?
            .compactMap { InputValidator.validateNickname($0) }
            .filter { !$0.isEmpty }
        
        // Message format:
        // - Flags: 1 byte (bit 0: isRelay, bit 1: isPrivate, bit 2: hasOriginalSender, bit 3: hasRecipientNickname, bit 4: hasSenderPeerID, bit 5: hasMentions)
        // - Timestamp: 8 bytes (seconds since epoch)
        // - ID length: 1 byte
        // - ID: variable
        // - Sender length: 1 byte
        // - Sender: variable
        // - Content length: 2 bytes
        // - Content: variable
        // Optional fields based on flags:
        // - Original sender length + data
        // - Recipient nickname length + data
        // - Sender peer ID length + data
        // - Mentions array
        
        var flags: UInt8 = 0
        if isRelay { flags |= 0x01 }
        if isPrivate { flags |= 0x02 }
        if safeOriginalSender != nil { flags |= 0x04 }
        if safeRecipientNickname != nil { flags |= 0x08 }
        if safeSenderPeerID != nil { flags |= 0x10 }
        if let safeMentions, !safeMentions.isEmpty { flags |= 0x20 }
        
        data.append(flags)
        
        // Timestamp (in milliseconds)
        let timestampMillis = UInt64(timestamp.timeIntervalSince1970 * 1000)
        // Encode as 8 bytes, big-endian
        for i in (0..<8).reversed() {
            data.append(UInt8((timestampMillis >> (i * 8)) & 0xFF))
        }
        
        // ID
        if let idData = id.data(using: .utf8) {
            data.append(UInt8(min(idData.count, 255)))
            data.append(idData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Sender
        if let senderData = safeSender.data(using: .utf8) {
            data.append(UInt8(min(senderData.count, 255)))
            data.append(senderData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Content
        guard let contentData = content.data(using: .utf8),
              contentData.count <= InputValidator.Limits.maxMessageLength else {
            return nil
        }
        let length = UInt16(contentData.count)
        // Encode length as 2 bytes, big-endian
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(contentData)
        
        // Optional fields
        if let originalSender = safeOriginalSender, let origData = originalSender.data(using: .utf8) {
            data.append(UInt8(min(origData.count, 255)))
            data.append(origData.prefix(255))
        }
        
        if let recipientNickname = safeRecipientNickname, let recipData = recipientNickname.data(using: .utf8) {
            data.append(UInt8(min(recipData.count, 255)))
            data.append(recipData.prefix(255))
        }
        
        if let peerData = safeSenderPeerID?.id.data(using: .utf8) {
            data.append(UInt8(min(peerData.count, 255)))
            data.append(peerData.prefix(255))
        }
        
        // Mentions array
        if let mentions = safeMentions {
            data.append(UInt8(min(mentions.count, 255))) // Number of mentions
            for mention in mentions.prefix(255) {
                if let mentionData = mention.data(using: .utf8) {
                    data.append(UInt8(min(mentionData.count, 255)))
                    data.append(mentionData.prefix(255))
                } else {
                    data.append(0)
                }
            }
        }
        
        
        return data
    }
    
    convenience init?(_ data: Data) {
        // Create an immutable copy to prevent threading issues
        let dataCopy = Data(data)
        
        
        guard dataCopy.count >= 13 else {
            return nil
        }
        
        var offset = 0
        
        // Flags
        guard offset < dataCopy.count else {
            return nil
        }
        let flags = dataCopy[offset]; offset += 1
        let isRelay = (flags & 0x01) != 0
        let isPrivate = (flags & 0x02) != 0
        let hasOriginalSender = (flags & 0x04) != 0
        let hasRecipientNickname = (flags & 0x08) != 0
        let hasSenderPeerID = (flags & 0x10) != 0
        let hasMentions = (flags & 0x20) != 0
        
        // Timestamp
        guard offset + 8 <= dataCopy.count else {
            return nil
        }
        let timestampData = dataCopy[offset..<offset+8]
        let timestampMillis = timestampData.reduce(0) { result, byte in
            (result << 8) | UInt64(byte)
        }
        offset += 8
        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000.0)
        
        // ID
        guard offset < dataCopy.count else {
            return nil
        }
        let idLength = Int(dataCopy[offset]); offset += 1
        guard offset + idLength <= dataCopy.count else {
            return nil
        }
        guard let rawID = String(data: dataCopy[offset..<offset+idLength], encoding: .utf8),
              let id = InputValidator.validateMessageID(rawID) else {
            return nil
        }
        offset += idLength
        
        // Sender
        guard offset < dataCopy.count else {
            return nil
        }
        let senderLength = Int(dataCopy[offset]); offset += 1
        guard offset + senderLength <= dataCopy.count else {
            return nil
        }
        let senderRaw = String(data: dataCopy[offset..<offset+senderLength], encoding: .utf8) ?? ""
        let sender = InputValidator.validateNickname(senderRaw) ?? "unknown"
        offset += senderLength
        
        // Content
        guard offset + 2 <= dataCopy.count else {
            return nil
        }
        let contentLengthData = dataCopy[offset..<offset+2]
        let contentLength = Int(contentLengthData.reduce(0) { result, byte in
            (result << 8) | UInt16(byte)
        })
        offset += 2
        guard offset + contentLength <= dataCopy.count else {
            return nil
        }
        
        let content = String(data: dataCopy[offset..<offset+contentLength], encoding: .utf8) ?? ""
        guard content.utf8.count <= InputValidator.Limits.maxMessageLength else { return nil }
        offset += contentLength
        
        // Optional fields
        var originalSender: String?
        if hasOriginalSender && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                let rawOriginalSender = String(data: dataCopy[offset..<offset+length], encoding: .utf8) ?? ""
                originalSender = InputValidator.validateNickname(rawOriginalSender)
                offset += length
            }
        }
        
        var recipientNickname: String?
        if hasRecipientNickname && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                let rawNickname = String(data: dataCopy[offset..<offset+length], encoding: .utf8) ?? ""
                recipientNickname = InputValidator.validateNickname(rawNickname)
                offset += length
            }
        }
        
        var senderPeerID: PeerID?
        if hasSenderPeerID && offset < dataCopy.count {
            let length = Int(dataCopy[offset]); offset += 1
            if offset + length <= dataCopy.count {
                if let candidate = PeerID(data: dataCopy[offset..<offset+length]),
                   candidate.isValid {
                    senderPeerID = candidate
                } else {
                    senderPeerID = nil
                }
                offset += length
            }
        }
        
        // Mentions array
        var mentions: [String]?
        if hasMentions && offset < dataCopy.count {
            let mentionCount = Int(dataCopy[offset]); offset += 1
            if mentionCount > 0 {
                mentions = []
                for _ in 0..<mentionCount {
                    if offset < dataCopy.count {
                        let length = Int(dataCopy[offset]); offset += 1
                        if offset + length <= dataCopy.count {
                            if let mention = String(data: dataCopy[offset..<offset+length], encoding: .utf8),
                               let sanitizedMention = InputValidator.validateNickname(mention) {
                                mentions?.append(sanitizedMention)
                            }
                            offset += length
                        }
                    }
                }
            }
        }
        
        self.init(
            id: id,
            sender: sender,
            content: content,
            timestamp: timestamp,
            isRelay: isRelay,
            originalSender: originalSender,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: senderPeerID,
            mentions: mentions
        )
    }
}

// MARK: - Helpers

extension BitchatMessage {
    
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    var formattedTimestamp: String {
        Self.timestampFormatter.string(from: timestamp)
    }
}

extension Array where Element == BitchatMessage {
    /// Filters out empty ones and deduplicate by ID while preserving order (from oldest to newest)
    func cleanedAndDeduped() -> [Element] {
        let arr = filter {
            guard $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
            guard InputValidator.validateMessageID($0.id) != nil else { return false }
            return $0.content.utf8.count <= InputValidator.Limits.maxMessageLength
        }
        guard arr.count > 1 else {
            return arr
        }
        var seen = Set<String>()
        var dedup: [BitchatMessage] = []
        for m in arr.sorted(by: { $0.timestamp < $1.timestamp }) {
            if !seen.contains(m.id) {
                dedup.append(m)
                seen.insert(m.id)
            }
        }
        return dedup
    }
}
