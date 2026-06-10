import SwiftUI

// MARK: - Models

struct WeightEntry: Identifiable {
    let id = UUID()
    let date: Date
    let kg: Double
}

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

enum AnimalStatus: String {
    case healthy = "Healthy"
    case pregnant = "Pregnant"
    case attention = "Needs Attention"

    var key: String {
        switch self {
        case .healthy: return "status.healthy"
        case .pregnant: return "status.pregnant"
        case .attention: return "status.attention"
        }
    }

    var color: Color {
        switch self {
        case .healthy: return CarniColors.successGreen
        case .pregnant: return Color(red: 64 / 255, green: 130 / 255, blue: 224 / 255)
        case .attention: return Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255)
        }
    }
}

struct Animal: Identifiable {
    let id = UUID()
    var name: String
    var tag: String
    var breed: String
    var sex: AnimalSex
    var birthDate: Date
    var status: AnimalStatus
    var muzzleRegistered: Bool
    /// When this animal's muzzle was last scanned; nil if never.
    var lastScanned: Date?
    var weights: [WeightEntry]
    var avatarColor: Color

    var currentWeight: Double? { weights.last?.kg }

    /// Change since the previous weigh-in.
    var weightDelta: Double? {
        guard weights.count >= 2 else { return nil }
        return weights[weights.count - 1].kg - weights[weights.count - 2].kg
    }

    func ageDescription(_ lang: LanguageManager) -> String {
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

enum ScanResult: String {
    case identified = "Identified"
    case newRegistration = "New ID"
    case failed = "No Match"

    var key: String {
        switch self {
        case .identified: return "scan.identified"
        case .newRegistration: return "scan.newID"
        case .failed: return "scan.noMatch"
        }
    }

    var color: Color {
        switch self {
        case .identified: return CarniColors.successGreen
        case .newRegistration: return Color(red: 64 / 255, green: 130 / 255, blue: 224 / 255)
        case .failed: return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255)
        }
    }

    var icon: String {
        switch self {
        case .identified: return "checkmark.seal.fill"
        case .newRegistration: return "plus.viewfinder"
        case .failed: return "questionmark.circle.fill"
        }
    }
}

struct ScanEvent: Identifiable {
    let id = UUID()
    var animalName: String
    var animalTag: String
    var date: Date
    var result: ScanResult
    var avatarColor: Color
}

// MARK: - Store (dummy data for now; backend comes later)

final class HerdStore: ObservableObject {
    @Published var animals: [Animal]
    @Published var recentScans: [ScanEvent]
    /// Average herd weight over the past months, for the dashboard trend chart.
    @Published var herdTrend: [WeightEntry]

    var averageWeight: Double {
        let current = animals.compactMap(\.currentWeight)
        guard !current.isEmpty else { return 0 }
        return current.reduce(0, +) / Double(current.count)
    }

    var scansThisWeek: Int {
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return recentScans.filter { $0.date > weekAgo }.count
    }

    var registeredCount: Int {
        animals.filter(\.muzzleRegistered).count
    }

    /// Animals ordered by scan urgency: never scanned first, then longest since last scan.
    var animalsByScanUrgency: [Animal] {
        animals.sorted { ($0.lastScanned ?? .distantPast) < ($1.lastScanned ?? .distantPast) }
    }

    init() {
        let purple = CarniColors.purple
        let green = Color(red: 70 / 255, green: 152 / 255, blue: 115 / 255)
        let blue = Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255)
        let orange = Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255)
        let pink = Color(red: 204 / 255, green: 96 / 255, blue: 144 / 255)
        let teal = Color(red: 52 / 255, green: 144 / 255, blue: 150 / 255)

        animals = [
            Animal(
                name: "Daisy", tag: "TR-0241", breed: "Holstein", sex: .female,
                birthDate: Self.yearsAgo(4, months: 2), status: .healthy, muzzleRegistered: true,
                lastScanned: Self.hoursAgo(2),
                weights: Self.monthlySeries([596, 601, 605, 603, 608, 612]), avatarColor: purple
            ),
            Animal(
                name: "Bella", tag: "TR-0187", breed: "Angus", sex: .female,
                birthDate: Self.yearsAgo(3, months: 5), status: .pregnant, muzzleRegistered: true,
                lastScanned: Self.hoursAgo(5 * 24),
                weights: Self.monthlySeries([488, 495, 502, 509, 514, 521]), avatarColor: pink
            ),
            Animal(
                name: "Thor", tag: "TR-0093", breed: "Simmental", sex: .male,
                birthDate: Self.yearsAgo(5, months: 1), status: .healthy, muzzleRegistered: true,
                lastScanned: Self.hoursAgo(5),
                weights: Self.monthlySeries([905, 918, 926, 931, 940, 947]), avatarColor: blue
            ),
            Animal(
                name: "Luna", tag: "TR-0312", breed: "Jersey", sex: .female,
                birthDate: Self.yearsAgo(2, months: 0), status: .healthy, muzzleRegistered: true,
                lastScanned: Self.hoursAgo(29),
                weights: Self.monthlySeries([388, 395, 401, 406, 412, 415]), avatarColor: teal
            ),
            Animal(
                name: "Rosie", tag: "TR-0156", breed: "Hereford", sex: .female,
                birthDate: Self.yearsAgo(6, months: 3), status: .attention, muzzleRegistered: true,
                lastScanned: Self.hoursAgo(12 * 24),
                weights: Self.monthlySeries([575, 571, 568, 566, 562, 558]), avatarColor: orange
            ),
            Animal(
                name: "Clover", tag: "TR-0388", breed: "Holstein", sex: .female,
                birthDate: Self.yearsAgo(0, months: 11), status: .healthy, muzzleRegistered: false,
                lastScanned: nil,
                weights: Self.monthlySeries([212, 228, 241, 256, 270, 284]), avatarColor: green
            ),
        ]

        recentScans = [
            ScanEvent(
                animalName: "Daisy", animalTag: "TR-0241",
                date: Self.hoursAgo(2), result: .identified, avatarColor: purple
            ),
            ScanEvent(
                animalName: "Thor", animalTag: "TR-0093",
                date: Self.hoursAgo(5), result: .identified, avatarColor: blue
            ),
            ScanEvent(
                animalName: "Clover", animalTag: "TR-0388",
                date: Self.hoursAgo(22), result: .newRegistration, avatarColor: green
            ),
            ScanEvent(
                animalName: "Luna", animalTag: "TR-0312",
                date: Self.hoursAgo(29), result: .identified, avatarColor: teal
            ),
            ScanEvent(
                animalName: "Unknown", animalTag: "—",
                date: Self.hoursAgo(50), result: .failed, avatarColor: Color.gray
            ),
        ]

        herdTrend = Self.monthlySeries([512, 518, 524, 529, 537, 556])
    }

    func addAnimal(
        name: String, tag: String, breed: String, sex: AnimalSex,
        birthDate: Date, initialWeightKg: Double?, muzzleRegistered: Bool
    ) {
        let palette: [Color] = [
            CarniColors.purple,
            Color(red: 70 / 255, green: 152 / 255, blue: 115 / 255),
            Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
            Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255),
            Color(red: 204 / 255, green: 96 / 255, blue: 144 / 255),
            Color(red: 52 / 255, green: 144 / 255, blue: 150 / 255),
        ]
        var weights: [WeightEntry] = []
        if let kg = initialWeightKg {
            weights.append(WeightEntry(date: Date(), kg: kg))
        }
        let animal = Animal(
            name: name, tag: tag, breed: breed, sex: sex,
            birthDate: birthDate, status: .healthy, muzzleRegistered: muzzleRegistered,
            lastScanned: muzzleRegistered ? Date() : nil,
            weights: weights, avatarColor: palette[animals.count % palette.count]
        )
        animals.insert(animal, at: 0)
    }

    // MARK: Date helpers for seed data

    private static func yearsAgo(_ years: Int, months: Int) -> Date {
        Calendar.current.date(byAdding: DateComponents(month: -(years * 12 + months)), to: Date()) ?? Date()
    }

    private static func hoursAgo(_ hours: Int) -> Date {
        Date().addingTimeInterval(-Double(hours) * 3600)
    }

    /// Builds a monthly weigh-in series ending this month.
    private static func monthlySeries(_ values: [Double]) -> [WeightEntry] {
        values.enumerated().map { index, kg in
            let monthsBack = values.count - 1 - index
            let date = Calendar.current.date(byAdding: .month, value: -monthsBack, to: Date()) ?? Date()
            return WeightEntry(date: date, kg: kg)
        }
    }
}
