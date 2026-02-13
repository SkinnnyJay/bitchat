import Foundation

/// Comprehensive input validation for BitChat protocol
/// Prevents injection attacks, buffer overflows, and malformed data
struct InputValidator {
    
    // MARK: - Constants
    
    struct Limits {
        static let maxNicknameLength = 50
        // BinaryProtocol payload length is encoded as UInt16. Leave protocol
        // headroom by capping user content below the hard UInt16 ceiling.
        static let maxMessageLength = 60_000
        // Packet/message identifier fields are encoded as UInt8 length in several
        // paths. Keep a safety margin below 255 for cross-path compatibility.
        static let maxMessageIDLength = 200
    }
    
    // MARK: - String Content Validation
    
    /// Validates and sanitizes user-provided strings used in UI
    static func validateUserString(_ string: String, maxLength: Int) -> String? {
        // Check empty
        guard !string.isEmpty else { return nil }

        // Trim whitespace
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Check length
        guard trimmed.count <= maxLength else { return nil }

        // Remove control characters
        let controlChars = CharacterSet.controlCharacters
        let cleaned = trimmed.components(separatedBy: controlChars).joined()
        
        // Ensure valid UTF-8 (should already be, but double-check)
        guard cleaned.data(using: .utf8) != nil else { return nil }
        
        // Prevent zero-width characters and other invisible unicode
        let invisibleChars = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        let visible = cleaned.components(separatedBy: invisibleChars).joined()
        
        return visible.isEmpty ? nil : visible
    }
    
    /// Validates nickname
    static func validateNickname(_ nickname: String) -> String? {
        return validateUserString(nickname, maxLength: Limits.maxNicknameLength)
    }

    /// Validates message identifiers across transports.
    static func validateMessageID(_ messageID: String) -> String? {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep IDs canonical: reject IDs that require trimming.
        guard trimmed == messageID else { return nil }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        guard trimmed.utf8.count <= Limits.maxMessageIDLength else { return nil }

        let controlChars = CharacterSet.controlCharacters
        guard trimmed.rangeOfCharacter(from: controlChars) == nil else { return nil }

        let invisibleChars = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{FEFF}")
        guard trimmed.rangeOfCharacter(from: invisibleChars) == nil else { return nil }

        guard trimmed.data(using: .utf8) != nil else { return nil }
        return trimmed
    }
    
    // MARK: - Protocol Field Validation

    // Note: Message type validation is performed closer to decoding using
    // MessageType/NoisePayloadType enums; keeping validator free of stale lists.

    /// Validates timestamp is reasonable (not too far in past or future)
    static func validateTimestamp(_ timestamp: Date) -> Bool {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let oneHourFromNow = now.addingTimeInterval(3600)
        return timestamp >= oneHourAgo && timestamp <= oneHourFromNow
    }

}
