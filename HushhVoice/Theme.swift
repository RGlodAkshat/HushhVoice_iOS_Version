import SwiftUI

enum HVTheme {
    // Pure “Apple dark mode” vibe
    static let bg = Color.black
    static let surface = Color(white: 0.12)        // chat bubble background
    static let surfaceAlt = Color(white: 0.08)     // composer background
    static let stroke = Color.white.opacity(0.08)  // subtle strokes
    static let userBubble = LinearGradient(
        colors: [Color.white.opacity(0.95), Color.white.opacity(0.80)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let userText = Color.black
    static let botText = Color.white
    static let corner: CGFloat = 16
}
