import SwiftUI

struct LandingView: View {
    private enum Screen {
        case landing
        case signIn
        case signUp
    }

    @ObservedObject private var lang = LanguageManager.shared
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
                    onSwitchToSignUp: { goTo(.signUp) }
                )
                .transition(.move(edge: .bottom))
            }

            if screen == .signUp {
                SignUpForm(
                    onBack: { goTo(.landing) },
                    onSwitchToSignIn: { goTo(.signIn) }
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
            HStack {
                Spacer()
                languageToggle
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 8) {
                Text("Agri_vision")
                    .font(AgriFont.bold(36))
                    .foregroundStyle(AgriColors.white)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                Text(lang.t("auth.landing.subtitle"))
                    .font(AgriFont.regular(15))
                    .foregroundStyle(AgriColors.white.opacity(0.88))
            }
            .padding(.bottom, 28)

            VStack(spacing: 12) {
                LandingActionButton(title: lang.t("auth.signin")) {
                    goTo(.signIn)
                }

                LandingActionButton(title: lang.t("auth.signup")) {
                    goTo(.signUp)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 48)
        }
    }

    private var languageToggle: some View {
        HStack(spacing: 4) {
            ForEach(AppLanguage.allCases) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        lang.language = option
                    }
                } label: {
                    Text(option.rawValue.uppercased())
                        .font(AgriFont.semibold(13))
                        .foregroundStyle(lang.language == option ? AgriColors.purple : AgriColors.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(lang.language == option ? AgriColors.white : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }
}

private struct LandingActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AgriFont.semibold(17))
                .foregroundStyle(AgriColors.purple)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(AgriColors.white)
                .clipShape(RoundedRectangle(cornerRadius: AgriLayout.buttonCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: AgriLayout.buttonCornerRadius)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    AgriColors.purpleLight.opacity(0.55),
                                    AgriColors.purple.opacity(0.30),
                                    AgriColors.purpleDark.opacity(0.40),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: AgriColors.purpleDark.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}
