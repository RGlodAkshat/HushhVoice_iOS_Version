import SwiftUI

struct PostSummaryActionsView: View {
    var onExplore: () -> Void
    var onGoToHushhTech: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(spacing: 8) {
                Text("You're set")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(HVTheme.botText)
                Text("Choose where you want to go next.")
                    .font(.subheadline)
                    .foregroundStyle(HVTheme.botText.opacity(0.6))
            }

            VStack(spacing: 14) {
                Button(action: onExplore) {
                    HStack {
                        Text("Explore HushhVoice")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "sparkles")
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 16).fill(HVTheme.accent))
                }
                .foregroundColor(.black)

                Button(action: onGoToHushhTech) {
                    HStack {
                        Text("Go to HushhTech")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(HVTheme.stroke, lineWidth: 1)
                            .background(RoundedRectangle(cornerRadius: 16).fill(HVTheme.surfaceAlt))
                    )
                }
                .foregroundStyle(HVTheme.botText)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
    }
}
