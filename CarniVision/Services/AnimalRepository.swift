import Foundation
import Supabase

/// One inserted animal's identifier (the new row's UUID, as a string).
struct CreatedAnimal {
    let id: String
}

/// Parses PostgREST date strings deterministically (no reliance on the
/// supabase-swift internal decoder, so fixtures decode with plain JSONDecoder).
enum PostgrestDate {
    /// `date` columns: YYYY-MM-DD.
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `timestamptz` columns: ISO-8601, with or without fractional seconds.
    /// PostgREST emits microsecond precision, which ISO8601DateFormatter can
    /// reject — when both formatters fail, trim the fraction and retry
    /// (sub-second precision is irrelevant for display).
    static func timestamp(_ raw: String) -> Date? {
        if let date = fractional.date(from: raw) ?? whole.date(from: raw) {
            return date
        }
        guard let dotIndex = raw.firstIndex(of: ".") else { return nil }
        let tail = raw[raw.index(after: dotIndex)...]
        guard let tzIndex = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else {
            return nil
        }
        return whole.date(from: String(raw[..<dotIndex]) + String(tail[tzIndex...]))
    }
}

/// One row of `animals` with its embedding count, as returned by PostgREST
/// (`select=*,embeddings(count)`). Schema columns are nullable free text.
struct AnimalRecord: Identifiable, Decodable {
    let id: UUID
    let name: String?
    let tag: String?
    let breed: String?
    let sex: String?           // "female" | "male" (free text in the schema)
    let birthDate: Date?
    let createdAt: Date
    let embeddingCount: Int

    /// Derived, never a locally flipped flag: registered == embeddings exist.
    var muzzleRegistered: Bool { embeddingCount > 0 }

    init(
        id: UUID, name: String?, tag: String?, breed: String?, sex: String?,
        birthDate: Date?, createdAt: Date, embeddingCount: Int
    ) {
        self.id = id
        self.name = name
        self.tag = tag
        self.breed = breed
        self.sex = sex
        self.birthDate = birthDate
        self.createdAt = createdAt
        self.embeddingCount = embeddingCount
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tag, breed, sex, embeddings
        case birthDate = "birth_date"
        case createdAt = "created_at"
    }

    private struct EmbeddingCount: Decodable { let count: Int }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        breed = try c.decodeIfPresent(String.self, forKey: .breed)
        sex = try c.decodeIfPresent(String.self, forKey: .sex)
        birthDate = try c.decodeIfPresent(String.self, forKey: .birthDate)
            .flatMap { PostgrestDate.dateOnly.date(from: $0) }
        let createdRaw = try c.decode(String.self, forKey: .createdAt)
        guard let created = PostgrestDate.timestamp(createdRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: c,
                debugDescription: "unparseable timestamptz: \(createdRaw)"
            )
        }
        createdAt = created
        embeddingCount = (try c.decodeIfPresent([EmbeddingCount].self, forKey: .embeddings))?
            .first?.count ?? 0
    }
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

    /// All of the signed-in owner's animals (RLS-scoped), newest first, with
    /// embedding counts. PostgREST: GET /rest/v1/animals?select=*,embeddings(count)
    /// &order=created_at.desc — decoded with plain JSONDecoder because
    /// AnimalRecord parses its own dates.
    func list() async throws -> [AnimalRecord] {
        let response = try await client
            .from("animals")
            .select("*, embeddings(count)")
            .order("created_at", ascending: false)
            .execute()
        return try JSONDecoder().decode([AnimalRecord].self, from: response.data)
    }
}
