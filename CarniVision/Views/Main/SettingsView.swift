import SwiftUI
import Supabase

struct SettingsScreen: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared

    @State private var notificationsOn = true
    @State private var autoCaptureOn = true
    @State private var metricUnits = true
    @State private var accountSheet: AccountSheet?

    /// Set when presented as a sheet (from the Home gear); nil when embedded.
    var onClose: (() -> Void)? = nil

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                header
                profileCard
                accountSection
                languageSection
                preferencesSection
                aboutSection
                signOutButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, CarniLayout.tabBarClearance)
        }
        .sheet(item: $accountSheet) { sheet in
            switch sheet {
            case .email:
                ChangeEmailSheet(currentEmail: userEmail).environmentObject(auth)
            case .password:
                ChangePasswordSheet().environmentObject(auth)
            }
        }
    }

    private var header: some View {
        HStack {
            Text(lang.t("settings.title"))
                .font(CarniFont.bold(24))
                .foregroundStyle(CarniColors.purpleDark)
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CarniColors.purpleDark)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(Color.white)
                                .shadow(color: CarniColors.purpleDark.opacity(0.08), radius: 8, y: 3)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(lang.t("common.close"))
            }
        }
    }

    private var userEmail: String? {
        SupabaseClientProvider.shared.auth.currentSession?.user.email
    }

    private var profileInitials: String {
        guard let email = userEmail, let first = email.first else { return "?" }
        return String(first).uppercased()
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(CarniColors.purple.opacity(0.14))
                Text(profileInitials)
                    .font(CarniFont.bold(20))
                    .foregroundStyle(CarniColors.purple)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(userEmail ?? lang.t("settings.account"))
                    .font(CarniFont.bold(17))
                    .foregroundStyle(CarniColors.purpleDark)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CarniColors.tabInactive)
        }
        .carniCard()
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: lang.t("settings.account"))

            VStack(spacing: 0) {
                Button { accountSheet = .email } label: {
                    LinkRow(
                        icon: "envelope.fill",
                        tint: Color(red: 72 / 255, green: 122 / 255, blue: 204 / 255),
                        title: lang.t("settings.changeEmail")
                    )
                }
                .buttonStyle(.plain)
                Divider().opacity(0.5)
                Button { accountSheet = .password } label: {
                    LinkRow(
                        icon: "lock.fill",
                        tint: CarniColors.purple,
                        title: lang.t("settings.changePassword")
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(settingsCardBackground)
        }
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
            Task { await auth.signOut() }
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
        .contentShape(Rectangle())
    }
}

enum AccountSheet: Identifiable {
    case email
    case password

    var id: Int {
        switch self {
        case .email: return 0
        case .password: return 1
        }
    }
}

/// Scaffolding shared by the account-edit sheets: title bar, scrollable body,
/// inline error, and a primary save button that reflects `isWorking`.
private struct AccountEditSheet<Content: View>: View {
    let title: String
    let saveTitle: String
    let isWorking: Bool
    let canSave: Bool
    let errorMessage: String?
    let successMessage: String?
    let onSave: () -> Void
    @ViewBuilder let content: Content

    @ObservedObject private var lang = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(title)
                    .font(CarniFont.bold(22))
                    .foregroundStyle(CarniColors.purpleDark)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CarniColors.purpleDark)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(CarniColors.purple.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(lang.t("common.close"))
            }

            content

            if let successMessage {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(CarniFont.regular(13))
                    .foregroundStyle(CarniColors.successGreen)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(CarniFont.regular(13))
                    .foregroundStyle(Color(red: 214 / 255, green: 84 / 255, blue: 84 / 255))
            }

            Button(action: onSave) {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().tint(.white) }
                    Text(isWorking ? lang.t("settings.saving") : saveTitle)
                        .font(CarniFont.semibold(16))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(CarniColors.purple)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSave || isWorking)
            .opacity((!canSave || isWorking) ? 0.55 : 1)

            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}

private struct ChangeEmailSheet: View {
    let currentEmail: String?

    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var newEmail = ""
    @State private var succeeded = false

    private var canSave: Bool {
        let trimmed = newEmail.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed != currentEmail
    }

    var body: some View {
        AccountEditSheet(
            title: lang.t("settings.changeEmail"),
            saveTitle: lang.t("settings.save"),
            isWorking: auth.isWorking,
            canSave: canSave,
            errorMessage: auth.errorMessage,
            successMessage: succeeded ? lang.t("settings.emailUpdated") : nil,
            onSave: save
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if let currentEmail {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lang.t("settings.currentEmail"))
                            .font(CarniFont.semibold(11))
                            .foregroundStyle(CarniColors.tabInactive)
                        Text(currentEmail)
                            .font(CarniFont.regular(15))
                            .foregroundStyle(CarniColors.purpleDark)
                    }
                }
                AuthTextField(
                    title: lang.t("settings.newEmail"),
                    placeholder: lang.t("auth.emailPh"),
                    text: $newEmail,
                    keyboardType: .emailAddress,
                    textContentType: .emailAddress,
                    lightStyle: true
                )
            }
        }
    }

    private func save() {
        Task {
            let trimmed = newEmail.trimmingCharacters(in: .whitespaces)
            if await auth.updateEmail(trimmed) {
                succeeded = true
            }
        }
    }
}

private struct ChangePasswordSheet: View {
    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var codeSent = false
    @State private var isSendingCode = false
    @State private var succeeded = false
    @State private var localError: String?

    private var canSave: Bool {
        codeSent && !code.isEmpty && newPassword.count >= 6 && !confirmPassword.isEmpty
    }

    var body: some View {
        AccountEditSheet(
            title: lang.t("settings.changePassword"),
            saveTitle: lang.t("settings.save"),
            isWorking: auth.isWorking,
            canSave: canSave,
            errorMessage: localError ?? auth.errorMessage,
            successMessage: succeeded ? lang.t("settings.passwordUpdated") : nil,
            onSave: save
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Step 1: email a confirmation code to the signed-in user. Once
                // sent, reveal the code field so they can confirm the change.
                if codeSent {
                    Text(lang.t("settings.codeSent"))
                        .font(CarniFont.regular(13))
                        .foregroundStyle(CarniColors.tabInactive)
                    AuthTextField(
                        title: lang.t("settings.verificationCode"),
                        placeholder: lang.t("settings.verificationCodePh"),
                        text: $code,
                        keyboardType: .numberPad,
                        textContentType: .oneTimeCode,
                        lightStyle: true
                    )
                }

                AuthSecureField(
                    title: lang.t("settings.newPassword"),
                    placeholder: lang.t("settings.newPasswordPh"),
                    text: $newPassword,
                    lightStyle: true
                )
                AuthSecureField(
                    title: lang.t("settings.confirmNewPassword"),
                    placeholder: lang.t("auth.repeatPw"),
                    text: $confirmPassword,
                    lightStyle: true
                )

                Button(action: sendCode) {
                    HStack(spacing: 8) {
                        if isSendingCode { ProgressView().tint(CarniColors.purple) }
                        Text(codeSent ? lang.t("settings.resendCode") : lang.t("settings.sendCode"))
                            .font(CarniFont.semibold(14))
                    }
                    .foregroundStyle(CarniColors.purple)
                }
                .buttonStyle(.plain)
                .disabled(isSendingCode)
            }
        }
    }

    private func sendCode() {
        localError = nil
        isSendingCode = true
        Task {
            let sent = await auth.sendPasswordChangeCode()
            isSendingCode = false
            if sent { codeSent = true }
        }
    }

    private func save() {
        guard newPassword == confirmPassword else {
            localError = lang.t("auth.mismatch")
            return
        }
        localError = nil
        Task {
            if await auth.updatePassword(new: newPassword, code: code.trimmingCharacters(in: .whitespaces)) {
                succeeded = true
            }
        }
    }
}
