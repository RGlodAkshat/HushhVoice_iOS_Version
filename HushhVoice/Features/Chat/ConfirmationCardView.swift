import SwiftUI

// Confirmation card displayed inside chat for write actions.
struct ConfirmationCardView: View {
    let confirmation: ChatConfirmation
    var onConfirm: (() -> Void)?
    var onEdit: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm \(confirmation.actionType)")
                .font(.headline)
                .foregroundStyle(HVTheme.botText)

            Text(confirmation.previewText)
                .font(.subheadline)
                .foregroundStyle(HVTheme.botText.opacity(0.85))
                .lineSpacing(3)

            HStack(spacing: 10) {
                Button("Confirm") { onConfirm?() }
                    .buttonStyle(.borderedProminent)
                    .tint(HVTheme.accent)

                Button("Edit") { onEdit?() }
                    .buttonStyle(.bordered)
                    .tint(HVTheme.botText)

                Button("Cancel") { onCancel?() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(HVTheme.surfaceAlt)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HVTheme.stroke))
        )
        .padding(.horizontal)
    }
}
