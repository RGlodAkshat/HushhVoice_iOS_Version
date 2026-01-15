import SwiftUI

// Simple animated dots to show "assistant is typing".
struct TypingIndicatorView: View {
    @State private var scale: CGFloat = 0.2

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(HVTheme.botText.opacity(0.35)).frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.00), value: scale)
            Circle().fill(HVTheme.botText.opacity(0.55)).frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.15), value: scale)
            Circle().fill(HVTheme.botText).frame(width: 7, height: 7)
                .scaleEffect(scale)
                .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.30), value: scale)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
        .onAppear { scale = 1.0 }
    }
}
