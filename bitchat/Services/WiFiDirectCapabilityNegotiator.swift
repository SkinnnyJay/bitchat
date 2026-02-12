import Foundation

struct WiFiDirectCapabilityNegotiator {
    static let currentProtocolVersion = 1
    static let requiredCapabilities: Set<String> = ["pm"]
    static let defaultCapabilities: Set<String> = ["pm", "ack"]
    
    private let protocolVersion: Int
    private let requiredCapabilities: Set<String>
    private let defaultCapabilities: Set<String>

    init(
        protocolVersion: Int = WiFiDirectCapabilityNegotiator.currentProtocolVersion,
        requiredCapabilities: Set<String> = WiFiDirectCapabilityNegotiator.requiredCapabilities,
        defaultCapabilities: Set<String> = WiFiDirectCapabilityNegotiator.defaultCapabilities
    ) {
        self.protocolVersion = protocolVersion
        self.requiredCapabilities = requiredCapabilities
        self.defaultCapabilities = defaultCapabilities
    }

    func discoveryInfo() -> [String: String] {
        [
            "v": String(protocolVersion),
            "caps": defaultCapabilities.sorted().joined(separator: ",")
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
        for (key, value) in dictionary {
            if let stringValue = value as? String {
                parsed[key] = stringValue
            } else if let numberValue = value as? NSNumber {
                parsed[key] = numberValue.stringValue
            }
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
        return requiredCapabilities.isSubset(of: capabilities)
    }

    static func parseCapabilities(_ capabilityString: String) -> Set<String> {
        Set(
            capabilityString
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}
