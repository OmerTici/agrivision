import SwiftUI

struct SignUpForm: View {
    var onBack: () -> Void
    var onSwitchToSignIn: () -> Void

    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared
    @State private var fullName = ""
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var selectedCountry = CountryCode.turkey
    @State private var password = ""
    @State private var confirmPassword = ""

    private var canSubmit: Bool {
        !fullName.isEmpty
            && !email.isEmpty
            && !phoneNumber.isEmpty
            && !password.isEmpty
            && password == confirmPassword
    }

    var body: some View {
        VStack(spacing: 12) {
            AuthBackButton(systemName: "chevron.left", action: onBack)

            AuthHeader(title: lang.t("auth.create"), compact: true)

            AuthCard(compact: true, lightStyle: true) {
                VStack(spacing: 8) {
                    AuthTextField(
                        title: lang.t("auth.fullName"),
                        placeholder: lang.t("auth.fullNamePh"),
                        text: $fullName,
                        textContentType: .name,
                        compact: true,
                        lightStyle: true
                    )

                    AuthTextField(
                        title: lang.t("auth.email"),
                        placeholder: lang.t("auth.emailPh"),
                        text: $email,
                        keyboardType: .emailAddress,
                        textContentType: .emailAddress,
                        compact: true,
                        lightStyle: true
                    )

                    PhoneNumberField(
                        title: lang.t("auth.phone"),
                        selectedCountry: $selectedCountry,
                        phoneNumber: $phoneNumber,
                        compact: true,
                        lightStyle: true
                    )

                    AuthSecureField(
                        title: lang.t("auth.password"),
                        placeholder: lang.t("auth.createPw"),
                        text: $password,
                        compact: true,
                        lightStyle: true
                    )

                    AuthSecureField(
                        title: lang.t("auth.confirmPw"),
                        placeholder: lang.t("auth.repeatPw"),
                        text: $confirmPassword,
                        compact: true,
                        lightStyle: true
                    )
                }

                if let error = auth.errorMessage {
                    Text(error)
                        .font(CarniFont.regular(13))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PrimaryAuthButton(
                    title: auth.isWorking ? lang.t("auth.signingUp") : lang.t("auth.signupAction"),
                    compact: true,
                    disabled: !canSubmit || auth.isWorking
                ) {
                    handleSignUp()
                }
            }

            Spacer(minLength: 0)

            AuthFooterPrompt(
                prompt: lang.t("auth.haveAccount"),
                actionTitle: lang.t("auth.login"),
                compact: true
            ) {
                onSwitchToSignIn()
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSignUp() {
        guard password == confirmPassword else {
            auth.errorMessage = lang.t("auth.mismatch")
            return
        }
        Task {
            await auth.signUp(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
        }
    }
}
