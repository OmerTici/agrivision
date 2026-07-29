import XCTest
@testable import AgriVision

final class EarTagExtractionTests: XCTestCase {
    func testExtractsCleanTag() {
        XCTAssertEqual(EarTagReaderService.extractTag(from: "TR 1234567890"), "TR1234567890")
    }

    func testExtractsTagSplitAcrossLines() {
        // Tags print the number in groups; OCR lines are joined with spaces.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "TR 12 3456 7890 12"), "TR123456789012")
        XCTAssertEqual(EarTagReaderService.extractTag(from: "TR-12-345-678-90"), "TR1234567890")
    }

    func testExtractsTagBuriedInNoise() {
        XCTAssertEqual(
            EarTagReaderService.extractTag(from: "some barn text TR 34001234567 more text"),
            "TR34001234567"
        )
    }

    func testLowercaseTROK() {
        XCTAssertEqual(EarTagReaderService.extractTag(from: "tr 12345678"), "TR12345678")
    }

    func testRejectsTooFewDigits() {
        // "TR 0412" style short forms exist on paper, but OCR locking on a
        // partial read of a longer tag is worse than waiting for a full read.
        XCTAssertNil(EarTagReaderService.extractTag(from: "TR 0412"))
    }

    func testRejectsPlainNumbersWithoutTR() {
        XCTAssertNil(EarTagReaderService.extractTag(from: "1234567890"))
    }

    func testRejectsEmptyAndGarbage() {
        XCTAssertNil(EarTagReaderService.extractTag(from: ""))
        XCTAssertNil(EarTagReaderService.extractTag(from: "no tag here"))
    }

    func testNormalizeMatchesFarmerEnteredForms() {
        XCTAssertEqual(
            EarTagReaderService.normalize("tr-12 3456 7890"),
            EarTagReaderService.normalize("TR1234567890")
        )
    }
}
