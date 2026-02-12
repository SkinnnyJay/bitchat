import Foundation

enum WiFiPeerIdentity {
    static func normalizedKey(_ peerID: String) -> String {
        let trimmed = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return PeerID(str: trimmed).toShort().id
    }

    static func isEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let leftRaw = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightRaw = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leftRaw.isEmpty, !rightRaw.isEmpty else { return false }

        let left = PeerID(str: leftRaw)
        let right = PeerID(str: rightRaw)
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

    static func normalizedOutboxPeerID(for peerID: PeerID) -> PeerID {
        if let noiseKey = peerID.noiseKey {
            return PeerID(publicKey: noiseKey)
        }
        if peerID.prefix != .empty {
            return PeerID(str: peerID.bare)
        }
        return peerID
    }
}
