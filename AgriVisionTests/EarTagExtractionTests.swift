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

    func testRealTagLinesOutOfOrderStillAssemblesFullTag() {
        // Vision may emit the serial line before the header; the TR-anchored
        // pattern fails (only 2 digits follow TR) but header + serial
        // assembly recovers the full number anyway.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "1755219 TR 20"), "TR201755219")
    }

    func testAssemblesAcrossBarcodeJunk() {
        // The field coin-flip this fixes: the barcode stripe between the
        // "TR 43" header and the serial OCRs as junk, which used to break
        // the contiguous pattern and drop the read to serial-only.
        XCTAssertEqual(
            EarTagReaderService.extractTag(from: "TR 43 2IIIlIIı 1608816"),
            "TR431608816"
        )
        // Separator-glyph letter after TR, same layout.
        XCTAssertEqual(
            EarTagReaderService.extractTag(from: "TRO03 ıIıIl 2962213"),
            "TR032962213"
        )
    }

    func testExtractHeaderFindsStandaloneHeaderOnly() {
        XCTAssertEqual(EarTagReaderService.extractHeader(from: "TR 43 some junk"), "43")
        XCTAssertEqual(EarTagReaderService.extractHeader(from: "TRO03"), "03")
        // Three digits after TR is a number, not the header.
        XCTAssertNil(EarTagReaderService.extractHeader(from: "TR 0412"))
        XCTAssertNil(EarTagReaderService.extractHeader(from: "TRACTOR"))
        XCTAssertNil(EarTagReaderService.extractHeader(from: "no tag"))
    }

    func testCompletedPoolsHeaderOntoBareSerialOnly() {
        // Bare 7-8 digit serial + pooled header → full tag.
        XCTAssertEqual(
            EarTagReaderService.completed(tag: "1608816", pooledHeader: "43"),
            "TR431608816"
        )
        // Already-complete reads and 9+ digit reads are never re-prefixed.
        XCTAssertEqual(
            EarTagReaderService.completed(tag: "TR431608816", pooledHeader: "43"),
            "TR431608816"
        )
        XCTAssertEqual(
            EarTagReaderService.completed(tag: "201755219", pooledHeader: "43"),
            "201755219"
        )
        XCTAssertEqual(EarTagReaderService.completed(tag: "1608816", pooledHeader: nil), "1608816")
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

    func testToleratesStraySeparatorLettersAfterTR() {
        // Newer tags print "TR◦03"; OCR reads the separator as a letter.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "TRO03 2962212"), "TR032962212")
        // But words starting with TR never become tags.
        XCTAssertEqual(EarTagReaderService.extractTag(from: "TRACTOR 1234567"), "1234567")
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

    // Vote policy: how one round's frame reads merge into a winner.

    func testWinningKeyConfirmsTwoAgreeingFrames() {
        XCTAssertEqual(
            EarTagReaderService.winningKey(for: ["TR201755219", "1755219"]),
            EarTagReaderService.serialKey("1755219")
        )
    }

    func testWinningKeyAcceptsLoneUncontradictedRead() {
        // Most rounds yield one usable frame; failing them would tank success.
        XCTAssertEqual(
            EarTagReaderService.winningKey(for: ["TR201755219"]),
            EarTagReaderService.serialKey("TR201755219")
        )
    }

    func testWinningKeyMajorityBeatsGarbledOutlier() {
        // The field failure this exists for: one rotation-garbled read
        // (2962212 → 7177967) must be outvoted, even if it looks structured.
        XCTAssertEqual(
            EarTagReaderService.winningKey(for: ["2962212", "TR7177967", "2962212"]),
            EarTagReaderService.serialKey("2962212")
        )
    }

    func testWinningKeyConflictFallsToStructure() {
        // One-vs-one conflict: the TR-full (shape-validated) read wins.
        XCTAssertEqual(
            EarTagReaderService.winningKey(for: ["TR032962213", "7177967"]),
            EarTagReaderService.serialKey("TR032962213")
        )
    }

    func testWinningKeyContradictoryRoundFails() {
        // Two conflicting bare serials: no basis to pick — rescan.
        XCTAssertNil(EarTagReaderService.winningKey(for: ["2962212", "7177967"]))
        // Two conflicting TR-full reads: equally structured — rescan.
        XCTAssertNil(EarTagReaderService.winningKey(for: ["TR032962213", "TR201755219"]))
        XCTAssertNil(EarTagReaderService.winningKey(for: []))
    }

    func testRelaxedClassifierCatchesFadedTags() {
        // Sun-bleached olive tag plastic (field case TR 43): fails strict...
        XCTAssertFalse(EarTagReaderService.isTagYellow(r: 0.45, g: 0.40, b: 0.28))
        // ...but passes the relaxed tier.
        XCTAssertTrue(EarTagReaderService.isTagYellowRelaxed(r: 0.45, g: 0.40, b: 0.28))
        // Gray/white/dark still rejected even relaxed.
        XCTAssertFalse(EarTagReaderService.isTagYellowRelaxed(r: 0.6, g: 0.6, b: 0.58))
        XCTAssertFalse(EarTagReaderService.isTagYellowRelaxed(r: 0.12, g: 0.11, b: 0.10))
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

    func testNearMatchSuggestsUniqueOneEditNeighbor() {
        let herd = ["TR201755219", "TR431608816", "TR032962213"]
        // One substituted digit (8 read as 0) — the classic OCR miss.
        XCTAssertEqual(EarTagReaderService.nearMatch(read: "1600816", in: herd), "TR431608816")
        // Header presence on the read doesn't matter; serials are compared.
        XCTAssertEqual(EarTagReaderService.nearMatch(read: "TR431600816", in: herd), "TR431608816")
        // Two edits away — no suggestion.
        XCTAssertNil(EarTagReaderService.nearMatch(read: "1600810", in: herd))
        // Exact match isn't a "near" match (the exact path handles it).
        XCTAssertNil(EarTagReaderService.nearMatch(read: "1608816", in: herd))
    }

    func testNearMatchRefusesAmbiguousCandidates() {
        // Two herd tags each one edit from the read: suggesting either would
        // be a coin flip, so nothing is offered.
        let herd = ["TR431608816", "TR431608817"]
        XCTAssertNil(EarTagReaderService.nearMatch(read: "1608818", in: herd))
    }

    func testWithinOneEdit() {
        XCTAssertTrue(EarTagReaderService.withinOneEdit("1608816", "1608816"))
        XCTAssertTrue(EarTagReaderService.withinOneEdit("1608816", "1600816"))  // substitution
        XCTAssertTrue(EarTagReaderService.withinOneEdit("160816", "1608816"))   // deletion
        XCTAssertTrue(EarTagReaderService.withinOneEdit("16088166", "1608816")) // insertion
        XCTAssertFalse(EarTagReaderService.withinOneEdit("1600810", "1608816")) // two subs
        XCTAssertFalse(EarTagReaderService.withinOneEdit("16016", "1608816"))   // length gap 2
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
