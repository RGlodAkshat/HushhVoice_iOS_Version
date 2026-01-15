import SwiftUI

// Top app bar with menu toggle and quick link button.
struct HeaderBar: View {
    var onToggleSidebar: (() -> Void)?
    var onGoToHushhTech: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { onToggleSidebar?() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 18, weight: .semibold))
            }
            .tint(HVTheme.accent)

            Text("HushhVoice")
                .font(.headline)
                .foregroundStyle(HVTheme.botText)

            Spacer()

            Button {
                onGoToHushhTech?()
            } label: {
                Text("Go to HushhTech")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(HVTheme.surfaceAlt))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
            }
            .foregroundStyle(HVTheme.botText)
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(HVTheme.bg.opacity(0.95))
    }
}
