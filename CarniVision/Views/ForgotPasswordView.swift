import SwiftUI

struct ForgotPasswordView: View {
    @Environment(\.dismiss) private var dismiss
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
                                .font(CarniFont.semibold(14))
                                .foregroundStyle(CarniColors.white)
                                .frame(width: 32, height: 32)
                                .background(CarniColors.white.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: CarniLayout.buttonCornerRadius))
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }

                    AuthHeader(
                        title: "Forgot Password",
                        subtitle: "Enter your email or phone number and we'll send you a reset link."
                    )

                    AuthCard {
                        AuthMethodPicker(method: $resetMethod)

                        if resetMethod == .email {
                            AuthTextField(
                                title: "Email",
                                placeholder: "you@example.com",
                                text: $email,
                                keyboardType: .emailAddress,
                                textContentType: .emailAddress
                            )
                        } else {
                            PhoneNumberField(
                                title: "Phone number",
                                selectedCountry: $selectedCountry,
                                phoneNumber: $phoneNumber
                            )
                        }

                        PrimaryAuthButton(title: "Send Reset Link") {
                            handleResetRequest()
                        }
                    }

                    AuthFooterPrompt(
                        prompt: "Remember your password?",
                        actionTitle: "Back to login"
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
