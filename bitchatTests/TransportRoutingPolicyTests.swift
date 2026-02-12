import XCTest
@testable import bitchat

final class TransportRoutingPolicyTests: XCTestCase {
    func testReturnsNilWhenNoTransportIsAvailable() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 1024)
        let decision = policy.routePrivateMessage(
            .init(payloadBytes: 100, meshReachable: false, nostrAvailable: false)
        )
        XCTAssertNil(decision)
    }

    func testPrefersMeshWhenOnlyMeshIsAvailable() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 1024)
        let decision = policy.routePrivateMessage(
            .init(payloadBytes: 200, meshReachable: true, nostrAvailable: false)
        )
        XCTAssertEqual(decision, .mesh)
    }

    func testPrefersNostrWhenOnlyNostrIsAvailable() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 1024)
        let decision = policy.routePrivateMessage(
            .init(payloadBytes: 10, meshReachable: false, nostrAvailable: true)
        )
        XCTAssertEqual(decision, .nostr)
    }

    func testPrefersMeshForSmallPayloadWhenBothAreAvailable() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 1024)
        let decision = policy.routePrivateMessage(
            .init(payloadBytes: 200, meshReachable: true, nostrAvailable: true)
        )
        XCTAssertEqual(decision, .mesh)
    }

    func testPrefersNostrForLargePayloadWhenBothAreAvailable() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 100)
        let decision = policy.routePrivateMessage(
            .init(payloadBytes: 200, meshReachable: true, nostrAvailable: true)
        )
        XCTAssertEqual(decision, .nostr)
    }

    func testReturnsNilWhenPayloadExceedsPrivatePacketLimitEvenIfBothAvailable() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 100)
        let decision = policy.routePrivateMessage(
            .init(
                payloadBytes: TransportConfig.privateMessagePacketContentMaxBytes + 1,
                meshReachable: true,
                nostrAvailable: true
            )
        )
        XCTAssertNil(decision)
    }

    func testReturnsNilWhenOnlyNostrAvailableAndPayloadExceedsNostrLimit() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 100)
        let decision = policy.routePrivateMessage(
            .init(
                payloadBytes: TransportConfig.nostrEmbeddedPayloadMaxBytes + 1,
                meshReachable: false,
                nostrAvailable: true
            )
        )
        XCTAssertNil(decision)
    }

    func testReturnsNilWhenOnlyMeshAvailableAndPayloadExceedsMeshLimit() {
        let policy = TransportRoutingPolicy(nostrPreferredPayloadBytes: 100)
        let decision = policy.routePrivateMessage(
            .init(
                payloadBytes: TransportConfig.privateMessagePacketContentMaxBytes + 1,
                meshReachable: true,
                nostrAvailable: false
            )
        )
        XCTAssertNil(decision)
    }
}
