import Foundation

struct WiFiDirectCapabilityNegotiator {
    static let currentProtocolVersion = 1
    static let requiredCapabilities: Set<String> = ["pm"]
    static let defaultCapabilities: Set<String> = ["pm", "ack"]

    func discoveryInfo() -> [String: String] {
        [
            "v": String(Self.currentProtocolVersion),
            "caps": Self.defaultCapabilities.sorted().joined(separator: ",")
        ]
    }

    func isPeerCompatible(discoveryInfo: [String: String]?) -> Bool {
        guard let discoveryInfo else {
            // Backward compatibility: peers without metadata are treated as legacy-compatible.
            return true
        }

        if let versionRaw = discoveryInfo["v"],
           let version = Int(versionRaw),
           version != Self.currentProtocolVersion {
            return false
        }

        guard let capabilityString = discoveryInfo["caps"] else {
            return true
        }

        let capabilities = Set(
            capabilityString
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        return !Self.requiredCapabilities.isDisjoint(with: capabilities)
    }
}
