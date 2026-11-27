import XCTest
@testable import GalaxyBluetooth

@MainActor
final class AddressTests: XCTestCase {
    func testPrivateAddressesBecomeEndpoints() throws {
        XCTAssertEqual(try LANTransport.endpoint("192.168.10.85").absoluteString, "http://192.168.10.85:8082")
        XCTAssertEqual(try LANTransport.endpoint(" http://10.0.0.2:8082/ ").absoluteString, "http://10.0.0.2:8082")
        XCTAssertEqual(try LANTransport.endpoint("172.31.254.1").host, "172.31.254.1")
    }

    func testPublicLoopbackAndMalformedAddressesAreRejected() {
        for address in ["8.8.8.8", "127.0.0.1", "172.32.0.1", "192.168.1", "192.168.01.2", "192.168.1.256", "comma.local", ""] {
            XCTAssertThrowsError(try LANTransport.endpoint(address), address)
        }
    }

    func testLocalQRCodeAcceptsOnlyTheGalaxyScreen() {
        XCTAssertEqual(LANTransport.localQRAddress("http://192.168.1.20:8082/#/"), "192.168.1.20")
        XCTAssertNil(LANTransport.localQRAddress("https://192.168.1.20:8082/"))
        XCTAssertNil(LANTransport.localQRAddress("http://192.168.1.20:8082/settings"))
        XCTAssertNil(LANTransport.localQRAddress("http://user@192.168.1.20:8082/"))
        XCTAssertNil(LANTransport.localQRAddress("http://8.8.8.8:8082/"))
    }
}

@MainActor
final class ReportPathTests: XCTestCase {
    func testPrivatePathsAreSummarized() {
        XCTAssertEqual(LoopbackServer.reportPath("/api/device/state?token=x"), "/api/device/state")
        XCTAssertEqual(LoopbackServer.reportPath("/api/recordings/media/abc"), "/api/recordings/…")
        XCTAssertEqual(LoopbackServer.reportPath("/js/app.js"), "/js/app.js")
        XCTAssertEqual(LoopbackServer.reportPath("/secret/place"), "[other path]")
    }
}

@MainActor
final class GalaxyPatchTests: XCTestCase {
    func testReadDeadlinesApplyOnlyToKnownFiles() {
        let feed = "export class SnapshotFeed {\n  poll() {\n    setTimeout(() => {\n    }, 4000)\n  }\n}"
        let adapted = LoopbackServer.nativeReadDeadlines(feed, asset: "js/snapshot-feed.js")
        XCTAssertNotEqual(adapted, feed)
        XCTAssertTrue(adapted.contains("20000"))
        XCTAssertEqual(LoopbackServer.nativeReadDeadlines(feed, asset: "js/other.js"), feed)
        XCTAssertEqual(LoopbackServer.nativeReadDeadlines("unrelated", asset: "js/snapshot-feed.js"), "unrelated")
    }
}

final class PairingCredentialTests: XCTestCase {
    func testLegacyHexKeyDecodes() {
        let key = String(repeating: "AB", count: 32)
        let credential = PairingCredential.decode(Data(key.utf8))
        XCTAssertEqual(credential?.key, key.lowercased())
        XCTAssertNil(credential?.id)
    }

    func testInvalidKeysAreRejected() {
        XCTAssertNil(PairingCredential.decode(Data("short".utf8)))
        XCTAssertNil(PairingCredential.decode(Data(String(repeating: "g", count: 64).utf8)))
    }

    func testStoredCredentialRoundTrips() throws {
        let stored = PairingCredential(key: String(repeating: "a", count: 64), id: nil, previousId: nil)
        XCTAssertEqual(PairingCredential.decode(try JSONEncoder().encode(stored)), stored)
    }
}

final class SharedDestinationTests: XCTestCase {
    func testCoordinatesFromCommonMapLinks() {
        for text in ["https://maps.google.com/?q=12.3,-45.6", "geo:12.3,-45.6(Home)", "https://maps.apple.com/?ll=12.3,-45.6&q=Cafe"] {
            guard case let .place(_, latitude, longitude) = SharedDestination.parse(text) else { return XCTFail(text) }
            XCTAssertEqual(latitude, 12.3)
            XCTAssertEqual(longitude, -45.6)
        }
    }

    func testAddressesBecomeSearches() {
        XCTAssertEqual(SharedDestination.parse("geo:0,0?q=10+Main+Street"), .search("10 Main Street"))
    }
}

@MainActor
final class ConnectionEventLogTests: XCTestCase {
    func testSecretsAreRedacted() {
        let log = ConnectionEventLog()
        let key = String(repeating: "a", count: 64)
        log.record("failed https://galaxy.example/private " + key + " Bearer token-value")
        let event = log.events.last ?? ""
        XCTAssertFalse(event.contains(key))
        XCTAssertFalse(event.contains("token-value"))
        XCTAssertFalse(event.contains("galaxy.example"))
    }

    func testFailuresSurviveHeavyPolling() {
        let log = ConnectionEventLog()
        log.record("request failed HTTP 403")
        for index in 0..<13000 { log.record("poll \(index)") }
        XCTAssertFalse(log.events.contains { $0.contains("HTTP 403") })
        XCTAssertEqual(log.failureEvents.count, 1)
    }
}
