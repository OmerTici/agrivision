import SwiftUI
import XCTest
@testable import AgriVision

@MainActor
final class EventFormattingTests: XCTestCase {
    private var previousLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        previousLanguage = LanguageManager.shared.language
    }

    override func tearDown() {
        LanguageManager.shared.language = previousLanguage
        super.tearDown()
    }

    private func makeEvent(result: String, score: Double?, animalName: String?) -> ScanEvent {
        let id = UUID()
        let record = EventRecord(
            id: UUID(),
            kind: result == "enrolled" ? "enroll" : "identify",
            animalID: animalName == nil ? nil : id,
            result: result,
            score: score,
            createdAt: Date()
        )
        let animals = animalName.map { name in
            [Animal(id: id, name: name, tag: "TR-1", breed: "Holstein", sex: .female,
                    birthDate: nil, createdAt: Date(), muzzleRegistered: true,
                    avatarColor: .purple)]
        } ?? []
        return ScanEvent(record: record, animals: animals)
    }

    func testIdentifiedWithScoreEnglish() {
        LanguageManager.shared.language = .english
        let event = makeEvent(result: "identified", score: 0.64, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — identified (0.64)")
    }

    func testIdentifiedWithScoreTurkish() {
        LanguageManager.shared.language = .turkish
        let event = makeEvent(result: "identified", score: 0.64, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — tanımlandı (0.64)")
    }

    func testEnrolledEnglishAndTurkish() {
        LanguageManager.shared.language = .english
        var event = makeEvent(result: "enrolled", score: nil, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — enrolled")

        LanguageManager.shared.language = .turkish
        event = makeEvent(result: "enrolled", score: nil, animalName: "Deneme 1")
        XCTAssertEqual(event.title(LanguageManager.shared), "Deneme 1 — kaydedildi")
    }

    func testUnknownEnglishAndTurkish() {
        LanguageManager.shared.language = .english
        var event = makeEvent(result: "unknown", score: 0.31, animalName: nil)
        XCTAssertEqual(event.title(LanguageManager.shared), "Unknown animal — no match")

        LanguageManager.shared.language = .turkish
        event = makeEvent(result: "unknown", score: 0.31, animalName: nil)
        XCTAssertEqual(event.title(LanguageManager.shared), "Bilinmeyen hayvan — eşleşme yok")
    }
}
