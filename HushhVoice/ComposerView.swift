import SwiftUI

struct ComposerView: View {
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void
    var disabled: Bool

    // 👉 Two-line starting height (with 17pt system font + insets)
    @State private var height: CGFloat = 56

    // If you ever change the font/insets in AutoGrowingTextView, bump this up/down a bit
    private let minHeight: CGFloat = 26   // ~2 lines
    private let maxHeight: CGFloat = 200  // grows to ~6–8 lines before scrolling

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(HVTheme.surfaceAlt)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(HVTheme.stroke))

                AutoGrowingTextView(
                    text: $text,
                    calculatedHeight: $height,
                    minHeight: minHeight,   // 👈 start at 2 lines
                    maxHeight: maxHeight,   // 👈 grow beyond as needed
                    onReturn: { if !disabled { onSend() } }
                )
                .frame(height: height)
                .padding(.horizontal, 8)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Ask HushhVoice…")
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            Button(action: onSend) {
                if isSending {
                    ProgressView().tint(.black).padding(10)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(6)
                }
            }
            .background(disabled ? Color.white.opacity(0.25) : Color.white)
            .foregroundStyle(disabled ? .black.opacity(0.5) : .black)
            .clipShape(Circle())
            .disabled(disabled)
        }
        .padding(.vertical, 4)
    }
}
