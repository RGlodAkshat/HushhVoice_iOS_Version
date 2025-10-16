import SwiftUI

struct TypingIndicatorView: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.white.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animationScale(i))
                    .animation(.easeInOut(duration: 0.9).repeatForever().delay(0.15 * Double(i)), value: animationScale(i))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: HVTheme.corner).fill(HVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: HVTheme.corner).stroke(HVTheme.stroke))
        .onAppear {}
    }

    private func animationScale(_ i: Int) -> CGFloat { 0.85 + CGFloat((Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 0.9))) }
}
