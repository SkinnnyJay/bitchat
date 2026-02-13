import Foundation

enum NostrKeyNormalizer {
    static func canonicalHex(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if let data = Data(hexString: normalized), data.count == 32 {
            return normalized
        }

        guard let (hrp, data) = try? Bech32.decode(normalized), hrp == "npub", data.count == 32 else {
            return nil
        }
        return data.hexEncodedString()
    }

    static func canonicalNpub(_ value: String?) -> String? {
        guard let canonicalHex = canonicalHex(value),
              let data = Data(hexString: canonicalHex),
              data.count == 32 else { return nil }
        return try? Bech32.encode(hrp: "npub", data: data)
    }
}
