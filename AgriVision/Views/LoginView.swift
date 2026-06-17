import SwiftUI

struct SignInForm: View {
    var onBack: () -> Void
    var onSwitchToSignUp: () -> Void
    var presentStatus: (AuthStatusContent) -> Void

    @EnvironmentObject private var auth: AuthService
    @ObservedObject private var lang = LanguageManager.shared
    @State private var loginMethod: AuthMethod = .email
    @State private var email = ""
    @State private var phoneNumber = ""
    @State private var selectedCountry = CountryCode.turkey
    @State private var password = ""
    @State private var showForgotPassword = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                AuthBackButton(systemName: "chevron.left", action: onBack)

                AuthHeader(
                    title: "Agri_vision",
                    subtitle: lang.t("auth.login.subtitle")
                )

                AuthCard(lightStyle: true) {
                    AuthMethodPicker(method: $loginMethod, lightStyle: true)

                    VStack(spacing: 16) {
                        if loginMethod == .email {
                            AuthTextField(
                                title: lang.t("auth.email"),
                                placeholder: lang.t("auth.emailPh"),
                                text: $email,
                                keyboardType: .emailAddress,
                                textContentType: .emailAddress,
                                lightStyle: true
                            )
                        } else {
                            PhoneNumberField(
                                title: lang.t("auth.phone"),
                                selectedCountry: $selectedCountry,
                                phoneNumber: $phoneNumber,
                                lightStyle: true
                            )
                        }

                        AuthSecureField(
                            title: lang.t("auth.password"),
                            placeholder: lang.t("auth.passwordPh"),
                            text: $password,
                            lightStyle: true
                        )
                    }

                    HStack {
                        Spacer()
                        AuthTextButton(title: lang.t("auth.forgot"), lightStyle: true) {
                            showForgotPassword = true
                        }
                    }

                    PrimaryAuthButton(
                        title: auth.isWorking ? lang.t("auth.signingIn") : lang.t("auth.login")
                    ) {
                        handleLogin()
                    }
                    .disabled(auth.isWorking || email.isEmpty || password.isEmpty)
                }

                AuthFooterPrompt(
                    prompt: lang.t("auth.noAccount"),
                    actionTitle: lang.t("auth.signupAction")
                ) {
                    onSwitchToSignUp()
                }

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showForgotPassword) {
            ForgotPasswordView()
        }
    }

    private func handleLogin() {
        Task {
            let result = await auth.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            if case .failed(let kind) = result {
                presentStatus(AuthStatusContent.failure(kind, lang: lang))
            }
            // On success, identity is set and RootView swaps to the main app.
        }
    }
}
