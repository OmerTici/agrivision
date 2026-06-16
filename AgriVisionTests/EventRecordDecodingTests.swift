import XCTest
@testable import AgriVision

final class EventRecordDecodingTests: XCTestCase {
    func testDecodesIdentifyEvent() throws {
        let json = """
        [{
          "id": "0a1b2c3d-1111-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "kind": "identify",
          "animal_id": "9b2e7a44-1111-2222-3333-444455556666",
          "result": "identified",
          "score": 0.64,
          "created_at": "2026-06-12T09:15:00.123456+00:00"
        }]
        """.data(using: .utf8)!

        let record = try XCTUnwrap(JSONDecoder().decode([EventRecord].self, from: json).first)
        XCTAssertEqual(record.kind, "identify")
        XCTAssertEqual(record.result, "identified")
        XCTAssertEqual(record.animalID?.uuidString.lowercased(), "9b2e7a44-1111-2222-3333-444455556666")
        let score = try XCTUnwrap(record.score)
        XCTAssertEqual(score, 0.64, accuracy: 0.0001)
    }

    func testDecodesUnknownIdentifyAndEnrollEvents() throws {
        let json = """
        [{
          "id": "0a1b2c3d-aaaa-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "kind": "identify",
          "animal_id": null,
          "result": "unknown",
          "score": 0.31,
          "created_at": "2026-06-12T09:16:00+00:00"
        },
        {
          "id": "0a1b2c3d-bbbb-2222-3333-444455556666",
          "owner": "11111111-1111-1111-1111-111111111111",
          "kind": "enroll",
          "animal_id": "9b2e7a44-1111-2222-3333-444455556666",
          "result": "enrolled",
          "score": null,
          "created_at": "2026-06-12T09:17:00+00:00"
        }]
        """.data(using: .utf8)!

        let records = try JSONDecoder().decode([EventRecord].self, from: json)
        XCTAssertEqual(records.count, 2)
        XCTAssertNil(records[0].animalID)
        XCTAssertEqual(records[0].result, "unknown")
        XCTAssertEqual(records[1].kind, "enroll")
        XCTAssertNil(records[1].score)
    }
}
