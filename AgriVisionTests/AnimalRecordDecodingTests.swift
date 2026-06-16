import XCTest
@testable import AgriVision

final class AnimalRecordDecodingTests: XCTestCase {
    func testDecodesPostgrestRowWithEmbeddingCount() throws {
        let json = """
        [{
          "id": "9b2e7a44-1111-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "name": "Deneme 1",
          "tag": "TR-0412",
          "breed": "Holstein",
          "sex": "female",
          "birth_date": "2024-03-01",
          "status": null,
          "created_at": "2026-06-11T14:03:21.123456+00:00",
          "embeddings": [{"count": 5}]
        }]
        """.data(using: .utf8)!

        let records = try JSONDecoder().decode([AnimalRecord].self, from: json)
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.id.uuidString.lowercased(), "9b2e7a44-1111-2222-3333-444455556666")
        XCTAssertEqual(record.name, "Deneme 1")
        XCTAssertEqual(record.tag, "TR-0412")
        XCTAssertEqual(record.breed, "Holstein")
        XCTAssertEqual(record.sex, "female")
        XCTAssertEqual(record.embeddingCount, 5)
        XCTAssertTrue(record.muzzleRegistered)

        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let birth = try XCTUnwrap(record.birthDate)
        let parts = calendar.dateComponents([.year, .month, .day], from: birth)
        XCTAssertEqual(parts.year, 2024)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 1)
        let created = calendar.dateComponents([.year, .month, .day, .hour], from: record.createdAt)
        XCTAssertEqual(created.year, 2026)
        XCTAssertEqual(created.hour, 14)
    }

    func testDecodesNullsZeroCountAndWholeSecondTimestamp() throws {
        let json = """
        [{
          "id": "9b2e7a44-aaaa-bbbb-cccc-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "name": null,
          "tag": null,
          "breed": null,
          "sex": null,
          "birth_date": null,
          "status": null,
          "created_at": "2026-06-11T14:03:21+00:00",
          "embeddings": [{"count": 0}]
        }]
        """.data(using: .utf8)!

        let record = try XCTUnwrap(JSONDecoder().decode([AnimalRecord].self, from: json).first)
        XCTAssertNil(record.name)
        XCTAssertNil(record.birthDate)
        XCTAssertEqual(record.embeddingCount, 0)
        XCTAssertFalse(record.muzzleRegistered)
    }
}
