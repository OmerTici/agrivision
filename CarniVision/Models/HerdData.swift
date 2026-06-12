import SwiftUI

// MARK: - Models

enum AnimalSex: String, CaseIterable, Identifiable {
    case female = "Female"
    case male = "Male"

    var id: String { rawValue }

    var key: String {
        switch self {
        case .female: return "sex.female"
        case .male: return "sex.male"
        }
    }
}

struct Animal: Identifiable {
    let id: UUID
    var name: String
    var tag: String
    var breed: String
    var sex: AnimalSex
    var birthDate: Date?
    /// Enrollment date (the DB row's created_at).
    var createdAt: Date
    /// Derived server-side: true when the animal has at least one embedding.
    var muzzleRegistered: Bool
    var avatarColor: Color

    func ageDescription(_ lang: LanguageManager) -> String {
        guard let birthDate else { return "—" }
        let parts = Calendar.current.dateComponents([.year, .month], from: birthDate, to: Date())
        let years = parts.year ?? 0
        let months = parts.month ?? 0
        let yr = lang.t("unit.yr")
        let mo = lang.t("unit.mo")
        if years == 0 { return "\(months) \(mo)" }
        if months == 0 { return "\(years) \(yr)" }
        return "\(years) \(yr) \(months) \(mo)"
    }
}

extension Animal {
    static let avatarPalette: [Color] = [
        CarniColors.purple,
        Color(red: 70 / 255, green: 152 / 255, blue: 115 / 255),
        Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
        Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255),
        Color(red: 204 / 255, green: 96 / 255, blue: 144 / 255),
        Color(red: 52 / 255, green: 144 / 255, blue: 150 / 255),
    ]

    init(record: AnimalRecord) {
        self.init(
            id: record.id,
            name: record.name ?? "",
            tag: record.tag ?? "",
            breed: record.breed ?? "",
            sex: record.sex == "male" ? .male : .female,
            birthDate: record.birthDate,
            createdAt: record.createdAt,
            muzzleRegistered: record.muzzleRegistered,
            // Stable across launches: derived from the UUID, not array position.
            avatarColor: Self.avatarPalette[Int(record.id.uuid.0) % Self.avatarPalette.count]
        )
    }
}

/// One enroll/identify action from the server-side events feed, with the
/// animal's display info resolved against the loaded herd.
struct ScanEvent: Identifiable {
    let id: UUID
    let kind: String      // "enroll" | "identify"
    let result: String    // "enrolled" | "identified" | "unknown"
    let score: Double?
    let date: Date
    let animalID: UUID?
    let animalName: String?
    let avatarColor: Color

    init(record: EventRecord, animals: [Animal]) {
        let animal = record.animalID.flatMap { id in animals.first(where: { $0.id == id }) }
        self.id = record.id
        self.kind = record.kind
        self.result = record.result
        self.score = record.score
        self.date = record.createdAt
        self.animalID = record.animalID
        self.animalName = animal?.name
        self.avatarColor = animal?.avatarColor ?? Color.gray
    }

    /// Row text, e.g. "Deneme 1 — identified (0.64)" / "Unknown animal — no match".
    func title(_ lang: LanguageManager) -> String {
        let name = animalName ?? lang.t("event.unknownAnimal")
        switch result {
        case "enrolled":
            return lang.t("event.enrolled", name)
        case "identified":
            if let score {
                return lang.t("event.identified", name, score)
            }
            return lang.t("event.identifiedNoScore", name)
        default:
            return lang.t("event.noMatch")
        }
    }

    var icon: String {
        switch result {
        case "enrolled": return "plus.viewfinder"
        case "identified": return "checkmark.seal.fill"
        default: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch result {
        case "enrolled": return Color(red: 64 / 255, green: 130 / 255, blue: 224 / 255)
        case "identified": return CarniColors.successGreen
        default: return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255)
        }
    }
}

// MARK: - Repository seams (tests substitute these)

protocol AnimalListing {
    func list() async throws -> [AnimalRecord]
}

protocol EventListing {
    func recent(limit: Int) async throws -> [EventRecord]
}

extension AnimalRepository: AnimalListing {}
extension EventRepository: EventListing {}

// MARK: - Store

/// Owns the herd + event feed for the UI. No seed data: empty until `load()`.
@MainActor
final class HerdStore: ObservableObject {
    @Published var animals: [Animal] = []
    @Published var events: [ScanEvent] = []
    @Published var isLoading = false
    @Published var loadError: String?

    private let animalSource: AnimalListing
    private let eventSource: EventListing

    init(
        animalSource: AnimalListing = AnimalRepository(),
        eventSource: EventListing = EventRepository()
    ) {
        self.animalSource = animalSource
        self.eventSource = eventSource
    }

    var registeredCount: Int {
        animals.filter(\.muzzleRegistered).count
    }

    var scansThisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return events.filter { $0.date > weekAgo }.count
    }

    /// Fetches animals and events concurrently. Called on sign-in (MainTabView
    /// .task), pull-to-refresh, after a successful enrollment, and after an
    /// identify returns (the server wrote an event either way).
    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            async let animalRecords = animalSource.list()
            async let eventRecords = eventSource.recent(limit: 20)
            let (records, recent) = try await (animalRecords, eventRecords)
            let loaded = records.map(Animal.init(record:))
            animals = loaded
            events = recent.map { ScanEvent(record: $0, animals: loaded) }
        } catch {
            loadError = Self.loadErrorMessage(for: error)
        }
    }

    /// Optimistic insert after AnimalRepository.create succeeds; reconciled by
    /// the next load(). muzzleRegistered stays false until embeddings exist.
    func addAnimal(
        id: UUID, name: String, tag: String, breed: String,
        sex: AnimalSex, birthDate: Date
    ) {
        let record = AnimalRecord(
            id: id, name: name, tag: tag, breed: breed,
            sex: sex.rawValue.lowercased(), birthDate: birthDate,
            createdAt: Date(), embeddingCount: 0
        )
        animals.insert(Animal(record: record), at: 0)
    }

    /// Maps load failures to a localized banner message at the UI boundary
    /// (same pattern as CameraModel.localizedRecognitionMessage).
    static func loadErrorMessage(for error: Error) -> String {
        let lang = LanguageManager.shared
        if error is URLError {
            return lang.t("recognition.error.network")
        }
        return lang.t("common.loadError")
    }
}

// MARK: - TEMPORARY compatibility shims (deleted by Tasks 10-12)
// These keep HomeView/AnimalsView/AddAnimalView compiling until each screen is
// rewritten. DO NOT ship: Task 14's grep step verifies they are gone.

extension HerdStore {
    func addAnimal(
        name: String, tag: String, breed: String, sex: AnimalSex,
        birthDate: Date, initialWeightKg: Double?, muzzleRegistered: Bool
    ) {
        addAnimal(id: UUID(), name: name, tag: tag, breed: breed, sex: sex, birthDate: birthDate)
    }

    func markLastAddedMuzzleRegistered() {
        Task { await load() }
    }
}
