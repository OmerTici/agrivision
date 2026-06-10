import SwiftUI

struct SettingsScreen: View {
    @ObservedObject private var lang = LanguageManager.shared

    @State private var notificationsOn = true
    @State private var autoCaptureOn = true
    @State private var metricUnits = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                profileCard
                languageSection
                preferencesSection
                aboutSection
                signOutButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
    }

    private var header: some View {
        Text(lang.t("settings.title"))
            .font(CarniFont.bold(24))
            .foregroundStyle(CarniColors.purpleDark)
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(CarniColors.purple.opacity(0.14))
                Text("GV")
                    .font(CarniFont.bold(20))
                    .foregroundStyle(CarniColors.purple)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("Green Valley Farm")
                    .font(CarniFont.bold(17))
                    .foregroundStyle(CarniColors.purpleDark)
                Text("owner@greenvalley.farm")
                    .font(CarniFont.regular(13))
                    .foregroundStyle(CarniColors.tabInactive)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .carniCard()
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: lang.t("settings.language"))

            VStack(spacing: 0) {
                ForEach(Array(AppLanguage.allCases.enumerated()), id: \.element) { index, option in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            lang.language = option
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(option.rawValue.uppercased())
                                .font(CarniFont.bold(12))
                                .foregroundStyle(CarniColors.purple)
                                .frame(width: 34, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(CarniColors.purple.opacity(0.12))
                                )
                            Text(option.displayName)
                                .font(CarniFont.regular(15))
                                .foregroundStyle(CarniColors.purpleDark)
                            Spacer()
                            if lang.language == option {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(CarniColors.purple)
                            } else {
                                Circle()
                                    .strokeBorder(CarniColors.tabInactive.opacity(0.4), lineWidth: 1.5)
                                    .frame(width: 18, height: 18)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    if index < AppLanguage.allCases.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(settingsCardBackground)
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: lang.t("settings.preferences"))

            VStack(spacing: 0) {
                ToggleRow(
                    icon: "bell.fill",
                    tint: Color(red: 222 / 255, green: 138 / 255, blue: 60 / 255),
                    title: lang.t("settings.notifications"),
                    isOn: $notificationsOn
                )
                Divider().opacity(0.5)
                ToggleRow(
                    icon: "camera.fill",
                    tint: CarniColors.purple,
                    title: lang.t("settings.autoCapture"),
                    isOn: $autoCaptureOn
                )
                Divider().opacity(0.5)
                ToggleRow(
                    icon: "scalemass.fill",
                    tint: CarniColors.successGreen,
                    title: lang.t("settings.metric"),
                    isOn: $metricUnits
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(settingsCardBackground)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: lang.t("settings.about"))

            VStack(spacing: 0) {
                LinkRow(
                    icon: "questionmark.circle.fill",
                    tint: Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
                    title: lang.t("settings.help")
                )
                Divider().opacity(0.5)
                LinkRow(icon: "doc.text.fill", tint: CarniColors.tabInactive, title: lang.t("settings.privacy"))
                Divider().opacity(0.5)
                HStack(spacing: 12) {
                    IconBadge(icon: "info.circle.fill", tint: CarniColors.purpleLight)
                    Text(lang.t("settings.version"))
                        .font(CarniFont.regular(15))
                        .foregroundStyle(CarniColors.purpleDark)
                    Spacer()
                    Text("0.1.0 (beta)")
                        .font(CarniFont.regular(13))
                        .foregroundStyle(CarniColors.tabInactive)
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(settingsCardBackground)
        }
    }

    private var settingsCardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white)
            .shadow(color: CarniColors.purpleDark.opacity(0.07), radius: 12, y: 4)
    }

    private var signOutButton: some View {
        Button {
            // Hook up to auth flow later.
        } label: {
            Label(lang.t("settings.signout"), systemImage: "rectangle.portrait.and.arrow.right")
                .font(CarniFont.semibold(15))
                .foregroundStyle(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255).opacity(0.09))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct IconBadge: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }
}

private struct ToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(icon: icon, tint: tint)
            Text(title)
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(CarniColors.purple)
        }
        .padding(.vertical, 9)
    }
}

private struct LinkRow: View {
    let icon: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(icon: icon, tint: tint)
            Text(title)
                .font(CarniFont.regular(15))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .padding(.vertical, 12)
    }
}
