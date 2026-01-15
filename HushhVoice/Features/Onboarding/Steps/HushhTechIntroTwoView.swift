import SwiftUI

struct HushhTechIntroTwoView: View {
    var onContinue: () -> Void
    @State private var showRows = false

    var body: some View {
        OnboardingContainer {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    HStack {
                        OnboardingChip(text: "Step 3 of 4")
                        Spacer()
                    }
                    ProgressDots(total: 4, current: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 12) {
                    Text("AI that works for you, not on you.")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(HVTheme.botText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(-2)
                    VStack(spacing: 0) {
                        FeatureRow(
                            icon: "lock.fill",
                            title: "Privacy-first",
                            description: "Nothing moves without consent",
                            show: showRows,
                            delay: 0
                        )
                        FeatureDivider()
                        FeatureRow(
                            icon: "person.fill",
                            title: "Personal AI",
                            description: "Understands you, not audiences",
                            show: showRows,
                            delay: 0.06
                        )
                        FeatureDivider()
                        FeatureRow(
                            icon: "sparkles",
                            title: "Real value",
                            description: "Better decisions and experiences",
                            show: showRows,
                            delay: 0.12
                        )
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 24)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HVTheme.surface.opacity(0.7),
                                        HVTheme.surfaceAlt.opacity(0.6)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.07)))
                            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
                    )
                    .padding(.top, 6)
                }

                Text("No ads. No tracking. Consent First.")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.5))

                Button(action: onContinue) {
                    HStack {
                        Text("Continue")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
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

                Spacer()
            }
            .padding(.vertical, 24)
            .onAppear { showRows = true }
        }
    }
}

struct FeatureDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

struct FeatureRow: View {
    var icon: String
    var title: String
    var description: String
    var show: Bool
    var delay: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HVTheme.accent)
                .padding(8)
                .background(Circle().fill(HVTheme.surfaceAlt))
                .overlay(Circle().stroke(Color.white.opacity(0.08)))
                .scaleEffect(show ? 1.0 : 0.92)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HVTheme.botText)
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(show ? 1 : 0)
        .offset(y: show ? 0 : 6)
        .animation(.easeOut(duration: 0.3).delay(delay), value: show)
    }
}
