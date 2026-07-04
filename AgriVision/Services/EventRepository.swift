import Foundation
import Supabase

/// One row of the server-written `events` feed (enroll/identify actions).
struct EventRecord: Identifiable, Decodable, Equatable {
    let id: UUID
    let kind: String       // "enroll" | "identify"
    let animalID: UUID?    // nil for unknown identify
    let result: String     // "enrolled" | "identified" | "unknown"
    let score: Double?     // top-1 similarity for identify, nil for enroll
    let createdAt: Date

    init(id: UUID, kind: String, animalID: UUID?, result: String, score: Double?, createdAt: Date) {
        self.id = id
        self.kind = kind
        self.animalID = animalID
        self.result = result
        self.score = score
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, result, score
        case animalID = "animal_id"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        animalID = try c.decodeIfPresent(UUID.self, forKey: .animalID)
        result = try c.decode(String.self, forKey: .result)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        let createdRaw = try c.decode(String.self, forKey: .createdAt)
        guard let created = PostgrestDate.timestamp(createdRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: c,
                debugDescription: "unparseable timestamptz: \(createdRaw)"
            )
        }
        createdAt = created
    }
}

/// Animal scope for an events query.
enum EventAnimalFilter: Equatable {
    case all
    case specific(UUID)
    case unrecognized   // animal_id IS NULL
}

/// Reads the signed-in owner's recent events via PostgREST (RLS-scoped).
/// GET /rest/v1/events?select=*&order=created_at.desc&limit=N
struct EventRepository {
    private let client: SupabaseClient

    /// Result values that are user-visible feed entries. The events table also
    /// holds failure telemetry rows (invalid_image, storage_failed, ...) that
    /// the app must never render.
    private static let feedResults = ["enrolled", "identified", "unknown"]
    /// Feed queries never select telemetry columns (detail jsonb etc.).
    private static let feedColumns = "id,kind,animal_id,result,score,created_at"

    init(client: SupabaseClient = SupabaseClientProvider.shared) {
        self.client = client
    }

    /// Most recent events, newest first.
    func recent(limit: Int) async throws -> [EventRecord] {
        let response = try await client
            .from("events")
            .select(Self.feedColumns)
            .in("result", values: Self.feedResults)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
        return try JSONDecoder().decode([EventRecord].self, from: response.data)
    }

    /// A page of events (newest first) for the scan-history screen, filtered
    /// server-side so pagination stays correct under filters. `range` is
    /// inclusive: offset..<offset+limit.
    func page(offset: Int, limit: Int, animal: EventAnimalFilter, since: Date?) async throws -> [EventRecord] {
        var query = client.from("events").select(Self.feedColumns)
            .in("result", values: Self.feedResults)
        switch animal {
        case .all: break
        case .specific(let id): query = query.eq("animal_id", value: id.uuidString)
        case .unrecognized: query = query.is("animal_id", value: nil)
        }
        if let since {
            query = query.gte("created_at", value: ISO8601DateFormatter().string(from: since))
        }
        let response = try await query
            .order("created_at", ascending: false)
            .range(from: offset, to: offset + limit - 1)
            .execute()
        return try JSONDecoder().decode([EventRecord].self, from: response.data)
    }
}
