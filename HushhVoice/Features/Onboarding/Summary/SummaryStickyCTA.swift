import SwiftUI

struct SummaryStickyCTA: View {
    var onConfirm: () -> Void
    var onOpenHushhTech: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onConfirm) {
                HStack {
                    Text("Confirm & continue with Kai")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(HVTheme.accent)
                )
            }
            .foregroundColor(.black)

            Button(action: onOpenHushhTech) {
                Text("Open HushhTech")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.8))
            }
            .buttonStyle(.plain)

            Button(action: onConfirm) {
                Text("I'll refine this later")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HVTheme.botText.opacity(0.7))
            }
            .buttonStyle(.plain)

            Text("Kai will keep refining this as you talk.")
                .font(.footnote)
                .foregroundStyle(HVTheme.botText.opacity(0.6))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
        )
    }
}
