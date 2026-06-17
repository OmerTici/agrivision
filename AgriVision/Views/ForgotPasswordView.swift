import SwiftUI

struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lang = LanguageManager.shared
    @State private var resetMethod: AuthMethod = .email
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var selectedCountry = CountryCode.turkey

    var body: some View {
        AuthBackground {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 24)

                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(AgriFont.semibold(14))
                                .foregroundStyle(AgriColors.white)
                                .frame(width: 32, height: 32)
                                .background(AgriColors.white.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: AgriLayout.buttonCornerRadius))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }

                    AuthHeader(
                        title: lang.t("auth.forgotTitle"),
                        subtitle: lang.t("auth.forgotSubtitle")
                    )

                    AuthCard {
                        AuthMethodPicker(method: $resetMethod)

                        if resetMethod == .email {
                            AuthTextField(
                                title: lang.t("auth.email"),
                                placeholder: lang.t("auth.emailPh"),
                                text: $email,
                                keyboardType: .emailAddress,
                                textContentType: .emailAddress
                            )
                        } else {
                            PhoneNumberField(
                                title: lang.t("auth.phone"),
                                selectedCountry: $selectedCountry,
                                phoneNumber: $phoneNumber
                            )
                        }

                        PrimaryAuthButton(title: lang.t("auth.sendReset")) {
                            handleResetRequest()
                        }
                    }

                    AuthFooterPrompt(
                        prompt: lang.t("auth.remember"),
                        actionTitle: lang.t("auth.backToLogin")
                    ) {
                        dismiss()
                    }

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func handleResetRequest() {
        switch resetMethod {
        case .email:
            print("Reset requested for email: \(email)")
        case .phone:
            print("Reset requested for phone: \(selectedCountry.dialCode) \(phoneNumber)")
        }
    }
}
