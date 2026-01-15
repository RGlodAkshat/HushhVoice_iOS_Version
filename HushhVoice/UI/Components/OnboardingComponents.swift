import SwiftUI

struct OnboardingContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
    }
}

struct ProgressDots: View {
    var total: Int
    var current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { idx in
                Circle()
                    .fill(idx == current ? HVTheme.accent : HVTheme.surfaceAlt)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(HVTheme.stroke.opacity(0.6)))
            }
        }
    }
}

struct OnboardingChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(HVTheme.surfaceAlt.opacity(0.75)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08)))
            .foregroundStyle(HVTheme.botText.opacity(0.75))
    }
}
