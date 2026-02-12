import Foundation

protocol WiFiDirectTransportDelegate: AnyObject {
    func wifiTransportDidUpdatePeers(_ peers: [String])
    func wifiTransportDidReceive(_ data: Data, from peerID: String)
    func wifiTransportDidChangeAvailability(_ isAvailable: Bool)
}

enum WiFiDirectTransportError: Error {
    case notAvailable
    case peerNotFound
    case sendFailed
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

    private let impl: WiFiDirectTransportBackend

    override init() {
        impl = WiFiDirectTransportBackendImpl()
        super.init()
        impl.owner = self
    }

    func startDiscovery() {
        impl.startDiscovery()
    }

    func stopDiscovery() {
        impl.stopDiscovery()
    }

    func send(_ data: Data, to peerID: String? = nil) throws {
        try impl.send(data, to: peerID)
    }

    fileprivate func didReceive(_ data: Data, from peerID: String) {
        delegate?.wifiTransportDidReceive(data, from: peerID)
    }

    fileprivate func didUpdatePeers(_ peers: [String]) {
        currentPeers = peers
    }

    fileprivate func didChangeAvailability(_ available: Bool) {
        delegate?.wifiTransportDidChangeAvailability(available)
    }
}

private protocol WiFiDirectTransportBackend: AnyObject {
    var owner: WiFiDirectTransport? { get set }
    var isAvailable: Bool { get }
    func startDiscovery()
    func stopDiscovery()
    func send(_ data: Data, to peerID: String?) throws
}

#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

private final class MPCWiFiDirectTransportImplementation: NSObject, WiFiDirectTransportBackend {
    weak var owner: WiFiDirectTransport?

    private let serviceType = "bitchat-wifi"
    private let localPeerID: MCPeerID
    private let session: MCSession
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: localPeerID,
        discoveryInfo: nil,
        serviceType: serviceType
    )
    private lazy var browser = MCNearbyServiceBrowser(
        peer: localPeerID,
        serviceType: serviceType
    )

    override init() {
        let fallbackName = ProcessInfo.processInfo.hostName
        localPeerID = MCPeerID(displayName: String(fallbackName.prefix(63)))
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
}

extension MPCWiFiDirectTransportImplementation: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
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
        invitationHandler(true, session)
    }
}

extension MPCWiFiDirectTransportImplementation: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peers = session.connectedPeers.map(\.displayName).sorted()
        owner?.didUpdatePeers(peers)
    }
}

private typealias WiFiDirectTransportBackendImpl = MPCWiFiDirectTransportImplementation
#else
private final class NoopWiFiDirectTransportImplementation: WiFiDirectTransportBackend {
    weak var owner: WiFiDirectTransport?

    var isAvailable: Bool { false }

    func startDiscovery() {
        owner?.didChangeAvailability(false)
    }

    func stopDiscovery() {}

    func send(_ data: Data, to peerID: String?) throws {
        throw WiFiDirectTransportError.notAvailable
    }
}

private typealias WiFiDirectTransportBackendImpl = NoopWiFiDirectTransportImplementation
#endif
