import SwiftUI

struct SignInForm: View {
    var onBack: () -> Void
    var onSwitchToSignUp: () -> Void
    var onAuthenticated: () -> Void = {}

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
                    subtitle: "Welcome back. Sign in to continue."
                )

                AuthCard(lightStyle: true) {
                    AuthMethodPicker(method: $loginMethod, lightStyle: true)

                    VStack(spacing: 16) {
                        if loginMethod == .email {
                            AuthTextField(
                                title: "Email",
                                placeholder: "you@example.com",
                                text: $email,
                                keyboardType: .emailAddress,
                                textContentType: .emailAddress,
                                lightStyle: true
                            )
                        } else {
                            PhoneNumberField(
                                title: "Phone number",
                                selectedCountry: $selectedCountry,
                                phoneNumber: $phoneNumber,
                                lightStyle: true
                            )
                        }

                        AuthSecureField(
                            title: "Password",
                            placeholder: "Enter your password",
                            text: $password,
                            lightStyle: true
                        )
                    }

                    HStack {
                        Spacer()
                        AuthTextButton(title: "Forgot Password?", lightStyle: true) {
                            showForgotPassword = true
                        }
                    }

                    PrimaryAuthButton(title: "Log in") {
                        handleLogin()
                    }
                }

                AuthFooterPrompt(
                    prompt: "Don't have an account?",
                    actionTitle: "Sign up"
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
