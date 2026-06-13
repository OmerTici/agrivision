import XCTest
@testable import CarniVision

/// Mutable clock so debounce windows can be advanced deterministically.
final class TestClock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 0)) { self.now = start }
}

@MainActor
final class ServerStatusTests: XCTestCase {
    private func makeService(clock: TestClock = TestClock()) -> CloudRunRecognitionService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return CloudRunRecognitionService(
            baseURL: URL(string: "https://embedder.example.com")!,
            session: session,
            tokenProvider: { "jwt-token" },
            now: { clock.now }
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequestBody = nil
        super.tearDown()
    }

    func testStatusDefaultsToUnknownAndIsReadyDerives() {
        let service = makeService()
        XCTAssertEqual(service.status, .unknown)
        XCTAssertFalse(service.isReady)

        service.status = .online
        XCTAssertTrue(service.isReady)

        service.status = .offline
        XCTAssertFalse(service.isReady)
    }
}
