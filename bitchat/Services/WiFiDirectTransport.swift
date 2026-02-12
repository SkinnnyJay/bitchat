import Foundation

protocol WiFiDirectTransportDelegate: AnyObject {
    func wifiTransportDidUpdatePeers(_ peers: [String])
    func wifiTransportDidReceive(_ data: Data, from peerID: String)
    func wifiTransportDidChangeAvailability(_ isAvailable: Bool)
}

enum WiFiDirectTransportError: Error, Equatable {
    case notAvailable
    case peerNotFound
    case sendFailed
    case invalidPayload
}

/// Wi‑Fi Direct style transport backed by MultipeerConnectivity where available.
///
/// This transport is intentionally scoped as a self-contained service so it can
/// be integrated incrementally into the broader transport routing stack.
final class WiFiDirectTransport: NSObject {
    weak var delegate: WiFiDirectTransportDelegate?

    private(set) var currentPeers: [String] = [] {
        didSet {
            guard oldValue != currentPeers else { return }
            delegate?.wifiTransportDidUpdatePeers(currentPeers)
        }
    }

    var isAvailable: Bool {
        impl.isAvailable
    }

    private(set) var isDiscovering = false
    private let impl: WiFiDirectTransportBackend
    private let maxTrackedPeers: Int
    private let maxPeerIDBytes: Int
    private let maxInboundPayloadBytes: Int
    private var lastPublishedAvailability: Bool?

    init(localPeerID: String? = nil, backend: WiFiDirectTransportBackend? = nil) {
        impl = backend ?? WiFiDirectTransportBackendImpl(localPeerID: localPeerID)
        maxTrackedPeers = max(1, TransportConfig.wifiDirectMaxTrackedPeers)
        maxPeerIDBytes = max(1, TransportConfig.wifiDirectPeerIDMaxBytes)
        maxInboundPayloadBytes = TransportConfig.messageRouterInboundWiFiPayloadMaxBytes
        super.init()
        impl.owner = self
    }

    override convenience init() {
        self.init(localPeerID: nil, backend: nil)
    }

    func startDiscovery() {
        guard !isDiscovering else { return }
        guard impl.isAvailable else {
            didChangeAvailability(false)
            return
        }
        isDiscovering = true
        impl.startDiscovery()
    }

    func stopDiscovery() {
        guard isDiscovering else { return }
        isDiscovering = false
        impl.stopDiscovery()
        didChangeAvailability(false)
    }

    func send(_ data: Data, to peerID: String? = nil) throws {
        guard !data.isEmpty, data.count <= TransportConfig.messageRouterInboundWiFiPayloadMaxBytes else {
            throw WiFiDirectTransportError.invalidPayload
        }
        let normalizedPeerID: String?
        if let peerID {
            let trimmed = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw WiFiDirectTransportError.peerNotFound
            }
            guard trimmed.utf8.count <= maxPeerIDBytes else {
                throw WiFiDirectTransportError.peerNotFound
            }
            normalizedPeerID = trimmed
        } else {
            normalizedPeerID = nil
        }
        try impl.send(data, to: normalizedPeerID)
    }

    func peerCapabilities(peerID: String) -> Set<String>? {
        guard isDiscovering else { return nil }
        let normalizedPeerID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPeerID.isEmpty else { return nil }
        guard normalizedPeerID.utf8.count <= maxPeerIDBytes else { return nil }
        return impl.capabilities(for: normalizedPeerID)
    }

    deinit {
        stopDiscovery()
    }

    func didReceive(_ data: Data, from peerID: String) {
        dispatchOnMain { [weak self] in
            guard let self else { return }
            guard self.isDiscovering else { return }
            guard !data.isEmpty else { return }
            guard data.count <= self.maxInboundPayloadBytes else { return }
            let normalizedPeerID = peerID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPeerID.isEmpty else { return }
            guard normalizedPeerID.utf8.count <= self.maxPeerIDBytes else { return }
            self.delegate?.wifiTransportDidReceive(data, from: normalizedPeerID)
        }
    }

    func didUpdatePeers(_ peers: [String]) {
        dispatchOnMain { [weak self] in
            guard let self else { return }
            let normalized = peers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.utf8.count <= self.maxPeerIDBytes }
            let uniqueSorted = Array(Set(normalized)).sorted()
            let capped = Array(uniqueSorted.prefix(self.maxTrackedPeers))
            if !self.isDiscovering && !uniqueSorted.isEmpty {
                return
            }
            self.currentPeers = capped
        }
    }

    func didChangeAvailability(_ available: Bool) {
        dispatchOnMain { [weak self] in
            guard let self else { return }
            if available && !self.isDiscovering {
                return
            }
            if self.lastPublishedAvailability == available {
                return
            }
            if !available {
                self.impl.resetState()
                self.currentPeers = []
                self.isDiscovering = false
            }
            self.lastPublishedAvailability = available
            self.delegate?.wifiTransportDidChangeAvailability(available)
        }
    }

    private func dispatchOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

protocol WiFiDirectTransportBackend: AnyObject {
    var owner: WiFiDirectTransport? { get set }
    var isAvailable: Bool { get }
    init(localPeerID: String?)
    func startDiscovery()
    func stopDiscovery()
    func resetState()
    func send(_ data: Data, to peerID: String?) throws
    func capabilities(for peerID: String) -> Set<String>?
}

#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

private final class MPCWiFiDirectTransportImplementation: NSObject, WiFiDirectTransportBackend {
    weak var owner: WiFiDirectTransport?

    private let serviceType = "bitchat-wifi"
    private let localPeerID: MCPeerID
    private let session: MCSession
    private let capabilityNegotiator = WiFiDirectCapabilityNegotiator()
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: localPeerID,
        discoveryInfo: capabilityNegotiator.discoveryInfo(),
        serviceType: serviceType
    )
    private lazy var browser = MCNearbyServiceBrowser(
        peer: localPeerID,
        serviceType: serviceType
    )
    private var inviteBackoffByPeerID: [String: TimeInterval] = [:]
    private var nextInviteAllowedAt: [String: Date] = [:]
    private var capabilitiesByPeerID: [String: Set<String>] = [:]
    private let initialInviteBackoffSeconds: TimeInterval = TransportConfig.wifiDirectInviteInitialBackoffSeconds
    private let maxInviteBackoffSeconds: TimeInterval = TransportConfig.wifiDirectInviteMaxBackoffSeconds

    required init(localPeerID: String?) {
        let displayName = Self.sanitizeDisplayName(localPeerID)
        self.localPeerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    var isAvailable: Bool { true }

    func startDiscovery() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        owner?.didChangeAvailability(true)
    }

    func stopDiscovery() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
    }

    func resetState() {
        inviteBackoffByPeerID.removeAll()
        nextInviteAllowedAt.removeAll()
        capabilitiesByPeerID.removeAll()
    }

    func send(_ data: Data, to peerID: String?) throws {
        guard !session.connectedPeers.isEmpty else {
            throw WiFiDirectTransportError.notAvailable
        }

        let targets: [MCPeerID]
        if let peerID {
            guard let target = session.connectedPeers.first(where: { $0.displayName == peerID }) else {
                throw WiFiDirectTransportError.peerNotFound
            }
            targets = [target]
        } else {
            targets = session.connectedPeers
        }

        do {
            try session.send(data, toPeers: targets, with: .reliable)
        } catch {
            throw WiFiDirectTransportError.sendFailed
        }
    }

    func capabilities(for peerID: String) -> Set<String>? {
        capabilitiesByPeerID[peerID]
    }

    private static func sanitizeDisplayName(_ candidate: String?) -> String {
        let base = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ProcessInfo.processInfo.hostName
        let source = (base?.isEmpty == false) ? base! : fallback
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let filteredScalars = source.unicodeScalars.filter { allowed.contains($0) }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        if filtered.isEmpty {
            return "bitchat-peer"
        }
        return String(filtered.prefix(63))
    }
}

extension MPCWiFiDirectTransportImplementation: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peerKey = peerID.displayName
        if state == .connected {
            inviteBackoffByPeerID.removeValue(forKey: peerKey)
            nextInviteAllowedAt.removeValue(forKey: peerKey)
        } else if state == .notConnected {
            capabilitiesByPeerID.removeValue(forKey: peerKey)
        }
        let peers = session.connectedPeers.map(\.displayName).sorted()
        owner?.didUpdatePeers(peers)
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        owner?.didReceive(data, from: peerID.displayName)
    }

    func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {}

    func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}

extension MPCWiFiDirectTransportImplementation: MCNearbyServiceAdvertiserDelegate {
    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let discoveryInfoFromContext = capabilityNegotiator.parseDiscoveryInfo(from: context)
        guard capabilityNegotiator.isPeerCompatible(discoveryInfo: discoveryInfoFromContext) else {
            invitationHandler(false, nil)
            return
        }
        if let caps = discoveryInfoFromContext?["caps"] {
            capabilitiesByPeerID[peerID.displayName] = WiFiDirectCapabilityNegotiator.parseCapabilities(caps)
        } else {
            capabilitiesByPeerID.removeValue(forKey: peerID.displayName)
        }
        invitationHandler(true, session)
    }
}

extension MPCWiFiDirectTransportImplementation: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard capabilityNegotiator.isPeerCompatible(discoveryInfo: info) else {
            return
        }
        if let caps = info?["caps"] {
            capabilitiesByPeerID[peerID.displayName] = WiFiDirectCapabilityNegotiator.parseCapabilities(caps)
        } else {
            capabilitiesByPeerID.removeValue(forKey: peerID.displayName)
        }

        let peerKey = peerID.displayName
        let now = Date()
        if let nextAllowed = nextInviteAllowedAt[peerKey], now < nextAllowed {
            return
        }

        browser.invitePeer(peerID, to: session, withContext: capabilityNegotiator.invitationContextData(), timeout: 10)

        let currentBackoff = inviteBackoffByPeerID[peerKey] ?? initialInviteBackoffSeconds
        let nextBackoff = min(currentBackoff * 2, maxInviteBackoffSeconds)
        inviteBackoffByPeerID[peerKey] = nextBackoff
        nextInviteAllowedAt[peerKey] = now.addingTimeInterval(currentBackoff)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        nextInviteAllowedAt.removeValue(forKey: peerID.displayName)
        inviteBackoffByPeerID.removeValue(forKey: peerID.displayName)
        capabilitiesByPeerID.removeValue(forKey: peerID.displayName)
        let peers = session.connectedPeers.map(\.displayName).sorted()
        owner?.didUpdatePeers(peers)
    }
}

private typealias WiFiDirectTransportBackendImpl = MPCWiFiDirectTransportImplementation
#else
private final class NoopWiFiDirectTransportImplementation: WiFiDirectTransportBackend {
    weak var owner: WiFiDirectTransport?

    var isAvailable: Bool { false }

    required init(localPeerID: String?) {}

    func startDiscovery() {
        owner?.didChangeAvailability(false)
    }

    func stopDiscovery() {}

    func resetState() {}

    func send(_ data: Data, to peerID: String?) throws {
        throw WiFiDirectTransportError.notAvailable
    }

    func capabilities(for peerID: String) -> Set<String>? {
        nil
    }
}

private typealias WiFiDirectTransportBackendImpl = NoopWiFiDirectTransportImplementation
#endif
