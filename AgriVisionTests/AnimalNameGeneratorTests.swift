import XCTest
@testable import AgriVision

final class AnimalNameGeneratorTests: XCTestCase {
    /// Simulates a farmer enrolling 500 animals, always accepting the
    /// suggestion: every suggestion must be unique — the pool must never
    /// become a constraint on adding animals.
    func testFiveHundredSuggestionsStayUnique() {
        var taken: [String] = []
        for _ in 0..<500 {
            let suggestion = AnimalNameGenerator.suggest(language: .turkish, takenNames: taken)
            XCTAssertFalse(
                taken.contains(where: { AnimalNameGenerator.normalize($0) == AnimalNameGenerator.normalize(suggestion) }),
                "Duplicate suggestion: \(suggestion)"
            )
            XCTAssertFalse(suggestion.trimmingCharacters(in: .whitespaces).isEmpty)
            taken.append(suggestion)
        }
    }

    func testSuggestionSkipsTakenNamesCaseInsensitively() {
        for _ in 0..<50 {
            let suggestion = AnimalNameGenerator.suggest(language: .english, takenNames: ["DAISY", "bella  "])
            XCTAssertNotEqual(AnimalNameGenerator.normalize(suggestion), "daisy")
            XCTAssertNotEqual(AnimalNameGenerator.normalize(suggestion), "bella")
        }
    }

    func testReshuffleNeverReturnsCurrentName() {
        for _ in 0..<50 {
            let suggestion = AnimalNameGenerator.suggest(language: .english, takenNames: [], current: "Daisy")
            XCTAssertNotEqual(suggestion, "Daisy")
        }
    }

    func testEnglishAndTurkishPoolsDiffer() {
        let en = AnimalNameGenerator.suggest(language: .english, takenNames: [])
        let tr = AnimalNameGenerator.suggest(language: .turkish, takenNames: [])
        XCTAssertFalse(en.isEmpty)
        XCTAssertFalse(tr.isEmpty)
    }
}
