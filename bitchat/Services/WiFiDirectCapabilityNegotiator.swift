import Foundation

struct WiFiDirectCapabilityNegotiator {
    private enum Limits {
        static let maxVersionLength = 16
        static let maxCapabilitiesLength = 512
    }

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
        self.protocolVersion = protocolVersion
        self.requiredCapabilitiesSet = requiredCapabilities
        self.defaultCapabilitiesSet = defaultCapabilities
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
        if let version = parseStringValue(dictionary["v"], maxLength: Limits.maxVersionLength) {
            parsed["v"] = version
        }
        if let capabilities = parseStringValue(dictionary["caps"], maxLength: Limits.maxCapabilitiesLength) {
            parsed["caps"] = capabilities
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
        Set(
            capabilityString
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private func parseStringValue(_ value: Any?, maxLength: Int) -> String? {
        let stringValue: String?
        if let string = value as? String {
            stringValue = string
        } else if let number = value as? NSNumber {
            stringValue = number.stringValue
        } else {
            stringValue = nil
        }
        guard let stringValue else { return nil }
        guard !stringValue.isEmpty, stringValue.utf8.count <= maxLength else { return nil }
        return stringValue
    }
}
