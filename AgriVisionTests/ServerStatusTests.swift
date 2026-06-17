import XCTest
@testable import AgriVision

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

    // MARK: - warmUp state tests

    private func healthResponse(modelLoaded: Bool, status: Int = 200) {
        MockURLProtocol.requestHandler = { request in
            let json = "{\"status\":\"ok\",\"model_loaded\":\(modelLoaded)}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }
    }

    func testWarmUpSuccessSetsOnline() async {
        let service = makeService()
        healthResponse(modelLoaded: true)
        await service.warmUp()
        XCTAssertEqual(service.status, .online)
        XCTAssertTrue(service.isReady)
    }

    func testWarmUpModelNotLoadedSetsOffline() async {
        let service = makeService()
        healthResponse(modelLoaded: false)
        await service.warmUp()
        XCTAssertEqual(service.status, .offline)
    }

    func testWarmUpHTTPErrorSetsOffline() async {
        let service = makeService()
        healthResponse(modelLoaded: true, status: 503)
        await service.warmUp()
        XCTAssertEqual(service.status, .offline)
    }

    func testWarmUpTransportErrorSetsOffline() async {
        let service = makeService()
        MockURLProtocol.requestHandler = { _ in throw NSError(domain: "net", code: -1009) }
        await service.warmUp()
        XCTAssertEqual(service.status, .offline)
    }

    func testDebounceSkipsWithinWindow() async {
        let clock = TestClock()
        let service = makeService(clock: clock)

        healthResponse(modelLoaded: true)          // first call -> online
        await service.warmUp()
        XCTAssertEqual(service.status, .online)

        // Within 120s, a second call must NOT touch the network: prove it by
        // arming a handler that would flip to offline; status must stay online.
        clock.now = Date(timeIntervalSince1970: 60)
        healthResponse(modelLoaded: false)         // would set offline IF called
        await service.warmUp()
        XCTAssertEqual(service.status, .online, "debounced call must not re-ping")
    }

    func testDebounceReChecksAfterWindow() async {
        let clock = TestClock()
        let service = makeService(clock: clock)

        healthResponse(modelLoaded: true)
        await service.warmUp()
        XCTAssertEqual(service.status, .online)

        clock.now = Date(timeIntervalSince1970: 121)  // past the 120s window
        healthResponse(modelLoaded: false)
        await service.warmUp()
        XCTAssertEqual(service.status, .offline, "after the window it must re-ping")
    }

    func testDebounceAlwaysChecksWhenNotOnline() async {
        let service = makeService()
        healthResponse(modelLoaded: true, status: 503)  // -> offline
        await service.warmUp()
        XCTAssertEqual(service.status, .offline)

        healthResponse(modelLoaded: true)               // not online -> must re-ping
        await service.warmUp()
        XCTAssertEqual(service.status, .online)
    }
}
