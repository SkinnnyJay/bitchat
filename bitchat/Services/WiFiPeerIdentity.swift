import Foundation

enum WiFiPeerIdentity {
    private static func shouldPreservePrefix(_ prefix: PeerID.Prefix) -> Bool {
        prefix == .geoDM || prefix == .geoChat
    }

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

        let lowercaseTrimmed = trimmed.lowercased()
        if let matchedPrefix = PeerID.Prefix.allCases.first(where: { prefix in
            prefix != .empty && lowercaseTrimmed.hasPrefix(prefix.rawValue)
        }) {
            let suffix = trimmed.dropFirst(matchedPrefix.rawValue.count)
            return PeerID(str: matchedPrefix.rawValue + suffix)
        }

        return PeerID(str: trimmed)
    }

    static func normalizedKey(_ peerID: String) -> String {
        let trimmed = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let canonical = canonicalPeerID(PeerID(str: trimmed))
        if let noiseKey = canonical.noiseKey {
            return PeerID(publicKey: noiseKey).id.lowercased()
        }
        if canonical.prefix != .empty {
            if shouldPreservePrefix(canonical.prefix) {
                return canonical.id.lowercased()
            }
            return canonical.bare.lowercased()
        }
        return canonical.id.lowercased()
    }

    static func isEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedKey(lhs)
        let right = normalizedKey(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    static func lookupKeys(for peerID: String) -> [String] {
        let trimmed = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys: [String] = []
        func appendKey(_ key: String) {
            let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }
            if !keys.contains(candidate) {
                keys.append(candidate)
            }
        }

        appendKey(trimmed)
        appendKey(trimmed.lowercased())
        for candidate in candidateIDs(for: PeerID(str: trimmed)) {
            appendKey(candidate)
            appendKey(candidate.lowercased())
        }
        return keys
    }

    static func candidateIDs(for peerID: PeerID) -> [String] {
        let canonicalPeerID = canonicalPeerID(peerID)
        var candidates: [String] = [canonicalPeerID.id]
        let preservePrefix = shouldPreservePrefix(canonicalPeerID.prefix)
        if canonicalPeerID.prefix != .empty,
           !preservePrefix,
           !canonicalPeerID.bare.isEmpty {
            candidates.append(canonicalPeerID.bare)
        }

        if !preservePrefix {
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
        if shouldPreservePrefix(canonicalPeerID.prefix) {
            return canonicalPeerID
        }
        if let noiseKey = canonicalPeerID.noiseKey {
            return PeerID(publicKey: noiseKey)
        }
        if canonicalPeerID.prefix != .empty {
            return PeerID(str: canonicalPeerID.bare)
        }
        return canonicalPeerID
    }
}
