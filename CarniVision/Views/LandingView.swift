import SwiftUI

struct LandingView: View {
    private enum Screen {
        case landing
        case signIn
        case signUp
    }

    var onAuthenticated: () -> Void = {}

    @State private var screen: Screen = .landing

    private var transitionAnimation: Animation {
        .easeInOut(duration: 0.4)
    }

    var body: some View {
        ZStack {
            FarmVideoBackground(purpleOverlayOpacity: screen == .landing ? 0.25 : 0.45)
                .animation(transitionAnimation, value: screen)

            if screen == .landing {
                landingContent
                    .transition(.opacity)
            }

            if screen == .signIn {
                SignInForm(
                    onBack: { goTo(.landing) },
                    onSwitchToSignUp: { goTo(.signUp) },
                    onAuthenticated: onAuthenticated
                )
                .transition(.move(edge: .bottom))
            }

            if screen == .signUp {
                SignUpForm(
                    onBack: { goTo(.landing) },
                    onSwitchToSignIn: { goTo(.signIn) },
                    onAuthenticated: onAuthenticated
                )
                .transition(.move(edge: .bottom))
            }
        }
    }

    private func goTo(_ destination: Screen) {
        withAnimation(transitionAnimation) {
            screen = destination
        }
    }

    private var landingContent: some View {
        VStack {
            Spacer()

            VStack(spacing: 8) {
                Text("Carni_vision")
                    .font(CarniFont.bold(36))
                    .foregroundStyle(CarniColors.white)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                Text("Choose how you'd like to continue")
                    .font(CarniFont.regular(15))
                    .foregroundStyle(CarniColors.white.opacity(0.88))
            }
            .padding(.bottom, 28)

            VStack(spacing: 12) {
                LandingActionButton(title: "Sign In") {
                    goTo(.signIn)
                }

                LandingActionButton(title: "Sign Up") {
                    goTo(.signUp)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
        }
    }
}

private struct LandingActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CarniFont.semibold(17))
                .foregroundStyle(CarniColors.purple)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(CarniColors.white)
                .clipShape(RoundedRectangle(cornerRadius: CarniLayout.buttonCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: CarniLayout.buttonCornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    CarniColors.purpleLight.opacity(0.55),
                                    CarniColors.purple.opacity(0.30),
                                    CarniColors.purpleDark.opacity(0.40),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: CarniColors.purpleDark.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}
