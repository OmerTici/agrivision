import SwiftUI

struct SignInForm: View {
    var onBack: () -> Void
    var onSwitchToSignUp: () -> Void
    var onAuthenticated: () -> Void = {}

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
                    title: "Carni_vision",
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

                    PrimaryAuthButton(title: lang.t("auth.login")) {
                        handleLogin()
                    }
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
        switch loginMethod {
        case .email:
            print("Login with email: \(email)")
        case .phone:
            print("Login with phone: \(selectedCountry.dialCode) \(phoneNumber)")
        }
        onAuthenticated()
    }
}
