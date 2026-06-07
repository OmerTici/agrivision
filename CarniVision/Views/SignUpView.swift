import SwiftUI

struct SignUpForm: View {
    var onBack: () -> Void
    var onSwitchToSignIn: () -> Void
    var onAuthenticated: () -> Void = {}

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

            AuthHeader(title: "Create Account", compact: true)

            AuthCard(compact: true, lightStyle: true) {
                VStack(spacing: 8) {
                    AuthTextField(
                        title: "Full name",
                        placeholder: "Your name",
                        text: $fullName,
                        textContentType: .name,
                        compact: true,
                        lightStyle: true
                    )

                    AuthTextField(
                        title: "Email",
                        placeholder: "you@example.com",
                        text: $email,
                        keyboardType: .emailAddress,
                        textContentType: .emailAddress,
                        compact: true,
                        lightStyle: true
                    )

                    PhoneNumberField(
                        title: "Phone number",
                        selectedCountry: $selectedCountry,
                        phoneNumber: $phoneNumber,
                        compact: true,
                        lightStyle: true
                    )

                    AuthSecureField(
                        title: "Password",
                        placeholder: "Create a password",
                        text: $password,
                        compact: true,
                        lightStyle: true
                    )

                    AuthSecureField(
                        title: "Confirm password",
                        placeholder: "Repeat your password",
                        text: $confirmPassword,
                        compact: true,
                        lightStyle: true
                    )
                }

                PrimaryAuthButton(title: "Sign up", compact: true, disabled: !canSubmit) {
                    handleSignUp()
                }
            }

            Spacer(minLength: 0)

            AuthFooterPrompt(
                prompt: "Already have an account?",
                actionTitle: "Log in",
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
        print("Sign up — name: \(fullName), email: \(email), phone: \(selectedCountry.dialCode) \(phoneNumber)")
        onAuthenticated()
    }
}
