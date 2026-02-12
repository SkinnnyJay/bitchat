import Foundation

enum WiFiPeerIdentity {
    private static func canonicalPeerID(_ peerID: PeerID) -> PeerID {
        if peerID.prefix != .empty {
            let bare = peerID.bare.trimmingCharacters(in: .whitespacesAndNewlines)
            if bare.isEmpty {
                return peerID
            }
            return PeerID(str: peerID.prefix.rawValue + bare)
        }

        let trimmed = peerID.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return peerID
        }
        return PeerID(str: trimmed)
    }

    static func normalizedKey(_ peerID: String) -> String {
        let trimmed = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let canonical = canonicalPeerID(PeerID(str: trimmed))
        if let noiseKey = canonical.noiseKey {
            return PeerID(publicKey: noiseKey).id
        }
        if canonical.prefix != .empty {
            return canonical.bare
        }
        return canonical.id
    }

    static func isEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedKey(lhs)
        let right = normalizedKey(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    static func candidateIDs(for peerID: PeerID) -> [String] {
        let canonicalPeerID = canonicalPeerID(peerID)
        var candidates: [String] = [canonicalPeerID.id]
        if canonicalPeerID.prefix != .empty, !canonicalPeerID.bare.isEmpty {
            candidates.append(canonicalPeerID.bare)
        }

        let short = canonicalPeerID.toShort().id
        if short != canonicalPeerID.id {
            candidates.append(short)
        }

        if let noiseKey = canonicalPeerID.noiseKey {
            let full = noiseKey.hexEncodedString()
            if full != canonicalPeerID.id {
                candidates.append(full)
            }
        }

        var unique: [String] = []
        for candidate in candidates {
            let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedCandidate.isEmpty else { continue }
            if !unique.contains(normalizedCandidate) {
                unique.append(normalizedCandidate)
            }
        }
        return unique
    }

    static func normalizedOutboxPeerID(for peerID: PeerID) -> PeerID {
        let canonicalPeerID = canonicalPeerID(peerID)
        if let noiseKey = canonicalPeerID.noiseKey {
            return PeerID(publicKey: noiseKey)
        }
        if canonicalPeerID.prefix != .empty {
            return PeerID(str: canonicalPeerID.bare)
        }
        return canonicalPeerID
    }
}
