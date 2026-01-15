import SwiftUI

struct QuietMicButtonSmall: View {
    @Binding var isMuted: Bool
    var onToggle: () -> Void

    @State private var pulse = false
    @State private var tapPulse = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                isMuted.toggle()
                onToggle()
                tapPulse = false
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                tapPulse = true
            }
        } label: {
            ZStack {
                Circle()
                    .fill(HVTheme.surfaceAlt.opacity(isMuted ? 0.80 : 1.0))
                    .overlay(Circle().stroke(HVTheme.stroke.opacity(isMuted ? 0.9 : 0.55), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)

                Circle()
                    .stroke(HVTheme.accent.opacity(isMuted ? 0.12 : 0.35), lineWidth: 2)
                    .scaleEffect(tapPulse ? 1.35 : 1.05)
                    .opacity(tapPulse ? 0.0 : 0.85)
                    .animation(.easeOut(duration: 0.45), value: tapPulse)

                Circle()
                    .stroke(HVTheme.accent.opacity(isMuted ? 0.16 : 0.40), lineWidth: isMuted ? 1 : 2)
                    .scaleEffect(isMuted ? 1.02 : (pulse ? 1.16 : 1.05))
                    .opacity(isMuted ? 0.30 : (pulse ? 0.80 : 0.45))
                    .blur(radius: isMuted ? 0.6 : 2.0)
                    .animation(isMuted ? .none : .easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: pulse)

                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isMuted ? Color.red.opacity(0.9) : HVTheme.botText.opacity(0.9))
            }
            .frame(width: 62, height: 62)
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .accessibilityLabel(isMuted ? "Unmute microphone" : "Mute microphone")
    }
}
