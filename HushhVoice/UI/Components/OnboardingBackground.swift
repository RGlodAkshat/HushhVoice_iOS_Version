import SwiftUI

struct OnboardingBackground: View {
    var body: some View {
        ZStack {
            HVTheme.bg.ignoresSafeArea()
            AuroraBackground()
                .ignoresSafeArea()
            LinearGradient(
                colors: [HVTheme.accent.opacity(0.18), Color.black.opacity(0.2), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(

                colors: [HVTheme.accent.opacity(0.20), Color.clear],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()
        }
    }
}

struct AuroraBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Circle()
                .fill(HVTheme.accent.opacity(0.16))
                .frame(width: 380, height: 380)
                .blur(radius: 60)
                .offset(x: drift ? -140 : 120, y: drift ? -220 : -80)
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: drift ? 130 : -160, y: drift ? 180 : 220)
            Circle()
                .fill(HVTheme.accent.opacity(0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 60)
                .offset(x: drift ? 40 : -60, y: drift ? 240 : 140)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}
