import SwiftUI

struct HushhTechIntroOneView: View {
    var onContinue: () -> Void
    @State private var isPressing = false
    @State private var animateIn = false

    var body: some View {
        OnboardingContainer {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    HStack {
                        OnboardingChip(text: "Step 2 of 4")
                        Spacer()
                    }

                    ProgressDots(total: 4, current: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 16) {
                    LogoOrb(size: 220, logoSize: 72, wakePulse: false)
                        .opacity(animateIn ? 1 : 0)
                        .scaleEffect(animateIn ? 1 : 0.98)
                        .animation(.easeOut(duration: 0.5).delay(0.05), value: animateIn)

                    VStack(spacing: 10) {
                        Text("Your data. Your intelligence. Your control.")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(HVTheme.botText)
                            .multilineTextAlignment(.center)
                            .lineSpacing(-1)
                        Text("HushhTech helps you organize and use your personal data - privately, securely, and on your terms.")
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(HVTheme.botText.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .opacity(animateIn ? 1 : 0)
                    .offset(y: animateIn ? 0 : 10)
                    .animation(.easeOut(duration: 0.4).delay(0.18), value: animateIn)
                }

                Button(action: onContinue) {
                    HStack {
                        Text("Continue")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .offset(x: isPressing ? 4 : 0)
                            .animation(.easeOut(duration: 0.15), value: isPressing)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.accent.opacity(0.95),
                                        HVTheme.accent.opacity(0.75)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                }
                .foregroundColor(.black)
                .buttonStyle(PressableButtonStyle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPressing = true }
                        .onEnded { _ in isPressing = false }
                )
                .opacity(animateIn ? 1 : 0)
                .offset(y: animateIn ? 0 : 10)
                .animation(.easeOut(duration: 0.35).delay(0.28), value: animateIn)

                Spacer()
            }
            .padding(.vertical, 24)
            .onAppear { animateIn = true }
        }
    }
}
