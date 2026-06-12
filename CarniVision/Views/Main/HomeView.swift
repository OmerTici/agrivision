import Charts
import SwiftUI

// MARK: - Shared screen components

extension View {
    /// White rounded card with the app's soft shadow.
    func carniCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: CarniColors.purpleDark.opacity(0.07), radius: 12, y: 4)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(CarniFont.bold(18))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(CarniFont.semibold(13))
                        .foregroundStyle(CarniColors.purple)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Color-codes how overdue an animal's muzzle scan is.
func scanUrgencyColor(_ lastScanned: Date?) -> Color {
    guard let lastScanned else {
        return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255)
    }
    let days = Date().timeIntervalSince(lastScanned) / 86400
    if days >= 7 { return Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255) }
    if days >= 2 { return Color(red: 226 / 255, green: 142 / 255, blue: 48 / 255) }
    return CarniColors.successGreen
}

struct AnimalAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
            Text(name.prefix(1).uppercased())
                .font(CarniFont.bold(size * 0.42))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Home

struct HomeScreen: View {
    @EnvironmentObject private var store: HerdStore
    @ObservedObject private var lang = LanguageManager.shared
    var onSeeAllAnimals: () -> Void = {}

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                statsGrid
                needsScanSection
                weightTrendCard
                recentScansSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return lang.t("greeting.morning")
        case 12..<18: return lang.t("greeting.afternoon")
        default: return lang.t("greeting.evening")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(CarniFont.regular(14))
                    .foregroundStyle(CarniColors.tabInactive)
                Text("Green Valley Farm")
                    .font(CarniFont.bold(24))
                    .foregroundStyle(CarniColors.purpleDark)
            }
            Spacer()
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CarniColors.purpleDark)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.white)
                            .shadow(color: CarniColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                    )
                Circle()
                    .fill(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255))
                    .frame(width: 9, height: 9)
                    .offset(x: -3, y: 3)
            }
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
            StatCard(
                icon: "pawprint.fill",
                tint: CarniColors.purple,
                value: "\(store.animals.count)",
                label: lang.t("home.animals")
            )
            StatCard(
                icon: "scalemass.fill",
                tint: CarniColors.successGreen,
                value: String(format: "%.0f kg", store.averageWeight),
                label: lang.t("home.avgWeight")
            )
            StatCard(
                icon: "camera.viewfinder",
                tint: Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255),
                value: "\(store.scansThisWeek)",
                label: lang.t("home.scansThisWeek")
            )
            StatCard(
                icon: "checkmark.seal.fill",
                tint: Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
                value: "\(store.registeredCount)/\(store.animals.count)",
                label: lang.t("home.muzzleIDs")
            )
        }
    }

    private var weightTrendCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(lang.t("home.weightTrend"))
                    .font(CarniFont.bold(16))
                    .foregroundStyle(CarniColors.purpleDark)
                Spacer()
                if let first = store.herdTrend.first?.kg, let last = store.herdTrend.last?.kg, first > 0 {
                    let pct = (last - first) / first * 100
                    Label(String(format: "%+.1f%%", pct), systemImage: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(CarniFont.semibold(12))
                        .foregroundStyle(pct >= 0 ? CarniColors.successGreen : Color.red)
                }
            }

            Chart(store.herdTrend) { entry in
                AreaMark(
                    x: .value("Month", entry.date, unit: .month),
                    y: .value("Weight", entry.kg)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [CarniColors.purple.opacity(0.25), CarniColors.purple.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Month", entry.date, unit: .month),
                    y: .value("Weight", entry.kg)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .foregroundStyle(CarniColors.purple)
            }
            .chartYScale(domain: chartDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(CarniFont.regular(11))
                        .foregroundStyle(CarniColors.tabInactive)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) {
                    AxisGridLine().foregroundStyle(CarniColors.tabInactive.opacity(0.2))
                    AxisValueLabel()
                        .font(CarniFont.regular(11))
                        .foregroundStyle(CarniColors.tabInactive)
                }
            }
            .frame(height: 150)
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carniCard()
    }

    private var chartDomain: ClosedRange<Double> {
        let values = store.herdTrend.map(\.kg)
        let low = (values.min() ?? 0) - 15
        let high = (values.max() ?? 100) + 15
        return low...high
    }

    private var needsScanSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: lang.t("home.needsScan"), actionTitle: lang.t("home.seeAll"), action: onSeeAllAnimals)

            VStack(spacing: 10) {
                ForEach(store.animalsByScanUrgency.prefix(3)) { animal in
                    NeedsScanRow(animal: animal)
                }
            }
        }
    }

    private var recentScansSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: lang.t("home.recentScans"), actionTitle: lang.t("home.seeAll"), action: onSeeAllAnimals)

            VStack(spacing: 10) {
                ForEach(store.recentScans) { scan in
                    ScanRow(scan: scan)
                }
            }
        }
    }
}

private struct StatCard: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.13))
                )
            Text(value)
                .font(CarniFont.bold(21))
                .foregroundStyle(CarniColors.purpleDark)
            Text(label)
                .font(CarniFont.regular(12))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .carniCard(padding: 14)
    }
}

private struct NeedsScanRow: View {
    let animal: Animal
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            AnimalAvatar(name: animal.name, color: animal.avatarColor, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(animal.name)
                    .font(CarniFont.semibold(15))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(animal.tag)
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
            }

            Spacer()

            let tint = scanUrgencyColor(animal.lastScanned)
            Label(
                animal.lastScanned.map { lang.timeAgo($0) } ?? lang.t("animals.never"),
                systemImage: "clock.arrow.circlepath"
            )
            .font(CarniFont.semibold(12))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.12)))
        }
        .carniCard(padding: 12)
    }
}

private struct ScanRow: View {
    let scan: ScanEvent
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 12) {
            AnimalAvatar(name: scan.animalName ?? "?", color: scan.avatarColor, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(scan.animalName ?? lang.t("event.unknownAnimal"))
                    .font(CarniFont.semibold(15))
                    .foregroundStyle(CarniColors.purpleDark)
                Text(lang.timeAgo(scan.date))
                    .font(CarniFont.regular(12))
                    .foregroundStyle(CarniColors.tabInactive)
                    .lineLimit(1)
            }

            Spacer()

            Label(scan.title(lang), systemImage: scan.icon)
                .font(CarniFont.semibold(11))
                .foregroundStyle(scan.color)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(scan.color.opacity(0.12)))
        }
        .carniCard(padding: 12)
    }
}
