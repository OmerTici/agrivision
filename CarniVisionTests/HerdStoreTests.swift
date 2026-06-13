import XCTest
@testable import CarniVision

private final class MockAnimalListing: AnimalListing {
    var records: [AnimalRecord] = []
    var error: Error?

    func list() async throws -> [AnimalRecord] {
        if let error { throw error }
        return records
    }
}

private final class MockEventListing: EventListing {
    var records: [EventRecord] = []
    var error: Error?

    func recent(limit: Int) async throws -> [EventRecord] {
        if let error { throw error }
        return records
    }
}

@MainActor
final class HerdStoreTests: XCTestCase {
    private let animalID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func makeRecord(embeddingCount: Int) -> AnimalRecord {
        AnimalRecord(
            id: animalID, name: "Deneme 1", tag: "TR-0001", breed: "Holstein",
            sex: "female", birthDate: nil, createdAt: Date(), embeddingCount: embeddingCount
        )
    }

    func testLoadSuccessPopulatesAnimalsAndResolvesEventNames() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let events = MockEventListing()
        events.records = [
            EventRecord(id: UUID(), kind: "identify", animalID: animalID,
                        result: "identified", score: 0.64, createdAt: Date())
        ]
        let store = HerdStore(animalSource: animals, eventSource: events)

        await store.load()

        XCTAssertNil(store.loadError)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.animals.count, 1)
        XCTAssertEqual(store.animals[0].name, "Deneme 1")
        XCTAssertTrue(store.animals[0].muzzleRegistered)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.events[0].animalName, "Deneme 1")
        XCTAssertEqual(store.registeredCount, 1)
        XCTAssertEqual(store.scansThisWeek, 1)
    }

    /// The recent-activity feed is secondary: if events fail (e.g. the `events`
    /// table is missing), the herd must still load and no error banner shows.
    func testEventFeedFailureStillLoadsAnimalsWithoutError() async {
        struct EventsUnavailable: Error {}
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let events = MockEventListing()
        events.error = EventsUnavailable()
        let store = HerdStore(animalSource: animals, eventSource: events)

        await store.load()

        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.animals.count, 1)
        XCTAssertEqual(store.animals[0].name, "Deneme 1")
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func testLoadFailureSetsLoadErrorAndKeepsListsEmpty() async {
        let animals = MockAnimalListing()
        animals.error = URLError(.notConnectedToInternet)
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())

        await store.load()

        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.animals.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func testReloadAfterEnrollFlipsDerivedMuzzleFlag() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 0)]
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())

        await store.load()
        XCTAssertFalse(store.animals[0].muzzleRegistered)

        animals.records = [makeRecord(embeddingCount: 5)]  // enrollment happened server-side
        await store.load()
        XCTAssertTrue(store.animals[0].muzzleRegistered)
        XCTAssertNil(store.loadError)
    }

    func testAddAnimalInsertsOptimisticallyAtTop() async {
        let animals = MockAnimalListing()
        animals.records = [makeRecord(embeddingCount: 5)]
        let store = HerdStore(animalSource: animals, eventSource: MockEventListing())
        await store.load()

        let newID = UUID()
        store.addAnimal(id: newID, name: "Yeni", tag: "TR-0002", breed: "Angus",
                        sex: .male, birthDate: Date())

        XCTAssertEqual(store.animals.count, 2)
        XCTAssertEqual(store.animals[0].id, newID)
        XCTAssertEqual(store.animals[0].name, "Yeni")
        XCTAssertFalse(store.animals[0].muzzleRegistered)
    }
}
