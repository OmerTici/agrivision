import XCTest
@testable import AgriVision

/// Intercepts URLSession requests so we can assert on them and return fixtures.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol strips httpBody for stream bodies; capture via bodyStream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            MockURLProtocol.lastRequestBody = data
        } else {
            MockURLProtocol.lastRequestBody = request.httpBody
        }

        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "no-handler", code: 0))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class RecognitionDecodingTests: XCTestCase {
    private func makeService(token: String? = "jwt-token") -> CloudRunRecognitionService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return CloudRunRecognitionService(
            baseURL: URL(string: "https://embedder.example.com")!,
            session: session,
            tokenProvider: { token }  // async closure
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.lastRequestBody = nil
        super.tearDown()
    }

    func testIdentifyDecodesResponseAndSendsBearerAndImageField() async throws {
        let json = """
        {"decision":"identified","animal_id":"a1","name":"Daisy",
         "score":0.91,"margin":0.2,
         "candidates":[{"animal_id":"a1","name":"Daisy","sim":0.91}]}
        """.data(using: .utf8)!
        var capturedAuth: String?
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            capturedURL = request.url
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }

        let service = makeService()
        let result = try await service.identify(jpegData: Data([0xFF, 0xD8, 0xFF]))

        XCTAssertEqual(result.decision, "identified")
        XCTAssertEqual(result.animalId, "a1")
        XCTAssertEqual(result.name, "Daisy")
        XCTAssertEqual(result.score, 0.91, accuracy: 0.0001)
        let firstSim = try XCTUnwrap(result.candidates.first).sim
        XCTAssertEqual(firstSim, 0.91, accuracy: 0.0001)
        XCTAssertEqual(capturedAuth, "Bearer jwt-token")
        XCTAssertEqual(capturedURL?.absoluteString, "https://embedder.example.com/identify")

        let body = String(data: MockURLProtocol.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(body.contains("name=\"image\"; filename="))
    }

    func testEnrollDecodesResponseAndSendsAllFields() async throws {
        let json = """
        {"enrolled_count":5,"full_images_stored":1}
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, json)
        }

        let service = makeService()
        let muzzles = (0..<5).map { _ in Data([0xFF, 0xD8, 0xFF]) }
        let result = try await service.enroll(animalID: "abc-123",
                                              muzzleJpegs: muzzles,
                                              fullJpegs: [Data([0xFF, 0xD8, 0xFF])])

        XCTAssertEqual(result.enrolledCount, 5)
        XCTAssertEqual(result.fullImagesStored, 1)

        let body = String(data: MockURLProtocol.lastRequestBody ?? Data(), encoding: .isoLatin1) ?? ""
        XCTAssertTrue(body.contains("name=\"animal_id\"\r\n\r\nabc-123"))
        XCTAssertEqual(body.components(separatedBy: "name=\"images\"").count - 1, 5)
        XCTAssertEqual(body.components(separatedBy: "name=\"full_images\"").count - 1, 1)
    }

    func testHTTPErrorThrowsHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 502,
                                       httpVersion: nil, headerFields: nil)!
            return (resp, Data("bad gateway".utf8))
        }
        let service = makeService()
        do {
            _ = try await service.identify(jpegData: Data([0xFF, 0xD8, 0xFF]))
            XCTFail("expected throw")
        } catch let RecognitionError.http(status, _) {
            XCTAssertEqual(status, 502)
        } catch {
            XCTFail("expected RecognitionError.http, got \(error)")
        }
    }

    func testMissingTokenThrowsNotAuthenticated() async {
        let service = makeService(token: nil)
        do {
            _ = try await service.identify(jpegData: Data([0xFF, 0xD8, 0xFF]))
            XCTFail("expected throw")
        } catch RecognitionError.notAuthenticated {
            // ok
        } catch {
            XCTFail("expected notAuthenticated, got \(error)")
        }
    }
}
