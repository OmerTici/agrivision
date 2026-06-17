import XCTest
@testable import AgriVision

final class MultipartFormDataTests: XCTestCase {
    func testContentTypeHeaderCarriesBoundary() {
        let form = MultipartFormData(boundary: "BOUND123")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=BOUND123")
    }

    func testTextFieldEncoding() {
        var form = MultipartFormData(boundary: "BOUND123")
        form.appendField(name: "animal_id", value: "abc-123")
        let body = String(data: form.finalizedBody(), encoding: .utf8)!

        XCTAssertTrue(body.contains("--BOUND123\r\n"))
        XCTAssertTrue(body.contains("Content-Disposition: form-data; name=\"animal_id\"\r\n\r\nabc-123\r\n"))
        XCTAssertTrue(body.hasSuffix("--BOUND123--\r\n"))
    }

    func testFilePartEncodingIncludesFilenameAndContentType() {
        var form = MultipartFormData(boundary: "BOUND123")
        let bytes = Data([0xFF, 0xD8, 0xFF])
        form.appendFile(name: "image", filename: "muzzle.jpg", mimeType: "image/jpeg", data: bytes)
        let body = form.finalizedBody()
        let text = String(data: body, encoding: .isoLatin1)!

        XCTAssertTrue(text.contains(
            "Content-Disposition: form-data; name=\"image\"; filename=\"muzzle.jpg\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg\r\n\r\n"))
        // raw JPEG magic bytes survive
        XCTAssertTrue(body.range(of: Data([0xFF, 0xD8, 0xFF])) != nil)
    }

    func testRepeatedFilePartsShareFieldName() {
        var form = MultipartFormData(boundary: "B")
        form.appendFile(name: "images", filename: "a.jpg", mimeType: "image/jpeg", data: Data([0x01]))
        form.appendFile(name: "images", filename: "b.jpg", mimeType: "image/jpeg", data: Data([0x02]))
        let text = String(data: form.finalizedBody(), encoding: .isoLatin1)!
        let occurrences = text.components(separatedBy: "name=\"images\"").count - 1
        XCTAssertEqual(occurrences, 2)
    }

    func testRandomBoundaryInitProducesNonEmptyBoundary() {
        let form = MultipartFormData()
        XCTAssertFalse(form.boundary.isEmpty)
    }
}
