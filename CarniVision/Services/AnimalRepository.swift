import Foundation
import Supabase

/// One inserted animal's identifier (the new row's UUID, as a string).
struct CreatedAnimal {
    let id: String
}

/// Inserts animal rows into the embedder project's `animals` table.
struct AnimalRepository {
    private let client: SupabaseClient

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    /// Row payload sent to Supabase. `birth_date` is an ISO-8601 date string
    /// (YYYY-MM-DD); `sex` is lowercased free text ("female" | "male").
    private struct AnimalInsert: Encodable {
        let owner: String
        let name: String
        let tag: String
        let breed: String
        let sex: String
        let birth_date: String
    }

    private struct AnimalRow: Decodable {
        let id: UUID
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Inserts a new animal owned by `ownerID` and returns its id.
    func create(
        ownerID: String,
        name: String,
        tag: String,
        breed: String,
        sex: AnimalSex,
        birthDate: Date
    ) async throws -> CreatedAnimal {
        let payload = AnimalInsert(
            owner: ownerID,
            name: name,
            tag: tag,
            breed: breed,
            sex: sex.rawValue.lowercased(),     // "female" | "male"
            birth_date: Self.dateFormatter.string(from: birthDate)
        )
        let row: AnimalRow = try await client
            .from("animals")
            .insert(payload)
            .select("id")
            .single()
            .execute()
            .value
        return CreatedAnimal(id: row.id.uuidString)
    }
}
