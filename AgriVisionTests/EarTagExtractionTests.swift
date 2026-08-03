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

    // Real tag from field testing: "TR 20" small header, "1755219" big serial.

    func testRealTagBothLinesInOrder() {
        XCTAssertEqual(EarTagReaderService.extractTag(from: "TR 20 1755219"), "TR201755219")
    }

    func testRealTagLinesOutOfOrderFallsBackToSerial() {
        // Vision may emit the serial line before the header; the TR-anchored
        // pattern fails (only 2 digits follow TR) but the serial fallback hits.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "1755219 TR 20"), "1755219")
    }

    func testSerialAloneAcceptedWhenHeaderMissed() {
        XCTAssertEqual(EarTagReaderService.extractTag(from: "1755219"), "1755219")
    }

    func testRejectsShortDigitRuns() {
        // Pen numbers, gate numbers etc. — short runs never lock.
        XCTAssertNil(EarTagReaderService.extractTag(from: "123456"))
        XCTAssertNil(EarTagReaderService.extractTag(from: "pen 42"))
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

    func testFallbackPicksLongestRunAndNeverMergesAcrossGaps() {
        // "42" (a pen number) must not fuse with the serial into "421755219".
        XCTAssertEqual(EarTagReaderService.extractTag(from: "42 1755219"), "1755219")
        // Longest contiguous run wins over a shorter stray number.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "1234567 17552190"), "17552190")
    }

    func testNineDigitRunRestoresTRPrefix() {
        // 9+ digits include the province code — only the letters were missed.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "201755219"), "TR201755219")
        // 7-8 digits are the serial alone; never presented as complete.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "1755219"), "1755219")
    }

    func testSerialKeyPoolsFullAndHeaderlessReads() {
        // Full read, province-only-missed read, and bare serial all pool.
        XCTAssertEqual(
            EarTagReaderService.serialKey("TR201755219"),
            EarTagReaderService.serialKey("1755219")
        )
        XCTAssertEqual(
            EarTagReaderService.serialKey("201755219"),
            EarTagReaderService.serialKey("TR201755219")
        )
        // Different serials stay distinct.
        XCTAssertNotEqual(
            EarTagReaderService.serialKey("TR201755219"),
            EarTagReaderService.serialKey("TR201755218")
        )
    }

    func testTagYellowClassifier() {
        // Bright saturated tag plastic.
        XCTAssertTrue(EarTagReaderService.isTagYellow(r: 0.95, g: 0.85, b: 0.15))
        XCTAssertTrue(EarTagReaderService.isTagYellow(r: 0.80, g: 0.70, b: 0.20))
        // Straw/hay: yellowish hue but dull and desaturated.
        XCTAssertFalse(EarTagReaderService.isTagYellow(r: 0.65, g: 0.60, b: 0.45))
        // Not yellow at all.
        XCTAssertFalse(EarTagReaderService.isTagYellow(r: 0.9, g: 0.9, b: 0.9))  // white
        XCTAssertFalse(EarTagReaderService.isTagYellow(r: 0.2, g: 0.7, b: 0.25)) // green
        XCTAssertFalse(EarTagReaderService.isTagYellow(r: 0.8, g: 0.2, b: 0.15)) // red
        XCTAssertFalse(EarTagReaderService.isTagYellow(r: 0.1, g: 0.1, b: 0.1))  // dark
    }

    func testMatchesExactAndSerialSuffix() {
        XCTAssertTrue(EarTagReaderService.matches(stored: "TR-20 1755219", read: "TR201755219"))
        // Serial-only read matches the stored full tag by suffix.
        XCTAssertTrue(EarTagReaderService.matches(stored: "TR201755219", read: "1755219"))
        // But a serial must not match a stored tag it merely resembles.
        XCTAssertFalse(EarTagReaderService.matches(stored: "TR201755218", read: "1755219"))
        XCTAssertFalse(EarTagReaderService.matches(stored: "", read: "1755219"))
    }
}
