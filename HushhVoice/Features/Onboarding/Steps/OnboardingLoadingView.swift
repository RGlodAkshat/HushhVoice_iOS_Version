import SwiftUI

struct OnboardingLoadingView: View {
    var body: some View {
        OnboardingContainer {
            VStack(spacing: 16) {
                ProgressView()
                    .tint(HVTheme.accent)
                Text("Preparing Kai")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(HVTheme.botText)
                Text("Getting your session ready.")
                    .font(.footnote)
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(HVTheme.surface.opacity(0.9))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(HVTheme.stroke))
            )
        }
    }
}
