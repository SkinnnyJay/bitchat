import Foundation

/// Decides which transport should carry a private message when multiple
/// transports are available.
///
/// Current policy:
/// - If only one transport is available, use it.
/// - If both are available, prefer mesh for smaller payloads and Nostr for
///   larger payloads.
/// - If none are available, return `nil` so caller can queue for later.
struct TransportRoutingPolicy {
    enum PrivateRoute: Equatable {
        case mesh
        case nostr
    }

    struct Context: Equatable {
        let payloadBytes: Int
        let meshReachable: Bool
        let nostrAvailable: Bool
    }

    private let nostrPreferredPayloadBytes: Int

    init(nostrPreferredPayloadBytes: Int = TransportConfig.nostrPreferredPayloadBytes) {
        self.nostrPreferredPayloadBytes = max(1, nostrPreferredPayloadBytes)
    }

    func routePrivateMessage(_ context: Context) -> PrivateRoute? {
        switch (context.meshReachable, context.nostrAvailable) {
        case (false, false):
            return nil
        case (true, false):
            return .mesh
        case (false, true):
            return .nostr
        case (true, true):
            if context.payloadBytes >= nostrPreferredPayloadBytes {
                return .nostr
            }
            return .mesh
        }
    }
}
