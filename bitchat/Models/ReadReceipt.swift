//
// ReadReceipt.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

struct ReadReceipt: Codable {
    private enum BinaryVersion: UInt8 {
        case v1 = 0x01
    }

    let originalMessageID: String
    let receiptID: String
    var readerID: String  // Who read it
    let readerNickname: String
    let timestamp: Date
    
    init(originalMessageID: String, readerID: String, readerNickname: String) {
        self.originalMessageID = InputValidator.validateMessageID(originalMessageID) ?? UUID().uuidString
        self.receiptID = UUID().uuidString
        let canonicalReader = PeerID(str: readerID).toShort()
        self.readerID = canonicalReader.isShort ? canonicalReader.id : readerID
        self.readerNickname = InputValidator.validateNickname(readerNickname) ?? "user"
        self.timestamp = Date()
    }
    
    // For binary decoding
    private init(originalMessageID: String, receiptID: String, readerID: String, readerNickname: String, timestamp: Date) {
        self.originalMessageID = originalMessageID
        self.receiptID = receiptID
        self.readerID = readerID
        self.readerNickname = readerNickname
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case originalMessageID, receiptID, readerID, readerNickname, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawOriginalMessageID = try container.decode(String.self, forKey: .originalMessageID)
        let rawReceiptID = try container.decode(String.self, forKey: .receiptID)
        let rawReaderID = try container.decode(String.self, forKey: .readerID)
        let rawReaderNickname = try container.decode(String.self, forKey: .readerNickname)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)

        guard let originalMessageID = InputValidator.validateMessageID(rawOriginalMessageID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .originalMessageID,
                in: container,
                debugDescription: "Invalid original message ID"
            )
        }
        guard let receiptID = InputValidator.validateMessageID(rawReceiptID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .receiptID,
                in: container,
                debugDescription: "Invalid receipt ID"
            )
        }
        let canonicalReaderID = PeerID(str: rawReaderID).toShort()
        guard canonicalReaderID.isShort else {
            throw DecodingError.dataCorruptedError(
                forKey: .readerID,
                in: container,
                debugDescription: "Invalid reader peer ID"
            )
        }
        guard let readerNickname = InputValidator.validateNickname(rawReaderNickname) else {
            throw DecodingError.dataCorruptedError(
                forKey: .readerNickname,
                in: container,
                debugDescription: "Invalid reader nickname"
            )
        }
        guard InputValidator.validateTimestamp(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Invalid timestamp"
            )
        }

        self.init(
            originalMessageID: originalMessageID,
            receiptID: receiptID,
            readerID: canonicalReaderID.id,
            readerNickname: readerNickname,
            timestamp: timestamp
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard let originalMessageID = InputValidator.validateMessageID(originalMessageID) else {
            throw EncodingError.invalidValue(
                originalMessageID,
                EncodingError.Context(codingPath: [CodingKeys.originalMessageID], debugDescription: "Invalid original message ID")
            )
        }
        guard let receiptID = InputValidator.validateMessageID(receiptID) else {
            throw EncodingError.invalidValue(
                receiptID,
                EncodingError.Context(codingPath: [CodingKeys.receiptID], debugDescription: "Invalid receipt ID")
            )
        }
        let canonicalReaderID = PeerID(str: readerID).toShort()
        guard canonicalReaderID.isShort else {
            throw EncodingError.invalidValue(
                readerID,
                EncodingError.Context(codingPath: [CodingKeys.readerID], debugDescription: "Invalid reader peer ID")
            )
        }
        guard let readerNickname = InputValidator.validateNickname(readerNickname) else {
            throw EncodingError.invalidValue(
                readerNickname,
                EncodingError.Context(codingPath: [CodingKeys.readerNickname], debugDescription: "Invalid reader nickname")
            )
        }
        guard InputValidator.validateTimestamp(timestamp) else {
            throw EncodingError.invalidValue(
                timestamp,
                EncodingError.Context(codingPath: [CodingKeys.timestamp], debugDescription: "Invalid timestamp")
            )
        }

        try container.encode(originalMessageID, forKey: .originalMessageID)
        try container.encode(receiptID, forKey: .receiptID)
        try container.encode(canonicalReaderID.id, forKey: .readerID)
        try container.encode(readerNickname, forKey: .readerNickname)
        try container.encode(timestamp, forKey: .timestamp)
    }
    
    func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }
    
    static func decode(from data: Data) -> ReadReceipt? {
        try? JSONDecoder().decode(ReadReceipt.self, from: data)
    }
    
    // MARK: - Binary Encoding
    
    func toBinaryData() -> Data {
        guard let safeOriginalMessageID = InputValidator.validateMessageID(originalMessageID),
              let safeReceiptID = InputValidator.validateMessageID(receiptID),
              let safeReaderNickname = InputValidator.validateNickname(readerNickname),
              InputValidator.validateTimestamp(timestamp) else {
            return Data()
        }
        let canonicalReaderID = PeerID(str: readerID).toShort()
        guard canonicalReaderID.isShort,
              let readerData = Data(hexString: canonicalReaderID.id),
              readerData.count == 8 else {
            return Data()
        }

        var data = Data()
        data.append(BinaryVersion.v1.rawValue)
        data.appendString(safeOriginalMessageID, maxLength: 255)
        data.appendString(safeReceiptID, maxLength: 255)
        data.append(readerData)
        data.appendDate(timestamp)
        data.appendString(safeReaderNickname, maxLength: 255)
        return data
    }
    
    static func fromBinaryData(_ data: Data) -> ReadReceipt? {
        // Create defensive copy
        let dataCopy = Data(data)
        guard !dataCopy.isEmpty else { return nil }
        
        if dataCopy.first == BinaryVersion.v1.rawValue {
            return decodeV1BinaryData(dataCopy)
        }
        
        return decodeLegacyBinaryData(dataCopy)
    }
    
    private static func decodeV1BinaryData(_ dataCopy: Data) -> ReadReceipt? {
        var offset = 0
        guard let version = dataCopy.readUInt8(at: &offset),
              version == BinaryVersion.v1.rawValue else { return nil }
        guard let originalMessageIDRaw = dataCopy.readString(at: &offset, maxLength: 255),
              let originalMessageID = InputValidator.validateMessageID(originalMessageIDRaw),
              let receiptIDRaw = dataCopy.readString(at: &offset, maxLength: 255),
              let receiptID = InputValidator.validateMessageID(receiptIDRaw),
              let readerIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let readerID = readerIDData.hexEncodedString()
        guard PeerID(str: readerID).isShort else { return nil }
        guard let timestamp = dataCopy.readDate(at: &offset),
              InputValidator.validateTimestamp(timestamp),
              let readerNicknameRaw = dataCopy.readString(at: &offset, maxLength: 255),
              let readerNickname = InputValidator.validateNickname(readerNicknameRaw),
              offset == dataCopy.count else { return nil }
        
        return ReadReceipt(
            originalMessageID: originalMessageID,
            receiptID: receiptID,
            readerID: readerID,
            readerNickname: readerNickname,
            timestamp: timestamp
        )
    }
    
    private static func decodeLegacyBinaryData(_ dataCopy: Data) -> ReadReceipt? {
        
        // Minimum size: 2 UUIDs (32) + readerID (8) + timestamp (8) + min nickname
        guard dataCopy.count >= 49 else { return nil }
        
        var offset = 0
        
        guard let originalMessageIDRaw = dataCopy.readUUID(at: &offset),
              let originalMessageID = InputValidator.validateMessageID(originalMessageIDRaw),
              let receiptIDRaw = dataCopy.readUUID(at: &offset),
              let receiptID = InputValidator.validateMessageID(receiptIDRaw) else { return nil }
        
        guard let readerIDData = dataCopy.readFixedBytes(at: &offset, count: 8) else { return nil }
        let readerID = readerIDData.hexEncodedString()
        guard PeerID(str: readerID).isShort else { return nil }
        
        guard let timestamp = dataCopy.readDate(at: &offset),
              InputValidator.validateTimestamp(timestamp),
              let readerNicknameRaw = dataCopy.readString(at: &offset),
              let readerNickname = InputValidator.validateNickname(readerNicknameRaw),
              offset == dataCopy.count else { return nil }
        
        return ReadReceipt(originalMessageID: originalMessageID,
                          receiptID: receiptID,
                          readerID: readerID,
                          readerNickname: readerNickname,
                          timestamp: timestamp)
    }
}
