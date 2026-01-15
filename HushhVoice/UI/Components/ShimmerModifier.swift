import SwiftUI

struct ShimmerModifier: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if active {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.02),
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .rotationEffect(.degrees(20))
                        .offset(x: phase * 240)
                        .blendMode(.screen)
                        .onAppear {
                            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                                phase = 0.8
                            }
                        }
                    }
                }
            )
            .clipped()
    }
}

extension View {
    func shimmer(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
