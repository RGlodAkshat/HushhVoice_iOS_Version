import SwiftUI

struct LogoOrb: View {
    var size: CGFloat
    var logoSize: CGFloat
    var wakePulse: Bool

    @State private var breathe = false

    var body: some View {
        let scale = wakePulse ? 1.12 : (breathe ? 1.04 : 0.96)
        let opacity = wakePulse ? 1.0 : (breathe ? 0.85 : 0.6)

        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [HVTheme.accent.opacity(0.55), Color.clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: size * 0.85
                    )
                )
                .frame(width: size, height: size)
                .blur(radius: 12)
                .scaleEffect(scale)
                .opacity(opacity)

            Circle()
                .fill(HVTheme.surfaceAlt.opacity(0.75))
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay(Circle().stroke(Color.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 8)

            Image("hushh_quiet_logo")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}
