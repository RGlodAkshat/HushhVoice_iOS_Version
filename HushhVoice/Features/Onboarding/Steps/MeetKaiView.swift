import SwiftUI

struct MeetKaiView: View {
    var onStart: () -> Void
    var onNotNow: () -> Void
    @State private var pulse = false
    @State private var wakePulse = false

    var body: some View {
        OnboardingContainer {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    HStack {
                        OnboardingChip(text: "Step 4 of 4")
                        Spacer()
                    }
                    ProgressDots(total: 4, current: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 12) {
                    LogoOrb(size: 240, logoSize: 76, wakePulse: wakePulse)
                        .frame(height: 140)
                    Text("Meet Kai")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(HVTheme.botText)
                    Text("A calm financial AI that helps you think clearly about capital allocation. Takes ~3-4 minutes.")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(HVTheme.botText.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                        .padding(.horizontal, 18)
                }

                HStack(spacing: 8) {
                    TrustChip(text: "Private by default", icon: "lock.fill")
                    TrustChip(text: "Skip anytime", icon: "forward.fill")
                    TrustChip(text: "Stop anytime", icon: "xmark")
                }

                Button(action: onStart) {
                    HStack {
                        Text("Start talking")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "mic.fill")
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
                            .shadow(color: HVTheme.accent.opacity(0.35), radius: 14, x: 0, y: 8)
                    )
                    .background(
                        Circle()
                            .stroke(HVTheme.accent.opacity(0.35), lineWidth: 2)
                            .frame(width: 160, height: 160)
                            .scaleEffect(pulse ? 1.08 : 0.92)
                            .opacity(pulse ? 0 : 0.35)
                    )
                }
                .foregroundColor(.black)
                .buttonStyle(PressableButtonStyle())
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            wakePulse = true
                        }
                        .onEnded { _ in
                            wakePulse = false
                        }
                )

                Button(action: onNotNow) {
                    Text("Not now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HVTheme.botText.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.ultraThinMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))
                        )
                }
                .buttonStyle(PressableButtonStyle())

                Spacer()
            }
            .padding(.vertical, 24)
        }
    }
}

struct TrustChip: View {
    var text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HVTheme.botText.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 96)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
    }
}
