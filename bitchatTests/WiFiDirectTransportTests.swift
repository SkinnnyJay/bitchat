import XCTest
@testable import bitchat

final class WiFiDirectTransportTests: XCTestCase {
    func testAvailabilityAndStartStopAreSafe() {
        let transport = WiFiDirectTransport()
        transport.startDiscovery()
        transport.stopDiscovery()

        #if canImport(MultipeerConnectivity)
        XCTAssertTrue(transport.isAvailable)
        #else
        XCTAssertFalse(transport.isAvailable)
        #endif
    }

    func testSendWithoutPeersThrows() {
        let transport = WiFiDirectTransport()
        XCTAssertThrowsError(try transport.send(Data("hello".utf8)))
    }
}
