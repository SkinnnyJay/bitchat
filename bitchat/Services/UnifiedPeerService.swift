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
            
            enrichedPeers.append(peer)
            if peer.isConnected { connected.insert(peerID) }
            addedPeerIDs.insert(peerID)
            
            // Update fingerprint cache
            if let publicKey = resolvedNoisePublicKey {
                fingerprintCache[peerID.id] = publicKey.sha256Fingerprint()
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
            fingerprintCache[peerID.id] = favoriteKey.sha256Fingerprint()
        }
        
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
        var newIndex: [String: BitchatPeer] = [:]
        
        for peer in enrichedPeers {
            newIndex[peer.peerID.id] = peer
            
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
            if let fingerprint = cache[key] {
                return fingerprint
            }
        }
        let normalizedTarget = WiFiPeerIdentity.normalizedKey(peerID)
        guard !normalizedTarget.isEmpty else { return nil }
        return cache.first { key, _ in
            WiFiPeerIdentity.normalizedKey(key) == normalizedTarget
        }?.value
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

    static func shouldIncludeFavoriteAsOfflinePeer(
        favoriteNoiseKey: Data,
        favoriteNickname: String,
        existingPeers: [BitchatPeer],
        addedPeerIDs: Set<PeerID>
    ) -> Bool {
        let favoritePeerID = PeerID(hexData: favoriteNoiseKey)
        if addedPeerIDs.contains(favoritePeerID) {
            return false
        }

        if existingPeers.contains(where: { WiFiPeerIdentity.isEquivalent($0.peerID.id, favoritePeerID.id) }) {
            return false
        }

        if !favoriteNickname.isEmpty {
            let isConnectedByNickname = existingPeers.contains {
                $0.isConnected && $0.nickname == favoriteNickname
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
        if let peerIDNoiseKey = snapshot.peerID.noiseKey, peerIDNoiseKey.count == 32 {
            return peerIDNoiseKey
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

        for peer in peers {
            let display = peer.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawNick = peer.nickname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if display == normalizedTarget || rawNick == normalizedTarget {
                return peer.peerID.id
            }
        }
        return nil
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
        if let fingerprint = meshService.getFingerprint(for: PeerID(str: peerID)) {
            for key in Self.lookupKeys(for: peerID) {
                fingerprintCache[key] = fingerprint
            }
            return fingerprint
        }
        
        // Try to get from peer's public key
        if let peer = getPeer(by: peerID) {
            if let fingerprint = Self.fingerprintFromPeer(peer) {
                for key in Self.lookupKeys(for: peerID) {
                    fingerprintCache[key] = fingerprint
                }
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
