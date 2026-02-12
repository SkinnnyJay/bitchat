import Foundation

enum WiFiPeerIdentity {
    static func normalizedKey(_ peerID: String) -> String {
        PeerID(str: peerID).toShort().id
    }

    static func isEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = PeerID(str: lhs)
        let right = PeerID(str: rhs)
        if left.id == right.id {
            return true
        }
        return left.toShort().id == right.toShort().id
    }

    static func candidateIDs(for peerID: PeerID) -> [String] {
        var candidates: [String] = [peerID.id]
        if peerID.prefix != .empty, !peerID.bare.isEmpty {
            candidates.append(peerID.bare)
        }

        let short = peerID.toShort().id
        if short != peerID.id {
            candidates.append(short)
        }

        if let noiseKey = peerID.noiseKey {
            let full = noiseKey.hexEncodedString()
            if full != peerID.id {
                candidates.append(full)
            }
        }

        var unique: [String] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }
}
