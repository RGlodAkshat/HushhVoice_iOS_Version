import SwiftUI
import UIKit

// Landing gate shown before user signs in or chooses guest mode.
struct AuthGateView: View {
    @ObservedObject private var google = GoogleSignInManager.shared
    @AppStorage("hushh_guest_mode") private var isGuest: Bool = false
    @State private var breathe = false
    @State private var appeared = false

    private var tagline: String {
        "Your data. Your intelligence. In voice mode."
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    HVTheme.surfaceAlt.opacity(0.9),
                                    HVTheme.surfaceAlt.opacity(0.6)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 136, height: 136)
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                        .background(
                            RadialGradient(
                                colors: [HVTheme.accent.opacity(0.25), .clear],
                                center: .center,
                                startRadius: 12,
                                endRadius: 120
                            )
                        )

                    Image("hushh_quiet_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 6)
                }
                .scaleEffect(breathe ? 1.02 : 0.98)
                .opacity(breathe ? 1.0 : 0.85)
                .onAppear {
                    withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                        breathe = true
                    }
                }

                VStack(spacing: 10) {
                    Text("HushhVoice")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(tagline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                }
            }
            .padding(.bottom, 8)

            VStack(spacing: 14) {
                Button {
                    isGuest = false
                    google.signIn()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                        Text(google.isSignedIn ? "Continue with Google" : "Continue with Google")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(0.7)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.white))
                }
                .foregroundColor(.black)
                .buttonStyle(AuthGatePressableStyle())

                Text("— or —")
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.footnote.weight(.semibold))

                SupabaseSignInWithAppleButton()
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .buttonStyle(AuthGatePressableStyle())

                Button {
                    isGuest = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Continue as Guest")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(0.7)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .foregroundColor(.white)
                .buttonStyle(AuthGatePressableStyle())
            }
            .padding(.horizontal, 28)

            Spacer()

            VStack(spacing: 6) {
                Text("Used only to connect your data securely to your personal AI.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                Text("Nothing is shared without your consent.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)

            Spacer(minLength: 26)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 18)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) {
                appeared = true
            }
        }
        .background(AuthGateBackground().ignoresSafeArea())
    }
}

private struct AuthGatePressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
    }
}

private struct AuthGateBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(hue: 0.58, saturation: 0.4, brightness: 0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [HVTheme.accent.opacity(0.15), .clear],
                center: .top,
                startRadius: 40,
                endRadius: 320
            )
            RadialGradient(
                colors: [Color.white.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 280
            )
        }
    }
}
