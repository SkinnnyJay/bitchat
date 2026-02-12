import Foundation

struct WiFiDirectCapabilityNegotiator {
    private enum Limits {
        static let maxVersionLength = 16
        static let maxCapabilitiesLength = 512
        static let maxCapabilityTokenLength = 32
        static let maxCapabilityTokenCount = 32
    }
    static let invalidFieldSentinel = "__invalid__"

    static let currentProtocolVersion = 1
    static let requiredCapabilities: Set<String> = ["pm"]
    static let defaultCapabilities: Set<String> = ["pm", "ack"]
    
    private let protocolVersion: Int
    private let requiredCapabilitiesSet: Set<String>
    private let defaultCapabilitiesSet: Set<String>

    init(
        protocolVersion: Int = WiFiDirectCapabilityNegotiator.currentProtocolVersion,
        requiredCapabilities: Set<String> = WiFiDirectCapabilityNegotiator.requiredCapabilities,
        defaultCapabilities: Set<String> = WiFiDirectCapabilityNegotiator.defaultCapabilities
    ) {
        self.protocolVersion = max(1, protocolVersion)
        let sanitizedRequired = Self.sanitizeCapabilities(requiredCapabilities)
        let sanitizedDefault = Self.sanitizeCapabilities(defaultCapabilities)
        self.requiredCapabilitiesSet = sanitizedRequired
        self.defaultCapabilitiesSet = sanitizedDefault.union(sanitizedRequired)
    }

    func discoveryInfo() -> [String: String] {
        [
            "v": String(protocolVersion),
            "caps": defaultCapabilitiesSet.sorted().joined(separator: ",")
        ]
    }

    func invitationContextData() -> Data? {
        try? JSONSerialization.data(withJSONObject: discoveryInfo(), options: [])
    }

    func parseDiscoveryInfo(from context: Data?) -> [String: String]? {
        guard let context, !context.isEmpty else { return nil }
        guard let rawObject = try? JSONSerialization.jsonObject(with: context, options: []),
              let dictionary = rawObject as? [String: Any] else {
            return nil
        }
        var parsed: [String: String] = [:]
        if dictionary.keys.contains("v") {
            parsed["v"] = parseStringValue(dictionary["v"], maxLength: Limits.maxVersionLength)
                ?? Self.invalidFieldSentinel
        }
        if dictionary.keys.contains("caps") {
            parsed["caps"] = parseStringValue(dictionary["caps"], maxLength: Limits.maxCapabilitiesLength)
                ?? Self.invalidFieldSentinel
        }
        return parsed.isEmpty ? nil : parsed
    }

    func isPeerCompatible(discoveryInfo: [String: String]?) -> Bool {
        guard let discoveryInfo else {
            // Backward compatibility: peers without metadata are treated as legacy-compatible.
            return true
        }

        if let versionRaw = discoveryInfo["v"] {
            guard let version = Int(versionRaw) else { return false }
            if version != protocolVersion {
                return false
            }
        }

        guard let capabilityString = discoveryInfo["caps"] else {
            return true
        }

        let capabilities = Self.parseCapabilities(capabilityString)
        return requiredCapabilitiesSet.isSubset(of: capabilities)
    }

    static func parseCapabilities(_ capabilityString: String) -> Set<String> {
        sanitizeCapabilities(
            Set(
                capabilityString
                    .split(separator: ",")
                    .map { String($0) }
            )
        )
    }

    private static func sanitizeCapabilities(_ capabilities: Set<String>) -> Set<String> {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        Set(
            capabilities
                .sorted()
                .prefix(Limits.maxCapabilityTokenCount)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter {
                    !$0.isEmpty &&
                    $0.utf8.count <= Limits.maxCapabilityTokenLength &&
                    $0.rangeOfCharacter(from: allowed.inverted) == nil
                }
        )
    }

    private func parseStringValue(_ value: Any?, maxLength: Int) -> String? {
        let stringValue: String?
        if let string = value as? String {
            stringValue = string
        } else if let bool = value as? Bool {
            _ = bool
            stringValue = nil
        } else if let number = value as? NSNumber {
            stringValue = number.stringValue
        } else {
            stringValue = nil
        }
        guard let stringValue else { return nil }
        let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxLength else { return nil }
        return trimmed
    }
}
