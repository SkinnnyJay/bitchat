import Foundation

enum FingerprintNormalizer {
    static func canonical(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, Data(hexString: normalized)?.count == 32 else { return nil }
        return normalized
    }
}
