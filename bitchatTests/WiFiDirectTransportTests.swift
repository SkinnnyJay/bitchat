import XCTest
@testable import bitchat

final class WiFiDirectTransportTests: XCTestCase {
    private final class MockDelegate: WiFiDirectTransportDelegate {
        var peerUpdates: [[String]] = []
        var receives: [(data: Data, from: String)] = []
        var availability: [Bool] = []

        func wifiTransportDidUpdatePeers(_ peers: [String]) {
            peerUpdates.append(peers)
        }

        func wifiTransportDidReceive(_ data: Data, from peerID: String) {
            receives.append((data, peerID))
        }

        func wifiTransportDidChangeAvailability(_ isAvailable: Bool) {
            availability.append(isAvailable)
        }
    }

    private final class MockBackend: WiFiDirectTransportBackend {
        weak var owner: WiFiDirectTransport?
        var isAvailable: Bool
        var startDiscoveryCount = 0
        var stopDiscoveryCount = 0
        var resetStateCount = 0
        var sentPayloads: [(data: Data, peerID: String?)] = []
        var sendError: Error?
        var capabilitiesByPeerID: [String: Set<String>] = [:]

        required init(localPeerID: String?) {
            isAvailable = true
        }

        func startDiscovery() {
            startDiscoveryCount += 1
            owner?.didChangeAvailability(isAvailable)
        }

        func stopDiscovery() {
            stopDiscoveryCount += 1
        }

        func resetState() {
            resetStateCount += 1
        }

        func send(_ data: Data, to peerID: String?) throws {
            if let sendError {
                throw sendError
            }
            sentPayloads.append((data, peerID))
        }

        func capabilities(for peerID: String) -> Set<String>? {
            capabilitiesByPeerID[peerID]
        }

        func simulatePeerUpdate(_ peers: [String]) {
            owner?.didUpdatePeers(peers)
        }

        func simulateReceive(_ data: Data, from peerID: String) {
            owner?.didReceive(data, from: peerID)
        }

        func simulateAvailability(_ available: Bool) {
            isAvailable = available
            owner?.didChangeAvailability(available)
        }
    }

    private enum SampleError: Error {
        case failedSend
    }

    func testStartStopDiscoveryAreIdempotent() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)

        transport.startDiscovery()
        transport.startDiscovery()
        XCTAssertTrue(transport.isDiscovering)
        XCTAssertEqual(backend.startDiscoveryCount, 1)

        transport.stopDiscovery()
        transport.stopDiscovery()
        XCTAssertFalse(transport.isDiscovering)
        XCTAssertEqual(backend.stopDiscoveryCount, 1)
        XCTAssertEqual(backend.resetStateCount, 1)
    }

    func testStartDiscoveryWhenUnavailableDoesNotEnterDiscoveringState() {
        let backend = MockBackend(localPeerID: "self")
        backend.isAvailable = false
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        transport.startDiscovery()

        let expect = expectation(description: "unavailable discovery publishes false availability")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertFalse(transport.isDiscovering)
        XCTAssertEqual(backend.startDiscoveryCount, 0)
        XCTAssertEqual(delegate.availability, [false])
    }

    func testStartDiscoveryRecoversWhenBackendBecomesAvailable() {
        let backend = MockBackend(localPeerID: "self")
        backend.isAvailable = false
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        transport.startDiscovery()
        XCTAssertFalse(transport.isDiscovering)
        XCTAssertEqual(backend.startDiscoveryCount, 0)

        backend.isAvailable = true
        transport.startDiscovery()

        let expect = expectation(description: "availability updates after backend recovers")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertTrue(transport.isDiscovering)
        XCTAssertEqual(backend.startDiscoveryCount, 1)
        XCTAssertEqual(delegate.availability, [false, true])
    }

    func testSendIsForwardedToBackend() throws {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let payload = Data("hello".utf8)

        try transport.send(payload, to: "peer-a")

        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertEqual(backend.sentPayloads[0].data, payload)
        XCTAssertEqual(backend.sentPayloads[0].peerID, "peer-a")
    }

    func testSendPropagatesBackendError() {
        let backend = MockBackend(localPeerID: "self")
        backend.sendError = SampleError.failedSend
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)

        XCTAssertThrowsError(try transport.send(Data("hello".utf8), to: "peer-a"))
    }

    func testSendRejectsWhitespacePeerIDBeforeBackendSend() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)

        XCTAssertThrowsError(try transport.send(Data("hello".utf8), to: "   ")) { error in
            XCTAssertEqual(error as? WiFiDirectTransportError, .peerNotFound)
        }
        XCTAssertTrue(backend.sentPayloads.isEmpty)
    }

    func testSendTrimsPeerIDBeforeBackendSend() throws {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)

        try transport.send(Data("hello".utf8), to: "  peer-a  ")

        XCTAssertEqual(backend.sentPayloads.count, 1)
        XCTAssertEqual(backend.sentPayloads[0].peerID, "peer-a")
    }

    func testDelegateReceivesPeerAndMessageEvents() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        let expect = expectation(description: "delegate receives availability, peers, and message")
        transport.startDiscovery()
        backend.simulatePeerUpdate(["peer-a", "peer-b"])
        backend.simulateReceive(Data("ping".utf8), from: "peer-a")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.availability, [true])
        XCTAssertEqual(delegate.peerUpdates, [["peer-a", "peer-b"]])
        XCTAssertEqual(delegate.receives.count, 1)
        XCTAssertEqual(delegate.receives[0].from, "peer-a")
    }

    func testPeerUpdatesAreTrimmedDeduplicatedAndSorted() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        let expect = expectation(description: "normalized peer updates delivered")
        backend.simulatePeerUpdate([" peer-b ", "", "peer-a", "peer-a", "   "])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.peerUpdates.last, ["peer-a", "peer-b"])
    }

    func testReceivePeerIDIsTrimmedAndBlankSourceDropped() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        let expect = expectation(description: "normalized receive events delivered")
        backend.simulateReceive(Data("ping".utf8), from: "  peer-a  ")
        backend.simulateReceive(Data("ping".utf8), from: "   ")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.receives.count, 1)
        XCTAssertEqual(delegate.receives[0].from, "peer-a")
    }

    func testSendWithoutPeersThrows() {
        let transport = WiFiDirectTransport()
        XCTAssertThrowsError(try transport.send(Data("hello".utf8)))
    }

    func testPeerCapabilitiesAreReadFromBackend() {
        let backend = MockBackend(localPeerID: "self")
        backend.capabilitiesByPeerID["peer-a"] = ["pm", "ack"]
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)

        XCTAssertEqual(transport.peerCapabilities(peerID: "peer-a"), ["pm", "ack"])
        XCTAssertEqual(transport.peerCapabilities(peerID: "  peer-a  "), ["pm", "ack"])
        XCTAssertNil(transport.peerCapabilities(peerID: "   "))
        XCTAssertNil(transport.peerCapabilities(peerID: "missing"))
    }

    func testStopDiscoveryClearsBackendCapabilities() {
        let backend = MockBackend(localPeerID: "self")
        backend.capabilitiesByPeerID["peer-a"] = ["pm", "ack"]
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)

        transport.startDiscovery()
        transport.stopDiscovery()

        XCTAssertEqual(backend.resetStateCount, 1)
        XCTAssertNil(transport.peerCapabilities(peerID: "peer-a"))
    }

    func testStopDiscoveryClearsPeersAndPublishesUnavailable() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        let expect = expectation(description: "stop discovery publishes reset events")
        transport.startDiscovery()
        backend.simulatePeerUpdate(["peer-a"])
        transport.stopDiscovery()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.availability, [true, false])
        XCTAssertTrue(delegate.peerUpdates.contains(["peer-a"]))
        XCTAssertTrue(delegate.peerUpdates.contains([]))
        XCTAssertEqual(backend.resetStateCount, 1)
    }

    func testAvailabilityDropClearsPeersWithoutStopDiscovery() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        let expect = expectation(description: "availability drop clears peers")
        transport.startDiscovery()
        backend.simulatePeerUpdate(["peer-a"])
        backend.simulateAvailability(false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.availability, [true, false])
        XCTAssertTrue(delegate.peerUpdates.contains(["peer-a"]))
        XCTAssertTrue(delegate.peerUpdates.contains([]))
        XCTAssertFalse(transport.isDiscovering)
    }

    func testAvailabilityDropAllowsDiscoveryRestartAfterRecovery() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        transport.startDiscovery()
        XCTAssertTrue(transport.isDiscovering)
        XCTAssertEqual(backend.startDiscoveryCount, 1)

        let drop = expectation(description: "availability drop settles")
        backend.simulateAvailability(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            drop.fulfill()
        }
        wait(for: [drop], timeout: 1.0)
        XCTAssertFalse(transport.isDiscovering)

        backend.isAvailable = true
        transport.startDiscovery()

        let recover = expectation(description: "recovery availability settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            recover.fulfill()
        }
        wait(for: [recover], timeout: 1.0)

        XCTAssertTrue(transport.isDiscovering)
        XCTAssertEqual(backend.startDiscoveryCount, 2)
        XCTAssertEqual(delegate.availability, [true, false, true])
    }

    func testIgnoresStaleAvailabilityTrueWhenNotDiscovering() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        transport.startDiscovery()
        transport.stopDiscovery()
        XCTAssertFalse(transport.isDiscovering)
        XCTAssertEqual(delegate.availability, [true, false])

        let expect = expectation(description: "stale availability true ignored")
        backend.simulateAvailability(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(delegate.availability, [true, false])
    }

    func testIgnoresStalePeerUpdatesWhenNotDiscovering() {
        let backend = MockBackend(localPeerID: "self")
        let transport = WiFiDirectTransport(localPeerID: "self", backend: backend)
        let delegate = MockDelegate()
        transport.delegate = delegate

        transport.startDiscovery()
        transport.stopDiscovery()
        XCTAssertFalse(transport.isDiscovering)
        XCTAssertEqual(transport.currentPeers, [])

        let expect = expectation(description: "stale peer update ignored")
        backend.simulatePeerUpdate(["peer-z"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1.0)

        XCTAssertEqual(transport.currentPeers, [])
        XCTAssertFalse(delegate.peerUpdates.contains(["peer-z"]))
    }
}
