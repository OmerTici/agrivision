import SwiftUI

struct SignUpForm: View {
    var onBack: () -> Void
    var onSwitchToSignIn: () -> Void
    var presentStatus: (AuthStatusContent) -> Void

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
        VStack(spacing: 0) {
            AuthBackButton(systemName: "chevron.left", action: onBack)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            ScrollView {
                VStack(spacing: 12) {
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

                        PrimaryAuthButton(
                            title: auth.isWorking ? lang.t("auth.signingUp") : lang.t("auth.signupAction"),
                            compact: true,
                            disabled: !canSubmit || auth.isWorking
                        ) {
                            handleSignUp()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)

            AuthFooterPrompt(
                prompt: lang.t("auth.haveAccount"),
                actionTitle: lang.t("auth.login"),
                compact: true
            ) {
                onSwitchToSignIn()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleSignUp() {
        guard password == confirmPassword else {
            presentStatus(AuthStatusContent(
                kind: .error,
                title: lang.t("auth.popup.signupFailed.title"),
                message: lang.t("auth.mismatch"),
                autoDismiss: nil
            ))
            return
        }
        Task {
            let result = await auth.signUp(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password
            )
            switch result {
            case .signedIn:
                // Identity is set; RootView swaps to the main app automatically.
                break
            case .confirmationSent:
                presentStatus(AuthStatusContent(
                    kind: .success,
                    title: lang.t("auth.popup.emailSent.title"),
                    message: lang.t("auth.popup.emailSent.message"),
                    autoDismiss: 2.2,
                    onDismiss: onSwitchToSignIn
                ))
            case .failed(let kind):
                let titleKey = kind == .generic ? "auth.popup.signupFailed.title" : nil
                var content = AuthStatusContent.failure(kind, lang: lang)
                if let titleKey { content.title = lang.t(titleKey) }
                presentStatus(content)
            }
        }
    }
}
