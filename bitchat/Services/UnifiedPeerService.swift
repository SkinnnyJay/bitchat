//
//  UnifiedPeerService.swift
//  bitchat
//
//  Unified peer state management combining mesh connectivity and favorites
//  This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation
import Combine
import SwiftUI

/// Single source of truth for peer state, combining mesh connectivity and favorites
@MainActor
final class UnifiedPeerService: ObservableObject, TransportPeerEventsDelegate {
    
    // MARK: - Published Properties
    
    @Published private(set) var peers: [BitchatPeer] = []
    @Published private(set) var connectedPeerIDs: Set<String> = []
    @Published private(set) var favorites: [BitchatPeer] = []
    @Published private(set) var mutualFavorites: [BitchatPeer] = []
    
    // MARK: - Private Properties
    
    private var peerIndex: [String: BitchatPeer] = [:]
    private var fingerprintCache: [String: String] = [:]  // peerID -> fingerprint
    private var fingerprintCacheOrder: [String] = []
    private var connectedPeerLookupKeys: Set<String> = []
    private let meshService: Transport
    private let identityManager: SecureIdentityStateManagerProtocol
    weak var messageRouter: MessageRouter?
    private let favoritesService = FavoritesPersistenceService.shared
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init(meshService: Transport, identityManager: SecureIdentityStateManagerProtocol) {
        self.meshService = meshService
        self.identityManager = identityManager
        
        // Subscribe to changes from both services
        setupSubscriptions()
        
        // Perform initial update
        Task { @MainActor in
            updatePeers()
        }
    }
    
    // MARK: - Setup
    
    private func setupSubscriptions() {
        // Subscribe to mesh peer updates via delegate (preferred over publishers)
        meshService.peerEventsDelegate = self
        
        // Also listen for favorite change notifications
        NotificationCenter.default.publisher(for: .favoriteStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePeers()
            }
            .store(in: &cancellables)
    }

    // TransportPeerEventsDelegate
    func didUpdatePeerSnapshots(_ peers: [TransportPeerSnapshot]) {
        updatePeers()
    }
    
    // MARK: - Core Update Logic
    
    private func updatePeers() {
        let meshPeers = meshService.currentPeerSnapshots()
        // If we have no direct links at all, peers should not be marked reachable
        // "Reachable" means mesh-attached via at least one live link.
        let hasAnyConnected = meshPeers.contains { $0.isConnected }
        let favorites = favoritesService.favorites
        
        var enrichedPeers: [BitchatPeer] = []
        var connected: Set<PeerID> = []
        var addedPeerIDs: Set<PeerID> = []
        var candidateMeshPeers: [BitchatPeer] = []
        
        // Phase 1: Add all mesh peers (connected and reachable)
        for peerInfo in meshPeers {
            let peerID = peerInfo.peerID
            guard peerID != meshService.myPeerID else { continue }  // Never add self
            let resolvedNoisePublicKey = Self.resolvedNoisePublicKey(for: peerInfo)
            
            let peer = buildPeerFromMesh(
                peerInfo: peerInfo,
                resolvedNoisePublicKey: resolvedNoisePublicKey,
                favorites: favorites,
                meshAttached: hasAnyConnected
            )

            candidateMeshPeers.append(peer)
        }

        let dedupedMeshPeers = Self.deduplicateMeshPeers(candidateMeshPeers)
        enrichedPeers.append(contentsOf: dedupedMeshPeers)
        for peer in dedupedMeshPeers {
            if peer.isConnected { connected.insert(peer.peerID) }
            addedPeerIDs.insert(peer.peerID)
            if let fingerprint = Self.fingerprintFromPeer(peer) {
                Self.cacheFingerprint(
                    fingerprint,
                    for: peer.peerID.id,
                    in: &fingerprintCache,
                    order: &fingerprintCacheOrder,
                    cap: TransportConfig.uiFingerprintCacheCap
                )
            }
        }
        
        // Phase 2: Add offline favorites that we actively favorite
        for (favoriteKey, favorite) in favorites where favorite.isFavorite {
            let peerID = PeerID(hexData: favoriteKey)
            let shouldInclude = Self.shouldIncludeFavoriteAsOfflinePeer(
                favoriteNoiseKey: favoriteKey,
                favoriteNickname: favorite.peerNickname,
                existingPeers: enrichedPeers,
                addedPeerIDs: addedPeerIDs
            )
            if !shouldInclude { continue }
            
            let peer = buildPeerFromFavorite(favorite: favorite, peerID: peerID.id)
            enrichedPeers.append(peer)
            addedPeerIDs.insert(peerID)
            
            // Update fingerprint cache
            Self.cacheFingerprint(
                favoriteKey.sha256Fingerprint(),
                for: peerID.id,
                in: &fingerprintCache,
                order: &fingerprintCacheOrder,
                cap: TransportConfig.uiFingerprintCacheCap
            )
        }
        Self.pruneFingerprintCache(
            &fingerprintCache,
            order: &fingerprintCacheOrder,
            referenceIDs: Self.fingerprintCacheReferenceIDs(from: enrichedPeers),
            cap: TransportConfig.uiFingerprintCacheCap
        )
        
        // Phase 3: Sort peers
        enrichedPeers.sort { lhs, rhs in
            // Connectivity rank: connected > reachable > others
            func rank(_ p: BitchatPeer) -> Int { p.isConnected ? 2 : (p.isReachable ? 1 : 0) }
            let lr = rank(lhs), rr = rank(rhs)
            if lr != rr { return lr > rr }
            // Then favorites inside same rank
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            // Finally alphabetical
            return lhs.displayName < rhs.displayName
        }
        
        // Phase 4: Build subsets and indices
        var favoritesList: [BitchatPeer] = []
        var mutualsList: [BitchatPeer] = []
        let newIndex = Self.buildPeerIndex(from: enrichedPeers)
        
        for peer in enrichedPeers {
            if peer.isFavorite {
                favoritesList.append(peer)
            }
            if peer.isMutualFavorite {
                mutualsList.append(peer)
            }
        }
        
        // Phase 5: Filter out offline non-mutual peers and update published properties
        let filtered = enrichedPeers.filter { p in
            p.isConnected || p.isReachable || p.isMutualFavorite
        }
        self.peers = filtered
        self.connectedPeerIDs = Set(connected.map(\.id))
        self.connectedPeerLookupKeys = Self.buildConnectedPeerLookupKeys(from: self.connectedPeerIDs)
        self.favorites = favoritesList
        self.mutualFavorites = mutualsList
        self.peerIndex = newIndex
        
        // Log summary (commented out to reduce noise)
        // let connectedCount = connected.count
        // let offlineCount = enrichedPeers.count - connectedCount
        // Peer update: \(enrichedPeers.count) total (\(connectedCount) connected, \(offlineCount) offline)
    }
    
    // MARK: - Peer Building Helpers
    
    private func buildPeerFromMesh(
        peerInfo: TransportPeerSnapshot,
        resolvedNoisePublicKey: Data?,
        favorites: [Data: FavoritesPersistenceService.FavoriteRelationship],
        meshAttached: Bool
    ) -> BitchatPeer {
        // Determine reachability based on lastSeen and identity trust
        let now = Date()
        let fingerprint = resolvedNoisePublicKey?.sha256Fingerprint()
        let isVerified = fingerprint.map { identityManager.isVerified(fingerprint: $0) } ?? false
        let isFav = resolvedNoisePublicKey.flatMap { favorites[$0]?.isFavorite } ?? false
        let retention: TimeInterval = (isVerified || isFav) ? TransportConfig.bleReachabilityRetentionVerifiedSeconds : TransportConfig.bleReachabilityRetentionUnverifiedSeconds
        // A peer is reachable if we recently saw them AND we are attached to the mesh
        let withinRetention = now.timeIntervalSince(peerInfo.lastSeen) <= retention
        let isReachable = peerInfo.isConnected ? true : (withinRetention && meshAttached)

        var peer = BitchatPeer(
            peerID: peerInfo.peerID,
            noisePublicKey: resolvedNoisePublicKey ?? Data(),
            nickname: peerInfo.nickname,
            lastSeen: peerInfo.lastSeen,
            isConnected: peerInfo.isConnected,
            isReachable: isReachable
        )
        
        // Check for favorite status
        if let noiseKey = resolvedNoisePublicKey,
           let favoriteStatus = favorites[noiseKey] {
            peer.favoriteStatus = favoriteStatus
            peer.nostrPublicKey = favoriteStatus.peerNostrPublicKey
        }
        
        return peer
    }
    
    private func buildPeerFromFavorite(
        favorite: FavoritesPersistenceService.FavoriteRelationship,
        peerID: String
    ) -> BitchatPeer {
        var peer = BitchatPeer(
            peerID: PeerID(str: peerID),
            noisePublicKey: favorite.peerNoisePublicKey,
            nickname: favorite.peerNickname,
            lastSeen: favorite.lastUpdated,
            isConnected: false,
            isReachable: false
        )
        
        peer.favoriteStatus = favorite
        peer.nostrPublicKey = favorite.peerNostrPublicKey
        
        return peer
    }
    
    // MARK: - Public Methods

    static func lookupKeys(for peerID: String) -> [String] {
        WiFiPeerIdentity.lookupKeys(for: peerID)
    }

    static func resolvePeer(from peerIndex: [String: BitchatPeer], peerID: String) -> BitchatPeer? {
        let lookupKeys = lookupKeys(for: peerID)
        guard !lookupKeys.isEmpty else { return nil }

        for key in lookupKeys {
            if let peer = peerIndex[key] {
                return peer
            }
        }

        let normalizedTarget = WiFiPeerIdentity.normalizedKey(peerID)
        guard !normalizedTarget.isEmpty else { return nil }
        return peerIndex.values.first {
            WiFiPeerIdentity.normalizedKey($0.peerID.id) == normalizedTarget
        }
    }

    static func resolveCachedFingerprint(from cache: [String: String], peerID: String) -> String? {
        for key in lookupKeys(for: peerID) {
            if let fingerprint = cache[key],
               let canonicalFingerprint = canonicalFingerprint(fingerprint) {
                return canonicalFingerprint
            }
        }
        let normalizedTarget = WiFiPeerIdentity.normalizedKey(peerID)
        guard !normalizedTarget.isEmpty else { return nil }
        return cache.first { key, value in
            guard canonicalFingerprint(value) != nil else { return false }
            WiFiPeerIdentity.normalizedKey(key) == normalizedTarget
        }.flatMap { canonicalFingerprint($0.value) }
    }

    static func cacheFingerprint(
        _ fingerprint: String,
        for peerID: String,
        in cache: inout [String: String]
    ) {
        guard let canonicalFingerprint = canonicalFingerprint(fingerprint) else { return }
        for key in lookupKeys(for: peerID) {
            cache[key] = canonicalFingerprint
        }
        let normalized = WiFiPeerIdentity.normalizedKey(peerID)
        if !normalized.isEmpty {
            cache[normalized] = canonicalFingerprint
        }
    }

    static func cacheFingerprint(
        _ fingerprint: String,
        for peerID: String,
        in cache: inout [String: String],
        order: inout [String],
        cap: Int
    ) {
        guard let canonicalFingerprint = canonicalFingerprint(fingerprint) else { return }
        guard cap > 0 else {
            cache.removeAll()
            order.removeAll()
            return
        }

        var orderedKeys: [String] = []
        func appendKey(_ key: String) {
            guard !key.isEmpty else { return }
            if !orderedKeys.contains(key) {
                orderedKeys.append(key)
            }
        }

        for key in lookupKeys(for: peerID) {
            appendKey(key)
        }
        let normalized = WiFiPeerIdentity.normalizedKey(peerID)
        if !normalized.isEmpty {
            appendKey(normalized)
        }

        for key in orderedKeys {
            cache[key] = canonicalFingerprint
            if let existingIndex = order.firstIndex(of: key) {
                order.remove(at: existingIndex)
            }
            order.append(key)
        }

        while order.count > cap {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    static func fingerprintCacheReferenceIDs(from peers: [BitchatPeer]) -> [String] {
        var referenceIDs: [String] = []
        func appendID(_ id: String) {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !referenceIDs.contains(trimmed) {
                referenceIDs.append(trimmed)
            }
        }

        for peer in peers {
            appendID(peer.peerID.id)
            if !peer.peerID.isGeoDM && !peer.peerID.isGeoChat,
               peer.noisePublicKey.count == 32 {
                appendID(peer.noisePublicKey.hexEncodedString())
            }
        }

        return referenceIDs
    }

    static func pruneFingerprintCache(
        _ cache: inout [String: String],
        order: inout [String],
        referenceIDs: [String],
        cap: Int
    ) {
        guard cap > 0 else {
            cache.removeAll()
            order.removeAll()
            return
        }

        var allowedKeys: Set<String> = []
        for referenceID in referenceIDs {
            for key in lookupKeys(for: referenceID) {
                allowedKeys.insert(key)
            }
            let normalized = WiFiPeerIdentity.normalizedKey(referenceID)
            if !normalized.isEmpty {
                allowedKeys.insert(normalized)
            }
        }

        if !allowedKeys.isEmpty {
            cache = cache.filter { allowedKeys.contains($0.key) }
            order = order.filter { allowedKeys.contains($0) && cache[$0] != nil }
        } else {
            cache.removeAll()
            order.removeAll()
            return
        }

        while order.count > cap {
            let evicted = order.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    static func resolveFingerprintFromMesh(
        for peerID: String,
        using resolver: (PeerID) -> String?
    ) -> String? {
        for lookupKey in lookupKeys(for: peerID) {
            if let fingerprint = resolver(PeerID(str: lookupKey)),
               let canonicalFingerprint = canonicalFingerprint(fingerprint) {
                return canonicalFingerprint
            }
        }
        return nil
    }

    static func canonicalFingerprint(_ fingerprint: String) -> String? {
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64, Data(hexString: trimmed) != nil else { return nil }
        return trimmed
    }

    static func buildPeerIndex(from peers: [BitchatPeer]) -> [String: BitchatPeer] {
        var index: [String: BitchatPeer] = [:]
        for peer in peers {
            for key in lookupKeys(for: peer.peerID.id) where index[key] == nil {
                index[key] = peer
            }
            if !peer.peerID.isGeoDM && !peer.peerID.isGeoChat,
               peer.noisePublicKey.count == 32 {
                let fullNoiseID = peer.noisePublicKey.hexEncodedString()
                for key in lookupKeys(for: fullNoiseID) where index[key] == nil {
                    index[key] = peer
                }
            }
            let normalized = WiFiPeerIdentity.normalizedKey(peer.peerID.id)
            if !normalized.isEmpty, index[normalized] == nil {
                index[normalized] = peer
            }
        }
        return index
    }

    static func buildConnectedPeerLookupKeys(from connectedPeerIDs: Set<String>) -> Set<String> {
        var lookupKeys: Set<String> = []
        for connectedPeerID in connectedPeerIDs {
            for key in lookupKeys(for: connectedPeerID) {
                lookupKeys.insert(key)
            }
            let normalized = WiFiPeerIdentity.normalizedKey(connectedPeerID)
            if !normalized.isEmpty {
                lookupKeys.insert(normalized)
            }
        }
        return lookupKeys
    }

    static func isPeerOnline(
        _ peerID: String,
        connectedPeerIDs: Set<String>,
        connectedPeerLookupKeys: Set<String>
    ) -> Bool {
        if connectedPeerIDs.contains(peerID) {
            return true
        }
        for key in lookupKeys(for: peerID) where connectedPeerLookupKeys.contains(key) {
            return true
        }
        let normalized = WiFiPeerIdentity.normalizedKey(peerID)
        guard !normalized.isEmpty else { return false }
        return connectedPeerLookupKeys.contains(normalized)
    }

    static func meshDedupKey(for peerID: PeerID) -> String {
        let normalized = WiFiPeerIdentity.normalizedKey(peerID.id)
        if !normalized.isEmpty {
            return normalized
        }
        return peerID.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func deduplicateMeshPeers(_ peers: [BitchatPeer]) -> [BitchatPeer] {
        var peersByDedupKey: [String: BitchatPeer] = [:]
        for peer in peers {
            let dedupKey = meshDedupKey(for: peer.peerID)
            if let existing = peersByDedupKey[dedupKey] {
                if shouldPreferMeshPeer(peer, over: existing) {
                    peersByDedupKey[dedupKey] = peer
                }
            } else {
                peersByDedupKey[dedupKey] = peer
            }
        }
        return Array(peersByDedupKey.values)
    }

    static func shouldPreferMeshPeer(_ candidate: BitchatPeer, over existing: BitchatPeer) -> Bool {
        if candidate.isConnected != existing.isConnected {
            return candidate.isConnected
        }
        if candidate.isReachable != existing.isReachable {
            return candidate.isReachable
        }

        let candidateHasNoiseKey = candidate.noisePublicKey.count == 32
        let existingHasNoiseKey = existing.noisePublicKey.count == 32
        if candidateHasNoiseKey != existingHasNoiseKey {
            return candidateHasNoiseKey
        }

        if candidate.lastSeen != existing.lastSeen {
            return candidate.lastSeen > existing.lastSeen
        }
        return candidate.peerID.id < existing.peerID.id
    }

    static func shouldIncludeFavoriteAsOfflinePeer(
        favoriteNoiseKey: Data,
        favoriteNickname: String,
        existingPeers: [BitchatPeer],
        addedPeerIDs: Set<PeerID>
    ) -> Bool {
        guard favoriteNoiseKey.count == 32 else {
            return false
        }
        let favoritePeerID = PeerID(hexData: favoriteNoiseKey)
        if addedPeerIDs.contains(favoritePeerID) {
            return false
        }

        if existingPeers.contains(where: { WiFiPeerIdentity.isEquivalent($0.peerID.id, favoritePeerID.id) }) {
            return false
        }

        let sanitizedNickname = InputValidator.validateNickname(favoriteNickname)
        if let sanitizedNickname {
            let isConnectedByNickname = existingPeers.contains {
                $0.isConnected && InputValidator.validateNickname($0.nickname) == sanitizedNickname
            }
            if isConnectedByNickname {
                return false
            }
        }

        return true
    }

    static func resolvedNoisePublicKey(for snapshot: TransportPeerSnapshot) -> Data? {
        if let noisePublicKey = snapshot.noisePublicKey, noisePublicKey.count == 32 {
            return noisePublicKey
        }
        for lookupKey in lookupKeys(for: snapshot.peerID.id) {
            if let peerIDNoiseKey = PeerID(str: lookupKey).noiseKey, peerIDNoiseKey.count == 32 {
                return peerIDNoiseKey
            }
        }
        return nil
    }

    static func fingerprintFromPeer(_ peer: BitchatPeer) -> String? {
        guard peer.noisePublicKey.count == 32 else { return nil }
        return peer.noisePublicKey.sha256Fingerprint()
    }
    
    /// Get peer by ID
    func getPeer(by id: String) -> BitchatPeer? {
        Self.resolvePeer(from: peerIndex, peerID: id)
    }
    
    /// Get peer ID for nickname
    func getPeerID(for nickname: String) -> String? {
        Self.peerID(for: nickname, in: peers)
    }

    static func peerID(for nickname: String, in peers: [BitchatPeer]) -> String? {
        let target = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let normalizedTarget = target.lowercased()

        let candidates = peers.filter { peer in
            let display = peer.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawNick = peer.nickname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return display == normalizedTarget || rawNick == normalizedTarget
        }
        guard !candidates.isEmpty else { return nil }
        return bestPeerForNicknameMatch(candidates)?.peerID.id
    }

    static func bestPeerForNicknameMatch(_ peers: [BitchatPeer]) -> BitchatPeer? {
        guard !peers.isEmpty else { return nil }
        peers.max { lhs, rhs in
            if nicknameMatchPriority(lhs) != nicknameMatchPriority(rhs) {
                return nicknameMatchPriority(lhs) < nicknameMatchPriority(rhs)
            }
            if lhs.lastSeen != rhs.lastSeen {
                return lhs.lastSeen < rhs.lastSeen
            }
            return lhs.peerID.id > rhs.peerID.id
        }
    }

    private static func nicknameMatchPriority(_ peer: BitchatPeer) -> Int {
        if peer.isConnected { return 3 }
        if peer.isReachable { return 2 }
        if peer.isMutualFavorite { return 1 }
        return 0
    }
    
    /// Check if peer is online
    func isOnline(_ peerID: String) -> Bool {
        Self.isPeerOnline(
            peerID,
            connectedPeerIDs: connectedPeerIDs,
            connectedPeerLookupKeys: connectedPeerLookupKeys
        )
    }
    
    /// Check if peer is blocked
    func isBlocked(_ peerID: String) -> Bool {
        // Get fingerprint
        guard let fingerprint = getFingerprint(for: peerID) else { return false }
        
        // Check SecureIdentityStateManager for block status
        if let identity = identityManager.getSocialIdentity(for: fingerprint) {
            return identity.isBlocked
        }
        
        return false
    }
    
    /// Toggle favorite status
    func toggleFavorite(_ peerID: String) {
        guard let peer = getPeer(by: peerID) else { 
            SecureLogger.warning("⚠️ Cannot toggle favorite - peer not found: \(peerID)", category: .session)
            return 
        }
        
        let wasFavorite = peer.isFavorite
        
        // Get the actual nickname for logging and saving
        var actualNickname = peer.nickname
        
        // Debug logging to understand the issue
        SecureLogger.debug("🔍 Toggle favorite - peer.nickname: '\(peer.nickname)', peer.displayName: '\(peer.displayName)', peerID: \(peerID)", category: .session)
        
        if actualNickname.isEmpty {
            // Try to get from mesh service's current peer list
            if let meshPeerNickname = meshService.peerNickname(peerID: PeerID(str: peerID)) {
                actualNickname = meshPeerNickname
                SecureLogger.debug("🔍 Got nickname from mesh service: '\(actualNickname)'", category: .session)
            }
        }
        
        // Use displayName as fallback (which shows ID prefix if nickname is empty)
        let finalNickname = actualNickname.isEmpty ? peer.displayName : actualNickname
        
        if wasFavorite {
            // Remove favorite
            favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
        } else {
            // Get or derive peer's Nostr public key if not already known
            var peerNostrKey = peer.nostrPublicKey
            if peerNostrKey == nil {
                // Try to get from NostrIdentityBridge association
                peerNostrKey = NostrIdentityBridge.getNostrPublicKey(for: peer.noisePublicKey)
            }
            
            // Add favorite
            favoritesService.addFavorite(
                peerNoisePublicKey: peer.noisePublicKey,
                peerNostrPublicKey: peerNostrKey,
                peerNickname: finalNickname
            )
        }
        
        // Log the final nickname being saved
        SecureLogger.debug("⭐️ Toggled favorite for '\(finalNickname)' (peerID: \(peerID), was: \(wasFavorite), now: \(!wasFavorite))", category: .session)
        
        // Send favorite notification to the peer via router (mesh or Nostr)
        if let router = messageRouter {
            router.sendFavoriteNotification(to: PeerID(str: peerID), isFavorite: !wasFavorite)
        } else {
            // Fallback to mesh-only if router not yet wired
            meshService.sendFavoriteNotification(to: PeerID(str: peerID), isFavorite: !wasFavorite)
        }
        
        // Force update of peers to reflect the change
        updatePeers()
        
        // Force UI update by notifying SwiftUI directly
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }
    
    /// Toggle blocked status
    func toggleBlocked(_ peerID: String) {
        guard let fingerprint = getFingerprint(for: peerID) else { return }
        
        // Get or create social identity
        var identity = identityManager.getSocialIdentity(for: fingerprint)
            ?? SocialIdentity(
                fingerprint: fingerprint,
                localPetname: nil,
                claimedNickname: getPeer(by: peerID)?.displayName ?? "Unknown",
                trustLevel: .unknown,
                isFavorite: false,
                isBlocked: false,
                notes: nil
            )
        
        // Toggle blocked status
        identity.isBlocked = !identity.isBlocked
        
        // Can't be both favorite and blocked
        if identity.isBlocked {
            identity.isFavorite = false
            // Also remove from favorites service
            if let peer = getPeer(by: peerID) {
                favoritesService.removeFavorite(peerNoisePublicKey: peer.noisePublicKey)
            }
        }
        
        identityManager.updateSocialIdentity(identity)
    }
    
    /// Get fingerprint for peer ID
    func getFingerprint(for peerID: String) -> String? {
        // Check cache first
        if let cached = Self.resolveCachedFingerprint(from: fingerprintCache, peerID: peerID) {
            return cached
        }
        
        // Try to get from mesh service
        if let fingerprint = Self.resolveFingerprintFromMesh(
            for: peerID,
            using: { [meshService] candidate in meshService.getFingerprint(for: candidate) }
        ) {
            Self.cacheFingerprint(
                fingerprint,
                for: peerID,
                in: &fingerprintCache,
                order: &fingerprintCacheOrder,
                cap: TransportConfig.uiFingerprintCacheCap
            )
            return fingerprint
        }
        
        // Try to get from peer's public key
        if let peer = getPeer(by: peerID) {
            if let fingerprint = Self.fingerprintFromPeer(peer) {
                Self.cacheFingerprint(
                    fingerprint,
                    for: peerID,
                    in: &fingerprintCache,
                    order: &fingerprintCacheOrder,
                    cap: TransportConfig.uiFingerprintCacheCap
                )
                return fingerprint
            }
        }
        
        return nil
    }
    
    // MARK: - Compatibility Methods (for easy migration)
    
    var allPeers: [BitchatPeer] { peers }
    var connectedPeers: [String] { Array(connectedPeerIDs) }
    var favoritePeers: Set<String> { 
        Set(favorites.compactMap { getFingerprint(for: $0.peerID.id) })
    }
    var blockedUsers: Set<String> {
        Set(peers.compactMap { peer in
            isBlocked(peer.peerID.id) ? getFingerprint(for: peer.peerID.id) : nil
        })
    }
}
