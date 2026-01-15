import SwiftUI

// Input field and send button at the bottom of the chat.
struct ComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var disabled: Bool
    var onSend: () -> Void

    private let fieldHeight: CGFloat = 36
    private var iconSize: CGFloat { 20 }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(HVTheme.surfaceAlt)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)

                HStack {
                    TextField("Ask HushhVoice…", text: $text, onCommit: { if !disabled { onSend() } })
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(false)
                        .foregroundColor(HVTheme.botText)
                        .font(.body)
                        .frame(height: fieldHeight)
                        .padding(.horizontal, 10)
                }
                .frame(height: fieldHeight)
            }
            .frame(height: fieldHeight)

            Button(action: onSend) {
                if isSending {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: iconSize, weight: .semibold))
                }
            }
            .frame(width: fieldHeight, height: fieldHeight)
            .background(disabled ? Color.white.opacity(0.25) : Color.white)
            .foregroundStyle(disabled ? .black.opacity(0.5) : .black)
            .clipShape(Circle())
            .disabled(disabled)
        }
        .padding(.vertical, 4)
        .tint(HVTheme.accent)
    }
}
