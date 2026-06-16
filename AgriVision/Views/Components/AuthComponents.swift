import SwiftUI

enum AuthMethod: String, CaseIterable, Identifiable {
    case email = "Email"
    case phone = "Phone"

    var id: String { rawValue }

    var key: String {
        switch self {
        case .email: return "auth.method.email"
        case .phone: return "auth.method.phone"
        }
    }
}

struct AuthBackground<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AgriColors.purpleLight, AgriColors.purple, AgriColors.purpleDark],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            content
        }
    }
}

struct AuthHeader: View {
    let title: String
    var subtitle: String? = nil
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 4 : 10) {
            Text(title)
                .font(AgriFont.bold(compact ? 24 : 30))
                .foregroundStyle(AgriColors.white)

            if let subtitle {
                Text(subtitle)
                    .font(AgriFont.regular(compact ? 13 : 15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AgriColors.mutedText)
            }
        }
    }
}

struct AuthMethodPicker: View {
    @Binding var method: AuthMethod
    var compact: Bool = false
    var lightStyle: Bool = false
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AuthMethod.allCases) { option in
                Button {
                    method = option
                } label: {
                    Text(lang.t(option.key))
                        .font(AgriFont.semibold(compact ? 13 : 15))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, compact ? 8 : 10)
                        .foregroundStyle(
                            method == option
                                ? (lightStyle ? AgriColors.white : AgriColors.purple)
                                : (lightStyle ? AgriColors.purple : AgriColors.white)
                        )
                        .background(
                            method == option
                                ? (lightStyle ? AgriColors.purple : AgriColors.white)
                                : Color.clear
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(lightStyle ? AgriColors.purple.opacity(0.10) : AgriColors.white.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: AgriLayout.buttonCornerRadius))
    }
}

struct AuthCard<Content: View>: View {
    var compact: Bool = false
    var lightStyle: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: compact ? 12 : 20) {
            content
        }
        .padding(compact ? 14 : 24)
        .background {
            if lightStyle {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.75),
                        Color.white.opacity(0.75),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                ZStack {
                    AgriColors.cardOverlay
                    Color.clear.background(.ultraThinMaterial.opacity(0.15))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AgriLayout.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AgriLayout.cardCornerRadius)
                .stroke(
                    lightStyle ? AgriColors.purple.opacity(0.12) : AgriColors.white.opacity(0.22),
                    lineWidth: 1
                )
        )
        .shadow(color: AgriColors.purpleDark.opacity(lightStyle ? 0.15 : 0.25), radius: compact ? 10 : 16, y: compact ? 4 : 8)
    }
}

struct AuthTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType?
    var compact: Bool = false
    var lightStyle: Bool = false

    private var labelColor: Color {
        lightStyle ? AgriColors.purple.opacity(0.85) : AgriColors.white.opacity(0.92)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(title)
                .font(AgriFont.semibold(compact ? 11 : 12))
                .foregroundStyle(labelColor)

            TextField(placeholder, text: $text)
                .font(AgriFont.regular(compact ? 14 : 16))
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, compact ? 12 : 14)
                .padding(.vertical, compact ? 10 : 14)
                .background(AgriColors.fieldBackground)
                .foregroundStyle(AgriColors.purple)
                .clipShape(RoundedRectangle(cornerRadius: AgriLayout.fieldCornerRadius))
        }
    }
}

struct AuthSecureField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var compact: Bool = false
    var lightStyle: Bool = false

    private var labelColor: Color {
        lightStyle ? AgriColors.purple.opacity(0.85) : AgriColors.white.opacity(0.92)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(title)
                .font(AgriFont.semibold(compact ? 11 : 12))
                .foregroundStyle(labelColor)

            SecureField(placeholder, text: $text)
                .font(AgriFont.regular(compact ? 14 : 16))
                .textContentType(.password)
                .padding(.horizontal, compact ? 12 : 14)
                .padding(.vertical, compact ? 10 : 14)
                .background(AgriColors.fieldBackground)
                .foregroundStyle(AgriColors.purple)
                .clipShape(RoundedRectangle(cornerRadius: AgriLayout.fieldCornerRadius))
        }
    }
}

struct PhoneNumberField: View {
    let title: String
    @Binding var selectedCountry: CountryCode
    @Binding var phoneNumber: String
    var compact: Bool = false
    var lightStyle: Bool = false

    private var labelColor: Color {
        lightStyle ? AgriColors.purple.opacity(0.85) : AgriColors.white.opacity(0.92)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Text(title)
                .font(AgriFont.semibold(compact ? 11 : 12))
                .foregroundStyle(labelColor)

            HStack(spacing: 8) {
                Menu {
                    ForEach(CountryCode.all) { country in
                        Button {
                            selectedCountry = country
                        } label: {
                            Text("\(country.flag)  \(country.name)  \(country.dialCode)")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedCountry.flag)
                            .font(AgriFont.regular(compact ? 16 : 18))
                        Text(selectedCountry.dialCode)
                            .font(AgriFont.semibold(compact ? 13 : 15))
                            .foregroundStyle(AgriColors.purple)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AgriColors.purple.opacity(0.7))
                    }
                    .padding(.horizontal, compact ? 10 : 12)
                    .padding(.vertical, compact ? 10 : 14)
                    .background(AgriColors.fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AgriLayout.fieldCornerRadius))
                }

                TextField("5XX XXX XX XX", text: $phoneNumber)
                    .font(AgriFont.regular(compact ? 14 : 16))
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .padding(.horizontal, compact ? 12 : 14)
                    .padding(.vertical, compact ? 10 : 14)
                    .background(AgriColors.fieldBackground)
                    .foregroundStyle(AgriColors.purple)
                    .clipShape(RoundedRectangle(cornerRadius: AgriLayout.fieldCornerRadius))
            }
        }
    }
}

struct PrimaryAuthButton: View {
    let title: String
    var compact: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AgriFont.semibold(compact ? 15 : 17))
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 12 : 15)
                .foregroundStyle(AgriColors.purple)
                .background(AgriColors.white)
                .clipShape(RoundedRectangle(cornerRadius: AgriLayout.buttonCornerRadius))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

struct AuthBackButton: View {
    var systemName: String = "chevron.left"
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(AgriFont.semibold(14))
                    .foregroundStyle(AgriColors.white)
                    .frame(width: 32, height: 32)
                    .background(AgriColors.white.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: AgriLayout.buttonCornerRadius))
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

struct AuthTextButton: View {
    let title: String
    var lightStyle: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AgriFont.semibold(14))
                .foregroundStyle(lightStyle ? AgriColors.purple : AgriColors.white)
                .underline()
        }
        .buttonStyle(.plain)
    }
}

struct AuthFooterPrompt: View {
    let prompt: String
    let actionTitle: String
    let action: () -> Void
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(prompt)
                .foregroundStyle(AgriColors.mutedText)
            Button(action: action) {
                Text(actionTitle)
                    .font(AgriFont.semibold(compact ? 13 : 14))
                    .foregroundStyle(AgriColors.white)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .font(AgriFont.regular(compact ? 13 : 15))
    }
}
